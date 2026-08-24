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

  ## ROUND 3 (Maxwell's rejection, 2026-08-24): "no rooms, no alleys, no
  ## items, no intention" — CA-blob terrain alone cannot BE a battle-royale
  ## map. POIs are the composition unit; caves fill demotes to organic
  ## texture between them. Each archetype is chosen to be nameable at a
  ## glance (a caster's callout), per Maxwell's bar.
  PoiArchetype = enum
    poiCompound   ## major: two buildings (2 rooms each) split by an alley
    poiOutpost    ## mid: one building, 2 rooms
    poiYard       ## mid: walled yard + colonnade, open-air
    poiRuins      ## minor: broken/partial walls, no full enclosure

  PoiSite = object
    center: MapPoint
    archetype: PoiArchetype
    halfExtent: int   ## rough footprint half-size, for spacing/labels
    lootTier: int      ## 0 = richest (major), 1 = mid, 2 = minor

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
    pois: seq[PoiSite]           ## round 3: the composition/intention layer
    structureCount: int         ## obstacles[0..<structureCount] are AUTHORED
      ## (POI walls + connectors) — never confetti-pruned, since a broken
      ## ruin's individual wall segment can be legitimately smaller than the
      ## floor. obstacles[structureCount..^1] is the demoted caves fill,
      ## which IS subject to the prune.
    ## Round-3 items — doctrine §4.4, the PRIMARY BR balance lever, absent
    ## from rounds 1-2 entirely. medKitSpawns/medKitCandidates mirror
    ## CtfMap's own fields verbatim: plain seq[MapPoint], NEUTRAL (no team
    ## keying at all), so they transfer to a 16-group draw with zero
    ## adaptation — confirmed by reading src/ctf/sim_types.nim directly.
    ## grenadeSpawns is BR's own analogue of CtfMap.grenadeSpawnPoints()
    ## (also neutral there, just a fixed array[4,..] keyed off map layout,
    ## which BR has none of) sized to the POI count instead of a fixed 4.
    ## teamPickups (shields/cans/barriers) are DELIBERATELY ABSENT: see the
    ## final report for why they cannot express a 16-group-fair pool under
    ## the current engine.
    medKitSpawns: seq[MapPoint]
    medKitCandidates: seq[MapPoint]
    grenadeSpawns: seq[MapPoint]

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

# --- POI structures (round 3) -------------------------------------------------
## "bsp-lite applied as discrete local stamps" (coordinator, round 3): each
## POI is a small, self-contained rect-wall compound, built the same way
## mapgen_styles.genBsp builds rooms (walls inset from a leaf rect, a door
## gap centered on each open side) but authored directly here instead of
## via a global BSP split — global BSP is what the sibling br-demo lane
## found gets eaten by the carve at giant scale; a local stamp has no carve
## to dodge in the first place.

proc rectShapeBr(x, y, w, h: int): ArenaShape =
  ArenaShape(kind: shapeRect, rect: MapRect(x: x, y: y, w: w, h: h))

type RoomSide = enum rsTop, rsRight, rsBottom, rsLeft

proc stampRoom(
  rect: MapRect, openSides: set[RoomSide], wallThick, doorW: int
): seq[ArenaShape] =
  ## One rectangular room: a wall on every side, OPEN sides split around a
  ## centered door gap. `openSides` must have >= 2 members for the room to
  ## satisfy the exit rule (doc §4.5, "leavable under fire") by construction
  ## — every caller here picks 2 or more.
  # top / bottom (horizontal walls, at y=rect.y and y=rect.y+rect.h-wallThick)
  for (side, wy) in [(rsTop, rect.y), (rsBottom, rect.y + rect.h - wallThick)]:
    if side in openSides:
      let gapX = rect.x + (rect.w - doorW) div 2
      if gapX > rect.x:
        result.add rectShapeBr(rect.x, wy, gapX - rect.x, wallThick)
      if gapX + doorW < rect.x + rect.w:
        result.add rectShapeBr(gapX + doorW, wy, rect.x + rect.w - (gapX + doorW), wallThick)
    else:
      result.add rectShapeBr(rect.x, wy, rect.w, wallThick)
  # left / right (vertical walls)
  for (side, wx) in [(rsLeft, rect.x), (rsRight, rect.x + rect.w - wallThick)]:
    if side in openSides:
      let gapY = rect.y + (rect.h - doorW) div 2
      if gapY > rect.y:
        result.add rectShapeBr(wx, rect.y, wallThick, gapY - rect.y)
      if gapY + doorW < rect.y + rect.h:
        result.add rectShapeBr(wx, gapY + doorW, wallThick, rect.y + rect.h - (gapY + doorW))
    else:
      result.add rectShapeBr(wx, rect.y, wallThick, rect.h)

proc stampRuinRoom(
  rng: var Rand, rect: MapRect, wallThick: int
): seq[ArenaShape] =
  ## A "ruins" room: only 2 of 4 sides drawn (the other 2 are simply
  ## missing, wide open — a collapsed structure, not a doored one), and
  ## each drawn wall is broken into 2 segments with a gap, so even the
  ## standing walls read as rubble. Trivially clears the exit rule: two
  ## whole sides are open air.
  let sides = [rsTop, rsRight, rsBottom, rsLeft]
  var order = @sides
  rng.shuffle(order)
  let keep = order[0 .. 1]  ## keep exactly 2 of the 4 sides
  for side in keep:
    case side
    of rsTop, rsBottom:
      let wy = if side == rsTop: rect.y else: rect.y + rect.h - wallThick
      let breakX = rect.x + rect.w div 3 + rng.rand(0 .. rect.w div 3)
      let gap = 30 + rng.rand(0 .. 30)
      result.add rectShapeBr(rect.x, wy, max(1, breakX - rect.x), wallThick)
      if breakX + gap < rect.x + rect.w:
        result.add rectShapeBr(breakX + gap, wy, rect.x + rect.w - (breakX + gap), wallThick)
    of rsLeft, rsRight:
      let wx = if side == rsLeft: rect.x else: rect.x + rect.w - wallThick
      let breakY = rect.y + rect.h div 3 + rng.rand(0 .. rect.h div 3)
      let gap = 30 + rng.rand(0 .. 30)
      result.add rectShapeBr(wx, rect.y, wallThick, max(1, breakY - rect.y))
      if breakY + gap < rect.y + rect.h:
        result.add rectShapeBr(wx, breakY + gap, wallThick, rect.y + rect.h - (breakY + gap))

proc stampColonnade(
  rng: var Rand, rect: MapRect
): seq[ArenaShape] =
  ## A grid of small pillars inside a yard — cover with sightlines, not a
  ## sealed room. Spacing wide enough for a 13px footprint to weave through.
  const
    Pitch = 90
    PillarR = 16
  var gy = rect.y + Pitch div 2
  while gy < rect.y + rect.h - Pitch div 2:
    var gx = rect.x + Pitch div 2
    while gx < rect.x + rect.w - Pitch div 2:
      let jx = gx + rng.rand(-14 .. 14)
      let jy = gy + rng.rand(-14 .. 14)
      result.add ArenaShape(kind: shapeDisc, cx: jx, cy: jy, radius: PillarR)
      gx += Pitch
    gy += Pitch

