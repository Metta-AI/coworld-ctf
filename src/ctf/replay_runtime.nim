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
  result.player.buildReplayKeyframes(result.sim)
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
    sendLead = not state.momentumSent
    sendFpMap = not state.fpMapSent
  # The inspector card, resolved by the board hit test inside
  # `buildSpriteProtocolUpdates` and shipped down the chrome channel as
  # finished lines. This is the ONLY path the static replay bundle has: the
  # sim-side InspectorLayerId is a UI layer, and the broadcast client's
  # composite filter only blits ZoomableFlag/MapLayerType layers -- so the
  # native card has never been a pixel here. Gated on `Playing` to match
  # `addInspector`, which refuses to draw in the lobby or on the end-card.
  var
    inspectSlot = -1
    inspectLines: seq[string] = @[]
  let inspectIndex = nextState.inspectIndex
  if inspectIndex >= 0 and inspectIndex < sim.players.len and
      sim.phase == Playing:
    inspectSlot = sim.players[inspectIndex].joinOrder
    inspectLines = sim.inspectorLines(inspectIndex)
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
      if sendLead: replay.livesLeadSeries else: @[],
      replay.replayStartTick(),
      replay.endHoldSecondsLeft(),
      sendFpMap,
      replay.skipLulls,
      replay.skipLulls and replay.playing and
        replay.isLullTick(sim.tickCount),
      if sendLead: replay.lullSpans else: @[],
      if sendLead: replay.beatEvents else: nil,
      inspectSlot,
      inspectLines
    )
  )
  if sendLead:
    nextState.momentumSent = true
  if sendFpMap:
    nextState.fpMapSent = true
