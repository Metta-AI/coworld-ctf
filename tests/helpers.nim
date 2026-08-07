## Shared test helpers. These used to be copy-pasted per test module; the
## bodies here are byte-for-byte the common variants, so migrating a test onto
## this module must not change the game state it constructs.
##
## Tests run from the repo root (see AGENTS.md), but sim construction and
## sprite-packet building lazily load `data/` assets relative to the cwd — so
## the builders here pin the cwd to the game directory for the duration of the
## call, exactly like every local copy did.

import
  std/os,
  bitworld/spriteprotocol,
  ctf/[global, sim]

const GameDir* = currentSourcePath.parentDir.parentDir

proc initCtfForTest*(config = defaultGameConfig()): SimServer =
  ## Initializes the CTF sim from the game directory (so data/ resolves).
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc twoTeamGame*(collectEvents = false): SimServer =
  ## A started game with one Red player (0) and one Blue player (1). Pass
  ## `collectEvents = true` to turn the tier-2 event sink on.
  result = initCtfForTest(defaultGameConfig())
  discard result.addPlayer("red0")
  discard result.addPlayer("blue0")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Blue
  result.collectEvents = collectEvents

proc namedGame*(seats: int): SimServer =
  ## `seats` players whose addresses are unmistakable inside a label and share
  ## no substring with the team colors or the slot letters. Seats alternate
  ## Red, Blue, Red, Blue... by slot order, as teamForSlot assigns them.
  result = initCtfForTest(defaultGameConfig())
  for i in 0 ..< seats:
    discard result.addPlayer("policy" & $i)
  result.startGame()

proc none*(sim: SimServer): seq[InputState] =
  ## An all-idle input frame sized to the roster.
  newSeq[InputState](sim.players.len)

proc hexTeamMap*(cls = hxStandard): CtfMap =
  ## The hand-authored 4-TEAM hexagon: bare field, Klein-four symmetry, one
  ## endzone disc per team.
  ##
  ## This USED to build the board here, field by field. It no longer does: the
  ## same geometry now ships as the NAMED `arena-hex4` / `arena-hex4-giant`
  ## maps, because the two live 4-team league variants need a board the engine
  ## will resolve by name and a `mapSpec` blob pasted into a manifest is
  ## geometry owned by data. Keeping a second copy here would be exactly the
  ## reimplementation `AGENTS.md` warns about — the map code's fairness
  ## invariants fail SILENTLY as team unfairness when restated elsewhere — so
  ## the tests now run on the board production runs on.
  ##
  ## Hex Stage 2 GENERATES 2-team boards only (`generateMapAttempt` raises for
  ## every other count — the cube-space orbit rasterizer is Stage 2b), so the
  ## old `mapPath: "gen"` + `mapLayout: "corners"/"plus"` fixtures cannot
  ## exist. This one the engine genuinely accepts: `validateMap` passes it,
  ## `teamAnchor` / `teamImagePoint` / `captureZone` all resolve it, and it
  ## rides the same `mapSpec` channel a replay pins its geometry through.
  ##
  ## Round-tripped through the spec so the value equals its own spec exactly.
  mapFromSpecJson(mapSpecJson(arenaHex4CtfMap(
    (if cls == hxGiant: "arena-hex4-giant" else: "arena-hex4"), cls)))

proc fourTeamSpecJson*(gameMap = hexTeamMap()): string =
  ## The `mapSpec` config fragment that pins a 4-team hex board.
  """{"teams": 4, "mapSpec": """ & mapSpecJson(gameMap) & "}"

var bareHexMapCache: CtfMap

proc bareHexMap*(): CtfMap =
  ## The standard arena's HEXAGON with its terrain removed: a real, validating
  ## 2-team map whose only walls are the hull and its border ring.
  ##
  ## Vision, jitter and hit-geometry tests want a long clear sightline in a
  ## known direction. On the rectangular board they got one by naming a
  ## corridor between two hand-authored obstacle columns; a hexagon's corridors
  ## are shorter (the widest fully clear band on the arena is 501 px) and, more
  ## to the point, they move whenever `arenaHexObstacles` is re-tuned, which
  ## made those tests assert the arena's furniture rather than the mechanic
  ## under test. The bare hull is the same geometry with the furniture removed:
  ## from its center every direction is open to the border — 474 px east and
  ## west, 547 px north and south — and the numbers depend only on the size
  ## class. Terrain-dependent behaviour (glass, cover, shadowcasting past a
  ## stub) stays on the real arena, in the tests that are about terrain.
  if bareHexMapCache.width == 0:
    var m = mapFromSpecJson(mapSpecJson(loadCtfMapMetadata("")))
    m.name = "bare-hex"
    m.leftObstacles = @[]
    m.trenches = @[]
    bareHexMapCache = mapFromSpecJson(mapSpecJson(m))
  bareHexMapCache

