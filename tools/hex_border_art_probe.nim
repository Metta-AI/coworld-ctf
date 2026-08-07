## Why the spectator board's RECTANGULAR border stamp is safe on a hexagon.
##
## `map_art.nim`'s design thesis (:186-200, :713-721) is that the art is derived
## from the collision mask, so the two cannot disagree. `loadMapLayers` honours
## it literally: its mask comes from `rasterizeRestWallMask`, which stamps the
## border via `mapBorderWallAt` — THE boundary rule, `hexEdgeDist < ArenaBorder`.
##
## `renderArenaRgbaPair` does NOT. It stamps the border ring as a RECTANGLE
## (four bands off the bounding box), which is exactly right for a rectangular
## arena and, on a hexagon, misses four of six edges: a hexagon meets its
## bounding box only along the flat top and bottom. This probe was written
## expecting that to be a visible bug. IT IS NOT, and the reason is worth
## keeping:
##
##   `ArenaBorderColor` is OPAQUE (alpha 255), and `overTint` at alpha 255
##   returns the tint verbatim. Every pixel of the ring paints solid (44,34,25)
##   whichever material is underneath, so the mask divergence cannot reach the
##   output. Outside the hull the paint loop short-circuits to transparent
##   before consulting the mask at all. The only pixels that CAN differ are wall
##   pixels within a parapet width of a diagonal hull edge — and the 10px ring
##   holds obstacles far enough off that, measured across six maps, the entire
##   difference is 0-6 pixels at a max channel delta of 4/255.
##
## So the divergence is real in the MASK and provably absent from the IMAGE.
## Deriving the stamp from `hexEdgeDistF` instead (the "correct" fix) was
## measured at +23% on `renderArenaRgbaPair`, which runs on the certifier's boot
## clock, in exchange for those 6 pixels. It was reverted.
##
## THIS PROBE IS THE GUARD ON THAT REASONING. It reports the mask divergence,
## and it FAILS if the property that makes the divergence harmless — an opaque
## border tint — ever stops holding. Make `ArenaBorderColor` translucent and
## four of the hull's six edges start showing floor through the ring; this is
## what tells you.
##
## Usage:
##   nim c -d:release -o:/tmp/hexborder tools/hex_border_art_probe.nim
##   /tmp/hexborder [arena|arena-large|gen:<seed>|pool:<n>] [--scale N]
##
## Audit tooling; not part of the server.
import
  std/[math, os, strutils],
  pixie,
  ../src/ctf/sim

