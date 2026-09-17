# Sparebox Runbook

## Before any Containerlab session

1. Confirm the lab actually has its Containerlab-injected links:

```bash
docker exec clab-sparebox-fabric-r1-1 ip -br link show
```

You should see `lo`, `eth0`, `eth1`, `eth2`, `eth3` on the router. If the manually injected links are missing, do not debug BGP/LDP first; rebuild the lab.

2. For a clean rebuild:

```bash
sudo containerlab destroy -t containerlab/topology.clab.yml --cleanup
sudo containerlab deploy -t containerlab/topology.clab.yml
sudo ./containerlab/scripts/setup-cust-a.sh
```

3. Wait for routing/LDP state to settle before judging the fabric. In particular, the CUST-A MPLS pilot should not be tested immediately after deploy while LDP is still converging.

4. Use Containerlab lifecycle commands for Containerlab-managed routers. Do **not** use `docker restart` for FRR nodes because it can remove the `eth1`/`eth2`/`eth3` veth links that Containerlab injected into the namespace.

## Baseline fabric checks

Inspect all six FRR nodes with the hyphenated Containerlab name:

```bash
for r in r1-1 r1-2 r2-1 r2-2 r3-1 r3-2; do
    c="clab-sparebox-fabric-$r"
    echo
    echo "===== $r : OSPF ====="
    docker exec "$c" vtysh -c 'show ip ospf neighbor'
    echo
    echo "===== $r : BGP ====="
    docker exec "$c" vtysh -c 'show bgp summary'
done
```

A healthy Phase 1 baseline is:

- one intra-region OSPF neighbor in `Full` state on each router;
- three established IPv4-unicast BGP peers on each router;
- 18/18 IPv4-unicast BGP sessions established overall.

### Common audit mistake

The correct router name is:

```text
clab-sparebox-fabric-r1-1
```

not:

```text
clab-sparebox-fabric_r1-1
```

An underscore produces `No such container` and can be mistaken for a routing failure.

## LDP / MPLS checks

LDP is intentionally limited to the r1 pair for the delivered CUST-A pilot:

```bash
for r in r1-1 r1-2; do
    c="clab-sparebox-fabric-$r"
    echo "===== $r LDP ====="
    docker exec "$c" vtysh -c 'show mpls ldp neighbor'
    docker exec "$c" vtysh -c 'show mpls table'
done
```

After deploy, allow LDP to converge before interpreting an empty/partial MPLS table.

## CUST-A VPNv4/MPLS pilot

The post-deploy kernel setup is scripted in:

```text
containerlab/scripts/setup-cust-a.sh
```

Run it after every fresh Containerlab deployment:

```bash
sudo ./containerlab/scripts/setup-cust-a.sh
```

The script creates the Linux `CUST-A` VRF using table `100`, assigns the local customer `/32`, enables MPLS input on `eth1`, sets `net.mpls.platform_labels=100000`, and enables `net.ipv4.raw_l3mdev_accept=1`.

Verify the VRFs:

```bash
for r in r1-1 r1-2; do
    c="clab-sparebox-fabric-$r"
    docker exec "$c" vtysh -c 'show vrf'
    docker exec "$c" vtysh -c 'show ip route vrf CUST-A'
done
```

### Correct functional test

Use the CUST-A VRF explicitly:

```bash
docker exec clab-sparebox-fabric-r1-1 ping -I CUST-A -c 5 192.168.101.2
docker exec clab-sparebox-fabric-r1-2 ping -I CUST-A -c 5 192.168.101.1
```

A successful Phase 1 result is 5/5 replies in both directions.

A plain:

```bash
ping 192.168.101.2
```

from the default VRF is not a valid CUST-A functional test and can produce a misleading failure.

For forwarding-path inspection:

```bash
docker exec clab-sparebox-fabric-r1-1 ip route get 192.168.101.2 vrf CUST-A
docker exec clab-sparebox-fabric-r1-2 ip route get 192.168.101.1 vrf CUST-A
```

The Phase 1 pilot should resolve through an MPLS encapsulation/label toward the peer.

## IPsec checks

The strongSwan sidecars share the router network namespaces:

```bash
for r in r1-1 r1-2 r2-1 r2-2 r3-1 r3-2; do
    c="clab-sparebox-fabric-ipsec-$r"
    echo
    echo "===== IPSEC $r ====="
    docker exec "$c" ipsec statusall
done
```

The Phase 1 architecture uses transport-mode IKEv2/ESP on the three primary inter-region links. Do not describe this as full data-plane encryption of every packet in the fabric.

## NixOS rebuild discipline

