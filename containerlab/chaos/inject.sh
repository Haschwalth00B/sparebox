#!/usr/bin/env bash
#
# inject.sh — Week 6 failure injection for the sparebox fabric.
#
# Injects *reversible* faults into the running Containerlab topology and
# tracks what's currently broken, so nothing is ever left half-failed.
# Measurement lives elsewhere (probe.sh / trial.sh); this script only
# breaks things and un-breaks them.
#
# Two design rules, both learned the hard way:
#
#   1. No `docker stop` / `docker restart`, ever. Containerlab-injected
#      veth links don't survive container restart (docs/runbook.md,
#      lesson 1) — a "node failure" done that way costs a full redeploy
#      to recover from. Node failure here means the data interfaces go
#      admin-down inside a container that keeps running.
#
#   2. Every fault has an explicit heal, a state file, and an EXIT trap.
#      A Ctrl-C mid-experiment must not leave the fabric black-holed.
#
# Usage:
#   ./inject.sh list
#   ./inject.sh preflight
#   ./inject.sh baseline
#   ./inject.sh wait-converged [SECONDS]
#   ./inject.sh status
#   ./inject.sh fail  <scenario> <target> [--for SECONDS]
#   ./inject.sh heal  <scenario> <target>
#   ./inject.sh heal-all
#
# Env overrides: CLAB_PREFIX, CHAOS_STATE

set -euo pipefail

PREFIX="${CLAB_PREFIX:-clab-sparebox-fabric}"
STATE="${CHAOS_STATE:-/var/tmp/sparebox-chaos.state}"

NODES=(r1-1 r1-2 r2-1 r2-2 r3-1 r3-2)

# link name -> "nodeA:ifA nodeB:ifB"
declare -A LINKS=(
  [link12]="r1-2:eth2 r2-1:eth2"     # region1 <-> region2 primary
  [link23]="r2-2:eth2 r3-1:eth2"     # region2 <-> region3 primary
  [link31]="r3-2:eth2 r1-1:eth2"     # region3 <-> region1 primary
  [link14]="r1-1:eth3 r2-2:eth3"     # region1 <-> region2 redundant
  [link25]="r2-1:eth3 r3-2:eth3"     # region2 <-> region3 redundant
  [link35]="r3-1:eth3 r1-2:eth3"     # region3 <-> region1 redundant
  [link-r1]="r1-1:eth1 r1-2:eth1"    # region1 intra (OSPF + iBGP + LDP)
  [link-r2]="r2-1:eth1 r2-2:eth1"    # region2 intra
  [link-r3]="r3-1:eth1 r3-2:eth1"    # region3 intra
)

TRANSIT_LINKS=(link12 link23 link31 link14 link25 link35)

# router -> loopback, used by the baseline reachability gate
declare -A LOOPBACK=(
  [r1-1]=10.0.1.1 [r1-2]=10.0.1.2
  [r2-1]=10.0.2.1 [r2-2]=10.0.2.2
  [r3-1]=10.0.3.1 [r3-2]=10.0.3.2
)

# every trial measures an outage against this source. Keep it fixed: r1-1
# reaches r2-1's loopback over link12 by default (1 AS hop) and over the
# far side of the ring after link12 fails (2 AS hops), so the failure and
# the recovery are both observable from one probe point.
PROBE_SRC="${PROBE_SRC:-r1-1}"

# ---------------------------------------------------------------- helpers

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S.%3N)" "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# exec inside a router container
dex() { local n="$1"; shift; docker exec "$PREFIX-$n" "$@"; }

# exec inside that router's strongSwan sidecar (shares the router's netns,
# and unlike the FRR image it's Debian — has tc, tcpdump, full iputils)
sdex() { local n="$1"; shift; docker exec "$PREFIX-ipsec-$n" "$@"; }

endpoints_of() {
  local link="$1"
  [[ -v LINKS[$link] ]] || die "unknown link '$link' (try: ./inject.sh list)"
  echo "${LINKS[$link]}"
}

