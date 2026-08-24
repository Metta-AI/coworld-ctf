## brmapkit — a CLI for authoring battle-royale (BR) maps.
##
## FORK, not a patch (Maxwell's ruling, 2026-08-24; docs/designs/BR_MAPGEN.md).
## The CTF generator (tools/mapkit.nim, src/ctf/arena.nim's
## generateMapAttempt/validateGeneratedMap/mapFromSpecJson/validateMap) is
## UNTOUCHED by this file. BR needs full-board asymmetric authoring with NO
## symmetry group, no flags/endzones/homes/teams, and a 16-spawn
## last-group-standing validator suite instead of a 2-team capture-the-flag
## one — none of which fit `CtfMap`'s invariants (`validateMap` hard-codes a
## symNone spec to exactly 2 teams, `mapProtectedFloorAt`/`renderMap` walk
## `gameMap.teams()`/`flagHome()`, capped at 4). So this tool defines its own
## light `BrMap` and its own render/validate/metrics pipeline, while reusing
## the actual GOOD PARTS verbatim rather than re-deriving them:
##   - `mapgen_styles.generateShapes` / `genCaves` — welded organic terrain,
##     the exact CA + blob-polygon generator CTF uses, unmodified.
##   - `sim`'s pure shape geometry — `ArenaShape`/`MapRect`/`MapPoint`,
##     `inShape`, `shapeBounds`, `pointInPolygon` — none of it touches
##     `CtfMap`/teams, so it transfers with zero adaptation.
##   - `map_render`'s rasterization STRATEGY (paint each shape only over its
##     own bounding box, never area x shapes) and its warm-stone/floor
##     palette, duplicated here since its per-pixel helpers are private to
##     that module and its `renderMap` is wired to CTF's team/flag globals.
##   - the mapkit CLI shape: generate / render / validate / metrics, one spec
##     JSON as the working document.
##
## Claude's loop:
##   brmapkit generate --seed 7 -o m.json
##   brmapkit render   m.json -o m.png            # then LOOK at the PNG
##   brmapkit validate m.json                     # BR gates? (exit code)
##   brmapkit metrics  m.json                     # walkable/mass/ring/zone stats
##   brmapkit contactsheet a.png b.png ... -o sheet.png
##
## See docs/designs/BR_MAPGEN.md for the doctrine this tool draws for: the
## giant (2.6x) 3211x1713 field, derived gunRange, the 16-point k=0.85 ring,
## the z=0.173 rectangular final zone, and the four BR static validators.

import std/[os, math, random, strformat, strutils, tables, json, algorithm, sequtils]
import pixie
import ../src/ctf/sim, ../src/ctf/mapgen_styles

type CliError = object of CatchableError

proc fail(msg: string) {.noreturn.} =
  raise newException(CliError, msg)

# --- argument parsing (duplicated from mapkit.nim's tiny parser) ------------

type Args = object
  positionals: seq[string]
  flags: Table[string, string]
  params: Table[string, string]
  bools: Table[string, bool]

proc parseArgs(argv: seq[string]): Args =
  result.flags = initTable[string, string]()
  result.params = initTable[string, string]()
  result.bools = initTable[string, bool]()
  var i = 0
  while i < argv.len:
    let a = argv[i]
    if a == "--param":
      inc i
      if i >= argv.len: fail("--param needs k=v")
      let kv = argv[i].split('=', 1)
      if kv.len != 2: fail("--param expects k=v, got: " & argv[i])
      result.params[kv[0]] = kv[1]
    elif a.startsWith("--"):
      let body = a[2 .. ^1]
      if body.contains('='):
        let kv = body.split('=', 1)
        result.flags[kv[0]] = kv[1]
      elif i + 1 < argv.len and not argv[i + 1].startsWith("--") and
          not (argv[i + 1].startsWith("-") and argv[i + 1].len == 2):
        ## The mapkit.nim precedent this parser is duplicated from only
        ## excludes "--"-prefixed lookahead, so a bool flag directly
        ## followed by a short flag (e.g. `--json -o out.json`) swallowed
        ## "-o" as ITS OWN value instead of reading as a bare bool — fixed
        ## here by also excluding 2-char short-flag tokens from "looks like
        ## a value".
        result.flags[body] = argv[i + 1]
        inc i
      else:
        result.bools[body] = true
    elif a.startsWith("-") and a.len == 2:
      let key = if a == "-o": "out" else: a[1 .. ^1]
      inc i
      if i >= argv.len: fail("flag " & a & " needs a value")
      result.flags[key] = argv[i]
    else:
      result.positionals.add a
    inc i

proc flag(a: Args, key, default: string): string = a.flags.getOrDefault(key, default)
proc intFlag(a: Args, key: string, default: int): int =
  if key in a.flags: a.flags[key].parseInt else: default
proc floatFlag(a: Args, key: string, default: float): float =
  if key in a.flags: a.flags[key].parseFloat else: default

proc applyParams(p: var StyleParams, params: Table[string, string]) =
  ## Duplicated verbatim from mapkit.nim's applyParams — the style knob
  ## surface is identical, BR just draws from a smaller family (caves only,
  ## in practice).
  for key, raw in params:
    template asInt: int = raw.parseInt
    template asFloat: float = raw.parseFloat
    case key
    of "period": p.period = asInt
    of "prob": p.prob = asFloat
    of "clusterMin": p.clusterMin = asInt
    of "clusterMax": p.clusterMax = asInt
    of "radMin": p.radMin = asInt
    of "radMax": p.radMax = asInt
    of "jitter": p.jitter = asInt
    of "cell": p.cell = asInt
    of "fillProb": p.fillProb = asFloat
    of "steps": p.steps = asInt
    of "birth": p.birth = asInt
    of "death": p.death = asInt
    of "blobScale": p.blobScale = asFloat
    of "wallThick": p.wallThick = asInt
    of "braid": p.braid = asFloat
    else: fail("unknown --param: " & key)

# --- BR map model -------------------------------------------------------------

type
  SpawnEdge = enum seTop, seRight, seBottom, seLeft

  BrSpawn = object
    p: MapPoint
    edge: SpawnEdge

  BrMap = object
    name: string
    genSeed: int
    style: MapStyle
    width, height: int
    gunRange: int              ## derived, §4.1: G = sqrt(W*H / (groups*pi))
    spawnClearW, spawnClearH: int  ## CtfMap.spawnClearW/H semantics, reused
    groups: int                 ## 16 duos
    seatsPerGroup: int          ## 2
    ringK: float                ## 0.85, §4.2
    zoneZ: float                ## 0.173, §4.3 final-zone scale
    obstacles: seq[ArenaShape]  ## FULL board, no symmetry (BR is symNone-only)
    spawns: seq[BrSpawn]

const
  StandardW = 1235   ## the CTF "standard" field width scaledGenShell derives from
  StandardH = 659
  GiantScale = 2.6    ## doctrine §4.1: giant field, half colossal's traverse time
  RingK = 0.85
  ZoneZ = 0.173
  Groups = 16
  SeatsPerGroup = 2
  ArenaBorderPx = 10   ## perimeter wall thickness, matches CTF's ArenaBorder
  styleSalt = 0x9E3779B1

