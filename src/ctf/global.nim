import
  std/[algorithm, math, os, strutils, tables],
  supersnappy,
  bitworld/pixelfonts, bitworld/profile, bitworld/spriteprotocol, bitworld/server,
  pixie,
  labels, sim

const
  BroadcastChromeSpriteId* = 4090
    ## Reserved 1×1 never-drawn sprite whose LABEL carries the broadcast chrome
    ## JSON (scorebug/clock/scrubber/roster/events). The chrome used to ride a
    ## separate opt-in `TextMessage`; that interactive text channel does NOT
    ## survive a hosted replay (the client→server `hud:on` never routes through
    ## the recorded stream), so hosted the HUD froze at its DOM defaults while
    ## the board — carried on the binary sprite channel — played fine. Smuggling
    ## the chrome through the SAME binary channel the board rides makes it
    ## survive every playback path (live serve, generic client, hosted replay).
  ReplayScrubberSpriteId = 4004
  ReplayScrubberObjectId = 4004
  ReplayScrubberWidth = 84
  ReplayScrubberHeight = 5
  ReplayScrubberTrackY = 2
  ReplayScrubberY = 8
  ReplayPanelHeight = 20
  ReplayCenterBottomLayerId = 8
  ReplayBottomLeftLayerId = 9
  ReplayCenterBottomLayerType = 8
  ReplayBottomLeftLayerType = 4
  ReplayMismatchLayerId = 10
  ReplayMismatchLayerType = 5
  ReplayTickSpriteId = 4002
  ReplayControlsSpriteId = 4003
  ReplayMismatchSpriteId = 4006
  ReplayTickObjectId = 4002
  ReplayControlsObjectId = 4003
  ReplayMismatchObjectId = 4006
  ReplayMismatchMinWidth = 128
  ReplayMismatchPadX = 4
  ReplayMismatchPadY = 3
  ReplayMismatchBgR = 220'u8
  ReplayMismatchBgG = 20'u8
  ReplayMismatchBgB = 20'u8
  ReplayMismatchBgA = 255'u8
  ## Map is emitted as horizontal BANDS, not one sprite. The full arena
  ## (1235×659 RGBA) compresses to ~1.09 MB — a SINGLE sprite-protocol message
  ## that alone exceeds the hosted replay's 1 MiB WebSocket frame limit, so the
  ## viewer closes with 1009 (message too big) and never loads a frame. Splitting
  ## the map into bands keeps every pixel (each band is a crop at its own
  ## y-offset; the client composites them into one seamless map layer) while
  ## making each message a fraction of the cap. Ids 30..(30+bands) and
  ## 40..(40+bands) sit clear of every other pool (layer ids stop at 12, the
  ## next sprite pool is PlayerSpriteBase = 100) for up to 60 bands — enough
  ## for every generated size class (4-team giant = 52). The client's
  ## static-band cache window (broadcast_core.js STATIC_BAND_MAX_ID = 99)
  ## mirrors that 60-band ceiling. Only the override-only colossal class can
  ## exceed it: band 70+'s SPRITE id would collide with PlayerSpriteBase.
  MapBandSpriteBase = 30
  MapBandObjectBase = 40
  MapBandHeight = 192         ## px rows per band — 659/192 ≈ 4 bands (was 96 /
                              ## ~7). Logical rows shrink by boardScale² so each
                              ## band's byte size stays under the 1 MiB cap.
  ScoreboardWidth = 84
  ScoreboardHeight = 116
  ScoreboardY = 2
  ScoreboardRowHeight = 7
  ScoreboardPipX = 2
  ScoreboardPipY = 2
  ScoreboardPipSize = 4
  ScoreboardTextX = 8
  ScoreboardTextSpriteBase = 12000
  ScoreboardTextObjectBase = 12100
  ScoreboardPipSpriteBase = 12200
  ScoreboardPipObjectBase = 12300
  ScoreboardTextColor = 2'u8
  ScoreboardSelectedTextColor = 10'u8
  InterstitialLayerId = 2
  InterstitialLayerType = 5    ## top-center: status text floats over the arena.
  OverheadYOffset = 4          ## px gap between a sprite top and overhead UI.
  HpPipSpriteBase = 820        ## hp bar sprites: 820 + lit-segment count (0..3).
  HpPipObjectBase = 19000      ## hp bar object-id pool: one per player.
  HpBarSegments = 3            ## health shown as 3 fixed thirds, NOT one pip per
                               ## hit point (a 99-hp config would draw a ~296px
                               ## neon ribbon over a 16px sprite — the bar length
                               ## must not scale with the hit-point config).
  HpBarSegW = 4                ## px width of one health segment.
  HpBarSegGap = 1              ## px gap between segments.
  HpBarH = 2                   ## px height of the health bar.
  HpBarWidth = HpBarSegments * HpBarSegW +
    (HpBarSegments - 1) * HpBarSegGap  ## 14px total — sized to the crew sprite.
  IdentityBadgeSpriteBase = 4200 ## Greek identity badges keyed
                                 ## ord(team)*IdentityNames.len + identity:
                                 ## 4200..4231 (clear of the endzone fade crops
                                 ## at 4100..4131).
  IdentityBadgeObjectBase = 19040  ## identity badge object pool: one per
                                   ## player, 19040..19071 (clear of the hp
                                   ## pips at 19000 and impact rings at 19120).
  IdentityBadgeSize = 11         ## px badge disc diameter.
  IdentityGlyphW = 5             ## px width of one hand-drawn Greek glyph.
  IdentityGlyphH = 7             ## px height of one hand-drawn Greek glyph.
  FlagBannerW = 20             ## px width of the carried heart-gem sprite (square).
  FlagBannerH = 20             ## px height of the carried heart-gem sprite (square).
  PlantedFlagScale = 3         ## the HOME heart is drawn this many x bigger so it
                               ## reads as a real objective on the 96px pedestal.
  PlantedFlagW = FlagBannerW * PlantedFlagScale
  PlantedFlagH = FlagBannerH * PlantedFlagScale
  PlantedFlagSpriteBase = 708  ## scaled home-heart sprites: 708..711 by team.
  GameOverIconSpriteBase = 712 ## compact roster-chip soldiers: 712..715 by team.
  GameOverIconSize = 14        ## roster chip footprint (fits the game-over row).
  CarryHeartSpriteBase = 600   ## carried-heart sprites, baked per team×aim so the
                               ## held heart rotates WITH the cog: team×16 aim →
                               ## 600..663 (red 600.., blue 616.., green 632..,
                               ## yellow 648..663) — the 6xx block is otherwise
                               ## free, clear of the flag pools at 700+ and the
                               ## aim dots at 780.
  CarryHeartFwdPx = 12         ## px the carried heart rides FORWARD of the body along
                               ## the aim, so it sits between the head and the arms.
  FlagAuraSpriteBase = 704     ## carrier-glow sprites: 704..707 by team
                               ## (700..703 are the carried flag banners).
  FlagAuraObjectBase = 19200   ## carrier-glow object pool (one per carried flag).
  FlagAuraSize = 26            ## px diameter of the carrier halo.
  ## Heart-taken endzone power-down (broadcast/spectator only): when a team's
  ## heart is stolen (flag.carrier >= 0) that team's endzone crack-glow + capture
  ## line fade out "like the power source is gone", and fade back when it comes
  ## home. The glow is BAKED once into the shared map sprite (also the POV/RL
  ## observation) so it cannot be re-tinted per frame; instead an overlay of the
  ## SAME endzone columns — cropped to the hot-vs-cold diff box, transparent
  ## where the two maps agree — crossfades from the baked-glow crop to a
  ## glow-free crop, drawn just above the map and below every actor. Purely
  ## cosmetic — outside gameHash and untouched in the player POV. Sprite ids
  ## 4100..4131 and object ids 19520..19523 sit clear of every other pool.
  EndzoneFadeSpriteBase = 4100 ## per-(team, stage) fade crops: 4100 +
                               ## ord(team)*GlowFadeStages + stage → 4100..4131.
                               ## Every stage owns an id so the crops can be
                               ## pre-shipped once per connection and the
                               ## event-time ramp is a pure object remap (bytes
                               ## ≈ 0) instead of a ~200 KB sprite resend per
                               ## frame — the burst that stalled WAN replay
                               ## viewers.
  EndzoneFadeObjectBase = 19520  ## one strip overlay per team.
  EndzonePrewarmEveryFrames* = 4  ## drip one fade crop every N frames after
                                 ## connect (~1.2 Mbps for ~2.4 s on classic
                                 ## maps, twice that on 4-team maps) instead
                                 ## of dumping every crop at once.
  GlowFadeStages* = 8          ## crossfade steps; 0 = full glow, 7 = fully cold.
  ## Grenades (0.7.0): a paint-bomb orb PNG shared by three placements plus a
  ## drawn charge ring and blast flash. Sprite ids 840..845 sit above the sound
  ## ring (830) and below the tracer dots (900). Object pools live at 19300+.
  PaintBombPickupSpriteId = 840  ## corner pickup orb (native size).
  PaintBombAirSpriteId = 841     ## in-flight orb (slightly smaller).
  PaintBombCarrySpriteId = 842   ## the "grenade carried" marker over a carrier.
  ThrowTargetSpriteId = 843      ## the charge-time landing ring.
  BlastSpriteBase = 844          ## landing paint-splat sprites, keyed
                                 ## colorIndex*BlastStages+stage. Team colors
                                 ## (Red idx0, Blue idx6) → ids 844..847 and
                                 ## 868..871, clear of tracers at 900.
  TrenchBlastSpriteBase = 848    ## the trench-truncated variant of the same
                                 ## landing splat, same colorIndex*BlastStages+
                                 ## stage keying → ids 848..851 and 872..875:
                                 ## still clear of tracers at 900.
  PaintBombPickupSize = 22       ## px footprint of a corner pickup orb.
  PaintBombAirSize = 16          ## px footprint of the airborne orb.
  PaintBombCarrySize = 10        ## px footprint of the carried marker.
  ThrowTargetSize = GrenadeBlastRadius * 2
    ## px diameter of the throw-target ring: EXACTLY the blast diameter, so
    ## "everything in here gets hit" is literally true (GameVersion 17; the
    ## old 15px ring under-sold the danger zone by ~7x).
  BlastSize = GrenadeBlastRadius * 2 + 4
    ## px footprint of the landing splat: the blast diameter plus a 2px
    ## margin, so the painted burst covers the true damage circle.
  TrenchBlastSize = TrenchSize
    ## px footprint of a blast that landed inside a trench: capped to the
    ## pit's own square (56px) instead of the open-field BlastSize (108px),
    ## so the flash reads as trapped in the pit rather than spilling over
    ## its rim.
  BlastStages = 4                ## landing-splat fade stages across BlastFxTicks.
  PaintBombPickupObjectBase = 19300  ## corner pickups: 19300..19303 (four corners).
  MedKitSpriteId = 1400          ## center med kit pickup (native size);
                                 ## 845 collided with red blast stage 1
                                 ## (BlastSpriteBase 844..847).
  MedKitSize = 26                ## px footprint of a med kit pickup.
  MedKitObjectBase = 19600       ## med kits: 19600..19603 (2 on sides maps,
                                 ## 4 on 4-team maps).
  ShieldSpriteId = 1420          ## endzone shield pickup (native size).
  ShieldCarrySpriteId = 1421     ## the "shield carried" marker over a carrier.
  ShieldSize = 26                ## px footprint of an endzone shield pickup.
  ShieldCarrySize = 12           ## px footprint of the carried shield marker.
  ShieldObjectBase = 19560       ## endzone shields: 19560..19563, one per
                                 ## team — clear of the endzone-fade strips
                                 ## (19520..19523), the med kits (19600+),
                                 ## and the PER-PLAYER carried-shield markers
                                 ## at 19900..19931.
  ShieldCarryObjectBase = 19900  ## carried shield markers: one per player,
                                 ## 19900..19931. Moved off 19620: a 32-wide
                                 ## per-player pool there runs into the plasma
                                 ## arc pickups at 19640.
  ShieldBubbleSpriteId = 1422    ## the protective bubble drawn around a carrier.
  ShieldBubbleSize = 44          ## px bubble diameter (34px soldier body + margin).
  ShieldBubbleLagPx = 6.0        ## px the bubble center trails BEHIND the aim:
                                 ## the soldier canvas pivots on the body+gun
                                 ## unit's center, but the visible team-colored
                                 ## shell sits ~6px behind it (the dark gun
                                 ## leads), so an un-lagged bubble reads
                                 ## off-center around the agent.
  ShieldBubbleObjectBase = 19940 ## carrier bubbles: one per player,
                                 ## 19940..19971 (clear of the map markers at
                                 ## 20000). Moved off 19680: a 32-wide
                                 ## per-player pool there runs into the spray
                                 ## cone FX at 19700.
  ## The bubble shows while the carrier's shield layer (shieldHp) is intact;
  ## sim.nim records the impact FX with the same condition.
  ShieldBubbleDeformBase = 1424  ## blink/dent impact variants keyed
                                 ## bucket*stages+stage: 1424..1487 (clear of
                                 ## tracer heads at 1300..1363 and spray can
                                 ## sprites at 2000).
  ShieldBubbleDeformBuckets = 16 ## impact-angle buckets (16 brads apart, like
                                 ## the soldier rotations).
  ShieldBubbleDeformStages = 4   ## blink/dent ease-back steps across
                                 ## BubbleImpactTicks.
  PlasmaArcPickupSpriteId = 2000
  PlasmaArcCarrySpriteId = 2001
  PlasmaArcFxSpriteBase = 2002   ## cone paint-mist puffs, keyed colorIndex *
                                 ## (stages * pulses) + stage * pulses +
                                 ## pulse: 2002..2385, clear of the replay
                                 ## UI sprites at 4002.
  PlasmaArcFxStages* = 4         ## fade stages across PlasmaArcFxTicks.
  PlasmaArcFxPulses* = 6         ## puffs placed along the cone axis, sized to
                                 ## the local cone width. 6 (was 4) so the
                                 ## overlapping puffs close into a continuous
                                 ## plume instead of beads on a string.
  PlasmaArcPickupSize = 20
  PlasmaArcCarrySize = 10
  PlasmaArcPickupObjectBase = 19640
  PlasmaArcCarryObjectBase = 19660
  PlasmaArcFxObjectBase* = 19700 ## 19700..19891 (32 flashes x 6 pulses),
                                 ## clear of the carried-shield markers at
                                 ## 19900.
  PlasmaArcMaxFlashes = MaxPlayers ## most spray cones drawn at once. Cans are
                                 ## one per team, but a fired cone leaves a
                                 ## few fading per-tick snapshots and respawns
                                 ## let carriers overlap, so size to the
                                 ## player count like every shooter pool.
  RotDiamondSpriteBase = 1401    ## spinning diamond frames: 1401..1416;
                                 ## 850 collided with CorpseSpriteBase.
  RotDiamondObjectBase = 19610   ## spinning center diamonds: 19610..19617;
                                 ## 19360 collided with PaintBombCarryObjectBase.
  PaintBombAirObjectBase = 19320     ## airborne orbs: one per in-flight grenade.
  PaintBombCarryObjectBase = 19360   ## carried markers: one per player.
  ThrowTargetObjectBase = 19400      ## charge rings: one per player.
  BlastObjectBase = 19440            ## blast flashes: one per recent blast.
  ShoutSpriteBase = 22000      ## speech-bubble sprites: one per live shout,
                               ## keyed by the viewer's shoutSlots table (see
                               ## addShouts), clear of the fog runs at 21000
                               ## and map markers at 20000.
  ShoutObjectBase = 19480      ## speech-bubble object pool: one per live shout,
                               ## same slot key as the sprite.
  ShoutMaxCount = MaxPlayers   ## most bubbles drawn at once (one per player:
                               ## applyShout replaces a shouter's live bubble).
  ShoutDwellFrames* = ShoutCooldownTicks  ## min RENDERED board frames each text
                               ## a bubble shows stays up (~1s wall at 24fps).
                               ## Replay playback compresses sim time (speed ×
                               ## the skip-lulls boost, up to 64 ticks per
                               ## frame), so ShoutTicks alone can put a bubble
                               ## on screen for a single frame — a flash of
                               ## random text near a bot. The dwell floors READ
                               ## time in wall frames; at live 1x it changes
                               ## nothing, because applyShout's cooldown already
                               ## spaces texts at least this far apart. Board
                               ## only: player streams are bot observations and
                               ## keep exact sim timing. "Wall" is the frame
                               ## COUNT standing in for real time — nothing
                               ## reads the system clock, so the floor (and its
                               ## tests) is deterministic under any CPU load.
                               ## See addBoardShouts.
  ShoutBubbleZ = 30003         ## just above the name label (30002), so a shout
                               ## reads over the crowd but under the HUD text.
  ShoutPadX = 4                ## px of paper around the text, left and right.
  ShoutPadY = 3                ## px of paper above and below the text.
  ShoutTailH = 4               ## px tail dropping from the pill toward the head.
  ShoutFloat = 13              ## px the tail tip floats above the shouter's head.
  GrenadeMaxAirborne = MaxPlayers  ## most in-flight orbs drawn at once.
  GrenadeMaxBlasts = MaxPlayers    ## most blast flashes drawn at once.
  SoundRingSpriteId = 830      ## the filled landing "sound" ring sprite
                               ## (grenade landings; shots use the impact ring).
  SoundRingSize = 12           ## px diameter of the sound rings.
  SoundRingJitter = 20         ## max px a ring strays from the true spot.
  AimRenderFuzzBrads = 14      ## max brads (±14 ≈ ±19.7°) a soldier sprite's
                               ## gun rotation strays from the true aim in
                               ## PLAYER views — sprites are never aim oracles.
  AimRenderFuzzWindow = 12     ## ticks (~0.5s) an aim-fuzz offset holds before
                               ## re-rolling: too brief to learn, too long to
                               ## average away inside a 5-tick windup.
  ShotImpactSpriteId = 831     ## the hollow shot "impact" ring sprite.
  ShotImpactObjectBase = 19120 ## impact ring object-id pool: 19120..19151
                               ## (one per drawn shot, clear of the flag
                               ## auras at 19200).
  ## A hitscan shot's whole beam appears at once, so the tracer can't literally
  ## move — but it draws as a COMET (the shape that reads as a fired projectile
  ## and is easiest to follow, per ux.replay research): a bright paintball HEAD
  ## at the impact end with a thin trail fading behind it back toward the
  ## shooter, plus a small muzzle flash marking who fired. The eye locks onto
  ## the head and reads the shot's direction from the fade — never a fat tube.
  TracerStages = 4             ## age fade stages (protocol has no per-object alpha).
  MissStagePenalty = 2         ## a missed shot's comet draws this many fade
                               ## stages older: hits stay bright, misses fade.
  TrailBuckets = 6             ## along-beam opacity steps baked into the trail dots.
  TrailFalloff* = 1.6          ## trail brightness = t^this (t: 0 muzzle → 1 impact).
                               ## Exported for the JS wire-constants block.
  TrailMinAlpha = 0.06         ## drop trail dots fainter than this (trims the tail).
  TracerDotSpriteBase = 900    ## trail dots keyed color×stage×bucket: 900..1283.
  TracerDotObjectBase = 24000  ## tracer trail object-id pool (above the fog pool).
  TracerDotSize = 4            ## a THIN trail — ~1/4 a 16px soldier, never a tube.
  TracerDotSpacing = 3         ## px between sampled blobs; < size so they overlap
                               ## into one continuous thin trail, not a dotted line.
  TracerMaxShots = MaxPlayers  ## most tracers drawn at once (one per shooter:
                               ## ShotFxTicks == FireCooldownTicks, so a
                               ## shooter never has two live tracers).
  TracerDotsPerShot = GunRange div TracerDotSpacing + 4  ## dots per full-range shot, plus slack.
  TracerMaxDots = TracerMaxShots * TracerDotsPerShot  ## 11328 ids: 24000..35327 (GV34 gun range).
  MuzzleBloomSpriteBase = 1290 ## per-fade-stage muzzle flash sprites: 1290..1293.
  MuzzleBloomObjectBase = 16800  ## one flash per drawn shot: 16800..16831.
  HitFlashSpriteBase = 1294    ## per-stage struck-target rings: 1294..1297.
  HitFlashStages = 4           ## expanding/fading ring steps over HitFlashTicks.
  HitFlashSize = 34            ## px canvas: rings the 16px soldier body.
  HitFlashObjectBase = 16880   ## struck-target ring pool: 16880..16911. Moved
                               ## off 16840 to make room for the widened
                               ## tracer heads.
  HitFlashMaxCount = MaxPlayers  ## most flash rings drawn at once (hits within
                               ## HitFlashTicks are bounded by the shooters).
  MuzzleBloomSize = 7          ## a small colorless flash marking the shooter.
  TracerHeadSpriteBase = 1300  ## per color-and-fade-stage leading heads: 1300..1363.
  TracerHeadObjectBase = 16840  ## one leading head per drawn shot: 16840..16871.
                                ## Moved off 16820 to make room for the
                                ## widened muzzle blooms.
  TracerHeadSize = 6           ## the bright leading paintball at the impact end.
  SplatterSpriteBase = 16000   ## per color-and-fade-stage splatter sprites: 16000..16063.
  SplatterObjectBase = 17000   ## splatter object-id pool base, above the tracer
                               ## ids: 17000..17063.
  SplatterSize = 13
  SplatterStages = 4           ## fade stages across SplatterFxTicks.
  SplatterMaxCount = MaxPlayers * 2  ## most splatters drawn at once (splatters
                               ## outlive tracers, so keep the old 2x-players
                               ## headroom).
  HitSpriteBase = 16100        ## per-color-and-stage hit-splat sprites: 16100..16163.
  HitSplatSize = 21            ## on-hit paint-splat canvas (~1.3x a 16px player).
  HitSplatCoreR = 6.0          ## px radius of the splat's main wet blob.
  ## --- Permanent dried terrain paint (SPECTATOR/BOARD ONLY) ---
  ## Stains never expire, so unlike every other FX family they are emitted ONCE
  ## and then left on the client forever — the same trick the map bands use
  ## (never tracked in objectIds, so the per-frame delete diff can't reap them).
  ## That makes a thousand decals cost nothing per frame; see addPaintStains.
  StainSpriteBase = 34000      ## ONE sprite per stain: 34000..35199. Not shared
                               ## per color×variant, because each blot is masked
                               ## to the surface it actually hit (see
                               ## buildPaintStainSprite) and that mask depends on
                               ## the map under that exact spot. Lives in the gap
                               ## between the kill pops (..31191) and the rig
                               ## pools (40000..): the 4-team rig legs alone span
                               ## 41000..72679, so anything above 40000 is both
                               ## taken and past the u16 id ceiling.
  DiamondPaintSpriteBase = 35300 ## per-(diamond, frame) painted stone:
                               ## 35300..35427 (8 diamonds x 16 frames). A
                               ## diamond claims ids here only once paint lands
                               ## on it; clean ones keep sharing the 16 plain
                               ## frames at RotDiamondSpriteBase. Only the frame
                               ## currently on screen is ever emitted, so a
                               ## painted diamond costs one sprite per spin
                               ## step, not 16 at once.
  StainObjectBase = 38500      ## one object per stain: 38500..39699, between
                               ## the rig object pools (..38491) and the debug
                               ## pool at 40000. Moved off 33000: the widened
                               ## tracer-dot pool (24000..35327) swallowed it.
  StainVariants = 8            ## distinct blot shapes, picked by the stain's own
                               ## hash so a lane of paint never reads as one
                               ## rubber-stamped sprite repeated.
  StainSize = 27               ## px canvas, ~1.7x a cog body. Sized UP from a
                               ## single-mark read to a coverage read: a match
                               ## lands only a few hundred stains, so at cog size
                               ## they scattered as confetti instead of pooling
                               ## into painted ground.
  StainZ = low(int16) + 2      ## floor decal: above the map bands AND above the
                               ## endzone glow fade (low(int16)+1), below every
                               ## actor. Above the fade because paint lies ON the
                               ## floor while the fade is floor LIGHTING — under
                               ## it, the fade's near-opaque column crop would
                               ## erase every endzone stain whenever that heart
                               ## was out. Must also stay clear of low(int16) so
                               ## the client's static-band cache stays valid (it
                               ## requires every dynamic object to sort strictly
                               ## above the bands).
  DamagePopSpriteBase = 31000  ## floating "-N" damage-number sprites keyed
                               ## color×bucket×stage: 31000..31255 (above tracers).
                               ## The bucket is NOT amount-1: the amounts in
                               ## play (1 shot/grenade-splash, 2 grenade
                               ## open-field, 3 spray, 6 grenade trapped-in-
                               ## trench) are sparse, not a dense 1..N range,
                               ## so damagePopBucket() maps each known amount
                               ## to a small bucket index instead of baking
                               ## one sprite id per distinct hp value. The
                               ## displayed TEXT still shows the real amount
                               ## (see addDamagePops) — only the bucket/sprite
                               ## count is capped.
  DamagePopObjectBase = 38000  ## one drawn damage pop per object: 38000..38031.
                               ## Moved off 31200: the widened tracer-dot pool
                               ## (24000..35327) swallowed it.
  DamagePopStages = 4          ## alpha fade stages across DamageFxTicks.
  DamagePopMaxCount = MaxPlayers  ## most floating numbers drawn at once.
  DamagePopBucketCount = 4     ## distinct -N sprite buckets reserved per color
                               ## (see damagePopBucket()), not a display clamp.
  DamagePopRisePx = 11         ## px the number floats upward over its full life.
  DamagePopZ = 30006           ## drawn above players, HP bars and name tags.
  KillPopSpriteBase = 31256    ## floating "KO" kill-marker sprites keyed
                               ## color×stage: 31256..31319 (above damage pops).
  KillPopRisePx = 16           ## px the kill marker floats upward over its life.
  ## --- Articulated turret-rig sprite/object id pools (board only) ---
  ## The cog draws as 9 z-stacked segments + a held gun, each its own board object
  ## so the head/arms track AIM while the legs/wheels track MOVEMENT (a true turret
  ## swivel). Sprite pools are generous and lazily baked; they start well clear of
  ## every family above (highest was kill pops ~31191). Bake dims: head = team×16
  ## aim; arms = team×16 aim; legs = team×16 heading×(2·swing+1)×(shorten+1);
  ## wheels = team×16 heading×(2·caster+1).
  RigHeadSpriteBase* = 40000   ## 40000..40127 (2 skins × 4 teams × 16 aim).
                               ## Exported so the sprite-collision audit can
                               ## scope skin-pool checks below the rig pool.
  RigArmSpriteBase = 40200     ## team×2arms×16aim×2reach → 40200..40455.
  RigLegSpriteBase = 41000     ## team×3legs×16head×33swing×5shorten = 7920 ids
                               ## per team → 41000..72679.
  RigWheelSpriteBase = 73000   ## team×3wheels×16head×17caster = 816 ids per
                               ## team → 73000..76263.
  RigGunSpriteBase = 76500     ## team×16 aim → 76500..76563 (held marker + glow).
  RigSpraySpriteBase = 76600   ## team×16 aim → 76600..76663 (held spray can +
                               ## glow): the swap-in art while a cog carries a
                               ## can, sharing the gun's object slot.
  ## Object pools sit clear of the tracer-dot pool (24000..35327) and the
  ## damage/kill pops (38000..38031); rig objects live at 38100+ (32 players
  ## each). Moved off 32000+: the widened tracer-dot pool swallowed that range.
  RigHeadObjectBase = 38100    ## 1 head object per player: 38100..38131.
  RigArmObjectBase = 38140     ## 2 arm objects per player: 38140..38203.
  RigLegObjectBase = 38220     ## 3 leg objects per player: 38220..38315.
  RigWheelObjectBase = 38340   ## 3 wheel objects per player: 38340..38435.
  RigGunObjectBase = 38460     ## 1 gun object per player: 38460..38491.
  ## The retired aim-dot indicator left sprites 780..795 and objects
  ## 18000..18063 unallocated; both ranges are free to reuse.
  PlayerNameSpriteBase = 7000
  PlayerNameObjectBase = 7000
  PlayerNameZ = 30002
  PlayerNameMaxChars = 16
  PlayerNameColor = 2'u8
  TransportIconSize = 6
  TransportIconHeight = 6
  TransportIconCount = 5
  TransportButtonGap = 2
  TransportButtonStride = TransportIconSize + TransportButtonGap
  TransportSpeedX = 0
  TransportSpeedY = 8
  TransportWidth = 108
  TransportHeight = 18
  TransportSpeedGap = 16
  TransportX = 2
  TransportY = 1
  ## Sprite/object id pools (sprites and objects are separate namespaces).
  ## Sprites: team flags 700..703 (FlagSpriteBase), hp pips 820+, tracer
  ## dots 900..963 (color×fade-stage), muzzle blooms 964..967 (stage), tracer
  ## heads 968..1031 (color×stage), aim dots 780..795, identity badges
  ## 4200..4231 (team×identity), self markers 5100..5131, team score text
  ## 12100..12103, splatters 16000..16063, fog runs 21000..21155
  ## (one per run width in cells), map markers 20000. Objects: flags 6500..6503
  ## (map view) / 5009..5012 (player view), team score text 9600..9603,
  ## muzzle blooms 16800..16831, tracer heads 16840..16871, hit flashes
  ## 16880..16911, splatters 17000..17063, identity badges 19040..19071,
  ## map markers 20000, fog runs 21000..23047, tracer dots 24000..35327.
  ## The full board object layout is enforced by the compile-time audit at
  ## the end of this const section (BoardObjectPools).
  ## Player debug sprites and objects use per-player pools at 40000+.
  SpritePlayerFireSpriteId = 5000
  SpritePlayerFireShadowSpriteId = 5001
  SpritePlayerRemainingSpriteId = 5003
  SpritePlayerInterstitialSpriteId = 5006
  SpritePlayerWalkabilitySpriteId = 5007
  SpritePlayerInterstitialObjectId = 5006
  SpritePlayerRemainingObjectId = 5008
  SpritePlayerFlagObjectBase = 5009  ## 5009..5012 by team.
  SpritePlayerWeaponSpriteId = 5020  ## own-weapon HUD text ("weapon gun|arc").
  SpritePlayerWeaponObjectId = 5021
  SpritePlayerOwnAimSpriteId = 5022  ## invisible own-aim readback marker
  SpritePlayerOwnAimObjectId = 5023  ## ("own aim <brads>", player stream only).
  SpritePlayerSelfSpriteBase = 5100  ## white-outlined self soldiers, keyed by
                                     ## skin×rotation: default 5100..5115,
                                     ## crown 5116..5131.
  CorpseSpriteBase = 1500      ## grey dead-soldier sprites, one per team×rot
                               ## per skin: default 1500..1563, crown 1564..1627.
                               ## A corpse must never read as a
                               ## live soldier for a label-scanning ghost
                               ## viewer. Moved off 850: that range overlapped
                               ## the blue paint-blast sprites (868..871).
  FlagObjectBase = 6500        ## 6500..6503 by team.
  ## Per-viewer fog of war: a second zoomable map-sized layer of translucent
  ## dark row-run sprites over the unseen 8px visibility cells. It draws over
  ## the map layer and alpha-blends, dimming everything outside the viewer's
  ## vision. Run sprites are defined lazily, one per run width in cells.
  FogLayerId = 4
  FogRunSpriteBase = 21000
  FogObjectBase = 21000
  FogMaxRuns = 2048            ## fog object pool; overflow drops shortest runs.
  FogAlpha = 160'u8            ## fog dims unseen floor to ~37% brightness.
  ## v7.0 sim renamed the top-left scoreboard layer consts; alias them back to
  ## the names this (v6.0) renderer uses, so the renderer stays byte-identical.
  TopLeftLayerId = ScoreboardLayerId
  TopLeftLayerType = ScoreboardLayerType
  ## Player-view HUD layers (the map layer now spans the whole arena, so the
  ## HUD sits on dedicated screen-corner UI layers).
  HudTopRightLayerId = 5       ## lives counter.
  HudTopRightLayerType = 2
  HudBottomLeftLayerId = 6     ## fire-readiness icon.
  HudBottomLeftLayerType = 4
  PlayerInterstitialLayerId = 7  ## lobby / game-over screens, top-center.
  PlayerInterstitialLayerType = 5
  ## Team kills/deaths scoreboard shown above the field in every view.
  TeamScoreLayerId = 11        ## NOT 8: the replay viewer re-registers layer 8 as its
                               ## center-BOTTOM scrubber panel, which dragged the team
                               ## scoreboard to the bottom of replays.
  TeamScoreLayerType = 5       ## top-center anchor.
  TeamScoreWidth = 132
  TeamScoreGap = 8             ## px between the red and blue halves.
  TeamScoreSpriteBase = 12100  ## one score chip per team: 12100..12103.
  TeamScoreObjectBase = 9600   ## one score chip per team: 9600..9603.
  MapMarkerSpriteBase = 20000
  MapMarkerObjectBase = 20000
  MapMarkerZ = -32767
  ProtocolTextSpriteBase = 9000
  ProtocolTextObjectBase = 9000
  ProtocolTextZ = 30010
  DebugSpriteBase* = 40000     ## 1024 sprite ids per player for debug overlays.
  DebugObjectBase* = 40000     ## 1024 object ids per player for debug overlays.
  DebugPlayerIdStride* = 1024  ## Payload sprite/object ids must stay in
                               ## 0..1023; larger ids alias via modulo.
  DebugOverlayZ* = 29000       ## Above gameplay, below protocol text.
  ProtocolTextColor = 2'u8
  ProtocolGameOverIconObjectBase = 9700
  PlayerColorNames = [
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
  ## --- Board object-id pool audit (compile time) ---
  ## The wire packs object ids as u16 (spriteprotocol addU16), and the
  ## per-frame delete diff reaps by id — so two pools sharing a range is a
  ## silent, game-wide failure (one family's delete sweep eats another's
  ## objects). Every fixed object pool above is listed here as
  ## (name, base, width) and the static block below proves the layout:
  ## no two pools overlap, and nothing crosses the u16 ceiling. Widths for
  ## index-bounded families (map bands, protocol text, map markers) are
  ## generous envelopes, not exact caps.
  U16ObjectIdCeiling = 65535
  BoardObjectPools = [
    ("map bands", MapBandObjectBase, 960),
    ("players (POV view)", PlayerObjectBase, MaxPlayers),
    ("replay UI", ReplayTickObjectId, 5),
    ("player HUD", SpritePlayerInterstitialObjectId, 16),
    ("flags", FlagObjectBase, 4),
    ("player names", PlayerNameObjectBase, MaxPlayers),
    ("protocol text", ProtocolTextObjectBase, 100),
    ("team score", TeamScoreObjectBase, 4),
    ("game-over icons", ProtocolGameOverIconObjectBase, 100),
    ("scoreboard text", ScoreboardTextObjectBase, MaxPlayers + 8),
    ("scoreboard pips", ScoreboardPipObjectBase, MaxPlayers + 8),
    ("muzzle blooms", MuzzleBloomObjectBase, TracerMaxShots),
    ("tracer heads", TracerHeadObjectBase, TracerMaxShots),
    ("hit flashes", HitFlashObjectBase, HitFlashMaxCount),
    ("splatters", SplatterObjectBase, SplatterMaxCount),
    ("hp pips", HpPipObjectBase, MaxPlayers),
    ("identity badges", IdentityBadgeObjectBase, MaxPlayers),
    ("impact rings", ShotImpactObjectBase, TracerMaxShots),
    ("flag auras", FlagAuraObjectBase, 4),
    ("grenade pickups", PaintBombPickupObjectBase, 4),
    ("airborne grenades", PaintBombAirObjectBase, GrenadeMaxAirborne),
    ("grenade carry markers", PaintBombCarryObjectBase, MaxPlayers),
    ("throw-target rings", ThrowTargetObjectBase, MaxPlayers),
    ("blast flashes", BlastObjectBase, GrenadeMaxBlasts),
    ("shout bubbles", ShoutObjectBase, ShoutMaxCount),
    ("endzone fades", EndzoneFadeObjectBase, 4),
    ("endzone shields", ShieldObjectBase, 4),
    ("med kits", MedKitObjectBase, 4),
    ("rot diamonds", RotDiamondObjectBase, 8),
    ("plasma arc pickups", PlasmaArcPickupObjectBase, 4),
    ("plasma arc carry markers", PlasmaArcCarryObjectBase, MaxPlayers),
    ("plasma arc fx", PlasmaArcFxObjectBase,
      PlasmaArcMaxFlashes * PlasmaArcFxPulses),
    ("shield carry markers", ShieldCarryObjectBase, MaxPlayers),
    ("shield bubbles", ShieldBubbleObjectBase, MaxPlayers),
    ("map markers", MapMarkerObjectBase, 1000),
    ("fog runs", FogObjectBase, FogMaxRuns),
    ("tracer dots", TracerDotObjectBase, TracerMaxDots),
    ("damage pops", DamagePopObjectBase, DamagePopMaxCount),
    ("rig heads", RigHeadObjectBase, MaxPlayers),
    ("rig arms", RigArmObjectBase, MaxPlayers * 2),
    ("rig legs", RigLegObjectBase, MaxPlayers * 3),
    ("rig wheels", RigWheelObjectBase, MaxPlayers * 3),
    ("rig guns", RigGunObjectBase, MaxPlayers),
    ("paint stains", StainObjectBase, StainMaxCount),
  ]

static:
  for i in 0 ..< BoardObjectPools.len:
    let (aName, aBase, aWidth) = BoardObjectPools[i]
    doAssert aBase + aWidth - 1 <= U16ObjectIdCeiling,
      "object pool '" & aName & "' crosses the u16 wire ceiling: " &
      $aBase & ".." & $(aBase + aWidth - 1)
    for j in i + 1 ..< BoardObjectPools.len:
      let (bName, bBase, bWidth) = BoardObjectPools[j]
      doAssert aBase + aWidth <= bBase or bBase + bWidth <= aBase,
        "object pools overlap: '" & aName & "' " &
        $aBase & ".." & $(aBase + aWidth - 1) & " and '" & bName & "' " &
        $bBase & ".." & $(bBase + bWidth - 1)
  ## The per-player debug pool (DebugObjectBase, 1024 ids per player) is not
  ## in the table: it must only sit above every gameplay pool. (With 32
  ## players its top ids exceed the u16 ceiling — a pre-existing, debug-only
  ## spill; debug overlays never run in league games.)
  doAssert DebugObjectBase >= StainObjectBase + StainMaxCount,
    "debug object pool must start above the paint stains"

type
  SpriteDefinition = ref object
    spriteId: int
    width: int
    height: int
    label: string
    compressedPixels: seq[uint8]

  DebugOverlay* = object
    sprites*: Table[int, SpritePacketSpriteDef]
    objects*: Table[int, SpritePacketObject]

  ShoutLinger* = object
    ## Render state for one board speech-bubble slot: what the bubble is
    ## currently SHOWING, which may lawfully trail the sim under compressed
    ## replay playback so the text keeps its wall-clock read time
    ## (ShoutDwellFrames). Board-only; bots never see this. See addBoardShouts.
    active*: bool
    team*: Team
    name*: string              ## shouter's anonymous slot letter, resolved
                               ## while the shout was live (the author can
                               ## depart mid-display).
    text*: string              ## the payload on screen — the newest payload
                               ## only once the current one has met its dwell.
    frames*: int               ## advancing rendered frames this text has shown.
    anchorX*, tailTipY*: int   ## last drawn anchor, in 1x map px, so a bubble
                               ## whose shouter died or left keeps its spot.

  GlobalViewerState* = object
    initialized*: bool
    objectIds*: seq[int]
    mouseX*: int
    mouseY*: int
    mouseLayer*: int
    mouseDown*: bool
    selectedJoinOrder*: int
    clickPending*: bool
    povActive*: bool
    povJoinOrder*: int
    povState*: PlayerViewerState
    scrubbingReplay*: bool
    replaySeekTick*: int
    replayCommands*: seq[char]
    momentumSent*: bool          ## full lives-lead series already sent to this viewer.
    fpMapSent*: bool             ## static minimap wall silhouette already sent (EYES PiP tactical map).
    povSelectPending*: int       ## POV slot requested by a `v:<slot>` command.
    endzoneFade*: array[Team, int]  ## per-team endzone glow crossfade stage (0
                                 ## = full glow / heart home, GlowFadeStages-1 =
                                 ## dark / heart taken); ramped ±1 per frame.
    endzonePrewarmFrames*: int   ## frames seen since connect, used to drip the
                                 ## endzone fade crops to this viewer up front.
    cogDrive*: array[MaxPlayers, CogDriveState]  ## per-player segmented-trike
                                 ## animation state (body heading / turnAmt /
                                 ## per-wheel casters), evolved once per frame
                                 ## from velocity. Broadcast-only; see stepCogDrive.
    cogDriveTick*: int           ## sim.tickCount at the last cogDrive step; a
                                 ## non-sequential jump snaps the pose instead of
                                 ## integrating across it (scrub-safe).
    stainsSent*: int             ## how many permanent paint stains this viewer
                                 ## already holds. Stains are append-only and
                                 ## emitted once each (addPaintStains), so this
                                 ## is the incremental cursor into
                                 ## sim.paintStains — never a re-send.
    shoutSlots*: array[ShoutMaxCount, string]  ## slot → owning shouter address
                                 ## ("" = free), so a bubble keeps one wire
                                 ## sprite/object id for its whole life however
                                 ## sim.recentShouts reshuffles; see addShouts.
    shoutLinger*: array[ShoutMaxCount, ShoutLinger]  ## what each claimed slot
                                 ## is showing, aged in RENDERED frames so
                                 ## compressed playback cannot flash a bubble;
                                 ## see addBoardShouts.
    shoutLingerTick*: int        ## sim.tickCount at the last board shout pass:
                                 ## the dwell clock ticks only when playback
                                 ## advanced, and a backward jump (scrub
                                 ## restore) snaps linger state clean.
    spriteDefs: seq[SpriteDefinition]

  PlayerViewerState* = ref object
    initialized*: bool
    objectIds*: seq[int]
    pendingDebugSprites*: seq[seq[uint8]]
    debugSpriteLimitWarned*: bool
    shoutSlots*: array[ShoutMaxCount, string]  ## slot → owning shouter address
                                 ## ("" = free); see GlobalViewerState.shoutSlots.
    spriteDefs: seq[SpriteDefinition]

  ProtocolTextItem = ref object
    spriteId: int
    objectId: int
    x, y, z: int
    color: uint8
    struck: bool
    label: string
    lines: seq[string]

## --- Board render scale (spectator/replay supersampling) ---
## The SPECTATOR/replay stream renders the board at RenderScale× the sim's
## 1235×659 map-pixel space: object placements on the zoomable board layers
## are multiplied by `boardScale`, every board sprite ships at boardScale× its
## logical footprint, and the map viewport announces the scaled size. The sim,
## the gameHash, and the PLAYER observation stream (what bots parse — see
## RULES.md) all stay in 1× map pixels: `boardScale` is 1 except inside the
## non-POV section of buildSpriteProtocolUpdates. Because a scaled sprite is
## exactly boardScale× its logical size, 1×-space centering math like
## `x - Size div 2` lands on the identical screen point after scaling —
## (x - s/2)·k == k·x - (k·s)/2 — so call sites keep computing in map pixels.
const RenderScale* {.intdefine.} = 2
  ## Board supersample factor for the spectator/replay renderer. Build with
  ## -d:RenderScale=1 to reproduce the legacy 1× wire exactly.

var boardScale = 1
  ## Current emission scale. 1 for every player/POV stream; RenderScale inside
  ## the global broadcast/replay board section. Module state (not a param)
  ## because the ~20 emission helpers are shared verbatim between the player
  ## and spectator builders; the two builder entry points own the value.

proc scaleSpritePixels(
  pixels: openArray[uint8],
  width, height, k: int
): seq[uint8] =
  ## Nearest-neighbor integer upscale of a sprite buffer. Accepts the two
  ## wire pixel formats: RGBA (w·h·4 bytes) and 1-byte palette (w·h bytes).
  if k <= 1:
    return @pixels
  let bpp =
    if pixels.len == width * height * 4: 4
    elif pixels.len == width * height: 1
    else:
      raise newException(CtfError,
        "scaleSpritePixels: buffer is neither RGBA nor palette for " &
        $width & "x" & $height & " (len " & $pixels.len & ")")
  result = newSeq[uint8](width * k * height * k * bpp)
  for y in 0 ..< height * k:
    let srcRow = (y div k) * width
    for x in 0 ..< width * k:
      let
        src = (srcRow + x div k) * bpp
        dst = (y * width * k + x) * bpp
      for c in 0 ..< bpp:
        result[dst + c] = pixels[src + c]

var TransportSheet: Sprite

var
  EndzoneColdRgba: seq[uint8]  ## full glow-free map RGBA, lazily built once.
  EndzoneStripCache: array[Team, array[GlowFadeStages, seq[uint8]]]
    ## per-team, per-stage endzone delta crops crossfading the baked-glow floor
    ## toward the cold floor; each baked once and reused for the whole session.
  EndzoneDiffBox: array[Team, tuple[x0, y0, x1, y1: int]]
    ## per-team bounding box (map coords, inclusive) of the pixels that differ
    ## between the baked-glow map and the cold map; x1 < x0 means empty.
  EndzoneDiffBoxReady: array[Team, bool]

var
  boardMapCache: seq[uint8]
  boardColdMapCache: seq[uint8]
    ## Process-wide caches of the boardScale× arena renders (hot + cold). The
    ## arena is fixed per process, so one native bake serves every connection —
    ## same pattern as EndzoneStripCache.

proc ensureBoardMaps(sim: SimServer) =
  ## Fills both native boardScale× arena bakes (hot + cold share one geometry
  ## mask and floor pass — see renderArenaRgbaPair). boardScale > 1 only.
  let expected =
    sim.gameMap.width * boardScale * sim.gameMap.height * boardScale * 4
  if boardMapCache.len != expected or boardColdMapCache.len != expected:
    let pair = renderArenaRgbaPair(sim.gameMap, boardScale)
    boardMapCache = pair.hot
    boardColdMapCache = pair.cold

proc boardScaledMapPixels(sim: SimServer): seq[uint8] =
  ## The NATIVE boardScale× hot arena RGBA (float wall geometry, bilinear
  ## floor, high-res pedestals). boardScale > 1 only.
  sim.ensureBoardMaps()
  boardMapCache

proc boardScaledColdMapPixels(sim: SimServer): seq[uint8] =
  ## The NATIVE boardScale× COLD arena RGBA (glow + capture line omitted,
  ## pedestals dimmed) for the endzone fade overlay. boardScale > 1 only.
  sim.ensureBoardMaps()
  boardColdMapCache

proc endzoneStripBox(gameMap: CtfMap, team: Team):
    tuple[x0, y0, x1, y1: int] =
  ## The inclusive scan box of ONE team's endzone: its capture-zone bounding
  ## box expanded to cover the flag-home pedestal footprint (which pokes
  ## ~28px past the capture line on the inner side — so the crossfade dims
  ## the pedestal disc too, with no lit sliver left behind). Bounding BOTH
  ## axes matters on 4-team maps: two corner zones share an x span, and an
  ## unbounded-y scan would sweep the other team's glow into this team's
  ## diff box, powering both down together. Sides maps reduce to the
  ## classic full-height column. Outside the glow band the hot and cold
  ## maps are identical, so a generous box is a visual no-op.
  let
    pedHalf = PedestalCoverSize div 2
    zone = gameMap.captureZone(team)
    anchor = gameMap.teamAnchor(team)
  result.x0 = max(0, min(zone.xLo, anchor.x - pedHalf))
  result.x1 = min(MapWidth - 1, max(zone.xHi, anchor.x + pedHalf))
  result.y0 = max(0, min(zone.yLo, anchor.y - pedHalf))
  result.y1 = min(MapHeight - 1, max(zone.yHi, anchor.y + pedHalf))

proc endzoneDiffBox(sim: SimServer, team: Team): tuple[x0, y0, x1, y1: int] =
  ## Returns the bounding box (map coords, inclusive) of the pixels inside one
  ## team's endzone column that differ between the baked-glow map and the cold
  ## glow-free map — the crack glow, capture line, and pedestal disc. Everything
  ## else in the column is identical at every crossfade stage, so the fade
  ## overlay never needs to ship it. Computed once per team and cached.
  if EndzoneColdRgba.len != MapWidth * MapHeight * 4:
    ## Map (re)selected since the last bake: rebuild the cold map and drop
    ## every strip/box derived from the old geometry. This must run BEFORE
    ## the ready-flag return below — a box cached on a differently-sized map
    ## would otherwise be served as-is and index out of the current map's
    ## (correctly re-baked) buffers in endzoneStripSprite.
    EndzoneColdRgba = coldEndzoneMapRgba(sim.gameMap)
    EndzoneStripCache = default(typeof(EndzoneStripCache))
    EndzoneDiffBoxReady = default(typeof(EndzoneDiffBoxReady))
  if EndzoneDiffBoxReady[team]:
    return EndzoneDiffBox[team]
  let scan = sim.gameMap.endzoneStripBox(team)
  result = (x0: scan.x1 + 1, y0: scan.y1 + 1, x1: scan.x0 - 1, y1: -1)
  for y in scan.y0 .. scan.y1:
    for x in scan.x0 .. scan.x1:
      let src = mapIndex(x, y) * 4
      if sim.mapRgba[src] != EndzoneColdRgba[src] or
          sim.mapRgba[src + 1] != EndzoneColdRgba[src + 1] or
          sim.mapRgba[src + 2] != EndzoneColdRgba[src + 2]:
        result.x0 = min(result.x0, x)
        result.y0 = min(result.y0, y)
        result.x1 = max(result.x1, x)
        result.y1 = max(result.y1, y)
  EndzoneDiffBox[team] = result
  EndzoneDiffBoxReady[team] = true

proc endzoneStripSprite(
  sim: SimServer,
  team: Team,
  stage: int
): tuple[x, y, w, h: int, pixels: seq[uint8]] =
  ## Returns the endzone-glow DELTA overlay for one crossfade `stage`, cropped
  ## to the diff bounding box: pixels where the baked-glow and cold maps agree
  ## are fully transparent (the identical map shows through), differing pixels
  ## carry the blend — stage 0 all hot, GlowFadeStages-1 all cold. Drawn just
  ## above the map and below every actor so only the endzone glow + capture
  ## line visibly power down when a heart is taken — the shared map sprite (and
  ## the POV/RL view) is never re-baked. The endzone tint spans the whole
  ## column floor, so the diff crop still carries most of it (~200 KB vs
  ## ~400 KB for the full opaque strip) — which is why the crops are ALSO
  ## pre-shipped per connection (addEndzonePrewarm) so a steal/return ramp
  ## never pays sprite bytes at event time. Each (team, stage) crop is baked
  ## once and cached.
  let box = sim.endzoneDiffBox(team)
  if box.x1 < box.x0:
    return (x: 0, y: 0, w: 0, h: 0, pixels: @[])
  result.x = box.x0
  result.y = box.y0
  result.w = box.x1 - box.x0 + 1
  result.h = box.y1 - box.y0 + 1
  let s = clamp(stage, 0, GlowFadeStages - 1)
  if EndzoneStripCache[team][s].len ==
      result.w * boardScale * result.h * boardScale * 4:
    result.pixels = EndzoneStripCache[team][s]
    return
  # t: 0 at stage 0 (all hot/baked glow), 1 at the last stage (all cold).
  let
    t = s.float / float(GlowFadeStages - 1)
    k = boardScale
  if k == 1:
    result.pixels = newSeq[uint8](result.w * result.h * 4)
    for y in 0 ..< result.h:
      for x in 0 ..< result.w:
        let
          src = mapIndex(box.x0 + x, box.y0 + y) * 4
          dst = (y * result.w + x) * 4
        if sim.mapRgba[src] == EndzoneColdRgba[src] and
            sim.mapRgba[src + 1] == EndzoneColdRgba[src + 1] and
            sim.mapRgba[src + 2] == EndzoneColdRgba[src + 2]:
          continue                     # identical to the map below: transparent.
        for c in 0 .. 2:
          let
            hot = sim.mapRgba[src + c].float
            cold = EndzoneColdRgba[src + c].float
          result.pixels[dst + c] = uint8(hot + (cold - hot) * t)
        result.pixels[dst + 3] = 255
  else:
    # Native boardScale× crop: the diff BOX stays the logical 1× one (so the
    # overlay lands exactly where addBoardObject scales it to), but the pixels
    # blend the native-rendered hot and cold board maps — the fade overlay is
    # as sharp as the map it covers.
    let
      hotMap = sim.boardScaledMapPixels()
      coldMap = sim.boardScaledColdMapPixels()
      ow = result.w * k
      oh = result.h * k
      rowW = MapWidth * k
    result.pixels = newSeq[uint8](ow * oh * 4)
    for y in 0 ..< oh:
      for x in 0 ..< ow:
        let
          src = ((box.y0 * k + y) * rowW + box.x0 * k + x) * 4
          dst = (y * ow + x) * 4
        if hotMap[src] == coldMap[src] and
            hotMap[src + 1] == coldMap[src + 1] and
            hotMap[src + 2] == coldMap[src + 2]:
          continue                     # identical to the map below: transparent.
        for c in 0 .. 2:
          let
            hot = hotMap[src + c].float
            cold = coldMap[src + c].float
          result.pixels[dst + c] = uint8(hot + (cold - hot) * t)
        result.pixels[dst + 3] = 255
  EndzoneStripCache[team][s] = result.pixels

proc initGlobalViewerState*(): GlobalViewerState =
  ## Returns the default state for one global protocol viewer.
  result.mouseLayer = MapLayerId
  result.selectedJoinOrder = -1
  result.povJoinOrder = -1
  new(result.povState)
  result.replaySeekTick = -1
  result.replayCommands = @[]
  result.povSelectPending = -2   ## -2 = no request; -1 = clear; >=0 = slot.
  result.cogDriveTick = low(int)  ## no drive step yet; the first frame snaps.
  result.shoutLingerTick = low(int)  ## no shout pass yet; see addBoardShouts.

proc initPlayerViewerState*(): PlayerViewerState =
  ## Returns the default state for one sprite player viewer.
  new(result)

proc debugSpritePixels(sprite: SpritePacketSpriteDef): seq[uint8] =
  ## Decodes one sprite and rejects pixel counts that do not match its shape.
  result = uncompress(sprite.compressedPixels)
  if result.len != sprite.width * sprite.height * 4:
    raise newException(
      SpriteProtocolError,
      "debug sprite pixel count does not match its dimensions"
    )

proc validateDebugSpritePacket*(packet: openArray[uint8]) =
  ## Validates pixels before they reach replay storage; rendering decodes them.
  for message in packet.parseSpritePacket():
    if message.kind == spkSprite:
      discard message.sprite.debugSpritePixels()

proc applyDebugSpritePacket*(
  overlay: var DebugOverlay,
  packet: openArray[uint8]
) =
  ## Folds one player-authored sprite packet into an overlay.
  for message in packet.parseSpritePacket():
    case message.kind
    of spkSprite:
      overlay.sprites[message.sprite.id] = message.sprite
    of spkObject:
      overlay.objects[message.objectDef.id] = message.objectDef
    of spkDeleteObject:
      overlay.objects.del(message.objectId)
    of spkClearObjects:
      overlay.objects.clear()
    of spkViewport, spkLayer:
      discard

proc debugSpriteId*(playerIndex, payloadId: int): int =
  ## Returns the viewer sprite id for one player's payload sprite id.
  DebugSpriteBase + playerIndex * DebugPlayerIdStride +
    payloadId mod DebugPlayerIdStride

proc debugObjectId*(playerIndex, payloadId: int): int =
  ## Returns the viewer object id for one player's payload object id.
  DebugObjectBase + playerIndex * DebugPlayerIdStride +
    payloadId mod DebugPlayerIdStride

proc putRgbaPixel(pixels: var seq[uint8], pixelIndex: int, color: uint8) =
  ## Writes one palette color as a global protocol RGBA pixel.
  let
    rgba = Palette[color and 0x0f]
    offset = pixelIndex * 4
  pixels[offset] = rgba.r
  pixels[offset + 1] = rgba.g
  pixels[offset + 2] = rgba.b
  pixels[offset + 3] = rgba.a

proc newRgbaPixels(width, height: int): seq[uint8] =
  ## Allocates a transparent RGBA sprite buffer.
  newSeq[uint8](width * height * 4)

proc putRawRgbaPixel(
  pixels: var seq[uint8],
  pixelIndex: int,
  r, g, b, a: uint8
) =
  ## Writes one true-color RGBA pixel.
  let offset = pixelIndex * 4
  pixels[offset] = r
  pixels[offset + 1] = g
  pixels[offset + 2] = b
  pixels[offset + 3] = a

proc transportSheet(): Sprite =
  ## Returns the cached transport icon sheet.
  if TransportSheet.width == 0:
    TransportSheet = readRequiredSprite(clientDataDir() / "transport.png")
  TransportSheet

proc playerColorIndex(color: uint8): int =
  ## Returns the player color slot for a palette color.
  for i in 0 ..< PlayerColors.len:
    if PlayerColors[i] == color:
      return i
  0

proc playerColorName(index: int): string =
  ## Returns the display name for one player color slot.
  if index >= 0 and index < PlayerColorNames.len:
    return PlayerColorNames[index]
  "unknown"

const SoldierSkinSpriteStride = 4 * SoldierRotations
  ## One rotation set per Team enum member (4), per skin — red/blue default-
  ## skin ids keep their historical values; the pool widened for green/yellow.

proc soldierPlayerSpriteId(team: Team, skin: Skin, rot: int): int =
  ## Sprite id for one living soldier at aim rotation `rot`. The four team
  ## masters need SoldierRotations ids per skin; they sit in the existing
  ## player sprite pool (PlayerSpriteBase..), which reserved 16 ids per color.
  PlayerSpriteBase + ord(skin) * SoldierSkinSpriteStride +
    ord(team) * SoldierRotations + rot

proc selectedSoldierPlayerSpriteId(team: Team, skin: Skin, rot: int): int =
  ## Selected (outlined) soldier sprite id at aim rotation `rot`.
  SelectedPlayerSpriteBase + ord(skin) * SoldierSkinSpriteStride +
    ord(team) * SoldierRotations + rot

# --- Articulated turret-rig sprite ids ---
# Each family packs its dimensions into a dense range. Signed articulation steps
# (leg swing, wheel caster) are offset to a non-negative index. ord(seg) within a
# family: arms armL/armR = 0/1; legs FL/FR/Rear = 0/1/2; wheels L/R/Rear = 0/1/2.
proc rigHeadSpriteId(team: Team, skin: Skin, aimStep: int): int =
  RigHeadSpriteBase +
    ord(skin) * 2 * RigSteps +
    ord(team) * RigSteps +
    aimStep

proc rigGunSpriteId(team: Team, aimStep: int): int =
  RigGunSpriteBase + ord(team) * RigSteps + aimStep

proc rigSpraySpriteId(team: Team, aimStep: int): int =
  RigSpraySpriteBase + ord(team) * RigSteps + aimStep

proc rigArmSpriteId(team: Team, seg: RigSeg, aimStep, reach: int): int =
  ## reach 0 = tucked (idle), 1 = reaching forward (carrying).
  let armIdx = if seg == rsArmL: 0 else: 1
  RigArmSpriteBase + (((ord(team) * 2 + armIdx) * RigSteps + aimStep) * 2) + reach

proc rigLegIdx(seg: RigSeg): int =
  case seg
  of rsLegFL: 0
  of rsLegFR: 1
  of rsLegRear: 2
  else: 0

proc rigLegSpriteId(team: Team, seg: RigSeg,
    headStep, swingStep, shortenStep: int): int =
  ## headStep 0..15; swingStep signed → 0..2·RigLegSwingSteps; shortenStep 0..RigShortenSteps.
  let
    swings = 2 * RigLegSwingSteps + 1
    shorts = RigShortenSteps + 1
    sw = swingStep + RigLegSwingSteps
    idx = ((rigLegIdx(seg) * RigSteps + headStep) * swings + sw) * shorts + shortenStep
  RigLegSpriteBase + (ord(team) * 3 * RigSteps * swings * shorts) + idx

proc rigWheelIdx(seg: RigSeg): int =
  case seg
  of rsWheelL: 0
  of rsWheelR: 1
  of rsWheelRear: 2
  else: 0

proc rigWheelSpriteId(team: Team, seg: RigSeg, headStep, casterStep: int): int =
  ## headStep 0..15; casterStep signed → 0..2·RigCasterSteps.
  let
    casters = 2 * RigCasterSteps + 1
    cs = casterStep + RigCasterSteps
    idx = (rigWheelIdx(seg) * RigSteps + headStep) * casters + cs
  RigWheelSpriteBase + (ord(team) * 3 * RigSteps * casters) + idx

proc corpseSoldierSpriteId(team: Team, skin: Skin, rot: int): int =
  ## Sprite id for a dead soldier (grey corpse) at rotation `rot` (the
  ## selected-soldier pools start at 6000).
  CorpseSpriteBase + ord(skin) * SoldierSkinSpriteStride +
    ord(team) * SoldierRotations + rot

proc selfSoldierSpriteId(skin: Skin, rot: int): int =
  ## Sprite id for the outlined POV self soldier at rotation `rot`.
  SpritePlayerSelfSpriteBase + ord(skin) * SoldierRotations + rot

proc soldierFacingRight(rot: int): bool =
  ## Whether a soldier at rotation step `rot` faces right (east-ish) — the same
  ## left/right split the sim bakes into `flipH` (flipped while aiming into the
  ## western half). Used ONLY to attach the documented `<side>` observation
  ## label to each rotation sprite so exact-match label readers (the baseline
  ## bot, RULES.md) keep working while the HD art keeps its full-rotation sweep.
  let brad = rot * (AimBradsTurn div SoldierRotations)
  not (brad > AimBradsTurn div 4 and brad < AimBradsTurn * 3 div 4)

proc spriteDefinitionIndex(
  defs: openArray[SpriteDefinition],
  spriteId: int
): int =
  ## Returns the cache index for one sprite definition.
  for i in 0 ..< defs.len:
    if defs[i].spriteId == spriteId:
      return i
  -1

proc addSpriteChanged(
  packet: var seq[uint8],
  defs: var seq[SpriteDefinition],
  spriteId, width, height: int,
  pixels: openArray[uint8],
  label: string,
  changed = false
) {.measure.} =
  ## Appends a sprite definition when metadata or caller dirtiness changed.
  ## Every sprite MUST carry a non-empty label — the inspector and bot readers
  ## both key off it, and an empty label silently re-sends forever.
  doAssert label.len > 0, "sprite " & $spriteId & " needs a non-empty label"
  let index = defs.spriteDefinitionIndex(spriteId)
  if index >= 0:
    if defs[index].width == width and
        defs[index].height == height and
        defs[index].label == label and
        not changed:
      return
    defs[index].width = width
    defs[index].height = height
    defs[index].label = label
    defs[index].compressedPixels = @[]
  else:
    defs.add SpriteDefinition(
      spriteId: spriteId,
      width: width,
      height: height,
      label: label
    )
  packet.addSprite(spriteId, width, height, pixels, label)

proc addBoardObject(
  packet: var seq[uint8],
  objectId, x, y, z, layerId, spriteId: int
) =
  ## addObject for renderer emissions: placements on the zoomable board
  ## layers (map + fog) scale by boardScale; UI-layer placements pass
  ## through untouched. z is ordering-only and never scales.
  if layerId == MapLayerId or layerId == FogLayerId:
    packet.addObject(
      objectId, x * boardScale, y * boardScale, z, layerId, spriteId)
  else:
    packet.addObject(objectId, x, y, z, layerId, spriteId)

proc addBoardSpriteChanged(
  packet: var seq[uint8],
  defs: var seq[SpriteDefinition],
  spriteId, width, height: int,
  pixels: openArray[uint8],
  label: string,
  changed = false,
  native = 1
) {.measure.} =
  ## addSpriteChanged for BOARD sprites: `width`/`height` stay in logical map
  ## pixels; the wire sprite ships at boardScale× those dims. `native` is the
  ## scale `pixels` was rasterized at — 1 (upscaled here on emission) or
  ## boardScale (already high-res; passed through). The dedup check runs
  ## before any upscale so per-frame callers pay nothing when unchanged.
  doAssert label.len > 0, "sprite " & $spriteId & " needs a non-empty label"
  let
    outW = width * boardScale
    outH = height * boardScale
  let index = defs.spriteDefinitionIndex(spriteId)
  if index >= 0 and defs[index].width == outW and
      defs[index].height == outH and
      defs[index].label == label and
      not changed:
    return
  if native == boardScale:
    packet.addSpriteChanged(defs, spriteId, outW, outH, pixels, label, changed)
  else:
    packet.addSpriteChanged(
      defs, spriteId, outW, outH,
      scaleSpritePixels(pixels, width, height, boardScale), label, changed)

proc addDebugOverlay(
  packet: var seq[uint8],
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  overlay: DebugOverlay,
  playerIndex: int
) =
  ## Adds one selected player's debug overlay to a global viewer packet.
  var payloadSpriteIds: seq[int] = @[]
  for payloadId in overlay.sprites.keys:
    payloadSpriteIds.add(payloadId)
  payloadSpriteIds.sort()
  var validSpriteIds: seq[int] = @[]
  for payloadId in payloadSpriteIds:
    let
      sprite = overlay.sprites[payloadId]
      spriteId = debugSpriteId(playerIndex, payloadId)
      index = spriteDefs.spriteDefinitionIndex(spriteId)
    var pixels: seq[uint8]
    try:
      pixels = sprite.debugSpritePixels()
    except SpriteProtocolError, SnappyError:
      continue
    validSpriteIds.add(payloadId)
    let
      changed = index < 0 or
        spriteDefs[index].width != sprite.width or
        spriteDefs[index].height != sprite.height or
        spriteDefs[index].label != sprite.label or
        spriteDefs[index].compressedPixels != sprite.compressedPixels
    if not changed:
      continue
    if index >= 0:
      spriteDefs[index].width = sprite.width
      spriteDefs[index].height = sprite.height
      spriteDefs[index].label = sprite.label
      spriteDefs[index].compressedPixels = sprite.compressedPixels
    else:
      spriteDefs.add SpriteDefinition(
        spriteId: spriteId,
        width: sprite.width,
        height: sprite.height,
        label: sprite.label,
        compressedPixels: sprite.compressedPixels
      )
    # A debug sprite's declared dims are LOGICAL map pixels, like every other
    # board sprite: the wire sprite ships at boardScale× those dims so an
    # annotation keeps its map-relative size at any render scale, matching the
    # addBoardObject placement below. Emitted through addSprite rather than
    # addBoardSpriteChanged because the latter asserts a non-empty label, and a
    # player's label is untrusted input that must never abort the server.
    packet.addSprite(
      spriteId,
      sprite.width * boardScale,
      sprite.height * boardScale,
      scaleSpritePixels(pixels, sprite.width, sprite.height, boardScale),
      sprite.label
    )

  var payloadObjectIds: seq[int] = @[]
  for payloadId in overlay.objects.keys:
    payloadObjectIds.add(payloadId)
  payloadObjectIds.sort()
  for payloadId in payloadObjectIds:
    let objectDef = overlay.objects[payloadId]
    if objectDef.spriteId notin validSpriteIds:
      continue
    let objectId = debugObjectId(playerIndex, payloadId)
    currentIds.add(objectId)
    packet.addBoardObject(
      objectId,
      objectDef.x,
      objectDef.y,
      DebugOverlayZ,
      MapLayerId,
      debugSpriteId(playerIndex, objectDef.spriteId)
    )

proc applyGlobalViewerMessage*(
  state: var GlobalViewerState,
  message: string
) =
  ## Applies one or more global protocol client messages.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientMouseMoveMessage:
      state.mouseX = item.x
      state.mouseY = item.y
      state.mouseLayer =
        if item.hasLayer:
          item.layer
        else:
          MapLayerId
    of SpriteClientMouseButtonMessage:
      if item.button == 0x01'u8:
        state.mouseDown = item.down
        if state.mouseDown:
          state.clickPending = true
        else:
          state.scrubbingReplay = false
    of SpriteClientChatMessage:
      # Whole-string ctf-side commands are intercepted before the legacy
      # char-by-char transport path, so a multi-digit tick or slot is never
      # mangled into speed keystrokes.
      if item.text.startsWith("s:"):
        let tick = try: parseInt(item.text[2 .. ^1]) except ValueError: -1
        if tick >= 0:
          state.replaySeekTick = tick
      elif item.text.startsWith("v:"):
        let slot = try: parseInt(item.text[2 .. ^1]) except ValueError: -2
        if slot >= -1:
          state.povSelectPending = slot
      else:
        state.replayCommands.add(item.text)
    of SpriteClientInputMessage:
      discard
    of SpriteClientReadyMessage, SpriteClientDebugSpriteMessage:
      discard

proc applyPlayerViewerMessage*(
  state: var PlayerViewerState,
  message: string,
  inputMask: var uint8,
  pressedMask: var uint8,
  chatText: var string
) =
  ## Applies sprite player protocol input messages.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientChatMessage:
      chatText.add(item.text)
    of SpriteClientInputMessage:
      pressedMask = pressedMask or (item.mask and not inputMask)
      inputMask = item.mask
    of SpriteClientDebugSpriteMessage:
      state.pendingDebugSprites.add(item.debugSprites)
    of SpriteClientMouseMoveMessage, SpriteClientMouseButtonMessage,
        SpriteClientReadyMessage:
      discard

proc buildSpriteProtocolRawSprite(sprite: Sprite): seq[uint8] {.measure.} =
  ## Builds a raw global protocol sprite from a game sprite.
  result = newRgbaPixels(sprite.width, sprite.height)
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let colorIndex = sprite.pixels[sprite.spriteIndex(x, y)]
      if colorIndex != TransparentColorIndex:
        result.putRgbaPixel(sprite.spriteIndex(x, y), colorIndex)

proc buildSpriteProtocolShadowSprite(sprite: Sprite): seq[uint8] {.measure.} =
  ## Builds a shadowed global protocol sprite from a game sprite.
  result = newRgbaPixels(sprite.width, sprite.height)
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let colorIndex = sprite.pixels[sprite.spriteIndex(x, y)]
      if colorIndex != TransparentColorIndex:
        result.putRgbaPixel(
          sprite.spriteIndex(x, y),
          ShadowMap[colorIndex and 0x0f]
        )

proc buildSolidSprite(
  width, height: int,
  color: uint8
): seq[uint8] {.measure.} =
  ## Builds a solid protocol sprite.
  result = newRgbaPixels(width, height)
  for i in 0 ..< width * height:
    result.putRgbaPixel(i, color)

proc buildIndexedSpritePixels(
  indices: openArray[uint8],
  width,
  height: int,
  fallback: uint8
): seq[uint8] {.measure.} =
  ## Builds an RGBA sprite from palette indices.
  result = newRgbaPixels(width, height)
  for i in 0 ..< width * height:
    let color =
      if i < indices.len:
        indices[i]
      else:
        fallback
    result.putRgbaPixel(i, color)

proc buildHpBarSprite(litSegments: int): seq[uint8] {.measure.} =
  ## Builds the overhead health bar as a fixed row of HpBarSegments thirds. The
  ## bar length never scales with the hit-point config (a 99-hp game must not
  ## paint a full-width ribbon over a 16px sprite); health reads as N-of-3 lit
  ## chunks. A lit third is a calm sage green, a spent one a dim socket, so the
  ## bar informs without shouting over the board.
  result = newRgbaPixels(HpBarWidth, HpBarH)
  for seg in 0 ..< HpBarSegments:
    let x0 = seg * (HpBarSegW + HpBarSegGap)
    for py in 0 ..< HpBarH:
      for px in 0 ..< HpBarSegW:
        let i = py * HpBarWidth + x0 + px
        if seg < litSegments:
          result.putRawRgbaPixel(i, 122, 176, 96, 235)
        else:
          result.putRawRgbaPixel(i, 44, 40, 34, 170)

const IdentityGlyphs: array[8, array[IdentityGlyphH, uint8]] = [
  ## Uppercase Greek Α Β Γ Δ Ε Ζ Η Θ as 5×7 row bitmasks (bit 4 = leftmost
  ## pixel). Hand-drawn because neither bundled font has Greek coverage
  ## (Rajdhani carries only Μ Π Σ).
  [0b01110'u8, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001], # Α
  [0b11110'u8, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110], # Β
  [0b11111'u8, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000], # Γ
  [0b00100'u8, 0b00100, 0b01010, 0b01010, 0b10001, 0b10001, 0b11111], # Δ
  [0b11111'u8, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111], # Ε
  [0b11111'u8, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111], # Ζ
  [0b10001'u8, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001], # Η
  [0b01110'u8, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b01110], # Θ
]

proc buildIdentityBadgeSprite(
  team: Team,
  identityIndex: int
): seq[uint8] {.measure.} =
  ## Builds one identity badge: a dark ink disc with a team-tinted rim and the
  ## identity's Greek glyph in the team color mixed toward white (the aim-dot
  ## treatment), so the letter reads over the disc at board scale.
  result = newRgbaPixels(IdentityBadgeSize, IdentityBadgeSize)
  let
    base = Palette[teamColor(team) and 0x0f]
    c = float(IdentityBadgeSize - 1) / 2
  for y in 0 ..< IdentityBadgeSize:
    for x in 0 ..< IdentityBadgeSize:
      let d = sqrt((float(x) - c) * (float(x) - c) +
        (float(y) - c) * (float(y) - c))
      if d > c:
        continue
      let i = y * IdentityBadgeSize + x
      if d >= c - 1.2:
        result.putRawRgbaPixel(i, base.r, base.g, base.b, 220)
      else:
        result.putRawRgbaPixel(i, 24, 22, 20, 215)
  let
    gx0 = (IdentityBadgeSize - IdentityGlyphW) div 2
    gy0 = (IdentityBadgeSize - IdentityGlyphH) div 2
    glyph = IdentityGlyphs[identityIndex]
  for gy in 0 ..< IdentityGlyphH:
    for gx in 0 ..< IdentityGlyphW:
      if (glyph[gy] shr (IdentityGlyphW - 1 - gx) and 1) == 0:
        continue
      result.putRawRgbaPixel(
        (gy0 + gy) * IdentityBadgeSize + gx0 + gx,
        uint8((base.r.int + 255) div 2),
        uint8((base.g.int + 255) div 2),
        uint8((base.b.int + 255) div 2),
        255
      )

proc buildSoundRingSprite(): seq[uint8] {.measure.} =
  ## Builds the semi-transparent white "sound" ring: a faint filled circle
  ## with a brighter rim, colorless so it never leaks the shooter's team.
  result = newRgbaPixels(SoundRingSize, SoundRingSize)
  let c = float(SoundRingSize - 1) / 2
  for y in 0 ..< SoundRingSize:
    for x in 0 ..< SoundRingSize:
      let d = sqrt((float(x) - c) * (float(x) - c) +
        (float(y) - c) * (float(y) - c))
      if d <= c:
        let alpha = if d >= c - 1.5: 150'u8 else: 45'u8
        result.putRawRgbaPixel(y * SoundRingSize + x, 255, 255, 255, alpha)

proc buildShotImpactSprite(): seq[uint8] {.measure.} =
  ## Builds the hollow white "impact" ring: rim only, no fill, so it reads
  ## as a different sound than the grenade landing ring and never hides
  ## what's under it. Colorless so it never leaks the shooter's team.
  result = newRgbaPixels(SoundRingSize, SoundRingSize)
  let c = float(SoundRingSize - 1) / 2
  for y in 0 ..< SoundRingSize:
    for x in 0 ..< SoundRingSize:
      let d = sqrt((float(x) - c) * (float(x) - c) +
        (float(y) - c) * (float(y) - c))
      if d <= c and d >= c - 1.5:
        result.putRawRgbaPixel(y * SoundRingSize + x, 255, 255, 255, 150)

proc fuzzedAimBrads(sim: SimServer, targetIndex: int): int =
  ## The aim angle a soldier sprite RENDERS with in PLAYER views: the true
  ## aim plus a deterministic pseudo-random offset within ±AimRenderFuzzBrads
  ## (~±20°), held for AimRenderFuzzWindow ticks per target then re-rolled.
  ## Stable across frames, viewers, and replays — but never the exact aim
  ## (GameVersion 24; SELF exempted since 26): looking at ANOTHER bot — enemy
  ## or teammate — must not reveal where its gun truly points. Your own self
  ## marker renders TRUE aim: your gun is your own state, not a leak. The
  ## broadcast board is unaffected (spectators see true aim). Same hash
  ## family as shotImpactOffset.
  var h = 0x9E3779B9'u32 xor 0x5F356495'u32
  h = (h xor uint32(targetIndex)) * 0x85EBCA6B'u32
  h = (h xor uint32(sim.tickCount div AimRenderFuzzWindow)) * 0xC2B2AE35'u32
  h = h xor (h shr 15)
  let span = uint32(2 * AimRenderFuzzBrads + 1)
  (sim.players[targetIndex].aimBrads + int(h mod span) - AimRenderFuzzBrads +
    AimBradsTurn) mod AimBradsTurn

proc shotImpactOffset(shot: ShotFx): (int, int) =
  ## A deterministic pseudo-random offset for one shot's impact ring: stable
  ## across frames, viewers, and replays, but never the exact landing spot.
  var h = 0x9E3779B9'u32 xor 0x5F356495'u32
  h = (h xor uint32(shot.firedTick)) * 0x85EBCA6B'u32
  h = (h xor uint32(shot.x1)) * 0xC2B2AE35'u32
  h = (h xor uint32(shot.y1)) * 0x27D4EB2F'u32
  h = h xor (h shr 15)
  let span = uint32(2 * SoundRingJitter + 1)
  (int(h mod span) - SoundRingJitter,
    int((h shr 16) mod span) - SoundRingJitter)

proc buildThrowTargetSprite(): seq[uint8] {.measure.} =
  ## The charge-time landing marker: a thin warm-amber ring (a hollow reticle,
  ## not a filled disc, so it never hides what's under it) drawn where the
  ## grenade would land. Sized to the blast danger so it reads as "everything
  ## in here gets hit". Colorless-warm so it never leaks the thrower's team.
  result = newRgbaPixels(ThrowTargetSize, ThrowTargetSize)
  let c = float(ThrowTargetSize - 1) / 2
  for y in 0 ..< ThrowTargetSize:
    for x in 0 ..< ThrowTargetSize:
      let d = sqrt((float(x) - c) * (float(x) - c) +
        (float(y) - c) * (float(y) - c))
      if d <= c and d >= c - 2.0:                 # a 2px hollow rim
        result.putRawRgbaPixel(y * ThrowTargetSize + x, 255, 190, 70, 210)

proc buildShieldBubblePixels(
  dentBucket, stage: int
): seq[uint8] {.measure.} =
  ## The shield carrier's protective bubble: a pale-cyan soap-bubble ring drawn
  ## AROUND the whole soldier — hollow with only a faint interior sheen, so the
  ## carrier stays fully visible inside it — plus a small specular glint on the
  ## upper-left rim so it reads as a bubble, not a range ring. Colorless-cool so
  ## it never leaks the carrier's team.
  ##
  ## dentBucket < 0 builds the idle bubble. Otherwise it builds one impact
  ## variant: the whole ring blinks brighter and the rim presses in slightly
  ## around the impact site (dentBucket in 16ths of a turn, toward the
  ## shooter), both easing back to idle across the stages — the shield absorbs
  ## the hit, so the impact reads on the bubble, never on the body inside.
  result = newRgbaPixels(ShieldBubbleSize, ShieldBubbleSize)
  let
    c = float(ShieldBubbleSize - 1) / 2
    rimBase = c - 1.0
    glintX = -0.7071 * rimBase
    glintY = -0.7071 * rimBase
    # 1.0 on the impact tick, easing to 0 as the FX ends.
    ease =
      if dentBucket < 0:
        0.0
      else:
        1.0 - float(stage) / float(ShieldBubbleDeformStages)
    impactAngle = float(dentBucket) * 2.0 * PI /
      float(ShieldBubbleDeformBuckets)
    dentDepth = 3.5 * ease       # a slight press, never a collapse
    dentWidth = 0.7              # radians of rim the dent spreads across
    blink = 55.0 * ease          # whole-ring brightness pulse
  for y in 0 ..< ShieldBubbleSize:
    for x in 0 ..< ShieldBubbleSize:
      let
        dx = float(x) - c
        dy = float(y) - c
        d = sqrt(dx * dx + dy * dy)
      if d > rimBase + 1.6:
        continue
      # Local rim radius: pressed inward around the impact site.
      var rim = rimBase
      var impact = 0.0
      if dentBucket >= 0 and d > 0.5:
        # Angular distance from the impact site (screen y is down, matching
        # aim brads: angle = atan2(-dy, dx)).
        var da = arctan2(-dy, dx) - impactAngle
        while da < -PI: da += 2.0 * PI
        while da >= PI: da -= 2.0 * PI
        impact = exp(-(da * da) / (dentWidth * dentWidth))
        rim = rimBase - dentDepth * impact
      # Anti-aliased hollow rim over a barely-there interior sheen.
      var alpha = (175.0 + blink) * max(0.0, 1.0 - abs(d - rim) / 1.6)
      # The impact site flashes hardest — a bright pressed patch on the rim.
      alpha += 60.0 * ease * impact * max(0.0, 1.0 - abs(d - rim) / 2.2)
      if d < rim:
        alpha = max(alpha, 20.0 + 14.0 * ease)
      # Specular glint where the upper-left rim catches the light.
      let glintD = sqrt((dx - glintX) * (dx - glintX) +
        (dy - glintY) * (dy - glintY))
      alpha = min(235.0, alpha + 120.0 * max(0.0, 1.0 - glintD / 4.5))
      result.putRawRgbaPixel(
        y * ShieldBubbleSize + x,
        uint8(min(255.0, 175.0 + 60.0 * ease * impact)),
        uint8(min(255.0, 222.0 + 25.0 * ease * impact)),
        255,
        uint8(alpha)
      )

proc buildShieldBubbleSprite(): seq[uint8] =
  ## The idle (no recent impact) carrier bubble.
  buildShieldBubblePixels(-1, 0)

## The spray cone ANIMATES: a burst's fan starts bunched at the nozzle and jets
## outward to full reach as each per-tick snapshot ages, then thins out. The old
## plasma version placed its discs at fixed distances and only faded them, so the
## cone popped into existence fully formed and never moved — it read as a static
## stamp, not as paint leaving a can.
##
## The sim emits one snapshot per active tick (PlasmaArcActiveTicks) and each
## lives PlasmaArcFxTicks, so several fans at different stages overlap at any
## instant — that overlap is what makes a held trigger read as one continuous jet
## rather than a pulsing strobe.
const
  SprayJetStart = 0.55   ## how far along the reach the fan spans on its FIRST
                         ## frame; it grows to the full reach by the last stage.
  SprayPuffOverlap = 1.35  ## puffs are drawn OVERSIZE for their slot so
                           ## neighbours merge into one plume — at 1.0 the fan
                           ## reads as beads on a string, floor showing between.
  SprayNozzleFwd = SprayHeldGripPx + SprayHeldLengthPx
    ## Where the paint actually LEAVES the can, ALONG the aim: the held can's
    ## tail sits SprayHeldGripPx along the aim and the can is SprayHeldLengthPx
    ## long, so its nozzle is this far forward of the body center.
    ##
    ## The fan starts HERE rather than at the body center. Starting at the center
    ## put the first puff ~10px BEHIND the nozzle, on top of the cog's own body,
    ## so the paint read as pouring out of the cog's FACE instead of the can.
  SprayNozzleRight = GunRightPx
    ## ...and PERPENDICULAR to the aim: the can is held at the cog's RIGHT, the
    ## same GunRightPx off the aim ray as the marker it replaces, so the nozzle
    ## is off-axis too. Without this the plume left the correct distance but the
    ## wrong side, hanging in the air beside the can rather than out of it.
    ##
    ## Both offsets are DERIVED from the mount constants, not hardcoded, so
    ## re-posing the held can moves the paint with it.
  SprayAxisConverge = 0.65
    ## How much of the lateral offset has bled away by the far end of the plume.
    ## The near puffs sit fully at the nozzle; further out they drift back toward
    ## the cone's true center line, because that IS where the cone points — a jet
    ## held rigidly off-axis for its whole length would visibly miss the hitbox it
    ## represents. This is the visual bridge from the nozzle to the centered cone.
    ##
    ## The hitbox stays centered on the body throughout: selectArcVictims is
    ## untouched, and this is a render-side offset only.

proc sprayJetGrowth(stage: int): float =
  ## How far the fan has jetted out, 0 = just left the nozzle, 1 = full reach.
  SprayJetStart + (1.0 - SprayJetStart) *
    (stage.float / float(max(1, PlasmaArcFxStages - 1)))

proc plasmaPulseForward*(pulse, stage: int): int =
  ## The forward distance of one paint-mist puff's center, in map px, measured
  ## from the sprayer's body center: the puff's slot along the fan, where the fan
  ## spans the NOZZLE out to however far this stage has jetted.
  let tip = float(PlasmaArcFxReach) * sprayJetGrowth(stage)
  if tip <= float(SprayNozzleFwd):
    return SprayNozzleFwd
  SprayNozzleFwd + int(round((tip - float(SprayNozzleFwd)) *
    float(2 * pulse + 1) / float(2 * PlasmaArcFxPulses)))

proc plasmaPulseRight*(pulse, stage: int): int =
  ## The PERPENDICULAR offset of one puff's center, in map px, positive toward
  ## the cog's right (the side the can is held on). Full at the nozzle and
  ## easing back toward the cone's center line with distance, per
  ## SprayAxisConverge — so the plume visibly leaves the nozzle and then joins
  ## the axis the cone actually covers.
  if PlasmaArcFxPulses <= 1:
    return SprayNozzleRight
  let along = float(pulse) / float(PlasmaArcFxPulses - 1)   ## 0 near .. 1 far
  int(round(float(SprayNozzleRight) * (1.0 - SprayAxisConverge * along)))

proc plasmaPulseDiameter*(pulse, stage: int): int =
  ## One puff sprite's diameter: the plume's width AT that puff's current
  ## distance (so the mist widens as it travels), scaled by the overlap so the
  ## plume closes up. The floor keeps a near-nozzle puff from collapsing to a
  ## speck.
  ##
  ## Sized against the FX span, NOT the damage reach: the overlap draws each
  ## puff wider than its slot, so a plume sized directly off the cone would
  ## always spill outside it, and growing the cone to catch the spill would
  ## grow the plume with it. The damage cone is set to cover this shape
  ## instead — test_plasma_arc asserts the containment.
  let
    forward = plasmaPulseForward(pulse, stage)
    slot = PlasmaArcFxMaxWidth * forward div max(1, PlasmaArcFxReach)
  max(10, int(round(float(slot) * SprayPuffOverlap)))

## --- Team-colored PAINT art: always tint from teamPaintRgba ---
## Every paint visual below (spray mist, grenade blast, paintball tracer + head,
## on-hit splat, dried terrain stain, damage/KO pop) resolves its team color
## through `teamPaintRgba`, NOT `Palette[...]`. The 16-entry retro palette a
## sprite's `color: uint8` indexes has a blue slot (BlueTeamColor = 13) of
## (131,118,156) — a muted lavender that matches nothing else on screen: the
## blue soldier art is (116,168,255) and the blue endzone floor is (63,124,196).
## So palette-tinted blue paint read as a washed-out grey-violet, as if it
## belonged to some third team. teamPaintRgba maps the two TEAM colors to their
## true display values and passes individual player-slot colors through.
proc buildPlasmaPulseSprite(
  colorIndex, stage, pulse: int
): seq[uint8] {.measure.} =
  ## Builds one puff of the spray cone: atomized PAINT in the sprayer's team
  ## color, speckled by a per-pixel hash (the death splatter's dither idiom) so
  ## it reads as wet mist rather than a solid disc, at full team saturation
  ## except a wet sheen in the core.
  ##
  ## The puffs overlap (see `SprayPuffOverlap`) into one continuous plume, and
  ## the droplet density thins toward each puff's rim so the plume's edge is
  ## ragged and gassy instead of a ring of hard circles.
  let
    size = plasmaPulseDiameter(pulse, stage)
    base = teamPaintRgba(PlayerColors[colorIndex and 0x0f])
    center = float(size - 1) / 2
    radius = max(center, 1.0)
    fade = 1.0 - 0.72 * (stage.float /
      float(max(1, PlasmaArcFxStages - 1)))
  result = newRgbaPixels(size, size)
  for y in 0 ..< size:
    for x in 0 ..< size:
      let
        dx = float(x) - center
        dy = float(y) - center
        distance = sqrt(dx * dx + dy * dy)
      if distance > radius:
        continue
      let core = 1.0 - distance / radius
      # Droplet dither: hash the pixel (with the stage AND slot, so every puff
      # of every frame speckles differently — a static pattern would read as a
      # texture sliding along the aim instead of moving paint). Keep the pixel
      # only if it beats the local density: dense core, thin ragged rim.
      var noise = uint32(x + 1) * 374761393'u32 +
        uint32(y + 1) * 668265263'u32 + uint32(stage + 1) * 2246822519'u32 +
        uint32(pulse + 1) * 3266489917'u32
      noise = (noise xor (noise shr 13)) * 1274126177'u32
      if float((noise shr 16) mod 100) > 30.0 + 70.0 * core:
        continue
      # Wet sheen only in the hot center; the body stays saturated team paint.
      let sheen = max(0.0, core - 0.55) * 2.0
      result.putRawRgbaPixel(
        y * size + x,
        uint8(clamp(base.r.float + sheen * (255.0 - base.r.float), 0, 255)),
        uint8(clamp(base.g.float + sheen * (255.0 - base.g.float), 0, 255)),
        uint8(clamp(base.b.float + sheen * (255.0 - base.b.float), 0, 255)),
        uint8(clamp(255.0 * fade * (0.45 + 0.55 * core), 0.0, 255.0))
      )

proc buildBlastSprite(colorIndex, stage, size: int): seq[uint8] {.measure.} =
  ## The grenade landing: a BIG paint splat in the THROWER's team color — a
  ## paint-bomb bursts, it doesn't flash white. Same wet-paintball language as
  ## the on-hit splat (buildHitSparkSprite) but blast-sized (~2x the blast
  ## radius), with a ragged rim of flung droplets so it reads as a burst, a
  ## bright wet-sheen core, and a deep same-hue contour so it pops off the dark
  ## floor. Alpha-only fade across the short blast life keeps the team color
  ## vivid (never muddies toward brown) so a landing is unmistakably one team's.
  ## `size` is BlastSize for an open-field landing or TrenchBlastSize for one
  ## trapped in a trench — every proportion below scales off it, so a trench
  ## blast is the same shape shrunk to the pit's footprint, not a crop.
  result = newRgbaPixels(size, size)
  let
    base = teamPaintRgba(PlayerColors[colorIndex and 0x0f])
    paintR = uint8((base.r.int * 3 + 255) div 4)
    paintG = uint8((base.g.int * 3 + 255) div 4)
    paintB = uint8((base.b.int * 3 + 255) div 4)
    sheenR = uint8((base.r.int + 255 * 3) div 4)
    sheenG = uint8((base.g.int + 255 * 3) div 4)
    sheenB = uint8((base.b.int + 255 * 3) div 4)
    edgeR = uint8(base.r.int * 2 div 5)
    edgeG = uint8(base.g.int * 2 div 5)
    edgeB = uint8(base.b.int * 2 div 5)
    c = float(size - 1) / 2
    coreR = float(size) * 0.30                 # main wet blob radius
    # Alpha-only fade: full at stage 0, thinning to a faint stain by the last.
    fade = 1.0 - 0.72 * (stage.float / float(max(1, BlastStages - 1)))
  # Ten flung droplets ring the core (fixed offsets → deterministic sprite).
  # The offsets were hand-tuned on the original 84px canvas; `ds` rescales
  # them to the current canvas so the outermost paint always reaches the
  # true blast radius, whatever GrenadeBlastRadius is.
  const droplets = [(-30, -10, 7.0), (26, -22, 6.0), (33, 14, 7.5),
                    (-22, 26, 6.5), (8, 33, 5.5), (-33, 6, 5.0),
                    (18, 30, 5.0), (-14, -30, 5.5), (31, -3, 5.0),
                    (-4, -34, 4.5)]
  let ds = float(size) / 84.0
  for y in 0 ..< size:
    for x in 0 ..< size:
      let
        dx = float(x) - c
        dy = float(y) - c
        d2 = dx * dx + dy * dy
      # Irregular core edge: hash-perturb the radius so the blob is organic.
      var noise = uint32(x) * 374761393'u32 + uint32(y) * 668265263'u32
      noise = (noise xor (noise shr 13)) * 1274126177'u32
      let wobble = (int((noise shr 16) mod 11) - 5).float      # -5..+5 px
      let coreEdge = coreR + wobble
      var
        inShape = d2 <= coreEdge * coreEdge
        onEdge = d2 > (coreEdge - 4.0) * (coreEdge - 4.0) and inShape
      if not inShape:
        for (ox, oy, dr) in droplets:
          let
            ddx = float(x) - (c + ox.float * ds)
            ddy = float(y) - (c + oy.float * ds)
            sdr = dr * ds
          if ddx * ddx + ddy * ddy <= sdr * sdr:
            inShape = true
            onEdge = ddx * ddx + ddy * ddy > (sdr - 2.0) * (sdr - 2.0)
            break
      if not inShape:
        continue
      # Wet sheen: a bright offset lobe up-left inside the core.
      let
        sxr = dx + 7.0
        syr = dy + 7.0
        sheen = d2 <= coreR * coreR and
          (sxr * sxr + syr * syr) <= (coreR * 0.55) * (coreR * 0.55) and
          (int((noise shr 9) mod 5) > 0)
      var r, g, b: uint8
      if onEdge:
        (r, g, b) = (edgeR, edgeG, edgeB)
      elif sheen:
        (r, g, b) = (sheenR, sheenG, sheenB)
      else:
        (r, g, b) = (paintR, paintG, paintB)
      result.putRawRgbaPixel(
        y * size + x, r, g, b,
        uint8(clamp(255.0 * fade, 0.0, 255.0))
      )

proc buildTracerDotSprite(colorIndex, stage, bucket: int): seq[uint8] {.measure.} =
  ## Builds one thin trail blob of the comet's tail: a small round wet paintball
  ## in SATURATED team paint. Blobs are sampled at < their own size along the
  ## beam so they overlap into one thin continuous trail (not a dotted line),
  ## and the `bucket` bakes the along-beam fade — bucket 0 is the faint far tail
  ## near the muzzle, the top bucket is the bright base just behind the head.
  ## Two fades multiply in: the along-beam `bucket` and the whole shot's age
  ## `stage` (ux.replay L98), so a shot punches then dies. Only a faint center
  ## highlight lifts the color (a full white core washed the trail pink); the
  ## interior is solid with a ~1px soft rim so overlaps merge cleanly.
  result = newRgbaPixels(TracerDotSize, TracerDotSize)
  let
    base = teamPaintRgba(PlayerColors[colorIndex and 0x0f])
    c = float(TracerDotSize - 1) / 2
    r = c + 0.5                ## blob radius reaches the canvas edge.
    stageFade = 1.0 - stage.float / float(TracerStages)
    # Along-beam brightness: bucket 0 faintest → top bucket brightest.
    beamT = (bucket.float + 1.0) / float(TrailBuckets)
    beamFade = pow(beamT, TrailFalloff)
  for y in 0 ..< TracerDotSize:
    for x in 0 ..< TracerDotSize:
      let
        dx = float(x) - c
        dy = float(y) - c
        dist = sqrt(dx * dx + dy * dy)
      if dist > r:
        continue
      # Stay saturated team paint: only a faint highlight (≤25% toward white)
      # lifts the very center, so the trail reads as its team color.
      let sheen = clamp(1.0 - dist / r, 0.0, 1.0) * 0.25
      let
        rr = base.r.int + int(float(255 - base.r.int) * sheen)
        gg = base.g.int + int(float(255 - base.g.int) * sheen)
        bb = base.b.int + int(float(255 - base.b.int) * sheen)
        # Solid interior, ~1px soft rim so overlapping blobs form one line.
        edge = clamp(r - dist, 0.0, 1.0)
        alpha = uint8(clamp(int(255.0 * stageFade * beamFade * edge), 0, 255))
      result.putRawRgbaPixel(
        y * TracerDotSize + x,
        uint8(clamp(rr, 0, 255)),
        uint8(clamp(gg, 0, 255)),
        uint8(clamp(bb, 0, 255)),
        alpha
      )

proc buildMuzzleBloomSprite(stage: int): seq[uint8] {.measure.} =
  ## Builds the subtle muzzle flash at a shot's ORIGIN: a soft warm-amber glow
  ## that marks where the gun fired. Deliberately DIM and never white-hot — the
  ## bright leading paintball is the eye-anchor, and the flash must not read as
  ## a second ball; it just quietly tags the shooter. Fades by ALPHA over the
  ## shot's life so it puffs then dies.
  result = newRgbaPixels(MuzzleBloomSize, MuzzleBloomSize)
  let
    c = float(MuzzleBloomSize - 1) / 2
    r = c + 0.5
    stageFade = 1.0 - stage.float / float(TracerStages)
  for y in 0 ..< MuzzleBloomSize:
    for x in 0 ..< MuzzleBloomSize:
      let
        dx = float(x) - c
        dy = float(y) - c
        dist = sqrt(dx * dx + dy * dy)
      if dist > r:
        continue
      # Warm amber, brightening a touch toward the center but never to white.
      let coreMix = clamp(1.0 - dist / r, 0.0, 1.0)  ## 1 center, 0 rim.
      let
        rr = 235 + int(20.0 * coreMix)               ## 235 rim → 255 core.
        gg = 150 + int(50.0 * coreMix)               ## 150 rim → 200 core.
        bb = 70 + int(40.0 * coreMix)                ## 70 rim → 110 core.
        # Soft falloff so it glows rather than snaps; capped low so it stays
        # a background tag, not a rival to the head.
        edge = clamp((r - dist) / 2.0, 0.0, 1.0)
        alpha = uint8(clamp(int(150.0 * stageFade * edge), 0, 255))
      result.putRawRgbaPixel(
        y * MuzzleBloomSize + x,
        uint8(rr), uint8(clamp(gg, 0, 255)), uint8(clamp(bb, 0, 255)), alpha
      )

proc buildHitFlashSprite(stage: int): seq[uint8] {.measure.} =
  ## Builds one stage of the struck-target flash: a hot white ring that
  ## expands outward and fades over the flash's short life, ringing the
  ## victim's body so a connected shot reads instantly in the spectator
  ## view. Colorless so it never recolors either team.
  result = newRgbaPixels(HitFlashSize, HitFlashSize)
  let
    c = float(HitFlashSize - 1) / 2
    t = stage.float / float(max(1, HitFlashStages - 1))  ## 0 fresh → 1 dying.
    radius = 10.0 + 6.0 * t                              ## expands outward.
    thickness = 2.6 - 1.0 * t                            ## thins as it dies.
    alphaTop = 235.0 * (1.0 - 0.75 * t)                  ## fades out.
  for y in 0 ..< HitFlashSize:
    for x in 0 ..< HitFlashSize:
      let
        dx = float(x) - c
        dy = float(y) - c
        dist = sqrt(dx * dx + dy * dy)
        edge = clamp(thickness - abs(dist - radius), 0.0, 1.0)
      if edge > 0:
        result.putRawRgbaPixel(
          y * HitFlashSize + x,
          255, 255, 255,
          uint8(clamp(int(alphaTop * edge), 0, 255))
        )

proc addHitFlashes(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8]
) {.measure.} =
  ## Rings every recently-struck player with the expanding white hit flash,
  ## drawn over the victim's CURRENT position so it tracks them while they
  ## keep moving. SPECTATOR ONLY, like the tracers: player observations never
  ## contain it, so bots learn nothing new.
  for i in 0 ..< min(sim.hitFlashes.len, HitFlashMaxCount):
    let flash = sim.hitFlashes[i]
    if flash.playerIndex < 0 or flash.playerIndex >= sim.players.len:
      continue
    let
      victim = sim.players[flash.playerIndex]
      age = sim.tickCount - flash.tick
      stage = clamp(age * HitFlashStages div HitFlashTicks, 0, HitFlashStages - 1)
      spriteId = HitFlashSpriteBase + stage
    packet.addBoardSpriteChanged(
      spriteDefs,
      spriteId,
      HitFlashSize,
      HitFlashSize,
      buildHitFlashSprite(stage),
      "hit flash stage " & $stage
    )
    let objectId = HitFlashObjectBase + i
    currentIds.add(objectId)
    packet.addBoardObject(
      objectId,
      victim.x + CollisionW div 2 - HitFlashSize div 2,
      victim.y + CollisionH div 2 - HitFlashSize div 2,
      30007,
      MapLayerId,
      spriteId
    )

proc buildTracerHeadSprite(colorIndex, stage: int): seq[uint8] {.measure.} =
  ## Builds the bright LEADING paintball at a shot's IMPACT end — the comet's
  ## head, the eye-anchor. Hotter than a trail dot (a wide white-hot core over a
  ## team-color rim) so it's the brightest thing on the beam and clearly points
  ## at the target it struck. Alpha fades by age stage like the trail, so head
  ## and tail die together.
  result = newRgbaPixels(TracerHeadSize, TracerHeadSize)
  let
    base = teamPaintRgba(PlayerColors[colorIndex and 0x0f])
    c = float(TracerHeadSize - 1) / 2
    r = c + 0.5
    stageFade = 1.0 - stage.float / float(TracerStages)
  for y in 0 ..< TracerHeadSize:
    for x in 0 ..< TracerHeadSize:
      let
        dx = float(x) - c
        dy = float(y) - c
        dist = sqrt(dx * dx + dy * dy)
      if dist > r:
        continue
      # A wider white-hot core than a body dot (pow<1 pushes white outward),
      # bleeding to the pure team color at the rim for unambiguous team ID.
      let coreMix = pow(clamp(1.0 - dist / r, 0.0, 1.0), 0.6)
      let
        rr = base.r.int + int(float(255 - base.r.int) * coreMix)
        gg = base.g.int + int(float(255 - base.g.int) * coreMix)
        bb = base.b.int + int(float(255 - base.b.int) * coreMix)
        edge = clamp((r - dist) / 1.0, 0.0, 1.0)
        alpha = uint8(clamp(int(255.0 * stageFade * edge), 0, 255))
      result.putRawRgbaPixel(
        y * TracerHeadSize + x,
        uint8(clamp(rr, 0, 255)),
        uint8(clamp(gg, 0, 255)),
        uint8(clamp(bb, 0, 255)),
        alpha
      )

proc buildSplatterSprite(colorIndex, stage: int): seq[uint8] {.measure.} =
  ## Builds one death-splatter blob: a dense irregular blob of the victim's
  ## color at stage 0 that grows sparser and darker toward the last stage.
  result = newRgbaPixels(SplatterSize, SplatterSize)
  let
    color = PlayerColors[colorIndex and 0x0f]
    shade = ShadowMap[color and 0x0f]
    half = SplatterSize div 2
  for y in 0 ..< SplatterSize:
    for x in 0 ..< SplatterSize:
      let
        dx = x - half
        dy = y - half
        d2 = dx * dx + dy * dy
      if d2 > half * half:
        continue
      var noise = uint32(x) * 374761393'u32 + uint32(y) * 668265263'u32
      noise = (noise xor (noise shr 13)) * 1274126177'u32
      let density = 120 - stage * 25 - d2 * 2
      if int((noise shr 16) mod 100) < density:
        result.putRgbaPixel(
          y * SplatterSize + x,
          if stage >= SplatterStages div 2: shade else: color
        )

proc buildHitSparkSprite(colorIndex, stage: int): seq[uint8] {.measure.} =
  ## Builds the on-hit PAINT SPLAT left by a non-fatal hit (this is paintball,
  ## not blood). A wet, glossy blob of the SHOOTER's team paint — big enough
  ## (~player-sized) to read at a glance, flung droplets around the core so it
  ## reads unmistakably as a splat, a bright wet-sheen highlight, and a thin
  ## dark contour so it pops off the dark floor. It fades by ALPHA ONLY and
  ## never darkens toward brown, so red stays vivid paint (never a blood scab)
  ## and the SHOOTER's color stays legible for the whole life (enemy tag vs
  ## friendly fire). Centered on a HitSplatSize canvas.
  result = newRgbaPixels(HitSplatSize, HitSplatSize)
  let
    base = teamPaintRgba(PlayerColors[colorIndex and 0x0f])
    # Paint stays bright: lighten the team color a touch so it never muddies,
    # and keep a wet-highlight color near white for the sheen.
    paintR = uint8((base.r.int * 3 + 255) div 4)
    paintG = uint8((base.g.int * 3 + 255) div 4)
    paintB = uint8((base.b.int * 3 + 255) div 4)
    sheenR = uint8((base.r.int + 255 * 3) div 4)
    sheenG = uint8((base.g.int + 255 * 3) div 4)
    sheenB = uint8((base.b.int + 255 * 3) div 4)
    # Dark contour = a deep version of the SAME hue (not brown), so the edge
    # reads as shadowed paint, keeping the team color unambiguous.
    edgeR = uint8(base.r.int * 2 div 5)
    edgeG = uint8(base.g.int * 2 div 5)
    edgeB = uint8(base.b.int * 2 div 5)
    c = float(HitSplatSize - 1) / 2
    # Alpha-only fade: full at stage 0, thinning to a faint stain by the last.
    fade = 1.0 - 0.62 * (stage.float / float(SplatterStages - 1))
    coreR2 = HitSplatCoreR * HitSplatCoreR
  # Six flung droplets ring the core (fixed offsets → deterministic sprite).
  const droplets = [(-8, -3, 2.4), (7, -6, 2.0), (9, 4, 2.6),
                    (-6, 7, 2.2), (2, 9, 1.8), (-9, 2, 1.7)]
  for y in 0 ..< HitSplatSize:
    for x in 0 ..< HitSplatSize:
      let
        dx = float(x) - c
        dy = float(y) - c
        d2 = dx * dx + dy * dy
      # Irregular core edge: hash-perturb the radius so the blob is organic.
      var noise = uint32(x) * 374761393'u32 + uint32(y) * 668265263'u32
      noise = (noise xor (noise shr 13)) * 1274126177'u32
      let wobble = (int((noise shr 16) mod 7) - 3).float  # -3..+3 px
      let coreEdge = HitSplatCoreR + wobble * 0.5
      var
        inShape = d2 <= coreEdge * coreEdge
        onEdge = d2 > (coreEdge - 1.6) * (coreEdge - 1.6) and inShape
      # Any droplet the pixel falls inside also paints the shape.
      if not inShape:
        for (ox, oy, dr) in droplets:
          let
            ddx = float(x) - (c + ox.float)
            ddy = float(y) - (c + oy.float)
          if ddx * ddx + ddy * ddy <= dr * dr:
            inShape = true
            onEdge = ddx * ddx + ddy * ddy > (dr - 1.0) * (dr - 1.0)
            break
      if not inShape:
        continue
      # Wet sheen: a small bright offset lobe up-left inside the core.
      let
        sxr = dx + 2.0
        syr = dy + 2.0
        sheen = d2 <= coreR2 and (sxr * sxr + syr * syr) <= 5.2 * 5.2 and
          (int((noise shr 9) mod 5) > 0)
      var r, g, b: uint8
      if onEdge:
        (r, g, b) = (edgeR, edgeG, edgeB)
      elif sheen:
        (r, g, b) = (sheenR, sheenG, sheenB)
      else:
        (r, g, b) = (paintR, paintG, paintB)
      result.putRawRgbaPixel(
        y * HitSplatSize + x, r, g, b,
        uint8(clamp(255.0 * fade, 0.0, 255.0))
      )

proc buildPaintStainSprite(
  sim: SimServer,
  stain: PaintStain,
  colorIndex, variant: int,
  maskToSurface = true
): seq[uint8] {.measure.} =
  ## Builds one DRIED terrain stain: a flat, matte splat of team paint soaked
  ## into the floor. Deliberately NOT the wet on-hit splat — no sheen, no bright
  ## contour, and a muted alpha — because a stain is old paint, and a floor
  ## covered in wet-looking blobs would out-shout the players. Reads as
  ## coverage when several overlap; keeps the team hue unambiguous so a lane's
  ## color says who owns it.
  ##
  ## Analytic: rasterized AT the emission scale (boardScale), per the board
  ## sprite rule, so the ragged edges stay crisp instead of blocky-upscaled.
  let
    k = max(1, boardScale)
    outSize = StainSize * k
  result = newRgbaPixels(outSize, outSize)
  let
    base = teamPaintRgba(PlayerColors[colorIndex and 0x0f])
    # Keep the hue saturated and let ALPHA do all the subtlety. The stain has to
    # stay translucent enough that the floor's concrete — control joints, cracks,
    # grain — reads straight through it, which is the whole difference between
    # "paint soaked into terrain" and "a colored blob dropped on top of it".
    paintR = uint8(min(255, base.r.int * 92 div 100))
    paintG = uint8(min(255, base.g.int * 92 div 100))
    paintB = uint8(min(255, base.b.int * 92 div 100))
    c = float(outSize - k) / 2
    fs = float(outSize)
    v = float(variant)
  # A splat is a MAIN GOB plus a few smaller satellite blobs — overlapping
  # circles, the same construction as the wet on-hit splat. (An earlier pass
  # modulated one radius by sin(angle * lobes), which does not read as paint at
  # all: it renders as a spiky star/asterisk. Never shape a blot that way.)
  # Offsets/radii are in units of the 19px canvas, scaled to the emission size,
  # and are fixed per variant so the sprite stays deterministic.
  const gobs = [
    # (dx, dy, r) per variant, main gob first.
    [(0.00, 0.00, 0.30), (0.19, -0.13, 0.16), (-0.17, 0.15, 0.13),
     (0.13, 0.20, 0.10)],
    [(-0.03, 0.02, 0.31), (-0.20, -0.16, 0.15), (0.20, 0.10, 0.14),
     (0.04, -0.23, 0.09)],
    [(0.02, -0.02, 0.28), (0.21, 0.14, 0.17), (-0.15, -0.19, 0.12),
     (-0.21, 0.12, 0.10)],
    [(0.00, 0.03, 0.32), (-0.22, 0.09, 0.14), (0.16, -0.18, 0.13),
     (0.19, 0.19, 0.09)],
    [(-0.02, -0.01, 0.29), (0.18, -0.20, 0.15), (0.14, 0.21, 0.12),
     (-0.20, -0.10, 0.11)],
    [(0.03, 0.00, 0.30), (-0.18, -0.18, 0.16), (-0.13, 0.21, 0.11),
     (0.22, 0.08, 0.12)],
    [(-0.01, 0.02, 0.27), (0.22, 0.02, 0.16), (-0.19, 0.16, 0.14),
     (0.05, -0.22, 0.11)],
    [(0.01, -0.03, 0.31), (0.15, 0.20, 0.15), (-0.21, -0.13, 0.13),
     (-0.09, 0.22, 0.10)]
  ]
  let shape = gobs[variant mod gobs.len]
  for y in 0 ..< outSize:
    for x in 0 ..< outSize:
      let
        px = float(x)
        py = float(y)
      # `density` is 0..1 coverage of wet paint at this pixel, taken as the
      # strongest of three splat features. It drives ALPHA only — never a
      # color swap — so the mark is one translucent film over the stonework.
      var density = 0.0
      # 1. The main mass: overlapping gobs, with a flat CORE. A purely radial
      # falloff makes each gob a soft ball; holding density at 1 until the
      # outer third makes it a blot with a soft rim, which is what paint is.
      for (ox, oy, rr) in shape:
        let
          gx = px - (c + ox * fs)
          gy = py - (c + oy * fs)
          gr = rr * fs
          gd = sqrt(gx * gx + gy * gy)
        if gd < gr:
          density = max(density, clamp((1.0 - gd / gr) / 0.38, 0.0, 1.0))
      # Everything thrown clear of the mass leaves in ONE direction — paint
      # arrives on a trajectory. Spraying features evenly around the circle is
      # what turned an earlier pass into asterisks/spiders; keeping them inside
      # a narrow arc is what makes the mark read as thrown.
      let throwAng = v * 2.39
      # 2. Short tapered FINGERS creeping off the mass edge, not long spokes.
      for f in 0 ..< 2:
        let
          fa = throwAng + (float(f) - 0.5) * 0.62
          flen = fs * (0.15 + 0.06 * abs(sin(v * 0.7 + float(f) * 1.9)))
          fwid = fs * (0.062 + 0.020 * abs(cos(v * 1.4 + float(f))))
          dirX = cos(fa)
          dirY = sin(fa)
          relX = px - c
          relY = py - c
          t = clamp((relX * dirX + relY * dirY) / flen, 0.0, 1.0)
          perp = abs(relX * dirY - relY * dirX)
          wid = fwid * (1.0 - 0.70 * t)      ## tapers to a point
        if wid > 0.0 and perp < wid:
          density = max(density, (1.0 - perp / wid) * (1.0 - 0.45 * t))
      # 3. Flung DROPLETS — sparse specks downrange of the throw, the giveaway
      # detail that separates a splat from a blob.
      for s in 0 ..< 6:
        let
          sa = throwAng + (float(s) - 2.5) * 0.34
          sd = fs * (0.26 + 0.13 * abs(sin(v + float(s) * 2.6)))
          sr = fs * (0.016 + 0.017 * abs(cos(v * 1.7 + float(s) * 1.3)))
          dx2 = px - (c + cos(sa) * sd)
          dy2 = py - (c + sin(sa) * sd)
          dd = sqrt(dx2 * dx2 + dy2 * dy2)
        if dd < sr:
          density = max(density, (1.0 - dd / sr) * 0.85)
      if density <= 0.0:
        continue
      # Per-pixel grain, the same deterministic hash idiom as the other splat
      # art. It both frays the outline (so no shape shows a clean analytic
      # edge) and mottles the interior, so the paint looks absorbed unevenly
      # into stone rather than airbrushed on.
      var noise = uint32(x) * 374761393'u32 + uint32(y) * 668265263'u32 +
        uint32(variant) * 2246822519'u32
      noise = (noise xor (noise shr 13)) * 1274126177'u32
      let
        grain = float(int((noise shr 16) mod 1000)) / 1000.0
        frayed = density - 0.30 * grain      ## ragged, never analytic
      if frayed <= 0.02:
        continue
      # THE key number: a single stain is a faint tint, not a sticker. Peak
      # opacity stays low so the floor reads through every mark; coverage comes
      # from many marks LAYERING (each is composited over the last), which is
      # how a fought-over lane ends up saturated while a quiet one stays clean.
      const StainPeakAlpha = 104.0
      let alpha = uint8(clamp(
        StainPeakAlpha * pow(min(1.0, frayed), 0.75) * (0.74 + 0.26 * grain),
        0.0, 255.0
      ))
      if alpha <= 3:
        continue
      # SURFACE MASK. Paint clings to the thing it hit: a blot that struck a
      # wall must stop at that wall's edge instead of draping over the floor
      # beside it (and a blot on the floor must not climb the wall). Map this
      # sprite pixel back to its map cell and drop it unless that cell is the
      # same surface the paint actually landed on. This is why stains cannot
      # share one sprite per color×variant — the mask is specific to the spot.
      if maskToSurface:
        let
          mapX = stain.x - StainSize div 2 + x div k
          mapY = stain.y - StainSize div 2 + y div k
        # isArtWall, not isWall: since GV28 the collision mask carries the
        # diamonds' LIVE rotated footprint, so masking a terrain stain against
        # it would make the stain flicker with the spin. Terrain stains belong
        # to the static art; paint that lands on a diamond is stored on the
        # diamond instead (addPaintStain) so it turns with the stone.
        if sim.isArtWall(mapX, mapY) != stain.onWall:
          continue
      result.putRawRgbaPixel(y * outSize + x, paintR, paintG, paintB, alpha)

## --- Smooth (vector) board text — spectator supersample only ---
## Every 1× stream keeps the retro pixel fonts byte-for-byte (the player
## observation stream and the POV lens are untouched); at boardScale > 1 the
## board text sprites re-render with Rajdhani SemiBold (data/font.ttf, OFL —
## the same face the DOM broadcast chrome uses) so names, damage pops and
## shout bubbles resolve as smooth antialiased type instead of upscaled 6px
## glyph blocks.
var boardTypefaceCache: Typeface

proc boardTypeface(): Typeface =
  if boardTypefaceCache.isNil:
    boardTypefaceCache = readTypeface(gameDir() / "data" / "font.ttf")
  boardTypefaceCache

var smoothTextCache: Table[string, tuple[
  width, height: int, pixels: seq[uint8]]]

proc imageToStraightRgba(image: Image): seq[uint8] =
  ## Straight-alpha RGBA bytes for the Sprite v1 protocol (pixie stores
  ## premultiplied).
  result = newSeq[uint8](image.width * image.height * 4)
  for i in 0 ..< image.width * image.height:
    let c = image.data[i].rgba()
    result[i * 4] = c.r
    result[i * 4 + 1] = c.g
    result[i * 4 + 2] = c.b
    result[i * 4 + 3] = c.a

proc smoothTextSprite(
  lines: openArray[string],
  r, g, b: uint8,
  scale: int,
  lineHeightPx: int,
  struck = false
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Rasterizes text with the board face at `scale`× resolution: LOGICAL dims
  ## out (so 1×-space layout math keeps working), native scale× pixels. Each
  ## line sits on the same lineHeightPx grid the pixel font used; a soft dark
  ## drop shadow keeps thin vector strokes legible over the busy floor. Baked
  ## once per (text, color, scale) — labels re-emit every frame.
  var key = $r & "," & $g & "," & $b & "," & $scale & "," &
    $lineHeightPx & "," & $struck
  for line in lines:
    key.add "\x1f"
    key.add line
  if smoothTextCache.hasKey(key):
    return smoothTextCache[key]
  let
    face = boardTypeface()
    font = newFont(face)
    lineBox = float32(lineHeightPx * scale)
  # The em box slightly under the line box: Rajdhani's ascent+descent overrun
  # their em, and the descenders of p/g/y must stay inside the line grid.
  font.size = lineBox / 1.2
  font.lineHeight = lineBox
  var textW = 1.0'f32
  for line in lines:
    textW = max(textW, font.layoutBounds(line).x)
  let
    pad = scale
    outW = int(ceil(textW)) + pad * 2
    logicalW = max(1, (outW + scale - 1) div scale)
    # One extra logical row so the last line's descenders never clip.
    logicalH = max(1, lines.len * lineHeightPx + 1)
    canvasW = logicalW * scale
    canvasH = logicalH * scale
  var image = newImage(canvasW, canvasH)
  for i, line in lines:
    let
      ty = float32(i * lineHeightPx * scale)
      off = float32(scale) * 0.5
    font.paint = newPaint(SolidPaint)
    font.paint.color = color(0, 0, 0, 0.7)
    image.fillText(font, line, translate(vec2(float32(pad) + off, ty + off)))
    font.paint = newPaint(SolidPaint)
    font.paint.color = color(
      float32(r) / 255, float32(g) / 255, float32(b) / 255, 1)
    image.fillText(font, line, translate(vec2(float32(pad), ty)))
  # Names and pop numerals form a small bounded set, but don't let a churny
  # key population (renames, odd statuses) grow the bake cache forever.
  if smoothTextCache.len > 4096:
    smoothTextCache.clear()
  result.width = logicalW
  result.height = logicalH
  result.pixels = imageToStraightRgba(image)
  if struck:
    for i, line in lines:
      let lineY = (i * lineHeightPx + 3) * scale
      for y in lineY ..< min(lineY + scale, canvasH):
        for x in 0 ..< canvasW:
          let o = (y * canvasW + x) * 4
          result.pixels[o] = 90
          result.pixels[o + 1] = 90
          result.pixels[o + 2] = 90
          result.pixels[o + 3] = 255
  smoothTextCache[key] = result

proc blitRgbaBuffer(
  dst: var seq[uint8],
  dstW, dstH: int,
  src: openArray[uint8],
  srcW, srcH, atX, atY: int
) =
  ## Copies a straight-alpha RGBA buffer into a larger one (src wins where it
  ## has any alpha; the buffers never meaningfully overlap).
  for y in 0 ..< srcH:
    let dy = atY + y
    if dy < 0 or dy >= dstH:
      continue
    for x in 0 ..< srcW:
      let dx = atX + x
      if dx < 0 or dx >= dstW:
        continue
      let
        s = (y * srcW + x) * 4
        d = (dy * dstW + dx) * 4
      if src[s + 3] == 0:
        continue
      dst[d] = src[s]
      dst[d + 1] = src[s + 1]
      dst[d + 2] = src[s + 2]
      dst[d + 3] = src[s + 3]

proc buildFloatingPopSprite(
  game: SimServer, colorIndex: int, text: string, stage: int
): tuple[width, height: int, pixels: seq[uint8]] {.measure.} =
  ## Builds one floating pop label ("-N" damage number or "KO" kill marker):
  ## bright team-tinted glyphs with a dark 1px contour so it pops off any
  ## floor, fading by ALPHA across the pop's short life (the protocol has no
  ## per-object alpha). Cosmetic only, never in gameHash. The tint uses the
  ## VICTIM's team color so it reads as that player's loss, lightened toward
  ## white so the glyphs stay legible.
  let
    font = game.asciiSprites
    textW = max(1, font.textWidth(text))
    glyphH = max(1, font.height)
    width = textW + 2          # 1px contour margin on each side
    height = glyphH + 2
    base = teamPaintRgba(PlayerColors[colorIndex and 0x0f])
    inkR = uint8((base.r.int + 255 * 2) div 3)
    inkG = uint8((base.g.int + 255 * 2) div 3)
    inkB = uint8((base.b.int + 255 * 2) div 3)
    # Alpha-only fade: full at stage 0, nearly gone by the last stage.
    fade = 1.0 - 0.85 * (stage.float / float(max(1, DamagePopStages - 1)))
    alpha = uint8(clamp(255.0 * fade, 0.0, 255.0))
  if boardScale > 1:
    # Supersampled board: the numeral as smooth vector type (its drop shadow
    # plays the old dark contour's role), the stage fade applied to the copy
    # the cache hands back. LOGICAL dims, native pixels.
    result = smoothTextSprite([text], inkR, inkG, inkB, boardScale, height)
    if alpha != 255'u8:
      for i in countup(3, result.pixels.len - 1, 4):
        result.pixels[i] = uint8(result.pixels[i].int * alpha.int div 255)
    return
  result.width = width
  result.height = height
  result.pixels = newRgbaPixels(width, height)
  # Mark the numeral's ink cells, offset by the 1px contour margin.
  var ink = newSeq[bool](width * height)
  var penX = 1
  for ch in text:
    let glyph = font.glyphAt(ch)
    for gy in 0 ..< glyph.height:
      for gx in 0 ..< glyph.width:
        if glyph.glyphPixel(gx, gy):
          let
            ix = penX + gx
            iy = 1 + gy
          if ix >= 0 and ix < width and iy >= 0 and iy < height:
            ink[iy * width + ix] = true
    penX += font.glyphAdvance(ch)
  # Paint: ink cells bright; any cell 4-adjacent to ink gets a dark contour so
  # the number never smears into the floor. The contour fades with the number.
  for iy in 0 ..< height:
    for ix in 0 ..< width:
      let i = iy * width + ix
      if ink[i]:
        result.pixels.putRawRgbaPixel(i, inkR, inkG, inkB, alpha)
      else:
        var nearInk = false
        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
          let
            nx = ix + dx
            ny = iy + dy
          if nx >= 0 and nx < width and ny >= 0 and ny < height and
              ink[ny * width + nx]:
            nearInk = true
            break
        if nearInk:
          result.pixels.putRawRgbaPixel(i, 20, 16, 14, alpha)

proc buildMapSpritePixels(sim: SimServer): seq[uint8] {.measure.} =
  ## Returns the true-color map pixels for a global protocol sprite.
  if sim.mapRgba.len == sim.gameMap.width * sim.gameMap.height * 4:
    return sim.mapRgba
  result = newRgbaPixels(sim.gameMap.width, sim.gameMap.height)
  for i in 0 ..< sim.mapPixels.len:
    result.putRgbaPixel(i, sim.mapPixels[i])

proc boardMapPixels(sim: SimServer): seq[uint8] {.measure.} =
  ## The board-scale RGBA map for the spectator stream: the shared 1× map at
  ## boardScale 1, otherwise the NATIVE boardScale× arena bake.
  if boardScale <= 1:
    return sim.buildMapSpritePixels()
  sim.boardScaledMapPixels()

var
  boardMapBandsCache: seq[uint8]
  boardMapBandsDefs: seq[SpriteDefinition]
    ## Process-wide cache of the boardScale× map band sprite+object wire
    ## messages and the sprite defs they imply. The bands are byte-identical
    ## for every viewer, and re-encoding them per connection (13 MB of band
    ## copies + snappy at RenderScale 2) cost ~1 s of the hosted certifier's
    ## 10-second first-frame budget.

proc addMapBands(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  packet: var seq[uint8]
) {.measure.} =
  ## Emits the static arena map as a stack of horizontal bands instead of one
  ## giant sprite. Each band is a full-width crop placed at its own y-offset on
  ## the map layer — the client composites them into one seamless image (it
  ## blits every object at obj.x/obj.y, so adjacent bands tile with no seam).
  ## This keeps the map pixel-identical while ensuring no single sprite message
  ## approaches the hosted 1 MiB WS frame cap: the LOGICAL rows per band shrink
  ## by boardScale² so each band's byte size stays at the proven 1× level no
  ## matter the board scale. Like the old single map object, bands are emitted
  ## once at init and never tracked in objectIds, so the per-frame delete diff
  ## leaves them on the client forever.
  let
    h = sim.gameMap.height
    outW = sim.gameMap.width * boardScale
    logicalBandH = max(1, MapBandHeight div (boardScale * boardScale))
  # Per-viewer dedup up front (the same check addSpriteChanged would do per
  # band): once this viewer holds the first band at this scale it holds all
  # of them, so repeat calls append nothing.
  block:
    let sentinel = spriteDefs.spriteDefinitionIndex(MapBandSpriteBase)
    if sentinel >= 0 and spriteDefs[sentinel].width == outW:
      return
  if boardScale > 1 and boardMapBandsCache.len > 0:
    # Cached wire bytes: register the defs for this viewer, splice the bytes.
    for def in boardMapBandsDefs:
      let index = spriteDefs.spriteDefinitionIndex(def.spriteId)
      if index >= 0:
        spriteDefs[index] = def
      else:
        spriteDefs.add def
    packet.add boardMapBandsCache
    return
  let mapPixels = sim.boardMapPixels()
  var
    encoded: seq[uint8]
    encodedDefs: seq[SpriteDefinition]
    band = 0
    y0 = 0
  while y0 < h:
    let
      bandH = min(logicalBandH, h - y0)
      outBandH = bandH * boardScale
      outY0 = y0 * boardScale
    var bandPixels = newSeq[uint8](outW * outBandH * 4)
    copyMem(bandPixels[0].addr, mapPixels[outY0 * outW * 4].unsafeAddr,
      outW * outBandH * 4)
    let
      spriteId = MapBandSpriteBase + band
      objectId = MapBandObjectBase + band
    encoded.addSpriteChanged(
      encodedDefs, spriteId, outW, outBandH, bandPixels, "map band " & $band)
    encoded.addBoardObject(objectId, 0, y0, low(int16), MapLayerId, spriteId)
    inc band
    y0 += bandH
  if boardScale > 1:
    boardMapBandsCache = encoded
    boardMapBandsDefs = encodedDefs
  for def in encodedDefs:
    let index = spriteDefs.spriteDefinitionIndex(def.spriteId)
    if index >= 0:
      spriteDefs[index] = def
    else:
      spriteDefs.add def
  packet.add encoded

proc invalidateBoardMapCaches*() =
  ## Drops every process-wide cache derived from the current map's pixels.
  ## Needed when the serve loop hot-switches replays: the new sim carries a new
  ## map, but these globals are keyed by nothing (the band bytes) or by byte
  ## size alone (the arena and endzone bakes), so a same-size map would keep
  ## serving the previous arena's pixels to every new viewer. Team/skin sprite
  ## caches are map-independent and survive.
  boardMapCache = @[]
  boardColdMapCache = @[]
  EndzoneColdRgba = @[]
  EndzoneStripCache = default(typeof(EndzoneStripCache))
  EndzoneDiffBox = default(typeof(EndzoneDiffBox))
  EndzoneDiffBoxReady = default(typeof(EndzoneDiffBoxReady))
  boardMapBandsCache = @[]
  boardMapBandsDefs = @[]

proc chunkSpritePacket*(packet: seq[uint8], maxBytes: int): seq[seq[uint8]] =
  ## Splits one sprite-protocol packet into WS-frame-sized chunks at MESSAGE
  ## boundaries. The client parses each binary WS message independently and
  ## accumulates sprite/object state across them, so a packet delivered as N
  ## frames is equivalent to one frame — as long as no frame is cut mid-message.
  ## Needed because the hosted replay closes any frame over 1 MiB (1009); even
  ## with the map banded, the init packet's TOTAL can exceed that in one send.
  ## A single message larger than maxBytes is emitted as its own (oversized)
  ## chunk rather than split — the map bands guarantee that never happens.
  result = @[]
  if packet.len == 0:
    return
  var
    offset = 0
    chunkStart = 0
  while offset < packet.len:
    let msgStart = offset
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01:  # sprite: id,w,h (6) + clen (4) + pixels + llen (2) + label
      let clen = packet.readU32(offset + 6)
      offset += 10 + clen
      let llen = packet.readU16(offset)
      offset += 2 + llen
    of 0x02: offset += 11   # object
    of 0x03: offset += 2    # delete object
    of 0x04: discard        # clear objects (no payload)
    of 0x05: offset += 5    # viewport
    of 0x06: offset += 3    # layer
    else:
      # Unknown message: we can't measure it, so flush what we have and ship the
      # remainder whole rather than risk a mid-message cut.
      break
    # If appending this message would overflow the current chunk, close the
    # chunk at the previous message boundary first (unless it's empty).
    if offset - chunkStart > maxBytes and msgStart > chunkStart:
      result.add(packet[chunkStart ..< msgStart])
      chunkStart = msgStart
  if chunkStart < packet.len:
    result.add(packet[chunkStart ..< packet.len])

proc buildWalkabilitySpritePixels(sim: SimServer): seq[uint8] {.measure.} =
  ## Returns a binary RGBA walkability mask for sprite agents.
  result = newSeq[uint8](sim.gameMap.width * sim.gameMap.height * 4)
  for i in 0 ..< sim.gameMap.width * sim.gameMap.height:
    let offset = i * 4
    let walkable =
      if i < sim.walkMask.len:
        sim.walkMask[i]
      elif i < sim.wallMask.len:
        not sim.wallMask[i]
      else:
        true
    if walkable:
      result[offset] = 255
      result[offset + 1] = 255
      result[offset + 2] = 255
      result[offset + 3] = 255

proc mapMarkerSpriteId(index: int): int =
  ## Returns the stable sprite id for one static map marker.
  MapMarkerSpriteBase + index

proc mapMarkerObjectId(index: int): int =
  ## Returns the stable object id for one static map marker.
  MapMarkerObjectBase + index

proc addMapMarker(
  packet: var seq[uint8],
  spriteDefs: var seq[SpriteDefinition],
  index, x, y, width, height: int,
  label: string
) {.measure.} =
  ## Adds one invisible labeled marker object to the map layer.
  let
    spriteId = mapMarkerSpriteId(index)
    objectId = mapMarkerObjectId(index)
  packet.addBoardSpriteChanged(
    spriteDefs,
    spriteId,
    width,
    height,
    newRgbaPixels(width, height),
    label
  )
  packet.addBoardObject(objectId, x, y, MapMarkerZ, MapLayerId, spriteId)

proc endzoneShapeToken(gameMap: CtfMap, zone: CaptureZone): string =
  ## Maps one team's capture zone onto the closed shape vocabulary of the
  ## endzone marker (see LabelEndzoneShapes). The zone's own refinement flags
  ## outrank the map fields: `disc`/`diag` say how membership is actually
  ## tested, the layout/endzone fields only distinguish the box-filling
  ## shapes from each other.
  if zone.disc:
    LabelEndzoneShapeDisc
  elif zone.diag:
    LabelEndzoneShapeCorner
  elif gameMap.layout == layoutPlus:
    LabelEndzoneShapeArm
  elif gameMap.endzone == ezSquare:
    LabelEndzoneShapeSquare
  else:
    LabelEndzoneShapeColumn

proc addMapMarkers(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  packet: var seq[uint8]
) {.measure.} =
  ## Adds invisible room markers for sprite agents, plus the episode-parameter
  ## marker stating the team count and map size outright (see
  ## LabelPrefixGameParams) — so a policy reads the game shape at t=0 instead
  ## of inferring it from room markers and layer viewports — and one endzone
  ## marker per team stating its capture zone's shape and bounding-box
  ## corners (see LabelPrefixEndzone).
  var index = 0
  for room in sim.rooms:
    packet.addMapMarker(
      spriteDefs,
      index,
      room.x,
      room.y,
      room.w,
      room.h,
      "Room " & room.name
    )
    inc index
  packet.addMapMarker(
    spriteDefs,
    index,
    0,
    0,
    1,
    1,
    labelGameParams(
      sim.gameMap.teamCount(),
      sim.gameMap.width,
      sim.gameMap.height
    )
  )
  inc index
  for team in sim.gameMap.teams():
    let zone = sim.gameMap.captureZone(team)
    if zone.diag:
      ## The `corner` contract promises the threshold diagonal joins the two
      ## box corners adjacent to the map corner — true exactly when the L1
      ## limit was not clamped by the far map edges. HomeDepth's bounds keep
      ## anchors well inside the clamp on every map class; hold that here so
      ## a retune cannot silently bend the stated geometry.
      doAssert zone.diagLimit == zone.xHi - zone.xLo and
          zone.diagLimit == zone.yHi - zone.yLo,
        "clamped diagonal capture zone breaks the corner-marker contract"
    packet.addMapMarker(
      spriteDefs,
      index,
      zone.xLo,
      zone.yLo,
      1,
      1,
      labelEndzone(
        teamText(team),
        sim.gameMap.endzoneShapeToken(zone),
        zone.xLo,
        zone.yLo,
        zone.xHi,
        zone.yHi
      )
    )
    inc index

proc buildFogRunSprite(widthCells: int): seq[uint8] {.measure.} =
  ## Builds one translucent dark fog run sprite covering `widthCells`
  ## horizontally-adjacent 8px visibility cells.
  let
    width = widthCells * FovCellSize
    height = FovCellSize
  result = newSeq[uint8](width * height * 4)
  for i in 0 ..< width * height:
    result.putRawRgbaPixel(i, 0, 0, 0, FogAlpha)

proc fogRunSpriteId(widthCells: int): int =
  ## Returns the sprite id for one fog run width.
  FogRunSpriteBase + widthCells

proc addFogRuns(
  sim: SimServer,
  playerIndex: int,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8]
) {.measure.} =
  ## Places the viewer's fog overlay: one translucent dark run object per
  ## horizontal stretch of unseen cells on each visibility grid row, drawn on
  ## the fog layer above the map. Overflowing the object pool drops the
  ## shortest runs (cosmetic only; entity culling is exact regardless).
  let visible = sim.playerFov(playerIndex).visible
  var runs: seq[tuple[cx, cy, width: int]] = @[]
  for cy in 0 ..< FovGridH:
    var cx = 0
    while cx < FovGridW:
      if visible[fovCellIndex(cx, cy)]:
        inc cx
        continue
      var runEnd = cx
      while runEnd < FovGridW and not visible[fovCellIndex(runEnd, cy)]:
        inc runEnd
      runs.add((cx: cx, cy: cy, width: runEnd - cx))
      cx = runEnd
  if runs.len > FogMaxRuns:
    runs.sort(proc(a, b: tuple[cx, cy, width: int]): int = cmp(b.width, a.width))
    runs.setLen(FogMaxRuns)
  for runIndex, run in runs:
    let spriteId = fogRunSpriteId(run.width)
    if spriteDefs.spriteDefinitionIndex(spriteId) < 0:
      # Building the pixel buffer is the expensive part: only do it the
      # first time this run width is seen on this connection.
      packet.addBoardSpriteChanged(
        spriteDefs,
        spriteId,
        run.width * FovCellSize,
        FovCellSize,
        buildFogRunSprite(run.width),
        "fog"
      )
    let objectId = FogObjectBase + runIndex
    currentIds.add(objectId)
    packet.addBoardObject(
      objectId,
      run.cx * FovCellSize,
      run.cy * FovCellSize,
      0,
      FogLayerId,
      spriteId
    )

proc putTextSpritePixel(
  pixels: var seq[uint8],
  width, height, x, y: int,
  color: uint8
) =
  ## Puts one protocol pixel into a text sprite.
  if x < 0 or y < 0 or x >= width or y >= height:
    return
  pixels.putRgbaPixel(y * width + x, color)

proc blitGlyph(
  target: var seq[uint8],
  targetWidth, targetHeight: int,
  glyph: PixelGlyph,
  baseX, baseY: int,
  color: uint8
) =
  ## Blits a single-color glyph into protocol pixels.
  for y in 0 ..< glyph.height:
    for x in 0 ..< glyph.width:
      if not glyph.glyphPixel(x, y):
        continue
      target.putTextSpritePixel(
        targetWidth,
        targetHeight,
        baseX + x,
        baseY + y,
        color
      )

proc blitFontText(
  target: var seq[uint8],
  targetWidth, targetHeight: int,
  font: PixelFont,
  text: string,
  baseX, baseY: int,
  color: uint8,
  bold = false
) =
  ## Blits single-color text in a given pixel font into protocol pixels. When
  ## bold, each glyph is overdrawn one pixel to the right (a faux-bold that
  ## thickens vertical strokes) and the advance is widened by one so the extra
  ## column never bleeds into the next letter.
  var x = baseX
  for ch in text:
    let glyph = font.glyphAt(ch)
    target.blitGlyph(targetWidth, targetHeight, glyph, x, baseY, color)
    if bold:
      target.blitGlyph(targetWidth, targetHeight, glyph, x + 1, baseY, color)
    x += font.glyphAdvance(ch) + (if bold: 1 else: 0)

proc blitSmallText(
  game: SimServer,
  target: var seq[uint8],
  targetWidth, targetHeight: int,
  text: string,
  baseX, baseY: int,
  color: uint8
) =
  ## Blits small (tiny5 HUD font) text into protocol pixels.
  target.blitFontText(
    targetWidth, targetHeight, game.asciiSprites, text, baseX, baseY, color
  )

proc buildSpriteProtocolTextSprite(
  game: SimServer,
  lines: openArray[string],
  color: uint8,
  struck = false,
  smooth = false
): tuple[width, height: int, pixels: seq[uint8]] {.measure.} =
  ## Builds a transparent multi-line text sprite. With `smooth` (and a
  ## supersampled board), the vector face at boardScale× — LOGICAL dims,
  ## native pixels; callers emit with native = boardScale.
  if smooth and boardScale > 1:
    let c = Palette[color and 0x0f]
    return smoothTextSprite(lines, c.r, c.g, c.b, boardScale, TextLineHeight,
      struck)
  result.width = 1
  for line in lines:
    result.width = max(result.width, game.asciiSprites.textWidth(line))
  result.height = max(1, lines.len * TextLineHeight)
  result.pixels = newRgbaPixels(result.width, result.height)
  for lineIndex, line in lines:
    let baseY = lineIndex * TextLineHeight
    var baseX = 0
    for ch in line:
      let glyph = game.asciiSprites.glyphAt(ch)
      result.pixels.blitGlyph(
        result.width,
        result.height,
        glyph,
        baseX,
        baseY,
        color
      )
      baseX += game.asciiSprites.glyphAdvance(ch)
    if struck:
      let lineY = baseY + 3
      for x in 0 ..< game.asciiSprites.textWidth(line):
        result.pixels.putTextSpritePixel(
          result.width,
          result.height,
          x,
          lineY,
          3'u8
        )

proc textLabel(lines: openArray[string]): string =
  ## Returns a debugger label for one rendered text sprite.
  for i, line in lines:
    if i > 0:
      result.add("\n")
    result.add(line)

proc buildSmoothShoutBubble(
  game: SimServer,
  team: Team,
  text: string,
  k: int
): tuple[width, height: int, pixels: seq[uint8]] =
  ## The comic speech bubble re-drawn as smooth vector art for the k×
  ## supersampled board: true rounded corners, an antialiased team outline, and
  ## the shout text set in the board face. Same silhouette and proportions as
  ## the pixel bubble; LOGICAL dims out, native k× pixels.
  let
    face = boardTypeface()
    font = newFont(face)
    lineBox = float32(game.shoutFont.height * k)
  font.size = lineBox / 1.1
  font.lineHeight = lineBox
  let
    textW = font.layoutBounds(text).x
    pillW = int(ceil(textW)) + 2 * ShoutPadX * k
    pillH = game.shoutFont.height * k + 2 * ShoutPadY * k
    outW = pillW
    outH = pillH + ShoutTailH * k
    logicalW = max(1, (outW + k - 1) div k)
    logicalH = max(1, (outH + k - 1) div k)
    canvasW = logicalW * k
    canvasH = logicalH * k
    edge = Palette[teamColor(team) and 0x0f]
    edgeColor = color(
      float32(edge.r) / 255, float32(edge.g) / 255, float32(edge.b) / 255, 1)
    paperColor = color(1, 241 / 255, 232 / 255, 240 / 255)
    stroke = float32(k)
    radius = float32(2 * k)
    tailCx = float32(pillW div 2)
  var image = newImage(canvasW, canvasH)
  let pill = rect(
    stroke / 2, stroke / 2,
    float32(pillW) - stroke, float32(pillH) - stroke)
  # Tail first (a filled triangle with its own outline), pill drawn over it so
  # the joint is seamless.
  var tail = newPath()
  let
    tailTopY = float32(pillH) - stroke
    tailTipY = float32(pillH + ShoutTailH * k) - stroke / 2
    tailHalf = float32(ShoutTailH * k)
  tail.moveTo(tailCx - tailHalf, tailTopY)
  tail.lineTo(tailCx + tailHalf, tailTopY)
  tail.lineTo(tailCx, tailTipY)
  tail.closePath()
  image.fillPath(tail, paperColor)
  image.strokePath(tail, edgeColor, strokeWidth = stroke)
  var pillPath = newPath()
  pillPath.roundedRect(pill, radius, radius, radius, radius)
  image.fillPath(pillPath, paperColor)
  image.strokePath(pillPath, edgeColor, strokeWidth = stroke)
  font.paint = newPaint(SolidPaint)
  font.paint.color = color(30 / 255, 24 / 255, 20 / 255, 1)
  image.fillText(font, text,
    translate(vec2(float32(ShoutPadX * k), float32(ShoutPadY * k))))
  result.width = logicalW
  result.height = logicalH
  result.pixels = imageToStraightRgba(image)

proc buildShoutBubble(
  game: SimServer,
  team: Team,
  text: string
): tuple[width, height: int, pixels: seq[uint8]] {.measure.} =
  ## A kid-friendly comic speech bubble for one shout: dark ink on a cream
  ## "paper" pill with rounded corners, a chunky team-colored outline, and a
  ## little tail pointing down at the shouter. Drawn with the chunky 9px shout
  ## font (not the 6px tiny5 HUD font) so it reads at full desktop size, and
  ## in-world with the rest of the pixel art — never as an HD overlay. On the
  ## supersampled board the vector variant replaces it (same silhouette).
  if boardScale > 1:
    return game.buildSmoothShoutBubble(team, text, boardScale)
  let
    font = game.shoutFont
    # Bold widens each glyph's advance by 1 and overdraws 1px past the last
    # glyph, so reserve text.len + 1 extra columns of paper for it.
    boldExtra = text.len + 1
    textW = max(1, font.textWidth(text)) + boldExtra
    pillW = textW + 2 * ShoutPadX
    pillH = font.height + 2 * ShoutPadY
    width = pillW
    height = pillH + ShoutTailH
    edge = Palette[teamColor(team) and 0x0f]  # team-colored outline
    tailCx = pillW div 2                       # tail centered under the pill
  result.width = width
  result.height = height
  result.pixels = newRgbaPixels(width, height)

  proc rounded(x, y, w, h: int): bool =
    ## True when (x, y) is inside a 1px-corner-clipped rounded rectangle.
    if x < 0 or y < 0 or x >= w or y >= h:
      return false
    let corner = (x == 0 or x == w - 1) and (y == 0 or y == h - 1)
    not corner

  # Paper fill + team outline for the pill body.
  for y in 0 ..< pillH:
    for x in 0 ..< pillW:
      if not rounded(x, y, pillW, pillH):
        continue
      let onEdge =
        x <= 0 or x >= pillW - 1 or y <= 0 or y >= pillH - 1 or
        not rounded(x - 1, y, pillW, pillH) or
        not rounded(x + 1, y, pillW, pillH) or
        not rounded(x, y - 1, pillW, pillH) or
        not rounded(x, y + 1, pillW, pillH)
      let i = y * width + x
      if onEdge:
        result.pixels.putRawRgbaPixel(i, edge.r, edge.g, edge.b, 255)
      else:
        result.pixels.putRawRgbaPixel(i, 255, 241, 232, 240)  # palette paper

  # Tail: a shrinking triangle of paper with a team-colored left/right lip,
  # so the bubble points at the shouter's head.
  for row in 0 ..< ShoutTailH:
    let
      half = ShoutTailH - row              # tail narrows toward the tip
      y = pillH + row
    for dx in -half .. half:
      let x = tailCx + dx
      if x < 0 or x >= width:
        continue
      let i = y * width + x
      if dx == -half or dx == half or row == ShoutTailH - 1:
        result.pixels.putRawRgbaPixel(i, edge.r, edge.g, edge.b, 255)
      else:
        result.pixels.putRawRgbaPixel(i, 255, 241, 232, 240)

  # Bold dark ink text in the chunky shout font, centered on the paper.
  result.pixels.blitFontText(
    width, height, font, text,
    ShoutPadX, ShoutPadY, 0'u8,  # palette 0 = near-black ink
    bold = true
  )

proc centeredTextX(sim: SimServer, text: string): int =
  ## Returns the centered x position for interstitial text.
  (ScreenWidth - sim.asciiSprites.textWidth(text)) div 2

proc addTeamScoreboard(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8]
) {.measure.} =
  ## Adds the team kills/deaths scoreboard above the field: red on the left,
  ## blue on the right, each in its team color. Playing only — interstitial
  ## screens put their own title in the same top-center spot.
  if sim.phase != Playing:
    return
  var kills, deaths: array[Team, int]
  for p in sim.players:
    kills[p.team] += p.kills
    deaths[p.team] += p.deaths
  # One "NAME k/d" text sprite per active team, laid out left to right in
  # enum order and centered as a group (the classic red-left/blue-right
  # strip is the 2-team case).
  var chips: seq[tuple[team: Team, text: string,
    sprite: tuple[width, height: int, pixels: seq[uint8]]]]
  var totalWidth = -TeamScoreGap
  for team in sim.teams():
    let text = teamText(team).toUpperAscii() & " " &
      $kills[team] & "/" & $deaths[team]
    let sprite = sim.buildSpriteProtocolTextSprite([text], teamColor(team))
    totalWidth += sprite.width + TeamScoreGap
    chips.add((team: team, text: text, sprite: sprite))
  var x = max(0, (TeamScoreWidth - totalWidth) div 2)
  for chip in chips:
    let slot = ord(chip.team)
    packet.addSpriteChanged(
      spriteDefs,
      TeamScoreSpriteBase + slot,
      chip.sprite.width,
      chip.sprite.height,
      chip.sprite.pixels,
      "team score " & chip.text
    )
    currentIds.add(TeamScoreObjectBase + slot)
    packet.addBoardObject(
      TeamScoreObjectBase + slot,
      x,
      1,
      0,
      TeamScoreLayerId,
      TeamScoreSpriteBase + slot
    )
    x += chip.sprite.width + TeamScoreGap

proc addTextItem(
  items: var seq[ProtocolTextItem],
  x, y: int,
  lines: openArray[string],
  label = "",
  color = ProtocolTextColor,
  struck = false
) =
  ## Adds one text sprite placement to an interstitial layout.
  let index = items.len
  var item = ProtocolTextItem(
    spriteId: ProtocolTextSpriteBase + index,
    objectId: ProtocolTextObjectBase + index,
    x: x,
    y: y,
    z: ProtocolTextZ,
    color: color,
    struck: struck
  )
  for line in lines:
    item.lines.add(line)
  item.label =
    if label.len > 0:
      label
    else:
      textLabel(lines)
  items.add(item)

proc teamTitle(team: Team): string =
  ## Returns the scoreboard/game-over title for a team.
  teamText(team).toUpperAscii() & " WINS"

proc interstitialTextItems(
  sim: SimServer,
  playerIndex: int
): seq[ProtocolTextItem] =
  ## Returns separate text sprites for one interstitial player screen.
  case sim.phase
  of Lobby:
    let needed = max(0, sim.config.minPlayers - sim.players.len)
    if needed > 0:
      result.addTextItem(sim.centeredTextX("WAITING"), 4, ["WAITING"])
      result.addTextItem(sim.centeredTextX("NEED MORE!"), 14, ["NEED MORE!"])
    else:
      result.addTextItem(sim.centeredTextX("GAME"), 2, ["GAME"])
      result.addTextItem(sim.centeredTextX("STARTING"), 11, ["STARTING"])
      let
        seconds = sim.lobbyStartSecondsRemaining()
        line = "IN " & $seconds
      if seconds > 0:
        result.addTextItem(sim.centeredTextX(line), 20, [line])
  of Playing:
    if playerIndex < 0 or playerIndex >= sim.players.len:
      let
        gap = 10
        blockH = sim.asciiSprites.height * 2 + gap
        startY = (ScreenHeight - blockH) div 2
      result.addTextItem(sim.centeredTextX("GAME IN"), startY, ["GAME IN"])
      result.addTextItem(
        sim.centeredTextX("PROGRESS"),
        startY + sim.asciiSprites.height + gap,
        ["PROGRESS"]
      )
  of GameOver:
    let title =
      if sim.isDraw:
        "DRAW"
      else:
        teamTitle(sim.winner)
    let
      titleW = sim.asciiSprites.textWidth(title)
      titleX = (ScreenWidth - titleW) div 2
      rowH = 14
      rowsPerCol = 8
      colW = ScreenWidth div 2
      textOffsetX = 19
      startY = 16
    result.addTextItem(titleX, 2, [title])
    for i in 0 ..< sim.players.len:
      let
        p = sim.players[i]
        col = i div rowsPerCol
        row = i mod rowsPerCol
        baseX = min(col, 1) * colW
        textX = baseX + textOffsetX
        textY = startY + row * rowH + (rowH - 6) div 2
        tag = teamText(p.team).toUpperAscii()
      result.addTextItem(textX, textY, [tag], struck = (p.lives <= 0 and not p.alive))

proc addProtocolTextSprites(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8],
  layer: int,
  playerIndex: int
) {.measure.} =
  ## Adds separate text sprites for current interstitial text.
  let items = sim.interstitialTextItems(playerIndex)
  for item in items:
    let text = sim.buildSpriteProtocolTextSprite(
      item.lines,
      item.color,
      item.struck
    )
    currentIds.add(item.objectId)
    packet.addSpriteChanged(
      spriteDefs,
      item.spriteId,
      text.width,
      text.height,
      text.pixels,
      item.label,
      changed = item.struck or item.color != ProtocolTextColor
    )
    packet.addBoardObject(
      item.objectId,
      item.x,
      item.y,
      item.z,
      layer,
      item.spriteId
    )

proc gameOverIconSpriteId(team: Team): int =
  ## Compact roster-chip soldier sprite id for the game-over list.
  GameOverIconSpriteBase + ord(team)

proc addProtocolGameOverActorSprites(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8],
  layer: int
) {.measure.} =
  ## Adds separate player sprites for the game over interstitial.
  if sim.phase != GameOver:
    return
  for team in sim.teams():
    packet.addSpriteChanged(
      spriteDefs,
      gameOverIconSpriteId(team),
      GameOverIconSize,
      GameOverIconSize,
      soldierIconPixels(team, GameOverIconSize),
      "roster " & teamText(team)
    )
  let
    rowH = 14
    rowsPerCol = 8
    colW = ScreenWidth div 2
    iconOffsetX = 4
    startY = 16
  for i in 0 ..< sim.players.len:
    let
      player = sim.players[i]
      col = i div rowsPerCol
      row = i mod rowsPerCol
      baseX = min(col, 1) * colW
      y = startY + row * rowH
      iconX = baseX + iconOffsetX
      iconY = y + (rowH - GameOverIconSize) div 2
      objectId = ProtocolGameOverIconObjectBase + i
    currentIds.add(objectId)
    packet.addBoardObject(
      objectId,
      iconX - 1,
      iconY - 1,
      30000,
      layer,
      gameOverIconSpriteId(player.team)
    )

proc addProtocolInterstitialActorSprites(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8],
  layer, playerIndex: int
) {.measure.} =
  ## Adds separate actor sprites for sprite protocol interstitials.
  case sim.phase
  of GameOver:
    sim.addProtocolGameOverActorSprites(spriteDefs, currentIds, packet, layer)
  else:
    discard

proc hasInterstitialFrame(sim: SimServer): bool =
  ## Returns true when the global viewer should show a neutral game screen.
  sim.phase in {Lobby, GameOver}

proc addSpriteProtocolInterstitialSprites(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  packet: var seq[uint8]
) {.measure.} =
  ## Adds reusable sprites for non-playing screens.
  packet.addSpriteChanged(
    spriteDefs,
    SpritePlayerInterstitialSpriteId,
    ScreenWidth,
    ScreenHeight,
    buildIndexedSpritePixels(
      sim.darkBgPixels,
      ScreenWidth,
      ScreenHeight,
      SpaceColor
    ),
    "interstitial background"
  )

proc buildFlagBannerSprite(team: Team): seq[uint8] {.measure.} =
  ## The carried CTF objective: a glowing team-colored HEART-GEM relic (Red =
  ## crimson life-crystal, Blue = frost life-crystal), loaded from the hand-
  ## painted PNG and scaled to the small carried footprint. 0.7.0 renamed the
  ## "flag" a heart in-sim ("heart returned home"), so the object reads as a
  ## life-crystal you steal, not a banner. The PNG's bold dark outline and
  ## feathered alpha let it read on any floor, matching the pedestal art style.
  ## Rasterized from the ~450px painted master at scale× the carried footprint.
  loadHeartSprite(team, FlagBannerW * boardScale)

proc buildCarryHeartSprite(team: Team, aimStep: int): seq[uint8] {.measure.} =
  ## The carried heart RIGIDLY LOCKED to the cog's grip: rotated to the aim step so
  ## its orientation turns WITH the cog (never floats/tumbles free), plus a fixed
  ## PERPENDICULAR offset so the pointed end faces to the SIDE (not along the aim) —
  ## the cog cradles it sideways in its arms out front, held. As the cog turns, the
  ## heart turns with it, so it always reads as gripped. Baked per aim step (like the
  ## gun) so position AND orientation track the aim together.
  let
    size = FlagBannerW * boardScale
    src = loadHeartSprite(team, size)
  var img = newImage(size, size)
  for i in 0 ..< size * size:
    img.data[i] = rgba(src[i*4], src[i*4+1], src[i*4+2], src[i*4+3]).rgbx()
  # aim increases CCW (0=east); screen y is down, so rotate by -aimAngle to track it.
  # +PI turns the point PERPENDICULAR to the aim (to the side), the cradled pose.
  let aimAngle = float(aimStep) * 2.0 * PI / float(SoldierRotations)
  let rotated = newImage(size, size)
  let m = translate(vec2(float32(size) / 2, float32(size) / 2)) *
    rotate(float32(-aimAngle + PI)) *
    translate(vec2(float32(-size) / 2, float32(-size) / 2))
  rotated.draw(img, m)
  result = newSeq[uint8](size * size * 4)
  for i in 0 ..< size * size:
    let c = rotated.data[i].rgba()
    result[i*4] = c.r; result[i*4+1] = c.g; result[i*4+2] = c.b; result[i*4+3] = c.a

proc buildPlantedFlagSprite(team: Team): seq[uint8] {.measure.} =
  ## The HOME heart-gem, loaded NATIVELY at the big pedestal footprint (not an
  ## upscale of the tiny carried sprite) so the hand-painted facets stay crisp.
  ## It reads as a real objective standing on the pedestal, not a thumbnail.
  loadHeartSprite(team, PlantedFlagW * boardScale)

proc buildFlagAuraSprite(team: Team): seq[uint8] {.measure.} =
  ## Builds the soft carrier halo in the FLAG's team color: a feathered disc
  ## drawn UNDER the carrier so the flag-runner is the brightest, most-tracked
  ## figure on the board (TagPro / TF2 carrier-glow convention). A blue player
  ## carrying the red flag glows red. Semi-transparent so it tints the floor
  ## without hiding the runner. Analytic — rasterized at the emission scale.
  let outSize = FlagAuraSize * boardScale
  result = newRgbaPixels(outSize, outSize)
  let
    base = Palette[teamColor(team) and 0x0f]
    c = float(outSize - boardScale) / 2
  for y in 0 ..< outSize:
    for x in 0 ..< outSize:
      let d = sqrt((float(x) - c) * (float(x) - c) + (float(y) - c) * (float(y) - c))
      if d > c:
        continue
      let alpha = uint8(min(150.0, 30.0 + 130.0 * (1.0 - d / c)))
      result.putRawRgbaPixel(
        y * outSize + x,
        uint8((base.r.int + 255) div 2),
        uint8((base.g.int + 255) div 2),
        uint8((base.b.int + 255) div 2),
        alpha
      )

proc flagLabel(team: Team): string =
  ## Returns the observation label for one team's flag sprite.
  labelFlag(teamText(team))

proc carryHeartSpriteId(team: Team, aimStep: int): int =
  ## The carried-heart sprite id at aim step `aimStep` (cradled in the rig cog's
  ## arms, rotating with the aim so it stays gripped).
  CarryHeartSpriteBase + ord(team) * SoldierRotations + aimStep

proc addFlagSprites(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  packet: var seq[uint8]
) {.measure.} =
  ## Adds every active team's banner sprites (carried + big planted) plus
  ## carrier halos. The builders raster at the emission scale, so pass
  ## native = boardScale.
  for team in sim.teams():
    packet.addBoardSpriteChanged(
      spriteDefs,
      FlagSpriteBase + ord(team),
      FlagBannerW,
      FlagBannerH,
      buildFlagBannerSprite(team),
      flagLabel(team),
      native = boardScale
    )
    packet.addBoardSpriteChanged(
      spriteDefs,
      PlantedFlagSpriteBase + ord(team),
      PlantedFlagW,
      PlantedFlagH,
      buildPlantedFlagSprite(team),
      labelFlagPlanted(teamText(team)),
      native = boardScale
    )
    packet.addBoardSpriteChanged(
      spriteDefs,
      FlagAuraSpriteBase + ord(team),
      FlagAuraSize,
      FlagAuraSize,
      buildFlagAuraSprite(team),
      flagLabel(team) & " carrier glow",
      native = boardScale
    )
  # The carried heart is baked PER AIM STEP (team×16) so it rotates with the cog;
  # defined lazily in the board flag loop (only the carrier's current aim is drawn).

proc soldierOutlined(
  pixels: seq[uint8],
  outline: uint8,
  renderScale = 1
): seq[uint8] =
  ## Returns a copy of a rasterized soldier sprite with a selected-outline:
  ## any transparent pixel within 2 (logical) px of a solid one is painted the
  ## outline color. Matches the legacy selected-crew highlight, but on
  ## true-color art. The sprite is a SoldierCanvas·renderScale square; the
  ## outline width scales with it so the highlight keeps its 1× weight.
  result = pixels
  let
    canvas = SoldierCanvas * renderScale
    reach = 2 * renderScale
    n = canvas * canvas
    oc = Palette[outline and 0x0f]
  var solid = newSeq[bool](n)
  for i in 0 ..< n:
    solid[i] = pixels[i * 4 + 3] >= 64'u8
  for y in 0 ..< canvas:
    for x in 0 ..< canvas:
      let i = y * canvas + x
      if solid[i]:
        continue
      var adjacent = false
      for dy in -reach .. reach:
        for dx in -reach .. reach:
          let nx = x + dx
          let ny = y + dy
          if nx < 0 or ny < 0 or nx >= canvas or ny >= canvas:
            continue
          if solid[ny * canvas + nx]:
            adjacent = true
      if adjacent:
        result.putRawRgbaPixel(i, oc.r, oc.g, oc.b, oc.a)

proc soldierCorpse(pixels: seq[uint8]): seq[uint8] =
  ## Returns a copy of a soldier sprite recolored as a corpse: every solid
  ## pixel desaturates to grey (luma-weighted) and drops to ~55% opacity, so a
  ## body reads as fallen debris — never a live soldier — in the ghost view.
  ## Works at any raster scale (dims come from the buffer).
  result = pixels
  let n = pixels.len div 4
  for i in 0 ..< n:
    let a = pixels[i * 4 + 3]
    if a == 0'u8:
      continue
    let
      r = pixels[i * 4].int
      g = pixels[i * 4 + 1].int
      b = pixels[i * 4 + 2].int
      luma = uint8((r * 54 + g * 183 + b * 19) shr 8)
      # Pull toward mid-grey so team tint fully washes out.
      grey = uint8((luma.int + 128) div 2)
    result[i * 4] = grey
    result[i * 4 + 1] = grey
    result[i * 4 + 2] = grey
    result[i * 4 + 3] = uint8(a.int * 140 div 255)

proc addPlayerActorSprites(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  packet: var seq[uint8],
  selected: bool
) {.measure.} =
  ## Adds pre-rotated top-down soldier sprites for every configured skin: one
  ## SoldierRotations-step set per team, plus selected outlines for the map.
  let usedSkins = sim.config.usedSkins()
  for skin in Skin:
    if skin notin usedSkins:
      continue
    for team in sim.teams():
      let color = teamText(team)
      for rot in 0 ..< SoldierRotations:
        let
          # Raster natively at the emission scale: the ~120px painted masters
          # carry real detail the 1× 34px body footprint throws away.
          pixels = soldierRotPixels(team, skin, rot, boardScale)
          side = if soldierFacingRight(rot): LabelSideRight else: LabelSideLeft
        # The HD sprite keeps its full 16-step rotation for the VISUAL; the label
        # stays the documented `player <color> <side>` (RULES.md) so exact-match
        # label readers keep working. Distinct sprite ids may share a side label
        # — the client keys sprites by id, not label, so that is harmless.
        packet.addBoardSpriteChanged(
          spriteDefs,
          soldierPlayerSpriteId(team, skin, rot),
          SoldierCanvas,
          SoldierCanvas,
          pixels,
          labelPlayer(color, side),
          native = boardScale
        )
        # Corpse and selection variants derive from the same rendered pixels.
        packet.addBoardSpriteChanged(
          spriteDefs,
          corpseSoldierSpriteId(team, skin, rot),
          SoldierCanvas,
          SoldierCanvas,
          soldierCorpse(pixels),
          labelCorpse(color, side),
          native = boardScale
        )
        if selected:
          packet.addBoardSpriteChanged(
            spriteDefs,
            selectedSoldierPlayerSpriteId(team, skin, rot),
            SoldierCanvas,
            SoldierCanvas,
            soldierOutlined(pixels, 8'u8, boardScale),
            labelSelectedPlayer(color, side),
            native = boardScale
          )

proc buildSpriteProtocolInit(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition]
): seq[uint8] {.measure.} =
  ## Builds the initial global viewer snapshot.
  result = @[]
  result.addU8(0x04)
  result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
  # The spectator board layer announces its boardScale× size; the client fits
  # whatever viewport it is told to the window, so the scaled board lands in
  # the same screen rect with boardScale× the pixels.
  result.addViewport(
    MapLayerId,
    sim.gameMap.width * boardScale,
    sim.gameMap.height * boardScale
  )
  result.addLayer(TopLeftLayerId, TopLeftLayerType, UiLayerFlag)
  result.addViewport(TopLeftLayerId, ScoreboardWidth, ScoreboardHeight)
  result.addLayer(InterstitialLayerId, InterstitialLayerType, UiLayerFlag)
  result.addViewport(InterstitialLayerId, ScreenWidth, ScreenHeight)
  result.addLayer(BottomRightLayerId, BottomRightLayerType, UiLayerFlag)
  result.addViewport(BottomRightLayerId, ScreenWidth, ScreenHeight)
  result.addLayer(TeamScoreLayerId, TeamScoreLayerType, UiLayerFlag)
  result.addViewport(TeamScoreLayerId, TeamScoreWidth, TextLineHeight + 2)
  # The map rides as horizontal bands (see addMapBands): one ~1.09 MB map
  # sprite exceeds the hosted 1 MiB WS frame cap — banding keeps every pixel
  # while making each message a fraction of the cap.
  sim.addMapBands(spriteDefs, result)
  sim.addMapMarkers(spriteDefs, result)
  sim.addFlagSprites(spriteDefs, result)
  sim.addSpriteProtocolInterstitialSprites(spriteDefs, result)
  sim.addPlayerActorSprites(spriteDefs, result, selected = true)

proc buildSpriteProtocolPlayerInit(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition]
): seq[uint8] {.measure.} =
  ## Builds the initial sprite player snapshot: the full-map view (the client
  ## scales the whole arena to the window), the fog overlay layer, and the
  ## screen-corner HUD layers.
  result = @[]
  result.addU8(0x04)
  let mapPixels = sim.buildMapSpritePixels()
  result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
  result.addViewport(MapLayerId, sim.gameMap.width, sim.gameMap.height)
  result.addLayer(FogLayerId, MapLayerType, ZoomableLayerFlag)
  result.addViewport(FogLayerId, sim.gameMap.width, sim.gameMap.height)
  result.addLayer(HudTopRightLayerId, HudTopRightLayerType, UiLayerFlag)
  result.addViewport(HudTopRightLayerId, 24, TextLineHeight + 2)
  result.addLayer(HudBottomLeftLayerId, HudBottomLeftLayerType, UiLayerFlag)
  result.addViewport(HudBottomLeftLayerId, SpriteSize + 2, SpriteSize + 2)
  result.addLayer(
    PlayerInterstitialLayerId,
    PlayerInterstitialLayerType,
    UiLayerFlag
  )
  result.addViewport(PlayerInterstitialLayerId, ScreenWidth, ScreenHeight)
  result.addLayer(TeamScoreLayerId, TeamScoreLayerType, UiLayerFlag)
  result.addViewport(TeamScoreLayerId, TeamScoreWidth, TextLineHeight + 2)
  result.addSpriteChanged(
    spriteDefs,
    MapSpriteId,
    sim.gameMap.width,
    sim.gameMap.height,
    mapPixels,
    "map"
  )
  sim.addMapMarkers(spriteDefs, result)
  result.addSpriteChanged(
    spriteDefs,
    SpritePlayerWalkabilitySpriteId,
    sim.gameMap.width,
    sim.gameMap.height,
    sim.buildWalkabilitySpritePixels(),
    LabelWalkabilityMap
  )
  sim.addFlagSprites(spriteDefs, result)
  result.addSpriteChanged(
    spriteDefs,
    SpritePlayerFireSpriteId,
    sim.flagSprite.width,
    sim.flagSprite.height,
    buildSpriteProtocolRawSprite(sim.flagSprite),
    LabelFireIcon
  )
  result.addSpriteChanged(
    spriteDefs,
    SpritePlayerFireShadowSpriteId,
    sim.flagSprite.width,
    sim.flagSprite.height,
    buildSpriteProtocolShadowSprite(sim.flagSprite),
    LabelFireIconCooldown
  )
  sim.addSpriteProtocolInterstitialSprites(spriteDefs, result)
  sim.addPlayerActorSprites(spriteDefs, result, selected = false)

proc spriteObjectId(player: Player): int =
  ## Returns the stable global protocol object id for a player.
  PlayerObjectBase + player.joinOrder

proc spritePlayerNameObjectId(player: Player): int =
  ## Returns the stable global protocol object id for a player name label.
  PlayerNameObjectBase + player.joinOrder

proc spritePlayerNameSpriteId(player: Player): int =
  ## Returns the global protocol sprite id for a player name label.
  PlayerNameSpriteBase + player.joinOrder

proc playerLabelText(player: Player): string =
  ## Returns the per-player name label text for the global viewer.
  result = player.address
  if result.len == 0:
    result = "?"
  if result.len > PlayerNameMaxChars:
    result.setLen(PlayerNameMaxChars)

proc scoreboardPipObjectId(row: int): int =
  ## Returns the stable score pip object id for one row.
  ScoreboardPipObjectBase + row

proc scoreboardTextObjectId(row: int): int =
  ## Returns the stable score text object id for one row.
  ScoreboardTextObjectBase + row

proc scoreboardTextSpriteId(row: int): int =
  ## Returns the stable score text sprite id for one row.
  ScoreboardTextSpriteBase + row

proc scoreboardPipSpriteId(colorIndex: int): int =
  ## Returns the stable score pip sprite id for one color.
  ScoreboardPipSpriteBase + colorIndex

proc scoreboardName(player: Player): string =
  ## Returns the clickable scoreboard player label. The color pip next to the
  ## row already carries the team, so no (red)/(blue) tag.
  player.playerLabelText()

proc scoreboardText(player: Player): string =
  ## Returns one compact scoreboard row.
  player.scoreboardName() & " " & $player.lives

proc scoreboardJoinOrderAt(
  sim: SimServer,
  layer,
  mouseX,
  mouseY: int
): int =
  ## Returns the join order for a clicked scoreboard name.
  if layer != TopLeftLayerId:
    return -1
  let row = (mouseY - ScoreboardY) div ScoreboardRowHeight
  if row < 0 or row >= sim.players.len:
    return -1
  let
    player = sim.players[row]
    name = player.scoreboardName()
    rowY = ScoreboardY + row * ScoreboardRowHeight
    nameWidth = sim.asciiSprites.textWidth(name)
  if mouseY < rowY or mouseY >= rowY + TextLineHeight:
    return -1
  if mouseX < ScoreboardTextX or
      mouseX >= ScoreboardTextX + nameWidth:
    return -1
  player.joinOrder

proc toggleSelectedJoinOrder(
  state: var GlobalViewerState,
  joinOrder: int
) =
  ## Selects or clears the current point-of-view join order.
  if joinOrder < 0:
    state.selectedJoinOrder = -1
  elif state.selectedJoinOrder == joinOrder:
    state.selectedJoinOrder = -1
  else:
    state.selectedJoinOrder = joinOrder

proc addScoreboard(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8],
  selectedJoinOrder: int
) {.measure.} =
  ## Adds the top-left player score picker (per-team lives).
  packet.addLayer(TopLeftLayerId, TopLeftLayerType, UiLayerFlag)
  packet.addViewport(TopLeftLayerId, ScoreboardWidth, ScoreboardHeight)
  for i in 0 ..< sim.players.len:
    let
      player = sim.players[i]
      colorIndex = playerColorIndex(player.color)
      pipSpriteId = scoreboardPipSpriteId(colorIndex)
      pipObjectId = scoreboardPipObjectId(i)
      textSpriteId = scoreboardTextSpriteId(i)
      textObjectId = scoreboardTextObjectId(i)
      rowY = ScoreboardY + i * ScoreboardRowHeight
      color =
        if player.joinOrder == selectedJoinOrder:
          ScoreboardSelectedTextColor
        else:
          ScoreboardTextColor
      text = sim.buildSpriteProtocolTextSprite(
        [player.scoreboardText()],
        color
      )
    currentIds.add(pipObjectId)
    currentIds.add(textObjectId)
    packet.addSpriteChanged(
      spriteDefs,
      pipSpriteId,
      ScoreboardPipSize,
      ScoreboardPipSize,
      buildSolidSprite(ScoreboardPipSize, ScoreboardPipSize, player.color),
      "score pip " & playerColorName(colorIndex)
    )
    packet.addBoardObject(
      pipObjectId,
      ScoreboardPipX,
      ScoreboardPipY + i * ScoreboardRowHeight,
      0,
      TopLeftLayerId,
      pipSpriteId
    )
    packet.addSpriteChanged(
      spriteDefs,
      textSpriteId,
      text.width,
      text.height,
      text.pixels,
      "score " & player.scoreboardText() & " color " & $color
    )
    packet.addBoardObject(
      textObjectId,
      ScoreboardTextX,
      rowY,
      0,
      TopLeftLayerId,
      textSpriteId
    )

proc playerLabelLines(
  sim: SimServer,
  player: Player,
  playerIndex: int
): seq[string] =
  ## Returns label lines (name plus lives) for one player.
  result = @[playerLabelText(player)]

proc carriedFlagTeam(sim: SimServer, playerIndex: int): int =
  ## Returns the ordinal of the team flag this player is carrying, or -1 if the
  ## player carries no flag. (A carrier runs the ENEMY team's flag, so the glyph
  ## is colored for the flag it holds — not the carrier's own team.)
  for team in sim.teams():
    if sim.flags[team].carrier == playerIndex:
      return ord(team)
  -1

const
  # A compact flag glyph appended beside a carrier's name so it's obvious WHO
  # holds the flag, colored for the flag's own team (see carriedFlagTeam). Sized
  # to the TextLineHeight so it sits on the name's baseline.
  NameFlagPoleX = 0
  NameFlagW = 6
  NameFlagClothRows = [1, 2, 3]   # cloth rows (rest is bare pole) within the line.

proc blitNameFlag(
  target: var seq[uint8],
  targetWidth, targetHeight, baseX, baseY: int,
  team: Team
) =
  ## Blits the compact team-colored flag marker (pole + cloth + 1px dark
  ## outline) into a name sprite at (baseX, baseY). The outline lets it read on
  ## any floor, matching the board banner.
  let
    body = teamColor(team)
    h = TextLineHeight
  var kind = newSeq[uint8](NameFlagW * h)  # 0 empty, 1 pole, 2 cloth
  proc put(x, y: int, k: uint8) =
    if x >= 0 and x < NameFlagW and y >= 0 and y < h:
      kind[y * NameFlagW + x] = k
  for y in 0 ..< h:                       # the pole, full height of the line.
    put(NameFlagPoleX, y, 1)
  for y in NameFlagClothRows:             # the cloth, attached right of the pole.
    for x in NameFlagPoleX + 1 .. NameFlagPoleX + 3:
      put(x, y, 2)
  proc solid(x, y: int): bool =
    x >= 0 and x < NameFlagW and y >= 0 and y < h and kind[y * NameFlagW + x] != 0
  for y in 0 ..< h:
    for x in 0 ..< NameFlagW:
      let px = baseX + x
      let py = baseY + y
      case kind[y * NameFlagW + x]
      of 1: target.putTextSpritePixel(targetWidth, targetHeight, px, py, 5'u8)  # wood pole
      of 2: target.putTextSpritePixel(targetWidth, targetHeight, px, py, body)  # team cloth
      else:
        if solid(x - 1, y) or solid(x + 1, y) or solid(x, y - 1) or solid(x, y + 1):
          target.putTextSpritePixel(targetWidth, targetHeight, px, py, OutlineColor)

proc buildCarrierNameSprite(
  sim: SimServer,
  player: Player,
  flagTeamOrd: int,
  smooth = false
): tuple[width, height: int, pixels: seq[uint8]] {.measure.} =
  ## Builds a carrier's overhead label: the name in the normal color, then a
  ## small flag marker in the carried flag's team color set NEXT TO the name (so
  ## it's obvious who has the flag and whose flag it is), not overlapping it.
  ## With `smooth` (supersampled board): vector name + the pixel-art flag chip
  ## integer-upscaled beside it — LOGICAL dims, native boardScale× pixels.
  let
    name = playerLabelText(player)
    gap = 2
  if smooth and boardScale > 1:
    let
      k = boardScale
      c = Palette[PlayerNameColor and 0x0f]
      nameSpr = smoothTextSprite([name], c.r, c.g, c.b, k, TextLineHeight)
    result.width = nameSpr.width + gap + NameFlagW
    result.height = nameSpr.height
    result.pixels = newSeq[uint8](result.width * k * result.height * k * 4)
    result.pixels.blitRgbaBuffer(result.width * k, result.height * k,
      nameSpr.pixels, nameSpr.width * k, nameSpr.height * k, 0, 0)
    var chip = newRgbaPixels(NameFlagW, TextLineHeight)
    chip.blitNameFlag(NameFlagW, TextLineHeight, 0, 0, Team(flagTeamOrd))
    result.pixels.blitRgbaBuffer(result.width * k, result.height * k,
      scaleSpritePixels(chip, NameFlagW, TextLineHeight, k),
      NameFlagW * k, TextLineHeight * k, (nameSpr.width + gap) * k, 0)
    return
  let nameW = sim.asciiSprites.textWidth(name)
  result.width = nameW + gap + NameFlagW
  result.height = TextLineHeight
  result.pixels = newRgbaPixels(result.width, result.height)
  sim.blitSmallText(result.pixels, result.width, result.height, name, 0, 0,
    PlayerNameColor)
  result.pixels.blitNameFlag(result.width, result.height, nameW + gap, 0,
    Team(flagTeamOrd))

proc spritePlayerX(player: Player): int =
  ## Returns the global viewer x position for a player sprite: the soldier
  ## canvas is centered on the player (canvas center = the helmet pivot).
  player.x + CollisionW div 2 - SoldierDrawOff

proc spritePlayerY(player: Player): int =
  ## Returns the global viewer y position for a player sprite.
  player.y + CollisionH div 2 - SoldierDrawOff

proc overheadAnchorX(player: Player): int =
  ## X of the soldier body's left edge — the anchor for centering overhead UI
  ## (name label, carry marker) over the body, not the wider gun-clearance canvas.
  player.x + CollisionW div 2 - SoldierBodyPx div 2

proc overheadAnchorY(player: Player): int =
  ## Y of the soldier body's top edge — the anchor for stacking overhead UI
  ## (HP bar, name, shout) just above the helmet, independent of canvas size.
  player.y + CollisionH div 2 - SoldierBodyPx div 2

proc selectSpritePlayer(
  sim: SimServer,
  mouseX,
  mouseY: int
): int {.measure.} =
  ## Returns the join order of the topmost player under the mouse.
  result = -1
  var bestY = low(int)
  for player in sim.players:
    # Hit-test the body footprint (the helmet square), not the wider transparent
    # gun-clearance canvas, so clicks near a swinging gun don't select a player.
    let
      x = player.overheadAnchorX()
      y = player.overheadAnchorY()
      w = SoldierBodyPx
      h = SoldierBodyPx
    if mouseX >= x and mouseX < x + w and
        mouseY >= y and mouseY < y + h and
        player.y >= bestY:
      bestY = player.y
      result = player.joinOrder

proc selectedPlayerIndex(
  sim: SimServer,
  joinOrder: int
): int {.measure.} =
  ## Returns the player index for a join order.
  for i in 0 ..< sim.players.len:
    if sim.players[i].joinOrder == joinOrder:
      return i
  -1

proc tracerDotSpriteId(colorIndex, stage, bucket: int): int =
  ## Returns the sprite id for one trail dot's color, age stage, and along-beam
  ## fade bucket.
  TracerDotSpriteBase + (colorIndex * TracerStages + stage) * TrailBuckets + bucket

proc tracerHeadSpriteId(colorIndex, stage: int): int =
  ## Returns the sprite id for one leading-head color and fade stage.
  TracerHeadSpriteBase + colorIndex * TracerStages + stage

proc addShotTracers(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8]
) {.measure.} =
  ## Places each shot's tracer from fixed object pools as a COMET: a small
  ## colorless muzzle flash at the origin (who fired), a thin team-color trail
  ## that fades back toward the shooter, and a bright leading paintball at the
  ## impact end (the eye-anchor pointing at the target). The along-beam fade is
  ## baked per trail dot via its bucket. A shot that HIT draws full-bright; a
  ## MISS draws pre-aged (its age stage advanced by MissStagePenalty) so the
  ## whole comet — flash, trail, and head — reads faded and the eye is drawn
  ## to the shots that connected. SPECTATOR ONLY: only the map/broadcast
  ## view draws tracers; player observations never contain them — a player
  ## learns of a shot solely through its jittered landing ring
  ## (addShotImpactRings).
  var
    nextDot = 0
    bucketDefined: array[TrailBuckets, bool]
  for shotIndex in 0 ..< min(sim.recentShots.len, TracerMaxShots):
    let shot = sim.recentShots[shotIndex]
    let
      colorIndex = playerColorIndex(shot.color)
      age = sim.tickCount - shot.firedTick
      ageStage = clamp(age * TracerStages div ShotFxTicks, 0, TracerStages - 1)
      # A miss starts life half-faded: reuse the age-fade sprites by drawing
      # the whole comet as if it were already MissStagePenalty stages old.
      stage =
        if shot.hit: ageStage
        else: clamp(ageStage + MissStagePenalty, 0, TracerStages - 1)
      dx = shot.x1 - shot.x0
      dy = shot.y1 - shot.y0
      length = max(abs(dx), abs(dy))
      steps = max(1, length div TracerDotSpacing)
    # Trail: thin paint dots from just past the muzzle up to just behind the
    # head, each in the along-beam bucket for its distance so the tail fades
    # back toward the shooter (the muzzle flash and head own the endpoints).
    for b in 0 ..< TrailBuckets:
      bucketDefined[b] = false
    for s in 1 ..< steps:
      if nextDot >= TracerMaxDots:
        break
      let
        mx = shot.x0 + dx * s div steps
        my = shot.y0 + dy * s div steps
        beamT = s / steps                 ## 0 at muzzle → 1 at impact.
        bucket = clamp(int(beamT * float(TrailBuckets)), 0, TrailBuckets - 1)
      if pow((bucket.float + 1.0) / float(TrailBuckets), TrailFalloff) < TrailMinAlpha:
        continue                          ## far-tail dot too faint to bother.
      let spriteId = tracerDotSpriteId(colorIndex, stage, bucket)
      if not bucketDefined[bucket]:
        bucketDefined[bucket] = true
        packet.addBoardSpriteChanged(
          spriteDefs,
          spriteId,
          TracerDotSize,
          TracerDotSize,
          buildTracerDotSprite(colorIndex, stage, bucket),
          "shot trail " & playerColorName(colorIndex) &
            " stage " & $stage & " bucket " & $bucket
        )
      let objectId = TracerDotObjectBase + nextDot
      inc nextDot
      currentIds.add(objectId)
      packet.addBoardObject(
        objectId,
        mx - TracerDotSize div 2,
        my - TracerDotSize div 2,
        30005,
        MapLayerId,
        spriteId
      )
    # Muzzle bloom at the origin — the colorless flash that says "fired here".
    let bloomSpriteId = MuzzleBloomSpriteBase + stage
    packet.addBoardSpriteChanged(
      spriteDefs,
      bloomSpriteId,
      MuzzleBloomSize,
      MuzzleBloomSize,
      buildMuzzleBloomSprite(stage),
      "muzzle bloom stage " & $stage
    )
    let bloomId = MuzzleBloomObjectBase + shotIndex
    currentIds.add(bloomId)
    packet.addBoardObject(
      bloomId,
      shot.x0 - MuzzleBloomSize div 2,
      shot.y0 - MuzzleBloomSize div 2,
      30006,
      MapLayerId,
      bloomSpriteId
    )
    # Leading head at the impact end — bright white-hot ball that says
    # "struck here", pointing the beam at its target.
    let headSpriteId = tracerHeadSpriteId(colorIndex, stage)
    packet.addBoardSpriteChanged(
      spriteDefs,
      headSpriteId,
      TracerHeadSize,
      TracerHeadSize,
      buildTracerHeadSprite(colorIndex, stage),
      "shot head " & playerColorName(colorIndex) & " stage " & $stage
    )
    let headId = TracerHeadObjectBase + shotIndex
    currentIds.add(headId)
    packet.addBoardObject(
      headId,
      shot.x1 - TracerHeadSize div 2,
      shot.y1 - TracerHeadSize div 2,
      30006,
      MapLayerId,
      headSpriteId
    )

proc addAimIndicators(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8],
  viewerIndex = -1
) {.measure.} =
  ## Aim direction is now shown by the soldier's held paintball gun, which
  ## sweeps with the aim angle in every view — so the old floating aim-dot line
  ## (a stand-in from before the soldier had a real gun) is retired. Kept as a
  ## no-op so the two call sites (broadcast + player POV) stay unchanged; the
  ## former AimDot object pool now falls to the per-frame delete sweep.
  discard

proc addShotImpactRings(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8],
  viewerIndex: int
) {.measure.} =
  ## Only a shot's LANDING is audible: every recent shot leaves every living
  ## viewer one brief hollow "shot impact" ring near where it landed, whether
  ## or not any part of the shot crossed their vision. The muzzle emits no
  ## signal — firing never reveals the shooter's neighborhood, only where the
  ## paint lands. This is the ONLY trace of a shot in a player observation
  ## (tracers are spectator render only). The ring is jittered per shot
  ## (shotImpactOffset) so it reveals a neighborhood, never the exact spot,
  ## and never which team.
  discard viewerIndex                     ## sound ignores walls and fov.
  for shotIndex in 0 ..< min(sim.recentShots.len, TracerMaxShots):
    let shot = sim.recentShots[shotIndex]
    packet.addBoardSpriteChanged(
      spriteDefs,
      ShotImpactSpriteId,
      SoundRingSize,
      SoundRingSize,
      buildShotImpactSprite(),
      LabelShotImpact
    )
    let
      (ix, iy) = shotImpactOffset(shot)
      impactId = ShotImpactObjectBase + shotIndex
    currentIds.add(impactId)
    packet.addBoardObject(
      impactId,
      shot.x1 + ix - SoundRingSize div 2,
      shot.y1 + iy - SoundRingSize div 2,
      30000,
      MapLayerId,
      ShotImpactSpriteId
    )

