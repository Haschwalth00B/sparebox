# Chaos Mesh Workload Validation

## Scope

This document records Kubernetes workload-level fault-injection tests
for Spare Box. These tests are separate from the Containerlab FRR/MPLS
routing reconvergence benchmarks in `containerlab/chaos/`.

## Environment

- Host: `sparebox`
- Kubernetes: k3s
- Test workload: `sparebox-web`
- Namespace: `gitops-test`
- Workload: nginx Deployment with two replicas
- Fault injection: Chaos Mesh NetworkChaos and StressChaos

## Kernel support

The NixOS kernel configuration enables the legacy iptables filter
backend required for the NetworkChaos tests:

- `NETFILTER_XTABLES_LEGACY=y`
- `IP_NF_IPTABLES_LEGACY=m`
- `IP_NF_FILTER=m`

The required `iptable_filter` module was loaded during validation.

## Test results

### Network delay

- A temporary NetworkChaos delay experiment was applied to the test
  workload.
- Recovery was reported successfully.
- The temporary experiment resource was removed after testing.

### Packet loss

- A temporary NetworkChaos experiment injected 10% packet loss.
- Configured fault duration: 30 seconds.
- The experiment reported `AllRecovered=True`.
- The recovery event reported that Chaos Mesh successfully recovered
  the injected fault.
- The `sparebox-web` Deployment remained at 2/2 ready replicas.
- The temporary NetworkChaos resource was removed after testing.

### CPU stress

- A temporary StressChaos experiment targeted one `sparebox-web` pod.
- Configuration: one CPU worker at 25% load for 30 seconds.
- Chaos Mesh reported successful injection and recovery in Kubernetes events.
- The `sparebox-web` Deployment remained at 2/2 ready replicas.
- The temporary StressChaos resource was deleted after testing.
- No HTTP probe measurements during the CPU stress interval were recorded.

## Verification commands

Set the kubeconfig before running Kubernetes commands:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

kubectl get deployment sparebox-web -n gitops-test
kubectl get networkchaos -A
```

Expected final state: the Deployment has two ready replicas and no
temporary NetworkChaos resources remain.

## Limitations

These tests validate workload-level fault injection and recovery.
They do not measure FRR/MPLS route reconvergence, VPN failover, or
fabric-level packet-loss recovery. Those results remain documented
separately in the Containerlab trial results.

## Game Day 1: Web Pod Failure and Recovery

**Date:** 2026-10-11  
**Experiment:** Chaos Mesh `PodChaos`, action `pod-kill`  
**Target namespace:** `gitops-test`  
**Target selector:** `app=sparebox-web`  
**Mode:** `one`

### Hypothesis

Terminating one web pod should cause Kubernetes to create a replacement.
With two replicas, the web service should remain reachable through its
ClusterIP service.

### Observations

- One `sparebox-web` pod was terminated by Chaos Mesh.
- Kubernetes created a replacement pod, which reached `Running` and `Ready`.
- The deployment returned to 2/2 available replicas.
- The service had two endpoints after recovery.
- All 10 HTTP requests performed after recovery returned HTTP 200.
- Observed post-recovery response times were approximately 1–3 ms.
- VictoriaMetrics `probe_success` remained `1` at every 5-second sample
  from 10:15 to 10:20 UTC.
- No probe failures were observed in that query window.
- The temporary `PodChaos` resource was deleted after the experiment.

### Outcome

**Passed:** Kubernetes self-healing and post-recovery HTTP availability.

The monitoring samples support service availability throughout the observed
window. Because probes were sampled every five seconds, this does not prove
that no brief interruption occurred between samples.

### Limitations and follow-up

- Exact pod recovery duration was not measured.
- HTTP requests were run after recovery, not continuously during injection.
- The experiment did not validate the `SpareboxWebDown` alert or notification
  delivery because no failed probes were observed.

Next: run a separate, controlled outage test to validate alert firing,
notification delivery, and alert resolution.

## Game Day 2: Alert Firing, Discord Notification, and Resolution

### Objective
Validate the end-to-end alerting path by deliberately taking
`sparebox-web` offline, confirming that `SpareboxWebDown` fires,
and verifying that Discord receives both firing and resolved
notifications.

### Procedure
1. Confirmed `sparebox-web` had two ready replicas.
2. Checked that Alertmanager was healthy.
3. Scaled `sparebox-web` from two replicas to zero to simulate an outage.
4. Monitored the vmalert API until `SpareboxWebDown` entered
   the `firing` state.
5. Allowed time for the firing notification to be sent.
6. Restored the Deployment to two replicas and waited for rollout
   completion.
7. Verified the Discord firing and resolved notifications.

### Results
- Alert rule: `SpareboxWebDown`
- Expression: `probe_success{job="sparebox-web"} == 0`
- Severity: `critical`
- Alert progression observed: `inactive` -> `pending` -> `firing`
- Firing notification received in Discord: approximately 4:01
- Resolved notification received in Discord: approximately 4:06
- Alertmanager notification counter for Discord: 1 at the time
  of the post-test metrics query
- Discord failure counters reported: 0
- Application restored successfully: 2/2 replicas ready

### Outcome
The controlled outage triggered the expected critical alert.
Discord received both the firing and resolved notifications,
confirming the end-to-end notification path and recovery signal.

The reported Discord receipt times are observations, not a
precise measurement of outage duration or alert-resolution latency.
The notification counter is a point-in-time metric and should
not be interpreted as the total number of messages received.

### Follow-up
- Keep the alert rule, Alertmanager configuration, and notification
  credentials managed safely.
- For future game days, record outage start, alert firing,
  application recovery, and resolved notification timestamps
  separately to calculate detection and recovery latency.
