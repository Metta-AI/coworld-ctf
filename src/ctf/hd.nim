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
  UiScale* = 3                 ## HD px per legacy UI px on HD UI layers.
  HdUiLayerFlag* = 16          ## client hint: UI content authored at UiScale.
  UiTextLine* = TextLineHeight * UiScale  ## 21: one HD UI text line height.
  HdCrewSize* = 96             ## HD player sprite canvas (32 map px).
  HdCrewBodyPx = 50            ## the soldier body's target size on the canvas.
  HdCrewRotations* = 16        ## pre-rotated aim steps (16 brads apart).
  HdFlagSize* = 60             ## heart art canvas (20 map px).
  HdPedestalSize* = 60         ## pedestal pad art canvas (20 map px).
  HdFloorTileMapPx* = 96       ## one floor tile covers 96x96 map px (a
                               ## 288px sprite: small enough to keep the
                               ## init snapshot under hosted frame limits).
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
  HdCorpseSpriteBase* = 35500
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
    hdCrewCorpse

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

proc hdTintTiles*(team: Team): seq[tuple[x, y, w, h: int]] =
  ## Map-px rects exactly partitioning one team's half for the territory
  ## wash. Tiled (like the floor) because one half-map uniform sprite costs
  ## ~700KB of snappy copies on the wire; the tiles dedupe to a few KB.
  let
    x0 = if team == Red: 0 else: MapWidth div 2
    x1 = if team == Red: MapWidth div 2 else: MapWidth
  var y = 0
  while y < MapHeight:
    let h = min(HdFloorTileMapPx, MapHeight - y)
    var x = x0
    while x < x1:
      let w = min(HdFloorTileMapPx, x1 - x)
      result.add((x, y, w, h))
      x += w
    y += h

proc hdTintTilePixels*(team: Team, width, height: int): seq[uint8] =
  ## One uniform translucent wash tile at HD scale (map-px dimensions in).
  let tint = if team == Red: ArenaRedWash else: ArenaBlueWash
  result = newSeq[uint8](width * RenderScale * height * RenderScale * 4)
  for i in 0 ..< width * RenderScale * height * RenderScale:
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
  ## Four border wall TILE sprites with a darkened inner edge: one repeating
  ## tile per side instead of full-length slabs (a full-width textured slab
  ## costs ~150KB on the wire; a tile is a few KB and repeats seamlessly
  ## because its texture is world-anchored and wall.png tiles).
  let
    b = ArenaBorder * RenderScale
    run = HdFloorTileMapPx * RenderScale
  proc slabTile(
    width, height, edgeSide, texOffX, texOffY: int
  ): seq[uint8] =
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
        result.putWallPixel(
          py * width + px, wallTexel(texOffX + px, texOffY + py), edge
        )
  hdBorderSprites[0] = (0, 0, run, b, slabTile(run, b, 0, 0, 0))
  hdBorderSprites[1] = (0, MapHeight - ArenaBorder, run, b,
    slabTile(run, b, 1, 0, (MapHeight - ArenaBorder) * RenderScale))
  hdBorderSprites[2] = (0, 0, b, run, slabTile(b, run, 2, 0, 0))
  hdBorderSprites[3] = (MapWidth - ArenaBorder, 0, b, run,
    slabTile(b, run, 3, (MapWidth - ArenaBorder) * RenderScale, 0))

proc hdBorderTiles*(): seq[tuple[side, x, y: int]] =
  ## Map-px placements for the repeating border tiles: full top and bottom
  ## rows plus full left and right columns. Corner overlaps repeat identical
  ## world-anchored texture, so draw order there does not matter.
  var x = 0
  while x < MapWidth:
    result.add((0, x, 0))
    result.add((1, x, MapHeight - ArenaBorder))
    x += HdFloorTileMapPx
  var y = 0
  while y < MapHeight:
    result.add((2, 0, y))
    result.add((3, MapWidth - ArenaBorder, y))
    y += HdFloorTileMapPx

