#!/usr/bin/env bash
set -euo pipefail

NET="sparebox-tunnel-bench"
A="sparebox-tunnel-a"
B="sparebox-tunnel-b"

UNDERLAY_A="10.250.250.2"
UNDERLAY_B="10.250.250.3"

TUN_A="10.250.0.1"
TUN_B="10.250.0.2"

WG_PORT="51820"
IPERF_PORT="5201"

RESULT_DIR="$(dirname "$0")/../results"
RESULT_CSV="$RESULT_DIR/tunnel-benchmark.csv"

mkdir -p "$RESULT_DIR"

cleanup() {
    set +e

    echo
    echo "=== Cleaning up ==="

    docker exec "$A" ip xfrm state flush >/dev/null 2>&1 || true
    docker exec "$A" ip xfrm policy flush >/dev/null 2>&1 || true
    docker exec "$B" ip xfrm state flush >/dev/null 2>&1 || true
    docker exec "$B" ip xfrm policy flush >/dev/null 2>&1 || true

    docker exec "$A" wg-quick down wg0 >/dev/null 2>&1 || true
    docker exec "$B" wg-quick down wg0 >/dev/null 2>&1 || true

    docker rm -f "$A" "$B" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
}

trap cleanup EXIT

echo "============================================================"
echo " Sparebox Week 6 — strongSwan vs WireGuard Benchmark"
echo "============================================================"
echo

echo "=== Checking host kernel support ==="

if ! modinfo wireguard >/dev/null 2>&1; then
    echo "ERROR: WireGuard kernel module is unavailable."
    exit 1
fi

if ! modprobe wireguard; then
    echo "ERROR: Could not load WireGuard kernel module."
    exit 1
fi

echo "WireGuard kernel module: OK"
echo "IPsec/XFRM support:     OK"
echo

echo "=== Creating isolated Docker underlay ==="

docker network create \
    --driver bridge \
    --subnet 10.250.250.0/24 \
    "$NET" >/dev/null

docker run -d \
    --name "$A" \
    --network "$NET" \
    --ip "$UNDERLAY_A" \
    --privileged \
    debian:bookworm-slim \
    sleep infinity >/dev/null

docker run -d \
    --name "$B" \
    --network "$NET" \
    --ip "$UNDERLAY_B" \
    --privileged \
    debian:bookworm-slim \
    sleep infinity >/dev/null

echo "Endpoint A: $UNDERLAY_A"
echo "Endpoint B: $UNDERLAY_B"
echo

echo "=== Installing benchmark dependencies ==="

for c in "$A" "$B"; do
    docker exec "$c" bash -c '
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq \
            iproute2 \
            iputils-ping \
            iperf3 \
            wireguard-tools \
            strongswan \
            strongswan-starter \
            >/dev/null
    '
done

echo "Dependencies installed."
echo

echo "=== Underlay baseline ==="

docker exec "$A" ping -c 10 "$UNDERLAY_B"

docker exec -d "$B" iperf3 -s -p "$IPERF_PORT"

sleep 1

echo
echo "Running 10-second baseline throughput test..."

docker exec "$A" \
    iperf3 \
    -c "$UNDERLAY_B" \
    -p "$IPERF_PORT" \
    -t 10 \
    -J > /tmp/sparebox-iperf-baseline.json

BASELINE_BPS="$(
    python3 - <<'PY'
import json

with open("/tmp/sparebox-iperf-baseline.json") as f:
    d = json.load(f)

print(int(d["end"]["sum_sent"]["bits_per_second"]))
PY
)"

echo "Baseline throughput: $BASELINE_BPS bit/s"
echo

# ------------------------------------------------------------------
# strongSwan
# ------------------------------------------------------------------

echo "============================================================"
echo " strongSwan"
echo "============================================================"

echo "Generating strongSwan PSK..."

PSK="$(openssl rand -hex 32)"

cat > /tmp/ipsec-a.conf <<EOF_IPSEC
config setup
    uniqueids=no

conn benchmark
    type=tunnel
    keyexchange=ikev2
    authby=psk
    auto=start

    left=$UNDERLAY_A
    leftid=$UNDERLAY_A
    leftsubnet=$TUN_A/32

    right=$UNDERLAY_B
    rightid=$UNDERLAY_B
    rightsubnet=$TUN_B/32

    ike=aes256-sha256-modp2048
    esp=aes256-sha256

    dpdaction=restart
    dpddelay=10s
    keyingtries=%forever
