import
  helpers,
  std/[os, unittest],
  bitworld/spriteprotocol,
  ctf/[global, sim]

const
  ReplayTickObjectId = 4002
  ReplayControlsObjectId = 4003
  ReplayScrubberObjectId = 4004
  ReplayCenterBottomLayerId = 8
  ReplayBottomLeftLayerId = 9
  ReplayMismatchLayerId = 10

proc initCrewriftForTest(config: GameConfig): SimServer =
  ## Initializes Crewrift from the game directory.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc clickReplayLayer(
  state: var GlobalViewerState,
  layer, x, y: int
) =
  ## Queues one replay click on a browser-visible replay UI layer.
  state.mouseLayer = layer
  state.mouseX = x
  state.mouseY = y
  state.mouseDown = false
  state.clickPending = true

proc packetHasObject(packet: openArray[uint8], objectId: int): bool =
  ## Returns true when a sprite packet contains one object id.
  for message in packet.parseSpritePacket():
    if message.kind == spkObject and message.objectDef.id == objectId:
      return true

suite "replay controls":
  test "transport and scrubber use split browser hit layers":
    var game = initCrewriftForTest(defaultGameConfig())
    var state = initGlobalViewerState()
    var next: GlobalViewerState

    discard game.buildSpriteProtocolUpdates(
      state,
      next,
      @[],
      replayTick = 100,
      replayPlaying = true,
      replaySpeed = 1,
      replayMaxTick = 1000,
      replayLooping = false,
      replayEnabled = true
    )
    state = next

    state.clickReplayLayer(ReplayBottomLeftLayerId, 11, 2)
    discard game.buildSpriteProtocolUpdates(
      state,
      next,
      @[],
      replayTick = 100,
      replayPlaying = true,
      replaySpeed = 1,
      replayMaxTick = 1000,
      replayLooping = false,
      replayEnabled = true
    )
    check next.replayCommands == @[' ']
    check next.replaySeekTick == -1

    state = next
    state.replayCommands.setLen(0)
    state.replaySeekTick = -1
    state.clickReplayLayer(ReplayCenterBottomLayerId, 64, 10)
    discard game.buildSpriteProtocolUpdates(
      state,
      next,
      @[],
      replayTick = 100,
      replayPlaying = false,
      replaySpeed = 1,
      replayMaxTick = 1000,
      replayLooping = false,
      replayEnabled = true
    )
    check next.replayCommands.len == 0
    check next.replaySeekTick == 506

    state = next
    state.replayCommands.setLen(0)
    state.replaySeekTick = -1
    state.clickReplayLayer(ReplayCenterBottomLayerId, 11, 2)
    discard game.buildSpriteProtocolUpdates(
      state,
      next,
      @[],
      replayTick = 506,
      replayPlaying = false,
      replaySpeed = 1,
      replayMaxTick = 1000,
      replayLooping = false,
      replayEnabled = true
    )
    check next.replayCommands.len == 0
    check next.replaySeekTick == -1

  test "replay controls are hidden during live spectating":
    var game = initCrewriftForTest(defaultGameConfig())
    var state = initGlobalViewerState()
    var next: GlobalViewerState

    let packet = game.buildSpriteProtocolUpdates(
      state,
      next,
      @[],
      replayTick = 100,
      replayPlaying = true,
      replaySpeed = 1,
      replayMaxTick = 1000,
      replayLooping = false,
      replayEnabled = false
    )
    check not packet.packetHasObject(ReplayTickObjectId)
    check not packet.packetHasObject(ReplayControlsObjectId)
    check not packet.packetHasObject(ReplayScrubberObjectId)

    state = next
    state.clickReplayLayer(ReplayBottomLeftLayerId, 11, 2)
    discard game.buildSpriteProtocolUpdates(
      state,
      next,
      @[],
      replayTick = 100,
      replayPlaying = true,
      replaySpeed = 1,
      replayMaxTick = 1000,
      replayLooping = false,
      replayEnabled = false
    )
    check next.replayCommands.len == 0
    check next.replaySeekTick == -1

  test "hash mismatch warning is shown in the top center layer, tiered":
    ## Two tiers (src/ctf/build_stamp.nim): without a proven same-build
    ## stamp the warning is the quiet cross-build chip; with one it is the
    ## loud determinism-break banner. Both live in the same top-center slot.
    var game = initCrewriftForTest(defaultGameConfig())

    proc mismatchPacket(sameBuild: bool): seq[uint8] =
      var state = initGlobalViewerState()
      var next: GlobalViewerState
      game.buildSpriteProtocolUpdates(
        state,
        next,
        @[],
        replayTick = 1208,
        replayPlaying = true,
        replaySpeed = 1,
        replayMaxTick = 2000,
        replayLooping = false,
        replayEnabled = true,
        replayMismatchTick = 1208,
        replayMismatchSameBuild = sameBuild
      )

    for (sameBuild, expectedLabel) in [
      (false, "recorded inputs - different engine build"),
      (true, "hash mismatch at tick 1208")
    ]:
      var
        foundSprite = false
        foundObject = false
      for message in mismatchPacket(sameBuild).parseSpritePacket():
        if message.kind == spkSprite and
            message.sprite.label == expectedLabel:
          foundSprite = true
        if message.kind == spkObject and
            message.objectDef.layer == ReplayMismatchLayerId:
          foundObject = true
      checkpoint "sameBuild=" & $sameBuild
      check foundSprite
      check foundObject
