# Season 2 Wasmtime runtime spike

Date: 2026-08-30

Contract base: `ac080b8fb06c6b529cac762f53137446436dd112`

Artifact branch: `james/s2-runtime`

## Decision

Wasmtime 48.0.1 through its C API, with Cranelift, is **confirmed as the
embedded runtime**. The five required containment cases return control to the
Nim host, per-Store memory limits and the 514-slot pool hold, every adversarial
module validates and compiles, and teardown reclaims every logical Linux pool
slot. There is no sandbox result that justifies switching to an interpreter.

The current ABI budgets are **not confirmed**. The complete runtime-half worst
tick misses its 10.400 ms hard allocation at every quota, both isolated and
under compile saturation. The serialized-artifact reservation also misses its
8x bound: the worst observed target produces 71.911x. Per the design, these are
budget and contract misses, not a runtime-selection failure. `StepFuel`,
`InitFuel`, `MaxActiveOverlays`, and host-call caps must come down, and the
reference plays must pass their harness goldens at the reduced budgets.

The timing verdicts here cover only the P0 runtime half: real Wasmtime work and
the fixed host-side cost models named below. They do not include lane A's body,
view construction, or shared world-map work and are not lane A's quarter-tick
verdict.

## Contents

- [Provenance and method](#provenance-and-method)
- [Containment and runtime configuration](#containment-and-runtime-configuration)
- [Pool capacity, instantiation, and memory](#pool-capacity-instantiation-and-memory)
- [Adversarial compilation](#adversarial-compilation)
- [Runtime-half cost model](#runtime-half-cost-model)
- [Fuel, epoch, and guard cost](#fuel-epoch-and-guard-cost)
- [Isolated and compile-saturated worst ticks](#isolated-and-compile-saturated-worst-ticks)
- [Provisional S2 game resources](#provisional-s2-game-resources)
- [Mandatory native x86 validation](#mandatory-native-x86-validation)
- [Raw evidence and validation status](#raw-evidence-and-validation-status)

## Provenance and method

The contract base is `ac080b8f`, which changes `MaxCoverRadiusPx` from 600 to
331 and `MaxCoverPostsExamined` from 512 to 1536. The rig and this report ship
together in the same commit on `james/s2-runtime`, so no unknowable self-hash
is claimed for them. The spike imports the contract constants from
`src/shell/types.nim`; all cap-sensitive rows were rebuilt and rerun against
that base. The retained 512-post rows are labeled as old-cap sensitivity data,
and the raw binary SHA-256 values below identify the measured executables.

The host was an Apple M4 Pro with 14 logical processors. Native development
rows used macOS arm64 and Nim 2.2.6. Linux rows ran sequentially under
OrbStack (Docker client 29.4.1, server 29.4.0, Linux arm64 kernel
`7.0.14-orbstack-00380-ga7e0a2dc9535`) with Nim 2.2.4. Linux arm64 execution
was native; Linux amd64 was Apple-Silicon emulation and is not a c6i/c7i
performance proxy. Each quota row records `/sys/fs/cgroup/cpu.max`; one CPU
was `100000/100000`, then `200000/100000`, `400000/100000`, and
`600000/100000`.

Pinned release assets:

| Asset | SHA-256 |
|---|---|
| Wasmtime 48.0.1 arm64 macOS C API | `9e3c636ed487a41026ff76388c5fa6f3a48ea0968408d033ed4b5e8082c20d69` |
| Wasmtime 48.0.1 amd64 macOS C API | `a5d92170718d41e4bd08173049019f0cedb318d0156365a52667d4a35ea3ca69` |
| Wasmtime 48.0.1 arm64 Linux C API | `1c521a9be661644541158b360df8f7c7ec5bc2d88d23ff4dbbc12f639247c266` |
| Wasmtime 48.0.1 amd64 Linux C API | `67683d04b416a8b91f0e607e7b4c22bd32f18f947c10b5372eb8c277ae3b883a` |
| wasi-sdk 33 arm64 macOS | `85c997a2665ead91673b5bb88b7d0df3fc8900df3bfa244f720d478187bbdc78` |
| wasi-sdk 33 amd64 macOS | `18f3f201ba9734e6a4455b0b6410690395a55e9ffa9f6f5066f66083a94b93b3` |
| wasi-sdk 33 arm64 Linux | `4f98ee738c7abb45c81a94d1461fc53cc569d1cd01498951c8184d841a027844` |
| wasi-sdk 33 amd64 Linux | `0ba8b5bfaeb2adf3f29bab5841d76cf5318ab8e1642ea195f88baba1abd47bce` |

The cold-review benchmark binary SHA-256 values were
`245e5b1bdc7ab80e32c8a79c1824d9fbae34ed2d2e16bbd64fccb2e3171d1a13`
on macOS,
`56f4482e5c05b8ba86f347bab45c473ff907d8cf0c0ab7f8f99a69727c251674`
on Linux arm64, and
`47e2e26554f2893d2ac414361a87c2c4f2b13dbabcda9f14a2d079f03a1f5b89`
on Linux amd64.

Representative commands, all run from the repository root:

```sh
tools/runtime_spike/fetch_deps.sh --verify-only
tools/runtime_spike/run.sh smoke
tools/runtime_spike/run.sh memory --instances 1,32,512 --soak 500
tools/runtime_spike/run.sh compile --repeats 3
tools/runtime_spike/run.sh tick --compile-workers 0
tools/runtime_spike/run.sh all

docker build --platform linux/arm64 \
  -f tools/runtime_spike/runtime-spike.Dockerfile \
  -t ctf-runtime-spike:arm64 .
docker build --platform linux/amd64 \
  -f tools/runtime_spike/runtime-spike.Dockerfile \
  -t ctf-runtime-spike:amd64 .

docker run --rm --platform linux/arm64 --cpus 1 \
  -e RUNTIME_SPIKE_CONTAINER_PLATFORM=OrbStack \
  -e RUNTIME_SPIKE_ENV_LABEL=linux-arm64-cpu1 \
  -e RUNTIME_SPIKE_EMULATED=false \
  -e RUNTIME_SPIKE_PLATFORM_NOTE=native-linux-arm64 \
  ctf-runtime-spike:arm64 all
```

The same `docker run` command covered arm64 and amd64 at 1, 2, 4, and 6 CPU,
with the environment label, emulation flag, and platform note changed to match
the row. Runs were sequential so quota cells did not compete with each other.
Timings use a monotonic clock. Warm-up, child-process isolation, sample count,
and the classification of real versus modeled work are stated with each table.

## Containment and runtime configuration

All four validation paths—native macOS, locked-Nix-package macOS, native Linux
arm64, and emulated Linux amd64—produced the same containment result. Every
host binary asserts `-d:noSignalHandler`; the hello module imports only
`play.emit`, has no WASI import, and exports `memory`, `play_alloc`,
`play_init`, and `play_step`.

| Case | Observed result | Fresh-instance survival proof | Class |
|---|---|---|---|
| Fuel exhaustion | trap code 11, all fuel consumed | hello emission succeeds | real Wasmtime |
| Epoch deadline | trap code 10, interrupt | hello emission succeeds | real Wasmtime + native ticker |
| Memory growth refusal | `memory.grow` returns -1, no trap | hello emission succeeds | real Store limiter |
| Out-of-bounds memory | trap code 1 with 64 KiB guard | hello emission succeeds | real Wasmtime |
| Stack overflow | trap code 0 at 256 KiB guest stack | hello emission succeeds | real Wasmtime |

The configured Engine uses Cranelift, fuel, epoch interruption with a 5 ms
ticker and four-epoch deadline, NaN canonicalization, a 256 KiB guest stack,
1 MiB per-memory maximum and reservation, 64 KiB guard, Wasmtime-owned trap
handling, and a pooling allocator with 514 core-instance and memory slots.
The final smoke line is `containment_rows=5 instruction_traps=4
limiter_refusals=1 clean_calls=5`.

Main includes the viewer-count wedge fix from PR 316. The eventual gate-3
containment run is therefore a full 32-seat run. The runtime worst tick in this
spike was already 32-seat throughout.

## Pool capacity, instantiation, and memory

These cap-independent phase-3 rows create one Engine and Module, one Store per
instance, and independently measure initial memory and fully grown-and-touched
1 MiB memory. Steady latency has 200 samples. The replacement soak drops and
recreates all 512 gameplay Stores for 500 cycles, requiring four stable RSS
samples within a 64 KiB band after each drop. The fixed return tolerance is
`max(8 MiB, 5% of the zero-live baseline)`; no allocator forcing is used.

| Environment | Cold us | Steady median/p95/p99/max us | Slots 514/515/reuse | Result | Class |
|---|---:|---:|---|---|---|
| macOS arm64 | 91.125 | 2.542 / 5.333 / 5.958 / 8.000 | pass / reject / pass | capacity PASS | real |
| Linux arm64 | 124.793 | 1.208 / 1.375 / 2.167 / 3.250 | pass / reject / pass | capacity PASS | real |
| Linux amd64 emulated | 5700.419 | 1.417 / 1.500 / 2.250 / 74.751 | pass / reject / pass | capacity PASS; timing non-normative | real, emulated |

RSS values below are KiB. Deltas are relative to the stable zero-live
baseline.

| Environment | Baseline | Initial delta 1/32/512 | Full-1-MiB delta 1/32/512 | Cycle 500 / teardown | Soak verdict | Class |
|---|---:|---:|---:|---:|---|---|
| macOS arm64 | 32,080 | 128 / 4,096 / 65,568 | 1,088 / 32,832 / 525,760 | +17,792 / +17,680 | **FAIL RSS return** | real |
| Linux arm64 | 27,520 | 128 / 4,096 / 65,536 | 1,024 / 32,768 / 524,288 | 0 / -448 | PASS | real |
| Linux amd64 emulated | 58,124 | 148 / 4,132 / 65,572 | 1,096 / 32,840 / 524,360 | -108 / -332 | PASS | real, emulated |

All three environments reclaimed and exactly reused every logical pool slot.
The macOS failure remains visible: RSS first exceeded tolerance at cycle 117
and retained about 18 MiB at teardown. Linux returning to baseline while all
three preserve exact slot accounting supports, but does not prove, the
inference that this is macOS allocator/page retention rather than a logical
pool leak. Full-memory writes produced checksum `554244096`.

## Adversarial compilation

Each shape is a distinct valid core-Wasm module of exactly 262,144 bytes.
Every row validates before `wasmtime_module_new`; each cold or warm repeat is a
fresh child process and internal parallel compilation is off. The macOS ranges
are three child processes per temperature. RSS is process-scoped validation
plus compilation peak, sampled every 1 ms; it excludes serialization.

| Shape; achieved objective | Temp | Validate ms min–max | `module_new` ms min–max | Serialized macOS | Compile RSS delta KiB min–max | Verdict | Class |
|---|---|---:|---:|---:|---:|---|---|
| enormous function; 262,116 nops | cold | 0.741–0.874 | 3.340–3.920 | 50,520 / 0.193x | 3,984–4,240 | PASS | real |
| enormous function; 262,116 nops | warm | 0.611–0.689 | 2.483–2.919 | 50,520 / 0.193x | 80–400 | PASS | real |
| maximal locals; 50,000 groups | cold | 0.434–0.524 | 5.312–7.135 | 50,520 / 0.193x | 13,424–14,400 | PASS | real |
| maximal locals; 50,000 groups | warm | 0.313–0.376 | 4.330–4.670 | 50,520 / 0.193x | 2,064–7,360 | PASS | real |
| deepest nesting; depth 87,372 | cold | 1.517–1.989 | 53.995–56.462 | 50,520 / 0.193x | 87,488–93,792 | PASS | real |
| deepest nesting; depth 87,372 | warm | 1.424–1.465 | 47.023–49.082 | 50,520 / 0.193x | 12,112–28,608 | PASS | real |
| maximal functions; 65,529 | cold | 5.604–7.089 | 1739.902–1769.902 | 18,785,384 / 71.661x | 429,296–435,040 | **FAIL ratio** | real |
| maximal functions; 65,529 | warm | 5.642–6.018 | 1757.324–1764.176 | 18,785,384 / 71.661x | 315,744–340,256 | **FAIL ratio** | real |

Reviewer verification runs add two important target and floor results using
the same Linux arm64 image family. At the native 1-CPU floor, maximal-functions
`module_new` was 1730.097 ms cold and 1724.683 ms warm, below the 2.000 s gate
on this M4-class core. A slower server core could cross the gate; native
gen-5-or-newer x86_64 validation remains mandatory.

Serialization is target-dependent. Maximal functions reached **71.911x on
arm64 Linux**, the worst observed ratio, versus 71.661x on arm64 macOS. The
other three exact-cap shapes were 0.755x on arm64 Linux versus 0.193x on arm64
macOS. Any `CompiledBytesPerRawByte` bound must hold across compilation
targets, not only on the development host.

The PM contract choice remains open:

1. Add a function-count cap below 65,529 and measure the highest admitted
   count that stays within the desired compiled reservation; or
2. retain the byte-only admission rule and raise the multiplier above the
   worst cross-target 71.911x observation, with corresponding cache and memory
   consequences.

This report does not preempt that choice or silently raise the ratified 8x
constant.

## Runtime-half cost model

The new-cap aggregate holds 512 instances resident and executes 160 distinct
full-fuel hostile steps, four full-fuel inits, 32 defaults, 32 complete
1089-by-8 fallback reflex plans, 64 maximum ladders, 32 admissions, eight
compile-result commits, 104 status entries, and 32 acknowledgments. Compilation
itself never runs on the timed tick thread.

Real work includes Wasmtime calls and traps, fuel/epoch checks, allocations,
memory range checks and copies, and callback crossings. Synthetic work models
host algorithms that do not yet exist. Mixed rows contain both. Micro rows are
diagnostic and are not summed to manufacture the directly timed aggregate.

| Component | Unit result | Classification | Assumption or boundary |
|---|---:|---|---|
| `nearest_cover`, 1,536 posts | 11.938 us/call | synthetic | 1,536 posts × 8 threats plus cold duck contrast |
| `nearest_reachable` | 0.029 us/call | synthetic | **unverified 64-tie scan assumption** |
| adversarial emit parse/canonical/schema | 61.747 us/emit | synthetic | late schema rejection |
| max-shaped valid Intent | 42.258 us/emit | synthetic | valid schema path |
| log sink | 0.293 us/call | synthetic | bounded sink |
| default play | 1.387 us/play | synthetic | engine-native model |
| `planEscape` fallback | 6.766 us/plan | synthetic | 1089 candidates × 8 hazards |
| ladder validation | 79.219 us/ladder | synthetic | 4,096 bytes, 16 entries |
| upload admission | 0.001 us/admission | synthetic | bookkeeping only |
| compile commit | 0.002 us/commit | synthetic | bookkeeping; no compilation |
| 104 statuses + 32 acks | 33.958 us/set | synthetic | serialization and copy |
| two allocations + two 32 KiB writes | 51.708 us | mixed | real guest calls/range/copy |
| one full-fuel hostile step | 519.250 us | mixed | real Wasmtime/callbacks plus host models |
| one full-fuel max-buffer init | 595.917 us | real | Wasmtime, two allocations, 69,632-byte write |

The all-cover comparison uses 20 repeats. Eight new-cap cover calls took
1911.708 us; four cover plus four reachable calls took 957.792 us, so the
aggregate correctly retains all-cover as the cost-maximizing allowed mix. The
64-entry reachable tie scan is still an unverified assumption and affects the
reachable micro row and this comparison; it does not affect the selected
all-cover aggregate.

The new exact count ledger has 1,280 cover callbacks, 15,728,640 post-threat
scores, 1,966,080 duck scores, 672 goal lookups and 43,008 assumed tie scores,
160 step traps consuming 32,000,000 fuel, four init traps consuming 4,000,000
fuel, 10,764,288 host-to-guest allocation bytes, 2,621,440 emit bytes, 163,840
log bytes, 34,848 reflex candidates, 278,784 hazard scores, 1,024 ladder
entries, and checksum `10991482733265098673`.

### Cover-price sensitivity

Changing the admitted cover density from 512 to 1,536 posts makes the pricing
effect explicit:

| Cap | `nearest_cover` | Eight cover calls | Post-threat / duck scores per complete tick | Native isolated median / max |
|---:|---:|---:|---:|---:|
| 512 posts, retained phase 5 | 3.602 us/call | 648.459 us | 5,242,880 / 655,360 | 78.024 / 81.041 ms |
| 1,536 posts, current contract | 11.938 us/call | 1911.708 us | 15,728,640 / 1,966,080 | 87.638 / 92.462 ms |

The scoring counts triple exactly; measured time is sensitive to host and run
conditions and is not forced into a linear claim.

## Fuel, epoch, and guard cost

Fuel/epoch overhead uses one identical finite compute module, a ten-call
warm-up, and 500 measured calls. Each environment/configuration summary has
five fresh child processes; each ratio pairs the same process ordinal with
fuel-off/epoch-off. The table shows ratio min/median/max from the accepted
phase-6 runs.

| Environment | Epoch only | Fuel only | Both |
|---|---:|---:|---:|
| macOS arm64 | 1.943 / 2.010 / 2.039 | 1.970 / 2.003 / 2.034 | 2.036 / 2.974 / 3.024 |
| Linux arm64, 1 CPU | 1.590 / 2.020 / 2.151 | 1.580 / 1.995 / 2.028 | 2.350 / 2.734 / 3.763 |
| Linux arm64, 2 CPU | 1.972 / 2.004 / 2.473 | 1.983 / 2.077 / 2.094 | 2.886 / 3.028 / 3.036 |
| Linux arm64, 4 CPU | 1.675 / 1.946 / 1.986 | 1.538 / 1.936 / 1.982 | 2.289 / 2.955 / 3.044 |
| Linux arm64, 6 CPU | 1.979 / 2.017 / 2.196 | 1.726 / 1.989 / 2.029 | 2.019 / 2.947 / 2.994 |
| Linux amd64 emulated, 1 CPU | 1.872 / 2.048 / 2.376 | 1.907 / 2.069 / 2.227 | 2.941 / 3.216 / 3.350 |
| Linux amd64 emulated, 2 CPU | 2.047 / 2.057 / 2.283 | 2.085 / 2.110 / 2.131 | 3.137 / 3.241 / 3.313 |
| Linux amd64 emulated, 4 CPU | 1.973 / 2.070 / 2.151 | 2.039 / 2.124 / 2.177 | 3.107 / 3.214 / 3.321 |
| Linux amd64 emulated, 6 CPU | 1.811 / 2.034 / 2.160 | 1.897 / 2.143 / 2.215 | 2.860 / 3.308 / 3.349 |

Both-on spans 2.019x–3.763x. The correct finding is a range on this small
compute workload, not that the combination “triples” execution generally.
Every child produced checksum `359541179040`.

The guard row runs an identical 1 MiB memory scan 1,000 times after ten
warm-ups. Both Engines retain the 1 MiB reservation; only the guard changes.

| Guard | Total us | Ratio | Process VSZ KiB | Class |
|---:|---:|---:|---:|---|
| 65,536 bytes | 9121.833 | 1.0000 | 412,882,544 | real Wasmtime |
| 4,294,967,296 bytes | 12436.292 | 1.3634 | 421,271,024 | real Wasmtime |

The large guard was 36.34% slower and added 8,388,480 KiB of VSZ in this run,
despite enabling guard-based bounds-check elision. The selected configuration
remains the measured 64 KiB guard. Checksum: `-1059061760`.

## Isolated and compile-saturated worst ticks

Each isolated row has 30 warm complete samples. Each saturated row starts two
real host compiler threads draining exactly 32 distinct validated 262,144-byte
modules—8,388,608 raw bytes—while complete ticks run. All rows prove both
workers overlapped, all 32 modules entered and completed, and zero failed. A
saturated sample is retained only when both worker threads are in the same
uninterrupted busy interval at the start and end of the complete tick. This
proves continuous two-worker overlap; a sample with an idle transition or a
queue drain during the tick is discarded. The table prints both counts.

These verdicts are for the runtime half only, not lane A's body/map/view work.
The fixed verdict uses the unrounded maximum and passes only at `<= 10.400 ms`.

| Environment | `cpu.max` | Mode | Retained | Discarded | Median | p95 | p99 | Max ms | Verdict |
|---|---|---|---:|---:|---:|---:|---:|---:|---|
| macOS arm64 | unavailable | isolated | 30 | — | 89.322 | 92.604 | 92.661 | 92.661 | FAIL |
| macOS arm64 | unavailable | saturated | 9 | 1 | 91.945 | 93.407 | 93.407 | 93.407 | FAIL |
| Linux arm64, 1 CPU | 100000/100000 | isolated | 30 | — | 127.810 | 135.893 | 136.524 | 136.524 | FAIL |
| Linux arm64, 1 CPU | 100000/100000 | saturated | 6 | 1 | 391.510 | 403.510 | 403.510 | 403.510 | FAIL |
| Linux arm64, 2 CPU | 200000/100000 | isolated | 30 | — | 124.747 | 132.856 | 132.976 | 132.976 | FAIL |
| Linux arm64, 2 CPU | 200000/100000 | saturated | 5 | 2 | 196.399 | 205.008 | 205.008 | 205.008 | FAIL |
| Linux arm64, 4 CPU | 400000/100000 | isolated | 30 | — | 123.099 | 130.643 | 134.594 | 134.594 | FAIL |
| Linux arm64, 4 CPU | 400000/100000 | saturated | 5 | 1 | 130.425 | 134.381 | 134.381 | 134.381 | FAIL |
| Linux arm64, 6 CPU | 600000/100000 | isolated | 30 | — | 123.886 | 128.218 | 129.401 | 129.401 | FAIL |
| Linux arm64, 6 CPU | 600000/100000 | saturated | 5 | 2 | 129.072 | 130.925 | 130.925 | 130.925 | FAIL |
| Linux amd64 emulated, 1 CPU | 100000/100000 | isolated | 30 | — | 80.526 | 84.340 | 94.834 | 94.834 | FAIL |
| Linux amd64 emulated, 1 CPU | 100000/100000 | saturated | 16 | 1 | 221.168 | 294.744 | 294.744 | 294.744 | FAIL |
| Linux amd64 emulated, 2 CPU | 200000/100000 | isolated | 30 | — | 83.305 | 85.771 | 86.482 | 86.482 | FAIL |
| Linux amd64 emulated, 2 CPU | 200000/100000 | saturated | 15 | 1 | 122.171 | 147.719 | 147.719 | 147.719 | FAIL |
| Linux amd64 emulated, 4 CPU | 400000/100000 | isolated | 30 | — | 81.742 | 85.946 | 86.056 | 86.056 | FAIL |
| Linux amd64 emulated, 4 CPU | 400000/100000 | saturated | 16 | 1 | 81.511 | 86.081 | 86.081 | 86.081 | FAIL |
| Linux amd64 emulated, 6 CPU | 600000/100000 | isolated | 30 | — | 84.627 | 86.552 | 87.565 | 87.565 | FAIL |
| Linux amd64 emulated, 6 CPU | 600000/100000 | saturated | 14 | 1 | 91.010 | 96.732 | 96.732 | 96.732 | FAIL |

Old-cap and new-cap worst-tick maxima show the direct contract sensitivity:

| Environment | Mode | 512-post max ms | 1,536-post max ms |
|---|---|---:|---:|
| macOS arm64 | isolated | 81.216 | 92.661 |
| macOS arm64 | saturated | 79.832 | 93.407 |
| Linux arm64, 1 CPU | isolated | 80.984 | 136.524 |
| Linux arm64, 1 CPU | saturated | 299.071 | 403.510 |
| Linux arm64, 2 CPU | isolated | 86.427 | 132.976 |
| Linux arm64, 2 CPU | saturated | 149.972 | 205.008 |
| Linux arm64, 4 CPU | isolated | 82.408 | 134.594 |
| Linux arm64, 4 CPU | saturated | 88.737 | 134.381 |
| Linux arm64, 6 CPU | isolated | 79.481 | 129.401 |
| Linux arm64, 6 CPU | saturated | 84.861 | 130.925 |
| Linux amd64 emulated, 1 CPU | isolated | 80.208 | 94.834 |
| Linux amd64 emulated, 1 CPU | saturated | 298.747 | 294.744 |
| Linux amd64 emulated, 2 CPU | isolated | 78.945 | 86.482 |
| Linux amd64 emulated, 2 CPU | saturated | 142.587 | 147.719 |
| Linux amd64 emulated, 4 CPU | isolated | 77.972 | 86.056 |
| Linux amd64 emulated, 4 CPU | saturated | 77.825 | 86.081 |
| Linux amd64 emulated, 6 CPU | isolated | 73.511 | 87.565 |
| Linux amd64 emulated, 6 CPU | saturated | 77.453 | 96.732 |

The retained old-cap saturated rows used the earlier queue-nonempty criterion;
the new-cap saturated rows use continuous two-worker overlap. They remain
labeled sensitivity evidence, not a controlled before/after comparison of the
saturation filter.

Native arm64 queue throughput was 12.786, 24.568, 40.836, and 35.039
modules/s at 1, 2, 4, and 6 CPU. Four CPUs are the clear compile-throughput
knee; six adds no meaningful throughput or saturated-tick improvement. That is
the evidence for the conditional resource shape below, not evidence that four
CPUs make the present budget pass.

## Provisional S2 game resources

The intended scheduler shape is a 4-CPU request and limit plus a 3 GiB memory
request and limit. The [canonical Coworld manifest schema](https://raw.githubusercontent.com/Metta-AI/coworld/main/src/coworld/coworld_manifest_schema.json)
currently permits game resource requests at `game.runnable.resources`, but its
limits object exposes only `cpu` and says that limit is currently honored only
for the player role. The concrete schema-valid game manifest recommendation is
therefore:

```yaml
game:
  runnable:
    resources:
      requests:
        cpu: "4"
        memory: 3Gi
      limits:
        cpu: "4"
```

That does **not** yet enforce the intended game ceiling: Coworld needs a small
manifest-schema and scheduler follow-up to honor the game CPU limit and add a
game memory limit. After that contract change, both requested resources should
equal their limits at 4 CPU and 3 GiB. Inventing `limits.memory` in the current
manifest would produce an invalid document, so the resource freeze is blocked
on that upstream support as well as the timing condition below.

The CPU value is **conditional**. It becomes supportable only after budget
reductions make the native 4-CPU compile-saturated maximum `<= 8.32 ms`, which
provides 20% operating headroom inside the 10.4 ms hard gate. Today that row is
134.381 ms, so this manifest must not ship against the current caps. Four CPUs
are selected over six because compilation reaches its measured knee at four;
if retuned budgets still miss 8.32 ms there, no tested native quota qualifies
and increasing the limit to six is not an evidence-backed repair for serial
tick work. The current 1-CPU default is not supported.

The memory calculation, in KiB, is deliberately explicit:

| Reserve | KiB | Basis |
|---|---:|---|
| 512 full instances | 551,808 | Linux baseline 27,520 + measured 524,288 delta |
| two compiler workers | 880,032 | 2 × largest observed process peak 440,016 |
| validator tables | 262,144 | full `MaxValidatorTableBytes` |
| current game | 524,288 | separately labeled current 512 MiB allowance |
| subtotal | 2,218,272 | before headroom |
| plus 25% | 2,772,840 | 2,707.852 MiB / 2.644 GiB |
| declarable value | 3,145,728 | rounded upward to 3 GiB |

The current 512 MiB default is therefore not supported. The intended 3 GiB
request and limit are provisional because compiler peaks were measured on macOS and lane
A's final body/view/map implementation is represented only by the current-game
allowance. Recompute this arithmetic with native server-class compiler peaks
and lane A's landed RSS before freezing the manifest.

## Mandatory native x86 validation

Before ABI budgets or resources freeze, run the exact rebuilt image on a
native gen-5-or-newer x86_64 Linux host, not Apple emulation:

```sh
docker build --platform linux/amd64 \
  -f tools/runtime_spike/runtime-spike.Dockerfile \
  -t ctf-runtime-spike:amd64 .

for cpus in 1 2 4 6; do
  docker run --rm --platform linux/amd64 --cpus "$cpus" \
    -e RUNTIME_SPIKE_CONTAINER_PLATFORM=native-linux \
    -e "RUNTIME_SPIKE_ENV_LABEL=linux-amd64-cpu$cpus" \
    -e RUNTIME_SPIKE_EMULATED=false \
    -e RUNTIME_SPIKE_PLATFORM_NOTE=native-gen5plus-linux-amd64 \
    ctf-runtime-spike:amd64 all
done

docker run --rm --platform linux/amd64 --cpus 1 \
  ctf-runtime-spike:amd64 compile --repeats 3
```

Acceptance requires every adversarial `module_new` call `<= 2.000 s`, a
cross-target artifact bound chosen by the PM, and both retuned runtime-half
maxima `<= 10.400 ms`; the selected operating quota must also keep the
saturated maximum `<= 8.32 ms`.

## Raw evidence and validation status

Cap-sensitive raw logs are outside the source tree:

- `/tmp/coworld-ctf-runtime-spike-p8-all-macos.log`
- `/tmp/coworld-ctf-runtime-spike-p8-{arm64,amd64}-cpu{1,2,4,6}.log`

Cap-independent memory and compile evidence is retained in
`/tmp/coworld-ctf-runtime-spike-memory-500-*.log` and
`/tmp/coworld-ctf-runtime-spike-compile.log`. The phase-6 logs retain the
512-post matrix and fresh-process overhead evidence. The supplemental Linux
compile values are reviewer verification runs and are attributed as such
above.

The post-report validation sweep passed its structural checks:

- `fetch_deps.sh --verify-only` verified the active macOS pair, and the two
  no-cache Docker builds verified both Linux pairs. The reviewer independently
  reconciled all eight pinned checksum entries against the official release
  digests; the unused amd64-macOS pair is therefore digest-checked but was not
  downloaded by this arm64 host sweep.
- Both Docker images rebuilt after the cold-review fixes; their binary SHA-256
  values exactly match the manifests above.
- The phase-7 native macOS, independently realized locked-Nix-package macOS,
  native Linux arm64, and emulated Linux amd64 smokes each passed all five
  containment rows, library resolution, import restriction, and clean
  post-trap calls. Native macOS and both Linux images passed smoke again after
  the cold-review ownership and saturation fixes.
- The complete macOS `all` rerun and every Linux arm64 and emulated-amd64
  `all` cell at 1/2/4/6 CPU preserved every exact ledger/queue invariant and
  both expected FAIL verdicts. These phase-8 raw files are the source of the
  timing table. Every saturated sample retained by them proves continuous
  two-worker overlap; discarded counts are explicit in each queue summary.
- The full `nix develop` shell remains blocked by the independently confirmed
  pre-existing `caos-tools` dependency failure. The Nix smoke instead used Nim
  2.2.4 from locked nixpkgs revision
  `567a49d1913ce81ac6e9582e3553dd90a955875f` and independently realized this
  flake's exact Wasmtime derivation; it did not bypass the host toolchain guard.
- Memory and adversarial compile modes were not rerun: the reviewer explicitly
  identified them as independent of the cover-cap change, so their accepted
  phase-3/4 evidence is retained. The usual smoke regression was rerun.
- Shell syntax, expected failure without `-d:noSignalHandler`, report/log
  reconciliation, whitespace, fixed-HEAD, and protected-scope checks passed.
  `git diff -- src tests Dockerfile` is empty. No native shard was added or run
  because gameplay code is untouched and the spike's executable acceptance is
  `run.sh smoke`.
