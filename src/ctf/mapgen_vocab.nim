## The SHAPE VOCABULARY: named terrain features a map is composed FROM.
##
## This module replaces the four interchangeable "column families" the old
## generator shipped (`colStubs` / `colDiamonds` / `colDiscs` / `colChevrons`),
## which were four SKINS on one uniform column lattice: swapping family changed
## what a pixel looked like, never what the map was. A vocabulary item here is
## a FEATURE — a thing a player names, walks around, and fights through.
##
## Every constructor is a pure function of `(rng, region, params)`, matching the
## house convention in `mapgen_styles.nim`, so a scene graph can compose them:
##
##   var r = initRand(seed)
##   let p = vocabParams(mapRules("standard", 2))
##   shapes.add doritos(r, slot, p)
##
## Contract for every constructor:
##   * every emitted shape lies wholly inside `region` (`shapeBounds` clipped),
##   * output is a deterministic function of the RNG state and the inputs,
##   * every emitted polygon is a simple closed ring of at least three integer
##     vertices and at most `MaxPolygonVerts`, well-formed for
##     `arena.pointInPolygon` (whose STRICT `ylo < y < yhi` straddle is a
##     fairness invariant this module never asks to be loosened),
##   * nothing here knows about symmetry, carve, endzones or validation. Those
##     stay in `arena.nim` exactly as they do for `mapgen_styles`.
##
## SIZING IS DERIVED, NOT CHOSEN. Everything scales off `MapRules.coverSizePx`
## (56 * sqrt(scale): 52 small .. 128 colossal). The reference literals in the
## design brief — doritos r22-34, cans r18-40 — are quoted at the STANDARD
## class and re-expressed here as fractions of `RefCoverPx`, so a giant board
## gets giant cover instead of the standard map photocopied at 260%.
##
## PASSABILITY FLOOR. Every gap this module deliberately leaves open — the gap
## inside a bunker cluster, the mouth of a cave, the spacing between cans — is
## at least `VocabParams.corridorPx`, which `mapRules` sets to
## `RecommendedCorridorWidthPx` = 68 px: two DRAWN cog bodies abreast, NOT the
## 26 px `MinCorridorWidth` collision floor. A gap you can only pass single
## file in a straight line is not a gap you fight through.

import std/[math, random]
import sim_types
import map_rules

const
  MaxPolygonVerts* = 48
    ## Hard ceiling on vertices in one emitted polygon, matching the private
    ## `BlobMaxVerts` in `mapgen_styles.nim`. A massif is a union of many
    ## discs and blows straight past this if traced naively; see `ridgeHull`
    ## for how the budget is met (profile scan + Douglas-Peucker, then a
    ## SPLIT into several polygons rather than a coarser single one).

  RefCoverPx* = 56
    ## The standard class's `coverSizePx`. Every literal from the design brief
    ## is quoted at this scale and stored as a fraction of it.

type
  VocabItem* = enum
    ## The composable vocabulary. `viTemple` is the only item that is plainly
    ## rectangular; the brief's "no more than half the shapes on a finished
    ## map may be plain rects/bars" is a budget on how often a composer picks
    ## it, and `rectShare` measures compliance for a finished shape list.
    viDorito        ## angled bunker: a stepped run of diamonds
    viCan           ## free-standing disc pillars you wrap a fight around
    viSnake         ## a low diagonal run down one flank
    viBeam          ## thick diagonal / wedge — the visual workhorse
    viTemple        ## medium rect, a solid anchor
    viBunker        ## 2-3 DIFFERENT kinds around one fightable gap
    viMassif        ## organic lumpy mass: discs walked along a jittered spine
    viCave          ## two near-parallel massifs with a passable gap between

  VocabParams* = object
    ## The derived scale inputs. Build with `vocabParams(mapRules(...))`;
    ## never hand-fill `coverSizePx`, it is the whole point that it is derived.
    coverSizePx*: int
      ## `MapRules.coverSizePx`. THE scale knob: a disc of cover size has
      ## diameter `coverSizePx`.
    corridorPx*: int
      ## `MapRules.minCorridorWidthPx` (68). The passability floor for every
      ## gap this module authors. Regime-invariant: it is set by the drawn cog
      ## body, not by the board.
    maxExposedRunPx*: int
      ## `MapRules.maxExposedRunPx` (132, regime-invariant). The longest
      ## stretch of a route that may lack cover — the ceiling on how far apart
      ## a composer may space these features and still leave a survivable
      ## route. Carried here so a composer reads one object.
    density*: float
      ## Multiplier on how many shapes an item emits, 1.0 = nominal. Clamped
      ## into [0.5, 1.6] on read.
    mirrorIsVertical*: bool
      ## True when the symmetry that will be applied downstream reflects
      ## ACROSS a vertical line (`x -> width-1-x`) — which is `symMirror` and
      ## `symRot180` on the rect board, i.e. every 2-team map that ships.
      ##
      ## This is not a styling knob, it is a FAIRNESS input, and it exists
      ## because of `arena.pointInPolygon`'s strict straddle. A traced ridge is
      ## mirror-exact only when its two profiles carry vertices at matching
      ## SCAN ROWS, which in turn is only possible when the ridge's run axis is
      ## PERPENDICULAR to the mirror line (see `pairedSimplify`). Measured over
      ## twelve massifs: 3,458 asymmetric wall pixels run the fair way, 147,906
      ## run the other way — 0.5% versus 21%. So `massif` and `cave` take their
      ## run axis from this flag, NOT from the shape of the region they are
      ## handed, and `vocabFootprint` reports their footprint already oriented.

# ---------------------------------------------------------------------------
# Derived sizes
# ---------------------------------------------------------------------------

func vocabParams*(rules: MapRules): VocabParams =
  ## THE constructor. Reads only derived quantities; no literal survives.
  VocabParams(
    coverSizePx: rules.coverSizePx,
    corridorPx: rules.minCorridorWidthPx,
    maxExposedRunPx: rules.maxExposedRunPx,
    density: 1.0,
    mirrorIsVertical: true)

func vocabParams*(sizeName: string, teamCount: int): VocabParams {.inline.} =
  vocabParams(mapRules(sizeName, teamCount))

func atRef(p: VocabParams, refPx: int): int {.inline.} =
  ## Re-express a length quoted at the STANDARD class in this class's scale.
  max(1, p.coverSizePx * refPx div RefCoverPx)

func doritoRadius*(p: VocabParams): tuple[lo, hi: int] =
  ## Brief: diamonds r22-34 at the standard class.
  (p.atRef(22), p.atRef(34))

func canRadius*(p: VocabParams): tuple[lo, hi: int] =
  ## Brief: discs r18-40 at the standard class.
  (p.atRef(18), p.atRef(40))

func beamThickness*(p: VocabParams): tuple[lo, hi: int] =
  ## "Thick diagonals" — half a cover piece to a whole one.
  (p.atRef(26), p.atRef(52))

