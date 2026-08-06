## Contact sheet + zoomable-review render for a DELIBERATE sample of the
## hexagonal generator's output. Demo/curation tooling; not part of the server.
##
## This is the "look at fifty of them at once" artifact: the point is to see the
## systematic shape of what the generator makes, which one map always hides.
##
## SELECTION RULE (stratified, deterministic, no cherry-picking):
##   The generator draws its size class uniformly over the five random classes
##   and its symmetry on a coin flip, so the honest proportion is 1/10 per
##   (class x symmetry) cell. Seeds are scanned in ascending order from 1 and
##   the FIRST five that land in each of the ten cells are kept -- 50 maps,
##   5 small / 5 standard / 5 large / 5 huge / 5 giant per symmetry.
##   `colossal` is override-only and is never drawn, so it cannot appear.
##   Every seed that the validator REJECTS is recorded with its reason rather
##   than silently skipped: the rejection mix is part of the answer.
##
## RENDER: the real board raster from `tools/map_render.nim` (terrain, glass,
## trenches, the hexagonal hull and its six void corners) with NO diagnostic
## overlays -- no protected-floor tint, no sightline rows, no reachability --
## because those paint over exactly the ground being judged. The endzone disc
## and its capture line are drawn the way the shipped art draws them
## (`map_art.endzoneColorAt`: a team ember wash inside the disc, a solid ring
## at the threshold), and the pedestal is marked at a legible minimum size.
##
##   nim c -d:release -r tools/render_hex_sheet.nim [outDir]

import
  std/[algorithm, json, math, os, strformat, strutils, tables],
  pixie,
  ../src/ctf/[sim, hex],
  map_render

const
  PerCell = 5                  ## maps per (size class x symmetry) cell.
  TileWidth = 760              ## sheet tile raster width, px.
  ZoomWidth = 1000             ## per-map raster inlined into the review page.
  ScanLimit = 4000             ## refuse to hunt forever for an empty cell.
  Pad = 14
  LabelH = 78
  SheetBg = rgba(20, 16, 12, 255)
  InkColor = rgba(232, 220, 200, 255)
  DimColor = rgba(154, 138, 112, 255)
  AccentColor = rgba(80, 220, 255, 255)

type
  Pick = object
    seed: int
    sizeName: string
    symName: string

  Rejection = object
    seed: int
    sizeName: string
    symName: string
    reason: string

proc blendOver(base, tint: ColorRGBA): ColorRGBA =
  ## Straight source-over of an alpha tint onto an opaque base.
  let a = int(tint.a)
  rgba(
    uint8((int(tint.r) * a + int(base.r) * (255 - a)) div 255),
    uint8((int(tint.g) * a + int(base.g) * (255 - a)) div 255),
    uint8((int(tint.b) * a + int(base.b) * (255 - a)) div 255),
    255,
  )

proc classNameOf(gameMap: CtfMap): string =
  ## The size class by its REAL hull dimensions, from hex.nim's own table --
  ## never a second hand-written width list that can drift from the board.
  for c in HexSizeClass:
    if HexSizes[c].width == gameMap.width and
        HexSizes[c].height == gameMap.height:
      return HexClassNames[c]
  &"{gameMap.width}x{gameMap.height}"

proc classIndexOf(name: string): int =
  for c in HexSizeClass:
    if HexClassNames[c] == name:
      return ord(c)
  ord(HexSizeClass.high) + 1

proc symNameOf(gameMap: CtfMap): string =
  ## The map's OWN spec token, so a retired spelling can never be invented here.
  parseJson(gameMap.mapSpecJson())["symmetry"].getStr()

proc teamZoneColor(team: Team): ColorRGBA =
  case team
  of Red: RedEndzoneColor
  of Blue: BlueEndzoneColor
  of Green: GreenEndzoneColor
  of Yellow: YellowEndzoneColor

