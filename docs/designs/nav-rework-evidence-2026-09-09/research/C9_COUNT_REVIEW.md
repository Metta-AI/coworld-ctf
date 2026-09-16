# C9_COUNT_REVIEW: deferred list materialization, counted on the nine real traces

Peer (Claude) counts-and-documents screen per `C9_LAZY_LIST_COUNT_REQUEST.md`.
No implementation, no native job, frozen C7 full source untouched. Script:
`C9/c9_lazy_list_count.py`; outputs `c9_lazy_list_counts-r050.json` and
`-r041.json` (the two native list/bitmap replay ratios used as the cost
model); table `C9/table.md`.

## 1. Method

Each trace's changed rebuilds are replayed in recorded source order
through a sequential 64-slot LRU updated after every source (production
order, not the pre-block classifier). A residency is one key's stay in the
cache from insertion to eviction (or to the end of the trace); its hits are
counted, and the first hit of a residency is separated from later hits.
Two policies are screened: materialize the list at a residency's first hit
(later hits replay the list) or at its second hit (hits after the second
replay it). The eager C7 full candidate is the reference: it builds the
list on every miss and replays it on every hit.

Cost model, explicit and only that: with `r` = list replay time over
bitmap replay time (native m8i 0.41 to 0.49 at 1300 px, m5a 0.44 to 0.49;
`C7_NATIVE_MICRO_REPORT.md`), each list replay saves `1 - r` bitmap-replay
units, so the maximum one-time extra conversion cost `X` a trace can
afford (in bitmap-replay units per conversion, on top of the bitmap replay
that hit performs anyway) is `X = (1 - r) * list_replays / conversions`.
Both `r = 0.50` (conservative) and `r = 0.41` (best native) are reported.

## 2. Counts

| trace | sources | misses | hits | first hits | later hits | residencies | hits per residency 0 / 1 / 2 / 3+ | first-hit policy: conversions, list replays, max extra cost (r 0.50 / 0.41) | second-hit policy: conversions, list replays, max extra cost (r 0.50 / 0.41) |
|---|---:|---:|---:|---:|---:|---:|---|---|---|
| s2_16_679962 | 196 | 121 | 75 | 35 | 40 | 121 | 86 / 17 / 7 / 11 | 35, 40, 0.57 / 0.67 | 18, 22, 0.61 / 0.72 |
| s2_16_679963 | 134 | 86 | 48 | 21 | 27 | 86 | 65 / 13 / 3 / 5 | 21, 27, 0.64 / 0.76 | 8, 19, 1.19 / 1.40 |
| s2_16_679964 | 189 | 112 | 77 | 31 | 46 | 112 | 81 / 15 / 6 / 10 | 31, 46, 0.74 / 0.88 | 16, 30, 0.94 / 1.11 |
| s2_16_679965 | 121 | 92 | 29 | 17 | 12 | 92 | 75 / 11 / 2 / 4 | 17, 12, 0.35 / 0.42 | 6, 6, 0.50 / 0.59 |
| s2_32_679962 | 757 | 382 | 375 | 92 | 283 | 382 | 290 / 39 / 8 / 45 | 92, 283, 1.54 / 1.81 | 53, 230, 2.17 / 2.56 |
| s2_32_679963 | 530 | 244 | 286 | 70 | 216 | 244 | 174 / 37 / 9 / 24 | 70, 216, 1.54 / 1.82 | 33, 183, 2.77 / 3.27 |
| s2_32_679964 | 673 | 378 | 295 | 97 | 198 | 378 | 281 / 49 / 12 / 36 | 97, 198, 1.02 / 1.20 | 48, 150, 1.56 / 1.84 |
| s2_32_679965 | 554 | 306 | 248 | 84 | 164 | 306 | 222 / 38 / 16 / 30 | 84, 164, 0.98 / 1.15 | 46, 118, 1.28 / 1.51 |
| smoke_s2_16_randomized | 137 | 104 | 33 | 18 | 15 | 104 | 86 / 9 / 6 / 3 | 18, 15, 0.42 / 0.49 | 9, 6, 0.33 / 0.39 |

