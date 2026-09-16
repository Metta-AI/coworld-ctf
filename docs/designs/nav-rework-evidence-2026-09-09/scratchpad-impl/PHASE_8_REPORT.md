# Phase 8 report — bounded-navigation regression matrix

## Status

Phase 8 is implemented at local commits:

- `6dfcffda33c2816573a08561ed259dac87f31ef8` — merge current
  `origin/main` at `dbd80a34`, preserving its cover-hold work
- `635727c866afb036f5b2da35c7a3b49ce5d56cc9` —
  `fix: keep shell zone time at zero in lobby`
- `dafe63a734d9a9d9566d37e827d769441279b385` —
  `test: close bounded navigation regression matrix`

The final HEAD is `dafe63a734d9a9d9566d37e827d769441279b385`, 32 commits
ahead and 0 behind `origin/main` at `dbd80a34`. The worktree is clean.
Nothing was pushed, submitted, merged remotely, published, or changed in
Asana.

The final regression matrix has no functional failure. The release aggregate
and shard 2 each fail only the unchanged, host-sensitive arm64 containment
body-wall-time assertion. A single required isolated baseline/HEAD pair fails
on both revisions under the same load, so this report does not relabel the
gate green and does not attribute the local miss to Phase 8.

## Phase-boundary merge and cover-hold resolution

Before Phase 8 code changes:

```sh
git fetch origin
git rev-parse --abbrev-ref HEAD
git rev-list --left-right --count HEAD...origin/main
git merge origin/main
```

The starting Phase-7 HEAD was 29 ahead and 9 behind. The merge brought in
current main's lazy cover scorer/default-facts and call-number changes. It
conflicted in exactly:

```text
src/shell/body.nim
tests/test_shell_body_seat.nim
```

The resolution retained main's `cover_scorer` integration, fresh-threat lazy
cover default, and call-number naming while preserving Phase 7's bounded-nav
contract: standing-intent changes do not cancel, pin, or otherwise mutate
navigation work. `tests/test_shell_body_seat.nim` passed immediately after the
resolution. The merge's documentation already covered the incoming cover-hold
behavior; no extra merge-only documentation change was needed.

## Mandatory fix-up

The fix-up was completed and committed before any Phase 8 regression work.
`src/ctf/server.nim` now passes `sim.gameTicksElapsed()` to
`shellEpisode.step`, replacing the raw `sim.tickCount - sim.gameStartTick`.
Because `gameStartTick` is `-1` in the lobby, the old expression presented
`tickCount + 1` as elapsed zone time and then jumped backward to zero when the
round started.

`tests/test_shell_server_seam.nim` steps a hazard-ready shell at lobby tick 50,
warms the shared safe cache, starts the game, and steps again at the same sim
tick. It asserts elapsed zone time and the cache bucket remain zero and the
cache revision does not change across the boundary.

Exact validation:

```sh
nim c -r -d:release -d:noSignalHandler --threads:on tests/test_shell_server_seam.nim
nim check -d:noSignalHandler --threads:on src/ctf.nim
env -u WASMTIME_C_API nim c -r -d:release -d:noSignalHandler --threads:on tests/test_shell_server_seam.nim
env -u WASMTIME_C_API nim check -d:noSignalHandler --threads:on src/ctf.nim
rg -n "tickCount\\s*-\\s*.*gameStartTick|gameStartTick\\s*-\\s*.*tickCount" src/shell src/ctf/server.nim
```

Both linked and stub server-seam runs passed 19/19. Both server checks exited
0. The grep returned no matches. The required fix-up evidence was also added
to `PHASE_7_REPORT.md` under `## Fix-up required by the Phase 8 gate`.

## Public navigation diagnostic cutover

Main has completed the First Light to Shell naming transition, so the current
public type and document are `ShellNavSummary` and
`docs/designs/SHELL_DEMO.md`; Phase 8 updated those current names rather than
reintroducing the stale plan spellings.

`ShellNavSummary` now counts the complete `BodyNavState` enum and carries the
two actionable seat lists. The exact pinned output is:

```text
SHELL_NAV tick=37 idle=1 following=2 steering=3 no_progress=4 arrived=5 steering_seats=[2,7] no_progress_seats=[9]
```

The server prints this census once per second and on every plan-budget event,
including all-idle ticks. The old `pending_plans`, `stale_path`, and `no_path`
fields are gone from current source and docs. `SHELL_DEMO.md` defines each of
the five states and the two seat lists.

The fail-first compile of the new episode test failed as intended before the
implementation:

```text
undeclared field: 'counts' for type episode.ShellNavSummary
```

The final episode suite passes the exact formatter row and proves a live
activation contributes one `idle` seat.

## Regression-matrix coverage

