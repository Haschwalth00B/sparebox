# Phase 1 — Network Fabric: Final Progress & Verification

**Status:** Complete  
**Phase:** 1 of the Sparebox capstone  
**Scope:** Weeks 1–6  
**Finalized:** 2026-09-17  
**Primary branch:** `dev`

Phase 1 establishes the reproducible network-fabric foundation for Sparebox. It combines a three-region FRR/Containerlab fabric, OSPF and BGP routing, a redundant inter-region ring, strongSwan transport-mode IPsec, a verified single-VRF MPLS/VPNv4 pilot, host-level metrics and Grafana, and scripted failure-injection benchmarking.

This document is the final Phase 1 record. It covers the shipped architecture, the decisions and debugging that shaped it, the final verification evidence, the Week 6 benchmark results, known limitations, and the operational handoff into Phase 2.

---

## 1. Phase 1 outcome

Phase 1 is complete and reproducible from the repository state on `dev`.

The delivered Phase 1 surface is:

- 3 routing regions / ASes: `65001`, `65002`, `65003`.
- 6 FRR routers: two per region.
- OSPF for intra-region reachability.
- 18 IPv4 BGP sessions total: 6 iBGP sessions plus 12 inter-region eBGP sessions.
- A primary three-link inter-region ring plus three redundant inter-region links.
- 6 strongSwan sidecars sharing the FRR router network namespaces.
- Transport-mode IKEv2/ESP protection on the three primary inter-region links.
- A single-VRF `CUST-A` VPNv4/MPLS pilot between `r1-1` and `r1-2`.
- LDP intentionally limited to the r1 pair for the pilot; it is not enabled as a fabric-wide LDP domain.
- Host-level Telegraf → VictoriaMetrics telemetry for BGP peer state.
- A declaratively provisioned Grafana dashboard for the collected BGP metrics.
- Scripted chaos injection, probing, trial execution and analysis.
- 60 formal link-down trials, 20 formal link-blackhole trials, and additional smoke coverage for other fault classes.
- A reproducible strongSwan-vs-WireGuard tunnel benchmark.

The main Phase 1 acceptance evidence is stored in:

- `containerlab/chaos/results/week6-benchmark.csv`
- `containerlab/chaos/results/tunnel-benchmark.csv`
- `containerlab/chaos/inject.sh`
- `containerlab/chaos/probe.sh`
- `containerlab/chaos/trial.sh`
- `containerlab/chaos/analyze.sh`
- `containerlab/chaos/benchmark/tunnel-benchmark.sh`

---

## 2. Final topology and addressing

### 2.1 Regions and loopbacks

| Region | ASN | Routers | Loopbacks | Intra-region subnet |
|---|---:|---|---|---|
| r1 | 65001 | `r1-1`, `r1-2` | `10.0.1.1/32`, `10.0.1.2/32` | `10.1.0.0/24` |
| r2 | 65002 | `r2-1`, `r2-2` | `10.0.2.1/32`, `10.0.2.2/32` | `10.2.0.0/24` |
| r3 | 65003 | `r3-1`, `r3-2` | `10.0.3.1/32`, `10.0.3.2/32` | `10.3.0.0/24` |

Each region uses OSPF internally and iBGP between its two routers. Inter-region reachability is provided by eBGP across the ring and the redundant ring links.

### 2.2 Primary inter-region ring

| Link | Endpoints | Subnet |
|---|---|---|
| link12 | `r1-2:eth2` ↔ `r2-1:eth2` | `10.12.0.0/30` |
| link23 | `r2-2:eth2` ↔ `r3-1:eth2` | `10.23.0.0/30` |
| link31 | `r3-2:eth2` ↔ `r1-1:eth2` | `10.31.0.0/30` |

### 2.3 Redundant inter-region links

Containerlab also carries a second inter-region path for each region boundary:

- `r1-1:eth3` ↔ `r2-2:eth3`
- `r2-1:eth3` ↔ `r3-2:eth3`
- `r3-1:eth3` ↔ `r1-2:eth3`

These links are what make the Week 6 link-down tests meaningful: a primary inter-region path can fail while the fabric has an alternate route.

The topology is defined in `containerlab/topology.clab.yml`; generated Containerlab artifacts are intentionally not treated as source-of-truth configuration.

