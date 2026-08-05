## The map-generator PARAMETER TABLE: the canonical size-class list, the
## visibility regime each class falls into, and the derived structural targets
## (cover, lanes, chokepoints, obstacle size, trenches, pickups, hub) that the
## structure pass consumes. Also the per-team-count rule set: which symmetry
## group, which board family, which classes a team count may ship on, and
## which seat totals deal evenly.
##
## Full derivation: `docs/plans/2026-08-05-map-size-class-rules.md`. Every
## number below is COMPUTED from the physical constants in `sim_types` — none
## is typed in. Read the doc before changing a formula; changing a formula
## changes what the structure pass builds.
##
## ---------------------------------------------------------------------------
## WHY REGIMES, NOT A SCALE FACTOR
## ---------------------------------------------------------------------------
##
## `arena.nim`'s `scaledGenShell` says it outright: "Obstacle SIZES never
## scale." A colossal board is therefore the standard map photocopied at 520%
## — the same 56 px pebbles, 27x as many of them, spread over 27x the ground.
##
## The reason one parameter set cannot serve every class is that `GunRange` has
## been FIXED at 1050 px since GV34 while board area spans 37x. Measure that
## with one number: `coneCoverage`, the fraction of the playfield one
## unoccluded vision cone covers (`VisionConeDeg` = 60 deg half-angle,
## `visionRange` = 1.5 * GunRange = 1575 px, so the cone is a 120 deg sector of
## area `pi * 1575^2 / 3` = 2,597,704 px^2):
##
##   class      playfield px^2   coneCoverage   regime
##   small             588,000         4.418    occlusion-limited
##   standard          813,865         3.192    occlusion-limited
##   large           1,376,342         1.887    occlusion-limited
##   huge            2,636,478         0.985    mixed
##   giant           5,500,443         0.472    mixed
##   colossal       22,008,194         0.118    range/navigation-limited
##
## On small/standard/large ONE stance sees 1.9-4.4 whole maps: nothing is out
## of reach and nothing is undiscoverable, so SIGHTLINE CONTROL is the entire
## design and encounter density takes care of itself. On colossal a stance sees
## 12%: sightline control barely matters and ENCOUNTER DENSITY is the design
## problem, so the map must funnel players toward contact rather than give them
## cover to hide behind. The regime cuts sit at the geometric midpoints of the
## two gaps in the data above (sqrt(1.887 * 0.985) = 1.363, and
## sqrt(0.472 * 0.118) = 0.236), rounded to 1.4 and 0.25.
##
## ---------------------------------------------------------------------------
## WHAT SCALES AND WHAT DOES NOT — THE RESULT
## ---------------------------------------------------------------------------
##
## The single most useful finding: because gun range, player speed, fire rate
## and hit points are all FIXED, every TACTICAL LENGTH is regime-invariant and
## only COUNTS and DENSITIES move. `maxExposedRunPx`, `wallSpanPx`,
## `chokepointSpacingPx` and `minPickupSpacingPx` are the same pixel value on
## every class; `laneCount`, `chokepointsPerRoute`, `pickupCount`,
## `trenchCount` and the cover band are what a size class actually changes.
##
## The one exception is `coverSizePx`, which scales as `sqrt(class scale)` —
## the geometric mean between today's "never scale" and a photocopy's "scale
## linearly". See the doc for why both endpoints are wrong.
##
## PURITY. This module reads only COMPILE-TIME CONSTANTS from `sim_types`. It
## must never read the mutable installed-map globals (`MapWidth`, `MapHeight`,
## `GrenadeMaxRange`, ...): those are per-process install state, and a rules
## table that depended on them could not describe a class other than the one
## currently loaded. `hex` is imported for the hex board table only.

import std/[math, strutils]
import sim_types
import hex

# ---------------------------------------------------------------------------
# Constants this module must agree with, and cannot import
# ---------------------------------------------------------------------------

const
  BorderPx* = 10
    ## Must equal `arena.ArenaBorder` (the perimeter wall thickness). `arena`
    ## imports THIS module, so the dependency cannot point the other way;
    ## `tests/test_map_rules.nim` pins the two together, the same guard
    ## `tests/test_burrow.nim` uses for `MinCorridorWidth`.

  RectBaseWidth* = 1235
  RectBaseHeight* = 659
    ## The 2-team shell's standard-class dimensions (`arena.scaledGenShell`).
  SquareBaseSide* = 960
    ## The 4-team square shell's standard-class side (`arena.scaledGenShell4`).

# ---------------------------------------------------------------------------
# Size classes — the ONE canonical table
# ---------------------------------------------------------------------------