func snakeThickness*(p: VocabParams): tuple[lo, hi: int] =
  ## "Low diagonals" — deliberately thinner than a beam: a snake reads as a
  ## ridge you shoot over the top of, not a wall.
  (p.atRef(14), p.atRef(22))

func templeSize*(p: VocabParams): tuple[lo, hi: int] =
  ## "Medium rects as solid anchors" — one cover piece to two.
  (p.atRef(46), p.atRef(112))

func massifRadius*(p: VocabParams): tuple[lo, hi: int] =
  ## The disc radii walked along a massif spine. The 2.2x spread is what makes
  ## the outline lumpy instead of a constant-width sausage.
  (p.atRef(20), p.atRef(44))

func densityScaled(p: VocabParams, nominal: int): int {.inline.} =
  let d = clamp(p.density, 0.5, 1.6)
  max(1, int(round(float(nominal) * d)))

func vocabFootprint*(item: VocabItem, p: VocabParams): tuple[w, h: int] =
  ## The region size an item WANTS. A composer that hands an item a smaller
  ## region still gets valid output (everything is clamped in), but a dorito
  ## run squeezed into half a footprint degenerates into one diamond, and a
  ## massif into a pebble. The long items (`viSnake`, `viMassif`, `viCave`)
  ## are BANDS: one dimension is a run length and the other is the feature's
  ## thickness. A snake takes its axis from the region's longer side; a massif
  ## or cave takes it from `mirrorIsVertical`, NOT from the region, so the
  ## footprint returned here is already oriented the way the item will build
  ## (see `VocabParams.mirrorIsVertical` — it is a fairness constraint).
  let c = p.coverSizePx
  # A ridge runs perpendicular to the mirror line, so with the usual vertical
  # mirror its RUN is vertical and its footprint is portrait.
  template ridge(runLen, thick: int): tuple[w, h: int] =
    if p.mirrorIsVertical: (thick, runLen) else: (runLen, thick)
  case item
  of viDorito: (3 * c, 3 * c)
  of viCan: (3 * c + p.corridorPx, 3 * c + p.corridorPx)
  of viSnake: (7 * c, 2 * c)
  of viBeam: (3 * c, 3 * c)
  of viTemple: (2 * c, 3 * c)
  # A wall of three pieces at 1.2-1.9 cover diameters each, plus the doorway.
  of viBunker: (5 * c + p.corridorPx, 3 * c)
  # A massif is at most `2*radHi` (~1.57 c) thick; the corridor on top is the
  # walkable lane BETWEEN two neighbouring massifs. Tiling at the bare mass
  # width packs ridges 30-60 px apart, which is under the passability floor.
  of viMassif: ridge(8 * c, 2 * c + p.corridorPx)
  # A cave needs two walls of `2*radHi + radLo` (~1.93 c) PLUS its mouth, and
  # then a lane outside it before the next feature; squeeze it into less and
  # the walls thin out before the gap does. That makes a cave intrinsically
  # ~6.5 cover pieces THICK, so its run has to be long enough that it still
  # reads as a passage rather than a square blot — hence 10c.
  of viCave: ridge(10 * c, 4 * c + 2 * p.corridorPx)

func isLongItem*(item: VocabItem): bool {.inline.} =
  ## Items that read as a RUN along an axis and want a band, not a slot.
  item in {viSnake, viMassif, viCave}

# ---------------------------------------------------------------------------
# Small helpers (kept local; `mapgen_styles` owns its own copies and is
# contested, so nothing is shared across the two files)
# ---------------------------------------------------------------------------

proc ri(r: var Rand, lo, hi: int): int =
  ## Inclusive-lo, EXCLUSIVE-hi; `lo` when the span is empty. Same convention
  ## as `mapgen_styles.ri`, so a reader moving between the two files is not
  ## surprised.
  if hi <= lo: lo else: lo + rand(r, hi - lo - 1)

proc rr(r: var Rand, lo, hi: int): int {.inline.} =
  ## Inclusive on BOTH ends — the natural form for a size range like r22-34.
  ri(r, lo, hi + 1)

proc coin(r: var Rand, pct: int): bool {.inline.} = ri(r, 0, 100) < pct

func rectOf(x, y, w, h: int): ArenaShape {.inline.} =
  ArenaShape(kind: shapeRect, rect: MapRect(x: x, y: y, w: max(1, w), h: max(1, h)))

func discOf(cx, cy, radius: int): ArenaShape {.inline.} =
  ArenaShape(kind: shapeDisc, cx: cx, cy: cy, radius: max(1, radius))

func diamondOf(cx, cy, radius: int): ArenaShape {.inline.} =
  ArenaShape(kind: shapeDiamond, cx: cx, cy: cy, radius: max(1, radius))

func diagOf(x0, y0, x1, y1, thickness: int): ArenaShape {.inline.} =
  ArenaShape(kind: shapeDiagonal, x0: x0, y0: y0, x1: x1, y1: y1,
             thickness: max(2, thickness))

func inset(region: MapRect, m: int): MapRect =
  ## The region shrunk by `m` on every side, never smaller than 1x1.
  let
    w = region.w - 2 * m
    h = region.h - 2 * m
  if w >= 1 and h >= 1:
    MapRect(x: region.x + m, y: region.y + m, w: w, h: h)
  else:
    MapRect(x: region.x + region.w div 2, y: region.y + region.h div 2,
            w: 1, h: 1)

func clampTo(v, lo, hi: int): int {.inline.} =
  if hi <= lo: lo else: clamp(v, lo, hi)

func clampCenter(region: MapRect, cx, cy, radius: int): (int, int) =
  ## Keep a radial shape wholly inside the region.
  (clampTo(cx, region.x + radius, region.x + region.w - 1 - radius),
   clampTo(cy, region.y + radius, region.y + region.h - 1 - radius))

func fitRadius(region: MapRect, radius: int): int {.inline.} =
  ## The largest radius that can sit inside the region at all.
  max(1, min(radius, min(region.w, region.h) div 2 - 1))

func horizontal(region: MapRect): bool {.inline.} = region.w >= region.h

