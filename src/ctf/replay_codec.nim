## CTF replay-load compatibility frontend.
##
## bitworld remains the format-1 writer and parser. This layer admits the
## explicitly compatible CTF game versions and owns format 2 so its reserved
## shell records can be added without changing bitworld's generic codec.

import
  std/[json, strutils, times],
  zippy,
  bitworld/replays as replayCodec,
  ../shell/[replay_records, types]

type
  CtfReplayData* = object
    replay*: ReplayData
    shell*: ShellReplayRecords

  CtfReplayWriter* = object
    enabled*: bool
    shellEpisode*: bool
    legacyWriter: replayCodec.ReplayWriter
    file: File
    callRecords: seq[seq[string]]
    annotationRecords: seq[seq[string]]
    transcriptRecords: seq[string]
    manifestWritten: bool

const
  ShellReplayFormatVersion* = 2'u16

proc writeU8(file: File, value: uint8) =
  file.write(char(value))

proc writeU16(file: File, value: uint16) =
  file.writeU8(uint8(value and 0xff'u16))
  file.writeU8(uint8(value shr 8))

proc writeU32(file: File, value: uint32) =
  for shift in countup(0, 24, 8):
    file.writeU8(uint8((value shr shift) and 0xff'u32))

proc writeI16(file: File, value: int) =
  file.writeU16(cast[uint16](int16(value)))

proc writeU64(file: File, value: uint64) =
  for shift in countup(0, 56, 8):
    file.writeU8(uint8((value shr shift) and 0xff'u64))

proc writeReplayString(file: File, value: string) =
  if value.len > high(uint16).int:
    raise newException(ReplayError, "Replay string is too long")
  file.writeU16(uint16(value.len))
  file.write(value)

proc writeReplayBytes(file: File, value: openArray[uint8]) =
  if uint64(value.len) > uint64(high(uint32)):
    raise newException(ReplayError, "Replay byte array is too long")
  file.writeU32(uint32(value.len))
  for item in value:
    file.writeU8(item)

proc writeRaw(writer: var CtfReplayWriter, bytes: string) =
  if writer.enabled and writer.shellEpisode:
    if writer.manifestWritten:
      raise newException(ReplayError,
        "shell replay manifest is already final")
    writer.file.write(bytes)

proc ensureSeatBucket(writer: var CtfReplayWriter, seat: uint8) =
  if int(seat) >= writer.callRecords.len:
    raise newException(ReplayError, "shell replay seat is out of range")

proc openReplayWriter*(
  path: string,
  configJson: string,
  spec: ReplaySpec,
  shellEpisode: bool,
  shellSeatCount = 0,
  openedAtMs = 0'u64,
): CtfReplayWriter =
  ## Opens the CTF-owned replay writer. The caller makes the gate decision;
  ## P5a deliberately does not wire this into the live server. Non-shell
  ## output delegates wholly to bitworld's format-1 writer.
  result.shellEpisode = shellEpisode
  if not shellEpisode:
    result.legacyWriter = replayCodec.openReplayWriter(path, configJson, spec)
    result.enabled = result.legacyWriter.enabled
    return
  if shellSeatCount < 0 or shellSeatCount > 256:
    raise newException(ReplayError, "shell replay seat count is out of range")
  if path.len == 0:
    return
  if not open(result.file, path, fmWrite):
    raise newException(IOError, "Could not open replay file: " & path)
  result.enabled = true
  result.callRecords = newSeq[seq[string]](shellSeatCount)
  result.annotationRecords = newSeq[seq[string]](shellSeatCount)
  result.file.write(spec.magic)
  result.file.writeU16(ShellReplayFormatVersion)
  result.file.writeReplayString(spec.gameName)
  result.file.writeReplayString(spec.gameVersion)
  let timestamp =
    if openedAtMs != 0'u64:
      openedAtMs
    else:
      uint64(toUnix(getTime())) * 1000'u64
  result.file.writeU64(timestamp)
  result.file.writeReplayString(configJson)

proc writeJoin*(writer: var CtfReplayWriter, time: uint32, player: int,
                name: string, slot: int, token: string) =
  if not writer.enabled:
    return
  if not writer.shellEpisode:
    replayCodec.writeJoin(writer.legacyWriter, time, player, name, slot, token)
    return
  if writer.manifestWritten:
    raise newException(ReplayError, "shell replay manifest is already final")
  writer.file.writeU8(ReplayJoinRecord)
  writer.file.writeU32(time)
  writer.file.writeU8(uint8(player))
  writer.file.writeReplayString(name)
  writer.file.writeI16(slot)
  writer.file.writeReplayString(token)

proc writeJoin*(writer: var CtfReplayWriter, time: uint32, player: int,
                address: string) =
  if not writer.enabled:
    return
  if not writer.shellEpisode:
    replayCodec.writeJoin(writer.legacyWriter, time, player, address)
    return
  if writer.manifestWritten:
    raise newException(ReplayError, "shell replay manifest is already final")
  writer.file.writeU8(ReplayJoinRecord)
  writer.file.writeU32(time)
  writer.file.writeU8(uint8(player))
  writer.file.writeReplayString(address)

proc writeLeave*(writer: var CtfReplayWriter, time: uint32, player: int) =
  if not writer.enabled:
    return
  if not writer.shellEpisode:
    replayCodec.writeLeave(writer.legacyWriter, time, player)
    return
  if writer.manifestWritten:
    raise newException(ReplayError, "shell replay manifest is already final")
  writer.file.writeU8(ReplayLeaveRecord)
  writer.file.writeU32(time)
  writer.file.writeU8(uint8(player))

proc writeInput*(writer: var CtfReplayWriter, input: ReplayInput) =
  if not writer.enabled:
    return
  if not writer.shellEpisode:
    replayCodec.writeInput(writer.legacyWriter, input)
    return
  if writer.manifestWritten:
    raise newException(ReplayError, "shell replay manifest is already final")
  writer.file.writeU8(ReplayInputRecord)
  writer.file.writeU32(input.time)
  writer.file.writeU8(input.player)
  writer.file.writeU8(input.keys)

proc writeChat*(writer: var CtfReplayWriter, time: uint32, player: int,
                message: string) =
  if not writer.enabled:
    return
  if not writer.shellEpisode:
    replayCodec.writeChat(writer.legacyWriter, time, player, message)
    return
  if writer.manifestWritten:
    raise newException(ReplayError, "shell replay manifest is already final")
  writer.file.writeU8(ReplayChatRecord)
  writer.file.writeU32(time)
  writer.file.writeU8(uint8(player))
  writer.file.writeReplayString(message)

proc writeDebugSprite*(writer: var CtfReplayWriter, time: uint32,
                       player: int, packet: openArray[uint8]) =
  if not writer.enabled:
    return
  if not writer.shellEpisode:
    replayCodec.writeDebugSprite(writer.legacyWriter, time, player, packet)
    return
  if writer.manifestWritten:
    raise newException(ReplayError, "shell replay manifest is already final")
  writer.file.writeU8(ReplayDebugSpriteRecord)
  writer.file.writeU32(time)
  writer.file.writeU8(uint8(player))
  writer.file.writeReplayBytes(packet)

proc writeHash*(writer: var CtfReplayWriter, tick: uint32, hash: uint64) =
  if not writer.enabled:
    return
  if not writer.shellEpisode:
    replayCodec.writeHash(writer.legacyWriter, tick, hash)
    return
  if writer.manifestWritten:
    raise newException(ReplayError, "shell replay manifest is already final")
  writer.file.writeU8(ReplayTickHashRecord)
  writer.file.writeU32(tick)
  writer.file.writeU64(hash)
  writer.file.flushFile()

proc writePlayCall*(writer: var CtfReplayWriter, record: PlayCallRecord) =
  if not writer.enabled:
    return
  if not writer.shellEpisode:
    raise newException(ReplayError, "shell record requires format 2")
  writer.ensureSeatBucket(record.seat)
  let bytes = record.encodePlayCallRecord()
  writer.callRecords[int(record.seat)].add(bytes)
  writer.writeRaw(bytes)

proc writeAnnotation*(writer: var CtfReplayWriter,
                      annotation: ShellAnnotation) =
  if not writer.enabled:
    return
  if not writer.shellEpisode:
    raise newException(ReplayError, "shell record requires format 2")
  writer.ensureSeatBucket(annotation.seat)
  let bytes = annotation.encodeAnnotationRecord()
  writer.annotationRecords[int(annotation.seat)].add(bytes)
  writer.writeRaw(bytes)

proc writeLobbyChat*(writer: var CtfReplayWriter, record: LobbyChatRecord) =
  if not writer.enabled:
    return
  if not writer.shellEpisode:
    raise newException(ReplayError, "shell record requires format 2")
  let bytes = record.encodeLobbyChatRecord()
  writer.transcriptRecords.add(bytes)
  writer.writeRaw(bytes)

proc writeLifecycle*(writer: var CtfReplayWriter, record: LifecycleRecord) =
  if not writer.enabled:
    return
  if not writer.shellEpisode:
    raise newException(ReplayError, "shell record requires format 2")
  writer.ensureSeatBucket(record.seat)
  writer.writeRaw(record.encodeLifecycleRecord())

proc writeManifest*(writer: var CtfReplayWriter) =
  if not writer.enabled or not writer.shellEpisode or writer.manifestWritten:
    return
  let manifest = buildShellReplayManifest(
    writer.callRecords, writer.annotationRecords, writer.transcriptRecords)
  writer.writeRaw(manifest.encodeManifestRecord())
  writer.manifestWritten = true

proc flushReplayWriter*(writer: var CtfReplayWriter) =
  if not writer.enabled:
    return
  if writer.shellEpisode:
    writer.file.flushFile()
  else:
    replayCodec.flushReplayWriter(writer.legacyWriter)

proc closeReplayWriter*(writer: var CtfReplayWriter) =
  if not writer.enabled:
    return
  if writer.shellEpisode:
    writer.writeManifest()
    writer.file.flushFile()
    writer.file.close()
  else:
    replayCodec.closeReplayWriter(writer.legacyWriter)
  writer.enabled = false

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
  let wireValue = bytes.readU16(offset)
  # The slot field is normatively signed i16; read its complete unsigned wire
  # representation first, then reinterpret that bounded value.
  int(cast[int16](wireValue))

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
  let
    length = bytes.readU16(offset)
    remaining = bytes.len - offset
  # Length is attacker-controlled. Bound the unsigned value before the int
  # conversion so wasm32 never narrows it into a signed domain first.
  if uint64(length) > uint64(remaining):
    raise newException(ReplayError, "Replay file is truncated at byte " & $offset)
  let checkedLength = int(length)
  result = bytes[offset ..< offset + checkedLength]
  offset += checkedLength

proc readReplayBytes(bytes: string, offset: var int): seq[uint8] =
  let
    length = bytes.readU32(offset)
    remaining = bytes.len - offset
  # Replay u32 values are checked unsigned before any int conversion; wasm32 is a first-class viewer target (§8).
  if uint64(length) > uint64(remaining):
    raise newException(ReplayError, "Replay file is truncated at byte " & $offset)
  let checkedLength = int(length)
  result = newSeq[uint8](checkedLength)
  for index in 0 ..< checkedLength:
    result[index] = bytes[offset + index].uint8
  offset += checkedLength

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

proc playSeatsFromConfig(configJson: string): seq[bool] =
  try:
    let config = parseJson(configJson)
    if config.kind != JObject or not config.hasKey("slots") or
        config["slots"].kind != JArray:
      return
    for slot in config["slots"]:
      result.add(
        slot.kind == JObject and slot.hasKey("control") and
        slot["control"].kind == JString and
        slot["control"].getStr() == "play")
  except JsonParsingError:
    raise newException(ReplayError, "Replay config JSON is invalid")

proc noteRecordOrder(time: uint32, phase: uint8, name: string,
                     hasTime: var bool, lastTime: var uint32,
                     lastPhase: var uint8) =
  ## At one replay time: join/legacy leave; lifecycle; ordinary Sprite
  ## input/chat; lobby transcript; call. A later phase may not be followed by
  ## an earlier one at the same time.
  if hasTime and time < lastTime:
    raise newException(ReplayError,
      "Replay record timestamps move backward at " & name)
  if hasTime and time == lastTime and phase < lastPhase:
    raise newException(ReplayError,
      "Replay same-time record ordering violation at " & name)
  if not hasTime or time > lastTime:
    lastPhase = phase
  else:
    lastPhase = max(lastPhase, phase)
  lastTime = time
  hasTime = true

proc verifyManifest(
  manifest: ShellReplayManifest,
  calls: openArray[tuple[seat: uint8, bytes: string]],
  annotations: openArray[tuple[seat: uint8, bytes: string]],
  transcript: openArray[string],
) =
  let seatCount = manifest.seats.len
  var
    callBuckets = newSeq[seq[string]](seatCount)
    annotationBuckets = newSeq[seq[string]](seatCount)
  for item in calls:
    if int(item.seat) >= seatCount:
      raise newException(ReplayError, "play-call seat is out of range")
    callBuckets[int(item.seat)].add(item.bytes)
  for item in annotations:
    if int(item.seat) >= seatCount:
      raise newException(ReplayError, "annotation seat is out of range")
    annotationBuckets[int(item.seat)].add(item.bytes)
  let computed = buildShellReplayManifest(
    callBuckets, annotationBuckets, transcript)
  for seat in 0 ..< seatCount:
    if manifest.seats[seat].callCount != computed.seats[seat].callCount or
        manifest.seats[seat].callChainSha256 !=
          computed.seats[seat].callChainSha256:
      raise newException(ReplayError,
        "play-call manifest verification failed for seat " & $seat)
    if manifest.seats[seat].annotationCount !=
          computed.seats[seat].annotationCount or
        manifest.seats[seat].annotationChainSha256 !=
          computed.seats[seat].annotationChainSha256:
      raise newException(ReplayError,
        "annotation manifest verification failed for seat " & $seat)
  if manifest.transcriptCount != computed.transcriptCount or
      manifest.transcriptChainSha256 != computed.transcriptChainSha256:
    raise newException(ReplayError,
      "lobby transcript manifest verification failed")

proc parseFormat2Records(
  replayBytes: string,
  offset: var int,
  spec: ReplaySpec,
  result: var CtfReplayData,
) =
  let configuredPlaySeats = result.replay.configJson.playSeatsFromConfig()
  var
    lastTick = 0'u32
    hasLastTick = false
    lastInputTime = 0'u32
    lastJoinTime = 0'u32
    lastLeaveTime = 0'u32
    lastChatTime = 0'u32
    lastDebugSpriteTime = 0'u32
    hasRecordTime = false
    lastRecordTime = 0'u32
    lastRecordPhase = 0'u8
    hasLobbyOrdinal = false
    lastLobbyOrdinal = 0'u64
    hasAnnotationTick: array[256, bool]
    lastAnnotationTick: array[256, uint32]
    callBytes: seq[tuple[seat: uint8, bytes: string]]
    annotationBytes: seq[tuple[seat: uint8, bytes: string]]
    transcriptBytes: seq[string]
    sawShellRecord = false
    sawManifest = false
    lifecycle = initLifecyclePlayback(configuredPlaySeats)
  while offset < replayBytes.len:
    let
      recordStart = offset
      recordType = replayBytes.readU8(offset)
    try:
      case recordType
      of ReplayTickHashRecord:
        let
          tick = replayBytes.readU32(offset)
          hash = replayBytes.readU64(offset)
        # u32 stays unsigned: high-bit ticks are legal on wasm32.
        if hasLastTick and tick <= lastTick:
          case spec.hashOrder
          of rhoStop:
            break
          of rhoError:
            raise newException(ReplayError,
              "Replay tick hashes move backward")
        lastTick = tick
        hasLastTick = true
        result.replay.hashes.add(ReplayHash(tick: tick, hash: hash))
      of ReplayInputRecord:
        let input = ReplayInput(
          time: replayBytes.readU32(offset),
          player: replayBytes.readU8(offset),
          keys: replayBytes.readU8(offset))
        if input.time < lastInputTime:
          raise newException(ReplayError,
            "Replay input timestamps move backward")
        lastInputTime = input.time
        noteRecordOrder(input.time, 2, "input", hasRecordTime,
          lastRecordTime, lastRecordPhase)
        result.replay.inputs.add(input)
      of ReplayJoinRecord:
        let join = replayBytes.readJoin(offset, spec)
        if join.time < lastJoinTime:
          raise newException(ReplayError,
            "Replay join timestamps move backward")
        lastJoinTime = join.time
        noteRecordOrder(join.time, 0, "join", hasRecordTime,
          lastRecordTime, lastRecordPhase)
        result.replay.joins.add(join)
      of ReplayLeaveRecord:
        let leave = ReplayLeave(
          time: replayBytes.readU32(offset),
          player: replayBytes.readU8(offset))
        if leave.time < lastLeaveTime:
          raise newException(ReplayError,
            "Replay leave timestamps move backward")
        lastLeaveTime = leave.time
        noteRecordOrder(leave.time, 0, "leave", hasRecordTime,
          lastRecordTime, lastRecordPhase)
        result.replay.leaves.add(leave)
      of ReplayChatRecord:
        if not spec.allowChat:
          raise newException(ReplayError,
            "Replay chat record is not supported")
        let chat = ReplayChat(
          time: replayBytes.readU32(offset),
          player: replayBytes.readU8(offset),
          message: replayBytes.readReplayString(offset))
        if chat.time < lastChatTime:
          raise newException(ReplayError,
            "Replay chat timestamps move backward")
        lastChatTime = chat.time
        noteRecordOrder(chat.time, 2, "chat", hasRecordTime,
          lastRecordTime, lastRecordPhase)
        result.replay.chats.add(chat)
      of ReplayDebugSpriteRecord:
        let debugSprite = ReplayDebugSprite(
          time: replayBytes.readU32(offset),
          player: replayBytes.readU8(offset),
          packet: replayBytes.readReplayBytes(offset))
        if debugSprite.time < lastDebugSpriteTime:
          raise newException(ReplayError,
            "Replay debug sprite timestamps move backward")
        lastDebugSpriteTime = debugSprite.time
        noteRecordOrder(debugSprite.time, 2, "debug sprite", hasRecordTime,
          lastRecordTime, lastRecordPhase)
        result.replay.debugSprites.add(debugSprite)
      of RecPlayCall:
        sawShellRecord = true
        offset = recordStart
        let call = replayBytes.decodePlayCallRecord(offset)
        for entry in call.entries:
          if entry.code.kind == cikNative and
              entry.code.nativeGameVersion != result.replay.gameVersion:
            raise newException(ReplayError,
              "native play-call identity GameVersion does not match replay")
        noteRecordOrder(call.replayTimeMs, 4, "play call", hasRecordTime,
          lastRecordTime, lastRecordPhase)
        result.shell.calls.add(call)
        callBytes.add((call.seat, replayBytes[recordStart ..< offset]))
      of RecBehaviorAnnotation:
        sawShellRecord = true
        offset = recordStart
        let annotation = replayBytes.decodeAnnotationRecord(offset)
        let seat = int(annotation.seat)
        if hasAnnotationTick[seat] and
            annotation.tick < lastAnnotationTick[seat]:
          raise newException(ReplayError,
            "Replay annotation ticks move backward for seat " & $seat)
        hasAnnotationTick[seat] = true
        lastAnnotationTick[seat] = annotation.tick
        result.shell.annotations.add(annotation)
        annotationBytes.add((annotation.seat,
          replayBytes[recordStart ..< offset]))
      of RecLobbyChat:
        sawShellRecord = true
        offset = recordStart
        let lobby = replayBytes.decodeLobbyChatRecord(offset)
        if hasLobbyOrdinal and lobby.ordinal <= lastLobbyOrdinal:
          raise newException(ReplayError,
            "Replay lobby transcript ordinals are not increasing")
        hasLobbyOrdinal = true
        lastLobbyOrdinal = lobby.ordinal
        noteRecordOrder(lobby.replayTimeMs, 3, "lobby transcript",
          hasRecordTime, lastRecordTime, lastRecordPhase)
        result.shell.lobbyTranscript.add(lobby)
        transcriptBytes.add(replayBytes[recordStart ..< offset])
      of RecDisconnect, RecKick, RecRebind:
        sawShellRecord = true
        if replayBytes.len - recordStart < 6:
          raise newException(ReplayError,
            "Replay file is truncated at byte " & $recordStart)
        let lifecycleBytes = replayBytes[recordStart ..< recordStart + 6]
        offset = recordStart + 6
        let record = decodeLifecycleRecord(lifecycleBytes)
        noteRecordOrder(record.replayTimeMs, 1, "lifecycle",
          hasRecordTime, lastRecordTime, lastRecordPhase)
        lifecycle.applyLifecycleRecord(record)
        result.shell.lifecycle.add(record)
      of RecManifest:
        sawShellRecord = true
        if sawManifest:
          raise newException(ReplayError, "duplicate shell replay manifest")
        offset = recordStart
        result.shell.manifest = replayBytes.decodeManifestRecord(offset)
        if configuredPlaySeats.len > 0 and
            result.shell.manifest.seats.len != configuredPlaySeats.len:
          raise newException(ReplayError,
            "shell manifest seat count does not match replay config")
        sawManifest = true
        if offset != replayBytes.len:
          raise newException(ReplayError,
            "shell replay manifest must be the final record")
        verifyManifest(result.shell.manifest, callBytes, annotationBytes,
          transcriptBytes)
        result.shell.manifestVerified = true
      else:
        raise newException(ReplayError, "Unknown replay record type")
    except ReplayRecordError as error:
      raise newException(ReplayError, error.msg)
    except LifecycleRecordError as error:
      raise newException(ReplayError, "invalid lifecycle record: " & error.msg)
  if sawShellRecord and not sawManifest:
    raise newException(ReplayError, "shell replay manifest is missing")

proc parseCtfReplayBytes*(
  bytes: string,
  spec: ReplaySpec,
  compatibleGameVersions: openArray[string]
): CtfReplayData =
  ## Parses one CTF replay and retains verified format-2 shell metadata.
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
    result.replay = replayCodec.parseReplayBytes(replayBytes, compatibleSpec)
    return

  result.replay = header.data
  replayBytes.parseFormat2Records(offset, spec, result)

proc parseReplayBytes*(
  bytes: string,
  spec: ReplaySpec,
  compatibleGameVersions: openArray[string]
): ReplayData =
  ## Compatibility surface for existing playback, which consumes only the
  ## legacy mask/sim streams after shell metadata has verified eagerly.
  parseCtfReplayBytes(bytes, spec, compatibleGameVersions).replay

proc loadReplay*(
  path: string,
  spec: ReplaySpec,
  compatibleGameVersions: openArray[string]
): ReplayData =
  ## Loads one format-1 or format-2 CTF replay from disk.
  parseReplayBytes(readFile(path), spec, compatibleGameVersions)

proc loadCtfReplay*(
  path: string,
  spec: ReplaySpec,
  compatibleGameVersions: openArray[string]
): CtfReplayData =
  parseCtfReplayBytes(readFile(path), spec, compatibleGameVersions)
