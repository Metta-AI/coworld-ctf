## track_census — the POLICY's enemy TRACK TABLE measured against engine
## GROUND TRUTH, from one re-simulated hosted replay.
##
## WHY. `updateTracks` (players/baseline/baseline.nim) is the policy's whole
## model of "who is out there". It matches this frame's sightings to remembered
## tracks BY POSITION within TrackMatchDist(40px), keeps a track for TrackTtl
## (120 ticks) and then TRUNCATES the table to TrackCap = 8 — a constant
## introduced in "cover-based tactics for 8v8", i.e. sized for a 2-team board
## with eight opponents. A four-team board has TWELVE. Everything downstream
## (target selection, dangerScore, the friendGuns-enemyGuns tally the tradeGate
## keys on, local-numbers estimates) reads this table, so any duplication or
## eviction is a PERCEPTION defect upstream of every behavioural lever.
##
## THE INSTRUMENT. The track table is a PURE FUNCTION of the sighting stream,
## and the sighting stream is a pure function of ground-truth positions + the
## engine's own fog model. So we do not need to re-run the policy: we replay the
## episode exactly as it happened, ask the engine who each seat could SEE on
## each tick, and run a byte-faithful copy of updateTracks over that stream —
## while carrying, for MEASUREMENT ONLY, the ground-truth slot that owns each
## track. Divergence between the table and the truth is then directly readable.
##
## ⚠️ THE GHOST WINDOW. global.nim's viewer builder gives a DEAD viewer the
## whole map unfogged ("Ghost viewers (dead players) watch the whole map"), and
## the policy's perception intake runs on every frame including dead ones. So
## for the RespawnTicks(72) after each death the policy is handed all 12 live
## enemies at once against an 8-slot table. This is modelled exactly.
##
## Traps defended against:
##   * Only `Playing` ticks count (the lobby parks everyone on a pedestal).
##   * Identity is `player.address`; seats are `joinOrder` (sim indices shift).
##   * A track's `owner` is ground truth the POLICY never has — measurement only.
##   * The tally/near numbers are computed on ALIVE ticks only (a dead seat's
##     position is frozen).
##   * fovBlocked is re-read every tick via refreshPlayerFov (diamonds rotate).
##
## Output: one JSON object per replay on stdout (JSONL when many are passed).
## Usage: track_census <replay-path> [<replay-path>...]

import
  std/[algorithm, json, math, os, strutils],
  ../src/ctf/[sim, sim_types, sim_state],
  toolutil

const
  # --- verbatim from players/baseline/baseline.nim -----------------------
  TrackMatchDist = 40.0     ## a sighting matches a track within this distance
  TrackTtl = 120            ## forget a player not seen for ~5s
  TrackCap = 8              ## "eight real opponents / teammates per side"
  FreshShotTicks = 24       ## only fire at tracks seen this recently
  LocalFreshTicks = 20      ## a track counts toward local balance only if fresh
  RetreatRadius = 260.0     ## local force-balance radius
  ShieldGunWeight = 1.5     ## a shielded enemy is this many guns
  PolMaxHp = 3              ## MaxHp the policy assumes
  # --- analysis windows ---------------------------------------------------
  BigCap = 64               ## the UNCAPPED counterfactual arm
  KillFxTicks = 44          ## engine: how long a `damage pop <color> KO` lives
  DeathLookback = 30        ## ticks before a death that count as "preceding"
  VisBins = 17

