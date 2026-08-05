## mapgen_graph — a SCENE-GRAPH terrain generator for CTF maps (prototype).
##
## This is the smallest honest implementation of the architecture proposed in
## `docs/plans/2026-08-05-scene-graph-mapgen-design.md`. It exists to answer
## one question with numbers instead of prose: does composing a map out of
## *regions that get given to scenes* beat scattering obstacles across the
## whole half-field? Everything here is deliberately small; the design doc is
## the deliverable and this is its proof.
##
## THREE THINGS THIS FILE IS TRYING TO DEMONSTRATE
##
## 1. **A scene owns a REGION, not the map.** `Scene.render` may only draw
##    inside `ctx.region`, and the only way to reach a smaller region is to
##    `make` one and hand it to a child. That is the whole reason a
##    scene-graph map reads as districts rather than as noise: nothing is ever
##    placed "somewhere on the board".
##
## 2. **Every placement carries the reason it exists.** `place` demands a
##    `serves` string, and the affordance it consumed is recorded on the
##    board. A feature nobody can name a purpose for cannot be written.
##
## 3. **Post-conditions outlive the pass that made them.** A scene may
##    register a `Postcondition` that the driver re-checks after the WHOLE
##    tree has rendered. This is the structural answer to the live
##    "walls in front of glass" defect (`arena.nim` glazes a column with no
##    knowledge of the diamonds a previous pass parked in front of it): the
##    glazier registers "this pane still has something to see", and a later
##    scene that blocks it fails the map instead of shipping it.
##
## SYMMETRY: everything here runs inside the FUNDAMENTAL DOMAIN (the left
## half). Nothing in this file knows about the lift; `buildArenaObstacles`
## does that downstream, exactly as it does for the current generator. That
## is deliberate — a symmetry-destroying pass (mettagrid's `dither_edges` is
## the archetype) can be added as one more scene and stay exactly fair,
## because it can only ever touch the domain.

import std/[algorithm, hashes, math, random, sequtils, sets, strutils, tables]
import sim_types, arena, map_rules

# ---------------------------------------------------------------------------
# Regions, placements, the board
# ---------------------------------------------------------------------------

type
  Region* = object
    ## A rectangle of the fundamental domain plus the TAGS that say what the
    ## scene which created it decided this rectangle is FOR. The tag is the
    ## carrier of intent: a child selects `["district", "rayblock"]` and can
    ## therefore assume, without re-deriving it, that its parent already
    ## proved this leaf must host a sightline-breaking structure.
    rect*: MapRect
    tags*: seq[string]

  Placement* = object
    ## One obstacle plus the audit trail that justifies it.
    shape*: ArenaShape
    scene*: string    ## the scene path that drew it
    serves*: string   ## the affordance it exists to provide

  Postcondition* = object
    ## A promise one scene makes that the driver re-checks after the entire
    ## tree has rendered. See the file header.
    scene*: string
    claim*: string
    check*: proc(b: Board): bool {.closure.}

  Board* = ref object
    ## Everything scenes share. Derived state (the wall test) is always
    ## recomputed from `placements`, never cached, so a scene can never read
    ## a stale picture of what an earlier scene did.
    width*, height*: int
    center*: MapPoint
    scanLo*, scanHi*: int          ## the validator's horizontal-ray band
    placements*: seq[Placement]
    posts*: seq[Postcondition]
    notes*: seq[string]
    rayCover*: seq[(int, int)]     ## y intervals a structure provably blocks
    protectedAt*: proc(x, y: int): bool {.closure.}

  Order* = enum ordFirst, ordRandom

  ChildAction* = object
    ## The port of mettagrid's `ChildrenAction`: a scene plus the query that
    ## picks which of the parent's regions it runs on.
    full*: bool          ## run on the parent's own region instead of its areas
    tags*: seq[string]   ## every tag must be present
    limit*: int          ## 0 = no limit
    order*: Order
    lock*: string        ## consume the selected areas under this lock name
    scene*: Scene

  Scene* = ref object
    name*: string
    render*: proc(ctx: var Ctx) {.closure.}
    children*: seq[ChildAction]

  Ctx* = object
    path*: string
    rng*: Rand
    region*: Region
    rules*: MapRules
    board*: Board
    areas*: seq[Region]
    locks*: Table[string, HashSet[int]]

