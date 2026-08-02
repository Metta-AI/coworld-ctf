import
  helpers,
  std/unittest,
  bitworld/spriteprotocol,
  ctf/sim

proc runClockTo(sim: var SimServer, remaining: int) =
  ## Advances the raw tick counter so `remaining` ticks stay on the clock.
  sim.tickCount = sim.gameStartTick + sim.config.maxTicks - remaining

suite "action clock floor":
  test "a kill under the floor extends the clock to 500 remaining":
    var sim = twoTeamGame()
    check ActionClockFloorTicks == 500
    sim.runClockTo(100)
    sim.killPlayer(1, 0)
    check sim.overtimeTicks == ActionClockFloorTicks - 100
    check sim.effectiveMaxTicks() - sim.gameTicksElapsed() ==
      ActionClockFloorTicks

  test "a heart steal under the floor extends the clock":
    var sim = twoTeamGame()
    sim.runClockTo(1)
    # Stand player 0 on the enemy heart and steal it.
    sim.players[0].x = sim.flags[Blue].x - CollisionW div 2
    sim.players[0].y = sim.flags[Blue].y - CollisionH div 2
    sim.tryPickupFlags(0)
    check sim.flags[Blue].carrier == 0
    check sim.effectiveMaxTicks() - sim.gameTicksElapsed() ==
      ActionClockFloorTicks

  test "no extension while at least 500 ticks remain":
    var sim = twoTeamGame()
    sim.runClockTo(ActionClockFloorTicks + 50)
    sim.killPlayer(1, 0)
    check sim.overtimeTicks == 0
    check sim.effectiveMaxTicks() == sim.config.maxTicks

  test "repeated action keeps re-flooring the same game":
    var sim = twoTeamGame()
    sim.runClockTo(10)
    sim.killPlayer(1, 0)
    let firstOvertime = sim.overtimeTicks
    check firstOvertime == ActionClockFloorTicks - 10
    # 400 more ticks pass; another kill floors the clock again.
    sim.tickCount += 400
    sim.players[1].alive = true
    sim.killPlayer(1, 0)
    check sim.effectiveMaxTicks() - sim.gameTicksElapsed() ==
      ActionClockFloorTicks
    check sim.overtimeTicks > firstOvertime

  test "the extended game ends at the new deadline, not the old one":
    var sim = twoTeamGame()
    sim.runClockTo(100)
    sim.killPlayer(1, 0)
    let noInput = newSeq[InputState](sim.players.len)
    # Step past the ORIGINAL deadline: still playing.
    for _ in 1 .. 200:
      sim.step(noInput, noInput)
    check sim.phase == Playing
    # Step past the extended deadline: the game ends.
    for _ in 1 .. ActionClockFloorTicks:
      if sim.phase != Playing:
        break
      sim.step(noInput, noInput)
    check sim.phase != Playing
    check sim.timeLimitReached

  test "untimed games (maxTicks 0) never bank overtime":
    var config = defaultGameConfig()
    config.maxTicks = 0
    var sim = initCtfForTest(config)
    discard sim.addPlayer("red0")
    discard sim.addPlayer("blue0")
    sim.startGame()
    sim.killPlayer(1, 0)
    check sim.overtimeTicks == 0
    check sim.effectiveMaxTicks() == 0

  test "overtime is part of the game hash":
    var sim1 = twoTeamGame()
    var sim2 = twoTeamGame()
    check sim1.gameHash == sim2.gameHash
    sim1.overtimeTicks = 100
    check sim1.gameHash != sim2.gameHash
