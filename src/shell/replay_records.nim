## Record-level codecs for the format-2 shell replay records.

import
  std/unicode,
  crunchy,
  ./[seats, types]

type
  LifecycleRecordKind* = enum
    lrDisconnect
    lrKick
    lrRebind

  LifecycleRecord* = object
    kind*: LifecycleRecordKind
    replayTimeMs*: uint32
    seat*: uint8

  LifecycleRecordErrorKind* = enum
    lreWrongSize
    lreWrongType
    lreSeatOutOfRange
    lreBackwardTime
    lreInvalidTransition
    lrePlaySeatDisconnect
    lrePlaySeatRebind

  LifecycleRecordError* = object of CatchableError
    kind*: LifecycleRecordErrorKind

  LifecyclePlayback* = object
    seats: seq[SeatPresence]
    playSeats: seq[bool]
    lastReplayTimeMs*: uint32
    hasReplayTime: bool

  CodeIdentityKind* = enum
    cikModule
    cikNative

  CodeIdentity* = object
    case kind*: CodeIdentityKind
    of cikModule:
      moduleSha256*: string
    of cikNative:
      nativeName*: string
      nativeGameVersion*: string

  PlayCallEntryIdentity* = object
    entryId*: string
    code*: CodeIdentity

  PlayCallRecord* = object
    replayTimeMs*: uint32
    seat*: uint8
    epoch*: uint64
    ladderBytes*: string
    entries*: seq[PlayCallEntryIdentity]
    contentSha256*: string

  LobbyChatRecord* = object
    replayTimeMs*: uint32
    ordinal*: uint64
    seat*: uint8
    team*: uint8
    text*: string

  BallotRecordKind* = enum
    ## docs/designs/prematch-vote-wire-2026-08-31.md §4's record `0x17`
    ## (RecVoteReserved, src/shell/types.nim): the same two kinds as the
    ## wire's `0xB3` VoteState.
    brkCast
    brkResolved

  BallotRecord* = object
    ## §4: one byte shorter than the wire packet per kind (`type` +
    ## `replayTimeMs` replaces `op` + `ver`, no `tick` field) — the same
    ## trim `0x13` already makes relative to `0xB2`. Hash-coupled like
    ## `0x14`-`0x16` (ruled, 2c2f905c): NO manifest arm, so unlike
    ## `LobbyChatRecord` above this type carries no ordered-chain
    ## integrity field and `buildShellReplayManifest` below is unchanged.
    replayTimeMs*: uint32
    ordinal*: uint64
    case kind*: BallotRecordKind
    of brkCast:
      seat*: uint8
      team*: uint8
      option*: uint8
    of brkResolved:
      category*: uint8
      tieBreakDrawn*: uint8
      finalOption*: uint8

  ShellManifestSeat* = object
    seat*: uint8
    callCount*: uint32
    callChainSha256*: string
    annotationCount*: uint32
    annotationChainSha256*: string

  ShellReplayManifest* = object
    seats*: seq[ShellManifestSeat]
    transcriptCount*: uint32
    transcriptChainSha256*: string

  ShellReplayRecords* = object
    calls*: seq[PlayCallRecord]
    annotations*: seq[ShellAnnotation]
    lobbyTranscript*: seq[LobbyChatRecord]
    lifecycle*: seq[LifecycleRecord]
    manifest*: ShellReplayManifest
    manifestVerified*: bool
    ballots*: seq[BallotRecord]
      ## §4's `0x17` (RecVoteReserved) records, in ordinal order. Hash-coupled
      ## like `0x14`-`0x16` (settled 2c2f905c): no manifest arm, so unlike
      ## `lobbyTranscript` above there is nothing here to verify against --
      ## the gameplay hash chain is the integrity check. Populated by the
      ## replay codec's format-2 record loop, same as every other field on
      ## this object; empty on a replay that never armed the vote phase.

  ReplayRecordError* = object of CatchableError

