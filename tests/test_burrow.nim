## Tests for the burrow connectivity tool (src/ctf/burrow.nim).
##
## Two patterns are copied straight from mettagrid's own suite:
##   - determinism: two independent runs on the same input are byte-identical
##   - connectivity: throw a grid of walled rooms at it, assert one component
## The rest pin the five changes the port had to make for this engine — brush
## width, the destruction audit, the fundamental-domain mask, the explicit
## passable set, and a failure RESULT instead of a crash — plus real timings
## on a standard and a giant board.

import
  std/[monotimes, strutils, times, unittest],
  ctf/burrow,
  ctf/sim

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc fingerprint(grid: BurrowGrid): uint64 =
  ## FNV-1a over the cell array plus the dimensions: the "byte-identical"
  ## comparison the determinism test needs, without materializing a string.
  result = 0xcbf29ce484222325'u64
  for v in [grid.w, grid.h, grid.cellSize, grid.domain.len]:
    result = (result xor uint64(v)) * 0x100000001b3'u64
  for cell in grid.cells:
    result = (result xor uint64(ord(cell))) * 0x100000001b3'u64
  for flag in grid.domain:
    result = (result xor uint64(ord(flag))) * 0x100000001b3'u64

proc fingerprint(report: BurrowReport): uint64 =
  result = 0xcbf29ce484222325'u64
  for v in [ord(report.status), report.componentsBefore,
      report.componentsAfter, report.anchorCells, report.tunnels,
      report.wallCellsDug, report.totalCost, report.objectsDestroyed.len,
      report.paths.len, report.dugCells.len]:
    result = (result xor uint64(v)) * 0x100000001b3'u64
  for p in report.objectsDestroyed:
    result = (result xor uint64(p.x * 65536 + p.y)) * 0x100000001b3'u64
  for path in report.paths:
    for p in path:
      result = (result xor uint64(p.x * 65536 + p.y)) * 0x100000001b3'u64

proc fill(grid: var BurrowGrid, x0, y0, x1, y1: int, cell: BurrowCell) =
  for y in max(0, y0) .. min(grid.h - 1, y1):
    for x in max(0, x0) .. min(grid.w - 1, x1):
      grid[x, y] = cell

proc roomGrid(rows, columns, roomW, roomH: int, wall = 1): BurrowGrid =
  ## mettagrid's `RoomGrid` shape: sealed rooms in a lattice, separated by
  ## solid wall bands, with a wall border all the way around. Every room is
  ## its own component, so `rows * columns` components go in.
  let
    w = columns * roomW + (columns + 1) * wall
    h = rows * roomH + (rows + 1) * wall
  result = initBurrowGrid(w, h, 8, bcWall)
  for r in 0 ..< rows:
    for c in 0 ..< columns:
      let
        x0 = wall + c * (roomW + wall)
        y0 = wall + r * (roomH + wall)
      result.fill(x0, y0, x0 + roomW - 1, y0 + roomH - 1, bcFloor)

proc componentCount(grid: BurrowGrid): int =
  labelComponents(grid).count

proc clearance(grid: BurrowGrid, p: BurrowPoint, r: int): bool =
  ## Independent re-derivation of the brush guarantee: every cell of the L2
  ## disc of radius r around p is passable (or clipped away by the board edge
  ## / the fundamental domain, which the burrow is not allowed to widen).
  for dy in -r .. r:
    for dx in -r .. r:
      if dx * dx + dy * dy > r * r: continue
      let
        x = p.x + dx
        y = p.y + dy
      if not grid.onGrid(x, y): continue
      if not grid.inDomain(grid.idx(x, y)): continue
      if not grid[x, y].isPassable:
        return false
  true

proc ringedPocket(gapIsWall: bool): BurrowGrid =
  ## A big room on the left, and a pocket on the right sealed behind a ring of
  ## OBJECTS. Everything between them is rock. `gapIsWall` swaps the ring cell
  ## facing the room for plain rock, which the cost model must prefer 5:1.
  result = initBurrowGrid(21, 11, 8, bcWall)
  result.fill(1, 1, 8, 9, bcFloor)      ## the main room
  result.fill(11, 3, 15, 7, bcObject)   ## the ring
  result.fill(12, 4, 14, 6, bcFloor)    ## the pocket inside it
  if gapIsWall:
    result[11, 5] = bcWall

# ---------------------------------------------------------------------------

