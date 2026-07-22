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
      # Shields live in the BOTTOM half (three-quarter height); the plasma arcs
      # hold the matching top-half spots.
      check abs(spawn.y - 3 * MapHeight div 4) < 120
      check spawn.y > MapHeight div 2
    # One shield on the red (left) half, one on the blue (right) half.
    check sim.shieldSpawns[0].x < MapWidth div 2
    check sim.shieldSpawns[1].x > MapWidth div 2

  test "picking up a shield from full health grants 6 hit points":
    var sim = twoTeamGame()
    check sim.config.hitPoints < ShieldHitPoints
    check sim.players[0].hp == sim.config.hitPoints
    sim.standOn(0, 0)
    sim.tryPickupShields(0)
    check sim.players[0].hasShield
    check sim.players[0].hp == ShieldHitPoints
    check not sim.shieldSpawns[0].present
    check sim.shieldSpawns[1].present

  test "a shield pickup heals ShieldPickupHeal, not to full":
    # A hurt shieldless player gains the shield plus 3 hp — it does not jump
    # straight to 6.
    var sim = twoTeamGame()
    check ShieldPickupHeal == 3
    sim.players[0].hp = 1
    sim.standOn(0, 0)
    sim.tryPickupShields(0)
    check sim.players[0].hasShield
    check sim.players[0].hp == 1 + ShieldPickupHeal
    check not sim.shieldSpawns[0].present

  test "a damaged shield carrier can take another shield to top up":
    var sim = twoTeamGame()
    sim.players[0].hasShield = true
    sim.players[0].hp = 2
    sim.standOn(0, 0)
    sim.tryPickupShields(0)
    check sim.players[0].hasShield
    check sim.players[0].hp == 2 + ShieldPickupHeal
    check not sim.shieldSpawns[0].present
    check sim.shieldSpawns[0].respawnAt == sim.tickCount + ShieldRespawnTicks

  test "a shield top-up caps at ShieldHitPoints":
    var sim = twoTeamGame()
    sim.players[0].hasShield = true
    sim.players[0].hp = ShieldHitPoints - 1
    sim.standOn(0, 0)
    sim.tryPickupShields(0)
    check sim.players[0].hp == ShieldHitPoints
    check not sim.shieldSpawns[0].present

  test "a shield carrier can still shoot and kill":
    var sim = twoTeamGame()
    sim.players[0].x = 300
    sim.players[0].y = 300
    sim.players[0].aimBrads = 0           # east
    sim.players[0].fireCooldown = 0
    sim.players[0].hasShield = true
    sim.players[1].x = 300 + 30
    sim.players[1].y = 300
    sim.players[1].hp = 1
    sim.tryFire(0)
    check not sim.players[1].alive

  test "a shield carrier's fire cooldown is 3x the normal cooldown":
    # Control: no shield, a shot starts the normal cooldown.
    var ctrl = twoTeamGame()
    ctrl.players[0].fireCooldown = 0
    ctrl.tryFire(0)
    check ctrl.players[0].fireCooldown == ctrl.config.fireCooldownTicks

    # Same shot with a shield: the cooldown is ShieldFireSlowdown times longer.
    var sim = twoTeamGame()
    sim.players[0].fireCooldown = 0
    sim.players[0].hasShield = true
    sim.tryFire(0)
    check ShieldFireSlowdown == 3
    check sim.players[0].fireCooldown ==
      sim.config.fireCooldownTicks * ShieldFireSlowdown

  test "a full-health shield carrier does not waste a spawn":
    var sim = twoTeamGame()
    sim.standOn(0, 0)
    sim.tryPickupShields(0)
    check sim.players[0].hasShield
    check sim.players[0].hp == ShieldHitPoints
    # Standing on the second shield at full 6 hp takes nothing — a pickup
    # that would heal 0 leaves the spawn for a teammate.
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
