## The size-class table and the per-regime / per-team-count rule sets
## (`src/ctf/map_rules.nim`). Two jobs:
##
## 1. Pin the CANONICAL TABLE, because two tools used to carry their own copies
##    of the class widths and both hard-failed on any width they had not been
##    told about. Every derived width is checked against the value that
##    actually shipped, so deriving them cannot silently move a class.
## 2. Pin the DERIVATIONS. The point of `map_rules` is that nobody types a
##    design number in; the guard that keeps it that way is checking the
##    formulas against independently-known facts — the hand-tuned cover band
##    that has shipped since GV25, `hex.nim`'s own spacing functions, and the
##    physical constants in `sim_types`.

import
  std/[math, strutils, unittest],
  ctf/[hex, map_rules, sim]

suite "the canonical size-class table":
  test "the drawable list is exactly the historical seed contract":
    # arena.MapSizeNames IS this sequence and the generator indexes it with
    # one rng draw, so its length and order re-deal every seed's size.
    check DrawableSizeNames == @["small", "standard", "large", "huge", "giant"]
    check not MapSizeClassTable[mszColossal].drawable
    for c in MapSizeClass:
      check (MapSizeClassTable[c].drawable) == (c != mszColossal)

  test "derived shell widths reproduce every width that ever shipped":
    # These are the literals tools/gen_map_pool.nim and
    # tools/build_pool_review.py used to carry. If the derivation moves, a
    # curated pool seed silently changes class.
    const RectShipped = [
      (mszSmall, 1050, 560), (mszStandard, 1235, 659), (mszLarge, 1606, 857),
      (mszHuge, 2223, 1186), (mszGiant, 3211, 1713), (mszColossal, 6422, 3427)]
    for (c, w, h) in RectShipped:
      check c.boardDims(boardRect2).width == w
      check c.boardDims(boardRect2).height == h
    const SquareShipped = [
      (mszSmall, 816), (mszStandard, 960), (mszLarge, 1248),
      (mszHuge, 1728), (mszGiant, 2496), (mszColossal, 4992)]
    for (c, side) in SquareShipped:
      check c.boardDims(boardSquare4).width == side
      check c.boardDims(boardSquare4).height == side

  test "the hex class table is the same six classes in the same order":
    for c in MapSizeClass:
      let hexClass = HexSizeClass(ord(c))
      check HexClassNames[hexClass] == c.sizeName()
      check HexClassScale[hexClass] == c.sizeScale()
      check c.boardDims(boardHex).width == HexSizes[hexClass].width
      check c.boardDims(boardHex).height == HexSizes[hexClass].height

  test "a width names its class on every family, and unknown widths say so":
    for family in BoardFamily:
      for c in MapSizeClass:
        check sizeClassOfWidth(c.boardDims(family).width, family) == ord(c)
    check sizeClassOfWidth(1234, boardRect2) == -1
    check sizeClassOfWidth(999999) == -1
    check knownWidths().find("colossal=6422") >= 0

  test "no shell width collides across the three families":
    # arena.mapSizeClass resolves a class from the width alone, without being
    # told which family it is holding. That is only sound while this holds.
    var widths: seq[int]
    for family in BoardFamily:
      for c in MapSizeClass:
        let w = c.boardDims(family).width
        check w notin widths
        widths.add w
    check widths.len == 3 * (ord(MapSizeClass.high) + 1)

  test "the border constant agrees with arena's":
    # map_rules cannot import arena (arena imports IT), so this is the guard
    # that keeps the duplicated constant honest.
    check BorderPx == ArenaBorder

  test "generated maps resolve to the right class through the table":
    for size in DrawableSizeNames:
      let gameMap = generateMapAttempt(
        4242, MapGenOverrides(size: size, windows: -1, pits: -1,
                              pitDensity: -1))
      check gameMap.mapSizeClassName() == size
      check gameMap.width == sizeClassOf(size).boardDims(boardRect2).width
    let colossal = generateMapAttempt(
      4242, MapGenOverrides(size: "colossal", windows: -1, pits: -1,
                            pitDensity: -1))
    check colossal.mapSizeClassName() == "colossal"

  test "an unknown width raises with the known widths, not a bare failure":
    var bogus = generateMapAttempt(
      4242, MapGenOverrides(windows: -1, pits: -1, pitDensity: -1))
    bogus.width = 1234
    expect CtfError:
      discard bogus.mapSizeClass()

