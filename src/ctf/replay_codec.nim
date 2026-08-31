## CTF replay-load compatibility frontend.
##
## bitworld remains the format-1 writer and parser. This layer admits the
## explicitly compatible CTF game versions and owns format 2 so its reserved
## shell records can be added without changing bitworld's generic codec.

import
  std/strutils,
  zippy,
  bitworld/replays as replayCodec,
  ../shell/types

proc readU8(bytes: string, offset: var int): uint8 =
  if offset + 1 > bytes.len:
    raise newException(ReplayError, "Replay file is truncated at byte " & $offset)
  result = bytes[offset].uint8
  inc offset

proc readU16(bytes: string, offset: var int): uint16 =
  if offset + 2 > bytes.len:
    raise newException(ReplayError, "Replay file is truncated at byte " & $offset)
  result = uint16(bytes[offset].uint8) or
    (uint16(bytes[offset + 1].uint8) shl 8)
  offset += 2

proc readI16(bytes: string, offset: var int): int =
  int(cast[int16](bytes.readU16(offset)))

proc readU32(bytes: string, offset: var int): uint32 =
  if offset + 4 > bytes.len:
    raise newException(ReplayError, "Replay file is truncated at byte " & $offset)
  for shift in countup(0, 24, 8):
    result = result or (uint32(bytes[offset].uint8) shl shift)
    inc offset

proc readU64(bytes: string, offset: var int): uint64 =
  if offset + 8 > bytes.len:
    raise newException(ReplayError, "Replay file is truncated at byte " & $offset)
  for shift in countup(0, 56, 8):
    result = result or (uint64(bytes[offset].uint8) shl shift)
    inc offset

proc readReplayString(bytes: string, offset: var int): string =
  let length = int(bytes.readU16(offset))
  if offset + length > bytes.len:
    raise newException(ReplayError, "Replay file is truncated at byte " & $offset)
  result = bytes[offset ..< offset + length]
  offset += length

proc readReplayBytes(bytes: string, offset: var int): seq[uint8] =
  let length = int(bytes.readU32(offset))
  if offset + length > bytes.len:
    raise newException(ReplayError, "Replay file is truncated at byte " & $offset)
  result = newSeq[uint8](length)
  for index in 0 ..< length:
    result[index] = bytes[offset + index].uint8
  offset += length

