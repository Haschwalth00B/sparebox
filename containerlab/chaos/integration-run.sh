#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

INJECT="$ROOT/containerlab/chaos/inject.sh"
CHECK="$ROOT/containerlab/chaos/integration-check.sh"
TIMELINE="$ROOT/containerlab/chaos/integration-timeline.sh"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
VM_URL="${VM_URL:-http://127.0.0.1:8428}"
NAMESPACE="gitops-test"
DEPLOYMENT="sparebox-web"
SELECTOR="app=sparebox-web"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="/tmp/sparebox-phase3-run-${STAMP}"
CHAOS_NAME="sparebox-phase3-pod-kill-${STAMP,,}"
FAULT_ATTEMPTED=0
FAULT_PID=""
FAULT_PGID=""
CHAOS_MAY_EXIST=0
START_UTC=""
END_UTC=""

usage() {
    cat <<EOF
Usage:
  $0 --execute

Without --execute, this runner refuses to inject a fault.
It targets only link12 and the gitops-test/sparebox-web workload.
Evidence is written to: $OUT_DIR
EOF
}

if [[ "${1:-}" != "--execute" || $# -ne 1 ]]; then
    usage
    exit 2
fi

mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/run.log"
exec > >(tee -a "$LOG") 2>&1

cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    set +e

    echo
    echo "=== SAFETY CLEANUP (exit=$rc) ==="

    # Explicitly restore the link before signalling the timed injector.
    # The injector also has a heal trap; its heal operations are idempotent.
    if (( FAULT_ATTEMPTED )); then
        "$INJECT" heal link-down link12 || true
    fi

    # Remove temporary Kubernetes chaos promptly; do not wait on the injector first.
    # Keep cleanup armed unless deletion and absence verification both succeed.
    if (( CHAOS_MAY_EXIST )); then
        if kubectl delete podchaos "$CHAOS_NAME" \
            -n "$NAMESPACE" --ignore-not-found \
            --wait=true --timeout=20s; then
            if remaining="$(kubectl get podchaos "$CHAOS_NAME" \
                -n "$NAMESPACE" --ignore-not-found -o name)"; then
                if [[ -z "$remaining" ]]; then
                    CHAOS_MAY_EXIST=0
                    echo "PASS: temporary PodChaos deletion verified."
                else
                    echo "ERROR: temporary PodChaos still exists: $remaining" >&2
                fi
            else
                echo "ERROR: could not verify temporary PodChaos deletion." >&2
            fi
        else
            echo "ERROR: PodChaos deletion failed; manual cleanup may be required." >&2
        fi
    fi

    # Job control gives the injector an isolated process group.
    # Signal that group so its timer child cannot keep cleanup blocked.
    if [[ -n "$FAULT_PID" && "$FAULT_PGID" == "$FAULT_PID" ]]; then
        kill -TERM -- "-$FAULT_PGID" 2>/dev/null || true
        wait "$FAULT_PID" 2>/dev/null || true
    elif [[ -n "$FAULT_PID" ]]; then
        echo "WARNING: no verified injector process group; not sending a group signal."
    fi
    FAULT_PID=""
    FAULT_PGID=""

    if (( FAULT_ATTEMPTED )); then
        "$INJECT" heal link-down link12
        "$INJECT" wait-converged 120
    fi

    echo "Evidence directory: $OUT_DIR"
    exit "$rc"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM


echo "=== Sparebox Phase 3 integration run ==="
echo "Started UTC: $STAMP"
echo "Evidence:    $OUT_DIR"
echo "Target link: link12"
echo "Target app:  $NAMESPACE/$DEPLOYMENT"
echo

echo "=== 1. Baseline checks ==="
"$INJECT" preflight
"$INJECT" baseline
"$CHECK" "$OUT_DIR/baseline.json"

echo
echo "=== Verify both link12 BGP peers are initially UP and fresh ==="
PEER_QUERY='frr_bgp_peer_up{peer=~"10.12.0.1|10.12.0.2"}'

curl -fsS --max-time 5 -G "$VM_URL/api/v1/query" \
  --data-urlencode "query=$PEER_QUERY" \
  --data-urlencode 'latency_offset=1s' \
  > "$OUT_DIR/bgp-baseline.json"
curl -fsS --max-time 5 -G "$VM_URL/api/v1/query" \
  --data-urlencode "query=timestamp($PEER_QUERY)" \
  --data-urlencode 'latency_offset=1s' \
  > "$OUT_DIR/bgp-baseline-timestamps.json"

python3 - "$OUT_DIR/bgp-baseline.json" \
  "$OUT_DIR/bgp-baseline-timestamps.json" <<'PYBASE'
import json, math, sys, time

expected = {"10.12.0.1", "10.12.0.2"}

def load_series(path):
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)
    if doc.get("status") != "success":
        raise SystemExit(f"ERROR: telemetry query failed: {path}")
    by_peer = {}
    for item in doc.get("data", {}).get("result", []):
        peer = item.get("metric", {}).get("peer")
        sample = item.get("value", [])
        if peer not in expected or peer in by_peer:
            raise SystemExit(f"ERROR: unexpected/duplicate peer series: {peer}")
        if len(sample) < 2:
            raise SystemExit(f"ERROR: malformed sample for {peer}")
        by_peer[peer] = sample[1]
    if set(by_peer) != expected:
        raise SystemExit(f"ERROR: expected both peers; found {sorted(by_peer)}")
    return by_peer

states = load_series(sys.argv[1])
raw_timestamps = load_series(sys.argv[2])
try:
    timestamps = {peer: float(value) for peer, value in raw_timestamps.items()}
except (TypeError, ValueError):
    raise SystemExit("ERROR: malformed underlying sample timestamp.")

now = time.time()
print("Baseline peer states:", states)
print("Underlying sample ages (seconds):",
      {peer: round(now - ts, 2) for peer, ts in timestamps.items()})

for peer in sorted(expected):
    if states[peer] != "1":
        raise SystemExit(f"ERROR: {peer} is not UP; refusing fault injection.")
    ts = timestamps[peer]
    if not math.isfinite(ts) or ts > now + 5 or now - ts > 30:
        raise SystemExit(f"ERROR: {peer} sample is stale or future-dated.")

print("PASS: both peers are UP with fresh underlying telemetry.")
PYBASE

kubectl get pods -n "$NAMESPACE" -l "$SELECTOR" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' |
  sort > "$OUT_DIR/pods-before.txt"

if [[ ! -s "$OUT_DIR/pods-before.txt" ]]; then
    echo "ERROR: no target pods found; refusing to continue." >&2
    exit 1
fi

START_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo
echo "=== 2. Inject link12 failure ==="
FAULT_ATTEMPTED=1
# Enable job control only for this launch, then verify the injector's real PGID.
set -m
"$INJECT" fail link-down link12 --for 90 \
  > "$OUT_DIR/inject.log" 2>&1 &
FAULT_PID=$!
set +m
sleep 1

if ! kill -0 "$FAULT_PID" 2>/dev/null; then
    cat "$OUT_DIR/inject.log"
    echo "ERROR: timed fault injector exited early." >&2
    exit 1
fi

FAULT_PGID="$(ps -o pgid= -p "$FAULT_PID" | tr -d '[:space:]')"
if [[ -z "$FAULT_PGID" || "$FAULT_PGID" != "$FAULT_PID" ]]; then
    echo "ERROR: injector process group could not be verified safely." >&2
    echo "Injector PID=$FAULT_PID; observed PGID=${FAULT_PGID:-unknown}" >&2
    echo "Refusing to signal any process group." >&2
    exit 1
fi
echo "Verified isolated injector process group: PID=$FAULT_PID PGID=$FAULT_PGID"

echo
echo "=== 3. Wait for fresh BGP-down telemetry ==="
echo "Polling for up to 48 seconds; no Kubernetes action until detected."

DETECTED=0
for attempt in $(seq 1 24); do
    if curl -fsS --max-time 5 -G "$VM_URL/api/v1/query" \
      --data-urlencode "query=$PEER_QUERY" \
  --data-urlencode 'latency_offset=1s' \
      > "$OUT_DIR/bgp-current.json" &&
      curl -fsS --max-time 5 -G "$VM_URL/api/v1/query" \
      --data-urlencode "query=timestamp($PEER_QUERY)" \
  --data-urlencode 'latency_offset=1s' \
      > "$OUT_DIR/bgp-current-timestamps.json" &&
      python3 - "$OUT_DIR/bgp-baseline.json" \
        "$OUT_DIR/bgp-baseline-timestamps.json" \
        "$OUT_DIR/bgp-current.json" \
        "$OUT_DIR/bgp-current-timestamps.json" <<'PYDETECT'
import json, math, sys, time

expected = {"10.12.0.1", "10.12.0.2"}

def load_series(path):
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)
    if doc.get("status") != "success":
        raise SystemExit(f"Telemetry query unsuccessful: {path}")
    by_peer = {}
    for item in doc.get("data", {}).get("result", []):
        peer = item.get("metric", {}).get("peer")
        sample = item.get("value", [])
        if peer not in expected or peer in by_peer:
            raise SystemExit(f"Unexpected or duplicate peer series: {peer}")
        if len(sample) < 2:
            raise SystemExit(f"Malformed sample for peer: {peer}")
        by_peer[peer] = sample[1]
    if set(by_peer) != expected:
        raise SystemExit(f"Incomplete peer series in {path}: {sorted(by_peer)}")
    return by_peer

