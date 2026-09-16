# Giant-map shared memory plan: exact structural reductions for the 11 configured maps

Historical proposal from before the expanded memory allowance. It is not implemented and is no longer required to meet the measured memory gate; see MEMORY_CAP_RULING.md.

Written 2026-09-09 by Claude (peer). Proposal only; nothing implemented. Numbers are from
`M2-m8i/configured.json` (worst shared 31,340,947 bytes on `br-gen-5204`, mixed graph
29,114,217 on every giant map) and from a local census run with the repo's own graph builder
on all 11 maps (`newBodyMixedGraph`, `newBodyRouteWorkspace`, `bodyMixedGraphBytes`; Mac,
structure only, no timing). Constraints honoured: exact costs, FIFO order among equal f, full
corpus quality, one shared workspace, existing caps unchanged.
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. Where the 29.1 MB goes (identical structure on all 11 maps)
Lattice nodes N = 344,487 (4 px), nav cells C = 85,814 (8 px), standable nodes 262,636 to
281,778 (76 to 82 percent of N), anchor cells 67,285 to 71,677, wall-band cells 5,728 to
7,197, bridge nodes 1,039,014 to 1,116,962 (capacity 1,259,712 on every map).

| Component | Bytes | Composition |
|---|---:|---|
| bridges | 8,471,408 | `bridgeOffset` C x 8 x int32 = 2,746,048; `bridgeLen` C x 8 x uint8 = 686,512; `bridgeNodes` capacity 1,259,712 x 4 = 5,038,848 (length 4.16 to 4.47 MB) |
| workspace | 8,267,688 | six N x 4-byte arrays: `g`, `parent`, `parentBridge`, `goalCost`, `state`, `goalStamp` |
| buckets | 7,084,656 | ring 3 x 131,072 x 4 = 1,572,864; per node `next`, `previous`, `bucket`, `queuedF` = 5,511,792 |
| reconstruction | 1,377,948 | `reconstruct` N x 4 |
| cellForNode | 1,377,948 | N x 4 |
| fineForCell | 1,373,024 | C x 4 x 4 |
| anchors | 687,743 | `anchorForCell` C x 4 + `anchorNode` N x 1 |
| legality | 387,548 | `legal` N x 1 + `standable` N / 8 |
| wallBand | 85,814 | C x 1 |

Everything else in the shared bound is about 2.2 MB (route index 1.45 MB, geometry 0.44 MB,
scratches 0.33 MB) plus M3's overlay and cache (a few hundred KB on these maps) and R1's
sight table (86 KB). Target: shared at most 16,777,216, so at least 14.6 MB must come out of
the mixed graph, and the plan should leave a margin for M3 and R1.

## 2. Candidate reductions, each exact by construction

Exactness here means: identical pops, identical g values, identical tie order, identical
routes, identical corpus hash. Each item changes a representation, never a value or an order.