proc streamSeed*(root: int, path: string): int =
  ## Per-scene RNG derivation. The stream is keyed by the scene's PATH, not
  ## by its position in a draw order, which buys the property the sibling
  ## sub-stream work is after: adding a scene anywhere in the tree leaves
  ## every other scene's stream bit-identical, and any single scene can be
  ## pinned by overriding its path key alone.
  root xor cast[int](hash(path)) xor 0x5EED_10A7

proc make*(ctx: var Ctx, rect: MapRect, tags: varargs[string]): Region =
  ## The only way to create a sub-region. Clamped into the parent, so a scene
  ## physically cannot hand a child ground it was not given.
  var r = rect
  r.x = max(r.x, ctx.region.rect.x)
  r.y = max(r.y, ctx.region.rect.y)
  r.w = min(r.w, ctx.region.rect.x + ctx.region.rect.w - r.x)
  r.h = min(r.h, ctx.region.rect.y + ctx.region.rect.h - r.y)
  result = Region(rect: r, tags: @tags)
  ctx.areas.add result

proc place*(ctx: var Ctx, shape: ArenaShape, serves: string) =
  ## Write one obstacle. `serves` is mandatory: the ledger is what makes
  ## "placed but pointless" auditable after the fact.
  doAssert serves.len > 0, "every placement must name what it serves"
  ctx.board.placements.add Placement(
    shape: shape, scene: ctx.path, serves: serves)

proc promise*(ctx: var Ctx, claim: string,
              check: proc(b: Board): bool {.closure.}) =
  ctx.board.posts.add Postcondition(
    scene: ctx.path, claim: claim, check: check)

proc note*(ctx: var Ctx, text: string) =
  ctx.board.notes.add ctx.path & ": " & text

# --- derived state, always recomputed --------------------------------------

proc wallAt*(b: Board, x, y: int): bool =
  ## Is there stone at this pixel RIGHT NOW? Glass counts as stone for
  ## movement and bullets; the glazier below is the only thing that cares
  ## about the difference.
  for p in b.placements:
    if inShape(x, y, p.shape):
      return true
  false

proc opaqueAt*(b: Board, x, y: int): bool =
  ## Stone that also blocks SIGHT. A window is not opaque.
  for p in b.placements:
    if not p.shape.window and inShape(x, y, p.shape):
      return true
  false

proc rectClear*(b: Board, r: MapRect, step = 4): bool =
  ## No existing obstacle inside this rectangle (sampled).
  var y = r.y
  while y < r.y + r.h:
    var x = r.x
    while x < r.x + r.w:
      if b.wallAt(x, y): return false
      x += step
    y += step
  true

proc rectUnprotected*(b: Board, r: MapRect, step = 8): bool =
  ## True when NO pixel of this rectangle sits on protected floor. A wall
  ## drawn on protected floor is silently erased by the carve, so a structure
  ## that fails this test cannot keep any promise it makes about sightlines
  ## or cover. This is a PRECONDITION, checked before the structure is
  ## chosen — not a validator that catches it afterwards.
  var y = r.y
  while y <= r.y + r.h:
    var x = r.x
    while x <= r.x + r.w:
      if b.protectedAt(x, y): return false
      x += step
    x = r.x + r.w
    if b.protectedAt(x, y): return false
    y += step
  y = r.y + r.h
  var x = r.x
  while x <= r.x + r.w:
    if b.protectedAt(x, y): return false
    x += step
  true

# ---------------------------------------------------------------------------
# The driver
# ---------------------------------------------------------------------------

proc selectAreas(ctx: var Ctx, act: ChildAction): seq[Region] =
  if act.full:
    return @[ctx.region]
  var picked: seq[int]
  for i, a in ctx.areas:
    var ok = true
    for t in act.tags:
      if t notin a.tags:
        ok = false
        break
    if ok: picked.add i
  if act.lock.len > 0:
    if act.lock notin ctx.locks:
      ctx.locks[act.lock] = initHashSet[int]()
    picked = picked.filterIt(it notin ctx.locks[act.lock])
  if act.limit > 0 and act.limit < picked.len:
    case act.order
    of ordFirst: picked = picked[0 ..< act.limit]
    of ordRandom:
      ctx.rng.shuffle(picked)
      picked = picked[0 ..< act.limit]
      picked.sort()
  if act.lock.len > 0:
    for i in picked: ctx.locks[act.lock].incl i
  for i in picked: result.add ctx.areas[i]

