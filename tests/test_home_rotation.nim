## Seed-derived rotation of TEAM -> HOME ownership (GV44).
##
## The pads never move: a 4-team board still carves the same four congruent
## home pockets, the same four pedestals and the same four capture zones. What
## rotates, once per episode and derived from the game seed, is WHICH TEAM OWNS
## WHICH ONE. Two-team play is untouched — Red left, Blue right is a game
## contract — so `homeSlot` is the identity there, and every 2-team number in
## this file is asserted against raw generator output, which never rotates.
##
## The whole point is that a home is a BUNDLE — anchor, pedestal, capture zone,
## spawn-strip orientation, spawn aim — so the coherence suite below re-checks
## the bundle at every rotation, and the invariance suite pins the things that
## must NOT move (the protected floor, the pad set, the pickup sets).

import
  helpers,
  std/[algorithm, sequtils, strutils, tables, unittest],
  bitworld/spriteprotocol,
  ctf/sim

var mapCache = initTable[string, CtfMap]()

proc fourTeamConfig(seed: int, layout: string): GameConfig =
  result = defaultGameConfig()
  result.teams = 4
  result.mapPath = "gen"
  result.mapGen.layout = layout
  result.mapSeed = 11        ## one terrain for every seed, so only the
  result.seed = seed         ## seed-derived home rotation varies here.

proc twoTeamConfig(seed: int): GameConfig =
  result = defaultGameConfig()
  result.mapPath = "gen"
  result.mapSeed = 5
  result.seed = seed

proc controlMap(config: GameConfig): CtfMap =
  ## The same terrain built straight from the generator, which has no rotation
  ## concept at all: only `resolveCtfMapMetadata` (the config path) applies
  ## one. This is the unrotated control every case below compares against, and
  ## it is what makes the 2-team identity check non-tautological.
  let key = $config.mapSeed & "|" & config.mapGen.layout & "|" & $config.teams
  if key notin mapCache:
    mapCache[key] = generateCtfMap(config.mapSeed, config.mapGen, config.teams)
  mapCache[key]

proc rotated(gameMap: CtfMap, rotation: int): CtfMap =
  ## The same board with a different home-ownership rotation. Terrain, masks
  ## and pad set are identical by construction; only team -> slot differs.
  result = gameMap
  result.homeRotation = rotation

proc nearestAnchorOwner(gameMap: CtfMap, x, y: int): Team =
  ## Which team's home anchor this point is closest to.
  result = Red
  var best = high(int)
  for team in gameMap.teams():
    let
      anchor = gameMap.teamAnchor(team)
      dx = x - anchor.x
      dy = y - anchor.y
      d = dx * dx + dy * dy
    if d < best:
      best = d
      result = team

suite "home rotation: 2-team identity":
  test "two teams never rotate, at any seed":
    ## Red left, Blue right is a game contract: the rotation must be the
    ## identity for every seed a 2-team episode can draw.
    for seed in 0 ..< 512:
      check homeRotationFor(seed, 2) == 0
      check homeRotationFor(seed, 1) == 0
      check homeRotationFor(seed, 0) == 0

  test "2-team homes match the unrotated generator exactly":
    for seed in [1, 7, 42, 1234, 90210]:
      let
        config = twoTeamConfig(seed)
        resolved = loadCtfMapMetadata(config)
        plain = controlMap(config)
      check resolved.homeRotation == 0
      for team in resolved.teams():
        check resolved.homeSlot(team) == team
        check resolved.teamAnchor(team) == plain.teamAnchor(team)
        check resolved.flagHome(team) == plain.flagHome(team)
        check resolved.spawnPocketHalf(team) == plain.spawnPocketHalf(team)
        check resolved.captureZone(team) == plain.captureZone(team)
        check resolved.spawnAimBrads(team) == plain.spawnAimBrads(team)
      check resolved.shieldSpawnPoints() == plain.shieldSpawnPoints()
      check resolved.sprayPaintSpawnPoints() == plain.sprayPaintSpawnPoints()

  test "2-team spawn strips and pedestals are unchanged":
    ## The played surface, not just the metadata: a real sim's homeX/homeY and
    ## flag pedestals still sit where the unrotated map says they do.
    let config = twoTeamConfig(31)
    var sim = initCtfForTest(config)
    for i in 0 ..< 6:
      discard sim.addPlayer("p" & $i)
    sim.startGame()
    check sim.gameMap.homeRotation == 0
    let plain = controlMap(config)
    var order: array[Team, int]
    for i in 0 ..< sim.players.len:
      let team = sim.players[i].team
      check sim.players[i].homeX ==
        sim.spawnPosition(team, order[team]).x
      check sim.players[i].homeY ==
        sim.spawnPosition(team, order[team]).y
      inc order[team]
    for team in sim.teams():
      let home = sim.gameMap.flagHome(team)
      check home == plain.flagHome(team)
      check sim.flags[team].x == home.x
      check sim.flags[team].y == home.y

