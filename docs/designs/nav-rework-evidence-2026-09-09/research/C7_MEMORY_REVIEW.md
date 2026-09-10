# C7_MEMORY_REVIEW: 64 versus 32 list slots against the integrated ledgers

Peer (Claude) documents-only review per `C7_MEMORY_REVIEW_REQUEST.md`.
Everything below is proposal arithmetic substituted into the measured
integrated C2+V1 ledgers (`C2-integrated-activation-mac.json`, 65 rows at
331 px including colossal; `C2-integrated-configured-mac.json`, 11 rows at
1300 px), not a measured final ledger. Reproducible calculation:
`C7/c7_memory_calc.py` with outputs `c7_memory_calc-64.json` and
`c7_memory_calc-32.json` (every row's before and after). No cap or source
change is proposed here; integration still needs the exact ledger from the
real constructor.

## 1. What is substituted

Current bitmap cache field per system (ledgered as `shared_danger_source_cache`,
object plus words times 8; its seq allowance sits in `allocator_overhead`):
58,912 B at 331 px, 856,608 B at 1300 px.

Proposed list cache: N slots, capacity per slot equal to the nonzero kernel
count measured from the real kernel (`C8_ZERO_REVIEW.md`: 5,385 at 331 px,
54,173 at 1300 px and any range of 1050 px or more), 8 bytes per entry
(int32 grid index, float32 weight), plus per-slot metadata (key int32,
length int32, lastUse uint64: 16 B), a fixed object part (about 32 B) and
one seq allowance (16 B, the same single allocation as today's bitmap seq).
The per-seat ref (8 B per seat in `seat_owners`) already exists for the
bitmap cache and does not change.

| slots | list cache at 331 px | list cache at 1300 px | delta versus bitmap at 1300 px |
|---:|---:|---:|---:|
| 64 | 2,758,192 B | 27,737,648 B | +26,881,040 B |
| 32 | 1,379,120 B | 13,868,848 B | +13,012,240 B |

(Root's 27,736,576 is the 64-slot payload alone; metadata adds 1,072 B.)

## 2. All 76 rows after substitution (64 slots)

| group | rows | worst shared before | worst shared after | cap | margin | worst total after | total cap margin |
|---|---:|---:|---:|---:|---:|---:|---:|
| non-colossal, 331 px (activation) | 64 | 16,252,478 | 18,951,758 | 33,554,432 (32 MiB, current) | 14,602,674 | 32,084,654 | 236,350,802 |
| configured, 1300 px | 11 | 32,464,268 | 59,345,308 | 67,108,864 (64 MiB, authorized) | 7,763,556 | 82,128,348 | 186,307,108 |
| configured, 1300 px against the current 32 MiB cap | 11 | | 59,345,308 | 33,554,432 | negative 25,790,876 | | |
| colossal, 331 px as measured | 1 | 138,377,419 shared (colossal is exempt from the shared cap) | | | | 231,857,627 | 36,577,829 |
| colossal at 1300 px, conservative | 1 | | | | | 257,246,907 | 11,188,549 |

The conservative colossal case replaces the 331 px cache (58,912) with the
1300 px list (27,737,648) and the 331 px geometry (422,444, of which
389,768 is the object plus the map-sized `sightBlocked`) with the 1300 px
geometry (that part plus the 427,716 B kernel and 14,784 B perimeter:
832,268), leaving the map-sized rasters, workspaces and packed weights
unchanged because they do not depend on range. It stays under 256 MiB
with 10.7 MiB to spare. Colossal is not a configured map, so this is the
bound the request asked for, not an expected deployment.

Every one of the 76 rows passes its cap with 64 slots under the
authorized 64 MiB non-colossal shared cap; the configured rows fail the
current 32 MiB cap by 25.8 MB, so 64 slots requires the authorization to
be exercised.

## 3. The same with 32 slots

Configured worst shared 45,476,508 (margin 21,632,356 under 64 MiB, still
11,922,076 over the current 32 MiB); colossal 331 px total 230,478,555;
colossal 1300 px conservative 243,378,107 (margin 25,057,349). So 32 slots
also needs the cap raise; it does not fit the current 32 MiB either. The
choice between 32 and 64 is therefore not "raise the cap or not" but
"7.4 MiB or 20.6 MiB of margin under the raised cap".

## 4. Hit cost of 32 slots (measured, `cache-trace/cache_sim_results.txt`)

LRU-32 versus LRU-64 hits on the nine real traces: 16 seats 74/75, 48/48,
77/77, 29/29, 33/33; 32 seats 356/375, 278/286, 265/295, 240/248, that is
5 to 10 percent fewer hits at 32 seats and up to 0.05 less of the ray
work removed. At 1300 px each lost hit is one full ray walk (about 60,000
ray steps, 1.5 ms per source on m5a per `C5_M5A_REVIEW.md` miss figures)
against a replay that the micro shows is far cheaper.

## 5. Ranges and growth

Capacity is fixed by the kernel's nonzero support: 54,173 for every range
of 1050 px or more, so the list does not grow past the configured 1300 px
figure for larger live ranges; the geometry's kernel does grow (643,204 B
at 1600 px) and the bitmap words would have, which is a second reason the
list is range-stable. Below 1050 px the capacity shrinks with the range
(5,385 at 331 px).

## 6. Recommendation

Retain 64 slots. It fits every current row under the caps the user has
authorized (64 MiB non-colossal shared, 256 MiB total) with 7.4 MiB and
10.7 MiB of margin respectively, and it avoids the measured 5 to 10 percent
hit loss at 32 seats that 32 slots would reintroduce; 32 slots would need
the same cap raise for a smaller benefit. Conditions, in order: (1) the
native C7 v2 micro must pass its preregistered threshold; (2) the miss-path
list recording and the full nine-trace pairs must show no material
regression; (3) the exact ledger from the real constructor on all 76 maps,
configured 1300 px and colossal must reproduce the numbers above within
the metadata estimate before the cap constant changes. Until then this
review is a proposal; the ledger fields to add are one `shared_danger_source_cache`
replacement counted by capacity, exactly as C2 did.

C7 MEMORY REVIEW READY
