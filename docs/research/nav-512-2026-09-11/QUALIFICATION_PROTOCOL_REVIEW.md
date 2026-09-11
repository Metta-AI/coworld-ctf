# Held-out qualification protocol: peer proposal

Read-only review of `HELDOUT_DRAFT.md`, `QUALIFICATION_PLAY.md`,
`qualification-maps/attempts.json` and `map-scale29.json`, the real-game
runner (`docs/reports/nav-budget-screen-2026-09-11/run_native.py`,
`prepare_native.py`), the demo-play config seam (`tests/fixtures/shell/
shell_demo_config.json`, parsed at `src/shell/episode.nim:490-518`) and
`docs/ENV_VARIATION.md`. No run, build, code change or commit. This is a
proposal for the root to freeze; numbers cited from earlier phases are
training-scenario evidence only.

## 1. Inputs and the seams that carry them

Every input below is an existing config key or runner argument; no
production knob is invented.

| Input | Values | Seam |
|---|---|---|
| Map | M1 `tests/fixtures/br-match-map-r9-301.json` (3211x1713, seed 301); M2 `tests/fixtures/br-match-map-14005.json` (3211x1713, seed 14005); M3 `qualification-maps/map-scale29.json` (3582x1911, seed 5120918, first passing draw after seven retained rejections); T = training practice spec (4242) for one anchor cell only | The fixtures are `mapSpec`-shaped objects (same keys as `config.practice.json.mapSpec`); the runner replaces `config['mapSpec']` with the file's object. `mapPath` stays `arena` and is overridden by the embedded spec, as the screen recorded. Freeze each file's normalized SHA-256 (draft already lists M1/M2; `qualification-maps/sha256.txt` has M3). |
| Gun range | 331, 497, 1050 | `config['gunRange']` (`ENV_VARIATION.md:343`); also sets the danger radius at activation. |
| Seats | 16, 32 | Existing trimming in `run_native.py` (`minPlayers`, `players`, `slots`, `tokens`, `demoPlay.seats`). With `teams = 16`, 16 seats is one solo per team; 32 is duos. |
| Guest | `edge_ride` (params as `shell_demo_config.json`); `nav_research_moving` (params `{}`) | `demoPlay.modulePath` / `playName` / `params`. The moving play's manifest declares `params: {}`, so the runner must pass `{}`; the root's native probe passed 5/5 on Nim 2.2.4 / Wasmtime 48.0.1. |
| Health | `hitPoints` 3 (edge_ride cells); 1000 (moving-play stress cells) | `config['hitPoints']` (`ENV_VARIATION.md:341`, `>= 1`). Lives stay 1. |
| Fixed | seed 907, `maxTicks` 1200, `playSeatBindTicks` 120, `fastMode` true, `speed` 1, `barrageMaxPerSec` 0, `SHELL_ZONE_LOG=1`, measurement patch from `prepare_native.py`, server threads on CPU 5, presence clients on 6-7 | unchanged from the H1-H3 cards |
| Variants | P256 = original `6b6b3408` at 256; C512 = selected candidate at 512 | same `sed` substitution of `ColdPlanBudgetPerTick` as the cards |

The runner needs a small parametrization of `run()` (map spec path,
gunRange, hitPoints, demoPlay module/name/params) in place of today's
hard-coded 497/practice/edge_ride; that is runner code under
`docs/`, not production code.

## 2. Matrix (ten cells, not a grid)

Chosen so each map appears at both seat counts, each range at least
twice, and each guest on at least two maps, with the heaviest planning
cases explicit.

| Cell | Map | Seats | Range | Guest | hitPoints | Why |
|---|---|---:|---:|---|---:|---|
| 1 | M1 | 32 | 331 | edge_ride | 3 | held-out map, short range, full roster |
| 2 | M1 | 16 | 1050 | edge_ride | 3 | long range at solo count |
| 3 | M2 | 32 | 1050 | edge_ride | 3 | long range, full roster |
| 4 | M2 | 16 | 331 | edge_ride | 3 | |
| 5 | M3 | 32 | 497 | edge_ride | 3 | largest map, most planning per route |
| 6 | M3 | 16 | 331 | edge_ride | 3 | |
| 7 | M1 | 32 | 497 | nav_research_moving | 1000 | all-alive replan load at the training range |
| 8 | M3 | 32 | 1050 | nav_research_moving | 1000 | worst case: largest map, longest range, synchronized replans |
| 9 | T | 16 | 497 | edge_ride | 3 | anchor to the training scenario at the other seat count |
| 10 | M2 | 16 | 497 | nav_research_moving | 1000 | moving load at solo count |

Cells 7, 8 and 10 keep `hitPoints` 1000 deliberately so the replan load is
not removed by deaths; they are stress cells, not realistic ones, and are
reported as such. The moving play clocks on the shared view tick, so all
seats replan in the same tick every 12 ticks; both variants face the same
burst.

## 3. Repetitions, order, coverage

