# Phase 4 report — danger scoring and immutable zone hazard

## Status

Phase 4 and its required fixup are **complete** at commit `eb3515e1`. The route query now prices
dynamic danger, blockage, and elapsed-time zone arrival with deterministic
integer arithmetic. Zone timing enters the shell through one activation-time,
damage-only snapshot; a typed dark overlay preserves the old behavior unless
the exact `season2Shell && zoneDamageByPaint && zonePhases.len > 0` gate is
true.

The fixup restores the layer direction: `ZoneDamageSnapshot` is now a CTF type,
`body_hazard` imports it, and `zone_field.nim` has no shell import. The focused
hazard suite passes 11/11 and the route-query suite passes 10/10 in both runtime-linked
and runtime-stub compile shapes. Both server compile shapes pass, the complete
runtime-linked release suite exits zero, the Emscripten replay-viewer compile
passes, and the final isolated containment run at fixup HEAD reports
`body_pass=true`. The legacy planner remains live as
required through Phase 9.

## Fail-before-fix evidence

`tests/test_shell_body_hazard.nim` was added before its production module and
run with the phase's allocator shape:

```sh
nim c -r -d:useMalloc tests/test_shell_body_hazard.nim
```

Exit code: `1`.

```text
tests/test_shell_body_hazard.nim(...): Error: cannot open file: ../src/shell/body_hazard
```

This was a real missing-module failure, not a skipped or inverted assertion.

## Checkpoint 1 — immutable damage overlay and ownership seam

Commit:

```text
9a9a77a7 shell: install immutable zone hazard overlay
```

Changes:

- Added `src/shell/body_hazard.nim`. `ZoneDamageSnapshot` owns a copy of the
  zone field's `damage` array and source fingerprint; no render `arrival` value
  crosses the seam.
- Projected each 4 px source cell into the immutable 8 px navigation grid by
  minimum arrival. The overlay retains per-cell arrivals, room maxima, and
  per-segment minimum/maximum summaries.
- Added a separate `BodySafeCache`, re-keyed by overlay fingerprint, game
  generation, 48-tick bucket, and backward elapsed time. `ZoneNeverArrives`
  remains infinity even after elapsed time exceeds `uint16`.
- The server builds the route index and damage overlay at the play-episode
  activation barrier, after `ensureZoneArrivalField` and before navigation
  construction. The exact gate installs a ready overlay; every other shape
  installs `newDarkBodyHazardOverlay()`.
- `episode.step` receives the live value
  `sim.tickCount - sim.gameStartTick`; no elapsed tick is captured at episode
  construction.
- `newBodyNavSystem` can accept the already prepared route index, avoiding a
  second activation build.

The focused hazard suite proves damage-not-arrival ownership, dark behavior,
minimum projection, infinity semantics, room and segment summaries, exact
cell-by-cell skip equivalence, all ramp boundaries, safe-cache lifecycle, and
fingerprint mismatch rejection. The FIRST LIGHT server seam has a direct test
for the exact activation gate.

## Checkpoint 2 — directed danger memo and elapsed-arrival routing

Commit:

```text
5e6b2159 shell: price route danger and zone arrival
```

Changes:

- Added a query-local memo indexed by directed arc. Each entry is one 4-byte
  cost plus one 2-byte generation stamp. It memoizes only danger and blockage;
  elapsed-time hazard remains separate because it depends on entry ETA and
  traversal direction.
- Hazard ETA advances cell by cell at 33 Q4 units per tick with ceiling
  division. Its finite legal cost is zero for `Never`, zero at slack >= 96,
  `12 * physicalLengthQ4` at slack <= 0, and the ties-to-even linear ramp
  between those boundaries.
- Segment min/max summaries skip only cases that are provably all-zero or
  fully saturated; tests compare both shortcuts to explicit cell-by-cell
  evaluation.
- Retained one bounded earliest-physical-arrival label beside the cheapest
  label for each side. The fixed adversarial two-prefix case selects that
  alternative and reaches the safer path. The side-pop cap remains 4,096; the
  fixture used 79 total side pops and 15 alternative-label pops.
- Route assembly remains transactional: only a fully reconstructed and
  validated candidate replaces a seat's existing descriptor.

The active query reads only the prepared `BodyRouteIndex`, immutable hazard
overlay, request state, and generation-stamped scratch. It neither calls the
zone source builder nor scans a full source grid.

