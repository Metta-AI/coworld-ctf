## Per-seat body state at the contracted server/body seam.
##
## RATIFIED 2026-08-31 (both lanes, via the PM): the full-belief seam extends
## `BodyTickInputs`
## with server-fogged item sightings, event ids for kills/aggressors/shouts/
## hazards, track veteran markers, optional track aim, and CTF lives on self.
## Event-like rows keep the stable `eventId` supplied at the seam. Item
## sightings deliberately derive identity from `(kind, NavCell cell)` instead:
## items do not move and two items of the same kind cannot occupy one cell at
## once, so this identifies "the known item at this cell" across re-sightings,
## including a later respawn in the same cell. No counter, clock, or address
## identity participates in belief ids.

import std/[algorithm, hashes, math, options]
import bitworld/spriteprotocol
import ../ctf/sim_types
import body_cache, body_map, body_nav, body_planner
import types as shellTypes

const
  IdleAimDeadband = AimTurnRate div 2
  ItemMemoryCap = 32
  AggressorWindowTicks = 120'u32
  KillFeedWindowTicks = 240'u32
  # PORTED from the pinned lab — parity-bound, do NOT tune. Changing one of
  # these changes the gate-1 differential, not just behaviour.
  FirefightTargetMinDwellTicks* = 8     ## LAB config.nim:164-165
  FirefightTargetSwitchMargin* = 0.10   ## LAB config.nim:166-167
  FirefightShootabilityWeight* = 0.35   ## LAB config.nim:179-180
  # SHELL INVENTIONS — wards are a §4.2 shell concept with no stencil
  # counterpart, so these are chosen, not ported, and are legitimately
  # tunable. WardThreatScoreBoost sits deliberately above the shootability
  # weight so a ward's attacker outranks a merely-shootable target; that
  # ratio is a design judgement, not a measurement.
  WardAimToleranceBrads* = 8
  WardThreatScoreBoost* = 0.65

