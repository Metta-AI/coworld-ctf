## Headless in-process A/B eval harness for Coworld CTF.
##
## Runs a full 8v8 game with no websocket, no real-time clock: the engine
## wrapper builds each slot's real fogged sprite packet, this driver feeds it
## into a real ProtocolClient and runs the SHIPPED baseline `decide()` — the
## byte-identical decision path — then steps the sim. Reports per-team kills /
## captures / shots / wins so it is BOTH the "do they actually hit" accuracy
## proof AND the A/B rig (control = baseline on both sides).
##
## The baseline player module is `include`d (not imported) so this driver sees
## its private `Bot`, `decide`, `roleForSeat`, `spawnAim`, and the per-frame
## bookkeeping constants (`AimRate`, `AimBrads`) WITHOUT editing the shipped
## file. Its `when isMainModule` block stays dormant here. The engine lives
## behind `harness_engine`, whose primitive-typed surface keeps the engine's
## `Team`/`enemy`/`flagHome` from colliding with the baseline's own.
##
## Usage:
##   nim c -d:release --opt:speed -o:players/baseline/eval/harness.out \
##     players/baseline/eval/harness.nim
##   ./players/baseline/eval/harness.out --games 20 --seed 7 --ticks 10000
##
## Env knobs let a forked "hunter" A/B against baseline without a rebuild:
##   HUNTER_SLOTS="0,2,4,..."  -> which slots run the hunter policy (Red seats
##                                are even). Unset => all-baseline control run.

import std/[os, random, strutils, strformat, math]
import ./harness_engine

# The shipped baseline bot, included verbatim. `isMainModule` is false here so
# its runBot entrypoint never fires; we drive `decide` directly.
include "../baseline.nim"

var
  campTicksRed = 0        ## diagnostic: ticks a RED bot spent frozen (<0.8px
  campTicksBlue = 0       ## moved) while holding a live enemy track — the
                          ## "grind a corner / camp" pathology, tallied per team.

type
  BotDriver = object
    bot: Bot
    client: ProtocolClient
    lastMask: uint8
    navBuilt: bool
    rng: Rand              ## this bot's OWN RNG stream, isolated per slot.

proc newDriver(slot, team, episodeSeed: int, tune: CombatTune): BotDriver =
  ## Mirrors runBot's setup for one seat: role from seat, a fresh
  ## ProtocolClient, transient reset, and — critically — a PER-BOT RNG.
  ##
  ## Hosted bots run as SEPARATE processes with independent streams
  ## (`randomize(slot*7919+1)`); giving each driver its own `Rand` (swapped
  ## into the global around `decide`) reproduces that isolation, so one bot's
  ## draws never perturb another's — the interleaving a single shared global
  ## stream would introduce.
  ##
  ## CTF gameplay is fully input-deterministic (the sim's own `rng` field is
  ## never consumed), and the bots seed by SLOT only — so a fixed seating
  ## replays bit-identically every episode. To get per-episode variety for a
  ## statistically meaningful batch WITHOUT breaking the paired A/B (both the
  ## baseline control and a hunter must face IDENTICAL conditions so only the
  ## swapped decisions differ), the episode seed salts every seat's stream.
  ## Team: 0 Red / 1 Blue.
  let t = (if team == 0: Red else: Blue)
  let role = roleForSeat(clamp(slot div 2, 0, 7), t)
  result.bot = Bot(slot: slot, team: t, role: role, tune: tune)
  result.bot.resetTransient()
  result.client = initProtocolClient()
  result.lastMask = 0xff'u8
  result.navBuilt = false
  result.rng = initRand(slot * 7919 + 1 + episodeSeed * 1_000_003)

