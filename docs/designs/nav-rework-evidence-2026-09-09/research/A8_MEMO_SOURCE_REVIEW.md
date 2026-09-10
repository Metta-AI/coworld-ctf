# A8 memo implementation: read-only source and test review

Reviewed, read only: `A8/memo/parent-body_route_index.nim` against
`candidate-body_route_index.nim` (the live nav-deferred-cache source is
byte identical to the frozen candidate), `base.nim` against the parent,
`check_pixel_failure_memo.nim` and `focused.log`,
`tools/check_a8_memo_counts.nim` and `counts.log`,
`tools/check_index_full_identity.nim`, `memo/identity.json` against
`A8/full-identity/parent.json`, the generated C in `memo/cache-focused/`,
`bench_index_constructor.nim` and `run_native.sh`. No source edits, no
native job. Root owns timing, source changes and result analysis.

## 1. Verdict

The implementation matches the accepted plan and I find no exactness
defect. It is ready for root's registered native screen (at least 5
percent median map 48 constructor improvement on both hosts, three
interleaved process pairs, five constructors per process). Nothing below
blocks that run; section 4 lists observations for the report.

## 2. Source diff, checked line by line

The candidate adds 37 lines to the parent and touches nothing else:

- `PixelSearchFailure`: 64 `int32` targets, `start`, `center`,
  `targetCount: uint8`, `exactEdges: bool`. 296 bytes as measured (256 +
  32 + 2, padded to 8). `PixelSearchScratch` gains `failures:
  array[128, PixelSearchFailure]` and `failureCount: int`; 37,896 bytes
  for the memo, 38,000 for the whole scratch (the six seq headers are 16
  bytes each under ORC plus the generation). Measured figures in
  `focused.log` agree with this arithmetic.
- Accounting: `initPixelSearchScratch` folds `sizeof(result.failures) +
  sizeof(result.failureCount)` into the existing `max`. Correct and in the
  existing style.
- Lookup: placed after the box-cap raise, after the valid-start return
  and after `beginSearch`, before the standable fill. It scans only
  `failureCount` records, compares start, center, mode and count before
  targets, and returns the default `PixelPath` on an exact match. The
  raw failed return is the default `PixelPath` as well (nothing is written
  into `result` before `reached >= 0`), so the hit value is identical.
  Template field access; no record copies.
- Admission: only at the existing `reached < 0` return, only when
  `failureCount < 128` and `targets.len <= 64`; copies the ordered targets
  exactly; never evicts. Invalid start, oversize lists and successes are
  never admitted (they return before the admission point or take the
  success path).
- Purity holds as in the plan review: the search reads only the immutable
  map, `routePoint` (arithmetic decode) and the key inputs, so a failure
  for a key is a failure for that key for the life of the scratch, and the
  scratch is construction-local (created in `buildSides` and the pocket
  builder, dies with them).
- Skipped side effects on a hit: standable fill, target stamps, visited
  stamps, parent and queue writes. None is read across calls (every read
  is guarded by the current generation or stays inside the same call's
  box), and `beginSearch` still runs, so generation advance and rollover
  are identical. The first focused test exercises exactly this, including
  the rollover reset of both stamp arrays.
- `base.nim` differs from the parent only by the A4 symmetric validator
  change. Both arms carry A4; the devbox tree is pre-A4, which
  `run_native.sh` handles by copying each arm in and recording its patch.

Generated C: `initPixelSearchScratch` takes `Result` as an output pointer
and zeroes it in place; the two construction-site locals are zeroed in
place; there is no copy of the 38,000-byte object anywhere in the unit.
The `var` parameter passing means no per-call copies either.

## 3. Tests and counts

- Five focused tests pass and cover the list from the plan review: repeat
  skips the walk and preserves generation rollover; every key component
  (mode, center, start, target list, target order) distinguishes entries;
  the 129th unique failure runs raw with no eviction and earlier entries
  still hit; 65-target lists run raw and are not admitted; invalid starts
  and successes are not admitted. The queue sentinel technique (`queue[0]
  = -123`) is a clean way to prove the walk was skipped or ran.
- Counts tool is the candidate source plus two counters (`inc memoHits`
  at the hit return, `inc pixelDequeues` at the dequeue) and a map 48
  driver; diff against the candidate shows nothing else. Result: 189 memo
  hits and 448,841 dequeues. That equals the count model exactly: 805,625
  measured dequeues minus 356,784 predicted savings is 448,841, and 189 is
  the full repeat count.
