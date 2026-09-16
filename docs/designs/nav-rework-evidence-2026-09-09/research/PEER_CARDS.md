# Hypothesis cards H1, H2, H3, H11 and the completion-latency workload spec

Written 2026-09-09 by Claude (peer). Draft for Codex review; a card is frozen only when Codex
commits it with the row in the registry. No code or remote change is made by this file.
Plan and metric definitions: `PEER_PLAN.md`. Sample protocol: `PEER_PLAN.md` section 1.4.

Card fields: id, status, mechanism, prediction, primary rows, non-regression rows, decision
rule, kill criteria, prior evidence, duplicate check, cascade entry, cost, what it will not
establish.

## H1: platform characterisation (measurement card)

- Status: proposed; may run now (S1 is allowed before the Phase 10/11 exit).
- Mechanism under test: none. Question: how do ns per pop, the non-search floor, weight refresh
  and the headroom-screen B differ across the hosts production actually uses, and how much do
  pinning and an SMT sibling change the tail?
- Hosts: m6i.8xlarge (done: B0), c6a.4xlarge (Codex provisioning), then one measured fleet-tail
  host if cheap (m5a.4xlarge, Zen 1, is the oldest in the inventory). No claim about a host not
  measured.
- Protocol per host: the B0 script unchanged (`run_baseline.sh`: 20234cc7, breakdown on,
  budgets 1,024 and 2,048 only for this card, three pinned fresh processes plus one unpinned),
  plus one "sibling busy" variant at 1,024: a spin loop pinned to the SMT sibling of the
  benchmark core (sibling from `/sys/devices/system/cpu/cpuN/topology/thread_siblings_list`),
  three repeats. Record `lscpu`, load, siblings, instance type, and the binary sha256.
- Outputs: per host and row, every repeat's p95 and max; ns per pop p50/p95; weight refresh,
  non-nav, request overhead p95; the largest B passing the screen on that host.
- Decision rule: the gate host for Phase 10 selection is the measured production host with the
  worst headroom result; m6i is reported alongside and labelled non-production.
- Kill: none (measurement).
- Prior evidence: B0 on m6i; the inventory in `platform-game-pods.json`.
- Duplicate check: DEVBOX_NUMBERS_1/2 measured m6i only, with the confounded harness.
- Cascade entry: C2/C3 directly (no code change).
- Cost: per host about 2 builds x 4 runs x 6 rows plus 3 sibling runs; instance-hours for c6a
  and any tail host.
- Will not establish: anything about code changes; anything about hosts not measured.

## H11: incremental per-seat packed-weight refresh

- Status: proposed; blocked until the Phase 10/11 exit (it is an algorithm change).
- Mechanism: on a danger-generation change each seat rebuilds its whole packed 4 px weight
  table (`packedWeights: seq[int16]`, ~172k entries on the largest pool lattice). Rebuild only
  the cells whose danger changed (the hot set and its dilation) and let cold anchors read the
  8 px value, so refresh cost scales with the changed region rather than the lattice.
- Prediction: `weight_refresh_p95_ns` from ~455-465 us to under 100 us in every row on m6i;
  whole-tick p95 down by 0.3-0.4 ms in rows where refresh sits on the tail (all 32-seat rows;
  16-seat p95 rows). Raw-pop capacity: about 500-600 more pops per tick at ~650 ns per pop if
  the screen is set by those rows.
- Primary rows: all six (refresh is present in all). Non-regression: quality gate all strata
  (route hash must be identical: weights are the same values, only when they are written
  changes), retained bytes, determinism.
- Decision rule: accept if weight refresh p95 improves in every row beyond the A/A spread and
  the route hash is unchanged; reject otherwise.
- Kill: route hash changes (means the refresh missed a cell); any per-seat state that grows
  with map size beyond what already exists; gain below A/A spread.
