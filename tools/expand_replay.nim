import
  std/[json, os, strutils],
  ../src/ctf/replays,
  ../src/ctf/sim

type
  ExpandReplayError = object of CatchableError

  ReplayEventKind* = enum
    PlayerJoined
    PhaseChanged
    Shot
    Hit
    Kill
    FlagSteal
    FlagReturnHome
    Capture
    Respawn
    ScoreChanged
    ItemPickup
    ItemUse
    ItemRespawn
    GameOver

  ReplayEvent* = object
    tick*: int
    kind*: ReplayEventKind
    actorSlot*: int
    actorLabel*: string
    secondarySlot*: int
    secondaryLabel*: string
    phase*: GamePhase
    scoreAmount*: int
    flagTeam*: Team
    winner*: Team
    isDraw*: bool
    item*: string
    livesLeft*: int            ## Victim lives remaining after a Kill.
    endReason*: string         ## GameOver: capture, wipe, time_limit, mutual_wipe.

  ReplayTimeline* = object
    events*: seq[ReplayEvent]
    tickCount*: int
    hashFailed*: bool
    failTick*: int

const
  UsageText = "Usage: nim r tools/expand_replay.nim [replay-path]"
  GameDir = currentSourcePath().parentDir().parentDir()
  DefaultReplayPath = GameDir / "tests" / "replays" / "ctf.bitreplay"

proc fail(message: string) =
  ## Raises one replay expansion failure.
  raise newException(ExpandReplayError, message)

proc replayPathFromArgs(): string {.used.} =
  ## Returns the replay path passed on the command line.
  var paths: seq[string]
  for arg in commandLineParams():
    if arg == "--":
      discard
    elif arg in ["--help", "-h"]:
      echo UsageText
      quit(0)
    elif arg.startsWith("--"):
      fail("Unknown option: " & arg & "\n" & UsageText)
    else:
      paths.add(arg)
  if paths.len > 1:
    fail("Expected at most one replay path.\n" & UsageText)
  if paths.len == 0:
    return DefaultReplayPath
  paths[0].absolutePath()

proc replayConfig(data: ReplayData): GameConfig =
  ## Returns the game config embedded in a replay.
  result = defaultGameConfig()
  result.update(data.configJson)

proc player(sim: SimServer, i: int): string =
  ## Returns team, color, and username for one player.
  let p = sim.players[i]
  teamText(p.team) & " " & playerColorText(p.color) & "(" & p.address & ")"

proc playerSlot(sim: SimServer, i: int): int =
  ## Returns one player's stable join slot.
  if i >= 0 and i < sim.players.len:
    return sim.players[i].joinOrder
  -1

proc addPlayerEvent(
  events: var seq[ReplayEvent],
  tick: int,
  kind: ReplayEventKind,
  sim: SimServer,
  playerIndex: int
) =
  ## Adds one single-player replay event.
  events.add ReplayEvent(
    tick: tick,
    kind: kind,
    actorSlot: sim.playerSlot(playerIndex),
    actorLabel: sim.player(playerIndex),
    secondarySlot: -1,
    phase: sim.phase
  )

type
  ItemSpawnTrack = object
    ## Last-seen present flags for floor pickups.
    ready: bool
    grenades: array[4, bool]
    medKits: array[2, bool]
    shields: array[2, bool]
    plasmas: array[2, bool]

  TrackState = object
    alive: seq[bool]
    kills: seq[int]
    deaths: seq[int]
    captures: seq[int]
    rewards: seq[int]
    shotsFired: seq[int]
    shotsHit: seq[int]
    hp: seq[int]
    shieldHp: seq[int]
    hasGrenade: seq[bool]
    hasPlasma: seq[bool]
    arcTicksLeft: seq[int]
    itemSpawns: ItemSpawnTrack

proc syncPlayers(
  sim: SimServer,
  tick: int,
  events: var seq[ReplayEvent],
  track: var TrackState
) =
  ## Adds tracking state and join events for newly joined players.
  while track.alive.len < sim.players.len:
    let i = track.alive.len
    track.alive.add(sim.players[i].alive)
    track.kills.add(sim.players[i].kills)
    track.deaths.add(sim.players[i].deaths)
    track.captures.add(sim.players[i].captures)
    track.rewards.add(sim.players[i].reward)
    track.shotsFired.add(sim.players[i].shotsFired)
    track.shotsHit.add(sim.players[i].shotsHit)
    track.hp.add(sim.players[i].hp)
    track.shieldHp.add(sim.players[i].shieldHp)
    track.hasGrenade.add(sim.players[i].hasGrenade)
    track.hasPlasma.add(sim.players[i].hasPlasmaArc)
    track.arcTicksLeft.add(sim.players[i].arcTicksLeft)
    events.addPlayerEvent(tick, PlayerJoined, sim, i)