proc fieldSize(scale: float): tuple[w, h: int] =
  (int(round(float(StandardW) * scale)), int(round(float(StandardH) * scale)))

proc deriveGunRange(w, h, groups: int): int =
  ## §4.1, alpha = 1: G = radius of one group's equal-share territory disc.
  int(round(sqrt(float(w) * float(h) / (float(groups) * PI))))

proc spawnClearance(scale: float): tuple[w, h: int] =
  ## CtfMap.spawnClearW/H semantics: s(70), s(130) at the size class's own
  ## scale (spawnClearW/H are CLEARANCES, which scale with the field, unlike
  ## obstacle geometry — see arena.nim's scaledGenShell comment).
  (int(round(70.0 * scale)), int(round(130.0 * scale)))

# --- ring spawns (§4.2) -------------------------------------------------------

proc ringSpawns(width, height: int, k: float, n: int): seq[BrSpawn] =
  ## n points equally spaced by ARC LENGTH around an inset rectangle ring of
  ## the field's own aspect. Walk clockwise from the top edge, phase-offset by
  ## half a step so no point lands exactly on a corner (keeps the per-edge
  ## pocket-orientation tag unambiguous for all n).
  let
    insetW = k * float(width)
    insetH = k * float(height)
    x0 = (float(width) - insetW) / 2.0
    y0 = (float(height) - insetH) / 2.0
    x1 = x0 + insetW
    y1 = y0 + insetH
    perimeter = 2.0 * (insetW + insetH)
    step = perimeter / float(n)
  var d = step / 2.0
  for i in 0 ..< n:
    var t = d
    var edge: SpawnEdge
    var x, y: float
    if t <= insetW:
      edge = seTop; x = x0 + t; y = y0
    else:
      t -= insetW
      if t <= insetH:
        edge = seRight; x = x1; y = y0 + t
      else:
        t -= insetH
        if t <= insetW:
          edge = seBottom; x = x1 - t; y = y1
        else:
          t -= insetW
          edge = seLeft; x = x0; y = y1 - t
    result.add BrSpawn(
      p: MapPoint(x: int(round(x)), y: int(round(y))), edge: edge)
    d += step

proc pocketRect(s: BrSpawn, clearW, clearH: int): MapRect =
  ## Oriented spawn-pocket clearance: the SMALLER half-extent (clearW) runs
  ## TANGENTIAL to the ring (along the edge, toward the next spawn — this is
  ## the axis under spacing pressure); the LARGER half-extent (clearH) runs
  ## RADIAL (toward the field interior / the border), which has no neighbour
  ## to collide with. This is the BR analogue of the CTF pocket, whose W ran
  ## along the home border and H ran along the carrier's approach.
  case s.edge
  of seTop, seBottom:
    MapRect(x: s.p.x - clearW, y: s.p.y - clearH, w: 2 * clearW, h: 2 * clearH)
  of seLeft, seRight:
    MapRect(x: s.p.x - clearH, y: s.p.y - clearW, w: 2 * clearH, h: 2 * clearW)

# --- terrain generation --------------------------------------------------------

proc placementRegion(width, height: int): MapRect =
  ## Full-board region inset only off the perimeter wall — no symmetry seam
  ## exists to dodge (BR is symNone-only), matching mapkit.placementRegion's
  ## own symNone branch.
  const hMargin = 40
  const vMargin = 2
  MapRect(x: hMargin, y: vMargin,
    w: max(1, width - 2 * hMargin), h: max(1, height - 2 * vMargin))

proc dropShapesNearSpawns(
  obstacles: seq[ArenaShape], pockets: seq[MapRect]
): seq[ArenaShape] =
  ## Drop (not clip) any generated shape whose bounding box crowds a spawn
  ## pocket — same policy as mapkit.keepFeatureClearance: dropping the whole
  ## seed shape keeps the terrain read as authored rock, never a shape with a
  ## bite taken out of it.
  ## Wider than the mapkit precedent (8px): BR pockets sit exposed on an open
  ## ring rather than tucked behind a protected home column, so a halo well
  ## past the drawn clearance rect measurably cuts down genuine one-exit
  ## chokepokes where organic terrain happens to crowd right up to the
  ## pocket's edge (empirically tuned against the exit-rule pass rate below).
  const Buffer = 70
  for shape in obstacles:
    let b = shapeBounds(shape)
    var collides = false
    for pocket in pockets:
      if b.x0 - Buffer <= pocket.x + pocket.w and
          b.x1 + Buffer >= pocket.x and
          b.y0 - Buffer <= pocket.y + pocket.h and
          b.y1 + Buffer >= pocket.y:
        collides = true
        break
    if not collides:
      result.add shape

proc generateBrMap(seed: int, style: MapStyle, paramsIn: StyleParams): BrMap =
  let (w, h) = fieldSize(GiantScale)
  result.name = "br-gen-" & $seed
  result.genSeed = seed
  result.style = style
  result.width = w
  result.height = h
  result.groups = Groups
  result.seatsPerGroup = SeatsPerGroup
  result.ringK = RingK
  result.zoneZ = ZoneZ
  result.gunRange = deriveGunRange(w, h, Groups)
  let (cw, ch) = spawnClearance(GiantScale)
  result.spawnClearW = cw
  result.spawnClearH = ch
  result.spawns = ringSpawns(w, h, RingK, Groups)
  let pockets = result.spawns.mapIt(pocketRect(it, cw, ch))
  let region = placementRegion(w, h)
  var params = paramsIn
  ## the sibling br-demo lane found (2026-08-24) that mapgen_styles'
  ## `verticalAnchors` places its safety band at a FIXED FRACTION (50-82%)
  ## of the REGION it's handed — correct only for a half-board about to be
  ## mirrored. Fed BR's full-width region directly, that band lands off
  ##-center and covers nothing near either edge, and (on the CTF path) can
  ## drift onto protected floor where mapWallAt forces it open regardless of
  ## any shape drawn there. BR has no protected floor / no sightline gate to
  ## satisfy in the first place (this generator's own connectivity/exit/
  ## anti-confetti/zone validators are the real BR gate), so the anchors buy
  ## nothing here and only add unpredictably-placed blob mass. Always off.
  params.noAnchors = true
  let raw = generateShapes(style, seed xor styleSalt, region, params)
  result.obstacles = dropShapesNearSpawns(raw, pockets)

# --- spec JSON (own schema; shape grammar matches arena.nim's wire format so
# it stays engine-compatible once the BR spawn/flagless lanes land) ----------

proc shapeSpecNode(shape: ArenaShape): JsonNode =
  result = newJObject()
  case shape.kind
  of shapeRect:
    result["kind"] = %"rect"
    result["x"] = %shape.rect.x
    result["y"] = %shape.rect.y
    result["w"] = %shape.rect.w
    result["h"] = %shape.rect.h
  of shapeDisc, shapeDiamond:
    result["kind"] = %(if shape.kind == shapeDisc: "disc" else: "diamond")
    result["cx"] = %shape.cx
    result["cy"] = %shape.cy
    result["r"] = %shape.radius
  of shapeDiagonal:
    result["kind"] = %"diagonal"
    result["x0"] = %shape.x0
    result["y0"] = %shape.y0
    result["x1"] = %shape.x1
    result["y1"] = %shape.y1
    result["t"] = %shape.thickness
  of shapePolygon:
    result["kind"] = %"polygon"
    var pts = newJArray()
    for p in shape.points: pts.add %*[p.x, p.y]
    result["points"] = pts
  if shape.window: result["window"] = %true

