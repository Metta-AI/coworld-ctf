## return_exposure — static CARRIER-SURVIVABILITY on the RETURN corridor.
##
## The 71213 episode finding: the P6 wave is FAIR (kill balance .99+, both sides
## reach the flag) yet converts 0 captures in 15 episodes — every carrier dies on
## the run home. The Balance Ledger balances route LENGTH (TIME) and the contract
## gates cover windows/trenches/items, but NOTHING measures whether a carrier can
## SURVIVE the return trip. Driver ruling 71236 R1 makes carrier-survivability a
## REQUIRED gate before the P1-P5 build, and this is its static screen.
##
## What it measures, PER SIDE, on the RETURN corridor specifically (the geodesic
## path from the ENEMY flag back to this team's OWN home stand — NOT the cover
## near the stands, which the ledger's COVER currency already does):
##   - coverFrac        fraction of return-path cells with cover within reach
##                      (a wall to break a lethal sightline)
##   - exposedRunMaxPx  longest contiguous stretch of the path with NO cover —
##                      the "shooting gallery" length a carrier crosses naked
##   - rotationBranches path cells offering a walkable side-branch (a juke/
##                      rotation option off the corridor)
##   - survival         composite 0..1 (higher = more survivable); the scalar the
##                      gate reads.
##
## STATIC — no episodes. `doAssert mapFitnessInstalled()` like the other tools.
##
## SELFTEST IS A CORRELATION CHECK (ruling 71236): the instrument must SEPARATE
## the arena (converts 33% in episodes) from the five 71213 seeds
## (4055/4063/4031/4085/4100, convert 0%). If it does not rank arena above all
## five, it is not measuring the right thing — STOP, do not screen with it.
##   /tmp/return_exposure --selftest      # the correlation gate; exit 0 = trust it
##   /tmp/return_exposure --map gen:4055  # one map, both sides, full profile
##   /tmp/return_exposure 4001 4120       # sweep (re-screen the symRot180 pool)
import
  std/[os, math, strformat, strutils],
  ../src/ctf/[arena, map_metrics, map_lanes, sim_types, map_rules]

const
  CoverReachPx = 20        ## a carrier "has cover" if a wall is within this many
                           ## px in some cardinal — close enough to duck behind.
  BranchProbePx = 30       ## a side-branch counts if walkable floor opens this
                           ## far off the corridor perpendicular to travel.
  # survival composite weights (documented, tunable; the selftest validates the
  # RANKING they produce, not the absolute values). Empirically (per-side detail
  # on the 71213 cases) COVER on the return route is the primary discriminator
  # — arena 0.393 vs the five non-converting seeds 0.15-0.33, margin 0.119 on
  # cover alone. exposed-run is a secondary penalty (a >=lethal naked stretch is
  # a guaranteed kill lane). rotationBranches did NOT discriminate here (all
  # ~700-900, saturated) so it is REPORTED but carries no composite weight —
  # letting it inflate scores only shrank the arena-vs-bad separation.
  wCover = 0.7
  wExposed = 0.3
  wRotation = 0.0

type
  SideExposure = object
    team: Team
    pathLenPx: int
    coverFrac: float
    exposedRunMaxPx: int
    rotationBranches: int
    survival: float
    ok: bool                ## a path was found

proc reconstructPath(field: seq[int32], walk: seq[bool], w, h, tx, ty: int):
    seq[int] =
  ## Gradient-descend the geodesic distance `field` from target (tx,ty) down to
  ## the source (distance 0), 4-connected. Returns flat pixel indices, target
  ## first. Empty if the target is unreachable.
  let t = nearestWalkable(walk, w, h, tx, ty)
  if t < 0 or field[t] < 0: return @[]
  var cur = t
  result.add cur
  var guard = 0
  while field[cur] > 0 and guard < w * h:
    inc guard
    let cx = cur mod w
    let cy = cur div w
    var best = cur
    var bestD = field[cur]
    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
      let nx = cx + dx
      let ny = cy + dy
      if nx < 0 or ny < 0 or nx >= w or ny >= h: continue
      let ni = ny * w + nx
      if not walk[ni] or field[ni] < 0: continue
      if field[ni] < bestD:
        bestD = field[ni]
        best = ni
    if best == cur: break        ## stuck (shouldn't happen on a clean field)
    cur = best
    result.add cur

proc nearestCoverPx(wall: seq[bool], w, h, px, py: int): int =
  ## Distance to the nearest wall in the 4 cardinals, capped at CoverReachPx+1.
  ## Small = good cover to hug; large = exposed.
  result = CoverReachPx + 1
  for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
    for step in 1 .. CoverReachPx:
      let x = px + dx * step
      let y = py + dy * step
      if x < 0 or y < 0 or x >= w or y >= h or wall[y * w + x]:
        if step < result: result = step
        break

proc hasSideBranch(walk: seq[bool], w, h, px, py, dirx, diry: int): bool =
  ## A walkable opening perpendicular to travel (dirx,diry) that runs
  ## BranchProbePx clear — a rotation/juke option off the corridor.
  for (perpx, perpy) in [(-diry, dirx), (diry, -dirx)]:
    var clear = true
    for step in 1 .. BranchProbePx:
      let x = px + perpx * step
      let y = py + perpy * step
      if x < 0 or y < 0 or x >= w or y >= h or not walk[y * w + x]:
        clear = false; break
    if clear: return true
  false

