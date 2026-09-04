import
  std/[json, math, os, strutils, tables],
  ../src/ctf/sim,
  toolutil

type Metrics = object
  episodes: int
  aliveTicks: int
  oneHpTicks: int
  shieldTicks: int
  movingTicks: int
  windupTicks: int
  movingWindupTicks: int
  cooldownTicks: int
  movingCooldownTicks: int
  under60MateTicks: int
  under120MateTicks: int
  under240MateTicks: int
  enemyUnder120Ticks: int
  enemyUnder240Ticks: int
  distanceHomeSum: float
  nearestMateSum: float
  nearestMateSamples: int
  deaths: int
  deathNearestMateSum: float
  deathNearestMateSamples: int
  deathsAlone: int
  kills: int
  shots: int
  hits: int
  captures: int
  livesRetained: int
  teamTicks: int
  focusConcentrationSum: float
  distinctObjectiveSum: int
  teamPairDistanceSum: float
  teamPairSamples: int

proc baseName(address: string): string =
  let marker = address.rfind(" (")
  if marker >= 0 and address.endsWith(")"):
    address[0 ..< marker]
  else:
    address

proc distance(a, b: Player): float =
  hypot(float(a.x - b.x), float(a.y - b.y))

proc accumulate(path: string, totals: var Table[string, Metrics]) =
  let previousDir = getCurrentDir()
  chdirGameDir()
  try:
    var (sim, replay) = openReplay(path)
    var
      seenTeams: Table[string, bool]
      lastDeaths: seq[int]
      lastX: seq[int]
      lastY: seq[int]
      lastPlaying = false
      eligible = false
    while replay.playing:
      replay.stepReplay(sim)
      while lastDeaths.len < sim.players.len:
        lastDeaths.add(0)
        lastX.add(sim.players[lastDeaths.high].x)
        lastY.add(sim.players[lastDeaths.high].y)
      let playing = sim.phase == Playing
      if playing and not lastPlaying:
        var names: Table[string, bool]
        for p in sim.players:
          names[p.address.baseName()] = true
        eligible = names.hasKey("James Botts") and names.hasKey("daveey") and
          names.hasKey("Ron @ SWGY") and names.hasKey("richard")
      if not eligible:
        lastPlaying = playing
        continue
      for i, p in sim.players:
        let name = p.address.baseName()
        if playing and not seenTeams.hasKey(name):
          seenTeams[name] = true
          totals.mgetOrPut(name, Metrics()).episodes.inc
        if p.deaths > lastDeaths[i]:
          var best = 1e18
          for j, mate in sim.players:
            if j != i and mate.team == p.team and mate.alive:
              best = min(best, p.distance(mate))
          var m = totals.mgetOrPut(name, Metrics())
          m.deaths.inc(p.deaths - lastDeaths[i])
          if best < 1e17:
            m.deathNearestMateSum += best
            m.deathNearestMateSamples.inc
          else:
            m.deathsAlone.inc
          totals[name] = m
        lastDeaths[i] = p.deaths
        if not playing or not p.alive:
          lastX[i] = p.x
          lastY[i] = p.y
          continue
        var m = totals.mgetOrPut(name, Metrics())
        m.aliveTicks.inc
        if p.hp == 1: m.oneHpTicks.inc
        if p.hasShield: m.shieldTicks.inc
        let moving = p.x != lastX[i] or p.y != lastY[i]
        if moving: m.movingTicks.inc
        if p.fireWindup > 0:
          m.windupTicks.inc
          if moving: m.movingWindupTicks.inc
        if p.fireCooldown > 0 and p.fireWindup == 0:
          m.cooldownTicks.inc
          if moving: m.movingCooldownTicks.inc
        m.distanceHomeSum += hypot(float(p.x - p.homeX), float(p.y - p.homeY))
        var
          mateBest = 1e18
          enemyBest = 1e18
        for j, other in sim.players:
          if i == j or not other.alive: continue
          if other.team == p.team:
            mateBest = min(mateBest, p.distance(other))
          else:
            enemyBest = min(enemyBest, p.distance(other))
        if mateBest < 1e17:
          m.nearestMateSum += mateBest
          m.nearestMateSamples.inc
          if mateBest < 60: m.under60MateTicks.inc
          if mateBest < 120: m.under120MateTicks.inc
          if mateBest < 240: m.under240MateTicks.inc
        if enemyBest < 120: m.enemyUnder120Ticks.inc
        if enemyBest < 240: m.enemyUnder240Ticks.inc
        totals[name] = m
        lastX[i] = p.x
        lastY[i] = p.y
      if playing:
        var handled: Table[string, bool]
        for p in sim.players:
          let name = p.address.baseName()
          if handled.hasKey(name): continue
          handled[name] = true
          var members: seq[int]
          for i, other in sim.players:
            if other.alive and other.address.baseName() == name:
              members.add(i)
          if members.len == 0: continue
          var counts: array[Team, int]
          for i in members:
            let actor = sim.players[i]
            var
              bestTeam = actor.team
              best = 1e18
            for team in Team:
              if team == actor.team: continue
              var anchorFound = false
              var hx, hy: int
              for other in sim.players:
                if other.team == team:
                  hx = other.homeX
                  hy = other.homeY
                  anchorFound = true
                  break
              if anchorFound:
                let d = hypot(float(actor.x - hx), float(actor.y - hy))
                if d < best:
                  best = d
                  bestTeam = team
            counts[bestTeam].inc
          var
            maxCount = 0
            distinctCount = 0
          for count in counts:
            if count > 0: distinctCount.inc
            maxCount = max(maxCount, count)
          var m = totals.mgetOrPut(name, Metrics())
          m.teamTicks.inc
          m.focusConcentrationSum += float(maxCount) / float(members.len)
          m.distinctObjectiveSum += distinctCount
          for a in 0 ..< members.len:
            for b in a + 1 ..< members.len:
              m.teamPairDistanceSum += sim.players[members[a]].distance(
                sim.players[members[b]])
              m.teamPairSamples.inc
          totals[name] = m
      if lastPlaying and not playing:
        for p in sim.players:
          let name = p.address.baseName()
          var m = totals.mgetOrPut(name, Metrics())
          m.kills += p.kills
          m.shots += p.shotsFired
          m.hits += p.shotsHit
          m.captures += p.captures
          m.livesRetained += p.lives
          totals[name] = m
      lastPlaying = playing
  finally:
    setCurrentDir(previousDir)