proc killerThisTick(sim: SimServer, track: TrackState): int =
  ## Returns the single player whose kill count just went up this tick, or -1
  ## when none or SEVERAL did — fidelity rule F7, matching broadcast's
  ## killerThisStep: when two players score on the same tick the sim cannot
  ## say who killed whom, so the timeline never guesses an attribution.
  result = -1
  var killerCount = 0
  for i, player in sim.players:
    if i < track.kills.len and player.kills > track.kills[i]:
      inc killerCount
      result = i
  if killerCount > 1:
    result = -1

proc teamHasCapture(sim: SimServer, team: Team): bool =
  ## Returns true when any player on the team has a recorded capture.
  for player in sim.players:
    if player.team == team and player.captures > 0:
      return true

proc gameEndReason(sim: SimServer): string =
  ## Returns why the match ended: capture, wipe, time limit, or mutual wipe.
  if sim.timeLimitReached:
    return "time_limit"
  if sim.isDraw:
    return "mutual_wipe"
  if sim.teamHasCapture(sim.winner):
    return "capture"
  "wipe"

proc printKillsAndDeaths(
  sim: SimServer,
  tick: int,
  events: var seq[ReplayEvent],
  track: var TrackState
) =
  ## Adds kill/respawn events by diffing per-player death and alive counters.
  let killer = sim.killerThisTick(track)
  for i, p in sim.players:
    if p.deaths > track.deaths[i]:
      events.add ReplayEvent(
        tick: tick,
        kind: Kill,
        actorSlot: if killer >= 0: sim.playerSlot(killer) else: -1,
        actorLabel: if killer >= 0: sim.player(killer) else: "unknown",
        secondarySlot: sim.playerSlot(i),
        secondaryLabel: sim.player(i),
        phase: sim.phase,
        livesLeft: p.lives
      )
    elif p.alive and not track.alive[i]:
      events.add ReplayEvent(
        tick: tick,
        kind: Respawn,
        actorSlot: sim.playerSlot(i),
        actorLabel: sim.player(i),
        secondarySlot: -1,
        phase: sim.phase,
        livesLeft: p.lives
      )
    track.alive[i] = p.alive
    track.kills[i] = p.kills
    track.deaths[i] = p.deaths

proc printShots(
  sim: SimServer,
  tick: int,
  events: var seq[ReplayEvent],
  track: var TrackState
) =
  ## Adds shot/hit events by diffing per-player shot counters. A player
  ## releases at most one shot per tick (fire cooldown), so each counter rises
  ## by at most one; a Hit is a shot that locked onto a live enemy on its ray.
  for i, p in sim.players:
    if p.shotsFired > track.shotsFired[i]:
      events.addPlayerEvent(tick, Shot, sim, i)
    if p.shotsHit > track.shotsHit[i]:
      events.addPlayerEvent(tick, Hit, sim, i)
    track.shotsFired[i] = p.shotsFired
    track.shotsHit[i] = p.shotsHit

