## map_catalog — the coverage view of the shipped terrain pool.
##
## Iterates all 20 `MapPoolSeeds`, and for each computes the four catalog
## coordinates:
##   archetype (route topology, `mapArchetypeFor`)
##   size      (`mapSizeClass`)
##   playtype  (`map_taxonomy.playtypeLabel`)
##   pacing    (`map_taxonomy.pacingTier`)
## then prints a per-map table, an archetype x size x playtype grid, and the
## list of EMPTY cells — combinations the pool does not contain. The empty
## cells are the point: they say which kinds of map a designer would have to
## author or seed-hunt for, because the current pool does not deliver them.
##
## NO new geometry and NO new metric: every coordinate is read off
## `generateCtfMap` / `evaluateMap` / `mapRules`, the same values the server
## and the ranker already compute. This is a REPORTING tool (like
## `archetype_probe`), not part of the server.
##
## Usage:  nim c -d:release -r tools/map_catalog.nim
## Costs one best-of-K selection per seed (~1s on a standard board).

import std/[strutils, strformat, tables, sets, sequtils]
import ../src/ctf/[arena, sim, map_metrics, map_rules, map_archetypes,
  map_pool, map_taxonomy]

const
  Playtypes = ["rush", "control", "siege", "skirmish", "overwatch"]
  Pacings = ["fast", "standard", "methodical"]

type
  Row = object
    seed: int
    archetype: string
    size: string
    playtype: string
    pacing: string
    chokeCount: int
    routeCountMin: int
    longRunFrac: float
    visDegreeCv: float
    coverPermille: int
    contactTicks: float

proc classifyPool(): seq[Row] =
  ## One row per pool seed. Memoises nothing — a single pass, one selection
  ## each — because the tool runs once and prints.
  for seed in MapPoolSeeds:
    let
      gameMap = generateCtfMap(seed)
      m = evaluateMap(gameMap, "gen:" & $seed)
      sizeClass = gameMap.mapSizeClass()
      teams = gameMap.teamCount()
      r = mapRules(sizeClass, teams)
      arch = mapArchetypeFor(seed, teams)
      ct = contactTicks(r.playfieldPx, TunedOpponents)
    result.add Row(
      seed: seed,
      archetype: $arch,
      size: sizeClass.sizeName(),
      playtype: playtypeLabel(m, r),
      pacing: pacingTier(ct, TunedContactTicks),
      chokeCount: m.chokeCount,
      routeCountMin: m.routeCountMin,
      longRunFrac: m.longRunFrac,
      visDegreeCv: m.visDegreeCv,
      coverPermille: m.coverPermille,
      contactTicks: ct)

proc distinctInOrder(xs: seq[string]): seq[string] =
  ## Distinct values, first-seen order, so tables read stably run to run.
  var seen: HashSet[string]
  for x in xs:
    if x notin seen:
      seen.incl x
      result.add x

when isMainModule:
  let rows = classifyPool()

  # --- per-map table -------------------------------------------------------
  echo "## Pool catalog — ", rows.len, " seeds"
  echo ""
  echo "| seed | archetype | size | playtype | pacing | choke | routeMin | longRunFrac | visCv | cover‰ | contactTicks |"
  echo "|------|-----------|------|----------|--------|-------|----------|-------------|-------|--------|--------------|"
  for r in rows:
    echo &"| {r.seed} | {r.archetype} | {r.size} | {r.playtype} | {r.pacing} | " &
      &"{r.chokeCount} | {r.routeCountMin} | {r.longRunFrac:.3f} | " &
      &"{r.visDegreeCv:.3f} | {r.coverPermille} | {r.contactTicks:.1f} |"
  echo ""

  # --- coordinate tallies --------------------------------------------------
  proc tally(sel: proc(r: Row): string): CountTable[string] =
    for r in rows: result.inc sel(r)
  proc showTally(title: string, order: seq[string], t: CountTable[string]) =
    echo "**", title, ":**  ",
      order.mapIt(&"{it} {t.getOrDefault(it, 0)}").join(" · ")

  let
    archs = distinctInOrder(rows.mapIt(it.archetype))
    sizes = distinctInOrder(rows.mapIt(it.size))
  echo "### Marginals"
  echo ""
  showTally("archetype", archs, tally(proc(r: Row): string = r.archetype))
  showTally("size", sizes, tally(proc(r: Row): string = r.size))
  showTally("playtype", @Playtypes, tally(proc(r: Row): string = r.playtype))
  showTally("pacing", @Pacings, tally(proc(r: Row): string = r.pacing))
  echo ""

  # --- archetype x size x playtype grid ------------------------------------
  # The catalog's core view. One block per size class; rows are archetypes,
  # columns are playtypes, each cell the seed count.
  var counts = initTable[string, int]()
  proc key(a, s, p: string): string = a & "\x1f" & s & "\x1f" & p
  for r in rows:
    counts.mgetOrPut(key(r.archetype, r.size, r.playtype), 0).inc

  echo "### Coverage grid — archetype x playtype, per size class"
  for s in sizes:
    echo ""
    echo "#### size: ", s
    echo ""
    echo "| archetype \\ playtype | ", Playtypes.join(" | "), " |"
    echo "|", repeat("---|", Playtypes.len + 1)
    for a in archs:
      var cells: seq[string]
      for p in Playtypes:
        let c = counts.getOrDefault(key(a, s, p), 0)
        cells.add(if c == 0: "·" else: $c)
      echo "| ", a, " | ", cells.join(" | "), " |"

  # --- empty cells ---------------------------------------------------------
  # Every (archetype, size, playtype) the pool COULD show but does not. Pacing
  # is folded in: it is a pure function of size here (all seeds run the shipping
  # roster), so it adds no independent cell — noted rather than crossed.
  echo ""
  echo "### Empty cells (archetype x size x playtype combinations absent from the pool)"
  echo ""
  var empties: seq[string]
  for a in archs:
    for s in sizes:
      for p in Playtypes:
        if counts.getOrDefault(key(a, s, p), 0) == 0:
          empties.add &"{a} / {s} / {p}"
  let total = archs.len * sizes.len * Playtypes.len
  echo "Present: ", total - empties.len, " of ", total,
    " (archetype x size x playtype) cells.  Empty: ", empties.len, "."
  echo ""
  for e in empties:
    echo "- ", e

  # --- pacing note ---------------------------------------------------------
  echo ""
  echo "### Pacing by size class"
  echo ""
  echo "Pacing is a function of the size class under the shipping roster " &
    "(all pool seeds are 2-team, 8 units/side), so it does not vary within a " &
    "class. Observed:"
  echo ""
  var pacingBySize = initTable[string, string]()
  for r in rows: pacingBySize[r.size] = r.pacing
  for s in sizes:
    echo "- **", s, "** → ", pacingBySize.getOrDefault(s, "?"),
      "  (contactTicks vs TunedContactTicks=", &"{TunedContactTicks:.1f}", ")"
