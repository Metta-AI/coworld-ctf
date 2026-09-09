# Latency harness unit: `--latency` completion workload

Written 2026-09-09 by Claude (peer) for the `LATENCY_BRIEF.md` unit. Harness-only change to
`tools/bench_body_nav_rework.nim`; no src edits, no commits, no remote work. Codex's
`navGateNoBreakdown` and profile edits are preserved verbatim (the diff below touches only
the new constants, the new procs, usage and argument parsing).
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. Marker semantics from source (the bug the draft spec had)

- `seat.revision` (`src/shell/body_nav.nim:110`) counts requests: it is incremented at 989
  inside `navigationWaypoint` when `shouldQueryRoute` is true, before `submitMixedRoute`, and
  it is zeroed by `resetNavigationLife` (339). It says nothing about completion, so the draft
  spec's "revision advanced past its value at wave start" would have counted request issuance
  as completion. Corrected.
- `seat.installedRoute.revision` (73) is the publication marker. `installMixedRoute` (692-709)
  writes it last, with `request.requestGeneration`, after copying the live spans; it is 0 in a
  fresh `BodyInstalledRoute`, which `resetNavigationLife` assigns (352), and
  `publishDangerGeneration` (472-474) clears the whole installed route when the seat's danger
  generation moves past the route's.
- The finish path (836-846) installs only when the seat is still `brlInFlight`, the request
  generation matches, and the danger generation matches; otherwise the result is dropped and
  nothing is published. A failed search sets `lastQuerySucceeded = false` and
  `lastQueryFailure` and leaves the installed route untouched.
- `cancelStaleRouteJob` (771-784): if the in-flight seat's `dangerGeneration` no longer equals
  the request's, the job is discarded and the seat goes back to `brlPending` with a refreshed
  danger generation. `publishDangerGeneration` increments `dangerGeneration` unconditionally
  on every scheduled rebuild (467-469), and rebuilds fire per seat every `DangerCadenceK = 32`
  ticks (`dangerSeatDue`, 545-546).

Harness rule: after each wave's reset, a seat is complete at the first tick where
`installedRoute.revision != 0` and `pointCount > 0`; the tick index, installed revision,
point count and `installedRouteFingerprint` are recorded then. At wave end every seat's
`revision`, lifecycle, `lastQuerySucceeded`, `lastQueryFailure`, `replacements` and
`firstWaitTick` are recorded, so an unpublished seat is classified from data rather than
assumed. "Superseded before install" means a published route whose installed revision is not
1, that is, not the wave's first request. No false completion is possible: reset zeroes the
marker, and the only writer of a nonzero marker is `installMixedRoute`.

## 2. What was implemented

- `--latency` flag, separate `runLatencyGate`/`latencyRow`/`runLatencyWaves` procs and a
  private `LatencyWave` record. No new `NavGateScenario` case, so `for scenario in
  NavGateScenario` in `runTickGate` is untouched. `--all` does not include it.
- Workload: pool map 15, the same corpus anchors as `--tick`; all seats reset and positioned at
  `start`; one warm-up far wave then 10 measured waves alternating far, near, far, ...;
  the same `tickFrames` (8 static threat tracks around the far goal), the same mask-driven
  movement, the production scheduler and body via `episode.step`; `elapsedZoneTick` is the
  within-wave tick, mirroring `tickRow`'s within-run counter. Cap 2,000 ticks per wave; a cap
  hit fails the row and the unfinished seat state is retained in the JSON.
- Two full runs in-process from fresh episodes; `deterministic` compares ticks, revisions,
  point counts, fingerprints, completion order, lifecycles and failures.
- Per wave (breakdown builds only): pops, scheduler restarts, admissions, completions, weight
  refreshes; `counters_measured` says whether they were compiled in.
- Row `pass` = deterministic and no cap hit and every measured seat-wave published. Tick timing
  of wave ticks is emitted with `tick_timing_gated: false`.

## 3. Commands (Mac, arm64, informational timing only)

```
cp ~/coding/coworlds/coworld-ctf/nim.cfg .            # untracked, gitignored, nimby-generated
W=~/coding/coworlds/coworld-ctf/tools/runtime_spike/.deps/installed/aarch64-macos/wasmtime-c-api
export WASMTIME_C_API=$W C_INCLUDE_PATH=$W/include LIBRARY_PATH=$W/lib DYLD_LIBRARY_PATH=$W/lib
nim c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on \
  -o:<scratch>/bench-new2 tools/bench_body_nav_rework.nim
<scratch>/bench-new2 --latency --corpus tests/fixtures/shell/nav_route_corpus.json   # x2 fresh
<scratch>/bench-base --tick ... ; <scratch>/bench-new --tick ...                       # base = pre-edit harness
nim check (runtime-linked) ; env -u WASMTIME_C_API nim check (runtime-stub) ; nim c -d:navGateNoBreakdown
```
Nim 2.2.6, source 20234cc7 plus Codex's harness edits plus this unit. Evidence files under
`research/LATENCY/` (my scratch copies; the directory name is mine, flag if it collides).

## 4. Checks and results

| Check | Result |
|---|---|
| Compile, runtime-linked shape (`nim check` with WASMTIME) | pass |
| Compile, runtime-stub shape (`env -u WASMTIME_C_API nim check`) | pass |
| Build with `-d:navGateNoBreakdown` | pass |
| `--tick` unchanged: base vs new binaries, 6 rows | `pops_per_tick` arrays identical in all 6 rows; every non-timing field identical; thresholds identical; key sets identical |
| `--latency`, first build, two fresh processes | both exit 1 (cap hits); all non-timing fields identical across processes; in-process `deterministic: true` on both rosters |
| `--latency`, second build (counters, superseded fix), process 1 | exit 1 (cap hits); deterministic; counters below |
| `--latency`, second build, process 2 | see section 7 |

