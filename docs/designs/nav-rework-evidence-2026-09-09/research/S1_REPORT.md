# S1: positive Q8 conversion

Parent d88fe68d; one-line floor-to-truncation change at B1024, m5a CPU5, Nim2.2.6/GCC11.4, three interleaved fresh process pairs. Parent worst p95/max5.721624/5.829678ms; candidate5.713180/5.770981ms. Packed refresh worst p95 falls from1.105472 to1.080091ms (2.30%); all three candidate refresh results are below every parent result. No meaningful whole-body improvement or qualification is claimed.

All six per-tick pop arrays match in every pair. Full3072 quality passes, zero missing/illegal,37637596pops, unchanged route hash `5a1340213fe3046dc119d6f8d5d59d59cbfd379f885b95968f105d3edcbca500`. All65activation memory rows pass with unchanged ledger against C0 L1 source. This is an explicit native quality/activation run, not the final canonical clean-checkout gate.

Focused13tests and peer review pass. Peer separately swept33553920 rounding inputs with zero conversion mismatches. Viewer Docker rebuild and module/GV/source-stamp checks pass. Invalid nonfinite float conversion was already outside the raster contract and was not changed.

Decision: retain as a small exact weight-refresh improvement; it does not solve the m5a floor or double throughput. Production-shape coverage is independently incomplete: see PRODUCTION_SHAPE_FINDING.md.

Documentation audit: no public API, configured behavior or numerical contract changes. The existing ties-to-even and range rules remain true; this report, preregistration, review and scoreboard document the experiment. Final Phase10/11 docs and shipping checks remain outstanding.

Accounting correction: pre-M1 danger geometry was copied per seat but counted once. Total-memory numbers understated retained payload; see [GEOMETRY_ACCOUNTING_CORRECTION.md](GEOMETRY_ACCOUNTING_CORRECTION.md). Raw results are preserved.
