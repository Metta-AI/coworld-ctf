# Research loop, resumed September 11

Active objective: candidate at 512 pooled work units/cog/tick must not slow the
whole game versus current code at 256, while preserving legality, route quality,
determinism and memory gates. This supersedes the archived rewrite's capacity
objective and 4/5ms gate for this campaign. Old Phase10/11 work is not falsely
marked complete. Budget changes may change masks and require final GameVersion,
fixtures, viewer and docs before any eventual shipping; no publication now.

Reuse the established hypothesis-card -> focused correctness -> native paired
screen -> held-out/full qualification -> scoreboard loop documented in the
archived RESEARCH_LOOP.md and META_RESEARCH.md. Existing tmux, Git, Python,
Fluffy and test suites suffice; no new research framework dependency.

Root owns native host and measurements; Claude (nav-512-peer) owns its separate
worktree and hypothesis review. Plans/feedback/results live in files. Each
experiment gets one mechanism, source/base hashes, fixed inputs, a written
prediction, rejection criteria, raw records, and explicit limits. Both partners
review claims. A negative stays negative. Do not compare profiled candidate
against an unprofiled baseline; profiling is diagnostic only. Native execution
is required for timing. All routes/work counts must match the unmodified
planner at the SAME budget for output-preserving changes; then compare the
candidate at512 to baseline256 for performance and route-wait benefit.

P0: Fluffy diagnostic on the existing 32-seat finite real game, budgets256/512,
1200 ticks. Add only main-thread markers around planner and minter calls and
whole server frame. Retain trace and verify plan counters match unprofiled
same-budget screen. Measure calls before deciding where to optimize. No timing
acceptance claim from P0. Current host is an owned sandbox m5a.4xlarge. The fleet refresh found games
in softmax-tournament; see HARDWARE.md for the read-only node/pod/image join,
credential-scope limitation, and remaining common-family qualification.

After P0, agree candidate gates and held-out workloads with Claude before
candidate timings. At minimum compare per-process median/p95/max, deadline
miss counts, total measured work time, and navigation wait/legality. Never
call a median win success while regressing the long tail. No clocks in route
choice or relaxed quality gates. Preserve exact failures and alternate proposals.
