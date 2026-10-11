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
