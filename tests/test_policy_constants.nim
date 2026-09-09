import
  std/[os, strutils, unittest],
  ctf/[sim_config, sim_types]

# ── POLICY-CONSTANT DRIFT CONTRACT ─────────────────────────────────────────
#
# `players/baseline/baseline.nim` cannot `import ctf/sim` — the policy is
# compiled standalone into the container — so every engine number it reasons
# about is a HAND-COPIED LOCAL CONSTANT. Nothing links the copy to the original.
# When the engine moves, the copy does not, and the failure is SILENT: the build
# is green, the bot runs, and it makes decisions against a world that stopped
# existing several GameVersions ago.
#
# This suite is the missing link. It is deliberately STATIC — it greps the
# shipped policy source and compares against engine constants — because the
# whole point is to catch a number that no simulation will ever complain about.
#
# It is the ASSERTION half of the 2026-08-20 lever-liveness correctness pass.
# Where a defect was real but a fix could not be justified by a measured bound,
# the house rule is to leave the code and pin the MEASUREMENT here, so nobody
# has to re-derive it. Each `check` below therefore carries its finding in the
# failure message, not just a boolean.

const
  RepoRoot = currentSourcePath.parentDir.parentDir
  PolicyPath = RepoRoot / "players" / "baseline" / "baseline.nim"

let policySrc = readFile(PolicyPath)

proc policyHas(needle: string): bool = policySrc.contains(needle)

proc policyCount(needle: string): int = policySrc.count(needle)

proc policyFloat(name: string): float =
  ## Read a `const <name> = <float>` straight out of the shipped policy source.
  ## ⚠️ Parsed, never hard-coded: a local copy of a constant that ANOTHER lane
  ## is actively correcting turns this suite into a backwards ratchet — it would
  ## fail on the fix instead of on the defect. Parse the live value and assert
  ## the RELATIONSHIP, which is what has to hold at every value.
  let key = "  " & name & " = "
  let i = policySrc.find(key)
  doAssert i >= 0, "constant not found in the shipped policy: " & name
  var j = i + key.len
  var num = ""
  while j < policySrc.len and policySrc[j] in {'0'..'9', '.', '-'}:
    num.add policySrc[j]
    inc j
  doAssert num.len > 0, "no numeric literal after " & name
  parseFloat(num)

