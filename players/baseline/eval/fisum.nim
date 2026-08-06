## fisum — the issue #15 `finishWounded` MECHANISM probe (deterministic, in-process).
##
## Two things the A/B rig cannot give us:
##
## 1. **A per-team lever A/B on identical frames.** `shippedCombatTune()` reads `FINISH`
##    from the process env, and this harness runs all 16 bots in ONE process — so an env
##    knob alone arms BOTH sides and the "A/B" is a mirror (the contaminated-control trap).
##    `FINTEAM=red|blue` re-stamps `tune.finishWounded` per team, the established
##    SPINTEAM/FIXTEAM pattern, giving a per-tick, deterministic, seat-rotatable A/B.
##
## 2. **Ground truth about the ENEMY's hit points.** The lever exists to convert enemy
##    1-hp lives into kills instead of letting them bank. No policy can observe that
##    reliably through fog, so the outcome metrics are read straight off `sim.players`
##    via `slotTruth` (-d:fiprobe), never off the bot's own perception.
##
## Reported (plan §2.1):
##   M1  fiPickDiff / fiEngage — share of engage frames where the lever's argmin differs
##       from the control's, computed by the DIFFERENTIAL probe inside decide() (both
##       selectors over the same frame state). A pick identical to the control's cannot
##       change an outcome, so this BOUNDS the A/B before any episode is bought.
##   M2  fraction of each team's hp-1 segments that END IN DEATH (= how well the OTHER
##       team finishes them). The lever's team should raise its opponent's number.
##   M3  travel per alive frame, per team — the mandated failure-signature row.
##   M4  mean ticks spent at hp 1, per team.
##
## Build (always with a UNIQUE nimcache — parallel same-named nim builds cross-contaminate):
##   cd players/baseline/eval && nim c -d:release --opt:speed -d:fiprobe \
##     --nimcache:/private/tmp/nc_fin_fi --out:fisum.out fisum.nim
## Run from the REPO ROOT (pixie loads data/ascii.png relative to cwd):
##   FINTEAM=red ./players/baseline/eval/fisum.out --games 12 --seed 100 --ticks 5000

