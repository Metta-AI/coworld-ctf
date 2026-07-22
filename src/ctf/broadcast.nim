## Replay broadcast state channel.
##
## Derives the designed broadcast client's JSON chrome state from the live
## sim. The binary sprite stream stays the board renderer; this module produces
## the parallel TextMessage the broadcast client reads to draw the scorebug,
## kill feed, banners, roster, transport and end-card.
##
## Beat-event derivation mirrors `tools/expand_replay.nim` exactly (per-victim
## death/alive diffs, carrier diffs, capture diffs, phase transitions), so the
## broadcast tells the same story the timeline tool would. Events are derived
## ONE SIM STEP AT A TIME (`stepEvents`) and accumulated by the caller across a
## playback frame, so kill attribution stays exact even at 16x — never
## collapsing a whole span into one ambiguous marker. Attribution still
## degrades honestly to "ambiguous" only on a genuine same-tick multi-kill
## (fidelity rule F7). Kills are never rendered as score (F1); flags have
## exactly HOME/TAKEN states (F2); the end-card names the tiebreak key and
## checks a draw before a winner (F3/F4).

import
  std/[json, math, strutils],
  sim

type
  BroadcastTracker* = object
    ## Per-server snapshot used to diff one sim step against the previous one.
    initialized: bool
    prevTick: int
    prevPhase: GamePhase
    alive: seq[bool]
    kills: seq[int]
    deaths: seq[int]
    captures: seq[int]
    carriers: array[Team, int]

proc initBroadcastTracker*(): BroadcastTracker =
  ## Returns a fresh, unsynced broadcast tracker.
  result.prevPhase = Lobby
  result.carriers = [Red: -1, Blue: -1]

proc slotOf(sim: SimServer, index: int): int =
  ## Returns the stable join slot for a player index, or -1.
  if index >= 0 and index < sim.players.len:
    return sim.players[index].joinOrder
  -1

proc snapshot(tracker: var BroadcastTracker, sim: SimServer) =
  ## Copies the current sim state into the tracker without emitting events.
  tracker.alive.setLen(sim.players.len)
  tracker.kills.setLen(sim.players.len)
  tracker.deaths.setLen(sim.players.len)
  tracker.captures.setLen(sim.players.len)
  for i, p in sim.players:
    tracker.alive[i] = p.alive
    tracker.kills[i] = p.kills
    tracker.deaths[i] = p.deaths
    tracker.captures[i] = p.captures
  for team in Team:
    tracker.carriers[team] = sim.flags[team].carrier
  tracker.prevTick = sim.tickCount
  tracker.prevPhase = sim.phase
  tracker.initialized = true

proc resync*(tracker: var BroadcastTracker, sim: SimServer) =
  ## Snapshots without emitting events, after a seek/loop/skip. The next
  ## `stepEvents` then diffs against this frame, so no phantom beats fire.
  tracker.snapshot(sim)

proc killerThisStep(
  sim: SimServer,
  tracker: BroadcastTracker
): tuple[index: int, ambiguous: bool] =
  ## Returns the single killer's player index for this step, or an ambiguous
  ## marker when two or more players scored a kill on the same tick (fidelity
  ## rule F7 — never guess an attribution the sim can't disambiguate).
  var
    killerIndex = -1
    killerCount = 0
  for i, p in sim.players:
    if i < tracker.kills.len and p.kills > tracker.kills[i]:
      inc killerCount
      killerIndex = i
  if killerCount == 1:
    (killerIndex, false)
  elif killerCount > 1:
    (-1, true)
  else:
    (-1, false)

