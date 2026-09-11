## Prints whether the C compiler fused a*b+c, plus hypot bits on a few
## lattice-like inputs. Build exactly like the server (release/opt:speed).
import std/[math, strutils]
proc fusedProbe(a, b, c: float): float {.noinline.} = a * b + c
let a = 1.0 + pow(2.0, -27)
let b = 1.0 - pow(2.0, -27)
let r = fusedProbe(a, b, -1.0)
echo "a*b+c bits=", toHex(cast[uint64](r)), " (0 => no contraction, 0xBC90000000000000 => fused)"
for (dx, dy) in [(3, 4), (7, 24), (12, 5), (1, 1), (4, 4), (2851, 1033), (3194, 1696), (1, 3210), (1712, 3210), (4, 0)]:
  let h = hypot(dx.float, dy.float)
  let cr = sqrt(float(dx * dx + dy * dy))
  echo "hypot(", dx, ",", dy, ") bits=", toHex(cast[uint64](h)), " correctly_rounded=", toHex(cast[uint64](cr)), (if h == cr: " same" else: " DIFFERENT")
