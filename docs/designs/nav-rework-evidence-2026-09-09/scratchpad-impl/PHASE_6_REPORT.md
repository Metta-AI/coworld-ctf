# Phase 6 report — stable request anchors and semantic intent

## Status

Phase 6 is complete at local commit
`73a60cc6885ff7cdc660a98ff74494c4cbedcd1a` (`shell: coalesce semantic
navigation targets`). The branch is 23 commits ahead and 0 behind
`origin/main` at `f374a18b2cffa6b1106c5ac3d81fd248018f378d`, and the worktree is
clean.

This phase adds the one allowed semantic navigation target, preserves literal
fallback and both standing-intent wire layouts, and gives the body coordinator
a stable accepted request anchor. It does not cut over from the legacy planner,
remove the old pin/slot fields, bump `GameVersion`, rebuild the viewer, or
re-record fixtures; those remain explicitly assigned to Phases 7, 10, and 11.
`ShellAbiVersion` remains `1`.

## Fail-before-fix

The first body-seat test was written against the missing contract and failed to
compile before production code changed:

```text
tests/test_shell_body_seat.nim(...): Error: undeclared field: 'targetClass'
for type types.Intent
```

The completed tests then drove the encoder, validator, binary view, resolver,
and coordinator changes together. No existing assertion or performance gate was
weakened.

## Implemented contract

### Intent and wire format

- `Intent.targetClass` is a neutral-empty string. The only non-empty value is
  `zone_safe_ground`, and it is legal only on `navigate_to`.
- A semantic navigate still requires its ordinary validated literal point. If
  semantic resolution is unavailable, that point is the fallback.
- The canonical JSON key is `target_class`, after
  `suppress_fire_freeze` and before `v`. Neutral-empty omits the key, keeping
  every existing emission byte-identical. `drop` is unchanged.
- The validator reports unknown target classes as `AbiUnknownReference`,
  rejects a class on `hold`, rejects the wrong JSON type, and still rejects a
  navigate without its literal point.
- The reserved uint32 at byte offset 12 of the 200-byte binary standing-intent
  record now carries target-class ID 0/1. The stride is unchanged and JSON and
  binary standing views agree.
- `play_sdk.emitNavigateController` accepts a static optional class and rejects
  unknown literals at compile time.

### Resolution and stable anchors

- `actFromBelief` resolves `zone_safe_ground` before its arrived test, using
  the Phase-5 damage-based safety surface and the live elapsed-zone tick and
  game generation supplied by `episode.nim`.
- Request identity is `(target class, resolved source cell)`. Cache bucket,
  overlay epoch, and provenance never participate.
- Literal requests coalesce against the last accepted goal cell. Sub-threshold
  changes do not move that anchor, so cumulative one-cell drift eventually
  crosses the two-cell threshold.
- A new route query is allowed for no route this life, an axis delta greater
  than two cells, a profile change, a stuck-8 event, a moving-goal 12-tick
  cadence, or route exhaustion. Pending requests suppress only no-route,
  stuck, and cadence retries; a changed goal/class/profile may replace them.
- Failed and cancelled queries still retain the accepted request anchor. An
  old route remains usable only while it continues to advance.
- `setStandingIntent` now validates and stores the intent without cancelling a
  route, pinning a goal, or clearing navigation. The obsolete pin and slot
  fields themselves remain until the Phase-10 deletion boundary.

The accepted Phase-5 layout-only commit remains the sole timing-motivated code
organisation change. Phase 6 made no further timing-driven reshuffle.

## Focused validation

The linked shape used the project-local Wasmtime C API:

```sh
export WASMTIME_C_API="$PWD/tools/runtime_spike/.deps/installed/aarch64-macos/wasmtime-c-api"
export C_INCLUDE_PATH="$WASMTIME_C_API/include"
export LIBRARY_PATH="$WASMTIME_C_API/lib"
export DYLD_LIBRARY_PATH="$WASMTIME_C_API/lib"
nim c -r -d:release -d:noSignalHandler --threads:on tests/test_<name>.nim
```

Final focused results:

| test | checks | result |
|---|---:|---|
| `test_shell_body_seat.nim` | 26 | pass |
| `test_shell_emit_validator.nim` | 13 | pass |
| `test_shell_view.nim` | 21 | pass |
| `test_shell_binary_view.nim` | 10 | pass |
| `test_play_sdk.nim` | 3 | pass |
| `test_shell_body_nav.nim` | 20 | pass |
| `test_shell_body_hazard.nim` | 17 | pass |
| `test_shell_body_route_query.nim` | 10 | pass |
| `test_shell_first_light_server.nim` | 15 | pass |
| `test_manifest_schema.nim` | 11 | pass |
| `test_shell_contracts.nim` | 28 | pass |

The command sweep initially named `tests/test_first_light_server.nim`, which
does not exist, and exited at the compiler's `cannot open` error. The corrected
repository path above passed 15/15. This was a command typo, not a product or
test failure; both outputs are retained in `phase6-logs/`.

The semantic-anchor tests specifically cover neutral omission, canonical order,
unknown class/type/hold rejection, literal fallback, pre-arrival resolution,
dark-overlay fallback, cumulative one-cell drift, the moving-12 cadence,
profile changes, semantic-source changes, no churn on bucket/epoch/provenance,
stuck/no-route retries, and continued advancement on an old route after a
failed replacement query.

## Server compile shapes

Commands:

```sh
nim check -d:noSignalHandler --threads:on src/ctf.nim
env -u WASMTIME_C_API nim check -d:noSignalHandler --threads:on src/ctf.nim
```

```text
runtime-linked server check: exit 0
runtime-stub server check: exit 0
```

## Full native qualification

The brief's literal command was attempted:

```sh
nim c -r -d:release tests/tests.nim
```

