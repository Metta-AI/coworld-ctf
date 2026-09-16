# C7_RESEARCH_REVIEW: per-entry (index, value) lists instead of visibility bitmaps

## 0. Revision 2: premises corrected per `C7_ROOT_REVIEW.md`

- Memory: the colossal figure I used (266,538,427 B, isolated C2 before
  V1) is obsolete. The integrated C2+V1+A4+H1 ledger
  (`C2-integrated-memory-summary.json`) has max total 229,158,347 B, a
  39,277,109 B margin under 256 MiB, and max non-colossal shared
  32,464,268 B. A 32-slot full-box 1300 px list (27,373,824 B) replacing
  the 856,608 B bitmap puts non-colossal shared near 58,981,484 B, under
  the user-authorized 64 MiB (67,108,864 B); a nonzero-only list bounded
  by the kernel support (`C8_ZERO_REVIEW.md`: 69,169 cells) is 17,707,264
  B, about 49.3 MB shared. Section 2's "1.9 MB colossal headroom" is
  withdrawn as a blocker; exact ledgers on all 76 maps, configured 1300 px
  and colossal are still required before any cap change.
- Literature: Roaring's 4,096 of 65,536 threshold is a container choice
  for compressed set storage and set operations, not a benchmark of
  weighted scatter-adds with precomputed float values, and the
  intersection results do not establish an iteration crossover for this
  kernel. The papers are background; they do not prove the list must lose.
- Bandwidth: source reads are 13.4 + 44.8 = 58.2 KB (bitmap plus scattered
  kernel) versus 89.7 KB for the list, 1.54x, not 2x; raster reads and
  writes are common to both and were counted inconsistently in section 3.
- Consequently the recommendation in section 8 is superseded: the
  tools-only C7 micro screen root authorized (ray-order lists captured from
  a diagnostic copy of the first-visit walk during untimed warm rebuilds,
  same v2 origins, C2 and C6 references, at least 20 percent lower median
  replay time on 1300 px rows and no material 331 px regression) is the
  right test, and it is paused pending the simpler C8 zero-omission
  screen, which reduces every representation's cost first. Sections 1 to
  8 below are retained as the record with these corrections applied.


Peer (Claude) research review of `C7_RESEARCH_REQUEST.md`. Documents only;
no source, native, or root change. Counts come from the read-only include
tool `peer-proofs/c6_fullword_count.nim` (extended with per-source min and
max; outputs `c7_traces.json`, `c7_map3_1300.json`, `c7_map3_331.json`),
the C2 LRU model (`cache-trace/cache_sim_results.txt`), and the existing
ledgers. No timing claim.

## 1. The counts that size the proposal

Visible cells per source (set bits in the C2 bitmap), which is exactly the
list length C7 would store:

| workload | sources | mean cells | max cells | box cells | mean density |
|---|---:|---:|---:|---:|---:|
| map 3 (br-gen-5120), 1300 px, every 3rd standable cell | 22,513 | 11,207 | 25,483 | 106,929 | 10.5 percent |
| map 3, 331 px, same origins | 22,513 | 3,165 | 5,367 | 7,225 | 43.8 percent |
| trace s2_32_679962 (5204), hits | 375 | 13,991 | 19,732 | 106,929 | 13.1 percent |
| trace s2_32_679963 (5263), hits | 286 | 14,616 | 20,187 | 106,929 | 13.7 percent |
| trace s2_32_679965 (5001), hits | 248 | 14,330 | 22,496 | 106,929 | 13.4 percent |

Minimum cells per source on real traces is 758 to 3,063; on map 3 sampled
origins 116.

## 2. Memory: the list cannot be capped by the mean

A list entry must hold the maximum a source can produce or refuse to cache
that source, because the request rules out silent allocation past a cap.
The observed maximum is 25,483 cells at 1300 px and 5,367 at 331 px, but a
single map or origin can exceed any observed value; the only hard bound is
the box, 106,929 cells at 1300 px. With 8 bytes per cell:

| entry sizing | 1300 px per entry | 32 slots | 64 slots | 331 px per entry | 32 slots |
|---|---:|---:|---:|---:|---:|
| C2 bitmap (for reference) | 13,368 B | 0.43 MB | 0.86 MB | 904 B | 29 KB |
| list at observed max (25,483 / 5,367) | 204 KB | 6.5 MB | 13.0 MB | 43 KB | 1.4 MB |
| list at full box (106,929 / 7,225) | 855 KB | 27.4 MB | 54.7 MB | 57.8 KB | 1.85 MB |

Against the current ledgers: non-colossal shared is about 31.6 MB at the
configured range per the request, so a full-box 32-slot list (27.4 MB)
reaches about 59 MB, under 64 MiB (67.1 MB) with about 8 MB margin, and 64
slots does not fit. The harder constraint is the colossal total: the last
activation report put colossal at 266,538,427 bytes against the 256 MiB
cap (268,435,456), a margin of 1.9 MB. A 32-slot full-box list at 331 px
(1.85 MB) consumes essentially all of it, and at 1300 px on colossal the
cap fails outright. Capping entries at an observed maximum needs an
overflow rule (mark the entry uncacheable and rebuild through the ray walk
every time), which costs hits on exactly the most expensive sources. Any
C7 design therefore has to recompute all 76 maps, configured 1300 px, and
colossal, as the request says, and the colossal total is the likely
blocker, not the non-colossal shared cap.

