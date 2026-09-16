## `loot` reference controller: fetch nearby pickups while the coast is clear.
##
## `supply_run` only ever chases medkits, and only when wounded, so every
## other item on the floor -- grenades, shields, spray cans, barriers -- went
## unused: the Season 2 starters averaged 0.1-0.4 pickups per seat per match.
## This is the general-purpose fetcher. It carries NO trigger of its own; the
## caller gates it with a `when` guard (no tracked enemy, an item within
## `detourMax`) so it only wins the ladder while looting is safe. When it is
## stepped and finds nothing it emits nothing, which yields the seat to the
## engine default until the guard closes and the rung below takes over.
##
## Degradations mirror supply_run's: items are the body-visible item memory in
## the landed view frame (no guest memory once an item leaves the frame), and
## `detourMax` is measured from the seat's position before the engine resolves
## the target with `nearest_reachable`.

import ../play

const
  ManifestBytes =
    "{\"abi\":1,\"class\":\"controller\",\"doc\":\"fetch the nearest reachable pickup of any kind while no enemy is tracked\",\"modes\":[\"br\"],\"name\":\"loot\",\"params\":{\"contested\":{\"default\":\"avoid\",\"kind\":\"enum\",\"of\":[\"avoid\",\"race\"]},\"detourMax\":{\"default\":400,\"integer\":true,\"kind\":\"number\",\"max\":4096,\"min\":0},\"medkits\":{\"default\":false,\"kind\":\"bool\"}},\"retune\":true}"
  PickupRangePx = 12'i32

type
  DecisionKind = enum
    dkNone
    dkRun

  Candidate = object
    found: bool
    index: int32
    x, y: int32
    distSq: int64

var
  params: LootParams
  selfTeam: SdkTeam
  lastKind: DecisionKind
  lastX, lastY: int32

proc play_manifest*() {.exportc, cdecl.} =
  discard emitRaw(ManifestBytes)

proc sq(value: int32): int64 {.inline.} =
  int64(value) * int64(value)

proc distSq(a, b: SdkPoint): int64 {.inline.} =
  sq(a.x - b.x) + sq(a.y - b.y)

proc itemUsable(item: SdkItem): bool =
  if not item.kindPresent or not item.pos.present:
    return false
  if item.presentKnown and not item.present:
    return false
  case item.kind
  of sikUnknown: false
  of sikMedkit: params.medkits
  else: true

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
  if not view.self.pos.present:
    return
  var rejected: array[MaxViewItems, bool]
  for _ in 0 ..< view.itemCount:
    let candidate = view.chooseNearestUnrejected(rejected)
    if not candidate.found:
      return
    if supplyRunContestAcceptable(rawView, view.items[int(candidate.index)],
        view.self.pos, selfTeam, params.contested, PickupRangePx):
      return candidate
    rejected[int(candidate.index)] = true

proc sameDecision(kind: DecisionKind; x = 0'i32; y = 0'i32): bool =
  lastKind == kind and lastX == x and lastY == y

proc remember(kind: DecisionKind; x = 0'i32; y = 0'i32) =
  lastKind = kind
  lastX = x
  lastY = y

proc resetDecisionCache() =
  lastKind = dkNone
  lastX = 0
  lastY = 0

proc loadParams(dataPtr, dataLen: int32; clearCache: bool): int32 =
  let decoded = readLootParams(context(dataPtr, dataLen))
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
    # Nothing worth fetching: emit nothing and let the guard close.
    resetArena()
    return 0

  let goal = nearestReachable(raw.x, raw.y)
  if not goal.ok:
    resetArena()
    return 0
  if sameDecision(dkRun, goal.x, goal.y):
    resetArena()
    return 0
  let code = emitNavigateController(goal, "12.0", "loot:fetch")
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
