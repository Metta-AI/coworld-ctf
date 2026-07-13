## Dumps generated HD sprites to PNGs for visual inspection:
## crew rotations for both team colors, a wall form, a border slab, the
## flags and pedestals — composited over the floor texture like the client
## would draw them.

import
  std/[os],
  pixie,
  bitworld/spriteprotocol,
  ../src/ctf/[hd, sim]

proc spriteToImage(pixels: seq[uint8], width, height: int): Image =
  result = newImage(width, height)
  for i in 0 ..< width * height:
    result.data[i] = rgba(
      pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2], pixels[i * 4 + 3]
    ).rgbx()

when isMainModule:
  loadPalette("")
  let gameMap = loadCtfMap()
  hdEnsureLoaded(gameMap)

  let
    tile = spriteToImage(hdFloorSpritePixels(), 384, 384)
    outPath = "/tmp/hd_preview.png"
  var canvas = newImage(1600, 900)
  # Floor backdrop.
  for ty in 0 .. 2:
    for tx in 0 .. 4:
      canvas.draw(tile, translate(vec2(float32(tx * 384), float32(ty * 384))))
  # Crew rotations: red (color 0) top row, blue (color 6) second row.
  for rot in 0 ..< HdCrewRotations:
    let redPix = hdCrewSpritePixels(0, rot, hdCrewNormal)
    canvas.draw(
      spriteToImage(redPix, HdCrewSize, HdCrewSize),
      translate(vec2(float32(20 + rot * 90), 30))
    )
    let bluePix = hdCrewSpritePixels(6, rot, hdCrewSelf)
    canvas.draw(
      spriteToImage(bluePix, HdCrewSize, HdCrewSize),
      translate(vec2(float32(20 + rot * 90), 130))
    )
  # Flags and pedestals.
  for team in Team:
    canvas.draw(
      spriteToImage(hdPedestalSpritePixels(team), HdPedestalSize, HdPedestalSize),
      translate(vec2(float32(40 + ord(team) * 160), 260))
    )
    canvas.draw(
      spriteToImage(hdFlagSpritePixels(team), HdFlagSize, HdFlagSize),
      translate(vec2(float32(52 + ord(team) * 160), 240))
    )
  # A few wall pieces.
  var x = 400.0
  var seen: seq[int]
  for piece in hdWallPiecesList():
    if piece.spriteId in seen:
      continue
    seen.add(piece.spriteId)
    let sprite = hdWallSprite(piece.spriteId)
    canvas.draw(
      spriteToImage(sprite.pixels, sprite.width, sprite.height),
      translate(vec2(float32(x), 250))
    )
    x += float(sprite.width + 20)
    if x > 1400:
      break
  # A border slab strip.
  let slab = hdBorderSlab(0)
  canvas.draw(
    spriteToImage(slab.pixels, slab.width, slab.height),
    translate(vec2(20, 560))
  )
  canvas.writeFile(outPath)
  echo "wrote ", outPath
