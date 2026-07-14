## High-resolution rendering assets for the sprite protocol.
##
## The simulation keeps its 1235x659 map-pixel coordinate system untouched;
## rendering multiplies map coordinates by RenderScale when placing objects on
## the zoomable map/fog layers and serves sprites drawn at RenderScale times
## their map footprint. Art masters live in data/hd/*.png and are rasterized
## here once per process: the crew master is recolored per player color and
## pre-rotated into HdCrewRotations aim steps, the procedural arena geometry
## is re-evaluated at float coordinates (sim.inShapeF) so wall edges stay
## crisp, and the floor is served as one tiled texture sprite instead of a
## full-map image to keep init packets small.

import
  std/[math, os, tables],
  pixie,
  bitworld/spriteprotocol,
  sim

const
  RenderScale* = 3             ## HD px per map px on the zoomable layers.
  SmoothLayerFlag* = 8         ## client hint: smooth (not nearest) upscaling.
  HdCrewSize* = 96             ## HD player sprite canvas (32 map px).
  HdCrewBodyPx = 50            ## the soldier body's target size on the canvas.
  HdCrewRotations* = 16        ## pre-rotated aim steps (16 brads apart).
  HdFlagSize* = 60             ## flag art canvas (20 map px): the banner must
                               ## dominate the canvas to read as a flag in-game.
  HdPedestalSize* = 60         ## pedestal pad art canvas (20 map px).
  HdFloorTileMapPx* = 128      ## one floor tile covers 128x128 map px.
  HdFloorTilePx = HdFloorTileMapPx * RenderScale
  ## Sprite-id pools (disjoint from everything in global.nim).
  HdFloorSpriteId* = 25000
  HdTintSpriteBase* = 25100    ## +0 red half wash, +1 blue half wash.
  HdWallSpriteBase* = 25200    ## one per unique wall form or carved instance.
  HdBorderSpriteBase* = 25300  ## top, bottom, left, right slabs.
  HdPedestalSpriteBase* = 25400  ## +0 red, +1 blue.
  ## Object-id pools for the static map furniture.
  HdFloorObjectBase* = 25000
  HdTintObjectBase* = 25100
  HdWallObjectBase* = 25200
  HdBorderObjectBase* = 25300
  HdPedestalObjectBase* = 25400
  ## HD player sprite ids: base + colorIndex * HdCrewRotations + rotation.
  HdPlayerSpriteBase* = 34000
  HdSelfSpriteBase* = 34500
  HdSelectedSpriteBase* = 35000
  ## Map furniture z order (i16 on the wire; the map anchor sits at -32768).
  HdFloorZ* = -32760
  HdTintZ* = -32759
  HdWallZ* = -32758
  HdPedestalZ* = -32757
  ArenaRedWash = rgba(120, 40, 44, 70)
  ArenaBlueWash = rgba(44, 60, 128, 70)
  WallEdgeDarken = 0.55        ## edge pixels keep 55% of their brightness.

type
  HdCrewKind* = enum
    hdCrewNormal
    hdCrewSelf
    hdCrewSelected

  HdWallPiece* = object
    ## One placed wall sprite: a deduped pure form or a carved instance.
    spriteId*: int
    x*, y*: int                ## map-px top-left for object placement.
    width*, height*: int       ## HD px sprite dimensions.

var
  hdLoaded = false
  hdCrewMaster: Image
  hdBodyCx, hdBodyCy: float    ## crew body pivot in master coordinates.
  hdBodyScale: float           ## master -> canvas scale for the body target.
  hdFloorImage: Image
  hdWallImage: Image
  hdFlagPixels: array[Team, seq[uint8]]
  hdPedestalPixels: array[Team, seq[uint8]]
  hdFloorPixels: seq[uint8]
  hdTintPixels: array[Team, seq[uint8]]
  hdCrewRecolored: Table[int, Image]
  hdCrewCache: Table[(int, int, HdCrewKind), seq[uint8]]
  hdWallPieces: seq[HdWallPiece]
  hdWallSprites: Table[int, tuple[width, height: int, pixels: seq[uint8]]]
  hdBorderSprites: array[4, tuple[x, y, width, height: int, pixels: seq[uint8]]]

proc hdDataDir(): string =
  gameDir() / "data" / "hd"

proc toStraightRgba(image: Image): seq[uint8] =
  ## Converts a pixie image (premultiplied RGBX) to straight protocol RGBA.
  result = newSeq[uint8](image.width * image.height * 4)
  for i in 0 ..< image.width * image.height:
    let c = image.data[i].rgba()
    result[i * 4] = c.r
    result[i * 4 + 1] = c.g
    result[i * 4 + 2] = c.b
    result[i * 4 + 3] = c.a

