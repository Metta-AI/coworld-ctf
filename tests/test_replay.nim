import
  std/[json, os, unittest],
  bitworld/spriteprotocol,
  ctf/[global, replay_runtime, replays, sim]

const
  GameDir = currentSourcePath.parentDir.parentDir
  # A fresh, drama-complete fixture recorded against the CURRENT gameplay rules
  # (Phase-1 set, tools/record_fixture.sh). The legacy cert fixture
  # tests/replays/ctf.bitreplay predates the "3 hit points per life" change
  # (commit 0c34ade) and stores no hitPoints in its config, so replaying it
  # under today's defaultGameConfig() (HitPoints = 3) deterministically diverges
  # the instant combat starts (hash mismatch at tick 71) — it is stale, not a
  # bug in the replay engine. This capture-ending fixture exceeds every tick
  # target below and hash-verifies clean end to end.
  CtfReplayPath = GameDir / "tests" / "fixtures" / "capture-seed7.bitreplay"

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
      bytes = serializeReplaySim(sim)
      restored = deserializeReplaySim(bytes)

    check bytes.len > 0
    check restored.tickCount == sim.tickCount
    check restored.gameHash() == hash

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
