import std/math
# Walk both formulations for a given (nx, ny) and compare the branch sequence.
proc walkRecomputed(nx, ny: int): seq[int8] =
  var ix = 0; var iy = 0
  while ix < nx or iy < ny:
    let decision = (1 + 2 * ix) * ny - (1 + 2 * iy) * nx
    if decision == 0: result.add 2; inc ix; inc iy
    elif decision < 0: result.add 0; inc ix
    else: result.add 1; inc iy
proc walkIncremental(nx, ny: int): seq[int8] =
  var ix = 0; var iy = 0
  let decisionX = 2 * ny
  let decisionY = 2 * nx
  var decision = ny - nx
  while ix < nx or iy < ny:
    if decision == 0: result.add 2; inc ix; inc iy; decision += decisionX - decisionY
    elif decision < 0: result.add 0; inc ix; decision += decisionX
    else: result.add 1; inc iy; decision -= decisionY
var checked = 0
var mismatches = 0
var maxAbs = 0
for nx in 0 .. 300:
  for ny in 0 .. 300:
    if nx == 0 and ny == 0: continue
    let a = walkRecomputed(nx, ny)
    let b = walkIncremental(nx, ny)
    inc checked
    if a != b:
      inc mismatches
      if mismatches <= 5: echo "MISMATCH nx=", nx, " ny=", ny
    maxAbs = max(maxAbs, max((2 * nx + 1) * ny, (2 * ny + 1) * nx))
# perimeter offsets at both radii, both sign combinations reduce to |dx|,|dy|
proc perimeter(r: int): seq[(int, int)] =
  var seen: seq[(int, int)]
  template inc2(dx, dy: int) =
    if (dx, dy) notin seen: seen.add (dx, dy)
  for dx in -r .. r:
    let dy = int(round(sqrt(max(0, r * r - dx * dx).float)))
    inc2(dx, dy); inc2(dx, -dy)
  for dy in -r .. r:
    let dx = int(round(sqrt(max(0, r * r - dy * dy).float)))
    inc2(dx, dy); inc2(-dx, dy)
  seen
for r in [42, 163]:
  var n = 0
  for (dx, dy) in perimeter(r):
    if walkRecomputed(abs(dx), abs(dy)) != walkIncremental(abs(dx), abs(dy)): inc mismatches
    inc n
  echo "radius ", r, " perimeter offsets checked ", n
echo "pairs checked=", checked, " mismatches=", mismatches, " max |decision| bound at 300: ", maxAbs
