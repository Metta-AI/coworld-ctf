## The hex arena coordinate kernel: cube/axial coordinates, the twelve exact
## integer symmetry operators of D6, the ONE hexagon boundary predicate, and
## the re-derived size classes. Stage 1 of
## `docs/plans/2026-08-04-hex-arena-conversion.md` — everything else in the
## conversion depends on this module.
##
## PURE. It imports `std/math` and nothing else: no `sim_types`, no process
## globals, no map install, no I/O. `tools/map_render.nim` and the map editor
## render arbitrary specs from a mummy thread pool, so a global reached from
## here would be a data race, and `arena.nim` installs its map into globals —
## keep the dependency arrow pointing this way.
##
## ---------------------------------------------------------------------------
## WHY CUBE COORDINATES ARE MANDATORY
## ---------------------------------------------------------------------------
##
## `rot90Point` (`arena.nim`) is an exact integer bijection on Z^2:
## `(x, y) -> (side - 1 - y, x)`. That exactness IS the codebase's team-fairness
## proof, which is why `validateMap` REFUSES a non-square rot90 board — a float
## rotation "would silently produce team-unfair obstacle images".
##
## `sin 60deg = sqrt(3)/2` is irrational, so rot60 and rot120 are NOT integer
## bijections of the square pixel lattice. Rotating pixels through floats and
## rounding reintroduces exactly the failure that validator refuses to permit.
##
## Therefore: obstacles are authored in cube coordinates `(q, r, s)` with
## `q + r + s == 0`, the symmetry orbit is walked in cube space where every
## operator is a signed coordinate permutation (exact, no arithmetic at all),
## and the assembled fundamental domain is rasterized to pixels EXACTLY ONCE.
## **Never rotate pixels.**
##
## ---------------------------------------------------------------------------
## THE FROZEN ORIENTATION, AND WHY
## ---------------------------------------------------------------------------
##
## Two orientations exist and they are duals, so both words appear in the plan
## and both are correct — of different objects:
##
## - **Lattice cells are FLAT-TOP.** `cubeToPixel` is the standard flat-top
##   layout: `x = size * 3/2 * q`, `y = size * (sqrt(3)/2 * q + sqrt(3) * r)`.
##   A cell has vertices at its left and right, flat edges top and bottom.
## - **The arena hexagon is POINTY-TOP.** A hexagonal REGION of flat-top cells
##   is itself rotated 30deg from its cells: `max(|q|, |r|, |s|) <= N` spans
##   `3*N*size` horizontally and `2*sqrt(3)*N*size` vertically, aspect
##   `3 / (2*sqrt(3)) = sqrt(3)/2 = 0.866`. So the natural hull of the authoring
##   lattice is a hexagon with vertices at top and bottom and flat edges left
##   and right, bounding box W x H with `W/H = sqrt(3)/2` — which is exactly the
##   969 x 1119 standard class below.
##
## Freezing both is what makes the boundary commensurate with the lattice: the
## arena outline is the hull of the same lattice the obstacles are authored on,
## so it needs no separate fairness argument.
##
## ANGLE CONVENTION, frozen with the layout: `cubeToPixel` emits SCREEN pixels
## with y growing DOWN, matching every other coordinate in the sim, and EVERY
## angle in this module is measured in that frame — from +x turning toward +y.
## So `hexRot60` is +60deg in the naming and is drawn turning CLOCKWISE, and
## `hexMir30`'s axis runs down-and-right. Pick either convention, but pick one:
## quoting a mirror axis in the y-up frame while the pixels are y-down is how a
## mirror silently becomes the wrong mirror.
##
## ---------------------------------------------------------------------------
## C4 IS NOT A HEX SYMMETRY
## ---------------------------------------------------------------------------
##
## The hexagonal point group is D6, order 12. By the crystallographic
## restriction theorem a lattice admits only 1-, 2-, 3-, 4- and 6-fold
## rotations, and a HEXAGONAL lattice admits 1, 2, 3, 6 — **not 4**. There is no
## hex analogue of `rot90` and none can be constructed; do not try.
##
## For 4 teams the correct group is the Klein four-group
## `V4 = {e, mirror0, mirror90, rot180}` (`GroupV4`). It has order 4, is a
## genuine subgroup of D6, and acts freely and transitively on 4 spawn points.
## The cost is real and must stay a stated, tested property: two of the four
## teams see a MIRROR IMAGE of the world rather than a rotation of it, which
## flips the handedness of every learned route. (It is the 4-player Chinese
## Checkers configuration.)
##
## A happy accident makes V4 the best possible choice: in pixel space its three
## non-identity elements are `(x,y) -> (x,-y)`, `(x,y) -> (-x,y)` and
## `(x,y) -> (-x,-y)`. Those are precisely the isometries the SQUARE pixel
## lattice also admits exactly, so the 4-team group is exact in BOTH spaces.
##
## ---------------------------------------------------------------------------
## WASM32 ARITHMETIC
## ---------------------------------------------------------------------------
##
## Under emscripten `int` is 32 bits and signed overflow traps where it is
## silently harmless on 64-bit. This codebase has shipped that bug twice; the
## established discipline is `int64` in `arena.nim`'s point-to-segment test and
## the `uint64` cast in `map_art.nim`'s `trenchRoughEdge`.
##
## Here: cube coordinates are bounded by the board radius in CELLS (a few
## thousand at worst) and only ever negated or permuted, so `int` is safe for
## them. The half-plane arithmetic in `hexEdgeDist` multiplies two doubled PIXEL
## extents (`2 * a2 * r2` reaches 5.9e7 on the colossal class, and a future
## caller could double it again), so every product there is `int64` and every
## input is widened before the multiply, never after.

