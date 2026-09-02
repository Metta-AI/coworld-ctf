## `hold_vs_gun` -- MONET's first custom controller.
##
## Ports Picasso's audited "never turn your back on a live gun" lever into
## the Season 2 play shell: under fire the play stands its ground facing the
## threat (body-side owns facing/fire) and will only reposition to cover that
## keeps a sightline on the gun; it never navigates directly away from the
## freshest aggressor bearing. Intended to sit as a guarded ladder rung
## (`.when` proximity guard) above the default rotation.
##
## Degradations (all verified against src/shell at 842b0fcf):
## - Aggressor rows carry a bearing, not a position (SdkAggressor.dirBrads),
##   so the away test runs in the cover atlas's own 16-sector space; the
##   sector thresholds are copied from src/shell/cover_scorer.nim so guest
##   and host classify bearings identically.
## - "No advancing across open toward the enemy" is approximated as
##   distance-closing along the direct bearing (+-1 sector): the guest has
##   no raycast, and nearest_cover only returns atlas cover posts anyway.
## - Today's server integration feeds no aggressor events into the body
##   (src/ctf/server.nim firstLightBodyInputs builds self/partner/tracks
##   only), so the hot branch is dormant on the live server until that
##   lands; the engageDist track branch carries the lever meanwhile.

import ../../../play_sdk/play

const
  ManifestBytes =
    "{\"abi\":1,\"class\":\"controller\",\"doc\":\"never turn your back on a live gun: stand ground facing the threat, take only facing cover\",\"modes\":[\"br\"],\"name\":\"hold_vs_gun\",\"params\":{\"calmTicks\":{\"default\":48,\"integer\":true,\"kind\":\"number\",\"max\":120,\"min\":12},\"coverMax\":{\"default\":260,\"integer\":true,\"kind\":\"number\",\"max\":600,\"min\":0},\"engageDist\":{\"default\":500,\"integer\":true,\"kind\":\"number\",\"max\":1200,\"min\":100}},\"retune\":true}"

  # src/shell/cover_scorer.nim's half-sector slope thresholds (16 sectors).
  SlopeScale = 1_000_000'i64
  Tan1125 = 198_912'i64
  Tan3375 = 668_179'i64
  Tan5625 = 1_496_606'i64
  Tan7875 = 5_027_339'i64

type
  DecisionKind = enum
    dkNone
    dkHold
    dkCover
    dkZone

  HoldParams = object
    valid: bool
    calmTicks: int32
    coverMax: int32
    engageDist: int32

var
  params: HoldParams
  selfTeam: SdkTeam
  lastKind: DecisionKind
  lastX, lastY: int32

proc play_manifest*() {.exportc, cdecl.} =
  discard emitRaw(ManifestBytes)

proc absI64(value: int64): int64 {.inline.} =
  if value < 0: -value else: value

proc minI(a, b: int32): int32 {.inline.} =
  if a < b: a else: b

proc maxI(a, b: int32): int32 {.inline.} =
  if a > b: a else: b

proc clampI(value, lo, hi: int32): int32 {.inline.} =
  if value < lo: lo
  elif value > hi: hi
  else: value

proc sq(value: int32): int64 {.inline.} =
  int64(value) * int64(value)

proc distSq(a, b: SdkPoint): int64 {.inline.} =
  sq(a.x - b.x) + sq(a.y - b.y)

proc quadrantSector(adx, ady: int64): int32 =
  if ady * SlopeScale <= adx * Tan1125: 0
  elif ady * SlopeScale < adx * Tan3375: 1
  elif ady * SlopeScale <= adx * Tan5625: 2
  elif ady * SlopeScale < adx * Tan7875: 3
  else: 4

proc sectorTo(a, b: SdkPoint): int32 =
  ## Same 16-sector classification as the host cover scorer.
  let dx = b.x - a.x
  let dy = b.y - a.y
  let offset = quadrantSector(absI64(int64(dx)), absI64(int64(dy)))
  if dx == 0 and dy == 0: 0
  elif dx >= 0:
    if dy >= 0: offset else: (16 - offset) mod 16
  elif dy >= 0: 8 - offset
  else: 8 + offset

proc sectorOfBrads(brads: int32): int32 =
  ((brads + 8) div 16) mod 16

proc sectorGap(a, b: int32): int32 =
  let d = ((a - b) mod 16 + 16) mod 16
  if d > 8: 16 - d else: d

proc keyIs(buf: ptr UncheckedArray[byte]; start, length: int32;
           expected: static[string]): bool =
  if length != expected.len.int32:
    return false
  for index in 0 ..< expected.len:
    if char(buf[start + index.int32]) != expected[index]:
      return false
  true

