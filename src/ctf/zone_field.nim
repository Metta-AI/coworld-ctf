## The battle-royale shrink-zone SCHEDULE (rect geometry) and the zone-paint
## ARRIVAL-TIME FIELD (the fast-marching frontier solve) — one shared,
## deterministic surface, lifted out of the render layer (global.nim) so the
## SIM can read the same painted(cell) truth the viewer draws
## (zoneDamageByPaint: the owner's "being on the pink paint is what does
## damage, not an invisible rectangle", 2026-09-03).
##
## Layering: global.nim (broadcast/render) imports sim, which imports and
## re-exports THIS module — so the schedule walk, the arrival field, its
## caches and its test taps keep exactly one implementation. Delivery (the
## once-per-episode data sprite + the 1x1 clock object, addZoneEdgeBand) and
## every purely cosmetic constant (ZonePaintBody, the FX label tags) stay in
## global.nim: this module is physics, not pixels.
##
## Everything below this header is MOVED code, verbatim, from sim.nim (the
## schedule: lerpInt through zoneRectAndDps) and global.nim (the round-3
## arrival field block) — see those files' git history for provenance. The
## only non-move changes are export markers on the pieces the two host
## modules now need across the boundary, and the zoneDamageByPaint additions
## (the damage-surface array + its query), each marked with a
## "zoneDamageByPaint:" comment.

import
  std/[heapqueue, math],
  bitworld/profile

import sim_types, arena, sim_config, sim_state

## ============================================================================
## BR ZONE PAINT — round 3: ARRIVAL-TIME FIELD + INCREMENTAL ACCUMULATION.
##
## Round 2 (a3cf203) fixed the "recolor every tick" cache defeat but kept the
## fundamental shape: every tick a rect changes, rebuild + reship four
## FULL-SIZE RGBA bars (up to ~4.5M px) over the wire. A Fable-level audit
## (2026-08-25) named four confirmed defects and this rewrite is the fix for
## all four, not another tuning pass:
##   D1 LAG — bounded per-pixel MATH never bounded per-tick TRAFFIC: the
##     viewer still re-decodes/re-uploads a megapixel sprite on every shrink
##     tick regardless of how cheap the pixel formula got.
##   D2 MARBLE — high-frequency rotated-noise brightness modulation read as
##     psychedelic oil-slick swirl at map zoom. Deleted outright.
##   D3 CONFETTI — a per-pixel threshold over stacked noise gave the frontier
##     speckle and torn fragments, no surface tension.
##   D4 DRY POCKETS + FLOATING BUILDINGS — (a) the render skip mask was built
##     from rendered wall ART (rooftops/parapets), which can swallow whole
##     walkable interiors; (b) the old flow term ADDED drown depth for
##     hard-to-reach pixels — backwards, a room behind a door should flood
##     LATER, not read as MORE drowned.
##
## The fix is architectural: compute one ARRIVAL-TIME FIELD per episode
## (paintArrivalTick, on a coarse ZoneFieldCellPx grid over the true FLOOR
## mask — sim.walkMask, never rendered art) at zone-config load, ship it to
## the client ONCE as a tiny data sprite (a few hundred KB before snappy, not
## megapixels, and never resent), and let every frame's paint be a pure
## READOUT of that static field against a single scalar — "now" — instead of
## a fresh per-tick repaint. See ensureZoneArrivalField for the construction
## and addZoneEdgeBand for delivery; the frame-by-frame render (incremental
## accumulation, the frontier band, the meniscus/gloss/droplet decoration)
## lives client-side in broadcast_core.js, reading the SAME field — the
## single source of truth both sides share, so nothing can drift between
## "what the field says" and "what got drawn."
## ============================================================================

const
  ZoneFieldCellPx* = 4       ## coarse grid stride, px — numerically the same
                             ## as brmapkit.nim's own GridStride (an offline
                             ## mapgen tool this runtime module does not
                             ## import), kept identical by convention.
  ZoneCornerRoundPx* = 16.0  ## rounded-corner SDF radius for the field's own
                             ## GEOMETRIC baseline (see roundedRectSignedDist)
                             ## — the same honesty bound round 2's
                             ## ZoneEdgeBoundPx established: the boundary's
                             ## shape, before any flow delay, never deviates
                             ## from the sharp rect line by more than this.
  ZoneFlowDelayCapTicks* = 1200  ## HONESTY BOUND on the FLOW-DELAY term
                             ## (round 2's spatial ZoneEdgeBoundPx, restated
                             ## in time): however deep a cove or slow a
                             ## doorway, the visual boundary never lags the
                             ## true damage line by more than this many
                             ## ticks. Raised again (350->600->750) past the
                             ## spec's original 150-250 band per Maxwell's
                             ## "tablecloth" ruling — the fingering term
                             ## (zoneFingerDelayAt) needs real spatial room
                             ## to read as a cove, not a ripple. Raised once
                             ## more (750->1200, Fable's audit 2026-08-25):
                             ## the room/aperture reachability fix (see
                             ## ensureZoneFloorGrid) finally gates real,
                             ## multi-cell-deep interior rooms behind their
                             ## own doors instead of misreading them as
                             ## exterior — a genuinely narrow, wall-hugging
                             ## room can legitimately need several hundred
                             ## ticks more than 750 to fill at the speed
                             ## field's own worst-case combined floor
                             ## (aperture x wallDrag x finger), measured
                             ## directly against the honesty test rather
                             ## than guessed. This bound is now for
                             ## PROPAGATION-accumulated lag only (a genuine
                             ## room/aperture chain — see ZoneFingerAmpPx
                             ## below for the split) and the unreached-cell
                             ## fallback in computeZoneFrontierField.
  ZoneFingerAmpPx* = 21.0    ## Maxwell's ruling (2026-08-25, close-zoom
                             ## review of the fresh recording): "it gets way
                             ## too stretched out at points, there should be
                             ## a limit to the amplitude at the meniscus" —
                             ## open-field tongues were stretching into long
                             ## pointed streamers because
                             ## zoneBoundaryFingerDelayAt's seed-nudge
                             ## amplitude was riding the SAME large
                             ## ZoneFlowDelayCapTicks budget raised for
                             ## legitimately deep room/aperture lag, which
                             ## is a completely different physical
                             ## quantity. Split: this bounds ONLY the
                             ## open-field meniscus ripple (a real front's
                             ## own advance-rate variation along its
                             ## length), never room/aperture lag, which
                             ## keeps the full ZoneFlowDelayCapTicks
                             ## headroom.
                             ##
                             ## DENOMINATED IN PIXELS, not ticks (Fable's
                             ## audit, 2026-08-25; coordinator-approved
                             ## re-denomination). Maxwell approved a LOOK,
                             ## on one map — the ticks were only the
                             ## vehicle. The visible amplitude is
                             ## ampTicks * the front's own edge speed, and
                             ## that speed is a property of the MAP and
                             ## schedule: 0.304 px/tick on the showmatch
                             ## map he judged, 0.117 on the small test map.
                             ## Keeping the ruling in ticks therefore made
                             ## his approved look silently vary per map —
                             ## the same 70 ticks is ~21px of meniscus
                             ## there and ~9px here, and a 9px ripple is
                             ## indistinguishable from the hard line he
                             ## rejected. 21.0px is the exact measured
                             ## equivalent of the 70 ticks he approved
                             ## (70 * 0.304), so the judged map is
                             ## unchanged and every other map now gets
                             ## that same approved look instead of an
                             ## arbitrary fraction of it.
  ZoneFingerOctaveFinePx* = 160.0   ## the meniscus's two noise octaves,
  ZoneFingerOctaveCoarsePx* = 260.0  ## in px measured ALONG THE FRONT (see
                             ## zoneFrontLoopCoordAt). Two, so no single
                             ## wavelength's own flat stretch can produce a
                             ## long straight run — both inside the
                             ## 160-300px lobe band of Maxwell's "no sharp
                             ## points" ruling. Exported because the paint
                             ## checks DERIVE their straight-run bound from
                             ## the coarse one rather than restating a
                             ## number: a front cannot stay inside a 1px
                             ## band for longer than its own coarsest
                             ## feature without being a straight line, so
                             ## that wavelength IS the bound, and it moves
                             ## if the tuning does.
  ZoneFingerAmpMaxTicks* = 400  ## CEILING on the converted budget: a
                             ## pathologically slow schedule would turn
                             ## 21px into hundreds of ticks of lateness, so
                             ## the conversion is clamped — well clear of
                             ## the ~180 ticks the slowest real map needs,
                             ## and far below ZoneFlowDelayCapTicks so the
                             ## meniscus/room-lag split Maxwell ruled on
                             ## survives the change. Never silent: the
                             ## clamp is asserted and printed by the paint
                             ## checks when it binds.
                             ##
                             ## RAISED 240 -> 400 with the continuous-close
                             ## schedule (2026-08-25). 240 was sized against
                             ## the OLD staged schedule, whose slowest map
                             ## needed 179 ticks. Deleting the holds and
                             ## stretching the close to 4800 ticks LOWERS
                             ## base speed (more ticks for the same closure,
                             ## not fewer) — the small test map fell to
                             ## 0.0868 px/tick and needed 242, so the clamp
                             ## bound and silently delivered 20.84px instead
                             ## of the approved 21.0. That is a 0.8% cosmetic
                             ## shortfall and would have been invisible; the
                             ## check caught it because a ceiling that can
                             ## bind unnoticed is exactly what this
                             ## assertion exists to prevent. 400 restores
                             ## real headroom and stays far below
                             ## ZoneFlowDelayCapTicks (1200), so the
                             ## meniscus/room-lag split Maxwell ruled on is
                             ## untouched.
  ZoneApertureDoorRefPx = 26.0  ## reference doorway width, px — matches
                             ## arena.nim's MinPassableWidth (the narrowest
                             ## passable floor): local flow speed throttles
                             ## toward its floor as clearance shrinks toward
                             ## this, a genuine bottleneck at a real doorway.
  ZoneApertureMinMult = 0.15   ## flow-speed floor at a fully-choked cell —
                             ## never zero (an unreachable pocket would never
                             ## resolve in the fast-march), but a real drag.
  ZoneWallDragRangePx = 10.0   ## px of proximity to a TRUE wall over which
                             ## flow speed ramps down — the front rounds
                             ## corners and hugs obstacles instead of
                             ## crossing them at open-field speed.
  ZoneWallDragMinMult = 0.5    ## flow-speed multiplier AT the wall (0px).
  ZoneFingerCellPx = 140.0     ## viscous-fingering lattice, px — F(p)'s own
                             ## speed-multiplier lattice (zoneSpeedFieldAt),
                             ## folded into the SAME fast-marching solve, not
                             ## a separate additive field. Wavelength within
                             ## the spec's 300-600px band, biased toward the
                             ## low end so individual finger/cove runs stay
                             ## well under the "no straight run longer than
                             ## ~100px" acceptance bound.
  ZoneFingerAcrossCompress = 4.5  ## cross-axis compression in
                             ## zoneSpeedFieldAt's rotated frame: how much
                             ## more elongated a tongue reads than the plain
                             ## octave's own round blobs — same idiom as
                             ## round 2's ZoneToneStreakLenX, now driven by a
                             ## geometrically real advance direction instead
                             ## of a decorative one. Narrow, elongated coves
                             ## are harder for the solve's own minimum-time
                             ## search to route laterally around than wide
                             ## round ones — see ZoneFingerMinMult.
  ZoneFingerMinMult = 0.55    ## speed floor AT a noise peak (a cove) —
                             ## deliberately lower than the aperture/wall-
                             ## drag floors: a fast-marching solve always
                             ## has some nearby faster lane to detour
                             ## through in open 2D space (that is what makes
                             ## it a CORRECT minimum-time solve), so a mild
                             ## speed dip reads as barely a ripple in the
                             ## final arrival field even though the speed
                             ## field itself visibly varies — only a floor
                             ## this low makes crossing a cove expensive
                             ## enough that the front visibly prefers the
                             ## tip lanes instead of shrugging the noise off.
                             ## TRIED AND REVERTED (0.55->0.3, 2026-08-25):
                             ## hypothesized this floor governed the real
                             ## map's right-edge corridor wash-out (see the
                             ## turning-angle check #7); MEASURED false —
                             ## lowering it left the real-map kink's own
                             ## angle EXACTLY unchanged (89.700...deg, same
                             ## to 11 significant figures) while breaking
                             ## the flow-delay honesty gate and worsening
                             ## the small-map turning angle 0deg->45deg. The
                             ## wash-out is not mediated by this term.
                             ## SECOND TRY, ALSO REVERTED (edge-parallel
                             ## anisotropic drag — full F(p) speed along the
                             ## local advance direction, throttled across
                             ## it, so lateral corridor travel pays a real
                             ## toll — see computeZoneFrontierField's git
                             ## history): also measured ZERO effect on the
                             ## real-map kink's own angle (89.700...deg,
                             ## unchanged to 11 significant figures) while
                             ## regressing door-first (0 -> 1 violation).
                             ## That insensitivity is the actual diagnosis:
                             ## neither point forming the kink is EVER
                             ## improved by propagation at all (an isotropic
                             ## vs anisotropic propagation change altering
                             ## nothing means propagation never wins over
                             ## the raw seed value there) — both are direct
                             ## t0(p) + zoneBoundaryFingerDelayAt(p) seed
                             ## reads, untouched by any F(p)/slowness term.
                             ## The real bug is upstream of propagation
                             ## speed entirely, most likely in how the
                             ## finite-difference `angle` (zoneEdgeAngleAt)
                             ## behaves for a point diagonally outside the
                             ## rect (both edges' corner-influence region at
                             ## once) — open for the next pass.
  ZoneArtOverhangMaxPx = 8.0   ## D4a fix: rendered wall ART may hide a floor
                             ## pixel only THIS close to a TRUE (collision)
                             ## wall cell — a rooftop bevel/parapet's own
                             ## overhang, never a whole walkable interior.
  ZoneFieldSeed = 0x2E15
  ZoneNeverArrives* = 0xFFFF'u16  ## sentinel: this floor cell sits inside the
                             ## schedule's FINAL rect and never floods (real
                             ## arrival ticks stay far below this — a full
                             ## showmatch schedule sums to ~3360 ticks before
                             ## even adding the flow-delay cap).

