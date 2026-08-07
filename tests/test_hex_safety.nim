## THE SILENT-FAILURE NET for the hexagonal playfield.
##
## Every rule in here was written against a RECTANGLE and means something else
## on a hexagon. What makes this family dangerous is that none of them crash:
## the code compiles, the episode runs to completion, the wire stays
## well-formed, and the behaviour is simply wrong. There is no exception to
## catch and no log line to grep, so a regression here is invisible unless
## something asserts the intent — which is what this module is for.
##
## Each suite pins the MEASUREMENT that caught the bug, not a paraphrase of the
## fix, so the test stays meaningful if the implementation is rewritten. The
## numbers in the comments are the before/after from the sweep that landed
## these; see the GV41 note in `sim_types.nim`.
import
  helpers,
  std/[math, strutils, unittest],
  bitworld/spriteprotocol,
  ctf/[global, sim, hex, labels]

proc installedGame(configJson: string): SimServer =
  ## A started 2-team game on one specific map.
  var config = defaultGameConfig()
  if configJson.len > 0:
    config.update(configJson)
  result = initCtfForTest(config)
  discard result.addPlayer("red0")
  discard result.addPlayer("blue0")
  result.startGame()

proc genConfig(seed: int, size = ""): string =
  result = """{"mapPath": "gen", "mapSeed": """ & $seed
  if size.len > 0:
    result.add """, "mapSize": """" & size & """""""
  result.add "}"

const
  ## One hand-authored board, one of each parity/scale hazard, and a
  ## generated seed from the shipped pool. Kept small enough to stay inside a
  ## shard's budget while covering both a small and an oversize class.
  SafetyBoards = [
    ("arena", ""),
    ("arena-large", """{"mapPath": "arena-large"}"""),
    ("gen:7", genConfig(7)),
    ("gen:1007", genConfig(1007)),
    ("gen77:small", genConfig(77, "small")),
  ]

# ---------------------------------------------------------------------------
# 1. Grenade pickups must be REACHABLE, not merely walkable.
# ---------------------------------------------------------------------------
# The four spawns used to sit at the corners of the BOUNDING BOX at inset 50,
# which on a hexagon is deep in the void: `pickupByTouch` never fires,
# `spawn.present` stays true forever, the sprite keeps rendering, and nothing
# anywhere reports it. `grenadeSpawnPoints` now derives them from the hull's
# vertices and `walkableGrenadePoints` shrinks the ring until all four land on
# floor — but "on floor" is one PIXEL, and a pickup fires only when a player's
# CENTRE gets within GrenadePickupRange, which needs a whole footprint. This
# asserts the property that actually matters.

proc touchableFrom(sim: SimServer, spawn: PickupSpawn): bool =
  for dy in -GrenadePickupRange .. GrenadePickupRange:
    for dx in -GrenadePickupRange .. GrenadePickupRange:
      if dx * dx + dy * dy > GrenadePickupRange * GrenadePickupRange:
        continue
      if sim.canOccupy(spawn.x + dx, spawn.y + dy):
        return true
  false

suite "hex safety: grenade pickups are reachable":
  for (name, configJson) in SafetyBoards:
    test "every grenade spawn can actually be picked up on " & name:
      var sim = installedGame(configJson)
      let board = sim.gameMap.mapBoard()
      check sim.grenadeSpawns.len == 4
      for i, spawn in sim.grenadeSpawns:
        checkpoint($name & " spawn " & $i & " at " & $(spawn.x, spawn.y))
        ## On the playfield at all — the failure this whole suite exists for.
        check board.hexEdgeDist(spawn.x, spawn.y) >= float(ArenaBorder)
        check sim.isWalkable(spawn.x, spawn.y)
        ## And a body can get close enough to take it.
        check sim.touchableFrom(spawn)
        check spawn.present

  test "the four spawns are one symmetric ring, not four nudged points":
    ## `walkableGrenadePoints` shrinks the whole RING rather than nudging each
    ## point, because an independent nudge lands mirror partners on different
    ## spots — measured (780,891) against (339,890) — which hands one side a
    ## different approach to a contested pickup. The set must be closed under
    ## the board's mirror and under the half turn.
    var sim = installedGame("")
    let
      cx2 = sim.gameMap.width - 1        ## x + mirror(x) for the x mirror.
      cy2 = sim.gameMap.height - 1
    var points: seq[tuple[x, y: int]]
    for spawn in sim.grenadeSpawns:
      points.add((spawn.x, spawn.y))
    for p in points:
      check (cx2 - p.x, p.y) in points          ## mirror across the long axis
      check (p.x, cy2 - p.y) in points          ## mirror across the short axis
      check (cx2 - p.x, cy2 - p.y) in points    ## the half turn