proc stepEvents*(
  sim: SimServer,
  tracker: var BroadcastTracker,
  events: JsonNode
) =
  ## Appends the beat events produced by the transition from the tracker's last
  ## snapshot to the current sim tick, then advances the tracker. Only meant to
  ## be called across a small forward delta (one replay step); use `resync`
  ## after a seek. Each event carries the tick it fired on so the client can
  ## place scrubber markers and honour per-beat read-holds.
  if not tracker.initialized:
    tracker.snapshot(sim)
    return

  let tick = sim.tickCount

  # Phase transitions (and the terminal game-over verdict).
  if sim.phase != tracker.prevPhase:
    events.add(%*{"t": tick, "k": "phase", "phase": ($sim.phase).toLowerAscii})
    if sim.phase == GameOver:
      events.add(%*{
        "t": tick,
        "k": "gameover",
        "winner": teamText(sim.winner),
        "draw": sim.isDraw,
        "tl": sim.timeLimitReached
      })

  # Kills and respawns, diffed per player like expand_replay.
  let killer = sim.killerThisStep(tracker)
  # Provable mutual trade: when exactly two players scored a kill this step AND
  # exactly those same two players died, each necessarily killed the other (a
  # player can't kill itself and no third party scored), so attribution IS
  # recoverable even though `killerThisStep` reports the step ambiguous. We tag
  # each of the two kill events with its partner's slot so the client can draw
  # one linked "A traded with B" row instead of two nameless markers. A wider
  # pileup (>2 kills, or killers != victims) stays honestly ambiguous.
  var killers, victims: seq[int]
  for i, p in sim.players:
    if i < tracker.kills.len and p.kills > tracker.kills[i]:
      killers.add i
    if i < tracker.deaths.len and p.deaths > tracker.deaths[i]:
      victims.add i
  let tradePair =
    killers.len == 2 and victims.len == 2 and
    killers[0] in victims and killers[1] in victims
  for i, p in sim.players:
    if i < tracker.deaths.len and p.deaths > tracker.deaths[i]:
      let tk = killer.index >= 0 and sim.players[killer.index].team == p.team
      var event = %*{
        "t": tick,
        "k": "kill",
        "killer": (if killer.index >= 0: sim.slotOf(killer.index) else: -1),
        "victim": sim.slotOf(i),
        "tk": tk,
        "amb": killer.ambiguous
      }
      if tradePair:
        # The partner is the other victim; each is the other's provable killer.
        let partner = if victims[0] == i: victims[1] else: victims[0]
        event["trade"] = %sim.slotOf(partner)
      events.add(event)
    elif i < tracker.alive.len and p.alive and not tracker.alive[i]:
      events.add(%*{"t": tick, "k": "respawn", "who": sim.slotOf(i)})

  # Flag steals and returns, diffed per team like expand_replay. A carrier
  # losing a flag for any reason but capture returns it home instantly.
  for team in Team:
    let carrier = sim.flags[team].carrier
    if carrier == tracker.carriers[team]:
      continue
    if tracker.carriers[team] >= 0:
      events.add(%*{"t": tick, "k": "return", "flag": teamText(team)})
    if carrier >= 0:
      events.add(%*{
        "t": tick,
        "k": "steal",
        "flag": teamText(team),
        "by": sim.slotOf(carrier)
      })

  # Captures, diffed per player. A player always captures the enemy flag.
  for i, p in sim.players:
    if i < tracker.captures.len and p.captures > tracker.captures[i]:
      events.add(%*{
        "t": tick,
        "k": "capture",
        "by": sim.slotOf(i),
        "flag": teamText(enemy(p.team))
      })

  tracker.snapshot(sim)

proc teamStateJson(sim: SimServer, team: Team): JsonNode =
  ## Returns one team's scorebug state: lives, flag state, carrier, progress.
  let
    flag = sim.flags[team]
    taken = flag.carrier >= 0
  result = %*{
    "lives": sim.teamLivesRemaining(team),
    "flag": (if taken: "taken" else: "home"),
    "carrier": (if taken: sim.slotOf(flag.carrier) else: -1),
    "prog": sim.teamFlagProgress(enemy(team))
  }

