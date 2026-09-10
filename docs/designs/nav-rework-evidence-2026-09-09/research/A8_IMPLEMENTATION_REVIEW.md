# A8_IMPLEMENTATION_REVIEW: failed pixel-search memo, design and native screen (documents only)

Peer (Claude) review of `A8_COUNT_RESULT.md` and `A8/local-mac/counts.json`.
No implementation; root owns the tree and native runners.

## 1. The counts, verified

Map 48, pocket scratch (scope 1): 455 calls, 804,689 dequeues, 266
distinct exact keys, 15,176 bytes of key payload (57 bytes per key on
average, so a dozen int32 targets plus the fixed part). Outcomes: 442
failed (798,440 dequeues, 1,806 per call against a 4,225-pixel box), 2
reached-but-empty, 11 successes. Repeats: 189, all failed, 356,784
dequeues = 44.3 percent of all dequeues (1,888 per repeat); zero exact-key
result or dequeue mismatches; every weak-key (start, center, exactEdges)
repeat is also an exact ordered-target repeat, so target growth loses
nothing on this map. Sides scratch: 2 calls, no repeats. Configured maps
3, 5, 6: 5, 96, 5 pocket calls, zero repeats of any kind. The wrapper
always executed the raw search and the source was restored; the
pre-run screen (100 calls, 25 percent) passes on map 48.

Two consequences before design: the benefit is confined to geometry like
map 48 (the map that fails the m5a activation ratio), and it is an
operation count, 44 percent of dequeues in the pocket pixel stages, not a
constructor-time gain. From the A5 attribution (`A5_NATIVE_REVIEW.md`),
the pocket pixel stages (coverage resolve, graph joins, final pending)
are about 80 ms of the 252 ms m8i index on map 48, and the BFS is a part
of those stages, so the plausible index-time effect is single-digit
percent; it cannot by itself close the m5a ratio (2.41x against 2.0x
needs about a 29 percent index-plus-nav reduction).

## 2. Memo shapes, judged on the measured access pattern

The repeats come from `resolvePocketPending` re-evaluating the same
unresolved points on later passes and from the join loop; between two
repeats of one key, hundreds of other searches run (the pending list is
thousands of points). That rules out a small recency ring: a 16-entry
linear cache would be flushed before any repeat returns, so it would
count near zero of the 189. The memo must be keyed by start.

| shape | hits it can serve | storage, measured worst case on map 48 | overhead |
|---|---|---|---|
| Full exact-key failure memo (`std/tables` keyed by start pixel, center, exactEdges, ordered targets) | all 189 | 266 keys, 15,176 B of key payload; table slots hidden by the library (analytically the smallest power of two above 1.5 times length, 512 slots) | one hash of a short int32 seq plus one equality compare per call |
| Per-start latest failed key (`std/tables` keyed by start pixel index only; value: exactEdges, ordered targets, one bool) | all 189 on this map, because every weak repeat is an exact repeat; loses only when the same start recurs with a different target list in between, which the count shows does not happen here | at most one entry per distinct failed start (at most 442 here), each the fixed part plus its targets; same table opacity | one table lookup by int32 plus one ordered compare |
| Small bounded linear cache | near zero (access pattern above) | fixed | none worth having |

Recommendation: the per-start latest-failed-key memo. It is the smallest
exact structure that serves the measured recurrence, its key is a single
int32 (no seq hashing), and its value is the ordered target list the
comparison needs anyway. Exactness: a memo hit is returned only when
start, center, exactEdges and the ordered targets all equal the stored
failed call, and only after the same valid-start check and
`beginSearch` generation bump the raw call would have made, so
generation advancement, rollover and every other side effect of a failed
search are preserved; invalid-start returns are not memoized (they cost
nothing). Scope: the memo lives in `PixelSearchScratch`, is created empty
in `initPixelSearchScratch` and dies with it, so the sides and pocket
stages never share entries and no map or index state can leak; nothing
is retained past construction.

## 3. Transient memory accounting (the request's central concern)

Do not report a guessed table capacity. Account explicitly:

- Bytes owned by the memo = sum over entries of (fixed part + 4 bytes per
  target), accumulated in a counter when an entry is inserted or
  replaced, and folded into `stats.transientPeakBytes` at each insertion
  the way the pending arrays already are; on map 48 the measured payload
  is 15,176 bytes for the exact-key form and at most that for the
  per-start form.
- Table slot storage from `std/tables` is not measurable through the
  public API; state its bound analytically (slot count is the smallest
  power of two not below 1.5 times the entry count; slot size is the
  key, value and hash fields) and cap the entry count at a fixed
  constant (4,096 is far above the 442 failed starts seen) beyond which
  the memo stops inserting and searches simply run raw, keeping the bound
  finite without an overflow fallback in results.
- The diagnostic should record, per scratch, the maximum targets per key
  and the maximum entries, so the cap and the per-entry size are set from
  measured maxima rather than assumed; the current counts give only the
  total payload and distinct keys.
- No custom hash map: `std/tables` with an int32 key is the existing
  stack; a per-entry `seq[int32]` for targets is the ordinary pattern the
  index already uses for transient scratch (`newSeqOfCap` in pending
  resolution).

## 4. Smallest reversible native speed screen (A4 base f9dff753)

- Arms: A4 parent versus A4 plus the per-start failed-key memo, no
  counters or Fluffy in timed binaries; a separate counted build reports
  memo hits and bytes for attribution only.
- Exactness first: full 76-index array identity against the parent (the
  route-index identity tool from A6), the A4 validator mutation
  diagnostic, focused route-index suite, full 3,072 quality on the old
  hash. Any difference closes A8.
- Timing: three interleaved constructor activation pairs on map 48 per
  host (the A5 profiler without markers, or the harness activation row),
  then the full 76-map activation report on both hosts.
- Advancement criterion, consistent with A6 and A7: at least 5 percent
  lower median map 48 index time on both m8i and m5a, exact outputs, and
  no map slower by more than noise in the 76-map run; report the m5a
  ratio for map 48 as measured, expecting it to remain above 2.0x, so
  the result is banked as a partial reduction toward the activation
  deficit, not as closing it. The final activation gate (2x non-colossal,
  3x colossal) stays absolute and unchanged.
- Reversibility: one proc wrapper plus a scratch field; reverting is the
  patch in reverse.

A8 IMPLEMENTATION REVIEW READY
