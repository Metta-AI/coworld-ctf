## NADE FUNNEL — re-simulates one hosted .replay and measures, PER TEAM, every
## stage of the grenade loop end to end:
##
##   available  → a corner pickup was present and reachable at all
##   picked     → hasGrenade went false->true (the pickup relay fired)
##   heldTicks  → total ticks carried (dead time between pick and throw)
##   thrown     → throwCharge released into an AirborneGrenade
##   charge     → the release charge (0..24) => the planned throw distance
##   landed     → the burst resolved
##   damaged    → enemies inside the 52px blast at landing (blast damage events)
##   killed     → blast kills
##   wasted     → landings that damaged NOBODY (the aim/timing leak)
##   selfHit    → own-team bodies caught in our own blast (friendly fire)
##   lostOnDeath→ carried a grenade into death without throwing it (the HOARD leak)
##
## Every stage is read straight off the sim, so the funnel is ground truth for
## the hosted match: it cannot disagree with what the league actually scored.
## Which team is ours is passed in by --us=<red|blue> (resolved from the
## episode's participant slots by the caller).
##
## Usage: nade_funnel <replay-path> --us=red|blue [--tag=name]

import std/[json, math, os, strutils, tables]
import ../src/ctf/replays
import ../src/ctf/sim

let params = commandLineParams()
if params.len < 1:
  quit("usage: nade_funnel <replay> --us=red|blue [--tag=name]")

var
  replayPath = ""
  usTeamText = "red"
  tag = ""
for p in params:
  if p.startsWith("--us="): usTeamText = p[5 .. ^1]
  elif p.startsWith("--tag="): tag = p[6 .. ^1]
  elif not p.startsWith("--"): replayPath = p.absolutePath()

let gameDir = currentSourcePath().parentDir().parentDir()
setCurrentDir(gameDir)

let data = loadReplay(replayPath)
var config = defaultGameConfig()
config.update(data.configJson)

var
  game = initSimServer(config)
  replay = initReplayPlayer(data)
game.gameEventLoggingEnabled = false
game.collectEvents = true
replay.looping = false
replay.mismatchQuit = true

type
  Funnel = object
    picked: int
    thrown: int
    landed: int
    chargeSum: int
    throwDistSum: int
    heldTicks: int
    lostOnDeath: int
    dmgEvents: int          # blast Damage events landed on the OTHER team
    dmgAmount: int
    selfHitEvents: int      # blast Damage on our own team (incl. thrower)
    kills: int
    wastedLandings: int     # a landing that hit nobody at all
    multiHitLandings: int   # a landing that hit 2+ enemies
    # timing: which tick-bucket the throws happen in
    thrownEarly: int        # tick < 1000
    thrownMid: int          # 1000..3000  <- the phase we lose
    thrownLate: int         # > 3000

var
  fun: array[2, Funnel]     # index by team ord
  prevHasNade: array[16, bool]
  prevAlive: array[16, bool]
  # airborne key -> (thrower, tick, dist)
  live = initTable[int, tuple[thrower, launch, dist: int]]()
  pickupPresentTicks: array[4, int]
  nPlayers = 0
  # per-landing damage accumulation, keyed by thrower slot
  landingDmg = initTable[int, tuple[enemies, mates, dmg, kills: int]]()

proc teamIdx(t: Team): int = (if t == Red: 0 else: 1)

let usIdx = (if usTeamText == "red": 0 else: 1)

