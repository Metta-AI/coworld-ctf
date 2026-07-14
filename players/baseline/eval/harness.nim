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
  result = defaultCombatTune()
  result.freshShotTicks = envInt("HUNT_FRESH", 10)     # was 24: don't fire at ~>0.4s-old tracks
  result.fireSlackPx = envFloat("HUNT_SLACK", 7.0)     # was 11: tighter corridor settle
  result.leadTicks = envFloat("HUNT_LEAD", 7.0)        # was 6: lead a touch more through windup
  result.combatDeadband = envInt("HUNT_DEAD", 2)       # was 2: aim-settle tolerance
  result.fireRange = envFloat("HUNT_RANGE", FireRange) # keep map-wide engage by default

proc runEpisode(seed, maxTicks, numPlayers: int, hunterSlots: seq[int]):
    EpisodeResult =
  ## Runs one headless game. Seats listed in hunterSlots run the HUNTER tune
  ## (sharpened fire discipline); every other seat runs the baseline default.
  ## With no hunterSlots this is the all-baseline control (byte-identical to
  ## the shipped decide), so paired seeds isolate the hunter's fire discipline.
  let
    engine = newEvalEngine(numPlayers, seed, maxTicks)
    baseTune = defaultCombatTune()
    huntTune = hunterTune()
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
      &"lead={h.leadTicks} dead={h.combatDeadband} range={h.fireRange}"
  echo "seed  ticks  over  winner  redK blueK  redC blueC  redS blueS  " &
    "redHit% blueHit%"

  var
    redWins = 0
    blueWins = 0
    draws = 0
    unfinished = 0
    totRedK, totBlueK, totRedC, totBlueC, totRedS, totBlueS: int
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
    totRedC += r.redCaptures; totBlueC += r.blueCaptures
    totRedS += r.redShots; totBlueS += r.blueShots

  let
    tRedHit = (if totRedS > 0: 100.0 * totRedK.float / totRedS.float else: 0.0)
    tBlueHit = (if totBlueS > 0: 100.0 * totBlueK.float / totBlueS.float else: 0.0)
  echo ""
  echo &"TOTals over {games} games:"
  echo &"  wins:     RED {redWins}  BLUE {blueWins}  draw {draws}  unfinished {unfinished}"
  echo &"  kills:    RED {totRedK}  BLUE {totBlueK}"
  echo &"  captures: RED {totRedC}  BLUE {totBlueC}"
  echo &"  shots:    RED {totRedS}  BLUE {totBlueS}"
  echo &"  hit rate: RED {tRedHit:.2f}%  BLUE {tBlueHit:.2f}%"

when isMainModule:
  main()
