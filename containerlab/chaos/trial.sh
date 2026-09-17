#!/usr/bin/env bash
#
# trial.sh — automated HA/failover trials for the Sparebox fabric.
#
# Safe design:
#   - never modifies inject.sh, probe.sh, fabric.env, topology or FRR
#   - never overwrites the old results/trials.csv
#   - records kernel-route changes as well as packet-loss gaps
#   - handles zero-loss failover as a successful HA result
#
# A trial:
#   1. ensure the fabric is healthy
#   2. start a high-frequency ICMP probe
#   3. record the currently selected kernel route
#   4. inject the requested fault
#   5. watch for either:
#        a) route change, and/or
#        b) packet loss
#   6. heal the fault
#   7. verify the original route returns when possible
#   8. append one CSV row
#
# This is intentionally different from the old outage-only trial model:
# a redundant link-down can produce ZERO packet loss while still proving
# failover through a route change.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/fabric.env"

INJECT="$HERE/inject.sh"
PROBE="$HERE/probe.sh"

SCEN=""
TARGET=""

TRIALS=20
SRC=r1-1
DST=r2-1

IV=0.02
PREROLL=1
GRACE=5
MAX_FAULT=15
SETTLE=2
ROUTE_POLL=0.02

OUTDIR="$HERE/results"
CSV="$OUTDIR/failover-trials.csv"
NOTE=""

usage() {
  cat <<USAGE
trial.sh — automated failover/reconvergence trials

Usage:
  ./trial.sh <scenario> <target> [options]

Options:
  -n, --trials N       number of trials       (default 20)
      --src NODE       probe source          (default r1-1)
      --dst NODE       probe destination     (default r2-1)
      --interval S     ICMP interval         (default 0.02)
      --grace S        initial fault grace   (default 5)
      --max-fault S    maximum fault hold    (default 15)
      --settle S       post-heal wait        (default 2)
      --route-poll S   route polling period  (default 0.02)
      --out DIR        results directory
                       (default ./results)
      --note TEXT      note written to rows
  -h, --help           show this help

Examples:

  ./trial.sh link-down link12 -n 20 \
    --src r1-2 --dst r2-1 \
    --note "primary-link-failover"

  ./trial.sh link-down link23 -n 20 \
    --src r2-2 --dst r3-1 \
    --note "primary-link-failover"

  ./trial.sh link-down link31 -n 20 \
    --src r3-2 --dst r1-1 \
    --note "primary-link-failover"

Notes:
  - Existing chaos/results/trials.csv is NOT modified.
  - New results are written to:
      chaos/results/failover-trials.csv
  - Route changes are measured independently of packet loss.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--trials)
      TRIALS="$2"
      shift 2
      ;;
    --src)
      SRC="$2"
      shift 2
      ;;
    --dst)
      DST="$2"
      shift 2
      ;;
    --interval)
      IV="$2"
      shift 2
      ;;
    --grace)
      GRACE="$2"
      shift 2
      ;;
    --max-fault)
      MAX_FAULT="$2"
      shift 2
      ;;
    --settle)
      SETTLE="$2"
      shift 2
      ;;
    --route-poll)
      ROUTE_POLL="$2"
      shift 2
      ;;
    --out)
      OUTDIR="$2"
      CSV="$OUTDIR/failover-trials.csv"
      shift 2
      ;;
    --note)
      NOTE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "trial.sh: unknown flag '$1'" >&2
      exit 2
      ;;
    *)
      if [[ -z "$SCEN" ]]; then
        SCEN="$1"
      elif [[ -z "$TARGET" ]]; then
        TARGET="$1"
      else
        echo "trial.sh: unexpected argument '$1'" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

[[ -n "$SCEN" && -n "$TARGET" ]] || {
  usage
  exit 2
}

[[ -x "$INJECT" ]] || {
  echo "trial.sh: $INJECT not found or not executable" >&2
  exit 2
}

[[ -x "$PROBE" ]] || {
  echo "trial.sh: $PROBE not found or not executable" >&2
  exit 2
}

[[ -n "${LOOPBACK[$SRC]:-}" && -n "${LOOPBACK[$DST]:-}" ]] || {
  echo "trial.sh: probe pair must be two known nodes" >&2
  exit 2
}

[[ "$TRIALS" =~ ^[0-9]+$ && "$TRIALS" -gt 0 ]] || {
  echo "trial.sh: --trials must be a positive integer" >&2
  exit 2
}

mkdir -p "$OUTDIR/raw"