proc hdEnsureLoaded*(gameMap: CtfMap) =
  ## Loads and rasterizes every HD asset once per process.
  if hdLoaded:
    return
  hdCrewMaster = readHdImage("crew_red.png")
  hdCrewMaster.measureCrewBody()
  hdFloorImage = readHdImage("floor.png").resize(HdFloorTilePx, HdFloorTilePx)
  hdWallImage = readHdImage("wall.png")
  hdFlagPixels[Red] = buildFlagPixels(readHdImage("heart_red.png"))
  hdFlagPixels[Blue] = buildFlagPixels(readHdImage("heart_blue.png"))
  hdPedestalPixels[Red] = buildPedestalPixels(readHdImage("pedestal_red.png"))
  hdPedestalPixels[Blue] = buildPedestalPixels(readHdImage("pedestal_blue.png"))
  hdFloorPixels = hdFloorImage.toStraightRgba()
  buildWallPieces(gameMap.center)
  buildBorderSlabs()
  hdLoaded = true

proc hdFlagSpritePixels*(team: Team): seq[uint8] =
  hdFlagPixels[team]

proc hdPedestalSpritePixels*(team: Team): seq[uint8] =
  hdPedestalPixels[team]

proc hdFloorSpritePixels*(): seq[uint8] =
  hdFloorPixels

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
  of hdCrewNormal, hdCrewCorpse:
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
  if kind == hdCrewCorpse:
    # A corpse must never read as a live soldier: desaturate to grey,
    # darken, and go translucent so the floor shows through.
    for i in 0 ..< HdCrewSize * HdCrewSize:
      if pixels[i * 4 + 3] == 0:
        continue
      let grey = uint8((
        int(pixels[i * 4]) + int(pixels[i * 4 + 1]) + int(pixels[i * 4 + 2])
      ) div 3 * 55 div 100)
      pixels[i * 4] = grey
      pixels[i * 4 + 1] = grey
      pixels[i * 4 + 2] = grey
      pixels[i * 4 + 3] = uint8(int(pixels[i * 4 + 3]) * 60 div 100)
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
    of hdCrewCorpse: HdCorpseSpriteBase
  base + (colorIndex and 0x0f) * HdCrewRotations + rot

var
  hdUiFont: Font
  hdUiFontRatio: float32
  hdTextCache: Table[
    (string, int, uint32, bool),
    tuple[width, height: int, pixels: seq[uint8]]
  ]
  hdCrewIconCache: Table[(int, int), seq[uint8]]

proc hdFont(): Font =
  ## The shared UI font, loaded once; hdUiFontRatio converts a wanted line
  ## height into the font size that produces it.
  if hdUiFont == nil:
    hdUiFont = readFont(hdDataDir() / "font.ttf")
    hdUiFont.size = 100
    hdUiFontRatio = 100.0'f32 / hdUiFont.defaultLineHeight
  hdUiFont

proc hdColorKey(color: ColorRGBA): uint32 =
  uint32(color.r) or (uint32(color.g) shl 8) or
    (uint32(color.b) shl 16) or (uint32(color.a) shl 24)

proc hdTextWidth*(text: string, linePx = UiTextLine): int =
  ## Pixel width of one line of HD UI text.
  let font = hdFont()
  font.size = float32(linePx) * hdUiFontRatio
  max(1, int(ceil(font.layoutBounds(text).x)))

proc hdTextLine*(
  text: string,
  color: ColorRGBA,
  linePx = UiTextLine,
  struck = false
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Rasterizes one line of HD UI text; the sprite is exactly linePx tall.
  let key = (text, linePx, hdColorKey(color), struck)
  if key in hdTextCache:
    return hdTextCache[key]
  let font = hdFont()
  font.size = float32(linePx) * hdUiFontRatio
  var paint = newPaint(SolidPaint)
  paint.color = color.color()
  font.paint = paint
  let width = max(1, int(ceil(font.layoutBounds(text).x)))
  var image = newImage(width, linePx)
  image.fillText(font, text)
  var pixels = image.toStraightRgba()
  if struck:
    for y in [linePx div 2 - 1, linePx div 2]:
      for x in 0 ..< width:
        let i = (y * width + x) * 4
        pixels[i] = color.r
        pixels[i + 1] = color.g
        pixels[i + 2] = color.b
        pixels[i + 3] = 255
  result = (width, linePx, pixels)
  if hdTextCache.len > 1024:
    hdTextCache.clear()
  hdTextCache[key] = result

proc hdResizeRgba*(
  pixels: seq[uint8],
  width, height, outWidth, outHeight: int
): seq[uint8] =
  ## Smoothly resizes straight RGBA pixels.
  var image = newImage(width, height)
  for i in 0 ..< width * height:
    image.data[i] = rgba(
      pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2], pixels[i * 4 + 3]
    ).rgbx()
  image.resize(outWidth, outHeight).toStraightRgba()

