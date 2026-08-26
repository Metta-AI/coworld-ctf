import
  std/[json, os, sequtils, unittest],
  ctf/[broadcast, glory, replays, sim],
  "../tools/expand_replay"

const
  GameDir = currentSourcePath.parentDir.parentDir
  FixtureDir = GameDir / "tests" / "fixtures"
  # Fixtures are recorded against the CURRENT gameplay rules and must be
  # re-recorded on every GameVersion bump (tools/record_fixture.sh):
  #   capture-seed7:  record_fixture.sh <out> 7
  #   wipe-lives1:    record_fixture.sh <out> 12 10000 \
  #                     '{"lives":1,"hitPoints":1,"carrierSpeedPct":1}'
  #   draw-nokill:    record_fixture.sh <out> 7 1500 \
  #                     '{"hitPoints":1000,"carrierSpeedPct":1}'
  # (carrierSpeedPct 1 pins the flag so the wipe/draw endings cannot be
  # preempted by a capture; record on an otherwise idle machine — a
  # CPU-starved server at speed 16 drops its bots and ends degenerate.)
  # wipe-lives1 moved off seed 7 in the /proof engine-lane cycle
  # (2026-08-24): under that baseline matchup seed 7 resolved as a MUTUAL
  # wipe (a draw, dWipe never mints), which defeats this fixture's whole
  # purpose -- seed 9 was the first tried that resolved as a clean
  # one-sided wipe THEN. Moved AGAIN in the v6 GLORY /proof wave
  # (2026-08-25): seed 9 itself now resolves as a mutual-wipe draw under the
  # v6 economy (bot connection order is not fully deterministic across
  # recordings even at a fixed seed, and the tuned buffs/xp this wave shipped
  # can shift which team survives longer) -- seed 12 was the seed that
  # resolved clean THEN. Moved AGAIN in GLORY v7 (2026-08-25, FIX WAVE E):
  # seed 12 itself now resolves as a mutual-wipe draw under v7's re-fit
  # LevelThresholds and reordered curricula (12, 13, 14, 16 all tried and
  # drew; 9 won by capture, not a wipe) -- seed 15 is the seed that resolved
  # a clean one-sided wipe THEN. Re-recorded again for GLORY v8 (2026-08-25,
  # FAST BREAK wave -- the hashed capturedFastBreak field moves gameHash, so
  # every fixture needs a fresh recording even though this fixture's own
  # scenario (lives:1, no carrier) never touches the flag): seed 15 held,
  # still a clean one-sided wipe, but BLUE this time, not RED -- no test
  # below pins a specific winning team for this fixture, only that it is a
  # clean (non-draw) wipe, so no assertion needed re-pinning. Re-recorded
  # AGAIN for GLORYVERSION 9 (2026-08-26, LAW AUDIT wave -- the new E2/E3
  # counters and hashed plumbing move gameHash): seed 15 now resolves as a
  # mutual-wipe draw again (9, 13, 16 also tried and drew) -- seed 12 (the
  # v6-era seed) is the one that came back clean this time, RED by wipe. Pick
  # a seed by outcome, not by habit: try a few and read the herald log's last
  # line before committing a recording. Then re-pin the capture winner
  # asserted below to the new recording.
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
        of "achv":
          # Cross-checks broadcast's "achv" wire kind (read straight off
          # sim.achievementFeed) against expand_replay's OWN independent read
          # of the same feed (tools/expand_replay.nim's Achievement kind,
          # STAGE 5). (tier, slot) is the fingerprint both sides carry --
          # not team/tree/glory/first too, since broadcast's payload is a
          # fixed wire shape this suite may not widen.
          result.add((e["t"].getInt, "achv", e["tier"].getInt, e["slot"].getInt))
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
      of Achievement:
        result.add((e.tick, "achv", e.achvTier, e.actorSlot))
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
      # is pinned to the current recording of the fixture (/proof engine-lane
      # cycle, 2026-08-24: Red captures -- flipped from Blue on this
      # re-record; nothing in that cycle touched combat/movement, so this is
      # ordinary bot-connection-order variance across recordings, not a
      # gameplay regression. Re-pin on every re-record). Re-recorded again
      # for GLORY v7 (2026-08-25, FIX WAVE E) -- still a RED capture, no
      # re-pin needed. Re-recorded AGAIN for GLORY v8 (2026-08-25, FAST BREAK
      # wave) -- still a RED capture, no re-pin needed. Re-recorded AGAIN for
      # GLORYVERSION 9 (2026-08-26, LAW AUDIT wave -- the new E2/E3 counters
      # and hashed plumbing move gameHash) -- flipped to a BLUE capture this
      # time, same bot-connection-order variance the 2026-08-24 note already
      # explains, not a gameplay regression.
      check state["over"]["draw"].getBool == false
      check state["over"]["timeLimit"].getBool == false
      check state["over"]["winner"].getStr == "blue"
      # The scorebug axis is lives + flag state, never a kill score.
      check state["teams"]["red"].hasKey("lives")
      check state["teams"]["blue"]["flag"].getStr in ["home", "taken"]
    finally:
      setCurrentDir(previousDir)

  test "keyframe walk precomputes the flag beats + verdict timeline":
    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      let data = loadReplay(CaptureFixture)
      var
        sim = initFixtureSim(data)
        replay = initReplayPlayer(data)
      replay.mismatchQuit = true
      replay.buildReplayKeyframes(sim)
      # The precomputed timeline holds exactly the streamed flag beats +
      # verdict (never kills/respawns), in tick order.
      let streamed = broadcastBeats(CaptureFixture).filterIt(
        it.key in ["steal", "return", "capture", "gameover"]
      )
      check replay.beatEvents.len == streamed.len
      for i, event in replay.beatEvents.elems:
        check event["k"].getStr == streamed[i].key
        check event["t"].getInt == streamed[i].tick
      # The timeline carries exactly one verdict, matching the fixture's
      # pinned ending. (On a capture tick the phase-change gameover event
      # precedes the capture event, so the verdict need not sort last.)
      let verdicts = replay.beatEvents.elems.filterIt(it["k"].getStr == "gameover")
      check verdicts.len == 1
      check verdicts[0]["draw"].getBool == false
      check verdicts[0]["winner"].getStr == "blue"   # see the re-pin note above
      # The chrome frame ships the timeline when (and only when) asked.
      let withBeats = parseJson(sim.buildStateJson(
        newJArray(), false, 1, replay.replayMaxTick(), false, true, -1, -1,
        beatEvents = replay.beatEvents
      ))
      check withBeats["beats"] == replay.beatEvents
      let withoutBeats = parseJson(sim.buildStateJson(
        newJArray(), false, 1, replay.replayMaxTick(), false, true, -1, -1
      ))
      check not withoutBeats.hasKey("beats")
    finally:
      setCurrentDir(previousDir)

  test "beat timeline verdict reports a draw honestly":
    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      let data = loadReplay(DrawFixture)
      var
        sim = initFixtureSim(data)
        replay = initReplayPlayer(data)
      replay.mismatchQuit = true
      replay.buildReplayKeyframes(sim)
      let verdicts = replay.beatEvents.elems.filterIt(it["k"].getStr == "gameover")
      check verdicts.len == 1
      check verdicts[0]["draw"].getBool == true
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

