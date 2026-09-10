# C8_SCREEN_READY: zero-weight omission, isolated screen (exactness and counts)

Peer (Claude) per `C8_ROOT_REVIEW.md`, in `nav-source-cache` only. C6 v2
snapshots and tools were preserved first (`C8/baseline-c6v2/`, and the C6
folder is untouched). No primary or native edits; nothing committed. Root
owns primary source and native runners.

## 1. Arms

- Parent (`snapshots/parent-body_nav.nim`): frozen C2 plus inert C5
  markers, no C3 and no C6 arm; byte-identical to the C6 parent snapshot
  and to the archived C5 v2 bytes.
- Candidate (`snapshots/candidate-body_nav.nim`, `C8-candidate-over-parent.patch`,
  19 lines): in `addVisibleCell`, after the existing stamp store and
  kernel index, `let weight = kernel[kernelIndex]`; `if weight == 0'f32:
  return`; otherwise record the bit and add that same `weight`. No ray,
  cap, allocation, config, or source-order change; the stamp is stored
  before the check, so traversal and stopping are identical.
- The tree's screen source keeps both C6 and C8 behind booldefines that
  default off (`C8-screen-source-over-parent.patch`), so it stays
  byte-for-byte C2 in behaviour unless a define is passed.

## 2. Exactness, both snapshots built in place (`local-mac/`)

| check | parent | candidate |
|---|---|---|
| focused cache suite | 7 of 7 | 7 of 7 |
| body nav rework suite | 16 of 16 | 16 of 16 |
| nine-trace raster chains (counted replay build) | equal to the C2 recorded chains | identical to parent, all nine |
| hits and misses per trace | as C2 | identical to parent |
| raster mismatches versus a fresh same-arm system | 0 | 0 |
| ledger (`sharedDangerSourceCache`) at 331 / 1300 px | 58,912 / 856,608 | identical |
| kernel support at 331 / 1050 / 1300 / 1600 px | 5,385 / 54,173 / 54,173 / 54,173 nonzero cells, max offset 41 / 131 / 131 / 131, no negative or non-finite values | identical |

Old-versus-new raster equality is direct: the chain hashes are computed
over every rebuild's full raster by the parent build and by the candidate
build separately, and they match each other and the values recorded when
C2 was first replayed. Keys, hit and miss counts, and allocated capacities
are unchanged by construction (the change happens after the lookup and
does not touch slot selection or sizing) and were confirmed identical.

## 3. Counts (what intentionally changes)

Set bits per bitmap fall by exactly the parent's zero-kernel count:

| workload | parent set bits | parent zero-kernel bits | candidate set bits | candidate zero-kernel bits |
|---|---:|---:|---:|---:|
| s2_32_679963 hits (286 sources) | 4,180,051 | 233,053 | 3,946,998 | 0 |
| s2_32_679963 misses (244) | 2,917,274 | 198,898 | 2,718,376 | 0 |
| s2_16_679962 hits (75) | 1,146,869 | 90,377 | 1,056,492 | 0 |
| s2_16_679962 misses (121) | 1,676,981 | 121,332 | 1,555,649 | 0 |
| map 3, 1300 px, 9,657 cold rebuilds | 108,210,574 | 9,546,525 | 98,664,049 | 0 |
| map 3, 331 px, same origins | 30,564,378 | 1,048,347 | 29,516,031 | 0 |

Shares removed: 5.6 to 10.4 percent of recorded cells at 1300 px on the
nine traces (`C8_ZERO_REVIEW.md`), 8.8 percent on map 3 at 1300 px, 3.4
percent at 331 px.

Report corrections per `C8_ROOT_REVIEW.md`: the count tool classifies a
whole rebuild's sources as hit or miss before the rebuild, which root
verified equals sequential per-source LRU on these nine traces
(`C6_COUNT_ROOT_CHECK.md`); it is not a universal classifier. And the
zero-weight cells are those beyond `min(1050, live range)` px from the
source: beyond 1050 px at the configured 1300 px, beyond 331 px in the
331 px rows. The two workloads remove different cells.

## 4. What native must decide

Prediction, as preregistered by root: fewer bitmap bits and adds improve
hits; the extra load and branch on every first visit may cost on misses
and must be reported separately (changing-source and repeated-source
diagnostics, counters only in diagnostic outputs, full quality on the old
hash). A null overall result closes standalone C8 without primary
adoption; the kernel-support facts still stand for C7 sizing (exact
capacity from the nonzero kernel count computed in `initDangerGeometry`,
54,173 pairs at 1300 px, about 13.9 MB for 32 slots, no observed-max cap
and no overflow rule).

`run_c8_screen.sh` covers the exactness and count part with explicit exit
codes for two snapshot checkouts; root's C3-shaped timing runner supplies
the paired timings.

## 5. Cleanup and ownership

Tree state: C5 v2 plus the C6 and C8 booldefine arms in `body_nav.nim`
(both off), C6 tools, `tmp/c8/` raw outputs (copied to `local-mac/`).
Reverting C8 alone is `C8-screen-source-over-parent.patch` minus the C6
hunks, or restoring `C8/baseline-c6v2/screen-body_nav.nim`. The screen
source was hash-checked after the in-place snapshot builds.

C8 SCREEN READY
