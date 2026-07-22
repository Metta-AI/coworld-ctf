## Dumps the REAL soldierBasePixels + soldierTurretPixels (what the game draws)
## side by side at the south-facing rest angle, so the neck cut can be judged on
## the actual render, not a mock. Throwaway. Writes /tmp/real_halves.png.
import
  pixie,
  ../src/ctf/sim

proc toImg(px: seq[uint8], size: int): Image =
  result = newImage(size, size)
  for i in 0 ..< size * size:
    result.data[i] = rgba(px[i*4], px[i*4+1], px[i*4+2], px[i*4+3]).rgbx()

when isMainModule:
  const S = 3                       # renderScale for detail
  let
    canvas = SoldierCanvas * S
    team = Blue
    rot = soldierRotIndex(192)      # aim SOUTH = master as drawn (face down)
  let
    base = toImg(soldierBasePixels(team, rot, S), canvas)
    turret = toImg(soldierTurretPixels(team, rot, S), canvas)
  var sheet = newImage(canvas * 2 + 30, canvas)
  for i in 0 ..< sheet.width * sheet.height:
    sheet.data[i] = rgba(60, 60, 66, 255).rgbx()
  sheet.draw(turret, translate(vec2(0, 0)))
  sheet.draw(base, translate(vec2(float32(canvas + 30), 0)))
  sheet.writeFile("/tmp/real_halves.png")
  echo "left=TURRET  right=BASE  (real render, cut row ", SoldierTurretCutRow, ")"
