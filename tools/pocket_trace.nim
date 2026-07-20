import std/[os, strformat, math], ../src/ctf/replays, ../src/ctf/sim

# Re-simulates a replay and reports the OFFENSE-PENETRATION mechanism metric
# tempo-004 cares about: for each team, the minimum distance any ALIVE attacker
# reaches to the ENEMY pedestal, the peak count of attackers within 220px of it,
# and steals/captures per team + the winner. Sampled every SampleEvery ticks.
#
#   nim r tools/pocket_trace.nim <replay.json>

const
  SampleEvery = 50
  PocketRadius = 220.0

let path = commandLineParams()[0]
let gameDir = currentSourcePath().parentDir().parentDir()
setCurrentDir(gameDir)
let data = loadReplay(path)
var config = defaultGameConfig()
config.update(data.configJson)
var
  game = initSimServer(config)
  replay = initReplayPlayer(data)
game.gameEventLoggingEnabled = false
replay.looping = false
replay.mismatchQuit = true

proc enemy(t: Team): Team = (if t == Red: Blue else: Red)

var
  minDist: array[Team, float] = [1e18, 1e18]
  maxWithin: array[Team, int] = [0, 0]
  steals: array[Team, int] = [0, 0]
  prevCarrier: array[Team, int] = [-1, -1]   # carrier of flags[home]
  tick = 0

while replay.playing:
  replay.stepReplay(game)
  inc tick
  # steal detection: flags[homeTeam].carrier goes -1 -> a player of enemy(homeTeam)
  for homeTeam in [Red, Blue]:
    let c = game.flags[homeTeam].carrier
    if c >= 0 and prevCarrier[homeTeam] < 0:
      let robber = game.players[c].team
      inc steals[robber]
    prevCarrier[homeTeam] = c
  if tick mod SampleEvery == 0:
    for team in [Red, Blue]:
      let ped = game.gameMap.flagHome(enemy(team))
      var within = 0
      for p in game.players:
        if p.team != team or not p.alive:
          continue
        let d = hypot(float(p.x - ped.x), float(p.y - ped.y))
        if d < minDist[team]: minDist[team] = d
        if d < PocketRadius: inc within
      if within > maxWithin[team]: maxWithin[team] = within

var caps: array[Team, int] = [0, 0]
var aliveEnd: array[Team, int] = [0, 0]
for p in game.players:
  caps[p.team] += p.captures
  if p.alive: inc aliveEnd[p.team]

let winner =
  if caps[Red] > caps[Blue]: "Red"
  elif caps[Blue] > caps[Red]: "Blue"
  elif aliveEnd[Red] != aliveEnd[Blue]: (if aliveEnd[Red] > aliveEnd[Blue]: "Red(lives)" else: "Blue(lives)")
  else: "draw?"

echo &"ticks={tick} winner={winner}"
for team in [Red, Blue]:
  echo &"  {team}: minDistToPocket={minDist[team]:.0f} maxWithin220={maxWithin[team]} steals={steals[team]} captures={caps[team]} aliveEnd={aliveEnd[team]}"
