# The 4-team raise is budget arithmetic, not connectivity

> ## ⚠️ CORRECTION, 2026-08-06, same day. The MECHANISM below is WRONG.
>
> The fill-floor clamp is **not** what was failing 4-team. On a rot90 board `structureCount` is
> **0**, so the subtraction loop runs zero iterations and the clamp at `arena.nim:2073` never
> fires at all. I read the arithmetic correctly and applied it to a branch that does not execute
> it. The floor is left in place, unchanged, and remains untested at 2 teams where
> `structureCount` is non-zero.
>
> **The OBSERVATIONS below are correct and they are what found the real bug**, so this document
> stays rather than being deleted. Cover really is flat across a 2.2x density sweep; the density
> knob really is disconnected; every failing seed really does fail "too clogged" and never
> routing. Task 157ce824 took exactly those observations and asked the better question — *what
> IS the cover made of, if not the fill?* — and rendered it:
>
> 1. **The terrain block was emitting NOTHING on 4-team.** `xMin` is `captureClear + 50`, an
>    inset that holds terrain off the capture COLUMN of a 2-team *sides* board. A rot90 board has
>    no such column. Applied anyway it left a 127x397 emission region inside a 408x408 quadrant,
>    and the street grid then dropped **34 of 34 shapes on every attempt** (`survived=0`).
> 2. **So the whole board was row cover.** On seed 1002, 51 of 53 shapes were pickets, and the
>    pickets alone measured 141 of 178 permille against a 170 ceiling. *That* is why sweeping fill
>    density 40%→140% moved cover by 4 permille — the density knob was not connected to anything.
> 3. **The row cover clamped its scan to `min(sightlineHiX, center.x)` while the validator reads
>    `sightlineLoX..sightlineHiX` unclamped.** A picket's rot180 image lands at x in [435,630] —
>    inside the validator's band, outside the clamped one — so the pass never credited the row its
>    own image already blocked, and laid about twice the pickets it needed.
>
> Result: 4-team validity 65% → **100%** (32/32), interiorFrac 0.098 → 0.252, staticScore
> 0.861 → 0.984, with 2-team unregressed and three seeds rescued.
>
> The lesson I got right and the lesson I got wrong are the same lesson. I found a flat series and
> correctly concluded a mechanism was inert — but I then named the first inert-looking mechanism I
> could find in the source instead of rendering the board and asking what the cover actually was.
> That is the identical error the task's own history records three times, committed a fourth time
> by the person quoting it. **The flat series was the finding. The mechanism was a guess.**

Measured 2026-08-06 on `maxwell/mapgen-rebuild` @ 4a013df, by the epic owner, before
any epic-3757029c task landed. This is the THIRD standing diagnosis in this rewrite to be
proven wrong by measurement, after "the suite takes 50 minutes" (it was 7.1 minutes plus
fleet load) and "shapeRowSpan is the lane blocker" (it was not).

## What the epic believed

Task 157ce824 (W0) states the measured root cause of 4-team's 68% validity as:

> sparse fills -> "no 26px route to the blue flag" at 125-167 permille
> dense fills  -> "too clogged" at 175-242 permille
> no window between them

and points the fix at wiring `src/ctf/burrow.nim` for connectivity.

## What is actually true

`/tmp/gensweep 16 4` fails on seeds 1002, 1005, 1006, 1012, 1013 (5/16 = 31%).
**Every sampled attempt on every one of them fails `too clogged`. Not one fails routing.**

The original diagnosis was taken on a different seed set (1, 13, 118798, 135769, 141426)
and before the street grid landed. It no longer describes the failure.

`tools/gen_sweep.nim:31` samples attempts 0..4, and `arena.nim:2066` sets
`densityPct = 40 + 12 * (attempt mod 9)`, so those five attempts span 40%, 52%, 64%, 76%
and 88% of the nominal fill budget. Observed cover across that 2.2x density range:

| seed | attempt 0 (40%) | 1 (52%) | 2 (64%) | 3 (76%) | 4 (88%) |
|------|-----------------|---------|---------|---------|---------|
| 1002 | 178pm | 178pm | 174pm | 178pm | 178pm |
| 1012 | 178pm | 174pm | 174pm | 178pm | 178pm |
| 1013 | 178pm | 178pm | 174pm | 178pm | 174pm |
| 1005 | 199pm | 203pm | 204pm | 204pm | 199pm |
| 1006 | 204pm | 204pm | 203pm | 203pm | 199pm |

Flat. A 2.2x change in the fill budget moves cover by at most 5pm against a 170pm ceiling.

## The mechanism

`src/ctf/arena.nim:2066-2073`:

```nim
let densityPct = 40 + 12 * (attempt mod 9)
var budget = domainArea * FillBudgetPermille div 1000 * densityPct div 100
for i in 0 ..< min(structureCount, emitted.len):
  budget -= approxArea(emitted[i])
budget = max(budget, domainArea * FillFloorPermille div 1000)   # FillFloorPermille = 55
```

Structure area is subtracted from the swept budget, and the remainder is then **clamped up**
to a hard 55-permille floor. On 4-team the structure (street grid, lifted x4) is large enough
that the subtraction drives the budget below the floor on *every* attempt, so the clamp fires
every time and all nine density steps emit the same fill.

**The density sweep is the generator's designed escape valve — the comment above it says so
explicitly — and it is inert on 4-team.** Arithmetic: structure ~120-150pm plus the 55pm floor
is 175-205pm, against a 170pm ceiling. That matches the observed 174-204pm.

## Why this matters for sequencing

Cover cannot get under the ceiling because the floor holds it up, so the cover gate rejects
every candidate before the routing gate ever runs. Wiring burrow first means fixing the SECOND
gate while the FIRST still rejects everything — the change would measure as no improvement and
be wrongly discarded.

This does **not** show connectivity is fine. Once cover drops under 170 the routing gate finally
gets to run and may well fail then; that is the regime the original 60-attempt measurement was
in. The correct order is: fix the budget arithmetic, re-run, and report the failure-reason MIX.
The transition from `too clogged` to a routing failure is the evidence that burrow is needed.

## The floor is deliberate — do not just delete it

Its comment records why it exists: squeezing the fill to nothing keeps a board legal while
making it EMPTY, which is what the first attempt at this budget did, and it is interiorFrac
that collapses. Structure and fill are competing for one budget and 4-team's structure is too
expensive for its domain. Either structure gets cheaper on rot90, or the floor scales with what
structure actually costs.

## Same mechanism, second site

Task fcd2e04d (small 2-team boards, seeds 1015 and 1020) is the identical failure: structure
alone busts the ceiling and the sparsest fill still measures 196pm. Two size/team regimes, one
root cause — structure sized without reference to the domain it has to fit in. There is likely
one shared fix.