suite "home rotation: 4-team fairness":
  test "every team occupies every home slot at 25% +/- 5pp":
    ## The population-level guarantee this whole change exists for: over a
    ## large seed sample no team is stuck with a slot.
    const Seeds = 4000
    for layout in ["corners", "plus"]:
      let base = controlMap(fourTeamConfig(0, layout))
      var counts = initTable[string, int]()
      for seed in 0 ..< Seeds:
        let gameMap = base.rotated(homeRotationFor(seed, 4))
        var slots: seq[Team]
        for team in gameMap.teams():
          let slot = gameMap.homeSlot(team)
          slots.add slot
          counts.mgetOrPut($team & "->" & $slot, 0) += 1
        ## A rotation is a PERMUTATION: no two teams may share a slot.
        check slots.deduplicate().len == 4
      for team in base.teams():
        for slot in base.teams():
          let share =
            counts.getOrDefault($team & "->" & $slot, 0).float / Seeds.float
          check share >= 0.20
          check share <= 0.30

  test "all four rotations occur over a 400-seed sample":
    var seen: array[4, int]
    for seed in 0 ..< 400:
      let rotation = homeRotationFor(seed, 4)
      check rotation in 0 .. 3
      inc seen[rotation]
    for rotation in 0 .. 3:
      check seen[rotation] > 0

  test "a spec-pinned map (the replay path) is dealt the same homes":
    ## Playback resolves the map from the PINNED spec, not the generator, and
    ## the spec deliberately carries no rotation field — the deal is a pure
    ## function of the `seed` a replay's config already echoes. So a spec
    ## round-trip has to land on the same homes, and a different seed on that
    ## same terrain has to land on a different deal.
    let
      live = loadCtfMapMetadata(fourTeamConfig(5, "corners"))
      spec = mapSpecJson(live)
    var replayConfig = fourTeamConfig(5, "corners")
    replayConfig.mapSpec = spec
    let replayed = loadCtfMapMetadata(replayConfig)
    check replayed.homeRotation == live.homeRotation
    for team in live.teams():
      check replayed.teamAnchor(team) == live.teamAnchor(team)
      check replayed.captureZone(team) == live.captureZone(team)
      check replayed.spawnAimBrads(team) == live.spawnAimBrads(team)
    ## Same pinned terrain, different episode seed: same pads, new deal.
    var otherSeed = replayConfig
    var differs = false
    for seed in 0 ..< 16:
      otherSeed.seed = seed
      let other = loadCtfMapMetadata(otherSeed)
      check other.slotAnchor(Red) == live.slotAnchor(Red)
      if other.homeRotation != live.homeRotation:
        differs = true
    check differs

  test "the config path really carries the rotation":
    ## Guards the wiring, not the hash: a rotation computed but never applied
    ## would pass everything above and change nothing on the board.
    var seenRotations: seq[int]
    for seed in 0 ..< 40:
      let gameMap = loadCtfMapMetadata(fourTeamConfig(seed, "corners"))
      check gameMap.homeRotation == homeRotationFor(seed, 4)
      seenRotations.add gameMap.homeRotation
    check seenRotations.deduplicate().len == 4

