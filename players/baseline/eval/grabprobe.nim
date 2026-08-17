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
  # ⭐ spinCap RANGE FORK isolation (issue #8). shippedCombatTune() reads
  # NOSPINCAP / SPINRANGE from the process env, but the harness runs all 16
  # bots in ONE process — so without this the "A/B" is a mirror. SPINTEAM
  # picks which side gets the candidate traverse and RE-STAMPS the other side
  # back to plain v39, giving a deterministic, per-tick, seat-rotatable A/B.
  let spinTeam = getEnv("SPINTEAM")
  if spinTeam.len > 0:
    let mine = (spinTeam == "red" and t == Red) or (spinTeam == "blue" and t == Blue)
    if not mine:
      tune.spinCap = true
      tune.spinCapRangePx = Inf
  # ⭐⭐ MID-QUAD BREAK isolation (2026-08-14). Same problem as SPINTEAM: this
  # harness seats OUR policy on all 16 slots, so a whole-batch env flip is a
  # MIRROR — both sides move together and per-seat K/D is symmetric by
  # construction, which is exactly the "no-op A/B" tell. SEAT4TEAM arms the
  # package on ONE colour: roleForSeat reads it directly (a pure function cannot
  # be re-stamped) and the two tune levers are stripped from the other colour
  # here, so all three move as one arm. ⚠️ SEAT-ROTATE IT — run red-armed and
  # blue-armed and average, or you have measured the side.
  let seat4Team = getEnv("SEAT4TEAM")
  if seat4Team.len > 0:
    let armed = (seat4Team == "red" and t == Red) or
                (seat4Team == "blue" and t == Blue)
    if not armed:
      tune.roleSep = false
      tune.midSpread = false
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
  # ⭐ GV40 AIM A/B (2026-08-06). shippedCombatTune() reads OLDAIM from the
  # process env and all 16 bots share ONE process, so a bare OLDAIM=1 would arm
  # BOTH sides and the "A/B" would be a mirror — the same trap SPINTEAM and
  # RALLYTEAM exist to avoid. AIMTEAM=red|blue gives that side the SHIPPED-
  # BROKEN GV36 slot servo and leaves the other on the GV40 continuous fix,
  # giving a deterministic, seat-rotatable head-to-head from one frozen binary.
  let aimTeam = getEnv("AIMTEAM")
  if aimTeam.len > 0:
    tune.aimLegacy = (aimTeam == "red" and t == Red) or
                     (aimTeam == "blue" and t == Blue)
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

