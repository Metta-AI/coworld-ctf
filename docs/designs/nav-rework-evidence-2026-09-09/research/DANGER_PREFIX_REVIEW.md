# Danger-ray prefix sharing review: measured, and rejected as negligible

Written 2026-09-09 by Claude (peer) for `DANGER_PREFIX_REVIEW_REQUEST.md`. Standalone counts
and documents only; no source edits, no speed claims. Context from Codex: D0 measured three
m5a 1,300 px pairs, worst body p95/max 5.949/6.035 to 5.839/5.953 ms, masks and pops
identical, quality and ledger identical, gate still failing; D1 (kernel index) remains the
next small ablation.
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. Verdict: reject prefix sharing of the current ray set
A trie of exact step prefixes over the existing perimeter rays shares almost nothing: at the
configured radius 163 it has 172,708 nodes for 188,892 steps, a reduction of 8.6 percent of
the walk before any trie overhead, and by depth 128 every one of the 924 rays occupies its
own node. The redundancy in the walk is real but lives at the cell level (2.25 steps per
unique cell), and no exact prefix structure can reach it because a ray's continuation is
determined by its slope, not by the cell it is in. The only structures that do reach it
change the visibility definition, which is a design decision, not an exact optimisation.

## 2. Counts (standalone script replicating `castRay` exactly: perimeter via `pyRound`,
supercover decision, signs, diagonal side cells)

| radius | rays | total steps | diagonal side adds | trie nodes (kind sequence, per sign quadrant) | unique cells reached | disc cells | steps saved by a trie | steps per unique cell |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 42 (331 px) | 236 | 12,352 | 288 | 10,680 | 5,652 | 5,525 | 1,672 (13.5 percent) | 2.19 |
| 163 (1,300 px) | 924 | 188,892 | 2,592 | 172,708 | 83,928 | 83,457 | 16,184 (8.6 percent) | 2.25 |
| 255 (stress; no configured ceiling exists, only `gunRange > 0`) | 1,444 | 462,820 | 4,208 | 430,068 | 205,004 | 204,269 | 32,752 (7.1 percent) | 2.26 |

Sharing by depth at radius 163: 12 nodes at depth 0 (one per sign quadrant and first kind),
92 at depth 4, 508 at depth 16, 844 at depth 32, 916 at depth 64, and 924 (all rays
distinct) from depth 128 on. So the sharing is confined to the first few dozen steps near the
origin, where the rays are densest. The unique-cell count is essentially the disc (cells
reached at most a few outside the exact circle), which says the walk covers every cell in
range; the 2.25 multiplicity is rays re-treading cells they do not own.

Why the kind-sequence trie is nearly a forest: two rays through the same cell at the same
depth arrive with different `(nx, ny)` and therefore different decision histories; their
kind sequences coincide only while their slopes agree to within the integer decision, which
for 924 distinct slopes ends within a few dozen steps. A trie keyed on cells instead of kinds
would merge those nodes, but the children of a merged node would then depend on which ray
arrived, so it is no longer a trie of the existing rays; it is a new ray set.

## 3. The ordering argument, tested (it holds, but does not help here)
Within one source: `nextVisitGeneration` stamps once; every cell receives exactly one
`+= kernel[cell - origin]` per source through `addVisibleCell`'s stamp, whichever ray reaches
it first; a ray's truncation depends only on its own cells and side cells and the immutable
`sightBlocked` table, never on another ray or on the stamps; diagonal side adds are
idempotent through the same stamp; out-of-grid checks truncate identically; the close-floor
pass runs after all rays of the source and is unaffected. So the raster after a source is the
union of the truncated ray paths with one kernel add per cell, independent of the order in
which rays or their shared prefixes are walked. Source order and the per-source kernel adds
stay as they are, so cross-source float accumulation order is preserved. A trie walk would
therefore be exact. No hole found in the reasoning; the hole is in the payoff.