suite "the visibility regimes":
  test "the cone area is the sector the fog actually applies":
    check VisionRangePx == GunRange * 3 div 2
    check VisionRangePx == 1575
    let sector = degToRad(float(2 * VisionConeDeg)) / 2.0 *
      float(VisionRangePx) * float(VisionRangePx)
    check abs(float(ConeAreaPx) - sector) < 1.0
    check ConeAreaPx == 2597704

  test "cone coverage spans 4.4 whole maps down to 12% of one":
    let small = mszSmall.coneCoverage(boardRect2)
    let colossal = mszColossal.coneCoverage(boardRect2)
    check abs(small - 4.418) < 0.01
    check abs(colossal - 0.118) < 0.01
    # Monotone: a bigger class is always harder to see across.
    for c in mszSmall ..< mszColossal:
      check c.coneCoverage(boardRect2) >
        MapSizeClass(ord(c) + 1).coneCoverage(boardRect2)

  test "all three board families agree on every class's regime":
    const Expected = [
      vrOcclusion, vrOcclusion, vrOcclusion, vrMixed, vrMixed, vrRange]
    for c in MapSizeClass:
      for family in BoardFamily:
        check c.regimeOf(family) == Expected[ord(c)]

  test "the regime cuts sit clear of every observed coverage":
    # The cuts are the geometric midpoints of the two gaps in the data; this
    # asserts nothing lands near one, so a rounding change cannot flip a class.
    for c in MapSizeClass:
      for family in BoardFamily:
        let coverage = c.coneCoverage(family)
        check abs(coverage - RegimeOcclusionMin) > 0.2
        check abs(coverage - RegimeRangeMax) > 0.1

suite "tactical lengths are regime-invariant; counts are not":
  test "every length set by the gun, the clock and the body is one number":
    # This is the whole thesis: GunRange, MaxSpeed, FireCooldownTicks and
    # HitPoints are fixed, so the lengths they imply cannot depend on the
    # board. Only counts and densities may.
    for c in MapSizeClass:
      let r = mapRules(c, 2)
      check r.maxExposedRunPx == MaxExposedRunPx
      check r.wallSpanPx == WallSpanPx
      check r.chokepointSpacingPx == GunRange
      check r.minPickupSpacingPx == GunRange
      check r.gunRangePx == GunRange
      check r.visionRangePx == VisionRangePx

  test "the exposed-run budget is derived, not typed":
    check ShotsToKill == HitPoints * 100 div FieldAccuracyPct
    check TicksToKill == (ShotsToKill - 1) * FireCooldownTicks
    check MaxExposedRunPx == TicksToKill * MaxSpeed div MotionScale
    check MaxExposedRunPx == 132
    check WallSpanPx == 2 * MaxExposedRunPx

  test "the strafe window is one shot's acceptance corridor":
    check StrafeWindowPx == 2 * (PlayerHalf + int(BulletHalfWidth))
    # ...and it is a move a player can make between an enemy's shots.
    check StrafeWindowPx * MotionScale div MaxSpeed < FireCooldownTicks

suite "the cover budget derivation":
  test "it reproduces the hand-tuned band that has shipped since GV25":
    # The strongest evidence the mean-free-sightline law is the right model:
    # nobody derived CoverPermilleMin/Max, they were tuned by hand, and the
    # law lands on both within a few permille from first principles.
    let r = mapRules(mszStandard, 2)
    check abs(r.coverPermilleMin - CoverPermilleMin) <= 3
    check abs(r.coverPermilleMax - CoverPermilleMax) <= 3
    check r.meanFreeSightlineMaxPx == GunRange
    check r.meanFreeSightlineMinPx == GunRange div 4

  test "the range regime INVERTS the sightline band":
    # On a board where a cone sees 12%, short sightlines are the disease, not
    # the cure: rays must run at least a gun range so contact happens at all.
    let
      occlusion = mapRules(mszStandard, 2)
      rangeLimited = mapRules(mszColossal, 2)
    check rangeLimited.meanFreeSightlineMinPx == GunRange
    check rangeLimited.meanFreeSightlineMaxPx == VisionRangePx
    check rangeLimited.meanFreeSightlineMinPx > occlusion.meanFreeSightlineMinPx
    # ...so it carries LESS cover to hide behind, not more.
    check rangeLimited.coverPermilleMax < occlusion.coverPermilleMax

  test "cover size scales as sqrt(class scale), between the two wrong answers":
    for c in MapSizeClass:
      let r = mapRules(c, 2)
      check r.coverSizePx ==
        int(round(float(BaseCoverSizePx) * sqrt(c.sizeScale())))
      # It always hides a drawn body, and never outgrows its own band.
      check r.coverSizePx >= SoldierBodyPx
    check mapRules(mszStandard, 2).coverSizePx == BaseCoverSizePx
    # Holding size fixed needs 711 pieces on colossal; scaling it linearly
    # needs 291 px boulders. sqrt keeps the piece count growing as sqrt(area).
    check mapRules(mszColossal, 2).coverSizePx == 128
    let
      standardPieces = mapRules(mszStandard, 2).coverPieces
      colossalPieces = mapRules(mszColossal, 2).coverPieces
    check colossalPieces < 8 * standardPieces
    check colossalPieces > standardPieces