- Prior evidence: B0 split (`PEER_PLAN.md` 4.5); DEVBOX_NUMBERS_2 item (b) listed "per-seat 4 px
  weight table rebuilt wholesale at every danger generation" as a candidate; it was never run.
- Duplicate check: not in the exploration record's rejected list.
- Cascade entry: C0.
- Cost: low-medium (one module, `src/shell/body_nav.nim` weight refresh path; a focused test
  that compares full versus incremental tables cell by cell).
- Will not establish: anything about search cost per pop.

## H2: compact active-node workspace

- Status: proposed; blocked until the Phase 10/11 exit. Conditional on S1: run only if search
  time is at least half of the tick at the candidate B on the gate host (true on m6i at 4,096:
  2.4-3.1 ms of 3.9-5.0 ms).
- Mechanism: the shared resumable workspace is dense over the full 4 px lattice (~4.3 MB on the
  pool, 37 MB dense on colossal per the record), while 4 px nodes exist only in hot cells and
  the wall band. Give each hot or wall-band cell a dense slot in a compact array indexed through
  a per-map slot table built at index time; 8 px anchors keep their own dense array. The pop
  loop touches the compact arrays only.
- Prediction: ns per pop p95 down at least 20 percent on Ice Lake and Milan (fewer L2 misses);
  no change in pops per route; route hash identical.
- Primary rows: all six at the candidate B. Non-regression: quality gate all strata, colossal
  retained bytes within cap, determinism, activation time within its gate.
- Decision rule: accept if ns per pop improves beyond A/A spread on the gate host with the
  route hash unchanged; reject otherwise.
- Kill: route hash changes; colossal exceeds cap; activation gate fails; gain below A/A spread
  on the gate host even if the Mac improves.
- Prior evidence: exploration record rejected a *sparse* compact workspace (4-6x slower per
  pop); this is a dense-per-hot-cell layout, a different mechanism. Handoff step 2 makes it
  conditional on the split.
- Duplicate check: distinct from the sparse rejection; record the distinction in the row.
- Cascade entry: C0.
- Cost: high (body_route_query.nim workspace, body_route_index.nim slot table, tests).
- Will not establish: anything about pops per route.

## H3: pop-loop layout and width (three sub-cards, run in order)

- Status: proposed; blocked until the Phase 10/11 exit.
- H3a stamps: 16-bit generation stamps where the wrap is provably handled (generation reset on
  wrap); g values stay int32 unless a bound proof exists. Prediction: ns per pop down 3-8
  percent. Kill: any wrap hazard without a proof; gain below A/A spread.
- H3b layout: split the combined int32 cell table into arrays by access pattern (stamp and g
  hot in the pop loop, parent cold until reconstruction). Prediction: 5-15 percent. Kill: below
  A/A spread.
- H3c Dial buckets: size the bucket ring to the actual weight span and keep it in a separate
  small array. Prediction: 0-5 percent. Kill: below A/A spread.
- Primary rows: all six. Non-regression: quality, determinism, retained bytes.
- Decision rule per sub-card: accept on ns per pop improvement beyond A/A spread with route hash
  unchanged.
- Prior evidence: R4.2a (width-1 Dial, 182 ns per pop on the M4) and R4.2b (width-16 rejected);
  staged neighbour loop and prefetch did not move the M4. None on x86.
- Duplicate check: R4.2b is the only overlap and is a different parameter.
- Cascade entry: C0.
- Cost: medium.
- Will not establish: cache behaviour beyond what ns per pop shows; use Fluffy or perf counters
  in a separate profiled build if a mechanism claim is needed.

## 5. Completion-latency workload: minimal spec (harness only, `tools/`)

Purpose: the handoff's step 3 asks for the first-goal route-latency tail (p50/p95/max ticks at
16 and 32 seats) at the chosen B. `first_goals` cannot give it (resets every tick). Codex's
prereg and DECISIONS ask for a minimal implementation, not a framework.

