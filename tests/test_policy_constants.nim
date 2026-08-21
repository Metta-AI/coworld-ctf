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

suite "policy constants track the engine":

  # ── 1. THE PLASMA-ARC REACH ─────────────────────────────────────────────
  #
  # FINDING (2026-08-20, verified against CURRENT source, not a changelog):
  # the policy's `PlasmaArcReachPx = 136.0` is STALE. 136 = 4 * SoldierBodyPx,
  # which is now `PlasmaArcFxReach` — the DRAWN PLUME's span, i.e. ART
  # geometry. The DAMAGE reach is `PlasmaArcReach = 5 * PlasmaArcSquare` = 170,
  # grown at GameVersion 30 precisely so the damage cone covers the tip of the
  # plume the game draws. Reading the FX const instead of the damage const is
  # the most likely origin of 136, and it is a trap that survives eyeballing a
  # replay: the paint you SEE really does end at 136.
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

  # ── 2. THE SPAWN-ADDRESS FAMILY ─────────────────────────────────────────
  #
  # FINDING: the policy's `Team` enum has only `Red, Blue`. The engine's has
  # `Red, Blue, Green, Yellow`. Every pickup address in the policy is written
  # `if team == Red: <a> else: <b>` — a two-way branch — so on a four-team
  # board GREEN AND YELLOW BOTH INHERIT BLUE'S COORDINATES. The engine does not
  # mirror at all: it orbits Red's point through the map's own symmetry
  # (`teamOrbitPoints` / `teamImagePoint`), which is a rot90 on `layoutCorners`,
  # not a left-right flip.
  #
  # Measured misses (re-simulated hosted boards, sibling lanes, 2026-08-20):
  #   MED KIT  0 of 3,433 four-team boards had a live spawn inside the 12px
  #            pickup range of a formula spot; median miss 168px (58px on
  #            2-team, where the formula also loses a 59.9% coin flip over
  #            WHICH candidate pair is active).
  #   SHIELD   0 of 2,400 team-addresses within 12px; Red 395px, Blue 395px,
  #            GREEN 1136.9px, Yellow 65px. Green's address points into
  #            YELLOW's base corner.
  #   ARC      0.00% within 12px, median 178px off, over 600 boards.
  # The med-kit and shield halves are owned by other lanes; asserted here, not
  # fixed here.

  test "the policy Team enum is 2-team, so every address formula is 2-team":
    check policyHas("Team = enum\n    Red, Blue")
    # If someone widens the policy enum, these address formulas must be
    # revisited in the same change — that is the whole point of pinning it.
    check Team.high == Yellow          # the ENGINE knows four

  test "every pickup-address formula is the 2-way shape (documented)":
    # Both formulas branch Red / not-Red. Kept as an inventory, not a fix.
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
