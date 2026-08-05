## Measures what best-of-K ranking actually buys, over a batch of seeds, at
## several K, against the hand-authored `arena` as CONTROL in the same run.
##
##   nim c -d:release -o:/tmp/rankprobe tools/map_rank_probe.nim
##   /tmp/rankprobe --seeds 300 --first 1001 --k 1,4,8,16,32 \
##     --tsv /tmp/rank-sweep.tsv
##
## The point is a DISTRIBUTION SHIFT, not an example. Every candidate map at
## every K is emitted as one TSV row carrying every static metric, so the
## shipped-best population can be compared against the first-valid population
## metric by metric — including the metrics that do NOT move, which is
## information about the metric.
##
## Two things this reports that nothing else can:
##
##   * the COST. Attempts per accepted map and wall clock per map at each K,
##     which is the other half of "K=8 is the 89th percentile".
##   * whether the shipped path agrees. The probe runs the ranking loop
##     itself (so it can count attempts) and then checks its pick against
##     `generateCtfMap`'s, by mapSpec, on every seed. A probe that measures a
##     reimplementation of the thing under test measures nothing.
##
## Curation/measurement tooling; not part of the server.
import
  std/[algorithm, math, os, sequtils, strformat, strutils, times],
  ../src/ctf/sim

const
  Usage = """
Usage: map_rank_probe [options]
  --seeds <n>     how many seeds to scan (default 200)
  --first <n>     first seed (default 1001)
  --k <list>      comma-separated K values (default 1,8,32)
  --tsv <path>    write the per-map metric rows here
  --no-verify     skip the generateCtfMap cross-check (it doubles the work)
"""

type
  Row = object
    k, seed, attempts, candidates: int
    ms: float
    sizeClass: string
    score: float
    metrics: MapMetrics
    agrees: bool

proc metricNames(): seq[string] =
  @["score", "interiorFrac", "coveredFrac", "exposedFrac", "wallFrac",
    "p95ClearancePx", "medianSightPx", "p95SightPx", "longSightFrac",
    "minRoutes", "minCutPx", "detourMean", "crossings", "standRingMin",
    "standRingDelta", "standCoverMin", "collisionCoverRatio",
    "collisionClearRatio", "rectShapeFrac", "shapeCount", "trenchCount"]

proc minCrossings(m: MapMetrics): int =
  result = high(int)
  for crossing in m.crossings:
    result = min(result, crossing.count)
  if result == high(int): result = 0

proc metricValues(row: Row): seq[float] =
  let m = row.metrics
  @[row.score, m.interiorFrac, m.coveredFrac, m.exposedFrac, m.wallFrac,
    m.p95ClearancePx, m.medianSightPx, m.p95SightPx, m.longSightFrac,
    m.minRoutes.float, m.minCutPx.float, m.detourMean, m.minCrossings().float,
    m.standRingMin, m.standRingDelta, m.standCoverMin,
    (if m.collision.mapCoverFrac > 0:
       m.collision.coverFrac / m.collision.mapCoverFrac else: 0.0),
    (if m.collision.mapClearancePx > 0:
       m.collision.clearancePx / m.collision.mapClearancePx else: 0.0),
    m.rectShapeFrac, m.shapeCount.float, m.trenchCount.float]

proc sizeClassOf(gameMap: CtfMap): string =
  for cls in HexSizeClass:
    if HexSizes[cls].width == gameMap.width and
        HexSizes[cls].height == gameMap.height:
      return HexClassNames[cls]
  &"{gameMap.width}x{gameMap.height}"

proc mean(values: seq[float]): float =
  if values.len == 0: 0.0 else: sum(values) / values.len.float

proc median(values: seq[float]): float =
  if values.len == 0:
    return 0.0
  var sorted = values
  sorted.sort()
  let mid = sorted.len div 2
  if sorted.len mod 2 == 1: sorted[mid]
  else: 0.5 * (sorted[mid - 1] + sorted[mid])