proc paintEndzone(image: Image, gameMap: CtfMap, scale: float) =
  ## The capture disc as the shipped bake paints it: a low ember wash over the
  ## endzone FLOOR only (stone and glass keep their material), and a solid team
  ## ring on the threshold the carrier has to cross.
  for team in gameMap.teams():
    let
      zone = gameMap.captureZone(team)
      col = teamZoneColor(team)
      cx = (float(zone.anchorX) + 0.5) * scale
      cy = (float(zone.anchorY) + 0.5) * scale
      r = float(zone.radius) * scale
      ringW = max(2.0, 3.0 * scale)
      x0 = max(0, int(floor(cx - r)))
      y0 = max(0, int(floor(cy - r)))
      x1 = min(image.width - 1, int(ceil(cx + r)))
      y1 = min(image.height - 1, int(ceil(cy + r)))
    for y in y0 .. y1:
      for x in x0 .. x1:
        let d = hypot(float(x) + 0.5 - cx, float(y) + 0.5 - cy)
        if d > r:
          continue
        let base = image.unsafe[x, y].rgba
        if base == StoneColor or base == GlassColor:
          continue
        image.unsafe[x, y] =
          if d >= r - ringW:
            blendOver(base, rgba(col.r, col.g, col.b, 210))
          else:
            blendOver(base, rgba(col.r, col.g, col.b, 30))

proc paintPedestal(image: Image, gameMap: CtfMap, scale: float) =
  ## The flag pedestal, floored at a size that survives the sheet's downscale.
  for team in gameMap.teams():
    let
      home = gameMap.flagHome(team)
      col = teamZoneColor(team)
      cx = (float(home.x) + 0.5) * scale
      cy = (float(home.y) + 0.5) * scale
      r = max(5.0, 8.0 * scale)
      x0 = max(0, int(floor(cx - r - 2)))
      y0 = max(0, int(floor(cy - r - 2)))
      x1 = min(image.width - 1, int(ceil(cx + r + 2)))
      y1 = min(image.height - 1, int(ceil(cy + r + 2)))
    for y in y0 .. y1:
      for x in x0 .. x1:
        let d = hypot(float(x) + 0.5 - cx, float(y) + 0.5 - cy)
        if d <= r - 1.6:
          image.unsafe[x, y] = col
        elif d <= r + 0.8:
          image.unsafe[x, y] = rgba(24, 18, 14, 255)

proc rawRender(gameMap: CtfMap, maxDimension: int): MapRenderResult =
  ## The board with NO diagnostic overlays and no pickup crosses: floor, stone,
  ## glass, trenches, hull.
  renderMap(
    gameMap,
    MapRenderOptions(
      maxDimension: maxDimension, overlays: {}, pickupKinds: {}))

proc renderTile(gameMap: CtfMap, maxDimension: int): Image =
  ## One honest board raster. `map_render` stays a pure function of the map;
  ## the endzone and pedestal are composited on top of the finished raster.
  let res = rawRender(gameMap, maxDimension)
  result = res.image
  result.paintEndzone(gameMap, res.renderScale)
  result.paintPedestal(gameMap, res.renderScale)

type CoverStats = object
  ## Where the wall actually IS, measured on the finished raster rather than
  ## re-derived from shape lists: the renderer is the one thing that already
  ## agrees with the picture being judged.
  ##
  ## Every figure is permille of its region's PLAYABLE area (inside the hull,
  ## outside both endzone discs -- protected floor is never carved, so counting
  ## it would dilute every map by a different amount per size class).
  overall: int      ## wall permille of the whole playable interior.
  core: int         ## wall permille inside the central quarter-radius disc.
  lane: int         ## wall permille of the base-to-base corridor band.
  apron: int        ## wall permille of the ring just outside the endzones.
  flank: int        ## wall permille of everything outside the corridor band.

