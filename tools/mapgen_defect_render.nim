## mapgen_defect_render — renders a generated map and DRAWS the measurement
## that `tools/mapgen_defect_probe.nim` reports, so a number can be looked at.
##
## Glass already renders cyan in `tools/map_render.nim`. What this adds is the
## thing the picture cannot show on its own: the sightline each pane actually
## has. From every window it marches both ways on the vision mask (minWall
## minus glass — the mask the FOG uses, not the one the validator uses) and
## paints the free run GREEN where it clears the useful bar and RED where a
## wall cuts it short, with a marker on the occluder it ran into.
##
## PURITY: same contract as map_render — no map is installed, no process
## global is read.
##
## Usage:
##   mapgen_defect_render --seed 1008 --teams 2 -o /tmp/m.png
##   mapgen_defect_render --seed 1008 --crop 527,350,260 -o /tmp/zoom.png
##   mapgen_defect_render --map arena -o /tmp/arena.png       # the CONTROL

import
  std/[math, os, strformat, strutils, tables],
  pixie,
  ../src/ctf/sim,
  map_render

const
  MarchStep = 2
  UsefulDepthPx = 200
  RayGood = rgba(60, 235, 90, 255)
  RayBad = rgba(255, 60, 60, 255)
  HitMark = rgba(255, 230, 40, 255)

type Bounds = tuple[x0, y0, x1, y1: int]

proc bboxOf(shape: ArenaShape): Bounds =
  case shape.kind
  of shapeRect:
    (shape.rect.x, shape.rect.y,
      shape.rect.x + shape.rect.w - 1, shape.rect.y + shape.rect.h - 1)
  of shapeDisc, shapeDiamond:
    (shape.cx - shape.radius, shape.cy - shape.radius,
      shape.cx + shape.radius, shape.cy + shape.radius)
  of shapeDiagonal:
    let t = shape.thickness
    (min(shape.x0, shape.x1) - t, min(shape.y0, shape.y1) - t,
      max(shape.x0, shape.x1) + t, max(shape.y0, shape.y1) + t)
  of shapePolygon:
    var b: Bounds = (int.high, int.high, int.low, int.low)
    for p in shape.points:
      b.x0 = min(b.x0, p.x); b.y0 = min(b.y0, p.y)
      b.x1 = max(b.x1, p.x); b.y1 = max(b.y1, p.y)
    b

proc main() =
  var flags = initTable[string, string]()
  let argv = commandLineParams()
  var i = 0
  while i < argv.len:
    let a = argv[i]
    if a.startsWith("--") and i + 1 < argv.len:
      flags[a[2 .. ^1]] = argv[i + 1]; inc i
    elif a == "-o" and i + 1 < argv.len:
      flags["out"] = argv[i + 1]; inc i
    inc i

  let
    mapName = flags.getOrDefault("map", "")
    teams = flags.getOrDefault("teams", "2").parseInt
    outPath = flags.getOrDefault("out", "/tmp/mapgen_defect.png")
  var gameMap =
    if mapName.len > 0: loadCtfMapMetadata(mapName)
    else: generateCtfMap(flags.getOrDefault("seed", "1000").parseInt,
      MapGenOverrides(windows: -1, pits: -1, pitDensity: -1), teams)

  let
    w = gameMap.width
    h = gameMap.height
    obstacles = buildArenaObstacles(gameMap)
  let (maxWall, minWall) = rasterizeWallMasks(gameMap, obstacles)
  var glass = newSeq[bool](w * h)
  for shape in obstacles:
    if not shape.window: continue
    let b = bboxOf(shape)
    for y in max(b.y0, 0) .. min(b.y1, h - 1):
      for x in max(b.x0, 0) .. min(b.x1, w - 1):
        if maxWall[y * w + x] and inShape(x, y, shape): glass[y * w + x] = true
  var vision = newSeq[bool](w * h)
  for k in 0 ..< w * h: vision[k] = minWall[k] and not glass[k]

  let options = MapRenderOptions(
    maxDimension: 0,
    overlays: {overlayPickups},
    pickupKinds: AllPickupKinds)
  var render = renderMap(gameMap, options)
  let img = render.image

  proc plot(px, py: int, c: ColorRGBA) =
    for dy in -1 .. 1:
      for dx in -1 .. 1:
        let (x, y) = (px + dx, py + dy)
        if x >= 0 and y >= 0 and x < img.width and y < img.height:
          img.unsafe[x, y] = c

  var report: seq[string]
  for shape in obstacles:
    if not shape.window: continue
    let b = bboxOf(shape)
    let
      bw = b.x1 - b.x0
      bh = b.y1 - b.y0
      alongY = bw <= bh                 ## thin in x => the view is horizontal
      (dxs, dys) = if alongY: (1, 0) else: (0, 1)
      cx = (b.x0 + b.x1) div 2
      cy = (b.y0 + b.y1) div 2
    for sgn in [1, -1]:
      let (dx, dy) = (dxs * sgn, dys * sgn)
      var (x, y) = (cx, cy)
      var guard = 0
      while x >= 0 and y >= 0 and x < w and y < h and
          inShape(x, y, shape) and guard < 400:
        x += dx; y += dy; inc guard
      var d = 0
      var trail: seq[(int, int)]
      while d < GunRange:
        if x < 0 or y < 0 or x >= w or y >= h: break
        if vision[y * w + x]: break
        trail.add (x, y)
        x += dx * MarchStep; y += dy * MarchStep; d += MarchStep
      let color = if d >= UsefulDepthPx: RayGood else: RayBad
      for (tx, ty) in trail:
        plot(int(float(tx) * render.renderScale),
          int(float(ty) * render.renderScale), color)
      if d < GunRange:
        plot(int(float(x) * render.renderScale),
          int(float(y) * render.renderScale), HitMark)
      report.add &"pane ({cx},{cy}) {shape.kind} dir=({dx},{dy}) freeDepth={d}px"

  var shot = img
  if "crop" in flags:
    let parts = flags["crop"].split(',')
    let
      ccx = parts[0].parseInt
      ccy = parts[1].parseInt
      rad = parts[2].parseInt
      x0 = clamp(int(float(ccx - rad) * render.renderScale), 0, img.width - 1)
      y0 = clamp(int(float(ccy - rad) * render.renderScale), 0, img.height - 1)
      x1 = clamp(int(float(ccx + rad) * render.renderScale), x0 + 1, img.width)
      y1 = clamp(int(float(ccy + rad) * render.renderScale), y0 + 1, img.height)
    shot = img.subImage(x0, y0, x1 - x0, y1 - y0)
    let zoom = max(1, 700 div max(1, shot.width))
    if zoom > 1:
      shot = shot.resize(shot.width * zoom, shot.height * zoom)
  elif "max" in flags:
    let m = flags["max"].parseInt
    if shot.width > m or shot.height > m:
      let s = min(float(m) / float(shot.width), float(m) / float(shot.height))
      shot = shot.resize(max(1, int(float(shot.width) * s)),
        max(1, int(float(shot.height) * s)))
  shot.writeFile(outPath)
  for line in report: stderr.writeLine(line)
  stderr.writeLine(&"{gameMap.name} {w}x{h} {gameMap.symmetry} " &
    &"{gameMap.endzone} -> {outPath}")

when isMainModule:
  main()