import std/math

# ---------------------------------------------------------------------------
# Irrational constants
# ---------------------------------------------------------------------------

const
  Sqrt3* = 1.7320508075688772935              ## sqrt(3)
  Sqrt3Half* = 0.86602540378443864676         ## sqrt(3)/2 = sin 60deg = cos 30deg
  Sqrt3Third* = 0.57735026918962576451        ## sqrt(3)/3 = tan 30deg
  HexAreaFactor* = 2.5980762113533159403      ## 3*sqrt(3)/2: hex area / R^2

  HexAspectMin* = Sqrt3Half                   ## 0.8660..., a pointy-top hull
  HexAspectMax* = 1.1547005383792515290       ## 2/sqrt(3), a flat-top hull
    ## Any group transitive on 3 or 6 spawns contains a 120deg rotation, which
    ## confines the bounding-box aspect (W/H) to [sqrt(3)/2, 2/sqrt(3)]. The
    ## square arena's 1235/659 = 1.874 is far outside it: exact 3- or 6-team
    ## fairness on today's canvas is IMPOSSIBLE, and an anisotropic stretch of
    ## the lattice is not an isometry, so it silently breaks per-team travel
    ## times. The board has to change shape. See plan section 0.3.

# ---------------------------------------------------------------------------
# Cube and axial coordinates
# ---------------------------------------------------------------------------

type
  Cube* = object
    ## A hex lattice cell in cube coordinates. INVARIANT: `q + r + s == 0`.
    ## Constructing through `cube()` maintains it; `isCube` re-checks it and
    ## every symmetry operator preserves it by construction (each is a signed
    ## permutation of the three components, and both operations preserve a zero
    ## sum).
    q*, r*, s*: int

  Axial* = object
    ## The same cell with the redundant third component dropped — the compact
    ## form for storage and wire/JSON. `s` is always `-q - r`.
    q*, r*: int

func cube*(q, r: int): Cube {.inline.} =
  ## The only constructor that cannot violate the invariant.
  Cube(q: q, r: r, s: -q - r)

func isCube*(c: Cube): bool {.inline.} =
  ## Whether the cube invariant holds. Cheap enough to assert on any value
  ## that crossed a module or a wire boundary.
  c.q + c.r + c.s == 0

func toAxial*(c: Cube): Axial {.inline.} = Axial(q: c.q, r: c.r)
func toCube*(a: Axial): Cube {.inline.} = cube(a.q, a.r)

func `+`*(a, b: Cube): Cube {.inline.} =
  Cube(q: a.q + b.q, r: a.r + b.r, s: a.s + b.s)

func `-`*(a, b: Cube): Cube {.inline.} =
  Cube(q: a.q - b.q, r: a.r - b.r, s: a.s - b.s)

func `*`*(c: Cube, k: int): Cube {.inline.} =
  Cube(q: c.q * k, r: c.r * k, s: c.s * k)

const CubeOrigin* = Cube(q: 0, r: 0, s: 0)

const CubeDirections* = [
  Cube(q: 1, r: 0, s: -1),    ## 0:  30deg — right and down
  Cube(q: 0, r: 1, s: -1),    ## 1:  90deg — straight down
  Cube(q: -1, r: 1, s: 0),    ## 2: 150deg
  Cube(q: -1, r: 0, s: 1),    ## 3: 210deg — left and up
  Cube(q: 0, r: -1, s: 1),    ## 4: 270deg — straight up
  Cube(q: 1, r: -1, s: 0),    ## 5: 330deg
]
  ## The six unit steps, in `hexRot60` orbit order: applying `hexRot60` to
  ## `CubeDirections[i]` yields `CubeDirections[(i + 1) mod 6]`. Pinned by test.
  ##
  ## They sit at 30, 90, ..., 330 degrees rather than 0, 60, ..., 300 — the
  ## signature of a FLAT-TOP cell, whose two vertical neighbours are directly
  ## above and below it and whose other four are diagonal.

func neighbor*(c: Cube, dir: int): Cube {.inline.} =
  ## The adjacent cell in one of the six directions (`dir` is taken mod 6, so
  ## callers may pass a raw rotation count).
  c + CubeDirections[((dir mod 6) + 6) mod 6]