proc shapeFromSpecNode(node: JsonNode): ArenaShape =
  let window = node{"window"}.getBool(false)
  case node["kind"].getStr()
  of "rect":
    ArenaShape(kind: shapeRect, window: window, rect: MapRect(
      x: node["x"].getInt(), y: node["y"].getInt(),
      w: node["w"].getInt(), h: node["h"].getInt()))
  of "disc":
    ArenaShape(kind: shapeDisc, window: window,
      cx: node["cx"].getInt(), cy: node["cy"].getInt(), radius: node["r"].getInt())
  of "diamond":
    ArenaShape(kind: shapeDiamond, window: window,
      cx: node["cx"].getInt(), cy: node["cy"].getInt(), radius: node["r"].getInt())
  of "diagonal":
    ArenaShape(kind: shapeDiagonal, window: window,
      x0: node["x0"].getInt(), y0: node["y0"].getInt(),
      x1: node["x1"].getInt(), y1: node["y1"].getInt(), thickness: node["t"].getInt())
  of "polygon":
    var pts: seq[MapPoint]
    for pt in node["points"]: pts.add MapPoint(x: pt[0].getInt(), y: pt[1].getInt())
    ArenaShape(kind: shapePolygon, window: window, points: pts)
  else:
    raise newException(CtfError, "Unknown BR spec shape: " & node["kind"].getStr())

proc pointsNode(points: seq[MapPoint]): JsonNode =
  result = newJArray()
  for p in points: result.add %*[p.x, p.y]

proc pointsFromNode(node: JsonNode): seq[MapPoint] =
  if node.isNil or node.kind != JArray: return
  for item in node: result.add MapPoint(x: item[0].getInt(), y: item[1].getInt())

proc styleToStr(s: MapStyle): string =
  case s
  of styleBsp: "bsp"
  of styleCaves: "caves"
  of styleMaze: "maze"
  of styleScatter: "scatter"

proc brMapSpecJson(m: BrMap): string =
  ## spawnPoints grammar confirmed with the spawn-points lane (branch
  ## maxwell/br-spawn, 2026-08-24): top-level "spawnPoints" key, team-major
  ## flattened seq[MapPoint] encoded like pointsNode(), perTeam = len div
  ## teamCount. Here teamCount = groups = 16, perTeam = 1 -> 16 points in
  ## ring order.
  var shapes = newJArray()
  for shape in m.obstacles: shapes.add shape.shapeSpecNode()
  var spawnPts = newJArray()
  for s in m.spawns: spawnPts.add %*[s.p.x, s.p.y]
  let spec = %*{
    "name": m.name,
    "genSeed": m.genSeed,
    "mode": "br",                    ## marks this a BR spec, not a CtfMap one
    "style": styleToStr(m.style),
    "width": m.width,
    "height": m.height,
    "symmetry": "none",              ## full-board, #280-style, no lift
    "flagless": true,
    "gunRange": m.gunRange,
    "spawnClearW": m.spawnClearW,
    "spawnClearH": m.spawnClearH,
    "groups": m.groups,
    "seatsPerGroup": m.seatsPerGroup,
    "ringK": m.ringK,
    "zoneZ": m.zoneZ,
    "spawnPoints": spawnPts,          ## confirmed grammar, see comment above
    "leftObstacles": shapes,          ## full authored set; symNone = verbatim
  }
  $spec

proc brMapFromSpecJson(text: string): BrMap =
  let node = parseJson(text)
  result.name = node["name"].getStr()
  result.genSeed = node{"genSeed"}.getInt(0)
  result.style =
    case node{"style"}.getStr("caves")
    of "bsp": styleBsp
    of "caves": styleCaves
    of "maze": styleMaze
    of "scatter": styleScatter
    else: styleCaves
  result.width = node["width"].getInt()
  result.height = node["height"].getInt()
  result.gunRange = node["gunRange"].getInt()
  result.spawnClearW = node["spawnClearW"].getInt()
  result.spawnClearH = node["spawnClearH"].getInt()
  result.groups = node{"groups"}.getInt(Groups)
  result.seatsPerGroup = node{"seatsPerGroup"}.getInt(SeatsPerGroup)
  result.ringK = node{"ringK"}.getFloat(RingK)
  result.zoneZ = node{"zoneZ"}.getFloat(ZoneZ)
  for item in node["leftObstacles"]:
    result.obstacles.add item.shapeFromSpecNode()
  ## Re-derive edge tags from position (not pinned in the spec): the ring
  ## walk is deterministic from width/height/ringK/groups, so this round-trips.
  let ring = ringSpawns(result.width, result.height, result.ringK, result.groups)
  let pts = pointsFromNode(node["spawnPoints"])
  if pts.len != ring.len:
    raise newException(CtfError,
      "BR spec spawnPoints count " & $pts.len & " != groups " & $ring.len)
  for i, p in pts:
    result.spawns.add BrSpawn(p: p, edge: ring[i].edge)

# --- geometry / grid helpers for validators + render -------------------------

const GridStride = 4  ## px per grid cell for connectivity/mass/zone analysis
const NoEnclosureExits = 99
  ## exit count returned when a pocket/rect boundary sample ring is 100%
  ## walkable: nothing encloses it at all, which is the OPPOSITE of a
  ## single-exit trap, so it must clear MinPocketExits/ZoneMinExits trivially
  ## rather than reading as "one exit" (a fully-open ring and a one-door room
  ## are not the same failure mode).

proc gridDims(width, height: int): tuple[cols, rows: int] =
  (width div GridStride + 1, height div GridStride + 1)

proc buildWallGrid(m: BrMap): seq[bool] =
  ## True = solid (wall or off-playable-border), sampled at grid-cell centers.
  ## Painted shape-by-shape over each shape's own bounding box only, matching
  ## map_render's rasterization strategy (area + sum-of-boxes, never
  ## area x shapes) — the giant board has ~340k grid cells and can carry
  ## 1000+ blob polygons.
  let (cols, rows) = gridDims(m.width, m.height)
  result = newSeq[bool](cols * rows)
  for gy in 0 ..< rows:
    let y = gy * GridStride
    for gx in 0 ..< cols:
      let x = gx * GridStride
      if x < ArenaBorderPx or y < ArenaBorderPx or
          x >= m.width - ArenaBorderPx or y >= m.height - ArenaBorderPx:
        result[gy * cols + gx] = true
  for shape in m.obstacles:
    let b = shapeBounds(shape)
    let gx0 = max(0, b.x0 div GridStride)
    let gy0 = max(0, b.y0 div GridStride)
    let gx1 = min(cols - 1, b.x1 div GridStride)
    let gy1 = min(rows - 1, b.y1 div GridStride)
    for gy in gy0 .. gy1:
      let y = gy * GridStride
      for gx in gx0 .. gx1:
        let x = gx * GridStride
        if inShape(x, y, shape):
          result[gy * cols + gx] = true

# Union-Find for connected-component labeling.
type DSU = object
  parent: seq[int]
  size: seq[int]

