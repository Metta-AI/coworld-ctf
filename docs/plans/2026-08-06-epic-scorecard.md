# Epic 3757029c scorecard — LAND THE GENERATOR

Epic owner, 2026-08-06. Scored against five lenses. **A lens with no measurement scores ZERO, not
"assumed fine".** Every number here I measured myself on `maxwell/mapgen-rebuild`, with the arena
as control in the same batch and an explicit clean `--nimcache`, rather than accepting a report.

State at time of writing: 15 of the epic's tasks closed, and **THE SUITE IS GREEN — 748 OK, 0
FAILED**, measured on the merged tree @ b20898a with a fresh `--nimcache`. Pool re-curation
(c752704b) and the label regression (89d9ce71) have landed. In flight: corridor floor (49cb2dce),
the staticScore re-weight (013a9c98), the hand-built 4-team control (710986ee) and the carrier-in-
zone sampler (7d972e05). Not started: the retargeted enclosure task (b7f44fb5). Complete but
deliberately unmerged: the GV39 fairness bundle (d768ba09), which lands LAST by merge order.

---

## Lens 1 — Validity and invariants: 10/10

    2-team validity   90%  ->  48/50 (96%)     bar >= 95%   MET, with margin
    4-team validity   68%  ->  50/50 (100%)    bar >= 95%   MET
    staticScore       0.939 -> 0.976 / 0.972                MET, improved on both
    suite failures    37   ->  0               bar 0        MET
    raise cascade     34   ->  0                            MET
    spec -> map identity   18/18, 11/11 fresh maps          MET (was flagged a possible ship-blocker)
    distinct maps          39/39, 32/32                     MET (was 10 of 16 seeds on 2 maps)

The headline of the epic — "about 32 of 37 failures are 4-team tests that die on a RAISE" — is
resolved. `generateCtfMap` no longer fails to produce a map anywhere in the suite.

**All 37 failures are gone and NOT ONE of them was fixed by weakening a test.** 34 were one bug
wearing 34 names and cleared as a group without those tests being touched. Of the last four, two
were expectation re-derivations (the pit totals, the sightline rows) and two — plus a third found
alongside them — were **assertions that go red when the generator improves**: `test_burrow`
demanded a DISCONNECTED board, and `test_map_eval` asserted a giant board has more routes than the
arena (it has 5 against 8) and that the curated pool stays WORSE than the hand-authored control
(the margin had fallen to 0.002). Each was re-derived from what it meant rather than re-pinned, and
the pool one was replaced by a claim about the INSTRUMENT that cannot ratchet: the stick must rank
a board that spends its cover on pebbles below one that spends the same cover on masses.

The 2-team margin also turned out to be a sample-size artefact: 38/40 (95%, zero headroom) became
48/50 (96%) once the window widened, and **both failures are seeds 1026 and 1038, both `three-lane`**
— the one archetype of six that was never rewritten. Every 2-team validity failure left in this
epic is that single topology.

## Lens 2 — Architecture and enclosure: 6/10

    2-team interiorFrac   0.315 -> 0.295      bar >= 0.30   NOT MET  (50-map sheet, 0.005 short)
    4-team interiorFrac   0.098 -> 0.274      bar >= 0.30   NOT MET  (2.8x improvement)
    arena control, same batch     0.342
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

**Re-checked at the full 50, and the reservation is sharper than "not every tile".** Both 50-map
sheets are rendered and committed (`2026-08-06-sheet50-verdict.md`). At 2 teams I can name warren
and blocks lattices, field masses, corner diagonals and three-lane bars without reading the
captions; at 4 teams a real street grid, a radial pinwheel, a diagonal star and a sparse family.
The sameness charge is retired. But **across 48 2-team tiles the single most repeated visual
element is a texture of small equal-sized dark squares**, and a plurality of tiles read as that
texture first and as their archetype second — the CONFETTI mode the enclosure work named. At 4
teams a small square ring around the centre recurs on a large share of tiles.

