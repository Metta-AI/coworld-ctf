# H2 experiment card

Registered before any H2 timing. Use the same nine-run order, server flags,
CPU affinity, exact saved game inputs, 32 seats and 1,200 ticks as H1_CARD.md.
Create a new results directory; do not reuse the timed processes or discard
runs. Correctness first: native independent original-segment differential,
existing navigation suite, cross-build fingerprints and same-budget game
semantic stream. H2 changes only segmentClear; no allocations or units change.

Candidate selection rule, fixed before reading H1 timings: if H1 passes its
registered screen, test H1+H2; otherwise test H2 alone on parent 6b6b3408.
Keep separate source patches. Compare candidate512 with parent512 (intermediate
optimization) and parent256 (512 target), with the same ratios and thresholds
as H1_CARD.md. The intermediate total-frame threshold remains <=0.98; all
median paired p50/p95/max ratios <=1.00 and worst deadline misses cannot rise.
No burst exclusions. This remains a training scenario, not full qualification.

Run P1 sampling only between completed screens. No profiling, building or
compressing artifacts on the native host during the nine timing processes.
