import
  std/json,
  ctf/[broadcast, global, replay_runtime, replays, sim]

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

proc renderCurrent(events: JsonNode) =
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
  if runtimeLoaded:
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