when isMainModule:
  var
    positional: seq[string]
    scale = 2
  var i = 1
  while i <= paramCount():
    let arg = paramStr(i)
    case arg
    of "--scale": inc i; scale = parseInt(paramStr(i))
    else: positional.add(arg)
    inc i
  let mapPath = if positional.len > 0: positional[0] else: "arena"
  let gameMap = loadCtfMap(mapPath)
  let
    w = gameMap.width
    h = gameMap.height
    ow = w * scale
    oh = h * scale
    board = gameMap.mapBoard()
  echo "map ", gameMap.name, " ", w, "x", h, "  scale=", scale,
    "  ArenaBorder=", ArenaBorder

  # The rectangular stamp renderArenaRgbaPair uses, verbatim.
  let
    bTop = ArenaBorder * scale
    bBottom = (h - ArenaBorder) * scale
    bLeft = ArenaBorder * scale
    bRight = (w - ArenaBorder) * scale

  # Name each disagreement by which of the six edges it sits on. The hull is
  # landscape: vertices at 0/60/120/180/240/300 degrees, so the six EDGE normals
  # point at 30/90/150/210/270/330 — the flat top and bottom, and four
  # diagonals. Bucketing the bearing by floor(a / 60) therefore centres bucket k
  # on the edge whose normal is 60k + 30 degrees.
  const EdgeName = ["NE diagonal", "N (flat top)", "NW diagonal",
                    "SW diagonal", "S (flat bottom)", "SE diagonal"]
  var
    perEdgeMissing: array[6, int]   # collision says WALL, art stamped floor
    ringTotal: array[6, int]
    missing = 0
    extra = 0
    ringPixels = 0
  let
    ccx = float(ow) / 2.0
    ccy = float(oh) / 2.0

  template bucketOf(px, py: int): int =
    var a = arctan2(-(float(py) + 0.5 - ccy), float(px) + 0.5 - ccx)
    if a < 0: a += 2.0 * PI
    int(floor(a / (PI / 3.0))) mod 6

  for y in 0 ..< oh:
    let fy = (float(y) + 0.5) / float(scale)
    for x in 0 ..< ow:
      let edge = board.hexEdgeDistF((float(x) + 0.5) / float(scale), fy)
      if edge <= 0.0:
        continue                      # void: painted transparent, never shaded
      if edge < float(ArenaBorder):
        inc ringPixels
        inc ringTotal[bucketOf(x, y)]
      # THE boundary rule vs the rectangle actually stamped.
      let
        collisionWall = edge < float(ArenaBorder)
        rectWall = y < bTop or y >= bBottom or x < bLeft or x >= bRight
      if collisionWall == rectWall:
        continue
      if collisionWall:
        inc missing
        inc perEdgeMissing[bucketOf(x, y)]
      else:
        inc extra

  echo ""
  echo "border ring (hexEdgeDist in (0, ArenaBorder)): ", ringPixels, " px"
  echo "art mask diverges from the collision boundary on ", missing + extra,
    " px  (", formatFloat(
      100.0 * float(missing + extra) / float(max(1, ringPixels)),
      ffDecimal, 1), "% of the ring)"
  echo "  collision WALL, art stamped FLOOR: ", missing
  echo "  art stamped WALL, collision FLOOR: ", extra
  echo ""
  echo "per hull edge:"
  for e in 0 ..< 6:
    echo "  ", align(EdgeName[e], 16), "  ring=", align($ringTotal[e], 7),
      "  unstamped=", align($perEdgeMissing[e], 7),
      "  (", formatFloat(
        100.0 * float(perEdgeMissing[e]) / float(max(1, ringTotal[e])),
        ffDecimal, 1), "%)"

  # ---- THE GUARD -----------------------------------------------------------
  # The divergence above is invisible for exactly one reason. Assert it.
  echo ""
  echo "ArenaBorderColor = rgba(", ArenaBorderColor.r, ",",
    ArenaBorderColor.g, ",", ArenaBorderColor.b, ",", ArenaBorderColor.a, ")"
  var failed = false
  if ArenaBorderColor.a != 255:
    failed = true
    echo "FAIL: the border tint is translucent, so the material UNDER the ring"
    echo "      now shows through — and on four of the hull's six edges that"
    echo "      material is FLOOR, not roof. renderArenaRgbaPair's border stamp"
    echo "      must derive from hexEdgeDistF before this can ship."
  else:
    echo "ok: opaque, so the ring paints solid whatever the mask says under it."

  # Belt and braces: the ring really is solid tint in the finished image.
  let pair = renderArenaRgbaPair(gameMap, scale)
  var ringOff = 0
  for y in 0 ..< oh:
    let fy = (float(y) + 0.5) / float(scale)
    for x in 0 ..< ow:
      let edge = board.hexEdgeDistF((float(x) + 0.5) / float(scale), fy)
      if edge <= 0.0 or edge >= float(ArenaBorder):
        continue
      let o = (y * ow + x) * 4
      if pair.hot[o] != ArenaBorderColor.r or
         pair.hot[o + 1] != ArenaBorderColor.g or
         pair.hot[o + 2] != ArenaBorderColor.b:
        inc ringOff
  echo "ring pixels in the baked image that are NOT the solid tint: ", ringOff
  if ringOff != 0:
    failed = true
    echo "FAIL: something now paints over the ring, so the mask divergence can"
    echo "      reach the image. Re-measure before trusting the rectangle."

  echo ""
  if failed:
    quit("FAIL", 1)
  echo "PASS: the rectangular border stamp cannot reach the spectator image."
