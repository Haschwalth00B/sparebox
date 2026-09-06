#!/usr/bin/env bash
#
# collect-bgp-summary.sh
#
# Week 5 metrics pipeline, step 1: eBGP/iBGP peer state for the ring
# backbone (r1-1..r3-2), one line-protocol point per peer per router.
# Deliberately scoped to the default-VRF ring first -- VPNv4/CUST-A,
# OSPF, LDP, interface counters, and IPsec tunnel state are follow-up
# collector scripts wired in as separate telegraf inputs.exec entries,
# not folded into this one.
#
# Run manually to sanity-check before Telegraf ever calls it:
#   ./collect-bgp-summary.sh
# Output is InfluxDB line protocol -- each line is one metric point.
#
# CONFIRMED: Containerlab names these containers with the
# "clab-sparebox-fabric-<node>" prefix on the deployed sparebox lab.
set -euo pipefail

CLAB_PREFIX="clab-sparebox-fabric"

declare -A ROUTERS=(
  [r1-1]=region1 [r1-2]=region1
  [r2-1]=region2 [r2-2]=region2
  [r3-1]=region3 [r3-2]=region3
)

for router in "${!ROUTERS[@]}"; do
  region="${ROUTERS[$router]}"
  container="${CLAB_PREFIX}-${router}"

  if ! summary_json=$(docker exec "$container" vtysh -c "show bgp ipv4 unicast summary json" 2>/dev/null); then
    # Container unreachable or vtysh failed -- report as down rather than
    # silently dropping the point, so a dead router shows up on the
    # topology-health dashboard instead of just leaving a gap.
    echo "frr_bgp_peer,router=${router},region=${region},peer=unknown up=0i"
    continue
  fi

  # CONFIRMED: The deployed FRR output exposes BGP peers under
  # .ipv4Unicast.peers. The fallback to .peers is retained for
  # compatibility with alternate FRR JSON layouts.
  echo "$summary_json" | jq -r --arg router "$router" --arg region "$region" '
    (.ipv4Unicast.peers // .peers // {}) | to_entries[] |
    "frr_bgp_peer,router=" + $router + ",region=" + $region + ",peer=" + .key +
    " up=" + (if .value.state == "Established" then "1i" else "0i" end) +
    ",pfx_rcvd=" + ((.value.pfxRcd // 0) | tostring) + "i" +
    ",msg_rcvd=" + ((.value.msgRcvd // 0) | tostring) + "i"
  '
done
