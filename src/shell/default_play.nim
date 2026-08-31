## The engine-native fallback controller (§7.3), initially for Battle Royale.
## It is recomputed every tick that no guest controller has a cached output.

import std/options
import ../ctf/sim_types
import body, body_map
import types

type
  BrDefaultRule* = enum
    brRotate
    brPartnerLeash
    brCoverHold
    brHold

  BrDefaultFacts* = object
    ## Lane C's coherent tick-N adapter value. It is assembled from lane A's
    ## relayed accessors by standing_order.brDefaultFacts; it is not a lane-A
    ## bundle operation or a new frozen seam.
    tick*: uint32
    map*: BodyMap
    selfPos*: BodyPoint
    currentZone*: MapRect
    nextZone*: MapRect
    ticksToNextShrink*: int
    zoneDps*: int
    idleAimCenterBrads*: int
    threatPositions*: seq[BodyPoint]
    partner*: Option[PartnerTelemetry]
    rotateTarget*: BodyPoint
    coverGoal*: Option[ValidatedGoal]

  DefaultDecision* = object
    rule*: BrDefaultRule
    intent*: Intent
    goal*: Option[ValidatedGoal]

const
  ## PROPOSED BR BEHAVIOR — James ratification pending. Keep every tunable
  ## rule and the deterministic tie order in this one block until ratified;
  ## changing one is a gameplay decision, not an implementation cleanup.
  BrRotateLeadTicks* = 120
  BrRotateArriveRadiusPx* = 48.0
  BrCoverArriveRadiusPx* = 24.0
  BrPartnerLeashPx* = 256
  BrPartnerArriveRadiusPx* = 64.0
  BrRulePriority* = [brRotate, brPartnerLeash, brCoverHold, brHold]

proc toBodyPoint*(point: MapPoint): BodyPoint {.inline.} =
  (point.x, point.y)

proc toMapPoint*(point: BodyPoint): MapPoint {.inline.} =
  MapPoint(x: point.x, y: point.y)

proc navigate(goal: ValidatedGoal, arriveRadius: float, reason: string,
              movingGoal = false): DefaultDecision =
  result.intent = Intent(
    kind: ikNavigateTo,
    point: some(goal.goalPoint.toMapPoint),
    arriveRadius: arriveRadius,
    movingGoal: movingGoal,
    reason: reason)
  result.goal = some(goal)

proc partnerOutsideLeash(facts: BrDefaultFacts): bool =
  if facts.partner.isNone or not facts.partner.get.alive:
    return false
  let partner = facts.partner.get
  let dx = int64(partner.pos.x) - int64(facts.selfPos.x)
  let dy = int64(partner.pos.y) - int64(facts.selfPos.y)
  let leash = int64(BrPartnerLeashPx)
  dx * dx + dy * dy > leash * leash

proc validatedTarget(facts: BrDefaultFacts, target: BodyPoint): Option[ValidatedGoal] =
  facts.map.validateGoal(target, facts.selfPos)

proc computeBrDefault*(facts: BrDefaultFacts): DefaultDecision =
  ## Implements the single proposed priority block above. Raw rotate/partner
  ## targets are converted to lane-A ValidatedGoal proofs here; a missing or
  ## invalid proof makes that rule ineligible and falls through instead of
  ## installing a raw point.
  for rule in BrRulePriority:
    case rule
    of brRotate:
      if facts.ticksToNextShrink <= BrRotateLeadTicks:
        let rotateGoal = facts.validatedTarget(facts.rotateTarget)
        if rotateGoal.isSome:
          result = navigate(rotateGoal.get, BrRotateArriveRadiusPx,
            "default:rotate")
          result.rule = rule
          return
    of brPartnerLeash:
      if facts.partnerOutsideLeash:
        let partnerGoal = facts.validatedTarget(facts.partner.get.pos)
        if partnerGoal.isSome:
          result = navigate(partnerGoal.get, BrPartnerArriveRadiusPx,
            "default:partner", movingGoal = true)
          result.rule = rule
          return
    of brCoverHold:
      if facts.threatPositions.len > 0 and facts.coverGoal.isSome:
        result = navigate(facts.coverGoal.get, BrCoverArriveRadiusPx,
          "default:cover")
        result.rule = rule
        return
    of brHold:
      result = DefaultDecision(
        rule: rule,
        intent: Intent(kind: ikHold, arriveRadius: 0.0,
          reason: "default:hold"),
        goal: none(ValidatedGoal))
      return