proc hdCrewIconPixels*(colorIndex, sizePx: int): seq[uint8] =
  ## A right-facing crew body resized for HD UI panels.
  let key = (colorIndex, sizePx)
  if key in hdCrewIconCache:
    return hdCrewIconCache[key]
  result = hdResizeRgba(
    hdCrewSpritePixels(colorIndex, 0, hdCrewNormal),
    HdCrewSize,
    HdCrewSize,
    sizePx,
    sizePx
  )
  hdCrewIconCache[key] = result

proc hdTransportIcon*(
  kind: char,
  sizePx: int,
  color: ColorRGBA
): seq[uint8] =
  ## Draws one replay transport icon as crisp vector shapes:
  ## '<' restart, 'b' step back, 'p' play, 'P' pause, 'e' to end, 'r' loop.
  var image = newImage(sizePx, sizePx)
  let
    s = float32(sizePx)
    paint = newPaint(SolidPaint)
  paint.color = color.color()
  var path = newPath()
  case kind
  of '<':
    path.rect(0.10 * s, 0.15 * s, 0.12 * s, 0.70 * s)
    path.moveTo(0.90 * s, 0.15 * s)
    path.lineTo(0.90 * s, 0.85 * s)
    path.lineTo(0.30 * s, 0.50 * s)
    path.closePath()
  of 'b':
    path.moveTo(0.75 * s, 0.15 * s)
    path.lineTo(0.75 * s, 0.85 * s)
    path.lineTo(0.20 * s, 0.50 * s)
    path.closePath()
  of 'p':
    path.moveTo(0.20 * s, 0.10 * s)
    path.lineTo(0.90 * s, 0.50 * s)
    path.lineTo(0.20 * s, 0.90 * s)
    path.closePath()
  of 'P':
    path.rect(0.20 * s, 0.12 * s, 0.20 * s, 0.76 * s)
    path.rect(0.60 * s, 0.12 * s, 0.20 * s, 0.76 * s)
  of 'e':
    path.moveTo(0.10 * s, 0.15 * s)
    path.lineTo(0.70 * s, 0.50 * s)
    path.lineTo(0.10 * s, 0.85 * s)
    path.closePath()
    path.rect(0.78 * s, 0.15 * s, 0.12 * s, 0.70 * s)
  of 'r':
    # A loop ring with a gap plus an arrow head at the gap.
    var ring = newPath()
    ring.arc(0.5 * s, 0.5 * s, 0.32 * s, 0.30'f32, 5.30'f32, false)
    image.strokePath(ring, paint, strokeWidth = 0.12 * s)
    path.moveTo(0.86 * s, 0.28 * s)
    path.lineTo(0.98 * s, 0.56 * s)
    path.lineTo(0.68 * s, 0.52 * s)
    path.closePath()
  else:
    discard
  image.fillPath(path, paint)
  image.toStraightRgba()

var
  hdGrenadeCache: Table[int, seq[uint8]]
  hdBlastCache: Table[int, seq[uint8]]

