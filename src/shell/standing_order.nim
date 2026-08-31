## The zero-guest §7.4 standing-order path used by FIRST LIGHT.

import std/options
import bitworld/spriteprotocol
import ../ctf/sim_types
import body_map
import types
import default_play
import finisher

export default_play, finisher

type
  BodyTickInputs* = object
    input*: InputState

  LaneABrSnapshot* = object
    ## Lane-C adapter snapshot until lane A FL-A relays its read surface.
    ## Goal proof construction already uses lane A's concrete BodyMap.
    selfPos*: MapPoint
    currentZone*: MapRect
    nextZone*: MapRect
    ticksToNextShrink*: int
    zoneDps*: int
    idleAimCenterBrads*: int
    threatPositions*: seq[MapPoint]
    rotateTarget*: Option[MapPoint]
    coverGoal*: Option[ValidatedGoal]
    partnerTarget*: Option[MapPoint]

  SeatBody* = object
    seat*: uint8
    map*: BodyMap
    brSnapshot*: LaneABrSnapshot
    partner*: PartnerTelemetry
    hasInstalledIntent*: bool
    installedIntent*: Intent
    installedGoal*: Option[ValidatedGoal]
    installedEffectiveEpoch*: uint64
    installCount*: int

  StandingOrderState* = object
    hasStanding*: bool
    intent*: Intent
    intentBytes*: string
    provenance*: Provenance
    effectiveEpoch*: uint64
    installedEffectiveEpoch*: uint64
    lastDefaultRule*: BrDefaultRule
    annotations*: seq[ShellAnnotation]

proc activateSeatBody*(map: BodyMap, seat: uint8): SeatBody =
  ## Frozen lane-A operation; wrapper remains lane C until FL-A relays it.
  SeatBody(seat: seat, map: map)

proc setStandingIntent*(body: var SeatBody, intent: Intent,
    goal: Option[ValidatedGoal], effectiveEpoch: uint64) =
  ## Frozen lane-A operation; the goal argument prevents a raw point from
  ## crossing the install boundary.
  assert (intent.kind == ikNavigateTo) == goal.isSome
  if goal.isSome:
    assert intent.point == some(goal.get.goalPoint.toMapPoint)
  body.hasInstalledIntent = true
  body.installedIntent = intent
  body.installedGoal = goal
  body.installedEffectiveEpoch = effectiveEpoch
  inc body.installCount

proc seatTick*(body: var SeatBody, inputs: BodyTickInputs,
    tick: uint32): InputState =
  ## Frozen lane-A operation; execution is supplied by lane A on relay.
  discard body
  discard tick
  inputs.input

proc partnerTelemetry*(body: SeatBody): PartnerTelemetry =
  ## Frozen granted accessor; concrete visibility/staleness stays in lane A.
  body.partner

proc brDefaultFacts*(body: SeatBody, tick: uint32): BrDefaultFacts =
  ## Lane-C adapter over the current read surface. On FL-A relay this keeps its
  ## result type and reads the concrete lane-A accessors instead.
  var threats: seq[BodyPoint]
  for point in body.brSnapshot.threatPositions:
    threats.add(point.toBodyPoint)
  BrDefaultFacts(
    tick: tick,
    map: body.map,
    selfPos: body.brSnapshot.selfPos.toBodyPoint,
    currentZone: body.brSnapshot.currentZone,
    nextZone: body.brSnapshot.nextZone,
    ticksToNextShrink: body.brSnapshot.ticksToNextShrink,
    zoneDps: body.brSnapshot.zoneDps,
    idleAimCenterBrads: body.brSnapshot.idleAimCenterBrads,
    threatPositions: threats,
    partner: partnerTelemetry(body),
    rotateTarget: if body.brSnapshot.rotateTarget.isSome:
      some(body.brSnapshot.rotateTarget.get.toBodyPoint) else: none(BodyPoint),
    coverGoal: body.brSnapshot.coverGoal,
    partnerTarget: if body.brSnapshot.partnerTarget.isSome:
      some(body.brSnapshot.partnerTarget.get.toBodyPoint) else: none(BodyPoint))

proc sameProvenance(a, b: Provenance): bool =
  if a.base.kind != b.base.kind or a.overlays != b.overlays:
    return false
  case a.base.kind
  of pbEntry:
    a.base.entryId == b.base.entryId and
      a.base.moduleSha256 == b.base.moduleSha256 and
      a.base.emitTick == b.base.emitTick
  of pbDefault:
    true
  of pbReflex:
    a.base.reflexName == b.base.reflexName

proc stepFirstLightDefault*(state: var StandingOrderState,
    body: var SeatBody, tick: uint32) =
  ## Recomputes the default every fallback tick, folds zero overlays, finishes,
  ## and installs only on bytes/provenance/epoch difference. FIRST LIGHT reads
  ## the state's initialized epoch zero and never advances it.
  let facts = brDefaultFacts(body, tick)
  let decision = computeBrDefault(facts)
  state.lastDefaultRule = decision.rule
  let finished = finishDefault(decision.intent, facts.idleAimCenterBrads)
  let bytes = canonicalIntent(finished.intent)
  let effectiveEpoch = state.effectiveEpoch
  let changed = not state.hasStanding or state.intentBytes != bytes or
    not sameProvenance(state.provenance, finished.provenance) or
    state.installedEffectiveEpoch != effectiveEpoch

  if changed:
    setStandingIntent(body, finished.intent, decision.goal, effectiveEpoch)
    state.hasStanding = true
    state.intent = finished.intent
    state.intentBytes = bytes
    state.provenance = finished.provenance
    state.installedEffectiveEpoch = effectiveEpoch
    state.annotations.add(ShellAnnotation(
      tick: tick,
      seat: body.seat,
      kind: akAcceptedIntentChange,
      effectiveEpoch: effectiveEpoch,
      provenance: finished.provenance,
      intentBytes: bytes))
