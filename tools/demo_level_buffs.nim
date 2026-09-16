## LEVELS ARE POWER -- paired demo (harness card 2d30dba3, GLORYVERSION 16,
## GameVersion 61). Proves the six `levelX()` GLORY buff accessors, dead
## since GV10 ("landed... unwired increment 1/3", 04096969), now fire in
## real combat resolution -- not just that they compile, per the "WIRE
## moves, PROSE does not" rule.
##
## Method: paired seats on the SAME sim (same seed, same config, same
## engine build), one seat pinned at level 0 ("recruit", the control) and
## one at MaxLevel ("legend", the treatment). Every measurement below calls
## the REAL sim proc that runs in a live match (startFireWindup,
## selectGunShot/applyFire, startArcFire, tryPickupGrenades/throwGrenade,
## applyInput) and reads the field it actually wrote -- never a
## reimplementation of the glory.nim formulas. A fresh paired game is built
## per section so no measurement's tick history leaks into the next.
##
## Usage: nim r tools/demo_level_buffs.nim
## Exit code is nonzero if ANY buff fails to show the expected paired
## difference -- a compile-clean but functionally-dead buff fails this
## script exactly the way it failed the six real call sites before this
## change.

import
  std/[strformat],
  ../src/ctf/sim,
  toolutil

const
  RecruitIdx = 0  ## level 0, the control seat.
  LegendIdx = 1   ## MaxLevel, the treatment seat.

proc idle(sim: SimServer): seq[InputState] =
  ## An all-idle input frame sized to the roster (tests/helpers.nim's
  ## `none()`, inlined here so this tool has no test-only import).
  newSeq[InputState](sim.players.len)

proc pairedGame(configOverrideJson = ""): SimServer =
  ## Two seats, same team-neutral setup, one pinned to level 0 and one to
  ## MaxLevel. hp is re-set to each seat's OWN buffed ceiling after pinning
  ## level, mirroring what `respawnPlayers`/match-start do for a cog that is
  ## already at that level when its life begins -- NOT a mid-life heal (the
  ## design law is explicit: levelling grants headroom, never a free heal).
  ## `configOverrideJson`, when non-empty, is applied via `config.update`
  ## exactly like `tools/record_fixture.sh`'s recipes -- lets a section
  ## demo the buffs on a NAMED LIVE VARIANT's shape, not only the default.
  chdirGameDir()
  var config = defaultGameConfig()
  if configOverrideJson.len > 0:
    config.update(configOverrideJson)
  result = initSimServer(config)
  discard result.addPlayer("recruit")
  discard result.addPlayer("legend")
  result.startGame()
  result.players[RecruitIdx].team = Red
  result.players[LegendIdx].team = Blue
  result.players[RecruitIdx].level = 0
  result.players[LegendIdx].level = MaxLevel
  result.players[RecruitIdx].hp = result.config.maxHpFor(
    Red, result.players[RecruitIdx].perks, result.players[RecruitIdx].level)
  result.players[LegendIdx].hp = result.config.maxHpFor(
    Blue, result.players[LegendIdx].perks, result.players[LegendIdx].level)

const
  ## battle-royale-s2's own manifest shape (coworld_manifest_paintbot.json,
  ## the "hitPoints": 4 arm E variant) trimmed to the fields that matter for
  ## this demo: hitPoints=4 (not the classic-CTF default of 3) and brMode
  ## true (so levelForXp's threshold scaling and hitPointsFor's handicap
  ## path both run the SAME code the live variant runs). Full 16-team/zone
  ## shape omitted -- irrelevant to a 2-seat buff comparison.
  BrArmEConfigJson = """{"hitPoints": 4, "brMode": true, "lives": 1}"""

var failures = 0
var totalChecks = 0

proc report(label: string, recruit, legend: string, pass: bool) =
  let mark = if pass: "PASS" else: "FAIL"
  echo &"[{mark}] {label}: recruit(L0)={recruit}  legend(L5)={legend}"
  inc totalChecks
  if not pass:
    inc failures

# ── 1. levelWindupTicks (L1 -1 tick, L5 another -1 -- total -2) ───────────
block windup:
  var sim = pairedGame()
  sim.startFireWindup(RecruitIdx)
  sim.startFireWindup(LegendIdx)
  let
    recruitTicks = sim.players[RecruitIdx].fireWindup
    legendTicks = sim.players[LegendIdx].fireWindup
  report("windup ticks armed (startFireWindup)",
    $recruitTicks, $legendTicks,
    recruitTicks == FireWindupTicks and legendTicks == FireWindupTicks - 2 and
      legendTicks < recruitTicks)

# ── 2. levelMaxHp (+1 at L3+, capped there) ────────────────────────────────
block maxHp:
  let sim = pairedGame()
  let
    recruitHp = sim.players[RecruitIdx].hp
    legendHp = sim.players[LegendIdx].hp
  report("spawn hp ceiling (maxHpFor)",
    $recruitHp, $legendHp,
    recruitHp == HitPoints and legendHp == HitPoints + 1 and
      legendHp > recruitHp)