proc runScene*(scene: Scene, path: string, root: int, region: Region,
               rules: MapRules, board: Board) =
  ## Render one scene, then each declared child on the areas it selects.
  ## Depth-first and strictly ordered, so "this layer runs after that one" is
  ## a readable property of the tree rather than a comment.
  var ctx = Ctx(
    path: path, rng: initRand(streamSeed(root, path)), region: region,
    rules: rules, board: board, locks: initTable[string, HashSet[int]]())
  if scene.render != nil:
    scene.render(ctx)
  var seen = initCountTable[string]()
  for act in scene.children:
    let n = seen.getOrDefault(act.scene.name)
    seen.inc act.scene.name
    let areas = ctx.selectAreas(act)
    for j, area in areas:
      ## The child path names the child SCENE and its occurrence, never the
      ## parent's child index — inserting a new differently-named layer
      ## therefore cannot renumber an existing one's RNG stream.
      let childPath = path & "/" & act.scene.name & "." & $n & ":" & $j
      runScene(act.scene, childPath, root, area, rules, board)

proc checkPostconditions*(b: Board): seq[string] =
  for p in b.posts:
    if not p.check(b):
      result.add p.scene & " broke its promise: " & p.claim

# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------

proc rect(x, y, w, h: int): ArenaShape =
  ArenaShape(kind: shapeRect, rect: MapRect(x: x, y: y, w: w, h: h))

proc glassRect(x, y, w, h: int): ArenaShape =
  ArenaShape(kind: shapeRect, window: true,
             rect: MapRect(x: x, y: y, w: w, h: h))

proc disc(cx, cy, r: int): ArenaShape =
  ArenaShape(kind: shapeDisc, cx: cx, cy: cy, radius: r)

proc ri(r: var Rand, lo, hi: int): int =
  if hi <= lo: lo else: lo + rand(r, hi - lo)

# ---------------------------------------------------------------------------
# Scene: districtPlan — the PARTITION. Renders nothing.
# ---------------------------------------------------------------------------
#
# The direct port of mettagrid's `BSPLayout`, which is the single most
# important idea we never took: a scene that draws NOTHING and only decides
# what the sub-regions ARE. Every structural decision that needs to see the
# whole half-field at once (which districts must break a sightline, how much
# of the cover budget is left) is made HERE, once, and published as tags.

const
  StreetInset = 24     ## px stripped off every leaf; two leaves therefore
                       ## leave a 48px street between their structures, and
                       ## the street network is connected BY CONSTRUCTION
                       ## because it is the complement of the BSP cut lines.
  WallThick = 14
  DoorPx = 44          ## comfortably over the validator's 26px erosion
  MinLeafW = 96
  MinLeafH = 200
    ## Not a taste number. A district must survive being inset by a street on
    ## both sides and STILL fit two non-overlapping doors plus the wall
    ## between them: 2*DoorPx + 3*WallThick + 2*StreetInset = 178. 200 is
    ## that bound with a little slack, and a smaller value silently produced
    ## a partition in which no district could host a structure at all.

proc colonnadeLeaves(r: var Rand, band: MapRect, cols: int,
                     minH: int): seq[MapRect] =
  ## The partition, and the single most load-bearing decision in this file.
  ##
  ## THE THING THAT WENT WRONG FIRST. A plain BSP partition refused every
  ## seed, and it was right to: a horizontal cut that spans the whole domain
  ## leaves a STREET running clear across the half-field, and a street is a
  ## horizontal sightline. The generator was being told, correctly, that its
  ## own street plan was an unshootable-across-map defect.
  ##
  ## So the partition is constrained rather than repaired: columns first,
  ## and each column's horizontal cuts are STAGGERED half a row against its
  ## neighbour. Every row is then either inside some column's structure (and
  ## blocked by it) or in one column's street — where the neighbouring
  ## column is mid-structure. The sightline invariant becomes a property of
  ## the street plan, and the map needs no repair pass at all.
  ##
  ## It also buys the route shape a CTF map wants for free: to cross the
  ## field you must jog in y at every column boundary, which is exactly the
  ## detour the metrics reward and the straight sprint they punish.
  let colW = band.w div cols
  for c in 0 ..< cols:
    let
      x0 = band.x + c * colW
      w = if c == cols - 1: band.x + band.w - x0 else: colW
      rows = max(2, band.h div max(minH, 1))
      pitch = band.h div rows
      ## The stagger: column c is offset by c/cols of a row pitch. This is
      ## the same stratified ladder the hand-authored arena uses for its
      ## pickets — the difference is that here it is load-bearing rather
      ## than decorative, and the plan proves it worked before shipping.
      ## Column 0 is deliberately UNJITTERED. Its first district has to sit
      ## flush against the top of the domain, because the validator's very
      ## first scan row is two pixels below it and nothing else can reach
      ## that far up. Jittering it cost twelve of twelve seeds.
      phase =
        if c == 0: 0
        else: (c * pitch) div cols + ri(r, 0, max(1, pitch div 8))
    var y = band.y
    if phase > 0:
      result.add MapRect(x: x0, y: y, w: w, h: phase)
      y += phase
    while y < band.y + band.h:
      let h = min(pitch + ri(r, -pitch div 8, pitch div 8 + 1),
                  band.y + band.h - y)
      if h < 40:
        ## Absorb a runt tail into the previous district rather than
        ## emitting a district too small to host anything.
        if result.len > 0: result[^1].h += h
        break
      result.add MapRect(x: x0, y: y, w: w, h: h)
      y += h

