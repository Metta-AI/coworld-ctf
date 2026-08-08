## pool_class_probe — which curated pool entries can a size-class-scoped
## generator change touch?
##
## The `PoolRenderHashes` pin in `tests/test_map_editor_core.nim` moves
## whenever the shipping map for a pool seed moves, and a bare "10 of 20
## changed" says nothing about whether that was the intended blast radius.
## This prints each entry's SIZE CLASS, so a change that claims to leave
## `standard` boards untouched can be held to it entry by entry rather than
## re-pinned on trust.
##
##   nim c -d:release -r tools/pool_class_probe.nim
## Demo/curation tooling; not part of the server.
import std/[strformat, tables]
import ../src/ctf/[sim, arena, map_pool, map_rules]

when isMainModule:
  var byClass = initCountTable[string]()
  for index in 0 ..< MapPoolSeeds.len:
    let
      gameMap = poolCtfMap(index)
      cls = sizeName(gameMap.mapSizeClass())
    byClass.inc cls
    echo &"pool[{index:<2}] seed={MapPoolSeeds[index]} {cls:<9} " &
      &"{gameMap.width}x{gameMap.height} teams=2"
  echo ""
  for cls, n in byClass:
    echo &"{cls:<9} {n}"