suite "burrow: connectivity":
  test "a grid of walled rooms comes out as one component":
    ## mettagrid's own test, `test_connect_room_grid`.
    for brush in [0, 1, 2]:
      var grid = roomGrid(rows = 2, columns = 3, roomW = 5, roomH = 5)
      check grid.componentCount == 6
      let report = grid.burrow(defaultBurrowParams(brush))
      check report.ok
      check report.status == bsConnected
      check report.componentsBefore == 6
      check report.componentsAfter == 1
      check report.tunnels == 5
      check grid.componentCount == 1

  test "a bigger lattice, and every room really is reachable from every room":
    var grid = roomGrid(rows = 4, columns = 5, roomW = 7, roomH = 6, wall = 2)
    check grid.componentCount == 20
    let report = grid.burrow(defaultBurrowParams(1))
    check report.ok
    check grid.componentCount == 1
    ## Flood from one room and demand it covers every passable cell.
    var start = BurrowPoint(x: -1, y: -1)
    block find:
      for y in 0 ..< grid.h:
        for x in 0 ..< grid.w:
          if grid[x, y].isPassable:
            start = BurrowPoint(x: x, y: y)
            break find
    let reached = grid.reachableFrom(start)
    var missed = 0
    for i in 0 ..< grid.cells.len:
      if grid.cells[i].isPassable and not reached[i]: inc missed
    check missed == 0

  test "an already-connected map is left untouched":
    var grid = initBurrowGrid(20, 20, 8, bcFloor)
    let before = grid.fingerprint
    let report = grid.burrow(defaultBurrowParams(2))
    check report.ok
    check report.componentsBefore == 1
    check report.tunnels == 0
    check report.wallCellsDug == 0
    check grid.fingerprint == before

  test "the cheapest crossing is the thinnest barrier":
    ## Two rooms separated by one wall band that is 1 cell thick at y = 5 and
    ## 5 cells thick everywhere else. The argmin must pick the thin section.
    var grid = initBurrowGrid(21, 11, 8, bcWall)
    grid.fill(1, 1, 7, 9, bcFloor)
    grid.fill(13, 1, 19, 9, bcFloor)
    grid.fill(12, 5, 12, 5, bcFloor)   ## thin section: only x = 8..11 is rock
    check grid.componentCount == 2
    var params = defaultBurrowParams(0)
    params.artifacts = {baPaths, baDugCells}
    let report = grid.burrow(params)
    check report.ok
    ## Four wall cells is the thin crossing; the thick one would be five.
    check report.wallCellsDug == 4
    for p in report.dugCells:
      check p.y == 5

suite "burrow: determinism":
  test "two independent runs are byte-identical":
    ## No RNG anywhere in the module, so this is a hard equality, not a
    ## statistical one.
    for brush in [0, 2]:
      var
        a = roomGrid(rows = 3, columns = 4, roomW = 6, roomH = 5, wall = 3)
        b = roomGrid(rows = 3, columns = 4, roomW = 6, roomH = 5, wall = 3)
      var params = defaultBurrowParams(brush)
      params.artifacts = {baPaths, baDugCells}
      let
        ra = a.burrow(params)
        rb = b.burrow(params)
      check a.fingerprint == b.fingerprint
      check ra.fingerprint == rb.fingerprint
      check ra.dugCells == rb.dugCells
      check ra.paths == rb.paths
      check ra.summary == rb.summary

  test "determinism survives a wedge mask and pinned anchors":
    proc build(): BurrowGrid =
      result = roomGrid(rows = 3, columns = 3, roomW = 6, roomH = 6, wall = 2)
      result.domain = newSeq[bool](result.w * result.h)
      for y in 0 ..< result.h:
        for x in 0 ..< result.w:
          result.domain[y * result.w + x] = x < result.w div 2
    var
      a = build()
      b = build()
    var params = defaultBurrowParams(1)
    params.anchors = @[BurrowPoint(x: 3, y: 3)]
    params.artifacts = {baPaths, baDugCells}
    let
      ra = a.burrow(params)
      rb = b.burrow(params)
    check ra.status == rb.status
    check a.fingerprint == b.fingerprint
    check ra.fingerprint == rb.fingerprint

  test "the junction pass is deterministic too (no RNG tie-break)":
    ## The reference picks uniformly among equally-distant candidates. Ours
    ## takes the lowest (y, x), so repeated runs agree.
    proc build(): BurrowGrid =
      result = initBurrowGrid(31, 31, 8, bcFloor)
    var
      a = build()
      b = build()
    let
      ra = a.ensureHubJunctions(@[BurrowPoint(x: 15, y: 15)])
      rb = b.ensureHubJunctions(@[BurrowPoint(x: 15, y: 15)])
    check ra.ok and rb.ok
    check ra.placed == rb.placed
    check a.fingerprint == b.fingerprint

