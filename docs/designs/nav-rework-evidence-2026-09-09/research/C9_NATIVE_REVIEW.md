# C9_NATIVE_REVIEW: m8i conversion micro verified, and a bounded full-candidate plan

Peer (Claude) documents-only review per `C9_NATIVE_RESULT.md`. No
implementation; the plan below waits for root's m5a confirmation. Ledger
projection script: `C9/c9_memory_calc.py`, output `c9_memory_calc-64.json`.

## 1. The m8i result, recomputed from `C9-micro-m8i-summary.json`

Eight configurations, five fresh processes each, all exact, all
`pass_screen` true, rotating operation order, no defines:

| map | range px | bitmap ns | conversion ns | list ns | conversion increment | list / bitmap |
|---|---:|---:|---:|---:|---:|---:|
| br-gen-5120 | 1300 | 43,486 | 53,946 | 20,546 | 0.2405 | 0.4725 |
| br-gen-5204 | 1300 | 51,468 | 63,835 | 24,702 | 0.2403 | 0.4800 |
| br-gen-5263 | 1300 | 38,492 | 47,611 | 17,891 | 0.2369 | 0.4648 |
| br-gen-5001 | 1300 | 43,533 | 54,151 | 20,828 | 0.2439 | 0.4784 |
| br-gen-5120 | 331 | 12,688 | 16,083 | 4,938 | 0.2676 | 0.3891 |
| br-gen-5204 | 331 | 14,118 | 17,871 | 7,053 | 0.2658 | 0.4995 |
| br-gen-5263 | 331 | 11,656 | 14,695 | 5,777 | 0.2607 | 0.4956 |
| br-gen-5001 | 331 | 12,262 | 15,562 | 6,102 | 0.2691 | 0.4976 |

Root's ranges are reproduced (1300 px conversion 0.2369 to 0.2439, list
0.4648 to 0.4800; 331 px 0.2607 to 0.2691 and 0.3891 to 0.4995). The
generated conversion and replay functions contain no `eqcopy` or
`eqdestroy`. All 41 exit codes are 0. The screen passes as registered;
it remains an advancement screen.

## 2. Estimated recorded-trace benefit (revision 2: per-map costs, labelled an estimate)

Assumption, stated: first-hit materialization; each trace priced with the
m8i micro medians of its own map at 1300 px (`C9-micro-m8i-summary.json`);
net saving per episode = later hits times (1 - list ratio) minus
conversions times conversion increment, in that map's bitmap replays,
times that map's bitmap replay time. The micro's origins are evenly
spread samples, not the recorded origins, so these are estimates of the
recorded-window benefit, not per-source upper bounds. Counts from
`C9/c9_lazy_list_counts-r050.json`; table also in `C9/c9_trace_estimate.json`.

| trace | map | later hits | conversions | bitmap ns (map, 1300 px) | list ratio | conversion increment | net saving ms per episode (first-hit policy) | episode sim ticks | mean per tick us |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| s2_16_679962 | br-gen-5204 | 40 | 35 | 51,468 | 0.4800 | 0.2403 | 0.638 | 2023 | 0.32 |
| s2_16_679963 | br-gen-5263 | 27 | 21 | 38,492 | 0.4648 | 0.2369 | 0.365 | 2151 | 0.17 |
| s2_16_679964 | br-gen-5204 | 46 | 31 | 51,468 | 0.4800 | 0.2403 | 0.848 | 2124 | 0.40 |
| s2_16_679965 | br-gen-5001 | 12 | 17 | 43,533 | 0.4784 | 0.2439 | 0.092 | 3277 | 0.03 |
| s2_32_679962 | br-gen-5204 | 283 | 92 | 51,468 | 0.4800 | 0.2403 | 6.437 | 2331 | 2.76 |
| s2_32_679963 | br-gen-5263 | 216 | 70 | 38,492 | 0.4648 | 0.2369 | 3.811 | 2357 | 1.62 |
| s2_32_679964 | br-gen-5204 | 198 | 97 | 51,468 | 0.4800 | 0.2403 | 4.100 | 3088 | 1.33 |
| s2_32_679965 | br-gen-5001 | 164 | 84 | 43,533 | 0.4784 | 0.2439 | 2.832 | 3289 | 0.86 |
| smoke_s2_16_randomized | br-gen-5001 | 15 | 18 | 43,533 | 0.4784 | 0.2439 | 0.149 | 2248 | 0.07 |