baseline_state = load_series(sys.argv[1])
baseline_ts_raw = load_series(sys.argv[2])
current_state = load_series(sys.argv[3])
current_ts_raw = load_series(sys.argv[4])

try:
    baseline_ts = {p: float(v) for p, v in baseline_ts_raw.items()}
    current_ts = {p: float(v) for p, v in current_ts_raw.items()}
except (TypeError, ValueError):
    raise SystemExit("Malformed source timestamp.")

now = time.time()
for peer in sorted(expected):
    bt = baseline_ts[peer]
    ct = current_ts[peer]
    if baseline_state[peer] != "1":
        raise SystemExit(f"{peer}: baseline was not healthy.")
    if not math.isfinite(bt) or bt > now + 5:
        raise SystemExit(f"{peer}: baseline timestamp is invalid.")
    if not math.isfinite(ct) or ct > now + 5 or now - ct > 30:
        raise SystemExit(f"{peer}: current timestamp is stale/invalid.")
    if ct <= bt:
        raise SystemExit(f"{peer}: current sample is not newer than baseline.")

down = [peer for peer in sorted(expected) if current_state[peer] == "0"]
print("Current peer states:", current_state)
print("Current sample ages (seconds):",
      {p: round(now - current_ts[p], 2) for p in sorted(expected)})
