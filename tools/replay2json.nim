## replay2json — normalize one .replay into a single self-describing JSON doc
## (INFRA task 1216939684284592; generalizes lh_dump.nim / heat_mine.nim).
##
## One hash-validated re-simulation walk produces:
##   meta      - map dims, GameVersion, seed, tick clock (absolute + game ticks)
##   end       - winner / isDraw / timeLimitReached + derived cause
##               (timeout | capture | mutual_wipe | wipe)  [PLAYBOOK scar:
##               classify on gameTicksElapsed vs maxTicks, NEVER absolute tick]
##   players   - roster keyed by stable join SLOT (parity: even=Red, odd=Blue)
##               with final counters (kills/deaths/captures/shots/accuracy)
##   events    - every tier-2 SimEvent (shot/hit/damage/kill/death/flag_steal/
##               flag_return/capture/respawn/heal/phase), source/target are
##               join slots; death: source=victim,target=killer; x,y = where
##   ticks     - sampled every N ticks (default 3): per-player [slot, x, y,
##               alive, hp, lives, carryingFlag] + both flags [x, y, carrier]
##               + phase; `t` absolute tick, `gt` ticks since Playing started
##
## --fov (INFRA task 1216964910440323) appends two fields to every player tick
## entry: [..., seenByEnemy, seenByMask]. seenByEnemy = 1 iff the player is
## inside at least one LIVING enemy's actual field of view THIS tick, computed
## by the sim's own FOV machinery (refreshPlayerFov + playerVisibleTo: episode-
## config cone (live league: 45 deg half-angle, NOT the source const 60) around
## the viewer's aim, omni bubble, walls shadowcast — never a hand-drawn cone).
## seenByMask = bitmask of OTHER living players whose FOV contains this player
## (bit index = viewer join slot, self excluded), so consumers can also
## reconstruct own-team sighting knowledge (e.g. lever-gate replays). Dead
## targets carry 0/0. Cost ~3x re-sim time; fovCaches are derived state, so
## the walk stays hash-clean (mismatchQuit still proves faithfulness).
## Schema stays ctf-replay2json/1 for plain runs; --fov docs say /2 and set
## "fov": true plus visionConeDeg/visionBubble in the meta.
##
## Usage: replay2json <replay-path> [--out <path.json>] [--every N] [--fov]
## Canonical copy: cogamer cogames/ctf/team/bin/replay2json.nim — UNTRACKED in
## coworld-ctf; copy into coworld-ctf/tools/ to compile (GameDir resolution):
##   nim c -d:release --path:/root/.nimby/pkgs tools/replay2json.nim
## Or just run team/bin/replay2json (wrapper: auto-toolchain + cache + URLs).

import
  std/[json, os, strutils],
  ../src/ctf/replays,
  ../src/ctf/sim

const GameDir = currentSourcePath().parentDir().parentDir()

proc key(kind: SimEventKind): string =
  case kind
  of Shot: "shot"
  of Hit: "hit"
  of Damage: "damage"
  of Kill: "kill"
  of Death: "death"
  of FlagSteal: "flag_steal"
  of FlagReturn: "flag_return"
  of Capture: "capture"
  of Respawn: "respawn"
  of Heal: "heal"
  of PhaseChange: "phase"