proc initDSU(n: int): DSU =
  result.parent = newSeq[int](n)
  result.size = newSeq[int](n)
  for i in 0 ..< n:
    result.parent[i] = i
    result.size[i] = 1

proc find(d: var DSU, x: int): int =
  var x = x
  while d.parent[x] != x:
    d.parent[x] = d.parent[d.parent[x]]
    x = d.parent[x]
  x

proc union(d: var DSU, a, b: int) =
  let ra = d.find(a)
  let rb = d.find(b)
  if ra == rb: return
  if d.size[ra] < d.size[rb]:
    d.parent[ra] = rb
    d.size[rb] += d.size[ra]
  else:
    d.parent[rb] = ra
    d.size[ra] += d.size[rb]

proc components(
  mask: seq[bool], cols, rows: int, want: bool, diag: bool
): tuple[labels: seq[int], sizes: Table[int, int]] =
  ## Connected components of cells where mask[i] == want. `diag` selects
  ## 8-connectivity (used for WALL masses, so diagonal-touching blobs still
  ## read as one weld) vs 4-connectivity (used for WALKABLE floor, so a
  ## diagonal pixel-gap never counts as a real path).
  var dsu = initDSU(cols * rows)
  for gy in 0 ..< rows:
    for gx in 0 ..< cols:
      let i = gy * cols + gx
      if mask[i] != want: continue
      if gx + 1 < cols and mask[i + 1] == want: dsu.union(i, i + 1)
      if gy + 1 < rows and mask[i + cols] == want: dsu.union(i, i + cols)
      if diag:
        if gx + 1 < cols and gy + 1 < rows and mask[i + cols + 1] == want:
          dsu.union(i, i + cols + 1)
        if gx > 0 and gy + 1 < rows and mask[i + cols - 1] == want:
          dsu.union(i, i + cols - 1)
  result.labels = newSeq[int](cols * rows)
  result.sizes = initTable[int, int]()
  for gy in 0 ..< rows:
    for gx in 0 ..< cols:
      let i = gy * cols + gx
      if mask[i] != want:
        result.labels[i] = -1
        continue
      let r = dsu.find(i)
      result.labels[i] = r
      result.sizes[r] = result.sizes.getOrDefault(r, 0) + 1

proc toGrid(x, y: int): tuple[gx, gy: int] = (x div GridStride, y div GridStride)

# --- exit / choke counting ----------------------------------------------------

proc countExits(
  wall: seq[bool], cols, rows: int, cx, cy, radius: int
): int =
  ## Samples a circle of the given radius (map px) around (cx, cy) and counts
  ## CONTIGUOUS walkable arcs — the static approximation of "how many
  ## distinct exits does this pocket have" (doc §4.5). A single arc, however
  ## wide, is one exit: the whole ring being open counts as ONE, not merged
  ## into "no chokepoint" — we want independent breaks in the wall, so two
  ## arcs separated by ANY solid span both count, and the wraparound is
  ## stitched (arc 0 and the last arc merge if both walkable and adjacent).
  const Samples = 96
  var open = newSeq[bool](Samples)
  for i in 0 ..< Samples:
    let theta = 2.0 * PI * float(i) / float(Samples)
    let x = cx + int(round(float(radius) * cos(theta)))
    let y = cy + int(round(float(radius) * sin(theta)))
    let (gx, gy) = toGrid(clamp(x, 0, cols * GridStride - 1),
                           clamp(y, 0, rows * GridStride - 1))
    if gx >= 0 and gx < cols and gy >= 0 and gy < rows:
      open[i] = not wall[gy * cols + gx]
  if not anyIt(open, it): return 0
  if allIt(open, it): return NoEnclosureExits  # no wall nearby at all: trivially safe
  var runs = 0
  for i in 0 ..< Samples:
    let prev = open[(i + Samples - 1) mod Samples]
    if open[i] and not prev: inc runs
  runs

proc countBoundaryExits(
  wall: seq[bool], cols, rows, width, height: int, rect: MapRect
): int =
  ## Same contiguous-arc count as countExits, walked around a RECTANGLE'S
  ## perimeter instead of a circle — used both for the zone-center viability
  ## sweep (§4.3) and for the spawn-pocket exit rule (§4.5).
  ##
  ## A pocket near the map edge can have a ring that pokes OFF the field
  ## (negative x/y, or past width/height): clamping those samples onto the
  ## nearest in-field pixel lands them on the perimeter wall (always solid),
  ## which reads as a permanent one-sided "chokepoint" that has nothing to do
  ## with the drawn terrain — every seed failed the exit rule on exactly this
  ## before the fix. Off-field samples are dropped entirely instead: the
  ## circular run-count then naturally bridges the gap they leave, judging
  ## only the boundary that is actually part of the playable map.
  var pts: seq[tuple[x, y: int]]
  const Step = GridStride
  ## Margin rounded UP to a full grid cell: a raw pixel just past ArenaBorderPx
  ## (e.g. x=10) can still floor-divide (toGrid) onto a grid cell whose OWN
  ## sample point (gx*GridStride, e.g. 8) is < ArenaBorderPx and so was marked
  ## permanently solid by buildWallGrid's border rule — a single such
  ## mismatched sample amid an otherwise open ring reads as a false 1-pixel
  ## "wall", which the run-counter then reports as exactly one exit. Padding
  ## the margin to the next grid cell guarantees every kept sample's OWN grid
  ## cell is unambiguously past the border rule.
  const FieldMargin = ArenaBorderPx + GridStride
  proc inField(x, y: int): bool =
    x >= FieldMargin and y >= FieldMargin and
      x < width - FieldMargin and y < height - FieldMargin
  var x = rect.x
  while x <= rect.x + rect.w:
    if inField(x, rect.y): pts.add (x, rect.y)
    x += Step
  var y = rect.y
  while y <= rect.y + rect.h:
    if inField(rect.x + rect.w, y): pts.add (rect.x + rect.w, y)
    y += Step
  x = rect.x + rect.w
  while x >= rect.x:
    if inField(x, rect.y + rect.h): pts.add (x, rect.y + rect.h)
    x -= Step
  y = rect.y + rect.h
  while y >= rect.y:
    if inField(rect.x, y): pts.add (rect.x, y)
    y -= Step
  if pts.len == 0: return 0
  var open = newSeq[bool](pts.len)
  for i, p in pts:
    let (gx, gy) = toGrid(p.x, p.y)
    if gx >= 0 and gx < cols and gy >= 0 and gy < rows:
      open[i] = not wall[gy * cols + gx]
  if not anyIt(open, it): return 0
  if allIt(open, it): return NoEnclosureExits  # no wall nearby at all: trivially safe
  var runs = 0
  for i in 0 ..< pts.len:
    let prev = open[(i + pts.len - 1) mod pts.len]
    if open[i] and not prev: inc runs
  runs

# --- zone geometry (§4.3) ------------------------------------------------------

proc zoneRect(width, height: int, z: float, cx, cy: int): MapRect =
  let
    w = int(round(z * float(width)))
    h = int(round(z * float(height)))
  result = MapRect(x: cx - w div 2, y: cy - h div 2, w: w, h: h)

# --- BR validators -------------------------------------------------------------

