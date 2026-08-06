# The measuring stick, corrected — and the epic's real baseline

Epic 3757029c, LANE C (task 4fb75b77). Branch `maxwell/mapgen-metrics-stick`,
off `maxwell/mapgen-rebuild` at 4a013df. **Not merged** — the epic owner merges.

Every number recorded before this branch was taken with a different instrument.
This is the re-score under the corrected one, with `arena` and `arena-large` as
labelled controls in every batch.

Reproduce:

```
nim c -d:release --out:bin/stick_probe tools/stick_probe.nim
bin/stick_probe --teams 2 --pool --gen 1001-1020
bin/stick_probe --teams 4 --gen 1001-1020
bin/map_eval score gen:1003          # both controls prepended automatically
```

---

## What changed, and what moved

| # | Correction | Did it move anything? |
|---|---|---|
| 1 | Diagonal runs gate | **Yes, a lot.** Two new bands. On 13 of 36 maps at 2 teams the longest open line is the diagonal; at 4 teams it is **every single map**. |
| 2 | Chokepoints carry a pinch length | **Yes.** Four pool seeds ship a mandatory pinch longer than survivable, worst +83px. Previously invisible. |
| 3 | Isovist re-cut at 259px | **Yes, and it loosened.** Took the "one camper owns every route" flag off 3 of the 5 maps carrying it. |
| 4 | Stand-side cover floor | **Yes.** Seven maps breach the distance floor. The *fraction* floor moves nothing and cannot — see below. |
| 5 | *(found on the way)* runs measured between standable ends | Small but everywhere: 3–4% off every run number, including both controls. |
| 6 | *(found on the way)* `bandHard` actually rejects | **Yes at 4 teams:** seeds 1001, 1007, 1020 go 0.74 → **0.00**. Nothing at 2 teams. |

### The one that moved nothing, stated plainly

**`standCoverMin`'s absolute floor does not bite on today's population.** It is
set at 1.5% and the measured minimum is 3.0%. That is not a mistake and it is
not fixable by raising it: the fraction is *not scale-free*. `arena-large` is
the same furniture on a 69% bigger board and reads 2.6% where `arena` reads
7.2%, without one obstacle moving relative to the stand. Any bar high enough to
mean something flags a control. So the fraction can only ever be a **nakedness
detector** — it exists so a stand with literally nothing beside it cannot score
a perfect fairness spread and pass, which is exactly the defect in the brief.

The floor with teeth is `standCoverGapMaxPx`, bounded by `MaxExposedRunPx` =
132px because that is physics rather than a share of the board.

---

## The four blind spots, with the control's numbers

### 1. The open-run scan was axis-only — and the diagonal is the longest line

The brief's numbers (arena 790px diagonal vs 663px axis, arena-large 1185px)
reproduce. Two things turned up underneath them.

**The runs were seeded in the border gutter.** Every board carries a ~10px strip
between the border ring and the first floor a 13px body fits on. It is open for
the map's whole perimeter, so before this change the longest row, column *and*
diagonal on every map — both controls included — started in it. Runs are now
measured **between two `corridorOpen` endpoints**: a line nobody can stand at
either end of is not a firing lane. The honest size of that correction is 3–4%,
not a cliff — those lines are *anchored* in the gutter but travel through real
playfield:

| | before | after |
|---|---|---|
| arena, longest row | 663 | 638 |
| arena, longest diagonal | 790 | **758** |
| arena-large, longest row | 868 | 843 |
| arena-large, longest diagonal | 1185 | **1149** |

**The diagonal metric that already existed could never have gated.** `map_metrics`
reported `diagLongRunFrac` — the share of diagonal *runs* over 600px. The
diagonal scan emits a run per diagonal, most of them short corner clips, so the
denominator is polluted: arena reads **10.4% long by axis count and 0.2% by
diagonal count** while its longest diagonal is *longer* than its longest row. A
band on that number never fires. The gated form is pixel-weighted
(`diagLongRunPxFrac`), which makes the two scans the same measurement.

Two bands now:

- **`sightlineMaxPx` ≤ `GunRange` (1050px)** — longest unbroken line on any of
  the four axes. This is the validator's own horizontal rule said as a *length*.
- **`diagLongRunPxFrac` ≤ 0.15** — arena 1.0%, arena-large 18.3%, pool max 14.3%.

On the lower bound the brief warned about: `sightlineBand`'s 262px floor is on
the **mean free sightline**, a different statistic from a max. A cap at 1050 on
the longest line does not press on a floor at 262 on the average one, so this
does not fail from the other side.