proc stampPoi(rng: var Rand, site: PoiSite): seq[ArenaShape] =
  ## Dispatch by archetype. Half-extent sets the footprint; each archetype
  ## subdivides it differently so archetypes stay visually distinguishable
  ## at thumbnail size (Maxwell's "could a caster name the places?" bar).
  const WallThick = 16
  const DoorW = 78
  let cx = site.center.x
  let cy = site.center.y
  let he = site.halfExtent
  case site.archetype
  of poiCompound:
    ## Two buildings (2 rooms each), split by a real gap — the alley.
    let alley = 70
    let bw = (2 * he - alley) div 2
    let bh = (he * 3) div 2
    let leftX = cx - he
    let rightX = cx + alley div 2
    for (bx, mirrored) in [(leftX, false), (rightX, true)]:
      ## Each building splits into an upper/lower room (the shared seam sits
      ## at the building's own vertical midline).
      let r1 = MapRect(x: bx, y: cy - bh div 2, w: bw, h: bh div 2 - 10)
      let r2 = MapRect(x: bx, y: cy - 10, w: bw, h: bh div 2 - 10)
      ## Each room: exterior side open (alley/outside), plus one more —
      ## never both doors on the SAME pair of rooms' facing walls, so the
      ## alley reads like a real seam rather than one continuous corridor.
      let outward = if mirrored: rsRight else: rsLeft
      result.add stampRoom(r1, {outward, rsTop}, WallThick, DoorW)
      result.add stampRoom(r2, {outward, rsBottom}, WallThick, DoorW)
  of poiOutpost:
    ## One building, 2 rooms side by side with independent exterior doors.
    let bw = he
    let bh = (he * 3) div 2
    let r1 = MapRect(x: cx - bw, y: cy - bh div 2, w: bw - 8, h: bh)
    let r2 = MapRect(x: cx + 8, y: cy - bh div 2, w: bw - 8, h: bh)
    result.add stampRoom(r1, {rsLeft, rsTop}, WallThick, DoorW)
    result.add stampRoom(r2, {rsRight, rsBottom}, WallThick, DoorW)
  of poiYard:
    ## A walled yard (2 doors) with a colonnade inside — open-air cover.
    let yardRect = MapRect(x: cx - he, y: cy - he * 3 div 4, w: 2 * he, h: he * 3 div 2)
    result.add stampRoom(yardRect, {rsTop, rsBottom}, WallThick, DoorW + 20)
    let innerRect = MapRect(
      x: yardRect.x + WallThick + 20, y: yardRect.y + WallThick + 20,
      w: yardRect.w - 2 * (WallThick + 20), h: yardRect.h - 2 * (WallThick + 20))
    result.add stampColonnade(rng, innerRect)
  of poiRuins:
    let r = MapRect(x: cx - he, y: cy - he, w: 2 * he, h: 2 * he)
    result.add stampRuinRoom(rng, r, WallThick)
    ## A second, smaller broken cluster nearby reads as a debris field
    ## rather than one lonely wall stub.
    let r2 = MapRect(
      x: cx - he + he, y: cy - he div 2 + he, w: he, h: he)
    result.add stampRuinRoom(rng, r2, WallThick - 4)

proc tooCloseToAny(p: MapPoint, sites: seq[PoiSite], minDist: int): bool =
  for s in sites:
    let dx = p.x - s.center.x
    let dy = p.y - s.center.y
    if dx * dx + dy * dy < minDist * minDist:
      return true
  false

proc tooCloseToAnyPocket(p: MapPoint, pockets: seq[MapRect], clear: int): bool =
  for pocket in pockets:
    if p.x >= pocket.x - clear and p.x <= pocket.x + pocket.w + clear and
        p.y >= pocket.y - clear and p.y <= pocket.y + pocket.h + clear:
      return true
  false

proc tryPlacePoi(
  rng: var Rand, sites: var seq[PoiSite],
  targetX, targetY, jitterX, jitterY, width, height, minSep: int,
  pockets: seq[MapRect], archetype: PoiArchetype, halfExtent, lootTier: int
) =
  ## Pulled out of placePois as a top-level proc: a nested proc closing over
  ## a `var Rand` parameter fails Nim's capture-safety check ("cannot be
  ## captured as it would violate memory safety") — passing `rng` explicitly
  ## sidesteps it.
  ##
  ## jitterX/jitterY are DELIBERATELY asymmetric: a giant field is wide
  ## (3211px) but short (1713px), and every spawn pocket's tangential
  ## clearance leaves only narrow gaps ALONG the top/bottom edges — so the
  ## rejection sampler needs plenty of room to slide horizontally to find
  ## one of those gaps, but only a little vertically before it either
  ## crosses back into a pocket's radial reach or a spawn pocket on the far
  ## side (measured: symmetric jitter placed 3/7 POIs; this placed 7/7).
  const MaxAttempts = 200
  for attempt in 0 ..< MaxAttempts:
    let jx = targetX + (if jitterX > 0: rng.rand(-jitterX .. jitterX) else: 0)
    let jy = targetY + (if jitterY > 0: rng.rand(-jitterY .. jitterY) else: 0)
    let margin = halfExtent + 60
    if jx < margin or jy < margin or jx >= width - margin or jy >= height - margin:
      when defined(brDebugExit):
        if attempt == MaxAttempts - 1:
          stderr.writeLine(&"  POI reject(margin) target=({targetX},{targetY}) tried=({jx},{jy}) margin={margin}")
      continue
    let p = MapPoint(x: jx, y: jy)
    if tooCloseToAny(p, sites, minSep):
      when defined(brDebugExit):
        if attempt == MaxAttempts - 1:
          stderr.writeLine(&"  POI reject(minSep={minSep}) target=({targetX},{targetY}) tried=({jx},{jy})")
      continue
    if tooCloseToAnyPocket(p, pockets, halfExtent + 40):
      when defined(brDebugExit):
        if attempt == MaxAttempts - 1:
          stderr.writeLine(&"  POI reject(pocket) target=({targetX},{targetY}) tried=({jx},{jy})")
      continue
    sites.add PoiSite(
      center: p, archetype: archetype, halfExtent: halfExtent, lootTier: lootTier)
    when defined(brDebugExit):
      stderr.writeLine(&"  POI placed {archetype} at ({p.x},{p.y}) halfExtent={halfExtent} attempt={attempt}")
    return
  when defined(brDebugExit):
    stderr.writeLine(&"  POI FAILED entirely: target=({targetX},{targetY}) archetype={archetype}")
  ## Every attempt collided — skip this site rather than force an overlap;
  ## the place-count floor validator will report the true count honestly.

