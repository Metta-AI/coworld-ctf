import std/[json, math, random, strformat, algorithm, sequtils]
import ctf/[arena, br_map_pool, sim_types]
import shell/[body_map, body_nav]
proc evenRound(v: float): int =
  let lower = floor(v).int; let f = v - lower.float
  lower + ord(f > 0.5 or (f == 0.5 and (lower and 1) != 0))
proc perimeter(r: int): seq[BodyPoint] =
  let d = 2*r+1; var inc = newSeq[bool](d*d)
  template add(px, py: int) =
    let i = (py+r)*d + px + r
    if not inc[i]: inc[i] = true; result.add((px, py))
  for x in -r..r:
    let y = evenRound(sqrt(max(0, r*r-x*x).float)); add(x, y); add(x, -y)
  for y in -r..r:
    let x = evenRound(sqrt(max(0, r*r-y*y).float)); add(x, y); add(-x, y)
iterator rayCells(t: BodyPoint): tuple[p: BodyPoint, side: bool] =
  let nx = abs(t.x); let ny = abs(t.y); let sx = cmp(t.x, 0); let sy = cmp(t.y, 0)
  var x, y, ix, iy: int; var dec = ny - nx
  while ix < nx or iy < ny:
    if dec == 0:
      yield ((x+sx, y), true); yield ((x, y+sy), true)
      x += sx; y += sy; inc ix; inc iy; dec += 2*ny - 2*nx
    elif dec < 0: x += sx; inc ix; dec += 2*ny
    else: y += sy; inc iy; dec -= 2*nx
    yield ((x, y), false)