## Qualification

### Focused suites, both compile shapes

With the checked-in Wasmtime C API paths exported, then again with
`WASMTIME_C_API` explicitly removed:

```sh
nim c -r -d:release -d:useMalloc -d:noSignalHandler --threads:on \
  tests/test_shell_body_hazard.nim
nim c -r -d:release -d:useMalloc -d:noSignalHandler --threads:on \
  tests/test_shell_body_route_query.nim

env -u WASMTIME_C_API nim c -r -d:release -d:useMalloc \
  -d:noSignalHandler --threads:on tests/test_shell_body_hazard.nim
env -u WASMTIME_C_API nim c -r -d:release -d:useMalloc \
  -d:noSignalHandler --threads:on tests/test_shell_body_route_query.nim
```

All four commands exited `0`. Each shape reported hazard 10/10 and route query
10/10, including:

```text
[OK] zone snapshot copies damage and never reads render arrival
[OK] segment extrema skips equal cell-by-cell directional scoring
[OK] hazard ramp boundaries are exact and painted cells remain finite
[OK] safe cache rekeys on bucket generation and backward elapsed time
[OK] directed-arc danger memo is shared generation-stamped and bounded
[OK] earliest-arrival label preserves the safer two-prefix route
```

The runtime-linked FIRST LIGHT server seam also completed 15/15, including:

```text
FIRST_LIGHT enabled play_seats=1 executor=lane-a-fl-b reset=hazard-dark
FIRST_LIGHT enabled play_seats=1 executor=lane-a-fl-b reset=hazard-ready
[OK] hazard overlay follows the exact shell paint gate at activation
```

### Server entrypoint, both shapes

```sh
nim check -d:noSignalHandler --threads:on src/ctf.nim
env -u WASMTIME_C_API nim check -d:noSignalHandler --threads:on src/ctf.nim
```

Both commands exited `0`.

### Complete runtime-linked release suite

The first shorthand attempt correctly stopped at the runtime toolchain guard:

```sh
nim c -r -d:release tests/tests.nim
```

Exit code: `1`.

```text
src/shell/runtime.nim(16,10) Error: shell runtime requires -d:noSignalHandler
```

No guard was bypassed. The production compile shape was then used:

```sh
nim c -r -d:release -d:noSignalHandler --threads:on tests/tests.nim
```

Exit code: `0`.

```text
347567 lines; 30.611s; 1.906GiB peakmem; ... [SuccessX]
[OK] hazard overlay follows the exact shell paint gate at activation
[OK] a room fills door-first: arrival correlates with walk-distance from the doorway
[OK] a real 16-duo episode ticks to completion, hash-exact, with a winner or a documented draw
[OK] 2 x 2160 ticks of sim, control and paint complete under 120 s
```

The executable ran the aggregate shard imports to completion with no failed
test and process exit `0`, including the 32-seat containment row.

## Isolated containment and same-session baseline

The standing-rule command was run back-to-back and in isolation first at the
detached `origin/main` worktree (`f374a18b`), then at Phase 4 HEAD
(`5e6b2159`):

```sh
nim c -r -d:release -d:useMalloc -d:noSignalHandler --threads:on \
  tests/test_shell_containment.nim
```

The final adjacent pair produced these raw per-wave body maxima, rounded to the
nearest microsecond:

| wave | `origin/main` | Phase 4 HEAD | delta |
|---|---:|---:|---:|
| trap | 5,463 | 5,705 | +242 |
| call_free_loop | 4,716 | 4,943 | +227 |
| growth_loop | 4,548 | 4,700 | +152 |
| table_growth | 4,297 | 4,701 | +404 |
| oob_emit | 4,924 | 4,629 | -295 |
| stack_recursion | 4,490 | 4,805 | +315 |
| hostile_allocator | 4,221 | 4,537 | +316 |
| init_import_phase_violation | 4,419 | 4,596 | +177 |
| retune_refusal | 4,217 | 4,540 | +323 |
| retune_absent_refusal | 4,610 | 4,972 | +362 |
| retune_import_phase_violation | 4,239 | 4,618 | +379 |
| emit_flood | 4,215 | 4,782 | +567 |
| **verdict maximum** | **5,463** | **5,705** | **+242 (+4.4%)** |

