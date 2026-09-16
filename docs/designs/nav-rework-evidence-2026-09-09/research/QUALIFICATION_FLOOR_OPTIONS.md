# Qualification floor: narrow remedies for the per-tick danger rebuild cost

Written 2026-09-09 by Claude (peer) at Codex's request. Review and ranking only; no code.
Inputs: Codex's first two c6a L0 repeats (pop arrays preserved; p95 about 4 percent better;
skipped refreshes 120 to 26 at 32 seats; the remaining rebuilds are each seat's first cadence
and still occupy more than 5 percent of the 120 samples), the m5a B0 row (p95 6.06 ms, danger
3.4 ms of which weights 1.1 ms), the B0 m6i split (`PEER_PLAN.md` 4.5), and source at
8265f53a plus the L0 diff. Numbers quoted from Codex are not independently verified.

## 0. What the floor is

At 32 seats one seat's scheduled rebuild lands on every tick (`DangerCadenceK = 32`), so the
p95 tick always contains one rebuild. A rebuild on the largest pool map is: zero a ~42.7k-cell
float32 raster (about 171 KB; the packed table is 85,466 bytes per seat, 2,734,912 / 32 from
Codex's ledger, and my earlier "172k entries" figure was wrong), cast the LOS kernel for each of up to 8 sources (radius
`liveGunRangePx / 8` cells, 85 x 85 = 7,225 kernel cells per source at the harness's 331 px),
apply the close floor per source, one pass for the LOS weight and maximum, then
`rebuildPackedWeights`: one pass packing the raster to Q8 and a second scatter pass setting
the hot bit on the 3 x 3 neighbourhood of every danger > 0 cell. On m6i that is roughly
1.0 ms raster plus 0.46 ms table; on m5a (Zen 1) Codex measured 3.4 ms in total. L0 removes
rebuilds whose ordered sources are unchanged; it cannot remove a seat's first rebuild or any
rebuild after a change, and the harness's 120-sample window still contains the first rebuild
of every seat (32 of 120 samples at 32 seats), which is why p95 barely moved.

Two things follow. First, in the harness the first-rebuild share is a window artefact: over a
long episode with stationary threats the steady state is L0's 26 rebuilds per 120 ticks, not
32 plus 26. Second, in real play the share is whatever the threat picture makes it, and a seat
with moving visible enemies rebuilds every 32 ticks regardless. Any remedy must be judged on
the second, not the first.

## 1. Option A: cross-seat reuse of a computed raster (copy into existing buffers)

Mechanism: when a due seat's ordered sources changed (L0 miss), scan the other seats for one
whose `selectedDangerCount` and ordered `selectedDangerPoints[0 ..< count]` are identical
(lowest seat index wins, deterministic), and if found copy that seat's `danger.values`,
`danger.maximum` and `packedWeights` into the due seat's own buffers instead of rebuilding.
Then `dangerTick = tick`, and the generation bump and route expiry as on the changed path.

Correctness:
- The raster and table are pure functions of the ordered points and the shared geometry.
  Geometry is shared by construction: `initDangerGeometry(liveGunRangePx)` is called once and
  every seat takes the same kernel, perimeter and radius (283-294), and every seat has the same
  `dangerRangePx`. The map is immutable. So identical ordered points give bitwise-identical
  outputs on any seat; a copy equals a rebuild byte for byte, and the corpus route hash is
  unaffected by construction.
- Invariant required: a seat's raster and table always correspond to its stored ordered
  points. True today at every point where another seat could read them: selection and rebuild
  are adjacent in `rebuildDanger` and in the changed branch of the cadence; the L0 unchanged
  branch leaves both as they were; the constructor state (count 0, zero raster, table packed
  from the zero raster at 296-299) is consistent for route-enabled seats. One caveat: a seat
  constructed without route queries has no table (`packedWeights` empty); the donor scan must
  require a non-empty table or copy only the raster and repack. Simplest rule: only donate when
  the donor's `packedWeights.len == cellCount`.
- The copy is into the recipient's existing buffers (memcpy of about 171 KB plus 85 KB); no
  aliasing, no new retained state, no new hash. `dangerWorkspace.visited` is scratch and must
  not be copied.
- Determinism: pure, deterministic donor choice; the result does not depend on which donor is
  chosen because all candidates hold identical bytes.
- Tests: copy versus forced rebuild byte-equality on a two-seat system; donor with an empty
  table is skipped; donor whose points differ in order is not used; the generation still
  bumps for the recipient; route expiry still happens.

Cost: the scan is at most 31 x 8 point compares; the copy is about 256 KB of memcpy, which on
these hosts is a few microseconds against a 1.4 ms (m6i) or 3.4 ms (m5a) rebuild.

Real-world utility (the honest part): a copy is available only when two seats' visible
enemies are the same set in the same distance order. Candidates are per-seat beliefs
(`dangerInputFromTracks`: tracks fresh this tick), so this needs overlapping vision and
similar positions. In the Season 2 duo format teammates are often co-located and see the same
enemies, so hits are plausible within a duo but rare across duos. In the harness every seat
sees the same 8 static tracks from the same start, so hits are near-universal there: option A
is benchmark-flattering and the c6a and m5a rows will overstate its production value. It does
remove the "first rebuild of every seat" share in the harness window, which is exactly the
term Codex identified, so it will likely make the m5a row pass; it will not make a production
seat with its own threat picture cheaper.

Verdict: correct, narrow, state-free, and within the approved rule (skipping work whose inputs
are provably identical). Worth doing for the qualification only if it is reported as what it
is: a same-input dedup that helps co-located seats, measured on a harness where all seats are
co-located.

## 2. Option B: optimise packed-weight hot marking

Mechanism candidates, all required to produce a bitwise-identical table:
- B1: fold the hot bit into the pack pass with a 3 x 3 danger > 0 test per cell (read 9 floats,
  write 1) instead of a scatter of 9 writes per hot cell. Work moves from "9 per hot cell" to
  "9 per cell"; a win only when the hot set is dense, which it is under a big LOS field, and a
  loss on quiet rasters. Not a clear win.
- B2: row-wise dilation: for each row compute a horizontal 3-wide OR of danger > 0 into a
  temporary row bitmap, then the vertical OR of three rows while packing. About 3 operations
  per cell, one pass, a few KB of scratch (three row bitmaps), no retained state. Exact.
- B3: derive the hot set from the raster rebuild instead of rescanning: the LOS painter already
  knows which cells it touched (the visit stamps in `dangerWorkspace.visited`); dilating that set
  is the same as dilating danger > 0 only if every touched cell ends with a positive value,
  which the close floor and attenuation may not guarantee near the kernel edge. Needs a proof
  or an exactness test; otherwise reject.
- B4: skip the second pass when `selectedDangerCount == 0` (the raster is all zero, so no hot
  bits); trivial and exact, and it also covers the constructor's initial pack.

Expected effect: the table pass is about 0.46 ms on m6i and 1.1 ms on m5a; the scatter is a
fraction of that (the Q8 conversion with range check dominates pass one). B2 plausibly saves
0.1-0.2 ms on m6i and 0.3-0.5 ms on m5a. Applies to every rebuild in production, not just
identical inputs, so its utility is general but its magnitude is small. It cannot close a
2.5 ms gap on m5a by itself.

Correctness and dependencies: pure local rewrite of `rebuildPackedWeights`; the only consumer
of the table is the search; exactness is testable by comparing the old and new packers on the
corpus rasters. No contract question.

Verdict: do B4 now (free), B2 as a measured micro-optimisation under the A/A protocol; B1 and
B3 not worth the risk for the size of the prize.

## 3. Options that touch the raster rebuild itself (bigger prize, need decisions)

- C1: raster-pass micro-optimisations that keep bytes exact: compute the maximum during
  accumulation instead of a final pass (max is order-independent); drop the `DangerLosWeight
  != 1.0` multiply loop when the constant is 1.0 (it is); zero with a memset. Saves one or two
  passes over 171 KB, perhaps 0.05 ms on m6i. Exact, no decision needed, small.
- C2: per-source contribution reuse (keep each source's field and add or subtract on change).
  Float addition is not associative, so the result is not bitwise equal to a from-scratch
  rebuild; routes could change in rare Q8 boundary cases; the corpus `danger_hash` strata and
  the equivalence contract would need re-ratification. Largest real-world win for moving
  threats (only the moved source is recomputed). A decision, not a qualification fix.
- C3: split one seat's rebuild across two ticks into a staging raster, publish on the second.
  Halves the per-tick floor at the cost of one tick of danger latency and one shared 171 KB
  staging buffer (counted in shared retained). Exact bytes, but a behaviour change in when
  danger becomes visible to the search; needs a decision and a replay/GameVersion cycle.
- C4: a uint8 or uint16 raster (the listed follow-up in the design brief). Halves or quarters
  memory traffic in every pass, but changes values, so routes change; needs the corpus gate
  re-run and a decision.
- C5: reduce the LOS range or kernel. Gameplay change; out of scope.

## 4. The option that is not code

The m5a rows are 2-3 of 33 running CTF containers (Codex's inventory). If James accepts a
Karpenter instance-generation floor of 6 (or an explicit family exclusion of m5a and c5) for
the jobs pool, the slowest hosts leave the fleet and the qualification host becomes c6a, where
the B0 and L0 rows already pass at B = 1,024 and 2,048. Cost: slightly less spot capacity and
a devops change in the metta chart, not this repo. This is the only remedy that removes the
m5a floor without changing what the game computes, and it should be on the table next to
options A and B rather than after them.

## 5. Ranking for the qualification, with what each one is worth outside it

| Rank | Option | Closes the m5a gap? | Exact bytes | New state | Decision needed | Production value |
|---|---|---|---|---|---|---|
| 1 | Fleet floor (section 4) | yes, by removing the host | n/a | none | James, infra | none in code; removes a host class |
| 2 | A cross-seat copy | likely in the harness | yes | none | no (identical inputs) | co-located duos only; benchmark-flattering |
| 3 | B4 plus B2 packer | no (0.3-0.5 ms) | yes | row scratch | no | general, small |
| 4 | C1 raster passes | no (~0.1 ms) | yes | none | no | general, small |
| 5 | C3 split rebuild | halves the floor | yes | shared staging buffer | yes | general |
| 6 | C2 per-source reuse | large for moving threats | no | per-source fields | yes, re-ratify | largest |
| 7 | C4 narrower raster | large | no | none | yes, corpus | large |

Recommendation for the current unit: A plus B4 as the narrow, exact set, reported with the
caveat in section 1; put section 4 to James at the same time, because if the fleet floor is
accepted the m5a qualification stops being the constraint and A's benchmark benefit stops
mattering. Do not let A's harness result stand in for a production floor reduction; the
honest floor statement for a moving-threat seat on m5a remains about 3.4 ms per rebuild tick
until C2 or C3 is decided.

## 6. L1: exact packed-table equality through one shared scratch buffer (liveness prerequisite)

Context (Codex, c6a, L0 applied): far waves still starve, 3 of 16 and 3 of 32 seats publish
per far wave, 33-40 restarts per wave, because the same eight points reorder as the seat
moves toward the cluster and L0's ordered compare treats that as a change.

Mechanism: on an L0 miss, rebuild the raster as today, then pack into one shared map-sized
scratch table instead of the seat's table; compare scratch with `seat.packedWeights` exactly
(full memcmp, no hash); if equal, leave the seat's table, do not bump the generation, keep the
in-flight job, still expire the installed route; if different, swap or copy scratch into the
seat's table and take the changed path (bump, expire).

Correctness:
- The search reads only the packed table (`beginBodyRouteSearch`, `spendBodyRoutePops`); the
  float raster has no other consumer in `src/shell` except the packer and a diagnostic
  snapshot (`dangerSnapshot`). So "table unchanged" is exactly "every value the search can read
  is unchanged", and continuing the job is identical to an uninterrupted search. No
  changed-table continuation: the generation still bumps on any byte difference.
- Exact compare, no collision risk: a byte compare of 85,466 bytes on the largest pool map,
  778,752 on colossal, a few microseconds; no hashing.
- The rebuilt raster is always written to the seat (fresh), and when the table is equal the
  old table is the packing of the new raster by definition of equality, so nothing is stale.
- Swap versus copy: `swap(seat.packedWeights, scratch)` is O(1), allocation-free and not an
  alias (ownership moves; scratch then holds the previous table and is overwritten at the next
  rebuild). A copy is equally correct at 85 KB. Either way no reader holds the table across
  ticks: the search takes it as an `openArray` per call.
- Reorder residual: with a reordered same set the raster can differ in the last bit; the Q8
  packing (`packedDangerQ8`, round to 15-bit) will almost always erase that, but not provably
  always, so a rare restart remains possible. Report `scheduler_restarts` per far wave; expect
  near zero, not zero by proof.
- Ordering of checks: L0 ordered compare first (skips the rebuild entirely), then L1 (skips only
  the bump). L1 does not reduce the danger floor at all: the raster rebuild and pack still run
  on every miss. It is a liveness fix, and it should be recorded as such, separate from the
  floor options above.
- Retained memory: one shared scratch of 85,466 bytes (pool) or 778,752 (colossal) belongs in
  the shared ledger (`retainedNavigationBytes`, under the mixed graph or workspace line) and in
  the harness's pool 16 MiB gate. After M0 the pool margin was 839,121 bytes, so it fits;
  colossal at 250.5 MiB plus 0.78 MB fits under 256 MiB. Codex's statement that both fit
  "if explicitly ledgered" is right; the ledger line is a must, not an option.
- Determinism: pure. GameVersion, fixtures and viewer as for L0 (masks change).

Tests required: same set reordered by moving `selfXy` while the table stays equal:
generation unchanged and in-flight job preserved (workspace generation equal); a genuine
change (source moves one cell into a new LOS region): bump and expiry; scratch contents after
a swap are never read (a test that corrupts scratch after the rebuild and checks the seat's
table and the next rebuild are unaffected); retained ledger includes the scratch and the pool
gate still passes on every pool map; `--latency` far waves publish every seat with restarts
reported; corpus route hash unchanged.

Position in the ranking: L1 is a prerequisite for any B = 1,024 qualification that includes a
completion criterion, independent of the floor. It does not change the section 5 table; the
m5a floor remains the section 4 or C-option question.
