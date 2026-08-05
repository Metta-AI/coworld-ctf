## Derives the hexagonal arena's COVER BAND from lane geometry.
##
## The question this answers is not "what number makes the generator pass" but
## "how much wall does it take to interrupt every chord family on a hexagonal
## hull of this size class". Everything it prints is a measurement over the
## real hull, through the real validator iterators.
##
## `geom` reports, per size class:
##   lanes       how many of the validator's scanned chords are long enough to
##               need interrupting at all, per family, and the perpendicular
##               BAND each family's must-block chords occupy.
##   skeleton    the minimum-area set of the generator's own repair primitive
##               (a 28px-circumradius hex plug) that interrupts all of them,
##               found by greedy set cover over the hull and then VERIFIED
##               with `sightlineOpenRun`. This is the geometric floor: below
##               it, no arrangement of wall can satisfy the sightline rule.
##   plug pass   what `plugOpenSightlines` — the shipping repair — actually
##               spends doing the same job on a bare hull.
##   arena       the hand-authored arena's own cover, the design target.
##
## `dist` samples generated candidates and reports the cover distribution and
## the rejection histogram per size class.
##
##   nim c -d:release -r tools/hex_cover_probe.nim geom
##   nim c -d:release -r tools/hex_cover_probe.nim dist [perClass] [firstSeed]
##
## Curation/derivation tooling; not part of the server.

import std/[math, os, strutils, strformat, algorithm, tables, bitops, sets]
import ../src/ctf/[sim_types, arena, hex]

const
  PlugRadius = 28
    ## `plugOpenSightlines` builds its cover out of `hexShape(px, py, 28)`.
    ## Every skeleton figure below is quoted in that same currency so the
    ## floor is something the generator can actually build, not an idealized
    ## one-pixel membrane.

proc bareShell(cls: HexSizeClass): CtfMap =
  ## The class's hull with its real endzones, flag ring and base depth, and NO
  ## terrain at all. Cover measured on this is exactly zero, so anything the
  ## skeleton adds is attributable to lane blocking.
  result = arenaHexCtfMap(HexClassNames[cls], cls)
  result.leftObstacles = @[]

proc interiorArea(gameMap: CtfMap): int =
  ## The cover-budget denominator, spelled exactly as `collectMapDiagnostics`
  ## spells it: inside the hull's border ring, minus protected floor.
  for y in 0 ..< gameMap.height:
    for x in 0 ..< gameMap.width:
      if not gameMap.mapBorderWallAt(x, y) and
          not mapProtectedFloorAt(gameMap, x, y):
        inc result

proc buildableArea(gameMap: CtfMap): int =
  ## The interior MINUS the ground no generator pass will ever build on: the
  ## endzone aprons and the flag-ring keep-out. This is NOT the cover-budget
  ## denominator, and the difference is the point — see `geom`'s report line.
  let
    apron = gameMap.endzoneRadius + EndzoneApron - EndzoneWallMargin
    keepOut = gameMap.flagRingKeepOut()
  for y in 0 ..< gameMap.height:
    for x in 0 ..< gameMap.width:
      if gameMap.mapBorderWallAt(x, y) or mapProtectedFloorAt(gameMap, x, y):
        continue
      var blocked = false
      for team in gameMap.teams():
        let a = gameMap.teamAnchor(team)
        if endzoneFloorAt(x, y, a.x, a.y, apron, true):
          blocked = true
      let
        dx = x - gameMap.center.x
        dy = y - gameMap.center.y
      if dx * dx + dy * dy <= keepOut * keepOut:
        blocked = true
      if not blocked:
        inc result

proc wallArea(gameMap: CtfMap, obstacles: seq[ArenaShape]): int =
  ## Interior wall pixels, same interior. `rasterizeWallMasks`' maxWall is the
  ## swept union, which is what the cover CEILING is measured on.
  let (maxWall, _) = rasterizeWallMasks(gameMap, obstacles)
  for y in 0 ..< gameMap.height:
    for x in 0 ..< gameMap.width:
      if not gameMap.mapBorderWallAt(x, y) and
          not mapProtectedFloorAt(gameMap, x, y) and
          maxWall[y * gameMap.width + x]:
        inc result