# ---------------------------------------------------------------------------
# 2. A throw may never land off the playfield.
# ---------------------------------------------------------------------------
# `throwTarget` clamped each axis into `ArenaBorder..MapWidth - ArenaBorder`,
# a BOX 28% larger than the hull, so an aim at any of the six corners resolved
# into solid void — drawn as a legal charge ring, and still dealing blast
# damage back through the map edge because `explodeGrenade` has no
# line-of-sight test. Swept over every aim slot from a 60px grid of thrower
# positions: 19.8-20.4% of full-charge throws landed off the playfield on every
# size class before the fix, 0% after.

proc offFieldThrowRate(sim: var SimServer): tuple[bad, total: int] =
  let board = sim.gameMap.mapBoard()
  for py in countup(ArenaBorder + 40, MapHeight - ArenaBorder - 40, 60):
    for px in countup(ArenaBorder + 40, MapWidth - ArenaBorder - 40, 60):
      if board.hexEdgeDist(px, py) < float(ArenaBorder):
        continue
      for slot in 0 ..< AimRotations:
        var player = sim.players[0]
        player.x = px
        player.y = py
        player.aimBrads = slot * AimStepBrads
        player.throwCharge = GrenadeChargeTicks
        let (tx, ty) = throwTarget(player)
        inc result.total
        if board.hexEdgeDist(tx, ty) < float(ArenaBorder):
          inc result.bad

suite "hex safety: throws land on the playfield":
  for (name, configJson) in SafetyBoards:
    test "no full-charge throw lands in the border ring or the void on " & name:
      var sim = installedGame(configJson)
      let (bad, total) = sim.offFieldThrowRate()
      checkpoint(name & ": " & $bad & " of " & $total & " throws off-field")
      check total > 500      ## the sweep really ran
      check bad == 0

  test "a throw aimed at a hex corner falls SHORT along the same aim":
    ## The clamp shortens the throw; it must never veer it sideways, or the
    ## grenade goes somewhere nobody aimed.
    var sim = installedGame("")
    let board = sim.gameMap.mapBoard()
    var shortened = 0
    for slot in 0 ..< AimRotations:
      var player = sim.players[0]
      player.x = sim.gameMap.center.x
      player.y = sim.gameMap.center.y
      player.aimBrads = slot * AimStepBrads
      player.throwCharge = GrenadeChargeTicks
      let
        (ux, uy) = aimVector(player.aimBrads)
        (tx, ty) = throwTarget(player)
        reach = hypot(float(tx - player.x), float(ty - player.y))
      check board.hexEdgeDist(tx, ty) >= float(ArenaBorder)
      if reach > 0.5:
        ## Still on the aim ray: the landing is a non-negative multiple of the
        ## aim unit vector, to within the 1px rounding of the march.
        check abs(float(tx - player.x) - ux * reach) <= 1.5
        check abs(float(ty - player.y) - uy * reach) <= 1.5
      if reach < float(GrenadeMaxRange) - 1.0:
        inc shortened
    ## From the CENTRE of the standard board a full throw fits in every
    ## direction, so nothing should be shortened here; the assertion is that
    ## the clamp is not silently eating range on an open board.
    check shortened == 0

  test "the render's charge ring is the grenade's real landing point":
    ## `throwTarget` and `throwGrenade` used to hold two copies of the same
    ## arithmetic. They are one proc now; this is the guard that keeps it so.
    var sim = installedGame("")
    let
      held = @[InputState(c: true), InputState(c: true)]
      released = sim.none()
    for slot in 0 ..< AimRotations:
      sim.players[0].aimBrads = slot * AimStepBrads
      sim.players[0].hasGrenade = true
      sim.players[0].throwCharge = GrenadeChargeTicks
      sim.airborneGrenades = @[]
      ## What the render would draw this tick...
      let predicted = throwTarget(sim.players[0])
      ## ...against where the release actually sends it.
      sim.step(released, held)
      check sim.airborneGrenades.len == 1
      if sim.airborneGrenades.len == 1:
        check (sim.airborneGrenades[0].tx, sim.airborneGrenades[0].ty) ==
          predicted