proc buildPaintedDiamondPixels(
  sim: SimServer,
  diamond, frame, size: int,
  base: seq[uint8]
): seq[uint8] {.measure.} =
  ## One spin frame of a diamond with its accumulated paint baked ON. The paint
  ## is stored in the diamond's un-rotated frame, so here it is rotated FORWARD
  ## into this frame's screen offsets — the mark turns with the stone.
  ##
  ## Compositing into the stone sprite (rather than drawing paint as separate
  ## objects over it) is what keeps the paint clipped to the silhouette while it
  ## spins: a blot near the rim is cut by the stone's own alpha, so paint never
  ## hangs off the edge of a turning diamond.
  result = base
  let
    k = max(1, boardScale)
    outSize = size * k
    center = float(size) / 2.0
    angle = float(frame) / float(DiamondSpinFrames) * PI / 2.0
    ca = cos(angle)
    sa = sin(angle)
  for stain in sim.diamondStains:
    if int(stain.diamond) != diamond:
      continue
    let
      colorIndex = playerColorIndex(stain.color)
      variant = int(stain.seed shr 7) mod StainVariants
      # Un-rotated frame -> this frame's screen offset (the inverse of the
      # transform applied when the hit was recorded).
      dx = float(stain.lx) * ca - float(stain.ly) * sa
      dy = float(stain.lx) * sa + float(stain.ly) * ca
      # Blot art, unmasked: the diamond's own alpha does the clipping below.
      blot = sim.buildPaintStainSprite(
        PaintStain(x: 0, y: 0, color: stain.color, onWall: true,
                   seed: stain.seed),
        colorIndex, variant, maskToSurface = false
      )
      blotSize = StainSize * k
      originX = int(round((center + dx) * float(k))) - blotSize div 2
      originY = int(round((center + dy) * float(k))) - blotSize div 2
    for by in 0 ..< blotSize:
      let ty = originY + by
      if ty < 0 or ty >= outSize:
        continue
      for bx in 0 ..< blotSize:
        let tx = originX + bx
        if tx < 0 or tx >= outSize:
          continue
        let
          src = (by * blotSize + bx) * 4
          srcA = blot[src + 3]
        if srcA == 0:
          continue
        let dst = (ty * outSize + tx) * 4
        if result[dst + 3] == 0:
          continue                    ## off the stone: clipped by its alpha.
        # Source-over onto opaque stone, so the carved shading still reads
        # through the translucent paint.
        let a = float(srcA) / 255.0
        for c in 0 .. 2:
          result[dst + c] = uint8(clamp(
            float(blot[src + c]) * a + float(result[dst + c]) * (1.0 - a),
            0.0, 255.0
          ))