print("Fresh down-state peers:", down)

if not down:
    raise SystemExit("No fresh BGP-down state observed.")
PYDETECT
    then
        DETECTED=1
        break
    fi

    sleep 2
done

if (( ! DETECTED )); then
    echo "ERROR: expected BGP-down telemetry was not verified." >&2
    echo "Refusing to trigger PodChaos."
    exit 1
fi

echo
echo "=== 4. Trigger one controlled pod-kill experiment ==="
echo "Creating temporary resource: $CHAOS_NAME"

# Set this before apply so cleanup also covers an interrupted apply.
CHAOS_MAY_EXIST=1
kubectl apply -f - <<EOF
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: ${CHAOS_NAME}
  namespace: ${NAMESPACE}
spec:
  action: pod-kill
  mode: one
  selector:
    namespaces:
      - ${NAMESPACE}
    labelSelectors:
      app: sparebox-web
EOF

echo
echo "=== 5. Verify pod replacement and capture Chaos Mesh status ==="
REPLACEMENT_SEEN=0
OLD_POD_GONE=0
NEW_READY_POD=""

for attempt in $(seq 1 30); do
    # Refresh target identity during polling; a not-yet-reported target is
    # not treated as success and does not stop the loop.
    if kubectl get podchaos "$CHAOS_NAME" -n "$NAMESPACE" -o json \
      > "$OUT_DIR/podchaos-status.json"; then
        :
    else
        : > "$OUT_DIR/podchaos-status.json"
    fi

    kubectl get pods -n "$NAMESPACE" -l "$SELECTOR" -o json \
      > "$OUT_DIR/pods-current.json"

    python3 - "$OUT_DIR/pods-before.txt" \
      "$OUT_DIR/pods-current.json" "$OUT_DIR/pods-current.txt" \
      "$OUT_DIR/pods-new-ready.txt" "$OUT_DIR/podchaos-status.json" \
      "$OUT_DIR/pods-target.txt" "$NAMESPACE" <<'PODCHECK'
