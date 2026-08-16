#!/bin/bash
# Run once after every `containerlab deploy` — VRF-lite kernel state
# (the CUST-A device + MPLS sysctls) doesn't persist across container
# recreation and zebra won't create it itself. Safe to re-run.
set -e
for pair in "r1-1:192.168.101.1" "r1-2:192.168.101.2"; do
  node="${pair%%:*}"; ip="${pair##*:}"
  c="clab-sparebox-fabric-$node"
  docker exec "$c" ip link show CUST-A >/dev/null 2>&1 \
    || docker exec "$c" ip link add CUST-A type vrf table 100
  docker exec "$c" ip link set CUST-A up
  docker exec "$c" ip addr show CUST-A | grep -q "$ip/32" \
    || docker exec "$c" ip addr add "$ip/32" dev CUST-A
  docker exec "$c" sysctl -w net.mpls.conf.eth1.input=1
  docker exec "$c" sysctl -w net.mpls.platform_labels=100000
  docker exec "$c" sysctl -w net.ipv4.raw_l3mdev_accept=1
done
echo "CUST-A VRF setup complete on r1-1/r1-2 (idempotent)"
