## intent_dump — emit playable specs + renders for the scene-graph generator in
## BOTH modes (baseline prototype vs the intentional layer), so a playtest sweep
## compares the same seeds with the only difference being the two intentional
## scenes. Writes <outdir>/<mode>-<seed>.json (a mapSpec `map_eval play` loads)
## and <mode>-<seed>.png.
##
## Usage:
##   nim c -d:release -o:/tmp/intent_dump tools/intent_dump.nim
##   /tmp/intent_dump /tmp/intent 4002 4005 4008
import std/[os, strformat, strutils]
import pixie
import ../src/ctf/[sim, map_metrics, mapgen_graph]
import ../tools/map_render

when isMainModule:
  let args = commandLineParams()
  if args.len < 2:
    quit("usage: intent_dump <outdir> <seed> [seed ...]")
  let outDir = args[0]
  createDir(outDir)
  for i in 1 ..< args.len:
    let seed = parseInt(args[i])
    for mode in ["baseline", "intentional"]:
      let g = generateGraphMap(seed, intentional = (mode == "intentional"))
      if g.rejected:
        echo &"{mode}-{seed}: REJECTED {g.reason}"
        continue
      let bad = validateGeneratedMap(g.gameMap)
      let specPath = outDir / &"{mode}-{seed}.json"
      writeFile(specPath, mapSpecJson(g.gameMap))
      let img = renderMap(g.gameMap, MapRenderOptions(maxDimension: 900))
      img.image.writeFile(outDir / &"{mode}-{seed}.png")
      let m = evaluateMap(g.gameMap, &"{mode}-{seed}")
      echo &"{mode}-{seed}: trenches={g.gameMap.trenches.len} " &
        &"obstacles={g.gameMap.leftObstacles.len} valid={bad.len == 0} " &
        &"interior={m.interiorFrac*100:.1f}% -> {specPath}" &
        (if bad.len > 0: "  << " & bad else: "")