type
  Lane = object
    ## One scanned chord that is long enough to need interrupting, with the
    ## endpoints of its open run on the BARE hull. `perp` is its signed
    ## perpendicular distance from the board centre, which is what turns a
    ## list of lanes into a band width.
    axis, intercept: int
    x0, y0, x1, y1: int
    length: int
    perp: float

proc laneAngle(axis: int): float = degToRad(float(SightlineAxisDeg[axis]))

proc perpCoord(axis: int, x, y: float): float =
  ## Perpendicular coordinate of a point for one family: the signed offset of
  ## the line through it, so two points on the same chord share a value.
  let a = laneAngle(axis)
  -x * sin(a) + y * cos(a)

proc alongCoord(axis: int, x, y: float): float =
  let a = laneAngle(axis)
  x * cos(a) + y * sin(a)

proc plugHalfWidth(axis: int): float =
  ## Half the plug's shadow on this family's perpendicular axis. `hexShape`
  ## defaults to POINTY-TOP, whose vertices sit at 30-degree offsets: against
  ## the three edge-to-edge families the shadow is across the flats
  ## (`R*cos30`), against the three vertex-to-vertex ones it is across the
  ## points (`R`). The vertex families are therefore marginally cheaper to
  ## block per plug, which is half of why the sixth family is nearly free.
  if axis <= 2: float(PlugRadius) * cos(degToRad(30.0))
  else: float(PlugRadius)

proc collectLanes(gameMap: CtfMap): seq[Lane] =
  ## Every scanned chord on the BARE hull whose open run already reaches
  ## `sightlineMinSpan`. These are the lanes any legal map must interrupt;
  ## the shorter chords near the corners are wedges, not lanes, and the
  ## validator never demands cover on them.
  let obstacles = buildArenaObstacles(gameMap)
  let (_, minWall) = rasterizeWallMasks(gameMap, obstacles)
  let
    cx = float(gameMap.center.x)
    cy = float(gameMap.center.y)
  for axis in 0 ..< SightlineAxisCount:
    for intercept in gameMap.sightlineIntercepts(axis):
      let run = gameMap.sightlineOpenRun(minWall, axis, intercept)
      if not run.open:
        continue
      result.add Lane(
        axis: axis, intercept: intercept,
        x0: run.x0, y0: run.y0, x1: run.x1, y1: run.y1,
        length: max(abs(run.x1 - run.x0), abs(run.y1 - run.y0)) + 1,
        perp: perpCoord(axis, float(run.x0) - cx, float(run.y0) - cy))

proc blocks(lane: Lane, gameMap: CtfMap, px, py: int): bool =
  ## Whether a plug centred at `(px, py)` interrupts this lane: its shadow has
  ## to straddle the chord AND land far enough from both ends that neither
  ## remnant is still `sightlineMinSpan` long.
  let
    span = float(gameMap.sightlineMinSpan())
    half = plugHalfWidth(lane.axis)
  if abs(perpCoord(lane.axis, float(px), float(py)) -
      perpCoord(lane.axis, float(lane.x0), float(lane.y0))) > half:
    return false
  let
    t = alongCoord(lane.axis, float(px), float(py))
    t0 = alongCoord(lane.axis, float(lane.x0), float(lane.y0))
    t1 = alongCoord(lane.axis, float(lane.x1), float(lane.y1))
    lo = min(t0, t1)
    hi = max(t0, t1)
  if t <= lo or t >= hi:
    return false
  (t - half) - lo < span and hi - (t + half) < span

