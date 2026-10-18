#!/usr/bin/env python3
"""Observe-only Phase 3 Alertmanager webhook receiver."""

import json
import logging
import math
import os
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import URLError
from urllib.parse import urlencode
from urllib.request import urlopen

HOST = os.getenv("BRIDGE_HOST", "127.0.0.1")
PORT = int(os.getenv("BRIDGE_PORT", "8080"))
VM_URL = os.getenv("VICTORIAMETRICS_URL", "http://127.0.0.1:8428").rstrip("/")
MAX_TELEMETRY_AGE = int(os.getenv("MAX_TELEMETRY_AGE_SECONDS", "45"))
EXPECTED_PEERS = {"10.12.0.1", "10.12.0.2"}

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
log = logging.getLogger("phase3-bridge")


class RejectedSignal(ValueError):
    """The alert or telemetry did not meet safety requirements."""


def parse_timestamp(value):
    if not isinstance(value, str) or not value:
        raise RejectedSignal("missing timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError("timezone missing")
        return parsed.timestamp()
    except ValueError as exc:
        raise RejectedSignal("invalid timestamp") from exc


def validate_alert_payload(payload, now=None):
    """Return the one authorized alert or reject the webhook."""
    if not isinstance(payload, dict) or not isinstance(payload.get("alerts"), list):
        raise RejectedSignal("missing alerts list")

    matches = []
    for alert in payload["alerts"]:
        if not isinstance(alert, dict):
            continue
        labels = alert.get("labels")
        if not isinstance(labels, dict):
            continue
        if labels.get("alertname") == "SpareboxLink12Degraded":
            matches.append(alert)

    if len(matches) != 1:
        raise RejectedSignal("expected exactly one SpareboxLink12Degraded alert")

    alert = matches[0]
    labels = alert.get("labels", {})

    if alert.get("status") != "firing":
        raise RejectedSignal("alert is not firing")

    required = {
        "link": "link12",
        "automation": "phase3-recovery",
        "service": "sparebox-web",
    }
    for key, expected in required.items():
        if labels.get(key) != expected:
            raise RejectedSignal(f"unexpected alert label: {key}")

    started_at = parse_timestamp(alert.get("startsAt"))
    now = time.time() if now is None else now
    if started_at > now + 5:
        raise RejectedSignal("alert timestamp is in the future")

    # This version deliberately observes signals only. It does not perform
    # deduplication or recovery; those are separate implementation stages.
    return alert


def validate_peer_snapshot(value_results, timestamp_results, now=None,
                           max_age=MAX_TELEMETRY_AGE):
    """Require both expected peer samples to be present and fresh."""
    now = time.time() if now is None else now

    def index_results(results, value_index, kind):
        indexed = {}
        for item in results:
            if not isinstance(item, dict):
                raise RejectedSignal(f"malformed {kind} result")
            metric = item.get("metric")
            if not isinstance(metric, dict):
                raise RejectedSignal(f"malformed {kind} metric labels")
            peer = metric.get("peer")
            values = item.get("value")
            if peer not in EXPECTED_PEERS or not isinstance(values, list) or len(values) < 2:
                raise RejectedSignal(f"unexpected {kind} series")
            if peer in indexed:
                raise RejectedSignal(f"duplicate {kind} series for {peer}")
            try:
                parsed = float(values[value_index])
            except (TypeError, ValueError) as exc:
                raise RejectedSignal(f"invalid {kind} value") from exc
            if not math.isfinite(parsed):
                raise RejectedSignal(f"non-finite {kind} value")
            indexed[peer] = parsed
        if set(indexed) != EXPECTED_PEERS:
            raise RejectedSignal(f"expected both link12 peers in {kind} results")
        return indexed

    values = index_results(value_results, 1, "peer")
    timestamps = index_results(timestamp_results, 1, "timestamp")

    for peer, sample_time in timestamps.items():
        age = now - sample_time
        if age < -5:
            raise RejectedSignal(f"future-dated telemetry for {peer}")
        if age > max_age:
            raise RejectedSignal(f"stale telemetry for {peer}")

    if any(value not in (0.0, 1.0) for value in values.values()):
        raise RejectedSignal("peer metric must be 0 or 1")

    if not any(value == 0.0 for value in values.values()):
        raise RejectedSignal("alert does not match current peer state")

    return {
        "peer_count": len(values),
        "down_peers": sorted(peer for peer, value in values.items() if value == 0.0),
        "max_sample_age_seconds": round(max(now - t for t in timestamps.values()), 2),
    }


def query_vector(query):
    url = f"{VM_URL}/api/v1/query?{urlencode({'query': query, 'latency_offset': '1ms'})}"
    with urlopen(url, timeout=3) as response:
        body = json.loads(response.read())

    if not isinstance(body, dict):
        raise RuntimeError("VictoriaMetrics returned a malformed response")
    if body.get("status") != "success":
        raise RuntimeError("VictoriaMetrics query failed")

    data = body.get("data")
    if not isinstance(data, dict):
        raise RuntimeError("VictoriaMetrics response is missing data")
    results = data.get("result")
    if not isinstance(results, list):
        raise RuntimeError("VictoriaMetrics response is missing result series")
    return results


def read_link12_telemetry(now=None):
    selector = r'frr_bgp_peer_up{peer=~"10\\.12\\.0\\.[12]"}'
    values = query_vector(selector)
    timestamps = query_vector(f"timestamp({selector})")
    return validate_peer_snapshot(values, timestamps, now=now)


class Handler(BaseHTTPRequestHandler):
    server_version = "SpareboxPhase3Bridge/0.1"

    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def respond(self, status, body):
        encoded = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        if self.path in ("/healthz", "/readyz"):
            self.respond(200, {"status": "ok", "mode": "observe-only"})
        else:
            self.respond(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/alerts":
            self.respond(404, {"error": "not found"})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 1024 * 1024:
                raise RejectedSignal("invalid request size")
            try:
                payload = json.loads(self.rfile.read(length))
            except (json.JSONDecodeError, UnicodeDecodeError) as exc:
                raise RejectedSignal("invalid JSON payload") from exc
            alert = validate_alert_payload(payload)
            telemetry = read_link12_telemetry()

            result = {
                "accepted": True,
                "mode": "observe-only",
                "alert": alert["labels"]["alertname"],
                "telemetry": telemetry,
                "recovery_executed": False,
            }
            log.info("validated signal: %s", json.dumps(result))
            self.respond(202, result)

        except RejectedSignal as exc:
            log.warning("signal rejected: %s", exc)
            self.respond(400, {"accepted": False, "reason": str(exc)})
        except (URLError, TimeoutError, OSError, RuntimeError, ValueError) as exc:
            log.error("signal could not be verified: %s", type(exc).__name__)
            self.respond(503, {"accepted": False, "reason": "verification unavailable"})

    def log_message(self, fmt, *args):
        log.info("%s - %s", self.client_address[0], fmt % args)


class BridgeHTTPServer(ThreadingHTTPServer):
    # Avoid keeping the process alive solely for request worker threads.
    daemon_threads = True
    # Keep the listen backlog bounded.
    request_queue_size = 16


if __name__ == "__main__":
    log.info("starting in observe-only mode on %s:%s", HOST, PORT)
    BridgeHTTPServer((HOST, PORT), Handler).serve_forever()
