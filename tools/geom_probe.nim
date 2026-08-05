## Throwaway probe: dump the real geometry a 2-team standard board hands the
## structure pass, so the scene design is written against measured numbers.
import std/strformat
import ../src/ctf/[sim, map_rules]

let m = generateCtfMap(1001, MapGenOverrides(
  windows: -1, pits: -1, pitDensity: -1, size: "standard",
  symmetry: "mirror", endzone: "column"), 2)

echo &"board {m.width}x{m.height} center=({m.center.x},{m.center.y})"
echo &"captureClear={m.captureClear} flagRing={m.flagRing} " &
  &"spawnClear={m.spawnClearW}x{m.spawnClearH} homeDepth={m.homeDepth}"
let a = m.teamAnchor(Red)
echo &"redAnchor=({a.x},{a.y})  sightline band x=[{m.sightlineLoX},{m.sightlineHiX}]"
echo &"medkits={m.medKitSpawns}"

let r = mapRules("standard", 2)
echo &"rules: regime={r.regime} lanes={r.laneCount}x{r.laneWidthPx}px " &
  &"pitch={r.lanePitchPx} cover={r.coverPermilleMin}..{r.coverPermilleMax} " &
  &"coverSize={r.coverSizePx} wallSpan={r.wallSpanPx}"
echo &"       maxOpenRun={r.maxOpenRunPx} maxExposedRun={r.maxExposedRunPx} " &
  &"minCorridor={r.minCorridorWidthPx} chokeSpacing={r.chokepointSpacingPx} " &
  &"chokesPerRoute={r.chokepointsPerRoute} coverPieces={r.coverPieces}"
echo &"       hubRadius={r.hubRadiusPx} pickups={r.pickupCount} " &
  &"cross={r.crossSectionPx} traverse={r.traversePx} playfield={r.playfieldPx}"

# how much of the half-field is actually buildable (not protected floor)?
var protectedPx, freePx = 0
for y in 0 ..< m.height:
  for x in 0 ..< m.width div 2:
    if m.mapProtectedFloorAt(x, y): inc protectedPx else: inc freePx
echo &"left half: protected={protectedPx}px free={freePx}px " &
  &"({protectedPx * 100 div (protectedPx + freePx)}% protected)"
