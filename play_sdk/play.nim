## Minimal Nim play SDK for the Season 2 core-WASM ABI.
##
## This library is author convenience only. The server's real security
## boundary remains `src/shell`: binary validation, manifest parsing, ABI
## checks, host queries, and emit validation.

const
  ArenaBytes = 32 * 1024
  EmitBufferBytes = 1024
  MaxViewTracks* = 32
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
    aggressorCount*: int32
    aggressors*: array[MaxViewAggressors, SdkAggressor]
    killFeedCount*: int32
    killFeed*: array[MaxViewKillFeed, SdkKillFeed]

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

  JsonReader = object
    base: ptr UncheckedArray[byte]
    len: int32
    pos: int32
    ok: bool

var
  arena: array[ArenaBytes, byte]
  nextOffset: int32
  emitBuffer: array[EmitBufferBytes, byte]
  emitLen: int32

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

proc skipValue(r: var JsonReader; depth: int32 = 0): bool =
  if not r.ok or depth > 16:
    r.ok = false
    return false
  case r.ch
  of '"':
    result = r.skipRawString()
  of '{':
    var nesting = 0'i32
    while r.ok and not r.atEnd:
      case r.ch
      of '"':
        if not r.skipRawString():
          return false
        continue
      of '{', '[':
        inc nesting
      of '}', ']':
        dec nesting
        inc r.pos
        if nesting == 0:
          return true
        continue
      of '\\':
        r.ok = false
        return false
      else:
        discard
      inc r.pos
    r.ok = false
    return false
  of '[':
    var nesting = 0'i32
    while r.ok and not r.atEnd:
      case r.ch
      of '"':
        if not r.skipRawString():
          return false
        continue
      of '{', '[':
        inc nesting
      of '}', ']':
        dec nesting
        inc r.pos
        if nesting == 0:
          return true
        continue
      of '\\':
        r.ok = false
        return false
      else:
        discard
      inc r.pos
    r.ok = false
    return false
  of '-', '0' .. '9', 't', 'f', 'n':
    while r.ok and not r.atEnd and r.ch notin {',', '}', ']'}:
      inc r.pos
    result = true
  else:
    r.ok = false
    return false

proc readPoint(r: var JsonReader): SdkPoint =
  if not r.take('['):
    return
  var x, y = 0'i32
  if not r.readIntValue(x) or not r.take(',') or not r.readIntValue(y) or
      not r.take(']'):
    return
  result = SdkPoint(present: true, x: x, y: y)

proc readRect(r: var JsonReader): SdkRect =
  if not r.take('['):
    return
  var values: array[4, int32]
  for index in 0 .. 3:
    if index > 0 and not r.take(','):
      return
    if not r.readIntValue(values[index]):
      return
  if not r.take(']'):
    return
  result = SdkRect(present: true, x1: values[0], y1: values[1],
    x2: values[2], y2: values[3])

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

proc readSelf(r: var JsonReader): SdkSelf =
  if not r.beginObject():
    return
  var key: JsonString
  while r.nextObjectKey(key):
    if r.stringEquals(key, "aim_brads"):
      result.aimPresent = r.readIntValue(result.aimBrads)
    elif r.stringEquals(key, "alive"):
      result.alivePresent = r.readBoolValue(result.alive)
    elif r.stringEquals(key, "hp"):
      result.hpPresent = r.readIntValue(result.hp)
    elif r.stringEquals(key, "hp_frac"):
      result.hpFracPresent = r.readNumberScaled(result.hpFracScaled)
    elif r.stringEquals(key, "pos"):
      result.pos = r.readPoint()
    else:
      discard r.skipValue()

proc readZone(r: var JsonReader): SdkZone =
  if not r.beginObject():
    return
  var key: JsonString
  while r.nextObjectKey(key):
    if r.stringEquals(key, "current"):
      result.current = r.readRect()
    elif r.stringEquals(key, "phase"):
      result.phasePresent = r.readIntValue(result.phase)
    elif r.stringEquals(key, "ticks_to_shrink"):
      result.ticksToShrinkPresent = r.readIntValue(result.ticksToShrink)
    else:
      discard r.skipValue()

proc readWorld(r: var JsonReader): SdkWorld =
  if not r.beginObject():
    return
  var key: JsonString
  while r.nextObjectKey(key):
    if r.stringEquals(key, "alive_teams"):
      result.aliveTeamsPresent = r.readIntValue(result.aliveTeams)
    elif r.stringEquals(key, "zone"):
      result.zone = r.readZone()
    else:
      discard r.skipValue()

proc readTrack(r: var JsonReader): SdkTrack =
  if not r.beginObject():
    return
  var key: JsonString
  while r.nextObjectKey(key):
    if r.stringEquals(key, "aim_brads"):
      result.aimPresent = r.readIntValue(result.aimBrads)
    elif r.stringEquals(key, "bounty"):
      result.bountyPresent = r.readBoolValue(result.bounty)
    elif r.stringEquals(key, "fresh_tick"):
      result.freshTickPresent = r.readIntValue(result.freshTick)
    elif r.stringEquals(key, "hp"):
      result.hpPresent = r.readIntValue(result.hp)
    elif r.stringEquals(key, "pos"):
      result.pos = r.readPoint()
    elif r.stringEquals(key, "seat"):
      result.seatPresent = r.readIntValue(result.seat)
    elif r.stringEquals(key, "team"):
      let value = r.readJsonString()
      result.team = r.parseTeamSlice(value)
      result.teamPresent = value.present and result.team != stUnknown
    else:
      discard r.skipValue()

