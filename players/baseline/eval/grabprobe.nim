## Minimal tune-free grab/capture prober for the 0.7.8 baseline.
##
## Seats N baseline bots in the headless 0.7.8 sim, drives the SHIPPED
## `decide()` byte-identically (per-slot RNG isolation like runBot), and
## reports per-team grabs / captures / wins over a batch. Its only purpose is
## to prove the origin/main baseline is NOT blind on 0.7.8 (it reads the
## "<color> flag" labels the live server emits) — i.e. it actually steals and
## captures, unlike a heart-label reader on the same server.
##
## Usage:
##   nim c -d:release --opt:speed -o:/tmp/grabprobe.out \
##     players/baseline/eval/grabprobe.nim
##   /tmp/grabprobe.out --games 12 --seed 100 --ticks 10000

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

proc newDriver(slot, team, episodeSeed: int): Driver =
  let t = (if team == 0: Red else: Blue)
  let role = roleForSeat(clamp(slot div 2, 0, 7), t)
  var tune = shippedCombatTune()
  # Isolate the two 2026-07-16 finish fixes (carrier home-stretch + thief chase).
  #   NOFIX=1        → strip the fixes from BOTH teams (mirror control).
  #   FIXTEAM=red    → only Red gets the fixes; Blue is stripped (seat-rotated A/B).
  #   FIXTEAM=blue   → only Blue gets them; Red stripped.
  let fixTeam = getEnv("FIXTEAM")
  let stripFix =
    getEnv("NOFIX") == "1" or
    (fixTeam == "red" and t == Blue) or
    (fixTeam == "blue" and t == Red)
  # PBMARGIN=1 narrows the strip to PLAYBOOK ONLY, so the "control" seat keeps the
  # full champion minus the play layer. That measures the MARGINAL contribution of
  # the playbook on top of the shipped champion (the decision-relevant question now
  # that playbook is in shippedCombatTune), rather than champion-vs-bare-core.
  let pbMargin = getEnv("PBMARGIN") == "1"
  if stripFix:
    tune.playbook = false
    if not pbMargin:
      tune.carrierHomeStretch = false
      tune.chaseThief = false
      tune.cornerPreAim = false
      tune.sentryDisplace = false
      tune.topBias = false
  # Per-lever isolation: NOCHASE strips only the behavioral thief-chase lever
  # (leaving the pure carrier-pathing finish fix on) for whichever team holds
  # the fix, so a seat-rotated pair attributes the two levers separately.
  if getEnv("NOCHASE") == "1" and not stripFix:
    tune.chaseThief = false
  if getEnv("NOHOMESTRETCH") == "1" and not stripFix:
    tune.carrierHomeStretch = false
  # CORNER PRE-AIM isolation: NOCORNER strips only the wall-aim fix for the fixed
  # team, so a seat-rotated pair attributes the aim lever separately. Isolating
  # it alone (NOCHASE+NOHOMESTRETCH set too) measures its hit-rate effect clean.
  if getEnv("NOCORNER") == "1" and not stripFix:
    tune.cornerPreAim = false
  if getEnv("NOSENTRY") == "1" and not stripFix:
    tune.sentryDisplace = false
  if getEnv("NOTOPBIAS") == "1" and not stripFix:
    tune.topBias = false
  # PLAYBOOK is now ON in shippedCombatTune. NOPLAYBOOK strips only the play layer
  # for the fixed team, so a seat-rotated pair isolates the observation-triggered
  # plays against an otherwise-identical control that keeps every other lever.
  if getEnv("NOPLAYBOOK") == "1" and not stripFix:
    tune.playbook = false
  # GRABTIMING=1 turns ON the anti-stacked-dive hold (not in shippedCombatTune) so
  # the not-blind oracle can confirm a grabTiming build still grabs + has decisive
  # games before any upload. Applies to BOTH teams (a mirror liveness check).
  if getEnv("GRABTIMING") == "1":
    tune.grabTiming = true
  # HOLDLINE=1 / GRABGATE=1 (2026-07-22, the h006 counters) turn ON the anti-over-extend
  # rally / numbers-gated pocket open (neither in shippedCombatTune) so the not-blind
  # oracle can confirm each build still grabs + has decisive games before any A/B.
  # Applies to BOTH teams (a mirror liveness check).
  if getEnv("HOLDLINE") == "1":
    tune.holdLine = true
  if getEnv("GRABGATE") == "1":
    tune.grabGate = true
  result.bot = Bot(slot: slot, team: t, role: role, tune: tune)
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

proc main() =
  var games = 12
  var seed = 100
  var ticks = 10000
  var i = 0   # commandLineParams() excludes argv[0]; start at the FIRST real flag
  let p = commandLineParams()
  while i < p.len:
    case p[i]
    of "--games": inc i; games = parseInt(p[i])
    of "--seed": inc i; seed = parseInt(p[i])
    of "--ticks": inc i; ticks = parseInt(p[i])
    else: discard
    inc i

  var
    totRedGrab, totBlueGrab, totRedCap, totBlueCap: int
    totRedShot, totBlueShot, totRedHit, totBlueHit: int
    redWins, blueWins, draws: int
  let numPlayers = 16
  for g in 0 ..< games:
    let epSeed = seed + g
    var engine = newEvalEngine(numPlayers, epSeed, ticks)
    var drivers: seq[Driver]
    for s in 0 ..< numPlayers:
      drivers.add newDriver(s, engine.teamOfSlot(s), epSeed)
    var tick = 0
    while tick < ticks:
      for s in 0 ..< numPlayers:
        let packet = engine.frameFor(s)
        let mask = drivers[s].frame(packet)
        engine.setMask(s, mask)
      engine.advance()
      inc tick
      let r = engine.result()
      if r.phaseOver: break
    let r = engine.result()
    totRedGrab += r.redGrabs; totBlueGrab += r.blueGrabs
    totRedCap += r.redCaptures; totBlueCap += r.blueCaptures
    totRedShot += r.redShots; totBlueShot += r.blueShots
    totRedHit += r.redHits; totBlueHit += r.blueHits
    if r.isDraw or r.winnerTeam < 0: inc draws
    elif r.winnerTeam == 0: inc redWins
    else: inc blueWins
    echo &"game {g}: winner={r.winnerTeam} ticks={r.ticks} " &
      &"grabs R{r.redGrabs}/B{r.blueGrabs} caps R{r.redCaptures}/B{r.blueCaptures}"

  echo "==================================================="
  echo &"{games} games  seed {seed}  ticks {ticks}"
  echo &"WINS  Red {redWins}  Blue {blueWins}  Draw {draws}"
  echo &"GRABS total  Red {totRedGrab}  Blue {totBlueGrab}  (per game " &
    &"{totRedGrab/games:.1f}/{totBlueGrab/games:.1f})"
  echo &"CAPS  total  Red {totRedCap}  Blue {totBlueCap}  (per game " &
    &"{totRedCap/games:.2f}/{totBlueCap/games:.2f})"
  let
    redAcc = (if totRedShot > 0: 100.0 * totRedHit.float / totRedShot.float else: 0.0)
    blueAcc = (if totBlueShot > 0: 100.0 * totBlueHit.float / totBlueShot.float else: 0.0)
  echo &"SHOTS total  Red {totRedShot}  Blue {totBlueShot}"
  echo &"HITS  total  Red {totRedHit}  Blue {totBlueHit}"
  echo &"ACCURACY     Red {redAcc:.1f}%  Blue {blueAcc:.1f}%  " &
    &"(hits/shots — the wall-vs-body aim metric)"

when isMainModule:
  main()
