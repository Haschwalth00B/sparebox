# Phase 1 Progress — Network Fabric (Weeks 1–5)

Covers the debugging journey behind what's already shipped and committed.
Command-level verification detail lives here; `docs/runbook.md` holds the
distilled operational lessons; `docs/decisions/0001-option-b-defer.md` holds
the reasoning behind the one real scope decision made this phase.

## Topology & IP/ASN plan

| Region | ASN | Routers | Loopbacks | Intra-region subnet |
|---|---|---|---|---|
| r1 | 65001 | r1-1, r1-2 | `10.0.1.1/32`, `10.0.1.2/32` | `10.1.0.0/24` |
| r2 | 65002 | r2-1, r2-2 | `10.0.2.1/32`, `10.0.2.2/32` | `10.2.0.0/24` |
| r3 | 65003 | r3-1, r3-2 | `10.0.3.1/32`, `10.0.3.2/32` | `10.3.0.0/24` |

Ring transit links: `10.12.0.0/30` (r1-2↔r2-1), `10.23.0.0/30` (r2-2↔r3-1),
`10.31.0.0/30` (r3-2↔r1-1). Two FRR routers per region
(`quay.io/frrouting/frr:10.7.0`), full-mesh iBGP within each region,
eBGP on the ring between regions.

## Week 2 — Fabric bring-up (shipped)

3-region Containerlab topology, 2 FRR routers per region, intra-region OSPF
full adjacency on all three regions.

## Week 3 — eBGP ring + IPsec (shipped)

eBGP ring (region1↔region2↔region3↔region1) plus iBGP within each region;
cross-ring reachability proven. strongSwan running as Containerlab sidecars
(`network-mode: container:<router>`, custom `local/strongswan:5.9` image),
transport-mode PSK tunnels on all 3 transit links.

**Verification:** tcpdump on each transit interface concurrent with a ping
between the link's two IPs — confirmed ESP-only capture, no cleartext
leakage, on all 3 links.

**Known gaps, both now closed:**
- IPsec tunnels negotiate NAT-T despite no NAT device present — cosmetic,
  caused by the strongSwan sidecar sharing the router's full netns. Not
  fixed (scoping `charon.interfaces_use` per node would close it), but
  doesn't affect correctness.
- tcpdump wasn't baked into either image, so Week 3/5 captures needed an ad
  hoc `apk add tcpdump` that didn't survive a container recreation. **Closed
  since:** `containerlab/strongswan/Dockerfile` now installs tcpdump at
  build time.

## Week 4 — BAH 2026 buffer

Skipped; went straight into Week 5.

## Week 5 — MP-BGP VPNv4 segmentation

### Original design: red/blue dual-VRF Option B

Two VRFs (`red`, `blue`) across all three regions, per-router RD with a
shared per-VRF RT (red = `65000:100`, blue = `65000:200`), full Inter-AS
MPLS VPN Option B, LDP scoped per-region, dummy loopbacks per VRF per
router for ping-based segmentation proof.

### What went wrong

Two real issues surfaced before the design was reverted:

1. **Live-config RT-export drift** on 9 of 12 `vrf bgp` instances — the
   export RT had drifted to the router's own RD instead of the shared RT.
   The on-disk `frr.conf` files were already correct; only the live
   `vtysh` state had drifted.
2. **LDP crossing AS boundaries.** The on-disk config enabled `mpls ldp`
   and put the ring transit subnet into OSPF area 0 on `eth2` (the
   inter-AS link) as well as `eth1` — so OSPF/LDP formed adjacencies
   across AS boundaries instead of staying intra-region-only, violating
   the Option B rule that no shared LSP should cross an AS boundary.

Rather than debug forward from a broken state, reverted to the Week 3
verified baseline (OSPF/eBGP/IPsec ring, no VPNv4) and restarted with a
narrower design.

### Restart: single-VRF `CUST-A` pilot

Single VRF `CUST-A` (RD `65001:100` on r1-1, `65001:200` on r1-2, shared RT
`65001:100`), piloted on just r1-1/r1-2 — same AS, existing iBGP peers —
before deciding whether to extend across regions. Host MPLS kernel support
confirmed present (`mpls_router`/`mpls_iptunnel` load cleanly,
`net.mpls.platform_labels` already `100000`).

**Debugging notes, in order encountered:**

- Applied the first round of config changes with `docker restart` on
  r1-1/r1-2 — broke intra-region OSPF/connectivity on both nodes. Root
  cause: `docker restart` only re-manages Docker's own default `eth0`
  (bridge) interface, not the `eth1`/`eth2` veth links Containerlab
  manually injects into each container's netns at deploy time — those
  links were gone entirely after restart. Fix going forward:
  `containerlab deploy --reconfigure` for any change, never `docker
  restart`, on Containerlab-managed nodes.
