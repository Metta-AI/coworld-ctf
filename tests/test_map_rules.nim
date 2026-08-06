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
      check r.chokepointSpacingPx == LethalEnvelopePx
      check r.minPickupSpacingPx == LethalEnvelopePx
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

  test "the separator thins on a small board and never below legibility":
    # A separator's thickness is a DENSITY, not a tactical length: the network
    # costs `(laneCount + 1) * thick * halfTraverse * duty` out of a
    # `crossSection * halfTraverse` domain, so the traverse cancels and its
    # share of the board is set by the CROSS-SECTION alone. Held constant at
    # the engine's free-space minimum it took the small class over the cover
    # ceiling on structure ALONE — 132 permille of the half-domain against 113
    # on standard, with no attempt in 100 landing under the 170 ceiling.
    check mapRules(mszSmall, 2).laneSeparatorThickPx < BaseSeparatorThickPx
    # ...but every class the budget was never tight on is left EXACTLY alone.
    for c in [mszStandard, mszLarge, mszHuge, mszGiant, mszColossal]:
      check mapRules(c, 2).laneSeparatorThickPx == BaseSeparatorThickPx
    # The floor is LEGIBILITY, not physics — a 13 px footprint moving
    # 2.75 px/tick cannot cross a wall of any positive thickness, and
    # `lineOfSightClear` samples one pixel at a time, so no shot tunnels one.
    for teams in [2, 4]:
      for c in MapSizeClass:
        let t = mapRules(c, teams).laneSeparatorThickPx
        check t >= MinSeparatorThickPx
        check t <= BaseSeparatorThickPx

  test "the max open run ramps from the gun range to the vision range":
    check mapRules(mszStandard, 2).maxOpenRunPx == GunRange
    check mapRules(mszColossal, 2).maxOpenRunPx == VisionRangePx
    check mapRules(mszGiant, 2).maxOpenRunPx ==
      (GunRange + VisionRangePx) div 2

  test "chokepoints per route follow the traverse, not the class factor":
    var counts: seq[int]
    for c in MapSizeClass:
      counts.add mapRules(c, 2).chokepointsPerRoute
    # ~4x what they were: spacing moved from GunRange (a REACH) to
    # LethalEnvelopePx (where a defender can actually kill into the next one).
    check counts == @[4, 5, 6, 9, 12, 25]

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
    # The pair can be as close as 0.32H = 211 px, inside the 259 px envelope,
    # so a single camper genuinely covers both on the tight end of the draw.
    check h * 32 div 100 < MinPickupSpacingPx

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

suite "population fit: board area as a function of roster":
  test "the law is anchored on the one tuned configuration":
    check TunedPlayfieldPx == 1235 * 659
    check TunedPlayfieldPx == 813865
    check TunedOpponents == 8
    check PxPerOpponent == TunedPlayfieldPx div TunedOpponents
    check PxPerOpponent == 101733
    # ...and it reproduces that configuration: 2 x 8 resolves to standard at
    # stress 1.00. If this ever drifts, the anchor has moved.
    let tuned = fitMapSize(2, 8)
    check tuned.sizeClass == mszStandard
    check abs(tuned.densityStress - 1.0) < 0.01
    check tuned.verdict == popGood

  test "constant density is refused: the weapon sets a floor":
    # A = 50,900 * P would put a 1v1 on 101,733 px2 — a 319 px board, smaller
    # in every dimension than the gun's own reach. The floor is why not.
    check PxPerOpponent * 1 < mszSmall.playfieldPx(boardRect2)
    let duel = fitMapSize(2, 1)
    check duel.floorBound
    check duel.targetPlayfieldPx == mszSmall.playfieldPx(boardRect2)
    check duel.sizeClass == mszSmall          ## Maxwell's ask, directly
    # Every roster under the hinge wants the same board, and the hinge is where
    # the linear term overtakes the floor.
    let hinge = mszSmall.playfieldPx(boardRect2) / PxPerOpponent
    check hinge > 5.0 and hinge < 6.0
    for units in 1 .. 4:
      check fitMapSize(2, units).floorBound
      check fitMapSize(2, units).sizeClass == mszSmall
    check not fitMapSize(2, 8).floorBound

  test "a 1v1 never lands on giant, which is the whole complaint":
    let duel = fitMapSize(2, 1)
    check mszGiant notin duel.legalClasses
    check mszHuge notin duel.legalClasses
    check duel.legalClasses == @[mszSmall, mszStandard]
    # The old uniform draw offered all five.
    check DrawableSizeNames.len == 5

  test "the effective exponent is ~0.45, and the law is a hinge not a power":
    # Quoted in the design doc, so pinned here: fitting A(n_e) as a power law
    # over the realistic roster range gives ~0.45, but the true shape is a
    # constant floor hinged to a linear term (exponents 0 and 1).
    let
      lo = float(fitMapSize(2, 1).targetPlayfieldPx)
      hi = float(fitMapSize(6, 5).targetPlayfieldPx)
      alpha = ln(hi / lo) / ln(25.0)
    check alpha > 0.40 and alpha < 0.50

  test "opponents drive the law, not population":
    # 6 teams x 2 units and 2 teams x 2 units are both 4-and-12 players, but
    # five sixths of a 6-team field is hostile and only half of a 2-team one is.
    check fitMapSize(2, 6).opponents == 6
    check fitMapSize(6, 2).opponents == 10
    check fitMapSize(6, 2).population == 12
    check fitMapSize(2, 6).population == 12
    check fitMapSize(6, 2).targetPlayfieldPx >
      fitMapSize(2, 6).targetPlayfieldPx

  test "the roster cap is enforced, including Maxwell's own example":
    # "FFA6 with 6 units each" is 36 seats and does not fit MaxPlayers = 32.
    let over = fitMapSize(6, 6)
    check over.population == 36
    check over.population > MaxPlayers
    check over.verdict == popUnsupported
    check "MaxPlayers" in over.reason
    check fitMapSize(6, 5).population == 30    ## the largest that does fit
    check fitMapSize(6, 5).verdict != popUnsupported

