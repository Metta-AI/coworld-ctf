## Measures the team-fairness residue: pixels whose SYMMETRY IMAGE disagrees
## with them under the map's own symmetry. Every pixel, no stride, every
## size class (drawable AND colossal), both team counts, every endzone
## archetype — plus the two HAND-AUTHORED boards, which ship as fixtures and
## are what every recorded replay is actually played on.
##
## The stride matters: the regression test that let the GV40 defects ship
## sampled every 9th pixel, and the seams are 1 px wide, so it read 0 on a
## board that was 19% asymmetric along the seam columns.
##
## Reports three surfaces, because they fail independently:
##   protected — `mapProtectedFloorAt`, the always-walkable carve
##   wall      — `mapWallAt`, the carve subtracted from the obstacle union
##   trench    — the dug-pit set, as rectangles
##
## Counts are reported WITH their fraction of the swept area, because a raw
## count is unreadable across classes that differ 25x in area: 522 px is
## 0.06% of a standard board and would be 0.002% of a colossal one.
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

proc frac(bad, area: int): string =
  ## A count is meaningless without the area it was swept over.
  if bad == 0: "0.0000%"
  else: &"{100.0 * float(bad) / float(area):.4f}%"

proc report(label: string, m: CtfMap) =
  let
    area = m.width * m.height
    (p, w) = m.surfaces()
    t = m.trenchAsym()
  echo &"{label:<34} {m.width}x{m.height:<5} {area:>10} " &
    &"{p:>6} {frac(p, area):>9} {w:>6} {frac(w, area):>9} {t:>6}"

## Every size class, not just the drawable ones: `colossal` is even-sided at
## 4992 and was one of the classes Bug B hit.
const AllSizeNames = block:
  var s: seq[string]
  for c in MapSizeClass: s.add MapSizeClassTable[c].name
  s

echo "GENERATED BOARDS — asymmetric px under the map's own symmetry"
echo "every pixel swept, no stride"
echo ""
echo &"{\"class/teams/sym/endzone\":<34} {\"board\":<11} {\"swept\":>10} " &
  &"{\"prot\":>6} {\"prot%\":>9} {\"wall\":>6} {\"wall%\":>9} {\"trench\":>6}"
for sizeName in AllSizeNames:
  for teams in [2, 4]:
    let syms = if teams == 4: @["rot90"] else: @["mirror", "rot180"]
    for s in syms:
      ## Compact endzones are 2-team-only (arena.validateMap). `colossal` is
      ## 27x the area of a standard board, so it sweeps the SHIPPING endzone
      ## only — the archetype sweep's job is to prove the three carve shapes
      ## agree with the symmetry, which is a property of the shape, not of
      ## the scale, and the drawable classes already span both parities.
      let zones =
        if teams == 4: @[""]
        elif sizeName == "colossal": @[""]
        else: @["", "disc", "square"]
      for ez in zones:
        let m = generateMapAttempt(5, MapGenOverrides(
          size: sizeName, symmetry: s, windows: 0, pits: 0, pitDensity: -1,
          endzone: ez), teams)
        report(&"{sizeName} {teams}t {s} " &
          (if ez.len == 0: "column" else: ez), m)

echo ""
echo "ODD-PIT CENTRE TRENCH (mapPits locked odd -> one unpaired, self-symmetric pit)"
echo &"{\"class/sym\":<34} {\"board\":<11} {\"swept\":>10} " &
  &"{\"prot\":>6} {\"prot%\":>9} {\"wall\":>6} {\"wall%\":>9} {\"trench\":>6}"
for sizeName in AllSizeNames:
  for s in ["mirror", "rot180"]:
    let m = generateMapAttempt(5, MapGenOverrides(
      size: sizeName, symmetry: s, windows: 0, pits: 5, pitDensity: -1))
    report(&"{sizeName} 2t {s} pits:5", m)

echo ""
echo "HAND-AUTHORED BOARDS (what the recorded fixtures actually play on)"
echo &"{\"map\":<34} {\"board\":<11} {\"swept\":>10} " &
  &"{\"prot\":>6} {\"prot%\":>9} {\"wall\":>6} {\"wall%\":>9} {\"trench\":>6}"
for name in ["arena", "arena-large"]:
  report(name, loadCtfMapMetadata(name))
