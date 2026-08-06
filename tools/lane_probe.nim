## lane_probe — where the cover permille of a generated half actually GOES.
##
## The sweep reports one number ("too clogged, 196pm"); this splits it into the
## structure the plan emits before any cover lands (separators, gate shoulders,
## row pickets) versus the fill. A structural share that already exceeds the
## ceiling is the tell that no density sweep can rescue the seed.
##
##   nim c -d:release -r tools/lane_probe.nim [seed] [teams]
import std/[os, strformat, strutils, random]
import ../src/ctf/[map_rules, map_lanes, sim_types, sim, map_metrics]

proc areaOf(shapes: seq[ArenaShape], w, h: int): int =
  ## Painted-pixel count, deduplicated — overlapping walls must not be counted
  ## twice or the structural share reads high for the wrong reason.
  ## Separator and gate shapes are all rects, so a rect-only rasteriser is
  ## exact here rather than an approximation.
  var grid = newSeq[bool](w * h)
  for s in shapes:
    doAssert s.kind == shapeRect
    for y in max(0, s.rect.y) .. min(h - 1, s.rect.y + s.rect.h - 1):
      for x in max(0, s.rect.x) .. min(w - 1, s.rect.x + s.rect.w - 1):
        grid[y * w + x] = true
  for v in grid:
    if v: inc result

proc report(seed, teams: int, cls: MapSizeClass) =
  var rng = initRand(seed)
  let rules = mapRules(cls, teams, boardRect2)
  let (bw, bh) = cls.boardDims(boardRect2)
  echo &"seed {seed} class={rules.sizeName} board={bw}x{bh} " &
    &"laneCount={rules.laneCount} laneWidth={rules.laneWidthPx} " &
    &"minCorridor={rules.minCorridorWidthPx} cover={rules.coverSizePx} " &
    &"coverPermille band={rules.coverPermilleMin}..{rules.coverPermilleMax}"
  let
    region = MapRect(x: BorderPx, y: BorderPx,
      w: bw div 2 - BorderPx, h: bh - 2 * BorderPx)
    base = MapPoint(x: BorderPx + 60, y: bh div 2)
    seamX = bw div 2
    plan = planLanes(rng, region, base, seamX, rules)
  let
    seps = laneSeparatorShapes(plan)
    gates = laneGateShapes(plan)
    domain = region.w * region.h
  echo &"  plan: lanes={plan.lanes.len} sepThick={plan.sepThickPx} " &
    &"laneStartX={plan.laneStartX} seamX={plan.seamX} domain={domain}px"
  for i, lane in plan.lanes:
    echo &"    lane {i} role={lane.role} w={lane.widthPx} " &
      &"len={lane.lengthPx} gates={lane.gates.len}"
  let
    sepA = seps.areaOf(bw, bh)
    gateA = gates.areaOf(bw, bh)
    bothA = (seps & gates).areaOf(bw, bh)
  echo &"  separators: {seps.len} shapes {sepA}px = " &
    &"{sepA * 1000 div domain}pm of half-domain"
  echo &"  gates:      {gates.len} shapes {gateA}px = " &
    &"{gateA * 1000 div domain}pm"
  echo &"  STRUCTURE:  {bothA}px = {bothA * 1000 div domain}pm " &
    &"(ceiling {rules.coverPermilleMax}pm)"
  var scan: seq[string]
  for t in [12, 14, 16, 18, 20, 22, 26]:
    let a = laneSeparatorShapes(plan, t).areaOf(bw, bh)
    scan.add &"{t}px={a * 1000 div domain}pm"
  echo "  sep thickness scan: ", scan.join("  ")

proc sheet(count, teams: int) =
  ## Per-seed end-to-end result. `gen_sweep` reports the medians; the medians
  ## move when a previously-FAILING seed starts passing, so a per-seed sheet is
  ## the only way to tell a real regression from the new arrivals arriving.
  for i in 0 ..< count:
    let seed = 1001 + i
    var line = &"seed {seed}: "
    try:
      let
        gm = generateCtfMap(seed, teams = teams)
        m = evaluateMap(gm, "gen")
      line &= &"{gm.width}x{gm.height} " &
        &"{(if m.valid: \"OK  \" else: \"FAIL\")} " &
        &"cover={m.coverPermille}pm int={m.interiorFrac:.3f} " &
        &"routes={m.routeCountMin}..{m.routeCountMax} " &
        &"score={m.staticScore():.3f}"
      if not m.valid: line &= "  " & m.reason
    except CtfError:
      line &= "NO VALID LAYOUT IN 100 ATTEMPTS"
    echo line

proc main() =
  let
    seed = if paramCount() >= 1: parseInt(paramStr(1)) else: 1015
    teams = if paramCount() >= 2: parseInt(paramStr(2)) else: 2
    mode = if paramCount() >= 3: paramStr(3) else: ""
  case mode
  of "all":
    for c in MapSizeClass:
      if MapSizeClassTable[c].drawable: report(seed, teams, c)
  of "sheet": sheet(seed, teams)   ## first arg is a COUNT in this mode
  else: report(seed, teams, MapSizeClass(sizeClassOfWidth(1050, boardRect2)))

main()