proc printItems(
  sim: SimServer,
  tick: int,
  events: var seq[ReplayEvent],
  track: var TrackState
) =
  ## Adds item pickup and use events by diffing carried gear and HP.
  for i, p in sim.players:
    if track.alive[i] and p.alive and p.hp > track.hp[i]:
      events.add ReplayEvent(
        tick: tick,
        kind: ItemPickup,
        actorSlot: sim.playerSlot(i),
        actorLabel: sim.player(i),
        secondarySlot: -1,
        phase: sim.phase,
        item: "med kit"
      )
      events.add ReplayEvent(
        tick: tick,
        kind: ItemUse,
        actorSlot: sim.playerSlot(i),
        actorLabel: sim.player(i),
        secondarySlot: -1,
        phase: sim.phase,
        scoreAmount: p.hp - track.hp[i],
        item: "med kit"
      )
    if p.hasGrenade and not track.hasGrenade[i]:
      events.add ReplayEvent(
        tick: tick,
        kind: ItemPickup,
        actorSlot: sim.playerSlot(i),
        actorLabel: sim.player(i),
        secondarySlot: -1,
        phase: sim.phase,
        item: "grenade"
      )
    elif track.hasGrenade[i] and not p.hasGrenade and
      p.deaths == track.deaths[i]:
      events.add ReplayEvent(
        tick: tick,
        kind: ItemUse,
        actorSlot: sim.playerSlot(i),
        actorLabel: sim.player(i),
        secondarySlot: -1,
        phase: sim.phase,
        item: "grenade"
      )
    if p.shieldHp > track.shieldHp[i]:
      events.add ReplayEvent(
        tick: tick,
        kind: ItemPickup,
        actorSlot: sim.playerSlot(i),
        actorLabel: sim.player(i),
        secondarySlot: -1,
        phase: sim.phase,
        item: "shield"
      )
    if p.hasPlasmaArc and not track.hasPlasma[i]:
      events.add ReplayEvent(
        tick: tick,
        kind: ItemPickup,
        actorSlot: sim.playerSlot(i),
        actorLabel: sim.player(i),
        secondarySlot: -1,
        phase: sim.phase,
        item: "plasma arc"
      )
    if p.arcTicksLeft > 0 and track.arcTicksLeft[i] == 0:
      events.add ReplayEvent(
        tick: tick,
        kind: ItemUse,
        actorSlot: sim.playerSlot(i),
        actorLabel: sim.player(i),
        secondarySlot: -1,
        phase: sim.phase,
        item: "plasma arc"
      )
    track.hp[i] = p.hp
    track.shieldHp[i] = p.shieldHp
    track.hasGrenade[i] = p.hasGrenade
    track.hasPlasma[i] = p.hasPlasmaArc
    track.arcTicksLeft[i] = p.arcTicksLeft

proc addItemRespawn(
  events: var seq[ReplayEvent],
  tick: int,
  phase: GamePhase,
  item: string
) =
  ## Records one floor pickup becoming available again.
  events.add ReplayEvent(
    tick: tick,
    kind: ItemRespawn,
    actorSlot: -1,
    secondarySlot: -1,
    phase: phase,
    item: item
  )

proc printItemSpawns(
  sim: SimServer,
  tick: int,
  events: var seq[ReplayEvent],
  track: var TrackState
) =
  ## Adds item respawn events when a floor pickup refills.
  if not track.itemSpawns.ready:
    for i, spawn in sim.grenadeSpawns:
      track.itemSpawns.grenades[i] = spawn.present
    for i, spawn in sim.medKitSpawns:
      track.itemSpawns.medKits[i] = spawn.present
    for i, spawn in sim.shieldSpawns:
      track.itemSpawns.shields[i] = spawn.present
    for i, spawn in sim.plasmaArcSpawns:
      track.itemSpawns.plasmas[i] = spawn.present
    track.itemSpawns.ready = true
    return
  for i, spawn in sim.grenadeSpawns:
    if spawn.present and not track.itemSpawns.grenades[i]:
      events.addItemRespawn(tick, sim.phase, "grenade")
    track.itemSpawns.grenades[i] = spawn.present
  for i, spawn in sim.medKitSpawns:
    if spawn.present and not track.itemSpawns.medKits[i]:
      events.addItemRespawn(tick, sim.phase, "med kit")
    track.itemSpawns.medKits[i] = spawn.present
  for i, spawn in sim.shieldSpawns:
    if spawn.present and not track.itemSpawns.shields[i]:
      events.addItemRespawn(tick, sim.phase, "shield")
    track.itemSpawns.shields[i] = spawn.present
  for i, spawn in sim.plasmaArcSpawns:
    if spawn.present and not track.itemSpawns.plasmas[i]:
      events.addItemRespawn(tick, sim.phase, "plasma arc")
    track.itemSpawns.plasmas[i] = spawn.present

proc printCaptures(
  sim: SimServer,
  tick: int,
  events: var seq[ReplayEvent],
  track: var TrackState
) =
  ## Adds capture events by diffing per-player capture counters. A player
  ## always captures the enemy team's flag.
  for i, p in sim.players:
    if p.captures > track.captures[i]:
      events.add ReplayEvent(
        tick: tick,
        kind: Capture,
        actorSlot: sim.playerSlot(i),
        actorLabel: sim.player(i),
        secondarySlot: -1,
        flagTeam: enemy(p.team),
        phase: sim.phase
      )
    track.captures[i] = p.captures

proc printScoreChanges(
  sim: SimServer,
  tick: int,
  events: var seq[ReplayEvent],
  track: var TrackState
) =
  ## Adds score change events since the previous tick.
  for i, p in sim.players:
    if p.reward != track.rewards[i]:
      events.add ReplayEvent(
        tick: tick,
        kind: ScoreChanged,
        actorSlot: sim.playerSlot(i),
        actorLabel: sim.player(i),
        secondarySlot: -1,
        scoreAmount: p.reward - track.rewards[i],
        phase: sim.phase
      )
      track.rewards[i] = p.reward