var
  ZoneWallArtMaskKey: tuple[w, h, cx, cy: int] = (-1, -1, -1, -1)
  ZoneWallArtMask: seq[bool]      ## true wherever RENDERED wall art owns
                                  ## the pixel — see ensureZoneWallArtMask.
  ZoneWallArtMaskW, ZoneWallArtMaskH: int

when defined(zoneArrivalFieldProbe):
  ## Diagnostic-only build flag (never shipped default-on, same discipline
  ## as -d:zonePaintOff below): times and sizes the once-per-episode field
  ## build so a real measurement (not a guess) backs the "well under a
  ## second" perf claim, deterministic and immune to fleet-load wall-clock
  ## noise the way round 2's zoneTideCacheProbe was for its own hot path.
  var
    ZoneArrivalFieldBuildMs*: float
    ZoneArrivalFieldCells*: int
    ZoneArrivalFieldFloorCells*: int
  proc zoneArrivalFieldProbeReport*(): string =
    "ZAF buildMs=" & $ZoneArrivalFieldBuildMs &
      " cells=" & $ZoneArrivalFieldCells &
      " floorCells=" & $ZoneArrivalFieldFloorCells

proc lerpInt(a, b, t, total: int): int {.inline.} =
  ## Integer linear interpolation from `a` to `b`: exactly `a` at t=0 and
  ## exactly `b` at t=total (the multiply-then-divide cancels precisely
  ## regardless of sign), intermediate values integer-truncated. `total <= 0`
  ## returns `b` outright (an instant snap, never a division by zero).
  if total <= 0:
    return b
  a + (b - a) * t div total

proc zoneFinalPermille(sim: SimServer): int =
  ## The LAST configured phase's scale — the z the schedule closes on, and
  ## the z at which the zone has fully arrived at its drawn centre.
  if sim.config.zonePhases.len > 0: sim.config.zonePhases[^1].zPermille
  else: 1000

proc zoneCenterAtScale*(sim: SimServer, zPermille: int): MapPoint =
  ## The centre the zone rect is built about at scale `zPermille`. It DRIFTS,
  ## from the board's own centre at z = 1.0 to the drawn `sim.zoneCenter` at
  ## the schedule's final z.
  ##
  ## Why it must drift (Maxwell's ruling, 2026-08-24). A full-SIZE rect built
  ## about a drawn centre hangs off one edge of the board and leaves an equal
  ## band of real field OUTSIDE the zone. The doctrine calls phase 0 the DROP
  ## and gives it z = 1.00 — the whole field is safe — and it was not: the
  ## first BR match killed 6 of 16 duos at tick 256, before a shot was fired,
  ## because their spawns sat in that band. Spawns span the WHOLE field by
  ## ruling (BR_MAPGEN.md §4.2: no keep-away, not inset), so that is
  ## structural, not a bad draw.
  ##
  ## Clamping the rect to the board does NOT fix it, which is worth stating
  ## because it was the first thing tried: intersecting removes the part
  ## that hangs OFF the board but cannot cover the strip on the OPPOSITE
  ## side, so the far band stays lethal. Only moving the centre makes z = 1.0
  ## mean the whole board.
  ##
  ## Drifting also says the right thing about the mode: at the drop everyone
  ## is safe and the zone has no opinion about where the fight ends, and the
  ## drawn centre — the thing that stops a fixed middle deciding every
  ## episode (§4.3) — expresses itself progressively as the zone closes,
  ## which is exactly when it should matter. It is also what real battle
  ## royales do: the circle moves as it shrinks.
  let
    zFinal = sim.zoneFinalPermille()
    boardCx = sim.gameMap.width div 2
    boardCy = sim.gameMap.height div 2
  ## Degenerate schedules (none configured, or one that never shrinks) keep
  ## the drawn centre outright rather than dividing by zero.
  if zFinal >= 1000:
    return sim.zoneCenter
  ## Progress from "full board" to "fully arrived", in permille of the span
  ## the schedule actually covers.
  let travelled = clamp(
    (1000 - zPermille) * 1000 div (1000 - zFinal), 0, 1000)
  MapPoint(
    x: boardCx + (sim.zoneCenter.x - boardCx) * travelled div 1000,
    y: boardCy + (sim.zoneCenter.y - boardCy) * travelled div 1000)

proc zoneRectAtScale*(sim: SimServer, zPermille: int): MapRect =
  ## Returns the shrink-zone rectangle at scale `zPermille` (1..1000) about
  ## `zoneCenterAtScale(zPermille)`: the map's own aspect ratio (width and
  ## height scaled by the SAME permille from gameMap.width/height), so it is
  ## geometrically similar to the field at every phase. Integer math
  ## throughout — the only float in the whole feature is parsing the AUTHORED
  ## 0..1 `z` at config load (readZonePhaseZ), matching the handicaps/perkMods
  ## convention.
  ##
  ## At z = 1.0 this is the board exactly, whatever centre was drawn — see
  ## zoneCenterAtScale for why the centre drifts rather than sitting still.
  let
    w = max(1, sim.gameMap.width * zPermille div 1000)
    h = max(1, sim.gameMap.height * zPermille div 1000)
    c = sim.zoneCenterAtScale(zPermille)
  MapRect(x: c.x - w div 2, y: c.y - h div 2, w: w, h: h)

proc zoneClampToBoard*(sim: SimServer, rect: MapRect): MapRect =
  ## One zone rect INTERSECTED with the board — the EFFECTIVE zone.
  ##
  ## zoneRectAtScale is a pure geometric statement: a rect of the field's
  ## aspect, scaled about the DRAWN center. At small z that rect sits wholly
  ## on the board and the two are the same thing. At large z it does not:
  ## a full-SIZE rect centered anywhere but the board's own center hangs off
  ## one edge, and leaves an equal band of real field OUTSIDE the zone. So
  ## the doctrine's "phase 0 (drop), z = 1.00" — the whole field is safe —
  ## was false for every drawn center, and the drop phase killed 6 of 16
  ## duos at tick 256 of the first BR match without a shot being fired.
  ##
  ## Maxwell's ruling (2026-08-24): the effective rect is rect INTERSECT
  ## board at EVERY phase. z = 1.0 therefore means the whole board is safe
  ## whatever the drawn center, and the center only starts to express itself
  ## once the rect has shrunk inside the board's edges — which is exactly
  ## when it should matter.
  ##
  ## This is applied in ONE place, wrapping the schedule, because damage,
  ## art and the published label must never disagree about where the
  ## boundary is (the honest-boundary rule). Clamping per-consumer would be
  ## three chances to drift.
  let
    x0 = max(0, rect.x)
    y0 = max(0, rect.y)
    x1 = min(sim.gameMap.width, rect.x + rect.w)
    y1 = min(sim.gameMap.height, rect.y + rect.h)
  MapRect(x: x0, y: y0, w: max(0, x1 - x0), h: max(0, y1 - y0))

proc zoneRectAndDpsRaw(
  sim: SimServer, elapsedTicks: int
): tuple[cur, next: MapRect, dps: int] =
  ## Returns the shrink-zone's CURRENT rect, the NEXT (target) rect it is
  ## heading toward, and the active phase's dps, `elapsedTicks` after the
  ## game started (sim.tickCount - sim.gameStartTick). Pure function of
  ## config + zoneCenter + elapsed ticks — no stored rect/phase-index state
  ## on SimServer, so there is nothing else to keep in sync or hash.
  ##
  ## Walks the phases in order: each holds the PREVIOUS rect (phase 0's
  ## previous is the implicit full-scale z=1.0 rect) for `waitTicks`, then
  ## linearly interpolates into its own target over `shrinkTicks`. Once every
  ## phase's wait+shrink has elapsed, the rect holds at the LAST phase's
  ## target forever and `next` == `cur` (nothing left to pre-rotate toward).
  ## Callers must not call this with an empty zonePhases (guard first, like
  ## updateZone/addZoneMarkers do) — the loop below returns the implicit
  ## full-field rect with dps=0 in that case, which is harmless but pointless
  ## work.
  var
    previousPermille = 1000
    t = max(0, elapsedTicks)
  for phase in sim.config.zonePhases:
    if t < phase.waitTicks:
      return (
        sim.zoneRectAtScale(previousPermille),
        sim.zoneRectAtScale(phase.zPermille),
        phase.dps
      )
    t -= phase.waitTicks
    let target = sim.zoneRectAtScale(phase.zPermille)
    if t < phase.shrinkTicks or phase.shrinkTicks <= 0:
      if phase.shrinkTicks <= 0:
        return (target, target, phase.dps)
      let
        prevRect = sim.zoneRectAtScale(previousPermille)
        tShrink = min(t + 1, phase.shrinkTicks)
        cur = MapRect(
          x: lerpInt(prevRect.x, target.x, tShrink, phase.shrinkTicks),
          y: lerpInt(prevRect.y, target.y, tShrink, phase.shrinkTicks),
          w: lerpInt(prevRect.w, target.w, tShrink, phase.shrinkTicks),
          h: lerpInt(prevRect.h, target.h, tShrink, phase.shrinkTicks)
        )
      return (cur, target, phase.dps)
    t -= phase.shrinkTicks
    previousPermille = phase.zPermille
  let final = sim.zoneRectAtScale(previousPermille)
  let lastDps = if sim.config.zonePhases.len > 0: sim.config.zonePhases[^1].dps
    else: 0
  (final, final, lastDps)

proc zoneRectAndDps*(
  sim: SimServer, elapsedTicks: int
): tuple[cur, next: MapRect, dps: int] =
  ## The schedule above, with both rects clamped to the board — see
  ## zoneClampToBoard. EVERY consumer goes through here (updateZone's
  ## damage test, the seepage art, the published zone label), so all three
  ## read one boundary.
  ##
  ## The interpolation deliberately runs on the RAW rects and is clamped
  ## afterwards, not the other way round: the geometric rect shrinks
  ## continuously from the drawn center, and clamping the result means a
  ## shrink that is still off-board simply does not move the visible edge
  ## yet. Clamping the endpoints first would instead drag the board-edge
  ## edges inward from tick 0 and invent motion that the schedule never
  ## asked for.
  let raw = sim.zoneRectAndDpsRaw(elapsedTicks)
  (
    sim.zoneClampToBoard(raw.cur),
    sim.zoneClampToBoard(raw.next),
    raw.dps
  )

## (zoneTideHash/signedDistanceOutsideRect and round 2's meniscus/droplet/
## flow-blend const block were deleted with the layers that read them — see
## the architecture doc above. roundedRectSignedDist/zoneMeniscusHash/
## zoneMeniscusOctave below survive: still the right primitives for the
## field's geometric baseline and its lobe-noise/tone octaves.)