Baseline calibration was at the 1.0 floor, so its 5,463 us trap maximum made
that invocation exit `1` with `body_pass=false`. Phase 4 HEAD measured a 511 us
calibration probe, scale 1.2775, and a 6,387.5 us scaled body gate; its 5,705 us
maximum exited `0` with `body_pass=true`. Every runtime and control gate also
passed, all 384 terminal statuses were observed, no Store leaked, and the pool
remained reusable.

Earlier adjacent attempts showed the same host sensitivity in both directions:
one baseline passed at 5,297 us while HEAD missed the 1.0-floor gate at 5,696
us; another pair had both baseline and HEAD miss at the 1.0 floor. These results
are retained here rather than hidden. The final raw comparison is the useful
regression signal: Phase 4's worst wave is 4.4% above the adjacent baseline and
ordinary HEAD waves are 4.54--4.97 ms. Activation-time overlay/index work is
outside this tick window and remains assigned to Phase 9's activation rows.

## P4 fixup

### Layer boundary

The architectural regression was pinned red before production code moved:

```sh
nim c -r -d:release -d:useMalloc -d:noSignalHandler --threads:on \
  tests/test_shell_body_hazard.nim
```

Exit code: `1`.

```text
[FAILED] zone field does not import the shell layer
readFile("src/ctf/zone_field.nim").contains("../shell/") was true
```

Checkpoint:

```text
eb3515e1 shell: restore zone hazard layer boundary
```

`ZoneDamageSnapshot` moved from `src/shell/body_hazard.nim` into
`src/ctf/zone_field.nim`; the shell consumer now imports the lower layer. The
targeted source check produces no matches:

```sh
rg -n 'shell/' src/ctf/zone_field.nim
```

Exit code: `1` because there are zero matches. The whole `src/ctf` tree still
contains pre-existing, intentional server/replay integration imports from the
shell layer, so the regression test deliberately asserts the requested
`zone_field.nim` boundary rather than claiming those unrelated imports vanished.
The Emscripten consumer also compiles:

```sh
nim check -d:emscripten replay-viewer/ctf_replay.nim
```

Exit code: `0` (`168150 lines; 1.905s; ... [SuccessX]`).

### Tick-path diagnosis

A temporary, subsequently removed diagnostic ran 36 samples for each named
candidate under the runtime-linked release/useMalloc shape:

```sh
nim c -r -d:release -d:useMalloc -d:noSignalHandler --threads:on \
  tools/p4_tick_probe.nim
```

| candidate | min | median | max | clean containment tick involvement |
|---|---:|---:|---:|---|
| `BodyNavSystem` construction, 32 seats | 2,827 us | 3,121 us | 3,890 us | construction only; P4 added no `BodyNavSeat` fields |
| clean 32-seat body tick | 3,872 us | 4,279 us | 5,156 us | measured subject |
| elapsed-tick assignment | 0.00031 us/call | 0.00032 us/call | 0.00045 us/call | absent; containment does not call `FirstLightEpisode.step` |
| directed-arc query memo path | 237 us | 258 us | 292 us | absent; containment never calls `queryBodyRoute` |
| safe-cache bucket re-key | 11 us | 13 us | 17 us | absent; containment never calls the safe cache |
| safe-cache hot check | 0.00344 us/call | 0.00357 us/call | 0.00378 us/call | absent |

The measured `BodyNavSeat` size is 13,456 bytes and `FirstLightEpisode` is 200
bytes. A source trace confirms `cleanDefaultBodyTick` constructs the normal
body system, updates beliefs, and calls `actFromBelief`; it does not construct
or step a `FirstLightEpisode`, call the new route query, or touch
`BodySafeCache`. The server calls `episode.step` only while the play episode is
enabled. Therefore ticks that never call the query have no P4 memo-stamp,
overlay/elapsed, or safe-cache work to remove. The earlier 11-of-12 slowdown
pattern was not reproduced and is superseded by the adjacent-pair evidence
below; changing the tick code would have been a speculative benchmark patch.

Three fresh adjacent baseline/HEAD pairs used the required isolated command:

```sh
nim c -r -d:release -d:useMalloc -d:noSignalHandler --threads:on \
  tests/test_shell_containment.nim
```

Per-wave HEAD-minus-`origin/main` deltas, in microseconds:

| wave | pair 1 | pair 2 | pair 3 |
|---|---:|---:|---:|
| trap | -277 | -117 | +443 |
| call_free_loop | -6 | -243 | -664 |
| growth_loop | -1,946 | +289 | -146 |
| table_growth | -314 | -340 | +305 |
| oob_emit | +40 | +172 | +60 |
| stack_recursion | +165 | +271 | +497 |
| hostile_allocator | +273 | -405 | -1,831 |
| init_import_phase_violation | -146 | +282 | +432 |
| retune_refusal | +621 | -113 | +4 |
| retune_absent_refusal | -382 | +114 | +29 |
| retune_import_phase_violation | -258 | +254 | +66 |
| emit_flood | -256 | -116 | -32 |
| **maximum** | **-1,170 (-18.0%)** | **-117 (-2.1%)** | **-1,041 (-15.2%)** |

Pair 1 was baseline `6,507 us / body_pass=false` then HEAD `5,337 us /
body_pass=true`; pair 2 was `5,512 / true` then `5,395 / true`; pair 3 was
`6,834 / false` then `5,793 / false`. Every pair has mixed per-wave signs,
which is incompatible with a systematic cost on ticks that never use the new
query. An additional final adjacent pair was baseline `5,548 / true` then HEAD
`5,619 / true` (+71 us, +1.3% maximum), again with mixed per-wave signs. The
irreducible residual is host/allocator timing noise around an unscaled 5 ms
floor, not an identified P4 tick path.

### Fixup qualification

The focused and compile matrix passed after the checkpoint:

```text
runtime-linked hazard: 11/11, exit 0
runtime-linked route query: 10/10, exit 0
runtime-linked server nim check: exit 0
runtime-stub hazard: 11/11, exit 0
runtime-stub route query: 10/10, exit 0
runtime-stub server nim check: exit 0
Emscripten replay viewer nim check: exit 0
```

The full production-shape qualification also passed:

```sh
nim c -r -d:release -d:noSignalHandler --threads:on tests/tests.nim
```

Exit code: `0` (`347573 lines; 30.756s; 1.88GiB peakmem; ... [SuccessX]`).
The aggregate run included the 11 hazard tests, 10 route-query tests, and a
green containment verdict (`max_body_us=1978.000000008251 body_pass=true`).

## Documentation and deferred artifacts

The required pre-commit documentation audits found no repository documentation
that should change in Phase 4 or its fixup. The implementation follows the already-approved
Season 2 design and phase plan, while the public navigation design rewrite is
reserved for Phase 10. The same binding boundary defers the gameplay
`GameVersion`, all nine replay fixtures, sim-sources viewer rebuild, and pool
review artifacts to Phases 10 and 11; none were changed early.

## Freshness, commits, and clean state

Before implementation and before each checkpoint, the branch was fetched and
confirmed zero commits behind `origin/main`. The closing audit was:

```sh
git fetch origin --prune
git rev-parse --abbrev-ref HEAD
git rev-parse HEAD
git rev-parse origin/main
git rev-list --left-right --count HEAD...origin/main
git status --short
git diff --check
git log --oneline origin/main..HEAD
```

Exit code: `0`.

```text
james/s2-nav-rework
eb3515e15a3b1ded14193ca4d4b3a95a7f4cd6a5
f374a18b2cffa6b1106c5ac3d81fd248018f378d
18      0
eb3515e1 shell: restore zone hazard layer boundary
5e6b2159 shell: price route danger and zone arrival
9a9a77a7 shell: install immutable zone hazard overlay
eaa2046a shell: avoid unused route query activation
...
```

`git status --short` and `git diff --check` produced no output. Nothing was
pushed, submitted, or otherwise published.

## Open risks carried into Phase 5

- The local containment timing is noisy enough that `origin/main` itself often
  misses the unscaled 5 ms floor. Phase 9 must use its canonical isolated
  measurements and report activation components separately from tick work.
- Phase 5 must expose safety hints without leaking mutable cache ownership or
  changing the damage-only overlay boundary.
- The bounded earliest-arrival alternative fixes the demonstrated two-prefix
  case. Phase 9's all-map quality artifact remains the authority for broader
  route-quality and inflation gates.
- Non-validator islands remain deliberately unrepresented, and typed goal
  attachment must continue to reject them.
