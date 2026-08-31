## The zero-guest §7.4 standing-order path used by FIRST LIGHT.

import std/options
import ../ctf/sim_types
import body, body_map
import types
import default_play
import finisher

export body, default_play, finisher

type
  StandingOrderState* = object
    hasStanding*: bool
    intent*: Intent
    intentBytes*: string
    provenance*: Provenance
    effectiveEpoch*: uint64
    installedEffectiveEpoch*: uint64
    lastDefaultRule*: BrDefaultRule
    annotations*: seq[ShellAnnotation]

  BrDefaultFallbacks* = object
    ## Lane-C first-light fallbacks for facts lane A FL-B does not expose yet.
    ## Self and partner come from lane A's body accessors after updateBelief.
    ## Zone timing/rects are public server facts, and nearest-cover scoring is
    ## represented by an already validated goal until lane A relays that scorer.
    currentZone*: MapRect
    nextZone*: MapRect
    ticksToNextShrink*: int
    zoneDps*: int
    idleAimCenterBrads*: int
    rotateTarget*: Option[BodyPoint]
    coverGoal*: Option[ValidatedGoal]

  ReconstructedStandingOrder* = object
    tick*: uint32
    seat*: uint8
    effectiveEpoch*: uint64
    provenance*: Provenance
    intentBytes*: string

  ResolvedStandingOrder* = object
    ## Minimal §7.4 handoff from the ladder/reflex/default selection pipeline
    ## into the standing-order installer. Keeping this value type here avoids
    ## importing the runtime-backed ladder into FIRST LIGHT's zero-entry path.
    intent*: Intent
    goal*: Option[ValidatedGoal]
    provenance*: Provenance
    contributingEpoch*: uint64

proc center(rect: MapRect): BodyPoint =
  (rect.x + rect.w div 2, rect.y + rect.h div 2)

proc brDefaultFacts*(body: SeatBody, tick: uint32,
    fallback: BrDefaultFallbacks): BrDefaultFacts =
  ## Lane-C adapter over lane A's current read surface. The body state,
  ## fog-filtered tracks, and partner grant are real FL-B accessors. The
  ## fallback argument is explicitly limited to facts not yet exposed by lane A.
  var threats: seq[BodyPoint]
  for track in body.tracks:
    if track.isSome and track.get.freshTick == tick:
      threats.add(track.get.pos)
  BrDefaultFacts(
    tick: tick,
    map: body.map,
    selfPos: body.selfState.pos,
    currentZone: fallback.currentZone,
    nextZone: fallback.nextZone,
    ticksToNextShrink: fallback.ticksToNextShrink,
    zoneDps: fallback.zoneDps,
    idleAimCenterBrads: fallback.idleAimCenterBrads,
    threatPositions: threats,
    partner: partnerTelemetry(body),
    rotateTarget: if fallback.rotateTarget.isSome:
      fallback.rotateTarget.get else: fallback.nextZone.center,
    coverGoal: fallback.coverGoal)

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
    body: SeatBody, tick: uint32, fallback: BrDefaultFallbacks) =
  ## Recomputes the default every fallback tick, folds zero overlays, finishes,
  ## and installs only on bytes/provenance/epoch difference. FIRST LIGHT reads
  ## the state's initialized epoch zero and never advances it.
  let facts = brDefaultFacts(body, tick, fallback)
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
      seat: uint8(body.seatIndex),
      kind: akAcceptedIntentChange,
      effectiveEpoch: effectiveEpoch,
      provenance: finished.provenance,
      intentBytes: bytes))

proc installFinishedOrder(state: var StandingOrderState; body: SeatBody;
                          tick: uint32; finished: FinishedOrder;
                          effectiveEpoch: uint64;
                          goal: Option[ValidatedGoal]) =
  let bytes = canonicalIntent(finished.intent)
  let changed = not state.hasStanding or state.intentBytes != bytes or
    not sameProvenance(state.provenance, finished.provenance) or
    state.installedEffectiveEpoch != effectiveEpoch

  if changed:
    setStandingIntent(body, finished.intent, goal, effectiveEpoch)
    state.hasStanding = true
    state.intent = finished.intent
    state.intentBytes = bytes
    state.provenance = finished.provenance
    state.installedEffectiveEpoch = effectiveEpoch
    state.annotations.add(ShellAnnotation(
      tick: tick,
      seat: uint8(body.seatIndex),
      kind: akAcceptedIntentChange,
      effectiveEpoch: effectiveEpoch,
      provenance: finished.provenance,
      intentBytes: bytes))

proc finishResolvedOrder(intent: Intent; provenance: Provenance;
                         idleAimCenterBrads: int): FinishedOrder =
  ## Applies the same native final shaping as the zero-guest default path after
  ## the full §7.4 fold has already selected a base and merged active overlays.
  assert idleAimCenterBrads in 0 .. 255
  result.intent = intent
  if result.intent.idleAimCenterBrads.isNone:
    result.intent.idleAimCenterBrads = some(idleAimCenterBrads)
  result.provenance = provenance

proc stepResolvedOrder*(state: var StandingOrderState; body: SeatBody;
                        tick: uint32; resolved: ResolvedStandingOrder;
                        idleAimCenterBrads: int) =
  ## Installs the full §7.4 resolved standing order. The ladder output has
  ## already selected the base, stepped active guests, removed inactive /
  ## pending / faulted overlays, and folded active policies from scratch.
  ##
  ## Effective order epoch advances only when a call entry contributes on this
  ## tick. Default-only ticks keep the prior effective epoch, preserving epoch
  ## zero while FIRST LIGHT or an uninitialized/silent call is standing.
  let effectiveEpoch =
    if resolved.contributingEpoch != 0:
      resolved.contributingEpoch
    else:
      state.effectiveEpoch
  if resolved.contributingEpoch != 0:
    state.effectiveEpoch = resolved.contributingEpoch
  let finished = finishResolvedOrder(resolved.intent, resolved.provenance,
    idleAimCenterBrads)
  state.installFinishedOrder(body, tick, finished, effectiveEpoch,
    resolved.goal)

proc reconstructStandingOrders*(annotations: openArray[ShellAnnotation]):
    seq[ReconstructedStandingOrder] =
  ## Replay-side helper for the annotation truth model: accepted intent changes
  ## alone reconstruct which standing order stood at each transition. Lifecycle
  ## annotations clear/install outside this accepted-order sequence.
  for annotation in annotations:
    if annotation.kind == akAcceptedIntentChange:
      result.add ReconstructedStandingOrder(tick: annotation.tick,
        seat: annotation.seat,
        effectiveEpoch: annotation.effectiveEpoch,
        provenance: annotation.provenance,
        intentBytes: annotation.intentBytes)
