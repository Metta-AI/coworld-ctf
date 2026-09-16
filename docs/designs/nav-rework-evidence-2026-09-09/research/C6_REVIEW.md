# C6_REVIEW: contiguous adds for full visibility words in the cache-hit replay

Peer (Claude) read-only review of `C6_REVIEW_REQUEST.md`. No source edit.
Count screen run against the frozen C2 cache source through a read-only
include (`peer-proofs/c6_fullword_count.nim`, outputs `c6_traces.json`,
`c6_map3.json`). No timing claim.

## 1. Correctness of the sketch

For a word equal to `high(uint64)`, bits `k = wordIndex * 64` to `k + 63`
are all set, so the 64 kernel indices are consecutive and each maps to one
in-grid cell with one kernel add (C2 invariant, tested). The sketch splits
the run only where `kx` would pass `diameter - 1`: `n = min(remaining,
diameter - kx)` cells of row `ky` starting at `kx`, grid base
`(oy - r + ky) * W + ox - r + kx`, then `k += n`. Each span is a contiguous
range of both `kernel` and `values`, so the adds are the same per-cell
single adds C2 makes, in the same source order, with the floor
interleaving untouched. There is no reduction across cells, so float
results are bit-identical.

Facts that make the arm safe:

- Padding can never be inside a full word: the last word holds
  `d*d mod 64` valid bits, and `d = 2r + 1` is odd, so `d*d` is odd and
  never a multiple of 64; the last word always has padding bits, which
  C2 never sets, so it is never full. (At 1300 px `d*d mod 64 = 49`; at
  331 px, 57.) The arm therefore never touches an index at or beyond `d*d`.
- Out-of-grid cells are never recorded, so every cell of a full word is
  in-grid; no bounds test is needed, as in C2 and C3.
- Diameters below 64 (ranges up to 248 px) make a full word span several
  rows; the while loop handles that, and the count screen confirms the
  span arithmetic terminates at exactly `remaining = 0`.
- Negative row bases are plain signed arithmetic; the span index is the
  same expression C3 proved equal to the C2 formula.

Interaction with C3 (row cursor for sparse words): the two compose, but
after a full word the cursor state must be re-derived for the next sparse
bit (one division per full word, or advance the cursor by the spans
taken). The screen shows full words never crossed a row boundary on any
trace or on map 3 (spans per full word exactly 1.00), because the visible
disc never reaches a box row's last cells and the next row's first cells
together; the split logic is still required for exactness on other
geometry, it just never fires here.

Nim `-d:release` keeps bounds checks; the sparse loop already pays them,
and whether the C compiler vectorises the span loop through the two
`seq[float32]` pointers and the checks is a measurement question, not a
claim.

## 2. Count screen: how many replayed cells sit in full words

Per trace, hits only (the arm changes nothing on the miss path):

| trace | map | hit sources | full words / words | share of set bits in full words |
|---|---|---:|---:|---:|
| s2_16_679962 | 5204 | 75 | 3,418 / 125,325 | 0.191 |
| s2_16_679963 | 5263 | 48 | 2,659 / 80,208 | 0.240 |
| s2_16_679964 | 5204 | 77 | 3,297 / 128,667 | 0.197 |
| s2_16_679965 | 5001 | 29 | 2,214 / 48,459 | 0.304 |
| s2_32_679962 | 5204 | 375 | 15,231 / 626,625 | 0.186 |
| s2_32_679963 | 5263 | 286 | 14,967 / 477,906 | 0.229 |
| s2_32_679964 | 5204 | 295 | 10,162 / 492,945 | 0.159 |
| s2_32_679965 | 5001 | 248 | 15,075 / 414,408 | 0.271 |
| smoke (randomized seed) | 5001 | 33 | 2,334 / 55,143 | 0.300 |

Miss-path bitmaps (the same cells, recorded rather than replayed) show the
same shares, 0.16 to 0.30. Configured map 3 (br-gen-5120, 1300 px, one
cold rebuild per every seventh standable cell, 9,657 sources): 410,630
full words in 16.1 million, 0.243 of set bits in full words, about 11,205
visible cells and 42.5 full words per source.

So the arm covers roughly one fifth to three tenths of replayed cells; the
existing sparse loop keeps 70 to 84 percent. Words per entry are 1,671 at
1300 px, and only 2 to 3 percent of them are full; the rest are scanned as
today plus one extra compare per word.

## 3. What it can and cannot buy (bounds, not predictions)

Per replayed cell the sparse loop does a trailing-zero count, a clear of
the lowest bit, the C3 cursor step, one kernel load, one raster load and
store, and an add; the span loop drops the first three for the covered
cells. Even if a span cell cost half of a sparse cell, the replay would
shrink by at most about half of 0.16 to 0.30, so roughly 8 to 15 percent
of replay time, and the replay is the hit share of a rebuild only (25 to 58
percent of sources on real traces, 96 percent on the static harness). On
the harness rows, where a first-fill tick is about 70 percent replay, the
ceiling is a few percent of that tick; on real play it is smaller. That is
the same order as C3's result (6.480 to 6.357 ms worst p95, 0 of 11).

## 4. Recommendation and preregistration

The count gate the request asked for is met by the screen above: the
useful full-word fraction is 0.16 to 0.30 on every real trace and 0.24 on
configured map 3. Preregister the following before any source work:

- Micro-arm first: a replay-only microbench on map 3 bitmaps (the C5 v2
  tree's hit path, or a standalone include like the screen tool), paired
  C3 versus C3 plus the full-word arm, five runs each, reporting time per
  replayed source. Threshold to proceed to whole-body: at least 10 percent
  faster replay per source with identical rasters (byte compare and the
  C2 hash chain on all nine traces).
- Whole-body only if the micro-arm passes: paired configured rows on m8i
  and m5a, prediction "no more than 2 percent p95 change"; a result inside
  noise is a null and closes the direction, the same way C3's flat totals
  are being judged.
- Exactness obligations: reuse the C2 focused suite, the trace replay
  hash chains, and the corpus hash; add one unit test on a crafted map
  with a diameter below 64 so a full word spans several rows, and one at
  the 1300 px diameter with a full word whose row split would fire, to
  pin the split logic even though the screen never triggered it.
- Nothing in the arm touches the miss path, the bitmap, the LRU, the
  floor, or the publish, so the C2 ledger is unchanged.

Existing code to reuse: the arm is a second branch inside
`replayVisibleCells` next to the C3 cursor; the only pattern in the repo
for contiguous pointwise spans is the streaming row loops in the packed
dilation, which suggests writing the inner span as a plain indexed
`for offset in 0 ..< n` loop rather than any helper.

## 5. Diagnostic to adopt if implementing

`peer-proofs/c6_fullword_count.nim` (read-only include of the C2 source)
replays a trace through the selected-source seam, classifies each source
as hit or miss before the rebuild, and scans its bitmap for words, full
words, set bits, set bits in full words, and row spans per full word; the
`--map <name> <range> <stride>` mode samples cold rebuilds on a pool map.
If the arm is built, the same scan belongs in the C2 counters define so
the native runs report the share they actually served.

C6 REVIEW READY
