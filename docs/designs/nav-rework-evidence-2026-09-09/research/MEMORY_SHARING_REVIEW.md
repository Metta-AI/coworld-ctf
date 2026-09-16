# Memory-sharing review: per-seat geometry copies, the M1 fix, and the ledger audit

Written 2026-09-09 by Claude (peer) at Codex's request. Independent verification from
generated C and source; no source edits. Raw prior results are not altered; the caveats they
need are listed in section 5 for Codex to append to its own reports.
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. The defect, verified independently

Generated C from my Mac release build of the harness at the S1 tree
(`cache-g1/@m..@ssrc@sshell@sbody_nav.nim.c`, the emission Nim produces on any host), in
`newBodyNavSystem`'s seat loop:
```
colontmpD__2 = eqdup___...(dangerGeometry_1.Field0);   (*T55_).dangerKernel    = colontmpD__2;
colontmpD__3 = eqdup___...(dangerGeometry_1.Field1);   (*T55_).dangerPerimeter = colontmpD__3;
```
`initDangerGeometry` returned a tuple of two `seq`s held in a `let`; assigning its fields
into each seat's object constructor is a copy under ORC (`=dup`), not a move, so every seat
owned its own kernel and perimeter. By contrast the per-seat raster and visited workspace
are moved (`eqwasMoved` on `danger_1.Field0/Field1`), and `cache` is constructed per seat.
`retainedNavigationBytes` counted the geometry once, under `sharedDangerGeometry`, from
`seats[0]`. Codex's reading of the m5a C (lines 2090-2110 there) is confirmed here at the
same statements.

Size of one copy, from the ledger fields and the geometry arithmetic (kernel `(2r+1)^2`
float32 with `r = ceil(range / 8)`, perimeter `BodyPoint` = 16 bytes):

| range | radius | kernel bytes | perimeter bytes | per seat | 32 seats | uncounted (31 copies) |
|---:|---:|---:|---:|---:|---:|---:|
| 331 | 42 | 28,900 | 3,776 | 32,676 | 1,045,632 | 1,012,956 |
| 1,300 | 163 | 427,716 | 14,784 | 442,500 | 14,160,000 | 13,717,500 |

The 32,676 matches `shared_danger_geometry` in every 331 px ledger row
(`QUALITY/result.json`), and 442,500 matches the G1 local row at 1,300, so the copies are
exactly the ledgered geometry size, times the seat count.

## 2. Which numbers were wrong, and in which direction

- `total` (the 256 MiB check) was understated by 31 copies: about 1.0 MB on every 32-seat
  row at 331, about 13.7 MB at 1,300. No verdict flips: colossal at 331 was 261.9 MB and is
  really about 262.9 MB, under 268.4 MB; the G1 giant map at 1,300 was 61.5 MB and is really
  about 75.2 MB, far under the total cap.
- `shared_retained_upper_bound_bytes` (the 16 MiB pool check) was not understated. It
  included one geometry copy as shared; the copies were in fact per seat, so the shared
  figure was overstated by one copy (32,676 or 442,500 bytes), the conservative direction.
  Every pool pass/fail stands: 16,023,601 at L1 remains a pass, 30,504,907 on the giant map
  remains a failure.
- Real memory was higher than any ledger said by the uncounted amount, so the "exact
  ledger" wording in M0 and L1 was wrong for `total` even though the gate outcomes were
  right.

## 3. M1 in the working tree (diff against 29cf46f3), verified

- `DangerGeometry = ref object` with `kernel`, `perimeter`, `radius`; `initDangerGeometry`
  does `new(result)` and fills it once; each seat stores the reference (`dangerGeometry:
  dangerGeometry`). A `ref` assignment is a pointer copy with a refcount increment under
  ORC, so the sequences exist once. Correct.
- Ledger: `sharedDangerGeometry = sizeof(geometry[]) + kernel payload + perimeter payload`,
  plus one `SequenceAllocationOverhead` for the object and one per sequence. That is an
  honest accounting of the single shared owner; the constant is the same 16-byte allowance
  used elsewhere, so it is consistent, if approximate, for the object header.
- Hot path: `rebuildDangerFromPoints` reads `seat.dangerGeometry.kernel` and `.perimeter`
  through one pointer, passing the same `openArray` to `castRay` as before; bytes and
  results are identical by construction (same data), so every danger hash and route hash
  must be unchanged and the corpus assert is the exactness test.