suite "population fit: separation versus density":
  test "separation wins, and the resolved class is never below it":
    for teams in [2, 3, 4, 6]:
      for units in 1 .. (MaxPlayers div teams):
        let f = fitMapSize(teams, units)
        check ord(f.sizeClass) >= ord(f.separationClass)
        for c in f.legalClasses:
          check ord(c) >= ord(f.separationClass)

  test "the conflict is reported with a number, never papered over":
    # 6 teams are forced onto giant for base separation; 6 x 1 wants small.
    let sparse = fitMapSize(6, 1)
    check sparse.separationClass == mszGiant
    check sparse.sizeClass == mszGiant
    check sparse.densityStress > 9.0          ## 9.4x the area it wants
    check sparse.verdict == popUnsupported
    check sparse.reason.len > 0
    check "separation" in sparse.reason

  test "6-team FFA is only playable at a full roster":
    # The resolution in one line: 6 teams work when you fill them.
    # On the LETHALITY clock this is sharper than it first looked: 6-team FFA
    # is viable only at a FULL 30-seat roster, and even that is stressed.
    check fitMapSize(6, 1).verdict == popUnsupported
    check fitMapSize(6, 2).verdict == popUnsupported
    check fitMapSize(6, 4).verdict == popUnsupported
    check fitMapSize(6, 5).verdict == popStressed
    check fitMapSize(6, 5).densityStress < fitMapSize(6, 1).densityStress

  test "3 teams inherit a milder version of the same conflict":
    check fitMapSize(3, 4).separationClass == mszHuge
    check fitMapSize(3, 4).verdict == popUnsupported
    check fitMapSize(3, 8).verdict == popStressed
    check fitMapSize(3, 8).densityStress < fitMapSize(3, 4).densityStress

  test "the legality ceiling is the player's own loop, not the tick cap":
    check LegalStressMax ==
      float(TicksToKill + RespawnTicks) / TunedContactTicks
    check LegalStressMax > 2.0 and LegalStressMax < 3.0
    # MaxTicks is a safety cap, not a match length; building the budget on it
    # would be about twice as permissive.
    check (float(MaxTicks) / float(Lives)) / 4.0 / TunedContactTicks >
      2.0 * LegalStressMax

suite "population fit: cover is part of the answer":
  test "an over-sized board compensates with LESS cover, not more":
    # t_find is proportional to cover fraction, so longer sightlines find
    # people sooner. Same conclusion the range regime reached from the other
    # end, which is the consistency check that matters.
    let
      tuned = fitMapSize(2, 8)
      stretched = fitMapSize(6, 4)
      stretchedBand = mapRules(stretched.sizeClass, 6)
    check stretched.densityStress > tuned.densityStress
    check stretched.coverPermilleTarget <= stretchedBand.coverPermilleMax
    check stretched.coverPermilleTarget >= stretchedBand.coverPermilleMin
    # A board LARGER than its roster wants sits at the bottom of its band...
    check stretched.coverPermilleTarget == stretchedBand.coverPermilleMin
    # ...and a board SMALLER than its roster wants sits above the middle.
    let crowded = fitMapSize(2, 10)
    let crowdedBand = mapRules(crowded.sizeClass, 2)
    check crowded.densityStress < 1.0
    check crowded.coverPermilleTarget >
      (crowdedBand.coverPermilleMin + crowdedBand.coverPermilleMax) div 2

  test "saturation is reported when cover cannot pay the difference back":
    check fitMapSize(6, 4).coverCompensationSaturated
    check not fitMapSize(2, 8).coverCompensationSaturated
    # And saturation alone is enough to stop calling a config good.
    check fitMapSize(6, 4).verdict != popGood

  test "the target cover always lands inside the class's own derived band":
    for teams in [2, 3, 4, 6]:
      for units in 1 .. (MaxPlayers div teams):
        let
          f = fitMapSize(teams, units)
          band = mapRules(f.sizeClass, teams)
        check f.coverPermilleTarget >= band.coverPermilleMin
        check f.coverPermilleTarget <= band.coverPermilleMax

