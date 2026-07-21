import std/[os, strformat, math], ../src/ctf/replays, ../src/ctf/sim

# Re-simulates a replay and emits ONE line per carry-episode (a flag leaving a
# pedestal until it returns), tagging the outcome (CAPTURED vs DIED vs GAMEEND)
# and WHERE the carry ended relative to the enemy pedestal it was stolen from.
# Purpose: decode the Blue-vs-Red exfil failure geometry for tempo-006.
#
#   usage: exfil_trace <replay> [label]

let path = commandLineParams()[0]
let label = if commandLineParams().len > 1: commandLineParams()[1] else: ""
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

let gm = game.gameMap
let pedRed = gm.flagHome(Red)
let pedBlue = gm.flagHome(Blue)
proc ped(t: Team): tuple[x, y: int] =
  if t == Red: (pedRed.x, pedRed.y) else: (pedBlue.x, pedBlue.y)

# per-team active carry state
type Carry = object
  active: bool
  slot: int
  carrierTeam: Team    # the team carrying flags[flagTeam]  == enemy(flagTeam)
  startTick: int
  startX, startY: int
  prevX, prevY: int
  prevHp: int
  prevAlive: bool
  minHp: int
  startCaptures: int   # carrier .captures at steal (to detect the capture increment)

var carry: array[Team, Carry]
var tick = 0

proc zoneOf(flagTeam: Team, carrierTeam: Team, endX: int): string =
  # progress from the enemy pedestal (where stolen) toward own capture edge
  let stealX = ped(flagTeam).x           # enemy pedestal (steal point)
  let homeX  = ped(carrierTeam).x        # own pedestal (capture side)
  let prog = abs(endX - stealX)
  let cx = MapWidth div 2
  if prog < 230: "POCKET_EXIT"
  elif abs(endX - cx) < 140: "MID_CROSS"
  elif abs(endX - homeX) < 260: "HOMESTRETCH"
  else: "OPEN_FIELD"

proc emit(flagTeam: Team, cs: Carry, endTick, endX, endY: int, outcome: string) =
  let dur = endTick - cs.startTick
  let zone = zoneOf(flagTeam, cs.carrierTeam, endX)
  echo &"{label} CARRY flag={flagTeam} carrier={cs.carrierTeam} slot={cs.slot} " &
    &"steal_t={cs.startTick} steal=({cs.startX},{cs.startY}) " &
    &"end_t={endTick} end=({endX},{endY}) dur={dur} out={outcome} " &
    &"zone={zone} minHp={cs.minHp} endHp={cs.prevHp}"

while replay.playing:
  replay.stepReplay(game)
  inc tick
  for flagTeam in [Red, Blue]:
    let c = game.flags[flagTeam].carrier
    if c >= 0 and not carry[flagTeam].active and game.gameOverTimer == 0:
      # steal just happened (ignore the still-held flag after a capture ends the game)
      let p = game.players[c]
      carry[flagTeam] = Carry(active: true, slot: c, carrierTeam: p.team,
        startTick: tick, startX: p.x, startY: p.y, prevX: p.x, prevY: p.y,
        prevHp: p.hp, prevAlive: p.alive, minHp: p.hp, startCaptures: p.captures)
    elif c >= 0 and carry[flagTeam].active:
      let p = game.players[c]
      # capture is scored while the flag is still held (game ends, no reset)
      if p.captures > carry[flagTeam].startCaptures:
        emit(flagTeam, carry[flagTeam], tick, p.x, p.y, "CAPTURED")
        carry[flagTeam].active = false
      else:
        carry[flagTeam].prevX = p.x
        carry[flagTeam].prevY = p.y
        carry[flagTeam].prevHp = p.hp
        carry[flagTeam].prevAlive = p.alive
        if p.hp < carry[flagTeam].minHp: carry[flagTeam].minHp = p.hp
    elif c < 0 and carry[flagTeam].active:
      # carrier no longer holds and no capture increment => dead-carry (flag reset)
      let cs = carry[flagTeam]
      let carrier = game.players[cs.slot]
      let outcome = if not carrier.alive: "DIED" else: "DROP"
      emit(flagTeam, cs, tick, cs.prevX, cs.prevY, outcome)
      carry[flagTeam].active = false

# flush carries still active at replay end
for flagTeam in [Red, Blue]:
  if carry[flagTeam].active:
    emit(flagTeam, carry[flagTeam], tick, carry[flagTeam].prevX,
         carry[flagTeam].prevY, "ATEND")

echo &"{label} FINAL winner={game.winner} gameOverTimer={game.gameOverTimer} isDraw={game.isDraw} ticks={tick}"
