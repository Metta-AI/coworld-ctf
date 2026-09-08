## Shared canonical encoding for typed Intent and CombatPolicy.

import std/[algorithm, options, strutils]

import ../ctf/sim_types
import canonical_fast, types

proc protectedSetEmpty*(value: ProtectedSet): bool {.inline.} =
  value.teams.card == 0 and value.seats.len == 0

proc writeProtectedSet*(w: var CanonicalWriter, value: ProtectedSet) =
  ## Writes the engine-side canonical protected set: resolved plain seat
  ## spellings and team spellings, both sorted and deduplicated by wire text.
  w.beginObject()
  if value.seats.len > 0:
    var seats = newSeqOfCap[string](value.seats.len)
    for seat in value.seats:
      seats.add($seat)
    seats.sort()
    w.key("seats")
    w.beginArray()
    for index, seat in seats:
      if index == 0 or seat != seats[index - 1]:
        w.addString(seat)
    w.endArray()
  if value.teams.card > 0:
    var teams = newSeqOfCap[string](value.teams.card)
    for team in value.teams:
      teams.add(($team).toLowerAscii)
    teams.sort()
    w.key("teams")
    w.beginArray()
    for team in teams:
      w.addString(team)
    w.endArray()
  w.endObject()

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
  assert intent.idleAimCenterBrads in 0 .. 255

  w.beginObject()
  w.field("arrive_radius", intent.arriveRadius)
  if intent.clampToEndzone:
    w.field("clamp_to_endzone", true)
  if not intent.combat.combatPolicyEmpty:
    w.key("combat")
    w.writeCombatPolicy(intent.combat)
  # GVNEXT(drop): "drop" sorts between "combat" and "handoff" — canonical
  # (alphabetical) key order is asserted by canonical_fast, so placement here
  # is load-bearing, not cosmetic. Omitted when false, like every other
  # default-valued field, so an unchanged page round-trips byte-identically.
  if intent.drop:
    w.field("drop", true)
  if intent.handoff.len > 0:
    w.field("handoff", intent.handoff)
  # Every standing order encoded before this refactor already
  # carried this key; replay annotation goldens pin its presence and ordering.
  w.field("idle_aim_center_brads", int64(intent.idleAimCenterBrads))
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
