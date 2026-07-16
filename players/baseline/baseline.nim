## Baseline capture-the-flag bot for Coworld CTF (8v8, classic two-flag,
## dense-cover arena, FOG-OF-WAR full-map vision).
##
## Speaks the Bitworld Sprite v1 protocol over a websocket. The observation is
## the FULL map in map coordinates, but entities are fogged: an enemy (and an
## enemy carrying our flag) is only streamed while it sits inside OUR vision —
## a forward cone (half-angle ~45 degrees around our AIM ANGLE, unlimited
## range, walls block) plus a small omnidirectional bubble (~90px). Always
## visible: the static map, BOTH flag pedestals (teammates are fogged too),
## our own flag's state (an empty own pedestal means it is stolen), and
## ourselves via the distinct "self <color> right|left" marker. AIM IS
## DECOUPLED FROM MOVEMENT: a continuous per-player aim angle (0..255 brads,
## 0 = east, counter-clockwise on screen) turns while B (CCW) or Select (CW)
## is held at ~5 brads/tick; the d-pad never touches it. The aim drives the
## gun, the vision cone, and the sprite flip, so pointing it is THE core
## tactical decision. The bot keeps a persistent world model on top of that:
##
## - **Nav grid**: the full walkability mask arrives once at init; we erode it
##   by the player footprint into an 8px cell grid and run a cost field
##   (Dijkstra) to any goal, then follow the path with waypoint lookahead.
## - **Cover model**: walkable cells adjacent to an obstacle are "cover
##   cells". Cells a remembered enemy could shoot into (range + coarse LOS)
##   get a soft path cost, so movement naturally advances cover-to-cover and
##   keeps obstacles between us and known threats.
## - **Flag model** (two flags): pedestals are STATIC known positions and
##   pedestal flags are never fogged. Only OUR team can carry the enemy flag,
##   so the "<enemy color> heart" sprite is always visible and fully describes
##   our attack (pedestal / on me / on a mate). Only the enemy can carry OUR
##   heart: the "<my color> heart" sprite on its pedestal means safe, visible
##   off-pedestal is a live thief fix, and ABSENT means stolen by a fogged
##   carrier somewhere between our pedestal and its home edge.
## - **Memory**: visible players are matched to tracks (position, velocity,
##   last-seen tick) that persist through fog, and the last thief fix guides
##   the hunt after the carrier fogs out.
## - **Roles** (deterministic from the per-team seat, 8 seats): a mid QUAD
##   races lanes to the ENEMY pedestal, two flankers route wide and hit the
##   pocket from behind, one overwatch sniper holds a shielded cover post
##   whose peek cell owns the longest firing line over mid — under fog a lane
##   watcher SEES map-wide down its open lane, so overwatch is also the radar
##   — and one home defender guards the choke before our pedestal. The attack
##   wave is deliberately six strong: with no global flag tracking, a carrier
##   that slips the contest is hard to reacquire, so committed offense turns
##   steals into captures. While our flag is stolen the back line hunts the
##   thief along its predicted route toward ITS home edge; attackers press on
##   — captures are instant wins both ways, so the race stays on.
## - **Turret controller**: the bot dead-reckons its own aim (spawn aim is
##   toward the enemy side; each held rotate button turns it 5 brads/tick)
##   and resyncs it every frame from its own rendered aim-indicator dots.
##   Each tick it outputs the rotate button that traverses toward the desired
##   aim by the shortest arc, and fires only when the bullet corridor
##   (~14px half-width) covers the target at its range.
## - **Scanning**: units holding a position (overwatch posts, the defender's
##   choke, cooldown ducks) sweep the aim back and forth across the watch arc
##   with genuine rotate-button sweeps, raking the vision cone over it while
##   standing perfectly still. On the move, the aim leads the movement
##   direction when no target demands it, so attackers watch down-lane.
## - **Peek-and-shoot**: the default combat mode. With the gun up and a
##   remembered enemy blocked by a wall, PRE-LAY the aim on the firing line
##   while stepping sideways to the nearest cell that opens it — the shot is
##   ready the moment the ray clears; during the 12-tick cooldown, duck
##   behind the nearest cover that breaks the threat's line and hold there.
## - **Fire discipline**: the bullet is a corridor hitscan along the aim, so
##   the fire gate is geometric: shoot when the aim error's perpendicular
##   miss at the target's range is inside the corridor. Skip targets with a
##   remembered teammate near the fire axis (friendly fire is on; the server
##   kills the NEAREST player in the corridor).
##
## Coordinate model: the map object sits at (0, 0), so object positions ARE
## map coordinates; we find ourselves via the self marker. Only a fresh A
## press fires, and the aim angle locks at the pull (the bullet leaves after
## a short windup), so we stop rotating on the tick we pull.

import
  std/[algorithm, heapqueue, math, os, random, strutils],
  bitworld/spriteprotocol,
  whisky,
  baseline/protocols

const
  WebSocketPath = "/player"
  RenderScale = 3             # HD px per map px on the wire; mirrors hd.nim.
                              # Object coordinates and sprite sizes arrive
                              # multiplied by this; sprites stay centered on
                              # the same map points, so dividing the object
                              # center recovers exact legacy map coordinates.
  MapW = 1235
  MapH = 659
  CenterX = MapW div 2
  CenterY = MapH div 2
  PlayerHalf = 6              # solid footprint half-extent, matches the sim
  NavCell = 8                 # nav grid cell size in px
  GridW = (MapW + NavCell - 1) div NavCell
  GridH = (MapH + NavCell - 1) div NavCell
  RepathTicks = 10            # refresh the cost field at least this often
  LookaheadCells = 6          # how far ahead on the path we aim the waypoint

  FireRange = 1250.0          # engage distance (the 1300px gun is map-wide)
  CarrierFireRange = 110.0    # while carrying, only shoot enemies this close
  RushEngageRange = 230.0     # racing for the steal: only fight what blocks it
  EscortEngageRange = 320.0   # escorting a run: only fight near threats
  PocketRushRange = 210.0     # this close to the enemy pedestal, just GRAB
  ThreatRange = 200.0         # react to a visible enemy this close facing us
  DuckRange = 340.0           # duck from remembered threats this close on cooldown
  TempoPressRange = 150.0     # #8: within this range, press a wounded/turned
                              # threat during our reload instead of ducking
  TempoFreshTicks = 12        # #8: only press a threat seen this recently (a
                              # stale fix is not a real half-beat opportunity)
  BoundThreatRange = 720.0    # #6: an observed clear-line threat within this
                              # (but beyond DuckRange) makes an advance across
                              # open ground while reloading a bounding hold
  BoundThreatTtl = 24         # #6: only bound for a threat remembered this recently
  BoundMateRange = 340.0      # #6: a covering mate must be within this support radius
  BoundMateTtl = 30           # #6: the covering mate must be this freshly seen
  BoundMateDepth = 60.0       # #6: the covering mate is not deeper into the enemy
                              # jaws than us by more than this (it covers from behind)
  DominateGuardBand = 300.0   # #7: search the domination post within this x-band
                              # inside our half of the center line (toward home)
  MateSpacing = 40.0          # soft repulsion radius between teammates
  CorridorHalfWidth = 15.0    # friendly-fire corridor half width along the ray
  LeadTicks = 6.0             # aim this many ticks ahead of a moving enemy:
                              # the 5-tick windup releases the bullet late
  TrackMatchDist = 40.0       # a sighting matches a track within this distance
  TrackTtl = 120              # forget a player not seen for ~5s
  TrackCap = 8                # eight real opponents / teammates per side
  FreshShotTicks = 24         # only fire at tracks seen this recently; the
                              # turret needs traverse time, so chases keep
                              # shooting a bit after the target fogs out
  ThiefFixTtl = 40            # a thief position fix guides the chase this long

  AimBrads = 256              # aim angle units per full turn
  AimRate = 5                 # brads/tick a held rotate button turns the aim
                              # (matches the server's aimTurnRate default)
  AimDotRadius = 16.0         # own aim-indicator dots sit within this radius
  AimResyncBrads = 4          # trust dead reckoning inside this error
  MaxHp = 3                   # hitPoints per life (config default); pip labels
                              # read "hp <n>/<MaxHp>"
  HpPipRadius = 22.0          # a player's overhead hp bar sits within this
  HpFocusBonus = 60.0         # px of effective-distance credit per missing
                              # enemy hit point — a tiebreak between
                              # comparably-engageable targets, never a reason
                              # to swing the turret across the map
  FocusFireBonus = 45.0       # px of credit when a visible mate's aim line
                              # already covers the target (finish together)
  TraversePxPerBrad = 1.6     # px of effective distance per brad of turret
                              # swing needed to lay on the target: err/AimRate
                              # ticks of traverse at ~8px of enemy closing
                              # motion per tick = 8/5 px per brad
  MateAimRayLen = 700.0       # trust a mate's aim line out to this range
  MateAimHitSlack = 22.0      # enemy within this perpendicular distance of a
                              # mate's aim ray counts as mate-targeted
  ButtonC = 1'u8 shl 7        # grenade charge/throw (input mask bit 128)
  NadeMaxRange = 240.0        # full-charge throw distance (~fifth of the field)
  NadeMinRange = 60.0         # never lob inside this — the ~40px blast + drift
                              # would clip us
  NadeBlast = 40.0            # blast radius; a pair this close dies together
  NadeFullChargeTicks = 24    # ~1s of holding C reaches max range
  NadePickupDetour = 90.0     # grab a corner pickup within this detour range
  CarrySelfRadius = 26.0      # a carried heart rides CarriedFlagLift (~10 map
                              # px) above its carrier's center, so our own
                              # carry shows as the enemy heart floating just
                              # over our head — never within the old 4px test
  CarriedFlagLift = 10.0      # px a carried heart flies above its carrier's
                              # center (mirrors CarriedFlagLift in src/ctf/global.nim).
  FlagPickupRange = 12.0      # touch radius to steal the enemy heart off its
                              # pedestal (mirrors FlagPickupRange in src/ctf/sim.nim).
  CarrierEstSpeed = 1.0       # px/tick a fogged mate-carrier is assumed to
                              # advance homeward (carrier moves at ~70% speed)
  CombatDeadband = 2          # stop the traverse within this error (brads);
                              # AimRate 5 cannot settle tighter than +-2
  CruiseDeadband = 8          # sloppier deadband for non-combat aim
  FireSlackPx = 11.0          # fire when the aim error's perpendicular miss
                              # at the target's range is inside this (the
                              # corridor half-width is ~14px; keep margin)
  CommitBonus = 400.0         # px of priority credit for the committed target,
                              # so we finish the enemy we are already killing
                              # instead of switching to a marginally closer one
  LockTtl = 48                # hold a target commitment this many ticks past
                              # the last frame we could engage it (~2 shots)
  LockMatchDist = 60.0        # a candidate this close to the lock fix IS it
  AimHoldTtl = 60             # TARGET-LOCK: keep the turret (and the vision
                              # cone, which rides the aim) pinned on a committed
                              # enemy's bearing for this many ticks past the last
                              # sighting. The server turns a fixed 5 brads/tick
                              # (aimTurnRate, uncappable), so LOSING a target into
                              # fog and re-slewing to re-acquire is the single
                              # costliest waste of the scarcest resource; holding
                              # the bearing keeps them lit AND pre-lined.
  HuntSweepTtl = 90           # HUNTING POSTURE: with no engageable target, aim
                              # toward the nearest enemy remembered this recently
                              # instead of blindly down the movement lane.
  AimThreatBonus = 120.0      # px of priority credit for an enemy currently
                              # FACING us (about to shoot) — engage the greatest
                              # threat first.
  DangerCloseBonus = 200.0    # #1: extra facing-credit at point-blank, tapering
                              # linearly to 0 at DangerFalloff — a close aligned
                              # gun kills us THIS second, a far one barely threatens
  DangerFalloff = 620.0       # range (px) at which a facing enemy's added danger
                              # decays to nothing (~half the map-wide gun range)
  DangerWoundedBonus = 90.0   # #1: extra credit for a target that is BOTH facing
                              # us AND wounded — the cheapest, most dangerous kill
  AimOnConeBrads = 32         # aimThreat: gun bearing within this many brads of the
                              # line to us counts as "aimed at us" (~45°, generous
                              # since the enemy is still turning toward us). Beyond
                              # this the gun points elsewhere = a lesser threat.
  AimDeadOnBrads = 8          # aimThreat: gun within this of dead-on = maximal
                              # danger scale (lethal THIS tick); credit tapers
                              # linearly from full at 0 to the on-cone floor here.
  RetreatRadius = 260.0       # local force-balance radius: count the fresh
                              # enemies and friendlies within this of us
  OutnumberMargin = 2         # fall back when fresh local enemies outnumber
                              # local friendlies (incl. self) by >= this
  LocalFreshTicks = 20        # a track counts toward local balance only if
                              # seen this recently
  RetreatHold = 24            # once outnumbered, commit to the withdrawal for
                              # this many ticks (hysteresis; no flip-flopping)
  RegroupRadius = 460.0       # fall back onto a remembered mate within this
                              # range (re-form the wave), else straight home
  RetreatStep = 240.0         # else withdraw this far toward our home side
  ScanArc = 44                # scan sweeps this many brads each side of the
                              # watch heading (cone half-angle is 32 brads)
  ScanDwellRange = 900.0      # #3: a sentry dwells on a fresh threat inside its
                              # arc within this range instead of sweeping past it
  ScanDwellTtl = 40           # #3: dwell only on a threat remembered this recently
  PushOutTicks = 360          # endgame push: no enemy seen for ~15s...
  PushOutMinGame = 2400       # ...this deep into the game breaks the posts
  LatePushTick = 6800         # all-in on the clock: past this tick a draw is
                              # the default outcome, so commit to the capture

  # --- team comms (shouts) & damage awareness ---------------------------------
  # The engine gives each player ONE shout channel: <=ShoutMaxChars (10) chars,
  # at most one per second, heard by teammates within ~247px THROUGH walls and
  # fog. We use it for four messages on one prioritized slot (see decide()):
  #   "oh shit!"  surprise: an enemy appeared in our face after a blind gap
  #   "die"       pre-fire: we are about to shoot with a mate in earshot
  #   "E <cell>.." enemy callout: chess-cell fixes on fresh enemy tracks
  #   "C<cx> <cy>" carrier heartbeat (existing; lowest priority)
  ChessFiles = 26             # A..Z map columns for the callout grid
  ChessRanks = 14             # 1..14 map rows: ~47x47px cells (MapW/26, MapH/14)
  ShoutGapTicks = 26          # min ticks between our own shouts (server caps at
                              # ReplayFps ~1/s; we self-rate a touch slower)
  CalloutFreshTicks = 20      # only call out enemies seen this recently
  CalloutMaxCells = 2         # name at most this many enemy cells per shout
                              # ("E M9 C4" fits the 10-char budget)
  SurpriseRadius = 95.0       # an enemy THIS close that we were not tracking is
                              # "in our face" — the corner-ambush jump scare
  SurpriseGapTicks = 40       # ...and unseen for at least this long before now
                              # (or brand new) — genuinely a surprise, not an
                              # enemy we watched approach
  SurpriseShoutCooldown = 150 # one "oh shit!" per bot per ~6s (flavor, not spam)
  DieEarshot = 200.0          # shout "die" when a friendly is within this of us
                              # as we fire — close enough to hear and help
  DieShoutCooldown = 90       # one "die" per bot per ~3.75s
  VanityShoutChance = 5       # % of eligible frames that actually emit a vanity
                              # ("oh shit!"/"die") shout. Without this the cooldown
                              # is the ONLY throttle, so in a clustered 8v8 a mate
                              # is almost always in earshot and every bot fires
                              # "die" every DieShoutCooldown ticks = a wall of
                              # bubbles on screen. This is a rare-flavor gate: keep
                              # the lines occasional, not constant. Uses a
                              # per-(slot,tick) hash, NOT rand(), so the shared RNG
                              # stream stays untouched and the mask stays neutral.
  ShoutHeardRange = 247.0     # ShoutRange (MapWidth div 5): reaction radius when
                              # WE hear a mate's contact shout
  ContactWatchTicks = 30      # after hearing "oh shit!"/"die"/callout, orient
                              # the vision cone toward the fix for this long
  HpDropOrientTicks = 24      # after taking a hit from an unseen direction,
                              # orient toward the muzzle-ring bearing this long
  ShotSoundRange = 300.0      # only react to "shot sound" muzzle rings within
                              # this of us (a nearby unseen shooter, likely at us)
  # ── Shout-reaction gate (calloutGate, 2026-07-16): a heard callout is
  # INTEL, not an order. Listening (banking the enemy track) is always cheap;
  # REACTING (turning the cone / moving) must clear a distraction bar keyed to
  # the bot's own task priority — SEAL "priority of work / need-to-know". These
  # gate the reaction, they do NOT gate the intel intake.
  CalloutSelfBubble = 130.0   # a callout THIS close to us is a threat to our OWN
                              # survival — even a committed carrier/grabber glances
                              # (OrientOnly), because a dead carrier captures nothing.
  CalloutLaneCone = 40        # brads: half-cone around our travel bearing. A
                              # callout inside it is a threat we are about to walk
                              # INTO, so even a committed bot orients to it.
  CalloutSectorRange = 300.0  # a posted defender (Overwatch/HomeDefender) reacts
                              # to a callout only within this of the thing it guards
                              # (the carrier it covers, or our own flag) — need-to-know.
  CalloutLaneReach = 520.0    # the lane-cone proximity override reaches this far
                              # down our travel bearing — a called threat farther
                              # than this on our path is not yet a walk-into risk.

  CoverShieldDist = 42.0      # an obstacle this close blocks a threat direction
  PeekLineDist = 150.0        # floor for an overwatch peek firing line; post
                              # scoring strongly prefers the longest line
  DuckSearchCells = 3         # duck-cell search radius in nav cells
  PeekSearchCells = 3         # peek-cell search radius in nav cells
  ExposureRange = 380.0       # enemy threat radius used for exposure costing
  ExposureThreats = 3         # cost only the freshest few remembered threats
  ExposureTrackTtl = 60       # only cost threats remembered this recently
  UnderFireTrackTtl = 16      # tracks this fresh can pin us on open ground
  SerpentineNear = 100.0      # serpentine band: closer threats are jink/duck
  SerpentineFar = 400.0       # ... and farther tracks cannot really aim at us
  StepCost = 5'i32            # orthogonal move cost in the nav field
  DiagCost = 7'i32            # ~sqrt(2) * StepCost
  ExposedCost = 14'i32        # extra cost to enter a threat-exposed cell:
                              # under fog the exposure model (enemy sniper
                              # posts + fresh tracks) is the only warning of
                              # watched lanes, so routes respect it hard
  FlankDepth = 260.0          # wide flankers cross this far past mid
  WeaveBand = 280.0           # rushers serpentine within this x-band of mid

  LaneTop = 40.0              # open corridor above the mirrored obstacles
  LaneMid = float(CenterY)
  LaneBottom = 619.0          # open corridor below the mirrored obstacles
  RespawnBandHalf = 84.0      # fresh enemies respawn at pedestal height ±72px
                              # aimed E-W; a carrier at that height runs straight
                              # down the invulnerable respawner's firing line, so
                              # a carrier clears this band vertically before the run.
  PocketClearX = 130.0        # while this close (x) to the robbed pedestal, the
                              # carrier is still in the respawn pocket.

