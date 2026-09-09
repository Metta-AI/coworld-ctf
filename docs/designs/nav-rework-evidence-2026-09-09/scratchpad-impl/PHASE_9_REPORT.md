# Phase 9 Report — Canonical Navigation Qualification

## Verdict

**FAIL. Do not proceed to Phase 10.**

The canonical retained-memory and activation gates pass, and the native
arm64/canonical amd64 corpus route hashes match. The route-quality gate fails
overall and in 30 of 48 strata, including four missing routes. The inclusive
body-slice tick gate fails in 8 of 12 canonical rows. The corresponding native
arm64 run fails 11 of 12 rows.

The limits, corpus, percentiles, live caps, and cases were not changed. Approved
structural alternatives were tested and reverted because none closed the
quality gap and the broad alternatives made the already-failing cold tick paths
substantially slower.

## Checkpoints and freshness

- Accepted Phase 8 base: `dafe63a7`.
- Synced twice while Phase 9 was in progress:
  - `629e1c52` merged the then-current `origin/main`.
  - a later upstream advance was merged before the first Phase 9 commit.
- Harness/instrumentation checkpoint:
  `9dce21b6bd76921306b4df94f19acb02993a91b1`
  (`test: add canonical body navigation qualification gate`).
- Portable native RSS fallback checkpoint:
  `b24d8d8dfcb82534cc28dbda0d44f580f1248862`
  (`fix: make navigation RSS probe portable`).
- Final qualification commit: `b24d8d8dfcb82534cc28dbda0d44f580f1248862`.
- Final pre-commit freshness check: 35 commits ahead, 0 behind
  `origin/main`.
- Final working tree was clean for every canonical row.

Exact final branch log requested by the implementation ledger:

```text
b24d8d8d fix: make navigation RSS probe portable
9dce21b6 test: add canonical body navigation qualification gate
2ab9238e Merge remote-tracking branch 'origin/main' into james/s2-nav-rework
629e1c52 Merge remote-tracking branch 'origin/main' into james/s2-nav-rework
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

The implementation adds only qualification surfaces: exact retained-byte
counters, `ShellTickResult.bodySliceNanoseconds`, the JSON harness, its clean
Docker runner, and focused regression assertions. No cutover, legacy deletion,
GameVersion change, replay recording, or viewer rebuild was performed.

## Canonical environment

The final canonical command was:

```sh
tools/run_body_nav_gate.sh > /tmp/nav-gate-amd64-final.json \
  2> /tmp/nav-gate-amd64-final.log
```

The runner built the repository Dockerfile's `build` target and invoked:

```sh
docker buildx build --load --platform linux/amd64 --target build \
  --build-arg NimMain=tools/bench_body_nav_rework.nim \
  --build-arg 'NimFlags=-d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on' \
  --tag coworld-ctf-nav-gate .
docker run --rm --platform linux/amd64 --cpus=1 \
  ... ./ctf --all --corpus tests/fixtures/shell/nav_route_corpus.json
