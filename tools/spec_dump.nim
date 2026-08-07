## Writes the mapSpec JSON of `generateCtfMap(seed, teams)` to a file, so a
## board built on THIS tree can be played on another one without the two trees
## having to agree about the generator. `map_eval play` reads exactly this.
##
##   spec_dump --teams 4 --out DIR 1004 1008 1010
##
## Imports `ctf/map_metrics` for its side effect: it installs the best-of-K
## ranker at module-init time, and a probe that imports `ctf/arena` alone
## silently selects FIRST-VALID and dumps a different map. Asserted, not
## assumed — this trap has produced a wrong answer here twice.
import
  std/[os, strutils],
  ../src/ctf/[arena, map_metrics, sim_types]

when isMainModule:
  var
    teams = 2
    outDir = "/tmp/specs"
    seeds: seq[int]
    argv = commandLineParams()
    i = 0
  while i < argv.len:
    case argv[i]
    of "--teams": inc i; teams = argv[i].parseInt
    of "--out": inc i; outDir = argv[i]
    else: seeds.add argv[i].parseInt
    inc i
  doAssert mapFitnessInstalled(), "ranker not linked: this would dump first-valid"
  createDir(outDir)
  for s in seeds:
    let m = generateCtfMap(
      s, MapGenOverrides(windows: -1, pits: -1, pitDensity: -1), teams)
    let path = outDir / ("t" & $teams & "-gen" & $s & ".json")
    writeFile(path, m.mapSpecJson())
    echo path, " ", m.width, "x", m.height, " teams=", teams