proc addRotatingDiamonds(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8]
) {.measure.} =
  ## Draws the center diamonds as slowly spinning rooftop-material sprites over
  ## the floor the art bake left under them. Map geometry is always visible
  ## (never fog-gated), and the halves spin in mirrored directions. The spin
  ## angle derives from tickCount, so replays and every viewer agree — and
  ## since GV28 the sim stamps THIS frame's silhouette into the collision,
  ## bullet, and vision masks (applyDiamondGeometry), so the shape drawn here
  ## is the shape that blocks. Both sides call diamondSpinFrame; there is no
  ## second copy of the angle math to drift.
  for i in 0 ..< AnimatedDiamonds.len:
    let
      spot = AnimatedDiamonds[i]
      frame = diamondSpinFrame(spot.cx, sim.tickCount)
      (size, pixels) = rotatingDiamondPixels(spot.radius, frame, boardScale)
    # A diamond that has been shot carries its paint baked into the stone, so
    # the marks turn with it and stay clipped to its silhouette. Only the frame
    # on screen right now is built/emitted; the rest arrive as the spin reaches
    # them, so paint costs one sprite per step rather than all 16 at once.
    var paintCount = 0
    for stain in sim.diamondStains:
      if int(stain.diamond) == i:
        inc paintCount
    let spriteId =
      if paintCount > 0: DiamondPaintSpriteBase + i * DiamondSpinFrames + frame
      else: RotDiamondSpriteBase + frame
    if paintCount > 0:
      # The label carries the paint count, so a NEW hit on this diamond
      # invalidates the viewer's cached frame and re-ships the repainted stone.
      let label = "diamond " & $i & " paint " & $paintCount
      let defIndex = spriteDefs.spriteDefinitionIndex(spriteId)
      if defIndex < 0 or spriteDefs[defIndex].label != label:
        packet.addBoardSpriteChanged(
          spriteDefs, spriteId, size, size,
          sim.buildPaintedDiamondPixels(i, frame, size, pixels), label,
          native = boardScale
        )
    elif spriteDefs.spriteDefinitionIndex(spriteId) < 0:
      packet.addBoardSpriteChanged(
        spriteDefs, spriteId, size, size, pixels, "diamond",
        native = boardScale
      )
    let objectId = RotDiamondObjectBase + i
    currentIds.add(objectId)
    packet.addBoardObject(
      objectId,
      spot.cx - size div 2,
      spot.cy - size div 2,
      spot.cy, MapLayerId, spriteId
    )

