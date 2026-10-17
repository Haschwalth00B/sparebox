# Architecture

This document describes the delivered system, not the plan. Anything not yet built
is marked as such. Detailed build history lives in `docs/phase1-progress.md`;
operational procedure lives in `docs/runbook.md`.

---

## 1. Host

| | |
|---|---|
| Hardware | HP ProDesk 400 G2 Mini, i5 6th-gen, 12 GB RAM, 512 GB NVMe |
| OS | NixOS 26.05, bare metal |
| Hostname | `sparebox` |
| LAN address | `192.168.1.35/24`, gateway `192.168.1.1`, interface `enp3s0` |
| Host firewall | disabled (`networking.firewall.enable = false`) |
| Config | single `flake.nix` + `modules/*.nix`, no Ansible, no Terraform |

There is no second box, no IPMI and no console. Two consequences shape the design:

1. `modules/safety-assertions.nix` turns "this configuration would make the host
   unreachable" into a build-time failure rather than a runtime one. It asserts SSH
   is enabled, the primary user exists, and that port 22 is reachable if the
   firewall is ever turned on.
2. The disaster-recovery story is NixOS generation rollback, not failover.

---

## 2. Network fabric (Phase 1 — shipped)

Six FRR routers (`quay.io/frrouting/frr:10.7.0`) across three simulated regions,
orchestrated by Containerlab from `containerlab/topology.clab.yml`. FRR and
strongSwan run as Containerlab-launched Docker containers, not host services — the
host only needs to run Docker well.

### 2.1 Regions and addressing

| Region | ASN | Routers | Loopbacks | Intra-region subnet |
|---|---:|---|---|---|
| r1 | 65001 | `r1-1`, `r1-2` | `10.0.1.1/32`, `10.0.1.2/32` | `10.1.0.0/24` |
| r2 | 65002 | `r2-1`, `r2-2` | `10.0.2.1/32`, `10.0.2.2/32` | `10.2.0.0/24` |
| r3 | 65003 | `r3-1`, `r3-2` | `10.0.3.1/32`, `10.0.3.2/32` | `10.3.0.0/24` |

### 2.2 Inter-region links

Primary ring:

| Link | Endpoints | Subnet |
|---|---|---|
| `link12` | `r1-2:eth2` ↔ `r2-1:eth2` | `10.12.0.0/30` |
| `link23` | `r2-2:eth2` ↔ `r3-1:eth2` | `10.23.0.0/30` |
| `link31` | `r3-2:eth2` ↔ `r1-1:eth2` | `10.31.0.0/30` |

Redundant path per boundary, on `eth3`: `r1-1`↔`r2-2`, `r2-1`↔`r3-2`, `r3-1`↔`r1-2`.
These are what make the link-down benchmark meaningful — a primary path can fail
while an alternate exists.

### 2.3 Protocol domain boundaries

These boundaries are deliberate. Violating them accidentally was the root cause of
the Week 5 Option B failure, so they are stated rather than implied.

| Protocol | Scope | Notes |
|---|---|---|
| OSPF | Intra-region only | Never redistributed into BGP. Cross-region reachability is loopback-to-loopback only. |
| iBGP | Within each region | 6 sessions |
| eBGP | Across the ring and redundant links | 12 sessions |
| IPsec | 3 primary transit links only | Transport-mode IKEv2/PSK, strongSwan sidecars sharing the router netns |
| LDP | `r1-1`/`r1-2` only | Scoped to the CUST-A pilot, not a fabric-wide domain |
| MP-BGP VPNv4 | `CUST-A` VRF on the r1 pair | RD `65001:100`/`65001:200`, shared RT `65001:100`, customer prefix `192.168.101.0/24` |

A common misread: a plain `ping` between regions fails by design, because it sources
from the egress interface's OSPF-local `/24`. Cross-region tests must be
loopback-sourced (`ping -I <loopback>`), and CUST-A tests must use `ping -I CUST-A`.

### 2.4 Non-declarative state

Kernel state that Containerlab and zebra do not create — the `CUST-A` VRF device,
MPLS sysctls, `raw_l3mdev_accept` — does not survive a redeploy. It is scripted in
`containerlab/scripts/setup-cust-a.sh` and must be run after every fresh deploy.
This is the rule the project applies generally: configuration that only works in one
live container session is not considered reproducible.

---

## 3. Observability (Phase 1 — shipped, host-level)

```
FRR routers ──docker exec vtysh──▶ Telegraf ──influx line protocol──▶ VictoriaMetrics ──▶ Grafana
  (containers)                   (host service, 15s)                  127.0.0.1:8428      192.168.1.35:3000
```

- `containerlab/scripts/metrics/collect-bgp-summary.sh` execs `vtysh` in each
  router and emits BGP peer state as `frr_bgp_peer_up`. Twelve real peer series.
- VictoriaMetrics: single node, 30-day retention, loopback-bound.
- Grafana: datasource and dashboards provisioned declaratively from
  `modules/observability.nix` and `grafana/dashboards/`.

Deliberate limitation: the collector is BGP-only. OSPF, LDP/VPNv4, interface
counters and IPsec are not exported. Additional signals are to be added as separate
Telegraf inputs so a parser error in one cannot take down the working BGP pipeline.

---

## 4. Chaos and benchmarking (Phase 1 — shipped)