type
  BodyWeapon* = enum
    ## Weapon vocabulary mirrored from the sim's player/view contract:
    ## `"gun" | "spray" | "grenade"` (`src/ctf/sim_types.nim:2210-2226`).
    bwGun
    bwSpray
    bwGrenade

  BodyItemKind* = enum
    bikGrenade
    bikMedkit
    bikShield
    bikSpray
    bikBarrier

  BodySelfState* = object
    pos*: BodyPoint
    hp*: int
    hpFrac*: float
    lives*: Option[int]
    aimBrads*: int
    fireCooldown*: int     ## Self `Player.fireCooldown` (`sim_types.nim:2210-2226`).
    fireWindup*: int       ## Self `Player.fireWindup` (`sim_types.nim:2210-2226`).
    windup*: Option[int]
      ## Aim angle locked at the trigger pull (`sim_types.nim:2210-2226`);
      ## `none` when no trigger is pulled. Deliberately not the sim's `-1`
      ## sentinel: 0 is a valid bearing, so an unset sentinel that
      ## zero-initialises would be indistinguishable from aiming at bearing 0.
      ## Lane C converts the sim's `-1` at the boundary.
    hasGrenade*: bool      ## Self grenade inventory (`sim_types.nim:2210-2226`).
    hasShield*: bool       ## Self shield inventory (`sim_types.nim:2210-2226`).
    shieldHp*: int         ## Self shield-layer hp (`sim_types.nim:2210-2226`).
    hasSprayPaint*: bool   ## Self spray-can inventory (`sim_types.nim:2210-2226`).
    arcTicksLeft*: int     ## Self active spray-cone ticks (`sim_types.nim:2210-2226`).
    alive*: bool
    carrying*: bool

  BodyTrack* = object
    pos*: BodyPoint
    team*: Team
    aimBrads*: Option[int]
    hpKnown*: Option[int]
    shielded*: bool
      ## Fog-visible shield carried by target, not shield hp
      ## (`src/ctf/sim_types.nim:2210-2226`).
    weapon*: Option[BodyWeapon]
      ## Weapon mirrored from the sim's player/view contract
      ## (`src/ctf/sim_types.nim:2210-2226`). Option because an enemy's
      ## weapon is not always readable through fog.
      ## Unknown must stay representable: it scores 0 for the spray term rather
      ## than defaulting to `bwGun`, matching unknown hp and optional aim.
    veteranMarker*: bool
    freshTick*: uint32

  BodyTrackUpdate* = object
    seat*: int
    pos*: BodyPoint
    team*: Team
    aimBrads*: Option[int]
    hpKnown*: Option[int]
    shielded*: bool
      ## Fog-visible shield carried by target, not shield hp
      ## (`src/ctf/sim_types.nim:2210-2226`).
    weapon*: Option[BodyWeapon]
      ## Weapon mirrored from the sim's player/view contract
      ## (`src/ctf/sim_types.nim:2210-2226`). Option because an enemy's
      ## weapon is not always readable through fog.
      ## Unknown must stay representable: it scores 0 for the spray term rather
      ## than defaulting to `bwGun`, matching unknown hp and optional aim.
    veteranMarker*: bool
    tick*: uint32

  ItemSighting* = object
    kind*: BodyItemKind
    pos*: BodyPoint
    present*: bool
    tick*: uint32

  BodyItemMemory* = object
    eventId*: uint64
    kind*: BodyItemKind
    pos*: BodyPoint
    present*: bool
    freshTick*: uint32

  KillEvent* = object
    eventId*: uint64
    tick*: uint32
    killerTeam*: Team
    victimSeat*: int

  AggressorEvent* = object
    eventId*: uint64
    tick*: uint32
    dirBrads*: int
    seat*: Option[int]

  ShoutEvent* = object
    eventId*: uint64
    team*: Team
    slotLetter*: string
    text*: string
    pos*: BodyPoint
    tick*: uint32

  BodyGrenadeHazard* = object
    eventId*: uint64
    coversSelf*: bool
    pos*: BodyPoint
    predictedBlastPos*: BodyPoint
    ticksToBlast*: int

  BodyBlastCue* = object
    eventId*: uint64
    coversSelf*: bool
    pos*: BodyPoint
    tick*: uint32

  BodyOwnThrow* = object
    eventId*: uint64
    target*: BodyPoint
    releaseTick*: uint32
    blastRadius*: int

  BodySprayHazardKind* = enum
    bshVisibleCone
    bshAnonymousImpact

  BodySprayHazard* = object
    eventId*: uint64
    coversSelf*: bool
    tick*: uint32
    case kind*: BodySprayHazardKind
    of bshVisibleCone:
      attackerSeat*: int
      origin*: BodyPoint
      aimBrads*: int
      reachPx*: int
      maxWidthPx*: int
    of bshAnonymousImpact:
      impactPos*: BodyPoint
      incomingDirBrads*: int

  HazardInputs* = object
    grenades*: seq[BodyGrenadeHazard]
    blastCues*: seq[BodyBlastCue]
    ownThrow*: Option[BodyOwnThrow]
    sprays*: seq[BodySprayHazard]

  PartnerSample* = object
    seat*: uint8
    pos*: BodyPoint
    aimBrads*: int
    alive*: bool

  PartnerTelemetry* = tuple[
    seat: uint8, pos: BodyPoint, aimBrads: int, alive: bool]

  BodyTickInputs* = object
    ## Contracted trust boundary. The server supplies only this seat's
    ## fog-filtered facts and the explicit duo telemetry grant. The body never
    ## receives raw sim state. The phase-4 combat selector owns noShoot/protect
    ## filtering before a track can become a vetted weapon target.
    self*: BodySelfState
    visibleTracks*: seq[BodyTrackUpdate]
    partner*: Option[PartnerSample]
    sightedItems*: seq[ItemSighting]
    killFeed*: seq[KillEvent]
    aggressorEvents*: seq[AggressorEvent]
    shouts*: seq[ShoutEvent]
    hazards*: HazardInputs

  TrackPredicate* = proc(track: BodyTrack): bool {.closure.}

  PreferenceScores* = object
    weakened*, isolated*, revenge*, bounty*: float

  CombatCandidateInput* = object
    ## Phase-4 target-acquisition input from the future weapon geometry pass.
    ## `baseScore` is the already-computed Stencil-like score term for facts
    ## this phase does not yet own (aim cost, corridor clearance, weapon/item
    ## state). This selector owns policy filtering, preference order,
    ## ward-threat bias, and target stickiness.
    seat*: int
    shootable*: bool
    baseScore*: float
    identity*: Option[int]

  CombatTarget* = object
    ## Vetted target. Construction is private to this module: weapon actuation
    ## in phase 5 must receive one of these from `selectCombatTarget` or a
    ## re-validation proc, so a noShoot endpoint is not a normal representable
    ## firing decision.
    seat: int
    team: Team
    pos: BodyPoint
    identity: Option[int]

  CombatDecision* = object
    target: CombatTarget
    score: float
    selectedTick: uint32
    shootable: bool

  ScoredCombatCandidate = object
    target: CombatTarget
    preference: seq[float]
    score: float
    selectedTick: uint32
    shootable: bool

  SeatBody* = ref object
    map*: BodyMap
    seatIndex*: int
    nav*: BodyNavSystem
    selfState*: BodySelfState
    tracks*: array[MaxPlayers, Option[BodyTrack]]
    items*: seq[BodyItemMemory]
    killFeed*: seq[KillEvent]
    aggressorEvents*: seq[AggressorEvent]
    shouts*: seq[ShoutEvent]
    hazards*: HazardInputs
    standingIntent*: shellTypes.Intent
    effectiveEpoch*: uint64
    standingGoal*: Option[ValidatedGoal]
    partnerGrant: Option[PartnerTelemetry]
    heldCombatTarget: Option[CombatTarget]
    heldCombatSelectedTick: uint32

proc tickInsideWindow(eventTick, now, window: uint32): bool =
  eventTick <= now and uint64(now - eventTick) < uint64(window)