proc coverStats(res: MapRenderResult, gameMap: CtfMap): CoverStats =
  let
    scale = res.renderScale
    image = res.image
    board = gameMap.mapBoard()
    cx = (float(gameMap.center.x) + 0.5) * scale
    cy = (float(gameMap.center.y) + 0.5) * scale
    coreR = 0.25 * float(gameMap.height) * 0.5 * scale
    laneH = 0.15 * float(gameMap.height) * scale
    apronOut = 0.15 * float(gameMap.height) * scale
  var
    anchors: seq[tuple[x, y, r: float]]
  for team in gameMap.teams():
    let zone = gameMap.captureZone(team)
    anchors.add (
      (float(zone.anchorX) + 0.5) * scale,
      (float(zone.anchorY) + 0.5) * scale,
      float(zone.radius) * scale)
  var
    tot, totW, coreN, coreW, laneN, laneW, apronN, apronW, flankN, flankW = 0
  for y in 0 ..< image.height:
    let fy = (float(y) + 0.5) / scale - 0.5
    for x in 0 ..< image.width:
      let fx = (float(x) + 0.5) / scale - 0.5
      if board.hexEdgeDistF(fx, fy) < float(ArenaBorder):
        continue                       ## hull frame and the six void corners.
      var
        inZone = false
        inApron = false
      for a in anchors:
        let d = hypot(float(x) + 0.5 - a.x, float(y) + 0.5 - a.y)
        if d <= a.r:
          inZone = true
        elif d <= a.r + apronOut:
          inApron = true
      if inZone:
        continue
      let
        px = image.unsafe[x, y].rgba
        isWall = px == StoneColor or px == GlassColor
      inc tot
      if isWall: inc totW
      if hypot(float(x) + 0.5 - cx, float(y) + 0.5 - cy) <= coreR:
        inc coreN
        if isWall: inc coreW
      if abs(float(y) + 0.5 - cy) <= laneH:
        inc laneN
        if isWall: inc laneW
      else:
        inc flankN
        if isWall: inc flankW
      if inApron:
        inc apronN
        if isWall: inc apronW
  proc permille(w, n: int): int = (if n == 0: 0 else: 1000 * w div n)
  CoverStats(
    overall: permille(totW, tot),
    core: permille(coreW, coreN),
    lane: permille(laneW, laneN),
    apron: permille(apronW, apronN),
    flank: permille(flankW, flankN),
  )

proc sheetFont(size: float32, col: ColorRGBA): Font =
  result = newFont(readTypeface("data" / "font.ttf"))
  result.size = size
  result.paint = newPaint(SolidPaint)
  result.paint.color = color(
    float32(col.r) / 255, float32(col.g) / 255, float32(col.b) / 255, 1)

proc write(image: Image, font: Font, text: string, x, y: float32) =
  image.fillText(font, text, translate(vec2(x, y)))

proc composeSheet(
  tiles: seq[Image],
  heads, subs: seq[string],
  cols: int,
  title, subtitle: string,
): Image =
  ## A uniform grid. Every hex class shares one aspect ratio, so a single
  ## `maxDimension` makes every tile exactly the same pixels and the grid is
  ## a true contact sheet rather than a ragged collage.
  let
    tw = tiles[0].width
    th = tiles[0].height
    cellW = tw + 2 * Pad
    cellH = th + LabelH + Pad
    rows = (tiles.len + cols - 1) div cols
    headH = 96
  result = newImage(cellW * cols, headH + cellH * rows + Pad)
  result.fill(SheetBg)
  let
    titleFont = sheetFont(40, AccentColor)
    subFont = sheetFont(25, DimColor)
    ## The label has to survive the sheet's own downscale: a 5-wide sheet is
    ## read at ~0.4x, so its type is sized up to land near 14px there.
    headFont = sheetFont(if cols >= 5: 36 else: 28, InkColor)
    metaFont = sheetFont(if cols >= 5: 27 else: 23, DimColor)
  result.write(titleFont, title, float32(Pad + 4), 16)
  result.write(subFont, subtitle, float32(Pad + 4), 60)
  for i, tile in tiles:
    let
      cx = (i mod cols) * cellW
      cy = headH + (i div cols) * cellH
    result.draw(tile, translate(vec2(float32(cx + Pad), float32(cy + LabelH))))
    result.write(headFont, heads[i], float32(cx + Pad), float32(cy + 4))
    result.write(metaFont, subs[i], float32(cx + Pad), float32(cy + 44))

