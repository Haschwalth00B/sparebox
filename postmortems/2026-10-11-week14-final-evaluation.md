# Week 14 Final Evaluation — 2026-10-11

## Overall status

**Status:** Workload-level game days completed; final evaluation documented.
**Git branch:** `dev`
**Environment:** Single-node NixOS host running k3s
**Test workload:** `sparebox-web` in namespace `gitops-test`

This evaluation summarizes the recorded Chaos Mesh experiments, alerting
game days, postmortems, and final live-state checks. It does not claim
high availability or uninterrupted service during every experiment.

## Evidence reviewed

| Area | Result | Evidence and limits |
|---|---|---|
| Pod failure and recovery | Demonstrated | A pod was deleted; Kubernetes replaced it and the Deployment returned to 2/2 ready replicas. Ten post-recovery HTTP checks returned 200 in approximately 1–3 ms. |
| Alert lifecycle | Demonstrated | `SpareboxWebDown` progressed to firing during a controlled scale-to-zero test. Firing and resolved Discord notifications were manually observed. |
| CPU stress | Injection and recovery demonstrated | One CPU worker at 25% load for 30 seconds; Chaos Mesh reported recovery and the Deployment remained 2/2. HTTP impact during injection was not measured. |
| Packet loss | Recovery demonstrated | A 30-second experiment configured for 10% packet loss reported `AllRecovered=True`; the Deployment remained 2/2. HTTP impact during injection was not measured. |
| Network delay | Recovery reported | The temporary experiment was applied and recovery reported; detailed latency and HTTP measurements were not recorded. |
| Monitoring | Healthy at final check | VictoriaMetrics returned `probe_success=1`; vmalert returned no active alerts; Alertmanager returned no active alerts. |
| GitOps | Healthy at final check | Flux reported its `flux-system` Kustomization Ready and applied a revision from `main`. |
| Cleanup | Verified | No NetworkChaos, PodChaos, StressChaos, or Chaos Mesh Schedule resources remained at the final check. |

## Game-day postmortems

- `2026-10-11-web-pod-recovery.md`
- `2026-10-11-alerting-lifecycle.md`
- `2026-10-11-cpu-stress-recovery.md`

Supporting experiment results are recorded in `docs/chaos-mesh-validation.md`.

## What this evaluation supports

- Kubernetes replaced a deliberately deleted web pod.
- The web Deployment returned to two ready replicas after the recorded tests.
- The alerting path detected a controlled outage and delivered firing and resolved Discord notifications.
- Chaos Mesh reported recovery for the recorded CPU stress, packet-loss, and network-delay experiments.
- Monitoring, alerting, Flux reconciliation, and experiment cleanup were healthy at the final verification point.

## Limitations and unmeasured results

- Exact pod recovery time and alerting-test outage duration were not measured.
- MTTR and error-budget consumption were not calculated.
- HTTP success and latency were not sampled continuously during CPU stress, packet loss, or network delay.
- The pod-failure test's post-recovery HTTP checks do not prove uninterrupted availability during the failure.
- A single-node k3s cluster does not demonstrate control-plane or node high availability.
- These Kubernetes workload experiments do not substitute for FRR/MPLS routing reconvergence benchmarks in `containerlab/chaos/`.

## Follow-up work

- [ ] Capture experiment start, injection end, and recovery timestamps.
- [ ] Collect continuous HTTP success and latency measurements during fault injection.
- [x] Define availability and latency objectives and the error-budget calculation in `grafana/dashboards/slo.json`.
- [ ] Review and report Containerlab routing reconvergence results separately.
- [ ] Keep claims in the README and portfolio aligned with measured evidence.

## Final live-state check

At the final verification point:

- k3s node `sparebox`: `Ready`
- `sparebox-web`: 2/2 ready replicas
- VictoriaMetrics `probe_success{job="sparebox-web"}`: `1`
- vmalert active alerts: none
- Alertmanager active alerts: none
- Flux `flux-system` Kustomization: Ready
- Chaos Mesh experiment and schedule resources: none found
- Git working tree: clean before this evaluation file was created

These are point-in-time checks, not a guarantee of continuous availability.
