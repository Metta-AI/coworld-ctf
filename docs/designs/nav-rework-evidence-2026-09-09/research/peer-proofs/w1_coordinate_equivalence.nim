import std/[math, random]
proc referenceRound(value: float): int =
  let lower = floor(value).int
  let fraction = value - lower.float
  if fraction > 0.5 or (fraction == 0.5 and (lower and 1) != 0): lower + 1 else: lower
proc roundedRayCoordinate(lower, remainder, steps: int): int {.inline.} =
  if remainder * 2 > steps or (remainder * 2 == steps and (lower and 1) != 0): lower + 1 else: lower
proc advanceRayCoordinate(lower, remainder: var int; delta, steps: int) {.inline.} =
  remainder += delta
  if remainder < 0: remainder += steps; dec lower
  elif remainder >= steps: remainder -= steps; inc lower
var checked = 0
var mismatches = 0
proc runCase(a, delta, steps: int) =
  var lower = a
  var remainder = 0
  for step in 0 .. steps:
    let expected = referenceRound(a.float + delta.float * step.float / steps.float)
    let got = roundedRayCoordinate(lower, remainder, steps)
    inc checked
    if expected != got:
      inc mismatches
      if mismatches <= 5: echo "MISMATCH a=", a, " d=", delta, " steps=", steps, " k=", step, " ref=", expected, " got=", got
    advanceRayCoordinate(lower, remainder, delta, steps)
# exhaustive: steps 1..400, every |delta| <= steps, three origins including odd/even and near map edge
for steps in 1 .. 400:
  for delta in -steps .. steps:
    for a in [0, 1, 3211]:
      runCase(a, delta, steps)
# seeded large: steps up to 3312
var rng = initRand(20260909)
for i in 0 ..< 20000:
  let steps = rng.rand(1 .. 3312)
  let delta = rng.rand(-steps .. steps)
  let a = rng.rand(0 .. 3312)
  runCase(a, delta, steps)
# exact ties sweep at large steps: even steps, delta odd so 2*rem==steps occurs
for steps in countup(2, 3312, 2):
  for delta in [1, -1, steps - 1, -(steps - 1), steps div 2 + 1]:
    runCase(7, delta, steps)
echo "checked=", checked, " mismatches=", mismatches
