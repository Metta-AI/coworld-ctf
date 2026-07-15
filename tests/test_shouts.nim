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

suite "shouts":
  test "a shout is stored with player, team, and shout-time coordinates":
    var sim = twoTeamGame()
    check sim.applyShout(0, "push mid")
    check sim.recentShouts.len == 1
    let shout = sim.recentShouts[0]
    check shout.address == "red0"
    check shout.team == Red
    check shout.text == "push mid"
    check shout.tick == sim.tickCount
    check shout.x == sim.players[0].x + CollisionW div 2
    check shout.y == sim.players[0].y + CollisionH div 2

  test "shouts are truncated to the limit and sanitized":
    var sim = twoTeamGame()
    check sim.applyShout(0, "0123456789ABCDEF")
    check sim.recentShouts[0].text == "0123456789"
    check sim.recentShouts[0].text.len == ShoutMaxChars
    # Control characters are dropped; whitespace-only shouts are ignored.
    sim.players[1].lastShoutTick = -1
    check not sim.applyShout(1, "\x01\x02   \n")

  test "dead players cannot shout":
    var sim = twoTeamGame()
    sim.players[0].alive = false
    check not sim.applyShout(0, "ghost")
    check sim.recentShouts.len == 0

  test "shouting is rate limited and replaces the previous bubble":
    var sim = twoTeamGame()
    check sim.applyShout(0, "first")
    check not sim.applyShout(0, "too soon")
    check sim.recentShouts.len == 1
    check sim.recentShouts[0].text == "first"
    # After the cooldown a new shout replaces the old bubble.
    let none = newSeq[InputState](sim.players.len)
    for _ in 0 ..< ShoutCooldownTicks:
      sim.step(none, none)
    check sim.applyShout(0, "second")
    check sim.recentShouts.len == 1
    check sim.recentShouts[0].text == "second"

  test "shouts expire after their display window":
    var sim = twoTeamGame()
    check sim.applyShout(0, "brief")
    let none = newSeq[InputState](sim.players.len)
    for _ in 0 ..< ShoutTicks:
      sim.step(none, none)
    check sim.recentShouts.len == 0

  test "shouts are audible within range, through walls, but not to the dead":
    var sim = twoTeamGame()
    check sim.applyShout(0, "here")
    let shout = sim.recentShouts[0]
    # The shouter hears its own shout.
    check sim.shoutAudibleTo(0, shout)
    # A viewer just inside the radius hears it; just outside does not.
    sim.players[1].x = shout.x + ShoutRange - 1 - CollisionW div 2
    sim.players[1].y = shout.y - CollisionH div 2
    check sim.shoutAudibleTo(1, shout)
    sim.players[1].x = shout.x + ShoutRange + 1 - CollisionW div 2
    check not sim.shoutAudibleTo(1, shout)
    # Dead viewers observe nothing.
    sim.players[1].x = shout.x - CollisionW div 2
    sim.players[1].alive = false
    check not sim.shoutAudibleTo(1, shout)

  test "shouts are part of the game hash":
    var sim1 = twoTeamGame()
    var sim2 = twoTeamGame()
    check sim1.gameHash == sim2.gameHash
    sim1.applyShout(0, "flank left")
    check sim1.gameHash != sim2.gameHash
    sim2.applyShout(0, "flank left")
    check sim1.gameHash == sim2.gameHash
