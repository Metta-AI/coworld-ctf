## stick_probe — the BEFORE/AFTER instrument for the measuring stick itself.
##
## `map_eval` scores maps. This scores the SCORER: it prints the raw numbers the
## bands are cut from, for a labelled batch, so a change to a band can be shown
## to have moved (or not moved) each map's real position rather than only its
## scalar.
##
## Rule 1 holds here as everywhere: `arena` and `arena-large` are prepended to
## every batch as labelled CONTROLS and are never exempted from anything.
##
##   stick_probe --teams 2 --pool --gen 1001-1020
##   stick_probe --teams 4 --gen 1001-1012

import
  std/[algorithm, os, sequtils, strformat, strutils],
  ../src/ctf/[arena, map_metrics, map_pool, map_lanes, sim_types]

type Row = object
  label: string
  m: MapMetrics

# The pinch-length fields do not exist on the BEFORE side of this change, and
# the whole point of the probe is that the same binary source can take both
# snapshots. `-1` prints as "not measured", which is the honest reading of the
# blind spot rather than a zero that looks like a measurement.
proc chokeExposed(m: MapMetrics): int =
  when compiles(m.chokeExposedPx): m.chokeExposedPx else: -1
proc chokeAllowed(m: MapMetrics): int =
  when compiles(m.chokeAllowedPx): m.chokeAllowedPx else: -1
proc chokeExcess(m: MapMetrics): int =
  when compiles(m.chokeExcessPx): m.chokeExcessPx else: -1

proc parseRange(spec: string): (int, int) =
  let parts = spec.split('-')
  let lo = parts[0].parseInt
  (lo, if parts.len > 1: parts[1].parseInt else: lo)

proc quantile(sorted: seq[float], q: float): float =
  if sorted.len == 0: return 0.0
  sorted[clamp(int(q * float(sorted.len - 1) + 0.5), 0, sorted.len - 1)]

proc spreadOf(values: seq[float]): string =
  var s = values
  s.sort()
  &"min {s.quantile(0.0):8.3f}  p25 {s.quantile(0.25):8.3f}  " &
    &"med {s.quantile(0.5):8.3f}  p75 {s.quantile(0.75):8.3f}  " &
    &"max {s.quantile(1.0):8.3f}"

