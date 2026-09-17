#!/usr/bin/env bash
#
# analyze.sh — analyze Sparebox HA/failover trial results.
#
# Reports:
#   route-change detection
#   packet-loss outage
#   packet-loss detection lag
#   heal/revert timing
#   zero-loss failover rate
#
# Percentiles use nearest-rank, matching the original analyzer.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CSV="$HERE/results/failover-trials.csv"

CSV="$DEFAULT_CSV"
MODE="table"

usage() {
  cat <<USAGE
analyze.sh — analyze failover-trials.csv

Usage:
  ./analyze.sh [results/failover-trials.csv] [--csv]

Options:
  --csv       machine-readable CSV output
  -h, --help  show this help

Default:
  $DEFAULT_CSV
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -n "${1:-}" && "$1" != "--csv" ]]; then
  CSV="$1"
fi

for arg in "$@"; do
  [[ "$arg" == "--csv" ]] && MODE="csv"
done

[[ -f "$CSV" ]] || {
  echo "analyze.sh: no such file: $CSV" >&2
  exit 2
}

# ---------------------------------------------------------------------------
# CSV columns
# ---------------------------------------------------------------------------

C_SCEN=2
C_TGT=3
C_SRC=4
C_DST=5
C_ROUTE_BEFORE=7
C_ROUTE_AFTER=8
C_ROUTE_CHANGE=9
C_ROUTE_CHANGE_S=10
C_PACKET_LOSS=11
C_LOSS_LAG=12
C_HEAL=13

# ---------------------------------------------------------------------------
# Percentiles
# ---------------------------------------------------------------------------

pct() {
  local p="$1"

  awk -v p="$p" '
    { v[NR]=$1 }

    END {
      if (NR == 0) {
        print "-"
        exit
      }

      i=int((p/100)*NR+0.9999)

      if (i < 1) i=1
      if (i > NR) i=NR

      printf "%.3f",v[i]
    }'
}

stats() {
  local file="$1"
  local n

  n="$(wc -l < "$file")"

  if [[ "$n" -eq 0 ]]; then
    echo "0 - - - - -"
    return
  fi

  printf '%s %s %s %s %s %s' \
    "$n" \
    "$(head -n1 "$file")" \
    "$(pct 50 < "$file")" \
    "$(pct 90 < "$file")" \
    "$(pct 95 < "$file")" \
    "$(tail -n1 "$file")"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---------------------------------------------------------------------------
# Validate header
# ---------------------------------------------------------------------------

header="$(head -n1 "$CSV")"

if [[ "$header" != *"route_change_s"* ]]; then
  echo "analyze.sh: this is the old trials.csv format." >&2
  echo >&2
  echo "Use the new file:" >&2
  echo "  ./chaos/analyze.sh chaos/results/failover-trials.csv" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Group keys
# ---------------------------------------------------------------------------

keys="$(
  awk -F, \
    -v s="$C_SCEN" \
    -v t="$C_TGT" \
    -v a="$C_SRC" \
    -v b="$C_DST" '
      NR > 1 && NF > 5 {
        print $s "|" $t "|" $a "|" $b
      }
    ' "$CSV" | sort -u
)"

[[ -n "$keys" ]] || {
  echo "no trial rows in $CSV"
  exit 0
}

if [[ "$MODE" == "table" ]]; then
  printf '%-16s %-8s %-13s %-18s %3s %9s %9s %9s %9s %9s\n' \
    SCENARIO TARGET PROBE METRIC n min p50 p90 p95 max

  printf '%s\n' "$(printf '%.0s─' {1..116})"
fi

# ---------------------------------------------------------------------------
# Statistics
# ---------------------------------------------------------------------------