**Does the gate reject `arena-large` at 1149px? Yes. Decided on evidence: that is
a finding about the map.** 1149px of unbroken line between two standable points,
on a board whose gun reaches 1050px, is a lane neither end can contest — the
exact defect the horizontal rule exists to prevent, missed because the rule only
looks along rows. It is *not* silently exempted: it breaches, loudly, in every
report. What it does **not** do yet is hard-reject, because flipping that would
also retire four curated pool seeds at 1074px. That is a pool-recuration
decision and it is filed as its own task with the numbers.

### 2. Chokepoint detection had no pinch length

A 40px doorway and a 40 × 400px shooting gallery were one measurement.
`map_lanes.auditCorridorPinches` is reused whole (rule 3 — no reimplementation),
giving `chokeExposedPx` / `chokeAllowedPx` / `chokeExcessPx`, banded at 0 with
one whole kill's travel (132px) as the margin.

Both controls score **0 excess**, and *why* is the interesting part: arena has
**28 pinch gates and zero mandatory ones**. Its straight 188px channel of 36px
floor is one optional lane among eight, so it is a flank and not a kill box —
the distinction the length rule turns on, and the reason gating on arc length
instead of unbroken sightline would reject the best map in the repo.

Four 2-team maps breach: 1005 and 1021 at +65px, 1041 at +35px, 1016 at +31px
(the last two now fixed by re-selection — see below).

**Validator wiring: I did NOT wire `corridorPinchFailures` into
`arena.collectMapDiagnostics`.** That is task 49cb2dce's, exactly as briefed —
I did the metric side only, so the predicate is not wired twice.

### 3. The isovist was ~4× too wide

`IsovistRangePx` was `GunRange` = 1050. Gun range is a *reach*: aim is 32
discrete slots with no assist and the shot is accepted against the 13px solid
body, so `P(hit)` is 0.47 at 300px and **0.14 at gun range**. Covering a
chokepoint means being able to *kill* into it. Now `LethalEnvelopePx` = 259.

Note the direction — **this loosens the penalty**, and that is correct: the old
radius was flagging maps whose chokepoints merely fell in one field of view.
Both readings ship side by side so the re-cut is a printed before/after.
Flagged at 1050: 1003, 1005, 1012, 1021, 1018. Flagged at 259: 1005, 1021.

**Audited for others, per the warning:**

- `map_lanes.chokepointsCovered(rangePx = GunRange)` — **same 4× error**, in a
  proc with no caller yet that was about to acquire one. Fixed to
  `LethalEnvelopePx` so the assertion is not wired in carrying it.
- The visibility graph's pair cutoff — left on `GunRange` **deliberately**. It
  asks who can *see* whom, which is the awareness axis and is the right axis for
  "how evenly is this board read". A lethal-range twin (`visLethalDegree*`) is
  measured alongside it and is the one to read for any encounter claim. It is
  reported and **not banded**, for an honest reason: the sample stride grows with
  the board to hold the sample cap, so on a giant board a 259px cut leaves each
  sample a handful of partners and its CV is sampling noise. Fixing that needs a
  range-tied stride — a separate change, not a silent one.
- `map_lanes`' collision-cover radius is `GunRange div 4` = 262px, already on the
  lethal axis by arithmetic. Left alone; noted so nobody "fixes" it.
- `LongRunPx` = 600 is hand-picked, not range-derived. The derived figure is
  `2 × LethalEnvelopePx` = 518, which 600 clears by 16%. Left where it is
  because every band is calibrated on it; recorded so nobody re-derives it.

### 4. The unenforced causal property

There was no absolute stand-side rule, only a fairness *spread* — and a spread
structurally cannot express a floor: two equally naked stands both score 0 and
pass. Both floors now exist, and there is a test that strips the cover from both
stands and checks the spread still passes while the floor fires.

`standCoverGapMaxPx` ≤ 132px: arena **83** (37% slack), arena-large 111, pool
median 125, max 176. Seven maps breach.

**Routes:** the design intends ≥3 vertex-disjoint routes and the band that
*rejects* enforces ≥2. Both are now present — `routeCountMin` (hard, 2) and
`routeCountDesign` (soft, 3) — and each note names the other, so the report says
out loud which bound enforces and which aspires.

---

## Two more the measurement turned up

**The validator's horizontal scan had two holes.** It stepped 4px, so it never
looked at 3 of every 4 rows; and it started at `ArenaBorder + 2`, inside the
gutter. Seeds 1001 and 1014 each ship a fully open row the scan has never
examined. Stride is now 1 and it starts at the first occupiable row — **verified
to reject nothing that ships**, on both controls and every pool seed.

