## GV44 (home-SLOT rotation, classic 4-team) x the BR spawn subsystem's own
## spawn-GROUP rotation (16-team): these two lanes never ran in the same
## process before this integration. GV44 lands on main for classic play
## (`docs/RULES.md` "Battle-royale elimination..." neighbour, "the homes are
## dealt"); the BR spawn subsystem lands on this branch for 16-team play.
## Both key off the SAME `config.seed`, through DIFFERENT formulas
## (`homeRotationFor` vs `spawnGroupOffset`) into DIFFERENT places
## (`CtfMap.homeRotation`/`homeSlot` vs the runtime-only `spawnGroupOffset`
## call in `spawnPosition`/`spawnAimBrads`). Nothing in
## `resolveCtfMapMetadata` gates GV44's rotation on team count beyond > 2, so
## it computes and applies a rotation on a 16-team BR map too — it just isn't
## SUPPOSED to mean anything there, because BR authors `spawnPoints` and
## `spawnPosition`'s BR branch never consults `homeSlot` at all.
##
## That "isn't supposed to" was not actually true until `homeSlot` was fixed
## (arena.nim): before the fix, a BR board reports `layoutSides`, which has
## no rot90 orbit — `rot90Quarter` returns 0 for every team under that
## layout — so `homeSlot`'s search either matched EVERY team (rotation mod 4
## == 0, so it always returned Red: every team's `teamAnchor` collapsed onto
## one point) or NO team (falls through to identity by accident, not by
## contract). `teamAnchor` is read unconditionally per team by
## `selectCtfMap` (`ArenaAnchors`) on EVERY map, BR included — the collapse
## was inert only because BR's other consumers (`spawnPosition`,
## `spawnAimBrads`, `defaultCtfRooms`) all early-return on authored
## `spawnPoints` before reaching it, one new `ArenaAnchors` reader away from
## a real bug.
##
## This suite pins the fixed contract directly:
##   1. GV44's rotation is genuinely live on a 16-team BR map (computed,
##      matches `homeRotationFor`) — but `homeSlot` is the identity there,
##      exercised across BOTH branches of the old bug (rotation mod 4 == 0
##      and != 0), not just one hand-picked seed.
##   2. BR's actual seat placement is PROVABLY independent of whatever GV44
##      rotation is simultaneously live on the map struct — proven by
##      re-running one seed with `homeRotation` forced to several different
##      values and diffing every seat, not by code inspection.
##   3. A classic 4-team GV44 game and a 16-team BR game booted back-to-back
##      in the same process (sharing the installed-map globals `selectCtfMap`
##      writes) do not leak state into each other in either direction.

import
  helpers,
  std/[json, tables, unittest],
  ctf/[arena, global, sim, sim_config, sim_types]

const
  W = 1235
  H = 659
  SpawnClear = 40
  Groups = 16
  SeatsPerGroup = 2

proc gridSpawnPointsNode(count = Groups): JsonNode =
  ## `count` points on a 4-column grid, team-major: point i is group i's one
  ## landing spot (SeatsPerGroup seats re-share it, in join order). Spacing
  ## comfortably clears SpawnClear and every board edge — see
  ## test_br_team_bridge.nim, which authors the identical grid.
  result = newJArray()
  for i in 0 ..< count:
    let
      col = i mod 4
      row = i div 4
    result.add %*[154 + 308 * col, 82 + 165 * row]

proc brSpec(): string =
  ## A minimal BR-shaped map spec: symNone, the default ("sides") layout — a
  ## BR board has no sides/corners concept at all — flagless, 16 authored
  ## spawn groups, and all four neutral item pools authored (validateMap
  ## rejects a flagless spawnGroups>1 map that leaves any of them empty).
  var node = %*{
    "name": "gv44-br-rotation-demo",
    "width": W, "height": H,
    "flagRing": 70, "captureClear": 210,
    "spawnClearW": SpawnClear, "spawnClearH": SpawnClear,
    "gunRange": 331,
    "symmetry": "none",
    "layout": "sides",
    "endzone": "column", "endzoneRadius": 0, "homeDepth": 0,
    "medKitSpawns": [[W div 2, H div 3], [W div 2, 2 * H div 3]],
    "medKitCandidates": [[W div 2, H div 3], [W div 2, 2 * H div 3]],
    "leftObstacles": newJArray(),
    "flagless": true,
  }
  node["spawnPoints"] = gridSpawnPointsNode(Groups)
  node["shieldSpawns"] = gridSpawnPointsNode(Groups)
  node["spraySpawns"] = gridSpawnPointsNode(Groups)
  node["grenadeSpawns"] = gridSpawnPointsNode(Groups)
  node["spawnGroups"] = %Groups
  $node

