import
  std/[algorithm, json, math, os, random, strutils],
  bitworld/aseprite, bitworld/pixelfonts, bitworld/profile, bitworld/spriteprotocol,
  bitworld/server,
  jsony, pixie

when not defined(emscripten):
  import bitworld/client as bitworldClient

import map_pool

const
  GameName* = "ctf"
  GameVersion* = "31"  ## GV31 (operator rule): WEAPONS HIT BODIES, NOT
                       ## POINTS. Three changes, all closing the same gap —
                       ## paint visibly covering a cog that walked away clean.
                       ## 1. The cone hits BODIES, not center points: a victim
                       ## is tested as a disc of PlasmaArcBodyRadius (half a
                       ## cog), where it used to be the bare point its 1px
                       ## collision box describes. Largest effect point-blank,
                       ## where the cone was narrower than the cog it covered.
                       ## 2. The reach grew 4 -> 5 squares, with the width
                       ## grown to match so the 14-degree half-angle did NOT
                       ## change. The 5th square is exactly what it takes to
                       ## cover the tip of the plume the game draws: the mist
                       ## is a chain of round puffs drawn oversize so they
                       ## merge, so it always reached past the cone that sized
                       ## it. test_plasma_arc pins the containment.
                       ## A cog can still be grazed by the plume's edge
                       ## without damage (the overlap makes the mist ~15px
                       ## wider than the cone); closing that too would need a
                       ## 31-degree cone, which is a different weapon.
                       ## 3. The GRENADE BLAST catches a cog whose SOLID BODY
                       ## BOX (±PlayerHalf) touches the blast circle, not
                       ## merely one whose position point falls inside it —
                       ## the same point-vs-body gap as (1), in the last
                       ## weapon that still had it. The gun already sampled
                       ## its bullet corridor across ±PlayerHalf, so once the
                       ## cone hits bodies the blast is the lone hold-out, and
                       ## a cog visibly standing in the splat could take
                       ## nothing. On-axis reach is now GrenadeBlastRadius +
                       ## PlayerHalf (58px); the radius constant and the splat
                       ## art are unchanged, so the splat now slightly
                       ## UNDER-sells its reach (the mirror of the plume's
                       ## overhang in (2)).
                       ## NOTE "body" is deliberately two sizes here: the cone
                       ## uses the DRAWN body (PlasmaArcBodyRadius, 17px)
                       ## because its whole point is covering visible paint,
                       ## while the gun and the blast use the SOLID footprint
                       ## (PlayerHalf, 6px) they have always used. Widening
                       ## the blast to the drawn body would take it from +31%
                       ## to +76% effective area, which is a balance change,
                       ## not a consistency fix.
                       ## GV30 (operator rule): every team's shield and spray
                       ## can is RED's spot carried over by the map's OWN
                       ## symmetry, not by a mirror. Mirroring a pickup on a
                       ## rot180 board lands it in the rotation of Red's OTHER
                       ## pickup, so Blue fought for a shield sitting in the
                       ## cans' terrain — different cover, different sightlines
                       ## to the same item. The 4-team boards had the rot90
                       ## version of the same bug (a mirrored copy lands in the
                       ## TRANSPOSE of Red's surroundings). Pickup positions
                       ## move on every map, including the hand-authored
                       ## arenas, so replays recorded under GV29 no longer
                       ## reproduce and the fixtures are re-recorded.
                       ## GV29 (operator rule): live spinning-diamond geometry
                       ## extends to GENERATED terrain, fairly. Selection is
                       ## closed under each map's symmetry group (a cross on
                       ## rot90 maps, where a vertical band is not invariant),
                       ## and spin DIRECTION follows it too: reflections turn
                       ## image diamonds opposite ways, rotations turn them
                       ## together. validateGeneratedMap now bounds the turn
                       ## from both sides, which re-curated the map pool.
                       ## GV28 (operator rule): on the HAND-AUTHORED arenas
                       ## the spinning center diamonds are REAL GEOMETRY, not
                       ## decoration. Their collision, bullet, and vision
                       ## footprint is the rotated diamond the art draws —
                       ## recomputed whenever the spin frame advances
                       ## (DiamondSpinTicksPerFrame) — so cover you can see is
                       ## cover you get, and a corner that has swept past no
                       ## longer stops a shot. The rotation is derived from
                       ## tickCount, so replays and every viewer agree; a
                       ## player the sweep would engulf is pushed to the
                       ## nearest free floor, never onto another body.
                       ## Generated terrain (pool/gen, and so every 4-team
                       ## map) keeps the GV27 baked static diamonds — see
                       ## isSpinningDiamond for why.
                       ## GV27 (operator rule): the default arena's
                       ## column-1 glass windows alternate from both ends
                       ## (stone, glass, stone, glass) — stubs 2, 4, and 6
                       ## of 7 (y=108, 300, 491), a top/bottom-symmetric
                       ## set replacing GV26's stubs 2, 5, 6; x-mirrored
                       ## like every column-1 shape.
                       ## TRENCHES are CONFIG-GATED and ship without a
                       ## version bump, exactly like procedural terrain:
                       ## the default arena has none, so its rules are
                       ## byte-identical, and a league opts in through its
                       ## own config (generated maps place pits per seed;
                       ## mapPits/mapPitDensity steer them). A trench is a
                       ## walkable dug-pit square — never a wall to
                       ## movement, bullets, or vision. Dropping in and
                       ## moving around inside are full speed; CLIMBING OUT
                       ## (motion away from the pit's center while inside)
                       ## is 1/5 speed (TrenchSpeedDivisor). Occupants fire
                       ## at 1/3 rate (TrenchFireSlowdown,
                       ## max-composed with the shield/carrier multiplier),
                       ## and TrenchMissPct percent of gun shots that would
                       ## hit an occupant fly straight over instead — the
                       ## bullet continues down the ray and can hit a body
                       ## behind (shots from inside the same trench are
                       ## exempt). Replays pin the exact trench set via
                       ## mapSpec, so playback is exact either way.
                       ## Procedural terrain itself (mapPath "gen"/"pool",
                       ## curated pool in map_pool.nim) is CONFIG-GATED and
                       ## shipped without a version bump: the default arena
                       ## layout is unchanged, and a league that enables it
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
  StainChancePct* = 100       ## % of paint landing on TERRAIN that dries into a
                              ## permanent stain. 100 = every miss marks the wall
                              ## it hit, so the lanes players actually run get
                              ## visibly repainted over a match; lower it to thin
                              ## the buildup. Cosmetic only, never in gameHash.
  StainSeatDepth* = 6         ## px a wall stain is pushed past the wall's
                              ## leading edge so the masked blot lands on the
                              ## face rather than half-overhanging the floor.
  StainMaxCount* = 1200       ## most dried stains kept for a match. A 5000-tick
                              ## game with 16 cogs firing every FireCooldownTicks
                              ## tops out near 6600 shots, so this caps unbounded
                              ## growth (and the wire) while still reading as
                              ## "this corridor is covered in paint". Oldest wins:
                              ## once full, new paint stops sticking rather than
                              ## evicting the history the viewer already saw.
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
  ClassicScoring* = "classic" ## winner +1 per losing team, each loser -1.
  PotScoring* = "pot"         ## every team antes one point; the winning team
                              ## takes the whole pot and the losing teams
                              ## split the forfeit (see potScoring below).
  TimeoutReward* = -1         ## EVERY player scores -1 on a time-limit draw
                              ## (GameVersion 21): stalling out the clock is
                              ## never better than losing, for either side.

  FlagPickupRange* = 12       ## touch radius to steal the enemy flag.
  CaptureZoneWidth* = 40      ## width of each home-edge capture zone.
  PedestalCoverSize* = 96     ## px footprint the flag-home pedestal art covers.

  ClassicHomeDepth* = 700     ## the historical home-anchor depth permille:
                              ## the base 30% of the way in from its edge.
  HomeDepthMin* = 400         ## depth bounds. Below the floor the bases
  HomeDepthMax* = 800         ## crowd the center; above it they clip the
                              ## border.
  EndzoneRadiusMin* = 90      ## compact-endzone radius bounds. The floor
  EndzoneRadiusMax* = 220     ## keeps the pedestal art and its endzone pits
                              ## inside the zone; the ceiling keeps the two
                              ## zones clear of the center ring.
  EndzoneWallMargin* = 6      ## px of protected floor past the scoring ring,
                              ## the compact echo of the classic column's
                              ## 210-clear vs 206-threshold gap.

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
  GrenadeBlastRadius* = 52    ## everyone whose SOLID BODY BOX (±PlayerHalf)
                              ## touches this circle takes damage — a body
                              ## test, not a position-point test (GV31), so
                              ## on-axis reach is 52 + PlayerHalf = 58 px.
                              ## (GameVersion 17: 40 -> 52, +30%.)
  GrenadeDamage* = 2          ## hit points removed by one blast, for a
                              ## victim standing outside any trench.
  GrenadeTrenchDamage* = 6    ## a blast that lands in the SAME trench as its
                              ## victim: the pit traps the blast, amplifying it.
  GrenadeTrenchSplashDamage* = 1  ## a victim in a trench, hit by a blast that
                              ## landed elsewhere (open field or another
                              ## trench): the pit mostly shields them.
  BlastFxTicks* = 12          ## cosmetic blast flash duration in ticks.

  MedKitPickupRange* = 12     ## touch radius to pick a med kit up.
  MedKitRespawnTicks* = 30 * ReplayFps  ## a taken kit refills after 30s.
  PlasmaArcSpawnInset* = GrenadeSpawnInset
  PlasmaArcPickupRange* = 12  ## touch radius to pick a plasma arc up.
  PlasmaArcRespawnTicks* = 30 * ReplayFps
  PlasmaArcSquare* = SoldierBodyPx  ## one "square": a cog body length.
  PlasmaArcFxReach* = 4 * PlasmaArcSquare
                              ## how far the DRAWN plume spans, and the span
                              ## its puffs are sized against. This is art
                              ## geometry, not damage: the mist is a chain of
                              ## round puffs drawn oversize so they merge
                              ## (SprayPuffOverlap), so its outermost pixel
                              ## lands well past this. The damage reach below
                              ## is set to cover that overhang — see
                              ## test_plasma_arc's containment check, which is
                              ## what keeps the two in step if either moves.
  PlasmaArcFxMaxWidth* = 2 * PlasmaArcSquare
                              ## the drawn plume's width at PlasmaArcFxReach.
  PlasmaArcReach* = 5 * PlasmaArcSquare  ## forward cone reach: 5 squares
                              ## (GameVersion 30, was 4). The 5th square is
                              ## not extra range for its own sake — it is
                              ## exactly what it takes for the damage cone to
                              ## cover the tip of the plume the game draws, so
                              ## a cog the paint engulfs cannot walk away
                              ## clean.
  PlasmaArcMaxWidth* = 5 * PlasmaArcSquare div 2  ## cone width AT max reach:
                              ## 2.5 squares, which holds the half-angle at
                              ## atan(1/4) ~ 14.0 degrees everywhere along the
                              ## reach as the reach grew. The cone widens
                              ## linearly from the muzzle.
  PlasmaArcBodyRadius* = SoldierBodyPx div 2
                              ## the sprayed cog's own half-width, added to the
                              ## cone on every side (GameVersion 30). Reach and
                              ## width above describe the cone's CENTERLINE
                              ## geometry, and a victim used to be tested as a
                              ## bare point (CollisionW is 1px) — so paint could
                              ## visibly engulf a 34px body that took no damage,
                              ## worst of all point-blank, where the centerline
                              ## cone is narrower than the cog it covers (10px
                              ## to each side at 40px out). Spraying a body now
                              ## hits it: the test is the cog's DISC against the
                              ## cone, not its center point.
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

  TrenchSize* = 56            ## side length of the walkable trench square
                              ## open flag ring (corner reach ~40px < the
                              ## 70px ring), so it never touches a wall.
  TrenchSpeedDivisor* = 5     ## CLIMBING OUT is 1/5 speed: while the center
                              ## is inside a pit, any axis motion pointing
                              ## AWAY from the pit's center has its cap and
                              ## accel divided by this, and outward momentum
                              ## sheds to the cap. Dropping in, crossing,
                              ## and moving around the pit are full speed.
  TrenchFireSlowdown* = 3     ## an occupant's gun fire cooldown multiplier
                              ## (1/3 fire rate). Max-composed with the
                              ## shield/carrier slowdown, never the product —
                              ## same rule as shield+heart (GV26).
  TrenchMissPct* = 70         ## percent of gun shots that would hit a trench
                              ## occupant that fly straight over instead
                              ## (deterministic sim RNG); the bullet carries
                              ## on down the ray. Shots fired from inside the
                              ## same trench never miss this way.

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
  ScoreboardLayerId* = 1       ## left roster panel (red; +green on 4-team maps).
  ScoreboardLayerType* = 1     ## top-left anchor.
  ScoreboardRightLayerId* = 12 ## right roster panel (blue; +yellow on 4-team maps).
  ScoreboardRightLayerType* = 2  ## top-right anchor.
  BottomRightLayerId* = 3
  BottomRightLayerType* = 3
  ZoomableLayerFlag* = 1
  UiLayerFlag* = 2
  PlayerSpriteBase* = 100
  FlagSpriteBase* = 700       ## team flag sprites: 700..703 by team.
  SelectedPlayerSpriteBase* = 6000  ## outlined selected-soldier pool:
                              ## 4 teams x 16 rotations per skin — default
                              ## 6000..6063, crown 6064..6127. Moved from
                              ## 800: that pool swallowed the hp pips
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
  ## Team colors: Red team = palette red (3), Blue team = palette blue (13),
  ## Green team = palette green (10), Yellow team = palette yellow (8).
  RedTeamColor* = 3'u8
  BlueTeamColor* = 13'u8
  GreenTeamColor* = 10'u8
  YellowTeamColor* = 8'u8
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
    ## The first two members are the classic pair; a game's ACTIVE teams are
    ## always a prefix of this enum (`Red .. Team(teamCount - 1)`), so every
    ## 2-team code path sees exactly the members it always did.
    Red
    Blue
    Green
    Yellow

  TeamLayout* = enum
    ## Where the teams live on the map. `layoutSides` is the classic 2-team
    ## left/right arena; the two 4-team layouts put a team in each corner or
    ## at the end of each arm of a plus.
    layoutSides
    layoutCorners
    layoutPlus

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

  EndzoneShape* = enum
    ## The shape of a team's home capture region on a SIDES map. The classic
    ## column runs the full map height along the home border; the two COMPACT
    ## shapes wrap the base itself, which lets the base sit well off the edge
    ## with playable wilderness all around it — behind included.
    ezColumn
    ezDisc
    ezSquare

  CaptureZone* = object
    ## One team's home capture region. Sides maps use the classic
    ## full-height columns; plus arms are boxes bounded on both axes; corner
    ## teams get a DIAGONAL zone — everything within an L1 radius of their
    ## map corner, whose threshold edge is a 45-degree line cut across the
    ## corner. A COMPACT endzone is the anchor-centered box (a square zone
    ## needs nothing more; `disc` rounds it off). The box fields always hold
    ## the zone's bounding box (the strip and diff-box machinery scan it);
    ## `diag` / `disc` refine membership.
    xLo*, xHi*, yLo*, yHi*: int
    diag*: bool                ## L1 corner zone instead of the full box.
    cornerX*, cornerY*: int    ## the map corner the diagonal zone hugs.
    diagLimit*: int            ## inclusive L1 radius from that corner.
    disc*: bool                ## L2 zone around the anchor instead of the box.
    anchorX*, anchorY*: int    ## the base the compact zone is centered on.
    radius*: int               ## inclusive L2 radius from that anchor.

  MapSymmetry* = enum
    ## How a map's full obstacle set derives from its authored/generated
    ## seed set. Mirror and rot180 complete a LEFT-half set across the
    ## vertical center line (2-team maps); rot90 completes a QUADRANT set by
    ## rotating it 90/180/270 degrees about the center (4-team maps, square
    ## only). All are exactly team-fair; rot180 keeps diagonal lanes diagonal
    ## instead of folding them into chevrons.
    symMirror
    symRot180
    symRot90

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
    spawnClearW*: int          ## half-width of the open spawn pockets.
    spawnClearH*: int          ## half-height of the open spawn pockets.
    gunRange*: int             ## default gun range on this map (px).
    endzone*: EndzoneShape     ## home capture-region shape (sides maps).
    endzoneRadius*: int        ## COMPACT endzones: the scoring radius (disc)
                               ## or half-extent (square) around the anchor,
                               ## in px. 0 on `ezColumn` maps.
    homeDepth*: int            ## home anchor position as a permille of the
                               ## half-field, measured from the center: 700
                               ## (the classic) puts the base 30% of the way
                               ## in from its edge, and SMALLER values push it
                               ## further from the edge.
    symmetry*: MapSymmetry
    layout*: TeamLayout        ## sides (2 teams) / corners / plus (4 teams).
    genSeed*: int              ## generator seed; 0 for hand-authored maps.
    medKitSpawns*: seq[MapPoint]     ## the two ACTIVE med-kit points.
    medKitCandidates*: seq[MapPoint] ## the drawn candidate set (4 on
                                     ## generated maps; equals the active
                                     ## pair on hand-authored maps).
    leftObstacles*: seq[ArenaShape]
    trenches*: seq[MapRect]    ## walkable dug-pit squares (config-gated trenches): standing
                               ## inside slows movement and fire, and most
                               ## incoming gun shots fly straight over.

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
    wins*: array[Team, int]    ## lifetime wins while seated on each team.
    games*: array[Team, int]   ## lifetime games seated on each team.
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
    layout*: string        ## 4-team maps: "corners" | "plus"; "" = draw.
    pits*: int             ## requested TOTAL trench count, 0..64; -1 =
                           ## density draw. Best-effort: when the candidate
                           ## spots can't host the full request, the map
                           ## places as many as fit. Even counts place
                           ## symmetric pairs; an odd count anchors its
                           ## extra pit dead center (self-symmetric under
                           ## mirror AND rot180), so both parities stay
                           ## exactly team-fair.
    pitDensity*: int       ## percent multiplier on the default per-class
                           ## pit chances (100 = default feel, 0 = none,
                           ## 200 = twice as digging-happy); -1 = default.
                           ## Ignored when `pits` locks an exact count.
    endzone*: string       ## "column" | "disc" | "square"; "" = draw. The
                           ## two COMPACT shapes wrap the base and open the
                           ## home border strip up as wilderness.
    endzoneRadius*: int    ## compact endzone scoring radius in px,
                           ## EndzoneRadiusMin..EndzoneRadiusMax; 0 = draw.
                           ## Ignored on `ezColumn` maps.
    baseDepth*: int        ## home anchor depth permille (see CtfMap.
                           ## homeDepth), HomeDepthMin..HomeDepthMax;
                           ## 0 = draw (700 on column maps).

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
    teams*: int               ## active team count: 2 (classic sides) or 4
                              ## (corner / plus free-for-all maps). Every
                              ## team fights for itself; "2v2" is two
                              ## policies splitting one classic team's
                              ## seats, not a game mode.
    scoring*: string          ## end-of-game reward rule: ClassicScoring
                              ## (default, unchanged) or PotScoring.
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

  DiamondPatch = object
    ## Diamond-free wall pixels for one live geometry window.
    x0, y0, w, h: int
    frame: int
    dirty: bool     ## frame advanced this tick, mask not restamped yet.
    baseWall: seq[bool]
    neighbours: seq[int]
      ## Every diamond whose own window overlaps this one, INCLUDING itself.
      ## A restamp ORs all of them, so a shared pixel gets the same answer
      ## whichever window wrote it last. Usually just self; dense generated
      ## maps can pack diamonds closer than the arena does.

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

  PaintStain* = object
    ## A DRIED paint stain on the terrain: cosmetic, permanent for the rest of
    ## the match, and never in gameHash (replay-safe). Where SplatterFx marks
    ## where a cog was HIT and fades over a few seconds, a stain is the paint
    ## that missed and hit the map — so the lanes players fight over slowly
    ## accumulate their colors. Emitted once per stain and then left on the
    ## client forever (see addPaintStains), so this is nearly free per frame.
    x*, y*: int
    color*: uint8              ## the SHOOTER's paint, so a lane's color says
                               ## which team keeps running it.
    onWall*: bool              ## true when the paint struck WALL geometry. The
                               ## renderer masks the blot to pixels of this same
                               ## surface, so a splat on a wall stays on the wall
                               ## instead of spilling onto the floor beside it.
    seed*: uint32              ## picks the blot shape/rotation variant, derived
                               ## from the impact site so a replay re-derives
                               ## the identical mark.

  DiamondStain* = object
    ## Paint that landed on a ROTATING center diamond. Stored in the diamond's
    ## OWN un-rotated frame (lx, ly) rather than in map pixels, so the mark
    ## turns with the stone it stuck to instead of hanging in the air where the
    ## shot happened to hit. Cosmetic; never enters gameHash.
    diamond*: uint8            ## index into AnimatedDiamonds.
    lx*, ly*: float32          ## offset from the diamond center, un-rotated.
    color*: uint8
    seed*: uint32

  BlastFx* = object
    ## A cosmetic grenade blast flash; never enters gameHash (replay-safe).
    ## Landing is audible: views also derive their landing sound rings here.
    x*, y*: int
    tick*: int
    color*: uint8              ## the thrower's paint color, so the landing
                               ## splat reads as that team's paint-bomb.
    trenchLanding*: bool       ## true when the blast landed inside a trench:
                               ## the flash renders truncated to the pit's
                               ## footprint instead of the open-field size.

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
    amount*: int               ## hit points lost (1 for a shot; a grenade
                               ## varies by trench, see explodeGrenade).
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
    windowMask*: seq[bool]     ## STATIC glass pixels; wall, but never opaque to vision.
    fovBlocked*: seq[bool]     ## FovGridW x FovGridH; a cell is opaque when mostly wall.
    fovCaches: seq[PlayerFov]
    diamondPatches: seq[DiamondPatch]
    rng*: Rand
    nextJoinOrder*: int
    tickCount*: int
    recentShots*: seq[ShotFx]  ## cosmetic shot tracers; excluded from gameHash.
    hitFlashes*: seq[HitFlashFx]  ## cosmetic struck-target flashes; excluded from gameHash.
    bubbleImpacts*: seq[BubbleImpactFx]  ## cosmetic shield-bubble impact blinks; excluded from gameHash.
    splatters*: seq[SplatterFx]  ## cosmetic death splatters; excluded from gameHash.
    diamondStains*: seq[DiamondStain]  ## permanent paint riding the spinning
                               ## center diamonds; excluded from gameHash.
    paintStains*: seq[PaintStain]  ## permanent dried terrain paint; excluded from
                               ## gameHash. Append-only within a match and reset
                               ## on startGame/resetToLobby, so a replay rebuilds
                               ## the exact same buildup as it re-simulates and a
                               ## keyframe scrub restores the paint of that tick.
    recentBlasts*: seq[BlastFx]  ## cosmetic grenade blasts; excluded from gameHash.
    damagePops*: seq[DamageFx]  ## cosmetic floating "-N" damage numbers; excluded from gameHash.
    recentShouts*: seq[Shout]  ## live shouts; observable state, in gameHash.
    grenadeSpawns*: array[4, PickupSpawn]
    medKitSpawns*: seq[PickupSpawn]       ## the map's active med kits (2 on
                                          ## sides maps, 4 on 4-team maps).
    shieldSpawns*: seq[PickupSpawn]       ## one shield per team endzone.
    plasmaArcSpawns*: seq[PickupSpawn]    ## one spray can per team endzone.
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

