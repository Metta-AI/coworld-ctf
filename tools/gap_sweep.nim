## gap_sweep — static standCoverGapMaxPx across a seed range.
##
## Uses the SAME map loader map_eval uses (loadCtfMapMetadata("gen:<seed>")),
## so numbers reproduce `map_eval score gen:<seed>`. Static only, no episodes.
## Emits CSV to stdout: seed,valid,gapMaxPx,breachBound,staticScore,gapSub,gapBreached
## (breachBound = standCoverGapMaxPx > MaxExposedRunPx=132; gapSub/gapBreached
##  are the standCoverGapMaxPx band's own sub-score and breach flag.)
##
## Reproduce (built the tasks#42 Layer-3 gap sweep, 4001-4080):
##   export PATH="$HOME/.nimby/nim/bin:$PATH"; cd ~/mirror   # deps: nimby sync -g nimby.lock
##   nim c -d:release --out:/tmp/gap_sweep tools/gap_sweep.nim
##   /tmp/gap_sweep 4001 4080
import
  std/[os, strformat, strutils],
  ../src/ctf/[arena, map_metrics]

proc gapBand(): Band =
  for b in DefaultBands:
    if b.name == "standCoverGapMaxPx": return b
  raise newException(ValueError, "standCoverGapMaxPx band not found")

when isMainModule:
  let args = commandLineParams()
  if args.len < 2:
    quit("usage: gap_sweep <loSeed> <hiSeed>")
  let
    lo = args[0].parseInt
    hi = args[1].parseInt
    band = gapBand()
    bound = int(band.hi)   # MaxExposedRunPx = 132
  stderr.writeLine &"# standCoverGapMaxPx bound (band.hi/MaxExposedRunPx) = {bound}px"
  echo "seed,valid,gapMaxPx,breachBound,staticScore,gapSub,gapBreached"
  for seed in lo .. hi:
    let m = evaluateMap(loadCtfMapMetadata(&"gen:{seed}"), &"gen:{seed}")
    # locate the gap band's own result for this map
    var gapSub = 1.0
    var gapBreached = false
    for r in m.scoreBands():
      if r.band.name == "standCoverGapMaxPx":
        gapSub = r.sub
        gapBreached = r.breached
        break
    let breachBound = m.standCoverGapMaxPx > bound
    echo &"{seed},{m.valid},{m.standCoverGapMaxPx},{breachBound}," &
         &"{m.staticScore():.4f},{gapSub:.4f},{gapBreached}"