type
  Team = enum
    Red, Blue

  Role = enum
    MidTop, MidBottom, MidGuard, FlankTop, FlankBottom,
    Overwatch, HomeDefender

  ReactLevel = enum           # SHOUT-REACTION GATE: how far a heard callout may
                              # move this bot, keyed on its own task priority.
                              # Every seat in this policy is always OCCUPIED by an
                              # objective (rush / carry / escort / post), so a
                              # report never moves the FEET — the strongest verdict
                              # is a cone glance; the intel is banked regardless.
    None,                     # bank the intel only — never touch the aim
    OrientOnly                # swing the vision cone onto it (turn-and-watch)

  Vec = object                # a map-space point or direction
    x, y: float

  Actor = object              # a player visible this frame
    pos: Vec
    facingRight: bool
    hp: int                   # from the overhead pip bar; 0 = not read
    aimBrads: int             # gun bearing read from the aim-dot line; -1 unknown

  Track = object              # a remembered player
    pos, vel: Vec
    lastSeen: int
    facingRight: bool
    hp: int                   # last observed hit points; 0 = never read
    aimBrads: int             # last observed gun bearing (aim dots); -1 unknown

  CombatTune = object
    ## The fire/engage decision knobs, made per-bot so a forked policy can
    ## sharpen its shooting without touching the shipped baseline. Every field
    ## mirrors a module const; `defaultCombatTune` fills them WITH those consts,
    ## so a bot left on the default decides bit-identically to the old code —
    ## the shipped path is provably unchanged. Only the fields the const used to
    ## drive in the COMBAT decision are here; nav/post/peek geometry still reads
    ## the consts directly, so a hunter's tune never perturbs its navigation.
    fireSlackPx: float        # perp-miss corridor a shot must sit inside
    freshShotTicks: int       # only fire at tracks seen this recently
    leadTicks: float          # aim this many ticks ahead of a moving enemy
    combatDeadband: int       # settle the traverse within this error (brads)
    fireRange: float          # default engage distance
    carrierFireRange: float   # engage cap while carrying the flag
    rushEngageRange: float    # engage cap while racing for the steal
    escortEngageRange: float  # engage cap while escorting a carrier
    pocketRushRange: float    # inside this of the enemy pedestal, just GRAB
    commit: bool              # target commitment: keep firing on the enemy we
                              # already wounded until it dies/fogs, instead of
                              # re-picking the nearest each frame. Off => shipped.
    commitBonus: float        # px of priority credit for the committed target
    forceBalance: bool        # local numbers awareness (FALSIFIED 2026-07-14 as
                              # a win lever; kept behind this flag, OFF).
    outnumberMargin: int      # fall back when localEnemies - localFriends >= this
    unstuckEngaged: bool      # BUG FIX: let the stuck-recovery jink fire even
                              # while a target is selected, so a bot grinding an
                              # obstacle corner as it advances can break free.
    aimLock: bool             # ⭐ TARGET-LOCK: hold the turret on a committed
                              # enemy's bearing whenever we have a fresh track,
                              # and never reset aim to the move lane while locked.
    huntSweep: bool           # HUNTING POSTURE: with no shot, aim at the nearest
                              # remembered enemy instead of down the move lane.
    fireOnRealBody: bool      # gate the trigger on the perp-miss to the target's
                              # REAL last-seen position, not the full lead phantom.
    threatFacingBonus: bool   # danger-score: credit an enemy FACING us so we
                              # engage the greatest threat first.
    shout: bool               # EMIT shouts at all (carrier heartbeat + enemy
                              # callouts + "oh shit!" + "die"). Off => silent.
    shoutCallout: bool        # emit "E <cell>.." chess enemy-position callouts.
    shoutSurprise: bool       # emit "oh shit!" when ambushed at close range.
    shoutDie: bool            # emit "die" pre-fire when a mate is in earshot.
    reactContact: bool        # REACT to a heard mate shout: orient the vision
                              # cone toward the fix (turn-and-watch, not a rush).
    damageAware: bool         # orient toward the shooter when hit from an unseen
                              # direction (own-HP drop + "shot sound" ring).
    carrierFlee: bool         # a carrier keeps MOVING home while engaged (gun
                              # still fires) instead of advancing — FALSIFIED
                              # 2026-07-15 (net -3, conv worse): fleeing turns the
                              # back to the respawner without clearing its cone.
    carrierClearBand: bool    # ⭐ CAPTURE CONVERSION: inside the robbed pocket,
                              # route the carrier DIAGONALLY out of the respawn
                              # firing band (pedestal height ±72px, where fresh
                              # invulnerable respawners spawn aimed E-W) before the
                              # home run — never pick the mid lane that IS the cone.
    carrierSprint: bool       # ⭐⭐ CAPTURE CONVERSION (survive=110t/drop@home=4%
                              # diagnosis): a carrier NEVER enters the combat branch
                              # (engage range 0, like pocketRush). It was burning
                              # ~4.5s pinned in the pocket firing at the INVULNERABLE
                              # spawn-protected respawner (selectFireTarget skips it,
                              # so 100% wasted) while advancing INTO the nest. Drop
                              # combat entirely: pure-navigate home at full speed.
                              # FALSIFIED 2026-07-15 (net -3): the gun buys survival
                              # by suppressing KILLABLE pursuers; a pure runner is
                              # shot in the back and dies FASTER. Kept behind flag.
    carrierScreen: bool       # ⭐⭐⭐ COORDINATION: the escort nearest the robbed
                              # pocket bodies-blocks the respawn cone — sits at the
                              # carrier's EXACT y, one body toward the pocket, so a
                              # westward/eastward respawner shot aimed at the carrier
                              # crosses the escort FIRST (selectFireTarget stops at
                              # the first body; friendly fire ON). The one mechanism
                              # the mirror can't refute away: a screen is physics.
    carrierGrabDetect: bool   # ⭐⭐⭐⭐ WAKEUP DEADLOCK FIX: the self-carry test only
                              # fires when the heart is >16px off its pedestal, but a
                              # carrier standing ON the robbed pedestal keeps the heart
                              # ~7px away (CarriedFlagLift=10) → iCarry stays FALSE →
                              # the bot never routes home and camps the pedestal it
                              # already robbed until timeout (hosted replays: 67-75% of
                              # a game frozen at the enemy pedestal → a DRAW that should
                              # have been a win). Fix via the auto-pickup invariant: a
                              # living player within FlagPickupRange of an un-carried
                              # enemy pedestal heart is INSTANTLY made carrier by the
                              # sim, so if the heart is on me AND I'm inside pickup range
                              # of the pedestal with no mate closer, I MUST be carrying.
    # ── SEAL/CQB v4 levers (2026-07-16). Each defaults false (control), all ON
    # in shippedCombatTune, each with its own harness env knob. Derived from the
    # recovered ctf-combat-strategy doctrine, reinterpreted for WIN-ONLY scoring
    # (serve winning firefights that clear a carrier's path / hold the flag →
    # captures & wipes, NOT raw kill volume).
    dangerScore: bool         # #1 GREATEST-THREAT-FIRST: a richer target danger
                              # score — a facing enemy's engage credit scales UP
                              # with proximity (a close aligned gun kills us THIS
                              # second; a far one barely threatens), and a facing
                              # AND wounded enemy is the top-value engage. Supersedes
                              # the flat threatFacingBonus tiebreak.
    twoSpeedScan: bool        # #3 TWO-SPEED SCAN: a sentry's idle sweep DWELLS on
                              # the bearing of the nearest fresh threat inside its
                              # arc for a few ticks instead of raking straight past
                              # the one bearing that matters (the turret turns at a
                              # fixed rate, so "slow" = pause on the hot bearing).
    boundingOverwatch: bool   # #6 BUDDY BOUNDING OVERWATCH: do not stroll forward
                              # across a threatened open lane while MY gun is on
                              # cooldown and a covering mate is up — duck to cover
                              # for the reload, then bound forward when the gun is
                              # live. Keeps at least one team gun always up.
    pointOfDomination: bool   # #7 POINT OF DOMINATION: score overwatch posts by
                              # clear-LOS coverage of the cells where enemies
                              # ACTUALLY travel (baked from the occupancy heatmap),
                              # and give the home defender a domination post too —
                              # dominate the ground the enemy must cross.
    tempoPress: bool          # #8 TEMPO / AUDACITY: press on the half-beat — when
                              # the near threat is wounded or just fired (mid-
                              # cooldown, can't punish us), DON'T duck; close for
                              # the kill in its dead time.
    fireSuperiority: bool     # #9 PRESS-VS-BREAK ON FIRE SUPERIORITY (the correct
                              # forceBalance): break off only when we are genuinely
                              # fire-INFERIOR (outnumbered AND their guns are real,
                              # not mostly wounded), never on raw head-count — and
                              # PRESS whenever we can win the trade.
    calloutGate: bool         # SHOUT-REACTION GATE (2026-07-16): gate the REACTION
                              # to a heard callout by the bot's own task priority
                              # (SEAL need-to-know) instead of reorienting anyone in
                              # earshot. Requires shout/reactContact ON to have any
                              # callouts to gate. Off => the old indiscriminate react.
    aimThreat: bool           # AIM-DOT THREAT (2026-07-16, task #19): read a visible
                              # enemy's gun bearing from its rendered aim-dot line and
                              # replace the coarse facingRight half-plane test with a
                              # precise gun-on-me cone. Danger credit scales with how
                              # tightly the gun points at us (dead-on = lethal now).
                              # Falls back to facingRight when the dots are unreadable.
                              # Requires dangerScore (it sharpens that block's threat).

  Bot = ref object
    slot: int
    team: Team
    role: Role
    tune: CombatTune          # fire/engage knobs; default == baseline consts
    tick: int                 # sim ticks, advanced by frames received
    navBuilt: bool
    cellWalkable: seq[bool]   # eroded walkability, GridW x GridH
    coverCell: seq[bool]      # walkable cells hugging an obstacle
    exposure: seq[bool]       # cells a remembered enemy could shoot into
    navDist: seq[int32]       # cost field toward navGoal
    navGoal: int              # goal cell of the current field, -1 = stale
    navStamp: int             # tick the field was computed
    postHold, postPeek: Vec   # overwatch cover post and its peek cell
    postReady: bool
    enemyPosts: seq[Vec]      # the mirrored ENEMY sniper peek cells
    chokeHold: Vec            # defender hold point snapped to cover
    dominatePost: Vec         # #7 POINT OF DOMINATION: the defensive cover cell
    dominateReady: bool       # with the widest clear LOS over the enemy approach
    behindLines: bool         # flanker has crossed deep into the enemy half
    enemies: seq[Track]
    mates: seq[Track]
    carrierPos, carrierVel: Vec   # last fix on the thief carrying OUR flag
    carrierSeen: int
    lastEnemySeen: int        # last tick ANY enemy was inside our vision
    gameStart: int            # tick of the last lobby-to-playing transition
    firedLast: bool           # A was set on the previous sent mask
    estAim: int               # dead-reckoned own aim angle in brads
    rotSign: int              # rotation of the last sent mask: +1 B, -1 Select
    wasDead: bool             # respawn resets the aim to the spawn heading
    scanHigh: bool            # scan sweep currently heading to the high end
    lastPos: Vec
    stuckTicks: int
    jinkUntil: int
    jinkBits: uint8
    nadeCharge: int           # ticks the C button has been held; 0 = idle
    mateFixPos: Vec           # last SEEN position of a mate-carried enemy heart
    mateFixTick: int          # tick of that sighting; 0 = never seen this game
    nadeNeed: int             # charge ticks required for the planned throw
    shoutWant: string         # chat packet to send after this frame's input
    lastShoutTick: int        # rate limit: server allows one shout per second
    lockPos: Vec              # committed target's last-known position, matched
    lockUntil: int            # frame-to-frame; commit holds it until this tick
    lockHp: int               # committed target's last-seen hp (0 = unknown)
    aimLockPos: Vec           # TARGET-LOCK: the enemy the turret is pinned on,
    aimLockUntil: int         # held (aim stays on its bearing) until this tick
    retreatUntil: int         # force-balance withdrawal committed until this tick
    ownHp: int                # our own hp last frame (MaxHp = full); 0 = unread
    surpriseShoutTick: int    # last tick we shouted "oh shit!" (own rate limit)
    dieShoutTick: int         # last tick we shouted "die" (own rate limit)
    orientPos: Vec            # a heard-shout / damage bearing to face for a beat
    orientUntil: int          # keep the vision cone on orientPos until this tick
    calloutPos: Vec           # SHOUT-REACTION GATE: nearest callout heard THIS
    calloutTick: int          # frame — STAGED for the task gate (start of decide),
                              # not yet acted on. The gate (once commitment state
                              # is known) decides whether it earns a cone glance,
                              # which reuses orientPos/orientUntil.

proc roleForSeat(seat: int, team: Team): Role =
  ## Deterministic role spread over the 8 per-team seats. Seats 2 and 3 both
  ## spawn at flag height, but the sim's un-mirrored +-6px spawn offset makes
  ## seat 3 the closest spawn to the flag for Red and seat 2 for Blue — the
  ## rusher takes whichever is closest so we win the opening pickup race.
  ## Under fog the attack wave is six strong (a mid quad plus two flankers):
  ## with no global flag tracking a carrier that slips the contest is hard to
  ## reacquire, so committed offense converts steals into captures, and the
  ## back line is one lane sniper plus the home defender.
  when defined(rushAll):
    # Shuffled-seat leagues deal this policy 1-2 agents onto random mixed
    # teams: coordinated-wave roles waste the seat, and a single capture wins
    # the episode outright, so every seat plays the flag-racing rusher.
    MidTop
  else:
    case seat
    of 0: FlankBottom      # wide bottom lane, get behind the contest
    of 1: MidGuard         # third mid, trails offset high and cleans up
    of 2: (if team == Blue: MidTop else: MidBottom)
    of 3: (if team == Red: MidTop else: MidBottom)
    of 4: MidBottom        # fourth mid: the second trailing attacker
    of 5: Overwatch        # cover post flanking the ring: the lane sniper
    of 6: FlankTop         # wide top lane, get behind the contest
    else: HomeDefender     # choke guard before our capture column

proc defaultCombatTune(): CombatTune =
  ## The shipped baseline's combat knobs, verbatim from the module consts.
  ## A Bot constructed without an explicit tune (every shipped seat) gets this,
  ## so its fire/engage decisions are byte-identical to the pre-refactor code.
  CombatTune(
    fireSlackPx: FireSlackPx,
    freshShotTicks: FreshShotTicks,
    leadTicks: LeadTicks,
    combatDeadband: CombatDeadband,
    fireRange: FireRange,
    carrierFireRange: CarrierFireRange,
    rushEngageRange: RushEngageRange,
    escortEngageRange: EscortEngageRange,
    pocketRushRange: PocketRushRange,
    commit: false,            # the pure-baseline control: re-pick nearest each frame.
    commitBonus: CommitBonus,
    forceBalance: false,      # control: always press, no numbers awareness.
    outnumberMargin: OutnumberMargin,
    unstuckEngaged: false,    # control: shipped disables the jink when engaged.
    aimLock: false,           # control: aim resets to the move lane off-target.
    huntSweep: false,         # control: no active acquisition sweep.
    fireOnRealBody: false,    # control: fire gate uses the full lead phantom.
    threatFacingBonus: false, # control: danger score ignores enemy facing.
    shout: false,             # control: never shout.
    shoutCallout: false,      # control: no enemy callouts.
    shoutSurprise: false,     # control: no "oh shit!".
    shoutDie: false,          # control: no "die".
    reactContact: false,      # control: ignore heard shouts.
    damageAware: false,       # control: no orient-to-shooter reaction.
    carrierFlee: false,       # control: carrier advances toward a point-blank enemy.
    carrierClearBand: false,  # control: carrier lane may sit in the respawn cone.
    carrierSprint: false,     # control: carrier fights (engage 110px) instead of running.
    carrierScreen: false,     # control: escort screens remembered threats, not the cone.
    carrierGrabDetect: false, # control: self-carry only when heart >16px off pedestal.
    dangerScore: false,       # control: flat facing tiebreak only (threatFacingBonus).
    twoSpeedScan: false,      # control: sentry sweep rakes past the hot bearing.
    boundingOverwatch: false, # control: advance across open ground even on cooldown.
    pointOfDomination: false, # control: overwatch posts scored by raw line length.
    tempoPress: false,        # control: always duck on cooldown, never press dead time.
    fireSuperiority: false,   # control: no press-vs-break judgement.
    calloutGate: false,       # control: a heard callout reorients anyone in earshot.
    aimThreat: false,         # control: threat uses the coarse facingRight half-plane.
  )

