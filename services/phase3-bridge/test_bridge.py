import json
import unittest
from datetime import datetime, timezone
from unittest.mock import patch
from urllib.parse import parse_qs, urlparse

from bridge import (
    RejectedSignal,
    query_vector,
    validate_alert_payload,
    validate_peer_snapshot,
)

NOW = 1_800_000_000.0


def alert_payload(**overrides):
    labels = {
        "alertname": "SpareboxLink12Degraded",
        "link": "link12",
        "automation": "phase3-recovery",
        "service": "sparebox-web",
    }
    labels.update(overrides)
    return {
        "status": "firing",
        "alerts": [{
            "status": "firing",
            "labels": labels,
            "startsAt": "2026-10-17T10:00:00Z",
        }],
    }


def peer_results(values):
    return [
        {"metric": {"peer": peer}, "value": [NOW, str(value)]}
        for peer, value in values.items()
    ]


def timestamp_results(timestamps):
    return [
        {"metric": {"peer": peer}, "value": [NOW, str(ts)]}
        for peer, ts in timestamps.items()
    ]


class AlertValidationTests(unittest.TestCase):
    def test_accepts_exact_firing_alert(self):
        alert = validate_alert_payload(alert_payload())
        self.assertEqual(alert["labels"]["link"], "link12")

    def test_rejects_resolved_alert(self):
        payload = alert_payload()
        payload["alerts"][0]["status"] = "resolved"
        with self.assertRaises(RejectedSignal):
            validate_alert_payload(payload)

    def test_rejects_wrong_link(self):
        with self.assertRaises(RejectedSignal):
            validate_alert_payload(alert_payload(link="link23"))

    def test_rejects_wrong_automation_label(self):
        with self.assertRaises(RejectedSignal):
            validate_alert_payload(alert_payload(automation="other"))

    def test_rejects_duplicate_target_alerts(self):
        payload = alert_payload()
        payload["alerts"].append(payload["alerts"][0])
        with self.assertRaises(RejectedSignal):
            validate_alert_payload(payload)

    def test_rejects_missing_alerts(self):
        with self.assertRaises(RejectedSignal):
            validate_alert_payload({})

    def test_rejects_future_alert_timestamp(self):
        payload = alert_payload()
        payload["alerts"][0]["startsAt"] = datetime.fromtimestamp(
            NOW + 60, timezone.utc
        ).isoformat()
        with self.assertRaises(RejectedSignal):
            validate_alert_payload(payload, now=NOW)


class TelemetryValidationTests(unittest.TestCase):
    def setUp(self):
        self.values = peer_results({"10.12.0.1": 0, "10.12.0.2": 1})
        self.timestamps = timestamp_results({
            "10.12.0.1": NOW - 10,
            "10.12.0.2": NOW - 15,
        })

    def test_accepts_fresh_snapshot_with_one_peer_down(self):
        result = validate_peer_snapshot(
            self.values, self.timestamps, now=NOW, max_age=45
        )
        self.assertEqual(result["down_peers"], ["10.12.0.1"])
        self.assertEqual(result["peer_count"], 2)

    def test_rejects_missing_peer(self):
        with self.assertRaises(RejectedSignal):
            validate_peer_snapshot(
                self.values[:1], self.timestamps, now=NOW, max_age=45
            )

    def test_rejects_stale_telemetry(self):
        stale = timestamp_results({
            "10.12.0.1": NOW - 100,
            "10.12.0.2": NOW - 10,
        })
        with self.assertRaises(RejectedSignal):
            validate_peer_snapshot(self.values, stale, now=NOW, max_age=45)

    def test_rejects_alert_when_both_peers_are_up(self):
        values = peer_results({"10.12.0.1": 1, "10.12.0.2": 1})
        with self.assertRaises(RejectedSignal):
            validate_peer_snapshot(values, self.timestamps, now=NOW)

    def test_rejects_future_dated_sample(self):
        future = timestamp_results({
            "10.12.0.1": NOW + 30,
            "10.12.0.2": NOW - 10,
        })
        with self.assertRaises(RejectedSignal):
            validate_peer_snapshot(self.values, future, now=NOW)

    def test_rejects_unexpected_metric_value(self):
        values = peer_results({"10.12.0.1": 2, "10.12.0.2": 1})
        with self.assertRaises(RejectedSignal):
            validate_peer_snapshot(values, self.timestamps, now=NOW)

    def test_rejects_duplicate_peer_series(self):
        values = self.values + [self.values[0]]
        with self.assertRaises(RejectedSignal):
            validate_peer_snapshot(values, self.timestamps, now=NOW)

    def test_rejects_malformed_metric_labels(self):
        values = [
            {"metric": None, "value": [NOW, "0"]},
            self.values[1],
        ]
        with self.assertRaises(RejectedSignal):
            validate_peer_snapshot(values, self.timestamps, now=NOW)

    def test_rejects_nan_peer_value(self):
        values = peer_results({"10.12.0.1": "nan", "10.12.0.2": 1})
        with self.assertRaises(RejectedSignal):
            validate_peer_snapshot(values, self.timestamps, now=NOW)

    def test_rejects_infinite_peer_value(self):
        values = peer_results({"10.12.0.1": "inf", "10.12.0.2": 1})
        with self.assertRaises(RejectedSignal):
            validate_peer_snapshot(values, self.timestamps, now=NOW)

    def test_rejects_non_finite_sample_timestamp(self):
        timestamps = timestamp_results({
            "10.12.0.1": "nan",
            "10.12.0.2": NOW - 10,
        })
        with self.assertRaises(RejectedSignal):
            validate_peer_snapshot(self.values, timestamps, now=NOW)



class QueryVectorTests(unittest.TestCase):
    @patch("bridge.urlopen")
    def test_queries_use_one_millisecond_latency_offset(self, mock_urlopen):
        response = mock_urlopen.return_value.__enter__.return_value
        response.read.return_value = json.dumps({
            "status": "success",
            "data": {"resultType": "vector", "result": []},
        }).encode()

        peer_query = r'frr_bgp_peer_up{peer=~"10\\.12\\.0\\.[12]"}'
        timestamp_query = f"timestamp({peer_query})"

        query_vector(peer_query)
        query_vector(timestamp_query)

        self.assertEqual(mock_urlopen.call_count, 2)
        for call in mock_urlopen.call_args_list:
            params = parse_qs(urlparse(call.args[0]).query)
            self.assertEqual(params["latency_offset"], ["1ms"])

        self.assertEqual(
            parse_qs(urlparse(mock_urlopen.call_args_list[0].args[0]).query)["query"],
            [peer_query],
        )
        self.assertEqual(
            parse_qs(urlparse(mock_urlopen.call_args_list[1].args[0]).query)["query"],
            [timestamp_query],
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
