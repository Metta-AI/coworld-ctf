proc playLog(level: int32; data: int32; length: int32) {.importc: "play_log",
  cdecl, header: "play_imports.h".}

proc rawoutput(s: string) =
  if s.len > 0:
    playLog(3, cast[int32](unsafeAddr s[0]), s.len.int32)

proc panic(s: string) {.noreturn.} =
  rawoutput(s)
  {.emit: "__builtin_trap();".}
  while true:
    discard
