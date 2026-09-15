#!/usr/bin/env bash
# sparebox — week 6 diagnostic collection
#
# Read-only, with two exceptions that are both reverted in place:
#   - one `tc qdisc add ... netem` + `del` on ipsec-r1-1:eth2 (capability probe)
#   - ./inject.sh preflight / baseline / status (these only read)
# Never calls `fail`. Never touches git. Skips *secret* files.
#
# Usage:
#   bash collect-sparebox.sh > /tmp/sparebox-diag.txt 2>&1
#   then upload /tmp/sparebox-diag.txt

set +e
export LC_ALL=C

REPO="${REPO:-/root/sparebox}"
PREFIX="${CLAB_PREFIX:-clab-sparebox-fabric}"
NODES=(r1-1 r1-2 r2-1 r2-2 r3-1 r3-2)
INJECT="${INJECT:-$REPO/containerlab/chaos/inject.sh}"

sec()   { printf '\n\n##################### %s #####################\n' "$*"; }
run()   { printf '\n--- $ %s\n' "$*"; eval "$*" 2>&1; }
runrc() { printf '\n--- $ %s\n' "$*"; eval "$*" 2>&1; printf '[rc=%s]\n' "$?"; }
vt()    { local n="$1"; shift; printf '\n--- $ [%s] vtysh -c "%s"\n' "$n" "$*"; docker exec "$PREFIX-$n" vtysh -c "$*" 2>&1; }

printf 'sparebox diagnostic collection\n'
printf 'generated: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
printf 'repo=%s prefix=%s\n' "$REPO" "$PREFIX"

# ============================================================ 0. HOST
sec "0. HOST"
run 'date -u'
run 'uname -a'
run 'nixos-version'
run 'uptime'
run 'free -m'
run 'df -h / /var/tmp'
run 'containerlab version'
run 'docker info --format "server={{.ServerVersion}} storage={{.Driver}} cgroup={{.CgroupVersion}}"'
run 'command -v jq tc timeout tcpdump docker bash awk sed tac'
run 'jq --version'
run 'tc -V'
run 'bash --version | head -1'

# ============================================ 0b. KERNEL / NETEM CAPABILITY
sec "0b. KERNEL MODULES + NETEM CAPABILITY (host)"
run 'ls -d /lib/modules/* 2>&1'
run 'ls -d /run/booted-system/kernel-modules/lib/modules/* 2>&1'
run 'lsmod | grep -E "sch_netem|sch_htb|sch_tbf|ifb|mpls|vrf|xfrm|esp|ah4" '
runrc 'modprobe sch_netem'
runrc 'modprobe ifb'
runrc 'modprobe mpls_router'
run 'lsmod | grep -E "sch_netem|ifb|mpls_router|vrf"'
run 'sysctl net.mpls.platform_labels net.mpls.conf.lo.input 2>&1'
run "grep -rnE 'kernelModules|kernelParams|sch_netem|mpls|virtualisation' $REPO/flake.nix $REPO/modules 2>&1 | head -60"

# ============================================================ 1. REPO / GIT
sec "1. REPO / GIT STATE"
run "git -C $REPO status -sb"
run "git -C $REPO branch -avv"
run "git -C $REPO log --oneline -20"
run "git -C $REPO log --stat -3"
run "git -C $REPO status --porcelain"
run "find $REPO -name .git -prune -o -name 'clab-*' -prune -o -type f -print | sort"

# ============================================================ 2. CONFIGS
sec "2. TOPOLOGY + FRR CONFIG"
run "cat $REPO/containerlab/topology.clab.yml"
for n in "${NODES[@]}"; do
  run "cat $REPO/containerlab/frr/$n/frr.conf"
done
run "ls -laR $REPO/containerlab/frr 2>&1 | head -80"
for f in $(find "$REPO/containerlab/scripts" -type f 2>/dev/null | sort); do run "cat $f"; done