proc addPlasmaArcs(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8],
  viewerIndex = -1
) {.measure.} =
  ## Places side-center spray can pickups and carried markers.
  for i in 0 ..< sim.plasmaArcSpawns.len:
    let spawn = sim.plasmaArcSpawns[i]
    if not spawn.present:
      continue
    if viewerIndex >= 0 and not sim.fovVisibleAt(viewerIndex, spawn.x, spawn.y):
      continue
    if spriteDefs.spriteDefinitionIndex(PlasmaArcPickupSpriteId) < 0:
      packet.addBoardSpriteChanged(
        spriteDefs,
        PlasmaArcPickupSpriteId,
        PlasmaArcPickupSize,
        PlasmaArcPickupSize,
        loadSprayCanSprite(PlasmaArcPickupSize * boardScale),
        LabelSprayCan,
        native = boardScale
      )
    let objectId = PlasmaArcPickupObjectBase + i
    currentIds.add(objectId)
    packet.addBoardObject(
      objectId,
      spawn.x - PlasmaArcPickupSize div 2,
      spawn.y - PlasmaArcPickupSize div 2,
      spawn.y,
      MapLayerId,
      PlasmaArcPickupSpriteId
    )

  for i in 0 ..< sim.players.len:
    let player = sim.players[i]
    if not player.alive or not player.hasPlasmaArc:
      continue
    if viewerIndex >= 0 and i != viewerIndex and
        not sim.playerVisibleTo(viewerIndex, i):
      continue
    if spriteDefs.spriteDefinitionIndex(PlasmaArcCarrySpriteId) < 0:
      packet.addBoardSpriteChanged(
        spriteDefs,
        PlasmaArcCarrySpriteId,
        PlasmaArcCarrySize,
        PlasmaArcCarrySize,
        loadSprayCanSprite(PlasmaArcCarrySize * boardScale),
        LabelSprayCanCarried,
        native = boardScale
      )
    let objectId = PlasmaArcCarryObjectBase + i
    currentIds.add(objectId)
    packet.addBoardObject(
      objectId,
      player.x + CollisionW div 2 + HpBarWidth div 2 -
        PlasmaArcCarrySize div 2,
      player.overheadAnchorY() - OverheadYOffset - PlasmaArcCarrySize,
      30006,
      MapLayerId,
      PlasmaArcCarrySpriteId
    )