suite "home rotation: determinism":
  test "same seed, same assignment, twice":
    for seed in [0, 3, 17, 99, 4096]:
      check homeRotationFor(seed, 4) == homeRotationFor(seed, 4)
      let
        a = loadCtfMapMetadata(fourTeamConfig(seed, "corners"))
        b = loadCtfMapMetadata(fourTeamConfig(seed, "corners"))
      check a.homeRotation == b.homeRotation
      for team in a.teams():
        check a.homeSlot(team) == b.homeSlot(team)
        check a.teamAnchor(team) == b.teamAnchor(team)
        check a.captureZone(team) == b.captureZone(team)

  test "two identical 4-team games agree on homes and hash":
    proc runGame(): SimServer =
      result = initCtfForTest(fourTeamConfig(7, "plus"))
      for i in 0 ..< 4:
        discard result.addPlayer("p" & $i)
      result.startGame()
      let none = newSeq[InputState](0)
      for _ in 0 ..< 120:
        result.step(none, none)
    var a = runGame()
    let b = runGame()
    check a.gameMap.homeRotation == b.gameMap.homeRotation
    check a.gameHash() == b.gameHash()
    for i in 0 ..< a.players.len:
      check a.players[i].homeX == b.players[i].homeX
      check a.players[i].homeY == b.players[i].homeY

suite "home rotation: the home BUNDLE stays coherent":
  test "pedestal, zone and spawn strip all follow the SAME slot":
    ## The failure mode this guards is a HALF rotation: a team spawning at one
    ## home while its pedestal, scoring zone or strip orientation stays at
    ## another. Checked at every rotation, on both 4-team layouts.
    for layout in ["corners", "plus"]:
      var sim = initCtfForTest(fourTeamConfig(0, layout))
      for i in 0 ..< 12:
        discard sim.addPlayer("p" & $i)
      sim.startGame()
      for rotation in 0 .. 3:
        sim.gameMap = sim.gameMap.rotated(rotation)
        var homes: seq[MapPoint]
        for team in sim.teams():
          let
            slot = sim.gameMap.homeSlot(team)
            anchor = sim.gameMap.teamAnchor(team)
            zone = sim.gameMap.captureZone(team)
          homes.add anchor
          ## The anchor IS one of the board's unrotated pads.
          check anchor == sim.gameMap.slotAnchor(slot)
          ## The pedestal stands on the anchor, inside the team's OWN zone...
          check sim.gameMap.flagHome(team) == anchor
          check zone.inCaptureZone(anchor.x, anchor.y)
          ## ...and inside NOBODY else's.
          for other in sim.teams():
            if other != team:
              check not sim.gameMap.captureZone(other)
                .inCaptureZone(anchor.x, anchor.y)
          ## Every spawn-strip position is standable floor whose nearest home
          ## is this team's own.
          for order in 0 ..< 8:
            let spawn = sim.spawnPosition(team, order)
            check sim.canOccupy(spawn.x, spawn.y)
            check sim.gameMap.nearestAnchorOwner(spawn.x, spawn.y) == team
        check homes.deduplicate().len == 4

  test "the spawn strip staggers along the OCCUPIED arm":
    ## `spawnPosition` staggers perpendicular to the home axis. Keyed on team
    ## identity it would lay the west arm's strip across a north arm after a
    ## rotation; keyed on the occupied slot it never does. The tell is which
    ## axis the strip spreads along.
    var sim = initCtfForTest(fourTeamConfig(0, "plus"))
    for i in 0 ..< 4:
      discard sim.addPlayer("p" & $i)
    sim.startGame()
    for rotation in 0 .. 3:
      sim.gameMap = sim.gameMap.rotated(rotation)
      for team in sim.teams():
        let
          slot = sim.gameMap.homeSlot(team)
          first = sim.spawnPosition(team, 0)
          last = sim.spawnPosition(team, 7)
        if slot in {Red, Blue}:
          ## West / east arm: the strip runs DOWN the side (y spreads).
          check abs(last.y - first.y) > abs(last.x - first.x)
        else:
          ## North / south arm: the strip runs ACROSS the mouth (x spreads).
          check abs(last.x - first.x) > abs(last.y - first.y)

  test "spawn aim faces the center from the OCCUPIED home":
    for layout in ["corners", "plus"]:
      let base = controlMap(fourTeamConfig(0, layout))
      for rotation in 0 .. 3:
        let gameMap = base.rotated(rotation)
        for team in gameMap.teams():
          let
            anchor = gameMap.teamAnchor(team)
            aim = aimVector(gameMap.spawnAimBrads(team))
            toCenterX = float(gameMap.center.x - anchor.x)
            toCenterY = float(gameMap.center.y - anchor.y)
          ## Facing the fight: the aim vector's dot product with the vector
          ## from the home to the map center is positive at every rotation.
          check aim.x * toCenterX + aim.y * toCenterY > 0.0