proc readHdImage(name: string): Image =
  readImage(hdDataDir() / name)

proc measureCrewBody(master: Image) =
  ## Finds the soldier body pivot: the rifle is a thin horizontal appendage,
  ## so body columns are the ones with a tall opaque span. Rotations pivot on
  ## the body center so the character spins in place and the gun sweeps.
  var colCounts = newSeq[int](master.width)
  var maxCol = 1
  for x in 0 ..< master.width:
    for y in 0 ..< master.height:
      if master.data[y * master.width + x].a >= 64:
        inc colCounts[x]
    maxCol = max(maxCol, colCounts[x])
  var left = -1
  var right = -1
  for x in 0 ..< master.width:
    if colCounts[x] * 100 >= maxCol * 35:
      if left < 0:
        left = x
      right = x
  if left < 0:
    left = 0
    right = master.width - 1
  var top = master.height
  var bottom = -1
  for x in left .. right:
    for y in 0 ..< master.height:
      if master.data[y * master.width + x].a >= 64:
        top = min(top, y)
        bottom = max(bottom, y)
  if bottom < top:
    top = 0
    bottom = master.height - 1
  hdBodyCx = float(left + right) / 2
  hdBodyCy = float(top + bottom) / 2
  let bodySpan = float(max(right - left + 1, bottom - top + 1))
  hdBodyScale = float(HdCrewBodyPx) / max(1.0, bodySpan)

proc buildFlagPixels(image: Image): seq[uint8] =
  image.resize(HdFlagSize, HdFlagSize).toStraightRgba()

proc buildPedestalPixels(image: Image): seq[uint8] =
  image.resize(HdPedestalSize, HdPedestalSize).toStraightRgba()

proc buildTintPixels(team: Team): seq[uint8] =
  ## One translucent territory wash covering a half of the map at HD scale.
  let
    width = (MapWidth div 2 + MapWidth mod 2) * RenderScale
    height = MapHeight * RenderScale
    tint = if team == Red: ArenaRedWash else: ArenaBlueWash
  result = newSeq[uint8](width * height * 4)
  for i in 0 ..< width * height:
    result[i * 4] = tint.r
    result[i * 4 + 1] = tint.g
    result[i * 4 + 2] = tint.b
    result[i * 4 + 3] = tint.a

proc wallTexel(worldX, worldY: int): ColorRGBA =
  ## Samples the wall texture, tiled, at one HD pixel.
  let
    tx = ((worldX mod hdWallImage.width) + hdWallImage.width) mod
      hdWallImage.width
    ty = ((worldY mod hdWallImage.height) + hdWallImage.height) mod
      hdWallImage.height
  hdWallImage.data[ty * hdWallImage.width + tx].rgba()

proc putWallPixel(
  pixels: var seq[uint8],
  index: int,
  texel: ColorRGBA,
  edge: bool
) =
  ## Writes one wall pixel, darkening shape edges for readability.
  if edge:
    pixels[index * 4] = uint8(float(texel.r) * WallEdgeDarken)
    pixels[index * 4 + 1] = uint8(float(texel.g) * WallEdgeDarken)
    pixels[index * 4 + 2] = uint8(float(texel.b) * WallEdgeDarken)
  else:
    pixels[index * 4] = texel.r
    pixels[index * 4 + 1] = texel.g
    pixels[index * 4 + 2] = texel.b
  pixels[index * 4 + 3] = 255

proc rasterizeWallRegion(
  originX, originY: int,          ## map px of the sprite's top-left.
  width, height: int,             ## HD px sprite dimensions.
  inside: proc(mx, my: float): bool
): seq[uint8] =
  ## Rasterizes one wall region at HD resolution: each HD pixel samples the
  ## predicate at its map-space center, edge pixels (any 4-neighbour outside
  ## at 1 HD px reach) darken to outline the shape.
  result = newSeq[uint8](width * height * 4)
  let step = 1.0 / float(RenderScale)
  for py in 0 ..< height:
    for px in 0 ..< width:
      let
        mx = float(originX) + (float(px) + 0.5) * step
        my = float(originY) + (float(py) + 0.5) * step
      if not inside(mx, my):
        continue
      # A two-HD-px reach keeps the outline readable at typical zoom.
      let edge =
        not inside(mx - step, my) or not inside(mx + step, my) or
        not inside(mx, my - step) or not inside(mx, my + step) or
        not inside(mx - 2 * step, my) or not inside(mx + 2 * step, my) or
        not inside(mx, my - 2 * step) or not inside(mx, my + 2 * step)
      result.putWallPixel(
        py * width + px,
        wallTexel(px, py),
        edge
      )

