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
    trenches*: seq[Placement]
      ## A SEPARATE channel from `placements`, because a trench is not a wall:
      ## it blocks no ray and no bullet — it is walkable floor that makes its
      ## occupant hard to hit (`TrenchMissPct`) but slow to fire and costly to
      ## leave. It lives on its own list for two reasons. First, the ledger
      ## must be able to say a trench serves something a wall never could
      ## ("a survivable holdpoint that does not shorten a sightline",
      ## `map_rules.trenchSharePermille`). Second, and load-bearing:
      ## `buildArenaObstacles` mirrors `leftObstacles` but NOT `gameMap.trenches`
      ## (the trench field is stored already-symmetrized — see `mapSpecJson`),
      ## so a trench dug here in the left-half domain must be mirrored EXPLICITLY
      ## downstream. Keeping it off `placements` is what stops the wall-mirror
      ## from double-imaging it.
    posts*: seq[Postcondition]
    notes*: seq[string]
    rayCover*: seq[(int, int)]     ## y intervals a structure provably blocks
    protectedAt*: proc(x, y: int): bool {.closure.}
    budgetPx*, spentPx*: int
      ## The cover budget is a resource SHARED by every scene, so it lives on
      ## the board and is debited by `place`, not owned by whichever scene
      ## happened to think about it. The first version made it a parameter of
      ## the district plan alone; the plan then stayed inside its budget while
      ## the bastion, the plazas and the apron spent on top of it, and two of
      ## forty seeds shipped over the validator's 170-permille ceiling. A
      ## budget that only one of five spenders can see is not a budget.

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

proc areaOf(s: ArenaShape): int =
  case s.kind
  of shapeRect: max(0, s.rect.w) * max(0, s.rect.h)
  of shapeDisc: int(3.1416 * float(s.radius * s.radius))
  of shapeDiamond: 2 * s.radius * s.radius
  else: 0

proc place*(ctx: var Ctx, shape: ArenaShape, serves: string) =
  ## Write one obstacle. `serves` is mandatory: the ledger is what makes
  ## "placed but pointless" auditable after the fact. Every write debits the
  ## shared cover budget, so no scene can overspend one it never read.
  doAssert serves.len > 0, "every placement must name what it serves"
  ctx.board.placements.add Placement(
    shape: shape, scene: ctx.path, serves: serves)
  ctx.board.spentPx += areaOf(shape)

proc dig*(ctx: var Ctx, square: MapRect, serves: string) =
  ## Write one TRENCH. Same audit contract as `place` — `serves` is mandatory —
  ## but a trench goes on its own channel and is DELIBERATELY NOT debited
  ## against the wall cover budget: it delivers survivability without spending
  ## sightline, which is the whole reason `map_rules` gives trenches a separate
  ## share of the cover total. A trench that cost wall-budget would make the
  ## generator choose between the two exactly where the doctrine says it should
  ## not have to.
  doAssert serves.len > 0, "every trench must name what it serves"
  ctx.board.trenches.add Placement(
    shape: ArenaShape(kind: shapeRect, rect: square),
    scene: ctx.path, serves: serves)

proc budgetLeft*(b: Board): int = b.budgetPx - b.spentPx

proc canAfford*(b: Board, px: int): bool =
  b.budgetPx <= 0 or b.spentPx + px <= b.budgetPx

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

proc rayClear*(b: Board, x0, y0, dx, dy, len: int, skip: int): bool =
  ## Straight-line occlusion test against the CURRENT wall set. Lives here,
  ## with the other derived state, because both the structure scenes and the
  ## glazier make promises in terms of it.
  var i = skip
  while i <= len:
    let
      x = x0 + dx * i
      y = y0 + dy * i
    if x < 0 or y < 0 or x >= b.width or y >= b.height: return true
    if b.opaqueAt(x, y): return false
    inc i
  true