---

## 3. Week 2 — Fabric bring-up

The base fabric was brought up as a six-router Containerlab topology using `quay.io/frrouting/frr:10.7.0`.

The key delivered properties were:

- Three independent routing regions.
- Two FRR routers in every region.
- OSPF full adjacency inside all three regions.
- iBGP inside each region.
- A ring between the three regions.
- A second, redundant inter-region path per boundary.

The final audit confirmed the six intra-region OSPF adjacencies are all `Full`.

---

## 4. Week 3 — eBGP ring and IPsec

The routing fabric was extended with:

- eBGP between regions around the primary ring.
- Additional eBGP sessions on the redundant links.
- strongSwan sidecars attached with `network-mode: container:<router>`.
- IKEv2/PSK transport-mode IPsec on the three primary inter-region links.

### 4.1 IPsec verification

The three primary transit links were captured with tcpdump while testing the corresponding point-to-point path. The observed traffic was ESP rather than cleartext application/IP payloads on those protected links.

The architecture should still be described precisely: this is **transport-mode IPsec on selected transit/control-plane traffic**, not a claim that every packet in the fabric data plane is encrypted end-to-end.

### 4.2 Known IPsec observations

The strongSwan sidecars can negotiate NAT-T even though there is no separate NAT device in the lab. This is a side effect of sharing the router's complete network namespace and is not treated as a correctness failure.

`containerlab/strongswan/Dockerfile` now installs tcpdump into the image so packet-capture tooling survives container recreation.

---

## 5. Week 4 — BAH 2026 buffer

Week 4 was intentionally left as a schedule buffer around BAH 2026. Work moved directly into Week 5 rather than consuming the buffer as a dedicated implementation week.

---

## 6. Week 5 — MPLS/VPNv4 segmentation

### 6.1 Original design: full red/blue Inter-AS Option B

The original Week 5 target was a full Inter-AS MPLS VPN Option B implementation:

- `red` and `blue` VRFs in all three regions.
- Per-router route distinguishers.
- Shared route-targets per customer VRF.
- LDP scoped to regional boundaries.
- Dummy customer loopbacks for segmentation verification.

That first attempt surfaced two genuine configuration/design problems:

1. **Live-config RT export drift.** On 9 of 12 `vrf bgp` instances, the running configuration had the router's own RD in the export path instead of the shared per-VRF RT. The repository `frr.conf` files were not the source of that drift; the live `vtysh` state was.
2. **LDP crossed AS boundaries.** LDP and OSPF were initially placed on the inter-AS transit interfaces, allowing the AS boundaries to participate in a shared OSPF/LDP domain. That violates the intended Option B separation model.

Instead of layering more debugging on top of that state, the design was reverted to the verified routing/IPsec baseline and restarted with a narrower, testable pilot.

The full decision record remains in `docs/decisions/0001-option-b-defer.md`.

### 6.2 Delivered design: single-VRF `CUST-A` pilot

The delivered VPNv4 milestone is a single customer VRF on the r1 pair:

- `r1-1` CUST-A address: `192.168.101.1/32`
- `r1-2` CUST-A address: `192.168.101.2/32`
- VRF table: `100`
- `r1-1` RD: `65001:100`
- `r1-2` RD: `65001:200`
- Shared import/export RT: `65001:100`
- VPNv4 exchange: existing r1 iBGP session
- MPLS/LDP: only the r1 pair for the pilot

The asymmetric RDs are intentional; the common RT is what allows the two customer routes to be imported into the same VPN routing context.

### 6.3 Reproducibility fix: `setup-cust-a.sh`

A manually-created Linux VRF device does not survive Containerlab container recreation. The final repository therefore includes:

`containerlab/scripts/setup-cust-a.sh`

The script is idempotent and performs the post-deploy kernel setup required by the pilot:

- creates `CUST-A` as a Linux VRF with table `100` if absent;
- brings the VRF device up;
- installs the local `/32` if absent;
- enables MPLS input processing on `eth1`;
- sets `net.mpls.platform_labels=100000`;
- sets `net.ipv4.raw_l3mdev_accept=1`.

The script is expected to be run after a fresh Containerlab deployment.