proc frame(driver: var BotDriver, packet: string): uint8 =
  ## One frame for one bot: feed the packet, run runBot's per-frame preamble
  ## (tick advance, aim dead-reckon, lobby gate, nav build), then `decide`.
  ## Returns the chosen button mask (level mask, same as the live wire value).
  let bot = driver.bot
  let client = driver.client
  if not client.feedInProcessPacket(packet):
    return driver.lastMask                 # malformed frame: hold last input.
  let advance = max(1, client.frameAdvance)
  bot.tick += advance
  bot.estAim = floorMod(bot.estAim + bot.rotSign * AimRate * advance, AimBrads)
  if not client.mapCameraReady:
    bot.resetTransient()                   # lobby / game-over interstitial.
    return driver.lastMask
  if not driver.navBuilt and client.walkabilityReady:
    bot.buildNavGrid(client)
    driver.navBuilt = true
  # Swap this bot's private RNG into the global stream `decide` draws from,
  # then save it back — each seat consumes its OWN sequence (buildNavGrid above
  # is rand-free, so it needs no swap).
  randState() = driver.rng
  result = bot.decide(client)
  driver.rng = randState()
  driver.lastMask = result
  # Diagnostic: is this bot frozen (~0.6s of no movement) while it holds a
  # fresh enemy track? That is the "grind a corner / camp while it has someone
  # to shoot" pathology. decide() maintains stuckTicks; a fresh enemy is one
  # seen within FreshShotTicks.
  if bot.stuckTicks >= 15:
    for t in bot.enemies:
      if bot.tick - t.lastSeen <= FreshShotTicks:
        if bot.team == Red: inc campTicksRed else: inc campTicksBlue
        break

proc parseSlotSet(spec: string): seq[int] =
  for part in spec.split(','):
    let s = part.strip()
    if s.len > 0:
      result.add(parseInt(s))

proc envFloat(name: string, dflt: float): float =
  let v = getEnv(name)
  if v.len > 0: parseFloat(v.strip()) else: dflt

proc envInt(name: string, dflt: int): int =
  let v = getEnv(name)
  if v.len > 0: parseInt(v.strip()) else: dflt