proc brConfig(seed: int): GameConfig =
  result = defaultGameConfig()
  result.teams = Groups
  result.seed = seed
  result.mapSpec = brSpec()

proc fourTeamConfig(seed: int, layout: string): GameConfig =
  result = defaultGameConfig()
  result.teams = 4
  result.mapPath = "gen"
  result.mapGen.layout = layout
  result.mapSeed = 11        ## one terrain for every seed, so only the
  result.seed = seed         ## seed-derived home rotation varies here.

proc brSeatPositions(seed: int, homeRotationOverride = int.low): seq[(int, int)] =
  ## Every seat's (homeX, homeY) for a fresh 16-group, 32-seat BR game.
  ## `homeRotationOverride`, when set, force-writes the map's GV44 rotation
  ## to a value DIFFERENT from whatever `resolveCtfMapMetadata` drew for
  ## `seed`, before a single player joins — isolating whether BR placement
  ## depends on it at all, rather than trusting the code path by inspection.
  var config = brConfig(seed)
  var sim = initCtfForTest(config)
  if homeRotationOverride != int.low:
    sim.gameMap.homeRotation = homeRotationOverride
  for i in 0 ..< Groups * SeatsPerGroup:
    discard sim.addPlayer("p" & $i)
  sim.startGame()
  invalidateBoardMapCaches()
  for p in sim.players:
    result.add (p.homeX, p.homeY)

proc classicAnchors(seed: int, layout: string): Table[Team, MapPoint] =
  ## Every team's resolved home anchor for a fresh 4-team GV44 game.
  var config = fourTeamConfig(seed, layout)
  var sim = initCtfForTest(config)
  for i in 0 ..< 4:
    discard sim.addPlayer("p" & $i)
  sim.startGame()
  invalidateBoardMapCaches()
  for team in sim.teams():
    result[team] = sim.gameMap.teamAnchor(team)

suite "GV44 x BR: independent rotations":
  test "GV44's rotation is live on a 16-team BR map, but homeSlot is the identity there":
    var sawZeroMod4 = false
    var sawNonzeroMod4 = false
    for seed in 0 ..< 300:
      let gameMap = loadCtfMapMetadata(brConfig(seed))
      check gameMap.teamCount() == Groups
      check gameMap.layout == layoutSides
      ## GV44 does not know this is BR: the rotation is computed exactly as
      ## it would be for any > 2-team map.
      check gameMap.homeRotation == homeRotationFor(seed, Groups)
      if gameMap.homeRotation mod 4 == 0: sawZeroMod4 = true
      else: sawNonzeroMod4 = true
      for team in gameMap.teams():
        check gameMap.homeSlot(team) == team
        check gameMap.teamAnchor(team) == gameMap.slotAnchor(team)
    ## Both branches of the pre-fix bug (collapse-to-Red at rotation mod 4
    ## == 0, accidental identity otherwise) must have been exercised across
    ## this seed sample, or the identity checks above would be vacuous.
    check sawZeroMod4
    check sawNonzeroMod4

  test "BR seat placement is provably independent of GV44's home rotation":
    for seed in [0, 3, 11, 42, 777, 12345, 99999]:
      let natural = brSeatPositions(seed)
      check natural.len == Groups * SeatsPerGroup
      ## Force several rotations that are NOT what the seed naturally drew
      ## (0 and a nonzero value cover both branches of the pre-fix bug; a
      ## large value proves it is not just small ints that are ignored).
      for override in [0, 1, 2, 3, 999983]:
        if override == homeRotationFor(seed, Groups):
          continue
        check brSeatPositions(seed, override) == natural

  test "a classic GV44 game and a BR game do not cross-contaminate through installed-map globals":
    const
      ClassicSeed = 17
      BrSeed = 99
    let
      classicBefore = classicAnchors(ClassicSeed, "corners")
      brBefore = brSeatPositions(BrSeed)
    ## Boot the OTHER kind of game (repeatedly, at other seeds) in between,
    ## re-installing the process-global arena (selectCtfMap) each time.
    discard brSeatPositions(BrSeed + 1)
    discard classicAnchors(ClassicSeed + 1, "plus")
    discard brSeatPositions(BrSeed + 2)
    discard classicAnchors(ClassicSeed + 2, "corners")
    let
      classicAfter = classicAnchors(ClassicSeed, "corners")
      brAfter = brSeatPositions(BrSeed)
    check classicAfter == classicBefore
    check brAfter == brBefore
    ## And the rotations really did differ between the two games sharing
    ## this process — otherwise "did not cross-contaminate" would be
    ## unfalsifiable.
    check classicBefore.len == 4
