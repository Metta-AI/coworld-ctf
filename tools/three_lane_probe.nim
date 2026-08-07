## three_lane_probe — WHOSE permille is it?
##
## `2026-08-06-archetype-fingerprints.md` measured `three-lane` as the only
## archetype that fails validity (8/10 against 100% everywhere else), and both
## failures are "too clogged" against the 170 permille ceiling. A cover verdict
## on the finished map names a seed, not a cause: `leftObstacles` is emitted in
## FOUR layers and only one of them has a budget.
##
##   structure  the topology's own walls — lane separators and gates, or an
##              archetype's chicanes. Spends FIRST and is never dropped.
##   fill       the vocabulary masses plus the biome texture, reconciled
##              against the routes and then BUDGETED.
##   centre     the spinning-diamond feature. Unbudgeted, but it is 1-5
##              diamonds and the same policy set is available to every
##              archetype.
##   pickets    the constructive row cover. Unbudgeted BY DESIGN — it exists
##              to close a hard validator failure — and `three-lane` is the
##              only archetype that runs the pass TWICE, once inside
##              `map_lanes.carveLanes` and once in `arena`.
##
## Each layer's cover is read off the validator's OWN mask by rasterising a
## PREFIX of the finished obstacle list, not by summing shape areas — the fill
## layers overlap by construction, so an area sum over-counts exactly where it
## matters.
##
## Requires `-d:maptrace`, which is what populates `arena.lastMapGenTrace`.
## Imports `map_metrics` (via `sim`) so the best-of-K ranker is LINKED; a probe
## that omits it silently measures first-valid instead. The header prints
## `mapFitnessLabel()` so that can never be assumed again.
##
##   nim c -d:release -d:maptrace -r tools/three_lane_probe.nim [count] [teams]
##   nim c -d:release -d:maptrace -r tools/three_lane_probe.nim --seeds=1026,1038
##
## Demo/curation tooling; not part of the server.
import std/[os, strformat, strutils, tables]
import ../src/ctf/[sim, arena, map_metrics, map_rules]

when not defined(maptrace):
  {.error: "three_lane_probe needs -d:maptrace (see arena.MapGenTrace).".}

const NoOverrides = MapGenOverrides(windows: -1, pits: -1, pitDensity: -1)

proc coverOfPrefix(gameMap: CtfMap, upTo: int): int =
  ## Cover permille of the first `upTo` obstacles, measured on the same mask
  ## `validateGeneratedMap` reads — protected floor carved back out and every
  ## symmetry image counted, which is the whole reason not to sum areas.
  if upTo <= 0: return 0
  var partial = gameMap
  partial.leftObstacles = gameMap.leftObstacles[0 ..< min(upTo,
    gameMap.leftObstacles.len)]
  mapDiagnostics(partial, {}).coverPermille

type AttemptRow = object
  seed, attempt: int
  arch: string
  size: string
    ## The board SHELL's size class. It belongs to the seed, not the attempt
    ## (`map_seed.seedStream` holds it fixed), so it is the one candidate
    ## explanation a per-attempt sweep cannot reach — a structure network of
    ## fixed absolute size costs more permille on a smaller board.
  valid: bool
  reason: string
  cover, structureCover, fillCover, centreCover: int
  structure, fill, centre, rowPickets, lanePickets: int
  fillOffered, fillDropped, budgetSkipped: int
  routeMin: int
  score: float

proc probeAttempt(seed, attempt, teams: int): AttemptRow =
  var gameMap: CtfMap
  try:
    gameMap = generateMapAttempt(seed, NoOverrides, teams, attempt)
  except CtfError as e:
    return AttemptRow(seed: seed, attempt: attempt,
      arch: $mapArchetypeFor(seed, teams), reason: "raised: " & e.msg)
  let t = lastMapGenTrace
  result = AttemptRow(
    seed: seed, attempt: attempt, arch: t.arch,
    structure: t.structureEnd,
    fill: t.fillEnd - t.structureEnd,
    centre: t.centreEnd - t.fillEnd,
    rowPickets: t.rowPickets,
    lanePickets: t.lanePickets,
    fillOffered: t.fillOffered, fillDropped: t.fillDropped,
    budgetSkipped: t.budgetSkipped,
    size: sizeName(gameMap.mapSizeClass()))
  result.reason = validateGeneratedMap(gameMap)
  result.valid = result.reason.len == 0
  let m = evaluateMap(gameMap, "gen")
  result.cover = m.coverPermille
  result.routeMin = m.routeCountMin
  result.score = m.staticScore()
  result.structureCover = gameMap.coverOfPrefix(t.structureEnd)
  result.fillCover = gameMap.coverOfPrefix(t.fillEnd)
  result.centreCover = gameMap.coverOfPrefix(t.centreEnd)

