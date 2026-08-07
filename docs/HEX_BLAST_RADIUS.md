# The hex migration's blast radius — swept, with what each surface now proves

Sweep of `maxwell/hex-silent-failures` @ `91f2aa5`, run 2026-08-07. Branch:
`maxwell/hex-blast-radius`. Third and last of the hex audit trilogy, after
`HEX_SHIP_GATE.md` and `HEX_SILENT_FAILURES.md`.

This one is a SWEEP, so the failure mode is not writing bad code — it is
missing a caller. The rule it was run under: **"no error" is not evidence of
coverage.** Every surface below is either handled with something that would go
RED if it regressed, or reported as not handled. The starting suite was
**578 tests green**, which is exactly why a green suite could not be taken as
the answer to anything.

## What was already done, and is not re-litigated here

Rounds one through three had already landed `tests/helpers.nim`, the geometry
test rewrites, `map-validation-baseline.tsv`, `PoolRenderHashes`, five of the
six `.bitreplay` fixtures on GV41, the pool re-curation and
`docs/pool-review.html`. Verified green and left alone.

## The four things that were actually broken

### 1. Both 4-team leagues booted nothing — and the suite was green

`coworld_manifest_paintbot.json` published `4ffa` and `4ffa8` as
`teams: 4, mapPath: "gen"`. The hexagon's generator refuses every team count
but 2, so the real release binary died at boot on the manifest's own config:
exit 1, no listener, every seated bot timing out. Two of three live competitive
variants, dead.

`test_manifest_schema.nim` had five tests over the `config_schema` — the knobs
an operator MAY set — and **not one that ran a published variant's own
`game_config` through the engine.** A manifest is data; nothing was reading it.

* **Goes red now:** *every published variant RESOLVES A MAP the engine will
  seat*, over both manifests. It named both broken variants with the engine's
  own error before the fix.
* **Fixed by:** `arena-hex4` / `arena-hex4-giant`, hand-authored Klein-four
  hexagons as NAMED maps in `arena.nim` — not `mapSpec` blobs pasted into a
  1,600-line hand-synced manifest, because that is geometry owned by data.
  Verified V4-exact: Red (355,280) carries to (355,688) / (763,280) /
  (763,688) about the (559,484) centre.
* **Deliberately bare.** The 2-team slalom seeds a half-plane; V4 needs a
  quadrant. A wrong reuse is silently team-unfair rather than visibly broken.
* `mapSize: "giant"` came off `4ffa8` — under a named map it is a knob the
  engine silently ignores, which is the same failure family.

### 2. A six-team spec killed the process instead of being rejected

Found while writing the 3/6-team contracts. `activeTeams` refused a count
outside 2/3/4 with a **`doAssert`**. The spec rebuild reaches it while deriving
capture zones, and `layout` is a STRING off the wire — so `layout: "hex6"` in a
league config or a replay's pinned `mapSpec` raised an AssertionDefect, which
the `except CatchableError` those paths already wrap around exactly this kind
of rejection **cannot catch**. Under `-d:danger` the assert is compiled out
entirely and `Team(5)` is an out-of-range enum on the wire path.

Now a `CtfError`. The test's `try/except` IS the assertion — it would not have
caught a Defect.

### 3. The small size class put all four flankers inside the wall

Measured, not suspected. `tools/policy_lane_probe.nim` walks the reference
policy's lane posts over 11 boards and asks the sim's own predicate:

| | posts in wall |
|---|---|
| unclamped | **4 of 8 on BOTH small seeds**; 2 of 8 on one standard seed (terrain, not hull) |
| shipped | 0 hull failures on any board |

The flank posts are absolute pixels — `LaneTop` y=40, `FlankDepth` 260px either
side of centre — while a flat-top hexagon's top edge reaches only
`(width-1)/4`. That is 280px at standard (**20px of margin**) and ~238px at
small, 951px wide. Nothing crashed, nothing logged: two of six seats walked at
a wall for a whole episode.

`players/baseline/baseline/lanes.nim` (sibling of `endzones.nim`) now owns the
constants and clamps by SCANNING the engine's own `insideHex`/`hexEdgeDist` —
the choice `homeDepthWindow` makes, and for the same reason. `ctf/hex` is pure
and pulls in only `std/math`, so the bot's dependency cone is unchanged.
`test_policy_lanes.nim` also asserts the clamp is a **no-op from standard up**:
a rescue that quietly re-tuned every other board would be a behaviour change
arriving as a side effect.

### 4. The external decoder contract said the hull was the wrong shape

`tools/dump_map_mask.nim` ships as `decoder-gv<N>-<sha>` and daveey/cogamer
PINS a build, so its consumers parse output from a binary they chose against a
schema they read once. Its `boardShape` note said the hull was **pointy top**.
`HexBoard` has always built the flat-top one. A consumer that believed the
comment would reconstruct the hexagon rotated 30 degrees — every off-board test
wrong, in a way that still looks like a plausible map.

Corrected, with the six vertices now published outright so nobody derives the
hull from an adjective, and `test_decoder_contract.nim` checks they sit on the
boundary predicate the sim actually collides against.

Added `formatVersion`, independent of `GameVersion` — which cannot serve,
because it moves for unrelated reasons and did NOT move when the board became a
hexagon and the C4 zone keys were deleted. `docs/DECODER_CONTRACT.md` carries
the version table and the notify step.

