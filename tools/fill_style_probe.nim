## fill_style_probe — which biome does the SHIPPING generator draw for a seed?
##
## `arena.generateMapAttempt` picks the fill skin as the first draw on the
## seed's "fill" stream. That is a pure function of (seed, attempt), so it can
## be replayed from outside without instrumenting the generator — which
## matters here because a `city`-skinned board is the thing that has to be
## LOOKED at, and there is otherwise no way to ask for one.
##
##   nim c -d:release -r tools/fill_style_probe.nim [firstSeed] [count]

import std/[os, strformat, strutils]
import ../src/ctf/[map_seed]

const Styles = ["caves", "forest", "desert", "city", "plains"]

proc styleOf(seed, attempt: int): string =
  var fillRng = mapSeed(seed, attempt).stream("fill")
  Styles[fillRng.pick(Styles.len)]

when isMainModule:
  let
    first = if paramCount() >= 1: parseInt(paramStr(1)) else: 1001
    count = if paramCount() >= 2: parseInt(paramStr(2)) else: 40
  var tally: array[5, int]
  for i in 0 ..< count:
    let seed = first + i
    var row = &"seed {seed}: "
    for attempt in 0 ..< 4:
      row &= &"{styleOf(seed, attempt)} "
    for s in 0 ..< Styles.len:
      if styleOf(seed, 0) == Styles[s]: inc tally[s]
    echo row
  var total = 0
  for t in tally: total += t
  var summary = ""
  for s in 0 ..< Styles.len:
    summary &= &"{Styles[s]}={tally[s]}/{total} "
  echo &"attempt-0 draw over {count} seeds: {summary}"
