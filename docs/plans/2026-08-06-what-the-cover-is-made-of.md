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

## SPLIT BY THE BAR — and it refutes the pebble reading, including mine

The mean is the wrong summary when the miss is concentrated, so the same
population is split by its own bar and the two profiles printed adjacent. Same
batch, same control.

    2 TEAMS   PASS >=0.30 (11/29)   interiorFrac 0.402   cover 162pm
        <34px  sub-body    20.5% of footprint
        34-68  one-body    47.9%
        68-120 corridor    25.7%
        >=120  mass         5.9%
              FAIL <0.30 (18/29)   interiorFrac 0.225   cover 150pm
        <34px  sub-body    21.9% of footprint
        34-68  one-body    32.1%
        68-120 corridor    31.7%
        >=120  mass        14.3%

    4 TEAMS   PASS >=0.30 (9/30)    interiorFrac 0.378   cover 148pm
        <34px  sub-body    45.1% of footprint
        34-68  one-body    29.5%
        68-120 corridor    20.5%
        >=120  mass         5.0%
              FAIL <0.30 (21/30)   interiorFrac 0.238   cover 156pm
        <34px  sub-body    28.7% of footprint
        34-68  one-body    21.1%
        68-120 corridor    29.3%
        >=120  mass        21.0%

**The speck share does not separate pass from fail, and at 4 teams it runs the
wrong way.** 2-team: 20.5% passing against 21.9% failing — indistinguishable.
4-team: passing maps carry *more* specks than failing ones, 45.1% against 28.7%.
So the reading I wrote into the sheet verdict and the scorecard — that pebbles
are what costs enclosure — **is not supported by the data I collected to support
it.** The eye saw specks because they are 74-92% of the shape COUNT; count is
not what buys enclosure, and the contact sheet cannot show footprint.

Two things DO separate the two groups, consistently at both team counts, and
both point at the control's own profile:

    one-body (34-68px)  PASS 47.9% / 29.5%   FAIL 32.1% / 21.1%    passing spends MORE
    mass (>=120px)      PASS  5.9% /  5.0%   FAIL 14.3% / 21.0%    passing spends ~1/3

Passing maps put their footprint in the arena's ONLY bucket, and failing maps put
two to four times as much of it into masses the arena does not use at all. That
is the same statement as section 1, arrived at from the other direction, and it
is the opposite of "add masses".

It is worth saying why that is mechanically sensible rather than just observed:
`interiorFrac` is open floor with at least 6 of 8 directions blocked within
120 px. A 120px+ lump is mostly *its own interior* — it fills the floor it would
otherwise enclose. Walls at body scale, arranged around open floor, are what
produce enclosed floor. The arena's five staggered columns are exactly that.

**What the split does NOT establish.** This is observational across seeds, not an
intervention: nobody has taken one board and moved footprint from the mass bucket
into the one-body bucket. Mass share may also be a proxy for archetype — if
`field` draws large masses by design and also scores low, the bucket is reporting
the archetype. Both are cheap to check and neither is checked here.

## What this changes for `b7f44fb5`

The brief for that task says to emit the weighted shape vocabulary INTO the
street blocks, mirroring what worked on 2-team, on the stated grounds that
"vocabulary masses, not just biome noise" is what bought 2-team its enclosure.
**Measured on the shipped generator, the maps that clear the bar are the ones
with the LEAST mass**, at both team counts, by a factor of about three. Whatever
those 2-team moves did, the surviving correlate is not mass share.

So the experiment that measurement now supports is not "add masses". It is:
**take footprint out of the >=120px bucket and put it in 34-68px, holding cover
permille fixed, and see whether `interiorFrac` moves.** That is a single
intervention with a control (the same seed before the change), it is falsifiable,
and it is the arm nobody has run. The 20 seeds that already pass — 2-team 1001,
1007, 1008, 1011, 1012, 1014, 1017, 1019, 1022, 1023, 1030 and 4-team 1009, 1012,
1013, 1018, 1019, 1023, 1024, 1025, 1030 — are the cheapest available evidence
for what a passing configuration looks like and should be rendered and read
before anything is tuned.

Also worth asking, though the split says it is not the bar-driver: **why 1843
sub-body shapes exist per half-board at all.** The arena has four. Four
mechanisms in this epic read correctly in the source and did nothing when
measured, and a speck population two orders of magnitude larger than the
control's is the right shape for a fifth.

## What this does NOT establish

Bounding-box footprint is not carved wall area — a disc and a rect with the same
box count the same here. That is deliberate (it is what the eye reads at a
glance) but it means the footprint shares are an upper bound on how much wall
each bucket actually spends. It also does not show that reducing the speck count
would raise `interiorFrac`; it shows only that the control achieves 0.342 without
any of them, and that the arm with more mass scores worse. Nobody has yet run the
experiment.