func wedgePolygon(x0, y0, x1, y1, wStart, wEnd: int): ArenaShape =
  ## A TAPERED QUAD about the segment (x0,y0)-(x1,y1): `wStart` wide at one
  ## end, `wEnd` at the other. Convex, four integer vertices, simple by
  ## construction.
  ##
  ## Why not `shapeDiagonal`? A diagonal is a capsule: constant width, round
  ## caps. Rendered at map scale a run of them reads as scattered LOGS, and
  ## two in one slot at free angles cross into an X. A taper reads as built
  ## masonry, and it is the difference between "wedge" and "stick".
  ##
  ## THE MIDDLE TWO VERTICES ARE SNAPPED TO A SHARED Y, and that is a
  ## FAIRNESS fix, not a cosmetic one. `arena.pointInPolygon` counts an edge
  ## only on a STRICT straddle, so a vertex whose neighbours sit on opposite
  ## sides in y contributes no crossing on its own row. Sort a convex quad's
  ## corners by y and the top and bottom are extrema (harmless) but the middle
  ## two are both pass-through, at DIFFERENT rows — so two rows each lose ONE
  ## crossing, which inverts inside/outside across the rest of that row. Under
  ## the mirror the inversion lands on the other side, and the two teams get
  ## different walls: 5,630 asymmetric wall pixels measured over four boards
  ## of beams. Snapping the two middle vertices to a common y makes that row
  ## lose TWO crossings instead of one, which is parity-neutral and therefore
  ## mirror-exact. Measured after: zero.
  let
    dx = float(x1 - x0)
    dy = float(y1 - y0)
    length = max(1.0, hypot(dx, dy))
    nx = -dy / length
    ny = dx / length
    h0 = float(max(2, wStart)) / 2.0
    h1 = float(max(2, wEnd)) / 2.0
  var pts = @[
    MapPoint(x: x0 + int(round(nx * h0)), y: y0 + int(round(ny * h0))),
    MapPoint(x: x1 + int(round(nx * h1)), y: y1 + int(round(ny * h1))),
    MapPoint(x: x1 - int(round(nx * h1)), y: y1 - int(round(ny * h1))),
    MapPoint(x: x0 - int(round(nx * h0)), y: y0 - int(round(ny * h0)))]
  var order = [0, 1, 2, 3]
  for i in 1 .. 3:
    var j = i
    while j > 0 and pts[order[j]].y < pts[order[j - 1]].y:
      swap(order[j], order[j - 1])
      dec j
  let snapped = (pts[order[1]].y + pts[order[2]].y) div 2
  pts[order[1]].y = snapped
  pts[order[2]].y = snapped
  ArenaShape(kind: shapePolygon, points: pts)

# ---------------------------------------------------------------------------
# DORITOS — the signature angled bunker
# ---------------------------------------------------------------------------

proc doritos*(r: var Rand, region: MapRect, p: VocabParams): seq[ArenaShape] =
  ## A STEPPED RUN of diamonds along a diagonal. Not a scatter of diamonds:
  ## the pieces share one axis and are spaced at ~1.5 radii, so consecutive
  ## corners nearly touch and the run reads as one angled bunker wall with
  ## shootable notches between the points. The diagonal axis is the feature —
  ## a diamond's flat faces are 45 degrees off it, which is why the bunker
  ## deflects fire along the run instead of stopping it dead.
  let
    (rLo, rHi) = p.doritoRadius
    band = region.inset(2)
  if band.w < 8 or band.h < 8: return
  let
    rad0 = fitRadius(band, rr(r, rLo, rHi))
    count = clamp(densityScaled(p, 3), 2, 5)
    stepLen = max(rad0 * 3 div 2, rad0 + 6)
    # Axis: one of the four diagonals, so the run is always ANGLED.
    sx = (if coin(r, 50): 1 else: -1)
    sy = (if coin(r, 50): 1 else: -1)
    # Start from the corner the run walks away from, so the whole run fits.
    span = (count - 1) * stepLen * 7 div 10
  var
    cx = clampTo(if sx > 0: band.x + rad0 + ri(r, 0, max(1, band.w div 6))
                 else: band.x + band.w - 1 - rad0 - ri(r, 0, max(1, band.w div 6)),
                 band.x + rad0, band.x + band.w - 1 - rad0)
    cy = clampTo(if sy > 0: band.y + rad0 + ri(r, 0, max(1, band.h div 6))
                 else: band.y + band.h - 1 - rad0 - ri(r, 0, max(1, band.h div 6)),
                 band.y + rad0, band.y + band.h - 1 - rad0)
  discard span
  for i in 0 ..< count:
    let
      rad = fitRadius(band, rr(r, rLo, rHi))
      (px, py) = clampCenter(band, cx, cy, rad)
    result.add diamondOf(px, py, rad)
    # 7/10 on each axis keeps the run diagonal but not exactly 45 degrees, so
    # two doritos on one map never step identically.
    cx += sx * (stepLen * rr(r, 6, 9) div 10)
    cy += sy * (stepLen * rr(r, 6, 9) div 10)
    if cx < band.x or cx > band.x + band.w or
       cy < band.y or cy > band.y + band.h:
      break

# ---------------------------------------------------------------------------
# CANS — free-standing pillars a fight wraps around
# ---------------------------------------------------------------------------

proc cans*(r: var Rand, region: MapRect, p: VocabParams): seq[ArenaShape] =
  ## Two to four discs, SEPARATED by at least a corridor width. The separation
  ## is the design: a can is something you strafe around while a duel rotates,
  ## which needs walkable floor all the way round. Merged discs would be a
  ## massif, and that is a different item.
  let
    (rLo, rHi) = p.canRadius
    band = region.inset(2)
  if band.w < 8 or band.h < 8: return
  let want = clamp(densityScaled(p, 3), 1, 5)
  var placed: seq[(int, int, int)]
  # Rejection sampling with a hard attempt budget keeps this O(1)-ish and,
  # more importantly, DETERMINISTIC in the number of RNG draws per attempt.
  for attempt in 0 ..< want * 12:
    if placed.len >= want: break
    let
      rad = fitRadius(band, rr(r, rLo, rHi))
      cx0 = ri(r, band.x, band.x + band.w)
      cy0 = ri(r, band.y, band.y + band.h)
      (cx, cy) = clampCenter(band, cx0, cy0, rad)
    var ok = true
    for (ox, oy, orad) in placed:
      let
        dx = cx - ox
        dy = cy - oy
        need = rad + orad + p.corridorPx
      if dx * dx + dy * dy < need * need:
        ok = false
        break
    if ok:
      placed.add (cx, cy, rad)
  for (cx, cy, rad) in placed:
    result.add discOf(cx, cy, rad)

# ---------------------------------------------------------------------------
# BEAMS / WEDGES — thick diagonals, the visual workhorse
# ---------------------------------------------------------------------------

