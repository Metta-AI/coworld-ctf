import std/[math, random]
# Copies of the working-tree helpers (body_map.nim), unchanged.
proc advanceRayCoordinate(lower, remainder: var int; delta, steps, advance: int) {.inline.} =
  if advance == 1:
    remainder += delta
    if remainder < 0: remainder += steps; dec lower
    elif remainder >= steps: remainder -= steps; inc lower
  else:
    let accumulated = remainder.int64 + delta.int64 * advance.int64
    let whole = floorDiv(accumulated, steps.int64)
    lower += whole.int
    remainder = (accumulated - whole * steps.int64).int
var checked = 0
var mismatches = 0
var beyond32 = 0
proc trial(a, delta, steps, k: int) =
  var l1 = a; var r1 = 0
  for i in 0 ..< k: advanceRayCoordinate(l1, r1, delta, steps, 1)
  var l2 = a; var r2 = 0
  advanceRayCoordinate(l2, r2, delta, steps, k)
  inc checked
  if abs(delta.int64 * k.int64) >= 2'i64 shl 30: inc beyond32
  if l1 != l2 or r1 != r2:
    inc mismatches
    if mismatches <= 5: echo "MISMATCH a=", a, " d=", delta, " steps=", steps, " k=", k, " inc=(", l1, ",", r1, ") jump=(", l2, ",", r2, ")"
  # also from a nonzero mid-ray remainder state
  var l3 = a; var r3 = 0
  var l4 = a; var r4 = 0
  let pre = min(k, 3)
  for i in 0 ..< pre: advanceRayCoordinate(l3, r3, delta, steps, 1); advanceRayCoordinate(l4, r4, delta, steps, 1)
  for i in 0 ..< k: advanceRayCoordinate(l3, r3, delta, steps, 1)
  advanceRayCoordinate(l4, r4, delta, steps, k)
  inc checked
  if l3 != l4 or r3 != r4: inc mismatches
var rng = initRand(7)
for steps in 1 .. 300:
  for delta in -steps .. steps:
    for k in [2, 3, 7, 100, 255]:
      trial(5, delta, steps, k)
for i in 0 ..< 200_000:
  let steps = rng.rand(1 .. (1 shl 23) - 1)
  let delta = rng.rand(-steps .. steps)
  trial(rng.rand(0 .. 1 shl 23), delta, steps, rng.rand(2 .. 255))
trial(0, -((1 shl 23) - 1), (1 shl 23) - 1, 255)
trial(0, (1 shl 23) - 1, (1 shl 23) - 1, 255)
echo "checked=", checked, " mismatches=", mismatches, " cases_with_|delta*k|>=2^31=", beyond32