suite "policy constants track the engine":

  # ── 1. THE PLASMA-ARC REACH ─────────────────────────────────────────────
  #
  # FINDING (2026-08-20, verified against CURRENT source, not a changelog):
  # the policy's `PlasmaArcReachPx = 136.0` is STALE. 136 = 4 * SoldierBodyPx,
  # which is now `PlasmaArcFxReach` — the DRAWN PLUME's span, i.e. ART
  # geometry. The DAMAGE reach is `PlasmaArcReach = 5 * PlasmaArcSquare` = 170,
  # grown at GameVersion 30 precisely so the damage cone covers the tip of the
  # plume the game draws. Reading the FX const instead of the damage const is
  # the most likely origin of 136.
  #
  # ⚠️⚠️ WHY A REPLAY CHECK RATIFIES THE BUG INSTEAD OF CATCHING IT — this is
  # how the stale constant survived four propagations and two clean audits, and
  # an earlier draft of this comment had it BACKWARDS (it claimed the visible
  # paint stops at 136, which would merely have made a replay check useless).
  # The truth is worse: a replay check actively CONFIRMS the wrong number, in
  # the direction that feels safe. Both halves are in the engine source:
  #   * sim_types.nim:546 — the plume's puffs are "drawn oversize so they merge
  #     (SprayPuffOverlap), so its outermost pixel lands well past this";
  #   * sim_types.nim:558 — the 5th square (GameVersion 30, was 4) "is not extra
  #     range for its own sake — it is exactly what it takes for the damage cone
  #     to cover the tip of the plume the game draws".
  # So the VISIBLE paint reaches approximately the DAMAGE envelope (~187), not
  # 136. A reviewer who sanity-checks `PlasmaArcReachPx = 136` against a replay
  # sees paint out at ~187 against a constant of 136 and concludes "136 is
  # CONSERVATIVE, we have margin" — the opposite of the truth, arrived at by
  # doing the right thing. Any future check of a policy constant against a
  # rendered replay has this hazard: art geometry and damage geometry are
  # separate constants that the engine deliberately keeps in step, so the
  # picture cannot distinguish them. Check the CONSTANT, not the picture.
  #
  # It is worse than a 34px error, because a victim is a DISC, not a point:
  # sim.selectArcVictims accepts a victim while
  #     forward <= PlasmaArcReach + PlasmaArcBodyRadius        (170 + 17 = 187)
  #     perpendicular <= forward * (MaxWidth / (2*reach)) + 17 (slope 0.25)
  # so the head-on danger radius is 187px. PlasmaArcDamage == MaxHp, so one
  # touch is an instant kill.

  test "engine arc geometry is the number the policy comments claim":
    check PlasmaArcSquare == SoldierBodyPx
    check PlasmaArcReach == 5 * SoldierBodyPx        # 170, NOT 136
    check PlasmaArcFxReach == 4 * SoldierBodyPx      # 136 is the FX/plume span
    check PlasmaArcBodyRadius == SoldierBodyPx div 2 # 17
    check PlasmaArcMaxWidth == 5 * SoldierBodyPx div 2
    # The documented half-angle: slope = MaxWidth / (2 * reach) = 0.25.
    check PlasmaArcMaxWidth.float / (2.0 * PlasmaArcReach.float) == 0.25
    # One cone touch is lethal to a bare cog (3 hp), which is why the margin
    # below matters at all: there is no "survive it and back off" outcome.
    check PlasmaArcDamage == 3

  test "the policy's local arc-reach copy is a KNOWN-STALE tombstone":
    # We do NOT assert the copy equals the engine — it does not, and the fix is
    # owned by the spray lane (the same constant propagated into
    # `ArcBreachFireReach` and is ALSO read as a cluster radius, so changing its
    # value from a second branch would silently widen an unrelated gate by
    # 1.56x in area). What we assert is that it cannot go back to looking
    # CORRECT while being wrong: if someone deletes the tombstone comment
    # without fixing the number, this fails.
    check policyHas("PlasmaArcReachPx = 136.0")
    check policyHas("STALE SINCE GameVersion 30")

  test "MEASURED: both defensive arc gates sit INSIDE the real kill zone":
    # The finding, pinned so it is never re-derived. These are the numbers as
    # SHIPPED; the test documents the gap rather than asserting it away.
    const
      PolicyReach = 136.0        # baseline.nim PlasmaArcReachPx (stale)
      CounterArcReachBuffer = 24.0
      ArcStandoffBuffer = 60.0
      ArcStandoffRing = PolicyReach + ArcStandoffBuffer          # 196
      DisarmedThreshold = PolicyReach + CounterArcReachBuffer    # 160
    let realDanger = float(PlasmaArcReach + PlasmaArcBodyRadius) # 187
    check realDanger == 187.0

    # counterArc calls an arc-carrier "safely disarmed — a free kill" beyond
    # 160px and pays CounterArcBonus(240) to STEER THE ENGAGE at it. That is
    # 27px inside a cone that one-shots us: the lever does not merely fail to
    # protect, it actively pulls us onto the one enemy that can delete us.
    check DisarmedThreshold < realDanger
    check realDanger - DisarmedThreshold == 27.0

    # arcStandoff backs off at 196px. ArcStandoffBuffer was sized at 60px to
    # cover the 5-tick cone sweep plus one frame of reaction at 2.75px/tick.
    # Against the real envelope the margin is NINE px — about 3 ticks, i.e.
    # less than the sweep it was explicitly sized for. The dead band
    # (196..236px) therefore straddles the kill line instead of clearing it.
    let effectiveMargin = ArcStandoffRing - realDanger
    check effectiveMargin == 9.0
    check effectiveMargin < float(PlasmaArcActiveTicks) * 2.75
    # ⚠️ NOT PATCHED HERE ON PURPOSE. arcStandoff's shipped behaviour rests on
    # a measured result (retreat a cone DIAGONALLY, not radially); moving the
    # ring changes the slip geometry's premise, so it needs its own A/B rather
    # than a drive-by number swap.

  # ── 1b. THE TWO HALVES OF ONE WEAPON MUST AGREE ─────────────────────────
  #
  # The arc has a FIRE half (when do we press the can) and a VETO half (when
  # would pressing it hit a teammate). They are separate code with separate
  # constants, and nothing made them agree — v58 sized the VETO to the engine's
  # true 170 while the FIRE gate stayed on `ArcBreachFireReach = 128`, derived
  # from the stale 136 (its own doc comment still says "just inside the engine's
  # 136px reach"). The two halves of one weapon disagreed by 59px.
  #
  # TWO INVARIANTS, both directional, both true before AND after the spray
  # lane's correction — so this pins the relationship without ratcheting
  # backwards on a value that is actively being fixed elsewhere.

  test "the arc VETO envelope covers the engine's true damage envelope":
    # If the veto were narrower than the weapon, we would fire shots the veto
    # believed were safe and the engine scored as friendly fire. This is the
    # invariant that must never break.
    const
      ArcFfReachPx = 170.0
      ArcFfBodyPx = 17.0
      ArcFfRidePx = 13.75      # PlasmaArcActiveTicks(5) * 2.75px/tick of ride
      ArcFfSlope = 0.25
      ArcFfAimPadSlope = 0.125 # one tick of turret lag
    # Local copies must match the shipped source, or this test is fiction.
    check policyHas("ArcFfReachPx = 170.0")
    check policyHas("ArcFfBodyPx = 17.0")
    check policyHas("ArcFfRidePx = 13.75")
    check policyHas("ArcFfSlope = 0.25")
    check policyHas("ArcFfAimPadSlope = 0.125")
    let engineDanger = float(PlasmaArcReach + PlasmaArcBodyRadius)   # 187
    check ArcFfReachPx + ArcFfBodyPx >= engineDanger - 0.001
    # …and the veto's wedge is WIDER than the engine's, never narrower.
    check ArcFfSlope + ArcFfAimPadSlope >=
      PlasmaArcMaxWidth.float / (2.0 * PlasmaArcReach.float)
    # The ride term is the half-window of a cone that re-selects victims on
    # every one of its active ticks; it can only ever widen the veto.
    check ArcFfRidePx > 0.0

  test "the arc FIRE envelope never exceeds the engine's (SHIPPED value)":
    # ⚠️⚠️ THIS TEST RESOLVES THE SHIPPED FIRE REACH, NOT A NAMED CONSTANT.
    # The first draft bounded `ArcBreachFireReach` because that WAS the fire
    # gate. The spray lane's correction keeps that constant at 128.0 as the
    # `NOSPRAYCONE=1` CONTROL arm and moves the shipped gate to a tune-gated
    # expression, so a test pinned to the constant would go GREEN FOREVER and
    # never see the shipped number again — the exact failure `policyFloat()`
    # exists to prevent, one level further out. A guard has to track the value
    # the champion actually plays with, through every indirection.
    # ⚠️ CROSS-LANE OWNERSHIP — read before "fixing" a failure here.
    # `ArcFfReachPx` / `ArcFfBodyPx` / `ArcFfRidePx` / `ArcFfSlope` are NOT the
    # arc lane's. They arrived at 702701e with v58's friendly-fire vetoes, so
    # the WINDUP/AoE-VETO lane owns them — and this test now transitively bounds
    # a third lane's constants against the engine. That is correct by
    # construction (the veto wedge and the fire wedge are built from the same
    # numbers, so if they move together an overshoot still trips the ENGINE
    # bound), but it means an edit in a lane that has never heard of this file
    # can turn it red. If you are that lane: the failure is telling you the arc
    # weapon's fire or veto envelope no longer matches `sim.selectArcVictims`,
    # which is a real defect, not a stale test. Re-derive from
    # src/ctf/sim_types.nim rather than relaxing the bound.
    const
      ArcFfReachPx = 170.0
      ArcFfBodyPx = 17.0
      ArcFfRidePx = 13.75
      ArcFfSlope = 0.25
    let
      engineDanger = float(PlasmaArcReach + PlasmaArcBodyRadius)   # 187
      engineSlope = PlasmaArcMaxWidth.float / (2.0 * PlasmaArcReach.float)
      vetoCap = ArcFfReachPx + ArcFfBodyPx + ArcFfRidePx           # 200.75
      # The cone-sized gate ships default ON via a NO* opt-out, so its ON arm
      # is the shipped envelope; the constant survives as the control arm.
      coneGated = policyHas("sprayConeFire")

    var shippedFireReach: float
    if coneGated:
      # Post-correction shape. Assert the ARMING too — a lever that silently
      # became opt-IN would move the shipped envelope back to the control arm
      # without changing either number.
      # ⚠️ This is a SOURCE assertion: it proves the file says default-ON. It
      # does NOT prove the built binary resolves default-ON — see 4b, and pair
      # it with a resolved-tune dump in the ship checklist. Source, resolved
      # tune, and image recipe are three separate guarantees.
      check policyHas("result.sprayConeFire = getEnv(\"NOSPRAYCONE\").len == 0")
      check policyHas("ArcFfReachPx + ArcFfBodyPx")
      shippedFireReach = ArcFfReachPx + ArcFfBodyPx                # 187
      # The control arm must still be a legal envelope in its own right.
      check policyFloat("ArcBreachFireReach") <= engineDanger
    else:
      # Pre-correction shape: the constant IS the shipped gate.
      check policyHas("ArcBreachFireReach = ")
      shippedFireReach = policyFloat("ArcBreachFireReach")         # 128

    # ⚠️ FAIL LOUD rather than silently skipping. If neither recognised shape is
    # present the fire gate has been restructured again, and this test must be
    # re-pointed rather than quietly passing on a stale assumption.
    check shippedFireReach > 0.0

    # (a) SAFETY — never press outside what the VETO is prepared to police, or
    #     we take shots the friendly-fire veto never examined. Margin here is
    #     ArcFfRidePx(13.75); the veto is deliberately the wider envelope.
    check shippedFireReach <= vetoCap

    # (b) SANITY — never press beyond what the ENGINE can actually damage.
    check shippedFireReach <= engineDanger

    # (c) The WEDGE, same direction. The fire slope must not exceed the engine's.
    check ArcFfSlope <= engineSlope + 1e-9

    # ⚠️⚠️ ZERO MARGIN IS THE TARGET STATE, NOT A NEAR-MISS — DO NOT "FIX" IT.
    # Post-correction both engine bounds hold with EQUALITY: reach 187 == 187 and
    # slope 0.25 == 0.25. That is deliberate — the fire predicate is
    # `selectArcVictims` term for term with NO padding, because padding the
    # ENEMY side would be tuning whereas matching the engine is a correctness
    # repair. Hence `<=` and not `<` throughout: a strict inequality would fail
    # on the correct answer. Anyone reading the zero margin as a bug and adding
    # a safety pad would be re-introducing the very defect this file exists to
    # catch, in the opposite direction.

    # ⚠️ MEASURED COST, recorded not asserted (the gap closes to 0 on landing, so
    # pinning it would ratchet backwards). Over 1,421 re-simulated Elite ffa4
    # episodes, of ready carry-ticks where the sim's own `selectArcVictims`
    # WOULD have damaged a fresh enemy at the bearing we already held
    # (n = 3,609 for us), **71.3% were refused by ArcBreachFireReach = 128
    # ALONE** — the most expensive stale number in the arc family. The 59px
    # disagreement between the two halves of one weapon is the whole mechanism:
    # the veto knew the cone reaches 187, the trigger did not.
    # ⚠️ That 71.3% is a paired within-block ratio from an UNCALIBRATED rig
    # (7.7x seed-block spread); it earns the fix PRIORITY, not a ship claim.
    # The hosted A/B is the test, and the correctness repair stands either way.

  # ── 2a. THE PER-TEAM ADDRESS BUG: SHIELD AND ARC ONLY ───────────────────
  #
  # ⚠️ SCOPE CORRECTION 2026-08-20 (caught by the kit-selector lane BEFORE this
  # test hardened, and re-verified here against both sources). An earlier draft
  # of this file filed MED KIT, SHIELD and ARC as "three faces of one bug". That
  # was WRONG, and wrong in the most durable way — a false causal claim inside a
  # GREEN test. Med kits have a SEPARATE cause; see 2b. Only shield and arc are
  # this bug. The two defects happen to produce the same symptom (a phantom
  # address), which is exactly why they got merged.
  #
  # FINDING: the policy's `Team` enum has only `Red, Blue`. The engine's has
  # `Red, Blue, Green, Yellow`. The shield and arc addresses are each written
  # `if team == Red: <a> else: <b>` — a two-way branch — so on a four-team board
  # GREEN AND YELLOW BOTH INHERIT BLUE'S COORDINATES. The engine does not mirror
  # at all: it orbits Red's point through the map's own symmetry
  # (`teamOrbitPoints` / `teamImagePoint`), which is a rot90 on `layoutCorners`
  # — the TOP edge, not the right edge a mirror picks.
  #
  # Measured (re-simulated hosted boards, sibling lanes, 2026-08-20):
  #   SHIELD  0 of 2,400 team-addresses within the 12px pickup range;
  #           Red 395px, Blue 395px, GREEN 1136.9px, Yellow 65px. Green's
  #           address points into YELLOW's base corner.
  #   ARC     0.00% within 12px, median 178px off, over 600 boards.
  # The shield half is owned by the consumable lane; asserted here, not fixed.

  test "the policy Team enum is 2-team, so the PER-TEAM addresses are 2-team":
    check policyHas("Team = enum\n    Red, Blue")
    # If someone widens the policy enum, these address formulas must be
    # revisited in the same change — that is the whole point of pinning it.
    check Team.high == Yellow          # the ENGINE knows four

  test "the shield and arc addresses are the 2-way shape (documented)":
    # Both formulas branch Red / not-Red. Kept as an inventory, not a fix.
    # ⚠️ EXACTLY TWO formulas have this shape. The med-kit constants are NOT
    # among them — they take no team argument at all (see 2b).
    check policyHas("if team == Red: vec(50, y) else: vec(float(MapW - 50), y)")
    check policyCount("if team == Red: vec(50, y) else: vec(float(MapW - 50), y)") == 2
    # …while the engine derives every non-Red point by SYMMETRY, and on
    # layoutCorners Blue's shield is a QUARTER TURN of Red's (the top edge),
    # not the right edge a mirror picks.
    check policyHas("proc ownShieldSpawn(team: Team): Vec")
    check policyHas("proc arcSpawn(team: Team): Vec")

  test "arcSpawn is UNREACHABLE in every shipped image (assert, not fix)":
    # arcSpawn has exactly one call site, inside the breacher seek block gated
    # on `iAmBreacher = bot.tune.arcBreach and ...`. `arcBreach` is FALSE in
    # shippedCombatTune() and set true ONLY under `when defined(arcOn)` — and
    # the image builds with `ARG NIM_DEFINES=""`. So its phantom address has
    # never once been walked to in a shipped build, and correcting the address
    # would change nothing. Both facts are true; neither justifies a patch.
    check policyCount("arcSpawn(bot.team)") == 1
    check policyHas("when defined(arcOn):\n    result.arcBreach = true")
    # No unconditional arming may creep in without this test noticing.
    check policyCount("result.arcBreach = true") == 1

  # ── 2b. THE MED-KIT PHANTOM: A DIFFERENT BUG WITH THE SAME SYMPTOM ──────
  #
  # FINDING: the med-kit formula is a phantom for reasons that have NOTHING to
  # do with the `Team` enum. It takes no team argument at all —
  #     MedKitAX = MapW div 2        MedKitBX = MapW div 2
  #     MedKitAY = MapH div 3        MedKitBY = 2 * MapH div 3
  # — so all four colours walk to the SAME two spots and miss by the SAME
  # distance. There is no address to inherit and no per-team asymmetry.
  #
  # ⭐ THE METHOD THAT SEPARATED THEM — worth more than either finding.
  # Both defects present identically as "0% of formula spots are within the
  # 12px pickup range", which is what let them be merged into one cause.
  # DECOMPOSING THE POSITIONAL ERROR INTO AXES before assigning a cause split
  # them apart in one table (hosted mapSpecs, kit-selector lane, 2026-08-20):
  #
  #     board     mean |dx|   mean |dy|   formula x EXACTLY the kit x
  #     2-team      0.0 px     46.7 px    18/18 (100%)
  #     4-team    169.3 px     59.3 px     0/6  (0%)
  #
  # The enum mechanism REQUIRES a nonzero |dx| (a team inheriting the wrong
  # side's x). On 2-team |dx| is identically ZERO on 18 of 18 boards, so the
  # enum cannot be the cause there. Always decompose before attributing.
  #
  # THE TWO REAL CAUSES, both confirmed against src/ctf/arena.nim:
  #   2-TEAM — the x is EXACT by construction (generator `mid = width div 2`,
  #     policy `MapW div 2`: the same number), so the entire miss is in y. The
  #     generator draws y1 from [0.16H, 0.34H] and y2 from [0.36H, 0.47H] and
  #     then COIN-FLIPS which of the two candidate pairs is live. The policy
  #     hard-codes H/3 and 2H/3 and knows nothing of the draw or the flip.
  #   4-TEAM — the generator ABANDONS the centre column entirely and places
  #     four kits on a quadMirror/rot90 ORBIT at radius d from map centre. That
  #     is why 4-team (median 168px) is worse than 2-team (58px) — not because
  #     half the teams get another team's address.
  # Verified independently on a real hosted 4-team spec (gen-21482, width 1235,
  # so MedKitAX = 617): kits sit at x = 499 and 735, i.e. |dx| = 118 on all
  # four, and none is on the centre column.
  #
  # Owned by the consumable-economy and kit-selector lanes. Asserted, not fixed.

  test "the med-kit formula has NO team term (so the enum bug cannot reach it)":
    check policyHas("MedKitAX = float(MapW div 2)")
    check policyHas("MedKitBX = float(MapW div 2)")
    check policyHas("MedKitAY = float(MapH div 3)")
    check policyHas("MedKitBY = float(2 * MapH div 3)")
    # The shape that WOULD carry the enum bug is `proc …(team: Team)`. The
    # med-kit constants are plain map-derived values with no team parameter,
    # which is the whole reason 2a cannot explain them.
    check not policyHas("MedKitAX(team")
    check not policyHas("medKitSpot(team")

  test "the ENGINE med-kit generator explains the miss on both axes":
    let arenaSrc = readFile(RepoRoot / "src" / "ctf" / "arena.nim")
    # 2-team: same x as the policy (hence |dx| == 0), y is a RANDOM DRAW from
    # two bands, and a COIN FLIP selects which candidate pair is live.
    check arenaSrc.contains("mid = result.width div 2")
    check arenaSrc.contains("y1 = rng.pickRange(result.height * 16 div 100")
    check arenaSrc.contains("y2 = rng.pickRange(result.height * 36 div 100")
    check arenaSrc.contains("if rng.coin():")
    # 4-team: an ORBIT about the centre, not a centre column at all.
    check arenaSrc.contains("quadMirrorOrbit(")
    check arenaSrc.contains("rot90Orbit(")
    check arenaSrc.contains("result.medKitSpawns = result.medKitCandidates")

  # ── 3. THE AIM WORLD (why spinCap is unreachable) ───────────────────────
  #
  # FINDING: `spinCap` ships ON and its guarded branch was evaluated 0 times in
  # 768,992 bot-frames on both board families. Nothing is wrong with spinCap:
  # the whole spin-budget family lives inside the `elif desiredAim >= 0:` GV36
  # SLOT-SERVO arm, which runs only when the observed aim step is a multiple of
  # 8 brads and >= 8 (a 32-slot lattice). GV40 restored CONTINUOUS aim, so the
  # step is AimTurnRate = 5 brads/tick and the continuous arm always wins.
  #
  # Left armed deliberately: switching it off would be a behaviour change with
  # no bound behind it (it cannot execute either way), and if the engine ever
  # returns to a slot lattice the lever should wake up as its authors intended.
  # This test is the tripwire for exactly that flip.

  test "the engine is a CONTINUOUS-aim world, so the slot servo is dead code":
    check AimTurnRate == 5
    # The policy's slot-world test, reproduced exactly:
    #   aimSlotWorld = aimLegacy or (aimStepBrads >= 8 and aimStepBrads mod 8 == 0)
    let slotWorld = AimTurnRate >= 8 and AimTurnRate mod 8 == 0
    check not slotWorld
    check policyHas("bot.aimStepBrads >= 8 and bot.aimStepBrads mod 8 == 0")
    # ⚠️ IF THIS TEST EVER FAILS, spinCap (and NOSPINCAP / SPINRANGE with it)
    # has just come back to life UNMEASURED. It has never been exercised on
    # this engine. A/B it before trusting it.

  # ── 4. THE GRENADE BARRAGE IS ARMED IN THE FIELD ────────────────────────
  #
  # FINDING — and a CORRECTION to the lever-liveness audit. That audit recorded
  # `BarrageDepthPx == 0.0` on 100% of frames and concluded hazardSense's
  # barrage branch was a constant-false guard. It is not. The branch is live and
  # the label contract is intact; the local RIG was blind:
  #   * the marker is emitted only when `barrageMaxPerSec > 0`, and
  #     `defaultGameConfig()` ships 0;
  #   * `newEvalEngine` overrode aimTurnRate/gunRange/map/teams/scoring and
  #     nothing else, so every local episode ran with the mode OFF;
  #   * the HOSTED league arms it on 2v2, 4ffa AND 4ffa8.
  # `EVAL_BARRAGE` now exposes it to the rig. This test pins the field truth so
  # the false null cannot be re-derived from a local run.

  test "the hosted manifest ARMS the barrage endgame":
    let manifest = readFile(RepoRoot / "coworld_manifest_paintbot.json")
    # Present as a real mode setting, not merely as a schema default.
    check manifest.contains("\"barrageMaxPerSec\": 15")
    check manifest.count("\"barrageMaxPerSec\": 15") >= 3   # 2v2, 4ffa, 4ffa8
    # …while the engine default is OFF, which is what made the rig silent.
    check defaultGameConfig().barrageMaxPerSec == 0

  test "the rig can now reach the barrage, and the LATCH is documented":
    let engineSrc = readFile(
      RepoRoot / "players" / "baseline" / "eval" / "harness_engine.nim")
    check engineSrc.contains("EVAL_BARRAGE")
    check engineSrc.contains("config.barrageMaxPerSec = parseInt")
    # The trap that produced the false null a second time is worth pinning:
    # depth is stated 0 until the clock drops to barrageStartSec remaining, so
    # a run that stops before the latch reads 0 even with the mode armed.
    check BarrageStartSec == 30
    check engineSrc.contains("THE LATCH IS THE TRAP")
    # ⭐ MEASURED, so the false null cannot be re-derived: one episode, seed 101,
    # `-d:barrprobe`, EVAL_BARRAGE=15 EVAL_BARRAGE_START=280 gave maxDepth 330px,
    # 20,136 frames with a non-zero stated depth, 20,136 post/stand vetoes and
    # 14,970 frames on which the body-evacuation override DROVE THE FEET. The
    # same binary with the mode off reproduces the audit's 0.0/0/0/0 exactly.
    # The branch is live and dominant; only the rig was blind.
    check engineSrc.contains("14,970 body-EVACUATION frames")

  # ── 4b. THE IMAGE MUST NOT ARM OR DISARM ANYTHING ───────────────────────
  #
  # ⚠️ WHY THIS EXISTS: every other arming check in this file is a SOURCE
  # assertion, and the bug that cost NINE DAYS was an IMAGE bug. `touchCommit`
  # was correct in source the whole time; it was dark in the built container
  # because arming depended on an env var the Dockerfile never set. A source
  # parse cannot see that, and neither can a local rig run — they came apart
  # once already, and the shipped champion is what counts.
  #
  # THE GUARANTEE THIS PINS. The policy's arming contract is:
  #     default-ON  ->  `result.x = getEnv("NOX").len == 0`   (opt-OUT)
  #     dark        ->  `result.x = getEnv("X").len > 0`      (opt-IN)
  # Both resolve correctly IF AND ONLY IF the image supplies no environment of
  # its own. So rather than trying to predict which vars matter, assert the
  # stronger and simpler property: THE RUNTIME STAGE SETS NO ENV AT ALL. Then
  # every opt-OUT lever is necessarily ON in the image and every opt-IN lever is
  # necessarily OFF, with no per-lever bookkeeping to fall out of date.
  #
  # ⚠️ WHAT IT STILL DOES NOT PROVE: that the built BINARY resolves the tune the
  # way the source reads. This is a static guard over the build recipe, not an
  # execution of the artifact. The complement is a RESOLVED-TUNE dump read off a
  # constructed Bot (the `LEVERSTATE` / `SPRAYARM` probe shape in the eval
  # harness), which belongs in the ship checklist rather than in CI. Source
  # parse, resolved tune, and image recipe are three different guarantees; this
  # file owns two of them and deliberately does not pretend to own the third.

  test "the shipped IMAGE supplies no environment, so arming is code-only":
    let dockerfile = readFile(RepoRoot / "players" / "baseline" / "Dockerfile")
    # Split into build stages; the LAST `FROM` begins the runtime stage, which
    # is the only one whose environment the running policy can observe.
    var stages: seq[string] = @[]
    for line in dockerfile.splitLines():
      if line.strip().toLowerAscii().startsWith("from "):
        stages.add ""
      if stages.len > 0:
        stages[^1].add line & "\n"
    check stages.len >= 2          # a builder stage and a runtime stage
    let runtime = stages[^1]

    # (1) THE RUNTIME STAGE DECLARES NO ENV WHATSOEVER. Not "no NO* vars" — none
    #     at all, which is the property that needs no maintenance.
    for line in runtime.splitLines():
      let t = line.strip()
      check not t.toLowerAscii().startsWith("env ")

    # (2) …and it inherits nothing from the builder: only the compiled binary is
    #     copied forward, so the builder's `ENV PATH` cannot leak into the run.
    check runtime.contains("COPY --from=build")
    check not runtime.contains("ENV PATH")

    # (3) COMPILE-TIME arming is off too: the image builds with an EMPTY define
    #     set, so every `when defined(...)` lever is dark in the shipped binary.
    #     This is what keeps `arcBreach` honest (see section 2a).
    check dockerfile.contains("ARG NIM_DEFINES=\"\"")

    # ⚠️ IF THIS TEST FAILS, DO NOT "FIX" IT BY NARROWING THE CHECK. An `ENV`
    # line appearing in the runtime stage means a lever is being armed by the
    # IMAGE — the exact anti-pattern that hid `touchCommit` for nine days while
    # it was field-proven. The fix is to move the arming into
    # `shippedCombatTune()` as a default-ON `NO*` opt-out, never to allow the
    # env var here.

  # ── 5. NO STILLBORN / NO-OP LEVER MAY RETURN ────────────────────────────

  test "the deleted dead levers stay deleted":
    # carrierGrabDetect: shipped `true` with ZERO read sites in every shipped
    # build (`git log --all -S "tune.carrierGrabDetect"` -> one commit, 80e7f87,
    # not an ancestor of HEAD). The fix it named ships as an unconditional
    # constant, which is still present and still doing the work.
    # ⚠️ Match the CODE line (start of line, proc-body indent), not the string —
    # the tombstone comments quote the deleted line verbatim on purpose.
    check not policyHas("\n    carrierGrabDetect: bool")
    check not policyHas("\n  result.carrierGrabDetect = true")
    check policyHas("CarrySelfRadius")
    check policyHas("carrierGrabDetect — FIELD DELETED")

    # carrierClearBand: v47 deleted both bodies but left an `if/else` whose two
    # arms were byte-identical, so from v47 on it could not change a mask on
    # ANY board. The liveness audit counted 1,008 "fires" for it on 2-team —
    # the canonical case of a fire counter being unable to see an `if` whose
    # arms agree.
    check not policyHas("\n    carrierClearBand: bool")
    check not policyHas("\n  result.carrierClearBand = true")
    check policyHas("carrierClearBand — FIELD DELETED")

  test "no A/B knob exists for a field the policy never reads":
    let harnessSrc = readFile(
      RepoRoot / "players" / "baseline" / "eval" / "harness.nim")
    # grabTiming / grabGate are TOMBSTONES: real shipped history, superseded by
    # smartGrab, kept for their design record. What must NOT exist is a knob
    # that arms them, because such an A/B is a guaranteed null that reads as
    # "no effect" rather than "not wired".
    # A read site is always `bot.tune.<field>` in this policy; the tombstone
    # comments quote the bare `tune.<field>` form, so anchor on the real shape.
    check policyCount("bot.tune.grabTiming") == 0
    check policyCount("bot.tune.grabGate") == 0
    check policyHas("ZERO READ SITES since smartGrab")
    check not harnessSrc.contains("envInt(\"GRABTIMING\"")
    check not harnessSrc.contains("envInt(\"GRABGATE\"")
    check not harnessSrc.contains("envInt(\"GRABFIX\"")
    check not harnessSrc.contains("envInt(\"CLEARBAND\"")
    # …and each is loud rather than silently absent.
    check harnessSrc.contains("deadKnob(\"GRABTIMING\"")
    check harnessSrc.contains("deadKnob(\"GRABGATE\"")
    check harnessSrc.contains("deadKnob(\"GRABFIX\"")
    check harnessSrc.contains("deadKnob(\"CLEARBAND\"")

  # ── 6. THE 2-TEAM MEDKIT PERCEPTION BLACKOUT ────────────────────────────

  test "MEASURED: medVisOn is FALSE OUTRIGHT on a two-team board":
    # `medVisOn = tune.medSee or (tune.ffaMedSee and ffa4Board)`, and medSee is
    # armed only by an opt-IN container env var the image never sets. So on
    # 2-team the union-of-visible-kit-sprites candidate family is never
    # populated at all — the standing "we never steer to medkits, broken on
    # 2-team too" finding is a PERCEPTION BLACKOUT, not a steering failure.
    check policyHas(
      "let medVisOn = bot.tune.medSee or (bot.tune.ffaMedSee and ffa4Board)")
    check policyHas("result.medSee = getEnv(\"MEDSEE\").len > 0")
    let dockerfile = readFile(
      RepoRoot / "players" / "baseline" / "Dockerfile")
    # The image declares exactly one environment variable, and it is not MEDSEE.
    check not dockerfile.contains("MEDSEE")
    check policyHas("2-TEAM MEDKIT PERCEPTION BLACKOUT")
    # ⚠️ Arming it is a TRADE, not a free fix: adding sight alone measured
    # +0.32 ± 0.08 heals/team-Ep but −0.02 ± 0.01 captures/team-Ep (n=18,
    # paired, 3 hosted 2-team mapSpecs x 3 seeds) — the capture sign the
    # 2026-08-06 FEET LAW revert predicted. The gate belongs to the
    # consumable-economy lane, one knob per consumable.
