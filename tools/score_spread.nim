## score_spread — build a SPREAD of maps along staticScore, on purpose.
##
## Why this exists: `staticScore` is a hand-written surrogate for play quality
## that has never been checked against play. Checking it needs maps whose
## scores differ, and the shipping generator no longer produces those — it runs
## best-of-K and ships the winner, so the shipped population is saturated near
## the top (2-team median 0.972 on this branch). A correlation computed over a
## saturated population measures nothing, however many episodes you buy.
##
## The spread axis here is the ATTEMPT INDEX, not the seed. `generateMapAttempt`
## routes `attempt` through the `stream` scenes and NOT the `seedStream` ones,
## so the board SHELL (size class, symmetry, team layout, endzone archetype) is
## identical across every attempt of one seed while terrain/cover/pickups are
## redrawn. Attempts of one seed are therefore the SAME BOARD built differently,
## which is a better-controlled spread than the old generator's cross-seed one:
## board scale, spawn geometry and objective placement are held fixed and only
## the architecture the score claims to measure moves.
##
## Size is locked to one class for the same reason. Board area drives episode
## cost, dead-floor fraction and pace directly, and none of that is what
## staticScore claims to be about — leaving it free would let a scale confound
## masquerade as a score effect.
##
## Emits, per candidate: the mapSpec JSON (feedable straight to
## `map_eval play <spec.json>`, which routes it into the server's `mapSpec`
## config field) plus a manifest row carrying staticScore, validity, and every
## band's sub-score so a downstream re-weighting can be tried WITHOUT
## re-generating or re-playing anything.
##
## Usage:
##   nim c -d:release -o:/tmp/scorespread tools/score_spread.nim
##   /tmp/scorespread --seeds 1001,1002,1003 --attempts 9 --size small \
##     --out /tmp/spread

import
  std/[algorithm, json, os, strformat, strutils],
  ../src/ctf/[arena, map_metrics, sim_types]

type SpreadError = object of CatchableError

proc fail(msg: string) {.noreturn.} =
  raise newException(SpreadError, msg)

proc metricsJson(m: MapMetrics): JsonNode =
  ## Everything a re-weighting or a "which band actually moved?" question needs,
  ## without re-running the generator.
  result = %*{
    "name": m.name, "valid": m.valid, "reason": m.reason,
    "width": m.width, "height": m.height, "teams": m.teams,
    "layout": m.layout, "symmetry": m.symmetry, "endzone": m.endzone,
    "staticScore": m.staticScore(),
    "interiorFrac": m.interiorFrac, "coveredFrac": m.coveredFrac,
    "exposedFrac": m.exposedFrac, "longRunFrac": m.longRunFrac,
    "openRunP50Px": m.openRunP50Px, "openRunP95Px": m.openRunP95Px,
    "routeCountMin": m.routeCountMin, "routeCapacityFrac": m.routeCapacityFrac,
    "bottleneckPx": m.bottleneckPx, "chokeCount": m.chokeCount,
    "chokeCovered": m.chokeCovered,
    "collisionCoverRatio": m.collisionCoverRatio,
    "collisionRoutes": m.collisionRoutes,
    "standRingOpenMin": m.standRingOpenMin,
    "standRingSpread": m.standRingOpenMax - m.standRingOpenMin,
    "standCoverSpread": m.standCoverMax - m.standCoverMin,
    "midCrossCount": m.midCrossCount, "midOpenFrac": m.midOpenFrac,
    "detourMax": m.detourMax, "visDegreeCv": m.visDegreeCv,
    "coverPermille": m.coverPermille, "openFloorPx": m.openFloorPx,
  }
  var bands = newJObject()
  for r in m.scoreBands():
    bands[r.band.name] = %*{
      "value": r.value, "sub": r.sub, "weight": r.band.weight,
      "breached": r.breached}
  result["bands"] = bands