sec "2b. STRONGSWAN CONFIG (secrets excluded)"
run "ls -laR $REPO/containerlab/strongswan 2>&1 | head -80"
for f in $(find "$REPO/containerlab/strongswan" -type f ! -name '*secret*' ! -name '*.pem' ! -name '*.key' 2>/dev/null | sort); do
  run "cat $f"
done
run "find $REPO/containerlab/strongswan -name '*secret*' -exec ls -l {} + 2>&1"

sec "2c. DOCS"
run "ls -la $REPO/docs 2>&1"
run "head -n 60 $REPO/docs/runbook.md 2>&1"

# ============================================== 3. CONTAINERS + NETNS WIRING
sec "3. CONTAINERS"
run "docker ps -a --format '{{.Names}} | {{.Image}} | {{.Status}}' | sort"
for n in "${NODES[@]}"; do
  run "docker inspect -f 'ROUTER  {{.Name}} netmode={{.HostConfig.NetworkMode}} priv={{.HostConfig.Privileged}} pid={{.State.Pid}} started={{.State.StartedAt}}' $PREFIX-$n"
  run "docker inspect -f 'SIDECAR {{.Name}} netmode={{.HostConfig.NetworkMode}} priv={{.HostConfig.Privileged}} pid={{.State.Pid}} started={{.State.StartedAt}}' $PREFIX-ipsec-$n"
done

sec "3b. NETNS SHARING (router vs its sidecar — must match)"
for n in "${NODES[@]}"; do
  rp=$(docker inspect -f '{{.State.Pid}}' "$PREFIX-$n" 2>/dev/null)
  sp=$(docker inspect -f '{{.State.Pid}}' "$PREFIX-ipsec-$n" 2>/dev/null)
  printf '%-6s router_ns=%-24s sidecar_ns=%s\n' "$n" \
    "$(readlink /proc/${rp:-0}/ns/net 2>&1)" "$(readlink /proc/${sp:-0}/ns/net 2>&1)"
done

# ============================================================ 4. ADDRESSING
sec "4. ADDRESSING (ground truth)"
for n in "${NODES[@]}"; do
  run "docker exec $PREFIX-$n ip -br addr show"
done
for n in "${NODES[@]}"; do
  run "docker exec $PREFIX-$n ip -br link show"
done

sec "4b. DISCOVERED LOOPBACKS (compare against inject.sh LOOPBACK map)"
declare -A LO
for n in "${NODES[@]}"; do
  LO[$n]=$(docker exec "$PREFIX-$n" ip -4 -o addr show dev lo 2>/dev/null \
           | awk '$4 !~ /^127\./ {split($4,a,"/"); print a[1]; exit}')
  printf '%-6s lo=%s\n' "$n" "${LO[$n]:-NONE-FOUND}"
done
printf '\ninject.sh assumes: r1-1=10.0.1.1 r1-2=10.0.1.2 r2-1=10.0.2.1 r2-2=10.0.2.2 r3-1=10.0.3.1 r3-2=10.0.3.2\n'

# ============================================================ 5. IMAGE TOOLING
sec "5. IMAGE TOOLING (what actually exists in each image)"
run "docker exec $PREFIX-r1-1 cat /etc/os-release | head -3"
run "docker exec $PREFIX-r1-1 sh -c 'command -v ping ip tc jq vtysh tcpdump ss traceroute'"
run "docker exec $PREFIX-r1-1 sh -c 'ping -V 2>&1 | head -2; echo ===; ping --help 2>&1 | head -12'"
run "docker exec $PREFIX-r1-1 sh -c 'readlink -f \$(command -v ping) 2>&1'"
run "docker exec $PREFIX-ipsec-r1-1 cat /etc/os-release | head -3"
run "docker exec $PREFIX-ipsec-r1-1 sh -c 'command -v ping ip tc tcpdump ipsec swanctl charon jq'"
run "docker exec $PREFIX-ipsec-r1-1 sh -c 'ping -V 2>&1 | head -2; echo ===; tc -V'"