proc readParams(dataPtr, dataLen: int32): HoldParams =
  ## Strict reader over the canonical params bytes ({"a":1,...}, keys sorted,
  ## no whitespace, plain non-negative integers). Missing keys keep the
  ## manifest defaults; anything else is invalid.
  result = HoldParams(valid: true, calmTicks: 48, coverMax: 260,
    engageDist: 500)
  if dataLen <= 0:
    return
  let buf = cast[ptr UncheckedArray[byte]](dataPtr)
  var pos = 0'i32
  template cur(): char =
    (if pos < dataLen: char(buf[pos]) else: '\0')
  template fail() =
    result.valid = false
    return
  if cur() != '{': fail()
  inc pos
  if cur() == '}':
    inc pos
    result.valid = pos == dataLen
    return
  while true:
    if cur() != '"': fail()
    inc pos
    let keyStart = pos
    while pos < dataLen and char(buf[pos]) != '"':
      inc pos
    if pos >= dataLen: fail()
    let keyLen = pos - keyStart
    inc pos
    if cur() != ':': fail()
    inc pos
    var value = 0'i32
    var digits = 0
    while cur() in {'0' .. '9'}:
      if digits >= 6: fail()
      value = value * 10 + int32(ord(cur()) - ord('0'))
      inc digits
      inc pos
    if digits == 0: fail()
    if buf.keyIs(keyStart, keyLen, "calmTicks"):
      result.calmTicks = value
      if value < 12 or value > 120: result.valid = false
    elif buf.keyIs(keyStart, keyLen, "coverMax"):
      result.coverMax = value
      if value > 600: result.valid = false
    elif buf.keyIs(keyStart, keyLen, "engageDist"):
      result.engageDist = value
      if value < 100 or value > 1200: result.valid = false
    else:
      result.valid = false
    if cur() == ',':
      inc pos
      continue
    break
  if cur() != '}': fail()
  inc pos
  if pos != dataLen: result.valid = false

proc sameDecision(kind: DecisionKind; x = 0'i32; y = 0'i32): bool =
  lastKind == kind and (kind == dkHold or (lastX == x and lastY == y))

proc remember(kind: DecisionKind; x = 0'i32; y = 0'i32) =
  lastKind = kind
  lastX = x
  lastY = y

proc emitHoldIfChanged(): int32 =
  if sameDecision(dkHold):
    resetArena()
    return 0
  let code = emitHoldController("hold_vs_gun:stand")
  if code < 0:
    return code
  remember(dkHold)
  resetArena()
  0

proc movesAwayFromGun(selfPos: SdkPoint; goal: ValidatedGoal;
                      threatDirBrads: int32): bool =
  ## True when the goal is a move within +-1 sector of DIRECTLY away from
  ## the freshest aggressor bearing -- the one move this play never makes.
  if threatDirBrads < 0:
    return false
  if goal.x == selfPos.x and goal.y == selfPos.y:
    return false
  let goalPoint = SdkPoint(present: true, x: goal.x, y: goal.y)
  let awaySector = (sectorOfBrads(threatDirBrads) + 8) mod 16
  sectorGap(sectorTo(selfPos, goalPoint), awaySector) <= 1

proc advancesAcrossOpen(selfPos: SdkPoint; goal: ValidatedGoal;
                        enemy: SdkPoint): bool =
  ## True when the goal closes distance on the enemy along the direct
  ## bearing (+-1 sector): shadowing cover is fine, walking at the gun over
  ## open ground is not.
  let goalPoint = SdkPoint(present: true, x: goal.x, y: goal.y)
  if distSq(goalPoint, enemy) >= distSq(selfPos, enemy):
    return false
  sectorGap(sectorTo(selfPos, goalPoint), sectorTo(selfPos, enemy)) <= 1

proc loadParams(dataPtr, dataLen: int32; clearCache: bool): int32 =
  let decoded = readParams(dataPtr, dataLen)
  if not decoded.valid:
    return 1
  params = decoded
  if clearCache:
    lastKind = dkNone
    lastX = 0
    lastY = 0
  0

proc loadContext(ctxPtr, ctxLen: int32) =
  var decoded: SdkContext
  selfTeam = stUnknown
  if readBinaryContextInto(context(ctxPtr, ctxLen), decoded) and
      decoded.selfTeamPresent:
    selfTeam = decoded.selfTeam

proc play_init*(paramsPtr, paramsLen, ctxPtr, ctxLen: int32): int32 {.
    exportc, cdecl.} =
  resetArena()
  loadContext(ctxPtr, ctxLen)
  loadParams(paramsPtr, paramsLen, true)

proc emitCover(goal: ValidatedGoal; reason: static[string]): int32 =
  if sameDecision(dkCover, goal.x, goal.y):
    resetArena()
    return 0
  let code = emitNavigateController(goal, "24.0", reason)
  if code < 0:
    return code
  remember(dkCover, goal.x, goal.y)
  resetArena()
  0

