#!/usr/bin/env bash
#
# collect-ospf-neighbors.sh
#
# Export per-neighbor OSPF state and uptime for the six FRR routers.
# OSPF is intentionally scoped to the existing intra-region adjacencies.
# Output is InfluxDB line protocol for a separate Telegraf inputs.exec.
#
set -uo pipefail

CLAB_PREFIX="clab-sparebox-fabric"

declare -A REGIONS=(
  [r1-1]=region1 [r1-2]=region1
  [r2-1]=region2 [r2-2]=region2
  [r3-1]=region3 [r3-2]=region3
)

declare -A EXPECTED_NEIGHBORS=(
  [r1-1]=10.0.1.2 [r1-2]=10.0.1.1
  [r2-1]=10.0.2.2 [r2-2]=10.0.2.1
  [r3-1]=10.0.3.2 [r3-2]=10.0.3.1
)

for router in r1-1 r1-2 r2-1 r2-2 r3-1 r3-2; do
  region="${REGIONS[$router]}"
  expected="${EXPECTED_NEIGHBORS[$router]}"
  container="${CLAB_PREFIX}-${router}"

  if ! summary_json=$(
    docker exec "$container" vtysh -c 'show ip ospf neighbor json' 2>/dev/null
  ); then
    echo "frr_ospf_collector,router=${router},region=${region} success=0i"
    echo "frr_ospf_neighbor,router=${router},region=${region},neighbor=${expected},interface=eth1 up=0i,uptime_seconds=0i"
    continue
  fi

  if ! printf '%s\n' "$summary_json" |
    jq -e '.neighbors | type == "object"' >/dev/null 2>&1; then
    echo "frr_ospf_collector,router=${router},region=${region} success=0i"
    echo "frr_ospf_neighbor,router=${router},region=${region},neighbor=${expected},interface=eth1 up=0i,uptime_seconds=0i"
    continue
  fi

  echo "frr_ospf_collector,router=${router},region=${region} success=1i"

  # Preserve an explicit down point if the expected neighbor is absent.
  # The collector-success metric distinguishes collection failure from
  # a successfully queried router with a missing OSPF neighbor.
  if ! printf '%s\n' "$summary_json" |
    jq -e --arg peer "$expected" \
      '.neighbors[$peer] | type == "array" and length > 0' >/dev/null 2>&1; then
    echo "frr_ospf_neighbor,router=${router},region=${region},neighbor=${expected},interface=eth1 up=0i,uptime_seconds=0i"
    continue
  fi

  printf '%s\n' "$summary_json" |
    jq -r \
      --arg router "$router" \
      --arg region "$region" \
      --arg expected "$expected" '
      .neighbors[$expected][] |
      "frr_ospf_neighbor,router=" + $router +
      ",region=" + $region +
      ",neighbor=" + $expected +
      ",interface=" + ((.ifaceName // "unknown") | split(":")[0]) +
      " up=" +
      (if (.converged // ((.nbrState // "") | split("/")[0])) == "Full"
       then "1i" else "0i" end) +
      ",uptime_seconds=" +
      (((.upTimeInMsec // 0) / 1000 | floor | tostring) + "i")
    '
done
