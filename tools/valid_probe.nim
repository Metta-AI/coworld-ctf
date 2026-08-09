## valid_probe — per-SEED validity of the SHIPPED generator (`generateCtfMap`,
## i.e. best-of-K), with the reason tally for every seed that dies.
##
## `gen_sweep` answers this for seeds 1001+ only, and the interesting failures
## are elsewhere: `tests/test_four_team.nim` builds seed 42. A validator change
## has to be measured on the seeds the repo actually uses, not on a convenient
## contiguous block.
##
##   nim c -d:release --nimcache:/tmp/nc-vp -r tools/valid_probe.nim [lo] [hi] [teams]
import std/[os, strformat, strutils, tables]
import ../src/ctf/sim

when isMainModule:
  let
    lo = if paramCount() >= 1: paramStr(1).parseInt else: 1
    hi = if paramCount() >= 2: paramStr(2).parseInt else: 100
    teams = if paramCount() >= 3: paramStr(3).parseInt else: 4
    layout = if paramCount() >= 4: paramStr(4) else: ""
    overrides = MapGenOverrides(
      layout: layout, windows: -1, pits: -1, pitDensity: -1)
  setCurrentDir(currentSourcePath().parentDir().parentDir())
  var
    ok, total = 0
    dead: seq[int]
  for seed in lo .. hi:
    inc total
    try:
      discard generateCtfMap(seed, overrides, teams = teams)
      inc ok
    except CtfError:
      dead.add seed
  echo &"{teams} teams, layout={(if layout.len == 0: \"(drawn)\" else: layout)}, " &
    &"seeds {lo}..{hi}: shipped-generator validity " &
    &"{ok}/{total} ({100.0 * float(ok) / float(total):.1f}%)"
  if existsEnv("VALID_MARGIN"):
    ## How much SLACK a seed has, not just whether it survives. A fixture seed
    ## that validates on 2 of 100 attempts is one validator tightening away
    ## from breaking every test that builds it, and nothing reports that today
    ## — seed 42 at layout=corners was exactly this.
    for seed in lo .. hi:
      var valid = 0
      for attempt in 0 ..< 100:
        if validateGeneratedMap(
            generateMapAttempt(seed, overrides, teams, attempt)).len == 0:
          inc valid
      echo &"    seed {seed}: {valid}/100 attempts valid"
  if dead.len > 0:
    echo &"  {dead.len}/{total} seeds found no valid layout in " &
      "MapGenMaxAttempts; why every attempt was rejected:"
    for seed in dead:
      var tally = initCountTable[string]()
      for attempt in 0 ..< 100:
        let why = validateGeneratedMap(
          generateMapAttempt(seed, overrides, teams, attempt))
        tally.inc(if why.len == 0: "VALID?" else: why.split(":")[0])
      var parts: seq[string]
      for reason, n in tally.pairs:
        parts.add &"{reason} {n}/100"
      echo &"    seed {seed}: " & parts.join(", ")
