#!/usr/bin/env bash
set -Eeuo pipefail

VM_URL="${VM_URL:-http://127.0.0.1:8428}"
NAMESPACE="${NAMESPACE:-gitops-test}"
DEPLOYMENT="${DEPLOYMENT:-sparebox-web}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${1:-/tmp/sparebox-phase3-observation-${STAMP}.json}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Phase 3 observation — read-only"
echo "VictoriaMetrics: $VM_URL"
echo "Kubernetes:      $NAMESPACE/$DEPLOYMENT"
echo "Report:          $OUT"
echo

curl -fsS --max-time 5 -G "$VM_URL/api/v1/query" \
  --data-urlencode 'query=frr_bgp_peer_up' \
  --data-urlencode 'latency_offset=1s' \
  > "$TMP/bgp.json"

curl -fsS --max-time 5 -G "$VM_URL/api/v1/query" \
  --data-urlencode 'query=probe_success{job="sparebox-web"}' \
  --data-urlencode 'latency_offset=1s' \
  > "$TMP/probe.json"

kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o json \
  > "$TMP/deployment.json"

kubectl get pods -n "$NAMESPACE" -l app=sparebox-web -o json \
  > "$TMP/pods.json"

mkdir -p "$(dirname "$OUT")"

python3 - "$TMP" "$OUT" "$STAMP" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

tmp, output, stamp = sys.argv[1:4]

def load(name):
    with open(os.path.join(tmp, name), encoding="utf-8") as f:
        return json.load(f)

bgp = load("bgp.json")
probe = load("probe.json")
deployment = load("deployment.json")
pods_doc = load("pods.json")

def results(document):
    if document.get("status") != "success":
        raise RuntimeError("VictoriaMetrics returned a non-success response")
    return document.get("data", {}).get("result", [])

peers = results(bgp)
peer_states = []
for item in peers:
    metric = item.get("metric", {})
    value = item.get("value", [])
    valid = len(value) > 1 and value[1] in ("0", "1")
    up = valid and value[1] == "1"
    peer_states.append({
        "router": metric.get("router", "?"),
        "peer": metric.get("peer", "?"),
        "up": up,
        "status": (
            "healthy" if up
            else "failed" if valid
            else "unknown"
        ),
        "evidence_valid": valid,
    })

probes = results(probe)
# The expected job should produce exactly one series. Missing, duplicate,
# or malformed results are unknown evidence, never a successful probe.
probe_value_valid = (
    len(probes) == 1
    and len(probes[0].get("value", [])) > 1
    and probes[0]["value"][1] in ("0", "1")
)
probe_up = probe_value_valid and probes[0]["value"][1] == "1"
probe_status = (
    "healthy" if probe_up
    else "failed" if probe_value_valid
    else "unknown"
)

spec_replicas = deployment.get("spec", {}).get("replicas", 0)
status = deployment.get("status", {})
ready_replicas = status.get("readyReplicas", 0)
available_replicas = status.get("availableReplicas", 0)

pod_states = []
for pod in pods_doc.get("items", []):
    conditions = pod.get("status", {}).get("conditions", [])
    ready = any(
        c.get("type") == "Ready" and c.get("status") == "True"
        for c in conditions
    )
    pod_states.append({
        "name": pod.get("metadata", {}).get("name", "?"),
        "phase": pod.get("status", {}).get("phase", "Unknown"),
        "ready": ready,
        "node": pod.get("spec", {}).get("nodeName", "?"),
        "restarts": sum(
            c.get("restartCount", 0)
            for c in pod.get("status", {}).get("containerStatuses", [])
        ),
    })

fabric_ok = bool(peer_states) and all(
    p["status"] == "healthy" for p in peer_states
)
deployment_ok = (
    spec_replicas > 0
    and ready_replicas == spec_replicas
    and available_replicas == spec_replicas
)
pods_ok = (
    len(pod_states) == spec_replicas
    and all(p["phase"] == "Running" and p["ready"] for p in pod_states)
)

report = {
    "observed_at_utc": datetime.now(timezone.utc).isoformat(),
    "mode": "read-only",
    "no_faults_injected": True,
    "no_kubernetes_resources_modified": True,
    "fabric": {
        "metric": "frr_bgp_peer_up",
        "peer_series_count": len(peer_states),
        "peers_up": sum(p["status"] == "healthy" for p in peer_states),
        "peers_down": [p for p in peer_states if p["status"] == "failed"],
        "peers_unknown": [p for p in peer_states if p["status"] == "unknown"],
        "healthy": fabric_ok,
    },
    "application_probe": {
        "metric": 'probe_success{job="sparebox-web"}',
        "series_count": len(probes),
        "success": probe_up,
        "status": probe_status,
        "evidence_valid": probe_value_valid,
    },
    "kubernetes": {
        "namespace": deployment.get("metadata", {}).get("namespace"),
        "deployment": deployment.get("metadata", {}).get("name"),
        "desired_replicas": spec_replicas,
        "ready_replicas": ready_replicas,
        "available_replicas": available_replicas,
        "pods": pod_states,
        "healthy": deployment_ok and pods_ok,
    },
    "overall_healthy": fabric_ok and probe_up and deployment_ok and pods_ok,
}

with open(output, "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2)
    f.write("\n")

print("Fabric peers: {}/{} up".format(
    report["fabric"]["peers_up"], report["fabric"]["peer_series_count"]))
print("Application probe:", "PASS" if probe_up else "FAIL")
print("Deployment replicas: {}/{}".format(ready_replicas, spec_replicas))
print("Pod readiness:", "PASS" if pods_ok else "FAIL")
print("Overall observation:", "HEALTHY" if report["overall_healthy"] else "DEGRADED")
print("Report written:", output)

if not report["overall_healthy"]:
    sys.exit(1)
PY