Every recorded episode is estimated positive: about 0.1 to 0.85 ms per
16-seat episode and 2.8 to 6.4 ms per 32-seat episode (the earlier
"0.1 to 0.4 ms" range used one average cost and understated the 16-seat
figures; s2_16_679964 is 0.85 ms). Spread over the episode this is 0.03
to 2.8 us per tick on average, concentrated on rebuild ticks, where a tick
with eight list replays saves about 0.18 ms on m8i. The recorded windows
have sparse reuse, which is why the trace estimate is small; it is an
estimate of that workload only.

Configured gate potential (a different measured workload, kept separate):
in the configured rows every measured first fill is eight cache hits
(`C5_M5A_REVIEW.md`: replay alone about 2.35 ms of a 4.19 ms danger stage
on m5a, and fill ticks define the row p95). Under C9 the harness's static
eight sources would make seat 0's fill a miss, seat 1's fill the one
conversion, and every later seat's fill a list replay. If the m5a list
ratio from the micro (0.44 to 0.49) held for those replays, a first-fill
tick's replay share would fall by roughly half, on the order of a
millisecond on m5a, on exactly the ticks that set the configured p95; the
conversion tick would cost about a quarter of a replay more. That is a
potential to be measured in the whole-body runs, not a prediction, and
it is where more memory would have to earn a useful whole-body gain. The
trace criterion is not weakened: the full-trace pairs must show no
material real-trace or miss regression, and the whole-body rows must show
the gain, before any integration.

## 3. Ledger projection with both payloads (the request's correction to C7 arithmetic)

The C9 cache keeps the C2 bitmap payload (misses record exactly as C2)
and adds the list payload, a per-slot list length, and a second seq
owner. Both capacities are retained by construction and both are counted
at capacity:

| range px | bitmap payload | list payload | object (measured 1,056 + 64 lengths + list fields) | extra seq allowance | cache field total |
|---:|---:|---:|---:|---:|---:|
| 331 | 57,856 | 2,757,120 | 1,328 | 16 | 2,816,320 |
| 1300 | 855,552 | 27,736,576 | 1,328 | 16 | 28,593,472 |

Substituted into the integrated C2+V1 rows (the script asserts each row's
current cache field equals the C2 formula before replacing it):

| group | worst after | cap | margin |
|---|---:|---:|---:|
| configured 1300 px shared (11 rows) | 60,201,132 | 67,108,864 (64 MiB, authorized) | 6,907,732 (6.6 MiB) |
| configured 1300 px shared against the current 32 MiB | 60,201,132 | 33,554,432 | negative 26,646,700 |
| non-colossal 331 px shared (64 rows) | 19,009,886 | 33,554,432 | 14,544,546 |
| colossal 331 px total, as measured | 231,915,755 | 268,435,456 | 36,519,701 |
| colossal 1300 px total, conservative (1300 kernel and perimeter substituted, colossal cap unchanged) | 258,102,731 | 268,435,456 | 10,332,725 (9.9 MiB) |

C9 fits the authorized 64 MiB shared cap and the unchanged 256 MiB total
with about 6.6 MiB and 9.9 MiB of margin on this projection; it needs the
cap raise exactly as C7 did, plus 0.86 MB more for the retained bitmap. A
32-slot C9 is not proposed; the hit-loss counts from
`C7_RESEARCH_REVIEW.md` still apply. Padding caveat: adding an `int32`
list length to the 16-byte slot (`key: int32, lastUse: uint64`) may pad
the slot to 24 bytes, adding 512 bytes to the object, and the object and
both seq capacities must be measured with `sizeof` and `capacity` in the
final candidate rather than taken from this estimate; both owner
allocation allowances are preserved on integration.

