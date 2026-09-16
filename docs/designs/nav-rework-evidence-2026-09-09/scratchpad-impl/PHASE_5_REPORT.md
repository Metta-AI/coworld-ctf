# Phase 5 report — stable safety hints and resolver

## Status

Phase 5 is complete at `fc989898` on `james/s2-nav-rework`.

The shell now publishes integer-only zone-safety hints through the shared play
view. Ready overlays resolve dry ground with a legal, fixed-cap search or the
precomputed room/portal field; dark overlays omit the new JSON key and PV1
section byte-for-byte. The SDK exposes the result behind an explicit presence
flag. Phase 5 also exposes `zoneSafeTarget`; accepting the
`zone_safe_ground` Intent and giving it stable request identity remains Phase 6.

The final production-linked aggregate passed 2,164 checks with no failure.
Both server compile shapes pass. The required adjacent isolated containment
pair passed, and the final aggregate containment row passed at 4,878 us against
the 5,000 us gate.

## Fail-before-fix

The first focused safety test was written against the planned activation seam
before that seam existed. Compilation stopped with the expected constructor
failure:

```text
Error: type mismatch: got <BodyMap, int literal(1), int literal(331),
  prepareRouteQueries: bool, preparedRouteIndex: BodyRouteIndex,
  hazard: BodyHazardOverlay, safeCache: BodySafeCache>
...
unknown named parameter: hazard
```

After the first implementation, the new focused suites passed, but final
qualification exposed an attributable containment concern: the first version
put a 512-pop fixed workspace directly on `BodyNavSystem`. Even when lazily
allocated, that changed the constructor/type and produced repeatedly positive
timing deltas. That implementation was superseded rather than accepting a
focused-only result.

## Computation contract

- `BodySafetyHints` carries `int32` paint ETA, safety ETA, and pixel distance,
  an `int8` retreat octant, and the selected source cell.
- `ticksUntilPaintHere` is `-1` for `HazardNeverArrives`; otherwise it is
  `max(0, arrival - elapsedTick)`.
- A dry self cell returns `ticksToSafety = 0`, `safeDistPx = 0`, and no
  direction.
- A room whose cache says it contains dry ground runs a legal weighted cell
  search capped at 512 pops. The queue order is Q4 distance then row-major cell;
  cardinal steps cost 128 Q4 and diagonals cost 181 Q4.
- A room with no dry cell compares each room portal by walked chain distance
  plus the shared `safeDistanceQ4` field, then follows `nextSafeSide` to its dry
  source.
- Every selected source is rechecked through the same fingerprint-guarded dry
  predicate before publication.
- An unresolved/capped answer leaves safety time, distance, and direction at
  `-1`; it never expands into a full-board search.
- Public distance is ceil(Q4/16), time is ceil(Q4/33), and the first legal step
  maps to one of eight exact integer octants (32 brads per octant at the view
  boundary).

The safety search reuses the existing activation-sized
`BodyRouteQueryScratch`. Hazard/cache context is attached only when a play
roster already requested route-query preparation. Safety and route queries are
serial on the game thread. The all-input/default `BodyNavSystem` type and
constructor are source-identical to accepted Phase 4 and own no Phase-5
workspace.

## Wire and SDK contract

- JSON adds optional `nav` immediately before the existing `schema` key while
  preserving every older key, including `drop`, in its prior order.
- Dark/non-zone frames omit `nav`; the complete JSON bytes are identical to the
  pre-Phase-5 encoding.
- PV1 appends section ID 14 after all existing sections. It has count 1,
  32-byte stride, four signed i32 values, and four reserved zero i32 values.
- Dark frames omit section 14 and preserve all prior bytes.
- `SdkNav.present` distinguishes omission from a present row whose values may
  legitimately be `-1` or zero.
- The shared JSON/binary selected-row equivalence assertion includes `nav` and
  remains green.

## Tests

Focused runtime-linked release commands used the project-local Wasmtime C API:

```sh
export WASMTIME_C_API="$PWD/tools/runtime_spike/.deps/installed/aarch64-macos/wasmtime-c-api"
export C_INCLUDE_PATH="$WASMTIME_C_API/include"
export LIBRARY_PATH="$WASMTIME_C_API/lib"
export DYLD_LIBRARY_PATH="$WASMTIME_C_API/lib"
nim c -r -d:release -d:noSignalHandler --threads:on tests/test_shell_body_hazard.nim
nim c -r -d:release -d:noSignalHandler --threads:on tests/test_shell_body_route_query.nim
nim c -r -d:release -d:noSignalHandler --threads:on tests/test_shell_view.nim
nim c -r -d:release -d:noSignalHandler --threads:on tests/test_shell_binary_view.nim
nim c -r -d:release -d:noSignalHandler --threads:on tests/test_play_sdk.nim
nim c -r -d:release -d:noSignalHandler --threads:on tests/test_shell_first_light_server.nim
```

Final/focused results:

| suite | checks | failures |
|---|---:|---:|
| body hazard + safety resolver | 17 | 0 |
| bounded route query | 10 | 0 |
| JSON play view | 20 | 0 |
| PV1 binary view | 9 | 0 |
| play SDK | 2 | 0 |
| first-light server seam | 15 | 0 |

The hint suite covers dark omission, dry self beyond `uint16` elapsed time,
same-room row-major choice, all eight integer octants, portal fallback, dry
source rechecks, cache bucket stability, and the 512-pop cap. The wire tests pin
JSON order/omission, section append/stride/reserved bytes, SDK presence, and
JSON/binary selected-row equivalence.

The hazard and route-query suites also passed in the runtime-stub environment:

```sh
env -u WASMTIME_C_API nim c -r -d:release -d:noSignalHandler --threads:on \
  tests/test_shell_body_hazard.nim
env -u WASMTIME_C_API nim c -r -d:release -d:noSignalHandler --threads:on \
  tests/test_shell_body_route_query.nim
```

```text
body hazard + safety: 17 OK, 0 FAILED
body route query:      10 OK, 0 FAILED
```

## Server compile shapes

Final HEAD passed both required shapes:

```sh
nim check -d:noSignalHandler --threads:on src/ctf.nim
env -u WASMTIME_C_API nim check -d:noSignalHandler --threads:on src/ctf.nim
```

```text
runtime-linked server check: PASS
runtime-stub server check: PASS
```

## Full native qualification

The brief's literal command was attempted first:

```sh
nim c -r -d:release tests/tests.nim
```

It is stale against the current repository import graph and correctly stops at
the toolchain guard:

```text
src/shell/runtime.nim(16, 10) Error: shell runtime requires -d:noSignalHandler
```

The documented production-linked shape was then used at final HEAD:

```sh
nim c -r -d:release -d:useMalloc -d:noSignalHandler --threads:on \
  tests/tests.nim
```

```text
aggregate final: ok=2164 failed=0 exit=0
SHELL_CONTAINMENT_VERDICT ... max_body_us=4877.999999962412
  scaled_body_gate_us=5000.0 ... body_pass=true
```

The four workflow shard binaries were compiled with the exact workflow flags.
In the exact parallel local execution, shards 1, 3, and 4 passed while shard 2
had only the load-sensitive containment timing failure:

```text
shard 1: ok=335 failed=0
shard 2: ok=795 failed=1
shard 3: ok=647 failed=0
shard 4: ok=397 failed=0
```

No assertion was weakened. Rebuilding shard 2 at final HEAD and running it
without competing shards produced the final green result:

```text
shard 2 retry2: ok=796 failed=0 exit=0
SHELL_CONTAINMENT_VERDICT ... max_body_us=4919.000000001006
  scaled_body_gate_us=5000.0 ... body_pass=true
```

The parallel failure and two preceding isolated misses (5,654/5,150 us and
5,089/5,000 us) are retained in the logs; the final pass is not presented as
proof that the Mac timing gate is noiseless. Canonical linux/amd64 performance
qualification remains Phase 9.

## Required isolated containment pair

Command for each side, run adjacently with the same project-local runtime:

```sh
nim c -r -d:release -d:useMalloc -d:noSignalHandler --threads:on \
  tests/test_shell_containment.nim
```

Baseline is the frozen scratch worktree at `origin/main` commit
`f374a18b2cffa6b1106c5ac3d81fd248018f378d`; HEAD is the post-reuse Phase-5
tree. Both passed:

| side | calibration us | scaled body gate us | max body us | verdict |
|---|---:|---:|---:|---|
| origin/main baseline | 553 | 6,912.5 | 6,077 | pass |
| Phase-5 HEAD | 510 | 6,375.0 | 5,398 | pass |

Per-wave body minima (microseconds):

| wave | baseline | HEAD | delta |
|---|---:|---:|---:|
| trap | 5,511 | 5,398 | -113 |
| call_free_loop | 4,543 | 4,790 | +247 |
| growth_loop | 4,463 | 4,398 | -65 |
| table_growth | 4,235 | 4,332 | +97 |
| oob_emit | 4,092 | 4,228 | +136 |
| stack_recursion | 4,252 | 4,513 | +261 |
| hostile_allocator | 4,039 | 4,602 | +563 |
| init_import_phase_violation | 4,489 | 4,518 | +29 |
| retune_refusal | 4,049 | 4,319 | +270 |
| retune_absent_refusal | 5,679 | 4,668 | -1,011 |
| retune_import_phase_violation | 6,077 | 4,274 | -1,803 |
| emit_flood | 4,232 | 4,611 | +379 |

The signs are mixed and both sides pass. At final HEAD, a fresh standalone run
also passed at 5,548 us against a 6,975 us calibrated gate. The containment
path never creates route scratch; its `BodyNavSystem` type and constructor are
identical to Phase 4.

## Documentation audit and deferrals

The required documentation audit checked the changed schema, encoder, decoder,
SDK reference, Season-2 play surface, and binary-frame design against the final
code and tests. It updated:

- `docs/designs/BR_PLAYS.md` for the shipped hint surface and pending semantic
  Intent;
- `docs/designs/play-view-binary-frame-2026-08-31.md` for appended section 14;
- `play_sdk/README.md` for `SdkNav` discovery;
- `src/shell/schemas/play_view.schema.json` as the exact JSON reference.

The later scratch-ownership repair changed no public contract, so it required
no additional documentation edit.

Per the implementation brief, these repository-wide artifacts are deliberately
deferred to Phase 10/11 after canonical gates pass:

- GameVersion claim and changelog entry;
- all nine replay fixtures;
- `static-replay-viewer` Docker rebuild and smoke.

This is an explicit phase deferral, not an assertion that the normal `src/*.nim`
artifact rule does not apply.

## Commits, freshness, and artifacts

Phase-5 checkpoints:

```text
64be5b20 shell: publish bounded zone safety hints
c008ec82 shell: keep dark safety scratch lazy
c9823bce shell: reuse route scratch for safety hints
fc989898 shell: preserve legacy navigation code layout
```

The lazy standalone scratch checkpoint was superseded by reuse of the existing
activation-only route scratch. It remains in history as the measured logical
checkpoint that exposed why mere lazy allocation was insufficient.

Pre-commit fetches reported `behind=0`. Final source diff is 16 files, 676
insertions and 9 deletions relative to accepted Phase 4. Raw command output is
under `scratchpad/impl/phase5-logs/`, including every timing miss and retry.

## Open risks carried into Phase 6

- `zone_safe_ground` is not yet accepted in an Intent. Phase 6 owns validation,
  fallback to the required literal point, and stable semantic request identity.
- Safety and route queries share one scratch object and therefore rely on the
  existing single game-thread serialization contract. Parallel seat queries
  would require a different ownership model.
- The local arm64 containment threshold is visibly load-sensitive. The
  attributable isolated pair and final gates are green, but canonical
  linux/amd64 performance and activation/memory gates remain Phase 9.
- GameVersion, fixtures, viewer bundle, and final authoritative navigation
  documentation remain Phase 10/11 work by explicit brief instruction.
