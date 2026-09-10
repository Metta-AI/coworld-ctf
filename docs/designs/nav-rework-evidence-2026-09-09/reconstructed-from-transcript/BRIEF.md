# Implementation brief: precomputed shared cog navigation (nav rework)

You are the implementation lead for this rework. Claude orchestrates, reviews from disk, re-runs your tests independently, and gates each phase. James Boggs is the owner; he approved the design and asked for it to be implemented now.

## Ground truth (read in this order, all read-only)
1. Design document (approved, Codex-reviewed GO): /Users/jamesboggs/coding/coworlds/coworld-ctf/docs/designs/nav-rework-2026-09-04.html — read the source brief instead, it is the same content in Markdown: /Users/jamesboggs/coding/coworlds/coworld-ctf/docs/designs/.nav-rework-brief.md
2. The collab record that produced it (your own reviews): /private/tmp/claude-501/-Users-jamesboggs-coding-coworlds-coworld-ctf/3d57efa8-dd72-43f4-8a00-809d9728282b/scratchpad/collab/REVIEW.md, VERDICT.md, VERDICT2.md, RESPONSE.md, RESPONSE2.md
3. Measured topology and probe sources: /private/tmp/claude-501/-Users-jamesboggs-coding-coworlds-coworld-ctf/3d57efa8-dd72-43f4-8a00-809d9728282b/scratchpad/impl/nav_census.tsv, seg_probe.tsv, cell_probe.tsv, cell_probe.nim, seg_probe.nim (scratch probes; reuse ideas, not code)
4. Repo rules: AGENTS.md in the worktree (GameVersion, nine replay fixtures, viewer rebuild, pull-before-work, sim-sources stamp). docs/designs/strategy-play-calling-shell-2026-08-29.md and docs/designs/BR_PLAYS.md are the authoritative Season 2 rules surfaces; update them where behavior changes.
5. The Asana parent task 1218165906459726 defines the gates; the brief section 6 restates them verbatim. Its eleven subtasks, in order:
   01 Freeze the route corpus and add failing liveness and no-live-search tests
   02 Build and gate the immutable shared BodyRouteIndex
   03 Implement bounded hierarchical route queries over precomputed segments
   04 Add precomputed danger scoring and an immutable zone-hazard overlay
   05 Expose stable safety hints and zone-safe semantic targets to plays
   06 Coalesce literal and semantic goals against stable route anchors
   07 Add deterministic local steering and reset all per-life navigation state
   08 Land route, hazard, wire, lifecycle, and diagnostic regressions
   09 Pass all-map route quality, activation, memory, and 16/32-seat tick gates
   10 Remove live full-grid planning and version the gameplay and wire change
   11 Run final server, shell, replay, viewer, and documentation verification
   Dependency edges: 01 -> 02 -> 03 -> {04, 05}; 01 -> 06; {03,04,05,06} -> 07 -> 08 -> 09 -> 10 -> 11.

## Your workspace
- Worktree: /Users/jamesboggs/coding/coworlds/coworld-ctf-worktrees/nav-rework, branch james/s2-nav-rework, based on origin/main. Work ONLY there. Never touch /Users/jamesboggs/coding/coworlds/coworld-ctf (the main checkout) or any other worktree.
- Commit on the branch at every logical checkpoint (agent-optimised messages, match git log style). Do NOT push, open PRs, merge, edit Asana, or post anywhere.
- Build/test recipe on this Mac (nix develop is broken on darwin; do not set METTA_USE_NIX, do not bypass guards):
  sh tools/runtime_spike/fetch_deps.sh   (already run; prints the paths)
  export WASMTIME_C_API=/Users/jamesboggs/coding/coworlds/coworld-ctf-worktrees/nav-rework/tools/runtime_spike/.deps/installed/aarch64-macos/wasmtime-c-api; export C_INCLUDE_PATH=$WASMTIME_C_API/include LIBRARY_PATH=$WASMTIME_C_API/lib DYLD_LIBRARY_PATH=$WASMTIME_C_API/lib
  nim c -r -d:release -d:noSignalHandler --threads:on tests/test_shell_body_nav.nim   (same shape for other tests)
  Both compile shapes must pass: runtime-linked (env above) and runtime-stub: env -u WASMTIME_C_API nim check -d:noSignalHandler --threads:on src/ctf.nim
  Full suite: nim c -r -d:release tests/tests.nim (and the shard files under tests/ that CI runs; read .github/workflows/build.yml).
  nimby is already synced (repo nim.cfg carries the package paths). If a dependency is missing, run nimby sync against nimby.lock; never install globally.
