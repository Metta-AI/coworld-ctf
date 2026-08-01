## The sim's shared vocabulary: the core constants (including GameVersion
## and its changelog), the gameplay/wire types, the process-wide map
## dimension globals, and the pure helpers both sides of every seam need —
## split out of sim.nim (docs/plans/2026-08-01-sim-split.md) so the leaf
## modules (rig_art, arena, map_art, sim_config, sim_state, roster) share
## them without importing gameplay. Leaf modules may declare their own
## section-local consts/types; anything two modules need lives here.
##
## MOVED VERBATIM from sim.nim: SimServer and friends are flatty-serialized
## POSITIONALLY into replay keyframes, so declaration/field order here is
## wire format — reorder nothing without a GameVersion bump.

import
  std/[math, random],
  bitworld/pixelfonts,
  bitworld/server,
  pixie

const
  GameName* = "ctf"
  GameVersion* = "33"  ## GV33 (dead-team rule): A DEAD TEAM'S HEART LEAVES
                       ## PLAY. A team wiped from the field (no live player
                       ## and no lives left) has its heart retired on the
                       ## spot exactly like a captured one — including a
                       ## heart riding an enemy carrier's back, which drops
                       ## from the carrier (freeing their speed and fire
                       ## rate) instead of lingering as a live-looking
                       ## objective nobody can score. Retired hearts also
                       ## stop DRAWING entirely (GV32 left a captured heart
                       ## lying flat where it fell): a dead team keeps its
                       ## dim pedestal, but no heart anywhere on the board.
                       ## The retire flips hashed flag state on wipes, so
                       ## GV32 replays do not re-simulate.
                       ##
                       ## GV32 (4ffa rule): A CAPTURE ELIMINATES, THE LAST
                       ## TEAM STANDING WINS. Capturing a heart no longer
                       ## ends the game outright: the captured team is
                       ## eliminated on the spot (every player dies with no
                       ## respawn) and its heart leaves play where it was
                       ## captured. The game ends when at most one team
                       ## still stands — a 4-team winner has to capture all
                       ## three rival hearts or outlive the field. Classic
                       ## 2-team play is unchanged in outcome (eliminating
                       ## the only rival ends the game on the first
                       ## capture), but the end-state differs (losers dead,
                       ## heart retired), so GV31 replays do not re-simulate.
                       ##
                       ## GV31 (operator rule): WEAPONS HIT BODIES, NOT
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
  SpriteSheetAsepritePath* = "data/spritesheet.aseprite"
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
  ## Draw offset for the soldier: place the canvas so its center lands on
  ## the player position (canvas center = the body pivot).
  SoldierDrawOff* = SoldierCanvas div 2
  MotionScale* = 256
  Accel* = 76
  FrictionNum* = 144
  FrictionDen* = 256
  MaxSpeed* = 704
  StopThreshold* = 8
  MovementSlideMaxScan* = 3
  PlayerSolidSpan* = 2 * PlayerHalf  ## centers this close (Chebyshev) means
                                     ## two player footprints overlap.
  PlayerBouncePct* = 40       ## restitution of player-player collisions, in
                              ## percent: 0 = a dead-stop shove, 100 = a
                              ## perfectly elastic billiard bounce.
  TargetFps* = 24
  PlaybackSpeeds* = [1, 2, 3, 4, 8, 16]
    ## Replay/live playback speed steps (as multiples of real time). Lives in
    ## sim (not replays) so every layer that must agree with the top speed —
    ## the transport keymap, global.nim's cog-drive smoothing window, the JS
    ## clients' wire constants — derives from ONE table.
  SpaceColor* = 0'u8
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
  MaxPlayers* = 32
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
                              ## zones clear of the center ring ON THE
                              ## STANDARD 1235-WIDE FIELD — wider boards get
                              ## a proportionally larger ceiling, see
                              ## maxEndzoneRadius.
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

  TextLineHeight* = 7
  MapSpriteId* = 1
  MapObjectId* = 1
  MapLayerId* = 0
  MapLayerType* = 0
  ScoreboardLayerId* = 1       ## left roster panel (red; +green on 4-team maps).
  ScoreboardLayerType* = 1     ## top-left anchor.
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
  PlayerObjectBase* = 1000
  SelectedTextObjectId* = 4000
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
    lobbyJoinTimeoutTicks*: int  ## finite matches only: abort the lobby when
                                 ## the roster is still short after this many
                                 ## lobby ticks (0 = wait forever, the
                                 ## pre-existing behavior). The clock runs on
                                 ## lobby ticks, so board bake/setup before
                                 ## the loop starts never eats the budget.
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

  DiamondPatch* = object
    ## Diamond-free wall pixels for one live geometry window. Fields exported
    ## for sim.nim's restamp machinery (stage-1 split); not public API.
    x0*, y0*, w*, h*: int
    frame*: int
    dirty*: bool    ## frame advanced this tick, mask not restamped yet.
    baseWall*: seq[bool]
    neighbours*: seq[int]
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
    ## One team's flag: provably sitting on its home pedestal (carrier == -1),
    ## carried by an enemy player (never loose), or retired and out of play
    ## (captured, carrier == -1, frozen where it left play).
    x*, y*: int
    carrier*: int              ## player index carrying this flag, -1 when home.
    captured*: bool            ## the heart is out of play for the rest of the
                               ## game: captured (GV32), or retired because its
                               ## team has been completely killed (GV33). A
                               ## retired heart is never drawn and cannot be
                               ## stolen.

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
    fovCaches*: seq[PlayerFov]           ## exported for sim.nim (stage-1 split).
    diamondPatches*: seq[DiamondPatch]   ## exported for sim.nim (stage-1 split).
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
    lobbyWaitTimer*: int  ## lobby ticks spent short of minPlayers (live-server
                          ## lobby lifecycle only: not hashed, not in replays).
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


# Team endzone display colors (shared by the map bake and the paint FX).
const
  RedEndzoneColor* = rgba(224, 82, 58, 255)    ## team vermillion (§4).
  BlueEndzoneColor* = rgba(63, 124, 196, 255)  ## team cerulean (§4).
  GreenEndzoneColor* = rgba(69, 168, 94, 255)  ## matches the viewer --green.
  YellowEndzoneColor* = rgba(221, 197, 49, 255)  ## matches the viewer --yellow.
    ## Exported as THE team display colors. The 16-entry `Palette` a sprite's
    ## `color: uint8` indexes is the retro engine palette, and its blue slot
    ## (BlueTeamColor = 13) is a muted lavender (131,118,156) that reads nothing
    ## like the vivid cerulean the soldier art (116,168,255) and the endzone
    ## floor actually show. Any NEW team-colored art should tint from these four
    ## so it matches what a viewer sees on the board.

# Pure aim-angle math (needed on both sides of the art/gameplay split).
proc distSq*(ax, ay, bx, by: int): int =
  let
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy

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


# Team helpers (pure functions over the types/consts above).
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

