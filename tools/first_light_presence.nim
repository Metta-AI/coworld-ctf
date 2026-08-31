## Presence-only FIRST LIGHT seat client: connects, receives views, and sends
## readiness. It sends no input, policy, upload, call, or chat bytes.

import std/[options, os]
import whisky

proc readyBlob(): string =
  result = newString(1)
  result[0] = char(0x85)

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var socket: WebSocket
  for _ in 0 ..< 240:
    try:
      socket = newWebSocket(url)
      break
    except CatchableError:
      sleep(500)
  if socket == nil:
    quit("FIRST LIGHT presence client could not connect", 1)
  try:
    while true:
      let message = socket.receiveMessage()
      if message.isSome:
        socket.send(readyBlob(), BinaryMessage)
  except CatchableError:
    discard