suite "burrow: brush radius (change 1)":
  test "brush 0 reproduces the reference's width-1 tunnel":
    var grid = initBurrowGrid(15, 9, 8, bcWall)
    grid.fill(1, 1, 5, 7, bcFloor)
    grid.fill(9, 1, 13, 7, bcFloor)
    var params = defaultBurrowParams(0)
    params.artifacts = {baDugCells}
    let report = grid.burrow(params)
    check report.ok
    ## Three rock cells (x = 6, 7, 8) on one row and nothing else.
    check report.wallCellsDug == 3
    check report.dugCells.len == 3
    var rows: seq[int]
    for p in report.dugCells:
      if p.y notin rows: rows.add p.y
    check rows.len == 1

  test "the dug corridor is never narrower than the brush":
    for brush in [1, 2, 3]:
      var grid = roomGrid(rows = 2, columns = 3, roomW = 9, roomH = 9,
        wall = 2 * brush + 3)
      var params = defaultBurrowParams(brush)
      params.artifacts = {baPaths}
      let report = grid.burrow(params)
      check report.ok
      check report.paths.len == report.tunnels
      var narrow = 0
      for path in report.paths:
        for p in path:
          if not grid.clearance(p, brush): inc narrow
      check narrow == 0

  test "a wider brush digs strictly more, and the width scales with it":
    var dug: seq[int]
    for brush in [0, 1, 2, 3]:
      var grid = roomGrid(rows = 2, columns = 2, roomW = 9, roomH = 9,
        wall = 9)
      let report = grid.burrow(defaultBurrowParams(brush))
      check report.ok
      dug.add report.wallCellsDug
    for i in 1 ..< dug.len:
      check dug[i] > dug[i - 1]

  test "brushRadiusForCorridor sizes the disc against a pixel width":
    ## The stamped disc unions to a band 2r+1 cells across.
    for widthPx in [8, 16, 26, 34, 68, 96]:
      for cellSize in [4, 8, 16]:
        let r = brushRadiusForCorridor(widthPx, cellSize)
        check (2 * r + 1) * cellSize >= widthPx
        if r > 0:
          check (2 * (r - 1) + 1) * cellSize < widthPx
    check brushRadiusForCorridor(0, 8) == 0

suite "burrow: destruction audit (change 2)":
  test "a pocket sealed behind a ring of objects loses exactly one":
    var grid = ringedPocket(gapIsWall = false)
    var params = defaultBurrowParams(0)
    params.artifacts = {baDugCells}
    let report = grid.burrow(params)
    check report.ok
    check report.objectsDestroyed.len == 1
    check "DESTROYED 1 objects" in report.summary

  test "the audit matches the grid diff exactly, for every brush":
    for brush in [0, 1, 2]:
      var grid = ringedPocket(gapIsWall = false)
      let before = grid.cells
      let report = grid.burrow(defaultBurrowParams(brush))
      check report.ok
      ## Every object that disappeared is in the audit...
      var expected: seq[BurrowPoint]
      for i in 0 ..< before.len:
        if before[i] == bcObject and grid.cells[i] != bcObject:
          expected.add BurrowPoint(x: i mod grid.w, y: i div grid.w)
      check expected.len > 0
      check report.objectsDestroyed.len == expected.len
      for p in expected:
        check p in report.objectsDestroyed
      ## ...and the audit never claims one that survived.
      for p in report.objectsDestroyed:
        check before[grid.idx(p.x, p.y)] == bcObject
        check grid[p.x, p.y] == bcFloor
      ## Content is never bulldozed; walls are the only other thing touched.
      for i in 0 ..< before.len:
        if before[i] == bcContent:
          check grid.cells[i] == bcContent
        if before[i] == bcFloor:
          check grid.cells[i] == bcFloor

  test "one rock cell in the ring saves the objects — 50 beats 10":
    var grid = ringedPocket(gapIsWall = true)
    let report = grid.burrow(defaultBurrowParams(0))
    check report.ok
    check report.objectsDestroyed.len == 0
    check "DESTROYED" notin report.summary
    check report.summary.startsWith("burrow ok")

  test "a brush that clips content-free rock still audits its collateral":
    ## With a brush the tunnel is wider than its centerline, so objects the
    ## centerline misses get flattened anyway. That is the silent-destruction
    ## hole the audit exists to close: the count must grow, and every one of
    ## them must be named.
    var
      narrowGrid = ringedPocket(gapIsWall = true)
      wideGrid = ringedPocket(gapIsWall = true)
    let
      narrowReport = narrowGrid.burrow(defaultBurrowParams(0))
      wideReport = wideGrid.burrow(defaultBurrowParams(1))
    check narrowReport.ok and wideReport.ok
    check narrowReport.objectsDestroyed.len == 0
    check wideReport.objectsDestroyed.len > 0
    for p in wideReport.objectsDestroyed:
      check $p in wideReport.summary