suite "population fit: the generator's draw set":
  test "the default rosters restrict the draw and drop the absurd classes":
    check legalSizeNames(2, 8) == @["small", "standard"]
    check legalSizeNames(4, 4) == @["small", "standard", "large"]
    for teams in [2, 4]:
      check legalSizeNames(teams, fitMapSize(teams).unitsPerTeam).len <
        DrawableSizeNames.len

  test "a draw set is never empty, even for a broken configuration":
    for teams in [2, 3, 4, 6]:
      for units in 1 .. (MaxPlayers div teams):
        check legalSizeNames(teams, units).len >= 1

  test "bigger rosters move the draw set upward, monotonically":
    var lowest: seq[int]
    for units in [1, 4, 8, 12, 16]:
      lowest.add ord(fitMapSize(2, units).legalClasses[0])
    for i in 1 ..< lowest.len:
      check lowest[i] >= lowest[i - 1]

  test "the shipping default agrees with the seat plans":
    check fitMapSize(2).unitsPerTeam == 8      ## nearestSeatPlan(2) = 16
    check fitMapSize(4).unitsPerTeam == 4      ## nearestSeatPlan(4) = 16

suite "the two axes: awareness versus lethality":
  ## `GunRange` is a REACH, not an engagement range. Aim is 32 discrete slots
  ## and there is no aim assist, so beyond `14 / tan(5.625 deg)` = 142 px the
  ## lattice — not the jitter — decides whether a shot connects. Every derived
  ## number has to say which axis it lives on, because the two differ by 4x in
  ## distance and 16x in area.
  test "the lethal envelope is where the aim lattice puts it":
    check AimRotations == 32
    check abs(AimHalfSlotDeg - 5.625) < 1e-9
    # R_slot: inside this a centred body cannot be missed by the lattice.
    let rSlot = float(PlayerHalf + int(BulletHalfWidth)) /
      tan(degToRad(AimHalfSlotDeg))
    check abs(rSlot - 142.0) < 1.0
    # The envelope itself is where field accuracy is actually achieved...
    let pHit = radToDeg(arctan(
      float(PlayerHalf + int(BulletHalfWidth)) / float(LethalEnvelopePx))) /
      AimHalfSlotDeg
    check abs(pHit - float(FieldAccuracyPct) / 100.0) < 0.01
    # ...and it independently agrees with the shipped grenade reach to ~1%.
    check abs(LethalEnvelopePx - GrenadeMaxRange) * 100 div GrenadeMaxRange <= 2
    # The jitter is an order of magnitude smaller than the half-slot, which is
    # why the LATTICE is what sets the envelope.
    check LethalEnvelopePx < GunRange div 3

  test "lethality quantities use the envelope, awareness ones use the range":
    let r = mapRules(mszStandard, 2)
    # Lethality: can a defender KILL into the next one / onto that pickup?
    check r.chokepointSpacingPx == LethalEnvelopePx
    check r.minPickupSpacingPx == LethalEnvelopePx
    # Awareness: how far can anyone SEE? The regimes, the sightline band and
    # the cover budget that follows from it are all sightline questions and
    # keep the vision constants.
    check r.visionRangePx == VisionRangePx
    check r.meanFreeSightlineMaxPx == GunRange
    check r.maxOpenRunPx == GunRange
    check ConeAreaPx > 0

  test "an encounter law on sightlines would overstate lethal contact ~16x":
    # The reason this distinction had to be made explicit: areas, not lengths.
    let ratio = (GunRange * GunRange) div
      (LethalEnvelopePx * LethalEnvelopePx)
    check ratio >= 12 and ratio <= 17

  test "the exposed run survives the axis change":
    # 132 px stands because TicksToKill = 48 corresponds to an engagement at
    # ~237 px, which is inside the envelope rather than out at the reach.
    check MaxExposedRunPx == 132
    check MaxExposedRunPx < LethalEnvelopePx
