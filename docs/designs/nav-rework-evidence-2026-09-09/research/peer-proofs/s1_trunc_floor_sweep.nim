import std/math
proc viaFloor(v: float32): int = floor(v.float * 256.0).int
proc viaTrunc(v: float32): int = (v.float * 256.0).int
let cases = [3.7'f32, 0.999, 0.001, 1e-30, 127.99609, 32767.0/256, 32767.5/256]
for c in cases: echo c, " floor=", viaFloor(c), " trunc=", viaTrunc(c)
let nan = 0.0'f32 / 0.0'f32
let inf = 1.0'f32 / 0.0'f32
echo "nan<=0: ", nan <= 0'f32, " inf<=0: ", inf <= 0'f32
try: echo "nan floor=", viaFloor(nan), " trunc=", viaTrunc(nan)
except CatchableError as e: echo "nan raised ", e.name
except Defect as e: echo "nan defect ", e.name
try: echo "inf floor=", viaFloor(inf), " trunc=", viaTrunc(inf)
except Defect as e: echo "inf defect ", e.name
try: echo "1e30 floor=", viaFloor(1e30'f32), " trunc=", viaTrunc(1e30'f32)
except Defect as e: echo "1e30 defect ", e.name
# exhaustive-ish equivalence over every multiple of 1/1024 in (0, 32767.5], plus neighbours
var mismatches = 0
var n = 0
for k in 1 .. 32767 * 1024 + 512:
  let v = float32(k) / 1024.0'f32 / 256.0'f32
  inc n
  if viaFloor(v) != viaTrunc(v): inc mismatches
echo "sweep n=", n, " mismatches=", mismatches
