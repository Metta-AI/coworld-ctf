## Prints, for each generator seed, the 2-team endzone archetype and each team's
## capture zone box — next to the fixed x=150 home-column point the policy's
## homeDeepX() drives a carrier to. If that point is OUTSIDE the zone, a steal on
## that map can never be converted.
import std/[os, strutils], ../src/ctf/sim

when isMainModule:
  let lo = if paramCount() >= 1: parseInt(paramStr(1)) else: 301
  let hi = if paramCount() >= 2: parseInt(paramStr(2)) else: 308
  var inside, outside: int
  for seed in lo .. hi:
    let m = generateMapAttempt(seed, MapGenOverrides(windows: -1, pits: -1, pitDensity: -1))
    let z = m.captureZone(Red)
    let deepX = 150
    let ok = deepX >= z.xLo and deepX <= z.xHi
    if ok: inc inside else: inc outside
    echo "seed ", seed, "  ", m.width, "x", m.height,
         "  endzone=", $m.endzone,
         "  RedZone x[", z.xLo, "..", z.xHi, "] y[", z.yLo, "..", z.yHi, "]",
         "  homeDeepX=150 -> ", (if ok: "INSIDE" else: "*** OUTSIDE ***")
  echo "\ninside=", inside, "  outside=", outside
