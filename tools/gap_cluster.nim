## gap_cluster — archetype / playtype / size of a set of seeds, LIVE from the
## engine (generateCtfMap -> evaluateMap -> mapRules), NOT from stored map-card
## JSON. Provenance matters here: this number gates a change to the selection
## path (tasks#42), so every label is recomputed from the shipped best-of-K map.
##
## Reproduce:
##   export PATH="$HOME/.nimby/nim/bin:$PATH"; cd ~/mirror   # deps: nimby sync -g nimby.lock
##   nim c -d:release --out:/tmp/gap_cluster tools/gap_cluster.nim
##   /tmp/gap_cluster 4004 4061 4010 4003 4067 4042 4016 4073 4048 4028   # the 10 breaching
##   /tmp/gap_cluster 4053 4057 4005 4071 4017 4043 4021 4026 4058 4064 4076 4022 4040 4078 4059  # 120-131 band
## CSV: seed,gapMaxPx,sizeName,archetype,playtype,layout,teams,width,height,staticScore
import
  std/[os, strformat, strutils],
  ../src/ctf/[arena, sim, map_metrics, map_rules, map_taxonomy]

when isMainModule:
  let args = commandLineParams()
  if args.len < 1: quit("usage: gap_cluster <seed> [seed ...]")
  echo "seed,gapMaxPx,sizeName,archetype,playtype,layout,teams,width,height,staticScore"
  for a in args:
    let seed = a.parseInt
    let gm = generateCtfMap(seed)              # the shipped best-of-K map for the seed
    let m = evaluateMap(gm, &"gen:{seed}")
    let r = mapRules(gm.mapSizeClass(), 2)
    echo &"{seed},{m.standCoverGapMaxPx}," &
         &"{gm.mapSizeClass().sizeName()}," &
         &"{mapArchetypeFor(seed, 2)}," &
         &"{playtypeLabel(m, r)}," &
         &"{m.layout},{m.teams},{m.width},{m.height},{m.staticScore():.4f}"
