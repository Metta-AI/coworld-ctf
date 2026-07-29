## GV22 machine-readable-label ORACLE: scores the policy's label reads against
## the sim's own fields, tick by tick, in the real fogged headless engine.
##
## WHY THIS EXISTS. The policy has no API into the sim; it finds sprite objects
## by label string. That makes every perception path silently fail-open: a scan
## for a label the engine no longer emits returns an empty seq — no crash, no
## exception, no log line — and the bot simply stops seeing a category of thing.
## That is not hypothetical here. GV22 published two labels (`weapon <token>` and
## `identity <color> <name>[ shield][ nade] <weapon>`) precisely because the
## floating carry markers they replace are unreliable, and the 0.7.x spray-can
## reskin then RENAMED `plasma arc carried` to `spray can carried`, which zeroed
## the policy's old scan on the live engine without a single visible symptom.
##
## So "it compiles and the bots still play" is NOT evidence that a label read
## works. The only evidence is a per-tick comparison against ground truth, which
## is what this probe does:
##
##   SELF WEAPON (`weapon <token>`)   — the read must equal players[me].hasPlasmaArc.
##   ENEMY LOADOUT (`identity ...`)   — for every enemy the bot can actually SEE,
##                                      the arc/shield/nade read must equal that
##                                      player's own fields.
##
## Fog makes the enemy side one-directional: a player we cannot see emits no
## badge, so a MISS on an unseen enemy is correct behaviour, not an error. The
## probe therefore scores only enemies the sim says are visible to us — the same
## `playerVisibleTo` gate the frame builder uses — and reports FALSE NEGATIVES
## (visible but unread) and FALSE POSITIVES (read but not actually held)
## separately. Both must be zero.
##
## Loadouts are GRANTED (not waited for): in a 4000-tick episode most bots never
## touch a corner pickup, so an ungranted run would score the false branch of
## every read thousands of times and the true branch never — a green board that
## proves nothing. Granting exercises both branches on every seat.
##
## Usage:
##   nim c -d:release --opt:speed -d:labelprobe -o:/tmp/labelprobe.out \
##     players/baseline/eval/labelprobe.nim
##   /tmp/labelprobe.out --games 2 --ticks 1200

import std/[os, random, strutils, strformat]
import ./harness_engine

include "../baseline.nim"

type
  Driver = object
    bot: Bot
    client: ProtocolClient
    lastMask: uint8
    navBuilt: bool
    rng: Rand

  Score = object
    ## Every counter is a COMPARISON against the sim, never a bare tally.
    selfChecks: int        # frames the self-weapon read was scored while alive
    selfArmedTruth: int    # ...where the sim says we really hold an arc
    selfWrong: int         # ...where the read disagreed with the sim (MUST be 0)
    selfLabelMissing: int  # frames alive with NO `weapon ` label on the wire at all
    idBadges: int          # `identity` badges attributed to an actor
    seenChecks: int        # (visible enemy, tick) pairs scored
    arcFalseNeg: int       # visible arc carrier we did NOT read as armed (MUST be 0)
    arcFalsePos: int       # read armed but the sim says otherwise      (MUST be 0)
    shieldFalseNeg: int
    shieldFalsePos: int
    nadeFalseNeg: int
    nadeFalsePos: int
    idNamed: int           # visible enemies that came with a stable identity name

proc newDriver(slot, team, episodeSeed: int): Driver =
  let t = (if team == 0: Red else: Blue)
  let role = roleForSeat(clamp(slot div 2, 0, 7), t)
  result.bot = Bot(slot: slot, team: t, role: role, tune: shippedCombatTune())
  result.bot.resetTransient()
  result.client = initProtocolClient()
  result.lastMask = 0xff'u8
  result.navBuilt = false
  result.rng = initRand(slot * 7919 + 1 + episodeSeed * 1_000_003)

proc frame(driver: var Driver, packet: string): uint8 =
  let bot = driver.bot
  let client = driver.client
  if not client.feedInProcessPacket(packet):
    return driver.lastMask
  let adv = max(1, client.frameAdvance)
  bot.tick += adv
  bot.estAim = floorMod(bot.estAim + bot.rotSign * AimRate * adv, AimBrads)
  if not client.mapCameraReady:
    bot.resetTransient()
    return driver.lastMask
  if not driver.navBuilt and client.walkabilityReady:
    bot.buildNavGrid(client)
    driver.navBuilt = true
  randState() = driver.rng
  result = bot.decide(client)
  driver.rng = randState()
  driver.lastMask = result

proc scoreSelfWeapon(
  driver: Driver, truthArmed: bool, score: var Score
) =
  ## Reproduces the SHIPPED self-weapon read (the `weapon <token>` HUD label)
  ## against this driver's retained scene, then scores it on the sim's field.
  let client = driver.client
  var
    labelSeen = false
    readArmed = false
  for (_, label) in client.spriteObjectsWithLabelPrefix(LabelPrefixWeapon):
    let token = label[LabelPrefixWeapon.len .. ^1]
    labelSeen = true
    if token != WeaponTokenGun and token in ArmedWeaponTokens:
      readArmed = true
    break
  if not labelSeen:
    inc score.selfLabelMissing
    return
  inc score.selfChecks
  if truthArmed:
    inc score.selfArmedTruth
  if readArmed != truthArmed:
    inc score.selfWrong