suite "burrow: fundamental domain (change 3)":
  test "a wedge-masked run never writes outside the wedge":
    var grid = roomGrid(rows = 3, columns = 4, roomW = 6, roomH = 6, wall = 2)
    let wedgeX = grid.w div 2
    grid.domain = newSeq[bool](grid.w * grid.h)
    for y in 0 ..< grid.h:
      for x in 0 ..< grid.w:
        grid.domain[y * grid.w + x] = x < wedgeX
    let before = grid.cells
    var params = defaultBurrowParams(2)
    params.artifacts = {baDugCells, baPaths}
    let report = grid.burrow(params)
    check report.ok
    ## Not one cell outside the wedge changed.
    var outsideChanged = 0
    for y in 0 ..< grid.h:
      for x in 0 ..< grid.w:
        let i = y * grid.w + x
        if x >= wedgeX and grid.cells[i] != before[i]: inc outsideChanged
    check outsideChanged == 0
    ## ...and the report agrees.
    for p in report.dugCells:
      check p.x < wedgeX
    for path in report.paths:
      for p in path:
        check p.x < wedgeX
    for p in report.objectsDestroyed:
      check p.x < wedgeX

  test "the wedge is judged on its own components, not the whole board":
    ## Two rooms in the wedge and one outside it: the wedge run must see two
    ## components and dig one tunnel, ignoring the third room entirely.
    var grid = initBurrowGrid(30, 11, 8, bcWall)
    grid.fill(1, 1, 5, 9, bcFloor)
    grid.fill(8, 1, 12, 9, bcFloor)
    grid.fill(20, 1, 28, 9, bcFloor)
    grid.domain = newSeq[bool](grid.w * grid.h)
    for y in 0 ..< grid.h:
      for x in 0 ..< grid.w:
        grid.domain[y * grid.w + x] = x < 15
    let report = grid.burrow(defaultBurrowParams(1))
    check report.componentsBefore == 2
    check report.tunnels == 1
    check report.ok

  test "a pinned anchor overrides 'the largest component'":
    ## Plan §2.2: the connectivity anchor is the G-invariant hub, not
    ## whichever blob happens to be biggest.
    var grid = initBurrowGrid(31, 11, 8, bcWall)
    grid.fill(1, 1, 5, 5, bcFloor)     ## small: 25 cells
    grid.fill(20, 1, 29, 9, bcFloor)   ## large: 90 cells
    let unpinned = block:
      var g = grid
      g.burrow(defaultBurrowParams(0))
    check unpinned.anchorCells == 90
    var params = defaultBurrowParams(0)
    params.anchors = @[BurrowPoint(x: 3, y: 3)]
    let pinned = grid.burrow(params)
    check pinned.ok
    check pinned.anchorCells == 25

  test "anchors in two components never fake connectivity between them":
    var grid = initBurrowGrid(31, 11, 8, bcWall)
    grid.fill(1, 1, 5, 9, bcFloor)
    grid.fill(20, 1, 29, 9, bcFloor)
    var params = defaultBurrowParams(0)
    params.anchors = @[BurrowPoint(x: 3, y: 3), BurrowPoint(x: 25, y: 5)]
    let report = grid.burrow(params)
    check report.ok
    check report.tunnels == 1
    check grid.componentCount == 1

  test "an anchor on rock is a failure result, not a silent fallback":
    var grid = roomGrid(rows = 2, columns = 2, roomW = 5, roomH = 5)
    var params = defaultBurrowParams(0)
    params.anchors = @[BurrowPoint(x: 0, y: 0)]  ## the wall border
    let report = grid.burrow(params)
    check not report.ok
    check report.status == bsAnchorNotPassable
    check grid.componentCount == 4  ## nothing was dug