suite "broadcast state channel: the glory ledger":
  test "team state carries the glory ledger and its heat multiplier":
    # Priced by glory.nim and SHIPPED, never recomputed in the browser: the
    # chrome must read the same number the sim paid out, or the band drifts
    # from the ladder silently and nothing ever fails.
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
      for team in Team:
        let t = state["teams"][teamText(team)]
        check t["glory"].getInt == sim.teamGlory[team]
        check t["heat"].getInt == heatMult(sim.heatEmbers[team])
        check t["embers"].getInt == sim.heatEmbers[team]
      # A real episode must actually MINT something, or this assertion is
      # comparing two zeroes and guarding nothing.
      check sim.teamGlory[Red] + sim.teamGlory[Blue] > 0
      # The per-life ladder rides the roster rows.
      check state["roster"].len == sim.players.len
      for row in state["roster"]:
        check row.hasKey("lvl")
        check row.hasKey("xp")
    finally:
      setCurrentDir(previousDir)

  test "achievement claims stream as a NEW kind, leaving the beat order alone":
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
      var claims: seq[JsonNode]
      var warmup = newJArray()
      sim.stepEvents(tracker, warmup)
      while replay.playing:
        replay.stepReplay(sim)
        var events = newJArray()
        sim.stepEvents(tracker, events)
        for e in events:
          if e["k"].getStr == "achv":
            claims.add e
      # The fixture must actually claim something, or the shape checks below
      # pass vacuously.
      check claims.len > 0
      # One claim per ledger entry, no more: a re-emit would double-shout the
      # ticker.
      check claims.len == sim.achievementFeed.len
      for c in claims:
        check c["team"].getStr in ["red", "blue"]
        check c["name"].getStr.len > 0
        check c["tier"].getInt >= 0
        check c["glory"].getInt > 0
        check c.hasKey("first")
      # Every claim's name is glory.nim's, not a string built here.
      for i, claim in sim.achievementFeed:
        check claims[i]["name"].getStr ==
          achievementName(claim.tree, claim.tier)
        check claims[i]["glory"].getInt == claim.glory
        check claims[i]["first"].getBool == claim.first
      # And the kill/steal/return/capture stream is untouched -- still exactly
      # the expand_replay timeline, tuple for tuple.
      check broadcastBeats(CaptureFixture) == timelineBeats(CaptureFixture)
    finally:
      setCurrentDir(previousDir)

  test "a seek does NOT replay the achievement ledger":
    # `startGame` clears sim.achievementFeed and a seek re-runs from a
    # keyframe, so the tracker's cached length can EXCEED the live one. Without
    # the clamp in stepEvents a scrub-to-start indexes off the end of the feed
    # or re-shouts every claim the episode ever made.
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
      replay.buildReplayKeyframes(sim)
      var warmup = newJArray()
      sim.stepEvents(tracker, warmup)
      var seen = 0
      while replay.playing:
        replay.stepReplay(sim)
        var events = newJArray()
        sim.stepEvents(tracker, events)
        for e in events:
          if e["k"].getStr == "achv":
            inc seen
      check seen > 0
      let feedAtEnd = sim.achievementFeed.len

      # Scrub all the way back to the start, exactly as the viewer does.
      replay.applyReplaySeek(sim, replay.replayStartTick())
      tracker.resync(sim)
      check sim.achievementFeed.len <= feedAtEnd
      var after = 0
      for _ in 0 ..< 40:
        replay.stepReplay(sim)
        var events = newJArray()
        sim.stepEvents(tracker, events)
        for e in events:
          if e["k"].getStr == "achv":
            inc after
      # Whatever the first 40 ticks legitimately claim, it cannot be the whole
      # ledger the episode built up before the seek.
      check after < seen
    finally:
      setCurrentDir(previousDir)

  test "the inspector card rides the chrome frame only when a cog is hovered":
    # `insp` is FINISHED LINES from global.inspectorLines -- broadcast.nim never
    # composes card text, so this asserts the channel, not the wording.
    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      let data = loadReplay(CaptureFixture)
      var sim = initFixtureSim(data)
      var replay = initReplayPlayer(data)
      replay.mismatchQuit = true
      let bare = parseJson(sim.buildStateJson(
        newJArray(), false, 1, replay.replayMaxTick(), false, true, -1, -1
      ))
      check not bare.hasKey("insp")
      # A slot with no lines is still nothing to draw -- an empty card must not
      # ship as an empty box.
      let empty = parseJson(sim.buildStateJson(
        newJArray(), false, 1, replay.replayMaxTick(), false, true, -1, -1,
        inspectSlot = 3, inspectLines = @[]
      ))
      check not empty.hasKey("insp")
      let carded = parseJson(sim.buildStateJson(
        newJArray(), false, 1, replay.replayMaxTick(), false, true, -1, -1,
        inspectSlot = 3, inspectLines = @["ALPHA", "rank IRONHIDE ***"]
      ))
      check carded["insp"]["slot"].getInt == 3
      check carded["insp"]["lines"].len == 2
      check carded["insp"]["lines"][0].getStr == "ALPHA"
    finally:
      setCurrentDir(previousDir)

  test "keyframe walk precomputes the glory-series change-points":
    # Mirrors the lives-lead precedent exactly: same keyframe walk, same
    # "only where something changes" compaction, same full-timeline-up-front
    # lifecycle -- just for glory (+ heat) instead of lives.
    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      let data = loadReplay(CaptureFixture)
      var
        sim = initFixtureSim(data)
        replay = initReplayPlayer(data)
      replay.mismatchQuit = true
      replay.buildReplayKeyframes(sim)

      check replay.gloryLine.len > 0
      # A real episode must actually MINT something, or the checks below
      # compare zero to zero and guard nothing.
      check replay.gloryLine[^1][1] + replay.gloryLine[^1][2] > 0
      # Strictly ascending tick order -- every change-point is a real step
      # forward, never a duplicate or a rewind.
      for i in 1 ..< replay.gloryLine.len:
        check replay.gloryLine[i][0] > replay.gloryLine[i - 1][0]

      # The last change-point holds the FINAL ledger. Verify it against this
      # SAME replay's own live sim state at that exact tick (seeking off the
      # keyframes this same call just built), rather than a second,
      # independently-stepped playthrough -- glory pays penalties too (it is
      # NOT monotonic in value, only the tick axis is), so the one invariant
      # that actually matters is that the series never disagrees with the
      # state the scorebug itself would show at that tick.
      let last = replay.gloryLine[^1]
      replay.seekReplay(sim, last[0])
      check sim.tickCount == last[0]
      check sim.teamGlory[Red] == last[1]
      check sim.teamGlory[Blue] == last[2]
      check heatMult(sim.heatEmbers[Red]) == last[3]
      check heatMult(sim.heatEmbers[Blue]) == last[4]
    finally:
      setCurrentDir(previousDir)

  test "chrome frame ships the glory series when asked, absent otherwise":
    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      let data = loadReplay(CaptureFixture)
      var
        sim = initFixtureSim(data)
        replay = initReplayPlayer(data)
      replay.mismatchQuit = true
      replay.buildReplayKeyframes(sim)
      check replay.gloryLine.len > 0

      let withGlory = parseJson(sim.buildStateJson(
        newJArray(), false, 1, replay.replayMaxTick(), false, true, -1, -1,
        gloryLine = replay.gloryLine
      ))
      check withGlory["gloryLine"].len == replay.gloryLine.len
      for i, point in replay.gloryLine:
        let wire = withGlory["gloryLine"][i]
        check wire[0].getInt == point[0]
        check wire[1].getInt == point[1]
        check wire[2].getInt == point[2]
        check wire[3].getInt == point[3]
        check wire[4].getInt == point[4]

      let withoutGlory = parseJson(sim.buildStateJson(
        newJArray(), false, 1, replay.replayMaxTick(), false, true, -1, -1
      ))
      check not withoutGlory.hasKey("gloryLine")
    finally:
      setCurrentDir(previousDir)

  test "the glory series survives a seek (shipped once, never recomputed)":
    # Mirrors the lead series' lifecycle: precomputed ONCE on the keyframe
    # walk and never touched by seek/playback controls, so a scrub can never
    # desync it from the shape the client already drew.
    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      let data = loadReplay(CaptureFixture)
      var
        sim = initFixtureSim(data)
        replay = initReplayPlayer(data)
      replay.mismatchQuit = true
      replay.buildReplayKeyframes(sim)
      let before = replay.gloryLine
      check before.len > 0

      # Scrub around, exactly as a viewer's scrubber would.
      replay.applyReplaySeek(sim, replay.replayStartTick())
      replay.applyReplaySeek(sim, replay.replayMaxTick())
      replay.applyReplaySeek(sim, replay.replayStartTick() + 20)

      check replay.gloryLine == before
    finally:
      setCurrentDir(previousDir)