type
  ZoneCandidate = object
    cx, cy: int
    walkableFrac: float
    massCount: int
    exits: int
    pass: bool

  BrValidation = object
    ## One bool + a reason string per gate, plus the artifacts each needed.
    connectivityPass: bool
    connectivityReason: string
    componentCount: int
    dominantFrac: float

    exitPass: bool
    exitReason: string
    minPocketExits: int
    pocketExits: seq[int]

    antiConfettiPass: bool
    antiConfettiReason: string
    massCount: int
    confettiCount: int
    largestMassPx2: int

    zoneCandidates: seq[ZoneCandidate]
    zoneViableFrac: float
    zonePass: bool
    zoneReason: string

    specSizePass: bool
    specSizeReason: string
    specSizeBytes: int

    allPass: bool

const
  ConfettiFloorPx2 = 3000     ## below this, a wall mass counts as confetti
  ConfettiCeiling = 40        ## max confetti masses tolerated on the whole board
  MinPocketExits = 2          ## doc §4.5: no single-exit pocket
  ZoneWalkableFloor = 0.55
  ZoneMinMasses = 2
  ZoneMinExits = 2
  ZoneStepPx = 180
  ## The replay wire format caps one embedded string at 65535 bytes
  ## (bitworld/replays.nim:108-112, per the br-demo lane's 2026-08-24 giant
  ## symNone build, which hit this at 73KB). Budget well under the hard cap.
  SpecSizeBudgetBytes = 58000

proc validateBr(m: BrMap): BrValidation =
  let (cols, rows) = gridDims(m.width, m.height)
  let wall = buildWallGrid(m)

  # 1. Global connectivity ----------------------------------------------------
  var walkable = newSeq[bool](wall.len)
  for i in 0 ..< wall.len: walkable[i] = not wall[i]
  let walkComp = components(walkable, cols, rows, true, false)
  var labelOf: seq[int]
  for s in m.spawns:
    let (gx, gy) = toGrid(clamp(s.p.x, 0, cols * GridStride - 1),
                           clamp(s.p.y, 0, rows * GridStride - 1))
    labelOf.add walkComp.labels[gy * cols + gx]
  var totalWalkable = 0
  for _, sz in walkComp.sizes: totalWalkable += sz
  let uniqueLabels = labelOf.deduplicate()
  result.componentCount = walkComp.sizes.len
  if -1 in labelOf:
    result.connectivityPass = false
    result.connectivityReason = "a spawn point sampled onto a wall cell"
  elif uniqueLabels.len != 1:
    result.connectivityPass = false
    result.connectivityReason =
      &"spawns split across {uniqueLabels.len} components (need 1)"
  else:
    let dominant = walkComp.sizes[uniqueLabels[0]]
    result.dominantFrac = float(dominant) / float(max(1, totalWalkable))
    result.connectivityPass = result.dominantFrac >= 0.90
    result.connectivityReason =
      if result.connectivityPass: ""
      else: &"shared spawn component is only {result.dominantFrac*100:.1f}% of walkable area"

  # 2. Exit rule around every spawn pocket ------------------------------------
  var minExits = high(int)
  for s in m.spawns:
    ## Walk the boundary of the pocket's OWN oriented rect (expanded by a
    ## small margin), not a uniform circle: the pocket clearance itself is
    ## anisotropic (§ pocketRect), and a circle at a fixed radius pokes well
    ## outside the guaranteed-clear zone on the tangential (narrow) sides,
    ## which reads real terrain there as a "choke" even when the pocket's
    ## own clear zone was never promised to extend that far.
    const ExitMargin = 24
    let pocket = pocketRect(s, m.spawnClearW, m.spawnClearH)
    let ring = MapRect(
      x: pocket.x - ExitMargin, y: pocket.y - ExitMargin,
      w: pocket.w + 2 * ExitMargin, h: pocket.h + 2 * ExitMargin)
    let n = countBoundaryExits(wall, cols, rows, m.width, m.height, ring)
    when defined(brDebugExit):
      stderr.writeLine(&"spawn edge={s.edge} p=({s.p.x},{s.p.y}) ring=({ring.x},{ring.y},{ring.w},{ring.h}) exits={n}")
    result.pocketExits.add n
    minExits = min(minExits, n)
  result.minPocketExits = minExits
  result.exitPass = minExits >= MinPocketExits
  result.exitReason =
    if result.exitPass: ""
    else: &"a spawn pocket has only {minExits} exit(s), need >= {MinPocketExits}"

  # 3. Anti-confetti proxy ------------------------------------------------------
  let wallComp = components(wall, cols, rows, true, true)
  ## Cell (0,0) is always inside the border ring (buildWallGrid marks the
  ## whole perimeter solid regardless of any drawn terrain), so its label
  ## identifies the border's own component — the border is the map boundary,
  ## not a welded TERRAIN mass, and must not count toward "distinct places"
  ## or inflate the largest-mass stat.
  let borderLabel = wallComp.labels[0]
  var confetti = 0
  var largest = 0
  for lbl, sz in wallComp.sizes:
    if lbl == borderLabel: continue
    let px2 = sz * GridStride * GridStride
    if px2 < ConfettiFloorPx2: inc confetti
    largest = max(largest, px2)
  result.massCount = wallComp.sizes.len - 1  ## excludes the border component
  result.confettiCount = confetti
  result.largestMassPx2 = largest
  result.antiConfettiPass = confetti <= ConfettiCeiling
  result.antiConfettiReason =
    if result.antiConfettiPass: ""
    else: &"{confetti} confetti-sized masses (< {ConfettiFloorPx2}px^2), ceiling {ConfettiCeiling}"

  # 4. Zone-center viability sweep ----------------------------------------------
  let margin = max(zoneRect(m.width, m.height, m.zoneZ, 0, 0).w,
                    zoneRect(m.width, m.height, m.zoneZ, 0, 0).h) div 2 + ArenaBorderPx + 20
  var y = margin
  while y <= m.height - margin:
    var x = margin
    while x <= m.width - margin:
      let rect = zoneRect(m.width, m.height, m.zoneZ, x, y)
      var walkCells = 0
      var totalCells = 0
      var massesInside = initTable[int, bool]()
      let gx0 = max(0, rect.x div GridStride)
      let gy0 = max(0, rect.y div GridStride)
      let gx1 = min(cols - 1, (rect.x + rect.w) div GridStride)
      let gy1 = min(rows - 1, (rect.y + rect.h) div GridStride)
      for gy in gy0 .. gy1:
        for gx in gx0 .. gx1:
          let i = gy * cols + gx
          inc totalCells
          if not wall[i]:
            inc walkCells
          else:
            let lbl = wallComp.labels[i]
            if lbl >= 0 and lbl != borderLabel and
                wallComp.sizes[lbl] * GridStride * GridStride >= ConfettiFloorPx2:
              massesInside[lbl] = true
      let frac = float(walkCells) / float(max(1, totalCells))
      let exits = countBoundaryExits(wall, cols, rows, m.width, m.height, rect)
      var cand = ZoneCandidate(
        cx: x, cy: y, walkableFrac: frac, massCount: massesInside.len, exits: exits)
      cand.pass = frac >= ZoneWalkableFloor and
        massesInside.len >= ZoneMinMasses and exits >= ZoneMinExits
      result.zoneCandidates.add cand
      x += ZoneStepPx
    y += ZoneStepPx
  var viable = 0
  for c in result.zoneCandidates:
    if c.pass: inc viable
  result.zoneViableFrac =
    float(viable) / float(max(1, result.zoneCandidates.len))
  result.zonePass = viable >= 1
  result.zoneReason =
    if result.zonePass: ""
    else: "no candidate zone center passed the viability sweep"

  # 5. Spec-size budget ----------------------------------------------------------
  ## Serialize with the SAME emitter cmdGenerate/render use, so this is the
  ## exact byte count a pinned replay spec would carry.
  result.specSizeBytes = brMapSpecJson(m).len
  result.specSizePass = result.specSizeBytes <= SpecSizeBudgetBytes
  result.specSizeReason =
    if result.specSizePass: ""
    else: &"spec is {result.specSizeBytes}B, budget {SpecSizeBudgetBytes}B " &
      &"(replay wire cap is 65535B) — prune more or thin blob density"

  result.allPass = result.connectivityPass and result.exitPass and
    result.antiConfettiPass and result.zonePass and result.specSizePass

