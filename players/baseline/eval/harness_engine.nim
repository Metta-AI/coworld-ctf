## Headless in-process CTF engine wrapper for the eval / A-B harness.
##
## This module OWNS the engine types (SimServer, InputState, PlayerViewerState)
## and exposes only a primitive-typed surface: `string` packet blobs out,
## `uint8` button masks in, plain ints out for the scoreboard. That keeps the
## engine's `Team`/`enemy`/`flagHome` symbols from ever colliding with the
## baseline bot module (which declares its own `Team`, `enemy`, `flagHome`),
## so the driver can `include` the baseline verbatim and drive its BYTE-
## IDENTICAL decision path with zero edits to the shipped player.
##
## Fidelity contract (matches src/ctf/server.nim's live loop exactly):
##   * one sprite packet built per player per tick via
##     `buildSpriteProtocolPlayerUpdates` (real FOV/fog culling + delete-diffs),
##     so a per-slot `PlayerViewerState` MUST persist across ticks or the
##     bot's retained scene never sheds objects that left its vision;
##   * `sim.step(inputs, prevInputs)` with the bot's own level masks decoded
##     through `decodeInputMask` — a fresh A-press (attack and not prev.attack)
##     arms the 5-tick windup, exactly as the baseline self-pulses fire.

import
  std/[os, strutils],
  bitworld/spriteprotocol,
  ctf/sim,
  ctf/global

export spriteprotocol.InputState, spriteprotocol.decodeInputMask

when defined(rangehitprobe):
  import std/math
  const RangeHitNearPx = 150.0  ## the study's own band: 0-150px hit%.

when defined(ndprobe):
  import std/math

type
  EvalEngine* = ref object
    sim: SimServer
    viewers: seq[PlayerViewerState]  ## one retained viewer state per slot.
    prevInputs: seq[InputState]      ## last tick's decoded inputs (fire edge).
    curInputs: seq[InputState]       ## this tick's decoded inputs.
    redShots: int                    ## fresh tracers, tallied per tick.
    blueShots: int
    redHits: int                     ## shots that LANDED on a body (a "-1" damage
    blueHits: int                    ## pop, amount 1), credited to the SHOOTING team
                                     ## (= enemy of the victim's color; friendly-fire
                                     ## hits are negligible under the friendlyBlocked
                                     ## guard). redHits/redShots = our aim accuracy —
                                     ## the "we shoot the wall, daveey lands on the
                                     ## body" complaint, measured directly.
    redGrabs: int                    ## flag pickups (steals) credited per team,
    blueGrabs: int                   ## by watching flags[*].carrier transitions.
    teamGrabs*: array[4, int]        ## ⭐ N-TEAM STEALS (2026-08-18, the wbank
                                     ## A/B guardrail). red/blueGrabs credit by
                                     ## the VICTIM flag's colour, which on a
                                     ## 4-team board lumps three thieves into
                                     ## "blue". This credits the CARRIER's own
                                     ## engine team index instead, so a per-team
                                     ## steals-per-episode guardrail is real.
    prevCarrier: array[Team, int]    ## last tick's carrier index per flag.
    lastCarrierProg: array[Team, float]  ## carrier's fraction-of-map progress
                                     ## toward its capture edge, updated each tick.
    dropProgSum: array[Team, float]  ## Σ progress at which non-scoring drops
    dropCount: array[Team, int]      ## happened, per STEALING team (for the mean).
    grabTick: array[Team, int]       ## tick this flag was last grabbed off its
                                     ## pedestal (-1 when home), to age the run.
    survivalSum: array[Team, int]    ## Σ ticks a carrier lived after grabbing
    survivalCount: array[Team, int]  ## before a non-scoring death, per stealer.
    when defined(rangehitprobe):
      # -d:rangehitprobe (2026-08-07, v45 A/B reporting): range-banded shots/
      # hits, split at RangeHitNearPx (150px — the study's own band, "24pp vs
      # 3pp accuracy variance" was measured close-in). ShotFx already carries
      # the tracer's own (x0,y0)-(x1,y1) endpoints and whether it connected
      # (`hit`), so the range comes straight off the existing cosmetic tracer
      # — no engine change needed.
      redShotsNear, blueShotsNear: int
      redHitsNear, blueHitsNear: int
      redShotsFar, blueShotsFar: int
      redHitsFar, blueHitsFar: int
    when defined(shapeprobe):
      # -d:shapeprobe (2026-08-14, the Hermes SHAPE study): the geometry the
      # replay read on — how many bodies each side commits ACROSS the midline,
      # and which half its deaths fall in. Read straight off sim.players every
      # tick, so this is ENGINE truth, not a bot's belief about itself.
      #   spCross     own-half -> enemy-half transitions (one "crossing")
      #   spDeathOwn / spDeathEnemy   deaths bucketed by the half they fell in
      #   spDeepSum   Σ over ticks of (alive bodies standing in the enemy half);
      #               spDeepSum/spTicks = MEAN CONCURRENT DEEP BODIES, which is
      #               the shape number itself ("one runner, seven hold" ≈ 1.0)
      #   spDeepMax   most bodies deep at once across the episode
      spCross, spDeathOwn, spDeathEnemy, spDeepSum, spDeepMax: array[Team, int]
      spTicks: int
      spOwnLowX: array[Team, bool]   ## this team's own home sits in the low-x half
      spCenterX: float
      spWasDeep: seq[bool]           ## per slot: last tick's enemy-half flag
      spWasAlive: seq[bool]
      spLastX: seq[int]              ## last x seen ALIVE (i.e. where it died)

  SlotStat* = object
    slot*: int
    team*: int                       ## 0 = Red, 1 = Blue.
    kills*: int
    deaths*: int
    captures*: int
    lives*: int
    alive*: bool

  EpisodeResult* = object
    ticks*: int
    phaseOver*: bool
    winnerTeam*: int                 ## 0 Red, 1 Blue, -1 draw / unfinished.
    isDraw*: bool
    redKills*: int
    blueKills*: int
    redDeaths*: int                  ## deaths taken by each team; the lives
    blueDeaths*: int                 ## differential (kills-deaths) is the tiebreak.
    redLives*: int                   ## total lives remaining at game end
    blueLives*: int                  ## (Σ lives + 1 per still-alive player).
    redCaptures*: int
    blueCaptures*: int
    redShots*: int                   ## fresh tracers credited to Red shooters.
    blueShots*: int
    redHits*: int                    ## bullets that LANDED per team; redHits/redShots
    blueHits*: int                   ## is aim accuracy (the wall-vs-body miss metric).
    redGrabs*: int                   ## enemy-flag pickups by each team; the
    blueGrabs*: int                  ## grab->capture ratio is the conversion metric.
    redDropProgSum*: float           ## Σ progress-home (0..1) at each non-scoring
    blueDropProgSum*: float          ## carrier death, per stealing team, and the
    redDropCount*: int               ## count — mean = where the run home breaks.
    blueDropCount*: int
    redSurvivalSum*: int             ## Σ ticks a carrier lived after grabbing
    blueSurvivalSum*: int            ## before a non-scoring death (mean = how
    redSurvivalCount*: int           ## fast the grab is a death sentence; a
    blueSurvivalCount*: int          ## few ticks = dies IN the nest, not en route).
    slots*: seq[SlotStat]