proc itemEventId*(kind: BodyItemKind, cell: BodyPoint): uint64 =
  (uint64(ord(kind)) shl 56) or
    (uint64(cast[uint32](int32(cell.x))) shl 28) or
    uint64(cast[uint32](int32(cell.y)) and 0x0fff_ffff'u32)

proc itemEventIdForPoint*(map: BodyMap, kind: BodyItemKind,
                          point: BodyPoint): uint64 =
  itemEventId(kind, map.cellOf(point))

proc validateTick(observed, now: uint32, label: string) =
  if observed > now:
    raise newException(ValueError, label & " is from a future tick")

proc validateSeat(seat: int, label: string) =
  if seat < 0 or seat >= MaxPlayers:
    raise newException(ValueError, label & " seat is out of range")

proc validateAim(aimBrads: Option[int], label: string) =
  if aimBrads.isSome and aimBrads.get notin 0 .. 255:
    raise newException(ValueError, label & " aim_brads is out of range")

proc distanceSquared(a, b: BodyPoint): int64 =
  let
    dx = int64(a.x - b.x)
    dy = int64(a.y - b.y)
  dx * dx + dy * dy

proc sortItemsForRetention(items: var seq[BodyItemMemory], selfPos: BodyPoint) =
  items.sort(proc(a, b: BodyItemMemory): int =
    result = cmp(b.freshTick, a.freshTick)
    if result == 0:
      result = cmp(distanceSquared(selfPos, a.pos),
        distanceSquared(selfPos, b.pos))
    if result == 0: result = cmp(ord(a.kind), ord(b.kind))
    if result == 0: result = cmp(a.eventId, b.eventId))

proc upsertItem(body: SeatBody, sighting: ItemSighting) =
  let id = body.map.itemEventIdForPoint(sighting.kind, sighting.pos)
  for item in body.items.mitems:
    if item.eventId == id:
      item = BodyItemMemory(eventId: id, kind: sighting.kind,
        pos: sighting.pos, present: sighting.present,
        freshTick: sighting.tick)
      return
  body.items.add(BodyItemMemory(eventId: id, kind: sighting.kind,
    pos: sighting.pos, present: sighting.present, freshTick: sighting.tick))

proc upsertKill(target: var seq[KillEvent], event: KillEvent) =
  for row in target.mitems:
    if row.eventId == event.eventId:
      row = event
      return
  target.add(event)

proc upsertAggressor(target: var seq[AggressorEvent], event: AggressorEvent) =
  for row in target.mitems:
    if row.eventId == event.eventId:
      row = event
      return
  target.add(event)

proc normalizeKillFeed(rows: var seq[KillEvent], tick: uint32) =
  var kept: seq[KillEvent]
  for row in rows:
    if tickInsideWindow(row.tick, tick, KillFeedWindowTicks):
      kept.add(row)
  kept.sort(proc(a, b: KillEvent): int =
    result = cmp(b.tick, a.tick)
    if result == 0: result = cmp(a.eventId, b.eventId))
  rows = kept

proc normalizeAggressors(rows: var seq[AggressorEvent], tick: uint32) =
  var kept: seq[AggressorEvent]
  for row in rows:
    if tickInsideWindow(row.tick, tick, AggressorWindowTicks):
      kept.add(row)
  kept.sort(proc(a, b: AggressorEvent): int =
    result = cmp(b.tick, a.tick)
    if result == 0: result = cmp(a.eventId, b.eventId))
  rows = kept

proc normalizeShouts(rows: var seq[ShoutEvent], selfPos: BodyPoint) =
  rows.sort(proc(a, b: ShoutEvent): int =
    result = cmp(b.tick, a.tick)
    if result == 0:
      result = cmp(distanceSquared(selfPos, a.pos),
        distanceSquared(selfPos, b.pos))
    if result == 0: result = cmp(ord(a.team), ord(b.team))
    if result == 0: result = cmp(a.slotLetter, b.slotLetter)
    if result == 0: result = cmp(a.eventId, b.eventId))

proc normalizeHazards(hazards: var HazardInputs, selfPos: BodyPoint) =
  hazards.grenades.sort(proc(a, b: BodyGrenadeHazard): int =
    result = cmp(b.coversSelf, a.coversSelf)
    if result == 0: result = cmp(a.ticksToBlast, b.ticksToBlast)
    if result == 0:
      result = cmp(distanceSquared(selfPos, a.predictedBlastPos),
        distanceSquared(selfPos, b.predictedBlastPos))
    if result == 0: result = cmp(a.eventId, b.eventId))
  hazards.blastCues.sort(proc(a, b: BodyBlastCue): int =
    result = cmp(b.coversSelf, a.coversSelf)
    if result == 0: result = cmp(b.tick, a.tick)
    if result == 0:
      result = cmp(distanceSquared(selfPos, a.pos),
        distanceSquared(selfPos, b.pos))
    if result == 0: result = cmp(a.eventId, b.eventId))
  proc anchor(spray: BodySprayHazard): BodyPoint =
    case spray.kind
    of bshVisibleCone: spray.origin
    of bshAnonymousImpact: spray.impactPos
  hazards.sprays.sort(proc(a, b: BodySprayHazard): int =
    result = cmp(b.coversSelf, a.coversSelf)
    if result == 0: result = cmp(b.tick, a.tick)
    if result == 0:
      result = cmp(distanceSquared(selfPos, a.anchor),
        distanceSquared(selfPos, b.anchor))
    if result == 0: result = cmp(a.eventId, b.eventId))

proc safeIntent(): shellTypes.Intent =
  shellTypes.Intent(kind: shellTypes.ikHold,
    point: none(MapPoint), profile: shellTypes.cpDefault,
    combat: shellTypes.CombatPolicy())

proc activateSeatBody*(nav: BodyNavSystem, seatIndex: int): SeatBody =
  ## Activation barrier for production seats. The server owns one shared
  ## BodyNavSystem per episode, so danger rebuild staggering and cold-planning
  ## budgets remain server-wide under rulings 5 and 6.
  doAssert nav != nil, "body navigation system is nil"
  doAssert seatIndex >= 0 and seatIndex < nav.seatCount,
    "body seat index is out of range for navigation system"
  doAssert seatIndex < MaxPlayers, "body seat index is out of range"
  new(result)
  result.map = nav.map
  result.seatIndex = seatIndex
  result.nav = nav
  result.standingIntent = safeIntent()
  result.effectiveEpoch = 0
  result.standingGoal = none(ValidatedGoal)

proc activateSeatBody*(map: BodyMap, seatIndex: int,
                       liveGunRangePx: int): SeatBody =
  ## Testing/solo convenience. Production activation must pass the shared
  ## episode BodyNavSystem above; private systems do not preserve rulings 5/6
  ## across a roster. This overload allocates enough local seats for the
  ## selected roster index and delegates to the shared-system spelling.
  if seatIndex < 0 or seatIndex >= MaxPlayers:
    raise newException(ValueError, "body seat index is out of range")
  activateSeatBody(newBodyNavSystem(map, seatIndex + 1, liveGunRangePx),
    seatIndex)

proc setStandingIntent*(body: SeatBody, intent: shellTypes.Intent,
                        goal: Option[ValidatedGoal],
                        effectiveEpoch: uint64) =
  case intent.kind
  of shellTypes.ikNavigateTo:
    if goal.isNone:
      raise newException(ValueError,
        "NavigateTo standing intent requires a ValidatedGoal")
    if not goal.get.belongsTo(body.map):
      raise newException(ValueError,
        "standing intent goal belongs to another body map")
  of shellTypes.ikHold:
    if goal.isSome:
      raise newException(ValueError,
        "Hold standing intent must not carry a ValidatedGoal")

  let seat = body.nav.seats[body.seatIndex]
  if seat.job.planPending:
    seat.cache.cancelPlan(seat.job)
  body.standingIntent = intent
  body.effectiveEpoch = effectiveEpoch
  body.standingGoal = goal
  if goal.isSome:
    seat.cache.pinStandingGoal(goal.get.goalPoint)
  else:
    seat.cache.clearStandingGoalPin()

proc updateBelief*(body: SeatBody, inputs: BodyTickInputs, tick: uint32) =
  body.selfState = inputs.self

  # One update per seat is the server-side seam contract. Staging in a fixed
  # table makes application order independent without a per-tick allocation.
  var updates: array[MaxPlayers, Option[BodyTrackUpdate]]
  for update in inputs.visibleTracks:
    if update.seat < 0 or update.seat >= MaxPlayers:
      raise newException(ValueError, "track update seat is out of range")
    if updates[update.seat].isSome:
      raise newException(ValueError,
        "duplicate track update for seat " & $update.seat)
    if update.tick > tick:
      raise newException(ValueError, "track update is from a future tick")
    validateAim(update.aimBrads, "track update")
    updates[update.seat] = some(update)
  for seat in 0 ..< MaxPlayers:
    if updates[seat].isSome:
      let update = updates[seat].get
      body.tracks[seat] = some(BodyTrack(pos: update.pos,
        team: update.team, aimBrads: update.aimBrads,
        hpKnown: update.hpKnown, shielded: update.shielded,
        weapon: update.weapon, veteranMarker: update.veteranMarker,
        freshTick: update.tick))

  for sighting in inputs.sightedItems:
    validateTick(sighting.tick, tick, "item sighting")
    body.upsertItem(sighting)
  body.items.sortItemsForRetention(body.selfState.pos)
  if body.items.len > ItemMemoryCap:
    body.items.setLen(ItemMemoryCap)

  for event in inputs.killFeed:
    validateTick(event.tick, tick, "kill feed event")
    validateSeat(event.victimSeat, "kill feed victim")
    body.killFeed.upsertKill(event)
  body.killFeed.normalizeKillFeed(tick)

  for event in inputs.aggressorEvents:
    validateTick(event.tick, tick, "aggressor event")
    validateAim(some(event.dirBrads), "aggressor event")
    if event.seat.isSome:
      validateSeat(event.seat.get, "aggressor")
    body.aggressorEvents.upsertAggressor(event)
  body.aggressorEvents.normalizeAggressors(tick)

  var shouts: seq[ShoutEvent]
  for event in inputs.shouts:
    validateTick(event.tick, tick, "shout event")
    if event.text.len > 10:
      raise newException(ValueError, "shout text exceeds maxLength 10")
    let key = (team: event.team, slotLetter: event.slotLetter)
    for existing in shouts:
      if existing.team == key.team and existing.slotLetter == key.slotLetter:
        raise newException(ValueError, "duplicate shout for live shouter")
    shouts.add(event)
  body.shouts = shouts
  body.shouts.normalizeShouts(body.selfState.pos)

  var hazards = inputs.hazards
  for hazard in hazards.grenades:
    if hazard.ticksToBlast < 0:
      raise newException(ValueError, "grenade hazard blast tick is negative")
  for hazard in hazards.blastCues:
    validateTick(hazard.tick, tick, "blast cue")
  for hazard in hazards.sprays:
    validateTick(hazard.tick, tick, "spray hazard")
    case hazard.kind
    of bshVisibleCone:
      validateSeat(hazard.attackerSeat, "spray attacker")
      validateAim(some(hazard.aimBrads), "spray hazard")
    of bshAnonymousImpact:
      validateAim(some(hazard.incomingDirBrads), "spray hazard")
  hazards.normalizeHazards(body.selfState.pos)
  body.hazards = hazards

  body.partnerGrant = none(PartnerTelemetry)
  if inputs.partner.isSome:
    let partner = inputs.partner.get
    if partner.seat.int < 0 or partner.seat.int >= MaxPlayers:
      raise newException(ValueError, "partner seat is out of range")
    if inputs.self.alive and partner.alive:
      body.partnerGrant = some((seat: partner.seat, pos: partner.pos,
        aimBrads: partner.aimBrads, alive: true))

proc partnerTelemetry*(body: SeatBody): Option[PartnerTelemetry] =
  ## Sim-truth position and aim grant for a live duo partner. HP deliberately
  ## remains available only through ordinary fogged tracks. updateBelief
  ## clears the grant on absence or death, exactly at that input tick.
  body.partnerGrant

proc preferenceScores*(body: SeatBody, targetSeat: int, tick: uint32,
                       liveWeaponRangePx, targetMaxHp: int): PreferenceScores =
  validateSeat(targetSeat, "preference target")
  if liveWeaponRangePx <= 0:
    raise newException(ValueError, "live weapon range must be positive")
  if targetMaxHp <= 0:
    raise newException(ValueError, "target max hp must be positive")
  if body.tracks[targetSeat].isNone:
    return
  let target = body.tracks[targetSeat].get
  if target.hpKnown.isSome:
    result.weakened = max(0.0,
      1.0 - min(1.0, target.hpKnown.get.float / targetMaxHp.float))
  var nearestAlly = int64.high
  for seat in 0 ..< MaxPlayers:
    if seat == targetSeat or body.tracks[seat].isNone:
      continue
    let ally = body.tracks[seat].get
    if ally.team == target.team:
      nearestAlly = min(nearestAlly, distanceSquared(target.pos, ally.pos))
  if nearestAlly == int64.high:
    result.isolated = 1.0
  else:
    result.isolated = min(1.0,
      sqrt(nearestAlly.float) / liveWeaponRangePx.float)
  for event in body.aggressorEvents:
    if tickInsideWindow(event.tick, tick, AggressorWindowTicks) and
        event.seat == some(targetSeat):
      result.revenge = 1.0
      break
  if target.freshTick == tick and target.veteranMarker:
    result.bounty = 1.0

proc preferenceScoreTuple*(body: SeatBody, targetSeat: int,
                           tags: openArray[shellTypes.PreferTag],
                           tick: uint32, liveWeaponRangePx,
                           targetMaxHp: int): seq[float] =
  let scores = body.preferenceScores(targetSeat, tick, liveWeaponRangePx,
    targetMaxHp)
  for tag in tags:
    case tag
    of shellTypes.ptWeakened: result.add(scores.weakened)
    of shellTypes.ptIsolated: result.add(scores.isolated)
    of shellTypes.ptRevenge: result.add(scores.revenge)
    of shellTypes.ptBounty: result.add(scores.bounty)

proc compareByPreference*(body: SeatBody, leftSeat, rightSeat: int,
                          tags: openArray[shellTypes.PreferTag],
                          tick: uint32, liveWeaponRangePx,
                          targetMaxHp: int): int =
  let
    left = body.preferenceScoreTuple(leftSeat, tags, tick,
      liveWeaponRangePx, targetMaxHp)
    right = body.preferenceScoreTuple(rightSeat, tags, tick,
      liveWeaponRangePx, targetMaxHp)
  for index in 0 ..< min(left.len, right.len):
    if left[index] > right[index]: return -1
    if left[index] < right[index]: return 1
  cmp(leftSeat, rightSeat)

proc seatIndex(seatRef: shellTypes.SeatRef): int {.inline.} =
  int(uint8(seatRef))

proc containsSeat(set: shellTypes.ProtectedSet, seat: int): bool =
  for seatRef in set.seats:
    if seatRef.seatIndex == seat:
      return true
  false

proc containsTrack(set: shellTypes.ProtectedSet, seat: int,
                   team: Team): bool =
  team in set.teams or set.containsSeat(seat)

proc noShootTarget*(policy: shellTypes.CombatPolicy, seat: int,
                    team: Team): bool =
  validateSeat(seat, "combat target")
  policy.noShoot.containsTrack(seat, team)

proc protectedPolicyTarget*(policy: shellTypes.CombatPolicy, seat: int,
                            team: Team): bool =
  ## Wards are not threat targets. `noShoot` also joins the protected set for
  ## every later weapon path (§4.2), so both sets are excluded here.
  validateSeat(seat, "combat target")
  policy.noShoot.containsTrack(seat, team) or
    policy.protect.containsTrack(seat, team)

proc combatSeat*(target: CombatTarget): int {.inline.} = target.seat
proc combatTeam*(target: CombatTarget): Team {.inline.} = target.team
proc combatPos*(target: CombatTarget): BodyPoint {.inline.} = target.pos
proc combatIdentity*(target: CombatTarget): Option[int] {.inline.} =
  target.identity
proc combatTarget*(decision: CombatDecision): CombatTarget {.inline.} =
  decision.target
proc combatScore*(decision: CombatDecision): float {.inline.} = decision.score
proc combatSelectedTick*(decision: CombatDecision): uint32 {.inline.} =
  decision.selectedTick
proc combatShootable*(decision: CombatDecision): bool {.inline.} =
  decision.shootable

proc sameTarget(a, b: CombatTarget): bool =
  ## Body tracks are keyed by server seat. Optional identity is retained for
  ## the Stencil comparator, not for equality.
  a.seat == b.seat

proc aimedAtPoint(fromPos: BodyPoint, aimBrads: int,
                  point: BodyPoint): bool =
  let desired = bradsOfVector(point.x - fromPos.x, point.y - fromPos.y)
  abs(shortestAimBradsDelta(aimBrads, desired)) <= WardAimToleranceBrads

proc inLiveWeaponRange(fromPos, point: BodyPoint,
                       liveWeaponRangePx: int): bool =
  if liveWeaponRangePx <= 0:
    raise newException(ValueError, "live weapon range must be positive")
  let range = int64(liveWeaponRangePx)
  distanceSquared(fromPos, point) <= range * range

proc trackThreatensPoint(track: BodyTrack, point: BodyPoint,
                         liveWeaponRangePx: int): bool =
  if not inLiveWeaponRange(track.pos, point, liveWeaponRangePx):
    return false
  if track.aimBrads.isSome:
    return aimedAtPoint(track.pos, track.aimBrads.get, point)
  # Ruling 2026-08-31 kept unreadable aim as a named contract path; §4.2
  # keeps proximity as the fallback signal for exactly that case.
  true

proc aimedAtUs*(body: SeatBody, targetSeat: int, tick: uint32,
                liveWeaponRangePx: int): bool =
  validateSeat(targetSeat, "combat target")
  if body.tracks[targetSeat].isNone:
    return false
  let track = body.tracks[targetSeat].get
  track.freshTick == tick and
    track.trackThreatensPoint(body.selfState.pos, liveWeaponRangePx)

proc protectedWardPositions(body: SeatBody, policy: shellTypes.CombatPolicy,
                            tick: uint32): seq[tuple[seat: int, pos: BodyPoint]] =
  var seen: set[uint8]
  for seat in 0 ..< MaxPlayers:
    if body.tracks[seat].isSome:
      let track = body.tracks[seat].get
      if track.freshTick == tick and policy.protect.containsTrack(seat, track.team):
        result.add((seat: seat, pos: track.pos))
        seen.incl(uint8(seat))
  if body.partnerGrant.isSome:
    let partner = body.partnerGrant.get
    if partner.alive and policy.protect.containsSeat(partner.seat.int) and
        partner.seat notin seen:
      result.add((seat: partner.seat.int, pos: partner.pos))

proc threatensProtectedWard*(body: SeatBody,
    policy: shellTypes.CombatPolicy, targetSeat: int, tick: uint32,
    liveWeaponRangePx: int): bool =
  validateSeat(targetSeat, "combat target")
  if body.tracks[targetSeat].isNone:
    return false
  let track = body.tracks[targetSeat].get
  if track.freshTick != tick or
      policy.protectedPolicyTarget(targetSeat, track.team):
    return false
  for ward in body.protectedWardPositions(policy, tick):
    if ward.seat != targetSeat and
        track.trackThreatensPoint(ward.pos, liveWeaponRangePx):
      return true
  false

proc returnFirePermitted(body: SeatBody, targetSeat: int, tick: uint32): bool =
  for event in body.aggressorEvents:
    if tickInsideWindow(event.tick, tick, AggressorWindowTicks) and
        event.seat == some(targetSeat):
      return true
  false

proc compareScoredCombat(a, b: ScoredCombatCandidate): int =
  for index in 0 ..< min(a.preference.len, b.preference.len):
    if a.preference[index] > b.preference[index]: return -1
    if a.preference[index] < b.preference[index]: return 1
  result = cmp(b.score, a.score)
  if result != 0: return
  let
    aKnown = if a.target.identity.isSome: 0 else: 1
    bKnown = if b.target.identity.isSome: 0 else: 1
  result = cmp(aKnown, bKnown)
  if result != 0: return
  let
    aIdentity = if a.target.identity.isSome: a.target.identity.get else: 8
    bIdentity = if b.target.identity.isSome: b.target.identity.get else: 8
  result = cmp(aIdentity, bIdentity)
  if result != 0: return
  result = cmp(a.target.pos.y div NavCell, b.target.pos.y div NavCell)
  if result == 0:
    result = cmp(a.target.pos.x div NavCell, b.target.pos.x div NavCell)

proc candidateByTarget(candidates: openArray[ScoredCombatCandidate],
                       target: CombatTarget): Option[ScoredCombatCandidate] =
  for candidate in candidates:
    if candidate.target.sameTarget(target):
      return some(candidate)

proc toDecision(candidate: ScoredCombatCandidate): CombatDecision =
  CombatDecision(target: candidate.target, score: candidate.score,
    selectedTick: candidate.selectedTick, shootable: candidate.shootable)

proc recordSelectedCombatTarget(body: SeatBody,
                                candidate: ScoredCombatCandidate,
                                tick: uint32): CombatDecision =
  let changed = body.heldCombatTarget.isNone or
    not body.heldCombatTarget.get.sameTarget(candidate.target)
  if changed:
    body.heldCombatTarget = some(candidate.target)
    body.heldCombatSelectedTick = tick
  var selected = candidate
  selected.selectedTick = body.heldCombatSelectedTick
  selected.toDecision

proc selectCombatTarget*(body: SeatBody, policy: shellTypes.CombatPolicy,
    inputs: openArray[CombatCandidateInput], tick: uint32,
    liveWeaponRangePx, targetMaxHp: int): Option[CombatDecision] =
  ## The single phase-4 target-acquisition route. Ordering is:
  ## 1. structural noShoot/protect exclusion;
  ## 2. holdFire engageability;
  ## 3. policy preference tuple;
  ## 4. Stencil's score/identity/cell comparator;
  ## 5. Stencil's target stickiness.
  ##
  ## CTF defender/heart-stolen override arms from the lab are intentionally
  ## absent here: the BR-first body seam has no heart-stolen/thief fact, and
  ## pursuit remains deleted by ruling 3.
  if liveWeaponRangePx <= 0:
    raise newException(ValueError, "live weapon range must be positive")
  if targetMaxHp <= 0:
    raise newException(ValueError, "target max hp must be positive")

  var scored: seq[ScoredCombatCandidate]
  for input in inputs:
    validateSeat(input.seat, "combat candidate")
    if input.seat == body.seatIndex or body.tracks[input.seat].isNone:
      continue
    let track = body.tracks[input.seat].get
    if track.freshTick != tick:
      continue
    if policy.protectedPolicyTarget(input.seat, track.team):
      continue
    if policy.holdFire and not body.returnFirePermitted(input.seat, tick):
      continue
    let wardScore =
      if body.threatensProtectedWard(policy, input.seat, tick,
          liveWeaponRangePx):
        WardThreatScoreBoost
      else:
        0.0
    scored.add(ScoredCombatCandidate(
      target: CombatTarget(seat: input.seat, team: track.team,
        pos: track.pos, identity: input.identity),
      preference: body.preferenceScoreTuple(input.seat, policy.prefer,
        tick, liveWeaponRangePx, targetMaxHp),
      score: input.baseScore + wardScore + FirefightShootabilityWeight *
        (if input.shootable: 1.0 else: -1.0),
      shootable: input.shootable))

  if scored.len == 0:
    body.heldCombatTarget = none(CombatTarget)
    return none(CombatDecision)

  scored.sort(compareScoredCombat)
  let best = scored[0]
  if body.heldCombatTarget.isNone:
    return some(body.recordSelectedCombatTarget(best, tick))
  let current = scored.candidateByTarget(body.heldCombatTarget.get)
  if current.isNone:
    return some(body.recordSelectedCombatTarget(best, tick))
  if current.get.target.sameTarget(best.target):
    return some(body.recordSelectedCombatTarget(current.get, tick))
  let age = tick - body.heldCombatSelectedTick
  let immediate = (not current.get.shootable) and best.shootable
  let materiallyBetter = age >= FirefightTargetMinDwellTicks.uint32 and
    best.score >= current.get.score + FirefightTargetSwitchMargin
  if immediate or materiallyBetter:
    return some(body.recordSelectedCombatTarget(best, tick))
  some(body.recordSelectedCombatTarget(current.get, tick))

proc combatTargetStillAllowed*(body: SeatBody,
    policy: shellTypes.CombatPolicy, target: CombatTarget): bool =
  ## Final weapon veto hook for phase 5: re-check the endpoint against the
  ## current standing policy immediately before actuation.
  discard body
  not policy.protectedPolicyTarget(target.seat, target.team)

proc revalidateGrenadeCommit*(body: SeatBody,
    policy: shellTypes.CombatPolicy, target: CombatTarget,
    splashSeats: openArray[int]): Option[CombatTarget] =
  ## Grenade decisions are re-validated at commit time, against the current
  ## standing policy and the current predicted splash victims. A policy change
  ## or newly protected splash victim cancels the commit instead of force-
  ## releasing the stale throw.
  if not body.combatTargetStillAllowed(policy, target):
    return none(CombatTarget)
  for seat in splashSeats:
    validateSeat(seat, "grenade splash")
    if body.tracks[seat].isSome:
      let track = body.tracks[seat].get
      if policy.protectedPolicyTarget(seat, track.team):
        return none(CombatTarget)
  some(target)

proc arrived(pos, goal: BodyPoint, radius: float): bool =
  let
    dx = pos.x - goal.x
    dy = pos.y - goal.y
  float(dx * dx + dy * dy) <= radius * radius

proc idleAimMask(body: SeatBody): uint8 =
  ## FIRST-LIGHT PLACEHOLDER: converges the aim to the center and holds.
  ## Stencil's idle aim is an oscillating sweep around the center
  ## (LAB:action.nim:62-68, idleSweepAim); phase 5's full action port
  ## replaces this with the stencil-exact sweep — the phase-7 CTF
  ## differential exercises that path, never this one.
  if body.standingIntent.idleAimCenterBrads.isNone:
    return 0'u8
  let desired = ((body.standingIntent.idleAimCenterBrads.get mod
    AimBradsTurn) + AimBradsTurn) mod AimBradsTurn
  let delta = shortestAimBradsDelta(body.selfState.aimBrads, desired)
  if delta > IdleAimDeadband:
    ButtonB
  elif delta < -IdleAimDeadband:
    ButtonSelect
  else:
    0'u8

proc seatTick*(body: SeatBody, inputs: BodyTickInputs,
               tick: uint32): InputState =
  ## Executes one seat's movement-only body tick.
  ##
  ## Cold plan work and danger rebuild cadence stay episode-owned; callers run
  ## `runPlanningTick` and `rebuildScheduledDanger` on the shared BodyNavSystem.
  body.updateBelief(inputs, tick)
  if not body.selfState.alive:
    return InputState()

  var mask = 0'u8
  case body.standingIntent.kind
  of shellTypes.ikHold:
    mask = body.idleAimMask()
  of shellTypes.ikNavigateTo:
    if body.standingGoal.isNone:
      return decodeInputMask(body.idleAimMask())
    let goal = body.standingGoal.get
    let seat = body.nav.seats[body.seatIndex]
    if arrived(body.selfState.pos, goal.goalPoint,
        body.standingIntent.arriveRadius):
      seat.resetProgress(body.selfState.pos)
      mask = body.idleAimMask()
    else:
      let waypoint = body.nav.navigationWaypoint(body.seatIndex,
        body.selfState.pos, goal, tick.int,
        body.standingIntent.movingGoal, body.standingIntent.profile)
      mask = octantToward(body.selfState.pos, waypoint)
      if mask != 0'u8:
        seat.noteProgress(body.selfState.pos)
      else:
        mask = body.idleAimMask()
  decodeInputMask(mask)

proc dangerInputFromTracks*(body: SeatBody, tick: uint32,
                            predicate: TrackPredicate): DangerInput =
  ## Only tracks confirmed on this tick are candidates. The predicate is the
  ## caller's filtering seam until Phase 4 owns team/noShoot/protect policy.
  result.selfXy = body.selfState.pos
  for seat in 0 ..< MaxPlayers:
    if seat == body.seatIndex or body.tracks[seat].isNone:
      continue
    let track = body.tracks[seat].get
    if track.freshTick == tick and predicate(track):
      result.candidates.add(DangerCandidate(seatIndex: seat, pos: track.pos))

proc beliefFingerprint*(body: SeatBody): Hash =
  var value = hash(body.seatIndex) !& hash(body.selfState.pos) !&
    hash(body.selfState.hp) !& hash(body.selfState.hpFrac) !&
    hash(body.selfState.aimBrads) !& hash(body.selfState.alive) !&
    hash(body.selfState.fireCooldown) !& hash(body.selfState.fireWindup) !&
    hash(body.selfState.windup.isSome) !& hash(body.selfState.hasGrenade) !&
    hash(body.selfState.hasShield) !& hash(body.selfState.shieldHp) !&
    hash(body.selfState.hasSprayPaint) !&
    hash(body.selfState.arcTicksLeft) !& hash(body.selfState.carrying) !&
    hash(body.selfState.lives.isSome)
  if body.selfState.lives.isSome:
    value = value !& hash(body.selfState.lives.get)
  if body.selfState.windup.isSome:
    value = value !& hash(body.selfState.windup.get)
  for seat in 0 ..< MaxPlayers:
    value = value !& hash(body.tracks[seat].isSome)
    if body.tracks[seat].isSome:
      let track = body.tracks[seat].get
      value = value !& hash(seat) !& hash(track.pos) !& hash(ord(track.team)) !&
        hash(track.aimBrads.isSome) !& hash(track.hpKnown.isSome) !&
        hash(track.shielded) !& hash(track.weapon.isSome) !&
        hash(track.veteranMarker) !& hash(track.freshTick)
      if track.aimBrads.isSome:
        value = value !& hash(track.aimBrads.get)
      if track.hpKnown.isSome:
        value = value !& hash(track.hpKnown.get)
      if track.weapon.isSome:
        value = value !& hash(ord(track.weapon.get))
  for item in body.items:
    value = value !& hash(item.eventId) !& hash(ord(item.kind)) !&
      hash(item.pos) !& hash(item.present) !& hash(item.freshTick)
  for event in body.killFeed:
    value = value !& hash(event.eventId) !& hash(event.tick) !&
      hash(ord(event.killerTeam)) !& hash(event.victimSeat)
  for event in body.aggressorEvents:
    value = value !& hash(event.eventId) !& hash(event.tick) !&
      hash(event.dirBrads) !& hash(event.seat.isSome)
    if event.seat.isSome:
      value = value !& hash(event.seat.get)
  for event in body.shouts:
    value = value !& hash(event.eventId) !& hash(ord(event.team)) !&
      hash(event.slotLetter) !& hash(event.text) !& hash(event.pos) !&
      hash(event.tick)
  for hazard in body.hazards.grenades:
    value = value !& hash(hazard.eventId) !& hash(hazard.coversSelf) !&
      hash(hazard.pos) !& hash(hazard.predictedBlastPos) !&
      hash(hazard.ticksToBlast)
  for hazard in body.hazards.blastCues:
    value = value !& hash(hazard.eventId) !& hash(hazard.coversSelf) !&
      hash(hazard.pos) !& hash(hazard.tick)
  value = value !& hash(body.hazards.ownThrow.isSome)
  if body.hazards.ownThrow.isSome:
    let ownThrow = body.hazards.ownThrow.get
    value = value !& hash(ownThrow.eventId) !& hash(ownThrow.target) !&
      hash(ownThrow.releaseTick) !& hash(ownThrow.blastRadius)
  for hazard in body.hazards.sprays:
    value = value !& hash(hazard.eventId) !& hash(hazard.coversSelf) !&
      hash(hazard.tick) !& hash(ord(hazard.kind))
    case hazard.kind
    of bshVisibleCone:
      value = value !& hash(hazard.attackerSeat) !& hash(hazard.origin) !&
        hash(hazard.aimBrads) !& hash(hazard.reachPx) !&
        hash(hazard.maxWidthPx)
    of bshAnonymousImpact:
      value = value !& hash(hazard.impactPos) !&
        hash(hazard.incomingDirBrads)
  value = value !& hash(body.partnerGrant.isSome)
  if body.partnerGrant.isSome:
    let partner = body.partnerGrant.get
    value = value !& hash(partner.seat) !& hash(partner.pos) !&
      hash(partner.aimBrads) !& hash(partner.alive)
  !$value
