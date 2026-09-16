# Peer plan: research loop, protocol critique, and decisions

Written 2026-09-09 by Claude (peer, tmux `nav-research-peer`). Revision 2, after Codex's
`PEER_REVIEW.md` and `DECISIONS.md`. Where this file and `DECISIONS.md` differ, the decisions
file is the negotiated state and this file says so inline. Sources: `META_RESEARCH.md`.
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a
Inputs read: the handoff, PHASE_10_REPORT "State at stand-down", DEVBOX_NUMBERS_1/2,
RULING_TICK_GATE, FIXUP_P10_BUDGET, the exploration record, `tools/bench_body_nav_rework.nim`
and `tools/run_body_nav_gate.sh` at 20234cc7, the corpus header, and Codex's `PEER_UPDATE.md`,
`BASELINE_PREREG.md`, `B0_REPORT.md`, `B0/*.json`, `PROFILE/profile-trace.json`,
`INSTRUMENTATION_PREREG.md`, `LEDGER.md`, `platform-game-pods.json`.

Nothing here relaxes a threshold. Where documents disagree, the strictest value in force wins
(section 4.1).

## 0. Two finish lines

| | Phase 10 completion | Throughput doubling |
|---|---|---|
| Question | Which B does the current code afford on production-class hardware? | How much more useful search fits in the same tick after code changes? |
| Output | One constant, nine fixtures, viewer, GV check, docs, Phase 11 | Scoreboard of accepted and rejected changes, a new B, a doubling report |
| Selection | Headroom screen p95 <= 3.6 ms and max <= 4.5 ms over all rows and repeats, under the 4/5 ms harness gate | Same screen and gate; quality within harness limits; determinism; retained memory |
| State | B0 = 1,024 on m6i under the inherited protocol (`B0_REPORT.md`); 2,048 passes 4/5 but fails the screen on max in two rows | Not started; forbidden until Phase 10/11 finish (DECISIONS D3) |

Per DECISIONS D1 both capacity measures are reported separately: raw pop capacity (largest B
passing the screen) and fixed-work route throughput (M2). A doubling claim names which one it
is, on a matched host with matched work, unchanged gates, and final qualification.

## 1. The loop

Shape (adopted, DECISIONS "avoid a new framework"): tmux peer protocol, one git checkpoint per
experiment, registered hypothesis cards, the existing shell benchmark runner, JSON artifacts,
a small deterministic report script (`summarize_baseline.py` is the seed). Cascaded evaluation,
staged programme, duplicate rejection and preregistration as in `META_RESEARCH.md` section 2.
The operational contract that implements this is Codex's `RESEARCH_LOOP.md`; this section is
the rationale and the parts of the design that file does not spell out.

### 1.1 Stages and exit conditions
- **S0 Baseline.** Done for m6i (`B0_REPORT.md`). Remaining: I0 instrumentation-off and A/A
  pair (`INSTRUMENTATION_PREREG.md`, Codex), c6a rows (H1 card).
- **S1 Characterise.** Fluffy at B0 (done once, `PROFILE/`; see 4.6 for what it can and cannot
  see), per-stage split from the B0 JSON (section 4.5), H1 across hosts. Exit: a written
  statement of where the tick goes on each measured host, with all repeats shown.
- **Phase 10/11 completion** (DECISIONS D3, handoff order): choose B from the worst measured
  production-class host, fixtures, viewer, GV check, tests, containment pair, canonical Docker
  gate, docs, Phase 11. No algorithm experiment before this exits.
- **S2 Optimise.** Cards in rank order through the cascade (1.2). Exit: stopping rule (1.6).
- **S3 Ablate.** Each accepted change re-measured with that change alone reverted from the
  accepted stack. Exit: an ablation row or an explicit "not separable" note per change.
- **S4 Qualify.** Held-out corpus and maps (1.5), canonical Docker gate, both compile shapes,
  containment pair with same-host main, fixtures, viewer, docs. Exit: partner sign-off; James for
  anything that publishes, pushes, merges or touches Asana.

### 1.2 Evaluation cascade per hypothesis

| Stage | Where | What | Pass if |
|---|---|---|---|
| C0 | Mac | `nim check` both server shapes; `test_shell_body_nav_rework.nim`, `test_shell_body_seat.nim`; corpus route hash on the registered map subset | green; hash identical to parent, or the card pre-declared "routes may change" |
| C1 | Mac | full corpus quality, all strata; native tick rows (informational); ns/pop and pops per route | inflation within harness limits in every stratum; zero missing/illegal; effect direction matches the card, or the card pre-declared "x86-only effect" |
| C2 | pinned core, registered host, no concurrent benchmark | the six rows, 3 fresh processes, breakdown on, interleaved with the parent binary (A, B, A, B, A, B) | card's primary rows improve beyond the A/A spread of the same session; no gated row regresses beyond it (DECISIONS: primary rows and all-row nonregression registered separately) |
| C3 | c6a first, then measured fleet tail (DECISIONS D2) | as C2 | as C2 |
| Milestone | Mac Docker plus registered hosts | held-out corpus and maps; canonical Docker gate; retained memory; containment pair | all gates pass |

