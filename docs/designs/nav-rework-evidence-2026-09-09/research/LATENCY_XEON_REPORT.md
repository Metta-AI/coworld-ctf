# Xeon completion-latency baseline

Two fresh CPU5-pinned processes at source20234cc7, B1024, Nim2.2.6 have
identical non-timing results, including each in-process deterministic repeat.
Each measured far wave hits the2000tick cap without any published route:
80 unpublished seat-waves at16seats and160 at32seats. Near p50/p95/max are
18/48/51ticks at16seats and54/135/141 at32seats. This reproduces the Mac
outcomes on real EC2 hardware. Raw data: LATENCY-xeon/r1.json and r2.json.

A completion tail cannot be reported as zero: there were no observed far
completions. The tail is censored beyond2000ticks in this workload. The
unchanged-danger restart mechanism is traced in LIVENESS_REVIEW.md; L0 is
registered to test a narrow fix while preserving installed-route expiry.