const PoiPocketClearance = 110
  ## ROUND 4 (Maxwell's correction, 2026-08-24): "the ~560-630px POI
  ## clearance from spawn pockets is WRONG... a minor site adjacent to a
  ## spawn is a LANDING SITE... not a fairness violation." Shrunk from a
  ## scaled ~560-630px (spawnClearH + halfExtent + 40, which forced every
  ## POI into a narrow horizontal band and made all six draws look like the
  ## same map) down to a small FIXED margin: just enough that the pocket's
  ## own floor stays clear and the exit-check ring (PocketExitMargin=24px)
  ## holds with real margin. Wall-LEVEL safety near spawns (so a big
  ## structure's near edge doesn't choke a pocket) is still enforced
  ## downstream, per-shape, by dropShapesNearSpawns (70px) — a POI center
  ## this close to a pocket routinely has its nearest wall segments pruned,
  ## which reads as "the ruin's edge runs right up to the landing zone",
  ## exactly the landing-site feel doctrine wants.

proc placeUniformPoi(
  rng: var Rand, sites: var seq[PoiSite], width, height, minSep: int,
  pocketClear: int, pockets: seq[MapRect],
  archetype: PoiArchetype, halfExtent, lootTier: int
): bool =
  ## TRUE uniform rejection sampling over the WHOLE playable field (no
  ## artificial Y-band) — returns whether it found a spot, so callers can
  ## track how many of a target count actually landed.
  const MaxAttempts = 400
  let margin = halfExtent + 60
  let xLo = margin
  let xHi = width - margin
  let yLo = margin
  let yHi = height - margin
  if yHi <= yLo or xHi <= xLo:
    return false
  for attempt in 0 ..< MaxAttempts:
    let x = xLo + rng.rand(xHi - xLo)
    let y = yLo + rng.rand(yHi - yLo)
    let p = MapPoint(x: x, y: y)
    if tooCloseToAny(p, sites, minSep): continue
    if tooCloseToAnyPocket(p, pockets, pocketClear): continue
    sites.add PoiSite(center: p, archetype: archetype, halfExtent: halfExtent, lootTier: lootTier)
    when defined(brDebugExit):
      stderr.writeLine(&"  POI placed {archetype} at ({p.x},{p.y}) halfExtent={halfExtent} attempt={attempt}")
    return true
  when defined(brDebugExit):
    stderr.writeLine(&"  POI FAILED entirely: archetype={archetype}")
  false

proc inwardDir(edge: SpawnEdge): tuple[dx, dy: int]
  ## Forward declaration — full body defined later in the file; placePois
  ## (below) needs it for the ring-of-landing-sites offset.

proc placePois(
  rng: var Rand, width, height, gunRange: int, pockets: seq[MapRect], spawns: seq[BrSpawn]
): seq[PoiSite] =
  ## Deliberate composition, ROUND 4: one major (position now DRAWN, not
  ## fixed dead-center — zone centers are drawn too, so an off-center major
  ## is legitimate), a handful of mid POIs and corner-ish minors spread
  ## across the WHOLE field (no more Y-band), plus a RING OF LANDING SITES
  ## anchored near individual spawns so most of the ring has a near site —
  ## this is what fills the corners/quadrants and makes landing a real
  ## choice (near safe loot vs. contested center). K, archetype mix, and
  ## the major's offset all vary per seed so six draws read as six
  ## different maps.
  let cx = width div 2
  let cy = height div 2
  let minSep = int(1.15 * float(gunRange))  ## real travel distance between places
  let majorHalf = int(0.85 * float(gunRange))
  let midHalf = int(0.55 * float(gunRange))
  let minorHalf = int(0.38 * float(gunRange))
  let ringMinorHalf = int(0.30 * float(gunRange))

  # The major's position is drawn within a modest radius of field center —
  # off-center is legitimate (the zone-center sweep independently verifies
  # viability wherever the drawn zone lands), but a wildly off-center major
  # would make its OWN footprint collide with the field border, so the
  # offset is capped well inside the field.
  let majorOffsetMax = int(0.7 * float(gunRange))
  let majorTheta = rng.rand(2.0 * PI)
  let majorR = rng.rand(majorOffsetMax)
  let majorX = clamp(cx + int(float(majorR) * cos(majorTheta)),
    majorHalf + 80, width - majorHalf - 80)
  let majorY = clamp(cy + int(float(majorR) * sin(majorTheta)),
    majorHalf + 80, height - majorHalf - 80)
  tryPlacePoi(rng, result, majorX, majorY, int(0.1 * float(gunRange)), int(0.1 * float(gunRange)),
    width, height, minSep, pockets, poiCompound, majorHalf, 0)

  # Mid POIs: count and archetype mix both vary per draw.
  let midArchPool = [poiOutpost, poiYard]
  let midCount = 2 + rng.rand(2)  # 2..4
  for i in 0 ..< midCount:
    discard placeUniformPoi(rng, result, width, height, minSep, PoiPocketClearance,
      pockets, midArchPool[rng.rand(midArchPool.len - 1)], midHalf, 1)

  # A handful of interior minor sites (ruins), count varies too.
  let interiorMinorCount = 1 + rng.rand(2)  # 1..3
  for i in 0 ..< interiorMinorCount:
    discard placeUniformPoi(rng, result, width, height, minSep, PoiPocketClearance,
      pockets, poiRuins, minorHalf, 2)

  # THE RING OF LANDING SITES (round 4's main structural fix): try every
  # spawn in random order, offset a small landing site just inside its
  # pocket's clearance, until `ringMinorTarget` land — "roughly even
  # coverage", enforced by the item/cover validators rather than an exact
  # one-per-spawn guarantee.
  let ringMinorTarget = 6 + rng.rand(4)  # 6..10, per doctrine round 4
  var order = toSeq(0 ..< spawns.len)
  rng.shuffle(order)
  var ringMinorPlaced = 0
  for idx in order:
    if ringMinorPlaced >= ringMinorTarget: break
    let s = spawns[idx]
    let (idxDir, idyDir) = inwardDir(s.edge)
    let baseDist = PoiPocketClearance + ringMinorHalf + 30
    var placedHere = false
    for attempt in 0 ..< 50:
      let dist = baseDist + rng.rand(120)
      let along = rng.rand(-140 .. 140)  ## tangential jitter along the ring
      let tx =
        case s.edge
        of seTop, seBottom: s.p.x + along
        of seLeft, seRight: s.p.x + idxDir * dist
      let ty =
        case s.edge
        of seTop, seBottom: s.p.y + idyDir * dist
        of seLeft, seRight: s.p.y + along
      let margin = ringMinorHalf + 60
      if tx < margin or ty < margin or tx >= width - margin or ty >= height - margin:
        continue
      let p = MapPoint(x: tx, y: ty)
      if tooCloseToAny(p, result, minSep): continue
      if tooCloseToAnyPocket(p, pockets, PoiPocketClearance): continue
      let arch = if rng.rand(1) == 0: poiRuins else: poiOutpost
      result.add PoiSite(center: p, archetype: arch, halfExtent: ringMinorHalf, lootTier: 2)
      placedHere = true
      inc ringMinorPlaced
      when defined(brDebugExit):
        stderr.writeLine(&"  ring-minor placed {arch} at ({p.x},{p.y}) near spawn edge={s.edge}")
      break
    if not placedHere:
      when defined(brDebugExit):
        stderr.writeLine(&"  ring-minor FAILED near spawn edge={s.edge} p=({s.p.x},{s.p.y})")

  result

