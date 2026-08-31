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

type
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
    alive*: bool
    carrying*: bool

  BodyTrack* = object
    pos*: BodyPoint
    team*: Team
    aimBrads*: Option[int]
    hpKnown*: Option[int]
    veteranMarker*: bool
    freshTick*: uint32

  BodyTrackUpdate* = object
    seat*: int
    pos*: BodyPoint
    team*: Team
    aimBrads*: Option[int]
    hpKnown*: Option[int]
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
    ## receives raw sim state. Track filtering for team/noShoot/protect remains
    ## caller-owned until the Phase 4 combat policy lands.
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
        hpKnown: update.hpKnown, veteranMarker: update.veteranMarker,
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
    hash(body.selfState.carrying) !& hash(body.selfState.lives.isSome)
  if body.selfState.lives.isSome:
    value = value !& hash(body.selfState.lives.get)
  for seat in 0 ..< MaxPlayers:
    value = value !& hash(body.tracks[seat].isSome)
    if body.tracks[seat].isSome:
      let track = body.tracks[seat].get
      value = value !& hash(seat) !& hash(track.pos) !& hash(ord(track.team)) !&
        hash(track.aimBrads.isSome) !& hash(track.hpKnown.isSome) !&
        hash(track.veteranMarker) !& hash(track.freshTick)
      if track.aimBrads.isSome:
        value = value !& hash(track.aimBrads.get)
      if track.hpKnown.isSome:
        value = value !& hash(track.hpKnown.get)
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
