# L1 result: false cancellation removed, completion target still failed

One shared int16 scratch table holds each rebuilt packed field. Exact table
comparison preserves the search generation only when its input values are
identical; a changed table is swapped in and invalidates before another pop.
Public initialization remains forced and installed routes still expire on the
cadence. Focused12tests and peer review pass. Full-server compile checks are
recorded in L1-local/server-check-exits.json.

The complete native3072case corpus passes, zero missing/illegal and unchanged
hash `5a1340213fe3046dc119d6f8d5d59cbfd379f885b95968f105d3edcbca500`. All65allocation rows pass: largest pool
shared16023601B; colossal total261919620B including778752B shared scratch.

Three c6a CPU5 pairs, B1024, Nim2.2.6: L0 parent worstp95/max
2.409137/2.503933ms; L1 candidate2.411107/2.463861ms. No speedup is claimed.
Two latency processes have identical non-timing outcomes. Every measured far
wave still hits2000ticks with only3of16 or3of32seats published. Unlike L0,
scheduler restarts are zero. A representative wave spends2048000pops on
81admissions and80completed requests, repeatedly serving seats0/1/2 while the
rest remain pending with requestrevision1. SJF plus route expiry now limits
admission. The observed completed-subset p95(1129/1169ticks) is not the tail
for all seats; most remain censored beyond2000ticks.

L1 fails its preregistered all-publish completion target; this failure remains
recorded. It does establish that exact packed identity removes false cancellation
in this workload without changing static query quality. No claim of general
moving-threat liveness, m5a floor reduction or doubled throughput is made.
The2000tick criterion was registered for this experiment; the inherited handoff
requires reporting latency tails but sets no completion deadline. ACCEPTANCE_MAP
separates those requirements. Tick/headroom, final fixtures, canonical gate and
Phase10/11 remain incomplete for independent reasons.

Checkpoint documentation audit: the source, memory fields and tests agree
with this report and L1_CODE_REVIEW.md. Both complete server compile shapes
passed. The viewer was rebuilt and module/source-stamp checks passed. These
checks do not replace the final GameVersion/fixture cycle or canonical gate.
The compiler review and actual-server Fluffy report are separate evidence,
not measurements of this candidate on production hardware.

Accounting correction: pre-M1 danger geometry was copied per seat but counted once. Total-memory numbers understated retained payload; see [GEOMETRY_ACCOUNTING_CORRECTION.md](GEOMETRY_ACCOUNTING_CORRECTION.md). Raw results are preserved.
