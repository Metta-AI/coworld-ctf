## Prints `seed <sha1-of-mapSpecJson>` for a range of generator seeds — a
## baseline for proving that a generator change leaves given maps untouched.
## The endzone/homeDepth keys are stripped before hashing, which is what let a
## pre-endzone baseline and a post-endzone run compare directly. Note that no
## pre-hex baseline can match a post-hex one at all: the board is a different
## shape and a different size, so every seed names a different map.
## Usage: nim c -r -d:release tools/dump_map_specs.nim [lo] [hi]
import std/[json, os, strutils, strformat, sha1], ../src/ctf/sim

proc legacySpec(gameMap: CtfMap): string =
  let node = parseJson(gameMap.mapSpecJson())
  for key in ["endzone", "endzoneRadius", "homeDepth"]:
    node.delete(key)
  $node

when isMainModule:
  let
    lo = if paramCount() >= 1: parseInt(paramStr(1)) else: 1001
    hi = if paramCount() >= 2: parseInt(paramStr(2)) else: 1060
  for seed in lo .. hi:
    let gameMap = generateMapAttempt(
      seed, MapGenOverrides(windows: -1, pits: -1, pitDensity: -1))
    ## `EndzoneShape` has one member on a hex board, so the shape column is a
    ## constant now — printed from the enum rather than a hand-written token,
    ## so the day a sector zone lands it shows up here instead of silently
    ## reading "disc".
    let shape = $gameMap.endzone
    echo &"{seed} {($secureHash(gameMap.legacySpec))[0 .. 15]} " &
      &"{gameMap.width}x{gameMap.height} " &
      &"obstacles={gameMap.leftObstacles.len} " &
      &"valid={validateGeneratedMap(gameMap).len == 0} {shape} " &
      &"home={gameMap.teamHomeX(Red)} r={gameMap.endzoneRadius} " &
      &"why={validateGeneratedMap(gameMap)}"
