import
  std/[json, os, unittest],
  bitworld/spriteprotocol,
  ctf/[global, replay_runtime, replays, sim]

const
  GameDir = currentSourcePath.parentDir.parentDir
  # A fresh, drama-complete fixture recorded against the CURRENT gameplay rules
  # (Phase-1 set, tools/record_fixture.sh). This capture-ending fixture
  # (re-recorded for the v6 glory economy, 2026-08-25, GLORY /proof wave --
  # over 2400 ticks) exceeds every tick target below and hash-verifies clean
  # end to end. Winner-pin held: still a RED capture (unchanged from the v5
  # recording), so no re-pin was needed here or in test_broadcast_state.nim.
  # Re-recorded AGAIN for GLORY v7 (2026-08-25, FIX WAVE E) -- 6,109 ticks,
  # still a RED capture, no re-pin needed.
  # Re-recorded AGAIN for GLORY v8 (2026-08-25, FAST BREAK wave -- the
  # hashed capturedFastBreak field moves gameHash) -- 1,534 ticks, still a
  # RED capture, no re-pin needed.
  # Re-recorded AGAIN for GLORYVERSION 9 (2026-08-26, LAW AUDIT wave -- the
  # new E2/E3 counters and hashed plumbing move gameHash): flipped to a BLUE
  # capture that pass (this comment block went stale and was not updated
  # then -- see test_broadcast_state.nim, which pinned the flip correctly at
  # the time; corrected here in the v10 pass below).
  # Re-recorded AGAIN for GLORYVERSION 10 (2026-08-26, `dLevelUp`
  # zero+tombstoned -- see glory.nim's own changelog): 8,547 ticks, STILL a
  # BLUE capture, no re-pin needed either here (no winner assertion in this
  # file) or in test_broadcast_state.nim.
  # (tests/replays/ctf.bitreplay is the event-substrate fixture: GameVersion
  # 24, seed 603 as of the v10 re-record, kills by gun and grenade — see
  # test_extract_events.)
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
