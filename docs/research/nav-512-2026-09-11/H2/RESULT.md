# H1+H2 result: intermediate screen passed; 512 target still missed

All nine games completed with 1,200 frames and 32 initialized guests each.
No play faults. All same-budget semantic streams are identical across the
parent and candidate and across repetitions. Native segment differential and
navigation suites passed, and the production linked server built successfully.
No retained allocation change.

Median paired candidate512/original512: total0.896457, p500.924865,
p950.791635, maximum0.884850. Worst deadline misses149 versus195.
All three repetitions improved consistently. This passes the frozen stage card.

Against original256: total1.009365, p501.057472, p950.899571,
maximum1.027067. Worst deadline misses149 versus104. This fails the512 goal:
lower p95 alone is insufficient while median, maximum and misses regress.
Full rows/stage totals: results.json; every raw run is in raw-games.tar.gz.
H1+H2 remain provisional training-scenario improvements, not shipping proof.

Next candidate targets the remaining tiny helper overhead, with an explicit
narrow diagnostic tradeoff and unchanged bounds checks/accounting. H3 must
compare with H1+H2 at512 for its incremental effect, and original256 for goal.
