#!/usr/bin/env bash
#
# analyze.sh — p50/p95 (and friends) per scenario from trials.csv.
#
# Percentiles are nearest-rank on the sorted sample, which is the right
# choice for 20-ish samples: no interpolation between values that were
# never measured, and p95 of 20 trials is honestly reported as "the 19th
# worst of 20" rather than dressed up as a smooth estimate.
#
# Two columns matter:
#   fault_outage  how long traffic was black-holed after the fault
#   fault_lag     how long traffic kept flowing after the fault before the
#                 first loss — i.e. detection time
#
# Splitting them is the whole point. link-down and link-blackhole can
# reconverge in a comparable time once detected; what separates them by two
# orders of magnitude is detection, and a single "outage" number hides that.
#
# Usage: ./analyze.sh [results/trials.csv] [--csv]
#   --csv   emit machine-readable rows instead of the table

set -euo pipefail

CSV="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/results/trials.csv}"
[[ "${1:-}" == --csv ]] && { CSV="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/results/trials.csv"; }
MODE=table
for a in "$@"; do [[ "$a" == "--csv" ]] && MODE=csv; done

[[ -f "$CSV" ]] || { echo "analyze.sh: no such file: $CSV" >&2; exit 2; }

# column indices in trials.csv
C_SCEN=2; C_TGT=3; C_SRC=4; C_DST=5; C_FOUT=7; C_FLAG=8; C_HOUT=9

pct() { # stdin: sorted numbers, one per line. $1: percentile 0-100
  awk -v p="$1" '
    { v[NR] = $1 }
    END {
      if (NR == 0) { print "-"; exit }
      i = int((p / 100) * NR + 0.9999)
      if (i < 1)  i = 1
      if (i > NR) i = NR
      printf "%.3f", v[i]
    }'
}

stats_for() { # $1 file of values -> "n min p50 p90 p95 max"
  local f="$1" n
  n=$(wc -l < "$f")
  if [[ "$n" -eq 0 ]]; then echo "0 - - - - -"; return; fi
  printf '%s %s %s %s %s %s' \
    "$n" \
    "$(head -n1 "$f")" \
    "$(pct 50 < "$f")" \
    "$(pct 90 < "$f")" \
    "$(pct 95 < "$f")" \
    "$(tail -n1 "$f")"
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

keys=$(awk -F, -v s="$C_SCEN" -v t="$C_TGT" -v a="$C_SRC" -v b="$C_DST" \
       'NR > 1 && NF > 5 { print $s "|" $t "|" $a "|" $b }' "$CSV" | sort -u)

[[ -n "$keys" ]] || { echo "no trial rows in $CSV"; exit 0; }

if [[ "$MODE" == table ]]; then
  printf '%-16s %-8s %-11s %-7s %3s  %9s %9s %9s %9s %9s\n' \
    SCENARIO TARGET PROBE METRIC n min p50 p90 p95 max
  printf '%s\n' "$(printf '%.0s─' {1..104})"
fi

while IFS='|' read -r scen tgt src dst; do
  for metric in fault_outage fault_lag heal_outage; do
    case "$metric" in
      fault_outage) col=$C_FOUT ;;
      fault_lag)    col=$C_FLAG ;;
      heal_outage)  col=$C_HOUT ;;
    esac
    awk -F, -v s="$C_SCEN" -v t="$C_TGT" -v a="$C_SRC" -v b="$C_DST" -v c="$col" \
        -v ks="$scen" -v kt="$tgt" -v ka="$src" -v kb="$dst" \
        'NR > 1 && $s == ks && $t == kt && $a == ka && $b == kb { print $c + 0 }' \
        "$CSV" | sort -g > "$tmp/v"

    read -r n mn p50 p90 p95 mx <<<"$(stats_for "$tmp/v")"

    if [[ "$MODE" == table ]]; then
      printf '%-16s %-8s %-11s %-7s %3s  %9s %9s %9s %9s %9s\n' \
        "$scen" "$tgt" "$src->$dst" "${metric#fault_}" "$n" "$mn" "$p50" "$p90" "$p95" "$mx"
    else
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$scen" "$tgt" "$src" "$dst" "$metric" "$n" "$mn" "$p50" "$p90" "$p95" "$mx"
    fi
  done
  [[ "$MODE" == table ]] && echo
done <<< "$keys"

if [[ "$MODE" == table ]]; then
  echo "all values in seconds. 'outage' = blackhole duration, 'lag' = time from"
  echo "injection to first loss (detection). n < 20 means the run is incomplete."
  echo
  echo "path changes (TTL differing across the outage proves reconvergence onto"
  echo "a different path rather than the same path recovering):"
  awk -F, 'NR > 1 && $11 != "-" && $12 != "-" && $11 != $12 {
             printf "  %-16s %-8s trial %-3s ttl %s -> %s\n", $2, $3, $6, $11, $12 }' "$CSV" \
    | sort -u | head -20
fi

