import
  std/[os, unittest],
  ctf/sim
import helpers except initCtfForTest

## The scene: a shooter northwest of a single stone stub, sweeping its aim
## through all 256 brads and firing every angle. One target stands fully in the
## open due south; the same distance away, another pokes out past the stub's
## south-east corner at varying depths of cover. Exposure-sampled hit resolution
## means the number of aim angles that connect scales with how much body the
## target shows.
##
## The stub is PLACED (`helpers.coverHexConfig`) rather than borrowed from the
## hand-authored arena. It is the same 19x63 block in the same relative
## position the rectangular board's column-1 stub gave for free; on the hexagon
## the old absolute coordinates are in the void above the hull, and any
## replacement borrowed from `arenaHexObstacles` would move whenever the arena
## is re-tuned.
const
  StubRect = MapRect(x: 300, y: 290, w: 19, h: 63)
  ShooterX = 272
  ShooterY = 320
  OpenX = 272                 # due south of the shooter, nothing between.
  OpenY = 383
  DeepX = 319                 # tucked close behind the stub's SE corner:
  DeepY = 366                 # center-line blocked, a south sliver exposed.
  ShallowX = 313              # a step out of the same corner's shadow:
  ShallowY = 366              # more silhouette shown, still partly covered.
  CoveredX = 328              # fully inside the stub's shadow.
  CoveredY = 360

proc initCtfForTest(): SimServer =
  ## Initializes the CTF sim from the game directory (so data/ resolves), on
  ## the bare hexagon plus the one stub this scene is built around.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(coverHexConfig(@[rectShape(StubRect)]))
    result.gameEventLoggingEnabled = false
  finally:
    setCurrentDir(previousDir)

suite "shot exposure: more exposed opponents get hit more often":
  proc sweepHits(game: var SimServer, targetX, targetY: int): int =
    ## Parks the target at one spot and fires one shot per aim angle,
    ## counting how many of the 256 angles connect.
    game.players[1].x = targetX
    game.players[1].y = targetY
    for brads in 0 ..< AimBradsTurn:
      game.players[0].aimBrads = brads
      game.players[0].windupBrads = -1
      game.players[0].fireCooldown = 0
      game.players[1].hp = 3
      game.tryFire(0)
      if game.players[1].hp < 3:
        inc result

  var game = initCtfForTest()
  discard game.addPlayer("red0")
  discard game.addPlayer("blue0")
  game.startGame()
  game.players[0].team = Red
  game.players[1].team = Blue
  game.players[0].x = ShooterX
  game.players[0].y = ShooterY

  test "the scene is laid out as documented":
    # Every spot is standable and the stub really is the only cover story:
    # the open target has a clear center-line, both covered spots do not.
    check game.canOccupy(ShooterX, ShooterY)
    check game.canOccupy(OpenX, OpenY)
    check game.canOccupy(DeepX, DeepY)
    check game.canOccupy(ShallowX, ShallowY)
    check not game.segmentBlocked(ShooterX, ShooterY, OpenX, OpenY)
    check game.segmentBlocked(ShooterX, ShooterY, DeepX, DeepY)
    # ...and the stub is real, sitting exactly where the scene says it does.
    check game.isWall(StubRect.x, StubRect.y)
    check game.isWall(StubRect.x + StubRect.w - 1, StubRect.y + StubRect.h - 1)
    check not game.isWall(StubRect.x - 1, StubRect.y)
    check not game.isWall(StubRect.x, StubRect.y + StubRect.h)

  test "hit angles grow monotonically with exposure":
    let
      openHits = game.sweepHits(OpenX, OpenY)
      shallowHits = game.sweepHits(ShallowX, ShallowY)
      deepHits = game.sweepHits(DeepX, DeepY)
    # A body in the open is the most hittable of the three.
    check openHits > shallowHits
    # Stepping deeper into the corner's shadow sheds hit angles.
    check shallowHits > deepHits
    # But a poking sliver is NOT immune: its exposed part can be hit even
    # though the center-to-center line of sight is wall-blocked.
    check deepHits > 0

  test "full cover is still full immunity":
    # Fully behind the stub (well inside the corner's shadow) no aim
    # angle connects at all.
    let coveredHits = game.sweepHits(CoveredX, CoveredY)
    check game.segmentBlocked(ShooterX, ShooterY, CoveredX, CoveredY)
    check coveredHits == 0
