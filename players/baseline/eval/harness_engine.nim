## Headless in-process CTF engine wrapper for the eval / A-B harness.
##
## This module OWNS the engine types (SimServer, InputState, PlayerViewerState)
## and exposes only a primitive-typed surface: `string` packet blobs out,
## `uint8` button masks in, plain ints out for the scoreboard. That keeps the
## engine's `Team`/`enemy`/`flagHome` symbols from ever colliding with the
## baseline bot module (which declares its own `Team`, `enemy`, `flagHome`),
## so the driver can `include` the baseline verbatim and drive its BYTE-
## IDENTICAL decision path with zero edits to the shipped player.
##
## Fidelity contract (matches src/ctf/server.nim's live loop exactly):
##   * one sprite packet built per player per tick via
##     `buildSpriteProtocolPlayerUpdates` (real FOV/fog culling + delete-diffs),
##     so a per-slot `PlayerViewerState` MUST persist across ticks or the
##     bot's retained scene never sheds objects that left its vision;
##   * `sim.step(inputs, prevInputs)` with the bot's own level masks decoded
##     through `decodeInputMask` — a fresh A-press (attack and not prev.attack)
##     arms the 5-tick windup, exactly as the baseline self-pulses fire.

import
  std/[strutils],
  bitworld/spriteprotocol,
  ctf/sim,
  ctf/global

export spriteprotocol.InputState, spriteprotocol.decodeInputMask

type
  EvalEngine* = ref object
    sim: SimServer
    viewers: seq[PlayerViewerState]  ## one retained viewer state per slot.
    prevInputs: seq[InputState]      ## last tick's decoded inputs (fire edge).
    curInputs: seq[InputState]       ## this tick's decoded inputs.
    redShots: int                    ## fresh tracers, tallied per tick.
    blueShots: int
    redHits: int                     ## shots that LANDED on a body (a "-1" damage
    blueHits: int                    ## pop, amount 1), credited to the SHOOTING team
                                     ## (= enemy of the victim's color; friendly-fire
                                     ## hits are negligible under the friendlyBlocked
                                     ## guard). redHits/redShots = our aim accuracy —
                                     ## the "we shoot the wall, daveey lands on the
                                     ## body" complaint, measured directly.
    redGrabs: int                    ## flag pickups (steals) credited per team,
    blueGrabs: int                   ## by watching flags[*].carrier transitions.
    prevCarrier: array[Team, int]    ## last tick's carrier index per flag.
    lastCarrierProg: array[Team, float]  ## carrier's fraction-of-map progress
                                     ## toward its capture edge, updated each tick.
    dropProgSum: array[Team, float]  ## Σ progress at which non-scoring drops
    dropCount: array[Team, int]      ## happened, per STEALING team (for the mean).
    grabTick: array[Team, int]       ## tick this flag was last grabbed off its
                                     ## pedestal (-1 when home), to age the run.
    survivalSum: array[Team, int]    ## Σ ticks a carrier lived after grabbing
    survivalCount: array[Team, int]  ## before a non-scoring death, per stealer.

  SlotStat* = object
    slot*: int
    team*: int                       ## 0 = Red, 1 = Blue.
    kills*: int
    deaths*: int
    captures*: int
    lives*: int
    alive*: bool

  EpisodeResult* = object
    ticks*: int
    phaseOver*: bool
    winnerTeam*: int                 ## 0 Red, 1 Blue, -1 draw / unfinished.
    isDraw*: bool
    redKills*: int
    blueKills*: int
    redDeaths*: int                  ## deaths taken by each team; the lives
    blueDeaths*: int                 ## differential (kills-deaths) is the tiebreak.
    redLives*: int                   ## total lives remaining at game end
    blueLives*: int                  ## (Σ lives + 1 per still-alive player).
    redCaptures*: int
    blueCaptures*: int
    redShots*: int                   ## fresh tracers credited to Red shooters.
    blueShots*: int
    redHits*: int                    ## bullets that LANDED per team; redHits/redShots
    blueHits*: int                   ## is aim accuracy (the wall-vs-body miss metric).
    redGrabs*: int                   ## enemy-flag pickups by each team; the
    blueGrabs*: int                  ## grab->capture ratio is the conversion metric.
    redDropProgSum*: float           ## Σ progress-home (0..1) at each non-scoring
    blueDropProgSum*: float          ## carrier death, per stealing team, and the
    redDropCount*: int               ## count — mean = where the run home breaks.
    blueDropCount*: int
    redSurvivalSum*: int             ## Σ ticks a carrier lived after grabbing
    blueSurvivalSum*: int            ## before a non-scoring death (mean = how
    redSurvivalCount*: int           ## fast the grab is a death sentence; a
    blueSurvivalCount*: int          ## few ticks = dies IN the nest, not en route).
    slots*: seq[SlotStat]

