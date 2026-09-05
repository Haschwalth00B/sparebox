# ADR 0001: Defer full red/blue Inter-AS Option B, ship single-VRF CUST-A for Week 5

**Status:** Accepted
**Date:** 2026-08-17

## Context

The original Week 5 design was a full Inter-AS MPLS VPN Option B: two VRFs
(red/blue) across all three regions, per-router RD with a shared per-VRF
RT, LDP scoped per-region. A first attempt hit two real issues — live-config
RT-export drift on 9 of 12 `vrf bgp` instances, and LDP/OSPF forming
adjacencies across AS boundaries when the design explicitly requires no
shared LSP cross an AS boundary — and was reverted rather than debugged
forward from a broken state.

Current outreach for this capstone has been confirmed to include
Equinix-tier edge/CDN companies specifically, not just the earlier fintech/
general-tech list. Full Inter-AS Option B is exactly the kind of network
depth that outreach would probe in an interview, so silently dropping it
in favor of the simpler pilot would lose a genuine differentiator.

Phase 1 still has a fixed Week 6 ship date, and Phase 2/3 dates depend on
Phase 1 shipping on time.

## Decision

Ship the narrower single-VRF `CUST-A` pilot (r1-1/r1-2 only, same AS,
existing iBGP peers) as the Week 5 VPNv4 milestone. The full red/blue
Option B design is **deferred, not descoped** — scheduled as an optional,
non-blocking parallel track, startable any time from Week 7 onward,
explicitly structured so it never gates a Phase 2 or Phase 3 deliverable
or ship date. Week 18 (buffer) is the fallback landing spot if it isn't
picked up opportunistically earlier.

## Consequences

- Phase 1 ships on schedule at Week 6 regardless of whether the full
  Option B extension ever gets built.
- The delivered Week 5 milestone (single-VRF pilot) is smaller in scope
  than originally designed, but is fully verified and reproducible from a
  cold redeploy — real, not partial credit.
- The deferred design remains available as a genuine talking point for
  edge/CDN-specific interviews without carrying any schedule risk for the
  rest of the capstone.
- If Option B is never picked up, the resume/interview narrative leans on
  the pilot plus the documented reasoning for the scope call itself — the
  decision-making is as much the artifact as the code would have been.
