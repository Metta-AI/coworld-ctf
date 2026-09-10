# Phase 3 report — bounded hierarchical route queries

## Status

Phase 3 is **complete**, including the performance fixup at commit `eaa2046a`.
The immutable Phase 2 route index now supports synchronous bounded queries through one shared,
generation-stamped workspace. Queries attach exact pixel endpoints, consider
same-room and side-graph candidates, assemble and validate a complete route in
scratch, and publish only by an atomic copy into fixed per-seat storage.

The final focused suite passes 8/8. Every retained fine point on the published
narrow-pocket map is individually attachable. The synthetic cap case records a
local cap hit while returning another valid bounded candidate, and both local
and side pop counts remain at or below 4,096. Both server compile shapes, shard
wiring, and the full runtime-linked release suite pass. The legacy planner
remains present and all pre-existing suites stay green.

## Fixup — 32-seat body-slice regression

The Phase 3 query core originally constructed the immutable route index and
shared query scratch in every `newBodyNavSystem` call. The containment probe's
body sample intentionally includes that constructor, so it exposed activation
work even though none of its default-body ticks calls the hierarchical query.
No timed-window change was made.

### Measured localization

The required runtime-linked release command was run sequentially in detached
worktrees at `71e2d2d1`, `fd224c2c`, and the pre-fix HEAD `6b6e3b69`:

```sh
nim c -r -d:release -d:useMalloc -d:noSignalHandler --threads:on \
  tests/test_shell_containment.nim
```

The three `max_body_us` verdicts at each revision were:

| revision | run 1 | run 2 | run 3 | median |
|---|---:|---:|---:|---:|
| `71e2d2d1` (before query integration) | 5,988 | 5,010 | 5,373 | 5,373 |
| `fd224c2c` (query core) | 6,361 | 5,570 | 5,706 | 5,706 |
| `6b6e3b69` (pre-fix HEAD) | 7,592 | 5,745 | 5,822 | 5,822 |

The noisy maxima vary with host load, but the step appears at `fd224c2c`; the
later cap and order tests add no production body work. A diagnostic build then
timed the two new constructor calls over 36 samples on the containment map:

```text
newBodyRouteIndex:         951..1083 us
newBodyRouteQueryScratch:   19..53 us
```

Removing only those two constructions while retaining the larger fixed
per-seat descriptors returned ordinary waves to roughly 4.0–4.6 ms. This
locates the delta in activation-time index construction inside the sample,
not in per-tick querying, scratch touches, or the retained per-seat arrays.

### Fix

Checkpoint:

```text
eaa2046a shell: avoid unused route query activation
```

`newBodyNavSystem` now leaves the hierarchical route index and scratch absent
unless its caller sets `prepareRouteQueries = true`. `initFirstLightEpisode`
sets that flag exactly when the roster contains a play seat, so a play episode
still performs all full-board construction at its activation barrier. An
all-input episode and the containment probe use only the still-live legacy
planner and pay zero index/query-scratch work on ticks which do not call the
new path. Tests assert both halves of that contract. The legacy planner and
its scheduler remain unchanged and live through Phase 9 as required.

For Phase 9 accounting, the route index and shared scratch should be measured
once as named play-episode activation components, alongside the existing map,
planner, and prewarm activation rows. They must not be charged as recurring
body-tick work, and the containment timing window should remain unchanged. On
the small disconnected containment map, this row is approximately 1.0 ms for
the index plus 0.02–0.05 ms for scratch; Phase 9 must use its canonical pool
and colossal maps for the real activation ratios.

### Back-to-back baseline comparison

The exact command above was run back-to-back and in isolation first at
`origin/main` `f374a18b`, then at fixed HEAD. Raw body maxima, rounded to the
nearest microsecond, were:

| wave | `origin/main` | fixed HEAD | delta |
|---|---:|---:|---:|
| trap | 5,705 | 5,567 | -138 |
| call_free_loop | 4,824 | 4,887 | +63 |
| growth_loop | 4,633 | 4,380 | -253 |
| table_growth | 4,257 | 4,340 | +83 |
| oob_emit | 4,182 | 4,190 | +8 |
| stack_recursion | 4,533 | 4,491 | -42 |
| hostile_allocator | 4,302 | 4,653 | +351 |
| init_import_phase_violation | 4,394 | 4,383 | -11 |
| retune_refusal | 4,342 | 4,406 | +64 |
| retune_absent_refusal | 4,205 | 4,102 | -103 |
| retune_import_phase_violation | 4,408 | 4,166 | -242 |
| emit_flood | 4,563 | 4,515 | -48 |
| **verdict maximum** | **5,705** | **5,567** | **-138** |

Every fixed-HEAD wave is within 351 us of the adjacent baseline, with no
systematic Phase 3 surcharge. The baseline run missed its unscaled 5,000 us
local gate (`body_pass=false`), while the fixed run's calibration scale was
1.2875 and its 5,567 us maximum passed (`body_pass=true`). This is the same
known host-noise behavior noted in the fixup request; the raw back-to-back
comparison, rather than the pass bit alone, is the regression evidence.

### Fixup qualification

All of the following completed with exit code `0` after the fix:

```sh
nim c -r -d:release -d:noSignalHandler --threads:on \
  tests/test_shell_body_route_query.nim
nim c -r -d:release -d:noSignalHandler --threads:on \
  tests/test_shell_body_nav.nim
nim c -r -d:release -d:noSignalHandler --threads:on \
  tests/test_shell_body_seat.nim
nim c -r -d:release -d:noSignalHandler --threads:on \
  tests/test_shell_first_light.nim

# Runtime-linked and runtime-stub server shapes:
nim check -d:noSignalHandler --threads:on src/ctf.nim
env -u WASMTIME_C_API nim check -d:noSignalHandler --threads:on src/ctf.nim

# Complete runtime-linked release suite:
nim c -d:release -d:noSignalHandler --threads:on tests/tests.nim
./tests/tests
```

The focused query suite passed 8/8, navigation 20/20, seat 23/23, and FIRST
LIGHT 15/15. The complete release executable finished normally with no failed
test, including the aggregate 32-seat containment row. Both server compile
shapes succeeded. `git diff --check` was empty before the checkpoint.

The pre-commit documentation audit found no repository documentation that
should change in this fixup. This is an internal activation/cost contract, and
the approved phase plan reserves the public navigation design rewrite,
GameVersion work, fixtures, and viewer rebuild for Phase 10.

## Phase boundary and freshness

Commands run before the first Phase 3 commit:

```sh
git fetch origin
git rev-parse --abbrev-ref HEAD
git rev-list --left-right --count HEAD...origin/main
git status --short
```

Exit code: `0`.

Output:

```text
james/s2-nav-rework
10      0
```

The working tree was clean and the branch was zero commits behind
`origin/main`, so no Phase 3 merge or rebase was needed. Consequently no
incoming Phase 3 merge touched `src/shell/body*.nim` or `src/shell/episode.nim`.

The required pre-commit refresh was repeated after the query commits:

```sh
git fetch origin
git rev-parse --abbrev-ref HEAD
git rev-list --left-right --count HEAD...origin/main
git status --short
git diff --check
```

Exit code: `0`.

Output excerpt:

```text
james/s2-nav-rework
12      0
 M src/shell/body_route_query.nim
 M tests/test_shell_body_route_query.nim
```

`git diff --check` produced no output. At the original Phase 3 close, the
branch was 14 ahead / 0 behind `origin/main` at
`f374a18b2cffa6b1106c5ac3d81fd248018f378d`.

## Fail-before-fix evidence

The new test module was written before the query module/API existed:

```sh
nim check -d:noSignalHandler --threads:on tests/test_shell_body_route_query.nim
```

Exit code: `1`.

Representative compiler output:

```text
cannot open file: ../src/shell/body_route_query
undeclared identifier: 'RouteSidePopCap'
undeclared identifier: 'BodyRouteRequest'
```

The later cap-fallback test also failed before explicit cap-hit instrumentation:

```sh
nim c -r -d:release -d:noSignalHandler --threads:on tests/test_shell_body_route_query.nim
```

Exit code: `1`.

Output excerpt:

```text
Check failed: route.stats.localPops == RouteLocalPopCap
route.stats.localPops was 4072
RouteLocalPopCap was 4096
[FAILED] a capped same-room candidate falls back to the bounded side graph
```

That failure exposed the distinction between exhausting the fixed record table
and reaching exactly 4,096 heap pops. `BodyRouteQueryStats` now records cap hits
directly; the gate asserts the cap event and separately asserts that neither pop
counter exceeds its bound.

## Checkpoint 1 — bounded query core and atomic seat storage

Commit:

```text
fd224c2c shell: add bounded hierarchical route queries
```

Changes:

- Added `src/shell/body_route_query.nim` with `BodyRouteRequest`, typed
  `BodyRouteFailure`, `BodyRouteDescriptor`, `BodyRouteQueryResult`, and one
  `BodyRouteQueryScratch` allocated from the immutable route index.
- Endpoint attachment scans fixed rings 0 through 4 in deterministic order.
  It consults both coarse cells and Phase 2's compact per-cell fine-anchor
  index. A goal without validator provenance returns `brfGoalAttach`.
- Same-room weighted A* and side-graph A* use fixed activation-sized storage.
  The public caps are 4,096 local pops, 4,096 side pops, 512 points in each
  copied endpoint leg, and 4,096 immutable middle edges.
- The side heuristic is the exact Q4 octile expression
  `181*min(dx,dy) + 128*(max(dx,dy)-min(dx,dy))` over 8 px cell deltas.
- Cost ordering is integer-only. Physical lengths and accumulated priorities
  are checked `int64`; danger samples use ties-to-even Q8 quantization; the
  blocked cell applies the exact x8 multiplier.
- Route candidates are reconstructed into scratch, validated move by move and
  against the exact `ValidatedGoal`, then selected by deterministic cost,
  physical length, and descriptor ordering.
- `BodyNavSystem` owns the one shared workspace. Every seat owns only fixed
  descriptor arrays plus cursor, anchor, and revision. `installRoute` rejects
  failures and stale scratch generations, and copies all bytes before changing
  the live metadata.
- Added small read-only route-index accessors needed by query traversal and
  corrected `sideAnchor` to return its pixel center rather than grid
  coordinates.

The old `BodyPlanner`, its per-seat cache/job, and the old scheduler path remain
unchanged and live beside the new query path as required through Phase 9.

## Checkpoint 2 — shard wiring

Commit:

```text
0722e0b8 test: wire hierarchical route suites into CI
```

`tests/shard_2.nim` imports both the Phase 2 route-index suite and the Phase 3
query suite. `tests/test_shard_wiring.nim` explicitly names the deliberate-red
Phase 1 liveness file as deferred until Phase 7; all other test files must be
shard-imported. This made the pre-existing tripwire honest without weakening or
inverting any of the three red laws.

## Checkpoints 3 and 4 — cap and order evidence

Commits:

```text
d39655b5 test: prove bounded route cap fallback
6b6e3b69 test: cover route query order independence
```

The cap checkpoint adds direct `localCapHits` / `sideCapHits` instrumentation
and a deterministic large-room fixture. Its weighted local candidate exhausts
fixed scratch capacity, but the query still selects and validates another
bounded candidate. The order checkpoint runs the same forward/reverse requests
in opposite workspace order and compares fingerprints, proving that scratch
reuse and seat order do not affect the result.

## Focused query qualification

Command:

```sh
nim c -r -d:release -d:noSignalHandler --threads:on tests/test_shell_body_route_query.nim
```

Exit code: `0`.

Output:

```text
[Suite] bounded hierarchical body route query
  [OK] fixed caps and octile Q4 heuristic are exact
  [OK] straight same-room route retains both exact endpoints
  [OK] fine-only validator endpoint attaches through the retained cell index
  [OK] weighted local candidate routes around a blocked cell
  [OK] a capped same-room candidate leaves bounded fallbacks alive
  [OK] side graph routes deterministically through multiple rooms
  [OK] typed disconnection and validation failures return no descriptor
  [OK] install is atomic and a failed query leaves the previous route intact
```