import json, sys
from pathlib import Path

(before_path, current_path, names_path, ready_path,
 status_path, target_path, namespace) = sys.argv[1:]
with open(before_path, encoding="utf-8") as f:
    before = {line.strip() for line in f if line.strip()}
with open(current_path, encoding="utf-8") as f:
    doc = json.load(f)

items = doc.get("items", [])
with open(names_path, "w", encoding="utf-8") as f:
    f.writelines(sorted(
        item.get("metadata", {}).get("name", "") + "\n"
        for item in items if item.get("metadata", {}).get("name")
    ))

new_ready = []
for item in items:
    meta = item.get("metadata", {})
    status = item.get("status", {})
    name = meta.get("name", "")
    if name in before:
        continue
    ready = any(
        c.get("type") == "Ready" and c.get("status") == "True"
        for c in status.get("conditions", [])
    )
    if ready and status.get("phase") == "Running":
        new_ready.append(name)

with open(ready_path, "w", encoding="utf-8") as f:
    f.writelines(name + "\n" for name in sorted(new_ready))

current_names = {
    item.get("metadata", {}).get("name", "")
    for item in items
}

target_pod = ""
try:
    if Path(status_path).stat().st_size:
        status_doc = json.loads(Path(status_path).read_text(encoding="utf-8"))
        records = status_doc.get("status", {}).get("experiment", {}).get(
            "containerRecords", []
        )
        injected = []
        for record in records:
            try:
                count = int(record.get("injectedCount", 0) or 0)
            except (TypeError, ValueError):
                raise SystemExit("ERROR: malformed injectedCount in PodChaos status.")
            if count > 0:
                injected.append(record)

        if len(injected) > 1:
            raise SystemExit(
                f"ERROR: expected at most one injected target; found {len(injected)}."
            )
        if injected:
            target_id = injected[0].get("id", "")
            target_namespace, sep, target_pod = target_id.partition("/")
            if not sep or target_namespace != namespace or not target_pod:
                raise SystemExit(
                    f"ERROR: unexpected PodChaos target identity: {target_id!r}"
                )
except json.JSONDecodeError:
    # Status may be briefly unavailable while the resource is initializing.
    target_pod = ""

Path(target_path).write_text(
    target_pod + "\n" if target_pod else "", encoding="utf-8"
)

target_gone = bool(
    target_pod and target_pod in before and target_pod not in current_names
)
replacements = sorted(
    name for name in new_ready
    if name and name != target_pod and name not in before
    and name in current_names
)

print(f"Chaos Mesh target: {target_pod or 'not reported yet'}")
print(f"Target disappearance observed: {target_gone}")
print(f"New Running+Ready replacement candidates: {replacements}")

PODCHECK

    TARGET_POD="$(cat "$OUT_DIR/pods-target.txt")"
    NEW_READY_POD=""

    if [[ -s "$OUT_DIR/pods-new-ready.txt" ]]; then
        while IFS= read -r candidate; do
            [[ -n "$candidate" && "$candidate" != "$TARGET_POD" ]] || continue
            if grep -qxF "$candidate" "$OUT_DIR/pods-current.txt" &&
               ! grep -qxF "$candidate" "$OUT_DIR/pods-before.txt"; then
                NEW_READY_POD="$candidate"
                break
            fi
        done < "$OUT_DIR/pods-new-ready.txt"
    fi

    if [[ -n "$TARGET_POD" ]] &&
       grep -qxF "$TARGET_POD" "$OUT_DIR/pods-before.txt" &&
       ! grep -qxF "$TARGET_POD" "$OUT_DIR/pods-current.txt"; then
        OLD_POD_GONE=1
    fi

    if [[ -n "$NEW_READY_POD" && "$OLD_POD_GONE" -eq 1 ]]; then
        REPLACEMENT_SEEN=1
        echo "Injected target disappeared: $TARGET_POD"
        echo "Distinct replacement is Running and Ready: $NEW_READY_POD"
        break
    fi

    sleep 2