proc newEvalEngine*(numPlayers: int, seed: int, maxTicks: int): EvalEngine =
  ## Builds a started headless game with `numPlayers` baseline-seatable slots.
  ## Seat i -> team (i mod 2): even Red, odd Blue, matching the live default.
  var config = defaultGameConfig()
  config.seed = seed
  config.maxTicks = maxTicks
  config.maxGames = 0                # never auto-quit; harness owns the loop.
  result = EvalEngine(sim: initSimServer(config))
  result.sim.gameEventLoggingEnabled = false  # keep the run quiet (a SimServer
                                              # field, defaults true post-init).
  for i in 0 ..< numPlayers:
    discard result.sim.addPlayer("bot" & $i, trusted = true)
  result.sim.startGame()
  result.viewers = newSeq[PlayerViewerState](numPlayers)
  for i in 0 ..< numPlayers:
    result.viewers[i] = initPlayerViewerState()
  result.prevInputs = newSeq[InputState](numPlayers)
  result.curInputs = newSeq[InputState](numPlayers)
  for team in Team:
    result.prevCarrier[team] = -1
    result.grabTick[team] = -1

proc playerCount*(engine: EvalEngine): int =
  engine.sim.players.len

proc teamOfSlot*(engine: EvalEngine, slot: int): int =
  ## 0 Red / 1 Blue, read straight off the seated player.
  ord(engine.sim.players[slot].team)

proc isPlaying*(engine: EvalEngine): bool =
  engine.sim.phase == Playing

when defined(ohshitprobe):
  import std/math
  proc nearestEnemyMate*(engine: EvalEngine, slot: int): tuple[e, m: float] =
    ## Ground-truth nearest living enemy / mate distance to `slot` (probe only).
    let me = engine.sim.players[slot]
    var nE = 1e9
    var nM = 1e9
    for j in 0 ..< engine.sim.players.len:
      if j == slot or not engine.sim.players[j].alive: continue
      let q = engine.sim.players[j]
      let dd = sqrt(float((me.x - q.x) * (me.x - q.x) +
                          (me.y - q.y) * (me.y - q.y)))
      if q.team == me.team:
        if dd < nM: nM = dd
      else:
        if dd < nE: nE = dd
    (e: nE, m: nM)

when defined(ssprobe):
  # v7-only: count accidental sword/shield possession (auto-disarm). The
  # hasSword/hasShield fields exist only on the GameVersion 7 engine, so this
  # accessor compiles ONLY in the v7 worktree under -d:ssprobe.
  proc swordShieldOf*(engine: EvalEngine, slot: int):
      tuple[sword, shield, alive: bool] =
    let p = engine.sim.players[slot]
    (sword: p.hasSword, shield: p.hasShield, alive: p.alive)

proc frameFor*(engine: EvalEngine, slot: int): string =
  ## The exact sprite packet blob the live server would send this slot this
  ## tick: real fogged view, delta-encoded against the slot's retained viewer.
  var nextState: PlayerViewerState
  let packet = engine.sim.buildSpriteProtocolPlayerUpdates(
    slot, engine.viewers[slot], nextState)
  engine.viewers[slot] = nextState
  blobFromBytes(packet)

proc setMask*(engine: EvalEngine, slot: int, mask: uint8) =
  ## Records one bot's chosen button mask for the pending step.
  engine.curInputs[slot] = decodeInputMask(mask)

proc applyShout*(engine: EvalEngine, slot: int, text: string) =
  ## Registers one bot's shout into the sim exactly as the live server does:
  ## the server buffers each player's chat during the tick window and calls
  ## `sim.applyShout(playerIndex, chatText)` for every one just before
  ## `sim.step` (server.nim ~1015-1026). The sim enforces the alive-only,
  ## one-per-second, one-bubble-per-player rules; the shout lands in
  ## `recentShouts` and is delivered to every audible viewer on the NEXT
  ## frame build — so a bot hears a mate's shout the frame after it is made,
  ## matching the hosted timing the reaction logic was tuned against.
  engine.sim.applyShout(slot, text)

