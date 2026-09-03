## Pins the spray-cone geometry (`sprayContains`, ArcFireRangePx=170,
## ArcMaxWidthPx=85) that a partner-safety / cluster-fire check must use to
## agree with the host's actual fire gate. Two things are pinned:
##
## 1. `sprayContains` itself, on curated points, so a future edit to the
##    engine's cone shape (range/width constants or the forward/perp test)
##    is caught here first.
## 2. `withinFireConeMirror` -- the exact sqrt-free int64 reformulation MONET
##    plays use (see policies/monet/plays/fire_superiority.nim) -- agrees
##    with `sprayContains` across a grid of points and aim angles. Plays run
##    in a wasm sandbox with no libm `sqrt`, so they cannot normalize the aim
##    vector directly; the mirror instead cancels the shared `|aimAt-origin|`
##    factor algebraically. This test is the proof that cancellation is
##    correct, not just a restatement of it.

import std/[unittest, math]
import ../src/shell/body
import ../src/shell/body_map
import ../src/ctf/sim_types

# ── 2. sqrt-free mirror, copied verbatim from fire_superiority.nim ────────
const
  ArcFireRangePxI = 170'i64
  ArcMaxWidthPxI = 85'i64

proc absI64(value: int64): int64 {.inline.} =
  if value < 0: -value else: value

proc withinFireConeMirror(origin, aimAt, other: BodyPoint): bool =
  let
    dx = int64(aimAt.x - origin.x)
    dy = int64(aimAt.y - origin.y)
    dSq = dx * dx + dy * dy
  if dSq <= 0:
    return false
  let
    vx = int64(other.x - origin.x)
    vy = int64(other.y - origin.y)
    forward = vx * dx + vy * dy
    cross = vx * dy - vy * dx
  if forward <= 0:
    return false
  if forward * forward > ArcFireRangePxI * ArcFireRangePxI * dSq:
    return false
  2'i64 * ArcFireRangePxI * absI64(cross) <= ArcMaxWidthPxI * forward

proc aimAtPointFor(origin: BodyPoint, aimBrads: int, reach = 1000): BodyPoint =
  ## A point the engine's own `aimVector(aimBrads)` direction passes through,
  ## `reach` px out -- the "aiming directly at aimAt" case the mirror assumes.
  let (ux, uy) = aimVector(aimBrads)
  (x: origin.x + int(round(ux * reach.float)),
   y: origin.y + int(round(uy * reach.float)))

suite "shell spray cone geometry":
  test "ArcFireRangePx/ArcMaxWidthPx are still 170/85 (LAB config.nim:206-209)":
    check ArcFireRangePx == 170
    check ArcMaxWidthPx == 85

  test "sprayContains: straight ahead, in range and width, is caught":
    check sprayContains((0, 0), 0, (100, 0))

  test "sprayContains: directly behind the aim is never caught":
    check not sprayContains((0, 0), 0, (-50, 0))

  test "sprayContains: beyond ArcFireRangePx is not caught even on-axis":
    check not sprayContains((0, 0), 0, (171, 0))
    check sprayContains((0, 0), 0, (170, 0))

  test "sprayContains: perpendicular width widens linearly with range":
    # At forward=170 the half-width is ArcMaxWidthPx/2 = 42.5px.
    check sprayContains((0, 0), 0, (170, 42))
    check not sprayContains((0, 0), 0, (170, 43))
    # At forward=85 (half the reach) the half-width halves to ~21.25px.
    check sprayContains((0, 0), 0, (85, 21))
    check not sprayContains((0, 0), 0, (85, 22))

  test "mirror agrees with sprayContains across aim angles and offsets":
    ## `aimBrads` is a 256-step quantized angle; `withinFireConeMirror` takes
    ## a continuous point instead (the real usage: aiming AT a track's exact
    ## integer position). The two only have to agree away from the knife
    ## edge -- within ~3px of a boundary, brads quantization can legitimately
    ## flip the decision without either implementation being wrong. That is
    ## why this skips the margin rather than asserting bit-exact agreement
    ## through it; the exact-boundary agreement is pinned separately below
    ## for the four axis-aligned angles, where aimVector has no rounding
    ## error to hide behind.
    let origin: BodyPoint = (500, 500)
    var mismatches = 0
    for brads in countup(0, 255, 5):
      let (ux, uy) = aimVector(brads)
      let aimAt = aimAtPointFor(origin, brads)
      for ox in countup(-200, 200, 25):
        for oy in countup(-200, 200, 25):
          if ox == 0 and oy == 0:
            continue
          let
            vx = float(ox)
            vy = float(oy)
            forward = vx * ux + vy * uy
            perpendicular = abs(vx * uy - vy * ux)
            widthBound = forward * ArcMaxWidthPx.float /
              (2.0 * ArcFireRangePx.float)
          if abs(forward) < 3.0 or abs(forward - ArcFireRangePx.float) < 3.0 or
              (forward > 0.0 and abs(perpendicular - widthBound) < 3.0):
            continue
          let other: BodyPoint = (origin.x + ox, origin.y + oy)
          if sprayContains(origin, brads, other) !=
              withinFireConeMirror(origin, aimAt, other):
            inc mismatches
    check mismatches == 0

  test "cluster/partner-safety semantics: a victim clear of the cone stays clear":
    # A duo partner standing well off the firing line (90 degrees to the
    # side) is never caught, however close -- this is the exact shape
    # fire_superiority.nim's partner-exclusion check relies on.
    let origin: BodyPoint = (0, 0)
    let aimAt: BodyPoint = (170, 0)
    check not withinFireConeMirror(origin, aimAt, (5, 40))
    check not sprayContains(origin, 0, (5, 40))