proc bestZoneCandidate(v: BrValidation, width, height: int): ZoneCandidate =
  ## Pick the passing candidate closest to the field's geometric center (a
  ## centered final zone reads best on the example render); fall back to the
  ## highest-scoring candidate if none pass, so render still has something.
  let cx0 = width div 2
  let cy0 = height div 2
  var bestPass = false
  var bestScore = -1.0
  var best: ZoneCandidate
  var any = false
  for c in v.zoneCandidates:
    let d = sqrt(float((c.cx - cx0) * (c.cx - cx0) + (c.cy - cy0) * (c.cy - cy0)))
    if c.pass:
      if not bestPass or -d > bestScore:
        bestPass = true
        bestScore = -d
        best = c
        any = true
    elif not bestPass:
      let score = c.walkableFrac + float(c.massCount) * 0.1 + float(c.exits) * 0.1
      if not any or score > bestScore:
        bestScore = score
        best = c
        any = true
  best

proc pruneConfetti(
  obstacles: seq[ArenaShape], width, height: int, floorPx2: int
): seq[ArenaShape] =
  ## Anti-confetti is a HARD gate (doc §2.1), so it is enforced at DRAW time,
  ## not just measured after the fact: drop any shape whose 8-connected wall
  ## mass (the mass it welds into, sharing an edge or corner with a
  ## neighbour) is smaller than the confetti floor. A shape with no welded
  ## neighbours at all is its own 1-cell mass and is always dropped. Sampling
  ## each shape's CENTROID against the mass grid (rather than re-deriving
  ## membership analytically) keeps this consistent with validateBr's own
  ## mass measurement by construction.
  let (cols, rows) = gridDims(width, height)
  var wall = newSeq[bool](cols * rows)
  for shape in obstacles:
    let b = shapeBounds(shape)
    let gx0 = max(0, b.x0 div GridStride)
    let gy0 = max(0, b.y0 div GridStride)
    let gx1 = min(cols - 1, b.x1 div GridStride)
    let gy1 = min(rows - 1, b.y1 div GridStride)
    for gy in gy0 .. gy1:
      let y = gy * GridStride
      for gx in gx0 .. gx1:
        let x = gx * GridStride
        if inShape(x, y, shape):
          wall[gy * cols + gx] = true
  let comp = components(wall, cols, rows, true, true)
  for shape in obstacles:
    let b = shapeBounds(shape)
    let ccx = clamp((b.x0 + b.x1) div 2, 0, width - 1)
    let ccy = clamp((b.y0 + b.y1) div 2, 0, height - 1)
    let (gx, gy) = toGrid(ccx, ccy)
    if gx < 0 or gx >= cols or gy < 0 or gy >= rows: continue
    let lbl = comp.labels[gy * cols + gx]
    if lbl >= 0 and comp.sizes[lbl] * GridStride * GridStride >= floorPx2:
      result.add shape

# --- metrics -------------------------------------------------------------------

proc printMetrics(m: BrMap) =
  let (cols, rows) = gridDims(m.width, m.height)
  let wall = buildWallGrid(m)
  var walkableCells = 0
  for w in wall:
    if not w: inc walkableCells
  let totalCells = cols * rows
  let wallComp = components(wall, cols, rows, true, true)
  let borderLabel = wallComp.labels[0]  ## cell (0,0): always the border ring
  var sizesPx2: seq[int]
  for lbl, sz in wallComp.sizes:
    if lbl != borderLabel: sizesPx2.add sz * GridStride * GridStride
  sizesPx2.sort(Descending)

  echo &"size:            {m.width}x{m.height}  style={styleToStr(m.style)}  seed={m.genSeed}"
  echo &"gunRange G:      {m.gunRange} px  (field is {float(m.width)/float(m.gunRange):.2f} x {float(m.height)/float(m.gunRange):.2f} G)"
  echo &"walkable frac:   {float(walkableCells)/float(totalCells)*100:.1f}%  ({walkableCells}/{totalCells} grid cells @ {GridStride}px)"
  echo &"wall masses:     {sizesPx2.len}  (8-connected)"
  if sizesPx2.len > 0:
    let top = sizesPx2[0 ..< min(8, sizesPx2.len)]
    echo &"  largest 8 (px^2): {top}"
    let confetti = sizesPx2.filterIt(it < ConfettiFloorPx2).len
    echo &"  confetti (<{ConfettiFloorPx2}px^2): {confetti}"

  echo "spawn ring (k=" & $m.ringK & "):"
  let idealSpacing = m.ringK * float(m.width + m.height) / float(m.groups * 4) * 4.0 / 8.0
  var dists: seq[float]
  for i in 0 ..< m.spawns.len:
    let a = m.spawns[i].p
    let b = m.spawns[(i + 1) mod m.spawns.len].p
    dists.add sqrt(float((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)))
  let meanD = dists.foldl(a + b, 0.0) / float(max(1, dists.len))
  echo &"  spacing: mean(consecutive straight-line)={meanD:.1f}px ({meanD/float(m.gunRange):.2f}G)  ideal arc-length={idealSpacing:.1f}px ({idealSpacing/float(m.gunRange):.2f}G)"
  echo &"  min pairwise gap: {dists.min():.1f}px  max: {dists.max():.1f}px"

  let v = validateBr(m)
  echo "zone-center sweep (z=" & $m.zoneZ & "):"
  echo &"  candidates sampled: {v.zoneCandidates.len}  viable: {(v.zoneViableFrac*100):.1f}%"

proc metricsJson(m: BrMap, v: BrValidation): JsonNode =
  let (cols, rows) = gridDims(m.width, m.height)
  let wall = buildWallGrid(m)
  var walkableCells = 0
  for w in wall:
    if not w: inc walkableCells
  %*{
    "seed": m.genSeed,
    "style": styleToStr(m.style),
    "width": m.width,
    "height": m.height,
    "gunRange": m.gunRange,
    "walkableFrac": float(walkableCells) / float(cols * rows),
    "massCount": v.massCount,
    "confettiCount": v.confettiCount,
    "largestMassPx2": v.largestMassPx2,
    "componentCount": v.componentCount,
    "dominantWalkableFrac": v.dominantFrac,
    "minPocketExits": v.minPocketExits,
    "pocketExits": v.pocketExits,
    "zoneCandidateCount": v.zoneCandidates.len,
    "zoneViableFrac": v.zoneViableFrac,
    "pass": %*{
      "connectivity": v.connectivityPass,
      "exitRule": v.exitPass,
      "antiConfetti": v.antiConfettiPass,
      "zoneViability": v.zonePass,
      "all": v.allPass,
    },
  }

