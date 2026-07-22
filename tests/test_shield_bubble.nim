import
  std/[os, unittest],
  bitworld/spriteprotocol,
  ctf/[global, sim]

const
  GameDir = currentSourcePath.parentDir.parentDir
  ShieldBubbleObjectBase = 19680

proc initCtfForTest(config: GameConfig): SimServer =
  ## Initializes the CTF sim from the game directory.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc buildGlobalMessages(
  sim: var SimServer,
  state: var GlobalViewerState
): seq[SpritePacketMessage] =
  ## Builds and parses one global viewer sprite packet. Renders from the game
  ## directory so lazily-loaded sprite PNGs (hearts, shields) resolve.
  var nextState: GlobalViewerState
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = sim.buildSpriteProtocolUpdates(state, nextState).parseSpritePacket()
  finally:
    setCurrentDir(previousDir)
  state = nextState

proc hasObject(messages: openArray[SpritePacketMessage], objectId: int): bool =
  for message in messages:
    if message.kind == spkObject and message.objectDef.id == objectId:
      return true

proc objectSpriteId(
  messages: openArray[SpritePacketMessage],
  objectId: int
): int =
  ## Returns the sprite id an object draws with, or -1 when absent.
  result = -1
  for message in messages:
    if message.kind == spkObject and message.objectDef.id == objectId:
      return message.objectDef.spriteId

const
  ShieldBubbleSpriteId = 1422
  ShieldBubbleDeformBase = 1424
  ShieldBubbleDeformCount = 16 * 4

suite "shield carrier bubble":
  test "bubble appears on pickup and pops below 4 hp":
    var game = initCtfForTest(defaultGameConfig())
    let red = game.addPlayer("red0")
    discard game.addPlayer("blue0")
    game.startGame()

    var state = initGlobalViewerState()
    # No shield yet: no bubble.
    var messages = game.buildGlobalMessages(state)
    check not messages.hasObject(ShieldBubbleObjectBase + red)

    # A fresh carrier (ShieldHitPoints = 6) shows the bubble.
    game.players[red].hasShield = true
    game.players[red].hp = 6
    messages = game.buildGlobalMessages(state)
    check messages.hasObject(ShieldBubbleObjectBase + red)

    # Worn down but still holding bonus hp: the bubble stays at exactly 4.
    game.players[red].hp = 4
    messages = game.buildGlobalMessages(state)
    check messages.hasObject(ShieldBubbleObjectBase + red)

    # Below 4 hp the bubble pops (the small carry marker may remain).
    game.players[red].hp = 3
    messages = game.buildGlobalMessages(state)
    check not messages.hasObject(ShieldBubbleObjectBase + red)

    # Dead carriers never show a bubble.
    game.players[red].hp = 6
    game.players[red].alive = false
    messages = game.buildGlobalMessages(state)
    check not messages.hasObject(ShieldBubbleObjectBase + red)

  test "a hit on the bubble blinks the bubble instead of the body FX":
    var game = initCtfForTest(defaultGameConfig())
    let
      red = game.addPlayer("red0")
      blue = game.addPlayer("blue0")
    game.startGame()
    game.players[red].team = Red
    game.players[blue].team = Blue
    for i in 0 ..< game.players.len:
      game.players[i].spawnProtect = 0
    # Blue shoots the bubbled carrier from the east (like test_shields).
    game.players[red].x = 300
    game.players[red].y = 300
    game.players[red].hasShield = true
    game.players[red].hp = 6
    game.players[blue].x = 300 + 30
    game.players[blue].y = 300
    game.players[blue].aimBrads = 128
    game.players[blue].fireCooldown = 0
    game.tryFire(blue)

    # The hit lands (hp 6 -> 5) but the body FX are absorbed by the bubble:
    # no struck-target flash, no body paint spark — a bubble impact instead
    # (the "-1" pop still reports the damage).
    check game.players[red].hp == 5
    check game.bubbleImpacts.len == 1
    check game.bubbleImpacts[0].playerIndex == red
    check game.hitFlashes.len == 0
    check game.splatters.len == 0
    check game.damagePops.len == 1

    # The bubble object now draws a blink/dent variant, not the idle ring.
    var state = initGlobalViewerState()
    var messages = game.buildGlobalMessages(state)
    let hitSprite = messages.objectSpriteId(ShieldBubbleObjectBase + red)
    check hitSprite >= ShieldBubbleDeformBase
    check hitSprite < ShieldBubbleDeformBase + ShieldBubbleDeformCount

    # Once the impact FX window passes, the bubble eases back to idle.
    let none = newSeq[InputState](game.players.len)
    for _ in 0 ..< BubbleImpactTicks + 1:
      game.step(none, none)
    messages = game.buildGlobalMessages(state)
    check messages.objectSpriteId(ShieldBubbleObjectBase + red) ==
      ShieldBubbleSpriteId

  test "a hit below the bubble threshold keeps the normal body FX":
    var game = initCtfForTest(defaultGameConfig())
    let
      red = game.addPlayer("red0")
      blue = game.addPlayer("blue0")
    game.startGame()
    game.players[red].team = Red
    game.players[blue].team = Blue
    for i in 0 ..< game.players.len:
      game.players[i].spawnProtect = 0
    # The carrier is already worn below the bubble threshold: no bubble, so
    # the ordinary struck-target flash and paint spark show as always.
    game.players[red].x = 300
    game.players[red].y = 300
    game.players[red].hasShield = true
    game.players[red].hp = 3
    game.players[blue].x = 300 + 30
    game.players[blue].y = 300
    game.players[blue].aimBrads = 128
    game.players[blue].fireCooldown = 0
    game.tryFire(blue)

    check game.players[red].hp == 2
    check game.bubbleImpacts.len == 0
    check game.hitFlashes.len == 1
    check game.splatters.len == 1
