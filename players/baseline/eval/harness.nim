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
  # COMMS BUS (C1/C2, 2026-07-22, Track B): event-driven scenario codewords over
  # the shout channel. COMMS=1 turns on the full bus (emit + adopt); the per-part
  # knobs bisect it. commsBus emits, commsPlay adopts a heard play (needs playbook),
  # commsCrypto rotates the codeword table. All default OFF (not in shippedCombatTune)
  # so SHIPBASE=1 keeps the champion byte-identical unless a knob moves it. This is a
  # COORDINATION lever: the mirror can only prove no-regression + liveness + graceful
  # degradation — the real edge is a hosted mixed-field xreq (REF-comms). A/B:
  # SHIPBASE=1 COMMS=1 vs CONTROL_SHIPPED=1 (on BOTH seatings).
  let comms2 = envInt("COMMS", 0) != 0
  result.commsBus = envInt("COMMSBUS", (if comms2 or result.commsBus: 1 else: 0)) != 0
  result.commsPlay = envInt("COMMSPLAY", (if comms2 or result.commsPlay: 1 else: 0)) != 0
  result.commsCrypto = envInt("COMMSCRYPTO", (if comms2 or result.commsCrypto: 1 else: 0)) != 0
  # commsPlay extends the playbook flank machinery, so turn playbook on when adopting.
  if result.commsPlay: result.playbook = true
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
  # Carry-conversion forks (2026-07-17, round-624 decode). Each targets ONE of the
  # two field-confirmed carry failures and is NOT in shippedCombatTune (untested),
  # so under SHIPBASE=1 both default OFF — an unset knob keeps the champion, ESCORTRUN
  # /HUNTCARRIER explicitly move them. A/B: SHIPBASE=1 CONTROL_SHIPPED=1 vs +one knob.
  #   ESCORTRUN=1 — the KILL case (ep 3dcdd7eb): interpose on the midfield threat->carrier ray.
  #   HUNTCARRIER=1 — the OUT-RACE case (ep 8b6b080e): keep chasing the exposed enemy carrier.
  result.escortRun    = envInt("ESCORTRUN",   (if result.escortRun: 1 else: 0)) != 0
  result.huntCarrier  = envInt("HUNTCARRIER", (if result.huntCarrier: 1 else: 0)) != 0
  # v14 combat-parity levers ported onto the live engine (2026-07-18). preSlew =
  # "fire first" OODA half-beat: bias target-pick toward the enemy whose gun points
  # most OFF us. staggerFire = staggered bounding: hold to overwatch only when a
  # covering mate's muzzle is down (muzzle-bloom read). Both default OFF (not in
  # shippedCombatTune); unproven on this engine, so A/B before shipping.
  result.preSlew      = envInt("PRESLEW",     (if result.preSlew: 1 else: 0)) != 0
  result.staggerFire  = envInt("STAGGERFIRE", (if result.staggerFire: 1 else: 0)) != 0
  # regroupPush (2026-07-18): post-wipe consolidation — hold a shallow rally when
  # over-extended alone into a cleared enemy half, then push deep with the re-formed
  # wave (fixes the v14 "feed the respawn wave piecemeal" squander). COORDINATION
  # lever: the mirror gives both teams the regroup (benefit cancels) and its clean-
  # wipe trigger barely occurs in self-play — validate on a hosted/asymmetric field.
  result.regroupPush  = envInt("REGROUP",     (if result.regroupPush: 1 else: 0)) != 0
  # grabTiming (2026-07-20, the dive-death finding): hold the unarmed pedestal dive
  # when the pocket is STACKED and a covering mate is inbound (96% of our carrier
  # deaths are at the pedestal, 0% cap in every loss). Default OFF (not in shipped
  # Tune); asymmetric so the mirror measures grab->cap, but the "vs a real stacked
  # defense" edge is field-only. A/B: SHIPBASE=1 GRABTIMING=1 vs CONTROL_SHIPPED=1.
  result.grabTiming   = envInt("GRABTIMING",   (if result.grabTiming: 1 else: 0)) != 0
  # holdLine (2026-07-22, the h006 line-defense finding): the OPPOSITE trigger to
  # regroupPush — rally a shallow wave when over-extended into the enemy half AND a
  # fresh enemy LINE is to our front AND we lack local fire-superiority, so the mid hits
  # the line together instead of trickling in one body at a time to be farmed. Default
  # OFF (not in shippedCombatTune); COORDINATION lever, so the mirror gives both teams
  # the hold and part of the benefit cancels — validate the edge on a hosted/asymmetric
  # field. A/B: SHIPBASE=1 HOLDLINE=1 vs CONTROL_SHIPPED=1 (on BOTH seatings).
  result.holdLine     = envInt("HOLDLINE",     (if result.holdLine: 1 else: 0)) != 0
  # grabGate (2026-07-22, the h006 grab-discipline finding): gate the unarmed pedestal
  # open on LOCAL fire-superiority around the pocket (hold when fresh enemy guns near
  # the pedestal outnumber fresh mates by >= GrabGateDeficit — the diagnosed suicide-grab
  # state, 72-82% of our carriers die there). Default OFF (not in shippedCombatTune);
  # asymmetric so the mirror measures grab->cap. A/B: SHIPBASE=1 GRABGATE=1 vs CONTROL_SHIPPED=1.
  result.grabGate     = envInt("GRABGATE",     (if result.grabGate: 1 else: 0)) != 0
  # medTopOff (2026-07-20, v9 med-kit): a wounded, out-of-contact bot detours to a
  # visible center med kit (heals to full on a 12px touch; a healthy bot never
  # consumes one, so the kit is never wasted). Pure-upside MOVEMENT lever, default
  # OFF (not in shippedCombatTune) so SHIPBASE=1 keeps the champion unless MEDKIT=1
  # turns it on. Asymmetric survival edge (the healthier survivor wins the next
  # contact) so the mirror measures it. A/B: SHIPBASE=1 MEDKIT=1 vs CONTROL_SHIPPED=1.
  result.medTopOff    = envInt("MEDKIT",      (if result.medTopOff: 1 else: 0)) != 0
  # ── SEAL-lens v9 bundle (2026-07-20, the unabsorbed-doctrine backlog top tier).
  # Each defaults OFF (not in shippedCombatTune) so SHIPBASE=1 keeps the champion
  # unless the knob turns it on. A/B: SHIPBASE=1 <KNOB>=1 vs CONTROL_SHIPPED=1.
  #   SATCAP     — distributed-fire saturation cap (backlog #2)
  #   NOMASK     — don't-mask-fires, mover-side (backlog #3)
  #   ASSAULT    — near-ambush assault-through (backlog #6)
  #   OFFCONE    — off-cone approach bearing (backlog #4; needs aimThreat)
  #   FUNNEL     — defensive fatal-funnel pre-aim (backlog #5; mirror-PARTIAL)
  result.satCap         = envInt("SATCAP",  (if result.satCap: 1 else: 0)) != 0
  result.noMask         = envInt("NOMASK",  (if result.noMask: 1 else: 0)) != 0
  result.assaultThrough = envInt("ASSAULT", (if result.assaultThrough: 1 else: 0)) != 0
  result.offCone        = envInt("OFFCONE", (if result.offCone: 1 else: 0)) != 0
  result.fatalFunnel    = envInt("FUNNEL",  (if result.fatalFunnel: 1 else: 0)) != 0
  # AIMROT (2026-07-20): restore ALL aim-intel reads (observedAim resync,
  # mateAimBrads focus-fire rays, enemy aimBrads for aimThreat/preSlew) from
  # the v9 soldier rotation-sprite ids — the "aim dot" labels those reads were
  # built on were RETIRED in GameVersion 7, so the champion has been running
  # the degraded facingRight fallbacks live. Default OFF (not in shipped tune).
  # A/B: SHIPBASE=1 AIMROT=1 vs CONTROL_SHIPPED=1.
  result.aimRotRead     = envInt("AIMROT",  (if result.aimRotRead: 1 else: 0)) != 0
  # counterArc (Play C, GameVersion 15): prioritize a disarmed enemy plasma-arc
  # carrier beyond 136px. Default OFF (not in shippedCombatTune) so SHIPBASE=1
  # keeps the champion unless COUNTERARC=1. Needs dangerScore (sharpens it).
  # A/B: SHIPBASE=1 COUNTERARC=1 vs CONTROL_SHIPPED=1 (full v16), seat-rotated.
  result.counterArc     = envInt("COUNTERARC", (if result.counterArc: 1 else: 0)) != 0
  # v7 sword/shield adaptation (2026-07-19). avoidDisarm is the pure-downside fix
  # (mirror-measurable via SS-PROBE pickup count → ~0); shieldTank/swordAmbush are
  # coordination/positional levers, validate hosted. Knobs reach only HUNTER_SLOTS.
  result.avoidDisarm  = envInt("AVOIDDISARM", (if result.avoidDisarm: 1 else: 0)) != 0
  result.shieldTank   = envInt("SHIELDTANK",  (if result.shieldTank: 1 else: 0)) != 0
  result.swordAmbush  = envInt("SWORDAMBUSH", (if result.swordAmbush: 1 else: 0)) != 0
  # v7 BUNDLE ISOLATION (2026-07-17). These six shipped together in v7 (all true
  # in shippedCombatTune) and won rounds 621/624, but were NEVER A/B'd one at a
  # time — so we can't say which earn their place or bisect a regression. Unlike
  # escortRun/huntCarrier (field-only triggers), these are asymmetric geometry
  # levers the mirror CAN measure. Each defaults to its SHIPPED value, so under
  # SHIPBASE=1 the champion is intact unless a knob explicitly STRIPS one lever.
  # Isolation A/B: candidate = SHIPBASE=1 <KNOB>=0 (champion MINUS that lever),
  # control = CONTROL_SHIPPED=1 (full champion). If the minus-side LOSES on both
  # seatings, the lever earns its place; flat/positive => it doesn't (or hurts).
  result.carrierHomeStretch = envInt("HOMESTRETCH", (if result.carrierHomeStretch: 1 else: 0)) != 0
  result.chaseThief         = envInt("CHASETHIEF",  (if result.chaseThief: 1 else: 0)) != 0
  result.cornerPreAim       = envInt("CORNERAIM",   (if result.cornerPreAim: 1 else: 0)) != 0
  result.sentryDisplace     = envInt("SENTRYDISP",  (if result.sentryDisplace: 1 else: 0)) != 0
  result.topBias            = envInt("TOPBIAS",     (if result.topBias: 1 else: 0)) != 0
  result.playbook           = envInt("PLAYBOOK",    (if result.playbook: 1 else: 0)) != 0

