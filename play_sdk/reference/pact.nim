## `pact` reference overlay.
##
## The overlay emits `combat_policy` bytes only. Those bytes are validated and
## folded by the Season 2 shell, then enforced by the body-side weapon
## integration before live weapon paths actuate.

import ../play

const
  ManifestBytes =
    "{\"abi\":1,\"class\":\"overlay\",\"doc\":\"negotiated alliance: never target partners, dissolve at an agreed endgame\",\"modes\":[\"br\"],\"name\":\"pact\",\"params\":{\"holdFire\":{\"arms\":{\"aliveTeams\":{\"integer\":true,\"kind\":\"number\",\"max\":16,\"min\":2},\"tick\":{\"integer\":true,\"kind\":\"number\",\"min\":0},\"zonePhase\":{\"integer\":true,\"kind\":\"number\",\"max\":8,\"min\":1}},\"default\":{\"aliveTeams\":2},\"kind\":\"union\"},\"onBetrayal\":{\"default\":\"returnFire\",\"kind\":\"enum\",\"of\":[\"disengage\",\"returnFire\"]},\"partners\":{\"kind\":\"set\",\"max_items\":8,\"min_items\":1,\"of\":\"seat_or_duo_ref\",\"required\":true},\"protect\":{\"default\":false,\"kind\":\"bool\"}},\"retune\":true}"

type
  SeatSet = object
    count: int32
    seats: array[MaxPolicySeats, int32]

var
  params: PactParams
  ended: bool
  betrayedNoShoot: array[MaxPolicySeats, bool]
  betrayedProtect: array[MaxPolicySeats, bool]
  lastPresent: bool
  lastNoShootCount: int32
  lastProtectCount: int32
  lastNoShoot: array[MaxPactRefs, PactRef]
  lastProtect: array[MaxPactRefs, PactRef]

proc resetPolicyCache() =
  lastPresent = false
  lastNoShootCount = 0
  lastProtectCount = 0

proc play_manifest*() {.exportc, cdecl.} =
  discard emitRaw(ManifestBytes)

proc sameRef(a, b: PactRef): bool =
  a.kind == b.kind and a.seat == b.seat and a.team == b.team

proc samePolicy(noShoot: var array[MaxPactRefs, PactRef]; noShootCount: int32;
                protect: var array[MaxPactRefs, PactRef];
                protectCount: int32): bool =
  if not lastPresent or noShootCount != lastNoShootCount or
      protectCount != lastProtectCount:
    return false
  for index in 0 ..< noShootCount:
    if not sameRef(noShoot[index], lastNoShoot[index]):
      return false
  for index in 0 ..< protectCount:
    if not sameRef(protect[index], lastProtect[index]):
      return false
  true

proc rememberPolicy(noShoot: var array[MaxPactRefs, PactRef]; noShootCount: int32;
                    protect: var array[MaxPactRefs, PactRef];
                    protectCount: int32) =
  lastPresent = true
  lastNoShootCount = noShootCount
  lastProtectCount = protectCount
  for index in 0 ..< noShootCount:
    lastNoShoot[index] = noShoot[index]
  for index in 0 ..< protectCount:
    lastProtect[index] = protect[index]

proc addSeat(seats: var SeatSet; seat: int32) =
  if seat < 0 or seat >= MaxPolicySeats:
    return
  for index in 0 ..< seats.count:
    if seats.seats[index] == seat:
      return
  if seats.count < MaxPolicySeats:
    seats.seats[seats.count] = seat
    inc seats.count

proc resolvePartners(view: SdkView): SeatSet =
  for index in 0 ..< params.partnerCount:
    let partner = params.partners[index]
    case partner.kind
    of prSeat:
      result.addSeat(partner.seat)
    of prDuo:
      for trackIndex in 0 ..< view.trackCount:
        let track = view.tracks[trackIndex]
        if track.seatPresent and track.teamPresent and track.team == partner.team:
          result.addSeat(track.seat)

proc containsSeat(seats: SeatSet; seat: int32): bool =
  for index in 0 ..< seats.count:
    if seats.seats[index] == seat:
      return true
  false

proc markBetrayals(view: SdkView; partners: SeatSet) =
  for index in 0 ..< view.aggressorCount:
    let aggressor = view.aggressors[index]
    if aggressor.seatPresent and partners.containsSeat(aggressor.seat):
      betrayedProtect[aggressor.seat] = true
      if params.onBetrayal == bmReturnFire:
        betrayedNoShoot[aggressor.seat] = true

