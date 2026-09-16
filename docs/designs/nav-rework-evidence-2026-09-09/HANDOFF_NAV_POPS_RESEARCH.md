# Handoff: navigation throughput research on production-class hardware

Written 2026-09-09 by Claude (orchestrator of the nav rework so far) for a NEW Codex session.
Prior transcript: https://claude.ai/code/session_01H4Tq8mKE8YCb7mvENxWfct (session_01H4Tq8mKE8YCb7mvENxWfct).
Owner: James Boggs. You have carte blanche for effort and spend; James asked for a durable, potentially long-running scientific auto-research endeavour.

## 0. Your working arrangement (James's instruction, verbatim in substance)

You are a Codex instance. You MUST collaborate with a Claude Code instance as co-equal research partners using the `agent-collab` skill (tmux-driven peer collaboration; the Claude side has the skill at ~/.claude/skills/agent-collab, read its references/tmux-protocol.md, and drive Claude in a tmux session, or let Claude drive you; either direction works). Neither of you is the boss. Together you:
- generate hypotheses, rank them, and decide experiments;
- spin up sub-agents (Codex or Claude) in tmux sessions to implement and run experiments, and SHARE those sub-agents between you (one partner can hand a running session to the other by name);
- use Fluffy for profiling (repo AGENTS.md "Profiling build": `-d:ProfileTracePath=<path> -d:ProfileTicks=N`, `{.measure.}` markers on the game thread only, `tools/run_shell_demo.sh` with SHELL_EXTRA_NIM_FLAGS; the profiling-coworld build script is tools/build_profiling_coworld.sh). In the previous campaign Fluffy was requested but the per-stage numbers came from harness counters; actually use it this time and keep trace artifacts;
- keep a scoreboard and a written record that a future agent can audit (see section 6).

One of your FIRST tasks: do meta-research on state-of-the-art auto-research loops for agents (e.g. AI-Scientist-style loops, AutoResearch/ResearchAgent patterns, Sakana, Nous, "agent laboratory", program-synthesis-by-evolution loops such as AlphaEvolve/FunSearch-style search over code, OpenEvolve, etc.) and best practices (hypothesis registries, pre-registration, ablations, held-out validation, negative-result logging, reproducibility manifests, budget accounting, stopping rules). Then implement the loop you choose for THIS problem before running the main experiments. Write it down as a living document.

## 1. The goal

Maximise the number of search pops per game tick that fit inside a 5 ms whole-body tick on the hardware production actually runs on, WITHOUT sacrificing route-planning quality.

- Step 1 (mandatory, first): establish the baseline: how many pops does HEAD of `james/s2-nav-rework` fit in 5 ms right now on the EC2 box, with the whole-body tick measured (not the search alone), at 16 and 32 seats, across the three scheduler scenarios (first_goals, moving_goals, stuck_replans).
- Target: at least DOUBLE that number. That does NOT mean "find the largest budget the current code fits"; it means make the code fit more pops per millisecond (and/or need fewer pops) while the route-quality gate keeps passing.
- Quality is non-negotiable: the corpus gate (3,072 cases, per-stratum p95 <= 3.0 %, max <= 10.0 %, zero missing/illegal) must keep passing; today it passes at 0.313 % / 0.829 %. Any experiment that moves inflation must say so.

## 2. The platform: measure on the real thing, not this Mac

- The M4 Mac is ~3x faster per pop than the prod-class Xeon, and Docker linux/amd64 on the Mac is emulated (slower than both). James ruled: NO tick gating on the Mac or under emulation. Tick numbers come from EC2 only.
- The prod-mirror devbox `jamesboggs-box-2` (m6i.8xlarge, Intel Xeon Platinum 8375C Ice Lake @ 2.9 GHz, 32 vCPU) is where the numbers in section 4 were taken. Recipe: see `docs/designs/nav-throughput-notes-2026-09-09.md` in the main checkout (same file as `NAV_THROUGHPUT_NOTES.md` in the collab dir; agent-agnostic, not a Claude memory file) (checkout `~/coworld-ctf-nav`, nimby sync, fetch_deps, the `-d:noSignalHandler` trap, `taskset` pinning, results in `~/nav-bench/`). Public IP moves; last known 3.81.19.75; private ip-172-31-46-120.
- BUT the devbox is NOT necessarily the prod instance type. Production game pods are scheduled by Karpenter into the `jobs-warm` NodePool (metta repo devops/charts/tournament/values.yaml + templates/nodepools.yaml): capacity-type spot with on-demand fallback, instance-category in {c, m, r}, instance-generation > 4, arch amd64, CPU-count-based selection. So the actual CPU varies per node (Intel Ice Lake / Sapphire Rapids, AMD Milan / Genoa are all possible). Crucial first step: discover the instance types ACTUALLY hosting game pods (prod kube context via the `k8s-log-inspection` skill: node labels `node.kubernetes.io/instance-type` for nodes in the jobs pool; or the Datadog facet `@node.instance_type` used in devops/datadog/dashboards.py), then benchmark on THOSE instance types (spin up an EC2 of that type via `metta box`, or ask James). The game pod's CPU request is 1 vCPU (COWORLD_GAME_CPU_REQUEST = "1", no limit by default; paintbot manifest sets none for the game), so pin to one core for the conservative case and also measure unpinned burst.
- Treat platform knowledge as a lever: cache sizes (Ice Lake 8375C: 1.25 MB L2/core, 54 MB shared L3), NUMA, SMT siblings, spot-instance variability, memory bandwidth. Measure, do not assume.

