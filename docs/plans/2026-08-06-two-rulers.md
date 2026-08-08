# Every validity number in this epic was taken with a broken ruler

Epic owner, 2026-08-06. Read this before comparing any two numbers in epic 3757029c.

## What broke

`BandKind.bandHard` is documented as "outside => the map is REJECTED". Exactly one band was ever
marked with it (`routeCountMin`), and **nothing read the field**. `scoreBands` treated both kinds
identically and `staticScore` averaged a hard breach in with everything else.

So a 4-team board offering **one** vertex-disjoint route between a base pair — a corridor, which is
precisely what the band exists to forbid — scored 0.736 and could win a best-of-K draw. Found by
task 4fb75b77.

That is this epic's own failure mode, sitting inside the suite that is supposed to catch it: a
gate that was believed to be enforcing and was silently inert. It is the same shape as the
fill-floor clamp (an escape valve believed to be sweeping and silently pinned) and the same shape
as the sightline prosthetic (a repair believed to be needed and silently deleted).

## The number that changes

Making the band real costs nothing at 2 teams — the measured population is at 3 routes or better,
and the arena control is at 8.

At 4 teams it **zeroes seeds 1001, 1007 and 1020**, each of which has exactly one route.

    4-team validity, old ruler:  11/16 (68%)
    4-team validity, corrected:   8/16 (50%)   -- 3 of the 11 "valid" maps are corridors

**Every 4-team number recorded in this epic before task 4fb75b77 lands is optimistic**, including
the 68% in the epic description, the 68% I reproduced independently at the start of this session,
and the interiorFrac 0.098 and staticScore 0.861 medians, which were taken over a population that
included three maps that should never have validated.

## What this means for W0

Task 157ce824 must reach >= 95% validity under the **corrected** ruler, not the old one. Landing
at 95% on the old ruler and then merging the corrected one would drop it back below the bar, and
the drop would look like a regression caused by W0 when it is really the ruler being fixed
underneath it.

Sequence: land W0, merge the corrected stick, **re-measure**, and report the post-correction number
as the real one. Do not report a pre-correction validity figure as if it were the result.

## The general rule this earns

Three times now in this rewrite a mechanism has been believed active and measured inert — the
sweep, the band, the prosthetic. In each case the code READ correctly and the behaviour was
different. The cheap detector is the same every time: **make the mechanism prove it fires** by
measuring the thing it is supposed to change, with a control you did not touch. The fill floor was
caught by a flat cover series across a 2.2x density range. The band was caught by asking what the
field was read by. Neither needed a rewrite to find.