proc main() =
  var
    seeds = 200
    first = 1001
    ks = @[1, 8, 32]
    tsvPath = ""
    verify = true
    i = 1
  while i <= paramCount():
    let arg = paramStr(i)
    proc next(): string =
      inc i
      if i > paramCount(): quit(Usage)
      paramStr(i)
    case arg
    of "--seeds": seeds = parseInt(next())
    of "--first": first = parseInt(next())
    of "--k": ks = next().split(',').mapIt(parseInt(it.strip()))
    of "--tsv": tsvPath = next()
    of "--no-verify": verify = false
    of "--help", "-h": quit(Usage, 0)
    else: quit("Unknown option " & arg & "\n" & Usage)
    inc i

  ## Rule 1 of the five meta-rules: the control runs in every batch. It is
  ## also what three of the bands are anchored on, so it is measured once
  ## here and reused rather than recomputed per candidate.
  let control = controlMetrics()
  echo &"control: arena {control.width}x{control.height} " &
    &"interior={control.interiorFrac * 100:.1f}% " &
    &"wall={control.wallFrac * 100:.1f}% " &
    &"p95cover={control.p95ClearancePx:.0f}px " &
    &"routes={control.minRoutes} " &
    &"score={scoreMap(control, control).score * 100:.1f}"
  echo ""

  var rows: seq[Row]
  let overrides = MapGenOverrides(windows: -1, pits: -1, pitDensity: -1)
  for k in ks:
    let started = epochTime()
    var disagreements = 0
    for s in 0 ..< seeds:
      let seed = first + s
      var row = Row(k: k, seed: seed, agrees: true)
      let mapStart = epochTime()
      ## The shipped loop, reproduced here ONLY so the attempt count is
      ## observable; the pick is cross-checked against generateCtfMap below.
      var candidates: seq[CtfMap]
      var attempts = 0
      while attempts < 100 and candidates.len < k:
        let candidate = generateMapAttempt(seed, overrides, 2, attempts)
        inc attempts
        if validateGeneratedMap(candidate).len == 0:
          candidates.add candidate
      if candidates.len == 0:
        echo &"  seed {seed}: NO VALID MAP in {attempts} attempts"
        continue
      let pick =
        if k <= 1: 0 else: rankCtfMapCandidates(candidates)
      row.ms = 1000.0 * (epochTime() - mapStart)
      row.attempts = attempts
      row.candidates = candidates.len
      let chosen = candidates[pick]
      row.sizeClass = chosen.sizeClassOf()
      row.metrics = computeMapMetrics(
        chosen, withChokepoints = false, withValidation = false)
      row.score = scoreMap(row.metrics, control).score
      if verify:
        var probe = overrides
        probe.rankK = k
        let shipped = generateCtfMap(seed, probe, 2)
        if $shipped.mapSpecJson() != $chosen.mapSpecJson():
          row.agrees = false
          inc disagreements
      rows.add row
    let elapsed = epochTime() - started
    let mine = rows.filterIt(it.k == k)
    echo &"K={k:<3} n={mine.len} " &
      &"attempts/map={mean(mine.mapIt(it.attempts.float)):.2f} " &
      &"candidates/map={mean(mine.mapIt(it.candidates.float)):.2f} " &
      &"gen+rank={mean(mine.mapIt(it.ms)):.1f} ms/map " &
      &"(batch {elapsed:.1f}s" &
      (if verify: ", verify included)" else: ")")
    if verify and disagreements > 0:
      echo &"  !! {disagreements} seeds where generateCtfMap disagreed " &
        "with the probe's pick"

  ## ------------------------------------------------------------- report --
  let names = metricNames()
  echo ""
  echo "-- distribution by K (median, and mean in parentheses)"
  var header = "metric".alignLeft(22)
  for k in ks:
    header &= (&"K={k}").align(20)
  header &= "control".align(12)
  echo header
  for mi, name in names:
    var line = name.alignLeft(22)
    for k in ks:
      let values = rows.filterIt(it.k == k).mapIt(it.metricValues()[mi])
      line &= (&"{median(values):.3f} ({mean(values):.3f})").align(20)
    let controlRow = Row(metrics: control, score: scoreMap(control, control).score)
    line &= (&"{controlRow.metricValues()[mi]:.3f}").align(12)
    echo line

  echo ""
  echo "-- size classes shipped (must not move: K may not buy its score " &
    "with the board)"
  for k in ks:
    var counts: seq[(string, int)]
    for row in rows.filterIt(it.k == k):
      var found = false
      for i in 0 ..< counts.len:
        if counts[i][0] == row.sizeClass:
          inc counts[i][1]
          found = true
      if not found: counts.add (row.sizeClass, 1)
    counts.sort(proc (a, b: (string, int)): int = cmp(b[1], a[1]))
    echo &"  K={k:<3} " & counts.mapIt(&"{it[0]}={it[1]}").join("  ")

  echo ""
  echo "-- fraction of maps at or above the control, per metric"
  var head2 = "metric".alignLeft(22)
  for k in ks:
    head2 &= (&"K={k}").align(12)
  echo head2
  let controlRow = Row(metrics: control, score: scoreMap(control, control).score)
  for mi, name in names:
    var line = name.alignLeft(22)
    for k in ks:
      let
        values = rows.filterIt(it.k == k).mapIt(it.metricValues()[mi])
        target = controlRow.metricValues()[mi]
        atLeast = values.filterIt(it >= target).len
      line &= (&"{100.0 * atLeast.float / max(values.len, 1).float:.0f}%").align(12)
    echo line

  if tsvPath.len > 0:
    var lines = @[(@["k", "seed", "attempts", "candidates", "ms",
      "sizeClass", "agrees"] & names).join("\t")]
    for row in rows:
      lines.add (@[$row.k, $row.seed, $row.attempts, $row.candidates,
        &"{row.ms:.2f}", row.sizeClass, $row.agrees] &
        row.metricValues().mapIt(&"{it:.6f}")).join("\t")
    ## The control, as a row, in the same file — a batch that skips its
    ## control is worse than one that flags it.
    lines.add (@["0", "0", "0", "0", "0.00", "arena",
      "true"] & controlRow.metricValues().mapIt(&"{it:.6f}")).join("\t")
    writeFile(tsvPath, lines.join("\n") & "\n")
    echo ""
    echo "wrote ", tsvPath, " (", rows.len + 1, " rows)"

main()
