# Danger wavefront review: exact Manhattan-shell batching of the ray set

Written 2026-09-09 by Claude (peer) for `DANGER_WAVEFRONT_REVIEW_REQUEST.md`. Standalone
tests and counts only; no production code, no performance claims. P1 is running; this is a
later candidate.
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. Verdict: the challenge stands; the wavefront is exact
Processing relative cells in increasing Manhattan distance, removing from an active-ray set
every ray whose check at that distance is blocked, then adding the kernel once to every
non-blocked cell at that distance with an active member, reproduces the current ray union
exactly. A standalone differential against a faithful copy of the current visitor found no
difference in 885 trials at radii 42 and 163. `DANGER_PREFIX_REVIEW.md`'s statement that
reducing the step count requires changing visibility was too strong and is corrected there;
what it should have said is that sharing by kind-prefix is negligible. This candidate
reduces the per-source work from one event per ray step (188,892 at radius 163) to one
event per disc cell (83,928), with no visibility change.

## 2. Proof, in the terms of the current code
Per ray, events are ordered by Manhattan distance from the origin: an axis step moves to a
cell at `d + 1` and there checks then adds that cell; a diagonal step checks the two side
cells at `d + 1` (x side first), adds both, then checks and adds the target at `d + 2`. So a
ray's checks and adds are at non-decreasing distance, every checked cell is also the cell
added when the check passes, and at any one distance a ray has either one cell (axis or
target) or the two side cells, nothing else. Removal in the wavefront happens at the shell of
the first blocked check, which is the same event at which the original ray breaks; because all
removals at a shell precede all adds at that shell, a diagonal pair with one blocked side
adds neither side, exactly as the original's "both checks before either add". A cell is added
by the wavefront iff some member ray is still active after the shell's removals iff that ray
had no blocked check at any distance up to and including this one iff, in the original, that
ray reaches this cell with all prior checks passed and adds it. Rays that reach their
endpoints keep their bits set harmlessly (no later memberships). Out-of-grid relative cells
are treated as blocked at their shell, which both removes the rays that would have broken on
the bounds check and prevents any add there, matching `sightCellBlocked` and
`addVisibleCell`'s bounds guard. The origin is added separately, unconditionally, as now.
Within one source each cell receives one kernel add whichever ray justifies it, so no stamp
array is needed on this path; source order and the close-floor pass are untouched, so
cross-source float accumulation order is preserved.

## 3. Differential evidence (standalone Python, both algorithms from the source semantics)
Exact visitor: the current `castRay` order, side-check order, stamp semantics, bounds as
blocked. Wavefront: memberships precomputed by walking every ray once without walls, shells
by `|dx| + |dy|`, remove-then-add per shell, `blocked` including out-of-grid.
- Radius 42: exhaustive single wall at every position within Chebyshev distance 10 of the
  origin (440 cases, which covers every side-wall, target-wall and same-distance ordering
  near the origin where rays are densest) plus 300 random maps (grid sizes from `r / 2` to
  `2 r + 10`, wall density 0.02 to 0.35, random origin including edges): 740 trials,
  0 mismatches.
- Radius 163: single wall within Chebyshev 5 (120 cases) plus 25 random maps: 145 trials,
  0 mismatches.
The comparison is on the set of added cells; since each cell gets one identical kernel add
per source in both, equal sets mean bitwise-equal rasters.

## 4. Counts (no walls; memberships are geometry, walls only remove)
| radius | rays | disc cells with members | memberships | per cell | angular intervals per cell (ids sorted by angle) | 64-bit words per cell |
|---:|---:|---:|---:|---:|---:|---:|
| 42 | 236 | 5,652 | 12,640 | 2.24 | mean 1.00, max 2 | mean 1.02, max 2 |
| 163 | 924 | 83,928 | 191,484 | 2.28 | mean 1.00, max 2 | mean 1.02, max 5 |
Memberships equal ray steps plus diagonal side adds (12,352 + 288; 188,892 + 2,592), as they
must. The decisive fact is the interval count: a cell's ray set is one contiguous run of
angle-sorted ids in all but a handful of cells (max two runs), so a cell needs at most two
`(first, last)` id pairs; the bitset-word view is only needed for the active set.

## 5. Data and memory, counted
- Per relative cell: signed coordinates (2 x int16 = 4 B, kernel index derivable) plus
  membership as one or two id ranges (2 x uint16 each). Variable encoding with a count flag:
  radius 42 about 45 KB; radius 163 about 672 KB; radius 255 about 1.64 MB (205,004 cells);
  it scales with `r^2`, and no configured ceiling exists (`gunRange > 0` only), so the ledger
  must carry the actual size per geometry. Fixed two-range layout: 12 B per cell, 1.0 MB at
  163. Shell boundaries: one offset per Manhattan distance, `2 r + 1` int32s. Shared per
  geometry through the M1 `ref`, counted at capacity in `sharedDangerGeometry`; against the
  32 MiB cap the configured maps have 1,946,812 bytes of margin, so radius 163 fits with room
  and radius 255 would not without other changes.
