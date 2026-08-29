## Sim-state services shared by the roster machinery and the gameplay core:
## lobby status, spawn aim, team paint colors, game-event logging, the
## replay hash (gameHash/mixHash), walkability + spawn placement, the tier-2
## event sink (emitEvent), and flag reset. Stage 5 of
## docs/plans/2026-08-01-sim-split.md; re-exported by sim.nim.

import
  std/[random, strutils],
  bitworld/spriteprotocol, pixie,
  sim_types, arena, sim_config

proc lobbyIsStarting*(sim: SimServer): bool =
  ## Returns whether the lobby is in the start countdown.
  sim.players.len >= sim.config.minPlayers

proc lobbyStartTicksRemaining*(sim: SimServer): int =
  ## Returns ticks left before the lobby starts the game.
  if not sim.lobbyIsStarting() or sim.config.startWaitTicks <= 0:
    return 0
  if sim.startWaitTimer > 0:
    sim.startWaitTimer
  else:
    sim.config.startWaitTicks

proc lobbyStartSecondsRemaining*(sim: SimServer): int =
  ## Returns visible seconds left before the lobby starts the game.
  let ticks = sim.lobbyStartTicksRemaining()
  if ticks <= 0:
    return 0
  max(1, (ticks + TargetFps - 1) div TargetFps)

proc spawnAimBrads*(gameMap: CtfMap, team: Team, groupOffset = 0): int =
  ## Returns the spawn/respawn aim angle: toward the map center, so every
  ## team wakes facing the fight. Sides maps keep the classic east/west pair;
  ## corner teams face the diagonal, plus arms face along their arm.
  ##
  ## BR N-point spawn subsystem: when the map carries authored spawnPoints
  ## (the exact condition spawnPosition already gates its own N-point
  ## placement on), the classic layout table below has nothing useful to say
  ## — a BR board has no "sides" or "corners", just points scattered around
  ## the field — so every team is aimed from the CENTROID of its OWN
  ## assigned spawn-point group toward gameMap.center instead, via
  ## bradsOfVector (the exact inverse of aimVector). Before this fix every
  ## non-Red team fell through to the classic sides-map formula regardless
  ## of layout: a Red-faces-east/everyone-else-faces-west binary, so all 15
  ## non-Red BR duos woke facing due west no matter where on the ring they
  ## actually spawned.
  ##
  ## `groupOffset` is spawnPosition's own per-episode spawnGroupOffset
  ## (default 0, i.e. the raw/unrotated group): pass the SAME offset used to
  ## place this team's players so the computed bearing matches the point
  ## they actually stand on — spawnGroupOffset rotates WHICH physical group
  ## each team lands in every episode (so no team owns a ring cell forever),
  ## and a facing computed from the wrong (unrotated) group would point
  ## toward center from a ring position this team never actually occupies.
  ##
  ## Classic (non-BR) maps never author spawnPoints, so this branch is never
  ## reached for them and the table below stays byte-identical to the
  ## pre-BR formula.
  if gameMap.spawnPoints.len > 0:
    let
      teamCount = gameMap.teamCount()
      perTeam = gameMap.spawnPoints.len div teamCount
      group = (ord(team) + groupOffset) mod teamCount
    var sx, sy = 0
    for i in 0 ..< perTeam:
      let p = gameMap.spawnPoints[group * perTeam + i]
      sx += p.x
      sy += p.y
    let
      cx = sx div perTeam
      cy = sy div perTeam
    return bradsOfVector(gameMap.center.x - cx, gameMap.center.y - cy)
  ## The table keys on layout + OCCUPIED SLOT, and that already serves BOTH
  ## 4-team symmetries: the corner aims are exactly the reflections of Red's
  ## south-east (Blue = its x-mirror SW, Green = its y-mirror NE, Yellow =
  ## its rot180 NW), which is what quad-mirror demands, and they equal the
  ## rot90 quarter turns of it too. Plus aims point along each arm either way.
  ##
  ## Keyed on `homeSlot`, not on team identity: after a GV44 home rotation the
  ## aim has to face the center from the pad the team ACTUALLY woke up on, or
  ## a rotated seat spawns staring into its own back wall.
  let slot = gameMap.homeSlot(team)
  case gameMap.layout
  of layoutSides:
    if slot == Red:
      0                        ## east, toward Blue.
    else:
      AimBradsTurn div 2       ## west, toward Red.
  of layoutCorners:
    ## 0 = east, counter-clockwise: SE 224, SW 160, NE 32, NW 96.
    case slot
    of Red:
      AimBradsTurn - AimBradsTurn div 8      ## top-left faces south-east.
    of Blue:
      AimBradsTurn div 2 + AimBradsTurn div 8  ## top-right faces south-west.
    of Green:
      AimBradsTurn div 8                     ## bottom-left faces north-east.
    of Yellow:
      AimBradsTurn div 2 - AimBradsTurn div 8  ## bottom-right faces north-west.
    else: raiseAssert(
      "spawnAimBrads: layoutCorners is 4-team only, got " & $team &
        " — 16-team BR play never uses layoutCorners (BR_MAPGEN.md §6.2).")
  of layoutPlus:
    case slot
    of Red:
      0                        ## west arm faces east.
    of Blue:
      AimBradsTurn div 2       ## east arm faces west.
    of Green:
      3 * AimBradsTurn div 4   ## north arm faces south.
    of Yellow:
      AimBradsTurn div 4       ## south arm faces north.
    else: raiseAssert(
      "spawnAimBrads: layoutPlus is 4-team only, got " & $team &
        " — 16-team BR play never uses layoutPlus (BR_MAPGEN.md §6.2).")