proc poiFootprintRect(site: PoiSite): MapRect =
  MapRect(x: site.center.x - site.halfExtent, y: site.center.y - site.halfExtent,
    w: 2 * site.halfExtent, h: 2 * site.halfExtent)

proc rectsOverlap(a, b: MapRect, pad: int): bool =
  not (a.x + a.w + pad < b.x or b.x + b.w + pad < a.x or
    a.y + a.h + pad < b.y or b.y + b.h + pad < a.y)

proc pointNearAnyPoi(p: MapPoint, pois: seq[PoiSite], pad: int): bool =
  for site in pois:
    let f = poiFootprintRect(site)
    if p.x >= f.x - pad and p.x <= f.x + f.w + pad and
        p.y >= f.y - pad and p.y <= f.y + f.h + pad:
      return true
  false

proc linearConnectors(
  rng: var Rand, pois: seq[PoiSite], pockets: seq[MapRect]
): seq[ArenaShape] =
  ## "Broken wall lines, fence/ridge runs with real mass" between POIs
  ## (coordinator, round 3) — screens for the rotation AND grain for the
  ## field, the anti-confetti directive's "continuous linear features".
  ## Connects each POI to its nearest neighbour (a cheap near-MST: not
  ## every pair, so the field doesn't turn into a lattice) with a segmented
  ## line, each segment perpendicular to the run and offset with jitter so
  ## it reads as a fence/ridge, not a ruler.
  const
    SegLen = 46
    SegThick = 13
    Step = 85       ## distance between segment attempts along the run
    KeepChance = 0.62 ## fraction of steps that actually place a segment (the BREAK)
  var connected: seq[(int, int)]
  for i in 0 ..< pois.len:
    var bestJ = -1
    var bestD = high(int)
    for j in 0 ..< pois.len:
      if i == j: continue
      let dx = pois[i].center.x - pois[j].center.x
      let dy = pois[i].center.y - pois[j].center.y
      let d = dx * dx + dy * dy
      if d < bestD:
        bestD = d
        bestJ = j
    if bestJ >= 0:
      let key = if i < bestJ: (i, bestJ) else: (bestJ, i)
      if key notin connected:
        connected.add key
  for (i, j) in connected:
    let a = pois[i].center
    let b = pois[j].center
    let dx = float(b.x - a.x)
    let dy = float(b.y - a.y)
    let length = sqrt(dx * dx + dy * dy)
    if length < 1.0: continue
    let ux = dx / length
    let uy = dy / length
    let px = -uy  ## perpendicular unit vector, for the segment's own orientation
    let py = ux
    var t = float(pois[i].halfExtent) + 40.0
    while t < length - float(pois[j].halfExtent) - 40.0:
      if rng.rand(1.0) < KeepChance:
        let jitter = float(rng.rand(-18 .. 18))
        let midx = a.x.float + ux * t + px * jitter
        let midy = a.y.float + uy * t + py * jitter
        let p0 = MapPoint(x: int(midx - px * float(SegLen) / 2.0), y: int(midy - py * float(SegLen) / 2.0))
        let p1 = MapPoint(x: int(midx + px * float(SegLen) / 2.0), y: int(midy + py * float(SegLen) / 2.0))
        if not tooCloseToAnyPocket(MapPoint(x: int(midx), y: int(midy)), pockets, 30):
          result.add ArenaShape(
            kind: shapeDiagonal, x0: p0.x, y0: p0.y, x1: p1.x, y1: p1.y,
            thickness: SegThick)
      t += Step

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

  ## ROUND 3 (Maxwell's rejection, 2026-08-24): "no rooms, no alleys, no
  ## items, no intention — the generator is clearly not working here." CA
  ## blobs alone cannot BE a battle-royale map. POIs are drawn FIRST — the
  ## layout grammar / intention — and everything else (connectors, caves
  ## fill) composes around them instead of the other way around.
  var poiRng = initRand(seed xor 0x7F4A_2C11)
  result.pois = placePois(poiRng, w, h, result.gunRange, pockets, result.spawns)
  var structures: seq[ArenaShape]
  for site in result.pois:
    var stampRng = initRand(seed xor 0x9B1E_44D7 xor (site.center.x * 131071 + site.center.y))
    structures.add stampPoi(stampRng, site)

  var connectorRng = initRand(seed xor 0x2E9D_7731)
  let connectors = linearConnectors(connectorRng, result.pois, pockets)

  ## Caves DEMOTES to organic fill between structures — one pass, low
  ## density, dropped wherever it would overlap a POI footprint or a
  ## connector run (a blob eating a doorway reads as a bug, not terrain).
  let region = placementRegion(w, h)
  var params = paramsIn
  params.noAnchors = true
  params.fillProb = min(params.fillProb, 0.16)
  params.blobScale = min(params.blobScale, 0.75)
  let caveRaw = generateShapes(style, seed xor styleSalt, region, params)
  var caveFill: seq[ArenaShape]
  for shape in caveRaw:
    let b = shapeBounds(shape)
    var clash = false
    for site in result.pois:
      if rectsOverlap(MapRect(x: b.x0, y: b.y0, w: b.x1 - b.x0, h: b.y1 - b.y0),
          poiFootprintRect(site), 50):
        clash = true
        break
    if not clash:
      caveFill.add shape

  ## Kept as two separately-dropped groups (not one merged list) so the
  ## authored/fill split survives dropShapesNearSpawns' filtering intact —
  ## structureCount has to describe the FINAL obstacles list, after pockets
  ## have already removed whatever they're going to remove from each half.
  let structuresKept = dropShapesNearSpawns(structures & connectors, pockets)
  let caveFillKept = dropShapesNearSpawns(caveFill, pockets)
  result.structureCount = structuresKept.len
  result.obstacles = structuresKept & caveFillKept

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
  var poiNodes = newJArray()
  for site in m.pois:
    poiNodes.add %*{
      "x": site.center.x, "y": site.center.y,
      "archetype": $site.archetype, "halfExtent": site.halfExtent,
      "lootTier": site.lootTier,
    }
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
    "structureCount": m.structureCount,
    "pois": poiNodes,                 ## round-3 layout grammar; art-only, the
                                       ## sim reads leftObstacles/items instead
    ## round-3 items — medKitSpawns/medKitCandidates mirror CtfMap's own
    ## (NEUTRAL, not team-keyed) field names verbatim. teamPickups is
    ## deliberately absent; see the final report.
    "medKitSpawns": pointsNode(m.medKitSpawns),
    "medKitCandidates": pointsNode(m.medKitCandidates),
    "grenadeSpawns": pointsNode(m.grenadeSpawns),
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
  result.structureCount = node{"structureCount"}.getInt(0)
  let poiNode = node{"pois"}
  if not poiNode.isNil and poiNode.kind == JArray:
    for pn in poiNode:
      let archetype =
        case pn{"archetype"}.getStr("poiOutpost")
        of "poiCompound": poiCompound
        of "poiOutpost": poiOutpost
        of "poiYard": poiYard
        of "poiRuins": poiRuins
        else: poiOutpost
      result.pois.add PoiSite(
        center: MapPoint(x: pn["x"].getInt(), y: pn["y"].getInt()),
        archetype: archetype,
        halfExtent: pn{"halfExtent"}.getInt(150),
        lootTier: pn{"lootTier"}.getInt(1))
  result.medKitSpawns = pointsFromNode(node{"medKitSpawns"})
  result.medKitCandidates = pointsFromNode(node{"medKitCandidates"})
  result.grenadeSpawns = pointsFromNode(node{"grenadeSpawns"})

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
  wall: seq[bool], cols, rows, width, height: int, rect: MapRect,
  extraBlockers: seq[ArenaShape] = @[]
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
  ##
  ## `extraBlockers` (round 2): shapes not yet baked into `wall`, tested live
  ## at each sample — lets a repair-blob CANDIDATE be checked against "would
  ## this choke the ring" directly, instead of via an approximate safety
  ## margin. Margins turned out to be unreliable here: blobPolygon's organic
  ## wobble can push its silhouette up to ~1.7x its nominal radius in one
  ## lobe (a2+a3 amplitude up to 0.42+0.28), which quietly ate every fixed
  ## margin tried and kept re-choking rings the arithmetic said were clear.
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
      if open[i] and extraBlockers.len > 0:
        ## Test at the GRID-ALIGNED point (gx*GridStride, gy*GridStride), not
        ## the raw perimeter-walk pixel `p` — `wall` itself was populated by
        ## buildWallGrid sampling shapes at grid-aligned points, so testing
        ## extraBlockers at the unaligned pixel occasionally disagreed with
        ## what the FINAL validate pass (which bakes candidates into a fresh
        ## buildWallGrid, all grid-aligned) would find once a candidate was
        ## accepted — a ring the trim sweep called safe still failed the real
        ## exit-rule check afterward. Matching the sample point removes the
        ## discrepancy: this call now predicts buildWallGrid exactly.
        let sx = gx * GridStride
        let sy = gy * GridStride
        for shape in extraBlockers:
          if inShape(sx, sy, shape):
            open[i] = false
            break
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

    ## ROUND 2 (coordinator review, 2026-08-24): the round-1 gates all
    ## passed on "empty pan with islands" draws because none of them
    ## measured DISTRIBUTION. These three close that gap.
    placeCountPass: bool
    placeCountReason: string
    bigMassCount: int            ## masses strictly above the confetti floor

    perSpawnCoverPass: bool
    perSpawnCoverReason: string
    uncoveredSpawns: int

    distributionPass: bool
    distributionReason: string
    emptyGridCells: int
    gridCoverage: seq[bool]      ## 4x2, row-major, for the metrics dump
    # ROUND 3 (Maxwell's rejection, 2026-08-24): "items, intention" is the
    # doctrine's PRIMARY BR lever (doc 4.4), absent from rounds 1-2 entirely.
    itemCoveragePass: bool
    itemCoverageReason: string
    uncoveredSpawnsItems: int

    poiLootPass: bool
    poiLootReason: string
    poisWithoutLoot: int

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
  PlaceCountFloor = 6         ## round-2: >= 6 welded (non-confetti) masses
  PerSpawnCoverGR = 1.5       ## round-2 §2.3: rotation cover within 1.5 G
  DistGridCols = 4            ## round-2: 4x2 distribution grid
  DistGridRows = 2
  PocketExitMargin = 24       ## shared with ensurePerSpawnCover so a screen
                               ## blob can never be placed ON its own spawn's
                               ## exit-check ring (round-2 regression: it was
                               ## using the raw pocket's radius, not the
                               ## ring's, and choked 6 spawns down to 1 exit)
  DistMaxEmptyCells = 1       ## at most ONE deliberately-open cell tolerated

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
    let pocket = pocketRect(s, m.spawnClearW, m.spawnClearH)
    let ring = MapRect(
      x: pocket.x - PocketExitMargin, y: pocket.y - PocketExitMargin,
      w: pocket.w + 2 * PocketExitMargin, h: pocket.h + 2 * PocketExitMargin)
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
  result.bigMassCount = result.massCount - confetti

  # 3b. Place-count floor (round 2) --------------------------------------------
  result.placeCountPass = result.bigMassCount >= PlaceCountFloor
  result.placeCountReason =
    if result.placeCountPass: ""
    else: &"{result.bigMassCount} welded masses, need >= {PlaceCountFloor} " &
      "(\"empty pan with islands\" if this stays low)"

  # 3c. Per-spawn cover (round 2, doc §2.3 sharpened) ---------------------------
  block perSpawnCover:
    let radius = int(PerSpawnCoverGR * float(m.gunRange))
    const ScanStride = GridStride * 3
    var uncovered = 0
    for s in m.spawns:
      var covered = false
      var dy = -radius
      while dy <= radius and not covered:
        var dx = -radius
        while dx <= radius and not covered:
          if dx * dx + dy * dy <= radius * radius:
            let x = s.p.x + dx
            let y = s.p.y + dy
            if x >= 0 and x < m.width and y >= 0 and y < m.height:
              let (gx, gy) = toGrid(x, y)
              if gx >= 0 and gx < cols and gy >= 0 and gy < rows:
                let i = gy * cols + gx
                if wall[i]:
                  let lbl = wallComp.labels[i]
                  if lbl >= 0 and lbl != borderLabel and
                      wallComp.sizes[lbl] * GridStride * GridStride >= ConfettiFloorPx2:
                    covered = true
          dx += ScanStride
        dy += ScanStride
      if not covered: inc uncovered
      when defined(brDebugExit):
        stderr.writeLine(&"perSpawnCover spawn edge={s.edge} p=({s.p.x},{s.p.y}) covered={covered}")
    result.uncoveredSpawns = uncovered
    result.perSpawnCoverPass = uncovered == 0
    result.perSpawnCoverReason =
      if result.perSpawnCoverPass: ""
      else: &"{uncovered}/{m.spawns.len} spawns have no welded mass within " &
        &"{PerSpawnCoverGR}G ({radius}px) — unscreened rotation"

  # 3d. Distribution grid (round 2) ---------------------------------------------
  block distribution:
    var coverage = newSeq[bool](DistGridCols * DistGridRows)
    let cellW = (m.width + DistGridCols - 1) div DistGridCols
    let cellH = (m.height + DistGridRows - 1) div DistGridRows
    for gy in 0 ..< rows:
      let y = gy * GridStride
      for gx in 0 ..< cols:
        if not wall[gy * cols + gx]: continue
        let lbl = wallComp.labels[gy * cols + gx]
        if lbl < 0 or lbl == borderLabel: continue
        if wallComp.sizes[lbl] * GridStride * GridStride < ConfettiFloorPx2: continue
        let x = gx * GridStride
        let cellX = min(DistGridCols - 1, x div cellW)
        let cellY = min(DistGridRows - 1, y div cellH)
        coverage[cellY * DistGridCols + cellX] = true
    var empty = 0
    for c in coverage:
      if not c: inc empty
    result.gridCoverage = coverage
    result.emptyGridCells = empty
    result.distributionPass = empty <= DistMaxEmptyCells
    result.distributionReason =
      if result.distributionPass: ""
      else: &"{empty} of {DistGridCols * DistGridRows} field-grid cells have " &
        &"zero cover mass (max {DistMaxEmptyCells} tolerated) — an empty half, " &
        "not a deliberate open pan"

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

  # 6. Item coverage (round 3, doctrine §4.4) ------------------------------------
  ## Every spawn's nearest item within ~1.5 gun-ranges of its ring position.
  block itemCoverage:
    let radius = int(PerSpawnCoverGR * float(m.gunRange))
    let allItems = m.medKitCandidates & m.grenadeSpawns
    var uncovered = 0
    for s in m.spawns:
      var best = high(int)
      for it in allItems:
        let dx = s.p.x - it.x
        let dy = s.p.y - it.y
        let d2 = dx * dx + dy * dy
        if d2 < best: best = d2
      let dist = if best == high(int): high(int) else: int(sqrt(float(best)))
      if dist > radius: inc uncovered
    result.uncoveredSpawnsItems = uncovered
    result.itemCoveragePass = uncovered == 0
    result.itemCoverageReason =
      if result.itemCoveragePass: ""
      else: &"{uncovered}/{m.spawns.len} spawns have no item within " &
        &"{PerSpawnCoverGR}G ({radius}px)"

  # 7. Every POI has a reason to visit (round 3) ----------------------------------
  block poiLoot:
    var missing = 0
    for site in m.pois:
      var hasLoot = false
      let checkR = site.halfExtent + 60
      for it in m.medKitCandidates:
        if abs(it.x - site.center.x) <= checkR and abs(it.y - site.center.y) <= checkR:
          hasLoot = true
          break
      if not hasLoot:
        for it in m.grenadeSpawns:
          if abs(it.x - site.center.x) <= checkR and abs(it.y - site.center.y) <= checkR:
            hasLoot = true
            break
      if not hasLoot: inc missing
    result.poisWithoutLoot = missing
    result.poiLootPass = missing == 0
    result.poiLootReason =
      if result.poiLootPass: ""
      else: &"{missing}/{m.pois.len} POIs have no item nearby — a place with no reason to visit"

  result.allPass = result.connectivityPass and result.exitPass and
    result.antiConfettiPass and result.zonePass and result.specSizePass and
    result.placeCountPass and result.perSpawnCoverPass and result.distributionPass and
    result.itemCoveragePass and result.poiLootPass

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