proc teamCount*(layout: TeamLayout): int =
  ## Returns how many teams a layout seats.
  case layout
  of layoutSides:
    2
  of layoutCorners, layoutPlus:
    4

proc teamCount*(gameMap: CtfMap): int =
  ## Returns how many teams play on one map.
  gameMap.layout.teamCount()

proc activeTeams*(count: int): Slice[Team] =
  ## Returns the active-team slice for one team count. Active teams are
  ## always a prefix of the enum, so 2-team games iterate exactly Red..Blue
  ## — every historical loop, hash, and wire frame is unchanged.
  doAssert count in [2, 4], "team count must be 2 or 4"
  Red .. Team(count - 1)

proc teams*(gameMap: CtfMap): Slice[Team] =
  ## Returns the active teams on one map.
  activeTeams(gameMap.teamCount())

proc teams*(sim: SimServer): Slice[Team] =
  ## Returns the active teams in one game.
  sim.gameMap.teams()


proc teamText*(team: Team): string =
  ## Returns the readable team name.
  case team
  of Red:
    "red"
  of Blue:
    "blue"
  of Green:
    "green"
  of Yellow:
    "yellow"

proc teamColor*(team: Team): uint8 =
  ## Returns the palette color for one team.
  case team
  of Red:
    RedTeamColor
  of Blue:
    BlueTeamColor
  of Green:
    GreenTeamColor
  of Yellow:
    YellowTeamColor

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
    "data/heart_" & teamText(team) & ".png",
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
    Blue: "data/soldier_blue.png",
    Green: "data/soldier_green.png",
    Yellow: "data/soldier_yellow.png"
  ],
  CrownSkin: [
    Red: "data/soldier_red_crown.png",
    Blue: "data/soldier_blue_crown.png",
    Green: "data/soldier_green_crown.png",
    Yellow: "data/soldier_yellow_crown.png"
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
  rigHeadImg: array[Skin, array[Team, Image]]
  rigScale: array[Team, float]   ## master-frame px -> map px (body fills body px).
  # The head asset is skin-specific; all other rig segments are shared.
  # Bake cache keyed by skin and (baseStep, artStep, shortenStep, scale).
  # baseStep is the aim step (head/arms) or heading step (legs/wheels); artStep
  # is the leg swing or wheel caster; shortenStep is the leg-length index
  # (0 for non-legs).
  rigSegCache: array[Skin, array[Team, array[RigSeg, seq[tuple[
    baseStep, artStep, shortenStep, scale: int, pixels: seq[uint8]]]]]]

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
  let dir = gameDir() / "data/rig_real" / teamText(team)
  for seg in RigSeg:
    rigSegImg[team][seg] = readImage(dir / rigSegPath(seg) & ".png")
  rigHeadImg[DefaultSkin][team] = rigSegImg[team][rsHead]
  rigHeadImg[CrownSkin][team] = readImage(dir / "head_crown.png")
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
    shortenStep = 0, renderScale = 1, skin = DefaultSkin): seq[uint8] =
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
    effectiveSkin = if seg == rsHead: skin else: DefaultSkin
  for cached in rigSegCache[effectiveSkin][team][seg]:
    if cached.baseStep == b and cached.artStep == art and
        cached.shortenStep == sh and cached.scale == renderScale:
      return cached.pixels
  ensureRigLoaded(team)
  let
    outCanvas = RigCanvas * renderScale
    img =
      if seg == rsHead:
        rigHeadImg[effectiveSkin][team]
      else:
        rigSegImg[team][seg]
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
  rigSegCache[effectiveSkin][team][seg].add(
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
  case gameMap.layout
  of layoutSides:
    if gameMap.symmetry == symRot90:
      raise newException(CtfError, "Sides maps cannot use rot90 symmetry.")
  of layoutCorners, layoutPlus:
    if gameMap.symmetry != symRot90:
      raise newException(CtfError, "Corner/plus maps are rot90-only.")
  if gameMap.symmetry == symRot90 and gameMap.width != gameMap.height:
    ## rot90 rotates about the center of a SQUARE; a non-square board would
    ## silently produce team-unfair obstacle images.
    raise newException(CtfError, "rot90 symmetry needs a square map.")
  if gameMap.homeDepth != 0 and
      (gameMap.homeDepth < HomeDepthMin or gameMap.homeDepth > HomeDepthMax):
    raise newException(
      CtfError, "Map home depth must be " & $HomeDepthMin & ".." &
        $HomeDepthMax & " permille (0 = the classic " &
        $ClassicHomeDepth & ").")
  if gameMap.endzone == ezColumn:
    if gameMap.endzoneRadius != 0:
      raise newException(
        CtfError, "Column endzones carry no radius.")
  else:
    if gameMap.layout != layoutSides:
      raise newException(
        CtfError, "Compact endzones need a 2-team sides map.")
    if gameMap.endzoneRadius < EndzoneRadiusMin or
        gameMap.endzoneRadius > EndzoneRadiusMax:
      raise newException(
        CtfError, "Map endzone radius must be " & $EndzoneRadiusMin & ".." &
          $EndzoneRadiusMax & " px.")
  validateMapPoint("center", gameMap.center, gameMap.width, gameMap.height)
  for i, room in gameMap.rooms:
    validateMapRect(
      "room " & $i,
      MapRect(x: room.x, y: room.y, w: room.w, h: room.h),
      gameMap.width,
      gameMap.height
    )
  for i, trench in gameMap.trenches:
    validateMapRect("trench " & $i, trench, gameMap.width, gameMap.height)

const
  ArenaName = "arena"
  ArenaLargeName = "arena-large"
  ArenaBorder* = 10            ## perimeter wall thickness in px.

  ## Warm CRT-phosphor arena (REPLAY_DESIGN §3 art-lock): neutral-warm grey
  ## polished-concrete floor, warm-stone cover, the two team colors the only
  ## saturated channels — never the cold blue-slate default the house style
  ## forbids.
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
    # Column 1 (x=268..286): rect stubs, phase 0, border-attached ends.
    # GV27 (operator rule): the GLASS WINDOWS alternate from both ends —
    # stone, glass, stone, glass — landing on stubs 2, 4 (the middle), and
    # 6 of 7, a top/bottom-symmetric set. Glass is solid to movement,
    # bullets, and spray cones, transparent to fog-of-war; x-mirrored like
    # every column-1 shape.
    ArenaShape(kind: shapeRect, rect: MapRect(x: 268, y: 10, w: 18, h: 62)),
    ArenaShape(kind: shapeRect, window: true,
      rect: MapRect(x: 268, y: 108, w: 18, h: 60)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 268, y: 204, w: 18, h: 60)),
    ArenaShape(kind: shapeRect, window: true,
      rect: MapRect(x: 268, y: 300, w: 18, h: 59)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 268, y: 395, w: 18, h: 60)),
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

proc homeDepthOf(gameMap: CtfMap): int =
  ## The map's home-anchor depth permille, defaulting to the classic 700 so
  ## a zero-valued map (a hand-built test fixture, an old replay spec) keeps
  ## the historical anchors.
  if gameMap.homeDepth > 0: gameMap.homeDepth else: ClassicHomeDepth

proc axisHomeLo(center, depth: int): int =
  ## Returns the low-edge home anchor along one axis: `depth` permille of the
  ## way back from the center (700 = the classic 30%-from-the-edge home-x).
  ## At 700 this is exactly the historical `center * 7 div 10`.
  center - (center * depth div 1000)

proc axisHomeHi(center, size, depth: int): int =
  ## Returns the high-edge home anchor along one axis (the classic Blue
  ## home-x formula at depth 700).
  center + ((size - center) * depth div 1000)

proc rot90Point*(p: MapPoint, side: int): MapPoint {.inline.} =
  ## One quarter turn clockwise about the center of a side x side square
  ## board: (x, y) -> (side - 1 - y, x).
  ##
  ## The fixed point of that map is (side - 1)/2, which on an EVEN-sided
  ## board is a half pixel away from the div-derived `center`. Anything that
  ## has to be exactly its own quarter turn must therefore be built by
  ## walking this orbit (or measured in doubled coordinates), never anchored
  ## to `center` — see rot90Quarter and centerOffset2.
  MapPoint(x: side - 1 - p.y, y: p.x)

proc rot90Quarter*(gameMap: CtfMap, team: Team): int =
  ## How many quarter turns separate RED's quadrant from this team's. Team
  ## enum order is not orbit order for either 4-team layout, so the mapping
  ## is spelled out per layout; sides maps have no rot90 orbit at all.
  case gameMap.layout
  of layoutSides:
    0
  of layoutCorners:
    ## Orbit top-left -> top-right -> bottom-right -> bottom-left.
    case team
    of Red: 0
    of Blue: 1
    of Yellow: 2
    of Green: 3
  of layoutPlus:
    ## Orbit west -> north -> east -> south.
    case team
    of Red: 0
    of Green: 1
    of Blue: 2
    of Yellow: 3

proc rot90TeamPoint*(gameMap: CtfMap, red: MapPoint, team: Team): MapPoint =
  ## RED's point walked round the orbit to `team`'s quadrant. Anything one
  ## team owns a copy of — a home, a pickup — has to be built this way: the
  ## rot90 wall mask carries Red's surroundings onto the image of Red's
  ## point, so a copy placed by MIRRORING lands in the transpose of them
  ## instead, with different cover and different sightlines.
  result = red
  for _ in 0 ..< gameMap.rot90Quarter(team):
    result = result.rot90Point(gameMap.width)

proc teamImagePoint*(gameMap: CtfMap, red: MapPoint, team: Team): MapPoint =
  ## RED's point carried onto `team`'s side of the board by the map's OWN
  ## symmetry — the general form of `rot90TeamPoint`, for the 2-team boards
  ## too.
  ##
  ## Which symmetry is not a detail: the terrain was built with exactly one
  ## of them, and only that one carries Red's surroundings onto the image.
  ## On a rot180 board a MIRRORED copy lands in the rotation of some other
  ## Red spot instead — which is how the shields came to sit in the terrain
  ## of the spray cans, and the cans in the terrain of the shields.
  case gameMap.symmetry
  of symRot90:
    gameMap.rot90TeamPoint(red, team)
  of symMirror:
    if team == Red: red
    else: MapPoint(x: gameMap.width - 1 - red.x, y: red.y)
  of symRot180:
    if team == Red: red
    else: MapPoint(
      x: gameMap.width - 1 - red.x, y: gameMap.height - 1 - red.y)

proc teamAnchor*(gameMap: CtfMap, team: Team): MapPoint =
  ## Returns one team's home anchor: the center of its protected spawn
  ## pocket, where its pedestal stands.
  ##
  ## 4-team anchors are RED's anchor walked around the rot90 orbit, so every
  ## team's home is EXACTLY a quarter turn of every other team's. Deriving
  ## the far anchors from axisHomeHi instead would place them symmetrically
  ## about `center` — one pixel off the orbit on an even-sided board, which
  ## is a fairness difference, not a rounding detail.
  let
    cx = gameMap.center.x
    cy = gameMap.center.y
    d = gameMap.homeDepthOf()
  case gameMap.layout
  of layoutSides:
    result =
      case team
      of Red:
        MapPoint(x: axisHomeLo(cx, d), y: cy)
      else:
        MapPoint(x: axisHomeHi(cx, gameMap.width, d), y: cy)
  of layoutCorners, layoutPlus:
    ## Red seeds the orbit: top-left on corner maps, west on plus maps.
    result =
      if gameMap.layout == layoutCorners:
        MapPoint(x: axisHomeLo(cx, d), y: axisHomeLo(cy, d))
      else:
        MapPoint(x: axisHomeLo(cx, d), y: cy)
    for _ in 0 ..< gameMap.rot90Quarter(team):
      result = result.rot90Point(gameMap.width)

proc spawnPocketHalf*(gameMap: CtfMap, team: Team): tuple[w, h: int] =
  ## The half-extents of one team's protected spawn pocket, around its
  ## anchor. The pocket is taller than it is wide, so it does NOT survive a
  ## quarter turn unchanged: on rot90 boards the odd quarters carry the
  ## rotated W x H -> H x W box. Stamping the same box at all four anchors
  ## would carve two of the four quadrants to a different shape than their
  ## rotational twins — on a 1248px board that is ~119k pixels, 7.6% of the
  ## board, where the protected floor disagrees with its own quarter turn.
  ##
  ## Mirror and rot180 symmetries preserve the axes, so 2-team maps keep the
  ## single upright box they always had.
  if gameMap.rot90Quarter(team) mod 2 == 1:
    (gameMap.spawnClearH, gameMap.spawnClearW)
  else:
    (gameMap.spawnClearW, gameMap.spawnClearH)

proc plusArmHalf*(gameMap: CtfMap): int =
  ## Returns the half-span of a plus map's arms — the width of each team's
  ## endzone mouth and protected approach: 19% of the map side, comfortably
  ## wider than the spawn pockets on every size class.
  19 * min(gameMap.width, gameMap.height) div 100

proc plusArmBand*(gameMap: CtfMap): tuple[lo, hi: int] =
  ## The inclusive span an arm occupies across the board, centered on the
  ## board's TRUE rot90 axis at (side - 1)/2 rather than on the integer
  ## center. The two differ by a pixel on an even side, and a band centered
  ## on `center` is not its own quarter turn — the west arm's y-span would
  ## land one pixel off the north arm's x-span. Identical to the doubled
  ## comparison mapProtectedFloorAt carves the approach with.
  let
    side = min(gameMap.width, gameMap.height)
    lo = (side - 2 * gameMap.plusArmHalf()) div 2
  (lo, side - 1 - lo)

proc teamHomeX*(gameMap: CtfMap, team: Team): int =
  ## Returns the home-edge x anchor for one team's spawn strip and pedestal.
  gameMap.teamAnchor(team).x

proc flagHome*(gameMap: CtfMap, team: Team): MapPoint =
  ## Returns the pedestal position for one team's flag, at the center of the
  ## team's protected spawn pocket.
  gameMap.teamAnchor(team)

proc trenchSquareAt(cx, cy: int): MapRect =
  ## A TrenchSize×TrenchSize dug pit centered on (cx, cy). Like obstacle
  ## sizes, the pit never scales with the map's size class.
  MapRect(
    x: cx - TrenchSize div 2,
    y: cy - TrenchSize div 2,
    w: TrenchSize,
    h: TrenchSize
  )

proc rectsIntersect(a, b: MapRect): bool =
  ## Returns true when the two rectangles overlap by at least one pixel.
  a.x < b.x + b.w and b.x < a.x + a.w and
    a.y < b.y + b.h and b.y < a.y + a.h

proc defaultCtfRooms(gameMap: CtfMap): seq[Room] =
  ## The room annotation set every map shares: an informal center zone plus
  ## one base strip per team spanning its spawn pocket. Derives entirely
  ## from the map's dimensions and clearances. Sides maps keep the classic
  ## full-clearance base columns; 4-team layouts box each pocket instead.
  result.add Room(name: "Center", x: gameMap.width div 2 - 80,
    y: gameMap.height div 2 - 80, w: 160, h: 160)
  if gameMap.endzone != ezColumn:
    ## Compact endzones ARE the base: the room is the zone's bounding box.
    let r = gameMap.endzoneRadius
    for team in gameMap.teams():
      let
        anchor = gameMap.teamAnchor(team)
        name = teamText(team)
      result.add Room(
        name: name[0].toUpperAscii() & name[1 .. ^1] & " Base",
        x: anchor.x - r, y: anchor.y - r, w: 2 * r, h: 2 * r
      )
    return
  case gameMap.layout
  of layoutSides:
    result.add Room(name: "Red Base", x: 0,
      y: gameMap.height div 2 - gameMap.spawnClearH,
      w: gameMap.captureClear, h: 2 * gameMap.spawnClearH)
    result.add Room(name: "Blue Base",
      x: gameMap.width - gameMap.captureClear,
      y: gameMap.height div 2 - gameMap.spawnClearH,
      w: gameMap.captureClear, h: 2 * gameMap.spawnClearH)
  of layoutCorners, layoutPlus:
    for team in gameMap.teams():
      let
        anchor = gameMap.teamAnchor(team)
        half = gameMap.spawnPocketHalf(team)
        name = teamText(team)
      result.add Room(
        name: name[0].toUpperAscii() & name[1 .. ^1] & " Base",
        x: anchor.x - half.w,
        y: anchor.y - half.h,
        w: 2 * half.w,
        h: 2 * half.h
      )

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

proc captureZone*(gameMap: CtfMap, team: Team): CaptureZone =
  ## Returns one team's home capture zone. Sides maps keep the classic
  ## full-height home column unless the map draws a COMPACT endzone, which
  ## wraps the base in a disc or square instead; corner teams get a DIAGONAL
  ## zone (everything within an L1 radius of their map corner, its threshold
  ## a 45-degree line through the anchor); plus teams get an arm-mouth box
  ## past the anchor, bounded to the arm span — the open corners are
  ## battlefield.
  let
    anchor = gameMap.teamAnchor(team)
    half = CaptureZoneWidth div 2
    w = gameMap.width
    h = gameMap.height
  # Start from the full board and pull each bounded edge in to the anchor's
  # threshold; which edges are bounded is exactly what the layout decides.
  result = CaptureZone(xLo: 0, xHi: w - 1, yLo: 0, yHi: h - 1)
  if gameMap.endzone != ezColumn:
    ## A compact endzone is the anchor-centered box — which IS the square
    ## zone; the disc flag rounds its corners off. Every edge is an inner
    ## threshold, so the paint lines all four and a carrier scores from
    ## whichever side they reach.
    let r = gameMap.endzoneRadius
    result = CaptureZone(
      xLo: anchor.x - r, xHi: anchor.x + r,
      yLo: anchor.y - r, yHi: anchor.y + r,
      disc: gameMap.endzone == ezDisc,
      anchorX: anchor.x, anchorY: anchor.y, radius: r
    )
    return
  case gameMap.layout
  of layoutSides:
    if team == Red:
      result.xHi = anchor.x + half
    else:
      result.xLo = anchor.x - half
  of layoutCorners:
    ## The threshold edge is the 45-degree line through the anchor (plus
    ## half slack): everything within that L1 radius of the team's map
    ## corner scores. The box fields are its bounding box.
    result.diag = true
    result.cornerX = if anchor.x < gameMap.center.x: 0 else: w - 1
    result.cornerY = if anchor.y < gameMap.center.y: 0 else: h - 1
    result.diagLimit = abs(anchor.x - result.cornerX) +
      abs(anchor.y - result.cornerY) + half
    ## The inset-clamped respawn box must intersect the L1 region, or every
    ## respawn would silently fall back to the pedestal point.
    doAssert result.diagLimit >= 2 * (ArenaBorder + PlayerHalf) + 2,
      "degenerate diagonal capture zone"
    if anchor.x < gameMap.center.x:
      result.xHi = min(w - 1, result.diagLimit)
    else:
      result.xLo = max(0, w - 1 - result.diagLimit)
    if anchor.y < gameMap.center.y:
      result.yHi = min(h - 1, result.diagLimit)
    else:
      result.yLo = max(0, h - 1 - result.diagLimit)
  of layoutPlus:
    ## An arm-mouth box: past the anchor on the home axis, bounded to the
    ## arm span on the other (the corners are open field, not endzone).
    let band = gameMap.plusArmBand()
    case team
    of Red:
      result.xHi = anchor.x + half
      result.yLo = band.lo
      result.yHi = band.hi
    of Blue:
      result.xLo = anchor.x - half
      result.yLo = band.lo
      result.yHi = band.hi
    of Green:
      result.yHi = anchor.y + half
      result.xLo = band.lo
      result.xHi = band.hi
    of Yellow:
      result.yLo = anchor.y - half
      result.xLo = band.lo
      result.xHi = band.hi

proc inCaptureZone*(zone: CaptureZone, x, y: int): bool =
  ## Returns whether a map point sits inside one capture zone.
  if x < zone.xLo or x > zone.xHi or y < zone.yLo or y > zone.yHi:
    return false
  if zone.diag:
    return abs(x - zone.cornerX) + abs(y - zone.cornerY) <= zone.diagLimit
  if zone.disc:
    let
      dx = x - zone.anchorX
      dy = y - zone.anchorY
    return dx * dx + dy * dy <= zone.radius * zone.radius
  true

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