func hexLength*(c: Cube): int {.inline.} =
  ## Steps from the origin to this cell.
  (abs(c.q) + abs(c.r) + abs(c.s)) div 2

func hexDistance*(a, b: Cube): int {.inline.} =
  ## Steps between two cells — the hex lattice's L1 metric.
  hexLength(a - b)

iterator hexRing*(radius: int): Cube =
  ## The `6 * radius` cells at exactly `radius` steps from the origin, walked
  ## once in increasing-angle order (clockwise as drawn), starting from the
  ## 270deg corner. Radius 0 yields the origin alone.
  if radius <= 0:
    yield CubeOrigin
  else:
    var c = CubeDirections[4] * radius
    for side in 0 ..< 6:
      for _ in 0 ..< radius:
        yield c
        c = c.neighbor(side)

iterator hexDisc*(radius: int): Cube =
  ## Every cell within `radius` steps of the origin — `3r^2 + 3r + 1` of them.
  ## The set is D6-invariant, which makes it the natural domain for the
  ## bijection property tests.
  for q in -radius .. radius:
    for r in max(-radius, -q - radius) .. min(radius, -q + radius):
      yield cube(q, r)

# ---------------------------------------------------------------------------
# Cube <-> pixel (flat-top layout, screen y down)
# ---------------------------------------------------------------------------

func cubeToPixel*(c: Cube, size: float): tuple[x, y: float] {.inline.} =
  ## Cell center as a pixel OFFSET from the lattice origin, flat-top layout,
  ## screen y down. `size` is the cell circumradius in pixels.
  ##
  ## Offsets, not absolute pixels, deliberately: the caller adds the board
  ## center once, so there is exactly one place where the lattice is pinned to
  ## the canvas and the symmetry operators never have to know about it.
  (x: size * 1.5 * float(c.q),
   y: size * (Sqrt3Half * float(c.q) + Sqrt3 * float(c.r)))

func pixelToCubeF*(x, y, size: float): tuple[q, r, s: float] {.inline.} =
  ## The exact inverse of `cubeToPixel`, before rounding — fractional cube
  ## coordinates for a pixel offset from the lattice origin.
  let
    q = (2.0 / 3.0) * x / size
    r = (-x / 3.0 + Sqrt3Third * y) / size
  (q: q, r: r, s: -q - r)

func cubeRound*(fq, fr, fs: float): Cube =
  ## Nearest lattice cell to a fractional cube coordinate. Rounds all three
  ## components and then re-derives whichever moved FURTHEST, so the invariant
  ## survives and ties break the same way everywhere.
  var
    q = int(round(fq))
    r = int(round(fr))
    s = int(round(fs))
  let
    dq = abs(float(q) - fq)
    dr = abs(float(r) - fr)
    ds = abs(float(s) - fs)
  if dq > dr and dq > ds: q = -r - s
  elif dr > ds: r = -q - s
  else: s = -q - r
  Cube(q: q, r: r, s: s)

func pixelToCube*(x, y, size: float): Cube {.inline.} =
  ## Nearest cell to a pixel offset from the lattice origin.
  let f = pixelToCubeF(x, y, size)
  cubeRound(f.q, f.r, f.s)

# ---------------------------------------------------------------------------
# D6: the twelve exact integer symmetry operators
# ---------------------------------------------------------------------------

type
  HexSym* = enum
    ## The point group of the hex lattice, D6, order 12. Every element is a
    ## signed permutation of `(q, r, s)`: exact, allocation-free, and
    ## overflow-proof (it performs no arithmetic beyond negation).
    ##
    ## Rotations are named by their turn angle, mirrors by their AXIS angle,
    ## both in the frozen screen frame (from +x toward +y, i.e. clockwise as
    ## drawn). Every axis angle here is pinned by a fixed-point probe in
    ## `tests/test_hex.nim`.
    hexE          ## identity                (q, r, s)
    hexRot60      ## +60deg                  (-r, -s, -q)
    hexRot120     ## +120deg                 (s, q, r)
    hexRot180     ## +180deg                 (-q, -r, -s)
    hexRot240     ## +240deg                 (r, s, q)
    hexRot300     ## +300deg                 (-s, -q, -r)
    hexMir0       ## axis 0deg, horizontal   (q, s, r)     pixel (x,y)->(x,-y)
    hexMir30      ## axis 30deg              (-s, -r, -q)
    hexMir60      ## axis 60deg              (r, q, s)
    hexMir90      ## axis 90deg, vertical    (-q, -s, -r)  pixel (x,y)->(-x,y)
    hexMir120     ## axis 120deg             (s, r, q)
    hexMir150     ## axis 150deg             (-r, -q, -s)

