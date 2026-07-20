## Dumps the CvC cog soldier sprites to a PNG for visual inspection: all 16
## aim rotations for both teams (upright body, swept gun) plus the roster
## icons, composited over the arena floor texture.

import
  pixie,
  ../src/ctf/sim

proc spriteToImage(pixels: seq[uint8], width, height: int): Image =
  result = newImage(width, height)
  for i in 0 ..< width * height:
    result.data[i] = rgba(
      pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2], pixels[i * 4 + 3]
    ).rgbx()

when isMainModule:
  let
    floor = readImage("data/arena_floor.png")
    outPath = "/tmp/soldier_preview.png"
  var canvas = newImage(1600, 420)
  var ty = 0
  while ty < canvas.height:
    var tx = 0
    while tx < canvas.width:
      canvas.draw(floor, translate(vec2(float32(tx), float32(ty))))
      tx += floor.width
    ty += floor.height
  # Aim rotations: red top row, blue second row (rot 0 = east, CCW).
  for team in Team:
    for rot in 0 ..< SoldierRotations:
      let pix = soldierRotPixels(team, rot)
      canvas.draw(
        spriteToImage(pix, SoldierCanvas, SoldierCanvas),
        translate(vec2(float32(20 + rot * 95), float32(30 + ord(team) * 110)))
      )
  # Roster icons at three sizes.
  for team in Team:
    for (i, size) in [(0, 16), (1, 24), (2, 34)]:
      canvas.draw(
        spriteToImage(soldierIconPixels(team, size), size, size),
        translate(vec2(float32(40 + i * 50), float32(280 + ord(team) * 60)))
      )
  canvas.writeFile(outPath)
  echo "wrote ", outPath