proc main() =
  let params = commandLineParams()
  var
    replayPath = ""
    outPath = ""
    every = 3
    fov = false
  var i = 0
  while i < params.len:
    case params[i]
    of "--out":
      inc i
      outPath = params[i].absolutePath()
    of "--every":
      inc i
      every = parseInt(params[i])
    of "--fov":
      fov = true
    else:
      replayPath = params[i].absolutePath()
    inc i
  if replayPath.len == 0:
    stderr.writeLine "usage: replay2json <replay> [--out <path.json>] [--every N] [--fov]"
    quit(1)

  let data = loadReplay(replayPath)
  var config = defaultGameConfig()
  config.update(data.configJson)

  setCurrentDir(GameDir)   # map assets resolve relative to repo root
  var
    game = initSimServer(config)
    replay = initReplayPlayer(data)
  game.gameEventLoggingEnabled = false
  game.collectEvents = true
  replay.looping = false
  replay.mismatchQuit = true   # a clean walk also proves the re-sim is faithful

  var
    events = newJArray()
    ticks = newJArray()
    lastCaptureTick = -1

  while replay.playing:
    replay.stepReplay(game)
    let gt =
      if game.gameStartTick > 0: game.tickCount - game.gameStartTick else: -1
    for event in game.events:
      var row = newJObject()
      row["tick"] = %event.tick
      row["gt"] = %(if game.gameStartTick > 0: event.tick - game.gameStartTick else: -1)
      row["kind"] = %event.kind.key()
      row["source"] = %event.source
      row["target"] = %event.target
      row["weapon"] = %event.weapon
      row["amount"] = %event.amount
      row["hp"] = %event.hp
      row["blocked"] = %event.blocked
      row["x"] = %event.x
      row["y"] = %event.y
      events.add(row)
      if event.kind == Capture: lastCaptureTick = event.tick
    game.events.setLen(0)

    if game.tickCount mod every == 0:
      # FOV pass (only on sampled ticks; the cache keys on cell+aim, so this
      # is safe to call any time — fog-cache scar: fovVisibleAt returns TRUE
      # on an invalid cache, so ALWAYS refresh every viewer first).
      var seenMask = newSeq[int](game.players.len)   # bit = viewer joinOrder
      var seenEnemy = newSeq[bool](game.players.len)
      if fov:
        for vi in 0 ..< game.players.len:
          if game.players[vi].joinOrder >= 0 and game.players[vi].alive:
            discard game.refreshPlayerFov(vi)
        for ti in 0 ..< game.players.len:
          let t = game.players[ti]
          if t.joinOrder < 0 or not t.alive: continue
          for vi in 0 ..< game.players.len:
            if vi == ti: continue
            let v = game.players[vi]
            if v.joinOrder < 0 or not v.alive: continue
            if game.playerVisibleTo(vi, ti):
              seenMask[ti] = seenMask[ti] or (1 shl v.joinOrder)
              if v.team != t.team:
                seenEnemy[ti] = true
      var row = newJObject()
      row["t"] = %game.tickCount
      row["gt"] = %gt
      row["phase"] = %($game.phase)
      var ps = newJArray()
      for idx, p in game.players:
        if p.joinOrder < 0: continue
        var e = newJArray()
        e.add(%p.joinOrder)
        e.add(%p.x)
        e.add(%p.y)
        e.add(%(if p.alive: 1 else: 0))
        e.add(%p.hp)
        e.add(%p.lives)
        e.add(%(if p.carryingFlag: 1 else: 0))
        if fov:
          e.add(%(if seenEnemy[idx]: 1 else: 0))
          e.add(%seenMask[idx])
        ps.add(e)
      row["players"] = ps
      var fs = newJObject()
      for team in [Red, Blue]:
        var f = newJArray()
        f.add(%game.flags[team].x)
        f.add(%game.flags[team].y)
        f.add(%game.flags[team].carrier)
        fs[$team] = f
      row["flags"] = fs
      ticks.add(row)

  # End-cause taxonomy (memory lesson maxticks-measured-from-gamestarttick):
  # timeLimitReached -> timeout draw; capture at the final tick -> capture;
  # isDraw without the clock -> mutual wipe; else team wipe.
  let cause =
    if game.timeLimitReached: "timeout"
    elif lastCaptureTick >= 0 and lastCaptureTick >= game.tickCount - 1: "capture"
    elif game.isDraw: "mutual_wipe"
    else: "wipe"

  var doc = newJObject()
  doc["schema"] = %(if fov: "ctf-replay2json/2" else: "ctf-replay2json/1")
  doc["fov"] = %fov
  if fov:
    doc["visionConeDeg"] = %config.visionConeDeg   # EPISODE config, not source const
    doc["visionBubble"] = %config.visionBubble
  doc["replay"] = %replayPath
  doc["gameVersion"] = %GameVersion
  doc["mapWidth"] = %MapWidth
  doc["mapHeight"] = %MapHeight
  doc["seed"] = %config.seed
  doc["maxTicks"] = %config.maxTicks
  doc["sampleEvery"] = %every
  doc["gameStartTick"] = %game.gameStartTick
  doc["finalTick"] = %game.tickCount
  doc["gameTicksElapsed"] = %game.gameTicksElapsed()

  var endObj = newJObject()
  endObj["phase"] = %($game.phase)
  endObj["winner"] = %($game.winner)
  endObj["isDraw"] = %game.isDraw
  endObj["timeLimitReached"] = %game.timeLimitReached
  endObj["cause"] = %cause
  doc["end"] = endObj

  var roster = newJArray()
  for idx, p in game.players:
    var row = newJObject()
    row["slot"] = %p.joinOrder
    row["playerIndex"] = %idx
    row["address"] = %p.address
    row["team"] = %($p.team)
    row["lives"] = %p.lives
    row["kills"] = %p.kills
    row["deaths"] = %p.deaths
    row["captures"] = %p.captures
    row["shotsFired"] = %p.shotsFired
    row["shotsHit"] = %p.shotsHit   # NOTE: includes friendly-fire hits
    roster.add(row)
  doc["players"] = roster
  doc["events"] = events
  doc["ticks"] = ticks

  if outPath.len == 0:
    outPath = replayPath & ".json"
  createDir(outPath.parentDir())   # writeFile into a missing dir would fail
  writeFile(outPath, $doc)
  stderr.writeLine "replay2json ok ticks=" & $game.tickCount &
    " gt=" & $game.gameTicksElapsed() & " events=" & $events.len &
    " cause=" & cause & " -> " & outPath

main()