proc addPlasmaArcFlashes(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8],
  viewerIndex = -1
) {.measure.} =
  ## Places each recent spray burst's fading cone: a run of paint-mist puffs
  ## along the attacker's aim, each sized to the local cone width.
  for i in 0 ..< min(sim.plasmaArcFlashes.len, PlasmaArcMaxFlashes):
    let flash = sim.plasmaArcFlashes[i]
    if viewerIndex >= 0 and
        not sim.fovVisibleAt(viewerIndex, flash.x, flash.y):
      continue
    let
      age = max(0, sim.tickCount - flash.tick)
      stage = clamp(age * PlasmaArcFxStages div PlasmaArcFxTicks,
        0, PlasmaArcFxStages - 1)
      colorIndex = playerColorIndex(flash.color)
      (ux, uy) = aimVector(flash.aimBrads)
      # The cog's RIGHT, perpendicular to the aim: for east aim (1, 0) this is
      # (0, 1) — screen-down — matching the held weapon's GunRightPx convention.
      (rx, ry) = (-uy, ux)
    for pulse in 0 ..< PlasmaArcFxPulses:
      let
        spriteId = PlasmaArcFxSpriteBase +
          colorIndex * PlasmaArcFxStages * PlasmaArcFxPulses +
          stage * PlasmaArcFxPulses + pulse
        # Both the distance and the width move with `stage`: the fan jets out
        # from the nozzle as the burst ages instead of appearing fully formed.
        forward = float(plasmaPulseForward(pulse, stage))
        # ...and each puff is nudged toward the cog's right, so the plume leaves
        # the NOZZLE (which is held off-axis) and eases onto the cone's axis.
        right = float(plasmaPulseRight(pulse, stage))
        diameter = plasmaPulseDiameter(pulse, stage)
        px = flash.x + int(round(ux * forward + rx * right))
        py = flash.y + int(round(uy * forward + ry * right))
      # The damage cone is blocked by walls (selectArcVictims runs a
      # line-of-sight test per victim), so the animation must not sail
      # through them either: stop placing mist puffs at the first wall
      # along the aim ray.
      if not sim.lineOfSightClear(flash.x, flash.y, px, py):
        break
      if spriteDefs.spriteDefinitionIndex(spriteId) < 0:
        packet.addBoardSpriteChanged(
          spriteDefs,
          spriteId,
          diameter,
          diameter,
          buildPlasmaPulseSprite(colorIndex, stage, pulse),
          LabelSprayPaintPuff
        )
      let objectId = PlasmaArcFxObjectBase + i * PlasmaArcFxPulses + pulse
      currentIds.add(objectId)
      packet.addBoardObject(
        objectId,
        px - diameter div 2,
        py - diameter div 2,
        30006,
        MapLayerId,
        spriteId
      )

