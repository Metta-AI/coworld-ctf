## Scratch verification probe (NOT a repo tool, do not commit).
##
## Drives the REAL boot-path integration seam
## (team_colors.setTeamDisplayColors -> shimmer.installPayloadShimmer) against
## the real stock-4team-corners-seed424242.bitreplay fixture, then uses the
## same black-box shimmer-sprite detection tests/test_shimmer.nim already
## trusts (find sprites labeled "metal shimmer ...", find their objects,
## check which player's cog center they sit on) to report, per seat: team,
## stripped policy name, alive, whether a shimmer overlay is centered on them.
##
## This exercises the ONE code path shard_4's tests never call directly:
## installPayloadShimmer() is only ever invoked from src/ctf.nim's boot, never
## from a test.
import
  std/[os, strutils, tables],
  pixie,
  bitworld/spriteprotocol,
  ../src/ctf/[global, shimmer, sim, team_colors],
  ../tools/toolutil

const ShimmerLabelPrefix = "metal shimmer "

proc shimmerSpriteIds(messages: openArray[SpritePacketMessage]): seq[int] =
  for message in messages:
    if message.kind == spkSprite and
        message.sprite.label.startsWith(ShimmerLabelPrefix):
      result.add message.sprite.id

proc shimmerCentres(messages: openArray[SpritePacketMessage]): seq[(int, int)] =
  let ids = messages.shimmerSpriteIds()
  var size = 0
  for message in messages:
    if message.kind == spkSprite and message.sprite.id in ids:
      size = message.sprite.width
  for message in messages:
    if message.kind == spkObject and message.objectDef.spriteId in ids:
      result.add (message.objectDef.x + size div 2,
                  message.objectDef.y + size div 2)

proc shimmersOnSeat(sim: SimServer, messages: openArray[SpritePacketMessage],
                     seat: int): bool =
  let
    scale = boardRenderScaleFor(sim.gameMap.width, sim.gameMap.height)
    px = sim.players[seat].x * scale
    py = sim.players[seat].y * scale
  for (cx, cy) in messages.shimmerCentres():
    if abs(cx - px) <= 8 * scale and abs(cy - py) <= 8 * scale:
      return true
  false

proc fullFrame(sim: var SimServer): seq[SpritePacketMessage] =
  var state = initGlobalViewerState()
  var nextState: GlobalViewerState
  sim.buildSpriteProtocolUpdates(state, nextState).parseSpritePacket()

proc run(fixturePath: string, payloadJson: string, targetTick: int,
         outPng: string) =
  chdirGameDir()
  var (sim, replay) = openReplay(fixturePath)

  # THE REAL BOOT PATH, in the real boot order (src/ctf.nim lines ~95-101).
  let recolored = setTeamDisplayColors(payloadJson)
  installPayloadShimmer()
  echo "setTeamDisplayColors -> recolored any team: ", recolored
  echo "anyShimmer(): ", anyShimmer()

  while replay.playing and sim.tickCount < targetTick:
    try:
      replay.stepReplay(sim)
    except ReplayError:
      echo "REPLAY HASH MISMATCH at tick ", sim.tickCount + 1
      quit(1)
  echo "landed at tick ", sim.tickCount, " (target ", targetTick, ")"

  let messages = fullFrame(sim)
  echo "shimmer sprite ids this frame: ", messages.shimmerSpriteIds()
  echo "shimmer overlay centres this frame: ", messages.shimmerCentres()
  echo ""
  echo "team  policy            alive  shimmers  teamDisplayColor  recolored"
  for i in 0 ..< sim.players.len:
    let p = sim.players[i]
    let pol = policyName(p.address)
    let
      shim = sim.shimmersOnSeat(messages, i)
      aliveStr = $p.alive
      shimStr = $shim
    echo teamText(p.team) & "   ".substr(0, 3) & "  " &
      pol & repeat(" ", max(1, 18 - pol.len)) &
      aliveStr & repeat(" ", max(1, 7 - aliveStr.len)) &
      shimStr & repeat(" ", max(1, 10 - shimStr.len)) &
      $teamDisplayColor(p.team) & "  " & $teamDisplayIsRecolored(p.team)

  # Save an authoritative full-board PNG straight from the engine's own
  # sprite compositor -- not a browser screenshot, but the same renderer.
  let img = compositeBoard(messages, boardRenderScaleFor(sim.gameMap.width, sim.gameMap.height))
  img.writeFile(outPng)
  echo "wrote ", outPng

when isMainModule:
  let args = commandLineParams()
  if args.len < 4:
    echo "usage: verify_payload_shimmer <fixture.bitreplay> <payload.json> <targetTick> <out.png>"
    quit(1)
  let payload = readFile(args[1])
  run(args[0], payload, parseInt(args[2]), args[3])