(The base `--tick` run exited 1 on the Mac tick gate while the new run exited 0; both were run
concurrently with the latency processes and Mac timing is not a gate. Work fields are what the
check compares, and they match.)

## 5. Findings (Mac, B = 1,024, pool 15, breakdown on)

Far waves never publish a route for any seat within 2,000 ticks, at 16 and at 32 seats, in
every far wave, in both processes. Near waves publish every seat.

| roster | wave kind | ticks used | pops | scheduler restarts | admissions | completions |
|---:|---|---:|---:|---:|---:|---:|
| 16 | far (each of 5 measured) | 2,000 (cap) | 2,048,000 | 62-63 | 63-64 | 0 |
| 16 | near (each of 5) | 48-51 | 48k-52k | 0 | 27-31 | 27-31 |
| 32 | far (each of 5) | 2,000 (cap) | 2,048,000 | 62-63 | 63-64 | 0 |
| 32 | near (each of 5) | 127-141 | 130k-144k | 0-4 | 107-137 | 106-134 |

Near ticks-to-route (measured waves): 16 seats p50/p95/max = 18/48/51 (n = 80); 32 seats
54/135/141 (n = 160). Completion order is seat order 0, 1, 2, ... (SJF with equal estimates
falls through to earliest wait tick then seat index). Far ticks-to-route: no samples.

End state of every unpublished far seat: `request_revision = 1`, `replacements = 0`,
`last_failure = brfNone`, `last_query_succeeded = false`; seat 0 is `brlInFlight`, every
other seat `brlPending`. So the first request was never replaced, never failed, and never
finished.

Mechanism, read from source and matched by the counters: seat 0 wins admission; every 32
ticks its danger rebuild bumps its danger generation; `cancelStaleRouteJob` discards the
in-flight search and re-queues it from scratch; the restart count per far wave (62-63) equals
2,000 / 32. A route can therefore never receive more than about 32 x 1,024 = 32,768 pops (the
first window is shorter, since admission and cadence are not aligned). The far route on this
map needs 19,170 pops with no danger (activation row, `mac-activation-pool15.json`), and the
warm-up wave, which runs before the threat-cloud danger has been folded into the weights,
did publish seat 0 at wave tick 17 with 484 points. Once danger around the far goal is in the
weights the far search needs more pops than one cadence window provides, and it is restarted
forever. The corpus far strata under danger were measured at roughly 31k-52k pops in the
campaign (exploration record, R3.3), which is above the window.

This is consistent with the B0 tick rows, where `route_completions_per_tick` is 0 in every
row except the 32-seat moving-goal row. It is not a harness artefact: the harness moves seats by
the produced masks and never touches danger or the scheduler.

What this establishes: at B = 1,024 with the 32-tick cadence, a seat whose route needs more
than roughly 32k pops on this map never gets a route; it steers for the whole wave. What it does
not establish: the exact pop requirement of this far case under danger (not emitted), behaviour
on other maps, or anything about x86 timing (this run is Mac).

Implications for Phase 10 selection (for Codex and James, not decided here):
- Selecting B by the tick screen alone is insufficient; a completion criterion is needed for
  the far strata (for instance, every corpus far case must be able to complete within one
  cadence window at the chosen B, or the cadence and cancel policy must change).
- At B = 2,048 the window is about 65k pops, above the campaign's far-case counts, but that is a
  src-side and design question (cancel-on-generation versus resume-with-refreshed-weights), and
  it is out of this unit's scope.

## 6. Superseded and failure counts

With the corrected rule (installed revision != 1), `superseded_before_install` is 0 on both
rosters; the first build's count (63/127) was mislabeled: it compared the installed revision
with the seat's revision at wave end, which is higher whenever a seat re-requests after its
route is cleared at the next cadence tick. `failed_unpublished` is 0: no search returned a
failure.

## 7. Cross-process check, second build

Process 2 (fresh process, same binary): exit 1 with the same 5 cap hits per roster,
`deterministic: true` on both rosters, and every non-timing field of both rows identical to
process 1 (per-seat ticks, revisions, point counts, fingerprints, completion order, lifecycle,
failure codes, and the per-wave pop and scheduler counters). Evidence: `LATENCY/mac-latency-v2-p1.json`,
`LATENCY/mac-latency-v2-p2.json`, exit files, and `LATENCY_SHA256SUMS`.

## 8. State handed back

- `tools/bench_body_nav_rework.nim`: sha256 5606a0fd3cfbf6a1542af8e43dc914f31900fd32925f38bc3447e983027824b9,
  225 insertions / 7 deletions against 20234cc7 (includes Codex's earlier edits). I am no
  longer editing it.
- The `--latency` rows fail by design at B = 1,024 on this map (far-wave starvation); the
  failures and unfinished seat states are retained in the JSON. Per Codex's instruction the cap
  and the threat layout were not tuned.
- Remaining questions: the far case's pop requirement under danger is not emitted (a per-seat
  pops-since-admission counter would show how close each restart came); whether EC2 reproduces
  the identical wave outcomes (it should, the outcome is pop-count driven and deterministic);
  and which policy change, if any, James wants for cancel-on-generation.
