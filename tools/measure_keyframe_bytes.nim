## Measures the REAL keyframe-stream footprint of a recorded `.bitreplay` —
## the exact in-memory structure the wasm viewer builds via
## `buildReplayKeyframes` to support scrubbing/seeking. Every keyframe
## flatty-serializes the WHOLE SimServer (minus the static map bakes, see
## replays.nim's serializeReplaySim), which includes every player's
## `policyPage` string verbatim — so a replay with many page-carrying seats
## multiplies that string across every keyframe.
##
## This is the measurement instrument for the page-size-cap hazard: given a
## replay recorded by the live server, load it exactly the way the viewer
## does and report the real byte totals, not a modelled estimate.
##
## Usage: measure_keyframe_bytes <replay.bitreplay>

import
  std/[os, strformat],
  ../src/ctf/[replays, sim]

const GameDir = currentSourcePath.parentDir.parentDir

proc initReplaySim(data: ReplayData): SimServer =
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    var config = defaultGameConfig()
    config.update(data.configJson)
    result = initSimServer(config)
    result.gameEventLoggingEnabled = false
  finally:
    setCurrentDir(previousDir)

when isMainModule:
  if paramCount() < 1:
    quit("Usage: measure_keyframe_bytes <replay.bitreplay>", 1)
  let
    path = paramStr(1)
    fileBytes = readFile(path)
    data = parseReplayBytes(fileBytes)

  var
    simState = data.initReplaySim()
    replay = initReplayPlayer(data)

  replay.buildReplayKeyframes(simState)

  var
    totalKeyframeBytes = 0
    maxKeyframeBytes = 0
    minKeyframeBytes = int.high
    maxPageCarryingSeats = 0
    maxPageBytesInOneKeyframe = 0

  echo &"replay file           : {path}"
  echo &"replay file bytes     : {fileBytes.len}"
  echo &"ticks recorded        : {data.hashes.len}"
  echo &"reflash chat records  : {data.chats.len}"
  echo &"keyframe count        : {replay.keyframes.len}"
  echo "tick    simBytes  pageCarryingSeats  pageBytesSum"

  # Restore EACH keyframe in turn (the same donor-swap seekReplay uses) so
  # we see the real per-keyframe policyPage footprint at the tick it was
  # actually captured at, not just the replay's final state (which can read
  # 0 page-carrying seats simply because every seat had disconnected by the
  # time the match ended).
  for kf in replay.keyframes:
    totalKeyframeBytes += kf.simBytes.len
    maxKeyframeBytes = max(maxKeyframeBytes, kf.simBytes.len)
    minKeyframeBytes = min(minKeyframeBytes, kf.simBytes.len)
    replay.seekReplay(simState, kf.tick)
    var
      pageBytes = 0
      pageCarrying = 0
    for p in simState.players:
      if p.policyPage.len > 0:
        inc pageCarrying
        pageBytes += p.policyPage.len
    maxPageCarryingSeats = max(maxPageCarryingSeats, pageCarrying)
    maxPageBytesInOneKeyframe = max(maxPageBytesInOneKeyframe, pageBytes)
    echo &"{kf.tick:>5}   {kf.simBytes.len:>9}  {pageCarrying:>17}  {pageBytes:>12}"

  echo &"keyframe bytes, total : {totalKeyframeBytes}"
  echo &"keyframe bytes, min   : {(if replay.keyframes.len > 0: minKeyframeBytes else: 0)}"
  echo &"keyframe bytes, max   : {maxKeyframeBytes}"
  if replay.keyframes.len > 0:
    echo &"keyframe bytes, avg   : {totalKeyframeBytes div replay.keyframes.len}"
  echo &"max page-carrying seats in any one keyframe : {maxPageCarryingSeats}"
  echo &"max policyPage bytes summed in any one keyframe : {maxPageBytesInOneKeyframe}"
