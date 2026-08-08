# 2-team validity is now EXACTLY on the bar, with no headroom

Epic owner, 2026-08-06, measured after merging the pit-candidate follow-on.

    2-team, 40 seeds:  39/40 (97%)  ->  38/40 (95%)     bar is >= 95%
    interiorFrac       0.291        ->  0.297
    cover              162pm        ->  163pm
    4-team, 32 seeds:  32/32 (100%) ->  32/32 (100%)    unchanged
    failing seeds: 1026 and 1038, BOTH "too clogged" on every sampled attempt

## This is a correct trade, not a bug

The pit work found that an `instead` proposal was being registered as a pit candidate without
checking whether anything else covered the spot. On the old lattice that was automatic; in an
overlapping fill it is not. So every pick **deleted a piece of cover and then failed to leave a pit
where it had been**. Fixing that means cover stops being silently removed — which is right, and
which is exactly why cover went up and two seeds tipped over the 170pm ceiling.

interiorFrac moved the right way at the same time (0.291 -> 0.297), so the trade bought enclosure.

## But the margin is gone, and that is the finding

**2-team validity is now exactly 95% against a >= 95% bar.** One more seed and the epic misses its
own hard gate. Every remaining piece of map-changing work is now operating with zero slack:

    49cb2dce  corridor floor 26 -> 68        RAISES the corridor requirement
    10fc7a24  archetypes                     changes topology, hence cover
    7801f394  polygon/diagonal lane clipping  MEASURED at 186pm against a 170 ceiling

That last one is the sharpest: it was already measured over the ceiling and deferred for exactly
this reason. It cannot land without a compensating budget change.

## What this says about the real constraint

The 2-team cover budget, not connectivity and not enclosure, is now the binding constraint on
validity. Three separate pieces of work have now hit the 170pm ceiling from underneath — the small
boards (structure alone), the polygon/diagonal clipping, and now the pit candidate fix. Each was a
correct local fix that pushed cover up.

The honest read is that structure, fill, vocabulary and pits are all drawing on one budget that
nothing owns end to end, and the ceiling is calibrated against a control (arena, 167pm) that does
not have to satisfy all four at once. **Do not respond by raising CoverPermilleMax** — that is how
a validator stops being a validator, and the ceiling is the only thing standing between the epic
and a clogged map. Respond by making the budget explicit and owned.
