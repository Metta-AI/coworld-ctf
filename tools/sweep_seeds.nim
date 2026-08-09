## sweep_seeds — hunt seeds that fill EMPTY catalog cells (siege / rush /
## large boards), the archetypes the shipped 20-seed pool does not deliver.
##
## For each scanned seed it runs the SAME pipeline the catalog and the server
## do — `generateCtfMap` (best-of-K selection) → `evaluateMap` → `mapRules` →
## `playtypeLabel` / `pacingTier` — and emits one CSV row per seed that clears
## the interest filter:
##   playtype in {siege, rush}  OR  sizeClass in {large, huge}.
## No new geometry and no new metric: every column is a field one of those
## already-shipping calls produced (like `map_catalog.nim`, this is a REPORTING
## tool, not part of the server).
##
## COST. `generateCtfMap` is a full best-of-K selection (~1s on a standard
## board), so the 1000–9999 range is ~2.5 h if run blind. This tool is
## therefore BOUNDED and RESUMABLE: it scans [start, start+count) and streams
## each hit as it finds it, so a caller runs it in capped batches rather than
## one long wedge. Seeds already in `MapPoolSeeds` are skipped (the task adds
## NEW seeds; it never re-lists an existing one).
##
## SIZE REACHABILITY. At the shipping 2-team roster `legalSizeNames(2, 8)` is
## {small, standard} — `generateCtfMap(seed)` (2-team default) can NEVER draw
## large/huge, so the size filter only ever fires when this tool is asked to
## generate at a wider roster. The `-units` flag exists for exactly that probe:
## it widens the size draw (`legalSizeNames(2, units)`) so a large board can
## appear, and the CSV records which roster produced the row. A large hit is
## reported for a FUTURE big-board pool at its own roster; it is not something
## the 2-team `MapPoolSeeds` can serve (see tools/gen_map_pool.nim's SizeQuota).
##
## Usage:
##   nim c -d:release -r tools/sweep_seeds.nim [start] [count] [units] [out.csv]
## Defaults: start=1000 count=9000 units=8 out=sweep_seeds.csv
## Run from the repo ROOT (data/ paths resolve relative to cwd).

import std/[os, strformat, strutils, sets, tables, algorithm]
import ../src/ctf/[arena, sim, map_metrics, map_rules, map_pool, map_taxonomy]

type
  Hit = object
    seed: int
    archetype: string
    size: string
    playtype: string
    pacing: string
    staticScore: float
    chokeCount: int
    routeCountMin: int
    valid: bool
    reason: string

proc interesting(h: Hit): bool =
  ## The empty-cell filter: a siege/rush geometry OR a big board.
  h.playtype in ["siege", "rush"] or h.size in ["large", "huge"]