# ============================================== 6. NETEM CAPABILITY (live)
sec "6. NETEM CAPABILITY — reversible live probe"
runrc "docker exec $PREFIX-ipsec-r1-1 tc qdisc show dev eth2"
runrc "docker exec $PREFIX-ipsec-r1-1 tc qdisc add dev eth2 root netem loss 100%"
runrc "docker exec $PREFIX-ipsec-r1-1 tc qdisc show dev eth2"
runrc "docker exec $PREFIX-ipsec-r1-1 tc qdisc del dev eth2 root"
runrc "docker exec $PREFIX-ipsec-r1-1 tc qdisc show dev eth2"
printf '\n(above must end with the default qdisc, not netem — if it ends with netem, run: docker exec %s-ipsec-r1-1 tc qdisc del dev eth2 root)\n' "$PREFIX"
runrc "docker exec $PREFIX-r1-1 tc qdisc show dev eth2"

# ============================================== 7. FRR CONTROL PLANE
sec "7. CONTROL PLANE — OSPF"
for n in "${NODES[@]}"; do vt "$n" 'show ip ospf neighbor'; done

sec "7b. CONTROL PLANE — BGP SUMMARY (human)"
for n in "${NODES[@]}"; do vt "$n" 'show bgp ipv4 unicast summary'; done

sec "7c. CONTROL PLANE — BGP SUMMARY JSON (raw, r1-1 + r2-1)"
vt r1-1 'show bgp ipv4 unicast summary json'
vt r1-1 'show bgp summary json'
vt r2-1 'show bgp ipv4 unicast summary json'

sec "7d. EXACT jq EXPRESSION USED BY inject.sh baseline()"
for n in "${NODES[@]}"; do
  echo "== $n"
  docker exec "$PREFIX-$n" vtysh -c "show bgp ipv4 unicast summary json" 2>&1 \
    | jq -r '(.ipv4Unicast.peers // .peers // {}) | to_entries[] | .key + " => " + (.value.state // "?")' 2>&1
done

sec "7e. EXACT ROUTE-PRESENCE CHECK USED BY inject.sh baseline()"
for n in "${NODES[@]}"; do
  [ "$n" = "r1-1" ] && continue
  t="${LO[$n]}"
  echo "== r1-1 route to $n ($t)"
  docker exec "$PREFIX-r1-1" vtysh -c "show ip route ${t:-0.0.0.0} json" 2>&1 \
    | jq -e 'length > 0' 2>&1
  printf '[jq -e rc=%s]\n' "$?"
done

sec "7f. MPLS / LDP / VPNv4"
for n in "${NODES[@]}"; do vt "$n" 'show mpls ldp neighbor'; done
vt r1-1 'show mpls ldp binding'
vt r1-1 'show bgp vpnv4 all summary'
vt r1-1 'show bgp vpnv4 all'
vt r1-1 'show ip route vrf CUST-A'
vt r1-2 'show ip route vrf CUST-A'
run "docker exec $PREFIX-r1-1 ip -f mpls route show"
run "docker exec $PREFIX-r1-2 ip -f mpls route show"
run "docker exec $PREFIX-r1-1 ip vrf show"
run "docker exec $PREFIX-r1-1 sysctl net.mpls.platform_labels net.mpls.conf.eth1.input net.ipv4.raw_l3mdev_accept"

sec "7g. ROUTE TABLES + RUNNING CONFIG"
vt r1-1 'show ip route'
vt r2-1 'show ip route'
vt r1-1 'show running-config'
run "docker exec $PREFIX-r1-1 sh -c 'grep -vE \"^#|^\\\$\" /etc/frr/daemons'"

