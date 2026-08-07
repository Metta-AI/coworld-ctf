# The 50-map sheet, at both team counts, looked at

The epic's definition of done asks for "a 50-map sheet an observer can name
archetypes from". This is that sheet, rendered by the epic owner on
`maxwell/mapgen-rebuild` @ 64f3975 with a fresh `--nimcache`, and this is what
it looks like rather than what it scores.

    docs/plans/2026-08-06-sheet50-2team.png    50 seeds, 48 rendered
    docs/plans/2026-08-06-sheet50-4team.png    50 seeds, 50 rendered

## The numbers, with the control in the same batch

| | 2-team | 4-team | arena control |
|---|---|---|---|
| valid | **48/50 (96%)** | **50/50 (100%)** | — |
| mean staticScore | 0.976 | 0.972 | 1.000 |
| mean interiorFrac | 0.295 | 0.274 | 0.342 |

Both counts clear the >= 95% validity bar, and 2-team now clears it with margin
rather than sitting exactly on it: the earlier 38/40 (95%) was a 40-seed window,
and widening it to 50 found 48. The two failures are seeds **1026 and 1038**,
which are the same two the pool re-curation rejected, and both are `three-lane`
— the one archetype of the six that was not rewritten. Every 2-team validity
failure this epic has left is that single topology (filed, `897b384c`).

4-team mean staticScore reads 0.972 here against 0.991 on the 32-seed sweep.
That is the wider sample, not a regression — 0.991 was measured over 32 seeds
and this is 50. Report the wider one.

**`interiorFrac` misses at both counts: 0.295 and 0.274 against a >= 0.30 bar.**
It is a miss and it is recorded as a miss. 2-team is 0.005 short.

## What the sheet actually shows

**It is not one map.** That was the previous handoff's charge and it no longer
holds. At 2 teams I can name, without the captions: dense orthogonal room
lattices with long straight walls (`warren`/`blocks`); a few large organic
masses on open ground (`field`); boards whose corners are cut by big diagonal
X-walls; and long horizontal bar arrays (`three-lane`). At 4 teams the families
are, if anything, cleaner — a genuine STREET GRID with orthogonal lanes and
blocks between them, a RADIAL pinwheel of four spokes off the centre, a
DIAGONAL star family, and a sparse-scatter family. The four-fold signature of
`symRot90` is unmistakable and correct on every 4-team tile.

**And the honest reservation, which is the same shape as the interiorFrac miss.**
Across 48 2-team tiles the single most repeated visual element is a texture of
small, roughly equal-sized dark squares and diamonds scattered over open floor.
A plurality of tiles read as that texture first and as their archetype second.
This is the CONFETTI failure mode the enclosure work named explicitly, and the
picture and the number agree for once: cover that is spent on pebbles is cover
that buys no enclosure, which is exactly `interiorFrac` 0.295 against the
control's 0.342.

At 4 teams there is a second repetition: a small square ring around the board
centre recurs on a large share of tiles, and down the first column especially
the radial-with-centre-box design reads as the same board redrawn with
different pebbles.

So the bar is scored **MET WITH RESERVATION** at both counts: the strong
families are nameable by eye and the sameness charge is retired, but a
plurality of tiles are nameable only by their texture.

> **⚠️ CORRECTION, same day.** The next sentence used to read "the remaining work
> is spending the same cover budget on masses instead of pebbles". Measured
> directly in `2026-08-06-what-the-cover-is-made-of.md`, that is wrong twice
> over. Speck share does not separate maps that clear the `interiorFrac` bar
> from maps that miss it (2-team 20.5% against 21.9% of footprint), and at 4
> teams the PASSING maps carry more specks, not fewer (45.1% against 28.7%).
> Adding masses is worse still: passing maps carry about a THIRD the mass share
> of failing ones at both counts, and the hand-authored control has none at all.
>
> The observation above stands — the texture really is what a plurality of tiles
> read as, and the eye really does see it first. What was wrong was inferring
> the *cause of the number* from it. Specks are 74-92% of the shape COUNT and a
> contact sheet cannot show footprint, so the eye was reading the loudest signal
> rather than the load-bearing one. The separator is footprint at 34-68px, the
> arena's only bucket.

## Method note

The two failed seeds are rendered as BLANK CELLS rather than skipped, so the
sheet's grid shows 50 slots with 2 gaps. A contact sheet that silently packed
48 tiles into 48 slots would report 100% by omission — the same class of error
as a count reported without its fraction.