A hypothesis that fails at any stage is a negative at that stage with numbers (1.7). At most
two fix attempts per hypothesis.

### 1.3 One commit per experiment
Subject carries the card id; body carries the scoreboard row. Rejected experiments stay in
history and are reverted so the tip is always the accepted stack.

### 1.4 Noise: A/A and paired controls (DECISIONS D5)
Independent full-process repeats are the unit, never per-tick resampling (consecutive ticks
share scheduler and danger state, so a bootstrap over ticks understates the spread). Per row
report every repeat's p95 and max, the min-to-max spread across repeats, and the same for the
parent binary run interleaved in the same session. "Improved" means the candidate's worst
repeat beats the parent's best repeat on the primary rows; that is a descriptive rule, not a
confidence bound, and the sample protocol (repeat count, interleaving, pin) is fixed in the
card before the run. Three repeats is the floor; a card may register more. The gate statistics
(nearest-rank p95 of 120, observed max) stay exactly as the harness computes them.

Evidence that this matters: in B0, budget 2,048 fails the headroom screen only through two
single-sample maxima (4.920 ms in one 16-seat moving row where the next largest sample was
3.553; 4.995 ms in one 32-seat stuck row where the next was 3.938). Under the registered rule
that is a fail and stays a fail; it is also exactly the shape of event that A/A must size.

### 1.5 Held-out validation
Development set: the existing corpus (3,072 cases) and the existing tick anchors (pool map 15).
Held-out, used only at milestones: a second corpus from `tools/build_nav_route_corpus.nim`
with a different seed and start points, same oracle and strata, committed once; and three
additional pool maps chosen by a seeded draw recorded in the registry before S2. The original
corpus remains a gate at the harness limits; the held-out set answers whether a gain is general.

### 1.6 Stopping and checkpoints (DECISIONS: no terminating cap)
Per hypothesis: stop when the card's decision rule fires or after two fix attempts.
Programme checkpoint, not termination: at 40 experiments or 20 host-hours, re-plan with the
partner. Doubling is reported when achieved under section 0; not achieving it is reported as a
negative with the best achieved, never as completion. Owned idle experimental instances are
stopped when done; host lifetime and spend are recorded in the ledger.

### 1.7 Negatives
Every negative gets a scoreboard row: stage failed, numbers, believed mechanism, and "what this
does not establish". The exploration record's rejected list is imported as pre-existing
negatives with their original criteria so nothing is re-run without a new mechanism.

### 1.8 Costs
Units: host minutes (pinned), builds, agent turns, instance-hours per host. B0 on m6i: four
builds, three pinned repeats plus one unpinned per build, six rows each. Manifests carry
`cost.*`; the ledger sums per card.

### 1.9 Manifests and layout (Codex owns files; proposal)
`research/runs/<YYYYMMDD-HHMM>-<card>-<stage>/` with `manifest.json`, harness JSON, stderr,
`git rev-parse HEAD`, `git status --porcelain`, binary sha256, and any Fluffy trace. Manifest
fields: card id, stage, commit, dirty, parent commit and binary sha, nim version, flags,
breakdown on/off, host (instance type, cpu model, cores, SMT, NUMA), pinned cpu, sibling state,
load before and after, harness sha256, corpus and pool sha256, B, repeats, interleaving order,
estimator, cost. `research/SCOREBOARD.md` is append-only, one row per cascade run. B0 already
follows most of this (`B0/*-host.txt`, `*-binary.sha256`, `B0_SHA256SUMS`).

## 2. Metrics
- **M0** whole-body tick p95 and max, six rows, registered host (gate).
- **M1** ns per pop from `route_search_ns_per_pop_*`.
- **M2** routes per second at fixed quality: corpus routes completed per second of search time
  on the registered host, with inflation inside the harness limits and the route hash recorded.
  Needs a small harness addition (the activation row already times one far query; generalise
  over the corpus). Codex owns.
- **M3** per-stratum inflation, missing, illegal (gate). **M4** route hash identical
  arm64/amd64 (gate). **M5** retained bytes (gate).