proc newEvalEngine*(numPlayers: int, seed: int, maxTicks: int): EvalEngine =
  ## Builds a started headless game with `numPlayers` baseline-seatable slots.
  ## Seat i -> team (i mod 2): even Red, odd Blue, matching the live default.
  var config = defaultGameConfig()
  config.seed = seed
  config.maxTicks = maxTicks
  # ⚠️⚠️ LEAGUE PHYSICS, NOT ENGINE DEFAULTS. `defaultGameConfig()` ships
  # aimTurnRate = 1 slot/tick and gunRange = 1050, but every live paintbot
  # config (cfg_default/cfg_4ffa/cfg_4ffa8 + the hosted league) passes
  # aimTurnRate = 5 and gunRange = 1300. At rate 1 the GV36 slot servo is a
  # plain shortest-arc turn and the whole spin-budget family is INERT, so a
  # harness on the defaults silently measures nothing for any aim lever.
  # Override to the league values; AIMRATE / GUNRANGE reproduce the old runs.
  let
    aimRateEnv = getEnv("AIMRATE")
    gunRangeEnv = getEnv("GUNRANGE")
  config.aimTurnRate = (if aimRateEnv.len > 0: parseInt(aimRateEnv) else: 5)
  config.gunRange = (if gunRangeEnv.len > 0: parseInt(gunRangeEnv) else: 1300)
  config.maxGames = 0                # never auto-quit; harness owns the loop.
  # Generated-board probes (plan #16): the league draws a NEW map every episode,
  # and several policy reads (med-kit spots, shield spawns, endzones) are arena
  # formulas that are only true on `arena`. These env overrides let a probe run
  # the deterministic in-process rig on a GENERATED board. Unset = unchanged, so
  # every existing gate/probe output stays byte-identical. Harness-only file: it
  # is never compiled into /bin/baseline (the Dockerfile builds baseline.nim).
  if getEnv("EVAL_MAP").len > 0:
    config.mapPath = getEnv("EVAL_MAP")
  # ⭐ EVAL_MAPSPEC (2026-08-17, one-door validation): run the mirror on the
  # EXACT board a recorded league episode was played on. Every replay's config
  # carries the expanded geometry as `mapSpec` (sim_config.nim:695 fills it for
  # every "gen" map), and resolveCtfMapMetadata gives an explicit mapSpec
  # priority over mapPath/mapSeed — so this is byte-exact, not a regeneration.
  # ⚠️ REGENERATING FROM A SEED CANNOT WORK: the map name "gen-57711" carries
  # the generator's winning ATTEMPT seed, while the hosted config leaves
  # mapSeed at -1 — so `mapSeed=57711` runs generateCtfMap FROM 57711 and can
  # land on a different map. The recorded spec is the only exact handle.
  #   /tmp/door_entry.out <replay> --dump-mapspec /tmp/m.json
  #   EVAL_MAPSPEC=/tmp/m.json EVAL_SCORING=pot /tmp/grabprobe.out ...
  if getEnv("EVAL_MAPSPEC").len > 0:
    config.mapSpec = readFile(getEnv("EVAL_MAPSPEC"))
  if getEnv("EVAL_TEAMS").len > 0:
    config.teams = parseInt(getEnv("EVAL_TEAMS"))
  # ⭐⭐ EVAL_MAPSYM / EVAL_MAPSIZE (2026-08-18, RIG-FIDELITY AUDIT). `EVAL_MAP=gen`
  # with teams=4 draws scaledGenShell4 — a SQUARE rot90 corner/plus board. The
  # hosted 4-team league board measured off 155 v55 replays is a 1200x650
  # RECTANGLE with corner bases (median inter-base 1023px, nearest pair 429px);
  # the square rig board measures 545px median / 460px nearest, i.e. HALF the
  # separation and aspect 1.0 against the field's 1.85. That is the rectangular
  # `quadmirror` shell, which arena.nim documents as override-only — so the rig
  # was never on the hosted map FAMILY, and the difference is not cosmetic: on
  # the square board all 48 lives are gone by tick 1000 (field: 4.65 of 12),
  # which pins every life-economy metric at its ceiling. There was no env
  # passthrough for the mapGen overrides at all; EVAL_MAPSPEC (byte-exact
  # recorded board) is the stronger instrument, this is the cheap one.
  if getEnv("EVAL_MAPSYM").len > 0:
    config.mapGen.symmetry = getEnv("EVAL_MAPSYM")
  if getEnv("EVAL_MAPSIZE").len > 0:
    config.mapGen.size = getEnv("EVAL_MAPSIZE")
  # `quadmirror` alone still coin-flips corners vs plus, and the hosted board is
  # CORNERS: measured base centroids sit at the four corners of the 1200x650
  # rectangle (84,126)/(1098,93)/(179,537)/(1168,540), pair distances
  # 421/453/989/1014/1021/1160 — one near neighbour and two far, which is the
  # asymmetry the whole ffa4 territory model rests on. A `plus` draw on the same
  # shell gives 497/536/542/575/579/1000: four near neighbours and a different
  # game. EVAL_MAPSYM=quadmirror EVAL_MAPLAYOUT=corners is the pair.
  if getEnv("EVAL_MAPLAYOUT").len > 0:
    config.mapGen.layout = getEnv("EVAL_MAPLAYOUT")
  if getEnv("EVAL_SCORING").len > 0:
    config.scoring = getEnv("EVAL_SCORING")
  result = EvalEngine(sim: initSimServer(config))
  result.sim.gameEventLoggingEnabled = false  # keep the run quiet (a SimServer
                                              # field, defaults true post-init).
  when defined(roleprobe):
    # -d:roleprobe (2026-08-14, mid-quad break): the tier-2 sink is the only way
    # to see FRIENDLY FIRE, which is the crowding metric a MIRROR rig can
    # actually move (entry-y cannot — this rig's baseline is already 140-205px
    # where the field shows 5-31px). Field reading: 8.1% of half4 deaths are
    # own-colour (60 Picasso-on-Picasso, 42 from filler teammates) on exactly
    # the deal where three of four seats are mids.
    result.sim.collectEvents = true
  when defined(wkprobe):
    # -d:wkprobe (2026-08-07, kept permanently like canprobe/ssprobe): turn on
    # the tier-2 event sink so weaponKillCounts() below can read weapon-
    # attributed Kill events (weapon="gun"/"spray"/"grenade"). Off by default
    # (collectEvents costs real allocation), so every other probe build stays
    # exactly as fast.
    result.sim.collectEvents = true
  when defined(evdump):
    # -d:evdump (2026-08-18, RIG-FIDELITY AUDIT): turn on the SAME tier-2 event
    # sink the hosted extractor drains, so this rig can emit an event stream in
    # the byte-identical wire format (ctf/events.eventsJsonl) that
    # ~/.ctf/scout/events holds for the field. That is the only way to run ONE
    # analyser over both populations: any hand-rolled rig counter is a second
    # definition, and a definition mismatch is indistinguishable from a fidelity
    # gap. Never compiled into the shipped player.
    result.sim.collectEvents = true
  when defined(ndprobe):
    # -d:ndprobe (2026-08-14, the v56 nade package): the tier-2 sink carries
    # GrenadeThrow / GrenadeImpact / Pickup, which is the only ENGINE-TRUTH
    # source for throws, supply and blast multiplicity (a policy-side counter
    # of what the bot BELIEVES is not the field metric).
    result.sim.collectEvents = true
  for i in 0 ..< numPlayers:
    discard result.sim.addPlayer("bot" & $i, trusted = true)
  result.sim.startGame()
  when defined(ndprobe):
    # Print the sim's OWN grenade spawn geometry, once per episode. This is the
    # evidence for nadeSupply's premise: the four corners are derived from map
    # size + layout alone (grenadeSpawnPoints), planted with no
    # nearest-walkable nudge, and never move for the whole episode — i.e. they
    # are STATIC KNOWN POINTS like the shield/plasma-arc spawns, not something
    # the 90px vision bubble has to find.
    var pts = ""
    for sp in result.sim.grenadeSpawns:
      pts.add " " & $sp.x & "," & $sp.y
    echo "NDMAP ", result.sim.gameMap.width, "x", result.sim.gameMap.height,
      " layout=", result.sim.gameMap.layout, " teams=", result.sim.config.teams,
      " grenadeSpawns:", pts
  result.viewers = newSeq[PlayerViewerState](numPlayers)
  for i in 0 ..< numPlayers:
    result.viewers[i] = initPlayerViewerState()
  result.prevInputs = newSeq[InputState](numPlayers)
  result.curInputs = newSeq[InputState](numPlayers)
  for team in Team:
    result.prevCarrier[team] = -1
    result.grabTick[team] = -1
  when defined(shapeprobe):
    # The two pedestals are mirrored across the midline on every board, so their
    # midpoint IS the centre line — no map-width constant needed (and it stays
    # correct on generated boards, which the width constant would not).
    let
      redHomeX = result.sim.gameMap.flagHome(Red).x.float
      blueHomeX = result.sim.gameMap.flagHome(Blue).x.float
    result.spCenterX = (redHomeX + blueHomeX) / 2.0
    result.spOwnLowX[Red] = redHomeX < result.spCenterX
    result.spOwnLowX[Blue] = blueHomeX < result.spCenterX
    result.spWasDeep = newSeq[bool](numPlayers)
    result.spWasAlive = newSeq[bool](numPlayers)
    result.spLastX = newSeq[int](numPlayers)
    for i in 0 ..< numPlayers:
      result.spWasAlive[i] = true
      result.spLastX[i] = result.sim.players[i].x