proc coverHexMap*(obstacles: seq[ArenaShape]): CtfMap =
  ## The bare hexagon plus a hand-placed LEFT-HALF obstacle set: a controlled
  ## cover scene. `buildArenaObstacles` mirrors the set onto the right half, as
  ## it does for any authored map, so the board stays team-fair.
  var m = bareHexMap()
  m.name = "cover-hex"
  m.leftObstacles = obstacles
  mapFromSpecJson(mapSpecJson(m))

proc coverHexConfig*(obstacles: seq[ArenaShape]): GameConfig =
  result = defaultGameConfig()
  result.update(
    """{"mapSpec": """ & mapSpecJson(coverHexMap(obstacles)) & "}")

proc bareHexConfig*(extraJson = ""): GameConfig =
  ## `defaultGameConfig` with the bare hexagon pinned as the map. `extraJson`
  ## carries any extra config keys, e.g. `"\"gunRange\": 200"`.
  result = defaultGameConfig()
  var json = """{"mapSpec": """ & mapSpecJson(bareHexMap())
  if extraJson.len > 0:
    json.add ", " & extraJson
  json.add "}"
  result.update(json)

proc bareTwoTeamGame*(collectEvents = false): SimServer =
  ## `twoTeamGame` on the BARE hexagon (see `bareHexMap`). The combat and FX
  ## tests need the two bodies to face each other at a chosen separation with a
  ## clear sightline; the fixed pair of coordinates that used to provide one on
  ## the rectangular arena is inside a wall on the hexagon, and any replacement
  ## would pin the mechanic under test to the arena's furniture.
  result = initCtfForTest(bareHexConfig())
  discard result.addPlayer("red0")
  discard result.addPlayer("blue0")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Blue
  result.collectEvents = collectEvents

proc faceOff*(sim: var SimServer, shooter, target, gap: int) =
  ## Stands two players `gap` px apart on the board's center row, the shooter
  ## to the WEST aiming due east. The center row is the hexagon's widest, so on
  ## a bare hull the pair has open floor for the full half-width either way.
  let
    cx = sim.gameMap.center.x
    cy = sim.gameMap.center.y
  sim.players[shooter].x = cx - gap div 2
  sim.players[shooter].y = cy
  sim.players[shooter].aimBrads = 0
  sim.players[target].x = cx - gap div 2 + gap
  sim.players[target].y = cy

proc chargeAndThrow*(sim: var SimServer, playerIndex, holdTicks: int) =
  ## Holds C for holdTicks then releases.
  var held = sim.none()
  held[playerIndex].c = true
  var prev = sim.none()
  for _ in 0 ..< holdTicks:
    sim.step(held, prev)
    prev = held
  sim.step(sim.none(), prev)

proc armToFire*(game: var SimServer, shooter: int) =
  ## Clears the gates so the shooter's next tryFire releases this tick.
  game.players[shooter].windupBrads = -1
  game.players[shooter].fireCooldown = 0

proc placeAtCenter*(player: var Player, x, y: int) =
  ## Centers a player's collision box on a map point.
  player.x = x - CollisionW div 2
  player.y = y - CollisionH div 2

proc segmentBlocked*(sim: SimServer, ax, ay, bx, by: int): bool =
  ## Returns true when a wall pixel blocks the straight segment between two
  ## map points (same stepping as the sim's line-of-sight routine).
  ##
  ## `sim.isWall` reports every off-board pixel as wall, and on the HEXAGONAL
  ## arena the six corners of the bounding box are permanent void that reads as
  ## wall too — so a segment whose endpoints sit outside the hull is blocked for
  ## a reason that has nothing to do with terrain. `openSightline` below is the
  ## guard that keeps a sightline test from passing (or failing) on the void.
  let
    dx = bx - ax
    dy = by - ay
    steps = max(abs(dx), abs(dy))
  for s in 1 .. steps:
    if sim.isWall(ax + dx * s div steps, ay + dy * s div steps):
      return true
  false

proc onPlayfield*(x, y: int): bool =
  ## Whether a map point is on the installed arena's FLOOR SIDE of the boundary:
  ## inside the hexagon and clear of the border ring. Everything else — the ring
  ## and the six void corners of the bounding box — is wall by construction, so
  ## a terrain assertion aimed there measures the hull, not the map.
  not isArenaBorderWall(x, y)

