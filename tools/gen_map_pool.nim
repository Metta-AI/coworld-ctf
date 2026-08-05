## Regenerates src/ctf/map_pool.nim: scans a seed range, generates the map
## each seed ACTUALLY SHIPS, scores it against the hand-authored arena, and
## keeps the highest scorers under a size-class quota.
##
## Usage: nim c -d:release -r tools/gen_map_pool.nim [startSeed] [scanCount]
## Demo/curation tooling; not part of the server.
##
## THIS USED TO CURATE ON VALIDITY. It kept "the first seeds whose map passes
## every validator on the FIRST attempt", which selected nothing — at a ~77%
## first-attempt pass rate that is the first twenty-odd seeds in the range,
## and the fitness harness then measured every one of them as FLATTER than
## the control (interior 9.9-17.9% against the arena's 32.5% on the square
## board). "The curated pool" was never curated.
##
## Two things changed underneath it and both are load-bearing here:
##
##   * `generateCtfMap` is now best-of-K, so a SEED no longer names one draw
##     — it names the best of K draws of the same board. Curation must
##     therefore call `generateCtfMap`, not `generateMapAttempt`, and must
##     call it at the SHIPPED K. Curating at a higher K would pin seeds whose
##     runtime map is a different map, which is the subtlest possible way to
##     ship an uncurated pool.
##   * retries no longer roll the seed forward (they perturb the terrain
##     sub-streams instead), so the old "first-attempt only" rule — which
##     existed precisely because attempt 1 of seed N was attempt 0 of seed
##     N+1 — is obsolete. A pool entry is the map its seed makes, whether
##     that took one attempt or nine.
import std/[algorithm, os, strutils, strformat, times], ../src/ctf/sim

const
  PoolSize = 20
  SizeQuota: array[HexSizeClass, int] = [4, 5, 4, 4, 3, 0]
    ## small, standard, large, huge, giant, colossal. Colossal is
    ## override-only and never drawn at random, so its quota is 0 by
    ## construction rather than by the array simply being short.
  DefaultScan = 120
    ## Seeds scanned. The quota needs 3-5 entries per class and the size
    ## class is drawn uniformly over five classes, so ~24 candidates per
    ## class is roughly a 1-in-6 selection — enough for the ranking to mean
    ## something without the scan taking an hour.

  ## There is no ENDZONE-SHAPE quota any more: the hex arena is all-disc
  ## (`EndzoneShape` has one member), so the old column/disc/square split had
  ## nothing left to balance. Variety in the endzone now lives in its RADIUS
  ## and the base depth, both of which the generator draws per seed.

type
  Entry = object
    seed: int
    cls: HexSizeClass
    score: float
    gameMap: CtfMap

proc sizeClass(gameMap: CtfMap): HexSizeClass =
  ## The size class this board's dimensions name, looked up in `HexSizes` —
  ## the ONE table `scaledGenShell` scales from. The old form re-listed five
  ## widths of the rectangular board and raised on anything else, so after the
  ## hex conversion it raised on EVERY generated map; deriving it from the
  ## source of truth cannot go stale that way again.
  for cls in HexSizeClass:
    if HexSizes[cls].width == gameMap.width and
        HexSizes[cls].height == gameMap.height:
      return cls
  raise newException(
    CtfError, "Map " & $gameMap.width & "x" & $gameMap.height &
      " matches no hex size class.")