proc addMedKits(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8],
  viewerIndex = -1
) {.measure.} =
  ## Places the two center-field med kit pickups, fog-gated by map position
  ## like the grenade pickups. The map/replay view passes no viewer and shows
  ## both. The sprite is defined lazily on first need per connection.
  for i in 0 ..< sim.medKitSpawns.len:
    let spawn = sim.medKitSpawns[i]
    if not spawn.present:
      continue
    if viewerIndex >= 0 and not sim.fovVisibleAt(viewerIndex, spawn.x, spawn.y):
      continue
    if spriteDefs.spriteDefinitionIndex(MedKitSpriteId) < 0:
      packet.addBoardSpriteChanged(
        spriteDefs, MedKitSpriteId,
        MedKitSize, MedKitSize,
        loadMedKitSprite(MedKitSize * boardScale), LabelMedKit,
        native = boardScale
      )
    let objectId = MedKitObjectBase + i
    currentIds.add(objectId)
    packet.addBoardObject(
      objectId,
      spawn.x - MedKitSize div 2,
      spawn.y - MedKitSize div 2,
      spawn.y, MapLayerId, MedKitSpriteId
    )

proc addShields(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8],
  viewerIndex = -1
) {.measure.} =
  ## Places the two endzone shield pickups (fog-gated by map position like the
  ## med kits) plus a small "shield carried" marker over anyone holding one
  ## (gated on seeing that player), plus a protective bubble drawn around a
  ## carrier while the shield layer holds (it pops when shieldHp hits 0).
  ## The map/replay view passes no viewer and shows all. Sprites are defined
  ## lazily on first need per connection.
  for i in 0 ..< sim.shieldSpawns.len:
    let spawn = sim.shieldSpawns[i]
    if not spawn.present:
      continue
    if viewerIndex >= 0 and not sim.fovVisibleAt(viewerIndex, spawn.x, spawn.y):
      continue
    if spriteDefs.spriteDefinitionIndex(ShieldSpriteId) < 0:
      packet.addBoardSpriteChanged(
        spriteDefs, ShieldSpriteId,
        ShieldSize, ShieldSize,
        loadShieldSprite(ShieldSize * boardScale), LabelShield,
        native = boardScale
      )
    let objectId = ShieldObjectBase + i
    currentIds.add(objectId)
    packet.addBoardObject(
      objectId,
      spawn.x - ShieldSize div 2,
      spawn.y - ShieldSize div 2,
      spawn.y, MapLayerId, ShieldSpriteId
    )

  for i in 0 ..< sim.players.len:
    let player = sim.players[i]
    if not player.alive or not player.hasShield:
      continue
    let seeMe = viewerIndex < 0 or i == viewerIndex or
      sim.playerVisibleTo(viewerIndex, i)
    if not seeMe:
      continue
    # Never both: the forcefield bubble and the little overhead marker report the
    # SAME state, so showing them together double-reports it and the marker just
    # adds clutter over an already-unmissable bubble. While the layer holds
    # (shieldHp > 0) the bubble speaks for itself; once it is spent the bubble
    # pops and the marker takes over, because the shield's fire slowdown is still
    # in effect and the state has to stay readable.
    if player.shieldHp <= 0:
      if spriteDefs.spriteDefinitionIndex(ShieldCarrySpriteId) < 0:
        packet.addBoardSpriteChanged(
          spriteDefs, ShieldCarrySpriteId,
          ShieldCarrySize, ShieldCarrySize,
          loadShieldSprite(ShieldCarrySize * boardScale), LabelShieldCarried,
          native = boardScale
        )
      let objectId = ShieldCarryObjectBase + i
      currentIds.add(objectId)
      packet.addBoardObject(
        objectId,
        player.x + CollisionW div 2 - HpBarWidth div 2 - ShieldCarrySize div 2,
        player.overheadAnchorY() - OverheadYOffset - ShieldCarrySize,
        30006, MapLayerId, ShieldCarrySpriteId
      )
    else:
      # A fresh impact swaps the idle bubble for a blink/dent variant keyed by
      # the impact direction and age — the newest impact wins if several
      # shooters connected within the FX window.
      var
        bubbleSpriteId = ShieldBubbleSpriteId
        newestAge = BubbleImpactTicks
        impactBrads = 0
      for impact in sim.bubbleImpacts:
        if impact.playerIndex != i:
          continue
        let age = sim.tickCount - impact.tick
        if age >= 0 and age < newestAge:
          newestAge = age
          impactBrads = impact.angleBrads
      if newestAge < BubbleImpactTicks:
        let
          bucket = (impactBrads * ShieldBubbleDeformBuckets div
            AimBradsTurn + ShieldBubbleDeformBuckets) mod
            ShieldBubbleDeformBuckets
          stage = clamp(
            newestAge * ShieldBubbleDeformStages div BubbleImpactTicks,
            0, ShieldBubbleDeformStages - 1
          )
        bubbleSpriteId = ShieldBubbleDeformBase +
          bucket * ShieldBubbleDeformStages + stage
        if spriteDefs.spriteDefinitionIndex(bubbleSpriteId) < 0:
          packet.addBoardSpriteChanged(
            spriteDefs, bubbleSpriteId,
            ShieldBubbleSize, ShieldBubbleSize,
            buildShieldBubblePixels(bucket, stage),
            "shield bubble hit"
          )
      elif spriteDefs.spriteDefinitionIndex(ShieldBubbleSpriteId) < 0:
        packet.addBoardSpriteChanged(
          spriteDefs, ShieldBubbleSpriteId,
          ShieldBubbleSize, ShieldBubbleSize,
          buildShieldBubbleSprite(), "shield bubble"
        )
      let
        bubbleId = ShieldBubbleObjectBase + i
        aim = aimVector(player.aimBrads)
      currentIds.add(bubbleId)
      packet.addBoardObject(
        bubbleId,
        player.x + CollisionW div 2 -
          int(round(aim.x * ShieldBubbleLagPx)) - ShieldBubbleSize div 2,
        player.y + CollisionH div 2 -
          int(round(aim.y * ShieldBubbleLagPx)) - ShieldBubbleSize div 2,
        30000, MapLayerId, bubbleSpriteId
      )

proc addGrenades(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8],
  viewerIndex = -1
) {.measure.} =
  ## Places every grenade visual for one view (0.7.0 paint-bombs). Corner
  ## pickups, in-flight orbs, and landing blasts are fog-gated by map position;
  ## a carrier's "grenade carried" marker and a charging player's throw-target
  ## ring are gated by whether the viewer can see that player (readable intel,
  ## like the aim line). The map/replay view passes no viewer and shows all.
  ## Sprites are defined lazily so an all-quiet frame registers nothing. A
  ## landing the viewer could NOT see still leaves a "grenade sound" ring.
  let viewer = viewerIndex
  template mapVisible(mx, my: int): bool =
    viewer < 0 or sim.fovVisibleAt(viewer, mx, my)

  # Corner pickups: the paint-bomb orb sitting on its spawn, sorted into the
  # world by row so players in front occlude it. Decoding the PNG is the
  # expensive part, so — like the fog runs — only build the pixel buffer the
  # first time the sprite is needed on this connection, never per frame.
  for i in 0 ..< sim.grenadeSpawns.len:
    let spawn = sim.grenadeSpawns[i]
    if not spawn.present or not mapVisible(spawn.x, spawn.y):
      continue
    if spriteDefs.spriteDefinitionIndex(PaintBombPickupSpriteId) < 0:
      packet.addBoardSpriteChanged(
        spriteDefs, PaintBombPickupSpriteId,
        PaintBombPickupSize, PaintBombPickupSize,
        loadPaintBombSprite(PaintBombPickupSize * boardScale), LabelGrenade,
        native = boardScale
      )
    let objectId = PaintBombPickupObjectBase + i
    currentIds.add(objectId)
    packet.addBoardObject(
      objectId,
      spawn.x - PaintBombPickupSize div 2,
      spawn.y - PaintBombPickupSize div 2,
      spawn.y, MapLayerId, PaintBombPickupSpriteId
    )

  # In-flight orbs: they fly OVER walls and players, so they draw on top.
  for i in 0 ..< min(sim.airborneGrenades.len, GrenadeMaxAirborne):
    let (gx, gy) = grenadePosition(sim.airborneGrenades[i], sim.tickCount)
    if not mapVisible(gx, gy):
      continue
    if spriteDefs.spriteDefinitionIndex(PaintBombAirSpriteId) < 0:
      packet.addBoardSpriteChanged(
        spriteDefs, PaintBombAirSpriteId,
        PaintBombAirSize, PaintBombAirSize,
        loadPaintBombSprite(PaintBombAirSize * boardScale), LabelGrenadeAir,
        native = boardScale
      )
    let objectId = PaintBombAirObjectBase + i
    currentIds.add(objectId)
    packet.addBoardObject(
      objectId,
      gx - PaintBombAirSize div 2,
      gy - PaintBombAirSize div 2,
      30006, MapLayerId, PaintBombAirSpriteId
    )

  # Per-player markers: a small carried orb over the head of anyone holding a
  # grenade, and a landing ring for anyone mid-charge — both gated on seeing
  # that player (a ghost/map view sees all).
  for i in 0 ..< sim.players.len:
    let player = sim.players[i]
    if not player.alive:
      continue
    let seeMe = viewer < 0 or i == viewer or sim.playerVisibleTo(viewer, i)
    if not seeMe:
      continue
    if player.hasGrenade:
      if spriteDefs.spriteDefinitionIndex(PaintBombCarrySpriteId) < 0:
        packet.addBoardSpriteChanged(
          spriteDefs, PaintBombCarrySpriteId,
          PaintBombCarrySize, PaintBombCarrySize,
          loadPaintBombSprite(PaintBombCarrySize * boardScale), LabelGrenadeCarried,
          native = boardScale
        )
      let objectId = PaintBombCarryObjectBase + i
      currentIds.add(objectId)
      packet.addBoardObject(
        objectId,
        player.x + CollisionW div 2 + HpBarWidth div 2 - PaintBombCarrySize div 2,
        player.overheadAnchorY() - OverheadYOffset - PaintBombCarrySize,
        30006, MapLayerId, PaintBombCarrySpriteId
      )
    # Throw-target ring: the projected landing point of a charging lob. This is
    # PLAYER-OBSERVATION intel only (a bot reads the "throw target" label to flee
    # the marked spot) — but in the BROADCAST/map view it swept a big circle
    # around the charging player as the aim rotated, reading as "swinging the
    # grenade around." So it is drawn ONLY in a player view (viewer >= 0); the
    # broadcast keeps the grenade in-hand (the carried marker) and shows the lob
    # by the airborne orb + the landing splat, never the aim-preview ring.
    if player.throwCharge > 0 and viewer >= 0:
      let (tx, ty) = throwTarget(player)
      if spriteDefs.spriteDefinitionIndex(ThrowTargetSpriteId) < 0:
        packet.addBoardSpriteChanged(
          spriteDefs, ThrowTargetSpriteId,
          ThrowTargetSize, ThrowTargetSize,
          buildThrowTargetSprite(), LabelThrowTarget
        )
      let objectId = ThrowTargetObjectBase + i
      currentIds.add(objectId)
      packet.addBoardObject(
        objectId,
        tx - ThrowTargetSize div 2,
        ty - ThrowTargetSize div 2,
        ty, MapLayerId, ThrowTargetSpriteId
      )

  # Landing splats: a big paint splat in the THROWER's team color bursts on the
  # floor (drawn low, so players run across it), and — for a landing the viewer
  # could not see — a jittered "grenade sound" ring instead (audible).
  for i in 0 ..< min(sim.recentBlasts.len, GrenadeMaxBlasts):
    let blast = sim.recentBlasts[i]
    let age = sim.tickCount - blast.tick
    if mapVisible(blast.x, blast.y):
      let
        stage = clamp(age * BlastStages div BlastFxTicks, 0, BlastStages - 1)
        colorIndex = playerColorIndex(blast.color)
        size = if blast.trenchLanding: TrenchBlastSize else: BlastSize
        spriteBase =
          if blast.trenchLanding: TrenchBlastSpriteBase else: BlastSpriteBase
        spriteId = spriteBase + colorIndex * BlastStages + stage
      if spriteDefs.spriteDefinitionIndex(spriteId) < 0:
        packet.addBoardSpriteChanged(
          spriteDefs, spriteId, size, size,
          buildBlastSprite(colorIndex, stage, size),
          LabelBlastStagePrefix & $stage
        )
      let objectId = BlastObjectBase + i
      currentIds.add(objectId)
      packet.addBoardObject(
        objectId,
        blast.x - size div 2,
        blast.y - size div 2,
        blast.y - 2, MapLayerId, spriteId
      )
    elif viewer >= 0:
      if spriteDefs.spriteDefinitionIndex(SoundRingSpriteId) < 0:
        packet.addBoardSpriteChanged(
          spriteDefs, SoundRingSpriteId, SoundRingSize, SoundRingSize,
          buildSoundRingSprite(), LabelGrenadeSound
        )
      var h = 0x9E3779B9'u32
      h = (h xor uint32(blast.tick)) * 0x85EBCA6B'u32
      h = (h xor uint32(blast.x)) * 0xC2B2AE35'u32
      h = (h xor uint32(blast.y)) * 0x27D4EB2F'u32
      h = h xor (h shr 15)
      let
        span = uint32(2 * SoundRingJitter + 1)
        dx = int(h mod span) - SoundRingJitter
        dy = int((h shr 16) mod span) - SoundRingJitter
        objectId = BlastObjectBase + i
      currentIds.add(objectId)
      packet.addBoardObject(
        objectId,
        blast.x + dx - SoundRingSize div 2,
        blast.y + dy - SoundRingSize div 2,
        30000, MapLayerId, SoundRingSpriteId
      )

