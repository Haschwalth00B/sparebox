# Postmortem: SpareboxWebDown Alert Lifecycle — 2026-10-11

**Status:** Resolved
**Experiment:** Controlled scale-down of `sparebox-web`
**Blast radius:** Namespace `gitops-test`; only the test web Deployment
**Duration:** Exact outage duration not measured
**MTTR:** Not measured; exact failure-to-recovery timestamps were not collected

## Summary

A controlled outage was induced by scaling `sparebox-web` from two
replicas to zero. The `SpareboxWebDown` critical alert progressed
through pending to firing, and Discord received both firing and
resolved notifications. The Deployment was restored to two ready
replicas, the probe returned `1`, and vmalert reported the alert
as inactive.

## Timeline

Times below are approximate local time (IST, UTC+05:30) unless stated
otherwise. Notification receipt times were reported manually.

| Time | Event | Source |
|---|---|---|
| Before test | Deployment healthy at 2/2 replicas | kubectl |
| During test | Deployment scaled to zero replicas | kubectl |
| During test | Alert progressed from inactive to pending to firing | vmalert API |
| 16:01 approx. | Firing notification received | Discord, manually observed |
| After firing | Deployment restored to two replicas; rollout succeeded | kubectl |
| 16:06 approx. | Resolved notification received | Discord, manually observed |
| After recovery | Probe returned `1`; alert was inactive; no active Alertmanager alerts | VictoriaMetrics, vmalert, Alertmanager |

The vmalert response recorded `activeAt` as `2026-10-11T10:30:15Z`.
The exact outage start and application recovery timestamps were not captured.

## Root cause

The service outage was intentional: the Deployment was scaled to zero
to validate the monitoring and notification pipeline. The test was
not caused by an unexpected production failure.

## Impact

- SLI affected: HTTP availability probe for `sparebox-web`.
- Alert: `SpareboxWebDown`.
- Expression: `probe_success{job="sparebox-web"} == 0`.
- Severity: `critical`.
- Error budget consumed: not calculated; a quantified SLO/error budget
  impact was not established during this test.
- Detection: the alert fired after the configured pending period.
- Recovery: two replicas became ready, the probe returned `1`, and the
  alert became inactive.
- Notifications: Discord firing and resolved messages were both received.

## What the experiment proved, and what it did not

**Proved**
- The probe detected the simulated service outage.
- vmalert evaluated the rule and reached the firing state.
- Alertmanager delivered the firing and resolved notifications to Discord.
- The application and alert state recovered after the Deployment was restored.

**Not proved**
- Exact outage duration, MTTR, or alert-resolution latency.
- A quantified error-budget impact.
- High availability or resilience to node failure.
- That the notification counter alone represented both Discord messages.

## Action items

- [ ] Capture exact timestamps for outage start, firing, recovery, and resolution — project owner — before final evaluation.
- [x] Define and document the availability SLO and error-budget calculation — reflected in `grafana/dashboards/slo.json`. Per-experiment error-budget consumption remains unmeasured.