- The canonical performance gate is linux/amd64 Docker (Nim 2.2.4). Measure locally on arm64 for development, but the gate run in subtask 09 must use the Dockerfile in the repo (or a documented equivalent); if Docker is unavailable, say so in the report and record arm64 numbers as provisional. Do not claim a gate passed on the wrong platform.

## Non-negotiables (from the task; the design brief section 0 and 6 have the full list)
- No full-board search of any kind on an active play tick; bounded queries only; per-seat query state has no map-sized arrays.
- Deterministic: no clocks, threads, async, pointer identity, hash iteration order in route choice. Integer fixed-point costs as designed.
- A living cog with a valid goal moves on the same tick (steering when no advancing route).
- Routes legal, same validated goal/component; cost-inflation gate p95 <= 3.0 % / max <= 10.0 % per stratum against the float oracle; body slice p95 <= 4.0 ms / max <= 5.0 ms at 16 and 32 seats; activation <= 2x (pool) / 3x (colossal) baseline; retained shared nav data <= 16 MiB / 32 MiB.
- Consume the zone damage surface (never arrival), gate on zoneDamageByPaint, elapsed zone tick passed into the step.
- GameVersion bump, all NINE fixtures re-recorded, static-replay-viewer rebuilt (Docker) — only in subtask 10/11 after gates pass.
- Do not change cover selection/scoring, combat policy, fog rules, play strategy. Navigation treats every ValidatedGoal identically.
- Cover-hold task 1218165969208626 has NOT landed (still Blocked upstream). Keep navigation independent of it: leave the "cold transition to a cover goal" corpus row as a clearly marked TODO gated on that task; everything else proceeds.
- Follow the repo's existing patterns (activation-barrier constructors, ValidatedGoal opacity, diagnostic state enums, test file conventions). Minimal diff within those patterns; no new dependencies.

## Protocol with Claude
- Content in files, pane for signals. Write everything of substance into /private/tmp/claude-501/-Users-jamesboggs-coding-coworlds-coworld-ctf/3d57efa8-dd72-43f4-8a00-809d9728282b/scratchpad/impl/: PLAN.md, LEDGER.md (running decisions/progress), PHASE_<n>_REPORT.md.
- Phase 0 (now): write PLAN.md. It must map phases to the eleven subtasks (you may group 04+05 and 08+09 if justified), and for each phase list: files to add/change, the new types and procs (names + signatures), the tests written first (fail-before-fix), the gate or check that closes the phase, and the commit boundaries. Include the corpus design for subtask 01 (literal manifest format, strata, oracle), the index data layout with byte accounting, the query algorithm in pseudocode with the fixed-point rules, the lifecycle state list to clear on death, and the benchmark harness plan for 09. Call out every place where the design brief is underspecified and state the decision you will take. End your reply with the literal line PLAN DONE and stop.
- Wait for Claude's message PLAN: GO (or a REVISE list) before writing any code.
- Then implement phase by phase. At the end of each phase: all tests for that phase pass in the worktree, commits are made, PHASE_<n>_REPORT.md exists (what changed, exact commands run with real output excerpts, gate numbers, open risks), and your reply ends with the literal line PHASE <n> DONE. Do not start the next phase until Claude sends PROCEED P<n+1>.
- If a gate fails, report the failure with numbers and a proposed fix; never weaken a gate, delete a test, or bypass a guard to get green.
- Keep replies short; the files carry the content.

## Commit drift
The design brief cites line numbers at commit fad3029f. Your worktree is at origin/main 429f4831, which includes #415 (fog-safe hazards, kill feed, aggressors and shouts fed into each cog body) and possibly other changes to body.nim/body_nav.nim/episode.nim. Before planning, diff fad3029f..429f4831 for src/shell and src/ctf and re-verify every citation you rely on; record any drift that changes the design in PLAN.md.