- The `CUST-A` VRF kernel device (`ip link add CUST-A type vrf`) had to be
  created by hand, since zebra's VRF-lite backend expects the device to
  already exist rather than creating it itself.
- Once created, BGP VPNv4 exchange was confirmed genuinely working — both
  `192.168.101.1/32` and `192.168.101.2/32` visible in each other's `show
  bgp vrf CUST-A` with correct cross-node next hops — and kernel FIB/route
  resolution was confirmed correct via `ip route get`, resolving with the
  right MPLS label out the right interface.
- `net.mpls.conf.<iface>.input=1` was needed on top of the platform-wide
  sysctl but wasn't sufficient alone to fix reachability.
- tcpdump run from the strongSwan sidecar (sharing the router's full
  netns) confirmed the send side was fully correct — MPLS-labeled ICMP
  genuinely left r1-1 on the wire — isolating the remaining gap to
  receive-side label handling.
- A later session found live containers had been sitting since Aug 8 with
  no `eth1`/`eth2` veth links at all (confirmed via `ip -br link show` —
  only `lo`+`eth0` on all 6 nodes) — the same Containerlab link-loss
  failure mode as the `docker restart` issue above, but this time
  occurring on its own between sessions. Fixed with a full `containerlab
  destroy`+`deploy` rather than `docker exec` against the stale
  containers.
- Post-redeploy, the `CUST-A`/LDP config block turned out to have never
  actually been saved to the repo's `frr.conf` files — it had only
  existed in the previous session's live containers, wiped by the
  destroy. Confirmed via a clean `git diff` against matching
  container/host `cat` output. Rewrote both
  `containerlab/frr/r1-1/frr.conf` and `r1-2/frr.conf` in full and applied
  live with `frr-reload.py --reload`.
- Re-testing after a fresh `destroy`+`deploy` showed the manually-created
  VRF device and MPLS sysctls hadn't survived either — meaning the pilot
  wasn't actually reproducible from git alone. Fixed by committing
  `containerlab/scripts/setup-cust-a.sh`, an idempotent script that
  recreates the VRF device and sysctls after every deploy.
- A later apparent 100% packet-loss regression traced back to two
  overlapping, non-forwarding causes: the veth links vanishing again
  mid-session (root cause still not identified — `uptime` showed a
  long-running host, but `docker inspect` showed the container's netns
  had only existed minutes), and checking LDP/MPLS state before LDP had
  ~10s to converge after redeploy, which reads as a phantom forwarding
  bug if you don't wait it out.

### Final verification (confirmed reproducible)

With the settle time accounted for and a genuinely cold redeploy:

- `ip -f mpls route show` showed the correct kernel LFIB entry.
- `ip vrf exec CUST-A ping` succeeded end-to-end with 0% packet loss.
- Confirmed reproducible from a cold `containerlab destroy`+`deploy` plus
  the committed `setup-cust-a.sh` script — not just working in one long
  session.

Control plane (BGP VPNv4 exchange), kernel FIB (`ip -f mpls route show`),
and data plane (`ping`) were all independently checked. Config is committed
and pushed (`containerlab/frr/r1-1/frr.conf`, `r1-2/frr.conf`,
`containerlab/scripts/setup-cust-a.sh`).

## Deferred, not dropped: full red/blue Inter-AS Option B

See `docs/decisions/0001-option-b-defer.md` for the full reasoning. Short
version: given outreach now includes Equinix-tier edge/CDN companies, the
full design isn't descoped — it's an optional, non-blocking parallel track
startable any time from Week 7 onward, structured so it never gates a
Phase 2 or Phase 3 ship date. Phase 1 ships on schedule at Week 6 with the
single-VRF `CUST-A` pilot as the delivered VPNv4 milestone.

## Operational lessons (carried into Phase 2)

1. Containerlab-injected veth links (`eth1`/`eth2`) don't survive `docker
   restart` and can vanish on their own between sessions. Check `ip -br
   link show` at the start of any session before debugging anything else.
2. Anything set up by hand against a running container doesn't persist and
   isn't reproducible unless it's scripted and committed — cost real time
   twice in Week 5. The fix pattern (script it, commit it, test from a
   cold redeploy) is exactly the discipline Flux/GitOps enforces
   structurally in Phase 2.
3. LDP — and likely other convergence-based systems later, e.g. Flux
   reconciliation — needs settle time after a redeploy before a negative
   test result can be trusted.
