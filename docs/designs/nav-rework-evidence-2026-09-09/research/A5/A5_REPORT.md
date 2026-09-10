# A5_REPORT: pocket-connector attribution markers (isolated, attribution only)

Peer (Claude) work per `A5_PROFILE_REQUEST.md` in `nav-validation-symmetry`
(A4 baseline f9dff753 plus root's A4 diff). No root, source-cache, or
remote edits; nothing committed. This unit adds Fluffy stage markers and
cheap counters only; production control flow, the full validator, and the
A4 change are untouched. Mac numbers below are a smoke to prove the trace
carries the intended stages; they are not timing evidence. Root runs the
profiler on m5a/m8i with `run_a5_profile.sh`.

## 1. Baseline preserved

`A5/baseline/` holds the exact A4 bytes archived before any edit
(`A4-body_route_index.nim`, `check_body_index_validation.nim`, `A4-tree.diff`,
`SHA256SUMS`). The A5 markers are `A5-markers-over-A4.patch` (206 lines,
`body_route_index.nim` only, every runtime effect under
`when ProfileTracePath.len > 0`); the profiler change is `A5-profiler.patch`
(arguments `<pool-index> <repeats>`, defaults 48 and 5 as in A2, plus a
counters line). After instrumentation: the focused route-index suite passes
7 of 7 without the define (`local-mac/focused-route-index.log`) and the A4
mutation diagnostic still reports 2,164 of 2,164 matching decisions
(`local-mac/validator-mutations.log`), so the validator is unchanged.

## 2. Markers

Inside `buildPocketConnectors`: `pocket.canonicalMapping`,
`pocket.initialTargetsScratch`, `pocket.coverage` (whole
`buildPocketCoverage` call), `pocket.graphJoins` (the per-source-graph
connector loop), `pocket.finalPending` (the second `resolvePocketPending`),
`pocket.pack`, `pocket.collapse`. Inside `buildPocketCoverage`:
`pocket.coverage.classify` (per-cell classification loop),
`pocket.coverage.pixelScan` (the per-pixel seed loop as one stage),
`pocket.coverage.resolvePending`, `pocket.coverage.sort`. No per-pixel or
per-seed markers. Counters (totals over repeats, printed by the profiler):
coverage cells, cells needing pixel scan, secondary cells, scanned pixels,
deferred secondary points, unresolved before the coverage resolve, pending
out of coverage, resolve passes and seeds, join candidates (calls to
`pixelPocketPath` in the join loop), join paths, final pending in, paths,
pocket points.

## 3. Local smoke (Mac arm64, map 48 `br-gen-24678`, grid 283 by 151, five builds)

Durations nest (`index.complete` contains `index.pocketConnectors`, which
contains `pocket.coverage`, which contains its sub-stages); never add them.

| stage | mean ms (Mac, informational) |
|---|---:|
| index.complete | 431.7 |
| index.pocketConnectors | 237.9 |
| pocket.coverage | 144.0 |
| pocket.coverage.pixelScan | 79.8 |
| pocket.coverage.resolvePending | 61.1 |
| pocket.coverage.classify | 2.6 |
| pocket.coverage.sort | 0.3 |
| pocket.graphJoins | 52.2 |
| pocket.finalPending | 40.6 |
| pocket.canonicalMapping | 1.2 |
| pocket.initialTargetsScratch, pack, collapse | under 0.1 each |
| index.fieldsAndCountSegments | 72.5 |
| index.validate | 62.2 |
| index.legalMoves | 48.7 |

Counters per build (totals divided by five): 42,733 coverage cells, of
which 11,808 need a pixel scan and 171 are secondary; 766,656 pixels
scanned; 8,224 deferred secondary points; 2,114 seeds unresolved after
the scan, resolved over 4 passes touching 16,255 seeds; 10,186 pending
points leave coverage; the join loop calls `pixelPocketPath` 6,167 times
to produce 1 join path; `finalPending` then re-resolves the same 10,186
points; 11 pocket paths and 42 pocket points in total.

## 4. Evidence-backed next questions (attribution only, no optimization proposed)

1. `pocket.graphJoins` spends about 52 ms on 6,167 `pixelPocketPath`
   searches for one successful join on map 48. Each call runs an exact
   pixel search inside a 32 px box (`ConnectorMaxDistancePx`). Question for
   the native trace: is this the same on m5a, and what fraction of those
   calls return empty paths versus paths rejected by
   `coarseConnectorGraphComponent`? A second counter split would answer it
   without changing control flow.
2. `pocket.finalPending` re-runs `resolvePocketPending` over all 10,186
   pending points (8,224 of them deferred secondary points that were never
   scanned in the first pass) and costs about 41 ms. Question: how many
   resolve as `psCovered` by an existing path versus needing a new pixel
   search? Only the latter is real work; the former is a coverage test per
   point.
3. `pocket.coverage.pixelScan` scans 766,656 pixels for 11,808 cells (27.6
   percent of cells) and costs about 80 ms; classification itself is 2.6
   ms. Question: what share of scanned pixels are non-standable (rejected
   before any search) versus `psCovered` by a segment test versus seeds?
   The boundary-proof rule (`clearance <= PlayerHalf + radius`) decides the
   27.6 percent; how it varies across the 76 maps would say whether map 48
   is a geometry outlier.
4. The four `resolvePending` passes touch 16,255 seeds for 2,114 initial
   unresolved points, so seeds are revisited about 7.7 times each.
   Question: does pass count or seeds per pass track the m5a ratio?
5. Host question (m5a 2.412x versus m8i pass): the stage split here is the
   input; the answer needs the same profiler on both hosts with the same
   binary flags. If pixel-search stages scale worse on m5a than
   `index.legalMoves` and `index.validate` do, the ratio gap is in
   memory-bound pixel work, not in the coarse passes A2/A4 already halved.
   That is a hypothesis to test with `run_a5_profile.sh`, not a finding.

## 5. Cleanup and ownership

The isolated tree now carries: root's A4 diff (preserved byte-exact, see
`baseline/SHA256SUMS` versus the tree before A5) plus the A5 markers in
`src/shell/body_route_index.nim` and the profiler change in
`tools/profile_body_route_index.nim`; `tmp/a5/` holds local binaries and
the raw trace (copied to `A5/local-mac/`). Reverting A5 is
`git checkout -- tools/profile_body_route_index.nim` and applying
`A5-markers-over-A4.patch` in reverse; the A4 bytes are in `baseline/`.
Root owns native runs; `run_a5_profile.sh` reproduces the A2 recipe with
the pool index and repeat count as arguments.

A5 ATTRIBUTION READY