type
  MapSizeClass* = enum
    ## Every field-scale class the generator knows. The order is a CONTRACT:
    ## `arena.MapSizeNames` is this list filtered to the drawable classes, in
    ## this order, and widening it re-deals which size each seed draws.
    ## `hex.HexSizeClass` is the same six in the same order.
    mszSmall, mszStandard, mszLarge, mszHuge, mszGiant, mszColossal

  MapSizeClassSpec* = object
    name*: string
    scale*: float
    drawable*: bool
      ## Whether a random size draw may pick this class. `colossal` is
      ## override-only and has never been in the draw list.

  BoardFamily* = enum
    ## Which shell geometry a team count is played on.
    boardRect2      ## 1235 x 659 scaled — the shipping 2-team board.
    boardSquare4    ## 960 x 960 scaled — the shipping 4-team rot90 board.
    boardHex        ## `hex.HexSizes` — the only family that admits 3 or 6
                    ## teams, because a 120 deg rotation confines the bounding
                    ## box aspect to [0.866, 1.155] and 1235/659 = 1.874.

  VisibilityRegime* = enum
    vrOcclusion     ## coneCoverage >= 1.4 — one stance sees the whole map.
    vrMixed         ## 0.25 .. 1.4
    vrRange         ## coneCoverage <= 0.25 — you must walk to find anyone.

const
  MapSizeClassTable*: array[MapSizeClass, MapSizeClassSpec] = [
    MapSizeClassSpec(name: "small",    scale: 0.85, drawable: true),
    MapSizeClassSpec(name: "standard", scale: 1.0,  drawable: true),
    MapSizeClassSpec(name: "large",    scale: 1.3,  drawable: true),
    MapSizeClassSpec(name: "huge",     scale: 1.8,  drawable: true),
    MapSizeClassSpec(name: "giant",    scale: 2.6,  drawable: true),
    MapSizeClassSpec(name: "colossal", scale: 5.2,  drawable: false),
  ]
    ## THE source of truth for size classes. `arena.mapSizeScale`,
    ## `arena.MapSizeNames`, `hex.HexClassScale`, `tools/gen_map_pool.nim` and
    ## `tools/build_pool_review.py` all derive from this — none of them may
    ## carry its own width literals again. Adding a row here is all it takes
    ## to ship a new class.

func buildDrawableNames(): seq[string] =
  for c in MapSizeClass:
    if MapSizeClassTable[c].drawable:
      result.add MapSizeClassTable[c].name

const DrawableSizeNames* = buildDrawableNames()
  ## The classes a random draw may pick, in enum order. `arena.MapSizeNames`
  ## IS this sequence; the generator indexes it with one RNG draw, so its
  ## length and order are part of the seed contract.

func findSizeClass*(name: string): int =
  ## The class index for a size name, or -1. Non-raising so callers can
  ## produce their own error type (`arena` raises `CtfError`).
  for c in MapSizeClass:
    if MapSizeClassTable[c].name == name:
      return ord(c)
  -1

func sizeClassOf*(name: string): MapSizeClass =
  let i = findSizeClass(name)
  if i < 0:
    raise newException(ValueError, "Unknown map size: " & name)
  MapSizeClass(i)

func sizeScale*(c: MapSizeClass): float {.inline.} =
  MapSizeClassTable[c].scale

func sizeName*(c: MapSizeClass): string {.inline.} =
  MapSizeClassTable[c].name

func scaled*(c: MapSizeClass, value: int): int {.inline.} =
  ## The class's own rounding rule, identical to `arena.scaledGenShell`'s
  ## local `s()`. Every derived dimension goes through this so a class's
  ## numbers agree everywhere to the pixel.
  int(round(float(value) * MapSizeClassTable[c].scale))

func boardDims*(c: MapSizeClass, family: BoardFamily):
    tuple[width, height: int] =
  ## The shell dimensions for one class on one board family. DERIVED, never
  ## tabled: this is what replaces the width literals that made a new size
  ## class unshippable.
  case family
  of boardRect2: (c.scaled(RectBaseWidth), c.scaled(RectBaseHeight))
  of boardSquare4: (c.scaled(SquareBaseSide), c.scaled(SquareBaseSide))
  of boardHex: (HexSizes[HexSizeClass(ord(c))].width,
                HexSizes[HexSizeClass(ord(c))].height)

func playfieldPx*(c: MapSizeClass, family: BoardFamily): int =
  ## Playable area in px^2. A hexagon encloses only 75% of its bounding box,
  ## so `width * height` would overstate it by a third — `hex.hexArea` is the
  ## comparable number and is what the regime classification must use.
  let (w, h) = c.boardDims(family)
  case family
  of boardRect2, boardSquare4: w * h
  of boardHex: int(hexBoard(w, h).hexArea())

func sizeClassOfWidth*(width: int, family: BoardFamily): int =
  ## The class index whose shell is this wide on this family, or -1. Derived
  ## from `boardDims`, so it answers for any class in the table — including
  ## one added tomorrow. This is what `tools/gen_map_pool.nim` used to do with
  ## a `case` over five width literals that RAISED on anything else.
  for c in MapSizeClass:
    if c.boardDims(family).width == width:
      return ord(c)
  -1

func sizeClassOfWidth*(width: int): int =
  ## Family-agnostic form: the first family whose shell matches. The rect and
  ## square shells never collide (1235 * s vs 960 * s share no rounded width
  ## across the table — pinned by test).
  for family in BoardFamily:
    let i = sizeClassOfWidth(width, family)
    if i >= 0:
      return i
  -1

func knownWidths*(): string =
  ## Every shell width the table can produce, for error messages — so an
  ## unknown width reports what IS known instead of just failing.
  var parts: seq[string]
  for family in BoardFamily:
    for c in MapSizeClass:
      parts.add MapSizeClassTable[c].name & "=" & $c.boardDims(family).width
  parts.join(" ")

