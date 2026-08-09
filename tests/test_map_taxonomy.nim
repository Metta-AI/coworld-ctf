## Pins `map_taxonomy`'s descriptive labels: the CUT-POINTS and the DECISION
## ORDER, both calibrated against docs/evidence/staticscore-play-rows-windowed.json.
##
## Pure — no map generation. The classifier is a pure function of already-computed
## `MapMetrics`/`MapRules` fields, so the test constructs those fields directly at
## the values the evidence file actually holds. If a threshold drifts away from
## the data that justified it, one of these checks moves.

import
  std/unittest,
  ctf/[map_metrics, map_rules, map_taxonomy]

proc metrics(chokeCount = 4, routeCountMin = 3, longRunFrac = 0.08,
             visDegreeCv = 0.37, coverPermille = 160): MapMetrics =
  ## A standard-class map at the evidence medians, with the four playtype
  ## coordinates overridable. Every other field stays zero — the classifier
  ## reads only these five.
  result.chokeCount = chokeCount
  result.routeCountMin = routeCountMin
  result.longRunFrac = longRunFrac
  result.visDegreeCv = visDegreeCv
  result.coverPermille = coverPermille

let stdRules = mapRules(mszStandard, 2)   ## coverPermilleMax = 168

suite "playtypeLabel — calibrated against the evidence quartiles":

  test "siege: chokeCount at/above the top-quartile shelf (>=8)":
    check playtypeLabel(metrics(chokeCount = 8), stdRules) == "siege"
    check playtypeLabel(metrics(chokeCount = 15), stdRules) == "siege"
    # just under the shelf is NOT siege
    check playtypeLabel(metrics(chokeCount = 7, routeCountMin = 3),
      stdRules) != "siege"

  test "overwatch: long lanes (longRunFrac>=0.093) on thin cover (<=0.9*max)":
    # cover 139 <= 0.9*168 = 151.2, lanes 0.148 -> overwatch (evidence: s1003)
    check playtypeLabel(
      metrics(chokeCount = 0, longRunFrac = 0.148, coverPermille = 139),
      stdRules) == "overwatch"
    # same lanes but ample cover -> NOT overwatch
    check playtypeLabel(
      metrics(chokeCount = 0, longRunFrac = 0.148, coverPermille = 168,
        routeCountMin = 3, visDegreeCv = 0.30),
      stdRules) != "overwatch"

  test "rush: open and direct — chokeCount<=1 and routeCountMin<=2":
    check playtypeLabel(
      metrics(chokeCount = 1, routeCountMin = 2, longRunFrac = 0.055,
        visDegreeCv = 0.385, coverPermille = 157),
      stdRules) == "rush"

  test "skirmish: many routes (>=4) OR uneven exposure (visCv>=0.394)":
    check playtypeLabel(
      metrics(chokeCount = 0, routeCountMin = 4, visDegreeCv = 0.35),
      stdRules) == "skirmish"
    check playtypeLabel(
      metrics(chokeCount = 0, routeCountMin = 2, visDegreeCv = 0.42),
      stdRules) == "skirmish"

  test "control: the residual three-lane middle":
    # 3 routes, medium choke, medium exposure, ample cover, short lanes
    check playtypeLabel(
      metrics(chokeCount = 3, routeCountMin = 3, longRunFrac = 0.08,
        visDegreeCv = 0.34, coverPermille = 164),
      stdRules) == "control"

  test "decision order: siege out-ranks skirmish on a many-route maze":
    # 9 chokes AND 3 routes: pinch dominates -> siege, not skirmish
    check playtypeLabel(metrics(chokeCount = 9, routeCountMin = 3),
      stdRules) == "siege"

  test "cover normalisation is per size class, not a raw permille":
    # small-class coverMax is lower, so the same permille is 'thinner' there.
    let smallRules = mapRules(mszSmall, 2)   ## coverPermilleMax = 156
    # cover 139 vs small-max 156: 139 <= 0.9*156=140.4 -> still thin -> overwatch
    check playtypeLabel(
      metrics(chokeCount = 0, longRunFrac = 0.10, coverPermille = 139),
      smallRules) == "overwatch"

suite "pacingTier — ratios against the tuned contact clock":

  test "fast below 0.8x, methodical above 1.3x, standard between":
    let t = TunedContactTicks
    check pacingTier(0.5 * t, t) == "fast"
    check pacingTier(0.79 * t, t) == "fast"
    check pacingTier(0.9 * t, t) == "standard"
    check pacingTier(1.0 * t, t) == "standard"
    check pacingTier(1.3 * t, t) == "standard"      # boundary is inclusive-standard
    check pacingTier(1.31 * t, t) == "methodical"
    check pacingTier(2.0 * t, t) == "methodical"

  test "degenerate tuned clock does not divide by zero":
    check pacingTier(10.0, 0.0) == "standard"

  test "the pool's two size classes fall either side of tuned":
    # small board is denser than tuned -> fast; standard board is the tuned
    # board itself -> standard. (Pinned by the catalog run.)
    check pacingTier(metrics(), mapRules(mszSmall, 2)) == "fast"
    check pacingTier(metrics(), mapRules(mszStandard, 2)) == "standard"
