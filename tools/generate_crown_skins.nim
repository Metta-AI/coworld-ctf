## Generates the crown skin masters from the canonical team soldier art.
##
## Run from the repository root:
##   nim r tools/generate_crown_skins.nim

import pixie

const SoldierSkins = [
  ("data/soldier_red.png", "data/soldier_red_crown.png"),
  ("data/soldier_blue.png", "data/soldier_blue_crown.png")
]

proc addCrown(master: Image): Image =
  ## Composites a compact outlined gold crown over the cog's helmet.
  result = newImage(master.width, master.height)
  result.draw(master)

  let
    gold = color(232 / 255, 197 / 255, 71 / 255, 1)
    outline = color(88 / 255, 63 / 255, 28 / 255, 1)
  var crown = newPath()
  crown.moveTo(40, 29)
  crown.lineTo(38, 11)
  crown.lineTo(51, 20)
  crown.lineTo(58, 4)
  crown.lineTo(65, 19)
  crown.lineTo(73, 4)
  crown.lineTo(80, 20)
  crown.lineTo(92, 11)
  crown.lineTo(89, 29)
  crown.closePath()
  result.fillPath(crown, gold)
  result.strokePath(crown, outline, strokeWidth = 4)

  var band = newPath()
  band.moveTo(41, 24)
  band.lineTo(90, 24)
  result.strokePath(band, outline, strokeWidth = 3)

when isMainModule:
  for (sourcePath, outputPath) in SoldierSkins:
    let master = readImage(sourcePath)
    master.addCrown().writeFile(outputPath)
    echo "wrote ", outputPath