proc isCompressedReplayBytes(bytes: string): bool =
  if bytes.len > 18:
    let
      b0 = bytes[0].uint8
      b1 = bytes[1].uint8
      b2 = bytes[2].uint8
      b3 = bytes[3].uint8
    if b0 == 31'u8 and b1 == 139'u8 and b2 == 8'u8 and
        (b3 and 224'u8) == 0'u8:
      return true

  if bytes.len > 6:
    let
      b0 = bytes[0].uint8
      b1 = bytes[1].uint8
    if (b0 and 15'u8) == 8'u8 and (b0 shr 4) <= 7'u8 and
        ((uint16(b0) * 256'u16 + uint16(b1)) mod 31'u16) == 0'u16:
      return true

proc replayPayloadBytes(bytes: string, spec: ReplaySpec): string =
  if bytes.startsWith(spec.magic):
    return bytes
  if spec.allowCompressed and bytes.isCompressedReplayBytes():
    return uncompress(bytes)
  bytes

proc isCompatible(
  gameVersion: string,
  compatibleGameVersions: openArray[string]
): bool =
  for compatibleVersion in compatibleGameVersions:
    if gameVersion == compatibleVersion:
      return true

proc readHeader(
  replayBytes: string,
  spec: ReplaySpec,
  compatibleGameVersions: openArray[string],
  offset: var int
): tuple[formatVersion: uint16, data: ReplayData] =
  if replayBytes.len < spec.magic.len:
    raise newException(ReplayError, "Replay file is truncated")
  if replayBytes[0 ..< spec.magic.len] != spec.magic:
    raise newException(ReplayError, "Replay magic does not match")
  offset = spec.magic.len
  result.formatVersion = replayBytes.readU16(offset)
  if result.formatVersion notin [1'u16, 2'u16]:
    raise newException(ReplayError, "Unsupported replay format version")
  result.data.gameName = replayBytes.readReplayString(offset)
  result.data.gameVersion = replayBytes.readReplayString(offset)
  discard replayBytes.readU64(offset)
  result.data.configJson = replayBytes.readReplayString(offset)
  if result.data.gameName != spec.gameName:
    raise newException(ReplayError, "Replay game name does not match")
  if not result.data.gameVersion.isCompatible(compatibleGameVersions):
    raise newException(
      ReplayError,
      "Replay game version " & result.data.gameVersion.escape() &
        " is not compatible"
    )

proc readJoin(
  replayBytes: string,
  offset: var int,
  spec: ReplaySpec
): ReplayJoin =
  result.time = replayBytes.readU32(offset)
  result.player = replayBytes.readU8(offset)
  case spec.joinKind
  of rjkNameSlotToken:
    result.name = replayBytes.readReplayString(offset)
    result.slot = replayBytes.readI16(offset)
    result.token = replayBytes.readReplayString(offset)
  of rjkAddress:
    result.address = replayBytes.readReplayString(offset)
    result.name = result.address

proc parseFormat2Records(
  replayBytes: string,
  offset: var int,
  spec: ReplaySpec,
  replay: var ReplayData
) =
  var
    lastTick = -1
    lastInputTime = 0'u32
    lastJoinTime = 0'u32
    lastLeaveTime = 0'u32
    lastChatTime = 0'u32
    lastDebugSpriteTime = 0'u32
  while offset < replayBytes.len:
    let recordType = replayBytes.readU8(offset)
    case recordType
    of ReplayTickHashRecord:
      let
        tick = replayBytes.readU32(offset)
        hash = replayBytes.readU64(offset)
      if int(tick) <= lastTick:
        case spec.hashOrder
        of rhoStop:
          break
        of rhoError:
          raise newException(ReplayError, "Replay tick hashes move backward")
      lastTick = int(tick)
      replay.hashes.add(ReplayHash(tick: tick, hash: hash))
    of ReplayInputRecord:
      let input = ReplayInput(
        time: replayBytes.readU32(offset),
        player: replayBytes.readU8(offset),
        keys: replayBytes.readU8(offset)
      )
      if input.time < lastInputTime:
        raise newException(ReplayError, "Replay input timestamps move backward")
      lastInputTime = input.time
      replay.inputs.add(input)
    of ReplayJoinRecord:
      let join = replayBytes.readJoin(offset, spec)
      if join.time < lastJoinTime:
        raise newException(ReplayError, "Replay join timestamps move backward")
      lastJoinTime = join.time
      replay.joins.add(join)
    of ReplayLeaveRecord:
      let leave = ReplayLeave(
        time: replayBytes.readU32(offset),
        player: replayBytes.readU8(offset)
      )
      if leave.time < lastLeaveTime:
        raise newException(ReplayError, "Replay leave timestamps move backward")
      lastLeaveTime = leave.time
      replay.leaves.add(leave)
    of ReplayChatRecord:
      if not spec.allowChat:
        raise newException(ReplayError, "Replay chat record is not supported")
      let chat = ReplayChat(
        time: replayBytes.readU32(offset),
        player: replayBytes.readU8(offset),
        message: replayBytes.readReplayString(offset)
      )
      if chat.time < lastChatTime:
        raise newException(ReplayError, "Replay chat timestamps move backward")
      lastChatTime = chat.time
      replay.chats.add(chat)
    of ReplayDebugSpriteRecord:
      let debugSprite = ReplayDebugSprite(
        time: replayBytes.readU32(offset),
        player: replayBytes.readU8(offset),
        packet: replayBytes.readReplayBytes(offset)
      )
      if debugSprite.time < lastDebugSpriteTime:
        raise newException(
          ReplayError,
          "Replay debug sprite timestamps move backward"
        )
      lastDebugSpriteTime = debugSprite.time
      replay.debugSprites.add(debugSprite)
    of RecPlayCall, RecBehaviorAnnotation, RecManifest, RecLobbyChat,
        RecDisconnect, RecKick, RecRebind:
      raise newException(
        ReplayError,
        "unsupported shell record in pre-bump reader"
      )
    else:
      raise newException(ReplayError, "Unknown replay record type")

proc parseReplayBytes*(
  bytes: string,
  spec: ReplaySpec,
  compatibleGameVersions: openArray[string]
): ReplayData =
  ## Parses one format-1 or format-2 CTF replay from memory.
  let replayBytes = bytes.replayPayloadBytes(spec)
  var offset = 0
  let header = replayBytes.readHeader(
    spec,
    compatibleGameVersions,
    offset
  )
  if header.formatVersion == 1'u16:
    let compatibleSpec = ReplaySpec(
      magic: spec.magic,
      formatVersion: header.formatVersion,
      gameName: spec.gameName,
      gameVersion: header.data.gameVersion,
      joinKind: spec.joinKind,
      allowChat: spec.allowChat,
      allowCompressed: spec.allowCompressed,
      hashOrder: spec.hashOrder
    )
    return replayCodec.parseReplayBytes(replayBytes, compatibleSpec)

  result = header.data
  replayBytes.parseFormat2Records(offset, spec, result)

proc loadReplay*(
  path: string,
  spec: ReplaySpec,
  compatibleGameVersions: openArray[string]
): ReplayData =
  ## Loads one format-1 or format-2 CTF replay from disk.
  parseReplayBytes(readFile(path), spec, compatibleGameVersions)
