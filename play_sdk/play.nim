## Minimal Nim play SDK for the Season 2 core-WASM ABI.
##
## This library is author convenience only. The server's real security
## boundary remains `src/shell`: binary validation, manifest parsing, ABI
## checks, host queries, and emit validation.

const
  ArenaBytes = 32 * 1024
  EmitBufferBytes = 1024
  MaxViewTracks* = 32
  MaxViewItems* = 32
  MaxViewAggressors* = 16
  MaxViewKillFeed* = 32
  MaxPactRefs* = 8
  MaxPolicySeats* = 32
  NoGoal* = -1'i64
  QuotaExceeded* = -2'i64
  InvalidSpatialArgument* = -3'i64

type
  PlayContext* = object
    data*: int32
    len*: int32

  PlayView* = object
    data*: int32
    len*: int32

  ValidatedGoal* = object
    ok*: bool
    x*, y*: int32

  CoverThreat* = object
    x*, y*: int32

  SdkTeam* = enum
    stUnknown
    stRed
    stBlue
    stGreen
    stYellow
    stBlack
    stSilver
    stIvory
    stPink
    stUmber
    stOrange
    stPlum
    stLime
    stAzure
    stPeach
    stNavy
    stRust
    stMint
    stGold

  JsonString* = object
    present*: bool
    start*, len*: int32

  SdkPoint* = object
    present*: bool
    x*, y*: int32

  SdkRect* = object
    present*: bool
    x1*, y1*, x2*, y2*: int32

  SdkSelf* = object
    pos*: SdkPoint
    hpPresent*: bool
    hp*: int32
    hpFracPresent*: bool
    hpFracScaled*: int32
    aimPresent*: bool
    aimBrads*: int32
    alivePresent*: bool
    alive*: bool

  SdkZone* = object
    phasePresent*: bool
    phase*: int32
    current*: SdkRect
    next*: SdkRect
    ticksToShrinkPresent*: bool
    ticksToShrink*: int32

  SdkWorld* = object
    aliveTeamsPresent*: bool
    aliveTeams*: int32
    zone*: SdkZone

  SdkTrack* = object
    seatPresent*: bool
    seat*: int32
    teamPresent*: bool
    team*: SdkTeam
    pos*: SdkPoint
    freshTickPresent*: bool
    freshTick*: int32
    hpPresent*: bool
    hp*: int32
    aimPresent*: bool
    aimBrads*: int32
    bountyPresent*: bool
    bounty*: bool

  SdkAggressor* = object
    tickPresent*: bool
    tick*: int32
    dirPresent*: bool
    dirBrads*: int32
    seatPresent*: bool
    seat*: int32

  SdkKillFeed* = object
    tickPresent*: bool
    tick*: int32
    killerTeamPresent*: bool
    killerTeam*: SdkTeam
    victimSeatPresent*: bool
    victimSeat*: int32

  SdkItemKind* = enum
    sikUnknown
    sikGrenade
    sikMedkit
    sikShield
    sikSpray
    sikBarrier

  SdkItem* = object
    kindPresent*: bool
    kind*: SdkItemKind
    pos*: SdkPoint
    freshTickPresent*: bool
    freshTick*: int32
    presentKnown*: bool
    present*: bool

  SdkView* = object
    valid*: bool
    tickPresent*: bool
    tick*: int32
    epochPresent*: bool
    epoch*: int32
    self*: SdkSelf
    world*: SdkWorld
    trackCount*: int32
    tracks*: array[MaxViewTracks, SdkTrack]
    itemCount*: int32
    items*: array[MaxViewItems, SdkItem]
    aggressorCount*: int32
    aggressors*: array[MaxViewAggressors, SdkAggressor]
    killFeedCount*: int32
    killFeed*: array[MaxViewKillFeed, SdkKillFeed]

  SdkContext* = object
    valid*: bool
    selfSeatPresent*: bool
    selfSeat*: int32
    selfTeamPresent*: bool
    selfTeam*: SdkTeam
    duoPartnerPresent*: bool
    duoPartner*: int32

  HoldFireKind* = enum
    hfAliveTeams
    hfTick
    hfZonePhase

  BetrayalMode* = enum
    bmReturnFire
    bmDisengage

  PactRefKind* = enum
    prSeat
    prDuo

  PactRef* = object
    kind*: PactRefKind
    seat*: int32
    team*: SdkTeam

  PactParams* = object
    valid*: bool
    partnersPresent*: bool
    partnerCount*: int32
    partners*: array[MaxPactRefs, PactRef]
    holdFireKind*: HoldFireKind
    holdFireValue*: int32
    protect*: bool
    onBetrayal*: BetrayalMode

  EdgeRideParams* = object
    valid*: bool
    margin*: int32
    coverBiasScaled*: int32
    enterLead*: int32

  SupplyContestedMode* = enum
    scmAvoid
    scmRace

  SupplyRunParams* = object
    valid*: bool
    whenHpBelow*: int32
    detourMax*: int32
    contested*: SupplyContestedMode

  BodyguardParams* = object
    valid*: bool
    wardPresent*: bool
    wardSeat*: int32
    leashMin*: int32
    leashMax*: int32
    interpose*: bool
    peelHp*: int32

  JackalJoinWhen* = enum
    jwAfterKill
    jwBothWeakened

  JackalExitKind* = enum
    jeKills
    jeHpFloor

  JackalParams* = object
    valid*: bool
    earshot*: int32
    joinWhen*: JackalJoinWhen
    exitKind*: JackalExitKind
    exitKills*: int32
    exitHpFloor*: int32

  CrossfireParams* = object
    valid*: bool
    spacingMin*: int32
    spacingMax*: int32
    minAngle*: int32

  SupplyRunView* = object
    valid*: bool
    self*: SdkSelf
    trackCount*: int32
    tracks*: array[MaxViewTracks, SdkTrack]
    itemCount*: int32
    items*: array[MaxViewItems, SdkItem]

  BodyguardView* = object
    valid*: bool
    self*: SdkSelf
    trackCount*: int32
    tracks*: array[MaxViewTracks, SdkTrack]

  JackalView* = object
    valid*: bool
    tickPresent*: bool
    tick*: int32
    self*: SdkSelf
    zone*: SdkZone
    candidateFound*: bool
    candidate*: SdkTrack
    candidateDistSq*: int64
    knownHpCount*: int32
    weakCount*: int32
    freshKill*: bool
    newestOwnKillTick*: int32
    newOwnKillRows*: int32
    trackCount*: int32
    tracks*: array[MaxViewTracks, SdkTrack]
    killFeedCount*: int32
    killFeed*: array[MaxViewKillFeed, SdkKillFeed]

  CrossfireView* = object
    valid*: bool
    self*: SdkSelf
    zone*: SdkZone
    trackCount*: int32
    tracks*: array[MaxViewTracks, SdkTrack]

  EdgeRideView* = object
    valid*: bool
    tickPresent*: bool
    tick*: int32
    selfPos*: SdkPoint
    current*: SdkRect
    next*: SdkRect
    ticksToShrinkPresent*: bool
    ticksToShrink*: int32

  JsonReader = object
    base: ptr UncheckedArray[byte]
    len: int32
    pos: int32
    ok: bool

  BinarySection = object
    present: bool
    count: int32
    stride: int32
    offset: int32

  BinaryFrame = object
    base: ptr UncheckedArray[byte]
    len: int32
    ok: bool
    sectionCount: int32
    tick: int32
    epoch: int32

var
  arena: array[ArenaBytes, byte]
  nextOffset: int32
  emitBuffer: array[EmitBufferBytes, byte]
  emitLen: int32