Always build the intended system explicitly from the repository flake:

```bash
sudo nixos-rebuild switch --flake .#sparebox
```

Before a potentially disruptive change, prefer:

```bash
nix flake check --show-trace
sudo nixos-rebuild dry-build --flake .#sparebox
```

Do not use a bare `nixos-rebuild switch`. The host previously contained a stale `/etc/nixos` copy that did not represent the current Sparebox configuration.

## Observability checks

Current Phase 1 services are host-level NixOS services:

```bash
systemctl is-active telegraf
systemctl is-active grafana
systemctl is-active victoriametrics 2>/dev/null || \
systemctl is-active victoria-metrics 2>/dev/null || true
```

Health endpoints:

```bash
curl -fsS http://192.168.1.35:3000/api/health
curl -fsS http://127.0.0.1:8428/-/healthy
```

Grafana listens on `192.168.1.35:3000`. VictoriaMetrics listens on `127.0.0.1:8428`.

The shipped collector is deliberately BGP-only. It monitors the inter-region ring peers; it does not currently export OSPF, LDP/VPNv4, interface-counter or IPsec metrics.

If Grafana state needs to be rebuilt, use the NixOS activation path. Do not `rm -rf /var/lib/grafana` and then attempt to recover it with a bare `systemctl start`.

## Week 6 chaos benchmark

The formal benchmark evidence is:

```text
containerlab/chaos/results/week6-benchmark.csv
```

Formal coverage:

- 20 `link-down` trials on `link12`;
- 20 `link-down` trials on `link23`;
- 20 `link-down` trials on `link31`;
- 20 `link-blackhole` trials on `link12`.

Total: 80 formal rows plus the CSV header.

Run analysis with:

```bash
cd containerlab/chaos
./analyze.sh results/failover-trials.csv
```

The older `results/trials.csv` format is intentionally rejected by the current analyzer. Use the current failover-trial format when generating/analysing new experiments.

### Failure-test interpretation

- `link-down`: expected control-plane reroute; `route_change_s` is the key metric even when packet loss is zero.
- `link-blackhole`: expected to expose the difference between path failure and path withdrawal; loss can occur without a route change.
- `bgp-freeze`: a short fault window does not necessarily exceed the BGP hold timer, so absence of path change during a short smoke test is not equivalent to failed routing.
- `ipsec-down`/`ipsec-freeze`: the loopback probe does not traverse the selected transport-mode IPsec selectors, so these tests are not interpreted as full-fabric encryption/failover tests.
- `node-down`: keep as separate smoke coverage unless a dedicated probe and recovery definition are established.

Do not mix materially different failure semantics into one convergence percentile.

## Tunnel benchmark

Run:

```bash
./containerlab/chaos/benchmark/tunnel-benchmark.sh
```

The script creates an isolated Docker underlay, measures a 10-second iperf3 baseline, then measures strongSwan and WireGuard using the same endpoints. It cleans up its containers/network on exit.

Formal evidence is written to:

```text
containerlab/chaos/results/tunnel-benchmark.csv
```

The current measured run reported approximately:

- baseline: 27.481 Gbit/s;
- strongSwan: 506.792 Mbit/s, 0.182 ms average RTT, 0% loss;
- WireGuard: 1.667 Gbit/s, 0.707 ms average RTT, 0% loss.

Treat these as measurements from the lab environment, not universal protocol-performance claims.

## Shell validation

Before committing shell changes:

```bash
for f in containerlab/chaos/*.sh containerlab/chaos/benchmark/*.sh; do
    echo "checking: $f"
    bash -n "$f" || exit 1
done

echo "ALL SHELL SYNTAX CHECKS PASSED"
```

## Known non-fatal warnings

A Containerlab deploy on this NixOS host may report an inability to locate `/lib/modules/<kernel>/modules.dep`. Do not treat that message alone as a fabric failure; verify the live interfaces and protocol state.

Containerlab may also report `/etc/hosts: read-only file system` while operating on generated containers. Again, verify the actual deployment state rather than treating the warning by itself as proof of a broken lab.

## Phase 1 stopping point

Phase 1 is complete. The stable foundation is:

- 3 regions / 6 routers;
- OSPF + 18-session BGP fabric;
- primary and redundant inter-region paths;
- strongSwan transport-mode IPsec;
- single-VRF CUST-A VPNv4/MPLS pilot;
- BGP telemetry through Telegraf/VictoriaMetrics/Grafana;
- scripted chaos and formal failover evidence.

Full red/blue Inter-AS Option B and broader observability remain separate follow-on work and must not be mistaken for Phase 1 deliverables.
