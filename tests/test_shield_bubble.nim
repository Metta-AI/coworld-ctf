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