proc hunterTune(): CombatTune =
  ## The hunter's fire/engage knobs. Starts from the baseline default and
  ## sharpens the FIRE DISCIPLINE that the ground-truth diagnosis blamed for
  ## the ~80% miss rate: (1) stop shooting at stale linearly-extrapolated
  ## phantoms of juking targets, (2) require the aim to settle tighter inside
  ## the 14px corridor before pulling. Every field is overridable by an env
  ## var (HUNT_* ) so hypotheses A/B without a rebuild. Defaults below encode
  ## the leading hypothesis; a control-vs-hunter run isolates their effect.
  # SHIPBASE=1 starts the hunter from the SHIPPED v3 champion (commit + aimLock +
  # unstuckEngaged + carrierGrabDetect) instead of the pure baseline, so a v4 A/B
  # can layer ONLY the new SEAL4 levers on top of v3 — the candidate = v3 + v4,
  # the control = v3 (CONTROL_SHIPPED=1), so the run isolates the v4 delta alone.
  result = (if envInt("SHIPBASE", 0) != 0: shippedCombatTune() else: defaultCombatTune())
  # Knob sweep (both directions of fire-discipline were falsified 2026-07-14 —
  # defaults now sit at the baseline so a SMART run isolates the LOGIC change).
  result.freshShotTicks = envInt("HUNT_FRESH", FreshShotTicks)
  result.fireSlackPx = envFloat("HUNT_SLACK", FireSlackPx)
  result.leadTicks = envFloat("HUNT_LEAD", LeadTicks)
  result.combatDeadband = envInt("HUNT_DEAD", CombatDeadband)
  result.fireRange = envFloat("HUNT_RANGE", FireRange)
  # Fork 1 — target commitment. SMART=1 turns it on; HUNT_COMMIT sweeps the
  # priority credit for the locked target. The default is the value ALREADY in
  # `result` — so under SHIPBASE=1 (start = v3 champion) an unset SMART keeps the
  # shipped commit=true instead of silently reverting it to baseline. (This
  # reverts the void v4 run where SHIPBASE=1 still stripped the v3 core because
  # SMART/AIMLOCK/UNSTUCK/GRABFIX defaulted to 0.)
  result.commit = envInt("SMART", (if result.commit: 1 else: 0)) != 0
  result.commitBonus = envFloat("HUNT_COMMIT", CommitBonus)
  # Fork 2 — local force balance ("don't feed a 1-vs-N"). BALANCE=1 turns it
  # on; HUNT_MARGIN sweeps the outnumber threshold (2 => retreat at 1v3 / 2v4).
  result.forceBalance = envInt("BALANCE", 0) != 0
  result.outnumberMargin = envInt("HUNT_MARGIN", OutnumberMargin)
  # Fork 3 — corner-grind BUG FIX: allow the stuck-jink to fire while engaged.
  # Default = the value already in `result` (shipped=true under SHIPBASE=1).
  result.unstuckEngaged = envInt("UNSTUCK", (if result.unstuckEngaged: 1 else: 0)) != 0
  # SEAL gunfighter forks (2026-07-14). SEAL=1 turns the whole bundle on; each
  # also has its own env override so an A/B can isolate a single lever. aimLock
  # defaults to its shipped value so SHIPBASE=1 keeps the v3 lock unless SEAL/
  # AIMLOCK explicitly moves it.
  let seal = envInt("SEAL", 0) != 0
  result.aimLock = envInt("AIMLOCK", (if seal or result.aimLock: 1 else: 0)) != 0
  result.huntSweep = envInt("HUNT", (if seal: 1 else: 0)) != 0
  result.fireOnRealBody = envInt("REALBODY", (if seal: 1 else: 0)) != 0
  result.threatFacingBonus = envInt("THREATFACE", (if seal: 1 else: 0)) != 0
  result.unstuckEngaged = result.unstuckEngaged or seal
  # Comms + awareness forks (2026-07-15). SHOUT=1 turns the whole bundle on
  # (emit + react + callouts + oh-shit + die + damage-aware); each lever also
  # has its own env override so an A/B isolates one at a time. shout is the
  # master EMIT switch; reactContact is the master RECEIVE switch. The Picasso
  # champion (shippedCombatTune) still runs with all of these OFF until an A/B
  # proves one, so control vs SHOUT run isolates the whole comms layer.
  let comms = envInt("SHOUT", 0) != 0
  # Each shout flag defaults to its SHIPPED value (the vanity emitters shout/
  # shoutSurprise/shoutDie are ON in the v4 champion), so SHIPBASE=1 KEEPS them
  # unless SHOUT/the per-flag knob moves it — same void-A/B fix as the v3 core
  # and SEAL4 levers. shoutCallout (strategic) stays shipped-off.
  result.shout = envInt("SHOUT_EMIT", (if comms or result.shout: 1 else: 0)) != 0
  result.shoutCallout = envInt("SHOUT_CALLOUT", (if comms or result.shoutCallout: 1 else: 0)) != 0
  result.shoutSurprise = envInt("SHOUT_SURPRISE", (if comms or result.shoutSurprise: 1 else: 0)) != 0
  result.shoutDie = envInt("SHOUT_DIE", (if comms or result.shoutDie: 1 else: 0)) != 0
  result.reactContact = envInt("REACT", (if comms: 1 else: 0)) != 0
  result.damageAware = envInt("DMGAWARE", (if comms: 1 else: 0)) != 0
  # Shout-reaction GATE fork (2026-07-16). CALLGATE=1 turns the distraction bar
  # on: a heard callout still SEEDS the enemy track (intel is always banked), but
  # the REACTION (turn the cone / move the feet) must clear a task-priority gate —
  # a committed carrier/grabber banks and keeps going, only a free gun chases.
  # Requires REACT (something to gate). Default = shipped value, so SHIPBASE=1
  # keeps whatever the champion runs unless CALLGATE explicitly moves it.
  result.calloutGate = envInt("CALLGATE", (if result.calloutGate: 1 else: 0)) != 0
  # Aim-dot threat (2026-07-16, task #19). AIMTHREAT=1 replaces the coarse
  # facingRight half-plane in the dangerScore block with a precise gun-on-me cone
  # read from the enemy's aim-dot line. Mirror-measurable (both teams render aim
  # dots). Default = shipped value so SHIPBASE=1 keeps the champion unless
  # AIMTHREAT moves it; requires DANGER (dangerScore) on to have a block to sharpen.
  result.aimThreat = envInt("AIMTHREAT", (if result.aimThreat: 1 else: 0)) != 0
  # Capture-conversion fork (2026-07-15). CARRIERFLEE=1: a carrier keeps moving
  # home while engaged instead of advancing into a point-blank enemy — targets
  # the drop@home~2% leak (carriers die AT the robbed pedestal, in the respawn
  # nest). Isolated so an A/B measures grab->cap% directly.
  result.carrierFlee = envInt("CARRIERFLEE", 0) != 0
  # CLEARBAND=1: carrier clears the respawn firing band (pedestal height ±84)
  # vertically before the home run, and never picks a lane inside it. Targets
  # the drop@home~4% death (carriers killed AT the robbed pedestal by fresh
  # invulnerable respawners aimed E-W). Isolated for a direct grab->cap% A/B.
  result.carrierClearBand = envInt("CLEARBAND", 0) != 0
  # SPRINT=1: carrier NEVER enters combat (engage 0). Survival instrumentation
  # showed carriers live ~110t but travel ~4% of the run — PINNED firing at the
  # invulnerable spawn-protected respawner (wasted shots) while advancing into
  # the nest instead of running. Drop combat: pure-navigate home at full speed.
  # FALSIFIED (net -3): the gun buys survival; a pure runner dies faster.
  result.carrierSprint = envInt("SPRINT", 0) != 0
  # SCREEN=1: the rear escort body-blocks the respawn cone at the carrier's EXACT
  # y (one body toward the robbed pocket) so the invulnerable respawner's shot
  # kills the ESCORT, not the carrier. The one mechanism the self-play mirror
  # can't cancel — a friendly body on the ray is physics. Coordination lever.
  result.carrierScreen = envInt("SCREEN", 0) != 0
  # GRABFIX=1: the wakeup deadlock fix. The self-carry test only fired when the
  # heart was >16px off its pedestal; a carrier standing ON the robbed pedestal
  # keeps the heart ~7px away so iCarry stayed FALSE and the bot camped the
  # pedestal it already robbed until timeout (hosted replays: our carrier frozen
  # at the enemy pedestal 67-75% of a game -> a DRAW that should have been a win).
  # Recognize carry via the auto-pickup invariant (living player in pickup range
  # of an un-carried pedestal heart is instantly the carrier). Asymmetric fix, so
  # a seat-rotated self-play A/B CAN measure it (unlike the six combat levers).
  # Default = shipped value, so SHIPBASE=1 keeps the v3 grabfix unless GRABFIX
  # explicitly overrides it.
  result.carrierGrabDetect = envInt("GRABFIX", (if result.carrierGrabDetect: 1 else: 0)) != 0
  # SEAL/CQB v4 bundle (2026-07-16). SEAL4=1 turns the whole set on; each lever
  # also has its own env override so a regression can be bisected without a
  # rebuild. The Picasso v4 champion runs all six ON together (shippedCombatTune),
  # so each defaults to its SHIPPED value: SHIPBASE=1 KEEPS the v4 levers unless
  # SEAL4/the per-lever knob explicitly moves it. (Same void-A/B fix as the v3
  # core knobs — a "start from shipped then override" default of 0 would silently
  # STRIP the six levers from the candidate that claims to build on them.)
  let seal4 = envInt("SEAL4", 0) != 0
  result.dangerScore       = envInt("DANGER",   (if seal4 or result.dangerScore: 1 else: 0)) != 0
  result.twoSpeedScan      = envInt("TWOSCAN",  (if seal4 or result.twoSpeedScan: 1 else: 0)) != 0
  result.boundingOverwatch = envInt("BOUND",    (if seal4 or result.boundingOverwatch: 1 else: 0)) != 0
  result.pointOfDomination = envInt("DOMINATE", (if seal4 or result.pointOfDomination: 1 else: 0)) != 0
  result.tempoPress        = envInt("TEMPO",    (if seal4 or result.tempoPress: 1 else: 0)) != 0
  result.fireSuperiority   = envInt("FIRESUP",  (if seal4 or result.fireSuperiority: 1 else: 0)) != 0
  # nadeEcon (2026-07-29): the static-coord grenade-corner routing. Defaults to its
  # SHIPPED value so SHIPBASE=1 neither strips nor injects it — NADEECON=1 adds the
  # lever to a candidate, NADEECON=0 strips it for an isolation run.
  result.nadeEcon = envInt("NADEECON", (if result.nadeEcon: 1 else: 0)) != 0