proc spawnFlipH*(gameMap: CtfMap, team: Team, groupOffset = 0): bool =
  ## Returns whether a team's sprite spawns horizontally flipped: any spawn
  ## aim with a westward component faces the body left. Exactly `team ==
  ## Blue` on sides maps; on a BR (spawnPoints) map, any team whose own-point
  ## bearing to center has a westward component. `groupOffset` forwards to
  ## spawnAimBrads unchanged — see its doc comment.
  let brads = gameMap.spawnAimBrads(team, groupOffset)
  brads > AimBradsTurn div 4 and brads < 3 * AimBradsTurn div 4

proc teamPaintRgba*(color: uint8): ColorRGBA =
  ## Maps a sprite's palette team color to the TRUE team display color — the
  ## vivid hues the soldier art and endzone floors actually show — rather than
  ## the retro palette slot. Use this for any new true-color team art:
  ## `Palette[BlueTeamColor]` is a muted lavender (131,118,156) that matches the
  ## blue a viewer sees nowhere else on the board. A non-team color (an
  ## individual player slot) falls back to its palette entry.
  ##
  ## Loops `Team` (was a 4-way `elif` chain on the named *TeamColor consts,
  ## collapsed per BR_MAPGEN.md §6.2) and reuses the shared
  ## `teamEndzoneColor`, so this stays correct with no edit as `Team` widens.
  for team in Team:
    if color == teamColor(team):
      return teamEndzoneColor(team)
  Palette[color and 0x0f]


proc playerText*(sim: SimServer, playerIndex: int): string =
  ## Returns the readable player color for one player index.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return "unknown"
  playerColorText(sim.players[playerIndex].color)

proc logGameEvent*(sim: SimServer, text: string) =
  ## Writes one game event to stdout for Docker logs.
  if sim.gameEventLoggingEnabled:
    echo text

proc logLobbyWaiting*(sim: var SimServer) =
  ## Logs waiting-for-player state when it changes.
  let
    needed = max(0, sim.config.minPlayers - sim.players.len)
    players = sim.players.len
  if players == sim.lastLobbyPlayersLogged and
      needed == sim.lastLobbyNeededLogged:
    return
  sim.lastLobbyPlayersLogged = players
  sim.lastLobbyNeededLogged = needed
  sim.lastLobbySecondsLogged = -1
  sim.logGameEvent(
    "waiting for players: " & $players & "/" &
      $sim.config.minPlayers & ", need " & $needed & " more"
  )