while replay.playing:
  # Drain events emitted by the step we are about to take, after stepping.
  let preTick = game.tickCount
  replay.stepReplay(game)
  let t = game.tickCount
  # Players JOIN over the opening ticks, so the roster has to grow with them —
  # latching the count on the first non-empty tick silently truncates every
  # per-player stage (and undercounts picks below throws, an impossible funnel).
  if game.players.len > nPlayers:
    let grown = min(game.players.len, 16)
    for i in nPlayers ..< grown:
      prevHasNade[i] = game.players[i].hasGrenade
      prevAlive[i] = game.players[i].alive
    nPlayers = grown

  for i in 0 ..< game.grenadeSpawns.len:
    if game.grenadeSpawns[i].present: inc pickupPresentTicks[i]

  # ── stage: picked / held / lostOnDeath
  for i in 0 ..< nPlayers:
    let p = game.players[i]
    let ti = teamIdx(p.team)
    if p.hasGrenade and not prevHasNade[i]:
      inc fun[ti].picked
    if p.hasGrenade:
      inc fun[ti].heldTicks
    # died while holding one (and no throw this tick => it was simply lost)
    if prevAlive[i] and not p.alive and prevHasNade[i] and not p.hasGrenade:
      var threwThisTick = false
      for g in game.airborneGrenades:
        if g.thrower == i and g.launchTick >= preTick: threwThisTick = true
      if not threwThisTick: inc fun[ti].lostOnDeath
    prevHasNade[i] = p.hasGrenade
    prevAlive[i] = p.alive

  # ── stage: thrown  (a new airborne grenade appeared)
  var cur = initTable[int, tuple[thrower, launch, dist: int]]()
  for g in game.airborneGrenades:
    let key = g.launchTick * 100 + g.thrower
    let dx = g.tx - g.sx
    let dy = g.ty - g.sy
    let d = int(sqrt(float(dx*dx + dy*dy)))
    cur[key] = (g.thrower, g.launchTick, d)
    if key notin live:
      let ti = teamIdx(game.players[g.thrower].team)
      inc fun[ti].thrown
      fun[ti].throwDistSum += d
      fun[ti].chargeSum += 0   # charge already consumed; distance stands in
      if g.launchTick < 1000: inc fun[ti].thrownEarly
      elif g.launchTick <= 3000: inc fun[ti].thrownMid
      else: inc fun[ti].thrownLate

  # ── stage: landed — a key that vanished burst on THIS tick, and the sim
  # emitted its Damage/Kill events into the collected stream during this step.
  var landedThisTick: seq[tuple[thrower, launch, dist: int]] = @[]
  for key, v in live:
    if key notin cur: landedThisTick.add v
  live = cur

  # Read the tier-2 event stream for grenade attribution (authoritative: the
  # sim tags weapon="grenade" on exactly the blast damage/kills).
  landingDmg.clear()
  for ev in game.events:
    if ev.weapon != "grenade": continue
    let src = ev.source
    if src < 0 or src >= nPlayers: continue
    let ti = teamIdx(game.players[src].team)
    var acc = landingDmg.getOrDefault(src)
    case ev.kind
    of Damage:
      let sameTeam = ev.target >= 0 and ev.target < nPlayers and
        game.players[ev.target].team == game.players[src].team
      if sameTeam:
        inc fun[ti].selfHitEvents
        inc acc.mates
      else:
        inc fun[ti].dmgEvents
        fun[ti].dmgAmount += ev.amount
        inc acc.enemies
        acc.dmg += ev.amount
    of Kill:
      inc fun[ti].kills
      inc acc.kills
    else: discard
    landingDmg[src] = acc
  game.events.setLen(0)

  for l in landedThisTick:
    let ti = teamIdx(game.players[l.thrower].team)
    inc fun[ti].landed
    let acc = landingDmg.getOrDefault(l.thrower)
    if acc.enemies == 0 and acc.mates == 0: inc fun[ti].wastedLandings
    elif acc.enemies >= 2: inc fun[ti].multiHitLandings

proc j(f: Funnel): JsonNode =
  %*{
    "picked": f.picked, "thrown": f.thrown, "landed": f.landed,
    "heldTicks": f.heldTicks, "lostOnDeath": f.lostOnDeath,
    "dmgEvents": f.dmgEvents, "dmgAmount": f.dmgAmount,
    "selfHitEvents": f.selfHitEvents, "kills": f.kills,
    "wasted": f.wastedLandings, "multiHit": f.multiHitLandings,
    "throwDistSum": f.throwDistSum,
    "thrownEarly": f.thrownEarly, "thrownMid": f.thrownMid,
    "thrownLate": f.thrownLate,
  }

var pickupPresent = 0
for v in pickupPresentTicks: pickupPresent += v

# Whole-team totals so the funnel can be read against the match outcome.
var caps, tkills, tdeaths: array[2, int]
for i in 0 ..< nPlayers:
  let ti = teamIdx(game.players[i].team)
  caps[ti] += game.players[i].captures
  tkills[ti] += game.players[i].kills
  tdeaths[ti] += game.players[i].deaths

echo $(%*{
  "tag": tag, "replay": replayPath.extractFilename, "ticks": game.tickCount,
  "us": usTeamText,
  "usFunnel": j(fun[usIdx]), "themFunnel": j(fun[1 - usIdx]),
  "pickupPresentTicks": pickupPresent,
  "usCaps": caps[usIdx], "themCaps": caps[1 - usIdx],
  "usKills": tkills[usIdx], "themKills": tkills[1 - usIdx],
  "usDeaths": tdeaths[usIdx], "themDeaths": tdeaths[1 - usIdx],
})