proc beams*(r: var Rand, region: MapRect, p: VocabParams): seq[ArenaShape] =
  ## ONE thick tapered wedge at a free angle, and sometimes a second wedge
  ## PARALLEL to it with a corridor between them.
  ##
  ## The first version emitted two independent free-angle capsules per slot,
  ## which crossed near the middle about half the time: a whole map of X's and
  ## V's that read as spilled pick-up-sticks. Two rules fix it and both matter:
  ## the second wedge is parallel (never crossing), and length is capped at
  ## 4.5x thickness so a beam is a WEDGE and not a stick. `wedgePolygon`
  ## supplies the taper that makes it read as masonry.
  let
    (tLo, tHi) = p.beamThickness
    band = region.inset(2)
  if band.w < 16 or band.h < 16: return
  let
    maxThick = max(4, min(band.w, band.h) div 3)
    thick = min(rr(r, tLo, tHi), maxThick)
    # A wedge is 2.5-4.5 thicknesses long. Beyond that it stops being a wedge.
    wantLen = thick * rr(r, 25, 45) div 10
    half = thick div 2 + 2
    inner = band.inset(half)
  if inner.w < 8 or inner.h < 8: return
  let
    length = clampTo(wantLen, thick * 2, max(thick * 2, min(inner.w, inner.h)))
    # Free angle, but biased AWAY from the axes: an axis-aligned wedge is just
    # a tapered temple, and the point of this item is the raking silhouette.
    deg = rr(r, 18, 72) + 90 * ri(r, 0, 4)
    ang = float(deg) * PI / 180.0
    dx = int(round(cos(ang) * float(length) / 2.0))
    dy = int(round(sin(ang) * float(length) / 2.0))
    pad = max(abs(dx), abs(dy)) + 1
    core = inner.inset(pad)
  if core.w < 2 or core.h < 2: return
  let
    cx = ri(r, core.x, core.x + core.w)
    cy = ri(r, core.y, core.y + core.h)
    # Taper: the narrow end is 30-70% of the wide end, and which end is wide
    # is a coin flip, so a field of wedges does not all point one way.
    narrow = max(6, thick * rr(r, 30, 70) div 100)
    flip = coin(r, 50)
  result.add wedgePolygon(cx - dx, cy - dy, cx + dx, cy + dy,
                          (if flip: thick else: narrow),
                          (if flip: narrow else: thick))
  # A parallel partner, offset perpendicular by a full corridor plus both
  # half-thicknesses: two ramparts with a lane between, never an X.
  if coin(r, 40):
    let
      sep = thick + p.corridorPx
      ox = int(round(-sin(ang) * float(sep)))
      oy = int(round(cos(ang) * float(sep)))
      sx = clampTo(cx + ox, core.x, core.x + core.w - 1)
      sy = clampTo(cy + oy, core.y, core.y + core.h - 1)
      thick2 = max(6, thick * rr(r, 70, 100) div 100)
      narrow2 = max(6, thick2 * rr(r, 30, 70) div 100)
    result.add wedgePolygon(sx - dx, sy - dy, sx + dx, sy + dy,
                            (if flip: narrow2 else: thick2),
                            (if flip: thick2 else: narrow2))

# ---------------------------------------------------------------------------
# TEMPLES — medium rects as solid anchors
# ---------------------------------------------------------------------------

proc temples*(r: var Rand, region: MapRect, p: VocabParams): seq[ArenaShape] =
  ## One or two medium axis-aligned rectangles. The ONE deliberately plain
  ## item: a map needs a few unambiguous solid masses to read as architecture,
  ## and an angled shape cannot be one because its silhouette changes with
  ## your approach. Keep it a minority of the shape count (`rectShare`).
  let
    (sLo, sHi) = p.templeSize
    band = region.inset(2)
  if band.w < 12 or band.h < 12: return
  let count = clamp(densityScaled(p, 1), 1, 2)
  var placed: seq[MapRect]
  for i in 0 ..< count * 6:
    if placed.len >= count: break
    let
      w = min(rr(r, sLo, sHi), max(4, band.w * 2 div 3))
      h = min(rr(r, sLo, sHi), max(4, band.h * 2 div 3))
      x = ri(r, band.x, max(band.x + 1, band.x + band.w - w))
      y = ri(r, band.y, max(band.y + 1, band.y + band.h - h))
      cand = MapRect(x: x, y: y, w: w, h: h)
    var ok = true
    for other in placed:
      # Temples never merge: two touching rects read as one lumpy rect, which
      # is the worst-looking thing on the old maps.
      if x < other.x + other.w + p.corridorPx and
         other.x < x + w + p.corridorPx and
         y < other.y + other.h + p.corridorPx and
         other.y < y + h + p.corridorPx:
        ok = false
        break
    if ok: placed.add cand
  for rect in placed:
    result.add rectOf(rect.x, rect.y, rect.w, rect.h)

# ---------------------------------------------------------------------------
# SNAKE — a low diagonal run down one flank
# ---------------------------------------------------------------------------

proc snake*(r: var Rand, region: MapRect, p: VocabParams): seq[ArenaShape] =
  ## A run of LOW diagonals with small rects at the joints, hugging one edge
  ## of the region for most of its length. "Every good field has one": it is
  ## the feature that makes a flank legible — a continuous, followable line
  ## that tells a player where the edge route is and gives them cover the
  ## whole way down it, without ever sealing the flank off (the segments zigzag
  ## AWAY from the wall, so the run is porous by construction).
  let
    (tLo, tHi) = p.snakeThickness
    band = region.inset(2)
  if band.w < 24 or band.h < 24: return
  let
    thick = min(rr(r, tLo, tHi), max(4, min(band.w, band.h) div 4))
    half = thick div 2 + 2
    inner = band.inset(half)
  if inner.w < 8 or inner.h < 8: return
  let
    alongH = horizontal(inner)
    runLen = if alongH: inner.w else: inner.h
    crossLen = if alongH: inner.h else: inner.w
    segs = clamp(densityScaled(p, max(3, runLen div max(1, p.coverSizePx * 3 div 2))),
                 2, 9)
    stepLen = max(8, runLen div segs)
    # Which flank: the run hugs one side, wandering into at most a third of
    # the cross extent.
    nearLow = coin(r, 50)
    amp = max(4, crossLen div 3)
    baseCross = if nearLow: 0 else: crossLen - 1
    sign = if nearLow: 1 else: -1
  var
    u = 0
    v = baseCross + sign * ri(r, 0, max(1, amp div 3))
  proc toXY(uu, vv: int): (int, int) =
    if alongH: (inner.x + uu, inner.y + vv) else: (inner.x + vv, inner.y + uu)
  for i in 0 ..< segs:
    let
      u1 = min(runLen - 1, u + stepLen)
      # Alternate the cross displacement so the run zigzags: that is what
      # makes it a snake rather than a bar.
      target = baseCross + sign * clampTo(
        (if (i and 1) == 0: rr(r, amp div 2, amp) else: rr(r, 0, amp div 3)),
        0, crossLen - 1)
      v1 = clampTo(target, 0, crossLen - 1)
      (x0, y0) = toXY(u, v)
      (x1, y1) = toXY(u1, v1)
    result.add diagOf(x0, y0, x1, y1, thick)
    # A small rect at the joint: it thickens the elbow so the run does not
    # pinch to nothing where two capsules meet at an angle, and it is the
    # only rect a snake contributes.
    if i + 1 < segs and coin(r, 70):
      let
        jw = max(4, thick * 3 div 2)
        jx = clampTo(x1 - jw div 2, inner.x, inner.x + inner.w - jw)
        jy = clampTo(y1 - jw div 2, inner.y, inner.y + inner.h - jw)
      result.add rectOf(jx, jy, jw, jw)
    u = u1
    v = v1
    if u >= runLen - 1: break

# ---------------------------------------------------------------------------
# BUNKER CLUSTER — 2-3 DIFFERENT kinds around one fightable gap
# ---------------------------------------------------------------------------