done

# Preserve the resource status before deleting the experiment.
if kubectl get podchaos "$CHAOS_NAME" -n "$NAMESPACE" -o json \
  > "$OUT_DIR/podchaos-status.json"; then
    python3 - "$OUT_DIR/podchaos-status.json" <<'PODSTATUS'
import json, sys

with open(sys.argv[1], encoding="utf-8") as f:
    doc = json.load(f)

status = doc.get("status", {})
print("Chaos Mesh experiment status:", status.get("experiment", "not reported"))
for condition in status.get("conditions", []):
    print(
        "Condition:",
        condition.get("type", "?"),
        "=",
        condition.get("status", "?"),
        condition.get("reason", ""),
    )
PODSTATUS
else
    echo "WARNING: could not capture PodChaos status; see run.log."
fi

if (( ! REPLACEMENT_SEEN || ! OLD_POD_GONE )); then
    echo "ERROR: replacement evidence incomplete; see saved pod snapshots." >&2
    exit 1
fi

# Verify the exact pod recorded as injected by Chaos Mesh disappeared.
# Deployment recovery and Chaos Mesh AllRecovered are separate signals.
if [[ ! -s "$OUT_DIR/podchaos-status.json" ]]; then
    echo "ERROR: PodChaos status evidence is missing; cannot verify target identity." >&2
    exit 1
fi

python3 - "$OUT_DIR/podchaos-status.json" \
  "$OUT_DIR/pods-before.txt" "$OUT_DIR/pods-current.json" \
  "$OUT_DIR/pods-new-ready.txt" "$NAMESPACE" <<'PODTARGET'
import json, sys

status_path, before_path, current_path, ready_path, namespace = sys.argv[1:]

def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(
            f"ERROR: cannot read valid JSON evidence from {path}: {exc}"
        )

with open(before_path, encoding="utf-8") as f:
    before = {line.strip() for line in f if line.strip()}

current_doc = read_json(current_path)
current = {
    item.get("metadata", {}).get("name", "")
    for item in current_doc.get("items", [])
}
with open(ready_path, encoding="utf-8") as f:
    new_ready = {line.strip() for line in f if line.strip()}

doc = read_json(status_path)
records = doc.get("status", {}).get("experiment", {}).get("containerRecords", [])
def injected_count(record):
    try:
        return int(record.get("injectedCount", 0) or 0)
    except (TypeError, ValueError):
        raise SystemExit(
            "ERROR: malformed injectedCount in PodChaos status evidence."
        )

injected = [
    record for record in records
    if injected_count(record) > 0
]
if len(injected) != 1:
    raise SystemExit(
        f"ERROR: expected exactly one injected PodChaos target; found {len(injected)}."
    )

target_id = injected[0].get("id", "")
target_namespace, sep, target_pod = target_id.partition("/")
if not sep or target_namespace != namespace or not target_pod:
    raise SystemExit(f"ERROR: unexpected PodChaos target identity: {target_id!r}")

if target_pod not in before:
    raise SystemExit(
        f"ERROR: injected target {target_pod} was not present in the baseline."
    )
if target_pod in current:
    raise SystemExit(
        f"ERROR: injected target {target_pod} is still present in the current snapshot."
    )

replacements = sorted(
    name for name in new_ready
    if name and name != target_pod and name in current and name not in before
)
if not replacements:
    raise SystemExit(
        "ERROR: no distinct new Running+Ready pod was verified in the current snapshot."
    )