proc printFlagChanges(
  sim: SimServer,
  tick: int,
  events: var seq[ReplayEvent],
  prevCarriers: var array[Team, int]
) =
  ## Adds per-team flag steal and return-home events by diffing each flag's
  ## carrier. A carrier losing a flag for any reason other than capture sends
  ## it straight back to its pedestal; captures keep the carrier and are
  ## reported separately.
  for team in Team:
    let carrier = sim.flags[team].carrier
    if carrier == prevCarriers[team]:
      continue
    if prevCarriers[team] >= 0:
      events.add ReplayEvent(
        tick: tick,
        kind: FlagReturnHome,
        actorSlot: -1,
        actorLabel: "",
        secondarySlot: -1,
        flagTeam: team,
        phase: sim.phase
      )
    if carrier >= 0:
      events.add ReplayEvent(
        tick: tick,
        kind: FlagSteal,
        actorSlot: sim.playerSlot(carrier),
        actorLabel: sim.player(carrier),
        secondarySlot: -1,
        flagTeam: team,
        phase: sim.phase
      )
    prevCarriers[team] = carrier

proc scoreAmountText(amount: int): string =
  ## Returns a readable signed score amount.
  if amount > 0:
    "+" & $amount
  else:
    $amount

proc key*(event: ReplayEvent): string =
  ## Returns the event-log key for one replay event.
  case event.kind
  of PlayerJoined:
    "player_joined"
  of PhaseChanged:
    "phase"
  of Shot:
    "shot"
  of Hit:
    "hit"
  of Kill:
    "kill"
  of FlagSteal:
    "flag_steal"
  of FlagReturnHome:
    "flag_return_home"
  of Capture:
    "capture"
  of Respawn:
    "respawn"
  of ScoreChanged:
    "score"
  of ItemPickup:
    "item_pickup"
  of ItemUse:
    "item_use"
  of ItemRespawn:
    "item_respawn"
  of GameOver:
    "game_over"

proc text*(event: ReplayEvent): string =
  ## Renders one replay event as a human-readable CLI line.
  case event.kind
  of PlayerJoined:
    "  player " & event.actorLabel & " joined"
  of PhaseChanged:
    "  phase " & $event.phase
  of Shot:
    "  player " & event.actorLabel & " fired"
  of Hit:
    "  player " & event.actorLabel & " landed a shot"
  of Kill:
    "  player " & event.actorLabel & " killed " & event.secondaryLabel &
      " (" & $event.livesLeft & (
        if event.livesLeft == 1:
          " life left"
        else:
          " lives left"
      ) & ")"
  of FlagSteal:
    "  player " & event.actorLabel & " stole the " &
      teamText(event.flagTeam) & " flag"
  of FlagReturnHome:
    "  " & teamText(event.flagTeam) & " flag returned home"
  of Capture:
    "  player " & event.actorLabel & " captured the " &
      teamText(event.flagTeam) & " flag"
  of Respawn:
    "  player " & event.actorLabel & " respawned (" &
      $event.livesLeft & (
        if event.livesLeft == 1:
          " life left"
        else:
          " lives left"
      ) & ")"
  of ScoreChanged:
    "  score player " & event.actorLabel & " " & scoreAmountText(event.scoreAmount)
  of ItemPickup:
    "  player " & event.actorLabel & " picked up a " & event.item
  of ItemUse:
    case event.item
    of "grenade":
      "  player " & event.actorLabel & " threw a grenade"
    of "med kit":
      "  player " & event.actorLabel & " healed with a med kit"
    of "plasma arc":
      "  player " & event.actorLabel & " fired a plasma arc"
    else:
      "  player " & event.actorLabel & " used a " & event.item
  of ItemRespawn:
    "  a " & event.item & " respawned"
  of GameOver:
    case event.endReason
    of "capture":
      "  game over: " & teamText(event.winner) & " wins by capture"
    of "wipe":
      "  game over: " & teamText(event.winner) & " wins by wipe"
    of "time_limit":
      "  game over: time-limit draw"
    of "mutual_wipe":
      "  game over: mutual wipe"
    else:
      if event.isDraw:
        "  game over: draw"
      else:
        "  game over: " & teamText(event.winner) & " wins"