proc shippedCombatTune(): CombatTune =
  ## The tune the DEPLOYED player runs. Identical to the baseline default plus
  ## target commitment + target-lock + the corner-grind unstick fix (the proven
  ## Picasso gunfighter levers). `defaultCombatTune` stays the untouched control
  ## the harness A/Bs against; this is what runBot actually plays.
  result = defaultCombatTune()
  result.commit = true
  result.aimLock = true
  result.unstuckEngaged = true
  # WAKEUP DEADLOCK FIX (2026-07-16): recognize self-carry the instant we grab
  # the heart standing ON the enemy pedestal, so the carrier routes home instead
  # of camping the robbed pedestal until timeout. Seat-rotated self-play A/B
  # (12g/side, paired seed 100) net +7 seat-adjusted, grab->cap up in BOTH
  # seatings (Red 23.8% vs 13.0% baseline, Blue 26.3% vs 5.9%). Asymmetric fix
  # (converts would-be-draws to wins for the fixed side) so the mirror measures
  # it, unlike the six falsified combat levers.
  result.carrierGrabDetect = true
  # ── SEAL/CQB v4 (2026-07-16): the six doctrine levers, now the PROVEN champion
  # base. Corrected seat-rotated A/B (24g/side, seed 100, candidate = this + core
  # vs control = v3 core alone) = +8 SEAT-ADJUSTED, positive on BOTH seatings
  # (Run A Red +6, Run B Blue +10; true seat bias only ±2). Mechanism = the v4
  # side out-GRABS and out-CAPTURES both seatings (fire-superiority press + tempo
  # + danger-score threat pick win firefights near the objective → more wipes +
  # heart-runs). ⚠️ LAB-vs-v3 only, NOT hosted-field-confirmed (Maxwell: skip the
  # mixed-field step). Each is still individually harness-gated (DANGER/TWOSCAN/
  # BOUND/DOMINATE/TEMPO/FIRESUP) so a regression can be bisected; CONTROL_SHIPPED
  # now means v4, so the NEXT lever (shout gate) A/Bs cleanly on top of this.
  result.dangerScore = true
  result.twoSpeedScan = true
  result.boundingOverwatch = true
  result.pointOfDomination = true
  result.tempoPress = true
  result.fireSuperiority = true
  # ── AIM-DOT THREAT (2026-07-16, task #19). Shipped on Maxwell's EXPLICIT
  # go-ahead ("we can swap champion to revert ... but let's upload") BEFORE the
  # lab A/B finished — the seat-rotated A/B is still running; if it goes negative
  # the revert is: DELETE this line, or swap the league champion back to the v4
  # version. NOT yet proven; this is an early upload by request, not a proven
  # champion. Replaces the coarse facingRight half-plane in the dangerScore block
  # with a precise gun-on-me cone read from the enemy's aim-dot line.
  result.aimThreat = true
  # ── VANITY SHOUTS (2026-07-16, Maxwell: "still include the vanity messages
  # like oh shit and die"). EMIT-ONLY character: "oh shit!" on a point-blank
  # ambush, "die" as we open fire near a mate. Provably MASK-NEUTRAL — the emit
  # block runs AFTER the button mask is finalized and only stages bot.shoutWant,
  # so our own movement/aim never changes. Both fire only when our position is
  # ALREADY revealed (enemy at point-blank / our own muzzle flash), so the
  # range-audible bubble leaks nothing new. STRATEGIC comms stays SHELVED:
  # shoutCallout (enemy callouts + the carrier-position heartbeat), reactContact,
  # calloutGate, and damageAware all remain OFF — the mirror A/B showed the
  # react/callout layer only ever costs turret-time (see the shout-gate memento).
  result.shout = true
  result.shoutSurprise = true
  result.shoutDie = true

proc vec(x, y: float): Vec =
  Vec(x: x, y: y)

proc `+`(a, b: Vec): Vec = vec(a.x + b.x, a.y + b.y)
proc `-`(a, b: Vec): Vec = vec(a.x - b.x, a.y - b.y)
proc `*`(a: Vec, s: float): Vec = vec(a.x * s, a.y * s)

proc len(a: Vec): float =
  hypot(a.x, a.y)

proc dist(a, b: Vec): float =
  len(a - b)

proc norm(a: Vec): Vec =
  let l = a.len()
  if l < 1e-6: vec(0, 0) else: a * (1.0 / l)

proc dot(a, b: Vec): float =
  a.x * b.x + a.y * b.y

proc cross(a, b: Vec): float =
  a.x * b.y - a.y * b.x

proc octantBits(d: Vec): uint8 =
  ## D-pad bits for the 8-way direction nearest to `d`. The worst-case aim
  ## error is 22.5 degrees, safely inside the 25-degree firing cone.
  if d.len() < 1e-6:
    return 0
  let octant = (int(round(arctan2(d.y, d.x) / (PI / 4))) + 8) mod 8
  case octant
  of 0: ButtonRight
  of 1: ButtonRight or ButtonDown
  of 2: ButtonDown
  of 3: ButtonDown or ButtonLeft
  of 4: ButtonLeft
  of 5: ButtonLeft or ButtonUp
  of 6: ButtonUp
  else: ButtonUp or ButtonRight

proc bradsOf(d: Vec): int =
  ## The aim angle in brads pointing along `d`: 0 = east (+x), increasing
  ## counter-clockwise on screen (64 = north; map y grows downward).
  if d.len() < 1e-6:
    return 0
  (int(round(arctan2(-d.y, d.x) * float(AimBrads div 2) / PI)) +
    AimBrads) mod AimBrads

proc bradsDir(brads: int): Vec =
  ## The unit vector of one aim angle in brads (the true fire axis).
  let angle = float(brads) * PI / float(AimBrads div 2)
  vec(cos(angle), -sin(angle))

proc bradsErr(desired, current: int): int =
  ## The signed shortest arc from `current` to `desired` in -128..127:
  ## positive means rotate counter-clockwise (hold B).
  (desired - current + AimBrads + AimBrads div 2) mod AimBrads -
    AimBrads div 2

proc spawnAim(team: Team): int =
  ## The spawn/respawn aim angle: toward the enemy side.
  if team == Red: 0 else: AimBrads div 2

proc chessCell(p: Vec): string =
  ## Encodes a map point as a chess-style cell "F9": file A..Z across the
  ## width (~47px each), rank 1..14 down the height. A short, replay-legible
  ## address that pins an enemy to a ~47px neighborhood — plenty to turn a
  ## teammate's turret onto it (its own vision/tracking reacquire from there).
  let
    fw = float(MapW) / float(ChessFiles)
    rh = float(MapH) / float(ChessRanks)
    f = clamp(int(p.x / fw), 0, ChessFiles - 1)
    r = clamp(int(p.y / rh), 0, ChessRanks - 1)
  $chr(ord('A') + f) & $(r + 1)

proc chessDecode(cell: string): Vec =
  ## Inverse of chessCell: the CENTER of the named cell, or (-1,-1) if the
  ## address is malformed (an out-of-range file letter or non-numeric rank).
  if cell.len < 2 or cell[0] notin {'A' .. 'Z'}:
    return vec(-1, -1)
  var rank: int
  try:
    rank = parseInt(cell[1 .. ^1])
  except ValueError:
    return vec(-1, -1)
  let f = ord(cell[0]) - ord('A')
  if f >= ChessFiles or rank < 1 or rank > ChessRanks:
    return vec(-1, -1)
  let
    fw = float(MapW) / float(ChessFiles)
    rh = float(MapH) / float(ChessRanks)
  vec((float(f) + 0.5) * fw, (float(rank - 1) + 0.5) * rh)

proc slotFromUrl(url: string): int =
  ## Reads the `slot` query parameter from the websocket URL.
  let key = "slot="
  let at = url.find(key)
  if at < 0:
    return 0
  var i = at + key.len
  var digits = ""
  while i < url.len and url[i] in {'0' .. '9'}:
    digits.add(url[i])
    inc i
  if digits.len == 0: 0 else: digits.parseInt()

proc mapPos(client: ProtocolClient, o: SpriteObjectInfo): Vec =
  ## Map-space center of a sprite object (the map object sits at the origin,
  ## so the camera offset is zero; keep it for exactness). The wire carries
  ## RenderScale-scaled coordinates with sprites centered on scaled map
  ## points, so the division is exact for every entity the bot reads.
  vec(
    float((o.x + o.width div 2) div RenderScale + client.mapCameraX),
    float((o.y + o.height div 2) div RenderScale + client.mapCameraY)
  )

proc findSelf(
    client: ProtocolClient, color: string): tuple[alive: bool, pos: Vec] =
  ## Our avatar via the distinct self marker, only drawn while we are alive.
  for facingRight in [true, false]:
    let label = "self " & color & (if facingRight: " right" else: " left")
    for o in client.spriteObjectsWithLabel(label):
      return (alive: true, pos: client.mapPos(o))

proc observedAim(client: ProtocolClient, me: Vec, color: string): int =
  ## Our actual aim read back from our own rendered aim-indicator dots: the
  ## farthest "aim dot <color>" object within the indicator radius points
  ## along the aim. Returns -1 when no dot is close enough (teammate dots
  ## share our color but hug their own player). Resolution is ~2 brads —
  ## an absolute fix that caps dead-reckoning drift.
  result = -1
  var bestD = 0.0
  for o in client.spriteObjectsWithLabel("aim dot " & color):
    let
      p = client.mapPos(o)
      d = dist(p, me)
    if d <= AimDotRadius and d > bestD:
      bestD = d
      result = bradsOf(p - me)

proc actorsFor(client: ProtocolClient, color: string): seq[Actor] =
  ## Visible players of one color in map coordinates plus horizontal facing
  ## and hit points. The overhead "hp <n>/<max>" pip bar is fog-culled with
  ## its player, so whenever the player is visible its hp is too: attach the
  ## nearest pip bar within HpPipRadius.
  for facingRight in [true, false]:
    let label = "player " & color & (if facingRight: " right" else: " left")
    for o in client.spriteObjectsWithLabel(label):
      result.add(Actor(pos: client.mapPos(o), facingRight: facingRight,
        aimBrads: -1))
  for hp in 1 .. MaxHp:
    for o in client.spriteObjectsWithLabel("hp " & $hp & "/" & $MaxHp):
      let p = client.mapPos(o)
      var best = -1
      var bestD = HpPipRadius
      for i in 0 ..< result.len:
        let d = dist(result[i].pos, p)
        if d < bestD:
          bestD = d
          best = i
      if best >= 0:
        result[best].hp = hp
  # Aim bearing: each living player renders a short "aim dot <color>" line from
  # its center along its gun angle. Attribute each dot to the nearest actor and
  # keep the FARTHEST attributed dot per actor — its bearing from the actor is
  # the gun direction (same absolute readback observedAim/mateAimBrads use). Two
  # actors closer than 2*AimDotRadius can't be told apart, so leave both at -1.
  var farDot = newSeq[float](result.len)          # 0 = no dot yet
  for o in client.spriteObjectsWithLabel("aim dot " & color):
    let p = client.mapPos(o)
    var best = -1
    var bestD = AimDotRadius
    for i in 0 ..< result.len:
      let d = dist(result[i].pos, p)
      if d < bestD:
        bestD = d
        best = i
    if best >= 0 and bestD > farDot[best]:
      farDot[best] = bestD
      result[best].aimBrads = bradsOf(p - result[best].pos)
  # Ambiguity guard: if two actors sit within 2*AimDotRadius their dot lines
  # overlap and attribution is unreliable — drop both to unknown.
  for i in 0 ..< result.len:
    for j in i + 1 ..< result.len:
      if dist(result[i].pos, result[j].pos) <= 2.0 * AimDotRadius:
        result[i].aimBrads = -1
        result[j].aimBrads = -1

proc selfHp(client: ProtocolClient, me: Vec, color: string): tuple[have: bool, hp: int] =
  ## Our own current hit points, read from the overhead pip bar the engine
  ## always sends the viewer for itself. The bar sits within HpPipRadius of our
  ## avatar; a mate's bar shares the label but hugs its own player, so match the
  ## nearest bar to us. A drop between frames is proof we were just hit.
  result = (have: false, hp: 0)
  var bestD = HpPipRadius
  for hp in 1 .. MaxHp:
    for o in client.spriteObjectsWithLabel("hp " & $hp & "/" & $MaxHp):
      let d = dist(client.mapPos(o), me)
      if d < bestD:
        bestD = d
        result = (have: true, hp: hp)

proc mateAimBrads(client: ProtocolClient, mate, me: Vec, color: string): int =
  ## A visible mate's aim angle read from ITS rendered aim-indicator dots
  ## (the same absolute readback observedAim does for our own turret).
  ## Returns -1 when the mate is too close to us to attribute dots safely.
  if dist(mate, me) <= 2.0 * AimDotRadius:
    return -1
  result = -1
  var bestD = 0.0
  for o in client.spriteObjectsWithLabel("aim dot " & color):
    let
      p = client.mapPos(o)
      d = dist(p, mate)
    if d <= AimDotRadius and d > bestD and dist(p, me) > AimDotRadius:
      bestD = d
      result = bradsOf(p - mate)

proc walkableAt(client: ProtocolClient, x, y: int): bool =
  if x < 0 or y < 0 or x >= client.walkabilityWidth or
      y >= client.walkabilityHeight:
    return false
  client.walkabilityMask[y * client.walkabilityWidth + x]

proc footprintFits(client: ProtocolClient, x, y: int): bool =
  ## True when the player's solid box centered at (x, y) is all walkable,
  ## mirroring canOccupy in the sim.
  for dy in -PlayerHalf .. PlayerHalf:
    for dx in -PlayerHalf .. PlayerHalf:
      if not client.walkableAt(x + dx, y + dy):
        return false
  true

proc cellOf(p: Vec): int =
  let
    cx = clamp(int(p.x) div NavCell, 0, GridW - 1)
    cy = clamp(int(p.y) div NavCell, 0, GridH - 1)
  cy * GridW + cx

proc cellCenter(cell: int): Vec =
  vec(
    float((cell mod GridW) * NavCell + NavCell div 2),
    float((cell div GridW) * NavCell + NavCell div 2)
  )

proc pixelRayClear(client: ProtocolClient, a, b: Vec): bool =
  ## True when no wall pixel blocks the segment; mirrors lineOfSightClear in
  ## the sim (walls are exactly the non-walkable pixels).
  let
    ax = int(a.x)
    ay = int(a.y)
    bx = int(b.x)
    by = int(b.y)
    steps = max(abs(bx - ax), abs(by - ay))
  if steps == 0:
    return true
  for s in 1 .. steps:
    if not client.walkableAt(ax + (bx - ax) * s div steps,
                             ay + (by - ay) * s div steps):
      return false
  true

proc rayClearCoarse(client: ProtocolClient, a, b: Vec, step: float): bool =
  ## Coarsely-sampled walkability raycast for cover scoring and exposure
  ## costing, where an occasional missed thin corner is an acceptable trade.
  let
    d = b - a
    l = d.len()
  if l < 1e-6:
    return true
  let n = max(1, int(l / step))
  for s in 1 .. n:
    let p = a + d * (float(s) / float(n))
    if not client.walkableAt(int(p.x), int(p.y)):
      return false
  true

proc openLineLen(client: ProtocolClient, a, dir: Vec, maxLen, step: float): float =
  ## Length of the wall-free ray from `a` along unit `dir`, capped at maxLen.
  ## Sizes sniper firing lines and arrow-snipe rays under the map-wide gun.
  var l = step
  while l <= maxLen:
    let p = a + dir * l
    if not client.walkableAt(int(p.x), int(p.y)):
      return l - step
    l += step
  maxLen

proc homeSign(team: Team): float =
  ## -1 toward Red's home edge (left), +1 toward Blue's (right).
  if team == Red: -1.0 else: 1.0

proc homeDeepX(team: Team): float =
  ## A point well inside our capture zone (Red x <= ~206, Blue x >= ~1029).
  ## Blue mirrors Red exactly across the x = 617 center line.
  if team == Red: 150.0 else: float(MapW - 1) - 150.0

proc enemy(team: Team): Team =
  ## The opposing team.
  if team == Red: Blue else: Red

proc flagHome(team: Team): Vec =
  ## The STATIC pedestal position of one team's flag: the center of the
  ## team's protected spawn pocket (matches flagHome in src/ctf/sim.nim).
  if team == Red: vec(186, 329) else: vec(1049, 329)

proc chokeSpot(team: Team): Vec =
  ## Defender hold point between the flag and our home edge, mirrored
  ## exactly across the x = 617 center line.
  if team == Red: vec(390, 340) else: vec(float(MapW - 1) - 390.0, 340)

proc nearestOpenCell(bot: Bot, cell: int): int =
  ## The nearest walkable nav cell, searched in expanding rings.
  if bot.cellWalkable[cell]:
    return cell
  let
    cx = cell mod GridW
    cy = cell div GridW
  for r in 1 .. 16:
    for dy in -r .. r:
      for dx in -r .. r:
        if abs(dx) != r and abs(dy) != r:
          continue
        let
          nx = cx + dx
          ny = cy + dy
        if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
          continue
        if bot.cellWalkable[ny * GridW + nx]:
          return ny * GridW + nx
  cell