const
  BinaryFrameHeaderBytes = 32'i32
  BinarySectionEntryBytes = 12'i32
  BinaryFrameVersion = 1'i32

  BvSelf = 1'i32
  BvWorld = 2'i32
  BvZone = 3'i32
  BvTracks = 4'i32
  BvAggressors = 5'i32
  BvKillFeed = 6'i32
  BvItems = 7'i32
  BvContextSelf = 102'i32

  SelfRecordNeed = 28'i32
  WorldRecordNeed = 12'i32
  ZoneRecordNeed = 48'i32
  TrackRecordNeed = 32'i32
  ItemRecordNeed = 24'i32
  AggressorRecordNeed = 16'i32
  KillFeedRecordNeed = 12'i32
  ContextSelfRecordNeed = 16'i32

  SelfAliveFlag = 1'u32
  ZoneNextPresentFlag = 1'u32
  TrackAimPresentFlag = 1'u32
  TrackHpPresentFlag = 2'u32
  TrackBountyFlag = 4'u32
  ItemPresentFieldFlag = 1'u32
  ItemPresentValueFlag = 2'u32
  AggressorSeatPresentFlag = 1'u32
  ContextDuoPresentFlag = 1'u32

proc playEmit(data: int32; length: int32): int32 {.importc: "play_emit",
  cdecl, header: "play_imports.h".}
proc playLog(level: int32; data: int32; length: int32) {.importc: "play_log",
  cdecl, header: "play_imports.h".}
proc playNearestReachable(x, y: int32): int64 {.
  importc: "play_nearest_reachable", cdecl, header: "play_imports.h".}
proc playNearestCover(x, y, radius, bearingBrads, threatsPtr,
                      threatsLen: int32): int64 {.
  importc: "play_nearest_cover", cdecl, header: "play_imports.h".}

proc play_alloc*(length: int32): int32 {.exportc, cdecl.} =
  if length <= 0 or length > ArenaBytes.int32 - nextOffset:
    return 0
  result = cast[int32](addr arena[nextOffset])
  nextOffset += length

proc resetArena*() =
  nextOffset = 0

proc context*(data, len: int32): PlayContext =
  PlayContext(data: data, len: len)

proc view*(data, len: int32): PlayView =
  PlayView(data: data, len: len)

{.push checks: off.}

proc initJsonReader(data, len: int32): JsonReader =
  result.base = cast[ptr UncheckedArray[byte]](data)
  result.len = len
  result.ok = data >= 0 and len >= 0

proc atEnd(r: JsonReader): bool {.inline.} =
  r.pos >= r.len

proc ch(r: JsonReader): char {.inline.} =
  if r.pos < 0 or r.pos >= r.len:
    '\0'
  else:
    char(r.base[r.pos])

proc take(r: var JsonReader; expected: char): bool =
  if not r.ok or r.atEnd or r.ch != expected:
    r.ok = false
    return false
  inc r.pos
  true

proc stringEquals(r: JsonReader; s: JsonString;
                  expected: static[string]): bool {.inline.} =
  if not s.present or s.len != expected.len.int32:
    return false
  for index in 0 ..< expected.len:
    if char(r.base[s.start + index.int32]) != expected[index]:
      return false
  true

proc sliceStartsWith(r: JsonReader; s: JsonString;
                     prefix: static[string]): bool {.inline.} =
  if not s.present or s.len < prefix.len.int32:
    return false
  for index in 0 ..< prefix.len:
    if char(r.base[s.start + index.int32]) != prefix[index]:
      return false
  true

proc digitAt(r: JsonReader; offset: int32): int32 {.inline.} =
  if offset < 0 or offset >= r.len:
    return -1
  let c = char(r.base[offset])
  if c < '0' or c > '9':
    -1
  else:
    int32(ord(c) - ord('0'))

proc parseSeatRef(r: JsonReader; s: JsonString; seat: var int32): bool =
  if not r.sliceStartsWith(s, "seat:") or s.len <= 5:
    return false
  var value = 0'i32
  for offset in s.start + 5 ..< s.start + s.len:
    let digit = r.digitAt(offset)
    if digit < 0:
      return false
    value = value * 10 + digit
    if value >= MaxPolicySeats:
      return false
  seat = value
  true

proc parseTeamSlice(r: JsonReader; s: JsonString): SdkTeam =
  if r.stringEquals(s, "navy"): stNavy
  elif r.stringEquals(s, "rust"): stRust
  elif r.stringEquals(s, "mint"): stMint
  elif r.stringEquals(s, "gold"): stGold
  else: stUnknown

proc parseDuoRef(r: JsonReader; s: JsonString; team: var SdkTeam): bool =
  if not r.sliceStartsWith(s, "duo:") or s.len <= 4:
    return false
  let teamSlice = JsonString(present: true, start: s.start + 4, len: s.len - 4)
  team = r.parseTeamSlice(teamSlice)
  team != stUnknown

proc readJsonString(r: var JsonReader): JsonString =
  if not r.take('"'):
    return
  result.present = true
  result.start = r.pos
  while r.ok and not r.atEnd:
    let c = r.ch
    if c == '"':
      result.len = r.pos - result.start
      inc r.pos
      return
    if c == '\\':
      # The engine emits these field names and pact strings without escapes.
      # Escaped values are treated as a bounded miss instead of being decoded
      # into guest-owned heap memory.
      r.ok = false
      result.present = false
      return
    inc r.pos
  r.ok = false
  result.present = false

proc skipRawString(r: var JsonReader): bool =
  if not r.take('"'):
    return false
  while r.ok and not r.atEnd:
    let c = r.ch
    if c == '"':
      inc r.pos
      return true
    if c == '\\':
      inc r.pos
      if r.atEnd:
        r.ok = false
        return false
      inc r.pos
      continue
    inc r.pos
  r.ok = false
  false

proc readKey(r: var JsonReader): JsonString =
  r.readJsonString()

proc readBoolValue(r: var JsonReader; value: var bool): bool =
  if not r.ok:
    return false
  if r.pos + 4 <= r.len and char(r.base[r.pos]) == 't' and
      char(r.base[r.pos + 1]) == 'r' and char(r.base[r.pos + 2]) == 'u' and
      char(r.base[r.pos + 3]) == 'e':
    r.pos += 4
    value = true
    return true
  if r.pos + 5 <= r.len and char(r.base[r.pos]) == 'f' and
      char(r.base[r.pos + 1]) == 'a' and char(r.base[r.pos + 2]) == 'l' and
      char(r.base[r.pos + 3]) == 's' and char(r.base[r.pos + 4]) == 'e':
    r.pos += 5
    value = false
    return true
  r.ok = false
  false

proc readIntValue(r: var JsonReader; value: var int32): bool =
  if not r.ok:
    return false
  var negative = false
  if r.ch == '-':
    negative = true
    inc r.pos
  var seen = false
  var parsed = 0'i64
  while r.ok and not r.atEnd:
    let digit = r.digitAt(r.pos)
    if digit < 0:
      break
    seen = true
    parsed = parsed * 10 + digit
    if parsed > int64(high(int32)):
      r.ok = false
      return false
    inc r.pos
  if not seen:
    r.ok = false
    return false
  value = int32(parsed)
  if negative:
    value = -value
  true

proc readNumberScaled(r: var JsonReader; value: var int32): bool =
  if not r.ok:
    return false
  var negative = false
  if r.ch == '-':
    negative = true
    inc r.pos
  var parsed = 0'i64
  var scale = 1000000'i32
  var seen = false
  while r.ok and not r.atEnd:
    let digit = r.digitAt(r.pos)
    if digit < 0:
      break
    seen = true
    parsed = parsed * 10 + digit
    inc r.pos
  if not r.atEnd and r.ch == '.':
    inc r.pos
    while r.ok and not r.atEnd:
      let digit = r.digitAt(r.pos)
      if digit < 0:
        break
      seen = true
      if scale > 1:
        parsed = parsed * 10 + digit
        scale = scale div 10
      inc r.pos
  if not seen:
    r.ok = false
    return false
  while scale > 1:
    parsed = parsed * 10
    scale = scale div 10
  if parsed > int64(high(int32)):
    r.ok = false
    return false
  value = int32(parsed)
  if negative:
    value = -value
  true