suite "burrow: the passable set (change 4)":
  test "a region whose only floor is content is a real component":
    ## The reference labeller only saw literal "empty", so this region was
    ## invisible to it and the map shipped disconnected.
    var grid = initBurrowGrid(21, 11, 8, bcWall)
    grid.fill(1, 1, 7, 9, bcFloor)
    grid.fill(13, 3, 17, 7, bcContent)   ## floor with a med kit on every cell
    check grid.componentCount == 2
    let report = grid.burrow(defaultBurrowParams(0))
    check report.ok
    check report.tunnels == 1
    check grid.componentCount == 1

  test "walking over content is as cheap as walking over floor":
    ## A content strip must not be routed around like an obstacle.
    var grid = initBurrowGrid(21, 11, 8, bcWall)
    grid.fill(1, 1, 9, 9, bcFloor)
    grid.fill(5, 1, 5, 9, bcContent)     ## a content column through the room
    grid.fill(11, 1, 19, 9, bcFloor)
    let report = grid.burrow(defaultBurrowParams(0))
    check report.ok
    check report.objectsDestroyed.len == 0
    ## Every content cell survives.
    var content = 0
    for cell in grid.cells:
      if cell == bcContent: inc content
    check content == 9

  test "objects block movement — they are not floor":
    var grid = initBurrowGrid(11, 11, 8, bcWall)
    grid.fill(1, 1, 4, 9, bcFloor)
    grid.fill(5, 1, 5, 9, bcObject)
    grid.fill(6, 1, 9, 9, bcFloor)
    check grid.componentCount == 2

suite "burrow: failure results (change 5)":
  test "a severed domain returns a status, it does not raise":
    ## Two in-domain islands with no in-domain route between them: the
    ## reference's bare assert would crash the generator here.
    var grid = initBurrowGrid(31, 11, 8, bcFloor)
    grid.domain = newSeq[bool](grid.w * grid.h)
    for y in 0 ..< grid.h:
      for x in 0 ..< grid.w:
        grid.domain[y * grid.w + x] = x < 10 or x > 20
    let report = grid.burrow(defaultBurrowParams(0))
    check not report.ok
    check report.status == bsUnreachable
    check report.summary.startsWith("burrow FAILED")

  test "a board with no floor at all reports bsEmpty":
    var grid = initBurrowGrid(12, 12, 8, bcWall)
    let report = grid.burrow(defaultBurrowParams(1))
    check not report.ok
    check report.status == bsEmpty

  test "ok() is the single accept test the reroll loop branches on":
    var grid = roomGrid(rows = 2, columns = 2, roomW = 5, roomH = 5)
    check grid.burrow(defaultBurrowParams(1)).ok
    var empty = initBurrowGrid(6, 6, 8, bcWall)
    check not empty.burrow(defaultBurrowParams(1)).ok

