import
  std/json,
  bitworld/spriteprotocol,
  ctf/[broadcast, global, replays, sim]

var
  runtimeLoaded = false
  replay: ReplayPlayer
  game: SimServer
  viewer: GlobalViewerState
  tracker: BroadcastTracker
  packet: seq[uint8]
  lastError: string

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc renderCurrent(events = newJArray()) =
  var nextViewer: GlobalViewerState
  packet = game.buildSpriteProtocolUpdates(
    viewer,
    nextViewer,
    game.tickCount,
    replay.playing,
    replay.replaySpeed(),
    replay.replayMaxTick(),
    replay.looping,
    true,
    replay.hashMismatchTick
  )
  let sendLead = not viewer.momentumSent
  packet.addSprite(
    BroadcastChromeSpriteId,
    1,
    1,
    [0'u8, 0, 0, 0],
    game.buildStateJson(
      events,
      replay.playing,
      replay.replaySpeed(),
      replay.replayMaxTick(),
      replay.looping,
      true,
      replay.hashMismatchTick,
      nextViewer.selectedJoinOrder,
      if sendLead: replay.livesLeadSeries else: @[],
      replay.replayStartTick()
    )
  )
  if sendLead:
    nextViewer.momentumSent = true
  viewer = nextViewer

proc ctfLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "ctf_load_replay", cdecl.} =
  var stage = "parse replay"
  try:
    lastError = ""
    let replayData = parseReplayBytes(data.bytesFromPointer(int(length)))
    stage = "load replay config"
    var config = defaultGameConfig()
    config.update(replayData.configJson)
    stage = "initialize simulation"
    game = initSimServer(config)
    game.gameEventLoggingEnabled = false
    stage = "initialize replay"
    replay = initReplayPlayer(replayData)
    # Match the native replay server default: keep a historical replay usable
    # after the first integrity mismatch and surface the warning in the shared
    # replay chrome. `--mismatch-quit` remains a native diagnostic mode.
    replay.mismatchQuit = false
    stage = "build replay keyframes"
    replay.buildReplayKeyframes(game)
    stage = "seek replay start"
    replay.seekReplay(game, replay.replayStartTick())
    replay.playing = true
    viewer = initGlobalViewerState()
    tracker = initBroadcastTracker()
    runtimeLoaded = true
    stage = "render first frame"
    renderCurrent()
    return 1
  except Exception as error:
    runtimeLoaded = false
    lastError = stage & ": " & error.msg & "\n" & error.getStackTrace()
    return 0

proc ctfInput(data: ptr uint8, length: cint)
    {.exportc: "ctf_input", cdecl.} =
  if runtimeLoaded:
    viewer.applyGlobalViewerMessage(data.bytesFromPointer(int(length)))

proc ctfFrame(): cint {.exportc: "ctf_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  try:
    var didSeek = false
    if viewer.replaySeekTick >= 0:
      replay.applyReplaySeek(game, viewer.replaySeekTick)
      didSeek = true
    for command in viewer.replayCommands:
      let tickBeforeCommand = game.tickCount
      replay.applyReplayCommand(game, command)
      if game.tickCount != tickBeforeCommand:
        didSeek = true
    if didSeek:
      tracker.resync(game)

    var events = newJArray()
    if replay.playing:
      for _ in 0 ..< replay.replaySpeed():
        if replay.playing:
          replay.stepReplay(game)
          game.stepEvents(tracker, events)
      if replay.looping and not replay.playing:
        replay.seekReplay(game, replay.replayStartTick())
        replay.playing = true
        tracker.resync(game)

    renderCurrent(events)
    return 1
  except Exception as error:
    lastError = "advance replay: " & error.msg & "\n" & error.getStackTrace()
    return -1

proc ctfPacketPointer(): ptr uint8
    {.exportc: "ctf_packet_ptr", cdecl.} =
  if packet.len == 0:
    nil
  else:
    packet[0].addr

proc ctfPacketLength(): cint {.exportc: "ctf_packet_len", cdecl.} =
  cint(packet.len)

proc ctfErrorPointer(): ptr uint8 {.exportc: "ctf_error_ptr", cdecl.} =
  if lastError.len == 0:
    nil
  else:
    cast[ptr uint8](lastError[0].addr)

proc ctfErrorLength(): cint {.exportc: "ctf_error_len", cdecl.} =
  cint(lastError.len)

when isMainModule:
  discard
