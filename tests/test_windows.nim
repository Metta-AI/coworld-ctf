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

proc armToFire(game: var SimServer, shooter: int) =
  ## Clears the gates so the shooter's next tryFire releases this tick.
  game.players[shooter].windupBrads = -1
  game.players[shooter].fireCooldown = 0
  game.players[shooter].spawnProtect = 0

proc segmentBlocked(sim: SimServer, ax, ay, bx, by: int): bool =
  ## Returns true when a wall pixel blocks the straight segment between two
  ## map points (same stepping as the sim's line-of-sight routine).
  let
    dx = bx - ax
    dy = by - ay
    steps = max(abs(dx), abs(dy))
  for s in 1 .. steps:
    if sim.isWall(ax + dx * s div steps, ay + dy * s div steps):
      return true
  false

proc fovAt(sim: SimServer, visible: seq[bool], x, y: int): bool =
  ## Reads one map point from a computed visibility grid.
  let (cx, cy) = fovCellAt(x, y)
  visible[fovCellIndex(cx, cy)]

## The column-3 discs (x=421 and its x-mirror) are glass windows: they stay
## walls for movement, bullets, and sword line-of-sight, but fog-of-war
## shadowcasting sees straight through them. The scene used throughout:
## a west-side spot at (375, 258), the window disc at (421, 258) r=28
## (x 393..449), and an east-side spot at (500, 258) — the straight line
## between the spots crosses only the window.
const
  WestX = 375
  EastX = 500
  RowY = 258
  WindowCx = 421
  WindowMirrorCx = MapWidth - 1 - WindowCx
  StoneDiamondCx = 349        # column-2 diamond at (349, 282): stays opaque.
  StoneDiamondCy = 282

suite "windows: glass blocks movement and shots but not vision":
  let sim = initCtfForTest()

  test "the test scene is laid out as documented":
    check sim.canOccupy(WestX, RowY)
    check sim.canOccupy(EastX, RowY)
    check sim.isWall(WindowCx, RowY)
    check sim.segmentBlocked(WestX, RowY, EastX, RowY)

  test "windows block movement exactly like stone":
    check not sim.canOccupy(WindowCx, RowY)
    check not sim.canOccupy(WindowMirrorCx, RowY)
    check not sim.isWalkable(WindowCx, RowY)

  test "windows stay in the wall mask, but leave the fog occlusion grid":
    check sim.wallMask[mapIndex(WindowCx, RowY)]
    let (wcx, wcy) = fovCellAt(WindowCx, RowY)
    check not sim.fovBlocked[fovCellIndex(wcx, wcy)]
    # The mirrored disc is glass too.
    check sim.wallMask[mapIndex(WindowMirrorCx, RowY)]
    let (mcx, mcy) = fovCellAt(WindowMirrorCx, RowY)
    check not sim.fovBlocked[fovCellIndex(mcx, mcy)]
    # Stone still occludes: the column-2 diamond's center cell is opaque.
    let (scx, scy) = fovCellAt(StoneDiamondCx, StoneDiamondCy)
    check sim.fovBlocked[fovCellIndex(scx, scy)]

  test "vision passes through a window":
    var visible: seq[bool]
    # Viewer west of the disc aiming due east (0 brads): the spot behind the
    # glass is inside the forward cone and no longer fogged.
    let (vcx, vcy) = fovCellAt(WestX, RowY)
    sim.computeFovVisible(vcx, vcy, 0, visible)
    check sim.fovAt(visible, EastX, RowY)

  test "stone still blocks vision from the same viewpoint":
    var visible: seq[bool]
    # Same viewer aiming due west (128 brads): the lane behind the column-2
    # stone diamond stays fogged.
    let (vcx, vcy) = fovCellAt(WestX, RowY)
    sim.computeFovVisible(vcx, vcy, 128, visible)
    check not sim.fovAt(visible, 300, RowY)

  test "a player seen through glass cannot be shot through it":
    var game = initCtfForTest()
    let
      shooter = game.addPlayer("red0")
      target = game.addPlayer("blue0")
    game.startGame()
    game.players[shooter].team = Red
    game.players[target].team = Blue
    game.players[shooter].x = WestX
    game.players[shooter].y = RowY
    game.players[shooter].aimBrads = 0          # due east, straight at the glass.
    game.players[target].x = EastX
    game.players[target].y = RowY
    game.players[target].spawnProtect = 0
    game.armToFire(shooter)
    # Seen: the enemy behind the window is visible through the glass.
    discard game.refreshPlayerFov(shooter)
    check game.playerVisibleTo(shooter, target)
    # Not shot: the bullet stops at the glass — a miss, no damage.
    let hpBefore = game.players[target].hp
    game.tryFire(shooter)
    check game.players[shooter].shotsFired == 1
    check game.players[shooter].shotsHit == 0
    check game.players[target].hp == hpBefore
    # The tracer visibly ends at the window, not at the target.
    check game.recentShots.len > 0
    let tracer = game.recentShots[^1]
    check tracer.x1 < WindowCx - 20             # stopped at the west face.
    check tracer.x1 > WestX
