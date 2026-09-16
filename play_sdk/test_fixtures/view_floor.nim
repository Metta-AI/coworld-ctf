## Test-only WASM probe for the SDK's tight view-byte walk floor.

import ../play

const
  ManifestBytes =
    "{\"abi\":1,\"class\":\"overlay\",\"doc\":\"test-only SDK view byte-walk floor\",\"modes\":[\"br\"],\"name\":\"view_floor\",\"params\":{},\"retune\":true}"

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
  let bytes = cast[ptr UncheckedArray[byte]](viewPtr)
  var index = 0'i32
  var acc = sink
  while index < viewLen:
    acc += int32(bytes[index])
    inc index
  sink = acc
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
