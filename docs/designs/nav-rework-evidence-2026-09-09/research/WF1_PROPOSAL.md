# WF1 proposal: interval-narrowed wavefront screen, with a count-based stopping rule

Written 2026-09-09 by Claude (peer) for `WF0_RESULT_REQUEST.md`. Review of the m5a screen plus
new standalone counts (`peer-proofs/wf1_work_shape_count.nim`, stdout retained); no
production code, no remote mutation, no timing claims beyond quoting Codex's rows.
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. The m5a result, read independently
`WF0-screen-m5a/result.json` (EPYC 7571, CPU 5, 30 interleaved samples per row, all 14 rasters
bitwise equal): at 331 px the candidate p95 is 1.08 to 1.27x the parent on six maps and 0.93x
on colossal; at 1,300 px it is 1.99 to 3.57x on all seven. The per-row minima tell the same
story as the p95s (parents 1.8 to 12.1 ms, candidates 2.1 to 25.2 ms), so this is not tail
noise. The Mac pattern (candidate ahead at 331) does not hold on the bottleneck host; the
m5a rows are the evidence that counts. Verdict on WF0 as built: rejected, retained.

## 2. Why it lost: the work shape, counted on the same 14 rows
Same seeded sources and selection as the diagnostic (totals over the 8 selected sources):

| row | range | executed ray steps | of nominal | unique cells added | wave cells scanned | wave cells with an active member | steps beyond the kernel cutoff |
|---|---:|---:|---:|---:|---:|---:|---:|
| pool 0 | 331 | 65,739 | 99 pct | 23,522 | 45,216 | 23,522 | 703 |
| configured 5 | 331 | 59,971 | 99 pct | 21,502 | 43,344 | 21,502 | 673 |
| colossal | 331 | 69,503 | 99 pct | 27,325 | 45,216 | 27,325 | 954 |
| pool 0 | 1,300 | 341,099 | 23 pct | 54,162 | 448,312 | 54,162 | 1,363 |
| pool 29 | 1,300 | 361,377 | 24 pct | 68,989 | 565,012 | 68,989 | 3,505 |
| configured 0 | 1,300 | 357,658 | 24 pct | 74,712 | 671,424 | 74,712 | 10,405 |
| colossal | 1,300 | 541,570 | 36 pct | 161,080 | 671,424 | 161,080 | 37,499 |

