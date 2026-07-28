## Mate-aim sprite-readback mechanism probe (task 1216960771024767, 0 arms).
## Re-simulates a .bitreplay and, per sim tick and per seat, builds the REAL
## player POV packet (buildSpriteProtocolPlayerUpdates), parses it exactly the
## way the baseline bot's protocol client does, and decodes every OTHER visible
## player's aim rotation step from its soldier sprite id — the
## -d:mateAimSpriteRead readback (soldierPlayerSpriteId = 100 + skin*32 +
## team*16 + rot; id mod 16 isolates rot).
##
## Reports:
##  1. readback fidelity: |decoded bucket center - true aimBrads| histogram,
##     separately for mates and enemies, plus visible-but-unmatched misses
##  2. attribution geometry: sprite-center vs sim-body-center offset (max/p99)
##     — validates the bot-side MateSpriteMatchRadius
##  3. consumer-level agreement: the mateTargeted ray test (slack 22px, ray
##     700px) evaluated with the TRUE aim vs the DECODED aim, confusion matrix
##     binned by mate->enemy distance (0-240 / 240-500 / 500-700 px)
##
## Usage: mate_aim_probe <replay-path> [max-ticks]

import
  std/[math, os, strformat, strutils, tables],
  bitworld/spriteprotocol,
  ../src/ctf/replays,
  ../src/ctf/sim,
  ../src/ctf/global

const
  GameDir = currentSourcePath().parentDir().parentDir()
  SoldierSpriteBase = 100       # src/ctf/sim.nim PlayerSpriteBase
  SoldierRotSteps = 16          # src/ctf/global.nim SoldierRotations
  RotBrads = 256 div SoldierRotSteps
  MatchRadius = 16.0            # baseline.nim MateSpriteMatchRadius
  RayLen = 700.0                # baseline.nim MateAimRayLen
  RaySlack = 22.0               # baseline.nim MateAimHitSlack
  ProbeMapObjectId = 1          # players/baseline/baseline/protocols.nim
  ProbeMapSpriteId = 1

proc bradsErr(a, b: int): int =
  ## Shortest signed angular difference a-b, matching baseline.nim.
  (a - b + 256 + 128) mod 256 - 128

proc bradsDirX(brads: int): float =
  cos(float(brads) * PI / 128.0)

proc bradsDirY(brads: int): float =
  -sin(float(brads) * PI / 128.0)

type ObjInfo = object
  x, y, spriteId: int
  present: bool

type ClientMirror = object
  ## The minimal slice of the bot's ProtocolClient sprite state, updated by
  ## the same parseSpritePacket messages the bot applies (incremental: sprite
  ## defs arrive once, objects persist until deleted).
  labels: Table[int, string]        # spriteId -> label
  dims: Table[int, (int, int)]      # spriteId -> (width, height)
  objs: Table[int, ObjInfo]         # objectId -> state
  camX, camY: int

proc apply(c: var ClientMirror, packet: seq[uint8]) =
  for message in parseSpritePacket(packet):
    case message.kind
    of spkSprite:
      c.labels[message.sprite.id] = message.sprite.label
      c.dims[message.sprite.id] = (message.sprite.width, message.sprite.height)
    of spkObject:
      let od = message.objectDef
      c.objs[od.id] = ObjInfo(x: od.x, y: od.y, spriteId: od.spriteId,
        present: true)
      if od.id == ProbeMapObjectId and od.spriteId == ProbeMapSpriteId:
        c.camX = -od.x
        c.camY = -od.y
    of spkDeleteObject:
      if message.objectId in c.objs:
        c.objs[message.objectId].present = false
    of spkClearObjects:
      for o in c.objs.mvalues: o.present = false
    else:
      discard

type Decoded = object
  cx, cy: float                     # mapPos-equivalent sprite center
  aim: int                          # decoded bucket center, brads

proc decodedSoldiers(c: ClientMirror, color: string): seq[Decoded] =
  ## The bot-side decode under test: every present object labelled
  ## `player <color> <side>` -> sprite center + rotation-bucket aim.
  for objectId, o in c.objs:
    if not o.present: continue
    let label = c.labels.getOrDefault(o.spriteId, "")
    if label.startsWith("player " & color & " "):
      let (w, h) = c.dims.getOrDefault(o.spriteId, (0, 0))
      result.add(Decoded(
        cx: float(o.x + w div 2 + c.camX),
        cy: float(o.y + h div 2 + c.camY),
        aim: floorMod(o.spriteId - SoldierSpriteBase, SoldierRotSteps) *
          RotBrads))

let params = commandLineParams()
if params.len < 1:
  quit("Usage: mate_aim_probe <replay-path> [max-ticks]")
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
  mateSamples, enemySamples = 0
  mateMisses, enemyMisses = 0       # visible+alive but no sprite within radius
  worstMateErr, worstEnemyErr = 0
  mateErrHist, enemyErrHist: array[0 .. 16, int]
  offMax = 0.0                      # sprite-center vs body-center offset
  offHist: array[0 .. 17, int]      # px, cap 17
  # Consumer confusion per distance bin: [TP, FP, FN, TN]
  bins: array[3, array[4, int]]