proc scalarEnded(r: JsonReader): bool {.inline.} =
  r.atEnd or r.ch in {',', '}', ']'}

proc skipParamLiteral(r: var JsonReader; literal: static[string]): bool =
  for ch in literal:
    if not r.take(ch):
      return false
  if not r.scalarEnded:
    r.ok = false
    return false
  true

proc skipParamNumber(r: var JsonReader): bool =
  if r.ch == '-':
    inc r.pos
  var seen = false
  while r.ok and not r.atEnd:
    let digit = r.digitAt(r.pos)
    if digit < 0:
      break
    seen = true
    inc r.pos
  if not seen:
    r.ok = false
    return false
  if not r.atEnd and r.ch == '.':
    inc r.pos
    var fractionSeen = false
    while r.ok and not r.atEnd:
      let digit = r.digitAt(r.pos)
      if digit < 0:
        break
      fractionSeen = true
      inc r.pos
    if not fractionSeen:
      r.ok = false
      return false
  if not r.atEnd and r.ch in {'e', 'E'}:
    inc r.pos
    if not r.atEnd and r.ch in {'+', '-'}:
      inc r.pos
    var exponentSeen = false
    while r.ok and not r.atEnd:
      let digit = r.digitAt(r.pos)
      if digit < 0:
        break
      exponentSeen = true
      inc r.pos
    if not exponentSeen:
      r.ok = false
      return false
  if not r.scalarEnded:
    r.ok = false
    return false
  true

proc skipParamValue(r: var JsonReader; depth: int32 = 0): bool =
  ## Params remain canonical JSON because play_init/play_retune still receive
  ## params bytes and lane A has no binary params encoding. This bounded helper
  ## exists only to skip unknown fields in those tiny params objects under
  ## InitFuel; play_view/play_context bytes are fixed-layout binary frames.
  if not r.ok or depth > 16:
    r.ok = false
    return false
  case r.ch
  of '"':
    result = r.skipRawString()
  of '{':
    if not r.take('{'):
      return false
    if not r.atEnd and r.ch == '}':
      inc r.pos
      return true
    while r.ok:
      discard r.readKey()
      if not r.take(':') or not r.skipParamValue(depth + 1):
        return false
      if not r.atEnd and r.ch == ',':
        inc r.pos
        continue
      if not r.atEnd and r.ch == '}':
        inc r.pos
        return true
      r.ok = false
      return false
    return false
  of '[':
    if not r.take('['):
      return false
    if not r.atEnd and r.ch == ']':
      inc r.pos
      return true
    while r.ok:
      if not r.skipParamValue(depth + 1):
        return false
      if not r.atEnd and r.ch == ',':
        inc r.pos
        continue
      if not r.atEnd and r.ch == ']':
        inc r.pos
        return true
      r.ok = false
      return false
    return false
  of 't':
    result = r.skipParamLiteral("true")
  of 'f':
    result = r.skipParamLiteral("false")
  of 'n':
    result = r.skipParamLiteral("null")
  of '-', '0' .. '9':
    result = r.skipParamNumber()
  else:
    r.ok = false
    return false

proc beginObject(r: var JsonReader): bool =
  r.take('{')

proc nextObjectKey(r: var JsonReader; key: var JsonString): bool =
  if not r.ok:
    return false
  if not r.atEnd and r.ch == '}':
    inc r.pos
    return false
  if not r.atEnd and r.ch == ',':
    inc r.pos
  key = r.readKey()
  if not key.present or not r.take(':'):
    r.ok = false
    return false
  true

proc beginArray(r: var JsonReader): bool =
  r.take('[')

proc nextArrayElement(r: var JsonReader; index: var int32): bool =
  if not r.ok:
    return false
  if not r.atEnd and r.ch == ']':
    inc r.pos
    return false
  if index > 0:
    if not r.take(','):
      return false
  inc index
  true

proc hasBytes(frame: BinaryFrame; offset, count: int32): bool {.inline.} =
  frame.ok and offset >= 0 and count >= 0 and offset <= frame.len - count

proc u8At(frame: BinaryFrame; offset: int32; value: var int32): bool =
  if not frame.hasBytes(offset, 1):
    return false
  value = int32(frame.base[offset])
  true

proc u16At(frame: BinaryFrame; offset: int32; value: var int32): bool =
  if not frame.hasBytes(offset, 2):
    return false
  value = int32(frame.base[offset]) or (int32(frame.base[offset + 1]) shl 8)
  true

proc u32At(frame: BinaryFrame; offset: int32; value: var uint32): bool =
  if not frame.hasBytes(offset, 4):
    return false
  value = uint32(frame.base[offset]) or
    (uint32(frame.base[offset + 1]) shl 8) or
    (uint32(frame.base[offset + 2]) shl 16) or
    (uint32(frame.base[offset + 3]) shl 24)
  true

proc i32At(frame: BinaryFrame; offset: int32; value: var int32): bool =
  var raw = 0'u32
  if not frame.u32At(offset, raw):
    return false
  value = cast[int32](raw)
  true

proc u64At(frame: BinaryFrame; offset: int32; value: var uint64): bool =
  if not frame.hasBytes(offset, 8):
    return false
  value = 0'u64
  for shift in 0 .. 7:
    value = value or (uint64(frame.base[offset + int32(shift)]) shl (shift * 8))
  true

proc f64ScaledAt(frame: BinaryFrame; offset: int32; value: var int32): bool =
  var bits = 0'u64
  if not frame.u64At(offset, bits):
    return false
  var decoded: float64
  copyMem(addr decoded, addr bits, 8)
  value = int32(decoded * 1_000_000.0)
  true

proc initBinaryFrame(view: PlayView): BinaryFrame =
  result.base = cast[ptr UncheckedArray[byte]](view.data)
  result.len = view.len
  result.ok = view.data >= 0 and view.len >= BinaryFrameHeaderBytes
  if not result.ok:
    return
  if char(result.base[0]) != 'P' or char(result.base[1]) != 'V' or
      char(result.base[2]) != '1' or result.base[3] != 0:
    result.ok = false
    return
  var version, sections = 0'i32
  var tickRaw, frameBytes = 0'u32
  var epochRaw = 0'u64
  if not result.u16At(4, version) or version != BinaryFrameVersion or
      not result.u8At(7, sections) or
      not result.u32At(8, tickRaw) or
      not result.u64At(16, epochRaw) or
      not result.u32At(24, frameBytes):
    result.ok = false
    return
  if frameBytes != uint32(view.len) or
      epochRaw > uint64(high(int32)) or tickRaw > uint32(high(int32)):
    result.ok = false
    return
  let tableBytes = int64(BinaryFrameHeaderBytes) +
    int64(sections) * int64(BinarySectionEntryBytes)
  if tableBytes > int64(view.len):
    result.ok = false
    return
  result.sectionCount = sections
  result.tick = int32(tickRaw)
  result.epoch = int32(epochRaw)

proc findSection(frame: var BinaryFrame; kind: int32): BinarySection =
  if not frame.ok:
    return
  for index in 0 ..< frame.sectionCount:
    let entry = BinaryFrameHeaderBytes + index * BinarySectionEntryBytes
    var entryKind, count, stride = 0'i32
    var offsetRaw = 0'u32
    if not frame.u16At(entry, entryKind) or
        not frame.u16At(entry + 2, count) or
        not frame.u16At(entry + 4, stride) or
        not frame.u32At(entry + 8, offsetRaw):
      frame.ok = false
      return
    if entryKind == kind:
      if stride <= 0 or offsetRaw > uint32(high(int32)):
        frame.ok = false
        return
      let offset = int32(offsetRaw)
      let bytes = int64(count) * int64(stride)
      if int64(offset) < int64(BinaryFrameHeaderBytes) +
          int64(frame.sectionCount) * int64(BinarySectionEntryBytes) or
          int64(offset) + bytes > int64(frame.len):
        frame.ok = false
        return
      return BinarySection(present: true, count: count, stride: stride,
        offset: offset)

