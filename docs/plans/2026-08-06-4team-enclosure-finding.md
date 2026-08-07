# 4-team enclosure: the fill budget is not connected to cover, and the row cover is

Task b7f44fb5 (LANE A, epic 3757029c). **The acceptance bar was NOT met.** This
records what the numbers actually say, so the next attempt starts from the
measurement rather than from the brief.

All numbers from clean nimcaches on `maxwell/mapgen-rebuild @ 8418626`
(W0 merged), `tools/gen_sweep.nim` and `tools/w0_probe.nim`.

## 1. The brief's numbers are stale, in both directions

    task says            measured on the current tree
    4-team 0.098    ->   0.274   (16 seeds, validity 16/16)
    2-team 0.315    ->   0.257   (20 seeds, validity 20/20)

W0 and the archetype work already took 4-team most of the way; the gap is
0.274 -> 0.30, not 0.098 -> 0.30. And **2-team has regressed** from the 0.315
the colonnade commit recorded to 0.257 — it now sits BELOW 4-team, and below
the >= 0.30 bar it is supposed to have already cleared. Nothing in this task
caused that; it is the state of the merged tree. Whoever picks up 2-team should
bisect the merges after 278d160 rather than trust the 0.315.

Also worth restating: there is no hand-authored 4-team map (task 44d455a1), so
the >= 0.30 bar for 4 teams is inherited from a 2-team control and has never
been shown to be reachable at 4 teams.

## 2. interiorFrac IS the largest room, inverted — confirmed, both team counts

`tools/archetype_probe.nim --raw`, `largest` = largest room as a fraction of
floor:

    4 teams          largest  int     cover      2 teams        largest  int
    hub      (n=4)   0.26     0.230   161pm      hub    (n=2)   0.32     0.196
    blocks   (n=3)   0.09     0.251   150pm      field  (n=3)   0.32     0.221
    field    (n=4)   0.14     0.274   164pm      ring   (n=1)   0.15     0.257
    warren   (n=2)   0.05     0.322   152pm      blocks (n=5)   0.18     0.268
    ring     (n=3)   0.07     0.330   151pm      warren (n=4)   0.13     0.459

`warren` is the only archetype whose enclosure comes from WALLS rather than
masses, and it wins by a factor on identical cover. That is the mechanism, and
it is the same thing `vocab_bench` reports from the other end: the wall-like
`bunker` (0.456) and `snake` (0.450) over the landform `massif` (0.174) and
`temple` (0.128). A blob blocks one of the metric's 8 rays for the pixels
behind it; a wall blocks one ray for every pixel in the band it spans.

## 3. The mechanism works. It was BUILT and MEASURED, per candidate

A partition pass — chamfer the board, find the longest open run inside a room,
lay a `wallWithDoors` across it — was implemented and A/B'd against the SAME
candidate (`-d:nopartition`, so best-of-K cannot reshuffle which board wins):

    seed 1005 a0   int 0.267 -> 0.301   cover 162 -> 168pm   still valid
    seed 1005 a4   int 0.309 -> 0.354   cover 170 -> 192pm   LOST (too clogged)
    seed 1002 a8   int 0.242 -> 0.296   cover 207 -> 214pm
    seed 1012 a4   int 0.347 -> 0.377   cover 188 -> 199pm

+0.03 to +0.05 of interiorFrac, reliably. **The geometry is right.** Through the
full generator it moved the median by nothing (0.269-0.281 against a 0.274
baseline), because every wall costs cover and the 170 ceiling is already the
binding constraint. The pass was REVERTED rather than shipped: an unwired lever
that does not move the metric is a tombstone, and this repo has paid for those.

## 4. THE FINDING: the fill budget is not connected to cover. The pickets are

`tools/w0_probe.nim` decomposes a candidate by removing one class at a time:

    seed 1003 a0   49 shapes, 21 pickets   173pm total, 81pm without pickets
    seed 1004 a0   40 shapes, 27 pickets   152pm total, 84pm without pickets
    seed 1008 a0  208 shapes, 20 pickets   150pm total, 99pm without pickets

