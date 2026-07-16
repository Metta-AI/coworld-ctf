import std/[os, math, strformat], ../src/ctf/replays, ../src/ctf/sim

# Re-simulates a replay; at each "oh shit!" shout, reports the shouter's nearest
# ENEMY and nearest TEAMMATE (living), to verify the surprise trigger is
# enemy-driven and not misfiring on a nearby friendly.

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

proc d(ax, ay, bx, by: int): float =
  sqrt(float((ax - bx) * (ax - bx) + (ay - by) * (ay - by)))

const SurpriseRadius = 95.0
# Ring buffer of recent per-tick min-enemy-distance for each address, so at a
# shout we can ask: was ANY enemy within SurpriseRadius in the last N ticks?
var histWin = 96
import std/tables
var minEnemyHist = initTable[string, seq[float]]()  # address -> last histWin dists

var n = 0
var enemyWithinRecent = 0
var lastShout = initTable[string, int]()   # address -> last counted shout tick
while replay.playing:
  replay.stepReplay(game)
  # 1) record this tick's nearest-enemy distance for every living player
  for p in game.players:
    if not p.alive: continue
    var nE = 1e9
    for q in game.players:
      if not q.alive or q.address == p.address or q.team == p.team: continue
      let dd = d(p.x, p.y, q.x, q.y)
      if dd < nE: nE = dd
    if p.address notin minEnemyHist: minEnemyHist[p.address] = @[]
    minEnemyHist[p.address].add nE
    if minEnemyHist[p.address].len > histWin:
      minEnemyHist[p.address].delete(0)
  # 2) inspect this tick's shouts
  for s in game.recentShouts:
    if s.text != "oh shit!":
      continue
    if lastShout.getOrDefault(s.address, -1) == s.tick:
      continue                              # same bubble, already counted
    lastShout[s.address] = s.tick
    var sx, sy = 0
    var found = false
    var steam: Team
    for p in game.players:
      if p.address == s.address and p.alive:
        sx = p.x; sy = p.y; steam = p.team; found = true; break
    if not found: continue
    var nE = 1e9
    var nM = 1e9
    for p in game.players:
      if not p.alive or p.address == s.address: continue
      let dd = d(sx, sy, p.x, p.y)
      if p.team == steam:
        if dd < nM: nM = dd
      else:
        if dd < nE: nE = dd
    # min enemy distance over the recent window (captures a foe that just died/fogged)
    var recentMinE = 1e9
    for v in minEnemyHist.getOrDefault(s.address, @[]):
      if v < recentMinE: recentMinE = v
    inc n
    let ok = recentMinE <= SurpriseRadius
    if ok: inc enemyWithinRecent
    echo &"t{s.tick} {s.address:<18} nE_now={nE:6.1f} recentMinE={recentMinE:6.1f} nMate={nM:6.1f}  " &
         (if ok: "ok(enemy≤95 recently)" else: "!! NO enemy≤95 in last 96t")
echo &"--- {n} 'oh shit!'; had enemy≤{SurpriseRadius:.0f}px within {histWin}t: {enemyWithinRecent}/{n} ---"