proc recordOffset(frame: BinaryFrame; section: BinarySection;
                  index, need: int32): int32 =
  if not frame.ok or not section.present or index < 0 or
      index >= section.count or section.stride < need:
    return -1
  let offset = int64(section.offset) + int64(index) * int64(section.stride)
  if offset < 0 or offset + int64(need) > int64(frame.len):
    return -1
  int32(offset)

proc teamFromId(id: int32): SdkTeam =
  ## `src/shell/binary_view.nim` writes ord(Team). Decode every landed BR
  ## team id because live context and track equality must not collapse
  ## non-reference teams to unknown.
  case id
  of 0: stRed
  of 1: stBlue
  of 2: stMint
  of 3: stGold
  of 4: stBlack
  of 5: stSilver
  of 6: stIvory
  of 7: stPink
  of 8: stUmber
  of 9: stRust
  of 10: stOrange
  of 11: stPlum
  of 12: stLime
  of 13: stNavy
  of 14: stAzure
  of 15: stPeach
  else: stUnknown

proc itemFromId(id: int32): SdkItemKind =
  ## `src/shell/binary_view.nim` writes PlayItemKind ids:
  ## grenade=0, medkit=1, shield=2, spray=3, barrier=4.
  case id
  of 0: sikGrenade
  of 1: sikMedkit
  of 2: sikShield
  of 3: sikSpray
  of 4: sikBarrier
  else: sikUnknown

proc rectAt(frame: BinaryFrame; offset: int32): SdkRect =
  var x, y, w, h = 0'i32
  if frame.i32At(offset, x) and frame.i32At(offset + 4, y) and
      frame.i32At(offset + 8, w) and frame.i32At(offset + 12, h):
    result = SdkRect(present: true, x1: x, y1: y, x2: x + w, y2: y + h)

proc readSelf(frame: BinaryFrame; section: BinarySection): SdkSelf =
  let offset = frame.recordOffset(section, 0, SelfRecordNeed)
  if offset < 0:
    return
  var flags = 0'u32
  discard frame.u32At(offset, flags)
  result.alivePresent = true
  result.alive = (flags and SelfAliveFlag) != 0
  result.pos.present =
    frame.i32At(offset + 4, result.pos.x) and
    frame.i32At(offset + 8, result.pos.y)
  result.hpPresent = frame.i32At(offset + 12, result.hp)
  result.hpFracPresent = frame.f64ScaledAt(offset + 16, result.hpFracScaled)
  result.aimPresent = frame.i32At(offset + 24, result.aimBrads)

proc readWorld(frame: BinaryFrame; section: BinarySection): SdkWorld =
  let offset = frame.recordOffset(section, 0, WorldRecordNeed)
  if offset < 0:
    return
  var aliveRaw = 0'u32
  if frame.u32At(offset + 4, aliveRaw) and aliveRaw <= uint32(high(int32)):
    result.aliveTeamsPresent = true
    result.aliveTeams = int32(aliveRaw)

proc readZone(frame: BinaryFrame; section: BinarySection): SdkZone =
  let offset = frame.recordOffset(section, 0, ZoneRecordNeed)
  if offset < 0:
    return
  var flags = 0'u32
  discard frame.u32At(offset, flags)
  result.phasePresent = frame.i32At(offset + 4, result.phase)
  result.ticksToShrinkPresent =
    frame.i32At(offset + 8, result.ticksToShrink)
  result.current = frame.rectAt(offset + 16)
  if (flags and ZoneNextPresentFlag) != 0:
    result.next = frame.rectAt(offset + 32)

proc readTrack(frame: BinaryFrame; section: BinarySection;
               index: int32): SdkTrack =
  let offset = frame.recordOffset(section, index, TrackRecordNeed)
  if offset < 0:
    return
  var flags, seatRaw, teamRaw, tickRaw = 0'u32
  discard frame.u32At(offset, flags)
  if frame.u32At(offset + 4, seatRaw) and seatRaw <= uint32(high(int32)):
    result.seatPresent = true
    result.seat = int32(seatRaw)
  if frame.u32At(offset + 8, teamRaw) and teamRaw <= uint32(high(int32)):
    result.team = teamFromId(int32(teamRaw))
    result.teamPresent = result.team != stUnknown
  result.pos.present =
    frame.i32At(offset + 12, result.pos.x) and
    frame.i32At(offset + 16, result.pos.y)
  if frame.u32At(offset + 20, tickRaw) and tickRaw <= uint32(high(int32)):
    result.freshTickPresent = true
    result.freshTick = int32(tickRaw)
  if (flags and TrackAimPresentFlag) != 0:
    result.aimPresent = frame.i32At(offset + 24, result.aimBrads)
  if (flags and TrackHpPresentFlag) != 0:
    result.hpPresent = frame.i32At(offset + 28, result.hp)
  if (flags and TrackBountyFlag) != 0:
    result.bountyPresent = true
    result.bounty = true

proc readItem(frame: BinaryFrame; section: BinarySection;
              index: int32): SdkItem =
  let offset = frame.recordOffset(section, index, ItemRecordNeed)
  if offset < 0:
    return
  var flags, kindRaw, tickRaw = 0'u32
  discard frame.u32At(offset, flags)
  if frame.u32At(offset + 4, kindRaw) and kindRaw <= uint32(high(int32)):
    result.kind = itemFromId(int32(kindRaw))
    result.kindPresent = result.kind != sikUnknown
  result.pos.present =
    frame.i32At(offset + 8, result.pos.x) and
    frame.i32At(offset + 12, result.pos.y)
  if frame.u32At(offset + 16, tickRaw) and tickRaw <= uint32(high(int32)):
    result.freshTickPresent = true
    result.freshTick = int32(tickRaw)
  if (flags and ItemPresentFieldFlag) != 0:
    result.presentKnown = true
    result.present = (flags and ItemPresentValueFlag) != 0

proc readAggressor(frame: BinaryFrame; section: BinarySection;
                   index: int32): SdkAggressor =
  let offset = frame.recordOffset(section, index, AggressorRecordNeed)
  if offset < 0:
    return
  var flags, tickRaw, dirRaw, seatRaw = 0'u32
  discard frame.u32At(offset, flags)
  if frame.u32At(offset + 4, tickRaw) and tickRaw <= uint32(high(int32)):
    result.tickPresent = true
    result.tick = int32(tickRaw)
  if frame.u32At(offset + 8, dirRaw) and dirRaw <= uint32(high(int32)):
    result.dirPresent = true
    result.dirBrads = int32(dirRaw)
  if (flags and AggressorSeatPresentFlag) != 0 and
      frame.u32At(offset + 12, seatRaw) and seatRaw <= uint32(high(int32)):
    result.seatPresent = true
    result.seat = int32(seatRaw)

proc readKillFeedRow(frame: BinaryFrame; section: BinarySection;
                     index: int32): SdkKillFeed =
  let offset = frame.recordOffset(section, index, KillFeedRecordNeed)
  if offset < 0:
    return
  var tickRaw, teamRaw, victimRaw = 0'u32
  if frame.u32At(offset, tickRaw) and tickRaw <= uint32(high(int32)):
    result.tickPresent = true
    result.tick = int32(tickRaw)
  if frame.u32At(offset + 4, teamRaw) and teamRaw <= uint32(high(int32)):
    result.killerTeam = teamFromId(int32(teamRaw))
    result.killerTeamPresent = result.killerTeam != stUnknown
  if frame.u32At(offset + 8, victimRaw) and
      victimRaw <= uint32(high(int32)):
    result.victimSeatPresent = true
    result.victimSeat = int32(victimRaw)

