#!/usr/bin/env bash
#
# probe.sh — high-rate reachability probe. One line per reply, nothing on
# loss, so an outage is a gap in the output. trial.sh measures those gaps.
#
# Runs ping inside <src>'s strongSwan sidecar rather than the router. The
# sidecar shares the router's network namespace (confirmed: identical
# net:[inode] for all six pairs), so this measures the router's own data
# plane — same trick already used for tcpdump in Week 5. The reason to
# bother: the FRR image is Alpine and its ping is busybox, which has no -D
# timestamps and no sub-second interval. At busybox's 1s floor a
# sub-second reconvergence is invisible, so p50/p95 for link-down would be
# measuring the probe, not the fabric. The sidecar is Debian with iputils
# 20221126: -i 0.02 and microsecond -D both work (verified, 20 packets in
# 970ms).
#
# -I <loopback> is load-bearing. Only loopbacks are carried in BGP, so an
# unsourced probe leaves with an interface address (10.1.0.1 / 10.31.0.2)
# that nothing outside the local region has a route back to. Verified: an
# unsourced r1-1 -> r2-1 ping is 100% loss on a completely healthy fabric,
# while the same ping sourced from 10.0.1.1 is 0% loss.
#
# Output format, one line per reply:
#     <epoch_seconds.micros> <icmp_seq> <rtt_ms> <ttl>
#
# TTL is carried through deliberately: a TTL change across an outage proves
# traffic returned on a *different* path (real reconvergence) rather than
# the original path simply coming back. That distinction is the difference
# between "BGP reconverged" and "the link flapped and healed itself", and
# it is worth having in the data rather than inferring it later.
#
# Usage: ./probe.sh <src-node> <dst-node> [interval] [deadline]
#   interval  seconds between probes (default 0.02 = 50pps)
#   deadline  hard stop, seconds (default 600). ping enforces this itself
#             via -w, and it runs under `timeout` as well, so the probe
#             cannot outlive its trial even if the caller is killed.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fabric.env
source "$HERE/fabric.env"

src="${1:-}"; dst="${2:-}"
iv="${3:-0.02}"
deadline="${4:-600}"

if [[ -z "$src" || -z "$dst" ]]; then
  echo "usage: ./probe.sh <src-node> <dst-node> [interval] [deadline]" >&2
  echo "nodes: ${NODES[*]}" >&2
  exit 2
fi

s="${LOOPBACK[$src]:-}"
d="${LOOPBACK[$dst]:-}"
[[ -n "$s" ]] || { echo "probe.sh: unknown node '$src'" >&2; exit 2; }
[[ -n "$d" ]] || { echo "probe.sh: unknown node '$dst'" >&2; exit 2; }

ctr="$CLAB_PREFIX-ipsec-$src"

# Killing `docker exec` on the host does not kill the process inside the
# container, so clean up explicitly. Done with a /proc walk rather than
# pkill/pidof because debian:bookworm-slim does not ship procps and the
# sidecar image only adds strongswan, iproute2, iputils-ping and tcpdump.
stop_inner() {
  docker exec "$ctr" sh -c '
    for p in /proc/[0-9]*; do
      [ "$(cat "$p/comm" 2>/dev/null)" = ping ] && kill -INT "${p#/proc/}" 2>/dev/null
    done' >/dev/null 2>&1 || true
}
trap stop_inner EXIT INT TERM

# stdbuf -oL inside the container: without it ping block-buffers when its
# stdout is a pipe, and trial.sh's liveness check reads a file that only
# updates every 4KB — which reads as a 30-second outage that never happened.
docker exec "$ctr" stdbuf -oL timeout "$deadline" \
  ping -n -D -i "$iv" -W 1 -w "$deadline" -I "$s" "$d" 2>/dev/null \
| awk '
    /bytes from/ {
      ts = $1; gsub(/[\[\]]/, "", ts)
      seq = ""; rtt = ""; ttl = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^icmp_seq=/) { split($i, a, "="); seq = a[2] }
        if ($i ~ /^ttl=/)      { split($i, a, "="); ttl = a[2] }
        if ($i ~ /^time=/)     { split($i, a, "="); rtt = a[2] }
      }
      print ts, seq, rtt, ttl
      fflush()
    }'