## 4. Proposed C9 full-candidate plan (not implemented)

Source, one file (`body_nav.nim`), over the frozen C2 parent:

- Data: keep C2's bitmap seq and slot layout; add `entries:
  seq[DangerSourceEntry]` of `64 * capacity`, `capacity` from the actual
  nonzero kernel count at creation, and `listLength: int32` per slot with
  sentinel `-1` = not materialized. A materialized list of length 0 is a
  valid state distinct from `-1` (it cannot arise with this kernel, since
  the origin cell always has weight 1, but the code must treat 0 as
  "converted, nothing to add", never as "unconverted").
- Miss (unchanged C2 recording): claim victim, zero the bitmap words, set
  `listLength = -1`, run the ray walk recording bits exactly as C2. That
  reset is the list invalidation on slot reuse; no other invalidation
  exists because geometry and range are immutable per system.
- Hit: if `listLength < 0`, run the row-major bitmap traversal that adds
  every set cell and appends each nonzero (index, weight) entry, then
  store the count; else replay the list. The conversion is the C9 micro's
  `convertAndReplay` shape, reading the cache through the seat field, no
  per-cell `ref` local (the C7 refcount lesson), the entries seq accessed
  through the seat field as well.
- Unchanged: key and sequential 64-slot LRU, source order, exact-pixel
  floor, visit generations (uint32 in this parent), publishing, C5
  markers.
- Ledger: field = object + bitmap capacity times 8 + entries capacity
  times 8; both allowances; no cap constant change in the candidate.
- Diagnostics: existing order and counters, plus per-slot list lengths
  (with `-1` visible) for tests.

Regression tests (extend the C2 focused suite; keep its raster and LRU
checks):

1. Eviction reuse: the corrected 63-origin pattern; after the long slot is
   reused by a short source the slot's length is `-1` until the short
   source's first hit, then equals the short list; hit raster equals a
   fresh reference.
2. First versus later hit: same source three times; after the second
   rebuild the length is set, the third replays the list; all three
   rasters equal the reference and each other.
3. Border origins at 331, 1050, 1300 and 1600 px on miss, first hit and
   second hit.
4. Repeated empty selections and a rebuild with zero sources between
   hits: lengths untouched, rasters zero, cache order unchanged.
5. Zero-length valid list: the hit path's nonnegative-length branch
   covers 0 naturally, and no public mutation API or diagnostic setter is
   added to manufacture the state. If practical, an include-based
   internal test seam (the same private-access pattern the C6, C7 and
   C9 diagnostics use) sets a converted slot's length to 0 and asserts a
   hit adds nothing and does not reconvert; otherwise the test documents
   the invariant that the origin cell always carries weight 1, so a
   converted list is never empty, and asserts the `-1` sentinel converts
   on hit.
6. Rollover: the visit generation is C2's uint32 and untouched; the byte
   stamp rollover test stays with V1's tree and is noted as not
   applicable here.
7. Ledger: field equals the two capacities plus object exactly; total
   rises by exactly the field plus one allowance versus C2 on every map.
8. Real traces: the nine chains, hits and misses identical to C2; a
   count of conversions per trace equal to the sequential model's
   residencies-with-a-hit (`C9/c9_lazy_list_counts`), which is the first
   time the count model is checked against the implementation.

Native gates, restated from the request and not weakened: three
interleaved trace and regime pairs on both hosts against C2 with no
material real-trace or miss regression and the estimated trace benefit
reported against its estimate, unprofiled full quality on the old hash,
then the integrated 76-row memory rows and the configured whole-body
runs, where the additional memory must earn a useful whole-body gain on
the first-fill rows. No production implementation until the m5a micro
screen passes.

C9 PLAN CORRECTED READY (revision 2 of this review; the m5a micro screen was still running when revised)
