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

proc fourTeamConfig(layout: string): GameConfig =
  result = defaultGameConfig()
  result.teams = 4
  result.mapPath = "gen"
  result.mapGen.layout = layout
  result.mapSeed = 42

proc fourTeamGame(layout = "corners"): SimServer =
  ## A started 4-team game with one player per team (slots deal mod 4).
  result = initCtfForTest(fourTeamConfig(layout))
  for i in 0 ..< 4:
    discard result.addPlayer("p" & $i)
  result.startGame()

proc centerOn(sim: var SimServer, playerIndex, x, y: int) =
  ## Places one player so its collision CENTER sits at (x, y).
  sim.players[playerIndex].x = x - CollisionW div 2
  sim.players[playerIndex].y = y - CollisionH div 2

suite "four team ctf":
  test "seats deal round all four teams":
    let sim = fourTeamGame()
    check sim.gameMap.teamCount() == 4
    check sim.teams() == Red .. Yellow
    for i in 0 ..< 4:
      check sim.players[i].team == Team(i)

  test "all four flags start home on their own pedestals":
    let sim = fourTeamGame()
    for team in sim.teams():
      let home = sim.gameMap.flagHome(team)
      check sim.flags[team].carrier == -1
      check sim.flags[team].x == home.x
      check sim.flags[team].y == home.y

  test "any enemy flag can be stolen, never your own":
    var sim = fourTeamGame()
    let greenHome = sim.gameMap.flagHome(Green)
    # Red walks onto the GREEN pedestal and takes the heart.
    sim.centerOn(0, greenHome.x, greenHome.y)
    sim.tryPickupFlags(0)
    check sim.flags[Green].carrier == 0
    check sim.players[0].carryingFlag
    # Green itself cannot interact with its own (returned) flag.
    sim.resetFlag(Green)
    sim.players[0].carryingFlag = false
    sim.centerOn(2, greenHome.x, greenHome.y)
    sim.tryPickupFlags(2)
    check sim.flags[Green].carrier == -1
    check not sim.players[2].carryingFlag

  test "a capture pays the winner +3 and each loser -1":
    var sim = fourTeamGame()
    let greenHome = sim.gameMap.flagHome(Green)
    sim.centerOn(0, greenHome.x, greenHome.y)
    sim.tryPickupFlags(0)
    check sim.flags[Green].carrier == 0
    # Carry it into Red's own capture zone.
    let anchor = sim.gameMap.teamAnchor(Red)
    sim.centerOn(0, anchor.x, anchor.y)
    sim.checkWinCondition()
    check sim.phase == GameOver
    check sim.winner == Red
    check not sim.isDraw
    check sim.players[0].reward == 3
    for i in 1 ..< 4:
      check sim.players[i].reward == -1

  test "the game continues at two teams and ends on the last survivor":
    var sim = fourTeamGame()
    # Wipe Green and Yellow: two teams still stand, the game goes on.
    for i in [2, 3]:
      sim.players[i].alive = false
      sim.players[i].lives = 0
    sim.checkWinCondition()
    check sim.phase == Playing
    # Wipe Blue too: Red is the last team standing and wins +3.
    sim.players[1].alive = false
    sim.players[1].lives = 0
    sim.checkWinCondition()
    check sim.phase == GameOver
    check sim.winner == Red
    check not sim.isDraw
    check sim.players[0].reward == 3
    check sim.players[1].reward == -1

  test "config round-trips teams and layout through replay JSON":
    let sim = fourTeamGame()
    var config = defaultGameConfig()
    config.update(sim.config.configJson())
    check config.teams == 4
    check config.mapSpec.len > 0
    let rebuilt = resolveCtfMapMetadata(config)
    check rebuilt.layout == layoutCorners
    check rebuilt.teamCount() == 4
    check rebuilt == sim.gameMap

  test "plus layout anchors the four teams on the four arms":
    let sim = fourTeamGame("plus")
    let gameMap = sim.gameMap
    check gameMap.layout == layoutPlus
    let
      red = gameMap.teamAnchor(Red)
      blue = gameMap.teamAnchor(Blue)
      green = gameMap.teamAnchor(Green)
      yellow = gameMap.teamAnchor(Yellow)
    check red.x < gameMap.center.x and red.y == gameMap.center.y
    check blue.x > gameMap.center.x and blue.y == gameMap.center.y
    check green.y < gameMap.center.y and green.x == gameMap.center.x
    check yellow.y > gameMap.center.y and yellow.x == gameMap.center.x
    # North team's capture zone is the arm mouth: bounded on y by the
    # anchor threshold and on x by the arm span (the corners are open
    # field, not endzone).
    let
      zone = gameMap.captureZone(Green)
      arm = gameMap.plusArmHalf()
    check zone.yHi < gameMap.height - 1
    check zone.xLo == gameMap.center.x - arm
    check zone.xHi == gameMap.center.x + arm

  test "corner endzones are diagonal":
    let sim = fourTeamGame()
    let zone = sim.gameMap.captureZone(Red)
    check zone.diag
    # The map corner itself is deep inside; the anchor is inside; a point
    # past the 45-degree threshold on one axis alone is not.
    check zone.inCaptureZone(ArenaBorder, ArenaBorder)
    let anchor = sim.gameMap.teamAnchor(Red)
    check zone.inCaptureZone(anchor.x, anchor.y)
    check not zone.inCaptureZone(zone.diagLimit - 5, zone.diagLimit - 5)

  test "a stepped 4-team episode is deterministic and respawns in-zone":
    proc runGame(): SimServer =
      result = initCtfForTest(fourTeamConfig("corners"))
      for i in 0 ..< 8:
        discard result.addPlayer("p" & $i)
      result.startGame()
      # Kill one player so the respawn path (diagonal-zone sampling) runs.
      result.killPlayer(5, 0)
      let none = newSeq[InputState](0)
      for tick in 0 ..< 400:
        result.step(none, none)
    var a = runGame()
    let b = runGame()
    check a.gameHash() == b.gameHash()
    check a.tickCount == b.tickCount
    # The killed player respawned somewhere inside its OWN diagonal zone.
    check a.players[5].alive
    let
      zone = a.gameMap.captureZone(a.players[5].team)
      cx = a.players[5].x + CollisionW div 2
      cy = a.players[5].y + CollisionH div 2
    check zone.inCaptureZone(cx, cy)

  test "bad 4-team configs fail loudly":
    var config = defaultGameConfig()
    expect CtfError:
      config.update("""{"teams": 3}""")
    expect CtfError:
      config.update("""{"teams": 4, "mapPath": "arena"}""")
    expect CtfError:
      config.update("""{"teams": 4, "mapPath": "pool"}""")
    expect CtfError:
      config.update("""{"teams": 2, "mapPath": "gen", "mapLayout": "corners"}""")
    expect CtfError:
      config.update(
        """{"teams": 4, "mapPath": "gen", "mapSymmetry": "mirror"}""")

  test "classic 2-team configs reject green and yellow slots":
    var config = defaultGameConfig()
    config.slots = @[PlayerSlotConfig(team: Green, hasTeam: true)]
    expect CtfError:
      config.update("""{"teams": 2}""")

