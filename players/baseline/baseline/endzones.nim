## Where a carry SCORES, read off the engine's own statement of it.
##
## This module exists because the same mistake has now cost two measurement
## rounds. Both times the policy answered "where is home" with a coordinate it
## DERIVED from the map's dimensions — a "home column" at `MapW * 150 div 1235`
## — and both times the engine moved the capture zone somewhere that literal
## does not reach:
##
##   1. on generated rectangular maps the column sat outside the zone on 3 of 8
##      seeds, so a steal could never convert on those boards;
##   2. on GV38's hexagonal arena every zone became a DISC around the base, and
##      a column at a lane `y` never enters a disc at all.
##
## The engine states each zone outright, once, in an init marker. Reading it is
## not an optimization over the literal — it is the only version of this that
## does not break again the next time the geometry changes. Everything here is
## therefore a pure function of the MARKER TEXT, so the reference policy and
## the tests see exactly the same answer (tests/test_policy_endzones.nim
## checks that answer against the sim's own `inCaptureZone` predicate).
import std/strutils
import ctf/labels

type
  EndzoneMark* = object
    ## One team's stated home capture region:
    ## `endzone <color> <shape> <x0>,<y0> <x1>,<y1>`. The corners are the
    ## INCLUSIVE bounding box in map pixels; `shape` says how the zone fills
    ## that box. The token is stored VERBATIM, including one this build does
    ## not recognize — see `parseEndzoneMarks`.
    color*, shape*: string
    x0*, y0*, x1*, y1*: int

  ZonePoint* = tuple[x, y: float]

const UnknownZoneProbeTicks* = 90
  ## Ticks the carrier dwells on each interior probe of a zone whose shape
  ## token this build does not recognize (see `captureAim`). Long enough to
  ## arrive and stand there, short enough that a full five-probe sweep of the
  ## box costs a few seconds rather than the episode.

proc parseEndzoneMark*(label: string, mark: var EndzoneMark): bool =
  ## Parses one `endzone ...` label. Returns false for a label that is not an
  ## endzone marker or does not carry a bounding box.
  ##
  ## The shape token is KEPT, NOT FILTERED, and that is the point of this
  ## proc. Validating it against this build's copy of `LabelEndzoneShapes` and
  ## dropping the marker otherwise looks like strictness and is the opposite:
  ## the vocabulary is closed on the EMIT side (a `doAssert` in `labelEndzone`)
  ## precisely so that it can grow ADDITIVELY, and a policy that discards the
  ## whole marker on an unrecognized token throws away corners that are exact
  ## map pixels whatever fills them — and then silently falls back to a guess.
  ## That is how a stale literal survives an engine change: not by being wrong
  ## loudly, but by being reached.
  ##
  ## The arity check alone already rejects the spectator-only glow overlay
  ## `endzone <color> power <n>`, which splits into THREE fields rather than
  ## four; both corners must additionally parse as `x,y` integer pairs, so
  ## nothing lands here without a real box.
  if not label.startsWith(LabelPrefixEndzone):
    return false
  let parts = label[LabelPrefixEndzone.len .. ^1].split(' ')
  if parts.len != 4:
    return false
  let
    lo = parts[2].split(',')
    hi = parts[3].split(',')
  if lo.len != 2 or hi.len != 2:
    return false
  try:
    mark = EndzoneMark(
      color: parts[0], shape: parts[1],
      x0: parseInt(lo[0]), y0: parseInt(lo[1]),
      x1: parseInt(hi[0]), y1: parseInt(hi[1])
    )
  except ValueError:
    return false
  true

proc parseEndzoneMarks*(labels: openArray[string]): seq[EndzoneMark] =
  ## Every well-formed endzone marker in a frame's labels.
  var mark: EndzoneMark
  for label in labels:
    if parseEndzoneMark(label, mark):
      result.add mark

proc endzoneIndex*(marks: openArray[EndzoneMark], color: string): int =
  ## The index of one team's stated zone, or -1 if the board sent none.
  for i in 0 ..< marks.len:
    if marks[i].color == color:
      return i
  -1

proc boxCentre*(mark: EndzoneMark): ZonePoint =
  ## The centre of a stated zone's bounding box.
  (x: float(mark.x0 + mark.x1) * 0.5, y: float(mark.y0 + mark.y1) * 0.5)

proc captureAim*(mark: EndzoneMark, tick: int): ZonePoint =
  ## The point to stand on to score inside this zone.
  ##
  ## The marker carries a shape token, so this BRANCHES on it rather than
  ## assuming one geometry fills every box.
  ##
  ## `disc` — the box centre, which is PROVABLY inside. The zone is the circle
  ## inscribed in the box, so its centre IS the box centre and its radius is
  ## half the box extent, which is positive for any box the engine draws. That
  ## guarantee belongs to the disc; it is claimed for nothing else here, and
  ## the four straight-edged tokens GV38 retired are exactly why (an `arm` or
  ## `corner` zone's box centre could sit outside the zone entirely).
  ##
  ## Any OTHER token — a shape added after this build shipped — degrades
  ## instead of breaking. The corners are still exact, so the aim opens at the
  ## box centre, the best single guess for a zone inscribed in a box, and then
  ## walks a slow deterministic cycle of four further probes at half extent so
  ## a carrier whose centre happens not to score sweeps the box rather than
  ## hovering on one dead point. Every probe is strictly inside the bounding
  ## box. This is a SWEEP, not a proof — it is what can honestly be done with
  ## a membership rule this build has never been told.
  let c = mark.boxCentre()
  if mark.shape == LabelEndzoneShapeDisc:
    return c
  let
    qx = float(mark.x1 - mark.x0) * 0.25
    qy = float(mark.y1 - mark.y0) * 0.25
  case (tick div UnknownZoneProbeTicks) mod 5
  of 1: (x: c.x - qx, y: c.y)
  of 2: (x: c.x, y: c.y - qy)
  of 3: (x: c.x + qx, y: c.y)
  of 4: (x: c.x, y: c.y + qy)
  else: c