proc bunkerCluster*(r: var Rand, region: MapRect, p: VocabParams): seq[ArenaShape] =
  ## Two or three pieces of DIFFERENT kinds laid along ONE short axis, all but
  ## one junction TOUCHING, and exactly one junction opened to a corridor. It
  ## reads as a stub of wall with a doorway punched through it: one feature,
  ## one gap, and the gap is the thing you fight through.
  ##
  ## THE FIRST VERSION PUT THE PIECES ON A RING around a central hole, and it
  ## looked like three loose rocks — which is exactly the defect this whole
  ## vocabulary exists to end, so it is worth saying why it was doomed. A
  ## cover-sized piece is `coverSizePx` = 56 px across and the passability
  ## floor is `corridorPx` = 68 px. Space three pieces evenly around a hole
  ## that wide and every piece is FURTHER from its neighbours than it is big:
  ## no amount of tuning makes that read as one object. Put the same pieces in
  ## contact and spend the whole gap budget in ONE place, and it does.
  let band = region.inset(2)
  if band.w < 24 or band.h < 24: return
  let
    # THREE PIECES, NOT TWO. With two, the door has a piece on each side and
    # nothing else, so it reads as two rocks with a space — there is no wall
    # for the door to be a hole in. With three, one junction fuses into a
    # visible mass and the door separates that mass from a single buttress,
    # which is legible as ONE built thing. Density may add a fourth.
    count = clamp(densityScaled(p, 3), 3, 4)
    # The door is held at the corridor floor plus a SMALL jitter. A wider door
    # does not read as a hole in a wall, it reads as two objects.
    gap = clampTo(p.corridorPx + ri(r, 0, max(1, p.corridorPx div 4)),
                  p.corridorPx, max(p.corridorPx, min(band.w, band.h) * 2 div 5))
    # THE PIECES MUST OUT-MASS THE DOORWAY. At `coverSizePx/2` they were 56 px
    # across with a 68-102 px door between them, so each piece was further
    # from its neighbour than it was big and the cluster read as loose rocks
    # even when in contact. A bunker piece is a piece of WALL, not a piece of
    # cover: 1.2-1.9 cover diameters, so the door is plainly a hole IN
    # something.
    baseR = clampTo(p.coverSizePx * rr(r, 62, 95) div 100,
                    6, max(6, min(band.w, band.h) div 3))
    doorAt = ri(r, 0, max(1, count - 1))   ## which junction is the doorway
  # Kinds without replacement: a cluster is never two of one thing.
  var kinds = @[0, 1, 2, 3]   ## 0 diamond, 1 disc, 2 rect, 3 wedge
  for i in countdown(kinds.high, 1):
    let j = ri(r, 0, i + 1)
    swap(kinds[i], kinds[j])
  # Walk the axis, accumulating each piece's radius. Every junction that is
  # NOT the door overlaps by a third of a radius, so those pieces fuse into
  # one visible mass and the door is unmistakably the one hole in it.
  var
    radii: seq[int]
    offs: seq[int]
    cursor = 0
    maxRad = 0
  for i in 0 ..< count:
    let rad = max(5, baseR * rr(r, 78, 118) div 100)
    if i > 0:
      cursor += radii[^1] + rad -
        (if i - 1 == doorAt: -gap else: max(3, rad div 2))
    radii.add rad
    offs.add cursor
    maxRad = max(maxRad, rad)
  # THE ANGLE IS FITTED TO THE SLOT, NOT DRAWN FREELY. A three-piece wall is
  # ~360 px long; tilting it 35 degrees in a 163 px tall band drove its end
  # pieces into `clampCenter`, which squashed them into edge slivers — visible
  # in the render as stray 4 px shards. The tilt is now whatever the slot can
  # actually accommodate, which is often zero.
  let
    runLen = offs[^1] - offs[0] + radii[0] + radii[^1]
    alongH = horizontal(band)
    crossRoom = float(max(0, (if alongH: band.h else: band.w) - 2 * maxRad))
    sinCap = clamp(crossRoom / max(1.0, float(runLen)), 0.0, 0.60)
    tiltMax = int(radToDeg(arcsin(sinCap)))
    axis = if alongH: 0 else: 90
    ang = float(axis + ri(r, -tiltMax, tiltMax + 1)) * PI / 180.0
    ux = cos(ang)
    uy = sin(ang)
    mid = (offs[0] + offs[^1]) div 2
    cxc = band.x + band.w div 2
    cyc = band.y + band.h div 2
  # A STAGGER WAS TRIED AND REVERTED. Pushing everything past the door
  # sideways by half a radius, to make the group read as a turned gate rather
  # than a broken line, changed the render not at all and cost 14% of the
  # item's enclosure (0.64 -> 0.55 encl/cov). The pieces stay colinear.
  for i in 0 ..< count:
    let
      t = float(offs[i] - mid)
      rad = radii[i]
      px = cxc + int(round(ux * t))
      py = cyc + int(round(uy * t))
    case kinds[i mod kinds.len]
    of 0:
      let (x, y) = clampCenter(band, px, py, rad)
      result.add diamondOf(x, y, rad)
    of 1:
      let (x, y) = clampCenter(band, px, py, rad)
      result.add discOf(x, y, rad)
    of 2:
      let
        w = max(6, rad * rr(r, 130, 185) div 100)
        h = max(6, rad * rr(r, 85, 135) div 100)
        x = clampTo(px - w div 2, band.x, max(band.x, band.x + band.w - w))
        y = clampTo(py - h div 2, band.y, max(band.y, band.y + band.h - h))
      result.add rectOf(x, y, w, h)
    else:
      # A wedge laid PERPENDICULAR to the run: it caps the end of the wall and
      # gives the doorway a jamb to shoot around. The arm is capped by what
      # the slot can hold ACROSS the run — an uncapped arm was clamped into a
      # 4 px shard, which is what the stray slivers in the render were.
      let
        wide = max(6, rad * 3 div 2)
        inner = band.inset(wide div 2 + 2)
      if inner.w < 8 or inner.h < 8: continue
      let
        arm = clampTo(rad, 4, max(4, min(inner.w, inner.h) div 2 - 1))
        tx = int(round(-uy * float(arm)))
        ty = int(round(ux * float(arm)))
      let
        ax = clampTo(px - tx, inner.x, inner.x + inner.w - 1)
        ay = clampTo(py - ty, inner.y, inner.y + inner.h - 1)
        bx = clampTo(px + tx, inner.x, inner.x + inner.w - 1)
        by = clampTo(py + ty, inner.y, inner.y + inner.h - 1)
      result.add wedgePolygon(ax, ay, bx, by, wide, max(6, wide div 2))

