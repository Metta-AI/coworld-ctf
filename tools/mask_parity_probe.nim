## Bake-vs-spec COLLISION MASK parity probe.
##
## The engine collides against masks that come out of the ART BAKE
## (sim.nim: `loadMapLayers(...)` -> walkMask/wallMask), while
## validateGeneratedMap and the map-fitness harness certify geometry from the
## SPEC rasterizer (rasterizeRestWallMask). If those two ever disagree, the
## engine collides against walls the validator never approved and both suites
## stay green. Nothing in the repo compared them, so this measures the delta
## instead of assuming it is zero.
##
## The right comparand is includeSpinning = false: the bake deliberately
## leaves the rotating centre diamonds out of the static masks because
## applyDiamondGeometry stamps their live rotation per frame.
##
## Usage: nim c -r -d:release tools/mask_parity_probe.nim [mapPath ...]
import std/[os, strformat], pixie, ../src/ctf/sim

proc probe(mapPath: string) =
  let
    gameMap = loadCtfMap(mapPath)      # installs, so the Arena globals answer
    w = gameMap.width
    h = gameMap.height
    cx = gameMap.center.x
    cy = gameMap.center.y
    layers = loadMapLayers(gameMap)
    protectedAt = proc (x, y: int): bool = isProtectedFloor(x, y, cx, cy)
    spec = rasterizeRestWallMask(gameMap, ArenaObstacles, protectedAt,
      includeSpinning = false)
  var
    wallOnlyInBake = 0
    wallOnlyInSpec = 0
    diffAtDiamond = 0
    diffAtWindow = 0
    diffOnBorder = 0
    walkDisagree = 0
    firstDiff = (-1, -1)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let
        i = y * w + x
        baked = layers.wallImage[x, y].a > 0
        walkable = layers.walkImage[x, y].a > 0
      # walk and wall must stay exact complements of one another.
      if walkable == baked:
        inc walkDisagree
      if baked == spec[i]:
        continue
      if firstDiff[0] < 0:
        firstDiff = (x, y)
      if baked: inc wallOnlyInBake else: inc wallOnlyInSpec
      if isAnimatedDiamondPixel(x, y): inc diffAtDiamond
      if isArenaWindowPixel(x, y, cx, cy): inc diffAtWindow
      if x < ArenaBorder or y < ArenaBorder or
          x >= w - ArenaBorder or y >= h - ArenaBorder:
        inc diffOnBorder
  let total = wallOnlyInBake + wallOnlyInSpec
  echo &"{mapPath:16s} {w}x{h} diff={total} " &
    &"(bakeOnly={wallOnlyInBake} specOnly={wallOnlyInSpec}) " &
    &"atDiamond={diffAtDiamond} atWindow={diffAtWindow} " &
    &"onBorder={diffOnBorder} walkWallNotComplement={walkDisagree}" &
    (if total > 0: &" first={firstDiff}" else: "")

when isMainModule:
  var paths: seq[string]
  for i in 1 .. paramCount():
    paths.add paramStr(i)
  if paths.len == 0:
    paths = @["arena", "arena-large"]
    for seed in [1001, 1003, 1007, 2024, 4242]:
      paths.add "gen:" & $seed
  for path in paths:
    probe(path)
