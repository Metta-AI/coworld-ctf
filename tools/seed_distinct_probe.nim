## seed_distinct_probe — how many DISTINCT maps does a range of seeds produce?
##
## Every quality metric in this project is computed PER MAP, so a generator that
## emits the same board for ten different seeds scores exactly as well as one
## that emits ten different boards. staticScore, interiorFrac and cover permille
## are all blind to it by construction. This is the one number that is not.
##
## Identity is the mapSpec, not the picture: mapSpecJson is the full expanded
## geometry and is what replays pin, so two seeds with the same spec really are
## the same board rather than merely similar.
##
##   nim c -d:release -r tools/seed_distinct_probe.nim [count] [teams]
import std/[os, strformat, strutils, tables, sets]
import ../src/ctf/[sim, arena]

proc main() =
  let
    count = if paramCount() >= 1: parseInt(paramStr(1)) else: 20
    teams = if paramCount() >= 2: parseInt(paramStr(2)) else: 2
  var
    specs = initTable[string, seq[int]]()
    raised = 0
  for i in 0 ..< count:
    let seed = 1001 + i
    var gameMap: CtfMap
    try:
      gameMap = generateCtfMap(seed, teams = teams)
    except CtfError:
      inc raised
      continue
    ## The name carries the seed, so strip it before comparing -- otherwise
    ## every map is trivially "distinct" and the probe measures nothing.
    var spec = mapSpecJson(gameMap)
    let nameEnd = spec.find(",")
    if nameEnd > 0: spec = spec[nameEnd .. ^1]
    specs.mgetOrPut(spec, @[]).add seed

  let
    generated = count - raised
    distinct0 = specs.len
  echo &"{teams}-team, seeds 1001..{1000 + count}: generated {generated}/{count} " &
    &"({100 * generated div max(count, 1)}%), raised {raised}/{count} " &
    &"({100 * raised div max(count, 1)}%)"
  echo &"  DISTINCT maps: {distinct0}/{generated} " &
    &"({100 * distinct0 div max(generated, 1)}%)"
  ## A collision is the whole point of the probe, so name the seeds involved --
  ## "62% distinct" is a number, "seeds 1,3,7,9 are one board" is a bug report.
  var collisions = 0
  for spec, seeds in specs:
    if seeds.len > 1:
      inc collisions
      echo &"    COLLISION: {seeds.len} seeds share one map -> {seeds}"
  if collisions == 0:
    echo "    no two seeds produced the same map."

main()
