## Per-seat body state at the contracted server/body seam.
##
## This first-light slice owns the standing order and belief-lite data only.
## Movement/action execution is added in FL-B; the guarded server lifecycle is
## added in FL-C.

import std/[hashes, options]
import bitworld/spriteprotocol
import ../ctf/sim_types
import body_cache, body_map, body_nav, body_planner
import types as shellTypes

const IdleAimDeadband = AimTurnRate div 2

type
  BodySelfState* = object
    pos*: BodyPoint
    hp*: int
    hpFrac*: float
    aimBrads*: int
    alive*: bool
    carrying*: bool

  BodyTrack* = object
    pos*: BodyPoint
    team*: Team
    aimBrads*: int
    hpKnown*: Option[int]
    freshTick*: uint32

  BodyTrackUpdate* = object
    seat*: int
    pos*: BodyPoint
    team*: Team
    aimBrads*: int
    hpKnown*: Option[int]
    tick*: uint32

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

  TrackPredicate* = proc(track: BodyTrack): bool {.closure.}

  SeatBody* = ref object
    map*: BodyMap
    seatIndex*: int
    nav*: BodyNavSystem
    selfState*: BodySelfState
    tracks*: array[MaxPlayers, Option[BodyTrack]]
    standingIntent*: shellTypes.Intent
    effectiveEpoch*: uint64
    standingGoal*: Option[ValidatedGoal]
    partnerGrant: Option[PartnerTelemetry]

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
    updates[update.seat] = some(update)
  for seat in 0 ..< MaxPlayers:
    if updates[seat].isSome:
      let update = updates[seat].get
      body.tracks[seat] = some(BodyTrack(pos: update.pos,
        team: update.team, aimBrads: update.aimBrads,
        hpKnown: update.hpKnown, freshTick: update.tick))

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
    hash(body.selfState.carrying)
  for seat in 0 ..< MaxPlayers:
    value = value !& hash(body.tracks[seat].isSome)
    if body.tracks[seat].isSome:
      let track = body.tracks[seat].get
      value = value !& hash(seat) !& hash(track.pos) !& hash(ord(track.team)) !&
        hash(track.aimBrads) !& hash(track.hpKnown.isSome) !&
        hash(track.freshTick)
      if track.hpKnown.isSome:
        value = value !& hash(track.hpKnown.get)
  value = value !& hash(body.partnerGrant.isSome)
  if body.partnerGrant.isSome:
    let partner = body.partnerGrant.get
    value = value !& hash(partner.seat) !& hash(partner.pos) !&
      hash(partner.aimBrads) !& hash(partner.alive)
  !$value