### 6.4 Debugging lessons from the pilot

Several failures were initially misread as routing bugs but were actually lifecycle or verification issues:

- Using `docker restart` on Containerlab-managed FRR nodes removed the manually injected `eth1`/`eth2` veth links. The correct lifecycle operation is a Containerlab redeploy/reconfigure, not a Docker restart.
- Live VRF state created with `docker exec` is ephemeral unless recreated by a committed script.
- After a cold redeploy, LDP needs settling time before MPLS forwarding state should be judged.
- A stale set of containers was found without the expected `eth1`/`eth2` links; a full `containerlab destroy` followed by `deploy` restored the topology.
- The first working CUST-A forwarding checks were performed from the correct VRF context. A plain `ping 192.168.101.2` from the default VRF was not a valid CUST-A functional test and produced a misleading 100% loss result.

### 6.5 Final CUST-A verification

After a cold redeploy plus the committed setup script, both the control and data planes were verified independently:

```text
r1-1 CUST-A → 192.168.101.2: 5/5 replies, 0% packet loss
r1-2 CUST-A → 192.168.101.1: 5/5 replies, 0% packet loss
```

Kernel route resolution showed MPLS encapsulation through the CUST-A table, for example:

```text
192.168.101.2 encap mpls 144 via 10.1.0.2 dev eth1 table 100
192.168.101.1 encap mpls 144 via 10.1.0.1 dev eth1 table 100
```

LDP was operational on the r1 pair and the BGP VPN label was present. The underlay loopbacks also remained reachable in both directions.

The final conclusion is therefore:

> **The CUST-A VPNv4/MPLS pilot is functional and reproducible from the repository state.**

It is a single-VRF pilot, not the original full red/blue Inter-AS Option B design.

---

## 7. Week 5 — Metrics pipeline and Grafana

Observability is implemented as host-level NixOS services, separate from the Containerlab routing nodes.

### 7.1 Telegraf → VictoriaMetrics

Current implementation:

- VictoriaMetrics single-node.
- Retention: `30d`.
- Listen address: `127.0.0.1:8428`.
- Telegraf interval/flush interval: `15s`.
- Influx line protocol is sent to VictoriaMetrics.
- The current collector is intentionally **BGP-only**.

The collector at `containerlab/scripts/metrics/collect-bgp-summary.sh` reads `show bgp ipv4 unicast summary json` from the six FRR routers and emits peer-level metrics.

The current dashboard/collector therefore covers the 12 inter-region ring peers, while the routing fabric itself has 18 IPv4 BGP sessions including the six intra-region iBGP sessions.

OSPF state, LDP/VPNv4 state, interface counters and IPsec state are deliberately separate future collectors rather than being mixed into the BGP collector.

### 7.2 Grafana

Grafana is provisioned declaratively with:

- VictoriaMetrics as the Prometheus-compatible datasource.
- datasource UID `victoriametrics`.
- dashboard provider `sparebox`.
- dashboard file `grafana/dashboards/topology-health.json`.
- HTTP bind `192.168.1.35:3000`.

Final host verification on 2026-09-17 returned:

```json
{
  "database": "ok",
  "version": "13.0.7",
  "commit": "NA"
}
```

The socket check also confirmed Grafana listening on `192.168.1.35:3000`.

NixOS activation creates the Grafana state layout, including the generated secret key file. Manual deletion/recreation of `/var/lib/grafana` is therefore not a substitute for rebuilding the NixOS generation.

### 7.3 Observability limitation

Phase 1 should not be described as having full-fabric observability. The shipped pipeline is a deliberately narrow, working BGP peer-state collector with Grafana visualization. Expanding the metric surface is Phase 2/3 work.

---

## 8. Week 6 — Automated chaos and failover benchmarking

Week 6 turned the redundant fabric into a measurable failure-injection system.

### 8.1 Chaos tooling

The `containerlab/chaos/` directory now contains:

| File | Purpose |
|---|---|
| `inject.sh` | Applies and rolls back failure conditions. |
| `probe.sh` | Samples reachability and routing state. |
| `trial.sh` | Runs repeatable fault trials and records metrics. |
| `analyze.sh` | Calculates route-change, packet-loss, lag and heal statistics. |
| `fabric.env` | Shared fabric/test parameters. |
| `results/week6-benchmark.csv` | Formal Week 6 benchmark evidence. |
| `benchmark/tunnel-benchmark.sh` | Isolated strongSwan/WireGuard throughput test. |
| `results/tunnel-benchmark.csv` | Tunnel benchmark evidence. |

`analyze.sh` uses nearest-rank percentiles. Its main metrics are:

- `route_change_s`: time from fault injection until the kernel selects a different route;
- `packet_loss_s`: observed ICMP outage caused by the fault;
- `loss_detection_s`: time from injection until first observed packet loss;
- `heal_route_s`: time after healing until the original route returns.

For redundant link-down tests, `route_change_s` is the primary failover metric because a correct alternate route can prevent any packet loss at all.

### 8.2 Formal dataset

`containerlab/chaos/results/week6-benchmark.csv` contains **81 lines: one header plus 80 formal trial rows**.

The formal dataset consists of:

- 20 `link-down` trials for `link12`;
- 20 `link-down` trials for `link23`;
- 20 `link-down` trials for `link31`;
- 20 `link-blackhole` trials.

Other fault classes were exercised as smoke tests rather than mixed into the formal 80-trial statistical dataset because their failure-detection semantics are materially different.

### 8.3 Link-down results

| Target | Trials | Route-change p50 | Route-change p95 | Max | Path changes | Zero-loss trials |
|---|---:|---:|---:|---:|---:|---:|
| `link12` | 20 | 53 ms | 92 ms | 97.662 ms | 20/20 | 20/20 |
| `link23` | 20 | 51 ms | 88 ms | 88.817 ms | 20/20 | 20/20 |
| `link31` | 20 | 56 ms | 91 ms | 95.658 ms | 20/20 | 20/20 |
| **All link-down** | **60** | **54.6 ms** | **90.6 ms** | **97.662 ms** | **60/60** | **60/60** |

Interpretation: the primary-link failures were detected and rerouted in tens of milliseconds, and the probe observed no ICMP packet loss in the formal link-down dataset.

These numbers are measurements from this Containerlab/NixOS environment, not a general claim about OSPF/BGP convergence on arbitrary hardware or networks.

### 8.4 Link-blackhole result

The formal blackhole set contains 20 trials against `link12`.

Observed result:

- no route change during the blackhole condition;
- all 20 trials recorded packet loss;
- packet-loss interval p50: **5.107 s**;
- packet-loss interval p95: **5.128 s**.

This is an important distinction from link-down. Removing the link gives the routing protocols a concrete failure signal; blackholing traffic can leave the control plane believing the path is still available. The benchmark intentionally preserves that distinction rather than collapsing both cases into one “failover time” metric.

### 8.5 Smoke-only scenarios

The Week 6 injector also supports:

- `node-down`
- `bgp-freeze`
- `ipsec-down`
- `ipsec-freeze`

These were kept as smoke coverage rather than pooled into the 80-trial formal dataset.

Two important reasons are documented by the experiments:

- A BGP freeze that lasts only for the trial window does not exceed the configured BGP hold timer, so it is not expected to trigger immediate path withdrawal.
- The measured loopback probe does not traverse the transport-mode IPsec selectors used by the fabric, so taking those IPsec SAs down does not necessarily change the measured loopback route.

These are design/measurement semantics, not evidence that the injector is broken.

---

## 9. Week 6 — strongSwan vs WireGuard benchmark

The tunnel benchmark uses two isolated privileged Debian containers on a dedicated Docker bridge so its results are not mixed with the Containerlab routing fabric.

### 9.1 Test method

- Underlay network: `10.250.250.0/24`.
- Endpoint A: `10.250.250.2`.
- Endpoint B: `10.250.250.3`.
- Tunnel endpoints: `10.250.0.1` and `10.250.0.2`.
- Throughput tool: `iperf3` for 10 seconds.
- Connectivity/latency checks: ping.
- strongSwan: IKEv2 PSK, AES-256/SHA-256 with MODP-2048; ESP AES-256/SHA-256.
- WireGuard: kernel module plus `wg-quick`.
- The script cleans up its containers and network when complete.

### 9.2 Measured results