proc footprintOf(leaf, band: MapRect): MapRect =
  ## The buildable rectangle inside one district. A leaf is inset only on the
  ## edges it SHARES with another leaf — that is what makes the street, and
  ## it is why the street network is connected without anyone checking. On an
  ## edge that is the domain boundary there is no neighbour to make room for,
  ## so the structure runs right up to it. Insetting there instead would
  ## leave a clear lane hugging the map border, which is precisely the row
  ## the sightline validator rejects.
  let
    l = if leaf.x <= band.x + 1: 0 else: StreetInset
    t = if leaf.y <= band.y + 1: 0 else: StreetInset
    r = if leaf.x + leaf.w >= band.x + band.w - 1: 0 else: StreetInset
    b = if leaf.y + leaf.h >= band.y + band.h - 1: 0 else: StreetInset
  MapRect(x: leaf.x + l, y: leaf.y + t,
          w: leaf.w - l - r, h: leaf.h - t - b)

proc districtPlanScene(coverTargetPermille, interiorHalfPx: int): Scene =
  Scene(name: "districtPlan", render: proc(ctx: var Ctx) =
    let
      band = ctx.region.rect
      cols = clamp(band.w div MinLeafW, 2, 3)
      leaves = colonnadeLeaves(ctx.rng, band, cols, MinLeafH)
    ## FEASIBILITY FIRST. A leaf can host a ray-blocking structure only if
    ## its whole footprint is off protected floor — otherwise the carve
    ## deletes the very wall the plan is counting on. Checking this BEFORE
    ## choosing roles is what stops the generator from promising something
    ## the engine will silently take away.
    var
      foot = newSeq[MapRect](leaves.len)
      capable: seq[int]
    for i, leaf in leaves:
      foot[i] = footprintOf(leaf, band)
      if foot[i].w >= 60 and foot[i].h >= 2 * DoorPx + 3 * WallThick and
          ctx.board.rectUnprotected(foot[i]):
        capable.add i

    ## THE Y-COVER. Under mirror symmetry the left half alone must break
    ## every horizontal ray, so the plan picks a set of districts whose
    ## y-extents COVER the validator's scan band. Each such district is
    ## built because it covers rows nothing else covers — that is the
    ## reason, recorded as the `rayblock` tag, and it is the reason the
    ## sightline-repair prosthetic is not needed.
    ##
    ## Classic greedy interval cover: from the current cursor, take the
    ## candidate reaching FURTHEST, not merely the next one that starts in
    ## time. The naive sweep this replaces refused every seed.
    var role = newSeq[string](leaves.len)
    var cursor = max(ctx.board.scanLo, band.y)
    let bandHi = min(ctx.board.scanHi, band.y + band.h)
    while cursor < bandHi:
      var best = -1
      for i in capable:
        if role[i] == "rayblock": continue
        if foot[i].y <= cursor and foot[i].y + foot[i].h > cursor:
          if best < 0 or foot[i].y + foot[i].h > foot[best].y + foot[best].h:
            best = i
      if best < 0:
        ## An honest failure, not a patch: this seed's partition cannot cover
        ## the scan band, so the candidate is refused and best-of-K draws
        ## another. No random diamonds are dropped to make it pass.
        ctx.note "y-cover incomplete, uncovered from y=" & $cursor
        ctx.board.notes.add "REJECT: sightline y-cover unreachable at y=" &
          $cursor
        break
      role[best] = "rayblock"
      cursor = foot[best].y + foot[best].h

    ## Spend what is left of the cover budget on more structure, biggest
    ## leaves first so the map gains architecture rather than confetti.
    proc ringPx(fp: MapRect): int =
      fp.w * fp.h - max(0, fp.w - 2 * WallThick) * max(0, fp.h - 2 * WallThick)
    var wallPx = 0
    for i, r in role:
      if r == "rayblock": wallPx += ringPx(foot[i])
    ## The budget is measured against the validator's OWN interior band (the
    ## half of it this domain is responsible for), not against the domain
    ## rectangle — otherwise the generator aims at a permille the validator
    ## does not compute and lands outside the 42..168 window it must hit.
    let budgetPx = coverTargetPermille * interiorHalfPx div 1000
    var rest = capable.filterIt(role[it].len == 0)
    rest.sort(proc(a, b: int): int =
      cmp(leaves[b].w * leaves[b].h, leaves[a].w * leaves[a].h))
    for i in rest:
      let add = ringPx(foot[i])
      if wallPx + add <= budgetPx:
        role[i] = "rayblock"
        wallPx += add

    ## The areas handed to children are FOOTPRINTS, not leaves: the street
    ## has already been subtracted, so a child cannot accidentally build in
    ## it. A child can only ever be given ground it is allowed to use.
    for i, leaf in leaves:
      var tags = @["district"]
      if role[i].len > 0: tags.add role[i]
      else: tags.add "open"
      if leaf.x + leaf.w >= band.x + band.w - 2: tags.add "seam"
      if leaf.x <= band.x + 2: tags.add "home"
      discard ctx.make(foot[i], tags)
  )