func apply*(op: HexSym, c: Cube): Cube {.inline.} =
  ## One symmetry operator applied to a cell. This is the whole fairness
  ## kernel: it is a bijection of the lattice by inspection, it preserves
  ## `q + r + s == 0` by inspection, and it cannot round, overflow, or drift.
  case op
  of hexE:       Cube(q: c.q, r: c.r, s: c.s)
  of hexRot60:   Cube(q: -c.r, r: -c.s, s: -c.q)
  of hexRot120:  Cube(q: c.s, r: c.q, s: c.r)
  of hexRot180:  Cube(q: -c.q, r: -c.r, s: -c.s)
  of hexRot240:  Cube(q: c.r, r: c.s, s: c.q)
  of hexRot300:  Cube(q: -c.s, r: -c.q, s: -c.r)
  of hexMir0:    Cube(q: c.q, r: c.s, s: c.r)
  of hexMir30:   Cube(q: -c.s, r: -c.r, s: -c.q)
  of hexMir60:   Cube(q: c.r, r: c.q, s: c.s)
  of hexMir90:   Cube(q: -c.q, r: -c.s, s: -c.r)
  of hexMir120:  Cube(q: c.s, r: c.r, s: c.q)
  of hexMir150:  Cube(q: -c.r, r: -c.q, s: -c.s)

func apply*(op: HexSym, a: Axial): Axial {.inline.} =
  toAxial(op.apply(a.toCube()))

func isRotation*(op: HexSym): bool {.inline.} =
  ## Rotations preserve handedness; mirrors reverse it. A team whose image is
  ## produced by a mirror sees a world in which every learned route is
  ## left-right flipped — plan section 0.1.
  op <= hexRot300

const
  HexRotations* = [hexE, hexRot60, hexRot120, hexRot180, hexRot240, hexRot300]
    ## `HexRotations[k]` is the rotation by `60 * k` degrees, so
    ## `HexRotations[k] == rot60^k`. Pinned by test.
  HexMirrors* = [hexMir0, hexMir30, hexMir60, hexMir90, hexMir120, hexMir150]
    ## `HexMirrors[k]` has its axis at `30 * k` degrees. On the pointy-top
    ## arena the EVEN entries (0, 60, 120) run through opposite edge midpoints
    ## and the ODD ones (30, 90, 150) through opposite vertices.

# The composition table is BUILT, not typed. Two independent lattice vectors
# determine a D6 element uniquely, so identifying `a . b` by its action on
# `cube(1, 0)` and `cube(0, 1)` is exact — and the build itself is a
# compile-time proof that the twelve operators are closed under composition.
const
  ComposeProbeA = Cube(q: 1, r: 0, s: -1)
  ComposeProbeB = Cube(q: 0, r: 1, s: -1)

func buildComposeTable(): array[HexSym, array[HexSym, HexSym]] =
  for a in HexSym:
    for b in HexSym:
      let
        wantA = a.apply(b.apply(ComposeProbeA))
        wantB = a.apply(b.apply(ComposeProbeB))
      var found = false
      for c in HexSym:
        if c.apply(ComposeProbeA) == wantA and c.apply(ComposeProbeB) == wantB:
          result[a][b] = c
          found = true
          break
      doAssert found, "D6 is not closed under composition — impossible"

const HexComposeTable* = buildComposeTable()
  ## The D6 group table. `HexComposeTable[a][b]` is "apply b, then a".

func compose*(a, b: HexSym): HexSym {.inline.} =
  ## "Apply `b`, then `a`" — function composition order, `a . b`.
  HexComposeTable[a][b]

func inverse*(op: HexSym): HexSym =
  ## The operator that undoes this one. Every mirror is its own inverse; the
  ## rotations pair up.
  for c in HexSym:
    if compose(op, c) == hexE:
      return c
  hexE  # unreachable: D6 is a group

func order*(op: HexSym): int =
  ## How many times this operator must be applied to return to the identity —
  ## 1, 2, 3 or 6 on a hex lattice, and NEVER 4 (crystallographic restriction).
  var
    acc = op
    n = 1
  while acc != hexE:
    acc = compose(acc, op)
    inc n
  n

# ---------------------------------------------------------------------------
# The subgroups we actually deploy, one per team count
# ---------------------------------------------------------------------------

const
  GroupC1* = @[hexE]
  GroupC2* = @[hexE, hexRot180]
    ## 2 teams: a half turn. The 2-team analogue of today's `symRot180`.
  GroupC3* = @[hexE, hexRot120, hexRot240]
    ## 3 teams: thirds of a turn, all rotations, no mirror — every team sees
    ## the same handedness.
  GroupV4* = @[hexE, hexMir0, hexMir90, hexRot180]
    ## 4 teams: the Klein four-group (equivalently the dihedral group of order
    ## 4, generated by two PERPENDICULAR mirrors whose product is the half
    ## turn). C4 IS NOT A SUBGROUP OF D6; this is the only order-4 subgroup that
    ## acts freely and transitively on 4 points, and two of its elements are
    ## mirrors (plan section 0.1).
  GroupC6* = @[hexE, hexRot60, hexRot120, hexRot180, hexRot240, hexRot300]
    ## 6 teams: sixths of a turn.
  GroupD6* = @[hexE, hexRot60, hexRot120, hexRot180, hexRot240, hexRot300,
               hexMir0, hexMir30, hexMir60, hexMir90, hexMir120, hexMir150]
    ## The full point group — the invariance the arena BOUNDARY has, not a
    ## team layout (it is not free on any point set of size 12 we care about).