| Required surface | Direct evidence |
|---|---|
| every typed route failure | `test_shell_body_route_query`: exhaustive enum order `none`, start attach, goal attach, disconnected, local cap, side cap, descriptor overflow, validation; all failure objects expose no descriptor; real start/disconnect/foreign-scratch/foreign-goal paths are pinned |
| danger + blocked cell + zone hazard | one composed carrier-profile route query with deterministic danger raster, live blocked cell, ready overlay, finite elapsed time, cap checks, exact validation, and blocked-cell exclusion |
| ramp, bucket, lifecycle boundaries | 17/17 hazard suite plus cache re-key/backward-time cases; server lobby/start fix-up; body death, inactive, and fresh-respawn cases |
| literal/class wire strictness | emit-validator class vocabulary and required literal fallback tests; standing-intent validation and semantic identity tests |
| canonical JSON and binary reserved fields | contract/view suites and binary-view goldens, including target-class reserved word, additive nav section, and zero reserved integers |
| SDK dark/light | SDK optional-presence test, dark frames, populated nav decode, and production wasm pipeline |
| death, respawn, inactive | episode lifecycle, prepared-seat reset, inactive query/steering assertions, and first-respawn movement tests |
| query transactionality | successful descriptor installation followed by failed and stale-scratch installs leaves fingerprint, revision, cursor, and anchor unchanged |
| all five nav states | exact `ShellNavSummary` count array and formatted `idle/following/steering/no_progress/arrived` line |
| no active legacy full-grid work | active action tick asserts no full-board plan scheduling or work-unit movement; production prepared seats have nil legacy planners |
| no per-seat map/fine-node scaling | small and arena systems have different map/fine counts but equal seat-object size; one shared scratch; all 32 seats retain the same fixed two-point route buffer |
| cover/combat/fog/strategy/drop/handoff unchanged | cover scorer and fresh-threat body tests; 13/13 combat suite; belief/fog and full player-fog suites; ladder/reference-play strategy suites; drop and handoff suites; standing payload test preserves carrier profile, hold-fire, drop, and gun handoff without touching nav work |

## Focused qualification

The linked focused matrix used the repository's Wasmtime 48.0.1 C API and the
command shape:

```sh
nim c -r -d:release -d:noSignalHandler --threads:on tests/test_<name>.nim
```

Final linked results:

| suite | passed |
|---|---:|
| `test_shell_body_route_index.nim` | 7 |
| `test_shell_body_route_query.nim` | 12 |
| `test_shell_body_hazard.nim` | 17 |
| `test_shell_body_nav.nim` | 21 |
| `test_shell_body_nav_rework.nim` | 12 |
| `test_shell_body_seat.nim` | 30 |
| `test_shell_emit_validator.nim` | 14 |
| `test_shell_view.nim` | 21 |
| `test_shell_binary_view.nim` | 10 |
| `test_play_sdk.nim` | 3 |
| `test_shell_contracts.nim` | 29 |
| `test_shell_episode.nim` | 16 |
| `test_shell_episode_ladder.nim` | 31 |
| `test_shell_server_seam.nim` | 19 |
| `test_manifest_schema.nim` | 11 |

The touched runtime-agnostic suites also passed with `WASMTIME_C_API`
explicitly unset: route query 12/12, nav rework 12/12, body seat 30/30,
episode 16/16, and server seam 19/19. The runtime-backed SDK/ladder cases have
no stub execution shape; their linked runs cover the production runtime.

Both final server compile shapes passed:

```sh
nim check -d:noSignalHandler --threads:on src/ctf.nim
env -u WASMTIME_C_API nim check -d:noSignalHandler --threads:on src/ctf.nim
```

`tools/ci/check_gameversion.sh origin/main` also passed: base and HEAD both
remain GV59. Phase 8 does not change gameplay rules; Phase 10 still owns the
collision-free version claim and fixture recording.

## Four-shard qualification

All four shards compiled with the workflow's exact linked release flags:

```sh
nim c -d:release -d:useMalloc -d:noSignalHandler --threads:on tests/shard_1.nim
nim c -d:release -d:useMalloc -d:noSignalHandler --threads:on tests/shard_2.nim
nim c -d:release -d:useMalloc -d:noSignalHandler --threads:on tests/shard_3.nim
nim c -d:release -d:useMalloc -d:noSignalHandler --threads:on tests/shard_4.nim
```

The exact parallel execution was run once, without a shard retry:

| shard | exit | passed | failed |
|---:|---:|---:|---:|
| 1 | 0 | 335 | 0 |
| 2 | 1 | 829 | 1 |
| 3 | 0 | 647 | 0 |
| 4 | 0 | 409 | 0 |