proc zoneMeniscusHash(seed, kx, ky: int): float {.inline.} =
  ## Deterministic 2D lattice noise in [-1, 1] — a pure function of its
  ## inputs (no RNG state), so a live game and its recorded replay bake the
  ## identical boundary. Same unsigned-mix idiom as trenchEdgeNoise/
  ## zoneTideHash: uint64 throughout so the mix can't hit a checked overflow
  ## on the wasm32 replay viewer.
  let mixed = cast[uint64](seed) * 0x9E3779B97F4A7C15'u64 xor
    cast[uint64](kx) * 73856093'u64 xor
    cast[uint64](ky) * 19349663'u64
  var h = uint32(mixed and 0x7FFFFFFF'u64)
  h = h xor (h shr 13)
  h = h * 0x85EBCA6B'u32
  h = h xor (h shr 16)
  float(h and 0xFFFF) / 32767.5 - 1.0

proc zoneMeniscusOctave(px, py, cellPx: float, seed: int): float =
  ## One octave of smooth value noise in [-1, 1]: bilinear blend of the four
  ## surrounding lattice points, each axis eased with cosine interpolation
  ## `(1-cos(t*PI))/2` rather than linear — a rounded liquid bulge profile
  ## instead of a faceted diamond, the same easing trenchEdgeWave uses for
  ## its (much smaller, 1D) wander.
  let
    cx = px / cellPx
    cy = py / cellPx
    kx0 = floor(cx).int
    ky0 = floor(cy).int
    fx = cx - float(kx0)
    fy = cy - float(ky0)
    sx = (1.0 - cos(fx * PI)) / 2.0
    sy = (1.0 - cos(fy * PI)) / 2.0
    n00 = zoneMeniscusHash(seed, kx0, ky0)
    n10 = zoneMeniscusHash(seed, kx0 + 1, ky0)
    n01 = zoneMeniscusHash(seed, kx0, ky0 + 1)
    n11 = zoneMeniscusHash(seed, kx0 + 1, ky0 + 1)
    nx0 = n00 + (n10 - n00) * sx
    nx1 = n01 + (n11 - n01) * sx
  nx0 + (nx1 - nx0) * sy

proc smoothRamp01(t: float): float {.inline.} =
  ## Hermite smoothstep, clamped to [0, 1] first: 0 at t<=0, 1 at t>=1,
  ## zero SLOPE at both ends (unlike `clamp(t, 0.0, 1.0)` alone, which has
  ## a slope discontinuity — a real kink — right at the two clamp
  ## boundaries). Used wherever a physical quantity ramps smoothly across
  ## a threshold (a choke's own viscosity, see zoneSpeedFieldAt) instead of
  ## snapping a straight line onto a hard floor/ceiling.
  let c = clamp(t, 0.0, 1.0)
  c * c * (3.0 - 2.0 * c)

proc roundedRectSignedDist*(rect: MapRect, cornerR, px, py: float): float =
  ## Signed distance (px) from map point (px, py) to `rect`'s boundary with
  ## its corners rounded to radius `cornerR` — negative inside, 0 on the
  ## boundary, positive outside. Standard 2D "rounded box" SDF. Plain
  ## Chebyshev distance (distanceOutsideRect) has perfectly SQUARE
  ## isolines even after round 1's meniscus noise perturbed them — additive
  ## noise jitters a square's edge, it does not round its CORNER, which is
  ## exactly why Maxwell's round-2 review still read "a hard rectangle
  ## edge" despite an up-to-117px warp. This actually rounds it. Provably
  ## within `cornerR` of the sharp-box distance everywhere (0 far from any
  ## corner, at most `cornerR` right at one) — see ZoneHardSolidDepthPx's
  ## derivation, which relies on that bound.
  let
    hw = float(rect.w) * 0.5
    hh = float(rect.h) * 0.5
    cx = float(rect.x) + hw
    cy = float(rect.y) + hh
    qx = abs(px - cx) - hw + cornerR
    qy = abs(py - cy) - hh + cornerR
    ax = max(qx, 0.0)
    ay = max(qy, 0.0)
  sqrt(ax * ax + ay * ay) + min(max(qx, qy), 0.0) - cornerR

proc zoneFrontLoopCoordAt(px, py: float, rect: MapRect,
    shapeW, shapeH: float): tuple[a, b: float] =
  ## Where (px, py) sits ALONG THE FRONT that will pass through it — as a
  ## point on a CLOSED LOOP in the noise's own 2D domain, whose
  ## circumference equals that front's own perimeter. This is the
  ## coordinate zoneBoundaryFingerDelayAt's octaves read, so a stated 160px
  ## finger wavelength means 160px measured along the front.
  ##
  ## `rect` supplies the CENTRE the family shrinks about; (shapeW, shapeH)
  ## supply its SHAPE — the board's own width and height, the pair
  ## zoneRectAtScale scales every rect in the family from. They are separate
  ## parameters because at the schedule's terminal z the rect is a couple of
  ## integer pixels and no longer carries its own aspect; see DEGENERATE
  ## EXTENTS below, which is the whole reason this signature has them.
  ##
  ## THE FAMILY MATTERS (Fable's audit, 2026-08-25 — this is the second
  ## and load-bearing correction). The zone's rect shrinks by a HOMOTHETY:
  ## w = W*z and h = H*z about the drawn centre, so successive fronts are
  ## SCALED copies of one another. They are NOT offset/eroded copies. Two
  ## earlier parameterizations both assumed the offset family — the base
  ## rect's own perimeter (12cbd6d) and then the level-set/offset curve
  ## through the point — and both inherit that family's defect: the arc
  ## position of a far exterior point is R*(theta + PI/2), and as the point
  ## moves outward along a line, R grows while (theta + PI/2) shrinks, so
  ## the two very nearly CANCEL. Measured offline against the real
  ## showmatch geometry, the offset-curve coordinate leaves a 408px stretch
  ## of the sampled right edge flat to within 1px (the harness measured
  ## 468px on the real thing — the model agrees), and its derivative even
  ## changes SIGN in the far field, which is a fold: two different places
  ## on one front reading the same noise, i.e. a manufactured kink.
  ##
  ## A homothetic family has no such degeneracy. Normalizing by the rect's
  ## own half-extents (that is, by the SHAPE — see below), zp = max(|u|,
  ## |v|) IS the scale of the front through p (exact for a sharp-cornered
  ## rect, and ZoneCornerRoundPx = 16 is negligible against any real rect),
  ## and theta = atan2(v, u) is that front's own angular parameter —
  ## continuous everywhere outside the centre, monotone along every edge, no
  ## quadrant cases at all.
  ##
  ## Sampling on a LOOP rather than by scalar arc length is what removes
  ## the last seam: any scalar "distance around the perimeter" has a branch
  ## cut where it wraps, and a branch cut on a flat edge is exactly the
  ## discontinuity this whole line of work has been chasing. Feeding the
  ## octave a point on a circle of circumference = perimeter instead makes
  ## the coordinate closed by construction — arc length along that circle
  ## equals arc length along the front, and there is nowhere to wrap. It
  ## also gives the fingers the right behaviour through a shrink: they stay
  ## attached to their own theta, so a lobe persists as a material feature
  ## of the front and contracts with it, instead of sliding along it.
  ##
  ## Measured offline (same model that reproduced the 468px defect):
  ## right edge 84px longest flat run, top edge 124px, versus 408px and
  ## 160px for the offset curve.
  ##
  ## DEGENERATE EXTENTS, AND WHY THE SHAPE CANNOT COME FROM `rect`
  ## (2026-08-26, with the close-to-nothing schedule). The schedule now runs
  ## the rect down to the smallest scale the config allows instead of
  ## holding at a terminal room, so the rect the CALLER has is a few px on a
  ## side — 1x1 on the 1235x659 test board, 3x1 on the real 3211x1713
  ## showmatch map. An earlier pass floored hw/hh at 1.0 each to keep the
  ## normalization finite, which is safe but is NOT enough, because the
  ## floor is applied to each axis INDEPENDENTLY and therefore destroys the
  ## one thing this coordinate is built out of: the family's ASPECT.
  ##
  ## THE CONTRACT THAT BREAKS. This proc exists so that "a stated 160px
  ## finger wavelength means 160px measured ALONG THE FRONT" — i.e. so that
  ## |d(loop)/ds| == 1 for a 1px step along the front, everywhere on the
  ## loop. That holds only when (hw, hh) is proportional to the family's
  ## true (W, H). Floored to (1, 1) on a 1.874:1 board the assumed family
  ## becomes SQUARES, and the metric stops being 1: MEASURED before this
  ## fix, |d(loop)/ds| ranged 0.648..1.424 around a mid-schedule front on
  ## the small map (a 2.20x spread) and 0.546..1.756 on the real showmatch
  ## map (3.22x). The stated 160px octave was therefore landing anywhere
  ## from 91px to 293px along the real front — and since a turning-angle
  ## bound derived from that wavelength scales as its INVERSE SQUARE, the
  ## paint could legitimately bend up to 3.1x harder than check #7's term A
  ## priced, purely because of this. That is a self-inflicted regression of
  ## the close-to-zero schedule itself: at the old terminal 385x205 rect the
  ## floor never bound and the contract held.
  ##
  ## THE FIX IS EXACT, NOT A WIDER FLOOR. The loop coordinate is INVARIANT
  ## to which member of the family supplies the normalization, for a fixed
  ## centre: with (hw, hh) = k*(W/2, H/2) the scale reads zp = s/k, the
  ## perimeter reads 4*(hw + hh)*zp = 2*(W + H)*s — k cancels — and theta is
  ## k-free outright. So the shape can be taken from the family's FULL-SCALE
  ## member (the board's own W and H, which is exactly what zoneRectAtScale
  ## scales every rect from) while the CENTRE still comes from `rect`, and
  ## the result is precisely what a non-degenerate `rect` would have given.
  ## No floor can bind, at any z, because W and H are the board's.
  ##
  ## The centre is taken as the rect's own true centre in float. It is not
  ## floored either: flooring it moved the whole loop origin by half a pixel
  ## at a 1px rect for no reason.
  let
    hw = max(1e-6, shapeW * 0.5)
    hh = max(1e-6, shapeH * 0.5)
    u = (px - (float(rect.x) + float(rect.w) * 0.5)) / hw
    v = (py - (float(rect.y) + float(rect.h) * 0.5)) / hh
    zp = max(abs(u), abs(v))
  if zp < 1e-9:
    return (0.0, 0.0)
  let
    theta = arctan2(v, u)
    perim = 4.0 * (hw + hh) * zp
    r = perim / (2.0 * PI)
  (r * cos(theta), r * sin(theta))

## (zoneDropletCellHash/zoneCellSplotchAt/zoneDropletAt/zoneBodyLobeAdvanceAt/
## zoneToneAdvanceAt/zoneDrownedColorAt, ensureZoneFlowGrid/computeZoneFlowDist/
## sampleZoneFlowDepth/zoneFlowBlendedDepth, and zoneDeadPixelColor were all
## deleted here — round 2's PER-RECT confetti frontier, marble tone and
## per-tick Dijkstra. Their replacements (ensureZoneFloorGrid,
## computeZoneFlowTimeToFinal, ensureZoneArrivalField) live below
## isZoneWallArt, and compute a STATIC field once per episode instead of a
## fresh flood/repaint on every rect change.

proc ensureZoneWallArtMask(sim: SimServer) =
  ## Precomputes, once per map, which pixels are covered by RENDERED wall
  ## art — the SAME test renderArenaRgbaPair uses to build its own artMask
  ## (the border ring, plus every obstacle shape via shapeWallAtF) — not
  ## sim.wallMask/isWall, the PHYSICS collision mask. That mask is baked
  ## from a separately-rasterized collision image and is not guaranteed to
  ## line up pixel-for-pixel with a rooftop bevel or parapet drawn past the
  ## collidable core; using it left thin art overhangs still getting
  ## painted (Maxwell's pixel-sampled review: flooded walls still read the
  ## paint's magenta family, not the wall's brown, i.e. the fix wasn't
  ## reaching most of what a screenshot actually shows). This is the exact
  ## art contract instead, cached so the per-pixel zone-band rebuild (which
  ## can run every tick during an active shrink) pays an O(1) lookup, not a
  ## per-obstacle shape retest.
  ##
  ## Spinning diamonds are excluded: they redraw themselves as their own
  ## live sprite objects every frame, tracking their own rotation, so a
  ## static hole for their base footprint would either gap open once
  ## they've spun clear or fight their own live redraw.
  let
    w = sim.gameMap.width
    h = sim.gameMap.height
    cx = sim.gameMap.center.x
    cy = sim.gameMap.center.y
    key = (w: w, h: h, cx: cx, cy: cy)
  if key == ZoneWallArtMaskKey and ZoneWallArtMask.len == w * h:
    return
  ZoneWallArtMaskKey = key
  ZoneWallArtMaskW = w
  ZoneWallArtMaskH = h
  ZoneWallArtMask = newSeq[bool](w * h)
  for y in 0 ..< h:
    let borderRow = y < ArenaBorder or y >= h - ArenaBorder
    for x in 0 ..< w:
      if borderRow or x < ArenaBorder or x >= w - ArenaBorder:
        ZoneWallArtMask[y * w + x] = true
  for shape in ArenaObstacles:
    if sim.gameMap.isSpinningDiamond(shape):
      continue
    let (bx0, by0, bx1, by1) = shapeBounds(shape)
    for y in max(0, by0) .. min(h - 1, by1):
      let fy = float(y) + 0.5
      for x in max(0, bx0) .. min(w - 1, bx1):
        if ZoneWallArtMask[y * w + x]:
          continue
        if shapeWallAtF(float(x) + 0.5, fy, shape, cx, cy):
          ZoneWallArtMask[y * w + x] = true

proc isZoneWallArt(x, y: int): bool {.inline.} =
  if x < 0 or y < 0 or x >= ZoneWallArtMaskW or y >= ZoneWallArtMaskH:
    return true
  ZoneWallArtMask[y * ZoneWallArtMaskW + x]

var
  ZoneFloorGridKey: tuple[w, h, cx, cy: int] = (-1, -1, -1, -1)
  ZoneFloorGridW, ZoneFloorGridH: int
  ZoneFloorWalkable: seq[bool]        ## per coarse cell: sim.walkMask at the
                                      ## cell center — TRUE floor (D4a), never
                                      ## rendered art.
  ZoneFloorWallDistPx: seq[float32]   ## px from cell center to the nearest
                                      ## TRUE (collision) wall cell, via an
                                      ## unweighted BFS over this same grid —
                                      ## feeds wallDrag and the art-overhang
                                      ## dilation bound below.
  ZoneFloorPaintable: seq[bool]       ## walkable AND not swallowed by a
                                      ## nearby wall-ART overhang — see
                                      ## ZoneArtOverhangMaxPx. This is the
                                      ## D4a fix: round 2's isZoneWallArt
                                      ## alone could hide a whole interior;
                                      ## here it only dilates a few px past a
                                      ## TRUE wall.
  ZoneFloorRoomId: seq[int]          ## -1 = exterior world or a narrow
                                      ## aperture (its own honest rect-
                                      ## crossing tick is a trustworthy
                                      ## direct fast-march source); >=0 = an
                                      ## interior room's component id (its
                                      ## arrival may ONLY come from marching
                                      ## in through the room's own door —
                                      ## see computeZoneFrontierField's
                                      ## seeding rule and the research notes
                                      ## on why a raw geometric distance
                                      ## comparison can't tell "genuinely
                                      ## open" from "another cell in the
                                      ## same sealed room, marginally less
                                      ## dead" apart).

proc buildZoneFloorGrid(sim: SimServer, w, h, gw, gh: int) =
  ## The rebuild body of ensureZoneFloorGrid, split out so the CACHE-HIT
  ## path never touches it. This proc contains a nested proc that captures
  ## `sim`, and Nim populates a nested proc's closure environment at the
  ## ENCLOSING proc's entry — copying the whole SimServer value object
  ## (mapRgba, walkMask, fonts: tens of MB on the giant showmatch map, ~30ms
  ## per call) before any early return could run. Keeping the cache check in
  ## a proc with no captures (ensureZoneFloorGrid below) makes the hit path
  ## the O(1) lookup it always claimed to be; this build path pays the copy
  ## once per map, where it is noise.
  let
    haveWalk = sim.walkMask.len == w * h
    haveWall = sim.wallMask.len == w * h
  proc walkableAtPx(px, py: int): bool =
    if px < 0 or py < 0 or px >= w or py >= h:
      return false
    let i = py * w + px
    if haveWalk: sim.walkMask[i]
    elif haveWall: not sim.wallMask[i]
    else: true
  ZoneFloorWalkable = newSeq[bool](gw * gh)
  for gy in 0 ..< gh:
    let py = min(h - 1, gy * ZoneFieldCellPx + ZoneFieldCellPx div 2)
    for gx in 0 ..< gw:
      let px = min(w - 1, gx * ZoneFieldCellPx + ZoneFieldCellPx div 2)
      ZoneFloorWalkable[gy * gw + gx] = walkableAtPx(px, py)
  # Multi-source unweighted BFS from every non-walkable (wall) cell — a
  # cheap, good-enough clearance estimate (px = BFS ring * cell stride) for
  # wallDrag AND the D4a overhang bound. 8-connected, so a diagonal ring is
  # slightly undercounted versus true Euclidean distance; fine for a
  # cosmetic speed/skip signal, not a physics value.
  ZoneFloorWallDistPx = newSeq[float32](gw * gh)
  for i in 0 ..< ZoneFloorWallDistPx.len:
    ZoneFloorWallDistPx[i] = -1.0'f32
  var queue = newSeq[int]()
  for i in 0 ..< gw * gh:
    if not ZoneFloorWalkable[i]:
      ZoneFloorWallDistPx[i] = 0.0'f32
      queue.add(i)
  var qh = 0
  while qh < queue.len:
    let idx = queue[qh]
    inc qh
    let
      gx = idx mod gw
      gy = idx div gw
      d = ZoneFloorWallDistPx[idx]
    for oy in -1 .. 1:
      for ox in -1 .. 1:
        if ox == 0 and oy == 0:
          continue
        let
          nx = gx + ox
          ny = gy + oy
        if nx < 0 or ny < 0 or nx >= gw or ny >= gh:
          continue
        let nidx = ny * gw + nx
        if ZoneFloorWallDistPx[nidx] >= 0.0'f32:
          continue
        ZoneFloorWallDistPx[nidx] = d + float32(ZoneFieldCellPx)
        queue.add(nidx)
  ZoneFloorPaintable = newSeq[bool](gw * gh)
  for gy in 0 ..< gh:
    for gx in 0 ..< gw:
      let idx = gy * gw + gx
      if not ZoneFloorWalkable[idx]:
        continue
      let
        px = min(w - 1, gx * ZoneFieldCellPx + ZoneFieldCellPx div 2)
        py = min(h - 1, gy * ZoneFieldCellPx + ZoneFieldCellPx div 2)
        overhang = isZoneWallArt(px, py) and
          ZoneFloorWallDistPx[idx] <= ZoneArtOverhangMaxPx
      ZoneFloorPaintable[idx] = not overhang
  # Interior-room classification — see ZoneFloorRoomId's own doc above for
  # WHY this is needed (a pure geometric T0 comparison cannot distinguish
  # "genuinely open" from "another cell in the same sealed room"). REDEFINED
  # BY REACHABILITY (Fable's audit, 2026-08-25): the earlier width test
  # flagged a cell as an "aperture" whenever it sat close to ANY single
  # wall, which is wall PROXIMITY, not narrowness — a room-edge cell a few
  # px from its own wall got the same verdict as a true doorway cell pinched
  # on both sides, so a small room (barely wider than the aperture
  # threshold everywhere) had almost every one of its own cells misread as
  # exterior-eligible and direct-seeded at its rect-crossing tick, the
  # "paints in rooms before the door" defect — the giant showmatch map found
  # only ~12 components this way against the mapgen's own thousands of real
  # room candidates.
  #
  # The fix has two parts:
  #   1. A genuine 2-SIDED passage width per cell (rayRunCells below): the
  #      MINIMUM, over 4 opposite-direction axis pairs (W/E, N/S, NW/SE,
  #      NE/SW), of the clear span straight through the cell along that
  #      axis. A true doorway/corridor is pinched on BOTH sides along its
  #      cross-axis (small sum); a room-edge cell is close to one wall but
  #      opens wide on the other side of every axis (large sum) — the
  #      distinction the old 1-sided wall-distance test could not draw.
  #   2. Flood from the MAP'S OWN BORDER over the walkable grid, touching
  #      but never propagating PAST a narrow-gap cell: everything reached
  #      this way is the connected exterior world, or a narrow passage
  #      directly bordering it (its own honest rect-crossing tick is
  #      trustworthy — see the research notes' "genuinely on the retreating
  #      edge" test). Everything the flood never reaches is walled off
  #      behind at least one sub-aperture squeeze and gets its own
  #      connected-component room id; its arrival may only come from
  #      upwind propagation through that squeeze, in computeZoneFrontierField
  #      below. Reachability from the true border (not "whichever component
  #      happens to be biggest") is what makes this work even when a single
  #      giant hall or a courtyard outsizes the nominal "exterior".
  const
    PassageAxisOffsets: array[4, tuple[dx, dy: int]] = [
      (1, 0), (0, 1), (1, 1), (1, -1)
    ]  ## one representative direction per axis (W/E, N/S, NW/SE, NE/SW) —
       ## the opposite direction is walked separately as its negation.
    PassageRayCapCells = int(ZoneApertureDoorRefPx * 1.5 / float(ZoneFieldCellPx)) + 1
      ## any axis whose ray reaches this cap without hitting a wall is, by
      ## construction, already well past the narrow-gap threshold below —
      ## the cap bounds cost without ever mis-measuring a genuinely narrow
      ## axis (which always resolves well inside it).
  proc rayRunCells(startIdx, dx, dy: int): int =
    let
      gx0 = startIdx mod gw
      gy0 = startIdx div gw
    while result < PassageRayCapCells:
      let
        nx = gx0 + dx * (result + 1)
        ny = gy0 + dy * (result + 1)
      if nx < 0 or ny < 0 or nx >= gw or ny >= gh:
        break
      if not ZoneFloorWalkable[ny * gw + nx]:
        break
      inc result
  var isNarrowGap = newSeq[bool](gw * gh)
  block passageWidth:
    let
      narrowThresholdPx = ZoneApertureDoorRefPx * 1.25
      axisStepPx = [
        float(ZoneFieldCellPx), float(ZoneFieldCellPx),
        float(ZoneFieldCellPx) * 1.41421356, float(ZoneFieldCellPx) * 1.41421356
      ]
    for i in 0 ..< gw * gh:
      if not ZoneFloorWalkable[i]:
        continue
      # Cheap short-circuit: a cell already this far from its NEAREST wall
      # in every direction cannot possibly have a 2-sided axis pair summing
      # below the threshold, so the full 8-ray measurement below only ever
      # runs for cells actually close to some wall.
      if ZoneFloorWallDistPx[i] >= narrowThresholdPx:
        continue
      var minWidthPx = Inf
      for a in 0 ..< 4:
        let
          (dx, dy) = PassageAxisOffsets[a]
          posRun = rayRunCells(i, dx, dy)
          negRun = rayRunCells(i, -dx, -dy)
          widthPx = float(posRun + negRun + 1) * axisStepPx[a]
        minWidthPx = min(minWidthPx, widthPx)
      isNarrowGap[i] = minWidthPx < narrowThresholdPx
  ZoneFloorRoomId = newSeq[int](gw * gh)
  for i in 0 ..< ZoneFloorRoomId.len:
    ZoneFloorRoomId[i] = -2  # unvisited
  var reached = newSeq[bool](gw * gh)
  block borderFlood:
    # Seed: a textbook "flood from the map border" needs a walkable cell
    # literally on the GRID's own outer ring — but a real level almost
    # always wraps its whole playable area in a boundary wall (measured on
    # this engine's own maps: zero walkable cells on the ring, for both the
    # small ladder map and the giant showmatch map), so that seed set is
    # always empty here and would misclassify the ENTIRE floor as one
    # sealed interior. The map-topology-agnostic equivalent is the walkable
    # cell FARTHEST from any wall at all: the deepest point of whichever
    # region has the most room to breathe, which on any real level is the
    # open field/hub, never a room (a sealed room's own deepest point is
    # bounded by its own small size). Flooding outward from every cell
    # tied for that maximum, refusing to cross a narrow gap, reaches
    # exactly the connected exterior world — the same result "the map
    # border" would give on a level whose playable area DID touch its own
    # canvas edge, without depending on that ever being true.
    var
      maxWallDist = -1.0'f32
      queue: seq[int]
    for i in 0 ..< gw * gh:
      if ZoneFloorWalkable[i] and ZoneFloorWallDistPx[i] > maxWallDist:
        maxWallDist = ZoneFloorWallDistPx[i]
    for i in 0 ..< gw * gh:
      if ZoneFloorWalkable[i] and ZoneFloorWallDistPx[i] == maxWallDist and
          not reached[i]:
        reached[i] = true
        queue.add(i)
    when defined(zoneRoomClassifyDebug):
      var narrowSeedCount = 0
      for i in queue:
        if isNarrowGap[i]: inc narrowSeedCount
      stderr.writeLine("borderFlood: seeds=" & $queue.len &
        " narrowSeeds=" & $narrowSeedCount & " maxWallDist=" & $maxWallDist &
        " gw=" & $gw & " gh=" & $gh)
    var qh = 0
    while qh < queue.len:
      let idx = queue[qh]
      inc qh
      if isNarrowGap[idx]:
        continue  # touched (already marked reached, so still a trustworthy
                  # direct source) but never propagated PAST — the flood
                  # stops at every squeeze instead of only a hand-picked one.
      let
        cgx = idx mod gw
        cgy = idx div gw
      for oy in -1 .. 1:
        for ox in -1 .. 1:
          if ox == 0 and oy == 0:
            continue
          let
            nx = cgx + ox
            ny = cgy + oy
          if nx < 0 or ny < 0 or nx >= gw or ny >= gh:
            continue
          let nidx = ny * gw + nx
          if not ZoneFloorWalkable[nidx] or reached[nidx]:
            continue
          reached[nidx] = true
          queue.add(nidx)
  for i in 0 ..< gw * gh:
    if reached[i]:
      ZoneFloorRoomId[i] = -1
  block classifyRooms:
    var
      nextId = 0
      queue: seq[int]
    for startIdx in 0 ..< gw * gh:
      if not ZoneFloorWalkable[startIdx] or reached[startIdx]:
        continue
      if ZoneFloorRoomId[startIdx] != -2:
        continue
      let compId = nextId
      inc nextId
      queue.setLen(0)
      queue.add(startIdx)
      ZoneFloorRoomId[startIdx] = compId
      var qh = 0
      while qh < queue.len:
        let idx = queue[qh]
        inc qh
        let
          cgx = idx mod gw
          cgy = idx div gw
        for oy in -1 .. 1:
          for ox in -1 .. 1:
            if ox == 0 and oy == 0:
              continue
            let
              nx = cgx + ox
              ny = cgy + oy
            if nx < 0 or ny < 0 or nx >= gw or ny >= gh:
              continue
            let nidx = ny * gw + nx
            if not ZoneFloorWalkable[nidx] or reached[nidx]:
              continue
            if ZoneFloorRoomId[nidx] != -2:
              continue
            ZoneFloorRoomId[nidx] = compId
            queue.add(nidx)
  when defined(zoneD4OverlayDump):
    ## Diagnostic-only (never shipped default-on): the D4a before/after
    ## verification screenshots, dumped straight from the ALREADY-BUILT
    ## coarse arrays (no redundant per-pixel proc calls, no rebuilding
    ## anything) so this stays proportional to the coarse grid's own size
    ## (a few hundred KB of pixel writes), not the map's full native
    ## resolution.
    block d4Dump:
      var before = newImage(gw, gh)
      var after = newImage(gw, gh)
      let
        floorColor = rgba(150, 150, 150, 255)
        wallColor = rgba(40, 32, 28, 255)
        bugColor = rgba(230, 20, 20, 255)
      var bugCells = 0
      var totalWalkableCells = 0
      for gy2 in 0 ..< gh:
        for gx2 in 0 ..< gw:
          let idx2 = gy2 * gw + gx2
          let
            px2 = min(w - 1, gx2 * ZoneFieldCellPx + ZoneFieldCellPx div 2)
            py2 = min(h - 1, gy2 * ZoneFieldCellPx + ZoneFieldCellPx div 2)
            walkable2 = ZoneFloorWalkable[idx2]
            wallArt2 = isZoneWallArt(px2, py2)
          if walkable2:
            inc totalWalkableCells
          if walkable2 and wallArt2:
            before[gx2, gy2] = bugColor
            inc bugCells
          elif wallArt2:
            before[gx2, gy2] = wallColor
          else:
            before[gx2, gy2] = floorColor
          if ZoneFloorPaintable[idx2]:
            after[gx2, gy2] = floorColor
          else:
            after[gx2, gy2] = wallColor
      stderr.writeLine("D4 dump: grid " & $gw & "x" & $gh &
        " walkableCells=" & $totalWalkableCells &
        " bugCells(walkable-but-wallArt)=" & $bugCells)
      before.writeFile("/tmp/d4-before.png")
      after.writeFile("/tmp/d4-after.png")
      stderr.writeLine("D4 dump: wrote /tmp/d4-before.png and /tmp/d4-after.png")

proc ensureZoneFloorGrid(sim: SimServer) =
  ## Static per-map coarse floor grid, the D4a fix's foundation: walkability
  ## comes from sim.walkMask (TRUE collision), never from rendered wall art.
  ## Cached the same way ensureZoneWallArtMask is (keyed on map dims/center,
  ## a no-op past the first call for a given map). The rebuild lives in
  ## buildZoneFloorGrid, and MUST stay there: see its doc for why hoisting
  ## it back inline would silently turn every cache hit into a full
  ## SimServer copy.
  ensureZoneWallArtMask(sim)
  let
    w = sim.gameMap.width
    h = sim.gameMap.height
    cx = sim.gameMap.center.x
    cy = sim.gameMap.center.y
    key = (w: w, h: h, cx: cx, cy: cy)
    gw = (w + ZoneFieldCellPx - 1) div ZoneFieldCellPx
    gh = (h + ZoneFieldCellPx - 1) div ZoneFieldCellPx
  if key == ZoneFloorGridKey and ZoneFloorWalkable.len == gw * gh:
    return
  ZoneFloorGridKey = key
  ZoneFloorGridW = gw
  ZoneFloorGridH = gh
  buildZoneFloorGrid(sim, w, h, gw, gh)

proc zoneScheduleTotalTicks(sim: SimServer): int =
  ## Sum of every configured phase's wait+shrink — the tick past which the
  ## rect holds at the final phase's target forever (zoneRectAndDpsRaw).
  for phase in sim.config.zonePhases:
    result += phase.waitTicks + phase.shrinkTicks

proc zoneScheduleFingerprint(sim: SimServer): int =
  ## Folds the zonePhases schedule into one int for the arrival-field cache
  ## key — RENDER-ONLY (never gameHash), same unsigned FNV-ish idiom as
  ## zoneMeniscusHash/zoneDropletCellHash so the mix can't hit a checked
  ## overflow. dps is left out on purpose: it affects damage, never geometry.
  var hu = 0xCBF29CE484222325'u64
  for phase in sim.config.zonePhases:
    hu = (hu xor cast[uint64](phase.zPermille)) * 0x100000001B3'u64
    hu = (hu xor cast[uint64](phase.waitTicks)) * 0x100000001B3'u64
    hu = (hu xor cast[uint64](phase.shrinkTicks)) * 0x100000001B3'u64
  int(hu and 0x7FFFFFFF'u64)

proc zoneBaseSpeedPxPerTick*(sim: SimServer, totalTicks: int): float =
  ## The single OPEN-FIELD reference speed every local flow multiplier below
  ## scales (aperture/wallDrag/lobeNoise are all relative to this): the
  ## average px/tick the rect's half-extent recedes WHILE IT IS MOVING.
  ## Everything downstream of this is honest ticks, never a raw px count.
  ##
  ## MOVING TICKS, NOT TOTAL TICKS (2026-08-26). This used to divide by the
  ## whole schedule, waits included, which silently made the reference speed
  ## a fiction on any schedule with a long hold: the front does not creep
  ## during a wait, it stands still and then moves at the full close rate.
  ## ZoneFingerAmpPx is converted to a tick budget by DIVIDING by this
  ## speed, so understating the speed OVERSTATES the budget, and the
  ## meniscus renders proportionally deeper than the look Maxwell approved.
  ## It bit the moment the gear-up became half the schedule (G=3000 of
  ## 6000): the reference read half the true close rate, the amplitude came
  ## out ~2x the approved 21px, and check #7 caught it as a 54.7deg kink at
  ## span 50 — far too coarse a step to blame on quantization.
  ##
  ## Note the self-consistency test one suite over CANNOT catch this: it
  ## asserts ampTicks * speed == ZoneFingerAmpPx, which holds for ANY speed
  ## because ampTicks is defined as ZoneFingerAmpPx / speed. Only comparing
  ## the speed against the rect's ACTUAL motion finds it, which is why the
  ## shape checks are the ones that did.
  if totalTicks <= 0:
    return 1.0
  var waitTicks = 0
  for phase in sim.config.zonePhases:
    waitTicks += phase.waitTicks
  let
    fullW = sim.gameMap.width
    fullH = sim.gameMap.height
    final = sim.zoneRectAndDps(totalTicks).cur
    closeX = float(max(0, fullW - final.w)) * 0.5
    closeY = float(max(0, fullH - final.h)) * 0.5
    movingTicks = max(1, totalTicks - waitTicks)
  max(0.05, (closeX + closeY) / 2.0 / float(movingTicks))

proc zoneEdgeAngleAt(px, py: float, finalRect: MapRect): tuple[ca, sa: float] =
  ## The local rotated frame's basis (ca, sa) = (cos, sin) of the outward
  ## advance direction at map point (px, py) — the finite-difference
  ## gradient of roundedRectSignedDist against the FINAL rect, same
  ## construction zoneSpeedFieldAt's fingering term and
  ## zoneBoundaryFingerDelayAt's seed nudge each used to duplicate inline.
  ## `along = (ca, sa)` points away from the rect (the advance direction);
  ## `across = (-sa, ca)` is its perpendicular (tangential to the local
  ## edge). Shared here so the edge-parallel drag term below (Maxwell's
  ## fluid-sim survey, 2026-08-25 — anisotropic transport cost) uses the
  ## EXACT SAME frame the noise sampling does, never a second, potentially
  ## inconsistent angle.
  const Eps = 1.0
  let
    sdx1 = roundedRectSignedDist(finalRect, ZoneCornerRoundPx, px + Eps, py)
    sdx0 = roundedRectSignedDist(finalRect, ZoneCornerRoundPx, px - Eps, py)
    sdy1 = roundedRectSignedDist(finalRect, ZoneCornerRoundPx, px, py + Eps)
    sdy0 = roundedRectSignedDist(finalRect, ZoneCornerRoundPx, px, py - Eps)
    gx = sdx1 - sdx0
    gy = sdy1 - sdy0
    angle =
      if abs(gx) < 1e-6 and abs(gy) < 1e-6: 0.0
      else: arctan2(gy, gx)
  (cos(angle), sin(angle))

proc zoneSpeedFieldAt(px, py: float, wallDistPx: float32, finalRect: MapRect): float =
  ## F(p) for the fast-marching solve below (computeZoneFrontierField) — see
  ## ~/.ctf/knowledge/research/zone-front/ for the eikonal-equation grounding
  ## (Maxwell's ruling, 2026-08-25: "calculate just the frontier meniscus
  ## line, make that work mathematically correct... then fill in the paint
  ## behind it" — front propagation, not an improvised additive delay). ONE
  ## coherent speed field carries every physical effect the render wants,
  ## all multiplicative, all in (0, 1]:
  ##   - APERTURE: throttles through narrow clearances — a doorway's own
  ##     width relative to ZoneApertureDoorRefPx. Clearance is approximated
  ##     as 2x the distance to the nearest wall (a corridor's centerline
  ##     sits half its own width from either wall).
  ##   - WALL DRAG: slower within ZoneWallDragRangePx of a wall, so the
  ##     front rounds corners and hugs obstacles instead of crossing them at
  ##     open-field speed.
  ##   - FINGERING: a smooth, LOW-frequency, ANISOTROPIC noise octave —
  ##     "viscous fingering" — elongated along the local advance direction
  ##     (the outward gradient of roundedRectSignedDist against the FINAL
  ##     rect, via finite differences; nested/monotonic with every earlier
  ##     phase's rect, so this direction is a stable stand-in for "which way
  ##     the boundary recedes" regardless of which phase is actually live).
  ##     Compressing the cross-axis in that rotated frame stretches the
  ##     octave's normally-round blobs into TONGUES, the same streak trick
  ##     round 2's zoneToneAdvanceAt used for tone — except this angle is
  ##     geometrically real, not decorative. A speed multiplier (never a
  ##     separate additive delay): folding it into F(p) means the FMM solve
  ##     itself produces the fingered isoline as ONE consequence of ONE
  ##     solve, with no second field to blend and no way for an interior
  ##     cell to "borrow" a fast-lane shortcut that skips the walkable graph.
  ##
  ## NOT adopted: per-terrain absorption (Maxwell's fluid-sim survey,
  ## 2026-08-25 — modulating flow speed by local floor MATERIAL, e.g. cave
  ## rock vs built floor). Checked and confirmed absent: neither CtfMap nor
  ## anything reachable from SimServer at runtime carries a spatially-
  ## varying per-cell material signal — the round-11b TERRAIN/THEME switch
  ## (cave/building/mixed, interior/exterior) is a single GLOBAL per-map
  ## choice baked into the art layer, not a per-tile field the solver could
  ## read. Skipped rather than invented a signal that does not exist.
  let
    clearance = wallDistPx.float * 2.0
    # VISCOSITY AT A CHOKE — Maxwell's fluid-sim survey (2026-08-25): the
    # aperture throttle IS the inflow/outflow term a cellular-automaton
    # volume-flow model would balance per tick; the "graphics attach to
    # math" law says that behavior belongs here, in F(p), not in a second
    # live simulation (see the architecture-comparison research note in
    # ~/.ctf/knowledge/research/zone-front/ for why the solver itself stays
    # unchanged). `smoothRamp01` (Hermite smoothstep) replaces the earlier
    # clamped-LINEAR ramp: both already gave a half-width gap roughly half
    # speed (t=0.5 either way), but the clamped-linear version has a real
    # KINK in F(p) at both the clearance=0 floor and the clearance=
    # ZoneApertureDoorRefPx ceiling — a discontinuous SLOPE feeding
    # straight into the eikonal solve, one more source of the sharp-point
    # defect the noise-octave fix (zoneBoundaryFingerDelayAt) addressed for
    # the seed term. The Hermite curve is smooth (zero slope) at both
    # ends, so crossing a choke never bends the isoline's curvature
    # abruptly, only smoothly.
    aperture = ZoneApertureMinMult + smoothRamp01(clearance / ZoneApertureDoorRefPx) *
      (1.0 - ZoneApertureMinMult)
    wallDrag = smoothRamp01(wallDistPx.float / ZoneWallDragRangePx)
    wallMult = ZoneWallDragMinMult + wallDrag * (1.0 - ZoneWallDragMinMult)
    (ca, sa) = zoneEdgeAngleAt(px, py, finalRect)
  let
    along = px * ca + py * sa
    across = (px * -sa + py * ca) * ZoneFingerAcrossCompress
    noise = zoneMeniscusOctave(along, across, ZoneFingerCellPx,
      ZoneFieldSeed xor 0x9F)
    fingerMult = clamp(noise * 0.5 + 0.5, 0.0, 1.0) *
      (1.0 - ZoneFingerMinMult) + ZoneFingerMinMult
      ## in [ZoneFingerMinMult, 1.0] — a noise TROUGH runs at full speed (a
      ## tip, kissing the true line), a PEAK throttles far harder than a
      ## real chokepoint (a cove, lagging deeply). Deliberately a LOWER
      ## floor than the aperture/wallDrag terms: a fast-marching solve
      ## always has some nearby faster lane to detour through in open 2D
      ## space (that's what makes it a CORRECT minimum-time solve), so a
      ## mild speed dip reads as barely a ripple — only a floor this low
      ## makes crossing a cove expensive enough that the front visibly
      ## prefers the tip lanes instead of shrugging the noise off.
  max(0.02, aperture * wallMult * fingerMult)

type ZoneFieldQItem = tuple[t: float32, idx: int]
proc `<`(a, b: ZoneFieldQItem): bool {.inline.} = a.t < b.t


proc zoneBaseArrivalTickAt(
  sim: SimServer, px, py: float, totalTicks: int, finalRect: MapRect
): int =
  ## The tick the TRUE (honest, rounded-corner) damage boundary passes this
  ## point, ignoring flow — a bisection against roundedRectSignedDist over
  ## zoneRectAndDps's own schedule (the SAME function damage reads, sim.nim,
  ## untouched by this file). Rects shrink monotonically over the whole
  ## schedule (every edge is a single affine function of z), so the signed
  ## distance at a fixed point is monotonic non-decreasing in t and a plain
  ## integer bisection finds the exact crossing tick.
  ## Returns high(int) if the point sits inside the FINAL rect and never
  ## floods — the schedule's own "stays safe forever" outcome.
  if roundedRectSignedDist(finalRect, ZoneCornerRoundPx, px, py) <= 0.0:
    return high(int)
  let rect0 = sim.zoneRectAndDps(0).cur
  if roundedRectSignedDist(rect0, ZoneCornerRoundPx, px, py) > 0.0:
    return 0
  var
    lo = 0
    hi = totalTicks
  while hi - lo > 1:
    let
      mid = (lo + hi) div 2
      rectMid = sim.zoneRectAndDps(mid).cur
    if roundedRectSignedDist(rectMid, ZoneCornerRoundPx, px, py) > 0.0:
      hi = mid
    else:
      lo = mid
  hi

const ZoneFrontierOffsets*: array[8, tuple[dx, dy: int]] = [
  (-1, 0), (1, 0), (0, -1), (0, 1),
  (-1, -1), (1, -1), (-1, 1), (1, 1)
]

proc zoneFingerAmpTicksFor*(baseSpeed: float): float =
  ## ZoneFingerAmpPx converted into this map+schedule's own tick budget via
  ## its front speed, clamped to ZoneFingerAmpMaxTicks. Exported so the
  ## paint checks can assert the clamp and report when it binds.
  clamp(ZoneFingerAmpPx / max(baseSpeed, 1e-6), 0.0, ZoneFingerAmpMaxTicks)

proc zoneFingerAmpClampBinds*(baseSpeed: float): bool =
  ## True when the conversion above is being CAPPED rather than honoured —
  ## the map is slower than the ceiling was sized for, so its meniscus will
  ## read smaller than ZoneFingerAmpPx. Reported, never silent.
  ZoneFingerAmpPx / max(baseSpeed, 1e-6) > ZoneFingerAmpMaxTicks

proc zoneBoundaryFingerDelayAt(px, py: float, finalRect: MapRect,
    shapeW, shapeH, ampTicks: float): float =
  ## Fingering at the SOURCE, not just downstream of it. A fast-marching
  ## solve is a MINIMUM-time solve: an exterior cell seeded at exactly its
  ## own honest T0 is already the theoretical fastest value, so no amount
  ## of speed variation elsewhere in F(p) can ever pull it earlier — and a
  ## smooth, open 2D domain always has SOME nearby faster lane to route
  ## around a slow patch, so F(p)'s own fingering (zoneSpeedFieldAt) reads
  ## as almost nothing across the vast open exterior, only inside truly
  ## sealed rooms where there is no alternate path at all. Real spilled
  ## paint fingers in the OPEN field too — the front's own advance rate
  ## varies smoothly along its length, not only where something blocks it.
  ##
  ## This is that variation, applied ONLY at the moment an exterior/
  ## aperture cell becomes a source (see computeZoneFrontierField's seeding
  ## loop) — never blended into an interior cell's own value (interiors
  ## still come ONLY from propagation, unchanged). It reuses the exact same
  ## rotated-frame, advance-direction-elongated octave zoneSpeedFieldAt's
  ## own fingering term samples, just read as a bounded ADDITIVE tick delay
  ## here instead of a speed multiplier there — same lattice, two readouts,
  ## because a source's OWN activation time and a traveller's speed through
  ## already-open ground are two different physical quantities even for the
  ## same underlying viscous texture. Bounded to [0, ampTicks] —
  ## a SMALL cap, not the room/aperture ZoneFlowDelayCapTicks (Maxwell's
  ## ruling, 2026-08-25: streamers, not a meniscus, is what an open-field
  ## nudge riding the room-lag-sized budget looks like — see
  ## ZoneFingerAmpPx's own doc for the split). Late-only either way:
  ## paint may be late here, by up to that much, never early.
  let
    # The ONLY spatial input the octaves below read is position ALONG THE
    # FRONT. A flat rect edge crosses its whole length at the SAME tick
    # (T0 is constant along it), so any variation keyed to the
    # perpendicular coordinate contributes nothing there — the
    # coordinator's original diagnosis: "give the nudge a component keyed
    # to position ALONG the edge, which is exactly what makes tongues on a
    # flat front." Two octaves so no single wavelength's own flat stretch
    # can produce a long straight run either — BOTH inside the 160-300px
    # lobe band (Maxwell's "no sharp points" ruling, 2026-08-25: a real
    # viscous front is curvature-limited, every tongue and cove rounded).
    #
    # zoneFrontLoopCoordAt supplies that position as a point on a closed
    # loop whose circumference is the front's own perimeter — see its doc
    # for why the two earlier parameterizations (the finite-difference
    # rotated-frame angle, then the offset-curve arc length) both failed:
    # they assumed the wrong family of fronts. The zone shrinks by a
    # HOMOTHETY, not an erosion.
    loop = zoneFrontLoopCoordAt(px, py, finalRect, shapeW, shapeH)
    n1 = zoneMeniscusOctave(loop.a, loop.b, ZoneFingerOctaveFinePx,
      ZoneFieldSeed xor 0x9F)
    n2 = zoneMeniscusOctave(loop.a, loop.b, ZoneFingerOctaveCoarsePx,
      ZoneFieldSeed xor 0xB3)
    combined = clamp(n1 * 0.5 + n2 * 0.5, -1.0, 1.0)
  # Full [0, ampTicks] amplitude — late-only (honesty untouched,
  # ZoneFlowDelayCapTicks below still bounds the total), but no headroom
  # held back within THIS smaller budget: a shy amplitude is exactly what
  # left runs long in the earlier passes.
  when defined(zoneFlatPaintControl):
    # NEGATIVE-CONTROL BUILD ONLY (never in a shipped binary; guarded by a
    # define no build sets). Kills the seed nudge outright, so the front
    # reduces to the bare rect edge — the deliberately broken paint the
    # meniscus checks must MOVE on. A check that reads the same green with
    # this define set is measuring nothing (house rule: a gate must
    # DISCRIMINATE, not just hit). See tests/test_zone.nim's recorded
    # control values.
    discard combined
    0.0
  else:
    clamp(combined * 0.5 + 0.5, 0.0, 1.0) * ampTicks

proc computeZoneFrontierField(
  sim: SimServer, totalTicks: int, finalRect: MapRect, baseSpeed: float
): seq[float32] =
  ## Textbook fast marching (Sethian's method — see
  ## ~/.ctf/knowledge/research/zone-front/ for the eikonal-equation grounding
  ## and the exact update formula this implements) solving |∇T|·F(p) = 1 over
  ## the floor domain (ZoneFloorWalkable — true walls excluded from the
  ## domain entirely, i.e. F=0 on them), F(p) = zoneSpeedFieldAt carrying
  ## EVERY physical effect (aperture throttle, wall drag, anisotropic
  ## fingering) as ONE coherent speed field. ONE solve, one clock — Maxwell's
  ## ruling (2026-08-25): "calculate just the frontier meniscus line... then
  ## fill in the paint behind it."
  ##
  ## The zone schedule is the TIME-DEPENDENT boundary condition: a cell
  ## becomes a valid SOURCE (queue-seeded at its own honest rect-crossing
  ## tick, zoneBaseArrivalTickAt) only if it is walkable-adjacent to a
  ## neighbour still safe at that same moment — genuinely on the retreating
  ## edge, not merely geometrically close to it while sealed behind a wall.
  ## Every OTHER reachable cell's value comes ONLY from upwind propagation
  ## through this ONE solve. That is what makes "a room fills door-first,
  ## never before its own door, never faster than the exterior" fall out of
  ## the algorithm's own causality (a Known node's value can only ever come
  ## from an already-SMALLER neighbour — see the research notes) instead of
  ## a hand-built room/aperture classifier: the earlier construction that
  ## let every cell claim its own wall-ignorant geometric tick as a free
  ## source was exactly the bug (rooms reading as reachable from their own
  ## back wall, not their door).
  let
    gw = ZoneFloorGridW
    gh = ZoneFloorGridH
  var t0 = newSeq[int](gw * gh)
  for gy in 0 ..< gh:
    for gx in 0 ..< gw:
      let idx = gy * gw + gx
      if not ZoneFloorWalkable[idx]:
        t0[idx] = high(int)
        continue
      let
        px = float(gx * ZoneFieldCellPx + ZoneFieldCellPx div 2)
        py = float(gy * ZoneFieldCellPx + ZoneFieldCellPx div 2)
      t0[idx] = sim.zoneBaseArrivalTickAt(px, py, totalTicks, finalRect)
  result = newSeq[float32](gw * gh)
  for i in 0 ..< result.len:
    result[i] = Inf.float32
  # One conversion per episode: ZoneFingerAmpPx into THIS map+schedule's
  # own tick budget (see ZoneFingerAmpPx's doc for why the ruling is
  # denominated in pixels).
  let fingerAmpTicks = zoneFingerAmpTicksFor(baseSpeed)
  # The fingering family's SHAPE. zoneRectAtScale builds every rect in the
  # schedule by scaling these two numbers, so they — not the terminal rect's
  # own couple of integer pixels — are what keeps the loop coordinate's
  # "160px means 160px along the front" contract true at every z. See
  # zoneFrontLoopCoordAt's DEGENERATE EXTENTS note.
  let
    shapeW = float(sim.gameMap.width)
    shapeH = float(sim.gameMap.height)
  var pq = initHeapQueue[ZoneFieldQItem]()
  for gy in 0 ..< gh:
    for gx in 0 ..< gw:
      let idx = gy * gw + gx
      if not ZoneFloorWalkable[idx] or t0[idx] == high(int):
        continue
      # ELIGIBLE SOURCE = exterior world or a narrow aperture (ZoneFloorRoomId
      # < 0, see ensureZoneFloorGrid): its own honest rect-crossing tick is a
      # trustworthy direct value. An interior-room cell is NEVER a direct
      # source, however early its own wall-ignorant geometric T0 reads — a
      # raw "does some neighbour have a marginally larger T0" test cannot
      # tell "genuinely adjacent to the safe exterior" from "another cell in
      # the same already-dead sealed room, one grid step less dead" apart
      # (both satisfy that comparison almost everywhere in a smoothly-
      # varying T0 field); only the wall-aware room/aperture split can. A
      # room's value therefore comes ONLY from upwind propagation through
      # this same solve, seeded at its own door — see the research notes.
      if ZoneFloorRoomId[idx] < 0:
        let
          px = float(gx * ZoneFieldCellPx + ZoneFieldCellPx div 2)
          py = float(gy * ZoneFieldCellPx + ZoneFieldCellPx div 2)
        result[idx] = float32(t0[idx]) +
          float32(zoneBoundaryFingerDelayAt(px, py, finalRect,
            shapeW, shapeH, fingerAmpTicks))
        pq.push((t: result[idx], idx: idx))
  proc valueAt(gw, gh, nx, ny: int, field: seq[float32]): float32 {.inline.} =
    if nx < 0 or ny < 0 or nx >= gw or ny >= gh:
      return Inf.float32
    let nidx = ny * gw + nx
    if not ZoneFloorWalkable[nidx]:
      return Inf.float32
    field[nidx]
  # F(p) is a PURE function of position (never of the search itself), but a
  # naive call inside the relaxation loop below re-evaluates it — trig,
  # finite differences, a noise octave — every time ANY popped neighbour
  # touches the same cell, often many times over the course of the march.
  # Precomputing it once per walkable cell is the same "static field, baked
  # once" discipline every other per-pixel cost in this file already uses
  # (ensureZoneStaticFields's round-2 ancestor, ensureZoneFloorGrid's wall
  # distance) — without it, the giant showmatch map's build time was
  # dominated by redundant speed-field recomputation, not the march itself.
  var speedField = newSeq[float32](gw * gh)
  for gy in 0 ..< gh:
    for gx in 0 ..< gw:
      let idx = gy * gw + gx
      if not ZoneFloorWalkable[idx] or t0[idx] == high(int):
        continue
      let
        px = float(gx * ZoneFieldCellPx + ZoneFieldCellPx div 2)
        py = float(gy * ZoneFieldCellPx + ZoneFieldCellPx div 2)
      speedField[idx] = float32(zoneSpeedFieldAt(px, py, ZoneFloorWallDistPx[idx], finalRect))
  let h = float32(ZoneFieldCellPx)
  while pq.len > 0:
    let (t, idx) = pq.pop()
    if t > result[idx]:
      continue                          # stale heap entry, already beaten
    let
      gx = idx mod gw
      gy = idx div gw
    for off in ZoneFrontierOffsets:
      let
        nx = gx + off.dx
        ny = gy + off.dy
      if nx < 0 or ny < 0 or nx >= gw or ny >= gh:
        continue
      let nidx = ny * gw + nx
      if not ZoneFloorWalkable[nidx] or t0[nidx] == high(int):
        continue           # a cell that never crosses (safe inside the
                            # final rect forever) is not part of the dead
                            # zone's domain at all — never a relaxation
                            # target, regardless of march reachability.
      let
        f = speedField[nidx].float
        slowness = h / float32(baseSpeed * f)
        tx = min(valueAt(gw, gh, nx - 1, ny, result),
          valueAt(gw, gh, nx + 1, ny, result))
        ty = min(valueAt(gw, gh, nx, ny - 1, result),
          valueAt(gw, gh, nx, ny + 1, result))
      var best = Inf.float32
      # The 2D quadratic upwind update (Sethian): (T-tx)^2 + (T-ty)^2 =
      # slowness^2, larger (causal) root only, requiring T >= max(tx,ty).
      if tx < Inf.float32 and ty < Inf.float32:
        let
          b = -2.0'f32 * (tx + ty)
          c = tx * tx + ty * ty - slowness * slowness
          disc = b * b - 4.0'f32 * 2.0'f32 * c
        if disc >= 0.0'f32:
          let cand = (-b + sqrt(disc)) / 4.0'f32
          if cand >= max(tx, ty):
            best = cand
      # 1D fallback (only one axis usable, or the quadratic had no causal
      # root) — still upwind, just lower-order at that node.
      if tx < Inf.float32:
        best = min(best, tx + slowness)
      if ty < Inf.float32:
        best = min(best, ty + slowness)
      # Diagonal candidates: a practical octile extension for 8-connectivity
      # (see the research notes — the strict Sethian quadratic is stated for
      # orthogonal pairs; a diagonal neighbour contributes a 1D-style step
      # of length h*sqrt2, the same upwind idea, better isotropy than 4-
      # connectivity alone).
      # TRIED AND REVERTED (edge-parallel anisotropic drag, 2026-08-25):
      # slowed lateral (tangential) propagation relative to radial advance
      # to price the transport a straight open corridor was suspected of
      # letting through for free — MEASURED to have ZERO effect on the
      # real-map right-edge kink's own angle (89.700...deg, unchanged to
      # 11 significant figures across the change) while regressing
      # door-first (0 -> 1 violation). The insensitivity is itself
      # diagnostic: neither of the two points forming that kink is ever
      # IMPROVED by relaxation at all (an isotropic-vs-anisotropic
      # propagation change altering NOTHING means propagation never wins
      # over their own direct seed value there) — both are reading their
      # raw t0(p) + zoneBoundaryFingerDelayAt(p) seed values untouched.
      # The real bug is upstream of propagation entirely: those two points
      # sit diagonally OUTSIDE the current rect (above AND right of it, a
      # corner-influenced region), where the finite-difference `angle`
      # zoneEdgeAngleAt derives for the rotated across-coordinate likely
      # swings sharply over a small move — an open item for the next pass,
      # not a propagation-speed problem at all.
      for doff in ZoneFrontierOffsets:
        if doff.dx == 0 or doff.dy == 0:
          continue
        let dv = valueAt(gw, gh, nx + doff.dx, ny + doff.dy, result)
        if dv < Inf.float32:
          best = min(best, dv + slowness * 1.41421356'f32)
      # HONESTY FLOOR, folded into the update itself rather than applied as
      # an afterthought (Fable's audit, 2026-08-25): t0(p) is not just a
      # cosmetic reference — it is the exact tick sim.nim's own damage rule
      # starts charging a player standing at p, so "never paint before
      # t0(p)" must hold for literally every cell, including a direct
      # source. A smooth 2D domain's own "nearby faster lane" property (the
      # same one that washes out zoneSpeedFieldAt's fingering in open
      # field, by design) can ALSO relax an exterior/aperture cell down
      # BELOW its own t0 via a long detour from a distant, much-earlier-
      # uncovered part of the map — before this fix that undershoot was
      # only corrected in a FINAL pass, after already being used, at full
      # (dishonest) strength, to seed every cell it went on to relax. Two
      # honestly-clamped neighbours therefore did not compose: a room cell
      # and its own door could each independently clamp UP to their own
      # (different) t0 afterward, with no guarantee the room ends up on
      # the correct side of its door — precisely the intermittent "room
      # fills a few ticks before its door" violations this closes. Flooring
      # `best` HERE means every stored value is honest the moment it is
      # written, so the floor propagates forward through the same causal
      # order the FMM already relies on: a room's value, always built from
      # its (now-already-honest) door, can never undercut it.
      if best < Inf.float32 and best < float32(t0[nidx]):
        best = float32(t0[nidx])
      if best < result[nidx]:
        result[nidx] = best
        pq.push((t: best, idx: nidx))
  # Honesty safety clamp (defensive, not the mechanism the six checks
  # verify): never let a reachable cell precede its own honest rect-crossing
  # tick, and never let a cell the solve genuinely never reached read as
  # "never" (F(p)'s own floors already bound every REACHED cell's value —
  # see the research notes — so this upper bound is a fallback for the
  # unreached case, not a ceiling on the solve's own answer).
  #
  # Fable's audit (2026-08-25, once real room population existed to check
  # against): the ORIGINAL version of this clamp applied `min(result[i],
  # t0[i] + cap)` UNCONDITIONALLY, to every cell, reached or not. For a
  # cell deep in a genuinely sealed pocket, upwind propagation through its
  # own door can legitimately need MORE than `cap` ticks past that cell's
  # own WALL-IGNORANT t0 (t0 is pure rect-boundary geometry — it can be
  # early for a point that sits geometrically close to the schedule's
  # center while being walled off many doors deep) — the unconditional
  # clamp then forcibly pulled that cell's honestly-propagated value back
  # DOWN to (an early) t0 + cap, letting it paint BEFORE cells nearer its
  # own door that happened to have a later t0. That is exactly the
  # "wall-ignorant geometric term wins as a free bound" bug the room/
  # aperture source-gating above was built to eliminate, reintroduced
  # through the ceiling instead of the floor. Gating this fallback on
  # `result[i] >= Inf.float32` (the solve never touched this cell at all)
  # keeps the intended safety net — nothing reads as permanently
  # unreachable — without ever overriding an actually-computed, causally
  # correct propagated value.
  for i in 0 ..< result.len:
    if t0[i] == high(int):
      continue
    if result[i] < float32(t0[i]):
      result[i] = float32(t0[i])
    if result[i] >= Inf.float32:
      result[i] = float32(t0[i]) + float32(ZoneFlowDelayCapTicks)

type
  ZoneArrivalField* = object
    gridW*, gridH*: int
    damage*: seq[uint16]   ## zoneDamageByPaint: the DAMAGE surface — the
                           ## same frontier solve as `arrival` below but
                           ## UNGATED by ZoneFloorPaintable. The paintable
                           ## mask is a RENDER skip (D4a: rendered wall art
                           ## — a rooftop bevel/parapet — HIDES the pixel);
                           ## the fluid still flooded under it, so damage
                           ## must not carve 8px wall-hug immunity lanes
                           ## out of cells the art happens to cover. Equal
                           ## to `arrival` on every paintable cell;
                           ## ZoneNeverArrives only for a wall cell
                           ## (off-domain — updateZone falls back to the
                           ## rect test there) or a floor cell inside the
                           ## schedule's final safe rect (genuinely never
                           ## painted, genuinely never damaged).
    arrival*: seq[uint16]  ## per coarse cell, the paint-arrival tick,
                           ## quantized — ZoneNeverArrives (0xFFFF) for a
                           ## wall cell or a floor cell inside the schedule's
                           ## final safe rect. MONOTONE by construction (both
                           ## the geometric base term and the capped flow
                           ## delay only ever add): arrival ticks never
                           ## produce receding paint.

var
  ZoneArrivalFieldKey: tuple[w, h, cx, cy, zcx, zcy, scheduleFp: int] =
    (-1, -1, -1, -1, -1, -1, -1)
  ZoneArrivalFieldValue*: ZoneArrivalField
  ZoneArrivalFieldShipped*: bool  ## whether the data sprite has gone out for
                                 ## the CURRENT key — false again the instant
                                 ## the key changes (a fresh episode/map),
                                 ## which is the only time it gets resent.

type ZoneArrivalFieldDebugState* = object
  built*: bool
  shipped*: bool
  gridW*, gridH*: int
  cells*: int

proc zoneArrivalFieldDebugState*(): ZoneArrivalFieldDebugState =
  ## Read-only live diagnostic for first-light launcher traces. It reports the
  ## exact cached field/shipping state owned by addZoneEdgeBand without causing
  ## the field to build.
  ZoneArrivalFieldDebugState(
    built: ZoneArrivalFieldValue.arrival.len > 0,
    shipped: ZoneArrivalFieldShipped,
    gridW: ZoneArrivalFieldValue.gridW,
    gridH: ZoneArrivalFieldValue.gridH,
    cells: ZoneArrivalFieldValue.arrival.len)

proc ensureZoneArrivalField*(sim: SimServer): bool {.discardable, measure.} =
  ## Builds paintArrivalTick ONCE per episode (the key folds map dims/center,
  ## the drawn zone center, and the zonePhases schedule — any of those
  ## changing means a genuinely different field, which cannot happen
  ## mid-episode but is guarded the same way every other ensure* cache here
  ## guards it). This is the ENTIRE fix for D1: nothing downstream of this
  ## proc runs per tick — the wire ships the field's bytes exactly once (see
  ## addZoneEdgeBand) and every frame after that is a client-side READOUT of
  ## a scalar threshold against this static array.
  let
    w = sim.gameMap.width
    h = sim.gameMap.height
    cx = sim.gameMap.center.x
    cy = sim.gameMap.center.y
    key = (w: w, h: h, cx: cx, cy: cy,
      zcx: sim.zoneCenter.x, zcy: sim.zoneCenter.y,
      scheduleFp: sim.zoneScheduleFingerprint())
  if key == ZoneArrivalFieldKey and ZoneArrivalFieldValue.arrival.len > 0:
    return false
  ZoneArrivalFieldKey = key
  ZoneArrivalFieldShipped = false
  when defined(zoneArrivalFieldProbe):
    let t0 = epochTime()
  ensureZoneFloorGrid(sim)
  let
    gw = ZoneFloorGridW
    gh = ZoneFloorGridH
    totalTicks = sim.zoneScheduleTotalTicks()
    finalRect = sim.zoneRectAndDps(totalTicks).cur
    baseSpeed = sim.zoneBaseSpeedPxPerTick(totalTicks)
    frontier = computeZoneFrontierField(sim, totalTicks, finalRect, baseSpeed)
  var field = ZoneArrivalField(gridW: gw, gridH: gh)
  field.arrival = newSeq[uint16](gw * gh)
  field.damage = newSeq[uint16](gw * gh)
  when defined(zoneArrivalFieldProbe):
    var floorCells = 0
  for gy in 0 ..< gh:
    for gx in 0 ..< gw:
      let idx = gy * gw + gx
      # zoneDamageByPaint: the damage surface reads the frontier DIRECTLY —
      # walkable-domain physics only, no render-skip gate (see the field
      # doc). frontier is finite for every walkable cell outside the final
      # safe rect (computeZoneFrontierField's unreached-cell fallback), so
      # ZoneNeverArrives here means exactly wall/off-domain or final-safe.
      field.damage[idx] =
        if frontier[idx] >= Inf.float32: ZoneNeverArrives
        else: uint16(clamp(frontier[idx].int, 0, 0xFFFE))
      if not ZoneFloorPaintable[idx] or frontier[idx] >= Inf.float32:
        field.arrival[idx] = ZoneNeverArrives
        continue
      when defined(zoneArrivalFieldProbe):
        inc floorCells
      field.arrival[idx] = uint16(clamp(frontier[idx].int, 0, 0xFFFE))
  ZoneArrivalFieldValue = field
  when defined(zoneArrivalFieldProbe):
    ZoneArrivalFieldBuildMs = (epochTime() - t0) * 1000.0
    ZoneArrivalFieldCells = gw * gh
    ZoneArrivalFieldFloorCells = floorCells
  when defined(zoneArrivalFieldContainmentCheck):
    ## Diagnostic-only (never shipped default-on): asserts the field's own
    ## honesty contract — painted(p) at tick T must imply p is outside
    ## rect(T), within the ZoneCornerRoundPx bound; a dry, already-outside
    ## cell's arrival must not exceed T by more than the flow-delay cap plus
    ## slack for the base-tick's own coarse-cell/bisection rounding. Walks a
    ## spread of sample ticks across the whole schedule against the REAL
    ## running config, so this catches anything a synthetic unit test's
    ## smaller map might not reproduce.
    stderr.writeLine("ZAF containment check: grid " & $gw & "x" & $gh &
      " totalTicks=" & $totalTicks)
    for frac in [0.05, 0.15, 0.30, 0.45, 0.55, 0.65, 0.75, 0.85, 0.95, 1.0]:
      let t = int(float(totalTicks) * frac)
      let rect = sim.zoneRectAndDps(t).cur
      var violations = 0
      var worstInsideSd = 0.0
      var overdueViol = 0
      var worstOverdue = 0
      for gy2 in 0 ..< gh:
        for gx2 in 0 ..< gw:
          let idx2 = gy2 * gw + gx2
          if not ZoneFloorPaintable[idx2]:
            continue
          let
            px2 = float(gx2 * ZoneFieldCellPx + ZoneFieldCellPx div 2)
            py2 = float(gy2 * ZoneFieldCellPx + ZoneFieldCellPx div 2)
            arrival2 = field.arrival[idx2].int
            painted = arrival2 <= t
            sd = roundedRectSignedDist(rect, ZoneCornerRoundPx, px2, py2)
          if painted and sd < -ZoneCornerRoundPx - 1.0:
            inc violations
            worstInsideSd = max(worstInsideSd, -sd)
          if sd > ZoneCornerRoundPx and arrival2 != ZoneNeverArrives.int and
              arrival2 > t:
            let overdue = arrival2 - t
            if overdue > ZoneFlowDelayCapTicks + 60:
              inc overdueViol
              worstOverdue = max(worstOverdue, overdue)
      stderr.writeLine("ZAF t=" & $t & " containmentViol=" & $violations &
        " worstInsideSd=" & $worstInsideSd & " overdueViol=" & $overdueViol &
        " worstOverdue=" & $worstOverdue)
  true

proc zoneArrivalFieldCellAt*(px, py: int): tuple[has: bool, arrival: int] =
  ## TEST/DIAGNOSTIC accessor: the arrival tick for the coarse cell covering
  ## map pixel (px, py) — `has=false` off-grid or before any field is built;
  ## `arrival` is 0xFFFF (ZoneNeverArrives) for a wall cell or a floor cell
  ## that never floods. Callers must have already run ensureZoneArrivalField
  ## for the sim in question this episode.
  let
    gx = px div ZoneFieldCellPx
    gy = py div ZoneFieldCellPx
  if ZoneArrivalFieldValue.gridW <= 0 or gx < 0 or gy < 0 or
      gx >= ZoneArrivalFieldValue.gridW or gy >= ZoneArrivalFieldValue.gridH:
    return (false, 0)
  (true, ZoneArrivalFieldValue.arrival[gy * ZoneArrivalFieldValue.gridW + gx].int)

proc zoneArrivalFieldGridDims*(): tuple[w, h: int] =
  (ZoneArrivalFieldValue.gridW, ZoneArrivalFieldValue.gridH)

proc zonePaintedForDamageAt*(
  sim: SimServer, px, py, elapsedTicks: int
): tuple[onField: bool, painted: bool] =
  ## zoneDamageByPaint: the armed damage test — is map pixel (px, py)'s
  ## coarse cell PAINTED (damage-surface arrival <= the schedule's own
  ## elapsed clock, the same `sim.tickCount - sim.gameStartTick` every zone
  ## consumer reads)? Ensures the once-per-episode field first
  ## (ensureZoneArrivalField is keyed and cached, so this is an O(1) lookup
  ## every tick after the first — and the build itself is a pure function
  ## of map + drawn center + schedule, identical whether the render layer
  ## or this damage path triggers it first: one surface, either entrance).
  ##
  ## onField=false — off-grid, or a wall cell where the flow field is
  ## undefined (damage[idx] == ZoneNeverArrives while the cell is
  ## non-walkable) — tells updateZone to fall back to the rect test for
  ## that cog. A cog's center should never sit in a wall cell, but
  ## "should" is not a damage rule: no pixel may read as immortal ground.
  ## A WALKABLE never-cell is the schedule's final safe rect — genuinely
  ## never painted, genuinely never damaged — and reports onField=true,
  ## painted=false forever.
  ensureZoneArrivalField(sim)
  let
    gx = px div ZoneFieldCellPx
    gy = py div ZoneFieldCellPx
    gw = ZoneArrivalFieldValue.gridW
  if gw <= 0 or gx < 0 or gy < 0 or
      gx >= gw or gy >= ZoneArrivalFieldValue.gridH:
    return (false, false)
  let idx = gy * gw + gx
  let damageArrival = ZoneArrivalFieldValue.damage[idx].int
  if damageArrival == ZoneNeverArrives.int:
    if idx < ZoneFloorWalkable.len and ZoneFloorWalkable[idx]:
      return (true, false)
    return (false, false)
  (true, damageArrival <= elapsedTicks)

proc zoneTestWallDistGrid*(sim: SimServer): seq[float32] =
  ## TEST accessor for ZoneFloorWallDistPx — lets a machine check build its
  ## own independent geodesic reference distance using the SAME clearance
  ## data the solver's own F(p) reads, without duplicating the solver's
  ## march itself.
  ensureZoneFloorGrid(sim)
  ZoneFloorWallDistPx

proc zoneTestClassifyRooms*(sim: SimServer): seq[int] =
  ## TEST accessor for ZoneFloorRoomId — the SAME classification
  ## computeZoneFrontierField's own source-eligibility test reads (see
  ## ensureZoneFloorGrid), exposed read-only so the machine checks can
  ## verify the solver's OUTPUT against ground truth an independent
  ## instrument would need anyway, without silently drifting from what the
  ## solver actually used (a duplicated, separately-maintained copy of the
  ## same classifier could rot out of sync and start validating against
  ## itself instead of the solver).
  ensureZoneFloorGrid(sim)
  ZoneFloorRoomId

proc zoneTestFrontLoopCoordAt*(px, py: float, rect: MapRect,
    shapeW, shapeH: float): tuple[a, b: float] =
  ## TEST accessor for zoneFrontLoopCoordAt — the fingering family's own
  ## parameterization, exposed so a machine check can assert the family
  ## does not COLLAPSE at a degenerate terminal rect. A collapse is silent
  ## (one constant coordinate everywhere, hence a dead-flat front), so it
  ## needs a test that reads the mechanism directly rather than only its
  ## downstream shape.
  zoneFrontLoopCoordAt(px, py, rect, shapeW, shapeH)

proc zoneTestPaintableAt*(px, py: int): bool =
  ## TEST/DIAGNOSTIC accessor: ZoneFloorPaintable for the coarse cell
  ## covering map pixel (px, py). Exists for the same reason
  ## zoneTestRoomIdAt does — it takes NO SimServer.
  ##
  ## That matters more than it looks: SimServer is a value `object`, not a
  ## ref, so a per-cell check written against zoneD4MaskAt pays for the sim
  ## on every single call. A whole-board sweep of the real showmatch map is
  ## 803x429 = 344,487 cells, and the ALL PINK check that does exactly that
  ## sweep ran for over an hour before this existed. Callers must have
  ## already run ensureZoneFloorGrid (ensureZoneArrivalField does).
  let
    gx = px div ZoneFieldCellPx
    gy = py div ZoneFieldCellPx
    gw = ZoneFloorGridW
  if gw <= 0 or gx < 0 or gy < 0 or gx >= gw or gy >= ZoneFloorGridH:
    return false
  ZoneFloorPaintable[gy * gw + gx]

proc zoneTestFingerDelayAt*(px, py: float, finalRect: MapRect,
    shapeW, shapeH, ampTicks: float): float =
  ## TEST/DIAGNOSTIC accessor: zoneBoundaryFingerDelayAt, the SEED nudge —
  ## the additive tick delay the solver stamps on an exterior cell at the
  ## moment it becomes a source. Exposed for the same reason
  ## zoneTestRoomIdAt is: check #7's bound is DERIVED from what this
  ## function can do, and a bound derived from a function the instrument
  ## cannot evaluate is a bound nothing can falsify.
  zoneBoundaryFingerDelayAt(px, py, finalRect, shapeW, shapeH, ampTicks)

proc zoneTestBaseArrivalTickAt*(sim: SimServer, px, py: float,
    totalTicks: int, finalRect: MapRect): int =
  ## TEST/DIAGNOSTIC accessor: zoneBaseArrivalTickAt — the tick the TRUE
  ## damage boundary passes this point, ignoring flow. `arrival - this` is
  ## the flow's LAG behind the honest boundary, which is what separates a
  ## meniscus from a touchdown.
  zoneBaseArrivalTickAt(sim, px, py, totalTicks, finalRect)

proc zoneTestScheduleTotalTicks*(sim: SimServer): int =
  ## TEST/DIAGNOSTIC accessor: the schedule's own total tick count, the
  ## same one ensureZoneArrivalField solves against.
  zoneScheduleTotalTicks(sim)

proc zoneTestRoomIdAt*(px, py: int): int =
  ## TEST/DIAGNOSTIC accessor: ZoneFloorRoomId for the coarse cell covering
  ## map pixel (px, py) — the per-pixel readout of zoneTestClassifyRooms,
  ## so a per-sample instrument can ask "is this cell exterior/aperture
  ## ground?" without copying the whole grid on every probe. Negative for
  ## exterior/aperture (and for a wall / off-grid cell); >= 0 is a genuine
  ## interior-room cell — EXACTLY the predicate computeZoneFrontierField's
  ## own source-eligibility test uses (`if ZoneFloorRoomId[idx] < 0`), which
  ## is why the meniscus instrument can share it rather than inventing a
  ## second, driftable notion of "architecture". Callers must have already
  ## run ensureZoneFloorGrid (ensureZoneArrivalField does).
  let
    gx = px div ZoneFieldCellPx
    gy = py div ZoneFieldCellPx
    gw = ZoneFloorGridW
  if gw <= 0 or gx < 0 or gy < 0 or gx >= gw or gy >= ZoneFloorGridH:
    return -1
  ZoneFloorRoomId[gy * gw + gx]

proc zoneD4MaskAt*(sim: SimServer, px, py: int): tuple[walkable, paintable, wallArt: bool] =
  ## D4a VERIFICATION accessor: at full map-pixel resolution (not the coarse
  ## solver grid), the TRUE walkability (sim.walkMask, what the arrival
  ## field's floor domain is actually built from), whether this pixel is
  ## PAINTABLE per the fixed skip mask (walkable AND not swallowed by a
  ## nearby wall-ART overhang — ZoneArtOverhangMaxPx), and the OLD/raw
  ## wall-ART claim alone (isZoneWallArt) — the mask round 2 used
  ## UNCONDITIONALLY as its skip mask, which is exactly the D4a defect: it
  ## can swallow whole interiors, not just a wall's own rendered overhang.
  ensureZoneFloorGrid(sim)
  let
    w = sim.gameMap.width
    h = sim.gameMap.height
  if px < 0 or py < 0 or px >= w or py >= h:
    return (false, false, true)
  let
    walkable = if sim.walkMask.len == w * h: sim.walkMask[py * w + px]
      else: not sim.wallMask[py * w + px]
    wallArt = isZoneWallArt(px, py)
    gx = px div ZoneFieldCellPx
    gy = py div ZoneFieldCellPx
    gw = ZoneFloorGridW
  var paintable = false
  if gx >= 0 and gy >= 0 and gx < gw and gy < ZoneFloorGridH:
    paintable = ZoneFloorPaintable[gy * gw + gx]
  (walkable, paintable, wallArt)
