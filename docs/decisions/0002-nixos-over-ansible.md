# ADR 0002: Bare-metal NixOS over Ubuntu + Ansible

**Status:** Accepted
**Date:** 2026-07-14 (recorded retrospectively 2026-09-19)

## Context

Containerlab's own quickstart targets Ubuntu, k3s's documentation assumes a
conventional distro, and Ansible is the more recognised keyword in infrastructure
job postings. Against that, the rest of this homelab already runs NixOS + flakes,
and the project's design principle is a single `flake.nix` as the source of truth
for the network simulation, the cluster and every supporting service.

Three components were checked directly rather than assumed, since "the binary is
packaged" and "pleasant to run declaratively" are different claims:

- `services.k3s` — a real, actively maintained module with 30+ options.
- `services.victoriametrics` and `services.telegraf` — both real and actively
  patched; this was the piece most worth doubting, and it held up.
- `pkgs.containerlab` — packaged and current.

The network-fabric half turned out to barely touch NixOS-specific configuration at
all: FRR and strongSwan run as Containerlab-launched Docker containers, so the host
mainly needs `virtualisation.docker.enable`. The genuine NixOS surface area was the
host-level metrics path, which is the piece with confirmed module support.

## Decision

Bare-metal NixOS. One `flake.nix` plus `modules/*.nix` for the fabric host config,
the k3s platform and all supporting services. No Ansible, no Terraform.

**Fallback rule:** if a component fights the declarative path for more than about a
day, run that one piece as a plain Docker container or a hand-written systemd unit
under the same flake. Still git-tracked, still reproducible, just not every line a
NixOS option. Do not switch OS over a single awkward component.

## Consequences

- Consistent with the rest of the homelab's tooling; no new language to learn
  alongside BGP, OSPF, IPsec, k3s, Flux and Chaos Mesh.
- Free atomic rollback via NixOS generations — which is the entire disaster-recovery
  story on a box with no failover partner and no IPMI.
- Loses "Ansible" as a resume keyword. Mitigated by being able to explain the choice
  rather than having defaulted into it.
- Created a real failure mode of its own: a build can succeed while silently
  dropping modules that keep the host reachable. This happened once. The mitigation
  is `modules/safety-assertions.nix`, which converts "would be unreachable" into a
  build-time error.

## Notes

If this were a first NixOS box, the honest answer would flip to Debian without
argument. An 18-week plan already carrying five or six new subjects is not the time
to also pick up a functional configuration language. This decision holds because
Nix is being *applied* here, not learned.
