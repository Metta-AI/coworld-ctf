## Live player view: the replay viewer's chrome, driven by the STEPPING sim.
##
## The board a human plays on is already `global.buildSpriteProtocolPlayerUpdates`
## — fogged, self-marked, glory pops and all. What it never had is the chrome the
## broadcast/replay layer grew: the scorebug, the glory ledger with its HEAT
## rung, the achievement claims, the feed. That chrome is a JSON frame
## (`broadcast.buildStateJson`) smuggled as the label of a reserved never-drawn
## sprite (`BroadcastChromeSpriteId`), and until now it shipped ONLY on replay
## packets. This module ships the same frame — same schema, same client code,
## same look — off a live sim, plus the one thing a recording never needed: the
## human seat's own private state (`me`).
##
## **Everything here is gated on `PlayerViewerState.hudEnabled`,** set only by a
## client that sent `hud:on`. A policy never sends it, so a bot's observation of
## the player stream is byte-for-byte what it was before this module existed.
## That gate is not a nicety: the player stream IS the RL observation space
## (RULES.md), and a chrome sprite in it would be a free scoreboard oracle.
##
## **What is deliberately NOT here (and where it goes when it lands).** The
## human's true aim never enters `me`. Aim is fuzzed in every player view by
## design (GV24, `global.fuzzedAimBrads`) and a HUD field carrying the real
## angle would defeat that from inside the renderer. The private unfuzzed
## reticle and shooter-side shot feedback are a separate, design-sensitive
## channel; `me` leaves a named seam for them (see `SelfAimSeam` below) and this
## module adds nothing that reads sharper than the pixels already on the board.
## The one directional read it does offer — `inc`, "you are being shot at" — is
## computed from `global.shotImpactPoint`, i.e. the JITTERED ring the human can
## already see, never from the shot's true landing.

import
  std/[json, math],
  bitworld/spriteprotocol,
  broadcast, global, glory, sim

const
  SelfAimSeam* = "aim"
    ## RESERVED key name in the `me` block for the private human-seat reticle
    ## channel. Nothing writes it here. It is named so the channel's owner has
    ## one obvious place to land, and so a future reader can tell "absent
    ## because it is a different lane's work" from "absent by accident".
  IncomingRangePx* = 340
    ## how near an impact ring has to land to be worth an incoming-fire arc.
    ## Wide enough to cover a duel at real engagement range, tight enough that
    ## the far side of the arena does not permanently light the ring.
  IncomingMaxArcs* = 4
    ## most arcs shown at once; beyond this the screen edge is a solid band and
    ## says less than one arrow would.

proc levelProgress(player: Player): (int, int) =
  ## Returns (xp into the current rung, xp the next rung costs). At max level
  ## the second value is 0, which the client renders as a full, capped bar
  ## rather than dividing by zero.
  var floorXp = 0
  for i, threshold in LevelThresholds:
    if player.xp < threshold:
      return (player.xp - floorXp, threshold - floorXp)
    floorXp = threshold
  (0, 0)

proc incomingArcs(sim: SimServer, player: Player): JsonNode =
  ## The bearings of every recent impact ring near this cog, in whole degrees
  ## measured the way the board reads (0 = east, counter-clockwise), plus its
  ## distance. Sourced from `shotImpactPoint`, so an arc can never point more
  ## precisely than the ring the human is already looking at.
  result = newJArray()
  var count = 0
  for shot in sim.recentShots:
    if count >= IncomingMaxArcs:
      break
    let
      (ix, iy) = shotImpactPoint(shot)
      dx = ix - player.x
      dy = iy - player.y
      dist = int(sqrt(float(dx * dx + dy * dy)))
    if dist > IncomingRangePx:
      continue
    # atan2 with the y term negated: map y grows DOWN, bearings grow
    # counter-clockwise, exactly like `aimBrads`.
    var deg = int(round(arctan2(float(-dy), float(dx)) * 180.0 / PI))
    if deg < 0:
      deg += 360
    # `ix`/`iy` are the ring's own map position -- fixed for the life of the
    # shot, unlike the bearing, which changes every tick the player moves. The
    # client keys its once-per-shot dedupe on them.
    result.add(%*{"a": deg, "d": dist, "t": shot.firedTick, "ix": ix, "iy": iy})
    inc count