# ---------------------------------------------------------------------------
# CSV
#
# This is intentionally a NEW file so the old trials.csv remains untouched.
# ---------------------------------------------------------------------------

if [[ ! -f "$CSV" ]]; then
  cat > "$CSV" <<'CSV_HEADER'
run,scenario,target,probe_src,probe_dst,trial,route_before,route_after,route_change,route_change_s,packet_loss_s,loss_lag_s,heal_route_change_s,ttl_before,ttl_after,samples,interval_s,note
CSV_HEADER
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

now() {
  date -u +%s.%N
}

elapsed() {
  awk -v a="$(now)" -v b="$1" 'BEGIN { printf "%.6f", a - b }'
}

# ---------------------------------------------------------------------------
# Runtime state / cleanup
# ---------------------------------------------------------------------------

CUR_SCEN=""
CUR_TARGET=""
PROBE_PID=""
ROUTE_PID=""

cleanup_on_exit() {
  if [[ -n "$CUR_SCEN" ]]; then
    "$INJECT" heal "$CUR_SCEN" "$CUR_TARGET" >/dev/null 2>&1 || true
  fi

  if [[ -n "$PROBE_PID" ]]; then
    kill "$PROBE_PID" >/dev/null 2>&1 || true
    wait "$PROBE_PID" >/dev/null 2>&1 || true
  fi

  if [[ -n "$ROUTE_PID" ]]; then
    kill "$ROUTE_PID" >/dev/null 2>&1 || true
    wait "$ROUTE_PID" >/dev/null 2>&1 || true
  fi
}

trap cleanup_on_exit EXIT INT TERM

# ---------------------------------------------------------------------------
# Kernel route
#
# The IPsec sidecar shares the router network namespace, so querying the
# sidecar gives us the same kernel routing decision as the FRR router.
# ---------------------------------------------------------------------------


route_now() {
  local container="$CLAB_PREFIX-ipsec-$SRC"
  local dst_ip="${LOOPBACK[$DST]}"

  docker exec "$container" sh -c \
    "ip route get '$dst_ip' 2>/dev/null" |
    sed -n 's/.*via \([^ ]*\).*dev \(eth[123]\).*/via \1 dev \2/p' |
    head -n1
}


route_raw() {
  local container="$CLAB_PREFIX-ipsec-$SRC"
  local dst_ip="${LOOPBACK[$DST]}"

  docker exec "$container" sh -c \
    "ip route get '$dst_ip' 2>/dev/null" |
    head -n1
}

# ---------------------------------------------------------------------------
# Route monitor
#
# Format:
#   timestamp route
#
# Example:
#   1758012345.123456 via 10.12.0.2 dev eth2
#   1758012345.143456 via 10.35.0.1 dev eth3
# ---------------------------------------------------------------------------

start_route_monitor() {
  local outfile="$1"

  (
    while :; do
      ts="$(now)"
      r="$(route_now || true)"

      if [[ -n "$r" ]]; then
        printf '%s %s\n' "$ts" "$r"
      fi

      sleep "$ROUTE_POLL"
    done
  ) > "$outfile" 2>/dev/null &

  echo $!
}

# ---------------------------------------------------------------------------
# Probe
# ---------------------------------------------------------------------------

start_probe() {
  local outfile="$1"
  local deadline="$2"

  "$PROBE" "$SRC" "$DST" "$IV" "$deadline" > "$outfile" 2>/dev/null &
  echo $!
}

probe_flowing() {
  local f="$1"
  local stale="${2:-0.4}"
  local last

  last="$(tail -n1 "$f" 2>/dev/null | awk '{print $1}')"

  [[ -n "$last" ]] || return 1

  awk -v n="$(now)" -v l="$last" -v s="$stale" \
    'BEGIN { exit !((n-l) < s) }'
}

wait_probe() {
  local f="$1"
  local timeout="$2"
  local t0

  t0="$(now)"

  while :; do
    probe_flowing "$f" && return 0

    if awk -v e="$(elapsed "$t0")" -v t="$timeout" \
      'BEGIN { exit !(e >= t) }'; then
      return 1
    fi

    sleep 0.05
  done
}