const
  EmptyOrderedChainHash* =
    "0000000000000000000000000000000000000000000000000000000000000000"
  NativeReflexNames* = [
    "reflex_clear_grenade",
    "reflex_clear_spray",
    "reflex_zone_escape",
  ]

proc `==`*(a, b: CodeIdentity): bool =
  if a.kind != b.kind:
    return false
  case a.kind
  of cikModule:
    a.moduleSha256 == b.moduleSha256
  of cikNative:
    a.nativeName == b.nativeName and
      a.nativeGameVersion == b.nativeGameVersion

proc `==`*(a, b: ProvenanceBase): bool =
  if a.kind != b.kind:
    return false
  case a.kind
  of pbEntry:
    a.entryId == b.entryId and
      a.moduleSha256 == b.moduleSha256 and
      a.emitTick == b.emitTick
  of pbDefault:
    true
  of pbReflex:
    a.reflexName == b.reflexName

proc `==`*(a, b: Provenance): bool =
  a.base == b.base and a.overlays == b.overlays

proc `==`*(a, b: ShellAnnotation): bool =
  if a.tick != b.tick or a.seat != b.seat or a.kind != b.kind:
    return false
  case a.kind
  of akAcceptedIntentChange:
    a.effectiveEpoch == b.effectiveEpoch and
      a.provenance == b.provenance and a.intentBytes == b.intentBytes
  of akClearOnDeath:
    a.clearGeneration == b.clearGeneration
  of akInstallSafeIntent:
    a.installGeneration == b.installGeneration and
      a.installReason == b.installReason and a.safeBytes == b.safeBytes
  of akPlayFault:
    a.faultAtEpoch == b.faultAtEpoch and
      a.faultEntryId == b.faultEntryId and
      a.faultCode == b.faultCode and
      a.annotationFaultReason == b.annotationFaultReason

proc `==`*(a, b: BallotRecord): bool =
  ## Nim's generic structural `==` (unittest's `check`) cannot walk a `case`
  ## object's fields in parallel -- same reason `ShellAnnotation`/
  ## `CodeIdentity`/`ProvenanceBase` above all carry an explicit override.
  if a.replayTimeMs != b.replayTimeMs or a.ordinal != b.ordinal or
      a.kind != b.kind:
    return false
  case a.kind
  of brkCast:
    a.seat == b.seat and a.team == b.team and a.option == b.option
  of brkResolved:
    a.category == b.category and a.tieBreakDrawn == b.tieBreakDrawn and
      a.finalOption == b.finalOption

proc recordError(message: string) {.noReturn.} =
  raise newException(ReplayRecordError, message)

proc addU8(bytes: var string, value: uint8) =
  bytes.add(char(value))

