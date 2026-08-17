
## Before starting any containerlab session
- `docker exec <any-node> ip -br link show` — if only `lo`/`eth0` are present,
  the veth links are gone (has happened across host reboots/idle periods even
  with containers still marked "running"). Redeploy before doing anything else:
  `containerlab destroy -t topology.clab.yml --cleanup && containerlab deploy -t topology.clab.yml`
- After redeploy, run `containerlab/scripts/setup-cust-a.sh` for the VPNv4 pilot,
  then wait ~10s before checking LDP/MPLS state. LDP needs a moment to converge;
  checking too fast reads as a phantom forwarding bug (cost real debugging time
  during Week 5 — see docs/phase1-progress.md §3.3).