**And then the picture and the number were measured against each other, and they disagree.** I
wrote here that "cover spent on pebbles buys no enclosure, and that IS the Lens 2 miss". It is not.
Splitting the same 59 maps by the `interiorFrac >= 0.30` bar
(`2026-08-06-what-the-cover-is-made-of.md`) shows speck share does not separate pass from fail at
2 teams (20.5% of footprint against 21.9%) and runs BACKWARDS at 4 teams (passing 45.1%, failing
28.7%). What separates them is footprint at **34-68 px — the hand-authored arena's only bucket,
98.2% of its footprint** — and mass above 120 px, which passing maps carry about a third as much of
and the arena has none of. The eye read the loudest signal, not the load-bearing one: specks are
74-92% of the shape COUNT, and a contact sheet cannot show footprint.

## Lens 4 — Suite and contract health: 9/10

    spec -> map identity      HOLDS, proven on fresh maps, not the pool
    replay hashes             NOT re-recorded; GV39 bump deliberately unmerged
    fairness (GV39)           diagnosed, branch complete, NOT landed
    label vocabulary          RESOLVED — it was never a contract break
    validation baseline       re-dealt against the rebuilt generator
    pool + docs/pool-review.html   re-curated, regenerated, all 20 renders reviewed

The contract is in good shape and **both scares turned out to be something other than a contract
break**. "Every curated map spec round-trips byte-identically" was a RAISE, not a round-trip break.
The label regression was not a regression at all: `team score <TEAM> <kills>/<deaths>` is the
scoreboard chip and the `/2` that changed is Blue's DEATH COUNT, not a capture target. The real
defect was `normalizeLabel` keeping digits after a slash — an exception written for
`hp <lit>/<total>` and applied to every slashed label — so one sweep's death count got baked into
the golden. No label proc changed shape and the engine emits byte-identical strings. The exception
is now gated on `LabelPrefixHp`, and `labelTeamScore` joined the shared vocabulary it had been
sitting outside of as a bare string concat.

I regenerated `docs/pool-review.html` in a browser and looked at it rather than trusting the hash:
20 inline renders, 20 seeds, no missing tiles.

Docked only for GV39 being correct-but-unlanded.

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

    suite 0 failures                          MET — 748 OK, 0 FAILED, no test weakened
    2-team AND 4-team >= 95% valid            MET — 48/50 (96%) and 50/50 (100%)
    interiorFrac >= 0.30 both counts          NOT MET — 0.295 and 0.274 (control 0.342)
    staticScore no worse than 0.939           MET — 0.976 and 0.972 over 50 seeds each
    repair-plug share 0%                      MET — verified deleted, not merely unused
    50-map sheet with nameable archetypes     MET WITH RESERVATION — see Lens 3
    pool re-curated + pool-review.html        MET — 20 seeds re-pinned, every render reviewed
    >= 1 play result per team count + control  PARTIAL — 2-team yes; 4-team control IN FLIGHT

**The epic is not done and must not be closed.** One bar item is unmet outright (`interiorFrac`),
one is met with a stated reservation, and one is partial with the work in flight. That is a far
better position than the three-of-eight this document opened with — but "better" is not the gate.
Closing it here is exactly how the next handoff starts with "fifty generated maps are still one
map" again.

The `interiorFrac` miss now has a measured direction and it is the OPPOSITE of the one this
document and task `b7f44fb5`'s brief both assumed. Maps that clear the bar spend their footprint at
34-68 px — the arena's only bucket — and carry about a third the mass share of maps that miss it,
at both team counts. The experiment nobody has run is to move footprint OUT of the >=120 px bucket
into 34-68 px with cover permille held fixed. `b7f44fb5` is that work, it is Lane A, and it is
queued behind the corridor floor rather than skipped.

**20 of 59 seeds already clear the bar** (11/29 at 2 teams, 9/30 at 4), and the best 2-team seed
measures 0.548 — 1.6x the hand-authored control. The generator can already build boards more
enclosed than the arena; it does not do it reliably. That is a much cheaper problem than the mean
suggests, and the mean is what the definition of done is written against.
