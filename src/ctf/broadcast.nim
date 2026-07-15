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
  std/[json, strutils],
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
  for i, p in sim.players:
    if i < tracker.deaths.len and p.deaths > tracker.deaths[i]:
      let tk = killer.index >= 0 and sim.players[killer.index].team == p.team
      events.add(%*{
        "t": tick,
        "k": "kill",
        "killer": (if killer.index >= 0: sim.slotOf(killer.index) else: -1),
        "victim": sim.slotOf(i),
        "tk": tk,
        "amb": killer.ambiguous
      })
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
      "cap": p.captures
    })

proc buildStateJson*(
  sim: SimServer,
  events: JsonNode,
  playing: bool,
  speed: int,
  maxTick: int,
  looping: bool,
  transportEnabled: bool,
  mismatchTick: int,
  povSlot: int
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
    "lp": looping,
    "en": transportEnabled,
    "mm": mismatchTick,
    "pov": povSlot,
    "teams": teams,
    "roster": sim.rosterJson(),
    "events": (if events.isNil: newJArray() else: events)
  }

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

  $state