# ---------------------------------------------------------------------------
# Scene: structure — the CONTENT of one district.
# ---------------------------------------------------------------------------
#
# Two archetypes, and BOTH of them block every horizontal ray across their
# own y-extent by construction:
#
#   courtyard — four walls, doors on the west and east faces whose y-bands
#               are DISJOINT. The union of the two side walls therefore
#               covers every row of the footprint, while the two doors make
#               a real through-route. One constraint, two purposes, and the
#               sightline invariant is a property of the geometry rather
#               than of a later scan.
#   bunker    — three walls (a U). Whichever way it opens, at least one full
#               -height side wall survives, so the y-extent is covered.
#
# Reachability is also by construction, and for the same reason mettagrid's
# `compound.py` never needs a flood fill: walls are only ever drawn as thin
# borders, never as fill, so no pocket can be sealed, and the street ring
# around every footprint is guaranteed by `StreetInset`.

proc structureScene(): Scene =
  Scene(name: "structure", render: proc(ctx: var Ctx) =
    let
      fp = ctx.region.rect   ## already the footprint: the plan subtracted
                             ## the street before handing this region over
      t = WallThick
    if fp.w < 60 or fp.h < 2 * DoorPx + 3 * t:
      ctx.note "district too small for a structure"
      return
    let courtyard = fp.w >= 90 and rand(ctx.rng, 1.0) < 0.6
    if courtyard:
      ## Door bands, chosen disjoint. The gap between them is the wall that
      ## breaks the ray; the doors themselves are the route.
      let
        span = fp.h - 2 * t
        slack = span - 2 * DoorPx
        a = t + ri(ctx.rng, 0, max(1, slack div 3))
        b = a + DoorPx + ri(ctx.rng, max(8, slack div 3), max(9, slack))
        westLo = fp.y + a
        eastLo = fp.y + min(b, fp.h - t - DoorPx)
      doAssert westLo + DoorPx <= eastLo, "west and east doors must not align"
      ctx.place rect(fp.x, fp.y, fp.w, t), "courtyard north wall"
      ctx.place rect(fp.x, fp.y + fp.h - t, fp.w, t), "courtyard south wall"
      ctx.place rect(fp.x, fp.y, t, westLo - fp.y), "west wall above the door"
      ctx.place rect(fp.x, westLo + DoorPx, t, fp.y + fp.h - westLo - DoorPx),
        "west wall below the door"
      ctx.place rect(fp.x + fp.w - t, fp.y, t, eastLo - fp.y),
        "east wall above the door"
      ctx.place rect(fp.x + fp.w - t, eastLo + DoorPx, t,
                     fp.y + fp.h - eastLo - DoorPx), "east wall below the door"
      ctx.board.rayCover.add (fp.y, fp.y + fp.h)
    else:
      let dir = ctx.rng.rand(3)
      ctx.place rect(fp.x, fp.y, fp.w, t), "bunker north wall"
      ctx.place rect(fp.x, fp.y + fp.h - t, fp.w, t), "bunker south wall"
      if dir != 0: ctx.place rect(fp.x, fp.y, t, fp.h), "bunker west wall"
      if dir != 1:
        ctx.place rect(fp.x + fp.w - t, fp.y, t, fp.h), "bunker east wall"
      ctx.board.rayCover.add (fp.y, fp.y + fp.h)
  )