const MapSelectionK*: array[MapSizeClass, int] = [
  mszSmall: 12,
  mszStandard: 8,
  mszLarge: 6,
  mszHuge: 4,
  mszGiant: 2,
  mszColossal: 1,
]
  ## How many VALID candidates `arena.generateCtfMap` ranks before shipping the
  ## best one. E[max of K] is K/(K+1) of the generator's own quality range, so
  ## K=4 buys the 80th percentile, K=8 the 89th and K=12 the 92nd. The returns
  ## are logarithmic and the cost is exactly linear, which is why nothing here
  ## is 32 — measured over 40 seeds, K=1 -> K=8 moves the mean `staticScore`
  ## 0.834 -> 0.898 and the WORST map 0.636 -> 0.804, and K=8 -> K=16 is worth
  ## another ~0.01.
  ##
  ## The table is per CLASS because the cost is per class and spans an order of
  ## magnitude. Selection pays generate + validate + `map_metrics.evaluateMap`
  ## per candidate, and `evaluateMap` dominates above `standard` (isovists and
  ## the visibility graph grow with board area). Measured per candidate,
  ## release build, 2-team:
  ##   small 50 ms · standard 132 ms · large 151 ms · huge 301 ms ·
  ##   giant 648 ms
  ## The K column is chosen to hold the cost of ONE generated map near a
  ## second at every size — 0.6 s small, 1.1 s standard, 0.9 s large, 1.2 s
  ## huge, 1.3 s giant — rather than to hold K constant and let a giant board
  ## cost forty times a small one.
  ##
  ## `colossal` is 1: it is override-only, it is 22 M pixels, and one
  ## `evaluateMap` there costs more than a whole standard-board selection.
  ##
  ## Selection is deterministic given the seed, so this table is part of the
  ## seed -> map contract: changing a row re-deals every seed of that class.
  ## Replays are unaffected — they pin `mapSpec`, which never re-runs the
  ## generator (see `arena.resolveCtfMapMetadata`).

func selectionK*(c: MapSizeClass): int {.inline.} =
  MapSelectionK[c]

# ---------------------------------------------------------------------------
# Derived physical quantities (all from sim_types constants)
# ---------------------------------------------------------------------------

const
  VisionRangePx* = GunRange * 3 div 2
    ## `sim.visionRange` — 1.5x the gun range since GV34.
  ConeAreaPx* = int(degToRad(float(2 * VisionConeDeg)) / 2.0 *
                    float(VisionRangePx) * float(VisionRangePx))
    ## Area of one unoccluded vision cone: a `2 * VisionConeDeg` sector of
    ## radius `visionRange`. 2,597,704 px^2 at stock settings.

  SpeedPxPerTickNum* = MaxSpeed
  SpeedPxPerTickDen* = MotionScale
    ## 704/256 = 2.75 px/tick = 66 px/s. A colossal board is 6422 px across:
    ## ONE crossing is 97 seconds, about a whole game.

  FieldAccuracyPct* = 55
    ## Measured field hit rate (GV26-GV36 scout re-simulations sit at 48-61%).
    ## The nominal figure is 80% for a fully visible body at MAX range
    ## (`AimJitterCentralZ`), but exposure is what sets the survivable-run
    ## budget and real exposure is partial, so the FIELD number is the honest
    ## input. Halving it doubles `maxExposedRunPx`; it is the one soft input
    ## in this module and it is isolated here on purpose.

  ShotsToKill* = HitPoints * 100 div FieldAccuracyPct        ## 5 shots
  TicksToKill* = (ShotsToKill - 1) * FireCooldownTicks       ## 48 ticks
  MaxExposedRunPx* = TicksToKill * SpeedPxPerTickNum div SpeedPxPerTickDen
    ## 132 px — how far a player travels in the time a shooter needs to kill
    ## them. Cover must never be further apart than this along a route, or the
    ## route is not survivable. REGIME-INVARIANT: every input is fixed.

  BaseCoverSizePx* = 56
    ## The STANDARD class's cover-piece width. The generator's discs and
    ## diamonds carry radius 28, so a piece is 56 px across — the same number
    ## as `TrenchSize`, and not a coincidence: both are "one piece of terrain".
    ##
    ## It is also almost exactly the derived floor. A defender at depth `c`
    ## behind cover of width `W`, hidden from a shooter at distance `d` who is
    ## free to slide `S` sideways during the exchange, needs
    ## `W >= (34*d + S*c) / (d + c)`. At the occlusion regime's own engagement
    ## distance (`d` = the band midpoint, ~300 px), one body of depth
    ## (`c` = 34) and a slide of one kill's worth of travel
    ## (`S` = MaxExposedRunPx), that is `W >= 47 px`. The hand-tuned 56 clears
    ## it by 19%; a 34 px piece (one body) would NOT.

  StrafeWindowPx* = 2 * (PlayerHalf + int(BulletHalfWidth))
    ## 28 px. A shot's acceptance corridor is +-(PlayerHalf + BulletHalfWidth)
    ## = +-14 px, so 28 px of lateral displacement turns a locked-in hit into
    ## a miss. At 2.75 px/tick that takes 10.2 ticks — inside the 12-tick
    ## `FireCooldownTicks`, so it is a move a player can actually make between
    ## an enemy's shots. This is the dodge room a lane must carry beyond the
    ## bodies in it.

  WallSpanPx* = 2 * MaxExposedRunPx
    ## 264 px — the shortest STRUCTURAL wall (a lane separator, as opposed to
    ## a cover pebble). Rounding one end of a wall of span S costs S/2 of extra
    ## travel; for the separation to be worth anything that detour must cost
    ## more than a kill takes, so S/2 >= MaxExposedRunPx. Today's generator
    ## emits nothing longer than a 60 px stub, so it builds ZERO structural
    ## walls on any class.

  ChokepointSpacingPx* = GunRange
    ## Two chokepoints are tactically distinct exactly when a defender holding
    ## one cannot shoot into the other. REGIME-INVARIANT; the COUNT per route
    ## is what a size class changes.

  MinPickupSpacingPx* = GunRange
    ## Two pickups closer than a gun range are one pickup: a single camper
    ## covers both. (Today's generator places its med-kit pair 211-448 px
    ## apart on the standard board — inside one gun range. See the doc.)

  HubRadiusCapPx* = GunRange div 2
    ## 525 px. A hub wider than this is two engagements, not one: players on
    ## opposite rims cannot reach each other.

  RecommendedCorridorWidthPx* = 2 * SoldierBodyPx
    ## 68 px — two DRAWN cog bodies abreast. `arena.MinCorridorWidth` is 26 px
    ## today, which clears the 13 px solid footprint (`PlayerHalf` = 6) but not
    ## the 34 px silhouette, so two cogs in a minimum corridor overlap on
    ## screen. Source's published minimum hallway is 64 units and the standard
    ## rule is "at least double the player width"; matching `SoldierBodyPx` =
    ## 34 to Source's 32-unit player gives 1 unit ~= 1.06 px, under which TF2's
    ## 1024-unit medium-range cap = 1088 px lands within 4% of our 1050 px
    ## `GunRange`. The correspondence is close enough that published metrics
    ## transfer. NOT SHIPPED — see the doc for the measured pool churn.

  GrenadeRangeFromGunPx* = GunRange div 4
    ## 262 px — the grenade range this module RECOMMENDS. `GrenadeMaxRange` is
    ## `MapWidth div 5` today and therefore scales with the board while
    ## `GunRange` does not, so on colossal the grenade nominally OUT-RANGES the
    ## gun (1284 px vs 1050 px). A quarter of the gun's reach reproduces the
    ## standard board's historical 247 px within 6% and cannot invert again.
    ## NOT SHIPPED: it is a sim-behaviour change and needs a GameVersion bump.

