import
  helpers,
  std/[json, os, unittest],
  bitworld/spriteprotocol,
  ctf/[global, replay_runtime, replays, sim]

const
  # A fresh, drama-complete fixture recorded against the CURRENT gameplay rules
  # (GameVersion 35, seed 1, tools/record_fixture.sh). This capture-ending
  # fixture exceeds every tick target below and hash-verifies clean end to end.
  # (tests/replays/ctf.bitreplay is the event-substrate fixture:
  # GameVersion 35, seed 902, lives 9 — see
  # test_extract_events.)
  CtfReplayPath = GameDir / "tests" / "fixtures" / "capture-seed1.bitreplay"

proc initReplaySim(data: ReplayData): SimServer =
  ## Initializes a replay simulation from the replay config JSON.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    var config = defaultGameConfig()
    config.update(data.configJson)
    result = initSimServer(config)
    result.gameEventLoggingEnabled = false
  finally:
    setCurrentDir(previousDir)

suite "ctf replay":
  test "shared runtime initializes, advances, controls, and renders replay":
    let
      data = loadReplay(CtfReplayPath)
      previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    var runtime: InitializedReplay
    try:
      runtime = initReplayRuntime(
        data,
        mismatchQuit = true,
        gameEventLoggingEnabled = false
      )
    finally:
      setCurrentDir(previousDir)

    check runtime.player.playing
    check runtime.sim.tickCount == runtime.player.replayStartTick()
    check not runtime.sim.gameEventLoggingEnabled

    let tickBefore = runtime.sim.tickCount
    discard runtime.player.advanceReplayFrame(
      runtime.sim,
      runtime.tracker,
      newSeq[int](),
      @['6']
    )
    check runtime.player.replaySpeed() == 16
    check runtime.sim.tickCount == tickBefore + 16

    var
      viewer = initGlobalViewerState()
      nextViewer: GlobalViewerState
    let packet = runtime.sim.buildReplayViewerPacket(
      runtime.player,
      viewer,
      nextViewer,
      newJArray()
    )
    var chrome: JsonNode
    for message in packet.parseSpritePacket():
      if message.kind == spkSprite and
          message.sprite.id == BroadcastChromeSpriteId:
        chrome = message.sprite.label.parseJson()
    check packet.len > 0
    check not chrome.isNil
    check chrome["t"].getInt() == runtime.sim.tickCount
    check chrome["en"].getBool()
    check nextViewer.momentumSent

    runtime.player.seekReplay(runtime.sim, runtime.player.replayMaxTick())
    runtime.player.endHoldFrames = ReplayFps * 2
    var holdViewer: GlobalViewerState
    let holdPacket = runtime.sim.buildReplayViewerPacket(
      runtime.player,
      nextViewer,
      holdViewer,
      newJArray()
    )
    var holdChrome: JsonNode
    for message in holdPacket.parseSpritePacket():
      if message.kind == spkSprite and
          message.sprite.id == BroadcastChromeSpriteId:
        holdChrome = message.sprite.label.parseJson()
    check not holdChrome.isNil
    check holdChrome["hold"].getInt() == 2

    let seekTick = runtime.player.replayStartTick() + 20
    discard runtime.player.advanceReplayFrame(
      runtime.sim,
      runtime.tracker,
      @[seekTick],
      newSeq[char]()
    )
    check runtime.sim.tickCount == seekTick
    check not runtime.player.playing
    check runtime.player.endHoldFrames == 0

  test "sim serializes with flatty":
    let data = loadReplay(CtfReplayPath)
    var
      sim = data.initReplaySim()
      replay = initReplayPlayer(data)
    replay.looping = false
    replay.mismatchQuit = true

    while sim.tickCount < 250:
      replay.stepReplay(sim)

    let
      hash = sim.gameHash()
      mapBakeBytes = sim.mapPixels.len + sim.mapRgba.len +
        sim.darkBgPixels.len + sim.walkMask.len
      bytes = serializeReplaySim(sim)

    check bytes.len > 0
    # Keyframes must EXCLUDE the static map bakes: serializing them into
    # every keyframe cost ~40 MB x ~55 keyframes on giant maps, more than
    # the wasm32 replay viewer can address at all. The whole keyframe must
    # come out smaller than the bakes it stripped...
    check bytes.len < mapBakeBytes
    # ...while the serialized sim itself reads back untouched.
    check sim.gameHash() == hash
    check sim.mapPixels.len > 0

    let restored = deserializeReplaySim(bytes, sim)
    check restored.tickCount == sim.tickCount
    check restored.gameHash() == hash
    # The donor's bakes moved into the restored sim.
    check restored.mapPixels.len > 0

  test "keyframed seek restores matching state":
    let data = loadReplay(CtfReplayPath)
    var
      baseline = data.initReplaySim()
      baselineReplay = initReplayPlayer(data)
      sim = data.initReplaySim()
      replay = initReplayPlayer(data)
    baselineReplay.looping = false
    baselineReplay.mismatchQuit = true
    replay.looping = false
    replay.mismatchQuit = true

    let target = 300
    while baseline.tickCount < target:
      baselineReplay.stepReplay(baseline)
    let hash = baseline.gameHash()

    replay.buildReplayKeyframes(sim)
    replay.seekReplay(sim, target)

    check replay.keyframes.len > 1
    check sim.tickCount == target
    check sim.gameHash() == hash

  test "hashes match":
    let data = loadReplay(CtfReplayPath)
    var
      sim = data.initReplaySim()
      replay = initReplayPlayer(data)
    replay.looping = false
    replay.mismatchQuit = true

    while replay.playing:
      replay.stepReplay(sim)

    check replay.hashIndex == data.hashes.len
    check not replay.hashValidationFailed
    check replay.hashMismatchTick == -1
    check sim.tickCount >= int(data.hashes[^1].tick)