# ---------------------------------------------------------------------------
# 3. Movement must not become slope-dependent at low speed.
# ---------------------------------------------------------------------------
# `slideScanRadius` floored at 1, which is a 45-degree diagonal — exactly what
# the rectangular board's walls were. A hex hull edge is 60 degrees and costs
# 1.73px perpendicular per px along it, so radius 1 cannot take the step and
# `applyMomentumAxis` zeroes the carry. The scan widens with SPEED, so a
# continuously-held d-pad escapes the regime in two ticks and the bug hides;
# a policy that PULSES its input never leaves it.

proc wedgeTravel(slope: float, duty, ticks: int): int =
  ## Travel along a wall face of the given slope, with `right` held one tick in
  ## `duty`. duty 1 is continuous input.
  var sim = initCtfForTest(defaultGameConfig())
  let p = sim.addPlayer("slider")
  sim.blockAll()
  const
    X0 = TestFieldX0
    Y0 = TestFieldY0
  for y in Y0 - 300 .. Y0 + 220:
    for x in X0 .. X0 + 400:
      if float(x - X0) * slope <= float(Y0 + 220 - y):
        sim.walkMask[mapIndex(x, y)] = true
  let sx = X0 + 20
  var sy = Y0 + 220
  while sy > Y0 - 300 and not sim.canOccupy(sx, sy):
    dec sy
  doAssert sim.canOccupy(sx, sy), "no valid start against the wedge"
  sim.placeStill(p, sx, sy)
  for tick in 0 ..< ticks:
    sim.applyInput(p, InputState(right: tick mod duty == 0))
  sim.players[p].x - sx

suite "hex safety: sliding a 60-degree wall":
  test "the slide scan floor clears a hex edge":
    ## tan(60) = 1.73, so a radius of 1 is structurally short. This is the
    ## invariant; the two constants are free to move as long as it holds.
    check MovementSlideMinScan >= 2
    check MovementSlideMaxScan >= MovementSlideMinScan

  test "a PULSING policy travels the same on a 60-degree face as on flat floor":
    ## The measurement that caught it. Before the floor: 30px on flat floor,
    ## 30px on a 45-degree face, and 1px on the 60-degree face — a 30x
    ## collapse, on exactly the geometry the hexagon introduced.
    for duty in [2, 3, 4, 6]:
      let
        flat = wedgeTravel(0.0, duty, 60)
        deg45 = wedgeTravel(1.0, duty, 60)
        deg60 = wedgeTravel(sqrt(3.0), duty, 60)
      checkpoint("duty 1-in-" & $duty & ": flat=" & $flat &
        " 45deg=" & $deg45 & " 60deg=" & $deg60)
      check flat > 0
      check deg45 == flat
      check deg60 == flat

  test "continuous input is unaffected, which is why this hid":
    for slope in [0.0, 1.0, sqrt(3.0)]:
      check wedgeTravel(slope, 1, 30) == wedgeTravel(0.0, 1, 30)

