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
  for i in 0 ..< result.players.len:
    result.players[i].spawnProtect = 0

proc standOn(sim: var SimServer, playerIndex, spawnIndex: int) =
  ## Puts one player exactly on a shield spawn point.
  sim.players[playerIndex].x = sim.shieldSpawns[spawnIndex].x - CollisionW div 2
  sim.players[playerIndex].y = sim.shieldSpawns[spawnIndex].y - CollisionH div 2

suite "shields":
  test "one shield spawns in each team's endzone on walkable floor":
    let sim = twoTeamGame()
    check sim.shieldSpawns.len == 2
    for spawn in sim.shieldSpawns:
      check spawn.present
      check sim.canOccupy(spawn.x, spawn.y)
    # One shield on the red (left) half, one on the blue (right) half.
    check sim.shieldSpawns[0].x < MapWidth div 2
    check sim.shieldSpawns[1].x > MapWidth div 2

  test "picking up a shield grants 6 hit points and bars shooting":
    var sim = twoTeamGame()
    check sim.config.hitPoints < ShieldHitPoints
    sim.standOn(0, 0)
    sim.tryPickupShields(0)
    check sim.players[0].hasShield
    check sim.players[0].hp == ShieldHitPoints
    check not sim.shieldSpawns[0].present
    check sim.shieldSpawns[1].present

  test "a shield carrier cannot shoot; an unshielded control kills":
    # Control: no shield, a point-blank shot kills the enemy.
    var ctrl = twoTeamGame()
    ctrl.players[0].x = 300
    ctrl.players[0].y = 300
    ctrl.players[0].aimBrads = 0          # east
    ctrl.players[0].fireCooldown = 0
    ctrl.players[1].x = 300 + 30
    ctrl.players[1].y = 300
    ctrl.players[1].hp = 1
    ctrl.tryFire(0)
    check not ctrl.players[1].alive

    # Same setup, but the shooter carries a shield: the shot never fires.
    var sim = twoTeamGame()
    sim.players[0].x = 300
    sim.players[0].y = 300
    sim.players[0].aimBrads = 0
    sim.players[0].fireCooldown = 0
    sim.players[0].hasShield = true
    sim.players[1].x = 300 + 30
    sim.players[1].y = 300
    sim.players[1].hp = 1
    sim.tryFire(0)
    check sim.players[1].alive

  test "attack input from a shielded player releases no shot over many ticks":
    var sim = twoTeamGame()
    sim.players[0].x = 300
    sim.players[0].y = 300
    sim.players[0].aimBrads = 0
    sim.players[0].hasShield = true
    sim.players[1].x = 300 + 30
    sim.players[1].y = 300
    sim.players[1].hp = 1
    var inputs = newSeq[InputState](sim.players.len)
    inputs[0].attack = true
    let none = newSeq[InputState](sim.players.len)
    var prev = none
    for _ in 0 ..< 4 * ReplayFps:
      sim.step(inputs, prev)
      prev = inputs
      if not sim.players[0].hasShield:
        break
    check sim.players[1].alive

  test "a player carries at most one shield":
    var sim = twoTeamGame()
    sim.standOn(0, 0)
    sim.tryPickupShields(0)
    check sim.players[0].hasShield
    # Standing on the second shield with one in hand takes nothing.
    sim.standOn(0, 1)
    sim.tryPickupShields(0)
    check sim.shieldSpawns[1].present

  test "dead players cannot pick up a shield":
    var sim = twoTeamGame()
    sim.players[0].alive = false
    sim.standOn(0, 0)
    sim.tryPickupShields(0)
    check sim.shieldSpawns[0].present

  test "a taken shield respawns after 30 seconds":
    var sim = twoTeamGame()
    check ShieldRespawnTicks == 30 * ReplayFps
    sim.standOn(0, 0)
    sim.tryPickupShields(0)
    check not sim.shieldSpawns[0].present
    # Move the carrier away so the refilled shield is not retaken.
    sim.players[0].x = sim.players[0].homeX
    sim.players[0].y = sim.players[0].homeY
    let none = newSeq[InputState](sim.players.len)
    for _ in 0 ..< ShieldRespawnTicks + 1:
      sim.step(none, none)
    check sim.shieldSpawns[0].present

  test "dying loses the carried shield":
    var sim = twoTeamGame()
    sim.players[0].hasShield = true
    sim.players[0].hp = 1
    sim.players[1].x = sim.players[0].x + 40
    sim.players[1].y = sim.players[0].y
    sim.players[1].aimBrads = 128         # west, at player 0
    var inputs = newSeq[InputState](sim.players.len)
    inputs[1].attack = true
    let none = newSeq[InputState](sim.players.len)
    var prev = none
    while sim.players[0].alive and sim.tickCount < 200:
      sim.step(inputs, prev)
      prev = inputs
    check not sim.players[0].alive
    check not sim.players[0].hasShield

  test "shield state is in the game hash":
    var sim1 = twoTeamGame()
    var sim2 = twoTeamGame()
    check sim1.gameHash == sim2.gameHash
    sim1.players[0].hasShield = true
    check sim1.gameHash != sim2.gameHash
    sim1.players[0].hasShield = false
    sim1.shieldSpawns[0].present = false
    check sim1.gameHash != sim2.gameHash