const HexSubgroups*: array[6, tuple[name: string, teams: int,
                                    elems: seq[HexSym]]] = [
  ("C1", 1, GroupC1),
  ("C2", 2, GroupC2),
  ("C3", 3, GroupC3),
  ("V4", 4, GroupV4),
  ("C6", 6, GroupC6),
  ("D6", 0, GroupD6),   ## boundary invariance, not a team layout
]
  ## The subgroup table: every subgroup of D6 this codebase deploys, with the
  ## team count it serves (`0` = not a team layout). Note the gap at 4: D6's
  ## order-4 subgroup is V4 and there is NO C4, which is the whole reason
  ## `rot90Point` and friends are deleted rather than ported.

func teamGroup*(teamCount: int): seq[HexSym] =
  ## The symmetry group for a team count. Team `i`'s world is
  ## `teamGroup(n)[i]` applied to team 0's, so the ORDER of these sequences is
  ## a contract, exactly as `rot90Quarter` was on the square board.
  ##
  ## 5 teams is deliberately absent: 5 does not divide 6 and no subgroup of D6
  ## has order 5, so a fair 5-team hex does not exist.
  case teamCount
  of 1: GroupC1
  of 2: GroupC2
  of 3: GroupC3
  of 4: GroupV4
  of 6: GroupC6
  else:
    raise newException(
      ValueError,
      "No D6 subgroup acts freely and transitively on " & $teamCount &
        " spawns (supported: 1, 2, 3, 4, 6).")

func orbit*(c: Cube, group: openArray[HexSym]): seq[Cube] =
  ## Every image of a cell under a group, in GROUP ORDER — one entry per group
  ## element, duplicates kept. This is the team-indexed form: `orbit(seed,
  ## teamGroup(n))[i]` is team `i`'s copy, and dropping duplicates here would
  ## silently misalign the teams.
  result = newSeqOfCap[Cube](group.len)
  for op in group:
    result.add op.apply(c)

func orbitUnique*(c: Cube, group: openArray[HexSym]): seq[Cube] =
  ## The DEDUPLICATED orbit — the obstacle-stamping form. A seed sitting on a
  ## mirror axis or at the center is its own image, and stamping it twice is
  ## the classic double-carve bug.
  result = @[]
  for image in c.orbit(group):
    if image notin result:
      result.add image

func stabilizer*(c: Cube, group: openArray[HexSym]): seq[HexSym] =
  ## The group elements that FIX this cell. A spawn seed must have a trivial
  ## stabilizer (`@[hexE]`) or the group does not act freely on its orbit and
  ## two teams end up sharing a base.
  result = @[]
  for op in group:
    if op.apply(c) == c:
      result.add op

func actsFreely*(c: Cube, group: openArray[HexSym]): bool {.inline.} =
  c.stabilizer(group).len == 1

# ---------------------------------------------------------------------------
# Spawn seeds
# ---------------------------------------------------------------------------

const SpawnSeedAngle*: array[7, float] = [
  0.0,      ## 0 teams (unused)
  0.0,      ## 1
  0.0,      ## 2: orbit {0, 180} — bases LEFT and RIGHT, see below.
  90.0,     ## 3: orbit {90, 210, 330} — the three vertex directions.
  45.0,     ## 4: see below.
  0.0,      ## 5 (unsupported)
  30.0,     ## 6: orbit {30, 90, ..., 330} — all six vertex directions.
]
  ## The screen-frame angle at which to seed each team count's orbit.
  ##
  ## Vertex directions (30, 90, 150, ...) are preferred where the choice is
  ## free: at a ring radius of `f * R` the wall is `R` away along a vertex
  ## direction but only `0.866 * R` away along an edge-midpoint direction, so a
  ## base seeded on a vertex direction gets meaningfully more room behind it.
  ##
  ## 2 teams is the deliberate exception: the orbit is kept on the horizontal
  ## (an edge-midpoint pair) so RED stays left and BLUE stays right. `teamHomeX`
  ## and every deployed league policy encode that; `homeDeepX`'s scarred
  ## `MapW * 150 div 1235` literal is what a silent change of this axis costs.
  ##
  ## 4 teams is the interesting entry. V4 carries a seed at angle `t` to
  ## `{t, -t, 180 - t, 180 + t}`, whose gaps alternate `2t` and `180 - 2t`.
  ## They are equal ONLY at `t = 45deg` — which is not a lattice symmetry
  ## direction, and does not need to be: the seed is an ordinary lattice cell
  ## near 45deg and its orbit is exact regardless. Seeding a 4-team board on a
  ## lattice axis instead would give bases 60deg/120deg apart, i.e. one close
  ## pair and one far pair per team.

