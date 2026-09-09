# Navigation research loop

Living operational contract. Start here on resume, then read LEDGER.md, DECISIONS.md,
SCOREBOARD.md, and the latest registered card. Source survey: META_RESEARCH.md.
This implements the loop through the existing agent-collab tmux protocol, Git, shell runners,
immutable raw JSON, and a deterministic summary script. No new agent framework is needed.

## Scope and authority

Finish inherited Phase10/11 before optimization. Current units are baseline characterization,
profiling, protocol and infrastructure setup. Main checkout remains untouched; use this worktree.
Codex and Claude are co-equal: both may propose and criticize; no scientific acceptance comes
from an agent vote alone. Numeric checks own results. Current peer is nav-research-peer;
file ownership is stated in PEER_BRIEF.md and DECISIONS.md. Delegate workers into separate trees
and hand them off by session name and a durable card. Never run benchmarks concurrently on a host.
No Asana, pushes, PRs, publication or production mutation. Sandbox benchmark hosts are authorized.

## Per-unit sequence

1. Read prior negatives and select one hypothesis jointly. Write a card with mechanism,
   parent commit, files, expected effect, metric, source evidence, test corpus, host,
   repeat count, rejection criteria, resource estimate, and known limitations.
2. Freeze the card before first measurement. Keep the prior version plus checksum when
   amending. Use a local commit after documentation audit for code experiments. B0 and I0
   are preregistered measurement units whose cards were written before launching.
3. Implement one reversible change. Compile/test focused correctness first. Route-changing
   changes must pass original full 3072-case 0.5%/3% per-stratum quality limits and zero
   missing/illegal routes. Instrumentation-only changes must preserve work counts.
4. Evaluate on actual amd64 hardware with production-equivalent flags and whole-body timing.
   Store complete stdout/stderr, exit codes, source patch/commit, build/compiler/dependency and
   executable hashes, corpus hash, CPU/SMT/NUMA, pin, load, clock instrumentation and elapsed cost.
   Fluffy runs are separate diagnostics. Mac timings are informational; Docker quality is canonical,
   Docker emulated timing is not. Retained memory and cross-architecture determinism remain gates.
5. Register primary affected rows and all-row nonregression separately. Compare matched
   parent/candidate full-process repetitions, with A/A variability recorded.
   Do not bootstrap serial ticks as independent trials. Keep hard observed p95/max gates unchanged.
   Register any interval estimator before using it to decide acceptance. Never discard failures
   or rerun just for green. At most two repairs to an experimental idea before log/re-rank.
6. Append a scoreboard row, raw artifact links, costs, and what the result does and does not
   establish. Rejected experiments stay as negative evidence; return to accepted code without
   discarding anyone else's work. Ablate accepted changes before a combined improvement claim.
7. At milestones evaluate locked held-out routes/maps selected before optimization; do not tune
   to those. Original corpus remains an always-on gate. Qualify final budget, nine fixtures,
   GameVersion, viewer, docs, full tests, both compile shapes and paired containment as required.

## Metrics and claims

Report capacity in actual pops/tick, search ns/pop, pops/route, useful routes per fixed elapsed
search work, whole-body p95/max by scenario, completion p50/p95/max ticks, quality and memory.
The baseline for an improvement claim uses the same host, code workload and thresholds.
Budget selection uses 3.6ms p95 /4.5ms max headroom; ordinary tick gate remains4/5ms.
A raw-pop doubling and useful-work doubling are distinct claims. The handoff allows cheaper
pops OR fewer pops. Never claim doubling by changing the threshold, inflating useless work,
or replacing whole-body measurement with search-only time.

## Checkpoints and stops

Checkpoint at every unit and at40 experiments/20host-hours to reassess remaining mechanisms.
This is a replan point, not an invented spend cap or permission gate. Stop a broken hypothesis
on its predeclared rule; user halt stops all owned work. An external denial remains a blocker
for that action. A negative research campaign is reported honestly, never marked as2x success.
No unattended loop may mutate production or spin up unbounded hosts. Record every owned host
and its lifetime in LEDGER.md; stop/terminate it when no longer needed after retrieving evidence.

## Implemented commands

- B0: run_baseline.sh (on Xeon via SSH; fixed four-budget matrix).
- Validate and regenerate B0 reports: `python3 research/summarize_baseline.py` from evidence root.
- Fluffy: run_profile.sh, existing profile API around the harness --tick run.
- I0: run_instrumentation.sh, independent A1/A2 and instrumentation-off B builds, interleaved runs.
- Current results: B0_REPORT.md, B0_SUMMARY.json, B0_SHA256SUMS, PROFILE/summary.json.

Before S2: finish inherited qualification; finalize PEER_CARDS workload spec; register held-out
map indices and corpus generation command; validate actual production hardware baseline and I0.
