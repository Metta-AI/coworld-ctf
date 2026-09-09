# L1: exact packed-table identity

Parent L0 c5f39376; subsequent main sync changes only tools/glory. L0 failed
completion despite exact ordered-source reuse. L1 adds one shared int16 table
scratch, explicitly counted in shared retained navigation memory. Rebuild
into scratch, compare every value, swap and advance generation only when
changed. Forced initialization remains forced. Installed-route expiry remains
on each cadence. No hash-based identity or continuation across changed costs.
Avoid clearing an already empty installed-route array on an L0 reuse hit,
matching the original changed-input path's revision check.

Acceptance: focused reorder/job-preservation/changed-cost and buffer-ownership
tests; full corpus hash unchanged; every pool shared <=16MiB and total<=256MiB;
two real-EC2 latency processes with all seat-waves completing within2000ticks.
Retain any failures, rounding-induced restarts and censored tails. Three
interleaved parent/candidate B1024 timing processes; this is a liveness candidate,
not a claim of reducing the initial danger rebuild floor or doubling throughput.