proc hasAperture*(b: Board, box: MapRect, thick: int): bool =
  ## Is there a gap anywhere in this structure's wall ring? Walked along the
  ## CENTRELINE of each of the four walls, so a door shows up as open samples
  ## wherever it happens to sit.
  ##
  ## The first version of this promise fired a ray from the footprint's exact
  ## centre along each axis, and rejected every seed: a courtyard's doors are
  ## a band on the side wall, and the centre row almost never lines up with
  ## one. A reachability test has to look for the aperture, not guess where
  ## it is.
  let
    h = thick div 2
    x0 = box.x + h
    x1 = box.x + box.w - 1 - h
    y0 = box.y + h
    y1 = box.y + box.h - 1 - h
  var i = y0
  while i <= y1:
    if not b.wallAt(x0, i) or not b.wallAt(x1, i): return true
    inc i, 2
  i = x0
  while i <= x1:
    if not b.wallAt(i, y0) or not b.wallAt(i, y1): return true
    inc i, 2
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

proc trenchSquare(cx, cy: int): MapRect =
  ## A `TrenchSize`×`TrenchSize` pit centred on (cx, cy). Mirrors arena's own
  ## (unexported) `trenchSquareAt` — a trench never scales with the size class,
  ## so this is the whole definition.
  MapRect(x: cx - TrenchSize div 2, y: cy - TrenchSize div 2,
          w: TrenchSize, h: TrenchSize)

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
  DistrictBudgetShare = 74
    ## Percent of the shared cover budget the district plan may claim. The
    ## remainder is what the bastion, the plazas and the stand apron spend.
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
    ## The budget is the board's, measured against the validator's OWN
    ## interior band — not against the domain rectangle, or the generator
    ## aims at a permille the validator never computes. The plan may claim
    ## only part of it; the rest is left for the scenes that run after it,
    ## which is the fix for the two "too clogged" seeds.
    let budgetPx = ctx.board.budgetPx * DistrictBudgetShare div 100
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
      ## North and south doors too. They cost the sightline claim NOTHING —
      ## that claim rests on the union of the west and east side walls — and
      ## they make the courtyard a through-route on both axes instead of a
      ## corridor with two ends. Adding them cut stranded floor from 2.59% to
      ## the number in the report.
      let
        nDoor = fp.x + t + ri(ctx.rng, 0, max(1, fp.w - 2 * t - DoorPx))
        sDoor = fp.x + t + ri(ctx.rng, 0, max(1, fp.w - 2 * t - DoorPx))
      ctx.place rect(fp.x, fp.y, nDoor - fp.x, t), "courtyard north wall"
      ctx.place rect(nDoor + DoorPx, fp.y, fp.x + fp.w - nDoor - DoorPx, t),
        "courtyard north wall past the door"
      ctx.place rect(fp.x, fp.y + fp.h - t, sDoor - fp.x, t),
        "courtyard south wall"
      ctx.place rect(sDoor + DoorPx, fp.y + fp.h - t,
                     fp.x + fp.w - sDoor - DoorPx, t),
        "courtyard south wall past the door"
      ctx.place rect(fp.x, fp.y, t, westLo - fp.y), "west wall above the door"
      ctx.place rect(fp.x, westLo + DoorPx, t, fp.y + fp.h - westLo - DoorPx),
        "west wall below the door"
      ctx.place rect(fp.x + fp.w - t, fp.y, t, eastLo - fp.y),
        "east wall above the door"
      ctx.place rect(fp.x + fp.w - t, eastLo + DoorPx, t,
                     fp.y + fp.h - eastLo - DoorPx), "east wall below the door"
      ctx.board.rayCover.add (fp.y, fp.y + fp.h)
    else:
      ## A U opens on EXACTLY ONE side. The first version omitted a side only
      ## for two of the four `dir` values and placed all four walls for the
      ## other two — a sealed box, which the sim validator happily accepts
      ## because it only demands that the flags and the centre connect. Three
      ## of eight seeds stranded floor, up to 7.74% of the board (40,248 px)
      ## against the arena's 0.00%. That is the exact "placed but pointless"
      ## failure this design exists to prevent, committed by the design's own
      ## prototype: "thin borders, never fill" is necessary for reachability
      ## but NOT sufficient, and the aperture has to be an explicit promise
      ## rather than an assumed side effect.
      ##
      ## The opening never faces west or east: the y-cover is claimed against
      ## a full-height side wall, so removing one would break a promise the
      ## plan has already made on this district's behalf.
      let openNorth = ctx.rng.rand(1) == 0
      if not openNorth:
        ctx.place rect(fp.x, fp.y, fp.w, t), "bunker north wall"
      ctx.place rect(fp.x, fp.y, t, fp.h), "bunker west wall"
      ctx.place rect(fp.x + fp.w - t, fp.y, t, fp.h), "bunker east wall"
      if openNorth:
        ctx.place rect(fp.x, fp.y + fp.h - t, fp.w, t), "bunker south wall"
      ctx.board.rayCover.add (fp.y, fp.y + fp.h)
    ## Every structure promises its own interior keeps a way in, and the
    ## driver re-checks that after the WHOLE tree has rendered — so a later
    ## scene that parks something across the aperture fails the map by name
    ## instead of shipping a room nobody can enter.
    let box = fp
    ctx.promise("the structure at " & $box.x & "," & $box.y &
                " still has a way in", proc(b: Board): bool =
      b.hasAperture(box, WallThick))
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
      if ctx.board.canAfford(3 * rad * rad) and
          ctx.board.rectUnprotected(MapRect(x: cx - rad, y: cy - rad,
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
      if not ctx.board.canAfford(3 * pr * pr): continue
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
      if not ctx.board.canAfford(w * t + t * armH): continue
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
# Scene: forwardTrench — a SURVIVABLE HOLDPOINT overlooking the approach.
# ---------------------------------------------------------------------------
#
# Maxwell named trenches as the archetype of the "why is this here" problem,
# and the scene-graph prototype's answer so far was to delete them wholesale
# (`generateGraphMap` clears `gameMap.trenches`). That forfeits the one piece
# of cover the range/mixed doctrine calls indispensable: `map_rules`'
# `trenchSharePermille` gives trenches 250–500 permille of the WHOLE cover
# budget precisely because a trench "gives survivability WITHOUT shortening a
# sightline" — it is the only cover that is free where short sightlines are the
# disease. A wall that would deliver the same survivability would also blind
# the defender who stands behind it.
#
# So a trench is placed for exactly one reason, and it is checkable: a defender
# on our side of the field needs a place to HOLD the lane an attacker must
# cross to reach our flag — a spot that keeps them alive under fire (the pit)
# WHILE they can still see and shoot down that lane (the overlook). A trench
# that overlooks a wall is the "placed but pointless" defect in trench form, so
# the overlook is measured before the dig and PROMISED afterwards: the sightline
# toward midfield must survive every later scene, or the map fails by name.
#
# The trench sits on the forward third of the field (nearest the seam), on open
# floor the districts left crossable — which is where the fight for the flag
# actually happens, and where the pool's stands sit naked today.

proc trenchClear(b: Board, sq: MapRect): bool =
  ## A trench square must be dug in floor: clear of every wall, off protected
  ## floor (the carve would delete a pit on it just as it deletes a wall), and
  ## not overlapping a trench already dug. Sampled on a coarse grid — a trench
  ## is 56px, so an 8px step cannot miss a wall wide enough to matter.
  if not b.rectUnprotected(sq, 8): return false
  var y = sq.y
  while y <= sq.y + sq.h:
    var x = sq.x
    while x <= sq.x + sq.w:
      if b.wallAt(x, y): return false
      x += 8
    y += 8
  for t in b.trenches:
    let r = t.shape.rect
    if sq.x < r.x + r.w and r.x < sq.x + sq.w and
        sq.y < r.y + r.h and r.y < sq.y + sq.h:
      return false
  true

proc forwardTrenchScene(fieldX1, overlookPx, maxDig: int): Scene =
  ## Runs on the whole field region. `fieldX1` is the seam-side edge of the
  ## buildable field — "forward" is the third of the field nearest it, the
  ## ground a defender falls back to and an attacker has to cross last.
  Scene(name: "forwardTrench", render: proc(ctx: var Ctx) =
    let
      band = ctx.region.rect
      half = TrenchSize div 2
      ## The forward third: [x0, fieldX1). A defender here overlooks midfield
      ## (east, +x) — the direction every attacker on our flag comes from.
      x0 = max(band.x + half, fieldX1 - (band.w div 3))
      x1 = min(band.x + band.w - half, fieldX1)
    if x1 <= x0: return
    var dug = 0
    for _ in 0 ..< 40:
      if dug >= maxDig: break
      let
        cx = ri(ctx.rng, x0, x1)
        cy = ri(ctx.rng, band.y + half, band.y + band.h - half)
        sq = trenchSquare(cx, cy)
      if sq.x < band.x or sq.x + sq.w > band.x + band.w or
          sq.y < band.y or sq.y + sq.h > band.y + band.h: continue
      if not ctx.board.trenchClear(sq): continue
      ## MEASURE THE OVERLOOK before committing: fire east from the pit's
      ## centre. If the ray hits a wall before it clears `overlookPx`, this
      ## spot overlooks nothing and the defender in it is blind — skip it.
      let
        eye = cx + half + 1
        my = cy
      if not ctx.board.rayClear(eye, my, 1, 0, overlookPx, 1): continue
      ctx.dig sq, "survivable holdpoint overlooking the approach to our flag"
      inc dug
      ## PROMISE the overlook outlives every later scene. A wall parked across
      ## it afterwards turns the trench back into pointless cover, and the
      ## driver must catch that by name rather than ship it.
      let (ex, ey) = (eye, my)
      ctx.promise("trench at " & $cx & "," & $cy &
                  " still overlooks the approach", proc(b: Board): bool =
        b.rayClear(ex, ey, 1, 0, overlookPx, 1))
    if dug == 0: ctx.note "no forward spot both open and overlooking midfield"
  )

# ---------------------------------------------------------------------------
# Scene: crossfireCover — cover that BREAKS THE LONGEST OPEN RAY of a plaza.
# ---------------------------------------------------------------------------
#
# `plaza cover` is the single most-placed feature in the ledger (26 of ~44
# per-map placements) and, by its own comment, the least intentional: it drops
# "1–3 pieces of hard cover" at random positions and "make[s] no sightline
# claim". That is the exact defect this whole design exists to retire, living
# inside the design's own prototype — a feature placed because a loop reached
# it, with no reason that can be checked.
#
# The reason a plaza needs cover is specific: an OPEN district (the plan did
# not count on it to break a ray) still has a longest open sightline running
# across it, and that line is a shooting gallery — naked ground a defender
# rakes from one end. Cover exists to break THAT line, so the plaza can be
# crossed under fire instead of sprinted across in the open. So the piece is
# placed on the longest open ray the plaza has, and it PROMISES that ray is
# occluded afterwards. Cover that breaks no measured line is not written.

proc crossfireCoverScene(): Scene =
  Scene(name: "crossfireCover", render: proc(ctx: var Ctx) =
    let fp = ctx.region.rect
    if fp.w < 60 or fp.h < 60: return
    ## Find the longest open HORIZONTAL ray across the plaza: scan candidate
    ## rows, measure the clear span each offers, keep the widest. A horizontal
    ## ray is the one the sightline validator itself fires, so breaking it is
    ## breaking the line the map is actually judged on.
    const ScanStep = 6
    var
      bestY = -1
      bestSpan = 0     ## in PIXELS, not scan steps
    var y = fp.y + 8
    while y < fp.y + fp.h - 8:
      var span = 0
      var x = fp.x
      while x < fp.x + fp.w:
        if ctx.board.wallAt(x, y): span = 0
        else: span += ScanStep
        if span > bestSpan and not ctx.board.protectedAt(x, y):
          bestSpan = span
          bestY = y
        x += ScanStep
      y += 12
    ## No open ray worth breaking (a plaza already broken up by neighbouring
    ## structure) needs no cover — and saying so is the point of the ledger.
    if bestY < 0 or bestSpan < 40:
      ctx.note "plaza has no open ray long enough to be worth breaking"
      return
    let
      rad = max(20, ctx.rules.coverSizePx div 2 - ctx.rng.rand(8))
      ## Break the ray nearer its middle than its ends: cover hugging a wall
      ## just widens the wall, while cover mid-span forces the crosser to
      ## choose a side and creates the two peek angles a crossfire wants.
      cx = clamp(fp.x + fp.w div 2 + ctx.rng.rand(fp.w div 4) - fp.w div 8,
                 fp.x + rad, fp.x + fp.w - rad)
      cy = bestY
      box = MapRect(x: cx - rad, y: cy - rad, w: 2 * rad, h: 2 * rad)
    if not ctx.board.canAfford(3 * rad * rad): return
    if not ctx.board.rectUnprotected(box): return
    if not ctx.board.rectClear(box): return
    ## Cover that breaks a ray must not, in doing so, PINCH the route it sits
    ## on into a kill box — a narrow slot beside a wall down which the broken
    ## sightline simply re-forms is worse than the open ray it replaced. So the
    ## disc is placed only where it keeps open floor above and below it (the two
    ## ways a crosser goes AROUND it): the box grown by a safe margin in y must
    ## still be clear of every wall. A plaza with no such room is left open and
    ## says so, rather than shipping the pinch. The margin is set ABOVE the
    ## validator's own kill-box floor (it rejects a route ~48px wide holding a
    ## long sightline, and a corridor's safe floor is ~68px) so a gap this scene
    ## leaves is one a player can clear alive, not one the validator then flags.
    const PinchSafePx = 76
    let apron = MapRect(x: box.x, y: box.y - PinchSafePx,
                        w: box.w, h: box.h + 2 * PinchSafePx)
    if not ctx.board.rectClear(apron):
      ctx.note "plaza's longest ray has no room to be broken without a pinch"
      return
    ctx.place disc(cx, cy, rad),
      "cover breaking the plaza's longest open sightline"
    ## A second, smaller piece offset in y turns a single blocker into a
    ## stagger — two angles, not one wall — but only if it too lands on floor.
    let
      rad2 = max(16, rad - 8 - ctx.rng.rand(6))
      cy2 = clamp(cy + (if ctx.rng.rand(1) == 0: -1 else: 1) *
                    (rad + rad2 + 12), fp.y + rad2, fp.y + fp.h - rad2)
      box2 = MapRect(x: cx - rad2, y: cy2 - rad2, w: 2 * rad2, h: 2 * rad2)
    if ctx.board.canAfford(3 * rad2 * rad2) and
        ctx.board.rectUnprotected(box2) and ctx.board.rectClear(box2):
      ctx.place disc(cx, cy2, rad2), "plaza crossfire stagger"
    ## PROMISE the ray we came to break is broken and stays broken.
    let (ry, rx0, rlen) = (cy, fp.x, fp.w)
    ctx.promise("plaza ray at y=" & $ry & " is broken", proc(b: Board): bool =
      not b.rayClear(rx0, ry, 1, 0, rlen, 0))
  )

# ---------------------------------------------------------------------------
# Composition
# ---------------------------------------------------------------------------

proc vandalScene(): Scene =
  ## NEGATIVE CONTROL, and the only reason the post-condition machinery can
  ## be trusted. A guard that has never once fired is indistinguishable from
  ## a guard that cannot fire, so this scene exists to break the glazier's
  ## promise on purpose: it parks a slab of stone directly in front of every
  ## pane, which is exactly the live `arena.nim` defect (a repair diamond
  ## dropped in front of a window a previous pass glazed). It is wired in
  ## only by `generateGraphMap(breakGlass = true)`; `tests/test_mapgen_graph`
  ## asserts that turning it on turns the failure ON.
  Scene(name: "vandal", render: proc(ctx: var Ctx) =
    var panes: seq[MapRect]
    for p in ctx.board.placements:
      if p.shape.window and p.shape.kind == shapeRect:
        panes.add p.shape.rect
    for r in panes:
      ctx.place rect(r.x - 40, r.y - 10, 16, r.h + 20),
        "a slab parked in front of a window"
  )

proc ctfTwoTeamScene*(gameMap: CtfMap,
                      coverTargetPermille, interiorHalfPx: int,
                      breakGlass = false, intentional = false): Scene =
  ## The whole 2-team map as ONE tree. Read top to bottom, this IS the map's
  ## design intent in order — which is the thing the current 590-line
  ## imperative generator cannot show you at any length.
  ##
  ##   ctf2                       names the three regions of a half-field
  ##     districtPlan  (field)    partitions, and decides which districts
  ##       structure   (rayblock) must break a sightline / may hold cover
  ##       plaza/crossfire (open) open ground earns cover for a REASON
  ##     centralBastion (seam)    cover where the two teams actually meet
  ##     standApron     (apron)   cover on the approach to the pedestal
  ##     glazier        (field)   glass, last, only where sight exists
  ##     forwardTrench  (field)   a survivable holdpoint on our approach
  ##
  ## `intentional` swaps the two features whose placement carried no checkable
  ## reason for two that do: the random `plaza` cover becomes `crossfireCover`
  ## (placed on, and promising to break, the plaza's longest open ray), and a
  ## `forwardTrench` layer digs the trenches the prototype had been deleting —
  ## each dug only where it overlooks the approach it exists to hold. Left off,
  ## the tree is bit-identical to the prototype the report measures against.
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
    openScene = if intentional: crossfireCoverScene() else: plazaScene()
  plan.children = @[
    ChildAction(tags: @["district", "rayblock"], scene: structureScene()),
    ChildAction(tags: @["district", "open"], scene: openScene),
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
  if intentional:
    ## Runs LAST among field scenes, after the walls and glass are final, so a
    ## trench is only dug where the overlook survives everything placed before
    ## it — and its post-condition then guards it against anything after.
    result.children.add ChildAction(tags: @["field"],
      scene: forwardTrenchScene(fieldX1, GunRange div 3, 3))
  if breakGlass:
    result.children.add ChildAction(tags: @["field"], scene: vandalScene())

type GraphResult* = object
  gameMap*: CtfMap
  board*: Board
  rejected*: bool
  reason*: string

proc generateGraphMap*(seed: int, sizeName = "standard",
                       coverTargetPermille = 180,
                       breakGlass = false, intentional = false): GraphResult =
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
      protectedAt: proc(x, y: int): bool = shell.mapProtectedFloorAt(x, y),
      budgetPx: coverTargetPermille *
        ((gameMap.width - 2 * gameMap.captureClear) *
         (gameMap.height - 2 * ArenaBorder) div 2) div 1000)
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
  runScene(ctfTwoTeamScene(gameMap, coverTargetPermille, interiorHalfPx,
                           breakGlass, intentional),
           "root", seed, domain, rules, board)

  for p in board.placements:
    gameMap.leftObstacles.add p.shape

  ## Install the trenches. Unlike `leftObstacles`, `gameMap.trenches` is stored
  ## already-symmetrized (`buildArenaObstacles` never mirrors it), so every pit
  ## dug in the left-half domain is added TOGETHER WITH its x-mirror image here.
  ## That is the same discipline `finalizeTrenches` uses in the main generator,
  ## and it keeps team fairness structural: a defender on Red's approach and one
  ## on Blue's get the exact same pit.
  for t in board.trenches:
    gameMap.trenches.add t.shape
    gameMap.trenches.add t.shape.mirrorX(gameMap.width)

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
