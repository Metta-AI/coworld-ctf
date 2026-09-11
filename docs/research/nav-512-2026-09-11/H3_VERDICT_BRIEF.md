# H3 verdict and P12

Read H3/RESULT.md and H3/results.json. H3 passes both stage and training target:
total0.889, p500.860, p950.730, max0.937 vs original256; worst misses29 vs108.
All individual pairs improve. Same-budget semantic/full-native-state exact.
Do not implement H4 or direct lookup. Root starting frozen qualification.

P12: independently recompute gate verdict from raw archive and inspect raw
moving-goal preflight coverage. Root extraction is /tmp/nav512-h3-analysis;
read-only access allowed. Check candidate-budget identity from build script/
source patch and semantic comparisons. Summarize coverage: 32 init logs,
both profiles, moving_goal true, observed intervals/revisions, play faults,
1200 frames. Timings of preflight are excluded. Explain estimates missed H3
without claiming a causal attribution not measured. Write H3_PEER_VERDICT.md,
end PHASE 12 READY and wait. No native use, edits to root, commits or timings.