# ---------------------------------------------------------------------------
# Regime classification
# ---------------------------------------------------------------------------

const
  RegimeOcclusionMin* = 1.4
  RegimeRangeMax* = 0.25
    ## Geometric midpoints of the two gaps in the coneCoverage data, rounded.
    ## Every board family agrees on the classification at these cuts (the
    ## square shell is the tightest case and still clears both) — pinned by
    ## test.

func coneCoverage*(c: MapSizeClass, family: BoardFamily): float {.inline.} =
  ## How many whole playfields one unoccluded vision cone covers.
  float(ConeAreaPx) / float(c.playfieldPx(family))

func regimeOf*(coverage: float): VisibilityRegime {.inline.} =
  if coverage >= RegimeOcclusionMin: vrOcclusion
  elif coverage <= RegimeRangeMax: vrRange
  else: vrMixed

func regimeOf*(c: MapSizeClass, family: BoardFamily): VisibilityRegime =
  regimeOf(c.coneCoverage(family))

func sightlineBand*(regime: VisibilityRegime): tuple[lo, hi: int] =
  ## The regime's target band for the MEAN FREE SIGHTLINE — the average
  ## distance a random ray travels before an obstacle stops it. This is the
  ## one design quantity from which the cover budget follows.
  ##
  ## - occlusion: `[GunRange/4, GunRange]`. The ceiling is "no average ray
  ##   crosses a full gun range unbroken", which is what makes a map where
  ##   everything is in range of everything survivable at all. The floor is
  ##   "an average ray still gets a quarter of a gun range", below which the
  ##   gun's reach is wasted and the map is a maze.
  ## - range: `[GunRange, visionRange]`. INVERTED, and deliberately: on a
  ##   board where a cone sees 12%, breaking sightlines is how you make a map
  ##   nobody can find anyone on. Rays must run at least a gun range so
  ##   contact happens, and at most a vision range so no lane is dead ground
  ##   you cross blind.
  ## - mixed: `[GunRange/2, visionRange]`, spanning both.
  case regime
  of vrOcclusion: (GunRange div 4, GunRange)
  of vrMixed: (GunRange div 2, VisionRangePx)
  of vrRange: (GunRange, VisionRangePx)

func trenchSharePermille*(regime: VisibilityRegime): int =
  ## Share of a map's total cover delivered as TRENCHES rather than walls.
  ##
  ## A trench (`TrenchSize` = 56 px, walkable, `TrenchMissPct` = 70) gives
  ## survivability WITHOUT shortening a sightline — it is the only cover that
  ## is free in the range regime, where short sightlines are the disease.
  ## Walls deliver protection in proportion to how often a ray meets one, i.e.
  ## inversely to the mean free sightline, so the share trenches must carry
  ## rises with that band's midpoint. Anchored at 250 permille for the
  ## occlusion regime, which is what the generator's own density-mode roll
  ## rates (17/25/50 percent by candidate class) already produce.
  case regime
  of vrOcclusion: 250
  of vrMixed: 400
  of vrRange: 500

