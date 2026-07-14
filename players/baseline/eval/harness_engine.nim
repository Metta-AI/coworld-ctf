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
    redCaptures*: int
    blueCaptures*: int
    redShots*: int                   ## fresh tracers credited to Red shooters.
    blueShots*: int
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

proc playerCount*(engine: EvalEngine): int =
  engine.sim.players.len

proc teamOfSlot*(engine: EvalEngine, slot: int): int =
  ## 0 Red / 1 Blue, read straight off the seated player.
  ord(engine.sim.players[slot].team)

proc isPlaying*(engine: EvalEngine): bool =
  engine.sim.phase == Playing

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
  for i in 0 ..< sim.players.len:
    let p = sim.players[i]
    let team = ord(p.team)
    result.slots.add SlotStat(
      slot: i, team: team, kills: p.kills, deaths: p.deaths,
      captures: p.captures, lives: p.lives, alive: p.alive)
    if team == 0:
      result.redKills += p.kills
      result.redCaptures += p.captures
    else:
      result.blueKills += p.kills
      result.blueCaptures += p.captures