proc logLobbyCountdown*(sim: var SimServer) =
  ## Logs the lobby countdown once per visible second.
  let seconds = sim.lobbyStartSecondsRemaining()
  if seconds <= 0 or seconds == sim.lastLobbySecondsLogged:
    return
  sim.lastLobbySecondsLogged = seconds
  sim.logGameEvent("game starting in " & $seconds)

proc mapIndex*(x, y: int): int {.inline.} =
  y * MapWidth + x

proc mixHash(hash: var uint64, value: uint64) =
  ## Mixes one integer into a deterministic FNV-1a hash.
  hash = hash xor value
  hash *= 1099511628211'u64

proc mixHashInt(hash: var uint64, value: int) =
  ## Mixes one signed integer into a deterministic hash.
  hash.mixHash(cast[uint64](int64(value)))

proc mixHashBool(hash: var uint64, value: bool) =
  ## Mixes one boolean into a deterministic hash.
  hash.mixHashInt(ord(value))

proc grenadeThrowerSlot*(
  sim: SimServer,
  grenade: AirborneGrenade
): int {.inline.} =
  grenade.throwerSlot

proc policyPageHash*(page: string): uint64 =
  ## The content hash of one flashed one-page policy: FNV-1a 64 over the raw
  ## page bytes, the same mixer gameHash itself is built from.
  ##
  ## One function, three readers, on purpose: the sim stamps it at flash
  ## time, the replay writer puts it in the record, and the replay reader
  ## re-derives it from the recorded page and refuses a record whose two
  ## disagree. A second implementation anywhere would be a second chance for
  ## the live and playback sides to hash the same page differently.
  result = 14695981039346656037'u64
  for c in page:
    result.mixHashInt(ord(c))