# ---------------------------------------------------------------------------
# MASSIF — a lumpy organic mass whose outline never repeats
# ---------------------------------------------------------------------------
#
# THE `MaxPolygonVerts` PROBLEM AND HOW IT IS SOLVED.
#
# A massif is the UNION of 6-12 overlapping discs of varying radius walked
# along a jittered spine. Traced naively (marching squares on a raster) that
# union's outline is 100-300 vertices — far past the 48 ceiling — and
# simplifying a single ring down to 48 is what turns a massif back into a
# smooth blob, i.e. destroys the whole point.
#
# Two decisions solve it:
#
#  1. PROFILE SCAN, not contour trace. The spine is generated MONOTONE along
#     one axis (forward-only steps, jitter only across), so the union is
#     y-simple: at every column `u` its extent is exactly one interval
#     [lo(u), hi(u)], the min/max over the discs covering that column. The
#     outline is therefore the upper profile left-to-right followed by the
#     lower profile right-to-left — a ring that is SIMPLE BY CONSTRUCTION
#     (strictly increasing u on the top, strictly decreasing on the bottom,
#     lo < hi everywhere between), which is what `pointInPolygon` needs. No
#     contour tracer, no hole handling, no self-intersection risk.
#
#  2. SPLIT, don't coarsen. Each profile is thinned by Douglas-Peucker to at
#     most `MaxPolygonVerts div 2` points. If the epsilon that takes costs
#     more than a fifth of the mean disc radius — i.e. if meeting the ceiling
#     would visibly straighten the lumps — the disc chain is cut into
#     OVERLAPPING sub-chains and each is emitted as its own polygon. The union
#     is identical (consecutive sub-chains share a disc, so they overlap), the
#     detail is preserved exactly, and every ring is independently under the
#     ceiling. A standard-class massif is one polygon; a colossal-class or
#     long-band one is two or three.

proc rdpKeep(pts: seq[(int, int)], eps2: int64, lo, hi: int, keep: var seq[bool]) =
  ## Douglas-Peucker over the inclusive index range [lo, hi], marking kept
  ## points. Integer throughout: the test is
  ## `cross^2 > eps^2 * segLen^2`, cross-multiplied so there is no division
  ## and no float. int64 because a map-scale cross product overflows int32.
  if hi <= lo + 1: return
  let
    (ax, ay) = pts[lo]
    (bx, by) = pts[hi]
    dx = int64(bx - ax)
    dy = int64(by - ay)
    seg2 = dx * dx + dy * dy
  var
    best = -1
    bestVal: int64 = -1
  for i in lo + 1 ..< hi:
    let
      (px, py) = pts[i]
      cross = dx * int64(py - ay) - dy * int64(px - ax)
      val = cross * cross
    if val > bestVal:
      bestVal = val
      best = i
  if best < 0: return
  # dist^2 = cross^2 / seg2; keep when dist^2 > eps^2.
  let overshoot = if seg2 == 0: bestVal else: bestVal
  if seg2 == 0:
    if overshoot <= 0: return
  elif overshoot <= eps2 * seg2:
    return
  keep[best] = true
  rdpKeep(pts, eps2, lo, best, keep)
  rdpKeep(pts, eps2, best, hi, keep)

proc keepFlags(pts: seq[(int, int)], eps: int): seq[bool] =
  ## Douglas-Peucker at a given epsilon as a keep-mask; endpoints always kept.
  result = newSeq[bool](pts.len)
  if pts.len == 0: return
  result[0] = true
  result[^1] = true
  if pts.len <= 2: return
  rdpKeep(pts, int64(eps) * int64(eps), 0, pts.high, result)

proc pairedSimplify(
    top, bot: seq[(int, int)], budget: int, epsOut: var int
): tuple[st, sb: seq[(int, int)]] =
  ## Simplify BOTH profiles against a SHARED index set: whichever sample index
  ## either profile wants to keep is kept on both.
  ##
  ## THIS IS A FAIRNESS CONSTRUCTION, and it is worth being explicit about why
  ## a cosmetic-looking coupling is load-bearing.
  ##
  ## `arena.pointInPolygon` counts an edge only on a STRICT straddle, so a
  ## vertex whose neighbours sit on opposite sides in y contributes NO crossing
  ## on its own scan row. Every interior vertex of a profile is such a vertex.
  ## If a row loses ONE crossing, inside/outside INVERTS across the rest of
  ## that row — and under the mirror the inversion lands on the other side, so
  ## the two teams get different walls. Measured on massifs simplified
  ## independently: 158,136 asymmetric wall pixels, 17.7% of the item's wall.
  ##
  ## Sharing the index set makes the two profiles' vertices come in PAIRS at
  ## the same sample index. In the barrier orientation (`alongH == false`, the
  ## one a 2-team board actually wants, where the run axis is y) that means a
  ## matched pair at the same SCAN ROW, so such a row loses TWO crossings
  ## instead of one. Two is parity-neutral: the row goes empty rather than
  ## inverted, identically on both sides of the mirror. The row is then covered
  ## by the hidden core discs, which are exactly mirror-symmetric.
  epsOut = 0
  var eps = 0
  while eps < 4096:
    let
      ka = keepFlags(top, eps)
      kb = keepFlags(bot, eps)
    var n = 0
    for i in 0 ..< ka.len:
      if ka[i] or kb[i]: inc n
    if n <= budget or eps >= 2048:
      epsOut = eps
      for i in 0 ..< ka.len:
        if ka[i] or kb[i]:
          result.st.add top[i]
          result.sb.add bot[i]
      return
    eps = if eps == 0: 1 else: eps * 2
  # Unreachable: the loop returns at eps >= 2048 at the latest.

type SpineDisc = tuple[u, v, rad: int]

proc ridgeHull(
    discs: seq[SpineDisc], alongH: bool, originX, originY: int,
    step: int, budget: int, epsOut: var int
): seq[MapPoint] =
  ## The outline of a union of discs whose centers are MONOTONE in `u`, as a
  ## simple integer ring. See the block comment above for why this is a
  ## profile scan and not a contour trace.
  if discs.len == 0: return
  var
    uLo = discs[0].u - discs[0].rad + 1
    uHi = discs[0].u + discs[0].rad - 1
  for d in discs:
    uLo = min(uLo, d.u - d.rad + 1)
    uHi = max(uHi, d.u + d.rad - 1)
  if uHi <= uLo: return
  var top, bot: seq[(int, int)]
  var u = uLo
  while true:
    var
      lo = high(int)
      hi = low(int)
    for d in discs:
      let du = u - d.u
      if du * du >= d.rad * d.rad: continue
      let half = int(sqrt(float(d.rad * d.rad - du * du)))
      lo = min(lo, d.v - half)
      hi = max(hi, d.v + half)
    if lo != high(int):
      if hi < lo + 2: hi = lo + 2
      top.add (u, lo)
      bot.add (u, hi)
    if u >= uHi: break
    u = min(uHi, u + step)
  if top.len < 2: return
  let (st, sb) = pairedSimplify(top, bot, budget, epsOut)
  if st.len < 2: return
  proc emit(uu, vv: int): MapPoint =
    if alongH: MapPoint(x: originX + uu, y: originY + vv)
    else: MapPoint(x: originX + vv, y: originY + uu)
  for (uu, vv) in st:
    result.add emit(uu, vv)
  for i in countdown(sb.high, 0):
    result.add emit(sb[i][0], sb[i][1])