when defined(roleprobe):
  # ── ⭐⭐ MID-QUAD PROBE (grabprobe side). The finding is GEOMETRIC — four of
  # eight seats in the mid family, one mid role dealt twice, four bodies in one
  # corridor — so the numbers that can move on a mirror rig are per-seat K/D
  # (with SEAT4TEAM arming one colour) and TEAMMATE SEPARATION. Win rate on a
  # mirror cannot move by construction and is not scored here.
  #
  # ⚠️ SEPARATION IS TAKEN FROM GROUND TRUTH (-d:rwtruth slotTruth), never from
  # a bot's own fogged belief about where its mates are: a probe that counts
  # what the bot BELIEVES is not the field metric.
  const
    RpSampleEvery = 20        # ticks between separation samples (~cheap, and far
                              # longer than one engagement so samples are not
                              # autocorrelated into a fake n)
    RpNadePairPx = 120.0      # ONE grenade catches BOTH: GrenadeBlastRadius is 52
                              # and the check is body-box based, so a pair inside
                              # ~2*(52+half) can be taken by a single blast. This
                              # is the mirror analogue of the field stat this
                              # package targets (58.4% of enemy nade impacts that
                              # damaged us caught 2+ of ours).
    RpTightPairPx = 60.0      # dead-on-top-of-each-other, the hard bunching case
  var
    rpKills, rpDeaths: array[2, array[8, int]]   # per (team, teamSeat)
    rpEps: array[2, array[8, int]]               # episodes the seat appeared in
    rpPairAll, rpPairNade, rpPairTight: array[2, int]  # sampled unordered pairs
    rpBodyAll, rpBodyNade: array[2, int]         # sampled live bodies / with a
                                                 # mate inside one blast
    rpYSpreadSum: array[2, float]                # Σ stdev of live-teammate y
    rpYSpreadN: array[2, int]
    # ⭐ FRIENDLY FIRE, batch totals. Not split by colour on purpose: this rig is
    # a MIRROR, so in the symmetric arms the own-colour rate is a property of the
    # ARM, not of a side. (With SEAT4TEAM armed the sides differ — the per-seat
    # K/D table is where that split is read.)
    rpKillsAll, rpFfKills, rpFfGun, rpFfNade, rpFfSpray: int
    rpDmgAll, rpFfDmg: int

  proc rpSample(engine: EvalEngine, players: int) =
    ## One ground-truth separation sample over every live body, bucketed by team.
    var xs, ys: array[4, seq[float]]
    for s in 0 ..< players:
      let tr = engine.slotTruth(s)
      if not tr.alive: continue
      if tr.team notin 0 .. 3: continue
      xs[tr.team].add tr.x
      ys[tr.team].add tr.y
    for tm in 0 .. 1:
      let n = xs[tm].len
      if n == 0: continue
      var nearFor = newSeq[bool](n)
      for i in 0 ..< n:
        for j in i + 1 ..< n:
          let dx = xs[tm][i] - xs[tm][j]
          let dy = ys[tm][i] - ys[tm][j]
          let d = sqrt(dx * dx + dy * dy)
          inc rpPairAll[tm]
          if d <= RpNadePairPx:
            inc rpPairNade[tm]
            nearFor[i] = true
            nearFor[j] = true
          if d <= RpTightPairPx: inc rpPairTight[tm]
      for i in 0 ..< n:
        inc rpBodyAll[tm]
        if nearFor[i]: inc rpBodyNade[tm]
      if n >= 2:
        var m = 0.0
        for y in ys[tm]: m += y
        m /= n.float
        var v = 0.0
        for y in ys[tm]: v += (y - m) * (y - m)
        rpYSpreadSum[tm] += sqrt(v / (n - 1).float)
        inc rpYSpreadN[tm]