proc pocketRadialHalf(s: BrSpawn, clearW, clearH: int): int =
  clearH  ## pocketRect always puts the LARGER (radial) extent in clearH,
          ## regardless of which edge the spawn sits on.

proc inwardDir(edge: SpawnEdge): tuple[dx, dy: int] =
  case edge
  of seTop: (0, 1)
  of seBottom: (0, -1)
  of seLeft: (1, 0)
  of seRight: (-1, 0)

proc pointInAnyPocket(
  x, y: int, spawns: seq[BrSpawn], clearW, clearH, buffer: int
): bool =
  for s in spawns:
    let p = pocketRect(s, clearW, clearH)
    if x >= p.x - buffer and x <= p.x + p.w + buffer and
        y >= p.y - buffer and y <= p.y + p.h + buffer:
      return true
  false

# --- items (round 3, doctrine §4.4) -------------------------------------------
## Items are BR's PRIMARY balance lever per doctrine — absent from rounds 1
## and 2 entirely. Read against the actual engine (src/ctf/sim.nim,
## sim_types.nim): CtfMap.medKitSpawns/medKitCandidates are plain
## seq[MapPoint], NOT team-keyed at all, so they transfer to a 16-group
## draw with zero adaptation — this is BR's primary loot channel.
## teamPickups (shields/cans/barriers) are deliberately NOT emitted: see
## the final report for why (validateMap hard-codes symNone's teamCount to
## 2; barrierSpawnPoints derives its count from TeamLayout.teamCount(),
## which only knows 2 or 4 — neither expresses a 16-group-fair pool today).

