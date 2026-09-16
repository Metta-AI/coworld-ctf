## `supply_run` reference controller.
##
## Degradations:
## - Items are the current body-visible item memory in the landed view frame.
##   There is no separate guest item-memory API, so the play does not remember
##   medkits after they leave the frame.
## - The landed SDK does not expose the current route. `detourMax` is measured
##   from the seat's current position, then the engine resolves the target with
##   `nearest_reachable`.
## - The landed binary producer always includes self HP for live seats. If a
##   future producer omits it, this play holds rather than guessing from a
##   fraction with no max-HP contract.

import ../play

const
  ManifestBytes =
    "{\"abi\":1,\"class\":\"controller\",\"doc\":\"detour to reachable medkits when wounded, avoiding or racing contested pickups\",\"modes\":[\"br\"],\"name\":\"supply_run\",\"params\":{\"contested\":{\"default\":\"avoid\",\"kind\":\"enum\",\"of\":[\"avoid\",\"race\"]},\"detourMax\":{\"default\":500,\"integer\":true,\"kind\":\"number\",\"max\":4096,\"min\":0},\"whenHpBelow\":{\"default\":3,\"integer\":true,\"kind\":\"number\",\"max\":64,\"min\":0}},\"retune\":true}"
  MedkitPickupRangePx = 12'i32

type
  DecisionKind = enum
    dkNone
    dkHold
    dkRun

  Candidate = object
    found: bool
    index: int32
    x, y: int32
    distSq: int64

var
  params: SupplyRunParams
  selfTeam: SdkTeam
  lastKind: DecisionKind
  lastX, lastY: int32

proc play_manifest*() {.exportc, cdecl.} =
  discard emitRaw(ManifestBytes)

proc sq(value: int32): int64 {.inline.} =
  int64(value) * int64(value)

proc distSq(a, b: SdkPoint): int64 {.inline.} =
  sq(a.x - b.x) + sq(a.y - b.y)

proc triggered(view: SupplyRunView): bool =
  if view.self.hpPresent:
    return view.self.hp < params.whenHpBelow
  false

proc itemUsable(item: SdkItem): bool =
  item.kindPresent and item.kind == sikMedkit and item.pos.present and
    (not item.presentKnown or item.present)

proc chooseNearestUnrejected(view: SupplyRunView;
                             rejected: var array[MaxViewItems, bool]):
    Candidate =
  let maxSq = sq(params.detourMax)
  for index in 0 ..< view.itemCount:
    if rejected[int(index)]:
      continue
    let item = view.items[index]
    if not item.itemUsable:
      continue
    let d = view.self.pos.distSq(item.pos)
    if d > maxSq:
      continue
    if not result.found or d < result.distSq or
        (d == result.distSq and (item.pos.y < result.y or
          (item.pos.y == result.y and item.pos.x < result.x))):
      result = Candidate(found: true, index: index, x: item.pos.x,
        y: item.pos.y, distSq: d)

proc choose(rawView: PlayView; view: SupplyRunView): Candidate =
  if not view.self.pos.present or not view.triggered:
    return
  var rejected: array[MaxViewItems, bool]
  for _ in 0 ..< view.itemCount:
    let candidate = view.chooseNearestUnrejected(rejected)
    if not candidate.found:
      return
    if supplyRunContestAcceptable(rawView, view.items[int(candidate.index)],
        view.self.pos, selfTeam, params.contested, MedkitPickupRangePx):
      return candidate
    rejected[int(candidate.index)] = true

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
  let code = emitHoldController("supply_run:hold")
  if code < 0:
    return code
  remember(dkHold)
  resetArena()
  0

proc resetDecisionCache() =
  lastKind = dkNone
  lastX = 0
  lastY = 0

proc loadParams(dataPtr, dataLen: int32; clearCache: bool): int32 =
  let decoded = readSupplyRunParams(context(dataPtr, dataLen))
  if not decoded.valid:
    return 1
  params = decoded
  if clearCache:
    resetDecisionCache()
  0

proc loadContext(ctxPtr, ctxLen: int32) =
  var decoded: SdkContext
  if readBinaryContextInto(context(ctxPtr, ctxLen), decoded) and
      decoded.selfTeamPresent:
    selfTeam = decoded.selfTeam
  else:
    selfTeam = stUnknown

proc play_init*(paramsPtr, paramsLen, ctxPtr, ctxLen: int32): int32 {.
    exportc, cdecl.} =
  resetArena()
  loadContext(ctxPtr, ctxLen)
  loadParams(paramsPtr, paramsLen, true)

proc play_step*(viewPtr, viewLen: int32): int32 {.exportc, cdecl.} =
  let rawView = view(viewPtr, viewLen)
  var decoded: SupplyRunView
  if not readSupplyRunBinaryViewInto(rawView, decoded):
    return 1

  let raw = choose(rawView, decoded)
  if not raw.found:
    return emitHoldIfChanged()

  let goal = nearestReachable(raw.x, raw.y)
  if not goal.ok:
    return emitHoldIfChanged()
  if sameDecision(dkRun, goal.x, goal.y):
    resetArena()
    return 0
  let code = emitNavigateController(goal, "12.0", "supply_run:medkit")
  if code < 0:
    return code
  remember(dkRun, goal.x, goal.y)
  resetArena()
  0

proc play_retune*(oldPtr, oldLen, newPtr, newLen: int32): int32 {.
    exportc, cdecl.} =
  discard oldPtr
  discard oldLen
  resetArena()
  loadParams(newPtr, newLen, true)
