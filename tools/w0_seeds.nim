## w0_seeds — per-seed validity and shape, so a median can be compared on the
## seeds two builds SHARE rather than on two different populations. A change
## that rescues seeds which used to raise moves the median by composition
## alone, and that reads as a regression when it is the opposite.
##
##   nim c -d:release -r tools/w0_seeds.nim [count] [teams]
import std/[os, strformat, strutils]
import ../src/ctf/[sim, map_metrics]

proc main() =
  let
    count = if paramCount() >= 1: parseInt(paramStr(1)) else: 40
    teams = if paramCount() >= 2: parseInt(paramStr(2)) else: 2
  for i in 0 ..< count:
    let seed = 1001 + i
    try:
      let m = evaluateMap(generateCtfMap(seed, teams = teams), "gen")
      echo &"{seed}\t{m.valid}\t{m.interiorFrac:.4f}\t{m.staticScore():.4f}\t{m.coverPermille}"
    except CtfError:
      echo &"{seed}\tRAISE\t0\t0\t0"

main()