suite "routes: lanes, chokepoints, open runs":
  test "lane count rises through the mixed regime and COLLAPSES on colossal":
    # The funnel. Lanes are the minimum of "how many fit" and "how many still
    # deliver contact"; packing binds on the small classes and contact binds
    # hard on colossal, where the answer is fewer lanes than would fit.
    let lanes = block:
      var acc: seq[int]
      for c in MapSizeClass:
        acc.add mapRules(c, 2).laneCount
      acc
    check lanes == @[3, 3, 4, 5, 6, 3]

  test "a lane always passes two abreast with dodge room":
    for teams in [2, 4]:
      for c in MapSizeClass:
        let r = mapRules(c, teams)
        check r.laneWidthPx >= 2 * SoldierBodyPx + 2 * StrafeWindowPx
        check r.laneWidthPx >= RecommendedCorridorWidthPx
        check r.laneCount >= 3
        check r.lanePitchPx == r.laneWidthPx + r.coverSizePx

  test "the max open run ramps from the gun range to the vision range":
    check mapRules(mszStandard, 2).maxOpenRunPx == GunRange
    check mapRules(mszColossal, 2).maxOpenRunPx == VisionRangePx
    check mapRules(mszGiant, 2).maxOpenRunPx ==
      (GunRange + VisionRangePx) div 2

  test "chokepoints per route follow the traverse, not the class factor":
    var counts: seq[int]
    for c in MapSizeClass:
      counts.add mapRules(c, 2).chokepointsPerRoute
    check counts == @[1, 1, 2, 2, 3, 6]

suite "trenches, pickups and the hub":
  test "the trench share rises as the regime opens up":
    # A trench is the only cover that costs no sightline (TrenchMissPct = 70,
    # walkable, transparent), so it is what carries survivability on a board
    # that must stay open to make contact.
    check mapRules(mszStandard, 2).trenchSharePermille <
      mapRules(mszGiant, 2).trenchSharePermille
    check mapRules(mszGiant, 2).trenchSharePermille <
      mapRules(mszColossal, 2).trenchSharePermille

  test "the standard class's trench budget matches what the generator digs":
    # arena's density-mode roll rates (17/25/50 percent by candidate class)
    # produce roughly nine digs on the standard board.
    let r = mapRules(mszStandard, 2)
    check r.trenchCount >= 7
    check r.trenchCount <= 12

  test "colossal's trench budget does not fit the mapPits cap":
    # A finding, pinned so it cannot be forgotten: mapPits is capped at 64 and
    # the derived colossal budget is well past it. Raising the cap (or the
    # trench SIZE) is the structure pass's problem, but it is a real one.
    check mapRules(mszColossal, 2).trenchCount > 64

  test "pickup count is a whole symmetry orbit and grows only when it must":
    for teams in [2, 3, 4, 6]:
      let orbit = max(2, teams)
      for c in MapSizeClass:
        let r = mapRules(c, teams)
        check r.pickupCount mod orbit == 0
        check r.pickupCount >= orbit
    # Everything up to giant needs exactly one orbit; colossal needs three.
    check mapRules(mszGiant, 2).pickupCount == 2
    check mapRules(mszColossal, 2).pickupCount == 6

  test "today's generated med-kit pair sits inside one gun range":
    # The generator draws y1 in [16%, 34%] of the height and places the pair
    # at (y1, H-1-y1), so the pair is 0.32H..0.68H apart — 211..448 px on the
    # standard board, well inside MinPickupSpacingPx. One camper covers both.
    let h = mszStandard.boardDims(boardRect2).height
    check h * 68 div 100 < MinPickupSpacingPx

  test "the hub is never wider than one engagement":
    for teams in [2, 3, 4, 6]:
      for c in MapSizeClass:
        let r = mapRules(c, teams)
        check r.hubRadiusPx <= GunRange div 2
        check 2 * r.hubRadiusPx <= GunRange
    # The range regime pins it AT the cap: the hub is the encounter device.
    check mapRules(mszColossal, 2).hubRadiusPx == GunRange div 2
    check mapRules(mszStandard, 2).hubRadiusPx < GunRange div 2

  test "today's flag ring is far under the derived hub floor":
    # scaledGenShell ships flagRing = round(70 * scale): 70 px on the standard
    # board against a derived floor of 215 for a 16-seat house. A hub fight
    # there is body-blocked.
    check mapRules(mszStandard, 2).hubRadiusPx > 3 * 70

