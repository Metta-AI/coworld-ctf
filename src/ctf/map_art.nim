## The map ART bake: trench-edge noise art, rooftop/glass materials, the
## supersampled arena RGBA pair (renderArenaRgbaPair), layer loading
## (loadMapLayers) and the dark background. Consumed by global.nim and the
## endzone bake tool; nothing here is in gameHash. Stage 3 of
## docs/plans/2026-08-01-sim-split.md.

import
  std/[math, os],
  bitworld/aseprite, bitworld/server, bitworld/spriteprotocol, pixie,
  sim_types, rig_art, arena

const
  TrenchBevelPx = 8                          ## width of the pit's inner
                                             ## shadow bevel, px.
  TrenchLipColor = rgba(30, 22, 12, 255)     ## crisp dark cut line around
                                             ## the pit lip.
  TrenchLipAlpha = 185                       ## shadow strength at the lip...
  TrenchFloorAlpha = 95                      ## ...easing to this over the
                                             ## bevel and holding on the pit
                                             ## floor.
  TrenchEdgeWavePeriod = 9                   ## px between wander knots along
                                             ## a side of the cut line.
  TrenchEdgeWaveAmp = 3.5                    ## smooth in/out wander of the
                                             ## cut line, px.
  TrenchEdgeChipAmp = 1.0                    ## per-pixel nick on top of the
                                             ## wander, so the lip reads
                                             ## chipped, not machined.
  TrenchArtPadPx* = 5                        ## how far outside the exact
                                             ## gameplay square the dug art
                                             ## may reach; must stay >=
                                             ## WaveAmp + ChipAmp.

const
  VoidClear* = rgba(0, 0, 0, 0)
    ## Outside the hexagon: nothing at all.
    ##
    ## ArenaVoidNote — WHY TRANSPARENT AND NOT A MATERIAL.
    ##
    ## The six corners of the bounding box are not playfield, not wall, and not
    ## a rendering hole. Painting them with the WALL material fails outright:
    ## `rooftopColorAt` shades from the distance to the nearest floor, which
    ## saturates a hundred pixels into a slab, so a hexagonal board painted as
    ## wall bakes into a vast flat roof, reads as a plain grey rectangle, and
    ## makes the whole shape change invisible. That is the failure Stage 2 hit,
    ## and it answered it with a dedicated dark "void material" plus a lit rim.
    ##
    ## The material worked but it was a FAKE BACKDROP: it drew a lit stage the
    ## hexagon sat on, and the board then needed a dark panel behind it for the
    ## stage to look intentional. The answer is neither material nor wall — it
    ## is ALPHA 0. The corners emit nothing, the hexagon's silhouette reads
    ## directly against whatever is behind the board, and the six edges are
    ## defined by the hexagon's OWN border ring (`ArenaBorderColor`, thickness
    ## `ArenaBorder`) which is inside the hull and already exists. No rim, no
    ## grain, no panel.
    ##
    ## GAMEPLAY IS UNAFFECTED. This is the art bake only (`map_art.nim` is not
    ## in `gameHash`). The void is still WALL and still opaque to vision in both
    ## collision layers — `walkImage` stays `clear` and `wallImage` stays
    ## `opaque` out there, exactly as the four wall predicates say.
    ##
    ## The consumer contract: whatever composites this image must NOT fill a
    ## solid colour behind it first, or that colour is what silhouettes the
    ## hexagon. `client/broadcast_core.js` used to fill `#000` every frame and
    ## now clears instead.

proc overTint(base, tint: ColorRGBA): ColorRGBA =
  ## Alpha-composites a translucent tint over an opaque base color.
  ## (Moved from arena.nim in the round-2 audit: pure color math, art-only.)
  let a = tint.a.int
  rgba(
    uint8((base.r.int * (255 - a) + tint.r.int * a) div 255),
    uint8((base.g.int * (255 - a) + tint.g.int * a) div 255),
    uint8((base.b.int * (255 - a) + tint.b.int * a) div 255),
    255
  )

