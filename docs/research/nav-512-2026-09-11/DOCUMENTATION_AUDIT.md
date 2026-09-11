# Documentation audit in progress

Scope: the current planner optimizations and their reproducible qualification.
The default remains 256 units per configured seat. No GameConfig, map override,
gameplay constant, memory capacity, public wire schema or rule is changed, so
ENV_VARIATION needs no knob update for H1-H3. Source comments explain the heap
store reduction, exact clearance certificate and helper trace tradeoff.

The research README, frozen cards, implementation notes, raw archives, hashes
and result JSONs separate intermediate wins from the unmet 512 objective.
H3 remains pending timing. The six-cell held-out protocol is frozen before
candidate held-out performance, with exact config hashes and failure rules.

Before the final source checkpoint:
- Correct body_nav.nim's unsupported claim that 8k units take only a few ms.
  Native original 32-seat frames can spend about 40ms on planning; total and
  tail timings are workload-dependent. Do not replace it with an unqualified
  benchmark constant.
- The supplied operating guide refers to tools/run_body_nav_gate.sh and
  bench_body_nav_rework, absent from this current shipped-planner tree. Those
  belonged to archived research and are not valid commands for H1-H3. Use this
  campaign's real-server scripts and existing tests instead; preserve history.
- Update the handoff/README to the final measured state and link this campaign.
- Verify all tracked source changes have a rebuilt viewer and current stamp.
- Re-fetch origin/main before committing and review any new conflicts/drift.

No claim of production qualification or publication is made by this audit.

Checkpoint audit: body_nav timing claim corrected; source rationale, current
results, lessons, validation and archive instructions updated. ENV_VARIATION
needs no value change. Viewer rebuilt; all2301current-base shard checks, both
build shapes and viewer-stamp check passed. H3production default remains256.
Latestmain aeeef5f4 adds only docs/offlineglorytools beyond58e6c947; src runtime
bytes are unchanged, so the current-main native binaries remain applicable.
