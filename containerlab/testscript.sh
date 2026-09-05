#!/usr/bin/env bash
# verify-phase1.sh
#
# Run from the containerlab/ directory, AFTER:
#   containerlab destroy -t topology.clab.yml --cleanup
#   containerlab deploy -t topology.clab.yml
#   ./scripts/setup-cust-a.sh
#   sleep 10   # LDP settle time — see docs/runbook.md
#
# Checks every claim made through Week 5. Paste the full output back for
# a read on what's actually working vs. what's drifted.

set -uo pipefail
PREFIX="clab-sparebox-fabric"
NODES="r1-1 r1-2 r2-1 r2-2 r3-1 r3-2"

section() { echo; echo "=== $1 ==="; }

section "0. Veth link sanity (runbook lesson 1 — only lo+eth0 here means redeploy first)"
for n in $NODES; do
  echo "--- $n ---"
  docker exec "$PREFIX-$n" ip -br link show
done

section "1. OSPF full adjacency, all 3 regions (Week 2)"
for n in $NODES; do
  echo "--- $n ---"
  docker exec "$PREFIX-$n" vtysh -c "show ip ospf neighbor"
done

section "2. eBGP ring + iBGP sessions (Week 3)"
for n in $NODES; do
  echo "--- $n ---"
  docker exec "$PREFIX-$n" vtysh -c "show ip bgp summary"
done

section "3. Cross-ring reachability, r1-1 -> r2 and r3 loopbacks (Week 3)"
docker exec "$PREFIX-r1-1" ping -c3 10.0.2.1
docker exec "$PREFIX-r1-1" ping -c3 10.0.3.1

section "4. IPsec SA state, all 3 transit links (Week 3)"
for n in $NODES; do
  echo "--- ipsec-$n ---"
  docker exec "$PREFIX-ipsec-$n" ipsec statusall | grep -E "ESTABLISHED|no match|IKE_SA"
done

section "5. LDP operational, r1-1/r1-2 only (Week 5 pilot)"
docker exec "$PREFIX-r1-1" vtysh -c "show mpls ldp neighbor"
docker exec "$PREFIX-r1-2" vtysh -c "show mpls ldp neighbor"

section "6. VPNv4 route exchange, CUST-A (Week 5 pilot)"
docker exec "$PREFIX-r1-1" vtysh -c "show bgp vrf CUST-A"
docker exec "$PREFIX-r1-2" vtysh -c "show bgp vrf CUST-A"

section "7. Kernel LFIB, r1-1/r1-2 (Week 5 pilot)"
docker exec "$PREFIX-r1-1" ip -f mpls route show
docker exec "$PREFIX-r1-2" ip -f mpls route show

section "8. CUST-A data plane, 0% loss expected (Week 5 pilot)"
docker exec "$PREFIX-r1-1" ip vrf exec CUST-A ping -c5 192.168.101.2
