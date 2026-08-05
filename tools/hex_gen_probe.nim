## Generator pass-rate probe for the hexagonal arena.
##
## Reports what fraction of RAW seeds pass every validator first try, and the
## histogram of rejection reasons — the number the hex conversion has to state
## honestly, since the structure pass that will lift it is a separate epic.
##
##   nim c -d:release -r tools/hex_gen_probe.nim [count] [firstSeed]

import std/[os, strutils, tables, times]
import ../src/ctf/[sim_types, arena]

proc main() =
  let
    count = if paramCount() >= 1: parseInt(paramStr(1)) else: 200
    firstSeed = if paramCount() >= 2: parseInt(paramStr(2)) else: 1
  var
    passed = 0
    raised = 0
    reasons = initCountTable[string]()
    sizes = initCountTable[string]()
  let started = epochTime()
  for i in 0 ..< count:
    let seed = firstSeed + i
    var candidate: CtfMap
    try:
      candidate = generateMapAttempt(
        seed, MapGenOverrides(windows: -1, pits: -1, pitDensity: -1), 2)
    except CatchableError as e:
      inc raised
      reasons.inc("RAISED: " & e.msg.split('.')[0])
      continue
    let reason = validateGeneratedMap(candidate)
    sizes.inc($candidate.width & "x" & $candidate.height)
    if reason.len == 0:
      inc passed
    else:
      ## Bucket the reason, dropping the varying coordinate.
      var bucket = reason
      for cut in [" at ", ": "]:
        let idx = bucket.find(cut)
        if idx >= 0:
          bucket = bucket[0 ..< idx]
      reasons.inc(bucket)
  let elapsed = epochTime() - started
  echo "seeds: ", count, "  passed: ", passed, "  (",
    formatFloat(100.0 * float(passed) / float(count), ffDecimal, 1), "%)",
    "  raised: ", raised
  echo "elapsed: ", formatFloat(elapsed, ffDecimal, 1), "s  (",
    formatFloat(1000.0 * elapsed / float(count), ffDecimal, 0), " ms/seed)"
  echo "-- rejection reasons"
  reasons.sort()
  for reason, n in reasons:
    echo "  ", align($n, 4), "  ", reason
  echo "-- size classes drawn"
  sizes.sort()
  for size, n in sizes:
    echo "  ", align($n, 4), "  ", size

main()