when defined(ohshitprobe):
  var ohshitTotal = 0
  var ohshitEnemyClose = 0   # nearest ENEMY within 95px at emit
  var ohshitMateCloser = 0   # a teammate was closer than the nearest enemy

proc runEpisode(seed, maxTicks, numPlayers: int, hunterSlots: seq[int]):
    EpisodeResult =
  ## Runs one headless game. Seats listed in hunterSlots run the HUNTER tune
  ## (sharpened fire discipline); every other seat runs the baseline default.
  ## With no hunterSlots this is the all-baseline control (byte-identical to
  ## the shipped decide), so paired seeds isolate the hunter's fire discipline.
  let
    engine = newEvalEngine(numPlayers, seed, maxTicks)
    huntTune = hunterTune()
  # CONTROL_SHIPPED=1 makes the CONTROL side the full SHIPPED v3 champion, so a
  # v4 A/B pits (v3 + SEAL4) against v3 alone — the ONLY delta is the six new
  # levers. Takes precedence over CONTROL_COMMIT.
  var baseTune =
    if envInt("CONTROL_SHIPPED", 0) != 0: shippedCombatTune()
    else: defaultCombatTune()
  # CONTROL_COMMIT=1 gives the CONTROL side target commitment too, so an A/B
  # isolates a NEW fork (e.g. force balance) as the ONLY delta from the current
  # shipped Picasso (which already runs commit). Left off => pure-baseline control.
  if envInt("CONTROL_COMMIT", 0) != 0:
    baseTune.commit = true
  var drivers: seq[BotDriver]
  for slot in 0 ..< engine.playerCount():
    let tune = (if slot in hunterSlots: huntTune else: baseTune)
    drivers.add(newDriver(slot, engine.teamOfSlot(slot), seed, tune))

  var tick = 0
  while engine.isPlaying() and tick < maxTicks:
    for slot in 0 ..< drivers.len:
      let packet = engine.frameFor(slot)
      let mask = drivers[slot].frame(packet)
      engine.setMask(slot, mask)
      # Forward any shout the bot staged this frame, exactly as runBot's WS loop
      # sends chatBlob(shoutWant): the sim buffers it and delivers it to audible
      # mates on the next frame build. Clearing mirrors the shipped path.
      when defined(ohshitprobe):
        if drivers[slot].bot.shoutWant == "oh shit!":
          let (nE, nM) = engine.nearestEnemyMate(slot)
          inc ohshitTotal
          if nE <= 95.0: inc ohshitEnemyClose
          if nM < nE: inc ohshitMateCloser
      if drivers[slot].bot.shoutWant.len > 0:
        engine.applyShout(slot, drivers[slot].bot.shoutWant)
        drivers[slot].bot.shoutWant = ""
    engine.advance()
    inc tick
  result = engine.result()