suite "team-count rule sets":
  test "board families: 3 and 6 have no rectangular option at all":
    check familyForTeams(2) == boardRect2
    check familyForTeams(4) == boardSquare4
    check familyForTeams(3) == boardHex
    check familyForTeams(6) == boardHex
    expect ValueError:
      discard familyForTeams(5)
    # ...because the rect shell's aspect is nowhere near the band a 120-degree
    # rotation admits.
    check not hexBoard(1235, 659).aspectOk()
    for c in MapSizeClass:
      let (w, h) = c.boardDims(boardHex)
      check hexBoard(w, h).aspectOk()

  test "seat plans deal evenly and fit the roster":
    check 15 in seatPlans(3)
    check 18 in seatPlans(3)
    check 16 notin seatPlans(3)      ## 16 mod 3 = 1 deals 6/5/5
    check not seatsFit(16, 3)
    check seatsFit(15, 3)
    check seatPlans(6) == @[24, 30]
    check not seatsFit(48, 6)        ## 6ffa8 does not fit MaxPlayers = 32
    check 48 > MaxPlayers
    check seatsFit(16, 2)
    check seatsFit(16, 4)
    for teams in [2, 3, 4, 6]:
      for plan in seatPlans(teams):
        check plan mod teams == 0
        check plan <= MaxPlayers
        check plan div teams >= MinSeatsPerTeam
    check nearestSeatPlan(2) == 16
    check nearestSeatPlan(3) == 15
    check nearestSeatPlan(4) == 16
    check nearestSeatPlan(6) == 24

  test "the symmetry groups are hex.nim's, and only 4 teams get a mirror":
    check symmetryGroupName(2) == "C2"
    check symmetryGroupName(3) == "C3"
    check symmetryGroupName(4) == "V4"
    check symmetryGroupName(6) == "C6"
    check mirroredTeams(2) == 0
    check mirroredTeams(3) == 0
    check mirroredTeams(6) == 0
    # C4 is not a subgroup of D6, so 4 teams take the Klein four-group and
    # two of them see a MIRROR world. Confirmed against hex.nim directly.
    check mirroredTeams(4) == 2
    var mirrors = 0
    for op in teamGroup(4):
      if not op.isRotation():
        inc mirrors
    check mirrors == 2

  test "no rule-set field is handed, so a mirrored team gets the same map":
    # Every field the table emits is a count, a length or a density —
    # quantities a reflection preserves. The structural guard: the four V4
    # images of a spawn seed are distinct (the group acts freely), so the four
    # teams differ only by which image they hold, never by their rule set.
    let seed = spawnSeed(4, 6)
    check seed.actsFreely(teamGroup(4))
    check spawnCells(4, 6).len == 4
    let rules = mapRules(mszStandard, 4)
    for teamIndex in 0 ..< 4:
      # There is no per-team accessor to differ: one rule set serves all four.
      check mapRules(mszStandard, 4) == rules

  test "6 teams ship on the giant class only":
    # Adjacent bases ride a 0.75R ring, so their separation is 2*f*R*sin(pi/N)
    # — at N = 6 that collapses to exactly f*R, the worst case of any N.
    check abs(minCircumradiusForTeams(6) - SixTeamMinCircumradius) < 1.0
    check supportedSizeNames(6) == @["giant", "colossal"]
    for c in MapSizeClass:
      let
        (w, h) = c.boardDims(boardHex)
        board = hexBoard(w, h)
        r = mapRules(c, 6)
      check r.supported == board.supportsSixTeams()
      check r.supported == (board.adjacentBaseSeparation(6) >= float(GunRange))
      if not r.supported:
        check r.unsupportedReason.len > 0
        check r.baseSeparationPx < GunRange
      else:
        check r.baseSeparationPx >= GunRange
    check mapRules(mszHuge, 6).baseSeparationPx == 755
    check mapRules(mszGiant, 6).baseSeparationPx >= GunRange

  test "3 teams cannot ship below huge either — same criterion, milder":
    # Not in the brief; it falls out of the same formula. At N = 3 the
    # separation is 1.299 * R, so the floor is a 808 px circumradius.
    check supportedSizeNames(3) == @["huge", "giant", "colossal"]
    check mapRules(mszLarge, 3).baseSeparationPx < GunRange
    check mapRules(mszHuge, 3).baseSeparationPx >= GunRange

  test "2 teams are exempt from the adjacent-base rule, and shipping proves it":
    # The standard rect board's two homes are 935 px apart — inside one gun
    # range — and it has always played fine, because there is exactly one
    # enemy and terrain is authored between them. The gate is FFA-only.
    for c in MapSizeClass:
      check mapRules(c, 2).supported
    let gameMap = generateMapAttempt(
      1000, MapGenOverrides(size: "standard", windows: -1, pits: -1,
                            pitDensity: -1))
    check gameMap.teamHomeX(Blue) - gameMap.teamHomeX(Red) < GunRange

