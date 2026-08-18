## Rasterizer mirror-bit-identity (coworld-ctf issue: lucky-marten's mask
## diagnostic). pointInPolygon must be reflection-symmetric so a polygon and its
## mirror/rot180 image rasterize to the same wall mask — the team-fairness
## invariant. Encodes the diagnostic as a regression suite: self-symmetric polys
## must be EXACTLY 0 residual (the boundary-handedness bug that broke mesa/carve);
## slanted-edge boundary slivers are bounded, never interior.
import std/unittest
import ctf/[arena, sim_types]

proc mirrorResidual(pts: seq[MapPoint], W: int): tuple[total, interior: int] =
  ## pixels where pointInPolygon(x,y) != pointInPolygon(W-1-x,y, mirrorX(pts)).
  var mp: seq[MapPoint]
  for p in pts: mp.add MapPoint(x: W - 1 - p.x, y: p.y)
  let xs = block:
    var lo = pts[0].x; var hi = pts[0].x
    for p in pts: (lo = min(lo, p.x); hi = max(hi, p.x))
    (lo, hi)
  let ys = block:
    var lo = pts[0].y; var hi = pts[0].y
    for p in pts: (lo = min(lo, p.y); hi = max(hi, p.y))
    (lo, hi)
  for y in ys[0]-2 .. ys[1]+2:
    for x in xs[0]-2 .. xs[1]+2:
      let a = pointInPolygon(x, y, pts)
      let b = pointInPolygon(W - 1 - x, y, mp)
      if a != b:
        inc result.total
        if pointInPolygon(x-1,y,pts)==a and pointInPolygon(x+1,y,pts)==a and
           pointInPolygon(x,y-1,pts)==a and pointInPolygon(x,y+1,pts)==a:
          inc result.interior

suite "rasterizer mirror-bit-identity":
  const W = 1235

  test "self-symmetric axis-aligned poly: EXACT mirror identity (the bug)":
    # the pure repro: a rect-as-polygon that is its own mirror about x=617.
    # The old strict-`<` fill made this [517,716] (right boundary short); the
    # left/right-count fill makes it exact.
    let r = mirrorResidual(@[MapPoint(x:517,y:280), MapPoint(x:717,y:280),
                             MapPoint(x:717,y:380), MapPoint(x:517,y:380)], W)
    check r.total == 0

  test "vertical-edge triangle (mesa ramp/crevice band shape): EXACT":
    let r = mirrorResidual(@[MapPoint(x:384,y:260), MapPoint(x:384,y:400),
                             MapPoint(x:300,y:330)], W)
    check r.total == 0

  test "slanted poly: NO interior asymmetry (slivers bounded to the boundary)":
    let r = mirrorResidual(@[MapPoint(x:300,y:280), MapPoint(x:384,y:300),
                             MapPoint(x:360,y:360), MapPoint(x:300,y:340)], W)
    check r.interior == 0
