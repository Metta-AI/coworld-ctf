import
  std/[os, unittest],
  ctf/sim

const GameDir = currentSourcePath.parentDir.parentDir

proc initCtfForTest(): SimServer =
  ## Initializes the CTF sim from the game directory (so data/ resolves).
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(defaultGameConfig())
  finally:
    setCurrentDir(previousDir)

proc fovAt(sim: SimServer, visible: seq[bool], x, y: int): bool =
  ## Reads one map point from a computed visibility grid.
  let (cx, cy) = fovCellAt(x, y)
  visible[fovCellIndex(cx, cy)]

suite "fog-of-war vision":
  let sim = initCtfForTest()
  let
    cx = sim.gameMap.center.x   # 617: the vertical strip 596..638 is open.
    cy = sim.gameMap.center.y   # 329

  test "cone membership: ahead is visible, behind and sideways are not":
    var visible: seq[bool]
    # Facing straight up the open center corridor.
    sim.computeFovVisible(cx div FovCellSize, cy div FovCellSize, 0, -1, visible)
    check sim.fovAt(visible, cx, 100)          # far ahead, in the cone.
    check not sim.fovAt(visible, cx, 550)      # behind, beyond the bubble.
    check not sim.fovAt(visible, 100, cy)      # 90 degrees off, beyond bubble.

  test "the 45-degree cone edge follows the facing":
    var visible: seq[bool]
    # Facing diagonally up-right: cells up the open center corridor just
    # inside the 45-degree edge stay visible, just outside it fog over.
    sim.computeFovVisible(cx div FovCellSize, cy div FovCellSize, 1, -1, visible)
    check sim.fovAt(visible, 630, 100)         # ~43 degrees off the facing.
    check not sim.fovAt(visible, 610, 100)     # ~47 degrees off the facing.

  test "vision bubble: close cells are visible regardless of facing":
    var visible: seq[bool]
    sim.computeFovVisible(cx div FovCellSize, cy div FovCellSize, 0, -1, visible)
    check sim.fovAt(visible, cx, cy + 40)      # behind but inside the bubble.
    check sim.fovAt(visible, cx - 60, cy)      # sideways, inside the bubble.
    check sim.fovAt(visible, cx, cy)           # own cell.

  test "walls block the cone":
    # The chevron wall pair straddles the midline near x=479..506; facing
    # left from the center, the lane past it is occluded.
    var visible: seq[bool]
    sim.computeFovVisible(cx div FovCellSize, cy div FovCellSize, -1, 0, visible)
    check sim.fovAt(visible, 540, cy)          # before the wall: clear.
    check not sim.fovAt(visible, 440, cy)      # behind the wall: fogged.

  test "unlimited range down an open lane":
    var visible: seq[bool]
    # Facing down the open center corridor: the far border is ~319px away,
    # well past the bubble, still visible.
    sim.computeFovVisible(cx div FovCellSize, cy div FovCellSize, 0, 1, visible)
    check sim.fovAt(visible, cx, MapHeight - 20)

  test "enemies are culled when fogged, teammates never are":
    var game = initCtfForTest()
    discard game.addPlayer("red0")
    discard game.addPlayer("blue0")
    discard game.addPlayer("red1")
    game.startGame()
    game.players[0].team = Red
    game.players[1].team = Blue
    game.players[2].team = Red
    # Viewer red0 stands at the center facing up the open corridor.
    game.players[0].x = cx
    game.players[0].y = cy
    game.players[0].facingDx = 0
    game.players[0].facingDy = -1
    # Enemy ahead in the cone: visible.
    game.players[1].x = cx
    game.players[1].y = 100
    discard game.refreshPlayerFov(0)
    check game.playerVisibleTo(0, 1)
    # Enemy behind, beyond the bubble: fogged.
    game.players[1].y = 550
    check not game.playerVisibleTo(0, 1)
    # A teammate at the same fogged spot is always visible (team radio).
    game.players[2].x = cx
    game.players[2].y = 550
    check game.playerVisibleTo(0, 2)
    # And the viewer always sees itself.
    check game.playerVisibleTo(0, 0)

  test "pedestal flags are always visible; carried flags follow the carrier":
    var game = initCtfForTest()
    discard game.addPlayer("red0")
    discard game.addPlayer("blue0")
    game.startGame()
    game.players[0].team = Red
    game.players[1].team = Blue
    game.players[0].x = cx
    game.players[0].y = cy
    game.players[0].facingDx = 0
    game.players[0].facingDy = -1
    discard game.refreshPlayerFov(0)
    # Both pedestals sit far outside the up-facing cone yet stay visible.
    check game.flagVisibleTo(0, Red)
    check game.flagVisibleTo(0, Blue)
    # The enemy steals the red flag and runs behind the viewer: fogged.
    game.players[1].x = cx
    game.players[1].y = 550
    game.flags[Red].carrier = 1
    game.players[1].carryingFlag = true
    check not game.flagVisibleTo(0, Red)
    # The same carrier ahead in the cone: visible again.
    game.players[1].y = 100
    check game.flagVisibleTo(0, Red)

  test "dead viewers see everything":
    var game = initCtfForTest()
    discard game.addPlayer("red0")
    discard game.addPlayer("blue0")
    game.startGame()
    game.players[0].team = Red
    game.players[1].team = Blue
    game.players[0].x = cx
    game.players[0].y = cy
    game.players[0].facingDx = 0
    game.players[0].facingDy = -1
    game.players[0].alive = false
    game.players[1].x = cx
    game.players[1].y = 550
    check game.playerVisibleTo(0, 1)