import std/[os, random, strutils, strformat, math]
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
  # FINTEAM picks which colour carries finishWounded and RE-STAMPS the other back off,
  # so one process yields a genuine A/B instead of a mirror. Unset => both sides OFF
  # (the null / identity run).
  let finTeam = getEnv("FINTEAM")
  tune.finishWounded =
    (finTeam == "red" and t == Red) or (finTeam == "blue" and t == Blue)
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
  var ticks = 5000
  var i = 0
  let p = commandLineParams()
  while i < p.len:
    case p[i]
    of "--games": inc i; games = parseInt(p[i])
    of "--seed": inc i; seed = parseInt(p[i])
    of "--ticks": inc i; ticks = parseInt(p[i])
    else: discard
    inc i

  let numPlayers = 16
  var
    redWins, blueWins, draws: int
    kills: array[2, int]
    deaths: array[2, int]
    # hp-1 SEGMENT FATE, ground truth, per team that OWNS the segment.
    segs: array[2, int]
    segDeaths: array[2, int]      # ended because the owner DIED (the other team finished it)
    segHeals: array[2, int]       # ended because hp ROSE (a med kit banked the life)
    segOpen: array[2, int]        # still at hp 1 when the game ended (BANKED to the buzzer)
    segTicks: array[2, int]
    travel: array[2, float]
    aliveFrames: array[2, int]

  for g in 0 ..< games:
    let epSeed = seed + g
    var engine = newEvalEngine(numPlayers, epSeed, ticks)
    var drivers: seq[Driver]
    for s in 0 ..< numPlayers:
      drivers.add newDriver(s, engine.teamOfSlot(s), epSeed)
    var
      prevHp = newSeq[int](numPlayers)
      prevAlive = newSeq[bool](numPlayers)
      prevX = newSeq[int](numPlayers)
      prevY = newSeq[int](numPlayers)
      havePrev = newSeq[bool](numPlayers)
      hp1Since = newSeq[int](numPlayers)      # -1 = not in an hp-1 segment
    for s in 0 ..< numPlayers:
      hp1Since[s] = -1
    var tick = 0
    while tick < ticks:
      for s in 0 ..< numPlayers:
        let packet = engine.frameFor(s)
        let mask = drivers[s].frame(packet)
        engine.setMask(s, mask)
      engine.advance()
      inc tick
      # ── ground-truth sampling (after the step, so a death this tick is visible)
      for s in 0 ..< numPlayers:
        let st = engine.slotTruth(s)
        let tm = st.team
        if st.alive:
          inc aliveFrames[tm]
          if havePrev[s] and prevAlive[s]:
            travel[tm] += sqrt(float((st.x - prevX[s]) * (st.x - prevX[s]) +
                                     (st.y - prevY[s]) * (st.y - prevY[s])))
        # hp-1 segment bookkeeping
        if hp1Since[s] >= 0:
          if not st.alive:
            inc segs[tm]; inc segDeaths[tm]; segTicks[tm] += tick - hp1Since[s]
            hp1Since[s] = -1
          elif st.hp > 1:
            inc segs[tm]; inc segHeals[tm]; segTicks[tm] += tick - hp1Since[s]
            hp1Since[s] = -1
        elif st.alive and st.hp == 1:
          hp1Since[s] = tick
        prevHp[s] = st.hp
        prevAlive[s] = st.alive
        prevX[s] = st.x
        prevY[s] = st.y
        havePrev[s] = true
      let r = engine.result()
      if r.phaseOver: break
    # segments still open at the buzzer = lives BANKED to the end (the leader's 13%)
    for s in 0 ..< numPlayers:
      if hp1Since[s] >= 0:
        let tm = engine.slotTruth(s).team
        inc segs[tm]; inc segOpen[tm]; segTicks[tm] += tick - hp1Since[s]
    let r = engine.result()
    kills[0] += r.redKills; kills[1] += r.blueKills
    deaths[0] += r.redDeaths; deaths[1] += r.blueDeaths
    if r.isDraw or r.winnerTeam < 0: inc draws
    elif r.winnerTeam == 0: inc redWins
    else: inc blueWins
    echo &"game {g}: winner={r.winnerTeam} ticks={r.ticks} " &
      &"kills R{r.redKills}/B{r.blueKills}"

  proc pct(a, b: int): float = (if b > 0: 100.0 * a.float / b.float else: 0.0)
  echo "==================================================="
  echo &"FISUM  {games} games  seed {seed}  ticks {ticks}  FINTEAM={getEnv(\"FINTEAM\")}"
  echo &"WINS  Red {redWins}  Blue {blueWins}  Draw {draws}"
  echo &"KILLS Red {kills[0]}  Blue {kills[1]}   DEATHS Red {deaths[0]}  Blue {deaths[1]}"
  for tm in 0 .. 1:
    let name = (if tm == 0: "RED " else: "BLUE")
    echo &"{name} hp1Segs={segs[tm]} deaths={segDeaths[tm]} heals={segHeals[tm]} " &
      &"openAtEnd={segOpen[tm]}"
    echo &"{name}   M2 segment->DEATH share = {pct(segDeaths[tm], segs[tm]):.1f}%  " &
      &"(banked = heal {pct(segHeals[tm], segs[tm]):.1f}% + open {pct(segOpen[tm], segs[tm]):.1f}%)"
    echo &"{name}   M4 mean hp1 ticks = " &
      &"{(if segs[tm] > 0: segTicks[tm].float / segs[tm].float else: 0.0):.1f}"
    echo &"{name}   M3 travel/aliveFrame = " &
      &"{(if aliveFrames[tm] > 0: travel[tm] / aliveFrames[tm].float else: 0.0):.4f}" &
      &"  (aliveFrames {aliveFrames[tm]})"

when isMainModule:
  main()
  when defined(fiprobe):
    echo "=== FIPROBE DIFFERENTIAL SUMMARY (plan #15 §2.1 M1) ==="
    echo "fiElig=", fiElig, "  (frame,candidate) pairs meeting the lever condition"
    echo "fiSatFlip=", fiSatFlip, "  ...of those, the control would have SATURATED (F1's bite)"
    echo "fiEngage=", fiEngage, "  decide frames with the lever on and an engage pick"
    echo "fiPickDiff=", fiPickDiff, "  ...where the lever's argmin DIFFERS from the control's"
    echo "fiPickFin=", fiPickFin, "  ...and the new pick is the 1-hp finish candidate"
    echo "M1 pickDiffPct=",
      (if fiEngage > 0: 100.0 * fiPickDiff.float / fiEngage.float else: 0.0)
