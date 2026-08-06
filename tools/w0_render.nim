## w0_render — render ONE raw (unvalidated) generation attempt at full size,
## with the sightline and protected-floor overlays on. The contact sheet only
## shows candidates that PASSED, which is exactly the wrong sample when the
## question is why the others fail.
##
##   nim c -d:release -r tools/w0_render.nim <seed> <teams> <attempt> <out.png>
import std/[os, strformat, strutils, sequtils]
import pixie
import ../src/ctf/[arena, map_metrics, sim]
import map_render

proc main() =
  let
    seed = parseInt(paramStr(1))
    teams = parseInt(paramStr(2))
    attempt = parseInt(paramStr(3))
    outPath = paramStr(4)
  let raw = generateMapAttempt(seed, MapGenOverrides(
    windows: -1, pits: -1, pitDensity: -1), teams, attempt)
  let m = evaluateMap(raw, "raw")
  let pickets = raw.leftObstacles.filterIt(
    it.kind == shapeRect and it.rect.w == 24 and it.rect.h == 26)
  echo &"seed {seed} teams={teams} attempt={attempt}: {raw.width}x{raw.height} " &
    &"sym={raw.symmetry} layout={raw.layout} endzone={raw.endzone}"
  echo &"  {raw.leftObstacles.len} left shapes, {pickets.len} pickets"
  echo &"  cover={m.coverPermille}pm min={m.minCoverPermille}pm " &
    &"int={m.interiorFrac:.3f} valid={m.valid} reason={m.reason}"
  echo &"  sightline band x={raw.sightlineLoX}..{raw.sightlineHiX} " &
    &"center=({raw.center.x},{raw.center.y}) captureClear={raw.captureClear}"
  ## Where the pickets actually sit, so "they cluster at the same x" is a
  ## measurement rather than a guess.
  var xs = pickets.mapIt(it.rect.x)
  echo &"  picket x values: {xs}"
  let img = renderMap(raw, MapRenderOptions(
    maxDimension: 0,
    overlays: {overlayProtected, overlaySightlines},
  )).image
  img.writeFile(outPath)
  echo &"  -> {outPath} ({img.width}x{img.height})"

main()
