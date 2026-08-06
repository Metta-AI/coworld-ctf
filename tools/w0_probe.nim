## w0_probe — WHERE does a 4-team board spend its cover budget, and where does
## the route die? Answers both by re-evaluating the SAME candidate with one
## class of geometry removed at a time, so every number is a difference against
## a control rather than a model of the geometry.
##
##   nim c -d:release -r tools/w0_probe.nim [teams] [seed...]
import std/[os, strformat, strutils, sequtils]
import ../src/ctf/[arena, map_metrics, sim]

proc isPicket(s: ArenaShape): bool =
  ## rowCover emits exactly PicketW=24 x MinCorridorWidth=26 rects, and on a
  ## rot90 board the lane pickets never run, so the signature is unambiguous.
  s.kind == shapeRect and s.rect.w == 24 and s.rect.h == 26

proc report(tag: string, m: MapMetrics) =
  echo &"    {tag:<22} cover={m.coverPermille:>4}pm min={m.minCoverPermille:>4}pm " &
    &"int={m.interiorFrac:.3f} valid={m.valid} {m.reason}"

proc main() =
  let teams = if paramCount() >= 1: parseInt(paramStr(1)) else: 4
  var seeds: seq[int]
  for i in 2 .. paramCount(): seeds.add parseInt(paramStr(i))
  if seeds.len == 0: seeds = @[1002, 1005, 1006, 1012, 1013]

  for seed in seeds:
    echo &"seed {seed} (teams={teams})"
    for attempt in [0, 4, 8]:
      let raw = generateMapAttempt(seed, MapGenOverrides(
        windows: -1, pits: -1, pitDensity: -1), teams, attempt)
      let pickets = raw.leftObstacles.filterIt(it.isPicket).len
      echo &"  attempt {attempt}: {raw.leftObstacles.len} left shapes, " &
        &"{pickets} pickets, sym={raw.symmetry} layout={raw.layout} " &
        &"endzone={raw.endzone} {raw.width}x{raw.height}"
      report("as-generated", evaluateMap(raw, "raw"))
      ## Strip ONLY the rowCover pickets. Everything else — fill, spinners,
      ## streets — is untouched, so the delta is that stage's true cost.
      var noPickets = raw
      noPickets.leftObstacles = raw.leftObstacles.filterIt(not it.isPicket)
      report("minus pickets", evaluateMap(noPickets, "raw"))
      ## And the opposite end: pickets ONLY, so structure and fill are the
      ## remainder rather than an assumption.
      var onlyPickets = raw
      onlyPickets.leftObstacles = raw.leftObstacles.filterIt(it.isPicket)
      report("pickets only", evaluateMap(onlyPickets, "raw"))

main()
