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
  test "starts in playing with both flags home on their pedestals":
    let sim = twoTeamGame()
    check sim.phase == Playing
    for team in Team:
      let home = sim.gameMap.flagHome(team)
      check sim.flags[team].carrier == -1
      check sim.flags[team].x == home.x
      check sim.flags[team].y == home.y

  test "only the enemy flag can be picked up":
    var sim = twoTeamGame()
    let
      redHome = sim.gameMap.flagHome(Red)
      blueHome = sim.gameMap.flagHome(Blue)
    # Red player 0 standing on its OWN pedestal: no interaction.
    sim.players[0].x = redHome.x
    sim.players[0].y = redHome.y
    sim.tryPickupFlags(0)
    check sim.flags[Red].carrier == -1
    check not sim.players[0].carryingFlag
    # The same player on Blue's pedestal steals the blue flag.
    sim.players[0].x = blueHome.x
    sim.players[0].y = blueHome.y
    sim.tryPickupFlags(0)
    check sim.flags[Blue].carrier == 0
    check sim.players[0].carryingFlag
    # The red flag never moved.
    check sim.flags[Red].carrier == -1
    check sim.flags[Red].x == redHome.x
    check sim.flags[Red].y == redHome.y

  test "a dead player cannot steal a flag":
    var sim = twoTeamGame()
    let blueHome = sim.gameMap.flagHome(Blue)
    sim.players[0].x = blueHome.x
    sim.players[0].y = blueHome.y
    sim.players[0].alive = false
    sim.tryPickupFlags(0)
    check sim.flags[Blue].carrier == -1

  test "hitscan kills an enemy on the shot ray":
    var sim = twoTeamGame()
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    sim.players[0].aimBrads = 0
    sim.players[0].fireCooldown = 0
    sim.players[1].x = cx + 6
    sim.players[1].y = cy
    sim.players[1].spawnProtect = 0
    sim.players[1].hp = 1
    let livesBefore = sim.players[1].lives

    sim.tryFire(0)

    check not sim.players[1].alive
    check sim.players[1].deaths == 1
    check sim.players[1].lives == livesBefore - 1
    check sim.players[0].kills == 1

  test "three hits kill: each shot removes one hit point":
    var sim = twoTeamGame()
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    sim.players[0].aimBrads = 0
    sim.players[1].x = cx + 60
    sim.players[1].y = cy
    sim.players[1].spawnProtect = 0
    check sim.players[1].hp == sim.config.hitPoints

    for hit in 1 .. sim.config.hitPoints:
      sim.players[0].fireCooldown = 0
      sim.players[0].fireWindup = 0
      sim.tryFire(0)
      if hit < sim.config.hitPoints:
        check sim.players[1].alive
        check sim.players[1].hp == sim.config.hitPoints - hit
        check sim.players[1].deaths == 0
        check sim.players[0].kills == 0
    check not sim.players[1].alive
    check sim.players[1].deaths == 1
    check sim.players[0].kills == 1

    # Respawning restores full hit points.
    let noInput = newSeq[InputState](sim.players.len)
    for _ in 1 .. sim.config.respawnTicks + 1:
      sim.step(noInput, noInput)
    check sim.players[1].alive
    check sim.players[1].hp == sim.config.hitPoints

  test "a bullet stops at the first target in its path":
    var sim = twoTeamGame()
    discard sim.addPlayer("blue1")
    sim.players[2].team = Blue
    sim.players[2].alive = true
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    sim.players[0].aimBrads = 0
    sim.players[0].fireCooldown = 0
    # Two enemies dead ahead on the same ray: near and far.
    sim.players[1].x = cx + 40
    sim.players[1].y = cy
    sim.players[1].spawnProtect = 0
    sim.players[2].x = cx + 100
    sim.players[2].y = cy
    sim.players[2].spawnProtect = 0
    sim.players[1].hp = 1

    sim.tryFire(0)

    check not sim.players[1].alive     # first body in the path dies
    check sim.players[2].alive         # the bullet does not pass through
    check sim.players[0].kills == 1
    # The tracer ends at the first victim, not beyond it.
    check sim.recentShots[0].x1 == sim.players[1].x + CollisionW div 2

  test "a shot passes wide of an off-ray target":
    var sim = twoTeamGame()
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    sim.players[0].aimBrads = 0
    sim.players[0].fireCooldown = 0
    # Ahead but 60px off the ray: inside the old 25-degree cone, far outside
    # the bullet corridor.
    sim.players[1].x = cx + 200
    sim.players[1].y = cy + 60
    sim.players[1].spawnProtect = 0

    sim.tryFire(0)

    check sim.players[1].alive
    check sim.players[0].kills == 0

  test "the windup delays the shot":
    var sim = twoTeamGame()
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    sim.players[0].aimBrads = 0
    sim.players[0].fireCooldown = 0
    sim.players[1].x = cx + 60
    sim.players[1].y = cy
    sim.players[1].spawnProtect = 0
    sim.players[1].hp = 1

    sim.startFireWindup(0)
    check sim.players[0].fireWindup == sim.config.fireWindupTicks

    let noInput = newSeq[InputState](sim.players.len)
    # The target survives every tick of the windup but the last.
    for _ in 1 ..< sim.config.fireWindupTicks:
      sim.step(noInput, noInput)
      check sim.players[1].alive
    sim.step(noInput, noInput)
    check not sim.players[1].alive
    check sim.players[0].fireCooldown > 0

  test "ducking out of the line during the windup survives the shot":
    var sim = twoTeamGame()
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    sim.players[0].aimBrads = 0
    sim.players[0].fireCooldown = 0
    sim.players[1].x = cx + 60
    sim.players[1].y = cy
    sim.players[1].spawnProtect = 0

    sim.startFireWindup(0)
    # The peeker steps back out of the bullet corridor before the release.
    sim.players[1].y = cy + 40

    let noInput = newSeq[InputState](sim.players.len)
    for _ in 1 .. sim.config.fireWindupTicks:
      sim.step(noInput, noInput)
    check sim.players[1].alive
    check sim.players[0].kills == 0
    check sim.recentShots.len == 1     # the shot still fired, into empty space

  test "the aim locks at the trigger pull":
    var sim = twoTeamGame()
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    sim.players[0].aimBrads = 0
    sim.players[0].fireCooldown = 0
    sim.players[1].x = cx + 60
    sim.players[1].y = cy
    sim.players[1].spawnProtect = 0
    sim.players[1].hp = 1

    sim.startFireWindup(0)
    check sim.players[0].windupBrads == 0
    # Turning after the pull must not move the shot off the locked angle:
    # swing the live aim all the way to south during the windup.
    sim.players[0].aimBrads = 192

    let noInput = newSeq[InputState](sim.players.len)
    for _ in 1 .. sim.config.fireWindupTicks:
      sim.step(noInput, noInput)
    check not sim.players[1].alive     # still hit along the original aim
    check sim.players[0].windupBrads == -1

  test "rotate buttons turn the aim; movement never does":
    var sim = twoTeamGame()
    let rate = sim.config.aimTurnRate
    check sim.players[0].aimBrads == 0     # Red spawns aiming east.
    check sim.players[1].aimBrads == 128   # Blue spawns aiming west.

    var inputs = newSeq[InputState](sim.players.len)
    let noInput = newSeq[InputState](sim.players.len)
    # Holding B rotates counter-clockwise by aimTurnRate per tick.
    inputs[0] = InputState(b: true)
    sim.step(inputs, noInput)
    check sim.players[0].aimBrads == rate
    # Holding Select rotates clockwise (wrapping under 0).
    inputs[0] = InputState(select: true)
    sim.step(inputs, noInput)
    sim.step(inputs, noInput)
    check sim.players[0].aimBrads == (256 - rate) mod 256
    # Holding both rotate buttons cancels the rotation.
    inputs[0] = InputState(b: true, select: true)
    sim.step(inputs, noInput)
    check sim.players[0].aimBrads == (256 - rate) mod 256
    # Movement moves the player but NEVER changes the aim.
    inputs[0] = InputState(up: true, left: true)
    let (x0, y0) = (sim.players[0].x, sim.players[0].y)
    for _ in 1 .. 6:
      sim.step(inputs, noInput)
    check (sim.players[0].x, sim.players[0].y) != (x0, y0)
    check sim.players[0].aimBrads == (256 - rate) mod 256

  test "fire direction comes from the aim angle (32 = northeast)":
    var sim = twoTeamGame()
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    sim.players[0].aimBrads = 32   # northeast: +x, -y in map coordinates.
    sim.players[0].fireCooldown = 0
    # The target sits on the exact diagonal, inside the open flag ring.
    sim.players[1].x = cx + 40
    sim.players[1].y = cy - 40
    sim.players[1].spawnProtect = 0
    sim.players[1].hp = 1

    sim.tryFire(0)

    check not sim.players[1].alive
    check sim.players[0].kills == 1

  test "a hit records a tracer ending at the target and skips the hash":
    var sim = twoTeamGame()
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    sim.players[0].aimBrads = 0
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
    sim.players[0].aimBrads = 0
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
    sim.players[0].aimBrads = 0
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
    sim.players[0].aimBrads = 0
    sim.players[0].fireCooldown = 0
    sim.players[1].x = cx + 6
    sim.players[1].y = cy
    sim.players[1].spawnProtect = 0
    sim.players[1].hp = 1

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

  test "shot misses a target behind the shooter":
    var sim = twoTeamGame()
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    sim.players[0].aimBrads = 0   # aiming east
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
    sim.players[0].aimBrads = 0
    sim.players[0].fireCooldown = 0
    sim.players[1].x = cx + 6
    sim.players[1].y = cy
    sim.players[1].spawnProtect = 10

    sim.tryFire(0)

    check sim.players[1].alive

  test "a same-tick mutual duel kills both shooters (no order advantage)":
    var sim = twoTeamGame()
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    # Face each other, both ready, both pulling the trigger the same tick.
    sim.players[0].x = cx - 20
    sim.players[0].y = cy
    sim.players[0].aimBrads = 0
    sim.players[0].fireCooldown = 0
    sim.players[0].spawnProtect = 0
    sim.players[1].x = cx + 20
    sim.players[1].y = cy
    sim.players[1].aimBrads = 128
    sim.players[1].fireCooldown = 0
    sim.players[1].spawnProtect = 0

    sim.players[0].hp = 1
    sim.players[1].hp = 1

    sim.resolveSimultaneousFire([0, 1])

    check not sim.players[0].alive
    check not sim.players[1].alive
    check sim.players[0].kills == 1
    check sim.players[1].kills == 1
    check sim.recentShots.len == 2

  test "killing the carrier returns the flag to its own pedestal":
    var sim = twoTeamGame()
    let
      cx = sim.gameMap.center.x
      cy = sim.gameMap.center.y
      redHome = sim.gameMap.flagHome(Red)
      blueHome = sim.gameMap.flagHome(Blue)
    sim.players[0].x = cx
    sim.players[0].y = cy
    sim.players[0].aimBrads = 0
    sim.players[0].fireCooldown = 0
    sim.players[1].x = cx + 40
    sim.players[1].y = cy
    sim.players[1].spawnProtect = 0
    # Blue player 1 is running the RED flag home.
    sim.flags[Red].carrier = 1
    sim.players[1].carryingFlag = true
    sim.flags[Red].x = sim.players[1].x
    sim.flags[Red].y = sim.players[1].y
    sim.players[1].hp = 1

    sim.tryFire(0)

    check not sim.players[1].alive
    check not sim.players[1].carryingFlag
    check sim.flags[Red].carrier == -1
    check sim.flags[Red].x == redHome.x
    check sim.flags[Red].y == redHome.y
    # The blue flag was untouched by all of that.
    check sim.flags[Blue].carrier == -1
    check sim.flags[Blue].x == blueHome.x
    check sim.flags[Blue].y == blueHome.y

  test "removing the carrier returns the flag to its own pedestal":
    var sim = twoTeamGame()
    let redHome = sim.gameMap.flagHome(Red)
    sim.flags[Red].carrier = 1
    sim.players[1].carryingFlag = true
    sim.flags[Red].x = sim.players[1].x
    sim.flags[Red].y = sim.players[1].y

    sim.removePlayerAt(1)

    check sim.flags[Red].carrier == -1
    check sim.flags[Red].x == redHome.x
    check sim.flags[Red].y == redHome.y

  test "removing a lower-index player keeps the carrier index aligned":
    var sim = twoTeamGame()
    sim.flags[Red].carrier = 1
    sim.players[1].carryingFlag = true

    sim.removePlayerAt(0)

    check sim.flags[Red].carrier == 0
    check sim.players[0].carryingFlag

  test "carrying the enemy flag into your home zone captures and wins":
    var sim = twoTeamGame()
    # Red player 0 carries the BLUE flag into Red's capture zone.
    sim.flags[Blue].carrier = 0
    sim.players[0].carryingFlag = true
    sim.players[0].x = 0          # leftmost column is always in Red's zone
    sim.players[0].alive = true

    sim.checkWinCondition()

    check sim.phase == GameOver
    check sim.winner == Red
    check not sim.isDraw
    check sim.players[0].captures == 1

  test "carrying your own flag home does not exist: own flag never leaves":
    var sim = twoTeamGame()
    # A Red player inside Red's zone while only the RED flag is carried by
    # Blue must not trigger a Red capture.
    sim.flags[Red].carrier = 1
    sim.players[1].carryingFlag = true
    sim.players[0].x = 0
    sim.players[0].alive = true
    sim.players[1].x = sim.gameMap.center.x

    sim.checkWinCondition()

    check sim.phase == Playing

  test "gameHash covers both flags' state":
    var sim = twoTeamGame()
    let base = sim.gameHash()
    sim.flags[Red].x += 1
    check sim.gameHash() != base
    sim.flags[Red].x -= 1
    check sim.gameHash() == base
    sim.flags[Blue].carrier = 0
    check sim.gameHash() != base

  test "wiping the enemy team wins":
    var sim = twoTeamGame()
    sim.players[1].alive = false
    sim.players[1].lives = 0

    sim.checkWinCondition()

    check sim.phase == GameOver
    check sim.winner == Red

  test "a decisive win scores +1 for winners and -1 for losers":
    var sim = twoTeamGame()
    sim.finishGame(Red)
    check sim.phase == GameOver
    check sim.winner == Red
    check sim.players[0].reward == 1
    check sim.players[1].reward == -1

  test "a disconnected loser is not marked a winner":
    var sim = twoTeamGame()
    # Blue abandons (crashes) before the finish: its reward account remains.
    sim.recordGameAbandon(1)
    sim.removePlayerAt(1)
    sim.finishGame(Red)
    var red, blue = -1
    for i in 0 ..< sim.rewardAccounts.len:
      if sim.rewardAccounts[i].address == "red0": red = i
      elif sim.rewardAccounts[i].address == "blue0": blue = i
    check sim.rewardAccounts[red].won
    check sim.rewardAccounts[red].reward == 1
    check not sim.rewardAccounts[blue].won
    check sim.rewardAccounts[blue].reward == -1
    check sim.rewardAccounts[blue].winsRed == 0
    check sim.rewardAccounts[blue].winsBlue == 0

  test "a time-limit game is a scoreless draw for both sides":
    var sim = twoTeamGame()
    sim.config.maxTicks = 5
    let none = newSeq[InputState](sim.players.len)
    while sim.phase == Playing:
      sim.step(none, none)
    check sim.isDraw
    check sim.timeLimitReached
    check sim.players[0].reward == 0
    check sim.players[1].reward == 0
