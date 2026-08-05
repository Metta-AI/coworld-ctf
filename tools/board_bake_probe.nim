## Times and dumps the two BOARD ART bakes for one map — the 1x
## `loadMapLayers` bake (the map players and the collision-resolution layer
## see) and the scale-x `renderArenaRgbaPair` bake (the spectator board
## sprite) — so a change to the wall material can be judged on both paths and
## against the certifier's boot clock. `renderArenaRgbaPair`'s docstring calls
## that clock out: the bake runs at container boot on a small contended CI
## runner and must stay a startup blip.
##
## Usage:
##   nim c -d:release -o:/tmp/bakeprobe tools/board_bake_probe.nim
##   /tmp/bakeprobe <mapPath> <outPrefix> [--scale N] [--size giant] [--crop x,y,w,h]
##
## mapPath: arena | arena-large | gen:<seed> | pool:<index>
## --size:  regenerates gen:<seed> at a locked size class (giant = 2.6x).
## --crop:  also writes <outPrefix>-crop.png, a 1:1 window on the scale-x bake
##          (in scale-x pixels) for pixel-peeping a parapet or a chevron.
## Demo/audit tooling; not part of the server.
import
  std/[monotimes, os, strutils, times],
  pixie,
  ../src/ctf/sim

proc toImage(pixels: seq[uint8], w, h: int): Image =
  ## Packs a straight-alpha RGBA byte buffer (the bake's native format) into a
  ## pixie image for writing.
  result = newImage(w, h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let o = (y * w + x) * 4
      result[x, y] = rgba(pixels[o], pixels[o + 1], pixels[o + 2], 255)

proc ms(a, b: MonoTime): float =
  float((b - a).inNanoseconds) / 1e6

when isMainModule:
  var
    positional: seq[string]
    scale = 2
    sizeName = ""
    crop = ""
  var i = 1
  while i <= paramCount():
    let arg = paramStr(i)
    case arg
    of "--scale": inc i; scale = parseInt(paramStr(i))
    of "--size": inc i; sizeName = paramStr(i)
    of "--crop": inc i; crop = paramStr(i)
    else: positional.add(arg)
    inc i
  if positional.len != 2:
    quit("Usage: board_bake_probe <mapPath> <outPrefix> " &
      "[--scale N] [--size giant] [--crop x,y,w,h]")
  let
    mapPath = positional[0]
    prefix = positional[1]
  var gameMap: CtfMap
  if sizeName.len > 0:
    var config = defaultGameConfig()
    config.mapPath = "gen"
    config.mapSeed = if ':' in mapPath: parseInt(mapPath.split(':')[1]) else: 0
    config.mapGen = MapGenOverrides(
      size: sizeName, windows: -1, pits: -1, pitDensity: -1)
    gameMap = loadCtfMap(config)
  else:
    gameMap = loadCtfMap(mapPath)
  echo "map ", gameMap.name, " ", gameMap.width, "x", gameMap.height,
    " (", gameMap.width * gameMap.height, " px) obstacles=",
    ArenaObstacles.len, " trenches=", ArenaTrenches.len

  let t0 = getMonoTime()
  let layers = loadMapLayers(gameMap)
  let t1 = getMonoTime()
  layers.mapImage.writeFile(prefix & "-1x.png")

  let t2 = getMonoTime()
  let pair = renderArenaRgbaPair(gameMap, scale)
  let t3 = getMonoTime()
  let
    ow = gameMap.width * scale
    oh = gameMap.height * scale
  toImage(pair.hot, ow, oh).writeFile(prefix & "-x" & $scale & ".png")
  if crop.len > 0:
    let f = crop.split(',')
    let
      cx = parseInt(f[0])
      cy = parseInt(f[1])
      cw = parseInt(f[2])
      ch = parseInt(f[3])
    var img = newImage(cw, ch)
    for y in 0 ..< ch:
      for x in 0 ..< cw:
        let o = ((cy + y) * ow + cx + x) * 4
        img[x, y] = rgba(pair.hot[o], pair.hot[o + 1], pair.hot[o + 2], 255)
    img.writeFile(prefix & "-crop.png")

  # The spinning centre diamonds are the third consumer of the wall material:
  # they re-derive the parapet from a ROTATED mask every frame, so their light
  # has to stay put as the shape turns. Dump a strip of the spin cycle.
  block:
    var radii: seq[int]
    for spot in buildAnimatedDiamonds(gameMap, ArenaObstacles):
      if spot.radius notin radii:
        radii.add spot.radius
    for radius in radii:
      let
        size = rotatingDiamondSize(radius) * scale
        frames = 8
      var strip = newImage(size * frames, size)
      for f in 0 ..< frames:
        let (_, px) = rotatingDiamondPixels(radius, f * 2, scale)
        for y in 0 ..< size:
          for x in 0 ..< size:
            let o = (y * size + x) * 4
            strip[f * size + x, y] =
              rgba(px[o], px[o + 1], px[o + 2], px[o + 3])
      strip.writeFile(prefix & "-spin" & $radius & ".png")
      echo "wrote spin strip r=", radius

  echo "loadMapLayers(1x)        ", formatFloat(ms(t0, t1), ffDecimal, 1), " ms"
  echo "renderArenaRgbaPair(x", scale, ")  ",
    formatFloat(ms(t2, t3), ffDecimal, 1), " ms  (", ow, "x", oh, ")"