when defined(ohshitprobe):
  var ohshitTotal = 0
  var ohshitEnemyClose = 0   # nearest ENEMY within 95px at emit
  var ohshitMateCloser = 0   # a teammate was closer than the nearest enemy

when defined(ssprobe):
  # v7-only: does the UNADAPTED Picasso bot accidentally grab a sword/shield
  # (auto-pickup on touch => canFire=false, silent disarm)? Count alive-ticks
  # spent holding each, split Red/Blue, plus the number of distinct pickup
  # EVENTS (a rising edge of possession). If these are ~0 the auto-disarm risk
  # is marginal; if material, avoidance is urgent.
  var ssRedSwordTk = 0
  var ssBlueSwordTk = 0
  var ssRedShieldTk = 0
  var ssBlueShieldTk = 0
  var ssRedSwordEv = 0
  var ssBlueSwordEv = 0
  var ssRedShieldEv = 0
  var ssBlueShieldEv = 0
  var ssAliveTk = 0
  var ssPrevSword: array[64, bool]
  var ssPrevShield: array[64, bool]

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
  # TURTLE=1 (2026-07-22): force the CONTROL (non-hunter) team to hold its own half —
  # every control seat becomes a defensive post (HomeDefender / Overwatch spread) so it
  # stays home and lets the HUNTER team over-push into it. NOT a faithful h006, just a
  # standing-line stand-in so we can confirm holdLine's trigger FIRES against a held line
  # (the mirror can't produce a line — both teams attack — so holdLine fires ~0 there).
  # Diagnostic only; win-rate vs a turtle is not a league signal, the HL-PROBE fire is.
  let turtle = envInt("TURTLE", 0) != 0
  var drivers: seq[BotDriver]
  for slot in 0 ..< engine.playerCount():
    let tune = (if slot in hunterSlots: huntTune else: baseTune)
    var d = newDriver(slot, engine.teamOfSlot(slot), seed, tune)
    if turtle and slot notin hunterSlots:
      # Defensive spread over the control team's 8 seats: 3 home-choke guards + 5
      # overwatch posts fanned across the lanes = a body wall in its own half.
      let teamSeat = clamp(slot div 2, 0, 7)
      d.bot.role = (if teamSeat mod 8 in [0, 3, 7]: HomeDefender else: Overwatch)
    drivers.add(d)

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
    when defined(ssprobe):
      for slot in 0 ..< drivers.len:
        let ss = engine.swordShieldOf(slot)
        if not ss.alive: continue
        inc ssAliveTk
        let red = engine.teamOfSlot(slot) == 0
        if ss.sword:
          if red: inc ssRedSwordTk else: inc ssBlueSwordTk
          if not ssPrevSword[slot]:
            if red: inc ssRedSwordEv else: inc ssBlueSwordEv
        if ss.shield:
          if red: inc ssRedShieldTk else: inc ssBlueShieldTk
          if not ssPrevShield[slot]:
            if red: inc ssRedShieldEv else: inc ssBlueShieldEv
        ssPrevSword[slot] = ss.sword
        ssPrevShield[slot] = ss.shield
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
  when defined(hsprobe):
    echo &"  HS-PROBE: carrierHomeStretch fired {hsFireCount}  moved-target {hsMovedCount}  " &
      &"(fire=0 => field-only trigger; fire>0 moved=0 => no-op vs lane path)"
  when defined(rgprobe):
    echo &"  RG-PROBE guard: mid {rgMid} -> noCarry {rgNoCarry} -> noStolen {rgNoStolen} -> reach {rgReach}"
    echo &"  RG-PROBE funnel: reach {rgReach} -> deep {rgDeep} -> vacuum {rgVac} -> " &
      &"lone {rgLone} -> support {rgJoin} -> FIRED {rgFireCount}"
    echo &"    (a stage that zeroes the count names the gating condition; FIRED>0 => gate live)"
  when defined(gtprobe):
    echo &"  GT-PROBE funnel: want {gtWant} -> eligible {gtEligible} -> stacked {gtStacked} -> " &
      &"noCover {gtNoCover} -> FIRED {gtFireCount}"
    echo &"    (want>0 eligible=0 => grabTiming off/pushOut; stacked=0 => mirror pocket never stacks (field-only); FIRED>0 => gate live)"
  when defined(hlprobe):
    echo &"  HL-PROBE funnel: mid {hlMid} -> reach {hlReach} -> deep {hlDeep} -> " &
      &"line {hlLine} -> outgun {hlOutgun} -> support {hlLone} -> FIRED {hlFireCount}"
    echo &"    (deep=0 => never over-extends in mirror; line=0 => no fresh enemy front (vacuum=regroupPush's job); " &
      &"outgun=0 => never locally outgunned (field-only vs a real line); FIRED>0 => gate live)"
  when defined(ggprobe):
    echo &"  GG-PROBE funnel: want {ggWant} -> eligible {ggEligible} -> outgun {ggOutgun} -> FIRED {ggFireCount}"
    echo &"    (want>0 eligible=0 => grabGate off/pushOut/commit-ring; outgun=0 => pocket numbers even in mirror (field-only); FIRED>0 => gate live)"
  when defined(commsprobe):
    echo &"  COMMS-PROBE: classify stack {csStack} wipe {csWipe} peel {csPeel} line {csLine} -> " &
      &"EMIT {csEmit} -> HEARD {csHeard} -> ADOPT {csAdopt} -> WIPE-ARM {csWipeArm} " &
      &"LINE-ARM {csLineArm} NADE-CLUSTER {csNadeLine}"
    echo &"    (classify>0 => the scenario read fires (incl. LINE = standing enemy line); EMIT>0 => " &
      &"codewords broadcast; HEARD>0 => mates decode them; ADOPT>0 => a heard play drove a mate's flank; " &
      &"WIPE-ARM/LINE-ARM>0 => a HEARD wipe/line armed a mate's rally it never saw itself; " &
      &"NADE-CLUSTER>0 => a grenade carrier lobbed at a multikill cluster — the full bus is LIVE + " &
      &"COORDINATING combined-arms. Mirror = liveness+no-regression only; win-credit is a hosted xreq.)"
  when defined(mtprobe):
    echo &"  MT-PROBE funnel: on {mtOn} -> wounded {mtWounded} -> safe {mtSafe} -> " &
      &"free {mtFree} -> kitVisible {mtVisible} -> FIRED {mtFireCount}"
    echo &"    (wounded=0 => bots rarely survive hurt; safe=0 => always in contact when hurt; " &
      &"kitVisible=0 => fog hides the kit (field-only); FIRED>0 => detour live)"
  when defined(arprobe):
    echo &"  AR-PROBE: frames {arFrames}  selfRead {arSelfRead} (resync {arResync})  " &
      &"enemy {arEnemyRead}/{arEnemySeen}  mate {arMateRead}/{arMateSeen}"
    echo &"    (enemyRead=0 => the sprite-id pool moved (re-verify RotPlayerSpriteBase); " &
      &"read>0 => aim intel is BACK on the dot-less engine)"
  when defined(caprobe):
    echo &"  CA-PROBE: arcAttrib {caArcAttrib}  seen {caSeen}  bump {caBump}"
    echo &"    (arcAttrib=0 => no plasma-arc carrier ever occurs in self-play (lever " &
      &"field-only, expected in mirror); bump>0 => a disarmed carrier got the credit)"
  when defined(nmprobe):
    echo &"  NM-PROBE: navFrames {nmNavFrames}  supportRays {nmRays}  repel {nmRepel}"
    echo &"    (rays=0 => no live mate gun-line ever forms (mateGunDown/aim-read dead); " &
      &"repel>0 => movers actually bend off the corridor — lever live)"
  when defined(ocprobe):
    echo &"  OC-PROBE funnel: advance {ocAdvance} -> coneRead {ocConeRead} -> " &
      &"onUs {ocOnUs} -> BEND {ocBend}"
    echo &"    (coneRead=0 => enemy bearing channel dead (needs AIMROT); onUs=0 => cone " &
      &"never on the closer; BEND>0 => the approach actually bends — lever live)"
  when defined(asprobe):
    echo &"  AS-PROBE funnel: surprise {asSurprise} -> gunOnMe {asGunOnMe} -> " &
      &"committed {asNoCover} -> chargeFrames {asCharge}"
    echo &"    (surprise=0 => near-ambushes never happen in the mirror; committed=0 => " &
      &"cover was always nearer (duck stays right); chargeFrames>0 => lever live)"
  when defined(ffprobe):
    echo &"  FF-PROBE funnel: hold {ffHold} -> idle {ffIdle} -> preLay {ffPreLay}"
    echo &"    (idle=0 => a sentry always has a fresh track (sweep keeps the job); " &
      &"preLay>0 => the turret actually parks on the throat — lever live)"
  when defined(scprobe):
    echo &"  SC-PROBE funnel: engaged {scEngaged} -> satSeen {scSatSeen} -> " &
      &"redirect {scRedirect} / dogpile {scDogpile}"
    echo &"  SC-PROBE coverage (candidate evals): cov1 {scCov1}  cov2 {scCov2}  hp1 {scHp1}"
    echo &"  SC-PROBE dot-read: mateFresh {scMateFresh} -> read {scMateRead} -> rayHit {scRayHit}"
    echo &"    (satSeen=0 => pair-saturation never occurs in range (lever inert); " &
      &"redirect>0 => the cap actually spreads fire; dogpile = commit-held or lone target; " &
      &"cov1>0 cov2=0 => a PAIR of readable mate lines never forms — threshold unreachable)"
  when defined(ssprobe):
    let
      swPerK = (if ssAliveTk > 0: 1000.0 * (ssRedSwordTk + ssBlueSwordTk).float / ssAliveTk.float else: 0.0)
      shPerK = (if ssAliveTk > 0: 1000.0 * (ssRedShieldTk + ssBlueShieldTk).float / ssAliveTk.float else: 0.0)
    echo &"  SS-PROBE alive-ticks {ssAliveTk}"
    echo &"  SS-PROBE sword  held-ticks RED {ssRedSwordTk} BLUE {ssBlueSwordTk}  " &
      &"pickups RED {ssRedSwordEv} BLUE {ssBlueSwordEv}  ({swPerK:.2f} disarmed-ticks per 1k alive)"
    echo &"  SS-PROBE shield held-ticks RED {ssRedShieldTk} BLUE {ssBlueShieldTk}  " &
      &"pickups RED {ssRedShieldEv} BLUE {ssBlueShieldEv}  ({shPerK:.2f} disarmed-ticks per 1k alive)"
    echo &"    (accidental pickups on the UNADAPTED bot => canFire=false. High => avoidance urgent.)"
    echo &"  SS-PROBE levers: avoid-repel-frames {ssAvoidActive}  tank-seek {ssTankSeek}  " &
      &"ambush-seek {ssAmbushSeek}  ambush-swing {ssAmbushSwing}"
    echo &"    (proves the gated v7 levers are LIVE code: >0 => firing even when grabs are ~0)"

when isMainModule and not defined(tuneCheck):
  main()