proc playerCount*(engine: EvalEngine): int =
  engine.sim.players.len

proc teamOfSlot*(engine: EvalEngine, slot: int): int =
  ## 0 Red / 1 Blue, read straight off the seated player.
  ord(engine.sim.players[slot].team)

proc slotLifeState*(engine: EvalEngine, slot: int): tuple[hp, lives: int, alive: bool] =
  ## GROUND-TRUTH hp/lives/alive for one seat, straight off sim.players — for
  ## the ffa4 lives audit (2026-08-17): "lives spent by half-time", medkit
  ## takes, and P(escape|hp==1) all need ground truth sampled every tick, not
  ## the bot's own fogged/label-parsed perception (the 2026-08-05 field-metric
  ## rule). Unconditional, not probe-gated: a read-only accessor with no
  ## gameplay effect, and this module never compiles into the shipped player.
  let p = engine.sim.players[slot]
  (hp: p.hp, lives: p.lives, alive: p.alive)

proc isPlaying*(engine: EvalEngine): bool =
  engine.sim.phase == Playing

when defined(ohshitprobe):
  import std/math
  proc nearestEnemyMate*(engine: EvalEngine, slot: int): tuple[e, m: float] =
    ## Ground-truth nearest living enemy / mate distance to `slot` (probe only).
    let me = engine.sim.players[slot]
    var nE = 1e9
    var nM = 1e9
    for j in 0 ..< engine.sim.players.len:
      if j == slot or not engine.sim.players[j].alive: continue
      let q = engine.sim.players[j]
      let dd = sqrt(float((me.x - q.x) * (me.x - q.x) +
                          (me.y - q.y) * (me.y - q.y)))
      if q.team == me.team:
        if dd < nM: nM = dd
      else:
        if dd < nE: nE = dd
    (e: nE, m: nM)

