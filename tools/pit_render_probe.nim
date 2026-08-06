## Renders one generated map WITH its trenches drawn, so a change to the pit
## density can be looked at rather than only counted.
## Usage: nim c -d:release -r tools/pit_render_probe.nim <out.png> <seed>
import std/[os, strutils], pixie, ../src/ctf/sim, map_render
let
  outPath = paramStr(1)
  seed = parseInt(paramStr(2))
  gameMap = loadCtfMapMetadata("gen:" & $seed)
echo "seed ", seed, " trenches=", gameMap.trenches.len,
  " ", gameMap.width, "x", gameMap.height
renderMap(gameMap, MapRenderOptions(maxDimension: 900)).image.writeFile(outPath)
echo "wrote ", outPath