proc readBinaryViewInto*(view: PlayView; outView: var SdkView): bool =
  outView = default(SdkView)
  var frame = initBinaryFrame(view)
  if not frame.ok:
    return false
  outView.tickPresent = true
  outView.tick = frame.tick
  outView.epochPresent = true
  outView.epoch = frame.epoch
  let selfSection = frame.findSection(BvSelf)
  let worldSection = frame.findSection(BvWorld)
  if not frame.ok or selfSection.count != 1 or worldSection.count != 1:
    return false
  outView.self = frame.readSelf(selfSection)
  outView.world = frame.readWorld(worldSection)
  let zoneSection = frame.findSection(BvZone)
  if frame.ok and zoneSection.present and zoneSection.count == 1:
    outView.world.zone = frame.readZone(zoneSection)
  let tracks = frame.findSection(BvTracks)
  if frame.ok and tracks.present:
    let count = min(tracks.count, MaxViewTracks)
    for index in 0 ..< count:
      outView.tracks[index] = frame.readTrack(tracks, index)
    outView.trackCount = count
  let items = frame.findSection(BvItems)
  if frame.ok and items.present:
    let count = min(items.count, MaxViewItems)
    for index in 0 ..< count:
      outView.items[index] = frame.readItem(items, index)
    outView.itemCount = count
  let aggressors = frame.findSection(BvAggressors)
  if frame.ok and aggressors.present:
    let count = min(aggressors.count, MaxViewAggressors)
    for index in 0 ..< count:
      outView.aggressors[index] = frame.readAggressor(aggressors, index)
    outView.aggressorCount = count
  let killFeed = frame.findSection(BvKillFeed)
  if frame.ok and killFeed.present:
    let count = min(killFeed.count, MaxViewKillFeed)
    for index in 0 ..< count:
      outView.killFeed[index] = frame.readKillFeedRow(killFeed, index)
    outView.killFeedCount = count
  outView.valid = frame.ok and outView.self.pos.present and
    outView.world.aliveTeamsPresent
  outView.valid

proc readBinaryContextInto*(ctx: PlayContext; outCtx: var SdkContext): bool =
  outCtx = default(SdkContext)
  var frame = initBinaryFrame(PlayView(data: ctx.data, len: ctx.len))
  if not frame.ok:
    return false
  let selfSection = frame.findSection(BvContextSelf)
  if not frame.ok or selfSection.count != 1:
    return false
  let offset = frame.recordOffset(selfSection, 0, ContextSelfRecordNeed)
  if offset < 0:
    return false
  var flags, selfRaw, teamRaw = 0'u32
  discard frame.u32At(offset, flags)
  if frame.u32At(offset + 4, selfRaw) and selfRaw <= uint32(high(int32)):
    outCtx.selfSeatPresent = true
    outCtx.selfSeat = int32(selfRaw)
  if frame.u32At(offset + 8, teamRaw) and teamRaw <= uint32(high(int32)):
    outCtx.selfTeam = teamFromId(int32(teamRaw))
    outCtx.selfTeamPresent = outCtx.selfTeam != stUnknown
  if (flags and ContextDuoPresentFlag) != 0:
    outCtx.duoPartnerPresent =
      frame.i32At(offset + 12, outCtx.duoPartner)
  outCtx.valid = frame.ok and outCtx.selfSeatPresent
  outCtx.valid

proc readBinaryView*(view: PlayView): SdkView =
  discard readBinaryViewInto(view, result)

proc checksumBinaryViewFrame*(view: PlayView): int32 =
  ## Test/measurement helper for plays that deliberately inspect the whole
  ## binary frame. Reference plays should prefer typed section readers.
  let frame = initBinaryFrame(view)
  if not frame.ok:
    return -1
  var acc = 0'i32
  for index in 0 ..< frame.len:
    acc = acc + int32(frame.base[index])
  acc

proc readSupplyRunBinaryViewInto*(view: PlayView;
                                  outView: var SupplyRunView): bool =
  ## Supply-run only needs tracks when evaluating one medkit candidate for
  ## contest. Do not materialize the whole track section here; use
  ## supplyRunContestAcceptable on the original frame for that narrow check.
  outView = default(SupplyRunView)
  var frame = initBinaryFrame(view)
  if not frame.ok:
    return false
  let selfSection = frame.findSection(BvSelf)
  if not frame.ok or selfSection.count != 1:
    return false
  outView.self = frame.readSelf(selfSection)
  let items = frame.findSection(BvItems)
  if frame.ok and items.present:
    let count = min(items.count, MaxViewItems)
    for index in 0 ..< count:
      outView.items[index] = frame.readItem(items, index)
    outView.itemCount = count
  outView.valid = frame.ok and outView.self.pos.present
  outView.valid

proc supplyRunContestAcceptable*(view: PlayView; item: SdkItem;
                                 selfPos: SdkPoint; selfTeam: SdkTeam;
                                 mode: SupplyContestedMode;
                                 radiusPx: int32): bool =
  var frame = initBinaryFrame(view)
  if not frame.ok:
    return false
  let tracks = frame.findSection(BvTracks)
  if not frame.ok:
    return false
  if not tracks.present:
    return true
  let count = min(tracks.count, MaxViewTracks)
  let radiusSq = int64(radiusPx) * int64(radiusPx)
  for index in 0 ..< count:
    let offset = frame.recordOffset(tracks, index, TrackRecordNeed)
    if offset < 0:
      return false
    var x, y = 0'i32
    if not frame.i32At(offset + 12, x) or not frame.i32At(offset + 16, y):
      return false
    let dx = x - item.pos.x
    if dx < -radiusPx or dx > radiusPx:
      continue
    let dy = y - item.pos.y
    if dy < -radiusPx or dy > radiusPx:
      continue
    let enemyDistSq = int64(dx) * int64(dx) + int64(dy) * int64(dy)
    if enemyDistSq > radiusSq:
      continue

    var teamRaw = 0'u32
    var enemy = true
    if frame.u32At(offset + 8, teamRaw) and teamRaw <= uint32(high(int32)):
      let team = teamFromId(int32(teamRaw))
      enemy = selfTeam == stUnknown or team == stUnknown or team != selfTeam
    if not enemy:
      continue
    if mode == scmAvoid:
      return false
    if not selfPos.present:
      return false
    let selfDx = selfPos.x - item.pos.x
    let selfDy = selfPos.y - item.pos.y
    let selfDistSq =
      int64(selfDx) * int64(selfDx) + int64(selfDy) * int64(selfDy)
    if selfDistSq >= enemyDistSq:
      return false
  true

proc readBodyguardBinaryViewInto*(view: PlayView;
                                  outView: var BodyguardView): bool =
  outView = default(BodyguardView)
  var frame = initBinaryFrame(view)
  if not frame.ok:
    return false
  let selfSection = frame.findSection(BvSelf)
  if not frame.ok or selfSection.count != 1:
    return false
  outView.self = frame.readSelf(selfSection)
  let tracks = frame.findSection(BvTracks)
  if frame.ok and tracks.present:
    let count = min(tracks.count, MaxViewTracks)
    for index in 0 ..< count:
      outView.tracks[index] = frame.readTrack(tracks, index)
    outView.trackCount = count
  outView.valid = frame.ok and outView.self.pos.present
  outView.valid

