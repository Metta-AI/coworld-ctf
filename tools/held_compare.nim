## Renders the two held weapons side by side at several aim angles: the paintball
## MARKER vs the SPRAY CAN. The point is the SILHOUETTE difference — a viewer must
## be able to tell which weapon a cog holds at a glance, at every heading.
## Usage (repo root): nim r tools/held_compare.nim [out.png]
import
  std/os,
  pixie,
  ../src/ctf/sim

proc pixelsToImage(px: seq[uint8], size: int): Image =
  result = newImage(size, size)
  for y in 0 ..< size:
    for x in 0 ..< size:
      let i = (y * size + x) * 4
      result[x, y] = rgba(px[i], px[i + 1], px[i + 2], px[i + 3])

proc main() =
  setCurrentDir(currentSourcePath().parentDir().parentDir())
  let
    outPath = if paramCount() >= 1: paramStr(1) else: "/tmp/held_compare.png"
    scale = 2
    size = RigCanvas * scale
    steps = [0, 4, 8, 12]              # east, north, west, south
  var sheet = newImage(size * steps.len, size * 3)
  sheet.fill(rgba(58, 52, 46, 255))
  for col, step in steps:
    # row 0: the cog body rig (no weapon) for reference
    let head = pixelsToImage(rigSegPixels(Red, rsHead, step, 0, 0, scale), size)
    sheet.draw(head, translate(vec2(float32(col * size), 0)))
    # row 1: body + held MARKER
    var withGun = newImage(size, size)
    withGun.draw(head)
    withGun.draw(pixelsToImage(rigGunPixels(Red, step, scale), size))
    sheet.draw(withGun, translate(vec2(float32(col * size), float32(size))))
    # row 2: body + held SPRAY CAN
    var withCan = newImage(size, size)
    withCan.draw(head)
    withCan.draw(pixelsToImage(rigSprayCanPixels(Red, step, scale), size))
    sheet.draw(withCan, translate(vec2(float32(col * size), float32(size * 2))))
  sheet.resize(sheet.width * 2, sheet.height * 2).writeFile(outPath)
  echo "wrote ", outPath, "  rows: head / +marker / +spray can; cols: E N W S"

main()