proc plugLegal(gameMap: CtfMap, px, py: int): bool =
  ## The placement rules `plugOpenSightlines` obeys, so the skeleton is a
  ## floor for the SHIPPING generator and not just for an abstract hull: fully
  ## inside the hull, off protected floor, outside the endzone apron, and
  ## outside the flag-ring keep-out that stops plugs from sealing the centre.
  let
    board = gameMap.mapBoard()
    apron = gameMap.endzoneRadius + EndzoneApron - EndzoneWallMargin
    keepOut = gameMap.flagRing + 26 + 30
  if board.hexEdgeDist(px, py) < float(ArenaBorder + PlugRadius):
    return false
  if mapProtectedFloorAt(gameMap, px, py):
    return false
  for team in gameMap.teams():
    let a = gameMap.teamAnchor(team)
    if endzoneFloorAt(px, py, a.x, a.y, apron, true):
      return false
  let
    dx = px - gameMap.center.x
    dy = py - gameMap.center.y
  dx * dx + dy * dy > keepOut * keepOut

proc greedySkeleton(gameMap: CtfMap, lanes: seq[Lane],
                    grid: int): seq[MapPoint] =
  ## Minimum-area plug set that interrupts every lane, by greedy set cover on
  ## a `grid`-spaced lattice of candidate centres. Greedy is within a
  ## `ln(n)`-ish factor of optimal on set cover, and every plug costs the same
  ## area here, so "fewest plugs" IS "least wall". The answer is an upper
  ## bound on the true minimum, which is the safe direction for a FLOOR: the
  ## real minimum can only be smaller.
  ##
  ## Two candidate sources. The lattice finds the shared plugs — the ones that
  ## sit where several families cross. Positions taken ALONG each lane (the
  ## same quarter/half/three-quarter points `plugOpenSightlines` builds on)
  ## guarantee every lane has at least one candidate that blocks it, so a
  ## coarse lattice can never leave a lane unreachable and be mistaken for a
  ## lane that no wall can close.
  var
    candidates: seq[MapPoint]
    seen: HashSet[(int, int)]
  proc offer(x, y: int) =
    if x < 0 or y < 0 or x >= gameMap.width or y >= gameMap.height: return
    if (x, y) in seen: return
    seen.incl (x, y)
    if gameMap.plugLegal(x, y):
      candidates.add MapPoint(x: x, y: y)
  var y = gameMap.center.y mod grid
  while y < gameMap.height:
    var x = gameMap.center.x mod grid
    while x < gameMap.width:
      offer(x, y)
      x += grid
    y += grid
  for lane in lanes:
    for num in 1 .. 7:
      offer(lane.x0 + (lane.x1 - lane.x0) * num div 8,
            lane.y0 + (lane.y1 - lane.y0) * num div 8)
  ## Coverage is precomputed once as a bitset per candidate; after that each
  ## greedy round is a word-parallel popcount rather than a re-test of every
  ## (candidate, lane) pair, which is what makes the colossal class tractable.
  let words = (lanes.len + 63) div 64
  var cover = newSeq[uint64](candidates.len * words)
  for ci, c in candidates:
    for li, lane in lanes:
      if lane.blocks(gameMap, c.x, c.y):
        cover[ci * words + (li shr 6)] =
          cover[ci * words + (li shr 6)] or (1'u64 shl (li and 63))
  var remaining = newSeq[uint64](words)
  for li in 0 ..< lanes.len:
    remaining[li shr 6] = remaining[li shr 6] or (1'u64 shl (li and 63))
  var left = lanes.len
  while left > 0:
    var
      best = -1
      bestCount = 0
    for ci in 0 ..< candidates.len:
      var n = 0
      for w in 0 ..< words:
        n += countSetBits(cover[ci * words + w] and remaining[w])
      if n > bestCount:
        bestCount = n
        best = ci
    if best < 0:
      echo "    !! ", left, " lanes unblockable on the candidate grid"
      break
    result.add candidates[best]
    for w in 0 ..< words:
      remaining[w] = remaining[w] and not cover[best * words + w]
    left = 0
    for w in 0 ..< words:
      left += countSetBits(remaining[w])
    for w in 0 ..< words:
      cover[best * words + w] = 0

proc withPlugs(gameMap: CtfMap, plugs: seq[MapPoint]): CtfMap =
  ## The skeleton as a real map. Plugs are placed in the SEED half so
  ## `buildArenaObstacles` mirrors them, exactly like the repair pass — the
  ## mirror image of a blocked ray is blocked too, so folding costs nothing in
  ## coverage and the result is a legal, team-fair board.
  result = gameMap
  result.leftObstacles = @[]
  for p in plugs:
    var (px, py) = (p.x, p.y)
    if px > result.center.x:
      px = result.width - 1 - px
      if result.symmetry == symRot180:
        py = result.height - 1 - py
    result.leftObstacles.add hexShape(px, py, PlugRadius)

proc openLanes(gameMap: CtfMap): int =
  let obstacles = buildArenaObstacles(gameMap)
  let (_, minWall) = rasterizeWallMasks(gameMap, obstacles)
  for axis in 0 ..< SightlineAxisCount:
    for intercept in gameMap.sightlineIntercepts(axis):
      if gameMap.sightlineOpenRun(minWall, axis, intercept).open:
        inc result

proc geom(classes: seq[HexSizeClass]) =
  for cls in classes:
    let
      shell = bareShell(cls)
      board = hexBoardOf(cls)
      interior = shell.interiorArea()
      lanes = shell.collectLanes()
      scale = HexClassScale[cls]
    echo ""
    echo "=== ", HexClassNames[cls], "  ", board.width, "x", board.height,
      "  scale ", formatFloat(scale, ffDecimal, 2), " ==="
    echo &"  playfield {board.hexArea():.0f} px^2   " &
      &"interior (hull - protected) {interior} px^2   " &
      &"protected {board.hexArea().int - interior} px^2"
    let buildable = shell.buildableArea()
    echo &"  buildable (interior - aprons - ring keep-out) {buildable} px^2 " &
      &"= {100.0 * float(buildable) / float(interior):.1f}% of interior"
    echo &"  minSpan {shell.sightlineMinSpan()} px " &
      &"(0.8 * short axis)   endzoneR {shell.endzoneRadius}   " &
      &"flagRing {shell.flagRing}"
    ## Per-family lane census.
    var byAxis: array[SightlineAxisCount, seq[Lane]]
    for lane in lanes:
      byAxis[lane.axis].add lane
    echo "  lanes needing interruption, per family:"
    for axis in 0 ..< SightlineAxisCount:
      if byAxis[axis].len == 0:
        echo &"    {SightlineAxisDeg[axis]:>3} deg: none"
        continue
      var lo = byAxis[axis][0].perp
      var hi = lo
      var longest = 0
      for lane in byAxis[axis]:
        lo = min(lo, lane.perp)
        hi = max(hi, lane.perp)
        longest = max(longest, lane.length)
      let kind = if axis <= 2: "edge  " else: "vertex"
      echo &"    {SightlineAxisDeg[axis]:>3} deg {kind} " &
        &"{byAxis[axis].len:>4} lanes  band {hi - lo:7.1f} px  " &
        &"longest {longest:>5} px  plug shadow {2*plugHalfWidth(axis):5.1f} px"
    echo &"  total lanes: {lanes.len}"

    ## The skeleton: greedy minimum plug cover, then verified.
    let
      grid = max(8, min(32, int(round(16.0 * scale))))
      plugs = shell.greedySkeleton(lanes, grid)
      skeleton = shell.withPlugs(plugs)
      skelObstacles = buildArenaObstacles(skeleton)
      skelWall = skeleton.wallArea(skelObstacles)
      skelPermille = skelWall * 1000 div max(1, interior)
      stillOpen = skeleton.openLanes()
    ## The same skeleton priced in the vocabulary's THINNEST wall feature.
    ## A plug's effective thickness is its area over its mean shadow
    ## (`perimeter/pi`), so a curtain that does the same blocking work drawn
    ## at 12px costs that ratio of the plug figure. This is the number the
    ## FLOOR is set from: a map below it cannot interrupt its chords with any
    ## wall the generator can express.
    let
      plugArea = 3.0 * sqrt(3.0) / 2.0 * float(PlugRadius * PlugRadius)
      plugMeanShadow = 6.0 * float(PlugRadius) / PI
      plugThickness = plugArea / plugMeanShadow
      thinPermille = int(round(float(skelPermille) * 12.0 / plugThickness))
    echo &"  SKELETON  {plugs.len} plugs (grid {grid}px) -> " &
      &"{skelObstacles.len} shapes, {skelWall} px^2 wall = " &
      &"{skelPermille} permille   [{stillOpen} lanes still open]"
    echo &"    plug grain: area {plugArea:.0f} px^2 / mean shadow " &
      &"{plugMeanShadow:.1f} px = {plugThickness:.1f} px effective thickness"
    echo &"    same skeleton at the 12px thinnest wall feature: " &
      &"{thinPermille} permille"
    echo &"  BAND      {shell.coverPermilleMin()} .. {CoverPermilleMax} " &
      &"permille  (floor = CoverPermilleMin {CoverPermilleMin} * " &
      &"{HexStandardHeight}/{shell.height})"

    ## What the shipping repair pass spends on the same bare hull.
    var repaired = shell
    repaired.plugOpenSightlines(4000)
    let
      repObstacles = buildArenaObstacles(repaired)
      repWall = repaired.wallArea(repObstacles)
      repPermille = repWall * 1000 div max(1, interior)
      repOpen = repaired.openLanes()
    echo &"  PLUG PASS {repaired.leftObstacles.len} seed plugs -> " &
      &"{repObstacles.len} shapes, {repWall} px^2 wall = " &
      &"{repPermille} permille   [{repOpen} lanes still open]"

    ## The hand-authored arena on this class: the design target.
    let
      authored = arenaHexCtfMap(HexClassNames[cls], cls)
      authObstacles = buildArenaObstacles(authored)
      authWall = authored.wallArea(authObstacles)
      authInterior = authored.interiorArea()
      authPermille = authWall * 1000 div max(1, authInterior)
    echo &"  ARENA     {authObstacles.len} shapes, {authWall} px^2 wall = " &
      &"{authPermille} permille   " &
      &"[{authored.openLanes()} lanes still open]"

proc dist(classes: seq[HexSizeClass], perClass, firstSeed: int) =
  for cls in classes:
    var
      permilles, minPermilles: seq[int]
      reasons = initCountTable[string]()
      passed = 0
      seen = 0
      seed = firstSeed
    while seen < perClass:
      var candidate: CtfMap
      try:
        candidate = generateMapAttempt(seed, MapGenOverrides(
          size: HexClassNames[cls], windows: -1, pits: -1, pitDensity: -1), 2)
      except CatchableError:
        inc seed
        continue
      inc seen
      inc seed
      let diag = mapDiagnostics(candidate)
      permilles.add diag.coverPermille
      minPermilles.add diag.minCoverPermille
      if diag.reason.len == 0:
        inc passed
      else:
        var bucket = diag.reason
        for cut in [" at ", ": "]:
          let idx = bucket.find(cut)
          if idx >= 0:
            bucket = bucket[0 ..< idx]
        reasons.inc(bucket)
    permilles.sort()
    minPermilles.sort()
    proc q(s: seq[int], p: int): int = s[min(s.high, s.len * p div 100)]
    echo ""
    echo "=== ", HexClassNames[cls], "  n=", seen, "  passed ", passed,
      " (", formatFloat(100.0 * float(passed) / float(seen), ffDecimal, 1), "%)"
    echo &"  coverPermille    p05 {q(permilles,5):>4}  p25 {q(permilles,25):>4}" &
      &"  p50 {q(permilles,50):>4}  p75 {q(permilles,75):>4}" &
      &"  p95 {q(permilles,95):>4}  max {permilles[^1]:>4}"
    echo &"  minCoverPermille p05 {q(minPermilles,5):>4}" &
      &"  p50 {q(minPermilles,50):>4}  p95 {q(minPermilles,95):>4}"
    reasons.sort()
    for reason, n in reasons:
      echo &"    {n:>4}  {reason}"

proc why(sizeName: string, seed: int) =
  ## Locate one rejected seed's open lanes: where they are, how long they are,
  ## and whether the repair pass had anywhere legal to build on them.
  let gameMap = generateMapAttempt(seed, MapGenOverrides(
    size: sizeName, windows: -1, pits: -1, pitDensity: -1), 2)
  let diag = mapDiagnostics(gameMap)
  echo &"seed {seed} {sizeName} {gameMap.width}x{gameMap.height} " &
    &"cover {diag.coverPermille} band {diag.coverPermilleFloor}.." &
    &"{diag.coverPermilleCeiling}  reason: " &
    (if diag.reason.len == 0: "PASS" else: diag.reason)
  echo &"  obstacles(left) {gameMap.leftObstacles.len} " &
    &"trenches {gameMap.trenches.len} minSpan {gameMap.sightlineMinSpan()}"
  echo &"  center ({gameMap.center.x},{gameMap.center.y}) " &
    &"redAnchor ({gameMap.teamAnchor(Red).x},{gameMap.teamAnchor(Red).y}) " &
    &"homeX {gameMap.teamHomeX(Red)} ezR {gameMap.endzoneRadius} " &
    &"apron {gameMap.endzoneRadius + EndzoneApron - EndzoneWallMargin} " &
    &"ringKeepOut {gameMap.flagRing + 26 + 30}"
  let obstacles = buildArenaObstacles(gameMap)
  let (_, minWall) = rasterizeWallMasks(gameMap, obstacles)
  let
    apron = gameMap.endzoneRadius + EndzoneApron - EndzoneWallMargin
    keepOut = gameMap.flagRing + 26 + 30
  var shown = 0
  for axis in 0 ..< SightlineAxisCount:
    for intercept in gameMap.sightlineIntercepts(axis):
      let run = gameMap.sightlineOpenRun(minWall, axis, intercept)
      if not run.open:
        continue
      inc shown
      if shown > 8:
        continue
      let steps = max(abs(run.x1 - run.x0), abs(run.y1 - run.y0)) + 1
      ## How many of the 2*halfSteps+1 positions the repair would try are
      ## legal ground to build on.
      var legal = 0
      let halfSteps = max(1, steps div 16)
      for num in 0 .. 2 * halfSteps:
        let
          px0 = run.x0 + (run.x1 - run.x0) * num div (2 * halfSteps)
          py0 = run.y0 + (run.y1 - run.y0) * num div (2 * halfSteps)
        var (px, py) = (px0, py0)
        if px > gameMap.center.x:
          px = gameMap.width - 1 - px
          if gameMap.symmetry == symRot180:
            py = gameMap.height - 1 - py
        if mapProtectedFloorAt(gameMap, px, py): continue
        if endzoneFloorAt(px, py, gameMap.teamHomeX(Red), gameMap.center.y,
            apron, true): continue
        let
          rdx = px - gameMap.center.x
          rdy = py - gameMap.center.y
        if rdx * rdx + rdy * rdy <= keepOut * keepOut: continue
        inc legal
      echo &"  OPEN axis {SightlineAxisDeg[axis]:>3} deg intercept " &
        &"{intercept:>5}  ({run.x0},{run.y0})->({run.x1},{run.y1})  " &
        &"{steps} steps = {sightlineRunPixels(axis, steps)} px  " &
        &"legal build spots {legal}/{2 * halfSteps + 1}"
  echo &"  open lanes total: {shown}"
  ## Does another repair pass, run right here on the finished map, close them?
  ## If it does, the generator's own call is the thing that is not reaching.
  var retry = gameMap
  retry.plugOpenSightlines(200)
  echo &"  after an extra repair pass: {retry.openLanes()} open, " &
    &"{retry.leftObstacles.len - gameMap.leftObstacles.len} plugs added"

proc longestOpenRun(gameMap: CtfMap): tuple[len: int, deg: int,
                                            x0, y0, x1, y1: int] =
  ## The longest straight run of non-wall pixels anywhere on the board, swept
  ## over 180 directions at 1-degree steps with 1px spacing between parallel
  ## rays. This is the INDEPENDENT check on the sightline rule: the validator
  ## scans six families on a 4px grid, so a slit narrower than that grid can
  ## hide from it, and only a full sweep says what a gun can really cover.
  let obstacles = buildArenaObstacles(gameMap)
  var wall = newSeq[bool](gameMap.width * gameMap.height)
  for y in 0 ..< gameMap.height:
    for x in 0 ..< gameMap.width:
      wall[y * gameMap.width + x] = gameMap.mapWallAt(obstacles, x, y)
  let
    cx = gameMap.center.x
    cy = gameMap.center.y
    reach = int(hypot(float(gameMap.width), float(gameMap.height))) div 2 + 2
  for degI in 0 ..< 180:
    let
      ang = degToRad(float(degI))
      dxs = cos(ang)
      dys = sin(ang)
    for off in -reach .. reach:
      var
        run = 0
        sx, sy = 0
      for t in -reach .. reach:
        let
          x = int(round(float(cx) + dxs * float(t) - dys * float(off)))
          y = int(round(float(cy) + dys * float(t) + dxs * float(off)))
        var open = x >= 0 and y >= 0 and
          x < gameMap.width and y < gameMap.height
        if open:
          open = not wall[y * gameMap.width + x]
        if not open:
          run = 0
          continue
        if run == 0:
          sx = x
          sy = y
        inc run
        if run > result.len:
          result = (run, degI, sx, sy, x, y)

proc runs(sizeName: string, firstSeed, count: int) =
  ## Longest fully-open run on `count` ACCEPTED maps of one class, against the
  ## 1050px gun range. The number the lane rule exists to hold down.
  var seed = firstSeed
  var found = 0
  while found < count:
    let gameMap = generateCtfMap(seed, MapGenOverrides(
      size: sizeName, windows: -1, pits: -1, pitDensity: -1), 2)
    let best = gameMap.longestOpenRun()
    inc found
    echo &"{sizeName} seed {seed:>5}  longest open run {best.len:>5} px " &
      &"at {best.deg:>3} deg  ({best.x0},{best.y0})->({best.x1},{best.y1})  " &
      &"minSpan {gameMap.sightlineMinSpan()}  gunRange {GunRange}  " &
      (if best.len <= GunRange: &"margin {GunRange - best.len} px"
       else: &"OVER by {best.len - GunRange} px")
    seed += 1

when isMainModule:
  let mode = if paramCount() >= 1: paramStr(1) else: "geom"
  var classes: seq[HexSizeClass]
  for c in HexSizeClass:
    classes.add c
  case mode
  of "geom":
    if paramCount() >= 2:
      classes = @[hexSizeClass(paramStr(2))]
    geom(classes)
  of "dist":
    let
      perClass = if paramCount() >= 2: parseInt(paramStr(2)) else: 60
      firstSeed = if paramCount() >= 3: parseInt(paramStr(3)) else: 1001
    ## Colossal is override-only and never drawn at random; skip it here.
    classes = @[hxSmall, hxStandard, hxLarge, hxHuge, hxGiant]
    if paramCount() >= 4:
      classes = @[hexSizeClass(paramStr(4))]
    dist(classes, perClass, firstSeed)
  of "why":
    why(paramStr(2), parseInt(paramStr(3)))
  of "runs":
    runs(paramStr(2), parseInt(paramStr(3)),
         if paramCount() >= 4: parseInt(paramStr(4)) else: 4)
  else:
    quit("usage: hex_cover_probe [geom|dist|why] ...")