suite "pot scoring":
  ## Every team antes one point; the winning team takes the whole pot and the
  ## losing teams split the forfeit. 2 teams: +2/-2. 4 teams: +4/-1/-1/-1.

  proc twoTeamPotGame(): SimServer =
    var config = defaultGameConfig()
    config.scoring = PotScoring
    result = initCtfForTest(config)
    for i in 0 ..< 2:
      discard result.addPlayer("p" & $i)
    result.startGame()

  proc fourTeamPotGame(): SimServer =
    var config = fourTeamConfig("corners")
    config.scoring = PotScoring
    result = initCtfForTest(config)
    for i in 0 ..< 4:
      discard result.addPlayer("p" & $i)
    result.startGame()

  test "classic scoring is the default and is untouched":
    check defaultGameConfig().scoring == ClassicScoring
    var sim = fourTeamGame()
    sim.players[1].alive = false
    sim.players[1].lives = 0
    for i in [2, 3]:
      sim.players[i].alive = false
      sim.players[i].lives = 0
    sim.checkWinCondition()
    check sim.winner == Red
    check sim.players[0].reward == 3
    for i in 1 ..< 4:
      check sim.players[i].reward == -1

  test "two teams pay the winner +2 and the loser -2":
    var sim = twoTeamPotGame()
    sim.players[1].alive = false
    sim.players[1].lives = 0
    sim.checkWinCondition()
    check sim.phase == GameOver
    check sim.winner == Red
    check sim.players[0].reward == 2
    check sim.players[1].reward == -2

  test "four teams pay the winner +4 and each loser -1":
    var sim = fourTeamPotGame()
    for i in 1 ..< 4:
      sim.players[i].alive = false
      sim.players[i].lives = 0
    sim.checkWinCondition()
    check sim.phase == GameOver
    check sim.winner == Red
    check sim.players[0].reward == 4
    for i in 1 ..< 4:
      check sim.players[i].reward == -1

  test "a time-limit draw still costs every player one point":
    var sim = fourTeamPotGame()
    sim.finishGame(Red, isDraw = true, timeLimitReached = true)
    check sim.isDraw
    for i in 0 ..< 4:
      check sim.players[i].reward == TimeoutReward

  test "scoring round-trips through replay JSON and rejects unknown rules":
    let sim = fourTeamPotGame()
    var config = defaultGameConfig()
    config.update(sim.config.configJson())
    check config.scoring == PotScoring
    var bad = defaultGameConfig()
    expect CtfError:
      bad.update("""{"scoring": "winner-take-all"}""")
