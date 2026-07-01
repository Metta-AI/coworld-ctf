import
  std/[os, unittest],
  bitworld/spriteprotocol,
  ctf/sim

const GameDir = currentSourcePath.parentDir.parentDir

proc initCtfForTest(config: GameConfig): SimServer =
  ## Initializes the CTF sim from the game directory (so data/ resolves).
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc twoTeamGame(): SimServer =
  ## A started game with one Red player (0) and one Blue player (1).
  result = initCtfForTest(defaultGameConfig())
  discard result.addPlayer("red0")
  discard result.addPlayer("blue0")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Blue

suite "ctf game":
  test "starts in playing with a loose, centered flag":
    let sim = twoTeamGame()
    check sim.phase == Playing
    check sim.flagCarrier == -1
    check sim.flagX == sim.gameMap.center.x
    check sim.flagY == sim.gameMap.center.y

  test "hitscan kills an enemy inside the firing cone":
    var sim = twoTeamGame()
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    sim.players[0].facingDx = 1
    sim.players[0].facingDy = 0
    sim.players[0].fireCooldown = 0
    sim.players[1].x = cx + 6
    sim.players[1].y = cy
    sim.players[1].spawnProtect = 0
    let livesBefore = sim.players[1].lives

    sim.tryFire(0)

    check not sim.players[1].alive
    check sim.players[1].deaths == 1
    check sim.players[1].lives == livesBefore - 1
    check sim.players[0].kills == 1

  test "a hit records a tracer ending at the target and skips the hash":
    var sim = twoTeamGame()
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    sim.players[0].facingDx = 1
    sim.players[0].facingDy = 0
    sim.players[0].fireCooldown = 0
    sim.players[1].x = cx + 6
    sim.players[1].y = cy
    sim.players[1].spawnProtect = 0

    sim.tryFire(0)

    check sim.recentShots.len == 1
    let shot = sim.recentShots[0]
    check shot.x0 == cx + CollisionW div 2
    check shot.y0 == cy + CollisionH div 2
    check shot.x1 == sim.players[1].x + CollisionW div 2
    check shot.y1 == sim.players[1].y + CollisionH div 2
    check shot.color == sim.players[0].color

    # Cosmetic tracers must never change the deterministic gameplay hash:
    # mutating recentShots leaves the hash untouched.
    let hashWithShot = sim.gameHash()
    sim.recentShots.add ShotFx(x0: 1, y0: 2, x1: 3, y1: 4, firedTick: 9, color: 5)
    check sim.gameHash() == hashWithShot
    sim.recentShots.setLen(0)
    check sim.gameHash() == hashWithShot

  test "a miss records a tracer that stops within gun range":
    var sim = twoTeamGame()
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    sim.players[0].facingDx = 1
    sim.players[0].facingDy = 0
    sim.players[0].fireCooldown = 0
    sim.players[1].x = cx - 6      # behind the shooter: no target hit
    sim.players[1].y = cy

    sim.tryFire(0)

    check sim.players[0].kills == 0
    check sim.recentShots.len == 1
    let shot = sim.recentShots[0]
    check shot.x0 == cx + CollisionW div 2
    check shot.y1 == cy + CollisionH div 2
    # Endpoint is downrange (to the right) and within gun range.
    check shot.x1 > shot.x0
    check shot.x1 - shot.x0 <= sim.config.gunRange

  test "expired tracers are pruned after ShotFxTicks":
    var sim = twoTeamGame()
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    sim.players[0].facingDx = 1
    sim.players[0].facingDy = 0
    sim.players[0].fireCooldown = 0
    sim.players[1].x = cx - 6
    sim.players[1].y = cy

    sim.tryFire(0)
    check sim.recentShots.len == 1

    let noInput = newSeq[InputState](sim.players.len)
    for _ in 0 ..< ShotFxTicks:
      sim.step(noInput, noInput)
    check sim.recentShots.len == 0

  test "a kill leaves a splatter that skips the hash and fades out":
    var sim = twoTeamGame()
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    sim.players[0].facingDx = 1
    sim.players[0].facingDy = 0
    sim.players[0].fireCooldown = 0
    sim.players[1].x = cx + 6
    sim.players[1].y = cy
    sim.players[1].spawnProtect = 0

    sim.tryFire(0)

    check sim.splatters.len == 1
    check sim.splatters[0].x == sim.players[1].x
    check sim.splatters[0].y == sim.players[1].y
    check sim.splatters[0].color == sim.players[1].color

    # Cosmetic splatters must never change the deterministic gameplay hash:
    # mutating splatters leaves the hash untouched.
    let hashWithSplatter = sim.gameHash()
    sim.splatters.add SplatterFx(x: 1, y: 2, tick: 9, color: 5)
    check sim.gameHash() == hashWithSplatter
    sim.splatters.setLen(1)
    check sim.gameHash() == hashWithSplatter

    let noInput = newSeq[InputState](sim.players.len)
    for _ in 0 ..< SplatterFxTicks:
      sim.step(noInput, noInput)
    check sim.splatters.len == 0

  test "shot misses a target outside the cone":
    var sim = twoTeamGame()
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    sim.players[0].facingDx = 1   # facing right
    sim.players[0].facingDy = 0
    sim.players[0].fireCooldown = 0
    sim.players[1].x = cx - 6     # standing behind the shooter
    sim.players[1].y = cy

    sim.tryFire(0)

    check sim.players[1].alive
    check sim.players[0].kills == 0

  test "spawn-protected target cannot be shot":
    var sim = twoTeamGame()
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    sim.players[0].facingDx = 1
    sim.players[0].fireCooldown = 0
    sim.players[1].x = cx + 6
    sim.players[1].y = cy
    sim.players[1].spawnProtect = 10

    sim.tryFire(0)

    check sim.players[1].alive

  test "carrier in its home zone captures and wins":
    var sim = twoTeamGame()
    sim.flagCarrier = 0
    sim.players[0].carryingFlag = true
    sim.players[0].x = 0          # leftmost column is always in Red's zone
    sim.players[0].alive = true

    sim.checkWinCondition()

    check sim.phase == GameOver
    check sim.winner == Red
    check not sim.isDraw

  test "wiping the enemy team wins":
    var sim = twoTeamGame()
    sim.players[1].alive = false
    sim.players[1].lives = 0

    sim.checkWinCondition()

    check sim.phase == GameOver
    check sim.winner == Red

  test "finishGame awards WinReward to the winning team only":
    var sim = twoTeamGame()
    sim.finishGame(Red)
    check sim.phase == GameOver
    check sim.winner == Red
    check sim.players[0].reward == WinReward
    check sim.players[1].reward == 0