when defined(rwtruth):
  proc slotTruth*(engine: EvalEngine, slot: int):
      tuple[x, y: float, alive: bool, team: int] =
    ## GROUND TRUTH position/liveness for one seat, straight off `sim.players` —
    ## never the bot's own fogged perception (the 2026-08-05 field-metric rule:
    ## a `-d:` probe that counts what the bot BELIEVES is not the field metric).
    ## Probe builds only; the shipped player never sees this module.
    let p = engine.sim.players[slot]
    (x: float(p.x), y: float(p.y), alive: p.alive, team: ord(p.team))

when defined(fpprobe):
  proc slotVitals*(engine: EvalEngine, slot: int):
      tuple[hp: int, alive: bool, deaths: int, lives: int, x, y: int] =
    ## GROUND TRUTH vitals for one seat (probe builds only). The ffa4 metrics
    ## are life-economy metrics — lives spent by half-time, P(escape | hp==1) —
    ## and neither can be read from a bot's own fogged belief. Straight off
    ## sim.players, same source the hosted results JSON is built from.
    let p = engine.sim.players[slot]
    (hp: p.hp, alive: p.alive, deaths: p.deaths, lives: p.lives,
     x: int(p.x), y: int(p.y))

  proc slotCaptures*(engine: EvalEngine, slot: int): int =
    engine.sim.players[slot].captures

when defined(ssprobe):
  # v7-only: count accidental sword/shield possession (auto-disarm). The
  # hasSword/hasShield fields exist only on the GameVersion 7 engine, so this
  # accessor compiles ONLY in the v7 worktree under -d:ssprobe.
  proc swordShieldOf*(engine: EvalEngine, slot: int):
      tuple[sword, shield, alive: bool] =
    let p = engine.sim.players[slot]
    (sword: p.hasSword, shield: p.hasShield, alive: p.alive)

