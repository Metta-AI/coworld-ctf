# Looking at 20 2-team maps: the metrics pass, the eye does not

Rendered 2026-08-06 by the epic owner after merging `maxwell/mapgen-small-boards`.
Sheet: `2026-08-06-sheet-2team-20.png` (from `tools/map_sheet.nim 20`).

    20 maps, mean staticScore 0.957, mean interiorFrac 0.300
    arena control: 1.000 / 0.342
    validity 20/20 (100%)

Every acceptance number in the epic passes. The picture says something the numbers do not,
and the epic's own working rule #5 says that when the rubric and the eye disagree, the eye is
currently right.

## What is genuinely good

All 20 tiles render a real, playable-looking board — no blanks, no barcodes, no confetti.
There is honest textural variety: diamond scatter, long diagonal strokes, capsule masses
(seed 1016), heavy rectangular blocks, and open-plaza boards sit side by side. The
small class (`mzz2Small`) does **not** read as a corridor, which was the specific risk flagged
in task fcd2e04d when the lane separators were thinned — that risk did not materialise.

## What is not

**All twenty maps are the same map.** Every single tile has, in the same place:

- the same three vertical lane bands
- the same central circular plaza — the centre spinner colonnade, which `arena.nim` adds
  unconditionally
- the same two symmetric lighter spawn pockets, left and right
- the same left-right mirror

The variation is entirely in the *fill* — which pebbles land in the lanes. The brief is explicit
that this is the thing that does not count:

> an archetype picks the route topology and the spatial character; the biome and the shape
> vocabulary then only skin it. **Different archetype = different GRAPH, not different pebbles.**

The brief's self-check is "could you identify a specific seed from its picture alone?" Looking at
this sheet, honestly: no. I could sort tiles by texture density. I could not name one.

Maxwell's original complaint — "they should be very unique from one another, different styles...
this is all the same pinwheel shape" — has been treated in this epic as a 4-team problem. **It is
not. It is equally true at 2 teams**, and the 2-team branch is the one that already passes every
numeric acceptance criterion. That is the whole argument for why task 10fc7a24 (archetypes) is a
graph-topology task and cannot be satisfied by tuning the vocabulary weights.

## Two concrete consequences

1. **The centre plaza is a fixture and the brief says it must not be.** It is present on 20/20
   tiles. Task 10fc7a24 already notes the colonnade is unconditional and that a `field` or `ring`
   archetype wants it off, with the caveat that it is load-bearing for the spinning-diamond
   mechanic. This sheet is the evidence that it is currently the single strongest source of
   sameness — it draws the eye to the same spot on every tile.

2. **`interiorFrac` at 0.300 is now exactly on the acceptance line, down from 0.315.** The
   small-board fix cost 0.007. That is acceptable and it bought validity 90% -> 100%, but there is
   no headroom left: any further structure change that costs enclosure breaks the bar. Whoever
   takes the enclosure or corridor-floor work should treat 0.30 as a floor they are already
   standing on, not one they are approaching.
