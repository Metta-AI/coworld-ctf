# Documentation audit

Scope: the current planner optimizations and their reproducible qualification.
The default remains 256 units per configured seat. No GameConfig, map override,
gameplay constant, memory capacity, public wire schema or rule is changed, so
ENV_VARIATION needs no knob update for H1-H3. Source comments explain the heap
store reduction, exact clearance certificate and helper trace tradeoff.

The research README, frozen cards, implementation notes, raw archives, hashes
and result JSONs separate intermediate wins from full 512 qualification.
H3 passed training; held-out and fleet qualification remain in progress. The six-cell held-out protocol is frozen before
candidate held-out performance, with exact config hashes and failure rules.

The source-checkpoint audit covered:
- Corrected body_nav.nim's unsupported claim that 8k units take only a few ms.
  Native original 32-seat frames can spend about 40ms on planning; total and
  tail timings are workload-dependent. Do not replace it with an unqualified
  benchmark constant.
- The supplied operating guide refers to tools/run_body_nav_gate.sh and
  bench_body_nav_rework, absent from this current shipped-planner tree. Those
  belonged to archived research and are not valid commands for H1-H3. Use this
  campaign's real-server scripts and existing tests instead; preserve history.
- Updated the research README to the final measured state and link this campaign.
- Verified all tracked source changes have a rebuilt viewer and current stamp.
- Re-fetched origin/main before committing and checked runtime drift.

No claim of production qualification or publication is made by this audit.

Checkpoint audit: body_nav timing claim corrected; source rationale, current
results, lessons, validation and archive instructions updated. ENV_VARIATION
needs no value change. Viewer rebuilt; all2301current-base shard checks, both
build shapes and viewer-stamp check passed. H3production default remains256.
Latestmain aeeef5f4 adds only docs/offlineglorytools beyond58e6c947; src runtime
bytes are unchanged, so the current-main native binaries remain applicable.

Follow-up evidence audit: all twelve current-base correctness games and six
training games passed; held-out performance is still running. Peer restore
audits verified exact source reconstruction, frozen cards/configs and archives.
Guest bytes and H1 hash sidecar are now archived, patch extraction is explicit,
and a viewer QA record identifies c651dec9. New fleet scripts implement the
unchanged preregistered card; no production source or input changed. Fetched
origin/main 9f61d669 adds documentation/offline tooling only, with unchanged
runtime sources. No new broad source test run is warranted for these records.