proc shoutOffset(shout: Shout): (int, int) =
  ## The deterministic jitter for one shout's heard position, salted apart
  ## from the shot rings: nearby players learn the neighborhood the shout
  ## came from, never the exact spot.
  var h = 0x2545F491'u32
  h = (h xor uint32(shout.tick)) * 0x85EBCA6B'u32
  h = (h xor uint32(shout.x)) * 0xC2B2AE35'u32
  h = (h xor uint32(shout.y)) * 0x27D4EB2F'u32
  h = h xor (h shr 15)
  let span = uint32(2 * SoundRingJitter + 1)
  (int(h mod span) - SoundRingJitter,
    int((h shr 16) mod span) - SoundRingJitter)

proc addShouts(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8],
  shoutSlots: var array[ShoutMaxCount, string],
  viewerIndex: int
) {.measure.} =
  ## Places live shout speech bubbles for one PLAYER view: the viewer hears
  ## only shouts within ShoutRange and the bubble pins at deterministically
  ## jittered coordinates, like the shot sound rings — so a bot learns the
  ## neighborhood a shout came from, never the exact spot. This stream is a
  ## bot OBSERVATION: bubbles appear and expire on exact sim timing (no
  ## wall-clock dwell — that is a spectator affordance; see addBoardShouts).
  ##
  ## The bubble is labeled with the shouter's anonymous slot letter, never its
  ## address: listeners read these labels, and the address is the connecting
  ## policy's name. See `shoutIdentityName`.
  ##
  ## Sprite and object ids come from `shoutSlots`, the viewer's persistent
  ## address→slot table, NOT from the shout's position in `recentShouts`. That
  ## array reshuffles almost every tick in a busy match — a re-shout removes
  ## its old bubble mid-array and appends the new one, an expiry compacts the
  ## front — and ids keyed on the array index handed every bubble behind the
  ## churn point a different wire identity each frame, which the client
  ## rendered as bubbles teleporting and flashing each other's text. A slot is
  ## claimed when an address's bubble is first drawn and freed only when that
  ## address no longer has a live shout ANYWHERE in the sim — not merely out
  ## of this viewer's earshot — so a bubble heard again keeps its ids, and a
  ## re-shout replaces its own bubble in place: same slot, new label.
  for slot in 0 ..< ShoutMaxCount:
    if shoutSlots[slot].len == 0:
      continue
    var live = false
    for shout in sim.recentShouts:
      if shout.address == shoutSlots[slot]:
        live = true
        break
    if not live:
      shoutSlots[slot] = ""

  for shout in sim.recentShouts:
    if not sim.shoutAudibleTo(viewerIndex, shout):
      continue
    let
      (dx, dy) = shoutOffset(shout)
      anchorX = shout.x + dx
      tailTipY = shout.y + dy - ShoutFloat
    var slot = -1
    for s in 0 ..< ShoutMaxCount:
      if shoutSlots[s] == shout.address:
        slot = s
        break
    if slot < 0:
      for s in 0 ..< ShoutMaxCount:
        if shoutSlots[s].len == 0:
          shoutSlots[s] = shout.address
          slot = s
          break
    if slot < 0:
      # Every slot is owned by another live bubble — only possible when churn
      # pushes distinct shouting addresses past ShoutMaxCount. Drop the
      # overflow shout, like the old first-ShoutMaxCount cap did.
      continue
    let
      bubble = sim.buildShoutBubble(shout.team, shout.text)
      spriteId = ShoutSpriteBase + slot
      objectId = ShoutObjectBase + slot
    packet.addBoardSpriteChanged(
      spriteDefs,
      spriteId,
      bubble.width,
      bubble.height,
      bubble.pixels,
      labelShout(
        teamText(shout.team), sim.shoutIdentityName(shout), shout.text),
      native = boardScale
    )
    currentIds.add(objectId)
    packet.addBoardObject(
      objectId,
      anchorX - bubble.width div 2,
      tailTipY - bubble.height,
      ShoutBubbleZ,
      MapLayerId,
      spriteId
    )

proc addBoardShouts(
  sim: SimServer,
  state: var GlobalViewerState,
  currentIds: var seq[int],
  packet: var seq[uint8]
) {.measure.} =
  ## Places shout speech bubbles on the BOARD/broadcast view, floating over
  ## the shouter (following them while they move and live), with the same
  ## anonymous slot-letter label and slot-keyed wire ids as the player path
  ## (see addShouts for both rationales).
  ##
  ## Unlike the player path, what a bubble SHOWS is floored in wall-clock
  ## time — where "wall-clock" is counted in ADVANCING rendered frames, never
  ## read from the system clock, so this stays deterministic and replay-exact.
  ## A shout lives ShoutTicks of SIM time, but replay playback
  ## compresses sim time per rendered frame (speed × the skip-lulls boost, up
  ## to MaxLullTicksPerFrame ticks a frame) — enough to squeeze a bubble's
  ## whole life into one or two frames, which a viewer reads as random text
  ## flashing near the bots; a policy re-shouting comms every cooldown turned
  ## its bubble into a one-frame-per-payload strobe. So each slot keeps
  ## ShoutLinger render state: a text stays up for at least ShoutDwellFrames
  ## ADVANCING rendered frames (paused playback does not age it), an expired
  ## bubble lingers until its text met that dwell, and a fresher payload
  ## replaces the shown one only once the dwell is met — jumping straight to
  ## the newest payload, not through the queue. At live 1x this floor is
  ## invisible: applyShout's cooldown already spaces one shouter's texts at
  ## least ShoutDwellFrames ticks apart, and an unrefreshed bubble's
  ## ShoutTicks lifetime more than covers its dwell.
  ##
  ## A backward tick jump is a scrub restore: the restored sim is
  ## authoritative, so linger state snaps clean instead of ghosting bubbles
  ## from the abandoned timeline (the cogDrive scrub rule).
  let advanced = state.shoutLingerTick == low(int) or
    sim.tickCount > state.shoutLingerTick
  if state.shoutLingerTick != low(int) and
      sim.tickCount < state.shoutLingerTick:
    for slot in 0 ..< ShoutMaxCount:
      state.shoutLinger[slot] = ShoutLinger()
  state.shoutLingerTick = sim.tickCount

  # Free a slot only when its address has no live shout anywhere AND its
  # shown text has met the wall-clock dwell.
  for slot in 0 ..< ShoutMaxCount:
    if state.shoutSlots[slot].len == 0:
      continue
    var live = false
    for shout in sim.recentShouts:
      if shout.address == state.shoutSlots[slot]:
        live = true
        break
    if not live and (not state.shoutLinger[slot].active or
        state.shoutLinger[slot].frames >= ShoutDwellFrames):
      state.shoutSlots[slot] = ""
      state.shoutLinger[slot] = ShoutLinger()

  for shout in sim.recentShouts:
    var slot = -1
    for s in 0 ..< ShoutMaxCount:
      if state.shoutSlots[s] == shout.address:
        slot = s
        break
    if slot < 0:
      for s in 0 ..< ShoutMaxCount:
        if state.shoutSlots[s].len == 0:
          state.shoutSlots[s] = shout.address
          slot = s
          break
    if slot < 0:
      # Every slot is owned by another live bubble — only possible when churn
      # pushes distinct shouting addresses past ShoutMaxCount. Drop the
      # overflow shout, like the old first-ShoutMaxCount cap did.
      continue
    if not state.shoutLinger[slot].active:
      state.shoutLinger[slot] = ShoutLinger(
        active: true,
        team: shout.team,
        name: sim.shoutIdentityName(shout),
        text: shout.text,
        frames: 0,
        # Where the shout was made; the draw pass below follows the shouter
        # while they live, and this holds the spot when they do not.
        anchorX: shout.x,
        tailTipY: shout.y - ShoutFloat
      )
    elif state.shoutLinger[slot].text != shout.text and
        state.shoutLinger[slot].frames >= ShoutDwellFrames:
      state.shoutLinger[slot].team = shout.team
      state.shoutLinger[slot].name = sim.shoutIdentityName(shout)
      state.shoutLinger[slot].text = shout.text
      state.shoutLinger[slot].frames = 0

  for slot in 0 ..< ShoutMaxCount:
    if not state.shoutLinger[slot].active:
      continue
    # The broadcast pins the bubble over the shouter while they live, above
    # the name label; a dead or departed shouter leaves it where it last was.
    for player in sim.players:
      if player.address == state.shoutSlots[slot]:
        if player.alive:
          state.shoutLinger[slot].anchorX = player.x + CollisionW div 2
          state.shoutLinger[slot].tailTipY =
            player.overheadAnchorY() - OverheadYOffset -
            HpBarH - TextLineHeight - 2
        break
    let
      linger = state.shoutLinger[slot]
      bubble = sim.buildShoutBubble(linger.team, linger.text)
      spriteId = ShoutSpriteBase + slot
      objectId = ShoutObjectBase + slot
    packet.addBoardSpriteChanged(
      state.spriteDefs,
      spriteId,
      bubble.width,
      bubble.height,
      bubble.pixels,
      labelShout(teamText(linger.team), linger.name, linger.text),
      native = boardScale
    )
    currentIds.add(objectId)
    packet.addBoardObject(
      objectId,
      linger.anchorX - bubble.width div 2,
      linger.tailTipY - bubble.height,
      ShoutBubbleZ,
      MapLayerId,
      spriteId
    )
    if advanced:
      state.shoutLinger[slot].frames += 1

proc addHpPips(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8],
  viewerIndex = -1
) {.measure.} =
  ## Places a fixed 3-segment health bar above each living player's head. The
  ## map view passes no viewer and shows every bar; a player view passes its
  ## viewer index and only receives the bars of players it can see (a wounded
  ## enemy's hp is readable intel). Object ids are a fixed pool keyed by player
  ## index; stale bars fall to the delete sweep.
  let maxHp = max(1, sim.config.hitPoints)
  for i in 0 ..< sim.players.len:
    let player = sim.players[i]
    if not player.alive:
      continue
    if viewerIndex >= 0 and i != viewerIndex and
        not sim.playerVisibleTo(viewerIndex, i):
      continue
    # Map remaining hit points onto 3 thirds (ceil, so any living player keeps
    # at least one lit segment). The bar's pixel size is constant regardless of
    # the hit-point config, so a 99-hp game reads the same 14px 3-chunk bar.
    let effectiveHp = player.hp + player.shieldHp
    let litSegments = min(HpBarSegments,
      max(1, (effectiveHp * HpBarSegments + maxHp - 1) div maxHp))
    let spriteId = HpPipSpriteBase + litSegments
    packet.addBoardSpriteChanged(
      spriteDefs,
      spriteId,
      HpBarWidth,
      HpBarH,
      buildHpBarSprite(litSegments),
      labelHp(litSegments)
    )
    let objectId = HpPipObjectBase + i
    currentIds.add(objectId)
    packet.addBoardObject(
      objectId,
      player.x + CollisionW div 2 - HpBarWidth div 2,
      player.overheadAnchorY() - OverheadYOffset - HpBarH,
      30001,
      MapLayerId,
      spriteId
    )

proc addIdentityBadges(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8],
  viewerIndex = -1
) {.measure.} =
  ## Places each living player's identity badge (a Greek letter, alpha..theta
  ## by slot order within the team) centered on the soldier body. The body
  ## rotates with the aim, so the center — its rotation pivot — is the only
  ## spot that stays on the cog at every heading.
  ## The label is `identity <color> <name>[ shield][ nade][ arc]` — the
  ## suffixes carry the wearer's current loadout so an observing agent can
  ## read weapon state at a glance (the surviving half of the reverted #77
  ## unit tags). Scan identity labels by PREFIX (`identity <color> <name>`),
  ## never exact match: the tail changes with pickups. The map view passes no
  ## viewer and shows every badge; a player view passes its viewer index and
  ## only receives the badges of players it can see (identity is intel, like
  ## the hp bar). Object ids are a fixed pool keyed by player index; stale
  ## badges fall to the delete sweep.
  for i in 0 ..< sim.players.len:
    let player = sim.players[i]
    if not player.alive:
      continue
    if viewerIndex >= 0 and i != viewerIndex and
        not sim.playerVisibleTo(viewerIndex, i):
      continue
    let
      identityIndex = sim.slotIdentityIndex(player.joinOrder)
      spriteId = IdentityBadgeSpriteBase +
        ord(player.team) * IdentityNames.len + identityIndex
    # labelIdentity owns the ordering invariant (flags in fixed order, weapon
    # token always LAST and always present, so observers never infer a weapon
    # from absence).
    let label = labelIdentity(
      teamText(player.team),
      IdentityNames[identityIndex],
      shield = player.hasShield,
      nade = player.hasGrenade,
      weapon = (if player.hasPlasmaArc: LabelWeaponSpray else: LabelWeaponGun)
    )
    packet.addBoardSpriteChanged(
      spriteDefs,
      spriteId,
      IdentityBadgeSize,
      IdentityBadgeSize,
      buildIdentityBadgeSprite(player.team, identityIndex),
      label
    )
    let objectId = IdentityBadgeObjectBase + i
    currentIds.add(objectId)
    packet.addBoardObject(
      objectId,
      player.overheadAnchorX() + (SoldierBodyPx - IdentityBadgeSize) div 2,
      player.overheadAnchorY() + (SoldierBodyPx - IdentityBadgeSize) div 2,
      player.y + 1,
      MapLayerId,
      spriteId
    )

proc splatterSpriteId(colorIndex, stage: int, hit: bool): int =
  ## Returns the sprite id for one splatter/hit-spark color and fade stage.
  ## Hit sparks live in a separate pool so a small tag never reuses a death
  ## splatter's sprite definition for the same color and stage.
  (if hit: HitSpriteBase else: SplatterSpriteBase) +
    colorIndex * SplatterStages + stage

proc addSplatters(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8],
  viewerIndex = -1
) {.measure.} =
  ## Places fading death splatters from a fixed object pool. The fade stage
  ## comes from the splatter age quartile; splatters draw under the players.
  ## The map view passes no viewer and shows every splatter; a player view
  ## passes its viewer index and only receives the ones inside its vision.
  var nextSplatter = 0
  for splatter in sim.splatters:
    if nextSplatter >= SplatterMaxCount:
      break
    if viewerIndex >= 0 and
        not sim.fovVisibleAt(viewerIndex, splatter.x, splatter.y):
      continue
    let
      age = sim.tickCount - splatter.tick
      life = if splatter.hit: HitFxTicks else: SplatterFxTicks
      stage = clamp(
        age * SplatterStages div life,
        0,
        SplatterStages - 1
      )
      colorIndex = playerColorIndex(splatter.color)
      spriteSize = if splatter.hit: HitSplatSize else: SplatterSize
      px = splatter.x - spriteSize div 2
      py = splatter.y - spriteSize div 2
    let spriteId = splatterSpriteId(colorIndex, stage, splatter.hit)
    packet.addBoardSpriteChanged(
      spriteDefs,
      spriteId,
      spriteSize,
      spriteSize,
      (if splatter.hit: buildHitSparkSprite(colorIndex, stage)
       else: buildSplatterSprite(colorIndex, stage)),
      (if splatter.hit: "hit splat " else: "splatter ") &
        playerColorName(colorIndex) & " stage " & $stage
    )
    let objectId = SplatterObjectBase + nextSplatter
    inc nextSplatter
    currentIds.add(objectId)
    packet.addBoardObject(
      objectId,
      px,
      py,
      splatter.y - 100,
      MapLayerId,
      spriteId
    )

proc addPaintStains(
  sim: SimServer,
  state: var GlobalViewerState,
  packet: var seq[uint8]
) {.measure.} =
  ## Emits the PERMANENT dried paint on the terrain — the marks left where shots,
  ## sprays and grenades hit the map, which never expire, so the lanes players
  ## keep running end the match visibly coated in their colors.
  ##
  ## INCREMENTAL BY DESIGN. `sim.paintStains` is append-only within a match, so
  ## this ships only the stains a viewer hasn't seen yet and never re-sends or
  ## re-places an old one. Like the map bands, stain objects are deliberately
  ## NOT added to `currentIds`: the per-frame delete diff only reaps ids it has
  ## seen in a previous frame's list, so leaving them out is what makes them
  ## stick forever at zero per-frame cost. A thousand decals therefore cost one
  ## object message each, once — not a thousand messages per frame.
  ##
  ## Spectator/board only: the POV/RL observation stream never receives these
  ## (a policy must not start reading floor art as terrain), and `mapRgba` — the
  ## surface the RL view shares — is never touched.
  if state.stainsSent > sim.paintStains.len:
    # The match restarted (startGame cleared the list) while this viewer held
    # the previous match's paint: drop the stale marks and re-arm from empty.
    for i in 0 ..< min(state.stainsSent, StainMaxCount):
      packet.addDeleteObject(StainObjectBase + i)
    state.stainsSent = 0
  while state.stainsSent < min(sim.paintStains.len, StainMaxCount):
    let
      index = state.stainsSent
      stain = sim.paintStains[index]
      colorIndex = playerColorIndex(stain.color)
      variant = int(stain.seed shr 7) mod StainVariants
      # One sprite id per stain: the blot is masked to the surface under THIS
      # spot, so it cannot be shared across stains of the same color/variant.
      spriteId = StainSpriteBase + index
    packet.addBoardSpriteChanged(
      state.spriteDefs,
      spriteId,
      StainSize,
      StainSize,
      sim.buildPaintStainSprite(stain, colorIndex, variant),
      "paint stain " & playerColorName(colorIndex) & " variant " & $variant,
      native = boardScale
    )
    packet.addBoardObject(
      StainObjectBase + index,
      stain.x - StainSize div 2,
      stain.y - StainSize div 2,
      StainZ,
      MapLayerId,
      spriteId
    )
    inc state.stainsSent

proc damagePopBucket(amount: int): int =
  ## Maps a "-N" pop's HP-loss amount to one of DamagePopBucketCount sprite
  ## buckets. The amounts actually in play are sparse (1 shot/grenade-splash,
  ## 2 grenade open-field, 3 spray, 6 grenade trapped-in-trench), not a dense
  ## 1..N range, so this is an explicit lookup rather than `amount - 1` — that
  ## would need one bucket per distinct hp value and blow the reserved sprite
  ## range into KillPopSpriteBase. An amount outside the known set falls into
  ## the last bucket instead of indexing out of range.
  case amount
  of 1: 0
  of 2: 1
  of 3: 2
  of 6: 3
  else: DamagePopBucketCount - 1

proc addDamagePops(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8],
  viewerIndex = -1
) {.measure.} =
  ## Places floating "-N" damage numbers from a fixed object pool. Each rises a
  ## few pixels and fades over its short life (the stage is its age quartile),
  ## drawing above players so a lost health bar reads at a glance. The map view
  ## passes no viewer and shows every pop; a player view passes its viewer index
  ## and only receives the ones inside its vision (fog honesty).
  var nextPop = 0
  for pop in sim.damagePops:
    if nextPop >= DamagePopMaxCount:
      break
    if viewerIndex >= 0 and not sim.fovVisibleAt(viewerIndex, pop.x, pop.y):
      continue
    let
      age = sim.tickCount - pop.tick
      # A kill marker lives longer and floats higher than a "-N" number so a
      # death reads bigger than a scratch.
      life = if pop.kill: KillFxTicks else: DamageFxTicks
      risePer = if pop.kill: KillPopRisePx else: DamagePopRisePx
      stage = clamp(age * DamagePopStages div life, 0,
        DamagePopStages - 1)
      colorIndex = playerColorIndex(pop.color)
      text = if pop.kill: "KO" else: "-" & $pop.amount
      sprite = sim.buildFloatingPopSprite(colorIndex, text, stage)
      # Rise a few pixels over the full life so the label lifts off the player.
      rise = risePer * age div max(1, life)
      px = pop.x - sprite.width div 2
      py = pop.y - sprite.height div 2 - rise
      spriteId =
        if pop.kill:
          KillPopSpriteBase + colorIndex * DamagePopStages + stage
        else:
          DamagePopSpriteBase +
            (colorIndex * DamagePopBucketCount + damagePopBucket(pop.amount)) *
              DamagePopStages + stage
    packet.addBoardSpriteChanged(
      spriteDefs,
      spriteId,
      sprite.width,
      sprite.height,
      sprite.pixels,
      "damage pop " & playerColorName(colorIndex) & " " & text &
        " stage " & $stage,
      native = boardScale
    )
    let objectId = DamagePopObjectBase + nextPop
    inc nextPop
    currentIds.add(objectId)
    packet.addBoardObject(objectId, px, py, DamagePopZ, MapLayerId, spriteId)