proc hdGrenadePixels*(sizePx: int): seq[uint8] =
  ## An olive-drab grenade: body sphere, darker safety band, top cap, and a
  ## small highlight. Drawn procedurally so every size stays crisp.
  if sizePx in hdGrenadeCache:
    return hdGrenadeCache[sizePx]
  var image = newImage(sizePx, sizePx)
  let
    s = float32(sizePx)
    body = newPaint(SolidPaint)
    band = newPaint(SolidPaint)
    cap = newPaint(SolidPaint)
    glint = newPaint(SolidPaint)
  body.color = color(0.28, 0.36, 0.16, 1.0)
  band.color = color(0.18, 0.24, 0.10, 1.0)
  cap.color = color(0.55, 0.55, 0.58, 1.0)
  glint.color = color(0.85, 0.90, 0.75, 0.9)
  var path = newPath()
  path.circle(0.5 * s, 0.56 * s, 0.34 * s)
  image.fillPath(path, body)
  path = newPath()
  path.rect(0.16 * s, 0.48 * s, 0.68 * s, 0.14 * s)
  var clip = newPath()
  clip.circle(0.5 * s, 0.56 * s, 0.34 * s)
  var bandImage = newImage(sizePx, sizePx)
  bandImage.fillPath(path, band)
  var mask = newImage(sizePx, sizePx)
  mask.fillPath(clip, band)
  for i in 0 ..< sizePx * sizePx:
    if mask.data[i].a == 0:
      bandImage.data[i] = rgbx(0, 0, 0, 0)
  image.draw(bandImage)
  path = newPath()
  path.rect(0.40 * s, 0.10 * s, 0.20 * s, 0.16 * s)
  image.fillPath(path, cap)
  path = newPath()
  path.circle(0.38 * s, 0.44 * s, 0.07 * s)
  image.fillPath(path, glint)
  result = image.toStraightRgba()
  hdGrenadeCache[sizePx] = result

proc hdBlastPixels*(stage, stages, radiusPx: int): seq[uint8] =
  ## One expanding blast-flash frame: a hot core that fades while a shock
  ## ring grows to the full blast radius.
  let key = stage * 10000 + radiusPx
  if key in hdBlastCache:
    return hdBlastCache[key]
  let size = radiusPx * 2
  var image = newImage(size, size)
  let
    t = float32(stage) / float32(max(1, stages - 1))
    c = float32(radiusPx)
    ring = newPaint(SolidPaint)
    core = newPaint(SolidPaint)
  ring.color = color(1.0, 0.62 - 0.3 * t, 0.25 - 0.2 * t, 0.85 - 0.55 * t)
  core.color = color(1.0, 0.92, 0.60, 0.9 - 0.8 * t)
  var path = newPath()
  path.circle(c, c, c * (0.45 + 0.55 * t) - 2.0)
  image.strokePath(path, ring, strokeWidth = 6.0 - 3.0 * t)
  path = newPath()
  path.circle(c, c, c * 0.35 * (1.0 - t) + 2.0)
  image.fillPath(path, core)
  result = image.toStraightRgba()
  hdBlastCache[key] = result

proc hdCrosshairPixels*(sizePx: int, dim: bool): seq[uint8] =
  ## The fire-readiness HUD icon: a crosshair ring, bright when ready and
  ## dark translucent while the gun cools down.
  var image = newImage(sizePx, sizePx)
  let
    s = float32(sizePx)
    paint = newPaint(SolidPaint)
  paint.color =
    if dim: color(0.2, 0.2, 0.25, 0.55) else: color(0.95, 0.95, 0.98, 0.95)
  var ring = newPath()
  ring.circle(0.5 * s, 0.5 * s, 0.32 * s)
  image.strokePath(ring, paint, strokeWidth = 0.09 * s)
  var path = newPath()
  path.rect(0.47 * s, 0.04 * s, 0.06 * s, 0.22 * s)
  path.rect(0.47 * s, 0.74 * s, 0.06 * s, 0.22 * s)
  path.rect(0.04 * s, 0.47 * s, 0.22 * s, 0.06 * s)
  path.rect(0.74 * s, 0.47 * s, 0.22 * s, 0.06 * s)
  path.circle(0.5 * s, 0.5 * s, 0.05 * s)
  image.fillPath(path, paint)
  image.toStraightRgba()

proc hdFloorTiles*(): seq[tuple[x, y: int]] =
  ## Map-px top-left corners for the tiled floor cover.
  var y = 0
  while y < MapHeight:
    var x = 0
    while x < MapWidth:
      result.add((x, y))
      x += HdFloorTileMapPx
    y += HdFloorTileMapPx