when isMainModule:
  let
    start = if paramCount() >= 1: parseInt(paramStr(1)) else: 1001
    scan = if paramCount() >= 2: parseInt(paramStr(2)) else: DefaultScan
  ## Meta-rule 1: the control runs in every batch, and it is what three of
  ## the score's bands are anchored on.
  let control = controlMetrics()
  echo &"control: arena {control.width}x{control.height} " &
    &"interior={control.interiorFrac * 100:.1f}% " &
    &"wall={control.wallFrac * 100:.1f}%  " &
    &"(scoring {scan} seeds at the SHIPPED K={MapRankDefaultK})"

  var
    entries: seq[Entry]
    failed = 0
  let started = epochTime()
  for i in 0 ..< scan:
    let seed = start + i
    var gameMap: CtfMap
    try:
      gameMap = generateCtfMap(seed)
    except CatchableError as e:
      inc failed
      echo &"seed={seed} NO VALID MAP: {e.msg}"
      continue
    let
      metrics = computeMapMetrics(
        gameMap, withChokepoints = false, withValidation = false)
      gate = hardGates(metrics)
    if gate.len > 0:
      ## The shipped validators already passed (generateCtfMap returned), so
      ## this can only be one of the two gates the repo never had: no
      ## independent flank route, or an unreachable base.
      inc failed
      echo &"seed={seed} GATE {gate}"
      continue
    entries.add Entry(seed: seed, cls: gameMap.sizeClass(),
      score: scoreMap(metrics, control).score, gameMap: gameMap)
    if (i + 1) mod 10 == 0:
      echo &"  ...{i + 1}/{scan} scanned, {entries.len} scorable, " &
        &"{epochTime() - started:.0f}s"
      stdout.flushFile()
  echo &"scanned={scan} scorable={entries.len} unusable={failed} " &
    &"in {epochTime() - started:.0f}s"

  ## Best first, WITHIN each size class. Sorting globally and taking the top
  ## 20 would fill the pool with whichever class the rubric happens to
  ## favour; the quota exists so a game on a giant board is still a game the
  ## pool can serve.
  entries.sort(proc (a, b: Entry): int = cmp(b.score, a.score))
  var
    seeds: seq[int]
    counts: array[HexSizeClass, int]
    chosen: seq[Entry]
  for entry in entries:
    if counts[entry.cls] >= SizeQuota[entry.cls]:
      continue
    inc counts[entry.cls]
    chosen.add entry
    if chosen.len >= PoolSize:
      break
  ## Report what was taken AND what was left, per class — a quota that ran
  ## out of candidates is a scan that was too short, and it should be
  ## visible rather than inferred from a short pool.
  for cls in HexSizeClass:
    let
      pool = entries.filterIt(it.cls == cls)
      taken = chosen.filterIt(it.cls == cls)
    if pool.len == 0 and SizeQuota[cls] == 0:
      continue
    let
      best = if taken.len > 0: taken[0].score else: 0.0
      worstTaken = if taken.len > 0: taken[^1].score else: 0.0
      worstSeen = if pool.len > 0: pool[^1].score else: 0.0
    echo &"  {HexClassNames[cls]:<10} took {taken.len}/{SizeQuota[cls]} " &
      &"of {pool.len} candidates; score {best * 100:.1f} down to " &
      &"{worstTaken * 100:.1f} (worst available {worstSeen * 100:.1f})"
    if taken.len < SizeQuota[cls]:
      echo &"    !! quota unfilled — widen the scan"
  ## Order the pool by seed so the generated file reads as a set, not as a
  ## ranking that will look stale the moment the rubric moves.
  chosen.sort(proc (a, b: Entry): int = cmp(a.seed, b.seed))
  for entry in chosen:
    seeds.add entry.seed
    echo &"pool[{seeds.len - 1}] seed={entry.seed} " &
      &"score={entry.score * 100:.1f} " &
      &"{HexClassNames[entry.cls]} " &
      &"{entry.gameMap.width}x{entry.gameMap.height} " &
      &"sym={entry.gameMap.symmetry} " &
      &"r={entry.gameMap.endzoneRadius} " &
      &"home={entry.gameMap.teamHomeX(Red)} " &
      &"obstacles={entry.gameMap.leftObstacles.len}"
  if seeds.len < PoolSize:
    quit(&"only {seeds.len} of {PoolSize} pool slots filled — " &
      "rerun with a larger scan count.")

  var lines = @[
    "## GENERATED by `nim c -r tools/gen_map_pool.nim` — do not edit by hand.",
    "## The curated terrain pool: the highest-SCORING seeds in the scanned",
    "## range under a size-class quota, where the score is the static rubric",
    "## in `ctf/map_score` measured against the hand-authored arena as the",
    "## control. Each entry is the map `generateCtfMap` ships for that seed,",
    "## i.e. best-of-" & $MapRankDefaultK & " — so the pool and the runtime",
    "## must always agree on K.",
    "",
    "const MapPoolSeeds*: array[" & $PoolSize & ", int] = [",
  ]
  for i in countup(0, PoolSize - 1, 10):
    var chunk: seq[string]
    for j in i ..< min(i + 10, PoolSize):
      chunk.add $seeds[j]
    lines.add "  " & chunk.join(", ") & ","
  lines.add "]"
  let outPath =
    currentSourcePath.parentDir.parentDir / "src" / "ctf" / "map_pool.nim"
  writeFile(outPath, lines.join("\n") & "\n")
  echo "wrote ", outPath