# ---------------------------------------------------------------------------
# Team counts
# ---------------------------------------------------------------------------

const
  MinSeatsPerTeam* = 4
    ## Below four a team cannot cover the CTF role split (carrier, escort,
    ## defender, flex) and stops being a team. It is also what makes
    ## `seatPlans(6)` come out as exactly {24, 30} — the only 6-team totals
    ## that both deal evenly and fit `MaxPlayers` = 32.
  SeatPlanMin* = 12
    ## Below a dozen seats a board of any size plays empty; the shipping
    ## 2-team config seats 16.
  DefaultSeats* = 16
    ## The shipping roster (`config.json` seats 16, 8 per team). The rule set
    ## sizes lanes and the hub for the seat plan NEAREST this, not for a full
    ## 32-player house — sizing for the cap would double every lane width for
    ## a roster nobody runs.

func familyForTeams*(teamCount: int): BoardFamily =
  ## The board family a team count is played on. 3 and 6 have no rectangular
  ## option at all: any group transitive on 3 or 6 spawns contains a 120 deg
  ## rotation, which confines the bounding-box aspect to
  ## `[HexAspectMin, HexAspectMax]` = [0.866, 1.155], and the rect shell's
  ## 1235/659 = 1.874 is far outside it (`hex.nim`, plan section 0.3).
  case teamCount
  of 2: boardRect2
  of 4: boardSquare4
  of 3, 6: boardHex
  else:
    raise newException(ValueError, "Unsupported team count: " & $teamCount)

func seatPlans*(teamCount: int): seq[int] =
  ## Every seat TOTAL that deals evenly across `teamCount` teams, seats at
  ## least `MinSeatsPerTeam` each, and fits `MaxPlayers`.
  ##
  ## This is the check that catches the classic mistakes by construction: 16
  ## seats on 3 teams deals 6/5/5 (16 mod 3 = 1), and a 6-team 8-per-side
  ## roster is 48 seats, which does not fit MaxPlayers = 32 at all.
  doAssert teamCount > 0
  var n = max(SeatPlanMin, teamCount * MinSeatsPerTeam)
  n = ((n + teamCount - 1) div teamCount) * teamCount
  while n <= MaxPlayers:
    result.add n
    n += teamCount

func nearestSeatPlan*(teamCount: int): int =
  ## The legal seat total closest to the shipping roster — what a rule set
  ## sizes its lanes and hub for. 2 teams -> 16, 3 -> 15, 4 -> 16, 6 -> 24.
  let plans = seatPlans(teamCount)
  if plans.len == 0:
    return teamCount * MinSeatsPerTeam
  result = plans[0]
  for plan in plans:
    if abs(plan - DefaultSeats) < abs(result - DefaultSeats):
      result = plan

func seatsFit*(total, teamCount: int): bool {.inline.} =
  ## Whether a seat total deals evenly and fits the roster cap.
  teamCount > 0 and total > 0 and total mod teamCount == 0 and
    total <= MaxPlayers and total div teamCount >= MinSeatsPerTeam

func symmetryGroupName*(teamCount: int): string =
  ## The `hex.nim` subgroup this team count deploys.
  for entry in HexSubgroups:
    if entry.teams == teamCount:
      return entry.name
  "?"

func mirroredTeams*(teamCount: int): int =
  ## How many of the teams see a MIRROR IMAGE of the world rather than a
  ## rotation of it. Nonzero ONLY at 4: the hexagonal point group D6 has no
  ## order-4 rotation (crystallographic restriction), so 4 teams use the Klein
  ## four-group V4, two of whose elements are reflections. Every learned route
  ## is left-right flipped for those two teams.
  ##
  ## THIS IS WHY NO FIELD IN `MapRules` MAY BE HANDED. Everything the table
  ## emits is a count, a length or a density — quantities a mirror preserves.
  ## A "lanes favour the left flank" style parameter would silently hand two
  ## of four teams a different map.
  ##
  ## This answers for the HEX layout groups. The rect family independently
  ## draws `symMirror` half the time, under which each of the two teams sees
  ## the other's world reflected — the same handedness cost, symmetric between
  ## them, and the same reason the table stays unhanded.
  var mirrors = 0
  for op in teamGroup(teamCount):
    if not op.isRotation():
      inc mirrors
  mirrors

func minCircumradiusForTeams*(teamCount: int): float =
  ## The smallest hex circumradius at which two ANGULARLY ADJACENT bases sit
  ## at least one gun range apart. Bases ride a ring at
  ## `SixTeamBaseFraction` = 0.75 of the circumradius, so the adjacent
  ## separation is `2 * f * R * sin(pi / N)` — which at N = 6 collapses to
  ## exactly `f * R`, the worst case of any team count.
  ##
  ## FFA-specific, and `mapRules` only GATES on it at `teamCount >= 3`: with
  ## no shared front line every team is adjacent to two others, and a player
  ## who cannot leave the pad without standing in a neighbour's gun range is
  ## not playing. Two-team CTF tolerates less (the shipping standard board's
  ## two homes are 935 px apart, inside a gun range, and it plays fine)
  ## because there is exactly one enemy and terrain is authored between them.
  if teamCount < 2: return 0.0
  float(GunRange) / (2.0 * SixTeamBaseFraction * sin(PI / float(teamCount)))