suite "burrow: EnsureHubReachableJunction":
  test "a junction lands inside the band and is reachable":
    var grid = initBurrowGrid(41, 41, 8, bcFloor)
    let
      hub = BurrowPoint(x: 20, y: 20)
      params = defaultJunctionParams()
      report = grid.ensureHubJunctions(@[hub], params = params)
    check report.ok
    check report.placed.len == 1
    let
      p = report.placed[0]
      d2 = (p.x - hub.x) * (p.x - hub.x) + (p.y - hub.y) * (p.y - hub.y)
    check d2 >= params.minDistance * params.minDistance
    check d2 <= params.maxDistance * params.maxDistance
    check grid[p.x, p.y] == bcContent
    check grid.reachableFrom(hub)[grid.idx(p.x, p.y)]

  test "min_distance keeps it off the hub wall":
    ## The whole point of the lower bound: a junction glued to the hub is a
    ## trivialized objective.
    var grid = initBurrowGrid(41, 41, 8, bcFloor)
    let hub = BurrowPoint(x: 20, y: 20)
    for minDist in [2, 4, 8, 12]:
      var g = grid
      let report = g.ensureHubJunctions(@[hub],
        params = JunctionParams(minDistance: minDist, maxDistance: 15))
      check report.ok
      let p = report.placed[0]
      check (p.x - hub.x) * (p.x - hub.x) + (p.y - hub.y) * (p.y - hub.y) >=
        minDist * minDist

  test "an existing junction in the band satisfies the hub":
    var grid = initBurrowGrid(41, 41, 8, bcFloor)
    let
      hub = BurrowPoint(x: 20, y: 20)
      existing = BurrowPoint(x: 26, y: 20)
    let report = grid.ensureHubJunctions(@[hub], @[existing])
    check report.ok
    check report.placed.len == 0
    check report.satisfied == @[hub]

  test "a junction outside the band does NOT satisfy the hub":
    var grid = initBurrowGrid(81, 41, 8, bcFloor)
    let report = grid.ensureHubJunctions(
      @[BurrowPoint(x: 20, y: 20)], @[BurrowPoint(x: 70, y: 20)])
    check report.ok
    check report.placed.len == 1

  test "an unreachable junction in the band does NOT satisfy the hub":
    ## Reachability is checked over the passable set, so a junction behind a
    ## wall is not a junction.
    var grid = initBurrowGrid(41, 41, 8, bcFloor)
    grid.fill(25, 0, 25, 40, bcWall)
    let report = grid.ensureHubJunctions(
      @[BurrowPoint(x: 20, y: 20)], @[BurrowPoint(x: 30, y: 20)])
    check report.ok
    check report.placed.len == 1
    check report.placed[0].x < 25

  test "impossible means jsNoSite, not a silent no-op":
    ## The reference returns quietly here and ships a map whose hub has no
    ## contestable objective.
    var grid = initBurrowGrid(41, 41, 8, bcWall)
    grid.fill(18, 18, 22, 22, bcFloor)   ## a hub pocket smaller than minDist
    let
      hub = BurrowPoint(x: 20, y: 20)
      report = grid.ensureHubJunctions(@[hub])
    check not report.ok
    check report.status == jsNoSite
    check report.unserved == @[hub]
    check "UNSERVED" in report.summary

  test "no hubs is a caller bug and says so":
    var grid = initBurrowGrid(10, 10, 8, bcFloor)
    let report = grid.ensureHubJunctions(@[])
    check not report.ok
    check report.status == jsNoHubs

  test "several hubs each get served, and share what is already placed":
    var grid = initBurrowGrid(61, 21, 8, bcFloor)
    let hubs = @[
      BurrowPoint(x: 10, y: 10),
      BurrowPoint(x: 30, y: 10),
      BurrowPoint(x: 50, y: 10),
    ]
    let report = grid.ensureHubJunctions(hubs)
    check report.ok
    check report.placed.len + report.satisfied.len == hubs.len

  test "the junction never leaves the fundamental domain":
    var grid = initBurrowGrid(41, 41, 8, bcFloor)
    grid.domain = newSeq[bool](grid.w * grid.h)
    for y in 0 ..< grid.h:
      for x in 0 ..< grid.w:
        grid.domain[y * grid.w + x] = x < 22
    let report = grid.ensureHubJunctions(@[BurrowPoint(x: 20, y: 20)])
    check report.ok
    check report.placed[0].x < 22

  test "junctionParamsPx converts a pixel band without exceeding it":
    let p = junctionParamsPx(cellSize = 8, minPx = 40, maxPx = 200)
    check p.minDistance == 5     ## 40 px rounds UP to 5 cells
    check p.maxDistance == 25    ## 200 px rounds DOWN to 25 cells
    check p.minDistance * 8 >= 40
    check p.maxDistance * 8 <= 200

# ---------------------------------------------------------------------------
# Real boards: rasterization + timings
# ---------------------------------------------------------------------------

proc gridForMap(gameMap: CtfMap, cellSize: int):
    tuple[grid: BurrowGrid, rasterMs, downsampleMs: float] =
  ## Continuous pixel space -> burrow cells, via the SAME wall masks the
  ## generator's validator already builds. `maxWall` (the swept union) is the
  ## pessimistic mask: a corridor that closes at any spin frame is not a
  ## corridor, so the burrow must not route through one.
  let
    obstacles = buildArenaObstacles(gameMap)
    t0 = getMonoTime()
    masks = rasterizeWallMasks(gameMap, obstacles)
    t1 = getMonoTime()
  ## Trenches are walkable dug shapes: floor carrying content, not obstacles.
  ## Since GV37 a trench is an ArenaShape (it may be a polygon), so test the
  ## shape itself rather than a bounding rect — a bbox would mark undug floor.
  var content = newSeq[bool](gameMap.width * gameMap.height)
  for trench in gameMap.trenches:
    let b = shapeBounds(trench)
    for y in max(0, b.y0) .. min(gameMap.height - 1, b.y1):
      for x in max(0, b.x0) .. min(gameMap.width - 1, b.x1):
        if inShape(x, y, trench):
          content[y * gameMap.width + x] = true
  let
    grid = burrowGridFromPixels(gameMap.width, gameMap.height, cellSize,
      masks.maxWall, content = content)
    t2 = getMonoTime()
  (grid,
    float((t1 - t0).inMicroseconds) / 1000.0,
    float((t2 - t1).inMicroseconds) / 1000.0)

