## Live broadcast chrome (proof stakes #7/#9): the teams-alive bar, roster,
## kill feed and end-card the designed broadcast client renders used to be
## built ONLY off a loaded replay's ReplayPlayer (buildReplayViewerPacket) --
## a live match's global viewers got the bare board sprite stream with no
## chrome sprite at all, which is why wiring /client/global to the rich
## broadcast HTML needed buildLiveViewerPacket, not just a route change.
##
## These cases drive a LIVE, sim.step()-stepped match (never a replay file)
## through buildLiveViewerPacket and prove: (1) the chrome sprite carries
## real teams/roster/verdict state sourced straight off the live sim: no
## fabricated values; (2) a live kill reaches the chrome's event stream the
## same tick it happens, the same stepEvents() diff a replay uses; (3) every
## field only a full-match precompute scan can know (lead momentum series,
## lull spans, beat markers, achievement badges) is HONESTLY absent rather
## than faked; (4) the tracker survives both kinds of live reset
## (server.nim's full shouldReset vs. an in-match needsReregister round
## transition) the way server.nim now handles them; and (5) none of this
## bookkeeping touches gameHash -- stepEvents/buildStateJson only ever READ
## sim, matching the read-only signatures they were already given.

import
  helpers,
  std/[json, sequtils, unittest],
  bitworld/spriteprotocol,
  ctf/[broadcast, global, replay_runtime, sim]

proc chromeOf(packet: seq[uint8]): JsonNode =
  for message in packet.parseSpritePacket():
    if message.kind == spkSprite and
        message.sprite.id == BroadcastChromeSpriteId:
      return message.sprite.label.parseJson()

proc brGame(teams = 2): SimServer =
  var config = defaultGameConfig()
  config.brMode = true
  config.teams = teams
  if teams == 4:
    config.mapPath = "gen"
    config.mapGen.layout = "corners"
    config.mapSeed = 42
  result = initCtfForTest(config)
  for i in 0 ..< teams:
    discard result.addPlayer("p" & $i)
  result.startGame()

suite "live broadcast chrome (buildLiveViewerPacket)":
  test "a live mid-game frame carries real teams/roster state, no replay-only fields":
    var sim = brGame()
    var tracker = initBroadcastTracker()
    var warmup = newJArray()
    sim.stepEvents(tracker, warmup)  # bootstrap snapshot, stepEvents' own contract
    var
      events = newJArray()
      viewer = initGlobalViewerState()
      nextViewer: GlobalViewerState
    let packet = sim.buildLiveViewerPacket(
      viewer, nextViewer, [], sim.tickCount, 7200, 1, true, false, events)
    let chrome = packet.chromeOf()
    check not chrome.isNil
    check chrome["ph"].getStr == "playing"
    check chrome["teams"].hasKey("red")
    check chrome["teams"].hasKey("blue")
    check not chrome.hasKey("over")
    # No full-match precompute exists live -- none of these ever ship.
    check not chrome.hasKey("lead")
    check not chrome.hasKey("lulls")
    check not chrome.hasKey("beats")
    check not chrome.hasKey("ach")

  test "a live kill reaches the chrome's events the same tick it happens":
    var sim = brGame()
    var tracker = initBroadcastTracker()
    var warmup = newJArray()
    sim.stepEvents(tracker, warmup)
    sim.killPlayer(1, 0)
    var events = newJArray()
    sim.stepEvents(tracker, events)
    var
      viewer = initGlobalViewerState()
      nextViewer: GlobalViewerState
    let packet = sim.buildLiveViewerPacket(
      viewer, nextViewer, [], sim.tickCount, 7200, 1, true, false, events)
    let chrome = packet.chromeOf()
    check chrome["events"].len > 0
    check chrome["events"].anyIt(it["k"].getStr == "kill")

  test "a live game-over frame carries an honest end-card, sourced off sim state":
    var sim = brGame()
    var tracker = initBroadcastTracker()
    var warmup = newJArray()
    sim.stepEvents(tracker, warmup)
    sim.killPlayer(1, 0)  # brMode, 2 teams, 1 seat each: wipes blue's only seat
    sim.checkWinCondition()  # the live tick loop's own step() runs this each tick
    var events = newJArray()
    sim.stepEvents(tracker, events)
    check sim.phase == GameOver
    var
      viewer = initGlobalViewerState()
      nextViewer: GlobalViewerState
    let packet = sim.buildLiveViewerPacket(
      viewer, nextViewer, [], sim.tickCount, 7200, 1, true, false, events)
    let chrome = packet.chromeOf()
    check chrome["ph"].getStr == "gameover"
    check chrome.hasKey("over")
    check chrome["over"]["winner"].getStr == "red"
    check chrome["teams"]["red"].hasKey("lives")

  test "resync (an in-match round transition) starts the next diff clean, no phantom flood":
    # Mirrors server.nim's needsReregister handling: the roster and tick
    # count both carry forward (unlike a full match reset), but the frame
    # right after the transition must not diff against stale pre-transition
    # counters.
    var sim = brGame()
    var tracker = initBroadcastTracker()
    var events = newJArray()
    sim.stepEvents(tracker, events)
    sim.killPlayer(1, 0)  # brMode, 2 teams, 1 seat each: wipes blue's only seat
    events = newJArray()
    sim.stepEvents(tracker, events)
    check events.len > 0  # the kill/elimination/gameover beats really fired

    tracker.resync(sim)
    var afterResync = newJArray()
    sim.stepEvents(tracker, afterResync)
    check afterResync.len == 0  # resync -> next call is a clean diff, not a re-fire

  test "a full match reset (different roster size) never crashes a fresh tracker":
    # Mirrors server.nim's shouldReset handling: broadcastTracker = initBroadcastTracker()
    # alongside sim = initSimServer(config), so a smaller or larger NEXT
    # match's roster is never diffed against a stale-length array.
    var oldSim = brGame(teams = 2)
    var tracker = initBroadcastTracker()
    var warmup = newJArray()
    oldSim.stepEvents(tracker, warmup)
    oldSim.killPlayer(1, 0)

    tracker = initBroadcastTracker()  # the shouldReset-site reset this mirrors
    var newSim = brGame(teams = 4)
    var events = newJArray()
    newSim.stepEvents(tracker, events)  # first call on the new match: bootstrap only
    check events.len == 0
    var
      viewer = initGlobalViewerState()
      nextViewer: GlobalViewerState
    let packet = newSim.buildLiveViewerPacket(
      viewer, nextViewer, [], newSim.tickCount, 7200, 1, true, false, events)
    check packet.chromeOf()["teams"].len == 4

  test "stepping the live broadcast tracker never changes the sim's own gameHash":
    # gameHash is the replay-determinism boundary (server.nim's replayWriter
    # writes it every tick regardless of any viewer). stepEvents/
    # buildLiveViewerPacket read sim; they must never perturb it, or this
    # feature could not be wired into the live tick loop at all.
    var
      withChrome = brGame()
      withoutChrome = brGame()
      tracker = initBroadcastTracker()
      viewer = initGlobalViewerState()
    let none = newSeq[InputState](withChrome.players.len)
    for i in 0 ..< 40:
      withChrome.step(none, none)
      withoutChrome.step(none, none)
      var events = newJArray()
      withChrome.stepEvents(tracker, events)
      var nextViewer: GlobalViewerState
      discard withChrome.buildLiveViewerPacket(
        viewer, nextViewer, [], withChrome.tickCount, 7200, 1, true, false,
        events)
      viewer = nextViewer
      check withChrome.gameHash() == withoutChrome.gameHash()
