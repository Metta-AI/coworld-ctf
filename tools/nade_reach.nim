## NADE REACH — the counterfactual for the pickup fix, measured on a real
## hosted replay: how often does one of OUR bots stand within the pickup detour
## of an ARMED corner spawn and walk away without taking it?
##
## Reads the SAME static coords the engine uses (grenadeSpawnPoints) and the
## SAME detour the policy allows (90px), then reports, per team:
##   nearArmed   — bot-frames within detour of a corner that is currently armed
##   nearEpisodes— distinct (bot, corner, armed-window) approaches
##   tookIt      — approaches that ended in a pickup
##   walkedPast  — approaches that did NOT (the recoverable supply)
##
## A large walkedPast with a small tookIt says the grenade deficit is a ROUTING
## problem, not a supply or contest problem: the ammo was in reach and ignored.
##
## Usage: nade_reach <replay-path> --us=red|blue [--tag=name] [--detour=90]

import std/[json, os, strutils]
import ../src/ctf/replays
import ../src/ctf/sim

let params = commandLineParams()
if params.len < 1: quit("usage: nade_reach <replay> --us=red|blue")
var
  replayPath = ""
  usTeamText = "red"
  tag = ""
  detour = 90.0
for p in params:
  if p.startsWith("--us="): usTeamText = p[5 .. ^1]
  elif p.startsWith("--tag="): tag = p[6 .. ^1]
  elif p.startsWith("--detour="): detour = parseFloat(p[9 .. ^1])
  elif not p.startsWith("--"): replayPath = p.absolutePath()

setCurrentDir(currentSourcePath().parentDir().parentDir())
let data = loadReplay(replayPath)
var config = defaultGameConfig()
config.update(data.configJson)
var
  game = initSimServer(config)
  replay = initReplayPlayer(data)
game.gameEventLoggingEnabled = false
replay.looping = false
replay.mismatchQuit = true

let corners = grenadeSpawnPoints()
let detourSq = detour * detour

var
  nearFrames: array[2, int]
  approaches: array[2, int]
  tookIt: array[2, int]
  walkedPast: array[2, int]
  # per (player, corner): are we currently inside an approach?
  inApproach: array[16, array[4, bool]]
  prevHasNade: array[16, bool]
  nPlayers = 0

proc ti(t: Team): int = (if t == Red: 0 else: 1)
let usIdx = (if usTeamText == "red": 0 else: 1)

while replay.playing:
  replay.stepReplay(game)
  if game.players.len > nPlayers:
    let grown = min(game.players.len, 16)
    for i in nPlayers ..< grown: prevHasNade[i] = game.players[i].hasGrenade
    nPlayers = grown

  for i in 0 ..< nPlayers:
    let p = game.players[i]
    let team = ti(p.team)
    let justPicked = p.hasGrenade and not prevHasNade[i]
    for c in 0 ..< corners.len:
      let
        dx = float(p.x + CollisionW div 2 - corners[c].x)
        dy = float(p.y + CollisionH div 2 - corners[c].y)
        near = p.alive and not p.hasGrenade and
          game.grenadeSpawns[c].present and (dx*dx + dy*dy) <= detourSq
      if near:
        inc nearFrames[team]
        if not inApproach[i][c]:
          inApproach[i][c] = true
          inc approaches[team]
      elif inApproach[i][c]:
        # the approach ended: did it convert?
        inApproach[i][c] = false
        if justPicked: inc tookIt[team]
        else: inc walkedPast[team]
    prevHasNade[i] = p.hasGrenade

proc j(t: int): JsonNode =
  %*{"nearFrames": nearFrames[t], "approaches": approaches[t],
     "tookIt": tookIt[t], "walkedPast": walkedPast[t]}

echo $(%*{"tag": tag, "replay": replayPath.extractFilename,
  "ticks": game.tickCount, "detour": detour,
  "us": j(usIdx), "them": j(1 - usIdx)})
