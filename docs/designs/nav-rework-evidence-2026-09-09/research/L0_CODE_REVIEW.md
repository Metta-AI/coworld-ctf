# L0 code review: identical-ordered-source reuse in the scheduled danger cadence

Written 2026-09-09 by Claude (peer). Reviewed the working-tree diff against 8265f53a
(`src/shell/body_nav.nim` +27/-5, `tests/test_shell_body_nav_rework.nim` +50). No edits.
Independent check: the focused suite compiled and passed on this Mac, 11 of 11 tests, with the
runtime-linked flags (`-d:release -d:useMalloc -d:noSignalHandler --threads:on`, Nim 2.2.6).
Timing is not claimed; nothing here is a success claim until the c6a and Xeon rows exist.

## 1. Verdict
The diff implements exactly the narrow L0 shape agreed in `LIVENESS_REVIEW.md` section 8. I
found no correctness defect. Three test gaps and one accounting note are listed in section 4;
none blocks the measurement run.

## 2. What the source change does (verified line by line)

- `rebuildDanger` is split: selection (`selectDangerSources`) then a new private
  `rebuildSelectedDanger(seat, map, tick)` holding the previous "rebuild from selected points"
  block unchanged (empty selection still rebuilds a zero raster). The public `rebuildDanger`
  calls both, so it remains forced. `initializeDanger` is untouched and calls `rebuildDanger`,
  so it remains forced. The corpus support, the harness and the direct test callers keep
  today's semantics.
- `rebuildScheduledDanger`: for each due active seat it copies `selectedDangerCount` and the
  whole `selectedDangerPoints` array to locals (value copy of `array[8, BodyPoint]`, stack, no
  allocation), runs selection, then marks `changed` if the count differs or any point
  `[0 ..< newCount]` differs positionally. On `changed`: the old path (`rebuildSelectedDanger`
  then `publishDangerGeneration`). On unchanged: `dangerTick = tick` and
  `installedRoute = BodyInstalledRoute()`, nothing else. The trace record is written in both
  cases with the new source count.

### 2.1 Exact ordered-source dependency: verified
The comparison is positional over the ordered points and the count, which is the correct
conservative key: `rebuildDangerFromPoints` (423-455) reads only the ordered points and the
seat's once-assigned geometry (`dangerKernel`, `dangerPerimeter`, `dangerRadius`,
`dangerRangePx`, assigned at 291-294 and never reassigned) plus the immutable map and three
constants, and it zeroes the raster first, so equal ordered points give a bitwise-equal raster
and, through `rebuildPackedWeights`, a bitwise-equal table. `selectedDangerSeats` is not
compared; the raster does not depend on it, so that is correct. A same-set reorder is treated
as changed (test 2 proves it), which is the conservative side of the float-order question.

### 2.2 Forced initializer behaviour: verified
`rebuildDanger` and `initializeDanger` always rebuild. Note that production never calls
`initializeDanger` (its only callers are tests and the harness); the first scheduled cadence
on a fresh seat compares against the constructor state (count 0, zero points). If the first
selection is empty, the unchanged branch is taken and the seat keeps the constructor's zero
raster from `initDanger` and the packed table built at 296-299, which is what a forced empty
rebuild would produce (`rebuildDangerFromPoints` zeroes; `maximum = 0`). Correct, and no
sentinel needed, as Codex said.

### 2.3 Installed-route expiry: preserved
On the unchanged branch the route is cleared unconditionally. On the changed branch
`publishDangerGeneration` (467-474) increments the generation and then clears any installed
route whose generation differs, which after an increment is every installed route. So a due
seat loses its installed route on every cadence in both branches, exactly as before. One
difference to record, not a defect: the old path cleared the route only when the mixed graph
existed (`publishDangerGeneration` returns early otherwise); the new unchanged branch clears
regardless. Systems without a mixed graph never install routes, so there is no observable
change.

### 2.4 In-flight preservation: verified
`cancelStaleRouteJob` (771-784) keeps a job when lifecycle is in flight, the request
generation matches, and `request.dangerGeneration == seat.dangerGeneration`; the unchanged
branch touches none of those. After expiry the seat's `shouldQueryRoute` cannot issue a new
request while `pendingRoute.lifecycle != brlIdle` (608), so an in-flight far search is not
replaced by the expiry re-request; a seat that is idle with a route re-requests as today.
Test 1 pins this through `routeJob.workspaceGeneration` equality across the cadence, which is
the right observable: any restart would call `beginBodyRouteSearch`, which bumps the workspace
generation.

### 2.5 Determinism and accounting
The branch is a pure function of seat state. The unchanged branch does not call
`publishDangerGeneration`, so `timing.weightRefreshes` and `weightRefreshNanoseconds` are not
incremented for skipped rebuilds; that is correct for the harness split (no refresh happened)
but the B0 comparison must state that `weight_refreshes` and the danger stage will drop for
that reason. Movement masks change when far routes now install, so this is a GameVersion,
nine-fixture, viewer and docs change once it is accepted; the M0 checkpoint's rebuilt viewer
will be stale again.

## 3. Tests: what they prove
- Test 1 ("unchanged scheduled danger preserves search but expires installed routes"): same
  input at tick 32 keeps generation, advances `dangerTick`, leaves raster and table equal to the
  pre-cadence values, keeps the in-flight job (workspace generation equal after another
  scheduler call), the route then installs, and the cadence at 64 expires it with the generation
  still unchanged. This covers 2.1 (positive), 2.3 and 2.4.
- Test 2 ("removal, return and source reordering"): moving `selfXy` so that the two sources
  swap distance order bumps the generation (reorder is a change); removing all sources bumps;
  empty again is unchanged; return bumps. Covers 2.1 (negative) and the empty-selection case.
- Pre-existing test at 193 still passes (a changed source still cancels stale in-flight work).

## 4. Gaps and notes (not blocking measurement)
1. Equivalence, not just skip: test 1 compares the raster and table with their own pre-cadence
   values, which any skip would satisfy. A stronger check compares them with a forced
   `rebuildDanger` on a second system given the same inputs at tick 32, proving the skipped
   rebuild would have produced the same bytes. Cheap to add.
2. Self movement without reorder: no test moves `selfXy` while keeping the order (for example
   (16,48) to (20,48) with the two sources in the same relative order) and checks "unchanged".
   That is the case the far-wave workload depends on.
3. Forced initializer on identical inputs: no test calls `initializeDanger` twice with the same
   inputs and checks the generation increments both times; it documents that the public entry
   points stayed forced.
4. Multi-seat cadence: both tests use one seat, so `dangerSeatDue` phase alignment is not
   exercised with the new branch; the existing seat-suite cadence tests (`test_shell_body_seat`
   225-270) cover the schedule but should be rerun, along with the Phase 1 liveness laws, both
   compile shapes and `tests/tests.nim` once, before any fixture cycle.
5. The `--latency` rerun is the acceptance signal for the liveness symptom; with reordering as
   the seat approaches the goal cluster, far waves may still show some restarts, so report
   `scheduler_restarts` per wave, not just publication.
