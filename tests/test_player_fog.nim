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

proc buildPlayerMessages(
  sim: var SimServer,
  playerIndex: int,
  state: var PlayerViewerState
): seq[SpritePacketMessage] =
  ## Builds and parses one sprite player packet.
  var nextState: PlayerViewerState
  result = sim.buildSpriteProtocolPlayerUpdates(
    playerIndex,
    state,
    nextState
  ).parseSpritePacket()
  state = nextState

proc spriteLabels(messages: openArray[SpritePacketMessage]): seq[string] =
  for message in messages:
    if message.kind == spkSprite:
      result.add(message.sprite.label)

proc hasObject(messages: openArray[SpritePacketMessage], objectId: int): bool =
  for message in messages:
    if message.kind == spkObject and message.objectDef.id == objectId:
      return true

suite "player fog-of-war protocol":
  test "full-map POV: fog runs, self marker, no arrows, fov-culled enemies":
    var game = initCtfForTest(defaultGameConfig())
    let viewer = game.addPlayer("red0")
    let foe = game.addPlayer("blue0")
    game.startGame()
    game.players[viewer].team = Red
    game.players[foe].team = Blue
    let
      cx = game.gameMap.center.x
      cy = game.gameMap.center.y
    # Viewer at the center aiming up the open corridor; enemy fogged behind.
    game.players[viewer].x = cx
    game.players[viewer].y = cy
    game.players[viewer].aimBrads = 64
    game.players[foe].x = cx
    game.players[foe].y = 550

    var state: PlayerViewerState
    let messages = game.buildPlayerMessages(viewer, state)
    let labels = messages.spriteLabels()

    # The old 128x128 shadow view and the flag arrows are gone.
    for label in labels:
      check not label.contains("arrow")
      check label != "shadow"
    # The fog overlay and the distinct self marker are present. The viewer reads
    # as a white-outlined rotating soldier (aim shown by the held gun's sweep),
    # not the retired floating aim dots — but the marker keeps the DOCUMENTED
    # `self <color> <side>` label (RULES.md) so exact-match label readers work.
    # Aim 64 (east-ish) faces right.
    check "fog" in labels
    check "self red right" in labels
    check labels.anyIt(it.startsWith("self red ") or it.startsWith("self blue "))
    # The map object sits at the origin: object coords are map coords.
    var mapAtOrigin = false
    for message in messages:
      if message.kind == spkObject and message.objectDef.id == 1 and
          message.objectDef.spriteId == 1:
        mapAtOrigin = message.objectDef.x == 0 and message.objectDef.y == 0
    check mapAtOrigin
    # The fogged enemy is culled; the viewer itself is present.
    check not messages.hasObject(1000 + game.players[foe].joinOrder)
    check messages.hasObject(1000 + game.players[viewer].joinOrder)
    # Both pedestal flags are always present (5009 red, 5010 blue).
    check messages.hasObject(5009)
    check messages.hasObject(5010)

    # Turn the viewer around: the enemy enters the cone and appears.
    game.players[viewer].aimBrads = 192
    let turned = game.buildPlayerMessages(viewer, state)
    check turned.hasObject(1000 + game.players[foe].joinOrder)

  test "teammates and a teammate-carried flag fog like enemies":
    var game = initCtfForTest(defaultGameConfig())
    let viewer = game.addPlayer("red0")
    discard game.addPlayer("blue0")
    let mate = game.addPlayer("red1")
    game.startGame()
    game.players[viewer].team = Red
    game.players[1].team = Blue
    game.players[mate].team = Red
    let
      cx = game.gameMap.center.x
      cy = game.gameMap.center.y
    game.players[viewer].x = cx
    game.players[viewer].y = cy
    game.players[viewer].aimBrads = 64
    # The teammate runs the stolen blue flag far behind the viewer.
    game.players[mate].x = cx
    game.players[mate].y = 550
    game.flags[Blue].carrier = mate
    game.players[mate].carryingFlag = true
    game.flags[Blue].x = cx
    game.flags[Blue].y = 550

    var state: PlayerViewerState
    # The mate is behind the viewer (aiming north): fogged, flag and all.
    let messages = game.buildPlayerMessages(viewer, state)
    check not messages.hasObject(1000 + game.players[mate].joinOrder)
    check not messages.hasObject(5010)

    # Turn around: the mate and its carried flag appear.
    game.players[viewer].aimBrads = 192
    var state2: PlayerViewerState
    let turned = game.buildPlayerMessages(viewer, state2)
    check turned.hasObject(1000 + game.players[mate].joinOrder)
    check turned.hasObject(5010)

  test "an unseen shot leaves a jittered sound ring; a seen shot does not":
    var game = initCtfForTest(defaultGameConfig())
    let viewer = game.addPlayer("red0")
    discard game.addPlayer("blue0")
    game.startGame()
    game.players[viewer].team = Red
    game.players[1].team = Blue
    let
      cx = game.gameMap.center.x
      cy = game.gameMap.center.y
    game.players[viewer].x = cx
    game.players[viewer].y = cy
    game.players[viewer].aimBrads = 64   # looking north.
    # A shot fired well behind the viewer, outside cone and bubble.
    game.recentShots.add ShotFx(
      x0: cx, y0: 550, x1: cx + 200, y1: 550,
      firedTick: game.tickCount, color: game.players[1].color
    )

    var state: PlayerViewerState
    let messages = game.buildPlayerMessages(viewer, state)
    check messages.hasObject(19100)      # the sound ring (SoundRingObjectBase).

    # Turn around: the shot itself is visible, so the ring disappears.
    game.players[viewer].aimBrads = 192
    var state2: PlayerViewerState
    let turned = game.buildPlayerMessages(viewer, state2)
    check not turned.hasObject(19100)
