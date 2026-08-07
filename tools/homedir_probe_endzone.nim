## Throwaway probe: for teams=2 and teams=4, scan seeds 1..N and print the
## drawn endzone archetype (column/disc/square) so a homeDirNav invariance
## test can pick seeds that land on the classic column shape (the case the
## 2-team invariant claims byte-identical-within-tolerance behavior).
import std/[os, strutils], ../src/ctf/sim_types, ../src/ctf/arena

when isMainModule:
  let teams = if paramCount() >= 1: parseInt(paramStr(1)) else: 2
  let n = if paramCount() >= 2: parseInt(paramStr(2)) else: 60
  var cfg: GameConfig
  cfg.teams = teams
  cfg.mapPath = "gen"
  for seed in 1 .. n:
    cfg.mapSeed = seed
    let m = loadCtfMapMetadata(cfg)
    echo "seed=", seed, " teams=", teams, " endzone=", m.endzone,
      " layout=", m.layout, " homeDepth=", m.homeDepth,
      " w=", m.width, " h=", m.height
