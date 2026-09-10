# C6 rejected at the preregistered native screen

m8i CPU5, five paired micro runs, three maps at331/1300px, whole-map-spread64origin samples. Parent/candidate origin lists, workload parameters, set-bit/full-word counts, batch raster hashes and every reference float cell agree. All five crafted cases agree, including nonzero test kernels and row-crossing full words at diameters27and327. No counters are enabled in timed binaries.

Median candidate/parent replay ratios at1300px are0.91055(map5120),0.93024(map5204),0.93101(map5263): gains of8.94%,6.98%,6.90%, all below the preregistered10% threshold. At331px gains are5.22%,5.39%,3.22%. Do not change the threshold after seeing these numbers. C6-micro-native-summary.json retains every pair.

All27native real-trace pairs preserve ordered inputs and raster chains, but total rebuild ratios are1.00116–1.01531 (all slower); p95ratios0.98111–1.06602,24/27slower. The faster isolated hit loop does not demonstrate a useful real-rebuild improvement. These results do not identify the cause of the miss-dominated or code-layout effects; no causal claim is needed to reject adoption.

C6 closes without a whole-body run, primary source change, cap increase or budget selection. The original bitmap replay remains the retained implementation. The v1 top-edge-biased sample, corrected v2 map-wide sample, materialized source snapshots, tool arm-label fix, correctness artifacts and all raw native results remain auditable under C6/ and C6-micro-m8i/. Mac gains were informational and did not gate this decision.

Documentation audit: only isolated diagnostic artifacts and reports changed. No production API/config/setup contract requires an update; SCOREBOARD.md records this rejection and the unchanged final gates. The C6 source snapshots retain inert C5 markers, compiled out for these native timings.