proc readJackalBinaryViewInto*(view: PlayView;
                               outView: var JackalView; selfTeam: SdkTeam;
                               earshot, lastOwnKillTick: int32;
                               engaged: bool): bool =
  outView = default(JackalView)
  outView.newestOwnKillTick = -1
  var frame = initBinaryFrame(view)
  if not frame.ok:
    return false
  outView.tickPresent = true
  outView.tick = frame.tick
  let selfSection = frame.findSection(BvSelf)
  if not frame.ok or selfSection.count != 1:
    return false
  outView.self = frame.readSelf(selfSection)
  let zoneSection = frame.findSection(BvZone)
  if frame.ok and zoneSection.present and zoneSection.count == 1:
    outView.zone = frame.readZone(zoneSection)
  let tracks = frame.findSection(BvTracks)
  if frame.ok and tracks.present:
    let count = min(tracks.count, MaxViewTracks)
    let earshotSq = int64(earshot) * int64(earshot)
    for index in 0 ..< count:
      let offset = frame.recordOffset(tracks, index, TrackRecordNeed)
      if offset < 0:
        return false
      var flags, teamRaw, tickRaw = 0'u32
      var track = SdkTrack()
      discard frame.u32At(offset, flags)
      if frame.u32At(offset + 8, teamRaw) and teamRaw <= uint32(high(int32)):
        track.team = teamFromId(int32(teamRaw))
        track.teamPresent = track.team != stUnknown
      track.pos.present =
        frame.i32At(offset + 12, track.pos.x) and
        frame.i32At(offset + 16, track.pos.y)
      if not track.pos.present:
        return false
      if frame.u32At(offset + 20, tickRaw) and tickRaw <= uint32(high(int32)):
        track.freshTickPresent = true
        track.freshTick = int32(tickRaw)
      if (flags and TrackHpPresentFlag) != 0:
        track.hpPresent = frame.i32At(offset + 28, track.hp)
        if not track.hpPresent:
          return false
      if not track.pos.present:
        continue
      var enemy = true
      if track.teamPresent and selfTeam != stUnknown:
        enemy = track.team != selfTeam
      if not enemy:
        continue
      let
        dx = track.pos.x - outView.self.pos.x
        dy = track.pos.y - outView.self.pos.y
        d = int64(dx) * int64(dx) + int64(dy) * int64(dy)
      if d > earshotSq:
        continue
      inc outView.trackCount
      if not outView.candidateFound or
          (track.freshTickPresent and
            (not outView.candidate.freshTickPresent or
              track.freshTick > outView.candidate.freshTick)) or
          (track.freshTickPresent == outView.candidate.freshTickPresent and
            track.freshTick == outView.candidate.freshTick and
            d < outView.candidateDistSq):
        outView.candidateFound = true
        outView.candidate = track
        outView.candidateDistSq = d
      if track.hpPresent:
        inc outView.knownHpCount
        if track.hp * 2 < 4:
          inc outView.weakCount
  let killFeed = frame.findSection(BvKillFeed)
  if frame.ok and killFeed.present:
    let count = min(killFeed.count, MaxViewKillFeed)
    for index in 0 ..< count:
      let offset = frame.recordOffset(killFeed, index, KillFeedRecordNeed)
      if offset < 0:
        return false
      var tickRaw, teamRaw = 0'u32
      if not frame.u32At(offset, tickRaw) or tickRaw > uint32(high(int32)):
        return false
      let rowTick = int32(tickRaw)
      if rowTick <= outView.tick and outView.tick - rowTick <= 240:
        outView.freshKill = true
      if frame.u32At(offset + 4, teamRaw) and teamRaw <= uint32(high(int32)) and
          teamFromId(int32(teamRaw)) == selfTeam:
        outView.newestOwnKillTick = max(outView.newestOwnKillTick, rowTick)
        if engaged and rowTick > lastOwnKillTick:
          inc outView.newOwnKillRows
      inc outView.killFeedCount
  outView.valid = frame.ok and outView.self.pos.present and outView.tickPresent
  outView.valid

proc readJackalBinaryViewInto*(view: PlayView;
                               outView: var JackalView): bool =
  readJackalBinaryViewInto(view, outView, stUnknown, 500, -1, false)

proc readCrossfireBinaryViewInto*(view: PlayView;
                                  outView: var CrossfireView): bool =
  outView = default(CrossfireView)
  var frame = initBinaryFrame(view)
  if not frame.ok:
    return false
  let selfSection = frame.findSection(BvSelf)
  if not frame.ok or selfSection.count != 1:
    return false
  outView.self = frame.readSelf(selfSection)
  let zoneSection = frame.findSection(BvZone)
  if frame.ok and zoneSection.present and zoneSection.count == 1:
    outView.zone = frame.readZone(zoneSection)
  let tracks = frame.findSection(BvTracks)
  if frame.ok and tracks.present:
    let count = min(tracks.count, MaxViewTracks)
    for index in 0 ..< count:
      outView.tracks[index] = frame.readTrack(tracks, index)
    outView.trackCount = count
  outView.valid = frame.ok and outView.self.pos.present
  outView.valid

proc readEdgeRideBinaryViewInto*(view: PlayView;
                                 outView: var EdgeRideView): bool =
  outView = default(EdgeRideView)
  var frame = initBinaryFrame(view)
  if not frame.ok:
    return false
  outView.tickPresent = true
  outView.tick = frame.tick
  let selfSection = frame.findSection(BvSelf)
  let zoneSection = frame.findSection(BvZone)
  if not frame.ok or selfSection.count != 1 or zoneSection.count != 1:
    return false
  let self = frame.readSelf(selfSection)
  outView.selfPos = self.pos
  let zone = frame.readZone(zoneSection)
  outView.current = zone.current
  outView.next = zone.next
  outView.ticksToShrinkPresent = zone.ticksToShrinkPresent
  outView.ticksToShrink = zone.ticksToShrink
  outView.valid = frame.ok and outView.tickPresent and
    outView.selfPos.present and outView.current.present
  outView.valid

proc readPactParams*(ctx: PlayContext): PactParams =
  result.valid = true
  result.holdFireKind = hfAliveTeams
  result.holdFireValue = 2
  result.onBetrayal = bmReturnFire
  var r = initJsonReader(ctx.data, ctx.len)
  if not r.beginObject():
    result.valid = false
    return
  var key: JsonString
  while r.nextObjectKey(key):
    if r.stringEquals(key, "holdFire"):
      if not r.beginObject():
        result.valid = false
        return
      var armCount = 0'i32
      var arm: JsonString
      while r.nextObjectKey(arm):
        inc armCount
        if r.stringEquals(arm, "aliveTeams"):
          result.holdFireKind = hfAliveTeams
          result.valid = result.valid and r.readIntValue(result.holdFireValue)
        elif r.stringEquals(arm, "tick"):
          result.holdFireKind = hfTick
          result.valid = result.valid and r.readIntValue(result.holdFireValue)
        elif r.stringEquals(arm, "zonePhase"):
          result.holdFireKind = hfZonePhase
          result.valid = result.valid and r.readIntValue(result.holdFireValue)
        else:
          discard r.skipParamValue()
          result.valid = false
      if armCount != 1:
        result.valid = false
    elif r.stringEquals(key, "onBetrayal"):
      let value = r.readJsonString()
      if r.stringEquals(value, "returnFire"):
        result.onBetrayal = bmReturnFire
      elif r.stringEquals(value, "disengage"):
        result.onBetrayal = bmDisengage
      else:
        result.valid = false
    elif r.stringEquals(key, "partners"):
      result.partnersPresent = true
      if not r.beginArray():
        result.valid = false
        return
      var index = 0'i32
      while r.nextArrayElement(index):
        let value = r.readJsonString()
        if result.partnerCount >= MaxPactRefs or not value.present:
          result.valid = false
        else:
          var seat = 0'i32
          var team = stUnknown
          if r.parseSeatRef(value, seat):
            result.partners[result.partnerCount] = PactRef(kind: prSeat,
              seat: seat)
            inc result.partnerCount
          elif r.parseDuoRef(value, team):
            result.partners[result.partnerCount] = PactRef(kind: prDuo,
              team: team)
            inc result.partnerCount
          else:
            result.valid = false
    elif r.stringEquals(key, "protect"):
      result.valid = result.valid and r.readBoolValue(result.protect)
    else:
      discard r.skipParamValue()
  if not result.partnersPresent or result.partnerCount == 0:
    result.valid = false
  result.valid = result.valid and r.ok and r.pos == r.len

