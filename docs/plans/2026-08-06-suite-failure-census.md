# Suite failure census — 37 failures, classified

Measured 2026-08-06 by the epic owner on `maxwell/mapgen-rebuild` @ 4a013df, full suite,
`nim c -d:release -r tests/tests.nim`. This is the census epic 3757029c's Lane B is waiting on.

    total failures                 37
    raise cascade (generator dies) 34/37  (92%)
    real assertion failures         3/37  ( 8%)

A "raise cascade" failure is one where `generateCtfMap` threw
`no valid layout in 100 attempts` and the test's assertions never executed. Those tests are
not evidence of anything except that the generator would not produce a map.

## The 3 real failures — the only ones that need a decision

| test | file | what actually failed |
|------|------|----------------------|
| `generated-map validation matches the pre-refactor baseline` | test_map_editor_core.nim:226 | `collectedSightlineRows.len > 1` was **0**, then IndexDefect on `[0]` |
| `mapPits locks an exact total; odd counts anchor the map center` | test_mapgen.nim | exact pit total against an irregular fill-derived candidate set |
| `mapPitDensity scales the density draw` | test_mapgen.nim | same root cause as above |

The two pit tests are owned by task 78d0db3c. **The sightline-rows one is not owned by any task**
and is filed separately.

## Correction to the epic's framing

The epic states "about 32 of the 37 failures are 4-team tests". The 4-team share is real but the
cascade is **34/37, and it has TWO sources, not one**:

- 4-team seeds with no valid layout (5/16 = 31% of swept seeds) — task 157ce824 (W0)
- **2-team SMALL-class pool seeds 1015 and 1020 with no valid layout** — task fcd2e04d

The second source is why these plainly-2-team tests are in the failure list:

    every curated map spec round-trips byte-identically
    every pool seed ships a valid map under its own seed
    every compact pool seed keeps its flanks open
    the curated pool sits below the hand-authored control
    shared pool rendering matches the pre-extraction images
    the emitted label vocabulary matches tests/label_manifest.txt
    the endzone markers state each team's capture zone exactly
    every schema property is consumed by config.update

**Lane B is therefore blocked on BOTH 157ce824 and fcd2e04d, not on W0 alone.** Sequencing Lane B
behind only W0 would have left it re-curating a pool that still had two dead seeds in it.

Both blockers are the same underlying mechanism — see
`2026-08-06-fill-budget-floor-finding.md`: structure sized without reference to the domain it has
to fit in, plus a fill floor that clamps the density sweep and disables the escape valve.

## The ship-blocker is not a ship-blocker

`every curated map spec round-trips byte-identically` was flagged in task 78d0db3c as
"TREAT AS SERIOUS UNTIL PROVEN OTHERWISE — if this is a real round-trip break it is a
SHIP-BLOCKER and outranks everything else in this lane", because replays pin mapSpec.

**It is not a round-trip break. It is a raise.** Proven with `tools/spec_roundtrip_probe.nim`,
which generates fresh maps rather than sweeping the pool:

    2-team, 20 seeds: 18/18 generated maps round-trip (100%), json and CtfMap both
    4-team, 16 seeds: 11/11 generated maps round-trip (100%), json and CtfMap both

Fresh maps are also the harder test — they exercise the polygon masses and organic dithered
edges that the old lattice's rects and r28 discs never reached.

One control caveat, resolved: `arena` reports `json=true map=false`. That is benign and not a
geometry defect — `CtfMap.path` is deliberately not carried in the spec (`arena.nim:549` sets
`ArenaName`, `mapFromSpecJson` at `:3075` sets `GenMapName`). The geometry round-trips
byte-identically. Generated maps set `GenMapName` at `:1620` on both sides, so they compare equal.

## What this predicts

If the two validity blockers land, 34/37 failures clear as a group and the suite goes to 3
failures, all of them genuine expectation re-derivations. That prediction is falsifiable and
should be checked the moment both land — if the suite does not drop to ~3, something else is
wrong and the cascade theory was hiding it.