proc gameHash*(sim: SimServer): uint64 =
  ## Returns a deterministic hash of gameplay state.
  result = 14695981039346656037'u64
  result.mixHashInt(sim.tickCount)
  result.mixHashInt(ord(sim.phase))
  result.mixHashInt(ord(sim.winner))
  result.mixHashInt(sim.gameOverTimer)
  result.mixHashInt(sim.gameStartTick)
  result.mixHashInt(sim.startWaitTimer)
  result.mixHashBool(sim.timeLimitReached)
  # Mixed only once the barrage latches: a barrage-off game contributes
  # nothing here, while a latched barrage pins its start tick and launch
  # accumulator into every replay hash from that tick on.
  if sim.barrageStartTick >= 0:
    result.mixHashInt(sim.barrageStartTick)
    result.mixHashInt(sim.barrageAccum)
  # Mixed only when the shrink zone is configured: a zone-free game
  # contributes nothing here (the barrageStartTick rule), while a configured
  # one pins its once-drawn center into every replay hash — the rect
  # trajectory and dps damage are themselves pure functions of this center
  # plus already-hashed state (tickCount, gameStartTick, player hp/alive),
  # so nothing else needs mixing in.
  if sim.config.zonePhases.len > 0:
    result.mixHashInt(sim.zoneCenter.x)
    result.mixHashInt(sim.zoneCenter.y)
  result.mixHashBool(sim.isDraw)
  result.mixHashBool(sim.needsReregister)
  result.mixHashInt(sim.nextJoinOrder)
  for team in sim.teams():
    result.mixHashInt(sim.flags[team].x)
    result.mixHashInt(sim.flags[team].y)
    result.mixHashInt(sim.flags[team].carrier)
    result.mixHashBool(sim.flags[team].captured)
  result.mixHashInt(sim.players.len)
  for player in sim.players:
    result.mixHashInt(player.x)
    result.mixHashInt(player.y)
    result.mixHashInt(player.homeX)
    result.mixHashInt(player.homeY)
    result.mixHashInt(player.velX)
    result.mixHashInt(player.velY)
    result.mixHashInt(player.carryX)
    result.mixHashInt(player.carryY)
    result.mixHashBool(player.flipH)
    result.mixHashInt(player.aimBrads)
    result.mixHashInt(ord(player.team))
    result.mixHashBool(player.alive)
    result.mixHashInt(player.lives)
    result.mixHashInt(player.hp)
    result.mixHashInt(player.respawnTimer)
    result.mixHashInt(player.fireCooldown)
    result.mixHashInt(player.fireWindup)
    result.mixHashInt(player.windupBrads)
    result.mixHashBool(player.carryingFlag)
    result.mixHashBool(player.hasGrenade)
    result.mixHashBool(player.hasShield)
    result.mixHashInt(player.shieldHp)
    result.mixHashBool(player.hasSprayPaint)
    result.mixHashInt(player.arcTicksLeft)
    result.mixHashInt(player.arcAimBrads)
    # A 32-seat board can set bit 31 of the arc-hit mask; converting through
    # `int` overflows on wasm32 (same class as the color fix below). Widening
    # to uint64 hashes the identical value on both 32- and 64-bit targets.
    result.mixHash(uint64(player.arcHitMask))
    result.mixHashInt(player.throwCharge)
    result.mixHashInt(player.lastShoutTick)
    result.mixHashInt(player.joinOrder)
    # Color is an unsigned packed RGBA value. Converting it through `int`
    # overflows on wasm32 for colors with the high bit set; widening directly
    # preserves the native replay hash on both 32- and 64-bit targets.
    result.mixHash(uint64(player.color))
    result.mixHashInt(player.reward)
    result.mixHashInt(player.kills)
    result.mixHashInt(player.deaths)
    result.mixHashInt(player.captures)
    # Mixed only when the one-page-policy channel is armed, so a
    # reflash-off replay's hash trajectory is byte-identical to a build that
    # never added these fields — the same rule as the
    # allowCallouts/zonePhases/barrageStartTick guards.
    #
    # WHY a strategy page belongs in a GAMEPLAY hash at all: a reflash is a
    # real, out-of-band input to the episode — the cog plays differently
    # after it. The recorded button masks alone cannot witness it, so a
    # replay that lost the reflash record would re-simulate SILENTLY and
    # attribute the match to a strategy it never ran. Mixing the active
    # page's content hash and flash count turns that silent lie into a hash
    # mismatch at the exact tick the page went missing. The CONTENT itself
    # is not mixed (it is already summarised by policyPageHash, computed
    # once at flash time) — hashing a multi-KB page on every seat every tick
    # would be real CPU for no extra discrimination.
    if sim.config.allowPolicyReflash:
      result.mixHash(player.policyPageHash)
      result.mixHashInt(player.policyPageEpoch)
  for spawn in sim.grenadeSpawns:
    result.mixHashBool(spawn.present)
    result.mixHashInt(spawn.respawnAt)
  for spawn in sim.medKitSpawns:
    result.mixHashBool(spawn.present)
    result.mixHashInt(spawn.respawnAt)
  for spawn in sim.shieldSpawns:
    result.mixHashBool(spawn.present)
    result.mixHashInt(spawn.respawnAt)
  for spawn in sim.sprayPaintSpawns:
    result.mixHashBool(spawn.present)
    result.mixHashInt(spawn.respawnAt)
  result.mixHashInt(sim.airborneGrenades.len)
  for grenade in sim.airborneGrenades:
    result.mixHashInt(grenade.sx)
    result.mixHashInt(grenade.sy)
    result.mixHashInt(grenade.tx)
    result.mixHashInt(grenade.ty)
    result.mixHashInt(grenade.launchTick)
    result.mixHashInt(grenade.flightTicks)
    result.mixHashInt(grenade.thrower)
  result.mixHashInt(sim.recentShouts.len)
  for shout in sim.recentShouts:
    for c in shout.address:
      result.mixHashInt(ord(c))
    result.mixHashInt(ord(shout.team))
    for c in shout.text:
      result.mixHashInt(ord(c))
    result.mixHashInt(shout.tick)
    result.mixHashInt(shout.x)
    result.mixHashInt(shout.y)
    # Mixed only when the mode is on, so an allowCallouts-off replay's hash
    # trajectory is byte-identical to a build that never added these fields
    # — the same rule as the zonePhases/barrageStartTick guards above.
    if sim.config.allowCallouts:
      result.mixHashBool(shout.isCallout)
      result.mixHashInt(shout.calloutId)
      for c in shout.calloutCell:
        result.mixHashInt(ord(c))