Together these cases cover exact endpoints, an unstandable cell center with a
fine-only goal, all retained fine anchors, straight and weighted same-room
routes, blocked-cell avoidance, cap fallback, side-graph/portal traversal,
multiple rooms, both traversal directions, repeated and permuted queries,
typed no-attach/disconnection failures, activation overflow, validation, and
transactional installation.

The native arm64 fingerprints are stable across repeated runs and opposite
request order. The plan's canonical linux/amd64 cross-architecture hash and
performance evidence remains assigned to Phase 9; this report does not claim
that later gate early.

## Regression suites

Commands:

```sh
nim c -r -d:release -d:noSignalHandler --threads:on tests/test_shell_body_route_index.nim
nim c -r -d:release -d:noSignalHandler --threads:on tests/test_shell_body_map.nim
nim c -r -d:release -d:noSignalHandler --threads:on tests/test_shell_body_nav.nim
nim c -r -d:release -d:noSignalHandler --threads:on tests/test_shell_body_seat.nim
```

Exit code for every command: `0`.

Output excerpts:

```text
[Suite] immutable shared body route index
  [OK] canonical legality matches the old planner predicate
  [OK] index validates and is deterministic
  [OK] edge width and named activation failures fail closed
  [OK] fine crossing fallback stays sparse and decodes to coarse sampling
  [OK] portal sides come from their own coarse room anchors
  [OK] coverage excludes islands that cannot contain a validated endpoint
  [OK] pixel pocket connectors cover every validator endpoint

[Suite] shell body immutable episode map
  [OK] component-by-component static fields match the pinned stencil golden
  [OK] exact validator covers sites, walls, edges, radius and components
  [OK] validator byte cap arithmetic is exact
  [OK] invalid spawn fails the activation build

[Suite] shell body seat navigation
  [OK] route and duck caches are bounded, pinned, LRU, and non-minting
  [OK] danger_schedule_k32_fixed_seed
  [OK] cold_plan_budget_256_round_robin
  [OK] follower corridor, octants, and stuck state match stencil

[Suite] shell body seat belief-lite seam
  [OK] activation references the shared episode navigation system
  [OK] seatTick follows externally-budgeted navigation to a standing goal
  [OK] seatTick order is deterministic across shared episode navigation
```

The complete outputs contained 7/7, 15/15, 20/20, and 23/23 `[OK]` rows,
respectively.

Shard wiring command:

```sh
nim c -r -d:release -d:noSignalHandler --threads:on tests/test_shard_wiring.nim
```

Exit code: `0`.

Output:

```text
[Suite] shard wiring
  [OK] every test file on disk is imported by a shard
```

## Both server compile shapes

Runtime-linked command:

```sh
export WASMTIME_C_API="$PWD/tools/runtime_spike/.deps/installed/aarch64-macos/wasmtime-c-api"
export C_INCLUDE_PATH="$WASMTIME_C_API/include"
export LIBRARY_PATH="$WASMTIME_C_API/lib"
export DYLD_LIBRARY_PATH="$WASMTIME_C_API/lib"
nim check -d:noSignalHandler --threads:on src/ctf.nim
```

Exit code: `0`.

Output excerpt:

```text
182340 lines; 3.481s; 668.781MiB peakmem
proj: .../src/ctf.nim; out: unknownOutput [SuccessX]
```

Runtime-stub command:

```sh
env -u WASMTIME_C_API nim check -d:noSignalHandler --threads:on src/ctf.nim
```

Exit code: `0`.

Output excerpt:

```text
176122 lines; 3.260s; 537.273MiB peakmem
proj: .../src/ctf.nim; out: unknownOutput [SuccessX]
```

## Full qualification

Command:

```sh
export WASMTIME_C_API="$PWD/tools/runtime_spike/.deps/installed/aarch64-macos/wasmtime-c-api"
export C_INCLUDE_PATH="$WASMTIME_C_API/include"
export LIBRARY_PATH="$WASMTIME_C_API/lib"
export DYLD_LIBRARY_PATH="$WASMTIME_C_API/lib"
nim c -d:release -d:noSignalHandler --threads:on tests/tests.nim
./tests/tests
```

Exit code for both commands: `0`.

Output excerpts:

```text
346571 lines; 19.605s; 1.925GiB peakmem
proj: .../tests/tests.nim; out: .../tests/tests [SuccessX]

[Suite] bounded hierarchical body route query
  [OK] fixed caps and octile Q4 heuristic are exact
  [OK] straight same-room route retains both exact endpoints
  [OK] fine-only validator endpoint attaches through the retained cell index
  [OK] weighted local candidate routes around a blocked cell
  [OK] a capped same-room candidate leaves bounded fallbacks alive
  [OK] side graph routes deterministically through multiple rooms
  [OK] typed disconnection and validation failures return no descriptor
  [OK] install is atomic and a failed query leaves the previous route intact

[Suite] performance
episode wall time: 0s
  [OK] 2 x 2160 ticks of sim, control and paint complete under 120 s
```

The full executable completed normally with no failed test and exit code 0.
This is the required pre-existing-shard evidence, not only a focused test run.

## Documentation and deferred artifacts

The required pre-commit documentation audit was run using the
`audit-documentation` workflow. No authoritative repository documentation is
changed in Phase 3: the new query remains alongside, rather than replacing,
the documented legacy planner, and the approved plan reserves the public
Season 2 navigation/design rewrite for Phase 10.

The repository-wide AGENTS rule ordinarily couples any `src/*.nim` change to a
viewer rebuild. The direct BRIEF is more specific for this phased task and says
that the GameVersion bump, all nine replay fixtures, and the viewer rebuild
occur **only in subtasks 10/11 after the gates pass**. Accordingly Phase 3 did
not bump GameVersion, re-record fixtures, or rebuild `static-replay-viewer`.
This is an intentional phase deferral, not omitted qualification.

## Final branch log

Command:

```sh
git log --oneline origin/main..HEAD
```

Exit code: `0`.

Output:

```text
eaa2046a shell: avoid unused route query activation
6b6e3b69 test: cover route query order independence
d39655b5 test: prove bounded route cap fallback
0722e0b8 test: wire hierarchical route suites into CI
fd224c2c shell: add bounded hierarchical route queries
71e2d2d1 shell: connect pixel-grid route pockets
dcd14d13 Merge remote-tracking branch 'origin/main' into james/s2-nav-rework
db22311b shell: scope route coverage to validator components
ebb0c525 shell: derive portals from coarse room boundaries
585ea565 shell: qualify fine route-index coverage
e8a7b75a shell: add shared body route index
24b05e1d shell: centralize body navigation legality
7e1364c0 test: compact shared-navigation route corpus
7f589dc2 test: pin shared-navigation liveness failures
f289a8ee test: freeze shared-navigation route corpus
```

After the fixup checkpoint the branch is 15 ahead / 0 behind the same
`origin/main`; the repository working tree is clean.

## Codebase friction

**3/5 — mixed.** The existing `BodyMap` legality and Phase 2 immutable-index
accessors made the query traversal testable, and the shard tripwire gave strong
regression signal. The main friction was that fine/coarse route references and
portal-side chains expose several coordinate domains with the same integer
shape; that already caused `sideAnchor` to return a grid coordinate where a
pixel point was required, and it made descriptor assembly require careful
end-to-end validation. The explicit fixed caps and nearby tests kept that
friction contained rather than forcing a broader refactor.

**Fixup codebase friction: 2/5 — mostly cooperative.** The regression bisected
to one constructor change, and the episode's existing `SlotControl` boundary
provided the correct opt-in seam. The only notable friction was that the
containment “body tick” sample deliberately includes system activation, so the
initial symptom looked like recurring tick cost until the constructor was
timed directly.