proc trenchEdgeNoise(seed, knot, salt: int): float =
  ## Deterministic hash noise in [-1, 1]: a pure function of its inputs (no
  ## RNG state), so the same trench bakes the same rough edge every run and
  ## replays match the live render.
  ## The prime mix MUST run in uint64: seed reaches tens of millions, so
  ## seed * 73856093 overflows the 32-bit `int` of the wasm32 replay viewer
  ## and the overflow check kills the whole viewer ("stuck warming up" —
  ## every map bakes trench art). uint64 wrap reproduces the exact bit
  ## pattern the original 64-bit signed math produced, keeping the baked
  ## edges byte-identical to already-recorded replays.
  let mixed = cast[uint64](seed) * 73856093'u64 xor
    cast[uint64](knot) * 19349663'u64 xor
    cast[uint64](salt) * 83492791'u64
  var h = uint32(mixed and 0x7FFFFFFF'u64)
  h = h xor (h shr 13)
  h = h * 0x85EBCA6B'u32
  h = h xor (h shr 16)
  float(h and 0xFFFF) / 32767.5 - 1.0

proc trenchEdgeWave(trench: MapRect, side, t: int): float =
  ## How far one side of the pit's cut line is displaced (px, + = outward)
  ## at along-coordinate t: cosine-interpolated value noise with knots every
  ## TrenchEdgeWavePeriod px, plus a per-pixel chip. Seeded off the trench's
  ## position, so each dig gets its own stable edge.
  let
    seed = (trench.x * 8191 + trench.y) * 4 + side
    k0 = floorDiv(t, TrenchEdgeWavePeriod)
    u = float(t - k0 * TrenchEdgeWavePeriod) / TrenchEdgeWavePeriod
    s = (1 - cos(u * PI)) / 2
    n0 = trenchEdgeNoise(seed, k0, 0)
    n1 = trenchEdgeNoise(seed, k0 + 1, 0)
  (n0 + (n1 - n0) * s) * TrenchEdgeWaveAmp +
    trenchEdgeNoise(seed, t, 1) * TrenchEdgeChipAmp



proc trenchRoughEdge*(trench: MapRect, x, y: int): float =
  ## Signed distance (px) from map pixel (x, y) to the trench's ROUGH edge:
  ## the gameplay square with each side's cut line displaced by
  ## trenchEdgeWave, corners rounding and chipping naturally via the min.
  ## Negative = undug ground, ~0 = the lip, growing toward the pit floor.
  ## The displacement never exceeds WaveAmp + ChipAmp, so the art stays
  ## within TrenchArtPadPx of the exact square.
  let
    dl = float(x - trench.x) + trenchEdgeWave(trench, 0, y)
    dr = float(trench.x + trench.w - 1 - x) + trenchEdgeWave(trench, 1, y)
    dt = float(y - trench.y) + trenchEdgeWave(trench, 2, x)
    db = float(trench.y + trench.h - 1 - y) + trenchEdgeWave(trench, 3, x)
  min(min(dl, dr), min(dt, db))

proc trenchArtColorAt(base: ColorRGBA, x, y: int): ColorRGBA =
  ## Returns the floor color with the trench art applied at logical (x, y):
  ## a dug pit — a crisp dark lip line tracing a rough, shovel-dug edge
  ## (trenchRoughEdge), an inner shadow bevel easing down from the lip, and
  ## a uniformly darkened sunken floor, so the recess reads at a glance.
  ## Cosmetic only — the collision masks and gameplay (trenchIndexAt) keep
  ## the exact square; the art wanders at most TrenchArtPadPx around it.
  for trench in ArenaTrenches:
    let tr = shapeAsRect(trench)
    if x < tr.x - TrenchArtPadPx or
        x >= tr.x + tr.w + TrenchArtPadPx or
        y < tr.y - TrenchArtPadPx or
        y >= tr.y + tr.h + TrenchArtPadPx:
      continue
    # Axis-aligned rectangular pits get the rough dug edge; other kinds fill
    # flat (inside only). `shapeAsRect` is EXACT for an axis-aligned bar, so
    # the generator's square pits still take the rough path they always did.
    let edge =
      if trench.kind == shapeBar and trench.axisY == 0:
        trenchRoughEdge(tr, x, y)
      elif inShape(x, y, trench): float(TrenchBevelPx) + 1.0
      else: -1.0
    if edge < 0:
      continue                # undug ground inside the pad ring
    if edge < 1:
      return TrenchLipColor
    let
      depth = min(edge - 1, float(TrenchBevelPx))
      alpha = float(TrenchLipAlpha) -
        float(TrenchLipAlpha - TrenchFloorAlpha) * depth / float(TrenchBevelPx)
    return overTint(base, rgba(12, 9, 5, uint8(alpha)))
  base

proc tileSample(tex: Image, x, y: int): ColorRGBA =
  ## Samples a seamless texture tiled across the arena (opaque source).
  tex.unsafe[x mod tex.width, y mod tex.height].rgba

proc tileSampleF(tex: Image, fx, fy: float): ColorRGBA =
  ## Bilinear tile sample at a fractional map-pixel coordinate (wrapping).
  ## The texture still tiles 1:1 with LOGICAL map pixels — a scale× renderer
  ## passes fractional coords, so the floor texture keeps its 1× world size but
  ## resolves smoothly between texels. At integer-center coords this returns
  ## exactly tileSample's nearest texel.
  let
    sx = fx - 0.5
    sy = fy - 0.5
    fx0 = floor(sx)
    fy0 = floor(sy)
    tx = sx - fx0
    ty = sy - fy0
    xa = ((int(fx0) mod tex.width) + tex.width) mod tex.width
    xb = (xa + 1) mod tex.width
    ya = ((int(fy0) mod tex.height) + tex.height) mod tex.height
    yb = (ya + 1) mod tex.height
    c00 = tex.unsafe[xa, ya].rgba
    c10 = tex.unsafe[xb, ya].rgba
    c01 = tex.unsafe[xa, yb].rgba
    c11 = tex.unsafe[xb, yb].rgba
  template lerp(a, b: uint8, t: float): float =
    a.float + (b.float - a.float) * t
  rgba(
    uint8(lerp(c00.r, c10.r, tx) + (lerp(c01.r, c11.r, tx) - lerp(c00.r, c10.r, tx)) * ty),
    uint8(lerp(c00.g, c10.g, tx) + (lerp(c01.g, c11.g, tx) - lerp(c00.g, c10.g, tx)) * ty),
    uint8(lerp(c00.b, c10.b, tx) + (lerp(c01.b, c11.b, tx) - lerp(c00.b, c10.b, tx)) * ty),
    255
  )

const PedestalDimFactor = 0.34
  ## How dark the powered-down (cold) pedestal disc goes: each lit pixel's RGB is
  ## scaled to this fraction so the disc reads as an unlit socket, not a bright
  ## team light, when the heart has been carried away. Alpha is untouched so the
  ## textured floor still shows through the same silhouette.

proc pedestalDimmed(spr: Image): Image =
  ## Returns a copy of a pedestal sprite with its RGB scaled down (alpha kept), so
  ## the "cold" map shows the pedestal powered down. The broadcast glow-fade
  ## crossfades the lit pedestal toward this, so the disc dims when the heart is
  ## taken and re-lights when it comes home. Pixie stores premultiplied alpha;
  ## scaling RGB uniformly keeps the premultiplication valid.
  result = newImage(spr.width, spr.height)
  for y in 0 ..< spr.height:
    for x in 0 ..< spr.width:
      let p = spr[x, y]
      result[x, y] = rgbx(
        uint8(p.r.float * PedestalDimFactor),
        uint8(p.g.float * PedestalDimFactor),
        uint8(p.b.float * PedestalDimFactor),
        p.a)

proc blitCover(dst, spr: Image, cx, cy, size: int) =
  ## Alpha-composites a cover-object sprite onto the board, centered on its
  ## collision shape and scaled to the shape's footprint (plus a little for the
  ## baked contact shadow). The sprite's transparency lets the textured floor
  ## show through; the board stays fully opaque (opaque dst + src-over).
  if size <= 0 or spr.width == 0:
    return
  let scaled = spr.resize(size, size)
  dst.draw(scaled, translate(vec2((cx - size div 2).float32,
                                  (cy - size div 2).float32)))

## --- Rooftop wall material (top-down building look from the collision mask) ---
## Every wall pixel — border frame, rect stub, diamond, disc, or chevron — is
## rendered as one coherent LOW-DETAIL BUILDING seen from above: a light
## parapet rim around the perimeter, a shadow line where the parapet drops to
## the roof, and a dark flat roof membrane crossed by subtle diagonal seams.
## The shading comes from each pixel's distance to the nearest floor pixel and
## from the direction that distance grows, so — like the carved-stone material
## it replaces — the art matches every collider EXACTLY and is identical on
## both halves by construction (the mask is mirror-symmetric; the world-space
## roof seams are the one deliberate exception, same as the glass sheen).
## Light comes from the up-left, so a face turned up-left catches a highlight
## and one turned down-right falls into shadow — the Gungeon/Nuclear-Throne
## top-down convention (L98). The buildings keep the cover's warm-tan family
## (REPLAY_DESIGN §3 warm-stone cover) so they pop off the neutral-grey
## concrete floor, and the team colors stay the only saturated channels.
const
  WallBevel = 3                          ## px width of the parapet rim band.
  RoofFace = rgba(110, 92, 72, 255)      ## flat warm roof (the old cover tan,
                                         ## a step darker so the rim pops).
  RoofSeam = rgba(97, 80, 62, 255)       ## diagonal membrane seam lines.
  RoofLip = rgba(56, 45, 35, 255)        ## shadow line where parapet meets roof.
  ParapetFace = rgba(152, 130, 104, 255) ## flat parapet top.
  ParapetHi = rgba(192, 169, 139, 255)   ## up-left lit parapet (catches light).
  ParapetLo = rgba(88, 72, 56, 255)      ## down-right shaded parapet.
  StoneInk = rgba(32, 27, 22, 255)       ## warm near-black ground line (never #000).
  RoofSeamPeriod = 16                    ## px between diagonal roof seams.

## --- The wall distance field: the ONE metric behind both wall materials ---
## Rooftop and glass both shade from a single quantity per pixel: how far it is
## from the nearest FLOOR pixel, and which way that distance grows. Both come
## out of one Euclidean distance transform of the art mask, so the materials
## stay DERIVED from the collision mask (they cannot disagree with it) and are
## orientation-independent: a 45° chevron face gets the same parapet width as
## an axis-aligned rect face.
##
## This replaces a 4-axis RAY metric (step up/left/down/right until floor, take
## the min). That metric had three separate couplings to a square lattice:
##   * it is not a distance. A ray to an edge tilted θ off an axis OVERSHOOTS
##     the true distance by 1/cos θ, so a 45° face hit every band's threshold
##     at 1/√2 of the perpendicular distance an axis-aligned face did. Measured
##     across the arena's chevrons at scale 2: ink + parapet + lip came to 6 px
##     where the rect beside them got 8 — a quarter narrower, on the same
##     material;
##   * lit-vs-shaded was the binary predicate min(up,left) <= min(down,right):
##     a 2-bucket quantization of the surface normal into {up ∪ left} and
##     {down ∪ right}. With every normal one of 4 axis directions and the light
##     at 135° that IS the exact half-plane split — and it generalizes to
##     nothing. It painted BOTH long faces of a chevron, and three of a
##     diamond's four faces, at full highlight;
##   * it cost up to 4·cap steps per wall pixel.
## The transform is O(w·h) once per bake and every pixel then reads O(1).

const
  DistFrac = 64.0
    ## Fixed-point denominator of WallDistField: distances are stored in
    ## 1/64 px. Two bytes per pixel instead of four (a giant board at scale 2
    ## is 22M pixels, and this bake is already the memory peak of container
    ## boot), and 1/64 px leaves the gradient's central difference two orders
    ## of magnitude finer than one shading step.

type WallDistField* = object
  ## Euclidean distance from every pixel of a wall mask to the nearest FLOOR
  ## pixel: 0 on floor, SATURATING at `sat` px. Off-mask counts as wall (the
  ## arena border frame is solid), matching the ray metric this replaces, so
  ## no phantom edge leaks in from outside the board.
  ##
  ## Saturation is what keeps this cheap and overflow-proof. Every band the
  ## wall materials draw lives a handful of pixels from the floor, so nothing
  ## reads a distance past `sat`; capping there bounds the squared distances
  ## to 16 bits and the field to 2 bytes per pixel.
  w, h: int
  sat: float                 ## saturation distance, px.
  d: seq[uint16]             ## distance in 1/DistFrac px.

proc wallDistSat(scale: int): int =
  ## The saturation distance (px) that still serves every band the wall
  ## materials draw at this render scale: the outermost threshold is the
  ## parapet's inner lip at (WallBevel + 1)·scale, plus 2 px so the gradient's
  ## central difference at the last shaded pixel is still taken between two
  ## TRUE distances rather than against the cap.
  (WallBevel + 1) * scale + 2

proc wallDistField*(wall: seq[bool], w, h, scale: int): WallDistField =
  ## The exact saturated Euclidean distance transform of a wall mask.
  ##
  ## Two separable passes (Felzenszwalb & Huttenlocher, "Distance Transforms
  ## of Sampled Functions"), O(w·h) total:
  ##   1. per COLUMN, the exact 1-D distance to the nearest floor pixel in
  ##      that column, by two linear sweeps — written as whole-ROW sweeps of
  ##      row y against row y∓1, which is the same transform with sequential
  ##      memory access instead of a cache-hostile column walk. Capped, then
  ##      squared, IN PLACE in the result buffer that pass 2 then overwrites
  ##      row by row (no second full-board allocation: at scale 2 a giant
  ##      board is 22M pixels and this bake is already boot's memory peak).
  ##   2. per ROW, the lower envelope of the parabolas f(q) + (x − q)², whose
  ##      minimum is the exact squared 2-D Euclidean distance.
  ##
  ## Capping pass 1 before pass 2 cannot corrupt the band we care about:
  ## capping only LOWERS values, so a result can only fall below the true
  ## distance by way of a capped column, and every such result is itself ≥ the
  ## cap — i.e. already outside every band. Below the cap the transform is
  ## exact.
  ##
  ## wasm32 note (same hazard as trenchEdgeNoise above): `int` is 32 bits
  ## under emscripten and overflow TRAPS, which kills the replay viewer
  ## outright. Pass 1 caps distances BEFORE squaring so its arithmetic never
  ## leaves 16 bits, and pass 2's parabola math is written in int64 because
  ## q² alone reaches 4.1e7 on a giant board at scale 2 — comfortable in 32
  ## bits today and one board-size bump from not being.
  let
    n = w * h
    capPx = wallDistSat(scale)
  doAssert capPx <= 255,
    "wall distance field saturates past 16-bit squares at scale " & $scale
  result = WallDistField(w: w, h: h, sat: capPx.float, d: newSeq[uint16](n))
  if n == 0:
    return
  # Pass 1: exact 1-D column distance, capped, then squared. The backward
  # sweep squares the row it has just finished reading, so the whole pass is
  # two touches of the buffer instead of four.
  let capU = uint16(capPx)
  for x in 0 ..< w:
    result.d[x] = if wall[x]: capU else: 0'u16
  for y in 1 ..< h:
    let row = y * w
    for x in 0 ..< w:
      result.d[row + x] =
        if wall[row + x]: min(result.d[row - w + x] + 1, capU) else: 0'u16
  for y in countdown(h - 2, 0):
    let row = y * w
    for x in 0 ..< w:
      let below = result.d[row + w + x]
      if below + 1 < result.d[row + x]:
        result.d[row + x] = below + 1
      result.d[row + w + x] = below * below
  for x in 0 ..< w:
    result.d[x] = result.d[x] * result.d[x]
  # Pass 2: the parabola lower envelope along each row — but only over the
  # RUNS of nonzero column distance. A zero means "floor in this column at
  # this row", which pins the answer to 0, and it also DOMINATES every
  # parabola behind it: for a run bracketed by zeros at lo and hi, any q past
  # them contributes (x − q)² > (x − lo)², so the envelope never needs them.
  # Boards are mostly floor, so this is where the transform's cost actually
  # goes: it turns a whole-board envelope into a wall-only one.
  var
    vertex = newSeq[int](w)      ## parabolas still on the envelope
    cross = newSeq[float](w + 1) ## x where consecutive parabolas cross
    f = newSeq[int64](w)         ## this row's squared column distances
  for y in 0 ..< h:
    let row = y * w
    for x in 0 ..< w:
      f[x] = int64(result.d[row + x])
    template intersect(a, b: int): float =
      ## Where parabolas rooted at a and b cross (a > b, so never /0).
      float((f[a] + a.int64 * a.int64) - (f[b] + b.int64 * b.int64)) /
        float(2 * (a - b))
    var runStart = 0
    while runStart < w:
      if f[runStart] == 0:
        result.d[row + runStart] = 0
        inc runStart
        continue
      var runEnd = runStart
      while runEnd < w and f[runEnd] != 0:
        inc runEnd
      let
        lo = max(0, runStart - 1)
        hi = min(w - 1, runEnd)
      var k = 0
      vertex[0] = lo
      cross[0] = NegInf
      cross[1] = Inf
      for q in lo + 1 .. hi:
        var s = intersect(q, vertex[k])
        while k > 0 and s <= cross[k]:
          dec k
          s = intersect(q, vertex[k])
        inc k
        vertex[k] = q
        cross[k] = s
        cross[k + 1] = Inf
      k = 0
      for x in runStart ..< runEnd:
        while cross[k + 1] < x.float:
          inc k
        let
          dx = int64(x - vertex[k])
          sq = f[vertex[k]] + dx * dx
          dist = min(sqrt(sq.float), result.sat)
        result.d[row + x] = uint16(dist * DistFrac + 0.5)
      runStart = runEnd

proc distSat*(field: WallDistField): float =
  ## The distance past which this field stops being a distance. Exported with
  ## distAt so a test can state the saturation contract.
  field.sat

proc distAt*(field: WallDistField, x, y: int): float =
  ## The field sampled with EDGE REPLICATION, so the gradient stencil at a
  ## board-border pixel takes a one-sided difference instead of reading a
  ## phantom floor from outside the board.
  let
    cx = clamp(x, 0, field.w - 1)
    cy = clamp(y, 0, field.h - 1)
  field.d[cy * field.w + cx].float / DistFrac

proc surfaceLit*(field: WallDistField, x, y: int): float =
  ## How lit the surface is at (x, y), 0 = full shadow … 1 = full highlight.
  ##
  ## The distance grows INTO the wall, so −∇d is the OUTWARD face normal — the
  ## true angle of the edge, not the nearest of four axes. The lit fraction is
  ## the cosine against a light from the up-left, (−1, −1)/√2 (screen y points
  ## DOWN), remapped to [0, 1].
  ##
  ## The cosine is scaled by √2 before the remap so an AXIS-ALIGNED face still
  ## lands exactly on full highlight or full shadow. That is deliberate: the
  ## arena is ~90% axis-aligned rects and they must keep the tone they have
  ## today, with the off-axis faces (chevrons, discs, diamonds) filling in the
  ## in-between tones the old 2-bucket test could not express. It also makes
  ## the ramp linear in the cosine, which is the flat-shaded look this
  ## material wants — not a soft Lambert falloff.
  ##
  ## A pixel with no gradient at all has no orientation and reads as the
  ## neutral mid-tone. That is the ridge down the middle of a wall thinner
  ## than two parapets, where the two faces meet and the answer genuinely is
  ## "neither".
  let
    gx = field.distAt(x + 1, y) - field.distAt(x - 1, y)
    gy = field.distAt(x, y + 1) - field.distAt(x, y - 1)
    m = sqrt(gx * gx + gy * gy)
  if m < 1e-6:
    return 0.5
  ## −(gx, gy)/m · (−1, −1)/√2, times √2 = (gx + gy)/m.
  clamp(((gx + gy) / m + 1.0) * 0.5, 0.0, 1.0)

type SeamAxis = object
  ## A stripe family: the stripes are the level sets of nx·x + ny·y, so
  ## (nx, ny) is the pattern's NORMAL and the stripes run across it.
  ##
  ## Parameterized rather than baked into an (x + y) expression because a
  ## 45° family is a property of a SQUARE lattice. A hex build moves the two
  ## materials onto two hex axes without touching the shading code.
  nx, ny: float

const
  Sqrt2 = 1.4142135623730951
  Sqrt6Half = 1.224744871391589       ## sqrt(2) * sqrt(3) / 2

  RoofSeamAxis = SeamAxis(nx: 0.0, ny: Sqrt2)
    ## Roof membrane seams: level sets of y, running EAST-WEST — parallel to
    ## the hull's flat top and bottom edges (normal at 90 degrees).
  GlassSheenAxis = SeamAxis(nx: Sqrt6Half, ny: Sqrt2 * 0.5)
    ## Glass sheen streaks: normal at 30 degrees, so the streaks run parallel
    ## to the hull's upper-right edge. 60 degrees off the roof seams.
    ##
    ## BOTH WERE 45-DEGREE FAMILIES (x + y and x − y) until the hull became a
    ## hexagon. That pairing is perpendicular, which is the right answer for a
    ## SQUARE lattice and belongs to no hex axis at all: on this hull a 45
    ## degree seam meets four of the six edges at 15 or 75 degrees and reads as
    ## a pattern laid over the shape rather than with it. These two are hull
    ## axes — the family of the flat edges, and the family of the upper-right
    ## edge.
    ##
    ## Both vectors keep LENGTH sqrt(2), which the old pair also had, because
    ## `seamPhase` mods nx·x + ny·y by the period: the stripe SPACING is
    ## period / |n|. Normalising to unit length here would have silently
    ## widened every roof seam by a factor of sqrt(2). Only the angle moves.

## DESIGN INTENT, kept as a contract: the two stripe families must stay well
## APART in angle, or a window and the roof it is set into read as one
## continuous pattern instead of two materials. Perpendicular is the
## square-lattice answer; what actually matters is the ANGLE, so this admits a
## hex build putting them on two hex axes (0° and 120°, |cos| = 1/2) without
## weakening the guarantee. Written without sqrt so it holds at compile time.
static:
  const
    dot = RoofSeamAxis.nx * GlassSheenAxis.nx +
      RoofSeamAxis.ny * GlassSheenAxis.ny
    lenSq = (RoofSeamAxis.nx * RoofSeamAxis.nx +
        RoofSeamAxis.ny * RoofSeamAxis.ny) *
      (GlassSheenAxis.nx * GlassSheenAxis.nx +
        GlassSheenAxis.ny * GlassSheenAxis.ny)
  doAssert dot * dot * 4.0 <= lenSq + 1e-9,
    "roof seams and glass sheen must stay at least 60 degrees apart"

proc seamPhase(axis: SeamAxis, x, y: int, period: int): float =
  ## Where (x, y) sits within one stripe period, in [0, period). floorMod, so
  ## it stays continuous across the origin and across negative coordinates.
  let
    t = axis.nx * x.float + axis.ny * y.float
    p = period.float
  t - floor(t / p) * p

proc rooftopColorAt(
  field: WallDistField, x, y, scale: int
): ColorRGBA =
  ## Shades one wall pixel as a low-detail rooftop: an ink ground line where
  ## the building meets the floor, a parapet rim graded from the face's own
  ## angle to the up-left light, a shadow line where the parapet drops inside,
  ## and a dark seamed roof membrane deep in the interior. The field may be a
  ## `scale`× render of the arena; every band (ink line, parapet, lip) widens
  ## by `scale` so the material keeps its 1× proportions.
  let
    s = scale.float
    bevel = (WallBevel * scale).float
    edge = field.distAt(x, y)
  if edge <= s:
    return StoneInk                      ## touches the floor → ground outline.
  if edge <= bevel:
    ## Graded parapet rim: brightest at the outer edge (just inside the ink
    ## line), easing toward the flat parapet top by the rim width so the
    ## building edge reads raised, not painted.
    let
      rim = mix(ParapetLo, ParapetHi, field.surfaceLit(x, y))
      t = (edge - 2 * s) / max(1.0, bevel - 2 * s)
    return mix(rim, ParapetFace, clamp(t, 0.0, 1.0))
  if edge <= bevel + s:
    return RoofLip                       ## parapet drops to the roof.
  ## Roof membrane: flat dark field with subtle diagonal seams (perpendicular
  ## to the glass sheen streaks, so the two materials never read as one
  ## pattern).
  if seamPhase(RoofSeamAxis, x, y, RoofSeamPeriod * scale) < s:
    RoofSeam
  else:
    RoofFace

proc rooftopColor(field: WallDistField, x, y: int): ColorRGBA =
  ## 1× rooftop material (the baked collision-resolution map and spun diamonds).
  rooftopColorAt(field, x, y, 1)

const
  ## Glass window material: a pale pane set in the same parapet frame language
  ## as the rooftop walls — a skylight in the building's face. The face targets
  ## palette index 1 (light gray) and the
  ## sheen streaks index 2 (near-white), so windows stay legible after the
  ## player-view palette quantization — glass must READ as see-through cover.
  GlassFace = rgba(198, 198, 196, 255)   ## flat pane; quantizes to palette 1.
  GlassSheen = rgba(240, 236, 226, 255)  ## diagonal streaks; quantizes to 2.

proc windowGlassColorAt(
  field: WallDistField, x, y, scale: int
): ColorRGBA =
  ## Shades one glass window pixel: the same ink ground line and a thin
  ## parapet frame where the pane meets the floor (so windows sit in the
  ## rooftop wall language), then a pale pane crossed by sheen streaks on the
  ## GlassSheenAxis, held well off the roof seams' axis so glass and roof
  ## never read as one material.
  ## Like rooftopColorAt, every band widens by `scale` so the material keeps
  ## its 1× screen proportions on the render-scale board, and reads the same
  ## Euclidean distance field — so the frame is the same width on a diagonal
  ## pane as on an axis-aligned one.
  let
    s = scale.float
    frameCap = (2 * scale).float
    edge = field.distAt(x, y)
  if edge <= s:
    return StoneInk                      ## touches the floor → carve outline.
  if edge <= frameCap:
    return ParapetFace                   ## thin parapet frame around the pane.
  let phase = seamPhase(GlassSheenAxis, x, y, 24 * scale)
  if phase < 3 * s or (phase >= 7 * s and phase < 9 * s):
    GlassSheen
  else:
    GlassFace

proc windowGlassColor(field: WallDistField, x, y: int): ColorRGBA =
  ## 1× glass (the baked collision-resolution map the players observe).
  windowGlassColorAt(field, x, y, 1)

var diamondFrameCache: array[DiamondSpinFrames, seq[tuple[
  scale: int, pixels: seq[uint8]]]]

proc rotatingDiamondSize*(radius: int): int =
  ## The LOGICAL (map-pixel) footprint of a spinning diamond sprite — the
  ## same value rotatingDiamondPixels returns, without building any pixels.
  2 * radius + 8

proc rotatingDiamondPixels*(
  radius, frame: int,
  scale = 1
): tuple[size: int, pixels: seq[uint8]] =
  ## One pre-rotated frame of a spinning center diamond, shaded with the same
  ## rooftop material as the baked walls: the mask is rotated, then the
  ## parapet bevel is re-derived from it, so the light stays up-left at every
  ## angle.
  ## The mask comes from rotatedDiamondCovers — the SAME predicate the
  ## collision, bullet, and vision masks stamp — so what a player sees is
  ## exactly what blocks them. `size` is the LOGICAL (map-pixel) footprint;
  ## `pixels` are rasterized at scale× that footprint — the analytic mask is
  ## evaluated per output pixel, so a scaled frame has genuinely smoother
  ## edges, not upscaled blocks.
  let size = 2 * radius + 8
  let index = diamondFrameIndex(frame)
  for cached in diamondFrameCache[index]:
    if cached.scale == scale:
      return (size, cached.pixels)
  let outSize = size * scale
  var mask = newSeq[bool](outSize * outSize)
  for y in 0 ..< outSize:
    for x in 0 ..< outSize:
      ## dx = x/scale - size/2, scaled by the shared denominator. The sprite
      ## blits at cx - size div 2, so this reduces to exactly (X - cx) in map
      ## pixels — the same offsets animatedDiamondCovers samples, at scale×
      ## resolution.
      mask[y * outSize + x] = rotatedDiamondCovers(
        radius, index,
        2 * x - size * scale,
        2 * y - size * scale,
        2 * scale)
  ## One distance transform per frame, then every pixel of the parapet reads
  ## it: the diamond's four 45° faces each get their own tone from their own
  ## normal, which is the whole point of spinning it.
  let field = wallDistField(mask, outSize, outSize, scale)
  var pixels = newSeq[uint8](outSize * outSize * 4)
  for y in 0 ..< outSize:
    for x in 0 ..< outSize:
      if mask[y * outSize + x]:
        let
          color = rooftopColorAt(field, x, y, scale)
          offset = (y * outSize + x) * 4
        pixels[offset] = color.r
        pixels[offset + 1] = color.g
        pixels[offset + 2] = color.b
        pixels[offset + 3] = 255
  diamondFrameCache[index].add((scale: scale, pixels: pixels))
  (size, pixels)

## --- Capture endzones (the floor a carrier must reach to score) ---
## The win condition is a full-height vertical column at each home edge: a live
## carrier scores the instant its center-x crosses the inner threshold, at ANY
## height (captureZoneXRange / checkWinConditions). We make that legible by
## painting the endzone INTO the floor — an in-world "painted endzone", not HUD
## chrome — so it rides the board sprite and scales with the locked composition.
## The old broad half-board territory wash was removed for muddying the flagstone
## into "gradient columns" (L98 #4); this is the opposite: a CONFINED tint inside
## the narrow scoring column only, anchored by a crisp bright threshold line at
## the exact x a carrier must cross. Cosmetic over mapImage → hash-safe.
const
  EndzoneCrackGlow = 165         ## ember alpha on the darkest crack pixels (kept
                                 ## below the pedestal glow so the flag home
                                 ## stays the brightest thing in the endzone).
  EndzoneLineAlpha = 220         ## solid threshold line at the exact score-x.
  EndzoneLineW = 3               ## px width of that threshold line.
  # The concrete floor texture (scripts/art/build_floor.py) is baked to a
  # luminance CONTRACT with these gates: the polished surface — including its
  # light panel-seam bevels — stays at lum 72..112 (at/above FaceLevel → NO
  # glow); only the hairline crack bottoms dip to ~32..34 (at/below CrackLevel
  # → full glow), with the crack tapers crossing the band and glowing partially.
  EndzoneFaceLevel = 66          ## polished-surface floor luminance (glow = 0).
  EndzoneCrackLevel = 34         ## joint/crack-bottom luminance (glow = full).
  EndzoneGlowFloor = 0.82        ## min home-falloff so the far end still glows.
  # The four *EndzoneColor team display colors moved to sim_types (they are
  # shared with the paint FX in sim_state, and hosting them here dragged the
  # whole art bake into the hash module's import DAG).

proc emberThroughCracks(base, ember: ColorRGBA, strength: float): ColorRGBA =
  ## Lets a team ember glow seep UP ONLY through the DARK joint/crack pixels of
  ## the concrete TEXTURE — the polished faces stay completely clean (no base
  ## wash), so team color is confined to the actual fissures/seams, not a flat
  ## tint over the tiles (L98 #4). Distinct from the solid capture LINE, which is
  ## a painted stripe. A two-point luminance gate anchored to the measured floor
  ## split does the confining; `strength` is a gentle pedestal-side falloff.
  let l = (base.r.int * 30 + base.g.int * 59 + base.b.int * 11) div 100
  # 0 at/above a polished face, 1 at/below a crack bottom — cracks only.
  let crack = clamp((EndzoneFaceLevel - l).float /
    (EndzoneFaceLevel - EndzoneCrackLevel).float, 0.0, 1.0)
  let a = strength * crack * crack * EndzoneCrackGlow.float
  overTint(base, rgba(ember.r, ember.g, ember.b, uint8(clamp(a, 0.0, 255.0))))

proc teamEndzoneColor(team: Team): ColorRGBA =
  ## Returns the floor-glow ember color for one team's endzone.
  case team
  of Red: RedEndzoneColor
  of Blue: BlueEndzoneColor
  of Green: GreenEndzoneColor
  of Yellow: YellowEndzoneColor

type EndzoneTint = object
  ## One team's precomputed endzone paint job: its capture-zone box, ember
  ## color, and which box edges are inner THRESHOLD edges (the map-border
  ## edges of the box are not thresholds and draw no line).
  zone: CaptureZone
  color: ColorRGBA
  boundLoX, boundHiX, boundLoY, boundHiY: bool

proc endzoneTints(gameMap: CtfMap): seq[EndzoneTint] =
  ## The active teams' endzone paint jobs, computed once per bake.
  for team in gameMap.teams():
    let zone = gameMap.captureZone(team)
    result.add EndzoneTint(
      zone: zone,
      color: teamEndzoneColor(team),
      boundLoX: zone.xLo > 0,
      boundHiX: zone.xHi < gameMap.width - 1,
      boundLoY: zone.yLo > 0,
      boundHiY: zone.yHi < gameMap.height - 1
    )

proc endzoneColorAt(
  tints: seq[EndzoneTint], base: ColorRGBA, x, y, playLo, playHi,
  playLoY, playHiY: int
): ColorRGBA =
  ## Tints one floor pixel if it sits inside a capture endzone. Team ember
  ## seeps up through the tile cracks, brightest at the pedestal (the inner
  ## threshold edge) and floored so the whole zone still glows; the exact
  ## threshold a carrier must cross gets a crisp solid line. Sides maps
  ## reproduce the classic two-column paint exactly; corner boxes fade on
  ## both axes and line both inner edges.
  for tint in tints:
    if not tint.zone.inCaptureZone(x, y):
      continue
    var
      onLine = false
      near = 1.0
    if tint.zone.disc:
      ## ROUND endzone — the only kind a hex board has: the threshold is the
      ## ember is brightest against it and eases in toward the pedestal —
      ## the same language as the diagonal corner zones.
      let d = sqrt(float(
        (x - tint.zone.anchorX) * (x - tint.zone.anchorX) +
        (y - tint.zone.anchorY) * (y - tint.zone.anchorY)))
      if d > float(tint.zone.radius - EndzoneLineW):
        return overTint(base, rgba(tint.color.r, tint.color.g,
          tint.color.b, EndzoneLineAlpha))
      return emberThroughCracks(base, tint.color,
        EndzoneGlowFloor + (1.0 - EndzoneGlowFloor) *
          clamp(d / max(1, tint.zone.radius).float, 0.0, 1.0))
    if tint.boundHiX:
      if x > tint.zone.xHi - EndzoneLineW:
        onLine = true
      near = min(near, clamp(
        (x - playLo).float / max(1, tint.zone.xHi - playLo).float, 0.0, 1.0))
    if tint.boundLoX:
      if x < tint.zone.xLo + EndzoneLineW:
        onLine = true
      near = min(near, clamp(
        (playHi - x).float / max(1, playHi - tint.zone.xLo).float, 0.0, 1.0))
    if tint.boundHiY:
      if y > tint.zone.yHi - EndzoneLineW:
        onLine = true
      near = min(near, clamp(
        (y - playLoY).float / max(1, tint.zone.yHi - playLoY).float, 0.0, 1.0))
    if tint.boundLoY:
      if y < tint.zone.yLo + EndzoneLineW:
        onLine = true
      near = min(near, clamp(
        (playHiY - y).float / max(1, playHiY - tint.zone.yLo).float, 0.0, 1.0))
    if onLine:
      return overTint(base, rgba(tint.color.r, tint.color.g,
        tint.color.b, EndzoneLineAlpha))
    return emberThroughCracks(base, tint.color,
      EndzoneGlowFloor + (1.0 - EndzoneGlowFloor) * near)
  base

proc shapeLogicalBounds(shape: ArenaShape): tuple[x0, y0, x1, y1: int] =
  ## A conservative logical-pixel bounding box around one obstacle shape (the
  ## scale× rasterizer only evaluates the float geometry inside it).
  case shape.kind
  of shapeDisc:
    (shape.cx - shape.radius - 1, shape.cy - shape.radius - 1,
     shape.cx + shape.radius + 1, shape.cy + shape.radius + 1)
  of shapeBar, shapeHex:
    let r = shapeAsRect(shape)
    (r.x - 1, r.y - 1, r.x + r.w + 1, r.y + r.h + 1)
  of shapeDiagonal:
    (min(shape.x0, shape.x1) - shape.thickness - 1,
     min(shape.y0, shape.y1) - shape.thickness - 1,
     max(shape.x0, shape.x1) + shape.thickness + 1,
     max(shape.y0, shape.y1) + shape.thickness + 1)
  of shapePolygon:
    if shape.points.len == 0:
      (0, 0, -1, -1)
    else:
      var
        x0 = shape.points[0].x
        y0 = shape.points[0].y
        x1 = shape.points[0].x
        y1 = shape.points[0].y
      for p in shape.points:
        x0 = min(x0, p.x); y0 = min(y0, p.y)
        x1 = max(x1, p.x); y1 = max(y1, p.y)
      (x0 - 1, y0 - 1, x1 + 1, y1 + 1)

proc renderArenaRgbaPair*(
  gameMap: CtfMap,
  scale: int
): tuple[hot, cold: seq[uint8]] =
  ## The arena VISUAL rasterized natively at `scale`× map resolution for the
  ## spectator/replay renderer — real detail, not an upscale: wall shapes are
  ## re-evaluated from their float geometry per output pixel (crisp diagonal
  ## chevron/diamond edges), the rooftop parapet bevel grades over scale× more
  ## steps, the concrete floor resolves bilinearly between texels, and the
  ## pedestal art (600px masters) rasterizes at scale× its footprint. The
  ## endzone tint gates stay LOGICAL-column based, so the capture line and
  ## glow columns land exactly where the 1× map puts them. Collision masks are
  ## untouched — they come from loadMapLayers at 1× and stay byte-identical.
  ##
  ## Renders BOTH variants in one pass — `hot` (baked endzone glow, lit
  ## pedestals) and `cold` (glow + capture line omitted, pedestals dimmed, for
  ## the glow-fade overlay) — because they share the two expensive stages: the
  ## geometry mask (rasterized per obstacle bounding box, not by testing every
  ## shape at every output pixel) and the bilinear floor bake. The certifier
  ## boots this on a small CI runner, so the bake must stay a startup blip,
  ## not a first-viewer stall.
  let
    w = gameMap.width
    h = gameMap.height
    ow = w * scale
    oh = h * scale
    cx = gameMap.center.x
    cy = gameMap.center.y
    dir = gameDir()
    floorTex = readImage(dir / "data/arena_floor.png")
  var pedSprs: array[Team, Image]
  for team in gameMap.teams():
    pedSprs[team] = readImage(dir / "data/ped_" & teamText(team) & ".png")
  # The art mask at output resolution: border + obstacle shapes from float
  # geometry, minus the spinning center diamonds (drawn live as objects).
  # Window pixels (glass) get their own mask in the same per-shape pass: wall
  # points inside a window shape draw as the pale pane, not the rooftop
  # material.
  var
    artMask = newSeq[bool](ow * oh)
    windowMask = newSeq[bool](ow * oh)
  let
    bTop = ArenaBorder * scale
    bBottom = (h - ArenaBorder) * scale
    bLeft = ArenaBorder * scale
    bRight = (w - ArenaBorder) * scale
  for y in 0 ..< oh:
    if y < bTop or y >= bBottom:
      for x in 0 ..< ow:
        artMask[y * ow + x] = true
    else:
      for x in 0 ..< bLeft:
        artMask[y * ow + x] = true
      for x in bRight ..< ow:
        artMask[y * ow + x] = true
  for shape in ArenaObstacles:
    if gameMap.isSpinningDiamond(shape):
      continue
    let
      (sx0, sy0, sx1, sy1) = shapeLogicalBounds(shape)
      ox0 = max(0, sx0 * scale)
      oy0 = max(0, sy0 * scale)
      ox1 = min(ow, sx1 * scale)
      oy1 = min(oh, sy1 * scale)
    for y in oy0 ..< oy1:
      let fy = (float(y) + 0.5) / float(scale)
      for x in ox0 ..< ox1:
        let fx = (float(x) + 0.5) / float(scale)
        if shapeWallAtF(fx, fy, shape, cx, cy):
          artMask[y * ow + x] = true
          if shape.window:
            windowMask[y * ow + x] = true
  # ONE distance transform of the finished art mask serves every wall pixel of
  # both materials and both variants. It is the whole shading input: the old
  # per-pixel 4-ray scan was the single most expensive thing in this loop on a
  # big board, because each of its up-to-4·cap steps chased a mask that no
  # longer fits in cache.
  let artDist = wallDistField(artMask, ow, oh, scale)
  # The floor texture tiles the board with a period of exactly texW×texH LOGICAL
  # pixels, so the bilinear floor repeats every texW·scale × texH·scale output
  # pixels — bake ONE tile block and index it, instead of bilinear-sampling
  # 3.3M board pixels (this bake runs at container boot on a small contended
  # CI runner; every pass here is on the certifier's clock).
  let
    tileW = floorTex.width * scale
    tileH = floorTex.height * scale
  var tileBlock = newSeq[ColorRGBA](tileW * tileH)
  for y in 0 ..< tileH:
    let fy = (float(y) + 0.5) / float(scale)
    for x in 0 ..< tileW:
      tileBlock[y * tileW + x] =
        tileSampleF(floorTex, (float(x) + 0.5) / float(scale), fy)
  let
    tints = endzoneTints(gameMap)
    playLo = ArenaBorder
    playHi = w - 1 - ArenaBorder
    playLoY = ArenaBorder
    playHiY = h - 1 - ArenaBorder
  # Where trench art CAN reach: each pit's padded box, in LOGICAL pixels — the
  # same guard loadMapLayers has always had, and for the same reason. Outside
  # these boxes trenchArtColorAt provably returns its input, so adding it here
  # is a pixel-for-pixel no-op; without it EVERY floor pixel pays a scan of
  # EVERY trench, TWICE (hot and cold). A giant board digs 78 pits under 22M
  # output pixels, and that scan alone was ~75% of this bake's wall clock —
  # on the certifier's boot clock.
  var trenchNear = newSeq[bool](w * h)
  for trench in ArenaTrenches:
    # A trench is an `ArenaShape` since GV37 (vector obstacles); every trench is
    # still axis-aligned, so `shapeAsRect` recovers the pit box exactly.
    let tr = shapeAsRect(trench)
    for ty in max(0, tr.y - TrenchArtPadPx) ..<
        min(h, tr.y + tr.h + TrenchArtPadPx):
      for tx in max(0, tr.x - TrenchArtPadPx) ..<
          min(w, tr.x + tr.w + TrenchArtPadPx):
        trenchNear[ty * w + tx] = true
  # Paint straight into the output byte buffers — the pixie Image round trip
  # (premultiply on write, un-premultiply on pack) was pure overhead for an
  # opaque board.
  result.hot = newSeq[uint8](ow * oh * 4)
  result.cold = newSeq[uint8](ow * oh * 4)
  template put(buf: seq[uint8], offset: int, c: ColorRGBA, alpha: uint8) =
    buf[offset] = c.r
    buf[offset + 1] = c.g
    buf[offset + 2] = c.b
    buf[offset + 3] = alpha
  let board = gameMap.mapBoard()
  for y in 0 ..< oh:
    let
      ly = y div scale
      tileRow = (y mod tileH) * tileW
    for x in 0 ..< ow:
      let
        i = y * ow + x
        lx = x div scale
        ## THE hex boundary, at the renderer's own sub-pixel resolution, so the
        ## six edges are drawn as crisply as the scale allows instead of
        ## stepping in whole logical pixels.
        edge = board.hexEdgeDistF((float(x) + 0.5) / float(scale),
                                  (float(y) + 0.5) / float(scale))
        onBorder = edge < float(ArenaBorder)
      if edge <= 0.0:
        ## Outside the hexagon: TRANSPARENT, so the hexagon's silhouette reads
        ## against whatever is behind the board. See `ArenaVoidNote`.
        put(result.hot, i * 4, VoidClear, 0)
        put(result.cold, i * 4, VoidClear, 0)
        continue
      var hotColor, coldColor: ColorRGBA
      if artMask[i]:
        hotColor =
          if windowMask[i]:
            windowGlassColorAt(artDist, x, y, scale)
          else:
            rooftopColorAt(artDist, x, y, scale)
        coldColor = hotColor
      else:
        coldColor = tileBlock[tileRow + x mod tileW]
        hotColor = endzoneColorAt(
          tints, coldColor, lx, ly, playLo, playHi, playLoY, playHiY)
        # The trench pit (config-gated trenches) paints over the finished floor on both
        # variants; it sits at the center, well clear of the endzone glow.
        if trenchNear[ly * w + lx]:
          coldColor = trenchArtColorAt(coldColor, lx, ly)
          hotColor = trenchArtColorAt(hotColor, lx, ly)
      if onBorder:
        hotColor = overTint(hotColor, ArenaBorderColor)
        coldColor = overTint(coldColor, ArenaBorderColor)
      put(result.hot, i * 4, hotColor, 255)
      put(result.cold, i * 4, coldColor, 255)
  # Pedestals: pixie still resizes the painted masters, but the composite onto
  # the board is a manual straight-alpha src-over into the byte buffers.
  for team in gameMap.teams():
    let
      home = gameMap.flagHome(team)
      full = pedSprs[team]
      size = PedestalCoverSize * scale
      scaled = full.resize(size, size)
      dimmed = scaled.pedestalDimmed()
      px0 = home.x * scale - size div 2
      py0 = home.y * scale - size div 2
    for sy in 0 ..< size:
      let dy = py0 + sy
      if dy < 0 or dy >= oh:
        continue
      for sx in 0 ..< size:
        let dx = px0 + sx
        if dx < 0 or dx >= ow:
          continue
        let
          litPx = scaled.data[sy * size + sx].rgba
          dimPx = dimmed.data[sy * size + sx].rgba
          offset = (dy * ow + dx) * 4
        template blend(buf: seq[uint8], src: ColorRGBA) =
          if src.a == 255'u8:
            buf[offset] = src.r
            buf[offset + 1] = src.g
            buf[offset + 2] = src.b
          elif src.a > 0'u8:
            let a = src.a.int
            buf[offset] =
              uint8((src.r.int * a + buf[offset].int * (255 - a)) div 255)
            buf[offset + 1] =
              uint8((src.g.int * a + buf[offset + 1].int * (255 - a)) div 255)
            buf[offset + 2] =
              uint8((src.b.int * a + buf[offset + 2].int * (255 - a)) div 255)
        blend(result.hot, litPx)
        blend(result.cold, dimPx)

proc loadMapLayers*(gameMap: CtfMap, withEndzoneGlow = true):
    tuple[mapImage, walkImage, wallImage: Image] =
  ## Builds the visual map plus the walk and wall masks for the arena. The
  ## visuals: a tiled top-down polished-concrete floor, and ONE coherent
  ## rooftop material for every wall pixel — border frame, rect stub, diamond,
  ## disc, and chevron alike — beveled from the collision mask itself so the
  ## art matches each collider EXACTLY and is identical on both halves by
  ## construction. The
  ## old side-view brick texture (sliced mid-course into the shapes → "torn
  ## ribbon" chevrons) and the three clashing prop sprites (wood crate /
  ## steampunk pipe / barrel scaled to a square over diamond/disc footprints)
  ## are gone (L98 #4: one baked material; let flags + pedestals carry team
  ## identity). Team pedestals stay. The walk/wall COLLISION masks are
  ## byte-identical to before — the art is cosmetic over the exact geometry.
  let
    w = gameMap.width
    h = gameMap.height
    cx = gameMap.center.x
    cy = gameMap.center.y
  result.mapImage = newImage(w, h)
  result.walkImage = newImage(w, h)
  result.wallImage = newImage(w, h)
  let
    clear = rgba(0, 0, 0, 0)
    opaque = rgba(255, 255, 255, 255)
    dir = gameDir()
    floorTex = readImage(dir / "data/arena_floor.png")
  var pedSprs: array[Team, Image]
  for team in gameMap.teams():
    pedSprs[team] = readImage(dir / "data/ped_" & teamText(team) & ".png")
  ## Pass 1: the boolean wall mask (border + obstacles), shared by the shading
  ## bevel and the collision masks so art and geometry can never disagree.
  ## Rasterized per shape (isArenaWall per pixel scans the whole obstacle
  ## list, which is minutes of shape tests on an oversize board).
  let installedProtected = proc (px, py: int): bool =
    isProtectedFloor(px, py, cx, cy)
  var wallMask = rasterizeRestWallMask(gameMap, ArenaObstacles,
    installedProtected)
  ## The static mask drops only the spinning shapes themselves. Any overlapping
  ## wall from another obstacle remains baked under the live sprite.
  let noSpinMask = rasterizeRestWallMask(gameMap, ArenaObstacles,
    installedProtected, includeSpinning = false)
  var artMask = wallMask
  for y in 0 ..< h:
    for x in 0 ..< w:
      if artMask[y * w + x] and isAnimatedDiamondPixel(x, y):
        artMask[y * w + x] = noSpinMask[y * w + x]
  ## The 1× distance field over that same art mask — the sole shading input
  ## for both wall materials below, so the art stays derived from the exact
  ## geometry (and the collision-resolution map a player observes gets the
  ## identical treatment the spectator board does).
  let artDist = wallDistField(artMask, w, h, 1)
  ## Where glass CAN be: the union of the window shapes' footprints, painted
  ## once so the per-pixel glass test below is a mask read instead of an
  ## isArenaWindowPixel obstacle scan (same identity: glass = wall pixel
  ## covered by a window shape).
  var windowCover = newSeq[bool](w * h)
  for shape in ArenaObstacles:
    if not shape.window:
      continue
    let
      bounds = shapeBounds(shape)
      wx0 = max(bounds.x0, 0)
      wy0 = max(bounds.y0, 0)
      wx1 = min(bounds.x1, w - 1)
      wy1 = min(bounds.y1, h - 1)
    for y in wy0 .. wy1:
      for x in wx0 .. wx1:
        if inShape(x, y, shape):
          windowCover[y * w + x] = true
  ## Where trench art CAN reach: each pit's padded box. Outside these,
  ## trenchArtColorAt provably returns its input, so the floor loop skips the
  ## per-pixel trench scan.
  var trenchNear = newSeq[bool](w * h)
  for trench in ArenaTrenches:
    let tr = shapeAsRect(trench)
    for y in max(0, tr.y - TrenchArtPadPx) ..<
        min(h, tr.y + tr.h + TrenchArtPadPx):
      for x in max(0, tr.x - TrenchArtPadPx) ..<
          min(w, tr.x + tr.w + TrenchArtPadPx):
        trenchNear[y * w + x] = true
  ## The capture endzones: the exact score-columns from checkWinConditions'
  ## captureZoneXRange (Red's inclusive right threshold, Blue's inclusive left),
  ## painted into the FLOOR below so a carrier can read where to run.
  let
    tints = endzoneTints(gameMap)
    playLo = ArenaBorder                     # inner playfield edges: the glow
    playHi = w - 1 - ArenaBorder             # anchors home, fades to the line.
    playLoY = ArenaBorder
    playHiY = h - 1 - ArenaBorder
  ## Pass 2: paint. Floor pixels sample the concrete tile; wall pixels are the
  ## rooftop material shaded from the mask. The perimeter frame is overlaid
  ## with the solid border color so the play space reads as a lit pit. Floor
  ## pixels inside a
  ## capture column get a CONFINED team endzone tint + a bright threshold line
  ## (endzoneColorAt) — not the removed broad half-board wash (L98 #4).
  let board = gameMap.mapBoard()
  for y in 0 ..< h:
    for x in 0 ..< w:
      let
        edge = board.hexEdgeDist(x, y)
        onBorder = edge < float(ArenaBorder)
        wall = wallMask[y * w + x]
        artWall = artMask[y * w + x]
        windowPixel = wall and windowCover[y * w + x]
      if edge <= 0.0:
        ## Outside the hexagon: TRANSPARENT art (see `ArenaVoidNote`), and
        ## still WALL in both collision layers exactly as the four wall
        ## predicates say.
        result.mapImage[x, y] = clear
        result.walkImage[x, y] = clear
        result.wallImage[x, y] = opaque
        continue
      var color =
        if windowPixel: windowGlassColor(artDist, x, y)
        elif artWall: rooftopColor(artDist, x, y)
        elif withEndzoneGlow: endzoneColorAt(tints,
          tileSample(floorTex, x, y), x, y, playLo, playHi, playLoY, playHiY)
        else: tileSample(floorTex, x, y)
      if not wall and trenchNear[y * w + x]:
        # The trench pit (config-gated trenches) paints over the finished floor; it never
        # overlaps a wall (it sits inside the open center ring).
        color = trenchArtColorAt(color, x, y)
      if onBorder:
        color = overTint(color, ArenaBorderColor)
      result.mapImage[x, y] = color
      ## The collision layers drop the spinning diamonds for the same reason
      ## the art does: their footprint is not static. initSimServer keeps this
      ## diamond-free bake as the BASE and stamps the live rotated footprint
      ## over it every time the spin frame advances (applyDiamondGeometry).
      let collisionWall = artWall
      result.walkImage[x, y] = if collisionWall: clear else: opaque
      result.wallImage[x, y] = if collisionWall: opaque else: clear
  ## Carved team pedestal under each flag home (walkable — sits inside the
  ## protected spawn pocket; cosmetic only, collision masks untouched). With the
  ## glow OFF this is the "cold" map: the pedestal art is dimmed to a powered-down
  ## disc (see pedestalDimmed) so the broadcast crossfade dims the disc along with
  ## the floor glow when the heart is gone — otherwise a hot==cold pedestal never
  ## fades. The RGB/hot map (withEndzoneGlow) keeps the pedestal at full light.
  for team in gameMap.teams():
    let
      home = gameMap.flagHome(team)
      full = pedSprs[team]
      spr = if withEndzoneGlow: full else: full.pedestalDimmed()
    blitCover(result.mapImage, spr, home.x, home.y, PedestalCoverSize)

proc coldEndzoneMapRgba*(gameMap: CtfMap): seq[uint8] =
  ## Builds the map RGBA with the endzone crack-glow and capture line OMITTED —
  ## the "power source is gone" cold floor. Same layout/format as `sim.mapRgba`
  ## (walls, border, pedestals identical), so a broadcast overlay can crossfade
  ## the baked-glow map toward this and only the glow + line visibly change.
  ## Cosmetic, spectator-only: it is NOT the map the player POV / RL agents see.
  let (mapImage, _, _) = loadMapLayers(gameMap, withEndzoneGlow = false)
  result = newSeq[uint8](MapWidth * MapHeight * 4)
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      let
        pixel = mapImage[x, y]
        offset = (y * MapWidth + x) * 4
      result[offset] = pixel.r
      result[offset + 1] = pixel.g
      result[offset + 2] = pixel.b
      result[offset + 3] = pixel.a

proc loadDarkBgPixels*(): seq[uint8] =
  ## Loads the dark interstitial background as palette pixels.
  let image = readAsepriteImage(gameDir() / DarkBgPath)
  if image.width != ScreenWidth or image.height != ScreenHeight:
    raise newException(
      CtfError,
      DarkBgPath & " must be " & $ScreenWidth & "x" & $ScreenHeight & "."
    )
  result = newSeq[uint8](ScreenWidth * ScreenHeight)
  for y in 0 ..< ScreenHeight:
    for x in 0 ..< ScreenWidth:
      let color = nearestPaletteIndex(image[x, y])
      result[y * ScreenWidth + x] =
        if color == TransparentColorIndex: SpaceColor else: color