Worse than the stride: the rule rejects a ray only when it crosses the *entire*
`sightlineLoX..sightlineHiX` band. That band is 805px on a column endzone and
**1205px on a compact one** — so on half the pool the effective sightline cap is
wider than the gun, which is why four pool seeds carry a 1074px open row and all
four pass.

**`bandHard` was documented and unimplemented.** `BandKind.bandHard` has always
read "outside => the map is REJECTED", exactly one band was marked with it, and
*nothing read the field*. A 4-team board with **one** vertex-disjoint route
scored 0.736 and could win a best-of-K draw. That is this epic's own failure mode
— passing a bar the suite claims to enforce — sitting inside the suite meant to
catch it. Now enforced.

---

## The re-scored baseline

`bin/stick_probe`, controls first, `staticScore` under the corrected stick.

### 2 teams — 38 maps, **0 rejected by the hard gate**

| | arena (CTL) | arena-large (CTL) | pool min | median | max |
|---|---|---|---|---|---|
| staticScore | **1.000** | 0.905 | 0.898 | 0.980 | 1.000 |
| sightlineMaxPx | 758 | **1149** | 568 | 818 | **1074** |
| longest line is… | diagonal | diagonal | — | 13 of 36 diagonal | — |
| diagLongRunPxFrac | 0.010 | **0.183** | 0.000 | 0.027 | 0.092 |
| chokeExcessPx | 0 | 0 | −96 | 0 | **+65** |
| standCoverGapPx | 83 | 111 | 103 | 124 | **141** |
| routeCountMin | 8 | 12 | 3 | 3 | 6 |

Absent: seeds **1015, 1020** — the generator cannot satisfy them on this branch.

### 4 teams — 14 maps, **0 rejected by the hard gate**

| | arena (CTL) | arena-large (CTL) | gen min | median | max |
|---|---|---|---|---|---|
| staticScore | **1.000** | 0.905 | **0.000** | 0.904 | 0.926 |
| sightlineMaxPx | 758 | 1149 | 697 | 835 | **1132** |
| longRunPxFrac (axis) | 0.393 | 0.462 | 0.000 | **0.000** | **0.000** |
| diagLongRunPxFrac | 0.010 | 0.183 | 0.002 | 0.002 | 0.098 |
| routeCountMin | 8 | 12 | **1** | 3 | 9 |

Absent: seeds **1002, 1005, 1006, 1012, 1013, 1017, 1018, 1019** — 8 of 20.

**The 4-team row is the headline.** The axis long-run fraction is **0.000 on
every single generated map** while those same maps carry **697–1132px unbroken
diagonals**. The old axis-only stick reported a perfect vision score on every
4-team board, and every one of them has a gun-range sniping lane. That is the
blind spot the brief predicted, and at 4 teams it is total rather than partial.

Three of those maps offer **one** vertex-disjoint route and now score 0.000.

### Selection moved too

The generator ranks with `map_metrics.staticScore`, so correcting the stick
changed *which candidate best-of-K ships*, not just its number. Measured: seed
1016's mandatory pinch went +31px → 0, seed 1041's +83px → +35px, seed 1013 lost
two chokepoints. **A before/after here is not "same map, new score" — read it as
the generator now selecting against defects it could not previously see.**

---

## Verification

- `test_map_los`, `test_map_lanes`, `test_map_rules`, `test_map_select` — **PASS**
- `test_map_eval` — 11 new tests pinning every correction, all pass
- `test_mapgen` (5) and `test_map_eval` (1) fail **identically on untouched base
  commit 4a013df** — seeds 1015/1020/11/13 do not generate on this branch at all.
  **Zero regressions from this change**; filed separately.
- Cost: arena scores in 390ms, arena-large in 230ms (the pinch audit is the new
  cost). Still free next to a ~97s episode; the sub-second and giant-board budget
  tests both hold.

## Filed

- The fraction-shaped bands are not scale-free — `arena-large` proves it
- Decide whether the `GunRange` sightline cap becomes a hard reject
- Eight of twenty seeds do not generate at 4 teams

## One more, not filed

`detourMax` reads **0.989** on seed 1014 — geometrically impossible, since a
walked route cannot be shorter than the straight line. It is cell-grid
quantisation: the walk is counted in 26px cells and both endpoints round inward,
so a long route can come in ~1% under. Harmless at this size, and stated here so
the next person does not spend an afternoon on it.
