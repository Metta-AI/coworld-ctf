## Season 2 play-seat wire codec for the Nim baseline, transcribed from the
## same ground truth the Python starters' `policies/poc_llm_policy/wire.py`
## was written from: the opcode table and wire limits in `src/shell/types.nim`
## and the exact field order / rejection rules in `src/shell/packets.nim`
## (docs/designs/strategy-play-calling-shell-2026-08-29.md §4.3). Nothing here
## links against the engine; this is what an outside client has to write.
##
## Scope: this baseline only ever SENDS ModuleUpload (0xA0), PlayCall (0xA1)
## and StatusAck (0xA2) -- never LobbyChat (0xA3), and never any legacy
## Sprite v1 client opcode (see baseline.nim's protocol dispatch). It DECODES
## PlayContext (0xB0) and PlayView (0xB1); LobbyChatBroadcast (0xB2) decodes
## structurally (for a future consumer) but this baseline does not act on it.

type
  S2WireError* = object of CatchableError
    ## A packet the production codec would have rejected, or one this
    ## client tried to send past its own size caps.

const
  OpModuleUpload* = 0xA0'u8
  OpPlayCall* = 0xA1'u8
  OpStatusAck* = 0xA2'u8
  OpLobbyChatSend* = 0xA3'u8
  OpPlayContext* = 0xB0'u8
  OpPlayView* = 0xB1'u8
  OpLobbyChatBroadcast* = 0xB2'u8

  ShellProtocolVersion* = 1'u8

  MaxModuleBytes* = 262144
  MaxCallBytes* = 4096

# ── little-endian byte packing ────────────────────────────────────────────

proc putU8(buf: var string, v: uint8) {.inline.} =
  buf.add(char(v))

