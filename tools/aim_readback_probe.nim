## Sprite aim-readback mechanism probe (task 1216949818460910, 0 arms).
## Re-simulates a .bitreplay and, per sim tick and per seat, builds the REAL
## player POV packet (buildSpriteProtocolPlayerUpdates), parses it exactly the
## way the baseline bot's protocol client does, and decodes the aim rotation
## step from the self-soldier sprite id — the -d:aimSpriteResync readback.
## Compares the decoded bucket center against the sim's TRUE aimBrads and
## fails loudly if any sample disagrees by more than half a rotation step
## (8 brads), i.e. if the readback mapping is wrong.
##
## Usage: aim_readback_probe <replay-path> [max-ticks]

import
  std/[math, os, strformat, strutils, tables],
  bitworld/spriteprotocol,
  ../src/ctf/replays,
  ../src/ctf/sim,
  ../src/ctf/global

const
  GameDir = currentSourcePath().parentDir().parentDir()
  SelfSoldierSpriteBase = 5100  # players/baseline: global SpritePlayerSelfSpriteBase
  SoldierRotSteps = 16
  SelfRotBrads = 256 div SoldierRotSteps

proc bradsErr(a, b: int): int =
  ## Shortest signed angular difference a-b, matching baseline.nim.
  (a - b + 256 + 128) mod 256 - 128

type ClientMirror = object
  ## The minimal slice of the bot's ProtocolClient sprite state: label + sprite
  ## id per present object, updated by the same parseSpritePacket messages.
  labels: Table[int, string]     # spriteId -> label
  objSprite: Table[int, int]     # objectId -> spriteId
  present: Table[int, bool]

proc apply(c: var ClientMirror, packet: seq[uint8]) =
  for message in parseSpritePacket(packet):
    case message.kind
    of spkSprite:
      c.labels[message.sprite.id] = message.sprite.label
    of spkObject:
      c.objSprite[message.objectDef.id] = message.objectDef.spriteId
      c.present[message.objectDef.id] = true
    of spkDeleteObject:
      c.present[message.objectId] = false
    of spkClearObjects:
      for k in c.present.mvalues: k = false
    else:
      discard

proc observedAimOf(c: ClientMirror, color: string): int =
  ## The bot-side decode under test: self marker label -> sprite id -> rot.
  result = -1
  for objectId, ok in c.present:
    if not ok: continue
    let sid = c.objSprite.getOrDefault(objectId, -1)
    let label = c.labels.getOrDefault(sid, "")
    if label.startsWith("self " & color):
      let rot = floorMod(sid - SelfSoldierSpriteBase, SoldierRotSteps)
      return rot * SelfRotBrads

let params = commandLineParams()
if params.len < 1:
  quit("Usage: aim_readback_probe <replay-path> [max-ticks]")
let
  replayPath = params[0].absolutePath()
  maxTicks = if params.len > 1: params[1].parseInt() else: high(int)

setCurrentDir(GameDir)
let data = loadReplay(replayPath)
var config = defaultGameConfig()
config.update(data.configJson)
var game = initSimServer(config)
var replay = initReplayPlayer(data)
game.gameEventLoggingEnabled = false
replay.looping = false
replay.mismatchQuit = true

var
  states: seq[PlayerViewerState]
  mirrors: seq[ClientMirror]
  samples = 0
  aliveMisses = 0
  worstErr = 0
  errHist: array[0 .. 16, int]   # |err| histogram, brads (cap 16)

while replay.playing and game.tickCount < maxTicks:
  replay.stepReplay(game)
  if game.phase != Playing: continue
  if states.len < game.players.len:
    states.setLen(game.players.len)
    mirrors.setLen(game.players.len)
  for i in 0 ..< game.players.len:
    var nextState: PlayerViewerState
    let packet = game.buildSpriteProtocolPlayerUpdates(i, states[i], nextState)
    states[i] = nextState
    # Updates are incremental (sprite defs arrive once), so the mirror carries
    # state across frames exactly like the bot's retained client does.
    mirrors[i].apply(packet)
    let color = if game.players[i].team == Red: "red" else: "blue"
    let seen = mirrors[i].observedAimOf(color)
    if not game.players[i].alive:
      continue
    if seen < 0:
      inc aliveMisses
      continue
    let err = abs(bradsErr(seen, game.players[i].aimBrads))
    inc samples
    errHist[min(err, 16)].inc
    if err > worstErr: worstErr = err

echo &"samples={samples} aliveMisses={aliveMisses} worstErr={worstErr}"
var cum = 0
for e in 0 .. 16:
  cum += errHist[e]
  if errHist[e] > 0:
    echo &"  |err|={e}: {errHist[e]} ({100.0*float(cum)/float(max(1,samples)):.1f}% cum)"
if worstErr > SelfRotBrads div 2:
  echo "FAIL: readback disagrees with true aim beyond half a rotation step"
  quit(1)
echo "OK: readback within half a rotation step of true aim on every sample"