proc readAggressor(r: var JsonReader): SdkAggressor =
  if not r.beginObject():
    return
  var key: JsonString
  while r.nextObjectKey(key):
    if r.stringEquals(key, "dir_brads"):
      result.dirPresent = r.readIntValue(result.dirBrads)
    elif r.stringEquals(key, "seat"):
      result.seatPresent = r.readIntValue(result.seat)
    elif r.stringEquals(key, "tick"):
      result.tickPresent = r.readIntValue(result.tick)
    else:
      discard r.skipValue()

proc readKillFeedRow(r: var JsonReader): SdkKillFeed =
  if not r.beginObject():
    return
  var key: JsonString
  while r.nextObjectKey(key):
    if r.stringEquals(key, "killer_team"):
      let value = r.readJsonString()
      result.killerTeam = r.parseTeamSlice(value)
      result.killerTeamPresent = value.present and result.killerTeam != stUnknown
    elif r.stringEquals(key, "tick"):
      result.tickPresent = r.readIntValue(result.tick)
    elif r.stringEquals(key, "victim_seat"):
      result.victimSeatPresent = r.readIntValue(result.victimSeat)
    else:
      discard r.skipValue()

proc readViewInto*(view: PlayView; outView: var SdkView): bool =
  outView.valid = false
  outView.tickPresent = false
  outView.tick = 0
  outView.epochPresent = false
  outView.epoch = 0
  outView.self = default(SdkSelf)
  outView.world = default(SdkWorld)
  outView.trackCount = 0
  outView.aggressorCount = 0
  outView.killFeedCount = 0
  var r = initJsonReader(view.data, view.len)
  if not r.beginObject():
    return false
  var key: JsonString
  while r.nextObjectKey(key):
    if r.stringEquals(key, "aggressors"):
      if not r.beginArray():
        return false
      var index = 0'i32
      while r.nextArrayElement(index):
        if outView.aggressorCount < MaxViewAggressors:
          outView.aggressors[outView.aggressorCount] = r.readAggressor()
          inc outView.aggressorCount
        else:
          discard r.skipValue()
    elif r.stringEquals(key, "epoch"):
      let value = r.readJsonString()
      if value.present:
        var parsed = 0'i32
        var ok = true
        for offset in value.start ..< value.start + value.len:
          let digit = r.digitAt(offset)
          if digit < 0:
            ok = false
          else:
            parsed = parsed * 10 + digit
        outView.epochPresent = ok
        outView.epoch = parsed
      else:
        r.ok = false
    elif r.stringEquals(key, "kill_feed"):
      if not r.beginArray():
        return
      var index = 0'i32
      while r.nextArrayElement(index):
        if outView.killFeedCount < MaxViewKillFeed:
          outView.killFeed[outView.killFeedCount] = r.readKillFeedRow()
          inc outView.killFeedCount
        else:
          discard r.skipValue()
    elif r.stringEquals(key, "self"):
      outView.self = r.readSelf()
    elif r.stringEquals(key, "tick"):
      outView.tickPresent = r.readIntValue(outView.tick)
    elif r.stringEquals(key, "tracks"):
      if not r.beginArray():
        return false
      var index = 0'i32
      while r.nextArrayElement(index):
        if outView.trackCount < MaxViewTracks:
          outView.tracks[outView.trackCount] = r.readTrack()
          inc outView.trackCount
        else:
          discard r.skipValue()
    elif r.stringEquals(key, "world"):
      outView.world = r.readWorld()
    else:
      discard r.skipValue()
  outView.valid = r.ok and r.pos == r.len
  outView.valid

proc readView*(view: PlayView): SdkView =
  discard readViewInto(view, result)

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
          result.valid = r.readIntValue(result.holdFireValue)
        elif r.stringEquals(arm, "tick"):
          result.holdFireKind = hfTick
          result.valid = r.readIntValue(result.holdFireValue)
        elif r.stringEquals(arm, "zonePhase"):
          result.holdFireKind = hfZonePhase
          result.valid = r.readIntValue(result.holdFireValue)
        else:
          discard r.skipValue()
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
      result.valid = r.readBoolValue(result.protect)
    else:
      discard r.skipValue()
  if not result.partnersPresent or result.partnerCount == 0:
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
  ## candidate density is still freeze-pending and is governed by the
  ## engine's `MaxCoverRadiusPx`/`MaxCoverPostsExamined` caps.
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
  of stNavy: appendLiteral("navy")
  of stRust: appendLiteral("rust")
  of stMint: appendLiteral("mint")
  of stGold: appendLiteral("gold")
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