proc main() =
  var
    games = 10
    baseSeed = 7
    maxTicks = 10000
    numPlayers = 16
  let hunterSlots = parseSlotSet(getEnv("HUNTER_SLOTS"))

  var i = 1
  let params = commandLineParams()
  while i <= params.len:
    let a = params[i - 1]
    case a
    of "--games": inc i; games = parseInt(params[i - 1])
    of "--seed": inc i; baseSeed = parseInt(params[i - 1])
    of "--ticks": inc i; maxTicks = parseInt(params[i - 1])
    of "--players": inc i; numPlayers = parseInt(params[i - 1])
    else: discard
    inc i

  echo &"CTF eval harness: games={games} baseSeed={baseSeed} " &
    &"maxTicks={maxTicks} players={numPlayers} " &
    &"hunterSlots={(if hunterSlots.len == 0: \"none (control)\" else: $hunterSlots)}"
  if hunterSlots.len > 0:
    let h = hunterTune()
    echo &"  hunter tune: fresh={h.freshShotTicks} slack={h.fireSlackPx} " &
      &"lead={h.leadTicks} dead={h.combatDeadband} range={h.fireRange} " &
      &"commit={h.commit} commitBonus={h.commitBonus} " &
      &"forceBalance={h.forceBalance} margin={h.outnumberMargin}"
  echo "seed  ticks  over  winner  redK blueK  redC blueC  redS blueS  " &
    "redHit% blueHit%"

  var
    redWins = 0
    blueWins = 0
    draws = 0
    unfinished = 0
    totRedK, totBlueK, totRedC, totBlueC, totRedS, totBlueS: int
    totRedD, totBlueD, totRedL, totBlueL: int
    totRedG, totBlueG: int
    totRedDropProg, totBlueDropProg: float
    totRedDropN, totBlueDropN: int
    totRedSurv, totBlueSurv: int
    totRedSurvN, totBlueSurvN: int
  for g in 0 ..< games:
    let seed = baseSeed + g
    let r = runEpisode(seed, maxTicks, numPlayers, hunterSlots)
    let
      redHit = (if r.redShots > 0: 100.0 * r.redKills.float / r.redShots.float else: 0.0)
      blueHit = (if r.blueShots > 0: 100.0 * r.blueKills.float / r.blueShots.float else: 0.0)
      winner =
        if not r.phaseOver: "unfin"
        elif r.isDraw: "draw"
        elif r.winnerTeam == 0: "RED"
        else: "BLUE"
    echo &"{seed:>4}  {r.ticks:>5}  {r.phaseOver:>4}  {winner:>6}  " &
      &"{r.redKills:>4} {r.blueKills:>5}  {r.redCaptures:>4} {r.blueCaptures:>5}  " &
      &"{r.redShots:>4} {r.blueShots:>5}  {redHit:>6.1f} {blueHit:>7.1f}"
    if not r.phaseOver: inc unfinished
    elif r.isDraw: inc draws
    elif r.winnerTeam == 0: inc redWins
    else: inc blueWins
    totRedK += r.redKills; totBlueK += r.blueKills
    totRedD += r.redDeaths; totBlueD += r.blueDeaths
    totRedL += r.redLives; totBlueL += r.blueLives
    totRedC += r.redCaptures; totBlueC += r.blueCaptures
    totRedS += r.redShots; totBlueS += r.blueShots
    totRedG += r.redGrabs; totBlueG += r.blueGrabs
    totRedDropProg += r.redDropProgSum; totBlueDropProg += r.blueDropProgSum
    totRedDropN += r.redDropCount; totBlueDropN += r.blueDropCount
    totRedSurv += r.redSurvivalSum; totBlueSurv += r.blueSurvivalSum
    totRedSurvN += r.redSurvivalCount; totBlueSurvN += r.blueSurvivalCount

  let
    tRedHit = (if totRedS > 0: 100.0 * totRedK.float / totRedS.float else: 0.0)
    tBlueHit = (if totBlueS > 0: 100.0 * totBlueK.float / totBlueS.float else: 0.0)
    decisive = redWins + blueWins
    # GameVersion 2 scoring: +1 to every winner, -1 to every loser, 0 on a
    # draw. Per team the LEAGUE score is simply (wins - losses); K-D and lives
    # award NOTHING now (the timeout tiebreak was removed), so they are printed
    # only as diagnostics below the score.
    redScore = redWins - blueWins
    blueScore = blueWins - redWins
  echo ""
  echo &"TOTals over {games} games:"
  echo &"  SCORE:    RED {redScore:+d}  BLUE {blueScore:+d}  " &
    &"(win-only: +1 win / -1 loss / 0 draw — THE leaderboard metric)"
  echo &"  results:  RED wins {redWins}  BLUE wins {blueWins}  " &
    &"draw {draws}  unfinished {unfinished}  ({decisive}/{games} decisive)"
  echo &"  wins by:  capture RED {totRedC} BLUE {totBlueC}  " &
    &"(rest of the {decisive} decisive games were WIPES)"
  let
    redConv = (if totRedG > 0: 100.0 * totRedC.float / totRedG.float else: 0.0)
    blueConv = (if totBlueG > 0: 100.0 * totBlueC.float / totBlueG.float else: 0.0)
  echo &"  grabs:    RED {totRedG}  BLUE {totBlueG}  " &
    &"(heart pickups — the capture funnel's mouth)"
  echo &"  grab->cap:RED {redConv:.1f}%  BLUE {blueConv:.1f}%  " &
    &"(pickups that became a winning capture — daveey's edge is HERE)"
  let
    redDropAt = (if totRedDropN > 0: totRedDropProg / totRedDropN.float else: 0.0)
    blueDropAt = (if totBlueDropN > 0: totBlueDropProg / totBlueDropN.float else: 0.0)
  echo &"  drop@home:RED {redDropAt * 100:.0f}%  BLUE {blueDropAt * 100:.0f}%  " &
    &"(mean run-home % where a carrier was killed; 0=at robbed pedestal, 100=own edge; " &
    &"n RED {totRedDropN} BLUE {totBlueDropN})"
  let
    redSurv = (if totRedSurvN > 0: totRedSurv.float / totRedSurvN.float else: 0.0)
    blueSurv = (if totBlueSurvN > 0: totBlueSurv.float / totBlueSurvN.float else: 0.0)
  echo &"  survive:  RED {redSurv:.0f}t  BLUE {blueSurv:.0f}t  " &
    &"(mean ticks a carrier LIVED after grabbing before a non-scoring death; " &
    &"few ticks = dies IN the nest, not en route; n RED {totRedSurvN} BLUE {totBlueSurvN})"
  echo "  --- diagnostics (award NO points under v2, for analysis only) ---"
  echo &"  kills:    RED {totRedK}  BLUE {totBlueK}"
  echo &"  deaths:   RED {totRedD}  BLUE {totBlueD}"
  echo &"  K-D diff: RED {totRedK - totRedD:+d}  BLUE {totBlueK - totBlueD:+d}"
  echo &"  lives end:RED {totRedL}  BLUE {totBlueL}"
  echo &"  shots:    RED {totRedS}  BLUE {totBlueS}"
  echo &"  hit rate: RED {tRedHit:.2f}%  BLUE {tBlueHit:.2f}%"
  echo &"  camp-ticks (frozen w/ live target): RED {campTicksRed}  BLUE {campTicksBlue}"
  when defined(ohshitprobe):
    let mis = (if ohshitTotal > 0: 100.0 * ohshitMateCloser.float / ohshitTotal.float else: 0.0)
    let good = (if ohshitTotal > 0: 100.0 * ohshitEnemyClose.float / ohshitTotal.float else: 0.0)
    echo &"  OHSHIT-PROBE: {ohshitTotal} 'oh shit!'  enemy<=95px {ohshitEnemyClose} ({good:.0f}%)  " &
      &"mate-closer {ohshitMateCloser} ({mis:.0f}% = MISFIRES)"

when isMainModule and not defined(tuneCheck):
  main()
