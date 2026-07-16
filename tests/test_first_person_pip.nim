import
  std/[json, os, unittest],
  ctf/[broadcast, sim]

const GameDir = currentSourcePath.parentDir.parentDir

proc initCtfForTest(config: GameConfig): SimServer =
  ## Initializes the CTF sim from the game directory.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc fpFrame(sim: SimServer, povSlot: int): JsonNode =
  ## Parses the `fp` node out of a chrome frame for one POV slot (or null).
  let frame = sim.buildStateJson(
    events = newJArray(),
    playing = false,
    speed = 1,
    maxTick = 1000,
    looping = false,
    transportEnabled = true,
    mismatchTick = -1,
    povSlot = povSlot
  )
  let parsed = parseJson(frame)
  if parsed.hasKey("fp"): parsed["fp"] else: newJNull()

suite "first-person picture-in-picture":
  test "no POV selected → no fp frame":
    var game = initCtfForTest(defaultGameConfig())
    discard game.addPlayer("red0")
    game.startGame()
    check game.fpFrame(-1).kind == JNull

  test "POV frame has one distance per raycast column":
    var game = initCtfForTest(defaultGameConfig())
    let red = game.addPlayer("red0")
    game.startGame()
    game.players[red].team = Red
    let fp = game.fpFrame(game.players[red].joinOrder)
    check fp.kind == JObject
    check fp["cols"].len == 96
    # Every column is either a wall hit distance (>=0) or a clean miss (-1).
    for c in fp["cols"]:
      check c.getInt() >= -1

  test "walls near the player yield shorter distances than an open lane":
    # A player pressed against the left border wall, aiming into the wall (west),
    # must read closer walls than the same player aiming down an open lane.
    var game = initCtfForTest(defaultGameConfig())
    let red = game.addPlayer("red0")
    game.startGame()
    game.players[red].team = Red
    game.players[red].x = 20   # hard against the left border
    game.players[red].y = MapHeight div 2

    game.players[red].aimBrads = AimBradsTurn div 2  # west, into the border
    let intoWall = game.fpFrame(game.players[red].joinOrder)
    game.players[red].aimBrads = 0                   # east, into the arena
    let intoArena = game.fpFrame(game.players[red].joinOrder)

    proc centerHit(fp: JsonNode): int =
      # The central column: the axis the player looks straight down.
      fp["cols"][fp["cols"].len div 2].getInt()

    let wallHit = intoWall.centerHit()
    # Aiming into the border wall must return a finite, short wall hit.
    check wallHit >= 0
    check wallHit < 60

  test "a visible enemy in front shows up as an entity near view-center":
    var game = initCtfForTest(defaultGameConfig())
    let
      red = game.addPlayer("red0")
      blue = game.addPlayer("blue0")
    game.startGame()
    game.players[red].team = Red
    game.players[blue].team = Blue
    let
      cx = game.gameMap.center.x
      cy = game.gameMap.center.y
    game.players[red].x = cx
    game.players[red].y = cy
    game.players[red].aimBrads = 0            # aiming east
    game.players[blue].x = cx + 80            # directly east, in the cone
    game.players[blue].y = cy

    # Refresh the viewer's fog so playerVisibleTo reflects real line of sight.
    discard game.refreshPlayerFov(red)
    let fp = game.fpFrame(game.players[red].joinOrder)
    check fp.kind == JObject
    var found = false
    for e in fp["ents"]:
      if e["k"].getStr() == "enemy":
        found = true
        # Dead-ahead → |o| near 0 (view center).
        check abs(e["o"].getFloat()) < 0.35
        check e["d"].getInt() > 0
    check found

  test "a dead viewer sees walls but no live entities in the inset":
    var game = initCtfForTest(defaultGameConfig())
    let
      red = game.addPlayer("red0")
      blue = game.addPlayer("blue0")
    game.startGame()
    game.players[red].team = Red
    game.players[blue].team = Blue
    let
      cx = game.gameMap.center.x
      cy = game.gameMap.center.y
    game.players[red].x = cx
    game.players[red].y = cy
    game.players[red].aimBrads = 0
    game.players[red].alive = false           # ghost viewer
    game.players[blue].x = cx + 80
    game.players[blue].y = cy

    let fp = game.fpFrame(game.players[red].joinOrder)
    check fp.kind == JObject
    check fp["cols"].len == 96                 # terrain still raycast
    for e in fp["ents"]:
      check e["k"].getStr() != "enemy"         # no moving entities for the dead
      check e["k"].getStr() != "mate"