print(f"PASS: Chaos Mesh injected target disappeared: {target_id}")
print(f"PASS: distinct new Running+Ready pod(s): {', '.join(replacements)}")

conditions = {
    item.get("type"): item.get("status")
    for item in doc.get("status", {}).get("conditions", [])
}
if conditions.get("AllRecovered") != "True":
    print(
        "NOTE: Chaos Mesh AllRecovered is not True "
        f"(observed {conditions.get('AllRecovered', 'not reported')}). "
        "Do not report this condition as successful; assess Kubernetes "
        "Deployment recovery separately."
    )
PODTARGET

echo "=== 6. Remove the temporary PodChaos resource ==="
kubectl delete podchaos "$CHAOS_NAME" -n "$NAMESPACE" \
  --ignore-not-found --wait=true --timeout=20s
if remaining="$(kubectl get podchaos "$CHAOS_NAME" \
    -n "$NAMESPACE" --ignore-not-found -o name)"; then
    if [[ -n "$remaining" ]]; then
        echo "ERROR: temporary PodChaos still exists: $remaining" >&2
        exit 1
    fi
else
    echo "ERROR: could not verify temporary PodChaos deletion." >&2
    exit 1
fi
CHAOS_MAY_EXIST=0
echo "PASS: temporary PodChaos deletion verified."

echo
echo "=== 7. Verify Kubernetes recovery ==="
kubectl rollout status "deployment/$DEPLOYMENT" \
  -n "$NAMESPACE" --timeout=90s

kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o json \
  > "$OUT_DIR/deployment-after.json"
python3 - "$OUT_DIR/deployment-after.json" <<'PYDEP'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    deployment = json.load(f)

spec = deployment.get("spec", {})
status = deployment.get("status", {})
desired = spec.get("replicas", 1)
ready = status.get("readyReplicas", 0)
available = status.get("availableReplicas", 0)
print(f"Deployment replicas: desired={desired}, ready={ready}, available={available}")
if desired != 2 or ready != desired or available != desired:
    raise SystemExit("ERROR: Deployment has not returned to 2/2 available.")
PYDEP

kubectl get pods -n "$NAMESPACE" -l "$SELECTOR" -o wide

echo
echo "=== 8. Allow timed injector to auto-heal, then verify convergence ==="
if [[ -n "$FAULT_PID" ]]; then
    if ! wait "$FAULT_PID"; then
        cat "$OUT_DIR/inject.log"
        echo "ERROR: timed injector exited unsuccessfully." >&2
        exit 1
    fi
    FAULT_PID=""
    FAULT_PGID=""
fi

cat "$OUT_DIR/inject.log"
"$INJECT" heal link-down link12
FAULT_ATTEMPTED=0
"$INJECT" wait-converged 120

echo
echo "=== 8b. Verify all BGP peers are UP with fresh telemetry ==="
echo "Polling for up to 120 seconds; final health observation is gated on recovery."

RECOVERY_CONFIRMED=0
RECOVERY_DEADLINE=$((SECONDS + 120))
attempt=0
while (( SECONDS < RECOVERY_DEADLINE )); do
    attempt=$((attempt + 1))
    if curl -fsS --max-time 5 -G "$VM_URL/api/v1/query" \
      --data-urlencode 'query=frr_bgp_peer_up' \
      --data-urlencode 'latency_offset=1s' \
      > "$OUT_DIR/recovery-bgp.json" &&
      curl -fsS --max-time 5 -G "$VM_URL/api/v1/query" \
      --data-urlencode 'query=timestamp(frr_bgp_peer_up)' \
      --data-urlencode 'latency_offset=1s' \
      > "$OUT_DIR/recovery-bgp-timestamps.json" &&
      python3 - "$OUT_DIR/recovery-bgp.json" \
        "$OUT_DIR/recovery-bgp-timestamps.json" <<'PYRECOVERY'
import json, math, sys, time

def load(path):
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)
    if doc.get("status") != "success":
        raise ValueError(f"unsuccessful query: {path}")
    return doc.get("data", {}).get("result", [])

