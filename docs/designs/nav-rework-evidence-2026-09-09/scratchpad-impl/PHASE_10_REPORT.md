# Phase 10.0 report: pop-budget ruling packet

Status: **MEASUREMENT COMPLETE; PRODUCTION NOT STARTED.**

## Verdict

Recommend **B = 16,384 pops per episode tick** for the production integration
trial. It is the largest requested candidate whose worst native combined
search-plus-steering slice p95 stays at or below approximately 3.2 ms:

| B | worst row | combined nav p95 | combined nav max | ruling |
|---:|---|---:|---:|---|
| 12,288 | 16-seat stuck replans | 2.625792 ms | 3.163709 ms | control passes |
| 16,384 | 32-seat stuck replans | 3.164042 ms | 3.486500 ms | recommend; p95 passes by 0.035958 ms |
| 20,480 | 16-seat stuck replans | 3.664792 ms | 4.368292 ms | reject; p95 is 0.464792 ms over screen |

The recommendation applies only to the P10.0 navigation-slice screen. The
16,384 maximum is above 3.2 ms, although the selection rule in `PLAN_P10.md`
uses p95 and requires the maximum to be reported. More importantly, the
additive whole-body estimate below does not pass the canonical 4/5 ms gate.
James still must rule before any production change.

## Method

The measurement-only harness is
`tools/investigate_body_nav_p10.nim`. It uses the accepted R3.3 mixed graph,
exact width-1 Q4 Dial queue, one resumable workspace, stable SJF admission, and
production `steeringMask` for every waiting seat. Its SJF key is octile Q4 then
seat number. Reversing request arrival order is not normalized before admission,
so the caller-order determinism check is real rather than a pre-sorted input.

The matrix is:

`{12,288; 16,384; 20,480} x {16; 32 seats} x
{first-goal burst; moving goal every 12 ticks; forced stuck replans}`.

Each of the 18 configurations ran as a separate executable process, sequentially
with no parallel benchmark jobs. Within that process the complete deterministic
scenario repeats until exactly 120 active-tick timing samples exist. The last
repeat is truncated at the 120th sample. Route ticks and lifecycle counts below
come from one complete scenario; timing percentiles use all 120 samples.
Each process also runs an untimed identical repeat and an untimed reversed-
arrival repeat. Assertions require identical schedule fingerprint, route
fingerprint, and completion order.

The timed combined slice begins before request issue/replacement and ends after
the waiting-seat steering pass. `search` and `steering` are also timed separately.
Graph/map/index activation is outside the slice.

Environment:

- Native macOS 15.5 arm64, Darwin 24.5.0.
- Nim 2.2.6, release, ORC, threads on, signal handler disabled.
- Branch `james/s2-nav-rework`, measured source HEAD
  `e7cda62bbfd5739a7d1dbe4f961ec8688a1ee404`, 71 ahead / 0 behind the local
  `origin/main` ref at measurement start.
- Harness SHA-256
  `421c5e66d710a82408760d74d5d367274c50fc6247005d062e9afd3a3bc2a889`.
- Executable SHA-256
  `b05bad8af8482f4bb3fc55b5628efffaddeae70b50d444642ce00f58595ba048`.
- Corpus SHA-256
  `aefb19ecf5159288f78c041429c81523b02c641f0e186cdd2de37958db871de7`.

These are native development measurements, not the linux/amd64 Phase 9
canonical gate.

## All 18 scheduler rows

`nav` is combined search plus steering. `search` and `steer` show p95/max.
Route latency is p50/p95/max ticks. Times are milliseconds.