type
  Sight = object
    x, y: float
    slot: int
    hp: int
    shield: bool

  Trk = object
    x, y: float
    lastSeen: int
    sightings: int
    hp: int
    shield: bool
    owner: int              ## GROUND TRUTH: slot that last updated this track.
    born: int

  SeatAgg = object
    seat: int
    address: string
    team: int
    seen: bool
    deaths, kills: int
    tAlive, tGhost: int             ## Playing ticks alive / dead
    tGhostResp, tGhostElim: int     ## ...respawning (lives>0) vs eliminated
    visHist: array[VisBins, int]    ## visible-enemy count histogram (alive ticks)
    visHistGhost: array[VisBins, int]
    # duplicates
    dupExtra, dupTicks: int             ## live tracks minus distinct owners
    dupExtraG, dupTicksG: int           ## ...during the ghost window
    dupF24Extra, dupF24Ticks: int       ## duplicates inside FreshShotTicks
    dupF20Extra, dupF20Ticks: int       ## ...inside the tally window
    # eviction
    capTicks, capTicksG: int            ## ticks the TrackCap actually truncated
    evTracks: int                       ## tracks discarded by the cap
    evLostBodies: int                   ## ...that left an alive body with NO track
    evLostVisible: int                  ## ...and that body was VISIBLE this tick
    evLostGhostWin: int                 ## lost bodies discarded during ghost window
    missVisible: int                    ## visible alive enemies absent from table
    missVisTicks: int
    # tally (alive ticks only)
    tallyN: int
    eTrk, eTruth: float                 ## enemyGuns from table vs from truth
    fTrk, fTruth: float                 ## friendGuns likewise
    marginErrSum, marginErrAbs, marginErrSq: float
    marginUnder, marginOver, marginExact: int   ## sign of (trk - truth)
    tallyDisagree: int
    # near
    nearN: int
    nearTrkSum, nearTruthSum: float
    nearTrkBlind: int                   ## no fresh track at all
    nearTrkN: int
    # --- fog-free comparator: only bodies we COULD have perceived ---------
    ePerc, fPerc: float
    pMarginErrSum, pMarginErrAbs, pMarginErrSq: float
    pMarginUnder, pMarginOver, pMarginExact: int
    pTallyDisagree: int
    # --- fresh tracks pointing at a DEAD body (v48 kill-release is dead) ---
    deadFreshTracks, deadFreshTicks: int
    deadTtlTracks: int
    ## ...of those, how many a `damage pop <color> KO` we could SEE would kill
    deadFreshKoSeen, deadTtlKoSeen: int
    koDeaths, koDeathsSeen, koDeathsTracked, koDeathsTrackedFresh: int
    ## --- ARM C: the same table with a KO-pop kill-release applied ---------
    cDupExtra, cDupTicks, cDupF24Ticks, cDupF20Ticks: int
    cDeadFreshTracks, cDeadFreshTicks: int
    cKnownSmall: int
    cMarginErrSum, cMarginErrAbs: float
    cMarginExact, cTallyDisagree, cVsBaseDisagree: int
    cReleased: int
    # --- positional error of fresh tracks on live bodies -------------------
    posErrN: int
    posErrSum, posErrMax: float
    posErrOver40: int
    # --- the UNCAPPED counterfactual --------------------------------------
    knownSmallSum, knownBigSum, knownN: int   ## distinct alive enemies held
    aKnownN, aKnownSmall, aKnownBig, aBigOnly, aBigOnlyTicks: int  ## ALIVE ticks only
    aKnownFresh, aTruthVisFresh: int          ## ...inside FreshShotTicks / truly visible-recently
    bigOnlySum: int                            ## bodies the big table has and the small does not
    bigOnlyTicks: int
    bigTallyDisagree: int
    bigMarginErrSum: float
    # --- respawn census ----------------------------------------------------
    respawnN: int
    respawnKnown, respawnKnownBig, respawnEnemiesAlive: int
    # --- realized coverage for the CAP fix --------------------------------
    deathKillerBigOnly: int
    earlyDeathKillerBigOnly: int
    # realized coverage for the futility bound
    deathsScored: int
    deathKillerDup: int
    deathKillerEvicted: int
    deathKillerMistracked: int          ## dup OR evicted in the lookback
    deathKillerUntracked: int           ## no track for the killer at death tick
    deathKillerVisible: int             ## killer visible at the death tick
    earlyDeathsScored: int
    earlyMistracked: int

proc idx(v: int): int = clamp(v, 0, VisBins - 1)

