## The hex coordinate kernel: `src/ctf/hex.nim`.
##
## These tests ARE the fairness proof, not decoration. The square board's proof
## was "rot90 is an exact integer bijection of Z^2"; on a hex lattice the
## equivalent claim is "every D6 operator is an exact integer bijection of the
## cube lattice, orbits close, and the boundary predicate is single-sourced and
## exactly V4-invariant on pixels". Each of those is asserted below. If one of
## them starts failing, obstacles, spawns, or pickups are no longer team-fair —
## which is silent everywhere else.
##
## The module is pure, so this suite imports `ctf/hex` alone: no `helpers`, no
## map install, no assets.
import
  std/[algorithm, math, sets, unittest],
  ctf/hex

proc sampleDisc(radius: int): seq[Cube] =
  result = @[]
  for c in hexDisc(radius):
    result.add c

var rngState: uint64 = 0x243F6A8885A308D3'u64

proc nextRand(): uint64 =
  ## splitmix64, so the "large sample" is the same on every machine and target.
  rngState = rngState + 0x9E3779B97F4A7C15'u64
  var z = rngState
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc randCube(span: int): Cube =
  let
    q = int(nextRand() mod uint64(2 * span + 1)) - span
    r = int(nextRand() mod uint64(2 * span + 1)) - span
  cube(q, r)

proc screenAngle(c: Cube): float =
  ## Degrees from +x turning toward +y — the module's frozen convention.
  let p = c.cubeToPixel(1.0)
  var a = radToDeg(arctan2(p.y, p.x))
  if a < 0: a += 360.0
  a