```

Harness metadata:

| Field | Value |
|---|---|
| commit | `b24d8d8dfcb82534cc28dbda0d44f580f1248862` |
| dirty | `false` |
| Nim | `2.2.4` |
| OS/arch | `linux/amd64` |
| image | `sha256:5dde6255eaaa8c6191a1a0e80cf8c66039ea98c6baabf07349edd24cab2932f8` |
| CPU limit | 1 |
| pool/corpus digest | `2169d51f53af12907977041223be9852e2e43781f2322273a62930cc33907b0f` |
| canonical | `true` |

Docker was OrbStack 29.4.0 on an arm64 host. Therefore the linux/amd64
quality, activation, and memory rows are canonical, while their absolute tick
latencies are required but provisional under emulation.

## Route quality — FAIL

Threshold in every row: p95 inflation <= 3.0%, max inflation <= 10.0%, with
zero missing and zero illegal routes.

- Cases: 3,072.
- Scored: 3,068.
- Missing: 4.
- Illegal: 0.
- Overall p95: 19.910469%.
- Overall max: 86.650066%.
- Failed strata: 30/48, plus the overall row.
- Route hash:
  `329c206965941b4d5278d9d7f65fe8f6a1de8821a20620d55bae8e80231e679a`.

All failing rows:

| Stratum | Count | Missing | Illegal | p95 % | Max % |
|---|---:|---:|---:|---:|---:|
| overall | 3068 | 4 | 0 | 19.910469 | 86.650066 |
| r16/default/danger/near | 64 | 0 | 0 | 27.807700 | 57.709227 |
| r16/default/danger/far | 64 | 0 | 0 | 16.710779 | 30.118454 |
| r16/default/blocked/far | 64 | 0 | 0 | 3.357926 | 7.670837 |
| r16/default/both/near | 64 | 0 | 0 | 27.807700 | 57.709227 |
| r16/default/both/far | 64 | 0 | 0 | 16.710779 | 30.118454 |
| r16/carrier/danger/near | 64 | 0 | 0 | 36.825298 | 86.650066 |
| r16/carrier/danger/far | 63 | 1 | 0 | 32.814133 | 78.952574 |
| r16/carrier/blocked/far | 64 | 0 | 0 | 3.357926 | 7.670837 |
| r16/carrier/both/near | 64 | 0 | 0 | 36.825298 | 86.650066 |
| r16/carrier/both/far | 63 | 1 | 0 | 32.814133 | 78.952574 |
| r16/hunter/danger/near | 64 | 0 | 0 | 19.910469 | 50.561984 |
| r16/hunter/danger/far | 64 | 0 | 0 | 7.412200 | 14.089981 |
| r16/hunter/blocked/far | 64 | 0 | 0 | 3.357926 | 7.670837 |
| r16/hunter/both/near | 64 | 0 | 0 | 21.534805 | 50.561984 |
| r16/hunter/both/far | 64 | 0 | 0 | 7.412200 | 14.089981 |
| r32/default/danger/near | 64 | 0 | 0 | 27.807700 | 57.709227 |
| r32/default/danger/far | 64 | 0 | 0 | 16.710779 | 30.118454 |
| r32/default/blocked/far | 64 | 0 | 0 | 3.357926 | 7.670837 |
| r32/default/both/near | 64 | 0 | 0 | 27.807700 | 57.709227 |
| r32/default/both/far | 64 | 0 | 0 | 16.710779 | 30.118454 |
| r32/carrier/danger/near | 64 | 0 | 0 | 36.825298 | 86.650066 |
| r32/carrier/danger/far | 63 | 1 | 0 | 32.814133 | 78.952574 |
| r32/carrier/blocked/far | 64 | 0 | 0 | 3.357926 | 7.670837 |
| r32/carrier/both/near | 64 | 0 | 0 | 36.825298 | 86.650066 |
| r32/carrier/both/far | 63 | 1 | 0 | 32.814133 | 78.952574 |
| r32/hunter/danger/near | 64 | 0 | 0 | 19.910469 | 50.561984 |
| r32/hunter/danger/far | 64 | 0 | 0 | 7.412200 | 14.089981 |
| r32/hunter/blocked/far | 64 | 0 | 0 | 3.357926 | 7.670837 |
| r32/hunter/both/near | 64 | 0 | 0 | 21.534805 | 50.561984 |
| r32/hunter/both/far | 64 | 0 | 0 | 7.412200 | 14.089981 |

The four missing routes are all `brfDescriptorOverflow` on
`m32-br-gen-23457`:

- `r16-s0-carrier-danger-far`
- `r16-s0-carrier-both-far`
- `r32-s0-carrier-danger-far`
- `r32-s0-carrier-both-far`

## Architecture determinism — PASS

The exact final-commit native arm64 route hash and canonical amd64 route hash
are both:

`329c206965941b4d5278d9d7f65fe8f6a1de8821a20620d55bae8e80231e679a`

The native row used macOS/arm64, the same explicit compile flags, the same
corpus digest, and no CPU limit. Its local Nim is 2.2.6; the canonical image
uses the required Nim 2.2.4.

## Activation and retained memory — PASS

All 64 published maps and the generated colossal map passed.

| Measurement | Worst row | Measured | Limit |
|---|---|---:|---:|
| Published activation ratio | `published:48:br-gen-24678` | 1.901047x | 2.0x |
| Published retained bytes | `published:29:br-gen-23312` | 1,942,861 | 16,777,216 |
| Published transient peak | `published:23:br-gen-22548` | 584,970 | reported only |
| Colossal activation ratio | `size:colossal` | 1.850716x | 3.0x |
| Colossal retained bytes | `size:colossal` | 28,449,996 | 33,554,432 |
| Colossal transient peak | `size:colossal` | 1,912,715 | reported only |

The colossal exact retained components were:

- route index: 26,709,545 bytes;
- query scratch: 872,508 bytes;
- hazard overlay: 855,274 bytes;
- safe cache: 12,669 bytes.

The separate per-seat danger+visited raster size was 3,115,008 bytes on the
colossal map. It is not included or mislabeled as shared route-query state.
The colossal post-GC RSS deltas were 398,909,440, 398,745,600, and
398,745,600 bytes and are reported separately from exact retained accounting.

For the requested architecture scaling evidence, the median of the 64
published-map BodyMap medians was 396,991,210.5 ns in canonical amd64 and
722,768,833 ns in native arm64: amd64/native = 0.549264x. The colossal
BodyMap baseline ratio was 0.667481x. These numbers compare the required
Nim 2.2.4 one-CPU emulated canonical build with the local Nim 2.2.6 native
build and should not be interpreted as a pure ISA benchmark.

## Inclusive body-slice tick time — FAIL

Each row used five warmups and 30 measured repetitions. Limits are p95 <=
4,000,000 ns and max <= 5,000,000 ns. The literal worst-degree target is
`br-gen-22010`, room 14, degree 28.

Canonical linux/amd64 values are provisional absolute latency because they ran
under arm64-host emulation:

| Seats | Scenario | Canonical p95 ns | Canonical max ns | Pass | Native p95 ns | Native max ns | Pass |
|---:|---|---:|---:|:---:|---:|---:|:---:|
| 16 | `first_goals` | 611,277,552 | 657,445,626 | no | 854,258,459 | 854,543,458 | no |
| 16 | `moving_goals` | 702,175,252 | 709,607,178 | no | 987,533,833 | 993,930,500 | no |
| 16 | `bucket_danger_rollover` | 1,673,056 | 1,736,093 | yes | 4,072,459 | 4,125,042 | no |
| 16 | `stuck_replans` | 544,735,201 | 565,418,500 | no | 717,012,458 | 719,341,083 | no |
| 16 | `worst_degree` | 1,688,889 | 1,729,427 | yes | 3,909,375 | 4,025,084 | yes |
| 16 | `cold_memo` | 610,598,597 | 612,115,706 | no | 852,234,625 | 853,492,416 | no |
| 32 | `first_goals` | 1,201,193,789 | 1,210,932,165 | no | 1,680,780,250 | 1,701,821,000 | no |
| 32 | `moving_goals` | 1,318,061,094 | 1,340,832,338 | no | 1,815,727,792 | 1,822,269,292 | no |
| 32 | `bucket_danger_rollover` | 3,419,622 | 3,427,997 | yes | 7,231,084 | 7,930,417 | no |
| 32 | `stuck_replans` | 1,099,902,781 | 1,104,332,847 | no | 1,377,942,500 | 1,385,150,042 | no |
| 32 | `worst_degree` | 3,443,413 | 3,719,784 | yes | 7,885,667 | 7,909,458 | no |
| 32 | `cold_memo` | 1,225,104,935 | 1,225,336,057 | no | 1,598,644,042 | 1,601,249,375 | no |

The failure is concentrated in first-route construction, moving-goal
replacement, stuck replanning, and forced-cold memo work. The steady
worst-degree and canonical bucket-rollover rows are within the canonical
limits, so constant per-tick bookkeeping is not the dominant problem.

## Approved fallback investigation

No fallback change was retained.

- Fine structural alternatives and bounded variants left p95 at
  18.554676–19.929885%, max at 86.468428%, and all four missing routes.
- A global structural A* alternative improved p95 to 15.744797% but left max
  86.650066% and four missing routes; weighted A* reached p95 14.784238% with
  the same max/missing failures.
- An anytime variant reached p95 19.499975%, max 86.468428%, with four missing
  routes.
- Segment/follower cost-aware sampling did not close the quality gap and
  worsened the already-catastrophic cold tick cost.
- Broad global/guide/bidirectional experiments made tick time impractical.

These results show that the current room/portal hierarchy does not represent
enough of the float oracle's weighted route choices. Tuning a local heuristic
or smoothing window cannot bridge a 19.91% p95 / 86.65% max gap. Raising caps
or removing the four overflow cases would violate the gate and was not done.

## Source qualification

Passed:

```sh
WASMTIME_C_API="$PWD/tools/runtime_spike/.deps/installed/aarch64-macos/wasmtime-c-api" \
WASI_SDK_PATH="$PWD/tools/runtime_spike/.deps/installed/aarch64-macos/wasi-sdk" \
  nim check -d:noSignalHandler --threads:on src/ctf.nim