# ---------------------------------------------------------------------------
# The rule set
# ---------------------------------------------------------------------------

type
  MapRules* = object
    ## Everything the structure pass needs for one (size class, team count).
    ## Resolve with `mapRules`; never reconstruct a field by hand.
    ##
    ## NO FIELD IS HANDED. See `mirroredTeams`.

    # --- identity -----------------------------------------------------------
    sizeClass*: MapSizeClass
    sizeName*: string
    scale*: float
    teamCount*: int
    family*: BoardFamily
    boardWidth*, boardHeight*: int
    playfieldPx*: int
    crossSectionPx*: int
      ## Playable extent ACROSS the attack axis — how much room there is to
      ## put lanes side by side.
    traversePx*: int
      ## Playable extent ALONG the attack axis: base to opposing base.
    coneCoverage*: float
    regime*: VisibilityRegime

    # --- supported? ---------------------------------------------------------
    supported*: bool
    unsupportedReason*: string
      ## Empty when `supported`. A rule set is still fully populated when
      ## unsupported, so tooling can show WHY a combination is refused.

    # --- cover --------------------------------------------------------------
    coverSizePx*: int
      ## Characteristic width of one cover piece (a disc's diameter).
    wallSpanPx*: int
      ## Shortest structural lane separator.
    meanFreeSightlineMinPx*, meanFreeSightlineMaxPx*: int
    coverPermilleMin*, coverPermilleMax*: int
      ## The cover budget that DELIVERS that sightline band on this class.
    coverPieces*: int
      ## Roughly how many cover pieces the mid-band budget buys, full board.

    # --- routes -------------------------------------------------------------
    laneCount*: int
    laneWidthPx*: int
    lanePitchPx*: int
    chokepointSpacingPx*: int
    chokepointsPerRoute*: int
    maxOpenRunPx*: int
      ## Longest straight unobstructed run the class permits.
    maxExposedRunPx*: int
      ## Longest stretch of a route that may lack cover.
    minCorridorWidthPx*: int

    # --- trenches, pickups, hub ---------------------------------------------
    trenchSharePermille*: int
    trenchPermille*: int
    trenchSizePx*: int
    trenchCount*: int
    pickupCount*: int
    minPickupSpacingPx*: int
    hubRadiusPx*: int

    # --- team layout --------------------------------------------------------
    symmetryGroup*: string
    mirroredTeams*: int
    seatPlans*: seq[int]
    seats*: int
      ## The seat plan this rule set sizes lanes and the hub for: the largest
      ## plan that fits, i.e. a full house.
    baseSeparationPx*: int
      ## Distance between angularly adjacent bases, 0 on the rect family
      ## (which has exactly one opposing base and authors terrain between).

    # --- ranges, for the downstream pass and the open decisions -------------
    gunRangePx*: int
    visionRangePx*: int
    grenadeMaxRangeTodayPx*: int
      ## What the sim computes today: `MapWidth div 5`.
    grenadeMaxRangeRecommendedPx*: int
      ## `GunRange div 4`. Differs from the above on every class; the
      ## SIGN of the difference is what matters — see `grenadeOutRangesGun`.
    grenadeOutRangesGun*: bool
      ## True when today's grenade range exceeds the gun range on this class.

func maxOpenRunFor(regime: VisibilityRegime): int =
  ## The longest straight unobstructed run a class permits, ramped linearly
  ## between two derived endpoints: `GunRange` in the occlusion regime (a run
  ## longer than the gun makes a position nobody can answer) and
  ## `visionRange` in the range regime (a run you can see the end of makes
  ## contact; a longer one is dead ground you cross blind).
  case regime
  of vrOcclusion: GunRange
  of vrMixed: (GunRange + VisionRangePx) div 2
  of vrRange: VisionRangePx

func coverModulus(coverSizePx: int): float {.inline.} =
  ## `A / P` for one cover piece — the only shape property the mean-free-path
  ## law needs. For a disc of diameter W that is `r / 2 = W / 4`.
  ##
  ## The law (2D, Cauchy): a random line meets convex bodies of number density
  ## `n` and mean perimeter `P` at rate `n * P / pi`, so with area fraction
  ## `phi = n * A` the MEAN FREE SIGHTLINE is `lambda = pi * (A/P) / phi`.
  ##
  ## Inverted, `phi = pi * (A/P) / lambda` — which is where the cover budget
  ## comes from. The check that this is not numerology: at the standard class
  ## (W = 56, A/P = 14) the occlusion band's endpoints come out at 42 and 168
  ## permille, and the hand-tuned `CoverPermilleMin`/`Max` that have shipped
  ## since GV25 are 40 and 170. The legacy floor IS "no average ray crosses a
  ## gun range" and the legacy ceiling IS "every average ray gets a quarter of
  ## one", to within 5% and 1% — nobody wrote that down, but that is what was
  ## tuned.
  float(coverSizePx) / 4.0