With no linked-runtime environment, the current import guard correctly stopped
it:

```text
src/shell/wasmtime_c.nim(15, 10) Error: WASMTIME_C_API is required
```

The repository's documented production-linked test shape then passed:

```sh
nim c -r -d:release -d:useMalloc -d:noSignalHandler --threads:on \
  tests/tests.nim
```

```text
aggregate: ok=2171 failed=0 exit=0
SHELL_CONTAINMENT_VERDICT ... calibration_probe_us=404.0000000031796
  scaled_body_gate_us=5050.000000039745
  max_body_us=4845.999999986361 body_pass=true
```

All four shard binaries compiled with the exact workflow flags:

```sh
nim c -d:release --hints:off -d:noSignalHandler --threads:on \
  -d:useMalloc -o:shard_$i tests/shard_$i.nim
```

The exact parallel execution produced:

```text
shard 1: ok=335 failed=0
shard 2: ok=803 failed=0
shard 3: ok=646 failed=1
shard 4: ok=397 failed=0
```

Shard 3's only failure was the paintball replay-summary subprocess reading seed
`0` from the shared `/tmp/paintball-test-replay/episode.bitreplay` instead of
the fixture's `679961`; the aggregate had already passed the same assertion.
Running the identical compiled shard alone immediately passed all 647 checks:

```text
shard 3 isolated: ok=647 failed=0 exit=0
```

The evidence identifies a cross-process temporary-file collision in the
parallel local run, not a Phase-6 navigation regression. The test's fixed temp
path is pre-existing and outside this phase's scope; it is recorded as a
follow-up risk rather than changed opportunistically. Shard 2's parallel
containment row passed at 4,952 us against a calibrated 5,012.5 us gate.

## Required adjacent isolated containment pair

Baseline and HEAD use the same already-built release/runtime shape and run
adjacently. Baseline is the frozen detached worktree at
`origin/main` commit `f374a18b2cffa6b1106c5ac3d81fd248018f378d`.

```sh
nim c -r -d:release -d:useMalloc -d:noSignalHandler --threads:on \
  tests/test_shell_containment.nim
```

Three consecutive adjacent samples after the shard run were:

| sample | side | calibration us | scaled body gate us | max body us | result |
|---:|---|---:|---:|---:|---|
| 1 | baseline | 427 | 5,337.5 | 5,178 | pass |
| 1 | Phase-6 HEAD | 353 | 5,000 | 4,556 | pass |
| 2 | baseline | 370 | 5,000 | 6,419 | fail |
| 2 | Phase-6 HEAD | 351 | 5,000 | 4,612 | pass |
| 3 | baseline | 356 | 5,000 | 4,633 | pass |
| 3 | Phase-6 HEAD | 353 | 5,000 | 4,638 | pass |

The required final passing pair is sample 3: HEAD is +5 us, with both below
the unchanged gate. Earlier attempts are also retained rather than hidden: the
immediate post-shard pair failed on both sides (baseline 5,445/5,062.5 us,
HEAD 6,095/5,037.5 us); the next pair passed baseline at 4,827/5,000 us and
had one HEAD hostile-allocator outlier at 5,279/5,000 us; another pair failed
both sides at 6,387 and 5,769 us. The later three-sample series then had two
fully green pairs and a baseline-only miss. Combined with the green aggregate
and shard-2 rows, the signs are mixed and there is no repeatable Phase-6-only
step on this load-sensitive arm64 gate. Canonical linux/amd64 performance
qualification remains Phase 9.

No timed window, threshold, assertion, constructor boundary, or production
layout was changed in response to these measurements.

## Documentation audit and deferrals

The required pre-commit documentation audit checked the schema and encoder,
SDK API, standing JSON/binary views, and Season-2 design surfaces against the
implemented contract. The commit updates:

- `docs/designs/strategy-play-calling-shell-2026-08-29.md`;
- `docs/designs/BR_PLAYS.md`;
- `docs/designs/play-view-binary-frame-2026-08-31.md`;
- `play_sdk/README.md`;
- `src/shell/schemas/intent.schema.json` as the machine-readable reference.

The hand-authored commentable HTML twin is already a historical snapshot rather
than a generated byte twin of the living Markdown. It was not partially edited
here; final documentation reconciliation remains Phase 11. `GameVersion`, all
nine replay fixtures, and `static-replay-viewer` remain deliberately untouched
until the Phase-10/11 cutover required by the implementation brief.

## Commit and diff

```text
73a60cc6 shell: coalesce semantic navigation targets
19 files changed, 418 insertions(+), 53 deletions(-)
```

`git diff --check origin/main...HEAD` exits zero. The phase checkpoint contains
no generated fixture, viewer, version, dependency, or unrelated formatting
churn.

Current branch history:

```text
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

## Open risks carried into Phase 7

- The legacy planner still owns actual movement. Phase 7 must connect the
  bounded route follower and deterministic local steering without changing the
  Phase-6 accepted-anchor contract.
- Phase 7 must clear every per-life navigation state, including the new
  accepted anchor, and make the three Phase-1 liveness/no-live-search laws
  green before shard wiring.
- The obsolete standing-intent pin and slot storage still exists by explicit
  instruction; Phase 10 owns its deletion alongside the legacy planner.
- The local arm64 containment gate remains visibly load-sensitive. The final
  adjacent pair and production-linked aggregate are green, while canonical
  linux/amd64 performance qualification remains Phase 9.
- CI's parallel shards can collide through
  `/tmp/paintball-test-replay/episode.bitreplay`; this pre-existing fixed-path
  test should eventually use a process-unique temp directory.
- `GameVersion`, nine replay fixtures, viewer bundle, and final authoritative
  documentation remain the Phase-10/11 boundary.

