#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 START_UTC END_UTC [OUTPUT.json]" >&2
  echo "Example: $0 2026-10-14T15:17:50Z 2026-10-14T15:19:10Z" >&2
  exit 2
fi

START="$1"
END="$2"
VM_URL="${VM_URL:-http://127.0.0.1:8428}"
NAMESPACE="${NAMESPACE:-gitops-test}"
DEPLOYMENT="${DEPLOYMENT:-sparebox-web}"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="${SCRIPT_DIR}${PYTHONPATH:+:${PYTHONPATH}}"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${3:-/tmp/sparebox-phase3-timeline-${STAMP}.json}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$START" "$END" <<'PY'
import sys
from datetime import datetime

try:
    start, end = [datetime.fromisoformat(x.replace("Z", "+00:00"))
                  for x in sys.argv[1:3]]
    if start.tzinfo is None or end.tzinfo is None or start >= end:
        raise ValueError("timestamps must be timezone-aware and START < END")
except ValueError as e:
    print(f"Invalid time window: {e}", file=sys.stderr)
    raise SystemExit(2)
PY

query_range() {
  local query="$1"
  local output="$2"

  curl -fsS --max-time 15 -G "$VM_URL/api/v1/query_range" \
    --data-urlencode "query=$query" \
    --data-urlencode "start=$START" \
    --data-urlencode "end=$END" \
    --data-urlencode 'step=5s' \
    --data-urlencode 'latency_offset=1s' > "$output"
}

echo "Querying historical telemetry (read-only)..."

query_range \
  'frr_bgp_peer_up{peer=~"10.12.0.1|10.12.0.2"}' \
  "$TMP/bgp.json"

query_range \
  'timestamp(frr_bgp_peer_up{peer=~"10.12.0.1|10.12.0.2"})' \
  "$TMP/bgp-timestamps.json"

query_range \
  'probe_success{job="sparebox-web"}' \
  "$TMP/probe.json"

query_range \
  'timestamp(probe_success{job="sparebox-web"})' \
  "$TMP/probe-timestamps.json"

kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o json \
  > "$TMP/deployment.json"

kubectl get pods -n "$NAMESPACE" -l app=sparebox-web -o json \
  > "$TMP/pods.json"

mkdir -p "$(dirname "$OUT")"

python3 - "$TMP" "$OUT" "$START" "$END" "$VM_URL" "$NAMESPACE" "$DEPLOYMENT" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

tmp, output, start, end, vm_url, namespace, deployment_name = sys.argv[1:]

def load(name):
    with open(os.path.join(tmp, name), encoding="utf-8") as f:
        return json.load(f)

def results(doc, name):
    if doc.get("status") != "success":
        raise RuntimeError(f"VictoriaMetrics query failed: {name}")
    return doc.get("data", {}).get("result", [])

def label_key(metric):
    return tuple(sorted((k, v) for k, v in metric.items()
                        if k != "__name__"))

def extract_samples(value_doc, timestamp_doc, value_name, timestamp_name):
    values = results(value_doc, value_name)
    timestamps = results(timestamp_doc, timestamp_name)

    ts_by_series = {
        label_key(s.get("metric", {})): {
            float(eval_ts): float(sample_ts)
            for eval_ts, sample_ts in s.get("values", [])
        }
        for s in timestamps
    }

    output_samples = []
    for series in values:
        labels = series.get("metric", {})
        key = label_key(labels)
        timestamp_map = ts_by_series.get(key, {})
        seen = set()

        for eval_ts, value in series.get("values", []):
            sample_ts = timestamp_map.get(float(eval_ts))
            if sample_ts is None or sample_ts in seen:
                continue
            seen.add(sample_ts)
            output_samples.append({
                "sample_time_utc": datetime.fromtimestamp(
                    sample_ts, timezone.utc
                ).isoformat(),
                "sample_timestamp": sample_ts,
                "evaluation_value": float(value),
                "labels": labels,
            })

    return sorted(output_samples, key=lambda x: x["sample_timestamp"])

bgp_samples = extract_samples(
    load("bgp.json"), load("bgp-timestamps.json"),
    "BGP", "BGP sample timestamps"
)
probe_samples = extract_samples(
    load("probe.json"), load("probe-timestamps.json"),
    "application probe", "probe sample timestamps"
)

# Range queries use lookback at their start boundary. Keep only actual
# samples whose underlying timestamps fall inside the requested window.
start_epoch = datetime.fromisoformat(start.replace("Z", "+00:00")).timestamp()
end_epoch = datetime.fromisoformat(end.replace("Z", "+00:00")).timestamp()

bgp_samples = [
    sample for sample in bgp_samples
    if start_epoch <= sample["sample_timestamp"] <= end_epoch
]
probe_samples = [
    sample for sample in probe_samples
    if start_epoch <= sample["sample_timestamp"] <= end_epoch
]

# Data-quality checks describe sample coverage, not continuous availability.
from timeline_quality import build_quality_report

