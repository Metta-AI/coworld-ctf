## `target_law` reference overlay.
##
## Degradations:
## - `prefer` is emitted through the landed `combat_policy.prefer` vocabulary.
##   The body-side preference scorer is engine-owned; this play only supplies
##   the ordered tags.
## - `holdTrigger` is limited to pact's landed condition shapes:
##   `{aliveTeams:N}`, `{zonePhase:k}`, and `{tick:t}`.
## - `never` emits the same seat/duo reference spellings as pact. Duo
##   resolution and noDuosInMode enforcement stay engine-side.

import ../play

const
  ManifestBytes =
    "{\"abi\":1,\"class\":\"overlay\",\"doc\":\"standing target filter: never shoot protected refs, prefer targets, and gate first fire\",\"modes\":[\"br\",\"ctf\"],\"name\":\"target_law\",\"params\":{\"holdTrigger\":{\"arms\":{\"aliveTeams\":{\"integer\":true,\"kind\":\"number\",\"max\":16,\"min\":2},\"tick\":{\"integer\":true,\"kind\":\"number\",\"min\":0},\"zonePhase\":{\"integer\":true,\"kind\":\"number\",\"max\":8,\"min\":1}},\"kind\":\"union\"},\"never\":{\"default\":[],\"kind\":\"set\",\"max_items\":8,\"min_items\":0,\"of\":\"seat_or_duo_ref\"},\"prefer\":{\"default\":[],\"kind\":\"list\",\"max_items\":4,\"min_items\":0,\"of\":{\"kind\":\"enum\",\"of\":[\"bounty\",\"isolated\",\"revenge\",\"weakened\"]}}},\"retune\":true}"

var
  params: TargetLawParams
  holdReleased: bool
  lastPresent: bool
  lastHoldFire: bool
  lastNeverCount: int32
  lastNever: array[MaxPactRefs, PactRef]
  lastPreferCount: int32
  lastPrefer: array[4, TargetLawPreferTag]

proc play_manifest*() {.exportc, cdecl.} =
  discard emitRaw(ManifestBytes)

proc sameRef(a, b: PactRef): bool =
  a.kind == b.kind and a.seat == b.seat and a.team == b.team

proc samePolicy(holdFire: bool): bool =
  if not lastPresent or holdFire != lastHoldFire or
      params.neverCount != lastNeverCount or params.preferCount != lastPreferCount:
    return false
  for index in 0 ..< params.neverCount:
    if not sameRef(params.never[index], lastNever[index]):
      return false
  for index in 0 ..< params.preferCount:
    if params.prefer[index] != lastPrefer[index]:
      return false
  true

proc rememberPolicy(holdFire: bool) =
  lastPresent = true
  lastHoldFire = holdFire
  lastNeverCount = params.neverCount
  lastPreferCount = params.preferCount
  for index in 0 ..< params.neverCount:
    lastNever[index] = params.never[index]
  for index in 0 ..< params.preferCount:
    lastPrefer[index] = params.prefer[index]

proc resetPolicyCache() =
  lastPresent = false
  lastHoldFire = false
  lastNeverCount = 0
  lastPreferCount = 0

proc triggerReached(view: TargetLawView): bool =
  case params.holdKind
  of thNone:
    true
  of thAliveTeams:
    view.world.aliveTeamsPresent and view.world.aliveTeams <= params.holdValue
  of thTick:
    view.tickPresent and view.tick >= params.holdValue
  of thZonePhase:
    view.world.zone.phasePresent and view.world.zone.phase >= params.holdValue

proc loadParams(dataPtr, dataLen: int32; clearCache: bool): int32 =
  let decoded = readTargetLawParams(context(dataPtr, dataLen))
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
  holdReleased = false
  loadParams(paramsPtr, paramsLen, true)

proc play_step*(viewPtr, viewLen: int32): int32 {.exportc, cdecl.} =
  var decoded: TargetLawView
  if not readTargetLawBinaryViewInto(view(viewPtr, viewLen), decoded):
    return 1

  if not holdReleased and triggerReached(decoded):
    holdReleased = true
  let holdFire = params.holdKind != thNone and not holdReleased
  if samePolicy(holdFire):
    resetArena()
    return 0
  let code = emitTargetLawPolicy(params.never, params.neverCount,
    params.prefer, params.preferCount, holdFire)
  if code < 0:
    return code
  rememberPolicy(holdFire)
  resetArena()
  0

proc play_retune*(oldPtr, oldLen, newPtr, newLen: int32): int32 {.
    exportc, cdecl.} =
  discard oldPtr
  discard oldLen
  resetArena()
  loadParams(newPtr, newLen, false)
