# M3 review: overlay and safe cache in the navigation ledger

Written 2026-09-09 by Claude (peer). Reviewed the working-tree diff (against 71a61745) to
`src/shell/body_safety_query.nim`, `src/shell/body_hazard.nim`, the ledger in
`src/shell/body_nav.nim`, `activationRow` in `tools/bench_body_nav_rework.nim`, and the two
new tests in `tests/test_shell_body_nav_rework.nim`, plus `M3_PREREG.md`. No source edits.
M3 is running on m8i; no numbers from it are used here.
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. Verdict
Correct and complete for the ownership it targets. The overlay and cache are now counted once,
through the scratch's references, at capacity, with per-sequence and per-object allowances,
and the activation row builds, refreshes and installs them before reading a fresh ledger.
No additional maximum-retention measurement is required for the installed context (section 4).
Two notes in section 5, neither blocking.

## 2. Accounting
- `contextRetainedBytes` (`body_safety_query.nim`): `hazard = scratch.hazard.retainedBytes`,
  `cache = scratch.cache.retainedBytes`; both procs are now capacity-based
  (`body_hazard.nim:55-73`: `sizeof(owner[]) + sum(capacity * elemSize)`), and the sequence
  headers are inside the owner's `sizeof`, as the comment says. Allowances: 16 per owner
  object and 16 per non-empty sequence, the same constant the nav ledger uses for its own
  sequences, so the two categories are consistent with the rest of the ledger. A nil overlay
  or cache counts zero, so bare systems are unchanged.
- The nav ledger adds `hazardOverlay` and `safeCache` lines from the context, folds the
  allowance into `allocatorOverhead`, and includes both in `total`; the harness includes both
  in `shared_retained_upper_bound_bytes`. Attribution as shared is right: one overlay and one
  cache per episode, referenced by nav.
- No double count: `BodySafetyScratch.retainedBytes` still returns only `sizeof(scratch[])`,
  `system.hazard` (the same object) is not counted separately, and the episode's own
  references are not ledgered anywhere else.
- The rest of the nav ledger is also capacity-based now (rasters, visited, packed tables,
  scratch, trace, seats, geometry including R1's `sightBlocked`), consistent with M2; every
  one of those is `newSeq`-built except the perimeter, so capacity equals length for them.

## 3. Activation order and workload
`activationRow`: map, index, overlay from `map.armedSnapshot`, cache refreshed once with
`refreshSafeCache(index, overlay, 0, 1)`, then `newBodyNavSystem(..., preparedRouteIndex =
index)` (whose constructor releases the following payload), then `installSafetyContext`, then
the far query, then `retainedNavigationBytes` read fresh. That satisfies the prereg's
ordering requirement: the overlay and cache are built while the index still carries its
following payload, which `newBodyHazardOverlay` and `refreshSafeCache` may read, and the ledger
is taken after installation. Timings are kept separate (`hazard_activation_ns`,
`safe_cache_activation_ns`) and added into `total_activation_ns`, matching the prereg. The
`activationResult` wrapper turns a `BodyMapError` into a failing row with the message instead
of aborting the whole run, which is right for a 65-row gate.

The armed snapshot populates every arrival cell and the segment arrays, so the row measures
the conservative (fully armed) overlay, and the single refresh populates the cache's side and
room arrays, so the row measures the cache at its steady size.

## 4. Maximum retention of the installed context
- Overlay: immutable after construction; its four sequences are `newSeq` to computed
  counts; capacity equals length. What the row measures is the maximum.
- Cache: one set of `safeDistQ4`, `safeNext`, `roomHasDry` sized by sides and rooms,
  replaced by fresh `newSeq` on a key change (fingerprint, generation, 48-tick bucket). The
  steady state is one set; the transient during a refresh is two sets for the duration of the
  three assignments, after which the old payloads are released. Since sizes are fixed by the
  index, the refreshed cache in the row is the maximum steady retention; the transient
  doubling is at most the cache's own size (tens to hundreds of KB) and is not retained.
  No further measurement is needed; if Codex wants the transient bounded on paper, the
  ledger line for the cache times two is the bound.
- Scratch: fixed arrays, unchanged.

## 5. Tests and notes
- "fresh navigation ledger counts the populated safety context": before and after
  installation on a two-seat system with a fully armed snapshot; checks the two lines are
  zero before, equal the owners' `retainedBytes` after, and that the `total` delta equals the
  two lines plus the allowance delta. This pins exactly what M3 claims.
- "graph ledger includes unused reserved bridge capacity" (from M2): reserves 64 extra
  elements and checks the ledger moves by 256 bytes. Good regression for the capacity rule.
- Note 1: the harness's `sharedUpperBound` and the ledger's `total` both include the two lines;
  the JSON `retained` block emits them (`hazard_overlay`, `safe_cache`). Prior rows lack the
  keys; consumers should treat a missing key as "not counted", not zero, when comparing.
- Note 2: the production episode with no armed zone holds a dark overlay (owner only); the
  row's armed overlay is therefore an upper bound for the overlay line, which is the right
  side to be on for a cap.