# ---------------------------------------------------------------------------
# 4. A respawn must land inside its own capture zone, on floor.
# ---------------------------------------------------------------------------
# `randomEndzonePosition` rejects on `inCaptureZone` only, then runs the
# accepted point through `nearestWalkable`, whose ring search can walk it back
# OUT of the zone. It holds today because every endzone disc is protected
# floor — but that is a property of the map generator, not of this proc, and
# nothing was checking it.

suite "hex safety: respawns land in their own endzone":
  for (name, configJson) in SafetyBoards:
    test "every endzone draw stays in the zone and on floor on " & name:
      var sim = installedGame(configJson)
      var escapes = 0
      var blocked = 0
      for team in sim.gameMap.teams():
        let zone = sim.captureZone(team)
        for _ in 0 ..< 200:
          let (x, y) = sim.randomEndzonePosition(team)
          if not zone.inCaptureZone(x, y):
            inc escapes
          if not sim.canOccupy(x, y):
            inc blocked
      checkpoint(name & ": escapes=" & $escapes & " blocked=" & $blocked)
      check escapes == 0
      check blocked == 0

  test "the capture zones are wholly walkable, which is what makes that safe":
    ## The load-bearing premise, asserted rather than assumed: if a generator
    ## change ever carves wall inside an endzone, THIS goes red and names the
    ## reason, instead of the draw quietly drifting out of the zone.
    for (name, configJson) in SafetyBoards:
      var sim = installedGame(configJson)
      for team in sim.gameMap.teams():
        let zone = sim.captureZone(team)
        var wall = 0
        for y in zone.yLo .. zone.yHi:
          for x in zone.xLo .. zone.xHi:
            if zone.inCaptureZone(x, y) and not sim.isWalkable(x, y):
              inc wall
        checkpoint(name & " " & teamText(team) & ": " & $wall & " wall px")
        check wall == 0

# ---------------------------------------------------------------------------
# 5. Ranges are keyed to the SHORT axis.
# ---------------------------------------------------------------------------
# `selectCtfMap` assigned `MapWidth div 5`, inherited from the rectangular
# board where width WAS the short axis. After the landscape flip that is the
# point-to-point diagonal, so every player got a 15.5% longer throw and a
# 15.5% louder shout as a side effect of a rendering decision. The old test
# pinned `== MapWidth div 5`, so it held the bug GREEN rather than catching it.

suite "hex safety: comms and throw ranges track the field, not the box":
  for (name, configJson) in SafetyBoards:
    test "ranges are a fifth of the SHORT axis on " & name:
      discard installedGame(configJson)
      check GrenadeMaxRange == MapHeight div 5
      check ShoutRange == MapHeight div 5
      ## The hull is always wider than it is tall (aspect 2/sqrt 3), so the two
      ## readings genuinely differ on every hex board — this is not a tautology.
      check MapWidth > MapHeight
      check GrenadeMaxRange != MapWidth div 5

# ---------------------------------------------------------------------------
# 6. The void is opaque, and that is what the fog and the BFS stand on.
# ---------------------------------------------------------------------------
# `buildFovBlocked` downsamples 8x8 px to one cell on `walls * 2 >= pixels`, so
# a cell that is 30-49% wall is TRANSPARENT. A staircased 60-degree edge can
# produce exactly such cells, and shadowcasting would then propagate past the
# boundary into the void. What rules it out is that the void is WALL, so a cell
# wholly outside the hull is 100% wall. That premise is now asserted in the map
# bake itself (any violation raises at boot); here it is checked end to end.

