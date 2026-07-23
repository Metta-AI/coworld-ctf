import
  std/[os, unittest],
  ctf/replays,
  ctf/sim

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