# --- render --------------------------------------------------------------------
# Own top-to-bottom raster loop (map_render's per-pixel helpers are private to
# that module, and its shared `renderMap` is wired to CTF's teams()/flagHome()
# globals, which BR has none of) — but the STRATEGY (paint each shape only
# over its own bounding box) and the warm floor/stone palette are the exact
# ones map_render.nim uses, duplicated here on purpose.

const
  FloorColor = rgba(214, 189, 150, 255)
  StoneColor = rgba(64, 48, 34, 255)
  BorderColor = rgba(44, 34, 25, 255)
  SpawnColor = rgba(235, 145, 35, 255)
  SpawnRingColor = rgba(235, 145, 35, 90)
  ZoneColor = rgba(230, 45, 45, 220)
  ZoneFillColor = rgba(230, 45, 45, 40)

proc fillDiscPx(image: Image, cx, cy, radius: int, color: ColorRGBA) =
  for y in max(0, cy - radius) .. min(image.height - 1, cy + radius):
    for x in max(0, cx - radius) .. min(image.width - 1, cx + radius):
      if (x - cx) * (x - cx) + (y - cy) * (y - cy) <= radius * radius:
        image.unsafe[x, y] = color

proc drawCrossPx(image: Image, cx, cy, radius: int, color: ColorRGBA) =
  for d in -radius .. radius:
    for t in -1 .. 1:
      if cx + d >= 0 and cx + d < image.width and cy + t >= 0 and cy + t < image.height:
        image.unsafe[cx + d, cy + t] = color
      if cx + t >= 0 and cx + t < image.width and cy + d >= 0 and cy + d < image.height:
        image.unsafe[cx + t, cy + d] = color

proc drawRectOutlinePx(image: Image, x0, y0, x1, y1: int, color: ColorRGBA, thick = 1) =
  let
    cx0 = clamp(x0, 0, image.width - 1)
    cy0 = clamp(y0, 0, image.height - 1)
    cx1 = clamp(x1, 0, image.width - 1)
    cy1 = clamp(y1, 0, image.height - 1)
  for t in 0 ..< thick:
    for x in cx0 .. cx1:
      if cy0 + t < image.height: image.unsafe[x, cy0 + t] = color
      if cy1 - t >= 0: image.unsafe[x, cy1 - t] = color
    for y in cy0 .. cy1:
      if cx0 + t < image.width: image.unsafe[cx0 + t, y] = color
      if cx1 - t >= 0: image.unsafe[cx1 - t, y] = color

proc renderBrMap(
  m: BrMap, maxDim: int, zoneRectOpt: MapRect, drawZone: bool
): Image =
  let scale =
    if maxDim <= 0: 1.0
    else: min(1.0, float(maxDim) / float(max(m.width, m.height)))
  let ow = int(ceil(float(m.width) * scale))
  let oh = int(ceil(float(m.height) * scale))
  result = newImage(ow, oh)

  proc toOut(v: int): int = int(round(float(v) * scale))
  proc toLogical(px: int): float = (float(px) + 0.5) / scale - 0.5

  var wall = newSeq[bool](ow * oh)
  for y in 0 ..< oh:
    let fy = toLogical(y)
    for x in 0 ..< ow:
      let fx = toLogical(x)
      let index = y * ow + x
      if fx < float(ArenaBorderPx) or fy < float(ArenaBorderPx) or
          fx >= float(m.width - ArenaBorderPx) or fy >= float(m.height - ArenaBorderPx):
        wall[index] = true

  for shape in m.obstacles:
    let b = shapeBounds(shape)
    let x0 = max(0, toOut(b.x0) - 1)
    let y0 = max(0, toOut(b.y0) - 1)
    let x1 = min(ow - 1, toOut(b.x1) + 1)
    let y1 = min(oh - 1, toOut(b.y1) + 1)
    for y in y0 .. y1:
      let fy = toLogical(y)
      for x in x0 .. x1:
        let fx = toLogical(x)
        if inShapeF(fx, fy, shape):
          wall[y * ow + x] = true

  for y in 0 ..< oh:
    for x in 0 ..< ow:
      let index = y * ow + x
      result.unsafe[x, y] = if wall[index]: StoneColor else: FloorColor

  # Spawn pockets: faint clearance ring, then a bright marker on the point.
  for s in m.spawns:
    let pocket = pocketRect(s, m.spawnClearW, m.spawnClearH)
    result.drawRectOutlinePx(
      toOut(pocket.x), toOut(pocket.y),
      toOut(pocket.x + pocket.w), toOut(pocket.y + pocket.h),
      SpawnRingColor)
  for s in m.spawns:
    result.fillDiscPx(toOut(s.p.x), toOut(s.p.y), max(2, toOut(10)), SpawnColor)
    result.drawCrossPx(toOut(s.p.x), toOut(s.p.y), max(3, toOut(16)), BorderColor)

  # One example final-zone rect (§4.3), a thing to look at, not just a line.
  if drawZone:
    result.drawRectOutlinePx(
      toOut(zoneRectOpt.x), toOut(zoneRectOpt.y),
      toOut(zoneRectOpt.x + zoneRectOpt.w), toOut(zoneRectOpt.y + zoneRectOpt.h),
      ZoneColor, thick = max(1, toOut(4)))

proc renderZoneHeatmap(m: BrMap, v: BrValidation, maxDim: int): Image =
  ## The BR-specific THIRD view (doc §5.4): which drawn zone centers pass the
  ## viability sweep and which don't, composited as translucent squares over
  ## the real terrain render — never a bare gray heatmap.
  result = renderBrMap(m, maxDim, MapRect(), false)
  let scale =
    if maxDim <= 0: 1.0
    else: min(1.0, float(maxDim) / float(max(m.width, m.height)))
  proc toOut(v: int): int = int(round(float(v) * scale))
  let half = ZoneStepPx div 2
  for c in v.zoneCandidates:
    let color =
      if c.pass: rgba(60, 200, 90, 130)
      else: rgba(210, 40, 40, 110)
    let x0 = toOut(c.cx - half)
    let y0 = toOut(c.cy - half)
    let x1 = toOut(c.cx + half)
    let y1 = toOut(c.cy + half)
    for y in max(0, y0) .. min(result.height - 1, y1):
      for x in max(0, x0) .. min(result.width - 1, x1):
        let bg = result.unsafe[x, y].rgba
        let a = int(color.a)
        result.unsafe[x, y] = rgba(
          uint8((int(color.r) * a + int(bg.r) * (255 - a)) div 255),
          uint8((int(color.g) * a + int(bg.g) * (255 - a)) div 255),
          uint8((int(color.b) * a + int(bg.b) * (255 - a)) div 255),
          255)

# --- commands ------------------------------------------------------------------

proc readSpec(path: string): BrMap =
  if not fileExists(path): fail("no such spec file: " & path)
  brMapFromSpecJson(readFile(path))