# ── 2b. levelMaxHp on the LIVE battle-royale-s2 arm E shape (hp=4, not the
#        classic-CTF default of 3) -- same buff, the variant's real ceiling.
block maxHpBrArmE:
  let sim = pairedGame(BrArmEConfigJson)
  let
    recruitHp = sim.players[RecruitIdx].hp
    legendHp = sim.players[LegendIdx].hp
  report("spawn hp ceiling on battle-royale-s2 (hp=4 arm E, maxHpFor)",
    $recruitHp, $legendHp,
    recruitHp == 4 and legendHp == 5 and legendHp > recruitHp)

# ── 3. levelFireCooldown (-25% at L4+) ─────────────────────────────────────
block fireCooldown:
  var sim = pairedGame()
  sim.tryFire(RecruitIdx)
  sim.tryFire(LegendIdx)
  let
    recruitCd = sim.players[RecruitIdx].fireCooldown
    legendCd = sim.players[LegendIdx].fireCooldown
  report("fire cooldown armed (applyFire)",
    $recruitCd, $legendCd,
    recruitCd == FireCooldownTicks and
      legendCd == FireCooldownTicks * 75 div 100 and legendCd < recruitCd)

# ── 4. levelSprayReset (-40% at L2+) ───────────────────────────────────────
block sprayReset:
  var sim = pairedGame()
  sim.players[RecruitIdx].hasSprayPaint = true
  sim.players[LegendIdx].hasSprayPaint = true
  sim.startArcFire(RecruitIdx)
  sim.startArcFire(LegendIdx)
  let
    recruitCd = sim.players[RecruitIdx].fireCooldown
    legendCd = sim.players[LegendIdx].fireCooldown
  report("spray active+reset armed (startArcFire)",
    $recruitCd, $legendCd,
    recruitCd == SprayPaintActiveTicks + SprayPaintResetTicks and
      legendCd ==
        SprayPaintActiveTicks + SprayPaintResetTicks * 60 div 100 and
      legendCd < recruitCd)

# ── 5. levelGrenadeCharges (a pickup yields 2 at L4+, not 1) ───────────────
block grenadeCharges:
  var sim = pairedGame()
  for idx in [RecruitIdx, LegendIdx]:
    sim.players[idx].x = sim.grenadeSpawns[0].x
    sim.players[idx].y = sim.grenadeSpawns[0].y
    sim.players[idx].aimBrads = 0
  # Two seats can't share one spawn's touch-radius resolution in a single
  # step deterministically, so pick each up in its own tick at its own
  # spawn -- move the recruit off spawn 0 first, then re-home it, mirroring
  # the two independent corner pickups a real 2v2 has.
  let prev = sim.idle()
  sim.step(sim.idle(), prev)  # recruit picks up spawn 0
  sim.players[LegendIdx].x = sim.grenadeSpawns[1].x
  sim.players[LegendIdx].y = sim.grenadeSpawns[1].y
  sim.step(sim.idle(), prev)  # legend picks up spawn 1
  let
    recruitCharges = sim.players[RecruitIdx].grenadeCharges
    legendCharges = sim.players[LegendIdx].grenadeCharges
  report("charges on pickup (tryPickupGrenades)",
    $recruitCharges, $legendCharges,
    recruitCharges == 1 and legendCharges == 2 and legendCharges > recruitCharges)
  # Now prove the SECOND throw only exists for the legend: throw once each
  # (chargeAndThrow pattern -- hold C, release) and check hasGrenade.
  proc throwOnce(sim: var SimServer, idx: int) =
    var inputs = sim.idle()
    inputs[idx] = InputState(c: true)
    sim.step(inputs, sim.idle())
    var released = sim.idle()
    sim.step(released, inputs)  # release C: fires the charged throw
  sim.throwOnce(RecruitIdx)
  sim.throwOnce(LegendIdx)
  report("hasGrenade after ONE throw (throwGrenade)",
    $sim.players[RecruitIdx].hasGrenade, $sim.players[LegendIdx].hasGrenade,
    sim.players[RecruitIdx].hasGrenade == false and
      sim.players[LegendIdx].hasGrenade == true)

# ── 6. levelCarrierSpeedPct (L5 waives the flag-carrier speed tax) ────────
block carrierSpeed:
  var sim = pairedGame()
  sim.players[RecruitIdx].carryingFlag = true
  sim.players[LegendIdx].carryingFlag = true
  # Hold "right" long enough for velocity to saturate at maxSpeed (clamped
  # every tick in applyInput), so the read is the steady-state cap, not a
  # mid-acceleration snapshot.
  var inputs = sim.idle()
  inputs[RecruitIdx] = InputState(right: true)
  inputs[LegendIdx] = InputState(right: true)
  let prev = sim.idle()
  for _ in 0 ..< 60:
    sim.step(inputs, prev)
  let
    recruitVel = sim.players[RecruitIdx].velX
    legendVel = sim.players[LegendIdx].velX
  report("carrier steady-state velX (applyInput)",
    $recruitVel, $legendVel,
    legendVel > recruitVel)

echo ""
if failures == 0:
  echo &"ALL {totalChecks} GLORY LEVEL BUFF CHECKS FIRED IN REAL SIM CODE " &
    &"(six buffs + the battle-royale-s2 arm E maxHp re-check). " &
    &"0/{totalChecks} failures."
else:
  echo &"{failures}/{totalChecks} checks did NOT show the expected paired " &
    "difference."
  quit(1)