suite "hex safety: fog never leaks through the hull":
  for (name, configJson) in SafetyBoards:
    test "every fog cell outside the hull is opaque on " & name:
      var sim = installedGame(configJson)
      let board = sim.gameMap.mapBoard()
      var voidCells = 0
      var transparent = 0
      for cy in 0 ..< FovGridH:
        for cx in 0 ..< FovGridW:
          var anyField = false
          for py in cy * FovCellSize ..< min((cy + 1) * FovCellSize, MapHeight):
            for px in cx * FovCellSize ..< min((cx + 1) * FovCellSize, MapWidth):
              if board.insideHex(px, py):
                anyField = true
                break
            if anyField: break
          if anyField:
            continue
          inc voidCells
          if not sim.fovBlocked[fovCellIndex(cx, cy)]:
            inc transparent
      checkpoint(name & ": " & $voidCells & " void cells, " &
        $transparent & " transparent")
      check voidCells > 100        ## a hexagon really does have void corners
      check transparent == 0

  test "no floor pixel exists outside the hull or inside the border ring":
    ## The premise under BOTH the fog downsample and the connectivity BFS's
    ## "row wrap can't happen" step. The map bake raises on a violation, so
    ## reaching this line at all is most of the proof; the sweep names the
    ## pixel if it ever stops holding.
    for (name, configJson) in SafetyBoards:
      var sim = installedGame(configJson)
      var leaked = 0
      for y in 0 ..< MapHeight:
        for x in 0 ..< MapWidth:
          if sim.isWalkable(x, y) and isArenaBorderWall(x, y):
            inc leaked
      checkpoint(name & ": " & $leaked & " walkable px in the ring/void")
      check leaked == 0

# ---------------------------------------------------------------------------
# 7. The `game teams <n> map <W>x<H>` marker states the BOX.
# ---------------------------------------------------------------------------
# It is documented as "the exact map size in map pixels", which on a rectangle
# was both the coordinate space and the playable extent. The hexagon split
# those, and the marker kept the box. That is the right choice — it is the
# space every wire coordinate lives in — but it has to be SAID, because the
# walkability sprite is the only channel carrying the true shape.

suite "hex safety: the map-size marker means the bounding box":
  test "the marker states the box, and the box is not the playfield":
    var sim = installedGame("")
    let board = sim.gameMap.mapBoard()
    let label = labelGameParams(
      sim.gameMap.teamCount(), sim.gameMap.width, sim.gameMap.height)
    check label.startsWith(LabelPrefixGameParams)
    check label.endsWith($MapWidth & "x" & $MapHeight)

    ## Every wire coordinate lives in the box: that is what makes the box the
    ## right thing to publish.
    check sim.gameMap.width == MapWidth
    check sim.gameMap.height == MapHeight

    ## And the playfield is strictly smaller, on both axes and in area — which
    ## is precisely why the marker cannot be read as a playable extent.
    var playable = 0
    var minX = MapWidth
    var maxX = 0
    for y in 0 ..< MapHeight:
      for x in 0 ..< MapWidth:
        if board.hexEdgeDist(x, y) >= float(ArenaBorder):
          inc playable
          minX = min(minX, x)
          maxX = max(maxX, x)
    checkpoint("playfield " & $playable & " px of " & $(MapWidth * MapHeight) &
      ", x extent " & $minX & ".." & $maxX)
    check playable < MapWidth * MapHeight
    check maxX - minX + 1 < MapWidth
    ## A regular hexagon is 3*sqrt(3)/8 = 64.95% of its bounding box; the
    ## border ring takes a little more. Pinned as a BAND so the number stays
    ## honest without going red on a border-thickness tweak.
    let fraction = float(playable) / float(MapWidth * MapHeight)
    check fraction > 0.60
    check fraction < 0.75

  test "the walkability sprite is the channel that carries the shape":
    ## The box's corners are void, and the walkability mask says so. If this
    ## ever stops being true the marker becomes the ONLY size channel and the
    ## true shape becomes unobservable to a policy.
    var sim = installedGame("")
    for (x, y) in [(0, 0), (MapWidth - 1, 0),
                   (0, MapHeight - 1), (MapWidth - 1, MapHeight - 1)]:
      check not sim.isWalkable(x, y)
    check sim.isWalkable(MapWidth div 2, MapHeight div 2)

## Generated maps are installed as the process map above; put the arena back.
installDefaultArena()
invalidateBoardMapCaches()