proc applyPolicyPage*(
  sim: var SimServer,
  playerIndex: int,
  page: string
): bool {.discardable.} =
  ## Flashes one one-page policy onto one seat, at THIS tick. Returns whether
  ## the page was accepted; the caller records a replay event for exactly the
  ## accepted ones (see server.nim, which mirrors the shout drain).
  ##
  ## The acceptance rule is deliberately as small as it can be — armed gate,
  ## real seat, non-empty page under the record's size ceiling — and depends
  ## on NOTHING that could be in flight: not the phase, not whether the cog
  ## is alive, not a cooldown. Every extra clause here is another way for the
  ## live server and playback to reach different verdicts on the same page
  ## and diverge, and the two flash regimes both need the permissive rule
  ## anyway: BR re-flashes at an ARBITRARY tick (its cogs have one life, so
  ## there is no spawn edge to hang it on) and CTF flashes on a respawn edge,
  ## when the cog is momentarily not alive.
  ##
  ## The size refusal is the load-bearing one. A page over the record's
  ## uint16 length prefix would apply live and then be unwritable to the
  ## replay — an applied-but-unrecorded input, the single outcome
  ## determinism cannot survive. Refusing it BEFORE any state moves keeps
  ## live and playback agreeing that the flash never happened.
  if not sim.config.allowPolicyReflash:
    return false
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  if page.len == 0 or page.len > MaxPolicyPageBytes:
    return false
  sim.players[playerIndex].policyPage = page
  sim.players[playerIndex].policyPageHash = policyPageHash(page)
  sim.players[playerIndex].policyPageTick = sim.tickCount
  # Every accepted flash bumps the epoch, INCLUDING a re-flash of the page
  # already loaded: reasserting the current plan is the most common thing an
  # LLM does, and without the bump that event would leave no trace in the
  # hash and a lost record for it would replay clean.
  inc sim.players[playerIndex].policyPageEpoch
  true

proc isWalkable*(sim: SimServer, x, y: int): bool =
  if x < 0 or y < 0 or x >= MapWidth or y >= MapHeight:
    return false
  sim.walkMask[mapIndex(x, y)]

proc canOccupy*(sim: SimServer, x, y: int): bool =
  ## True when the player's solid footprint, a box of half-extent PlayerHalf
  ## centered on (x, y), fits entirely on walkable floor.
  for dy in -PlayerHalf .. PlayerHalf:
    for dx in -PlayerHalf .. PlayerHalf:
      if not sim.isWalkable(x + dx, y + dy):
        return false
  true

proc nearestWalkable*(sim: SimServer, x, y: int): tuple[x, y: int] =
  ## Returns the nearest walkable cell to a point via expanding ring search.
  if sim.canOccupy(x, y):
    return (x, y)
  for r in 1 .. max(MapWidth, MapHeight):
    for dy in -r .. r:
      for dx in -r .. r:
        if abs(dx) != r and abs(dy) != r:
          continue
        let
          nx = x + dx
          ny = y + dy
        if sim.canOccupy(nx, ny):
          return (nx, ny)
  (x, y)