proc scoreEnemyLoadout(
  driver: Driver,
  engine: EvalEngine,
  slot, numPlayers: int,
  score: var Score
) =
  ## Reproduces the SHIPPED enemy-loadout read (actorsFor's `identity` badge
  ## scan) and scores each VISIBLE enemy against the sim. Visibility is taken
  ## from the engine, so an unseen enemy is never counted as a miss.
  let
    client = driver.client
    myTeam = ord(driver.bot.team)
    enemyColor = (if driver.bot.team == Red: "blue" else: "red")
    actors = client.actorsFor(enemyColor, driver.bot.tune.aimRotRead)
  for a in actors:
    if a.idLabel.len > 0:
      inc score.idBadges
  # Pair each VISIBLE enemy with the nearest read actor. The badge is centered on
  # the body, so a visible enemy that produced a badge sits essentially on top of
  # its actor; a generous 40px match keeps the pairing itself from being the thing
  # under test (we are scoring the LOADOUT read, not re-testing attribution).
  for j in 0 ..< numPlayers:
    if engine.teamOfSlot(j) == myTeam:
      continue
    let truth = engine.loadoutOf(j)
    if not truth.alive:
      continue
    if not engine.visibleTo(slot, j):
      continue
    var
      best = -1
      bestD = 40.0
    for i in 0 ..< actors.len:
      let d = dist(actors[i].pos, vec(float(truth.x), float(truth.y)))
      if d < bestD:
        bestD = d
        best = i
    if best < 0:
      continue           # visible but no actor sprite paired: not a LABEL failure
    inc score.seenChecks
    let a = actors[best]
    if a.idLabel.len > 0:
      inc score.idNamed
    if truth.arc and not a.hasArc: inc score.arcFalseNeg
    if a.hasArc and not truth.arc: inc score.arcFalsePos
    if truth.shield and not a.hasShield: inc score.shieldFalseNeg
    if a.hasShield and not truth.shield: inc score.shieldFalsePos
    if truth.nade and not a.hasNade: inc score.nadeFalseNeg
    if a.hasNade and not truth.nade: inc score.nadeFalsePos

proc parseSuite(): int =
  ## Scores the SHIPPED parse procs against literal wire strings — the exact
  ## labels tests/label_manifest.txt says each engine emits. The engine run below
  ## can only exercise the spelling THIS worktree emits (GV22 `arc`); the league
  ## runs the 0.7.x reskin that renamed the token to `spray`, and that rename is
  ## what silently zeroed the old marker scan in the first place. So the live
  ## spelling has to be covered here, statically, or the fix is unverified exactly
  ## where it matters most.
  var fails = 0
  proc expect(cond: bool, what: string) =
    if cond:
      echo "  ok   ", what
    else:
      echo "  FAIL ", what
      inc fails

  echo "--- identity tails ---"
  block:
    let r = parseIdentityLabel("identity blue alpha gun", "blue")
    expect(r.matched and r.id == "blue alpha" and
      not r.shield and not r.nade and not r.arc, "plain gun")
  block:
    let r = parseIdentityLabel("identity blue alpha shield gun", "blue")
    expect(r.matched and r.shield and not r.nade and not r.arc, "shield only")
  block:
    let r = parseIdentityLabel("identity blue alpha nade gun", "blue")
    expect(r.matched and r.nade and not r.shield and not r.arc, "nade only")
  block:
    let r = parseIdentityLabel("identity blue alpha shield nade gun", "blue")
    expect(r.matched and r.shield and r.nade and not r.arc, "shield + nade")
  block:
    let r = parseIdentityLabel("identity blue alpha arc", "blue")
    expect(r.matched and r.arc, "GV22 `arc` armed")
  block:
    let r = parseIdentityLabel("identity blue alpha spray", "blue")
    expect(r.matched and r.arc, "LIVE `spray` armed (the 0.7.x rename)")
  block:
    let r = parseIdentityLabel("identity blue theta shield nade spray", "blue")
    expect(r.matched and r.shield and r.nade and r.arc and r.id == "blue theta",
      "full live loadout")
  echo "--- color isolation (per-color scan must reject the other team) ---"
  block:
    let r = parseIdentityLabel("identity red alpha spray", "blue")
    expect(not r.matched, "red badge rejected by a blue scan")
  block:
    let r = parseIdentityLabel("identity blue alpha spray", "red")
    expect(not r.matched, "blue badge rejected by a red scan")
  echo "--- the identity NAME is never scanned for loadout tokens ---"
  block:
    let r = parseIdentityLabel("identity blue shield gun", "blue")
    expect(r.matched and not r.shield,
      "a name spelling `shield` does not arm hasShield")
  echo "--- own weapon HUD label ---"
  block:
    let r = parseWeaponLabel("weapon gun")
    expect(r.seen and not r.armed, "`weapon gun` -> seen, not armed")
  block:
    let r = parseWeaponLabel("weapon arc")
    expect(r.seen and r.armed, "GV22 `weapon arc` -> armed")
  block:
    let r = parseWeaponLabel("weapon spray")
    expect(r.seen and r.armed, "LIVE `weapon spray` -> armed")
  block:
    let r = parseWeaponLabel("lives 6hp x3")
    expect(not r.seen, "`lives ...` is not mistaken for a weapon label")
  block:
    let r = parseWeaponLabel("weapon trebuchet")
    expect(r.seen and not r.armed,
      "an UNKNOWN weapon token reads as seen-but-not-armed (fail safe: we " &
      "assume the gun works rather than freezing the trigger)")
  fails

