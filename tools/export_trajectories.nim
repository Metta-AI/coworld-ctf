import
  std/[json, os, streams, strutils],
  ../src/ctf/[global, replays, sim],
  toolutil

## Re-simulates a .bitreplay and writes every player's Sprite v1 wire frames
## plus the per-tick applied input masks — the exact observation/action streams
## a live Sprites Off (0x87) bot client would have seen and sent. Output feeds
## behavior-cloning training; the Python side parses the frames with the same
## code the live eval player uses.
##
## Usage: nim r -d:release tools/export_trajectories.nim <replay> <outdir>
##
## Writes <outdir>/<basename>.pbtraj (framed binary) and
## <outdir>/<basename>.meta.json. Refuses to emit anything on a hash mismatch:
## a replay the current engine cannot re-simulate deterministically is not
## training data.
##
## .pbtraj record framing, little-endian, repeated to EOF:
##   0x01 frame: u32 tick, u16 player, u32 len, len bytes (Sprite v1 wire packet)
##   0x02 masks: u32 tick, u16 count, count u8 applied-input masks
##   0x03 phase: u32 tick, u8 phase ord
## Frames for tick T describe the state AFTER tick T ran; the masks record for
## tick T+1 holds the actions applied while ticks advanced from T to T+1. A
## consumer pairs each player's mask at T+1 with their frame at T.

const UsageText = "Usage: nim r tools/export_trajectories.nim <replay-path> <out-dir>"

type ExportError = object of CatchableError

proc fail(message: string) =
  raise newException(ExportError, message)

proc putU16(stream: Stream, value: int) =
  stream.write(uint16(value))

proc putU32(stream: Stream, value: int) =
  stream.write(uint32(value))

proc exportTrajectories(replayPath, outDir: string) =
  let data = loadReplay(replayPath)
  let previousDir = getCurrentDir()
  chdirGameDir()
  var
    (sim, replay) = openReplay(data, mismatchQuit = true)
    states: seq[PlayerViewerState]
    phase = sim.phase
    frameCount = 0
  let
    baseName = replayPath.splitFile.name
    trajPath = outDir / baseName & ".pbtraj"
    tmpPath = trajPath & ".tmp"
    stream = newFileStream(tmpPath, fmWrite)
  if stream.isNil:
    fail("Cannot open " & tmpPath & " for writing")
  try:
    stream.write(uint8(3))
    stream.putU32(sim.tickCount)
    stream.write(uint8(ord(phase)))
    while replay.playing:
      replay.stepReplay(sim)
      let tick = sim.tickCount

      stream.write(uint8(2))
      stream.putU32(tick)
      stream.putU16(replay.lastAppliedMasks.len)
      for mask in replay.lastAppliedMasks:
        stream.write(mask)

      if phase != sim.phase:
        phase = sim.phase
        stream.write(uint8(3))
        stream.putU32(tick)
        stream.write(uint8(ord(phase)))

      while states.len < sim.players.len:
        states.add(nil)
      for playerIndex in 0 ..< sim.players.len:
        var nextState: PlayerViewerState
        let framePacket = sim.buildSpriteProtocolPlayerUpdates(
          playerIndex,
          states[playerIndex],
          nextState,
          spritesOff = true
        )
        let wirePacket = dedupObjectPlacements(
          framePacket.stripSpritePixels(),
          nextState.sentPlacements
        )
        states[playerIndex] = nextState
        stream.write(uint8(1))
        stream.putU32(tick)
        stream.putU16(playerIndex)
        stream.putU32(wirePacket.len)
        if wirePacket.len > 0:
          stream.writeData(wirePacket[0].addr, wirePacket.len)
        inc frameCount
  finally:
    stream.close()
    setCurrentDir(previousDir)

  var players = newJArray()
  for i, player in sim.players:
    players.add(%*{
      "index": i,
      "joinOrder": player.joinOrder,
      "name": player.address,
      "team": teamText(player.team),
      "kills": player.kills,
      "deaths": player.deaths,
      "captures": player.captures,
      "reward": player.reward,
    })
  let meta = %*{
    "sourceReplay": replayPath,
    "tickCount": sim.tickCount,
    "winner": teamText(sim.winner),
    "isDraw": sim.isDraw,
    "frameRecords": frameCount,
    "players": players,
    "config": parseJson(data.configJson),
  }
  moveFile(tmpPath, trajPath)
  writeFile(outDir / baseName & ".meta.json", meta.pretty)
  echo "wrote ", trajPath, " (", sim.tickCount, " ticks, ",
    sim.players.len, " players, ", frameCount, " frames)"

proc main() =
  var paths: seq[string]
  for arg in commandLineParams():
    if arg in ["--help", "-h"]:
      echo UsageText
      quit(0)
    elif arg.startsWith("--"):
      fail("Unknown option: " & arg & "\n" & UsageText)
    else:
      paths.add(arg)
  if paths.len != 2:
    fail("Expected a replay path and an output directory.\n" & UsageText)
  let outDir = paths[1].absolutePath()
  createDir(outDir)
  exportTrajectories(paths[0].absolutePath(), outDir)

main()