proc spawnGroupOffset*(sim: SimServer): int =
  ## How far to rotate the team -> spawn-group assignment this episode.
  ##
  ## Derived from the config seed alone (hashed, so consecutive seeds do not
  ## give consecutive offsets, which on a 4x4 grid would walk the assignment
  ## one cell at a time and keep neighbours as neighbours). Pure function of
  ## the seed: a replay of one seed seats exactly as the recording did.
  let teamCount = sim.gameMap.teamCount()
  if teamCount <= 1:
    return 0
  var h = uint32(sim.config.seed) * 2654435761'u32
  h = (h xor (h shr 15)) * 2246822519'u32
  h = h xor (h shr 13)
  int(h mod uint32(teamCount))

proc spawnPosition*(sim: SimServer, team: Team, order: int): tuple[x, y: int] =
  ## Returns a deterministic spawn position just inside a team's home edge:
  ## players stagger along the edge, perpendicular to their home axis (down
  ## the side for east/west teams, across for the plus layout's north/south
  ## arms).
  ##
  ## BR N-point spawn subsystem: when gameMap.spawnPoints is authored, it
  ## OVERRIDES this staggered placement entirely — seat (team, order) spawns
  ## at the team's order-th point, wrapping with `mod` if more seats join
  ## than points were authored for that team (extra seats simply re-share
  ## points, in order). teamAnchor/flagHome stay exactly as they are either
  ## way — spawnPoints never moves the flag pedestal, only where players
  ## stand.
  if sim.gameMap.spawnPoints.len > 0:
    let
      teamCount = sim.gameMap.teamCount()
      perTeam = sim.gameMap.spawnPoints.len div teamCount
      ## Team k does NOT always get spawn group k. A fixed team->position
      ## binding means one team owns a grid cell for every episode ever
      ## played on the map, so any positional advantage that cell carries
      ## (§3.4's ring-bias, or simply better cover) is handed to the same
      ## team every time, and per-spawn fairness — the measured floor the
      ## whole BR programme rests on (§2.5, §3.1) — can no longer be
      ## separated from per-team skill.
      ##
      ## Rotating by an episode-derived offset breaks the binding without
      ## touching determinism: the offset is a pure function of the seed,
      ## so one seed always replays identically, while consecutive seeds
      ## deal the groups differently.
      offset = sim.spawnGroupOffset()
      group = (ord(team) + offset) mod teamCount
      p = sim.gameMap.spawnPoints[group * perTeam + (order mod perTeam)]
    return sim.nearestWalkable(p.x, p.y)
  let
    anchor = sim.gameMap.teamAnchor(team)
    strip = order div 2          ## stagger players down the edge.
    spread = 36
    stepMajor = (strip - 1) * spread
    stepMinor = (if order mod 2 == 0: -6 else: 6)
    ## Which arm the team OCCUPIES this episode, not which one its colour
    ## implies: the GV44 home rotation moves a team between the plus layout's
    ## W/E and N/S arms, and a strip that kept its old axis would stagger
    ## players straight across the arm mouth into the wall.
    slot = sim.gameMap.homeSlot(team)
    vertical = sim.gameMap.layout != layoutPlus or slot in {Red, Blue}
    targetX = if vertical: anchor.x + stepMinor else: anchor.x + stepMajor
    targetY = if vertical: anchor.y + stepMajor else: anchor.y + stepMinor
  sim.nearestWalkable(targetX, targetY)

proc captureZone*(sim: SimServer, team: Team): CaptureZone =
  ## Returns one team's home capture zone on the installed map.
  sim.gameMap.captureZone(team)

proc randomEndzonePosition*(sim: var SimServer, team: Team):
    tuple[x, y: int] =
  ## Returns a random walkable position inside a team's endzone (the home
  ## capture zone), drawn from the deterministic sim RNG.
  let
    zone = sim.captureZone(team)
    inset = ArenaBorder + PlayerHalf
    xLo = max(zone.xLo, inset)
    xHi = min(zone.xHi, MapWidth - 1 - inset)
    yLo = max(zone.yLo, inset)
    yHi = min(zone.yHi, MapHeight - 1 - inset)
  var
    x = xLo + sim.rng.rand(xHi - xLo)
    y = yLo + sim.rng.rand(yHi - yLo)
  if zone.diag or zone.disc:
    ## A diagonal corner zone fills half its bounding box and a round
    ## compact zone about three quarters of it: redraw until the point falls
    ## inside (deterministic — pure rng sequence), with the anchor as a
    ## guaranteed landing spot if the draws run cold.
    var attempts = 0
    while not zone.inCaptureZone(x, y) and attempts < 16:
      x = xLo + sim.rng.rand(xHi - xLo)
      y = yLo + sim.rng.rand(yHi - yLo)
      inc attempts
    if not zone.inCaptureZone(x, y):
      let anchor = sim.gameMap.teamAnchor(team)
      x = anchor.x
      y = anchor.y
  sim.nearestWalkable(x, y)