proc binOf(d: float): int =
  if d <= 240.0: 0 elif d <= 500.0: 1 else: 2

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
    mirrors[i].apply(packet)
    if not game.players[i].alive:
      continue
    for team in [Red, Blue]:
      let color = if team == Red: "red" else: "blue"
      let decoded = mirrors[i].decodedSoldiers(color)
      for j in 0 ..< game.players.len:
        if j == i: continue
        let pj = game.players[j]
        if pj.team != team or not pj.alive: continue
        if not game.playerVisibleTo(i, j): continue
        let
          tx = float(pj.x)
          ty = float(pj.y)
        var best = -1
        var bestD = MatchRadius
        for k in 0 ..< decoded.len:
          let d = sqrt((decoded[k].cx - tx)^2 + (decoded[k].cy - ty)^2)
          if d < bestD:
            bestD = d
            best = k
        let isMate = pj.team == game.players[i].team
        if best < 0:
          if isMate: inc mateMisses else: inc enemyMisses
          continue
        let err = abs(bradsErr(decoded[best].aim, pj.aimBrads))
        if isMate:
          inc mateSamples
          mateErrHist[min(err, 16)].inc
          if err > worstMateErr: worstMateErr = err
        else:
          inc enemySamples
          enemyErrHist[min(err, 16)].inc
          if err > worstEnemyErr: worstEnemyErr = err
        offHist[min(int(bestD), 17)].inc
        if bestD > offMax: offMax = bestD
        if not isMate: continue
        # Consumer-level ray test agreement, true vs decoded aim, for every
        # live enemy of the mate's team (matching the decide() loop geometry).
        let
          tdx = bradsDirX(pj.aimBrads)
          tdy = bradsDirY(pj.aimBrads)
          rdx = bradsDirX(decoded[best].aim)
          rdy = bradsDirY(decoded[best].aim)
        for e in 0 ..< game.players.len:
          let pe = game.players[e]
          if pe.team == team or not pe.alive: continue
          let
            relX = float(pe.x) - tx
            relY = float(pe.y) - ty
            d = sqrt(relX^2 + relY^2)
          if d < 1.0 or d > RayLen: continue
          let
            tAlong = relX * tdx + relY * tdy
            tCross = abs(relX * tdy - relY * tdx)
            rAlong = relX * rdx + relY * rdy
            rCross = abs(relX * rdy - relY * rdx)
            truth = tAlong > 0.0 and tAlong <= RayLen and tCross <= RaySlack
            read = rAlong > 0.0 and rAlong <= RayLen and rCross <= RaySlack
            b = binOf(d)
          if truth and read: bins[b][0].inc
          elif read: bins[b][1].inc
          elif truth: bins[b][2].inc
          else: bins[b][3].inc

echo &"mateSamples={mateSamples} mateMisses={mateMisses} worstMateErr={worstMateErr}"
echo &"enemySamples={enemySamples} enemyMisses={enemyMisses} worstEnemyErr={worstEnemyErr}"
echo &"attribution offset: max={offMax:.2f}px"
var cum = 0
for e in 0 .. 16:
  cum += mateErrHist[e]
  if mateErrHist[e] > 0:
    echo &"  mate |err|={e}: {mateErrHist[e]} ({100.0*float(cum)/float(max(1,mateSamples)):.1f}% cum)"
cum = 0
for e in 0 .. 16:
  cum += enemyErrHist[e]
  if enemyErrHist[e] > 0:
    echo &"  enemy |err|={e}: {enemyErrHist[e]} ({100.0*float(cum)/float(max(1,enemySamples)):.1f}% cum)"
echo "attribution offset histogram (px):"
for e in 0 .. 17:
  if offHist[e] > 0:
    echo &"  {e}px: {offHist[e]}"
for b in 0 .. 2:
  let
    name = ["0-240px", "240-500px", "500-700px"][b]
    tp = bins[b][0]
    fp = bins[b][1]
    fn = bins[b][2]
    tn = bins[b][3]
    detect = if tp + fn > 0: 100.0 * float(tp) / float(tp + fn) else: 0.0
    falseMark = if fp + tn > 0: 100.0 * float(fp) / float(fp + tn) else: 0.0
    precision = if tp + fp > 0: 100.0 * float(tp) / float(tp + fp) else: 0.0
  echo &"consumer ray-test {name}: TP={tp} FP={fp} FN={fn} TN={tn} " &
    &"detect={detect:.1f}% falseMark={falseMark:.2f}% precision={precision:.1f}%"
if worstMateErr > RotBrads div 2:
  echo "FAIL: mate readback disagrees with true aim beyond half a rotation step"
  quit(1)
if mateSamples == 0:
  echo "FAIL: no mate samples decoded"
  quit(1)
echo "OK: mate readback within half a rotation step of true aim on every sample"
