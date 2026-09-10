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
  # ---- pre-build count gate: per-source operation model of interval-narrowed enumeration
  var order = toSeq(0 ..< per.len)
  proc angleOrder(a, b: BodyPoint): int =
    let ah = ord(a.y < 0 or (a.y == 0 and a.x < 0)); let bh = ord(b.y < 0 or (b.y == 0 and b.x < 0))
    if ah != bh: return cmp(ah, bh)
    let cross = a.x.int64 * b.y.int64 - a.y.int64 * b.x.int64
    if cross != 0: return -cmp(cross, 0'i64)
    result = cmp(a.x, b.x)
    if result == 0: result = cmp(a.y, b.y)
  order.sort(proc(i, j: int): int = angleOrder(per[i], per[j]))
  var rank = newSeq[int](per.len)
  for k, ri in order: rank[ri] = k
  let D = 2*r+1
  # memberships per relative cell as sorted rank lists, then contiguous rank ranges
  var members = newSeq[seq[int]](D*D)
  var cellShellOf = newSeq[int](D*D)
  for ri, t in per:
    for (p, side) in rayCells(t):
      let i = (p.y+r)*D + p.x + r
      members[i].add rank[ri]; cellShellOf[i] = abs(p.x)+abs(p.y)
  type Entry = object
    cell, first, last: int
  var shellEntries = newSeq[seq[Entry]](2*r+1)   # per shell: one entry per (cell, range)
  var cellsWithMultiRange = 0
  for i in 0 ..< D*D:
    if members[i].len == 0: continue
    var ks = members[i]; ks.sort()
    var runs: seq[(int, int)]
    var a = ks[0]; var b = ks[0]
    for k in ks[1..^1]:
      if k == b + 1: b = k
      else: runs.add((a, b)); a = k; b = k
    runs.add((a, b))
    if runs.len > 1: inc cellsWithMultiRange
    for (f, l) in runs: shellEntries[cellShellOf[i]].add Entry(cell: i, first: f, last: l)
  var shellMaxLen = newSeq[int](2*r+1)
  for sh in 1 .. 2*r:
    shellEntries[sh].sort(proc(x, y: Entry): int = cmp(x.first, y.first))
    for e in shellEntries[sh]: shellMaxLen[sh] = max(shellMaxLen[sh], e.last - e.first + 1)
  # per source: simulate the enumeration and count operations
  var srcIndex = 0
  for src in sources:
    inc srcIndex
    let o = map.cellOf(src.pos)
    # ray deaths (exact visitor semantics) -> deathShell per ray
    var deathShell = newSeq[int](per.len)
    for i in 0 ..< per.len: deathShell[i] = high(int)
    var execSrc = 0
    for ri, t in per:
      var pending: seq[BodyPoint]
      for (p, side) in rayCells(t):
        if side:
          pending.add p
          if pending.len == 2:
            inc execSrc
            if blocked(o.x+pending[0].x, o.y+pending[0].y) or blocked(o.x+pending[1].x, o.y+pending[1].y):
              deathShell[ri] = abs(p.x)+abs(p.y); break
            pending.setLen(0)
          continue
        inc execSrc
        if blocked(o.x+p.x, o.y+p.y): deathShell[ri] = abs(p.x)+abs(p.y); break
    # model: active intervals over ranks; per shell: removal pass then add pass, each enumerating cells per interval
    var alive = newSeq[bool](per.len)      # by rank
    for ri in 0 ..< per.len: alive[rank[ri]] = true
    var binarySearches, scanned, overlapTouched, dupTouched, adds, blockedHits, intervalOps = 0
    var stamp = newSeq[int](D*D)
    var stampGen = 0
    for sh in 1 .. 2*r:
      # intervals from alive
      var intervals: seq[(int, int)]
      var k = 0
      while k < per.len:
        if alive[k]:
          var e = k
          while e + 1 < per.len and alive[e+1]: inc e
          intervals.add((k, e)); k = e + 1
        else: inc k
      if intervals.len == 0: break
      intervalOps += intervals.len
      let entries = shellEntries[sh]
      if entries.len == 0: continue
      # pass 1 (removal) and pass 2 (add) both enumerate: for each interval, binary search then scan
      for pass in 0 .. 1:
        inc stampGen
        for (a, b) in intervals:
          inc binarySearches
          # first entry with first >= a - (maxLen-1)
          var lo = 0; var hi = entries.len
          let key = a - (shellMaxLen[sh] - 1)
          while lo < hi:
            let mid = (lo + hi) div 2
            if entries[mid].first < key: lo = mid + 1 else: hi = mid
          var idx = lo
          while idx < entries.len and entries[idx].first <= b:
            inc scanned
            let e = entries[idx]
            if e.last >= a:
              inc overlapTouched
              if stamp[e.cell] == stampGen: inc dupTouched
              else:
                stamp[e.cell] = stampGen
                let cx = e.cell mod D - r; let cy = e.cell div D - r
                let ax = o.x + cx; let ay = o.y + cy
                if pass == 0:
                  if blocked(ax, ay):
                    inc blockedHits
                    for m in members[e.cell]: alive[m] = false
                else:
                  # active member check (some member still alive)
                  var any = false
                  for m in members[e.cell]:
                    if alive[m]: any = true; break
                  if any: inc adds
            inc idx
        if pass == 0:
          # recompute intervals after removals for the add pass
          intervals.setLen(0)
          var k2 = 0
          while k2 < per.len:
            if alive[k2]:
              var e = k2
              while e + 1 < per.len and alive[e+1]: inc e
              intervals.add((k2, e)); k2 = e + 1
            else: inc k2
          intervalOps += intervals.len
    let modelEvents = scanned + binarySearches * 8 + intervalOps + adds
    echo &"{label} range {gunRange} source {srcIndex}: executed_steps {execSrc} model_scanned {scanned} overlap {overlapTouched} dup {dupTouched} adds {adds} blocked_hits {blockedHits} bsearch {binarySearches} interval_ops {intervalOps} model_events {modelEvents} ratio_model_over_steps {modelEvents.float / max(1, execSrc).float:.2f} multi_range_cells {cellsWithMultiRange}"
  echo &"{label} range {gunRange}: sources {sources.len} nominal_steps {nominalSteps} executed_steps {execSteps} beyond_cutoff {execBeyondCutoff} unique_added {addedUnique} wave_cells_scanned {waveScanned} wave_cells_with_active {waveWithActive} shells_scanned {shellsScanned}/{shellsTotal}"
let pool = loadBrS2PoolRaw()
let configured = parseJson(readFile(BrS2SoloMapPoolPath))
for gunRange in [331, 1300]:
  for index in [0, 29, 48]: shape("pool:" & $index, mapFromSpecJson($pool[index]["spec"]), gunRange)
  for index in [0, 5, 10]: shape("configured:" & $index, mapFromSpecJson($configured[index]), gunRange)
  shape("colossal", generateCtfMap(4242, MapGenOverrides(size: "colossal", windows: -1, pits: -1, pitDensity: -1), 4), gunRange)