proc erodeToFootprint(grid: var BurrowGrid, r: int) =
  ## The corridor-width erosion `collectMapDiagnostics` runs before its flood,
  ## applied at cell granularity: a cell survives only if the whole footprint
  ## disc fits. A shipped map is one component of raw floor, so THIS is what
  ## turns a real board into the field of pockets the burrow exists to
  ## reconnect — and it is also the state a mid-generation terrain stage is
  ## actually in when the burrow runs on it.
  let before = grid.cells
  for y in 0 ..< grid.h:
    for x in 0 ..< grid.w:
      if not before[y * grid.w + x].isPassable: continue
      var fits = true
      block scan:
        for dy in -r .. r:
          for dx in -r .. r:
            if dx * dx + dy * dy > r * r: continue
            let
              nx = x + dx
              ny = y + dy
            if not grid.onGrid(nx, ny) or
                not before[ny * grid.w + nx].isPassable:
              fits = false
              break scan
      if not fits: grid[x, y] = bcWall

proc erodeUntilFragmented(grid: var BurrowGrid, maxR = 6): int =
  ## Erode at escalating radii until the board is genuinely in pieces, and
  ## return the radius that did it (0 = never fragmented, which is a failure
  ## the caller must report rather than skip).
  ##
  ## This USED to be a bare `erodeToFootprint(1)` plus `check fragments > 1`,
  ## which is a test that goes red when the GENERATOR IMPROVES: the rebuilt
  ## generator's standard board survives an r=1 erosion as a single component,
  ## so the digging path stopped being exercised and the assertion started
  ## demanding a disconnected board as if connectivity were the defect. The
  ## thing worth testing is the BURROW — that it reconnects a fragmented board
  ## and digs exactly one tunnel per extra component — so the fragmentation is
  ## now manufactured to whatever depth this board needs instead of being
  ## borrowed from the board's shortcomings. It also survives the corridor
  ## floor moving from 26 to 68, which changes `brush` under this test.
  for r in 1 .. maxR:
    var probe = grid
    probe.erodeToFootprint(r)
    if probe.componentCount > 1:
      grid = probe
      return r
  0