proc rosterJson(sim: SimServer): JsonNode =
  ## Returns the per-player roster array keyed by stable join slot.
  result = newJArray()
  for p in sim.players:
    result.add(%*{
      "s": p.joinOrder,
      "team": teamText(p.team),
      "name": p.address,
      "col": int(p.color),
      "alive": p.alive,
      "lives": p.lives,
      "hp": p.hp,
      "carry": p.carryingFlag,
      "k": p.kills,
      "d": p.deaths,
      "cap": p.captures,
      "mk2": p.multiKills2,
      "mk3": p.multiKills3,
      "tk": p.teamKills
    })

const
  FpColumns = 96              ## raycast columns per first-person frame.
  FpMarchStep = 2.0           ## px per wall-march step (fine enough at 1235px).
  FpEntFovMarginBrads = 8.0   ## let a sprite straddling the cone edge still show.

proc bradOffset(a, b: float): float =
  ## Signed smallest angular difference a-b, wrapped to [-128, 128) brads.
  result = a - b
  while result < -float(AimBradsTurn div 2): result += float(AimBradsTurn)
  while result >= float(AimBradsTurn div 2): result -= float(AimBradsTurn)

proc firstPersonJson(sim: SimServer, playerIndex: int): JsonNode =
  ## Builds the selected player's first-person (Wolfenstein-style) raycast view:
  ## per-column perpendicular wall distances plus the billboarded entities the
  ## player can actually see. The main board keeps showing their fogged top-down
  ## POV; this rides alongside as the picture-in-picture inset. Everything here is
  ## derived from the same fog rules the player observes, so the inset never
  ## reveals more than the seat legitimately sees.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return newJNull()
  let
    self = sim.players[playerIndex]
    selfAlive = self.alive
    px = float(self.x + CollisionW div 2)
    py = float(self.y + CollisionH div 2)
    aim = float(self.aimBrads)
    # The inset FOV is literally the player's vision-cone half-angle, so the
    # strip shows exactly the arc they perceive.
    halfFov = float(sim.config.visionConeDeg) * float(AimBradsTurn) / 360.0
    maxRange = float(sim.config.gunRange)
    radPerBrad = PI / float(AimBradsTurn div 2)

  var cols = newJArray()
  for i in 0 ..< FpColumns:
    let
      frac = (if FpColumns == 1: 0.0 else: float(i) / float(FpColumns - 1))
      # Column 0 = left edge = CCW (+halfFov); column N-1 = right edge = CW.
      colBrad = aim + halfFov - frac * 2.0 * halfFov
      rad = colBrad * radPerBrad
      dx = cos(rad)
      dy = -sin(rad)
    var
      t = FpMarchStep
      hit = -1
    while t <= maxRange:
      let
        mx = int(px + dx * t)
        my = int(py + dy * t)
      if mx < 0 or my < 0 or mx >= MapWidth or my >= MapHeight:
        break
      if sim.isWall(mx, my):
        # Fisheye-correct: project the hit onto the central view axis so a flat
        # wall reads flat, not bowed.
        hit = int(t * cos((colBrad - aim) * radPerBrad))
        break
      t += FpMarchStep
    cols.add(%hit)

  var ents = newJArray()
  proc addEnt(
    kind, team: string,
    wx, wy: float,
    hp: int,
    carry: bool
  ) =
    let
      dx = wx - px
      dy = wy - py
      dist = hypot(dx, dy)
    if dist < 1.0:
      return
    let
      entBrad = arctan2(-dy, dx) / radPerBrad
      off = bradOffset(entBrad, aim)
    if abs(off) > halfFov + FpEntFovMarginBrads:
      return
    # o in [-1, 1]: -1 = left edge (+halfFov), +1 = right edge (-halfFov).
    var e = %*{"k": kind, "team": team, "o": -off / halfFov, "d": int(dist)}
    if hp >= 0:
      e["hp"] = %hp
    if carry:
      e["carry"] = %true
    ents.add(e)

  # A ghost (dead viewer) sees the whole map's terrain but NO moving entities,
  # so its inset is walls-only — matching the fog contract.
  if selfAlive:
    for j in 0 ..< sim.players.len:
      if j == playerIndex:
        continue
      let other = sim.players[j]
      if not other.alive:
        continue
      if not sim.playerVisibleTo(playerIndex, j):
        continue
      addEnt(
        (if other.team == self.team: "mate" else: "enemy"),
        teamText(other.team),
        float(other.x + CollisionW div 2),
        float(other.y + CollisionH div 2),
        other.hp,
        other.carryingFlag
      )
    # Hearts on their pedestals are billboards; a carried heart rides its
    # carrier (already drawn as that player, tagged carry), so skip it here.
    for team in Team:
      if sim.flags[team].carrier >= 0:
        continue
      if not sim.flagVisibleTo(playerIndex, team):
        continue
      let f = sim.flags[team]
      addEnt("heart", teamText(team), float(f.x), float(f.y), -1, false)

  result = %*{
    "mr": int(maxRange),
    "cols": cols,
    "ents": ents
  }