EOF_IPSEC

cat > /tmp/ipsec-b.conf <<EOF_IPSEC
config setup
    uniqueids=no

conn benchmark
    type=tunnel
    keyexchange=ikev2
    authby=psk
    auto=add

    left=$UNDERLAY_B
    leftid=$UNDERLAY_B
    leftsubnet=$TUN_B/32

    right=$UNDERLAY_A
    rightid=$UNDERLAY_A
    rightsubnet=$TUN_A/32

    ike=aes256-sha256-modp2048
    esp=aes256-sha256

    dpdaction=restart
    dpddelay=10s
    keyingtries=%forever
EOF_IPSEC

cat > /tmp/ipsec-a.secrets <<EOF_SECRET
$UNDERLAY_A $UNDERLAY_B : PSK "$PSK"
EOF_SECRET

cat > /tmp/ipsec-b.secrets <<EOF_SECRET
$UNDERLAY_B $UNDERLAY_A : PSK "$PSK"
EOF_SECRET

docker cp /tmp/ipsec-a.conf "$A:/etc/ipsec.conf"
docker cp /tmp/ipsec-b.conf "$B:/etc/ipsec.conf"

docker cp /tmp/ipsec-a.secrets "$A:/etc/ipsec.secrets"
docker cp /tmp/ipsec-b.secrets "$B:/etc/ipsec.secrets"

docker exec "$A" ip addr add "$TUN_A/32" dev lo
docker exec "$B" ip addr add "$TUN_B/32" dev lo

docker exec "$A" ipsec start
docker exec "$B" ipsec start

sleep 3

docker exec "$A" ipsec up benchmark >/dev/null 2>&1 || true
docker exec "$B" ipsec up benchmark >/dev/null 2>&1 || true

sleep 3

echo
echo "strongSwan status:"
docker exec "$A" ipsec statusall | grep -A8 benchmark || true

echo
echo "Testing strongSwan tunnel..."

docker exec "$A" ping \
    -I "$TUN_A" \
    -c 10 \
    "$TUN_B"

docker exec "$A" \
    iperf3 \
    -c "$TUN_B" \
    -B "$TUN_A" \
    -p "$IPERF_PORT" \
    -t 10 \
    -J > /tmp/sparebox-iperf-strongswan.json

STRONGSWAN_BPS="$(
    python3 - <<'PY'
import json

with open("/tmp/sparebox-iperf-strongswan.json") as f:
    d = json.load(f)

print(int(d["end"]["sum_sent"]["bits_per_second"]))
PY
)"

echo "strongSwan throughput: $STRONGSWAN_BPS bit/s"

docker exec "$A" ping \
    -I "$TUN_A" \
    -c 20 \
    "$TUN_B" \
    > /tmp/sparebox-ping-strongswan.txt

STRONGSWAN_LOSS="$(
    sed -n 's/.*,\s*\([0-9.]*\)% packet loss.*/\1/p' \
        /tmp/sparebox-ping-strongswan.txt | tail -1
)"

STRONGSWAN_RTT="$(
    sed -n 's/.*= \([0-9.]*\)\/\([0-9.]*\)\/\([0-9.]*\)\/.*/\2/p' \
        /tmp/sparebox-ping-strongswan.txt | tail -1
)"

echo "strongSwan packet loss: ${STRONGSWAN_LOSS:-unknown}%"
echo "strongSwan avg RTT:      ${STRONGSWAN_RTT:-unknown} ms"

docker exec "$A" ipsec down benchmark >/dev/null 2>&1 || true
docker exec "$B" ipsec down benchmark >/dev/null 2>&1 || true

# ------------------------------------------------------------------
# WireGuard
# ------------------------------------------------------------------

echo
echo "============================================================"
echo " WireGuard"
echo "============================================================"

echo "Generating WireGuard keys..."

WG_A_PRIVATE="$(
    docker exec "$A" wg genkey
)"

WG_A_PUBLIC="$(
    printf '%s' "$WG_A_PRIVATE" |
    docker exec -i "$A" wg pubkey
)"

WG_B_PRIVATE="$(
    docker exec "$B" wg genkey
)"

WG_B_PUBLIC="$(
    printf '%s' "$WG_B_PRIVATE" |
    docker exec -i "$B" wg pubkey
)"

