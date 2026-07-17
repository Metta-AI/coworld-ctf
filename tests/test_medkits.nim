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

proc standOn(sim: var SimServer, playerIndex, spawnIndex: int) =
  ## Puts one player exactly on a med kit spawn point.
  sim.players[playerIndex].x = sim.medKitSpawns[spawnIndex].x - CollisionW div 2
  sim.players[playerIndex].y = sim.medKitSpawns[spawnIndex].y - CollisionH div 2

suite "med kits":
  test "two kits spawn on the walkable center line":
    let sim = twoTeamGame()
    for spawn in sim.medKitSpawns:
      check spawn.present
      check sim.canOccupy(spawn.x, spawn.y)
      check abs(spawn.x - MapWidth div 2) < 120
    check sim.medKitSpawns[0].y < MapHeight div 2
    check sim.medKitSpawns[1].y > MapHeight div 2

  test "a hurt player picks a kit up by touch and heals to full":
    var sim = twoTeamGame()
    sim.players[0].hp = 1
    sim.standOn(0, 0)
    sim.tryPickupMedKits(0)
    check sim.players[0].hp == sim.config.hitPoints
    check not sim.medKitSpawns[0].present
    check sim.medKitSpawns[1].present

  test "a healthy player never consumes a kit":
    var sim = twoTeamGame()
    sim.standOn(0, 0)
    sim.tryPickupMedKits(0)
    check sim.medKitSpawns[0].present
    check sim.players[0].hp == sim.config.hitPoints

  test "dead players cannot pick up a kit":
    var sim = twoTeamGame()
    sim.players[0].hp = 1
    sim.players[0].alive = false
    sim.standOn(0, 0)
    sim.tryPickupMedKits(0)
    check sim.medKitSpawns[0].present

  test "a taken kit respawns after its timer":
    var sim = twoTeamGame()
    sim.players[0].hp = 1
    sim.standOn(0, 0)
    sim.tryPickupMedKits(0)
    check not sim.medKitSpawns[0].present
    # Move the healed player away so the refilled kit is not retaken.
    sim.players[0].x = sim.players[0].homeX
    sim.players[0].y = sim.players[0].homeY
    let none = newSeq[InputState](sim.players.len)
    for _ in 0 ..< MedKitRespawnTicks + 1:
      sim.step(none, none)
    check sim.medKitSpawns[0].present

  test "med kit state is in the game hash":
    var sim1 = twoTeamGame()
    var sim2 = twoTeamGame()
    check sim1.gameHash == sim2.gameHash
    sim1.players[0].hp = 1
    sim1.standOn(0, 0)
    sim1.tryPickupMedKits(0)
    sim2.players[0].hp = 1
    check sim1.gameHash != sim2.gameHash
