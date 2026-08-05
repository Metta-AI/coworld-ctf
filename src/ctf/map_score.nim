## Layer 1 (hard gates) and Layer 2 (the static score) of
## docs/plans/2026-08-04-map-generator-rebuild.md §6, plus the ranker that
## `generateCtfMap` calls to ship the BEST of K valid candidates instead of
## the first one.
##
## Why this is a separate module from `map_metrics`: that one MEASURES and
## this one JUDGES. Every band below is a decision — a number picked against
## the control, with the reason beside it — while nothing in `map_metrics`
## has an opinion. Keeping them apart is what lets a threshold move without
## touching a measurement, and it is what makes "which bands actually moved"
## a reviewable diff.
##
## Why it lives in `src/ctf/` and not `tools/`: the GENERATOR ranks with it.
## `arena.nim` cannot import it (the metrics read `arena`'s rasterizer, so
## the import would cycle), so the dependency is inverted: `arena` exposes a
## `{.nimcall.}` ranker hook and this module installs itself into it at
## module initialization. `sim.nim` imports this module, so every binary
## that builds a game ranks; the replay viewer, which never generates a map,
## does not import it and pays nothing.
##
## The hook is safe precisely BECAUSE of `map_metrics`' purity invariant: a
## gcsafe function of its arguments alone can be called from the boot path
## and from a mummy request thread with no synchronization at all.
import std/[math, strformat], sim_types, arena, map_metrics
export map_metrics

type
  Check* = object
    ## One scored band.
    ##
    ## `controlRelative` bands take their bound from the control's own
    ## measurement, which is what "pick thresholds against the control"
    ## means operationally. `loOpen` / `hiOpen` mark a bound that does not
    ## exist — a one-sided rule like "at least 3 routes" has no upper bound,
    ## and pretending it does produced a permanent "tight" warning on every
    ## map that comfortably passed. `taper` is the distance outside the band
    ## over which the score falls to zero, so two failing candidates still
    ## rank against each other.
    ##
    ## `scored = false` keeps a metric MEASURED and PRINTED while excluding
    ## it from the score, for a rule that provably does not govern this
    ## regime. That is not the same as skipping it: the number is on screen
    ## with the reason beside it.
    name*: string
    value*, lo*, hi*, weight*, taper*: float
    loOpen*, hiOpen*: bool
    unit*: string            ## "pct" | "px" | "n" | "x"
    controlRelative*: bool
    scored*: bool
    skipReason*: string
    note*: string

  ScoreCard* = object
    checks*: seq[Check]
    score*: float            ## weighted band satisfaction, 0..1.

# ---------------------------------------------------------------- gates ----

proc hardGates*(metrics: MapMetrics): string =
  ## Layer 1: reject outright. These are not preferences — a map that fails
  ## one cannot be played fairly at all.
  ##
  ## The shipped validators come first (sightlines, corridor connectivity,
  ## cover budget, endzone reachability), then the two the repo never had:
  ## a base pair with no independent flank route, and an unreachable base.
  if metrics.validationReason.len > 0:
    return metrics.validationReason
  if metrics.minRoutes <= 0:
    return "no route at all between two bases"
  if metrics.minRoutes < 2:
    return &"only {metrics.minRoutes} vertex-disjoint route(s) between " &
      "two bases — a single cut severs the map"
  for route in metrics.routes:
    if route.pathPx <= 0:
      return &"team {route.a} cannot walk to team {route.b}'s base"
  ""

# --------------------------------------------------------------- scoring ----

proc passes*(check: Check): bool =
  (check.loOpen or check.value >= check.lo) and
    (check.hiOpen or check.value <= check.hi)

proc bandScore*(check: Check): float =
  ## 1.0 inside the band, tapering to 0 over `taper` outside it. A hard 0/1
  ## makes the score a step function that cannot rank two failing
  ## candidates, which is the whole point of having a score.
  if check.passes():
    return 1.0
  let slack = max(check.taper, 1e-6)
  if not check.loOpen and check.value < check.lo:
    max(0.0, 1.0 - (check.lo - check.value) / slack)
  else:
    max(0.0, 1.0 - (check.value - check.hi) / slack)

