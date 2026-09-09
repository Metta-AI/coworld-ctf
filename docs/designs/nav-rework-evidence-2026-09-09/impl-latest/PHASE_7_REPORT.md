# Phase 7 report — bounded follower, steering, and life reset

## Status

Phase 7 is implemented at local commits:

- `2d6715da5b14553881bc243a3ea6beddff23ebd9` —
  `shell: move play seats on bounded routes`
- `2c46b6ac5986183c05627ef16907f37cdd486717` —
  `test: follow produced masks in shell danger probe`

The final HEAD is `2c46b6ac5986183c05627ef16907f37cdd486717`,
29 commits ahead and 0 behind `origin/main` at
`c3f7781b1ece9c7829403a305c26ace19af8f2e5`. The worktree is clean.
Nothing was pushed, submitted, merged remotely, published, or changed in
Asana.

## Fix-up required by the Phase 8 gate

Before any Phase 8 regression work, commit
`635727c866afb036f5b2da35c7a3b49ce5d56cc9` (`fix: keep shell zone time at
zero in lobby`) replaced the shell step seam's raw
`sim.tickCount - sim.gameStartTick` with the already-established guarded
`sim.gameTicksElapsed()` helper. In the lobby `gameStartTick == -1`, so the raw
expression incorrectly sent `tickCount + 1` into route hazard pricing and then
jumped backward to zero at `startGame`.

`tests/test_shell_server_seam.nim` now steps an enabled, hazard-ready shell at
lobby tick 50 and again at the same simulation tick immediately after
`startGame`. Both steps observe elapsed zone tick zero. The test warms the
shared safe cache before the boundary and proves its bucket remains zero and
its revision is unchanged after the boundary, so start does not spuriously
re-key the cache.

The Phase 8 boundary first merged advancing `origin/main` at merge commit
`6dfcffda`. Main's lazy-cover/call-number work conflicted in
`src/shell/body.nim` and `tests/test_shell_body_seat.nim`; the resolution kept
main's lazy cover and call-number naming while preserving the Phase 7 rule
that standing-intent changes do not mutate bounded navigation work.

Focused fix-up validation used the project-local Wasmtime C API for the linked
shape and the explicit unset environment for the stub shape:

```sh
nim c -r -d:release -d:noSignalHandler --threads:on tests/test_shell_server_seam.nim
nim check -d:noSignalHandler --threads:on src/ctf.nim
env -u WASMTIME_C_API nim c -r -d:release -d:noSignalHandler --threads:on tests/test_shell_server_seam.nim
env -u WASMTIME_C_API nim check -d:noSignalHandler --threads:on src/ctf.nim
rg -n "tickCount\\s*-\\s*.*gameStartTick|gameStartTick\\s*-\\s*.*tickCount" src/shell src/ctf/server.nim
```

All four Nim commands exited 0. The server-seam suite passed 19/19 in both
compile shapes, including:

```text
[OK] shell elapsed zone clock stays zero across the lobby start boundary
```

The final grep exited 1 with no matches, confirming no raw clock subtraction
remains in the shell-facing source seams.

Phase 7 merged advancing `origin/main` three times rather than work on a stale
base: `3693f744` brought in `a3ca2fba`, `4a658fbb` brought in `c68c5d9c`, and
`2eb1f278` brought in `c3f7781b`. The conflicts in the first merge preserved
the Phase-6 semantic target and hazard/index seams inside main's Shell rename
and profiling architecture. The later two merges were clean.

This phase intentionally does not bump `GameVersion`, record the nine replay
fixtures, rebuild `static-replay-viewer`, remove the legacy planner, or change
the public navigation diagnostic record. The approved phase plan assigns
those boundaries to Phases 8, 10, and 11.

## Fail-before-fix

Before production changes, the untouched assertions in
`tests/test_shell_body_nav_rework.nim` produced the required red result:

```text
ok=1 failed=3
a new valid goal moves on its acceptance tick: movement mask was zero
an exhausted old endpoint does not stall a replacement goal: movement mask was zero
active action ticks perform no full-board route search: full-grid work scheduled
```

The assertions in those three Phase-1 laws were not changed. Their constructors
were switched to the production prepared-route shape once that path existed.
The final file passes 11/11 and is imported by shard 4.

## Production behavior

### Route ownership and masks

`initShellEpisode` prepares `BodyRouteIndex` and its one shared bounded query
scratch whenever the roster contains a play seat. Those play seats receive no
per-seat legacy `BodyPlanner`; input-only seats are inactive in the navigation
system. On every live play-seat navigate tick:

1. The coordinator applies the Phase-6 accepted-anchor rules.
2. A required route query runs synchronously through `queryBodyRoute`.
3. A successful descriptor is copied atomically into the seat.
4. `BodyRouteCursor` streams the copied start/local leg, immutable indexed
   middle segments and crossings, copied goal leg, and exact endpoint.