- Three process repetitions per cell, one game at a time on the pinned
  core, nothing else on the host. Per repetition the pair order
  alternates: rep 1 P256 then C512; rep 2 C512 then P256; rep 3 P256 then
  C512. Cells are interleaved across repetitions (all cells' rep 1, then
  all cells' rep 2, ...) so host drift lands on both variants.
- 10 cells x 2 variants x 3 repetitions = 60 finite games of 1,200
  frames; at the observed 25-60 ms frames that is roughly two hours plus
  startup, well within one session. No warmups, no discarded runs, no
  replacement of slow runs, every `exit.json`/`failure.json` retained.
- Coverage rule: a run counts only if `BUDGET_FRAME` has exactly 1,200
  rows, `SHELL_MOVEMENT seats=` equals the seat count on every row, every
  seat logged its play `init`, and `play_fault` count is zero. Both runs
  of a pair must satisfy this for the pair to enter any ratio. Totals are
  never compared across unequal tick counts.

## 4. Exactness at equal budget (correctness before timing)

512 versus 256 changes when routes land and therefore the world; only
equal-budget comparisons can demand identical output.

- Offline, per held-out map: run `H1/crossbuild_fingerprints.nim`
  parametrized by map path for M1, M2, M3 on baseline and candidate; the
  suspension digest, path digest and point count must be identical. Cheap,
  no game. I can run the arm64 side of this for a cross-architecture
  determinism check against the root's amd64 output.
- In-game: one extra candidate-at-256 run for cells 1, 5 and 8 (one per
  map, including the moving play); its semantic stream
  (`SHELL_PLAN_BUDGET`, `SHELL_NAV`, `SHELL_INSTALL`, `SHELL_MOVEMENT`)
  must hash equal to the P256 run of the same repetition, as
  `analyze_h1.py` already checks. Three extra games.
- Repeat determinism: within a variant and budget, all three repetitions
  must produce identical semantic streams, as in every card so far.
- Legality: for every candidate run, replay the installed routes offline
  through `canStand` + the original segment scan on the same map (the
  `SHELL_INSTALL` rows give goals; the planner-level check is the existing
  `test_shell_body_segment_exact` oracle applied to each installed path).
  If the runner cannot export paths, the fingerprint parity above plus the
  segment oracle stands in, and the gap is stated.

## 5. Gates (per cell, C512 vs P256, paired by repetition)

Whole-frame, unchanged thresholds, all ticks including guest bursts:

- median paired ratio of frame total <= 1.00; median paired p50, p95 and
  maximum <= 1.00; worst deadline misses (frames > 41.667 ms) across the
  three candidate runs <= worst across the three parent runs.

Navigation benefit, reported and gated so a "faster but useless" result
cannot pass:

- pending seat-ticks, no-path seat-ticks and stale seat-ticks of C512 <=
  P256 in every repetition (this is the whole point of 512);
- route latency from a per-plan record (request tick to install tick),
  p50/p95/max, reported; not gated until the record exists in the runner;
- no play faults; guests initialized == seats.

Decision rule: every cell must pass the whole-frame gates. No averaging
across cells, no dropping a cell. A cell that fails is a qualification
failure for the candidate at 512 on that workload and is reported with
its stage attribution (planning versus non-planning sums from
`SHELL_TIMING`), as in `H1_PEER_VERDICT.md`. A median win with a
regressed tail is a fail.

## 6. What a failed or early-ending run means

- Server exit non-zero, startup timeout, or fewer than 1,200 frames: the
  run is recorded with its `failure.json` or truncated log and the pair is
  void for timing. It is not a timing win for whichever variant ended
  early, and it is not rerun in place.
- If the early end is a game outcome (last team standing before tick
  1200) on an edge_ride cell, the cell is re-registered once with
  `hitPoints` 1000 as a pre-declared fallback, the original attempt kept
  beside it, and the cell is then labelled a stress cell.
- Any play fault or missing init on any seat voids the run.
- Two voided pairs in one cell end that cell as "not qualified on this
  workload"; the campaign does not sample until it passes.

## 7. Memory and colossal

H1-H3 change no allocation; the check is arithmetic plus one activation.
For M3 (3582x1911) and the colossal fixture geometry
(`tests/fixtures/gen-colossal-4team.bitreplay`, `mapSize` colossal =
5.2x), compute per-seat planner bytes from the constructors on baseline
and candidate (must be equal) and run one activation of `newBodyNavSystem`
at 32 seats on each to confirm the build succeeds within the existing
caps. No colossal game is timed; the draft's "colossal memory case" is
satisfied by this, and a colossal BR game with 16 groups is not an
authored configuration today.

## 8. Fleet-family stage (explicit, not claimed here)

`HARDWARE.md` shows production CTF games mostly on c6a.4xlarge and
c8i-flex.4xlarge with 1-CPU requests and no limit. After the m5a matrix
passes, repeat cells 1, 5 and 8 (three repetitions each, 18 games) on one
c6a.4xlarge and one c8i-flex.4xlarge, twice: pinned as above, and unpinned
with the container's default scheduling to mirror the 1-CPU-request-no-
limit shape, including the guest burst ticks. Same gates. Until that runs,
every statement is "training and held-out scenarios on one m5a core".

## 9. Notes on the draft

- Agree with the map provenance correction: the golden map is the
  training map and is used only in cell 9 as an anchor.
- Agree with scale 2.9 via the BR authoring CLI and the retained
  rejections; freeze `map-scale29.json` by its recorded hash.
- The draft's guest-diversity point (scatter/bodyguard/jackal) is
  deferred: those plays' replan behaviour has not been inspected, and the
  moving play covers the deterministic moving-goal path the draft asked
  for. If a second realistic guest is wanted, `bodyguard` at 32 seats on
  M2 is the natural eleventh cell, added only after its install stream is
  inspected.
- The 60-game count is the budget for one session; if the root needs it
  smaller, drop cells 4 and 10 first (they duplicate range and guest
  coverage present elsewhere) rather than reducing repetitions.

PHASE 8 READY