proc isTight*(check: Check): bool =
  ## Within a quarter of the taper of a bound that actually exists: passing,
  ## but with no slack left for the next change to spend silently.
  if not check.passes():
    return false
  let margin = check.taper * 0.25
  (not check.loOpen and check.value - check.lo <= margin) or
    (not check.hiOpen and check.hi - check.value <= margin)

proc scoreMap*(metrics: MapMetrics, control: MapMetrics): ScoreCard =
  ## The static score. Absolute bands come from the MW2 field study; the
  ## rest are anchored on the control's own measurement, because a number
  ## picked out of the air is how a metric ends up flagging the map the
  ## engine was tuned on.
  ##
  ## Deliberately NOT scored, and why:
  ##   * trench count. The brief's 3-8 band would flag the control, which
  ##     has none. Reported, never scored.
  ##   * midfield OPENNESS as an absolute. The control is 70%+ open across
  ##     midfield, so any fixed bar that means anything fires on it. What is
  ##     comparable is how many distinct ways across that openness divides
  ##     into — that IS scored, with the fraction printed beside it.
  var checks: seq[Check]

  proc add(name: string, value, lo, hi, taper, weight: float, unit: string,
           loOpen = false, hiOpen = false, controlRelative = false,
           skipReason = "", note = "") =
    checks.add Check(name: name, value: value, lo: lo, hi: hi, taper: taper,
      weight: weight, loOpen: loOpen, hiOpen: hiOpen, unit: unit,
      controlRelative: controlRelative, scored: skipReason.len == 0,
      skipReason: skipReason, note: note)

  ## The conversion invariant, the single biggest finding of the MW2 study:
  ## a stand standing in the open never converted (6-12% cover within 200px)
  ## while every map that did convert measured 10-25%.
  ##
  ## It governs CAPTURE-AT-THE-STAND maps. On a legacy full-height column
  ## endzone the carrier scores by crossing into the home column, the whole
  ## `captureClear` strip is protected floor the generator may not build in,
  ## and the reading is structurally low for a reason that has nothing to do
  ## with how the map plays: the square control measured 7.2% and converted
  ## fine. So the numbers are measured and printed on every map, and scored
  ## only where the rule applies.
  var standSkip =
    if metrics.compactEndzone: ""
    else: "legacy column endzone: capture is not at the stand here"
  ## And the second way this band can be unreachable: a compact endzone
  ## whose radius swallows the whole 200px annulus makes every pixel of it
  ## protected floor, where the generator is forbidden to build. Scoring
  ## that would rank maps on their endzone radius, not on their terrain.
  ##
  ## THIS IS THE LIVE CASE ON THE HEXAGON, not a corner case: every hex
  ## endzone is a disc whose radius is ~10% of the board width, and its
  ## apron is protected too, so the 200px annulus around a standard-class
  ## pedestal is mostly ground no generator may build on. The reading is
  ## still printed on every map — it is how a future structure pass will
  ## know whether it has bought any approach cover — but ranking on it
  ## today would rank on the endzone draw.
  var maxProtected = 0.0
  for stand in metrics.stands:
    maxProtected = max(maxProtected, stand.protectedFrac)
  if standSkip.len == 0 and maxProtected > 0.80:
    standSkip = &"{maxProtected * 100:.0f}% of the 200px annulus is " &
      "protected floor — the endzone radius decides this, not the terrain"
  ## The FLOOR is anchored on the control, the ceiling stays absolute.
  ##
  ## The MW2 study's 10% floor was measured on annuli that were buildable
  ## end to end. On the hexagon 62% of this one is the endzone disc and its
  ## apron, so a map can only ever spend the remaining 38% here, and 10% of
  ## the whole ring is a materially harsher bar than the same number was on
  ## the board the study ran on. The re-derived cover band moved the arena to
  ## 9.1% and the absolute floor promptly flagged the CONTROL — which by this
  ## harness's first rule means the bound, not the arena, is what is wrong.
  ##
  ## Anchoring rather than skipping keeps the band SCORED: a map that leaves
  ## its pedestal barer than the arena's still loses points for it, which is
  ## the conversion signal the study actually found. The ceiling is untouched
  ## because "too much cover at the stand" is not a bound the control is
  ## anywhere near.
  let standCoverLo = min(0.10, control.standCoverMin)
  add("stand cover (min)", metrics.standCoverMin, standCoverLo, 0.25, 0.10,
    2.0, "pct", controlRelative = true, skipReason = standSkip,
    note = "wall fraction within 200px of the least-covered pedestal")
  add("stand cover (max)", metrics.standCoverMax, standCoverLo, 0.25, 0.10,
    1.0, "pct", controlRelative = true, skipReason = standSkip)
  ## Complementary: open AT the stand, cover in the approach annulus. The
  ## flag sits on the pedestal whatever the endzone shape, so the ring is
  ## the ground an attacker must contest to steal even where it is not where
  ## they score.
  ##
  ## ON THE HEXAGON THIS BAND FLAGGED THE CONTROL, at 100% against a 90%
  ## ceiling — and so did every generated map, at exactly 100%. That is the
  ## metric's fault, not the arena's. `StandRingPad` is 30px and
  ## `EndzoneApron` is 60px, so the sampled ring lies wholly INSIDE the
  ## apron: protected floor, where no generator may build, on every
  ## disc-endzone map that exists. The reading is arithmetic, not
  ## architecture. It is measured and printed with its protected fraction
  ## beside it, and scored only where terrain could have changed it —
  ## the same treatment, for the same reason, as stand-side cover.
  add("stand ring open (min)", metrics.standRingMin, 0.70, 0.90, 0.15, 1.5,
    "pct", note = "openness of the ring an attacker must contest",
    skipReason =
      if metrics.standRingProtectedMax > 0.80:
        &"{metrics.standRingProtectedMax * 100:.0f}% of the ring is " &
          "protected floor — the endzone apron decides this, not the terrain"
      else: "")
  ## Fairness of the objective is a rule on every map, column or compact.
  add("stand ring delta", metrics.standRingDelta, 0.0, 0.25, 0.15, 1.5,
    "pct", loOpen = true,
    note = "objective fairness: the stands must be equally defensible")
  ## TTK is 1.0-1.9s at 66px/s, so the distance you can be caught crossing
  ## before you die is 66-125px. This is a DISTANCE TO COVER, which is what
  ## the distance transform measures directly. An earlier version doubled it
  ## into a free-space diameter and promptly failed the control at 224px.
  add("P95 distance to cover", metrics.p95ClearancePx, 0.0, 125.0, 60.0,
    1.5, "px", loOpen = true,
    note = "P95 of the distance transform over walkable cells")
  ## Three-lane doctrine, made computable. No upper bound: an open field
  ## has dozens of disjoint routes and that is not a defect.
  add("vertex-disjoint routes", metrics.minRoutes.float, 3.0, 0.0, 2.0,
    2.0, "n", hiOpen = true,
    note = "unit-capacity max flow, worst base pair")
  var crossings = high(int)
  for crossing in metrics.crossings:
    crossings = min(crossings, crossing.count)
  if crossings == high(int): crossings = 0
  add("midfield crossings", crossings.float, 3.0, 0.0, 2.0, 1.5, "n",
    hiOpen = true,
    note = "distinct ways across the most divided midfield line")
  ## The architecture-vs-scatter discriminator. The control is honest
  ## scatter by design, so it is the FLOOR: a band with a fixed lower bound
  ## above it would flag the control.
  add("interior fraction", metrics.interiorFrac, control.interiorFrac, 0.0,
    0.15, 2.0, "pct", hiOpen = true, controlRelative = true,
    note = "floor with >= 6 of 8 directions blocked within 120px")
  ## Cover budget, anchored on the control rather than on the brief's
  ## 18-30%: the shipped generator bands 4-17%, the control measures ~10%,
  ## and a fixed 18% floor would flag it. Widen deliberately, not by
  ## accident.
  add("wall coverage", metrics.wallFrac,
    max(0.0, control.wallFrac - 0.06), control.wallFrac + 0.14, 0.06, 1.0,
    "pct", controlRelative = true,
    note = "interior wall pixels; the brief's 18-30% would flag the control")
  ## Where the fight will happen must have at least as much cover as the
  ## map average; the documented failure is a collision point in the open.
  ##
  ## THE ABSOLUTE 1.00x BOUND FLAGGED THE CONTROL on the hexagon, at 0.57x.
  ## Again the metric, not the arena: on a two-team hex board the
  ## equidistant frontier IS the centre, and the centre carries the always-
  ## open flag ring — protected floor by rule, so structurally barer than
  ## the map average on every hex map ever generated. The rule it encodes
  ## ("do not stage the fight in a cover-free area") is still right, so it
  ## is kept ALIVE and anchored on the control rather than dropped: a
  ## candidate has to stage its fight in at least as much cover as the
  ## layout the engine was tuned on. That still discriminates — the
  ## measured spread across seeds is 0.3x to 0.9x.
  let coverRatio =
    if metrics.collision.mapCoverFrac > 0:
      metrics.collision.coverFrac / metrics.collision.mapCoverFrac
    else:
      0.0
  let controlCoverRatio =
    if control.collision.mapCoverFrac > 0:
      control.collision.coverFrac / control.collision.mapCoverFrac
    else:
      1.0
  add("collision-point cover", coverRatio, controlCoverRatio, 0.0, 0.4, 1.5,
    "x", hiOpen = true, controlRelative = true,
    note = "cover density at the equidistant frontier vs the map average")
  ## Gallery shots: measured against the control, not an absolute.
  add("long sightline share", metrics.longSightFrac, 0.0,
    max(0.02, control.longSightFrac * 1.5), 0.10, 1.0, "pct",
    loOpen = true, controlRelative = true,
    note = &"share of open runs over {LongSightPx}px")
  ## One-sided: a straight run between bases is not obviously worse than a
  ## slightly bent one, but a labyrinth is.
  add("detour ratio", metrics.detourMean, 0.0, 1.6, 0.4, 1.0, "x",
    loOpen = true,
    note = "walked base-to-base distance / straight line")
  ## "No more than half your shapes should be plain rectangles."
  add("rect shape share", metrics.rectShapeFrac, 0.0, 0.5, 0.25, 0.5,
    "pct", loOpen = true)

  var total, weight = 0.0
  for check in checks:
    if not check.scored:
      continue
    total += check.weight * check.bandScore()
    weight += check.weight
  ScoreCard(checks: checks, score: total / max(weight, 1e-9))