| B | seats | scenario | nav p50/p95/max | search p95/max | steer p95/max | route ticks p50/p95/max |
|---:|---:|---|---:|---:|---:|---:|
| 12,288 | 16 | first goal | 1.483125 / 1.724833 / 1.859166 | 1.722750 / 1.854708 | 0.004167 / 0.007459 | 3 / 46 / 46 |
| 12,288 | 16 | moving goal | 1.533167 / 1.808833 / 2.256833 | 1.805542 / 2.252958 | 0.007375 / 0.008792 | 2 / 35 / 46 |
| 12,288 | 16 | stuck replans | 2.060417 / 2.625792 / 3.163709 | 2.624417 / 3.160084 | 0.006959 / 0.012041 | 8 / 27 / 29 |
| 12,288 | 32 | first goal | 1.478167 / 1.767583 / 1.933250 | 1.762333 / 1.925542 | 0.008125 / 0.018792 | 5 / 86 / 91 |
| 12,288 | 32 | moving goal | 1.533209 / 2.037500 / 2.298417 | 2.029375 / 2.290084 | 0.010500 / 0.020875 | 4 / 70 / 91 |
| 12,288 | 32 | stuck replans | 2.087791 / 2.531666 / 2.759417 | 2.515917 / 2.748917 | 0.012875 / 0.024500 | 18 / 53 / 57 |
| 16,384 | 16 | first goal | 1.992166 / 2.472334 / 3.020875 | 2.467084 / 3.013041 | 0.006667 / 0.009542 | 2 / 35 / 35 |
| 16,384 | 16 | moving goal | 1.965292 / 2.419833 / 2.663250 | 2.419083 / 2.662042 | 0.005792 / 0.009666 | 2 / 26 / 35 |
| 16,384 | 16 | stuck replans | 2.854917 / 3.045209 / 3.221125 | 3.039084 / 3.211292 | 0.006459 / 0.010667 | 7 / 20 / 22 |
| 16,384 | 32 | first goal | 1.989000 / 2.313417 / 2.517084 | 2.306958 / 2.511000 | 0.007750 / 0.022042 | 4 / 65 / 69 |
| 16,384 | 32 | moving goal | 1.997958 / 2.656208 / 3.226250 | 2.649958 / 3.217875 | 0.010375 / 0.024708 | 3 / 52 / 69 |
| 16,384 | 32 | stuck replans | 2.889916 / 3.164042 / 3.486500 | 3.151917 / 3.476208 | 0.014167 / 0.019042 | 11 / 40 / 43 |
| 20,480 | 16 | first goal | 2.559625 / 3.051958 / 3.573917 | 3.048708 / 3.571292 | 0.004792 / 0.009667 | 2 / 28 / 28 |
| 20,480 | 16 | moving goal | 2.680042 / 3.058000 / 3.296333 | 3.054584 / 3.291333 | 0.008208 / 0.009791 | 2 / 21 / 28 |
| 20,480 | 16 | stuck replans | 3.532541 / 3.664792 / 4.368292 | 3.652542 / 4.363875 | 0.008750 / 0.012666 | 6 / 16 / 17 |
| 20,480 | 32 | first goal | 2.680208 / 3.391208 / 3.749083 | 3.383333 / 3.744708 | 0.010166 / 0.030542 | 3 / 52 / 55 |
| 20,480 | 32 | moving goal | 2.591834 / 3.045125 / 3.620167 | 3.035458 / 3.612167 | 0.015041 / 0.027334 | 2 / 42 / 55 |
| 20,480 | 32 | stuck replans | 3.568459 / 3.655208 / 4.073125 | 3.639584 / 4.057666 | 0.016375 / 0.029083 | 8 / 32 / 34 |

At 16,384, relative to the 12,288 control, the route tail improves:

- 16 seats: first goal 46 -> 35 ticks p95, moving goal 35 -> 26, stuck
  replans 27 -> 20.
- 32 seats: first goal 86 -> 65 ticks p95, moving goal 70 -> 52, stuck
  replans 53 -> 40.

At 20,480 the p95 tails improve again to 28/21/16 ticks at 16 seats and
52/42/32 at 32 seats, but its worst nav p95 is 3.664792 ms. The latency benefit
does not justify violating the approximately 3.2 ms selection screen.

## Work, waiting, quality, and determinism

The raw TSV contains per-row queue/settled pops, completions, restarts,
superseded requests, oldest age, maximum consecutive wait, steering calls,
inflation, fingerprints, and PIDs. Decision-relevant summaries:

- All 18 rows completed with zero failed routes and zero illegal routes.
- Every row passed the identical-repeat and reversed-arrival assertions.
- All 18 recorded PIDs are distinct.
- The two selected scheduler cases per roster are exact against their stored
  float-oracle cost to floating-point noise: maximum observed inflation is
  `8.881784197001252e-14%`.
- First-goal route fingerprints are identical across all three budgets for a
  given roster. Moving/stuck aggregate fingerprints differ across budgets
  because a larger budget finishes more intermediate requests before the next
  replacement wave; every completed route remains legal and exact.
- At 16,384, the worst oldest-request age is 68 ticks and the worst consecutive
  wait is 68 ticks for first/moving goals; forced stuck replacement can keep a
  seat continuously pending for 66 ticks while its newest request age is 42.
- The timed steering pass is small: across the 16,384 rows its worst p95/max is
  0.014167/0.024708 ms and measured cost is 390--473 ns per call. It is included
  in the combined nav slice used for selection.
- Danger-generation restarts are exactly two on moving-goal rows and one on
  stuck rows. Goal-change restarts are three on each moving/stuck row. Pending
  supersessions are preserved in `rows.tsv`; none is reported as a failure.

This is a scheduler-case quality check, not a substitute for the full 3,072-case
production-path corpus rerun required after integration.

## Additive inclusive body-slice estimate