stop_probe() {
  local pid="$1"

  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true

  docker exec "$CLAB_PREFIX-ipsec-$SRC" sh -c '
    for p in /proc/[0-9]*; do
      [ "$(cat "$p/comm" 2>/dev/null)" = ping ] &&
        kill -INT "${p#/proc/}" 2>/dev/null || true
    done
  ' >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Route metrics
# ---------------------------------------------------------------------------

route_metrics() {
  local file="$1"
  local t_fault="$2"
  local t_heal="$3"
  local route_before="$4"

  awk \
    -v tf="$t_fault" \
    -v th="$t_heal" \
    -v rb="$route_before" '
    {
      ts=$1
      $1=""
      sub(/^ /,"")
      route=$0

      if (first_route == "") {
        first_route=route
      }

      if (route != rb && change_ts == 0 && ts >= tf && ts < th) {
        change_ts=ts
        route_after=route
      }

      if (ts >= th && heal_ts == 0 && route == rb && change_ts != 0) {
        heal_ts=ts
      }

      last_route=route
    }

    END {
      changed=0
      change_s=0
      heal_s=0

      if (change_ts != 0) {
        changed=1
        change_s=change_ts-tf
      }

      if (heal_ts != 0) {
        heal_s=heal_ts-th
      }

      printf "%d %.6f %.6f %s\n",
        changed,
        change_s,
        heal_s,
        (route_after == "" ? "-" : route_after)
    }' "$file"
}

# ---------------------------------------------------------------------------
# Packet-loss metrics
#
# Uses probe timestamps. A gap > GAP is a loss/outage.
# ---------------------------------------------------------------------------

GAP="$(awk -v i="$IV" \
  'BEGIN {
     g=5*i
     if (g < 0.15) g=0.15
     printf "%.4f",g
   }')"

