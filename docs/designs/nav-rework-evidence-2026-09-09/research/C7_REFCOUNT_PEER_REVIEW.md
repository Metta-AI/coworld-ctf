# C7_REFCOUNT_PEER_REVIEW: corrected 64-slot list on m8i, documents only

Peer (Claude) review of `C7_REFCOUNT_ROOT_RESULT.md` from
`C7-refcount-m8i-trace-summary.json`, `C7-refcount-m8i-regimes-summary.json`
and `C7-refcount-native-addVisibleCell-C.txt`. No source or native change.
m5a corrected and both full-quality runs are still in flight and are not
judged here.

## 1. Root's numbers, recomputed

- 27 trace pairs, all exact. Candidate over C2 totals: median 0.995052,
  range 0.974783 to 1.017079, 9 of 27 above 1. p95: median 1.020, range
  0.9726 to 1.0683, 23 of 27 above 1. All as stated.
- Regimes, 12 rows each, all exact: changing sources 1.0265 to 1.0424,
  median 1.0338; repeated sources 0.6715 to 0.7353, median 0.7011. As
  stated.
- The native `addVisibleCell` C (120 lines) contains no `eqcopy` or
  `eqdestroy`, matching the Mac extraction in `C7/refcount/`.

Per trace (totals, three repeats): the four 32-seat episodes improve by
1 to 2.5 percent (0.975 to 0.992), the 16-seat episodes are flat to 1.7
percent slower (0.993 to 1.017), and the randomized smoke is 1.2 to 1.7
percent slower. The split follows hit share: the 32-seat traces have 44
to 58 percent hits, the 16-seat ones 24 to 41 percent (`C2/replay_results.txt`).
p95 is worse on every 16-seat trace and on most 32-seat repeats.

## 2. What the correction established

The v1 per-cell reference owner was the dominant cause of v1's regression
on this compiled workload: changing-source ratios fell from 1.81 to 1.97
(v1) to 1.03 to 1.04 (corrected), and trace totals from 1.48 to 1.67 to
0.975 to 1.017, with nothing else changed in the miss loop but the alias.
That is a controlled source-level result. The remaining 2.6 to 4.2
percent changing-source cost is not attributed here; the entry store per
nonzero first visit and the larger slot region are the candidates, and
the C9 micro's conversion column is the closest measurement of a store
cost, not of this miss path.

## 3. Judgment

Agree with root: this is a mechanism result, not an adoption. Against the
preregistered gate ("actual trace total benefit, no material miss
regression, exact outputs"): outputs are exact; the total benefit is a
median 0.995 with the sign depending on hit share, which is not an actual
benefit on the recorded workload as a whole; misses regress 2.6 to 4.2
percent in the changing-source regime and p95 rises in 23 of 27 pairs;
and the price is about 27 MB of additional shared payload that would
consume most of the authorized cap raise. On that evidence the eager
64-slot list should not be integrated even if m5a and quality come back
clean.

What the result does support: the hit path is genuinely cheaper (repeated
sources 0.67 to 0.74 of C2 at the full-rebuild level, consistent with the
0.41 to 0.51 replay micro once the floor, pack and scan are included), so
the representation's value is real but confined to hits, and the miss
recording cost is what defeats it on real traces where 42 to 76 percent
of sources miss. That is exactly the shape C9 addresses: misses stay C2,
and the list is paid for only on residencies that were hit at least once
(17 to 97 per episode) or twice. The C9 count model already says the
weakest 16-seat traces can afford only 0.35 to 0.42 bitmap units of
conversion overhead; the native C9 micro decides whether the conversion
fits, and even a pass leaves the same whole-trace gate that C7 just
failed, applied to a smaller expected gain.

## 4. Recommendation

- Close the eager C7 full candidate as a completed negative with an exact
  proof and a controlled attribution (ownership overhead, then a small
  residual miss cost), retaining the corrected snapshot and both native
  result sets.
- Run the C9 native micro only under its preregistered limits; if it
  passes, the next screen is a full-trace pair of a C9 candidate against
  C2 with the same three criteria, and the count model predicts the
  16-seat traces will be the ones to watch.
- Do not spend the 64 MiB authorization on the list until a full-trace
  pair shows a total benefit; the memory review's arithmetic stands but
  its precondition has not been met.

C7 REFCOUNT PEER REVIEW READY