suite "the two open decisions":
  test "the grenade is pinned to the gun and can never out-range it (GV38)":
    # It USED to be MapWidth div 5, which scaled with the board while GunRange
    # has been fixed at 1050 since GV34 — so on colossal the grenade nominally
    # out-ranged the gun (6422 div 5 = 1284 px). GV38 pinned it to
    # GunRange div 4 = 262 px, the same number on every class. This test was
    # written to fire the day that landed; it now guards the inversion staying
    # closed on EVERY class, team count and board family, colossal included.
    check mapRules(mszColossal, 2).boardWidth div 5 == 1284  # the old value...
    check 1284 > GunRange                                    # ...i.e. a defect
    for c in MapSizeClass:
      for teamCount in 2 .. 4:
        for family in BoardFamily:
          let r = mapRules(c, teamCount, family)
          check r.grenadeMaxRangeTodayPx == GrenadeRangeFromGunPx
          check r.grenadeMaxRangeRecommendedPx == GrenadeRangeFromGunPx
          check r.grenadeMaxRangeTodayPx < r.gunRangePx
          check not r.grenadeOutRangesGun
    # No board dimension is left in the derivation: the smallest and the
    # largest shell report the identical reach even though their widths differ
    # 6.1x, where the old formula spanned 210 px to 1284 px.
    check mapRules(mszSmall, 2).grenadeMaxRangeTodayPx ==
      mapRules(mszColossal, 2).grenadeMaxRangeTodayPx
    # The rules module and the sim agree, and the shipped value reproduces the
    # standard board's historical 247 px within 6%.
    check GrenadeRangeFromGunPx == GunRange div 4
    check GrenadeRangeFromGunPx == GrenadeMaxRange
    check abs(GrenadeRangeFromGunPx - 1235 div 5) * 100 div (1235 div 5) < 7

  test "the corridor minimum is recommended, not raised, in this task":
    # 26 px clears the 13 px SOLID footprint but not the 34 px drawn body.
    # The measured churn of moving to 68 is in the design doc; the column
    # generator physically cannot serve it (slot period 88-120 around 56-60 px
    # obstacles leaves no adjacent gap over 64 px), so the raise belongs to the
    # structure pass.
    check MinCorridorWidth == 26
    check MinCorridorWidth > 2 * PlayerHalf
    check MinCorridorWidth < SoldierBodyPx
    check RecommendedCorridorWidthPx == 2 * SoldierBodyPx
    check RecommendedCorridorWidthPx == 68
    for c in MapSizeClass:
      check mapRules(c, 2).minCorridorWidthPx == RecommendedCorridorWidthPx
    # The scale bridge that makes published level-design metrics usable here:
    # SoldierBodyPx = 34 against Source's 32-unit player is 1.06 px/unit, under
    # which TF2's 1024-unit medium-range cap lands within 4% of GunRange.
    check abs(1024 * SoldierBodyPx div 32 - GunRange) * 100 div GunRange <= 4
