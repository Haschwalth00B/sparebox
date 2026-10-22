#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DATA="${SCRIPT_DIR}/../recovery-data-links.tsv"

[[ -s "$DATA" ]] || {
  echo "ERROR: missing recovery manifest: $DATA" >&2
  exit 1
}

mapfile -t LINKS < "$DATA"
((${#LINKS[@]} == 9)) || {
  echo "ERROR: expected exactly 9 data links; found ${#LINKS[@]}" >&2
  exit 1
}

routers=(r1-1 r1-2 r2-1 r2-2 r3-1 r3-2)
valid_node() {
  local candidate=$1 node
  for node in "${routers[@]}"; do
    [[ "$candidate" == "$node" ]] && return 0
  done
  return 1
}

# Preflight all links before making changes.
i=0
for link in "${LINKS[@]}"; do
  read -r na ia ma nz iz mz extra <<< "$link"
  [[ -n "$na" && -n "$ia" && -n "$ma" &&
     -n "$nz" && -n "$iz" && -n "$mz" && -z "${extra:-}" ]] || {
    echo "ERROR: malformed manifest row $((i + 1))" >&2
    exit 1
  }

  valid_node "$na" && valid_node "$nz" || {
    echo "ERROR: invalid router in manifest row $((i + 1))" >&2
    exit 1
  }
  [[ "$ia" =~ ^eth[123]$ && "$iz" =~ ^eth[123]$ ]] || {
    echo "ERROR: invalid interface in manifest row $((i + 1))" >&2
    exit 1
  }
  [[ "$ma" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ &&
     "$mz" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || {
    echo "ERROR: invalid MAC address in manifest row $((i + 1))" >&2
    exit 1
  }

  ca="clab-sparebox-fabric-$na"
  cz="clab-sparebox-fabric-$nz"
  docker inspect -f '{{.State.Running}}' "$ca" 2>/dev/null |
    grep -qx true || {
      echo "ERROR: router container is not running: $ca" >&2
      exit 1
    }
  docker inspect -f '{{.State.Running}}' "$cz" 2>/dev/null |
    grep -qx true || {
      echo "ERROR: router container is not running: $cz" >&2
      exit 1
    }

  pa=$(docker inspect -f '{{.State.Pid}}' "$ca")
  pz=$(docker inspect -f '{{.State.Pid}}' "$cz")
  has_a=0; has_z=0
  nsenter -t "$pa" -n ip link show dev "$ia" >/dev/null 2>&1 && has_a=1
  nsenter -t "$pz" -n ip link show dev "$iz" >/dev/null 2>&1 && has_z=1

  (( has_a == has_z )) || {
    echo "ERROR: only one endpoint exists: $na/$ia <-> $nz/$iz" >&2
    exit 1
  }

  if (( has_a == 0 )); then
    for v in "sba$i" "sbz$i"; do
      ip link show "$v" >/dev/null 2>&1 && {
        echo "ERROR: temporary host interface already exists: $v" >&2
        exit 1
      }
    done
  fi
  i=$((i + 1))
done

# Restore only pairs where both endpoints are absent.
i=0
for link in "${LINKS[@]}"; do
  read -r na ia ma nz iz mz <<< "$link"
  ca="clab-sparebox-fabric-$na"
  cz="clab-sparebox-fabric-$nz"
  pa=$(docker inspect -f '{{.State.Pid}}' "$ca")
  pz=$(docker inspect -f '{{.State.Pid}}' "$cz")

  if nsenter -t "$pa" -n ip link show dev "$ia" >/dev/null 2>&1; then
    echo "OK: $na/$ia <-> $nz/$iz already exists"
    i=$((i + 1))
    continue
  fi

  va="sba$i"; vz="sbz$i"
  ip link add "$va" type veth peer name "$vz"
  ip link set dev "$va" address "$ma"
  ip link set dev "$vz" address "$mz"
  ip link set dev "$va" netns "$pa"
  ip link set dev "$vz" netns "$pz"
  nsenter -t "$pa" -n ip link set dev "$va" name "$ia"
  nsenter -t "$pz" -n ip link set dev "$vz" name "$iz"
  nsenter -t "$pa" -n ip link set dev "$ia" up
  nsenter -t "$pz" -n ip link set dev "$iz" up

  echo "RESTORED: $na/$ia <-> $nz/$iz"
  i=$((i + 1))
done