- Identity: all 76 maps (64 pool, 11 configured, colossal) have identical
  hashes for every retained array and identical stats against the parent
  baseline in `A8/full-identity/parent.json`. `transientPeakBytes` is
  outside identity by protocol and in fact did not change on any of the
  76 maps: the scratch (88,725 bytes of per-cell arrays plus the 37,896
  memo) stays below the peak set elsewhere in construction (about 292 to
  300 KB on these maps).

## 4. Observations for the report (none blocking)

- Scan cost. With the array full, a miss costs up to 128 record compares
  and touches about one cache line per record (records are 296 bytes and
  the key fields sit at the end of each record), so up to about 128 line
  reads per failed or new search. Against map 48's 805,625 dequeues that
  is small, and on maps with no failures `failureCount` stays 0 and the
  scan is free. The native pair, not this reasoning, decides.
- Zeroing. Each scratch construction now zeroes 38,000 bytes instead of
  about 100; two scratches per index. Negligible, but it is the only new
  cost on maps without repeats.
- Transient accounting convention. `transientPeakBytes` is a max over
  allocation points, not a sum of concurrently live transients, so the
  memo's 37,896 bytes are counted at scratch creation but are invisible
  while the scratch is alive next to the larger pending arrays. That is
  the pre-existing convention, not something A8 changed; worth one
  sentence in the report so the unchanged peak is not misread as "no
  memory added".
- Generality. Admission is first 128 failures, no eviction, fitted to map
  48's measured order; a map whose repeats come after 128 unique failures
  gets nothing but the bounded scan. Keep the "no repeats on configured
  maps 3, 5, 6" negative and the sentence that the per-start
  latest-failure model gives identical counts here.
- Native run script. Order swap on repeat 2, CPU pinning, patches and
  hashes recorded, restoration on exit: consistent with earlier units. It
  times map 48 only, which is right for the screen; the 76-map activation
  report remains the place to show no other map slower than noise if the
  screen passes, as preregistered.

## 5. Native screen outcome (added after `A8_MEMO_SCREEN_RESULT.md`)

Reviewed `A8_MEMO_SCREEN_RESULT.md`, `A8/memo/native-screen-summary.json`
and every raw pair under `A8/memo/m8i/` and `A8/memo/m5a/`.

The negative decision is confirmed. The registered rule was at least 5
percent median map 48 constructor improvement on both hosts; m5a is under
it.

| host | pair ratios (candidate / parent, median of 5 constructors each) | median ratio | reduction | decision |
|---|---|---:|---:|---|
| m8i | 0.9389, 0.9349, 0.9384 | 0.9384 | 6.16% | pass |
| m5a | 0.9498, 0.9503, 0.9516 | 0.9503 | 4.97% | fail |

Raw pairs checked against the summary: the summary's per-pair values are
the medians of the five samples in each process file, and the medians
and percentages recompute exactly. Parent and candidate report the same
retained bytes (1,062,480) and the same transient peak (291,720) on both
hosts, consistent with section 3. m5a's three pairs span 0.9498 to 0.9516
and its parent samples vary by about 0.3 percent. That spread does not
make the decision statistically resolved: three pairs cannot resolve a
shortfall of 0.03 percentage points against a 5 percent line, and I make
no claim about the true effect on m5a beyond "close to the line". The
observed decision is negative under the registered rule, that does not
justify a resample to cross the same threshold, and I do not propose one.
No implementation follows from this unit.

What the unit leaves as evidence: an exact, construction-local memo that
serves every measured repeat on map 48 (189 hits, 356,784 of 805,625
dequeues saved, 76-map identity, unchanged retained memory) and improves
map 48 construction by about 6 percent on m8i and about 5 percent on m5a.
It does not act on maps without repeats and does not move the absolute
activation or tick gates, which stay unchanged. Exact-path check
(correction of my earlier note): `paths.log` is an intentionally retained
failed compile; `build-paths-v2.log` is the successful build, and root
compared `A8/memo/paths.json` against `A7/local/eager-arms-v2.json`. I
verified that comparison independently: the 11 crafted cases and the
`real_map48` block are equal field for field (173,424 searches, 170,726
reached, 12 exact-edge differences, result chain 4D841154B18CFF53). It is
supporting correctness evidence, not part of the timing decision. Both
native trees and nav-deferred-cache are restored clean.

Closed as a negative under the preregistered screen. Primary sources and
caps unchanged; root is restoring the isolated source after snapshotting.

A8 MEMO REVIEW FINAL READY