- **M6** ticks to route, p50/p95/max at 16/32 seats, from the completion-latency workload
  (`PEER_CARDS.md` section 5); reported, not gated.
Doubling reports raw-pop capacity and M2 separately (DECISIONS D1).

## 3. Hypothesis registry (ranking proposal; cards for H1-H3 and H11 in PEER_CARDS.md)

| id | Hypothesis | Predicted effect | Kill if | Prior evidence | Cost |
|---|---|---|---|---|---|
| H1 | Platform characterisation across m6i, c6a.4xlarge, fleet tail; pinned vs unpinned; SMT sibling busy vs idle | Milan per-pop cost differs from Ice Lake; sibling load moves the tail | measurement, no kill | 37 CTF game containers, mostly c6a.4xlarge, 1 CPU request, no limit (Codex inventory) | low |
| H11 | Per-seat packed-weight refresh made incremental (hot cells only; cold anchors take the 8 px value) | weight refresh p95 from ~0.46 ms toward < 0.1 ms in every row | gain < A/A spread; routes change | B0 split: 455-465 us p95 in all 24 rows, budget-independent; every tick at 32 seats | low-medium |
| H2 | Compact active-node workspace (dense slot per hot or wall-band cell) | M1 down >= 20 percent on x86 | M1 gain < A/A spread; colossal no longer fits | search is ~60 percent of the tick at B=4,096 on m6i; sparse variant was 4-6x slower | high |
| H3 | Pop-loop layout: SoA, 16-bit stamps where provable, bucket sizing | M1 down 10-25 percent | < A/A spread | none on x86 | medium |
| H4 | Consistent differential heuristic on the 8 px graph | pops per route down >= 25 percent | pops down < 10 percent, or any stratum max rises (3.0 percent harness max; the earlier tie shift to 3.64-3.77 percent would now FAIL) | inconsistent ALT gave ~1 percent | medium |
| H5 | Bidirectional or goal-side bounded search on anchors | pops per route down 15-40 percent on far cases | inflation moves | untried | medium |
| H6 | Incremental reuse across a danger generation, hot set only | fewer pops in stuck and moving rows | < A/A spread; per-seat state map-sized | rejected only under the old static design | high |
| H7 | Remaining request overhead (validate, attach, install) | request p95 down | already ~14 us p95 at B=1,024 (DECISIONS D4) | corrected x86 rows | low |
| H8 | Allocator, hugepages, prefetch tuned on Milan/Xeon | M1 down 5-15 percent | < A/A spread | prefetch no effect on M4 | low |
| H9 | `-march=x86-64-v3` if the production Docker build can carry it (fleet includes m5a Zen 1 and c5 Skylake, so v3 is the ceiling) | M1 down 0-10 percent | < A/A spread; Docker cannot carry it | untried | low |
| H10 | Scheduler variants (SJF tweaks, admission batching, budget carry-over) | M0 tail down at same B | unchanged | SJF is in | low |

Ranking rationale: H1 is measurement and decides the gate host. H11 is new from the B0 split
(section 4.5): a fixed ~0.46 ms per tick that does not scale with B, cheap to attack, and
mostly independent of the search. H2 and H3 attack the ~600-780 ns per pop on Ice Lake (about
3.5x the M4). H4 and H5 carry route-change risk under the 0.5/3.0 gate and come after the
cheap-pops ceiling is known. H7 is demoted per D4.

## 4. Critique of the baseline and acceptance design

### 4.1 Thresholds across documents; the strictest in force wins
- Route quality: harness `QualityP95Limit = 0.5`, `QualityMaxLimit = 3.0` per stratum (set in
  937ea830, James's commit; down from 3.0/10.0). Handoff section 1 and the Asana gate still say
  3.0/10.0. Keep 0.5/3.0 (DECISIONS agrees). R3.3's 0.313/0.829 passes either.
- Tick: harness gate 4/5 ms; selection screen 3.6/4.5 ms (FIXUP_P10_BUDGET step 3,
  RULING_TICK_GATE item 4, BASELINE_PREREG); handoff section 1 says "5 ms". Use 3.6/4.5 for
  choosing B and 4/5 as the gate; never quote 5 ms as the selection bound.
- The handoff and Asana text should be corrected during Phase 11 docs work.

### 4.2 The gate host
Codex's inventory (softmax-tournament, 2026-09-09T22:11Z): CTF game containers are mostly on
c6a.4xlarge (AMD Milan), some on m5a and newer Intel flex types; 1 CPU request, 512 Mi, no
limit. The m6i devbox (Ice Lake) is not in that set. Milan's L2 is 512 KiB per core against
Ice Lake's 1.25 MiB, so cache behaviour may differ. DECISIONS D2: c6a first (Codex is
provisioning), then the measured fleet tail; no assertion about an unmeasured host. Until c6a
rows exist every number is labelled `host: m6i`.