suite "hex lattice and coordinates":

  test "the cube invariant holds everywhere it can be checked":
    for c in hexDisc(24):
      check c.isCube()
      check c.toAxial().toCube() == c
    for _ in 0 ..< 4000:
      let c = randCube(1_000_000)
      check c.isCube()
      for op in HexSym:
        check op.apply(c).isCube()

  test "cube arithmetic and the hex metric agree with hand values":
    check cube(1, 0) == Cube(q: 1, r: 0, s: -1)
    check cube(2, -1) + cube(-1, 3) == cube(1, 2)
    check cube(2, -1) - cube(2, -1) == CubeOrigin
    check cube(1, -1) * 3 == cube(3, -3)
    check hexLength(cube(3, -1)) == 3           # (3, -1, -2): (3+1+2)/2
    check hexLength(CubeOrigin) == 0
    check hexDistance(cube(2, -1), cube(-1, 3)) == 4   # diff (3,-4,1)
    for dir in 0 .. 5:
      check hexDistance(CubeOrigin, CubeOrigin.neighbor(dir)) == 1
    check CubeOrigin.neighbor(6) == CubeOrigin.neighbor(0)
    check CubeOrigin.neighbor(-1) == CubeOrigin.neighbor(5)

  test "the ring walk stays on its ring and closes":
    for radius in 1 .. 20:
      var
        seen: HashSet[Cube]
        count = 0
      for c in hexRing(radius):
        check hexLength(c) == radius
        seen.incl c
        inc count
      check count == 6 * radius
      check seen.len == 6 * radius
    var originOnly = 0
    for c in hexRing(0):
      check c == CubeOrigin
      inc originOnly
    check originOnly == 1

  test "the disc has the closed-form cell count and is D6-invariant":
    for radius in 0 .. 12:
      var cells: HashSet[Cube]
      for c in hexDisc(radius):
        cells.incl c
      check cells.len == 3 * radius * radius + 3 * radius + 1
      ## D6-invariance of the sample domain is what makes the surjectivity
      ## half of the bijection test below meaningful.
      for op in HexSym:
        var images: HashSet[Cube]
        for c in cells:
          images.incl op.apply(c)
        check images == cells

  test "cube <-> pixel is POINTY-TOP, y down, and round-trips":
    ## THE frozen orientation, half one. Lattice cells are pointy-top, which is
    ## what makes their hexagonal HULL flat-top and the board landscape — the
    ## two are duals and this test is where the cell half is pinned.
    ## Hand-computed against x = size*(sqrt(3)*q + sqrt(3)/2*r), y = size*3/2*r.
    let p10 = cube(1, 0).cubeToPixel(10.0)
    check abs(p10.x - 17.3205080757) < 1e-9
    check abs(p10.y - 0.0) < 1e-9
    let p01 = cube(0, 1).cubeToPixel(10.0)
    check abs(p01.x - 8.6602540378) < 1e-9
    check abs(p01.y - 15.0) < 1e-9
    ## (1, 0, -1) is the +x direction exactly: a POINTY-TOP cell's neighbours
    ## sit at 0/60/... degrees, so pure +x is ONE cell away. (On the old
    ## flat-top layout it was two, via (2, -1, -1) — the clearest single
    ## fingerprint of which layout is in force.)
    let pAxis = cube(1, 0).cubeToPixel(10.0)
    check abs(pAxis.x - 17.3205080757) < 1e-9
    check abs(pAxis.y) < 1e-9
    ## ...and pure +y is NOT a lattice direction at all: (0,1,-1) is 60 degrees
    ## off it. The vertical steps are the two 60/120 diagonals.
    check abs(cube(0, 1).cubeToPixel(10.0).x - 8.6602540378) < 1e-9
    check CubeOrigin.cubeToPixel(37.0) == (x: 0.0, y: 0.0)
    for c in hexDisc(30):
      let p = c.cubeToPixel(11.0)
      check pixelToCube(p.x, p.y, 11.0) == c
      let f = pixelToCubeF(p.x, p.y, 11.0)
      check abs(f.q - float(c.q)) < 1e-9
      check abs(f.r - float(c.r)) < 1e-9
      check abs(f.q + f.r + f.s) < 1e-9

  test "cubeRound lands on a valid cell for arbitrary pixels":
    for _ in 0 ..< 20000:
      let
        x = float(int(nextRand() mod 20000'u64)) - 10000.0
        y = float(int(nextRand() mod 20000'u64)) - 10000.0
        c = pixelToCube(x, y, 7.5)
      check c.isCube()
      ## Rounding must pick a NEAREST cell: the recovered pixel is never more
      ## than one cell circumradius away.
      let back = c.cubeToPixel(7.5)
      check hypot(back.x - x, back.y - y) <= 7.5 + 1e-9

suite "D6: exact integer symmetry":

  test "every operator is an exact bijection of the cube lattice":
    ## Injective AND surjective on a D6-invariant domain, which is the whole
    ## claim: no cell is lost, no cell is doubled, nothing rounds.
    let cells = sampleDisc(40)
    check cells.len == 3 * 40 * 40 + 3 * 40 + 1
    var domain: HashSet[Cube]
    for c in cells:
      domain.incl c
    for op in HexSym:
      var images: HashSet[Cube]
      for c in cells:
        images.incl op.apply(c)
      check images.len == cells.len       # injective
      check images == domain              # surjective onto the same domain

  test "every operator is injective on a large off-lattice-origin sample":
    ## The disc above is small and centered; this one is wide and scattered, so
    ## an operator that only misbehaves far from the origin cannot hide.
    var sample: HashSet[Cube]
    while sample.len < 20000:
      sample.incl randCube(5_000_000)
    for op in HexSym:
      var images: HashSet[Cube]
      for c in sample:
        let image = op.apply(c)
        check image.isCube()
        check op.inverse().apply(image) == c
        images.incl image
      check images.len == sample.len

  test "orbits close: applying a generator its order times is the identity":
    let cells = sampleDisc(20)
    for op in HexSym:
      let n = op.order()
      ## 1, 2, 3, 6 and nothing else — see the C4 test below.
      check n in [1, 2, 3, 6]
      var sawFullPeriod = false
      for c in cells:
        var
          acc = c
          firstReturn = 0
        for step in 1 .. n:
          acc = op.apply(acc)
          if acc == c and firstReturn == 0:
            firstReturn = step
        ## Closes exactly at the operator's order, for every cell.
        check acc == c
        ## Cells that come back sooner (the center, and anything on this
        ## operator's axis) must do so on a DIVISOR of the order — a return at
        ## any other step would mean the orbit is not a group orbit.
        check firstReturn > 0
        check n mod firstReturn == 0
        if firstReturn == n: sawFullPeriod = true
      ## And the order is not overstated: some cell really does need all n.
      check sawFullPeriod

  test "C4 IS NOT A SUBGROUP OF D6":
    ## The crystallographic restriction, asserted rather than assumed: if this
    ## ever passes with an order-4 element, someone has bolted a fake rot90 on.
    for op in HexSym:
      check op.order() != 4
    check hexRot180.order() == 2
    check hexRot60.order() == 6
    check hexRot120.order() == 3

  test "the composition table is the D6 group table":
    let cells = sampleDisc(12)
    for a in HexSym:
      for b in HexSym:
        let ab = compose(a, b)
        for c in cells:
          check ab.apply(c) == a.apply(b.apply(c))
    ## Group axioms.
    for a in HexSym:
      check compose(a, hexE) == a
      check compose(hexE, a) == a
      check compose(a, a.inverse()) == hexE
      check compose(a.inverse(), a) == hexE
      for b in HexSym:
        for c in HexSym:
          check compose(compose(a, b), c) == compose(a, compose(b, c))
    ## Order 12, six rotations and six mirrors, and a mirror times a mirror is
    ## always a rotation.
    var rotations, mirrors = 0
    for a in HexSym:
      if a.isRotation(): inc rotations else: inc mirrors
    check rotations == 6
    check mirrors == 6
    for a in HexMirrors:
      for b in HexMirrors:
        check compose(a, b).isRotation()

  test "rot60 generates C6 and walks CubeDirections":
    var acc = hexE
    for k in 0 .. 5:
      check acc == HexRotations[k]
      acc = compose(hexRot60, acc)
    check acc == hexE
    for i in 0 .. 5:
      check hexRot60.apply(CubeDirections[i]) == CubeDirections[(i + 1) mod 6]
      ## POINTY-TOP cells: neighbours at 0, 60, 120, 180, 240, 300 degrees.
      check abs(screenAngle(CubeDirections[i]) - float(60 * i)) < 1e-9

  test "each mirror's axis is where its name says it is":
    ## One probe cell per axis, verified both by its pixel angle and by being a
    ## fixed point of exactly that mirror.
    ## Every probe moved one step round with the layout: under the pointy-top
    ## cell layout each mirror NAME carries the permutation the name 30 degrees
    ## below it carried under the old flat-top one, so the cell that lies on a
    ## given axis changed even though the axis angles did not.
    let probes = [
      (hexMir0, cube(1, 0), 0.0),
      (hexMir30, cube(1, 1), 30.0),
      (hexMir60, cube(0, 1), 60.0),
      (hexMir90, cube(-1, 2), 90.0),
      (hexMir120, cube(-1, 1), 120.0),
      (hexMir150, cube(-2, 1), 150.0)]
    for (mirror, probe, angle) in probes:
      check abs(screenAngle(probe) - angle) < 1e-9
      check mirror.apply(probe) == probe
      for other in HexMirrors:
        if other != mirror:
          check other.apply(probe) != probe

  test "the two axis-aligned mirrors are the pixel flips":
    ## This is what makes V4 exact on the SQUARE pixel lattice too.
    for c in hexDisc(20):
      let
        p = c.cubeToPixel(9.0)
        h = hexMir0.apply(c).cubeToPixel(9.0)
        v = hexMir90.apply(c).cubeToPixel(9.0)
        r = hexRot180.apply(c).cubeToPixel(9.0)
      check abs(h.x - p.x) < 1e-9 and abs(h.y + p.y) < 1e-9
      check abs(v.x + p.x) < 1e-9 and abs(v.y - p.y) < 1e-9
      check abs(r.x + p.x) < 1e-9 and abs(r.y + p.y) < 1e-9

  test "hand-computed operator values":
    check hexRot60.apply(cube(2, -1)) == cube(1, 1)      # (2,-1,-1)->(1,1,-2)
    check hexRot120.apply(cube(2, -1)) == cube(-1, 2)
    check hexRot180.apply(cube(2, -1)) == cube(-2, 1)
    check hexRot240.apply(cube(2, -1)) == cube(-1, -1)
    check hexRot300.apply(cube(2, -1)) == cube(1, -2)
    ## The ROTATIONS above are byte-for-byte what they were under the portrait
    ## convention — they are pure signed permutations and know nothing about
    ## pixels. The MIRRORS below are the ones that moved, because a mirror is
    ## named for the pixel axis it reflects about and the pixel map changed.
    check hexMir0.apply(cube(1, 0)) == cube(1, 0)        # on its own axis
    check hexMir90.apply(cube(1, 0)) == cube(-1, 0)      # +x flips to -x
    check hexMir30.apply(cube(3, 1)) == cube(1, 3)       # (3,1,-4)->(1,3,-4)
    check hexRot60.apply(Axial(q: 2, r: -1)) == Axial(q: 1, r: 1)

suite "team groups and spawns":

  test "V4 is the Klein four-group, not C4":
    check GroupV4 == @[hexE, hexMir0, hexMir90, hexRot180]
    check GroupV4.len == 4
    ## Every non-identity element is an involution — the signature that
    ## distinguishes V4 from the cyclic group of the same order.
    for op in GroupV4:
      if op != hexE:
        check op.order() == 2
    ## Closed, and the product of any two distinct non-identity elements is the
    ## third.
    for a in GroupV4:
      for b in GroupV4:
        check compose(a, b) in GroupV4
    check compose(hexMir0, hexMir90) == hexRot180
    check compose(hexMir90, hexMir0) == hexRot180
    check compose(hexMir0, hexRot180) == hexMir90
    check compose(hexMir90, hexRot180) == hexMir0
    ## Two of the four teams see a MIRRORED world. Stated, and tested, because
    ## a mirror flips the handedness of every learned route.
    var mirrored = 0
    for op in GroupV4:
      if not op.isRotation(): inc mirrored
    check mirrored == 2

  test "every entry of the subgroup table really is a subgroup":
    for (name, teams, group) in HexSubgroups:
      check group.len > 0
      check group[0] == hexE
      ## Closed, and closed under inverses — Lagrange then forces the order to
      ## divide 12, which is asserted by the team counts below.
      for a in group:
        check a.inverse() in group
        for b in group:
          check compose(a, b) in group
      if teams > 0:
        check group.len == teams
        check teamGroup(teams) == group
      else:
        check name == "D6"
        check group.len == 12
    ## The gap at 4 is the point: the order-4 subgroup is V4, never C4.
    check HexSubgroups[3].name == "V4"
    check HexSubgroups[3].elems.len == 4

  test "unsupported team counts are refused, not silently approximated":
    for n in [0, 5, 7, 8, 12]:
      expect ValueError:
        discard teamGroup(n)

  test "V4 acts freely and transitively on 4 spawn points":
    let
      seed = spawnSeed(4, 12)
      cells = spawnCells(4, 12)
    check cells.len == 4
    check cells[0] == seed
    ## FREE: only the identity fixes the seed, so no two teams share a base.
    check seed.stabilizer(GroupV4) == @[hexE]
    check seed.actsFreely(GroupV4)
    check toHashSet(cells).len == 4
    ## TRANSITIVE: from any spawn there is a group element carrying it to any
    ## other. With |group| == |orbit| == 4 that element is also unique.
    for a in cells:
      for b in cells:
        var carriers = 0
        for op in GroupV4:
          if op.apply(a) == b: inc carriers
        check carriers == 1
    ## Every spawn is the same distance from the center — an isometry cannot
    ## move a point off its ring, and this is the property a float rotation
    ## would have quietly broken.
    for c in cells:
      check hexLength(c) == 12
    ## Near the ideal 45 degrees, and the four gaps are equal to within the
    ## lattice's resolution at this ring.
    var angles: seq[float]
    for c in cells:
      angles.add screenAngle(c)
    angles.sort()
    for i in 0 .. 3:
      let gap = (angles[(i + 1) mod 4] - angles[i] + 360.0) mod 360.0
      check abs(gap - 90.0) < 6.0

  test "2, 3 and 6 team orbits are free, transitive and evenly spaced":
    for n in [2, 3, 6]:
      let
        group = teamGroup(n)
        seed = spawnSeed(n, 12)
        cells = spawnCells(n, 12)
      check cells.len == n
      check cells[0] == seed
      check seed.stabilizer(group) == @[hexE]
      check toHashSet(cells).len == n
      for c in cells:
        check hexLength(c) == 12
      ## 2, 3 and 6 all divide 6, so their orbits sit on exact lattice
      ## directions and the spacing is exactly 360/n.
      var angles: seq[float]
      for c in cells:
        angles.add screenAngle(c)
      angles.sort()
      for i in 0 ..< n:
        let gap = (angles[(i + 1) mod n] - angles[i] + 360.0) mod 360.0
        check abs(gap - 360.0 / float(n)) < 1e-6
    ## RED stays on the left, BLUE on the right — the axis every deployed
    ## policy encodes.
    let two = spawnCells(2, 12)
    check two[0].cubeToPixel(1.0).x > 0.0
    check two[1].cubeToPixel(1.0).x < 0.0
    check abs(two[0].cubeToPixel(1.0).y) < 1e-9

  test "orbit keeps duplicates for team indexing, orbitUnique drops them":
    ## A seed ON a mirror axis collapses: 4 group elements, 2 distinct images.
    let onAxis = cube(1, 0)           # fixed by hexMir0 (the horizontal axis)
    check onAxis.orbit(GroupV4).len == 4
    check onAxis.orbitUnique(GroupV4).len == 2
    check onAxis.stabilizer(GroupV4) == @[hexE, hexMir0]
    check not onAxis.actsFreely(GroupV4)
    ## Off-axis: orbit and orbitUnique agree, and team i's copy is group[i]'s
    ## image — the ordering contract downstream indexes teams by.
    let free = spawnSeed(4, 12)
    let images = free.orbit(GroupV4)
    check images.len == 4
    check free.orbitUnique(GroupV4).len == 4
    for i, op in GroupV4:
      check images[i] == op.apply(free)

suite "the hexagon boundary predicate":

  const Standard = (1119, 969)

  test "insideHex agrees with hexEdgeDist > 0 on every pixel of a board":
    ## The one predicate, swept in full. `arena.nim` warns that its wall rule is
    ## written FOUR times and must stay pixel-identical; this is the test that
    ## keeps the hex version single-sourced. Failures are COUNTED rather than
    ## `check`ed per pixel: 1.08M unittest assertions is slow enough in a debug
    ## build to matter, and a count localises nothing a sweep would not.
    let b = hexBoard(Standard[0], Standard[1])
    var
      inside = 0
      disagree = 0
      overloadDisagree = 0
    for y in 0 ..< b.height:
      for x in 0 ..< b.width:
        let d = b.hexEdgeDist(x, y)
        if b.insideHex(x, y) != (d > 0.0): inc disagree
        if b.insideHex(float(x), float(y)) != (d > 0.0) or
            insideHex(x, y, b.width, b.height) != (d > 0.0) or
            hexEdgeDist(x, y, b.width, b.height) != d:
          inc overloadDisagree
        if d > 0.0: inc inside
    check disagree == 0
    check overloadDisagree == 0
    ## A hexagon covers 3/4 of its bounding box; the boundary pixels the strict
    ## comparison excludes are a rounding-level share of that.
    check inside == 811103
    let frac = float(inside) / float(b.width * b.height)
    check frac > 0.745
    check frac < 0.751

  test "the same agreement holds on tiny and on even-sided boards":
    for (w, h) in [(9, 11), (2, 2), (12, 14), (100, 115), (824, 951)]:
      let b = hexBoard(w, h)
      var disagree = 0
      for y in 0 ..< h:
        for x in 0 ..< w:
          if b.insideHex(x, y) != (b.hexEdgeDist(x, y) > 0.0): inc disagree
      check disagree == 0

  test "hexEdgeDist is EXACTLY invariant under V4 on the pixel lattice":
    ## Bit-identical, not approximately equal. V4's pixel action is
    ## x -> W-1-x and y -> H-1-y, which negate the doubled coordinates and
    ## permute the three half-plane pairs; every intermediate is an exact
    ## integer in float64, so the result must match to the last bit. Any
    ## deviation here is per-team unfairness at the arena wall — the hex
    ## analogue of the non-square rot90 board `validateMap` refuses.
    for (w, h) in [(1119, 969), (14, 12), (951, 824)]:
      let b = hexBoard(w, h)
      var asymmetric = 0
      for y in 0 ..< b.height:
        for x in 0 ..< b.width:
          let d = b.hexEdgeDist(x, y)
          if b.hexEdgeDist(b.width - 1 - x, y) != d or
              b.hexEdgeDist(x, b.height - 1 - y) != d or
              b.hexEdgeDist(b.width - 1 - x, b.height - 1 - y) != d:
            inc asymmetric
      check asymmetric == 0

  test "the hexagon is inscribed exactly in its bounding box":
    let b = hexBoard(Standard[0], Standard[1])
    ## FLAT-TOP: the apothem is half the HEIGHT and the circumradius half the
    ## WIDTH. Under the portrait convention these were the other way round, and
    ## that single swap is the whole orientation change at board level.
    check b.apothem() == 484.0                 # (969-1)/2, the short axis
    check b.circumradius() == 559.0            # (1119-1)/2, the long axis
    check b.hexCenter() == (x: 559.0, y: 484.0)
    ## The four extreme points are exactly ON the boundary, so nothing spills
    ## outside the declared bounding box and nothing falls short of it. The two
    ## VERTICES are left and right; the two flat edges are top and bottom.
    check b.hexEdgeDist(0, 484) == 0.0         # left vertex
    check b.hexEdgeDist(1118, 484) == 0.0      # right vertex
    check b.hexEdgeDist(559, 0) == 0.0         # top edge midpoint
    check b.hexEdgeDist(559, 968) == 0.0       # bottom edge midpoint
    check not b.insideHex(0, 484)
    check b.insideHex(1, 484)
    check b.insideHex(559, 1)
    ## The corners of the bounding box are deep void — at exactly the same
    ## depth as under the portrait convention, since the box merely transposed.
    for (x, y) in [(0, 0), (1118, 0), (0, 968), (1118, 968)]:
      check b.hexEdgeDist(x, y) < -242.0
      check b.hexEdgeDist(x, y) > -242.1
    ## The top and bottom rows are whole EDGES lying exactly on the boundary,
    ## so no pixel of either is strictly inside; and the two apex COLUMNS are
    ## likewise only touched, never entered.
    for x in 0 ..< b.width:
      check not b.insideHex(x, 0)
      check not b.insideHex(x, b.height - 1)
    for y in 0 ..< b.height:
      check not b.insideHex(0, y)
      check not b.insideHex(b.width - 1, y)

  test "the distance at the center is the apothem, and falls off linearly":
    let b = hexBoard(Standard[0], Standard[1])
    check abs(b.hexEdgeDist(559, 484) - b.apothem()) < 1e-9
    ## Straight up/down from the centre runs at the two FLAT edges, so the
    ## distance falls off at rate exactly 1. (On the portrait board that ray
    ## was horizontal — it is the apothem direction either way.)
    for k in 0 .. 400:
      check abs(b.hexEdgeDist(559, 484 + k) - float(484 - k)) < 1e-9
    ## Every point at distance >= t from the boundary is inside, in all six
    ## directions: sample the six edge normals at 60-degree steps.
    for step in 0 .. 5:
      let
        ang = degToRad(float(60 * step))
        margin = 10.0
      for radius in 0 .. 470:
        let
          x = 559.0 + float(radius) * cos(ang)
          y = 484.0 + float(radius) * sin(ang)
        if float(radius) <= b.apothem() - margin:
          check b.insideHex(x, y)

  test "the float and int entry points are the same function":
    let b = hexBoard(Standard[0], Standard[1])
    for y in countup(0, b.height - 1, 7):
      for x in countup(0, b.width - 1, 5):
        check b.hexEdgeDistF(float(x), float(y)) == b.hexEdgeDist(x, y)

  test "a lattice sized to the board has its hull on the arena boundary":
    ## THE frozen orientation, half two — and the reason half one had to flip
    ## with it. The hull of a radius-N lattice of POINTY-TOP cells is itself a
    ## FLAT-TOP hexagon of aspect 2/sqrt(3): the same hexagon the arena outline
    ## is. That duality is why the pair is frozen together, and why the boundary
    ## needs no fairness argument separate from the lattice's.
    let b = hexBoard(Standard[0], Standard[1])
    for cells in [4, 12, 40]:
      let size = b.lattice(cells)
      ## The extreme +x cell of the radius-N disc sits on the arena's right
      ## VERTEX, to within the half pixel by which the integer size table rounds
      ## H against W.
      let east = cube(cells, 0).cubeToPixel(size)
      check abs(east.x - b.circumradius()) < 1.0
      check abs(east.y) < 1e-9
      ## The bottom EDGE is flat, so the two cells that reach lowest share a y
      ## exactly on it and straddle the vertical axis — neither is on the axis,
      ## because +y is not a lattice direction for pointy-top cells.
      let
        southEast = cube(0, cells).cubeToPixel(size)
        southWest = cube(-cells, cells).cubeToPixel(size)
      check abs(southEast.y - b.apothem()) < 1e-9
      check abs(southWest.y - b.apothem()) < 1e-9
      check abs(southEast.x + southWest.x) < 1e-9
      ## The hull aspect is exactly 2/sqrt(3), independent of N.
      check abs(east.x / southEast.y - HexAspectMax) < 1e-12

suite "hex size classes":

  test "the table is exactly round(standard * class factor)":
    check HexStandardWidth == 1119
    check HexStandardHeight == 969
    check HexSizes[hxStandard] == (1119, 969)
    ## LANDSCAPE: wider than tall, at the flat-top end of the aspect band.
    check HexStandardWidth > HexStandardHeight
    for c in HexSizeClass:
      check HexSizes[c].width ==
        int(round(float(HexStandardWidth) * HexClassScale[c]))
      check HexSizes[c].height ==
        int(round(float(HexStandardHeight) * HexClassScale[c]))
      check hexSizeClass(HexClassNames[c]) == c
      check hexBoardOf(HexClassNames[c]) == hexBoardOf(c)
    expect ValueError:
      discard hexSizeClass("enormous")
    ## The randomly-drawn classes, matching arena.nim's MapSizeNames; colossal
    ## stays override-only.
    check HexSizeNames == ["small", "standard", "large", "huge", "giant"]
    check "colossal" notin HexSizeNames

  test "every class sits inside the 120-degree aspect band":
    ## Any group transitive on 3 or 6 spawns contains a 120-degree rotation,
    ## which confines the bounding-box aspect to [sqrt(3)/2, 2/sqrt(3)]. Today's
    ## 1235x659 board is 1.874 — this is the constraint that forces the reshape.
    check 1235.0 / 659.0 > HexAspectMax
    for c in HexSizeClass:
      let b = hexBoardOf(c)
      check b.aspectOk()
      ## Within one pixel of the exact 2/sqrt(3) FLAT-TOP aspect. The band's
      ## two ends are the only two aspects a regular hexagon can have, and the
      ## board ships at the maximum; a portrait board would sit at the minimum
      ## and `aspectOk` accepts both.
      check abs(b.aspect() - HexAspectMax) <= 1.0 / float(min(b.width, b.height))
    check abs(HexAspectMin - sqrt(3.0) / 2.0) < 1e-15
    check abs(HexAspectMax - 2.0 / sqrt(3.0)) < 1e-15
    check abs(HexAreaFactor - 3.0 * sqrt(3.0) / 2.0) < 1e-12

  test "every class holds the playfield area of the rect class it replaces":
    ## Equal playfield area is what keeps travel times, the fixed gun range and
    ## the cover budget calibrated across the conversion.
    let rects = [
      (hxSmall, 1050, 560), (hxStandard, 1235, 659), (hxLarge, 1606, 857),
      (hxHuge, 2223, 1186), (hxGiant, 3211, 1713), (hxColossal, 6422, 3427)]
    for (c, w, h) in rects:
      ## The old table was round(1235/659 * factor); pin that we are comparing
      ## against the right predecessor.
      check w == int(round(1235.0 * HexClassScale[c]))
      check h == int(round(659.0 * HexClassScale[c]))
      let
        b = hexBoardOf(c)
        ratio = b.hexArea() / float(w * h)
      check ratio > 0.997
      check ratio < 1.003
      ## A quarter of the bounding box is void.
      let voidFrac = 1.0 - b.hexArea() / float(b.width * b.height)
      check abs(voidFrac - 0.25) < 0.002

  test "the standard class matches the documented derivation":
    let b = hexBoardOf(hxStandard)
    ## R = sqrt(1235*659 / (3*sqrt(3)/2)) = 559.69 -> width 1119, height 969.
    let r = sqrt(1235.0 * 659.0 / HexAreaFactor)
    check abs(r - 559.69) < 0.01
    check int(round(2.0 * r)) == b.width          # long axis, vertex to vertex
    check int(round(sqrt(3.0) * r)) == b.height   # short axis, edge to edge
    check b.hexArea() == 3.0 * 484.0 * 559.0    # 811,668 px^2
    ## The flip is area-neutral to the PIXEL: hexArea is 3/4*(W-1)*(H-1) and a
    ## product does not care which factor is which, so this is the identical
    ## number the portrait table produced.

  test "the boundary arithmetic is wasm32-safe on the largest class":
    ## Under emscripten `int` is 32 bits and signed overflow TRAPS. `hexSlacks`
    ## multiplies the doubled half-extents, so the magnitudes it reaches are
    ## pinned here — and so is how little headroom the largest class leaves.
    const Int32Max = 2_147_483_647'i64
    let b = hexBoardOf(hxColossal)
    ## a2 is the doubled APOTHEM (height-1) and r2 the doubled CIRCUMRADIUS
    ## (width-1); under the portrait convention the two were fed by the opposite
    ## sides, and the products below are unchanged because they transposed.
    check b.a2 == 5038      # 5039 - 1, the short axis
    check b.r2 == 5818      # 5819 - 1, the long axis
    check 2'i64 * b.a2 * b.r2 == 58_622_168
    check b.r2 * b.r2 + 4'i64 * b.a2 * b.a2 == 135_374_900
    check 2'i64 * b.a2 * b.r2 < Int32Max
    check b.r2 * b.r2 + 4'i64 * b.a2 * b.a2 < Int32Max
    ## Both products are QUADRATIC in the board size, so the headroom in linear
    ## terms is the square root of the headroom in the product: the tighter of
    ## the two (the slant norm) clears int32 by only ~15x, i.e. under 4x on the
    ## side of the board. A class table that grew the colossal board fourfold
    ## would trap on wasm and nowhere else — which is exactly why this is typed
    ## int64 rather than left to chance.
    check (b.r2 * b.r2 + 4'i64 * b.a2 * b.a2) * 15 < Int32Max
    check (b.r2 * b.r2 + 4'i64 * b.a2 * b.a2) * 16 > Int32Max
    check 2'i64 * (4 * b.a2) * (4 * b.r2) < Int32Max      # 16x: still fits
    check 2'i64 * (7 * b.a2) * (7 * b.r2) > Int32Max      # 49x: does not
    ## And the predicate is still correct out there.
    check abs(b.hexEdgeDist(2909, 2519) - b.apothem()) < 1e-9
    check b.hexEdgeDist(0, 2519) == 0.0        # left vertex
    check b.hexEdgeDist(2909, 0) == 0.0        # top edge midpoint
    check not b.insideHex(0, 0)
    var disagree = 0
    for y in countup(0, b.height - 1, 13):
      for x in countup(0, b.width - 1, 11):
        let d = b.hexEdgeDist(x, y)
        if b.insideHex(x, y) != (d > 0.0): inc disagree
        if b.hexEdgeDist(b.width - 1 - x, b.height - 1 - y) != d: inc disagree
    check disagree == 0

  test "6ffa fits on the giant class and nothing smaller":
    ## Adjacent-base separation on an N-ring is 2*f*R*sin(pi/N), which at N=6
    ## collapses to f*R — the worst case of any team count. It has to clear the
    ## fixed 1050px gun range or 6ffa is cross-ring spawn sniping.
    const GunRange = 1050.0
    for c in HexSizeClass:
      let b = hexBoardOf(c)
      check b.supportsSixTeams() == (c in {hxGiant, hxColossal})
      check b.supportsSixTeams() ==
        (b.adjacentBaseSeparation(6) >= GunRange)
      ## The collapse identity itself.
      check abs(b.adjacentBaseSeparation(6) -
        SixTeamBaseFraction * b.circumradius()) < 1e-9
      ## Fewer teams are always roomier at the same ring.
      for n in [2, 3, 4]:
        check b.adjacentBaseSeparation(n) > b.adjacentBaseSeparation(6)
    check hexBoardOf(hxGiant).circumradius() >= SixTeamMinCircumradius
    check hexBoardOf(hxHuge).circumradius() < SixTeamMinCircumradius