# ---------------------------------------------------------------------------
# Scene: plaza — an OPEN district still earns a little cover.
# ---------------------------------------------------------------------------

proc plazaScene(): Scene =
  Scene(name: "plaza", render: proc(ctx: var Ctx) =
    let fp = ctx.region.rect
    if fp.w < 60 or fp.h < 60: return
    ## Two or three pieces of hard cover, sized from the rules rather than
    ## from a magic number, placed so the open ground is crossable but not
    ## naked. They make no sightline claim and are not counted on for one.
    let n = 1 + ctx.rng.rand(2)
    for _ in 0 ..< n:
      let
        rad = max(18, ctx.rules.coverSizePx div 2 - ctx.rng.rand(10))
        cx = fp.x + rad + ctx.rng.rand(max(1, fp.w - 2 * rad))
        cy = fp.y + rad + ctx.rng.rand(max(1, fp.h - 2 * rad))
      if ctx.board.rectUnprotected(MapRect(x: cx - rad, y: cy - rad,
                                           w: 2 * rad, h: 2 * rad)):
        ctx.place disc(cx, cy, rad), "plaza cover"
  )

# ---------------------------------------------------------------------------
# Scene: standApron — cover on the APPROACH to the pedestal.
# ---------------------------------------------------------------------------
#
# The measured defect this exists to fix: the current pool's stands sit in
# the open (standCover median 1.1% against the arena's 7.2%, standRingOpen
# 93.6-100% against the arena's 89.2%). The engine protects the floor right
# around a pedestal, so the only place cover CAN go is the annulus just
# outside the protected column — which is exactly where an attacker has to
# stand. Every piece here is placed in that annulus and nowhere else.

proc standApronScene(anchor: MapPoint, innerPx, outerPx: int): Scene =
  Scene(name: "standApron", render: proc(ctx: var Ctx) =
    var placed = 0
    for i in 0 ..< 14:
      if placed >= 5: break
      let
        ang = rand(ctx.rng, TAU)
        rad = innerPx + ctx.rng.rand(max(1, outerPx - innerPx))
        cx = anchor.x + int(cos(ang) * float(rad))
        cy = anchor.y + int(sin(ang) * float(rad))
        pr = 26 + ctx.rng.rand(16)
        box = MapRect(x: cx - pr, y: cy - pr, w: 2 * pr, h: 2 * pr)
      if box.x < ctx.region.rect.x or
          box.x + box.w > ctx.region.rect.x + ctx.region.rect.w or
          box.y < ctx.region.rect.y or
          box.y + box.h > ctx.region.rect.y + ctx.region.rect.h: continue
      if not ctx.board.rectUnprotected(box): continue
      if not ctx.board.rectClear(box): continue
      ctx.place disc(cx, cy, pr), "cover on the stand approach"
      inc placed
    if placed == 0: ctx.note "no room in the stand annulus"
  )

# ---------------------------------------------------------------------------
# Scene: centralBastion — cover at the COLLISION POINT.
# ---------------------------------------------------------------------------
#
# `collisionCoverRatio` is arena 1.46 against a pool median of 0.83: today
# the two teams meet in the most naked part of the map. On a 2-team sides
# board the collision point is the centre, so this scene builds a structure
# in the flag-ring annulus, on the seam, where the mirror completes it into
# one central feature.

proc centralBastionScene(center: MapPoint, ringPx: int): Scene =
  Scene(name: "centralBastion", render: proc(ctx: var Ctx) =
    let
      band = ctx.region.rect
      t = WallThick
      gap = ringPx + 26
    for sign in [-1, 1]:
      let
        armH = max(70, band.h div 6)
        cy = center.y + sign * (gap + armH div 2)
        y0 = cy - armH div 2
        x0 = band.x + 10
        w = band.w - 20
      if y0 < band.y or y0 + armH > band.y + band.h: continue
      let box = MapRect(x: x0, y: y0, w: w, h: armH)
      if not ctx.board.rectUnprotected(box): continue
      ## A hook opening toward the centre: the wall that faces midfield is
      ## solid (so it is real cover for whoever holds it), and the arm that
      ## reaches back toward the seam gives the holder a lane to fall into.
      ctx.place rect(x0, if sign < 0: y0 else: y0 + armH - t, w, t),
        "bastion face toward midfield"
      ctx.place rect(x0, y0, t, armH), "bastion flank"
      ctx.board.rayCover.add (y0, y0 + armH)
  )

