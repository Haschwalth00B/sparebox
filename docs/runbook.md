
## Before starting any containerlab session
- `docker exec <any-node> ip -br link show` — if only `lo`/`eth0` are present,
  the veth links are gone (has happened across host reboots/idle periods even
  with containers still marked "running"). Redeploy before doing anything else:
  `containerlab destroy -t topology.clab.yml --cleanup && containerlab deploy -t topology.clab.yml`
- After redeploy, run `containerlab/scripts/setup-cust-a.sh` for the VPNv4 pilot,
  then wait ~10s before checking LDP/MPLS state. LDP needs a moment to converge;
  checking too fast reads as a phantom forwarding bug (cost real debugging time
  during Week 5 — see docs/phase1-progress.md §3.3).
- Always rebuild with `nixos-rebuild switch --flake .#sparebox`, never a
  bare `nixos-rebuild switch`. `/etc/nixos` is a stale, separate flake
  copy (not a symlink) left over from before `~/sparebox` became the
  single source of truth, and an unpinned rebuild silently builds from it
  instead — with no error (see `docs/phase1-progress.md`, metrics/Grafana
  section).
- If a nix-managed service with symlinked state (e.g. Grafana's
  `/var/lib/grafana`) needs a clean-state reset, never `rm -rf` its state
  dir and restart via `systemctl` directly — that state includes
  nix-store symlinks set up by activation, not the running process.
  Delete the state, then run `nixos-rebuild switch --flake .#sparebox` to
  regenerate it correctly.