proc jsonRow*(event: ReplayEvent): JsonNode =
  ## Returns one event-log JSON row for a replay event.
  var value = newJObject()
  case event.kind
  of PlayerJoined:
    value["label"] = %event.actorLabel
  of PhaseChanged:
    value["phase"] = %($event.phase)
  of Kill:
    value["victim_slot"] = %event.secondarySlot
    value["victim_label"] = %event.secondaryLabel
    value["lives_left"] = %event.livesLeft
  of FlagSteal, Capture:
    value["label"] = %event.actorLabel
    value["flag"] = %teamText(event.flagTeam)
  of Shot, Hit:
    value["label"] = %event.actorLabel
  of Respawn:
    value["label"] = %event.actorLabel
    value["lives_left"] = %event.livesLeft
  of FlagReturnHome:
    value["flag"] = %teamText(event.flagTeam)
  of ScoreChanged:
    value["amount"] = %event.scoreAmount
  of ItemPickup, ItemUse:
    value["label"] = %event.actorLabel
    value["item"] = %event.item
    if event.kind == ItemUse and event.scoreAmount != 0:
      value["amount"] = %event.scoreAmount
  of ItemRespawn:
    value["item"] = %event.item
  of GameOver:
    value["draw"] = %event.isDraw
    value["end_reason"] = %event.endReason
    if not event.isDraw:
      value["winner"] = %teamText(event.winner)

  result = newJObject()
  result["ts"] = %event.tick
  result["player"] = %event.actorSlot
  result["key"] = %event.key()
  result["value"] = value

proc eventsAt(timeline: ReplayTimeline, tick: int): seq[ReplayEvent] =
  ## Returns timeline events for one tick in their recorded order.
  for event in timeline.events:
    if event.tick == tick:
      result.add(event)

proc expandReplayTimeline*(data: ReplayData): ReplayTimeline =
  ## Expands one replay into a structured CTF event timeline.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    var
      sim = initSimServer(data.replayConfig())
      replay = initReplayPlayer(data)
      track: TrackState
      phase = sim.phase
      prevCarriers: array[Team, int]
    for team in Team:
      prevCarriers[team] = sim.flags[team].carrier

    sim.gameEventLoggingEnabled = false
    replay.looping = false
    replay.mismatchQuit = true

    while replay.playing:
      let tick = sim.tickCount + 1
      result.tickCount = tick
      try:
        replay.stepReplay(sim)
      except ReplayError:
        result.hashFailed = true
        result.failTick = tick
        return

      let
        phaseChanged = phase != sim.phase
        newPhase = sim.phase

      sim.syncPlayers(tick, result.events, track)
      sim.printShots(tick, result.events, track)
      sim.printItems(tick, result.events, track)
      sim.printItemSpawns(tick, result.events, track)
      sim.printKillsAndDeaths(tick, result.events, track)
      sim.printFlagChanges(tick, result.events, prevCarriers)
      sim.printCaptures(tick, result.events, track)
      sim.printScoreChanges(tick, result.events, track)

      ## Emit phase / game-over after same-tick kills and captures so the
      ## finishing blow reads before the match result.
      if phaseChanged:
        result.events.add ReplayEvent(
          tick: tick,
          kind: PhaseChanged,
          actorSlot: -1,
          secondarySlot: -1,
          phase: newPhase
        )
        if newPhase == GameOver:
          result.events.add ReplayEvent(
            tick: tick,
            kind: GameOver,
            actorSlot: -1,
            secondarySlot: -1,
            phase: newPhase,
            winner: sim.winner,
            isDraw: sim.isDraw,
            endReason: sim.gameEndReason()
          )
        phase = newPhase
  finally:
    setCurrentDir(previousDir)

proc expandReplay(path: string) {.used.} =
  ## Prints one readable replay timeline.
  if not fileExists(path):
    fail("Replay file does not exist: " & path)

  let data = loadReplay(path)
  let timeline = expandReplayTimeline(data)

  echo "replay ", path
  for tick in 1 .. timeline.tickCount:
    let events = timeline.eventsAt(tick)
    if events.len == 0:
      continue
    echo "tick ", tick
    for event in events:
      echo event.text()
    if timeline.hashFailed and tick == timeline.failTick:
      echo "  hash failed"
      fail("hash failed")
  echo "done"

when isMainModule:
  try:
    expandReplay(replayPathFromArgs())
  except ExpandReplayError as e:
    if e.msg != "hash failed":
      stderr.writeLine("expand_replay failed: " & e.msg)
    quit(1)
  except ReplayError as e:
    stderr.writeLine("expand_replay replay error: " & e.msg)
    quit(1)
  except CtfError as e:
    stderr.writeLine("expand_replay sim error: " & e.msg)
    quit(1)
