# C3 preregistration: cache replay row cursor

Baseline: frozen C2 candidate, f9dff753 plus shared visibility cache (C2-candidate-body_nav.nim and C2-candidate-bench.nim). Candidate changes only the integer index calculation in replayVisibleCells. Both arms exclude V1/A4/H1 and retain the isolated C2 ledger; final integration has the separately documented 16-byte correction.

Proof: C3_REVIEW.md and peer-proofs/c3_row_cursor_check.py establish the recurrence over 16,058,910 index comparisons. The implementation keeps one rowEnd and gridOffset per source; advance with while, not if. Source order, bitmap, cache replacement, kernel additions and floors are unchanged. No new dependency or memory allocation.

Prediction: whole-body configured 1300 px p95 does not regress, with a measurable cache-hit improvement. Miss-only workloads should remain unchanged apart from noise. Do not infer that this alone reaches the 3.6/4.5 ms headroom. Retain all failures and row-level masks/pops. A 1% noisy change is not convincing evidence of improvement.

Native m5a CPU 5: fresh parent/candidate builds with established release/useMalloc/noSignalHandler flags; full candidate quality must preserve the pre-H1 hash 5a1340213fe3046dc119d6f8d5d59d59cbfd379f885b95968f105d3edcbca500. Three interleaved parent/candidate configured runs across all eleven maps, 16/32 seats and all three scenarios. Each result is independently complete, no aggregate percentile subtraction. Keep all 198 paired rows, output hashes, versions and exact patches. No other timed process on host.

Native m8i CPU 5: three interleaved pairs for nine recorded source traces and changing/repeated source diagnostics, same as C2-mechanisms. Require identical ordered input/raster chains and counts. No other timed process on host.

Root integration, if evidence supports retention: focused cache/navigation tests, full corpus hash with H1, both server compile shapes, rebuilt viewer QA, final combined native and Docker qualification. This experiment does not select B or waive any gate.