proc buildSelfJson*(sim: SimServer, playerIndex: int): JsonNode =
  ## The human seat's own private HUD state. Every field is either something
  ## this player already knows first-hand (their own hp, ammo timers, level) or
  ## something already drawn on their own board (their position, the impact
  ## rings around them). Nothing here is a fact about anyone else.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return newJNull()
  let
    player = sim.players[playerIndex]
    (rungXp, rungNeed) = player.levelProgress()
  result = %*{
    "slot": player.joinOrder,
    "team": teamText(player.team),
    "name": scoreboardName(player),
    "alive": player.alive,
    # Board position in MAP pixels. The player stream renders at 1x (boardScale
    # is only ever RenderScale inside the spectator board section), so these are
    # the same units the client's own layer viewport is announced in — the
    # camera can centre on them with no scale conversion.
    "x": player.x,
    "y": player.y,
    "hp": player.hp,
    "mhp": max(1, sim.config.hitPoints),
    "sh": player.shieldHp,
    "lives": player.lives,
    "rs": player.respawnTimer,
    "mrs": max(1, sim.config.respawnTicks),
    # Fire readiness. The board ALREADY shows this as a two-state icon
    # (SpritePlayerFireSpriteId vs its shadow); these are the same two timers
    # unrolled so the meter can show HOW LONG rather than merely "not yet".
    # Windup and cooldown are deliberately separate: they mean opposite things
    # to a player (one is a shot in flight, the other is a shot you cannot take).
    "cd": player.fireCooldown,
    "mcd": max(1, sim.config.fireCooldownTicks),
    "wu": player.fireWindup,
    "mwu": max(1, sim.config.fireWindupTicks),
    "wp": (if player.hasPlasmaArc: "spray" else: "gun"),
    "nade": (if player.hasGrenade: player.grenadeCharges else: 0),
    "shield": player.hasShield,
    "carry": player.carryingFlag,
    "lvl": player.level,
    "xp": player.xp,
    "rung": rungXp,
    "need": rungNeed,
    "k": player.kills,
    "cap": player.captures,
    # Last paint taken, in TICKS AGO (-1 = never this session). A tick delta
    # rather than the raw tick so the client never has to know the sim's clock
    # to time a flash, and so a seek/restart cannot leave a stale timestamp
    # pinning the vignette on.
    "hit": (if player.paintHitTick < 0: -1
            else: sim.tickCount - player.paintHitTick),
    "by": player.lastKilledBy,
    "byAgo": (if player.lastKilledByTick < 0: -1
              else: sim.tickCount - player.lastKilledByTick),
    "inc": sim.incomingArcs(player)
  }

proc buildLivePlayerPacket*(
  sim: var SimServer,
  playerIndex: int,
  state: PlayerViewerState,
  nextState: var PlayerViewerState,
  events: JsonNode
): seq[uint8] =
  ## Builds one live player frame: the board exactly as every seat has always
  ## received it, plus — only for a seat that opted in — the broadcast chrome
  ## frame and this seat's own `me` block.
  result = sim.buildSpriteProtocolPlayerUpdates(playerIndex, state, nextState)
  if nextState.isNil or not nextState.hudEnabled or result.len == 0:
    return
  result.addSprite(
    BroadcastChromeSpriteId,
    1,
    1,
    [0'u8, 0, 0, 0],
    sim.buildStateJson(
      events,
      # Transport arguments, all neutralised. A live match has no scrub bound,
      # no speed and no loop; `transportEnabled = false` is what tells the
      # shared chrome to render its live face instead of a replay's.
      playing = true,
      speed = 1,
      maxTick = -1,
      looping = false,
      transportEnabled = false,
      mismatchTick = -1,
      # POV is the REPLAY viewer's "ride a seat" lens. A player socket already
      # IS that seat, so the lens stays off and the first-person PiP payload is
      # never computed — it would be a per-frame raycast for a view the human
      # is already inside.
      povSlot = -1,
      # Every full-match series (lives lead, glory line, lull spans, precomputed
      # beats) is precomputed by walking a recording to its END. Live, those
      # ticks do not exist yet. The client's ingest guards are all
      # `if (!s.<key>) return;`, so omitting them is a supported state, not a
      # degraded one.
      selfState = sim.buildSelfJson(playerIndex)
    )
  )