**The subtler half is that `--raw` did not break loudly.** Still `w*h` bytes,
row-major, classes unchanged — so a consumer's shape check still passes while
~38% of the box is now hull void reported as stone (measured: floor is
**62.3%** of `arena`'s 1,084,311 bytes). Any open-fraction statistic has a
different denominator than at version 1, silently.

## Refuted, and asserted anyway

* **The policy's LANE ROWS are not void.** The hypothesis was that `LaneTop`
  y=40 names permanent void on a hexagon. It does not: the flat top edge is
  ~41% of the board's width and the lanes are real floor on every class. Only
  the x OFFSETS along them were out of band (finding 3).
* **The carrier's lane pick was already safe.** Since GV38 it charges a lane
  for every unwalkable sample, so it retires a wall lane on its own. Only the
  unconditional flank/standoff targets needed the clamp.

## Named, measured, and deliberately NOT changed

* **`FireRange = MapW + 15` rests on a dead premise.** Gun range stopped
  scaling with the field at GV34 (`GunRange` is a flat 1050px), so the
  reference bot engages past its own gun on every board that exists: 1134 on
  `arena`, 1470 on `arena-large`, **2924 on a giant seed** — nearly 3x the
  reach. It predates the hexagon (the 1235px arena was already 1250 vs 1050),
  so it is not a hex regression. Moving it moves every engagement in the game
  and needs an A/B, not a sweep.
* **`gen-colossal-4team.bitreplay` is the one fixture not re-recorded**, and
  the named 4-team boards do NOT unblock it. `build.yml` already documents two
  independent reasons, and only the first is about team count:
  1. the generator is 2-team — which `arena-hex4-giant` now sidesteps;
  2. **the replay format's uint16 string length prefix.** A replay pins its
     resolved geometry as `mapSpec`, and the colossal hexagon (5819×5039)
     draws 769 shapes whose mapSpec alone is 67,387 bytes against a 65,535
     ceiling. Over by 4% before a single seat is added, and no team or seat
     count claws that back.

  So the canary stays parked, and wasm32's 2GB ceiling stays untested at the
  top size class. Fixing it needs a shape budget for the colossal class or a
  uint32 prefix in bitworld's replay strings — a wire change. Note the giant
  class measures 16,875 bytes, comfortably under, so `arena-hex4-giant` is
  recordable; it is simply a 7.3M-pixel board rather than a 29M-pixel one and
  therefore not the same test.

  **New coordinate expressions audited for wasm32** (int is 32 bits there):
  `laneDepth`'s hull scan runs through `hexEdgeDist`, which is int64
  internally; `arenaHex4CtfMap`'s largest intermediate is
  `210 * 5039 = 1,058,190`; the hull vertices peak at `3 * 5818 = 17,454`.
  None approach int32. No new allocation is proportional to board area.

## Two plan docs were cited by shipped code and absent from the tree

`hex.nim` — the coordinate kernel "everything else in the conversion depends
on" — cites `docs/plans/2026-08-04-hex-arena-conversion.md` as its design
authority, and three more modules cite it or the generator plan. Neither file
existed on this lineage; both were stranded on `maxwell/hex-and-generator-plans`.
Restored, and marked SUPERSEDED IN PART with a table of what the proposal says
against what shipped — the largest gap being that the plan opens by declaring
3-team and 6-team modes are added, and neither exists.

## Surfaces checked and found ALREADY handled

Named so the next sweep does not redo them, each with the thing that would go
red:

* **`tools/` (item 5).** `build.yml` already compiles every tool and the
  baseline player with `nim check --path:src` — added in an earlier round
  after two probes sat broken with CI fully green. Run locally over all ~90
  tools plus `players/baseline`: **0 failures**, including this sweep's new
  `policy_lane_probe.nim` (which needs `--path:src`, exactly what that step
  provides).
* **The map editor's zone vocabulary.** `map_editor.nim` already emits
  `disc`/`anchorX`/`anchorY`/`radius` and documents the retired C4 keys;
  `editor.js` carries no `rot90`, `corners` or `plus`. `test_map_editor.nim`
  and `test_map_editor_core.nim` are the guard.
* **`build_pool_review.py`'s SIZE_NAMES.** Already returns `f"{width}px"`
  rather than raising — "an unrecognised width is a fact worth SHOWING".
* **`docs/pool-review.html` (item 10).** Not regenerated, and should not be:
  this branch touches no generator, validator, RNG stream or `MapPoolSeeds`,
  so every pool render is byte-identical. Regenerating it would produce a
  diff that misrepresents what changed.
* **`tools/four_team_map_probe.nim`** no longer exists; the 4-team probing it
  did lives in `ez_probe_aacf.nim` and `test_four_team.nim`.

## Not settled here

* **The generator is 2-team.** Rectangular boards alongside hex, and hex at
  2/3/4/6 teams, is the stated target end state. It is generator work — the
  rectangular path was deleted rather than parameterised, and main's GV39
  `symQuadMirror` is an opposing design for one generator (ship-gate blocker
  C) — plus Stage 2b and the `Team` enum. `test_three_team.nim` and
  `test_six_team.nim` are the acceptance checklist: they go red, item by item,
  as each blocker lifts.
* **Cutting the decoder release and notifying the consumer** is left to a
  human. Publishing is public and hard to undo.
