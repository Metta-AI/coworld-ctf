## SDK hello play: manifest + init + step + retune through the real ABI.

import ../play

const
  ManifestBytes =
    "{\"abi\":1,\"class\":\"controller\",\"doc\":\"hello play\",\"modes\":[\"br\",\"ctf\",\"koth\"],\"name\":\"hello\",\"params\":{},\"retune\":true}"

proc play_manifest*() {.exportc, cdecl.} =
  discard emitRaw(ManifestBytes)

proc play_init*(paramsPtr, paramsLen, ctxPtr, ctxLen: int32): int32 {.
    exportc, cdecl.} =
  discard paramsPtr
  discard paramsLen
  discard context(ctxPtr, ctxLen)
  resetArena()
  0

proc play_step*(viewPtr, viewLen: int32): int32 {.exportc, cdecl.} =
  discard view(viewPtr, viewLen)
  let goal = nearestReachable(30, 30)
  let code = emitNavigateController(goal, "24.0", "hello")
  if code < 0:
    return code
  0

proc play_retune*(oldPtr, oldLen, newPtr, newLen: int32): int32 {.
    exportc, cdecl.} =
  discard oldPtr
  discard oldLen
  discard newPtr
  discard newLen
  resetArena()
  0