(Full 14 rows in the retained output. "Nominal" is the open-disc step count, 12,352 per
source at 331 and 188,892 at 1,300.)
Three facts:
1. At 1,300 px rays die early on real maps: they execute about a quarter of their nominal
   steps. The wavefront, which scans every cell of every shell until all rays are dead, scans
   1.3 to 1.9x more cells than the rays executed steps, with a heavier per-cell operation.
   That is consistent with the loss (event counts, not a causal hardware attribution); at 331 px rays run nearly full length and the wavefront's cell
   count is below the step count, but its per-cell cost still made it lose by 8 to 27
   percent (colossal's win is the one row where step count dominated).
2. The wavefront's "cells with an active member" equals the unique cells added, exactly, on
   every row. So a wavefront that only touched active cells would do 6.8 to 9.3k adds per
   source at 1,300 px against 42.6 to 67.7k executed ray steps: about 5 to 6x fewer events.
   At 331 px: 2.7 to 3.4k against 7.5 to 8.7k, about 2.5x. The counts in
   `DANGER_PREFIX_REVIEW.md` (2.25 steps per unique cell on an open disc) understated the
   real-map redundancy; with walls, rays crowd into the same corridors and re-tread cells
   about six times at 1,300 px.
3. The active set stays angularly compact: after removals, the alive rays form a mean of
   2.5 to 3.4 contiguous runs per shell in angular order (max 9) on pool and configured
   maps, and 6.6 to 7.3 (max 18) on colossal. Narrowing to the active runs therefore costs a
   few interval operations per shell, not a scan.

Zero-kernel tail pruning, counted separately: steps beyond the 1,050 px cutoff are 0.4 to
2.9 percent of executed steps on the six ordinary rows at 1,300 px and 7 percent on colossal,
about 1 percent at 331 px. It is exact and trivial (stop a ray at its first zero-kernel cell,
since distance from the origin is non-decreasing along the walk and adding +0.0 to a
non-negative float is bit-identical), but its value on these rows is negligible. Rejected as
a candidate worth a screen; noted as a free one-liner if a ray-side change is ever made.

## 3. The one bounded next experiment: WF1, interval-cursor narrowed wavefront
Same exact algorithm as WF0 (proof unchanged), different enumeration and layout:
- Cells within each shell stored in angular order (by first member ray id), with compact
  records: `int16` relative coordinates, `uint16` first and last ray id (two ranges at most
  in the counts, but keep the variable form), and a per-shell offset table. About 0.7 MB at
  radius 163, 45 KB at 42.
- The active set as a sorted list of disjoint id intervals (a small fixed-capacity array,
  say 32, with a proved fallback to the bitset if it overflows), not a bitset. Removal of a
  blocked cell's range splits or trims the interval it intersects.
- Per shell: for each active interval, binary-search the shell's cell list for the first cell
  whose id range reaches the interval and walk forward while cells overlap it. Pass 1
  (blocked removal) and pass 2 (adds) both enumerate only those cells, in that order, so the
  same-shell removal rule is preserved exactly: a cell that pass 1 removed has no active
  member and is not visited by pass 2. Cells with no active member are never touched.
- Everything else (source order, origin, close floor, maximum, stamps left allocated) as WF0.

Cost argument, corrected after `WF1_ROOT_REVIEW.md` and then measured by the count gate in
section 4a. Corrections: the shell counts in section 2 were totals over eight sources (about
200 to 326 shells per source at 1,300 px), so the earlier per-source bookkeeping figure was
eight times too high; a cursor carried across shells does not locate the same interval in the
next shell's array (shell lengths and ranges differ), so the model uses a binary search per
interval per shell and counts it; a cell whose membership is more than one run (21 cells at
radius 42, 82 at 163, including the angular seam) can be reached from more than one interval,
so the model counts those duplicate touches and dedupes adds with a per-cell stamp; and the
diagnostic would keep ordinary integer fields and dynamically sized interval storage, with no
two-range or 32-run assumption. The wavefront-side cost is not "irreducible" anything; it is
what the counted operations say it is.

## 4a. Pre-build count gate: result (executed before any code)
Model (`peer-proofs/wf1_count_gate_model.nim`, stdout retained): for every source on the 14
rows, the exact ray visitor's executed steps, and for the interval-narrowed enumeration the
entries scanned (both passes, binary search from `first >= a - (maxLen - 1)`, scan while
`first <= b`), overlaps, duplicate touches, adds, blocked hits, binary searches (counted as 8
operations each) and interval operations, summed as `model_events`.

| row | range | executed steps per source | scanned | adds | model events | events / steps (median over sources) |
|---|---:|---:|---:|---:|---:|---:|
| pool 0 | 331 | 8,217 | 6,115 | 2,940 | 12,252 | 1.51 |
| configured 5 | 331 | 7,496 | 5,567 | 2,688 | 10,904 | 1.50 |
| colossal | 331 | 8,688 | 7,136 | 3,416 | 16,346 | 1.98 |
| pool 0 | 1,300 | 42,637 | 14,249 | 6,770 | 30,090 | 0.69 |
| configured 0 | 1,300 | 44,707 | 19,517 | 9,339 | 40,580 | 0.90 |
| colossal | 1,300 | 67,696 | 41,953 | 20,135 | 95,345 | 1.44 |
Median over all 56 sources: 1.52 at 331 px, 0.86 at 1,300 px. Full table in the retained
output.

Verdict: the gate fails at both ranges (thresholds 0.80 and 0.60). At 331 px, the corpus
range, the narrowed enumeration scans about as many entries as the rays execute steps
before any bookkeeping, because rays there rarely die and the ray step count is only about
2.25x the unique cells while the two-pass enumeration touches each active entry twice; even a
merged single-pass variant (halving `scanned`) lands near 1.0. At 1,300 px the model is at
0.86, with the best rows at 0.6 to 0.7, which would need a per-event cost no higher than a ray
step's to break even, and WF0 showed the per-event cost runs well above that. WF1 is not
built; no `WF1_PREREG.md` is written; the wavefront direction stops here with the proof, the
WF0 screen and these counts as the record. The one exact cheap item that survives is the
zero-kernel tail stop, worth 0.4 to 7 percent of ray steps on these rows, noted, not
scheduled.

## 4. Stopping rules, as decided before the gate ran
- Pre-build count gate (no code): using the retained count script extended with a
  cursor-enumeration event model, if the modelled events per source exceed 60 percent of the
  executed ray steps on the median 1,300 px row, or 80 percent on the median 331 px row, do
  not build WF1; record the counts as the rejection. (The numbers above pass this gate; the
  model is the check that the cursor amortisation actually holds on every row.)
- Screen gate (isolated diagnostic, WF0's protocol, m5a CPU 5, 30 interleaved samples, all
  14 rows bitwise equal): reject the wavefront direction if the candidate p95 is at or above
  0.9x the parent on the median 1,300 px row, or above 1.0x on the median 331 px row (331 is
  the corpus range and must not regress). One screen, no second layout iteration afterwards:
  if WF1 loses, the work shape is wrong for this host and the direction stops here, with the
  proof and counts retained as the record of why.
- Integration gate (only if the screen passes both ranges): the 76-map differential and the
  paired whole-body rows in `WF0_IMPLEMENTATION_PLAN.md`; whole-body p95 on the loaded rows is
  the acceptance, not the isolated slice.

## 5. What this does not claim
No speed, and no causal attribution of the WF0 loss beyond the event counts. The counts are
operations, not cycles; the m5a screen showed per-event cost can invert a favourable count.
With the gate failed, the ray walk with D0a is the measured danger cost on this host today,
not a proven floor; the remaining exact levers outside this proposal are the weight refresh
(P1, measured), the close-floor pass, and the shared per-source reuse ranked below.

## 7. Ranking against exact shared per-source LOS reuse (`SHARED_DANGER_CACHE_QUESTION.md`)
Prior notes: `QUALIFICATION_FLOOR_OPTIONS.md` option A (copy a whole raster between seats
with identical ordered source lists) was ranked as exact but benchmark-flattering, not
rejected; the per-source contribution reuse there (C2) was a non-exact float cache. The new
question is different from both: cache each source's visible node set (a sparse list of
relative or absolute cell indices), keyed by the quantized source cell, immutable map and
range, and re-add the kernel by relative offset for any seat that selects that source, in
that seat's source order, with the close floor applied from the exact pixel position as now.
- Exactness: the visible set of a source depends only on its cell, the immutable sight table
  and the geometry; each seat still performs one float add per cell per source in its own
  source order, so the raster is bitwise the same. Deterministic replacement keyed on rebuild
  order (no clocks) is required and easy. Sound.