## 4. What a trie would cost if built anyway
Nodes at radius 163: 172,708. Layout options: three child indices plus a kind per node
(13 to 16 bytes, 2.2 to 2.8 MB), or a preorder layout with an implicit first child, a
next-sibling index and a kind byte (5 bytes, about 0.86 MB) walked with an explicit stack of
depth at most 2 radius. The shared bound on the configured maps is 31,607,620 bytes against
the 32 MiB (33,554,432) cap, a margin of 1,946,812 bytes, so the 16-byte layout does not fit
and the 5-byte layout takes almost half the margin. Activation: one pass over 188,892 steps
per nav-system construction, well under a millisecond, but it is added activation time and
the activation-ratio gate is already failing on 75 non-colossal maps with no waiver; any
candidate must report its activation delta, not hide it.

## 5. Established approaches, and why none is an exact drop-in
- Symmetric Pre-Computed Visibility Tries (denismr, https://github.com/denismr/SymmetricPCVT):
  a trie whose nodes are cells and whose paths are precomputed lines to every cell in the
  disc, pruned so each cell has one path. It captures cell-level sharing (one node per cell)
  and is symmetric, which is exactly why it is a different visibility definition from
  "union of independent supercover rays to the perimeter": cells become visible iff their
  single trie path is clear. On our maps that changes which cells receive kernel adds, so the
  corpus danger hashes and routes change; a design decision with a GameVersion cycle, the
  same class as the shadowcasting option already rejected in `RASTER_REVIEW.md` (R4).
- Shadowcasting and its variants (RogueBasin FOV survey; Milazzo's "Roguelike Vision
  Algorithms"; Ford's symmetric shadowcasting): O(disc cells), each cell once; same
  objection, different definition.
- Red Blob's visibility article and the ray-tree patents in the search are about continuous
  or triangle-mesh visibility, not a discrete union of pixel rays.
- General trie or radix libraries: the alphabet here is three symbols plus a sign quadrant,
  the structure is static and built once, and the walk needs the cell coordinate at every
  node; a flat array with implicit children fits that far better than any dictionary-style
  trie, so a dependency would add nothing even if the idea were worth pursuing. It is not,
  by the counts above.

## 6. Measurable hypothesis, stated so it can be refused cleanly
If anyone still wants to test prefix sharing: the maximum possible step reduction at 1,300 px
is 8.6 percent of the ray steps, all of it in the first few dozen steps from each source,
where the visited stamp already makes the cell add a compare-and-skip; the remaining per-step
cost (blocked-table load, stamp load) is unchanged for the other 91 percent. The prediction
is that the danger slice moves by less than the measured A/A spread on m5a, at a cost of 0.9
to 2.8 MB of shared memory against a 1.9 MB margin. That is a rejection, recorded here so it
is not rediscovered.

## 7. Where the remaining walk cost actually is, from the counts
188,892 steps per source at 1,300 px against 83,928 unique cells: each step does a blocked
load, a stamp load, and (on 44 percent of steps) a stamp store and a float add. Exact levers
that remain within the current definition are per-step cost only: D1 (incremental kernel
index), the geometry hoist, and check placement; none reduces the step count. Reducing the
step count needs either a smaller perimeter or a different visibility rule, and both change
rasters. The close-floor pass (a bounded square per source) and the packed-weight refresh
(about 1.08 ms of the danger slice on m5a) are the other two components and are separate
from the walk.

## 8. Correction (2026-09-09, after `DANGER_WAVEFRONT_REVIEW.md`)
Section 1's sentence "no exact prefix structure can reach it because a ray's continuation is
determined by its slope, not by the cell it is in" was right about prefix tries and wrong as a
general claim. The step count of the same ray union can be reduced exactly by batching the ray
set over Manhattan shells with an active-ray set, without any visibility change; a standalone
differential (885 trials at radii 42 and 163) found no difference. See
`DANGER_WAVEFRONT_REVIEW.md`. The rejection of prefix sharing itself stands.

Artifacts: the standalone script behind this review is preserved in `peer-proofs/` (see its `README.md` for the file, the command, and the provenance note that the original stdout was transcribed, not saved).
