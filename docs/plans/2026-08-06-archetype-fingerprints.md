# Six archetypes, measured — and they really are different graphs

Epic owner, 2026-08-06, verifying task 10fc7a24 on the merged tree. `tools/archetype_probe.nim`,
40 2-team seeds, arena as control.

    CONTROL arena:  rooms 7   routes 8   largest 0.15   int 0.342   cover 167pm   score 1.000

| archetype  | n  | valid      | rooms (dist)          | routeMin (dist)         | largest | int   | cover | score |
|------------|----|------------|-----------------------|-------------------------|---------|-------|-------|-------|
| three-lane | 10 | 8/10 (80%) | 3x4 5x3 7x2 11x1      | 0x1 3x6 4x3             | 0.16    | 0.329 | 161pm | 0.785 |
| blocks     | 10 | 10/10 100% | 3x6 5x4               | 4x2 5x3 6x3 8x2         | 0.17    | 0.294 | 161pm | 0.980 |
| ring       | 3  | 3/3  100%  | 3x1 5x1 7x1           | 7x1 9x1 11x1            | 0.19    | 0.205 | 151pm | 0.977 |
| hub        | 4  | 4/4  100%  | 1x1 3x1 5x2           | 8x2 9x1 11x1            | 0.25    | 0.200 | 137pm | 0.946 |
| warren     | 6  | 6/6  100%  | 7x1 9x4 11x1          | 3x1 4x2 5x1 6x1 7x1     | 0.12    | 0.444 | 164pm | 0.985 |
| field      | 7  | 7/7  100%  | 1x3 3x2 5x1 7x1       | 4x1 6x1 7x1 9x2 10x1 12x1| 0.36   | 0.213 | 147pm | 0.966 |

    room count  across all seeds: min 1  p25 3  med 5  p75 7  max 11   (arena 7)
    route count across all seeds: min 0  p25 4  med 6  p75 8  max 12   (arena 8)

## These are genuinely different graphs, not different pebbles

The brief's test is that different archetypes differ in TOPOLOGY. The fingerprints say they do, and
the two extremes are exactly the two the design predicted:

    warren   9 rooms median, interiorFrac 0.444, largest room 0.12   most enclosed, most rooms
    field    1-3 rooms,      interiorFrac 0.213, largest room 0.36   fewest rooms, biggest space

`largest` (the biggest single room as a fraction of floor) separates them 3x, and `interiorFrac`
separates them 2x — in OPPOSITE directions from each other, with neither being wrong. That is the
definition of a behaviour-space coordinate rather than a quality term, and it is why room count
belongs in this probe and not in `map_metrics`.

Room count varies 1..11 and route count 0..12 across seeds, both straddling the control (7 and 8).
Reported as distributions, not means, because the means would hide exactly this.

## And I could name them by eye

I rendered 20 2-team and 16 4-team tiles and looked. `warren`/`blocks` read as room lattices with
doorways; `field` reads as a few large masses in open ground; at 4 teams `ring` reads as a
perimeter loop with radiating spurs and `blocks` as a street grid. Against the "before" sheets —
twenty skins of one map at 2 teams, ten near-identical empty-block tiles at 4 — this is the
criterion substantially met.

**The centre is no longer a fixture.** It was the same bright shape in the same place on 36 of 36
tiles I rendered before this landed. `ring`, `warren` and `field` now leave the middle empty.

## The finding that falls straight out of the table

**`three-lane` is the only archetype that fails, and it is the worst on every measure.**

    valid 8/10 (80%)  -- every other archetype is 100%
    score 0.785       -- the next lowest is hub at 0.946
    routeMin 0 on one seed -- a board with NO vertex-disjoint route
    BOTH invalid seeds (1026, 1038) are three-lane, both "too clogged"

2-team validity is 38/40 (95%) and **the entire shortfall is one archetype**. This is a much more
tractable statement than "2-team validity is 95%", and it retires the reading in
`2026-08-06-cover-headroom-warning.md` that the whole 2-team cover budget is at its ceiling — five
of six archetypes have headroom; one does not. Filed as its own task.

Note `three-lane` is also the OLDEST of the six — it is the pre-existing `map_lanes` grammar that
the other five were written to join. The newest code is the healthiest here.
