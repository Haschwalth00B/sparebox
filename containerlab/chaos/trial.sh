#!/usr/bin/env bash
#
# trial.sh — run N reconvergence trials for one scenario/target and append
# one CSV row per trial. inject.sh breaks things; probe.sh watches; this
# script sequences the two and turns the result into numbers.
#
# What a trial is:
#
#   1. wait for the fabric to converge     (never measure into an unhealthy
#                                           fabric — runbook lesson 3)
#   2. start the probe, confirm it flows
#   3. pre-roll a few seconds of clean traffic
#   4. record t_fault, inject
#   5. wait for the probe to stall, then wait for it to flow again
#      (adaptive, not a fixed sleep: link-down recovers in well under a
#      second, an eBGP blackhole takes up to the 180s hold timer, and
#      hardcoding one number for both either truncates the slow case or
#      wastes an hour on the fast one)
#   6. record t_heal, heal, settle
#   7. stop the probe, measure the gaps around t_fault and t_heal
#
# A fault that produces no outage on this probe path is a result, not an
# error — failing link23 does not affect r1-1 -> r1-2, and recording that
# as 0 is more honest than quietly excluding it.
#
# Usage:
#   ./trial.sh <scenario> <target> [options]
#
#   -n, --trials N     number of trials            (default 20)
#       --src NODE     probe source                (default r1-1)
#       --dst NODE     probe destination           (default r2-1)
#       --interval S   probe interval, seconds     (default 0.02)
#       --grace S      how long to wait for an outage to appear before
#                      calling it "no effect"      (default 15)
#       --max-fault S  cap on how long to hold a fault while waiting for
#                      recovery                    (default 240)
#       --settle S     post-heal observation window (default 20)
#       --out DIR      results directory           (default ./results)
#       --note TEXT    free-text tag written into every row
#
# Examples:
#   ./trial.sh link-down      link12 -n 25
#   ./trial.sh link-blackhole link12 -n 5  --max-fault 300
#   ./trial.sh bgp-freeze     r1-2   -n 20 --max-fault 300
#   ./trial.sh ipsec-freeze   r1-2   -n 20 --max-fault 120 --dst r3-2

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fabric.env
source "$HERE/fabric.env"

INJECT="$HERE/inject.sh"
PROBE="$HERE/probe.sh"

SCEN=""; TARGET=""
TRIALS=20
SRC=r1-1; DST=r2-1
IV=0.02
PREROLL=3
GRACE=15
MAX_FAULT=240
SETTLE=20
OUTDIR="$HERE/results"
NOTE=""

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--trials)   TRIALS="$2"; shift 2 ;;
    --src)         SRC="$2"; shift 2 ;;
    --dst)         DST="$2"; shift 2 ;;
    --interval)    IV="$2"; shift 2 ;;
    --grace)       GRACE="$2"; shift 2 ;;
    --max-fault)   MAX_FAULT="$2"; shift 2 ;;
    --settle)      SETTLE="$2"; shift 2 ;;
    --out)         OUTDIR="$2"; shift 2 ;;
    --note)        NOTE="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    -*)            echo "unknown flag '$1'" >&2; exit 2 ;;
    *)
      if   [[ -z "$SCEN"   ]]; then SCEN="$1"
      elif [[ -z "$TARGET" ]]; then TARGET="$1"
      else echo "unexpected argument '$1'" >&2; exit 2; fi
      shift ;;
  esac
done

[[ -n "$SCEN" && -n "$TARGET" ]] || { usage; exit 2; }
[[ -x "$INJECT" ]] || { echo "trial.sh: $INJECT not found or not executable" >&2; exit 2; }
[[ -n "${LOOPBACK[$SRC]:-}" && -n "${LOOPBACK[$DST]:-}" ]] \
  || { echo "trial.sh: probe pair must be two known nodes" >&2; exit 2; }


# Ctrl-C (or any kill) mid-trial must not leave a fault active on the live
# fabric — same rule inject.sh's own `fail --for` enforces on itself.
# CUR_SCEN/CUR_TARGET are only non-empty while a fault is actually injected.
CUR_SCEN=""; CUR_TARGET=""
cleanup_on_exit() {
  [[ -n "$CUR_SCEN" ]] && "$INJECT" heal "$CUR_SCEN" "$CUR_TARGET" >/dev/null 2>&1
}
trap cleanup_on_exit EXIT INT TERM


# A gap only counts as an outage if it is clearly bigger than the probe
# interval. 5x the interval, floored at 150ms, keeps normal scheduler
# jitter on an 8-year-old i5 from registering as a reconvergence.
GAP=$(awk -v i="$IV" 'BEGIN { g = 5 * i; if (g < 0.15) g = 0.15; printf "%.4f", g }')

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$OUTDIR/raw"
CSV="$OUTDIR/trials.csv"
if [[ ! -f "$CSV" ]]; then
  echo "run,scenario,target,probe_src,probe_dst,trial,fault_outage_s,fault_lag_s,heal_outage_s,heal_lag_s,ttl_before,ttl_after,samples,interval_s,gap_thresh_s,note" > "$CSV"
fi

now()  { date -u +%s.%N; }
since(){ awk -v a="$(now)" -v b="$1" 'BEGIN { printf "%.3f", a - b }'; }

# --------------------------------------------------------------- probe state

# "flowing" = a reply landed within the last $2 seconds.
flowing() {
  local f="$1" stale="${2:-0.4}" last
  last=$(tail -n1 "$f" 2>/dev/null | awk '{print $1}')
  [[ -n "$last" ]] || return 1
  awk -v n="$(now)" -v l="$last" -v s="$stale" 'BEGIN { exit !((n - l) < s) }'
}

