import
  std/[json, os, sequtils, unittest],
  ctf/[broadcast, replays, sim],
  "../tools/expand_replay"

const
  GameDir = currentSourcePath.parentDir.parentDir
  FixtureDir = GameDir / "tests" / "fixtures"
  # Fixtures are recorded against the CURRENT gameplay rules and must be
  # re-recorded on every GameVersion bump (tools/record_fixture.sh):
  #   capture-seed7:  record_fixture.sh <out> 7
  #   wipe-lives1:    record_fixture.sh <out> 7 10000 \
  #                     '{"lives":1,"hitPoints":1,"carrierSpeedPct":1}'
  #   draw-nokill:    record_fixture.sh <out> 7 1500 \
  #                     '{"hitPoints":1000,"carrierSpeedPct":1}'
  # (carrierSpeedPct 1 pins the flag so the wipe/draw endings cannot be
  # preempted by a capture; record on an otherwise idle machine — a
  # CPU-starved server at speed 16 drops its bots and ends degenerate.)
  # Then re-pin the capture winner asserted below to the new recording.
  CaptureFixture = FixtureDir / "capture-seed7.bitreplay"
  WipeFixture = FixtureDir / "wipe-lives1.bitreplay"
  DrawFixture = FixtureDir / "draw-nokill.bitreplay"

proc initFixtureSim(data: ReplayData): SimServer =
  ## Initializes a sim in the game dir so assets resolve.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    var config = defaultGameConfig()
    config.update(data.configJson)
    result = initSimServer(config)
    result.gameEventLoggingEnabled = false
  finally:
    setCurrentDir(previousDir)

type
  Beat = tuple[tick: int, key: string, a: int, b: int]

proc broadcastBeats(path: string): seq[Beat] =
  ## Steps a replay one tick at a time and collects broadcast.stepEvents,
  ## normalised to a comparable (tick, key, actorSlot, secondarySlot) tuple.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    let data = loadReplay(path)
    var
      sim = initFixtureSim(data)
      replay = initReplayPlayer(data)
      tracker = initBroadcastTracker()
    replay.looping = false
    replay.mismatchQuit = true
    # Prime the tracker on the pre-play state so the first step diffs cleanly.
    var warmup = newJArray()
    sim.stepEvents(tracker, warmup)
    while replay.playing:
      replay.stepReplay(sim)
      var events = newJArray()
      sim.stepEvents(tracker, events)
      for e in events:
        let k = e["k"].getStr
        case k
        of "kill":
          result.add((e["t"].getInt, "kill", e["killer"].getInt, e["victim"].getInt))
        of "respawn":
          result.add((e["t"].getInt, "respawn", e["who"].getInt, -1))
        of "steal":
          result.add((e["t"].getInt, "steal", e["by"].getInt, -1))
        of "return":
          result.add((e["t"].getInt, "return", -1, -1))
        of "capture":
          result.add((e["t"].getInt, "capture", e["by"].getInt, -1))
        of "gameover":
          result.add((e["t"].getInt, "gameover", -1, -1))
        else:
          discard
  finally:
    setCurrentDir(previousDir)

proc timelineBeats(path: string): seq[Beat] =
  ## Collects the same beats from the trusted expand_replay timeline.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    let timeline = expandReplayTimeline(loadReplay(path))
    for e in timeline.events:
      case e.kind
      of Kill:
        result.add((e.tick, "kill", e.actorSlot, e.secondarySlot))
      of Respawn:
        result.add((e.tick, "respawn", e.actorSlot, -1))
      of FlagSteal:
        result.add((e.tick, "steal", e.actorSlot, -1))
      of FlagReturnHome:
        result.add((e.tick, "return", -1, -1))
      of Capture:
        result.add((e.tick, "capture", e.actorSlot, -1))
      of GameOver:
        result.add((e.tick, "gameover", -1, -1))
      else:
        discard
  finally:
    setCurrentDir(previousDir)

suite "broadcast state channel":
  test "beat stream matches the expand_replay timeline (capture ending)":
    let
      mine = broadcastBeats(CaptureFixture)
      reference = timelineBeats(CaptureFixture)
    check mine == reference
    # Sanity: this fixture must actually contain the signature beats.
    check mine.anyIt(it.key == "capture")
    check mine.anyIt(it.key == "steal")
    check mine.anyIt(it.key == "gameover")

  test "beat stream matches the timeline (wipe ending)":
    check broadcastBeats(WipeFixture) == timelineBeats(WipeFixture)

  test "beat stream matches the timeline (draw ending)":
    check broadcastBeats(DrawFixture) == timelineBeats(DrawFixture)

  test "final frame state names the verdict honestly":
    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      let data = loadReplay(CaptureFixture)
      var
        sim = initFixtureSim(data)
        replay = initReplayPlayer(data)
        tracker = initBroadcastTracker()
      replay.looping = false
      replay.mismatchQuit = true
      while replay.playing:
        replay.stepReplay(sim)
        var events = newJArray()
        sim.stepEvents(tracker, events)
      let state = parseJson(sim.buildStateJson(
        newJArray(), false, 1, replay.replayMaxTick(), false, true, -1, -1
      ))
      check state["ph"].getStr == "gameover"
      check state.hasKey("over")
      # A capture win is not a draw and not a time-limit tiebreak. The winner
      # is pinned to the current recording of the fixture (GameVersion 20,
      # seed 7: Red captures).
      check state["over"]["draw"].getBool == false
      check state["over"]["timeLimit"].getBool == false
      check state["over"]["winner"].getStr == "red"
      # The scorebug axis is lives + flag state, never a kill score.
      check state["teams"]["red"].hasKey("lives")
      check state["teams"]["blue"]["flag"].getStr in ["home", "taken"]
    finally:
      setCurrentDir(previousDir)

  test "draw end-card reports a draw before any winner (F4)":
    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      let data = loadReplay(DrawFixture)
      var
        sim = initFixtureSim(data)
        replay = initReplayPlayer(data)
        tracker = initBroadcastTracker()
      replay.looping = false
      replay.mismatchQuit = true
      while replay.playing:
        replay.stepReplay(sim)
        var events = newJArray()
        sim.stepEvents(tracker, events)
      let state = parseJson(sim.buildStateJson(
        newJArray(), false, 1, replay.replayMaxTick(), false, true, -1, -1
      ))
      check state["over"]["draw"].getBool == true
    finally:
      setCurrentDir(previousDir)
