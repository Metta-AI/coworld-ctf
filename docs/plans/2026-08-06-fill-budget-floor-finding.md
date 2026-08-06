# The 4-team raise is budget arithmetic, not connectivity

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