proc buildSpriteProtocolPlayerUpdates*(
  sim: var SimServer,
  playerIndex: int,
  state: PlayerViewerState,
  nextState: var PlayerViewerState
): seq[uint8] {.measure.} =
  ## Builds sprite protocol updates for one playable player view.
  result = @[]
  nextState =
    if state.isNil:
      initPlayerViewerState()
    else:
      state
  if not nextState.initialized:
    result = sim.buildSpriteProtocolPlayerInit(nextState.spriteDefs)
    nextState.initialized = true

  var currentIds: seq[int] = @[]
  if sim.phase != Playing or playerIndex < 0 or
      playerIndex >= sim.players.len:
    currentIds.add(SpritePlayerInterstitialObjectId)
    result.addBoardObject(
      SpritePlayerInterstitialObjectId,
      0,
      0,
      0,
      PlayerInterstitialLayerId,
      SpritePlayerInterstitialSpriteId
    )
    sim.addProtocolTextSprites(
      nextState.spriteDefs,
      currentIds,
      result,
      PlayerInterstitialLayerId,
      playerIndex
    )
    sim.addProtocolInterstitialActorSprites(
      nextState.spriteDefs,
      currentIds,
      result,
      PlayerInterstitialLayerId,
      playerIndex
    )
  else:
    let
      player = sim.players[playerIndex]
      viewerIsGhost = not player.alive
    if not viewerIsGhost:
      discard sim.refreshPlayerFov(playerIndex)

    # The full static map, always drawn: terrain is static knowledge.
    currentIds.add(MapObjectId)
    result.addBoardObject(MapObjectId, 0, 0, low(int16), MapLayerId, MapSpriteId)

    # The fog overlay dims everything outside this viewer's vision. Ghost
    # viewers (dead players) watch the whole map unfogged.
    if not viewerIsGhost:
      sim.addFogRuns(playerIndex, nextState.spriteDefs, currentIds, result)

    # The team flags: a pedestal flag is always visible (so an empty own
    # pedestal means the own flag is stolen); a carried flag rides its
    # carrier and is exactly as visible as that carrier. A retired heart
    # (GV32 capture or GV33 dead team) is out of play and never drawn.
    for team in sim.teams():
      let flag = sim.flags[team]
      if flag.captured:
        continue
      if viewerIsGhost or sim.flagVisibleTo(playerIndex, team):
        # A carried flag glows: the halo rides UNDER the carrier so the runner
        # is the brightest figure on the board.
        if flag.carrier >= 0:
          let auraId = FlagAuraObjectBase + ord(team)
          currentIds.add(auraId)
          result.addBoardObject(
            auraId,
            flag.x - FlagAuraSize div 2,
            flag.y - FlagAuraSize div 2,
            flag.y - 1,
            MapLayerId,
            FlagAuraSpriteBase + ord(team)
          )
        let objectId = SpritePlayerFlagObjectBase + ord(team)
        currentIds.add(objectId)
        if flag.carrier >= 0:
          # Carried: the heart rides BEHIND the carrier (z below the player), so
          # the runner's body stays the readable figure and the heart peeks out
          # around them instead of covering them. Centered on the carrier so it
          # frames the body evenly; the aura + nameplate still mark WHO runs it.
          result.addBoardObject(
            objectId,
            flag.x - FlagBannerW div 2,
            flag.y - FlagBannerH div 2,
            flag.y - 1,
            MapLayerId,
            FlagSpriteBase + ord(team)
          )
        else:
          # Home: the BIG planted banner, centered + bottom-anchored on the pedestal.
          result.addBoardObject(
            objectId,
            flag.x - PlantedFlagW div 2,
            flag.y - (PlantedFlagH - 2),
            flag.y + 1,
            MapLayerId,
            PlantedFlagSpriteBase + ord(team)
          )

    # Players: yourself (a distinct outlined self marker) is always visible;
    # everyone else — teammates included — only inside your vision; corpses
    # only for ghost viewers.
    for i in 0 ..< sim.players.len:
      let other = sim.players[i]
      if other.alive:
        if not viewerIsGhost and i != playerIndex and
            not sim.playerVisibleTo(playerIndex, i):
          continue
      elif not viewerIsGhost:
        continue
      # GV24/25: every OTHER soldier sprite in a player view — enemy,
      # teammate, corpse — renders with FUZZED aim (fuzzedAimBrads): exact
      # aim is never readable off another bot. The self marker is exact.
      let fuzzedRot = soldierRotIndex(sim.fuzzedAimBrads(i))
      var spriteId = soldierPlayerSpriteId(other.team, other.skin, fuzzedRot)
      if not other.alive:
        # A body (ghost view only): grey corpse sprite + `corpse <color> <side>`
        # so it never reads as a live soldier to a label-scanning policy.
        spriteId = corpseSoldierSpriteId(
          other.team,
          other.skin,
          fuzzedRot
        )
      elif i == playerIndex and not viewerIsGhost:
        # Yourself reads as a distinct white-outlined soldier rotated to your
        # TRUE aim (GV26): you know your own gun exactly — the fuzz exists to
        # hide OTHERS' aim, and your self marker is your own state, not a leak.
        let rot = soldierRotIndex(other.aimBrads)
        spriteId = selfSoldierSpriteId(other.skin, rot)
        result.addSpriteChanged(
          nextState.spriteDefs,
          spriteId,
          SoldierCanvas,
          SoldierCanvas,
          soldierOutlined(soldierRotPixels(other.team, other.skin, rot), 2'u8),
          # Documented self marker (RULES.md): `self <color> <side>`, only drawn
          # while alive. Side follows the aim exactly as the sim's flipH does.
          labelSelf(
            teamText(other.team),
            if soldierFacingRight(rot): LabelSideRight else: LabelSideLeft)
        )
      let objectId = other.spriteObjectId()
      currentIds.add(objectId)
      result.addBoardObject(
        objectId,
        other.spritePlayerX(),
        other.spritePlayerY(),
        other.y,
        MapLayerId,
        spriteId
      )

    sim.addAimIndicators(
      nextState.spriteDefs,
      currentIds,
      result,
      viewerIndex = playerIndex
    )
    sim.addHpPips(
      nextState.spriteDefs,
      currentIds,
      result,
      viewerIndex = playerIndex
    )
    sim.addIdentityBadges(
      nextState.spriteDefs,
      currentIds,
      result,
      viewerIndex = playerIndex
    )
    sim.addSplatters(
      nextState.spriteDefs,
      currentIds,
      result,
      viewerIndex = playerIndex
    )
    sim.addDamagePops(
      nextState.spriteDefs,
      currentIds,
      result,
      viewerIndex = playerIndex
    )
    sim.addRotatingDiamonds(nextState.spriteDefs, currentIds, result)
    sim.addMedKits(
      nextState.spriteDefs,
      currentIds,
      result,
      viewerIndex = playerIndex
    )
    sim.addShields(
      nextState.spriteDefs,
      currentIds,
      result,
      viewerIndex = playerIndex
    )
    sim.addGrenades(
      nextState.spriteDefs,
      currentIds,
      result,
      viewerIndex = playerIndex
    )
    sim.addPlasmaArcs(
      nextState.spriteDefs,
      currentIds,
      result,
      viewerIndex = playerIndex
    )
    sim.addPlasmaArcFlashes(
      nextState.spriteDefs,
      currentIds,
      result,
      viewerIndex = playerIndex
    )
    sim.addShouts(
      nextState.spriteDefs,
      currentIds,
      result,
      nextState.shoutSlots,
      viewerIndex = playerIndex
    )
    if not viewerIsGhost:
      sim.addShotImpactRings(
        nextState.spriteDefs,
        currentIds,
        result,
        viewerIndex = playerIndex
      )

    # Fire-readiness icon on the bottom-left HUD layer.
    if player.alive:
      currentIds.add(SpritePlayerRemainingObjectId)
      result.addBoardObject(
        SpritePlayerRemainingObjectId,
        1,
        1,
        0,
        HudBottomLeftLayerId,
        if player.fireCooldown > 0 or player.fireWindup > 0:
          SpritePlayerFireShadowSpriteId
        else:
          SpritePlayerFireSpriteId
      )

    # Lives counter on the top-right HUD layer.
    let
      livesText = $(player.hp + player.shieldHp) & "hp x" & $player.lives
      lives = sim.buildSpriteProtocolTextSprite([livesText], 2'u8)
    currentIds.add(SelectedTextObjectId)
    result.addSpriteChanged(
      nextState.spriteDefs,
      SpritePlayerRemainingSpriteId,
      lives.width,
      lives.height,
      lives.pixels,
      LabelPrefixLives & livesText
    )
    result.addBoardObject(
      SelectedTextObjectId,
      23 - lives.width,
      1,
      0,
      HudTopRightLayerId,
      SpritePlayerRemainingSpriteId
    )

    # Own-weapon readout under the lives counter: the sim swaps the gun out
    # whenever a spray can is carried, and a bot that has to infer its own
    # weapon from floating markers gets it wrong at the worst moments. The
    # label is the machine contract ("weapon gun" | "weapon spray").
    let
      weaponText = if player.hasPlasmaArc: LabelWeaponSpray else: LabelWeaponGun
      weapon = sim.buildSpriteProtocolTextSprite([weaponText], 2'u8)
    currentIds.add(SpritePlayerWeaponObjectId)
    result.addSpriteChanged(
      nextState.spriteDefs,
      SpritePlayerWeaponSpriteId,
      weapon.width,
      weapon.height,
      weapon.pixels,
      labelWeapon(weaponText)
    )
    result.addBoardObject(
      SpritePlayerWeaponObjectId,
      23 - weapon.width,
      8,
      0,
      HudTopRightLayerId,
      SpritePlayerWeaponSpriteId
    )

    # Own-aim readback: an invisible 1x1 marker whose LABEL states this
    # player's turret angle outright (`own aim <brads>`). The observation
    # carried no readback at all — bots dead-reckoned their own aim
    # open-loop, and the drift measurably cost accuracy (docs/PROTOCOL.md).
    # Label-carried like the lives counter: the 1x1 sprite re-sends only on
    # ticks the aim actually changed.
    currentIds.add(SpritePlayerOwnAimObjectId)
    result.addSpriteChanged(
      nextState.spriteDefs,
      SpritePlayerOwnAimSpriteId,
      1,
      1,
      newRgbaPixels(1, 1),
      labelOwnAim(player.aimBrads)
    )
    result.addBoardObject(
      SpritePlayerOwnAimObjectId,
      0,
      0,
      0,
      HudTopRightLayerId,
      SpritePlayerOwnAimSpriteId
    )

  sim.addTeamScoreboard(nextState.spriteDefs, currentIds, result)

  if not state.isNil:
    for objectId in state.objectIds:
      if objectId notin currentIds:
        result.addDeleteObject(objectId)
  nextState.objectIds = currentIds

proc replayCommandAt(layer, x, y: int): char =
  ## Returns the replay transport command under a UI coordinate.
  if layer != ReplayBottomLeftLayerId:
    return '\0'
  let
    localX = x - TransportX
    localY = y - TransportY
  if localY >= 0 and localY < TransportIconHeight:
    let index = localX div TransportButtonStride
    if index < 0 or index >= TransportIconCount:
      return '\0'
    if localX - index * TransportButtonStride >= TransportIconSize:
      return '\0'
    case index
    of 0: return '<'
    of 1: return ' '
    of 2: return 'e'
    of 3: return 'r'
    of 4: return 'b'
    else: return '\0'
  if localY >= TransportSpeedY and localY < TransportSpeedY + 6:
    let speedX = localX - TransportSpeedX
    if speedX >= 0 and speedX < 12:
      return '1'
    if speedX >= 16 and speedX < 28:
      return '2'
    if speedX >= 32 and speedX < 44:
      return '3'
    if speedX >= 48 and speedX < 60:
      return '4'
    if speedX >= 64 and speedX < 76:
      return '8'
    if speedX >= 80 and speedX < 100:
      return '6'
  '\0'

proc replayScrubTickAt(
  layer, x, y, maxTick: int,
  requireInside = true
): int =
  ## Returns the replay tick under the scrubber pointer.
  if layer != ReplayCenterBottomLayerId or maxTick < 0:
    return -1
  let
    scrubberX = max(0, (ScreenWidth - ReplayScrubberWidth) div 2)
    localX = x - scrubberX
    localY = y - ReplayScrubberY
  if requireInside and (
      localX < 0 or localX >= ReplayScrubberWidth or
      localY < 0 or localY >= ReplayScrubberHeight
    ):
    return -1
  if ReplayScrubberWidth <= 1:
    return 0
  let clampedX = clamp(localX, 0, ReplayScrubberWidth - 1)
  clamp((clampedX * maxTick) div (ReplayScrubberWidth - 1), 0, maxTick)

proc buildReplayScrubberSprite(
  tick, maxTick: int,
  enabled: bool
): tuple[width, height: int, pixels: seq[uint8]] {.measure.} =
  ## Builds a compact replay scrubber sprite.
  result.width = ReplayScrubberWidth
  result.height = ReplayScrubberHeight
  result.pixels = newRgbaPixels(ReplayScrubberWidth, ReplayScrubberHeight)
  let knobX =
    if maxTick > 0:
      clamp(
        (tick * (ReplayScrubberWidth - 1)) div maxTick,
        0,
        ReplayScrubberWidth - 1
      )
    else:
      0

  for x in 0 ..< ReplayScrubberWidth:
    result.pixels.putRgbaPixel(
      ReplayScrubberTrackY * ReplayScrubberWidth + x,
      1'u8
    )
  if enabled:
    for x in 0 .. knobX:
      result.pixels.putRgbaPixel(
        ReplayScrubberTrackY * ReplayScrubberWidth + x,
        10'u8
      )
  for y in 0 ..< ReplayScrubberHeight:
    result.pixels.putRgbaPixel(
      y * ReplayScrubberWidth + knobX,
      if enabled: 2'u8 else: 1'u8
    )
  if knobX > 0:
    result.pixels.putRgbaPixel(
      ReplayScrubberTrackY * ReplayScrubberWidth + knobX - 1,
      if enabled: 2'u8 else: 1'u8
    )
  if knobX < ReplayScrubberWidth - 1:
    result.pixels.putRgbaPixel(
      ReplayScrubberTrackY * ReplayScrubberWidth + knobX + 1,
      if enabled: 2'u8 else: 1'u8
    )

proc blitTransportIcon(
  target: var seq[uint8],
  sheet: Sprite,
  cell, baseX, baseY: int,
  tint: uint8
) =
  ## Blits one transport icon cell into protocol pixels.
  let sourceX = cell * TransportIconSize
  for y in 0 ..< TransportIconHeight:
    for x in 0 ..< TransportIconSize:
      let colorIndex = sheet.pixels[sheet.spriteIndex(sourceX + x, y)]
      if colorIndex == TransparentColorIndex:
        continue
      target.putRgbaPixel(
        (baseY + y) * TransportWidth + baseX + x,
        tint
      )

proc buildReplayControlsSprite(
  sim: SimServer,
  replayPlaying: bool,
  replaySpeed: int,
  replayLooping: bool,
  replayEnabled: bool
): tuple[width, height: int, pixels: seq[uint8]] {.measure.} =
  ## Builds the replay transport controls sprite.
  result.width = TransportWidth
  result.height = TransportHeight
  result.pixels = newRgbaPixels(TransportWidth, TransportHeight)
  let
    sheet = transportSheet()
    iconCells = [
      0,
      if replayPlaying: 2 else: 1,
      3,
      4,
      5
    ]
  for i in 0 ..< iconCells.len:
    let tint =
      if not replayEnabled:
        1'u8
      elif i == 3:
        if replayLooping: 10'u8 else: 1'u8
      else:
        2'u8
    result.pixels.blitTransportIcon(
      sheet,
      iconCells[i],
      i * TransportButtonStride,
      0,
      tint
    )

  let speedTexts = ["1X", "2X", "3X", "4X", "8X", "16X"]
  var x = TransportSpeedX
  for i in 0 ..< speedTexts.len:
    let speed =
      case i
      of 0: 1
      of 1: 2
      of 2: 3
      of 3: 4
      of 4: 8
      else: 16
    let color = if speed == replaySpeed: 10'u8 else: 1'u8
    sim.blitSmallText(
      result.pixels,
      TransportWidth,
      TransportHeight,
      speedTexts[i],
      x,
      TransportSpeedY,
      color
    )
    x += TransportSpeedGap

proc buildReplayMismatchSprite(
  sim: SimServer,
  tick: int
): tuple[width, height: int, pixels: seq[uint8], label: string] {.measure.} =
  ## Builds the top-center replay hash mismatch warning sprite.
  result.label = "hash mismatch at tick " & $tick
  let textWidth = sim.asciiSprites.textWidth(result.label)
  result.width = max(ReplayMismatchMinWidth, textWidth + ReplayMismatchPadX * 2)
  result.height = TextLineHeight + ReplayMismatchPadY * 2
  result.pixels = newRgbaPixels(result.width, result.height)
  for i in 0 ..< result.width * result.height:
    result.pixels.putRawRgbaPixel(
      i,
      ReplayMismatchBgR,
      ReplayMismatchBgG,
      ReplayMismatchBgB,
      ReplayMismatchBgA
    )
  sim.blitSmallText(
    result.pixels,
    result.width,
    result.height,
    result.label,
    (result.width - textWidth) div 2,
    ReplayMismatchPadY,
    2'u8
  )

proc addReplayMismatchWarning(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8],
  tick: int
) {.measure.} =
  ## Adds a fixed top-center replay hash mismatch warning.
  if tick < 0:
    return
  let warning = sim.buildReplayMismatchSprite(tick)
  packet.addLayer(
    ReplayMismatchLayerId,
    ReplayMismatchLayerType,
    UiLayerFlag
  )
  packet.addViewport(
    ReplayMismatchLayerId,
    warning.width,
    warning.height
  )
  currentIds.add(ReplayMismatchObjectId)
  packet.addSpriteChanged(
    spriteDefs,
    ReplayMismatchSpriteId,
    warning.width,
    warning.height,
    warning.pixels,
    warning.label
  )
  packet.addBoardObject(
    ReplayMismatchObjectId,
    0,
    0,
    0,
    ReplayMismatchLayerId,
    ReplayMismatchSpriteId
  )

proc endzoneFadeSpriteId(team: Team, stage: int): int =
  ## Returns the sprite id owned by one team's fade crop at one stage.
  EndzoneFadeSpriteBase + ord(team) * GlowFadeStages + stage

proc addEndzoneFadeSprite(
  sim: SimServer,
  state: var GlobalViewerState,
  packet: var seq[uint8],
  team: Team,
  stage: int
): tuple[x, y, w, h: int] =
  ## Ships one team's fade crop for one stage to this viewer (no-op if this
  ## connection already has it — sprite defs are tracked per viewer) and
  ## returns its placement box. w == 0 means the hot and cold maps agree and
  ## there is nothing to fade.
  let strip = sim.endzoneStripSprite(team, stage)
  result = (x: strip.x, y: strip.y, w: strip.w, h: strip.h)
  if strip.w <= 0:
    return
  packet.addBoardSpriteChanged(
    state.spriteDefs,
    endzoneFadeSpriteId(team, stage),
    strip.w,
    strip.h,
    strip.pixels,
    LabelPrefixEndzone & teamText(team) & " power " & $stage,
    native = boardScale
  )

proc addEndzonePrewarm(
  sim: SimServer,
  state: var GlobalViewerState,
  packet: var seq[uint8]
) {.measure.} =
  ## Drips every (team, stage) endzone fade crop to this viewer over the first
  ## seconds of the connection — one crop every EndzonePrewarmEveryFrames — so
  ## a later steal/return ramp is a pure object remap instead of a ~200 KB
  ## sprite send per frame right at the dramatic moment. Crops the fade ramp
  ## already shipped on demand are skipped by the per-viewer sprite-def check.
  let pairCount = sim.gameMap.teamCount() * (GlowFadeStages - 1)     # stages 1..7 per team; 0 never draws.
  let pairIndex = state.endzonePrewarmFrames div EndzonePrewarmEveryFrames
  if state.endzonePrewarmFrames mod EndzonePrewarmEveryFrames == 0 and
      pairIndex < pairCount:
    let
      team = Team(pairIndex div (GlowFadeStages - 1))
      stage = 1 + pairIndex mod (GlowFadeStages - 1)
    discard sim.addEndzoneFadeSprite(state, packet, team, stage)
  inc state.endzonePrewarmFrames

proc addEndzoneGlowFade(
  sim: SimServer,
  state: var GlobalViewerState,
  currentIds: var seq[int],
  packet: var seq[uint8]
) {.measure.} =
  ## Powers each team's endzone crack-glow + capture line down when that team's
  ## heart is taken (flag.carrier >= 0) and back up when it comes home, by
  ## ramping a per-team crossfade stage ±1 per frame and drawing the matching
  ## endzone fade crop just above the map (z below every floor decal/actor).
  ## Spectator/broadcast only — the shared map sprite and the POV/RL view are
  ## never touched, and stage 0 is a visual no-op (the baked glow itself).
  for team in sim.teams():
    # GV32: a captured heart never comes home — an eliminated team's endzone
    # glow stays down for the rest of the game.
    let taken = sim.flags[team].carrier >= 0 or sim.flags[team].captured
    if taken and state.endzoneFade[team] < GlowFadeStages - 1:
      inc state.endzoneFade[team]
    elif not taken and state.endzoneFade[team] > 0:
      dec state.endzoneFade[team]
    let stage = state.endzoneFade[team]
    if stage <= 0:
      continue                         # full glow: the baked map already shows it.
    let box = sim.addEndzoneFadeSprite(state, packet, team, stage)
    if box.w <= 0:
      continue                         # hot and cold maps agree: nothing to fade.
    let objectId = EndzoneFadeObjectBase + ord(team)
    currentIds.add(objectId)
    packet.addBoardObject(
      objectId,
      box.x,
      box.y,
      low(int16) + 1,                  # just above the map, below all decals/actors.
      MapLayerId,
      endzoneFadeSpriteId(team, stage)
    )

proc rigSegLabel(seg: RigSeg, color: string): string =
  ## The `player <color>` contract label rides on the HEAD segment (the aim-facing
  ## piece a label scanner reads as the actor); limbs get plain tags.
  case seg
  of rsHead: LabelPrefixPlayer & color
  of rsArmL, rsArmR: "cog arm " & color
  of rsLegFL, rsLegFR, rsLegRear: "cog leg " & color
  else: "cog wheel " & color

proc addCogRigObjects(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8],
  player: Player,
  drive: CogDriveState,
  carrying: bool
) =
  ## Places one cog's articulated TURRET trike. Every segment sprite is baked in
  ## the same RigCanvas, HUB-centered, so all objects share ONE canvas position
  ## and differ only by sprite id + z. Sprites are lazily defined (large pools).
  ## Turret swivel: the HEAD (+gun) and ARMS are baked to AIM; the LEGS and WHEELS
  ## are baked to the movement HEADING (bodyHeading) with per-leg swing + inner-leg
  ## shorten and per-wheel caster. The base is fully decoupled from the head
  ## (true tank); `carrying` is accepted for future carry-specific posing but the
  ## heart itself is emitted in the flag loop.
  ## Z (painter depth ~ map Y): rear wheel/leg < front wheels < front legs < head
  ## < arms (arms cradle the forward heart on top).
  let
    color = teamText(player.team)
    aimStep = soldierRotIndex(player.aimBrads)
    # TRUE TANK: the leg base points exactly where the cog MOVES (fully decoupled
    # from the head/aim — it can face 180° opposite the head when reversing). No
    # clamp; the legs stay tucked via the art so full divergence isn't spidery.
    baseHeading = if drive.initialized: drive.bodyHeading else: player.aimBrads
    headStep = rigHeadingStep(baseHeading)
    base = player.joinOrder
    # Center the RigCanvas on the player (canvas center = hub). 1× map px.
    rigX = player.x + CollisionW div 2 - RigCanvas div 2
    rigY = player.y + CollisionH div 2 - RigCanvas div 2

  # Precompute the movement-driven leg/wheel steps.
  proc legSprite(seg: RigSeg): int =
    rigLegSpriteId(player.team, seg, headStep,
      rigLegSwingStep(seg, drive.turnAmt), rigLegShortenStep(seg, drive.turnAmt))
  proc wheelSprite(seg: RigSeg, caster: int): int =
    rigWheelSpriteId(player.team, seg, headStep,
      rigCasterStep(caster, baseHeading))

  # Baked-art selector for each segment (so define-on-demand rebakes the exact pose).
  proc bakePixels(seg: RigSeg): seq[uint8] =
    case seg
    of rsHead:
      rigSegPixels(
        player.team,
        rsHead,
        aimStep,
        0,
        0,
        renderScale = boardScale,
        skin = player.skin
      )
    of rsArmL, rsArmR: rigSegPixels(player.team, seg, aimStep, 0, 0, boardScale)
    of rsLegFL, rsLegFR, rsLegRear:
      rigSegPixels(player.team, seg, headStep,
        rigLegSwingStep(seg, drive.turnAmt),
        rigLegShortenStep(seg, drive.turnAmt), boardScale)
    of rsWheelL:
      rigSegPixels(player.team, rsWheelL, headStep,
        rigCasterStep(drive.casterFL, baseHeading), 0, boardScale)
    of rsWheelR:
      rigSegPixels(player.team, rsWheelR, headStep,
        rigCasterStep(drive.casterFR, baseHeading), 0, boardScale)
    of rsWheelRear:
      rigSegPixels(player.team, rsWheelRear, headStep,
        rigCasterStep(drive.casterRear, baseHeading), 0, boardScale)

  var segs: seq[tuple[seg: RigSeg, objectId, spriteId, z: int]] = @[
    (rsWheelRear, RigWheelObjectBase + base*3 + 2,
      wheelSprite(rsWheelRear, drive.casterRear), player.y - 4),
    (rsLegRear, RigLegObjectBase + base*3 + 2, legSprite(rsLegRear), player.y - 3),
    (rsWheelL, RigWheelObjectBase + base*3 + 0,
      wheelSprite(rsWheelL, drive.casterFL), player.y - 2),
    (rsWheelR, RigWheelObjectBase + base*3 + 1,
      wheelSprite(rsWheelR, drive.casterFR), player.y - 2),
    (rsLegFL, RigLegObjectBase + base*3 + 0, legSprite(rsLegFL), player.y - 1),
    (rsLegFR, RigLegObjectBase + base*3 + 1, legSprite(rsLegFR), player.y - 1),
    (rsHead, RigHeadObjectBase + base,
      rigHeadSpriteId(player.team, player.skin, aimStep),
      player.y)]
  # Arms = the cog's SHOULDER pads. They're part of the cog's fixed silhouette:
  # always drawn, always in their natural tucked pose, rotating with the HEAD/aim
  # (never jutting forward — the earlier "reach" pose read as weird prongs). At rest
  # they sit just below the head z (head cube reads on top). While CARRYING, they
  # drop to y-2 so the carried heart tucks BETWEEN them and the head: the z-sandwich
  # is head(y) > heart(y-1) > arms(y-2) — head/face stays on top, the heart sits
  # under the head and over the arms, so it reads as held under the chin, not over
  # the face.
  let armZ = if carrying: player.y - 2 else: player.y - 1
  segs.add((rsArmL, RigArmObjectBase + base*2 + 0,
    rigArmSpriteId(player.team, rsArmL, aimStep, 0), armZ))
  segs.add((rsArmR, RigArmObjectBase + base*2 + 1,
    rigArmSpriteId(player.team, rsArmR, aimStep, 0), armZ))

  for s in segs:
    if spriteDefs.spriteDefinitionIndex(s.spriteId) < 0:
      packet.addBoardSpriteChanged(
        spriteDefs, s.spriteId, RigCanvas, RigCanvas,
        bakePixels(s.seg), rigSegLabel(s.seg, color), native = boardScale)
    currentIds.add(s.objectId)
    packet.addBoardObject(s.objectId, rigX, rigY, s.z, MapLayerId, s.spriteId)

  # The held WEAPON: its OWN object (not baked into the head), tracking AIM, with
  # a warm backlight glow so the dark art pops. Drawn ABOVE the head so it always
  # reads. A cog holds exactly one thing — the sim swaps the gun out whenever a
  # spray can is carried, so the art swaps with it and the silhouette shows which
  # weapon is live. Both share one object slot (a cog can't hold both).
  let
    holdsSpray = player.hasPlasmaArc
    weaponSpriteId =
      if holdsSpray: rigSpraySpriteId(player.team, aimStep)
      else: rigGunSpriteId(player.team, aimStep)
  if spriteDefs.spriteDefinitionIndex(weaponSpriteId) < 0:
    packet.addBoardSpriteChanged(
      spriteDefs, weaponSpriteId, RigCanvas, RigCanvas,
      (if holdsSpray: rigSprayCanPixels(player.team, aimStep, boardScale)
       else: rigGunPixels(player.team, aimStep, boardScale)),
      labelCogWeapon(color, spray = holdsSpray),
      native = boardScale)
  let weaponObjectId = RigGunObjectBase + base
  currentIds.add(weaponObjectId)
  packet.addBoardObject(
    weaponObjectId, rigX, rigY, player.y + 1, MapLayerId, weaponSpriteId)

proc buildSpriteProtocolUpdates*(
  sim: var SimServer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState,
  overlays: openArray[DebugOverlay] = [],
  replayTick = -1,
  replayPlaying = false,
  replaySpeed = 1,
  replayMaxTick = -1,
  replayLooping = false,
  replayEnabled = false,
  replayMismatchTick = -1
): seq[uint8] {.measure.} =
  ## Builds global viewer object updates for the current tick.
  result = @[]
  nextState = state
  nextState.replayCommands.setLen(0)
  nextState.replaySeekTick = -1
  # A `v:<slot>` DOM command SETS the POV directly (clear on -1), rather than
  # toggling like a board click, so the broadcast roster stays authoritative.
  if nextState.povSelectPending >= -1:
    nextState.selectedJoinOrder =
      if nextState.povSelectPending >= 0: nextState.povSelectPending
      else: -1
  nextState.povSelectPending = -2
  if nextState.clickPending:
    let scoreJoinOrder = sim.scoreboardJoinOrderAt(
      nextState.mouseLayer,
      nextState.mouseX,
      nextState.mouseY
    )
    if scoreJoinOrder >= 0:
      nextState.toggleSelectedJoinOrder(scoreJoinOrder)
    elif replayEnabled and replayTick >= 0:
      let seekTick = replayScrubTickAt(
        nextState.mouseLayer,
        nextState.mouseX,
        nextState.mouseY,
        replayMaxTick
      )
      if seekTick >= 0:
        nextState.scrubbingReplay = true
        nextState.replaySeekTick = seekTick
      else:
        let command = replayCommandAt(
          nextState.mouseLayer,
          nextState.mouseX,
          nextState.mouseY
        )
        if command != '\0':
          nextState.replayCommands.add(command)
        elif not nextState.povActive and nextState.mouseLayer == MapLayerId:
          # Board clicks arrive in the RenderScale× wire space the spectator
          # map layer is served at; the sim compares in 1× map pixels.
          nextState.toggleSelectedJoinOrder(
            sim.selectSpritePlayer(
              nextState.mouseX div RenderScale,
              nextState.mouseY div RenderScale
            )
          )
    elif not nextState.povActive and nextState.mouseLayer == MapLayerId:
      nextState.toggleSelectedJoinOrder(
        sim.selectSpritePlayer(
          nextState.mouseX div RenderScale,
          nextState.mouseY div RenderScale
        )
      )
    nextState.clickPending = false
  if replayEnabled and replayTick >= 0 and nextState.mouseDown and
      nextState.scrubbingReplay:
    let seekTick = replayScrubTickAt(
      nextState.mouseLayer,
      nextState.mouseX,
      nextState.mouseY,
      replayMaxTick
    )
    if seekTick >= 0:
      nextState.replaySeekTick = seekTick
  let playerIndex = sim.selectedPlayerIndex(nextState.selectedJoinOrder)
  if playerIndex < 0:
    nextState.selectedJoinOrder = -1
  let
    povActive = playerIndex >= 0
    povChanged = povActive != state.povActive or
      nextState.selectedJoinOrder != state.povJoinOrder
  if povChanged:
    nextState.objectIds.setLen(0)
    nextState.povState = initPlayerViewerState()
    # The POV (player) stream and the board (spectator) stream reuse sprite
    # ids at DIFFERENT render scales, and the client keys sprites by id
    # across both modes — so a mode switch must forget the def cache, or the
    # re-init would dedup-skip sprites the other mode overwrote client-side.
    nextState.spriteDefs.setLen(0)
    # Permanent stains are emitted once and never re-sent, so a mode switch —
    # which forgets the sprite defs above and (entering POV) clears the client's
    # objects — must re-arm the cursor, or the board would come back with every
    # stain object referencing a sprite id the client no longer has defined.
    nextState.stainsSent = 0
    if not povActive:
      nextState.initialized = false
  nextState.povActive = povActive
  nextState.povJoinOrder = nextState.selectedJoinOrder
  if povActive:
    var povState: PlayerViewerState
    let povClearsObjects =
      nextState.povState.isNil or not nextState.povState.initialized
    result = sim.buildSpriteProtocolPlayerUpdates(
      playerIndex,
      nextState.povState,
      povState
    )
    nextState.povState = povState
    var currentIds: seq[int] = @[]
    sim.addScoreboard(
      nextState.spriteDefs,
      currentIds,
      result,
      nextState.selectedJoinOrder
    )
    if playerIndex < overlays.len:
      result.addDebugOverlay(
        nextState.spriteDefs,
        currentIds,
        overlays[playerIndex],
        playerIndex
      )

    sim.addReplayMismatchWarning(
      nextState.spriteDefs,
      currentIds,
      result,
      replayMismatchTick
    )
    if not povClearsObjects:
      for objectId in state.objectIds:
        if objectId notin currentIds:
          result.addDeleteObject(objectId)
    nextState.objectIds = currentIds
    return
  # Everything below is the spectator BOARD section: emit it at the
  # supersampled render scale. The POV branch above already returned (it is a
  # 1× player stream), and every other stream builder leaves boardScale at 1.
  boardScale = RenderScale
  defer: boardScale = 1
  if not nextState.initialized:
    result = sim.buildSpriteProtocolInit(nextState.spriteDefs)
    result.addLayer(
      ReplayCenterBottomLayerId,
      ReplayCenterBottomLayerType,
      UiLayerFlag
    )
    result.addViewport(
      ReplayCenterBottomLayerId,
      ScreenWidth,
      ReplayPanelHeight
    )
    result.addLayer(
      ReplayBottomLeftLayerId,
      ReplayBottomLeftLayerType,
      UiLayerFlag
    )
    result.addViewport(
      ReplayBottomLeftLayerId,
      ScreenWidth,
      ReplayPanelHeight
    )
    nextState.initialized = true

  var currentIds: seq[int] = @[]
  sim.addScoreboard(
    nextState.spriteDefs,
    currentIds,
    result,
    nextState.selectedJoinOrder
  )
  sim.addEndzonePrewarm(nextState, result)
  sim.addEndzoneGlowFade(nextState, currentIds, result)
  # Permanent terrain paint: incremental (only stains this viewer lacks) and
  # intentionally NOT tracked in currentIds, so it persists like the map bands.
  sim.addPaintStains(nextState, result)
  sim.addSplatters(nextState.spriteDefs, currentIds, result)
  sim.addDamagePops(nextState.spriteDefs, currentIds, result)
  sim.addShotTracers(nextState.spriteDefs, currentIds, result)
  sim.addHitFlashes(nextState.spriteDefs, currentIds, result)
  sim.addRotatingDiamonds(nextState.spriteDefs, currentIds, result)
  sim.addMedKits(nextState.spriteDefs, currentIds, result)
  sim.addShields(nextState.spriteDefs, currentIds, result)
  sim.addGrenades(nextState.spriteDefs, currentIds, result)
  sim.addPlasmaArcs(nextState.spriteDefs, currentIds, result)
  sim.addPlasmaArcFlashes(nextState.spriteDefs, currentIds, result)
  sim.addBoardShouts(nextState, currentIds, result)
  sim.addAimIndicators(nextState.spriteDefs, currentIds, result)
  sim.addHpPips(nextState.spriteDefs, currentIds, result)
  sim.addIdentityBadges(nextState.spriteDefs, currentIds, result)

  # Advance the per-player segmented-trike drive animation. Only step on a NEW
  # tick; a sequential 1..16-tick delta smooths, any other delta (scrub, pause,
  # respawn, dead) SNAPS to a fresh rest pose so a jump never inherits a stale limb
  # pose. Broadcast-only + deterministic given the recorded velocities, so playback
  # stays replay-exact.
  const MaxSmoothStepTicks = PlaybackSpeeds[^1]
    ## The cog-drive smoothing window follows the top playback speed by
    ## construction (it used to be a hand-synced copy of that value).
  let neverStepped = nextState.cogDriveTick == low(int)
  let tickDelta = if neverStepped: 0 else: sim.tickCount - nextState.cogDriveTick
  if neverStepped or tickDelta != 0:
    let sequential = not neverStepped and
      tickDelta >= 1 and tickDelta <= MaxSmoothStepTicks
    for i in 0 ..< sim.players.len:
      let p = sim.players[i]
      if not p.alive:
        nextState.cogDrive[i] = initCogDriveState(p.aimBrads)
      elif sequential and nextState.cogDrive[i].initialized:
        nextState.cogDrive[i] = stepCogDrive(
          nextState.cogDrive[i], p.velX, p.velY, p.aimBrads)
      else:
        nextState.cogDrive[i] = initCogDriveState(p.aimBrads)
    nextState.cogDriveTick = sim.tickCount

  for playerIndex in 0 ..< sim.players.len:
    let player = sim.players[playerIndex]
    if not player.alive:
      continue
    # The cog draws as an articulated TURRET trike (board only): head + gun + arms
    # face AIM; 3 legs + 3 caster wheels track MOVEMENT (bodyHeading), each its own
    # board object so aim and movement read independently. Arms appear only while
    # carrying. All poses come from the scrub-snapped CogDriveState, so playback is
    # replay-exact. All coords are 1× MAP px; addBoardObject applies boardScale.
    sim.addCogRigObjects(nextState.spriteDefs, currentIds, result,
      player, nextState.cogDrive[playerIndex],
      carrying = sim.carriedFlagTeam(playerIndex) >= 0)
    if sim.config.showPlayerLabels:
      let flagTeamOrd = sim.carriedFlagTeam(playerIndex)
      let
        labelSpriteId = player.spritePlayerNameSpriteId()
        labelObjectId = player.spritePlayerNameObjectId()
        # Stable content key: name art only changes when the name or carried
        # flag marker changes. Skip rebuild + wire when the key already matches.
        labelKey =
          if flagTeamOrd >= 0:
            "name " & playerLabelText(player) & " flag " & $flagTeamOrd
          else:
            "name " & playerLabelText(player)
        defIndex = nextState.spriteDefs.spriteDefinitionIndex(labelSpriteId)
      var
        labelW = 0
        labelH = 0
      if defIndex >= 0 and
          nextState.spriteDefs[defIndex].label == labelKey:
        labelW = nextState.spriteDefs[defIndex].width div max(1, boardScale)
        labelH = nextState.spriteDefs[defIndex].height div max(1, boardScale)
      else:
        let label =
          if flagTeamOrd >= 0:
            sim.buildCarrierNameSprite(player, flagTeamOrd,
              smooth = boardScale > 1)
          else:
            sim.buildSpriteProtocolTextSprite(
              playerLabelLines(sim, player, playerIndex),
              PlayerNameColor,
              smooth = boardScale > 1
            )
        labelW = label.width
        labelH = label.height
        result.addBoardSpriteChanged(
          nextState.spriteDefs,
          labelSpriteId,
          label.width,
          label.height,
          label.pixels,
          labelKey,
          native = boardScale
        )
      let
        labelX = player.overheadAnchorX() +
          (SoldierBodyPx - labelW) div 2
        labelY = player.overheadAnchorY() - OverheadYOffset -
          HpBarH - labelH - 1
      currentIds.add(labelObjectId)
      result.addBoardObject(
        labelObjectId,
        labelX,
        labelY,
        PlayerNameZ,
        MapLayerId,
        labelSpriteId
      )

  # Both team flags: the banner planted on the home pedestal or riding the
  # carrier, with a floor-glow halo under any carrier so the flag-runner reads
  # as the brightest figure on the board. A retired heart (GV32 capture or
  # GV33 dead team) is out of play and never drawn.
  for team in sim.teams():
    let
      flag = sim.flags[team]
      objectId = FlagObjectBase + ord(team)
    if flag.captured:
      continue
    if flag.carrier >= 0:
      let auraId = FlagAuraObjectBase + ord(team)
      currentIds.add(auraId)
      result.addBoardObject(
        auraId,
        flag.x - FlagAuraSize div 2,
        flag.y - FlagAuraSize div 2,
        flag.y - 1,
        MapLayerId,
        FlagAuraSpriteBase + ord(team)
      )
    currentIds.add(objectId)
    if flag.carrier >= 0:
      # Carried: the rig cog CRADLES the heart in its arms out FRONT along the aim.
      # The heart sprite is baked PER AIM STEP so it rotates WITH the cog (stays
      # gripped, never floats/tumbles free); its position also rides forward on the
      # aim. Z-sandwich: head(carrier.y) > heart(carrier.y-1) > arms(carrier.y-2) —
      # the heart sits UNDER the head/face and OVER the arms, so it reads as held
      # under the chin, never covering the face. Broadcast board only; POV unchanged.
      let
        carrier = sim.players[flag.carrier]
        aimStep = soldierRotIndex(carrier.aimBrads)
        aim = aimVector(carrier.aimBrads)
        hx = flag.x + int(round(aim.x * float(CarryHeartFwdPx)))
        hy = flag.y + int(round(aim.y * float(CarryHeartFwdPx)))
        heartSpriteId = carryHeartSpriteId(team, aimStep)
      if nextState.spriteDefs.spriteDefinitionIndex(heartSpriteId) < 0:
        result.addBoardSpriteChanged(
          nextState.spriteDefs, heartSpriteId, FlagBannerW, FlagBannerH,
          buildCarryHeartSprite(team, aimStep),
          flagLabel(team) & " carried", native = boardScale)
      result.addBoardObject(
        objectId,
        hx - FlagBannerW div 2,
        hy - FlagBannerH div 2,
        carrier.y - 1,
        MapLayerId,
        heartSpriteId
      )
    else:
      # Home: the BIG planted banner, centered + bottom-anchored on the pedestal.
      result.addBoardObject(
        objectId,
        flag.x - PlantedFlagW div 2,
        flag.y - (PlantedFlagH - 2),
        flag.y + 1,
        MapLayerId,
        PlantedFlagSpriteBase + ord(team)
      )

  if sim.hasInterstitialFrame():
    # Status text and (on game over) the winner roster float directly over
    # the arena: the old full-screen dark interstitial background is gone —
    # the map, bubbles, and corner rosters stay visible throughout.
    sim.addProtocolTextSprites(
      nextState.spriteDefs,
      currentIds,
      result,
      InterstitialLayerId,
      -1
    )
    sim.addProtocolInterstitialActorSprites(
      nextState.spriteDefs,
      currentIds,
      result,
      InterstitialLayerId,
      -1
    )

  if replayEnabled:
    let
      controlTick = max(0, replayTick)
      controlMaxTick = max(controlTick, replayMaxTick)
      tickText = sim.buildSpriteProtocolTextSprite(
        ["TICK " & $controlTick],
        2'u8
      )
      scrubber = buildReplayScrubberSprite(
        controlTick,
        controlMaxTick,
        true
      )
      controls = sim.buildReplayControlsSprite(
        replayPlaying,
        replaySpeed,
        replayLooping,
        replayEnabled
      )
    currentIds.add(ReplayTickObjectId)
    currentIds.add(ReplayControlsObjectId)
    currentIds.add(ReplayScrubberObjectId)
    result.addSpriteChanged(
      nextState.spriteDefs,
      ReplayTickSpriteId,
      tickText.width,
      tickText.height,
      tickText.pixels,
      "replay tick " & $controlTick
    )
    result.addBoardObject(
      ReplayTickObjectId,
      max(0, (ScreenWidth - tickText.width) div 2),
      0,
      0,
      ReplayCenterBottomLayerId,
      ReplayTickSpriteId
    )
    result.addSpriteChanged(
      nextState.spriteDefs,
      ReplayScrubberSpriteId,
      scrubber.width,
      scrubber.height,
      scrubber.pixels,
      "replay scrubber " & $controlTick & "/" & $controlMaxTick
    )
    result.addBoardObject(
      ReplayScrubberObjectId,
      max(0, (ScreenWidth - ReplayScrubberWidth) div 2),
      ReplayScrubberY,
      0,
      ReplayCenterBottomLayerId,
      ReplayScrubberSpriteId
    )
    result.addSpriteChanged(
      nextState.spriteDefs,
      ReplayControlsSpriteId,
      controls.width,
      controls.height,
      controls.pixels,
      "replay controls play=" & $replayPlaying &
        " speed=" & $replaySpeed & " loop=" & $replayLooping
    )
    result.addBoardObject(
      ReplayControlsObjectId,
      TransportX,
      TransportY,
      0,
      ReplayBottomLeftLayerId,
      ReplayControlsSpriteId
    )
  sim.addReplayMismatchWarning(
    nextState.spriteDefs,
    currentIds,
    result,
    replayMismatchTick
  )
  sim.addTeamScoreboard(nextState.spriteDefs, currentIds, result)

  for objectId in state.objectIds:
    if objectId notin currentIds:
      result.addDeleteObject(objectId)
  nextState.objectIds = currentIds

proc warmBoardRenderCaches*(sim: SimServer) =
  ## Pre-bakes every process-wide spectator render cache at server startup so
  ## the first global viewer's init packet is assembled instantly. Without
  ## this the first connection paid the whole supersampled bake — ~8s on a
  ## laptop, far longer on a small CI runner, which tripped the coworld
  ## certifier's first-message timeout. No-op at RenderScale 1; every cache
  ## here is idempotent so later ensure calls are free.
  if RenderScale <= 1:
    return
  boardScale = RenderScale
  defer: boardScale = 1
  sim.ensureBoardMaps()
  for team in sim.teams():
    for stage in 1 ..< GlowFadeStages:
      discard sim.endzoneStripSprite(team, stage)
  let usedSkins = sim.config.usedSkins()
  for skin in Skin:
    if skin notin usedSkins:
      continue
    for team in sim.teams():
      for rot in 0 ..< SoldierRotations:
        discard soldierRotPixels(team, skin, rot, RenderScale)
  # The board turret-rig head follows the configured skin; the remaining segments
  # are shared. Prebake the REST pose at every aim/heading step so a
  # standing/straight-driving cog is hot on the first frame; maneuvering poses
  # bake lazily.
  for skin in usedSkins:
    for team in sim.teams():
      for rot in 0 ..< SoldierRotations:
        discard rigSegPixels(
          team, rsHead, rot, 0, 0,
          renderScale = RenderScale, skin = skin)
  for team in sim.teams():
    for rot in 0 ..< SoldierRotations:
      for seg in RigSeg:
        if seg != rsHead:
          discard rigSegPixels(team, seg, rot, 0, 0, RenderScale)
      discard rigGunPixels(team, rot, RenderScale)
      discard rigSprayCanPixels(team, rot, RenderScale)
  discard boardTypeface()
  block:
    # Encode the map-band wire messages too: they are byte-identical for
    # every viewer, and the 13 MB copy + snappy pass per connection was the
    # other second on the certifier's first-message clock.
    var
      defs: seq[SpriteDefinition]
      packet: seq[uint8]
    sim.addMapBands(defs, packet)