proc advance*(engine: EvalEngine) =
  ## Steps the sim one tick with the recorded masks, then rolls the fire edge.
  ## A shot's tracer is stamped with the tick it fired, so tallying tracers
  ## whose firedTick == the just-completed tick counts every shot released
  ## this step exactly once (recentShots is pruned only after ShotFxTicks).
  engine.sim.step(engine.curInputs, engine.prevInputs)
  for i in 0 ..< engine.prevInputs.len:
    engine.prevInputs[i] = engine.curInputs[i]
  let firedTick = engine.sim.tickCount
  for shot in engine.sim.recentShots:
    if shot.firedTick == firedTick:
      if shot.color == teamColor(Red): inc engine.redShots
      elif shot.color == teamColor(Blue): inc engine.blueShots
  # Gun-hit tally: a fresh "-1" damage pop (amount 1 = a bullet, not the amount-2
  # grenade blast) landed on a body THIS tick. Credit the SHOOTER = the enemy of
  # the victim's color, so redHits counts Red's bullets that connected. Paired
  # with redShots this is the direct aim-accuracy signal.
  for pop in engine.sim.damagePops:
    if pop.tick == firedTick and pop.amount == 1:
      if pop.color == teamColor(Red): inc engine.blueHits    # Red victim -> Blue shot
      elif pop.color == teamColor(Blue): inc engine.redHits
  # Flag-grab tally + drop-location diagnosis. A carrier index rising from -1
  # to a live player is a fresh steal; credit the STEALING team (a flag is
  # stolen by the opposing team, so flagTeam Blue -> a Red grab). A carrier
  # falling to -1 while the game is still Playing is a NON-SCORING DROP (the
  # carrier was killed en route — a capture instead ends the game with the
  # carrier still set), so we log how far home it had gotten: 0.0 = dropped at
  # the enemy pedestal it just robbed, 1.0 = at its own capture edge. The mean
  # drop-progress tells us WHERE the run home breaks down.
  let stillPlaying = engine.sim.phase == Playing
  for team in Team:
    let carrier = engine.sim.flags[team].carrier
    # Update this carrier's progress-home while it holds the flag.
    if carrier >= 0:
      let
        stealer = enemy(team)
        startX = engine.sim.gameMap.flagHome(team).x.float     # robbed pedestal
        endX = engine.sim.gameMap.flagHome(stealer).x.float    # own home edge
        flagX = engine.sim.flags[team].x.float
        span = (if startX != endX: startX - endX else: 1.0)
      engine.lastCarrierProg[team] = clamp((startX - flagX) / span, 0.0, 1.0)
    if carrier >= 0 and engine.prevCarrier[team] < 0:
      engine.grabTick[team] = engine.sim.tickCount    # start the survival clock
      if team == Blue: inc engine.redGrabs else: inc engine.blueGrabs
    elif carrier < 0 and engine.prevCarrier[team] >= 0 and stillPlaying:
      # Non-scoring drop: attribute the failed run to the stealing team.
      let lived = engine.sim.tickCount - engine.grabTick[team]
      if team == Blue:
        engine.dropProgSum[Red] += engine.lastCarrierProg[team]
        inc engine.dropCount[Red]
        engine.survivalSum[Red] += lived
        inc engine.survivalCount[Red]
      else:
        engine.dropProgSum[Blue] += engine.lastCarrierProg[team]
        inc engine.dropCount[Blue]
        engine.survivalSum[Blue] += lived
        inc engine.survivalCount[Blue]
    engine.prevCarrier[team] = carrier

proc result*(engine: EvalEngine): EpisodeResult =
  ## Snapshots the scoreboard from live sim fields (all authoritative — the
  ## same counters the hosted results JSON is built from).
  let sim = engine.sim
  result.ticks = sim.tickCount
  result.phaseOver = sim.phase == GameOver
  result.isDraw = sim.isDraw
  result.winnerTeam =
    if not result.phaseOver or sim.isDraw: -1
    else: ord(sim.winner)
  result.redShots = engine.redShots
  result.blueShots = engine.blueShots
  result.redHits = engine.redHits
  result.blueHits = engine.blueHits
  result.redGrabs = engine.redGrabs
  result.blueGrabs = engine.blueGrabs
  result.redDropProgSum = engine.dropProgSum[Red]
  result.blueDropProgSum = engine.dropProgSum[Blue]
  result.redDropCount = engine.dropCount[Red]
  result.blueDropCount = engine.dropCount[Blue]
  result.redSurvivalSum = engine.survivalSum[Red]
  result.blueSurvivalSum = engine.survivalSum[Blue]
  result.redSurvivalCount = engine.survivalCount[Red]
  result.blueSurvivalCount = engine.survivalCount[Blue]
  for i in 0 ..< sim.players.len:
    let p = sim.players[i]
    let team = ord(p.team)
    result.slots.add SlotStat(
      slot: i, team: team, kills: p.kills, deaths: p.deaths,
      captures: p.captures, lives: p.lives, alive: p.alive)
    let livesNow = p.lives + (if p.alive: 1 else: 0)
    if team == 0:
      result.redKills += p.kills
      result.redDeaths += p.deaths
      result.redLives += livesNow
      result.redCaptures += p.captures
    else:
      result.blueKills += p.kills
      result.blueDeaths += p.deaths
      result.blueLives += livesNow
      result.blueCaptures += p.captures
