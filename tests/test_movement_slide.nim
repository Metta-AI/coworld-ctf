import
  std/[os, unittest],
  bitworld/spriteprotocol,
  ctf/sim

const GameDir = currentSourcePath.parentDir.parentDir

proc initCtfForTest(config: GameConfig): SimServer =
  ## Initializes the CTF sim from the game directory.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc blockAll(sim: var SimServer) =
  ## Marks all map cells blocked for movement tests.
  for i in 0 ..< sim.walkMask.len:
    sim.walkMask[i] = false

proc openField(sim: var SimServer, x0, y0, x1, y1: int) =
  ## Opens a rectangular block of walkable floor.
  for y in y0 .. y1:
    for x in x0 .. x1:
      sim.walkMask[mapIndex(x, y)] = true

proc placeStill(sim: var SimServer, index, x, y: int) =
  sim.players[index].x = x
  sim.players[index].y = y
  sim.players[index].velX = 0
  sim.players[index].velY = 0
  sim.players[index].carryX = 0
  sim.players[index].carryY = 0

suite "movement footprint":
  test "moves across open floor toward input":
    var sim = initCtfForTest(defaultGameConfig())
    let p = sim.addPlayer("mover")
    sim.blockAll()
    sim.openField(40, 40, 240, 240)
    sim.placeStill(p, 100, 100)
    for _ in 0 .. 20:
      sim.applyInput(p, InputState(right: true))
    check sim.players[p].x > 100          # accelerated to the right
    check sim.players[p].y == 100          # no vertical drift

  test "solid footprint cannot overlap a wall":
    var sim = initCtfForTest(defaultGameConfig())
    let p = sim.addPlayer("bumper")
    sim.blockAll()
    sim.openField(40, 40, 240, 240)
    # Wall column starting at x = 150.
    for y in 40 .. 240:
      for x in 150 .. 240:
        sim.walkMask[mapIndex(x, y)] = false
    sim.placeStill(p, 100, 100)
    for _ in 0 .. 80:
      sim.applyInput(p, InputState(right: true))
    check sim.players[p].x > 100                    # advanced toward the wall
    check sim.players[p].x + PlayerHalf < 150        # but never entered it
