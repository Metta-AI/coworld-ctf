## Minimal synchronous WebSocket client used by server-integration tests.

import std/[net, strutils]

type RawWebSocketClient* = object
  socket: Socket

proc connectRawWebSocket*(port: int, path: string): RawWebSocketClient =
  result.socket = newSocket()
  result.socket.connect("127.0.0.1", Port(port))
  result.socket.send(
    "GET " & path & " HTTP/1.1\r\n" &
    "Host: 127.0.0.1\r\n" &
    "Connection: Upgrade\r\n" &
    "Upgrade: websocket\r\n" &
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" &
    "Sec-WebSocket-Version: 13\r\n\r\n")
  var response = ""
  while not response.endsWith("\r\n\r\n"):
    let byte = result.socket.recv(1, timeout = 5000)
    doAssert byte.len == 1, "unexpected EOF during WebSocket upgrade"
    response &= byte
  doAssert response.startsWith("HTTP/1.1 101")

proc sendBinary*(client: RawWebSocketClient, payload: string) =
  const mask = [0x12'u8, 0x34'u8, 0x56'u8, 0x78'u8]
  var frame = newStringOfCap(payload.len + 14)
  frame.add(0x82.char)
  if payload.len < 126:
    frame.add(char(0x80 or payload.len))
  elif payload.len <= 0xffff:
    frame.add(0xfe.char)
    frame.add(char((payload.len shr 8) and 0xff))
    frame.add(char(payload.len and 0xff))
  else:
    frame.add(0xff.char)
    for shift in countdown(56, 0, 8):
      frame.add(char((uint64(payload.len) shr shift) and 0xff))
  for byte in mask:
    frame.add(char(byte))
  for index, byte in payload:
    frame.add(char(byte.uint8 xor mask[index mod mask.len]))
  client.socket.send(frame)

proc recvExact(socket: Socket; length: int; timeoutMs: int): string =
  result = newStringOfCap(length)
  while result.len < length:
    let chunk = socket.recv(length - result.len, timeout = timeoutMs)
    doAssert chunk.len > 0, "unexpected EOF while reading WebSocket frame"
    result.add(chunk)

proc recvBinary*(client: RawWebSocketClient; timeoutMs = 5000): string =
  let header = client.socket.recvExact(2, timeoutMs)
  doAssert (uint8(header[0]) and 0x0f'u8) == 0x02'u8,
    "expected a binary WebSocket frame"
  doAssert (uint8(header[1]) and 0x80'u8) == 0,
    "server WebSocket frames must not be masked"
  var length = uint64(uint8(header[1]) and 0x7f'u8)
  if length == 126:
    let extended = client.socket.recvExact(2, timeoutMs)
    length = (uint64(uint8(extended[0])) shl 8) or uint64(uint8(extended[1]))
  elif length == 127:
    let extended = client.socket.recvExact(8, timeoutMs)
    length = 0
    for byte in extended:
      length = (length shl 8) or uint64(uint8(byte))
  doAssert length <= uint64(high(int))
  client.socket.recvExact(int(length), timeoutMs)

proc close*(client: RawWebSocketClient) =
  client.socket.close()
