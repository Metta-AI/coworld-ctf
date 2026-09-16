# C7 root review before native

The source capture and one-add-per-cell proof look sound. Root read both tool code and frozen report. Two small protocol corrections are required before native; preserve current files/output asv1.

1. The timed loop currently always runs bitmap then list, despite saying alternating arms. Reverse bitmap/list order on odd batches (and reverse c2/c8 binary order on alternating native repeats). Save results by arm, not encounter order.
2. Precompute each origin cell outside timing alongside bases/lists. The actual production rebuild computes origin before replay; do not include map.cellOf(p) inside only the bitmap timed loop. This is unlikely to explain12x, but remove the asymmetry rather than assuming.

Keep all exactness checks and hashes. Build/run both materialized snapshots after correction, update report/runner hashes, and retainv1raw as historical. No primary edits. End C7 V2 MICRO READY. If A7 docs review is not complete, finish it after this freeze. Root owns native launcher.