proc shapeBounds(shape: ArenaShape): tuple[x, y, w, h: int] =
  ## Map-px bounding box of one arena shape, padded one pixel.
  case shape.kind
  of shapeRect:
    (shape.rect.x - 1, shape.rect.y - 1, shape.rect.w + 2, shape.rect.h + 2)
  of shapeDisc, shapeDiamond:
    (shape.cx - shape.radius - 1, shape.cy - shape.radius - 1,
      shape.radius * 2 + 3, shape.radius * 2 + 3)
  of shapeDiagonal:
    let
      half = shape.thickness div 2 + 2
      x0 = min(shape.x0, shape.x1) - half
      y0 = min(shape.y0, shape.y1) - half
      x1 = max(shape.x0, shape.x1) + half
      y1 = max(shape.y0, shape.y1) + half
    (x0, y0, x1 - x0 + 1, y1 - y0 + 1)

proc rebase(shape: ArenaShape, dx, dy: int): ArenaShape =
  ## Returns the shape translated by (-dx, -dy) into sprite-local map coords.
  case shape.kind
  of shapeRect:
    ArenaShape(kind: shapeRect, rect: MapRect(
      x: shape.rect.x - dx, y: shape.rect.y - dy,
      w: shape.rect.w, h: shape.rect.h))
  of shapeDisc:
    ArenaShape(kind: shapeDisc, cx: shape.cx - dx, cy: shape.cy - dy,
      radius: shape.radius)
  of shapeDiamond:
    ArenaShape(kind: shapeDiamond, cx: shape.cx - dx, cy: shape.cy - dy,
      radius: shape.radius)
  of shapeDiagonal:
    ArenaShape(kind: shapeDiagonal,
      x0: shape.x0 - dx, y0: shape.y0 - dy,
      x1: shape.x1 - dx, y1: shape.y1 - dy,
      thickness: shape.thickness)

proc shapeSignature(shape: ArenaShape): string =
  ## Dedupe key for translation-identical shapes.
  case shape.kind
  of shapeRect:
    "r" & $shape.rect.w & "x" & $shape.rect.h
  of shapeDisc:
    "o" & $shape.radius
  of shapeDiamond:
    "d" & $shape.radius
  of shapeDiagonal:
    "g" & $(shape.x1 - shape.x0) & "," & $(shape.y1 - shape.y0) & "," &
      $shape.thickness

proc shapeIsCarved(shape: ArenaShape, cx, cy: int): bool =
  ## True when the protected-floor carve removes part of this instance, in
  ## which case its sprite is position-specific and cannot be deduped.
  let bounds = shape.shapeBounds()
  for my in bounds.y .. bounds.y + bounds.h:
    for mx in bounds.x .. bounds.x + bounds.w:
      let
        fx = float(mx) + 0.5
        fy = float(my) + 0.5
      if inShapeF(fx, fy, shape) and not shapeWallAtF(fx, fy, shape, cx, cy):
        return true
  false

proc buildWallPieces(center: MapPoint) =
  ## Builds every wall sprite (deduped forms plus carved instances) and the
  ## list of placements consumed by the packet builders.
  hdWallPieces = @[]
  hdWallSprites = initTable[int, tuple[width, height: int, pixels: seq[uint8]]]()
  var formIds = initTable[string, int]()
  var nextSprite = HdWallSpriteBase
  for obstacle in ArenaObstacles:
    let
      shape = obstacle              # a plain copy the closures can capture
      bounds = shape.shapeBounds()
      width = bounds.w * RenderScale
      height = bounds.h * RenderScale
      carved = shape.shapeIsCarved(center.x, center.y)
      local = shape.rebase(bounds.x, bounds.y)
    var spriteId = -1
    if not carved:
      let key = shape.shapeSignature()
      if key in formIds:
        spriteId = formIds[key]
      else:
        spriteId = nextSprite
        inc nextSprite
        formIds[key] = spriteId
        hdWallSprites[spriteId] = (width, height, rasterizeWallRegion(
          0, 0, width, height,
          proc(mx, my: float): bool = inShapeF(mx, my, local)
        ))
    else:
      # The protected-floor carve depends on world position, so a carved
      # instance rasterizes in world coordinates and cannot be deduped.
      spriteId = nextSprite
      inc nextSprite
      hdWallSprites[spriteId] = (width, height, rasterizeWallRegion(
        bounds.x, bounds.y, width, height,
        proc(mx, my: float): bool =
          shapeWallAtF(mx, my, shape, center.x, center.y)
      ))
    hdWallPieces.add HdWallPiece(
      spriteId: spriteId,
      x: bounds.x,
      y: bounds.y,
      width: width,
      height: height
    )

