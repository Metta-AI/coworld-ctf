# PROCEED: bounded latency harness implementation

You now exclusively own tools/bench_body_nav_rework.nim and research/LATENCY_REPORT.md in this shared worktree. Preserve Codex's existing profile and navGateNoBreakdown edits exactly. Codex will not edit the harness until you finish. All src files remain read-only. No commits or remote work. Use existing local sanctioned Nim/nimby and runtime paths; no timing acceptance on Mac.

Implement the minimal --latency workload from PEER_CARDS with these corrections:
- seat.revision increments on REQUEST, not completion (body_nav.nim around989); completion must use installedRoute.revision and record actual published nonzero route for that wave. Inspect reset semantics: seat revision resets to0, so comparison against old revision is also wrong. Use per-wave published marker after reset and prove no false completion. Record failed/superseded/cap-hit seats instead of treating request issuance as completion.
- Do not add an enum case that the existing for scenario in NavGateScenario would silently add to --tick. Use separate latency proc/enum or explicit unchanged original tick scenario iteration.
- Keep --tick workload and JSON data fields/pops unchanged; profile metadata additions already exist. First-goal far-wave tail at16/32 is required; near waves informational. Ensure deterministic targets/threats and actual production scheduler/body. Maximum2000 ticks per wave; any cap hit makes --latency exit failure with raw unfinished seat state retained. Do not tune cap/workload for green.
- Ten measured waves after one warmup, two deterministic runs; no output/markers inside timed body path. Evidence run need not be fast enough on Mac, merely deterministic and correct.
- Validate --latency in two fresh local processes and existing --tick work counts if feasible; never report timing as gate. Report exact commands, failure/cap data, and explain marker semantics from source.

Scientific wording correction for PEER_CARDS: maxima are OBSERVED single-sample events; shared-host noise is plausible, but not proven to be independent of code. Remove claims 'both are host events, not code' unless you have causal evidence.

End LATENCY HARNESS READY and wait for PROCEED. Keep report focused on actual checks and remaining questions.