when isMainModule:
  var
    teams = 2
    wantPool = false
    genLo, genHi = 0
    argv = commandLineParams()
    i = 0
  while i < argv.len:
    case argv[i]
    of "--teams": inc i; teams = argv[i].parseInt
    of "--pool": wantPool = true
    of "--gen": inc i; (genLo, genHi) = parseRange(argv[i])
    else: discard
    inc i

  var
    rows: seq[Row]
    ungenerated: seq[string]
  proc scoreOne(label: string, make: proc (): CtfMap) =
    ## A seed the generator cannot satisfy is RECORDED, never fatal. Letting one
    ## bad seed abort the batch is how a re-score silently becomes a re-score of
    ## whatever came before the exception.
    try:
      rows.add Row(label: label, m: evaluateMap(make(), label))
      stderr.writeLine "  scored " & label
    except CatchableError as e:
      ungenerated.add label & " (" & e.msg.split('(')[0].strip() & ")"
      stderr.writeLine "  UNGENERATED " & label & ": " & e.msg

  # CONTROLS FIRST, always, both of them.
  scoreOne("CTL arena", proc (): CtfMap = loadCtfMapMetadata("arena"))
  scoreOne("CTL arena-large", proc (): CtfMap = loadCtfMapMetadata("arena-large"))
  let overrides = MapGenOverrides(windows: -1, pits: -1, pitDensity: -1)
  if wantPool:
    for k in 0 ..< MapPoolSeeds.len:
      closureScope:
        let s = MapPoolSeeds[k]
        scoreOne(&"pool:{k}({s})",
          proc (): CtfMap = generateCtfMap(s, overrides, teams))
  if genHi >= genLo and genHi > 0:
    for seed in genLo .. genHi:
      closureScope:
        let s = seed
        scoreOne(&"gen:{s}", proc (): CtfMap = generateCtfMap(s, overrides, teams))

  echo ""
  echo &"=== {rows.len} maps at {teams} teams. First two rows are CONTROLS."
  if ungenerated.len > 0:
    echo &"!! {ungenerated.len} seed(s) THE GENERATOR COULD NOT SATISFY at " &
      &"{teams} teams, absent from every number below: " & ungenerated.join(", ")
  echo ""
  echo &"""{"map":<16}{"size":>10}{"score":>7} | """ &
    &"""{"axP95":>6}{"axMax":>6}{"axLong":>7} | """ &
    &"""{"dgP95":>6}{"dgMax":>6}{"dgLong":>7} | """ &
    &"""{"chk":>4}{"tight":>6}{"exp":>6}{"allow":>6}{"cov":>4} | """ &
    &"""{"stCovMin":>9}{"stCovMax":>9} | {"routes":>7}"""
  for r in rows:
    let m = r.m
    echo &"{r.label:<16}{m.width}x{m.height:<5}{m.staticScore():7.3f} | " &
      &"{m.openRunP95Px:6}{m.openRunMaxPx:6}{m.longRunFrac * 100:6.1f}% | " &
      &"{m.diagRunP95Px:6}{m.diagRunMaxPx:6}{m.diagLongRunFrac * 100:6.1f}% | " &
      &"{m.chokeCount:4}{m.chokeMinClearPx:6}{m.chokeExposed:6}" &
      &"{m.chokeAllowed:6}{(if m.chokeCovered: \"YES\" else: \" no\"):>4} | " &
      &"{m.standCoverMin * 100:8.1f}%{m.standCoverMax * 100:8.1f}% | " &
      &"{m.routeCountMin:7}"

  echo ""
  echo "DISTRIBUTION over the non-control rows:"
  proc column(name: string, get: proc (m: MapMetrics): float) =
    var v: seq[float]
    for r in rows[2 .. ^1]: v.add get(r.m)
    if v.len == 0: return
    echo &"  {name:<20} arena {get(rows[0].m):8.3f}  large {get(rows[1].m):8.3f}   " &
      v.spreadOf()
  column("axis runP95", proc (m: MapMetrics): float = m.openRunP95Px.float)
  column("axis runMax", proc (m: MapMetrics): float = m.openRunMaxPx.float)
  column("longRunFrac", proc (m: MapMetrics): float = m.longRunFrac)
  column("diag runP95", proc (m: MapMetrics): float = m.diagRunP95Px.float)
  column("diag runMax", proc (m: MapMetrics): float = m.diagRunMaxPx.float)
  column("diagLongRunFrac", proc (m: MapMetrics): float = m.diagLongRunFrac)
  column("chokeCount", proc (m: MapMetrics): float = m.chokeCount.float)
  column("chokeExposedPx", proc (m: MapMetrics): float = m.chokeExposed.float)
  column("chokeExcessPx", proc (m: MapMetrics): float = m.chokeExcess.float)
  column("chokeCovered", proc (m: MapMetrics): float =
    if m.chokeCount > 0 and m.chokeCovered: 1.0 else: 0.0)
  column("standCoverMin", proc (m: MapMetrics): float = m.standCoverMin)
  column("standCoverSpread",
    proc (m: MapMetrics): float = m.standCoverMax - m.standCoverMin)
  column("routeCountMin", proc (m: MapMetrics): float = m.routeCountMin.float)
  column("visDegreeCv", proc (m: MapMetrics): float = m.visDegreeCv)
  column("staticScore", proc (m: MapMetrics): float = m.staticScore())

  echo ""
  echo "BAND BREACHES (the control's breaches are METRIC BUGS, not verdicts):"
  for r in rows:
    var bad: seq[string]
    for b in r.m.scoreBands():
      if b.breached: bad.add &"{b.band.name}={b.value:.3f}"
    if bad.len > 0:
      let tag = if r.label.startsWith("CTL"): "  !! CONTROL " else: "     "
      echo &"{tag}{r.label:<16} {bad.join(\"  \")}"
