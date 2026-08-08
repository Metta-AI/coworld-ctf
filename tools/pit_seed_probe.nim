## Which seeds can seat a full pit request? The `mapPits` lock is BEST-EFFORT
## — candidate spots come from the FILL, so how many a board seats is a
## property of the seed. Finds seeds for the trench tests after a generator
## change re-deals them.
import std/[os, strformat, strutils]
import ../src/ctf/[sim, arena]
when isMainModule:
  let want = if paramCount() >= 1: parseInt(paramStr(1)) else: 12
  for seed in 1000 .. 1120:
    var big, exact = 0
    try:
      big = generateCtfMap(seed, MapGenOverrides(
        windows: -1, pits: 64, pitDensity: -1)).trenches.len
      exact = generateCtfMap(seed, MapGenOverrides(
        windows: -1, pits: want, pitDensity: -1)).trenches.len
    except CatchableError:
      continue
    if exact == want and big > want:
      echo &"seed {seed}: exact({want})={exact} over(64)={big} " &
        &"arch={mapArchetypeFor(seed)}"