proc runOne(path: string): JsonNode =
  var (game, replay) = openReplay(path.absolutePath(), mismatchQuit = false)
  game.collectEvents = true
  var slotCount = game.config.slots.len
  if slotCount == 0:
    slotCount = game.config.playerSlotLimit()
  let teamCount = game.config.teams

  var
    aggs = newSeq[SeatAgg](slotCount)
    eTracks = newSeq[seq[Trk]](slotCount)     ## per seat: the ENEMY table
    eBig = newSeq[seq[Trk]](slotCount)        ## ...the UNCAPPED counterfactual
    eKo = newSeq[seq[Trk]](slotCount)         ## ...with a KO-pop kill-release
    mTracks = newSeq[seq[Trk]](slotCount)     ## per seat: the MATE table
    # per (seat, enemy slot) last-tick markers, for the death lookback
    lastDup = newSeq[int](slotCount * slotCount)
    lastEvict = newSeq[int](slotCount * slotCount)
    lastVisible = newSeq[int](slotCount * slotCount)
    lastTracked = newSeq[int](slotCount * slotCount)
    lastBigOnly = newSeq[int](slotCount * slotCount)
    koDeathTick = newSeq[int](slotCount)          ## victim slot -> death tick
    deathSpotX = newSeq[float](slotCount)
    deathSpotY = newSeq[float](slotCount)
    koSeenTick = newSeq[int](slotCount * slotCount)  ## (seat,victim) -> pop seen
    wasAlive = newSeq[bool](slotCount)
    plives = newSeq[int](slotCount)
    seatOf = newSeq[int](slotCount)
    px = newSeq[float](slotCount)
    py = newSeq[float](slotCount)
    palive = newSeq[bool](slotCount)
    pteam = newSeq[int](slotCount)
    php = newSeq[int](slotCount)
    pshield = newSeq[bool](slotCount)
    playStart = -1
    lastTick = 0
  for s in 0 ..< slotCount:
    aggs[s].seat = s
    aggs[s].team = -1
    koDeathTick[s] = -1
    deathSpotX[s] = -1.0
  for i in 0 ..< slotCount * slotCount:
    lastDup[i] = -10_000
    lastEvict[i] = -10_000
    lastVisible[i] = -10_000
    lastTracked[i] = -10_000
    lastBigOnly[i] = -10_000
    koSeenTick[i] = -10_000

  # --- the byte-faithful updateTracks ------------------------------------
  proc updTracks(tracks: var seq[Trk], tick: int, seen: seq[Sight],
      evicted: var seq[Trk], capped: var bool, cap = TrackCap) =
    var claimed = newSeq[bool](tracks.len)
    for a in seen:
      var
        best = -1
        bestD = TrackMatchDist
      for i in 0 ..< tracks.len:
        if claimed[i]:
          continue
        let d = hypot(tracks[i].x - a.x, tracks[i].y - a.y)
        if d < bestD:
          bestD = d
          best = i
      if best >= 0:
        tracks[best].x = a.x
        tracks[best].y = a.y
        tracks[best].lastSeen = tick
        if a.hp > 0:
          tracks[best].hp = a.hp
        tracks[best].shield = a.shield
        tracks[best].owner = a.slot
        inc tracks[best].sightings
        claimed[best] = true
      else:
        tracks.add(Trk(x: a.x, y: a.y, lastSeen: tick, sightings: 1,
          hp: a.hp, shield: a.shield, owner: a.slot, born: tick))
        claimed.add(true)
    var kept: seq[Trk]
    for t in tracks:
      if tick - t.lastSeen <= TrackTtl:
        kept.add t
    kept.sort(proc(a, b: Trk): int = cmp(b.lastSeen, a.lastSeen))
    evicted.setLen(0)
    capped = kept.len > cap
    if capped:
      for i in cap ..< kept.len:
        evicted.add kept[i]
      kept.setLen(cap)
    tracks = kept

  var evBuf: seq[Trk]
  var capped = false

  while replay.playing:
    replay.stepReplay(game)
    let tick = game.tickCount
    lastTick = tick

    for s in 0 ..< slotCount:
      seatOf[s] = -1
      palive[s] = false
    for index, player in game.players:
      let s = player.joinOrder
      if s < 0 or s >= slotCount:
        continue
      seatOf[s] = index
      aggs[s].seen = true
      px[s] = float(player.x + CollisionW div 2)
      py[s] = float(player.y + CollisionH div 2)
      palive[s] = player.alive
      pteam[s] = ord(player.team)
      php[s] = player.hp
      pshield[s] = player.hasShield
      plives[s] = player.lives
      if aggs[s].address.len == 0:
        aggs[s].address = player.address
        aggs[s].team = ord(player.team)
      aggs[s].kills = player.kills
      aggs[s].deaths = player.deaths

    var deathsThisTick: seq[(int, int)]     ## (victim, killer)
    var deathPos: seq[(int, float, float)]
    for event in game.events:
      if event.kind == Death and event.source >= 0 and event.source < slotCount:
        deathsThisTick.add((event.source, event.target))
        deathPos.add((event.source, event.x, event.y))
        koDeathTick[event.source] = tick
        deathSpotX[event.source] = event.x
        deathSpotY[event.source] = event.y
    game.events.setLen(0)

    if game.phase != Playing:
      continue
    if playStart < 0:
      playStart = tick

    # --- refresh every live viewer's fog once -----------------------------
    for s in 0 ..< slotCount:
      if seatOf[s] >= 0 and palive[s]:
        discard game.refreshPlayerFov(seatOf[s])

    for s in 0 ..< slotCount:
      if seatOf[s] < 0:
        continue
      let ghost = not palive[s]
      # ── the sighting stream, exactly as the sprite stream would deliver it.
      var seenE: seq[Sight]
      var seenM: seq[Sight]
      var visCount = 0
      for o in 0 ..< slotCount:
        if o == s or seatOf[o] < 0 or not palive[o]:
          continue
        # A ghost viewer watches the whole map unfogged (global.nim 6395);
        # a live viewer sees only inside its own fov.
        let vis = ghost or game.playerVisibleTo(seatOf[s], seatOf[o])
        if not vis:
          continue
        lastVisible[s * slotCount + o] = tick
        let sg = Sight(x: px[o], y: py[o], slot: o, hp: php[o],
                       shield: pshield[o])
        if pteam[o] == pteam[s]:
          seenM.add sg
        else:
          seenE.add sg
          inc visCount

      updTracks(mTracks[s], tick, seenM, evBuf, capped)
      var mateCapped = capped
      discard mateCapped
      updTracks(eTracks[s], tick, seenE, evBuf, capped)
      var bigCapped = false
      var bigEv: seq[Trk]
      updTracks(eBig[s], tick, seenE, bigEv, bigCapped, BigCap)
      var koCapped = false
      var koEv: seq[Trk]
      updTracks(eKo[s], tick, seenE, koEv, koCapped)

      # ── distinct owners / duplicates -----------------------------------
      var ownerSeen = newSeq[bool](slotCount)
      var nDistinct = 0
      for t in eTracks[s]:
        if t.owner >= 0 and not ownerSeen[t.owner]:
          ownerSeen[t.owner] = true
          inc nDistinct
        lastTracked[s * slotCount + t.owner] = tick
      let dupExtra = eTracks[s].len - nDistinct
      # duplicates inside the freshness windows the shooters/tally use
      var o24 = newSeq[bool](slotCount)
      var o20 = newSeq[bool](slotCount)
      var n24 = 0
      var d24 = 0
      var n20 = 0
      var d20 = 0
      var dupOwner = newSeq[int](slotCount)
      for t in eTracks[s]:
        if t.owner >= 0:
          inc dupOwner[t.owner]
        if tick - t.lastSeen <= FreshShotTicks:
          inc n24
          if t.owner >= 0 and not o24[t.owner]:
            o24[t.owner] = true
            inc d24
        if tick - t.lastSeen <= LocalFreshTicks:
          inc n20
          if t.owner >= 0 and not o20[t.owner]:
            o20[t.owner] = true
            inc d20
      for o in 0 ..< slotCount:
        if dupOwner[o] > 1:
          lastDup[s * slotCount + o] = tick

      if ghost:
        inc aggs[s].tGhost
        if plives[s] > 0: inc aggs[s].tGhostResp else: inc aggs[s].tGhostElim
        aggs[s].visHistGhost[idx(visCount)] += 1
        aggs[s].dupExtraG += dupExtra
        if dupExtra > 0: inc aggs[s].dupTicksG
        if capped: inc aggs[s].capTicksG
      else:
        inc aggs[s].tAlive
        aggs[s].visHist[idx(visCount)] += 1
        aggs[s].dupExtra += dupExtra
        if dupExtra > 0: inc aggs[s].dupTicks
        aggs[s].dupF24Extra += (n24 - d24)
        if n24 - d24 > 0: inc aggs[s].dupF24Ticks
        aggs[s].dupF20Extra += (n20 - d20)
        if n20 - d20 > 0: inc aggs[s].dupF20Ticks
        if capped: inc aggs[s].capTicks

      # ── eviction: what the cap threw away ------------------------------
      if capped:
        aggs[s].evTracks += evBuf.len
        for t in evBuf:
          if t.owner < 0 or not palive[t.owner]:
            continue
          if ownerSeen[t.owner]:
            continue                     # the body still holds another track
          inc aggs[s].evLostBodies
          lastEvict[s * slotCount + t.owner] = tick
          if ghost:
            inc aggs[s].evLostGhostWin
          if lastVisible[s * slotCount + t.owner] == tick:
            inc aggs[s].evLostVisible

      # ── visible-but-absent ---------------------------------------------
      var miss = 0
      for o in 0 ..< slotCount:
        if o == s or seatOf[o] < 0 or not palive[o]: continue
        if pteam[o] == pteam[s]: continue
        if lastVisible[s * slotCount + o] != tick: continue
        if not ownerSeen[o]: inc miss
      aggs[s].missVisible += miss
      if miss > 0: inc aggs[s].missVisTicks

      # ── the UNCAPPED counterfactual: which bodies does the cap cost us? --
      var bigSeen = newSeq[bool](slotCount)
      var knownBig = 0
      for t in eBig[s]:
        if t.owner >= 0 and palive[t.owner] and not bigSeen[t.owner]:
          bigSeen[t.owner] = true
          inc knownBig
      var knownSmall = 0
      for o in 0 ..< slotCount:
        if ownerSeen[o] and palive[o]: inc knownSmall
      var bigOnly = 0
      for o in 0 ..< slotCount:
        if bigSeen[o] and not ownerSeen[o]:
          inc bigOnly
          lastBigOnly[s * slotCount + o] = tick
      inc aggs[s].knownN
      aggs[s].knownSmallSum += knownSmall
      aggs[s].knownBigSum += knownBig
      aggs[s].bigOnlySum += bigOnly
      if bigOnly > 0: inc aggs[s].bigOnlyTicks
      if not ghost:
        inc aggs[s].aKnownN
        aggs[s].aKnownSmall += knownSmall
        aggs[s].aKnownBig += knownBig
        aggs[s].aBigOnly += bigOnly
        if bigOnly > 0: inc aggs[s].aBigOnlyTicks
        var fseen = newSeq[bool](slotCount)
        var nf = 0
        for t in eTracks[s]:
          if tick - t.lastSeen <= FreshShotTicks and t.owner >= 0 and
              palive[t.owner] and not fseen[t.owner]:
            fseen[t.owner] = true
            inc nf
        aggs[s].aKnownFresh += nf
        var tv = 0
        for o in 0 ..< slotCount:
          if o == s or seatOf[o] < 0 or not palive[o]: continue
          if pteam[o] == pteam[s]: continue
          if tick - lastVisible[s * slotCount + o] <= FreshShotTicks: inc tv
        aggs[s].aTruthVisFresh += tv

      # ── respawn census: the table we CARRY INTO play --------------------
      if palive[s] and not wasAlive[s]:
        var aliveEnemies = 0
        for o in 0 ..< slotCount:
          if o != s and seatOf[o] >= 0 and palive[o] and pteam[o] != pteam[s]:
            inc aliveEnemies
        inc aggs[s].respawnN
        aggs[s].respawnKnown += knownSmall
        aggs[s].respawnKnownBig += knownBig
        aggs[s].respawnEnemiesAlive += aliveEnemies

      # ── would a `damage pop <color> KO` have reached this seat? ----------
      # The pop sits at the victim's death spot for KillFxTicks and is
      # fog-checked EVERY frame (global.nim addDamagePops), so the seat learns
      # of the death on the first tick of the pop's life that the spot is
      # visible to it.
      for v in 0 ..< slotCount:
        if v == s or seatOf[v] < 0: continue
        if pteam[v] == pteam[s]: continue
        let dt = koDeathTick[v]
        if dt < 0 or tick - dt > KillFxTicks: continue
        if koSeenTick[s * slotCount + v] >= dt: continue
        let dp = deathSpotX[v]
        if dp < 0: continue
        if ghost or game.fovVisibleAt(seatOf[s], int(deathSpotX[v]), int(deathSpotY[v])):
          koSeenTick[s * slotCount + v] = tick

      # ── ARM C: a `damage pop <color> KO` we can SEE expires the nearest
      # track within one body of the death spot (the v48 rule, on a label a
      # LIVE viewer actually receives).
      for v in 0 ..< slotCount:
        if v == s or seatOf[v] < 0 or pteam[v] == pteam[s]: continue
        if koSeenTick[s * slotCount + v] != tick: continue
        if deathSpotX[v] < 0: continue
        var kbest = -1
        var kbestD = 24.0
        for i in 0 ..< eKo[s].len:
          let d = hypot(eKo[s][i].x - deathSpotX[v], eKo[s][i].y - deathSpotY[v])
          if d < kbestD:
            kbestD = d
            kbest = i
        if kbest >= 0:
          eKo[s][kbest].lastSeen = tick - TrackTtl - 1
          inc aggs[s].cReleased

      if not ghost:
        var cOwner = newSeq[bool](slotCount)
        var cN = 0
        var cLive = 0
        var c24 = 0
        var c24d = 0
        var c20 = 0
        var c20d = 0
        var o24c = newSeq[bool](slotCount)
        var o20c = newSeq[bool](slotCount)
        var cDeadFresh = 0
        for t in eKo[s]:
          if tick - t.lastSeen > TrackTtl: continue
          inc cN
          if t.owner >= 0 and not cOwner[t.owner]:
            cOwner[t.owner] = true
            if palive[t.owner]: inc cLive
          if tick - t.lastSeen <= FreshShotTicks:
            inc c24
            if t.owner >= 0 and not o24c[t.owner]:
              o24c[t.owner] = true
              inc c24d
            if t.owner >= 0 and not palive[t.owner]: inc cDeadFresh
          if tick - t.lastSeen <= LocalFreshTicks:
            inc c20
            if t.owner >= 0 and not o20c[t.owner]:
              o20c[t.owner] = true
              inc c20d
        var cDistinct = 0
        for o in 0 ..< slotCount:
          if cOwner[o]: inc cDistinct
        aggs[s].cDupExtra += cN - cDistinct
        if cN - cDistinct > 0: inc aggs[s].cDupTicks
        if c24 - c24d > 0: inc aggs[s].cDupF24Ticks
        if c20 - c20d > 0: inc aggs[s].cDupF20Ticks
        aggs[s].cDeadFreshTracks += cDeadFresh
        if cDeadFresh > 0: inc aggs[s].cDeadFreshTicks
        aggs[s].cKnownSmall += cLive

      # ── fresh tracks pointing at a DEAD body / positional error ---------
      if not ghost:
        var deadFresh = 0
        for t in eTracks[s]:
          let age = tick - t.lastSeen
          if t.owner < 0: continue
          if not palive[t.owner]:
            let koKnown = koSeenTick[s * slotCount + t.owner] >= koDeathTick[t.owner] and
                          koDeathTick[t.owner] >= 0
            if age <= FreshShotTicks:
              inc deadFresh
              if koKnown: inc aggs[s].deadFreshKoSeen
            if age <= TrackTtl:
              inc aggs[s].deadTtlTracks
              if koKnown: inc aggs[s].deadTtlKoSeen
          elif age <= FreshShotTicks:
            let e = hypot(t.x - px[t.owner], t.y - py[t.owner])
            inc aggs[s].posErrN
            aggs[s].posErrSum += e
            if e > aggs[s].posErrMax: aggs[s].posErrMax = e
            if e > TrackMatchDist: inc aggs[s].posErrOver40
        aggs[s].deadFreshTracks += deadFresh
        if deadFresh > 0: inc aggs[s].deadFreshTicks

      # ── the tally + near, ALIVE ticks only ------------------------------
      if not ghost:
        var eTrk = 0.0
        var fTrk = 1.0
        for t in eTracks[s]:
          if tick - t.lastSeen <= LocalFreshTicks and
              hypot(t.x - px[s], t.y - py[s]) <= RetreatRadius:
            eTrk += (if t.shield: ShieldGunWeight
                     elif t.hp >= 1 and t.hp < PolMaxHp: t.hp.float / PolMaxHp.float
                     else: 1.0)
        for t in mTracks[s]:
          if tick - t.lastSeen <= LocalFreshTicks and
              hypot(t.x - px[s], t.y - py[s]) <= RetreatRadius:
            fTrk += 1.0
        var eTruth = 0.0
        var fTruth = 1.0
        var nearTruth = 1e9
        for o in 0 ..< slotCount:
          if o == s or seatOf[o] < 0 or not palive[o]: continue
          let d = hypot(px[o] - px[s], py[o] - py[s])
          if pteam[o] == pteam[s]:
            if d <= RetreatRadius: fTruth += 1.0
          else:
            if d < nearTruth: nearTruth = d
            if d <= RetreatRadius:
              eTruth += (if pshield[o]: ShieldGunWeight
                         elif php[o] >= 1 and php[o] < PolMaxHp:
                           php[o].float / PolMaxHp.float
                         else: 1.0)
        # FOG-FREE comparator: only bodies this seat could actually have
        # perceived — visible at some tick inside the same freshness window.
        var ePerc = 0.0
        var fPerc = 1.0
        for o in 0 ..< slotCount:
          if o == s or seatOf[o] < 0 or not palive[o]: continue
          if tick - lastVisible[s * slotCount + o] > LocalFreshTicks: continue
          let d = hypot(px[o] - px[s], py[o] - py[s])
          if d > RetreatRadius: continue
          if pteam[o] == pteam[s]: fPerc += 1.0
          else:
            ePerc += (if pshield[o]: ShieldGunWeight
                      elif php[o] >= 1 and php[o] < PolMaxHp:
                        php[o].float / PolMaxHp.float
                      else: 1.0)
        # the same tally off the UNCAPPED table
        var eBigT = 0.0
        for t in eBig[s]:
          if tick - t.lastSeen <= LocalFreshTicks and
              hypot(t.x - px[s], t.y - py[s]) <= RetreatRadius:
            eBigT += (if t.shield: ShieldGunWeight
                      elif t.hp >= 1 and t.hp < PolMaxHp: t.hp.float / PolMaxHp.float
                      else: 1.0)
        var eKoT = 0.0
        for t in eKo[s]:
          if tick - t.lastSeen <= LocalFreshTicks and
              hypot(t.x - px[s], t.y - py[s]) <= RetreatRadius:
            eKoT += (if t.shield: ShieldGunWeight
                     elif t.hp >= 1 and t.hp < PolMaxHp: t.hp.float / PolMaxHp.float
                     else: 1.0)
        var nearTrk = 1e9
        for t in eTracks[s]:
          if tick - t.lastSeen <= FreshShotTicks:
            let d = hypot(t.x - px[s], t.y - py[s])
            if d < nearTrk: nearTrk = d
        inc aggs[s].tallyN
        aggs[s].eTrk += eTrk
        aggs[s].eTruth += eTruth
        aggs[s].fTrk += fTrk
        aggs[s].fTruth += fTruth
        let err = (fTrk - eTrk) - (fTruth - eTruth)
        aggs[s].marginErrSum += err
        aggs[s].marginErrAbs += abs(err)
        aggs[s].marginErrSq += err * err
        if err > 1e-9: inc aggs[s].marginOver        ## table says we are BETTER off
        elif err < -1e-9: inc aggs[s].marginUnder
        else: inc aggs[s].marginExact
        # would the tradeGate DECISION differ? (friendGuns-enemyGuns >= 1.0)
        if ((fTrk - eTrk) >= 1.0) != ((fTruth - eTruth) >= 1.0):
          inc aggs[s].tallyDisagree
        aggs[s].ePerc += ePerc
        aggs[s].fPerc += fPerc
        let pErr = (fTrk - eTrk) - (fPerc - ePerc)
        aggs[s].pMarginErrSum += pErr
        aggs[s].pMarginErrAbs += abs(pErr)
        aggs[s].pMarginErrSq += pErr * pErr
        if pErr > 1e-9: inc aggs[s].pMarginOver
        elif pErr < -1e-9: inc aggs[s].pMarginUnder
        else: inc aggs[s].pMarginExact
        if ((fTrk - eTrk) >= 1.0) != ((fPerc - ePerc) >= 1.0):
          inc aggs[s].pTallyDisagree
        let cErr = (fTrk - eKoT) - (fPerc - ePerc)
        aggs[s].cMarginErrSum += cErr
        aggs[s].cMarginErrAbs += abs(cErr)
        if abs(cErr) < 1e-9: inc aggs[s].cMarginExact
        if ((fTrk - eKoT) >= 1.0) != ((fPerc - ePerc) >= 1.0):
          inc aggs[s].cTallyDisagree
        if ((fTrk - eKoT) >= 1.0) != ((fTrk - eTrk) >= 1.0):
          inc aggs[s].cVsBaseDisagree
        aggs[s].bigMarginErrSum += ((fTrk - eBigT) - (fTrk - eTrk))
        if ((fTrk - eTrk) >= 1.0) != ((fTrk - eBigT) >= 1.0):
          inc aggs[s].bigTallyDisagree
        if nearTruth < 1e8:
          inc aggs[s].nearN
          aggs[s].nearTruthSum += nearTruth
          if nearTrk < 1e8:
            aggs[s].nearTrkSum += nearTrk
            inc aggs[s].nearTrkN
          else: inc aggs[s].nearTrkBlind

    for s in 0 ..< slotCount:
      wasAlive[s] = palive[s]

    # ── realized coverage: was the killer mis-tracked before the death? ---
    for (victim, killer) in deathsThisTick:
      for s in 0 ..< slotCount:
        if s == victim or seatOf[s] < 0: continue
        if pteam[s] == pteam[victim]: continue
        inc aggs[s].koDeaths
        var held = false
        var heldFresh = false
        for t in eTracks[s]:
          if t.owner == victim:
            held = true
            if tick - t.lastSeen <= FreshShotTicks: heldFresh = true
        if held: inc aggs[s].koDeathsTracked
        if heldFresh: inc aggs[s].koDeathsTrackedFresh
      if killer < 0 or killer >= slotCount or victim >= slotCount: continue
      if seatOf[victim] < 0: continue
      inc aggs[victim].deathsScored
      let k = victim * slotCount + killer
      let dup = tick - lastDup[k] <= DeathLookback
      let ev = tick - lastEvict[k] <= DeathLookback
      let bo = tick - lastBigOnly[k] <= DeathLookback
      if dup: inc aggs[victim].deathKillerDup
      if ev: inc aggs[victim].deathKillerEvicted
      if bo: inc aggs[victim].deathKillerBigOnly
      if dup or ev: inc aggs[victim].deathKillerMistracked
      if tick - lastTracked[k] > DeathLookback:
        inc aggs[victim].deathKillerUntracked
      if tick - lastVisible[k] <= 1:
        inc aggs[victim].deathKillerVisible
      if playStart >= 0 and tick <= playStart + 1200:
        inc aggs[victim].earlyDeathsScored
        if dup or ev: inc aggs[victim].earlyMistracked
        if bo: inc aggs[victim].earlyDeathKillerBigOnly

  result = %*{
    "replay": path.extractFilename(),
    "ticks": lastTick,
    "teams": teamCount,
    "slots": slotCount,
    "seats": newJArray()
  }
  for s in 0 ..< slotCount:
    let a = aggs[s]
    if not a.seen: continue
    var vh = newJArray()
    for v in a.visHist: vh.add(%v)
    var vhg = newJArray()
    for v in a.visHistGhost: vhg.add(%v)
    result["seats"].add(%*{
      "seat": a.seat, "addr": a.address, "team": a.team,
      "kills": a.kills, "deaths": a.deaths,
      "t_alive": a.tAlive, "t_ghost": a.tGhost,
      "t_ghost_resp": a.tGhostResp, "t_ghost_elim": a.tGhostElim,
      "vis_hist": vh, "vis_hist_ghost": vhg,
      "dup_extra": a.dupExtra, "dup_ticks": a.dupTicks,
      "dup_extra_ghost": a.dupExtraG, "dup_ticks_ghost": a.dupTicksG,
      "dup_f24_extra": a.dupF24Extra, "dup_f24_ticks": a.dupF24Ticks,
      "dup_f20_extra": a.dupF20Extra, "dup_f20_ticks": a.dupF20Ticks,
      "cap_ticks": a.capTicks, "cap_ticks_ghost": a.capTicksG,
      "ev_tracks": a.evTracks, "ev_lost_bodies": a.evLostBodies,
      "ev_lost_visible": a.evLostVisible, "ev_lost_ghostwin": a.evLostGhostWin,
      "miss_visible": a.missVisible, "miss_vis_ticks": a.missVisTicks,
      "tally_n": a.tallyN,
      "e_trk": a.eTrk, "e_truth": a.eTruth,
      "f_trk": a.fTrk, "f_truth": a.fTruth,
      "margin_err_sum": a.marginErrSum, "margin_err_abs": a.marginErrAbs,
      "margin_err_sq": a.marginErrSq,
      "margin_under": a.marginUnder, "margin_over": a.marginOver,
      "margin_exact": a.marginExact, "tally_disagree": a.tallyDisagree,
      "near_n": a.nearN, "near_trk_sum": a.nearTrkSum,
      "near_truth_sum": a.nearTruthSum, "near_trk_blind": a.nearTrkBlind,
      "near_trk_n": a.nearTrkN,
      "e_perc": a.ePerc, "f_perc": a.fPerc,
      "p_margin_err_sum": a.pMarginErrSum, "p_margin_err_abs": a.pMarginErrAbs,
      "p_margin_err_sq": a.pMarginErrSq,
      "p_margin_under": a.pMarginUnder, "p_margin_over": a.pMarginOver,
      "p_margin_exact": a.pMarginExact, "p_tally_disagree": a.pTallyDisagree,
      "dead_fresh_tracks": a.deadFreshTracks, "dead_fresh_ticks": a.deadFreshTicks,
      "dead_ttl_tracks": a.deadTtlTracks,
      "dead_fresh_ko_seen": a.deadFreshKoSeen, "dead_ttl_ko_seen": a.deadTtlKoSeen,
      "ko_deaths": a.koDeaths, "ko_deaths_tracked": a.koDeathsTracked,
      "ko_deaths_tracked_fresh": a.koDeathsTrackedFresh,
      "c_dup_extra": a.cDupExtra, "c_dup_ticks": a.cDupTicks,
      "c_dup_f24_ticks": a.cDupF24Ticks, "c_dup_f20_ticks": a.cDupF20Ticks,
      "c_dead_fresh_tracks": a.cDeadFreshTracks, "c_dead_fresh_ticks": a.cDeadFreshTicks,
      "c_known_small": a.cKnownSmall, "c_released": a.cReleased,
      "c_margin_err_sum": a.cMarginErrSum, "c_margin_err_abs": a.cMarginErrAbs,
      "c_margin_exact": a.cMarginExact, "c_tally_disagree": a.cTallyDisagree,
      "c_vs_base_disagree": a.cVsBaseDisagree,
      "pos_err_n": a.posErrN, "pos_err_sum": a.posErrSum,
      "pos_err_max": a.posErrMax, "pos_err_over40": a.posErrOver40,
      "a_known_n": a.aKnownN, "a_known_small": a.aKnownSmall,
      "a_known_big": a.aKnownBig, "a_big_only": a.aBigOnly,
      "a_big_only_ticks": a.aBigOnlyTicks,
      "a_known_fresh": a.aKnownFresh, "a_truth_vis_fresh": a.aTruthVisFresh,
      "known_n": a.knownN, "known_small_sum": a.knownSmallSum,
      "known_big_sum": a.knownBigSum, "big_only_sum": a.bigOnlySum,
      "big_only_ticks": a.bigOnlyTicks,
      "big_tally_disagree": a.bigTallyDisagree,
      "big_margin_err_sum": a.bigMarginErrSum,
      "respawn_n": a.respawnN, "respawn_known": a.respawnKnown,
      "respawn_known_big": a.respawnKnownBig,
      "respawn_enemies_alive": a.respawnEnemiesAlive,
      "death_killer_bigonly": a.deathKillerBigOnly,
      "early_death_bigonly": a.earlyDeathKillerBigOnly,
      "deaths_scored": a.deathsScored,
      "death_killer_dup": a.deathKillerDup,
      "death_killer_evicted": a.deathKillerEvicted,
      "death_killer_mistracked": a.deathKillerMistracked,
      "death_killer_untracked": a.deathKillerUntracked,
      "death_killer_visible": a.deathKillerVisible,
      "early_deaths": a.earlyDeathsScored, "early_mistracked": a.earlyMistracked
    })

when isMainModule:
  chdirGameDir()
  var paths: seq[string]
  for i in 1 .. paramCount():
    paths.add paramStr(i)
  if paths.len == 0:
    quit("usage: track_census <replay-path> [...]", 1)
  for p in paths:
    try:
      echo $runOne(p)
    except CatchableError as e:
      echo $(%*{"replay": p.extractFilename(), "error": e.msg})
