## Test-only WASM probe for measuring SDK view-read fuel in `play_step`.

import ../play

const
  ManifestBytes =
    "{\"abi\":1,\"class\":\"overlay\",\"doc\":\"test-only SDK view reader meter\",\"modes\":[\"br\"],\"name\":\"view_meter\",\"params\":{},\"retune\":true}"

var sink: int32

proc play_manifest*() {.exportc, cdecl.} =
  discard emitRaw(ManifestBytes)

proc play_init*(paramsPtr, paramsLen, ctxPtr, ctxLen: int32): int32 {.
    exportc, cdecl.} =
  discard paramsPtr
  discard paramsLen
  discard ctxPtr
  discard ctxLen
  resetArena()
  sink = 0
  0

proc play_step*(viewPtr, viewLen: int32): int32 {.exportc, cdecl.} =
  var decoded: SdkView
  if not readViewInto(view(viewPtr, viewLen), decoded):
    return 1
  sink += decoded.tick + decoded.epoch + decoded.trackCount +
    decoded.aggressorCount + decoded.killFeedCount
  sink += decoded.self.hp + decoded.self.aimBrads
  sink += decoded.world.aliveTeams + decoded.world.zone.phase +
    decoded.world.zone.ticksToShrink
  resetArena()
  0

proc play_retune*(oldPtr, oldLen, newPtr, newLen: int32): int32 {.
    exportc, cdecl.} =
  discard oldPtr
  discard oldLen
  discard newPtr
  discard newLen
  resetArena()
  0