probe_metrics() {
  local file="$1"
  local t_fault="$2"
  local t_heal="$3"

  awk \
    -v tf="$t_fault" \
    -v th="$t_heal" \
    -v gap="$GAP" '
    {
      ts[NR]=$1
      ttl[NR]=$4
    }

    END {
      outage=0
      lag=0
      tpre="-"
      tpost="-"

      for (i=1; i<NR; i++) {
        d=ts[i+1]-ts[i]

        if (d <= gap)
          continue

        # Gap begins before heal and ends after fault.
        if (outage == 0 && ts[i] < th && ts[i+1] > tf) {
          outage=d
          lag=ts[i]-tf

          if (lag < 0)
            lag=0

          tpre=ttl[i]
          tpost=ttl[i+1]
        }
      }

      if (lag < 0)
        lag=0

      printf "%.6f %.6f %s %s %d\n",
        outage, lag, tpre, tpost, NR
    }' "$file"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo "run $STAMP — $SCEN $TARGET, $TRIALS trials"
echo "probe ${SRC}(${LOOPBACK[$SRC]}) -> ${DST}(${LOOPBACK[$DST]})"
echo "ICMP interval ${IV}s, route poll ${ROUTE_POLL}s"
echo "max fault ${MAX_FAULT}s, results -> $CSV"
echo

"$INJECT" heal-all >/dev/null 2>&1 || true

for ((i=1; i<=TRIALS; i++)); do
  printf '── trial %d/%d  ' "$i" "$TRIALS"

  # Always begin from a known-good fabric.
  if ! "$INJECT" wait-converged 30 >/dev/null 2>&1; then
    echo
    echo "fabric did not converge within 30s — stopping."
    echo "Run: ./chaos/inject.sh preflight"
    exit 1
  fi

  route_before="$(route_now || true)"

  if [[ -z "$route_before" ]]; then
    echo
    echo "could not determine route before fault — stopping."
    exit 1
  fi

  raw="$OUTDIR/raw/${STAMP}_${SCEN}_${TARGET}_$(printf '%03d' "$i").txt"
  route_raw_file="$OUTDIR/raw/${STAMP}_${SCEN}_${TARGET}_$(printf '%03d' "$i")_route.txt"

  # Probe only needs to live slightly longer than this trial.
  probe_deadline="$(
    awk -v p="$PREROLL" -v m="$MAX_FAULT" -v s="$SETTLE" \
      'BEGIN { printf "%.0f", p+m+s+10 }'
  )"

  PROBE_PID="$(start_probe "$raw" "$probe_deadline")"
  ROUTE_PID="$(start_route_monitor "$route_raw_file")"

  if ! wait_probe "$raw" 5; then
    echo
    echo "probe never flowed — stopping."
    stop_probe "$PROBE_PID"
    PROBE_PID=""
    kill "$ROUTE_PID" >/dev/null 2>&1 || true
    wait "$ROUTE_PID" >/dev/null 2>&1 || true
    ROUTE_PID=""
    exit 1
  fi

  # Give the route monitor time to record the stable pre-fault route.
  sleep "$PREROLL"

  t_fault="$(now)"

  "$INJECT" fail "$SCEN" "$TARGET" >/dev/null
  CUR_SCEN="$SCEN"
  CUR_TARGET="$TARGET"

  # For fast failover, wait only until either route changes or the
  # configured grace period expires. We do NOT wait 240 seconds.
  route_changed=0
  route_change_s=0
  route_after="-"

  route_deadline="$(awk -v t="$t_fault" -v g="$GRACE" \
    'BEGIN { printf "%.6f", t+g }')"

  while :; do
    result="$(route_metrics "$route_raw_file" "$t_fault" "9999999999" "$route_before")"

    read -r rc rcs _ route_candidate <<<"$result"

    if [[ "$rc" == "1" ]]; then
      route_changed=1
      route_change_s="$rcs"
      route_after="$route_candidate"
      break
    fi

    if awk -v n="$(now)" -v d="$route_deadline" \
      'BEGIN { exit !(n >= d) }'; then
      break
    fi

    sleep "$ROUTE_POLL"
  done

  # If route did not change during the short grace period, continue watching
  # for packet loss/recovery up to MAX_FAULT. This supports slow eBGP
  # blackholes and freeze scenarios without making fast link-down trials slow.
  fault_elapsed="$(elapsed "$t_fault")"

  packet_outage=0

  while awk -v e="$fault_elapsed" -v m="$MAX_FAULT" \
    'BEGIN { exit !(e < m) }'; do

    if ! probe_flowing "$raw"; then
      packet_outage=1
      break
    fi

    if [[ "$route_changed" == "1" ]]; then
      break
    fi

    sleep 0.05
    fault_elapsed="$(elapsed "$t_fault")"
  done

  t_heal="$(now)"

  "$INJECT" heal "$SCEN" "$TARGET" >/dev/null
  CUR_SCEN=""
  CUR_TARGET=""

  sleep "$SETTLE"

  stop_probe "$PROBE_PID"
  PROBE_PID=""

  kill "$ROUTE_PID" >/dev/null 2>&1 || true
  wait "$ROUTE_PID" >/dev/null 2>&1 || true
  ROUTE_PID=""

  route_metrics_out="$(route_metrics \
    "$route_raw_file" \
    "$t_fault" \
    "$t_heal" \
    "$route_before")"

  read -r route_changed_final route_change_s_final heal_route_change_s route_after_final \
    <<<"$route_metrics_out"

  # Prefer the route transition found during the active fault window.
  if [[ "$route_changed" == "1" ]]; then
    route_changed_final=1
    route_change_s_final="$route_change_s"
    route_after_final="$route_after"
  fi

  probe_metrics_out="$(probe_metrics "$raw" "$t_fault" "$t_heal")"

  read -r packet_loss_s loss_lag_s ttl_before ttl_after samples \
    <<<"$probe_metrics_out"

  if [[ "$route_changed_final" == "1" ]]; then
    route_status="PATH-CHANGE"
  else
    route_status="NO-PATH-CHANGE"
  fi

  if awk -v x="$packet_loss_s" 'BEGIN { exit !(x > 0) }'; then
    loss_status="LOSS"
  else
    loss_status="ZERO-LOSS"
  fi

  printf '%s,%s,%s,%s,%s,%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%d,%s,%s\n' \
    "$STAMP" \
    "$SCEN" \
    "$TARGET" \
    "$SRC" \
    "$DST" \
    "$i" \
    "$route_before" \
    "$route_after_final" \
    "$route_changed_final" \
    "$route_change_s_final" \
    "$packet_loss_s" \
    "$loss_lag_s" \
    "$heal_route_change_s" \
    "$ttl_before" \
    "$ttl_after" \
    "$samples" \
    "$IV" \
    "$NOTE" >> "$CSV"

  printf '%s  route=%ss  loss=%ss  heal=%ss  %s/%s\n' \
    "$route_status" \
    "$route_change_s_final" \
    "$packet_loss_s" \
    "$heal_route_change_s" \
    "$route_status" \
    "$loss_status"
done

"$INJECT" heal-all >/dev/null 2>&1 || true
"$INJECT" wait-converged 30 >/dev/null 2>&1 || \
  echo "WARNING: fabric not converged after the run"

echo
echo "done. $TRIALS trials appended to $CSV"
echo "analyse with: ./chaos/analyze.sh $CSV"
