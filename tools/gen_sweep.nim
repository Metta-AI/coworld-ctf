## gen_sweep — validity + shape of the SHIPPING generator over many seeds,
## always with the hand-authored `arena` as CONTROL. A metric that flags the
## control is wrong; one that skips it is worse.
##
##   nim c -d:release -r tools/gen_sweep.nim [count] [teams]
import std/[os, strformat, strutils, algorithm, sequtils]
import ../src/ctf/[sim, map_metrics]

proc main() =
  let
    count = if paramCount() >= 1: parseInt(paramStr(1)) else: 20
    teams = if paramCount() >= 2: parseInt(paramStr(2)) else: 2
  let control = evaluateMap(loadCtfMapMetadata("arena"), "arena")
  echo &"CONTROL arena: score={control.staticScore():.3f} " &
    &"interior={control.interiorFrac:.3f} cover={control.coverPermille}pm"
  var
    valid = 0
    scores, interiors: seq[float]
    reasons: seq[string]
  for i in 0 ..< count:
    let seed = 1001 + i
    var m: MapMetrics
    try:
      m = evaluateMap(generateCtfMap(seed, teams = teams), "gen")
    except CtfError:
      ## Nothing validated in 100 attempts. The interesting number is not
      ## "it raised" but WHICH gate rejected every attempt, so re-draw a few
      ## unvalidated candidates and tally their reasons.
      var tally: seq[string]
      for attempt in 0 ..< 5:
        let raw = generateMapAttempt(seed, MapGenOverrides(
          windows: -1, pits: -1, pitDensity: -1), teams, attempt)
        let why = validateGeneratedMap(raw)
        tally.add (if why.len == 0: "VALID?" else: why.split(":")[0])
      reasons.add &"seed {seed}: no valid layout; attempt reasons " &
        tally.join(" | ")
      continue
    if m.valid: inc valid
    else: reasons.add &"seed {seed}: {m.reason}"
    scores.add m.staticScore()
    interiors.add m.interiorFrac
  scores.sort(); interiors.sort()
  proc med(s: seq[float]): float =
    if s.len == 0: 0.0 else: s[s.len div 2]
  echo &"{teams}-team, {count} seeds: valid={valid}/{count} " &
    &"({valid * 100 div max(1, count)}%)  " &
    &"median score={med(scores):.3f} (control {control.staticScore():.3f})  " &
    &"median interiorFrac={med(interiors):.3f} (control {control.interiorFrac:.3f})"
  for r in reasons[0 ..< min(8, reasons.len)]: echo "   ", r
  if reasons.len > 8: echo &"   ... {reasons.len - 8} more"

main()