- Active set per source: `ceil(rays / 64)` words, 120 B at radius 163, a stack array; no
  per-seat state. Range clear and range test are a few word operations because the ranges are
  contiguous.
- Construction: walk every ray once (the existing loop, no map), accumulate per relative cell
  into a transient `(2 r + 1)^2` table of small lists (about 107k slots at 163, a few MB
  transient if done naively; two passes, count then fill, keep it at the final size plus one
  int per slot), sort cells into shells, emit ranges. Milliseconds at 163; it runs once per
  nav-system activation like the rest of the geometry, and its time must be reported under
  the activation-ratio gate that already fails on 75 maps rather than hidden.
- Runtime memory traffic per source: one blocked-table byte per disc cell, one kernel load
  and one float add per visible cell, no stamp loads or stores. The existing `visited`
  workspace stays allocated and unused on this path until measured, as the request says.

## 6. Established approaches, and why a local representation is right
- Wald, Slusallek, Benthin, Wagner, "Interactive Rendering with Coherent Ray Tracing",
  Eurographics 2001: rays traced in packets with a mask of active rays updated at each step;
  the wavefront is the same idea with one packet of all perimeter rays and Manhattan shells
  as the steps.
- Masked packet traversal of kd-trees and BVHs (Reshetov et al., Overbeck et al., Boulos et
  al.): active-ray bitmasks advanced through a spatial structure, dead rays masked out; the
  discrete analogue here needs no spatial hierarchy because the shells are the structure.
- Heckbert and Hanrahan, "Beam Tracing Polygonal Objects", SIGGRAPH 1984: continuous beams;
  and recursive shadowcasting in roguelike FOV: active angular intervals swept outward. Both
  are the continuous version of "an angular interval of rays stays alive until a blocker";
  our intervals are discrete ray-id runs computed from the exact walk, which is why the result
  equals the ray union rather than a geometric visibility.
- No dependency fits: the alphabet is a few hundred ray ids, the structure is static and
  built once per geometry, the operations are range clear and range test on at most 15
  64-bit words, all available in Nim's `std/bitops` on native and wasm (64-bit integers are
  native in wasm32). SIMD packet libraries and FOV libraries would each impose their own
  visibility semantics or platform assumptions.

## 7. What must be tested before it counts (in-tree, when implemented)
- The differential of section 3 ported to Nim against the real `castRay` on real maps: all
  pool maps and the 11 giant maps, seeded sources at 331 and 1,300 px, comparing rasters
  bitwise after `rebuildDangerFromPoints`; plus the exhaustive near-origin single-wall sweep.
- Corpus per-case danger hashes and route hash unchanged; masks and pops identical.
- Ledger: the membership table and shell offsets at capacity; the activation delta reported.
- Same-distance ordering cases named explicitly: one side blocked, the other clear; both
  clear with a blocked target; a blocked axis cell that is also another ray's side cell; walls
  on the grid border; origin on the border.

## 8. Limits
No timing. The work model (one event per disc cell instead of one per ray step, no stamp
traffic) is a count, not a measurement; the per-event cost is different in kind (range
operations on words versus a stamp compare) and only the m5a rows can rank it against D0a.
Memory grows with `r^2` and the 32 MiB margin is finite. This does not touch the weight
refresh (P1's territory) or the close-floor pass.

## Primary-source follow-up (Codex)

[Wald et al., coherent ray tracing](https://onlinelibrary.wiley.com/doi/abs/10.1111/1467-8659.00508) motivates shared work across coherent rays. [Embree's current source/API documentation](https://github.com/RenderKit/embree) exposes masked packet occlusion queries. Those are established approaches, not a proof of this discrete shell ordering. The proof and885 differential trials above are specific to this visitor. Embree's general scene/packet API would require translating the exact discrete side-cell semantics into custom geometry callbacks and a new native/wasm integration; the existing boolean raster and integer ray events are the narrower seam.

Implementation caution: the current validator only requires gunRange>0; do not hard-code an assumed maximum300-cell radius or store coordinates/ray IDs in narrow integers based only on the measured163 radius. Use ordinary integer fields and variable-length membership ranges first, count actual retained capacity, and select a slightly larger non-colossal cap within James's authorized4x ceiling only if measured footprint needs it. The proof does not imply a speedup: dense walls may terminate individual rays early while a naive shell traversal still visits many inactive cells. Preserve that counter-hypothesis in the preregistration.

Artifacts: the standalone script behind this review is preserved in `peer-proofs/` (see its `README.md` for the file, the command, and the provenance note that the original stdout was transcribed, not saved).