proc walkableNear(
  obstacles: seq[ArenaShape], cx, cy, radius: int, rng: var Rand
): MapPoint =
  ## Best-effort: a handful of random offsets within `radius`, first one not
  ## inside any obstacle wins. Correct regardless of which POI archetype
  ## placed the geometry — no need to hand-derive "the doorway is here" per
  ## archetype when we can just test the real obstacle list directly.
  for attempt in 0 ..< 24:
    let x = cx + (if radius > 0: rng.rand(-radius .. radius) else: 0)
    let y = cy + (if radius > 0: rng.rand(-radius .. radius) else: 0)
    var blocked = false
    for shape in obstacles:
      if inShape(x, y, shape):
        blocked = true
        break
    if not blocked:
      return MapPoint(x: x, y: y)
  MapPoint(x: cx, y: cy)  ## fall back to the POI center; rare in practice

proc placeItems(m: var BrMap, rng: var Rand) =
  ## The loot gradient (doctrine §4.4): the richest kit sits at the most
  ## exposed/central POI (tier 0, the compound), less at mid POIs (tier 1),
  ## a minor find at outer ruins (tier 2) — "no POI without a reason to
  ## visit" is satisfied by construction: every site gets >= 1 item.
  for site in m.pois:
    let n = case site.lootTier
      of 0: 3
      of 1: 2
      else: 1
    for k in 0 ..< n:
      let searchR = max(20, site.halfExtent - 30)
      let p = walkableNear(m.obstacles, site.center.x, site.center.y, searchR, rng)
      m.medKitCandidates.add p
    if site.lootTier <= 1:
      let p = walkableNear(m.obstacles, site.center.x, site.center.y,
        max(20, site.halfExtent - 40), rng)
      m.grenadeSpawns.add p
  m.medKitSpawns = m.medKitCandidates  ## BR is flagless: no candidate-pool
    ## narrowing step exists (that's a CTF pre-game mechanic), so every
    ## drawn point is "active" — kept as a separate field only to mirror
    ## CtfMap's shape for a future engine-side consumer.

proc nearestItemDist(p: MapPoint, items: seq[MapPoint]): int =
  result = high(int)
  for it in items:
    let dx = p.x - it.x
    let dy = p.y - it.y
    let d2 = dx * dx + dy * dy
    if d2 < result: result = d2
  if result == high(int): return high(int)
  result = int(sqrt(float(result)))