is_node() {
  local n="$1"
  for x in "${NODES[@]}"; do [[ "$x" == "$n" ]] && return 0; done
  return 1
}

record() { printf '%s %s\n' "$1" "$2" >> "$STATE"; }

forget() {
  [[ -f "$STATE" ]] || return 0
  grep -vxF "$1 $2" "$STATE" > "$STATE.tmp" 2>/dev/null || true
  mv "$STATE.tmp" "$STATE"
}

# ---------------------------------------------------------------- preflight

preflight() {
  local rc=0

  log "checking containers are up"
  for n in "${NODES[@]}"; do
    docker inspect -f '{{.State.Running}}' "$PREFIX-$n" 2>/dev/null | grep -q true \
      || { echo "  MISSING: $PREFIX-$n not running"; rc=1; }
  done

  # runbook lesson 1: veths silently vanish. Never inject into a fabric
  # that's already broken — every trial would record a bogus number.
  log "checking veth links exist (runbook lesson 1)"
  for n in "${NODES[@]}"; do
    local links
    links=$(dex "$n" ip -br link show 2>/dev/null | awk '{print $1}' | cut -d@ -f1 | tr '
' ' ')
    for want in eth1 eth2 eth3; do
      grep -qw "$want" <<<"$links" || {
        echo "  MISSING: $n has no $want (links: $links)"
        rc=1
      }
    done
  done

  # `tc qdisc show` only proves the binary exists. sch_netem is a module and
  # is not loaded at boot unless boot.kernelModules asks for it, so the only
  # honest check is to install a netem qdisc and remove it again.
  log "checking netem is actually usable from the sidecars (needed for blackhole)"
  if sdex r1-1 tc qdisc add dev eth2 root netem loss 0% >/dev/null 2>&1; then
    sdex r1-1 tc qdisc del dev eth2 root >/dev/null 2>&1 || true
    echo "  netem: ok"
  else
    echo "  netem: NOT usable from ipsec-r1-1 — link-blackhole will fail"
    echo "         check sch_netem is in boot.kernelModules (modules/kernel.nix)"
    rc=1
  fi

  if [[ -s "$STATE" ]]; then
    echo
    echo "  WARNING: faults still recorded as active:"
    sed 's/^/    /' "$STATE"
    echo "  run './inject.sh heal-all' before starting a clean run"
    rc=1
  fi

  if [[ $rc -ne 0 ]]; then
    log "preflight FAILED — fix the above before injecting anything"
    return 1
  fi

  log "checking baseline health (control plane + data plane)"
  baseline || rc=1

  [[ $rc -eq 0 ]] && log "preflight OK — fabric is clean and converged" \
                  || log "preflight FAILED"
  return $rc
}

# ---------------------------------------------------------------- baseline

# A fault measurement is only meaningful if the fabric was healthy the
# instant before the fault. Injecting into an unconverged or already-broken
# fabric produces numbers that look real and mean nothing, so this gate runs
# before every trial and not just once at the start of the session.
#
# Two checks, deliberately cheap enough to poll:
#   1. control plane — every BGP session on every router is Established
#   2. data plane    — PROBE_SRC reaches all five remote loopbacks, 0% loss
baseline() {
  local quiet="${1:-}" rc=0 n json down

  for n in "${NODES[@]}"; do
    if ! json=$(timeout 5 bash -c 'docker exec "$1" vtysh -c "$2"' _ "$PREFIX-$n" "show bgp ipv4 unicast summary json" 2>/dev/null); then
      [[ -z "$quiet" ]] && echo "  $n: vtysh unreachable"
      rc=1
      continue
    fi

    down=$(jq -r '(.ipv4Unicast.peers // .peers // {}) | to_entries[]
                  | select(.value.state != "Established")
                  | .key + "(" + (.value.state // "?") + ")"' <<<"$json" | tr '\n' ' ')

    if [[ -n "${down// /}" ]]; then
      [[ -z "$quiet" ]] && echo "  $n: peers not Established -> $down"
      rc=1
    fi
  done

  # Control plane: does PROBE_SRC actually have a route to each loopback?
  # Checked separately from the ping so a failure says *which* plane broke
  # instead of just "unreachable".
  local target src="${LOOPBACK[$PROBE_SRC]}"

  for n in "${NODES[@]}"; do
    [[ "$n" == "$PROBE_SRC" ]] && continue

    target="${LOOPBACK[$n]}"

    if ! timeout 5 bash -c 'docker exec "$1" vtysh -c "$2"' _ "$PREFIX-$PROBE_SRC" "show ip route $target json" 2>/dev/null \
         | jq -e 'length > 0' >/dev/null 2>&1; then
      [[ -z "$quiet" ]] && echo "  $PROBE_SRC: no route to $target ($n) — control plane"
      rc=1
      continue
    fi

    # Data plane. The -I is load-bearing: only the loopbacks are carried in
    # BGP, so an unsourced ping goes out with an interface address
    # (10.1.0.1 / 10.31.0.2) that nothing outside the local region has a
    # route back to. It fails on the return path, not the forward path,
    # which looks identical to a real outage and isn't one.
    if ! timeout 4 docker exec "$PREFIX-$PROBE_SRC" ping -c2 -W1 -I "$src" "$target" \
         >/dev/null 2>&1; then
      [[ -z "$quiet" ]] && echo "  $PROBE_SRC ($src) -> $target ($n): route present but no data plane"
      rc=1
    fi
  done

  if [[ -z "$quiet" ]]; then
    [[ $rc -eq 0 ]] && log "baseline OK — all sessions Established, all loopbacks reachable from $PROBE_SRC" \
                    || log "baseline FAILED — do not inject, do not record trials"
  fi

  return $rc
}

# Poll the baseline until it passes. BGP + OSPF + LDP all need settle time
# after a deploy or a heal (runbook lesson 3), and guessing at a sleep value
# is how you get a phantom failure.
wait_converged() {
  local timeout="${1:-180}" start now

  start=$(date +%s)

  log "waiting up to ${timeout}s for the fabric to converge"

  while :; do
    if baseline quiet; then
      now=$(date +%s)
      log "converged after $((now - start))s"
      return 0
    fi

    now=$(date +%s)

    if (( now - start >= timeout )); then
      log "NOT converged after ${timeout}s — running baseline verbosely:"
      baseline
      return 1
    fi

    sleep 3
  done
}

# ---------------------------------------------------------------- scenarios

# link-down: carrier loss on one end of a veth pair. The peer end loses
# carrier too, so one-sided is enough and is what a real fibre cut looks
# like. Both sides detect it immediately -> this is the fast path.
fail_link_down() {
  local link="$1" a

  read -r a _ <<<"$(endpoints_of "$link")"

  local node="${a%%:*}"
  local iface="${a##*:}"

  dex "$node" ip link set "$iface" down

  record link-down "$link"
}

heal_link_down() {
  local link="$1" a

  read -r a _ <<<"$(endpoints_of "$link")"

  local node="${a%%:*}"
  local iface="${a##*:}"

  dex "$node" ip link set "$iface" up

  forget link-down "$link"
}

# link-blackhole: the interesting one. Link stays UP, packets just vanish.
# Nothing gets a carrier signal, so detection falls back to BGP hold timer
# / OSPF dead interval / IPsec DPD instead of link-state. Expect this to be
# ~2 orders of magnitude slower than link-down — that delta is the whole
# argument for BFD, and it's the graph worth putting in the writeup.
#
# netem is egress-only, so it goes on both ends to kill both directions.
fail_link_blackhole() {
  local link="$1" a b

  read -r a b <<<"$(endpoints_of "$link")"

  log "FAIL link-blackhole $link  (netem loss 100% both directions, link stays UP)"

  for e in "$a" "$b"; do
    sdex "${e%%:*}" tc qdisc add dev "${e##*:}" root netem loss 100%
  done

  record link-blackhole "$link"
}

heal_link_blackhole() {
  local link="$1" a b

  read -r a b <<<"$(endpoints_of "$link")"

  log "HEAL link-blackhole $link"

  for e in "$a" "$b"; do
    sdex "${e%%:*}" tc qdisc del dev "${e##*:}" root 2>/dev/null || true
  done

  forget link-blackhole "$link"
}

# node-down: every data interface on one router goes admin-down. Container
# keeps running (see design rule 1), so the veths survive and this is a
# one-command recovery.
fail_node_down() {
  local node="$1"

  is_node "$node" || die "unknown node '$node'"

  log "FAIL node-down $node  (eth1 + eth2 + eth3 admin-down)"
  dex "$node" ip link set eth1 down
  dex "$node" ip link set eth2 down
  dex "$node" ip link set eth3 down

  record node-down "$node"
}

heal_node_down() {
  local node="$1"

  is_node "$node" || die "unknown node '$node'"

  log "HEAL node-down $node"
  dex "$node" ip link set eth1 up
  dex "$node" ip link set eth2 up
  dex "$node" ip link set eth3 up

  forget node-down "$node"
}

# bgp-freeze: SIGSTOP bgpd. Process alive, TCP sockets still open, kernel
# FIB untouched — just no KEEPALIVEs and no UPDATEs. This is the control
# plane failing while the data plane keeps forwarding, which is the case
# people get wrong in interviews. Recovery is hold-timer bound.
#
# Note: watchfrr will not respawn a stopped process the way it would a
# killed one, which is exactly why SIGSTOP and not SIGKILL.
fail_bgp_freeze() {
  local node="$1"

  is_node "$node" || die "unknown node '$node'"

  log "FAIL bgp-freeze $node  (SIGSTOP bgpd)"

  dex "$node" sh -c 'kill -STOP $(pidof bgpd)'

  record bgp-freeze "$node"
}

heal_bgp_freeze() {
  local node="$1"

  is_node "$node" || die "unknown node '$node'"

  log "HEAL bgp-freeze $node  (SIGCONT bgpd)"
  dex "$node" sh -c 'kill -CONT $(pidof bgpd)' || true

  forget bgp-freeze "$node"
}


# ipsec-down: graceful SA teardown from one end.
#
# `ipsec down <conn>` sends an IKE DELETE. The peer tears its SA down on
# receipt, so this measures graceful teardown and recovery — NOT DPD
# detection.
#
# Conn names follow the transit-<self>-<peer> convention in
# containerlab/strongswan/*/ipsec.conf.
ipsec_conn_for() {
  local link="$1" a b

  read -r a b <<<"$(endpoints_of "$link")"

  echo "${a%%:*} transit-${a%%:*}-${b%%:*}"
}

fail_ipsec_down() {
  local link="$1" node conn

  read -r node conn <<<"$(ipsec_conn_for "$link")"

  log "FAIL ipsec-down $link  ($node: ipsec down $conn)"

  sdex "$node" ipsec down "$conn"

  record ipsec-down "$link"
}

heal_ipsec_down() {
  local link="$1" node conn

  read -r node conn <<<"$(ipsec_conn_for "$link")"

  log "HEAL ipsec-down $link  ($node: ipsec up $conn)"

  sdex "$node" ipsec up "$conn" || true

  forget ipsec-down "$link"
}

# ipsec-freeze: SIGSTOP charon at one end.
#
# Unlike `ipsec down`, which sends an IKE DELETE and tears the peer's SA
# down immediately, freezing charon sends nothing. The peer has to work
# it out for itself, which is what DPD is for.
#
# ipsec.conf uses:
#   dpddelay   10s
#   dpdtimeout 30s
#
# No pidof/pgrep: the sidecar is debian:bookworm-slim plus strongSwan,
# iproute2, iputils-ping and tcpdump — procps is not installed.


charon_pid() {
  local node="$1"

  sdex "$node" sh -c '
    pid=$(cat /run/charon.pid 2>/dev/null || cat /var/run/charon.pid 2>/dev/null)

    case "$pid" in
      ""|*[!0-9]*)
        exit 1
        ;;
    esac

    printf "%s\n" "$pid"
  '
}



fail_ipsec_freeze() {
  local node="$1" pid

  is_node "$node" || die "unknown node '$node'"

  pid=$(charon_pid "$node") || die "could not find charon PID on $node"

  log "FAIL ipsec-freeze $node  (SIGSTOP charon, pid $pid)"
  sdex "$node" sh -c "kill -STOP $pid"

  record ipsec-freeze "$node"
}

heal_ipsec_freeze() {
  local node="$1" pid

  is_node "$node" || die "unknown node '$node'"

  pid=$(charon_pid "$node") || {
    log "HEAL ipsec-freeze $node  (charon PID not found)"
    forget ipsec-freeze "$node"
    return 0
  }

  log "HEAL ipsec-freeze $node  (SIGCONT charon, pid $pid)"
  sdex "$node" sh -c "kill -CONT $pid" || true

  forget ipsec-freeze "$node"
}



# ---------------------------------------------------------------- dispatch

SCENARIOS=(
  link-down
  link-blackhole
  node-down
  bgp-freeze
  ipsec-down
  ipsec-freeze
)


do_fail() {
  local s="$1" t="$2"

  # Injection must be transactional. If a multi-step fault partially
  # succeeds and a later operation fails, immediately undo whatever the
  # scenario may have changed. The heal functions are intentionally
  # idempotent, so this is safe even when nothing was recorded yet.
  if ! case "$s" in
    link-down)
      fail_link_down "$t"
      ;;
    link-blackhole)
      fail_link_blackhole "$t"
      ;;
    node-down)
      fail_node_down "$t"
      ;;
    bgp-freeze)
      fail_bgp_freeze "$t"
      ;;
    ipsec-down)
      fail_ipsec_down "$t"
      ;;
    ipsec-freeze)
      fail_ipsec_freeze "$t"
      ;;
    *)
      die "unknown scenario '$s' (try: ./inject.sh list)"
      ;;
  esac
  then
    log "FAIL injection failed — attempting immediate rollback"
    do_heal "$s" "$t" 2>/dev/null || true
    return 1
  fi
}