proc buildBorderSlabs() =
  ## Four border wall slabs with a darkened inner edge.
  let
    w = MapWidth * RenderScale
    h = MapHeight * RenderScale
    b = ArenaBorder * RenderScale
  proc slab(width, height, edgeSide: int): seq[uint8] =
    ## edgeSide: 0 bottom edge darkened, 1 top, 2 right, 3 left.
    result = newSeq[uint8](width * height * 4)
    for py in 0 ..< height:
      for px in 0 ..< width:
        let edge =
          case edgeSide
          of 0: py >= height - 2 * RenderScale
          of 1: py < 2 * RenderScale
          of 2: px >= width - 2 * RenderScale
          else: px < 2 * RenderScale
        result.putWallPixel(py * width + px, wallTexel(px, py), edge)
  hdBorderSprites[0] = (0, 0, w, b, slab(w, b, 0))
  hdBorderSprites[1] = (0, MapHeight - ArenaBorder, w, b, slab(w, b, 1))
  hdBorderSprites[2] = (0, ArenaBorder, b, h - 2 * b, slab(b, h - 2 * b, 2))
  hdBorderSprites[3] = (MapWidth - ArenaBorder, ArenaBorder, b, h - 2 * b,
    slab(b, h - 2 * b, 3))

proc hdEnsureLoaded*(gameMap: CtfMap) =
  ## Loads and rasterizes every HD asset once per process.
  if hdLoaded:
    return
  hdCrewMaster = readHdImage("crew_red.png")
  hdCrewMaster.measureCrewBody()
  hdFloorImage = readHdImage("floor.png").resize(HdFloorTilePx, HdFloorTilePx)
  hdWallImage = readHdImage("wall.png")
  hdFlagPixels[Red] = buildFlagPixels(readHdImage("flag_red.png"))
  hdFlagPixels[Blue] = buildFlagPixels(readHdImage("flag_blue.png"))
  hdPedestalPixels[Red] = buildPedestalPixels(readHdImage("pedestal_red.png"))
  hdPedestalPixels[Blue] = buildPedestalPixels(readHdImage("pedestal_blue.png"))
  hdFloorPixels = hdFloorImage.toStraightRgba()
  hdTintPixels[Red] = buildTintPixels(Red)
  hdTintPixels[Blue] = buildTintPixels(Blue)
  buildWallPieces(gameMap.center)
  buildBorderSlabs()
  hdLoaded = true

proc hdFlagSpritePixels*(team: Team): seq[uint8] =
  hdFlagPixels[team]

proc hdPedestalSpritePixels*(team: Team): seq[uint8] =
  hdPedestalPixels[team]

proc hdFloorSpritePixels*(): seq[uint8] =
  hdFloorPixels

proc hdTintSpritePixels*(team: Team): seq[uint8] =
  hdTintPixels[team]

proc hdTintSize*(): tuple[width, height: int] =
  ((MapWidth div 2 + MapWidth mod 2) * RenderScale, MapHeight * RenderScale)

proc hdWallPiecesList*(): seq[HdWallPiece] =
  hdWallPieces

proc hdWallSprite*(spriteId: int): tuple[width, height: int, pixels: seq[uint8]] =
  hdWallSprites[spriteId]

proc hdBorderSlab*(index: int): tuple[x, y, width, height: int, pixels: seq[uint8]] =
  hdBorderSprites[index]

