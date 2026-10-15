#!/usr/bin/env bash
set -Eeuo pipefail

TOPOLOGY="containerlab/topology.clab.yml"
ROUTERS=(r1-1 r1-2 r2-1 r2-2 r3-1 r3-2)
SIDECARS=(
  ipsec-r1-1 ipsec-r1-2
  ipsec-r2-1 ipsec-r2-2
  ipsec-r3-1 ipsec-r3-2
)

echo "=== Sparebox fabric boot recovery ==="
echo "Working directory: $PWD"

fabric_is_complete() {
  local node container iface

  for node in "${ROUTERS[@]}"; do
    container="clab-sparebox-fabric-${node}"

    docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null |
      grep -qx true || return 1

    for iface in eth1 eth2 eth3; do
      if ! docker exec "$container" ip -brief link show dev "$iface" 2>/dev/null |
           grep -q 'LOWER_UP'; then
        return 1
      fi
    done
  done

  for node in "${SIDECARS[@]}"; do
    container="clab-sparebox-fabric-${node}"

    docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null |
      grep -qx true || return 1
  done

  return 0
}

DEPLOY_RC=0

if fabric_is_complete; then
  echo "Fabric containers and interfaces already exist; skipping redeploy."
else
  echo "Fabric is incomplete; attempting Containerlab recovery."
  DEPLOY_LOG="$(mktemp)"
  trap 'rm -f "$DEPLOY_LOG"' EXIT

  set +e
  containerlab deploy \
    --topo "$TOPOLOGY" \
    --name sparebox-fabric \
    --max-workers 1 \
    --reconfigure \
    --skip-post-deploy >"$DEPLOY_LOG" 2>&1
  DEPLOY_RC=$?
  set -e

  cat "$DEPLOY_LOG"
  echo "Containerlab deploy exit code: $DEPLOY_RC"
fi

echo
echo "=== Verifying router containers and interfaces ==="
for node in "${ROUTERS[@]}"; do
  container="clab-sparebox-fabric-${node}"

  docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null |
    grep -qx true || {
      echo "ERROR: router is not running: $container" >&2
      exit 1
    }

  for iface in eth1 eth2 eth3; do
    docker exec "$container" ip link show dev "$iface" >/dev/null 2>&1 || {
      echo "ERROR: missing $iface on $container" >&2
      exit 1
    }
  done

  echo "OK: $node — eth1, eth2, eth3"
done

echo
echo "=== Verifying IPsec sidecars ==="
for node in "${SIDECARS[@]}"; do
  container="clab-sparebox-fabric-${node}"

  docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null |
    grep -qx true || {
      echo "ERROR: IPsec sidecar is not running: $container" >&2
      exit 1
    }

  echo "OK: $node"
done

echo
echo "=== Restoring CUST-A VRF and MPLS settings ==="
bash containerlab/scripts/setup-cust-a.sh

if (( DEPLOY_RC != 0 )); then
  echo "ERROR: Containerlab reported exit code $DEPLOY_RC." >&2
  echo "Inspect deployment output above, even if interface checks passed." >&2
  exit "$DEPLOY_RC"
fi

echo
echo "=== Fabric recovery completed ==="