proc main() =
  var
    count = 40
    teams = 2
    attempts = 0        ## 0 = the size class's own K
    seeds: seq[int]
    positional: seq[string]
  for i in 1 .. paramCount():
    let a = paramStr(i)
    if a.startsWith("--seeds="):
      for s in a["--seeds=".len .. ^1].split(','): seeds.add parseInt(s)
    elif a.startsWith("--attempts="):
      attempts = parseInt(a["--attempts=".len .. ^1])
    else: positional.add a
  if positional.len >= 1: count = parseInt(positional[0])
  if positional.len >= 2: teams = parseInt(positional[1])
  if seeds.len == 0:
    for i in 0 ..< count: seeds.add 1001 + i

  echo &"ranker: {mapFitnessLabel()}   teams={teams}   seeds={seeds.len}"
  echo &"cover ceiling {CoverPermilleMax} permille; " &
    "each layer's cover is CUMULATIVE (prefix of leftObstacles)"
  echo ""
  echo "seed  att arch       size     valid cover  struct  +fill  +centre  " &
    "pickets(lane/row)  shapes(s/f/c)  drop/skip  rt  score"

  var rows, winners: seq[AttemptRow]
  for seed in seeds:
    ## MIRROR `arena.generateCtfMapSelection` EXACTLY: draw until K candidates
    ## have PASSED, not until K have been drawn. Stopping at attempt K-1 was
    ## wrong and said so out loud — seed 1004 reported its two early
    ## first-K survivors as the shipping map while the real selection keeps
    ## drawing to 100 and ships a different, better board.
    ## `--attempts=N` draws exactly N candidates per seed whatever they score:
    ## a MATCHED sample across archetypes, which is what a layer comparison
    ## needs. Without it the sample is per-seed selection-length weighted, and
    ## a sick archetype contributes ten times the rows of a healthy one.
    let
      k = selectionK(generateMapAttempt(seed, NoOverrides, teams, 0))
      drawCap = if attempts > 0: attempts else: MapGenMaxAttempts
    var
      passed = 0
      best = AttemptRow(score: -1.0)
    for attempt in 0 ..< drawCap:
      let r = probeAttempt(seed, attempt, teams)
      rows.add r
      echo &"{r.seed} {r.attempt:<3} {r.arch:<10} {r.size:<8} " &
        &"{(if r.valid: \"ok   \" else: \"FAIL \")}" &
        &"{r.cover:<6} {r.structureCover:<7} {r.fillCover:<6} " &
        &"{r.centreCover:<8} {r.lanePickets:>3}/{r.rowPickets:<13} " &
        &"{r.structure}/{r.fill}/{r.centre:<9} " &
        &"{r.fillDropped}/{r.budgetSkipped:<8} {r.routeMin:<3} {r.score:.3f}" &
        (if r.valid: "" else: "   " & r.reason)
      if not r.valid: continue
      inc passed
      if r.score > best.score: best = r
      if attempts == 0 and passed >= k: break
    if best.score >= 0.0: winners.add best
    else: echo &"{seed} — NO VALID CANDIDATE in {MapGenMaxAttempts} attempts"

  ## The layer table. Means per archetype of the MARGINAL cover each layer
  ## adds, which is the number a budget conversation needs.
  proc layerTable(title: string, sample: seq[AttemptRow]) =
    echo ""
    echo title
    echo "archetype    n    structure  fill   centre  pickets  total  " &
      "lanePickets rowPickets  valid"
    var byArch = initOrderedTable[string, seq[AttemptRow]]()
    for r in sample:
      if r.arch.len == 0: continue
      byArch.mgetOrPut(r.arch, @[]).add r
    for arch, group in byArch:
      var s, f, c, p, tot, lp, rp, valid = 0
      for r in group:
        s += r.structureCover
        f += r.fillCover - r.structureCover
        c += r.centreCover - r.fillCover
        p += r.cover - r.centreCover
        tot += r.cover
        lp += r.lanePickets
        rp += r.rowPickets
        if r.valid: inc valid
      let n = group.len
      echo &"{arch:<12} {n:<4} {s div n:<10} {f div n:<6} {c div n:<7} " &
        &"{p div n:<8} {tot div n:<6} {lp div n:<11} {rp div n:<11} " &
        &"{valid}/{n}"

  layerTable("PER-ARCHETYPE LAYER SPEND — EVERY CANDIDATE DRAWN " &
    "(mean permille, marginal)", rows)
  ## The candidate population is the budget question; the WINNERS are the
  ## boards that ship. Both, because an archetype can be healthy in one and
  ## sick in the other and the two answers need different fixes.
  layerTable("PER-ARCHETYPE LAYER SPEND — THE WINNING BOARD ONLY " &
    "(mean permille, marginal)", winners)

when isMainModule:
  main()