The estimate adds, by roster, each budget's worst nav p95 and worst nav max to
the Phase 9 `worst_degree` whole-body row. That Phase 9 row contains the steady
body/navigation bookkeeping but no cold full-board query. Adding the complete
row is conservative and double-counts the small existing navigation work. It
is still useful as a rejection screen; it is not an integrated measurement.

Same-host native addition:

| B | seats | P10 nav p95/max | Phase 9 native worst-degree p95/max | additive p95/max | 4/5 ms gate |
|---:|---:|---:|---:|---:|:---:|
| 12,288 | 16 | 2.625792 / 3.163709 | 3.909375 / 4.025084 | 6.535167 / 7.188793 | fail |
| 12,288 | 32 | 2.531666 / 2.759417 | 7.885667 / 7.909458 | 10.417333 / 10.668875 | fail |
| 16,384 | 16 | 3.045209 / 3.221125 | 3.909375 / 4.025084 | 6.954584 / 7.246209 | fail |
| 16,384 | 32 | 3.164042 / 3.486500 | 7.885667 / 7.909458 | 11.049709 / 11.395958 | fail |
| 20,480 | 16 | 3.664792 / 4.368292 | 3.909375 / 4.025084 | 7.574167 / 8.393376 | fail |
| 20,480 | 32 | 3.655208 / 4.073125 | 7.885667 / 7.909458 | 11.540875 / 11.982583 | fail |

For context only, adding the native P10 nav numbers to Phase 9's provisional
linux/amd64-under-emulation worst-degree values gives:

| B | seats | cross-series additive p95/max | 4/5 ms gate |
|---:|---:|---:|:---:|
| 12,288 | 16 | 4.314681 / 4.893136 | p95 fail |
| 12,288 | 32 | 5.975079 / 6.479201 | fail |
| 16,384 | 16 | 4.734098 / 4.950552 | p95 fail |
| 16,384 | 32 | 6.607455 / 7.206284 | fail |
| 20,480 | 16 | 5.353681 / 6.097719 | fail |
| 20,480 | 32 | 7.098621 / 7.792909 | fail |

The cross-series table mixes platforms and is not gate evidence. Both tables
say the same practical thing: 16,384 advances as the scheduler budget, but an
integrated canonical body measurement remains mandatory. Do not claim the
whole-body gate from P10.0.

## Raw artifacts

Directory:

`/private/tmp/claude-501/-Users-jamesboggs-coding-coworlds-coworld-ctf/3d57efa8-dd72-43f4-8a00-809d9728282b/scratchpad/impl/phase10-logs/`

Contents:

- `b<B>-r<seats>-<scenario>.json`: 18 raw row artifacts, including 120 timing
  samples for combined nav/search/steering, raw steering-call counts,
  completion order, lifecycle counters, and fingerprints.
- Matching `.stderr`: one-row execution marker.
- `rows.tsv`: lossless flattened summary of all 18 rows.
- `validation.txt`: matrix, sample-count, PID, determinism, legality, and
  inflation assertions.
- `environment.txt`: OS/compiler/branch/HEAD plus source, binary, and corpus
  hashes.
- `nim-check.log` and `build.log`: compile validation.
- `SHA256SUMS`: checksums for all artifacts above.

Exact build and row command shapes:

```sh
export WASMTIME_C_API="$PWD/tools/runtime_spike/.deps/installed/aarch64-macos/wasmtime-c-api"
export C_INCLUDE_PATH="$WASMTIME_C_API/include"
export LIBRARY_PATH="$WASMTIME_C_API/lib"
export DYLD_LIBRARY_PATH="$WASMTIME_C_API/lib"

nim check -d:release -d:noSignalHandler --threads:on \
  tools/investigate_body_nav_p10.nim
nim c -d:release -d:noSignalHandler --threads:on \
  -o:/tmp/coworld-nav-p10-measure tools/investigate_body_nav_p10.nim

/tmp/coworld-nav-p10-measure \
  tests/fixtures/shell/nav_route_corpus.json \
  <12288|16384|20480> <16|32> \
  <first_goal_burst|moving_goal_12_tick_cadence|stuck_replans>
```

Both Nim checks succeeded. Imported Round 3/4 measurement modules emit their
existing unused-import/declaration warnings; there were no errors.

## Scope and ruling required

The only repository change is the new measurement harness under `tools/`.
`src/`, production tests, caps, GameVersion, fixtures, viewer, design docs, and
Asana are unchanged.

Local measurement checkpoint: `2906751b` (`experiment: measure Phase 10
navigation budgets`). The commit contains only
`tools/investigate_body_nav_p10.nim`; it was not pushed.

James must now rule on:

1. B=16,384 for the production integration trial (or another budget);
2. colossal option B and its eventual measured cap;
3. permission to begin P10.1 production integration.

Stop here until that ruling.