proc readEdgeRideParams*(ctx: PlayContext): EdgeRideParams =
  result.valid = true
  result.margin = 220
  result.coverBiasScaled = 800_000
  result.enterLead = 120
  var r = initJsonReader(ctx.data, ctx.len)
  if not r.beginObject():
    result.valid = false
    return
  var key: JsonString
  while r.nextObjectKey(key):
    if r.stringEquals(key, "coverBias"):
      result.valid = result.valid and r.readNumberScaled(result.coverBiasScaled)
      if result.coverBiasScaled < 0 or result.coverBiasScaled > 1_000_000:
        result.valid = false
    elif r.stringEquals(key, "enterLead"):
      result.valid = result.valid and r.readIntValue(result.enterLead)
      if result.enterLead < 0 or result.enterLead > 600:
        result.valid = false
    elif r.stringEquals(key, "margin"):
      result.valid = result.valid and r.readIntValue(result.margin)
      if result.margin < 40 or result.margin > 600:
        result.valid = false
    else:
      discard r.skipParamValue()
      result.valid = false
  result.valid = result.valid and r.ok and r.pos == r.len

proc readSupplyRunParams*(ctx: PlayContext): SupplyRunParams =
  result.valid = true
  result.whenHpBelow = 3
  result.detourMax = 500
  result.contested = scmAvoid
  var r = initJsonReader(ctx.data, ctx.len)
  if not r.beginObject():
    result.valid = false
    return
  var key: JsonString
  while r.nextObjectKey(key):
    if r.stringEquals(key, "whenHpBelow"):
      result.valid = result.valid and r.readIntValue(result.whenHpBelow)
      if result.whenHpBelow < 0 or result.whenHpBelow > 64:
        result.valid = false
    elif r.stringEquals(key, "detourMax"):
      result.valid = result.valid and r.readIntValue(result.detourMax)
      if result.detourMax < 0 or result.detourMax > 4096:
        result.valid = false
    elif r.stringEquals(key, "contested"):
      let value = r.readJsonString()
      if r.stringEquals(value, "avoid"):
        result.contested = scmAvoid
      elif r.stringEquals(value, "race"):
        result.contested = scmRace
      else:
        result.valid = false
    else:
      discard r.skipParamValue()
      result.valid = false
  result.valid = result.valid and r.ok and r.pos == r.len

proc readBodyguardParams*(ctx: PlayContext): BodyguardParams =
  result.valid = true
  result.leashMin = 80
  result.leashMax = 220
  result.interpose = true
  result.peelHp = 2
  var r = initJsonReader(ctx.data, ctx.len)
  if not r.beginObject():
    result.valid = false
    return
  var key: JsonString
  while r.nextObjectKey(key):
    if r.stringEquals(key, "ward"):
      let value = r.readJsonString()
      result.wardPresent = true
      if not r.parseSeatRef(value, result.wardSeat):
        result.valid = false
    elif r.stringEquals(key, "leash"):
      if not r.beginArray():
        result.valid = false
        return
      var index = 0'i32
      var values: array[2, int32]
      while r.nextArrayElement(index):
        if index <= 2:
          result.valid = result.valid and r.readIntValue(values[int(index - 1)])
        else:
          discard r.skipParamValue()
          result.valid = false
      if index != 2:
        result.valid = false
      result.leashMin = values[0]
      result.leashMax = values[1]
      if result.leashMin < 0 or result.leashMax < result.leashMin or
          result.leashMax > 4096:
        result.valid = false
    elif r.stringEquals(key, "interpose"):
      result.valid = result.valid and r.readBoolValue(result.interpose)
    elif r.stringEquals(key, "peelHp"):
      result.valid = result.valid and r.readIntValue(result.peelHp)
      if result.peelHp < 0 or result.peelHp > 64:
        result.valid = false
    else:
      discard r.skipParamValue()
      result.valid = false
  result.valid = result.valid and r.ok and r.pos == r.len

proc readJackalParams*(ctx: PlayContext): JackalParams =
  result.valid = true
  result.earshot = 500
  result.joinWhen = jwAfterKill
  result.exitKind = jeKills
  result.exitKills = 1
  var r = initJsonReader(ctx.data, ctx.len)
  if not r.beginObject():
    result.valid = false
    return
  var key: JsonString
  while r.nextObjectKey(key):
    if r.stringEquals(key, "earshot"):
      result.valid = result.valid and r.readIntValue(result.earshot)
      if result.earshot < 100 or result.earshot > 1200:
        result.valid = false
    elif r.stringEquals(key, "joinWhen"):
      let value = r.readJsonString()
      if r.stringEquals(value, "afterKill"):
        result.joinWhen = jwAfterKill
      elif r.stringEquals(value, "bothWeakened"):
        result.joinWhen = jwBothWeakened
      else:
        result.valid = false
    elif r.stringEquals(key, "exitAfter"):
      if not r.beginObject():
        result.valid = false
        return
      var armCount = 0'i32
      var arm: JsonString
      while r.nextObjectKey(arm):
        inc armCount
        if r.stringEquals(arm, "kills"):
          result.exitKind = jeKills
          result.valid = result.valid and r.readIntValue(result.exitKills)
          if result.exitKills < 1 or result.exitKills > 4:
            result.valid = false
        elif r.stringEquals(arm, "hpFloor"):
          result.exitKind = jeHpFloor
          result.valid = result.valid and r.readIntValue(result.exitHpFloor)
          if result.exitHpFloor < 0 or result.exitHpFloor > 3:
            result.valid = false
        else:
          discard r.skipParamValue()
          result.valid = false
      if armCount != 1:
        result.valid = false
    else:
      discard r.skipParamValue()
      result.valid = false
  result.valid = result.valid and r.ok and r.pos == r.len

proc readCrossfireParams*(ctx: PlayContext): CrossfireParams =
  result.valid = true
  result.spacingMin = 120
  result.spacingMax = 320
  result.minAngle = 32
  var r = initJsonReader(ctx.data, ctx.len)
  if not r.beginObject():
    result.valid = false
    return
  var key: JsonString
  while r.nextObjectKey(key):
    if r.stringEquals(key, "spacing"):
      if not r.beginArray():
        result.valid = false
        return
      var index = 0'i32
      var values: array[2, int32]
      while r.nextArrayElement(index):
        if index <= 2:
          result.valid = result.valid and r.readIntValue(values[int(index - 1)])
        else:
          discard r.skipParamValue()
          result.valid = false
      if index != 2:
        result.valid = false
      result.spacingMin = values[0]
      result.spacingMax = values[1]
      if result.spacingMin < 0 or result.spacingMax < result.spacingMin or
          result.spacingMax > 600:
        result.valid = false
    elif r.stringEquals(key, "minAngle"):
      result.valid = result.valid and r.readIntValue(result.minAngle)
      if result.minAngle < 0 or result.minAngle > 128:
        result.valid = false
    else:
      discard r.skipParamValue()
      result.valid = false
  result.valid = result.valid and r.ok and r.pos == r.len

{.pop.}