Shard 2's sole failure was the existing containment test:

```text
calibration_probe_us=416
scaled_body_gate_us=5200
max_body_us=5632
body_pass=false
runtime_pass=true
control_pass=true
```

No functional shard assertion failed. The compile shapes are both green, but
the linked execution matrix is not described as all green because the timing
assertion did fail.

## One isolated containment pair

Exactly one isolated adjacent pair was run, with no retries. The baseline was
a clean `git archive` of `origin/main` at `dbd80a34`; its dependency links were
created by the sanctioned `nimby --global sync nimby.lock`. Baseline and HEAD
used the same release/no-signal/threads/useMalloc flags and separate Nim caches.
The load-average sample before, between, and after the pair was unchanged:

```text
4.60 8.90 12.05
```

| revision | exit | calibration us | body gate us | max body us | max runtime us | max control us |
|---|---:|---:|---:|---:|---:|---:|
| `origin/main` `dbd80a34` | 1 | 409 | 5,112.5 | 6,055 | 722 | 57 |
| HEAD `dafe63a7` | 1 | 417 | 5,212.5 | 6,227 | 703 | 62 |

Both revisions fail `body_pass` under the same host load; both pass runtime,
control, host-survival, pool-reuse, and leak checks. The threshold was not
changed and the pair was not rerun. Phase 9 remains responsible for the
canonical Linux/amd64 performance gate.

## One-shot full aggregate — final Phase 8 test step

Per the Phase 8 gate, the full suite was not run during the implementation
loop. It was run exactly once, as the final Phase 8 test command:

```sh
nim c -r -d:release -d:useMalloc -d:noSignalHandler --threads:on tests/tests.nim
```

It compiled successfully and completed every suite, then exited 1 with:

```text
ok=2209 failed=1
SHELL_CONTAINMENT_VERDICT ...
calibration_probe_us=395.99999996653423
scaled_body_gate_us=5000.0
max_runtime_us=322.99999998031126 runtime_pass=true
max_body_us=5659.00000003694 body_pass=false
max_control_us=59.9999999622014 control_pass=true
host_survived=true pool_reusable=true leaks=0
```

The aggregate count is the four shard pass total minus the 11-test
`test_deprecated_modes` module intentionally imported by both shards 1 and 3.
The only failed test declaration was `full 32-seat hostile containment gate
survives every attack wave`; all later suites, including the new Phase 1
contract suite, replay verification, server seams, drop, handoff, fog, combat,
and viewer HUD tests, completed successfully. The aggregate was not retried.

## Documentation audit

The required pre-commit documentation audit found that the public diagnostic
shape had changed. `docs/designs/SHELL_DEMO.md` was updated in the same Phase 8
checkpoint with the exact `SHELL_NAV` line, state semantics, and seat-list
meaning. Searches of current source and docs found no surviving public use of
the retired `pending_plans`, `stale_path`, or `no_path` diagnostic fields.

The clock fix required no additional authoritative repo documentation because
the neighbouring `SHELL_ZONE` contract already says elapsed time remains zero
until the round starts. The cover-hold merge brought its own current docs.

## Remaining boundaries

- Phase 9: canonical Linux/amd64 route-quality, activation, memory, and 16/32
  seat timing qualification; resolve any attributable canonical failure.
- Phase 10: remove the legacy planner and remaining pin/slot state, claim a
  collision-free GameVersion, and record all nine replay fixtures.
- Phase 11: rebuild and verify the replay viewer, sim-source stamp, final full
  matrix, and documentation reconciliation.

No Phase 9 work has started.

## Final branch log

Exact final command and output:

```sh
git log --oneline origin/main..HEAD
```

```text
dafe63a7 test: close bounded navigation regression matrix
635727c8 fix: keep shell zone time at zero in lobby
6dfcffda Merge remote-tracking branch 'origin/main' into james/s2-nav-rework
2c46b6ac test: follow produced masks in shell danger probe
2eb1f278 Merge remote-tracking branch 'origin/main' into james/s2-nav-rework
2d6715da shell: move play seats on bounded routes
4a658fbb Merge remote-tracking branch 'origin/main' into james/s2-nav-rework
dba865de test: align semantic intent with shell encoder
3693f744 Merge remote-tracking branch 'origin/main' into james/s2-nav-rework
73a60cc6 shell: coalesce semantic navigation targets
fc989898 shell: preserve legacy navigation code layout
c9823bce shell: reuse route scratch for safety hints
c008ec82 shell: keep dark safety scratch lazy
64be5b20 shell: publish bounded zone safety hints
eb3515e1 shell: restore zone hazard layer boundary
5e6b2159 shell: price route danger and zone arrival
9a9a77a7 shell: install immutable zone hazard overlay
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