proc recoloredCrew(colorIndex: int): Image =
  ## Recolors the master's red accent panels toward one palette color,
  ## preserving shading (value) and highlights (desaturation).
  if colorIndex in hdCrewRecolored:
    return hdCrewRecolored[colorIndex]
  # Saturate and brighten the palette target: the PICO-8 player colors are
  # muted (e.g. "blue" is lavender 131,118,156) and read grey on the large
  # HD armor panels.
  let muted = Palette[PlayerColors[colorIndex and 0x0f] and 0x0f]
  let grey = (int(muted.r) + int(muted.g) + int(muted.b)) div 3
  proc lively(c: uint8): uint8 =
    uint8(clamp((grey + (int(c) - grey) * 2) * 23 div 20, 0, 255))
  let target = rgba(lively(muted.r), lively(muted.g), lively(muted.b), 255)
  var image = newImage(hdCrewMaster.width, hdCrewMaster.height)
  for i in 0 ..< hdCrewMaster.data.len:
    let c = hdCrewMaster.data[i].rgba()
    if c.a == 0:
      image.data[i] = rgbx(0, 0, 0, 0)
      continue
    let
      r = int(c.r)
      g = int(c.g)
      b = int(c.b)
    if r > 60 and r * 10 > g * 16 and r * 10 > b * 16:
      let
        value = r                     # accent brightness rides the red channel
        whiteMix = min(g, b)          # pink highlights keep their sheen
      var recolored = rgba(
        uint8(min(255, int(target.r) * value div 255 + whiteMix div 2)),
        uint8(min(255, int(target.g) * value div 255 + whiteMix div 2)),
        uint8(min(255, int(target.b) * value div 255 + whiteMix div 2)),
        c.a
      )
      image.data[i] = recolored.rgbx()
    else:
      image.data[i] = c.rgbx()
  hdCrewRecolored[colorIndex] = image
  image

proc outlineColor(kind: HdCrewKind): ColorRGBA =
  case kind
  of hdCrewNormal:
    rgba(0, 0, 0, 0)
  of hdCrewSelf:
    rgba(255, 255, 255, 255)
  of hdCrewSelected:
    Palette[8]                       # the legacy selected-outline yellow

proc hdCrewSpritePixels*(colorIndex, rot: int, kind: HdCrewKind): seq[uint8] =
  ## One pre-rotated, recolored, optionally outlined HD crew sprite.
  let key = (colorIndex, rot, kind)
  if key in hdCrewCache:
    return hdCrewCache[key]
  let
    master = recoloredCrew(colorIndex)
    angle = float(rot) * 2.0 * PI / float(HdCrewRotations)
  var canvas = newImage(HdCrewSize, HdCrewSize)
  let mat =
    translate(vec2(float32(HdCrewSize) / 2, float32(HdCrewSize) / 2)) *
    rotate(float32(-angle)) *
    scale(vec2(float32(hdBodyScale), float32(hdBodyScale))) *
    translate(vec2(float32(-hdBodyCx), float32(-hdBodyCy)))
  canvas.draw(master, mat)
  var pixels = canvas.toStraightRgba()
  let outline = outlineColor(kind)
  if outline.a > 0:
    # Two-pixel outline: any transparent pixel near a solid one lights up.
    var solid = newSeq[bool](HdCrewSize * HdCrewSize)
    for i in 0 ..< solid.len:
      solid[i] = pixels[i * 4 + 3] >= 64
    for y in 0 ..< HdCrewSize:
      for x in 0 ..< HdCrewSize:
        let i = y * HdCrewSize + x
        if solid[i]:
          continue
        var adjacent = false
        for dy in -2 .. 2:
          for dx in -2 .. 2:
            let
              nx = x + dx
              ny = y + dy
            if nx < 0 or ny < 0 or nx >= HdCrewSize or ny >= HdCrewSize:
              continue
            if solid[ny * HdCrewSize + nx]:
              adjacent = true
        if adjacent:
          pixels[i * 4] = outline.r
          pixels[i * 4 + 1] = outline.g
          pixels[i * 4 + 2] = outline.b
          pixels[i * 4 + 3] = outline.a
  hdCrewCache[key] = pixels
  pixels

proc hdRotIndex*(aimBrads: int): int =
  ## Quantizes an aim angle to the nearest pre-rotated sprite step.
  ((aimBrads + AimBradsTurn div (HdCrewRotations * 2)) *
    HdCrewRotations div AimBradsTurn) mod HdCrewRotations

proc hdPlayerSpriteId*(colorIndex, rot: int, kind: HdCrewKind): int =
  let base =
    case kind
    of hdCrewNormal: HdPlayerSpriteBase
    of hdCrewSelf: HdSelfSpriteBase
    of hdCrewSelected: HdSelectedSpriteBase
  base + (colorIndex and 0x0f) * HdCrewRotations + rot

proc hdFloorTiles*(): seq[tuple[x, y: int]] =
  ## Map-px top-left corners for the tiled floor cover.
  var y = 0
  while y < MapHeight:
    var x = 0
    while x < MapWidth:
      result.add((x, y))
      x += HdFloorTileMapPx
    y += HdFloorTileMapPx