## 3. Where the code is

- Branch: `james/s2-nav-rework` in the worktree `/Users/jamesboggs/coding/coworlds/coworld-ctf-worktrees/nav-rework` (not pushed; main checkout at /Users/jamesboggs/coding/coworlds/coworld-ctf is James's, treat read-only). ~90 commits ahead of origin/main. Latest production state at handoff: cutover done (`7fa6dafb` "Replace body routes with resumable mixed-grid search"), legacy planner deleted, GameVersion 63 claimed, fixtures + viewer recorded at a provisional budget, budget constant `BodyRoutePopBudgetPerTick` in src/shell/body_route_query.nim (4,096 at handoff; a 1,024 detour was reverted). A Codex session (tmux `codex-impl`) may still be finishing Phase 10 items: check `git log`, the tree, and `~/coding/coworlds/coworld-ctf-worktrees/nav-rework-collab/impl/PHASE_10_REPORT.md` before touching anything.
- Durable collab/evidence dir: `/Users/jamesboggs/coding/coworlds/coworld-ctf-worktrees/nav-rework-collab/` (impl/ has every phase report, campaign scoreboard, redirects, devbox numbers, LEDGER.md). The macOS temp cleaner deletes /private/tmp scratchpads: never keep evidence there.
- The exploration record (what was tried, outcomes, what is NOT established): `/Users/jamesboggs/coding/coworlds/coworld-ctf/docs/designs/nav-rework-exploration-record-2026-09-09.md` and evidence copies in `docs/designs/nav-rework-evidence-2026-09-09/` (untracked). Design doc: `docs/designs/nav-rework-2026-09-04.html` (its "no full-board search" rule was superseded by James's ruling; see section 5).
- Key modules: src/shell/body_route_query.nim (mixed-grid resumable search, Dial queue, SJF admission, descriptor install), body_route_index.nim (8 px rooms/portals, 4 px legality table, wall band, contracted chains, pocket connectors), body_hazard.nim (zone paint overlay, safe cache), body_nav.nim (coordinator, steering, hints, lifecycle), body_map.nim (immutable terrain, legality predicate). Harness: tools/bench_body_nav_rework.nim (`--tick --quality --activation --all --corpus tests/fixtures/shell/nav_route_corpus.json`), tools/run_body_nav_gate.sh (Docker canonical; tick rows are NOT gated per James), tools/investigate_body_nav_p9*.nim / p10 (measurement tools from the campaign).

## 4. What is already known (measured; details and caveats in the exploration record)

Algorithm that passes quality (campaign "R3.3"/"R4.4"): 4 px nodes only in cells with danger > 0 (dilated 1 cell) plus the static wall band; 8 px anchors elsewhere with cold edges contracted over exact precomputed 4 px chains; exact width-1 Dial bucket queue; one shared resumable workspace; stable shortest-job-first admission; per-tick pop budget; production steering while a seat waits. Rejected on measurement (see record for the exact criteria): ALT landmarks (only ~1 % fewer pops, more latency), corridor restriction (loses alternate rooms, max 80 %), width-16 buckets, in-tick 1,024-pop probes, warm starts (no pop savings), neighbour prefetch, extra workspaces, sparse compact workspace (fits colossal but 4-6x slower per pop).

Per-pop cost: ~185 ns on the M4; roughly 3x that on the Ice Lake core. Rough attempts at micro-optimisation (staged neighbour loop, prefetch) did not move it on the M4.

EC2 (one pinned Ice Lake core), whole-body tick p95/max in ms, 16 seats | 32 seats:
- B=1,024: first 2.15/2.17, moving 3.89/4.65, stuck 2.26/2.29 | first 2.41/3.75, moving 5.36/5.45 (FAIL), stuck 2.50/2.58
- B=2,048: first 2.79/4.07, moving 4.61/5.28 (FAIL), stuck 2.96/3.12 | first 2.96/2.98, moving 6.12/6.28 (FAIL), stuck 3.28/3.37
- B=3,072: first 3.32/3.39, moving 5.36/6.28 (FAIL), stuck 3.78/3.89 | first 3.56/3.61, moving 7.11/7.59 (FAIL), stuck 3.96/4.94
- B=4,096: first 3.91/3.93, moving 6.15/6.85, stuck 4.49/7.29 | first 4.11/4.15, moving 7.44/7.69, stuck 7.79/8.12
- B=8,192 and 16,384: 6-15 ms, all fail.
Two structural facts: (a) the non-search body floor is ~1.7 ms (16 seats) / ~2.0 ms (32 seats) on this core; (b) moving_goals fails at EVERY budget because each replan REQUEST costs ~1 ms OUTSIDE the pop budget (endpoint attach ring scan + exact connectors, per-seat 4 px weight-table refresh at each danger generation (172k int16 per seat), reconstruct + validateBodyRoute + install). Cutting that per-request overhead is the first throughput win; a Codex session was profiling it at handoff (look for "X86 OVERHEAD DONE" / a split-instrumented harness in the collab dir).
Containment test on the same box: origin/main 16.4 ms max_body, HEAD 9.6 ms; its 5.6 ms gate is host-calibrated and fails on main too. Pair it with a same-box main baseline; never read it as a nav pass/fail.

## 5. Rules and rulings in force

- James's rulings (2026-09-09): (1) production nav is a pop-budgeted resumable search over the precomputed legal graph with one shared workspace, deterministic admission and steering covering the wait; (2) budget chosen from real-hardware integrated measurement; (3) colossal cap raised with int16 weights, but colossal must be made efficient too; (4) no emulated/local canonical tick gate.
- Determinism is absolute: no clocks, threads in route choice, pointer identity, hash-iteration order; replays re-drive masks; identical route hashes across arm64/amd64 are currently proven and must stay so. Threads for the search were never tried and are NOT forbidden by James for exploration, but a threaded search must stay deterministic (e.g. per-seat independent workspaces with fixed assignment) and must be measured on the pod's 1-vCPU request reality.
- Memory: per-seat state must not be map-sized; shared retained nav data <= 16 MiB on pool maps (colossal cap raised, number set from measurement).
- Movement masks change => GameVersion bump + all NINE replay fixtures (AGENTS.md) + static-replay-viewer rebuild (Docker) + docs, once per shipped change, not per experiment.
- Repo hygiene: never push, PR, merge, or edit Asana without James; commit experiments on revertible checkpoints with scoreboard rows in the message; do not modify James's main checkout; the devbox runs a live tournament from ~/metta: do not touch ~/metta there (use the separate coworld-ctf checkouts).

## 6. Suggested research programme (hypotheses to rank, not a script)

Throughput levers, roughly by expected payoff on x86:
1. Per-request overhead (section 4b): make validateBodyRoute debug-only or incremental; attach without pixel segmentClear per candidate (precompute connector legality for anchor rings); refresh per-seat weight tables incrementally (hot cells only; cold anchors need only the 8 px value); avoid re-walking descriptors on install.
2. Cache behaviour on x86: the dense 4 px workspace (~4.3 MB pool) and Dial bucket arrays vs 1.25 MB L2. Options: compact active-node indexing for fine nodes only (a dense slot per hot/wall-band cell, not per lattice point), structure layout (AoS vs SoA), 16-bit stamps/g where safe, bucket array sizing, prefetch that actually helps on Xeon, hugepages, allocator (`-d:useMalloc` vs Nim's), `--passC:-march=<prod arch>` only if the production Docker build can carry it.
3. Fewer pops for the same routes: better admissible heuristics that are consistent on the mixed grid (the previous ALT attempt used an inconsistent potential and gave ~1 %; a consistent differential heuristic over the 8 px graph, or hierarchical bounds from the room graph, may do far better); bidirectional search; goal-side pruning; reuse of a previous search's closed set across a danger generation (incremental A*/LPA*/D* Lite ideas, previously rejected only in the old design's static-topology context); jump-point-like skipping restricted to zero-danger regions (danger makes costs non-uniform, but cold regions are uniform).
4. Scheduling: pops per tick vs latency tails (SJF is in); time-to-route matters to play only weakly (steering is within 2 % of ideal), so favour throughput.
5. Platform: exact prod instance types (section 2), core pinning vs burst, SMT, spot variability; measure per-pop ns per instance family and pick the worst as the gate.
6. SOTA navigation research online: grid/any-angle pathfinding with non-uniform costs (Theta*/Lazy Theta*, Anya, JPS+ with goal bounding, CPD/compressed path databases for static parts, contraction hierarchies over the static 8 px graph with dynamic overlay, "hierarchical A* with danger-adaptive resolution" which is what we have), and GPU/SIMD-free CPU tricks for A* inner loops.
Each experiment: pre-registered hypothesis, metric (pops/ms on the pod hardware, whole-body p95/max, corpus inflation, retained bytes), one commit, a scoreboard row, and a "what this does/does not establish" line. Log negative results.

## 7. Deliverables James expects

- A living research log + scoreboard in the durable collab dir (and copied into docs/designs/ when milestones land), with the transcript/session pointers.
- The baseline number first, then the best achieved pops-per-tick under 5 ms on the real prod hardware, with route quality unchanged, and the production budget set from it.
- When a change ships: GameVersion, nine fixtures, viewer, docs, Asana task 1218165906459726 updated (Claude side can do Asana via MCP), PR via Graphite only when James asks.