do_heal() {
  local s="$1" t="$2"

  case "$s" in
    link-down)
      heal_link_down "$t"
      ;;
    link-blackhole)
      heal_link_blackhole "$t"
      ;;
    node-down)
      heal_node_down "$t"
      ;;
    bgp-freeze)
      heal_bgp_freeze "$t"
      ;;
    ipsec-down)
      heal_ipsec_down "$t"
      ;;
    ipsec-freeze)
      heal_ipsec_freeze "$t"
      ;;
    *)
      die "unknown scenario '$s'"
      ;;
  esac
}

heal_all() {
  [[ -s "$STATE" ]] || {
    log "nothing to heal"
    return 0
  }

  # reverse order: last fault injected is the first one undone.
  #
  # Snapshot first — do_heal calls forget(), which rewrites $STATE, and
  # rewriting a file that is still being read is asking for trouble.
  # Reading from a plain file rather than a pipe also keeps the loop out
  # of a subshell.
  local snap
  snap=$(mktemp)

  tac "$STATE" > "$snap"

  while read -r s t; do
    [[ -n "${s:-}" ]] && do_heal "$s" "$t" || true
  done < "$snap"

  rm -f "$snap"

  : > "$STATE"

  log "heal-all complete"
}

show_status() {
  echo "=== recorded faults ==="

  if [[ -s "$STATE" ]]; then
    sed 's/^/  /' "$STATE"
  else
    echo "  (none)"
  fi

  echo
  echo "=== interface state ==="

  for n in "${NODES[@]}"; do
    printf '  %s: %s\n' "$n" \
      "$(dex "$n" ip -br link show 2>/dev/null |
          awk '$1 ~ /^eth[123]/ {printf "%s=%s ", $1, $2}')"
  done

  echo
  echo "=== netem qdiscs ==="

  local found=0

  for n in "${NODES[@]}"; do
    for i in eth1 eth2 eth3; do
      if sdex "$n" tc qdisc show dev "$i" 2>/dev/null | grep -q netem; then
        echo "  $n $i: netem active"
        found=1
      fi
    done
  done

  [[ $found -eq 0 ]] && echo "  (none)"

  echo
  echo "=== bgpd process state (T = frozen) ==="

  for n in "${NODES[@]}"; do
    printf '  %s: %s\n' "$n" \
      "$(dex "$n" sh -c 'pid=$(pidof bgpd 2>/dev/null); [[ -n "$pid" ]] && awk '\''{print $3}'\'' /proc/$pid/stat 2>/dev/null || echo ?' 2>/dev/null || echo '?')"
  done

  echo

  echo "=== charon process state (T = frozen) ==="

  for n in "${NODES[@]}"; do
    printf '  %-6s %s\n' "$n" \
      "$(pid=$(charon_pid "$n" 2>/dev/null || true)
        if [[ "$pid" =~ ^[0-9]+$ ]]; then
          sdex "$n" awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || echo '?'
        else
          echo '?'
        fi)"
  done


}