when defined(wkprobe):
  # -d:wkprobe (2026-08-07, kept permanently — the utility-weapon kill-share
  # audit tool): drains the tier-2 event stream ONCE at episode end and
  # tallies weapon-attributed Kill events (weapon="gun"/"spray"/"grenade")
  # per team. `source` on a SimEvent is the killer's stable JOIN slot
  # (sim_state.eventSlot / player.joinOrder), not necessarily the raw player
  # index, so build the join-slot->team map the same way
  # tools/extract_events.nim does (slotTeam[player.joinOrder] = player.team)
  # rather than assuming they match.
  proc weaponKillCounts*(engine: EvalEngine): tuple[
      redGun, blueGun, redSpray, blueSpray, redNade, blueNade: int] =
    var teamOfJoinSlot = newSeq[Team](engine.sim.players.len)
    for p in engine.sim.players:
      if p.joinOrder >= 0 and p.joinOrder < teamOfJoinSlot.len:
        teamOfJoinSlot[p.joinOrder] = p.team
    for e in engine.sim.events:
      if e.kind != Kill: continue
      if e.source < 0 or e.source >= teamOfJoinSlot.len: continue
      let isRed = teamOfJoinSlot[e.source] == Red
      case e.weapon
      of "gun":
        if isRed: inc result.redGun else: inc result.blueGun
      of "spray":
        if isRed: inc result.redSpray else: inc result.blueSpray
      of "grenade":
        if isRed: inc result.redNade else: inc result.blueNade
      else: discard

when defined(roleprobe):
  # ⭐⭐ FRIENDLY FIRE — the crowding metric, measured not inferred. Friendly fire
  # is ON in this engine (selectFireTarget stops at the FIRST body, whoever it
  # belongs to), so two of ours in one corridor is not a figure of speech: it is
  # a teammate standing on the ray. Field: 8.1% of half4 deaths came from our own
  # colour. Split by weapon because the two mechanisms are different — a `gun`
  # own-kill is a body on the line, a `grenade` own-kill is the blast catching a
  # cluster (the 58.4% stat), and the mid quad predicts BOTH.
  #
  # ⚠️ `source`/`target` are stable JOIN slots, not raw player indices — the same
  # trap weaponKillCounts documents. Build the join-slot map, never assume they
  # match.
  proc friendlyFireCounts*(engine: EvalEngine): tuple[
      kills, ffKills, ffGun, ffNade, ffSpray,
      dmg, ffDmg: int] =
    var teamOfJoinSlot = newSeq[int](engine.sim.players.len)
    for i in 0 ..< teamOfJoinSlot.len: teamOfJoinSlot[i] = -1
    for p in engine.sim.players:
      if p.joinOrder >= 0 and p.joinOrder < teamOfJoinSlot.len:
        teamOfJoinSlot[p.joinOrder] = ord(p.team)
    for e in engine.sim.events:
      if e.kind notin {Kill, Damage}: continue
      if e.source < 0 or e.source >= teamOfJoinSlot.len: continue
      if e.target < 0 or e.target >= teamOfJoinSlot.len: continue
      let st = teamOfJoinSlot[e.source]
      let tt = teamOfJoinSlot[e.target]
      if st < 0 or tt < 0: continue
      # Self-damage (own grenade at own feet) is a different defect from
      # shooting a MATE, and only the second one is crowding. Exclude it.
      let friendly = st == tt and e.source != e.target
      if e.kind == Kill:
        inc result.kills
        if friendly:
          inc result.ffKills
          case e.weapon
          of "gun": inc result.ffGun
          of "grenade": inc result.ffNade
          of "spray": inc result.ffSpray
          else: discard
      else:
        inc result.dmg
        if friendly: inc result.ffDmg

when defined(canprobe):
  # -d:canprobe: engine-side TRUTH for the spray-can pickup path — whether the
  # slot is actually holding a can this tick. Paired with the policy-side
  # cpSeen/cpSeek counters this splits "never saw one" from "saw one, declined"
  # from "sought one and missed". The field name is still the pre-0.7.x
  # `hasPlasmaArc`; only the WIRE label was renamed to `spray can`.
  proc sprayOf*(engine: EvalEngine, slot: int): tuple[can, alive: bool] =
    let p = engine.sim.players[slot]
    (can: p.hasPlasmaArc, alive: p.alive)