proc rot90(rect: MapRect, side: int): MapRect =
  ## Rotates one rectangle 90 degrees clockwise about the center of a
  ## side x side square map: pixel (x, y) maps to (side - 1 - y, x).
  MapRect(
    x: side - rect.y - rect.h,
    y: rect.x,
    w: rect.h,
    h: rect.w
  )

proc rot90(shape: ArenaShape, side: int): ArenaShape =
  ## Rotates one arena shape 90 degrees clockwise about the center of a
  ## side x side square map. Applying it twice equals rot180, so the rot90
  ## quadrant replication is an exact 4-fold symmetry group. Diamonds and
  ## discs are rotation-invariant about their own centers, so only the
  ## centers move.
  case shape.kind
  of shapeRect:
    ArenaShape(kind: shapeRect, window: shape.window,
      rect: shape.rect.rot90(side))
  of shapeDisc:
    ArenaShape(
      kind: shapeDisc,
      window: shape.window,
      cx: side - 1 - shape.cy,
      cy: shape.cx,
      radius: shape.radius
    )
  of shapeDiamond:
    ArenaShape(
      kind: shapeDiamond,
      window: shape.window,
      cx: side - 1 - shape.cy,
      cy: shape.cx,
      radius: shape.radius
    )
  of shapeDiagonal:
    ArenaShape(
      kind: shapeDiagonal,
      window: shape.window,
      x0: side - 1 - shape.y0,
      y0: shape.x0,
      x1: side - 1 - shape.y1,
      y1: shape.x1,
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
  ## The full obstacle set: every seed shape plus its image(s) under the
  ## map's symmetry (x-mirror or 180° rotation of the left half; 90/180/270°
  ## rotations of the quadrant on rot90 maps), precomputed once per map
  ## selection so the per-pixel wall test never re-mirrors.
  for shape in gameMap.leftObstacles:
    result.add shape
    case gameMap.symmetry
    of symMirror:
      result.add shape.mirrorX(gameMap.width)
    of symRot180:
      result.add shape.rot180(gameMap.width, gameMap.height)
    of symRot90:
      let quarter = shape.rot90(gameMap.width)
      result.add quarter
      result.add shape.rot180(gameMap.width, gameMap.height)
      result.add quarter.rot180(gameMap.width, gameMap.height)

## Spinning-diamond geometry lives up here, ahead of mapWallAt, because
## the terrain validator has to reason about the whole turn.

const
  DiamondSpinFrames* = 16      ## steps across 90° (a diamond is 4-fold symmetric).
  DiamondSpinTicksPerFrame* = 4  ## ~2.7s per quarter turn at 24 ticks/s.
  DiamondRotShift = 16         ## fixed-point fraction bits of the spin table.
  DiamondRotOne = 1'i64 shl DiamondRotShift
  ## cos(frame * 5.625°), scaled by 2^16. Geometry must not use host libm.
  ## sin(frame) is the same table read from the other end.
  DiamondCos: array[DiamondSpinFrames + 1, int64] = [
    65536'i64, 65220'i64, 64277'i64, 62714'i64, 60547'i64,
    57798'i64, 54491'i64, 50660'i64, 46341'i64, 41576'i64,
    36410'i64, 30893'i64, 25080'i64, 19024'i64, 12785'i64,
    6424'i64, 0'i64
  ]

proc diamondFrameIndex(frame: int): int {.inline.} =
  ## Wraps any signed frame counter into 0 ..< DiamondSpinFrames.
  ((frame mod DiamondSpinFrames) + DiamondSpinFrames) mod DiamondSpinFrames


proc rotatedDiamondCovers*(
  radius, frame, dxNum, dyNum, denom: int
): bool =
  ## Integer rotated-L1 membership: is the offset (dxNum/denom, dyNum/denom)
  ## map pixels from a diamond's center inside it at `frame`? Keeping the
  ## division symbolic lets the collision masks (denom = 2) and the scale× art
  ## rasterizer (denom = 2·scale) share ONE predicate, so the drawn silhouette
  ## and the geometry cannot drift apart.
  ##
  ## Both samplers measure from the diamond's center pixel, NOT from pixel
  ## centers half a pixel to its right. Under the x-mirror (x -> width-1-x)
  ## a +0.5 offset does not flip sign, so a half-pixel sample would make each
  ## diamond's footprint the mirror of its twin's translated by one pixel —
  ## the arena's obstacle union is exactly mirror-symmetric and team fairness
  ## rests on it. On integer offsets the mirror is exact. As a bonus, frame 0
  ## then reproduces the plain |dx| + |dy| <= r diamond that
  ## isAnimatedDiamondPixel bakes the hole for.
  let
    index = diamondFrameIndex(frame)
    ca = DiamondCos[index]
    sa = DiamondCos[DiamondSpinFrames - index]
    rx = int64(dxNum) * ca + int64(dyNum) * sa
    ry = -int64(dxNum) * sa + int64(dyNum) * ca
  abs(rx) + abs(ry) <= int64(radius) * int64(denom) * DiamondRotOne

const DiamondSpinBand = 80
  ## Half-width, in map pixels, of the center column whose diamonds spin.

type SpinFootprint* = enum
  ## Which shape a spinning diamond presents to an offline (uninstalled-map)
  ## wall test. Live play always uses the exact per-frame silhouette; these
  ## are for validation, which must hold across the WHOLE turn and so needs
  ## the bound that points the right way for each invariant.
  spinRest       ## the resting diamond, i.e. what the art bake carves out.
  spinSwept      ## union over the turn: nothing outside this is ever stone.
  spinAlways     ## intersection over the turn: this is stone at every frame.

proc nearSpinAxis(center, span: int): bool {.inline.} =
  ## Is a shape centered at `center` inside the spin band of an axis `span`
  ## pixels long? Measured against the SYMMETRY AXIS at (span - 1)/2, not
  ## against the map's center pixel: on an even span the two differ by half a
  ## pixel, and a diamond whose image fell on the other side of the threshold
  ## would spin while its twin stayed baked stone. Doubling both sides keeps
  ## the comparison exact in integers.
  abs(2 * center - (span - 1)) < 2 * DiamondSpinBand

proc isSpinningDiamond(gameMap: CtfMap, shape: ArenaShape): bool {.inline.} =
  ## The diamonds flanking the center of the field are the ones drawn — and,
  ## since GV28, COLLIDED — as spinning stone.
  ##
  ## The selected set must be CLOSED under the map's symmetry group, or one
  ## team gets rotating cover where another gets solid stone. The authored
  ## rule is a vertical band down the center column; that band is already
  ## closed under the mirror and under 180° rotation, since both preserve
  ## distance from the vertical axis. It is NOT closed under 90° rotation,
  ## which maps it to a horizontal band — so on rot90 (4-team) maps the set is
  ## the band's own closure: the union of the vertical and horizontal bands, a
  ## cross through the center. The arena is unaffected either way; it selects
  ## the same eight diamonds it always has.
  if shape.kind != shapeDiamond:
    return false
  case gameMap.symmetry
  of symMirror, symRot180:
    nearSpinAxis(shape.cx, gameMap.width)
  of symRot90:
    nearSpinAxis(shape.cx, gameMap.width) or
      nearSpinAxis(shape.cy, gameMap.height)

proc buildAnimatedDiamonds*(
  gameMap: CtfMap, obstacles: seq[ArenaShape]
): seq[tuple[cx, cy, radius: int]] =
  ## The eight diamonds flanking the center of the field (column 5 and its
  ## x-mirror): drawn as slowly rotating sprites instead of baked wall art.
  ## Since GV28 the rotation is REAL: the bake leaves them out of every
  ## collision layer and the sim stamps the live rotated footprint into the
  ## movement, bullet, and vision masks as the frame advances
  ## (applyDiamondGeometry).
  for shape in obstacles:
    if gameMap.isSpinningDiamond(shape):
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

proc endzoneFloorAt*(
  x, y, anchorX, anchorY, radius: int, disc: bool
): bool =
  ## Whether a point sits on one COMPACT endzone's protected floor: the
  ## scoring shape grown by the wall margin, so the ring the carrier crosses
  ## is never flush against a wall.
  let
    grown = radius + EndzoneWallMargin
    dx = abs(x - anchorX)
    dy = abs(y - anchorY)
  if dx > grown or dy > grown:
    return false
  if disc:
    return dx * dx + dy * dy <= grown * grown
  true

proc centerOffset2*(
  gameMap: CtfMap, x, y: int
): tuple[dx, dy: int] {.inline.} =
  ## TWICE the offset of (x, y) from the map's symmetry center. Doubling is
  ## what lets a rot90 board measure against its true axis at (side - 1)/2:
  ## on an even side that axis is a half pixel off the div-derived `center`,
  ## so a radius or band measured from `center` is not its own quarter turn.
  ## Mirror and rot180 maps keep the historical integer center exactly —
  ## every comparison below is the old one scaled by 4, so 2-team terrain is
  ## bit-identical.
  if gameMap.symmetry == symRot90:
    (2 * x - (gameMap.width - 1), 2 * y - (gameMap.height - 1))
  else:
    (2 * (x - gameMap.center.x), 2 * (y - gameMap.center.y))

proc mapProtectedFloorAt*(gameMap: CtfMap, x, y: int): bool =
  ## isProtectedFloor for a map that is NOT installed as the process map:
  ## the generator and validators run on candidates before any selection.
  if gameMap.endzone != ezColumn:
    ## COMPACT endzones protect the shape around each base and NOTHING at
    ## the border: the home strip is wilderness the terrain may build on.
    for team in gameMap.teams():
      let anchor = gameMap.teamAnchor(team)
      if endzoneFloorAt(x, y, anchor.x, anchor.y, gameMap.endzoneRadius,
          gameMap.endzone == ezDisc):
        return true
    let
      dcx = x - gameMap.center.x
      dcy = y - gameMap.center.y
    return dcx * dcx + dcy * dcy <= gameMap.flagRing * gameMap.flagRing
  let
    clear = gameMap.captureClear
    nearX = x < clear or x >= gameMap.width - clear
    nearY = y < clear or y >= gameMap.height - clear
    (dx2, dy2) = gameMap.centerOffset2(x, y)
    approach =
      case gameMap.layout
      of layoutSides:
        nearX
      of layoutCorners:
        nearX and nearY
      of layoutPlus:
        (nearX and abs(dy2) <= 2 * gameMap.plusArmHalf()) or
          (nearY and abs(dx2) <= 2 * gameMap.plusArmHalf())
  if approach:
    return true
  if dx2 * dx2 + dy2 * dy2 <= 4 * gameMap.flagRing * gameMap.flagRing:
    return true
  for team in gameMap.teams():
    let
      anchor = gameMap.teamAnchor(team)
      half = gameMap.spawnPocketHalf(team)
    if abs(x - anchor.x) <= half.w and abs(y - anchor.y) <= half.h:
      return true
  false

proc mapWallAt*(
  gameMap: CtfMap,
  obstacles: seq[ArenaShape],
  x, y: int,
  includeSpinning = true,
  spin = spinRest
): bool =
  ## Uninstalled-map wall test, matching isArenaWall's border + carve rules.
  ## `includeSpinning = false` drops the live diamonds, which is what the art
  ## bake needs to see under them; `spin` picks which bound of the turn a
  ## spinning diamond presents, for validation that must hold at every frame.
  if x < ArenaBorder or y < ArenaBorder or
      x >= gameMap.width - ArenaBorder or y >= gameMap.height - ArenaBorder:
    return true
  if mapProtectedFloorAt(gameMap, x, y):
    return false
  for shape in obstacles:
    if gameMap.isSpinningDiamond(shape):
      if not includeSpinning:
        continue
      if spin != spinRest:
        let
          dx = x - shape.cx
          dy = y - shape.cy
          d2 = dx * dx + dy * dy
          r2 = shape.radius * shape.radius
        ## Two cheap circles bracket the answer: nothing outside the
        ## circumradius is ever stone, everything inside the inradius
        ## (2*d2 <= r2) is stone at every frame. Only the annulus between them
        ## depends on the angle, and there the sixteen frames are walked for
        ## real — the true intersection is a rosette strictly larger than the
        ## inscribed disc, and approximating it by that disc would reject maps
        ## whose lane is in fact blocked at every frame.
        if d2 > r2:
          continue
        if 2 * d2 <= r2:
          return true
        var everStone, alwaysStone = false
        alwaysStone = true
        for frame in 0 ..< DiamondSpinFrames:
          if rotatedDiamondCovers(shape.radius, frame, 2 * dx, 2 * dy, 2):
            everStone = true
          else:
            alwaysStone = false
        if (if spin == spinSwept: everStone else: alwaysStone):
          return true
        continue
    if inShape(x, y, shape):
      return true
  false

proc scaledGenShell4(sizeName: string): CtfMap =
  ## The 4-team field shell: a SQUARE board (rot90 symmetry needs one) with
  ## the standard clearances scaled by the same class factors as the 2-team
  ## shell. The standard side (960) splits the difference between the
  ## classic arena's width and height so the fight density stays familiar.
  let scale =
    case sizeName
    of "small": 0.85
    of "standard": 1.0
    of "large": 1.3
    else:
      raise newException(CtfError, "Unknown map size: " & sizeName)
  proc s(value: int): int = int(round(float(value) * scale))
  result.width = s(960)
  result.height = s(960)
  result.mapLayer = 0
  result.walkLayer = 1
  result.wallLayer = 2
  result.center = MapPoint(x: result.width div 2, y: result.height div 2)
  result.flagRing = s(70)
  result.captureClear = s(210)
  result.spawnClearW = s(70)
  result.spawnClearH = s(130)
  result.gunRange = s(1300)

proc rot90Orbit(p: tuple[x, y: int], side: int):
    array[4, tuple[x, y: int]] =
  ## The four images of one point under the rot90 symmetry group of a
  ## side x side square map, in team-orbit order (k = 0..3 quarter turns).
  var q = MapPoint(x: p.x, y: p.y)
  for k in 0 ..< 4:
    result[k] = (q.x, q.y)
    q = q.rot90Point(side)

proc sightlineLoX*(gameMap: CtfMap): int =
  ## The low x of the band no straight horizontal ray may cross unblocked.
  ## Column endzones exempt the protected home strips (nothing can be built
  ## there); a compact endzone makes those strips ordinary field, so the
  ## scan runs border to border.
  if gameMap.endzone != ezColumn: ArenaBorder + 5
  else: gameMap.captureClear + 5

proc sightlineHiX*(gameMap: CtfMap): int =
  ## The high x of that band, the mirror of sightlineLoX.
  if gameMap.endzone != ezColumn: gameMap.width - ArenaBorder - 5
  else: gameMap.width - gameMap.captureClear - 5

proc rectOnOpenFloor(
  gameMap: CtfMap, obstacles: seq[ArenaShape], rect: MapRect
): bool =
  ## Returns true when every pixel of the rectangle is walkable floor on an
  ## uninstalled candidate map. Sampled on a 3px grid — finer than the
  ## thinnest wall feature (12px) — with the far edge column and row always
  ## included, so no wall can slip past the samples on any side.
  var xs, ys: seq[int]
  var x = rect.x
  while x < rect.x + rect.w - 1:
    xs.add x
    x += 3
  xs.add rect.x + rect.w - 1
  var y = rect.y
  while y < rect.y + rect.h - 1:
    ys.add y
    y += 3
  ys.add rect.y + rect.h - 1
  for sy in ys:
    for sx in xs:
      if mapWallAt(gameMap, obstacles, sx, sy):
        return false
  true

proc generateMapAttempt*(
  seed: int, overrides: MapGenOverrides, teams = 2
): CtfMap =  ## One UNVALIDATED draw. Every top-level parameter is drawn unconditionally
  ## and THEN overridden if locked, so locking one knob never shifts the
  ## other draws for the same seed. `teams` selects the family: 2 draws the
  ## classic left/right half-map, 4 draws a square rot90 corner/plus map.
  doAssert teams in [2, 4], "team count must be 2 or 4"
  var rng = MapRng(state: uint64(seed))

  let sizeDraw = MapSizeNames[rng.pick(3)]
  let sizeName = if overrides.size.len > 0: overrides.size else: sizeDraw
  result =
    if teams == 4: scaledGenShell4(sizeName)
    else: scaledGenShell(sizeName)
  result.name = "gen-" & $seed
  result.path = GenMapName
  result.genSeed = seed

  if teams == 4:
    ## The symmetry draw keeps its slot in the draw order (locking layout
    ## must not shift later draws), but rot90 is the only 4-team symmetry —
    ## a config that locks another one is a mistake, not a preference.
    discard rng.coin()
    result.symmetry = symRot90
    if overrides.symmetry notin ["", "rot90"]:
      raise newException(
        CtfError, "4-team maps are rot90-only; got mapSymmetry: " &
          overrides.symmetry)
    let layoutDraw = if rng.coin(): layoutCorners else: layoutPlus
    result.layout =
      case overrides.layout
      of "": layoutDraw
      of "corners": layoutCorners
      of "plus": layoutPlus
      else:
        raise newException(
          CtfError, "Unknown map layout: " & overrides.layout)
  else:
    let symDraw = if rng.coin(): symRot180 else: symMirror
    result.symmetry =
      case overrides.symmetry
      of "": symDraw
      of "mirror": symMirror
      of "rot180": symRot180
      else:
        raise newException(
          CtfError, "Unknown map symmetry: " & overrides.symmetry)
    if overrides.layout.len > 0 and overrides.layout != "sides":
      raise newException(
        CtfError, "Map layout " & overrides.layout & " needs teams: 4.")

  ## Endzone archetype. Drawn from a SEPARATE stream keyed off the same seed
  ## so the main draw order never shifts: a seed that lands on the classic
  ## column generates the exact map it always did, byte for byte.
  block endzoneDraw:
    ## The compact knobs only mean anything on a compact endzone, and which
    ## shape a seed DRAWS is not something a config should have to guess:
    ## demand the shape lock alongside them rather than silently applying
    ## them on the seeds that happen to draw round.
    if (overrides.endzoneRadius > 0 or overrides.baseDepth > 0) and
        overrides.endzone notin ["disc", "square"]:
      raise newException(
        CtfError,
        "mapEndzoneRadius / mapBaseDepth need mapEndzone: disc or square.")
    var ezRng = MapRng(state: uint64(seed) xor 0x5A17E9D3C0FFEE11'u64)
    let shapeDraw =
      if teams == 4: ezColumn      ## 4-team layouts own their own geometry.
      else:
        case ezRng.pick(4)
        of 0, 1: ezColumn          ## half the pool stays the classic arena.
        of 2: ezDisc
        else: ezSquare
    result.endzone =
      case overrides.endzone
      of "": shapeDraw
      of "column": ezColumn
      of "disc": ezDisc
      of "square": ezSquare
      else:
        raise newException(
          CtfError, "Unknown map endzone: " & overrides.endzone)
    if result.endzone == ezColumn:
      ## A column endzone is pinned to the home border by `captureClear`, so
      ## its base cannot move: the threshold would slide out of the protected
      ## column and carriers would score on ordinary terrain.
      result.homeDepth = ClassicHomeDepth
      break endzoneDraw
    if teams == 4:
      raise newException(
        CtfError, "Compact endzones (mapEndzone) need a 2-team map.")
    ## Compact endzones pull the base well off its edge — the strip behind it
    ## becomes wilderness — and wrap it in a scoring shape whose radius
    ## scales with the size class exactly like every other clearance.
    let
      depthDraw = ezRng.pickRange(520, 620)
      radiusDraw = result.width * ezRng.pickRange(110, 140) div 1235
    result.homeDepth =
      if overrides.baseDepth > 0: overrides.baseDepth else: depthDraw
    result.endzoneRadius =
      if overrides.endzoneRadius > 0: overrides.endzoneRadius else: radiusDraw
    if result.homeDepth < HomeDepthMin or result.homeDepth > HomeDepthMax:
      raise newException(
        CtfError, "Config field mapBaseDepth must be " & $HomeDepthMin &
          ".." & $HomeDepthMax & ".")
    if result.endzoneRadius < EndzoneRadiusMin or
        result.endzoneRadius > EndzoneRadiusMax:
      raise newException(
        CtfError, "Config field mapEndzoneRadius must be " &
          $EndzoneRadiusMin & ".." & $EndzoneRadiusMax & ".")
  result.rooms = result.defaultCtfRooms()

  let featureDraw = CenterFeatureNames[rng.pick(3)]
  let feature =
    if overrides.centerFeature.len > 0: overrides.centerFeature
    else: featureDraw
  if feature notin CenterFeatureNames:
    raise newException(CtfError, "Unknown map center feature: " & feature)

  ## Compact-endzone maps spread their columns over the whole half-field
  ## (the home border strip is wilderness now, not a protected column), so
  ## they draw MORE of them to hold the same field density. Same single draw
  ## either way — the RNG stream never shifts.
  let columnsDraw =
    if teams == 4: rng.pickRange(3, 4)
    elif result.endzone != ezColumn: rng.pickRange(6, 8)
    else: rng.pickRange(4, 6)
  let columns =
    if overrides.columns > 0: overrides.columns else: columnsDraw
  if columns < 3 or columns > 8:
    raise newException(CtfError, "Config field mapColumns must be 3..8.")

  let
    cy = result.center.y
    redAnchorX = result.teamHomeX(Red)
    ## Obstacle columns live between the home approach and the flag-ring
    ## flank; the ring and the endzones carve any overlap back out of the
    ## wall mask. A compact endzone frees the border strip, so the columns
    ## start just inside the wall and terrain wraps the base on every side.
    xMin =
      if result.endzone != ezColumn: ArenaBorder + 34
      else: result.captureClear + 50
    xMax = result.center.x - 52
    ## The vertical band the column slots may occupy: the full field on
    ## sides maps, the top-left quadrant on corner maps (rot90 fills the
    ## rest), the west arm on plus maps (the corner blocks own the rest).
    slotBand =
      case result.layout
      of layoutSides:
        (lo: ArenaBorder + 30, hi: result.height - ArenaBorder - 30)
      of layoutCorners, layoutPlus:
        ## The full quadrant, crossing the centerline: the rot90 images
        ## fill the other side, and slots near cy are what covers the
        ## central horizontal band. Both 4-team layouts are fully open
        ## square boards — they differ only in where the teams live.
        (lo: ArenaBorder + 30, hi: cy + 60)
  ## Window-eligible shapes: (obstacle index, column, slot y).
  var eligible: seq[tuple[idx, col, y: int]]
  ## Trench pit candidates, resolved into actual digs after the columns
  ## exist: `instead` swaps its obstacle for a pit, `gap` sits in a
  ## cleared slot's corridor, `endzone` hugs the pedestal.
  const
    pitInstead = 0
    pitGap = 1
    pitEndzone = 2
  var pitCandidates: seq[tuple[kind, obstacleIdx, x, y: int]]

  for col in 0 ..< columns:
    let
      colX = xMin + ((2 * col + 1) * (xMax - xMin)) div (2 * columns)
      family = ColumnFamily(rng.pick(4))
      ## 4-team quadrant shapes replicate x4 (not x2), so slots spread out
      ## to keep the same field density.
      period =
        if teams == 4: rng.pickRange(130, 180)
        else: rng.pickRange(88, 120)
      ## Phases are STRATIFIED across columns (like the hand-authored
      ## arena's 0/+48/+24/+72 ladder) with a half-period jitter: fully
      ## random phases leave rows every column misses, which the sightline
      ## validator rejects — mirror-symmetric maps almost never survived.
      phase = (period * col div columns +
        rng.pick(max(1, period div 2))) mod period
    var slotYs: seq[int]
    var slotY = slotBand.lo + phase
    while slotY <= slotBand.hi:
      slotYs.add slotY
      slotY += period
    if slotYs.len < (if result.layout == layoutSides: 3 else: 2):
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
      ## Compact endzones keep an APRON of clear ground outside the ring:
      ## terrain that crowded the scoring shape would seal the very
      ## approaches that make an off-the-edge base worth building, and the
      ## open-flank validator would reject the map anyway. Obstacle centers
      ## reach ~30px, so an apron of radius + 60 leaves every cardinal gate
      ## a full corridor's clearance.
      if result.endzone != ezColumn and
          endzoneFloorAt(colX, sy, redAnchorX, cy,
            result.endzoneRadius + 60 - EndzoneWallMargin,
            result.endzone == ezDisc):
        continue
      if cleared[i]:
        ## A cleared gap can hold a dug pit BETWEEN the column's obstacles
        ## — the corridor stays open to movement and fire.
        pitCandidates.add (pitGap, -1, colX, sy)
        continue
      ## Every kept slot can dig a trench INSTEAD of raising its obstacle
      ## — cover you stand in rather than behind. Selection below decides;
      ## the sightline repair and the validators judge the thinner wall
      ## set exactly as usual.
      pitCandidates.add (pitInstead, result.leftObstacles.len, colX, sy)
      case family
      of colStubs:
        ## Stub ends whose border gap would drop under the corridor minimum
        ## anchor to the border instead — a sub-26px slit is impassable
        ## anyway and reads as a wart.
        var top = sy - 30
        var bottom = sy + 30
        if i == 0 and top - ArenaBorder < MinCorridorWidth:
          top = ArenaBorder
        if i == slotYs.len - 1 and result.layout == layoutSides and
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

  ## Endzone trench pit candidates, authored on the RED side (the symmetry
  ## image gives Blue the exact counterpart): BEHIND the pedestal toward
  ## the home edge, and ABOVE and BELOW it — each clear of the pedestal
  ## art. Endzone floor is protected (never walled), so endzone digs
  ## always survive the open-floor prune below.
  let
    redHomeX = redAnchorX
    pedestalClear = PedestalCoverSize div 2 + TrenchSize div 2
    ## How far off the pedestal an endzone dig sits. Column endzones have the
    ## whole home strip to work with; a COMPACT zone clamps the offset so the
    ## pit stays on its protected floor (clear of the pedestal art at the
    ## floor, inside the ring at the ceiling) instead of being pruned later.
    compactPitOffset =
      max(pedestalClear,
        min(pedestalClear + 20,
          result.endzoneRadius - TrenchSize div 2 - EndzoneWallMargin))
    backOffset =
      if result.endzone == ezColumn: pedestalClear + 12
      else: compactPitOffset
    sideOffset =
      if result.endzone == ezColumn: pedestalClear + 20
      else: compactPitOffset
  pitCandidates.add (pitEndzone, -1, redHomeX - backOffset, cy)
  pitCandidates.add (pitEndzone, -1, redHomeX, cy - sideOffset)
  pitCandidates.add (pitEndzone, -1, redHomeX, cy + sideOffset)

  ## Pit selection. DENSITY mode (default) rolls every candidate at its
  ## class chance scaled by pitDensity percent. COUNT mode (pits locked)
  ## shuffles the candidates and takes symmetric pairs until the requested
  ## total is met — an ODD total anchors its extra pit at the exact map
  ## center, the one spot that is its own image under mirror AND rot180,
  ## so both parities stay exactly team-fair.
  if overrides.pits < -1 or overrides.pits > 64:
    raise newException(CtfError, "Config field mapPits must be 0..64.")
  if overrides.pitDensity < -1 or overrides.pitDensity > 1000:
    raise newException(
      CtfError, "Config field mapPitDensity must be 0..1000.")
  let
    pitDensity = if overrides.pitDensity >= 0: overrides.pitDensity else: 100
    centerPit = trenchSquareAt(result.center.x, result.center.y)
    oddCenterPit = overrides.pits >= 0 and overrides.pits mod 2 == 1
    pitPairsWanted = if overrides.pits >= 0: overrides.pits div 2 else: -1
  var obstacleRemoved = newSeq[bool](result.leftObstacles.len)
  if result.symmetry == symRot90:
    ## Trenches are a 2-team-map feature for now: the dig/image pair
    ## accounting assumes one symmetry image per dig, and rot90 maps have
    ## three. An explicit pit request errors; the density path digs nothing
    ## (clearing the candidates keeps the loop from writing UNPAIRED digs
    ## into result.trenches — finalize is what pairs them, and it is
    ## skipped on rot90).
    if overrides.pits > 0:
      raise newException(
        CtfError, "Trenches are not supported on 4-team maps yet.")
    pitCandidates.setLen(0)
  if pitPairsWanted >= 0:
    rng.shuffle(pitCandidates)
  for cand in pitCandidates:
    if pitPairsWanted >= 0:
      if result.trenches.len >= pitPairsWanted:
        break
    else:
      let baseChance =
        case cand.kind
        of pitInstead: 17
        of pitGap: 25
        else: 50
      if rng.pick(100) >= clamp(baseChance * pitDensity div 100, 0, 100):
        continue
    let pit = trenchSquareAt(cand.x, cand.y)
    var blocked = oddCenterPit and rectsIntersect(pit, centerPit)
    for accepted in result.trenches:
      if rectsIntersect(accepted, pit):
        blocked = true
        break
    if blocked:
      continue
    result.trenches.add pit
    if cand.kind == pitInstead:
      obstacleRemoved[cand.obstacleIdx] = true

  ## Swap the chosen `instead` obstacles out of the wall set. Window
  ## eligibility indexes leftObstacles, so compact both together.
  block removeSwappedObstacles:
    var remap = newSeq[int](result.leftObstacles.len)
    var compacted: seq[ArenaShape]
    for i, shape in result.leftObstacles:
      if obstacleRemoved[i]:
        remap[i] = -1
      else:
        remap[i] = compacted.len
        compacted.add shape
    result.leftObstacles = compacted
    var remappedEligible: seq[tuple[idx, col, y: int]]
    for entry in eligible:
      if remap[entry.idx] >= 0:
        remappedEligible.add (remap[entry.idx], entry.col, entry.y)
    eligible = remappedEligible

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
      for x in gameMap.sightlineLoX .. gameMap.center.x:
        if mapWallAt(gameMap, gameMap.leftObstacles, x, y):
          return true
      false
    proc rowBlockedFull(gameMap: CtfMap, obstacles: seq[ArenaShape],
        y: int): bool =
      ## Full-width row scan against the COMPLETE symmetry-expanded set —
      ## rot90 folds a quadrant into all four quarters, so no single-half
      ## shortcut exists.
      for x in gameMap.sightlineLoX .. gameMap.sightlineHiX:
        if mapWallAt(gameMap, obstacles, x, y):
          return true
      false
    var plugsLeft = 40
    while plugsLeft > 0:
      var uncovered = -1
      let fullSet =
        if result.symmetry == symRot90: buildArenaObstacles(result)
        else: @[]
      var y = ArenaBorder + 2
      while y < result.height - ArenaBorder:
        let covered =
          case result.symmetry
          of symMirror:
            result.rowBlocked(y)
          of symRot180:
            result.rowBlocked(y) or
              result.rowBlocked(result.height - 1 - y)
          of symRot90:
            result.rowBlockedFull(fullSet, y)
        if not covered:
          uncovered = y
          break
        y += 4
      if uncovered < 0:
        break sightlineRepair
      let
        plugCol = rng.pick(columns)
        plugX = xMin + ((2 * plugCol + 1) * (xMax - xMin)) div (2 * columns)
        ## Under rot90 a quadrant shape at row y also covers row H-1-y (its
        ## rot180 image), so an uncovered bottom-half row folds to its top
        ## reflection before plugging; plugs may sit close to the border.
        foldedRow =
          if result.symmetry == symRot90 and uncovered > cy:
            result.height - 1 - uncovered
          else:
            uncovered
        plugY = clamp(
          foldedRow + 24, ArenaBorder + 12, result.height - ArenaBorder - 12)
      dec plugsLeft
      ## A plug inside the endzone apron would seal an approach (and be
      ## carved to a stump by the protected floor anyway); skip it and let
      ## the next iteration try another column for the same row.
      if result.endzone != ezColumn and
          endzoneFloorAt(plugX, plugY, redAnchorX, cy,
            result.endzoneRadius + 60 - EndzoneWallMargin,
            result.endzone == ezDisc):
        continue
      result.leftObstacles.add ArenaShape(
        kind: shapeDiamond, cx: plugX, cy: plugY, radius: 28)

  ## Glass windows: fog sees through them, nothing passes them. Biased to
  ## the outermost column and the midline band, where sightlines matter.
  let windowsDraw =
    if teams == 4: rng.pickRange(1, 2)
    else: rng.pickRange(2, 4)
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

  ## Med kits. Sides maps: two complementary (y, H-1-y) center-line pairs
  ## are drawn as candidates and ONE pair goes active — a top/bottom pair on
  ## x = W/2 is invariant under both mirror and rot180, so pickup fairness
  ## is exact. 4-team maps: one kit per team as the rot90 orbit of a single
  ## drawn ring point, which is fair by the same symmetry argument.
  if teams == 4:
    let
      ringLo = result.flagRing + 40
      ringHi = result.center.x - result.captureClear - 60
      d = rng.pickRange(ringLo, max(ringLo + 1, ringHi))
      orbit = rot90Orbit((result.center.x + d, result.center.y), result.width)
    result.medKitCandidates = @[]
    for point in orbit:
      result.medKitCandidates.add MapPoint(x: point.x, y: point.y)
    result.medKitSpawns = result.medKitCandidates
  else:
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

  ## Finalize the trenches. Every left-half dig gets its image under
  ## the map's symmetry so neither team has a private pit; a dig that ended
  ## up under a wall (a sightline-repair plug can land on its slot) or on
  ## top of an already-accepted dig is dropped — and a dig whose image is
  ## blocked drops WITH it, fairness before density. (rot90 maps reach
  ## here with zero candidates and place nothing — see the guard above.)
  block finalizeTrenches:
    let obstacles = buildArenaObstacles(result)
    var digs: seq[MapRect]
    if oddCenterPit:
      ## The odd pit sits dead center, inside the always-open flag ring.
      digs.add centerPit
    proc addPair(
      gameMap: CtfMap, digs: var seq[MapRect], trench: MapRect
    ): bool =
      ## Accepts one left-half dig plus its symmetry image when both sit
      ## on open floor clear of every accepted dig. Count-mode parity
      ## rests on every candidate being distinct from its own image —
      ## true because column candidates cap at center.x - 52 and endzone
      ## candidates hug the red home; a future center-adjacent candidate
      ## class would break the exact-count accounting here.
      let image =
        case gameMap.symmetry
        of symMirror: trench.mirrorX(gameMap.width)
        of symRot180: trench.rot180(gameMap.width, gameMap.height)
        of symRot90: raiseAssert "trenches never place on rot90 maps"
      if not rectOnOpenFloor(gameMap, obstacles, trench) or
          not rectOnOpenFloor(gameMap, obstacles, image):
        return false
      for accepted in digs:
        if rectsIntersect(accepted, trench) or
            rectsIntersect(accepted, image):
          return false
      digs.add trench
      if image != trench:
        digs.add image
      true
    for trench in result.trenches:
      discard result.addPair(digs, trench)
    ## COUNT mode: pairs lost to sightline-repair walls are topped back up
    ## from the unused candidates that cannot change the wall set (gap and
    ## endzone spots; a late `instead` swap would dodge the repair pass).
    if pitPairsWanted >= 0:
      for cand in pitCandidates:
        if digs.len >= overrides.pits:
          break
        if cand.kind == pitInstead:
          continue
        discard result.addPair(digs, trenchSquareAt(cand.x, cand.y))
    result.trenches = digs
  result.validateMap()

proc validateGeneratedMap*(gameMap: CtfMap): string =
  ## Returns "" when the layout passes every play-quality invariant, else a
  ## human-readable failure reason. The generator's design intent lives HERE,
  ## not in the draws: anything that passes is fair game.
  let
    w = gameMap.width
    h = gameMap.height
    obstacles = buildArenaObstacles(gameMap)
  ## A spinning diamond is not one shape, so validation cannot use one mask:
  ## these invariants point in OPPOSITE directions (GV29).
  ##   maxWall — the swept union. Use it where MORE wall is the pessimistic
  ##     case: a corridor that closes at any frame is not a corridor, and a
  ##     map that is too clogged at any frame is too clogged.
  ##   minWall — the intersection over the turn, stone at every frame. Use it
  ##     where LESS wall is pessimistic: a firing lane that opens at any frame
  ##     is an open lane, and cover that comes and goes cannot prop up the
  ##     cover floor.
  ## A sightline checked against the swept mask would let a map ship with a
  ## cross-map lane that opens on a clock: the diamonds reach 29 px along an
  ## axis at rest but only 20 px a third of a turn later, while the swept disc
  ## claims 30 px at all times. Two seeds in the pre-GV29 pool had exactly
  ## that defect, which is why the pool was re-curated with this change.
  var
    maxWall = newSeq[bool](w * h)
    minWall = newSeq[bool](w * h)
  var minCoverPixels, coverPixels, interiorPixels = 0
  for y in 0 ..< h:
    for x in 0 ..< w:
      let
        isWall = mapWallAt(gameMap, obstacles, x, y, spin = spinSwept)
        isAlwaysWall =
          mapWallAt(gameMap, obstacles, x, y, spin = spinAlways)
      maxWall[y * w + x] = isWall
      minWall[y * w + x] = isAlwaysWall
      ## The cover-budget interior. Sides maps keep the historical x-band
      ## definition EXACTLY (the curated pool seeds validate first-attempt
      ## against it). 4-team layouts measure the actually-playable field:
      ## everything inside the border that is not protected floor.
      let interior =
        if gameMap.endzone != ezColumn:
          ## Compact endzones: the same "everything playable" measure the
          ## 4-team layouts use — the wilderness behind the bases is field
          ## and must carry its share of the cover budget.
          x >= ArenaBorder and x < w - ArenaBorder and
            y >= ArenaBorder and y < h - ArenaBorder and
            not mapProtectedFloorAt(gameMap, x, y)
        else:
          case gameMap.layout
          of layoutSides:
            x >= gameMap.captureClear and x < w - gameMap.captureClear and
              y >= ArenaBorder and y < h - ArenaBorder
          of layoutCorners, layoutPlus:
            x >= ArenaBorder and x < w - ArenaBorder and
              y >= ArenaBorder and y < h - ArenaBorder and
              not mapProtectedFloorAt(gameMap, x, y)
      if interior:
        inc interiorPixels
        if isWall:
          inc coverPixels
        if isAlwaysWall:
          inc minCoverPixels

  ## Cover budget: neither an open field nor a clogged maze — at EVERY frame,
  ## so the floor is measured on the cover that is always there and the
  ## ceiling on the cover that is ever there.
  let
    permille = coverPixels * 1000 div max(1, interiorPixels)
    minPermille = minCoverPixels * 1000 div max(1, interiorPixels)
  if minPermille < CoverPermilleMin:
    return "too open: " & $minPermille & " permille cover"
  if permille > CoverPermilleMax:
    return "too clogged: " & $permille & " permille cover"

  ## With map-wide guns no straight horizontal ray may survive between the
  ## capture columns (the property tests/test_map_los.nim pins for arena).
  block sightlines:
    let
      ax = gameMap.sightlineLoX
      bx = gameMap.sightlineHiX
    var y = ArenaBorder + 2
    while y < h - ArenaBorder:
      var blocked = false
      for x in ax .. bx:
        if minWall[y * w + x]:
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
    dist[i] = if maxWall[i]: 0'i32 else: int32.high div 2
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
  for team in gameMap.teams():
    if team == Red:
      continue
    let home = gameMap.flagHome(team)
    if not reached[home.y * w + home.x]:
      return
        if gameMap.teamCount() == 2:
          "no " & $MinCorridorWidth & "px route between the flags"
        else:
          "no " & $MinCorridorWidth & "px route to the " &
            teamText(team) & " flag"
  if not reached[gameMap.center.y * w + gameMap.center.x]:
    return "no " & $MinCorridorWidth & "px route to the center"

  ## Compact endzones must stay OPEN-FLANKED: a base you can only be reached
  ## from the field side is just a column endzone with extra steps. Checked
  ## on Red alone — mirror and rot180 hand Blue the exact image.
  if gameMap.endzone != ezColumn:
    let
      anchor = gameMap.teamAnchor(Red)
      gate = gameMap.endzoneRadius + MinCorridorWidth div 2 + 4
      gates = [
        (name: "behind", x: anchor.x - gate, y: anchor.y),
        (name: "above", x: anchor.x, y: anchor.y - gate),
        (name: "below", x: anchor.x, y: anchor.y + gate),
        (name: "ahead", x: anchor.x + gate, y: anchor.y),
      ]
    for g in gates:
      if g.x < 0 or g.y < 0 or g.x >= w or g.y >= h:
        return "endzone gate " & g.name & " is off the map"
      if not reached[g.y * w + g.x]:
        return "endzone gate " & g.name & " is sealed"

    ## ...and the way in from behind must not run THROUGH the endzone: fill
    ## from the rear gate with the zone itself forbidden and demand the
    ## center. That is the whole point of moving the base off the edge.
    let zone = gameMap.captureZone(Red)
    var
      around = newSeq[bool](w * h)
      backQueue = @[gates[0].y * w + gates[0].x]
    around[backQueue[0]] = true
    head = 0
    while head < backQueue.len:
      let i = backQueue[head]
      inc head
      for step in [-1, 1, -w, w]:
        let j = i + step
        if j < 0 or j >= w * h or not open[j] or around[j]:
          continue
        if zone.inCaptureZone(j mod w, j div w):
          continue
        around[j] = true
        backQueue.add j
    if not around[gameMap.center.y * w + gameMap.center.x]:
      return "no route around the endzone from behind the base"
  ""

proc generateCtfMap*(
  seed: int,
  overrides = MapGenOverrides(windows: -1, pits: -1, pitDensity: -1),
  teams = 2
): CtfMap =
  ## Generates a VALIDATED map: attempts seeds seed, seed+1, ... until one
  ## passes every validator. A locked-parameter combination that can never
  ## pass errors out after MapGenMaxAttempts.
  for attempt in 0 ..< MapGenMaxAttempts:
    let candidate = generateMapAttempt(seed + attempt, overrides, teams)
    if validateGeneratedMap(candidate).len == 0:
      return candidate
  raise newException(
    CtfError,
    "Map generation found no valid layout in " & $MapGenMaxAttempts &
      " attempts from seed " & $seed & " (over-constrained overrides?)."
  )

proc poolCtfMap*(
  index: int, overrides = MapGenOverrides(windows: -1, pits: -1, pitDensity: -1)
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

proc rectsNode(rects: seq[MapRect]): JsonNode =
  result = newJArray()
  for r in rects:
    result.add %*[r.x, r.y, r.w, r.h]

proc rectsFromNode(node: JsonNode): seq[MapRect] =
  if node.isNil or node.kind != JArray:
    return
  for item in node:
    result.add MapRect(
      x: item[0].getInt(), y: item[1].getInt(),
      w: item[2].getInt(), h: item[3].getInt()
    )

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
      case gameMap.symmetry
      of symMirror: "mirror"
      of symRot180: "rot180"
      of symRot90: "rot90"),
    "layout": (
      case gameMap.layout
      of layoutSides: "sides"
      of layoutCorners: "corners"
      of layoutPlus: "plus"),
    "endzone": (
      case gameMap.endzone
      of ezColumn: "column"
      of ezDisc: "disc"
      of ezSquare: "square"),
    "endzoneRadius": gameMap.endzoneRadius,
    "homeDepth": gameMap.homeDepthOf(),
    "medKitSpawns": pointsNode(gameMap.medKitSpawns),
    "medKitCandidates": pointsNode(gameMap.medKitCandidates),
    # Trenches are FULL-map (both halves), already symmetrized — playback
    # re-reads them verbatim, no re-mirroring.
    "trenches": rectsNode(gameMap.trenches),
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
  ## Missing keys default for pre-4-team pinned specs; an unknown NON-EMPTY
  ## value is a typo or a spec from a future version — replays pin specs
  ## precisely so playback is exact, so silently reinterpreting one would
  ## defeat the point. Raise instead.
  let symmetryText = node{"symmetry"}.getStr("mirror")
  result.symmetry =
    case symmetryText
    of "mirror": symMirror
    of "rot180": symRot180
    of "rot90": symRot90
    else:
      raise newException(
        CtfError, "Unknown map spec symmetry: " & symmetryText)
  let layoutText = node{"layout"}.getStr("sides")
  result.layout =
    case layoutText
    of "sides": layoutSides
    of "corners": layoutCorners
    of "plus": layoutPlus
    else:
      raise newException(CtfError, "Unknown map spec layout: " & layoutText)
  let endzoneText = node{"endzone"}.getStr("column")
  result.endzone =
    case endzoneText
    of "column": ezColumn
    of "disc": ezDisc
    of "square": ezSquare
    else:
      raise newException(CtfError, "Unknown map spec endzone: " & endzoneText)
  result.endzoneRadius = node{"endzoneRadius"}.getInt(0)
  result.homeDepth = node{"homeDepth"}.getInt(ClassicHomeDepth)
  result.medKitSpawns = pointsFromNode(node["medKitSpawns"])
  result.medKitCandidates = pointsFromNode(node["medKitCandidates"])
  ## Optional: specs pinned before trenches existed carry none and replay
  ## without them, exactly as recorded.
  result.trenches = rectsFromNode(node{"trenches"})
  for item in node["leftObstacles"]:
    result.leftObstacles.add item.shapeFromSpecNode()
  result.rooms = result.defaultCtfRooms()
  result.validateMap()

proc resolveCtfMapMetadata*(config: GameConfig): CtfMap =
  ## The effective map for one config: an explicit mapSpec wins (replay
  ## exactness), then the named maps, then the generator / curated pool.
  ## The resolved map's team count must match the config's `teams` knob —
  ## a 4-team game needs a generated corner/plus map (or a pinned spec).
  result =
    if config.mapSpec.len > 0:
      mapFromSpecJson(config.mapSpec)
    else:
      let
        name = if config.mapPath.len == 0: DefaultMapPath else: config.mapPath
        genSeed = if config.mapSeed != -1: config.mapSeed else: config.seed
      case name
      of ArenaName: arenaCtfMap()
      of ArenaLargeName: arenaLargeCtfMap()
      of GenMapName: generateCtfMap(genSeed, config.mapGen, config.teams)
      of PoolMapName:
        if config.teams != 2:
          raise newException(
            CtfError, "The curated pool is 2-team; use mapPath gen for " &
              $config.teams & " teams.")
        let index =
          if config.mapPoolIndex >= 0: config.mapPoolIndex else: genSeed
        poolCtfMap(index, config.mapGen)
      else:
        raise newException(CtfError, "Unknown map: " & name)
  if result.teamCount() != config.teams:
    raise newException(
      CtfError, "Config asks for " & $config.teams & " teams but map " &
        result.name & " seats " & $result.teamCount() & ".")

## The SELECTED map's layout, installed once per process by loadCtfMap and
## initialized to the default arena below so tooling that never selects a
## map observes a complete default state, never an empty one.
var
  ArenaFlagRing = 70
  ArenaCaptureClear = 210
  ArenaLayoutG = layoutSides
  ArenaSymmetryG = symMirror
  ArenaTeamCount = 2
  ArenaAnchors: array[Team, MapPoint]
  ArenaPocketHalf: array[Team, tuple[w, h: int]]
  ArenaPlusArmHalf = 0
  ArenaEndzoneRadius = 0     ## > 0 selects the COMPACT endzone floor rules.
  ArenaEndzoneDisc = false   ## compact endzone is a disc, not a square.
  ArenaObstacles*: seq[ArenaShape]
  AnimatedDiamonds*: seq[tuple[cx, cy, radius: int]]
  ArenaSpinMirrored* = true
    ## True when this map's symmetry is a REFLECTION, so mirror-image diamonds
    ## must spin in opposite directions. False on rotationally symmetric maps
    ## (rot180 / rot90), where every diamond turns together — see
    ## diamondSpinFrame.
  ArenaTrenches*: seq[MapRect]

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
  ArenaLayoutG = gameMap.layout
  ArenaSymmetryG = gameMap.symmetry
  ArenaTeamCount = gameMap.teamCount()
  for team in gameMap.teams():
    ArenaAnchors[team] = gameMap.teamAnchor(team)
    ArenaPocketHalf[team] = gameMap.spawnPocketHalf(team)
  ArenaPlusArmHalf = gameMap.plusArmHalf()
  ArenaEndzoneRadius =
    if gameMap.endzone == ezColumn: 0 else: gameMap.endzoneRadius
  ArenaEndzoneDisc = gameMap.endzone == ezDisc
  ArenaObstacles = buildArenaObstacles(gameMap)
  AnimatedDiamonds = buildAnimatedDiamonds(gameMap, ArenaObstacles)
  ArenaSpinMirrored = gameMap.symmetry == symMirror
  ArenaTrenches = gameMap.trenches

selectCtfMap(arenaCtfMap())

proc loadCtfMapMetadata*(path = ""): CtfMap =
  ## Returns one map's metadata WITHOUT installing it as the process map.
  ## Accepts "arena", "arena-large", "gen[:seed]", and "pool[:index]" (the
  ## suffix-less generated forms use seed/index 0); tooling convenience —
  ## servers resolve through the GameConfig overload instead.
  let name = if path.len == 0: DefaultMapPath else: path
  case name
  of ArenaName: arenaCtfMap()
  of ArenaLargeName: arenaLargeCtfMap()
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

proc trenchIndexAt*(x, y: int): int =
  ## Returns the index of the trench containing map pixel (x, y), or -1 when
  ## the point is in the open field.
  for i, trench in ArenaTrenches:
    if inRect(x, y, trench):
      return i
  -1

proc playerTrench*(sim: SimServer, playerIndex: int): int =
  ## Returns the index of the trench the player's center is standing in,
  ## or -1 in the open field. Occupancy is instantaneous: the slowdowns and
  ## the fly-over shot misses apply exactly while the center is inside.
  trenchIndexAt(
    sim.players[playerIndex].x + CollisionW div 2,
    sim.players[playerIndex].y + CollisionH div 2
  )

proc isAnimatedDiamondPixel*(x, y: int): bool =
  ## Returns true when (x, y) lies inside one of the rotating center diamonds
  ## at rest (frame 0). This is the BAKE-TIME predicate: it tells the art and
  ## the collision bake which pixels to leave empty because the live shape is
  ## stamped per frame instead. For "is this stone right now", ask the wall
  ## mask (or animatedDiamondCovers with the tick's frame).
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

proc arenaCenterOffset2(x, y, cx, cy: int): tuple[dx, dy: int] {.inline.} =
  ## The installed-map twin of CtfMap.centerOffset2: twice the offset from
  ## the symmetry center, measured against a rot90 board's true axis at
  ## (side - 1)/2 and against the integer center everywhere else.
  if ArenaSymmetryG == symRot90:
    (2 * x - (MapWidth - 1), 2 * y - (MapHeight - 1))
  else:
    (2 * (x - cx), 2 * (y - cy))

proc isProtectedFloor(x, y, cx, cy: int): bool =
  ## Regions that MUST stay walkable: the flag ring, every spawn pocket,
  ## and each team's home capture approach. Walls are never carved here.
  if ArenaEndzoneRadius > 0:
    ## COMPACT endzones: the shape around each base plus the center ring.
    ## The home border strips are ordinary field (see mapProtectedFloorAt).
    for team in activeTeams(ArenaTeamCount):
      if endzoneFloorAt(x, y, ArenaAnchors[team].x, ArenaAnchors[team].y,
          ArenaEndzoneRadius, ArenaEndzoneDisc):
        return true
    let
      rdx = x - cx
      rdy = y - cy
    return rdx * rdx + rdy * rdy <= ArenaFlagRing * ArenaFlagRing
  ## The classic column path below must stay pixel-for-pixel identical to
  ## mapProtectedFloorAt, which the generator and validators run on
  ## uninstalled candidates. 4-team maps always draw ezColumn, so the rot90
  ## boards are carved here and never by the compact branch above.
  let
    nearX = x < ArenaCaptureClear or x >= MapWidth - ArenaCaptureClear
    nearY = y < ArenaCaptureClear or y >= MapHeight - ArenaCaptureClear
    (dx2, dy2) = arenaCenterOffset2(x, y, cx, cy)
    approach =
      case ArenaLayoutG
      of layoutSides:
        nearX
      of layoutCorners:
        nearX and nearY
      of layoutPlus:
        (nearX and abs(dy2) <= 2 * ArenaPlusArmHalf) or
          (nearY and abs(dx2) <= 2 * ArenaPlusArmHalf)
  if approach:
    return true
  if dx2 * dx2 + dy2 * dy2 <= 4 * ArenaFlagRing * ArenaFlagRing:
    return true
  for team in activeTeams(ArenaTeamCount):
    if abs(x - ArenaAnchors[team].x) <= ArenaPocketHalf[team].w and
        abs(y - ArenaAnchors[team].y) <= ArenaPocketHalf[team].h:
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
  if ArenaEndzoneRadius > 0:
    let grown = float(ArenaEndzoneRadius + EndzoneWallMargin)
    for team in activeTeams(ArenaTeamCount):
      let
        adx = abs(x - float(ArenaAnchors[team].x))
        ady = abs(y - float(ArenaAnchors[team].y))
      if adx > grown or ady > grown:
        continue
      if not ArenaEndzoneDisc or adx * adx + ady * ady <= grown * grown:
        return true
    let
      rdx = x - float(cx)
      rdy = y - float(cy)
    return rdx * rdx + rdy * rdy <= float(ArenaFlagRing * ArenaFlagRing)
  ## Carries the same doubled-coordinate center as the integer test so the
  ## painted art cannot drift off the collision mask on a rot90 board.
  let
    nearX = x < float(ArenaCaptureClear) or
      x >= float(MapWidth - ArenaCaptureClear)
    nearY = y < float(ArenaCaptureClear) or
      y >= float(MapHeight - ArenaCaptureClear)
    (dx2, dy2) =
      if ArenaSymmetryG == symRot90:
        (2.0 * x - float(MapWidth - 1), 2.0 * y - float(MapHeight - 1))
      else:
        (2.0 * (x - float(cx)), 2.0 * (y - float(cy)))
    approach =
      case ArenaLayoutG
      of layoutSides:
        nearX
      of layoutCorners:
        nearX and nearY
      of layoutPlus:
        (nearX and abs(dy2) <= float(2 * ArenaPlusArmHalf)) or
          (nearY and abs(dx2) <= float(2 * ArenaPlusArmHalf))
  if approach:
    return true
  if dx2 * dx2 + dy2 * dy2 <= float(4 * ArenaFlagRing * ArenaFlagRing):
    return true
  for team in activeTeams(ArenaTeamCount):
    let half = ArenaPocketHalf[team]
    if abs(x - float(ArenaAnchors[team].x)) <= float(half.w) and
        abs(y - float(ArenaAnchors[team].y)) <= float(half.h):
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

const
  TrenchBevelPx = 8                          ## width of the pit's inner
                                             ## shadow bevel, px.
  TrenchLipColor = rgba(30, 22, 12, 255)     ## crisp dark cut line around
                                             ## the pit lip.
  TrenchLipAlpha = 185                       ## shadow strength at the lip...
  TrenchFloorAlpha = 95                      ## ...easing to this over the
                                             ## bevel and holding on the pit
                                             ## floor.

proc trenchArtColorAt(base: ColorRGBA, x, y: int): ColorRGBA =
  ## Returns the floor color with the trench art applied at logical (x, y):
  ## a dug pit — a crisp dark lip line on the square's edge, an inner shadow
  ## bevel easing down from the lip, and a uniformly darkened sunken floor,
  ## so the recess reads at a glance. Cosmetic only — the collision masks
  ## never see trenches, and the art is axis-aligned so it upscales crisply
  ## at any render scale.
  let t = trenchIndexAt(x, y)
  if t < 0:
    return base
  let
    trench = ArenaTrenches[t]
    edge = min(
      min(x - trench.x, trench.x + trench.w - 1 - x),
      min(y - trench.y, trench.y + trench.h - 1 - y)
    )
  if edge == 0:
    return TrenchLipColor
  let
    depth = min(edge, TrenchBevelPx)
    alpha = TrenchLipAlpha -
      (TrenchLipAlpha - TrenchFloorAlpha) * depth div TrenchBevelPx
  overTint(base, rgba(12, 9, 5, uint8(alpha)))

proc tileSample(tex: Image, x, y: int): ColorRGBA =
  ## Samples a seamless texture tiled across the arena (opaque source).
  tex.unsafe[x mod tex.width, y mod tex.height].rgba

proc tileSampleF(tex: Image, fx, fy: float): ColorRGBA =
  ## Bilinear tile sample at a fractional map-pixel coordinate (wrapping).
  ## The texture still tiles 1:1 with LOGICAL map pixels — a scale× renderer
  ## passes fractional coords, so the floor texture keeps its 1× world size but
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

## --- Rooftop wall material (top-down building look from the collision mask) ---
## Every wall pixel — border frame, rect stub, diamond, disc, or chevron — is
## rendered as one coherent LOW-DETAIL BUILDING seen from above: a light
## parapet rim around the perimeter, a shadow line where the parapet drops to
## the roof, and a dark flat roof membrane crossed by subtle diagonal seams.
## The shading comes from each pixel's distance to the nearest floor pixel, so
## — like the carved-stone material it replaces — the art matches every
## collider EXACTLY and is identical on both halves by construction (the mask
## is mirror-symmetric; the world-space roof seams are the one deliberate
## exception, same as the glass sheen). Light comes from the up-left, so the
## up-left parapet run catches a highlight and the down-right run falls into
## shadow — the Gungeon/Nuclear-Throne top-down convention (L98). The
## buildings keep the cover's warm-tan family (REPLAY_DESIGN §3 warm-stone
## cover) so they pop off the neutral-grey concrete floor, and the team
## colors stay the only saturated channels.
const
  WallBevel = 3                          ## px width of the parapet rim band.
  RoofFace = rgba(110, 92, 72, 255)      ## flat warm roof (the old cover tan,
                                         ## a step darker so the rim pops).
  RoofSeam = rgba(97, 80, 62, 255)       ## diagonal membrane seam lines.
  RoofLip = rgba(56, 45, 35, 255)        ## shadow line where parapet meets roof.
  ParapetFace = rgba(152, 130, 104, 255) ## flat parapet top.
  ParapetHi = rgba(192, 169, 139, 255)   ## up-left lit parapet (catches light).
  ParapetLo = rgba(88, 72, 56, 255)      ## down-right shaded parapet.
  StoneInk = rgba(32, 27, 22, 255)       ## warm near-black ground line (never #000).
  RoofSeamPeriod = 16                    ## px between diagonal roof seams.

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

proc rooftopColorAt(
  wall: seq[bool], w, h, x, y, scale: int
): ColorRGBA =
  ## Shades one wall pixel as a low-detail rooftop: an ink ground line where
  ## the building meets the floor, a parapet rim lit toward the up-left light
  ## and shaded toward the down-right, a shadow line where the parapet drops
  ## inside, and a dark seamed roof membrane deep in the interior. The mask
  ## may be a `scale`× render of the arena; every band (ink line, parapet,
  ## lip) widens by `scale` so the material keeps its 1× proportions.
  let
    bevel = WallBevel * scale
    cap = bevel + scale                  ## parapet + the inner lip line.
    up = floorDistDir(wall, w, h, x, y, 0, -1, cap)
    left = floorDistDir(wall, w, h, x, y, -1, 0, cap)
    down = floorDistDir(wall, w, h, x, y, 0, 1, cap)
    right = floorDistDir(wall, w, h, x, y, 1, 0, cap)
    edge = min(min(up, down), min(left, right))
  if edge <= scale:
    return StoneInk                      ## touches the floor → ground outline.
  let
    topDist = min(up, left)              ## nearer the up-left (lit) rim.
    botDist = min(down, right)           ## nearer the down-right (shaded) rim.
  if edge <= bevel:
    ## Graded parapet rim: brightest at the outer edge (just inside the ink
    ## line), easing toward the flat parapet top by the rim width so the
    ## building edge reads raised, not painted.
    if topDist <= botDist:
      let t = (topDist - 2 * scale).float / max(1, bevel - 2 * scale).float
      mix(ParapetHi, ParapetFace, clamp(t, 0.0, 1.0))
    else:
      let t = (botDist - 2 * scale).float / max(1, bevel - 2 * scale).float
      mix(ParapetLo, ParapetFace, clamp(t, 0.0, 1.0))
  elif edge <= bevel + scale:
    RoofLip                              ## parapet drops to the roof.
  else:
    ## Roof membrane: flat dark field with subtle diagonal seams running
    ## down-left (perpendicular to the glass sheen streaks, so the two
    ## materials never read as one pattern).
    let
      period = RoofSeamPeriod * scale
      phase = ((x + y) mod period + period) mod period
    if phase < scale: RoofSeam else: RoofFace

proc rooftopColor(wall: seq[bool], w, h, x, y: int): ColorRGBA =
  ## 1× rooftop material (the baked collision-resolution map and spun diamonds).
  rooftopColorAt(wall, w, h, x, y, 1)

const
  ## Glass window material: a pale pane set in the same parapet frame language
  ## as the rooftop walls — a skylight in the building's face. The face targets
  ## palette index 1 (light gray) and the
  ## sheen streaks index 2 (near-white), so windows stay legible after the
  ## player-view palette quantization — glass must READ as see-through cover.
  GlassFace = rgba(198, 198, 196, 255)   ## flat pane; quantizes to palette 1.
  GlassSheen = rgba(240, 236, 226, 255)  ## diagonal streaks; quantizes to 2.

proc windowGlassColorAt(
  wall: seq[bool], w, h, x, y, scale: int
): ColorRGBA =
  ## Shades one glass window pixel: the same ink ground line and a thin
  ## parapet frame where the pane meets the floor (so windows sit in the
  ## rooftop wall language), then a pale pane crossed by 45-degree sheen
  ## streaks running down-right, perpendicular to the up-left light the
  ## parapet bevels use.
  ## Like rooftopColorAt, every band widens by `scale` so the material
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
    return ParapetFace                   ## thin parapet frame around the pane.
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

proc diamondSpinFrame*(
  cx, tick: int, mirrored = ArenaSpinMirrored, width = MapWidth
): int {.inline.} =
  ## The spin frame of the diamond centered at map-x `cx` on one tick. The
  ## frame derives only from the tick, so the renderer, the collision masks,
  ## and every replay viewer read the SAME angle. Single source of truth.
  ##
  ## Direction has to follow the map's symmetry or the live footprint stops
  ## being symmetric even though the resting one is. A REFLECTION maps a
  ## rotation by +theta to one by -theta, so mirror-image diamonds must spin
  ## in OPPOSITE directions — the classic arena's two halves. A ROTATION
  ## commutes with rotation, so rot180 and rot90 image diamonds must spin the
  ## SAME way; giving them opposite directions (which the side-of-the-map rule
  ## does, since both symmetries move a diamond across the axis) makes the two
  ## halves of a rot180 map differ. On rotationally symmetric maps every
  ## diamond therefore turns together.
  ##
  ## `mirrored` / `width` default to the installed map, which is what every
  ## production caller wants; passing them explicitly lets the rule be checked
  ## against a map that is not the process map.
  let dir = if mirrored and 2 * cx >= width - 1: -1 else: 1
  diamondFrameIndex((tick div DiamondSpinTicksPerFrame) * dir)

proc animatedDiamondCovers*(
  spot: tuple[cx, cy, radius: int], frame, x, y: int
): bool {.inline.} =
  ## True when map pixel (x, y) is stone in one spinning diamond at `frame`.
  rotatedDiamondCovers(
    spot.radius, frame, 2 * (x - spot.cx), 2 * (y - spot.cy), 2)

var diamondFrameCache: array[DiamondSpinFrames, seq[tuple[
  scale: int, pixels: seq[uint8]]]]

proc rotatingDiamondPixels*(
  radius, frame: int,
  scale = 1
): tuple[size: int, pixels: seq[uint8]] =
  ## One pre-rotated frame of a spinning center diamond, shaded with the same
  ## rooftop material as the baked walls: the mask is rotated, then the
  ## parapet bevel is re-derived from it, so the light stays up-left at every
  ## angle.
  ## The mask comes from rotatedDiamondCovers — the SAME predicate the
  ## collision, bullet, and vision masks stamp — so what a player sees is
  ## exactly what blocks them. `size` is the LOGICAL (map-pixel) footprint;
  ## `pixels` are rasterized at scale× that footprint — the analytic mask is
  ## evaluated per output pixel, so a scaled frame has genuinely smoother
  ## edges, not upscaled blocks.
  let size = 2 * radius + 8
  let index = diamondFrameIndex(frame)
  for cached in diamondFrameCache[index]:
    if cached.scale == scale:
      return (size, cached.pixels)
  let outSize = size * scale
  var mask = newSeq[bool](outSize * outSize)
  for y in 0 ..< outSize:
    for x in 0 ..< outSize:
      ## dx = x/scale - size/2, scaled by the shared denominator. The sprite
      ## blits at cx - size div 2, so this reduces to exactly (X - cx) in map
      ## pixels — the same offsets animatedDiamondCovers samples, at scale×
      ## resolution.
      mask[y * outSize + x] = rotatedDiamondCovers(
        radius, index,
        2 * x - size * scale,
        2 * y - size * scale,
        2 * scale)
  var pixels = newSeq[uint8](outSize * outSize * 4)
  for y in 0 ..< outSize:
    for x in 0 ..< outSize:
      if mask[y * outSize + x]:
        let
          color = rooftopColorAt(mask, outSize, outSize, x, y, scale)
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
  EndzoneCrackGlow = 165         ## ember alpha on the darkest crack pixels (kept
                                 ## below the pedestal glow so the flag home
                                 ## stays the brightest thing in the endzone).
  EndzoneLineAlpha = 220         ## solid threshold line at the exact score-x.
  EndzoneLineW = 3               ## px width of that threshold line.
  # The concrete floor texture (scripts/art/build_floor.py) is baked to a
  # luminance CONTRACT with these gates: the polished surface — including its
  # light panel-seam bevels — stays at lum 72..112 (at/above FaceLevel → NO
  # glow); only the hairline crack bottoms dip to ~32..34 (at/below CrackLevel
  # → full glow), with the crack tapers crossing the band and glowing partially.
  EndzoneFaceLevel = 66          ## polished-surface floor luminance (glow = 0).
  EndzoneCrackLevel = 34         ## joint/crack-bottom luminance (glow = full).
  EndzoneGlowFloor = 0.82        ## min home-falloff so the far end still glows.
  RedEndzoneColor* = rgba(224, 82, 58, 255)    ## team vermillion (§4).
  BlueEndzoneColor* = rgba(63, 124, 196, 255)  ## team cerulean (§4).
  GreenEndzoneColor* = rgba(69, 168, 94, 255)  ## matches the viewer --green.
  YellowEndzoneColor* = rgba(221, 197, 49, 255)  ## matches the viewer --yellow.
    ## Exported as THE team display colors. The 16-entry `Palette` a sprite's
    ## `color: uint8` indexes is the retro engine palette, and its blue slot
    ## (BlueTeamColor = 13) is a muted lavender (131,118,156) that reads nothing
    ## like the vivid cerulean the soldier art (116,168,255) and this endzone
    ## floor actually show. Any NEW team-colored art should tint from these four
    ## so it matches what a viewer sees on the board.

proc emberThroughCracks(base, ember: ColorRGBA, strength: float): ColorRGBA =
  ## Lets a team ember glow seep UP ONLY through the DARK joint/crack pixels of
  ## the concrete TEXTURE — the polished faces stay completely clean (no base
  ## wash), so team color is confined to the actual fissures/seams, not a flat
  ## tint over the tiles (L98 #4). Distinct from the solid capture LINE, which is
  ## a painted stripe. A two-point luminance gate anchored to the measured floor
  ## split does the confining; `strength` is a gentle pedestal-side falloff.
  let l = (base.r.int * 30 + base.g.int * 59 + base.b.int * 11) div 100
  # 0 at/above a polished face, 1 at/below a crack bottom — cracks only.
  let crack = clamp((EndzoneFaceLevel - l).float /
    (EndzoneFaceLevel - EndzoneCrackLevel).float, 0.0, 1.0)
  let a = strength * crack * crack * EndzoneCrackGlow.float
  overTint(base, rgba(ember.r, ember.g, ember.b, uint8(clamp(a, 0.0, 255.0))))

proc teamEndzoneColor(team: Team): ColorRGBA =
  ## Returns the floor-glow ember color for one team's endzone.
  case team
  of Red: RedEndzoneColor
  of Blue: BlueEndzoneColor
  of Green: GreenEndzoneColor
  of Yellow: YellowEndzoneColor

type EndzoneTint = object
  ## One team's precomputed endzone paint job: its capture-zone box, ember
  ## color, and which box edges are inner THRESHOLD edges (the map-border
  ## edges of the box are not thresholds and draw no line).
  zone: CaptureZone
  color: ColorRGBA
  boundLoX, boundHiX, boundLoY, boundHiY: bool

proc endzoneTints(gameMap: CtfMap): seq[EndzoneTint] =
  ## The active teams' endzone paint jobs, computed once per bake.
  for team in gameMap.teams():
    let zone = gameMap.captureZone(team)
    result.add EndzoneTint(
      zone: zone,
      color: teamEndzoneColor(team),
      boundLoX: zone.xLo > 0,
      boundHiX: zone.xHi < gameMap.width - 1,
      boundLoY: zone.yLo > 0,
      boundHiY: zone.yHi < gameMap.height - 1
    )

proc endzoneColorAt(
  tints: seq[EndzoneTint], base: ColorRGBA, x, y, playLo, playHi,
  playLoY, playHiY: int
): ColorRGBA =
  ## Tints one floor pixel if it sits inside a capture endzone. Team ember
  ## seeps up through the tile cracks, brightest at the pedestal (the inner
  ## threshold edge) and floored so the whole zone still glows; the exact
  ## threshold a carrier must cross gets a crisp solid line. Sides maps
  ## reproduce the classic two-column paint exactly; corner boxes fade on
  ## both axes and line both inner edges.
  for tint in tints:
    if not tint.zone.inCaptureZone(x, y):
      continue
    var
      onLine = false
      near = 1.0
    if tint.zone.diag:
      ## Diagonal corner zone: the threshold edge is the 45-degree L1
      ## shell; the ember is brightest at the line and eases toward the
      ## corner. The line band is one pixel wider in L1 so its diagonal
      ## stripe carries the same optical weight as the axis lines.
      let d = abs(x - tint.zone.cornerX) + abs(y - tint.zone.cornerY)
      if d > tint.zone.diagLimit - EndzoneLineW - 1:
        return overTint(base, rgba(tint.color.r, tint.color.g,
          tint.color.b, EndzoneLineAlpha))
      return emberThroughCracks(base, tint.color,
        EndzoneGlowFloor + (1.0 - EndzoneGlowFloor) *
          clamp(d.float / max(1, tint.zone.diagLimit).float, 0.0, 1.0))
    if tint.zone.disc:
      ## Compact ROUND endzone: the threshold is the painted ring, so the
      ## ember is brightest against it and eases in toward the pedestal —
      ## the same language as the diagonal corner zones.
      let d = sqrt(float(
        (x - tint.zone.anchorX) * (x - tint.zone.anchorX) +
        (y - tint.zone.anchorY) * (y - tint.zone.anchorY)))
      if d > float(tint.zone.radius - EndzoneLineW):
        return overTint(base, rgba(tint.color.r, tint.color.g,
          tint.color.b, EndzoneLineAlpha))
      return emberThroughCracks(base, tint.color,
        EndzoneGlowFloor + (1.0 - EndzoneGlowFloor) *
          clamp(d / max(1, tint.zone.radius).float, 0.0, 1.0))
    if tint.boundHiX:
      if x > tint.zone.xHi - EndzoneLineW:
        onLine = true
      near = min(near, clamp(
        (x - playLo).float / max(1, tint.zone.xHi - playLo).float, 0.0, 1.0))
    if tint.boundLoX:
      if x < tint.zone.xLo + EndzoneLineW:
        onLine = true
      near = min(near, clamp(
        (playHi - x).float / max(1, playHi - tint.zone.xLo).float, 0.0, 1.0))
    if tint.boundHiY:
      if y > tint.zone.yHi - EndzoneLineW:
        onLine = true
      near = min(near, clamp(
        (y - playLoY).float / max(1, tint.zone.yHi - playLoY).float, 0.0, 1.0))
    if tint.boundLoY:
      if y < tint.zone.yLo + EndzoneLineW:
        onLine = true
      near = min(near, clamp(
        (playHiY - y).float / max(1, playHiY - tint.zone.yLo).float, 0.0, 1.0))
    if onLine:
      return overTint(base, rgba(tint.color.r, tint.color.g,
        tint.color.b, EndzoneLineAlpha))
    return emberThroughCracks(base, tint.color,
      EndzoneGlowFloor + (1.0 - EndzoneGlowFloor) * near)
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
  ## chevron/diamond edges), the rooftop parapet bevel grades over scale× more
  ## steps, the concrete floor resolves bilinearly between texels, and the
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
    floorTex = readImage(dir / "data/arena_floor.png")
  var pedSprs: array[Team, Image]
  for team in gameMap.teams():
    pedSprs[team] = readImage(dir / "data/ped_" & teamText(team) & ".png")
  # The art mask at output resolution: border + obstacle shapes from float
  # geometry, minus the spinning center diamonds (drawn live as objects).
  # Window pixels (glass) get their own mask in the same per-shape pass: wall
  # points inside a window shape draw as the pale pane, not the rooftop
  # material.
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
    if gameMap.isSpinningDiamond(shape):
      continue
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
  # The floor texture tiles the board with a period of exactly texW×texH LOGICAL
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
    tints = endzoneTints(gameMap)
    playLo = ArenaBorder
    playHi = w - 1 - ArenaBorder
    playLoY = ArenaBorder
    playHiY = h - 1 - ArenaBorder
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
            rooftopColorAt(artMask, ow, oh, x, y, scale)
        coldColor = hotColor
      else:
        coldColor = tileBlock[tileRow + x mod tileW]
        hotColor = endzoneColorAt(
          tints, coldColor, lx, ly, playLo, playHi, playLoY, playHiY)
        # The trench pit (config-gated trenches) paints over the finished floor on both
        # variants; it sits at the center, well clear of the endzone glow.
        coldColor = trenchArtColorAt(coldColor, lx, ly)
        hotColor = trenchArtColorAt(hotColor, lx, ly)
      if onBorder:
        hotColor = overTint(hotColor, ArenaBorderColor)
        coldColor = overTint(coldColor, ArenaBorderColor)
      put(result.hot, i * 4, hotColor)
      put(result.cold, i * 4, coldColor)
  # Pedestals: pixie still resizes the painted masters, but the composite onto
  # the board is a manual straight-alpha src-over into the byte buffers.
  for team in gameMap.teams():
    let
      home = gameMap.flagHome(team)
      full = pedSprs[team]
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
  ## visuals: a tiled top-down polished-concrete floor, and ONE coherent
  ## rooftop material for every wall pixel — border frame, rect stub, diamond,
  ## disc, and chevron alike — beveled from the collision mask itself so the
  ## art matches each collider EXACTLY and is identical on both halves by
  ## construction. The
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
    floorTex = readImage(dir / "data/arena_floor.png")
  var pedSprs: array[Team, Image]
  for team in gameMap.teams():
    pedSprs[team] = readImage(dir / "data/ped_" & teamText(team) & ".png")
  ## Pass 1: the boolean wall mask (border + obstacles), shared by the shading
  ## bevel and the collision masks so art and geometry can never disagree.
  var wallMask = newSeq[bool](w * h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      wallMask[y * w + x] = isArenaWall(x, y, cx, cy)
  ## The static mask drops only the spinning shapes themselves. Any overlapping
  ## wall from another obstacle remains baked under the live sprite.
  var artMask = wallMask
  for y in 0 ..< h:
    for x in 0 ..< w:
      if artMask[y * w + x] and isAnimatedDiamondPixel(x, y):
        artMask[y * w + x] =
          mapWallAt(gameMap, ArenaObstacles, x, y, includeSpinning = false)
  ## The capture endzones: the exact score-columns from checkWinConditions'
  ## captureZoneXRange (Red's inclusive right threshold, Blue's inclusive left),
  ## painted into the FLOOR below so a carrier can read where to run.
  let
    tints = endzoneTints(gameMap)
    playLo = ArenaBorder                     # inner playfield edges: the glow
    playHi = w - 1 - ArenaBorder             # anchors home, fades to the line.
    playLoY = ArenaBorder
    playHiY = h - 1 - ArenaBorder
  ## Pass 2: paint. Floor pixels sample the concrete tile; wall pixels are the
  ## rooftop material shaded from the mask. The perimeter frame is overlaid
  ## with the solid border color so the play space reads as a lit pit. Floor
  ## pixels inside a
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
        elif artWall: rooftopColor(artMask, w, h, x, y)
        elif withEndzoneGlow: endzoneColorAt(tints,
          tileSample(floorTex, x, y), x, y, playLo, playHi, playLoY, playHiY)
        else: tileSample(floorTex, x, y)
      if not wall:
        # The trench pit (config-gated trenches) paints over the finished floor; it never
        # overlaps a wall (it sits inside the open center ring).
        color = trenchArtColorAt(color, x, y)
      if onBorder:
        color = overTint(color, ArenaBorderColor)
      result.mapImage[x, y] = color
      ## The collision layers drop the spinning diamonds for the same reason
      ## the art does: their footprint is not static. initSimServer keeps this
      ## diamond-free bake as the BASE and stamps the live rotated footprint
      ## over it every time the spin frame advances (applyDiamondGeometry).
      let collisionWall = artWall
      result.walkImage[x, y] = if collisionWall: clear else: opaque
      result.wallImage[x, y] = if collisionWall: opaque else: clear
  ## Carved team pedestal under each flag home (walkable — sits inside the
  ## protected spawn pocket; cosmetic only, collision masks untouched). With the
  ## glow OFF this is the "cold" map: the pedestal art is dimmed to a powered-down
  ## disc (see pedestalDimmed) so the broadcast crossfade dims the disc along with
  ## the floor glow when the heart is gone — otherwise a hot==cold pedestal never
  ## fades. The RGB/hot map (withEndzoneGlow) keeps the pedestal at full light.
  for team in gameMap.teams():
    let
      home = gameMap.flagHome(team)
      full = pedSprs[team]
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
    teams: 2,
    scoring: ClassicScoring,
    mapPath: DefaultMapPath,
    mapSeed: -1,
    mapPoolIndex: -1,
    mapGen: MapGenOverrides(windows: -1, pits: -1, pitDensity: -1),
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
  of "green":
    Green
  of "yellow":
    Yellow
  else:
    raise newException(
      CtfError,
      "Config field slots[" & $slotIndex &
        "].team must be red, blue, green, or yellow."
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
  if config.teams notin [2, 4]:
    raise newException(CtfError, "Config field teams must be 2 or 4.")
  if config.scoring notin [ClassicScoring, PotScoring]:
    raise newException(
      CtfError,
      "Config field scoring must be " & ClassicScoring & " or " & PotScoring &
        "; got " & config.scoring & "."
    )
  for i, slot in config.slots:
    if slot.hasTeam and ord(slot.team) >= config.teams:
      raise newException(
        CtfError,
        "Config field slots[" & $i & "].team is " & teamText(slot.team) &
          " but the game seats " & $config.teams & " teams."
      )
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
  node.readConfigInt("teams", config.teams)
  node.readConfigString("scoring", config.scoring)
  node.readConfigString("map", config.mapPath)
  node.readConfigString("mapPath", config.mapPath)
  node.readConfigInt("mapSeed", config.mapSeed)
  node.readConfigInt("mapPoolIndex", config.mapPoolIndex)
  node.readConfigString("mapSize", config.mapGen.size)
  node.readConfigString("mapSymmetry", config.mapGen.symmetry)
  node.readConfigInt("mapColumns", config.mapGen.columns)
  node.readConfigInt("mapWindows", config.mapGen.windows)
  node.readConfigInt("mapPits", config.mapGen.pits)
  node.readConfigInt("mapPitDensity", config.mapGen.pitDensity)
  node.readConfigString("mapCenterFeature", config.mapGen.centerFeature)
  node.readConfigString("mapLayout", config.mapGen.layout)
  node.readConfigString("mapEndzone", config.mapGen.endzone)
  node.readConfigInt("mapEndzoneRadius", config.mapGen.endzoneRadius)
  node.readConfigInt("mapBaseDepth", config.mapGen.baseDepth)
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
  teamText(slot.team)

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
    "mapPits": config.mapGen.pits,
    "mapPitDensity": config.mapGen.pitDensity,
    "mapCenterFeature": config.mapGen.centerFeature,
    "mapLayout": config.mapGen.layout,
    "mapEndzone": config.mapGen.endzone,
    "mapEndzoneRadius": config.mapGen.endzoneRadius,
    "mapBaseDepth": config.mapGen.baseDepth,
    "closedRoster": config.closedRoster,
    "showPlayerLabels": config.showPlayerLabels,
    "fastMode": config.fastMode,
    "teams": config.teams,
    "scoring": config.scoring,
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

proc spawnAimBrads*(gameMap: CtfMap, team: Team): int =
  ## Returns the spawn/respawn aim angle: toward the map center, so every
  ## team wakes facing the fight. Sides maps keep the classic east/west pair;
  ## corner teams face the diagonal, plus arms face along their arm.
  case gameMap.layout
  of layoutSides:
    if team == Red:
      0                        ## east, toward Blue.
    else:
      AimBradsTurn div 2       ## west, toward Red.
  of layoutCorners:
    ## 0 = east, counter-clockwise: SE 224, SW 160, NE 32, NW 96.
    case team
    of Red:
      AimBradsTurn - AimBradsTurn div 8      ## top-left faces south-east.
    of Blue:
      AimBradsTurn div 2 + AimBradsTurn div 8  ## top-right faces south-west.
    of Green:
      AimBradsTurn div 8                     ## bottom-left faces north-east.
    of Yellow:
      AimBradsTurn div 2 - AimBradsTurn div 8  ## bottom-right faces north-west.
  of layoutPlus:
    case team
    of Red:
      0                        ## west arm faces east.
    of Blue:
      AimBradsTurn div 2       ## east arm faces west.
    of Green:
      3 * AimBradsTurn div 4   ## north arm faces south.
    of Yellow:
      AimBradsTurn div 4       ## south arm faces north.

proc spawnFlipH*(gameMap: CtfMap, team: Team): bool =
  ## Returns whether a team's sprite spawns horizontally flipped: any spawn
  ## aim with a westward component faces the body left. Exactly `team ==
  ## Blue` on sides maps.
  let brads = gameMap.spawnAimBrads(team)
  brads > AimBradsTurn div 4 and brads < 3 * AimBradsTurn div 4

proc teamPaintRgba*(color: uint8): ColorRGBA =
  ## Maps a sprite's palette team color to the TRUE team display color — the
  ## vivid hues the soldier art and endzone floors actually show — rather than
  ## the retro palette slot. Use this for any new true-color team art:
  ## `Palette[BlueTeamColor]` is a muted lavender (131,118,156) that matches the
  ## blue a viewer sees nowhere else on the board. A non-team color (an
  ## individual player slot) falls back to its palette entry.
  if color == RedTeamColor:
    RedEndzoneColor
  elif color == BlueTeamColor:
    BlueEndzoneColor
  elif color == GreenTeamColor:
    GreenEndzoneColor
  elif color == YellowTeamColor:
    YellowEndzoneColor
  else:
    Palette[color and 0x0f]


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
  for team in sim.teams():
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

proc spawnPosition*(sim: SimServer, team: Team, order: int): tuple[x, y: int] =
  ## Returns a deterministic spawn position just inside a team's home edge:
  ## players stagger along the edge, perpendicular to their home axis (down
  ## the side for east/west teams, across for the plus layout's north/south
  ## arms).
  let
    anchor = sim.gameMap.teamAnchor(team)
    strip = order div 2          ## stagger players down the edge.
    spread = 36
    stepMajor = (strip - 1) * spread
    stepMinor = (if order mod 2 == 0: -6 else: 6)
    vertical = sim.gameMap.layout != layoutPlus or team in {Red, Blue}
    targetX = if vertical: anchor.x + stepMinor else: anchor.x + stepMajor
    targetY = if vertical: anchor.y + stepMajor else: anchor.y + stepMinor
  sim.nearestWalkable(targetX, targetY)

proc captureZone(sim: SimServer, team: Team): CaptureZone =
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
    for team in Team:
      gameOrdinal += account.games[team]
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
    for team in Team:
      gameOrdinal += account.games[team]
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
  ## Returns every active team's flag to its home pedestal. Inactive slots
  ## hold an explicit no-carrier state so nothing can misread the array's
  ## zero value (carrier 0 would mean "player 0 carries it").
  for team in Team:
    if team in sim.teams():
      sim.resetFlag(team)
    else:
      sim.flags[team] = FlagState(x: 0, y: 0, carrier: -1)

proc teamForSlot(sim: SimServer, order: int): Team =
  ## Returns the configured or default team for one slot: slots deal round
  ## the active teams in enum order (the classic red/blue alternation on
  ## 2-team maps).
  let slot =
    if order >= 0 and order < sim.config.slots.len:
      sim.config.slots[order]
    else:
      PlayerSlotConfig()
  if slot.hasTeam:
    slot.team
  else:
    Team(order mod sim.gameMap.teamCount())

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

const IdentityNameUnknown* = "?"
  ## Stands in for a slot name that cannot be resolved; see `shoutIdentityName`.

proc shoutIdentityName*(sim: SimServer, shout: Shout): string =
  ## One shout author's anonymous slot name (an `IdentityNames` entry), for the
  ## speech-bubble label.
  ##
  ## Deliberately NOT `shout.address`. The address is the connecting policy's
  ## own name, and EVERY player in earshot reads shout labels off the wire — so
  ## labeling a bubble with the address hands rivals a free roster of who is in
  ## the match, and hands them our own name every time our bots talk to each
  ## other. The slot letter carries the same signal a listener can actually use
  ## ("which teammate called this") with no identity attached.
  ##
  ## Resolved at render time rather than stored on `Shout`, which is
  ## flatty-serialized into `SimServer` and therefore into replays: an extra
  ## field there would be a GameVersion break for a string that only ever
  ## exists in a rendered label.
  ##
  ## A bubble OUTLIVES its author — it displays for ShoutTicks, and the shouter
  ## can disconnect inside that window (`removePlayerAt` drops the row) — so an
  ## unresolvable author falls back to IdentityNameUnknown rather than dropping
  ## the bubble, which is observable state.
  for player in sim.players:
    if player.address == shout.address:
      return IdentityNames[sim.slotIdentityIndex(player.joinOrder)]
  IdentityNameUnknown

proc findSpawn*(sim: SimServer): tuple[x, y: int] =
  ## Returns the next lobby spawn position.
  let order = sim.players.len
  sim.spawnPosition(sim.teamForSlot(order), order div sim.gameMap.teamCount())

proc playerSlotLimit*(config: GameConfig): int =
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
  for team in sim.teams():
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
  let spawn = sim.spawnPosition(team, order div sim.gameMap.teamCount())
  sim.bindRewardAccountSlot(accountIndex, order)
  sim.rewardAccounts[accountIndex].hasTeam = false
  sim.rewardAccounts[accountIndex].won = false
  sim.rewardAccounts[accountIndex].abandoned = false
  sim.players.add Player(
    x: spawn.x,
    y: spawn.y,
    homeX: spawn.x,
    homeY: spawn.y,
    aimBrads: sim.gameMap.spawnAimBrads(team),
    flipH: sim.gameMap.spawnFlipH(team),
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
  inc sim.rewardAccounts[index].games[sim.players[playerIndex].team]

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
  inc sim.rewardAccounts[index].wins[sim.players[playerIndex].team]

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

proc grenadeSpawnPoints*(gameMap: CtfMap): array[4, tuple[x, y: int]] =
  ## The four grenade spawn points. Sides maps keep the classic corners;
  ## corner maps move them to the edge midpoints (the corners are endzones
  ## there); plus maps tuck them at the inner corners of the center
  ## intersection, clear of the four endzone arm mouths.
  let inset = ArenaBorder + GrenadeSpawnInset
  case gameMap.layout
  of layoutSides:
    [(inset, inset),
      (inset, gameMap.height - inset),
      (gameMap.width - inset, inset),
      (gameMap.width - inset, gameMap.height - inset)]
  of layoutCorners:
    rot90Orbit((gameMap.width div 2, inset), gameMap.width)
  of layoutPlus:
    let arm = gameMap.plusArmHalf()
    rot90Orbit(
      (gameMap.center.x + arm - inset, gameMap.center.y + arm - inset),
      gameMap.width
    )

proc shieldSpawnPoints*(gameMap: CtfMap): seq[tuple[x, y: int]] =
  ## One shield point per team, deep in that team's endzone. RED's spot is
  ## the only one chosen; every other team's is its image under the map's own
  ## symmetry (`teamImagePoint`), so no team's shield sits in terrain the
  ## others' don't get.
  let
    inset = ArenaBorder + GrenadeSpawnInset
    red =
      if gameMap.endzone != ezColumn:
        ## A compact endzone has no back column to hide a pickup in: park it
        ## below the pedestal, inside the zone (protected floor, so always
        ## walkable and always connected) and clear of the pedestal art.
        let anchor = gameMap.teamAnchor(Red)
        MapPoint(x: anchor.x, y: anchor.y + 2 * gameMap.endzoneRadius div 3)
      else:
        case gameMap.layout
        of layoutSides:
          ## The classic back column, bottom half; the cans hold the top.
          MapPoint(x: inset, y: 3 * gameMap.height div 4)
        of layoutCorners:
          ## Red's own x edge at anchor height. Blue's copy is the quarter
          ## turn of that — the TOP edge — not the right edge a mirror picks.
          MapPoint(x: inset, y: gameMap.teamAnchor(Red).y)
        of layoutPlus:
          ## The lower half of Red's arm mouth. Anchoring each team's copy to
          ## the integer `center` instead lands it a pixel off the orbit,
          ## since the rot90 axis is at (side - 1)/2.
          MapPoint(x: inset, y: gameMap.center.y + gameMap.plusArmHalf() div 2)
  for team in gameMap.teams():
    let point = gameMap.teamImagePoint(red, team)
    result.add((point.x, point.y))

proc plasmaArcSpawnPoints*(gameMap: CtfMap): seq[tuple[x, y: int]] =
  ## One spray can point per team, built exactly like the shields: RED's spot
  ## carried to every other team by the map's own symmetry. Red's can is the
  ## opposite half of its endzone from Red's shield, so the two sets never
  ## collide.
  let
    inset = ArenaBorder + PlasmaArcSpawnInset
    red =
      if gameMap.endzone != ezColumn:
        ## The compact-endzone counterpart of the shield spot: same zone,
        ## other side of the pedestal (cans high, shields low).
        let anchor = gameMap.teamAnchor(Red)
        MapPoint(x: anchor.x, y: anchor.y - 2 * gameMap.endzoneRadius div 3)
      else:
        case gameMap.layout
        of layoutSides:
          MapPoint(x: inset, y: gameMap.height div 4)
        of layoutCorners:
          ## Red's shield spot reflected across the diagonal — its own y edge
          ## at anchor width — so the two orbits never share an edge spot.
          MapPoint(x: gameMap.teamAnchor(Red).x, y: inset)
        of layoutPlus:
          MapPoint(x: inset, y: gameMap.center.y - gameMap.plusArmHalf() div 2)
  for team in gameMap.teams():
    let point = gameMap.teamImagePoint(red, team)
    result.add((point.x, point.y))

proc resetGrenades*(sim: var SimServer) =
  ## Refills every corner pickup and clears carried and airborne grenades.
  let points = sim.gameMap.grenadeSpawnPoints()
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
  var targets: seq[tuple[x, y: int]]
  if sim.gameMap.medKitSpawns.len >= 2:
    for point in sim.gameMap.medKitSpawns:
      targets.add((point.x, point.y))
  else:
    targets = @[
      (MapWidth div 2, MapHeight div 3),
      (MapWidth div 2, 2 * MapHeight div 3),
    ]
  sim.medKitSpawns.setLen(targets.len)
  for i in 0 ..< sim.medKitSpawns.len:
    let spot = sim.nearestWalkable(targets[i].x, targets[i].y)
    sim.medKitSpawns[i] = PickupSpawn(
      x: spot.x, y: spot.y, present: true, respawnAt: 0
    )

proc resetShields*(sim: var SimServer) =
  ## Places one shield deep in each team's endzone, in the same back column
  ## as the corner grenade pickups but in the BOTTOM half (three quarters of
  ## the map height down) — the spray cans hold the matching top-half spots —
  ## nudged to the nearest walkable floor, and refills both.
  let targets = sim.gameMap.shieldSpawnPoints()
  sim.shieldSpawns.setLen(targets.len)
  for i in 0 ..< sim.shieldSpawns.len:
    let spot = sim.nearestWalkable(targets[i].x, targets[i].y)
    sim.shieldSpawns[i] = PickupSpawn(
      x: spot.x, y: spot.y, present: true, respawnAt: 0
    )
  for i in 0 ..< sim.players.len:
    sim.players[i].hasShield = false
    sim.players[i].shieldHp = 0
proc resetPlasmaArcs*(sim: var SimServer) =
  ## Refills every team's spray can pickup and clears carried cans.
  let points = sim.gameMap.plasmaArcSpawnPoints()
  sim.plasmaArcSpawns.setLen(points.len)
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
  sim.paintStains = @[]        ## each match starts on a clean arena.
  sim.diamondStains = @[]
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
    sim.players[i].aimBrads = sim.gameMap.spawnAimBrads(sim.players[i].team)
    sim.players[i].flipH = sim.gameMap.spawnFlipH(sim.players[i].team)
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

proc isArtWall*(sim: SimServer, mx, my: int): bool =
  ## Static baked wall at this point, excluding the live diamonds.
  if mx < 0 or my < 0 or mx >= MapWidth or my >= MapHeight:
    return true
  for patch in sim.diamondPatches:
    if mx >= patch.x0 and mx < patch.x0 + patch.w and
        my >= patch.y0 and my < patch.y0 + patch.h:
      return patch.baseWall[(my - patch.y0) * patch.w + mx - patch.x0]
  sim.isWall(mx, my)

proc animatedDiamondAt*(sim: SimServer, x, y: int): int =
  ## Index of the live diamond covering (x, y), or -1.
  for i in 0 ..< AnimatedDiamonds.len:
    let spot = AnimatedDiamonds[i]
    if animatedDiamondCovers(
        spot, diamondSpinFrame(spot.cx, sim.tickCount), x, y):
      return i
  -1

proc diamondSpinAngle*(sim: SimServer, diamond: int): float =
  ## Cosmetic angle derived from the geometry/render frame source of truth.
  let frame = diamondSpinFrame(AnimatedDiamonds[diamond].cx, sim.tickCount)
  float(frame) / float(DiamondSpinFrames) * PI / 2.0

proc seatInWall*(sim: SimServer, x, y: int, ux, uy: float): (int, int) =
  ## Nudges a wall impact from the FIRST wall pixel a little deeper along the
  ## shot's heading, staying inside the wall. The blot is masked to wall pixels,
  ## so a mark centered exactly on the wall's leading edge loses the half that
  ## overhangs the floor and survives as a thin sliver; seating it into the face
  ## it struck keeps the splat whole. Never crosses back out, so paint on a thin
  ## pillar stays on that pillar.
  result = (x, y)
  for step in 1 .. StainSeatDepth:
    let
      nx = x + int(round(ux * float(step)))
      ny = y + int(round(uy * float(step)))
    if not sim.isWall(nx, ny):
      break
    result = (nx, ny)

proc addPaintStain*(sim: var SimServer, x, y: int, color: uint8,
                    onWall = false) =
  ## Records one DRIED terrain stain at an impact site, if it wins the
  ## StainChancePct roll. Cosmetic only — so this must NOT touch `sim.rng`
  ## (that stream drives gameplay, and drawing from it here would shift every
  ## later roll). Instead the roll and the blot variant come from a hash of the
  ## impact site + tick, the same idiom as shotImpactOffset/fuzzedAimBrads: a
  ## replay re-deriving this tick gets the identical stain, and a viewer that
  ## scrubs sees the paint that existed at that tick.
  if sim.paintStains.len >= StainMaxCount:
    return
  var h = 0x9E3779B9'u32 xor 0x85EBCA6B'u32
  h = (h xor uint32(x)) * 0xC2B2AE35'u32
  h = (h xor uint32(y)) * 0x27D4EB2F'u32
  h = (h xor uint32(sim.tickCount)) * 0x165667B1'u32
  h = h xor (h shr 15)
  if StainChancePct < 100 and int(h mod 100'u32) >= StainChancePct:
    return
  # Paint that hit a ROTATING diamond sticks to that stone, not to the map:
  # store it in the diamond's own frame so it turns with the spin. (A static
  # terrain stain here would also be invisible — the diamond sprite draws over
  # it — and would smear onto the floor the art bakes under the diamond.)
  let diamond = sim.animatedDiamondAt(x, y)
  if diamond >= 0:
    if sim.diamondStains.len >= StainMaxCount:
      return
    let
      spot = AnimatedDiamonds[diamond]
      a = sim.diamondSpinAngle(diamond)
      dx = float(x - spot.cx)
      dy = float(y - spot.cy)
    sim.diamondStains.add DiamondStain(
      diamond: uint8(diamond),
      # Screen offset -> the diamond's un-rotated frame, the same transform
      # rotatingDiamondPixels uses to carve its mask.
      lx: float32(dx * cos(a) + dy * sin(a)),
      ly: float32(-dx * sin(a) + dy * cos(a)),
      color: color,
      seed: h
    )
    return
  sim.paintStains.add PaintStain(
    x: x, y: y, color: color, onWall: onWall, seed: h
  )

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
  for team in sim.teams():
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
  # No permanent stain at the death spot either: the paint that killed this cog
  # landed ON the cog, and the fading splatter above is the record of it. Only
  # paint that MISSED and reached terrain leaves a mark on terrain.
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
  ## Returns every living player whose BODY overlaps the attacker's forward
  ## spray cone, computed from the attacker's CURRENT position and aim: a live
  ## cone tracks its owner across the active window.
  ##
  ## The victim is a disc of PlasmaArcBodyRadius, not the bare point its
  ## 1px collision box would suggest, so the cone covers what the paint
  ## visibly covers. Spraying backwards still hits nobody: the can points
  ## forward, so a cog behind the attacker is out regardless of its body.
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
    if forward <= 0 or forward > reach + float(PlasmaArcBodyRadius):
      continue
    if perpendicular > forward * halfWidthSlope + float(PlasmaArcBodyRadius):
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
    # A can sprayed at the terrain coats it. March the cone's center ray to the
    # first wall inside reach and dry a stain there — so spraying down a
    # corridor leaves the corridor painted, not just the cogs in it. One stain
    # per tick of the cone (its site moves with the owner).
    block sprayStain:
      let
        ax = attacker.x + CollisionW div 2
        ay = attacker.y + CollisionH div 2
        (ux, uy) = aimVector(attacker.aimBrads)
      for step in 1 .. PlasmaArcReach:
        let
          rx = ax + int(round(ux * float(step)))
          ry = ay + int(round(uy * float(step)))
        if sim.isWall(rx, ry):
          let (sxw, syw) = sim.seatInWall(rx, ry, ux, uy)
          sim.addPaintStain(sxw, syw, teamColor(attacker.team), onWall = true)
          break sprayStain
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
      if bubbleUp:
        # Blink the bubble toward the sprayer, as the gun's damage site does —
        # otherwise a fully-absorbed burst shows no feedback anywhere.
        sim.bubbleImpacts.add BubbleImpactFx(
          playerIndex: victimIndex,
          tick: sim.tickCount,
          angleBrads: bradsOfVector(
            sim.players[arcFire.attacker].x - sim.players[victimIndex].x,
            sim.players[arcFire.attacker].y - sim.players[victimIndex].y
          )
        )
      else:
        # A can of paint sprayed in the face paints: stamp the visor splat,
        # like the gun and the grenade.
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

proc selectFireTarget(sim: var SimServer, shooterIndex: int): int =
  ## Returns the player the shot lands on: the bullet travels down the
  ## locked aim direction toward the FIRST body it crosses (friendly fire
  ## on), stopping at walls — or -1 for a miss. A trench occupant crossed
  ## by the ray ducks under TrenchMissPct of the shots fired from outside
  ## their trench (config-gated trenches): the bullet flies straight over them and carries
  ## on down the ray to the next exposed body, exactly as if the occupant
  ## were not there. The duck is rolled per occupant on the deterministic
  ## sim RNG at shot release.
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
    shooterTrench = sim.playerTrench(shooterIndex)
  # Every body the bullet corridor crosses, at its distance along the ray.
  var crossed: seq[tuple[t: float, index: int]] = @[]
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
      crossed.add((t, i))
      break
  # Walk the crossed bodies in ray order (index breaks exact ties, so the
  # walk is deterministic); the first body that does not duck is the hit.
  crossed.sort()
  for candidate in crossed:
    let targetTrench = sim.playerTrench(candidate.index)
    if targetTrench >= 0 and targetTrench != shooterTrench and
        sim.rng.rand(99) < TrenchMissPct:
      continue
    return candidate.index

type PendingGunShot = object
  shooterIndex: int
  targetIndex: int
  headingBrads: int
  actionId: int64

proc selectGunShot(sim: var SimServer, shooterIndex: int): PendingGunShot =
  ## Selects a target and snapshots the trigger metadata before any
  ## simultaneous shot can kill and reset another shooter. (`var` because
  ## target selection rolls the trench duck on the sim RNG.)
  let
    shooter = sim.players[shooterIndex]
    headingBrads =
      if shooter.windupBrads >= 0: shooter.windupBrads
      else: shooter.aimBrads
    triggerTick =
      if shooter.windupBrads >= 0:
        sim.tickCount - sim.config.fireWindupTicks
      else:
        sim.tickCount
  PendingGunShot(
    shooterIndex: shooterIndex,
    targetIndex: sim.selectFireTarget(shooterIndex),
    headingBrads: headingBrads,
    actionId: sim.eventActionId(shooterIndex, GunAction, triggerTick)
  )

proc applyFire(sim: var SimServer, shot: PendingGunShot) =
  ## Applies one selected shot: cooldown, tracer, and the kill. The target
  ## may already have died to another shot this tick; the shot still lands
  ## (tracer and all) but only an alive target yields a kill.
  let
    shooterIndex = shot.shooterIndex
    targetIndex = shot.targetIndex
    shooter = sim.players[shooterIndex]
    (ux, uy) = aimVector(shot.headingBrads)
    sx = shooter.x + CollisionW div 2
    sy = shooter.y + CollisionH div 2
  # GV26: heart carriers fire at CarrierFireSlowdown (same 3x as shields);
  # Trench occupants fire at TrenchFireSlowdown (config-gated). Every slowdown
  # composes by MAX, never the product.
  var cooldownScale = 1
  if shooter.hasShield or shooter.carryingFlag:
    cooldownScale = max(ShieldFireSlowdown, CarrierFireSlowdown)
  if sim.playerTrench(shooterIndex) >= 0:
    cooldownScale = max(cooldownScale, TrenchFireSlowdown)
  sim.players[shooterIndex].fireCooldown =
    sim.config.fireCooldownTicks * cooldownScale
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
    actionId = shot.actionId,
    headingBrads = shot.headingBrads
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
    var
      lastClear = 0
      wallX = 0
      wallY = 0
      struckWall = false
    for step in 1 .. maxRange:
      let
        rx = sx + int(round(ux * float(step)))
        ry = sy + int(round(uy * float(step)))
      if sim.isWall(rx, ry):
        struckWall = true
        wallX = rx
        wallY = ry
        break
      lastClear = step
    ex = sx + int(round(ux * float(lastClear)))
    ey = sy + int(round(uy * float(lastClear)))
    # Paint that MISSES every cog carries on until it hits geometry, and dries
    # there for the rest of the match. The mark goes on the WALL PIXEL it
    # struck — not the last clear pixel in front of it, which would leave the
    # paint hanging on the floor beside the wall it visibly hit. A shot that
    # simply ran out of range hit nothing and marks nothing.
    if struckWall:
      let (stainX, stainY) = sim.seatInWall(wallX, wallY, ux, uy)
      sim.addPaintStain(stainX, stainY, shooter.color, onWall = true)
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
        actionId = shot.actionId,
        headingBrads = shot.headingBrads,
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
        # NO terrain stain here: a paintball that connects spends its paint ON
        # THE COG (the splat above). Only shots that MISS reach terrain and
        # mark it — that is the whole fiction, and staining hit sites too made
        # the arena read as painted wherever cogs merely stood.
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
      actionId = shot.actionId,
      headingBrads = shot.headingBrads,
      distance = hypot(float(ex - sx), float(ey - sy))
    )

proc tryFire*(sim: var SimServer, shooterIndex: int) =
  ## Fires one shot immediately (the single-shooter path).
  if not sim.canFire(shooterIndex):
    return
  sim.applyFire(sim.selectGunShot(shooterIndex))

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
  ## the radius — teammates and the thrower included. A trench changes the
  ## damage, not the radius: GrenadeTrenchDamage for a victim sharing the
  ## landing trench, GrenadeTrenchSplashDamage for a victim in any other
  ## trench, GrenadeDamage for anyone in the open.
  # Color the splat by the thrower's TEAM (not their individual slot color), so
  # a landing reads as that team's paint-bomb — and the sprite id stays within
  # the two team-color slots, never colliding with the tracer pool.
  let
    legacyThrowerIndex = sim.legacyGrenadeThrowerIndex(grenade)
    throwerSlot = sim.grenadeThrowerSlot(grenade)
    throwerIndex = sim.playerIndexForSlot(throwerSlot)
    throwerColor = teamColor(sim.teamForSlot(throwerSlot))
    landingTrench = trenchIndexAt(grenade.tx, grenade.ty)
  sim.recentBlasts.add BlastFx(
    x: grenade.tx, y: grenade.ty, tick: sim.tickCount, color: throwerColor,
    trenchLanding: landingTrench >= 0
  )
  # A paint bomb repaints the ground it lands on permanently: a cluster of
  # dried stains across the blast footprint, so a contested chokepoint that
  # eats grenades ends the match visibly coated. Offsets are fixed (and each
  # stain re-hashes its own site) so a replay rebuilds the identical cluster.
  # A trench-trapped blast keeps its stains inside the pit: offsets that
  # would land outside the landing trench's own square are simply skipped.
  const stainRing = [(0, 0), (-26, -14), (24, -20), (30, 12),
                     (-18, 24), (6, 32), (-32, 4), (14, -32)]
  for (ox, oy) in stainRing:
    let
      bx = grenade.tx + ox
      by = grenade.ty + oy
    if bx < 0 or by < 0 or bx >= MapWidth or by >= MapHeight:
      continue
    if landingTrench >= 0 and not inRect(bx, by, ArenaTrenches[landingTrench]):
      continue
    sim.addPaintStain(bx, by, throwerColor)
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
      # GV30: the blast tests the SOLID BODY BOX (±PlayerHalf), not the bare
      # position point — a cog whose footprint touches the circle is caught,
      # the same rule the gun's bullet corridor already uses (BulletHalfWidth
      # sampled across ±PlayerHalf). Circle-vs-box is the distance from the
      # burst to the NEAREST point of the box, so on-axis reach becomes
      # GrenadeBlastRadius + PlayerHalf.
      nearX = max(0, abs(px - grenade.tx) - PlayerHalf)
      nearY = max(0, abs(py - grenade.ty) - PlayerHalf)
    if nearX * nearX + nearY * nearY > radiusSq:
      continue
    # A trench traps or shields a blast: a victim caught in the SAME trench
    # the grenade landed in takes amplified damage (nowhere to duck), a
    # victim in any OTHER trench takes reduced splash, and a victim outside
    # every trench takes the ordinary open-field amount.
    let
      victimTrench = trenchIndexAt(px, py)
      dmg =
        if victimTrench < 0: GrenadeDamage
        elif victimTrench == landingTrench: GrenadeTrenchDamage
        else: GrenadeTrenchSplashDamage
      # Read the bubble BEFORE absorbDamage drains shieldHp: a bubble that eats
      # the blast keeps the body clean, exactly as with a paintball (see the
      # gun's damage site).
      bubbleUp = sim.players[i].hasShield and sim.players[i].shieldHp > 0
      blocked = sim.absorbDamage(i, dmg)
    if bubbleUp:
      # The bubble itself blinks and dents toward the burst, so an absorbed
      # blast reads as absorbed instead of leaving no feedback at all.
      sim.bubbleImpacts.add BubbleImpactFx(
        playerIndex: i,
        tick: sim.tickCount,
        angleBrads: bradsOfVector(grenade.tx - px, grenade.ty - py)
      )
    else:
      # A paint-bomb blast marks everyone caught in it — stamp so the EYES-PiP
      # visor splat fires for this paint hit (gun/grenade; spray stamps its own).
      sim.players[i].paintHitTick = sim.tickCount
    sim.emitEvent(
      Damage, source = throwerIndex, target = i, weapon = "grenade",
      amount = dmg, hp = max(0, sim.players[i].hp),
      blocked = blocked,
      x = float(px), y = float(py), sourceSlot = throwerSlot
    )
    if sim.collectEvents:
      damages.add sim.eventDamage(
        i,
        dmg,
        max(0, sim.players[i].hp),
        blocked
      )
    # Floating damage number for the blast's HP loss (cosmetic, not in gameHash).
    sim.damagePops.add DamageFx(
      x: px, y: py, tick: sim.tickCount,
      amount: dmg, color: sim.players[i].color
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
          amount = dmg, x = float(px), y = float(py),
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
  var shots: seq[PendingGunShot] = @[]
  for shooterIndex in shooters:
    if sim.canFire(shooterIndex):
      shots.add(sim.selectGunShot(shooterIndex))
  for shot in shots:
    sim.applyFire(shot)

proc tryPickupFlags*(sim: var SimServer, playerIndex: int) =
  ## Lets a living player steal ANY enemy team's flag off its pedestal by
  ## touch. A player's own flag cannot be interacted with by their own team.
  ## Ties (two pedestals in touch range at once — impossible on real maps)
  ## resolve in enum order, deterministically.
  if not sim.players[playerIndex].alive or sim.players[playerIndex].carryingFlag:
    return
  let
    px = sim.players[playerIndex].x + CollisionW div 2
    py = sim.players[playerIndex].y + CollisionH div 2
    rangeSq = FlagPickupRange * FlagPickupRange
  for flagTeam in sim.teams():
    if flagTeam == sim.players[playerIndex].team:
      continue
    if sim.flags[flagTeam].carrier >= 0:
      continue
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
      return

proc updateFlags(sim: var SimServer) =
  ## Keeps each carried flag glued to its carrier; a carrier that stops
  ## carrying for any reason other than capture sends the flag straight back
  ## to its own pedestal.
  for team in sim.teams():
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
    # CLIMBING OUT of a trench is slow; dropping in and moving around it
    # are not. While the center is inside a pit, each axis whose motion
    # points AWAY from the pit's center — up that wall — is capped at 1/5
    # speed and accel, and outward momentum is shed to the cap. Motion
    # into, across, and around the pit runs at full speed.
    trench = sim.playerTrench(playerIndex)
    slowSpeed = maxSpeed div TrenchSpeedDivisor
    slowAccel = max(1, accel div TrenchSpeedDivisor)
  var
    posBoundX = maxSpeed
    negBoundX = -maxSpeed
    posBoundY = maxSpeed
    negBoundY = -maxSpeed
  if trench >= 0:
    let
      pit = ArenaTrenches[trench]
      relX = (player.x + CollisionW div 2) - (pit.x + pit.w div 2)
      relY = (player.y + CollisionH div 2) - (pit.y + pit.h div 2)
    if relX > 0: posBoundX = slowSpeed
    elif relX < 0: negBoundX = -slowSpeed
    if relY > 0: posBoundY = slowSpeed
    elif relY < 0: negBoundY = -slowSpeed
    player.velX = clamp(player.velX, negBoundX, posBoundX)
    player.velY = clamp(player.velY, negBoundY, posBoundY)

  if inputX != 0:
    let accelX =
      if trench >= 0 and
          ((inputX > 0 and posBoundX == slowSpeed) or
           (inputX < 0 and negBoundX == -slowSpeed)):
        slowAccel
      else:
        accel
    player.velX = clamp(
      player.velX + inputX * accelX,
      negBoundX,
      posBoundX
    )
  else:
    player.velX =
      (player.velX * sim.config.frictionNum) div sim.config.frictionDen
    if abs(player.velX) < sim.config.stopThreshold:
      player.velX = 0

  if inputY != 0:
    let accelY =
      if trench >= 0 and
          ((inputY > 0 and posBoundY == slowSpeed) or
           (inputY < 0 and negBoundY == -slowSpeed)):
        slowAccel
      else:
        accel
    player.velY = clamp(
      player.velY + inputY * accelY,
      negBoundY,
      posBoundY
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
  # classic: zero-sum by construction — the winning team scores +1 per losing
  # team, each losing team -1. Classic 2-team play is +1/-1; a 4-team ffa win
  # pays the winner +3 and each loser -1.
  # pot: every team antes one point, so the pot is the team count and the
  # winning team takes all of it; the losing teams split the forfeit evenly
  # (integer division, so a 4-team pot of 4 costs each of the three losers 1).
  # 2 teams pay +2/-2, 4 teams pay +4/-1/-1/-1.
  let loserTeams = sim.gameMap.teamCount() - 1
  let winReward =
    if sim.config.scoring == PotScoring:
      sim.gameMap.teamCount()
    else:
      WinReward * loserTeams
  let lossReward =
    if sim.config.scoring == PotScoring:
      -(sim.gameMap.teamCount() div loserTeams)
    else:
      LossReward
  var awardedAccounts = newSeq[bool](sim.rewardAccounts.len)
  for i in 0 ..< sim.players.len:
    let accountIndex = sim.rewardAccountForPlayer(i)
    if awardedAccounts.len < sim.rewardAccounts.len:
      awardedAccounts.setLen(sim.rewardAccounts.len)
    if accountIndex >= 0 and accountIndex < awardedAccounts.len:
      awardedAccounts[accountIndex] = true
    if sim.players[i].team == winner:
      sim.addReward(i, winReward)
      sim.recordGameWin(i)
    else:
      sim.addReward(i, lossReward)
  for i in 0 ..< sim.rewardAccounts.len:
    if i < awardedAccounts.len and awardedAccounts[i]:
      continue
    if not sim.rewardAccounts[i].hasTeam:
      continue
    if sim.rewardAccounts[i].team == winner:
      sim.rewardAccounts[i].reward += winReward
      sim.rewardAccounts[i].won = true
      inc sim.rewardAccounts[i].wins[sim.rewardAccounts[i].team]
    else:
      sim.rewardAccounts[i].reward += lossReward

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

proc flagCarryProgress*(sim: SimServer, flagTeam: Team): int =
  ## Returns how far one team's STOLEN flag has been advanced from its
  ## pedestal toward its carrier's home; 0 while it sits home. (0.7.0
  ## relabels the flag a "heart" in art/copy, but the carry-to-home
  ## mechanic is unchanged.) Sides maps keep the classic x-displacement
  ## measure; corner and plus layouts use straight-line displacement.
  let flag = sim.flags[flagTeam]
  if flag.carrier < 0:
    return 0
  let
    carrierTeam = sim.players[flag.carrier].team
    home = sim.gameMap.flagHome(flagTeam)
  let progress =
    case sim.gameMap.layout
    of layoutSides:
      if carrierTeam == Red:
        home.x - flag.x
      else:
        flag.x - home.x
    of layoutCorners, layoutPlus:
      let
        anchor = sim.gameMap.teamAnchor(carrierTeam)
        d0 = sqrt(float(distSq(home.x, home.y, anchor.x, anchor.y)))
        d = sqrt(float(distSq(flag.x, flag.y, anchor.x, anchor.y)))
      int(d0 - d)
  max(0, progress)

proc teamFlagProgress*(sim: SimServer, team: Team): int =
  ## Returns how far this team has advanced a stolen enemy flag toward its
  ## own home; 0 when no enemy flag is on one of its players' backs.
  for flagTeam in sim.teams():
    if flagTeam == team:
      continue
    let flag = sim.flags[flagTeam]
    if flag.carrier < 0 or sim.players[flag.carrier].team != team:
      continue
    result = max(result, sim.flagCarryProgress(flagTeam))

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
  # Capture: a living carrier bringing an enemy flag into their own home
  # capture zone (deliberately no own-flag-must-be-home precondition).
  for flagTeam in sim.teams():
    let carrierIndex = sim.flags[flagTeam].carrier
    if carrierIndex < 0 or carrierIndex >= sim.players.len or
        not sim.players[carrierIndex].alive:
      continue
    let
      carrier = sim.players[carrierIndex]
      zone = sim.captureZone(carrier.team)
      cx = carrier.x + CollisionW div 2
      cy = carrier.y + CollisionH div 2
    if zone.inCaptureZone(cx, cy):
      sim.recordCapture(carrierIndex)
      sim.emitEvent(
        Capture, source = carrierIndex,
        x = float(cx), y = float(cy)
      )
      sim.logGameEvent(
        teamText(carrier.team) & " captured the " & teamText(flagTeam) & " heart"
      )
      sim.finishGame(carrier.team)
      return
  # Wipe: the game ends when at most one team still has live players — the
  # survivor wins, and a mutual wipe is a draw. A 4-team game continues
  # while two or more teams stand; a wiped team just stays out. Classic
  # 2-team behavior is the two-team case of the same rule.
  var
    aliveCount = 0
    lastAlive = Red
  for team in sim.teams():
    if sim.teamHasLivePlayers(team):
      inc aliveCount
      lastAlive = team
  if aliveCount == 1:
    sim.finishGame(lastAlive)
  elif aliveCount == 0:
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

## ---------------------------------------------------------------------------
## Spinning center diamonds — LIVE geometry (GV28).
## The art turns them, so the sim turns them too: what a player sees is what
## blocks their feet, their bullets, and their eyes. Only the sixteen frames of
## a quarter turn exist (a diamond is 4-fold symmetric), and only the pixels
## inside each diamond's circumscribed square can ever change, so a frame
## advance restamps ~8 small boxes — not the map.
## ---------------------------------------------------------------------------

proc initDiamondPatches(sim: var SimServer) =
  ## Snapshots the diamond-free collision masks around each spinning diamond.
  ## loadMapLayers already baked them WITHOUT the diamonds, so this captures
  ## the neighbours (a stub, the border) that must survive every restamp.
  sim.diamondPatches = @[]
  for spot in AnimatedDiamonds:
    let
      pad = spot.radius + 1
      x0 = max(0, spot.cx - pad)
      y0 = max(0, spot.cy - pad)
      x1 = min(MapWidth, spot.cx + pad + 1)
      y1 = min(MapHeight, spot.cy + pad + 1)
    var patch = DiamondPatch(
      x0: x0, y0: y0, w: x1 - x0, h: y1 - y0,
      frame: -1                       # nothing stamped yet.
    )
    patch.baseWall = newSeq[bool](patch.w * patch.h)
    for py in 0 ..< patch.h:
      for px in 0 ..< patch.w:
        let index = mapIndex(patch.x0 + px, patch.y0 + py)
        patch.baseWall[py * patch.w + px] = sim.wallMask[index]
    sim.diamondPatches.add patch
  ## Pair up overlapping windows. Without this a restamp of one diamond would
  ## write `base or its own stone` over a pixel its neighbour also occupies,
  ## erasing the neighbour's stone until the neighbour happened to restamp —
  ## and applyDiamondGeometry skips a diamond whose frame has not advanced, so
  ## "the neighbour restamps too" is not guaranteed.
  for i in 0 ..< sim.diamondPatches.len:
    for j in 0 ..< sim.diamondPatches.len:
      let a = sim.diamondPatches[i]
      let b = sim.diamondPatches[j]
      if a.x0 < b.x0 + b.w and b.x0 < a.x0 + a.w and
          a.y0 < b.y0 + b.h and b.y0 < a.y0 + a.h:
        sim.diamondPatches[i].neighbours.add j

proc refreshFovCells(sim: var SimServer, x0, y0, x1, y1: int) =
  ## Rebuilds the fog occlusion cells covering one map box from the live wall
  ## mask, on the same rule as buildFovBlocked (opaque when at least half the
  ## cell is wall) and with the same window exemption — glass never occludes.
  ##
  ## The glass test reads the precomputed windowMask rather than calling
  ## isArenaWindowPixel: that proc scans all ~70 ArenaObstacles twice per
  ## pixel, and this runs over ~41k pixels every time the spin advances. Doing
  ## it live cost ~5.4 ms per frame advance — more than three whole ticks —
  ## for a fact that never changes after the bake.
  let
    gx0 = clamp(x0 div FovCellSize, 0, FovGridW - 1)
    gx1 = clamp((x1 - 1) div FovCellSize, 0, FovGridW - 1)
    gy0 = clamp(y0 div FovCellSize, 0, FovGridH - 1)
    gy1 = clamp((y1 - 1) div FovCellSize, 0, FovGridH - 1)
  for gy in gy0 .. gy1:
    for gx in gx0 .. gx1:
      var
        walls = 0
        pixels = 0
      for py in gy * FovCellSize ..< min((gy + 1) * FovCellSize, MapHeight):
        for px in gx * FovCellSize ..< min((gx + 1) * FovCellSize, MapWidth):
          let index = mapIndex(px, py)
          inc pixels
          if sim.wallMask[index] and not sim.windowMask[index]:
            inc walls
      sim.fovBlocked[fovCellIndex(gx, gy)] = walls * 2 >= pixels

proc stampDiamondPatch(sim: var SimServer, index, frame: int) =
  ## Writes one diamond's rotated footprint into the movement, bullet, and
  ## vision masks: base OR stone, never a differential against the previous
  ## frame, so a restamp can neither leak old stone nor erase a neighbour.
  ## The OR runs over every diamond sharing this window, each at ITS OWN
  ## current frame, so the write is idempotent and order-independent.
  sim.diamondPatches[index].frame = frame
  let
    x0 = sim.diamondPatches[index].x0
    y0 = sim.diamondPatches[index].y0
    w = sim.diamondPatches[index].w
    h = sim.diamondPatches[index].h
  ## This runs ~4k pixels per window per frame advance, so the lone-diamond
  ## case — every window on both authored arenas — gets a loop with the shape
  ## in locals and no allocation. Resolving it out of a seq instead costs
  ## roughly a quarter of a tick.
  template stampLoop(covers: untyped) =
    for py in 0 ..< h:
      for px in 0 ..< w:
        let
          x {.inject.} = x0 + px
          y {.inject.} = y0 + py
          mapAt = mapIndex(x, y)
        var stone = sim.diamondPatches[index].baseWall[py * w + px]
        if not stone:
          stone = covers
        sim.wallMask[mapAt] = stone
        sim.walkMask[mapAt] = not stone

  if sim.diamondPatches[index].neighbours.len == 1:
    let spot = AnimatedDiamonds[index]
    stampLoop(animatedDiamondCovers(spot, frame, x, y))
  else:
    var live: seq[tuple[spot: tuple[cx, cy, radius: int], frame: int]]
    for other in sim.diamondPatches[index].neighbours:
      live.add((AnimatedDiamonds[other], sim.diamondPatches[other].frame))
    stampLoop(block:
      var hit = false
      for d in live:
        if animatedDiamondCovers(d.spot, d.frame, x, y):
          hit = true
          break
      hit)
  sim.refreshFovCells(x0, y0, x0 + w, y0 + h)

proc applyDiamondGeometry*(sim: var SimServer, tick: int): bool
    {.discardable.} =
  ## Brings every spinning diamond's geometry to the frame `tick` shows.
  ## Returns true when any of them turned. The frame comes from
  ## diamondSpinFrame — the same call the renderer makes — so geometry and art
  ## are the same shape by construction, and a replay re-derives both.
  ##
  ## The bool is not decoration: it is the only signal that someone may now be
  ## standing inside stone. Production code should go through
  ## updateAnimatedDiamonds, which acts on it. The two callers that discard it
  ## (initSimServer, resetToLobby) may only do so because the roster is empty
  ## at that point — any new caller under a live roster owes a push-out.
  ##
  ## Every frame is published BEFORE anything is stamped: a window ORs the
  ## neighbours it overlaps at THEIR current frames, so stamping mid-update
  ## would write a shared pixel against a stale angle.
  ## No allocation on either pass: this runs every tick, and three ticks in
  ## four nothing has moved.
  for index in 0 ..< sim.diamondPatches.len:
    let frame = diamondSpinFrame(AnimatedDiamonds[index].cx, tick)
    if frame == sim.diamondPatches[index].frame:
      continue
    sim.diamondPatches[index].frame = frame
    sim.diamondPatches[index].dirty = true
    result = true
  if not result:
    return
  for index in 0 ..< sim.diamondPatches.len:
    if not sim.diamondPatches[index].dirty:
      continue
    sim.diamondPatches[index].dirty = false
    sim.stampDiamondPatch(index, sim.diamondPatches[index].frame)
  if result:
    ## Vision was computed against the old stone; every viewer re-casts.
    for i in 0 ..< sim.fovCaches.len:
      sim.fovCaches[i].valid = false

proc nearestFreeBody(
  sim: SimServer, playerIndex, x, y: int
): tuple[x, y: int, found: bool] =
  ## The nearest cell where player `playerIndex` can stand without overlapping
  ## any OTHER live body, via the same deterministic expanding ring search as
  ## nearestWalkable. Unlike that one it reports failure instead of handing
  ## back the blocked point it was asked to escape.
  for r in 0 .. max(MapWidth, MapHeight):
    for dy in -r .. r:
      for dx in -r .. r:
        if r > 0 and abs(dx) != r and abs(dy) != r:
          continue
        let
          nx = x + dx
          ny = y + dy
        if not sim.canOccupy(nx, ny):
          continue
        var clear = true
        for j in 0 ..< sim.players.len:
          if j == playerIndex or not sim.players[j].alive:
            continue
          if max(abs(sim.players[j].x - nx), abs(sim.players[j].y - ny)) <=
              PlayerSolidSpan:
            clear = false
            break
        if clear:
          return (nx, ny, true)
  (x, y, false)

proc sweptByDiamond(sim: SimServer, px, py: int): bool =
  ## True when any pixel of the player box at (px, py) is inside a spinning
  ## diamond's CURRENT footprint — i.e. the stone moved onto them, rather than
  ## their being unable to stand for some unrelated reason.
  for spot in AnimatedDiamonds:
    let frame = diamondSpinFrame(spot.cx, sim.tickCount)
    for dy in -PlayerHalf .. PlayerHalf:
      for dx in -PlayerHalf .. PlayerHalf:
        if animatedDiamondCovers(spot, frame, px + dx, py + dy):
          return true
  false

proc pushPlayersOutOfDiamonds(sim: var SimServer) =
  ## A turning diamond can sweep over someone hugging its edge. Standing
  ## inside stone would make a player unshootable from one side and unable to
  ## walk out, so the sweep displaces them to the nearest free floor. The ring
  ## search is deterministic, so replays and clients agree.
  ##
  ## Players are displaced in index order and each lands clear of every other
  ## live body, so two players caught by the same sweep cannot be handed the
  ## same pixel — overlapping bodies are a state the rest of the game does not
  ## allow (tests/test_player_collision.nim).
  for i in 0 ..< sim.players.len:
    if not sim.players[i].alive:
      continue
    let
      px = sim.players[i].x
      py = sim.players[i].y
    if sim.canOccupy(px, py):
      continue
    if not sim.sweptByDiamond(px, py):
      continue
    let free = sim.nearestFreeBody(i, px, py)
    if free.found:
      sim.placePlayer(i, free.x, free.y)
    else:
      ## No standable floor anywhere on the map. Unreachable on every shipped
      ## map (measured: the whole sweep displaces by at most 2 px), but
      ## leaving someone embedded in stone is a silent, self-perpetuating
      ## trap — send them to their protected home pocket, and say so.
      sim.logGameEvent(
        "diamond sweep found no free floor for player " & $i & "; sent home")
      sim.resetPlayerToHome(i)

proc updateAnimatedDiamonds*(sim: var SimServer) =
  ## One tick of diamond rotation: geometry first, then anyone it engulfed.
  if sim.applyDiamondGeometry(sim.tickCount):
    sim.pushPlayersOutOfDiamonds()

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
  ##
  ## Which pixels are glass is fixed by the bake and never moves, so it is
  ## resolved ONCE here into windowMask. refreshFovCells re-derives occlusion
  ## for the boxes a turning diamond touches and reads that mask instead of
  ## re-running the O(obstacles) predicate per pixel. (Glass is never part of
  ## a spinning diamond — windows are stub shapes out on column 1 — so a live
  ## diamond can add wall over a window pixel but can never create or destroy
  ## one.)
  result.windowMask = newSeq[bool](MapWidth * MapHeight)
  var opaqueMask = result.wallMask
  block:
    let
      cx = result.gameMap.center.x
      cy = result.gameMap.center.y
    for y in 0 ..< MapHeight:
      for x in 0 ..< MapWidth:
        let index = mapIndex(x, y)
        if isArenaWindowPixel(x, y, cx, cy):
          result.windowMask[index] = true
          opaqueMask[index] = false
  result.fovBlocked = buildFovBlocked(opaqueMask)
  ## The bake left the spinning diamonds OUT of every collision layer; snapshot
  ## that diamond-free ground truth, then stamp tick 0's rotation over it. From
  ## here the masks track the art (updateAnimatedDiamonds, every step).
  result.initDiamondPatches()
  discard result.applyDiamondGeometry(0)   # no roster yet: nobody to push out.
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
  ## Rewind the spin BEFORE anything snaps to walkable floor. The pickup
  ## resets below all nudge their spawns through nearestWalkable, which reads
  ## the live walk mask — if the diamonds were still stamped at the frame the
  ## last game ended on, a pickup could be nudged clear of stone that is about
  ## to move and land inside the stone the new game starts with. (Safe to run
  ## with the roster already emptied above: no one is left to be engulfed, so
  ## the displacement pass this returns true for has nothing to do.)
  sim.tickCount = 0
  discard sim.applyDiamondGeometry(0)
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
  sim.paintStains = @[]
  sim.diamondStains = @[]
  sim.damagePops = @[]
  sim.nextJoinOrder = 0
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
        sim.players[i].aimBrads = sim.gameMap.spawnAimBrads(sim.players[i].team)
        sim.players[i].flipH = sim.gameMap.spawnFlipH(sim.players[i].team)
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

  # The center diamonds turn BEFORE anything moves or fires this tick, so
  # movement, bullets, and vision all resolve against the geometry the tick
  # renders — never against last tick's stone.
  sim.updateAnimatedDiamonds()

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
