import
  std/[os, sequtils, strutils, unittest],
  bitworld/spriteprotocol,
  ctf/[global, sim]

const GameDir = currentSourcePath.parentDir.parentDir

proc initCtfForTest(config: GameConfig): SimServer =
  ## Initializes the CTF sim from the game directory.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc mapLabels(sim: var SimServer): seq[string] =
  ## Builds one map-view sprite packet and returns its sprite labels.
  var
    state: GlobalViewerState
    nextState = initGlobalViewerState()
  let messages = sim.buildSpriteProtocolUpdates(state, nextState)
    .parseSpritePacket()
  for message in messages:
    if message.kind == spkSprite:
      result.add(message.sprite.label)

suite "floating damage numbers":
  test "a non-fatal shot leaves a fading -1 pop that a fatal shot's death does not remove":
    var game = initCtfForTest(defaultGameConfig())
    let
      shooter = game.addPlayer("red0")
      target = game.addPlayer("blue0")
    game.startGame()
    game.players[shooter].team = Red
    game.players[target].team = Blue
    # Shooter aims due east (brads 0) at a target a short distance right, with
    # spawn protection and cooldown cleared so the shot lands this tick.
    game.players[shooter].x = game.gameMap.center.x
    game.players[shooter].y = game.gameMap.center.y
    game.players[shooter].aimBrads = 0
    game.players[shooter].windupBrads = -1
    game.players[shooter].fireCooldown = 0
    game.players[shooter].spawnProtect = 0
    game.players[target].x = game.gameMap.center.x + 40
    game.players[target].y = game.gameMap.center.y
    game.players[target].spawnProtect = 0

    let hpBefore = game.players[target].hp
    check hpBefore >= 2                     # needs a non-fatal hit to survive.
    game.tryFire(shooter)
    check game.players[target].hp == hpBefore - 1
    check game.damagePops.len == 1
    check game.damagePops[0].amount == 1

    # The pop renders as a blue "-1" sprite in the map view.
    let labels = game.mapLabels()
    check labels.anyIt(it.startsWith("damage pop blue -1 stage 0"))

  test "the pop is cosmetic: it never enters the game hash":
    var a = initCtfForTest(defaultGameConfig())
    var b = initCtfForTest(defaultGameConfig())
    discard a.addPlayer("red0")
    discard b.addPlayer("red0")
    a.startGame()
    b.startGame()
    let hashBefore = a.gameHash()
    check hashBefore == b.gameHash()
    # Injecting a cosmetic pop into one sim must not diverge the hashes.
    a.damagePops.add DamageFx(
      x: 10, y: 10, tick: a.tickCount, amount: 2, color: a.players[0].color
    )
    check a.gameHash() == hashBefore
    check a.gameHash() == b.gameHash()

  test "pops expire after their cosmetic lifetime":
    var game = initCtfForTest(defaultGameConfig())
    # Two players on opposite teams so neither side is wiped (a lone team
    # would win by wipe and enter GameOver, which skips cosmetic pruning).
    let a = game.addPlayer("red0")
    let b = game.addPlayer("blue0")
    game.startGame()
    game.players[a].team = Red
    game.players[b].team = Blue
    game.damagePops.add DamageFx(
      x: 10, y: 10, tick: game.tickCount, amount: 1, color: game.players[a].color
    )
    check game.damagePops.len == 1
    let noInput = newSeq[InputState](game.players.len)
    for _ in 0 ..< DamageFxTicks + 2:
      game.step(noInput, noInput)
    check game.damagePops.len == 0
