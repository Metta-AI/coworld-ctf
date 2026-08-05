## Fog-of-war vision.
##
## The cone, the bubble and the range cap are properties of the SHADOWCASTER,
## not of the arena's furniture, so they run on the BARE hexagon
## (`helpers.bareHexMap`): the same hull, the same size class, no obstacles, so
## every direction from the center is open to the border and the numbers do not
## move when `arenaHexObstacles` is re-tuned. The one test that IS about terrain
## — glass passes vision, stone does not — runs on the real arena, against the
## GV16 midline bracket.
import
  helpers,
  std/unittest,
  bitworld/spriteprotocol,
  ctf/sim

const
  ## Clearances from the bare hexagon's center (484, 559) on the standard
  ## class: 474 px to the east and west edges, 547 px to the two vertices.
  Ahead = 359      ## north of center, well past the 90px bubble.
  Behind = 341     ## south of center, likewise.
  Sideways = 284   ## due west of center.

suite "fog-of-war vision":
  var sim = initCtfForTest(bareHexConfig())
  let
    cx = sim.gameMap.center.x   # 484 on the standard hexagon
    cy = sim.gameMap.center.y   # 559

  test "the bare hull really is open in every direction":
    ## The scene, asserted rather than assumed: everything below reads a cell
    ## whose sightline from the center crosses no wall.
    for (x, y) in [(cx, cy - Ahead), (cx, cy + Behind), (cx - Sideways, cy),
                   (cx + Sideways, cy), (cx, MapHeight - 20)]:
      check not sim.isWall(x, y)
      check not sim.segmentBlocked(cx, cy, x, y)

  test "cone membership: ahead is visible, behind and sideways are not":
    var visible: seq[bool]
    # Aiming north (64 brads).
    sim.computeFovVisible(cx div FovCellSize, cy div FovCellSize, 64, visible)
    check sim.fovAt(visible, cx, cy - Ahead)      # far ahead, in the cone.
    check not sim.fovAt(visible, cx, cy + Behind) # behind, beyond the bubble.
    check not sim.fovAt(visible, cx - Sideways, cy)  # 90 degrees off.

  test "the 60-degree cone edge follows the aim":
    var visible: seq[bool]
    # Aiming up-right at 21 brads (~30 degrees above east). Two cells 300px
    # out, one just inside the 60-degree edge and one just outside it.
    sim.computeFovVisible(cx div FovCellSize, cy div FovCellSize, 21, visible)
    check sim.fovAt(visible, cx + 25, cy - 299)   # ~56 degrees off the aim.
    check not sim.fovAt(visible, cx - 17, cy - 300)  # ~64 degrees off.

  test "vision bubble: close cells are visible regardless of aim":
    var visible: seq[bool]
    sim.computeFovVisible(cx div FovCellSize, cy div FovCellSize, 64, visible)
    check sim.fovAt(visible, cx, cy + 40)      # behind but inside the bubble.
    check sim.fovAt(visible, cx - 60, cy)      # sideways, inside the bubble.
    check sim.fovAt(visible, cx, cy)           # own cell.

  test "an open lane stays visible out to the map border":
    var visible: seq[bool]
    # Aiming south (192 brads) down the hexagon's long axis: the far border is
    # ~540px away, well past the bubble and well inside the 1575px vision
    # range, still visible.
    sim.computeFovVisible(cx div FovCellSize, cy div FovCellSize, 192, visible)
    check sim.fovAt(visible, cx, MapHeight - 20)

  test "the cone cuts off at 1.5x gun range (GV34)":
    # Vision range is derived from the LIVE config.gunRange (1.5x), so a
    # shortened gun proves the cutoff: gunRange 200 fogs the open lane past
    # 300px even with a clear sightline.
    var short = initCtfForTest(bareHexConfig(""""gunRange": 200"""))
    check short.visionRange == 300
    var visible: seq[bool]
    short.computeFovVisible(cx div FovCellSize, cy div FovCellSize, 192, visible)
    check short.fovAt(visible, cx, cy + 250)       # inside 300px: seen.
    check not short.fovAt(visible, cx, cy + 316)   # past the cutoff: fogged.
    # The stock sim sees the same far cell fine (only the range differs).
    var stock: seq[bool]
    sim.computeFovVisible(cx div FovCellSize, cy div FovCellSize, 192, stock)
    check sim.fovAt(stock, cx, cy + 316)

  test "the close-range bubble is never shrunk by the range cap":
    # Even an absurdly short gun keeps the 90px omnidirectional bubble: the
    # cap applies to the cone, not to close-quarters awareness.
    var short = initCtfForTest(bareHexConfig(""""gunRange": 40"""))
    check short.visionRange == 60
    var visible: seq[bool]
    short.computeFovVisible(cx div FovCellSize, cy div FovCellSize, 64, visible)
    check short.fovAt(visible, cx - 80, cy)        # sideways, inside the bubble.
    check not short.fovAt(visible, cx - 150, cy)   # outside bubble AND cone.
    check not short.fovAt(visible, cx, cy - 200)   # dead ahead, past the cap.

  test "everyone but yourself is culled when fogged, teammates included":
    var game = initCtfForTest(bareHexConfig())
    discard game.addPlayer("red0")
    discard game.addPlayer("blue0")
    discard game.addPlayer("red1")
    game.startGame()
    game.players[0].team = Red
    game.players[1].team = Blue
    game.players[2].team = Red
    # Viewer red0 stands at the center aiming north.
    game.players[0].x = cx
    game.players[0].y = cy
    game.players[0].aimBrads = 64
    # Enemy ahead in the cone: visible.
    game.players[1].x = cx
    game.players[1].y = cy - Ahead
    discard game.refreshPlayerFov(0)
    check game.playerVisibleTo(0, 1)
    # Enemy behind, beyond the bubble: fogged.
    game.players[1].y = cy + Behind
    check not game.playerVisibleTo(0, 1)
    # A teammate at the same fogged spot fogs too (no team radio).
    game.players[2].x = cx
    game.players[2].y = cy + Behind
    check not game.playerVisibleTo(0, 2)
    # A teammate ahead in the cone is visible like anyone else.
    game.players[2].y = cy - Ahead
    check game.playerVisibleTo(0, 2)
    # And the viewer always sees itself.
    check game.playerVisibleTo(0, 0)

  test "the vision cone follows the aim, not the movement":
    var game = initCtfForTest(bareHexConfig())
    discard game.addPlayer("red0")
    discard game.addPlayer("blue0")
    game.startGame()
    game.players[0].team = Red
    game.players[1].team = Blue
    # Viewer near the center aiming north; enemy south, beyond the bubble.
    game.players[0].x = cx
    game.players[0].y = cy - 60
    game.players[0].aimBrads = 64
    game.players[1].x = cx
    game.players[1].y = cy + Behind
    discard game.refreshPlayerFov(0)
    check not game.playerVisibleTo(0, 1)
    # Walking TOWARD the enemy does not swing the cone: still fogged.
    var inputs = newSeq[InputState](game.players.len)
    let noInput = newSeq[InputState](game.players.len)
    inputs[0] = InputState(down: true)
    for _ in 1 .. 10:
      game.step(inputs, noInput)
    check game.players[0].y > cy - 60      # the viewer really moved south...
    check game.players[0].aimBrads == 64   # ...with the aim untouched.
    discard game.refreshPlayerFov(0)
    check not game.playerVisibleTo(0, 1)
    # Rotating the aim around to south (64 -> ~192 via B) reveals the enemy.
    inputs[0] = InputState(b: true)
    while game.players[0].aimBrads < 190:
      game.step(inputs, noInput)
    discard game.refreshPlayerFov(0)
    check game.playerVisibleTo(0, 1)

  test "pedestal flags are always visible; carried flags follow the carrier":
    var game = initCtfForTest(bareHexConfig())
    discard game.addPlayer("red0")
    discard game.addPlayer("blue0")
    game.startGame()
    game.players[0].team = Red
    game.players[1].team = Blue
    game.players[0].x = cx
    game.players[0].y = cy
    game.players[0].aimBrads = 64
    discard game.refreshPlayerFov(0)
    # Both pedestals sit far outside the up-aimed cone yet stay visible.
    check game.flagVisibleTo(0, Red)
    check game.flagVisibleTo(0, Blue)
    # The enemy steals the red flag and runs behind the viewer: fogged.
    game.players[1].x = cx
    game.players[1].y = cy + Behind
    game.flags[Red].carrier = 1
    game.players[1].carryingFlag = true
    check not game.flagVisibleTo(0, Red)
    # The same carrier ahead in the cone: visible again.
    game.players[1].y = cy - Ahead
    check game.flagVisibleTo(0, Red)

  test "dead viewers see nothing but themselves":
    var game = initCtfForTest(bareHexConfig())
    discard game.addPlayer("red0")
    discard game.addPlayer("blue0")
    game.startGame()
    game.players[0].team = Red
    game.players[1].team = Blue
    game.players[0].x = cx
    game.players[0].y = cy
    game.players[0].aimBrads = 64
    game.players[0].alive = false
    game.players[1].x = cx
    game.players[1].y = cy + Behind
    # Death does not lift the fog: everything is masked until respawn —
    # even a target standing right where the viewer died.
    check not game.playerVisibleTo(0, 1)
    check not game.fovVisibleAt(0, cx, cy)
    check game.playerVisibleTo(0, 0)

