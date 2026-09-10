# H1 native screen: useful work improves; timing and far-tail gates remain unresolved

Frozen parent3aeb0398, m5a CPU5, Nim2.2.6/GCC11.4, B1024. Separate builds and three interleaved pairs at331px and1300px. Full candidate3072-case quality reproduces the Mac hash ee2488d32085fb4de3457c4cf841298c14b87add2225964d934f80f2a7c1013d and31,814,084pops. Aggregate quality is unchanged; route identity is intentionally different (see H1-screen-summary.json).

| Range | Parent worst p95/max ms | Candidate worst p95/max ms |
| --- | ---: | ---: |
|331px|3.948734 /4.080697|3.967364 /4.326134|
|1300px|5.208640 /5.251901|5.269882 /5.629607|

No whole-body speed improvement is established. Both1300px arms fail4/5ms, and both331px arms miss3.6ms selection headroom. Across18 rows per range, candidate completes789routes versus462 (1.708x), while consuming2,082,492 versus2,193,294pops. This is useful work in the fixed synthetic workload, not a fleet throughput qualification or2x result.

One paired latency process per arm uses frozen331px. Near-goal p50/p95/max ticks improve18/48/51 to8/16/17 at16seats, and50/133/140 to15/36/41 at32seats. Far-goal completed-only p95/max worsen1129 to1165 at16seats and1169 to1968 at32seats; medians remain82. Both arms hit the2000tick cap on all five measured far waves per roster. Unpublished seat-waves are65/145 in parent16/32 and65/144 in candidate. These are censored tails, not acceptable all-seat latency percentiles or proof of a new failure SLA. SJF starvation remains.

Decision: retain H1 as a promising isolated candidate pending a joint review of the far-tail tradeoff and final integrated validation. Do not copy it into production source yet. Its near-goal benefit is real in this workload, but it does not solve the whole-body floor or final budget selection. Raw results, source patches, hashes, exit codes and completion marker are H1-m5a/; run_h1.sh is the recipe.

Documentation audit: production source, caps, B1024 and route hash are unchanged. Candidate claims are confined to these experiment records; final gameplay/version/fixture documentation remains pending an adoption decision.