proc onPlayfield*(sim: SimServer, x, y: int): bool =
  onPlayfield(x, y)

proc fovAt*(sim: SimServer, visible: seq[bool], x, y: int): bool =
  ## Reads one map point from a computed visibility grid.
  ##
  ## `fovCellAt` CLAMPS an off-board point to the nearest cell rather than
  ## failing, which would quietly answer a different question: the hexagonal
  ## board is 969 px wide where the square one was 1235, so every stale x in
  ## between used to name real floor and now names nothing. Fail loudly instead.
  doAssert x >= 0 and x < MapWidth and y >= 0 and y < MapHeight,
    "fovAt point " & $(x, y) & " is off the map " & $(MapWidth, MapHeight)
  let (cx, cy) = fovCellAt(x, y)
  visible[fovCellIndex(cx, cy)]

proc blockAll*(sim: var SimServer) =
  ## Marks all map cells blocked for movement tests.
  for i in 0 ..< sim.walkMask.len:
    sim.walkMask[i] = false

const
  ## Where the synthetic-mask movement tests lay their open floor. The
  ## HEXAGONAL arena has no floor in the corners of its bounding box, so the
  ## old top-left rectangles (x, y from 40) now name permanent void. This
  ## origin sits on the widest band of the hull — the full row through the
  ## board's center — which is the hex equivalent of "anywhere on the board".
  TestFieldX0* = 180
  TestFieldY0* = 460

proc openField*(sim: var SimServer, x0, y0, x1, y1: int) =
  ## Opens a rectangular block of walkable floor.
  ##
  ## The rect must lie wholly on the PLAYFIELD. Two things go silently wrong
  ## otherwise, and both arrived with the hexagon: `mapIndex` has no row guard,
  ## so an `x` at or past `MapWidth` (now 969, down from the square board's
  ## 1235) wraps into the NEXT row and opens floor somewhere else entirely; and
  ## a rect in a bounding-box corner opens floor in the void, where the game can
  ## never put a player. The hull is convex, so checking the four corners of the
  ## rect proves the whole rect.
  doAssert x0 <= x1 and y0 <= y1, "openField rect is inside out"
  doAssert x0 >= 0 and y0 >= 0 and x1 < MapWidth and y1 < MapHeight,
    "openField rect leaves the map: " & $(x0, y0, x1, y1) &
    " on " & $(MapWidth, MapHeight)
  for (cx, cy) in [(x0, y0), (x1, y0), (x0, y1), (x1, y1)]:
    doAssert onPlayfield(cx, cy),
      "openField corner " & $(cx, cy) & " is off the hexagonal playfield" &
      " (border ring or void); anchor the rect at TestFieldX0/TestFieldY0"
  for y in y0 .. y1:
    for x in x0 .. x1:
      sim.walkMask[mapIndex(x, y)] = true

proc placeStill*(sim: var SimServer, index, x, y: int) =
  ## Pins a player at a point with all motion state zeroed.
  sim.players[index].x = x
  sim.players[index].y = y
  sim.players[index].velX = 0
  sim.players[index].velY = 0
  sim.players[index].carryX = 0
  sim.players[index].carryY = 0

proc hasObject*(messages: openArray[SpritePacketMessage], objectId: int): bool =
  ## True when a sprite packet places the given object id.
  for message in messages:
    if message.kind == spkObject and message.objectDef.id == objectId:
      return true

proc buildGlobalMessages*(
  sim: var SimServer,
  state: var GlobalViewerState
): seq[SpritePacketMessage] =
  ## Builds and parses one global viewer sprite packet. Renders from the game
  ## directory so lazily-loaded sprite PNGs (hearts, shields) resolve.
  var nextState: GlobalViewerState
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = sim.buildSpriteProtocolUpdates(state, nextState).parseSpritePacket()
  finally:
    setCurrentDir(previousDir)
  state = nextState

proc buildPlayerMessages*(
  sim: var SimServer,
  playerIndex: int,
  state: var PlayerViewerState
): seq[SpritePacketMessage] =
  ## Builds and parses one sprite player packet, from the game directory.
  var nextState: PlayerViewerState
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = sim.buildSpriteProtocolPlayerUpdates(
      playerIndex, state, nextState).parseSpritePacket()
  finally:
    setCurrentDir(previousDir)
  state = nextState

proc playerMessages*(
  sim: var SimServer,
  playerIndex: int
): seq[SpritePacketMessage] =
  ## One player packet from throwaway viewer state (no state carried).
  var state, nextState: PlayerViewerState
  sim.buildSpriteProtocolPlayerUpdates(playerIndex, state, nextState)
    .parseSpritePacket()
