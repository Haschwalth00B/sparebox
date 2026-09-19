# Postmortem: <experiment name> — <YYYY-MM-DD>

**Status:** Resolved
**Experiment:** `chaos/experiments/<file>.yaml`
**Blast radius:** namespace `<ns>` — never `flux-system` or `kube-system`
**Duration:** <start>–<end> (<X> min)
**MTTR:** <X> min (first alert → resolution)

## Summary

One or two sentences: what broke, what the observable impact was.

## Timeline

Machine-pulled rows from Chaos Mesh and Alertmanager; hand-written rows marked.

| Time | Event | Source |
|---|---|---|
| | experiment started | Chaos Mesh |
| | first SLI degradation visible | Grafana |
| | alert fired | Alertmanager |
| | experiment ended | Chaos Mesh |
| | alert resolved | Alertmanager |

## Root cause

Hand-written. This is the part that is actually analysis rather than output.

## Impact

- SLO affected:
- Error budget consumed:
- Did detection happen before the SLO breach, or after?

## What the experiment proved, and what it did not

Be specific about the failure mode exercised. A pod kill is not a node failure; a
network delay is not a partition. State which claim this run supports.

## Action items

- [ ] <action> — <owner> — <due>
