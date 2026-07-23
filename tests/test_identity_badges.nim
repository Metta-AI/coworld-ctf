import
  std/[os, tables, unittest],
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

proc playerMessages(
  sim: var SimServer,
  playerIndex: int
): seq[SpritePacketMessage] =
  var state, nextState: PlayerViewerState
  sim.buildSpriteProtocolPlayerUpdates(playerIndex, state, nextState)
    .parseSpritePacket()

proc presentLabels(messages: openArray[SpritePacketMessage]): seq[string] =
  ## Labels of every sprite referenced by a present object.
  var idLabels: Table[int, string]
  for m in messages:
    if m.kind == spkSprite:
      idLabels[m.sprite.id.int] = m.sprite.label
  for m in messages:
    if m.kind == spkObject:
      let label = idLabels.getOrDefault(m.objectDef.spriteId.int, "")
      if label.len > 0:
        result.add(label)

suite "identity badges":
  test "identities assign alpha..theta by slot order within each team":
    # Identity derives from the slot config alone — no players needed.
    # Default slots alternate red/blue: 0=red alpha, 1=blue alpha,
    # 2=red beta, 3=blue beta.
    var game = initCtfForTest(defaultGameConfig())
    check game.slotIdentityIndex(0) == 0
    check game.slotIdentityIndex(1) == 0
    check game.slotIdentityIndex(2) == 1
    check game.slotIdentityIndex(3) == 1

  test "a visible enemy's identity badge is in the observation":
    var game = initCtfForTest(defaultGameConfig())
    let
      viewer = game.addPlayer("red0")
      foe = game.addPlayer("blue0")
    game.startGame()
    game.players[viewer].team = Red
    game.players[foe].team = Blue
    let
      cx = game.gameMap.center.x
      cy = game.gameMap.center.y
    # Enemy directly inside the viewer's aim cone so it renders.
    game.players[viewer].x = cx
    game.players[viewer].y = cy
    game.players[viewer].aimBrads = 64
    game.players[foe].x = cx
    game.players[foe].y = cy - 40

    let labels = game.playerMessages(viewer).presentLabels()
    check "identity blue alpha" in labels
    check "identity red alpha" in labels  # yourself: always visible

  test "a fogged enemy's identity badge is not in the observation":
    var game = initCtfForTest(defaultGameConfig())
    let
      viewer = game.addPlayer("red0")
      foe = game.addPlayer("blue0")
    game.startGame()
    game.players[viewer].team = Red
    game.players[foe].team = Blue
    let
      cx = game.gameMap.center.x
      cy = game.gameMap.center.y
    # Enemy far BEHIND the viewer's aim: outside cone and bubble.
    game.players[viewer].x = cx
    game.players[viewer].y = cy
    game.players[viewer].aimBrads = 64  # aiming north
    game.players[foe].x = cx
    game.players[foe].y = cy + 300      # deep south

    let labels = game.playerMessages(viewer).presentLabels()
    check "identity blue alpha" notin labels

  test "a dead player's identity badge disappears":
    var game = initCtfForTest(defaultGameConfig())
    let
      viewer = game.addPlayer("red0")
      foe = game.addPlayer("blue0")
    game.startGame()
    game.players[viewer].team = Red
    game.players[foe].team = Blue
    game.players[foe].alive = false
    game.players[foe].hp = 0
    game.players[viewer].alive = false  # ghost viewer sees everything
    game.players[viewer].hp = 0

    let labels = game.playerMessages(viewer).presentLabels()
    check "identity blue alpha" notin labels
