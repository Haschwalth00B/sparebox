# Sparebox Kubernetes Chaos Mesh Experiments

## Scope

These manifests are reusable experiment templates for the `sparebox-web`
Deployment in the `gitops-test` namespace.

They are stored under `docs/`, outside the Flux-managed `k8s/` tree.
Flux will not automatically apply them.

The API server accepted all three templates using server-side dry-run.
This validates their schemas, not successful fault injection.

## Experiments

| File | Type | Scope | Duration |
|---|---|---|---|
| `experiments/pod-failure.yaml` | PodChaos | One matching pod | 30 seconds |
| `experiments/network-delay.yaml` | NetworkChaos | One matching pod; outbound direction | 30 seconds |
| `experiments/cpu-stress.yaml` | StressChaos | One matching pod; one CPU worker at 25% load | 30 seconds |

All experiments select pods using the `app=sparebox-web` label in the
`gitops-test` namespace.

## Safety rules

- Run experiments manually; do not leave them continuously active.
- Confirm the cluster and workload health before every experiment.
- Run only one experiment at a time.
- Keep a second terminal open to monitor the workload and probes.
- Stop and investigate if recovery does not occur as expected.
- Never target the separate `gitops-test` Deployment by name or label.
- Do not add these manifests to Flux-managed Kustomizations.

## Preflight

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

kubectl get nodes
kubectl get deployment sparebox-web -n gitops-test
kubectl get pods -n gitops-test -l app=sparebox-web
kubectl get podchaos,networkchaos,stresschaos -n gitops-test
```

## Validate templates without running them

```bash
for f in docs/chaos-mesh/experiments/*.yaml; do
  kubectl apply --dry-run=server -f "$f" || exit 1
done
```

## Manual execution

Only after preflight checks pass, apply **one** experiment:

```bash
kubectl apply -f docs/chaos-mesh/experiments/pod-failure.yaml
```

For the other experiment types, substitute `network-delay.yaml` or
`cpu-stress.yaml`. Applying a manifest starts the experiment; it is not a
dry-run.

Watch the experiment and target workload:

```bash
kubectl get podchaos,networkchaos,stresschaos -n gitops-test -w
kubectl get pods -n gitops-test -l app=sparebox-web -w
```

In a separate terminal, check the HTTP probe:

```bash
curl -fsSG http://127.0.0.1:8428/api/v1/query \
  --data-urlencode 'query=probe_success{job="sparebox-web"}'
```

A probe value of `1` means the HTTP check succeeded; `0` means it failed.
Network delay or CPU stress may not cause a complete outage, so a value of
`1` during those experiments does not by itself mean injection failed.

After the experiment ends, verify recovery:

```bash
kubectl get deployment sparebox-web -n gitops-test
kubectl get pods -n gitops-test -l app=sparebox-web
curl -fsSG http://127.0.0.1:8428/api/v1/query \
  --data-urlencode 'query=probe_success{job="sparebox-web"}'
```

If an experiment remains active unexpectedly, inspect its status and events
before taking action:

```bash
kubectl describe podchaos sparebox-web-pod-failure -n gitops-test
kubectl get events -n gitops-test --sort-by=.lastTimestamp
```

For NetworkChaos or StressChaos, use the corresponding resource kind and
name when inspecting status.

## Evidence recorded on 2026-10-10

- Chaos Mesh installation and CRDs were present.
- The PodChaos outage test affected both `sparebox-web` replicas for 90
  seconds; the experiment reported recovery.
- The HTTP probe reported failure during the outage and recovered afterward.
- vmalert and Alertmanager delivered firing and resolved notifications to
  Discord.
- The Deployment returned to 2/2 replicas and the alert returned to inactive.
- The temporary outage experiment was deleted.
- The three 30-second templates passed server-side dry-run validation.
- The NetworkChaos and StressChaos templates have not yet been executed.
- No recurring Schedule resource has been configured.
- The three templates are documentation files and are not reconciled by Flux.

Record future experiment runs separately, including start/end time, observed
probe values, alert delivery, recovery, and any unexpected behavior.

## Optional weekly Schedule

The file `schedules/weekly-pod-failure.yaml` defines a weekly PodChaos
Schedule. It uses `@every 168h`, targets one matching `sparebox-web` pod,
and injects `pod-failure` for 30 seconds. Its concurrency policy is
`Forbid`.

The Schedule is stored outside the Flux-managed `k8s/` tree. It passed
server-side dry-run validation but has **not** been activated.

Before enabling it, confirm that the weekly disruption will not overlap
with a mentor demo or other important workload. The Schedule recurs until
it is deleted.

### Activate after review

```bash
kubectl apply -f docs/chaos-mesh/schedules/weekly-pod-failure.yaml
```

### Inspect Schedule status

```bash
kubectl get schedule sparebox-web-weekly-pod-failure -n gitops-test
kubectl describe schedule sparebox-web-weekly-pod-failure -n gitops-test
```

### Delete the Schedule to stop future runs

```bash
kubectl delete schedule sparebox-web-weekly-pod-failure -n gitops-test
```

Deleting the Schedule prevents future scheduled runs. If an experiment is
already active, inspect its status and verify recovery separately.