proc main() =
  var
    games = 2
    ticks = 1200
    seed = 100
  let p = commandLineParams()
  var i = 0
  while i < p.len:
    case p[i]
    of "--games": inc i; games = parseInt(p[i])
    of "--ticks": inc i; ticks = parseInt(p[i])
    of "--seed": inc i; seed = parseInt(p[i])
    else: discard
    inc i

  echo "=== PARSE SUITE (shipped procs vs literal wire strings) ==="
  let parseFails = parseSuite()

  let numPlayers = 16
  var score = Score()
  for g in 0 ..< games:
    let epSeed = seed + g
    var engine = newEvalEngine(numPlayers, epSeed, ticks)
    var drivers: seq[Driver]
    for s in 0 ..< numPlayers:
      drivers.add newDriver(s, engine.teamOfSlot(s), epSeed)
    # Grant a MIXED loadout so both branches of every read are exercised on every
    # seat, and so the three tokens are independent (a seat with a shield but no
    # nade catches a parser that treats the tail as one blob).
    for s in 0 ..< numPlayers:
      engine.grantLoadout(
        s,
        arc = (s mod 4 == 1),
        shield = (s mod 4 == 2),
        nade = (s mod 3 == 0)
      )
    var tick = 0
    while tick < ticks:
      for s in 0 ..< numPlayers:
        let packet = engine.frameFor(s)
        let mask = drivers[s].frame(packet)
        engine.setMask(s, mask)
      # Score AFTER the frame is fed (the driver's scene is this tick's) but
      # BEFORE advancing, so ground truth and the retained scene are the same tick.
      for s in 0 ..< numPlayers:
        let truth = engine.loadoutOf(s)
        if not truth.alive:
          continue
        drivers[s].scoreSelfWeapon(truth.arc, score)
        drivers[s].scoreEnemyLoadout(engine, s, numPlayers, score)
      engine.advance()
      inc tick
      if engine.result().phaseOver: break
    # Re-grant: the sim clears possession on death/respawn, so a long run would
    # otherwise decay to all-false and stop testing the true branch.
    for s in 0 ..< numPlayers:
      engine.grantLoadout(
        s, arc = (s mod 4 == 1), shield = (s mod 4 == 2), nade = (s mod 3 == 0))

  echo "==================================================="
  echo &"=== ENGINE RUN: {games} games  seed {seed}  ticks {ticks} ==="
  echo &"  parse-suite failures {parseFails}   <-- MUST be 0"
  echo "--- SELF WEAPON (`weapon <token>` HUD label vs sim.hasPlasmaArc) ---"
  echo &"  scored frames      {score.selfChecks}"
  echo &"  ...armed per sim   {score.selfArmedTruth}   " &
    &"(both branches exercised: need > 0 and < scored)"
  echo &"  WRONG              {score.selfWrong}   <-- MUST be 0"
  echo &"  label missing      {score.selfLabelMissing}   " &
    "(frames alive with no `weapon ` label at all)"
  echo "--- ENEMY LOADOUT (`identity` badge vs sim fields, VISIBLE enemies) ---"
  echo &"  badges attributed  {score.idBadges}   <-- MUST be > 0 (else reader is dead)"
  echo &"  visible-enemy scored {score.seenChecks}"
  echo &"  ...with a name     {score.idNamed}"
  echo &"  arc     falseNeg {score.arcFalseNeg}  falsePos {score.arcFalsePos}"
  echo &"  shield  falseNeg {score.shieldFalseNeg}  falsePos {score.shieldFalsePos}"
  echo &"  nade    falseNeg {score.nadeFalseNeg}  falsePos {score.nadeFalsePos}"
  let ok =
    parseFails == 0 and
    score.selfWrong == 0 and score.selfChecks > 0 and
    score.selfArmedTruth > 0 and score.selfArmedTruth < score.selfChecks and
    score.idBadges > 0 and score.seenChecks > 0 and
    score.arcFalseNeg == 0 and score.arcFalsePos == 0 and
    score.shieldFalseNeg == 0 and score.shieldFalsePos == 0 and
    score.nadeFalseNeg == 0 and score.nadeFalsePos == 0
  echo "==================================================="
  echo (if ok: "PASS — every label read matches the sim on both branches"
        else: "FAIL — a label read disagrees with the sim (see nonzero above)")
  if not ok:
    quit(1)

when isMainModule:
  main()
