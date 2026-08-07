## MEASURE FIRST: for one replay, re-simulate with the frames sink on and
## report every gun/grenade/spray "kill" event's BLINDSIDE classification —
## was the killer, at the kill tick, outside the victim's forward ~120° arc
## (the victim's own stated aim, read straight off the frames stream, never
## a sprite-derived read: frame aimBrads comes from `player.aimBrads` in the
## sim itself, the same field the fuzzed "aim dot" sprites are DERIVED from,
## so this ground-truth read is exactly what the fuzz hides from a live bot,
## not what it corrupts here).
##
## One JSON row per kill on stdout: tick, killer/victim slot+team, the
## victim-relative bearing to the killer, the victim's own aim, the absolute
## angular gap between them in degrees, and `blindside` = gap > 60 (half of
## the ~120° forward arc). A trailing summary row carries the replay's
## finished/winner/slot_team roster so a caller never has to re-derive it.
##
## Usage: nim r tools/blindside_probe.nim <replay-path>
import std/[json, math, os, tables], extract_events, toolutil,
  ../src/ctf/sim

proc bradsOfDelta(dx, dy: float): int =
  ## Mirrors baseline.nim's bradsOf: 0 = east, CCW positive on screen (map y
  ## grows downward, hence the -dy), full turn = 256 brads.
  (int(round(arctan2(-dy, dx) * 128.0 / PI)) + 256) mod 256

proc bradsGap(a, b: int): int =
  ## Shortest absolute arc between two 0..255 brad readings.
  abs((a - b + 256 + 128) mod 256 - 128)

when isMainModule:
  let args = commandLineParams()
  if args.len != 1:
    stderr.writeLine("Usage: nim r tools/blindside_probe.nim <replay-path>")
    quit(1)
  let path = args[0].absolutePath()
  let extraction = extractEvents(loadReplay(path), captureFrames = true)
  # tick -> frame index (built once; robust to any gap/skip in the tick
  # stream instead of assuming index == tick - firstTick).
  var tickToIndex = initTable[int, int]()
  for i in 0 ..< extraction.frameCount:
    tickToIndex[extraction.frameTick(i)] = i
  for event in extraction.events:
    if event.kind != Kill:
      continue
    if not tickToIndex.hasKey(event.tick):
      continue
    let idx = tickToIndex[event.tick]
    if event.source < 0 or event.source >= extraction.frameSlots or
        event.target < 0 or event.target >= extraction.frameSlots:
      continue
    let
      killer = extraction.frameSeat(idx, event.source)
      victim = extraction.frameSeat(idx, event.target)
      bearingToKiller = bradsOfDelta(
        float(killer.x - victim.x), float(killer.y - victim.y))
      gapBrads = bradsGap(bearingToKiller, victim.aimBrads)
      gapDeg = float(gapBrads) * 360.0 / 256.0
    var row = newJObject()
    row["tick"] = %event.tick
    row["killer_slot"] = %event.source
    row["victim_slot"] = %event.target
    row["killer_team"] =
      %(if event.source < extraction.slotTeam.len: extraction.slotTeam[event.source] else: "")
    row["victim_team"] =
      %(if event.target < extraction.slotTeam.len: extraction.slotTeam[event.target] else: "")
    row["weapon"] = %event.weapon
    row["victim_aim_brads"] = %victim.aimBrads
    row["bearing_to_killer_brads"] = %bearingToKiller
    row["gap_deg"] = %gapDeg
    row["blindside"] = %(gapDeg > 60.0)
    echo $row
  var summary = newJObject()
  summary["type"] = %"summary"
  summary["replay"] = %path
  summary["finished"] = %extraction.finished
  summary["winner"] = %extraction.winner
  summary["slot_team"] = %extraction.slotTeam
  echo $summary