func spawnSeed*(teamCount, ring: int): Cube =
  ## The cell on the radius-`ring` hex ring whose orbit is the fairest set of
  ## `teamCount` spawn points: closest to the ideal angle, tie-broken toward
  ## lower `q` then lower `r` so the choice is deterministic, and rejecting any
  ## cell the group does not act freely on.
  doAssert ring > 0, "spawn ring must be positive"
  let
    group = teamGroup(teamCount)
    want = degToRad(SpawnSeedAngle[teamCount])
    wantX = cos(want)
    wantY = sin(want)
  var
    best = CubeOrigin
    bestDot = -2.0
    found = false
  for c in hexRing(ring):
    if not c.actsFreely(group):
      continue
    let
      p = c.cubeToPixel(1.0)
      norm = hypot(p.x, p.y)
      dot = (p.x * wantX + p.y * wantY) / norm
    if not found or dot > bestDot + 1e-12 or
        (abs(dot - bestDot) <= 1e-12 and (c.q, c.r) < (best.q, best.r)):
      best = c
      bestDot = dot
      found = true
  doAssert found, "no free spawn seed on this ring"
  best

func spawnCells*(teamCount, ring: int): seq[Cube] {.inline.} =
  ## The `teamCount` spawn cells, indexed by team.
  spawnSeed(teamCount, ring).orbit(teamGroup(teamCount))

# ---------------------------------------------------------------------------
# The hexagon boundary: ONE predicate, six half-planes
# ---------------------------------------------------------------------------
#
# `arena.nim` warns at its own `isProtectedFloor` that the wall rule is written
# FOUR times (`mapWallAt`, `isArenaWall`, `mapObstacleWallAtF`,
# `mapShapeWallAtF`) and must stay pixel-identical across all of them. That is a
# standing bug source. There is ONE boundary predicate here and every caller in
# the codebase routes through it. Do not write a second copy.

type
  HexBoard* = object
    ## A hexagon inscribed EXACTLY in a `width x height` pixel bounding box:
    ## pointy-top, centered on the board's true center `((W-1)/2, (H-1)/2)`,
    ## vertices at `(cx, 0)` and `(cx, H-1)`, flat edges at `x = 0` and
    ## `x = W-1`.
    ##
    ## `a2` and `r2` are the DOUBLED half-extents (`W-1`, `H-1`) — the same
    ## doubling trick `centerOffset2` uses on the square board, and for the same
    ## reason: on an even side the true symmetry axis is a half pixel off the
    ## div-derived center, and a shape measured from `center` is then not its
    ## own image. Doubling keeps every comparison in exact integers.
    ##
    ## A regular hexagon has no vertices on the integer lattice (the same
    ## irrationality that killed rot60 on pixels), so this hexagon is regular to
    ## within the rounding of `W` against `H * sqrt(3)/2` — at most half a pixel
    ## on every class in `HexSizes`. What it IS exactly is invariant under V4:
    ## `x -> W-1-x` and `y -> H-1-y` map the doubled coordinates to their
    ## negations and permute the three half-plane pairs among themselves.
    width*, height*: int
    a2*, r2*: int64

func hexBoard*(width, height: int): HexBoard {.inline.} =
  doAssert width > 1 and height > 1, "hex board must be at least 2x2"
  HexBoard(width: width, height: height,
           a2: int64(width - 1), r2: int64(height - 1))

func circumradius*(b: HexBoard): float {.inline.} =
  ## Center to a vertex, in pixels: half the bounding-box HEIGHT (pointy-top).
  float(b.r2) / 2.0

func apothem*(b: HexBoard): float {.inline.} =
  ## Center to an edge midpoint: half the bounding-box WIDTH.
  float(b.a2) / 2.0

func hexArea*(b: HexBoard): float {.inline.} =
  ## Playfield area in px^2 — `2 * apothem * circumradius * 3/2` for a hexagon
  ## with these half-extents. This, not `width * height`, is the number to
  ## compare against a rectangular board: 25% of the bounding box is void.
  3.0 * b.apothem() * b.circumradius()

func aspect*(b: HexBoard): float {.inline.} =
  float(b.width) / float(b.height)

func aspectOk*(b: HexBoard): bool {.inline.} =
  ## Whether the bounding box sits in the 120deg-rotation-admissible band, with
  ## one pixel of slack for the integer rounding of the class table.
  let slack = 1.0 / float(b.height)
  b.aspect() >= HexAspectMin - slack and b.aspect() <= HexAspectMax + slack