when defined(ndprobe):
  # -d:ndprobe: ENGINE TRUTH for the v56 nade package.
  type NdRec* = object
    ## One grenade-relevant tier-2 event, flattened for the harness.
    ## kind: 0 = GrenadeThrow, 1 = GrenadeImpact, 2 = grenade Pickup.
    kind*: int
    tick*: int
    slot*: int                 ## acting player's stable JOIN slot (-1 = n/a)
    team*: int                 ## that player's team ordinal (-1 = n/a)
    actionId*: int64           ## ties a throw to its impact
    victims*: array[4, int]    ## on an impact: bodies damaged, per team

  proc ndGrenadeRecs*(engine: EvalEngine): seq[NdRec] =
    ## Drains the collected event stream into throw / impact / pickup records.
    ## `source` is a stable JOIN slot, not the raw player index, so map it the
    ## same way weaponKillCounts and tools/extract_events.nim do.
    var teamOfJoinSlot = newSeq[int](engine.sim.players.len)
    for i in 0 ..< teamOfJoinSlot.len: teamOfJoinSlot[i] = -1
    for p in engine.sim.players:
      if p.joinOrder >= 0 and p.joinOrder < teamOfJoinSlot.len:
        teamOfJoinSlot[p.joinOrder] = ord(p.team)
    proc teamOf(s: int): int =
      if s >= 0 and s < teamOfJoinSlot.len: teamOfJoinSlot[s] else: -1
    for e in engine.sim.events:
      case e.kind
      of GrenadeThrow:
        result.add NdRec(kind: 0, tick: e.tick, slot: e.source,
                         team: teamOf(e.source), actionId: e.actionId)
      of GrenadeImpact:
        var rec = NdRec(kind: 1, tick: e.tick, slot: e.source,
                        team: teamOf(e.source), actionId: e.actionId)
        for d in e.damages:
          let t = teamOf(d.slot)
          if t in 0 .. 3: inc rec.victims[t]
        result.add rec
      of Pickup:
        if e.item == "grenade":
          result.add NdRec(kind: 2, tick: e.tick, slot: e.source,
                           team: teamOf(e.source), actionId: e.actionId)
      else: discard

  proc ndSpacingSample*(engine: EvalEngine): tuple[
      bots, underBlast: int, sumNearest: float, hist: array[6, int]] =
    ## GROUND-TRUTH nearest-living-mate distance for every living bot this
    ## tick. `underBlast` = bodies whose nearest mate sits inside NadeBlast,
    ## i.e. the population one enemy grenade takes two of. Histogram buckets
    ## (px): 0-26, 26-52, 52-66, 66-100, 100-200, 200+.
    for i in 0 ..< engine.sim.players.len:
      let me = engine.sim.players[i]
      if not me.alive: continue
      var nearest = 1e9
      for j in 0 ..< engine.sim.players.len:
        if j == i: continue
        let q = engine.sim.players[j]
        if not q.alive or q.team != me.team: continue
        let d = sqrt(float((me.x - q.x) * (me.x - q.x) +
                           (me.y - q.y) * (me.y - q.y)))
        if d < nearest: nearest = d
      if nearest > 1e8: continue         # no living mate: not a pair at all
      inc result.bots
      result.sumNearest += nearest
      if nearest <= GrenadeBlastRadius.float: inc result.underBlast
      let b =
        if nearest < 26.0: 0
        elif nearest < 52.0: 1
        elif nearest < 66.0: 2
        elif nearest < 100.0: 3
        elif nearest < 200.0: 4
        else: 5
      inc result.hist[b]

proc frameFor*(engine: EvalEngine, slot: int): string =
  ## The exact sprite packet blob the live server would send this slot this
  ## tick: real fogged view, delta-encoded against the slot's retained viewer.
  var nextState: PlayerViewerState
  let packet = engine.sim.buildSpriteProtocolPlayerUpdates(
    slot, engine.viewers[slot], nextState)
  engine.viewers[slot] = nextState
  blobFromBytes(packet)

proc setMask*(engine: EvalEngine, slot: int, mask: uint8) =
  ## Records one bot's chosen button mask for the pending step.
  engine.curInputs[slot] = decodeInputMask(mask)

proc applyShout*(engine: EvalEngine, slot: int, text: string) =
  ## Registers one bot's shout into the sim exactly as the live server does:
  ## the server buffers each player's chat during the tick window and calls
  ## `sim.applyShout(playerIndex, chatText)` for every one just before
  ## `sim.step` (server.nim ~1015-1026). The sim enforces the alive-only,
  ## one-per-second, one-bubble-per-player rules; the shout lands in
  ## `recentShouts` and is delivered to every audible viewer on the NEXT
  ## frame build — so a bot hears a mate's shout the frame after it is made,
  ## matching the hosted timing the reaction logic was tuned against.
  engine.sim.applyShout(slot, text)