## 3. Bandwidth and locality, per hit at 1300 px (mean source)

| path | bytes read | bytes written | index arithmetic |
|---|---:|---:|---|
| C2 bitmap replay | 13.4 KB bitmap + 44.8 KB kernel (4 B per visible cell, scattered inside a 428 KB kernel) | 44.8 KB raster read-modify-write, row-major | ctz, clear, div (C3 removes the div; C6 removes ctz on 16 to 30 percent of cells) |
| C7 list replay | 89.7 KB list, sequential | 44.8 KB raster read-modify-write, in ray order | none |

The list halves the integer work but doubles the bytes read, and it moves
the raster writes from row-major order to ray order. Ray order walks the
perimeter and steps outward along each ray, so consecutive destination
cells are on different rows most of the time; the row-major bitmap replay
touches each raster row once, sequentially. On a Zen1-class core with a
512 KB L2, the raster (343 KB) plus kernel (428 KB) already exceed L2, and
the list adds 90 KB of streaming reads per hit. Which side wins is a
measurement, but the request's "ray-order destination locality" is a cost
of the list, not a benefit: recording in first-visit order is exact, as
the request says, and it is also the least local write order available.

## 4. What the literature says about the density crossover

The established rule for choosing between a sorted list of indices and a
bitset is density. Roaring bitmaps keep a chunk as a sorted array only up
to 4,096 of 65,536 values (6.25 percent density) and convert to a bitmap
container above that, a threshold chosen so a container never costs more
than 16 bits per member ([Chambi, Lemire, Kaser, Godin, "Better bitmap
performance with Roaring bitmaps"](https://arxiv.org/pdf/1402.6407);
[Lemire et al., "Consistently faster and smaller compressed bitmaps with
Roaring"](https://arxiv.org/pdf/1603.06549); [Lemire et al., "Roaring
Bitmaps: Implementation of an Optimized Software
Library"](https://arxiv.org/pdf/1709.07821)). The hybrid inverted index of
Culpepper and Moffat that Roaring builds on stores dense sets as bitmaps
and sparse ones as arrays for the same reason, and the SIMD intersection
literature reports bitsets winning on dense data and losing by more than
10x only below about 1 percent density ([Lemire, Boytsov, Kurz, "SIMD
Compression and the Intersection of Sorted
Integers"](https://r-libre.teluq.ca/601/1/simdcompressionarxiv.pdf)). Our
entries are 10 to 14 percent dense at 1300 px and 44 percent at 331 px, on
the bitmap side of every published crossover; the sparsest real sources
(a few hundred cells) are the cheap ones either way. This is the reason
not to adopt a library: the question is not "which bitmap library" but
"list or bitmap at this density", and the published answer is bitmap.
Roaring's array container is the small internal list the request
describes, and Roaring itself would not use it here.

## 5. The miss path

Recording a list on the miss path is one 8-byte sequential append per
first-visit cell in place of one bitmap OR (a read-modify-write on a 13 KB
word array that stays in L1). The append is cheaper per cell in isolation
but writes 90 KB per source instead of 13 KB, and it needs a length and a
capacity check per cell (or an overflow flag). Whether that is faster,
neutral, or slower is not knowable from counts; the request is right to
say direct recording should not be presumed to avoid worsening misses.

## 6. Capacity 32 versus 64

From the C2 LRU model on the nine traces, hits at capacity 32 versus 64:
16 seats 74/75, 48/48, 77/77, 29/29, 33/33 (at most one hit lost); 32
seats 356/375, 278/286, 265/295, 240/248 (5 to 10 percent of hits lost),
with ray steps removed falling by 0.01 to 0.05. So the 32-slot hypothesis
costs little at 16 seats and a measurable share of hits at 32 seats.

## 7. Existing repo patterns

Fixed-capacity arrays with a count are the house pattern for bounded lists
(`selectedDangerPoints` in body_nav, `spans` and endpoint attachment arrays
in body_route_query, `newSeqOfCap` scratch in body_route_index). A C7
entry would be one of those at 106,929 pairs, or the C2 backing seq
scheme with a per-slot length. Nothing to add beyond that; no library.

## 8. Recommendation and the one screen if root still wants it

On the counts and the density literature, the list is the wrong container
for entries this dense, its memory is bounded only by the full box, and
the colossal total cap has 1.9 MB of headroom. I recommend not building
C7. If root wants a number anyway, the smallest screen with explicit limits
is:

- Micro only, no production source: extend the C6 microbench with a
  diagnostic list arm that, at warm time, records each origin's (index,
  value) pairs in first-visit order from the existing bitmap walk into a
  preallocated full-box array, then times list replay on the same evenly
  spread origins as the C2 and C6 arms, same batches and hashes.
- Limits to preregister: proceed to a ledger and design pass only if list
  replay is at least 20 percent faster per replay than the C6 candidate in
  the 1300 px rows on m8i and no slower at 331 px; otherwise close C7.
- Ledger gate before any source: recompute retained bytes with a full-box
  32-slot list on all 76 maps, configured 1300 px, and colossal; the
  colossal total must stay under 256 MiB with margin, which the numbers
  above say it will not at 1300 px.
- Hit-loss gate: the 32-slot LRU model above is already the quantification
  the request asked for; adopt 32 only if the micro gain outweighs 5 to 10
  percent fewer hits at 32 seats.

C7 REVIEW READY