func hexSlacks(b: HexBoard, dx2, dy2: float): tuple[n0, n1, n2: float] {.inline.} =
  ## The three half-plane slacks in QUADRUPLED, unnormalized units, given
  ## DOUBLED offsets from the board's true center. Positive means inside that
  ## opposed pair of edges. This is the single core both public entry points
  ## share; nothing else may re-derive it.
  ##
  ## The hexagon's six edges are three OPPOSED PAIRS, so three absolute values
  ## cover all six half-planes:
  ##   |dx|                    <= a          (the two vertical edges)
  ##   |R*dx + 2A*dy|          <= 2*A*R      (the two edges of positive slope)
  ##   |R*dx - 2A*dy|          <= 2*A*R      (the two of negative slope)
  ## with `A = a2/2` the apothem and `R = r2/2` the circumradius; the second
  ## line is the line through the vertices `(A, R/2)` and `(0, R)`.
  ##
  ## int64 for the products (see the wasm note at the top): `2 * a2 * r2` is
  ## 5.9e7 on the colossal class, comfortably inside int32 today but one
  ## careless doubling away from the trap. The values are integral whenever the
  ## caller passed integer pixels — every magnitude here is under 2^53, so the
  ## float64 arithmetic below is EXACT for those, which is what makes the V4
  ## pixel invariance exact rather than approximate.
  let
    cross = 2.0 * float(b.a2 * b.r2)
    fr2 = float(b.r2)
    fa2 = float(b.a2)
  (n0: float(b.a2) - abs(dx2),
   n1: cross - abs(fr2 * dx2 + 2.0 * fa2 * dy2),
   n2: cross - abs(fr2 * dx2 - 2.0 * fa2 * dy2))

func hexEdgeDistF*(b: HexBoard, x, y: float): float =
  ## Signed distance in pixels from `(x, y)` to the hexagon boundary: positive
  ## inside, zero exactly on an edge, negative outside.
  ##
  ## Inside, this is exactly the distance to the nearest edge. Outside it is the
  ## distance to the nearest edge LINE, which in the six corner wedges is a
  ## conservative UNDER-estimate of the distance to the hexagon itself (the true
  ## nearest feature there is a vertex). Every use in the codebase — border
  ## thickness, void detection, clamping a throw back inside — wants the
  ## conservative answer.
  let
    dx2 = 2.0 * x - float(b.a2)
    dy2 = 2.0 * y - float(b.r2)
    (n0, n1, n2) = b.hexSlacks(dx2, dy2)
    # Normals: (1, 0) for the vertical edges, (R, 2A) for the slanted pairs.
    # In doubled units their lengths are 1 and sqrt(r2^2 + 4*a2^2)/2, and the
    # slacks above are quadrupled, hence the /2 and the 2*sqrt(...) divisors.
    slantNorm = 2.0 * sqrt(float(b.r2 * b.r2) + 4.0 * float(b.a2 * b.a2))
  min(n0 / 2.0, min(n1, n2) / slantNorm)

func hexEdgeDist*(b: HexBoard, x, y: int): float {.inline.} =
  ## Integer-pixel form of `hexEdgeDistF`. Same core, no second copy.
  b.hexEdgeDistF(float(x), float(y))

func insideHex*(b: HexBoard, x, y: float): bool {.inline.} =
  ## Whether a point is strictly inside the hexagon. Defined as
  ## `hexEdgeDistF(...) > 0` so the two can never drift apart — the full-board
  ## sweep in `tests/test_hex.nim` is the regression guard that keeps it that
  ## way. Strict, so the four pixels of the bounding box that the hexagon merely
  ## touches read as void; they are inside the border wall regardless.
  b.hexEdgeDistF(x, y) > 0.0

func insideHex*(b: HexBoard, x, y: int): bool {.inline.} =
  b.insideHex(float(x), float(y))

func hexEdgeDist*(x, y, width, height: int): float {.inline.} =
  ## Convenience form for callers that have loose dimensions rather than a
  ## `HexBoard` (the installed-map globals in `arena.nim`).
  hexBoard(width, height).hexEdgeDist(x, y)

func insideHex*(x, y, width, height: int): bool {.inline.} =
  hexBoard(width, height).insideHex(x, y)

func hexCenter*(b: HexBoard): tuple[x, y: float] {.inline.} =
  ## The board's TRUE symmetry center. Note it lands on a half pixel whenever a
  ## dimension is even — anchor to this, never to `width div 2`.
  (x: float(b.a2) / 2.0, y: float(b.r2) / 2.0)

func lattice*(b: HexBoard, cells: int): float {.inline.} =
  ## The cell circumradius that fits a radius-`cells` hex lattice exactly inside
  ## this board, so `cubeToPixel` of the outermost ring lands on the boundary.
  ## The lattice hull spans `3 * cells * size` horizontally, matching `2 * A`.
  doAssert cells > 0, "lattice radius must be positive"
  2.0 * b.apothem() / (3.0 * float(cells))