proc main() =
  var
    seeds: seq[int]
    attempts = 9
    teams = 2
    size = "small"
    outDir = getTempDir() / "ctf-score-spread"
  let params = commandLineParams()
  var i = 0
  while i < params.len:
    let a = params[i]
    proc value(): string =
      if i + 1 >= params.len: fail(a & " needs a value")
      inc i
      params[i]
    case a
    of "--seeds":
      for part in value().split(','):
        if part.strip().len > 0: seeds.add part.strip().parseInt
    of "--attempts": attempts = value().parseInt
    of "--teams": teams = value().parseInt
    of "--size": size = value()
    of "--out": outDir = value()
    of "-h", "--help":
      echo "score_spread --seeds A,B,C [--attempts 9] [--teams 2] " &
        "[--size small] [--out DIR]"
      quit(0)
    else: fail("unknown flag: " & a)
    inc i
  if seeds.len == 0: fail("need --seeds")
  createDir(outDir)

  var
    overrides = MapGenOverrides(windows: -1, pits: -1, pitDensity: -1)
    rows = newJArray()
  overrides.size = size

  # The control goes in the manifest as a first-class row, never as a footnote.
  # A rubric that ranks the hand-authored arena badly is refuted by that fact
  # alone, so the control has to be measurable on the same axis as everything
  # else rather than quoted from a different report.
  block:
    let
      control = loadCtfMapMetadata("arena")
      metrics = evaluateMap(control, "arena")
      specPath = outDir / "arena.json"
    writeFile(specPath, mapSpecJson(control))
    var row = metricsJson(metrics)
    row["seed"] = %(-1)
    row["attempt"] = %(-1)
    row["label"] = %"arena"
    row["spec"] = %specPath
    rows.add row
    echo &"arena            {metrics.width}x{metrics.height} " &
      &"score={metrics.staticScore():.3f} valid={metrics.valid}"

  for seed in seeds:
    for attempt in 0 ..< attempts:
      let label = &"s{seed}a{attempt}"
      var
        gameMap: CtfMap
        generated = true
      try:
        gameMap = generateMapAttempt(seed, overrides, teams, attempt)
      except CatchableError as e:
        generated = false
        echo &"{label:<16} GENERATOR RAISED: {e.msg}"
      if not generated: continue
      let
        metrics = evaluateMap(gameMap, label)
        specPath = outDir / (label & ".json")
      writeFile(specPath, mapSpecJson(gameMap))
      var row = metricsJson(metrics)
      row["seed"] = %seed
      row["attempt"] = %attempt
      row["label"] = %label
      row["spec"] = %specPath
      rows.add row
      let gate = if metrics.valid: "ok  " else: "GATE"
      echo &"{label:<16} {gate} {metrics.width}x{metrics.height} " &
        &"score={metrics.staticScore():.3f} " &
        &"interior={metrics.interiorFrac * 100:.1f}% " &
        &"cover={metrics.coverPermille}pm " &
        (if metrics.valid: "" else: "(" & metrics.reason & ")")

  # Sorted by score so the spread is visible in the file itself, and so a
  # caller picking N points across the range can just stride the array.
  var sorted = rows.getElems()
  sorted.sort(proc (a, b: JsonNode): int =
    cmp(a["staticScore"].getFloat(), b["staticScore"].getFloat()))
  var ordered = newJArray()
  for r in sorted: ordered.add r
  let manifest = outDir / "manifest.json"
  writeFile(manifest, pretty(%*{
    "seeds": seeds, "attempts": attempts, "teams": teams, "size": size,
    "maps": ordered}))

  var valid: seq[float]
  for r in sorted:
    if r["valid"].getBool(): valid.add r["staticScore"].getFloat()
  echo ""
  echo &"{rows.len} candidate(s), {valid.len} valid"
  if valid.len > 0:
    echo &"valid staticScore range {valid[0]:.3f} .. {valid[^1]:.3f} " &
      &"(spread {valid[^1] - valid[0]:.3f})"
  echo "manifest -> " & manifest

when isMainModule:
  try:
    main()
  except SpreadError as e:
    stderr.writeLine "score_spread: " & e.msg
    quit(2)
