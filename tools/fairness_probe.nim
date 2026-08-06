## Measures the team-fairness residue: pixels whose SYMMETRY IMAGE disagrees
## with them under the map's own symmetry. Every pixel, no stride, every
## drawable size class, both team counts, every endzone archetype.
##
## Reports three surfaces, because they fail independently:
##   protected — `mapProtectedFloorAt`, the always-walkable carve
##   wall      — `mapWallAt`, the carve subtracted from the obstacle union
##   trench    — the dug-pit set, as rectangles
import std/[strformat, strutils]
import ../src/ctf/[sim, map_rules]

proc imageOf(m: CtfMap, x, y: int): (int, int) =
  ## One step of the map's symmetry group generates the whole orbit.
  case m.symmetry
  of symMirror: (m.width - 1 - x, y)
  of symRot180: (m.width - 1 - x, m.height - 1 - y)
  of symRot90: (m.width - 1 - y, x)

proc surfaces(m: CtfMap): tuple[protectedPx, wallPx: int] =
  let obstacles = buildArenaObstacles(m)
  for y in 0 ..< m.height:
    for x in 0 ..< m.width:
      let (ix, iy) = m.imageOf(x, y)
      if mapProtectedFloorAt(m, x, y) != mapProtectedFloorAt(m, ix, iy):
        inc result.protectedPx
      if mapWallAt(m, obstacles, x, y) != mapWallAt(m, obstacles, ix, iy):
        inc result.wallPx

proc trenchAsym(m: CtfMap): int =
  ## Trench pixels with no trench on their image. Trenches are a small rect
  ## set, so this paints them rather than sweeping the board.
  if m.trenches.len == 0: return 0
  var mask = newSeq[bool](m.width * m.height)
  for t in m.trenches:
    let (x0, y0, x1, y1) = shapeBounds(t)
    for yy in max(0, y0) .. min(m.height - 1, y1):
      for xx in max(0, x0) .. min(m.width - 1, x1):
        if inShape(xx, yy, t): mask[yy * m.width + xx] = true
  for y in 0 ..< m.height:
    for x in 0 ..< m.width:
      if not mask[y * m.width + x]: continue
      let (ix, iy) = m.imageOf(x, y)
      if not mask[iy * m.width + ix]: inc result

echo "class    tm sym    endzone  board       protected   wall  trench"
for sizeName in DrawableSizeNames:
  for teams in [2, 4]:
    let syms = if teams == 4: @["rot90"] else: @["mirror", "rot180"]
    for s in syms:
      ## Compact endzones are 2-team-only (arena.validateMap).
      let zones = if teams == 4: @[""] else: @["", "disc", "square"]
      for ez in zones:
        let m = generateMapAttempt(5, MapGenOverrides(
          size: sizeName, symmetry: s, windows: 0, pits: 0, pitDensity: -1,
          endzone: ez), teams)
        let (p, w) = m.surfaces()
        echo &"{sizeName:<8} {teams:<2} {s:<6} {(if ez.len == 0: \"column\" else: ez):<8} " &
          &"{m.width}x{m.height:<6} {p:>9} {w:>6} {m.trenches.len:>5}"

echo ""
echo "odd-pit centre trench (mapPits locked odd -> one self-symmetric pit):"
echo "class    sym     board       trench-rects  asym-px"
for sizeName in DrawableSizeNames:
  for s in ["mirror", "rot180"]:
    let m = generateMapAttempt(5, MapGenOverrides(
      size: sizeName, symmetry: s, windows: 0, pits: 5, pitDensity: -1))
    echo &"{sizeName:<8} {s:<7} {m.width}x{m.height:<6} " &
      &"{m.trenches.len:>12} {m.trenchAsym():>8}"