proc advance*(engine: EvalEngine) =
  ## Steps the sim one tick with the recorded masks, then rolls the fire edge.
  ## A shot's tracer is stamped with the tick it fired, so tallying tracers
  ## whose firedTick == the just-completed tick counts every shot released
  ## this step exactly once (recentShots is pruned only after ShotFxTicks).
  engine.sim.step(engine.curInputs, engine.prevInputs)
  for i in 0 ..< engine.prevInputs.len:
    engine.prevInputs[i] = engine.curInputs[i]
  let firedTick = engine.sim.tickCount
  for shot in engine.sim.recentShots:
    if shot.firedTick == firedTick:
      if shot.color == teamColor(Red): inc engine.redShots
      elif shot.color == teamColor(Blue): inc engine.blueShots
      when defined(rangehitprobe):
        # ShotFx's own tracer endpoints give the shot's range directly — no
        # cross-referencing against damagePops needed, and `hit` already
        # says whether THIS shot connected.
        let rng = hypot(float(shot.x1 - shot.x0), float(shot.y1 - shot.y0))
        let near = rng < RangeHitNearPx
        if shot.color == teamColor(Red):
          if near:
            inc engine.redShotsNear
            if shot.hit: inc engine.redHitsNear
          else:
            inc engine.redShotsFar
            if shot.hit: inc engine.redHitsFar
        elif shot.color == teamColor(Blue):
          if near:
            inc engine.blueShotsNear
            if shot.hit: inc engine.blueHitsNear
          else:
            inc engine.blueShotsFar
            if shot.hit: inc engine.blueHitsFar
  when defined(shapeprobe):
    # SHAPE geometry, sampled after the step so positions are this tick's truth.
    inc engine.spTicks
    var deepNow: array[Team, int]
    for i in 0 ..< engine.sim.players.len:
      let p = engine.sim.players[i]
      let t = p.team
      if p.alive:
        let deep = (if engine.spOwnLowX[t]: p.x.float > engine.spCenterX
                    else: p.x.float < engine.spCenterX)
        if deep:
          inc deepNow[t]
          if not engine.spWasDeep[i]:
            inc engine.spCross[t]     # a fresh own-half -> enemy-half crossing
        engine.spWasDeep[i] = deep
        engine.spLastX[i] = p.x
      else:
        if engine.spWasAlive[i]:
          # Death: bucket it by the half the body was standing in last tick.
          let inEnemy = (if engine.spOwnLowX[t]: engine.spLastX[i].float > engine.spCenterX
                         else: engine.spLastX[i].float < engine.spCenterX)
          if inEnemy: inc engine.spDeathEnemy[t] else: inc engine.spDeathOwn[t]
        engine.spWasDeep[i] = false   # a respawn starts home; re-crossing counts again
      engine.spWasAlive[i] = p.alive
    for t in Team:
      engine.spDeepSum[t] += deepNow[t]
      if deepNow[t] > engine.spDeepMax[t]: engine.spDeepMax[t] = deepNow[t]

  # Gun-hit tally: a fresh "-1" damage pop (amount 1 = a bullet, not the amount-2
  # grenade blast) landed on a body THIS tick. Credit the SHOOTER = the enemy of
  # the victim's color, so redHits counts Red's bullets that connected. Paired
  # with redShots this is the direct aim-accuracy signal.
  for pop in engine.sim.damagePops:
    if pop.tick == firedTick and pop.amount == 1:
      if pop.color == teamColor(Red): inc engine.blueHits    # Red victim -> Blue shot
      elif pop.color == teamColor(Blue): inc engine.redHits
  # Flag-grab tally + drop-location diagnosis. A carrier index rising from -1
  # to a live player is a fresh steal; credit the STEALING team (a flag is
  # stolen by the opposing team, so flagTeam Blue -> a Red grab). A carrier
  # falling to -1 while the game is still Playing is a NON-SCORING DROP (the
  # carrier was killed en route — a capture instead ends the game with the
  # carrier still set), so we log how far home it had gotten: 0.0 = dropped at
  # the enemy pedestal it just robbed, 1.0 = at its own capture edge. The mean
  # drop-progress tells us WHERE the run home breaks down.
  let stillPlaying = engine.sim.phase == Playing
  for team in Team:
    let carrier = engine.sim.flags[team].carrier
    # Update this carrier's progress-home while it holds the flag.
    if carrier >= 0:
      let
        # `enemy(team)` is gone from the engine: with up to four teams there is
        # no single "the opposing team". For this 2-team harness metric the
        # other side of a 2-team board is the only meaningful reading.
        stealer = (if team == Red: Blue else: Red)
        startX = engine.sim.gameMap.flagHome(team).x.float     # robbed pedestal
        endX = engine.sim.gameMap.flagHome(stealer).x.float    # own home edge
        flagX = engine.sim.flags[team].x.float
        span = (if startX != endX: startX - endX else: 1.0)
      engine.lastCarrierProg[team] = clamp((startX - flagX) / span, 0.0, 1.0)
    if carrier >= 0 and engine.prevCarrier[team] < 0:
      engine.grabTick[team] = engine.sim.tickCount    # start the survival clock
      if team == Blue: inc engine.redGrabs else: inc engine.blueGrabs
      # n-team truth: credit the thief, by raw engine team index.
      let thiefTeam = ord(engine.sim.players[carrier].team)
      if thiefTeam in 0 .. 3: inc engine.teamGrabs[thiefTeam]
    elif carrier < 0 and engine.prevCarrier[team] >= 0 and stillPlaying:
      # Non-scoring drop: attribute the failed run to the stealing team.
      let lived = engine.sim.tickCount - engine.grabTick[team]
      if team == Blue:
        engine.dropProgSum[Red] += engine.lastCarrierProg[team]
        inc engine.dropCount[Red]
        engine.survivalSum[Red] += lived
        inc engine.survivalCount[Red]
      else:
        engine.dropProgSum[Blue] += engine.lastCarrierProg[team]
        inc engine.dropCount[Blue]
        engine.survivalSum[Blue] += lived
        inc engine.survivalCount[Blue]
    engine.prevCarrier[team] = carrier