proc shape(label: string, gm: CtfMap, gunRange: int) =
  let map = newBodyMap(gm)
  var points: seq[BodyPoint]
  for y in countup(0, map.height-1, 32):
    for x in countup(0, map.width-1, 32):
      if map.canStand((x, y)): points.add((x, y))
  var rng = initRand(401)
  var input = DangerInput(selfXy: points[rng.rand(points.high)])
  for i in 0 ..< 16: input.candidates.add DangerCandidate(seatIndex: i, pos: points[rng.rand(points.high)])
  let nav = newBodyNavSystem(map, 1, gunRange, prepareRouteQueries = false)
  nav.seats[0].rebuildDanger(map, input, 0)
  let sources = nav.seats[0].selectedDangerSources()
  let r = max(1, (gunRange + NavCell - 1) div NavCell)
  let cutoffCells2 = (min(1050, gunRange).float / NavCell.float) ^ 2  # kernel zero beyond
  let per = perimeter(r)
  let W = map.gridWidth; let H = map.gridHeight
  proc blocked(x, y: int): bool = x < 0 or x >= W or y < 0 or y >= H or map.isWall(cellCenter((x, y)))
  var execSteps, execBeyondCutoff, addedUnique, nominalSteps = 0
  var waveScanned, waveWithActive, shellsScanned, shellsTotal = 0
  for src in sources:
    let o = map.cellOf(src.pos)
    # exact rays with early termination
    var visited = newSeq[bool](W*H)
    var dead = newSeq[bool](per.len)
    var deathShell = newSeq[int](per.len)
    for i in 0 ..< per.len: deathShell[i] = high(int)
    for ri, t in per:
      var pendingSide: seq[BodyPoint]
      for (p, side) in rayCells(t):
        inc nominalSteps
        let ax = o.x + p.x; let ay = o.y + p.y
        if side:
          pendingSide.add p
          if pendingSide.len == 2:
            inc execSteps
            if blocked(o.x+pendingSide[0].x, o.y+pendingSide[0].y) or blocked(o.x+pendingSide[1].x, o.y+pendingSide[1].y):
              dead[ri] = true; deathShell[ri] = abs(p.x)+abs(p.y); break
            for q in pendingSide:
              let idx = (o.y+q.y)*W + o.x+q.x
              if not visited[idx]: visited[idx] = true; inc addedUnique
            if float(p.x*p.x + p.y*p.y) > cutoffCells2: inc execBeyondCutoff
            pendingSide.setLen(0)
          continue
        inc execSteps
        if float(p.x*p.x + p.y*p.y) > cutoffCells2: inc execBeyondCutoff
        if blocked(ax, ay): dead[ri] = true; deathShell[ri] = abs(p.x)+abs(p.y); break
        let idx = ay*W + ax
        if not visited[idx]: visited[idx] = true; inc addedUnique
    # wavefront scan shape: per shell, cells scanned until all rays dead; cells with an active member
    # membership per relative cell
    # simpler: recompute per shell using rays' event lists
    var cellMembers: seq[seq[int32]] = newSeq[seq[int32]]((2*r+1)*(2*r+1))
    var cellShell = newSeq[int]((2*r+1)*(2*r+1))
    for ri, t in per:
      for (p, side) in rayCells(t):
        let i = (p.y+r)*(2*r+1) + p.x + r
        cellMembers[i].add int32(ri); cellShell[i] = abs(p.x)+abs(p.y)
    var lastDeath = 0
    for ri in 0 ..< per.len:
      if dead[ri]: lastDeath = max(lastDeath, deathShell[ri])
    let allDead = dead.allIt(it)
    let stopShell = if allDead: lastDeath else: 2*r
    shellsTotal += 2*r; shellsScanned += stopShell
    for i in 0 ..< cellMembers.len:
      if cellMembers[i].len == 0 or cellShell[i] > stopShell: continue
      inc waveScanned
      var anyActive = false
      for ri in cellMembers[i]:
        if not dead[ri] or deathShell[ri] > cellShell[i]: anyActive = true; break
      if anyActive: inc waveWithActive
  # per-shell active-interval statistics in angular id order (rays alive after removals at shell D)
  var order = toSeq(0 ..< per.len)
  proc angleOrder(a, b: BodyPoint): int =
    let ah = ord(a.y < 0 or (a.y == 0 and a.x < 0)); let bh = ord(b.y < 0 or (b.y == 0 and b.x < 0))
    if ah != bh: return cmp(ah, bh)
    let cross = a.x.int64 * b.y.int64 - a.y.int64 * b.x.int64
    if cross != 0: return -cmp(cross, 0'i64)
    result = cmp(a.x, b.x)
    if result == 0: result = cmp(a.y, b.y)
  order.sort(proc(i, j: int): int = angleOrder(per[i], per[j]))
  var intervalsSum, shellsCounted, intervalsMax = 0
  block:
    for src in sources:
      discard src
  # recompute per source deaths (cheap): reuse last source's dead arrays is wrong, so recompute all sources
  for src in sources:
    let o = map.cellOf(src.pos)
    var deathShell2 = newSeq[int](per.len)
    for i in 0 ..< per.len: deathShell2[i] = high(int)
    for ri, t in per:
      var pending: seq[BodyPoint]
      for (p, side) in rayCells(t):
        if side:
          pending.add p
          if pending.len == 2:
            if blocked(o.x+pending[0].x, o.y+pending[0].y) or blocked(o.x+pending[1].x, o.y+pending[1].y):
              deathShell2[ri] = abs(p.x)+abs(p.y); break
            pending.setLen(0)
          continue
        if blocked(o.x+p.x, o.y+p.y): deathShell2[ri] = abs(p.x)+abs(p.y); break
    var lastDeath2 = 0
    var allDead2 = true
    for ri in 0 ..< per.len:
      if deathShell2[ri] == high(int): allDead2 = false
      else: lastDeath2 = max(lastDeath2, deathShell2[ri])
    let stop2 = if allDead2: lastDeath2 else: 2*r
    for D in 1 .. stop2:
      var runs = 0; var prevAlive = false
      for k in order:
        let alive = deathShell2[k] > D
        if alive and not prevAlive: inc runs
        prevAlive = alive
      intervalsSum += runs; inc shellsCounted; intervalsMax = max(intervalsMax, runs)
  echo &"{label} range {gunRange}: active_intervals_per_shell mean {intervalsSum.float / max(1, shellsCounted).float:.1f} max {intervalsMax} shells_counted {shellsCounted}"
  echo &"{label} range {gunRange}: sources {sources.len} nominal_steps {nominalSteps} executed_steps {execSteps} beyond_cutoff {execBeyondCutoff} unique_added {addedUnique} wave_cells_scanned {waveScanned} wave_cells_with_active {waveWithActive} shells_scanned {shellsScanned}/{shellsTotal}"
let pool = loadBrS2PoolRaw()
let configured = parseJson(readFile(BrS2SoloMapPoolPath))
for gunRange in [331, 1300]:
  for index in [0, 29, 48]: shape("pool:" & $index, mapFromSpecJson($pool[index]["spec"]), gunRange)
  for index in [0, 5, 10]: shape("configured:" & $index, mapFromSpecJson($configured[index]), gunRange)
  shape("colossal", generateCtfMap(4242, MapGenOverrides(size: "colossal", windows: -1, pits: -1, pitDensity: -1), 4), gunRange)
