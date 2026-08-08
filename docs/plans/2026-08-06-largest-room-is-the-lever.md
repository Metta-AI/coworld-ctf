# `interiorFrac` is the largest room, inverted — and at 2 teams it is the archetype

Measured 2026-08-06 by the epic owner on `maxwell/mapgen-rebuild` @ 9c149a6,
`tools/archetype_probe.nim --raw` and `tools/pebble_probe.nim`, arena control in
both batches, fresh `--nimcache`.

This is the third reading of the Lens 2 miss in one afternoon. The first two
were mine and both were wrong. It is worth stating the sequence, because the
error is instructive and this document is the handoff for `b7f44fb5`:

1. From the contact sheet: *the boards are full of pebbles, so cover is being
   spent on pebbles.* **Refuted** — speck share does not separate maps that clear
   the bar from maps that miss it, and at 4 teams the passing maps carry more.
2. From the footprint buckets: *passing maps carry a third the mass share, so
   masses are the problem.* **True but downstream** — mass share turned out to be
   mostly a proxy, which is the confound the last document flagged as unchecked.
3. This one, which checks it.

## The measurement

Ranking the six archetypes by median largest-room fraction and reading
`interiorFrac` off the same table:

    2 TEAMS      largest room    interiorFrac      n   valid
      warren         0.12           0.444          6   6/6
      three-lane     0.16           0.324          6   5/6
      blocks         0.17           0.278          8   8/8
      ring           0.18           0.227          2   2/2
      hub            0.32           0.196          2   2/2
      field          0.34           0.221          6   6/6
      arena control  0.15           0.342          —   —

    4 TEAMS      largest room    interiorFrac      n   valid
      warren         0.05           0.317          6   6/6
      blocks         0.11           0.299          8   8/8
      field          0.14           0.274          4   4/4
      ring           0.17           0.284          7   7/7
      hub            0.23           0.205          5   5/5

**Order the archetypes by largest room and `interiorFrac` comes out in exact
reverse — 5 of 6 at 2 teams, 4 of 5 at 4 teams.** The two exceptions are
adjacent pairs separated by 0.025 and 0.010. Across a 2.3x spread in enclosure
at 2 teams, one descriptive coordinate that nobody chose as a quality term
orders it almost perfectly.

That is not a coincidence and it is not a correlation looking for a mechanism.
`interiorFrac` is open floor with at least 6 of 8 directions blocked within
120 px. **The middle of a big room has nothing blocked.** A board's largest room
is, almost by construction, its largest reservoir of floor that cannot count. So
is a 120px+ mass, for the same reason from the other side — it fills floor it
would otherwise enclose, which is why the mass-share reading was true.

## At 2 teams the miss is one archetype's problem, not the generator's

Cross-tabbing the 11 of 29 seeds that clear `interiorFrac >= 0.30` against what
the seed drew:

    warren        6 of 6 pass     100%
    three-lane    3 of 5 pass      60%   (of the valid ones)
    blocks        2 of 8 pass      25%
    field         0 of 6 pass       0%   best seed 0.295
    ring          0 of 2 pass       0%
    hub           0 of 2 pass       0%

`warren` clears the bar on every seed it draws and averages 0.444 — **1.3x the
hand-authored arena.** `field`, `hub` and `ring` clear it on none. The 0.292
population mean is a weighted average over the archetype MIX, and the mix is a
design choice rather than a tuning parameter.

At 4 teams the same table is compressed — 0.317 down to 0.205, a 1.5x spread
against 2 teams' 2.3x — and **no archetype is a reliable pass**. Only `warren`
clears 0.30 as a group and `blocks` sits at 0.299. So the two team counts miss
the bar for genuinely different reasons: 2-team is an archetype problem, 4-team
is a broad one.

## ⚠️ THE TRAP, which is now one line of code

The bar is `interiorFrac >= 0.30`. The archetype draw is a seed-level RNG scene.
**Reweighting that draw toward `warren` would hit the bar this afternoon**, take
the 2-team mean well past 0.30, and require no understanding of anything.

It would also make every board a room lattice. The centre plaza was on 36 of 36
tiles before this epic and removing it was the single largest gain in Lens 3;
replacing it with `warren` on 36 of 36 tiles is the same failure with a better
number. `field` at largest-room 0.34 and `warren` at 0.12 are 3x apart in
opposite directions and **neither is wrong** — that spread is the diversity the
epic bought.

If the archetype weights move, the 50-map sheet has to be re-rendered and looked
at before the number is reported, and the weight change has to be stated in the
commit rather than buried in a tuning diff.

## What `b7f44fb5` should actually do

The lever is **subdivide the largest room**, not add masses and not remove
specks. `warren` already does it — 9 to 11 rooms, largest 0.12 — and it is in
the generator today, passing 6 of 6, so the mechanism does not need inventing.
The work is making `field`, `hub` and `ring` break up their dominant room while
staying recognisably themselves, and at 4 teams doing it across the board.

That is a falsifiable single intervention with an obvious control: take a failing
`field` seed, subdivide its largest room, hold cover permille fixed, and see
whether `interiorFrac` moves the amount this table predicts. Nobody has run it.

## What this does NOT establish

Rank correlation over 6 and 5 groups is weak evidence on its own; the two
exception pairs are within noise of their neighbours and the `ring` and `hub`
groups are n=2 at 2 teams. Room count is measured as basins of the distance
transform at a fixed clearance, so "largest room" and `interiorFrac` are both
functions of the same mask and are not fully independent measurements — a
sceptic can reasonably call part of this definitional. What would settle it is
the intervention above, and this document is not that.
