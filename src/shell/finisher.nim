## The §7.3 finisher and the direct typed Intent canonical writer.

import std/options
import ../ctf/sim_types
import types
import canonical_fast
import policy_encoding

type
  FinishedOrder* = object
    intent*: Intent
    provenance*: Provenance

proc finishDefault*(intent: Intent, idleAimCenterBrads: int): FinishedOrder =
  ## Default is a stable reserved provenance tag. The finisher supplies the
  ## body's idle-aim center only when the source did not already provide it.
  assert idleAimCenterBrads in 0 .. 255
  result.intent = intent
  if result.intent.idleAimCenterBrads.isNone:
    result.intent.idleAimCenterBrads = some(idleAimCenterBrads)
  result.provenance = Provenance(base: ProvenanceBase(kind: pbDefault))

proc wireName(kind: IntentKind): string {.inline.} =
  case kind
  of ikNavigateTo: "navigate_to"
  of ikHold: "hold"

proc wireName(profile: CostProfile): string {.inline.} =
  case profile
  of cpDefault: "default"
  of cpCarrier: "carrier"
  of cpHunter: "hunter"

proc wireName(flag: MicroFlag): string {.inline.} =
  case flag
  of mfPeekDuck: "peek_duck"
  of mfSeparation: "separation"
  of mfFormationBias: "formation_bias"
  of mfStealRushExempt: "steal_rush_exempt"

proc wireName(tag: PreferTag): string {.inline.} =
  case tag
  of ptWeakened: "weakened"
  of ptIsolated: "isolated"
  of ptRevenge: "revenge"
  of ptBounty: "bounty"

proc combatPolicyEmpty(value: CombatPolicy): bool {.inline.} =
  value.noShoot.protectedSetEmpty and value.protect.protectedSetEmpty and
    value.prefer.len == 0 and not value.holdFire

proc writeCombatPolicy(w: var CanonicalWriter, value: CombatPolicy) =
  w.beginObject()
  if value.holdFire:
    w.field("hold_fire", true)
  if not value.noShoot.protectedSetEmpty:
    w.key("no_shoot")
    w.writeProtectedSet(value.noShoot)
  if value.prefer.len > 0:
    w.key("prefer")
    w.beginArray()
    for tag in value.prefer:
      w.addString(tag.wireName)
    w.endArray()
  if not value.protect.protectedSetEmpty:
    w.key("protect")
    w.writeProtectedSet(value.protect)
  w.field("schema", "combat_policy")
  w.field("v", 1'i64)
  w.endObject()

proc writeIntent*(w: var CanonicalWriter, intent: Intent) =
  ## Streams the trusted typed engine object directly in byte-sorted key
  ## order. canonical_fast asserts that ordering and allocates no JsonNode.
  assert intent.arriveRadius >= 0.0
  assert intent.reason.len <= IntentReasonMaxBytes
  assert (intent.kind == ikNavigateTo) == intent.point.isSome
  assert intent.handoff.len == 0 or intent.handoff in HandoffItems
  if intent.idleAimCenterBrads.isSome:
    assert intent.idleAimCenterBrads.get in 0 .. 255

  w.beginObject()
  w.field("arrive_radius", intent.arriveRadius)
  if intent.clampToEndzone:
    w.field("clamp_to_endzone", true)
  if not intent.combat.combatPolicyEmpty:
    w.key("combat")
    w.writeCombatPolicy(intent.combat)
  if intent.handoff.len > 0:
    w.field("handoff", intent.handoff)
  if intent.idleAimCenterBrads.isSome:
    w.field("idle_aim_center_brads", int64(intent.idleAimCenterBrads.get))
  w.field("kind", intent.kind.wireName)
  if intent.micro.card > 0:
    w.key("micro")
    w.beginArray()
    for flag in [mfFormationBias, mfPeekDuck, mfSeparation,
                 mfStealRushExempt]:
      if flag in intent.micro:
        w.addString(flag.wireName)
    w.endArray()
  if intent.movingGoal:
    w.field("moving_goal", true)
  if intent.point.isSome:
    let point = intent.point.get
    w.key("point")
    w.beginArray()
    w.addInt(int64(point.x))
    w.addInt(int64(point.y))
    w.endArray()
  if intent.profile != cpDefault:
    w.field("profile", intent.profile.wireName)
  if intent.reason.len > 0:
    w.field("reason", intent.reason)
  w.field("schema", "intent")
  if intent.suppressFireFreeze:
    w.field("suppress_fire_freeze", true)
  w.field("v", 1'i64)
  w.endObject()

proc canonicalIntent*(intent: Intent): string =
  var writer = initCanonicalWriter(256)
  writer.writeIntent(intent)
  writer.take()