# ---------------------------------------------------------------------------
# Scene: glazier — glass ONLY where there is something to see through it.
# ---------------------------------------------------------------------------
#
# This scene is the direct answer to the live "walls in front of glass"
# defect. Three properties, each of which the current two-pass arrangement
# lacks:
#
#   * It runs LAST among wall-affecting scenes, so the wall set it measures
#     is the final one. There is no later pass that can park something in
#     front of it, because the sightline-repair pass does not exist.
#   * It measures the affordance instead of assuming it: a pane is glazed
#     only if a ray fired through it actually reaches open ground on both
#     sides. No sightline, no glass.
#   * It registers a POST-CONDITION carrying that same ray. If any future
#     scene ever does block it, the driver fails the map by name instead of
#     shipping a pointless window.

proc rayClear(b: Board, x0, y0, dx, dy, len: int, skip: int): bool =
  var i = skip
  while i <= len:
    let
      x = x0 + dx * i
      y = y0 + dy * i
    if x < 0 or y < 0 or x >= b.width or y >= b.height: return true
    if b.opaqueAt(x, y): return false
    inc i
  true

proc glazierScene(maxPanes: int): Scene =
  Scene(name: "glazier", render: proc(ctx: var Ctx) =
    var candidates: seq[int]
    for i, p in ctx.board.placements:
      if p.shape.kind == shapeRect and not p.shape.window and
          p.serves.contains("wall") and p.shape.rect.w <= 2 * WallThick and
          p.shape.rect.h >= 60:
        candidates.add i
    ctx.rng.shuffle(candidates)
    var glazed = 0
    for idx in candidates:
      if glazed >= maxPanes: break
      let
        r = ctx.board.placements[idx].shape.rect
        paneH = min(64, r.h - 24)
      if paneH < 40: continue
      let
        py = r.y + (r.h - paneH) div 2
        midY = py + paneH div 2
        west = r.x - 1
        east = r.x + r.w
      ## Measure the affordance: is there open ground to see on both sides?
      if not ctx.board.rayClear(west, midY, -1, 0, 220, 1): continue
      if not ctx.board.rayClear(east, midY, 1, 0, 220, 1): continue
      ## Split the host wall around the pane and glaze the gap.
      ctx.board.placements[idx].shape = rect(r.x, r.y, r.w, py - r.y)
      ctx.place rect(r.x, py + paneH, r.w, r.y + r.h - py - paneH),
        "wall below a glazed pane"
      ctx.place glassRect(r.x, py, r.w, paneH),
        "glass over a measured sightline"
      inc glazed
      let (wx, ex, my) = (west, east, midY)
      ctx.promise("glass at " & $r.x & "," & $my & " still sees through", proc(
          b: Board): bool =
        b.rayClear(wx, my, -1, 0, 180, 1) and b.rayClear(ex, my, 1, 0, 180, 1))
  )

# ---------------------------------------------------------------------------
# Composition
# ---------------------------------------------------------------------------

proc ctfTwoTeamScene*(gameMap: CtfMap,
                      coverTargetPermille, interiorHalfPx: int): Scene =
  ## The whole 2-team map as ONE tree. Read top to bottom, this IS the map's
  ## design intent in order — which is the thing the current 590-line
  ## imperative generator cannot show you at any length.
  ##
  ##   ctf2                       names the three regions of a half-field
  ##     districtPlan  (field)    partitions, and decides which districts
  ##       structure   (rayblock) must break a sightline / may hold cover
  ##       plaza       (open)
  ##     centralBastion (seam)    cover where the two teams actually meet
  ##     standApron     (apron)   cover on the approach to the pedestal
  ##     glazier        (field)   glass, last, only where sight exists
  let
    anchor = gameMap.teamAnchor(Red)
    center = gameMap.center
    ring = gameMap.flagRing
    border = ArenaBorder
    height = gameMap.height
    ## The field stops short of the spawn pocket and of the flag ring. Both
    ## are protected floor: a wall there is deleted by the carve, so a
    ## district that straddled them could not keep the sightline promise the
    ## plan makes on its behalf. The domain is trimmed so the promise is
    ## always keepable, rather than trimmed later by a validator.
    fieldX0 = max(gameMap.captureClear + 4,
                  anchor.x + gameMap.spawnClearW + 8)
    fieldX1 = center.x - ring - 26
    plan = districtPlanScene(coverTargetPermille, interiorHalfPx)
  plan.children = @[
    ChildAction(tags: @["district", "rayblock"], scene: structureScene()),
    ChildAction(tags: @["district", "open"], scene: plazaScene()),
  ]
  result = Scene(name: "ctf2",
    render: proc(ctx: var Ctx) =
      discard ctx.make(MapRect(x: fieldX0, y: border, w: fieldX1 - fieldX0,
                               h: height - 2 * border), "field")
      discard ctx.make(MapRect(x: fieldX1, y: border, w: center.x - fieldX1,
                               h: height - 2 * border), "seam")
      discard ctx.make(MapRect(x: border, y: border, w: center.x - border,
                               h: height - 2 * border), "apron"),
    children: @[
      ChildAction(tags: @["field"], scene: plan),
      ChildAction(tags: @["seam"], scene: centralBastionScene(center, ring)),
      ChildAction(tags: @["apron"], scene: standApronScene(
        anchor, gameMap.captureClear - anchor.x + 24, 200)),
      ChildAction(tags: @["field"], scene: glazierScene(3)),
    ])

