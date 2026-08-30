import
  std/json,
  bitworld/spriteprotocol,
  broadcast, global, replays, sim

type
  InitializedReplay* = object
    ## Fully prepared deterministic replay state shared by native and WASM hosts.
    config*: GameConfig
    sim*: SimServer
    player*: ReplayPlayer
    tracker*: BroadcastTracker

proc initReplayRuntime*(
  data: ReplayData,
  mismatchQuit: bool,
  gameEventLoggingEnabled = true
): InitializedReplay =
  ## Constructs and starts replay playback from the recorded game config.
  result.config = defaultGameConfig()
  result.config.update(data.configJson)
  result.sim = initSimServer(result.config)
  result.sim.gameEventLoggingEnabled = gameEventLoggingEnabled
  result.player = initReplayPlayer(data)
  result.player.mismatchQuit = mismatchQuit
  # The whole-match precompute walk (seek keyframes, momentum series, story
  # beats, lull spans) used to run synchronously HERE — seconds of black
  # screen on a giant board before the first pixel. It now starts here and
  # advances a bounded slice per presentation frame (advanceReplayPlayback);
  # the lead chrome ships when it completes. Only the short lobby walk to
  # the first Playing tick — the spectator start — is paid up front.
  result.player.initReplayScan(result.sim)
  while result.sim.phase != Playing and
      result.sim.tickCount < result.player.replayMaxTick() and
      result.player.hashIndex < result.player.data.hashes.len and
      not result.player.hashValidationFailed:
    result.player.stepReplay(result.sim)
  if result.player.startTick < 0 and result.sim.phase == Playing:
    result.player.startTick = result.sim.gameStartTick
  # If the walk ended without reaching Playing (degenerate or corrupt
  # recording), startTick stays -1: replayStartTick() clamps it to 0 for
  # every consumer, and the scan still gets to publish the true value if
  # its full walk finds one later.
  # Land playback exactly on the spectator start tick (the walk above can
  # overshoot it by the tick that flipped the phase): keyframe 0 exists, so
  # this is a rewind-to-zero plus the same short lobby re-walk.
  result.player.seekReplay(result.sim, result.player.replayStartTick())
  result.player.playing = true
  result.tracker = initBroadcastTracker()

proc advanceReplayFrame*(
  replay: var ReplayPlayer,
  sim: var SimServer,
  tracker: var BroadcastTracker,
  seekTicks: openArray[int],
  commands: openArray[char]
): JsonNode =
  ## Applies viewer controls and advances one public presentation frame.
  var didSeek = false
  for seekTick in seekTicks:
    replay.applyReplaySeek(sim, seekTick)
    didSeek = true
  for command in commands:
    let tickBeforeCommand = sim.tickCount
    replay.applyReplayCommand(sim, command)
    if sim.tickCount != tickBeforeCommand:
      didSeek = true
  if didSeek:
    tracker.resync(sim)
    replay.cancelEndHold()

  let events = newJArray()
  let
    simPtr = sim.addr
    trackerPtr = tracker.addr
  replay.advanceReplayPlayback(
    sim,
    proc () = simPtr[].stepEvents(trackerPtr[], events),
    proc () = trackerPtr[].resync(simPtr[])
  )
  result = events

proc buildLiveViewerPacket*(
  sim: var SimServer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState,
  overlays: openArray[DebugOverlay],
  tick, maxTick, speed: int,
  playing, looping: bool,
  events: JsonNode
): seq[uint8] =
  ## Builds the live board + chrome packet for one global-viewer socket.
  ##
  ## stakes #7/#9: the broadcast chrome sprite (teams-alive bar, roster,
  ## kill-feed events, end-card) used to ride ONLY buildReplayViewerPacket
  ## above -- a live match's global viewers got the bare board via
  ## buildSpriteProtocolUpdates and nothing else, because every field
  ## buildStateJson needed past "board state" (playing/speed/maxTick/
  ## looping/POV) was read off a ReplayPlayer that only exists once a match
  ## is recorded and reloaded as a file. Every one of THOSE fields is also
  ## already computed for the live board packet at this same call site
  ## (server.nim's live send loop) -- this mirrors buildReplayViewerPacket's
  ## chrome-sprite append using those same live values, not new ones.
  ##
  ## What is deliberately NOT here, and why: the lead/momentum series, lull
  ## spans, beat markers and achievement badges are all products of a
  ## FULL-MATCH precompute scan (initReplayScan) that only makes sense once
  ## the whole match is already recorded -- a live match cannot know its own
  ## future. Passing empty/nil for those is an honest omission (the client
  ## already treats them as "absent this frame, cached from an earlier one"),
  ## not a fabricated value. Likewise transportEnabled=false and
  ## mismatchTick=-1: a live stream has no scrubber to seek and no replay
  ## hash to mismatch.
  result = sim.buildSpriteProtocolUpdates(
    state, nextState, overlays, tick, playing, speed, maxTick, looping,
    false, -1
  )
  if result.len == 0:
    return
  let sendFpMap = not state.fpMapSent
  result.addSprite(
    BroadcastChromeSpriteId,
    1,
    1,
    [0'u8, 0, 0, 0],
    sim.buildStateJson(
      events, playing, speed, maxTick, looping, false, -1,
      nextState.selectedJoinOrder,
      startTick = sim.gameStartTick,
      includeFpMap = sendFpMap
    )
  )
  if sendFpMap:
    nextState.fpMapSent = true

proc buildReplayViewerPacket*(
  sim: var SimServer,
  replay: ReplayPlayer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState,
  events: JsonNode
): seq[uint8] =
  ## Builds the shared replay board and chrome packet for one viewer.
  result = sim.buildSpriteProtocolUpdates(
    state,
    nextState,
    replay.overlays,
    sim.tickCount,
    replay.playing,
    replay.replaySpeed(),
    replay.replayMaxTick(),
    replay.looping,
    true,
    replay.hashMismatchTick
  )
  if result.len == 0:
    return

  let
    # The lead chrome (momentum series, beat markers, lull spans) waits for
    # the background precompute walk: it ships ONCE per viewer, so sending
    # before the walk finishes would freeze a half-scanned timeline into the
    # HUD. The client keys on presence, not frame number — late is fine.
    sendLead = not state.momentumSent and replay.scanComplete
    sendFpMap = not state.fpMapSent
  result.addSprite(
    BroadcastChromeSpriteId,
    1,
    1,
    [0'u8, 0, 0, 0],
    sim.buildStateJson(
      events,
      replay.playing,
      replay.replaySpeed(),
      replay.replayMaxTick(),
      replay.looping,
      true,
      replay.hashMismatchTick,
      nextState.selectedJoinOrder,
      if sendLead: replay.livesSeries else: @[],
      replay.replayStartTick(),
      replay.endHoldSecondsLeft(),
      sendFpMap,
      replay.skipLulls,
      replay.skipLulls and replay.playing and
        replay.isLullTick(sim.tickCount),
      if sendLead: replay.lullSpans else: @[],
      if sendLead: replay.beatEvents else: nil,
      if sendLead: replay.achievementBadges else: nil
    )
  )
  if sendLead:
    nextState.momentumSent = true
  if sendFpMap:
    nextState.fpMapSent = true
