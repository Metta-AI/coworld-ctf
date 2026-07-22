import std/[os, json, strutils], ../src/ctf/replays, ../src/ctf/sim

# Re-simulates a replay and emits a JSON record for side-asymmetry forensics:
# deaths with positions + killer attribution, periodic samples, summaries.

let path = commandLineParams()[0].absolutePath()
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

var
  prevAlive: array[16, bool]
  prevKills: array[16, int]
  prevX, prevY: array[16, int]
  deaths = newJArray()
  samples = newJArray()
  joins = newJArray()
  seenPlayers = 0

while replay.playing:
  replay.stepReplay(game)
  let t = game.tickCount
  while seenPlayers < game.players.len and seenPlayers < 16:
    let p = game.players[seenPlayers]
    joins.add(%*{"i": seenPlayers, "slot": p.joinOrder, "team": teamText(p.team),
                 "addr": p.address})
    prevAlive[seenPlayers] = p.alive
    inc seenPlayers
  # killer this tick: the single player whose kill count went up
  var killer = -1
  var killerCount = 0
  for i in 0 ..< min(game.players.len, 16):
    if game.players[i].kills > prevKills[i]:
      inc killerCount
      killer = i
  if killerCount != 1: killer = -1
  for i in 0 ..< min(game.players.len, 16):
    let p = game.players[i]
    if prevAlive[i] and not p.alive:
      var rec = %*{"t": t, "i": i, "slot": p.joinOrder, "team": teamText(p.team),
                   "x": prevX[i], "y": prevY[i]}
      if killer >= 0:
        rec["k"] = %killer
        rec["kx"] = %prevX[killer]
        rec["ky"] = %prevY[killer]
      deaths.add(rec)
    prevAlive[i] = p.alive
    if p.alive:
      prevX[i] = p.x
      prevY[i] = p.y
  for i in 0 ..< min(game.players.len, 16):
    prevKills[i] = game.players[i].kills
  if t mod 20 == 0:
    var row = newJArray()
    for i in 0 ..< min(game.players.len, 16):
      let p = game.players[i]
      row.add(%*[p.x, p.y, (if p.alive: 1 else: 0)])
    samples.add(%*{"t": t, "p": row})

var summary = newJArray()
for i in 0 ..< min(game.players.len, 16):
  let p = game.players[i]
  summary.add(%*{"i": i, "slot": p.joinOrder, "team": teamText(p.team),
                 "kills": p.kills, "deaths": p.deaths, "captures": p.captures,
                 "fired": p.shotsFired, "hit": p.shotsHit, "addr": p.address})
echo $(%*{"ticks": game.tickCount, "joins": joins, "deaths": deaths,
          "samples": samples, "summary": summary})