`containerlab/chaos/` holds `inject.sh`, `probe.sh`, `trial.sh` and `analyze.sh`,
plus `benchmark/tunnel-benchmark.sh`. Formal evidence is committed as CSV under
`results/`.

Failure classes are measured separately and never pooled, because they exercise
different mechanisms:

| Class | What it exercises | Key metric |
|---|---|---|
| `link-down` | Link-state event → control-plane reroute | `route_change_s` (loss is 0 by design) |
| `link-blackhole` | Silent discard with no link-state signal | `packet_loss_s` (no route change occurs) |
| `bgp-freeze` | Hold-timer behaviour | Only meaningful over a window longer than the hold timer |
| `ipsec-down`/`freeze` | Smoke only — the loopback probe does not traverse the transport-mode selectors |

---

## 5. Kubernetes platform and observability (Phase 2 — delivered)

### 5.1 Address plan

Verified non-overlapping against the existing host and lab:

| Range | Use |
|---|---|
| `10.42.0.0/16` | k3s pod CIDR |
| `10.43.0.0/16` | k3s service CIDR |
| `192.168.1.0/24` | host LAN |
| `172.17.0.0/16` | Docker default bridge |
| `172.20.20.0/24` | Containerlab management network |
| `10.0.x.x/32`, `10.1–10.3.0.0/24`, `10.12/23/31.0.0/30`, `192.168.101.0/24` | network fabric |

The k3s CIDRs are pinned in `modules/k3s-platform.nix`.

### 5.2 Cluster reconciliation

Flux reconciles `k8s/clusters/sparebox` from Git. The k3s auto-deploy manifest mechanism is disabled for resources managed by Flux, avoiding competing reconciliation paths.

The Flux SOPS decryption configuration is committed in the cluster configuration. Secret decryption and delivery depend on the corresponding age key and Kubernetes secret being present on the target system.

### 5.3 Node resource protection

The k3s configuration sets `systemReserved`, `kubeReserved`, and a memory eviction threshold. The kubelet permits host swap with `fail-swap-on: false`; Kubernetes workloads still follow the configured kubelet swap behaviour. Interpret stress-test results in the context of this single-node host and its other services.

### 5.4 Delivered platform

| Component | Implemented role |
|---|---|
| k3s | Single-node Kubernetes control plane and workload scheduling |
| Flux | GitOps reconciliation of cluster manifests |
| `sparebox-web` | Two-replica test Deployment in `gitops-test` |
| vmagent | Scrapes Kubernetes and HTTP-probe metrics and writes to host VictoriaMetrics |
| Blackbox Exporter | HTTP availability and latency probes |
| VictoriaMetrics | Host-side metrics storage, with configured retention |
| Grafana | Host-side dashboards for topology, Kubernetes/GitOps, and SLOs |
| vmalert | Evaluates the `SpareboxWebDown` alert rule |
| Alertmanager | Routes firing and resolved alerts to the configured Discord webhook |
| Chaos Mesh | Controlled workload fault-injection experiments |

VictoriaMetrics and Grafana remain host services; the cluster scraper sends metrics to the host-side metrics endpoint. This avoids maintaining a second in-cluster metrics database and Grafana instance.

### 5.5 Validation and recovery evidence

The GitHub Actions workflow runs `nix flake check`, evaluates the NixOS system derivation, renders the Kubernetes manifests, and validates them with kubeconform and kube-linter. Derivation evaluation is not a complete NixOS system build, and branch protection is not configured.

Recorded game days cover pod deletion and replacement, a controlled scale-to-zero alert lifecycle, CPU stress, packet loss, and network delay. The associated evidence and limitations are documented in `docs/chaos-mesh-validation.md` and `postmortems/`.

The tests demonstrated workload recovery and the firing/resolution notification path. They do not establish high availability or uninterrupted service during every experiment. Exact MTTR and outage duration were not measured, and continuous HTTP impact measurements were not collected for every fault injection.

Chaos Mesh experiment and schedule resources were removed after testing. Scheduled experiments are not left running.

### 5.6 Known limitations and deferred work

- **Single-node platform:** there is no Kubernetes HA control plane or redundant host.
- **Phase 3 integration:** a scripted link-failure experiment demonstrated fresh BGP-down telemetry before a Kubernetes pod-kill test, followed by workload and fabric recovery. This bounded test does not prove high availability or uninterrupted service.
- **Unified telemetry:** an initial Phase 3 recovery dashboard combines live BGP peer health, Kubernetes replica counts, and HTTP probe health. Broader fabric telemetry and richer historical recovery analysis remain future work.
- **Fabric telemetry:** the existing collector does not provide comprehensive OSPF, LDP, interface-counter, or IPsec metrics.
- **Fabric protocol scope:** the full red/blue Inter-AS Option B design and fabric-wide LDP remain deferred as described in ADR 0001.
- **SLO evidence:** SLO definitions and alerting exist, but exact MTTR, per-experiment error-budget consumption, and continuous impact during all experiments remain unmeasured.

Phase 2 is considered delivered with these limitations explicitly recorded. A Phase 3 integration run has demonstrated the fabric-failure-to-Kubernetes-recovery sequence. The runbook records the procedure, outcome, evidence location, and measurement caveats. The initial unified Phase 3 recovery dashboard is available; broader fabric telemetry and richer historical recovery analysis remain follow-on work.