proc placePlayer*(sim: var SimServer, playerIndex, x, y: int) =
  ## Moves one player to (x, y) with all motion state cleared.
  sim.players[playerIndex].x = x
  sim.players[playerIndex].y = y
  sim.players[playerIndex].velX = 0
  sim.players[playerIndex].velY = 0
  sim.players[playerIndex].carryX = 0
  sim.players[playerIndex].carryY = 0

proc resetPlayerToHome*(sim: var SimServer, playerIndex: int) =
  ## Moves one player back to its team home spawn position.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  sim.placePlayer(playerIndex,
    sim.players[playerIndex].homeX, sim.players[playerIndex].homeY)

proc arrangeHomePositions*(sim: var SimServer) =
  ## Saves and applies team home spawn positions for all players.
  var teamOrder: array[Team, int]
  for i in 0 ..< sim.players.len:
    let team = sim.players[i].team
    let spawn = sim.spawnPosition(team, teamOrder[team])
    inc teamOrder[team]
    sim.players[i].homeX = spawn.x
    sim.players[i].homeY = spawn.y
    sim.resetPlayerToHome(i)

proc eventSlot*(sim: SimServer, playerIndex: int): int {.inline.} =
  ## Returns a player's stable join slot for the tier-2 event stream, so an
  ## event survives roster changes; -1 for no/invalid player.
  if playerIndex >= 0 and playerIndex < sim.players.len:
    return sim.players[playerIndex].joinOrder
  -1

type EventActionKind* = enum
  GunAction
  GrenadeAction
  SprayAction

proc eventActionId*(
  sim: SimServer,
  playerIndex: int,
  kind: EventActionKind,
  tick = -1
): int64 {.inline.} =
  ## Encodes game, tick, action kind, and immutable slot.
  let
    eventTick = if tick >= 0: tick else: sim.tickCount
    slot = max(0, sim.eventSlot(playerIndex))
  var gameOrdinal = 0
  for account in sim.rewardAccounts:
    for team in Team:
      gameOrdinal += account.games[team]
  (int64(gameOrdinal) shl 48) or
    (int64(eventTick) shl 16) or
    (int64(ord(kind) + 1) shl 8) or
    int64(slot and 0xff)

proc eventActionIdForSlot*(
  sim: SimServer,
  slot: int,
  kind: EventActionKind,
  tick: int
): int64 {.inline.} =
  var gameOrdinal = 0
  for account in sim.rewardAccounts:
    for team in Team:
      gameOrdinal += account.games[team]
  (int64(gameOrdinal) shl 48) or
    (int64(tick) shl 16) or
    (int64(ord(kind) + 1) shl 8) or
    int64(max(0, slot) and 0xff)

proc eventDamage*(
  sim: SimServer,
  playerIndex, amount, hp, blocked: int
): EventDamage {.inline.} =
  EventDamage(
    slot: sim.eventSlot(playerIndex),
    amount: amount,
    hp: hp,
    blocked: blocked
  )