### 4.3 Tick scenarios measure storms, not play
- `first_goals` resets every seat's navigation life every tick (harness line 331), so each tick
  is a cold-admission storm; it cannot yield ticks-to-route. `PEER_CARDS.md` section 5 specifies
  the minimal completion-latency workload.
- `moving_goals` flips all seats' targets on the same tick every 12 ticks: a synchronised
  replan burst. Keep as the gate row; a staggered variant is informational only.
- `stuck_replans` sets `stuckTicks = 8` on every seat every tick: same storm shape.
- One map, one start, one near/far pair. Section 1.5 adds held-out maps.

### 4.4 Estimator and sample size
120 samples, nearest-rank p95 (6th largest), observed max. Max is the noisiest statistic and
the shared host runs a live tournament. B0 forbade retry-for-green and used worst-of-3; keep
that, add interleaved parent runs and the I0 A/A pair, and report every repeat. Do not change
the gate statistic.

### 4.5 What the B0 split says (m6i, breakdown on, r1 rows; all p95 in ms)
| B | row | total | search | weight refresh | non-nav | request overhead |
|---:|---|---:|---:|---:|---:|---:|
| 1,024 | 16 first | 2.195 | 0.647 | 0.456 | 1.088 | 0.002 |
| 1,024 | 32 moving | 2.527 | 0.747 | 0.460 | 1.247 | 0.014 |
| 4,096 | 16 first | 3.923 | 2.380 | 0.458 | 1.083 | 0.003 |
| 4,096 | 32 moving | 4.880 | 3.005 | 0.458 | 1.245 | 0.030 |
Observations (all from `B0/b1024-r1.json` and `b4096-r1.json`; other repeats agree within tens
of microseconds):
- ns per pop p95 is 580-800 on this core across all rows, about 3.5x the M4's 185.
- Weight refresh is ~0.46 ms p95 in every one of the 24 rows and does not scale with B. At 16
  seats the median refresh count per tick is 0 (p50 tick 0.84 ms) while p95 is a refresh tick;
  at 32 seats it is 1 per tick (p50 2.35 ms). The tail is set by refresh ticks. Hence H11.
- The Fluffy trace (`PROFILE/`) shows `rebuildScheduledDanger` at ~1.0 ms average per tick and
  no markers inside the nav search (the existing markers are `shell.*` and `body.*` stages;
  `shell.planning` equals the search time). Danger rebuild is outside nav scope but is the
  largest single item in the tick on this host; flagged for the record, not for this programme.
- Request overhead is 2-30 us p95: D4 confirmed.
- One unpinned run (2,048, 16-seat first) hit 4.695 ms p95 with 1,048 ns per pop: migration or
  sibling contention. Pinned rows never showed this. H1 measures the sibling case deliberately.

### 4.6 Instrumentation
B0 runs with `bodyNavBreakdown` on. Codex's I0 pairs it with a breakdown-off binary and an A/A
pair, interleaved, with pop-array equality as the work-equivalence check. Agreed; that unit is
Codex's. Fluffy cannot see inside the search without new `{.measure.}` markers in
`src/shell/body_nav.nim` or `body_route_query.nim` (game thread only); that is a src change and
is deferred until the Phase 10/11 exit, and must be a separate profiled build, never the
acceptance binary.

### 4.7 Corpus caveat
The corpus `todos` still carries the disabled cover-hold stratum (task 1218165969208626). A
"quality unchanged" claim excludes that stratum and should say so.

## 5. Disagreements: resolved and open
- D1 metric: resolved per DECISIONS (report both; no AND).
- D2 host: resolved (c6a first, Codex provisions).
- D3 sequencing: resolved (handoff order stands; Phase 10/11 before optimisation). My reason
  for raising it (fixture and viewer churn if a later change moves routes) is recorded as a
  cost to expect, not a disagreement.
- D4 request overhead: resolved (demoted).
- D5 acceptance: resolved (process-level repeats, interleaved parent, descriptive spread, gate
  statistics untouched).
- Open, minor: whether H11 should precede H2 in rank. My case is in section 3; Codex ranks.

## 6. Uncertainties
- Real Milan numbers (pending c6a).
- Whether the production Dockerfile's NimFlags can carry any `-march` (not checked).
- Whether weight refresh fires every tick in real play (tracks move every tick, so probably
  yes; the harness's static tracks make 16-seat rows refresh less often).
- Devbox disk at 84 percent for Docker gates (Codex ledger).
