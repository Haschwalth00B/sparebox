#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RECOVERY_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
ROUTERS=(r1-1 r1-2 r2-1 r2-2 r3-1 r3-2)
SIDECARS=(
  ipsec-r1-1 ipsec-r1-2
  ipsec-r2-1 ipsec-r2-2
  ipsec-r3-1 ipsec-r3-2
)

echo "=== Sparebox fabric boot recovery ==="
echo "Working directory: $PWD"

echo "=== Restoring missing data links, if necessary ==="
bash "$RECOVERY_ROOT/containerlab/scripts/restore-data-links.sh"

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

if ! fabric_is_complete; then
  echo "ERROR: fabric is incomplete; automatic reconfiguration is disabled." >&2
  echo "No containers were redeployed. Inspect container and interface state manually." >&2
  exit 1
fi

echo "Fabric containers and data interfaces are present; skipping redeploy."

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
bash "$RECOVERY_ROOT/containerlab/scripts/setup-cust-a.sh"

echo
echo "=== Waiting for BGP and data-plane convergence ==="
if ! bash "$RECOVERY_ROOT/containerlab/chaos/inject.sh" wait-converged 180; then
  echo "ERROR: BGP/data-plane convergence failed after 180 seconds." >&2
  exit 1
fi

echo
echo "=== Waiting for configured IPsec tunnels ==="
IPSEC_TIMEOUT=180
IPSEC_DEADLINE=$(( $(date +%s) + IPSEC_TIMEOUT ))

while :; do
  IPSEC_READY=1

  for node in "${ROUTERS[@]}"; do
    config="$RECOVERY_ROOT/containerlab/strongswan/${node}/ipsec.conf"
    container="clab-sparebox-fabric-ipsec-${node}"

    if ! status=$(docker exec "$container" /usr/sbin/ipsec statusall 2>/dev/null); then
      echo "WAIT: IPsec status unavailable on $node"
      IPSEC_READY=0
      continue
    fi

    while read -r conn; do
      [[ -n "$conn" ]] || continue

      if ! grep -Eq "^${conn}\\[[0-9]+\\]: ESTABLISHED([[:space:]]|$)" <<<"$status" ||
         ! grep -Eq "^${conn}\\{[0-9]+\\}:[[:space:]]+INSTALLED," <<<"$status"; then
        echo "WAIT: $node — $conn lacks an established IKE SA or installed child SA"
        IPSEC_READY=0
      fi
    done < <(awk '$1 == "conn" {print $2}' "$config")
  done

  if (( IPSEC_READY == 1 )); then
    echo "OK: all configured IPsec connections have established and installed SAs"
    break
  fi

  if (( $(date +%s) >= IPSEC_DEADLINE )); then
    echo "ERROR: configured IPsec tunnels did not become healthy within ${IPSEC_TIMEOUT}s." >&2
    exit 1
  fi

  sleep 5
done

echo
echo "=== Fabric recovery completed ==="