| Mode | Throughput | Avg RTT | Packet loss |
|---|---:|---:|---:|
| Baseline | 27.481 Gbit/s | — | 0% |
| strongSwan | 506.792 Mbit/s | 0.182 ms | 0% |
| WireGuard | 1.667 Gbit/s | 0.707 ms | 0% |

The measured WireGuard throughput was approximately **3.29×** the measured strongSwan throughput in this specific benchmark environment.

Relative to the same baseline, the measured throughputs were approximately:

- strongSwan: **1.84% of baseline**;
- WireGuard: **6.07% of baseline**.

These figures are environment-specific observations from the benchmark script; they should not be presented as universal protocol-performance guarantees.

The successful run also verified an established strongSwan IKEv2/ESP SA and a recent WireGuard handshake with non-zero transfer counters.

---

## 10. Final control-plane verification

The final audit of the live Containerlab deployment confirmed:

### OSPF

- 6/6 routers have their intra-region OSPF neighbor in `Full` state.

### BGP

- 3 established IPv4-unicast peers per router.
- 18/18 IPv4-unicast BGP sessions established.
- 12 of those are inter-region eBGP ring peers monitored by the current BGP metrics collector.

### MPLS/LDP

- LDP is operational only on the intended r1 pair.
- The CUST-A VPN route resolves through MPLS label 144 in the Linux forwarding table.
- The full fabric is not represented as one shared LDP domain.

### Interfaces

- `eth1`, `eth2` and `eth3` are present and up on the six FRR routers after a clean Containerlab deployment.

### IPsec

- strongSwan IKEv2/ESP SAs are established on the six sidecars.
- The fabric uses transport mode for the selected protected traffic.

### CUST-A

- `CUST-A` VRF exists with table `100` on `r1-1` and `r1-2`.
- Local and imported `/32` routes are installed.
- Correct CUST-A VRF pings succeed in both directions with 0% packet loss.

### Observability

- Telegraf active.
- Grafana active and reachable on `192.168.1.35:3000`.
- VictoriaMetrics healthy on `127.0.0.1:8428`.

### NixOS reproducibility

The final audit also passed:

```bash
nix flake check --no-build
sudo nixos-rebuild dry-build --flake .#sparebox
```

The committed chaos shell scripts pass `bash -n` syntax checks.

---

## 11. NixOS and Containerlab operational notes

These are important because several apparently serious failures during Phase 1 were lifecycle issues rather than routing failures.

### 11.1 Use Containerlab for Containerlab lifecycle

Do not use `docker restart` on the FRR routers when they are managed by Containerlab. Containerlab creates `eth1`/`eth2`/`eth3` links inside the router namespaces; Docker's normal container restart lifecycle does not recreate those manually injected veths.

For a clean rebuild:

```bash
sudo containerlab destroy -t containerlab/topology.clab.yml --cleanup
sudo containerlab deploy -t containerlab/topology.clab.yml
sudo ./containerlab/scripts/setup-cust-a.sh
```

Allow LDP/BGP/other control-plane state to settle before treating a transient negative result as a fabric regression.

### 11.2 Always use the repository flake

Use:

```bash
sudo nixos-rebuild switch --flake .#sparebox
```

not a bare `nixos-rebuild switch`.

The host previously had a separate stale `/etc/nixos` copy. Using the bare command built the wrong configuration generation without producing an obvious error because that older flake simply did not declare the Phase 1 services.

### 11.3 NixOS module-loader warning

Containerlab may report a warning around `/lib/modules/<kernel>/modules.dep` on this NixOS host. The host's kernel-module layout does not mirror a conventional `/lib/modules` installation. This warning is not by itself evidence that the routing fabric is unhealthy; verify the actual interfaces, services and protocol state before treating it as a fault.

### 11.4 Other non-fatal lifecycle warnings

Containerlab may also print `/etc/hosts: read-only file system` while operating on generated containers. The warning should be interpreted alongside the actual `containerlab inspect` state rather than treated as proof of a failed deployment.

---

## 12. Repository structure relevant to Phase 1