suite "burrow: real boards":
  test "standard and giant boards, end to end, with timings":
    const
      CellSize = FovCellSize   ## 8 px — see burrow.nim's RESOLUTION note.
      MinCorridorPx = MinCorridorWidth
        ## arena's own corridor minimum, now that it is exported — this used to
        ## be a hand-copied 26 that could drift. `map_rules` argues for raising
        ## it to `RecommendedCorridorWidthPx` = 68 (two DRAWN cog bodies); the
        ## measured pool churn of doing so is in
        ## docs/plans/2026-08-05-map-size-class-rules.md.
    let brush = brushRadiusForCorridor(MinCorridorPx, CellSize)
    for sizeName in ["standard", "giant"]:
      let gameMap = generateCtfMap(4242, MapGenOverrides(
        size: sizeName, windows: -1, pits: -1, pitDensity: -1))
      let (baseGrid, rasterMs, downMs) = gridForMap(gameMap, CellSize)
      echo "  ", sizeName, " ", gameMap.width, "x", gameMap.height,
        " -> ", baseGrid.w, "x", baseGrid.h, " cells (",
        baseGrid.w * baseGrid.h, "), brush r=", brush,
        "\n    rasterizeWallMasks ", rasterMs.formatFloat(ffDecimal, 2), " ms",
        " | downsample ", downMs.formatFloat(ffDecimal, 2), " ms"

      ## (a) the board as generated — already one component, so this is the
      ## early-out cost the validator would pay on a map that needs no repair.
      block asGenerated:
        var grid = baseGrid
        let
          t0 = getMonoTime()
          report = grid.burrow(defaultBurrowParams(brush))
          ms = float((getMonoTime() - t0).inMicroseconds) / 1000.0
        echo "    as generated:  burrow ", ms.formatFloat(ffDecimal, 2),
          " ms | ", report.summary
        check report.ok
        check grid.componentCount == 1

      ## (b) eroded to the player footprint — a genuinely fragmented board, so
      ## Dial's and the digging both run for real.
      block eroded:
        var grid = baseGrid
        let erodeR = grid.erodeUntilFragmented()
        let fragments = grid.componentCount
        var params = defaultBurrowParams(brush)
        params.artifacts = {baPaths}
        let
          t0 = getMonoTime()
          report = grid.burrow(params)
          ms = float((getMonoTime() - t0).inMicroseconds) / 1000.0
        echo "    footprint-eroded r=", erodeR, " (", fragments,
          " components):  burrow ", ms.formatFloat(ffDecimal, 2), " ms | ",
          report.summary
        ## r=0 means no erosion up to the cap could break this board apart, so
        ## the digging path below never ran — a silent pass, not a good board.
        check erodeR > 0
        check fragments > 1
        check report.ok
        check report.tunnels == fragments - 1
        check grid.componentCount == 1
        ## The brush guarantee holds on a real board, not just a toy one.
        var narrow = 0
        for path in report.paths:
          for p in path:
            if not grid.clearance(p, brush): inc narrow
        check narrow == 0

      ## (c) the same eroded board inside a fundamental domain — the left
      ## half — which is how the generator will actually call this (plan §2.2:
      ## burrow the wedge, then lift by the symmetry orbit).
      block wedge:
        var grid = baseGrid
        grid.erodeToFootprint(1)
        let wedgeX = grid.w div 2
        grid.domain = newSeq[bool](grid.w * grid.h)
        for y in 0 ..< grid.h:
          for x in 0 ..< grid.w:
            grid.domain[y * grid.w + x] = x < wedgeX
        let snapshot = grid.cells
        var params = defaultBurrowParams(brush)
        params.artifacts = {baDugCells}
        let
          t0 = getMonoTime()
          report = grid.burrow(params)
          ms = float((getMonoTime() - t0).inMicroseconds) / 1000.0
        echo "    left-half wedge:  burrow ", ms.formatFloat(ffDecimal, 2),
          " ms | ", report.summary
        check report.ok
        var outsideChanged = 0
        for y in 0 ..< grid.h:
          for x in 0 ..< grid.w:
            let i = y * grid.w + x
            if x >= wedgeX and grid.cells[i] != snapshot[i]:
              inc outsideChanged
        check outsideChanged == 0
        for p in report.dugCells:
          check p.x < wedgeX

    ## A second, independent run of the whole pipeline must land on the same
    ## bytes — determinism through the rasterizer as well as the algorithm.
    let gameMap = generateCtfMap(4242, MapGenOverrides(
      size: "standard", windows: -1, pits: -1, pitDensity: -1))
    var
      a = gridForMap(gameMap, CellSize).grid
      b = gridForMap(gameMap, CellSize).grid
    ## Both halves must be eroded IDENTICALLY or the determinism claim below is
    ## about the erosion, not the burrow — so derive the radius once from `a`
    ## and apply the same one to `b`.
    let erodeR = a.erodeUntilFragmented()
    check erodeR > 0
    b.erodeToFootprint(erodeR)
    check a.fingerprint == b.fingerprint
    let
      ra = a.burrow(defaultBurrowParams(brush))
      rb = b.burrow(defaultBurrowParams(brush))
    check ra.ok
    check ra.tunnels > 0
    check a.fingerprint == b.fingerprint
    check ra.fingerprint == rb.fingerprint

  test "the rasterizer is conservative: a dug cell is open at pixel level":
    ## A cell is passable only when EVERY pixel in it is, so the burrow can
    ## never route through a gap the 13 px footprint cannot use.
    const CellSize = 8
    var wall = newSeq[bool](32 * 32)
    ## One wall pixel in the middle of cell (1, 1).
    wall[12 * 32 + 12] = true
    let grid = burrowGridFromPixels(32, 32, CellSize, wall)
    check grid.w == 4 and grid.h == 4
    check grid[1, 1] == bcWall
    check grid[0, 0] == bcFloor
    check grid[2, 2] == bcFloor

  test "the pixel domain mask is strict, so a wedge never leaks":
    const CellSize = 8
    var
      wall = newSeq[bool](32 * 32)
      domainPx = newSeq[bool](32 * 32)
    for y in 0 ..< 32:
      for x in 0 ..< 32:
        domainPx[y * 32 + x] = x < 20      ## cuts cell column 2 in half
    let grid = burrowGridFromPixels(32, 32, CellSize, wall,
      domainPx = domainPx)
    check grid.inDomain(1, 0)
    check not grid.inDomain(2, 0)   ## partially covered -> excluded
    check not grid.inDomain(3, 0)