const ZoneInsetPx = 64'i32

proc zoneTarget(decoded: SdkView): SdkPoint =
  ## Outside the current safe zone nothing else matters: the re-entry point
  ## is self clamped into the rect inset toward the center (server-version-
  ## independent zone discipline -- guards may not be evaluated for us).
  result.present = false
  let zone = decoded.world.zone.current
  if not zone.present or not decoded.self.pos.present:
    return
  let
    lox = minI(zone.x1, zone.x2)
    hix = maxI(zone.x1, zone.x2)
    loy = minI(zone.y1, zone.y2)
    hiy = maxI(zone.y1, zone.y2)
  if decoded.self.pos.x >= lox and decoded.self.pos.x <= hix and
      decoded.self.pos.y >= loy and decoded.self.pos.y <= hiy:
    return                        # already inside: no zone move
  let
    ix = minI(ZoneInsetPx, (hix - lox) div 2)
    iy = minI(ZoneInsetPx, (hiy - loy) div 2)
  result.present = true
  result.x = clampI(decoded.self.pos.x, lox + ix, hix - ix)
  result.y = clampI(decoded.self.pos.y, loy + iy, hiy - iy)

proc emitZone(goal: ValidatedGoal; reason: static[string]): int32 =
  if sameDecision(dkZone, goal.x, goal.y):
    resetArena()
    return 0
  let code = emitNavigateController(goal, "24.0", reason)
  if code < 0:
    return code
  remember(dkZone, goal.x, goal.y)
  resetArena()
  0

proc play_step*(viewPtr, viewLen: int32): int32 {.exportc, cdecl.} =
  var decoded: SdkView
  if not readBinaryViewInto(view(viewPtr, viewLen), decoded):
    return 1
  if not decoded.self.pos.present:
    return emitHoldIfChanged()

  # Zone discipline first: outside the safe zone there is no fight worth
  # standing in -- walk back in, whatever the tracks say.
  let reentry = zoneTarget(decoded)
  if reentry.present:
    let goal = nearestReachable(reentry.x, reentry.y)
    if goal.ok:
      return emitZone(goal, "hold_vs_gun:zone")
    return emitHoldIfChanged()

  # Hot: any aggressor event fresher than calmTicks (rows are pre-windowed
  # to 120 ticks server-side; freshest kept defensively by scan).
  var hotFound = false
  var hotTick = -1'i32
  var hotDir = -1'i32
  if decoded.tickPresent:
    for index in 0 ..< decoded.aggressorCount:
      let row = decoded.aggressors[index]
      if row.tickPresent and row.tick <= decoded.tick and
          decoded.tick - row.tick < params.calmTicks and row.tick > hotTick:
        hotFound = true
        hotTick = row.tick
        hotDir = if row.dirPresent: row.dirBrads else: -1

  if hotFound:
    # Stand ground facing the gun; only facing cover may move us.
    if params.coverMax > 0:
      let goal = nearestCover(decoded.self.pos.x, decoded.self.pos.y,
        params.coverMax, hotDir)
      if goal.ok and not movesAwayFromGun(decoded.self.pos, goal, hotDir):
        return emitCover(goal, "hold_vs_gun:cover")
    return emitHoldIfChanged()

  # Not hot: shadow the nearest visible enemy track from cover.
  var enemyFound = false
  var enemy: SdkPoint
  var enemyDistSq = high(int64)
  for index in 0 ..< decoded.trackCount:
    let track = decoded.tracks[index]
    if not track.pos.present:
      continue
    if track.teamPresent and selfTeam != stUnknown and track.team == selfTeam:
      continue
    let d = distSq(decoded.self.pos, track.pos)
    if not enemyFound or d < enemyDistSq:
      enemyFound = true
      enemy = track.pos
      enemyDistSq = d

  if enemyFound and enemyDistSq <= sq(params.engageDist):
    if params.coverMax > 0:
      let bearing = sectorTo(decoded.self.pos, enemy) * 16
      let goal = nearestCover(decoded.self.pos.x, decoded.self.pos.y,
        params.coverMax, bearing)
      if goal.ok and not advancesAcrossOpen(decoded.self.pos, goal, enemy):
        return emitCover(goal, "hold_vs_gun:overwatch")
    return emitHoldIfChanged()

  # Calm (normally the ladder guard keeps us from owning this state).
  emitHoldIfChanged()

proc play_retune*(oldPtr, oldLen, newPtr, newLen: int32): int32 {.
    exportc, cdecl.} =
  discard oldPtr
  discard oldLen
  resetArena()
  loadParams(newPtr, newLen, true)