# ---------------------------------------------------------------- ranker ----

proc controlMetrics*(): MapMetrics =
  ## The CONTROL: the hand-authored default arena, measured on the same
  ## rubric as every candidate. Three bands are anchored on it (interior
  ## fraction, wall coverage, long-sightline share) precisely so a
  ## threshold can never drift away from the layout the engine was tuned on.
  ##
  ## Computed FRESH per ranking call rather than memoized in a module
  ## global. Memoizing would save ~1 candidate's worth of work per
  ## `generateCtfMap` and would cost the one property that makes the whole
  ## measurement stack safe to call from the map editor's mummy thread
  ## pool: that it touches no shared mutable state. It also keeps the
  ## control honest under the flat-top orientation work in flight — the
  ## control is whatever `arenaCtfMap()` is today, never a pinned number
  ## somebody has to remember to refresh.
  computeMapMetrics(arenaCtfMap(), withChokepoints = false)

proc scoreCandidate*(gameMap: CtfMap, control: MapMetrics): float {.gcsafe.} =
  ## One candidate's static score against a pre-measured control.
  ## Chokepoints are skipped (no band reads them, and they are the one
  ## expensive stage) and so is re-validation: the ranking loop only ever
  ## scores maps `validateGeneratedMap` has already passed.
  scoreMap(
    computeMapMetrics(gameMap, withChokepoints = false, withValidation = false),
    control
  ).score

proc rankCtfMapCandidates*(candidates: openArray[CtfMap]): int
    {.nimcall, gcsafe.} =
  ## `arena.mapCandidateRanker`'s implementation: the index of the
  ## best-scoring candidate. Ties keep the EARLIEST candidate, so a K that
  ## finds nothing to prefer degrades exactly to the old first-valid
  ## behaviour rather than to an arbitrary one.
  if candidates.len <= 1:
    return 0
  let control = controlMetrics()
  var best = 0
  var bestScore = -1.0
  for i, candidate in candidates:
    let score = candidate.scoreCandidate(control)
    if score > bestScore:
      bestScore = score
      best = i
  best

installMapCandidateRanker(rankCtfMapCandidates)