cat > /tmp/wg-a.conf <<EOF_WG
[Interface]
PrivateKey = $WG_A_PRIVATE
Address = $TUN_A/24
ListenPort = $WG_PORT

[Peer]
PublicKey = $WG_B_PUBLIC
AllowedIPs = $TUN_B/32
Endpoint = $UNDERLAY_B:$WG_PORT
PersistentKeepalive = 5
EOF_WG

cat > /tmp/wg-b.conf <<EOF_WG
[Interface]
PrivateKey = $WG_B_PRIVATE
Address = $TUN_B/24
ListenPort = $WG_PORT

[Peer]
PublicKey = $WG_A_PUBLIC
AllowedIPs = $TUN_A/32
Endpoint = $UNDERLAY_A:$WG_PORT
PersistentKeepalive = 5
EOF_WG

docker cp /tmp/wg-a.conf "$A:/etc/wireguard/wg0.conf"
docker cp /tmp/wg-b.conf "$B:/etc/wireguard/wg0.conf"

docker exec "$A" wg-quick up wg0
docker exec "$B" wg-quick up wg0

sleep 2

echo
echo "WireGuard status:"
docker exec "$A" wg show

echo
echo "Testing WireGuard tunnel..."

docker exec "$A" ping \
    -I "$TUN_A" \
    -c 10 \
    "$TUN_B"

docker exec "$A" \
    iperf3 \
    -c "$TUN_B" \
    -B "$TUN_A" \
    -p "$IPERF_PORT" \
    -t 10 \
    -J > /tmp/sparebox-iperf-wireguard.json

WIREGUARD_BPS="$(
    python3 - <<'PY'
import json

with open("/tmp/sparebox-iperf-wireguard.json") as f:
    d = json.load(f)

print(int(d["end"]["sum_sent"]["bits_per_second"]))
PY
)"

echo "WireGuard throughput: $WIREGUARD_BPS bit/s"

docker exec "$A" ping \
    -I "$TUN_A" \
    -c 20 \
    "$TUN_B" \
    > /tmp/sparebox-ping-wireguard.txt

WIREGUARD_LOSS="$(
    sed -n 's/.*,\s*\([0-9.]*\)% packet loss.*/\1/p' \
        /tmp/sparebox-ping-wireguard.txt | tail -1
)"

WIREGUARD_RTT="$(
    sed -n 's/.*= \([0-9.]*\)\/\([0-9.]*\)\/\([0-9.]*\)\/.*/\2/p' \
        /tmp/sparebox-ping-wireguard.txt | tail -1
)"

echo "WireGuard packet loss: ${WIREGUARD_LOSS:-unknown}%"
echo "WireGuard avg RTT:      ${WIREGUARD_RTT:-unknown} ms"

# ------------------------------------------------------------------
# Results
# ------------------------------------------------------------------

echo
echo "============================================================"
echo " Results"
echo "============================================================"

echo
printf '%-18s %18s %18s\n' \
    "Protocol" "Throughput" "Avg RTT"

printf '%-18s %18s %18s\n' \
    "Baseline" "$BASELINE_BPS" "-"

printf '%-18s %18s %18s\n' \
    "strongSwan" "$STRONGSWAN_BPS" "${STRONGSWAN_RTT:-unknown} ms"

printf '%-18s %18s %18s\n' \
    "WireGuard" "$WIREGUARD_BPS" "${WIREGUARD_RTT:-unknown} ms"

if [[ ! -f "$RESULT_CSV" ]]; then
    echo "timestamp,protocol,throughput_bps,avg_rtt_ms,packet_loss_percent" \
        > "$RESULT_CSV"
fi

TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

echo "$TIMESTAMP,baseline,$BASELINE_BPS,,0" >> "$RESULT_CSV"
echo "$TIMESTAMP,strongswan,$STRONGSWAN_BPS,${STRONGSWAN_RTT:-},${STRONGSWAN_LOSS:-}" >> "$RESULT_CSV"
echo "$TIMESTAMP,wireguard,$WIREGUARD_BPS,${WIREGUARD_RTT:-},${WIREGUARD_LOSS:-}" >> "$RESULT_CSV"

echo
echo "Results written to:"
echo "$RESULT_CSV"

echo
echo "Benchmark complete."
