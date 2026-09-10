# D1: carry the danger kernel index along each ray

Parent D0a8fe2cbad. Carry the exact kernel index: initial radius*(2*radius+1)+radius; X changes it by stepX, Y by stepY*diameter, diagonal by their sum. Pass side-cell indices before moving and preserve all existing bounds checks, visit stamps and float additions. Change no geometry ownership, decision recurrence, map indexing or source scheduling. No memory/activation change.

Hypothesis: avoiding repeated kernel-coordinate arithmetic on first cell visits improves the danger slice. Counter-hypothesis: maintaining the index on every ray step (including repeated visits) costs more than calculating it only on previously unvisited cells. Measure, retain the negative if so. This uses the existing exact integer grid recurrence described in D0_REVIEW.md; no library is needed for this local arithmetic.

Before timing run focused navigation and seat suites. Then three native m5a CPU5 pairs, B1024/range1300, full masks/pops equality; independent m8i3072 quality and retained-ledger equality. Report inclusive danger and weight percentiles separately. No source-order, float-order or timing threshold changes. No speed claim before results.
