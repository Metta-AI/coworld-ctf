## The zero-guest §7.4 standing-order path used by the shell.

import std/options
import ../ctf/sim_types
import body, body_map
import types
import default_play
import policy_encoding

export body, default_play, policy_encoding

type
  StandingOrderState* = object
    hasStanding*: bool
    intent*: Intent
    intentBytes*: string
    provenance*: Provenance
    effectiveCallNumber*: uint64
    installedEffectiveCallNumber*: uint64
    lastDefaultRule*: BrDefaultRule
    annotations*: seq[ShellAnnotation]

  BrDefaultFallbacks* = object
    ## Shell fallbacks for facts the body does not expose yet. Self and partner
    ## come from the body's accessors after updateBelief.
    ## Zone timing/rects are public server facts. Cover is selected lazily
    ## through the body-owned cache after higher-priority rules lose.
    currentZone*: MapRect
    nextZone*: MapRect
    ticksToNextShrink*: int
    zonePhase*: int
    zoneDps*: int
    rotateTarget*: Option[BodyPoint]

  ReconstructedStandingOrder* = object
    tick*: uint32
    seat*: uint8
    effectiveCallNumber*: uint64
    provenance*: Provenance
    intentBytes*: string

  ResolvedStandingOrder* = object
    ## Minimal §7.4 handoff from the ladder/reflex/default selection pipeline
    ## into the standing-order installer. Keeping this value type here avoids
    ## importing the runtime-backed ladder into the shell's zero-entry path.
    intent*: Intent
    goal*: Option[ValidatedGoal]
    provenance*: Provenance
    contributingCallNumber*: uint64

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
    threatPositions: threats,
    partner: partnerTelemetry(body),
    rotateTarget: if fallback.rotateTarget.isSome:
      fallback.rotateTarget.get else: fallback.nextZone.center)

proc computeBodyDefault*(body: SeatBody; facts: BrDefaultFacts): DefaultDecision =
  let tick = facts.tick
  computeBrDefault(facts, proc(): Option[ValidatedGoal] =
    body.defaultCoverGoal(tick))

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

proc stepShellDefault*(state: var StandingOrderState,
    body: SeatBody, tick: uint32, fallback: BrDefaultFallbacks) =
  ## Recomputes the default every fallback tick, folds zero overlays, and
  ## installs only on bytes/provenance/call number difference. The shell reads
  ## the state's initialized call number zero (no declaration) and never advances it.
  let facts = brDefaultFacts(body, tick, fallback)
  let decision = body.computeBodyDefault(facts)
  state.lastDefaultRule = decision.rule
  let bytes = canonicalIntent(decision.intent)
  let effectiveCallNumber = state.effectiveCallNumber
  let changed = not state.hasStanding or state.intentBytes != bytes or
    not sameProvenance(state.provenance, decision.provenance) or
    state.installedEffectiveCallNumber != effectiveCallNumber

  if changed:
    setStandingIntent(body, decision.intent, decision.goal, effectiveCallNumber)
    state.hasStanding = true
    state.intent = decision.intent
    state.intentBytes = bytes
    state.provenance = decision.provenance
    state.installedEffectiveCallNumber = effectiveCallNumber
    state.annotations.add(ShellAnnotation(
      tick: tick,
      seat: uint8(body.seatIndex),
      kind: akAcceptedIntentChange,
      effectiveCallNumber: effectiveCallNumber,
      provenance: decision.provenance,
      intentBytes: bytes))

proc installOrder(state: var StandingOrderState; body: SeatBody; tick: uint32;
                  intent: Intent; provenance: Provenance;
                  effectiveCallNumber: uint64; goal: Option[ValidatedGoal]) =
  let bytes = canonicalIntent(intent)
  let changed = not state.hasStanding or state.intentBytes != bytes or
    not sameProvenance(state.provenance, provenance) or
    state.installedEffectiveCallNumber != effectiveCallNumber

  if changed:
    setStandingIntent(body, intent, goal, effectiveCallNumber)
    state.hasStanding = true
    state.intent = intent
    state.intentBytes = bytes
    state.provenance = provenance
    state.installedEffectiveCallNumber = effectiveCallNumber
    state.annotations.add(ShellAnnotation(
      tick: tick,
      seat: uint8(body.seatIndex),
      kind: akAcceptedIntentChange,
      effectiveCallNumber: effectiveCallNumber,
      provenance: provenance,
      intentBytes: bytes))

proc stepResolvedOrder*(state: var StandingOrderState; body: SeatBody;
                        tick: uint32; resolved: ResolvedStandingOrder) =
  ## Installs the full §7.4 resolved standing order. The ladder output has
  ## already selected the base, stepped active guests, removed inactive /
  ## pending / faulted overlays, and folded active policies from scratch.
  ##
  ## Effective call number advances only when a call entry contributes on this
  ## tick. Default-only ticks keep the prior effective call number, preserving
  ## call number zero (no declaration) while the shell or an uninitialized/silent call stands.
  let effectiveCallNumber =
    if resolved.contributingCallNumber != 0:
      resolved.contributingCallNumber
    else:
      state.effectiveCallNumber
  if resolved.contributingCallNumber != 0:
    state.effectiveCallNumber = resolved.contributingCallNumber
  state.installOrder(body, tick, resolved.intent, resolved.provenance,
    effectiveCallNumber, resolved.goal)

proc reconstructStandingOrders*(annotations: openArray[ShellAnnotation]):
    seq[ReconstructedStandingOrder] =
  ## Replay-side helper for the annotation truth model: accepted intent changes
  ## alone reconstruct which standing order stood at each transition. Lifecycle
  ## annotations clear/install outside this accepted-order sequence.
  for annotation in annotations:
    if annotation.kind == akAcceptedIntentChange:
      result.add ReconstructedStandingOrder(tick: annotation.tick,
        seat: annotation.seat,
        effectiveCallNumber: annotation.effectiveCallNumber,
        provenance: annotation.provenance,
        intentBytes: annotation.intentBytes)