suite "home rotation: what must NOT move":
  test "the protected floor is identical at every rotation":
    ## Pads never move — the terrain a rotation lands on is the SAME terrain.
    ## Sampled on a grid dense enough to cross every pocket and arm.
    for layout in ["corners", "plus"]:
      let base = controlMap(fourTeamConfig(0, layout))
      for rotation in 1 .. 3:
        let gameMap = base.rotated(rotation)
        var mismatch = 0
        var y = 0
        while y < base.height:
          var x = 0
          while x < base.width:
            if mapProtectedFloorAt(base, x, y) !=
                mapProtectedFloorAt(gameMap, x, y):
              inc mismatch
            x += 7
          y += 7
        check mismatch == 0

  test "the pad set and the pickup sets are rotation-invariant":
    for layout in ["corners", "plus"]:
      let base = controlMap(fourTeamConfig(0, layout))
      var pads: seq[MapPoint]
      for team in base.teams():
        pads.add base.slotAnchor(team)
      for rotation in 0 .. 3:
        let gameMap = base.rotated(rotation)
        ## The set of anchors is the same set, only relabelled.
        var rotatedPads: seq[MapPoint]
        for team in gameMap.teams():
          rotatedPads.add gameMap.teamAnchor(team)
        check rotatedPads.sortedByIt((it.x, it.y)) ==
          pads.sortedByIt((it.x, it.y))
        ## The pickups are authored off the UNROTATED Red seed and carried by
        ## the map's symmetry orbit, so they do not move at all.
        check gameMap.shieldSpawnPoints() == base.shieldSpawnPoints()
        check gameMap.sprayPaintSpawnPoints() == base.sprayPaintSpawnPoints()
        check gameMap.grenadeSpawnPoints() == base.grenadeSpawnPoints()

  test "room boxes stay put; room NAMES follow the owner":
    for seed in [0, 1, 2, 3]:
      let
        config = fourTeamConfig(seed, "corners")
        gameMap = loadCtfMapMetadata(config)
        base = controlMap(config)
      var boxes, baseBoxes: seq[(int, int, int, int)]
      for room in gameMap.rooms:
        boxes.add (room.x, room.y, room.w, room.h)
      for room in base.rooms:
        baseBoxes.add (room.x, room.y, room.w, room.h)
      check boxes.sorted() == baseBoxes.sorted()
      ## ...and the base room named for a team encloses THAT team's anchor.
      for team in gameMap.teams():
        let anchor = gameMap.teamAnchor(team)
        var found = false
        for room in gameMap.rooms:
          if room.name.toLowerAscii().startsWith(teamText(team)):
            found = true
            check anchor.x >= room.x and anchor.x <= room.x + room.w
            check anchor.y >= room.y and anchor.y <= room.y + room.h
        check found