proc cmdGenerate(a: Args) =
  let
    seed = a.intFlag("seed", 1)
    style = parseStyle(a.flag("style", "caves"))
  var params = defaultParams(style)
  applyParams(params, a.params)
  var m = generateBrMap(seed, style, params)
  let rawCount = m.obstacles.len
  if not a.bools.getOrDefault("noPrune", false):
    m.obstacles = pruneConfetti(m.obstacles, m.width, m.height, ConfettiFloorPx2)
  let spec = brMapSpecJson(m)
  let outPath = a.flag("out", "")
  if outPath.len == 0:
    echo spec
  else:
    writeFile(outPath, spec)
    stderr.writeLine(
      &"generated br {styleToStr(style)} seed={seed} {m.width}x{m.height} " &
      &"gunRange={m.gunRange} spawns={m.spawns.len} obstacles={m.obstacles.len}" &
      &" (pruned {rawCount - m.obstacles.len} confetti of {rawCount}) -> {outPath}")

proc cmdRender(a: Args) =
  if a.positionals.len == 0: fail("render needs a spec path")
  let m = readSpec(a.positionals[0])
  let outPath = a.flag("out", a.positionals[0].changeFileExt("png"))
  let maxDim = a.intFlag("max", 1600)
  let v = validateBr(m)
  let zc = bestZoneCandidate(v, m.width, m.height)
  let rect = zoneRect(m.width, m.height, m.zoneZ, zc.cx, zc.cy)
  renderBrMap(m, maxDim, rect, true).writeFile(outPath)
  stderr.writeLine(&"rendered {a.positionals[0]} -> {outPath}")
  if a.bools.getOrDefault("heatmap", false):
    let heatPath = outPath.changeFileExt("") & ".zoneheat.png"
    renderZoneHeatmap(m, v, maxDim).writeFile(heatPath)
    stderr.writeLine(&"rendered zone-coverage heatmap -> {heatPath}")

proc printValidation(v: BrValidation) =
  echo &"connectivity:  {(if v.connectivityPass: \"PASS\" else: \"FAIL: \" & v.connectivityReason)}  (components={v.componentCount}, dominant={v.dominantFrac*100:.1f}%)"
  echo &"exit rule:     {(if v.exitPass: \"PASS\" else: \"FAIL: \" & v.exitReason)}  (min pocket exits={v.minPocketExits})"
  echo &"anti-confetti: {(if v.antiConfettiPass: \"PASS\" else: \"FAIL: \" & v.antiConfettiReason)}  (masses={v.massCount}, confetti={v.confettiCount}, largest={v.largestMassPx2}px^2)"
  echo &"zone-viable:   {(if v.zonePass: \"PASS\" else: \"FAIL: \" & v.zoneReason)}  (viable={v.zoneViableFrac*100:.1f}% of {v.zoneCandidates.len} candidates)"
  echo &"spec size:     {(if v.specSizePass: \"PASS\" else: \"FAIL: \" & v.specSizeReason)}  ({v.specSizeBytes}B / {SpecSizeBudgetBytes}B budget)"

proc cmdValidate(a: Args) =
  if a.positionals.len == 0: fail("validate needs a spec path")
  let m = readSpec(a.positionals[0])
  printMetrics(m)
  let v = validateBr(m)
  printValidation(v)
  if v.allPass:
    echo "PASS"
    quit(0)
  else:
    echo "FAIL"
    quit(1)

proc cmdMetrics(a: Args) =
  if a.positionals.len == 0: fail("metrics needs a spec path")
  let m = readSpec(a.positionals[0])
  printMetrics(m)
  if a.bools.getOrDefault("json", false):
    let v = validateBr(m)
    let outPath = a.flag("out", "")
    let js = $metricsJson(m, v)
    if outPath.len == 0: echo js
    else: writeFile(outPath, js)

proc cmdContactSheet(a: Args) =
  if a.positionals.len == 0: fail("contactsheet needs one or more PNG paths")
  var images: seq[Image]
  for p in a.positionals:
    images.add readImage(p)
  let cols = a.intFlag("cols", 3)
  let rows = (images.len + cols - 1) div cols
  let cellW = a.intFlag("cellw", 480)
  var maxAspect = 0.5
  for img in images: maxAspect = max(maxAspect, float(img.height) / float(img.width))
  let cellH = int(float(cellW) * maxAspect)
  let pad = 8
  let sheet = newImage(cols * (cellW + pad) + pad, rows * (cellH + pad) + pad)
  for y in 0 ..< sheet.height:
    for x in 0 ..< sheet.width:
      sheet.unsafe[x, y] = rgba(28, 24, 20, 255)
  for i, img in images:
    let col = i mod cols
    let row = i div cols
    let scale = min(float(cellW) / float(img.width), float(cellH) / float(img.height))
    let dw = max(1, int(float(img.width) * scale))
    let dh = max(1, int(float(img.height) * scale))
    let ox = pad + col * (cellW + pad) + (cellW - dw) div 2
    let oy = pad + row * (cellH + pad) + (cellH - dh) div 2
    for y in 0 ..< dh:
      let sy = clamp(int(float(y) / scale), 0, img.height - 1)
      for x in 0 ..< dw:
        let sx = clamp(int(float(x) / scale), 0, img.width - 1)
        let px = ox + x
        let py = oy + y
        if px >= 0 and px < sheet.width and py >= 0 and py < sheet.height:
          sheet.unsafe[px, py] = img.unsafe[sx, sy]
  let outPath = a.flag("out", "contactsheet.png")
  sheet.writeFile(outPath)
  stderr.writeLine(&"contact sheet: {images.len} images -> {outPath}")

const usage = """
brmapkit — author battle-royale maps (fork of tools/mapkit.nim; see
docs/designs/BR_MAPGEN.md)

  brmapkit generate [--style caves] [--seed N] [--param k=v ...] [-o spec.json]
                    (caves is the only doctrine-validated style; bsp/maze/
                    scatter are wired for experimentation but unproven at
                    giant scale)
  brmapkit render   spec.json [-o out.png] [--max N] [--heatmap]
                    (--heatmap also writes <out>.zoneheat.png, the §5.4
                    circle-center-coverage view)
  brmapkit validate spec.json          # BR gates: PASS/FAIL, exit code
  brmapkit metrics  spec.json [--json] [-o out.json]
  brmapkit contactsheet a.png b.png ... [-o sheet.png] [--cols N] [--cellw N]
"""

when isMainModule:
  let argv = commandLineParams()
  if argv.len == 0 or argv[0] in ["-h", "--help", "help"]:
    echo usage
    quit(0)
  let a = parseArgs(argv[1 .. ^1])
  try:
    case argv[0]
    of "generate": cmdGenerate(a)
    of "render": cmdRender(a)
    of "validate": cmdValidate(a)
    of "metrics": cmdMetrics(a)
    of "contactsheet": cmdContactSheet(a)
    else:
      stderr.writeLine("unknown command: " & argv[0])
      echo usage
      quit(2)
  except CliError as e:
    stderr.writeLine("brmapkit: " & e.msg)
    quit(2)
  except CtfError as e:
    stderr.writeLine("brmapkit: " & e.msg)
    quit(1)