# ---------------------------------------------------------------------------
# Size classes
# ---------------------------------------------------------------------------
#
# DERIVATION. Today's board is 1235 x 659 = 813,865 px^2 at aspect 1.874, which
# section 0.3 of the plan rules out for 3 and 6 teams. Holding PLAYFIELD AREA
# constant (equal area is what keeps travel times, gun range, and the cover
# budget calibrated) and solving for a regular hexagon:
#
#     (3*sqrt(3)/2) * R^2 = 813865
#     R = sqrt(813865 / 2.598076) = 559.69 px
#     height = 2R          = 1119.4  -> 1119
#     width  = sqrt(3) * R =  969.4  ->  969
#
# So STANDARD = 969 x 1119, bounding box 1,084,311 px^2 of which 25% is void.
# Every other class is that standard hexagon scaled by the SAME class factors
# `arena.nim`'s `mapSizeScale` already uses, and rounded the same way —
# `scaledGenShell` scales 1235/659, this scales 969/1119, so the two tables stay
# in step and a class name means the same amount of field on either geometry.
#
# Playfield below is `hexArea` (measured on the DOUBLED half-extents `W-1`,
# `H-1`, which is what the boundary predicate actually encloses), against the
# rectangular class it replaces:
#
#   class      factor      hex WxH        playfield    old rect WxH   old area
#   small        0.85     824 x  951        586,388      1050 x  560    588,000
#   standard     1.00     969 x 1119        811,668      1235 x  659    813,865
#   large        1.30    1260 x 1455      1,372,940      1606 x  857  1,376,342
#   huge         1.80    1744 x 2014      2,631,494      2223 x 1186  2,636,478
#   giant        2.60    2519 x 2909      5,491,758      3211 x 1713  5,500,443
#   colossal     5.20    5039 x 5819     21,983,313      6422 x 3427 22,008,194
#
# Every row is within 0.3% of its rectangular predecessor's area and within one
# pixel of the exact sqrt(3)/2 aspect — `aspectOk` asserts the latter with
# exactly that slack, and `test_hex.nim` asserts both.

type
  HexSizeClass* = enum
    hxSmall, hxStandard, hxLarge, hxHuge, hxGiant, hxColossal

const
  HexStandardWidth* = 969
  HexStandardHeight* = 1119
    ## Frozen. Deriving these at runtime from a float would make every map hash
    ## depend on the platform's `sqrt`.

  HexClassScale*: array[HexSizeClass, float] = [
    0.85,   ## small
    1.0,    ## standard
    1.3,    ## large
    1.8,    ## huge
    2.6,    ## giant
    5.2,    ## colossal — override-only, 2x giant, never drawn at random.
  ]
    ## Identical to `arena.nim`'s `mapSizeScale`. If one moves, both move.

  HexClassNames*: array[HexSizeClass, string] = [
    "small", "standard", "large", "huge", "giant", "colossal"]

  HexSizeNames* = ["small", "standard", "large", "huge", "giant"]
    ## The classes a random draw may pick — `colossal` is override-only, exactly
    ## as on the square board.

  HexSizes*: array[HexSizeClass, tuple[width, height: int]] = [
    (824, 951),      ## small
    (969, 1119),     ## standard
    (1260, 1455),    ## large
    (1744, 2014),    ## huge
    (2519, 2909),    ## giant
    (5039, 5819),    ## colossal
  ]
    ## `round(standard * HexClassScale[c])` on both axes, tabled rather than
    ## computed so the numbers are reviewable and platform-independent.

func hexSizeClass*(name: string): HexSizeClass =
  for c in HexSizeClass:
    if HexClassNames[c] == name:
      return c
  raise newException(ValueError, "Unknown hex map size: " & name)

func hexBoardOf*(c: HexSizeClass): HexBoard {.inline.} =
  hexBoard(HexSizes[c].width, HexSizes[c].height)

func hexBoardOf*(name: string): HexBoard {.inline.} =
  hexBoardOf(hexSizeClass(name))

# ---------------------------------------------------------------------------
# 6-team spacing
# ---------------------------------------------------------------------------

const
  SixTeamBaseFraction* = 0.75
    ## Bases sit at 0.75 of the circumradius, as on the square board.
  SixTeamMinCircumradius* = 1400.0
    ## Adjacent-base separation on an N-ring is `2 * f * R * sin(pi/N)`, which at
    ## N = 6 collapses to just `f * R` — the worst case of any team count. With
    ## `f = 0.75` and the fixed 1050px `GunRange`, adjacent bases only clear one
    ## gun range at `R >= 1400`. Below that, 6ffa is cross-ring spawn sniping.
    ## Plan section 0.4: 6ffa ships on the GIANT class only.

func adjacentBaseSeparation*(b: HexBoard, teamCount: int,
                             fraction = SixTeamBaseFraction): float {.inline.} =
  ## Distance between two angularly adjacent bases on the ring, in pixels.
  doAssert teamCount >= 2
  2.0 * fraction * b.circumradius() * sin(PI / float(teamCount))

func supportsSixTeams*(b: HexBoard): bool {.inline.} =
  b.circumradius() >= SixTeamMinCircumradius