- Work shape: a hit replaces one source's ray walk (5 to 8k executed steps at 331 px, 42 to
  68k at 1,300 px per source on these rows) by its adds only (2.7 to 3.4k and 6.8 to 20k), a 2
  to 6x event reduction per hit with the cheapest possible event (index, kernel load, add).
  A miss costs the current walk plus building the list. So its payoff is exactly the hit
  rate, and nothing in the harness (eight fixed tracks seen by every seat) says what that
  rate is in play; enemies move about a cell every two ticks and seats rebuild on a 32-tick
  cadence, so cross-seat hits need near-simultaneous rebuilds on a stationary enemy, while
  same-seat hits (a seat whose selection kept some sources) are the L0 case generalised to
  partial overlap.
- Memory: a bounded cache of visible lists; at 1,300 px a list is up to about 20k `int32`
  (80 KB), so 64 entries is about 5 MB, which does not fit the 1.9 MB margin under 32 MiB
  without the user's 4x allowance; at 331 px lists are about 12 KB and 64 entries fit.
  Ledgered at capacity, colossal total unchanged.
- Simplicity: it reuses the existing ray walk as its miss path and adds a keyed cache; the
  exactness argument is a paragraph. Simpler than any wavefront.
Ranking: shared per-source reuse is structurally more promising than the wavefront because
its gain is bounded by data (hit rate) rather than by a work shape the counts have now shown
unfavourable, and it is simpler. But it must not be screened on the synthetic harness first.
Its gate is a count, like WF1's: replay a realistic 16 and 32 seat input trace (a recorded
fixture or a shell-demo episode) through the production selection and log, per seat rebuild,
the selected source cells; simulate the cache policy offline (LRU by rebuild order, sizes 16,
64, 256) and report the hit rate per rebuild and the fraction of ray steps it would remove,
plus the adversarial cases in the question (disjoint sources, moving cells, eviction). If the
trace hit rate is below roughly 30 percent of ray steps removed, reject before any screen.
Order of work: A1 activation pairs (running) first; then the trace-driven hit-rate count for
the shared cache; the wavefront is closed.

## 6. Artifacts
`peer-proofs/wf1_work_shape_count.nim` and `.out` (14 rows: executed steps, unique cells,
wavefront cells scanned and with active members, kernel-cutoff tail, and the active-interval
statistics per shell).