5. The follower chooses the farthest exact-clear point within K=6 cells of the
   current leg, always testing from the cog's real pixel position.
6. An advancing waypoint produces the movement mask. Otherwise the body uses
   deterministic local steering on that same tick.

The arena middle-segment regression exposed and fixed a real corner case: the
legacy follower's unconditional “skip every waypoint within 8 px” rule could
jump past a required 4 px corner. The new follower advances an already-reached
point, but only smooths across candidates for which the exact real-position
`segmentClear` predicate succeeds.

### Steering and diagnostics

`steeringMask` visits `NavNeighbors` in its canonical order. It rejects a
candidate that is not standable, is not pixel-clear, or occupies the live
blocked-penalty cell. The integer score is Q4 target-distance reduction minus
ties-to-even Q8 profile danger and the finite elapsed-zone hazard price; the
diagonal step uses 181 Q4 and a cardinal step 128 Q4. Only strict score
improvement replaces the winner, so the first octant wins a tie. A candidate
must physically reduce target distance even when every scored value is
negative.

`BodyNavState` is now exactly:

```text
idle, following, steering, no-progress, arrived
```

An arrived endpoint is never an advancing route. A navigate tick with no
physically progressing legal candidate emits zero movement and records
`bnsNoProgress`; a stationary seat is never labelled as walking.

### Query failure and life reset

A failed replacement query records its typed result and preserves the old
descriptor bytes. The body follows that old route only while its next
waypoint advances from the current position; once exhausted it steers toward
the accepted replacement goal instead.

Death clears every per-life descriptor buffer/count, cursor and endpoint,
accepted request/semantic identity, revision, progress/stuck/block state,
query timing/counters, desired profile/moving flag, typed query result, and
legacy per-life planner state before `setSeatActive(false)`. Shared index,
hazard overlay, safe cache, danger raster, and danger geometry persist.
Scheduled danger skips inactive seats; query and steering entry points assert
if one is used. Respawn reactivates an empty navigation life and may query and
move on its first valid navigate tick.

## Which path produces masks

| context | movement-mask producer |
|---|---|
| production episode with any `control: play` seat | new synchronous bounded query, descriptor follower, and local steering |
| `test_shell_body_nav_rework`, prepared-route cases | new production path |
| `test_shell_episode` and `test_shell_episode_ladder` | new production episode path |
| new inactive-seat case in `test_shell_body_seat` | prepared-route lifecycle path |
| pre-existing `test_shell_body_nav` and legacy body-seat planner cases | legacy planner/follower, deliberately still compiled through Phase 10 |
| replay playback | recorded input masks; neither planner is rerun |

No production play-seat mask is produced by the legacy planner after this
phase.

## Shard selection measured before wiring

All four post-merge shards were compiled with the workflow flags and run in
parallel under `/usr/bin/time -p` before importing the formerly standalone
file:

| shard | real seconds | checks | result |
|---:|---:|---:|---|
| 1 | 184.72 | 335 | pass |
| 2 | 198.70 | 812 | 811 pass, containment-only fail |
| 3 | 168.24 | 647 | pass |
| 4 | 79.68 | 397 | pass |

Shard 4 was therefore the measured fastest, not the plan's earlier expected
shard 2, and now imports `test_shell_body_nav_rework`.

## Focused validation

The linked shape used the project-local Wasmtime C API and this command shape:

```sh
nim c -r -d:release -d:noSignalHandler --threads:on tests/test_<name>.nim
```

Final focused results before the last upstream replay-only merge were:

| test | checks | result |
|---|---:|---|
| `test_shell_body_nav_rework.nim` | 11 | pass |
| `test_shell_body_seat.nim` | 27 | pass |
| `test_shell_body_nav.nim` | 20 | pass |
| `test_shell_episode.nim` | 15 | pass |
| `test_shell_episode_ladder.nim` | 28 | pass |

The later full aggregate and shard run used the final HEAD and passed every
functional assertion in these files.

The first ladder wrapper rerun used `status` as a zsh variable, which is
read-only, and the wrapper exited after the test had run. The corrected wrapper
used `exit_code`; the test passed 28/28. Both facts are retained rather than
silently omitted.

## Server compile shapes

Both final-HEAD shapes passed:

```sh
nim check -d:noSignalHandler --threads:on src/ctf.nim
env -u WASMTIME_C_API nim check -d:noSignalHandler --threads:on src/ctf.nim
```

```text
runtime-linked exit=0
runtime-stub exit=0
```

## FIRST LIGHT proof

The final current-base command was:

```sh
SHELL_DEMO_MEASURE_ONLY=1 ./tools/run_shell_demo.sh
```

It used the actual upload/compile/call/ladder/body/mask path and exited zero:

```text
SHELL_INVENTORY wasmtime=true uploads=true calls=true stores=true ladder=true
SHELL_INSTALL tick=1 seat=0 rule=edge_ride provenance=entry:edge_ride ...
SHELL_MASK_SUMMARY tick=1 seats=32 moving=32 aiming=0
SHELL_DANGER ... threat_path_danger=1548.000 repriced=true verdict=PASS
SHELL_REFLEX_RUNTIME ... p95_us=2307.290 max_us=2381.253 ... verdict=PASS
SHELL_BODY ... p95_us=3.667 max_us=4.084 ... verdict=PASS
SHELL_RUNTIME ... p95_us=260.208 max_us=267.041 ... verdict=PASS
```

This is direct evidence that a cog which accepts `edge_ride`'s navigate order
on tick 1 moves on tick 1; all 32 seats in the probe did so.

The probe initially failed its later danger row because it still scored the
retired planner's now-empty `activePath`. Commit `2c46b6ac` makes that proof
score the positions generated by production masks, matching the episode
regression. The rerun above passes.

## Full native and shard qualification

The final aggregate used the production-linked workflow shape:

```sh
nim c -r -d:release -d:useMalloc -d:noSignalHandler --threads:on tests/tests.nim
```

Result:

```text
ok=2193 failed=1 exit=1
```

All 2,193 functional checks passed. The sole failure was the unchanged,
host-sensitive containment max:

```text
calibration_probe_us=398.0 scaled_body_gate_us=5000.0
max_runtime_us=2883.0 runtime_pass=true
max_body_us=9698.0 body_pass=false
max_control_us=114.0 control_pass=true
```

All four shards compiled with the exact workflow flags and ran in parallel:

| shard | real seconds | checks | result |
|---:|---:|---:|---|
| 1 | 198.60 | 335 | pass |
| 2 | 220.37 | 815 | 814 pass, containment-only fail |
| 3 | 181.66 | 647 | pass |
| 4 | 85.56 | 408 | pass, including all 11 new-route laws |

Shard 2's only failure was the same containment row (`max_body_us=9772.0`,
gate `5000.0`). No functional assertion failed in the aggregate or any shard.
The suite is therefore not described as wholly green.

## Required isolated containment pair

The baseline was a clean `git archive` of current `origin/main` commit
`c3f7781b`; its ignored `nim.cfg` was generated with the sanctioned
`nimby --global sync nimby.lock`. Baseline and HEAD were compiled with the same
release/runtime/useMalloc flags and separate Nim caches, then run adjacently.

The first baseline compile correctly stopped at missing Nimby paths before the
sync. The next simultaneous compile reached the linker but exposed a shared
Nim-cache collision because both revisions had the same test module name;
separate explicit cache directories fixed it. These were environment failures,
not test outcomes.

Ten valid adjacent samples all missed the unchanged local arm64 max on both
sides. Representative rows:

| sample | baseline calibration/gate/max us | HEAD calibration/gate/max us |
|---:|---:|---:|
| 1 | 414 / 5,175 / 6,620 | 407 / 5,087.5 / 6,663 |
| 3 | 412 / 5,150 / 9,955 | 417 / 5,212.5 / 7,621 |
| 9 | 396 / 5,000 / 6,365 | 405 / 5,062.5 / 6,361 |
| 10 | 459 / 5,737.5 / 5,882 | 421 / 5,262.5 / 6,003 |

The closest pair has HEAD 4 us faster than baseline; the full series has mixed
signs and shows no attributable P7-only step. This does not convert the failed
gate into a pass: current main and HEAD both fail locally. The threshold was
not changed, the test was not weakened, and all logs are retained. The proposed
resolution is the already-planned Phase-9 canonical linux/amd64 Docker run on
an idle, production-equivalent CPU; if HEAD alone fails there against a green
baseline, Phase 9 must optimize the measured path before proceeding.

## Documentation audit

The required pre-commit documentation audit found a real behavior change. The
authoritative Season 2 design now states that active play seats use the shared
immutable route index, bounded descriptors, K=6 exact-clear follower, same-tick
steering, and death reset, while the legacy planner is test-only until cleanup.
`BR_PLAYS.md`'s shipped surface records the same movement owner. No diagnostic
documentation was changed because Phase 8 owns the public `SHELL_NAV` schema
cutover. The shell-probe-only checkpoint required no additional documentation
change.

## Remaining boundaries

- Phase 8: public navigation summary/schema, server diagnostics, and expanded
  regression matrix.
- Phase 9: canonical Linux/amd64 all-map quality, activation, memory, and
  16/32-seat timing gates, including resolution of any attributable failure.
- Phase 10: remove the legacy full-grid planner and its pin/slot state, claim a
  collision-free `GameVersion`, and record all nine fixtures.
- Phase 11: rebuild/verify the viewer, sim-source stamp, full final matrix, and
  documentation reconciliation.

No Phase-8 work has started.