const ContactReferencePx* = mszHuge.playfieldPx(boardRect2)
  ## The playfield at the occlusion/mixed boundary (coneCoverage ~= 1.0). It
  ## is the reference the lane count's contact ceiling is measured against:
  ## "confine players to a route network of this area and the board keeps the
  ## contact rate of the last class that still played like one map."

func mapRules*(c: MapSizeClass, teamCount: int,
               family: BoardFamily): MapRules =
  ## The rule set for one size class, team count and board family. This is the
  ## entry point the structure pass calls; everything else in this module is
  ## its working.
  let fam = family
  result.sizeClass = c
  result.sizeName = c.sizeName()
  result.scale = c.sizeScale()
  result.teamCount = teamCount
  result.family = fam
  let (bw, bh) = c.boardDims(fam)
  result.boardWidth = bw
  result.boardHeight = bh
  result.playfieldPx = c.playfieldPx(fam)
  result.coneCoverage = c.coneCoverage(fam)
  result.regime = regimeOf(result.coneCoverage)

  # Attack-axis geometry. The rect and square shells are traversed along
  # their width; on a hexagon the bases ride a 0.75R ring, so an opposed pair
  # is 1.5R apart through the center.
  case fam
  of boardRect2:
    result.crossSectionPx = bh - 2 * BorderPx
    result.traversePx = bw - 2 * BorderPx
  of boardSquare4:
    result.crossSectionPx = bh - 2 * BorderPx
    result.traversePx = bw - 2 * BorderPx
  of boardHex:
    let board = hexBoard(bw, bh)
    result.crossSectionPx = int(2.0 * board.apothem()) - 2 * BorderPx
    result.traversePx =
      int(2.0 * SixTeamBaseFraction * board.circumradius())

  # --- cover ---------------------------------------------------------------
  #
  # Obstacle size scales as sqrt(class scale). Both endpoints of the argument
  # are wrong: hold size FIXED (today) and colossal needs 711 pieces to reach
  # its cover budget, a spec no client wants and a field of pebbles nobody can
  # navigate by; scale size LINEARLY and a colossal piece is 291 px, whose
  # mean free sightline blows past the vision range and leaves the board
  # blind. The geometric mean holds the piece count growing as sqrt(area)
  # (35 -> 137 across a 27x area span) and keeps every class inside its own
  # sightline band.
  result.coverSizePx =
    int(round(float(BaseCoverSizePx) * sqrt(c.sizeScale())))
  result.wallSpanPx = WallSpanPx
  let
    band = sightlineBand(result.regime)
    modulus = coverModulus(result.coverSizePx)
  result.meanFreeSightlineMinPx = band.lo
  result.meanFreeSightlineMaxPx = band.hi
  result.coverPermilleMin = int(round(PI * modulus / float(band.hi) * 1000.0))
  result.coverPermilleMax = int(round(PI * modulus / float(band.lo) * 1000.0))
  let midPermille = (result.coverPermilleMin + result.coverPermilleMax) div 2
  result.coverPieces = int(round(
    float(midPermille) / 1000.0 * float(result.playfieldPx) /
      (PI * float(result.coverSizePx) * float(result.coverSizePx) / 4.0)))

  # --- routes --------------------------------------------------------------
  #
  # Lane count is the MINIMUM of two ceilings, both floored:
  #   pack    — how many lanes physically fit across, at a nominal two-abreast
  #             lane plus one cover piece of separation.
  #   contact — how many lanes still deliver the encounter rate of the regime
  #             boundary. Contact rate falls as 1/area with everything else
  #             fixed, so a board keeps the boundary class's contact only if
  #             players are confined to a route network of area
  #             `A_ref = huge`. With lanes of the nominal width running the
  #             full traverse, that is `A_ref / (laneWidth * traverse)`.
  # Below three there is no route CHOICE, so three is the floor.
  #
  # The regime falls out rather than being asserted: pack binds on
  # small/standard/large (lanes are limited by how many fit), the two cross
  # over in the mixed regime, and contact binds hard on colossal — where the
  # answer is FEWER lanes than would fit, which is the funnel the range
  # regime needs.
  const NominalLanePx = 2 * SoldierBodyPx + 2 * StrafeWindowPx  ## 124
  let
    packLimit = float(result.crossSectionPx) /
      float(NominalLanePx + result.coverSizePx)
    contactLimit = float(ContactReferencePx) /
      float(NominalLanePx * max(1, result.traversePx))
  result.laneCount = max(3, int(floor(min(packLimit, contactLimit))))

  result.seatPlans = seatPlans(teamCount)
  result.seats = nearestSeatPlan(teamCount)
  let perTeam = max(1, result.seats div teamCount)
  # Lane width follows TRAFFIC: a team's players spread over its lanes, each
  # needing a body plus dodge room on both sides of the file.
  # ...but never below two abreast with dodge room on both sides: a lane one
  # body wide is a corridor, and a route network of corridors has no
  # overtaking, no escorting and no trading.
  result.laneWidthPx = max(NominalLanePx,
    ((perTeam + result.laneCount - 1) div result.laneCount) * SoldierBodyPx +
      2 * StrafeWindowPx)
  result.lanePitchPx = result.laneWidthPx + result.coverSizePx
  result.chokepointSpacingPx = ChokepointSpacingPx
  result.chokepointsPerRoute =
    max(1, (result.traversePx + ChokepointSpacingPx div 2) div
      ChokepointSpacingPx)
  result.maxOpenRunPx = maxOpenRunFor(result.regime)
  result.maxExposedRunPx = MaxExposedRunPx
  result.minCorridorWidthPx = RecommendedCorridorWidthPx

  # --- trenches ------------------------------------------------------------
  result.trenchSharePermille = trenchSharePermille(result.regime)
  let share = result.trenchSharePermille
  result.trenchPermille = midPermille * share div max(1, 1000 - share)
  result.trenchSizePx = result.coverSizePx
  result.trenchCount = int(round(
    float(result.trenchPermille) / 1000.0 * float(result.playfieldPx) /
      float(result.trenchSizePx * result.trenchSizePx)))

  # --- pickups -------------------------------------------------------------
  #
  # For k pickups spread over area A the mean distance to the nearest is
  # `0.5 * sqrt(A/k)`. Budget one gun range of detour for a kit — beyond that
  # the trip costs more than the fight it was meant to survive — so
  # `k >= A / (2 * GunRange)^2`. Rounded UP to a multiple of the symmetry
  # order, because a pickup set that is not a whole orbit is not team-fair.
  let
    orbit = max(2, teamCount)
    rawPickups = float(result.playfieldPx) /
      float(4 * GunRange * GunRange)
  result.pickupCount =
    max(orbit, ((int(ceil(rawPickups)) + orbit - 1) div orbit) * orbit)
  result.minPickupSpacingPx = MinPickupSpacingPx

  # --- hub -----------------------------------------------------------------
  #
  # Floor: a hub fight of `seats` players needs room for each to hold a strafe
  # disc of radius `SoldierBodyPx/2 + StrafeWindowPx`, at a realistic 70%
  # packing — `R >= rho * sqrt(seats / 0.7)`.
  # Ceiling: `GunRange/2`, past which the hub is two engagements.
  # The range regime pins the hub AT the ceiling: on a board where a cone sees
  # 12%, the hub is the encounter-manufacturing device and should be as large
  # as one engagement allows. The occlusion regime needs no such device — the
  # whole map is already one engagement — so it takes the floor.
  let
    rho = float(SoldierBodyPx) / 2.0 + float(StrafeWindowPx)
    occupancy = int(round(rho * sqrt(float(result.seats) / 0.7)))
  result.hubRadiusPx =
    case result.regime
    of vrOcclusion: min(occupancy, HubRadiusCapPx)
    of vrMixed: min(max(occupancy, HubRadiusCapPx div 2), HubRadiusCapPx)
    of vrRange: HubRadiusCapPx

  # --- team layout ---------------------------------------------------------
  result.symmetryGroup = symmetryGroupName(teamCount)
  result.mirroredTeams = mirroredTeams(teamCount)
  if fam == boardHex:
    let board = hexBoard(bw, bh)
    result.baseSeparationPx =
      int(round(board.adjacentBaseSeparation(teamCount)))

  # --- ranges --------------------------------------------------------------
  result.gunRangePx = GunRange
  result.visionRangePx = VisionRangePx
  result.grenadeMaxRangeTodayPx = bw div 5
  result.grenadeMaxRangeRecommendedPx = GrenadeRangeFromGunPx
  result.grenadeOutRangesGun = result.grenadeMaxRangeTodayPx > GunRange

  # --- support -------------------------------------------------------------
  result.supported = true
  if fam == boardHex:
    let board = hexBoard(bw, bh)
    if not board.aspectOk():
      result.supported = false
      result.unsupportedReason =
        "board aspect " & $result.boardWidth & "x" & $result.boardHeight &
          " is outside the 120-degree-rotation band [" &
          $HexAspectMin & ", " & $HexAspectMax & "]"
    elif teamCount >= 3 and
        board.circumradius() < minCircumradiusForTeams(teamCount):
      result.supported = false
      result.unsupportedReason =
        $teamCount & " teams need circumradius >= " &
          $int(round(minCircumradiusForTeams(teamCount))) & "; " &
          result.sizeName & " has " & $int(round(board.circumradius())) &
          " (adjacent bases would sit " & $result.baseSeparationPx &
          " px apart, inside one " & $GunRange & " px gun range)"
  if result.seatPlans.len == 0:
    result.supported = false
    result.unsupportedReason =
      "no seat total fits " & $teamCount & " teams under MaxPlayers = " &
        $MaxPlayers

func mapRules*(c: MapSizeClass, teamCount: int): MapRules {.inline.} =
  ## The rule set on the board family this team count actually ships on.
  mapRules(c, teamCount, familyForTeams(teamCount))

func mapRules*(sizeName: string, teamCount: int): MapRules {.inline.} =
  ## THE call the downstream structure pass makes.
  mapRules(sizeClassOf(sizeName), teamCount)

func supportedSizeNames*(teamCount: int): seq[string] =
  ## The size classes this team count may ship on. 6 teams answers "giant and
  ## colossal" and nothing else — the adjacent-base separation on anything
  ## smaller is inside a gun range.
  for c in MapSizeClass:
    if mapRules(c, teamCount).supported:
      result.add c.sizeName()