when isMainModule:
  let
    start = if paramCount() >= 1: parseInt(paramStr(1)) else: 1000
    count = if paramCount() >= 2: parseInt(paramStr(2)) else: 9000
    units = if paramCount() >= 3: parseInt(paramStr(3)) else: 8
    outPath = if paramCount() >= 4: paramStr(4) else: "sweep_seeds.csv"

  # Seeds the pool already lists never get re-hunted.
  var existing: HashSet[int]
  for s in MapPoolSeeds: existing.incl s

  # `units` widens the legal size draw exactly as fitMapSize would for that
  # roster; 8 is the shipping 2-team default (small/standard only).
  let sizes = legalSizeNames(2, units)

  var f = open(outPath, fmWrite)
  f.writeLine("seed,archetype,size,playtype,pacing,staticScore," &
    "chokeCount,routeCountMin,valid,reason,units,legalSizes")
  f.flushFile()

  # Optional: if COVERAGE_CSV is set, ALSO stream every VALID scanned seed's
  # full row there — the raw material for picking addable candidates that fill
  # empty archetype x size cells, not just the siege/rush/large interest set.
  var cov: File
  let covPath = getEnv("COVERAGE_CSV")
  let wantCov = covPath.len > 0
  if wantCov:
    cov = open(covPath, fmWrite)
    cov.writeLine("seed,archetype,size,playtype,pacing,staticScore," &
      "chokeCount,routeCountMin")
    cov.flushFile()

  var
    scanned = 0
    hits = 0
    raised = 0
    playtypeTally = initCountTable[string]()
    sizeTally = initCountTable[string]()
    chokeHist = initCountTable[int]()      ## reachability of siege (>=8)
    routeHist = initCountTable[int]()      ## reachability of rush (route<=2)
    maxChoke = 0
    rushShaped = 0                         ## choke<=1 AND route<=2 (rush cell)
  let legalStr = sizes.join("|")

  for seed in start ..< start + count:
    if seed in existing: continue
    inc scanned
    var gameMap: CtfMap
    try:
      # Same knob the catalog/pool use, but with the roster's size draw so a
      # wider `units` can surface a large board.
      gameMap = generateCtfMap(
        seed, MapGenOverrides(windows: -1, pits: -1, pitDensity: -1),
        teams = 2)
    except CtfError:
      inc raised
      continue

    let
      m = evaluateMap(gameMap, "gen:" & $seed)
      sizeClass = gameMap.mapSizeClass()
      teams = gameMap.teamCount()
      r = mapRules(sizeClass, teams)
      arch = mapArchetypeFor(seed, teams)
      ct = contactTicks(r.playfieldPx, TunedOpponents)
      h = Hit(
        seed: seed,
        archetype: $arch,
        size: sizeClass.sizeName(),
        playtype: playtypeLabel(m, r),
        pacing: pacingTier(ct, TunedContactTicks),
        staticScore: m.staticScore(),
        chokeCount: m.chokeCount,
        routeCountMin: m.routeCountMin,
        valid: m.valid,
        reason: m.reason)

    if wantCov and h.valid:
      cov.writeLine(&"{h.seed},{h.archetype},{h.size},{h.playtype}," &
        &"{h.pacing},{h.staticScore:.4f},{h.chokeCount},{h.routeCountMin}")
      cov.flushFile()

    playtypeTally.inc h.playtype
    sizeTally.inc h.size
    chokeHist.inc h.chokeCount
    routeHist.inc h.routeCountMin
    if h.chokeCount > maxChoke: maxChoke = h.chokeCount
    if h.chokeCount <= RushChokeMax and h.routeCountMin <= RushRouteMax:
      inc rushShaped

    if interesting(h):
      inc hits
      # reason may contain commas — quote it.
      f.writeLine(&"{h.seed},{h.archetype},{h.size},{h.playtype}," &
        &"{h.pacing},{h.staticScore:.4f},{h.chokeCount},{h.routeCountMin}," &
        &"{h.valid},\"{h.reason}\",{units},{legalStr}")
      f.flushFile()
      stderr.writeLine(&"HIT seed={h.seed} {h.playtype}/{h.size}/{h.archetype} " &
        &"score={h.staticScore:.3f} choke={h.chokeCount} " &
        &"routeMin={h.routeCountMin} valid={h.valid}")

  f.close()
  if wantCov: cov.close()
  stderr.writeLine(&"\n== sweep [{start},{start + count}) units={units} " &
    &"legal={legalStr} ==")
  stderr.writeLine(&"scanned={scanned} raised={raised} hits={hits} -> {outPath}")
  stderr.writeLine("playtype distribution (all scanned):")
  for k, v in playtypeTally: stderr.writeLine(&"  {k}: {v}")
  stderr.writeLine("size distribution (all scanned):")
  for k, v in sizeTally: stderr.writeLine(&"  {k}: {v}")
  stderr.writeLine(&"siege reachability: maxChoke={maxChoke} " &
    &"(SiegeChokeCount={SiegeChokeCount}); chokeCount histogram:")
  for c in 0 .. maxChoke:
    if chokeHist.getOrDefault(c) > 0:
      stderr.writeLine(&"  choke={c}: {chokeHist[c]}")
  stderr.writeLine(&"rush reachability: rush-shaped(choke<={RushChokeMax} " &
    &"AND route<={RushRouteMax})={rushShaped}; routeCountMin histogram:")
  var routeKeys: seq[int]
  for k in routeHist.keys: routeKeys.add k
  routeKeys.sort()
  for k in routeKeys:
    stderr.writeLine(&"  routeMin={k}: {routeHist[k]}")
