import
  helpers,
  std/unittest,
  ctf/sim

## Glass on the hexagonal arena: it blocks movement, bullets and spray-cone
## line-of-sight exactly like stone, but fog-of-war shadowcasting sees straight
## through it.
##
## The GV16 midline bracket carries the glass. Its only pane on RowY is the
## glass one (x 421..432 in the left half, and its x-mirror), with the bracket's
## stone bar directly above it — so one row picks the glass and a row 21px up
## picks stone at the same x, which is the whole contrast this file needs. The
## scene: a west spot at (414, RowY), the pane at x 421..432, and an east spot
## at (439, RowY); the straight line between the spots crosses only the glass.
##
## Every coordinate moved with the LANDSCAPE flip: the bracket is placed at
## `cx - flagRing - 68` and the centre is now (559, 484) rather than (484, 559),
## so both the column and the row changed. They were re-measured off the
## installed arena, not re-derived by hand.
##
## RowY IS NO LONGER THE CENTRE ROW. The pane spans y 467..502, but from y 484
## downward the floor east of the pane runs into the centre feature, so a
## straight line there would cross stone as well as glass and the contrast this
## file exists to test would be contaminated — silently, as a "glass blocks
## shots" pass that stone was really producing. 475 is the middle of the clean
## band (467..483), where the only thing between the two spots is the glass.
const
  WindowCx = 426              # the glass pane's center column (421..432).
  RowY = 475                  # inside the pane, in the clean band.
  WestX = 414
  EastX = 439
  StoneRowY = 460             # the bracket's stone bar (y 431..466): stays stone.
    # 460, not 454. The stone bar itself is unmoved — `bx` and `cy` are what
    # place it and neither changed — but the six-family sightline repair now
    # puts a plug just WEST of the bracket, and at 454 that plug clipped the
    # west spot's 13px footprint. 456 down is clear floor from x 405 to the
    # bar; 460 sits in the middle of that band. Re-derived from the installed
    # arena with `hex_cover_probe pixels arena 405 428 55 80`, not guessed.
# A template, not a `let`: MapWidth is a process `var`, and in a combined
# test binary an earlier module may leave a different map installed at this
# module's import time — read the width after this suite installs the arena.
template WindowMirrorCx(): int = MapWidth - 1 - WindowCx
const
  StoneDiamondCx = 525        # a spinning center diamond: stays opaque.
  StoneDiamondCy = 338

suite "windows: glass blocks movement and shots but not vision":
  let sim = initCtfForTest()

  test "the test scene is laid out as documented":
    check sim.canOccupy(WestX, RowY)
    check sim.canOccupy(EastX, RowY)
    check sim.isWall(WindowCx, RowY)
    check sim.segmentBlocked(WestX, RowY, EastX, RowY)
    # The same two spots one bar up are floor, with STONE between them.
    check sim.canOccupy(WestX, StoneRowY)
    check sim.canOccupy(EastX, StoneRowY)
    check sim.isWall(WindowCx, StoneRowY)
    check not isArenaWindowPixel(
      WindowCx, StoneRowY, sim.gameMap.center.x, sim.gameMap.center.y)

  test "windows block movement exactly like stone":
    check not sim.canOccupy(WindowCx, RowY)
    check not sim.canOccupy(WindowMirrorCx, RowY)
    check not sim.isWalkable(WindowCx, RowY)

  test "windows stay in the wall mask, but leave the fog occlusion grid":
    check sim.wallMask[mapIndex(WindowCx, RowY)]
    let (wcx, wcy) = fovCellAt(WindowCx, RowY)
    check not sim.fovBlocked[fovCellIndex(wcx, wcy)]
    # The mirrored pane is glass too.
    check sim.wallMask[mapIndex(WindowMirrorCx, RowY)]
    let (mcx, mcy) = fovCellAt(WindowMirrorCx, RowY)
    check not sim.fovBlocked[fovCellIndex(mcx, mcy)]
    # Stone still occludes: a spinning diamond's center cell is opaque.
    let (scx, scy) = fovCellAt(StoneDiamondCx, StoneDiamondCy)
    check sim.fovBlocked[fovCellIndex(scx, scy)]

  test "vision passes through a window":
    var visible: seq[bool]
    # Viewer east of the pane aiming due west (128 brads): the spot behind the
    # glass is inside the forward cone and no longer fogged.
    let (vcx, vcy) = fovCellAt(EastX, RowY)
    sim.computeFovVisible(vcx, vcy, 128, visible)
    check sim.fovAt(visible, WestX, RowY)

  test "stone still blocks vision from the same viewpoint":
    var visible: seq[bool]
    # The same scene one bar up: the bracket's stone stays stone, so a viewer
    # east of it aiming due west cannot see the west-side spot behind it.
    check sim.canOccupy(WestX, StoneRowY)
    check sim.canOccupy(EastX, StoneRowY)
    let (vcx, vcy) = fovCellAt(EastX, StoneRowY)
    sim.computeFovVisible(vcx, vcy, 128, visible)
    check not sim.fovAt(visible, WestX, StoneRowY)

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
    check tracer.x1 < 421                       # stopped at the west face.
    check tracer.x1 > WestX
