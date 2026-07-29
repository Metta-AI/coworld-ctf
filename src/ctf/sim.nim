import
  std/[json, math, os, random, strutils],
  bitworld/aseprite, bitworld/pixelfonts, bitworld/profile, bitworld/spriteprotocol,
  bitworld/server,
  jsony, pixie

when not defined(emscripten):
  import bitworld/client as bitworldClient

import map_pool

const
  GameName* = "ctf"
  GameVersion* = "26"  ## Procedural terrain (mapPath "gen"/"pool", curated
                       ## pool in map_pool.nim) is CONFIG-GATED and ships
                       ## without a version bump: the default arena and its
                       ## rules are unchanged, and a league that enables it
                       ## does so through its own config. Replays carry the
                       ## exact geometry (mapSpec) either way.
                       ## GV26 (three operator rules): (a) the SELF marker
                       ## renders TRUE aim again — the fuzz hides OTHERS'
                       ## aim, never your own state; (b) HEART carriers fire
                       ## at 1/3 rate (CarrierFireSlowdown, shield-pattern);
                       ## (c) column-1's FIFTH vertical bar (y=395 +
                       ## x-mirror) is a glass window.
                       ## GV25: dead players respawn at a RANDOM spot in
                       ## their endzone (uniform over the home capture
                       ## column, deterministic sim RNG) — a fixed respawn
                       ## point can no longer be camped.
                       ## GV24: soldier sprites in PLAYER views render with
                       ## FUZZED gun rotation (±~20°, deterministic, both
                       ## sides, self included) — exact aim is never readable
                       ## off a sprite; broadcast board unaffected.
                       ## GV23: a depleted shield layer breaks the shield
                       ## outright (icon + fire slowdown end with the bubble),
                       ## and kills/heart-steals floor the game clock at
                       ## ActionClockFloorTicks remaining.
  ReplayFps* = 24
  DefaultMapPath* = "arena"
  DarkBgPath* = "data/darkbg.aseprite"
  SpriteSheetAsepritePath = "data/spritesheet.aseprite"
  SpriteSize* = 12
  CrewSpriteSize* = 16
  CrewSpriteVariants* = 8
  ## HD top-down soldier: the real Cogs-vs-Clips cog, one tinted master per team
  ## (soldier_red/blue.png, facing SOUTH, smile visor visible) plus the shared
  ## paintball gun master (paintgun.png, muzzle east). Body and gun are mounted
  ## as ONE rigid unit — the gun held in FRONT of the face, both pointing the
  ## same way — and pre-rotated together through SoldierRotations aim steps:
  ## the cog looks where it aims. The canvas is larger than the body only so
  ## the extended gun never clips as the unit rotates. Emitted through the
  ## existing player sprite id pool (16 ids per color) — this replaces the
  ## flat 8-variant + h-flip crew.
  SoldierRotations* = 16      ## pre-rendered aim steps (16 brads apart).
  SoldierCanvas* = 72         ## px square sprite canvas (fits the swinging gun).
  SoldierBodyPx* = 34         ## cog body target size on the map (full-body unit).
  GunLengthPx* = 34           ## top-down gun master length on the map (stock-tip to
                              ## muzzle, along the aim ray).
  GunGripPx* = -13            ## gun stock-tip offset from the body center, along
                              ## aim (negative = stock sits behind the hub so the
                              ## barrel reaches out front, marker straddling the cog).
  GunRightPx* = 10            ## the marker is held at the cog's RIGHT: barrel
                              ## centerline offset this far off the aim ray, toward
                              ## the head's right (screen +y when facing +x/east).
                              ## Enough to clear the head silhouette and read as a
                              ## distinct held object, without floating far off.
  GunGlowRadius* = 0.6        ## px blur (master-frame): tiny, so the rim is CRISP —
                              ## an outline stroke, not a soft glow.
  GunGlowSpread* = 1.0        ## px the silhouette expands before blurring — this is
                              ## the outline WIDTH that sticks out past the gun edge.
  GunGlowAlpha* = 95'u8       ## faint warm outline (0..255), reads as a subtle stroke.
  SprayHeldLengthPx* = 22     ## the held spray can's length on the map, along the
                              ## aim ray. Shorter than the marker (GunLengthPx):
                              ## a can is a fistful, and the silhouette difference
                              ## is what tells a viewer WHICH weapon a cog holds.
  SprayHeldGripPx* = -6       ## can tail offset from the body center along aim.
                              ## Less negative than GunGripPx so the short can
                              ## sits IN the fist rather than straddling the hub.
  CollisionW* = 1
  CollisionH* = 1
  PlayerHalf* = 6             ## half-extent of the solid player footprint, in px.
  SpriteDrawOffX* = 8
  SpriteDrawOffY* = 8
  ## Draw offset for the soldier: place the canvas so its center lands on
  ## the player position (canvas center = the body pivot).
  SoldierDrawOff* = SoldierCanvas div 2
  MotionScale* = 256
  Accel* = 76
  FrictionNum* = 144
  FrictionDen* = 256
  MaxSpeed* = 704
  StopThreshold* = 8
  MovementSlideMaxScan = 3
  PlayerSolidSpan* = 2 * PlayerHalf  ## centers this close (Chebyshev) means
                                     ## two player footprints overlap.
  PlayerBouncePct* = 40       ## restitution of player-player collisions, in
                              ## percent: 0 = a dead-stop shove, 100 = a
                              ## perfectly elastic billiard bounce.
  TargetFps* = 24
  SpaceColor* = 0'u8
  MapVoidColor* = 12'u8
  TintColor* = 3'u8
  ShadeTintColor* = 9'u8
  OutlineColor* = 0'u8

  # CTF tuning defaults (RULES.md). Second-based values convert at 24 ticks/sec.
  Lives* = 3
  HitPoints* = 3              ## hits to kill: each shot removes one hit point.
  RespawnTicks* = 72          ## ~3s before respawning at home.
  GunRange* = 1300            ## px, effectively map-wide on the default
                              ## arena; LOS and aim are the real limits.
                              ## Each map def carries its own value — see
                              ## CtfMap.gunRange.
  ExposureSampleStep* = 3     ## px between silhouette line-of-sight samples
                              ## across a target's body (±PlayerHalf): only
                              ## the exposed part of a body can be hit.
  BulletHalfWidth* = 8.0      ## the bullet corridor half-width: a shot travels
                              ## along the facing ray and hits the FIRST player
                              ## whose footprint crosses it.
  FireCooldownTicks* = 12     ## ~0.5s between shots.
  FireWindupTicks* = 5        ## ~0.2s from trigger pull to the shot; aim locks
                              ## at the pull, so a peeking target can duck back.
  ShotFxTicks* = 12           ## ~0.5s a shot tracer stays visible (cosmetic only).
  HitFlashTicks* = 8          ## ~0.33s the struck-target flash rings a victim
                              ## in the spectator view (cosmetic only).
  SplatterFxTicks* = 120      ## ~5s a death splatter stays visible (cosmetic only).
  HitFxTicks* = 34            ## ~1.4s a non-fatal hit's paint splat stays visible.
  DamageFxTicks* = 26         ## ~1.1s a floating "-1" damage pop rises and fades
                              ## after a hit (cosmetic only, never in gameHash).
  KillFxTicks* = 44           ## ~1.8s a floating "KO" kill marker rises and fades
                              ## after a death (cosmetic only, never in gameHash).
  CarrierSpeedPct* = 70       ## carrier moves at 70% speed.
  AimBradsTurn* = 256         ## aim angle units per full turn (binary radians).
  AimTurnRate* = 5            ## brads/tick a held rotate button turns the aim
                              ## (~7 deg/tick; a full turn takes ~2.1s).
  VisionConeDeg* = 60         ## vision cone half-angle around the aim angle.
  VisionBubble* = 90          ## omnidirectional vision radius in px.

  FovCellSize* = 8            ## fog-of-war visibility grid cell size in px.

  StartWaitTicks* = 5 * TargetFps
  GameOverTicks* = 360
  MaxTicks* = 5_000  ## 0 = no limit.
  ActionClockFloorTicks* = 500  ## a kill or heart steal leaves at least this
                                ## many ticks on the clock, so a timed game
                                ## never ends mid-action.
  MaxGames* = 0  ## 0 = no limit.
  MaxPlayers* = 16
  MinPlayers* = 16

  WinReward* = 1              ## each winner scores +1 on capture or wipe.
  LossReward* = -1            ## each loser scores -1 on capture or wipe.
  TimeoutReward* = -1         ## EVERY player scores -1 on a time-limit draw
                              ## (GameVersion 21): stalling out the clock is
                              ## never better than losing, for either side.

  FlagPickupRange* = 12       ## touch radius to steal the enemy flag.
  CaptureZoneWidth* = 40      ## width of each home-edge capture zone.
  PedestalCoverSize* = 96     ## px footprint the flag-home pedestal art covers.

  GrenadeSpawnInset* = 40     ## corner grenade spawn inset from the border.
  GrenadePickupRange* = 12    ## touch radius to pick a grenade up.
  GrenadeRespawnTicks* = 5 * ReplayFps  ## a taken corner refills after 5s.
  GrenadeMinRange* = 30       ## a tap's distance: inside the blast radius,
                              ## so a panicked drop can hurt the thrower.
  GrenadeChargeTicks* = 24    ## hold this long for a full-strength throw.
  GrenadeFlightMultiple* = 2  ## release-to-burst = this many shot windups,
                              ## REGARDLESS of distance: a grenade is a snap
                              ## weapon, not a mortar shell you can stroll
                              ## away from. (Was 6 px/tick of flight — a
                              ## full-range lob hung airborne ~41 ticks.)
  GrenadeBlastRadius* = 52    ## everyone inside the blast takes damage
                              ## (GameVersion 17: 40 -> 52, +30%).
  GrenadeDamage* = 2          ## hit points removed by one blast.
  BlastFxTicks* = 12          ## cosmetic blast flash duration in ticks.

  MedKitPickupRange* = 12     ## touch radius to pick a med kit up.
  MedKitRespawnTicks* = 30 * ReplayFps  ## a taken kit refills after 30s.
  PlasmaArcSpawnInset* = GrenadeSpawnInset
  PlasmaArcPickupRange* = 12  ## touch radius to pick a plasma arc up.
  PlasmaArcRespawnTicks* = 30 * ReplayFps
  PlasmaArcSquare* = SoldierBodyPx  ## one "square": a cog body length.
  PlasmaArcReach* = 4 * PlasmaArcSquare  ## forward cone reach: 4 squares.
  PlasmaArcMaxWidth* = 2 * PlasmaArcSquare  ## cone width AT max reach:
                              ## 2 squares. The cone widens linearly from the
                              ## muzzle, so the half-angle is atan(1/4) ~ 14.0
                              ## degrees everywhere along the reach.
  PlasmaArcDamage* = 3        ## hit points removed by one cone touch:
                              ## instantly lethal to a bare cog (3 hp), but a
                              ## shield carrier (6 hp) survives the first one.
  PlasmaArcActiveTicks* = 5   ## a fired cone stays on this many ticks,
                              ## tracking the attacker's position and aim.
  PlasmaArcResetTicks* = 20   ## recharge time after the cone shuts off; the
                              ## refire cadence is ActiveTicks + ResetTicks.
  PlasmaArcFxTicks* = 4       ## each per-tick cone snapshot fades this long
                              ## (cosmetic only).

  ShieldPickupRange* = 12     ## touch radius to pick a shield up.
  ShieldRespawnTicks* = 30 * ReplayFps  ## a taken endzone shield refills after 30s.
  ShieldLayerHp* = 3          ## hp in a full shield layer. Damage depletes
                              ## the layer before base hp; a pickup refills it
                              ## and never heals base damage.
  ShieldFireSlowdown* = 3     ## a shield carrier's fire cooldown is this many
                              ## times longer (3x slower fire rate).
  CarrierFireSlowdown* = 3    ## a HEART carrier's fire cooldown multiplier
                              ## (GV26): carriers can shoot, at a third the
                              ## rate. Shield+heart do not stack (max, not
                              ## product).

  BubbleImpactTicks* = 8      ## ~0.33s the bubble's blink/dent impact FX
                              ## lasts (cosmetic only, like HitFlashTicks).

  ShoutMaxChars* = 10         ## a shout is at most this many characters.
  ShoutTicks* = 3 * ReplayFps ## a shout stays observable this long.
  ShoutCooldownTicks* = ReplayFps  ## at most one shout per second.

  TextColor* = 2'u8
  TextLineHeight* = 7
  MapSpriteId* = 1
  MapObjectId* = 1
  MapLayerId* = 0
  MapLayerType* = 0
  ScoreboardLayerId* = 1       ## red team roster panel.
  ScoreboardLayerType* = 1     ## top-left anchor.
  ScoreboardRightLayerId* = 12 ## blue team roster panel.
  ScoreboardRightLayerType* = 2  ## top-right anchor.
  BottomRightLayerId* = 3
  BottomRightLayerType* = 3
  ZoomableLayerFlag* = 1
  UiLayerFlag* = 2
  PlayerSpriteBase* = 100
  FlagSpriteBase* = 700       ## team flag sprites: 700 red flag, 701 blue flag.
  SelectedPlayerSpriteBase* = 6000  ## outlined selected-soldier pool:
                              ## default 6000..6031, crown 6032..6063. Moved
                              ## from 800: that pool swallowed the hp pips
                              ## (820..823) and the sound/impact rings
                              ## (830/831) — same collision class as the
                              ## 2026-07-22 unit-tag/fire-icon incident.
  SelectedTextSpriteId* = 4000
  SelectedViewportSpriteId* = 4001
  PlayerObjectBase* = 1000
  SelectedTextObjectId* = 4000
  SelectedViewportObjectId* = 4001
  PlayerColors* = [
    3'u8,
    7,
    8,
    14,
    4,
    11,
    13,
    15,
    1,
    2,
    5,
    6,
    9,
    10,
    12,
    0
  ]
  PlayerColorNames* = [
    "red",
    "orange",
    "yellow",
    "light blue",
    "pink",
    "lime",
    "blue",
    "pale blue",
    "gray",
    "white",
    "dark brown",
    "brown",
    "dark teal",
    "green",
    "dark navy",
    "black"
  ]
  ## Team colors: Red team = palette red (3), Blue team = palette blue (13).
  RedTeamColor* = 3'u8
  BlueTeamColor* = 13'u8
  ShadowMap* = [
    0'u8,  #  0 black       -> black
    12,    #  1 gray         -> dark navy
    9,     #  2 white        -> dark teal
    5,     #  3 red          -> dark brown
    5,     #  4 pink         -> dark brown
    0,     #  5 dark brown   -> black
    5,     #  6 brown        -> dark brown
    5,     #  7 orange       -> dark brown
    5,     #  8 yellow       -> dark brown
    12,    #  9 dark teal    -> dark navy
    9,     # 10 green        -> dark teal
    9,     # 11 lime         -> dark teal
    0,     # 12 dark navy    -> black
    12,    # 13 blue         -> dark navy
    12,    # 14 light blue   -> dark navy
    9,     # 15 pale blue    -> dark teal
  ]
  WebSocketPath* = "/player"
  GlobalWebSocketPath* = "/global"
  ReplayWebSocketPath* = "/replay"
  RewardWebSocketPath* = "/reward"

## Runtime map state. The game supports multiple arenas ("arena" is the
## default, "arena-large" the 30%-larger variant); one is selected per
## process by loadCtfMap (driven by config.mapPath) BEFORE any sim, mask,
## or render work happens, and never changes afterward — the render bakes
## in global.nim rely on that per-process invariant. The values below are
## initialized to the default arena so tools that never call loadCtfMap
## keep working unchanged.
var
  MapWidth* = 1235
  MapHeight* = 659
  FovGridW* = (MapWidth + FovCellSize - 1) div FovCellSize
  FovGridH* = (MapHeight + FovCellSize - 1) div FovCellSize
  FovCellCount* = FovGridW * FovGridH
  GrenadeMaxRange* = MapWidth div 5  ## max throw distance (full charge).
  ShoutRange* = MapWidth div 5  ## audible within 20% of the screen width.

type
  Team* = enum
    Red
    Blue

  Skin* = enum
    DefaultSkin
    CrownSkin

  CtfError* = object of ValueError

  GamePhase* = enum
    Lobby
    Playing
    GameOver

  Room* = object
    name*: string
    x*, y*, w*, h*: int

  MapRect* = object
    x*, y*, w*, h*: int

  ArenaShapeKind* = enum
    shapeRect
    shapeDisc
    shapeDiamond
    shapeDiagonal

  ArenaShape* = object
    ## One arena obstacle. Discs and diamonds are center + radius (L2 and L1
    ## norms); diagonals are a 45-degree wall segment of given perpendicular
    ## thickness between two endpoints. A `window` shape is glass: it blocks
    ## movement, bullets, and spray-cone line-of-sight exactly like stone, but
    ## fog-of-war shadowcasting sees straight through it.
    window*: bool
    case kind*: ArenaShapeKind
    of shapeRect:
      rect*: MapRect
    of shapeDisc, shapeDiamond:
      cx*, cy*, radius*: int
    of shapeDiagonal:
      x0*, y0*, x1*, y1*, thickness*: int

  MapPoint* = object
    x*, y*: int

  MapSymmetry* = enum
    ## How a map's right half derives from its authored/generated left half.
    ## Both are exactly team-fair; rot180 keeps diagonal lanes diagonal
    ## instead of folding them into chevrons.
    symMirror
    symRot180

  ArenaMaterial* = object
    ## One arena's cover material for the carved-bevel shader: the flat top
    ## face, the up-left lit bevel, the down-right shaded bevel, and the carve
    ## outline where a block meets the floor. A zero-alpha `face` means "use
    ## the default warm carved stone".
    face*, hi*, lo*, ink*: ColorRGBA

  CtfMap* = object
    name*: string
    path*: string
    width*, height*: int
    mapLayer*, walkLayer*, wallLayer*: int
    center*: MapPoint
    rooms*: seq[Room]
    ## Arena layout: the open-space clearances, the map's default gun range,
    ## and the LEFT-half obstacle set (mirrored across the vertical center
    ## line on selection).
    flagRing*: int             ## clear radius of the open center ring.
    captureClear*: int         ## x-columns kept traversable for carriers.
    carveClear*: int           ## always-floor home column; 0 = captureClear.
    spawnClearW*: int          ## half-width of the open spawn pockets.
    spawnClearH*: int          ## half-height of the open spawn pockets.
    gunRange*: int             ## default gun range on this map (px).
    symmetry*: MapSymmetry
    genSeed*: int              ## generator seed; 0 for hand-authored maps.
    medKitSpawns*: seq[MapPoint]     ## the two ACTIVE med-kit points.
    medKitCandidates*: seq[MapPoint] ## the drawn candidate set (4 on
                                     ## generated maps; equals the active
                                     ## pair on hand-authored maps).
    leftObstacles*: seq[ArenaShape]
    ## An ASYMMETRIC layout, used verbatim (no x-mirror) when non-empty. Set
    ## this instead of leftObstacles for maps recreating real-world geometry.
    fullObstacles*: seq[ArenaShape]
    ## Per-map ART: the tiled floor texture under data/, and the cover
    ## material the carved-bevel shader paints obstacles with. Both are
    ## installed process-wide by selectCtfMap. An empty floorTex means the
    ## default arena_floor.png.
    floorTex*: string
    material*: ArenaMaterial

  CrewSprite* = ref object
    width*, height*: int
    rgba*: seq[uint8]

  RewardAccount* = object
    address*: string
    slotIndex*: int
    team*: Team
    hasTeam*: bool
    won*: bool
    abandoned*: bool
    reward*: int
    winsRed*: int
    winsBlue*: int
    gamesRed*: int
    gamesBlue*: int
    kills*: int
    deaths*: int
    captures*: int

  PlayerSlotConfig* = object
    name*: string
    token*: string
    team*: Team
    color*: uint8
    skin*: Skin
    hasTeam*: bool
    hasColor*: bool

  MapGenOverrides* = object
    ## Per-parameter locks for the terrain generator. Zero-value ("" / 0,
    ## windows -1) = unlocked, drawn from the map seed. Locking a parameter
    ## replaces its draw without shifting the other draws.
    size*: string          ## "small" | "standard" | "large"
    symmetry*: string      ## "mirror" | "rot180"
    columns*: int          ## obstacle column count per half, 3..8
    windows*: int          ## glass-window count per half, 0..6; -1 = draw
    centerFeature*: string ## "bracket" | "ring" | "walls"

  GameConfig* = object
    motionScale*: int
    accel*: int
    frictionNum*: int
    frictionDen*: int
    maxSpeed*: int
    stopThreshold*: int
    playerBouncePct*: int
    seed*: int
    speed*: int
    lives*: int
    hitPoints*: int
    respawnTicks*: int
    gunRange*: int
    fireCooldownTicks*: int
    fireWindupTicks*: int
    carrierSpeedPct*: int
    aimTurnRate*: int
    visionConeDeg*: int
    visionBubble*: int
    minPlayers*: int
    startWaitTicks*: int
    gameOverTicks*: int
    maxTicks*: int
    maxGames*: int
    showPlayerLabels*: bool
    fastMode*: bool           ## advance frames early when every player has
                              ## sent the Sprite v1 ready packet; pacing only,
                              ## never in gameHash.
    mapPath*: string
    mapSeed*: int             ## terrain seed for "gen"/"pool"; -1 = derive
                              ## from the game seed.
    mapPoolIndex*: int        ## explicit pool pick; -1 = mapSeed mod pool.
    mapGen*: MapGenOverrides
    mapSpec*: string          ## expanded map geometry JSON. Filled once at
                              ## config parse for generated maps and written
                              ## into replays, so playback reuses the EXACT
                              ## geometry and never re-runs the generator.
    closedRoster*: bool
    slots*: seq[PlayerSlotConfig]

  Player* = object
    x*, y*: int
    homeX*, homeY*: int
    velX*, velY*: int
    carryX*, carryY*: int
    flipH*: bool
    aimBrads*: int             ## aim angle in brads, 0..255: 0 = east (+x),
                               ## counter-clockwise on screen (64 = north).
    team*: Team
    alive*: bool
    lives*: int
    hp*: int                   ## remaining hit points this life.
    respawnTimer*: int
    fireCooldown*: int
    fireWindup*: int           ## ticks until a pulled trigger releases its shot.
    windupBrads*: int          ## aim angle locked at the trigger pull, -1 = none.
    carryingFlag*: bool
    hasGrenade*: bool          ## each player carries at most one grenade.
    hasShield*: bool           ## carrying an endzone shield: 3x slower fire.
    shieldHp*: int             ## remaining shield-layer hp (0..ShieldLayerHp);
                               ## damage depletes it before base hp.
    hasPlasmaArc*: bool        ## each player carries at most one plasma arc.
    arcTicksLeft*: int         ## remaining active ticks of a fired spray
                               ## cone (0 = the cone is off).
    arcHitMask*: uint32        ## players already damaged by the current
                               ## activation: one hit per victim per firing.
    throwCharge*: int          ## ticks the throw button has been held.
    lastShoutTick*: int        ## tick of this player's latest shout, -1 = never.
    paintHitTick*: int         ## tick of the latest PAINT hit taken. Every
                               ## weapon throws paint — gun, grenade, and the
                               ## spray can — so all three stamp it. Cosmetic:
                               ## drives the EYES-PiP visor paint splat; -1 =
                               ## never, never enters gameHash.
    joinOrder*: int
    address*: string
    color*: uint8
    skin*: Skin               ## cosmetic only; excluded from gameHash.
    reward*: int
    kills*: int
    deaths*: int
    captures*: int
    shotsFired*: int           ## shots this player released; analysis-only,
                               ## excluded from gameHash (see gameHash).
    shotsHit*: int             ## released shots that connected with an enemy;
                               ## analysis-only, excluded from gameHash.
    multiKills2*: int          ## grenade blasts / spray bursts that
                               ## killed exactly 2; analysis-only, excluded
                               ## from gameHash.
    multiKills3*: int          ## grenade blasts / spray bursts that
                               ## killed 3 or more; analysis-only, excluded
                               ## from gameHash.
    teamKills*: int            ## teammates this player killed (backstabs);
                               ## analysis-only, excluded from gameHash.
    arcKillsThisFire*: int     ## kills scored by the current spray
                               ## activation; transient multi-kill
                               ## bookkeeping, excluded from gameHash.

  PlayerFov* = object
    ## One player's cached fog-of-war visibility grid (FovGridW x FovGridH
    ## cells). Recomputed only when the viewer's cell or aim changes.
    valid*: bool
    originCx*, originCy*: int
    aimBrads*: int
    visible*: seq[bool]

  ShotFx* = object
    ## A cosmetic shot tracer segment; never enters gameHash (replay-safe).
    x0*, y0*, x1*, y1*: int
    firedTick*: int
    color*: uint8
    hit*: bool                 ## the shot connected with a player: its tracer
                               ## draws full-bright, a miss draws pre-faded.

  HitFlashFx* = object
    ## A cosmetic "target was struck" flash; never enters gameHash
    ## (replay-safe). The spectator view draws a brief bright ring over the
    ## victim (tracked by index, so the flash follows them) the instant a
    ## bullet connects — making hits legible at a glance where the tracer
    ## alone is ambiguous.
    playerIndex*: int          ## the struck player; players are only appended.
    tick*: int                 ## when the bullet connected.

  BubbleImpactFx* = object
    ## A cosmetic shield-bubble impact; never enters gameHash (replay-safe).
    ## When a bullet lands on a carrier whose bubble is still up, the bubble
    ## itself blinks and dents toward the shooter — replacing the struck-target
    ## ring and body paint spark, so the hit reads as absorbed by the shield.
    playerIndex*: int          ## the struck carrier; players are only appended.
    tick*: int                 ## when the bullet connected.
    angleBrads*: int           ## impact site: direction from the carrier's
                               ## center toward the shooter, in aim brads.

  SplatterFx* = object
    ## A cosmetic death splatter mark; never enters gameHash (replay-safe). A
    ## `hit` mark is the smaller, shorter-lived paint spark left by a non-fatal
    ## hit; a death mark (hit == false) is the larger, long-dwelling splatter.
    x*, y*: int
    tick*: int
    color*: uint8
    hit*: bool

  BlastFx* = object
    ## A cosmetic grenade blast flash; never enters gameHash (replay-safe).
    ## Landing is audible: views also derive their landing sound rings here.
    x*, y*: int
    tick*: int
    color*: uint8              ## the thrower's paint color, so the landing
                               ## splat reads as that team's paint-bomb.

  PlasmaArcFx* = object
    ## A cosmetic spray-cone paint flash; never enters gameHash (replay-safe).
    x*, y*: int
    aimBrads*: int
    tick*: int
    color*: uint8

  DamageFx* = object
    ## A cosmetic floating "-N" damage number that rises and fades above a
    ## player the instant they lose hit points; never enters gameHash
    ## (replay-safe). Makes each of the 3 health bars visibly tick down.
    x*, y*: int                ## where the hit landed (player center at hit).
    tick*: int                 ## when the hit landed.
    amount*: int               ## hit points lost (1 for a shot, GrenadeDamage).
    color*: uint8              ## the victim's team color, so it reads as their loss.
    kill*: bool                ## a fatal hit: drawn as a "KO" kill marker that
                               ## lives KillFxTicks instead of the "-N" number.

  SimEventKind* = enum
    ## Tier-2 analysis event channel (the Logs substrate). Every kind is
    ## emitted at the exact in-sim site where the fact is known first-hand
    ## (weapon, positions, attacker), so downstream never has to guess by
    ## counter-diffing. Analysis-only: never enters gameHash.
    Shot        ## a gun shot released (source = shooter).
    Hit         ## a released shot connected with an enemy on its ray.
    Damage      ## hit points removed (gun/spray/grenade), amount = hp lost.
    Kill        ## a CREDITED kill (mirrors recordKill; self-kills by own
                ## grenade are a Death without a Kill).
    Death       ## a player died (source = victim, target = killer).
    FlagSteal   ## a flag left its pedestal on an enemy's back.
    FlagReturn  ## a flag went home for any reason other than capture.
    Capture     ## a carrier scored the enemy flag.
    Respawn     ## a dead player came back at home.
    Heal        ## hit points restored (med kit or shield pickup).
    PhaseChange ## the game phase moved (lobby / playing / gameover):
                ## weapon = the new phase name, amount = its ordinal.
    GunTrigger  ## a player pulled the gun trigger and locked their aim.
    ShotImpact  ## a released shot ended at a player, wall, or range limit.
    GrenadeThrow
    GrenadeImpact
    SprayUse    ## one active spray-cone tick and the damage it dealt.
    Pickup      ## a player picked up an item; item names the pickup.
    ShoutEvent  ## a player shouted; content is the sanitized text.

  EventDamage* = object
    ## One victim damaged by a primary impact/use event.
    slot*: int
    amount*: int
    hp*: int
    blocked*: int

  SimEvent* = object
    ## One tier-2 analysis event; never enters gameHash (replay-safe).
    ## Collected only while collectEvents is on, so live servers pay nothing.
    tick*: int
    kind*: SimEventKind
    source*: int               ## acting player's stable join slot, -1 = n/a.
    target*: int               ## affected player's stable join slot, -1 = n/a.
    weapon*: string            ## "gun" / "spray" / "grenade", the new phase
                               ## name for PhaseChange, "" = n/a.
    amount*: int               ## hp delta for Damage/Kill/Heal, the new
                               ## phase ordinal for PhaseChange, else 0.
    hp*: int                   ## the affected player's remaining hit points
                               ## AFTER the event, floored at 0 (a fatal
                               ## overkill still reads 0): the victim on
                               ## Damage, the healed player on Heal.
                               ## -1 on every other kind (n/a).
    blocked*: int              ## on a Damage event, how many of `amount`'s hit
                               ## points the victim's SHIELD absorbed — i.e.
                               ## damage prevented from touching the base cog.
                               ## A shield carrier holds bonus hp above the base
                               ## HitPoints ceiling (only a shield pickup lifts a
                               ## cog there), so any of this hit that lands while
                               ## the victim is above base is shield-soaked. 0
                               ## when the victim held no shield hp, and on every
                               ## non-Damage kind (n/a).
    x*, y*: float              ## map position where the event happened.
    actionId*: int64           ## ties stages of one weapon action together.
    headingBrads*: int         ## native aim heading (0..255), -1 = n/a.
    distance*: float           ## throw/shot distance in map pixels.
    item*: string              ## pickup item name, "" = n/a.
    content*: string           ## sanitized shout content, "" = n/a.
    damages*: seq[EventDamage] ## victims damaged by this impact/use.

  Shout* = object
    ## One short player message, audible within ShoutRange of where it was
    ## made. Bots observe shouts, so they are gameplay state (in gameHash)
    ## and replays re-apply the recorded chat records that produced them.
    address*: string           ## the shouter, by player address.
    team*: Team
    text*: string              ## sanitized, at most ShoutMaxChars.
    tick*: int                 ## when it was shouted.
    x*, y*: int                ## shouter center at shout time.

  PickupSpawn* = object
    ## One fixed pickup point: corner grenades and center med kits.
    x*, y*: int
    present*: bool
    respawnAt*: int            ## tick the pickup refills (when not present).

  AirborneGrenade* = object
    ## One thrown grenade in flight: it flies OVER walls in a straight line
    ## from the throw point to the target and explodes on landing.
    sx*, sy*: int
    tx*, ty*: int
    launchTick*: int
    flightTicks*: int
    thrower*: int              ## live index retained for replay-hash compatibility.
    throwerSlot*: int          ## immutable analysis identity; never hashed.
    throwerAccount*: int       ## stable results account; never hashed.

  FlagState* = object
    ## One team's flag: provably either sitting on its home pedestal
    ## (carrier == -1) or carried by an enemy player (never loose).
    x*, y*: int
    carrier*: int              ## player index carrying this flag, -1 when home.

  SimServer* = object
    config*: GameConfig
    players*: seq[Player]
    rewardAccounts*: seq[RewardAccount]
    crewSprites*: seq[CrewSprite]
    flagSprite*: Sprite
    gameMap*: CtfMap
    rooms*: seq[Room]
    flags*: array[Team, FlagState]  ## per-team flags on the home pedestals.
    mapPixels*: seq[uint8]
    mapRgba*: seq[uint8]
    darkBgPixels*: seq[uint8]
    walkMask*: seq[bool]
    wallMask*: seq[bool]
    fovBlocked*: seq[bool]     ## FovGridW x FovGridH; a cell is opaque when mostly wall.
    fovCaches: seq[PlayerFov]
    rng*: Rand
    nextJoinOrder*: int
    tickCount*: int
    recentShots*: seq[ShotFx]  ## cosmetic shot tracers; excluded from gameHash.
    hitFlashes*: seq[HitFlashFx]  ## cosmetic struck-target flashes; excluded from gameHash.
    bubbleImpacts*: seq[BubbleImpactFx]  ## cosmetic shield-bubble impact blinks; excluded from gameHash.
    splatters*: seq[SplatterFx]  ## cosmetic death splatters; excluded from gameHash.
    recentBlasts*: seq[BlastFx]  ## cosmetic grenade blasts; excluded from gameHash.
    damagePops*: seq[DamageFx]  ## cosmetic floating "-N" damage numbers; excluded from gameHash.
    recentShouts*: seq[Shout]  ## live shouts; observable state, in gameHash.
    grenadeSpawns*: array[4, PickupSpawn]
    medKitSpawns*: array[2, PickupSpawn]
    shieldSpawns*: array[2, PickupSpawn]  ## one shield per team endzone.
    plasmaArcSpawns*: array[2, PickupSpawn]
    airborneGrenades*: seq[AirborneGrenade]
    plasmaArcFlashes*: seq[PlasmaArcFx]
    gameStartTick*: int
    startWaitTimer*: int
    phase*: GamePhase
    asciiSprites*: PixelFont
    shoutFont*: PixelFont  ## chunky 9px grid font used only for shout bubbles.
    winner*: Team
    gameOverTimer*: int
    timeLimitReached*: bool
    overtimeTicks*: int        ## clock extension banked by the action floor
                               ## (kills / heart steals); resets each game.
    isDraw*: bool
    needsReregister*: bool
    gameEventLoggingEnabled*: bool
    collectEvents*: bool       ## tier-2 event sink switch; default off so
                               ## live servers pay nothing (see SimEvent).
    events*: seq[SimEvent]     ## collected tier-2 events; the extractor
                               ## drains this every tick. Never in gameHash.
    lastLobbyPlayersLogged*: int
    lastLobbyNeededLogged*: int
    lastLobbySecondsLogged*: int

proc gameDir*(): string =
  ## Returns the CTF game directory.
  getCurrentDir()

proc clientDataDir*(): string =
  ## Returns the shared client data directory.
  when defined(emscripten):
    gameDir() / "data"
  else:
    bitworldClient.clientDir() / "data"

proc spriteSheetPath(): string =
  ## Returns the sprite sheet aseprite path.
  gameDir() / SpriteSheetAsepritePath

proc loadSpriteSheet*(): Image =
  ## Loads the sprite sheet from aseprite.
  readAsepriteImage(spriteSheetPath())

proc crewSheetPath(): string =
  ## Returns the crew sprite sheet path. A hand-pixeled crew.png (the
  ## purpose-built tactical soldier) is preferred; the legacy crew.aseprite is
  ## the fallback so an art rollback needs no code change.
  for candidate in [
    gameDir() / "data" / "crew.png",
    clientDataDir() / "crew.png",
    clientDataDir() / "crew.aseprite",
    gameDir() / "data" / "crew.aseprite",
  ]:
    if fileExists(candidate):
      return candidate
  gameDir() / "data" / "crew.aseprite"

proc readCrewSheetImage(path: string): Image =
  ## Reads the crew sheet as a Pixie image from either a PNG or an aseprite
  ## file (both render to the same RGBA Image the crew tint path consumes).
  if path.toLowerAscii.endsWith(".png"):
    readImage(path)
  else:
    readAsepriteImage(path)

proc crewSpriteOffset*(sprite: CrewSprite, x, y: int): int =
  ## Returns the RGBA byte offset for one crew sprite pixel.
  (y * sprite.width + x) * 4

proc crewPixelIsTint*(r, g, b, a: uint8): bool =
  ## Returns true when one crew source pixel is pure tint white.
  a >= 20'u8 and r == 255'u8 and g == 255'u8 and b == 255'u8

proc crewPixelIsShade*(r, g, b, a: uint8): bool =
  ## Returns true when one crew source pixel is the darker tint marker.
  a >= 20'u8 and r == 0x9b'u8 and g == 0xad'u8 and b == 0xb7'u8

proc crewSpriteFromImage(image: Image, index, row: int): CrewSprite =
  ## Extracts one raw 16x16 crew sprite from one sheet row.
  result = CrewSprite(
    width: CrewSpriteSize,
    height: CrewSpriteSize,
    rgba: newSeq[uint8](CrewSpriteSize * CrewSpriteSize * 4)
  )
  let
    baseX = index * CrewSpriteSize
    baseY = row * CrewSpriteSize
  for y in 0 ..< CrewSpriteSize:
    for x in 0 ..< CrewSpriteSize:
      let
        pixel = image[baseX + x, baseY + y]
        offset = result.crewSpriteOffset(x, y)
      result.rgba[offset] = pixel.r
      result.rgba[offset + 1] = pixel.g
      result.rgba[offset + 2] = pixel.b
      result.rgba[offset + 3] = pixel.a

proc loadCrewSpriteRow*(row: int, label: string): seq[CrewSprite] =
  ## Loads eight 16x16 crew sprites from one sheet row.
  if row < 0:
    raise newException(CtfError, "Crew sprite sheet row is negative.")
  let
    path = crewSheetPath()
    image = readCrewSheetImage(path)
  if image.width < CrewSpriteSize * CrewSpriteVariants or
      image.height < CrewSpriteSize * (row + 1):
    raise newException(
      CtfError,
      label & " sprite sheet row is missing eight 16x16 sprites: " & path
    )
  for i in 0 ..< CrewSpriteVariants:
    result.add(image.crewSpriteFromImage(i, row))

proc loadCrewSprites*(): seq[CrewSprite] =
  ## Loads the first eight 16x16 living crew sprites.
  loadCrewSpriteRow(0, "Crew")

proc loadRgbaSprite*(name: string, size: int, alphaCutoff = 0'u8): seq[uint8] =
  ## Loads a hand-painted relic PNG from data/ and returns it as a straight-alpha
  ## RGBA buffer scaled to size×size for the Sprite v1 protocol. The PNGs carry
  ## real transparency (alpha-knocked from the art), and pixie stores
  ## premultiplied alpha internally, so we take `.rgba` to hand the protocol
  ## un-premultiplied colors.
  ##
  ## `alphaCutoff` > 0 snaps the resized alpha to a HARD edge (>= cutoff opaque,
  ## else fully clear). Pixie's `resize` is bilinear, so downscaling a big PNG
  ## feathers its bold dark outline into a ring of semi-transparent pixels that
  ## reads as a fuzzy colored halo bleeding onto the floor. Snapping the alpha
  ## keeps the SAME art but restores the crisp outline; the interior facets are
  ## untouched (they were already fully opaque). 128 is the sweet spot at both
  ## the carried (20px) and planted (60px) footprints.
  let image = readImage(gameDir() / name).resize(size, size)
  result = newSeq[uint8](size * size * 4)
  for y in 0 ..< size:
    for x in 0 ..< size:
      let
        pixel = image[x, y].rgba
        offset = (y * size + x) * 4
        alpha = if alphaCutoff == 0'u8: pixel.a
                elif pixel.a >= alphaCutoff: 255'u8
                else: 0'u8
      result[offset] = pixel.r
      result[offset + 1] = pixel.g
      result[offset + 2] = pixel.b
      result[offset + 3] = alpha

proc loadHeartSprite*(team: Team, size: int): seq[uint8] =
  ## The CTF objective, a glowing team-colored heart-gem relic (0.7.0 renamed the
  ## "flag" a heart in-sim). Red = crimson life-crystal, Blue = frost life-crystal.
  ## Hard alpha edge (cutoff 128) so the bold painted outline stays crisp at the
  ## sprite footprint instead of feathering into a fuzzy halo on the floor.
  loadRgbaSprite(
    if team == Red: "data/heart_red.png" else: "data/heart_blue.png",
    size,
    alphaCutoff = 128'u8
  )

proc loadMedKitSprite*(size: int): seq[uint8] =
  ## The center-field healing pickup: a chunky white healer's kit with a red
  ## cross, matching the bold-outline painted item style (heart gem, paint
  ## bomb). Hard alpha edge keeps the outline crisp on the floor.
  loadRgbaSprite("data/medkit.png", size, alphaCutoff = 128'u8)

proc loadShieldSprite*(size: int): seq[uint8] =
  ## The endzone protective pickup: a chunky bold-outline heater shield in the
  ## same painted-item style as the med kit and paint bomb. Hard alpha edge
  ## keeps the outline crisp on the floor.
  loadRgbaSprite("data/shield.png", size, alphaCutoff = 128'u8)

proc loadPaintBombSprite*(size: int): seq[uint8] =
  ## The thrown grenade, a kid-friendly dungeon-crawler alchemical paint-bomb orb
  ## (cork-stopped rune bottle of swirling paint — NO fuse). Used for the corner
  ## pickup, the carried icon, and the in-flight projectile.
  loadRgbaSprite("data/paintbomb.png", size)

proc loadSprayCanSprite*(size: int): seq[uint8] =
  ## The side-column cone weapon: a chunky aerosol spray-paint can, in the same
  ## bold-outline painted style as the med kit, shield, and paint bomb (this is
  ## paintball — the short-range weapon sprays paint, it does not fire plasma).
  ## Used for the floor pickup and the carried marker. Hard alpha edge keeps the
  ## ink outline crisp on the floor instead of feathering into a halo.
  loadRgbaSprite("data/spraycan.png", size, alphaCutoff = 128'u8)

## --- HD top-down soldier: CvC cog + gun, rotated as one rigid unit ---
## Each team's master (soldier_red/blue.png) is the canonical Cogs-vs-Clips cog
## facing SOUTH, smile visor visible, used exactly as drawn. It is measured for
## its body pivot (solid-pixel centroid) and scaled so the body fills
## SoldierBodyPx. The shared gun master (paintgun.png: muzzle east, barrel
## centerline at image mid-height) mounts GunGripPx east of the body center
## with its barrel on the aim ray, and body + gun pre-rotate TOGETHER around
## the body center — the cog spins with its gun, so east aim (rot 0) shows the
## master exactly as drawn and tracers always line up with the muzzle.
const SoldierMasterPaths: array[Skin, array[Team, string]] = [
  DefaultSkin: [
    Red: "data/soldier_red.png",
    Blue: "data/soldier_blue.png"
  ],
  CrownSkin: [
    Red: "data/soldier_red_crown.png",
    Blue: "data/soldier_blue_crown.png"
  ]
]

var
  soldierMasters: array[Skin, array[Team, Image]]
  soldierPivotX, soldierPivotY: array[Skin, array[Team, float]]
  soldierScale: array[Skin, array[Team, float]]
  soldierLoaded: array[Skin, array[Team, bool]]
  soldierRotCache: array[
    Skin,
    array[Team, array[SoldierRotations, seq[tuple[
      scale: int, pixels: seq[uint8]
    ]]]]
  ]
  gunMaster: Image
  gunScale: float
  gunLoaded: bool
  sprayMaster: Image
  sprayScale: float
  sprayLoaded: bool

proc measureSoldierBody(skin: Skin, team: Team, master: Image) =
  ## Finds the body pivot and the master->canvas scale: the centroid and
  ## vertical span of the SOLID pixels (alpha >= 200 — the cog shell; the
  ## baked-in soft drop shadow sits below that and is excluded, so the cog
  ## itself, not its shadow, is what centers and fills SoldierBodyPx).
  var
    sumX = 0.0
    sumY = 0.0
    n = 0
    top = master.height
    bot = -1
  for y in 0 ..< master.height:
    for x in 0 ..< master.width:
      if master.data[y * master.width + x].a >= 200:
        sumX += float(x); sumY += float(y); inc n
        top = min(top, y); bot = max(bot, y)
  if n == 0:
    soldierPivotX[skin][team] = float(master.width) / 2
    soldierPivotY[skin][team] = float(master.height) / 2
    soldierScale[skin][team] =
      float(SoldierBodyPx) / max(1.0, float(master.height))
  else:
    soldierPivotX[skin][team] = sumX / float(n)
    soldierPivotY[skin][team] = sumY / float(n)
    soldierScale[skin][team] =
      float(SoldierBodyPx) / max(1.0, float(bot - top + 1))

proc ensureSoldierLoaded(skin: Skin, team: Team) =
  if soldierLoaded[skin][team]:
    return
  let master = readImage(gameDir() / SoldierMasterPaths[skin][team])
  soldierMasters[skin][team] = master
  measureSoldierBody(skin, team, master)
  soldierLoaded[skin][team] = true

proc ensureGunLoaded() =
  if gunLoaded:
    return
  # Top-down paintball marker, muzzle east, barrel on the image mid-line. Scaled
  # by WIDTH so GunLengthPx spans the full stock-to-muzzle length along the aim.
  gunMaster = readImage(gameDir() / "data/paintgun_topdown.png")
  gunScale = float(GunLengthPx) / max(1.0, float(gunMaster.width))
  gunLoaded = true

proc ensureSprayLoaded() =
  if sprayLoaded:
    return
  # The held spray can: same convention as the gun master (nozzle EAST, body on
  # the image mid-line) so the identical grip math mounts it. Scaled to
  # SprayHeldLengthPx — a can is a short fistful, not a long marker.
  sprayMaster = readImage(gameDir() / "data/spraycan_held.png")
  sprayScale = float(SprayHeldLengthPx) / max(1.0, float(sprayMaster.width))
  sprayLoaded = true

proc soldierRotPixels*(
  team: Team,
  skin: Skin,
  rot: int,
  renderScale = 1
): seq[uint8] =
  ## One pre-rendered soldier sprite (SoldierCanvas·renderScale square,
  ## straight-alpha RGBA): body + gun as one rigid unit, rotated to aim step
  ## `rot`. The master's FACE side (south) leads the aim with the gun held in
  ## front of it — aiming south shows the master exactly as drawn. The masters
  ## are ~120px art rendered down to a 34px body at 1×, so a renderScale > 1
  ## raster recovers genuine painted detail, not upscaled blocks.
  let r = ((rot mod SoldierRotations) + SoldierRotations) mod SoldierRotations
  for cached in soldierRotCache[skin][team][r]:
    if cached.scale == renderScale:
      return cached.pixels
  ensureSoldierLoaded(skin, team)
  ensureGunLoaded()
  let
    master = soldierMasters[skin][team]
    outCanvas = SoldierCanvas * renderScale
    # aim increases counter-clockwise on screen (0=east, 64=north); screen y is
    # down, so a positive brad step rotates the art clockwise in image space —
    # i.e. draw at angle -theta to match aimVector.
    angle = float(r) * 2.0 * PI / float(SoldierRotations)
    s = soldierScale[skin][team] * float(renderScale)
    center = float32(outCanvas) / 2
  var canvas = newImage(outCanvas, outCanvas)
  let
    unitRot =
      translate(vec2(center, center)) *
      rotate(float32(-angle))
    # Unit space: +x = aim. The extra -90° turns the master so its SOUTH side
    # (the smile visor) points along +x — the face leads the aim, right behind
    # the gun.
    bodyMat =
      unitRot *
      rotate(float32(-PI / 2)) *
      scale(vec2(float32(s), float32(s))) *
      translate(
        vec2(
          float32(-soldierPivotX[skin][team]),
          float32(-soldierPivotY[skin][team])
        )
      )
    # Gun-local (0, height/2) — the stock end of the barrel centerline — mounts
    # GunGripPx along the aim (stock behind the hub, barrel reaching out front)
    # and GunRightPx off the aim ray to the cog's RIGHT (+y = right when facing
    # +x/east); it spins with the unit so the marker rides the head's right.
    gunMat =
      unitRot *
      translate(vec2(
        float32(GunGripPx * renderScale), float32(GunRightPx * renderScale))) *
      scale(vec2(
        float32(gunScale * float(renderScale)),
        float32(gunScale * float(renderScale))
      )) *
      translate(vec2(0, float32(-gunMaster.height) / 2))
  canvas.draw(master, bodyMat)
  canvas.draw(gunMaster, gunMat)
  # Straight-alpha RGBA for the Sprite v1 protocol (pixie stores premultiplied).
  var pixels = newSeq[uint8](outCanvas * outCanvas * 4)
  for i in 0 ..< outCanvas * outCanvas:
    let c = canvas.data[i].rgba()
    pixels[i * 4] = c.r
    pixels[i * 4 + 1] = c.g
    pixels[i * 4 + 2] = c.b
    pixels[i * 4 + 3] = c.a
  soldierRotCache[skin][team][r].add((scale: renderScale, pixels: pixels))
  pixels

proc soldierRotIndex*(aimBrads: int): int =
  ## Quantizes an aim angle to the nearest pre-rotated sprite step.
  ((aimBrads + AimBradsTurn div (SoldierRotations * 2)) *
    SoldierRotations div AimBradsTurn) mod SoldierRotations

## --- Articulated TURRET rig: the REAL CvC cog, segmented (broadcast board only) ---
## The SAME real master art as soldierRotPixels, SLICED (scripts/art/build_cvc_rig.py)
## into 9 pieces that recompose to the south master at rest but articulate like a
## tank trike when moving:
##   head  - cube + cyan visor + center pistons + the held GUN. Faces AIM. Drawn
##           LAST so it covers the hub/leg-joins (no head-hole).
##   armL/R- the two shoulder assemblies. Face AIM. TUCKED at rest; reach FORWARD
##           to cradle the carried heart only while carrying (carry-gated caller).
##   legFL/FR/Rear - the three leg struts (tire removed). Face the MOVEMENT heading
##           (CogDriveState.bodyHeading), each hinged about its own hip with a
##           differential turn swing; the INNER leg SHORTENS into a turn.
##   wheelL/R/Rear - the three tires, cut out of the legs, each CASTERING (rotating
##           about its axle) toward the roll direction, capped so a tall top-down
##           tire only tilts to hint the turn (never swings fully broadside).
## The head/arms track AIM while the legs/wheels track MOVEMENT — a true turret
## swivel. All broadcast-only (no sim state, no GameVersion bump); POV keeps the
## unified soldierRotPixels sprite.
##
## Every segment is baked in the SAME 192px master frame space through ONE code
## path (rigSegPixels): rotate the segment about its ANCHOR by a base angle (aim
## for head/arms, bodyHeading for legs/wheels) plus an articulation, then place the
## HUB on the player. At rest everything rotates by the same aim delta about anchors
## that ARE its master pixels, so the composite == the south master.
type
  RigSeg* = enum
    rsHead, rsArmL, rsArmR, rsLegFL, rsLegFR, rsLegRear,
    rsWheelL, rsWheelR, rsWheelRear

const
  RigSegCount* = 9
  RigCanvas* = 96             ## px square rig segment canvas at 1x (fits the
                              ## swung legs + castered wheels + reaching arms).
  # Anchors in 192px master-frame space (scripts/art/build_cvc_rig.py anchors.json).
  RigHub: tuple[x, y: float] = (96.0, 88.0)   ## cog rotation center (head-cube
                              ## center); head, arms and leg-hips all measured here.
  RigAnchor: array[RigSeg, tuple[x, y: float]] = [
    (96.0, 88.0),     # rsHead      (== hub; head rotates about the hub to aim)
    (70.0, 84.0),     # rsArmL      left shoulder attach
    (120.0, 84.0),    # rsArmR      right shoulder attach
    (72.0, 100.0),    # rsLegFL     left front hip
    (120.0, 100.0),   # rsLegFR     right front hip
    (96.0, 80.0),     # rsLegRear   rear hip — flipped 180° about hub to the BACK
    # Wheels caster about their TIRE CENTROID (measured), not the axle at the top —
    # pivoting mid-tire spins the wheel in place, not swinging the tire body out.
    (73.5, 134.0),    # rsWheelL    left front tire centroid
    (117.3, 132.7),   # rsWheelR    right front tire centroid
    (94.7, 48.3)]     # rsWheelRear rear tire centroid — flipped 180° to the BACK
  # Articulation feel (degrees). Legs differential-steer: rest tuck ± splay on the
  # turn signal; the INNER leg shortens instead of splaying wide.
  RigRestTuckDeg = 2.0
  RigSplayDeg = 5.0           ## outer leg barely swings — the inner-leg SHORTEN +
                              ## wheel caster carry the turn read; a big swing on
                              ## the far leg reads as a splayed spider strut.
  RigRearCounterFrac = 0.3    ## rear leg counter-swings this fraction of splay.
  RigInnerShorten = 0.34      ## inner leg shrinks up to this fraction on a turn.
  RigArmReachDeg = 22.0       ## arms swing forward this far to cradle a carried
                              ## heart (art step 1); 0 at rest (tucked shoulders).
  RigShortenSteps* = 4        ## baked leg-length steps (0 = full .. this = shortest).
  RigSteps* = 16              ## baked steps per rotating quantity (aim / heading).
  RigLegSwingSteps* = 16      ## baked leg swing steps across the full turn range.
  # Wheel caster: capped TIGHT so a tall top-down tire only tilts to hint the roll
  # direction. Expressed in brads (AimBradsTurn=256): 16 brads ≈ 22°.
  RigCasterMaxBrads* = 16
  RigCasterSteps* = 8         ## baked caster tilt steps across ±RigCasterMaxBrads.

var
  rigLoaded: array[Team, bool]
  rigSegImg: array[Team, array[RigSeg, Image]]
  rigScale: array[Team, float]   ## master-frame px -> map px (body fills body px).
  # Bake cache keyed by (baseStep, artStep, shortenStep, scale). baseStep is the
  # aim step (head/arms) or heading step (legs/wheels); artStep is the leg swing or
  # wheel caster; shortenStep is the leg-length index (0 for non-legs).
  rigSegCache: array[Team, array[RigSeg, seq[tuple[
    baseStep, artStep, shortenStep, scale: int, pixels: seq[uint8]]]]]

proc rigSegPath(seg: RigSeg): string =
  case seg
  of rsHead: "head"
  of rsArmL: "arm_l"
  of rsArmR: "arm_r"
  of rsLegFL: "leg_fl"
  of rsLegFR: "leg_fr"
  of rsLegRear: "leg_rear"
  of rsWheelL: "wheel_l"
  of rsWheelR: "wheel_r"
  of rsWheelRear: "wheel_rear"

proc rigSegIsLeg(seg: RigSeg): bool =
  seg in {rsLegFL, rsLegFR, rsLegRear}

proc rigSegIsWheel(seg: RigSeg): bool =
  seg in {rsWheelL, rsWheelR, rsWheelRear}

proc ensureRigLoaded(team: Team) =
  if rigLoaded[team]:
    return
  let dir = gameDir() / "data/rig_real" / (if team == Red: "red" else: "blue")
  for seg in RigSeg:
    rigSegImg[team][seg] = readImage(dir / rigSegPath(seg) & ".png")
  # Scale the rig so its body matches the unified soldier footprint. The solid
  # body spans ~99px in the 192px frame (y56..154); map that to SoldierBodyPx.
  ensureSoldierLoaded(DefaultSkin, team)
  rigScale[team] = float(SoldierBodyPx) / 99.0
  rigLoaded[team] = true

proc soldierCanvasToPixels(canvas: Image): seq[uint8] =
  ## Straight-alpha RGBA (Sprite v1 protocol) from a pixie canvas.
  result = newSeq[uint8](canvas.width * canvas.height * 4)
  for i in 0 ..< canvas.width * canvas.height:
    let c = canvas.data[i].rgba()
    result[i * 4] = c.r
    result[i * 4 + 1] = c.g
    result[i * 4 + 2] = c.b
    result[i * 4 + 3] = c.a

proc rigSegPixels*(team: Team, seg: RigSeg, baseStep, artStep: int,
    shortenStep = 0, renderScale = 1): seq[uint8] =
  ## One rig segment baked into a RigCanvas sprite, HUB-centered.
  ##  - baseStep: the segment's base rotation step (RigSteps) — the AIM step for
  ##    the head/arms, the movement-HEADING step for legs/wheels. This IS the
  ##    turret swivel: head/arms and legs get DIFFERENT baseSteps.
  ##  - artStep: leg differential swing (signed, RigLegSwingSteps) or wheel caster
  ##    tilt (signed, RigCasterSteps); ignored for the head.
  ##  - shortenStep: leg-length index 0..RigShortenSteps (legs only; inner-leg
  ##    shorten). 0 for everything else.
  ## Each segment rotates about its ANCHOR by baseDeg + articulation, then the HUB
  ## lands at canvas center — so at rest (all baseSteps equal, art 0) the segments
  ## recompose to the south master exactly.
  let
    b = ((baseStep mod RigSteps) + RigSteps) mod RigSteps
    art = artStep
    sh = clamp(shortenStep, 0, RigShortenSteps)
  for cached in rigSegCache[team][seg]:
    if cached.baseStep == b and cached.artStep == art and
        cached.shortenStep == sh and cached.scale == renderScale:
      return cached.pixels
  ensureRigLoaded(team)
  let
    outCanvas = RigCanvas * renderScale
    img = rigSegImg[team][seg]
    s = rigScale[team] * float(renderScale)
    center = float32(outCanvas) / 2
    anchor = RigAnchor[seg]
    hub = RigHub
    # base delta: rot 0 = east; the master faces SOUTH so the −90° turn makes the
    # face lead the base direction. Angle increases CCW; screen y down → rotate −.
    baseAngle = float(b) * 2.0 * PI / float(RigSteps)
    baseDeg = -baseAngle - PI / 2.0
    # The gun mounts in PURE aim space (no −90° — the master-south turn is only for
    # the body art), like soldierRotPixels: unitRot = rotate(−aimAngle).
    unitDeg = -baseAngle
  # Articulation about the segment's own anchor (radians, screen CCW+).
  var artDeg = 0.0
  if rigSegIsLeg(seg):
    let sw = float(art) / float(RigLegSwingSteps) * RigSplayDeg  # signed swing
    case seg
    of rsLegFL:  artDeg = (-RigRestTuckDeg + sw) * PI / 180.0
    of rsLegFR:  artDeg = ( RigRestTuckDeg + sw) * PI / 180.0
    of rsLegRear: artDeg = (sw * RigRearCounterFrac) * PI / 180.0
    else: discard
  elif rigSegIsWheel(seg):
    # caster tilt: art is the signed caster step; convert to a small angle.
    let tilt = float(art) / float(RigCasterSteps) *
      (float(RigCasterMaxBrads) * 2.0 * PI / float(AimBradsTurn))
    artDeg = -tilt
  elif seg in {rsArmL, rsArmR}:
    # Arms: art 0 = tucked (rest); art 1 = REACHING forward to cradle a carried
    # heart. The reach swings each shoulder inward-and-forward about its attach so
    # the two arms close in front of the aim (where the heart rides).
    if art != 0:
      artDeg = (if seg == rsArmL: RigArmReachDeg else: -RigArmReachDeg) *
        PI / 180.0
  # Leg-length shorten: scale the leg toward its hip along the hip→foot (down)
  # axis. The leg art hangs below its hip anchor, so scaling y about the anchor
  # pulls the foot (and its wheel, placed separately) up toward the hip.
  let shortenF = 1.0 - float(sh) / float(RigShortenSteps) * RigInnerShorten
  var canvas = newImage(outCanvas, outCanvas)
  let
    toCenter = translate(vec2(center, center))
    baseRot = rotate(float32(baseDeg))
    scl = scale(vec2(float32(s), float32(s)))
    hubToOrigin = translate(vec2(float32(-hub.x), float32(-hub.y)))
    artMat =
      translate(vec2(float32(anchor.x), float32(anchor.y))) *
      rotate(float32(artDeg)) *
      scale(vec2(1.0'f32, float32(shortenF))) *
      translate(vec2(float32(-anchor.x), float32(-anchor.y)))
    mat = toCenter * baseRot * scl * hubToOrigin * artMat
  # NB: the held gun is NO LONGER baked into the head — it is its own board object
  # (rigGunPixels), drawn ABOVE the head with a backlight glow so it reads clearly
  # and can be gated off if a cog is ever disarmed. The head is a clean turret.
  canvas.draw(img, mat)
  let pixels = soldierCanvasToPixels(canvas)
  rigSegCache[team][seg].add(
    (baseStep: b, artStep: art, shortenStep: sh, scale: renderScale,
     pixels: pixels))
  pixels

var rigGunCache: array[Team, seq[tuple[aimStep, scale: int, pixels: seq[uint8]]]]

proc rigGunPixels*(team: Team, aimStep: int, renderScale = 1): seq[uint8] =
  ## The held top-down paintball MARKER as its OWN HUB-centered rig object (not
  ## baked into the head): mounted at the cog's RIGHT (GunRightPx off the aim ray,
  ## stock GunGripPx along aim), barrel on +aim so tracers line up. A soft warm
  ## backlight glow is composited BEHIND the marker so the dark gun pops off the
  ## dark floor/legs. Team-independent shape, but cached per team for symmetry with
  ## the other rig segments. Emitted ABOVE the head z; gate the caller on a
  ## `hasGun` flag to hide it when a cog is disarmed.
  let a = ((aimStep mod RigSteps) + RigSteps) mod RigSteps
  for cached in rigGunCache[team]:
    if cached.aimStep == a and cached.scale == renderScale:
      return cached.pixels
  ensureGunLoaded()
  let
    outCanvas = RigCanvas * renderScale
    center = float32(outCanvas) / 2
    baseAngle = float(a) * 2.0 * PI / float(RigSteps)
    unitDeg = -baseAngle                 # pure aim space (muzzle on +aim)
    gs = gunScale * float(renderScale)
    gunMat =
      translate(vec2(center, center)) * rotate(float32(unitDeg)) *
      translate(vec2(
        float32(GunGripPx * renderScale), float32(GunRightPx * renderScale))) *
      scale(vec2(float32(gs), float32(gs))) *
      translate(vec2(0'f32, float32(-gunMaster.height) / 2))
  # 1) lay the gun on a transparent canvas, 2) build a warm-amber backlight from
  # its silhouette (spread + blur), 3) draw glow THEN gun on the output.
  var gunLayer = newImage(outCanvas, outCanvas)
  gunLayer.draw(gunMaster, gunMat)
  let glow = gunLayer.shadow(
    offset = vec2(0, 0),
    spread = float32(GunGlowSpread * float(renderScale)),
    blur = float32(GunGlowRadius * float(renderScale)),
    color = rgba(255, 214, 138, GunGlowAlpha).color)  # faint warm rim light
  var canvas = newImage(outCanvas, outCanvas)
  canvas.draw(glow)                            # subtle warm edge behind the marker
  canvas.draw(gunLayer)
  let pixels = soldierCanvasToPixels(canvas)
  rigGunCache[team].add((aimStep: a, scale: renderScale, pixels: pixels))
  pixels

var rigSprayCache: array[Team, seq[tuple[aimStep, scale: int, pixels: seq[uint8]]]]

proc rigSprayCanPixels*(team: Team, aimStep: int, renderScale = 1): seq[uint8] =
  ## The held SPRAY CAN, the swap-in for rigGunPixels while a cog carries one:
  ## same grip (the cog's RIGHT, GunRightPx off the aim ray) and the same
  ## nozzle-on-+aim convention, so the spray cone leaves the nozzle exactly where
  ## tracers leave the muzzle. Mounted SprayHeldGripPx along aim and scaled to
  ## SprayHeldLengthPx: a can is a short fistful, so its silhouette reads clearly
  ## different from the long marker — that difference is how a viewer tells which
  ## weapon a cog is holding.
  let a = ((aimStep mod RigSteps) + RigSteps) mod RigSteps
  for cached in rigSprayCache[team]:
    if cached.aimStep == a and cached.scale == renderScale:
      return cached.pixels
  ensureSprayLoaded()
  let
    outCanvas = RigCanvas * renderScale
    center = float32(outCanvas) / 2
    baseAngle = float(a) * 2.0 * PI / float(RigSteps)
    unitDeg = -baseAngle                 # pure aim space (nozzle on +aim)
    ss = sprayScale * float(renderScale)
    canMat =
      translate(vec2(center, center)) * rotate(float32(unitDeg)) *
      translate(vec2(
        float32(SprayHeldGripPx * renderScale),
        float32(GunRightPx * renderScale))) *
      scale(vec2(float32(ss), float32(ss))) *
      translate(vec2(0'f32, float32(-sprayMaster.height) / 2))
  # Same three-step composite as the marker: can, warm backlight from its
  # silhouette, then glow-under-can — so it pops off the dark floor identically.
  var canLayer = newImage(outCanvas, outCanvas)
  canLayer.draw(sprayMaster, canMat)
  let glow = canLayer.shadow(
    offset = vec2(0, 0),
    spread = float32(GunGlowSpread * float(renderScale)),
    blur = float32(GunGlowRadius * float(renderScale)),
    color = rgba(255, 214, 138, GunGlowAlpha).color)
  var canvas = newImage(outCanvas, outCanvas)
  canvas.draw(glow)
  canvas.draw(canLayer)
  let pixels = soldierCanvasToPixels(canvas)
  rigSprayCache[team].add((aimStep: a, scale: renderScale, pixels: pixels))
  pixels

proc soldierIconPixels*(team: Team, sizePx: int): seq[uint8] =
  ## A compact roster chip: the face-on cog scaled so the body fills the icon
  ## (no gun — the smile visor IS the identity). Used by the game-over list.
  ensureSoldierLoaded(DefaultSkin, team)
  let
    master = soldierMasters[DefaultSkin][team]
    s =
      float(sizePx) / float(SoldierBodyPx) *
        soldierScale[DefaultSkin][team]
  var canvas = newImage(sizePx, sizePx)
  let mat =
    translate(vec2(float32(sizePx) / 2, float32(sizePx) / 2)) *
    scale(vec2(float32(s), float32(s))) *
    translate(vec2(
      float32(-soldierPivotX[DefaultSkin][team]),
      float32(-soldierPivotY[DefaultSkin][team])
    ))
  canvas.draw(master, mat)
  result = newSeq[uint8](sizePx * sizePx * 4)
  for i in 0 ..< sizePx * sizePx:
    let c = canvas.data[i].rgba()
    result[i * 4] = c.r
    result[i * 4 + 1] = c.g
    result[i * 4 + 2] = c.b
    result[i * 4 + 3] = c.a

proc bradsOfVector*(dx, dy: int): int   ## fwd decl (defined near aimVector below).

## --- Cog driving physics: how the segmented trike steers/turns (broadcast-only) ---
## Ports the Maxwell-approved CogDriveState model (from maxwell/cog-base-turret-
## split): the body heading eases slowly toward travel; each wheel casters toward
## its foot's travel direction near-instantly (so tyres never scrape); the leg
## splay follows a smoothed turn signal. Everything derives from the already-known
## velocity, so it stays broadcast-only and replay-deterministic.
const
  CogBodyTurnRate* = 28       ## max brads/frame the body heading eases toward the
                              ## travel direction — the base is a TRUE TANK track
                              ## that snaps to where it rolls (fast + accurate),
                              ## fully independent of the head/aim.
  CogWheelTurnRate* = 48      ## brads/frame a wheel casters toward travel (even
                              ## faster than the base, so tyres never scrape).
  CogReverseMaxBrads* = 112   ## |heading-travel| beyond this (~158°) = reversing;
                              ## below it the base just turns to face travel.
  CogReverseCommitFrames* = 8   ## backward frames before committing to a U-turn.
  CogMoveMinSpeed* = StopThreshold
  CogTurnFullBrads* = 6       ## heading angular velocity mapped to full splay.
  CogTurnAmtEase* = 200       ## turnAmt eases toward target this many milli/frame.

type
  CogDriveState* = object
    ## Per-player broadcast animation state for the segmented trike. NOT in the
    ## sim / gameHash — lives in the viewer state, evolved once per frame.
    initialized*: bool
    bodyHeading*: int          ## brads the chassis currently faces.
    reverseFrames*: int        ## consecutive backward frames (commit counter).
    turnAmt*: int              ## signed steer signal, -1000..1000 (x1000). + = left.
    casterFL*, casterFR*, casterRear*: int  ## brads each wheel points.

proc bradDiff*(a, b: int): int =
  ## Shortest signed difference a-b wrapped to (-128, 128] brads.
  var d = ((a - b) mod AimBradsTurn + AimBradsTurn) mod AimBradsTurn
  if d > AimBradsTurn div 2:
    d -= AimBradsTurn
  d

proc easeBrads*(cur, target, maxStep: int): int =
  ## Steps `cur` toward `target` by at most `maxStep` brads along the shortest
  ## arc, wrapping into 0..AimBradsTurn-1.
  let d = bradDiff(target, cur)
  let step = clamp(d, -maxStep, maxStep)
  ((cur + step) mod AimBradsTurn + AimBradsTurn) mod AimBradsTurn

proc initCogDriveState*(aimBrads: int): CogDriveState =
  ## A freshly-spawned cog faces where it aims, wheels aligned, not reversing,
  ## legs at rest. Reset on any scrub/respawn so a jump never inherits a stale pose.
  CogDriveState(initialized: true, bodyHeading: aimBrads, reverseFrames: 0,
    turnAmt: 0, casterFL: aimBrads, casterFR: aimBrads, casterRear: aimBrads)

proc stepCogDrive*(state: CogDriveState, velX, velY, aimBrads: int):
    CogDriveState =
  ## Advances the trike's driving animation ONE frame from the current velocity.
  ## Deterministic: same (state, vel, aim) always yields the same next state.
  if not state.initialized:
    return initCogDriveState(aimBrads)
  result = state
  let speed = abs(velX) + abs(velY)
  if speed < CogMoveMinSpeed:
    # Parked: hold heading, coast every caster back to the heading, relax legs.
    result.reverseFrames = max(0, state.reverseFrames - 1)
    result.turnAmt = state.turnAmt -
      clamp(state.turnAmt, -CogTurnAmtEase, CogTurnAmtEase)
    result.casterFL = easeBrads(state.casterFL, state.bodyHeading, CogWheelTurnRate)
    result.casterFR = easeBrads(state.casterFR, state.bodyHeading, CogWheelTurnRate)
    result.casterRear = easeBrads(state.casterRear, state.bodyHeading, CogWheelTurnRate)
    return
  let
    travel = bradsOfVector(velX, velY)
    offBody = bradDiff(travel, state.bodyHeading).abs
    goingBackward = offBody > CogReverseMaxBrads
  if goingBackward:
    result.reverseFrames = min(state.reverseFrames + 1, CogReverseCommitFrames * 2)
  else:
    result.reverseFrames = max(0, state.reverseFrames - 2)
  let committed = result.reverseFrames >= CogReverseCommitFrames
  let headingTarget =
    if goingBackward and not committed: state.bodyHeading
    else: travel
  # The base snaps toward travel at a FLAT fast rate (a tank track grips and
  # turns hard) — no speed penalty, so a direction change is tracked promptly and
  # accurately instead of lagging a quarter-second behind.
  result.bodyHeading = easeBrads(state.bodyHeading, headingTarget, CogBodyTurnRate)
  # turnAmt: smoothed signed heading angular velocity / CogTurnFull, ×1000.
  let w = bradDiff(result.bodyHeading, state.bodyHeading)
  let tInst = clamp(w * 1000 div max(1, CogTurnFullBrads), -1000, 1000)
  let smoothed = (state.turnAmt * 7 + tInst * 3) div 10
  result.turnAmt = state.turnAmt +
    clamp(smoothed - state.turnAmt, -CogTurnAmtEase, CogTurnAmtEase)
  # Each wheel casters toward the travel direction (with a small turn lean so the
  # wheels visibly lead the arc). Rear leans opposite (pivot foot).
  let lean = clamp(result.turnAmt * (AimBradsTurn div 8) div 1000,
    -(AimBradsTurn div 8), AimBradsTurn div 8)
  result.casterFL = easeBrads(state.casterFL, travel + lean, CogWheelTurnRate)
  result.casterFR = easeBrads(state.casterFR, travel + lean, CogWheelTurnRate)
  result.casterRear = easeBrads(state.casterRear, travel - lean, CogWheelTurnRate)

proc rigHeadingStep*(headingBrads: int): int =
  ## The base rotation step for the movement-facing legs/wheels (quantized to
  ## RigSteps). Same quantization as soldierRotIndex, on the body heading.
  soldierRotIndex(headingBrads)

proc rigLegSwingStep*(seg: RigSeg, turnAmt: int): int =
  ## SIGNED leg swing step (−RigLegSwingSteps..RigLegSwingSteps) from the turn
  ## signal (turnAmt ×1000, + = LEFT/CCW). Both front legs swing together with the
  ## turn (the outer leg widens, the inner one is SHORTENED separately); the rear
  ## counter-swings. Non-leg segments return 0.
  let t = clamp(turnAmt, -1000, 1000)
  if rigSegIsLeg(seg):
    int(round(float(t) / 1000.0 * float(RigLegSwingSteps)))
  else: 0

proc rigLegShortenStep*(seg: RigSeg, turnAmt: int): int =
  ## Leg-length shorten step (0..RigShortenSteps) for the INNER leg of the turn.
  ## +turnAmt = LEFT/CCW ⇒ the LEFT (inner) front leg shortens; −turnAmt ⇒ RIGHT.
  let t = clamp(turnAmt, -1000, 1000)
  case seg
  of rsLegFL:  int(round(float(max(0, t)) / 1000.0 * float(RigShortenSteps)))
  of rsLegFR:  int(round(float(max(0, -t)) / 1000.0 * float(RigShortenSteps)))
  else: 0

proc rigCasterStep*(casterBrads, headingBrads: int): int =
  ## SIGNED wheel caster tilt step (−RigCasterSteps..RigCasterSteps): the caster
  ## direction relative to the base HEADING (the wheel is baked rotated by the
  ## heading, so its extra tilt is caster − heading), clamped to ±RigCasterMaxBrads
  ## so a tall top-down tire only tilts to hint the turn.
  let capped = clamp(bradDiff(casterBrads, headingBrads),
    -RigCasterMaxBrads, RigCasterMaxBrads)
  int(round(float(capped) / float(RigCasterMaxBrads) * float(RigCasterSteps)))

const RigBaseMaxDivergeBrads* = 14  ## ~20°: the leg base only LEANS a little toward
                                    ## the movement heading — it never swings far
                                    ## sideways (the spidery look). The HEAD still
                                    ## aims freely for the full turret swivel.

proc clampBaseHeading*(headingBrads, aimBrads: int): int =
  ## Clamps the leg-base heading to within ±RigBaseMaxDivergeBrads of the aim, so
  ## the base only LEANS into a strafe/turn while the head swivels freely. Returns
  ## a wrapped 0..AimBradsTurn-1 heading.
  let d = clamp(bradDiff(headingBrads, aimBrads),
    -RigBaseMaxDivergeBrads, RigBaseMaxDivergeBrads)
  ((aimBrads + d) mod AimBradsTurn + AimBradsTurn) mod AimBradsTurn

proc crewVariantIndex*(slotId: int): int =
  ## Returns the crew sprite variant for one player slot.
  if CrewSpriteVariants <= 0:
    return 0
  ((slotId mod CrewSpriteVariants) + CrewSpriteVariants) mod
    CrewSpriteVariants

proc validateMapRect(name: string, rect: MapRect, width, height: int) =
  ## Raises if one map rectangle is outside the map.
  if rect.w <= 0 or rect.h <= 0:
    raise newException(CtfError, "Map " & name & " size must be positive.")
  if rect.x < 0 or rect.y < 0 or
      rect.x + rect.w > width or rect.y + rect.h > height:
    raise newException(CtfError, "Map " & name & " is outside the map.")

proc validateMapPoint(name: string, point: MapPoint, width, height: int) =
  ## Raises if one map point is outside the map.
  if point.x < 0 or point.y < 0 or point.x >= width or point.y >= height:
    raise newException(CtfError, "Map " & name & " is outside the map.")

proc validateMap(gameMap: CtfMap) =
  ## Raises if a loaded map has invalid geometry.
  if gameMap.width <= 0 or gameMap.height <= 0:
    raise newException(CtfError, "Map dimensions must be positive.")
  validateMapPoint("center", gameMap.center, gameMap.width, gameMap.height)
  for i, room in gameMap.rooms:
    validateMapRect(
      "room " & $i,
      MapRect(x: room.x, y: room.y, w: room.w, h: room.h),
      gameMap.width,
      gameMap.height
    )

const
  ArenaName = "arena"
  ArenaLargeName = "arena-large"

  ## The MW2 paintball map pack: six top-down recreations of crowd-favorite
  ## Call of Duty: Modern Warfare 2 (2009) multiplayer maps, re-themed as
  ## paintball fields (docs/designs/mw2-paintball-maps.md holds the layouts,
  ## lane plans, and landmark rationale). Registered names below; the "mw2"
  ## ROTATION ALIAS is resolved in updateGameConfig, never in the registry.
  RustName = "rust"
  TerminalName = "terminal"
  HighriseName = "highrise"
  FavelaName = "favela"
  AfghanName = "afghan"
  ScrapyardName = "scrapyard"
  Mw2AliasName = "mw2"

  ## Per-episode rotation for mapPath "mw2": the league runs one fresh server
  ## process per episode with a distinct seed, so resolving the alias from
  ## the seed at config time rotates the pack across a round's episodes. The
  ## replay header records the RESOLVED name (a pure function of the recorded
  ## config), keeping replay re-simulation exact.
  Mw2Rotation* = [RustName, TerminalName, HighriseName, FavelaName,
                  AfghanName, ScrapyardName]

  ArenaBorder* = 10            ## perimeter wall thickness in px.
  DefaultFloorTex = "data/arena_floor.png"

  ## Warm CRT-phosphor arena (REPLAY_DESIGN §3 art-lock): warm-dark floor,
  ## warm-stone cover, the two team colors the only saturated channels — never
  ## the cold blue-slate default the house style forbids.
  ArenaBorderColor = rgba(44, 34, 25, 255)

  ## Interior obstacle shapes for the LEFT half only. Each is mirrored
  ## across the vertical center line so both halves are identical, and the
  ## in-column shapes come in top/bottom mirrored pairs around the map's
  ## horizontal midline. With map-wide guns the layout is a slalom of five
  ## staggered columns (x-centers 277/349/421/493/565 plus their x-mirrors)
  ## whose in-column gaps are offset from the neighbours', so every
  ## horizontal row hits a shape and no straight cross-field ray survives,
  ## while every corridor stays >= 26px for the 13px player footprint. The
  ## columns vary the shape per lane: border-attached rect stubs, diamonds,
  ## discs, 45-degree chevron walls angling across the old corridors, and
  ## rect/diamond stubs flanking the flag ring. A windowed square bracket
  ## straddling the horizontal midline closes the mid lane outside the flag
  ## ring to movement and fire, while its glass center pane gives both teams
  ## a fogless sightline down the center corridor (GameVersion 16); the
  ## ring itself stays an open disc for close flag fights. Shapes sit
  ## between the capture/spawn columns and the flag ring; isProtectedFloor
  ## carves them out of the ring, pockets, and capture columns.
  ArenaLeftObstacles = [
    # Column 1 (x=268..286): rect stubs, phase 0, border-attached ends. The
    # SECOND stub from the top and from the bottom are GLASS WINDOWS
    # (GameVersion 15): solid to movement, bullets, and spray cones, transparent
    # to fog-of-war.
    ArenaShape(kind: shapeRect, rect: MapRect(x: 268, y: 10, w: 18, h: 62)),
    ArenaShape(kind: shapeRect, window: true,
      rect: MapRect(x: 268, y: 108, w: 18, h: 60)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 268, y: 204, w: 18, h: 60)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 268, y: 300, w: 18, h: 59)),
    # GV26: the FIFTH stub from the top is a GLASS WINDOW too (operator rule)
    # — windows at stubs 2, 5, and 6; x-mirrored like every column-1 shape.
    ArenaShape(kind: shapeRect, window: true,
      rect: MapRect(x: 268, y: 395, w: 18, h: 60)),
    ArenaShape(kind: shapeRect, window: true,
      rect: MapRect(x: 268, y: 491, w: 18, h: 60)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 268, y: 587, w: 18, h: 62)),
    # Column 2 (x=349): diamonds, phase +48 (half period) vs column 1.
    ArenaShape(kind: shapeDiamond, cx: 349, cy: 90, radius: 28),
    ArenaShape(kind: shapeDiamond, cx: 349, cy: 186, radius: 28),
    ArenaShape(kind: shapeDiamond, cx: 349, cy: 282, radius: 28),
    ArenaShape(kind: shapeDiamond, cx: 349, cy: 376, radius: 28),
    ArenaShape(kind: shapeDiamond, cx: 349, cy: 472, radius: 28),
    ArenaShape(kind: shapeDiamond, cx: 349, cy: 568, radius: 28),
    # Column 3 (x=421): discs, phase +24. GameVersion 16 thinned the lane:
    # every other disc removed (was 66/162/258/400/496/592), giving the
    # column real gaps instead of a near-solid picket. Top/bottom mirror
    # symmetry is intentionally traded for the lower density; team fairness
    # only needs the x-mirror.
    ArenaShape(kind: shapeDisc, cx: 421, cy: 66, radius: 28),
    ArenaShape(kind: shapeDisc, cx: 421, cy: 258, radius: 28),
    ArenaShape(kind: shapeDisc, cx: 421, cy: 496, radius: 28),
    # Column 4 (x=479..509): 45-degree chevron walls, phase +72; the
    # midline pair was replaced in GameVersion 16 by the windowed bracket
    # below.
    ArenaShape(kind: shapeDiagonal, x0: 479, y0: 86, x1: 507, y1: 114, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 507, y0: 114, x1: 479, y1: 142, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 507, y0: 182, x1: 479, y1: 210, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 479, y0: 210, x1: 507, y1: 238, thickness: 12),
    # GameVersion 16: the old midline chevron zigzag (the sideways "W" that
    # closed the mid lane) is now a square bracket over the same footprint
    # (x=479..507, y=276..383): a vertical bar on the outer side plus short
    # arms reaching toward the flag ring — "[" here, "]" on the x-mirror.
    # The middle of the bar, straddling the midline, is a GLASS WINDOW:
    # the mid lane stays closed to movement, bullets, and spray, but
    # fog-of-war now sees straight down the center corridor through it.
    ArenaShape(kind: shapeRect, rect: MapRect(x: 479, y: 276, w: 28, h: 12)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 479, y: 288, w: 12, h: 24)),
    ArenaShape(kind: shapeRect, window: true,
      rect: MapRect(x: 479, y: 312, w: 12, h: 36)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 479, y: 348, w: 12, h: 23)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 479, y: 371, w: 28, h: 12)),
    ArenaShape(kind: shapeDiagonal, x0: 507, y0: 421, x1: 479, y1: 449, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 479, y0: 449, x1: 507, y1: 477, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 479, y0: 517, x1: 507, y1: 545, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 507, y0: 545, x1: 479, y1: 573, thickness: 12),
    # Column 5 (x=556..595): rect stubs at the borders, diamonds flanking
    # the flag ring (the ring carves their inner edges).
    ArenaShape(kind: shapeRect, rect: MapRect(x: 556, y: 24, w: 18, h: 66)),
    ArenaShape(kind: shapeDiamond, cx: 565, cy: 156, radius: 30),
    ArenaShape(kind: shapeDiamond, cx: 565, cy: 252, radius: 30),
    ArenaShape(kind: shapeDiamond, cx: 565, cy: 406, radius: 30),
    ArenaShape(kind: shapeDiamond, cx: 565, cy: 502, radius: 30),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 556, y: 569, w: 18, h: 66)),
  ]

  ## The arena-large layout (1606x858, 30% bigger in both axes): every
  ## shape keeps its `arena` SIZE while its CENTER (and the layout
  ## clearances) scale by 1.3, so the same cover sits in a roomier field
  ## with ~30% wider corridors — and some long sightlines the dense arena
  ## deliberately closed now survive; the field plays roomier by design.
  ## Five staggered columns at x-centers 360/454/547/641/735 plus their
  ## x-mirrors; border-attached stubs stay attached and the column-5 border
  ## gaps stay < 26px (impassable) rather than scaling into new lanes.
  ArenaLargeLeftObstacles = [
    # Column 1 (x=351..369): rect stubs, phase 0, border-attached ends. The
    # SECOND stub from the top and from the bottom are GLASS WINDOWS
    # (GameVersion 15): solid to movement, bullets, and spray cones, transparent
    # to fog-of-war.
    ArenaShape(kind: shapeRect, rect: MapRect(x: 351, y: 10, w: 18, h: 62)),
    ArenaShape(kind: shapeRect, window: true,
      rect: MapRect(x: 351, y: 149, w: 18, h: 60)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 351, y: 274, w: 18, h: 60)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 351, y: 399, w: 18, h: 59)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 351, y: 524, w: 18, h: 60)),
    ArenaShape(kind: shapeRect, window: true,
      rect: MapRect(x: 351, y: 649, w: 18, h: 60)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 351, y: 786, w: 18, h: 62)),
    # Column 2 (x=454): diamonds, phase +48 (half period) vs column 1.
    ArenaShape(kind: shapeDiamond, cx: 454, cy: 117, radius: 28),
    ArenaShape(kind: shapeDiamond, cx: 454, cy: 242, radius: 28),
    ArenaShape(kind: shapeDiamond, cx: 454, cy: 367, radius: 28),
    ArenaShape(kind: shapeDiamond, cx: 454, cy: 491, radius: 28),
    ArenaShape(kind: shapeDiamond, cx: 454, cy: 616, radius: 28),
    ArenaShape(kind: shapeDiamond, cx: 454, cy: 741, radius: 28),
    # Column 3 (x=547): discs, phase +24. GameVersion 16 thinned the lane:
    # every other disc removed, giving the column real gaps instead of a
    # near-solid picket. Top/bottom mirror symmetry is intentionally traded
    # for the lower density; team fairness only needs the x-mirror.
    ArenaShape(kind: shapeDisc, cx: 547, cy: 86, radius: 28),
    ArenaShape(kind: shapeDisc, cx: 547, cy: 335, radius: 28),
    ArenaShape(kind: shapeDisc, cx: 547, cy: 645, radius: 28),
    # Column 4 (x=627..655): 45-degree chevron walls, phase +72; the
    # midline pair was replaced in GameVersion 16 by the windowed bracket
    # below.
    ArenaShape(kind: shapeDiagonal, x0: 627, y0: 120, x1: 655, y1: 148, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 655, y0: 148, x1: 627, y1: 176, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 655, y0: 245, x1: 627, y1: 273, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 627, y0: 273, x1: 655, y1: 301, thickness: 12),
    # GameVersion 16: the old midline chevron zigzag (the sideways "W" that
    # closed the mid lane) is now a square bracket over the same footprint
    # (x=627..655, y=375..482): a vertical bar on the outer side plus short
    # arms reaching toward the flag ring — "[" here, "]" on the x-mirror.
    # The middle of the bar, straddling the midline, is a GLASS WINDOW:
    # the mid lane stays closed to movement, bullets, and spray, but
    # fog-of-war now sees straight down the center corridor through it.
    ArenaShape(kind: shapeRect, rect: MapRect(x: 627, y: 375, w: 28, h: 12)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 627, y: 387, w: 12, h: 24)),
    ArenaShape(kind: shapeRect, window: true,
      rect: MapRect(x: 627, y: 411, w: 12, h: 36)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 627, y: 447, w: 12, h: 23)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 627, y: 470, w: 28, h: 12)),
    ArenaShape(kind: shapeDiagonal, x0: 655, y0: 557, x1: 627, y1: 585, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 627, y0: 585, x1: 655, y1: 613, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 627, y0: 682, x1: 655, y1: 710, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 655, y0: 710, x1: 627, y1: 738, thickness: 12),
    # Column 5 (x=726..744): rect stubs at the borders (their border gaps
    # stay < 26px, i.e. impassable, rather than scaling into new lanes),
    # diamonds flanking the flag ring.
    ArenaShape(kind: shapeRect, rect: MapRect(x: 726, y: 31, w: 18, h: 66)),
    ArenaShape(kind: shapeDiamond, cx: 735, cy: 203, radius: 30),
    ArenaShape(kind: shapeDiamond, cx: 735, cy: 328, radius: 30),
    ArenaShape(kind: shapeDiamond, cx: 735, cy: 530, radius: 30),
    ArenaShape(kind: shapeDiamond, cx: 735, cy: 655, radius: 30),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 726, y: 761, w: 18, h: 66)),
  ]

  ## Rust: the oil-yard speedball field. Derrick tower dead center,
  ## pipe run, fuel tank, barrel bunkers.
  RustLeftObstacles = [
    # shack, shifted right out of the x<210 capture-column carve
    ArenaShape(kind: shapeRect, rect: MapRect(x: 214, y: 62, w: 89, h: 75)),
    # big fuel tank, cx shifted clear of the carve
    ArenaShape(kind: shapeDisc, cx: 278, cy: 522, radius: 62),
    # pipe run west of the gap (gap widened to 29px for the player footprint)
    ArenaShape(kind: shapeRect, rect: MapRect(x: 247, y: 385, w: 109, h: 25)),
    # pipe run east of the gap
    ArenaShape(kind: shapeRect, rect: MapRect(x: 385, y: 385, w: 109, h: 25)),
    # container
    ArenaShape(kind: shapeRect, rect: MapRect(x: 420, y: 62, w: 99, h: 50)),
    # dumpster
    ArenaShape(kind: shapeRect, rect: MapRect(x: 445, y: 547, w: 61, h: 37)),
    # barrels scattered along the approaches
    ArenaShape(kind: shapeDisc, cx: 321, cy: 162, radius: 19),
    ArenaShape(kind: shapeDisc, cx: 352, cy: 193, radius: 19),
    ArenaShape(kind: shapeDisc, cx: 408, cy: 497, radius: 19),
    ArenaShape(kind: shapeDisc, cx: 531, cy: 448, radius: 19),
    # tower approach ramp
    ArenaShape(kind: shapeDiagonal, x0: 506, y0: 224, x1: 568, y1: 286, thickness: 12),
    # THE derrick tower, as a derrick is top-down: four fat leg pylons
    # around an open middle. The protected r70 center disc stays floor, so
    # the flag fight happens UNDER the tower; the mirror gives the east legs.
    ArenaShape(kind: shapeDiamond, cx: 552, cy: 264, radius: 26),
    ArenaShape(kind: shapeDiamond, cx: 552, cy: 394, radius: 26),
    # Sightline pickets (see the no-cross-field-ray invariant below): the rows
    # the props above leave fully open, closed with oil-yard furniture. Two
    # border-attached pipe stacks take the north and south margin strips, a
    # riser tees off the horizontal pipe run to close the mid lane, and three
    # barrels plug the thin seams between the other shapes.
    ArenaShape(kind: shapeRect, rect: MapRect(x: 330, y: 10, w: 22, h: 62)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 330, y: 580, w: 22, h: 79)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 300, y: 291, w: 24, h: 94)),
    ArenaShape(kind: shapeDisc, cx: 372, cy: 140, radius: 20),
    ArenaShape(kind: shapeDisc, cx: 300, cy: 215, radius: 20),
    ArenaShape(kind: shapeDisc, cx: 408, cy: 428, radius: 20),
  ]

  ## Terminal: the airport concourse. Inflatable 747 IS the north
  ## lane; glass duty-free + scanner comb mid; Burger Town south.
  TerminalLeftObstacles = [
    # lounge seating, shifted+shortened out of the carve
    ArenaShape(kind: shapeRect, rect: MapRect(x: 214, y: 162, w: 70, h: 25)),
    # Burger Town
    ArenaShape(kind: shapeRect, rect: MapRect(x: 222, y: 472, w: 124, h: 100)),
    # duty-free island (glass)
    ArenaShape(kind: shapeRect, window: true, rect: MapRect(x: 296, y: 199, w: 99, h: 75)),
    # pillar
    ArenaShape(kind: shapeDisc, cx: 272, cy: 323, radius: 12),
    # pillar
    ArenaShape(kind: shapeDisc, cx: 370, cy: 385, radius: 12),
    # scanner comb (slits widened to 30px)
    ArenaShape(kind: shapeRect, window: true, rect: MapRect(x: 420, y: 255, w: 25, h: 31)),
    # scanner comb
    ArenaShape(kind: shapeRect, window: true, rect: MapRect(x: 420, y: 317, w: 25, h: 31)),
    # scanner comb
    ArenaShape(kind: shapeRect, window: true, rect: MapRect(x: 420, y: 379, w: 25, h: 31)),
    # luggage cart
    ArenaShape(kind: shapeRect, rect: MapRect(x: 469, y: 535, w: 37, h: 25)),
    # luggage cart
    ArenaShape(kind: shapeRect, rect: MapRect(x: 531, y: 497, w: 37, h: 25)),
    # jet bridge
    ArenaShape(kind: shapeDiagonal, x0: 469, y0: 174, x1: 537, y1: 106, thickness: 12),
    # 747 fuselage west of fwd door (door widened to 30px)
    ArenaShape(kind: shapeRect, rect: MapRect(x: 494, y: 75, w: 47, h: 87)),
    # 747 fuselage centre piece; mirror closes the east half
    ArenaShape(kind: shapeRect, rect: MapRect(x: 571, y: 75, w: 47, h: 87)),
    # 747 west wing
    ArenaShape(kind: shapeDiagonal, x0: 568, y0: 162, x1: 482, y1: 248, thickness: 12),
    # wing engine
    ArenaShape(kind: shapeDisc, cx: 531, cy: 211, radius: 25),
    # Sightline pickets (no-cross-field-ray invariant): concourse furniture on
    # the rows the set pieces leave open. A check-in desk run takes the north
    # margin, a baggage carousel arc and a cart the south, and two departure-
    # board pylons flank the scanner comb to close the mid-lane seams.
    ArenaShape(kind: shapeRect, rect: MapRect(x: 330, y: 10, w: 24, h: 65)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 366, y: 566, w: 24, h: 93)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 300, y: 410, w: 24, h: 62)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 469, y: 286, w: 22, h: 25)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 469, y: 348, w: 22, h: 25)),
  ]

  ## Highrise: the rooftop court. Glass office core per half, duct
  ## trench mid, crane center-north; the helipad south stays open floor.
  HighriseLeftObstacles = [
    # office core seg 1 (shifted clear of pocket carve)
    ArenaShape(kind: shapeRect, window: true, rect: MapRect(x: 257, y: 174, w: 80, h: 37)),
    # office core seg 2 (exit gaps between segs)
    ArenaShape(kind: shapeRect, window: true, rect: MapRect(x: 257, y: 249, w: 80, h: 62)),
    # office core seg 3
    ArenaShape(kind: shapeRect, window: true, rect: MapRect(x: 257, y: 348, w: 80, h: 75)),
    # office core seg 4
    ArenaShape(kind: shapeRect, window: true, rect: MapRect(x: 257, y: 460, w: 80, h: 25)),
    # AC unit north
    ArenaShape(kind: shapeRect, rect: MapRect(x: 222, y: 124, w: 50, h: 38)),
    # AC unit south
    ArenaShape(kind: shapeRect, rect: MapRect(x: 272, y: 497, w: 49, h: 38)),
    # duct trench west
    ArenaShape(kind: shapeRect, rect: MapRect(x: 321, y: 311, w: 61, h: 37)),
    # duct trench east (gap widened to 30px)
    ArenaShape(kind: shapeRect, rect: MapRect(x: 411, y: 311, w: 58, h: 37)),
    # crate north
    ArenaShape(kind: shapeRect, rect: MapRect(x: 370, y: 87, w: 38, h: 37)),
    # crate south
    ArenaShape(kind: shapeRect, rect: MapRect(x: 408, y: 547, w: 37, h: 37)),
    # scaffold stair
    ArenaShape(kind: shapeDiagonal, x0: 494, y0: 211, x1: 556, y1: 149, thickness: 12),
    # crane base (center, mirror-exact)
    ArenaShape(kind: shapeRect, rect: MapRect(x: 593, y: 25, w: 49, h: 62)),
    # crane arm reaching mid (center, mirror-exact)
    ArenaShape(kind: shapeRect, rect: MapRect(x: 605, y: 87, w: 25, h: 87)),
    # Sightline pickets (no-cross-field-ray invariant): rooftop plant on the
    # rows the cores and trench leave open — a parapet stub at the north edge,
    # a stair bulkhead and vent bank across the south deck, and two more AC
    # units closing the seams above and below the duct trench.
    ArenaShape(kind: shapeRect, rect: MapRect(x: 370, y: 10, w: 24, h: 40)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 370, y: 580, w: 24, h: 79)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 411, y: 218, w: 24, h: 46)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 349, y: 423, w: 24, h: 46)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 460, y: 480, w: 24, h: 70)),
  ]

  ## Favela: shantytown streetball. Staggered shanty blocks, water
  ## tanks, and the EMPTY center courtyard as the landmark.
  FavelaLeftObstacles = [
    # shanty B (widened left, absorbs carved block A)
    ArenaShape(kind: shapeRect, rect: MapRect(x: 214, y: 75, w: 119, h: 99)),
    # shanty C (alley to B widened to 31px)
    ArenaShape(kind: shapeRect, rect: MapRect(x: 364, y: 99, w: 93, h: 112)),
    # shanty E (widened left, absorbs carved block D)
    ArenaShape(kind: shapeRect, rect: MapRect(x: 214, y: 472, w: 156, h: 100)),
    # shanty F (alley to E widened to 31px)
    ArenaShape(kind: shapeRect, rect: MapRect(x: 401, y: 385, w: 93, h: 100)),
    # rooftop water tank on B
    ArenaShape(kind: shapeDisc, cx: 284, cy: 124, radius: 19),
    # rooftop water tank on F
    ArenaShape(kind: shapeDisc, cx: 420, cy: 435, radius: 19),
    # rooftop water tank on E (moved from carved block D)
    ArenaShape(kind: shapeDisc, cx: 241, cy: 522, radius: 19),
    # stair alley
    ArenaShape(kind: shapeDiagonal, x0: 469, y0: 286, x1: 531, y1: 224, thickness: 12),
    # construction scaffold centre-north (center, mirror-exact)
    ArenaShape(kind: shapeRect, rect: MapRect(x: 568, y: 50, w: 99, h: 74)),
    # kiosk centre-south; courtyard between stays EMPTY (center, mirror-exact)
    ArenaShape(kind: shapeRect, rect: MapRect(x: 580, y: 522, w: 75, h: 50)),
    # Sightline pickets (no-cross-field-ray invariant): more of the same
    # shantytown grain on the rows the blocks leave open — a roofline block at
    # the north wall, a stacked-crate pile at the south, and a market-stall row
    # breaking the long plaza approach WITHOUT touching the center courtyard
    # (that emptiness is the landmark).
    ArenaShape(kind: shapeRect, rect: MapRect(x: 364, y: 10, w: 62, h: 52)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 401, y: 566, w: 62, h: 93)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 296, y: 293, w: 25, h: 92)),
    ArenaShape(kind: shapeDisc, cx: 345, cy: 214, radius: 20),
  ]

  ## Afghan: the desert crash site. C-130 wreck dead center, north
  ## ridge with a cave mouth, burnt tank, sandbag lines.
  AfghanLeftObstacles = [
    # bunker as a C open toward the field; shifted clear of the pocket carve
    ArenaShape(kind: shapeRect, rect: MapRect(x: 257, y: 261, w: 25, h: 137)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 282, y: 261, w: 74, h: 25)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 282, y: 373, w: 74, h: 25)),
    # north ridge (the west stub is absorbed by the capture column; the ridge
    # face itself is the cave-mouth cover line)
    ArenaShape(kind: shapeRect, rect: MapRect(x: 222, y: 0, w: 297, h: 62)),
    # rocks
    ArenaShape(kind: shapeDisc, cx: 272, cy: 174, radius: 31),
    ArenaShape(kind: shapeDisc, cx: 371, cy: 435, radius: 37),
    ArenaShape(kind: shapeDisc, cx: 321, cy: 560, radius: 25),
    # burnt tank hulk
    ArenaShape(kind: shapeRect, rect: MapRect(x: 395, y: 249, w: 74, h: 37)),
    # sandbag lines
    ArenaShape(kind: shapeDiagonal, x0: 247, y0: 373, x1: 297, y1: 423, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 445, y0: 472, x1: 495, y1: 522, thickness: 12),
    # THE crashed C-130, as a broken airframe: the forward fuselage west of
    # the protected r70 center disc (the mirror supplies the aft half), the
    # open ring between them reading as the burned-out midsection crater.
    ArenaShape(kind: shapeRect, rect: MapRect(x: 484, y: 292, w: 68, h: 74)),
    # nose cone ahead of the body
    ArenaShape(kind: shapeDisc, cx: 458, cy: 329, radius: 28),
    # port wing swept back from the body, engine on the wing line
    ArenaShape(kind: shapeDiagonal, x0: 500, y0: 292, x1: 430, y1: 222, thickness: 12),
    ArenaShape(kind: shapeDisc, cx: 455, cy: 247, radius: 20),
    # broken tail chunk fallen south-west (the mirror drops a matching piece
    # south-east; together they flank the crater)
    ArenaShape(kind: shapeRect, rect: MapRect(x: 505, y: 404, w: 56, h: 40)),
    # Sightline pickets (no-cross-field-ray invariant): desert-field cover on
    # the rows the ridge and wreck leave open — a rock spur below the ridge
    # line, a dune-and-boulder pair across the south riverbed, and one more
    # boulder closing the seam above the bunker.
    ArenaShape(kind: shapeRect, rect: MapRect(x: 404, y: 62, w: 26, h: 81)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 396, y: 586, w: 26, h: 73)),
    ArenaShape(kind: shapeDisc, cx: 466, cy: 531, radius: 22),
    ArenaShape(kind: shapeDisc, cx: 300, cy: 210, radius: 20),
  ]

  ## Scrapyard: the aircraft boneyard. A broken fuselage spine down
  ## the midline between two brick streets.
  ScrapyardLeftObstacles = [
    # brick office (shifted right out of the carve)
    ArenaShape(kind: shapeRect, rect: MapRect(x: 214, y: 87, w: 92, h: 124)),
    # warehouse (shifted right out of the carve)
    ArenaShape(kind: shapeRect, rect: MapRect(x: 214, y: 448, w: 98, h: 124)),
    # west fuselage fore (body gap widened to 30px)
    ArenaShape(kind: shapeRect, rect: MapRect(x: 296, y: 298, w: 60, h: 63)),
    # west fuselage aft
    ArenaShape(kind: shapeRect, rect: MapRect(x: 385, y: 298, w: 60, h: 63)),
    # west fuselage nose cone (ring carves its west face)
    ArenaShape(kind: shapeDisc, cx: 272, cy: 330, radius: 31),
    # engine stack north (moved off the shifted office)
    ArenaShape(kind: shapeDisc, cx: 333, cy: 62, radius: 25),
    # engine stack south
    ArenaShape(kind: shapeDisc, cx: 469, cy: 560, radius: 25),
    # crate north
    ArenaShape(kind: shapeRect, rect: MapRect(x: 370, y: 112, w: 38, h: 37)),
    # crate south
    ArenaShape(kind: shapeRect, rect: MapRect(x: 408, y: 485, w: 37, h: 37)),
    # wing leaning on the fuselage
    ArenaShape(kind: shapeDiagonal, x0: 445, y0: 274, x1: 507, y1: 212, thickness: 12),
    # scrap-wall dressing north
    ArenaShape(kind: shapeRect, rect: MapRect(x: 198, y: 0, w: 172, h: 25)),
    # scrap-wall dressing south
    ArenaShape(kind: shapeRect, rect: MapRect(x: 247, y: 634, w: 173, h: 25)),
    # center fuselage: the spine's third airframe FLANKS the protected ring
    # (the mirror supplies its aft half across the ring gap)
    ArenaShape(kind: shapeRect, rect: MapRect(x: 470, y: 298, w: 75, h: 63)),
    # tail fin south of the ring (animates: within 80px of center.x)
    ArenaShape(kind: shapeDiamond, cx: 617, cy: 412, radius: 30),
    # Sightline pickets (no-cross-field-ray invariant): more boneyard scrap on
    # the rows the spine and streets leave open — a stripped wing panel below
    # the north scrap wall, a crushed-hulk stack above the south one, and two
    # engine cowlings closing the seams fore and aft of the fuselage spine.
    ArenaShape(kind: shapeRect, rect: MapRect(x: 400, y: 25, w: 24, h: 45)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 445, y: 586, w: 24, h: 60)),
    # (kept x-clear of the fuselage body gap at x 356..385 — plugging both its
    # ends would seal the passage through the spine into a dead pocket)
    ArenaShape(kind: shapeDisc, cx: 326, cy: 289, radius: 22),
    ArenaShape(kind: shapeDisc, cx: 326, cy: 379, radius: 22),
    ArenaShape(kind: shapeDisc, cx: 300, cy: 445, radius: 20),
  ]

proc defaultCtfRooms(gameMap: CtfMap): seq[Room] =
  ## The three-room annotation set every map shares: an informal center zone
  ## plus the two base strips spanning the spawn pockets. Derives entirely
  ## from the map's dimensions and clearances.
  @[
    Room(name: "Center", x: gameMap.width div 2 - 80,
         y: gameMap.height div 2 - 80, w: 160, h: 160),
    Room(name: "Red Base", x: 0,
         y: gameMap.height div 2 - gameMap.spawnClearH,
         w: gameMap.captureClear, h: 2 * gameMap.spawnClearH),
    Room(name: "Blue Base", x: gameMap.width - gameMap.captureClear,
         y: gameMap.height div 2 - gameMap.spawnClearH,
         w: gameMap.captureClear, h: 2 * gameMap.spawnClearH),
  ]

proc arenaCtfMap(): CtfMap =
  ## The default arena: the procedurally-defined symmetric 1235x659 map.
  result.name = ArenaName
  result.path = ArenaName
  result.width = 1235
  result.height = 659
  result.mapLayer = 0
  result.walkLayer = 1
  result.wallLayer = 2
  result.center = MapPoint(x: result.width div 2, y: result.height div 2)
  result.flagRing = 70
  result.captureClear = 210
  result.spawnClearW = 70
  result.spawnClearH = 130
  result.gunRange = 1300
  result.leftObstacles = @ArenaLeftObstacles
  result.medKitSpawns = @[
    MapPoint(x: result.width div 2, y: result.height div 3),
    MapPoint(x: result.width div 2, y: 2 * result.height div 3),
  ]
  result.medKitCandidates = result.medKitSpawns
  result.rooms = result.defaultCtfRooms()
  result.validateMap()

proc arenaLargeCtfMap(): CtfMap =
  ## The arena-large map: 1606x858 (+30% both axes). Obstacles keep their
  ## `arena` sizes but sit spread out; the layout clearances and the gun
  ## range scale with the field.
  result.name = ArenaLargeName
  result.path = ArenaLargeName
  result.width = 1606
  result.height = 858
  result.mapLayer = 0
  result.walkLayer = 1
  result.wallLayer = 2
  result.center = MapPoint(x: result.width div 2, y: result.height div 2)
  result.flagRing = 91
  result.captureClear = 273
  result.spawnClearW = 91
  result.spawnClearH = 169
  result.gunRange = 1690
  result.leftObstacles = @ArenaLargeLeftObstacles
  result.medKitSpawns = @[
    MapPoint(x: result.width div 2, y: result.height div 3),
    MapPoint(x: result.width div 2, y: 2 * result.height div 3),
  ]
  result.medKitCandidates = result.medKitSpawns
  result.rooms = result.defaultCtfRooms()
  result.validateMap()

proc rustCtfMap(): CtfMap =
  ## MW2 Rust as a paintball field: the derrick tower decides every fight.
  result.name = RustName
  result.path = RustName
  result.width = 1235
  result.height = 659
  result.mapLayer = 0
  result.walkLayer = 1
  result.wallLayer = 2
  result.center = MapPoint(x: result.width div 2, y: result.height div 2)
  result.flagRing = 70
  result.captureClear = 210
  result.spawnClearW = 70
  result.spawnClearH = 130
  result.gunRange = 1300
  result.leftObstacles = @RustLeftObstacles
  ## Art: rusted sheet metal and iron scaffold.
  result.floorTex = "data/rust_floor.png"
  result.material = ArenaMaterial(
    face: rgba(126, 82, 52, 255),
    hi: rgba(198, 138, 88, 255),
    lo: rgba(64, 38, 22, 255),
    ink: rgba(36, 20, 12, 255)
  )
  ## Med kits ride the classic center-line thirds, like the hand-authored
  ## arenas (the generated maps draw their own pair).
  result.medKitSpawns = @[
    MapPoint(x: result.width div 2, y: result.height div 3),
    MapPoint(x: result.width div 2, y: 2 * result.height div 3),
  ]
  result.medKitCandidates = result.medKitSpawns
  result.rooms = result.defaultCtfRooms()
  result.validateMap()

proc terminalCtfMap(): CtfMap =
  ## MW2 Terminal as a paintball field: fight through the 747 or the scanners.
  result.name = TerminalName
  result.path = TerminalName
  result.width = 1235
  result.height = 659
  result.mapLayer = 0
  result.walkLayer = 1
  result.wallLayer = 2
  result.center = MapPoint(x: result.width div 2, y: result.height div 2)
  result.flagRing = 70
  result.captureClear = 210
  result.spawnClearW = 70
  result.spawnClearH = 130
  result.gunRange = 1300
  result.leftObstacles = @TerminalLeftObstacles
  ## Art: white terminal panel and brushed trim.
  result.floorTex = "data/terminal_floor.png"
  result.material = ArenaMaterial(
    face: rgba(176, 174, 168, 255),
    hi: rgba(232, 230, 224, 255),
    lo: rgba(96, 95, 92, 255),
    ink: rgba(44, 44, 42, 255)
  )
  ## Med kits ride the classic center-line thirds, like the hand-authored
  ## arenas (the generated maps draw their own pair).
  result.medKitSpawns = @[
    MapPoint(x: result.width div 2, y: result.height div 3),
    MapPoint(x: result.width div 2, y: 2 * result.height div 3),
  ]
  result.medKitCandidates = result.medKitSpawns
  result.rooms = result.defaultCtfRooms()
  result.validateMap()

proc highriseCtfMap(): CtfMap =
  ## MW2 Highrise as a paintball field: core exits, duct trench, open helipad.
  result.name = HighriseName
  result.path = HighriseName
  result.width = 1235
  result.height = 659
  result.mapLayer = 0
  result.walkLayer = 1
  result.wallLayer = 2
  result.center = MapPoint(x: result.width div 2, y: result.height div 2)
  result.flagRing = 70
  result.captureClear = 210
  result.spawnClearW = 70
  result.spawnClearH = 130
  result.gunRange = 1300
  result.leftObstacles = @HighriseLeftObstacles
  ## Art: poured grey concrete plant.
  result.floorTex = "data/highrise_floor.png"
  result.material = ArenaMaterial(
    face: rgba(142, 141, 136, 255),
    hi: rgba(196, 195, 189, 255),
    lo: rgba(78, 78, 76, 255),
    ink: rgba(38, 38, 37, 255)
  )
  ## Med kits ride the classic center-line thirds, like the hand-authored
  ## arenas (the generated maps draw their own pair).
  result.medKitSpawns = @[
    MapPoint(x: result.width div 2, y: result.height div 3),
    MapPoint(x: result.width div 2, y: 2 * result.height div 3),
  ]
  result.medKitCandidates = result.medKitSpawns
  result.rooms = result.defaultCtfRooms()
  result.validateMap()

proc favelaCtfMap(): CtfMap =
  ## MW2 Favela as a paintball field: alley maze around an open courtyard.
  result.name = FavelaName
  result.path = FavelaName
  result.width = 1235
  result.height = 659
  result.mapLayer = 0
  result.walkLayer = 1
  result.wallLayer = 2
  result.center = MapPoint(x: result.width div 2, y: result.height div 2)
  result.flagRing = 70
  result.captureClear = 210
  result.spawnClearW = 70
  result.spawnClearH = 130
  result.gunRange = 1300
  result.leftObstacles = @FavelaLeftObstacles
  ## Art: painted plywood and cinder block.
  result.floorTex = "data/favela_floor.png"
  result.material = ArenaMaterial(
    face: rgba(150, 106, 78, 255),
    hi: rgba(210, 160, 124, 255),
    lo: rgba(78, 52, 36, 255),
    ink: rgba(40, 26, 18, 255)
  )
  ## Med kits ride the classic center-line thirds, like the hand-authored
  ## arenas (the generated maps draw their own pair).
  result.medKitSpawns = @[
    MapPoint(x: result.width div 2, y: result.height div 3),
    MapPoint(x: result.width div 2, y: 2 * result.height div 3),
  ]
  result.medKitCandidates = result.medKitSpawns
  result.rooms = result.defaultCtfRooms()
  result.validateMap()

proc afghanCtfMap(): CtfMap =
  ## MW2 Afghan as a paintball field: the C-130 wreck owns the midfield.
  result.name = AfghanName
  result.path = AfghanName
  result.width = 1235
  result.height = 659
  result.mapLayer = 0
  result.walkLayer = 1
  result.wallLayer = 2
  result.center = MapPoint(x: result.width div 2, y: result.height div 2)
  result.flagRing = 70
  result.captureClear = 210
  result.spawnClearW = 70
  result.spawnClearH = 130
  result.gunRange = 1300
  result.leftObstacles = @AfghanLeftObstacles
  ## Art: sandbagged rock and dust-caked hull.
  result.floorTex = "data/afghan_floor.png"
  result.material = ArenaMaterial(
    face: rgba(152, 128, 92, 255),
    hi: rgba(208, 184, 142, 255),
    lo: rgba(82, 66, 44, 255),
    ink: rgba(42, 34, 22, 255)
  )
  ## Med kits ride the classic center-line thirds, like the hand-authored
  ## arenas (the generated maps draw their own pair).
  result.medKitSpawns = @[
    MapPoint(x: result.width div 2, y: result.height div 3),
    MapPoint(x: result.width div 2, y: 2 * result.height div 3),
  ]
  result.medKitCandidates = result.medKitSpawns
  result.rooms = result.defaultCtfRooms()
  result.validateMap()

proc scrapyardCtfMap(): CtfMap =
  ## MW2 Scrapyard as a paintball field: two streets and a fuselage spine.
  result.name = ScrapyardName
  result.path = ScrapyardName
  result.width = 1235
  result.height = 659
  result.mapLayer = 0
  result.walkLayer = 1
  result.wallLayer = 2
  result.center = MapPoint(x: result.width div 2, y: result.height div 2)
  result.flagRing = 70
  result.captureClear = 210
  result.spawnClearW = 70
  result.spawnClearH = 130
  result.gunRange = 1300
  result.leftObstacles = @ScrapyardLeftObstacles
  ## Art: bare riveted aluminium and brick.
  result.floorTex = "data/scrapyard_floor.png"
  result.material = ArenaMaterial(
    face: rgba(140, 136, 130, 255),
    hi: rgba(198, 196, 190, 255),
    lo: rgba(74, 71, 68, 255),
    ink: rgba(36, 35, 33, 255)
  )
  ## Med kits ride the classic center-line thirds, like the hand-authored
  ## arenas (the generated maps draw their own pair).
  result.medKitSpawns = @[
    MapPoint(x: result.width div 2, y: result.height div 3),
    MapPoint(x: result.width div 2, y: 2 * result.height div 3),
  ]
  result.medKitCandidates = result.medKitSpawns
  result.rooms = result.defaultCtfRooms()
  result.validateMap()

proc teamHomeX*(gameMap: CtfMap, team: Team): int =
  ## Returns the home-edge x anchor for one team's spawn strip and pedestal.
  case team
  of Red:
    gameMap.center.x - (gameMap.center.x * 7 div 10)
  of Blue:
    gameMap.center.x + ((gameMap.width - gameMap.center.x) * 7 div 10)

proc flagHome*(gameMap: CtfMap, team: Team): MapPoint =
  ## Returns the pedestal position for one team's flag, at the center of the
  ## team's protected spawn pocket.
  MapPoint(x: gameMap.teamHomeX(team), y: gameMap.center.y)

proc mirrorX(rect: MapRect, width: int): MapRect =
  ## Mirrors one rectangle across the vertical center line of a width-px map.
  MapRect(x: width - rect.x - rect.w, y: rect.y, w: rect.w, h: rect.h)

proc mirrorX(shape: ArenaShape, width: int): ArenaShape =
  ## Mirrors one arena shape across the vertical center line of a width-px map.
  case shape.kind
  of shapeRect:
    ArenaShape(kind: shapeRect, window: shape.window,
      rect: shape.rect.mirrorX(width))
  of shapeDisc:
    ArenaShape(
      kind: shapeDisc,
      window: shape.window,
      cx: width - 1 - shape.cx,
      cy: shape.cy,
      radius: shape.radius
    )
  of shapeDiamond:
    ArenaShape(
      kind: shapeDiamond,
      window: shape.window,
      cx: width - 1 - shape.cx,
      cy: shape.cy,
      radius: shape.radius
    )
  of shapeDiagonal:
    ArenaShape(
      kind: shapeDiagonal,
      window: shape.window,
      x0: width - 1 - shape.x0,
      y0: shape.y0,
      x1: width - 1 - shape.x1,
      y1: shape.y1,
      thickness: shape.thickness
    )

proc `==`*(a, b: ArenaShape): bool =
  ## Field-wise equality (Nim derives no `==` for case objects); lets whole
  ## CtfMap values compare, which the map-spec round-trip tests rely on.
  if a.kind != b.kind or a.window != b.window:
    return false
  case a.kind
  of shapeRect:
    a.rect == b.rect
  of shapeDisc, shapeDiamond:
    a.cx == b.cx and a.cy == b.cy and a.radius == b.radius
  of shapeDiagonal:
    a.x0 == b.x0 and a.y0 == b.y0 and a.x1 == b.x1 and a.y1 == b.y1 and
      a.thickness == b.thickness

proc rot180(rect: MapRect, width, height: int): MapRect =
  ## Rotates one rectangle 180 degrees about the map center.
  MapRect(
    x: width - rect.x - rect.w,
    y: height - rect.y - rect.h,
    w: rect.w,
    h: rect.h
  )

proc rot180(shape: ArenaShape, width, height: int): ArenaShape =
  ## Rotates one arena shape 180 degrees about the map center.
  case shape.kind
  of shapeRect:
    ArenaShape(kind: shapeRect, window: shape.window,
      rect: shape.rect.rot180(width, height))
  of shapeDisc:
    ArenaShape(
      kind: shapeDisc,
      window: shape.window,
      cx: width - 1 - shape.cx,
      cy: height - 1 - shape.cy,
      radius: shape.radius
    )
  of shapeDiamond:
    ArenaShape(
      kind: shapeDiamond,
      window: shape.window,
      cx: width - 1 - shape.cx,
      cy: height - 1 - shape.cy,
      radius: shape.radius
    )
  of shapeDiagonal:
    ArenaShape(
      kind: shapeDiagonal,
      window: shape.window,
      x0: width - 1 - shape.x0,
      y0: height - 1 - shape.y0,
      x1: width - 1 - shape.x1,
      y1: height - 1 - shape.y1,
      thickness: shape.thickness
    )

proc inRect(x, y: int, rect: MapRect): bool =
  ## Returns true when (x, y) lies inside the rectangle.
  x >= rect.x and x < rect.x + rect.w and
    y >= rect.y and y < rect.y + rect.h

proc inShape*(x, y: int, shape: ArenaShape): bool =
  ## Returns true when (x, y) lies inside one arena shape.
  case shape.kind
  of shapeRect:
    inRect(x, y, shape.rect)
  of shapeDisc:
    let
      dx = x - shape.cx
      dy = y - shape.cy
    dx * dx + dy * dy <= shape.radius * shape.radius
  of shapeDiamond:
    abs(x - shape.cx) + abs(y - shape.cy) <= shape.radius
  of shapeDiagonal:
    ## Bounding-box rejection first, then point-to-segment distance in
    ## integers: (x, y) is inside when its distance to the segment is at
    ## most half the wall thickness.
    let half = shape.thickness div 2 + 1
    if x < min(shape.x0, shape.x1) - half or
        x > max(shape.x0, shape.x1) + half or
        y < min(shape.y0, shape.y1) - half or
        y > max(shape.y0, shape.y1) + half:
      false
    else:
      # 64-bit throughout: dx*dx + dy*dy reaches ~2.2e9 for these segments,
      # past int32 max, so on a 32-bit target (wasm) the plain-int form would
      # overflow. int64 is exact on every target and the comparison is unchanged.
      let
        vx = int64(shape.x1 - shape.x0)
        vy = int64(shape.y1 - shape.y0)
        wx = int64(x - shape.x0)
        wy = int64(y - shape.y0)
        len2 = vx * vx + vy * vy
        t = clamp(wx * vx + wy * vy, 0'i64, len2)
        dx = wx * len2 - t * vx
        dy = wy * len2 - t * vy
      dx * dx + dy * dy <=
        int64(shape.thickness) * int64(shape.thickness) * len2 * len2 div 4

proc buildArenaObstacles*(gameMap: CtfMap): seq[ArenaShape] =
  ## The full obstacle set, precomputed once per map selection so the
  ## per-pixel wall test never re-mirrors.
  ##
  ## Two authoring modes. A map that fills `leftObstacles` is COMPLETED BY ITS
  ## SYMMETRY (each left-half shape plus its image under x-mirror or 180°
  ## rotation) — the fairness-by-construction default the abstract arenas and
  ## every generated map use. A map that fills `fullObstacles` instead is taken
  ## VERBATIM: real-world layouts (the MW2 recreations) are asymmetric by
  ## nature — Terminal's 747 sits at one end of the concourse, Burger Town in
  ## one corner — and mirroring them would destroy the very geometry that makes
  ## the map recognizable. Such maps buy fidelity by giving up automatic
  ## symmetry, so they must balance the two approaches by hand instead.
  if gameMap.fullObstacles.len > 0:
    return gameMap.fullObstacles
  for shape in gameMap.leftObstacles:
    result.add shape
    case gameMap.symmetry
    of symMirror:
      result.add shape.mirrorX(gameMap.width)
    of symRot180:
      result.add shape.rot180(gameMap.width, gameMap.height)

proc buildAnimatedDiamonds(
  gameMap: CtfMap, obstacles: seq[ArenaShape]
): seq[tuple[cx, cy, radius: int]] =
  ## The eight diamonds flanking the center of the field (column 5 and its
  ## x-mirror): drawn as slowly rotating sprites instead of baked wall art.
  ## COLLISION, LOS, and the fog masks keep the exact static diamond — the
  ## spin is pure decoration and never enters gameHash.
  for shape in obstacles:
    if shape.kind == shapeDiamond and
        abs(shape.cx - gameMap.center.x) < 80:
      result.add((shape.cx, shape.cy, shape.radius))

## ---------------------------------------------------------------------------
## Procedural terrain (GameVersion 25). Canonical play draws a validated map
## from the curated pool (map_pool.nim); mapPath "gen" generates straight from
## a seed. Every layout is authored for the LEFT half only and completed by
## the map's symmetry, so team fairness is structural. The generator is fully
## deterministic (own splitmix64, never std/random) so one seed names one map
## on every platform, including wasm.
## ---------------------------------------------------------------------------

const
  GenMapName* = "gen"
  PoolMapName* = "pool"
  MinCorridorWidth = 26      ## narrowest corridor for the 13px footprint.
  MapGenMaxAttempts = 100
  MapSizeNames = ["small", "standard", "large"]
  CenterFeatureNames = ["bracket", "ring", "walls"]
  ## Interior cover budget, in permille of the non-protected interior that is
  ## obstacle wall. The hand-tuned arena sits inside this band; layouts
  ## outside it play too open or too clogged and are re-rolled.
  CoverPermilleMin = 40
  CoverPermilleMax = 170

type
  MapRng = object
    state: uint64

  ColumnFamily = enum
    colStubs        ## 18px-wide rect stubs, border-anchored at the ends.
    colDiamonds
    colDiscs
    colChevrons     ## 45-degree zigzag wall segments.

proc next(rng: var MapRng): uint64 =
  ## splitmix64: tiny, statistically solid, identical on every target.
  rng.state = rng.state + 0x9E3779B97F4A7C15'u64
  var z = rng.state
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc pick(rng: var MapRng, bound: int): int =
  ## Uniform 0..bound-1 (modulo bias is immaterial at these bounds).
  int(rng.next() mod uint64(bound))

proc pickRange(rng: var MapRng, lo, hi: int): int =
  lo + rng.pick(hi - lo + 1)

proc coin(rng: var MapRng): bool =
  (rng.next() and 1'u64) == 1

proc shuffle[T](rng: var MapRng, items: var seq[T]) =
  for i in countdown(items.high, 1):
    let j = rng.pick(i + 1)
    swap(items[i], items[j])

proc scaledGenShell(sizeName: string): CtfMap =
  ## Field dimensions and clearances for one size class: the standard-arena
  ## numbers scaled by the class factor. Obstacle SIZES never scale — bigger
  ## fields get roomier corridors, exactly like arena-large.
  let scale =
    case sizeName
    of "small": 0.85
    of "standard": 1.0
    of "large": 1.3
    else:
      raise newException(CtfError, "Unknown map size: " & sizeName)
  proc s(value: int): int = int(round(float(value) * scale))
  result.width = s(1235)
  result.height = s(659)
  result.mapLayer = 0
  result.walkLayer = 1
  result.wallLayer = 2
  result.center = MapPoint(x: result.width div 2, y: result.height div 2)
  result.flagRing = s(70)
  result.captureClear = s(210)
  result.spawnClearW = s(70)
  result.spawnClearH = s(130)
  result.gunRange = s(1300)
  result.rooms = result.defaultCtfRooms()

proc mapProtectedFloorAt*(gameMap: CtfMap, x, y: int): bool =
  ## isProtectedFloor for a map that is NOT installed as the process map:
  ## the generator and validators run on candidates before any selection.
  if x < gameMap.captureClear or x >= gameMap.width - gameMap.captureClear:
    return true
  let
    dx = x - gameMap.center.x
    dy = y - gameMap.center.y
  if dx * dx + dy * dy <= gameMap.flagRing * gameMap.flagRing:
    return true
  for team in Team:
    if abs(x - gameMap.teamHomeX(team)) <= gameMap.spawnClearW and
        abs(y - gameMap.center.y) <= gameMap.spawnClearH:
      return true
  false

proc mapWallAt*(gameMap: CtfMap, obstacles: seq[ArenaShape], x, y: int): bool =
  ## Uninstalled-map wall test, matching isArenaWall's border + carve rules.
  if x < ArenaBorder or y < ArenaBorder or
      x >= gameMap.width - ArenaBorder or y >= gameMap.height - ArenaBorder:
    return true
  if mapProtectedFloorAt(gameMap, x, y):
    return false
  for shape in obstacles:
    if inShape(x, y, shape):
      return true
  false

proc generateMapAttempt*(seed: int, overrides: MapGenOverrides): CtfMap =
  ## One UNVALIDATED draw. Every top-level parameter is drawn unconditionally
  ## and THEN overridden if locked, so locking one knob never shifts the
  ## other draws for the same seed.
  var rng = MapRng(state: uint64(seed))

  let sizeDraw = MapSizeNames[rng.pick(3)]
  result = scaledGenShell(
    if overrides.size.len > 0: overrides.size else: sizeDraw)
  result.name = "gen-" & $seed
  result.path = GenMapName
  result.genSeed = seed

  let symDraw = if rng.coin(): symRot180 else: symMirror
  result.symmetry =
    case overrides.symmetry
    of "": symDraw
    of "mirror": symMirror
    of "rot180": symRot180
    else:
      raise newException(
        CtfError, "Unknown map symmetry: " & overrides.symmetry)

  let featureDraw = CenterFeatureNames[rng.pick(3)]
  let feature =
    if overrides.centerFeature.len > 0: overrides.centerFeature
    else: featureDraw
  if feature notin CenterFeatureNames:
    raise newException(CtfError, "Unknown map center feature: " & feature)

  let columnsDraw = rng.pickRange(4, 6)
  let columns =
    if overrides.columns > 0: overrides.columns else: columnsDraw
  if columns < 3 or columns > 8:
    raise newException(CtfError, "Config field mapColumns must be 3..8.")

  let
    cy = result.center.y
    ## Obstacle columns live between the capture column and the flag-ring
    ## flank; the ring itself carves any overlap back out of the wall mask.
    xMin = result.captureClear + 50
    xMax = result.center.x - 52
  ## Window-eligible shapes: (obstacle index, column, slot y).
  var eligible: seq[tuple[idx, col, y: int]]

  for col in 0 ..< columns:
    let
      colX = xMin + ((2 * col + 1) * (xMax - xMin)) div (2 * columns)
      family = ColumnFamily(rng.pick(4))
      period = rng.pickRange(88, 120)
      ## Phases are STRATIFIED across columns (like the hand-authored
      ## arena's 0/+48/+24/+72 ladder) with a half-period jitter: fully
      ## random phases leave rows every column misses, which the sightline
      ## validator rejects — mirror-symmetric maps almost never survived.
      phase = (period * col div columns +
        rng.pick(max(1, period div 2))) mod period
    var slotYs: seq[int]
    var slotY = ArenaBorder + 30 + phase
    while slotY <= result.height - ArenaBorder - 30:
      slotYs.add slotY
      slotY += period
    if slotYs.len < 3:
      continue

    ## Clear-mask: drop each slot with probability 1/4, then guarantee at
    ## least one gap (a solid picket walls the lane off) and at least half
    ## the slots kept (a bare column gives no cover).
    var cleared = newSeq[bool](slotYs.len)
    var clearedCount = 0
    for i in 0 ..< slotYs.len:
      if rng.pick(4) == 0:
        cleared[i] = true
        inc clearedCount
    if clearedCount == 0:
      cleared[rng.pick(slotYs.len)] = true
      clearedCount = 1
    let minKept = (slotYs.len + 1) div 2
    while slotYs.len - clearedCount < minKept and clearedCount > 1:
      var idx = rng.pick(slotYs.len)
      while not cleared[idx]:
        idx = (idx + 1) mod slotYs.len
      cleared[idx] = false
      dec clearedCount

    var zig = rng.coin()
    for i, sy in slotYs:
      if cleared[i]:
        continue
      case family
      of colStubs:
        ## Stub ends whose border gap would drop under the corridor minimum
        ## anchor to the border instead — a sub-26px slit is impassable
        ## anyway and reads as a wart.
        var top = sy - 30
        var bottom = sy + 30
        if i == 0 and top - ArenaBorder < MinCorridorWidth:
          top = ArenaBorder
        if i == slotYs.len - 1 and
            result.height - ArenaBorder - bottom < MinCorridorWidth:
          bottom = result.height - ArenaBorder
        result.leftObstacles.add ArenaShape(kind: shapeRect,
          rect: MapRect(x: colX - 9, y: top, w: 18, h: bottom - top))
        eligible.add (result.leftObstacles.high, col, sy)
      of colDiamonds:
        result.leftObstacles.add ArenaShape(
          kind: shapeDiamond, cx: colX, cy: sy, radius: 28)
        eligible.add (result.leftObstacles.high, col, sy)
      of colDiscs:
        result.leftObstacles.add ArenaShape(
          kind: shapeDisc, cx: colX, cy: sy, radius: 28)
        eligible.add (result.leftObstacles.high, col, sy)
      of colChevrons:
        let (ya, yb) = if zig: (sy - 14, sy + 14) else: (sy + 14, sy - 14)
        result.leftObstacles.add ArenaShape(kind: shapeDiagonal,
          x0: colX - 14, y0: ya, x1: colX + 14, y1: yb, thickness: 12)
        zig = not zig

  ## Center feature, straddling the horizontal midline just outside the
  ## flag ring ("[" here; its symmetry image closes the right side).
  let bx = result.center.x - 138
  case feature
  of "bracket":
    ## The GV16 windowed bracket: mid lane closed to movement and fire,
    ## glass pane over the midline for a fogless center sightline.
    result.leftObstacles.add ArenaShape(kind: shapeRect,
      rect: MapRect(x: bx, y: cy - 53, w: 28, h: 12))
    result.leftObstacles.add ArenaShape(kind: shapeRect,
      rect: MapRect(x: bx, y: cy - 41, w: 12, h: 24))
    result.leftObstacles.add ArenaShape(kind: shapeRect, window: true,
      rect: MapRect(x: bx, y: cy - 17, w: 12, h: 36))
    result.leftObstacles.add ArenaShape(kind: shapeRect,
      rect: MapRect(x: bx, y: cy + 19, w: 12, h: 23))
    result.leftObstacles.add ArenaShape(kind: shapeRect,
      rect: MapRect(x: bx, y: cy + 42, w: 28, h: 12))
  of "walls":
    ## Solid bar pair with an open (glassless) midline gap.
    result.leftObstacles.add ArenaShape(kind: shapeRect,
      rect: MapRect(x: bx, y: cy - 100, w: 12, h: 80))
    result.leftObstacles.add ArenaShape(kind: shapeRect,
      rect: MapRect(x: bx, y: cy + 20, w: 12, h: 80))
  else:
    discard  # "ring": the center stays fully open.

  ## Sightline repair. A horizontal ray survives when no obstacle blocks its
  ## row: under MIRROR the right half repeats the left, so the LEFT half
  ## alone must cover every row; under ROT180 the right half contributes the
  ## flipped rows, so row y needs cover at y or height-1-y. Random layouts
  ## almost never satisfy the mirror condition on their own (the first pool
  ## scan came out 100% rot180), so plug the uncovered rows with diamonds in
  ## drawn columns; the validators still judge the repaired result.
  block sightlineRepair:
    proc rowBlocked(gameMap: CtfMap, y: int): bool =
      for x in gameMap.captureClear + 5 .. gameMap.center.x:
        if mapWallAt(gameMap, gameMap.leftObstacles, x, y):
          return true
      false
    var plugsLeft = 40
    while plugsLeft > 0:
      var uncovered = -1
      var y = ArenaBorder + 2
      while y < result.height - ArenaBorder:
        let covered =
          case result.symmetry
          of symMirror:
            result.rowBlocked(y)
          of symRot180:
            result.rowBlocked(y) or
              result.rowBlocked(result.height - 1 - y)
        if not covered:
          uncovered = y
          break
        y += 4
      if uncovered < 0:
        break sightlineRepair
      let
        plugCol = rng.pick(columns)
        plugX = xMin + ((2 * plugCol + 1) * (xMax - xMin)) div (2 * columns)
        plugY = clamp(
          uncovered + 24, ArenaBorder + 12, result.height - ArenaBorder - 12)
      result.leftObstacles.add ArenaShape(
        kind: shapeDiamond, cx: plugX, cy: plugY, radius: 28)
      dec plugsLeft

  ## Glass windows: fog sees through them, nothing passes them. Biased to
  ## the outermost column and the midline band, where sightlines matter.
  let windowsDraw = rng.pickRange(2, 4)
  let windowCount =
    if overrides.windows >= 0: overrides.windows else: windowsDraw
  if windowCount > 6:
    raise newException(CtfError, "Config field mapWindows must be 0..6.")
  var preferred, rest: seq[tuple[idx, col, y: int]]
  for entry in eligible:
    if entry.col == 0 or abs(entry.y - cy) < 70:
      preferred.add entry
    else:
      rest.add entry
  rng.shuffle(preferred)
  rng.shuffle(rest)
  let ranked = preferred & rest
  for i in 0 ..< min(windowCount, ranked.len):
    result.leftObstacles[ranked[i].idx].window = true

  ## Med kits: two complementary (y, H-1-y) center-line pairs are drawn as
  ## candidates and ONE pair goes active. A top/bottom pair on x = W/2 is
  ## invariant under both mirror and rot180, so pickup fairness is exact.
  let
    mid = result.width div 2
    y1 = rng.pickRange(result.height * 16 div 100, result.height * 34 div 100)
    y2 = rng.pickRange(result.height * 36 div 100, result.height * 47 div 100)
  result.medKitCandidates = @[
    MapPoint(x: mid, y: y1),
    MapPoint(x: mid, y: result.height - 1 - y1),
    MapPoint(x: mid, y: y2),
    MapPoint(x: mid, y: result.height - 1 - y2),
  ]
  result.medKitSpawns =
    if rng.coin():
      @[result.medKitCandidates[0], result.medKitCandidates[1]]
    else:
      @[result.medKitCandidates[2], result.medKitCandidates[3]]
  result.validateMap()

proc validateGeneratedMap*(gameMap: CtfMap): string =
  ## Returns "" when the layout passes every play-quality invariant, else a
  ## human-readable failure reason. The generator's design intent lives HERE,
  ## not in the draws: anything that passes is fair game.
  let
    w = gameMap.width
    h = gameMap.height
    obstacles = buildArenaObstacles(gameMap)
  var wallMask = newSeq[bool](w * h)
  var coverPixels, interiorPixels = 0
  for y in 0 ..< h:
    for x in 0 ..< w:
      let isWall = mapWallAt(gameMap, obstacles, x, y)
      wallMask[y * w + x] = isWall
      if x >= gameMap.captureClear and x < w - gameMap.captureClear and
          y >= ArenaBorder and y < h - ArenaBorder:
        inc interiorPixels
        if isWall:
          inc coverPixels

  ## Cover budget: neither an open field nor a clogged maze.
  let permille = coverPixels * 1000 div max(1, interiorPixels)
  if permille < CoverPermilleMin:
    return "too open: " & $permille & " permille cover"
  if permille > CoverPermilleMax:
    return "too clogged: " & $permille & " permille cover"

  ## With map-wide guns no straight horizontal ray may survive between the
  ## capture columns (the property tests/test_map_los.nim pins for arena).
  block sightlines:
    let
      ax = gameMap.captureClear + 5
      bx = w - gameMap.captureClear - 5
    var y = ArenaBorder + 2
    while y < h - ArenaBorder:
      var blocked = false
      for x in ax .. bx:
        if wallMask[y * w + x]:
          blocked = true
          break
      if not blocked:
        return "open horizontal sightline at y=" & $y
      y += 4

  ## Corridor + connectivity: chamfer 3-4 distance to the nearest wall,
  ## eroded by half the corridor minimum, then a flood fill — both flags and
  ## the center must connect through corridors the player footprint can
  ## actually use.
  var dist = newSeq[int32](w * h)
  for i in 0 ..< w * h:
    dist[i] = if wallMask[i]: 0'i32 else: int32.high div 2
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = y * w + x
      if dist[i] == 0:
        continue
      var d = dist[i]
      if x > 0: d = min(d, dist[i - 1] + 3)
      if y > 0: d = min(d, dist[i - w] + 3)
      if x > 0 and y > 0: d = min(d, dist[i - w - 1] + 4)
      if x < w - 1 and y > 0: d = min(d, dist[i - w + 1] + 4)
      dist[i] = d
  for y in countdown(h - 1, 0):
    for x in countdown(w - 1, 0):
      let i = y * w + x
      if dist[i] == 0:
        continue
      var d = dist[i]
      if x < w - 1: d = min(d, dist[i + 1] + 3)
      if y < h - 1: d = min(d, dist[i + w] + 3)
      if x < w - 1 and y < h - 1: d = min(d, dist[i + w + 1] + 4)
      if x > 0 and y < h - 1: d = min(d, dist[i + w - 1] + 4)
      dist[i] = d
  let minChamfer = int32((MinCorridorWidth div 2) * 3)
  var open = newSeq[bool](w * h)
  for i in 0 ..< w * h:
    open[i] = dist[i] >= minChamfer

  let
    redHome = gameMap.flagHome(Red)
    blueHome = gameMap.flagHome(Blue)
    startIndex = redHome.y * w + redHome.x
  var
    reached = newSeq[bool](w * h)
    queue = @[startIndex]
  if not open[startIndex]:
    return "red flag home is not on open floor"
  reached[startIndex] = true
  var head = 0
  while head < queue.len:
    let i = queue[head]
    inc head
    for step in [-1, 1, -w, w]:
      let j = i + step
      if j >= 0 and j < w * h and open[j] and not reached[j]:
        ## Row wrap at the border can't happen: the border ring is wall,
        ## so open[] is false along every edge.
        reached[j] = true
        queue.add j
  if not reached[blueHome.y * w + blueHome.x]:
    return "no " & $MinCorridorWidth & "px route between the flags"
  if not reached[gameMap.center.y * w + gameMap.center.x]:
    return "no " & $MinCorridorWidth & "px route to the center"
  ""

proc generateCtfMap*(
  seed: int, overrides = MapGenOverrides(windows: -1)
): CtfMap =
  ## Generates a VALIDATED map: attempts seeds seed, seed+1, ... until one
  ## passes every validator. A locked-parameter combination that can never
  ## pass errors out after MapGenMaxAttempts.
  for attempt in 0 ..< MapGenMaxAttempts:
    let candidate = generateMapAttempt(seed + attempt, overrides)
    if validateGeneratedMap(candidate).len == 0:
      return candidate
  raise newException(
    CtfError,
    "Map generation found no valid layout in " & $MapGenMaxAttempts &
      " attempts from seed " & $seed & " (over-constrained overrides?)."
  )

proc poolCtfMap*(
  index: int, overrides = MapGenOverrides(windows: -1)
): CtfMap =
  ## One curated-pool map; the index wraps around the pool.
  let n = MapPoolSeeds.len
  generateCtfMap(MapPoolSeeds[((index mod n) + n) mod n], overrides)

proc shapeSpecNode(shape: ArenaShape): JsonNode =
  ## One obstacle as replay-spec JSON.
  result = newJObject()
  case shape.kind
  of shapeRect:
    result["kind"] = %"rect"
    result["x"] = %shape.rect.x
    result["y"] = %shape.rect.y
    result["w"] = %shape.rect.w
    result["h"] = %shape.rect.h
  of shapeDisc, shapeDiamond:
    result["kind"] = %(if shape.kind == shapeDisc: "disc" else: "diamond")
    result["cx"] = %shape.cx
    result["cy"] = %shape.cy
    result["r"] = %shape.radius
  of shapeDiagonal:
    result["kind"] = %"diagonal"
    result["x0"] = %shape.x0
    result["y0"] = %shape.y0
    result["x1"] = %shape.x1
    result["y1"] = %shape.y1
    result["t"] = %shape.thickness
  if shape.window:
    result["window"] = %true

proc shapeFromSpecNode(node: JsonNode): ArenaShape =
  ## One obstacle parsed back from replay-spec JSON.
  let window = node{"window"}.getBool(false)
  case node["kind"].getStr()
  of "rect":
    ArenaShape(kind: shapeRect, window: window, rect: MapRect(
      x: node["x"].getInt(), y: node["y"].getInt(),
      w: node["w"].getInt(), h: node["h"].getInt()))
  of "disc":
    ArenaShape(kind: shapeDisc, window: window,
      cx: node["cx"].getInt(), cy: node["cy"].getInt(),
      radius: node["r"].getInt())
  of "diamond":
    ArenaShape(kind: shapeDiamond, window: window,
      cx: node["cx"].getInt(), cy: node["cy"].getInt(),
      radius: node["r"].getInt())
  of "diagonal":
    ArenaShape(kind: shapeDiagonal, window: window,
      x0: node["x0"].getInt(), y0: node["y0"].getInt(),
      x1: node["x1"].getInt(), y1: node["y1"].getInt(),
      thickness: node["t"].getInt())
  else:
    raise newException(
      CtfError, "Unknown map spec shape: " & node["kind"].getStr())

proc pointsNode(points: seq[MapPoint]): JsonNode =
  result = newJArray()
  for p in points:
    result.add %*[p.x, p.y]

proc pointsFromNode(node: JsonNode): seq[MapPoint] =
  for item in node:
    result.add MapPoint(x: item[0].getInt(), y: item[1].getInt())

proc mapSpecJson*(gameMap: CtfMap): string =
  ## The FULL expanded geometry of one map as JSON. Replays pin this, so
  ## playback rebuilds the exact map even if the generator changes later.
  var shapes = newJArray()
  for shape in gameMap.leftObstacles:
    shapes.add shape.shapeSpecNode()
  $(%*{
    "name": gameMap.name,
    "genSeed": gameMap.genSeed,
    "width": gameMap.width,
    "height": gameMap.height,
    "flagRing": gameMap.flagRing,
    "captureClear": gameMap.captureClear,
    "spawnClearW": gameMap.spawnClearW,
    "spawnClearH": gameMap.spawnClearH,
    "gunRange": gameMap.gunRange,
    "symmetry": (
      if gameMap.symmetry == symMirror: "mirror" else: "rot180"),
    "medKitSpawns": pointsNode(gameMap.medKitSpawns),
    "medKitCandidates": pointsNode(gameMap.medKitCandidates),
    "leftObstacles": shapes,
  })

proc mapFromSpecJson*(text: string): CtfMap =
  ## Rebuilds one map from its expanded replay spec. Rooms are derived from
  ## the clearances the same way the generator derives them.
  var node: JsonNode
  try:
    node = fromJson(text)
  except jsony.JsonError as e:
    raise newException(CtfError, "Could not parse map spec JSON: " & e.msg)
  result.name = node["name"].getStr()
  result.path = GenMapName
  result.genSeed = node{"genSeed"}.getInt(0)
  result.width = node["width"].getInt()
  result.height = node["height"].getInt()
  result.mapLayer = 0
  result.walkLayer = 1
  result.wallLayer = 2
  result.center = MapPoint(x: result.width div 2, y: result.height div 2)
  result.flagRing = node["flagRing"].getInt()
  result.captureClear = node["captureClear"].getInt()
  result.spawnClearW = node["spawnClearW"].getInt()
  result.spawnClearH = node["spawnClearH"].getInt()
  result.gunRange = node["gunRange"].getInt()
  result.symmetry =
    if node{"symmetry"}.getStr("mirror") == "rot180": symRot180
    else: symMirror
  result.medKitSpawns = pointsFromNode(node["medKitSpawns"])
  result.medKitCandidates = pointsFromNode(node["medKitCandidates"])
  for item in node["leftObstacles"]:
    result.leftObstacles.add item.shapeFromSpecNode()
  result.rooms = result.defaultCtfRooms()
  result.validateMap()

proc resolveCtfMapMetadata*(config: GameConfig): CtfMap =
  ## The effective map for one config: an explicit mapSpec wins (replay
  ## exactness), then the named maps (the two arenas plus the MW2 pack), then
  ## the generator / curated pool. `config.mapPath` is always a CONCRETE name
  ## by this point — the "mw2" rotation alias resolved in GameConfig.update.
  if config.mapSpec.len > 0:
    return mapFromSpecJson(config.mapSpec)
  let
    name = if config.mapPath.len == 0: DefaultMapPath else: config.mapPath
    genSeed = if config.mapSeed != -1: config.mapSeed else: config.seed
  case name
  of ArenaName: arenaCtfMap()
  of ArenaLargeName: arenaLargeCtfMap()
  of RustName: rustCtfMap()
  of TerminalName: terminalCtfMap()
  of HighriseName: highriseCtfMap()
  of FavelaName: favelaCtfMap()
  of AfghanName: afghanCtfMap()
  of ScrapyardName: scrapyardCtfMap()
  of GenMapName: generateCtfMap(genSeed, config.mapGen)
  of PoolMapName:
    let index =
      if config.mapPoolIndex >= 0: config.mapPoolIndex else: genSeed
    poolCtfMap(index, config.mapGen)
  else:
    raise newException(CtfError, "Unknown map: " & name)

## The COVER MATERIAL is per-map (installed by selectCtfMap from the selected
## map's `material`), so an arena's props read as its own scenery — rusted
## sheet metal on the oil yard, white terminal panel, poured concrete on the
## rooftop, painted plywood in the favela, sandbagged rock in the desert,
## bare aluminium in the boneyard. The default arena keeps the original warm
## carved-stone values exactly, so its art is byte-identical to before.
var
  StoneFace = rgba(120, 100, 78, 255)    ## flat top face of a raised block.
  StoneHi = rgba(190, 167, 137, 255)     ## up-left lit bevel (catches the light).
  StoneLo = rgba(68, 54, 41, 255)        ## down-right shaded bevel (falls to dark).
  StoneInk = rgba(34, 26, 19, 255)       ## warm near-black carve line (never #000).

## The SELECTED map's layout, installed once per process by loadCtfMap and
## initialized to the default arena below so tooling that never selects a
## map observes a complete default state, never an empty one.
var
  ArenaFlagRing = 70
  ArenaCaptureClear = 210
  ArenaSpawnClearW = 70
  ArenaSpawnClearH = 130
  ArenaRedHomeX = 186
  ArenaBlueHomeX = 1049
  ArenaObstacles*: seq[ArenaShape]
  AnimatedDiamonds*: seq[tuple[cx, cy, radius: int]]
  ArenaFloorTex* = DefaultFloorTex  ## data/ path of the selected map's floor.
  ArenaCarveClear = 210  ## width of the always-floor home column (px).

proc selectCtfMap(gameMap: CtfMap) =
  ## Installs one map as THE map for this process: dimensions, fog grid,
  ## map-relative ranges, layout clearances, and the mirrored obstacle set.
  ## Runs before any sim, mask, or render work; the render bakes in
  ## global.nim assume the arena never changes afterward.
  MapWidth = gameMap.width
  MapHeight = gameMap.height
  FovGridW = (MapWidth + FovCellSize - 1) div FovCellSize
  FovGridH = (MapHeight + FovCellSize - 1) div FovCellSize
  FovCellCount = FovGridW * FovGridH
  GrenadeMaxRange = MapWidth div 5
  ShoutRange = MapWidth div 5
  ArenaFlagRing = gameMap.flagRing
  ArenaCaptureClear = gameMap.captureClear
  ArenaCarveClear =
    if gameMap.carveClear > 0: gameMap.carveClear else: gameMap.captureClear
  ArenaSpawnClearW = gameMap.spawnClearW
  ArenaSpawnClearH = gameMap.spawnClearH
  ArenaRedHomeX = gameMap.teamHomeX(Red)
  ArenaBlueHomeX = gameMap.teamHomeX(Blue)
  ArenaObstacles = buildArenaObstacles(gameMap)
  AnimatedDiamonds = buildAnimatedDiamonds(gameMap, ArenaObstacles)
  ## Per-map ART. A map that declares no material keeps the default arena's
  ## warm carved stone, so the original arena renders byte-identically.
  ArenaFloorTex =
    if gameMap.floorTex.len > 0: gameMap.floorTex
    else: DefaultFloorTex
  if gameMap.material.face.a > 0:
    StoneFace = gameMap.material.face
    StoneHi = gameMap.material.hi
    StoneLo = gameMap.material.lo
    StoneInk = gameMap.material.ink
  else:
    StoneFace = rgba(120, 100, 78, 255)
    StoneHi = rgba(190, 167, 137, 255)
    StoneLo = rgba(68, 54, 41, 255)
    StoneInk = rgba(34, 26, 19, 255)

selectCtfMap(arenaCtfMap())

proc loadCtfMapMetadata*(path = ""): CtfMap =
  ## Returns one map's metadata WITHOUT installing it as the process map.
  ## Accepts "arena", "arena-large", the six MW2 pack names, "gen[:seed]",
  ## and "pool[:index]" (the suffix-less generated forms use seed/index 0);
  ## tooling convenience — servers resolve through the GameConfig overload
  ## instead. The "mw2" ROTATION ALIAS is NOT accepted here: it is resolved
  ## at config time, so the registry only ever sees concrete maps.
  let name = if path.len == 0: DefaultMapPath else: path
  case name
  of ArenaName: arenaCtfMap()
  of ArenaLargeName: arenaLargeCtfMap()
  of RustName: rustCtfMap()
  of TerminalName: terminalCtfMap()
  of HighriseName: highriseCtfMap()
  of FavelaName: favelaCtfMap()
  of AfghanName: afghanCtfMap()
  of ScrapyardName: scrapyardCtfMap()
  else:
    let parts = name.split(':')
    var suffix = 0
    if parts.len == 2:
      try:
        suffix = parseInt(parts[1])
      except ValueError:
        raise newException(CtfError, "Unknown map: " & name)
    if parts.len <= 2 and parts[0] == GenMapName:
      generateCtfMap(suffix)
    elif parts.len <= 2 and parts[0] == PoolMapName:
      poolCtfMap(suffix)
    else:
      raise newException(CtfError, "Unknown map: " & name)

proc loadCtfMapMetadata*(config: GameConfig): CtfMap =
  ## GameConfig-driven metadata: honors mapSpec, mapSeed, pool picks, and
  ## the generator overrides.
  resolveCtfMapMetadata(config)

proc loadCtfMap*(path = ""): CtfMap =
  ## Returns the named map ("arena" is the default; "arena-large" is the
  ## 30%-larger variant; "gen:<seed>"/"pool:<index>" the generated forms)
  ## and installs it as this process's arena.
  result = loadCtfMapMetadata(path)
  selectCtfMap(result)

proc loadCtfMap*(config: GameConfig): CtfMap =
  ## Resolves the config's effective map and installs it as this process's
  ## arena.
  result = resolveCtfMapMetadata(config)
  selectCtfMap(result)

proc isAnimatedDiamondPixel*(x, y: int): bool =
  ## Returns true when (x, y) lies inside one of the rotating center
  ## diamonds (their art is drawn as live objects, not baked wall).
  for spot in AnimatedDiamonds:
    if abs(x - spot.cx) + abs(y - spot.cy) <= spot.radius:
      return true
  false

proc inShapeF*(x, y: float, shape: ArenaShape): bool =
  ## Float-coordinate inShape: the render-scale rasterizer evaluates the same
  ## geometry at sub-pixel positions for crisp high-resolution wall edges.
  ## Collision and FOV keep using the integer predicate; the two may disagree
  ## by less than one map pixel along shape boundaries, which is invisible.
  case shape.kind
  of shapeRect:
    x >= float(shape.rect.x) and x < float(shape.rect.x + shape.rect.w) and
      y >= float(shape.rect.y) and y < float(shape.rect.y + shape.rect.h)
  of shapeDisc:
    let
      dx = x - float(shape.cx)
      dy = y - float(shape.cy)
    dx * dx + dy * dy <= float(shape.radius * shape.radius)
  of shapeDiamond:
    abs(x - float(shape.cx)) + abs(y - float(shape.cy)) <=
      float(shape.radius)
  of shapeDiagonal:
    let
      vx = float(shape.x1 - shape.x0)
      vy = float(shape.y1 - shape.y0)
      wx = x - float(shape.x0)
      wy = y - float(shape.y0)
      len2 = vx * vx + vy * vy
      t = clamp(wx * vx + wy * vy, 0.0, len2)
      dx = wx * len2 - t * vx
      dy = wy * len2 - t * vy
    dx * dx + dy * dy <=
      float(shape.thickness * shape.thickness) * len2 * len2 / 4.0

proc isProtectedFloor(x, y, cx, cy: int): bool =
  ## Regions that MUST stay walkable: the flag ring, both spawn pockets,
  ## and the two home capture columns. Walls are never carved here.
  ##
  ## ArenaCarveClear is the width of the always-floor home column. The
  ## abstract arenas keep it equal to the full capture zone, which forbids any
  ## cover in the outer sixth of the map; the recreated maps shrink it to just
  ## the pedestal apron so real building footprints can sit where they really
  ## do, and instead keep their spawn lanes open by hand.
  if x < ArenaCarveClear or x >= MapWidth - ArenaCarveClear:
    return true
  let
    dx = x - cx
    dy = y - cy
  if dx * dx + dy * dy <= ArenaFlagRing * ArenaFlagRing:
    return true
  for homeX in [ArenaRedHomeX, ArenaBlueHomeX]:
    if abs(x - homeX) <= ArenaSpawnClearW and abs(y - cy) <= ArenaSpawnClearH:
      return true
  false

proc isArenaWall(x, y, cx, cy: int): bool =
  ## Returns true when (x, y) is a wall pixel on the generated arena.
  if x < ArenaBorder or y < ArenaBorder or
      x >= MapWidth - ArenaBorder or y >= MapHeight - ArenaBorder:
    return true
  if isProtectedFloor(x, y, cx, cy):
    return false
  for shape in ArenaObstacles:
    if inShape(x, y, shape):
      return true
  false

proc isArenaWindowPixel*(x, y, cx, cy: int): bool =
  ## Returns true when (x, y) is a GLASS pixel: a wall pixel that belongs to a
  ## window shape. Glass stays in the collision/shot wall mask but is excluded
  ## from the fog-of-war occlusion build, so vision passes through it.
  if not isArenaWall(x, y, cx, cy):
    return false
  for shape in ArenaObstacles:
    if shape.window and inShape(x, y, shape):
      return true
  false

proc isProtectedFloorF(x, y: float, cx, cy: int): bool =
  ## Float-coordinate isProtectedFloor for the render-scale rasterizer.
  if x < float(ArenaCarveClear) or
      x >= float(MapWidth - ArenaCarveClear):
    return true
  let
    dx = x - float(cx)
    dy = y - float(cy)
  if dx * dx + dy * dy <= float(ArenaFlagRing * ArenaFlagRing):
    return true
  for homeX in [float(ArenaRedHomeX), float(ArenaBlueHomeX)]:
    if abs(x - homeX) <= float(ArenaSpawnClearW) and
        abs(y - float(cy)) <= float(ArenaSpawnClearH):
      return true
  false

proc obstacleWallAtF*(x, y: float, cx, cy: int): bool =
  ## Float-coordinate interior-obstacle test (the border ring excluded);
  ## the high-resolution renderer draws the border as separate slabs.
  if isProtectedFloorF(x, y, cx, cy):
    return false
  for shape in ArenaObstacles:
    if inShapeF(x, y, shape):
      return true
  false

proc shapeWallAtF*(x, y: float, shape: ArenaShape, cx, cy: int): bool =
  ## Float-coordinate test for one shape with the protected-floor carve
  ## applied, matching what the integer wall mask keeps of that shape.
  inShapeF(x, y, shape) and not isProtectedFloorF(x, y, cx, cy)

proc overTint(base, tint: ColorRGBA): ColorRGBA =
  ## Alpha-composites a translucent tint over an opaque base color.
  let a = tint.a.int
  rgba(
    uint8((base.r.int * (255 - a) + tint.r.int * a) div 255),
    uint8((base.g.int * (255 - a) + tint.g.int * a) div 255),
    uint8((base.b.int * (255 - a) + tint.b.int * a) div 255),
    255
  )

proc tileSample(tex: Image, x, y: int): ColorRGBA =
  ## Samples a seamless texture tiled across the arena (opaque source).
  tex.unsafe[x mod tex.width, y mod tex.height].rgba

proc tileSampleF(tex: Image, fx, fy: float): ColorRGBA =
  ## Bilinear tile sample at a fractional map-pixel coordinate (wrapping).
  ## The texture still tiles 1:1 with LOGICAL map pixels — a scale× renderer
  ## passes fractional coords, so the flagstone keeps its 1× world size but
  ## resolves smoothly between texels. At integer-center coords this returns
  ## exactly tileSample's nearest texel.
  let
    sx = fx - 0.5
    sy = fy - 0.5
    fx0 = floor(sx)
    fy0 = floor(sy)
    tx = sx - fx0
    ty = sy - fy0
    xa = ((int(fx0) mod tex.width) + tex.width) mod tex.width
    xb = (xa + 1) mod tex.width
    ya = ((int(fy0) mod tex.height) + tex.height) mod tex.height
    yb = (ya + 1) mod tex.height
    c00 = tex.unsafe[xa, ya].rgba
    c10 = tex.unsafe[xb, ya].rgba
    c01 = tex.unsafe[xa, yb].rgba
    c11 = tex.unsafe[xb, yb].rgba
  template lerp(a, b: uint8, t: float): float =
    a.float + (b.float - a.float) * t
  rgba(
    uint8(lerp(c00.r, c10.r, tx) + (lerp(c01.r, c11.r, tx) - lerp(c00.r, c10.r, tx)) * ty),
    uint8(lerp(c00.g, c10.g, tx) + (lerp(c01.g, c11.g, tx) - lerp(c00.g, c10.g, tx)) * ty),
    uint8(lerp(c00.b, c10.b, tx) + (lerp(c01.b, c11.b, tx) - lerp(c00.b, c10.b, tx)) * ty),
    255
  )

const PedestalDimFactor = 0.34
  ## How dark the powered-down (cold) pedestal disc goes: each lit pixel's RGB is
  ## scaled to this fraction so the disc reads as an unlit socket, not a bright
  ## team light, when the heart has been carried away. Alpha is untouched so the
  ## textured floor still shows through the same silhouette.

proc pedestalDimmed(spr: Image): Image =
  ## Returns a copy of a pedestal sprite with its RGB scaled down (alpha kept), so
  ## the "cold" map shows the pedestal powered down. The broadcast glow-fade
  ## crossfades the lit pedestal toward this, so the disc dims when the heart is
  ## taken and re-lights when it comes home. Pixie stores premultiplied alpha;
  ## scaling RGB uniformly keeps the premultiplication valid.
  result = newImage(spr.width, spr.height)
  for y in 0 ..< spr.height:
    for x in 0 ..< spr.width:
      let p = spr[x, y]
      result[x, y] = rgbx(
        uint8(p.r.float * PedestalDimFactor),
        uint8(p.g.float * PedestalDimFactor),
        uint8(p.b.float * PedestalDimFactor),
        p.a)

proc blitCover(dst, spr: Image, cx, cy, size: int) =
  ## Alpha-composites a cover-object sprite onto the board, centered on its
  ## collision shape and scaled to the shape's footprint (plus a little for the
  ## baked contact shadow). The sprite's transparency lets the textured floor
  ## show through; the board stays fully opaque (opaque dst + src-over).
  if size <= 0 or spr.width == 0:
    return
  let scaled = spr.resize(size, size)
  dst.draw(scaled, translate(vec2((cx - size div 2).float32,
                                  (cy - size div 2).float32)))

## --- Carved-stone wall material (top-down bevel from the collision mask) ---
## Every wall pixel — border frame, rect stub, diamond, disc, or chevron — is
## rendered as one coherent RAISED-STONE block whose shading comes from its
## distance to the nearest floor pixel. This replaces the old approach of
## tiling a SIDE-VIEW brick photo into the mask (which sliced the brick course
## mid-pattern → the "torn ribbon" chevrons) and blitting three clashing prop
## sprites (wood crate / steampunk pipe / barrel) scaled to a square that never
## matched the diamond/disc/diagonal footprints. Because the shading is derived
## from the mask, the art matches every collider EXACTLY and is identical on
## both halves by construction (the mask is mirror-symmetric). Light comes from
## the up-left, so the up-left faces catch a highlight and the down-right faces
## fall into shadow — the Gungeon/Nuclear-Throne top-down convention (L98).
const
  WallBevel = 3                          ## px width of the lit/shadow bevel band.


proc floorDistDir(wall: seq[bool], w, h, x, y, dx, dy, cap: int): int =
  ## Steps from (x, y) along (dx, dy) until the first floor (non-wall) pixel,
  ## capped at `cap`. Off-map counts as wall (the border is solid), so a pixel
  ## with no floor within `cap` in that direction returns cap + 1.
  for step in 1 .. cap:
    let
      nx = x + dx * step
      ny = y + dy * step
    if nx < 0 or ny < 0 or nx >= w or ny >= h:
      continue
    if not wall[ny * w + nx]:
      return step
  cap + 1

proc carvedStoneColorAt(
  wall: seq[bool], w, h, x, y, scale: int
): ColorRGBA =
  ## Shades one wall pixel as raised carved stone: an ink carve line where it
  ## meets the floor, a highlight on faces toward the up-left light, a shadow on
  ## faces toward the down-right, and a flat face deep inside the block. The
  ## mask may be a `scale`× render of the arena; every band (ink line, bevel)
  ## widens by `scale` so the material keeps its 1× proportions on screen.
  let
    bevel = WallBevel * scale
    up = floorDistDir(wall, w, h, x, y, 0, -1, bevel)
    left = floorDistDir(wall, w, h, x, y, -1, 0, bevel)
    down = floorDistDir(wall, w, h, x, y, 0, 1, bevel)
    right = floorDistDir(wall, w, h, x, y, 1, 0, bevel)
  if min(min(up, down), min(left, right)) <= scale:
    return StoneInk                      ## touches the floor → carve outline.
  let
    topDist = min(up, left)              ## nearer the up-left (lit) rim.
    botDist = min(down, right)           ## nearer the down-right (shaded) rim.
  if topDist <= bevel and topDist <= botDist:
    ## Graded lit bevel: brightest at the rim (just inside the ink line),
    ## easing back to the flat face by the bevel width so the block reads
    ## as a rounded raised edge, not a flat painted band.
    let t = (topDist - 2 * scale).float / max(1, bevel - 2 * scale).float
    mix(StoneHi, StoneFace, clamp(t, 0.0, 1.0))
  elif botDist <= bevel:
    let t = (botDist - 2 * scale).float / max(1, bevel - 2 * scale).float
    mix(StoneLo, StoneFace, clamp(t, 0.0, 1.0))
  else:
    StoneFace

proc carvedStoneColor(wall: seq[bool], w, h, x, y: int): ColorRGBA =
  ## 1× carved stone (the baked collision-resolution map and spun diamonds).
  carvedStoneColorAt(wall, w, h, x, y, 1)

const
  ## Glass window material: a pale pane set in the same stone frame language as
  ## the carved walls. The face targets palette index 1 (light gray) and the
  ## sheen streaks index 2 (near-white), so windows stay legible after the
  ## player-view palette quantization — glass must READ as see-through cover.
  GlassFace = rgba(198, 198, 196, 255)   ## flat pane; quantizes to palette 1.
  GlassSheen = rgba(240, 236, 226, 255)  ## diagonal streaks; quantizes to 2.

proc windowGlassColorAt(
  wall: seq[bool], w, h, x, y, scale: int
): ColorRGBA =
  ## Shades one glass window pixel: the same ink carve line and a thin stone
  ## frame where the pane meets the floor (so windows sit in the wall
  ## language), then a pale pane crossed by 45-degree sheen streaks running
  ## down-right, perpendicular to the up-left light the stone bevels use.
  ## Like carvedStoneColorAt, every band widens by `scale` so the material
  ## keeps its 1× screen proportions on the render-scale board.
  let
    frameCap = 2 * scale
    edge = min(
      min(
        floorDistDir(wall, w, h, x, y, 0, -1, frameCap),
        floorDistDir(wall, w, h, x, y, 0, 1, frameCap)
      ),
      min(
        floorDistDir(wall, w, h, x, y, -1, 0, frameCap),
        floorDistDir(wall, w, h, x, y, 1, 0, frameCap)
      )
    )
  if edge <= scale:
    return StoneInk                      ## touches the floor → carve outline.
  if edge <= frameCap:
    return StoneFace                     ## thin stone frame around the pane.
  let
    period = 24 * scale
    phase = ((x - y) mod period + period) mod period
  if phase < 3 * scale or phase in 7 * scale .. 9 * scale - 1:
    GlassSheen
  else:
    GlassFace

proc windowGlassColor(wall: seq[bool], w, h, x, y: int): ColorRGBA =
  ## 1× glass (the baked collision-resolution map the players observe).
  windowGlassColorAt(wall, w, h, x, y, 1)

const
  DiamondSpinFrames* = 16      ## steps across 90° (a diamond is 4-fold symmetric).
  DiamondSpinTicksPerFrame* = 4  ## ~2.7s per quarter turn at 24 ticks/s.

var diamondFrameCache: array[DiamondSpinFrames, seq[tuple[
  scale: int, pixels: seq[uint8]]]]

proc rotatingDiamondPixels*(
  radius, frame: int,
  scale = 1
): tuple[size: int, pixels: seq[uint8]] =
  ## One pre-rotated frame of a spinning center diamond, shaded with the same
  ## carved-stone material as the baked walls: the mask is rotated, then the
  ## bevel is re-derived from it, so the light stays up-left at every angle.
  ## Cosmetic only — collision keeps the static diamond. `size` is the LOGICAL
  ## (map-pixel) footprint; `pixels` are rasterized at scale× that footprint —
  ## the analytic mask is evaluated per output pixel, so a scaled frame has
  ## genuinely smoother edges, not upscaled blocks.
  let size = 2 * radius + 8
  let index = ((frame mod DiamondSpinFrames) + DiamondSpinFrames) mod
    DiamondSpinFrames
  for cached in diamondFrameCache[index]:
    if cached.scale == scale:
      return (size, cached.pixels)
  let
    outSize = size * scale
    angle = float(index) / float(DiamondSpinFrames) * PI / 2.0
    ca = cos(angle)
    sa = sin(angle)
    center = float(size) / 2.0
  var mask = newSeq[bool](outSize * outSize)
  for y in 0 ..< outSize:
    for x in 0 ..< outSize:
      let
        dx = (float(x) + 0.5) / float(scale) - center
        dy = (float(y) + 0.5) / float(scale) - center
        rx = dx * ca + dy * sa
        ry = -dx * sa + dy * ca
      mask[y * outSize + x] = abs(rx) + abs(ry) <= float(radius)
  var pixels = newSeq[uint8](outSize * outSize * 4)
  for y in 0 ..< outSize:
    for x in 0 ..< outSize:
      if mask[y * outSize + x]:
        let
          color = carvedStoneColorAt(mask, outSize, outSize, x, y, scale)
          offset = (y * outSize + x) * 4
        pixels[offset] = color.r
        pixels[offset + 1] = color.g
        pixels[offset + 2] = color.b
        pixels[offset + 3] = 255
  diamondFrameCache[index].add((scale: scale, pixels: pixels))
  (size, pixels)

## --- Capture endzones (the floor a carrier must reach to score) ---
## The win condition is a full-height vertical column at each home edge: a live
## carrier scores the instant its center-x crosses the inner threshold, at ANY
## height (captureZoneXRange / checkWinConditions). We make that legible by
## painting the endzone INTO the floor — an in-world "painted endzone", not HUD
## chrome — so it rides the board sprite and scales with the locked composition.
## The old broad half-board territory wash was removed for muddying the flagstone
## into "gradient columns" (L98 #4); this is the opposite: a CONFINED tint inside
## the narrow scoring column only, anchored by a crisp bright threshold line at
## the exact x a carrier must cross. Cosmetic over mapImage → hash-safe.
const
  EndzoneCrackGlow = 165         ## ember alpha on the darkest grout pixels (kept
                                 ## below the pedestal glow so the flag home
                                 ## stays the brightest thing in the endzone).
  EndzoneLineAlpha = 220         ## solid threshold line at the exact score-x.
  EndzoneLineW = 3               ## px width of that threshold line.
  # The flagstone texture runs dark (lum ~26..117, faces ~73+, grout ~<46), so
  # a single "below X" gate lit the whole floor. These two points bracket the
  # real split: at/above FaceLevel a pixel is a lit face → NO glow; at/below
  # CrackLevel it's grout → full glow; linear between.
  EndzoneFaceLevel = 66          ## lit stone face floor luminance (glow = 0).
  EndzoneCrackLevel = 34         ## grout/seam luminance (glow = full).
  EndzoneGlowFloor = 0.82        ## min home-falloff so the far end still glows.
  RedEndzoneColor = rgba(224, 82, 58, 255)    ## team vermillion (§4).
  BlueEndzoneColor = rgba(63, 124, 196, 255)  ## team cerulean (§4).

proc emberThroughCracks(base, ember: ColorRGBA, strength: float): ColorRGBA =
  ## Lets a team ember glow seep UP ONLY through the DARK crack/grout pixels of
  ## the flagstone TEXTURE — the lit stone faces stay completely clean (no base
  ## wash), so team color is confined to the actual fissures/seams, not a flat
  ## tint over the tiles (L98 #4). Distinct from the solid capture LINE, which is
  ## a painted stripe. A two-point luminance gate anchored to the measured floor
  ## split does the confining; `strength` is a gentle pedestal-side falloff.
  let l = (base.r.int * 30 + base.g.int * 59 + base.b.int * 11) div 100
  # 0 at/above a lit face, 1 at/below grout — cracks only, faces untouched.
  let crack = clamp((EndzoneFaceLevel - l).float /
    (EndzoneFaceLevel - EndzoneCrackLevel).float, 0.0, 1.0)
  let a = strength * crack * crack * EndzoneCrackGlow.float
  overTint(base, rgba(ember.r, ember.g, ember.b, uint8(clamp(a, 0.0, 255.0))))

proc endzoneColorAt(base: ColorRGBA, x, redHi, blueLo, playLo, playHi: int):
    ColorRGBA =
  ## Tints one floor pixel if it sits inside a capture endzone column. `redHi`
  ## is Red's inclusive right threshold x; `blueLo` is Blue's inclusive left
  ## threshold x; `playLo`/`playHi` are the inner playfield edges (for the
  ## glow falloff). Team ember seeps up through the tile cracks, brightest at the
  ## pedestal (the inner threshold edge) and floored so the whole zone still
  ## glows; the exact threshold x a carrier must cross gets a crisp solid line.
  if x <= redHi:
    if x > redHi - EndzoneLineW:
      overTint(base, rgba(RedEndzoneColor.r, RedEndzoneColor.g,
        RedEndzoneColor.b, EndzoneLineAlpha))
    else:
      let near = clamp((x - playLo).float / max(1, redHi - playLo).float, 0.0, 1.0)
      emberThroughCracks(base, RedEndzoneColor,
        EndzoneGlowFloor + (1.0 - EndzoneGlowFloor) * near)
  elif x >= blueLo:
    if x < blueLo + EndzoneLineW:
      overTint(base, rgba(BlueEndzoneColor.r, BlueEndzoneColor.g,
        BlueEndzoneColor.b, EndzoneLineAlpha))
    else:
      let near = clamp((playHi - x).float / max(1, playHi - blueLo).float, 0.0, 1.0)
      emberThroughCracks(base, BlueEndzoneColor,
        EndzoneGlowFloor + (1.0 - EndzoneGlowFloor) * near)
  else:
    base

proc shapeLogicalBounds(shape: ArenaShape): tuple[x0, y0, x1, y1: int] =
  ## A conservative logical-pixel bounding box around one obstacle shape (the
  ## scale× rasterizer only evaluates the float geometry inside it).
  case shape.kind
  of shapeRect:
    (shape.rect.x - 1, shape.rect.y - 1,
     shape.rect.x + shape.rect.w + 1, shape.rect.y + shape.rect.h + 1)
  of shapeDisc, shapeDiamond:
    (shape.cx - shape.radius - 1, shape.cy - shape.radius - 1,
     shape.cx + shape.radius + 1, shape.cy + shape.radius + 1)
  of shapeDiagonal:
    (min(shape.x0, shape.x1) - shape.thickness - 1,
     min(shape.y0, shape.y1) - shape.thickness - 1,
     max(shape.x0, shape.x1) + shape.thickness + 1,
     max(shape.y0, shape.y1) + shape.thickness + 1)

proc renderArenaRgbaPair*(
  gameMap: CtfMap,
  scale: int
): tuple[hot, cold: seq[uint8]] =
  ## The arena VISUAL rasterized natively at `scale`× map resolution for the
  ## spectator/replay renderer — real detail, not an upscale: wall shapes are
  ## re-evaluated from their float geometry per output pixel (crisp diagonal
  ## chevron/diamond edges), the carved-stone bevel grades over scale× more
  ## steps, the flagstone floor resolves bilinearly between texels, and the
  ## pedestal art (600px masters) rasterizes at scale× its footprint. The
  ## endzone tint gates stay LOGICAL-column based, so the capture line and
  ## glow columns land exactly where the 1× map puts them. Collision masks are
  ## untouched — they come from loadMapLayers at 1× and stay byte-identical.
  ##
  ## Renders BOTH variants in one pass — `hot` (baked endzone glow, lit
  ## pedestals) and `cold` (glow + capture line omitted, pedestals dimmed, for
  ## the glow-fade overlay) — because they share the two expensive stages: the
  ## geometry mask (rasterized per obstacle bounding box, not by testing every
  ## shape at every output pixel) and the bilinear floor bake. The certifier
  ## boots this on a small CI runner, so the bake must stay a startup blip,
  ## not a first-viewer stall.
  let
    w = gameMap.width
    h = gameMap.height
    ow = w * scale
    oh = h * scale
    cx = gameMap.center.x
    cy = gameMap.center.y
    dir = gameDir()
    floorTex = readImage(dir / ArenaFloorTex)
    pedRedSpr = readImage(dir / "data/ped_red.png")
    pedBlueSpr = readImage(dir / "data/ped_blue.png")
  # The art mask at output resolution: border + obstacle shapes from float
  # geometry, minus the spinning center diamonds (drawn live as objects).
  # Window pixels (glass) get their own mask in the same per-shape pass: wall
  # points inside a window shape draw as the pale pane, not carved stone.
  var
    artMask = newSeq[bool](ow * oh)
    windowMask = newSeq[bool](ow * oh)
  let
    bTop = ArenaBorder * scale
    bBottom = (h - ArenaBorder) * scale
    bLeft = ArenaBorder * scale
    bRight = (w - ArenaBorder) * scale
  for y in 0 ..< oh:
    if y < bTop or y >= bBottom:
      for x in 0 ..< ow:
        artMask[y * ow + x] = true
    else:
      for x in 0 ..< bLeft:
        artMask[y * ow + x] = true
      for x in bRight ..< ow:
        artMask[y * ow + x] = true
  for shape in ArenaObstacles:
    let
      (sx0, sy0, sx1, sy1) = shapeLogicalBounds(shape)
      ox0 = max(0, sx0 * scale)
      oy0 = max(0, sy0 * scale)
      ox1 = min(ow, sx1 * scale)
      oy1 = min(oh, sy1 * scale)
    for y in oy0 ..< oy1:
      let fy = (float(y) + 0.5) / float(scale)
      for x in ox0 ..< ox1:
        let fx = (float(x) + 0.5) / float(scale)
        if shapeWallAtF(fx, fy, shape, cx, cy):
          artMask[y * ow + x] = true
          if shape.window:
            windowMask[y * ow + x] = true
  for spot in AnimatedDiamonds:
    let
      pad = spot.radius + 2
      ox0 = max(0, (spot.cx - pad) * scale)
      oy0 = max(0, (spot.cy - pad) * scale)
      ox1 = min(ow, (spot.cx + pad) * scale)
      oy1 = min(oh, (spot.cy + pad) * scale)
    for y in oy0 ..< oy1:
      for x in ox0 ..< ox1:
        let i = y * ow + x
        if artMask[i] and isAnimatedDiamondPixel(x div scale, y div scale):
          artMask[i] = false
  # The flagstone tiles the board with a period of exactly texW×texH LOGICAL
  # pixels, so the bilinear floor repeats every texW·scale × texH·scale output
  # pixels — bake ONE tile block and index it, instead of bilinear-sampling
  # 3.3M board pixels (this bake runs at container boot on a small contended
  # CI runner; every pass here is on the certifier's clock).
  let
    tileW = floorTex.width * scale
    tileH = floorTex.height * scale
  var tileBlock = newSeq[ColorRGBA](tileW * tileH)
  for y in 0 ..< tileH:
    let fy = (float(y) + 0.5) / float(scale)
    for x in 0 ..< tileW:
      tileBlock[y * tileW + x] =
        tileSampleF(floorTex, (float(x) + 0.5) / float(scale), fy)
  let
    redHi = gameMap.teamHomeX(Red) + CaptureZoneWidth div 2
    blueLo = gameMap.teamHomeX(Blue) - CaptureZoneWidth div 2
    playLo = ArenaBorder
    playHi = w - 1 - ArenaBorder
  # Paint straight into the output byte buffers — the pixie Image round trip
  # (premultiply on write, un-premultiply on pack) was pure overhead for an
  # opaque board.
  result.hot = newSeq[uint8](ow * oh * 4)
  result.cold = newSeq[uint8](ow * oh * 4)
  template put(buf: seq[uint8], offset: int, c: ColorRGBA) =
    buf[offset] = c.r
    buf[offset + 1] = c.g
    buf[offset + 2] = c.b
    buf[offset + 3] = 255
  for y in 0 ..< oh:
    let
      ly = y div scale
      rowBorder = ly < ArenaBorder or ly >= h - ArenaBorder
      tileRow = (y mod tileH) * tileW
    for x in 0 ..< ow:
      let
        i = y * ow + x
        lx = x div scale
        onBorder = rowBorder or lx < ArenaBorder or lx >= w - ArenaBorder
      var hotColor, coldColor: ColorRGBA
      if artMask[i]:
        hotColor =
          if windowMask[i]:
            windowGlassColorAt(artMask, ow, oh, x, y, scale)
          else:
            carvedStoneColorAt(artMask, ow, oh, x, y, scale)
        coldColor = hotColor
      else:
        coldColor = tileBlock[tileRow + x mod tileW]
        hotColor = endzoneColorAt(coldColor, lx, redHi, blueLo, playLo, playHi)
      if onBorder:
        hotColor = overTint(hotColor, ArenaBorderColor)
        coldColor = overTint(coldColor, ArenaBorderColor)
      put(result.hot, i * 4, hotColor)
      put(result.cold, i * 4, coldColor)
  # Pedestals: pixie still resizes the painted masters, but the composite onto
  # the board is a manual straight-alpha src-over into the byte buffers.
  for team in Team:
    let
      home = gameMap.flagHome(team)
      full = if team == Red: pedRedSpr else: pedBlueSpr
      size = PedestalCoverSize * scale
      scaled = full.resize(size, size)
      dimmed = scaled.pedestalDimmed()
      px0 = home.x * scale - size div 2
      py0 = home.y * scale - size div 2
    for sy in 0 ..< size:
      let dy = py0 + sy
      if dy < 0 or dy >= oh:
        continue
      for sx in 0 ..< size:
        let dx = px0 + sx
        if dx < 0 or dx >= ow:
          continue
        let
          litPx = scaled.data[sy * size + sx].rgba
          dimPx = dimmed.data[sy * size + sx].rgba
          offset = (dy * ow + dx) * 4
        template blend(buf: seq[uint8], src: ColorRGBA) =
          if src.a == 255'u8:
            buf[offset] = src.r
            buf[offset + 1] = src.g
            buf[offset + 2] = src.b
          elif src.a > 0'u8:
            let a = src.a.int
            buf[offset] =
              uint8((src.r.int * a + buf[offset].int * (255 - a)) div 255)
            buf[offset + 1] =
              uint8((src.g.int * a + buf[offset + 1].int * (255 - a)) div 255)
            buf[offset + 2] =
              uint8((src.b.int * a + buf[offset + 2].int * (255 - a)) div 255)
        blend(result.hot, litPx)
        blend(result.cold, dimPx)

proc loadMapLayers*(gameMap: CtfMap, withEndzoneGlow = true):
    tuple[mapImage, walkImage, wallImage: Image] =
  ## Builds the visual map plus the walk and wall masks for the arena. The
  ## visuals: a tiled top-down flagstone floor, and ONE coherent carved-stone
  ## material for every wall pixel — border frame, rect stub, diamond, disc, and
  ## chevron alike — beveled from the collision mask itself so the art matches
  ## each collider EXACTLY and is identical on both halves by construction. The
  ## old side-view brick texture (sliced mid-course into the shapes → "torn
  ## ribbon" chevrons) and the three clashing prop sprites (wood crate /
  ## steampunk pipe / barrel scaled to a square over diamond/disc footprints)
  ## are gone (L98 #4: one baked material; let flags + pedestals carry team
  ## identity). Team pedestals stay. The walk/wall COLLISION masks are
  ## byte-identical to before — the art is cosmetic over the exact geometry.
  let
    w = gameMap.width
    h = gameMap.height
    cx = gameMap.center.x
    cy = gameMap.center.y
  result.mapImage = newImage(w, h)
  result.walkImage = newImage(w, h)
  result.wallImage = newImage(w, h)
  let
    clear = rgba(0, 0, 0, 0)
    opaque = rgba(255, 255, 255, 255)
    dir = gameDir()
    floorTex = readImage(dir / ArenaFloorTex)
    pedRedSpr = readImage(dir / "data/ped_red.png")
    pedBlueSpr = readImage(dir / "data/ped_blue.png")
  ## Pass 1: the boolean wall mask (border + obstacles), shared by the shading
  ## bevel and the collision masks so art and geometry can never disagree.
  var wallMask = newSeq[bool](w * h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      wallMask[y * w + x] = isArenaWall(x, y, cx, cy)
  ## The art mask drops the rotating center diamonds: their pixels paint as
  ## floor here and the live renderer draws them as spinning objects. The
  ## COLLISION masks below keep using the unmodified wallMask.
  var artMask = wallMask
  for y in 0 ..< h:
    for x in 0 ..< w:
      if artMask[y * w + x] and isAnimatedDiamondPixel(x, y):
        artMask[y * w + x] = false
  ## The capture endzones: the exact score-columns from checkWinConditions'
  ## captureZoneXRange (Red's inclusive right threshold, Blue's inclusive left),
  ## painted into the FLOOR below so a carrier can read where to run.
  let
    redHi = gameMap.teamHomeX(Red) + CaptureZoneWidth div 2
    blueLo = gameMap.teamHomeX(Blue) - CaptureZoneWidth div 2
    playLo = ArenaBorder                     # inner playfield edges: the glow
    playHi = w - 1 - ArenaBorder             # anchors home, fades to the line.
  ## Pass 2: paint. Floor pixels sample the flagstone tile; wall pixels are the
  ## carved-stone material shaded from the mask. The perimeter frame is the same
  ## stone darkened so the play space reads as a lit pit. Floor pixels inside a
  ## capture column get a CONFINED team endzone tint + a bright threshold line
  ## (endzoneColorAt) — not the removed broad half-board wash (L98 #4).
  for y in 0 ..< h:
    for x in 0 ..< w:
      let
        onBorder = x < ArenaBorder or y < ArenaBorder or
          x >= w - ArenaBorder or y >= h - ArenaBorder
        wall = wallMask[y * w + x]
        artWall = artMask[y * w + x]
        windowPixel = wall and isArenaWindowPixel(x, y, cx, cy)
      var color =
        if windowPixel: windowGlassColor(artMask, w, h, x, y)
        elif artWall: carvedStoneColor(artMask, w, h, x, y)
        elif withEndzoneGlow: endzoneColorAt(tileSample(floorTex, x, y), x,
          redHi, blueLo, playLo, playHi)
        else: tileSample(floorTex, x, y)
      if onBorder:
        color = overTint(color, ArenaBorderColor)
      result.mapImage[x, y] = color
      result.walkImage[x, y] = if wall: clear else: opaque
      result.wallImage[x, y] = if wall: opaque else: clear
  ## Carved team pedestal under each flag home (walkable — sits inside the
  ## protected spawn pocket; cosmetic only, collision masks untouched). With the
  ## glow OFF this is the "cold" map: the pedestal art is dimmed to a powered-down
  ## disc (see pedestalDimmed) so the broadcast crossfade dims the disc along with
  ## the floor glow when the heart is gone — otherwise a hot==cold pedestal never
  ## fades. The RGB/hot map (withEndzoneGlow) keeps the pedestal at full light.
  for team in Team:
    let
      home = gameMap.flagHome(team)
      full = if team == Red: pedRedSpr else: pedBlueSpr
      spr = if withEndzoneGlow: full else: full.pedestalDimmed()
    blitCover(result.mapImage, spr, home.x, home.y, PedestalCoverSize)

proc coldEndzoneMapRgba*(gameMap: CtfMap): seq[uint8] =
  ## Builds the map RGBA with the endzone crack-glow and capture line OMITTED —
  ## the "power source is gone" cold floor. Same layout/format as `sim.mapRgba`
  ## (walls, border, pedestals identical), so a broadcast overlay can crossfade
  ## the baked-glow map toward this and only the glow + line visibly change.
  ## Cosmetic, spectator-only: it is NOT the map the player POV / RL agents see.
  let (mapImage, _, _) = loadMapLayers(gameMap, withEndzoneGlow = false)
  result = newSeq[uint8](MapWidth * MapHeight * 4)
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      let
        pixel = mapImage[x, y]
        offset = (y * MapWidth + x) * 4
      result[offset] = pixel.r
      result[offset + 1] = pixel.g
      result[offset + 2] = pixel.b
      result[offset + 3] = pixel.a

proc loadDarkBgPixels*(): seq[uint8] =
  ## Loads the dark interstitial background as palette pixels.
  let image = readAsepriteImage(gameDir() / DarkBgPath)
  if image.width != ScreenWidth or image.height != ScreenHeight:
    raise newException(
      CtfError,
      DarkBgPath & " must be " & $ScreenWidth & "x" & $ScreenHeight & "."
    )
  result = newSeq[uint8](ScreenWidth * ScreenHeight)
  for y in 0 ..< ScreenHeight:
    for x in 0 ..< ScreenWidth:
      let color = nearestPaletteIndex(image[x, y])
      result[y * ScreenWidth + x] =
        if color == TransparentColorIndex: SpaceColor else: color

proc asciiIndex*(ch: char): int =
  ## Returns the ASCII sheet index for a character.
  ord(ch) - ord(' ')

proc blitAsciiText*(
  fb: var Framebuffer,
  asciiSprites: PixelFont,
  text: string,
  screenX, screenY: int
) =
  ## Draws text using the CTF tiny UI font.
  fb.drawText(asciiSprites, text, screenX, screenY, TextColor)

proc blitCenteredAsciiText*(
  fb: var Framebuffer,
  asciiSprites: PixelFont,
  text: string,
  screenY: int
) =
  ## Draws centered text using the CTF tiny UI font.
  let screenX = (ScreenWidth - asciiSprites.textWidth(text)) div 2
  fb.blitAsciiText(asciiSprites, text, screenX, screenY)

proc defaultGameConfig*(): GameConfig =
  ## Returns the default CTF gameplay config.
  GameConfig(
    motionScale: MotionScale,
    accel: Accel,
    frictionNum: FrictionNum,
    frictionDen: FrictionDen,
    maxSpeed: MaxSpeed,
    stopThreshold: StopThreshold,
    playerBouncePct: PlayerBouncePct,
    seed: 0xA6019,
    speed: 1,
    lives: Lives,
    hitPoints: HitPoints,
    respawnTicks: RespawnTicks,
    gunRange: GunRange,
    fireCooldownTicks: FireCooldownTicks,
    fireWindupTicks: FireWindupTicks,
    carrierSpeedPct: CarrierSpeedPct,
    aimTurnRate: AimTurnRate,
    visionConeDeg: VisionConeDeg,
    visionBubble: VisionBubble,
    minPlayers: MinPlayers,
    startWaitTicks: StartWaitTicks,
    gameOverTicks: GameOverTicks,
    maxTicks: MaxTicks,
    maxGames: MaxGames,
    showPlayerLabels: true,
    fastMode: true,
    mapPath: DefaultMapPath,
    mapSeed: -1,
    mapPoolIndex: -1,
    mapGen: MapGenOverrides(windows: -1),
    mapSpec: "",
    closedRoster: false,
    slots: @[]
  )

proc readConfigInt(node: JsonNode, name: string, value: var int) =
  ## Reads one optional integer config field.
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JInt:
    raise newException(CtfError, "Config field " & name & " must be an integer.")
  value = item.getInt()

proc readConfigBool(node: JsonNode, name: string, value: var bool) =
  ## Reads one optional boolean config field.
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JBool:
    raise newException(CtfError, "Config field " & name & " must be a boolean.")
  value = item.getBool()

proc readConfigString(node: JsonNode, name: string, value: var string) =
  ## Reads one optional string config field.
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JString:
    raise newException(CtfError, "Config field " & name & " must be a string.")
  value = item.getStr()

proc readSlotTeam(text: string, slotIndex: int): Team =
  ## Reads one slot team string.
  case text.strip().toLowerAscii()
  of "red":
    Red
  of "blue":
    Blue
  else:
    raise newException(
      CtfError,
      "Config field slots[" & $slotIndex & "].team must be red or blue."
    )

proc normalizedSlotColor(text: string): string =
  ## Returns a normalized slot color name.
  result = text.strip().toLowerAscii()
  result = result.replace("_", " ")
  result = result.replace("-", " ")
  result = result.replace(" ", "")

proc playerColorText*(color: uint8): string =
  ## Returns the readable player color name.
  for i in 0 ..< PlayerColors.len:
    if PlayerColors[i] == color:
      return PlayerColorNames[i]
  "unknown"

proc readSlotColor(text: string, slotIndex: int): uint8 =
  ## Reads one slot color string.
  case text.normalizedSlotColor()
  of "red":
    PlayerColors[0]
  of "orange":
    PlayerColors[1]
  of "yellow":
    PlayerColors[2]
  of "lightblue", "cyan":
    PlayerColors[3]
  of "pink":
    PlayerColors[4]
  of "lime":
    PlayerColors[5]
  of "blue":
    PlayerColors[6]
  of "paleblue":
    PlayerColors[7]
  of "gray", "grey":
    PlayerColors[8]
  of "white":
    PlayerColors[9]
  of "darkbrown":
    PlayerColors[10]
  of "brown":
    PlayerColors[11]
  of "darkteal", "teal":
    PlayerColors[12]
  of "green":
    PlayerColors[13]
  of "darknavy", "navy":
    PlayerColors[14]
  of "black":
    PlayerColors[15]
  else:
    raise newException(
      CtfError,
      "Config field slots[" & $slotIndex & "].color is unknown."
    )

proc readSlotSkin(node: JsonNode, slotIndex: int): Skin =
  ## Reads one tolerant cosmetic skin value.
  if node.kind == JString:
    case node.getStr()
    of "default":
      return DefaultSkin
    of "crown":
      return CrownSkin
    else:
      discard
  stderr.writeLine(
    "Warning: config slots[" & $slotIndex & "].skin value " & $node &
      " is unrecognized; using default."
  )
  DefaultSkin

proc readConfigSlots(node: JsonNode, slots: var seq[PlayerSlotConfig]) =
  ## Reads optional fixed player slot config entries.
  if not node.hasKey("slots"):
    return
  let items = node["slots"]
  if items.kind != JArray:
    raise newException(CtfError, "Config field slots must be an array.")
  slots.setLen(0)
  for i, item in items.elems:
    if item.kind != JObject:
      raise newException(
        CtfError,
        "Config field slots[" & $i & "] must be an object."
      )
    if item.hasKey("name"):
      raise newException(
        CtfError,
        "Config field slots[" & $i & "].name is not supported; use players[" &
          $i & "].name instead."
      )
    var slot: PlayerSlotConfig
    item.readConfigString("token", slot.token)
    if item.hasKey("team"):
      let team = item["team"]
      if team.kind != JString:
        raise newException(
          CtfError,
          "Config field slots[" & $i & "].team must be a string."
        )
      slot.team = readSlotTeam(team.getStr(), i)
      slot.hasTeam = true
    if item.hasKey("color"):
      let color = item["color"]
      if color.kind != JString:
        raise newException(
          CtfError,
          "Config field slots[" & $i & "].color must be a string."
        )
      slot.color = readSlotColor(color.getStr(), i)
      slot.hasColor = true
    if item.hasKey("skin"):
      slot.skin = readSlotSkin(item["skin"], i)
    slots.add(slot)

proc readConfigPlayers(node: JsonNode, slots: var seq[PlayerSlotConfig]) =
  ## Reads optional fixed player display names by slot index.
  if node.hasKey("player_names"):
    raise newException(
      CtfError,
      "Config field player_names is not supported; use players[].name instead."
    )
  if not node.hasKey("players"):
    return
  let items = node["players"]
  if items.kind != JArray:
    raise newException(CtfError, "Config field players must be an array.")
  if items.len > MaxPlayers:
    raise newException(
      CtfError,
      "Config field players cannot have more than 8 entries."
    )
  if slots.len < items.len:
    slots.setLen(items.len)
  for i, item in items.elems:
    if item.kind != JObject:
      raise newException(
        CtfError,
        "Config field players[" & $i & "] must be an object."
      )
    if not item.hasKey("name"):
      raise newException(
        CtfError,
        "Config field players[" & $i & "].name is required."
      )
    let nameNode = item["name"]
    if nameNode.kind != JString:
      raise newException(
        CtfError,
        "Config field players[" & $i & "].name must be a string."
      )
    let name = nameNode.getStr()
    if name.len == 0:
      raise newException(
        CtfError,
        "Config field players[" & $i & "].name must not be empty."
      )
    slots[i].name = name

proc defaultSlotName(slotIndex: int): string =
  ## Returns the canonical name for one generated tournament slot.
  "Player" & $(slotIndex + 1)

proc readConfigTokens(
  node: JsonNode,
  slots: var seq[PlayerSlotConfig],
  closedRoster: bool
) =
  ## Reads optional fixed player slot tokens.
  if not node.hasKey("tokens"):
    return
  let items = node["tokens"]
  if items.kind != JArray:
    raise newException(CtfError, "Config field tokens must be an array.")
  if items.len > MaxPlayers:
    raise newException(
      CtfError,
      "Config field tokens cannot have more than 8 entries."
    )
  if slots.len < items.len:
    slots.setLen(items.len)
  for i, item in items.elems:
    if item.kind != JString:
      raise newException(
        CtfError,
        "Config field tokens[" & $i & "] must be a string."
      )
    let token = item.getStr()
    if slots[i].token.len > 0 and slots[i].token != token:
      raise newException(
        CtfError,
        "Config field tokens[" & $i & "] conflicts with slots[" & $i &
          "].token."
      )
    slots[i].token = token
    if closedRoster and slots[i].name.len == 0:
      slots[i].name = defaultSlotName(i)

proc validate(config: GameConfig) =
  ## Raises if a gameplay config has invalid values.
  if config.motionScale <= 0:
    raise newException(CtfError, "Config field motionScale must be positive.")
  if config.frictionDen <= 0:
    raise newException(CtfError, "Config field frictionDen must be positive.")
  if config.minPlayers < 1:
    raise newException(CtfError, "Config field minPlayers must be at least 1.")
  if config.minPlayers > MaxPlayers:
    raise newException(CtfError, "can't do more than 8 players.")
  if config.lives < 1:
    raise newException(CtfError, "Config field lives must be at least 1.")
  if config.hitPoints < 1:
    raise newException(CtfError, "Config field hitPoints must be at least 1.")
  if config.gunRange <= 0:
    raise newException(CtfError, "Config field gunRange must be positive.")
  if config.fireWindupTicks < 0:
    raise newException(CtfError, "Config field fireWindupTicks must not be negative.")
  if config.carrierSpeedPct <= 0 or config.carrierSpeedPct > 100:
    raise newException(CtfError, "Config field carrierSpeedPct must be 1..100.")
  if config.playerBouncePct < 0 or config.playerBouncePct > 100:
    raise newException(CtfError, "Config field playerBouncePct must be 0..100.")
  if config.aimTurnRate < 1:
    raise newException(CtfError, "Config field aimTurnRate must be at least 1.")
  if config.visionConeDeg < 0 or config.visionConeDeg > 180:
    raise newException(CtfError, "Config field visionConeDeg must be between 0 and 180.")
  if config.visionBubble < 0:
    raise newException(CtfError, "Config field visionBubble must be non-negative.")
  if config.speed notin [1, 2, 3, 4, 8, 16]:
    raise newException(
      CtfError,
      "Config field speed must be 1, 2, 3, 4, 8, or 16."
    )
  if config.startWaitTicks < 0:
    raise newException(CtfError, "Config field startWaitTicks must be non-negative.")
  if config.respawnTicks < 0 or config.fireCooldownTicks < 0:
    raise newException(CtfError, "Timer config fields must not be negative.")
  if config.gameOverTicks < 0 or config.maxTicks < 0 or config.maxGames < 0:
    raise newException(CtfError, "Timer config fields must not be negative.")
  if config.slots.len > MaxPlayers:
    raise newException(CtfError, "Config field slots cannot have more than 8 entries.")
  if config.closedRoster and config.slots.len < config.minPlayers:
    raise newException(
      CtfError,
      "Config field closedRoster requires at least minPlayers configured slots."
    )
  if config.closedRoster:
    for i, slot in config.slots:
      if slot.name.len == 0:
        raise newException(
          CtfError,
          "Config field closedRoster requires players[" & $i & "].name."
        )
      if slot.token.len == 0:
        raise newException(
          CtfError,
          "Config field closedRoster requires slots[" & $i & "].token."
        )
  for i in 0 ..< config.slots.len:
    for j in i + 1 ..< config.slots.len:
      if config.slots[i].name.len > 0 and
          config.slots[i].name == config.slots[j].name:
        raise newException(
          CtfError,
          "Config field players has duplicate name " & config.slots[i].name & "."
        )
      if config.slots[i].token.len > 0 and
          config.slots[i].token == config.slots[j].token:
        raise newException(
          CtfError,
          "Config field slots has duplicate token."
        )

proc update*(config: var GameConfig, jsonText: string) =
  ## Updates a gameplay config from a JSON object.
  if jsonText.len == 0:
    return
  var node: JsonNode
  try:
    node = fromJson(jsonText)
  except jsony.JsonError as e:
    raise newException(CtfError, "Could not parse config JSON: " & e.msg)
  if node.kind != JObject:
    raise newException(CtfError, "Config must be a JSON object.")
  node.readConfigInt("motionScale", config.motionScale)
  node.readConfigInt("accel", config.accel)
  node.readConfigInt("frictionNum", config.frictionNum)
  node.readConfigInt("frictionDen", config.frictionDen)
  node.readConfigInt("maxSpeed", config.maxSpeed)
  node.readConfigInt("stopThreshold", config.stopThreshold)
  node.readConfigInt("playerBouncePct", config.playerBouncePct)
  node.readConfigInt("seed", config.seed)
  node.readConfigInt("speed", config.speed)
  node.readConfigInt("lives", config.lives)
  node.readConfigInt("hitPoints", config.hitPoints)
  node.readConfigInt("respawnTicks", config.respawnTicks)
  node.readConfigInt("gunRange", config.gunRange)
  node.readConfigInt("fireCooldownTicks", config.fireCooldownTicks)
  node.readConfigInt("fireWindupTicks", config.fireWindupTicks)
  node.readConfigInt("carrierSpeedPct", config.carrierSpeedPct)
  node.readConfigInt("aimTurnRate", config.aimTurnRate)
  node.readConfigInt("visionConeDeg", config.visionConeDeg)
  node.readConfigInt("visionBubble", config.visionBubble)
  node.readConfigInt("minPlayers", config.minPlayers)
  node.readConfigInt("startWaitTicks", config.startWaitTicks)
  node.readConfigInt("gameStartWaitTicks", config.startWaitTicks)
  node.readConfigInt("gameOverTicks", config.gameOverTicks)
  node.readConfigInt("maxTicks", config.maxTicks)
  node.readConfigInt("maxGameTicks", config.maxTicks)
  node.readConfigInt("maxGames", config.maxGames)
  node.readConfigBool("showPlayerLabels", config.showPlayerLabels)
  node.readConfigBool("fastMode", config.fastMode)
  node.readConfigString("map", config.mapPath)
  node.readConfigString("mapPath", config.mapPath)
  ## "mw2" is a rotation alias, not a map: resolve it to a concrete pack map
  ## keyed by the episode seed (read above) so each fresh league process —
  ## one per episode, distinct seeds — lands on a rotating map, and the
  ## replay header records the resolved name. Resolved BEFORE the effective
  ## map is looked up below, so the alias never reaches the registry.
  if config.mapPath == Mw2AliasName:
    config.mapPath = Mw2Rotation[abs(config.seed) mod Mw2Rotation.len]
  node.readConfigInt("mapSeed", config.mapSeed)
  node.readConfigInt("mapPoolIndex", config.mapPoolIndex)
  node.readConfigString("mapSize", config.mapGen.size)
  node.readConfigString("mapSymmetry", config.mapGen.symmetry)
  node.readConfigInt("mapColumns", config.mapGen.columns)
  node.readConfigInt("mapWindows", config.mapGen.windows)
  node.readConfigString("mapCenterFeature", config.mapGen.centerFeature)
  if node.hasKey("mapSpec"):
    if node["mapSpec"].kind != JObject:
      raise newException(CtfError, "Config field mapSpec must be an object.")
    config.mapSpec = $node["mapSpec"]
  ## Resolve the effective map ONCE: a generated map is expanded and pinned
  ## as mapSpec here, so the replay carries the exact geometry and playback
  ## never re-runs the generator. The gun range follows the selected map
  ## unless the config sets it explicitly: each map def carries its own
  ## map-wide default.
  let mapMeta = resolveCtfMapMetadata(config)
  if config.mapSpec.len == 0 and mapMeta.path == GenMapName:
    config.mapSpec = mapSpecJson(mapMeta)
  if not node.hasKey("gunRange"):
    config.gunRange = mapMeta.gunRange
  node.readConfigSlots(config.slots)
  node.readConfigBool("closedRoster", config.closedRoster)
  node.readConfigTokens(config.slots, config.closedRoster)
  node.readConfigPlayers(config.slots)
  config.validate()

proc slotTeamText(slot: PlayerSlotConfig): string =
  ## Returns a JSON team string for one slot.
  if not slot.hasTeam:
    return ""
  case slot.team
  of Red:
    "red"
  of Blue:
    "blue"

proc slotColorText(slot: PlayerSlotConfig): string =
  ## Returns a JSON color string for one slot.
  if not slot.hasColor:
    return ""
  playerColorText(slot.color)

proc skinText(skin: Skin): string =
  ## Returns a JSON skin string.
  case skin
  of DefaultSkin:
    "default"
  of CrownSkin:
    "crown"

proc configJson*(config: GameConfig): string =
  ## Returns the complete replay JSON for a gameplay config.
  var
    players = newJArray()
    slots = newJArray()
    tokens = newJArray()
    includePlayers = false
  for slot in config.slots:
    var item = newJObject()
    if slot.name.len > 0:
      includePlayers = true
    tokens.add(%slot.token)
    players.add(%*{"name": slot.name})
    if slot.hasTeam:
      item["team"] = %slot.slotTeamText()
    if slot.hasColor:
      item["color"] = %slot.slotColorText()
    if slot.skin != DefaultSkin:
      item["skin"] = %slot.skin.skinText()
    slots.add(item)
  var node = %*{
    "motionScale": config.motionScale,
    "accel": config.accel,
    "frictionNum": config.frictionNum,
    "frictionDen": config.frictionDen,
    "maxSpeed": config.maxSpeed,
    "stopThreshold": config.stopThreshold,
    "playerBouncePct": config.playerBouncePct,
    "seed": config.seed,
    "speed": config.speed,
    "lives": config.lives,
    "hitPoints": config.hitPoints,
    "respawnTicks": config.respawnTicks,
    "gunRange": config.gunRange,
    "fireCooldownTicks": config.fireCooldownTicks,
    "fireWindupTicks": config.fireWindupTicks,
    "carrierSpeedPct": config.carrierSpeedPct,
    "aimTurnRate": config.aimTurnRate,
    "visionConeDeg": config.visionConeDeg,
    "visionBubble": config.visionBubble,
    "minPlayers": config.minPlayers,
    "startWaitTicks": config.startWaitTicks,
    "gameOverTicks": config.gameOverTicks,
    "maxTicks": config.maxTicks,
    "maxGameTicks": config.maxTicks,
    "maxGames": config.maxGames,
    "mapPath": config.mapPath,
    "mapSeed": config.mapSeed,
    "mapPoolIndex": config.mapPoolIndex,
    "mapSize": config.mapGen.size,
    "mapSymmetry": config.mapGen.symmetry,
    "mapColumns": config.mapGen.columns,
    "mapWindows": config.mapGen.windows,
    "mapCenterFeature": config.mapGen.centerFeature,
    "closedRoster": config.closedRoster,
    "showPlayerLabels": config.showPlayerLabels,
    "fastMode": config.fastMode,
    "tokens": tokens,
    "slots": slots
  }
  if includePlayers:
    node["players"] = players
  if config.mapSpec.len > 0:
    node["mapSpec"] = fromJson(config.mapSpec)
  $node

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

proc teamText*(team: Team): string =
  ## Returns the readable team name.
  case team
  of Red:
    "red"
  of Blue:
    "blue"

proc teamColor*(team: Team): uint8 =
  ## Returns the palette color for one team.
  case team
  of Red:
    RedTeamColor
  of Blue:
    BlueTeamColor

proc enemy*(team: Team): Team =
  ## Returns the opposing team.
  case team
  of Red:
    Blue
  of Blue:
    Red

proc spawnAimBrads*(team: Team): int =
  ## Returns the spawn/respawn aim angle: toward the enemy side.
  case team
  of Red:
    0                          ## east, toward Blue.
  of Blue:
    AimBradsTurn div 2         ## west, toward Red.

proc aimVector*(brads: int): tuple[x, y: float] =
  ## Returns the unit vector for one aim angle in brads (256 per turn):
  ## 0 points east (+x) and the angle increases counter-clockwise on screen,
  ## so 64 is north (-y in map coordinates), 128 west, and 192 south.
  let angle = float(brads) * PI / float(AimBradsTurn div 2)
  (cos(angle), -sin(angle))

proc bradsOfVector*(dx, dy: int): int =
  ## Returns the aim-brads angle of a map-space vector — the inverse of
  ## `aimVector` (screen y points down, so north is -y).
  if dx == 0 and dy == 0:
    return 0
  let brads = int(round(
    arctan2(-float(dy), float(dx)) * float(AimBradsTurn div 2) / PI))
  ((brads mod AimBradsTurn) + AimBradsTurn) mod AimBradsTurn

proc playerText(sim: SimServer, playerIndex: int): string =
  ## Returns the readable player color for one player index.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return "unknown"
  playerColorText(sim.players[playerIndex].color)

proc logGameEvent(sim: SimServer, text: string) =
  ## Writes one game event to stdout for Docker logs.
  if sim.gameEventLoggingEnabled:
    echo text

proc logLobbyWaiting(sim: var SimServer) =
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

proc logLobbyCountdown(sim: var SimServer) =
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

proc grenadeThrowerSlot(
  sim: SimServer,
  grenade: AirborneGrenade
): int {.inline.} =
  grenade.throwerSlot

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
  result.mixHashInt(sim.overtimeTicks)
  result.mixHashBool(sim.isDraw)
  result.mixHashBool(sim.needsReregister)
  result.mixHashInt(sim.nextJoinOrder)
  for team in Team:
    result.mixHashInt(sim.flags[team].x)
    result.mixHashInt(sim.flags[team].y)
    result.mixHashInt(sim.flags[team].carrier)
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
    result.mixHashBool(player.hasPlasmaArc)
    result.mixHashInt(player.arcTicksLeft)
    result.mixHashInt(int(player.arcHitMask))
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
  for spawn in sim.grenadeSpawns:
    result.mixHashBool(spawn.present)
    result.mixHashInt(spawn.respawnAt)
  for spawn in sim.medKitSpawns:
    result.mixHashBool(spawn.present)
    result.mixHashInt(spawn.respawnAt)
  for spawn in sim.shieldSpawns:
    result.mixHashBool(spawn.present)
    result.mixHashInt(spawn.respawnAt)
  for spawn in sim.plasmaArcSpawns:
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

proc nearestWalkable(sim: SimServer, x, y: int): tuple[x, y: int] =
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

proc teamHomeX(sim: SimServer, team: Team): int =
  ## Returns the home-edge x anchor for one team's spawn strip.
  sim.gameMap.teamHomeX(team)

proc spawnPosition*(sim: SimServer, team: Team, order: int): tuple[x, y: int] =
  ## Returns a deterministic spawn position just inside a team's home edge.
  let
    baseX = sim.teamHomeX(team)
    strip = order div 2          ## stagger players down the edge.
    cy = sim.gameMap.center.y
    spread = 36
    targetY = cy + (strip - 1) * spread
    targetX = baseX + (if order mod 2 == 0: -6 else: 6)
  sim.nearestWalkable(targetX, targetY)

proc captureZoneXRange(sim: SimServer, team: Team): tuple[lo, hi: int] =
  ## Returns the inclusive x range of one team's home capture zone.
  case team
  of Red:
    let hi = sim.teamHomeX(Red) + CaptureZoneWidth div 2
    (0, hi)
  of Blue:
    let lo = sim.teamHomeX(Blue) - CaptureZoneWidth div 2
    (lo, MapWidth - 1)

proc randomEndzonePosition*(sim: var SimServer, team: Team):
    tuple[x, y: int] =
  ## Returns a random walkable position inside a team's endzone (the home
  ## capture column, full map height), drawn from the deterministic sim RNG.
  let
    zone = sim.captureZoneXRange(team)
    inset = ArenaBorder + PlayerHalf
    xLo = max(zone.lo, inset)
    xHi = min(zone.hi, MapWidth - 1 - inset)
    yLo = inset
    yHi = MapHeight - 1 - inset
  sim.nearestWalkable(
    xLo + sim.rng.rand(xHi - xLo),
    yLo + sim.rng.rand(yHi - yLo))

proc placePlayer(sim: var SimServer, playerIndex, x, y: int) =
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

proc eventSlot(sim: SimServer, playerIndex: int): int {.inline.} =
  ## Returns a player's stable join slot for the tier-2 event stream, so an
  ## event survives roster changes; -1 for no/invalid player.
  if playerIndex >= 0 and playerIndex < sim.players.len:
    return sim.players[playerIndex].joinOrder
  -1

type EventActionKind = enum
  GunAction
  GrenadeAction
  SprayAction

proc eventActionId(
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
    gameOrdinal += account.gamesRed + account.gamesBlue
  (int64(gameOrdinal) shl 48) or
    (int64(eventTick) shl 16) or
    (int64(ord(kind) + 1) shl 8) or
    int64(slot and 0xff)

proc eventActionIdForSlot(
  sim: SimServer,
  slot: int,
  kind: EventActionKind,
  tick: int
): int64 {.inline.} =
  var gameOrdinal = 0
  for account in sim.rewardAccounts:
    gameOrdinal += account.gamesRed + account.gamesBlue
  (int64(gameOrdinal) shl 48) or
    (int64(tick) shl 16) or
    (int64(ord(kind) + 1) shl 8) or
    int64(max(0, slot) and 0xff)

proc eventDamage(
  sim: SimServer,
  playerIndex, amount, hp, blocked: int
): EventDamage {.inline.} =
  EventDamage(
    slot: sim.eventSlot(playerIndex),
    amount: amount,
    hp: hp,
    blocked: blocked
  )

proc emitEvent(
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

proc emitPhaseChange(sim: var SimServer, newPhase: GamePhase) {.inline.} =
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

proc emitPickup(
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
  ## Returns both flags to their home pedestals.
  for team in Team:
    sim.resetFlag(team)

proc teamForSlot(sim: SimServer, order: int): Team =
  ## Returns the configured or default team for one slot.
  let slot =
    if order >= 0 and order < sim.config.slots.len:
      sim.config.slots[order]
    else:
      PlayerSlotConfig()
  if slot.hasTeam:
    slot.team
  elif order mod 2 == 0:
    Red
  else:
    Blue

const IdentityNames* = [
  "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"]
  ## Per-team player identities, assigned by slot order within the team.

proc slotIdentityIndex*(sim: SimServer, order: int): int =
  ## Returns one slot's identity index (into IdentityNames): its rank among
  ## same-team slots. Derived from the config, not stored, so it is stable
  ## across matches, reconnects, and replays. Wraps past theta in the
  ## degenerate case of more than IdentityNames.len slots on one team.
  let team = sim.teamForSlot(order)
  for i in 0 ..< order:
    if sim.teamForSlot(i) == team:
      inc result
  result = result mod IdentityNames.len

proc findSpawn*(sim: SimServer): tuple[x, y: int] =
  ## Returns the next lobby spawn position.
  let order = sim.players.len
  sim.spawnPosition(sim.teamForSlot(order), order div 2)

proc playerSlotLimit(config: GameConfig): int =
  ## Returns the number of slots players may occupy.
  if config.closedRoster: config.slots.len else: MaxPlayers

proc usedSkins*(config: GameConfig): set[Skin] =
  ## Returns the skins needed by slots that can join this game.
  if config.slots.len < config.playerSlotLimit():
    result.incl(DefaultSkin)
  for slot in config.slots:
    result.incl(slot.skin)

proc canAddPlayer*(sim: SimServer): bool =
  ## Returns whether the game has room for another player.
  sim.players.len < sim.config.playerSlotLimit()

proc playerLimitError(config: GameConfig): string =
  ## Returns a user-facing message for the current player cap.
  if config.closedRoster:
    let limit = config.playerSlotLimit()
    return "Configured roster is full (" & $limit &
      (if limit == 1: " player)." else: " players).")
  "can't do more than " & $MaxPlayers & " players."

proc slotConfig(config: GameConfig, slotIndex: int): PlayerSlotConfig =
  ## Returns one slot config or an empty config for missing entries.
  if slotIndex >= 0 and slotIndex < config.slots.len:
    config.slots[slotIndex]
  else:
    PlayerSlotConfig()

proc slotRestricted(config: GameConfig, slotIndex: int): bool =
  ## Returns true when a slot has identity restrictions.
  let slot = config.slotConfig(slotIndex)
  slot.name.len > 0 or slot.token.len > 0

proc slotAuthMatches(
  config: GameConfig,
  slotIndex: int,
  address,
  token: string
): bool =
  ## Returns true when a player satisfies one configured slot.
  let slot = config.slotConfig(slotIndex)
  if slot.name.len > 0 and address != slot.name:
    return false
  if slot.token.len > 0 and token != slot.token:
    return false
  true

proc hasConfiguredToken(config: GameConfig, token: string): bool =
  ## Returns true when a token matches any configured slot.
  for slot in config.slots:
    if slot.token.len > 0 and slot.token == token:
      return true
  false

proc hasConfiguredTokens(config: GameConfig): bool =
  ## Returns true when any slot has an auth token.
  for slot in config.slots:
    if slot.token.len > 0:
      return true
  false

proc validatePlayerSlot(
  config: GameConfig,
  slotIndex: int,
  address,
  token: string
) =
  ## Raises when a player does not satisfy one configured slot.
  let slot = config.slotConfig(slotIndex)
  if slot.name.len > 0 and address != slot.name:
    raise newException(
      CtfError,
      "Player name does not match configured slot " & $slotIndex & "."
    )
  if slot.token.len > 0 and token != slot.token:
    raise newException(
      CtfError,
      "Player token does not match configured slot " & $slotIndex & "."
    )

proc configuredPlayerName*(config: GameConfig, requestedSlot: int, token: string): string =
  ## Returns the configured identity for a tokenized slot request.
  if token.len == 0:
    return ""
  if requestedSlot >= 0 and requestedSlot < config.slots.len:
    let slot = config.slots[requestedSlot]
    if slot.name.len > 0 and slot.token.len > 0 and slot.token == token:
      return slot.name
    return ""
  for slot in config.slots:
    if slot.name.len > 0 and slot.token.len > 0 and slot.token == token:
      return slot.name
  ""

proc playerJoinAllowed*(
  config: GameConfig,
  address: string,
  requestedSlot: int,
  token: string
): bool =
  ## Returns whether a player websocket request can pass configured slot auth.
  if requestedSlot >= config.playerSlotLimit():
    return false
  if token.len > 0 and config.hasConfiguredTokens() and
      not config.hasConfiguredToken(token):
    return false
  if requestedSlot >= 0:
    return config.slotAuthMatches(requestedSlot, address, token)
  for i in 0 ..< config.slots.len:
    let slot = config.slots[i]
    let matchedName = slot.name.len > 0 and slot.name == address
    let matchedToken =
      slot.token.len > 0 and token.len > 0 and slot.token == token
    if matchedName or matchedToken:
      return config.slotAuthMatches(i, address, token)
  not config.closedRoster

proc slotOccupied(sim: SimServer, slotIndex: int): bool =
  ## Returns true when a player already owns a slot.
  for player in sim.players:
    if player.joinOrder == slotIndex:
      return true
  false

proc matchingConfiguredSlot(
  sim: SimServer,
  address,
  token: string
): int =
  ## Returns a matching configured slot for a player or -1.
  for i in 0 ..< sim.config.slots.len:
    if sim.slotOccupied(i):
      continue
    let slot = sim.config.slots[i]
    let couldMatchName = slot.name.len > 0 and slot.name == address
    let couldMatchToken = slot.token.len > 0 and slot.token == token
    if (couldMatchName or couldMatchToken) and
        sim.config.slotAuthMatches(i, address, token):
      return i
  -1

proc conflictingConfiguredSlot(
  sim: SimServer,
  address,
  token: string
): int =
  ## Returns a configured slot matched by name or token but not both.
  for i in 0 ..< sim.config.slots.len:
    if sim.slotOccupied(i):
      continue
    let slot = sim.config.slots[i]
    let matchedName = slot.name.len > 0 and slot.name == address
    let matchedToken =
      slot.token.len > 0 and token.len > 0 and slot.token == token
    if (matchedName or matchedToken) and
        not sim.config.slotAuthMatches(i, address, token):
      return i
  -1

proc namedConfiguredSlot(sim: SimServer, address: string): int =
  ## Returns an open configured slot with a matching name.
  for i in 0 ..< sim.config.slots.len:
    if sim.slotOccupied(i):
      continue
    let slot = sim.config.slots[i]
    if slot.name.len > 0 and slot.name == address:
      return i
  -1

proc nextAutoSlot(sim: SimServer, address, token: string): int =
  ## Returns the next open unrestricted or matching slot.
  let slotLimit = sim.config.playerSlotLimit()
  for i in sim.nextJoinOrder ..< slotLimit:
    if sim.slotOccupied(i):
      continue
    if not sim.config.slotRestricted(i) or
        sim.config.slotAuthMatches(i, address, token):
      return i
  for i in 0 ..< sim.nextJoinOrder:
    if i >= slotLimit:
      break
    if sim.slotOccupied(i):
      continue
    if not sim.config.slotRestricted(i) or
        sim.config.slotAuthMatches(i, address, token):
      return i
  -1

proc advanceJoinOrder(sim: var SimServer) =
  ## Moves the auto-slot cursor to the next open slot.
  while sim.nextJoinOrder < MaxPlayers and
      sim.slotOccupied(sim.nextJoinOrder):
    inc sim.nextJoinOrder

proc resolvePlayerSlot*(
  sim: SimServer,
  address,
  token: string,
  requestedSlot: int
): int =
  ## Returns the slot a player should use or raises on rejection.
  if requestedSlot >= MaxPlayers:
    raise newException(
      CtfError,
      "Player slot must be between 0 and 7."
    )
  if token.len > 0 and sim.config.hasConfiguredTokens() and
      not sim.config.hasConfiguredToken(token):
    raise newException(CtfError, "Player token is not configured.")
  if requestedSlot >= 0:
    if requestedSlot >= sim.config.playerSlotLimit():
      raise newException(CtfError, "Player slot is outside configured roster.")
    if sim.slotOccupied(requestedSlot):
      raise newException(
        CtfError,
        "Player slot " & $requestedSlot & " is already occupied."
      )
    sim.config.validatePlayerSlot(requestedSlot, address, token)
    return requestedSlot
  result = sim.matchingConfiguredSlot(address, token)
  if result >= 0:
    return result
  let conflict = sim.conflictingConfiguredSlot(address, token)
  if conflict >= 0:
    raise newException(
      CtfError,
      "Player credentials do not match configured slot " & $conflict & "."
    )
  result = sim.nextAutoSlot(address, token)
  if result < 0:
    raise newException(CtfError, "No available player slot.")

proc nextPlayerSlot*(sim: SimServer): int =
  ## Returns the slot required for the next live player index.
  sim.players.len

proc resolveTrustedPlayerSlot(
  sim: SimServer,
  address: string,
  requestedSlot: int
): int =
  ## Returns a trusted replay slot without requiring the original token.
  if requestedSlot >= MaxPlayers:
    raise newException(
      CtfError,
      "Player slot must be between 0 and 7."
    )
  if requestedSlot >= 0:
    if requestedSlot >= sim.config.playerSlotLimit():
      raise newException(CtfError, "Player slot is outside configured roster.")
    if sim.slotOccupied(requestedSlot):
      raise newException(
        CtfError,
        "Player slot " & $requestedSlot & " is already occupied."
      )
    return requestedSlot
  result = sim.namedConfiguredSlot(address)
  if result >= 0:
    return result
  result = sim.nextAutoSlot(address, "")
  if result < 0:
    raise newException(CtfError, "No available player slot.")

proc rewardAccountIndex(sim: SimServer, address: string): int =
  ## Returns the reward account index for an address.
  for i in 0 ..< sim.rewardAccounts.len:
    if sim.rewardAccounts[i].address == address:
      return i
  -1

proc ensureRewardAccount(sim: var SimServer, address: string): int =
  ## Returns the reward account index, creating the account if needed.
  result = sim.rewardAccountIndex(address)
  if result < 0:
    sim.rewardAccounts.add RewardAccount(
      address: address,
      slotIndex: -1,
      reward: 0
    )
    result = sim.rewardAccounts.high

proc bindRewardAccountSlot(
  sim: var SimServer,
  accountIndex,
  slotIndex: int
) =
  ## Binds a reward account to the stable player slot for this match.
  if accountIndex < 0 or accountIndex >= sim.rewardAccounts.len:
    return
  for i in 0 ..< sim.rewardAccounts.len:
    if i != accountIndex and sim.rewardAccounts[i].slotIndex == slotIndex:
      sim.rewardAccounts[i].slotIndex = -1
  sim.rewardAccounts[accountIndex].slotIndex = slotIndex

proc rewardAccountIndexForSlot(sim: SimServer, slotIndex: int): int =
  ## Returns the newest reward account index for a player slot.
  if slotIndex < 0 or sim.rewardAccounts.len == 0:
    return -1
  for i in countdown(sim.rewardAccounts.high, 0):
    if sim.rewardAccounts[i].slotIndex == slotIndex:
      return i
  -1

proc playerIndexForSlot(sim: SimServer, slotIndex: int): int =
  ## Returns the live player index for a player slot.
  for i in 0 ..< sim.players.len:
    if sim.players[i].joinOrder == slotIndex:
      return i
  -1

proc legacyGrenadeThrowerIndex(
  sim: SimServer,
  grenade: AirborneGrenade
): int {.inline.} =
  ## Retains GV24's mutable-index kill counter solely because player.kills is
  ## hashed. Attribution and results use throwerSlot/throwerAccount instead.
  if grenade.thrower >= 0 and grenade.thrower < sim.players.len:
    grenade.thrower
  else:
    -1

proc playerResultSlotCount(sim: SimServer): int =
  ## Returns the number of player slots represented in final results.
  result = sim.config.slots.len
  if sim.config.closedRoster:
    return
  for player in sim.players:
    result = max(result, player.joinOrder + 1)
  for account in sim.rewardAccounts:
    if account.slotIndex >= 0:
      result = max(result, account.slotIndex + 1)

proc playerAddressOccupied*(sim: SimServer, address: string): bool =
  ## Returns true when a player identity is already connected.
  for player in sim.players:
    if player.address == address:
      return true
  false

proc removePlayerAt*(sim: var SimServer, playerIndex: int) =
  ## Removes one live player and keeps index-keyed state aligned.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  for team in Team:
    if sim.flags[team].carrier == playerIndex:
      sim.logGameEvent(teamText(team) & " heart returned home")
      sim.resetFlag(team)
    elif sim.flags[team].carrier > playerIndex:
      dec sim.flags[team].carrier
  sim.players.delete(playerIndex)
  if playerIndex < sim.fovCaches.len:
    sim.fovCaches.delete(playerIndex)

proc addPlayer*(
  sim: var SimServer,
  address: string,
  requestedSlot = -1,
  token = "",
  trusted = false
): int =
  ## Adds one player, optionally validating and using a requested slot.
  if not sim.canAddPlayer():
    raise newException(CtfError, sim.config.playerLimitError())
  if sim.playerAddressOccupied(address):
    raise newException(
      CtfError,
      "Player name is already connected."
    )
  let
    order =
      if trusted:
        sim.resolveTrustedPlayerSlot(address, requestedSlot)
      else:
        sim.resolvePlayerSlot(address, token, requestedSlot)
    nextSlot = sim.nextPlayerSlot()
  if not trusted and order != nextSlot:
    raise newException(
      CtfError,
      "Player slot " & $order & " cannot join before slot " &
        $nextSlot & "."
    )
  let
    slot = sim.config.slotConfig(order)
    team = sim.teamForSlot(order)
    color =
      if slot.hasColor:
        slot.color
      else:
        teamColor(team)
    accountIndex = sim.ensureRewardAccount(address)
  let spawn = sim.spawnPosition(team, order div 2)
  sim.bindRewardAccountSlot(accountIndex, order)
  sim.rewardAccounts[accountIndex].hasTeam = false
  sim.rewardAccounts[accountIndex].won = false
  sim.rewardAccounts[accountIndex].abandoned = false
  sim.players.add Player(
    x: spawn.x,
    y: spawn.y,
    homeX: spawn.x,
    homeY: spawn.y,
    aimBrads: spawnAimBrads(team),
    flipH: team == Blue,
    windupBrads: -1,
    team: team,
    alive: true,
    lives: sim.config.lives,
    hp: sim.config.hitPoints,
    joinOrder: order,
    address: address,
    color: color,
    skin: slot.skin,
    lastShoutTick: -1,
    paintHitTick: -1,
    reward: sim.rewardAccounts[accountIndex].reward
  )
  sim.fovCaches.add PlayerFov(
    valid: false,
    visible: newSeq[bool](FovCellCount)
  )
  sim.advanceJoinOrder()
  sim.arrangeHomePositions()
  sim.players.high

proc addReward*(sim: var SimServer, playerIndex, amount: int) =
  ## Adds accumulated reward to a player and its address account.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let address = sim.players[playerIndex].address
  let index = sim.ensureRewardAccount(address)
  sim.bindRewardAccountSlot(index, sim.players[playerIndex].joinOrder)
  sim.rewardAccounts[index].reward += amount
  sim.players[playerIndex].reward = sim.rewardAccounts[index].reward

proc rewardAccountForPlayer(
  sim: var SimServer,
  playerIndex: int
): int =
  ## Returns the reward account index for a player, creating it if missing.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return -1
  let address = sim.players[playerIndex].address
  result = sim.ensureRewardAccount(address)
  sim.bindRewardAccountSlot(result, sim.players[playerIndex].joinOrder)

proc recordGameTeamAssigned*(
  sim: var SimServer,
  playerIndex: int
) =
  ## Records the team assignment for one player at game start.
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index < 0:
    return
  sim.rewardAccounts[index].team = sim.players[playerIndex].team
  sim.rewardAccounts[index].hasTeam = true
  sim.rewardAccounts[index].won = false
  sim.rewardAccounts[index].abandoned = false
  if sim.players[playerIndex].team == Red:
    inc sim.rewardAccounts[index].gamesRed
  else:
    inc sim.rewardAccounts[index].gamesBlue

proc recordGameAbandon*(sim: var SimServer, playerIndex: int) =
  ## Marks a player as abandoned for the current game.
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index < 0:
    return
  sim.rewardAccounts[index].abandoned = true

proc recordGameWin*(sim: var SimServer, playerIndex: int) =
  ## Increments the lifetime per-team win counter for one player.
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index < 0:
    return
  sim.rewardAccounts[index].won = true
  if sim.players[playerIndex].team == Red:
    inc sim.rewardAccounts[index].winsRed
  else:
    inc sim.rewardAccounts[index].winsBlue

proc recordKill*(sim: var SimServer, playerIndex: int) =
  ## Increments the kill counter for one player.
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index >= 0:
    inc sim.rewardAccounts[index].kills
  inc sim.players[playerIndex].kills

proc recordTeamKill*(sim: var SimServer, killerIndex, victimIndex: int) =
  ## Counts a teammate kill (the endscreen "backstab" badge). Weapon-agnostic:
  ## bullets, grenade blasts, and spray cones all land here.
  if killerIndex < 0 or killerIndex >= sim.players.len:
    return
  if victimIndex < 0 or victimIndex >= sim.players.len:
    return
  if killerIndex == victimIndex:
    return
  if sim.players[killerIndex].team == sim.players[victimIndex].team:
    inc sim.players[killerIndex].teamKills

proc recordDeath*(sim: var SimServer, playerIndex: int) =
  ## Increments the death counter for one player.
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index >= 0:
    inc sim.rewardAccounts[index].deaths
  inc sim.players[playerIndex].deaths

proc recordCapture*(sim: var SimServer, playerIndex: int) =
  ## Increments the capture counter for one player.
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index >= 0:
    inc sim.rewardAccounts[index].captures
  inc sim.players[playerIndex].captures

proc playerResultsJson*(sim: SimServer): string =
  ## Returns final player rewards and win states as JSON.
  var
    resultSlots: seq[int] = @[]
    names = newJArray()
    scores = newJArray()
    win = newJArray()
    teamList = newJArray()
    killsList = newJArray()
    deathsList = newJArray()
    capturesList = newJArray()
    shotsFiredList = newJArray()
    shotsHitList = newJArray()
    results = newJObject()
  for slotIndex in 0 ..< sim.playerResultSlotCount():
    resultSlots.add(slotIndex)
  for slotIndex in resultSlots:
    let
      playerIndex = sim.playerIndexForSlot(slotIndex)
      accountIndex =
        if playerIndex >= 0:
          sim.rewardAccountIndex(sim.players[playerIndex].address)
        else:
          sim.rewardAccountIndexForSlot(slotIndex)
      slotConfig = sim.config.slotConfig(slotIndex)
    var
      name =
        if slotConfig.name.len > 0:
          slotConfig.name
        else:
          "player-" & $slotIndex
      reward = 0
      playerTeam = Red
      hasTeam = false
      playerWon = false
      kills = 0
      deaths = 0
      captures = 0
      shotsFired = 0
      shotsHit = 0
    if accountIndex >= 0:
      let account = sim.rewardAccounts[accountIndex]
      name = account.address
      reward = account.reward
      playerTeam = account.team
      hasTeam = account.hasTeam
      playerWon = account.won
      kills = account.kills
      deaths = account.deaths
      captures = account.captures
    if playerIndex >= 0:
      let player = sim.players[playerIndex]
      name = player.address
      if accountIndex < 0:
        reward = player.reward
      playerTeam = player.team
      hasTeam = true
      playerWon = not sim.isDraw and player.team == sim.winner
      # Accuracy counters live only on the player (analysis-only, never
      # mirrored into reward accounts): a slot whose player left reports 0.
      shotsFired = player.shotsFired
      shotsHit = player.shotsHit
    if not hasTeam and slotConfig.hasTeam:
      playerTeam = slotConfig.team
      hasTeam = true
    names.add(%name)
    scores.add(%reward)
    win.add(%playerWon)
    teamList.add(%(if hasTeam: teamText(playerTeam) else: "unknown"))
    killsList.add(%kills)
    deathsList.add(%deaths)
    capturesList.add(%captures)
    shotsFiredList.add(%shotsFired)
    shotsHitList.add(%shotsHit)
  results["names"] = names
  results["scores"] = scores
  results["win"] = win
  results["team"] = teamList
  results["kills"] = killsList
  results["deaths"] = deathsList
  results["captures"] = capturesList
  # shotsFired/shotsHit stay OUT of the results payload: the platform's
  # episode-results schema is closed (additionalProperties: false) and the
  # certifier rejects unknown fields, blocking every canonical upload. The
  # counters remain on the players for replay-side analysis; re-add here
  # only after the platform schema learns the fields.
  $results

proc grenadeSpawnPoints*(): array[4, tuple[x, y: int]] =
  ## The four corner grenade spawn points: two on each team's side.
  let inset = ArenaBorder + GrenadeSpawnInset
  [(inset, inset),
    (inset, MapHeight - inset),
    (MapWidth - inset, inset),
    (MapWidth - inset, MapHeight - inset)]

proc resetGrenades*(sim: var SimServer) =
  ## Refills every corner pickup and clears carried and airborne grenades.
  let points = grenadeSpawnPoints()
  for i in 0 ..< sim.grenadeSpawns.len:
    sim.grenadeSpawns[i] = PickupSpawn(
      x: points[i].x, y: points[i].y, present: true, respawnAt: 0
    )
  sim.airborneGrenades = @[]
  for i in 0 ..< sim.players.len:
    sim.players[i].hasGrenade = false
    sim.players[i].throwCharge = 0

proc resetMedKits*(sim: var SimServer) =
  ## Places both med kits on the map's active spawn points (generated maps
  ## draw the pair per map; hand-authored maps carry the classic center-line
  ## thirds), nudged to the nearest walkable floor, and refills them.
  let targets =
    if sim.gameMap.medKitSpawns.len >= 2:
      [
        (sim.gameMap.medKitSpawns[0].x, sim.gameMap.medKitSpawns[0].y),
        (sim.gameMap.medKitSpawns[1].x, sim.gameMap.medKitSpawns[1].y),
      ]
    else:
      [
        (MapWidth div 2, MapHeight div 3),
        (MapWidth div 2, 2 * MapHeight div 3),
      ]
  for i in 0 ..< sim.medKitSpawns.len:
    let spot = sim.nearestWalkable(targets[i][0], targets[i][1])
    sim.medKitSpawns[i] = PickupSpawn(
      x: spot.x, y: spot.y, present: true, respawnAt: 0
    )

proc resetShields*(sim: var SimServer) =
  ## Places one shield deep in each team's endzone, in the same back column
  ## as the corner grenade pickups but in the BOTTOM half (three quarters of
  ## the map height down) — the spray cans hold the matching top-half spots —
  ## nudged to the nearest walkable floor, and refills both.
  let
    inset = ArenaBorder + GrenadeSpawnInset
    endzoneY = 3 * MapHeight div 4
    targets = [
      (inset, endzoneY),
      (MapWidth - inset, endzoneY)
    ]
  for i in 0 ..< sim.shieldSpawns.len:
    let spot = sim.nearestWalkable(targets[i][0], targets[i][1])
    sim.shieldSpawns[i] = PickupSpawn(
      x: spot.x, y: spot.y, present: true, respawnAt: 0
    )
  for i in 0 ..< sim.players.len:
    sim.players[i].hasShield = false
    sim.players[i].shieldHp = 0
proc plasmaArcSpawnPoints*(): array[2, tuple[x, y: int]] =
  ## The two spray can spawn points, nudged to walkable floor: the same side
  ## back columns as the shields, but in the TOP half (a quarter of the map
  ## height down) so the two pickups no longer sit on top of each other —
  ## spray cans high, shields low.
  let inset = ArenaBorder + PlasmaArcSpawnInset
  [(inset, MapHeight div 4),
    (MapWidth - inset, MapHeight div 4)]

proc resetPlasmaArcs*(sim: var SimServer) =
  ## Refills both side-center spray can pickups and clears carried cans.
  let points = plasmaArcSpawnPoints()
  for i in 0 ..< sim.plasmaArcSpawns.len:
    let spot = sim.nearestWalkable(points[i].x, points[i].y)
    sim.plasmaArcSpawns[i] = PickupSpawn(
      x: spot.x, y: spot.y, present: true, respawnAt: 0
    )
  sim.plasmaArcFlashes = @[]
  for i in 0 ..< sim.players.len:
    sim.players[i].hasPlasmaArc = false
    sim.players[i].arcTicksLeft = 0
    sim.players[i].arcHitMask = 0

proc startGame*(sim: var SimServer) =
  sim.logGameEvent("game started: players=" & $sim.players.len)
  sim.recentShots = @[]
  sim.hitFlashes = @[]
  sim.bubbleImpacts = @[]
  sim.splatters = @[]
  sim.damagePops = @[]
  sim.recentShouts = @[]
  sim.arrangeHomePositions()
  for i in 0 ..< sim.players.len:
    sim.players[i].lastShoutTick = -1
    sim.players[i].alive = true
    sim.players[i].lives = sim.config.lives
    sim.players[i].hp = sim.config.hitPoints
    sim.players[i].respawnTimer = 0
    sim.players[i].fireCooldown = 0
    sim.players[i].fireWindup = 0
    sim.players[i].windupBrads = -1
    sim.players[i].aimBrads = spawnAimBrads(sim.players[i].team)
    sim.players[i].flipH = sim.players[i].team == Blue
    sim.players[i].carryingFlag = false
    sim.players[i].hasShield = false
    sim.players[i].shieldHp = 0
    sim.players[i].kills = 0
    sim.players[i].deaths = 0
    sim.players[i].captures = 0
    sim.players[i].shotsFired = 0
    sim.players[i].shotsHit = 0
    sim.players[i].multiKills2 = 0
    sim.players[i].multiKills3 = 0
    sim.players[i].teamKills = 0
    sim.players[i].arcKillsThisFire = 0
    sim.recordGameTeamAssigned(i)
  sim.resetFlags()
  sim.resetGrenades()
  sim.resetShields()
  sim.resetPlasmaArcs()
  sim.emitPhaseChange(Playing)
  sim.phase = Playing
  sim.gameStartTick = sim.tickCount
  sim.timeLimitReached = false
  sim.overtimeTicks = 0
  sim.isDraw = false
  sim.lastLobbyPlayersLogged = -1
  sim.lastLobbyNeededLogged = -1
  sim.lastLobbySecondsLogged = -1

proc signOf(value: int): int {.inline.} =
  ## Returns the sign of one integer.
  if value < 0:
    return -1
  if value > 0:
    return 1
  0

proc slideScanRadius(sim: SimServer, carry, velocity: int): int =
  ## Returns the perpendicular scan radius for blocked movement.
  let
    pending = abs(carry) div sim.config.motionScale
    speed = (
      abs(velocity) + sim.config.motionScale - 1
    ) div sim.config.motionScale
  clamp(max(1, max(pending, speed)), 1, MovementSlideMaxScan)

proc playersOverlapAt(sim: SimServer, movingIndex, x, y: int): bool =
  ## True when a player footprint centered at (x, y) would overlap another
  ## live player's footprint.
  for i in 0 ..< sim.players.len:
    if i == movingIndex or not sim.players[i].alive:
      continue
    if max(abs(x - sim.players[i].x), abs(y - sim.players[i].y)) <=
        PlayerSolidSpan:
      return true
  false

proc blockingPlayerAt(
  sim: SimServer,
  movingIndex, fromX, fromY, toX, toY: int
): int =
  ## Returns the index of a live player whose body blocks this step, or -1.
  ## A step is blocked when it lands overlapping another body without
  ## increasing the separation — moving apart is always allowed, so bodies
  ## that start overlapped (a respawn onto an occupied home) can escape.
  for i in 0 ..< sim.players.len:
    if i == movingIndex or not sim.players[i].alive:
      continue
    let toDist =
      max(abs(toX - sim.players[i].x), abs(toY - sim.players[i].y))
    if toDist > PlayerSolidSpan:
      continue
    let fromDist =
      max(abs(fromX - sim.players[i].x), abs(fromY - sim.players[i].y))
    if toDist <= fromDist:
      return i
  -1

proc canSlideHorizontal(
  sim: SimServer,
  movingIndex, x, y, step, offset: int
): bool =
  ## Returns true when a horizontal step can slide by one offset.
  if offset == 0:
    return false
  let slideStep = signOf(offset)
  for i in 1 .. abs(offset):
    if not sim.canOccupy(x, y + slideStep * i) or
        sim.playersOverlapAt(movingIndex, x, y + slideStep * i):
      return false
  sim.canOccupy(x + step, y + offset) and
    not sim.playersOverlapAt(movingIndex, x + step, y + offset)

proc canSlideVertical(
  sim: SimServer,
  movingIndex, x, y, step, offset: int
): bool =
  ## Returns true when a vertical step can slide by one offset.
  if offset == 0:
    return false
  let slideStep = signOf(offset)
  for i in 1 .. abs(offset):
    if not sim.canOccupy(x + slideStep * i, y) or
        sim.playersOverlapAt(movingIndex, x + slideStep * i, y):
      return false
  sim.canOccupy(x + offset, y + step) and
    not sim.playersOverlapAt(movingIndex, x + offset, y + step)

proc trySlideOffset(
  sim: var SimServer,
  movingIndex, step, offset: int,
  horizontal: bool
): bool =
  ## Tries one candidate slide offset for a blocked movement step.
  template player: untyped = sim.players[movingIndex]
  if horizontal:
    if not sim.canSlideHorizontal(movingIndex, player.x, player.y, step, offset):
      return false
    player.x += step
    player.y += offset
  else:
    if not sim.canSlideVertical(movingIndex, player.x, player.y, step, offset):
      return false
    player.x += offset
    player.y += step
  true

proc trySlideMove(
  sim: var SimServer,
  movingIndex, step, radius, preferredSlide: int,
  horizontal: bool
): bool =
  ## Tries nearby slide offsets for one blocked movement step.
  if radius <= 0:
    return false
  let preferred = signOf(preferredSlide)
  for distance in 1 .. radius:
    if preferred != 0:
      if sim.trySlideOffset(
        movingIndex,
        step,
        preferred * distance,
        horizontal
      ):
        return true
      if sim.trySlideOffset(
        movingIndex,
        step,
        -preferred * distance,
        horizontal
      ):
        return true
    else:
      if sim.trySlideOffset(movingIndex, step, -distance, horizontal):
        return true
      if sim.trySlideOffset(movingIndex, step, distance, horizontal):
        return true
  false

proc bouncePlayers(sim: var SimServer, a, b: int, horizontal: bool) =
  ## Applies a slightly elastic equal-mass collision response along one axis
  ## between two touching players: the axis velocities average out (the
  ## shove) plus playerBouncePct percent of the closing speed rebounds (the
  ## bounce). At 100 this is a billiard-ball velocity swap, at 0 a dead-stop
  ## push.
  let
    pct = sim.config.playerBouncePct
    v1 = if horizontal: sim.players[a].velX else: sim.players[a].velY
    v2 = if horizontal: sim.players[b].velX else: sim.players[b].velY
    total = v1 + v2
    rebound = (v1 - v2) * pct div 100
  if horizontal:
    sim.players[a].velX = (total - rebound) div 2
    sim.players[b].velX = (total + rebound) div 2
  else:
    sim.players[a].velY = (total - rebound) div 2
    sim.players[b].velY = (total + rebound) div 2

proc applyMomentumAxis(
  sim: var SimServer,
  playerIndex, preferredSlide: int,
  horizontal: bool
) =
  ## Applies one fixed-point movement axis with collision sliding. Walls
  ## absorb blocked motion; another player's body blocks the same way but
  ## answers with a slightly elastic shove (bouncePlayers).
  template player: untyped = sim.players[playerIndex]
  let velocity = if horizontal: player.velX else: player.velY
  var carry =
    (if horizontal: player.carryX else: player.carryY) + velocity
  while abs(carry) >= sim.config.motionScale:
    let step = if carry < 0: -1 else: 1
    let
      nx = if horizontal: player.x + step else: player.x
      ny = if horizontal: player.y else: player.y + step
    var blocker = -1
    if sim.canOccupy(nx, ny):
      blocker = sim.blockingPlayerAt(playerIndex, player.x, player.y, nx, ny)
    if sim.canOccupy(nx, ny) and blocker < 0:
      if horizontal:
        player.x = nx
      else:
        player.y = ny
      carry -= step * sim.config.motionScale
    else:
      let radius = sim.slideScanRadius(carry, velocity)
      if sim.trySlideMove(
        playerIndex,
        step,
        radius,
        preferredSlide,
        horizontal
      ):
        carry -= step * sim.config.motionScale
      else:
        if blocker >= 0:
          sim.bouncePlayers(playerIndex, blocker, horizontal)
        carry = 0
        break
  if horizontal:
    player.carryX = carry
  else:
    player.carryY = carry

proc distSq*(ax, ay, bx, by: int): int =
  let
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy

proc actorColor*(colorIndex, tint: uint8): uint8 =
  ## Returns the final color for actor wildcard pixels.
  if colorIndex == TintColor:
    return tint
  if colorIndex == ShadeTintColor:
    return ShadowMap[tint and 0x0f]
  colorIndex

proc isWall*(sim: SimServer, mx, my: int): bool =
  if mx < 0 or my < 0 or mx >= MapWidth or my >= MapHeight:
    return true
  sim.wallMask[mapIndex(mx, my)]

proc lineOfSightClear*(sim: SimServer, ax, ay, bx, by: int): bool =
  ## Returns true when no wall blocks the segment between two map points.
  let
    dx = bx - ax
    dy = by - ay
    steps = max(abs(dx), abs(dy))
  if steps == 0:
    return true
  for s in 1 .. steps:
    let
      rx = ax + dx * s div steps
      ry = ay + dy * s div steps
    if sim.isWall(rx, ry):
      return false
  true

proc gameTicksElapsed*(sim: SimServer): int =
  ## Returns ticks elapsed since the current game left the lobby.
  if sim.gameStartTick < 0:
    return 0
  max(0, sim.tickCount - sim.gameStartTick)

proc effectiveMaxTicks*(sim: SimServer): int =
  ## Returns the game's tick limit including banked action-floor overtime
  ## (0 stays "no limit").
  if sim.config.maxTicks <= 0:
    return 0
  sim.config.maxTicks + sim.overtimeTicks

proc floorGameClock(sim: var SimServer) =
  ## Guarantees at least ActionClockFloorTicks of clock remain. Kills and
  ## heart steals call this so a timed game never ends mid-action; the
  ## extension banks into overtimeTicks (per-game, part of gameHash).
  if sim.config.maxTicks <= 0 or sim.phase != Playing:
    return
  let remaining = sim.effectiveMaxTicks() - sim.gameTicksElapsed()
  if remaining < ActionClockFloorTicks:
    sim.overtimeTicks += ActionClockFloorTicks - remaining

proc killPlayer*(
  sim: var SimServer,
  targetIndex,
  killerIndex: int,
  killerSlot = -1
) =
  ## Applies a fatal hit: return any carried flag to its pedestal, decrement
  ## lives, start respawn.
  if targetIndex < 0 or targetIndex >= sim.players.len:
    return
  if not sim.players[targetIndex].alive:
    return
  sim.logGameEvent(
    playerColorText(sim.players[targetIndex].color) &
      " killed by " & sim.playerText(killerIndex)
  )
  # A kill is action: keep at least ActionClockFloorTicks on the clock.
  sim.floorGameClock()
  # A dying trigger pull never releases, and a carried grenade is lost.
  sim.players[targetIndex].fireWindup = 0
  sim.players[targetIndex].windupBrads = -1
  sim.players[targetIndex].hasGrenade = false
  sim.players[targetIndex].hasShield = false
  sim.players[targetIndex].shieldHp = 0
  sim.players[targetIndex].hasPlasmaArc = false
  sim.players[targetIndex].arcTicksLeft = 0
  sim.players[targetIndex].throwCharge = 0
  for team in Team:
    if sim.flags[team].carrier == targetIndex:
      sim.players[targetIndex].carryingFlag = false
      sim.logGameEvent(teamText(team) & " heart returned home")
      sim.resetFlag(team)
  # Leave a cosmetic splatter at the death spot (never enters gameHash).
  sim.splatters.add SplatterFx(
    x: sim.players[targetIndex].x,
    y: sim.players[targetIndex].y,
    tick: sim.tickCount,
    color: sim.players[targetIndex].color,
    hit: false
  )
  # A floating "KO" kill marker rises and fades from the death spot — the same
  # mechanism as the "-1" damage pops, so a kill reads at a glance in the
  # spectator/replay view (cosmetic only, never in gameHash).
  sim.damagePops.add DamageFx(
    x: sim.players[targetIndex].x + CollisionW div 2,
    y: sim.players[targetIndex].y + CollisionH div 2,
    tick: sim.tickCount,
    amount: 0,
    color: sim.players[targetIndex].color,
    kill: true
  )
  sim.players[targetIndex].alive = false
  sim.players[targetIndex].velX = 0
  sim.players[targetIndex].velY = 0
  sim.players[targetIndex].carryX = 0
  sim.players[targetIndex].carryY = 0
  sim.recordDeath(targetIndex)
  # Death is the victim-side record (source = victim, target = killer); the
  # weapon-attributed Kill is emitted by each weapon's own damage site, where
  # the weapon is known first-hand.
  sim.emitEvent(
    Death, source = targetIndex, target = killerIndex,
    x = float(sim.players[targetIndex].x + CollisionW div 2),
    y = float(sim.players[targetIndex].y + CollisionH div 2),
    targetSlot = killerSlot
  )
  if sim.players[targetIndex].lives > 0:
    dec sim.players[targetIndex].lives
  sim.players[targetIndex].respawnTimer =
    if sim.players[targetIndex].lives > 0:
      max(1, sim.config.respawnTicks)
    else:
      0

proc absorbDamage*(sim: var SimServer, targetIndex: int, amount: int): int {.discardable.} =
  ## Applies damage to a player: the shield layer soaks hits before base hp.
  ## Callers keep their own death checks on the base hp that remains. Returns
  ## how many hp the shield layer absorbed (`fromShield`) — first-hand `blocked`
  ## for the tier-2 Damage event; callers that don't need it can ignore it.
  let fromShield = min(sim.players[targetIndex].shieldHp, amount)
  sim.players[targetIndex].shieldHp -= fromShield
  sim.players[targetIndex].hp -= amount - fromShield
  if fromShield > 0 and sim.players[targetIndex].shieldHp == 0:
    # A broken shield is GONE: the carry icon, the " shield" label, and the
    # fire slowdown all end with the bubble, and an in-flight slowed cooldown
    # re-clamps so the next shot fires at the normal rate.
    sim.players[targetIndex].hasShield = false
    sim.players[targetIndex].fireCooldown = min(
      sim.players[targetIndex].fireCooldown, sim.config.fireCooldownTicks
    )
  fromShield

proc canFire*(sim: SimServer, shooterIndex: int): bool =
  ## Returns whether one player is able to fire a shot right now.
  if shooterIndex < 0 or shooterIndex >= sim.players.len:
    return false
  let shooter = sim.players[shooterIndex]
  shooter.alive and shooter.fireCooldown <= 0 and not shooter.hasPlasmaArc

proc canFireArc*(sim: SimServer, attackerIndex: int): bool =
  ## Returns whether one player can fire an immediate spray burst.
  if attackerIndex < 0 or attackerIndex >= sim.players.len:
    return false
  let attacker = sim.players[attackerIndex]
  attacker.alive and attacker.hasPlasmaArc and attacker.fireCooldown <= 0

proc selectArcVictims(
  sim: SimServer,
  attackerIndex: int
): seq[int] =
  ## Returns every living player inside the attacker's forward spray cone,
  ## computed from the attacker's CURRENT position and aim: a live cone
  ## tracks its owner across the active window.
  if attackerIndex < 0 or attackerIndex >= sim.players.len:
    return @[]
  let
    attacker = sim.players[attackerIndex]
    ax = attacker.x + CollisionW div 2
    ay = attacker.y + CollisionH div 2
    (ux, uy) = aimVector(attacker.aimBrads)
    reach = float(PlasmaArcReach)
    # The cone's half-width grows linearly with forward distance, hitting
    # PlasmaArcMaxWidth / 2 exactly at the reach cap.
    halfWidthSlope = float(PlasmaArcMaxWidth) / (2.0 * reach)
  for i in 0 ..< sim.players.len:
    if i == attackerIndex or not sim.players[i].alive:
      continue
    let
      vx = float(sim.players[i].x + CollisionW div 2 - ax)
      vy = float(sim.players[i].y + CollisionH div 2 - ay)
      forward = vx * ux + vy * uy
      perpendicular = abs(vx * uy - vy * ux)
    if forward <= 0 or forward > reach:
      continue
    if perpendicular > forward * halfWidthSlope:
      continue
    if not sim.lineOfSightClear(
      ax,
      ay,
      sim.players[i].x + CollisionW div 2,
      sim.players[i].y + CollisionH div 2
    ):
      continue
    result.add(i)

proc startArcFire*(sim: var SimServer, attackerIndex: int) =
  ## Ignites one player's plasma cone: it stays on for PlasmaArcActiveTicks
  ## and the weapon then needs PlasmaArcResetTicks to recharge before the
  ## next firing. Damage is dealt by resolveActiveArcCones each active tick.
  if not sim.canFireArc(attackerIndex):
    return
  sim.players[attackerIndex].fireCooldown =
    PlasmaArcActiveTicks + PlasmaArcResetTicks
  sim.players[attackerIndex].arcTicksLeft = PlasmaArcActiveTicks
  sim.players[attackerIndex].arcHitMask = 0
  sim.players[attackerIndex].arcKillsThisFire = 0
  sim.logGameEvent(
    playerColorText(sim.players[attackerIndex].color) & " sprayed paint"
  )

proc resolveActiveArcCones*(sim: var SimServer) =
  ## Advances every live spray cone one tick: all cones are resolved
  ## against the same snapshot (no processing-order advantage), each victim
  ## is damaged at most once per activation, and every live cone leaves a
  ## cosmetic flash at its owner's current position and aim. A touch removes
  ## PlasmaArcDamage hit points — lethal to a bare cog, survivable once by a
  ## shield carrier. A dead owner's cone shuts off.
  var arcFires: seq[tuple[attacker: int, victims: seq[int]]] = @[]
  for attackerIndex in 0 ..< sim.players.len:
    if sim.players[attackerIndex].arcTicksLeft <= 0:
      continue
    if not sim.players[attackerIndex].alive:
      sim.players[attackerIndex].arcTicksLeft = 0
      continue
    arcFires.add((attackerIndex, sim.selectArcVictims(attackerIndex)))
  for arcFire in arcFires:
    let attacker = sim.players[arcFire.attacker]
    var damages: seq[EventDamage]
    sim.plasmaArcFlashes.add PlasmaArcFx(
      x: attacker.x + CollisionW div 2,
      y: attacker.y + CollisionH div 2,
      aimBrads: attacker.aimBrads,
      tick: sim.tickCount,
      color: teamColor(attacker.team)
    )
    for victimIndex in arcFire.victims:
      if victimIndex < 0 or victimIndex >= sim.players.len:
        continue
      if not sim.players[victimIndex].alive:
        continue
      if victimIndex < 32:
        let bit = 1'u32 shl victimIndex
        if (sim.players[arcFire.attacker].arcHitMask and bit) != 0:
          continue
        sim.players[arcFire.attacker].arcHitMask =
          sim.players[arcFire.attacker].arcHitMask or bit
      # A bubble that eats the burst keeps the body clean, exactly as with a
      # paintball (see the gun's damage site).
      let bubbleUp = sim.players[victimIndex].hasShield and
        sim.players[victimIndex].shieldHp > 0
      let blocked = sim.absorbDamage(victimIndex, PlasmaArcDamage)
      # A can of paint sprayed in the face paints: stamp the visor splat, like
      # the gun and the grenade.
      if not bubbleUp:
        sim.players[victimIndex].paintHitTick = sim.tickCount
      let
        vx = float(sim.players[victimIndex].x + CollisionW div 2)
        vy = float(sim.players[victimIndex].y + CollisionH div 2)
      sim.emitEvent(
        Damage, source = arcFire.attacker, target = victimIndex,
        weapon = "spray", amount = PlasmaArcDamage,
        hp = max(0, sim.players[victimIndex].hp),
        blocked = blocked, x = vx, y = vy
      )
      if sim.collectEvents:
        damages.add sim.eventDamage(
          victimIndex,
          PlasmaArcDamage,
          max(0, sim.players[victimIndex].hp),
          blocked
        )
      # Floating damage number for the HP loss (cosmetic, not in gameHash).
      sim.damagePops.add DamageFx(
        x: sim.players[victimIndex].x + CollisionW div 2,
        y: sim.players[victimIndex].y + CollisionH div 2,
        tick: sim.tickCount,
        amount: PlasmaArcDamage, color: sim.players[victimIndex].color
      )
      if sim.players[victimIndex].hp <= 0:
        sim.killPlayer(victimIndex, arcFire.attacker)
        if victimIndex != arcFire.attacker:
          sim.recordKill(arcFire.attacker)
          sim.recordTeamKill(arcFire.attacker, victimIndex)
          sim.emitEvent(
            Kill, source = arcFire.attacker, target = victimIndex,
            weapon = "spray", amount = PlasmaArcDamage, x = vx, y = vy
          )
          # Multi-kill accounting per ACTIVATION (not per tick): the second
          # kill of one firing mints a double, the third upgrades it to a
          # triple; a fourth+ stays inside the already-counted triple.
          inc sim.players[arcFire.attacker].arcKillsThisFire
          if sim.players[arcFire.attacker].arcKillsThisFire == 2:
            inc sim.players[arcFire.attacker].multiKills2
          elif sim.players[arcFire.attacker].arcKillsThisFire == 3:
            dec sim.players[arcFire.attacker].multiKills2
            inc sim.players[arcFire.attacker].multiKills3
    if sim.collectEvents:
      sim.emitEvent(
        SprayUse,
        source = arcFire.attacker,
        weapon = "spray",
        x = float(attacker.x + CollisionW div 2),
        y = float(attacker.y + CollisionH div 2),
        actionId = sim.eventActionId(
          arcFire.attacker,
          SprayAction,
          sim.tickCount - (PlasmaArcActiveTicks - attacker.arcTicksLeft)
        ),
        headingBrads = attacker.aimBrads,
        damages = damages
      )
    if sim.players[arcFire.attacker].arcTicksLeft > 0:
      dec sim.players[arcFire.attacker].arcTicksLeft

proc tryFireArc*(sim: var SimServer, attackerIndex: int) =
  ## Fires one spray burst immediately for direct callers and tests: ignites
  ## the cone and resolves its first tick (other live cones also advance).
  if not sim.canFireArc(attackerIndex):
    return
  sim.startArcFire(attackerIndex)
  sim.resolveActiveArcCones()

proc fireDirection(sim: SimServer, shooterIndex: int): tuple[x, y: float] =
  ## Returns the unit shot direction: the aim angle locked at the trigger
  ## pull when a windup is (or was) pending, else the shooter's current aim.
  let shooter = sim.players[shooterIndex]
  if shooter.windupBrads >= 0:
    aimVector(shooter.windupBrads)
  else:
    aimVector(shooter.aimBrads)

proc selectFireTarget(sim: SimServer, shooterIndex: int): int =
  ## Returns the FIRST player along the shot ray — the bullet travels down
  ## the locked aim direction and stops at the first body it crosses
  ## (friendly fire on) or the first wall — or -1 for a miss.
  ##
  ## A target's body is sampled across its silhouette (perpendicular to the
  ## ray, ±PlayerHalf): a sample connects only when the bullet corridor
  ## covers it AND the shooter has line of sight TO THAT SAMPLE. Cover is
  ## therefore partial, not binary — a corner-hugger can only be hit on the
  ## sliver of body it actually shows, and a fully exposed body presents the
  ## same effective width as the old center-only corridor check.
  result = -1
  let
    shooter = sim.players[shooterIndex]
    (ux, uy) = sim.fireDirection(shooterIndex)
    sx = shooter.x + CollisionW div 2
    sy = shooter.y + CollisionH div 2
    maxRange = float(sim.config.gunRange)
  var bestT = maxRange + 1.0
  for i in 0 ..< sim.players.len:
    if i == shooterIndex or not sim.players[i].alive:
      continue
    let
      tx = float(sim.players[i].x + CollisionW div 2)
      ty = float(sim.players[i].y + CollisionH div 2)
    for off in countup(-PlayerHalf, PlayerHalf, ExposureSampleStep):
      let
        px = tx - float(off) * uy      # silhouette sample: the body span
        py = ty + float(off) * ux      # perpendicular to the shot ray
        vx = px - float(sx)
        vy = py - float(sy)
        t = vx * ux + vy * uy          # distance along the ray
      if t <= 0 or t > maxRange:
        continue
      if abs(vx * uy - vy * ux) > BulletHalfWidth:
        continue
      if not sim.lineOfSightClear(sx, sy, int(round(px)), int(round(py))):
        continue
      if t < bestT:
        bestT = t
        result = i
      break

proc applyFire(sim: var SimServer, shooterIndex, targetIndex: int) =
  ## Applies one selected shot: cooldown, tracer, and the kill. The target
  ## may already have died to another shot this tick; the shot still lands
  ## (tracer and all) but only an alive target yields a kill.
  let
    shooter = sim.players[shooterIndex]
    (ux, uy) = sim.fireDirection(shooterIndex)
    sx = shooter.x + CollisionW div 2
    sy = shooter.y + CollisionH div 2
    shotHeading =
      if shooter.windupBrads >= 0: shooter.windupBrads
      else: shooter.aimBrads
    triggerTick =
      if shooter.windupBrads >= 0:
        sim.tickCount - sim.config.fireWindupTicks
      else:
        sim.tickCount
    actionId = sim.eventActionId(shooterIndex, GunAction, triggerTick)
  sim.players[shooterIndex].fireCooldown =
    if shooter.hasShield or shooter.carryingFlag:
      # GV26: heart carriers fire at CarrierFireSlowdown (same 3x as shields);
      # shield+heart takes the max multiplier, never the product.
      sim.config.fireCooldownTicks * max(ShieldFireSlowdown, CarrierFireSlowdown)
    else:
      sim.config.fireCooldownTicks
  sim.players[shooterIndex].windupBrads = -1
  # Accuracy bookkeeping (analysis-only, excluded from gameHash): every call
  # here is one released shot; a shot that locked onto a live enemy on the ray
  # (targetIndex >= 0) is on-target, so it counts as a hit even in the rare
  # tick where the victim already died to a simultaneous shot.
  inc sim.players[shooterIndex].shotsFired
  sim.emitEvent(
    Shot,
    source = shooterIndex,
    weapon = "gun",
    x = float(sx),
    y = float(sy),
    actionId = actionId,
    headingBrads = shotHeading
  )
  # Record a cosmetic tracer for the shot (never enters gameHash). It ends at
  # the victim, so a bullet visibly never travels past its first hit.
  var
    ex = sx
    ey = sy
  if targetIndex >= 0:
    inc sim.players[shooterIndex].shotsHit
    ex = sim.players[targetIndex].x + CollisionW div 2
    ey = sim.players[targetIndex].y + CollisionH div 2
    sim.emitEvent(
      Hit, source = shooterIndex, target = targetIndex, weapon = "gun",
      x = float(ex), y = float(ey)
    )
  else:
    # March along the unit aim to the last wall-free pixel or max range
    # (checking each sampled pixel keeps this O(range) at 1300px).
    let maxRange = sim.config.gunRange
    var lastClear = 0
    for step in 1 .. maxRange:
      let
        rx = sx + int(round(ux * float(step)))
        ry = sy + int(round(uy * float(step)))
      if sim.isWall(rx, ry):
        break
      lastClear = step
    ex = sx + int(round(ux * float(lastClear)))
    ey = sy + int(round(uy * float(lastClear)))
  sim.recentShots.add ShotFx(
    x0: sx,
    y0: sy,
    x1: ex,
    y1: ey,
    firedTick: sim.tickCount,
    color: shooter.color,
    hit: targetIndex >= 0
  )
  var impactReported = false
  if targetIndex >= 0 and sim.players[targetIndex].alive:
    # A carrier whose shield layer is still up at impact absorbs the hit
    # VISUALS on the bubble: it blinks and dents toward the shooter instead of
    # showing the inner struck-target ring and body paint spark. The "-1" pop
    # still reads the hp loss. (Cosmetic only — the damage itself is
    # unchanged.)
    let bubbleUp = sim.players[targetIndex].hasShield and
      sim.players[targetIndex].shieldHp > 0
    let blocked = sim.absorbDamage(targetIndex, 1)
    # Paintball paint marks the body only when the shield bubble ISN'T eating it
    # (a bubble dent draws no body paint). Stamp so the EYES-PiP visor splat
    # fires for THIS paint hit — and only for a PAINT hit (gun/grenade). The
    # spray cone stamps it at its own damage site.
    if not bubbleUp:
      sim.players[targetIndex].paintHitTick = sim.tickCount
    sim.emitEvent(
      Damage, source = shooterIndex, target = targetIndex, weapon = "gun",
      amount = 1, hp = max(0, sim.players[targetIndex].hp),
      blocked = blocked,
      x = float(sim.players[targetIndex].x + CollisionW div 2),
      y = float(sim.players[targetIndex].y + CollisionH div 2)
    )
    if sim.collectEvents:
      sim.emitEvent(
        ShotImpact,
        source = shooterIndex,
        target = targetIndex,
        weapon = "gun",
        x = float(ex),
        y = float(ey),
        actionId = actionId,
        headingBrads = shotHeading,
        distance = hypot(float(ex - sx), float(ey - sy)),
        damages = @[
          sim.eventDamage(
            targetIndex,
            1,
            max(0, sim.players[targetIndex].hp),
            blocked
          )
        ]
      )
    impactReported = true
    if bubbleUp:
      sim.bubbleImpacts.add BubbleImpactFx(
        playerIndex: targetIndex,
        tick: sim.tickCount,
        angleBrads: bradsOfVector(sx - ex, sy - ey)
      )
    else:
      # A spectator-view flash rings the struck target the moment the bullet
      # connects, so hits read at a glance (cosmetic only, never in gameHash).
      sim.hitFlashes.add HitFlashFx(
        playerIndex: targetIndex,
        tick: sim.tickCount
      )
    # A floating "-1" rises and fades from the victim so a lost health bar
    # reads at a glance (cosmetic only, never in gameHash).
    sim.damagePops.add DamageFx(
      x: sim.players[targetIndex].x + CollisionW div 2,
      y: sim.players[targetIndex].y + CollisionH div 2,
      tick: sim.tickCount,
      amount: 1,
      color: sim.players[targetIndex].color
    )
    if sim.players[targetIndex].hp <= 0:
      sim.killPlayer(targetIndex, shooterIndex)
      sim.recordKill(shooterIndex)
      sim.recordTeamKill(shooterIndex, targetIndex)
      sim.emitEvent(
        Kill, source = shooterIndex, target = targetIndex, weapon = "gun",
        amount = 1,
        x = float(sim.players[targetIndex].x + CollisionW div 2),
        y = float(sim.players[targetIndex].y + CollisionH div 2)
      )
    else:
      if not bubbleUp:
        # A non-fatal hit leaves a small, short-lived paint spark in the
        # shooter's color on the target (cosmetic only, never in gameHash).
        sim.splatters.add SplatterFx(
          x: sim.players[targetIndex].x,
          y: sim.players[targetIndex].y,
          tick: sim.tickCount,
          color: shooter.color,
          hit: true
        )
      sim.logGameEvent(
        playerColorText(sim.players[targetIndex].color) &
          " hit by " & sim.playerText(shooterIndex) &
          " (" & $(sim.players[targetIndex].hp +
            sim.players[targetIndex].shieldHp) & " hp left)"
      )
  if sim.collectEvents and not impactReported:
    sim.emitEvent(
      ShotImpact,
      source = shooterIndex,
      target = targetIndex,
      weapon = "gun",
      x = float(ex),
      y = float(ey),
      actionId = actionId,
      headingBrads = shotHeading,
      distance = hypot(float(ex - sx), float(ey - sy))
    )

proc tryFire*(sim: var SimServer, shooterIndex: int) =
  ## Fires one shot immediately (the single-shooter path).
  if not sim.canFire(shooterIndex):
    return
  sim.applyFire(shooterIndex, sim.selectFireTarget(shooterIndex))

proc startFireWindup*(sim: var SimServer, shooterIndex: int) =
  ## Starts a shot: locks the current aim angle and arms the windup.
  ## The shot itself releases fireWindupTicks later (see step).
  if not sim.canFire(shooterIndex):
    return
  if sim.players[shooterIndex].fireWindup > 0:
    return
  let actionId = sim.eventActionId(shooterIndex, GunAction)
  sim.players[shooterIndex].fireWindup = sim.config.fireWindupTicks
  sim.players[shooterIndex].windupBrads = sim.players[shooterIndex].aimBrads
  sim.emitEvent(
    GunTrigger,
    source = shooterIndex,
    weapon = "gun",
    x = float(sim.players[shooterIndex].x + CollisionW div 2),
    y = float(sim.players[shooterIndex].y + CollisionH div 2),
    actionId = actionId,
    headingBrads = sim.players[shooterIndex].aimBrads
  )


proc grenadePosition*(grenade: AirborneGrenade, tick: int): tuple[x, y: int] =
  ## The grenade's map position while airborne (linear flight over walls).
  let t = clamp(tick - grenade.launchTick, 0, grenade.flightTicks)
  (grenade.sx + (grenade.tx - grenade.sx) * t div grenade.flightTicks,
    grenade.sy + (grenade.ty - grenade.sy) * t div grenade.flightTicks)

proc throwTarget*(player: Player): tuple[x, y: int] =
  ## Where a charging player's throw would currently land, along their aim at
  ## the charge-picked distance. Shares throwGrenade's exact math so the render
  ## charge-ring can never disagree with where the grenade will actually go.
  let
    charge = clamp(player.throwCharge, 0, GrenadeChargeTicks)
    strength = GrenadeMinRange +
      (GrenadeMaxRange - GrenadeMinRange) * charge div GrenadeChargeTicks
    (ux, uy) = aimVector(player.aimBrads)
    sx = player.x + CollisionW div 2
    sy = player.y + CollisionH div 2
  (clamp(sx + int(round(ux * float(strength))),
      ArenaBorder + 2, MapWidth - ArenaBorder - 2),
    clamp(sy + int(round(uy * float(strength))),
      ArenaBorder + 2, MapHeight - ArenaBorder - 2))

proc throwGrenade(sim: var SimServer, playerIndex: int) =
  ## Releases the charged throw along the thrower's current aim. The charge
  ## picks the distance (GrenadeMinRange..GrenadeMaxRange); the grenade
  ## flies over every obstacle and explodes where it lands. Throwing is
  ## deliberately silent: no sound FX is recorded here.
  let
    player = sim.players[playerIndex]
    charge = clamp(player.throwCharge, 0, GrenadeChargeTicks)
    strength = GrenadeMinRange +
      (GrenadeMaxRange - GrenadeMinRange) * charge div GrenadeChargeTicks
    (ux, uy) = aimVector(player.aimBrads)
    sx = player.x + CollisionW div 2
    sy = player.y + CollisionH div 2
    tx = clamp(
      sx + int(round(ux * float(strength))),
      ArenaBorder + 2, MapWidth - ArenaBorder - 2
    )
    ty = clamp(
      sy + int(round(uy * float(strength))),
      ArenaBorder + 2, MapHeight - ArenaBorder - 2
    )
    # Fixed fuse: the burst comes exactly GrenadeFlightMultiple shot-windups
    # after release, near or far. The visible arc just moves faster on long
    # throws; the threat window is constant and readable.
    flight = max(1, GrenadeFlightMultiple * sim.config.fireWindupTicks)
    throwDistance = hypot(float(tx - sx), float(ty - sy))
  sim.airborneGrenades.add AirborneGrenade(
    sx: sx,
    sy: sy,
    tx: tx,
    ty: ty,
    launchTick: sim.tickCount,
    flightTicks: flight,
    thrower: playerIndex,
    throwerSlot: player.joinOrder,
    throwerAccount: sim.rewardAccountIndexForSlot(player.joinOrder)
  )
  sim.emitEvent(
    GrenadeThrow,
    source = playerIndex,
    weapon = "grenade",
    x = float(sx),
    y = float(sy),
    actionId = sim.eventActionId(playerIndex, GrenadeAction),
    headingBrads = player.aimBrads,
    distance = throwDistance,
    item = "grenade"
  )
  sim.players[playerIndex].hasGrenade = false
  sim.players[playerIndex].throwCharge = 0
  sim.logGameEvent(playerColorText(player.color) & " threw a grenade")

proc applyGrenadeInput(
  sim: var SimServer,
  playerIndex: int,
  input, prev: InputState
) =
  ## Hold C to charge a throw, release to let it fly.
  if not sim.players[playerIndex].alive or
      not sim.players[playerIndex].hasGrenade:
    sim.players[playerIndex].throwCharge = 0
    return
  if input.c:
    sim.players[playerIndex].throwCharge = min(
      sim.players[playerIndex].throwCharge + 1, GrenadeChargeTicks
    )
  elif prev.c and sim.players[playerIndex].throwCharge > 0:
    sim.throwGrenade(playerIndex)
  else:
    sim.players[playerIndex].throwCharge = 0

proc explodeGrenade(sim: var SimServer, grenade: AirborneGrenade) =
  ## Applies one landing: a cosmetic blast flash (which views also use for
  ## the audible landing's sound ring) plus blast damage to EVERYONE inside
  ## the radius — teammates and the thrower included.
  # Color the splat by the thrower's TEAM (not their individual slot color), so
  # a landing reads as that team's paint-bomb — and the sprite id stays within
  # the two team-color slots, never colliding with the tracer pool.
  let
    legacyThrowerIndex = sim.legacyGrenadeThrowerIndex(grenade)
    throwerSlot = sim.grenadeThrowerSlot(grenade)
    throwerIndex = sim.playerIndexForSlot(throwerSlot)
    throwerColor = teamColor(sim.teamForSlot(throwerSlot))
  sim.recentBlasts.add BlastFx(
    x: grenade.tx, y: grenade.ty, tick: sim.tickCount, color: throwerColor
  )
  sim.logGameEvent("grenade landed")
  let radiusSq = GrenadeBlastRadius * GrenadeBlastRadius
  var
    blastKills = 0
    damages: seq[EventDamage]
  for i in 0 ..< sim.players.len:
    if not sim.players[i].alive:
      continue
    let
      px = sim.players[i].x + CollisionW div 2
      py = sim.players[i].y + CollisionH div 2
    if distSq(px, py, grenade.tx, grenade.ty) > radiusSq:
      continue
    let blocked = sim.absorbDamage(i, GrenadeDamage)
    # A paint-bomb blast marks everyone caught in it — stamp so the EYES-PiP
    # visor splat fires for this paint hit (gun/grenade; spray stamps its own).
    sim.players[i].paintHitTick = sim.tickCount
    sim.emitEvent(
      Damage, source = throwerIndex, target = i, weapon = "grenade",
      amount = GrenadeDamage, hp = max(0, sim.players[i].hp),
      blocked = blocked,
      x = float(px), y = float(py), sourceSlot = throwerSlot
    )
    if sim.collectEvents:
      damages.add sim.eventDamage(
        i,
        GrenadeDamage,
        max(0, sim.players[i].hp),
        blocked
      )
    # Floating damage number for the blast's HP loss (cosmetic, not in gameHash).
    sim.damagePops.add DamageFx(
      x: px, y: py, tick: sim.tickCount,
      amount: GrenadeDamage, color: sim.players[i].color
    )
    if sim.players[i].hp <= 0:
      sim.killPlayer(i, throwerIndex, throwerSlot)
      if throwerSlot >= 0 and throwerSlot != sim.eventSlot(i):
        if grenade.throwerAccount >= 0 and
            grenade.throwerAccount < sim.rewardAccounts.len:
          inc sim.rewardAccounts[grenade.throwerAccount].kills
        if legacyThrowerIndex >= 0 and legacyThrowerIndex != i:
          # Preserve the exact GV24 hash even if compaction made this legacy
          # live index point at a different player. Results and events above
          # use the immutable thrower identity.
          inc sim.players[legacyThrowerIndex].kills
        if throwerIndex >= 0 and throwerIndex != i:
          sim.recordTeamKill(throwerIndex, i)
        sim.emitEvent(
          Kill, source = throwerIndex, target = i, weapon = "grenade",
          amount = GrenadeDamage, x = float(px), y = float(py),
          sourceSlot = throwerSlot
        )
        if throwerIndex >= 0 and throwerIndex != i:
          inc blastKills
  if sim.collectEvents:
    sim.emitEvent(
      GrenadeImpact,
      source = throwerIndex,
      weapon = "grenade",
      x = float(grenade.tx),
      y = float(grenade.ty),
      actionId = sim.eventActionIdForSlot(
        throwerSlot,
        GrenadeAction,
        grenade.launchTick
      ),
      headingBrads = bradsOfVector(
        grenade.tx - grenade.sx,
        grenade.ty - grenade.sy
      ),
      distance = hypot(
        float(grenade.tx - grenade.sx),
        float(grenade.ty - grenade.sy)
      ),
      item = "grenade",
      damages = damages,
      sourceSlot = throwerSlot
    )
  # Multi-kill accounting per BLAST: one landing that kills 2 mints a double,
  # 3+ a triple (a self-kill in the blast never counts toward either).
  if throwerIndex >= 0:
    if blastKills >= 3:
      inc sim.players[throwerIndex].multiKills3
    elif blastKills == 2:
      inc sim.players[throwerIndex].multiKills2

proc updateGrenades(sim: var SimServer) =
  ## Refills corner pickups whose timer elapsed and lands due grenades.
  for spawn in sim.grenadeSpawns.mitems:
    if not spawn.present and sim.tickCount >= spawn.respawnAt:
      spawn.present = true
  var
    landing: seq[AirborneGrenade] = @[]
    kept: seq[AirborneGrenade] = @[]
  for grenade in sim.airborneGrenades:
    if sim.tickCount - grenade.launchTick >= grenade.flightTicks:
      landing.add grenade
    else:
      kept.add grenade
  sim.airborneGrenades = kept
  for grenade in landing:
    sim.explodeGrenade(grenade)

proc tryPickupGrenades*(sim: var SimServer, playerIndex: int) =
  ## Lets a living player pick up a corner grenade by touch (one carried
  ## grenade max; either team may take either side's pickups).
  if not sim.players[playerIndex].alive or sim.players[playerIndex].hasGrenade:
    return
  let
    px = sim.players[playerIndex].x + CollisionW div 2
    py = sim.players[playerIndex].y + CollisionH div 2
    rangeSq = GrenadePickupRange * GrenadePickupRange
  for spawn in sim.grenadeSpawns.mitems:
    if spawn.present and distSq(px, py, spawn.x, spawn.y) <= rangeSq:
      spawn.present = false
      spawn.respawnAt = sim.tickCount + GrenadeRespawnTicks
      sim.players[playerIndex].hasGrenade = true
      sim.emitPickup(playerIndex, "grenade", spawn.x, spawn.y)
      sim.logGameEvent(
        playerColorText(sim.players[playerIndex].color) &
          " picked up a grenade"
      )
      return

proc updateMedKits*(sim: var SimServer) =
  ## Refills center med kits whose respawn timer elapsed.
  for spawn in sim.medKitSpawns.mitems:
    if not spawn.present and sim.tickCount >= spawn.respawnAt:
      spawn.present = true

proc updatePlasmaArcs*(sim: var SimServer) =
  ## Refills side-center spray can pickups whose respawn timer elapsed.
  for spawn in sim.plasmaArcSpawns.mitems:
    if not spawn.present and sim.tickCount >= spawn.respawnAt:
      spawn.present = true

proc tryPickupMedKits*(sim: var SimServer, playerIndex: int) =
  ## Lets a hurt living player pick up a center med kit by touch, restoring
  ## hit points back to full. A healthy player walks over it untouched, so a
  ## kit is never wasted; a taken kit refills after MedKitRespawnTicks.
  if not sim.players[playerIndex].alive:
    return
  if sim.players[playerIndex].hp >= sim.config.hitPoints:
    return
  let
    px = sim.players[playerIndex].x + CollisionW div 2
    py = sim.players[playerIndex].y + CollisionH div 2
    rangeSq = MedKitPickupRange * MedKitPickupRange
  for spawn in sim.medKitSpawns.mitems:
    if spawn.present and distSq(px, py, spawn.x, spawn.y) <= rangeSq:
      spawn.present = false
      spawn.respawnAt = sim.tickCount + MedKitRespawnTicks
      let healed = sim.config.hitPoints - sim.players[playerIndex].hp
      sim.players[playerIndex].hp = sim.config.hitPoints
      sim.emitPickup(playerIndex, "med_kit", spawn.x, spawn.y)
      sim.emitEvent(
        Heal, source = playerIndex, amount = healed,
        hp = sim.players[playerIndex].hp, x = float(px), y = float(py)
      )
      sim.logGameEvent(
        playerColorText(sim.players[playerIndex].color) &
          " picked up a med kit"
      )
      return

proc updateShields*(sim: var SimServer) =
  ## Refills endzone shields whose respawn timer elapsed.
  for spawn in sim.shieldSpawns.mitems:
    if not spawn.present and sim.tickCount >= spawn.respawnAt:
      spawn.present = true

proc tryPickupShields*(sim: var SimServer, playerIndex: int) =
  ## Lets a living player pick up an endzone shield by touch (either team may
  ## take either endzone's shield). A pickup grants the shield and refills the
  ## ShieldLayerHp-strong shield layer that damage depletes before base hp —
  ## it never heals base damage (that is the med kits' job), so a worn carrier
  ## may take another shield to restore the layer, while a carrier whose layer
  ## is intact leaves the spawn untouched for a teammate. Carrying a shield
  ## slows fire ShieldFireSlowdown times; a taken shield refills after
  ## ShieldRespawnTicks.
  if not sim.players[playerIndex].alive:
    return
  if sim.players[playerIndex].shieldHp >= ShieldLayerHp:
    return
  let
    px = sim.players[playerIndex].x + CollisionW div 2
    py = sim.players[playerIndex].y + CollisionH div 2
    rangeSq = ShieldPickupRange * ShieldPickupRange
  for spawn in sim.shieldSpawns.mitems:
    if spawn.present and distSq(px, py, spawn.x, spawn.y) <= rangeSq:
      spawn.present = false
      spawn.respawnAt = sim.tickCount + ShieldRespawnTicks
      sim.players[playerIndex].hasShield = true
      sim.players[playerIndex].shieldHp = ShieldLayerHp
      sim.emitPickup(playerIndex, "shield", spawn.x, spawn.y)
      sim.logGameEvent(
        playerColorText(sim.players[playerIndex].color) &
          " picked up a shield"
      )
      return

proc tryPickupPlasmaArcs*(sim: var SimServer, playerIndex: int) =
  ## Lets a living player pick up one side-center spray can by touch.
  if not sim.players[playerIndex].alive or sim.players[playerIndex].hasPlasmaArc:
    return
  let
    px = sim.players[playerIndex].x + CollisionW div 2
    py = sim.players[playerIndex].y + CollisionH div 2
    rangeSq = PlasmaArcPickupRange * PlasmaArcPickupRange
  for spawn in sim.plasmaArcSpawns.mitems:
    if spawn.present and distSq(px, py, spawn.x, spawn.y) <= rangeSq:
      spawn.present = false
      spawn.respawnAt = sim.tickCount + PlasmaArcRespawnTicks
      sim.players[playerIndex].hasPlasmaArc = true
      sim.players[playerIndex].fireWindup = 0
      sim.players[playerIndex].windupBrads = -1
      sim.emitPickup(playerIndex, "spray_can", spawn.x, spawn.y)
      sim.logGameEvent(
        playerColorText(sim.players[playerIndex].color) &
          " picked up a spray can"
      )
      return

proc sanitizeShout*(text: string): string =
  ## Reduces raw chat text to a legal shout: printable ASCII only, at most
  ## ShoutMaxChars characters, no leading or trailing spaces.
  for c in text:
    if c >= ' ' and c <= '~':
      result.add(c)
    if result.len == ShoutMaxChars:
      break
  result = result.strip()

proc applyShout*(sim: var SimServer, playerIndex: int, text: string): bool {.discardable.} =
  ## Applies one player chat message as a shout: a short message audible to
  ## anyone within ShoutRange of the shouter. Living players only, at most
  ## one shout per second, and one live bubble per player (a new shout
  ## replaces the old one). Returns whether the shout was applied.
  if sim.phase != Playing:
    return false
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  if not sim.players[playerIndex].alive:
    return false
  let shoutText = sanitizeShout(text)
  if shoutText.len == 0:
    return false
  let last = sim.players[playerIndex].lastShoutTick
  if last >= 0 and sim.tickCount - last < ShoutCooldownTicks:
    return false
  sim.players[playerIndex].lastShoutTick = sim.tickCount
  let address = sim.players[playerIndex].address
  var kept: seq[Shout] = @[]
  for shout in sim.recentShouts:
    if shout.address != address:
      kept.add shout
  let shout = Shout(
    address: address,
    team: sim.players[playerIndex].team,
    text: shoutText,
    tick: sim.tickCount,
    x: sim.players[playerIndex].x + CollisionW div 2,
    y: sim.players[playerIndex].y + CollisionH div 2
  )
  kept.add shout
  sim.recentShouts = kept
  sim.emitEvent(
    ShoutEvent,
    source = playerIndex,
    x = float(shout.x),
    y = float(shout.y),
    content = shoutText
  )
  true

proc shoutAudibleTo*(sim: SimServer, viewerIndex: int, shout: Shout): bool =
  ## Whether one viewer can hear a shout: within ShoutRange of where it was
  ## made. Shouts carry through walls and fog like gunfire, but dead viewers
  ## observe nothing.
  if viewerIndex < 0 or viewerIndex >= sim.players.len:
    return false
  if not sim.players[viewerIndex].alive:
    return false
  let
    vx = sim.players[viewerIndex].x + CollisionW div 2
    vy = sim.players[viewerIndex].y + CollisionH div 2
  distSq(vx, vy, shout.x, shout.y) <= ShoutRange * ShoutRange

proc resolveSimultaneousFire*(sim: var SimServer, shooters: openArray[int]) =
  ## Resolves every shot released this tick at once: all targets are chosen
  ## against the same snapshot before any kill is applied, so a mutual duel
  ## kills both shooters and neither team gains an input-processing-order
  ## advantage.
  var shots: seq[tuple[shooter, target: int]] = @[]
  for shooterIndex in shooters:
    if sim.canFire(shooterIndex):
      shots.add((shooterIndex, sim.selectFireTarget(shooterIndex)))
  for shot in shots:
    sim.applyFire(shot.shooter, shot.target)

proc tryPickupFlags*(sim: var SimServer, playerIndex: int) =
  ## Lets a living player steal the ENEMY team's flag off its pedestal by
  ## touch. A player's own flag cannot be interacted with by their own team.
  if not sim.players[playerIndex].alive or sim.players[playerIndex].carryingFlag:
    return
  let flagTeam = enemy(sim.players[playerIndex].team)
  if sim.flags[flagTeam].carrier >= 0:
    return
  let
    px = sim.players[playerIndex].x + CollisionW div 2
    py = sim.players[playerIndex].y + CollisionH div 2
    rangeSq = FlagPickupRange * FlagPickupRange
  if distSq(px, py, sim.flags[flagTeam].x, sim.flags[flagTeam].y) <= rangeSq:
    sim.flags[flagTeam].carrier = playerIndex
    sim.players[playerIndex].carryingFlag = true
    # A steal is action: keep at least ActionClockFloorTicks on the clock.
    sim.floorGameClock()
    sim.emitEvent(
      FlagSteal, source = playerIndex,
      x = float(sim.flags[flagTeam].x), y = float(sim.flags[flagTeam].y)
    )
    sim.logGameEvent(
      teamText(sim.players[playerIndex].team) & " stole the " &
        teamText(flagTeam) & " heart"
    )

proc updateFlags(sim: var SimServer) =
  ## Keeps each carried flag glued to its carrier; a carrier that stops
  ## carrying for any reason other than capture sends the flag straight back
  ## to its own pedestal.
  for team in Team:
    let carrier = sim.flags[team].carrier
    if carrier < 0:
      continue
    if carrier < sim.players.len and sim.players[carrier].alive:
      sim.flags[team].x = sim.players[carrier].x + CollisionW div 2
      sim.flags[team].y = sim.players[carrier].y + CollisionH div 2
    else:
      # Carrier vanished; the flag goes straight back home.
      sim.logGameEvent(teamText(team) & " heart returned home")
      sim.resetFlag(team)

proc applyInput*(
  sim: var SimServer,
  playerIndex: int,
  input: InputState
) {.measure.} =
  ## Applies one player's movement input. Firing is resolved separately and
  ## simultaneously for all players (resolveSimultaneousFire).
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  template player: untyped = sim.players[playerIndex]
  if not player.alive:
    return

  var
    inputX = 0
    inputY = 0
  if input.left:
    inputX -= 1
  if input.right:
    inputX += 1
  if input.up:
    inputY -= 1
  if input.down:
    inputY += 1

  # Aim rotation is decoupled from locomotion: holding B turns the aim
  # counter-clockwise, holding Select clockwise; holding both cancels out,
  # and the d-pad never changes the aim.
  if input.b != input.select:
    let turn =
      if input.b: sim.config.aimTurnRate else: -sim.config.aimTurnRate
    player.aimBrads =
      (player.aimBrads + turn + AimBradsTurn) mod AimBradsTurn
  # The sprite flip follows the aim: flipped while aiming left-ish.
  player.flipH =
    player.aimBrads > AimBradsTurn div 4 and
    player.aimBrads < AimBradsTurn * 3 div 4

  let
    speedScale =
      if player.carryingFlag: sim.config.carrierSpeedPct else: 100
    maxSpeed = sim.config.maxSpeed * speedScale div 100
    accel = sim.config.accel * speedScale div 100

  if inputX != 0:
    player.velX = clamp(
      player.velX + inputX * accel,
      -maxSpeed,
      maxSpeed
    )
  else:
    player.velX =
      (player.velX * sim.config.frictionNum) div sim.config.frictionDen
    if abs(player.velX) < sim.config.stopThreshold:
      player.velX = 0

  if inputY != 0:
    player.velY = clamp(
      player.velY + inputY * accel,
      -maxSpeed,
      maxSpeed
    )
  else:
    player.velY =
      (player.velY * sim.config.frictionNum) div sim.config.frictionDen
    if abs(player.velY) < sim.config.stopThreshold:
      player.velY = 0

  let
    preferredSlideY =
      if inputY != 0:
        inputY
      else:
        signOf(player.velY)
    preferredSlideX =
      if inputX != 0:
        inputX
      else:
        signOf(player.velX)
  sim.applyMomentumAxis(playerIndex, preferredSlideY, true)
  sim.applyMomentumAxis(playerIndex, preferredSlideX, false)

proc fovCellIndex*(cx, cy: int): int {.inline.} =
  ## Returns the flat index of one fog-of-war grid cell.
  cy * FovGridW + cx

proc fovCellAt*(x, y: int): tuple[cx, cy: int] {.inline.} =
  ## Returns the fog-of-war grid cell containing one map point.
  (clamp(x div FovCellSize, 0, FovGridW - 1),
   clamp(y div FovCellSize, 0, FovGridH - 1))

proc fovCellCenter*(cx, cy: int): tuple[x, y: int] {.inline.} =
  ## Returns the map-pixel center of one fog-of-war grid cell.
  (cx * FovCellSize + FovCellSize div 2, cy * FovCellSize + FovCellSize div 2)

proc buildFovBlocked*(wallMask: seq[bool]): seq[bool] =
  ## Downsamples the pixel wall mask into the fog-of-war occlusion grid: a
  ## cell is opaque when at least half of its pixels are wall.
  result = newSeq[bool](FovCellCount)
  for cy in 0 ..< FovGridH:
    for cx in 0 ..< FovGridW:
      var
        walls = 0
        pixels = 0
      for py in cy * FovCellSize ..< min((cy + 1) * FovCellSize, MapHeight):
        for px in cx * FovCellSize ..< min((cx + 1) * FovCellSize, MapWidth):
          inc pixels
          if wallMask[mapIndex(px, py)]:
            inc walls
      result[fovCellIndex(cx, cy)] = walls * 2 >= pixels

proc castFovOctant(
  blocked: openArray[bool],
  visible: var seq[bool],
  originCx, originCy, row: int,
  startSlope, endSlope: float,
  xx, xy, yx, yy: int
) =
  ## Recursive shadowcasting over one octant of the fog-of-war grid
  ## (Bergstrom-style). Row distance is unbounded; scanning stops at the grid
  ## edge, so vision range is limited only by walls.
  if startSlope < endSlope:
    return
  var
    start = startSlope
    rowBlocked = false
    newStart = 0.0
  let maxDist = FovGridW + FovGridH
  for dist in row .. maxDist:
    if rowBlocked:
      break
    var anyInside = false
    for dx in -dist .. 0:
      let
        dy = -dist
        lSlope = (float(dx) - 0.5) / (float(dy) + 0.5)
        rSlope = (float(dx) + 0.5) / (float(dy) - 0.5)
      if start < rSlope:
        continue
      if endSlope > lSlope:
        break
      let
        cx = originCx + dx * xx + dy * xy
        cy = originCy + dx * yx + dy * yy
      if cx < 0 or cy < 0 or cx >= FovGridW or cy >= FovGridH:
        continue
      anyInside = true
      let index = fovCellIndex(cx, cy)
      visible[index] = true
      if rowBlocked:
        if blocked[index]:
          newStart = rSlope
        else:
          rowBlocked = false
          start = newStart
      elif blocked[index]:
        rowBlocked = true
        castFovOctant(
          blocked,
          visible,
          originCx,
          originCy,
          dist + 1,
          start,
          lSlope,
          xx, xy, yx, yy
        )
        newStart = rSlope
    if not anyInside and dist > row:
      break

proc computeFovVisible*(
  sim: SimServer,
  originCx, originCy, aimBrads: int,
  visible: var seq[bool]
) {.measure.} =
  ## Computes one viewer's fog-of-war cell visibility: recursive shadowcasting
  ## from the viewer's cell (walls block), intersected with the forward vision
  ## cone (half-angle visionConeDeg around the aim angle, unlimited range)
  ## plus the omnidirectional vision bubble (visionBubble px).
  if visible.len != FovCellCount:
    visible.setLen(FovCellCount)
  zeroMem(addr visible[0], visible.len * sizeof(bool))
  visible[fovCellIndex(originCx, originCy)] = true
  const Octants = [
    (1, 0, 0, 1), (0, 1, 1, 0), (0, -1, 1, 0), (-1, 0, 0, 1),
    (-1, 0, 0, -1), (0, -1, -1, 0), (0, 1, -1, 0), (1, 0, 0, -1)
  ]
  for (xx, xy, yx, yy) in Octants:
    castFovOctant(
      sim.fovBlocked,
      visible,
      originCx,
      originCy,
      1,
      1.0,
      0.0,
      xx, xy, yx, yy
    )
  let
    (ox, oy) = fovCellCenter(originCx, originCy)
    (ax, ay) = aimVector(aimBrads)
    coneCos = cos(float(sim.config.visionConeDeg) * PI / 180.0)
    bubbleSq = float(sim.config.visionBubble * sim.config.visionBubble)
  for cy in 0 ..< FovGridH:
    for cx in 0 ..< FovGridW:
      let index = fovCellIndex(cx, cy)
      if not visible[index]:
        continue
      let
        (px, py) = fovCellCenter(cx, cy)
        vx = float(px - ox)
        vy = float(py - oy)
        d2 = vx * vx + vy * vy
      if d2 <= bubbleSq:
        continue
      let dot = vx * ax + vy * ay
      if dot < coneCos * sqrt(d2):
        visible[index] = false

proc ensureFovCacheSlots(sim: var SimServer) =
  ## Keeps player-indexed fog-of-war cache storage aligned with players.
  while sim.fovCaches.len < sim.players.len:
    sim.fovCaches.add PlayerFov(
      valid: false,
      visible: newSeq[bool](FovCellCount)
    )
  if sim.fovCaches.len > sim.players.len:
    sim.fovCaches.setLen(sim.players.len)

proc refreshPlayerFov*(sim: var SimServer, playerIndex: int): bool {.measure.} =
  ## Refreshes one player's cached fog-of-war grid and returns true when it
  ## was recomputed (the viewer moved to a new cell or turned).
  sim.ensureFovCacheSlots()
  let
    player = sim.players[playerIndex]
    (cx, cy) = fovCellAt(
      player.x + CollisionW div 2,
      player.y + CollisionH div 2
    )
  template cache: untyped = sim.fovCaches[playerIndex]
  if cache.valid and
      cache.originCx == cx and
      cache.originCy == cy and
      cache.aimBrads == player.aimBrads:
    return false
  sim.computeFovVisible(cx, cy, player.aimBrads, cache.visible)
  cache.valid = true
  cache.originCx = cx
  cache.originCy = cy
  cache.aimBrads = player.aimBrads
  true

proc playerFov*(sim: SimServer, playerIndex: int): lent PlayerFov =
  ## Returns one player's cached fog-of-war grid (refreshPlayerFov first).
  sim.fovCaches[playerIndex]

proc fovVisibleAt*(sim: SimServer, playerIndex, x, y: int): bool =
  ## Returns whether one map point is inside a viewer's vision. Dead viewers
  ## have no eyes: everything is fogged until they respawn. Call
  ## refreshPlayerFov first.
  if not sim.players[playerIndex].alive:
    return false
  if playerIndex >= sim.fovCaches.len or not sim.fovCaches[playerIndex].valid:
    return true
  let (cx, cy) = fovCellAt(x, y)
  sim.fovCaches[playerIndex].visible[fovCellIndex(cx, cy)]

proc playerVisibleTo*(sim: SimServer, viewerIndex, targetIndex: int): bool =
  ## Returns whether one player is observable by a viewer: only yourself is
  ## always visible; everyone else — teammates included — only inside your
  ## vision. There is no team radio.
  if viewerIndex == targetIndex:
    return true
  sim.fovVisibleAt(
    viewerIndex,
    sim.players[targetIndex].x + CollisionW div 2,
    sim.players[targetIndex].y + CollisionH div 2
  )

proc flagVisibleTo*(sim: SimServer, viewerIndex: int, team: Team): bool =
  ## Returns whether one team's flag is observable by a viewer: always on its
  ## pedestal; riding a carrier it is exactly as visible as the carrier.
  let carrier = sim.flags[team].carrier
  if carrier < 0:
    return true
  sim.playerVisibleTo(viewerIndex, carrier)

proc finishGame*(sim: var SimServer, winner: Team, isDraw = false, timeLimitReached = false) =
  ## Moves to game over and awards all winning players.
  if sim.phase == GameOver:
    return
  if isDraw:
    sim.logGameEvent("draw")
  else:
    sim.logGameEvent(teamText(winner) & " win")
  sim.emitPhaseChange(GameOver)
  sim.phase = GameOver
  sim.winner = winner
  sim.isDraw = isDraw
  sim.gameOverTimer = sim.config.gameOverTicks
  sim.timeLimitReached = timeLimitReached
  if isDraw:
    if timeLimitReached:
      # A time-limit draw is a lose-lose: every player on both teams takes
      # TimeoutReward so running out the clock is never better than losing.
      # A mutual-wipe draw stays 0/0 — both sides at least fought to the end.
      var penalizedAccounts = newSeq[bool](sim.rewardAccounts.len)
      for i in 0 ..< sim.players.len:
        let accountIndex = sim.rewardAccountForPlayer(i)
        if penalizedAccounts.len < sim.rewardAccounts.len:
          penalizedAccounts.setLen(sim.rewardAccounts.len)
        if accountIndex >= 0 and accountIndex < penalizedAccounts.len:
          penalizedAccounts[accountIndex] = true
        sim.addReward(i, TimeoutReward)
      for i in 0 ..< sim.rewardAccounts.len:
        if i < penalizedAccounts.len and penalizedAccounts[i]:
          continue
        if not sim.rewardAccounts[i].hasTeam:
          continue
        sim.rewardAccounts[i].reward += TimeoutReward
    return
  var awardedAccounts = newSeq[bool](sim.rewardAccounts.len)
  for i in 0 ..< sim.players.len:
    let accountIndex = sim.rewardAccountForPlayer(i)
    if awardedAccounts.len < sim.rewardAccounts.len:
      awardedAccounts.setLen(sim.rewardAccounts.len)
    if accountIndex >= 0 and accountIndex < awardedAccounts.len:
      awardedAccounts[accountIndex] = true
    if sim.players[i].team == winner:
      sim.addReward(i, WinReward)
      sim.recordGameWin(i)
    else:
      sim.addReward(i, LossReward)
  for i in 0 ..< sim.rewardAccounts.len:
    if i < awardedAccounts.len and awardedAccounts[i]:
      continue
    if not sim.rewardAccounts[i].hasTeam:
      continue
    if sim.rewardAccounts[i].team == winner:
      sim.rewardAccounts[i].reward += WinReward
      sim.rewardAccounts[i].won = true
      if winner == Red:
        inc sim.rewardAccounts[i].winsRed
      else:
        inc sim.rewardAccounts[i].winsBlue
    else:
      sim.rewardAccounts[i].reward += LossReward

proc maxTicksReached(sim: SimServer): bool =
  sim.config.maxTicks > 0 and sim.phase == Playing and
    sim.gameTicksElapsed() >= sim.effectiveMaxTicks()

proc teamLivesRemaining*(sim: SimServer, team: Team): int =
  ## Returns total lives remaining (alive players count their current life).
  ## Kept for the broadcast scorebug + momentum series (upstream dropped it as
  ## unused; the replay chrome still reads it).
  for p in sim.players:
    if p.team != team:
      continue
    result += p.lives
    if p.alive:
      inc result

proc teamFlagProgress*(sim: SimServer, team: Team): int =
  ## Returns how far the ENEMY flag has been advanced toward this team's
  ## home while carried; 0 when it sits on its pedestal. (0.7.0 relabels the
  ## flag a "heart" in art/copy, but the carry-to-home mechanic is unchanged.)
  let flag = sim.flags[enemy(team)]
  if flag.carrier < 0:
    return 0
  let home = sim.gameMap.flagHome(enemy(team))
  case team
  of Red:
    max(0, home.x - flag.x)
  of Blue:
    max(0, flag.x - home.x)

proc teamHasLivePlayers(sim: SimServer, team: Team): bool =
  ## Returns true when a team still has a player who can act this round.
  for p in sim.players:
    if p.team == team and (p.alive or p.lives > 0):
      return true
  false

proc shouldAbortFiniteMatch*(sim: SimServer): bool =
  ## Returns true when a finite match cannot continue after roster loss.
  if sim.config.maxGames <= 0:
    return false
  if sim.phase == Lobby:
    return sim.startWaitTimer > 0 and sim.players.len < sim.config.minPlayers
  sim.phase == Playing and sim.players.len == 0

proc checkWinCondition*(sim: var SimServer) {.measure.} =
  ## Resolves capture and wipe win conditions.
  if sim.phase != Playing or sim.players.len == 0:
    return
  # Capture: a living carrier bringing the enemy flag into their own home
  # capture zone (deliberately no own-flag-must-be-home precondition).
  for flagTeam in Team:
    let carrierIndex = sim.flags[flagTeam].carrier
    if carrierIndex < 0 or carrierIndex >= sim.players.len or
        not sim.players[carrierIndex].alive:
      continue
    let
      carrier = sim.players[carrierIndex]
      zone = sim.captureZoneXRange(carrier.team)
      cx = carrier.x + CollisionW div 2
    if cx >= zone.lo and cx <= zone.hi:
      sim.recordCapture(carrierIndex)
      sim.emitEvent(
        Capture, source = carrierIndex,
        x = float(cx), y = float(carrier.y + CollisionH div 2)
      )
      sim.logGameEvent(
        teamText(carrier.team) & " captured the " & teamText(flagTeam) & " heart"
      )
      sim.finishGame(carrier.team)
      return
  # Wipe: a team with no live players left loses.
  let
    redAlive = sim.teamHasLivePlayers(Red)
    blueAlive = sim.teamHasLivePlayers(Blue)
  if not redAlive and blueAlive:
    sim.finishGame(Blue)
  elif not blueAlive and redAlive:
    sim.finishGame(Red)
  elif not redAlive and not blueAlive:
    sim.finishGame(Red, isDraw = true)

proc checkMaxTicks(sim: var SimServer) =
  ## A game that hits the time limit before a capture or a wipe is a
  ## scoreless draw for both sides: no tiebreak, no rewards.
  if not sim.maxTicksReached():
    return
  sim.finishGame(Red, isDraw = true, timeLimitReached = true)

proc decodeGridFont(image: Image, cellW, cellH, cols: int,
    spacing = 1): PixelFont =
  ## Decodes a fixed-cell monospace ASCII sheet (ascii.png: cellW x cellH cells
  ## laid out `cols` per row, starting at ASCII 32) into a PixelFont. Unlike
  ## decodePixelFont there is no yellow marker row: each glyph is the cell's
  ## white ink, trimmed to its own ink width so the font stays proportional.
  ## Used only for shout bubbles, which want a chunkier, taller face than the
  ## 6px tiny5 HUD font so the text reads at full desktop size.
  result.height = cellH
  result.spacing = spacing
  proc ink(x, y: int): bool =
    if x < 0 or y < 0 or x >= image.width or y >= image.height:
      return false
    let p = image[x, y]
    p.a > 20'u8 and p.r >= 120'u8 and p.g >= 120'u8 and p.b >= 120'u8
  for code in FirstPrintableAscii .. LastPrintableAscii:
    let
      idx = code - FirstPrintableAscii
      cx = (idx mod cols) * cellW
      cy = (idx div cols) * cellH
    var minX = cellW
    var maxX = -1
    for gx in 0 ..< cellW:
      for gy in 0 ..< cellH:
        if ink(cx + gx, cy + gy):
          minX = min(minX, gx)
          maxX = max(maxX, gx)
          break
    # A blank cell (e.g. the space) gets a fixed narrow advance.
    let width = if maxX < 0: max(1, cellW div 2) else: maxX - minX + 1
    let start = if maxX < 0: 0 else: minX
    var glyph = PixelGlyph(ch: char(code), width: width, height: cellH)
    glyph.pixels = newSeq[bool](width * cellH)
    if maxX >= 0:
      for gy in 0 ..< cellH:
        for gx in 0 ..< width:
          glyph.pixels[gy * width + gx] = ink(cx + start + gx, cy + gy)
    result.glyphs.add(glyph)

proc loadShoutFont(): PixelFont =
  ## Loads the chunky 7x9 grid font used for shout bubbles.
  decodeGridFont(readImage(gameDir() / "data" / "ascii.png"), 7, 9, 18)

proc initSimServer*(config: GameConfig): SimServer =
  result.config = config
  result.rng = initRand(config.seed)
  loadPalette(clientDataDir() / "pallete.png")
  result.asciiSprites = readTiny5Font()
  result.shoutFont = loadShoutFont()

  let sheet = loadSpriteSheet()
  result.crewSprites = loadCrewSprites()
  # Reuse the former task-icon cell as the flag sprite.
  result.flagSprite = spriteFromImage(
    sheet.subImage(SpriteSize * 4, 0, SpriteSize, SpriteSize)
  )

  result.gameMap = loadCtfMap(config)
  result.rooms = result.gameMap.rooms

  let (mapImage, walkImage, wallImage) = loadMapLayers(result.gameMap)
  result.mapPixels = newSeq[uint8](MapWidth * MapHeight)
  result.mapRgba = newSeq[uint8](MapWidth * MapHeight * 4)
  result.darkBgPixels = loadDarkBgPixels()
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      let
        pixel = mapImage[x, y]
        index = mapIndex(x, y)
        offset = index * 4
      result.mapPixels[index] = nearestPaletteIndex(pixel)
      result.mapRgba[offset] = pixel.r
      result.mapRgba[offset + 1] = pixel.g
      result.mapRgba[offset + 2] = pixel.b
      result.mapRgba[offset + 3] = pixel.a

  result.walkMask = newSeq[bool](MapWidth * MapHeight)
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      let pixel = walkImage[x, y]
      result.walkMask[mapIndex(x, y)] = pixel.a > 0

  result.wallMask = newSeq[bool](MapWidth * MapHeight)
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      let pixel = wallImage[x, y]
      result.wallMask[mapIndex(x, y)] = pixel.a > 0

  ## The fog occlusion grid builds from the OPAQUE walls only: glass window
  ## pixels stay in wallMask (movement/bullets/spray cones) but drop out here, so
  ## shadowcasting sees straight through every window.
  var opaqueMask = result.wallMask
  block:
    let
      cx = result.gameMap.center.x
      cy = result.gameMap.center.y
    for y in 0 ..< MapHeight:
      for x in 0 ..< MapWidth:
        let index = mapIndex(x, y)
        if opaqueMask[index] and isArenaWindowPixel(x, y, cx, cy):
          opaqueMask[index] = false
  result.fovBlocked = buildFovBlocked(opaqueMask)
  result.fovCaches = @[]
  result.players = @[]
  result.nextJoinOrder = 0
  result.gameStartTick = -1
  result.startWaitTimer = 0
  result.gameEventLoggingEnabled = true
  result.resetFlags()
  result.resetGrenades()
  result.resetMedKits()
  result.resetShields()
  result.resetPlasmaArcs()
  result.lastLobbyPlayersLogged = -1
  result.lastLobbyNeededLogged = -1
  result.lastLobbySecondsLogged = -1

proc resetToLobby*(sim: var SimServer) =
  if sim.phase != Lobby:
    sim.emitPhaseChange(Lobby)
  sim.phase = Lobby
  sim.players = @[]
  sim.fovCaches = @[]
  sim.resetGrenades()
  sim.resetMedKits()
  sim.resetShields()
  sim.resetPlasmaArcs()
  sim.recentBlasts = @[]
  sim.plasmaArcFlashes = @[]
  sim.recentShouts = @[]
  sim.recentShots = @[]
  sim.hitFlashes = @[]
  sim.bubbleImpacts = @[]
  sim.splatters = @[]
  sim.damagePops = @[]
  sim.nextJoinOrder = 0
  sim.tickCount = 0
  sim.gameStartTick = -1
  sim.startWaitTimer = 0
  sim.timeLimitReached = false
  sim.overtimeTicks = 0
  sim.isDraw = false
  sim.needsReregister = true
  sim.resetFlags()
  sim.lastLobbyPlayersLogged = -1
  sim.lastLobbyNeededLogged = -1
  sim.lastLobbySecondsLogged = -1
  for account in sim.rewardAccounts.mitems:
    account.hasTeam = false
    account.won = false
    account.abandoned = false

proc stepLobby(sim: var SimServer) {.measure.} =
  ## Advances the lobby start countdown.
  if sim.players.len < sim.config.minPlayers:
    sim.startWaitTimer = 0
    sim.logLobbyWaiting()
    return
  if sim.config.startWaitTicks <= 0:
    sim.startGame()
    return
  if sim.startWaitTimer <= 0:
    sim.startWaitTimer = sim.config.startWaitTicks
  dec sim.startWaitTimer
  if sim.startWaitTimer <= 0:
    sim.startGame()
  else:
    sim.logLobbyCountdown()

proc respawnPlayers(sim: var SimServer) =
  ## Ticks respawn timers and brings dead players back at a random spot in
  ## their endzone, so a fixed respawn point can't be camped.
  for i in 0 ..< sim.players.len:
    if sim.players[i].alive:
      continue
    if sim.players[i].lives <= 0:
      continue
    if sim.players[i].respawnTimer > 0:
      dec sim.players[i].respawnTimer
      if sim.players[i].respawnTimer <= 0:
        let spawn = sim.randomEndzonePosition(sim.players[i].team)
        sim.placePlayer(i, spawn.x, spawn.y)
        sim.players[i].alive = true
        sim.players[i].hp = sim.config.hitPoints
        sim.players[i].aimBrads = spawnAimBrads(sim.players[i].team)
        sim.players[i].flipH = sim.players[i].team == Blue
        sim.emitEvent(
          Respawn, source = i,
          x = float(sim.players[i].x + CollisionW div 2),
          y = float(sim.players[i].y + CollisionH div 2)
        )

proc step*(
  sim: var SimServer,
  inputs: openArray[InputState],
  prevInputs: openArray[InputState]
) {.measure.} =
  inc sim.tickCount

  # Roster-driven transitions belong inside the deterministic step: leaves
  # are recorded and re-applied, so replays re-derive these exactly. (They
  # used to run live-only in the server loop, which made every replay with a
  # mid-match disconnect-out diverge from its recorded hashes.)
  if sim.players.len == 0 and sim.phase == Playing and sim.config.maxGames > 0:
    sim.finishGame(Red, isDraw = true, timeLimitReached = true)
  elif sim.players.len == 0 and sim.phase != Lobby:
    sim.resetToLobby()

  if sim.phase == Lobby:
    sim.stepLobby()
    return

  if sim.phase == GameOver:
    dec sim.gameOverTimer
    if sim.gameOverTimer <= 0:
      sim.resetToLobby()
    return

  # Playing: move everyone first, then resolve every shot that releases this
  # tick at once against the post-movement snapshot (no processing-order
  # advantage). A fresh trigger pull arms a windup with the aim locked at the
  # pull; the bullet leaves fireWindupTicks later from the shooter's current
  # position, so a target that ducks back behind cover survives the shot.
  var
    firing: seq[int] = @[]
    arcFiring: seq[int] = @[]
  for playerIndex in 0 ..< sim.players.len:
    if sim.players[playerIndex].fireCooldown > 0:
      dec sim.players[playerIndex].fireCooldown
    if sim.players[playerIndex].fireWindup > 0:
      dec sim.players[playerIndex].fireWindup
      if sim.players[playerIndex].fireWindup == 0:
        firing.add(playerIndex)
    let input =
      if playerIndex < inputs.len: inputs[playerIndex]
      else: InputState()
    let prev =
      if playerIndex < prevInputs.len: prevInputs[playerIndex]
      else: InputState()
    sim.applyInput(playerIndex, input)
    sim.applyGrenadeInput(playerIndex, input, prev)
    if input.attack and not prev.attack:
      if sim.players[playerIndex].hasPlasmaArc:
        if sim.canFireArc(playerIndex):
          arcFiring.add(playerIndex)
      else:
        if sim.config.fireWindupTicks <= 0:
          if sim.canFire(playerIndex) and sim.players[playerIndex].fireWindup == 0:
            sim.startFireWindup(playerIndex)
            firing.add(playerIndex)
        else:
          sim.startFireWindup(playerIndex)
  sim.resolveSimultaneousFire(firing)
  for playerIndex in arcFiring:
    sim.startArcFire(playerIndex)
  sim.resolveActiveArcCones()
  sim.updateGrenades()
  sim.updateMedKits()
  sim.updateShields()
  sim.updatePlasmaArcs()

  for playerIndex in 0 ..< sim.players.len:
    sim.tryPickupFlags(playerIndex)
    sim.tryPickupGrenades(playerIndex)
    sim.tryPickupMedKits(playerIndex)
    sim.tryPickupShields(playerIndex)
    sim.tryPickupPlasmaArcs(playerIndex)
  sim.updateFlags()
  sim.respawnPlayers()

  sim.checkWinCondition()
  sim.checkMaxTicks()

  # Prune expired shot tracers and splatters (cosmetic only; excluded from
  # gameHash).
  var kept: seq[ShotFx] = @[]
  for shot in sim.recentShots:
    if sim.tickCount - shot.firedTick < ShotFxTicks:
      kept.add shot
  sim.recentShots = kept
  var keptFlashes: seq[HitFlashFx] = @[]
  for flash in sim.hitFlashes:
    if sim.tickCount - flash.tick < HitFlashTicks:
      keptFlashes.add flash
  sim.hitFlashes = keptFlashes
  var keptImpacts: seq[BubbleImpactFx] = @[]
  for impact in sim.bubbleImpacts:
    if sim.tickCount - impact.tick < BubbleImpactTicks:
      keptImpacts.add impact
  sim.bubbleImpacts = keptImpacts
  var keptBlasts: seq[BlastFx] = @[]
  for blast in sim.recentBlasts:
    if sim.tickCount - blast.tick < BlastFxTicks:
      keptBlasts.add blast
  sim.recentBlasts = keptBlasts
  var keptArcFlashes: seq[PlasmaArcFx] = @[]
  for flash in sim.plasmaArcFlashes:
    if sim.tickCount - flash.tick < PlasmaArcFxTicks:
      keptArcFlashes.add flash
  sim.plasmaArcFlashes = keptArcFlashes

  # Expire old shouts. Unlike the cosmetic effects above, shouts are
  # observable gameplay state (bots hear them), so expiry is part of the
  # deterministic sim and the hash.
  var keptShouts: seq[Shout] = @[]
  for shout in sim.recentShouts:
    if sim.tickCount - shout.tick < ShoutTicks:
      keptShouts.add shout
  sim.recentShouts = keptShouts
  var keptSplatters: seq[SplatterFx] = @[]
  for splatter in sim.splatters:
    let life = if splatter.hit: HitFxTicks else: SplatterFxTicks
    if sim.tickCount - splatter.tick < life:
      keptSplatters.add splatter
  sim.splatters = keptSplatters
  var keptPops: seq[DamageFx] = @[]
  for pop in sim.damagePops:
    let life = if pop.kill: KillFxTicks else: DamageFxTicks
    if sim.tickCount - pop.tick < life:
      keptPops.add pop
  sim.damagePops = keptPops