wait_flowing() {
  local f="$1" to="$2" t0; t0=$(now)
  while :; do
    flowing "$f" && return 0
    awk -v e="$(since "$t0")" -v t="$to" 'BEGIN { exit !(e >= t) }' && return 1
    sleep 0.1
  done
}

wait_stalled() {
  local f="$1" to="$2" t0; t0=$(now)
  while :; do
    flowing "$f" || return 0
    awk -v e="$(since "$t0")" -v t="$to" 'BEGIN { exit !(e >= t) }' && return 1
    sleep 0.05
  done
}

stop_probe() {
  local pid="$1"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  # belt and braces: the probe's own EXIT trap should have done this, but
  # if it was SIGKILLed the ping inside the container survives until its -w
  # deadline and would bleed ICMP into the next trial.
  docker exec "$CLAB_PREFIX-ipsec-$SRC" sh -c '
    for p in /proc/[0-9]*; do
      [ "$(cat "$p/comm" 2>/dev/null)" = ping ] && kill -INT "${p#/proc/}" 2>/dev/null
    done' >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------- metrics

# Find the first gap that ends after the fault, and the first gap after
# that which ends after the heal. Anchoring on the gap's *end* rather than
# its start matters: when a fault takes effect instantly the last good
# reply is a few milliseconds before t_fault, and anchoring on the start
# would miss it.
#
# fault_lag is how long traffic kept flowing after injection — detection
# time, effectively. fault_outage is the blackhole itself.
metrics() {
  awk -v tf="$2" -v th="$3" -v gap="$GAP" '
    { ts[NR] = $1; tl[NR] = $4 }
    END {
      fo = 0; flag = 0; ho = 0; hlag = 0; tpre = "-"; tpost = "-"; fi = 0
      for (i = 1; i < NR; i++) {
        d = ts[i+1] - ts[i]
        if (d <= gap) continue
        if (fi == 0 && ts[i+1] > tf && ts[i] < th) {
          fi = i; fo = d; flag = ts[i] - tf; tpre = tl[i]; tpost = tl[i+1]
          continue
        }
        if (ho == 0 && fi != 0 && i > fi && ts[i+1] > th) {
          ho = d; hlag = ts[i] - th
        }
      }
      if (flag < 0) flag = 0
      if (hlag < 0) hlag = 0
      printf "%.4f %.4f %.4f %.4f %s %s %d\n", fo, flag, ho, hlag, tpre, tpost, NR
    }' "$1"
}

# ---------------------------------------------------------------------- run

echo "run $STAMP — $SCEN $TARGET, $TRIALS trials, probe ${SRC}(${LOOPBACK[$SRC]}) -> ${DST}(${LOOPBACK[$DST]})"
echo "interval ${IV}s, gap threshold ${GAP}s, max fault ${MAX_FAULT}s, results -> $CSV"
echo

# Never start a run on top of someone else's leftover fault.
"$INJECT" heal-all >/dev/null 2>&1 || true

for ((i = 1; i <= TRIALS; i++)); do
  printf '── trial %d/%d  ' "$i" "$TRIALS"

  if ! "$INJECT" wait-converged 180; then
    echo
    echo "fabric did not converge within 180s — stopping. Run './inject.sh preflight'."
    exit 1
  fi

  raw="$OUTDIR/raw/${STAMP}_${SCEN}_${TARGET}_$(printf '%03d' "$i").txt"
  deadline=$(( PREROLL + MAX_FAULT + SETTLE + 60 ))
  "$PROBE" "$SRC" "$DST" "$IV" "$deadline" > "$raw" 2>/dev/null &
  probe_pid=$!

  if ! wait_flowing "$raw" 15; then
    echo "probe never flowed — skipping (check ./probe.sh $SRC $DST by hand)"
    stop_probe "$probe_pid"
    continue
  fi
  sleep "$PREROLL"

  t_fault=$(now)
  "$INJECT" fail "$SCEN" "$TARGET" >/dev/null
  CUR_SCEN="$SCEN"; CUR_TARGET="$TARGET"

  if wait_stalled "$raw" "$GRACE"; then
    if wait_flowing "$raw" "$MAX_FAULT"; then
      printf 'outage %ss  ' "$(since "$t_fault")"
    else
      printf 'NO RECOVERY in %ss  ' "$MAX_FAULT"
    fi
    sleep 1
  else
    printf 'no effect on this path  '
  fi

  t_heal=$(now)
  "$INJECT" heal "$SCEN" "$TARGET" >/dev/null
  CUR_SCEN=""; CUR_TARGET=""
  sleep "$SETTLE"


  stop_probe "$probe_pid"

  read -r f_out f_lag h_out h_lag ttl_pre ttl_post n < <(metrics "$raw" "$t_fault" "$t_heal")

  printf '%s,%s,%s,%s,%s,%d,%s,%s,%s,%s,%s,%s,%d,%s,%s,%s\n' \
    "$STAMP" "$SCEN" "$TARGET" "$SRC" "$DST" "$i" \
    "$f_out" "$f_lag" "$h_out" "$h_lag" "$ttl_pre" "$ttl_post" "$n" \
    "$IV" "$GAP" "$NOTE" >> "$CSV"

  printf 'fault=%ss lag=%ss heal=%ss ttl %s->%s\n' "$f_out" "$f_lag" "$h_out" "$ttl_pre" "$ttl_post"
done

echo
"$INJECT" heal-all >/dev/null 2>&1 || true
"$INJECT" wait-converged 180 >/dev/null || echo "WARNING: fabric not converged after the run"
echo "done. $TRIALS trials appended to $CSV"
echo "analyse with: ./analyze.sh $CSV"