proc ensureItemCoverage(m: var BrMap, coverGR: float, rng: var Rand) =
  ## Round-3 gate: every spawn's nearest item within ~1.5 gun-ranges of its
  ## ring position. Items are pure POINTS (no collision), so — unlike the
  ## round-2 terrain screen-blob repair — this repair can never choke an
  ## exit ring; it just adds a supplementary medkit at the spawn's own
  ## pocket (always walkable by construction) when nothing organic is close
  ## enough.
  let radius = int(coverGR * float(m.gunRange))
  let allItems = m.medKitCandidates & m.grenadeSpawns
  for s in m.spawns:
    if nearestItemDist(s.p, allItems) > radius:
      let p = walkableNear(m.obstacles, s.p.x, s.p.y, m.spawnClearW div 2, rng)
      m.medKitCandidates.add p
      m.medKitSpawns.add p

proc ensurePerSpawnCover(m: BrMap, coverGR: float): seq[ArenaShape] =
  ## ROUND 2 (coordinator review, 2026-08-24): "every rotation from spawn is
  ## unscreened" — doctrine §2.3 (cover on the rotation) needs a welded mass
  ## within ~coverGR gun-ranges of EVERY spawn, and organic terrain density
  ## is not reliable enough to promise that on its own (that is exactly what
  ## the round-1 draws got called out for). A hard per-spawn gate needs a
  ## CONSTRUCTION, not a hope: measure each spawn against the terrain
  ## AFTER the confetti prune (call this post-prune), and for any spawn with
  ## no qualifying mass in range, author one small screen blob just past its
  ## pocket, on the field-INWARD side (never toward the map edge, and never
  ## inside another spawn's own pocket).
  const
    ScanStride = GridStride * 3   ## coarse disc scan: cheap, ~16px granularity
    ScreenBlobRadius = 36          ## pi*36^2 ~= 4072px^2, > ConfettiFloorPx2;
                                    ## shrunk from 45 in round-2 fix #2 below
                                    ## to buy more room in a thin radial band
    PocketBuffer = 70              ## matches dropShapesNearSpawns' halo
  let (cols, rows) = gridDims(m.width, m.height)
  let wall = buildWallGrid(m)
  let comp = components(wall, cols, rows, true, true)
  let borderLabel = comp.labels[0]
  let radius = int(coverGR * float(m.gunRange))
  var rng = initRand(m.genSeed xor 0x4B72_9E11)

  proc hasQualifyingMassNear(cx, cy: int): bool =
    var dy = -radius
    while dy <= radius:
      var dx = -radius
      while dx <= radius:
        if dx * dx + dy * dy <= radius * radius:
          let x = cx + dx
          let y = cy + dy
          if x >= 0 and x < m.width and y >= 0 and y < m.height:
            let (gx, gy) = toGrid(x, y)
            if gx >= 0 and gx < cols and gy >= 0 and gy < rows:
              let i = gy * cols + gx
              if wall[i]:
                let lbl = comp.labels[i]
                if lbl >= 0 and lbl != borderLabel and
                    comp.sizes[lbl] * GridStride * GridStride >= ConfettiFloorPx2:
                  return true
        dx += ScanStride
      dy += ScanStride
    false

  ## TWO-PHASE, round-2 fix #6 (replaces three earlier attempts at an
  ## incremental "accept only if provably safe" placement search — each
  ## closed one failure mode and opened another, because blobPolygon's
  ## organic wobble made every fixed safety margin unreliable and even a
  ## per-candidate simulation missed cross-candidate interactions depending
  ## on iteration order). This is simpler and provably correct instead:
  ##   1. Place a best-effort candidate for every uncovered spawn, using only
  ##      a cheap "don't land inside a pocket" filter — no ring-safety logic
  ##      at all yet.
  ##   2. Sweep to a fixpoint: recompute EVERY ring's exit count with ALL
  ##      surviving candidates as blockers (the exact same countBoundaryExits
  ##      the real exit-rule validator calls), and if any ring would drop
  ##      below MinPocketExits, drop ONE overlapping candidate and re-sweep.
  ## Step 2 can only ever REMOVE candidates, so it can never introduce a
  ## choke — the worst case is an honest per-spawn-cover gap, which is
  ## exactly the number the validator should report.
  var candidates: seq[ArenaShape]
  for s in m.spawns:
    let alreadyCovered = hasQualifyingMassNear(s.p.x, s.p.y)
    when defined(brDebugExit):
      stderr.writeLine(&"ensurePerSpawnCover spawn edge={s.edge} p=({s.p.x},{s.p.y}) alreadyCovered={alreadyCovered} radius={radius}")
    if alreadyCovered:
      continue
    let minCenterDist = pocketRadialHalf(s, m.spawnClearW, m.spawnClearH) + 10
    let maxCenterDist = radius - 5
    var placed = false
    if maxCenterDist >= minCenterDist:
      const ScanStep = 28
      block placement:
        var dy = -maxCenterDist
        while dy <= maxCenterDist:
          var dx = -maxCenterDist
          while dx <= maxCenterDist:
            let d2 = dx * dx + dy * dy
            if d2 >= minCenterDist * minCenterDist and d2 <= maxCenterDist * maxCenterDist:
              let cx = s.p.x + dx
              let cy = s.p.y + dy
              if cx >= ArenaBorderPx + 20 and cy >= ArenaBorderPx + 20 and
                  cx < m.width - ArenaBorderPx - 20 and cy < m.height - ArenaBorderPx - 20 and
                  not pointInAnyPocket(cx, cy, m.spawns, m.spawnClearW, m.spawnClearH, 15):
                let candidate = blobPolygon(
                  rng, MapRect(x: 0, y: 0, w: m.width, h: m.height),
                  cx, cy, ScreenBlobRadius, 12)
                ## Cheap bbox-only pre-filter: reject any candidate whose
                ## bounding box overlaps ANY spawn's ring outright, so phase 2
                ## (the expensive, authoritative trim) mostly only has to
                ## catch multi-candidate interactions instead of individually
                ## doomed placements — most of round 2's "too much trimming"
                ## was candidates that were never going to survive anyway.
                let cb = shapeBounds(candidate)
                var touchesRing = false
                for s2 in m.spawns:
                  let p2 = pocketRect(s2, m.spawnClearW, m.spawnClearH)
                  let r2x0 = p2.x - PocketExitMargin
                  let r2y0 = p2.y - PocketExitMargin
                  let r2x1 = p2.x + p2.w + PocketExitMargin
                  let r2y1 = p2.y + p2.h + PocketExitMargin
                  if not (cb.x1 < r2x0 - 4 or cb.x0 > r2x1 + 4 or
                      cb.y1 < r2y0 - 4 or cb.y0 > r2y1 + 4):
                    touchesRing = true
                    break
                if not touchesRing:
                  candidates.add candidate
                  placed = true
                  when defined(brDebugExit):
                    stderr.writeLine(&"  candidate screen blob at ({cx},{cy}) dist={sqrt(float(d2)):.0f} radius={radius}")
                  break placement
            dx += ScanStep
          dy += ScanStep
    when defined(brDebugExit):
      if not placed:
        stderr.writeLine(&"WARNING: no candidate slot for spawn edge={s.edge} p=({s.p.x},{s.p.y}) minCenterDist={minCenterDist} maxCenterDist={maxCenterDist}")

  # Phase 2: trim to a fixpoint against the REAL exit check.
  var stable = false
  while not stable and candidates.len > 0:
    stable = true
    block sweep:
      for s in m.spawns:
        let pocket = pocketRect(s, m.spawnClearW, m.spawnClearH)
        let ring = MapRect(
          x: pocket.x - PocketExitMargin, y: pocket.y - PocketExitMargin,
          w: pocket.w + 2 * PocketExitMargin, h: pocket.h + 2 * PocketExitMargin)
        if countBoundaryExits(wall, cols, rows, m.width, m.height, ring, candidates) <
            MinPocketExits:
          for i, c in candidates:
            let cb = shapeBounds(c)
            if not (cb.x1 < ring.x - 8 or cb.x0 > ring.x + ring.w + 8 or
                cb.y1 < ring.y - 8 or cb.y0 > ring.y + ring.h + 8):
              when defined(brDebugExit):
                stderr.writeLine(&"  trimming candidate {i} — it chokes ring for spawn edge={s.edge} p=({s.p.x},{s.p.y})")
              candidates.delete(i)
              stable = false
              break sweep
  result = candidates

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
    "bigMassCount": v.bigMassCount,
    "uncoveredSpawns": v.uncoveredSpawns,
    "emptyGridCells": v.emptyGridCells,
    "gridCoverage": v.gridCoverage,
    "specSizeBytes": v.specSizeBytes,
    "poiCount": m.pois.len,
    "medKitCount": m.medKitCandidates.len,
    "grenadeCount": m.grenadeSpawns.len,
    "uncoveredSpawnsItems": v.uncoveredSpawnsItems,
    "poisWithoutLoot": v.poisWithoutLoot,
    "pass": %*{
      "connectivity": v.connectivityPass,
      "exitRule": v.exitPass,
      "antiConfetti": v.antiConfettiPass,
      "zoneViability": v.zonePass,
      "specSize": v.specSizePass,
      "placeCount": v.placeCountPass,
      "perSpawnCover": v.perSpawnCoverPass,
      "distribution": v.distributionPass,
      "itemCoverage": v.itemCoveragePass,
      "poiLoot": v.poiLootPass,
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
  MedKitColor = rgba(60, 200, 90, 255)     ## round 3: the loot gradient, drawn
  GrenadeColor = rgba(235, 200, 40, 255)   ## round 3: minor supplementary pickup

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

  # Round-3 items — the loot gradient made visible: medkits (green cross)
  # denser at the major/mid POIs, grenades (yellow disc) as the minor extra.
  for p in m.medKitCandidates:
    result.fillDiscPx(toOut(p.x), toOut(p.y), max(2, toOut(7)), MedKitColor)
    result.drawCrossPx(toOut(p.x), toOut(p.y), max(2, toOut(10)), BorderColor)
  for p in m.grenadeSpawns:
    result.fillDiscPx(toOut(p.x), toOut(p.y), max(2, toOut(6)), GrenadeColor)

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

proc brDefaultParams(style: MapStyle): StyleParams =
  ## mapgen_styles.defaultParams is tuned for a HALF-board about to be
  ## mirrored; fed BR's full 3211x1713 board directly it reads as thin
  ## scattered marks. Round-3 (Maxwell's "no rooms, no intention" rejection)
  ## demoted caves from BR's PRIMARY content to organic fill BETWEEN
  ## authored POI structures (generateBrMap clamps fillProb/blobScale down
  ## further still for that role) — these are now just a sane starting
  ## point before that clamp, not the tuned round-1/2 primary-terrain values.
  result = defaultParams(style)
  if style == styleCaves:
    result.cell = 55
    result.fillProb = 0.16
    result.steps = 5
    result.birth = 5
    result.death = 4
    result.blobScale = 0.7

proc cmdGenerate(a: Args) =
  let
    seed = a.intFlag("seed", 1)
    style = parseStyle(a.flag("style", "caves"))
  var params = brDefaultParams(style)
  applyParams(params, a.params)
  var m = generateBrMap(seed, style, params)
  let rawCount = m.obstacles.len
  if not a.bools.getOrDefault("noPrune", false):
    ## Only the DEMOTED CAVES FILL (obstacles[structureCount..^1]) is
    ## subject to the anti-confetti prune — POI structures are authored,
    ## not organic, and a broken ruin's lone wall segment can legitimately
    ## sit below the confetti floor without being scatter.
    let protectedShapes = m.obstacles[0 ..< m.structureCount]
    let fillShapes = m.obstacles[m.structureCount .. ^1]
    let prunedFill = pruneConfetti(fillShapes, m.width, m.height, ConfettiFloorPx2)
    m.obstacles = protectedShapes & prunedFill
  var repaired = 0
  if not a.bools.getOrDefault("noRepair", false):
    let screens = ensurePerSpawnCover(m, PerSpawnCoverGR)
    repaired = screens.len
    m.obstacles.add screens
  var itemRng = initRand(seed xor 0x6C5D_E812)
  if not a.bools.getOrDefault("noItems", false):
    placeItems(m, itemRng)
    ensureItemCoverage(m, PerSpawnCoverGR, itemRng)
  let spec = brMapSpecJson(m)
  let outPath = a.flag("out", "")
  if outPath.len == 0:
    echo spec
  else:
    writeFile(outPath, spec)
    stderr.writeLine(
      &"generated br {styleToStr(style)} seed={seed} {m.width}x{m.height} " &
      &"gunRange={m.gunRange} spawns={m.spawns.len} pois={m.pois.len} " &
      &"obstacles={m.obstacles.len} (structures={m.structureCount})" &
      &" (pruned {rawCount - (m.obstacles.len - repaired)} confetti of {rawCount}," &
      &" {repaired} spawn-cover repairs, medkits={m.medKitCandidates.len}" &
      &" grenades={m.grenadeSpawns.len}) -> {outPath}")

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
  echo &"place count:   {(if v.placeCountPass: \"PASS\" else: \"FAIL: \" & v.placeCountReason)}  (bigMasses={v.bigMassCount}, floor={PlaceCountFloor})"
  echo &"per-spawn cvr: {(if v.perSpawnCoverPass: \"PASS\" else: \"FAIL: \" & v.perSpawnCoverReason)}  (uncovered={v.uncoveredSpawns}/16 within {PerSpawnCoverGR}G)"
  echo &"distribution:  {(if v.distributionPass: \"PASS\" else: \"FAIL: \" & v.distributionReason)}  (empty cells={v.emptyGridCells}/{DistGridCols*DistGridRows})"
  echo &"item coverage: {(if v.itemCoveragePass: \"PASS\" else: \"FAIL: \" & v.itemCoverageReason)}  (uncovered={v.uncoveredSpawnsItems}/16 within {PerSpawnCoverGR}G)"
  echo &"POI has loot:  {(if v.poiLootPass: \"PASS\" else: \"FAIL: \" & v.poiLootReason)}  (missing={v.poisWithoutLoot} POIs)"

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