proc addU16(bytes: var string, value: uint16) =
  bytes.addU8(uint8(value and 0xff'u16))
  bytes.addU8(uint8(value shr 8))

proc addU32(bytes: var string, value: uint32) =
  for shift in countup(0, 24, 8):
    bytes.addU8(uint8((value shr shift) and 0xff'u32))

proc addU64(bytes: var string, value: uint64) =
  for shift in countup(0, 56, 8):
    bytes.addU8(uint8((value shr shift) and 0xff'u64))

proc addString16(bytes: var string, value: string) =
  if value.len > high(uint16).int:
    recordError("shell replay string is too long")
  bytes.addU16(uint16(value.len))
  bytes.add(value)

proc readU8(bytes: string, offset: var int): uint8 =
  if offset >= bytes.len:
    recordError("shell replay record is truncated")
  result = bytes[offset].uint8
  inc offset

proc readU16(bytes: string, offset: var int): uint16 =
  if bytes.len - offset < 2:
    recordError("shell replay record is truncated")
  result = uint16(bytes[offset].uint8) or
    (uint16(bytes[offset + 1].uint8) shl 8)
  offset += 2

proc readU32(bytes: string, offset: var int): uint32 =
  if bytes.len - offset < 4:
    recordError("shell replay record is truncated")
  for shift in countup(0, 24, 8):
    result = result or (uint32(bytes[offset].uint8) shl shift)
    inc offset

proc readU64(bytes: string, offset: var int): uint64 =
  if bytes.len - offset < 8:
    recordError("shell replay record is truncated")
  for shift in countup(0, 56, 8):
    result = result or (uint64(bytes[offset].uint8) shl shift)
    inc offset

proc readString16(bytes: string, offset: var int): string =
  let length = bytes.readU16(offset)
  # The untrusted u16 stays unsigned until it has been bounded by the bytes
  # remaining. This is required for wasm32 even though u16 itself fits int32.
  if uint64(length) > uint64(bytes.len - offset):
    recordError("shell replay record is truncated")
  let checkedLength = int(length)
  result = bytes[offset ..< offset + checkedLength]
  offset += checkedLength

proc isSha256Hex(value: string): bool =
  if value.len != 64:
    return false
  for ch in value:
    if ch notin {'0' .. '9', 'a' .. 'f'}:
      return false
  true

proc hexNibble(ch: char): uint8 =
  case ch
  of '0' .. '9': uint8(ord(ch) - ord('0'))
  of 'a' .. 'f': uint8(ord(ch) - ord('a') + 10)
  else: recordError("SHA-256 identity is not lowercase hexadecimal")

proc hashRaw(value: string): string =
  if not value.isSha256Hex():
    recordError("SHA-256 identity must be 64 lowercase hexadecimal bytes")
  result = newString(32)
  for index in 0 ..< 32:
    result[index] = char(
      (value[index * 2].hexNibble shl 4) or
      value[index * 2 + 1].hexNibble)

proc rawHash(bytes: string, offset: var int): string =
  if bytes.len - offset < 32:
    recordError("shell replay record is truncated")
  var digest: array[32, uint8]
  for index in 0 ..< 32:
    digest[index] = bytes[offset + index].uint8
  offset += 32
  digest.toHex()

proc sha256Hex*(bytes: string): string =
  sha256(bytes).toHex()

proc orderedChainHash*(records: openArray[string]): string =
  ## The ordered chain starts at 32 zero bytes. Each arm is
  ## SHA256(previous raw digest || complete encoded record). It therefore
  ## commits to record bytes, count, and order without a delimiter ambiguity.
  var state = newString(32)
  for record in records:
    let digest = sha256(state & record)
    for index in 0 ..< 32:
      state[index] = char(digest[index])
  if records.len == 0:
    return EmptyOrderedChainHash
  var digest: array[32, uint8]
  for index in 0 ..< 32:
    digest[index] = state[index].uint8
  digest.toHex()

proc lifecycleError(kind: LifecycleRecordErrorKind) {.noReturn.} =
  var error = newException(LifecycleRecordError, $kind)
  error.kind = kind
  raise error

proc opcode(kind: LifecycleRecordKind): uint8 =
  case kind
  of lrDisconnect: RecDisconnect
  of lrKick: RecKick
  of lrRebind: RecRebind

proc encodeLifecycleRecord*(record: LifecycleRecord): string =
  result = newString(6)
  result[0] = char(record.kind.opcode())
  for byteIndex, shift in [0, 8, 16, 24]:
    result[byteIndex + 1] = char(uint8(
      (record.replayTimeMs shr shift) and 0xff'u32))
  result[5] = char(record.seat)

proc decodeLifecycleRecord*(bytes: string): LifecycleRecord =
  if bytes.len != 6:
    lifecycleError(lreWrongSize)
  case bytes[0].uint8
  of RecDisconnect: result.kind = lrDisconnect
  of RecKick: result.kind = lrKick
  of RecRebind: result.kind = lrRebind
  else: lifecycleError(lreWrongType)
  for byteIndex, shift in [0, 8, 16, 24]:
    result.replayTimeMs = result.replayTimeMs or
      (uint32(bytes[byteIndex + 1].uint8) shl shift)
  result.seat = bytes[5].uint8

proc initLifecyclePlayback*(playSeats: openArray[bool]): LifecyclePlayback =
  result.playSeats = @playSeats
  result.seats = newSeq[SeatPresence](playSeats.len)
  for presence in result.seats.mitems:
    presence = spConnected

proc presence*(playback: LifecyclePlayback, seat: int): SeatPresence =
  if seat < 0 or seat >= playback.seats.len:
    lifecycleError(lreSeatOutOfRange)
  playback.seats[seat]

proc applyLifecycleRecord*(
  playback: var LifecyclePlayback,
  record: LifecycleRecord,
) =
  # replayTimeMs stays uint32 through validation and comparison; wasm32 is a
  # first-class target, so no untrusted u32 narrows to int.
  if playback.hasReplayTime and record.replayTimeMs < playback.lastReplayTimeMs:
    lifecycleError(lreBackwardTime)
  let seat = int(record.seat) # uint8 is representable on every Nim target.
  if seat >= playback.seats.len:
    lifecycleError(lreSeatOutOfRange)
  case record.kind
  of lrDisconnect:
    if playback.playSeats[seat]:
      lifecycleError(lrePlaySeatDisconnect)
    if playback.seats[seat] != spConnected:
      lifecycleError(lreInvalidTransition)
    playback.seats[seat] = spReconnectable
  of lrKick:
    if playback.seats[seat] == spTerminal:
      lifecycleError(lreInvalidTransition)
    playback.seats[seat] = spTerminal
  of lrRebind:
    if playback.playSeats[seat]:
      lifecycleError(lrePlaySeatRebind)
    if playback.seats[seat] != spReconnectable:
      lifecycleError(lreInvalidTransition)
    playback.seats[seat] = spConnected
  playback.lastReplayTimeMs = record.replayTimeMs
  playback.hasReplayTime = true

proc addCodeIdentity(bytes: var string, code: CodeIdentity) =
  case code.kind
  of cikModule:
    bytes.addU8(0)
    bytes.add(code.moduleSha256.hashRaw())
  of cikNative:
    if code.nativeName notin NativeReflexNames:
      recordError("unknown native reflex identity")
    bytes.addU8(1)
    bytes.addString16(code.nativeName)
    bytes.addString16(code.nativeGameVersion)

proc readCodeIdentity(bytes: string, offset: var int): CodeIdentity =
  case bytes.readU8(offset)
  of 0:
    result = CodeIdentity(kind: cikModule,
      moduleSha256: bytes.rawHash(offset))
  of 1:
    result = CodeIdentity(
      kind: cikNative,
      nativeName: bytes.readString16(offset),
      nativeGameVersion: bytes.readString16(offset))
    if result.nativeName notin NativeReflexNames:
      recordError("unknown native reflex identity")
  else:
    recordError("unknown play-call code identity")

proc encodePlayCallRecord*(record: PlayCallRecord): string =
  if record.ladderBytes.len > MaxCallBytes:
    recordError("play-call ladder exceeds MaxCallBytes")
  if record.entries.len > MaxLadderEntries:
    recordError("play-call has too many entries")
  result.addU8(RecPlayCall)
  result.addU32(record.replayTimeMs)
  result.addU8(record.seat)
  result.addU64(record.epoch)
  result.addString16(record.ladderBytes)
  result.addU8(uint8(record.entries.len))
  for entry in record.entries:
    result.addString16(entry.entryId)
    result.addCodeIdentity(entry.code)

proc decodePlayCallRecord*(bytes: string, offset: var int): PlayCallRecord =
  ## Reads one record from a larger stream; trailing bytes belong to the next
  ## record and are intentionally left unread.
  let start = offset
  if bytes.readU8(offset) != RecPlayCall:
    recordError("wrong play-call record type")
  result.replayTimeMs = bytes.readU32(offset)
  result.seat = bytes.readU8(offset)
  result.epoch = bytes.readU64(offset)
  result.ladderBytes = bytes.readString16(offset)
  if result.ladderBytes.len > MaxCallBytes:
    recordError("play-call ladder exceeds MaxCallBytes")
  let entryCount = bytes.readU8(offset)
  if entryCount > MaxLadderEntries.uint8:
    recordError("play-call has too many entries")
  for _ in 0 ..< int(entryCount):
    result.entries.add(PlayCallEntryIdentity(
      entryId: bytes.readString16(offset),
      code: bytes.readCodeIdentity(offset)))
  result.contentSha256 = sha256Hex(bytes[start ..< offset])

proc decodePlayCallRecord*(bytes: string): PlayCallRecord =
  ## Decodes one complete standalone record.
  var offset = 0
  result = bytes.decodePlayCallRecord(offset)
  if offset != bytes.len:
    recordError("trailing bytes after play-call record")

proc addProvenance(bytes: var string, provenance: Provenance) =
  bytes.addU8(uint8(provenance.base.kind.ord))
  case provenance.base.kind
  of pbEntry:
    bytes.addString16(provenance.base.entryId)
    bytes.add(provenance.base.moduleSha256.hashRaw())
    bytes.addU32(provenance.base.emitTick)
  of pbDefault:
    discard
  of pbReflex:
    if provenance.base.reflexName notin NativeReflexNames:
      recordError("unknown annotation reflex provenance")
    bytes.addString16(provenance.base.reflexName)
  if provenance.overlays.len > MaxActiveOverlays:
    recordError("annotation has too many overlay contributors")
  bytes.addU8(uint8(provenance.overlays.len))
  for overlay in provenance.overlays:
    bytes.addString16(overlay.entryId)
    bytes.add(overlay.moduleSha256.hashRaw())
    bytes.addU32(overlay.acceptedTick)
    bytes.add(overlay.policySha256.hashRaw())

proc readProvenance(bytes: string, offset: var int): Provenance =
  case bytes.readU8(offset)
  of uint8(pbEntry.ord):
    result.base = ProvenanceBase(
      kind: pbEntry,
      entryId: bytes.readString16(offset),
      moduleSha256: bytes.rawHash(offset),
      emitTick: bytes.readU32(offset))
  of uint8(pbDefault.ord):
    result.base = ProvenanceBase(kind: pbDefault)
  of uint8(pbReflex.ord):
    result.base = ProvenanceBase(
      kind: pbReflex,
      reflexName: bytes.readString16(offset))
    if result.base.reflexName notin NativeReflexNames:
      recordError("unknown annotation reflex provenance")
  else:
    recordError("unknown annotation provenance base")
  let overlayCount = bytes.readU8(offset)
  if overlayCount > MaxActiveOverlays.uint8:
    recordError("annotation has too many overlay contributors")
  for _ in 0 ..< int(overlayCount):
    result.overlays.add(OverlayContribution(
      entryId: bytes.readString16(offset),
      moduleSha256: bytes.rawHash(offset),
      acceptedTick: bytes.readU32(offset),
      policySha256: bytes.rawHash(offset)))

const
  ## Annotation wire kinds. These are NOT AnnotationKind ordinals: records
  ## carry no length prefix, so a layout change needs a new byte, and the
  ## bytes below are the contract. Allocate future kinds from 5.
  WireAcceptedIntentChange = 0'u8
  WireClearOnDeath = 1'u8
  WireInstallSafeIntent = 2'u8
  WirePlayFaultLegacy = 3'u8
    ## The pre-code play-fault layout (epoch, entryId, reason), written by
    ## paintbot 0.7.311 and 0.7.312. Still decoded (code = fcUnknown); never
    ## written again.
  WirePlayFaultCoded = 4'u8
    ## epoch, code byte, entryId, reason.

proc wireKind(kind: AnnotationKind): uint8 =
  case kind
  of akAcceptedIntentChange: WireAcceptedIntentChange
  of akClearOnDeath: WireClearOnDeath
  of akInstallSafeIntent: WireInstallSafeIntent
  of akPlayFault: WirePlayFaultCoded

proc encodeAnnotationRecord*(annotation: ShellAnnotation): string =
  result.addU8(RecBehaviorAnnotation)
  result.addU32(annotation.tick)
  result.addU8(annotation.seat)
  result.addU8(annotation.kind.wireKind)
  case annotation.kind
  of akAcceptedIntentChange:
    result.addU64(annotation.effectiveEpoch)
    result.addProvenance(annotation.provenance)
    result.addString16(annotation.intentBytes)
  of akClearOnDeath:
    result.addU64(annotation.clearGeneration)
  of akInstallSafeIntent:
    if annotation.installReason notin ["activation", "respawn", "kicked"]:
      recordError("unknown safe-intent install reason")
    result.addU64(annotation.installGeneration)
    result.addString16(annotation.installReason)
    result.addString16(annotation.safeBytes)
  of akPlayFault:
    result.addU64(annotation.faultAtEpoch)
    result.addU8(uint8(annotation.faultCode.ord))
    result.addString16(annotation.faultEntryId)
    result.addString16(annotation.annotationFaultReason)

proc decodeAnnotationRecord*(bytes: string,
                             offset: var int): ShellAnnotation =
  ## Reads one record from a larger stream; trailing bytes belong to the next
  ## record and are intentionally left unread.
  if bytes.readU8(offset) != RecBehaviorAnnotation:
    recordError("wrong annotation record type")
  result.tick = bytes.readU32(offset)
  result.seat = bytes.readU8(offset)
  let kind = bytes.readU8(offset)
  case kind
  of WireAcceptedIntentChange:
    result = ShellAnnotation(
      tick: result.tick,
      seat: result.seat,
      kind: akAcceptedIntentChange,
      effectiveEpoch: bytes.readU64(offset),
      provenance: bytes.readProvenance(offset),
      intentBytes: bytes.readString16(offset))
  of WireClearOnDeath:
    result = ShellAnnotation(
      tick: result.tick,
      seat: result.seat,
      kind: akClearOnDeath,
      clearGeneration: bytes.readU64(offset))
  of WireInstallSafeIntent:
    let
      generation = bytes.readU64(offset)
      reason = bytes.readString16(offset)
      safeBytes = bytes.readString16(offset)
    if reason notin ["activation", "respawn", "kicked"]:
      recordError("unknown safe-intent install reason")
    result = ShellAnnotation(
      tick: result.tick,
      seat: result.seat,
      kind: akInstallSafeIntent,
      installGeneration: generation,
      installReason: reason,
      safeBytes: safeBytes)
  of WirePlayFaultLegacy:
    result = ShellAnnotation(
      tick: result.tick,
      seat: result.seat,
      kind: akPlayFault,
      faultAtEpoch: bytes.readU64(offset),
      faultEntryId: bytes.readString16(offset),
      faultCode: fcUnknown,
      annotationFaultReason: bytes.readString16(offset))
  of WirePlayFaultCoded:
    let epoch = bytes.readU64(offset)
    let codeByte = bytes.readU8(offset)
    if codeByte > uint8(high(FaultCode).ord):
      recordError("unknown annotation fault code")
    result = ShellAnnotation(
      tick: result.tick,
      seat: result.seat,
      kind: akPlayFault,
      faultAtEpoch: epoch,
      faultEntryId: bytes.readString16(offset),
      faultCode: FaultCode(codeByte),
      annotationFaultReason: bytes.readString16(offset))
  else:
    recordError("unknown annotation kind")

proc decodeAnnotationRecord*(bytes: string): ShellAnnotation =
  ## Decodes one complete standalone record.
  var offset = 0
  result = bytes.decodeAnnotationRecord(offset)
  if offset != bytes.len:
    recordError("trailing bytes after annotation record")

proc encodeLobbyChatRecord*(record: LobbyChatRecord): string =
  if record.text.len > LobbyChatMaxBytes:
    recordError("lobby transcript message exceeds LobbyChatMaxBytes")
  if validateUtf8(record.text) != -1:
    recordError("lobby transcript message is not valid UTF-8")
  result.addU8(RecLobbyChat)
  result.addU32(record.replayTimeMs)
  result.addU64(record.ordinal)
  result.addU8(record.seat)
  result.addU8(record.team)
  result.addU16(uint16(record.text.len))
  result.add(record.text)

proc decodeLobbyChatRecord*(bytes: string,
                            offset: var int): LobbyChatRecord =
  ## Reads one record from a larger stream; trailing bytes belong to the next
  ## record and are intentionally left unread.
  if bytes.readU8(offset) != RecLobbyChat:
    recordError("wrong lobby transcript record type")
  result.replayTimeMs = bytes.readU32(offset)
  result.ordinal = bytes.readU64(offset)
  result.seat = bytes.readU8(offset)
  result.team = bytes.readU8(offset)
  let length = bytes.readU16(offset)
  # Bind the u16 in its unsigned domain before converting on wasm32.
  if length > LobbyChatMaxBytes.uint16:
    recordError("lobby transcript message exceeds LobbyChatMaxBytes")
  if uint64(length) > uint64(bytes.len - offset):
    recordError("shell replay record is truncated")
  let checkedLength = int(length)
  result.text = bytes[offset ..< offset + checkedLength]
  offset += checkedLength
  if validateUtf8(result.text) != -1:
    recordError("lobby transcript message is not valid UTF-8")

proc decodeLobbyChatRecord*(bytes: string): LobbyChatRecord =
  ## Decodes one complete standalone record.
  var offset = 0
  result = bytes.decodeLobbyChatRecord(offset)
  if offset != bytes.len:
    recordError("trailing bytes after lobby transcript record")

proc encodeBallotRecord*(record: BallotRecord): string =
  ## docs/designs/prematch-vote-wire-2026-08-31.md §4, record `0x17`
  ## (RecVoteReserved): both kinds are 17 bytes, fixed.
  result.addU8(RecVoteReserved)
  result.addU32(record.replayTimeMs)
  case record.kind
  of brkCast:
    result.addU8(0)
    result.addU64(record.ordinal)
    result.addU8(record.seat)
    result.addU8(record.team)
    result.addU8(record.option)
  of brkResolved:
    result.addU8(1)
    result.addU64(record.ordinal)
    result.addU8(record.category)
    result.addU8(record.tieBreakDrawn)
    result.addU8(record.finalOption)

proc decodeBallotRecord*(bytes: string, offset: var int): BallotRecord =
  ## Reads one record from a larger stream; trailing bytes belong to the
  ## next record and are intentionally left unread.
  if bytes.readU8(offset) != RecVoteReserved:
    recordError("wrong ballot record type")
  let replayTimeMs = bytes.readU32(offset)
  let kind = bytes.readU8(offset)
  let ordinal = bytes.readU64(offset)
  case kind
  of 0'u8:
    let seat = bytes.readU8(offset)
    let team = bytes.readU8(offset)
    let option = bytes.readU8(offset)
    result = BallotRecord(kind: brkCast, replayTimeMs: replayTimeMs,
      ordinal: ordinal, seat: seat, team: team, option: option)
  of 1'u8:
    let category = bytes.readU8(offset)
    let tieBreakDrawn = bytes.readU8(offset)
    let finalOption = bytes.readU8(offset)
    result = BallotRecord(kind: brkResolved, replayTimeMs: replayTimeMs,
      ordinal: ordinal, category: category, tieBreakDrawn: tieBreakDrawn,
      finalOption: finalOption)
  else:
    recordError("unknown ballot record kind")

proc decodeBallotRecord*(bytes: string): BallotRecord =
  ## Decodes one complete standalone record.
  var offset = 0
  result = bytes.decodeBallotRecord(offset)
  if offset != bytes.len:
    recordError("trailing bytes after ballot record")

proc buildShellReplayManifest*(
  callRecords: openArray[seq[string]],
  annotationRecords: openArray[seq[string]],
  transcriptRecords: openArray[string],
): ShellReplayManifest =
  if callRecords.len != annotationRecords.len or callRecords.len > 256:
    recordError("manifest seat arms do not match")
  for seat in 0 ..< callRecords.len:
    if uint64(callRecords[seat].len) > uint64(high(uint32)) or
        uint64(annotationRecords[seat].len) > uint64(high(uint32)):
      recordError("manifest record count exceeds u32")
    result.seats.add(ShellManifestSeat(
      seat: uint8(seat),
      callCount: uint32(callRecords[seat].len),
      callChainSha256: orderedChainHash(callRecords[seat]),
      annotationCount: uint32(annotationRecords[seat].len),
      annotationChainSha256: orderedChainHash(annotationRecords[seat])))
  if uint64(transcriptRecords.len) > uint64(high(uint32)):
    recordError("manifest transcript count exceeds u32")
  result.transcriptCount = uint32(transcriptRecords.len)
  result.transcriptChainSha256 = orderedChainHash(transcriptRecords)

proc encodeManifestRecord*(manifest: ShellReplayManifest): string =
  if manifest.seats.len > 256:
    recordError("manifest has too many seat arms")
  result.addU8(RecManifest)
  result.addU16(uint16(manifest.seats.len))
  for index, seat in manifest.seats:
    if int(seat.seat) != index:
      recordError("manifest seat arms must be contiguous and ordered")
    result.addU8(seat.seat)
    result.addU32(seat.callCount)
    result.add(seat.callChainSha256.hashRaw())
    result.addU32(seat.annotationCount)
    result.add(seat.annotationChainSha256.hashRaw())
  result.addU32(manifest.transcriptCount)
  result.add(manifest.transcriptChainSha256.hashRaw())

proc decodeManifestRecord*(bytes: string,
                           offset: var int): ShellReplayManifest =
  ## Reads one record from a larger stream; trailing bytes belong to the next
  ## record and are intentionally left unread.
  if bytes.readU8(offset) != RecManifest:
    recordError("wrong shell manifest record type")
  let seatCount = bytes.readU16(offset)
  # Check u16 before conversion even though the protocol caps it at 256.
  if seatCount > 256'u16:
    recordError("manifest has too many seat arms")
  for index in 0 ..< int(seatCount):
    let seat = bytes.readU8(offset)
    if int(seat) != index:
      recordError("manifest seat arms must be contiguous and ordered")
    result.seats.add(ShellManifestSeat(
      seat: seat,
      callCount: bytes.readU32(offset),
      callChainSha256: bytes.rawHash(offset),
      annotationCount: bytes.readU32(offset),
      annotationChainSha256: bytes.rawHash(offset)))
  result.transcriptCount = bytes.readU32(offset)
  result.transcriptChainSha256 = bytes.rawHash(offset)

proc decodeManifestRecord*(bytes: string): ShellReplayManifest =
  ## Decodes one complete standalone record.
  var offset = 0
  result = bytes.decodeManifestRecord(offset)
  if offset != bytes.len:
    recordError("trailing bytes after shell manifest record")

proc moduleHashes*(records: ShellReplayRecords): seq[string] =
  for call in records.calls:
    for entry in call.entries:
      if entry.code.kind == cikModule and
          entry.code.moduleSha256 notin result:
        result.add(entry.code.moduleSha256)