| id | Change | Saving (giant) | Mechanism and why it is exact | Cost or risk |
|---|---|---:|---|---|
| G1 | Exact-size `bridgeNodes` (copy into a `newSeqOfCap(len)` at the end of `newBodyMixedGraph`, or two-pass count then fill) | 571,000 to 883,000 (per map: (1,259,712 - len) x 4) | Contents unchanged; only slack freed. Already flagged in `CAPACITY_AUDIT.md` | one transient copy at activation |
| G2 | Per-cell bridge base offset instead of per direction: `bridgeBase` C x int32 plus the existing `bridgeLen`; offset(dir) = base + sum of lens for lower directions | 2,402,792 | The builder appends each cell's bridges in direction order into `bridgeNodes` (cell loop, then direction loop, `add path`), so a cell's bridges are contiguous and the per-direction offset is derivable. Missing directions have len 0 | up to 7 byte adds per bridge edge in the pop loop (`bridgeOffset` is read once per anchor expansion per direction) |
| G3 | Drop `cellForNode`: cell = (x div 2, y div 2) from the node's lattice coordinates, which the loop already computes (`x = node mod width`, `y = node div width`) | 1,377,948 | Pure arithmetic identity of the existing mapping (`cellOf(finePoint(node))` with 8 px cells over a 4 px lattice) | one shift and one multiply per anchor expansion |
| G4 | Drop `fineForCell`: node(cell, slot) = (2 cy + slot div 2) x width + 2 cx + slot mod 2 | 1,373,024 | Same identity; the array is read only in endpoint attachment (`attachments`, line 438), never in the pop loop | none measurable |
| G5 | Goal tables to the attachment cap: replace `goalStamp` and `goalCost` (two N x 4 arrays) with a per-search bit per node (N / 8 = 43,061 bytes, generation-cleared like `standable`'s layout, or reuse a spare bit in `state`) plus a table of at most `BodyEndpointAttachmentCap = 512` (node, cost) pairs sorted by node | 2,712,835 | The tables are written only from the goal attachment set (`beginBodyRouteSearch`, at most 512 entries) and read once per settled node (`goalStamp[node] == generation` then `goalCost[node]`); a bit test plus a binary search over at most 512 entries returns the same cost | a bit test per settled node, a 9-step binary search only when the bit is set |
| G6 | `state` from uint32 to uint16 with a closed bit in bit 15 and a wrap-clear of the array every 32,767 searches (the queue already does this for `touchedGeneration`) | 688,974 | Stamps only compare for equality with the current generation; a clear on wrap keeps every stale stamp unequal | a 689 KB memset every 32k searches |
| G7 | Drop `queue.bucket`: the bucket is `queuedF mod bucketCount` and membership is "queuedF set", using a sentinel (`queuedF = low(int32)`) or a bit in `state` | 1,377,948 | `queueRemove` needs the bucket to unlink; it is recomputable from `queuedF`, which is kept | one modulo per remove |
| G8 | Drop `parentBridge`: at reconstruction, for a node whose parent is an anchor node, find the direction whose bridge from the parent's cell ends at the node (at most 8 checks of `bridgeNodes[offset + len - 1]`) | 1,377,948 | `parentBridge` stores exactly (parent cell x 8 + direction); the parent node is stored in `parent`, its cell is derivable (G3), and a bridge's end node identifies the direction uniquely because two bridges from one cell cannot end at the same node in the builder (each direction targets a different neighbour cell's anchor) | at most 8 compares per bridge edge at finish; if the uniqueness claim needs a guard, keep a uint8 direction instead (saving 1,033,461) |
| G9 | Drop `reconstruct`: reconstruct by walking `parent` twice (count, then emit) straight into the span builder, or emit spans in reverse and reverse the at most 4,096 spans | 1,377,948 | The route emitted is the same point sequence; the overflow rule (`brfDescriptorOverflow` when the count reaches the lattice size) becomes a count check with the same bound | two parent walks instead of one at finish; the failure condition must stay identical |
| G10 | Bucket ring 131,072 to 65,536 (the M0 argument applies unchanged: pops match absolute f exactly, ties stay in insertion order) | 786,432 | Exact; only chain-scan cost changes | measured chain scans on far searches, as M0 was |
| G11 | `anchorNode` derived (`anchorForCell[cell] == node`) and `anchorForCell` as a uint8 slot 0..3 or 255 | 601,929 | Pure identity of the existing tables | two extra reads per anchor test in `mixedActive` |
| G12 | Drop `queuedF` by recomputing f = g + h(node) at pop-chain scan | 1,377,948 | f is a deterministic function of g and the node; the chain scan compares recomputed f with `currentF` | an octile per chain entry per pop; only worth it if G1 to G11 leave a gap |

Not proposed: compacting the workspace over standable nodes only (saves 18 to 24 percent of
the per-node arrays but needs a remap table and touches every index path; net gain under
1 MB here); the compact active-node workspace (H2) is not bounded below the standable count
on these maps because the danger field can make most standable nodes active; lossy or
narrowed cost types (change values); any cap change.

## 3. Ranked plan with the expected result
Tier A, representation-only, no algorithm change, in this order (largest exact win per line
of code first): G5 (2.71 MB), G2 (2.40 MB), G3 (1.38), G4 (1.37), G7 (1.38), G8 (1.38 or 1.03
with the guard), G1 (at least 0.57), G6 (0.69), G11 (0.60). Sum at least 12.48 MB (12.13 with
the G8 guard variant). Shared bound after Tier A: about 18.9 MB. Not enough alone.
Tier B, exact algorithmic changes: G9 (1.38), G10 (0.79), G12 (1.38). With G9 and G10 the
shared bound is about 16.7 MB, marginal against 16.78; with G12 as well about 15.3 MB, a
margin of about 1.4 MB before M3's overlay and cache (a few hundred KB) and R1's table
(86 KB). So the plan that lands the giant maps under the cap with a real margin is Tier A
plus all of Tier B, and G12 is the item that decides whether the margin exists; its pop-time
cost is the one thing in this plan that needs a measured decision.

Expected shared bound on `br-gen-5204` after the full plan: about 15.3 to 15.7 MB including
M3 and R1, that is under 16 MiB by about 1.1 to 1.5 MB. The s2 pool maps and colossal gain
proportionally (colossal's total falls by roughly the same fractions of its 29-plus MB
graph).

## 4. Verification each item must pass
Exactness: full corpus route hash 5a1340213fe3... unchanged; per-case danger hashes
unchanged (they do not depend on the graph but guard the harness); `pops_per_tick` and every
recorded mask identical to the parent in all six rows at 331 and 1,300 px; `--latency`
non-timing identical; the Dial collision test (M0) and a new tie-order test that forces
equal-f chains through G7 and G12; the focused suites and both compile shapes.
Ledger: `bodyMixedGraphBytes` re-derived per item so the saving is visible line by line, with
the capacity rule from M2, and the giant-map rows re-run under the unchanged 16 MiB gate.
Timing: G2, G3, G5, G7, G8, G10, G12 touch the pop loop or finish path; run the A/A protocol
on c6a and m5a at both ranges after Tier A and again after Tier B, reporting `ns/pop` and the
far-goal rows; accept only if within the A/A spread or better.

## 5. Implementation tradeoffs, honestly
- G5 and G7 replace array reads with a bit test and a small search or a modulo; on the pop
  path that is likely neutral or better for cache pressure but is not proven until measured.
- G8's uniqueness claim (one bridge per direction per cell ends at a distinct node) follows
  from the builder, but a `doAssert` in a debug build or the uint8 fallback keeps it honest.
- G9 changes the finish path's shape; the overflow failure must trigger on exactly the same
  routes (same count bound), which the corpus's `brfDescriptorOverflow` cases pin if any exist.
- G12 is the only item with a real per-pop cost and the only one that buys the margin; run
  G1 to G11 first, measure the ledger, then decide G12 against the measured gap.
- All items keep one workspace, the existing `BodyRouteSpanCap`, `BodyEndpointAttachmentCap`
  and `BodyDialMaxBuckets`, and the corpus untouched.

## 6. Corrections (2026-09-09, after `BRIDGE_ENCODING_REVIEW_REQUEST.md`)
- G3 and G4 are not unclamped identities: `navWidth = max(1, width div 8)` (floor) while the
  lattice is `(width - 1) div 4 + 1` (ceil), so the last lattice column and row of maps whose
  dimensions are not multiples of 8 (the giant maps: 3211 x 1713) clamp into the final cell
  and `fineForCell` is overwritten in node order there. G3 stands with the clamp
  `min(x div 2, navWidth - 1)`; G4 is demoted to "keep the table, or derive interior cells
  plus an explicit boundary table after a proof over all supported dimensions"; its saving is
  not counted.
- G8: store an `int8` direction with `-1` sentinel and derive the source cell from `parent`;
  saving 1,033,461; no reverse lookup.
- New first bridge item: direction-byte bridge encoding (`BRIDGE_ENCODING_REVIEW.md`),
  3,779,136 at present capacity; G1 then saves 0.14 to 0.22 MB on the byte stream; G2
  unchanged at 2,402,792.
- Revised totals on `br-gen-5204`: Tier A about 14.1 MB (shared about 17.2 MB after); with G9
  and G10 about 15.1 MB; with G12 about 13.7 MB, before M3 and R1. Section 3's earlier sums
  are superseded by these.

## Status note (2026-09-09, after MEMORY_CAP_RULING.md)
James authorised up to 4x the non-colossal memory caps; root is setting a 32 MiB shared limit (2x) after branch sync, with the 256 MiB total unchanged. The measured giant maps fit that limit, so the reductions in this document are no longer required for the obsolete 16 MiB target. The document is retained as an inventory of exact savings and their proofs; nothing in it is scheduled. All timing, quality, determinism and activation gates stay in force.