proc snapToCover(bot: Bot, p: Vec): Vec =
  ## The nearest cover cell within a few cells of a point, else the point.
  let
    c0 = bot.nearestOpenCell(cellOf(p))
    cx = c0 mod GridW
    cy = c0 div GridW
  var bestD = 1e18
  result = p
  for dy in -6 .. 6:
    for dx in -6 .. 6:
      let
        nx = cx + dx
        ny = cy + dy
      if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
        continue
      let nc = ny * GridW + nx
      if not bot.coverCell[nc]:
        continue
      let d = dist(cellCenter(nc), p)
      if d < bestD:
        bestD = d
        result = cellCenter(nc)

proc scanPost(
    bot: Bot, client: ProtocolClient, eSign, wantY: float
): tuple[hold, peek: Vec, ready: bool] =
  ## Finds one overwatch sniper post for the side whose guns point along
  ## `eSign`: a cover cell hugging the center ring, shielded from the front,
  ## with a sideways peek cell that owns the LONGEST clear firing line — the
  ## map-wide gun makes the lane length the post's value.
  var bestScore = 1e18
  for cy in 0 ..< GridH:
    for cx in 0 ..< GridW:
      let c = cy * GridW + cx
      if not bot.coverCell[c]:
        continue
      let
        p = cellCenter(c)
        fwd = eSign * (p.x - float(CenterX))
      if fwd > -40.0 or fwd < -160.0:
        continue                         # this side of the ring, hugging it
      if rayClearCoarse(client, p, p + vec(eSign * CoverShieldDist, 0.0), 4.0):
        continue                         # nothing shields us from the front
      var
        peek: Vec
        peekLine = 0.0
      for dyc in [-2, 2, -1, 1]:
        let ny = cy + dyc
        if ny < 0 or ny >= GridH or not bot.cellWalkable[ny * GridW + cx]:
          continue
        let q = cellCenter(ny * GridW + cx)
        let line = openLineLen(client, q, vec(eSign, 0.0), FireRange, 6.0)
        if line > peekLine:
          peekLine = line
          peek = q
      if peekLine < PeekLineDist:
        continue
      # The firing-line length dominates; the position terms break near-ties
      # toward the wanted flank height and hugging the flag ring.
      let score = abs(p.y - wantY) + abs(fwd + 90.0) * 0.7 - peekLine * 0.7
      if score < bestScore:
        bestScore = score
        result.hold = p
        result.peek = peek
        result.ready = true

proc pickPost(bot: Bot, client: ProtocolClient) =
  ## Chooses our own overwatch post (the overwatch seat only): fire from the
  ## peek, duck back to the hold during cooldown.
  bot.postReady = false
  if bot.role != Overwatch:
    return
  let
    eSign = -homeSign(bot.team)
    wantY = float(CenterY) + 60.0
  let post = bot.scanPost(client, eSign, wantY)
  if post.ready:
    bot.postHold = post.hold
    bot.postPeek = post.peek
    bot.postReady = true

proc findEnemyPosts(bot: Bot, client: ProtocolClient) =
  ## Precomputes the standing virtual threats every carrier run has to
  ## respect, fed into exposure costing and lane choice: the mirrored ENEMY
  ## overwatch post (a stationary, hidden killer) and the ENEMY spawn
  ## pocket — every kill respawns an armed, spawn-protected enemy at the
  ## pedestal aiming our way, so the pocket mouth (and its mid lane) is
  ## permanently watched ground even when no track remembers anyone there.
  bot.enemyPosts.setLen(0)
  let post = bot.scanPost(client, homeSign(bot.team), float(CenterY) + 60.0)
  if post.ready:
    bot.enemyPosts.add(post.peek)
  bot.enemyPosts.add(flagHome(enemy(bot.team)))

const DominateApproach = [   # #7: the ground an intruder MUST cross to reach
                             # our pedestal — waypoints on the three lanes at the
                             # mid line and just inside our half, mirrored per
                             # team via homeSign. These are where the occupancy
                             # heatmap shows enemy travel concentrates (mid
                             # crossings feeding the pedestal pocket).
  (0.0, LaneTop), (0.0, LaneMid), (0.0, LaneBottom),      # the mid crossing
  (170.0, LaneTop), (170.0, LaneMid), (170.0, LaneBottom) # just inside our half
]

proc pickDominatePost(bot: Bot, client: ProtocolClient) =
  ## #7 POINT OF DOMINATION (home defender): rather than sit on a fixed choke
  ## spot, hold the cover cell on our side of the ring that COMMANDS the most of
  ## the ground an intruder has to cross to reach our pedestal — the cell whose
  ## clear firing lines cover the largest count of the enemy-approach waypoints
  ## (the mid-lane crossings the heatmap shows enemies funnel through). Under a
  ## map-wide gun, the seat that sees the most approach lanes kills the thief
  ## before it reaches the pocket. Computed once at nav build; a tiebreak keeps
  ## it near the classic choke so it does not wander off our capture column.
  bot.dominateReady = false
  if bot.role != HomeDefender:
    return
  let
    sign = homeSign(bot.team)
    choke = chokeSpot(bot.team)
    # Anchor the approach waypoints into map space for this team.
    lo = int((float(CenterX) + sign * DominateGuardBand) / float(NavCell))
    hi = int(float(CenterX) / float(NavCell))
    (x0, x1) = (min(lo, hi), max(lo, hi))
  var bestScore = -1e18
  for cy in 0 ..< GridH:
    for cx in x0 .. x1:
      if cx < 0 or cx >= GridW:
        continue
      let c = cy * GridW + cx
      if not bot.coverCell[c]:
        continue
      let p = cellCenter(c)
      # Must sit on OUR side of the ring, not out past the center line.
      if sign * (p.x - float(CenterX)) < 0.0:
        continue
      var covered = 0
      for w in DominateApproach:
        let wp = vec(float(CenterX) + sign * w[0], w[1])
        if dist(p, wp) <= FireRange and client.pixelRayClear(p, wp):
          inc covered
      if covered == 0:
        continue
      # Lanes commanded dominate; break near-ties toward the classic choke so
      # the defender still screens our own capture column.
      let score = float(covered) * 1000.0 - dist(p, choke)
      if score > bestScore:
        bestScore = score
        bot.dominatePost = p
        bot.dominateReady = true

proc buildNavGrid(bot: Bot, client: ProtocolClient) =
  ## Erodes the pixel walkability mask into a footprint-safe nav grid, then
  ## derives the cover model (cover cells, overwatch post, defender choke).
  bot.cellWalkable = newSeq[bool](GridW * GridH)
  for cy in 0 ..< GridH:
    for cx in 0 ..< GridW:
      bot.cellWalkable[cy * GridW + cx] = client.footprintFits(
        cx * NavCell + NavCell div 2, cy * NavCell + NavCell div 2)
  bot.coverCell = newSeq[bool](GridW * GridH)
  for cy in 0 ..< GridH:
    for cx in 0 ..< GridW:
      let c = cy * GridW + cx
      if not bot.cellWalkable[c]:
        continue
      block adjacency:
        for dy in -1 .. 1:
          for dx in -1 .. 1:
            if dx == 0 and dy == 0:
              continue
            let
              nx = cx + dx
              ny = cy + dy
            if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
              continue
            if not bot.cellWalkable[ny * GridW + nx]:
              bot.coverCell[c] = true
              break adjacency
  bot.exposure = newSeq[bool](GridW * GridH)
  bot.navDist = newSeq[int32](GridW * GridH)
  bot.navGoal = -1
  bot.pickPost(client)
  bot.findEnemyPosts(client)
  bot.pickDominatePost(client)
  bot.chokeHold = bot.snapToCover(chokeSpot(bot.team))
  bot.navBuilt = true

const NavNeighbors = [
  (1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)
]

proc rebuildExposure(bot: Bot, client: ProtocolClient) =
  ## Marks nav cells the freshest remembered enemies — plus the mirrored
  ## enemy sniper posts, which are stationary hidden threats all game —
  ## could shoot into (inside gun range with a coarsely-clear line). Used as
  ## a soft path cost.
  for i in 0 ..< bot.exposure.len:
    bot.exposure[i] = false
  var
    threatSpots: seq[Vec] = bot.enemyPosts
    threats = 0
  for t in bot.enemies:                  # already sorted freshest-first
    if threats >= ExposureThreats or bot.tick - t.lastSeen > ExposureTrackTtl:
      break
    inc threats
    threatSpots.add(t.pos)
  for spot in threatSpots:
    let
      x0 = max(0, int(spot.x - ExposureRange) div NavCell)
      x1 = min(GridW - 1, int(spot.x + ExposureRange) div NavCell)
      y0 = max(0, int(spot.y - ExposureRange) div NavCell)
      y1 = min(GridH - 1, int(spot.y + ExposureRange) div NavCell)
    for cy in y0 .. y1:
      for cx in x0 .. x1:
        let c = cy * GridW + cx
        if bot.exposure[c] or not bot.cellWalkable[c]:
          continue
        let p = cellCenter(c)
        if dist(p, spot) <= ExposureRange and
            rayClearCoarse(client, spot, p, 8.0):
          bot.exposure[c] = true

