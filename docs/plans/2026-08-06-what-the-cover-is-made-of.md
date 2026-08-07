# The control has ZERO masses. Enclosure is arrangement, not shape size.

Measured 2026-08-06 by the epic owner on `maxwell/mapgen-rebuild` @ 6a06829 with
`tools/pebble_probe.nim`, arena control in the same batch, fresh `--nimcache`.

This contradicts a premise I wrote into the epic myself two commits ago, and the
task brief for `b7f44fb5` repeats it: *"the remaining work is spending the same
cover budget on masses instead of pebbles."* **The hand-authored arena has no
masses at all.**

## The measurement

Every obstacle bucketed by its bounding box's long side. The edges are things the
game already means: 34 px is one DRAWN cog body (below it a shape cannot hide
anyone), 68 px is two abreast (`RecommendedCorridorWidthPx`), 120 px is the
`interiorFrac` probe's own reach (below it a shape cannot enclose).

    CONTROL   arena          35 shapes   cover 167pm   interiorFrac 0.342
        <34px  sub-body       4  (11.4% of shapes)     1.8% of footprint
        34-68  one-body      31  (88.6% of shapes)    98.2% of footprint
        68-120 corridor       0  ( 0.0% of shapes)     0.0% of footprint
        >=120  mass           0  ( 0.0% of shapes)     0.0% of footprint

    2 TEAMS   29/30 seeds  2474 shapes  cover 154pm   interiorFrac 0.292
        <34px  sub-body    1843  (74.5% of shapes)    21.4% of footprint
        34-68  one-body     387  (15.6% of shapes)    38.1% of footprint
        68-120 corridor     216  ( 8.7% of shapes)    29.4% of footprint
        >=120  mass          28  ( 1.1% of shapes)    11.1% of footprint

    4 TEAMS   30/30 seeds  3441 shapes  cover 153pm   interiorFrac 0.280
        <34px  sub-body    3041  (88.4% of shapes)    31.8% of footprint
        34-68  one-body     185  ( 5.4% of shapes)    22.6% of footprint
        68-120 corridor     154  ( 4.5% of shapes)    27.6% of footprint
        >=120  mass          61  ( 1.8% of shapes)    18.0% of footprint

Both lists are the fundamental domain, so the counts are comparable: 35 against
2474 is a real 71x, not a mirroring artefact.

## What it says

**1. The control is 35 shapes at ONE scale, and it wins on enclosure.** 88.6% of
its shapes and 98.2% of its footprint sit in a single bucket, 34-68 px. Not one
shape exceeds 68 px. Its 0.342 comes from where those 31 medium shapes are — the
five staggered columns its comments still describe — and from nothing else.

**2. Cover is at parity; GRANULARITY is not.** 167pm against 154 and 153. The
generator is not short of cover and never was. It spends that near-identical
budget across 71x and 98x as many shapes, and the majority of them are specks
that cannot hide a player: 74.5% and 88.4% of all shapes are under one body
width, carrying 21.4% and 31.8% of the footprint.

**3. The mass hypothesis has a counterexample in this same table.** 4-team
carries *more* mass than 2-team by every measure — 18.0% of footprint above
120 px against 11.1%, 1.8% of shapes against 1.1% — and scores *lower*
enclosure, 0.280 against 0.292. That is n = 2 and I am not calling it a
correlation. It is enough to say that adding masses is not the mechanism, because
the arm with more of them is behind, and the control has none.

**4. The miss is CONCENTRATED, not universal — and the mean hides it.**

    2 teams   interiorFrac  min 0.142  median 0.257  max 0.548   below 0.30: 18/29 (62%)
    4 teams   interiorFrac  min 0.105  median 0.276  max 0.440   below 0.30: 21/30 (70%)

**11 of 29 2-team seeds and 9 of 30 4-team seeds already clear the bar**, and the
best 2-team seed measures 0.548 — 1.6x the hand-authored control. The generator
can already build boards more enclosed than the arena. It just does not do it
reliably. That is a different, much cheaper problem than "learn to make enclosed
boards", and it is invisible in the 0.292 mean that the definition of done is
written against.

## What this changes for `b7f44fb5`

The brief for that task says to emit the weighted shape vocabulary INTO the
street blocks, mirroring what worked on 2-team. That may still be right, but the
justification in it — that masses are what buy enclosure — is not supported here,
and the task's own ⚠️ warning already said the item scoring best per unit cover
renders as a BARCODE and the second best as CONFETTI. This measurement says the
same thing from the other side.

The question that measurement now supports asking is **why 1843 sub-body shapes
per half-board exist at all**, and what emits them. Four mechanisms in this epic
read correctly in the source and did nothing when measured; this is the first
number that says where the budget actually goes rather than what it was meant
for. The 11 seeds that already pass are the cheapest available evidence for what
the passing configuration looks like, and they should be profiled before anything
is tuned.

## What this does NOT establish

Bounding-box footprint is not carved wall area — a disc and a rect with the same
box count the same here. That is deliberate (it is what the eye reads at a
glance) but it means the footprint shares are an upper bound on how much wall
each bucket actually spends. It also does not show that reducing the speck count
would raise `interiorFrac`; it shows only that the control achieves 0.342 without
any of them, and that the arm with more mass scores worse. Nobody has yet run the
experiment.