proc putU32LE(buf: var string, v: uint32) {.inline.} =
  var x = v
  for _ in 0 ..< 4:
    buf.add(char(x and 0xff'u32))
    x = x shr 8

proc putU64LE(buf: var string, v: uint64) {.inline.} =
  var x = v
  for _ in 0 ..< 8:
    buf.add(char(x and 0xff'u64))
    x = x shr 8

# ── client -> server encoders ──────────────────────────────────────────────

proc encodeModuleUpload*(uploadId: uint64, wasm: string): string =
  ## 0xA0: u8 op, u8 ver, u64 uploadId, u32 len, u8[len] wasm. Total 14+len.
  if wasm.len > MaxModuleBytes:
    raise newException(S2WireError,
      "module is " & $wasm.len & " bytes, cap is " & $MaxModuleBytes)
  result = newStringOfCap(14 + wasm.len)
  result.putU8(OpModuleUpload)
  result.putU8(ShellProtocolVersion)
  result.putU64LE(uploadId)
  result.putU32LE(uint32(wasm.len))
  result.add(wasm)

proc encodePlayCall*(proposalId: uint64, callJson: string): string =
  ## 0xA1: u8 op, u8 ver, u64 proposalId, u32 len, canonical ladder JSON.
  if callJson.len > MaxCallBytes:
    raise newException(S2WireError,
      "call is " & $callJson.len & " bytes, cap is " & $MaxCallBytes)
  result = newStringOfCap(14 + callJson.len)
  result.putU8(OpPlayCall)
  result.putU8(ShellProtocolVersion)
  result.putU64LE(proposalId)
  result.putU32LE(uint32(callJson.len))
  result.add(callJson)

proc encodeStatusAck*(mark: uint64): string =
  ## 0xA2: u8 op, u8 ver, u8[6] reserved zero, u64 mark. Fixed 16 bytes.
  result = newStringOfCap(16)
  result.putU8(OpStatusAck)
  result.putU8(ShellProtocolVersion)
  for _ in 0 ..< 6:
    result.add(char(0))
  result.putU64LE(mark)

# ── server -> client decoders ──────────────────────────────────────────────

type
  S2PacketKind* = enum
    spkIgnored     ## not one of this client's opcodes (§4.3: a play socket
                   ## may also carry the legacy Sprite v1 stream; ignoring
                   ## anything outside 0xB0/0xB1/0xB2 is the conforming
                   ## behaviour, not an error)
    spkPlayContext
    spkPlayView
    spkLobbyChat

  S2Packet* = object
    case kind*: S2PacketKind
    of spkPlayContext:
      control*: string
      context*: string
    of spkPlayView:
      tick*: uint32
      viewControl*: string
      view*: string
    of spkLobbyChat:
      ordinal*: uint64
      chatTick*: uint32
      seat*: uint8
      team*: uint8
      text*: string
    of spkIgnored:
      discard

proc take(data: string, at: var int, count: int): string =
  if count < 0 or at + count > data.len:
    raise newException(S2WireError, "short packet at offset " & $at)
  result = data[at ..< at + count]
  at += count

proc takeU8(data: string, at: var int): uint8 =
  uint8(take(data, at, 1)[0])

proc takeU32(data: string, at: var int): uint32 =
  let b = take(data, at, 4)
  result = uint32(b[0].uint8) or (uint32(b[1].uint8) shl 8) or
    (uint32(b[2].uint8) shl 16) or (uint32(b[3].uint8) shl 24)

proc takeU64(data: string, at: var int): uint64 =
  let b = take(data, at, 8)
  for i in 0 ..< 8:
    result = result or (uint64(b[i].uint8) shl (8 * i))

proc takePayload(data: string, at: var int): string =
  let n = int(takeU32(data, at))
  take(data, at, n)

proc isPlayContextOpcode*(data: string): bool {.inline.} =
  ## The protocol-detection predicate: true when a message's leading byte is
  ## `OpPlayContext` (0xB0) -- what a Season 2 seat's server sends,
  ## unprompted, as the very first message on a fresh socket (§4.3). Kept as
  ## a standalone pure function (rather than inlined at the call site) so
  ## the dispatch decision itself is unit-testable without a live socket.
  data.len > 0 and uint8(data[0]) == OpPlayContext

proc decodeServerPacket*(data: string): S2Packet =
  ## Decodes one 0xB0/0xB1/0xB2 packet. Anything else comes back
  ## `spkIgnored`; only a message whose leading byte IS one of this
  ## client's opcodes and then fails to parse is a real protocol violation.
  if data.len == 0:
    return S2Packet(kind: spkIgnored)
  let opcode = uint8(data[0])
  if opcode notin [OpPlayContext, OpPlayView, OpLobbyChatBroadcast]:
    return S2Packet(kind: spkIgnored)
  if data.len < 2 or uint8(data[1]) != ShellProtocolVersion:
    raise newException(S2WireError, "wrong protocol version")
  var at = 2
  case opcode
  of OpPlayContext:
    let control = takePayload(data, at)
    let context = takePayload(data, at)
    if at != data.len:
      raise newException(S2WireError, "trailing bytes")
    result = S2Packet(kind: spkPlayContext, control: control, context: context)
  of OpPlayView:
    let tick = takeU32(data, at)
    let control = takePayload(data, at)
    let view = takePayload(data, at)
    if at != data.len:
      raise newException(S2WireError, "trailing bytes")
    result = S2Packet(kind: spkPlayView, tick: tick, viewControl: control,
      view: view)
  else: # OpLobbyChatBroadcast
    let ordinal = takeU64(data, at)
    let chatTick = takeU32(data, at)
    let seat = takeU8(data, at)
    let team = takeU8(data, at)
    let text = takePayload(data, at)
    if at != data.len:
      raise newException(S2WireError, "trailing bytes")
    result = S2Packet(kind: spkLobbyChat, ordinal: ordinal, chatTick: chatTick,
      seat: seat, team: team, text: text)

# ── canonical JSON for OUR fixed, closed vocabulary of outgoing calls ──────
#
# Full canonical JSON (src/shell/canonical.nim) sorts object keys and spells
# floats in a specific shortest-round-trip grammar; this baseline never emits
# a float and only ever emits play names, entry ids and enum tags IT chooses
# itself (never user or wire-sourced text), so a general escaping encoder is
# unneeded machinery. These builders hard-code the one property order each
# shape needs (alphabetical: "entry_id" < "params" < "play") and assume every
# string passed in is from the closed literal sets in s2play.nim.

proc jstr(s: string): string {.inline.} =
  "\"" & s & "\""

proc canonicalEntry*(play, entryId: string, preferTags: seq[string] = @[]): string =
  if preferTags.len == 0:
    return "{\"entry_id\":" & jstr(entryId) & ",\"play\":" & jstr(play) & "}"
  var tags = "["
  for i, t in preferTags:
    if i > 0: tags.add(",")
    tags.add(jstr(t))
  tags.add("]")
  "{\"entry_id\":" & jstr(entryId) & ",\"params\":{\"prefer\":" & tags &
    "},\"play\":" & jstr(play) & "}"

proc canonicalLadder*(entries: seq[string]): string =
  result = "{\"plays\":["
  for i, e in entries:
    if i > 0: result.add(",")
    result.add(e)
  result.add("]}")
