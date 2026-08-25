import
  std/json,
  ctf/[broadcast, global, replay_runtime, replays, sim]

var
  runtimeLoaded = false
  gloryObserver = false
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

proc renderCurrent(events: JsonNode) =
  if gloryObserver:
    # A pre-glory recording's hashes lack the glory ledger fields entirely, so
    # every checked tick mismatches BY CONSTRUCTION and the fidelity banner
    # would be permanent noise. Clear the surfaced tick (the packet's "mm"
    # field and ctf_mismatch_tick) each frame -- seeks restore it from
    # keyframes -- while the detector itself stays untouched for normal
    # replays.
    replay.hashMismatchTick = -1
  var nextViewer: GlobalViewerState
  packet = game.buildReplayViewerPacket(replay, viewer, nextViewer, events)
  viewer = nextViewer

proc ctfLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "ctf_load_replay", cdecl.} =
  var stage = "parse replay"
  try:
    lastError = ""
    let replayData = parseReplayBytes(data.bytesFromPointer(int(length)))
    stage = "load replay config"
    stage = "initialize replay runtime"
    # Match the native replay server default: keep a historical replay usable
    # after the first integrity mismatch and surface the warning in the shared
    # replay chrome. `--mismatch-quit` remains a native diagnostic mode.
    if gloryObserver:
      # DEV RIG (deletable scaffolding, pairs with SimServer.gloryObserver).
      # Mirrors initReplayRuntime's sequence with the lens armed FIRST:
      # buildReplayKeyframes walks the whole match and serializes the entire
      # SimServer into every keyframe, so a flag set after init would (a) let
      # the walk run with buffs live -- baking diverged states into every
      # keyframe -- and (b) be clobbered back to false by the very first seek
      # restore.
      var config = defaultGameConfig()
      config.update(replayData.configJson)
      game = initSimServer(config)
      game.gameEventLoggingEnabled = false
      game.gloryObserver = true
      replay = initReplayPlayer(replayData)
      replay.mismatchQuit = false
      replay.buildReplayKeyframes(game)
      replay.seekReplay(game, replay.replayStartTick())
      replay.playing = true
      tracker = initBroadcastTracker()
    else:
      var initialized = initReplayRuntime(
        replayData,
        mismatchQuit = false,
        gameEventLoggingEnabled = false
      )
      game = move(initialized.sim)
      replay = move(initialized.player)
      tracker = move(initialized.tracker)
    viewer = initGlobalViewerState()
    runtimeLoaded = true
    stage = "render first frame"
    renderCurrent(newJArray())
    return 1
  except Exception as error:
    runtimeLoaded = false
    lastError = stage & ": " & error.msg & "\n" & error.getStackTrace()
    return 0

proc ctfInput(data: ptr uint8, length: cint)
    {.exportc: "ctf_input", cdecl.} =
  if runtimeLoaded:
    viewer.applyGlobalViewerMessage(data.bytesFromPointer(int(length)))

proc ctfSetPointer(x, y: cint) {.exportc: "ctf_set_pointer", cdecl.} =
  ## Streams the cursor's MAP-space position so the hover inspector can resolve
  ## a cog. Deliberately NOT a click: a board click sets `selectedJoinOrder`,
  ## which is the POV toggle, and the POV branch returns long before the hover
  ## hit test ever runs -- so pointing and pinning have to be different inputs.
  ##
  ## Three scars are baked into these four lines:
  ##  * It must also be listed in replay-viewer/config.nims EXPORTED_FUNCTIONS.
  ##    emcc dead-strips an `exportc` that isn't named there; the build still
  ##    exits 0, ctf_replay.wasm still exists, and `Module._ctf_set_pointer` is
  ##    simply `undefined` at runtime inside a handler firing 100x a second.
  ##  * It never touches `clickPending`/`mouseDown` state, and it BAILS while
  ##    either is set. `clickMap` writes mouseX/mouseY/mouseLayer plus
  ##    clickPending, consumed on the NEXT ctf_frame; browsers fire `click`
  ##    after `mouseup`, so a pointermove landing in that gap would relocate the
  ##    pending click and pin the wrong cog.
  ##  * Parking is signalled on `mouseLayer`, never on a coordinate. Nim's `div`
  ##    truncates toward zero, so a parked `mouseX = -1` becomes 0 in the hit
  ##    test and hovers the arena's top-left corner forever.
  if not runtimeLoaded:
    return
  if viewer.clickPending or viewer.mouseDown:
    return
  if x < 0 or y < 0:
    viewer.mouseLayer = -1
    return
  viewer.mouseLayer = MapLayerId
  viewer.mouseX = int(x)
  viewer.mouseY = int(y)

proc ctfSetGloryObserver(enabled: cint)
    {.exportc: "ctf_set_glory_observer", cdecl.} =
  ## DEV RIG (deletable scaffolding): arm the glory-observer lens. Must be
  ## called BEFORE ctf_load_replay (see the keyframe note in ctfLoadReplay);
  ## also listed in config.nims EXPORTED_FUNCTIONS or emcc dead-strips it.
  gloryObserver = enabled != 0

proc ctfFrame(): cint {.exportc: "ctf_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  try:
    let seekTicks =
      if viewer.replaySeekTick >= 0: @[viewer.replaySeekTick]
      else: newSeq[int]()
    let events = replay.advanceReplayFrame(
      game,
      tracker,
      seekTicks,
      viewer.replayCommands
    )
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

proc ctfMismatchTick(): cint {.exportc: "ctf_mismatch_tick", cdecl.} =
  if runtimeLoaded and not gloryObserver:
    cint(replay.hashMismatchTick)
  else:
    -1

proc ctfErrorPointer(): ptr uint8 {.exportc: "ctf_error_ptr", cdecl.} =
  if lastError.len == 0:
    nil
  else:
    cast[ptr uint8](lastError[0].addr)

proc ctfErrorLength(): cint {.exportc: "ctf_error_len", cdecl.} =
  cint(lastError.len)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  # Nim's generated main runs every module-global destructor when it returns,
  # freeing ArenaObstacles, render caches, fonts — everything — while the wasm
  # module stays alive and JS keeps calling ctf_load_replay/ctf_frame. The
  # whole session then runs on freed globals: replay hashes get overwritten by
  # later allocations (spurious "REPLAY HASH MISMATCH — SHOWING RECORDED
  # INPUTS" + frozen-at-spawn playback) and seeks crash out of bounds.
  # Unwinding main through emscripten's live-runtime exit skips the destructor
  # epilogue entirely, so globals stay valid for the life of the page.
  emscriptenExitWithLiveRuntime()