**The pickets are 35-92 permille of a 141-173 permille budget — up to half of
it — and the "pickets only" board measures interiorFrac 0.007 to 0.058.** They
are the single largest line item in the cover budget and they buy no enclosure
at all.

And the fill budget cannot be traded against them, because it does not reach
cover. Two independent measurements now say so:

  * W0 swept the fill DENSITY 40% -> 140% and moved cover by 4 permille.
  * This task cut `FillBudgetPermille` 350 -> 270, a 23% cut, and 4-team cover
    did not move at all: 162pm before, 162pm after (interiorFrac 0.270 ->
    0.257, i.e. strictly worse).

The reason is a feedback loop: less fill leaves more open sightline rows, the
row cover places more pickets, and cover lands back where it started. Cover at
4 teams is PINNED by the row-cover pass, whatever the fill does.

## 5. So the lever is the row cover, not the fill

The row cover places one 24x26 picket per otherwise-uncovered row, at a
rotating cursor x. Per row of sightline closed that is 24 px of stone, and it
encloses nothing. A 16 px vertical wall closes the same rows at 16 px each —
about a third cheaper — and every pixel beside it gains a blocked ray.

Freeing 35-92 permille and spending it on walls is the only move on the table
that raises enclosure and lowers cover at the same time. It is worth 0.03-0.05
per wall by the section-3 measurement, which is the whole remaining gap.

**The hazard, and why this task stopped rather than attempting it:** W0
measured stacked pickets as a PATHOLOGY. On seed 1005 all 43 pickets landed at
one x, and the rot90 lift turned that column into a box around the centre
plaza; the spread cursor exists to prevent exactly this. A vertical bar is that
column. The next attempt must render every candidate, not just score it, and
should expect the thickness and the spread to matter more than the idea.

## 6. Measured and REFUTED — do not repeat these

  * **Emitting the weighted vocabulary into the archetype's blocks** (the
    experiment this task's brief proposes first). Already implemented, on the
    tree, in the `masses` block — `archPlan.cells` are the compartments and
    each item is emitted into each. It is why 4-team is at 0.274 and not 0.098.
  * **Sweeping the fill budget.** Section 4. Not connected to cover.
  * **Triggering a partition search on CLEARANCE.** Clearance is a minimum over
    directions; the metric is disqualified by a maximum over directions. A
    400x90 hall has 45 px of clearance and is nearly the worst shape on the
    board. Triggered on clearance the pass fired on 27 of 176 attempts.
  * **Searching the fundamental domain.** The rooms that cost the most sit on
    the centre and belong to no quadrant. A 240 px run cannot be found in a
    312 px-wide quarter-board domain; 2-team (domain = a HALF) responded to the
    same code and 4-team did not.
  * **Thinning the picket.** `PicketW` is 24 and must stay under the 26 px
    route grid, but nothing requires 24 — so a 14 px picket should have closed
    the same rows for 40% less stone. Measured 24 -> 14: cover fell only
    162 -> 157pm (the count rises to compensate, the same feedback loop as
    above) and interiorFrac fell 0.270 -> 0.260, because a thinner blocker
    blocks fewer of the metric's rays for the pixels beside it. Cheaper stone
    is not the answer; stone in a WALL is.
  * **Reserving fill budget for a later pass, then re-applying the fill floor.**
    A no-op on exactly the attempts already at the floor, so the second layer
    became pure addition: seed 1005 a4 went 170 -> 192pm and lost a board that
    had been valid.

## 7. What is NOT the constraint

Cover headroom, on the archetypes that matter. `blocks` sits at 150pm, `ring`
151, `warren` 152 against a 170 ceiling. `hub` (161) and `field` (164) are the
tight ones — and `hub`'s enclosure is capped by design anyway, since its one
dominant central space is RESERVED and a partition may never enter it. `hub` is
4 of 16 seeds; leaving it alone still permits a >= 0.30 median if `field` and
`blocks` come up.