proc ratio(n, d: int): float =
  if d == 0: 0.0 else: float(n) / float(d)

var totals: Table[string, Metrics]
for path in commandLineParams():
  if path != "--":
    accumulate(path.absolutePath(), totals)

var output = newJObject()
for name, m in totals.pairs:
  output[name] = %*{
    "episodes": m.episodes,
    "alive_ticks": m.aliveTicks,
    "one_hp_fraction": ratio(m.oneHpTicks, m.aliveTicks),
    "shield_fraction": ratio(m.shieldTicks, m.aliveTicks),
    "moving_fraction": ratio(m.movingTicks, m.aliveTicks),
    "moving_windup_fraction": ratio(m.movingWindupTicks, m.windupTicks),
    "moving_cooldown_fraction": ratio(m.movingCooldownTicks, m.cooldownTicks),
    "nearest_mate_mean": if m.nearestMateSamples > 0:
      m.nearestMateSum / float(m.nearestMateSamples) else: 0.0,
    "mate_under_60_fraction": ratio(m.under60MateTicks, m.nearestMateSamples),
    "mate_under_120_fraction": ratio(m.under120MateTicks, m.nearestMateSamples),
    "mate_under_240_fraction": ratio(m.under240MateTicks, m.nearestMateSamples),
    "enemy_under_120_fraction": ratio(m.enemyUnder120Ticks, m.aliveTicks),
    "enemy_under_240_fraction": ratio(m.enemyUnder240Ticks, m.aliveTicks),
    "distance_home_mean": if m.aliveTicks > 0:
      m.distanceHomeSum / float(m.aliveTicks) else: 0.0,
    "deaths": m.deaths,
    "death_nearest_mate_mean": if m.deathNearestMateSamples > 0:
      m.deathNearestMateSum / float(m.deathNearestMateSamples) else: 0.0,
    "deaths_alone": m.deathsAlone,
    "kills": m.kills,
    "shots": m.shots,
    "hits": m.hits,
    "captures": m.captures,
    "lives_retained": m.livesRetained,
    "nearest_enemy_home_concentration": (if m.teamTicks > 0:
      m.focusConcentrationSum / float(m.teamTicks) else: 0.0),
    "nearest_enemy_homes_distinct_mean": (if m.teamTicks > 0:
      float(m.distinctObjectiveSum) / float(m.teamTicks) else: 0.0),
    "team_pair_distance_mean": (if m.teamPairSamples > 0:
      m.teamPairDistanceSum / float(m.teamPairSamples) else: 0.0)
  }
echo output.pretty()