while IFS='|' read -r scen tgt src dst; do

  # Route-change detection.
  awk -F, \
    -v s="$C_SCEN" \
    -v t="$C_TGT" \
    -v a="$C_SRC" \
    -v b="$C_DST" \
    -v c="$C_ROUTE_CHANGE_S" \
    -v ks="$scen" \
    -v kt="$tgt" \
    -v ka="$src" \
    -v kb="$dst" '
      NR > 1 &&
      $s == ks &&
      $t == kt &&
      $a == ka &&
      $b == kb &&
      $9 == 1 {
        print $c + 0
      }
    ' "$CSV" |
    sort -g > "$tmp/route"

  # Packet loss.
  awk -F, \
    -v s="$C_SCEN" \
    -v t="$C_TGT" \
    -v a="$C_SRC" \
    -v b="$C_DST" \
    -v c="$C_PACKET_LOSS" \
    -v ks="$scen" \
    -v kt="$tgt" \
    -v ka="$src" \
    -v kb="$dst" '
      NR > 1 &&
      $s == ks &&
      $t == kt &&
      $a == ka &&
      $b == kb {
        print $c + 0
      }
    ' "$CSV" |
    sort -g > "$tmp/loss"

  # Loss detection lag.
  awk -F, \
    -v s="$C_SCEN" \
    -v t="$C_TGT" \
    -v a="$C_SRC" \
    -v b="$C_DST" \
    -v c="$C_LOSS_LAG" \
    -v ks="$scen" \
    -v kt="$tgt" \
    -v ka="$src" \
    -v kb="$dst" '
      NR > 1 &&
      $s == ks &&
      $t == kt &&
      $a == ka &&
      $b == kb &&
      ($11 + 0) > 0 {
        print $c + 0
      }
    ' "$CSV" |
    sort -g > "$tmp/lag"

  # Heal/revert.
  awk -F, \
    -v s="$C_SCEN" \
    -v t="$C_TGT" \
    -v a="$C_SRC" \
    -v b="$C_DST" \
    -v c="$C_HEAL" \
    -v ks="$scen" \
    -v kt="$tgt" \
    -v ka="$src" \
    -v kb="$dst" '
      NR > 1 &&
      $s == ks &&
      $t == kt &&
      $a == ka &&
      $b == kb &&
      ($c + 0) > 0 {
        print $c + 0
      }
    ' "$CSV" |
    sort -g > "$tmp/heal"

  if [[ "$MODE" == "table" ]]; then

    read -r n mn p50 p90 p95 mx <<<"$(stats "$tmp/route")"

    printf '%-16s %-8s %-13s %-18s %3s %9s %9s %9s %9s %9s\n' \
      "$scen" "$tgt" "$src->$dst" \
      "route_change_s" \
      "$n" "$mn" "$p50" "$p90" "$p95" "$mx"

    read -r n mn p50 p90 p95 mx <<<"$(stats "$tmp/loss")"

    printf '%-16s %-8s %-13s %-18s %3s %9s %9s %9s %9s %9s\n' \
      "$scen" "$tgt" "$src->$dst" \
      "packet_loss_s" \
      "$n" "$mn" "$p50" "$p90" "$p95" "$mx"

    read -r n mn p50 p90 p95 mx <<<"$(stats "$tmp/lag")"

    printf '%-16s %-8s %-13s %-18s %3s %9s %9s %9s %9s %9s\n' \
      "$scen" "$tgt" "$src->$dst" \
      "loss_detection_s" \
      "$n" "$mn" "$p50" "$p90" "$p95" "$mx"

    read -r n mn p50 p90 p95 mx <<<"$(stats "$tmp/heal")"

    printf '%-16s %-8s %-13s %-18s %3s %9s %9s %9s %9s %9s\n' \
      "$scen" "$tgt" "$src->$dst" \
      "heal_route_s" \
      "$n" "$mn" "$p50" "$p90" "$p95" "$mx"

    echo

  else

    read -r rn rmin rp50 rp90 rp95 rmax <<<"$(stats "$tmp/route")"
    read -r ln lmin lp50 lp90 lp95 lmax <<<"$(stats "$tmp/loss")"
    read -r dn dmin dp50 dp90 dp95 dmax <<<"$(stats "$tmp/lag")"
    read -r hn hmin hp50 hp90 hp95 hmax <<<"$(stats "$tmp/heal")"

    printf '%s,%s,%s,%s,route_change_s,%s,%s,%s,%s,%s,%s\n' \
      "$scen" "$tgt" "$src" "$dst" \
      "$rn" "$rmin" "$rp50" "$rp90" "$rp95" "$rmax"

    printf '%s,%s,%s,%s,packet_loss_s,%s,%s,%s,%s,%s,%s\n' \
      "$scen" "$tgt" "$src" "$dst" \
      "$ln" "$lmin" "$lp50" "$lp90" "$lp95" "$lmax"

    printf '%s,%s,%s,%s,loss_detection_s,%s,%s,%s,%s,%s,%s\n' \
      "$scen" "$tgt" "$src" "$dst" \
      "$dn" "$dmin" "$dp50" "$dp90" "$dp95" "$dmax"

    printf '%s,%s,%s,%s,heal_route_s,%s,%s,%s,%s,%s,%s\n' \
      "$scen" "$tgt" "$src" "$dst" \
      "$hn" "$hmin" "$hp50" "$hp90" "$hp95" "$hmax"

  fi

  # -------------------------------------------------------------------------
  # HA summary
  # -------------------------------------------------------------------------

  awk -F, \
    -v s="$C_SCEN" \
    -v t="$C_TGT" \
    -v a="$C_SRC" \
    -v b="$C_DST" \
    -v ks="$scen" \
    -v kt="$tgt" \
    -v ka="$src" \
    -v kb="$dst" '
    NR > 1 &&
    $s == ks &&
    $t == kt &&
    $a == ka &&
    $b == kb {
      total++

      if ($9 == 1)
        route_changes++

      if (($11 + 0) > 0)
        loss_trials++
      else
        zero_loss++
    }

    END {
      if (total == 0)
        exit

      printf "  trials: %d | path changes: %d/%d (%.1f%%) | zero-loss: %d/%d (%.1f%%) | packet-loss trials: %d\n",
        total,
        route_changes,total,
        100*route_changes/total,
        zero_loss,total,
        100*zero_loss/total,
        loss_trials
    }
  ' "$CSV"

  echo

done <<< "$keys"

if [[ "$MODE" == "table" ]]; then
  echo "All values are seconds."
  echo
  echo "route_change_s = time from fault injection until the kernel selects"
  echo "                 a different route."
  echo "packet_loss_s   = observed ICMP gap caused by the fault."
  echo "loss_detection_s= time from injection until first packet loss."
  echo "heal_route_s    = time after healing until the original route returns."
  echo
  echo "For redundant link-down tests, route_change_s is the important"
  echo "failover metric even when packet_loss_s is 0."
fi