env -u WASMTIME_C_API -u WASI_SDK_PATH \
  nim check -d:noSignalHandler --threads:on src/ctf.nim

nim c -r -d:release -d:noSignalHandler --threads:on tests/test_shell_body_nav.nim
nim c -r -d:release -d:noSignalHandler --threads:on tests/test_shell_body_nav_rework.nim
nim c -r -d:release -d:noSignalHandler --threads:on tests/test_shell_body_route_index.nim
nim c -r -d:release -d:noSignalHandler --threads:on tests/test_shell_body_route_query.nim
nim c -r -d:release -d:noSignalHandler --threads:on tests/test_shell_body_hazard.nim
nim c -r -d:release -d:noSignalHandler --threads:on tests/test_shell_episode.nim
```

The runtime dependencies were verified through
`tools/runtime_spike/fetch_deps.sh`: Wasmtime C API 48.0.1 and WASI SDK
33.0. The focused suites passed with 21, 12, 7, 13, 17, and 16 test cases
respectively (the episode suite also retains its existing socket-view skip).

Exit-code record:

| Command/group | Exit | Output excerpt |
|---|---:|---|
| final `tools/run_body_nav_gate.sh` | 1 | JSON `"pass": false`; quality and tick gates failed as detailed above |
| native `--quality` | 1 | JSON quality `"pass": false`; route hash matched canonical |
| native `--activation` | 0 | JSON activation `"pass": true`; 65/65 rows passed |
| native `--tick` | 1 | JSON tick `"pass": false`; 11/12 rows failed |
| runtime-linked `nim check ... src/ctf.nim` | 0 | `184017 lines ... [SuccessX]` |
| runtime-stub `env -u ... nim check ... src/ctf.nim` | 0 | `177935 lines ... [SuccessX]` |
| six focused test commands above | 0 | every listed suite completed with only the documented episode skip |

`tests/tests.nim` was not run, exactly as required by Phase 9.

## Documentation audit

The mandatory pre-commit documentation audit found no authoritative
user/operator behavior to update. The new measurement fields are documented at
their declarations and covered by tests; the harness is an internal
qualification tool, and this report is its authorized operational record.
Phase 10 documentation, GameVersion, fixtures, and generated viewer work remain
deferred.

## Phase boundary

Phase 9 is complete as a qualification exercise, but its acceptance gate is
red. Phase 10 must not start without a new approved design or explicit
instruction that changes the gate/architecture.