Design (one new scenario in `tools/bench_body_nav_rework.nim`, no src change):
1. Add `ngsCompletionLatency = "completion_latency"` to `NavGateScenario`, run only under a new
   `--latency` flag so `--tick` rows and the canonical gate are byte-for-byte unchanged.
2. Wave loop: reset every seat once (`resetNavigationLife`), set all seats to the far goal
   (wave k even) or the near goal (wave k odd), then step ticks until every seat's
   `revision` has advanced past its value at the wave start, or a cap of 2,000 ticks is hit
   (a cap hit is a hard failure of the row). Record per seat the tick count from wave start to
   the first tick where `revision` advanced. Positions move by the produced masks exactly as
   the existing loop does, so steering during the wait is exercised.
3. Ten waves after one warm-up wave; report ticks-to-route p50/p95/max over all seat-waves,
   split by near and far, at 16 and 32 seats, plus the per-wave completion order (the SJF order
   is part of the evidence).
4. Determinism check inside the row: run the wave loop twice in the same process from a fresh
   episode and assert the per-seat tick counts and the route fingerprints
   (`installedRouteFingerprint`) are identical; emit `deterministic: true|false`.
5. Output fields: `ticks_to_route_samples`, `ticks_to_route_p50|p95|max` for near and far,
   `waves`, `cap_hits`, `deterministic`, plus the tick-time percentiles of the wave ticks as
   informational (not gated).
6. Acceptance for the harness change itself: focused build of the harness on the Mac; the six
   `--tick` rows' JSON identical in shape and, at fixed B and source, identical `pops_per_tick`
   arrays before and after the change (proves `--tick` is untouched); `--latency` output passes
   item 4 on two fresh processes; no new dependency; no src edit.
7. Prior art to reuse: the deleted `tools/investigate_body_nav_p10.nim` (visible at
   `git show 2906751b:tools/investigate_body_nav_p10.nim`) produced the P10.0 first-goal tables
   (for example B=12,288: 16-seat first-goal p50 3 ticks); its wave method can be lifted.

Owner: Codex (tools are Codex-owned). I review from disk against items 1-6.

## 6. Disagreements raised in this file
- H11's rank above H2: my case is the B0 split; Codex decides.
- H2's precondition uses "search at least half of the tick at the candidate B on the gate
  host"; if Codex prefers the handoff's wording ("pop slice dominates") we should define
  "dominates" numerically before H2 runs, not after.

## 7. Review of RESEARCH_LOOP.md and SCOREBOARD.md (per PEER_CHECKPOINT.md)

No material objection. The operational contract matches `PEER_PLAN.md` sections 1 and 2 and
`DECISIONS.md`; where they overlap, `RESEARCH_LOOP.md` is the contract and my plan is the
rationale. Three notes, none blocking:

1. The I0 row reports the breakdown-off binary's worst max at 4.433 ms at B=1,024, against
   2.785 ms worst max across all B0 pinned repeats at the same budget. That is the same
   single-sample-max shape seen in B0's 2,048 rows (`PEER_PLAN.md` 1.4). These maxima are
   observed single-sample events; shared-host noise is a plausible cause but has not been
   shown to be independent of the code. Suggest the loop record, per run, the largest
   sample and the second largest, so a future reader can tell a shifted tail from one event
   without reopening the JSON. This does not change any gate.
2. `RESEARCH_LOOP.md` step 5 should carry the DECISIONS rule that a card registers its primary
   rows and its all-row non-regression separately, so acceptance on a targeted card is not read
   as requiring every row to move.
3. The PLATFORM row counts 27 c6a.4xlarge of 33 running CTF containers; `PEER_PLAN.md` 4.2
   quotes Codex's earlier wording ("mostly c6a.4xlarge"); the scoreboard number is the one to
   cite from now on.

Cards H1, H11, H2, H3 and the completion-latency spec above stand as drafted. Ready for Codex's
card review and the next bounded unit (likely the latency harness, which I would implement
against section 5 items 1-6 under Codex's file ownership grant).