```text
.
├── flake.nix
├── containerlab/
│   ├── topology.clab.yml
│   ├── frr/
│   │   ├── r1-1/
│   │   ├── r1-2/
│   │   ├── r2-1/
│   │   ├── r2-2/
│   │   ├── r3-1/
│   │   └── r3-2/
│   ├── strongswan/
│   │   └── r1-1 ... r3-2/
│   ├── scripts/
│   │   ├── setup-cust-a.sh
│   │   └── metrics/collect-bgp-summary.sh
│   └── chaos/
│       ├── fabric.env
│       ├── inject.sh
│       ├── probe.sh
│       ├── trial.sh
│       ├── analyze.sh
│       ├── benchmark/tunnel-benchmark.sh
│       └── results/
├── modules/
│   └── observability.nix
├── grafana/
│   └── dashboards/topology-health.json
└── docs/
    ├── phase1-progress.md
    ├── runbook.md
    └── decisions/0001-option-b-defer.md
```

The repository is the source of truth. Live container state, generated Containerlab artifacts, and hand-entered `docker exec` configuration are not substitutes for committed configuration.

---

## 13. Deferred scope and explicit non-goals

### Deferred: full red/blue Inter-AS Option B

The original full `red`/`blue` design remains a separate, optional track. It was intentionally not allowed to block Phase 1 completion.

It can be revisited after Week 6 using the decision and lessons already captured, but Phase 1's shipped VPNv4 milestone is the verified single-VRF `CUST-A` pilot.

### Not claimed by Phase 1

Phase 1 should **not** be described as having:

- a full red/blue Inter-AS Option B implementation;
- a fabric-wide shared LDP domain;
- full-fabric encryption of every data-plane packet;
- full OSPF/LDP/interface/IPsec telemetry in VictoriaMetrics;
- production-grade multi-node VictoriaMetrics/Grafana HA;
- Kubernetes/k3s/Flux/Chaos Mesh integration.

Those are later-phase capabilities or deliberately deferred work.

---

## 14. Phase 2 handoff

The Phase 1 foundation is now stable enough that Phase 2 can build on it rather than continuing to rework the base fabric.

The main handoff principles are:

1. **Keep the repository declarative.** New host/service state belongs in the Nix flake; new lab state belongs in committed Containerlab/FRR/strongSwan configuration; ephemeral kernel setup must have a script like `setup-cust-a.sh`.
2. **Keep routing-domain boundaries explicit.** OSPF is intra-region. The delivered LDP scope is intentionally narrow. Do not reintroduce cross-AS OSPF/LDP accidentally while extending VPNs.
3. **Preserve measurement semantics.** Link-down, blackhole, BGP-timer and IPsec-selector tests measure different failure modes and should not be merged into a single convergence number.
4. **Treat cold-redeploy verification as part of correctness.** A configuration that only works in one live container session is not considered reproducible.
5. **Expand observability independently.** Add OSPF/LDP/VPNv4/interface/IPsec collectors as separate inputs so a parser error in one signal does not remove the working BGP pipeline.

---

## 15. Final Phase 1 evidence summary

| Area | Final status | Primary evidence |
|---|---|---|
| 3-region routing fabric | Complete | `containerlab/topology.clab.yml`, live protocol checks |
| OSPF | Complete | 6/6 intra-region adjacencies `Full` |
| BGP | Complete | 18/18 IPv4-unicast sessions established |
| Primary + redundant ring | Complete | 9 inter/intra topology links present |
| strongSwan/IPsec | Complete | IKEv2/ESP SAs established; transit capture evidence |
| CUST-A VPNv4/MPLS pilot | Complete | bilateral VRF ping + MPLS route resolution |
| BGP observability | Complete | Telegraf → VictoriaMetrics → Grafana |
| Link-down benchmark | Complete | 60 formal trials; p50 54.6 ms, p95 90.6 ms |
| Link-blackhole benchmark | Complete | 20 formal trials; p50 loss interval 5.107 s |
| Tunnel benchmark | Complete | baseline/strongSwan/WireGuard CSV |
| Cold-redeploy reproducibility | Complete | committed setup script + fresh deploy validation |
| Phase 1 documentation | Complete | this document + runbook + ADR |

**Phase 1 is complete.** The next work should extend the platform from this verified routing/observability/chaos foundation rather than treating the Phase 1 fabric as unfinished.