proc unpackGoal(value: int64): ValidatedGoal =
  if value >= 0:
    result.ok = true
    result.x = int32((value shr 32) and 0xffffffff'i64)
    result.y = int32(value and 0xffffffff'i64)

proc nearestReachable*(x, y: int32): ValidatedGoal =
  ## The sole SDK constructor for an encodable navigation goal.
  unpackGoal(playNearestReachable(x, y))

proc nearestCover*(x, y, radius: int32; bearingBrads: int32 = -1): ValidatedGoal =
  ## Host cover query over the engine-side atlas. The scorer is now live;
  ## candidate density is governed by the engine's frozen
  ## `MaxCoverRadiusPx`/`MaxCoverPostsExamined` caps.
  unpackGoal(playNearestCover(x, y, radius, bearingBrads, 0, 0))

proc log*(level: int32; bytes: openArray[byte]) =
  if bytes.len > 0:
    playLog(level, cast[int32](unsafeAddr bytes[0]), bytes.len.int32)
  else:
    playLog(level, 0, 0)

proc emitRaw*(bytes: openArray[byte]): int32 =
  if bytes.len > 0:
    playEmit(cast[int32](unsafeAddr bytes[0]), bytes.len.int32)
  else:
    playEmit(0, 0)

proc clearEmitBuffer() =
  emitLen = 0

proc appendByte(value: byte) =
  if emitLen < EmitBufferBytes.int32:
    emitBuffer[emitLen] = value
    inc emitLen

template appendLiteral(text: static[string]) =
  for ch in text:
    appendByte(byte(ord(ch)))

proc emitRaw*(text: static[string]): int32 =
  clearEmitBuffer()
  appendLiteral(text)
  playEmit(cast[int32](addr emitBuffer[0]), emitLen)

proc appendInt(value: int32) =
  if value == 0:
    appendByte(byte(ord('0')))
    return
  var digits: array[12, byte]
  var remaining = value
  var count = 0
  if remaining < 0:
    appendByte(byte(ord('-')))
    remaining = -remaining
  while remaining > 0:
    digits[count] = byte(ord('0') + remaining mod 10)
    remaining = remaining div 10
    inc count
  while count > 0:
    dec count
    appendByte(digits[count])

proc appendSeatText(seat: int32) =
  appendLiteral("seat:")
  appendInt(seat)

proc appendTeamText(team: SdkTeam) =
  case team
  of stRed: appendLiteral("red")
  of stBlue: appendLiteral("blue")
  of stGreen, stMint: appendLiteral("mint")
  of stYellow, stGold: appendLiteral("gold")
  of stBlack: appendLiteral("black")
  of stSilver: appendLiteral("silver")
  of stIvory: appendLiteral("ivory")
  of stPink: appendLiteral("pink")
  of stUmber: appendLiteral("umber")
  of stNavy: appendLiteral("navy")
  of stRust: appendLiteral("rust")
  of stOrange: appendLiteral("orange")
  of stPlum: appendLiteral("plum")
  of stLime: appendLiteral("lime")
  of stAzure: appendLiteral("azure")
  of stPeach: appendLiteral("peach")
  of stUnknown: appendLiteral("unknown")

proc appendPactRef(value: PactRef) =
  case value.kind
  of prSeat:
    appendSeatText(value.seat)
  of prDuo:
    appendLiteral("duo:")
    appendTeamText(value.team)

proc seatTextLess(a, b: int32): bool =
  ## Host policy_encoding sorts resolved protected-set spellings as strings.
  if a == b:
    return false
  if a < 10 and b < 10:
    return a < b
  if a < 10:
    return int32(ord('0') + a) < int32(ord('0') + (b div 10))
  if b < 10:
    return int32(ord('0') + (a div 10)) < int32(ord('0') + b)
  let aTens = a div 10
  let bTens = b div 10
  if aTens != bTens:
    return aTens < bTens
  (a mod 10) < (b mod 10)

proc sortSeats(seats: var array[MaxPolicySeats, int32]; count: int32): int32 =
  var n = count
  if n > MaxPolicySeats:
    n = MaxPolicySeats
  for index in 1 ..< n:
    let value = seats[index]
    var cursor = index
    while cursor > 0 and seatTextLess(value, seats[cursor - 1]):
      seats[cursor] = seats[cursor - 1]
      dec cursor
    seats[cursor] = value
  n

proc appendProtectedSeats(seats: var array[MaxPolicySeats, int32];
                          count: int32) =
  let n = sortSeats(seats, count)
  appendLiteral("{\"seats\":[")
  var wrote = false
  var previous = -1'i32
  for index in 0 ..< n:
    if index == 0 or seats[index] != previous:
      if wrote:
        appendByte(byte(ord(',')))
      appendByte(byte(ord('"')))
      appendSeatText(seats[index])
      appendByte(byte(ord('"')))
      wrote = true
      previous = seats[index]
  appendLiteral("]}")

proc emitCombatPolicySeats*(noShoot: var array[MaxPolicySeats, int32];
                            noShootCount: int32;
                            protect: var array[MaxPolicySeats, int32];
                            protectCount: int32): int32 =
  clearEmitBuffer()
  appendLiteral("{")
  var needComma = false
  if noShootCount > 0:
    appendLiteral("\"no_shoot\":")
    appendProtectedSeats(noShoot, noShootCount)
    needComma = true
  if protectCount > 0:
    if needComma:
      appendByte(byte(ord(',')))
    appendLiteral("\"protect\":")
    appendProtectedSeats(protect, protectCount)
    needComma = true
  if needComma:
    appendByte(byte(ord(',')))
  appendLiteral("\"schema\":\"combat_policy\",\"v\":1}")
  playEmit(cast[int32](addr emitBuffer[0]), emitLen)

proc emitCombatPolicyRefs*(noShoot: var array[MaxPactRefs, PactRef];
                           noShootCount: int32;
                           protect: var array[MaxPactRefs, PactRef];
                           protectCount: int32): int32 =
  clearEmitBuffer()
  appendLiteral("{")
  var needComma = false
  if noShootCount > 0:
    appendLiteral("\"no_shoot\":{\"seats\":[")
    for index in 0 ..< noShootCount:
      if index > 0:
        appendByte(byte(ord(',')))
      appendByte(byte(ord('"')))
      appendPactRef(noShoot[index])
      appendByte(byte(ord('"')))
    appendLiteral("]}")
    needComma = true
  if protectCount > 0:
    if needComma:
      appendByte(byte(ord(',')))
    appendLiteral("\"protect\":{\"seats\":[")
    for index in 0 ..< protectCount:
      if index > 0:
        appendByte(byte(ord(',')))
      appendByte(byte(ord('"')))
      appendPactRef(protect[index])
      appendByte(byte(ord('"')))
    appendLiteral("]}")
    needComma = true
  if needComma:
    appendByte(byte(ord(',')))
  appendLiteral("\"schema\":\"combat_policy\",\"v\":1}")
  playEmit(cast[int32](addr emitBuffer[0]), emitLen)

proc emitHoldController*(reason: static[string] = ""): int32 =
  clearEmitBuffer()
  appendLiteral("{\"arrive_radius\":0.0,\"kind\":\"hold\"")
  when reason.len > 0:
    appendLiteral(",\"reason\":\"")
    appendLiteral(reason)
    appendLiteral("\"")
  appendLiteral(",\"schema\":\"intent\",\"v\":1}")
  playEmit(cast[int32](addr emitBuffer[0]), emitLen)

proc emitNavigateController*(goal: ValidatedGoal; arriveRadius: static[string];
                             reason: static[string] = ""): int32 =
  if not goal.ok:
    return -3
  clearEmitBuffer()
  appendLiteral("{\"arrive_radius\":")
  appendLiteral(arriveRadius)
  appendLiteral(",\"kind\":\"navigate_to\",\"point\":[")
  appendInt(goal.x)
  appendLiteral(",")
  appendInt(goal.y)
  appendLiteral("]")
  when reason.len > 0:
    appendLiteral(",\"reason\":\"")
    appendLiteral(reason)
    appendLiteral("\"")
  appendLiteral(",\"schema\":\"intent\",\"v\":1}")
  playEmit(cast[int32](addr emitBuffer[0]), emitLen)

proc emitHoldFireOverlay*(): int32 =
  clearEmitBuffer()
  appendLiteral("{\"hold_fire\":true,\"schema\":\"combat_policy\",\"v\":1}")
  playEmit(cast[int32](addr emitBuffer[0]), emitLen)
