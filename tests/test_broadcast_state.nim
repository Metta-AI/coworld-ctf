import
  helpers,
  std/[json, os, sequtils, unittest],
  ctf/[broadcast, replays, sim],
  "../tools/expand_replay"

const
  FixtureDir = GameDir / "tests" / "fixtures"
  # Fixtures are recorded against the CURRENT gameplay rules and must be
  # re-recorded on every GameVersion bump (tools/record_fixture.sh):
  #   capture-seed1:  record_fixture.sh <out> 1
  #   wipe-lives1:    record_fixture.sh <out> 3 10000 \
  #                     '{"lives":1,"hitPoints":1,"carrierSpeedPct":1}'
  #   draw-nokill:    record_fixture.sh <out> 7 1500 \
  #                     '{"hitPoints":1000,"carrierSpeedPct":1,
  #                       "barrageMaxPerSec":0}'
  # (barrageMaxPerSec 0 is REQUIRED and is not optional tuning: config.json
  # ships the barrage on since 2026-08-07, and a barrage game has NO draw
  # ceiling by GV41's own rule — past the deadline the shelling grinds on
  # until one team stands. Recorded with the repo config the "draw" fixture
  # ran 109530 ticks against a 1500-tick limit and ended with a winner, so
  # the two draw-verdict tests below failed on a fixture that could not
  # contain a draw. The recipe predates the barrage and silently went stale.)
  # (carrierSpeedPct 1 pins the flag so the wipe/draw endings cannot be
  # preempted by a capture; record on an otherwise idle machine — a
  # CPU-starved server at speed 16 drops its bots and ends degenerate.)
  # Then re-pin the capture winner asserted below to the new recording.
  # The capture fixture's SEED is part of the recipe, not a constant: the
  # ending a seed produces is a property of the rules it was recorded under.
  # GV30 moved the pickups, and seed 7 — which captured under GV29 — now
  # runs to a time-limit draw, so the capture fixture moved to seed 1.
  # Under GV38 (locked spray cone) seed 1 still ends on a capture (Blue
  # captures the red heart, eliminating Red). The recording must ALSO keep
  # only one flag out from the last steal to the capture: the endzone fade
  # ramp test (test_replay_scan) watches this fixture just past the last
  # steal and its per-frame band allowance assumes a single powered-down
  # endzone — a double-steal ending ships both teams' bands at once and
  # busts the bound, so re-record until the last carry stands alone.
  CaptureFixture = FixtureDir / "capture-seed1.bitreplay"
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
      # is pinned to the current recording of the fixture (GameVersion 64,
      # seed 1: Blue captures the red heart, eliminating Red). A seed does
      # not pin the outcome — the bots are separate processes — so which side
      # wins is re-pinned on every re-record; the STRUCTURE (a capture ending,
      # no draw, no time limit) is what the test is actually asserting.
      check state["over"]["draw"].getBool == false
      check state["over"]["timeLimit"].getBool == false
      check state["over"]["winner"].getStr == "blue"
      # The scorebug axis is lives + flag state, never a kill score.
      check state["teams"]["red"].hasKey("lives")
      # GV32: the captured heart ends the game in the "captured" state.
      check state["teams"]["red"]["flag"].getStr == "captured"
      check state["teams"]["blue"]["flag"].getStr in ["home", "taken"]
      # The verdict carries a team-keyed map (any team count) that agrees with
      # the legacy red/blue scalars.
      for team in ["red", "blue"]:
        check state["over"]["teams"][team]["lives"].getInt ==
          state["over"][team & "Lives"].getInt
        check state["over"]["teams"][team].hasKey("prog")
      # Every team lists its seated policy identities; every roster seat names
      # its policy (the connection name with any " (N)" seat suffix stripped).
      for team in ["red", "blue"]:
        check state["teams"][team]["policies"].len >= 1
      for seat in state["roster"]:
        check seat.hasKey("pol")
        check seat["pol"].getStr == policyName(seat["name"].getStr)
      # SEASON 2: the glory cosmetic-pop queue rides every frame, unlike the
      # send-once "ach"/"huddle"/"vote" chrome below — an empty match-end
      # queue still ships an (empty) array, never an absent key.
      check state.hasKey("pops")
      check state["pops"].kind == JArray
      # A replay with no shell records (this fixture predates the huddle/vote
      # lanes) never sees these keys at all -- the degrade-to-nothing this
      # panel is built against.
      check not state.hasKey("huddle")
      check not state.hasKey("vote")
      # WIRE-OK BATCH (THE WHOLE epic, GameVersion 62->63): the realized-
      # economy stamp rides every frame, unconditional like "pops"/"glory".
      # This classic CTF fixture predates the recut economy and never sets
      # `gloryMultiplierRecut`, so it stays on the dark v12 ledger.
      check state.hasKey("economy")
      check state["economy"].getStr == "classic"
      # Each seat's own deed breakdown on the verdict block: always present
      # (an array, possibly empty for a seat that minted nothing), never
      # omit-when-absent like "prog"/"flag" above -- same idiom as "glory"/
      # "lives" on the same object. This fixture ends on a real capture, so
      # the winning side must have minted at least one deed (the capture
      # itself, at minimum). Re-pinned to the current recording's winner
      # (GameVersion 64, seed 1: Blue captures the red heart) -- see "final
      # frame state names the verdict honestly"'s own re-pin note above.
      for team in ["red", "blue"]:
        check state["over"]["teams"][team].hasKey("deeds")
        check state["over"]["teams"][team]["deeds"].kind == JArray
      check state["over"]["teams"]["blue"]["deeds"].len >= 1
      for entry in state["over"]["teams"]["blue"]["deeds"]:
        check entry.hasKey("deed")
        check entry["label"].getStr.len > 0
        check entry["count"].getInt >= 1
    finally:
      setCurrentDir(previousDir)

  test "SEASON 2: glory pops, huddle transcript and ballot ride the chrome frame when present":
    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      let data = loadReplay(CaptureFixture)
      var sim = initFixtureSim(data)
      # White-box: gloryPops is cosmetic-only (excluded from gameHash, see its
      # own doc comment), so pushing a fixture entry directly is the same
      # kind of test setup as `over.achievements`' unconditional endcard
      # check above -- no real deed needs to fire to prove the WIRE shape.
      sim.gloryPops.add GloryFx(
        x: 12, y: 34, tick: 5, amount: 18, team: Red, label: "",
        word: "TAG", first: false, earnerIndex: -1, startDelay: 0, row: 0)
      # row: 1 -- a second, site-stacked pop (addGloryPop's own collision
      # search, sim.nim) at nearly the same site as the one above. A viewer
      # missing this field draws it directly on top of a neighbour instead
      # of stacked above it (visually confirmed 2026-08-31: a rank-up pop
      # overlapping an unrelated deed pop at one spawn point read as
      # illegible mashed text).
      sim.gloryPops.add GloryFx(
        x: 56, y: 78, tick: 5, amount: 240, team: Blue, label: "Marksman",
        word: "", first: true, earnerIndex: 2, startDelay: 3, row: 1)
      let lobbyChat = %*[{"seat": 0, "team": "red", "text": "ready?"}]
      let ballots = %*[{"k": "cast", "seat": 0, "team": "red", "opt": 0}]
      let state = parseJson(sim.buildStateJson(
        newJArray(), false, 1, 100, false, true, -1, -1,
        lobbyChat = lobbyChat, ballots = ballots
      ))
      check state["pops"].len == 2
      let deedPop = state["pops"][0]
      check deedPop["x"].getInt == 12
      check deedPop["y"].getInt == 34
      check deedPop["t"].getInt == 5
      check deedPop["amt"].getInt == 18
      check deedPop["team"].getStr == "red"
      check deedPop["word"].getStr == "TAG"
      check deedPop["lbl"].getStr == ""
      check deedPop["row"].getInt == 0
      let claimPop = state["pops"][1]
      check claimPop["lbl"].getStr == "Marksman"
      check claimPop["first"].getBool == true
      check claimPop["earner"].getInt == 2
      check claimPop["delay"].getInt == 3
      # the site-stack depth the sim already computes (addGloryPop's
      # collision search) so a renderer can stack same-site pops instead of
      # drawing them on top of each other.
      check claimPop["row"].getInt == 1
      # send-once chrome: present and equal to what was passed, when given.
      check state["huddle"] == lobbyChat
      check state["vote"] == ballots
      # ...and absent again when the caller has nothing to send (an empty
      # array is treated the same as nil — no shell records for this frame).
      let bare = parseJson(sim.buildStateJson(
        newJArray(), false, 1, 100, false, true, -1, -1,
        lobbyChat = newJArray(), ballots = newJArray()
      ))
      check not bare.hasKey("huddle")
      check not bare.hasKey("vote")
    finally:
      setCurrentDir(previousDir)

  test "policyName strips only the hosted per-seat suffix":
    check policyName("softmaxwell (2)") == "softmaxwell"
    check policyName("softmaxwell (17)") == "softmaxwell"
    # The join path converts spaces to underscores (cleanPlayerName), so the
    # suffix reads "_(N)" on a real player address.
    check policyName("softmaxwell_(2)") == "softmaxwell"
    check policyName("ctf-focusfire:v62_(4)") == "ctf-focusfire:v62"
    check policyName("softmaxwell") == "softmaxwell"
    check policyName("Player1") == "Player1"       # no parens: untouched
    check policyName("bot (v2)") == "bot (v2)"     # non-numeric: untouched
    check policyName("(3)") == "(3)"               # nothing before it: untouched
    check policyName("") == ""

  test "glory series ships team-keyed change points":
    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      let data = loadReplay(CaptureFixture)
      var
        sim = initFixtureSim(data)
        replay = initReplayPlayer(data)
      replay.mismatchQuit = true
      replay.buildReplayKeyframes(sim)
      # One glory value per team on every change point, ticks non-decreasing.
      check replay.leadSeries.len >= 2
      check replay.leadMetric == "glory"   # classic game: the lane plots glory
      var lastTick = -1
      for point in replay.leadSeries:
        check point.len == 1 + 2  # tick + one glory value per team
        check point[0] >= lastTick
        lastTick = point[0]
      # The chrome frame publishes it as {teams, pts} in Team order.
      let state = parseJson(sim.buildStateJson(
        newJArray(), false, 1, replay.replayMaxTick(), false, true, -1, -1,
        replay.leadSeries, replay.leadMetric, replay.leadOutTicks
      ))
      # ELIMINATION TICKS, one per team in the same order. capture-seed1 ends
      # on Blue capturing the red heart (GameVersion 64 recording), which
      # eliminates Red -- so Red has a real tick and Blue, still standing,
      # has -1. Re-pinned from the prior recording's opposite winner (a seed
      # does not pin the outcome, same note the "verdict honestly" test above
      # carries).
      #
      # The >0 matters. "No lives banked and nobody up" is also true of the
      # LOBBY, before anyone has spawned, so latching it directly marks every
      # team eliminated on tick 1 -- which is what the first cut of this did,
      # measured as outTicks @[1, 1, 1, ...] across all sixteen teams of the
      # BR fixture. The latch is gated on having been alive first; this is
      # the assertion that would have caught it.
      check replay.leadOutTicks.len == 2
      let redOut = replay.leadOutTicks[0]
      let blueOut = replay.leadOutTicks[1]
      check redOut > 1
      check blueOut == -1
      check redOut <= replay.leadSeries[^1][0]
      # The band captions itself from this, rather than hardcoding a metric.
      check state["lead"]["metric"].getStr == "glory"
      # …and the wire carries them, so the lane can stop drawing a dead team
      # as a live competitor.
      check state["lead"]["out"].len == 2
      check state["lead"]["out"][0].getInt == redOut
      check state["lead"]["out"][1].getInt == -1
      check state["lead"]["teams"].len == 2
      check state["lead"]["teams"][0].getStr == "red"
      check state["lead"]["teams"][1].getStr == "blue"
      check state["lead"]["pts"].len == replay.leadSeries.len
      for row in state["lead"]["pts"]:
        check row.len == 3
    finally:
      setCurrentDir(previousDir)

  test "heat rides the wire beside glory: live per-team key + its own parallel series":
    # HEAT ON THE WIRE: heatMult/heatEmbers exist sim-side (glory.nim/
    # sim.nim) but were never broadcast -- 0 of 512 seat-episodes ever
    # reached the top rung and the x1 floor holds 99.7%+ of BR seat-time,
    # which an invisible mechanic will do. This proves the plumbing: the
    # live per-team key, and the full-match series parallel to `leadSeries`.
    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      let data = loadReplay(CaptureFixture)
      var
        sim = initFixtureSim(data)
        replay = initReplayPlayer(data)
      replay.mismatchQuit = true
      replay.buildReplayKeyframes(sim)
      # Same [tick, valuePerTeam…] change-point shape as leadSeries, same
      # team order -- but its OWN series (heatSeries), never folded into
      # leadSeries itself.
      check replay.heatSeries.len >= 1
      var lastTick = -1
      for point in replay.heatSeries:
        check point.len == 1 + 2  # tick + one heat value per team
        check point[0] >= lastTick
        lastTick = point[0]
        for value in point[1 .. ^1]:
          # HeatLadder = [1, 2, 4, 8]: the multiplier's floor is x1, never
          # zero -- "no heat" reads as the resting rung, not an absent key.
          check value in [1, 2, 4, 8]
      # The chrome frame publishes it as its own {teams, pts} key, parallel
      # to "lead" -- not merged into it (a hard constraint of this port: the
      # momentum lane's metric must keep meaning only glory/hill).
      let state = parseJson(sim.buildStateJson(
        newJArray(), false, 1, replay.replayMaxTick(), false, true, -1, -1,
        replay.leadSeries, replay.leadMetric, replay.leadOutTicks,
        heatSeries = replay.heatSeries
      ))
      check state["heat"]["teams"].len == 2
      check state["heat"]["teams"][0].getStr == "red"
      check state["heat"]["teams"][1].getStr == "blue"
      check state["heat"]["pts"].len == replay.heatSeries.len
      for row in state["heat"]["pts"]:
        check row.len == 3
      # Live per-team key: unconditional beside "glory" on EVERY frame (not
      # gated behind the once-per-viewer lead/heat series above), and its
      # value is exactly heatMult of the sim's own heatEmbers -- the same
      # formula mintGlory (glory.nim) already applies to every deed.
      check state["teams"]["red"]["heat"].getInt == heatMult(sim.heatEmbers[Red])
      check state["teams"]["blue"]["heat"].getInt == heatMult(sim.heatEmbers[Blue])
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
      check verdicts[0]["winner"].getStr == "blue"   # re-pinned, see "final frame state names the verdict honestly"
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