proc buildStateJson*(
  sim: SimServer,
  events: JsonNode,
  playing: bool,
  speed: int,
  maxTick: int,
  looping: bool,
  transportEnabled: bool,
  mismatchTick: int,
  povSlot: int,
  livesLeadSeries: seq[array[2, int]] = @[],
  startTick: int = 0,
  endHoldSeconds: int = 0
): string =
  ## Assembles the broadcast chrome frame from the current board state plus the
  ## events accumulated across this playback frame. Board-derived STATE (lives,
  ## flags, roster, verdict) is always present, so even a frame reached by a
  ## seek still hydrates the scorebug and end-card with no events.
  var teams = newJObject()
  for team in Team:
    teams[teamText(team)] = sim.teamStateJson(team)

  var state = %*{
    "t": sim.tickCount,
    "mt": sim.config.maxTicks,
    "ph": ($sim.phase).toLowerAscii,
    "lob": sim.lobbyStartSecondsRemaining(),
    "pl": playing,
    "sp": speed,
    "mx": maxTick,
    "st": startTick,
    "lp": looping,
    "en": transportEnabled,
    "mm": mismatchTick,
    "pov": povSlot,
    "teams": teams,
    "roster": sim.rosterJson(),
    "events": (if events.isNil: newJArray() else: events)
  }

  # First-person picture-in-picture: the selected seat's raycast view, present
  # only while a player is in POV. The client shows/hides its overlay canvas off
  # `pov >= 0` (like any other state-driven chrome) and redraws from `fp`.
  if povSlot >= 0:
    var povIndex = -1
    for i, p in sim.players:
      if p.joinOrder == povSlot:
        povIndex = i
        break
    if povIndex >= 0:
      let fp = sim.firstPersonJson(povIndex)
      if fp.kind != JNull:
        state["fp"] = fp

  # Full-timeline lives-lead series (sent ONCE per HUD viewer): [[tick, diff], …]
  # change-points across the WHOLE match so the momentum graph draws its full
  # width immediately instead of accumulating to the playhead. Absent on every
  # later frame — the client caches it.
  if livesLeadSeries.len > 0:
    var series = newJArray()
    for point in livesLeadSeries:
      series.add(%*[point[0], point[1]])
    state["lead"] = series

  # The end-card is STATE, not an event: present on every game-over frame so a
  # viewer who seeks straight to the end still sees the verdict. isDraw is read
  # before winner (F4); the tiebreak keys let the card name how it ended (F3),
  # and distinguish a mutual wipe from a dead-even limit (F10).
  if sim.phase == GameOver:
    state["over"] = %*{
      "winner": teamText(sim.winner),
      "draw": sim.isDraw,
      "timeLimit": sim.timeLimitReached,
      "redLives": sim.teamLivesRemaining(Red),
      "blueLives": sim.teamLivesRemaining(Blue),
      "redProg": sim.teamFlagProgress(Red),
      "blueProg": sim.teamFlagProgress(Blue)
    }
    # End-segment hold countdown: whole seconds until a looping replay
    # restarts. Present only during the hold, so the end-card can show a
    # "replaying in N" line without ever inventing a countdown after a seek.
    if endHoldSeconds > 0:
      state["hold"] = %endHoldSeconds

  $state
