# C2 native result: retain the cache, qualification remains open

The frozen C2 experiment uses f9dff753 plus the 64-slot shared visibility cache, B=1024, without V1, A4, or H1. On m5a CPU 5, three interleaved short pairs at each range preserve all 36 masks/pop rows. Worst p95/max: 331 px parent 3.861363/3.942945 ms versus candidate 3.470990/3.497900; 1300 px parent 5.238564/5.441599 versus candidate 3.554661/3.578252. Both short regimes fit the 3.6/4.5 ms headroom, but fixed repeated threats favor the cache.

The full configured workload passes 0 of 11 maps. Worst p95/max is 6.484532/6.680327 ms on map 5120, 32-seat stuck replans. All 76 memory ledgers pass; only 10/76 activation-time rows pass on this CPU. These results do not select a final budget or establish fleet acceptance. Raw files: C2-m5a/.

On m8i CPU 5, all 27 paired replays of nine actual source traces retain identical ordered inputs, raster hash chains, and cache counts. Total rebuild time is 0.6203–0.8812 times parent; p95 is 0.5979–0.9858 times parent. None regresses p95. Changing-source diagnostic totals range 0.9918–1.0108 times parent, with 8/12 slower: the no-slowdown prediction is falsified. Repeated-source totals range 0.2215–0.3302 times parent. Raw files: C2-mechanisms-m8i/; summaries: C2-trace-native-summary.json and C2-regimes-native-summary.json.

Root integration preserves V1 byte stamps, A4 validation, and H1 exact-goal heuristic. The isolated cache ledger omitted one 16-byte allocation allowance for its ref owner; integrated code adds it. Preserve isolated raw values, and use fresh integrated ledgers for the combined candidate. This is an accounting allowance, not a physical RSS bound.