const MaxSpineDiscs = 96
  ## Safety cap only. A massif is sized by the REGION it is handed, not by a
  ## disc count: an early version took a fixed 8 discs and so covered barely
  ## half of any band wider than its own footprint, which measured as a
  ## massif buying almost no cover at all (0.094 cover fraction). The length
  ## of a massif is a composition decision and belongs in `vocabFootprint`.

proc walkSpine(
    r: var Rand, runLen, crossLen: int, p: VocabParams, vStart: int
): seq[SpineDisc] =
  ## Forward-only steps along `u` with jitter only across, which is what makes
  ## the union y-simple (see `ridgeHull`). Radius varies 2.2x piece to piece:
  ## that variation, not the spine wobble, is most of what stops the outline
  ## repeating. The walk runs the FULL length of the region it is given.
  let
    (radLo, radHi) = p.massifRadius
    radCap = max(4, crossLen div 2 - 2)
    rLo = max(3, min(radLo, radCap))
    rHi = max(rLo, min(radHi, radCap))
  var
    rad0 = rr(r, rLo, rHi)
    u = rad0
    v = clampTo(vStart, rad0, max(rad0, crossLen - 1 - rad0))
  let usable = max(2 * rad0 + 2, runLen)
  for i in 0 ..< MaxSpineDiscs:
    let rad = if i == 0: rad0 else: rr(r, rLo, rHi)
    let
      uu = clampTo(u, rad, max(rad, usable - 1 - rad))
      vv = clampTo(v, rad, max(rad, crossLen - 1 - rad))
    result.add (uu, vv, rad)
    if uu >= usable - 1 - rad: break
    # Overlap hard: 0.6-0.9 radii of advance means consecutive discs share
    # most of their area, so the union is one mass and never beads.
    u = uu + max(3, rad * rr(r, 60, 90) div 100)
    v = vv + ri(r, -(rad * 2 div 3), rad * 2 div 3 + 1)

proc massifPolys(
    r: var Rand, region: MapRect, p: VocabParams, vStart: int
): seq[ArenaShape] =
  ## The shared body of `massif` and `cave`.
  ##
  ## THE RUN AXIS COMES FROM THE MIRROR, NOT FROM THE REGION. `pairedSimplify`
  ## can only make a traced ridge mirror-exact when its profile samples land
  ## on matching SCAN ROWS, which requires the run axis to be perpendicular to
  ## the mirror line. Taking the axis from the region's aspect (as every other
  ## item does) silently produced ridges that were 21% asymmetric wall
  ## whenever a composer handed over a landscape band.
  let
    alongH = not p.mirrorIsVertical
    runLen = if alongH: region.w else: region.h
    fullCross = if alongH: region.h else: region.w
  if runLen < 24 or fullCross < 10: return
  # A LANE IS RESERVED OUT OF THE BAND. `walkSpine` lets the spine wander the
  # whole cross extent it is given, so handing it the band's full width made
  # the mass fill the band edge to edge: tiled at its own footprint the
  # ridges came out 40-70 px apart, at or under the passability floor, and
  # the render showed it (313 permille cover, "too clogged"). Half a corridor
  # is held back at each edge so neighbouring ridges always leave a walkable
  # lane between them.
  let
    reserve = min(p.corridorPx, max(0, fullCross - 12))
    crossLen = fullCross - reserve
    crossOff = reserve div 2
  if crossLen < 10: return
  var discs = walkSpine(r, runLen, crossLen, p, vStart - crossOff)
  if discs.len == 0: return
  for d in discs.mitems:
    d.v += crossOff
  var radSum = 0
  for d in discs: radSum += d.rad
  let
    radMean = max(3, radSum div discs.len)
    step = max(2, radMean div 6)
    budget = MaxPolygonVerts div 2
    qualityEps = max(2, radMean div 5)
  # A CORE OF SMALL DISCS RIDES UNDER THE OUTLINE. It is not belt-and-braces
  # and its RADIUS is the whole trick.
  #
  # `arena.pointInPolygon` counts an edge only on a STRICT straddle
  # (`ylo < y < yhi`), so a vertex whose two neighbours sit on OPPOSITE sides
  # in y contributes no crossing at all on its own scan row. Measured on a
  # real massif ring: 8 of 594 rows inside the mass came back entirely EMPTY
  # — eight one-pixel horizontal slits straight through a barrier, which leak
  # line of sight and trip the generator's own "open horizontal sightline"
  # validator. That is a property of the shared primitive, not of this
  # module, and the strictness is a FAIRNESS invariant that must not be
  # loosened to fix it. A disc's membership is `dx^2 + dy^2 <= r^2`: no
  # vertices, no scan rows, so a disc cannot slit.
  #
  # Emitting the spine discs at their FULL radius fixed the slits and ruined
  # the item — the render came back as unmistakable beads on a string,
  # precisely the failure the brief names, because the circles then WERE the
  # silhouette. At `CoreDiscPct` they sit entirely inside the traced outline
  # (RDP is bounded by `qualityEps` = radMean/5, so the ring is never nearer
  # than ~0.8 r to the spine) and are invisible. The polygon supplies the
  # faceted, non-repeating silhouette; the hidden core supplies solidity.
  const CoreDiscPct = 58
  const MaxParts = 8
  var parts = 1
  var rings: seq[ArenaShape]
  while parts <= MaxParts:
    var
      worst = 0
      built: seq[ArenaShape]
      start = 0
    let per = max(2, (discs.len + parts - 1) div parts)
    while start < discs.len:
      let stop = min(discs.high, start + per)          ## inclusive, OVERLAPS
      var eps = 0
      let ring = ridgeHull(discs[start .. stop], alongH, region.x, region.y,
                           step, budget, eps)
      if ring.len >= 3:
        built.add ArenaShape(kind: shapePolygon, points: ring)
      worst = max(worst, eps)
      if stop >= discs.high: break
      start = stop
    rings = built
    if worst <= qualityEps or parts == MaxParts:
      break
    inc parts
  result = rings
  template addCore(u, v, rad: int) =
    if alongH:
      result.add discOf(region.x + (u), region.y + (v), rad)
    else:
      result.add discOf(region.x + (v), region.y + (u), rad)
  for i, d in discs:
    let core = max(3, d.rad * CoreDiscPct div 100)
    addCore(d.u, d.v, core)
    # A MIDPOINT CORE, but ONLY where the chain would otherwise break. The
    # cores are not automatically contiguous: the spine advances up to 0.9 r_i
    # while a core only reaches 0.58 r, so a big disc followed by a small one
    # leaves a few-pixel gap. Adding one unconditionally very nearly doubled
    # the shape count, and `arena.isArenaWall` is a LINEAR SCAN over every
    # obstacle on every wall query, so shape count is sim runtime.
    if i + 1 < discs.len:
      let
        n = discs[i + 1]
        nCore = max(3, n.rad * CoreDiscPct div 100)
        du = n.u - d.u
        dv = n.v - d.v
        gapSq = du * du + dv * dv
        reach = max(0, core + nCore - 2)
      # The spine jitters ACROSS as well as advancing, so the test has to be
      # the true centre distance; using the along-axis step alone let three
      # slits back in.
      if gapSq > reach * reach:
        addCore((d.u + n.u) div 2, (d.v + n.v) div 2,
                max(3, min(d.rad, n.rad) * 55 div 100))
  # The END CAPS need their own core. The chain above only reaches
  # `u_first - 0.58 r`, but the traced outline reaches `u_first - r`, so the
  # tip of the mass was polygon-only and still slit (measured: up to 4 rows).
  # A half-radius disc pushed 45% of a radius outward sits inside the cap arc
  # (whose half-width there is 0.89 r) and closes it.
  block:
    let
      a = discs[0]
      b = discs[^1]
    addCore(a.u - a.rad * 45 div 100, a.v, max(3, a.rad div 2))
    addCore(b.u + b.rad * 45 div 100, b.v, max(3, b.rad div 2))

