import
  std/[math, os, unittest],
  bitworld/spriteprotocol,
  ctf/sim

const GameDir = currentSourcePath().parentDir.parentDir

proc initCtfForTest(config: GameConfig): SimServer =
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc twoTeamGame(): SimServer =
  result = initCtfForTest(defaultGameConfig())
  discard result.addPlayer("red0")
  discard result.addPlayer("blue0")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Blue
  for i in 0 ..< result.players.len:
    result.players[i].spawnProtect = 0

proc none(sim: SimServer): seq[InputState] =
  newSeq[InputState](sim.players.len)

proc placeAtCenter(player: var Player, x, y: int) =
  player.x = x - CollisionW div 2
  player.y = y - CollisionH div 2

proc stepNone(sim: var SimServer, ticks: int) =
  let input = sim.none()
  for _ in 0 ..< ticks:
    sim.step(input, input)

suite "swords":
  test "two swords spawn at walkable side midpoints":
    let game = twoTeamGame()
    for i in 0 ..< game.swordSpawns.len:
      check game.swordSpawns[i].present
      check game.canOccupy(game.swordSpawns[i].x, game.swordSpawns[i].y)
      check abs(game.swordSpawns[i].y - MapHeight div 2) < 120
      if i == 0:
        check game.swordSpawns[i].x < MapWidth div 2
      else:
        check game.swordSpawns[i].x > MapWidth div 2

  test "pickup has a one-sword limit and respawns after 30 seconds":
    var game = twoTeamGame()
    let spawn = game.swordSpawns[0]
    game.players[0].placeAtCenter(spawn.x, spawn.y)
    game.tryPickupSwords(0)
    check game.players[0].hasSword
    check not game.swordSpawns[0].present
    game.players[1].placeAtCenter(game.swordSpawns[1].x, game.swordSpawns[1].y)
    game.tryPickupSwords(1)
    check game.players[1].hasSword
    game.players[0].placeAtCenter(spawn.x, spawn.y)
    game.tryPickupSwords(0)
    check game.players[0].hasSword
    game.players[0].placeAtCenter(400, 400)
    game.stepNone(SwordRespawnTicks)
    check game.swordSpawns[0].present

  test "a carried sword is lost on death":
    var game = twoTeamGame()
    game.players[0].hasSword = true
    game.killPlayer(0, 1)
    check not game.players[0].hasSword

  test "a sword carrier cannot fire":
    var game = twoTeamGame()
    game.players[0].hasSword = true
    game.players[1].placeAtCenter(game.players[0].x + 100, game.players[0].y)
    check not game.canFire(0)
    game.tryFire(0)
    check game.players[1].alive

  test "a swing kills a target in the forward arc and credits the attacker":
    var game = twoTeamGame()
    game.players[0].hasSword = true
    game.players[0].aimBrads = 0
    let ax = game.players[0].x + CollisionW div 2
    let ay = game.players[0].y + CollisionH div 2
    game.players[1].placeAtCenter(ax + SwordRange - 2, ay)
    game.trySwing(0)
    check not game.players[1].alive
    check game.players[0].kills == 1
    check game.swordSwipes.len == 1

  test "a swing misses behind, outside the arc, and beyond range":
    var game = twoTeamGame()
    game.players[0].hasSword = true
    game.players[0].aimBrads = 0
    let
      ax = game.players[0].x + CollisionW div 2
      ay = game.players[0].y + CollisionH div 2
    game.players[1].placeAtCenter(ax - SwordRange + 2, ay)
    game.trySwing(0)
    check game.players[1].alive
    game.players[0].fireCooldown = 0
    game.players[1].placeAtCenter(ax + 15, ay + SwordRange)
    game.trySwing(0)
    check game.players[1].alive
    game.players[0].fireCooldown = 0
    game.players[1].placeAtCenter(ax + SwordRange + 10, ay)
    game.trySwing(0)
    check game.players[1].alive

  test "spawn protection shields a target but friendly fire does not":
    var game = twoTeamGame()
    game.players[0].hasSword = true
    game.players[0].aimBrads = 0
    let
      ax = game.players[0].x + CollisionW div 2
      ay = game.players[0].y + CollisionH div 2
    game.players[1].placeAtCenter(ax + SwordRange - 2, ay)
    game.players[1].spawnProtect = 1
    game.trySwing(0)
    check game.players[1].alive
    game.players[0].fireCooldown = 0
    game.players[1].spawnProtect = 0
    game.players[1].team = game.players[0].team
    game.trySwing(0)
    check not game.players[1].alive
    check game.players[0].kills == 1

  test "same-tick swings can kill each other":
    var game = twoTeamGame()
    game.players[0].hasSword = true
    game.players[1].hasSword = true
    game.players[0].aimBrads = 0
    game.players[1].aimBrads = 128
    let
      ax = game.players[0].x + CollisionW div 2
      ay = game.players[0].y + CollisionH div 2
    game.players[0].placeAtCenter(ax, ay)
    game.players[1].placeAtCenter(ax + SwordRange - 2, ay)
    game.resolveSimultaneousSwings([0, 1])
    check not game.players[0].alive
    check not game.players[1].alive
    check game.players[0].kills == 1
    check game.players[1].kills == 1

  test "sword state is in the game hash":
    var game = twoTeamGame()
    let initial = game.gameHash()
    game.players[0].hasSword = true
    check game.gameHash() != initial
    let carried = game.gameHash()
    game.players[0].hasSword = false
    game.swordSpawns[0].present = not game.swordSpawns[0].present
    check game.gameHash() != carried