try:
    states = load(sys.argv[1])
    timestamps = load(sys.argv[2])

    def index(rows, is_timestamp=False):
        out = {}
        for row in rows:
            labels = row.get("metric", {})
            key = (labels.get("router"), labels.get("peer"))
            sample = row.get("value", [])
            if not all(key) or key in out or len(sample) < 2:
                raise ValueError("missing, duplicate, or malformed series")
            out[key] = sample[1]
        return out

    state_by_peer = index(states)
    timestamp_by_peer = index(timestamps)

    expected = set(state_by_peer)
    if len(expected) != 18 or len(state_by_peer) != 18:
        raise ValueError(
            f"expected 18 unique peer series; found {len(state_by_peer)}"
        )
    if set(timestamp_by_peer) != expected:
        raise ValueError("state and timestamp series do not match")

    now = time.time()
    down = []
    stale = []
    for peer, state in sorted(state_by_peer.items()):
        if state != "1":
            down.append(f"{peer[0]}->{peer[1]}={state}")
        try:
            ts = float(timestamp_by_peer[peer])
        except (TypeError, ValueError):
            stale.append(f"{peer[0]}->{peer[1]}=invalid timestamp")
            continue
        age = now - ts
        if not math.isfinite(ts) or age < -5 or age > 30:
            stale.append(f"{peer[0]}->{peer[1]} age={age:.1f}s")

    if down or stale:
        if down:
            print("Peers not UP:", ", ".join(down))
        if stale:
            print("Peers with stale/invalid samples:", ", ".join(stale))
        raise SystemExit(1)

    print(f"PASS: all {len(state_by_peer)} BGP peers are UP with fresh samples.")
except (OSError, ValueError, KeyError, TypeError) as exc:
    print(f"Recovery telemetry not yet valid: {exc}")
    raise SystemExit(1)
PYRECOVERY
    then
        RECOVERY_CONFIRMED=1
        break
    fi

    remaining=$((RECOVERY_DEADLINE - SECONDS))
    if (( remaining <= 0 )); then
        break
    fi
    echo "BGP recovery not yet verified (attempt $attempt); retrying in up to 5s."
    sleep "$(( remaining < 5 ? remaining : 5 ))"
done

if (( ! RECOVERY_CONFIRMED )); then
    echo "ERROR: all 18 BGP peers did not recover with fresh telemetry within 120 seconds." >&2
    echo "Inspect recovery-bgp.json and recovery-bgp-timestamps.json in: $OUT_DIR" >&2
    exit 1
fi

echo
echo "=== 8c. Wait for fresh post-recovery telemetry ==="
echo "Waiting up to 60 seconds for newer BGP and successful probe samples."

SETTLE_START_EPOCH="$(date +%s)"
SETTLE_DEADLINE=$((SECONDS + 60))
TELEMETRY_SETTLED=0
SETTLE_ATTEMPT=0

while (( SECONDS < SETTLE_DEADLINE )); do
    SETTLE_ATTEMPT=$((SETTLE_ATTEMPT + 1))

    if curl -fsS --max-time 5 -G "$VM_URL/api/v1/query" \
      --data-urlencode 'query=timestamp(frr_bgp_peer_up)' \
      --data-urlencode 'latency_offset=1s' \
      > "$OUT_DIR/settle-bgp-timestamps.json" &&
      curl -fsS --max-time 5 -G "$VM_URL/api/v1/query" \
      --data-urlencode 'query=frr_bgp_peer_up' \
      --data-urlencode 'latency_offset=1s' \
      > "$OUT_DIR/settle-bgp-state.json" &&
      curl -fsS --max-time 5 -G "$VM_URL/api/v1/query" \
      --data-urlencode 'query=probe_success{job="sparebox-web"}' \
      --data-urlencode 'latency_offset=1s' \
      > "$OUT_DIR/settle-probe.json" &&
      curl -fsS --max-time 5 -G "$VM_URL/api/v1/query" \
      --data-urlencode 'query=timestamp(probe_success{job="sparebox-web"})' \
      --data-urlencode 'latency_offset=1s' \
      > "$OUT_DIR/settle-probe-timestamps.json" &&
      python3 - "$OUT_DIR/settle-bgp-timestamps.json" \
        "$OUT_DIR/settle-bgp-state.json" \
        "$OUT_DIR/settle-probe.json" \
        "$OUT_DIR/settle-probe-timestamps.json" \
        "$SETTLE_START_EPOCH" <<'PYSETTLE'