when defined(doorprobe):
  var engineTeamOfSlot: array[32, int]   # real team index per slot (4-team safe)

  proc dpStat(v: seq[float]): (float, float) =
    ## mean, sample stdev.
    if v.len == 0: return (0.0, 0.0)
    var m = 0.0
    for x in v: m += x
    m /= v.len.float
    if v.len < 2: return (m, 0.0)
    var s = 0.0
    for x in v: s += (x - m) * (x - m)
    (m, sqrt(s / (v.len - 1).float))

  proc dpEntryLine(tag: string) =
    ## ⚠️ Printed AFTER EVERY GAME and flushed. This rig runs ~12 min/game under
    ## fleet load and the summary only exists at process exit, so a starved or
    ## killed run used to yield NOTHING. Cumulative, so any partial run is still
    ## a usable measurement — it just has fewer entries behind it.
    for tm in 0 .. 1:
      var allY, subY, subD: seq[float]
      for st in 0 .. 7:
        for i in 0 ..< dpEntryN[tm][st]:
          allY.add dpEntryY[tm][st][i]
          if st <= 3: subY.add dpEntryY[tm][st][i]
        if st <= 3:
          for i in 0 ..< dpDoorN[tm][st]: subD.add dpDoorY[tm][st][i]
      let (am, asd) = dpStat(allY)
      let (sm, ssd) = dpStat(subY)
      let (dm, dsd) = dpStat(subD)
      echo &"ENTRYY {tag} team{tm}  all n={allY.len} mean={am:.1f} " &
        &"stdev={asd:.1f}  |  SUBSET(seats0-3) n={subY.len} mean={sm:.1f} " &
        &"STDEV={ssd:.1f}  |  DOOR(+90px seats0-3) n={subD.len} " &
        &"mean={dm:.1f} STDEV={dsd:.1f}"
    flushFile(stdout)

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
    # ⭐ N-TEAM TALLY (v49 rig): winnerTeam is ord(sim.winner) — already 0..3 —
    # and r.slots carries team/kills/deaths/captures per seat, so the 4-team
    # truth always flowed through this probe and was being collapsed into two
    # buckets ("Blue" = every non-Red team — why a 4-team mirror printed
    # "Red 0 / Blue 10" and looked like a red-seat defect). Aggregate per real
    # team. Engine redGrabs/blueGrabs misattribute on >2 teams (any non-Blue
    # victim credits "blue"), so GRABS stays a 2-team metric.
    teamWins, teamCaps, teamKills, teamDeaths: array[4, int]
  let evalTeams = max(2, (if getEnv("EVAL_TEAMS").len > 0:
                            parseInt(getEnv("EVAL_TEAMS")) else: 2))
  # ⭐ EVAL_PLAYERS (2026-08-14): the 4ffa8 board is 32 SLOTS, and only there
  # does teamSeat reach 4..7 on a 4-team deal (teamSeat = slot div teams). With
  # the roster hard-coded to 16 the seat-4 half of the table was never exercised
  # at RUNTIME on 4-team at all — the seat dump proved the deal, but "the deal is
  # right" and "every seat still acts" are different claims and the statue
  # failure only shows up in the second one.
  let numPlayers = max(2, (if getEnv("EVAL_PLAYERS").len > 0:
                             parseInt(getEnv("EVAL_PLAYERS")) else: 16))
  for g in 0 ..< games:
    let epSeed = seed + g
    var engine = newEvalEngine(numPlayers, epSeed, ticks)
    var drivers: seq[Driver]
    for s in 0 ..< numPlayers:
      drivers.add newDriver(s, engine.teamOfSlot(s), epSeed)
      when defined(doorprobe):
        if s < 32: engineTeamOfSlot[s] = engine.teamOfSlot(s)
    var tick = 0
    while tick < ticks:
      for s in 0 ..< numPlayers:
        let packet = engine.frameFor(s)
        let mask = drivers[s].frame(packet)
        engine.setMask(s, mask)
      engine.advance()
      inc tick
      when defined(roleprobe):
        if tick mod RpSampleEvery == 0: rpSample(engine, numPlayers)
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
    if r.winnerTeam in 0 .. 3: inc teamWins[r.winnerTeam]
    for s in r.slots:
      if s.team in 0 .. 3:
        teamCaps[s.team] += s.captures
        teamKills[s.team] += s.kills
        teamDeaths[s.team] += s.deaths
    when defined(roleprobe):
      # Per-SEAT K/D. teamSeat is the engine's own slotIdentityIndex
      # (slot div teams) — the same formula roleForSeat is fed — so this is the
      # seat the roster scan's Α..Θ letters name, not a re-derived guess.
      for s in r.slots:
        if s.team notin 0 .. 1: continue
        let st = clamp(s.slot div max(2, evalTeams), 0, 7)
        rpKills[s.team][st] += s.kills
        rpDeaths[s.team][st] += s.deaths
        inc rpEps[s.team][st]
      let ff = engine.friendlyFireCounts()
      rpKillsAll += ff.kills; rpFfKills += ff.ffKills
      rpFfGun += ff.ffGun; rpFfNade += ff.ffNade; rpFfSpray += ff.ffSpray
      rpDmgAll += ff.dmg; rpFfDmg += ff.ffDmg
    echo &"game {g}: winner={r.winnerTeam} ticks={r.ticks} " &
      &"grabs R{r.redGrabs}/B{r.blueGrabs} caps R{r.redCaptures}/B{r.blueCaptures}"
    when defined(doorprobe):
      dpEntryLine(&"afterGame{g}")
    flushFile(stdout)

  when defined(roleprobe):
    # ── ⭐⭐ MID-QUAD REPORT. Three things, in the order they have to be true:
    #   1) the levers FIRED (a compiled-but-inert lever reads exactly like a
    #      broken one, and the reverts must read ZERO),
    #   2) nothing became a STATUE (per-seat frames + travel, the silent
    #      seat-contract failure),
    #   3) the separation actually moved (the mirror-measurable target).
    const RpRoleName = ["MidTop", "MidBottom", "MidGuard", "FlankTop",
                        "FlankBottom", "Overwatch", "HomeDefender"]
    echo "==================================================="
    echo "--- MID-QUAD PROBE ---"
    echo &"  arm: NOSEAT4={getEnv(\"NOSEAT4\")} NOROLESEP={getEnv(\"NOROLESEP\")} " &
      &"NOMIDSPREAD={getEnv(\"NOMIDSPREAD\")} NODOOR1={getEnv(\"NODOOR1\")} " &
      &"SEAT4TEAM={getEnv(\"SEAT4TEAM\")}"
    for tm in 0 .. 1:
      let tname = (if tm == 0: "RED " else: "BLUE")
      echo &"  team {tname}  seat  role          eps    K     D    K/D    K-D/ep" &
        &"   sepFire  midFire  midTrailMean  PARK"
      var tk, td = 0
      for st in 0 .. 7:
        if rpEps[tm][st] == 0: continue
        tk += rpKills[tm][st]; td += rpDeaths[tm][st]
        # Match the per-team K/D convention already used below: with zero deaths
        # the ratio is undefined, so report the kills rather than a 0.00 that
        # reads as "this seat did nothing" when it in fact went unkilled.
        let kd = (if rpDeaths[tm][st] > 0:
                    rpKills[tm][st].float / rpDeaths[tm][st].float
                  else: rpKills[tm][st].float)
        let kdep = (rpKills[tm][st] - rpDeaths[tm][st]).float / rpEps[tm][st].float
        let rn = (if dpRole[tm][st] in 0 .. 6: RpRoleName[dpRole[tm][st]] else: "-")
        let mtm = (if rpMidFrames[tm][st] > 0:
                     rpMidTrailSum[tm][st] / rpMidFrames[tm][st].float else: 0.0)
        echo &"          {st:>6}  {rn:<12} {rpEps[tm][st]:>3} {rpKills[tm][st]:>5} " &
          &"{rpDeaths[tm][st]:>5} {kd:>6.2f} {kdep:>9.2f} {rpSepFrames[tm][st]:>9} " &
          &"{rpMidFrames[tm][st]:>8} {mtm:>13.1f} {rpPark[tm][st]:>5}"
      let skd = (if td > 0: tk.float / td.float else: tk.float)
      var park = 0
      for st in 0 .. 7: park += rpPark[tm][st]
      echo &"  team {tname}  SQUAD  K {tk} D {td}  K/D {skd:.2f}  " &
        &"PARK-INVARIANT {(if park == 0: \"OK (0 frames)\" else: \"*** VIOLATED: \" & $park & \" frames ***\")}"
      # SEPARATION — the geometric target. A pair inside RpNadePairPx can be
      # taken by ONE grenade; bodyNade is the per-body version of the field's
      # "58.4% of nade impacts caught 2+ of ours".
      let pa = max(1, rpPairAll[tm])
      let ba = max(1, rpBodyAll[tm])
      let ysp = (if rpYSpreadN[tm] > 0:
                   rpYSpreadSum[tm] / rpYSpreadN[tm].float else: 0.0)
      echo &"  team {tname}  SEPARATION  pairs n={rpPairAll[tm]}  " &
        &"within{RpNadePairPx.int}px {100.0 * rpPairNade[tm].float / pa.float:.2f}%  " &
        &"within{RpTightPairPx.int}px {100.0 * rpPairTight[tm].float / pa.float:.2f}%  |  " &
        &"BODIES n={rpBodyAll[tm]} with a mate inside one blast " &
        &"{100.0 * rpBodyNade[tm].float / ba.float:.2f}%  |  live-mate y-STDEV {ysp:.1f}"
    # ⭐⭐ FRIENDLY FIRE — the crowding metric, and the one the FIELD reports:
    # 8.1% of half4 deaths were own-colour on the deal where three of four seats
    # are mids. Friendly fire is ON in this engine, so this is not a proxy for
    # crowding, it IS crowding: a mate on the ray, or a blast that caught two.
    let ka = max(1, rpKillsAll)
    let da = max(1, rpDmgAll)
    echo &"  FRIENDLY FIRE  kills n={rpKillsAll}  own-colour {rpFfKills} " &
      &"({100.0 * rpFfKills.float / ka.float:.2f}%)  [gun {rpFfGun} " &
      &"nade {rpFfNade} spray {rpFfSpray}]  |  damage events n={rpDmgAll}  " &
      &"own-colour {rpFfDmg} ({100.0 * rpFfDmg.float / da.float:.2f}%)"
    flushFile(stdout)

  when defined(doorprobe):
    # ── ⭐ ONE-DOOR REPORT. The target metric is ENTRY-Y STDEV: the spread of
    # the y at which our seats cross the midline into the enemy half. Field
    # baseline vs daveey: ours 5/17/31px, his 148-242px, target >100.
    # SUBSET is the number that matters: in "1v1 (8 per team)" paintbot we hold
    # slots {0,2,4,6} => teamSeats {0,1,2,3}, so seats 4..7 are a DIFFERENT
    # entrant's and must not be averaged into our score. This rig seats our
    # policy on all 8, so the subset is taken by filtering, not by re-seating.
    const RoleName = ["MidTop", "MidBottom", "MidGuard", "FlankTop",
                      "FlankBottom", "Overwatch", "HomeDefender"]
    let statOf = dpStat
    echo "==================================================="
    echo "--- ONE-DOOR PROBE (entry-y = midline crossing into the enemy half) ---"
    for tm in 0 .. 1:
      var allY: seq[float]
      var subY: seq[float]
      let tname = (if tm == 0: "RED " else: "BLUE")
      echo &"  team {tname}   seat  role          entries  meanY   stdevY   " &
        &"aliveFrames  travelPx  hotArm  hotFire  doorDeaths  hold  rel  exp"
      for st in 0 .. 7:
        var ys: seq[float]
        for i in 0 ..< dpEntryN[tm][st]: ys.add dpEntryY[tm][st][i]
        allY.add ys
        if st <= 3: subY.add ys
        let (mn, sd) = statOf(ys)
        let rn = (if dpRole[tm][st] in 0 .. 6: RoleName[dpRole[tm][st]] else: "-")
        echo &"           {st:>6}  {rn:<12} {ys.len:>8} {mn:>7.1f} {sd:>8.1f} " &
          &"{dpAliveFrames[tm][st]:>12} {dpTravel[tm][st]:>9.0f} " &
          &"{dpHotDoorArm[tm][st]:>7} {dpHotDoorFire[tm][st]:>8} " &
          &"{dpDoorDeaths[tm][st]:>11} {dpWaveHold[tm][st]:>5} " &
          &"{dpWaveRelease[tm][st]:>4} {dpWaveExpire[tm][st]:>4}"
      let (am, asd) = statOf(allY)
      let (sm, ssd) = statOf(subY)
      echo &"  team {tname}  ALL8   entries {allY.len:>5}  meanY {am:>7.1f}  " &
        &"ENTRY-Y STDEV {asd:>7.1f}"
      echo &"  team {tname}  SUBSET entries {subY.len:>5}  meanY {sm:>7.1f}  " &
        &"ENTRY-Y STDEV {ssd:>7.1f}   <-- the league seats {{0,1,2,3}}"
      # The DOOR reading (+90px past the midline). On r1692 e20 the midline
      # spread was 81.6px and the same seats' door spread was 6.8px — the
      # midline number alone would have called a one-door game "spread".
      var subD: seq[float]
      for st in 0 .. 3:
        for i in 0 ..< dpDoorN[tm][st]: subD.add dpDoorY[tm][st][i]
      let (dm, dsd) = statOf(subD)
      echo &"  team {tname}  DOOR   crossings {subD.len:>5}  meanY {dm:>7.1f}  " &
        &"DOOR-Y  STDEV {dsd:>7.1f}   <-- +90px past the midline"
    var hArm, hFire, dDeath, wHold, wRel, wExp = 0
    for tm in 0 .. 1:
      for st in 0 .. 7:
        hArm += dpHotDoorArm[tm][st]; hFire += dpHotDoorFire[tm][st]
        dDeath += dpDoorDeaths[tm][st]; wHold += dpWaveHold[tm][st]
        wRel += dpWaveRelease[tm][st]; wExp += dpWaveExpire[tm][st]
    echo &"  LEVER FIRES  doorDeaths {dDeath}  hotDoorArmed {hArm}  " &
      &"hotDoorMovedTarget {hFire}  waveHoldFrames {wHold}  " &
      &"waveReleases {wRel}  waveCapExpiries {wExp}"
    # ── SEAT LIVENESS. "2 of 6 bots stood perfectly still with zero errors"
    # after a silent seat-contract change; travel==0 or frames==0 is that
    # signature. Indexed by physical SLOT so it is unambiguous on 4-team too.
    echo "  --- SEAT LIVENESS (every slot must have frames>0 AND travel>0) ---"
    var dead = 0
    for sl in 0 ..< numPlayers:
      let rn = (if dpSlotRole[sl] in 0 .. 6: RoleName[dpSlotRole[sl]] else: "-")
      let ok = dpSlotFrames[sl] > 0 and dpSlotTravel[sl] > 0.0
      if not ok: inc dead
      echo &"    slot {sl:>2}  team {engineTeamOfSlot[sl]:>2}  teamSeat " &
        &"{dpSlotSeat[sl]:>2}  role {rn:<13} frames {dpSlotFrames[sl]:>7}  " &
        &"travel {dpSlotTravel[sl]:>9.0f}px  entries {dpSlotEntries[sl]:>4}  " &
        &"{(if ok: \"ACTS\" else: \"*** STATUE ***\")}"
    echo &"    STATUES: {dead} of {numPlayers}"

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
  if evalTeams > 2:
    echo &"--- PER-TEAM ({evalTeams} teams; Red/Blue lines above lump teams 1.." &
      &"{evalTeams-1} into 'Blue') ---"
    const tn = ["red", "blue", "green", "yellow"]
    for t in 0 ..< evalTeams:
      let kd = (if teamDeaths[t] > 0: teamKills[t].float / teamDeaths[t].float
                else: teamKills[t].float)
      echo &"  {tn[t]:<7} wins {teamWins[t]:>2}  caps {teamCaps[t]:>2}  " &
        &"kills {teamKills[t]:>4}  deaths {teamDeaths[t]:>4}  K/D {kd:.2f}"
  when defined(rngprobe):
    const bandName = ["<150", "150-300", "300-600", "600-1000", ">=1000"]
    for side in 0 .. 1:
      echo "--- RANGED CORRIDOR  team ", (if side == 0: "RED" else: "BLUE"),
        "   cappedTraverses ", rpCap[side],
        "  meanCapSlotErr ", (if rpCap[side] > 0: rpCapErr[side] / rpCap[side] else: 0.0)
      echo "band       frames     open   open%     fire   fire%  meanErrBrads  meanD"
      var tf2, to2, tfi2 = 0
      for b in 0 .. 4:
        let f = rpFrames[side][b]
        tf2 += f; to2 += rpOpen[side][b]; tfi2 += rpFire[side][b]
        let
          op = (if f > 0: 100.0 * rpOpen[side][b].float / f.float else: 0.0)
          fp = (if f > 0: 100.0 * rpFire[side][b].float / f.float else: 0.0)
          me = (if f > 0: rpErrSum[side][b].float / f.float else: 0.0)
          md = (if f > 0: rpDistSum[side][b] / f.float else: 0.0)
        echo &"{bandName[b]:>9} {f:>9} {rpOpen[side][b]:>8} {op:>7.2f} {rpFire[side][b]:>8} {fp:>7.2f} {me:>13.2f} {md:>6.0f}"
      let
        farF2 = rpFrames[side][2] + rpFrames[side][3] + rpFrames[side][4]
        farO2 = rpOpen[side][2] + rpOpen[side][3] + rpOpen[side][4]
        farFi2 = rpFire[side][2] + rpFire[side][3] + rpFire[side][4]
      echo &"    TOTAL {tf2:>9} {to2:>8} {100.0*to2.float/max(1,tf2).float:>7.2f} {tfi2:>8} {100.0*tfi2.float/max(1,tf2).float:>7.2f}"
      echo &"BEYOND300  frames {farF2}  open {farO2} ({100.0*farO2.float/max(1,farF2).float:.2f}%)  fire {farFi2}  shareOfShots {100.0*farFi2.float/max(1,tfi2).float:.2f}%"
    echo "--- RANGED CORRIDOR (all 16 bots pooled) ---"
    echo "band       frames     open   open%     fire   fire%  meanErrBrads  meanD"
    var tf, to, tfi = 0
    for b in 0 .. 4:
      let f = rpFrames[0][b] + rpFrames[1][b]
      tf += f; to += rpOpen[0][b] + rpOpen[1][b]; tfi += rpFire[0][b] + rpFire[1][b]
      let
        ob = rpOpen[0][b] + rpOpen[1][b]
        fb = rpFire[0][b] + rpFire[1][b]
        op = (if f > 0: 100.0 * ob.float / f.float else: 0.0)
        fp = (if f > 0: 100.0 * fb.float / f.float else: 0.0)
        me = (if f > 0: (rpErrSum[0][b] + rpErrSum[1][b]).float / f.float else: 0.0)
        md = (if f > 0: (rpDistSum[0][b] + rpDistSum[1][b]) / f.float else: 0.0)
      echo &"{bandName[b]:>9} {f:>9} {ob:>8} {op:>7.2f} {fb:>8} {fp:>7.2f} {me:>13.2f} {md:>6.0f}"
    echo &"    TOTAL {tf:>9} {to:>8} {100.0*to.float/max(1,tf).float:>7.2f} {tfi:>8} {100.0*tfi.float/max(1,tf).float:>7.2f}"
    let farF = rpFrames[0][2]+rpFrames[1][2]+rpFrames[0][3]+rpFrames[1][3]+rpFrames[0][4]+rpFrames[1][4]
    let farO = rpOpen[0][2]+rpOpen[1][2]+rpOpen[0][3]+rpOpen[1][3]+rpOpen[0][4]+rpOpen[1][4]
    let farFi = rpFire[0][2]+rpFire[1][2]+rpFire[0][3]+rpFire[1][3]+rpFire[0][4]+rpFire[1][4]
    echo &"BEYOND300  frames {farF}  open {farO} ({100.0*farO.float/max(1,farF).float:.2f}%)  fire {farFi}"
    echo &"SHOTSHARE  fire<150 {rpFire[0][0]+rpFire[1][0]}  fire>=300 {farFi}  share>=300 {100.0*farFi.float/max(1,tfi).float:.2f}%"
    echo &"SPINCAP    cappedFrames {rpCap[0]+rpCap[1]}  sumSlotErr {rpCapErr[0]+rpCapErr[1]}"

when isMainModule:
  main()