when defined(rangehitprobe):
  proc rangeHitCounts*(engine: EvalEngine): tuple[
      redShotsNear, redHitsNear, blueShotsNear, blueHitsNear,
      redShotsFar, redHitsFar, blueShotsFar, blueHitsFar: int] =
    (redShotsNear: engine.redShotsNear, redHitsNear: engine.redHitsNear,
     blueShotsNear: engine.blueShotsNear, blueHitsNear: engine.blueHitsNear,
     redShotsFar: engine.redShotsFar, redHitsFar: engine.redHitsFar,
     blueShotsFar: engine.blueShotsFar, blueHitsFar: engine.blueHitsFar)

when defined(shapeprobe):
  proc shapeCounts*(engine: EvalEngine, team: int): tuple[
      cross, deathOwn, deathEnemy, deepSum, deepMax, ticks: int] =
    ## Per-team SHAPE geometry for the episode just run. `deepSum/ticks` is the
    ## mean number of that team's bodies standing in the ENEMY half at any tick.
    let t = Team(team)
    (cross: engine.spCross[t], deathOwn: engine.spDeathOwn[t],
     deathEnemy: engine.spDeathEnemy[t], deepSum: engine.spDeepSum[t],
     deepMax: engine.spDeepMax[t], ticks: engine.spTicks)

proc result*(engine: EvalEngine): EpisodeResult =
  ## Snapshots the scoreboard from live sim fields (all authoritative — the
  ## same counters the hosted results JSON is built from).
  let sim = engine.sim
  result.ticks = sim.tickCount
  result.phaseOver = sim.phase == GameOver
  result.isDraw = sim.isDraw
  result.winnerTeam =
    if not result.phaseOver or sim.isDraw: -1
    else: ord(sim.winner)
  result.redShots = engine.redShots
  result.blueShots = engine.blueShots
  result.redHits = engine.redHits
  result.blueHits = engine.blueHits
  result.redGrabs = engine.redGrabs
  result.blueGrabs = engine.blueGrabs
  result.redDropProgSum = engine.dropProgSum[Red]
  result.blueDropProgSum = engine.dropProgSum[Blue]
  result.redDropCount = engine.dropCount[Red]
  result.blueDropCount = engine.dropCount[Blue]
  result.redSurvivalSum = engine.survivalSum[Red]
  result.blueSurvivalSum = engine.survivalSum[Blue]
  result.redSurvivalCount = engine.survivalCount[Red]
  result.blueSurvivalCount = engine.survivalCount[Blue]
  for i in 0 ..< sim.players.len:
    let p = sim.players[i]
    let team = ord(p.team)
    result.slots.add SlotStat(
      slot: i, team: team, kills: p.kills, deaths: p.deaths,
      captures: p.captures, lives: p.lives, alive: p.alive)
    let livesNow = p.lives + (if p.alive: 1 else: 0)
    if team == 0:
      result.redKills += p.kills
      result.redDeaths += p.deaths
      result.redLives += livesNow
      result.redCaptures += p.captures
    else:
      result.blueKills += p.kills
      result.blueDeaths += p.deaths
      result.blueLives += livesNow
      result.blueCaptures += p.captures


when defined(evdump):
  # ⭐ RIG-FIDELITY AUDIT (2026-08-18). Emits this episode in the hosted
  # replay-extraction wire format so ffa4_corpus.py's field analysers run over
  # rig episodes unchanged. Seats are keyed by joinOrder exactly as
  # tools/extract_events.nim does — `source`/`target` on a SimEvent are stable
  # join slots, NOT raw player indices, and on a 16-slot deal they are only
  # accidentally equal.
  import std/json
  import ctf/events as ctfevents

  const EvColorName = ["red", "blue", "green", "yellow", "purple", "orange",
                       "cyan", "pink"]

  proc evTeamColor(t: int): string =
    if t >= 0 and t < EvColorName.len: EvColorName[t] else: "team" & $t

  proc evJsonl*(engine: EvalEngine, address: seq[string]): string =
    ## The full JSON-lines stream for the episode just played, summary row
    ## included, in the same shape ~/.ctf/scout/events files carry.
    let n = engine.sim.players.len
    var slotTeam = newSeq[string](n)
    var slotAddr = newSeq[string](n)
    for i in 0 ..< n:
      let jo = engine.sim.players[i].joinOrder
      if jo < 0 or jo >= n: continue
      slotTeam[jo] = evTeamColor(ord(engine.sim.players[i].team))
      slotAddr[jo] = (if i < address.len: address[i] else: "bot" & $i)
    var roster = newJObject()
    roster["finished"] = %(engine.sim.phase == GameOver)
    roster["draw"] = %engine.sim.isDraw
    roster["winner"] = %(if engine.sim.isDraw: ""
                         else: evTeamColor(ord(engine.sim.winner)))
    roster["slot_address"] = %slotAddr
    roster["slot_team"] = %slotTeam
    roster["slot_shots_fired"] = %newSeq[int](n)
    roster["slot_shots_hit"] = %newSeq[int](n)
    ctfevents.eventsJsonl(engine.sim.events, engine.sim.tickCount, roster)
