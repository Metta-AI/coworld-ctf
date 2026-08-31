## Minimal no-WASI play used by the runtime containment smoke.

const
  ArenaBytes = 32 * 1024
  HelloBytes = [byte 104, 101, 108, 108, 111]

var
  arena: array[ArenaBytes, byte]
  nextOffset: int32

proc playEmit(data: int32; length: int32): int32 {.importc: "play_emit",
    cdecl, header: "hello_imports.h".}

proc play_alloc*(length: int32): int32 {.exportc, cdecl.} =
  if length <= 0 or length > ArenaBytes.int32 - nextOffset:
    return 0
  result = cast[int32](addr arena[nextOffset])
  nextOffset += length

proc play_init*(paramsPtr, paramsLen, ctxPtr, ctxLen: int32): int32 {.
    exportc, cdecl.} =
  discard paramsPtr
  discard paramsLen
  discard ctxPtr
  discard ctxLen
  nextOffset = 0
  0

proc play_step*(viewPtr, viewLen: int32): int32 {.exportc, cdecl.} =
  discard viewPtr
  discard viewLen
  let messagePtr = cast[int32](unsafeAddr HelloBytes[0])
  playEmit(messagePtr, HelloBytes.len.int32)