proc massif*(r: var Rand, region: MapRect, p: VocabParams): seq[ArenaShape] =
  ## An organic lumpy mass: a chain of discs of varying radius walked along a
  ## jittered spine, emitted as the OUTLINE of their union rather than as the
  ## discs themselves. Emitting the discs is what makes a chain read as beads
  ## on a string; the unioned outline is what makes it read as rock.
  let band = region.inset(2)
  if band.w < 24 or band.h < 12: return
  let crossLen = if horizontal(band): band.h else: band.w
  massifPolys(r, band, p, ri(r, crossLen div 4, crossLen * 3 div 4 + 1))

# ---------------------------------------------------------------------------
# CAVE — two near-parallel massifs with a gap
# ---------------------------------------------------------------------------

proc cave*(r: var Rand, region: MapRect, p: VocabParams): seq[ArenaShape] =
  ## Two massif spines run near-parallel with a passable gap between them.
  ## The gap is what you are actually building: a cave is the only vocabulary
  ## item that authors a ROUTE as well as an obstacle, and it is the single
  ## biggest lever on `interiorFrac` because floor between two walls is
  ## enclosed on six of eight directions by definition.
  let band = region.inset(2)
  if band.w < 40 or band.h < 24: return
  let
    # Same fairness constraint as `massifPolys`: the two walls run
    # perpendicular to the mirror line, so the MOUTH is measured across it.
    alongH = not p.mirrorIsVertical
    crossLen = if alongH: band.h else: band.w
    (radLo, radHi) = p.massifRadius
  if crossLen < 4 * radLo + p.corridorPx: return
  # THE GAP IS SIZED, NOT LEFT OVER. The first version handed each spine half
  # the region and let the mouth be whatever fell out of that arithmetic —
  # which on a tall band was 227 px, two and a half corridors, i.e. not a cave
  # at all. Here the two walls are given their own thickness and the gap is
  # the explicit remainder between them, centered in the region.
  let
    wallThick = min(2 * radHi + radLo, max(2 * radLo, (crossLen - p.corridorPx) div 2))
    gapWant = p.corridorPx + ri(r, 0, max(1, p.corridorPx div 2))
    gap = clampTo(gapWant, p.corridorPx, max(p.corridorPx, crossLen - 2 * wallThick))
    total = 2 * wallThick + gap
    offset = max(0, (crossLen - total) div 2)
  # Two independent spines, each confined to its OWN side band. A spine can
  # wander to the inner edge of its band and no further, so the mouth pinches
  # and widens along the run but can never close below `gap`.
  var lowBand, highBand: MapRect
  if alongH:
    lowBand = MapRect(x: band.x, y: band.y + offset, w: band.w, h: wallThick)
    highBand = MapRect(x: band.x, y: band.y + offset + wallThick + gap,
                       w: band.w, h: wallThick)
  else:
    lowBand = MapRect(x: band.x + offset, y: band.y, w: wallThick, h: band.h)
    highBand = MapRect(x: band.x + offset + wallThick + gap, y: band.y,
                       w: wallThick, h: band.h)
  result.add massifPolys(r, lowBand, p, wallThick div 2)
  result.add massifPolys(r, highBand, p, wallThick div 2)

# ---------------------------------------------------------------------------
# Dispatch + composition helpers
# ---------------------------------------------------------------------------

proc emitVocab*(
    item: VocabItem, r: var Rand, region: MapRect, p: VocabParams
): seq[ArenaShape] =
  ## THE call a scene graph makes. Everything above is reachable directly too;
  ## this exists so a composer can hold a `seq[VocabItem]` plan and walk it.
  case item
  of viDorito: doritos(r, region, p)
  of viCan: cans(r, region, p)
  of viSnake: snake(r, region, p)
  of viBeam: beams(r, region, p)
  of viTemple: temples(r, region, p)
  of viBunker: bunkerCluster(r, region, p)
  of viMassif: massif(r, region, p)
  of viCave: cave(r, region, p)

func parseVocabItem*(text: string): VocabItem =
  case text
  of "dorito", "doritos": viDorito
  of "can", "cans": viCan
  of "snake": viSnake
  of "beam", "beams", "wedge", "wedges": viBeam
  of "temple", "temples": viTemple
  of "bunker", "cluster", "bunkercluster": viBunker
  of "massif": viMassif
  of "cave": viCave
  else: raise newException(ValueError, "unknown vocabulary item: " & text)

func vocabName*(item: VocabItem): string =
  case item
  of viDorito: "dorito"
  of viCan: "can"
  of viSnake: "snake"
  of viBeam: "beam"
  of viTemple: "temple"
  of viBunker: "bunker"
  of viMassif: "massif"
  of viCave: "cave"

func rectShare*(shapes: seq[ArenaShape]): float =
  ## The share of a finished shape list that is a PLAIN RECT. The brief's
  ## budget is 0.5; a composer checks itself against this before shipping a
  ## map, because "half the map is bars" is the exact failure the vocabulary
  ## exists to end.
  if shapes.len == 0: return 0.0
  var n = 0
  for s in shapes:
    if s.kind == shapeRect: inc n
  float(n) / float(shapes.len)

func polygonWellFormed*(s: ArenaShape): bool =
  ## What `arena.pointInPolygon` needs from a ring: at least three vertices,
  ## at most `MaxPolygonVerts`, and a non-degenerate bounding box. It does NOT
  ## require convexity or a winding direction (even-odd), and this module
  ## never asks for the strict-straddle rule to be relaxed.
  if s.kind != shapePolygon: return true
  if s.points.len < 3 or s.points.len > MaxPolygonVerts: return false
  var
    minx = s.points[0].x
    maxx = s.points[0].x
    miny = s.points[0].y
    maxy = s.points[0].y
  for pt in s.points:
    minx = min(minx, pt.x); maxx = max(maxx, pt.x)
    miny = min(miny, pt.y); maxy = max(maxy, pt.y)
  maxx > minx and maxy > miny