MAX_SAMPLE_GAP_SECONDS = 30
EXPECTED_LINK12_SERIES = {
    ("r1-2", "10.12.0.2"),
    ("r2-1", "10.12.0.1"),
}
link12_series_samples = {
    f"bgp_peer_{router}_{peer}": [
        sample for sample in bgp_samples
        if (
            sample.get("labels", {}).get("router"),
            sample.get("labels", {}).get("peer"),
        ) == (router, peer)
    ]
    for router, peer in EXPECTED_LINK12_SERIES
}
data_quality = build_quality_report(
    {
        "fabric": bgp_samples,
        "application_probe": probe_samples,
        **link12_series_samples,
    },
    start_epoch,
    end_epoch,
    max_gap_seconds=MAX_SAMPLE_GAP_SECONDS,
)

def transitions(samples, state_key):
    by_series = {}
    for sample in samples:
        labels = sample["labels"]
        key = tuple(sorted((k, v) for k, v in labels.items()
                           if k != "__name__"))
        by_series.setdefault(key, []).append(sample)

    output = []
    for series in by_series.values():
        previous = object()
        for sample in series:
            value = sample["evaluation_value"]
            if value != previous:
                output.append({
                    "time_utc": sample["sample_time_utc"],
                    "labels": sample["labels"],
                    state_key: value,
                })
                previous = value
    return sorted(output, key=lambda x: x["time_utc"])

deployment = load("deployment.json")
pods_doc = load("pods.json")
status = deployment.get("status", {})

pods = []
for pod in pods_doc.get("items", []):
    pstatus = pod.get("status", {})
    ready = any(
        c.get("type") == "Ready" and c.get("status") == "True"
        for c in pstatus.get("conditions", [])
    )
    pods.append({
        "name": pod.get("metadata", {}).get("name", "?"),
        "phase": pstatus.get("phase", "Unknown"),
        "ready": ready,
        "node": pod.get("spec", {}).get("nodeName", "?"),
        "restarts": sum(
            c.get("restartCount", 0)
            for c in pstatus.get("containerStatuses", [])
        ),
    })

report = {
    "generated_at_utc": datetime.now(timezone.utc).isoformat(),
    "mode": "read-only historical telemetry correlation",
    "window": {"start_utc": start, "end_utc": end},
    "sampling": {
        "query_evaluation_step_seconds": 5,
        "maximum_expected_gap_seconds": MAX_SAMPLE_GAP_SECONDS,
        "note": (
            "Events use underlying metric sample timestamps where available. "
            "Samples are not continuous observations; scrape cadence and "
            "collection delay limit timing precision. Gap checks use distinct "
            "sample timestamps and do not prove continuous availability."
        ),
    },
    "data_quality": data_quality,
    "fabric": {
        "metric": "frr_bgp_peer_up",
        "samples": bgp_samples,
        "transitions": transitions(bgp_samples, "up"),
    },
    "application_probe": {
        "metric": 'probe_success{job="sparebox-web"}',
        "samples": probe_samples,
        "transitions": transitions(probe_samples, "success"),
    },
    "kubernetes_current_snapshot": {
        "snapshot_time_utc": datetime.now(timezone.utc).isoformat(),
        "namespace": namespace,
        "deployment": deployment_name,
        "desired_replicas": deployment.get("spec", {}).get("replicas", 0),
        "ready_replicas": status.get("readyReplicas", 0),
        "available_replicas": status.get("availableReplicas", 0),
        "pods": pods,
        "historical_pod_state_available": False,
    },
}

with open(output, "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2)
    f.write("\n")

print("\n=== Historical correlation ===")
print(f"Window: {start} -> {end}")
print(f"BGP samples: {len(bgp_samples)}")
for event in report["fabric"]["transitions"]:
    labels = event["labels"]
    print("  BGP", event["time_utc"],
          "router=" + labels.get("router", "?"),
          "peer=" + labels.get("peer", "?"),
          "up=" + str(int(event["up"])))

print(f"Application probe samples: {len(probe_samples)}")
for name, check in data_quality["checks"].items():
    gap = check["max_observed_gap_seconds"]
    gap_text = "n/a" if gap is None else f"{gap:.1f}s"
    print(
        f"Data quality ({name}): samples={check['sample_count']}, "
        f"distinct_times={check['distinct_sample_timestamps']}, "
        f"max_gap={gap_text}, trend_adequate={check['adequate_for_trend']}"
    )
for warning in data_quality["warnings"]:
    print("WARNING:", warning)

for event in report["application_probe"]["transitions"]:
    print("  Probe", event["time_utc"],
          "success=" + str(int(event["success"])))

k = report["kubernetes_current_snapshot"]
print("\n=== Kubernetes current snapshot (NOT historical) ===")
print(f"Deployment replicas: {k['ready_replicas']}/{k['desired_replicas']} ready")
for pod in pods:
    print(" ", pod["name"], pod["phase"],
          "ready=" + str(pod["ready"]),
          "node=" + pod["node"],
          "restarts=" + str(pod["restarts"]))

print("\nReport written:", output)

# Preserve the report, but signal incomplete evidence to callers.
missing_sources = [
    name for name, check in data_quality["checks"].items()
    if check["sample_count"] == 0
]
if missing_sources:
    print(
        "ERROR: insufficient telemetry; no samples for: "
        + ", ".join(missing_sources),
        file=sys.stderr,
    )
    raise SystemExit(2)
PY
