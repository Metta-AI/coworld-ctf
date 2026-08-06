# Epic 3757029c scorecard — LAND THE GENERATOR

Epic owner, 2026-08-06. Scored against five lenses. **A lens with no measurement scores ZERO, not
"assumed fine".** Every number here I measured myself on `maxwell/mapgen-rebuild`, with the arena
as control in the same batch and an explicit clean `--nimcache`, rather than accepting a report.

State at time of writing: 11 of the epic's tasks closed. Pool re-curation (c752704b) and the label
regression (89d9ce71) are in flight; corridor floor (49cb2dce), the retargeted enclosure task
(b7f44fb5) and the GV39 fairness bundle (d768ba09, complete but deliberately unmerged) are not.

---

## Lens 1 — Validity and invariants: 9/10

    2-team validity   90%  ->  38/40 (95%)     bar >= 95%   MET, with ZERO margin
    4-team validity   68%  ->  32/32 (100%)    bar >= 95%   MET
    staticScore       0.939 -> 0.978 / 0.991                MET, improved on both
    suite failures    37   ->  4               bar 0        NOT MET
    raise cascade     34   ->  0                            MET
    spec -> map identity   18/18, 11/11 fresh maps          MET (was flagged a possible ship-blocker)
    distinct maps          39/39, 32/32                     MET (was 10 of 16 seeds on 2 maps)

The headline of the epic — "about 32 of 37 failures are 4-team tests that die on a RAISE" — is
resolved. `generateCtfMap` no longer fails to produce a map anywhere in the suite. The four
remaining failures are expectation re-derivations, all owned, none a generator failure.

Docked a point because 2-team sits EXACTLY on 95% with no headroom and three separate correct
local fixes have now hit the 170pm cover ceiling from underneath.

## Lens 2 — Architecture and enclosure: 6/10

    2-team interiorFrac   0.315 -> 0.260      bar >= 0.30   NOT MET  (sheet mean 0.294)
    4-team interiorFrac   0.098 -> 0.276      bar >= 0.30   NOT MET  (2.8x improvement)
    repair-plug share     0%                                MET (prosthetic verified deleted)
    column lattice        deleted                           MET

4-team enclosure improved 2.4x and is the single largest architectural gain in the epic. Both team
counts still miss the stated bar and **that is reported as a miss** — even though this epic proved
the criterion points the wrong way (Lens 5), the bar as written was not met and substituting the
new criterion silently would be moving the goalposts.

## Lens 3 — Diversity and archetypes: 8/10

    distinct maps per seed   39/39, 32/32                   MET
    archetypes shipping      6 (bar was >= 5)               MET
    nameable on a sheet      yes, at both team counts       MET
    centre no longer a fixture                              MET

The seed collapse is genuinely fixed — ten 4-team seeds used to produce two maps — and SIX route
topologies now ship: `three-lane`, `blocks`, `ring`, `hub`, `warren`, `field`. Each is chosen from
its own seed-level RNG scene, so the archetype is a property of the SEED and every best-of-K
candidate is another try at the same design.

They are different GRAPHS, not different pebbles, and the fingerprints prove it:

    warren   9 rooms median, interiorFrac 0.444, largest room 0.12
    field    1-3 rooms,      interiorFrac 0.213, largest room 0.36

3x apart on largest-room and 2x on enclosure, in OPPOSITE directions, neither wrong. Room count
varies 1..11 and route count 0..12 across seeds, both straddling the control (7 and 8), reported
as distributions because means would hide exactly this.

I rendered 20 2-team and 16 4-team tiles and looked. `warren`/`blocks` read as room lattices with
doorways, `field` as a few large masses in open ground, and at 4 teams `ring` reads as a perimeter
loop with radiating spurs. **The centre plaza was on 36 of 36 tiles before this landed and is now
absent on several** — it was the single strongest source of sameness.

Docked because not every tile is confidently nameable, and because `three-lane` — the oldest of the
six, and the only one not rewritten — is measurably the weakest on every axis (80% valid against
100% for all five others, score 0.785 against a next-lowest 0.946, one seed with routeMin 0).

## Lens 4 — Suite and contract health: 8/10

    spec -> map identity      HOLDS, proven on fresh maps, not the pool
    replay hashes             NOT re-recorded; GV39 bump deliberately unmerged
    fairness (GV39)           diagnosed, branch complete, NOT landed
    label vocabulary          REGRESSED — a new label appeared, filed 89d9ce71
    validation baseline       stale by design; regenerate after map work settles

The contract is in good shape and the one genuine scare — "every curated map spec round-trips
byte-identically" — turned out to be a RAISE, not a round-trip break. Docked for the live label
regression and for GV39 being correct-but-unlanded.

## Lens 5 — Gameplay, measured not assumed: 8/10

This scored ZERO at the end of the previous session and saying so plainly was the most useful part
of that handoff. It is now the best-evidenced lens in the epic.

    2-team play        24 episodes, arena control in-batch        VERDICT: plays WORSE than control
    4-team play        15 episodes, gen:1007 labelled reference   measured; "arena control" bar SCORES ZERO
    staticScore vs play  41 maps, 210 episodes, reliability 0.92-0.98

The findings that matter more than the score:
* A generated map (`gen:1023`) scored staticScore **1.000, tying the control exactly**, and across
  three full episodes the enemy heart was **never taken** — 0 steals against the arena's 5.
* `interiorFrac`, the epic's own acceptance criterion, ranks maps **backwards** on dead floor
  (+0.638, p<0.001). Maps passing >= 0.30 average 0.615 dead floor against 0.542 for maps that fail.
* The arena is out of distribution on exactly one axis — dead floor — and 0 of 40 generated maps
  come near it.
* W0 fixed a REACHABILITY defect, not just a validation rate: every objective is now approached
  4/4 on all five 4-team boards, where an enemy previously reached only 2 of 4 pedestals.

Not 10/10 because reachability is still asymmetric (attackPairs 42-75%, never 12/12) and the
4-team lens has no true control.

---

## What this epic actually proved

Four mechanisms were believed active and measured **inert**. That is the through-line:

    the fill-density sweep      clamped, moved cover 4pm across a 2.2x range
    bandHard                    the ONE hard band, and nothing read the field
    the 4-team terrain block    dropped 34 of 34 shapes, every attempt
    pitInstead                  deleted cover and left no pit where it had been

Every one read correctly in the source. Every one was caught by measuring the thing it was supposed
to change against a control. **None needed a rewrite to find.**

And three standing diagnoses were proven wrong, including one of mine: the 4-team raise was not
connectivity (the task's premise) and not the fill-budget floor (my correction to it — on rot90
`structureCount` is 0 so that clamp never fires). I found a flat series, correctly concluded
something was inert, then named the first inert-looking mechanism in the source instead of
rendering the board. That is the same error the task's own history records three times.

## The bar, honestly

    suite 0 failures                          NOT MET — 4, all owned, zero raises
    2-team AND 4-team >= 95% valid            MET — 95% and 100%
    interiorFrac >= 0.30 both counts          NOT MET — 0.260 and 0.276
    staticScore no worse than 0.939           MET — 0.978 and 0.991
    repair-plug share 0%                      MET — verified deleted, not merely unused
    50-map sheet with nameable archetypes     MET — 6 archetypes, named by eye at both counts
    pool re-curated + pool-review.html        NOT MET — not started
    >= 1 play result per team count + control  PARTIAL — 2-team yes; 4-team measured, control ZERO

**The epic is not done and must not be closed.** Three of eight bar items are unmet. Closing it here
is exactly how the next handoff starts with "fifty generated maps are still one map" again.