Zero-hit residencies are 71 to 83 percent of all residencies on every
trace (0.745 overall): three of four cached sources are never requested
again before eviction. Of the residencies that are hit at all, roughly
half are hit exactly once. Later hits (the only hits a lazy list can
speed up) are 12 to 46 per 16-seat episode and 164 to 283 per 32-seat
episode.

## 3. Reading the break-even column

- Eager C7 pays a list write on every miss: 86 to 382 writes per episode
  to serve 29 to 375 hits, and 71 to 83 percent of those writes are never
  read. That is the structural reason the changing-source regime
  regressed 26 to 31 percent locally.
- First-hit materialization pays only on residencies that were hit at
  least once (17 to 97 per episode), and it earns 12 to 283 later list
  replays. The extra cost per conversion it can afford before breaking
  even is 0.35 to 0.74 bitmap units on the 16-seat traces and 0.98 to
  1.54 on the 32-seat traces at r = 0.50 (0.42 to 0.88 and 1.15 to 1.82 at
  r = 0.41). Materialization during a hit is one bitmap traversal that
  also writes an 8-byte entry per cell, so its extra cost is the entry
  writes, plausibly well under one bitmap unit; that is the unknown the
  request names, and it is what a micro must measure, not assume.
- Second-hit materialization converts fewer residencies (6 to 53) and
  earns fewer replays, but every conversion is on a key already proven to
  repeat: affordable extra cost 0.50 to 1.19 at 16 seats and 1.28 to 2.77
  at 32 seats (r = 0.50). It is the safer policy on the 16-seat traces,
  where two of five (s2_16_679965, smoke) can afford only 0.35 to 0.42
  units under first-hit.
- Negative traces are not hidden: s2_16_679965 and the randomized smoke
  have 12 and 15 later hits per episode; under first-hit they can afford
  at most 0.35 and 0.42 units, and under second-hit 0.50 and 0.33. If the
  measured conversion overhead is around half a bitmap unit, those two
  traces are net neutral or slightly negative under either policy while
  the 32-seat traces remain clearly positive.

## 4. What the counts say and do not say

They say: the hit distribution is heavy-tailed, most cached sources are
never reused, and deferring the list to first or second hit removes the
wasted writes that eager C7 makes on every miss while keeping most of the
later-hit replays (first-hit keeps 100 percent of later hits; second-hit
keeps 50 to 85 percent). They do not say the scheme is faster: the
conversion overhead is unmeasured, the bitmap payload (0.86 MB at 1300 px)
comes back on top of the list payload and must be ledgered against the 64
MiB cap (about 60.2 MB configured shared, 6.6 MiB margin), the length
sentinel adds a branch per hit, and the miss path returns to exactly C2.
Counts cannot authorize C9 source.

## 5. If C7 full's native miss regression holds

Then the eager list is out, and the choice is between C2 (bitmap only) and
a deferred list. The counts favour second-hit materialization on the
16-seat traces and either policy at 32 seats. The alternative if the
native later-hit savings turn out small in whole-tick terms is to stop at
C2 plus nothing: on real play the danger rebuild is a minority of the
tick (`C5_M5A_REVIEW.md`: no-fill ticks are planning-dominated), and a
list that only helps 12 to 46 later hits per 16-seat episode may not be
visible at p95 at all. The one micro that would settle the direction is
a first-hit conversion cost measurement (bitmap traversal plus entry
writes) against the bitmap replay on the same origins; anything above
about 0.5 units closes the 16-seat case, anything above about 1.5 closes
all of it.

## 6. Limitations recorded per `C7_REFCOUNT_REVIEW.md`

- A residency ends either at eviction or at the end of the trace; the two
  are pooled above. "Zero-hit" therefore means no observed hit before
  eviction or before the trace ended, not that the key would never have
  been hit; trace-end-resident lifetimes are censored.
- Second-hit materialization is not uniformly safer: on the randomized
  smoke trace its affordable extra cost (0.33) is below first-hit's
  (0.42). The policy choice is per-workload, not a rule.
- `C5_M5A_REVIEW.md` attributes synthetic configured cold fills; it is not
  proof that real-play danger is a minority of the tick, and section 5's
  fallback sentence should be read with that limit.
- The count script now labels traces from either the per-episode layout
  (`<run>/navsrc.txt`) or named files (`<run>.navsrc.txt`) and records each
  input's path and SHA-256 in the JSON.

C9 COUNT READY (revision 2)