type GraphResult* = object
  gameMap*: CtfMap
  board*: Board
  rejected*: bool
  reason*: string

proc generateGraphMap*(seed: int, sizeName = "standard",
                       coverTargetPermille = 120): GraphResult =
  ## Borrow the SHELL (board size, clearances, endzone, pedestals) from the
  ## existing generator, then replace its terrain wholesale with the scene
  ## tree. Reusing the shell is deliberate for a prototype: it keeps the
  ## comparison honest, because the only thing that differs between the
  ## measured numbers below and the current generator's is the terrain.
  var gameMap = generateMapAttempt(seed, MapGenOverrides(
    windows: 0, pits: 0, pitDensity: 0, size: sizeName,
    symmetry: "mirror", endzone: "column"), 2)
  gameMap.name = "graph-" & $seed
  gameMap.leftObstacles = @[]
  gameMap.trenches = @[]

  let
    shell = gameMap
    board = Board(
      width: gameMap.width, height: gameMap.height, center: gameMap.center,
      scanLo: ArenaBorder + 2, scanHi: gameMap.height - ArenaBorder,
      protectedAt: proc(x, y: int): bool = shell.mapProtectedFloorAt(x, y))
    ## The FUNDAMENTAL DOMAIN: the left half. Every scene runs inside it and
    ## nothing here knows about the lift — `buildArenaObstacles` mirrors the
    ## result downstream, exactly as it does for the current generator, so
    ## team fairness is structural rather than checked.
    domain = Region(
      rect: MapRect(x: 0, y: 0, w: gameMap.width div 2, h: gameMap.height),
      tags: @["domain"])
    rules = mapRules(sizeName, 2)
    ## The half-share of the band the validator actually computes its cover
    ## permille over.
    interiorHalfPx = (gameMap.width - 2 * gameMap.captureClear) *
      (gameMap.height - 2 * ArenaBorder) div 2
  runScene(ctfTwoTeamScene(gameMap, coverTargetPermille, interiorHalfPx),
           "root", seed, domain, rules, board)

  for p in board.placements:
    gameMap.leftObstacles.add p.shape

  ## Pickups: put them back on floor the terrain actually left open.
  var kits: seq[MapPoint]
  for pt in gameMap.medKitCandidates:
    var best = pt
    block find:
      for radius in countup(0, 240, 12):
        for a in 0 ..< 16:
          let
            ang = TAU * float(a) / 16.0
            x = pt.x + int(cos(ang) * float(radius))
            y = pt.y + int(sin(ang) * float(radius))
          if x < ArenaBorder or y < ArenaBorder or
              x >= gameMap.width - ArenaBorder or
              y >= gameMap.height - ArenaBorder: continue
          if not mapWallAt(gameMap, buildArenaObstacles(gameMap), x, y):
            best = MapPoint(x: x, y: y)
            break find
    kits.add best
  gameMap.medKitCandidates = kits
  gameMap.medKitSpawns =
    if kits.len >= 2: @[kits[0], kits[1]] else: kits

  result = GraphResult(gameMap: gameMap, board: board)
  for n in board.notes:
    if n.startsWith("REJECT"):
      result.rejected = true
      result.reason = n
  let broken = board.checkPostconditions()
  if broken.len > 0:
    result.rejected = true
    result.reason = broken[0]
