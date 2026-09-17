# ADR 0001: Defer full red/blue Inter-AS Option B, ship single-VRF CUST-A for Phase 1

**Status:** Accepted  
**Decision date:** 2026-08-17  
**Phase 1 outcome recorded:** 2026-09-17

## Context

The original Week 5 design was a full Inter-AS MPLS VPN Option B: two VRFs
(`red`/`blue`) across all three regions, per-router route distinguishers,
shared per-VRF route-targets, and LDP scoped per-region.

The first implementation attempt exposed two genuine problems:

1. Live-config RT-export drift affected 9 of 12 `vrf bgp` instances. The
   repository configuration files were already correct; the drift was in
   running `vtysh` state.
2. LDP/OSPF was allowed onto inter-AS transit interfaces, which formed a
   shared control-plane/LSP relationship across AS boundaries instead of
   keeping LDP scoped inside the intended routing regions.

The design was reverted to the verified OSPF/eBGP/IPsec baseline rather than
continuing to debug forward from a broken state.

The capstone still benefits from demonstrating real VPNv4/MPLS work, so a
smaller pilot was retained as the Phase 1 milestone.

## Decision

Ship a single-VRF `CUST-A` pilot on `r1-1`/`r1-2` in AS65001 using the existing
iBGP relationship and MPLS/LDP on that router pair.

The delivered pilot uses:

- `r1-1` customer address `192.168.101.1/32`;
- `r1-2` customer address `192.168.101.2/32`;
- VRF table `100`;
- RDs `65001:100` and `65001:200` respectively;
- shared RT `65001:100`.

The full red/blue Inter-AS Option B design is **deferred, not silently
removed**. It remains an optional follow-on track and does not gate the Phase
2 or Phase 3 schedule.

## Phase 1 outcome

The decision was validated by a cold-redeploy test. The committed
`containerlab/scripts/setup-cust-a.sh` recreates the Linux VRF and required
MPLS sysctls after Containerlab deployment. The control plane, kernel MPLS
route resolution and CUST-A data-plane forwarding were independently checked.

Final bilateral functional tests returned 5/5 replies with 0% packet loss:

```text
r1-1 CUST-A → 192.168.101.2
r1-2 CUST-A → 192.168.101.1
```

The pilot therefore satisfies the Phase 1 VPNv4/MPLS milestone while keeping
its scope explicit and reproducible.

## Consequences

- Phase 1 can close on the verified single-VRF pilot rather than carrying the
  original Option B experiment indefinitely.
- The Phase 1 repository has a real, reproducible VPNv4/MPLS data path rather
  than only a control-plane configuration.
- The full red/blue Inter-AS Option B implementation remains available as a
  separate technical extension without becoming a dependency of later phases.
- Future VPN work must preserve the routing-domain boundary lesson: do not
  accidentally form OSPF/LDP adjacencies across AS boundaries.
- The decision and its debugging history remain useful design artifacts even
  if the deferred Option B extension is never implemented.

## Follow-on constraints

Any future Option B work should begin from the verified Phase 1 baseline and
should include explicit checks for:

1. shared RT import/export correctness in both repository and live state;
2. OSPF/LDP scope at every AS boundary;
3. cold-redeploy reproducibility;
4. independent control-plane, FIB/LFIB and data-plane verification.