# ============================================================ 8. DATA PLANE
sec "8. DATA PLANE — three probe variants per destination"
src="${LO[r1-1]}"
printf 'probe source (r1-1 lo) = %s\n' "${src:-NONE}"
for n in "${NODES[@]}"; do
  [ "$n" = "r1-1" ] && continue
  t="${LO[$n]}"
  echo
  echo "================ r1-1 -> $n (${t:-NONE})"
  echo "-- A. router container, unsourced:"
  timeout 8 docker exec "$PREFIX-r1-1" ping -c2 -W1 "${t:-0.0.0.0}" 2>&1
  printf '[rc=%s]\n' "$?"
  echo "-- B. router container, -I ${src} (exactly what inject.sh does):"
  timeout 8 docker exec "$PREFIX-r1-1" ping -c2 -W1 -I "${src:-0.0.0.0}" "${t:-0.0.0.0}" 2>&1
  printf '[rc=%s]\n' "$?"
  echo "-- C. sidecar (same netns, iputils ping), -I ${src}:"
  timeout 8 docker exec "$PREFIX-ipsec-r1-1" ping -c2 -W1 -I "${src:-0.0.0.0}" "${t:-0.0.0.0}" 2>&1
  printf '[rc=%s]\n' "$?"
done

sec "8b. DATA PLANE — CUST-A VRF (week 5 pilot)"
runrc "docker exec $PREFIX-r1-1 ping -c2 -W1 -I 192.168.101.1 192.168.101.2"
runrc "docker exec $PREFIX-r1-1 ip vrf exec CUST-A ping -c2 -W1 192.168.101.2"
runrc "docker exec $PREFIX-ipsec-r1-1 ping -c2 -W1 -I 192.168.101.1 192.168.101.2"

sec "8c. HIGH-RATE PROBE FEASIBILITY (needed for p50/p95 resolution)"
runrc "docker exec $PREFIX-ipsec-r1-1 ping -c 20 -i 0.05 -W 1 -D -n -I ${src:-0.0.0.0} ${LO[r2-1]:-0.0.0.0}"

# ============================================================ 9. STRONGSWAN
sec "9. STRONGSWAN — which stack, which conn names"
for n in "${NODES[@]}"; do
  runrc "docker exec $PREFIX-ipsec-$n ipsec status"
done
run "docker exec $PREFIX-ipsec-r1-2 ipsec statusall 2>&1 | head -60"
runrc "docker exec $PREFIX-ipsec-r1-2 swanctl --list-conns"
runrc "docker exec $PREFIX-ipsec-r1-2 swanctl --list-sas"
run "docker exec $PREFIX-ipsec-r1-2 ip xfrm state 2>&1 | head -30"
run "docker exec $PREFIX-ipsec-r1-2 ip xfrm policy 2>&1 | head -30"
printf '\n(inject.sh assumes conn name transit-<self>-<peer>, e.g. transit-r1-2-r2-1 on r1-2)\n'

# ============================================================ 10. INJECT.SH
sec "10. INJECT.SH BEHAVIOUR"
runrc "bash -n $INJECT"
run "ls -l $INJECT"
run "cat /var/tmp/sparebox-chaos.state 2>&1"
run "$INJECT list"
run "$INJECT status"
runrc "$INJECT baseline"
runrc "$INJECT preflight"
sec "10b. INJECT.SH baseline UNDER bash -x (tail)"
bash -x "$INJECT" baseline 2>&1 | tail -n 150

# ============================================================ 11. LOGS
sec "11. LOGS"
for n in "${NODES[@]}"; do
  run "docker logs --tail 25 $PREFIX-$n"
done
for n in "${NODES[@]}"; do
  run "docker exec $PREFIX-$n sh -c 'tail -n 25 /var/log/frr/*.log 2>/dev/null'"
done
run "docker logs --tail 40 $PREFIX-ipsec-r1-2"
run "journalctl -k --since '-45 min' --no-pager 2>&1 | tail -80"

sec "END OF COLLECTION"
printf 'done: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