proc computeField(bot: Bot, client: ProtocolClient, goal: int) =
  ## Cost field (Dijkstra) over the nav grid toward one goal cell. Steps cost
  ## StepCost/DiagCost and entering a threat-exposed cell adds ExposedCost, so
  ## paths prefer segments that keep obstacles between us and known enemies.
  ## Diagonal steps require both orthogonal neighbors open (no corner cuts).
  bot.rebuildExposure(client)
  for i in 0 ..< bot.navDist.len:
    bot.navDist[i] = -1
  var heap = initHeapQueue[(int32, int32)]()
  bot.navDist[goal] = 0
  heap.push((0'i32, int32(goal)))
  while heap.len > 0:
    let
      (dcur, cur32) = heap.pop()
      cur = int(cur32)
    if dcur > bot.navDist[cur]:
      continue
    let
      cx = cur mod GridW
      cy = cur div GridW
    for (dx, dy) in NavNeighbors:
      let
        nx = cx + dx
        ny = cy + dy
      if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
        continue
      let nc = ny * GridW + nx
      if not bot.cellWalkable[nc]:
        continue
      if dx != 0 and dy != 0 and
          not (bot.cellWalkable[cy * GridW + nx] and
               bot.cellWalkable[ny * GridW + cx]):
        continue
      var step = (if dx != 0 and dy != 0: DiagCost else: StepCost)
      if bot.exposure[nc]:
        step += ExposedCost
      let nd = bot.navDist[cur] + step
      if bot.navDist[nc] < 0 or nd < bot.navDist[nc]:
        bot.navDist[nc] = nd
        heap.push((nd, int32(nc)))

proc gridRayClear(bot: Bot, a, b: Vec): bool =
  ## True when the eroded nav grid is open along the whole segment.
  let
    d = b - a
    steps = int(d.len() / 4.0) + 1
  for s in 0 .. steps:
    let p = a + d * (float(s) / float(steps))
    if not bot.cellWalkable[cellOf(p)]:
      return false
  true

proc navSteer(bot: Bot, client: ProtocolClient, me, target: Vec): Vec =
  ## Direction along the cost-field path toward `target`, with waypoint
  ## lookahead. Falls back to a beeline before the grid exists or when
  ## unreachable.
  if not bot.navBuilt:
    return target - me
  let goal = bot.nearestOpenCell(cellOf(target))
  if goal != bot.navGoal or bot.tick - bot.navStamp >= RepathTicks:
    bot.computeField(client, goal)
    bot.navGoal = goal
    bot.navStamp = bot.tick
  let start = bot.nearestOpenCell(cellOf(me))
  if bot.navDist[start] < 0:
    return target - me
  if bot.navDist[start] == 0:
    return target - me
  var
    node = start
    waypoint = cellCenter(start)
    haveClear = false
  for _ in 0 ..< LookaheadCells:
    var next = -1
    var bestD = bot.navDist[node]
    let
      cx = node mod GridW
      cy = node div GridW
    for (dx, dy) in NavNeighbors:
      let
        nx = cx + dx
        ny = cy + dy
      if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
        continue
      let nc = ny * GridW + nx
      if bot.navDist[nc] < 0 or bot.navDist[nc] >= bestD:
        continue
      if dx != 0 and dy != 0 and
          not (bot.cellWalkable[cy * GridW + nx] and
               bot.cellWalkable[ny * GridW + cx]):
        continue
      bestD = bot.navDist[nc]
      next = nc
    if next < 0:
      break
    node = next
    if bot.gridRayClear(me, cellCenter(node)):
      waypoint = cellCenter(node)
      haveClear = true
    else:
      break
  if not haveClear:
    waypoint = cellCenter(node)
  waypoint - me

proc findDuckCell(bot: Bot, client: ProtocolClient, me, threat: Vec): int =
  ## The nearest directly-reachable cell around us whose center the threat
  ## cannot see; -1 when no nearby cover breaks the line.
  result = -1
  let
    c0 = cellOf(me)
    cx0 = c0 mod GridW
    cy0 = c0 div GridW
  var bestD = 1e18
  for dy in -DuckSearchCells .. DuckSearchCells:
    for dx in -DuckSearchCells .. DuckSearchCells:
      let
        nx = cx0 + dx
        ny = cy0 + dy
      if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
        continue
      let nc = ny * GridW + nx
      if not bot.cellWalkable[nc]:
        continue
      let p = cellCenter(nc)
      if not bot.gridRayClear(me, p):
        continue
      if client.pixelRayClear(p, threat):
        continue                          # the threat can still see this cell
      let d = dist(p, me)
      if d < bestD:
        bestD = d
        result = nc

proc findPeekCell(bot: Bot, client: ProtocolClient, me, aim: Vec): int =
  ## The nearest directly-reachable cell that opens a firing line to `aim`
  ## within gun range; -1 when no sidestep grants the shot.
  result = -1
  let
    c0 = cellOf(me)
    cx0 = c0 mod GridW
    cy0 = c0 div GridW
  var bestD = 1e18
  for dy in -PeekSearchCells .. PeekSearchCells:
    for dx in -PeekSearchCells .. PeekSearchCells:
      let
        nx = cx0 + dx
        ny = cy0 + dy
      if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
        continue
      let nc = ny * GridW + nx
      if not bot.cellWalkable[nc]:
        continue
      let p = cellCenter(nc)
      if dist(p, aim) > FireRange or not bot.gridRayClear(me, p):
        continue
      if not client.pixelRayClear(p, aim):
        continue
      let d = dist(p, me)
      if d < bestD:
        bestD = d
        result = nc

proc updateTracks(bot: Bot, tracks: var seq[Track], seen: seq[Actor]) =
  ## Matches this frame's sightings to remembered tracks and prunes stale
  ## ones. Velocity is a blended px/tick estimate used to lead shots.
  var claimed = newSeq[bool](tracks.len)
  for a in seen:
    var
      best = -1
      bestD = TrackMatchDist
    for i in 0 ..< tracks.len:
      if claimed[i]:
        continue
      let d = dist(tracks[i].pos, a.pos)
      if d < bestD:
        bestD = d
        best = i
    if best >= 0:
      let
        dt = float(max(1, bot.tick - tracks[best].lastSeen))
        v = (a.pos - tracks[best].pos) * (1.0 / dt)
      tracks[best].vel = vec(
        clamp((tracks[best].vel.x + v.x) * 0.5, -3.0, 3.0),
        clamp((tracks[best].vel.y + v.y) * 0.5, -3.0, 3.0)
      )
      tracks[best].pos = a.pos
      tracks[best].facingRight = a.facingRight
      tracks[best].lastSeen = bot.tick
      if a.hp > 0:
        tracks[best].hp = a.hp
      tracks[best].aimBrads = a.aimBrads   # -1 when this frame's dots unreadable
      claimed[best] = true
    else:
      tracks.add(Track(
        pos: a.pos, lastSeen: bot.tick, facingRight: a.facingRight, hp: a.hp,
        aimBrads: a.aimBrads))
      claimed.add(true)
  var kept: seq[Track]
  for t in tracks:
    if bot.tick - t.lastSeen <= TrackTtl:
      kept.add(t)
  kept.sort(proc(a, b: Track): int = cmp(b.lastSeen, a.lastSeen))
  if kept.len > TrackCap:                # there are only eight real players
    kept.setLen(TrackCap)
  tracks = kept

proc resetTransient(bot: Bot) =
  ## Drops per-game memory between rounds (lobby / game-over interstitials).
  bot.enemies.setLen(0)
  bot.mates.setLen(0)
  bot.nadeCharge = 0
  bot.mateFixTick = 0
  bot.shoutWant = ""
  bot.lastShoutTick = 0
  bot.carrierSeen = -100_000
  bot.lastEnemySeen = bot.tick
  bot.gameStart = bot.tick
  bot.firedLast = false
  bot.estAim = spawnAim(bot.team)
  bot.rotSign = 0
  bot.wasDead = false
  bot.scanHigh = false
  bot.stuckTicks = 0
  bot.jinkUntil = 0
  bot.behindLines = false
  bot.navGoal = -1
  bot.lockUntil = -100_000
  bot.aimLockUntil = -100_000
  bot.retreatUntil = -100_000
  bot.ownHp = 0
  bot.surpriseShoutTick = -100_000
  bot.dieShoutTick = -100_000
  bot.orientUntil = -100_000

proc scanAim(bot: Bot, watch: Vec, me: Vec = vec(-1, -1)): int =
  ## The scan-sweep aim while holding a position: rake the vision cone back
  ## and forth across the arc around the `watch` heading with real rotation.
  ## Flip the sweep direction whenever the current end is nearly reached.
  let center = bradsOf(watch)
  # #3 TWO-SPEED SCAN: a sentry's sweep should DWELL on the one bearing that
  # matters — the nearest fresh (recently-remembered) threat whose direction
  # falls inside the scan arc — instead of raking straight past it and letting
  # it close in the blind half of the cycle. The turret turns at a fixed rate,
  # so "slow near the danger" means: while such a threat exists, hold the cone
  # on its bearing (dwell); resume the full sweep once it fogs out. Only when a
  # position (`me`) is supplied and the lever is on.
  if bot.tune.twoSpeedScan and me.x >= 0:
    var
      best = -1
      bestD = ScanDwellRange
    for i in 0 ..< bot.enemies.len:
      if bot.tick - bot.enemies[i].lastSeen > ScanDwellTtl:
        continue
      let bearing = bradsOf(bot.enemies[i].pos - me)
      if abs(bradsErr(bearing, center)) > ScanArc:
        continue                         # outside the arc we are responsible for
      let d = dist(bot.enemies[i].pos, me)
      if d < bestD:
        bestD = d
        best = i
    if best >= 0:
      return bradsOf(bot.enemies[best].pos - me)
  var goal = (center + (if bot.scanHigh: ScanArc else: -ScanArc) +
    AimBrads) mod AimBrads
  if abs(bradsErr(goal, bot.estAim)) <= CombatDeadband:
    bot.scanHigh = not bot.scanHigh
    goal = (center + (if bot.scanHigh: ScanArc else: -ScanArc) +
      AimBrads) mod AimBrads
  goal

proc safestLaneY(bot: Bot, me: Vec): float =
  ## The carrier's lane home: fewest remembered enemies AND the best cover
  ## continuity — under map-wide guns a lane whose run has no cover nearby is
  ## a shooting gallery even when it looks empty.
  var
    bestLane = LaneMid
    bestScore = 1e18
  for lane in [LaneTop, LaneMid, LaneBottom]:
    var score = abs(me.y - lane) / 500.0     # mild bias toward the nearest lane
    for t in bot.enemies:
      let towardHome =
        if bot.team == Red: t.pos.x < me.x + 200
        else: t.pos.x > me.x - 200
      if towardHome and abs(t.pos.y - lane) < 120:
        score += 1.0
    for post in bot.enemyPosts:
      # The mirrored enemy sniper posts are standing threats on the run home
      # even when nobody has been seen there.
      if abs(post.y - lane) < 120:
        score += 1.0
    if bot.navBuilt:
      # Cover continuity: sample the run home along the lane and charge each
      # sample with no cover cell in its 3x3 nav neighborhood.
      let
        goalX = homeDeepX(bot.team)
        stepX = (if goalX > me.x: 32.0 else: -32.0)
      var
        x = me.x
        samples = 0
        bare = 0
      while (stepX > 0.0 and x < goalX) or (stepX < 0.0 and x > goalX):
        inc samples
        let
          c = cellOf(vec(x, lane))
          cx = c mod GridW
          cy = c div GridW
        block covered:
          for dy in -1 .. 1:
            for dx in -1 .. 1:
              let
                nx = cx + dx
                ny = cy + dy
              if nx >= 0 and ny >= 0 and nx < GridW and ny < GridH and
                  bot.coverCell[ny * GridW + nx]:
                break covered
          inc bare
        x += stepX
      if samples > 0:
        score += float(bare) / float(samples) * 2.0
    if score < bestScore:
      bestScore = score
      bestLane = lane
  bestLane

proc vanityRoll(slot, tick, salt: int): bool =
  ## Deterministic per-(slot, tick) coin for the vanity-shout rarity gate.
  ## Returns true on ~VanityShoutChance% of frames. Deliberately does NOT touch
  ## the shared rand() stream so the button mask stays byte-identical (the
  ## vanity shouts are proven mask-neutral only because the emit block never
  ## perturbs movement/aim jitter). A cheap integer hash gives per-bot,
  ## per-tick decorrelated draws without any global state.
  var h = uint32(slot * 2654435761'i64 and 0xFFFFFFFF)
  h = h xor uint32((tick * 40503 + salt * 2246822519'i64) and 0xFFFFFFFF)
  h = h * 2246822519'u32
  h = h xor (h shr 15)
  int(h mod 100'u32) < VanityShoutChance

proc friendlyBlocked(bot: Bot, me, aim: Vec, enemyDist: float): bool =
  ## True when a remembered teammate could eat the shot: the bullet is a
  ## corridor hitscan (~14px half width) along the aim ray and the server
  ## kills the NEAREST player inside it, friend or foe — 8v8 puts many
  ## teammates downrange. The fire axis is the exact angle the turret would
  ## fire at right now.
  let dir = bradsDir(bradsOf(aim - me))
  for t in bot.mates:
    let age = float(bot.tick - t.lastSeen)
    if age > 36:
      continue
    let
      rel = t.pos - me
      d = rel.len()
      along = dot(rel, dir)
    if along <= 0 or d < 1e-6:
      continue
    if along >= enemyDist + 14.0:
      continue                          # beyond the target: the target dies first
    if abs(cross(rel, dir)) < CorridorHalfWidth + age * 0.35:
      return true
  false

proc decide(bot: Bot, client: ProtocolClient): uint8 =
  ## Core CTF policy for one frame.
  when defined(statue):
    return 0'u8                          # test dummy: stand still all game
  let
    myColor = (if bot.team == Red: "red" else: "blue")
    enemyColor = (if bot.team == Red: "blue" else: "red")
    (alive, me) = client.findSelf(myColor)
  if not alive:
    # Dead: the view is fully fogged (only our corpse renders) and inputs
    # are ignored, so skip perception entirely.
    bot.firedLast = false
    bot.rotSign = 0
    bot.wasDead = true
    return 0
  if bot.wasDead:
    # Respawned: the server points the aim back at the enemy side.
    bot.wasDead = false
    bot.estAim = spawnAim(bot.team)
  # Absolute turret fix: our own rendered aim-indicator dots show the actual
  # aim every frame, capping any dead-reckoning drift (mask-apply races).
  block resync:
    let seen = client.observedAim(me, myColor)
    if seen >= 0 and abs(bradsErr(seen, bot.estAim)) > AimResyncBrads:
      bot.estAim = seen
  let
    shotReady = client.spriteObjectsWithLabel("fire icon").len > 0
    seenEnemies = client.actorsFor(enemyColor)
    seenMates = client.actorsFor(myColor)
  # Surprise sensing (read BEFORE updateTracks rewrites lastSeen): an enemy in
  # our face that we were NOT already tracking freshly is a jump-scare — the
  # corner-turn ambush. Drives the "oh shit!" shout.
  # Nearest visible teammate: a genuine ambush is an ENEMY closer than any mate.
  # In a clustered brawl the closest actor is usually a friendly, and a fleeing/
  # dying enemy read a frame stale used to fire "oh shit!" while we were buried
  # in teammates (Maxwell 2026-07-16). Require the surprising enemy to be
  # strictly closer than our nearest mate so it only ever fires on an OPPONENT
  # in our face, never a nearby friendly.
  var nearestMateD = Inf
  for m in seenMates:
    let dm = dist(m.pos, me)
    if dm < nearestMateD:
      nearestMateD = dm
  var surprisePos = vec(-1, -1)
  var surpriseD = SurpriseRadius
  for a in seenEnemies:
    let d = dist(a.pos, me)
    if d >= surpriseD or d >= nearestMateD:
      continue
    var trackedFresh = false
    for t in bot.enemies:
      if dist(t.pos, a.pos) <= TrackMatchDist and
          bot.tick - t.lastSeen <= SurpriseGapTicks:
        trackedFresh = true
        break
    if not trackedFresh:
      surpriseD = d
      surprisePos = a.pos
  bot.updateTracks(bot.enemies, seenEnemies)
  bot.updateTracks(bot.mates, seenMates)
  if seenEnemies.len > 0:
    bot.lastEnemySeen = bot.tick

  # Damage awareness (SIGHT + SOUND): our own hp pip bar is always sent to us,
  # so a drop since last frame means we were just hit. If no enemy is in front
  # of us (nothing fresh in our cone), find the nearest "shot sound" muzzle
  # ring — a fogged shooter firing at us — and orient toward that bearing so we
  # stop getting shot in the back. Gated behind tune.damageAware.
  block damageSense:
    let (haveHp, hp) = client.selfHp(me, myColor)
    if not haveHp:
      break damageSense
    let prevHp = bot.ownHp
    bot.ownHp = hp
    if not bot.tune.damageAware or prevHp <= 0 or hp >= prevHp:
      break damageSense                  # first read, respawn, or no damage
    # We took a hit. Is a threat already in view? If so, combat handles it.
    var haveFreshVisible = false
    for a in seenEnemies:
      if dist(a.pos, me) <= FireRange:
        haveFreshVisible = true
        break
    if haveFreshVisible:
      break damageSense
    # Shot from an unseen direction: orient toward the nearest muzzle ring.
    var ringPos = vec(-1, -1)
    var ringD = ShotSoundRange
    for o in client.spriteObjectsWithLabel("shot sound"):
      let p = client.mapPos(o)
      let d = dist(p, me)
      if d < ringD:
        ringD = d
        ringPos = p
    if ringPos.x >= 0:
      bot.orientPos = ringPos
      bot.orientUntil = bot.tick + HpDropOrientTicks

  # Flag bookkeeping (two flags; a carried flag rides its carrier's exact
  # position). The enemy flag can only be carried by OUR team, so its sprite
  # is never fogged and fully describes our attack (pedestal / on me / on a
  # mate). Our own flag can only be carried by the enemy: on its pedestal it
  # is safe, visible off-pedestal is a live thief fix, and ABSENT means a
  # fogged thief is running it toward its home edge.
  var
    iCarry = false
    mateCarry = false
    mateCarryPos: Vec
  let
    stealTarget = flagHome(enemy(bot.team))  # the enemy pedestal is static
    ownHome = flagHome(bot.team)
    enemyFlags = client.spriteObjectsWithLabel(enemyColor & " heart")
    ownFlags = client.spriteObjectsWithLabel(myColor & " heart")
  if bot.tune.shout or bot.tune.reactContact:
    # Team comms intake: teammates broadcast on the one shout channel — a
    # 10-char message heard through walls/fog within ~247px. We read the label
    # "<myColor> shout <addr>: <text>" and decode by leading token:
    #   "C<cx> <cy>" carrier's own position (8px grid) — escort fix
    #   "E <cell> <cell>.." enemy callouts on the chess grid — orient the cone
    #   "oh shit!" / "die"  contact shouts — orient toward the shouter's bubble
    # The bubble's own jittered coordinates give the shouter's rough position,
    # used only for the "orient toward the panic/fire" contact reaction.
    for o in client.spriteObjects():
      if not o.label.startsWith(myColor & " shout "):
        continue
      let sep = o.label.rfind(": ")
      if sep < 0:
        continue
      let text = o.label[sep + 2 .. ^1]
      if text.len == 0:
        continue
      # Shouter's rough (jittered) location — same map-space math as mapPos, but
      # spriteObjects() yields a bare tuple (no SpriteObjectInfo), so inline it.
      let bubblePos = vec(
        float((o.x + o.width div 2) div RenderScale + client.mapCameraX),
        float((o.y + o.height div 2) div RenderScale + client.mapCameraY))
      if text[0] == 'C':
        # Carrier heartbeat: fresher than any dead-reckoned escort estimate.
        let parts = text[1 .. ^1].split(' ')
        if parts.len == 2:
          try:
            bot.mateFixPos = vec(float(parseInt(parts[0]) * 8 + 4),
              float(parseInt(parts[1]) * 8 + 4))
            bot.mateFixTick = bot.tick
          except ValueError:
            discard
      elif text[0] == 'E' and bot.tune.reactContact:
        # Enemy callout: seed a fresh track at each named cell we don't already
        # have fresher eyes on, and orient the vision cone toward the nearest.
        var nearest = vec(-1, -1)
        var nearestD = 1e18
        for cell in text[1 .. ^1].split(' '):
          if cell.len == 0:
            continue
          let p = chessDecode(cell)
          if p.x < 0:
            continue
          if dist(p, me) < nearestD:
            nearestD = dist(p, me)
            nearest = p
          # Only adopt if we have no fresh track already near this cell.
          var known = false
          for t in bot.enemies:
            if bot.tick - t.lastSeen <= CalloutFreshTicks and
                dist(t.pos, p) <= float(MapW) / float(ChessFiles):
              known = true
              break
          if not known:
            bot.enemies.add(Track(pos: p, vel: vec(0, 0),
              lastSeen: bot.tick - FreshShotTicks - 1, hp: 0,
              aimBrads: -1))  # a lead, not a shot — no gun bearing known
        # ⭐ Seeding the track above is the ALWAYS-ON intel intake — even a
        # committed carrier now KNOWS the called enemy. The REACTION (turn the
        # cone / move the feet) is separate: with the gate on, only STAGE the
        # nearest callout; the task-priority gate below (after all commitment
        # states are known) decides whether to act on it. Gate off => the old
        # indiscriminate reorient of anyone in earshot.
        if nearest.x >= 0 and nearestD <= ShoutHeardRange:
          if bot.tune.calloutGate:
            bot.calloutPos = nearest
            bot.calloutTick = bot.tick
          else:
            bot.orientPos = nearest
            bot.orientUntil = bot.tick + ContactWatchTicks
      elif (text == "oh shit!" or text == "die") and bot.tune.reactContact:
        # Contact shout from a mate in earshot: turn the vision cone toward the
        # panic/fire so someone covers the ambush (turn-and-watch, not a rush).
        if dist(bubblePos, me) <= ShoutHeardRange:
          if bot.tune.calloutGate:
            bot.calloutPos = bubblePos
            bot.calloutTick = bot.tick
          else:
            bot.orientPos = bubblePos
            bot.orientUntil = bot.tick + ContactWatchTicks
  if enemyFlags.len > 0:
    let fp = client.mapPos(enemyFlags[0])
    # Self-carry test: the heart hovers over its carrier, so "am I the
    # carrier" is "is the heart on MY head and on nobody else's" — a visible
    # mate closer to the heart than us means the mate is the carrier.
    var mateCloser = false
    let dSelf = dist(fp, me)
    for t in bot.mates:
      if bot.tick - t.lastSeen <= 2 and dist(t.pos, fp) < dSelf:
        mateCloser = true
        break
    # The heart is "in play" (off pedestal on a carrier) either when it has
    # travelled >16px OR — the deadlock case — when it rides a carrier standing
    # ON the pedestal. A carried heart is glued to its carrier's center every
    # tick and rendered CarriedFlagLift px overhead, so it shows DIRECTLY above
    # me (fp.x == me.x within rounding, fp.y ~10px up). An enemy pedestal heart
    # I'm merely APPROACHING sits on the pedestal AHEAD of me (x-offset by my
    # approach distance), so requiring x-alignment cleanly rejects that. And the
    # sim's auto-pickup makes any living player within FlagPickupRange of an
    # un-carried pedestal heart the carrier INSTANTLY (so a non-carrier inside
    # that range exists for ~1 tick) — hence "on the pedestal" (<=FlagPickupRange)
    # plus x-aligned overhead is a sound self-carry signal even at <16px travel.
    let grabbedOnPedestal = bot.tune.carrierGrabDetect and
      dist(me, stealTarget) <= FlagPickupRange and
      abs(fp.x - me.x) <= 6.0 and fp.y <= me.y + 4.0
    if dSelf <= CarrySelfRadius and (dist(fp, stealTarget) > 16.0 or
        grabbedOnPedestal) and not mateCloser:
      iCarry = true
    elif dist(fp, stealTarget) > 16.0:
      mateCarry = true                   # only a teammate can be carrying it
      mateCarryPos = fp
      bot.mateFixPos = fp
      bot.mateFixTick = bot.tick
  else:
    # The enemy heart is ABSENT from the frame: it is off its pedestal on a
    # FOGGED carrier — and only OUR team can carry it, so a teammate is
    # running it home right now even though we cannot see it. Without this
    # inference the whole wave keeps pressing an empty pedestal instead of
    # covering the run. Escort a dead-reckoned fix: the last sighting (or
    # the pedestal it was lifted from) advanced homeward at carrier speed.
    mateCarry = true
    var est =
      if bot.mateFixTick > 0: bot.mateFixPos
      else: stealTarget
    let elapsed = float(bot.tick - max(bot.mateFixTick, bot.gameStart))
    est.x += homeSign(bot.team) * min(
      abs(ownHome.x - est.x),
      elapsed * CarrierEstSpeed
    )
    mateCarryPos = est
  when defined(carryDebug):
    if bot.tick mod 50 == 0 and (iCarry or mateCarry):
      var fpS = "none"
      if enemyFlags.len > 0:
        let fp = client.mapPos(enemyFlags[0])
        fpS = $int(fp.x) & "," & $int(fp.y) & " d=" & $int(dist(fp, me))
      echo "CARRY t=", bot.tick, " slot=", bot.slot, " role=", bot.role,
        " iCarry=", iCarry, " mateCarry=", mateCarry,
        " me=", int(me.x), ",", int(me.y), " fp=", fpS,
        " mateCarryPos=", int(mateCarryPos.x), ",", int(mateCarryPos.y)
      flushFile(stdout)
  var ownStolen = ownFlags.len == 0
  var sawThief = false
  if ownFlags.len > 0:
    let fp = client.mapPos(ownFlags[0])
    if dist(fp, ownHome) <= 6:
      bot.carrierSeen = -100_000         # our flag is safely home
    else:
      # The thief holding our flag is inside our vision: take a fresh fix.
      ownStolen = true
      sawThief = true
      bot.carrierPos = fp
      bot.carrierVel = vec(0, 0)
      for t in bot.enemies:
        if dist(t.pos, fp) <= 8:
          bot.carrierVel = t.vel
          break
      bot.carrierSeen = bot.tick

  # (Shout EMIT is deferred to the end of decide(): the "die" pre-fire call
  # needs this frame's fire decision, so all four messages are prioritized and
  # emitted together once the button mask is known — see the emit block below.)

  # Flank progress: sticky so lane-runners do not oscillate at the boundary.
  if bot.role in {FlankTop, FlankBottom}:
    let fwd = -homeSign(bot.team) * (me.x - float(CenterX))
    if fwd >= FlankDepth - 50.0:
      bot.behindLines = true
    elif fwd < 20.0:
      bot.behindLines = false

  # Endgame push: our flag is safe and nobody on OUR side has seen an enemy
  # for a long while deep into the game. The survivors by then are usually
  # the defensive seats, and holding their posts forever is a guaranteed
  # tiebreak stalemate — break the posts and go win by capture (the enemy
  # team pushes symmetrically, so somebody makes something happen).
  let pushOut = not ownStolen and (
    (bot.tick - bot.gameStart > PushOutMinGame and
     bot.tick - bot.lastEnemySeen > PushOutTicks) or
    # Late all-in: a timeout is a scoreless draw, so deep into a game with no
    # capture the posts are worth nothing — break them and go win. Standoffs
    # keep enemies in sight, so the quiet-field trigger above never fires
    # against a peek-duck opponent; this one is on the clock.
    bot.tick - bot.gameStart > LatePushTick
  )

  # Local force balance: an attacker that finds itself outnumbered by fresh
  # enemies inside RetreatRadius — more enemy guns than friendly guns, self
  # included — breaks off and regroups instead of feeding a 1-vs-N duel.
  # Gated behind tune.forceBalance (OFF in the shipped tune — FALSIFIED
  # 2026-07-14 as a win lever, retained only so the harness BALANCE=1 knob
  # still exercises it).
  let offenseRole = bot.role in
    {MidTop, MidBottom, MidGuard, FlankTop, FlankBottom}
  let onOffense = (bot.tune.forceBalance or bot.tune.fireSuperiority) and
    offenseRole and
    not iCarry and not mateCarry and not ownStolen and
    dist(me, stealTarget) >= bot.tune.pocketRushRange
  if onOffense:
    if bot.tune.fireSuperiority:
      # #9 PRESS-VS-BREAK ON FIRE SUPERIORITY (the corrected forceBalance —
      # the head-count version was FALSIFIED because breaking on raw numbers
      # fights the win mechanism: firefights won → wipes/cleared carrier lanes
      # → captures). Break off ONLY when we are genuinely fire-INFERIOR, i.e.
      # the enemy's REAL guns outweigh ours. A wounded enemy is a fractional
      # gun (a 1-hp enemy is one of our trigger-pulls from gone), so weight each
      # fresh local enemy by its remaining hp fraction; unknown hp counts full.
      # Our side counts self + fresh local mates as whole guns. Press (never set
      # retreatUntil) whenever that effective margin is within reach — audacity
      # by default, withdraw only against a real overmatch.
      var enemyGuns = 0.0
      var friendGuns = 1.0               # ourselves, a whole gun
      for t in bot.enemies:
        if bot.tick - t.lastSeen <= LocalFreshTicks and
            dist(t.pos, me) <= RetreatRadius:
          enemyGuns += (if t.hp in 1 ..< MaxHp: t.hp.float / MaxHp.float else: 1.0)
      for t in bot.mates:
        if bot.tick - t.lastSeen <= LocalFreshTicks and
            dist(t.pos, me) <= RetreatRadius:
          friendGuns += 1.0
      if enemyGuns - friendGuns >= bot.tune.outnumberMargin.float:
        bot.retreatUntil = bot.tick + RetreatHold  # commit the fall-back (hysteresis)
    else:
      var localEnemies = 0
      var localFriends = 1               # ourselves
      for t in bot.enemies:
        if bot.tick - t.lastSeen <= LocalFreshTicks and
            dist(t.pos, me) <= RetreatRadius:
          inc localEnemies
      for t in bot.mates:
        if bot.tick - t.lastSeen <= LocalFreshTicks and
            dist(t.pos, me) <= RetreatRadius:
          inc localFriends
      if localEnemies - localFriends >= bot.tune.outnumberMargin:
        bot.retreatUntil = bot.tick + RetreatHold  # hysteresis: commit the fall-back
  let retreating = onOffense and bot.tick <= bot.retreatUntil
  # The fall-back point: regroup on the nearest fresh mate who is NOT deeper in
  # enemy territory than we are (two guns beat the 1-vs-N), else withdraw toward
  # our own side.
  var regroupTo = vec(me.x + homeSign(bot.team) * RetreatStep, me.y)
  if retreating:
    var bestD = RegroupRadius
    for t in bot.mates:
      if bot.tick - t.lastSeen > LocalFreshTicks:
        continue
      if homeSign(bot.team) * (t.pos.x - me.x) < -20.0:
        continue                         # this mate is further into the jaws
      let d = dist(t.pos, me)
      if d < bestD:
        bestD = d
        regroupTo = t.pos
    regroupTo.x = clamp(regroupTo.x, 20.0, float(MapW - 20))
    regroupTo.y = clamp(regroupTo.y, 20.0, float(MapH - 20))

  # Movement target from role and flag situation.
  var target: Vec
  if retreating:
    # Outnumbered locally: pull back to regroup. The combat block below still
    # fires at anything already lined up while we withdraw (a free trade on the
    # way out is fine) — we just stop ADVANCING into the losing cluster.
    target = regroupTo
  elif iCarry:
    # Run the stolen enemy flag home along the emptiest lane; the exposure
    # cost in the path field keeps the route hugging cover past remembered
    # enemies.
    let
      pocket = flagHome(enemy(bot.team))
    var laneY = bot.safestLaneY(me)
    if bot.tune.carrierClearBand:
      # ⭐ Grab-survival: every kill respawns an armed, spawn-protected (thus
      # UNKILLABLE) enemy at this pedestal aimed E-W across pedestal height. A
      # carrier lane at that height (safestLaneY often picks LaneMid) is a
      # straight run down that firing line — the drop@home~4% death. Force the
      # lane to the nearer band-clear corridor and, while still in the pocket
      # AND inside the respawn band, drive PURE-VERTICAL to clear the cone in the
      # fewest ticks before turning for home.
      if abs(laneY - float(CenterY)) < RespawnBandHalf:
        laneY = (if me.y < float(CenterY): LaneTop else: LaneBottom)
      if abs(me.x - pocket.x) < PocketClearX and
          abs(me.y - float(CenterY)) < RespawnBandHalf:
        target = vec(me.x, laneY)          # straight out of the cone, no home-x yet
      else:
        target = vec(homeDeepX(bot.team), laneY)
    elif abs(me.x - pocket.x) < 60.0 and abs(me.y - laneY) > 70.0:
      # Bug out of the pocket VERTICALLY first: every kill respawns an
      # armed, spawn-protected enemy at this pedestal whose spawn aim points
      # along the east-west axis — pure-vertical movement exits that cone
      # fastest, then the border lane runs home outside it.
      target = vec(pocket.x, laneY)
    else:
      target = vec(homeDeepX(bot.team), laneY)
  elif ownStolen and (bot.role == HomeDefender or
      (bot.role == Overwatch and
       bot.tick - bot.carrierSeen <= ThiefFixTtl) or
      (defined(swarm) and not iCarry and not mateCarry and
       bot.tick - bot.carrierSeen <= ThiefFixTtl)):
    # swarm: in shuffled-seat leagues this policy fields only 2-3 agents and
    # their roles are seat-lottery — when our flag is stolen with a fresh fix,
    # whoever sees it hunts, or an enemy capture ends the episode against us.
    # The back line intercepts the thief running OUR flag toward ITS home
    # edge; attackers keep pressing the enemy pedestal so the capture race
    # stays on. With a fresh fix, converge on the predicted route; without
    # one the thief is fogged but MUST cross mid toward its home edge, so
    # the defender guards the crossing on the lane nearest the last fix and
    # sweeps its vision — reacquisition takes eyes, not magic.
    if bot.tick - bot.carrierSeen <= ThiefFixTtl:
      # Converge on the thief's predicted path toward the enemy capture edge.
      var predicted = bot.carrierPos +
        bot.carrierVel * float(18 + bot.tick - bot.carrierSeen)
      predicted.x += -homeSign(bot.team) * 40.0
      target = vec(clamp(predicted.x, 20.0, float(MapW - 20)),
                   clamp(predicted.y, 20.0, float(MapH - 20)))
    else:
      var laneY = LaneMid
      if bot.carrierSeen > -100_000:
        var bestD = 1e18
        for lane in [LaneTop, LaneMid, LaneBottom]:
          if abs(bot.carrierPos.y - lane) < bestD:
            bestD = abs(bot.carrierPos.y - lane)
            laneY = lane
      target = vec(float(CenterX) - homeSign(bot.team) * 60.0, laneY)
  elif mateCarry and bot.tune.carrierScreen and
      bot.role in {MidBottom, FlankBottom, MidGuard}:
    # ⭐⭐⭐ CONE SCREEN: the killer of a fresh carrier is the INVULNERABLE
    # respawner at the robbed pedestal, shooting straight E-W (spawn aim) at the
    # carrier's y. It is not a "remembered enemy" (it just spawned), so the old
    # nearest-threat screen never sees it. Body-block the ray instead: sit at
    # the carrier's EXACT y, one body toward the enemy pocket the shot comes
    # from — selectFireTarget stops at the first body (friendly fire ON), so the
    # escort eats the shot meant for the carrier. Only while the carrier is
    # still in the danger corridor near the pocket; past that, normal escort.
    let
      pocket = flagHome(enemy(bot.team))
      pocketDist = abs(mateCarryPos.x - pocket.x)
    if pocketDist < PocketClearX * 3.0:
      # -homeSign points from the carrier back toward the enemy pocket.
      target = vec(mateCarryPos.x - homeSign(bot.team) * 30.0, mateCarryPos.y)
    else:
      target = mateCarryPos + vec(homeSign(bot.team) * 40.0, 0.0)
  elif mateCarry:
    case bot.role
    of MidTop, FlankTop:
      target = mateCarryPos + vec(homeSign(bot.team) * 46.0, -30.0)
    of MidBottom, FlankBottom:
      # Rear guard: sit between the carrier and the enemy pocket it just
      # robbed — respawners chase from there, and the gun kills the NEAREST
      # player in the cone, so a body on the ray shields the carrier.
      target = mateCarryPos + vec(
        -homeSign(bot.team) * 42.0,
        (if bot.role == MidBottom: 22.0 else: -22.0)
      )
    of MidGuard:
      # Screen the carrier from the nearest remembered threat.
      var threat = -1
      var threatD = 1e18
      for i in 0 ..< bot.enemies.len:
        let d = dist(bot.enemies[i].pos, mateCarryPos)
        if d < threatD:
          threatD = d
          threat = i
      if threat >= 0:
        target = mateCarryPos + norm(bot.enemies[threat].pos - mateCarryPos) * 30.0
      else:
        target = mateCarryPos + vec(-homeSign(bot.team) * 32.0, 0.0)
    of Overwatch:
      when defined(swarm):
        # Only 2-3 of our agents exist: a completed capture ends the episode,
        # so even the back line escorts the run home.
        target = mateCarryPos + vec(homeSign(bot.team) * 40.0, 24.0)
      else:
        # The posts already overwatch the carrier's retreat across mid.
        target =
          if bot.postReady: bot.postHold
          else: mateCarryPos + vec(-homeSign(bot.team) * 32.0, 0.0)
    of HomeDefender:
      when defined(swarm):
        target = mateCarryPos + vec(homeSign(bot.team) * 40.0, -24.0)
      else:
        target =
          if bot.tune.pointOfDomination and bot.dominateReady: bot.dominatePost
          else: bot.chokeHold      # #7: command the crossing while we attack
  elif bot.role == HomeDefender and not pushOut:
    # Hold the choke on our pedestal approach; break off to chase the nearest
    # intruder on our half (every steal has to come through here).
    var intruder = -1
    var intruderD = 1e18
    for i in 0 ..< bot.enemies.len:
      let onOurHalf =
        if bot.team == Red: bot.enemies[i].pos.x < float(CenterX) + 60
        else: bot.enemies[i].pos.x > float(CenterX) - 60
      if not onOurHalf:
        continue
      let d = dist(bot.enemies[i].pos, me)
      if d < intruderD:
        intruderD = d
        intruder = i
    if intruder >= 0:
      target = bot.enemies[intruder].pos + bot.enemies[intruder].vel * 6.0
    elif bot.tune.pointOfDomination and bot.dominateReady:
      # #7 POINT OF DOMINATION: hold the cover cell that commands the most of the
      # ground an intruder must cross, not a fixed choke — see the thief coming
      # down any lane and kill it before the pocket.
      target = bot.dominatePost
    else:
      target = bot.chokeHold
  elif bot.role == Overwatch and not pushOut:
    if bot.postReady:
      # Peek-and-shoot cycle: hold behind the post; with the gun up and a
      # remembered enemy in reach, sidestep to the peek cell to open the
      # line (the combat block below takes the shot and ducks us back).
      target = bot.postHold
      if shotReady:
        for t in bot.enemies:
          if bot.tick - t.lastSeen <= 24 and
              dist(t.pos, bot.postHold) < FireRange + 30.0:
            target = bot.postPeek
            break
    else:
      target = vec(float(CenterX) + homeSign(bot.team) * 70.0, float(CenterY))
  else:
    # Attackers: route to the ENEMY pedestal — a fixed, known position by
    # team side. The lead rusher races it dead straight (its seat spawns at
    # pedestal height), the second mid trails behind and offset so one enemy
    # cone cannot kill the pair; flankers run the extreme lanes deep past
    # mid, then hit the pedestal pocket from behind.
    target = stealTarget
    case bot.role
    of MidBottom:
      if dist(me, stealTarget) > 90:
        target = stealTarget + vec(homeSign(bot.team) * 34.0, 26.0)
    of MidGuard:
      if dist(me, stealTarget) > 90:
        target = stealTarget + vec(homeSign(bot.team) * 60.0, -26.0)
    of FlankTop, FlankBottom:
      # Run the wide lane deep, then turn straight in for the grab so the
      # flankers hit the pocket together with the mid trio instead of
      # trickling in.
      let laneY = (if bot.role == FlankTop: LaneTop else: LaneBottom)
      if not bot.behindLines and dist(me, stealTarget) > 170.0:
        target = vec(float(CenterX) - homeSign(bot.team) * FlankDepth, laneY)
    else:
      discard

  # The mid trio plays for the flag, not for position: pickup races and
  # carrier chases are lost to peek/duck detours, so mids keep moving and
  # shoot on the move whenever a mate is not already carrying.
  let rushing = not iCarry and not mateCarry and
    bot.role in {MidTop, MidBottom, MidGuard}
  # The pocket endgame: duelling at the pocket edge is an infinite respawn
  # grinder (respawners appear spawn-protected AT the pedestal), so the
  # attacker CLOSEST to the pedestal commits to the touch, unarmed and
  # undistracted, while the rest of the wave keeps its guns up to cover the
  # grab — even a suicide grab forces the enemy back onto defense, and a
  # lucky one starts the capture run.
  var nearestMateToSteal = 1e18
  for t in bot.mates:
    if bot.tick - t.lastSeen > 48:
      continue
    nearestMateToSteal = min(nearestMateToSteal, dist(t.pos, stealTarget))
  let pocketRush = not iCarry and not mateCarry and
    bot.role in {MidTop, MidBottom, MidGuard, FlankTop, FlankBottom} and
    dist(me, stealTarget) < PocketRushRange and
    dist(me, stealTarget) < nearestMateToSteal + 8.0

  # Combat: the nearest fresh track with a clear pixel ray AND a mate-free
  # fire cone is the engage target; the nearest fresh-but-wall-blocked track
  # is the peek candidate. The map-wide gun engages fresh tracks far beyond
  # the view, so chases keep killing after the target leaves the window —
  # but objective play caps the range: the carrier only fights point-blank,
  # rushers racing for the steal and escorts guarding a run only fight what
  # is actually in the way, instead of frag-chasing across the map.
  let maxEngage =
    if pocketRush: 0.0
    elif iCarry and bot.tune.carrierSprint: 0.0  # ⭐⭐ carrier never fights:
      # the diagnosis showed carriers survive ~110t but travel ~4% of the run —
      # PINNED firing at the invulnerable spawn-protected respawner (wasted) while
      # advancing into the nest. Engage 0 drops the combat branch so the carrier
      # pure-navigates home at full speed, turret free (still nav-steered).
    elif iCarry: bot.tune.carrierFireRange
    elif rushing: bot.tune.rushEngageRange
    elif mateCarry: bot.tune.escortEngageRange
    else: bot.tune.fireRange
  # Focus-fire intel: which remembered enemies sit on a visible mate's aim
  # line right now. A mate's rendered aim dots are an absolute readback of
  # where it is about to shoot; piling our shot onto the same target converts
  # two 1-damage hits into a kill instead of two wounded runners.
  var mateTargeted = newSeq[bool](bot.enemies.len)
  for m in bot.mates:
    if bot.tick - m.lastSeen > 2:
      continue                          # dots exist only while the mate is visible
    let mAim = client.mateAimBrads(m.pos, me, myColor)
    if mAim < 0:
      continue
    let dir = bradsDir(mAim)
    for i in 0 ..< bot.enemies.len:
      if bot.tick - bot.enemies[i].lastSeen > FreshShotTicks:
        continue
      let rel = bot.enemies[i].pos - m.pos
      let along = dot(rel, dir)
      if along <= 0.0 or along > MateAimRayLen:
        continue
      if abs(cross(rel, dir)) <= MateAimHitSlack:
        mateTargeted[i] = true

  var
    engage = -1
    engageD = maxEngage
    engagePrio = maxEngage
    aim: Vec
    engageBody: Vec                     # the engage target's REAL last-seen pos
    blockedAim: Vec
    haveBlocked = false
    blockedD = maxEngage
  for i in 0 ..< bot.enemies.len:
    let t = bot.enemies[i]
    if bot.tick - t.lastSeen > bot.tune.freshShotTicks:
      continue
    let predicted = t.pos + t.vel * (float(bot.tick - t.lastSeen) + bot.tune.leadTicks)
    let d = dist(predicted, me)
    if d >= maxEngage:
      continue
    # Target priority: distance plus the turret swing needed to lay on the
    # target (the traverse is slow, so a target near the current aim line
    # dies sooner than a nearer one behind us), discounted for wounded
    # targets (a 1-hp enemy dies to one shot — finish it before it resets on
    # respawn) and for targets a visible mate is already lined up on (focus
    # fire). The discounts are tiebreaks between comparably-engageable
    # targets, deliberately smaller than a real positional difference.
    var prio = d +
      float(abs(bradsErr(bradsOf(predicted - me), bot.estAim))) * TraversePxPerBrad
    if t.hp in 1 ..< MaxHp:
      prio -= float(MaxHp - t.hp) * HpFocusBonus
    if mateTargeted[i]:
      prio -= FocusFireBonus
    # Greatest-threat-first: an enemy FACING us can shoot this instant, so it
    # is more dangerous than an equidistant one looking away (gated OFF).
    let facingMe =
      (t.facingRight and t.pos.x < me.x) or
      (not t.facingRight and t.pos.x > me.x)
    # AIM-DOT THREAT (#19): the coarse facingRight test only knows which half-
    # plane the enemy faces — it flags a gun pointed 89° off us as "facing." When
    # aimThreat is on and we read the enemy's aim-dot line, replace that with a
    # real gun-on-me cone: aimScale is 1.0 when the gun is dead-on us, tapers to
    # a floor at the cone edge, and 0 when the gun points elsewhere (NOT a threat
    # this instant). Falls back to the half-plane (aimScale 1/0) when the dots are
    # unreadable, so we never lose the old signal.
    var aimScale = (if facingMe: 1.0 else: 0.0)
    if bot.tune.aimThreat and t.aimBrads >= 0:
      let aimErr = abs(bradsErr(t.aimBrads, bradsOf(me - t.pos)))
      if aimErr <= AimOnConeBrads:
        let tight = clamp(
          float(AimOnConeBrads - aimErr) /
            float(AimOnConeBrads - AimDeadOnBrads), 0.0, 1.0)
        aimScale = 0.4 + 0.6 * tight     # 0.4 on-cone floor → 1.0 dead-on
      else:
        aimScale = 0.0                   # gun points elsewhere: no threat now
    if bot.tune.dangerScore:
      # #1 GREATEST-THREAT-FIRST (richer danger score, supersedes the flat
      # facing tiebreak): a gun that is BOTH pointed at us AND close can kill us
      # THIS second — that is the target to neutralize first, ahead of a nearer
      # one looking away. Scale the facing credit UP as range closes (a facing
      # enemy at point-blank is lethal now; one at 600px is a rumor), and stack
      # an extra increment when it is also wounded (facing + one hit from death
      # = the cheapest kill that also removes the most danger). Credit is capped
      # so it stays a strong PRIORITY nudge, never a reason to fire past cover.
      if aimScale > 0.0:
        let closeFrac = clamp(1.0 - d / DangerFalloff, 0.0, 1.0)
        prio -= (AimThreatBonus + DangerCloseBonus * closeFrac) * aimScale
        if t.hp in 1 ..< MaxHp:
          prio -= DangerWoundedBonus * aimScale
    elif bot.tune.threatFacingBonus:
      if facingMe:
        prio -= AimThreatBonus
    # Target commitment: heavily favour the enemy we are already engaged with
    # (matched by its last-known position) so three shots land on ONE target
    # and kill it, rather than one shot each spread across many wounded ones.
    if bot.tune.commit and bot.tick <= bot.lockUntil and
        dist(t.pos, bot.lockPos) <= LockMatchDist:
      prio -= bot.tune.commitBonus
    if client.pixelRayClear(me, predicted):
      if bot.friendlyBlocked(me, predicted, d):
        continue                        # prefer a target with an empty corridor
      if engage < 0 or prio < engagePrio:
        engagePrio = prio
        engageD = d
        engage = i
        aim = predicted
        engageBody = t.pos
    elif d < blockedD:
      blockedD = d
      blockedAim = predicted
      haveBlocked = true

  # Refresh the commitment lock onto whichever target we chose this frame, so
  # next frame's selection is drawn back to it until it dies or fogs out.
  if bot.tune.commit and engage >= 0:
    bot.lockPos = bot.enemies[engage].pos
    bot.lockHp = bot.enemies[engage].hp
    bot.lockUntil = bot.tick + LockTtl

  # TARGET-LOCK: pin the turret on a committed enemy's bearing so the vision
  # cone (which rides the aim) keeps them lit and the gun stays pre-lined.
  # Refresh onto the engage target when we have one; otherwise hold onto the
  # freshest engageable-range enemy so a brief fog-out does not throw the aim
  # back to the movement lane.
  if bot.tune.aimLock:
    if engage >= 0:
      bot.aimLockPos = bot.enemies[engage].pos
      bot.aimLockUntil = bot.tick + AimHoldTtl
    else:
      var best = -1
      var bestD = maxEngage
      for i in 0 ..< bot.enemies.len:
        if bot.tick - bot.enemies[i].lastSeen > bot.tune.freshShotTicks:
          continue
        let d = dist(bot.enemies[i].pos, me)
        if d < bestD:
          bestD = d
          best = i
      if best >= 0:
        bot.aimLockPos = bot.enemies[best].pos
        bot.aimLockUntil = bot.tick + AimHoldTtl

  # The nearest remembered enemy that could be threatening us right now,
  # used to pick which line to break when ducking through cooldown.
  var
    nearThreat = -1
    nearThreatD = DuckRange
  for i in 0 ..< bot.enemies.len:
    if bot.tick - bot.enemies[i].lastSeen > 30:
      continue
    let d = dist(bot.enemies[i].pos, me)
    if d < nearThreatD:
      nearThreatD = d
      nearThreat = i

  # #6 BUDDY BOUNDING OVERWATCH: never stroll forward across a threatened open
  # lane while MY gun is on cooldown. A gun that is down cannot answer a shot,
  # so advancing into a live enemy line during the reload is how an attacker
  # trades itself for nothing. Instead HOLD at cover for the reload while a
  # covering mate's gun stays up, then bound forward when my gun is live again.
  # This keeps at least one team gun always trained on the crossing. Only for
  # advancing attackers (rushers who cross the open middle), only vs a threat
  # with a clear line to us beyond duck range (the duck branch owns the close
  # ones), and only when a fresh mate is nearby and not deeper in the jaws (so
  # the bound is genuinely covered, not a solo freeze that surrenders tempo).
  var boundHold = false
  var boundThreatPos: Vec
  if bot.tune.boundingOverwatch and not shotReady and
      not iCarry and not mateCarry and not pocketRush and
      bot.role in {MidTop, MidBottom, MidGuard, FlankTop, FlankBottom}:
    var lineThreat = -1
    var lineThreatD = BoundThreatRange
    for i in 0 ..< bot.enemies.len:
      if bot.tick - bot.enemies[i].lastSeen > BoundThreatTtl:
        continue
      let d = dist(bot.enemies[i].pos, me)
      if d <= DuckRange or d >= lineThreatD:
        continue                           # duck branch owns close; ignore far
      if client.pixelRayClear(me, bot.enemies[i].pos):
        lineThreatD = d
        lineThreat = i
    if lineThreat >= 0:
      var covered = false
      for t in bot.mates:
        if bot.tick - t.lastSeen > BoundMateTtl:
          continue
        if dist(t.pos, me) > BoundMateRange:
          continue
        if homeSign(bot.team) * (t.pos.x - me.x) < -BoundMateDepth:
          continue                         # this mate is further into the jaws
        covered = true
        break
      if covered:
        boundHold = true
        boundThreatPos = bot.enemies[lineThreat].pos

  # ⭐ SHOUT-REACTION GATE (calloutGate): a heard callout is INTEL, and the
  # track was already banked at intake — even a committed carrier now KNOWS the
  # called enemy. This gate decides only whether the report earns a vision-cone
  # GLANCE, keyed on the bot's task priority (SEAL "priority of work / need-to-
  # know"), now that every commitment state is settled. It NEVER moves the feet:
  # v1 (2026-07-16) mis-classed the pedestal-rushers as "free guns" and let a
  # callout pull 5/8 seats off the heart-rush → grabs collapsed, −12 seat-adj.
  # Maxwell's correction: a rusher advancing on the pedestal is ALREADY occupied
  # by an objective, so it joins the committed tier — and since every seat in
  # this policy always has a job, no report ever earns the feet. Cone-only.
  if bot.tune.calloutGate and bot.calloutTick == bot.tick:
    let
      cp = bot.calloutPos
      selfD = dist(cp, me)
      # Proximity override: a callout inside our own tight bubble, or dead-ahead
      # in a narrow cone on our travel bearing (a threat we are about to walk
      # INTO), earns a glance even from a committed bot — a dead carrier/rusher
      # captures nothing, so surviving the walk-in IS serving the objective.
      inLaneCone = abs(bradsErr(bradsOf(cp - me), bradsOf(target - me))) <=
        CalloutLaneCone
      proximity = selfD <= CalloutSelfBubble or
        (inLaneCone and selfD <= CalloutLaneReach)
    var glance = false
    if engage >= 0 or boundHold:
      # Owns a fresh target / bounding across a covered lane: already committed
      # to a threat we can win — a report never preempts a gun we're winning.
      glance = false
    elif iCarry or pocketRush or rushing:
      # OCCUPIED BY THE OBJECTIVE: the carry, the final grab, and an attacker
      # advancing on the pedestal all outrank a report (Maxwell: rushers "are
      # occupied by a current objective already"; his example — "enemy next to
      # the heart" is worth KNOWING, not worth stopping the grab). Only the
      # survival proximity override earns the glance.
      glance = proximity
    elif mateCarry:
      # Escorting a carrier run: a real job. Glance only at a callout near the
      # carrier we screen or on our own body — need-to-know for the run we cover.
      glance = dist(cp, mateCarryPos) <= CalloutSectorRange or proximity
    elif bot.role in {Overwatch, HomeDefender}:
      # Posted: need-to-know. Glance ONLY at a callout inside the sector this bot
      # guards (the thief/our home for the defender, its post for the sniper) —
      # a defender never leaves its post for a report, but it MUST look when the
      # contact is on the ground it was placed to hold.
      let guardPt =
        if bot.role == HomeDefender:
          (if ownStolen: bot.carrierPos else: ownHome)
        elif bot.postReady: bot.postHold
        else: me
      glance = dist(cp, guardPt) <= CalloutSectorRange or proximity
    else:
      # No commitment matched (e.g. a flanker recalled off its deep lane with no
      # rush active): the only genuinely uncommitted case. Glance if in earshot.
      glance = selfD <= ShoutHeardRange
    if glance:
      bot.orientPos = cp
      bot.orientUntil = bot.tick + ContactWatchTicks

  # Grenades (0.7.0): a lobbed 2-hp blast that flies over every wall — the
  # counter to cover-campers the hitscan gun can never reach. Carry one when a
  # corner pickup is a short detour away; spend it on a wall-blocked fresh
  # track (value the gun cannot collect) or on a tight enemy pair in range.
  var carryingNade = false
  for o in client.spriteObjectsWithLabel("grenade carried"):
    # The marker floats above-right of its carrier (+8 x, ~-20 y from center).
    if dist(client.mapPos(o), me) <= 30.0:
      carryingNade = true
      break
  var
    nadeAim = -1
    nadeThrowD = 0.0
  if carryingNade and not iCarry:
    var bestD = 1e18
    for i in 0 ..< bot.enemies.len:
      let t = bot.enemies[i]
      if bot.tick - t.lastSeen > FreshShotTicks:
        continue
      let p = t.pos + t.vel * float(bot.tick - t.lastSeen)
      let d = dist(p, me)
      if d < NadeMinRange or d > NadeMaxRange or d >= bestD:
        continue
      let blocked = not client.pixelRayClear(me, p)
      var paired = false
      if not blocked:
        for j in 0 ..< bot.enemies.len:
          if j != i and bot.tick - bot.enemies[j].lastSeen <= FreshShotTicks and
              dist(bot.enemies[j].pos, p) <= NadeBlast:
            paired = true
            break
      if blocked or paired:
        bestD = d
        nadeAim = bradsOf(p - me)
        nadeThrowD = d
  elif not carryingNade and not iCarry and not mateCarry and not pocketRush:
    # Collect a pickup: anyone grabs one within a short detour, and the two
    # flankers own their lane's friendly-side corner spawn — it sits right on
    # their border route, so they arm up on the way out every respawn cycle.
    for o in client.spriteObjectsWithLabel("grenade"):
      let p = client.mapPos(o)
      if p.x < 40.0 or p.y < 40.0 or p.x > float(MapW - 40) or
          p.y > float(MapH - 40):
        continue                     # HUD indicator shares the label
      let laneMatch =
        (bot.role == FlankTop and p.y < float(CenterY) and
         homeSign(bot.team) * (p.x - float(CenterX)) > 0) or
        (bot.role == FlankBottom and p.y > float(CenterY) and
         homeSign(bot.team) * (p.x - float(CenterX)) > 0)
      let reach = if laneMatch: 1e9 else: NadePickupDetour
      if dist(p, me) <= reach:
        when defined(nadeDebug):
          echo "DETOUR to pickup at ", p.x, ",", p.y, " role ", bot.role
        target = p
        break

  # Grenade danger: a visible throw-target ring marks where an enemy's lob
  # will land, and an airborne grenade is seconds from bursting — anything
  # inside the blast radius eats 2 of 3 hit points. Fleeing the marked spot
  # outranks every movement goal except nothing: dead carriers drop the run.
  var
    nadeDanger = false
    nadeDangerFrom: Vec
  block nadeDangerScan:
    for label in ["throw target", "grenade air"]:
      for o in client.spriteObjectsWithLabel(label):
        let p = client.mapPos(o)
        if dist(p, me) <= NadeBlast + 18.0:
          nadeDanger = true
          nadeDangerFrom = p
          break nadeDangerScan

  # Turret + locomotion, decided together but on separate buttons: moveMask
  # is the d-pad, desiredAim feeds the rotate buttons, wantFire pulls A.
  var
    moveMask: uint8
    desiredAim = -1
    deadband = bot.tune.combatDeadband
    wantFire = false
    acted = false
    holdStill = false
    nadeC = false
  if bot.nadeCharge > 0 or nadeAim >= 0:
    # Charge-throw: lay the turret on the lob line, then hold C for the ticks
    # the planned distance needs and release — the grenade leaves along the
    # CURRENT aim on release, so the turret keeps correcting while charging.
    if bot.nadeCharge == 0:
      bot.nadeNeed = max(3, int(float(NadeFullChargeTicks) *
        (nadeThrowD - 30.0) / (NadeMaxRange - 30.0)))
    if nadeAim >= 0:
      desiredAim = nadeAim
    if bot.nadeCharge > 0 or (desiredAim >= 0 and
        abs(bradsErr(desiredAim, bot.estAim)) <= CombatDeadband + 2):
      if bot.nadeCharge < bot.nadeNeed:
        nadeC = true
        inc bot.nadeCharge
      else:
        bot.nadeCharge = 0           # release this tick = the throw
    holdStill = true
    acted = true
  elif engage >= 0 and shotReady:
    # Traverse onto the target and fire once the corridor covers it: the
    # perpendicular miss of the current aim error at the target's range must
    # sit inside the ~14px bullet corridor. Advancing scales that miss down
    # linearly, so keep closing while the turret settles.
    desiredAim = bradsOf(aim - me)
    let
      err = abs(bradsErr(desiredAim, bot.estAim))
      perpMiss = engageD * sin(float(err) * PI / float(AimBrads div 2))
    wantFire = perpMiss <= bot.tune.fireSlackPx
    if bot.tune.fireOnRealBody:
      # Also open the trigger when the current aim's perp-miss to the target's
      # REAL last-seen position sits in the corridor (the lead phantom swings
      # wide on a juking target). Aim still LEADS; this only OPENS the trigger.
      let
        bodyAim = bradsOf(engageBody - me)
        bodyErr = abs(bradsErr(bodyAim, bot.estAim))
        bodyD = dist(engageBody, me)
        bodyMiss = bodyD * sin(float(bodyErr) * PI / float(AimBrads div 2))
      if bodyMiss <= bot.tune.fireSlackPx and
          client.pixelRayClear(me, engageBody) and
          not bot.friendlyBlocked(me, engageBody, bodyD):
        wantFire = true
    if retreating or (bot.tune.carrierFlee and iCarry):
      # Outnumbered (retreat) OR carrying the heart (flee): keep the gun on the
      # lined-up target and take the free trade, but MOVE toward our objective
      # (the regroup point / home capture edge) instead of advancing into the
      # enemy. A carrier that steps toward a point-blank respawner walks into the
      # invulnerable respawn nest at the pedestal and dies at ~2% of the run home
      # — the single biggest leak in the grab->capture funnel. The heart only
      # scores by reaching our edge, so the carrier NEVER trades ground for a kill.
      moveMask = octantBits(bot.navSteer(client, me, target))
    else:
      moveMask = octantBits(aim - me)
    if bot.tune.unstuckEngaged and bot.tick < bot.jinkUntil:
      # A stuck burst is in flight while we advance on the target: keep jinking
      # so a corner-grind actually breaks free instead of re-grinding the wall
      # every frame. The gun still fires on-line.
      moveMask = bot.jinkBits
    acted = true
  elif not iCarry and not rushing and not pocketRush and not shotReady and
      nearThreat >= 0:
    # Cooldown: our gun is down and a threat is near. Default = duck behind the
    # nearest cover that breaks its line and hold there until the gun is back
    # up, keeping the aim (and the vision cone) on the arc it would push through.
    let tp = bot.enemies[nearThreat]
    let facingMe =
      (tp.facingRight and tp.pos.x < me.x) or
      (not tp.facingRight and tp.pos.x > me.x)
    let pressWorth =
      bot.tune.tempoPress and bot.tick - tp.lastSeen <= TempoFreshTicks and
      # #8 TEMPO / AUDACITY — press on the half-beat: our reload is dead time,
      # but so is theirs if the threat can't punish us right now. When it is
      # WOUNDED (one or two of our returning trigger-pulls from dead) or TURNED
      # AWAY (its gun isn't on us this instant), don't surrender tempo to a duck
      # — CLOSE the distance while jinking, so the moment our gun is live we are
      # on top of it and finish it in ITS dead time. Only inside a band where
      # closing actually pays; a facing, full-hp gun still gets the duck.
      ((tp.hp in 1 ..< MaxHp) or not facingMe) and
      dist(tp.pos, me) <= TempoPressRange
    if pressWorth:
      desiredAim = bradsOf(tp.pos - me)      # pre-lay for the returning shot
      # Close on a jinking line (never a static/straight target): step toward
      # the threat with a sideways weave so we are not walking a clean corridor
      # into a gun that may come back up first.
      let toward = norm(tp.pos - me)
      var side = vec(-toward.y, toward.x)
      if (bot.tick div 10 + bot.slot div 2) mod 2 == 0:
        side = side * -1.0
      if not bot.gridRayClear(me, me + side * 24.0):
        side = side * -1.0
      moveMask = octantBits(toward + side * 0.5)
      acted = true
    else:
      let duck = bot.findDuckCell(client, me, tp.pos)
      if duck >= 0:
        desiredAim = bradsOf(tp.pos - me)
        if dist(cellCenter(duck), me) < 5.0:
          holdStill = true
        else:
          moveMask = octantBits(cellCenter(duck) - me)
        acted = true
  elif boundHold:
    # #6 BUDDY BOUNDING OVERWATCH: our gun is down and a mid-range enemy has a
    # clear line to us across open ground, but a covering mate's gun is up. Do
    # NOT bound forward into that line while reloading — duck to the nearest
    # cover that breaks the line and hold there, cone on the threat, until our
    # gun is live again (then shotReady flips and the engage/advance branches
    # resume the bound). One team gun stays trained on the crossing the whole
    # time. If no cover breaks the line, at least stop advancing (hold still).
    let duck = bot.findDuckCell(client, me, boundThreatPos)
    desiredAim = bradsOf(boundThreatPos - me)
    if duck >= 0 and dist(cellCenter(duck), me) >= 5.0:
      moveMask = octantBits(cellCenter(duck) - me)
    else:
      holdStill = true
    acted = true
  elif not iCarry and not rushing and shotReady and haveBlocked:
    # Peek: PRE-LAY the aim on the blocked target while stepping sideways to
    # the nearest cell that opens the firing line — the engage branch fires
    # the moment the ray clears, with the traverse already done.
    desiredAim = bradsOf(blockedAim - me)
    let peek = bot.findPeekCell(client, me, blockedAim)
    if peek >= 0 and dist(cellCenter(peek), me) > 4.0:
      moveMask = octantBits(cellCenter(peek) - me)
      acted = true

  if not acted:
    # Threat jink: sidestep a visible enemy that is aiming our way while our
    # own shot is not lined up, instead of walking into its muzzle.
    var threat = -1
    var threatD = ThreatRange
    for i in 0 ..< seenEnemies.len:
      let a = seenEnemies[i]
      let facingMe =
        (a.facingRight and a.pos.x < me.x) or
        (not a.facingRight and a.pos.x > me.x)
      let d = dist(a.pos, me)
      if facingMe and d < threatD:
        threatD = d
        threat = i
    if threat >= 0 and not iCarry and not pocketRush:
      let away = norm(me - seenEnemies[threat].pos)
      var side = vec(-away.y, away.x)
      if (bot.tick div 12 + bot.slot div 2) mod 2 == 0:
        side = side * -1.0
      if not bot.gridRayClear(me, me + side * 24.0):
        side = side * -1.0
      moveMask = octantBits(side + away * 0.4)
      if desiredAim < 0:
        desiredAim = bradsOf(seenEnemies[threat].pos - me)
    elif bot.role in {Overwatch, HomeDefender} and
        dist(me, target) < 6.0:
      # Holding a watch position: the aim carries the vision cone, so sweep
      # it back and forth across the arc threats cross while standing still.
      # While our flag is stolen the thief comes from our own half;
      # otherwise intruders come from the enemy half.
      let watch =
        if ownStolen: vec(homeSign(bot.team), 0.0)
        else: vec(-homeSign(bot.team), 0.0)
      if desiredAim < 0:
        desiredAim = bot.scanAim(watch, me)
      holdStill = true
    else:
      # Navigate: cover-aware path steering plus soft repulsion from nearby
      # teammates so one burst (or our own shot) cannot hit two of us.
      var steer = norm(bot.navSteer(client, me, target))
      for t in bot.mates:
        if bot.tick - t.lastSeen > 12:
          continue
        let d = dist(t.pos, me)
        if d < MateSpacing and d > 0.5:
          steer = steer + norm(me - t.pos) * ((MateSpacing - d) / MateSpacing) * 0.9
      # Serpentine when a straight run would cross watched ground. Fog cuts
      # both ways: a fresh remembered enemy with a clear pixel line pins
      # anyone, and rushers crossing the contested MIDDLE weave even without
      # intel — the snipers watching their lane are exactly the enemies they
      # cannot see. Close threats are the jink/duck branches' job; carriers
      # and the pocket grab skip it — for them speed beats evasion.
      if not iCarry and not pocketRush:
        var weave = false
        if rushing:
          weave = abs(me.x - float(CenterX)) < WeaveBand
        else:
          for t in bot.enemies:
            if bot.tick - t.lastSeen > UnderFireTrackTtl:
              continue
            let d = dist(t.pos, me)
            if d >= SerpentineNear and d <= SerpentineFar and
                client.pixelRayClear(me, t.pos):
              weave = true
              break
        if weave:
          var side = vec(-steer.y, steer.x)
          if (bot.tick div 8 + bot.slot div 2) mod 2 == 0:
            side = side * -1.0
          steer = norm(steer) + side * 0.6
      steer = steer + vec(rand(-0.12 .. 0.12), rand(-0.12 .. 0.12))
      moveMask = octantBits(steer)
      if bot.tick < bot.jinkUntil:
        moveMask = bot.jinkBits            # unsticking burst
      # Carriers and the pocket-grab rusher keep the cone down their escape
      # lane — for them speed beats gunfighting, so the lock/hunt overrides skip.
      let mayHunt = not iCarry and not pocketRush
      if desiredAim < 0 and mayHunt and bot.tune.aimLock and
          bot.tick <= bot.aimLockUntil:
        # ⭐ TARGET-LOCK: we hold a fresh enemy but have no clear shot THIS
        # frame (fogged, wall-blocked, or on cooldown). Do NOT snap the aim to
        # the movement lane — that surrenders a bearing we paid 5-brads/tick to
        # acquire and drops the enemy out of the cone. Keep the turret smoothly
        # pursuing the locked body so the moment the line clears we fire.
        desiredAim = bradsOf(bot.aimLockPos - me)
      elif desiredAim < 0 and mayHunt and bot.tune.huntSweep:
        # HUNTING POSTURE: no lock, but actively acquire — aim at the nearest
        # recently-remembered enemy rather than blindly down-lane.
        var best = -1
        var bestD = 1e18
        for i in 0 ..< bot.enemies.len:
          if bot.tick - bot.enemies[i].lastSeen > HuntSweepTtl:
            continue
          let d = dist(bot.enemies[i].pos, me)
          if d < bestD:
            bestD = d
            best = i
        if best >= 0:
          desiredAim = bradsOf(bot.enemies[best].pos - me)
        else:
          desiredAim = bradsOf(steer)
          deadband = CruiseDeadband
      if desiredAim < 0 and mayHunt and bot.tick <= bot.orientUntil and
          bot.orientPos.x >= 0:
        # CONTACT ORIENT: a mate's "oh shit!"/"die"/callout or an own-HP drop
        # from an unseen shooter gave us a bearing to face for a beat. With no
        # target of our own pulling the turret, swing the vision cone onto it
        # (turn-and-watch) so we pick the threat up instead of walking blind.
        desiredAim = bradsOf(bot.orientPos - me)
        deadband = CruiseDeadband
      if desiredAim < 0:
        # No target demands the turret: the aim leads the movement direction
        # so the vision cone watches down-lane where we are heading. Movement
        # no longer leaks our vision, so this is a choice, not a side effect.
        desiredAim = bradsOf(steer)
        deadband = CruiseDeadband

  # Stuck detection: if we have not moved for a second (and are not holding
  # behind cover on purpose), burst in a random direction and force a repath.
  if dist(me, bot.lastPos) < 0.8:
    inc bot.stuckTicks
  else:
    bot.stuckTicks = 0
  bot.lastPos = me
  if holdStill:
    bot.stuckTicks = 0
  if bot.stuckTicks > 20 and
      (engage < 0 or retreating or bot.tune.unstuckEngaged):
    bot.stuckTicks = 0
    bot.jinkUntil = bot.tick + 10
    bot.jinkBits = octantBits(vec(rand(-1.0 .. 1.0), rand(-1.0 .. 1.0)))
    bot.navGoal = -1
    if bot.jinkBits == 0:
      bot.jinkBits = ButtonUp
    moveMask = bot.jinkBits

  if nadeDanger:
    # Sprint straight out of the marked blast zone; drop any hold/duck.
    let away = me - nadeDangerFrom
    moveMask = octantBits(
      if len(away) < 1.0: vec(homeSign(bot.team), 0.3) else: away
    )
    holdStill = false

  if moveMask == 0 and not holdStill:
    moveMask = octantBits(vec(rand(-1.0 .. 1.0), rand(-1.0 .. 1.0)))

  # Rotate toward the desired aim by the shortest arc; inside the deadband
  # (AimRate cannot settle tighter than +-AimRate/2) hold the turret still.
  var rotBits: uint8 = 0
  if desiredAim >= 0:
    let err = bradsErr(desiredAim, bot.estAim)
    if err > deadband:
      rotBits = ButtonB
    elif err < -deadband:
      rotBits = ButtonSelect

  # Only a FRESH A press fires, and the pull locks the aim angle on the same
  # tick — never rotate on the pull tick so the lock takes the settled aim.
  var mask = moveMask or rotBits
  if wantFire and not bot.firedLast:
    mask = moveMask or ButtonA
  if nadeC:
    mask = mask or ButtonC
  bot.firedLast = (mask and ButtonA) != 0
  bot.rotSign =
    if (mask and ButtonB) != 0: 1
    elif (mask and ButtonSelect) != 0: -1
    else: 0

  # ── Team shout emit (one channel, server-capped ~1/s): pick the single
  # highest-value message this frame and stage it in shoutWant for the caller
  # to send. Priority: a close-range ambush ("oh shit!") > a pre-fire warning
  # ("die") > enemy position callouts ("E <cell>..") > the carrier's own-
  # position heartbeat ("C<cx> <cy>"). Each flavor has its own cooldown so none
  # spams; ShoutGapTicks (> the server's ShoutCooldownTicks) keeps us under the
  # cap. Every flavor is independently gated so the harness can A/B one at a
  # time; the whole emitter is off unless tune.shout.
  if bot.tune.shout and bot.tick - bot.lastShoutTick >= ShoutGapTicks:
    var say = ""
    if bot.tune.shoutSurprise and surprisePos.x >= 0 and
        bot.tick - bot.surpriseShoutTick >= SurpriseShoutCooldown:
      # Consume the cooldown window whether or not we actually yell, then emit
      # on only VanityShoutChance% of windows — otherwise the roll just re-fires
      # every frame and the cooldown stays the real (spammy) throttle.
      bot.surpriseShoutTick = bot.tick
      if vanityRoll(bot.slot, bot.tick, 1):
        say = "oh shit!"
    elif bot.tune.shoutDie and (mask and ButtonA) != 0 and
        bot.tick - bot.dieShoutTick >= DieShoutCooldown:
      # We are opening fire this tick: warn a nearby friendly so they take
      # cover or look our way and help finish the kill.
      var mateNear = false
      for t in bot.mates:
        if bot.tick - t.lastSeen <= LocalFreshTicks and
            dist(t.pos, me) <= DieEarshot:
          mateNear = true
          break
      if mateNear:
        # Same rare-flavor gate: consume the window, emit ~VanityShoutChance%.
        bot.dieShoutTick = bot.tick
        if vanityRoll(bot.slot, bot.tick, 2):
          say = "die"
    if say.len == 0 and bot.tune.shoutCallout:
      # Enemy callout: name the nearest fresh enemy cells on the chess grid so
      # mates who cannot see them swing their cones over. Dedupe cells and cap
      # the count so the address fits the 10-char shout.
      var chosen: seq[Track] = @[]
      for t in bot.enemies:
        if bot.tick - t.lastSeen <= CalloutFreshTicks:
          chosen.add t
      chosen.sort(proc(a, b: Track): int =
        cmp(dist(a.pos, me), dist(b.pos, me)))
      var cells: seq[string] = @[]
      for t in chosen:
        let c = chessCell(t.pos)
        if c notin cells:
          cells.add c
        if cells.len >= CalloutMaxCells:
          break
      if cells.len > 0:
        say = "E " & cells.join(" ")
    if say.len == 0 and iCarry and bot.tune.shoutCallout:
      # Carrier heartbeat: our own 8px-grid position so escorts converge. This
      # is STRATEGIC comms (broadcasts the carrier's exact spot — a position
      # tell to any shout-parsing enemy, since the bubble is range-audible to
      # both teams), so it rides shoutCallout, NOT the bare shout master: the
      # vanity-only champion (shout+surprise+die, callout off) must NOT leak the
      # carrier. It only ever HELPED when escorts reacted (reactContact), which
      # the shelved-comms champion also runs off — so off it's pure cost.
      say = "C" & $(int(me.x) div 8) & " " & $(int(me.y) div 8)
    if say.len > 0:
      bot.shoutWant = say
      bot.lastShoutTick = bot.tick

  mask

proc runBot(url: string) =
  ## Connects, then loops frames forever, reconnecting on disconnect.
  let
    slot = slotFromUrl(url)
    team = (if slot mod 2 == 0: Team.Red else: Team.Blue)
    role = roleForSeat(clamp(slot div 2, 0, 7), team)
    endpoint = ensureWsPath(url, WebSocketPath)
  randomize(slot * 7919 + 1)
  let bot = Bot(slot: slot, team: team, role: role, tune: shippedCombatTune())
  bot.resetTransient()
  echo "baseline slot=", slot, " team=", team, " role=", role, " -> ", endpoint
  let client = initProtocolClient()
  var everConnected = false
  while true:
    try:
      let ws = newWebSocket(endpoint)
      echo "connected ", endpoint
      everConnected = true
      client.reset()
      bot.navBuilt = false
      bot.resetTransient()
      var lastMask = 0xff'u8
      while true:
        if not client.receiveLatestFrame(ws, false):
          continue
        let advance = max(1, client.frameAdvance)
        bot.tick += advance
        # Dead-reckon the aim: the last sent mask keeps rotating on the
        # server for every elapsed sim tick until we change it.
        bot.estAim = floorMod(
          bot.estAim + bot.rotSign * AimRate * advance, AimBrads)
        if not client.mapCameraReady:
          bot.resetTransient()             # lobby / game-over interstitial
          continue
        if not bot.navBuilt and client.walkabilityReady:
          bot.buildNavGrid(client)
        let mask = bot.decide(client)
        if mask != lastMask:
          ws.send(inputBlob(mask), BinaryMessage)
          lastMask = mask
        # decide() stages at most one shout per frame (already self-rate-limited
        # under the server cap, and only ever set when tune.shout is on).
        if bot.shoutWant.len > 0:
          ws.send(chatBlob(bot.shoutWant), BinaryMessage)
          bot.shoutWant = ""
    except Exception as e:
      if everConnected:
        # The game ended and the server went away: exit so the episode
        # runner sees a clean player shutdown.
        echo "game over, exiting: ", e.msg
        quit(0)
      echo "connect retry: ", e.msg
      sleep(250)

when isMainModule and not defined(ctfEvalHarness):
  # The eval harness `include`s this file to drive the BYTE-IDENTICAL decision
  # path in-process; -d:ctfEvalHarness suppresses only this WS entrypoint so
  # the shipped player build (no such define) is completely unchanged.
  let url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if url.len == 0:
    raise newException(ValueError, "COWORLD_PLAYER_WS_URL is required.")
  runBot(url)
