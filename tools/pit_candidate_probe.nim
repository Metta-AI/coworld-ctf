## pit_candidate_probe — how many pits can a fill-derived candidate set seat?
##
## ⚠️ Imports `ctf/sim`, NOT `ctf/arena`: `sim` module-init installs the
## static-fitness ranker best-of-K selects with, so a probe that imports only
## `arena` ranks nothing and reports a DIFFERENT map for the same seed (this
## cost an hour — seed 1002 read 6 pits instead of 8).
##
## The old column lattice registered pit candidates from its SLOTS, so the
## candidate set was regular and countable. The rewrite registers them from
## the FILL (arena.nim's terrain block, skipping the first `structureCount`
## structure shapes), so the set is irregular and seed-dependent — and the
## `mapPits` lock, which promises an EXACT total, has to be honoured against
## it. This probe is what tells apart "the test's expectation is stale" from
## "the generator cannot keep its promise".
##
## Reports, per seed: the candidate set size, and for each requested pit count
## the total the generator actually seated. Build with -d:mapdbg to see the
## per-stage attrition (candidates -> selected -> paired -> final).
##
##   nim c -d:release -r tools/pit_candidate_probe.nim [--counts:0,1,4,7,12] [seeds...]

import std/[os, strutils]
import ../src/ctf/sim

var
  seeds: seq[int]
  counts = @[0, 1, 4, 7, 12]
  density = -2   ## -2 = off; otherwise run the density path at this value
  useAttempt = false

for arg in commandLineParams():
  if arg.startsWith("--counts:"):
    counts = @[]
    for part in arg[9 .. ^1].split(','):
      counts.add parseInt(part)
  elif arg.startsWith("--density:"):
    density = parseInt(arg[10 .. ^1])
  elif arg == "--attempt":
    useAttempt = true   ## raw generateMapAttempt(seed, .., attempt 0), no best-of-K
  else:
    seeds.add parseInt(arg)
if seeds.len == 0:
  seeds = @[1002, 4242]

proc gen(seed: int, ov: MapGenOverrides): CtfMap =
  if useAttempt: generateMapAttempt(seed, ov) else: generateCtfMap(seed, ov)

for seed in seeds:
  echo "=== seed ", seed, (if useAttempt: " (attempt 0)" else: " (best-of-K)")
  if density > -2:
    let m = gen(seed, MapGenOverrides(windows: -1, pits: -1, pitDensity: density))
    echo "  density=", density, " class=", m.mapSizeClass(),
      " ruleBudget=", mapRules(m.mapSizeClass(), 2).trenchCount,
      " -> trenches=", m.trenches.len
    continue
  ## An unlocked draw first: it reports the candidate set under -d:mapdbg
  ## without the count mode's early break truncating it.
  discard gen(seed, MapGenOverrides(windows: -1, pits: -1, pitDensity: 0))
  for c in counts:
    var got = -1
    var err = ""
    try:
      got = gen(seed, MapGenOverrides(windows: -1, pits: c, pitDensity: -1)).trenches.len
    except CatchableError as e:
      err = e.msg
    echo "  pits=", c, " -> ", (if err.len > 0: "RAISE " & err else: $got),
      (if err.len == 0 and got != c: "   <-- SHORT by " & $(c - got) else: "")
