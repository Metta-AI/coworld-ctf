import std/[os, strformat, strutils, tables], ../src/ctf/replays, ../src/ctf/sim

# Re-simulates one hosted replay and accumulates an OPPONENT-OCCUPANCY heatmap:
# where the given "opponent" slots spend their time, on a coarse grid, PLUS the
# capture-relevant metric — how many opponents sit in each pedestal's respawn
# firing band (pedestal height +/- RespawnBandHalf) while OUR carrier is inside
# that pocket. Because the mixed field seats our own policy on both teams, the
# caller passes exactly which slots are the real opponents (non-Picasso) so the
# map is "where daveey/beacon/flankfire actually are", not our own mirror.
#
# Usage: occupancy_heatmap.out <replay> <oppSlots csv> <ourSlots csv>
# Emits a TSV of grid counts to stdout (cellX cellY count) plus a summary block
# to stderr, so many replays can be concatenated by the caller into one grid.

const
  CellPx = 48                       # ~26x14 grid over the 1235x659 map
  GridW = (MapWidth + CellPx - 1) div CellPx
  GridH = (MapHeight + CellPx - 1) div CellPx
  RespawnBandHalf = 84              # matches the bot's cone constant
  PocketClearX = 130                # "in the pocket" x-distance from a pedestal

proc parseSlots(s: string): seq[int] =
  for part in s.split(','):
    let t = part.strip()
    if t.len > 0: result.add(parseInt(t))

let
  path = commandLineParams()[0]
  oppSlots = parseSlots(commandLineParams()[1])
  ourSlots = (if commandLineParams().len > 2: parseSlots(commandLineParams()[2]) else: @[])
  gameDir = currentSourcePath().parentDir().parentDir()
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
  grid = newSeq[int](GridW * GridH)
  samples = 0
  # money metric: opponents in the respawn band around the pedestal our carrier
  # is currently robbing, summed over carrier-in-pocket ticks.
  carrierPocketTicks = 0
  bandOppSum = 0

proc pedestalX(team: Team): int =
  # flagHome x for a team (from sim geometry).
  game.gameMap.flagHome(team).x

let pedCenterY = game.gameMap.center.y

var tick = 0
while replay.playing:
  replay.stepReplay(game)
  inc tick
  # Accumulate opponent occupancy every tick.
  for s in oppSlots:
    if s < game.players.len and game.players[s].alive:
      let
        cx = clamp(game.players[s].x div CellPx, 0, GridW - 1)
        cy = clamp(game.players[s].y div CellPx, 0, GridH - 1)
      inc grid[cy * GridW + cx]
  inc samples
  # Money metric: for each flag currently carried by one of OUR slots, count
  # opponents sitting in that robbed pedestal's respawn band.
  for team in [Red, Blue]:
    let c = game.flags[team].carrier
    if c >= 0 and c in ourSlots:
      let px = pedestalX(team)            # the pedestal our carrier just robbed
      if abs(game.players[c].x - px) < PocketClearX:
        inc carrierPocketTicks
        for s in oppSlots:
          if s < game.players.len and game.players[s].alive and
              abs(game.players[s].y - pedCenterY) < RespawnBandHalf and
              abs(game.players[s].x - px) < PocketClearX:
            inc bandOppSum

# Emit the grid as TSV so the caller can sum many replays.
for cy in 0 ..< GridH:
  for cx in 0 ..< GridW:
    let v = grid[cy * GridW + cx]
    if v > 0:
      echo &"{cx}\t{cy}\t{v}"

stderr.writeLine &"# {path.extractFilename}: ticks={tick} samples={samples} " &
  &"carrierPocketTicks={carrierPocketTicks} bandOppSum={bandOppSum} " &
  &"meanOppInBand={(if carrierPocketTicks>0: bandOppSum/carrierPocketTicks else: 0.0):.2f}"