import json, math, sys, time

def load(path):
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)
    if doc.get("status") != "success":
        raise ValueError(f"query failed: {path}")
    return doc.get("data", {}).get("result", [])

def key(row):
    return tuple(sorted(
        (k, v) for k, v in row.get("metric", {}).items()
        if k != "__name__"
    ))

def samples(rows):
    result = {}
    for row in rows:
        k = key(row)
        value = row.get("value", [])
        if k in result or len(value) < 2:
            raise ValueError("duplicate or malformed series")
        result[k] = value[1]
    return result

try:
    start = float(sys.argv[5])
    bgp_ts = samples(load(sys.argv[1]))
    bgp_state = samples(load(sys.argv[2]))
    probe = samples(load(sys.argv[3]))
    probe_ts = samples(load(sys.argv[4]))
    now = time.time()

    if len(bgp_ts) != 18 or len(bgp_state) != 18:
        raise ValueError(
            f"expected 18 BGP timestamp and state series; "
            f"got {len(bgp_ts)} timestamps and {len(bgp_state)} states"
        )
    if set(bgp_ts) != set(bgp_state):
        raise ValueError("BGP timestamp and state series do not match")
    down = [dict(labels) for labels, value in bgp_state.items() if value != "1"]
    if down:
        print(f"BGP peers still DOWN: {len(down)}/18")
        raise SystemExit(1)

    stale_bgp = []
    for labels, raw_ts in bgp_ts.items():
        ts = float(raw_ts)
        if (
            not math.isfinite(ts)
            or ts <= start
            or ts > now + 5
            or now - ts > 30
        ):
            stale_bgp.append(dict(labels))

    if stale_bgp:
        print(f"BGP samples not yet newer than settling start: {len(stale_bgp)}/18")

    if not probe or set(probe) != set(probe_ts):
        print("Application probe series/timestamp mismatch or missing.")
        raise SystemExit(1)

    probe_ok = all(
        value == "1"
        and math.isfinite(float(probe_ts[labels]))
        and start < float(probe_ts[labels]) <= now + 5
        and now - float(probe_ts[labels]) <= 30
        for labels, value in probe.items()
    )

    if not probe_ok:
        print("Application probe has not produced a newer successful sample.")
        raise SystemExit(1)

    if stale_bgp:
        raise SystemExit(1)

    print("PASS: all 18 BGP series and application probe have newer samples.")
except (OSError, ValueError, KeyError, TypeError) as exc:
    print(f"Telemetry settling check not yet satisfied: {exc}")
    raise SystemExit(1)
PYSETTLE
    then
        TELEMETRY_SETTLED=1
        break
    fi

    remaining=$((SETTLE_DEADLINE - SECONDS))
    if (( remaining <= 0 )); then
        break
    fi
    echo "Telemetry not settled (attempt $SETTLE_ATTEMPT); retrying."
    sleep "$(( remaining < 5 ? remaining : 5 ))"
done

if (( ! TELEMETRY_SETTLED )); then
    echo "ERROR: fresh post-recovery telemetry was not confirmed within 60 seconds." >&2
    echo "Inspect settle-*.json in: $OUT_DIR" >&2
    exit 1
fi

END_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo
echo "=== 9. Final health observation ==="
"$CHECK" "$OUT_DIR/final-observation.json"

echo
echo "=== 10. Historical telemetry timeline ==="
"$TIMELINE" "$START_UTC" "$END_UTC" "$OUT_DIR/timeline.json"

echo
echo "=== RUN COMPLETED ==="
echo "Start UTC: $START_UTC"
echo "End UTC:   $END_UTC"
echo "Evidence:  $OUT_DIR"
echo "Review run.log, baseline.json, final-observation.json and timeline.json."
