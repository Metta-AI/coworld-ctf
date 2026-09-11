# H1 result: intermediate screen passed; 512 target missed

All nine finite games completed, 1,200 frames each, all 32 guests initialized,
zero play faults. Same-budget semantic streams match across candidates and
all repetitions. Native heap differential and navigation suites passed;
production Nim 2.2.4 runtime-linked server build passed. Allocation layouts
are unchanged by inspection.

Median paired candidate512 / parent512 ratios: total 0.973436, p50 0.946761,
p95 0.982357, maximum 0.995000. Worst deadline misses 187 versus 190.
The second paired repetition regressed (total ratio 1.030907); it is retained,
not replaced or hidden. H1 passes the preregistered median-based stage screen,
but this is provisional training-scenario evidence only.

Candidate512 / parent256 median ratios: total 1.082573, p50 1.069521,
p95 1.110249, maximum 1.158833. Worst deadline misses 187 versus 106.
The 512 objective is not reached. Per H2_CARD.md, the next candidate is H1+H2.

Full rows and criteria: results.json. Raw games/build logs: raw-games.tar.gz
(SHA256 117188abeee1edee526362bcab7490fe2cffbe9b2cb3c571ad527198259e13f1).
No profiled timing entered the decision; all frames, including ladder bursts,
remain included. No live budget change or publication.