show_list() {
  cat <<EOF
scenarios:
  link-down       <link>   carrier loss on a veth pair (fast, link-state detected)
  link-blackhole  <link>   link stays UP, 100% loss (slow, timer detected)
  node-down       <node>   all data interfaces down on one router
  bgp-freeze      <node>   SIGSTOP bgpd — control plane dies, data plane lives
  ipsec-down      <link>   graceful SA teardown from one end (IKE DELETE, not DPD)
  ipsec-freeze    <node>   SIGSTOP charon — peer must detect via DPD

links:
EOF

  for l in "${!LINKS[@]}"; do
    printf '  %-8s %s\n' "$l" "${LINKS[$l]}"
  done | sort

  cat <<EOF

transit links (ring, have an alternate path): ${TRANSIT_LINKS[*]}
intra-region links have no alternate path — failing one partitions a region
on purpose, so expect a blackhole, not a reconvergence.

nodes: ${NODES[*]}

commands:
  preflight        containers up, veths present, netem usable, no stale faults, baseline healthy
  baseline         every BGP session Established + all loopbacks reachable from ${PROBE_SRC}
  wait-converged   poll baseline until it passes (use after every deploy and every heal)
  status           what is currently broken
  heal-all         undo everything, in reverse order
EOF
}

main() {
  local cmd="${1:-}"

  case "$cmd" in
    list)
      show_list
      ;;

    preflight)
      preflight
      ;;

    baseline)
      baseline
      ;;

    wait-converged)
      wait_converged "${2:-180}"
      ;;

    status)
      show_status
      ;;

    heal-all)
      heal_all
      ;;

    heal)
      [[ $# -ge 3 ]] || die "usage: ./inject.sh heal <scenario> <target>"
      do_heal "$2" "$3"
      ;;

    fail)
      [[ $# -ge 3 ]] || die "usage: ./inject.sh fail <scenario> <target> [--for SECONDS]"

      local s="$2"
      local t="$3"
      local dur=""

      if [[ "${4:-}" == "--for" ]]; then
        dur="${5:-}"
        [[ "$dur" =~ ^[0-9]+$ ]] || die "--for needs a number of seconds"
      fi

      if [[ -n "$dur" ]]; then
        # auto-heal on any exit path, including Ctrl-C
        trap 'do_heal "$s" "$t" 2>/dev/null || true' EXIT INT TERM

        do_fail "$s" "$t"

        log "holding fault for ${dur}s"

        sleep "$dur"

        trap - EXIT INT TERM

        do_heal "$s" "$t"
      else
        do_fail "$s" "$t"

        echo
        echo "fault is ACTIVE. heal with:  ./inject.sh heal $s $t"
      fi
      ;;

    ""|-h|--help)
      show_list
      ;;

    *)
      die "unknown command '$cmd'"
      ;;
  esac
}

main "$@"