proc seatExcludedForRef(value: PactRef;
                        excluded: array[MaxPolicySeats, bool]): bool =
  case value.kind
  of prSeat:
    value.seat >= 0 and value.seat < MaxPolicySeats and excluded[value.seat]
  of prDuo:
    false

proc addRef(dest: var array[MaxPactRefs, PactRef]; count: var int32;
            value: PactRef) =
  if count < MaxPactRefs:
    dest[count] = value
    inc count

proc addDuoRemainder(dest: var array[MaxPactRefs, PactRef]; count: var int32;
                     view: SdkView; team: SdkTeam;
                     excluded: array[MaxPolicySeats, bool]) =
  for trackIndex in 0 ..< view.trackCount:
    let track = view.tracks[trackIndex]
    if track.seatPresent and track.teamPresent and track.team == team and
        track.seat >= 0 and track.seat < MaxPolicySeats and
        not excluded[track.seat]:
      dest.addRef(count, PactRef(kind: prSeat, seat: track.seat))

proc addActiveRefs(dest: var array[MaxPactRefs, PactRef]; count: var int32;
                   view: SdkView; excluded: array[MaxPolicySeats, bool]) =
  for index in 0 ..< params.partnerCount:
    let partner = params.partners[index]
    case partner.kind
    of prSeat:
      if not seatExcludedForRef(partner, excluded):
        dest.addRef(count, partner)
    of prDuo:
      var betrayedMember = false
      for trackIndex in 0 ..< view.trackCount:
        let track = view.tracks[trackIndex]
        if track.seatPresent and track.teamPresent and
            track.team == partner.team and track.seat >= 0 and
            track.seat < MaxPolicySeats and excluded[track.seat]:
          betrayedMember = true
      if betrayedMember:
        dest.addDuoRemainder(count, view, partner.team, excluded)
      else:
        dest.addRef(count, partner)

proc endConditionReached(view: SdkView): bool =
  case params.holdFireKind
  of hfAliveTeams:
    view.world.aliveTeamsPresent and
      view.world.aliveTeams <= params.holdFireValue
  of hfTick:
    view.tickPresent and view.tick >= params.holdFireValue
  of hfZonePhase:
    view.world.zone.phasePresent and
      view.world.zone.phase >= params.holdFireValue

proc loadParams(dataPtr, dataLen: int32; clearCache: bool): int32 =
  let decoded = readPactParams(context(dataPtr, dataLen))
  if not decoded.valid:
    return 1
  params = decoded
  if clearCache:
    resetPolicyCache()
  0

proc play_init*(paramsPtr, paramsLen, ctxPtr, ctxLen: int32): int32 {.
    exportc, cdecl.} =
  discard ctxPtr
  discard ctxLen
  resetArena()
  ended = false
  for index in 0 ..< MaxPolicySeats:
    betrayedNoShoot[index] = false
    betrayedProtect[index] = false
  loadParams(paramsPtr, paramsLen, true)

proc play_step*(viewPtr, viewLen: int32): int32 {.exportc, cdecl.} =
  var decoded: SdkView
  if not readBinaryViewInto(view(viewPtr, viewLen), decoded):
    return 1

  if not ended and endConditionReached(decoded):
    ended = true

  var noShoot: array[MaxPactRefs, PactRef]
  var protect: array[MaxPactRefs, PactRef]
  var noShootCount = 0'i32
  var protectCount = 0'i32

  if not ended:
    let partnerSeats = resolvePartners(decoded)
    markBetrayals(decoded, partnerSeats)
    noShoot.addActiveRefs(noShootCount, decoded, betrayedNoShoot)
    if params.protect:
      protect.addActiveRefs(protectCount, decoded, betrayedProtect)

  if samePolicy(noShoot, noShootCount, protect, protectCount):
    resetArena()
    return 0
  let code = emitCombatPolicyRefs(noShoot, noShootCount, protect, protectCount)
  if code < 0:
    return code
  rememberPolicy(noShoot, noShootCount, protect, protectCount)
  resetArena()
  0

proc play_retune*(oldPtr, oldLen, newPtr, newLen: int32): int32 {.
    exportc, cdecl.} =
  discard oldPtr
  discard oldLen
  resetArena()
  loadParams(newPtr, newLen, false)
