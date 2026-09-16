# L1 code review: exact packed-table identity through one shared scratch

Written 2026-09-09 by Claude (peer). Reviewed the working-tree diff against c5f39376 (L0)
for `src/shell/body_nav.nim`, `tests/test_shell_body_nav_rework.nim` and
`tools/bench_body_nav_rework.nim`; the intervening merge 1aeffbd2 touches only `tools/glory`.
No edits. Independent checks on this Mac: the focused suite passes 12 of 12 with the
runtime-linked flags; `nim check` of `body_nav.nim` passes in the runtime-stub shape. No
success claim; the c6a run (`L1_PREREG.md`, `run_packed_identity.sh`) decides.

## 1. Verdict
Correct as far as I can trace it. Exact compare, ownership by swap without aliasing, full
memory accounting, forced initialisation and cadence expiry all hold. Four notes in section 5,
none blocking the measurement.

## 2. Scratch identity and exactness
- `publishDangerGeneration` now packs into `system.packedWeightScratch`, then compares
  `system.packedWeightScratch != seat.packedWeights`. Nim `seq` inequality compares length
  and every element, so this is an exact byte-for-byte identity with no hashing.
- The scratch is allocated in the constructor with `gridWidth * gridHeight` elements, the same
  `cellCount` the packer uses, so `rebuildPackedWeights`'s reallocation branch (`weights.len !=
  cellCount`) never fires on the tick path. Every seat's table is packed to the same length in
  the constructor (296-299), so after any number of swaps every buffer in rotation has the
  same length; no allocation on the cadence path.
- Pass one of the packer writes every cell, so the scratch's stale contents from a previous
  swap can never leak into a comparison.
- The float raster has no reader outside the rebuild, the packer and the diagnostic snapshot,
  so "table identical" is exactly "nothing the search reads changed". The raster itself is
  still rewritten fresh on every rebuild, so there is no staleness in the equal case: the
  retained table is the packing of the new raster by definition of equality.

## 3. Swap ownership
- `swap(system.packedWeightScratch, seat.packedWeights)` moves ownership; no two seats can
  share a buffer, and the search receives the seat's table as an `openArray` per call, so no
  reference survives across ticks. The alias test (two seats, seat 0 swapped twice while seat 1
  is not due) checks seat 1's bytes are untouched and the scratch length is still one table.
- On the `force` path the swap happens even when equal (constructor-packed table and scratch
  are identical), which is harmless.

## 4. Memory accounting
Caveat added 2026-09-09: the ledger categories were later found incomplete for the per-seat danger geometry copies; see `MEMORY_SHARING_REVIEW.md`. The scratch accounting reviewed here is unaffected.

- `BodyNavigationBytes.packedWeightScratch` is counted with its allocator overhead and added
  to `total`; the scratch is allocated before `result.navigationBytes = retainedNavigationBytes()`
  and the 256 MiB cap check, so the cap sees it.
- The harness's `sharedUpperBound` (activation row) includes `packedWeightScratch`, and the
  pool row passes only if that bound is at most 16 MiB (`bench_body_nav_rework.nim:250-276`),
  so the shared gate sees it too. `bytesJson` emits `packed_weight_scratch`, so the ledger
  shows the line explicitly. This satisfies the "explicitly ledgered" condition. Sizes: 85,466
  bytes on the largest pool map, 778,752 on colossal, per Codex; the activation row will state
  the actual values.

## 5. Expiry and forced-initialisation semantics
- Forced: `initializeDanger` calls `publishDangerGeneration(seat, force = true)`, which swaps
  and increments unconditionally. The harness's activation and quality setup uses
  `initializeDanger`, so the corpus rows keep forced semantics. The corpus oracle
  (`nav_route_corpus_support.nim:201-208`) constructs with `prepareRouteQueries = false` and
  reads only the raster, so it is unaffected by the packed path entirely.
- Expiry: on the changed path the installed route is cleared whenever `revision != 0`, no
  longer conditioned on a generation mismatch; that is equivalent to before (after an increment
  the mismatch was always true) and now also holds on the equal path, so every cadence still
  expires the route. The L0 unchanged branch clears only when `revision != 0`, matching the
  prereg's note and avoiding a needless write. In-flight work survives both equal paths because
  the generation is untouched and `shouldQueryRoute` cannot issue a request while the job is
  pending or in flight (608).
- Generation wrap handling is unchanged.

## 6. Tests
- "reordering preserves exact packed costs": the same two sources reordered by moving
  `selfXy` leave the table equal; generation unchanged; the in-flight job survives (workspace
  generation equal after another scheduler call). Then removal bumps, empty-again is an L0 hit,
  return bumps. This is the case L0 missed on c6a. Note: it encodes that this specific reorder
  packs identically, which is a property of these inputs, not a theorem; if it ever fails it
  means a Q8 boundary case, which would be worth knowing rather than a test bug.
- "packed scratch swaps do not alias another seat": as in section 3, plus the ledger line.
- The earlier L0 and cancel tests still pass.

Gaps (not blocking): no test that a swapped-in table equals a fresh repack of the same raster
into a local buffer (direct proof the scratch was complete); no test that a second
`initializeDanger` with identical inputs still bumps (documents forced semantics); no test that
the retained total and the pool shared bound still pass on every pool map with the scratch
(the c6a activation row covers this for real).

## 7. The experiment script
`run_packed_identity.sh`: parent is the L0 candidate binary copied from the L0 run, candidate
built from the working tree; three interleaved parent/candidate `--tick` processes on CPU 5,
two candidate `--latency` processes, then quality plus activation. That isolates L1 from L0
correctly. Two small notes: the parent's source hashes are not recorded in `source-hashes.txt`
(only the candidate's), so the L0 run's own hash file is the provenance for the parent; and
`git diff > candidate.patch` is taken against the index after the main merge, which is fine
because the merge touched only `tools/glory`, but the patch will not show that the parent
predates the merge. Acceptance reads as in `L1_PREREG.md`: all seat-waves complete within
2,000 ticks in both latency processes, restarts and any censored tails retained, corpus hash
unchanged, pool shared and total gates pass, and the timing rows reported against the L0
parent with no floor-reduction claim.