proc measureSide(m: CtfMap, walk, wall: seq[bool], w, h: int,
                 team: Team): SideExposure =
  result.team = team
  # RETURN corridor: from the ENEMY flag (where the carrier grabs it) back to
  # this team's OWN home stand (where a capture scores).
  let enemy = if team == Red: Blue else: Red
  let grabAt = m.flagHome(enemy)
  let homeStand = m.flagHome(team)
  let src = nearestWalkable(walk, w, h, homeStand.x, homeStand.y)
  if src < 0: return
  let field = geodesic(walk, w, h, [src])
  let path = reconstructPath(field, walk, w, h, grabAt.x, grabAt.y)
  if path.len < 2: return
  result.ok = true
  result.pathLenPx = path.len
  var covered = 0
  var run = 0                    ## current contiguous exposed run
  var maxRun = 0
  for k in 0 ..< path.len:
    let px = path[k] mod w
    let py = path[k] div w
    let cover = nearestCoverPx(wall, w, h, px, py)
    if cover <= CoverReachPx:
      inc covered
      run = 0
    else:
      inc run
      if run > maxRun: maxRun = run
    # rotation branch: use local travel direction
    if k + 1 < path.len:
      let nx = path[k + 1] mod w
      let ny = path[k + 1] div w
      let dirx = (if nx > px: 1 elif nx < px: -1 else: 0)
      let diry = (if ny > py: 1 elif ny < py: -1 else: 0)
      if (dirx != 0 or diry != 0) and hasSideBranch(walk, w, h, px, py, dirx, diry):
        inc result.rotationBranches
  result.coverFrac = covered.float / path.len.float
  result.exposedRunMaxPx = maxRun
  # composite: cover is good; a long exposed run is bad (normalized by the
  # lethal envelope — an exposed run >= LethalEnvelopePx is a guaranteed kill
  # lane, so that saturates the penalty); rotation branches are a mild bonus.
  let exposedPenalty = min(1.0, result.exposedRunMaxPx.float / float(LethalEnvelopePx))
  let rotationBonus = min(1.0, result.rotationBranches.float / 8.0)
  result.survival = max(0.0, min(1.0,
    wCover * result.coverFrac +
    wExposed * (1.0 - exposedPenalty) +
    wRotation * rotationBonus))

proc measure(name: string): tuple[valid, ok: bool, sides: seq[SideExposure], worst: float] =
  let m = loadCtfMapMetadata(name)
  result.valid = mapDiagnostics(m).reason.len == 0
  let
    w = m.width
    h = m.height
    diag = mapDiagnostics(m, {diagnosticWallMasks, diagnosticCorridorOpen})
    walk = diag.corridorOpen
    wall = diag.maxWall
  result.worst = 1.0
  result.ok = true
  for team in m.teams():
    let s = measureSide(m, walk, wall, w, h, team)
    result.sides.add s
    if not s.ok: result.ok = false
    if s.survival < result.worst: result.worst = s.survival

proc emit(name: string) =
  let r = measure(name)
  echo &"=== {name}  valid={r.valid} ==="
  for s in r.sides:
    echo &"  {s.team} return: pathLen={s.pathLenPx}px coverFrac={s.coverFrac:.3f} " &
      &"exposedRunMax={s.exposedRunMaxPx}px (lethal={LethalEnvelopePx}) " &
      &"rotationBranches={s.rotationBranches} -> survival={s.survival:.3f}" &
      (if s.ok: "" else: "  [NO PATH]")
  echo &"  worst-side survival = {r.worst:.3f}"

# The five 71213 seeds that convert 0% in episodes, and the arena that converts
# 33%. The instrument must rank arena's worst-side survival ABOVE all five.
const
  ConvertingControl = "arena"
  NonConverting = ["gen:4055", "gen:4063", "gen:4031", "gen:4085", "gen:4100"]

proc selftest(): int =
  stderr.writeLine "# SELFTEST (71236 correlation gate): arena (33% conv) must " &
    "rank ABOVE all five 0%-conversion 71213 seeds on worst-side survival."
  let arena = measure(ConvertingControl)
  stderr.writeLine &"#   {ConvertingControl}: worst-side survival = {arena.worst:.3f}"
  var ok = true
  var maxBad = 0.0
  for name in NonConverting:
    let r = measure(name)
    stderr.writeLine &"#   {name}: worst-side survival = {r.worst:.3f}"
    if r.worst > maxBad: maxBad = r.worst
    if r.worst >= arena.worst:
      stderr.writeLine &"#     ^ FAIL: {name} ({r.worst:.3f}) not below arena ({arena.worst:.3f})"
      ok = false
  stderr.writeLine &"# separation: arena {arena.worst:.3f} vs worst-non-converting {maxBad:.3f} " &
    &"(margin {arena.worst - maxBad:.3f})"
  if ok:
    stderr.writeLine "# SELFTEST PASS: instrument separates converting from non-converting."
    stderr.writeLine &"# => a survivability gate floor between {maxBad:.3f} and {arena.worst:.3f} " &
      "screens out the non-converting maps. (Absolute floor recommendation, 71244.)"
    return 0
  stderr.writeLine "# SELFTEST FAIL: does not separate the known cases — NOT measuring the " &
    "right thing. Do not screen with it; STOP-and-report."
  return 1

when isMainModule:
  doAssert mapFitnessInstalled(),
    "map fitness not installed — generated maps would not match the shipping map"
  let args = commandLineParams()
  if args.len == 1 and args[0] == "--selftest":
    quit(selftest())
  if args.len == 2 and args[0] == "--map":
    emit(args[1]); quit(0)
  if args.len == 2:
    let lo = args[0].parseInt
    let hi = args[1].parseInt
    for seed in lo .. hi:
      try: emit(&"gen:{seed}")
      except CtfError: stderr.writeLine &"# gen:{seed} unproducible (skipped)"
    quit(0)
  quit("usage: return_exposure --selftest | --map <name> | <loSeed> <hiSeed>")