- Not changed by M1: `dangerRangePx` stays per seat (an `int`), which is right since it is
  per seat by contract even though all seats receive the same value today.
- Side effect worth stating in the report: real memory drops by the uncounted amount
  (about 1.0 MB per 32-seat system at 331, about 13.7 MB at 1,300), which is a genuine
  saving on the giant maps, though it does not touch the failing shared bound.

## 4. Audit of the other ownership claims in `retainedNavigationBytes`

| Field | Constructed | Counted as | Verified |
|---|---|---|---|
| `routeIndex` | once (or supplied `preparedRouteIndex`, one object shared with the episode/harness) | shared | yes; when supplied, the same object is counted here and nowhere else in this ledger |
| `safetyScratch`, `mixedGraph`, `routeWorkspace`, `packedWeightScratch`, `dangerTrace` | once | shared | yes, single `new`/`newSeq` each |
| `seat.danger.values` (raster) | per seat, moved from `initDanger` | per seat | yes (`eqwasMoved`) |
| `seat.dangerWorkspace.visited` | per seat, moved | per seat | yes |
| `seat.packedWeights` | per seat, packed in the constructor | per seat | yes; swapped with the scratch under L1, lengths equal, count unchanged |
| `seat.cache` | per seat (`newBodySeatCache`) | `sizeof(cache[])` per seat | yes; `duckSlots` is an inline array; `map` is a shared `ref` (owned by the episode, correctly not counted). Caveat: `sizeof` covers inline fields only; if `BodyDuckResult` ever gains a `seq`, its payload would be uncounted. Today it is not counted either way, so this is a note, not a defect |
| `seat[]` itself | per seat | `sizeof(seat[])` | yes; the inline `installedRoute.spans` array is why `seat_owners` is about 99 KB per seat (3.17 MB for 32), consistent with the ledger |
| `dangerGeometry` | once after M1 | shared | yes after M1; per seat before |

Production path: `episode.nim:1144` activates bodies on the one shared `BodyNavSystem`
(`activateSeatBody(nav, seat)`). The overload at `body.nim:561-569` that builds a private
system per body is documented as a testing and solo convenience; its callers are
`tests/test_shell_ladder.nim` and `tools/benchmark_shell_default_play.nim`. Any memory or
timing from that benchmark tool is therefore not comparable to the shared-system harness.
No other duplicated shared structure was found.

## 5. Caveats the prior reports need (append, do not erase)

- `M0_REPORT.md`: "Colossal retains 261,140,828 bytes total" and "MEMORY_SUMMARY.json derives
  each shared sum from the raw ledger" are correct for the shared bound and understated for
  the total by about 32 x 32,676 - 32,676 = 1,012,956 bytes per 32-seat row (geometry copies
  were per seat, not shared). Verdicts unchanged.
- `L1_REPORT.md`: "All 65 allocation rows pass: largest pool shared 16,023,601 B; colossal
  total 261,919,620 B" same caveat on the colossal and every pool total; shared figures
  slightly overstated (conservative). Verdicts unchanged.
- `QUALITY/result.json` and every activation row before M1: `total` low by the same amount;
  `shared_danger_geometry` is one copy's size, and the field name overstated its sharing.
- `G1-local-peer` (1,300 px, giant map 0): total 61,526,603 is really about 75.2 MB; the
  shared bound 30,504,907 stands and still fails the pool cap.
- My own `L1_CODE_REVIEW.md` section 4 ("full memory accounting") and `MEMORY_REVIEW.md`
  section 1 accepted the ledger's categories as complete; both should carry a one-line
  pointer to this review. I will add those pointers to my two files; Codex owns its reports.

## 6. Tests M1 should carry
- Two seats' `dangerGeometry` are the same reference (`system.seats[0].dangerGeometry ==
  system.seats[1].dangerGeometry` by identity), and the kernel is not duplicated: the process
  RSS delta or `retainedNavigationBytes.total` for a 32-seat system at 1,300 px is lower than
  before M1 by about 13.7 MB (a coarse but real check via the harness's `rss_delta_bytes`).
- Danger hashes for the full corpus unchanged (the exactness gate); focused suites green.
- A ledger consistency test: sum of categories equals `total`, and `sharedDangerGeometry`
  equals `sizeof(geometry[]) + kernel + perimeter` computed independently from the radius.