suite "fog-of-war vision: glass on the real arena":
  ## The GV16 midline bracket carries the arena's only glass. Its pane spans
  ## x 421..432 in the left half (and its x-mirror), and is GLASS on rows
  ## y 467..502 with the bracket's stone bar directly above — so a viewer just
  ## east of the pane sees straight through it, while the same lane one bar up
  ## dies on stone.
  ##
  ## Every coordinate here moved with the LANDSCAPE flip and was RE-MEASURED
  ## off the installed arena (tools/hex_scene_probe.nim), not rescaled by hand:
  ## the board is 1119x969 with centre (559, 484), where the portrait hull put
  ## the same pane at x 346..357.
  ##
  ## GlassRowY IS NOT THE CENTRE ROW any more. From y 484 downward the floor
  ## east of the pane runs into the centre feature (stone at x 444..489 on
  ## y 490), so a westward ray from a viewer at x 439 would cross that stone as
  ## well as the glass — and this suite would then pass on stone while claiming
  ## to test glass. 475 sits in the clean band (467..483) where the only thing
  ## between the viewer and the far floor is the pane.
  var sim = initCtfForTest()
  const
    PaneCx = 426            # centre of the glass pane (x 421..432).
    GlassRowY = 475         # inside the pane, in the clean band.
    StoneRowY = 454         # the bracket's stone bar (y 431..466).
    ViewerX = 439           # floor just east of the pane, both rows.
    BehindX = 300           # open floor west of the pane, both rows.

  test "the bracket scene is laid out as documented":
    check isArenaWindowPixel(PaneCx, GlassRowY, sim.gameMap.center.x,
      sim.gameMap.center.y)
    check sim.isWall(PaneCx, GlassRowY)       # glass is still wall for shots.
    check not sim.isWall(ViewerX, GlassRowY)  # the viewer's own cell.
    check not sim.isWall(BehindX, GlassRowY)  # floor behind the pane.
    check sim.isWall(PaneCx, StoneRowY)       # stone above the pane...
    check not isArenaWindowPixel(             # ...and it is NOT glass.
      PaneCx, StoneRowY, sim.gameMap.center.x, sim.gameMap.center.y)
    check not sim.isWall(ViewerX, StoneRowY)  # the stone viewer's own cell.
    check not sim.isWall(BehindX, StoneRowY)  # floor behind that stone.

  test "walls block the cone, glass does not":
    # Two viewers one bar apart, both just east of the bracket aiming west
    # (128 brads). On the pane's own row the lane is glass and stays visible;
    # one bar up the same lane is stone and fogs. Same x, same aim, same
    # distance — the only difference is which pane the ray meets.
    var throughGlass: seq[bool]
    sim.computeFovVisible(ViewerX div FovCellSize, GlassRowY div FovCellSize,
      128, throughGlass)
    check sim.fovAt(throughGlass, BehindX, GlassRowY)
    var throughStone: seq[bool]
    sim.computeFovVisible(ViewerX div FovCellSize, StoneRowY div FovCellSize,
      128, throughStone)
    check not sim.fovAt(throughStone, BehindX, StoneRowY)
