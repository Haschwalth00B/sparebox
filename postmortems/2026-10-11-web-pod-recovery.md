# Postmortem: Web Pod Failure and Recovery — 2026-10-11

**Status:** Resolved
**Experiment:** Controlled `sparebox-web` pod deletion
**Blast radius:** Namespace `gitops-test`; one web pod
**Duration:** Exact disruption duration not measured
**MTTR:** Not measured; exact failure and recovery timestamps were not collected

## Summary

A controlled pod failure was used to validate the recovery of the
`sparebox-web` Deployment. The targeted pod was deleted, Kubernetes
created a replacement, and the Deployment returned to two ready
replicas. After recovery, 10 consecutive HTTP checks returned status
`200`, with observed response times of approximately 1–3 ms.

The experiment validated pod replacement and post-recovery HTTP
availability. It did not establish uninterrupted availability during
the disruption.

## Timeline

| Event | Evidence |
|---|---|
| Before experiment | `sparebox-web` Deployment was healthy |
| Experiment initiated | One web pod was deleted |
| Recovery | Kubernetes created a replacement pod |
| Deployment stabilized | Two replicas became ready (`2/2`) |
| Post-recovery verification | Service endpoints were present |
| HTTP verification | 10 checks returned HTTP `200`, approximately 1–3 ms |
| Cleanup | Temporary PodChaos resource was deleted |

Exact timestamps for pod deletion and recovery were not recorded.

## Root cause

The pod failure was intentional and induced by a controlled PodChaos
experiment. It was not an unexpected application or infrastructure
failure.

## Impact

- **Workload:** `sparebox-web`
- **Namespace:** `gitops-test`
- **Failure injected:** Deletion of one web pod
- **Recovery mechanism:** Kubernetes Deployment and ReplicaSet reconciliation
- **Post-recovery availability:** All 10 HTTP checks returned `200`
- **Error budget consumed:** Not calculated
- **MTTR:** Unknown; precise timestamps were not captured

## What the experiment proved, and what it did not

**Proved**
- The targeted pod was replaced following deletion.
- The Deployment recovered to two ready replicas.
- Service endpoints were available after recovery.
- Ten post-recovery HTTP requests succeeded.
- The temporary Chaos Mesh experiment was cleaned up.

**Not proved**
- Zero downtime during pod replacement.
- Exact recovery time or MTTR.
- HTTP success throughout the disruption.
- Resilience to node failure or simultaneous failure of multiple replicas.
- A quantified SLO or error-budget impact.

## Action items

- [ ] Capture timestamped HTTP probe results throughout future pod-failure experiments — project owner — before final evaluation.
- [ ] Record experiment start, pod deletion, replacement readiness, and final recovery timestamps — project owner — before final evaluation.
- [x] Define the availability SLO and error-budget calculation — reflected in `grafana/dashboards/slo.json`. Per-experiment error-budget consumption remains unmeasured.
