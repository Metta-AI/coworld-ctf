## biome_invariance_probe — PROVES a biome assignment is cosmetic.
##
## For every curated-pool seed it prints, on one line:
##   <seed> staticScore=<...> gameHash=0x<...> biome=<...>
##
## `staticScore` comes from `evaluateMap` on the shipped best-of-K map, exactly
## as the ranker computes it. `gameHash` is the sim's own replay hash after a
## fixed, deterministic script (add two players, start, step N idle ticks) on a
## sim built from that seed's generated map. `biome` is the field itself, so the
## SAME probe shows the skin actually changed while the two invariants did not.
##
## Run it before and after the biome change; diff the two outputs. The biome
## column moves, the staticScore and gameHash columns must be byte-identical.
##
## Usage: nim c -d:release -r tools/biome_invariance_probe.nim
import std/[strformat, os], bitworld/spriteprotocol,
  ../src/ctf/[arena, map_metrics, map_pool, sim, sim_types]

const
  SimSeed = 20260809   ## fixed simulation seed, so spawn draws are pinned.
  Ticks = 200          ## enough gameplay state to make the hash meaningful.

proc steppedHash(seed: int): uint64 =
  ## Build a sim on the generated map for `seed`, run a fixed idle script, hash.
  ## cwd is pinned to the repo root so data/ assets resolve, matching tests.
  let previousDir = getCurrentDir()
  setCurrentDir(currentSourcePath.parentDir.parentDir)
  try:
    var config = defaultGameConfig()
    config.mapPath = "gen"
    config.mapSeed = seed
    config.seed = SimSeed
    var sim = initSimServer(config)
    discard sim.addPlayer("red0")
    discard sim.addPlayer("blue0")
    sim.startGame()
    let idle = newSeq[InputState](sim.players.len)
    var prev = idle
    for _ in 0 ..< Ticks:
      sim.step(idle, prev)
      prev = idle
    result = sim.gameHash()
  finally:
    setCurrentDir(previousDir)

when isMainModule:
  for seed in MapPoolSeeds:
    let
      gameMap = generateCtfMap(seed)
      m = evaluateMap(gameMap, "gen:" & $seed)
      h = steppedHash(seed)
    echo &"{seed} staticScore={m.staticScore:.10f} gameHash=0x{h:016x} biome={gameMap.biome}"