when isMainModule:
  let outDir = if paramCount() >= 1: paramStr(1) else: "hex50"
  createDir(outDir)

  ## ---- selection ---------------------------------------------------------
  var
    quota = initTable[string, int]()
    picks: seq[Pick]
    rejections: seq[Rejection]
    scanned = 0
    seed = 1
  while picks.len < PerCell * 10 and seed <= ScanLimit:
    inc scanned
    var
      candidate: CtfMap
      raised = ""
    try:
      candidate = generateMapAttempt(
        seed, MapGenOverrides(windows: -1, pits: -1, pitDensity: -1), 2)
    except CatchableError as e:
      raised = e.msg
    if raised.len > 0:
      rejections.add Rejection(
        seed: seed, sizeName: "?", symName: "?", reason: "RAISED: " & raised)
      inc seed
      continue
    let
      sizeName = candidate.classNameOf()
      symName = candidate.symNameOf()
      reason = validateGeneratedMap(candidate)
    if reason.len > 0:
      rejections.add Rejection(
        seed: seed, sizeName: sizeName, symName: symName, reason: reason)
      inc seed
      continue
    let key = sizeName & "|" & symName
    if quota.getOrDefault(key) < PerCell:
      quota[key] = quota.getOrDefault(key) + 1
      picks.add Pick(seed: seed, sizeName: sizeName, symName: symName)
    inc seed
  echo "scanned ", scanned, " seeds (1..", seed - 1, ")  selected ", picks.len,
    "  rejected ", rejections.len
  for cell, n in quota:
    echo "  cell ", cell, ": ", n

  ## Read the sheet by class, then symmetry, then seed: the ordering IS the
  ## comparison the giant-boards question needs.
  picks.sort(proc (a, b: Pick): int =
    result = cmp(classIndexOf(a.sizeName), classIndexOf(b.sizeName))
    if result == 0: result = cmp(a.symName, b.symName)
    if result == 0: result = cmp(a.seed, b.seed))

  ## ---- render ------------------------------------------------------------
  var
    tiles: seq[Image]
    heads: seq[string]
    subs: seq[string]
    manifest = newJArray()
    byClass = initTable[string, seq[int]]()
    statTable: seq[CoverStats]
  for i, pick in picks:
    let gameMap = loadCtfMapMetadata("gen:" & $pick.seed)
    doAssert gameMap.genSeed == pick.seed,
      "seed rolled forward: " & $pick.seed
    let
      spec = parseJson(gameMap.mapSpecJson())
      depth = spec["homeDepth"].getInt()
      raw = rawRender(gameMap, ZoomWidth)
      stats = raw.coverStats(gameMap)
      name = &"hex-{i:02}-seed-{pick.seed}.png"
    raw.image.paintEndzone(gameMap, raw.renderScale)
    raw.image.paintPedestal(gameMap, raw.renderScale)
    raw.image.writeFile(outDir / name)
    statTable.add stats
    tiles.add renderTile(gameMap, TileWidth)
    heads.add &"#{i:02}  seed {pick.seed}  {pick.sizeName}"
    subs.add &"{gameMap.width}x{gameMap.height}  {pick.symName}  " &
      &"endzone r{gameMap.endzoneRadius}  base depth {depth}  " &
      &"{gameMap.leftObstacles.len} shapes  {gameMap.trenches.len} pits"
    byClass.mgetOrPut(pick.sizeName, @[]).add i
    var kits = newJArray()
    for p in gameMap.medKitSpawns:
      kits.add %*[p.x, p.y]
    manifest.add %*{
      "index": i,
      "seed": pick.seed,
      "file": name,
      "width": gameMap.width,
      "height": gameMap.height,
      "sizeName": pick.sizeName,
      "boardShape": "hexagon",
      "symmetry": pick.symName,
      "layout": spec["layout"].getStr(),
      "endzone": spec["endzone"].getStr(),
      "endzoneRadius": gameMap.endzoneRadius,
      "homeDepth": spec["homeDepth"].getInt(),
      "homeX": gameMap.teamHomeX(Red),
      "obstacles": gameMap.leftObstacles.len,
      "trenches": gameMap.trenches.len,
      "medKitSpawns": kits,
      "medKitCandidates": newJArray(),
      "coverOverall": stats.overall,
      "coverCore": stats.core,
      "coverLane": stats.lane,
      "coverApron": stats.apron,
      "coverFlank": stats.flank,
    }
    echo "rendered ", name

  ## ---- sheets ------------------------------------------------------------
  let
    rule = "selection: seeds scanned from 1; first " & $PerCell &
      " per (size class x symmetry) cell -- the generator draws both uniformly"
    sub = $picks.len & " maps  |  " & $scanned & " seeds scanned  |  " &
      $rejections.len & " validator rejections  |  " & rule
  composeSheet(tiles, heads, subs, 5,
    "CTF hexagonal generator - 50 maps", sub).writeFile(
      outDir / "contact-sheet-50.png")
  echo "wrote contact-sheet-50.png"

  ## Three 3-wide sheets: the same tiles at a size that still reads after the
  ## whole sheet is downscaled to 1600px.
  var part = 0
  var i = 0
  while i < tiles.len:
    let hi = min(i + 18, tiles.len)
    inc part
    composeSheet(
      tiles[i ..< hi], heads[i ..< hi], subs[i ..< hi], 3,
      &"CTF hex generator - detail sheet {part}/3  (maps #{i:02}-#{hi - 1:02})",
      sub).writeFile(outDir / &"detail-sheet-{part}.png")
    echo "wrote detail-sheet-", part, ".png"
    i = hi

  ## ---- true-scale comparison --------------------------------------------
  ## Every tile above is fitted to the same width, which HIDES the one thing a
  ## size class is: how big the field is relative to the cover on it. This
  ## strip renders one map per class at a COMMON pixel scale, so an obstacle
  ## that does not scale with the board is visible as an obstacle that does not
  ## scale with the board.
  block trueScale:
    const CommonScale = 0.26
    var
      strips: seq[Image]
      labels: seq[string]
    for c in HexSizeClass:
      let name = HexClassNames[c]
      if name notin byClass:
        continue
      let
        pick = picks[byClass[name][0]]
        gameMap = loadCtfMapMetadata("gen:" & $pick.seed)
      strips.add renderTile(
        gameMap, int(round(float(gameMap.width) * CommonScale)))
      labels.add &"{name}  seed {pick.seed}  {gameMap.width}x{gameMap.height}"
    if strips.len == 0:
      break trueScale
    var totalW = Pad
    var maxH = 0
    for s in strips:
      totalW += s.width + Pad
      maxH = max(maxH, s.height)
    var strip = newImage(totalW, maxH + 96 + Pad)
    strip.fill(SheetBg)
    let
      titleFont = sheetFont(30, AccentColor)
      labelFont = sheetFont(22, InkColor)
    strip.write(titleFont, "Same pixel scale across size classes - " &
      "obstacle vocabulary does not scale with the field",
      float32(Pad), 12)
    var x = Pad
    for k, s in strips:
      strip.draw(s, translate(vec2(float32(x), float32(96))))
      strip.write(labelFont, labels[k], float32(x), 62)
      x += s.width + Pad
    strip.writeFile(outDir / "true-scale-strip.png")
    echo "wrote true-scale-strip.png"

  ## ---- manifests ---------------------------------------------------------
  writeFile(outDir / "manifest.json", pretty(manifest))
  var rejJson = newJArray()
  var reasonCounts = initCountTable[string]()
  for r in rejections:
    var bucket = r.reason
    for cut in [" at ", ": "]:
      let idx = bucket.find(cut)
      if idx >= 0:
        bucket = bucket[0 ..< idx]
    reasonCounts.inc(bucket)
    rejJson.add %*{
      "seed": r.seed, "size": r.sizeName, "symmetry": r.symName,
      "reason": r.reason,
    }
  var buckets = newJArray()
  reasonCounts.sort()
  for reason, n in reasonCounts:
    buckets.add %*{"reason": reason, "count": n}
  var cells = newJArray()
  for cell, n in quota:
    let parts = cell.split('|')
    cells.add %*{"size": parts[0], "symmetry": parts[1], "count": n}
  writeFile(outDir / "meta.json", pretty(%*{
    "selectionRule": rule,
    "seedsScanned": scanned,
    "seedRangeHi": seed - 1,
    "selected": picks.len,
    "cells": cells,
    "rejections": rejJson,
    "rejectionBuckets": buckets,
  }))
  ## ---- where the wall went, by class ------------------------------------
  ## The sheet answers "does it look good"; this answers "is the middle the
  ## emptiest part", which no amount of squinting settles.
  echo "-- cover permille of playable interior (endzone discs excluded)"
  echo "  class      n   overall  core  lane  flank  apron   core/overall"
  var order: seq[string]
  for c in HexSizeClass:
    if HexClassNames[c] in byClass:
      order.add HexClassNames[c]
  for name in order:
    var s: array[5, int]
    let idx = byClass[name]
    for i in idx:
      s[0] += statTable[i].overall
      s[1] += statTable[i].core
      s[2] += statTable[i].lane
      s[3] += statTable[i].flank
      s[4] += statTable[i].apron
    let n = idx.len
    echo "  ", alignLeft(name, 10), align($n, 2), "  ",
      align($(s[0] div n), 7), align($(s[1] div n), 6),
      align($(s[2] div n), 6), align($(s[3] div n), 7),
      align($(s[4] div n), 7), "   ",
      formatFloat(float(s[1]) / float(max(1, s[0])), ffDecimal, 2)
  echo "-- rejections: ", rejections.len, " of ", scanned, " seeds scanned"
  for reason, n in reasonCounts:
    echo "  ", align($n, 4), "  ", reason
  echo "wrote ", outDir / "manifest.json"
