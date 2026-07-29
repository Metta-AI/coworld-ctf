import std/[os, strformat, strutils, math], ../src/ctf/replays, ../src/ctf/sim

# Fine carrier trace: every SampleEvery ticks, for any live flag carrier, print
# its pos, its velocity magnitude (moved since last sample), distance to its OWN
# capture edge (home), and the nearest enemy distance + whether that enemy has
# LOS-ish bearing. Highlights a carrier that stalls, backtracks, or fights.

const SampleEvery = 15

let path = commandLineParams()[0]
let startT = if paramCount() >= 2: parseInt(commandLineParams()[1]) else: 0
let endT = if paramCount() >= 3: parseInt(commandLineParams()[2]) else: 99999
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

proc px(v: int): int = v   # sim .x/.y accessors are already map pixels

var lastPos: array[16, (int,int)]
var tick = 0
while replay.playing:
  replay.stepReplay(game)
  inc tick
  if tick < startT or tick > endT: continue
  if tick mod SampleEvery != 0: continue
  for team in [Red, Blue]:
    let c = game.flags[team].carrier
    if c < 0: continue
    let p = game.players[c]
    let cx = px(p.x); let cy = px(p.y)
    # own capture edge: Red captures at left (x small), Blue at right (x large)
    let homeX = if p.team == Red: 60 else: 1175
    let distHome = abs(cx - homeX)
    let (lx, ly) = lastPos[c]
    let moved = sqrt(float((cx-lx)*(cx-lx) + (cy-ly)*(cy-ly)))
    # nearest enemy
    var nd = 99999.0
    for j in 0 ..< game.players.len:
      let e = game.players[j]
      if not e.alive or e.team == p.team: continue
      let d = sqrt(float((px(e.x)-cx)*(px(e.x)-cx) + (px(e.y)-cy)*(px(e.y)-cy)))
      if d < nd: nd = d
    lastPos[c] = (cx, cy)
    let tag = if moved < 3.0: " <STALL>" else: ""
    echo &"t{tick:>4} {p.team} carrier s{c:>2} ({cx:>4},{cy:>3}) moved{moved:>5.0f} distHome{distHome:>4} nearEnemy{nd:>5.0f}{tag}"