proc emitEvent*(
  sim: var SimServer,
  kind: SimEventKind,
  source = -1,
  target = -1,
  weapon = "",
  amount = 0,
  hp = -1,
  blocked = 0,
  x = 0.0,
  y = 0.0,
  actionId = 0'i64,
  headingBrads = -1,
  distance = 0.0,
  item = "",
  content = "",
  damages: seq[EventDamage] = @[],
  sourceSlot = -1,
  targetSlot = -1
) {.inline.} =
  ## Appends one tier-2 analysis event (see SimEvent); a no-op unless
  ## collectEvents is on, so live servers pay nothing. `source` and `target`
  ## are PLAYER INDICES here; they are recorded as stable join slots.
  if not sim.collectEvents:
    return
  sim.events.add SimEvent(
    tick: sim.tickCount,
    kind: kind,
    source: (if sourceSlot >= 0: sourceSlot else: sim.eventSlot(source)),
    target: (if targetSlot >= 0: targetSlot else: sim.eventSlot(target)),
    weapon: weapon,
    amount: amount,
    hp: hp,
    blocked: blocked,
    x: x,
    y: y,
    actionId: actionId,
    headingBrads: headingBrads,
    distance: distance,
    item: item,
    content: content,
    damages: damages
  )

proc emitPhaseChange*(sim: var SimServer, newPhase: GamePhase) {.inline.} =
  ## Appends one PhaseChange analysis event for a phase about to be entered
  ## (call BEFORE assigning sim.phase, with the phase being switched to).
  ## A no-op unless collectEvents is on.
  if not sim.collectEvents:
    return
  sim.emitEvent(
    PhaseChange,
    weapon = ($newPhase).toLowerAscii,
    amount = ord(newPhase)
  )

proc emitPickup*(
  sim: var SimServer,
  playerIndex: int,
  item: string,
  x, y: int
) {.inline.} =
  sim.emitEvent(
    Pickup,
    source = playerIndex,
    x = float(x),
    y = float(y),
    item = item
  )

proc resetFlag*(sim: var SimServer, team: Team) =
  ## Returns one team's flag to its home pedestal.
  # A flag leaving an enemy's back mid-game (death, disconnect — any reason
  # other than capture) is a FlagReturn analysis event; the pedestal resets
  # at game boundaries are not (phase guard).
  if sim.collectEvents and sim.phase == Playing and sim.flags[team].carrier >= 0:
    sim.emitEvent(
      FlagReturn,
      source = sim.flags[team].carrier,
      x = float(sim.flags[team].x),
      y = float(sim.flags[team].y)
    )
  let home = sim.gameMap.flagHome(team)
  sim.flags[team] = FlagState(x: home.x, y: home.y, carrier: -1)

proc resetFlags*(sim: var SimServer) =
  ## Returns every active team's flag to its home pedestal. Inactive slots
  ## hold an explicit no-carrier state so nothing can misread the array's
  ## zero value (carrier 0 would mean "player 0 carries it").
  ##
  ## BR N-point spawn subsystem: a flagless map arms NO flag at all, so an
  ## active team gets the SAME explicit sentinel as an inactive one instead
  ## of a real resetFlag — which would call flagHome/teamAnchor to compute a
  ## pedestal position. Skipping that call is deliberate, not just "don't
  ## bother": on a symNone map with layoutCorners/layoutPlus on a
  ## non-square board, teamAnchor's rot90-orbit math for a non-Red team can
  ## land far outside the board (the defaultCtfRooms crash this subsystem
  ## already had to fix once), so never computing the position kills that
  ## cosmetic hazard at the root instead of computing a garbage point
  ## nothing then draws. carrier=-1 + captured=true is the same "no flag
  ## active" sentinel every downstream reader (updateFlags,
  ## checkWinCondition, flagVisibleTo, flagCarryProgress, killPlayer's
  ## drop-on-death loop, roster's carrier-reindex) already treats as inert —
  ## captured=true additionally short-circuits checkWinCondition's "heart
  ## retired" bookkeeping loop before it would otherwise log a spurious
  ## "heart retired" line for a game that never had one.
  for team in Team:
    if team in sim.teams() and not sim.gameMap.flagless:
      sim.resetFlag(team)
    else:
      sim.flags[team] =
        FlagState(x: 0, y: 0, carrier: -1, captured: sim.gameMap.flagless)

