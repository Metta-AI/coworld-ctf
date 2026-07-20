import
  std/[algorithm, math, os, strutils],
  bitworld/pixelfonts, bitworld/profile, bitworld/spriteprotocol, bitworld/server,
  sim

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
  ## 40..(40+bands) sit clear of every other pool (layer ids stop at 12, the next
  ## sprite/object pools start at 100).
  MapBandSpriteBase = 30
  MapBandObjectBase = 40
  MapBandHeight = 96          ## px rows per band — 659/96 ≈ 7 bands, each well
                              ## under 200 KB compressed (far below the 1 MiB cap).
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
  FlagBannerW = 20             ## px width of the carried heart-gem sprite (square).
  FlagBannerH = 20             ## px height of the carried heart-gem sprite (square).
  PlantedFlagScale = 3         ## the HOME heart is drawn this many x bigger so it
                               ## reads as a real objective on the 96px pedestal.
  PlantedFlagW = FlagBannerW * PlantedFlagScale
  PlantedFlagH = FlagBannerH * PlantedFlagScale
  PlantedFlagSpriteBase = 704  ## scaled home-heart sprites: 704 red, 705 blue.
  GameOverIconSpriteBase = 706 ## compact roster-chip soldiers: 706 red, 707 blue.
  GameOverIconSize = 14        ## roster chip footprint (fits the game-over row).
  FlagAuraSpriteBase = 702     ## carrier-glow sprites: 702 red-flag halo, 703 blue-flag halo.
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
  ## 4100..4115 and object ids 19520..19521 sit clear of every other pool.
  EndzoneFadeSpriteBase = 4100 ## per-(team, stage) fade crops: 4100 +
                               ## ord(team)*GlowFadeStages + stage → 4100..4115.
                               ## Every stage owns an id so the crops can be
                               ## pre-shipped once per connection and the
                               ## event-time ramp is a pure object remap (bytes
                               ## ≈ 0) instead of a ~200 KB sprite resend per
                               ## frame — the burst that stalled WAN replay
                               ## viewers.
  EndzoneFadeObjectBase = 19520  ## one strip overlay per team.
  EndzonePrewarmEveryFrames = 4  ## drip one fade crop every N frames after
                                 ## connect (~1.2 Mbps for ~2.4 s) instead of
                                 ## dumping all 14 at once.
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
  PaintBombPickupSize = 22       ## px footprint of a corner pickup orb.
  PaintBombAirSize = 16          ## px footprint of the airborne orb.
  PaintBombCarrySize = 10        ## px footprint of the carried marker.
  ThrowTargetSize = 15           ## px diameter of the throw-target ring (blast-sized).
  BlastSize = 84                 ## px footprint of the landing splat (~2x GrenadeBlastRadius).
  BlastStages = 4                ## landing-splat fade stages across BlastFxTicks.
  PaintBombPickupObjectBase = 19300  ## corner pickups: 19300..19303 (four corners).
  MedKitSpriteId = 1400          ## center med kit pickup (native size);
                                 ## 845 collided with red blast stage 1
                                 ## (BlastSpriteBase 844..847).
  MedKitSize = 26                ## px footprint of a med kit pickup.
  MedKitObjectBase = 19600       ## center med kits: 19600..19601.
  ShieldSpriteId = 1420          ## endzone shield pickup (native size).
  ShieldCarrySpriteId = 1421     ## the "shield carried" marker over a carrier.
  ShieldSize = 26                ## px footprint of an endzone shield pickup.
  ShieldCarrySize = 12           ## px footprint of the carried shield marker.
  ShieldObjectBase = 19602       ## endzone shields: 19602..19603.
  ShieldCarryObjectBase = 19620  ## carried shield markers: one per player.
  SwordPickupSpriteId = 2000
  SwordCarrySpriteId = 2001
  SwordSwipeSpriteBase = 2002
  SwordSwipeStages = 4
  SwordPickupSize = 20
  SwordCarrySize = 10
  SwordSwipeSize = 2 * SwordRange
  SwordPickupObjectBase = 19640
  SwordCarryObjectBase = 19660
  SwordSwipeObjectBase = 19700
  SwordMaxSwipes = 16
  RotDiamondSpriteBase = 1401    ## spinning diamond frames: 1401..1416;
                                 ## 850 collided with CorpseSpriteBase.
  RotDiamondObjectBase = 19610   ## spinning center diamonds: 19610..19617;
                                 ## 19360 collided with PaintBombCarryObjectBase.
  PaintBombAirObjectBase = 19320     ## airborne orbs: one per in-flight grenade.
  PaintBombCarryObjectBase = 19360   ## carried markers: one per player.
  ThrowTargetObjectBase = 19400      ## charge rings: one per player.
  BlastObjectBase = 19440            ## blast flashes: one per recent blast.
  ShoutSpriteBase = 22000      ## speech-bubble sprites: one per live shout
                               ## (content-keyed, so unique per shout, clear
                               ## of the fog runs at 21000 and map markers at
                               ## 20000).
  ShoutObjectBase = 19480      ## speech-bubble object pool: one per live shout.
  ShoutMaxCount = 16           ## most bubbles drawn at once (one per player).
  ShoutBubbleZ = 30003         ## just above the name label (30002), so a shout
                               ## reads over the crowd but under the HUD text.
  ShoutPadX = 4                ## px of paper around the text, left and right.
  ShoutPadY = 3                ## px of paper above and below the text.
  ShoutTailH = 4               ## px tail dropping from the pill toward the head.
  ShoutFloat = 13              ## px the tail tip floats above the shouter's head.
  GrenadeMaxAirborne = 16      ## most in-flight orbs drawn at once.
  GrenadeMaxBlasts = 16        ## most blast flashes drawn at once.
  SoundRingSpriteId = 830      ## the shot "sound" ring sprite.
  SoundRingObjectBase = 19100  ## sound ring object-id pool (per recent shot).
  SoundRingSize = 12           ## px diameter of the sound ring.
  SoundRingJitter = 20         ## max px the ring strays from the true muzzle.
  ## A hitscan shot's whole beam appears at once, so the tracer can't literally
  ## move — but it draws as a COMET (the shape that reads as a fired projectile
  ## and is easiest to follow, per ux.replay research): a bright paintball HEAD
  ## at the impact end with a thin trail fading behind it back toward the
  ## shooter, plus a small muzzle flash marking who fired. The eye locks onto
  ## the head and reads the shot's direction from the fade — never a fat tube.
  TracerStages = 4             ## age fade stages (protocol has no per-object alpha).
  TrailBuckets = 6             ## along-beam opacity steps baked into the trail dots.
  TrailFalloff = 1.6           ## trail brightness = t^this (t: 0 muzzle → 1 impact).
  TrailMinAlpha = 0.06         ## drop trail dots fainter than this (trims the tail).
  TracerDotSpriteBase = 900    ## trail dots keyed color×stage×bucket: 900..1283.
  TracerDotObjectBase = 24000  ## tracer trail object-id pool (above the fog pool).
  TracerDotSize = 4            ## a THIN trail — ~1/4 a 16px soldier, never a tube.
  TracerDotSpacing = 3         ## px between sampled blobs; < size so they overlap
                               ## into one continuous thin trail, not a dotted line.
  TracerMaxShots = 16          ## most tracers drawn at once (one per shooter).
  TracerDotsPerShot = GunRange div TracerDotSpacing + 4  ## dots per full-range shot, plus slack.
  TracerMaxDots = TracerMaxShots * TracerDotsPerShot  ## 6992 ids: 24000..30991.
  MuzzleBloomSpriteBase = 1290 ## per-fade-stage muzzle flash sprites: 1290..1293.
  MuzzleBloomObjectBase = 16800  ## one flash per drawn shot: 16800..16815.
  MuzzleBloomSize = 7          ## a small colorless flash marking the shooter.
  TracerHeadSpriteBase = 1300  ## per color-and-fade-stage leading heads: 1300..1363.
  TracerHeadObjectBase = 16820  ## one leading head per drawn shot: 16820..16835.
  TracerHeadSize = 6           ## the bright leading paintball at the impact end.
  SplatterSpriteBase = 16000   ## per color-and-fade-stage splatter sprites: 16000..16063.
  SplatterObjectBase = 17000   ## splatter object-id pool base, above the tracer ids.
  SplatterSize = 13
  SplatterStages = 4           ## fade stages across SplatterFxTicks.
  SplatterMaxCount = 32        ## most splatters drawn at once.
  HitSpriteBase = 16100        ## per-color-and-stage hit-splat sprites: 16100..16163.
  HitSplatSize = 21            ## on-hit paint-splat canvas (~1.3x a 16px player).
  HitSplatCoreR = 6.0          ## px radius of the splat's main wet blob.
  DamagePopSpriteBase = 31000  ## floating "-N" damage-number sprites keyed
                               ## color×amount×stage: 31000..31127 (above tracers).
  DamagePopObjectBase = 31200  ## one drawn damage pop per object: 31200..31215.
  DamagePopStages = 4          ## alpha fade stages across DamageFxTicks.
  DamagePopMaxCount = 16       ## most floating numbers drawn at once.
  DamagePopMaxAmount = 2       ## highest -N shown (a grenade removes GrenadeDamage=2).
  DamagePopRisePx = 11         ## px the number floats upward over its full life.
  DamagePopZ = 30006           ## drawn above players, HP bars and name tags.
  AimDotSpriteBase = 780       ## per-color aim indicator dot sprites: 780..795.
  AimDotObjectBase = 18000     ## aim dot object-id pool: 18000..18063.
  AimDotSize = 2
  AimDotsPerPlayer = 4         ## dots along each player's aim line.
  AimDotStart = 5              ## px from the player center to the first dot.
  AimDotSpacing = 3            ## px between aim dots (line reaches ~14px out).
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
  ## Sprites: team flags 700..701 (FlagSpriteBase), hp pips 820+, tracer
  ## dots 900..963 (color×fade-stage), muzzle blooms 964..967 (stage), tracer
  ## heads 968..1031 (color×stage), aim dots 780..795, self markers 5100..5101,
  ## team score text 12100..12101, splatters 16000..16063, fog runs 21000..21155
  ## (one per run width in cells), map markers 20000. Objects: flags 6500..6501
  ## (map view) / 5009..5010 (player view), team score text 9600..9601,
  ## muzzle blooms 16800..16815, tracer heads 16820..16835, splatters
  ## 17000..17031, aim dots 18000..18063, map markers 20000, fog runs
  ## 21000..23047, tracer dots 24000..29263.
  SpritePlayerFireSpriteId = 5000
  SpritePlayerFireShadowSpriteId = 5001
  SpritePlayerRemainingSpriteId = 5003
  SpritePlayerInterstitialSpriteId = 5006
  SpritePlayerWalkabilitySpriteId = 5007
  SpritePlayerInterstitialObjectId = 5006
  SpritePlayerRemainingObjectId = 5008
  SpritePlayerFlagObjectBase = 5009  ## 5009 red flag, 5010 blue flag.
  SpritePlayerSelfSpriteBase = 5100  ## white-outlined self soldier, one per aim
                                     ## rotation: 5100..5115 (SoldierRotations).
  CorpseSpriteBase = 1500      ## grey dead-soldier sprites, one per team×rot
                               ## (1500..1531): a corpse must never read as a
                               ## live soldier for a label-scanning ghost
                               ## viewer. Moved off 850: that range overlapped
                               ## the blue paint-blast sprites (868..871).
  FlagObjectBase = 6500        ## 6500 red flag, 6501 blue flag.
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
  TeamScoreSpriteBase = 12100  ## 12100 red text, 12101 blue text.
  TeamScoreObjectBase = 9600   ## 9600 red text, 9601 blue text.
  MapMarkerSpriteBase = 20000
  MapMarkerObjectBase = 20000
  MapMarkerZ = -32767
  ProtocolTextSpriteBase = 9000
  ProtocolTextObjectBase = 9000
  ProtocolTextZ = 30010
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

type
  SpriteDefinition = ref object
    spriteId: int
    width: int
    height: int
    label: string

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
    broadcastHud*: bool          ## viewer opted into the JSON chrome channel.
    momentumSent*: bool          ## full lives-lead series already sent to this viewer.
    povSelectPending*: int       ## POV slot requested by a `v:<slot>` command.
    endzoneFade*: array[Team, int]  ## per-team endzone glow crossfade stage (0
                                 ## = full glow / heart home, GlowFadeStages-1 =
                                 ## dark / heart taken); ramped ±1 per frame.
    endzonePrewarmFrames*: int   ## frames seen since connect, used to drip the
                                 ## endzone fade crops to this viewer up front.
    spriteDefs: seq[SpriteDefinition]

  PlayerViewerState* = ref object
    initialized*: bool
    objectIds*: seq[int]
    spriteDefs: seq[SpriteDefinition]

  ProtocolTextItem = ref object
    spriteId: int
    objectId: int
    x, y, z: int
    color: uint8
    struck: bool
    label: string
    lines: seq[string]

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

proc endzoneStripRange(gameMap: CtfMap, team: Team): tuple[x0, x1: int] =
  ## The inclusive x span of one team's endzone column, full map height. It
  ## covers BOTH the crack-glow/capture-line column (captureZoneXRange) AND the
  ## flag-home pedestal footprint, which pokes ~28px past the capture line on the
  ## inner side — so the crossfade dims the pedestal disc too, with no lit sliver
  ## left behind. Outside the glow band the hot and cold maps are identical, so
  ## widening the strip is a visual no-op except over the pedestal.
  let pedHalf = PedestalCoverSize div 2
  case team
  of Red:
    (0, max(gameMap.teamHomeX(Red) + CaptureZoneWidth div 2,
            gameMap.teamHomeX(Red) + pedHalf))
  of Blue:
    (min(gameMap.teamHomeX(Blue) - CaptureZoneWidth div 2,
         gameMap.teamHomeX(Blue) - pedHalf), MapWidth - 1)

proc endzoneDiffBox(sim: SimServer, team: Team): tuple[x0, y0, x1, y1: int] =
  ## Returns the bounding box (map coords, inclusive) of the pixels inside one
  ## team's endzone column that differ between the baked-glow map and the cold
  ## glow-free map — the crack glow, capture line, and pedestal disc. Everything
  ## else in the column is identical at every crossfade stage, so the fade
  ## overlay never needs to ship it. Computed once per team and cached.
  if EndzoneDiffBoxReady[team]:
    return EndzoneDiffBox[team]
  if EndzoneColdRgba.len != MapWidth * MapHeight * 4:
    EndzoneColdRgba = coldEndzoneMapRgba(sim.gameMap)
  let (sx0, sx1) = sim.gameMap.endzoneStripRange(team)
  result = (x0: sx1 + 1, y0: MapHeight, x1: sx0 - 1, y1: -1)
  for y in 0 ..< MapHeight:
    for x in sx0 .. sx1:
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
  if EndzoneStripCache[team][s].len == result.w * result.h * 4:
    result.pixels = EndzoneStripCache[team][s]
    return
  result.pixels = newSeq[uint8](result.w * result.h * 4)
  # t: 0 at stage 0 (all hot/baked glow), 1 at the last stage (all cold).
  let t = s.float / float(GlowFadeStages - 1)
  for y in 0 ..< result.h:
    for x in 0 ..< result.w:
      let
        src = mapIndex(box.x0 + x, box.y0 + y) * 4
        dst = (y * result.w + x) * 4
      if sim.mapRgba[src] == EndzoneColdRgba[src] and
          sim.mapRgba[src + 1] == EndzoneColdRgba[src + 1] and
          sim.mapRgba[src + 2] == EndzoneColdRgba[src + 2]:
        continue                       # identical to the map below: transparent.
      for c in 0 .. 2:
        let
          hot = sim.mapRgba[src + c].float
          cold = EndzoneColdRgba[src + c].float
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

proc initPlayerViewerState*(): PlayerViewerState =
  ## Returns the default state for one sprite player viewer.
  new(result)

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

proc crewSpriteIsSolid(sprite: CrewSprite, x, y: int, flipH: bool): bool =
  ## Returns true when one crew sprite pixel has visible alpha.
  let srcX = if flipH: sprite.width - 1 - x else: x
  if srcX < 0 or srcX >= sprite.width or y < 0 or y >= sprite.height:
    return false
  sprite.rgba[sprite.crewSpriteOffset(srcX, y) + 3] >= 20'u8

proc putCrewPixel(
  pixels: var seq[uint8],
  pixelIndex: int,
  sprite: CrewSprite,
  x, y: int,
  tint: uint8
) =
  ## Writes one selectively tinted true-color crew pixel.
  let
    sourceOffset = sprite.crewSpriteOffset(x, y)
    r = sprite.rgba[sourceOffset]
    g = sprite.rgba[sourceOffset + 1]
    b = sprite.rgba[sourceOffset + 2]
    a = sprite.rgba[sourceOffset + 3]
  if a < 20'u8:
    return
  if crewPixelIsTint(r, g, b, a):
    pixels.putRgbaPixel(pixelIndex, tint)
  elif crewPixelIsShade(r, g, b, a):
    pixels.putRgbaPixel(pixelIndex, ShadowMap[tint and 0x0f])
  else:
    pixels.putRawRgbaPixel(pixelIndex, r, g, b, a)

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

proc crewSpriteForSlot(sim: SimServer, slotId: int): CrewSprite =
  ## Returns the crew sprite assigned to one player slot.
  sim.crewSprites[crewVariantIndex(slotId)]

proc soldierPlayerSpriteId(team: Team, rot: int): int =
  ## Sprite id for one living soldier at aim rotation `rot`. The two team
  ## masters need SoldierRotations ids each; they sit in the existing player
  ## sprite pool (PlayerSpriteBase..), which reserved 16 ids per palette color.
  PlayerSpriteBase + ord(team) * SoldierRotations + rot

proc selectedSoldierPlayerSpriteId(team: Team, rot: int): int =
  ## Selected (outlined) soldier sprite id at aim rotation `rot`.
  SelectedPlayerSpriteBase + ord(team) * SoldierRotations + rot

proc corpseSoldierSpriteId(team: Team, rot: int): int =
  ## Sprite id for a dead soldier (grey corpse) at rotation `rot`. Sits in the
  ## free 850..881 window just above the selected-soldier pool (800..831).
  CorpseSpriteBase + ord(team) * SoldierRotations + rot

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
  label: string = "",
  changed = false
) {.measure.} =
  ## Appends a sprite definition when metadata or caller dirtiness changed.
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
  else:
    defs.add SpriteDefinition(
      spriteId: spriteId,
      width: width,
      height: height,
      label: label
    )
  packet.addSprite(spriteId, width, height, pixels, label)

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
      if item.text == "hud:on":
        state.broadcastHud = true
      elif item.text == "hud:off":
        state.broadcastHud = false
        state.momentumSent = false
      elif item.text.startsWith("s:"):
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
    of SpriteClientMouseMoveMessage, SpriteClientMouseButtonMessage:
      discard

proc isSolid(sprite: Sprite, x, y: int, flipH: bool): bool =
  let srcX = if flipH: sprite.width - 1 - x else: x
  if srcX < 0 or srcX >= sprite.width or y < 0 or y >= sprite.height:
    return false
  sprite.pixels[sprite.spriteIndex(srcX, y)] != TransparentColorIndex

proc buildSpriteProtocolActorSprite(
  sprite: Sprite,
  tint: uint8,
  flipH: bool,
  selected: bool = false
): seq[uint8] {.measure.} =
  ## Builds a tinted actor sprite for the global viewer.
  let
    outWidth = sprite.width + 2
    outHeight = sprite.height + 2
    outline = if selected: 8'u8 else: OutlineColor
  result = newRgbaPixels(outWidth, outHeight)

  proc outIndex(x, y: int): int =
    y * outWidth + x

  if selected:
    for y in -1 .. sprite.height:
      for x in -1 .. sprite.width:
        if sprite.isSolid(x, y, flipH):
          continue
        let adjacent =
          sprite.isSolid(x - 1, y, flipH) or
          sprite.isSolid(x + 1, y, flipH) or
          sprite.isSolid(x, y - 1, flipH) or
          sprite.isSolid(x, y + 1, flipH)
        if adjacent:
          result.putRgbaPixel(outIndex(x + 1, y + 1), outline)

  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let srcX = if flipH: sprite.width - 1 - x else: x
      let colorIndex = sprite.pixels[sprite.spriteIndex(srcX, y)]
      if colorIndex == TransparentColorIndex:
        continue
      result.putRgbaPixel(
        outIndex(x + 1, y + 1),
        actorColor(colorIndex, tint)
      )

proc buildCrewProtocolActorSprite(
  sprite: CrewSprite,
  tint: uint8,
  flipH: bool,
  selected: bool = false
): seq[uint8] {.measure.} =
  ## Builds a selectively tinted true-color crew sprite.
  let
    outWidth = sprite.width + 2
    outHeight = sprite.height + 2
    outline = if selected: 8'u8 else: OutlineColor
  result = newRgbaPixels(outWidth, outHeight)

  proc outIndex(x, y: int): int =
    y * outWidth + x

  if selected:
    for y in -1 .. sprite.height:
      for x in -1 .. sprite.width:
        if sprite.crewSpriteIsSolid(x, y, flipH):
          continue
        let adjacent =
          sprite.crewSpriteIsSolid(x - 1, y, flipH) or
          sprite.crewSpriteIsSolid(x + 1, y, flipH) or
          sprite.crewSpriteIsSolid(x, y - 1, flipH) or
          sprite.crewSpriteIsSolid(x, y + 1, flipH)
        if adjacent:
          result.putRgbaPixel(outIndex(x + 1, y + 1), outline)

  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let srcX = if flipH: sprite.width - 1 - x else: x
      result.putCrewPixel(
        outIndex(x + 1, y + 1),
        sprite,
        srcX,
        y,
        tint
      )

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

proc soundRingOffset(shot: ShotFx): (int, int) =
  ## A deterministic pseudo-random offset for one shot's sound ring: stable
  ## across frames, viewers, and replays, but never the exact muzzle spot.
  var h = 0x9E3779B9'u32
  h = (h xor uint32(shot.firedTick)) * 0x85EBCA6B'u32
  h = (h xor uint32(shot.x0)) * 0xC2B2AE35'u32
  h = (h xor uint32(shot.y0)) * 0x27D4EB2F'u32
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

proc buildSwordIcon(size: int): seq[uint8] {.measure.} =
  ## Builds a small, readable sword icon for pickups and carried markers.
  result = newRgbaPixels(size, size)
  let center = float(size - 1) / 2
  for y in 0 ..< size:
    for x in 0 ..< size:
      let
        dx = float(x) - center
        dy = float(y) - center
        blade = abs(dx + dy) < 1.5 and dx < center * 0.65
        guard = abs(dx - dy) < 1.5 and abs(dx) < center * 0.45
        handle = abs(dx + dy) < 1.6 and dx > center * 0.35
      if blade:
        result.putRawRgbaPixel(
          y * size + x, 230, 238, 242, 235
        )
      elif guard:
        result.putRawRgbaPixel(
          y * size + x, 247, 190, 70, 245
        )
      elif handle:
        result.putRawRgbaPixel(
          y * size + x, 92, 56, 36, 245
        )

proc loadSwordSprite(size: int): seq[uint8] =
  ## Returns the sword icon at its requested protocol footprint.
  buildSwordIcon(size)

proc buildSwordSwipeSprite(colorIndex, stage: int): seq[uint8] {.measure.} =
  ## Builds a team-colored crescent slash with a short fade.
  result = newRgbaPixels(SwordSwipeSize, SwordSwipeSize)
  let
    base = Palette[PlayerColors[colorIndex and 0x0f] and 0x0f]
    center = float(SwordSwipeSize - 1) / 2
    radius = float(SwordRange) * 0.82
    fade = 1.0 - 0.72 * (stage.float /
      float(max(1, SwordSwipeStages - 1)))
  for y in 0 ..< SwordSwipeSize:
    for x in 0 ..< SwordSwipeSize:
      let
        dx = float(x) - center
        dy = float(y) - center
        distance = sqrt(dx * dx + dy * dy)
        angle = arctan2(-dy, dx)
        inArc = angle >= -PI / 4 and angle <= PI / 4
        onRim = abs(distance - radius) <= 1.8
      if inArc and onRim:
        result.putRawRgbaPixel(
          y * SwordSwipeSize + x,
          uint8((base.r.int + 255) div 2),
          uint8((base.g.int + 255) div 2),
          uint8((base.b.int + 255) div 2),
          uint8(clamp(255.0 * fade, 0.0, 255.0))
        )

proc buildBlastSprite(colorIndex, stage: int): seq[uint8] {.measure.} =
  ## The grenade landing: a BIG paint splat in the THROWER's team color — a
  ## paint-bomb bursts, it doesn't flash white. Same wet-paintball language as
  ## the on-hit splat (buildHitSparkSprite) but blast-sized (~2x the blast
  ## radius), with a ragged rim of flung droplets so it reads as a burst, a
  ## bright wet-sheen core, and a deep same-hue contour so it pops off the dark
  ## floor. Alpha-only fade across the short blast life keeps the team color
  ## vivid (never muddies toward brown) so a landing is unmistakably one team's.
  result = newRgbaPixels(BlastSize, BlastSize)
  let
    base = Palette[PlayerColors[colorIndex and 0x0f] and 0x0f]
    paintR = uint8((base.r.int * 3 + 255) div 4)
    paintG = uint8((base.g.int * 3 + 255) div 4)
    paintB = uint8((base.b.int * 3 + 255) div 4)
    sheenR = uint8((base.r.int + 255 * 3) div 4)
    sheenG = uint8((base.g.int + 255 * 3) div 4)
    sheenB = uint8((base.b.int + 255 * 3) div 4)
    edgeR = uint8(base.r.int * 2 div 5)
    edgeG = uint8(base.g.int * 2 div 5)
    edgeB = uint8(base.b.int * 2 div 5)
    c = float(BlastSize - 1) / 2
    coreR = float(BlastSize) * 0.30            # main wet blob radius
    # Alpha-only fade: full at stage 0, thinning to a faint stain by the last.
    fade = 1.0 - 0.72 * (stage.float / float(max(1, BlastStages - 1)))
  # Ten flung droplets ring the core (fixed offsets → deterministic sprite),
  # scaled to the big canvas so the burst throws paint well past the blob.
  const droplets = [(-30, -10, 7.0), (26, -22, 6.0), (33, 14, 7.5),
                    (-22, 26, 6.5), (8, 33, 5.5), (-33, 6, 5.0),
                    (18, 30, 5.0), (-14, -30, 5.5), (31, -3, 5.0),
                    (-4, -34, 4.5)]
  for y in 0 ..< BlastSize:
    for x in 0 ..< BlastSize:
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
            ddx = float(x) - (c + ox.float)
            ddy = float(y) - (c + oy.float)
          if ddx * ddx + ddy * ddy <= dr * dr:
            inShape = true
            onEdge = ddx * ddx + ddy * ddy > (dr - 2.0) * (dr - 2.0)
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
        y * BlastSize + x, r, g, b,
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
    base = Palette[PlayerColors[colorIndex and 0x0f] and 0x0f]
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

proc buildTracerHeadSprite(colorIndex, stage: int): seq[uint8] {.measure.} =
  ## Builds the bright LEADING paintball at a shot's IMPACT end — the comet's
  ## head, the eye-anchor. Hotter than a trail dot (a wide white-hot core over a
  ## team-color rim) so it's the brightest thing on the beam and clearly points
  ## at the target it struck. Alpha fades by age stage like the trail, so head
  ## and tail die together.
  result = newRgbaPixels(TracerHeadSize, TracerHeadSize)
  let
    base = Palette[PlayerColors[colorIndex and 0x0f] and 0x0f]
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

proc buildAimDotSprite(colorIndex: int): seq[uint8] {.measure.} =
  ## Builds one aim-indicator dot sprite: the player's palette color mixed
  ## halfway toward white, matching the tracer-dot styling.
  result = newRgbaPixels(AimDotSize, AimDotSize)
  let base = Palette[PlayerColors[colorIndex and 0x0f] and 0x0f]
  for i in 0 ..< AimDotSize * AimDotSize:
    result.putRawRgbaPixel(
      i,
      uint8((base.r.int + 255) div 2),
      uint8((base.g.int + 255) div 2),
      uint8((base.b.int + 255) div 2),
      255
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
    base = Palette[PlayerColors[colorIndex and 0x0f] and 0x0f]
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

proc buildDamagePopSprite(
  game: SimServer, colorIndex, amount, stage: int
): tuple[width, height: int, pixels: seq[uint8]] {.measure.} =
  ## Builds one floating "-N" damage number: a bright team-tinted numeral with
  ## a dark 1px contour so it pops off any floor, fading by ALPHA across the
  ## pop's short life (the protocol has no per-object alpha). Cosmetic only,
  ## never in gameHash. The tint uses the VICTIM's team color so it reads as
  ## that player's loss, lightened toward white so the number stays legible.
  let
    font = game.asciiSprites
    text = "-" & $amount
    textW = max(1, font.textWidth(text))
    glyphH = max(1, font.height)
    width = textW + 2          # 1px contour margin on each side
    height = glyphH + 2
    base = Palette[PlayerColors[colorIndex and 0x0f] and 0x0f]
    inkR = uint8((base.r.int + 255 * 2) div 3)
    inkG = uint8((base.g.int + 255 * 2) div 3)
    inkB = uint8((base.b.int + 255 * 2) div 3)
    # Alpha-only fade: full at stage 0, nearly gone by the last stage.
    fade = 1.0 - 0.85 * (stage.float / float(max(1, DamagePopStages - 1)))
    alpha = uint8(clamp(255.0 * fade, 0.0, 255.0))
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

proc addMapBands(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  packet: var seq[uint8]
) {.measure.} =
  ## Emits the static arena map as a stack of horizontal bands instead of one
  ## giant sprite. Each band is a full-width crop `MapBandHeight` rows tall,
  ## placed at its own y-offset on the map layer — the client composites them
  ## into one seamless image (it blits every object at obj.x/obj.y, so adjacent
  ## bands tile with no seam). This keeps the map pixel-identical while ensuring
  ## no single sprite message approaches the hosted 1 MiB WS frame cap. Like the
  ## old single map object, bands are emitted once at init and never tracked in
  ## objectIds, so the per-frame delete diff leaves them on the client forever.
  let
    w = sim.gameMap.width
    h = sim.gameMap.height
    mapPixels = sim.buildMapSpritePixels()
  var band = 0
  var y0 = 0
  while y0 < h:
    let bandH = min(MapBandHeight, h - y0)
    var bandPixels = newSeq[uint8](w * bandH * 4)
    copyMem(bandPixels[0].addr, mapPixels[y0 * w * 4].unsafeAddr, w * bandH * 4)
    let
      spriteId = MapBandSpriteBase + band
      objectId = MapBandObjectBase + band
    packet.addSpriteChanged(
      spriteDefs, spriteId, w, bandH, bandPixels, "map band " & $band)
    packet.addObject(objectId, 0, y0, low(int16), MapLayerId, spriteId)
    inc band
    y0 += bandH

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
  packet.addSpriteChanged(
    spriteDefs,
    spriteId,
    width,
    height,
    newRgbaPixels(width, height),
    label
  )
  packet.addObject(objectId, x, y, MapMarkerZ, MapLayerId, spriteId)

proc addMapMarkers(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  packet: var seq[uint8]
) {.measure.} =
  ## Adds invisible room markers for sprite agents.
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
      packet.addSpriteChanged(
        spriteDefs,
        spriteId,
        run.width * FovCellSize,
        FovCellSize,
        buildFogRunSprite(run.width),
        "fog"
      )
    let objectId = FogObjectBase + runIndex
    currentIds.add(objectId)
    packet.addObject(
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
  struck = false
): tuple[width, height: int, pixels: seq[uint8]] {.measure.} =
  ## Builds a transparent multi-line text sprite.
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

proc buildShoutBubble(
  game: SimServer,
  team: Team,
  text: string
): tuple[width, height: int, pixels: seq[uint8]] {.measure.} =
  ## A kid-friendly comic speech bubble for one shout: dark ink on a cream
  ## "paper" pill with rounded corners, a chunky team-colored outline, and a
  ## little tail pointing down at the shouter. Drawn with the chunky 9px shout
  ## font (not the 6px tiny5 HUD font) so it reads at full desktop size, and
  ## in-world with the rest of the pixel art — never as an HD overlay.
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
  let
    redText = "RED " & $kills[Red] & "/" & $deaths[Red]
    blueText = "BLUE " & $kills[Blue] & "/" & $deaths[Blue]
    red = sim.buildSpriteProtocolTextSprite([redText], teamColor(Red))
    blue = sim.buildSpriteProtocolTextSprite([blueText], teamColor(Blue))
    totalWidth = red.width + TeamScoreGap + blue.width
    startX = max(0, (TeamScoreWidth - totalWidth) div 2)
  packet.addSpriteChanged(
    spriteDefs,
    TeamScoreSpriteBase,
    red.width,
    red.height,
    red.pixels,
    "team score " & redText,
    changed = true
  )
  packet.addSpriteChanged(
    spriteDefs,
    TeamScoreSpriteBase + 1,
    blue.width,
    blue.height,
    blue.pixels,
    "team score " & blueText,
    changed = true
  )
  currentIds.add(TeamScoreObjectBase)
  currentIds.add(TeamScoreObjectBase + 1)
  packet.addObject(
    TeamScoreObjectBase,
    startX,
    1,
    0,
    TeamScoreLayerId,
    TeamScoreSpriteBase
  )
  packet.addObject(
    TeamScoreObjectBase + 1,
    startX + red.width + TeamScoreGap,
    1,
    0,
    TeamScoreLayerId,
    TeamScoreSpriteBase + 1
  )

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
  case team
  of Red:
    "RED WINS"
  of Blue:
    "BLUE WINS"

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
        tag = if p.team == Red: "RED" else: "BLUE"
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
    packet.addObject(
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
  for team in Team:
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
    packet.addObject(
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
  loadHeartSprite(team, FlagBannerW)

proc buildPlantedFlagSprite(team: Team): seq[uint8] {.measure.} =
  ## The HOME heart-gem, loaded NATIVELY at the big pedestal footprint (not an
  ## upscale of the tiny carried sprite) so the hand-painted facets stay crisp.
  ## It reads as a real objective standing on the pedestal, not a thumbnail.
  loadHeartSprite(team, PlantedFlagW)

proc buildFlagAuraSprite(team: Team): seq[uint8] {.measure.} =
  ## Builds the soft carrier halo in the FLAG's team color: a feathered disc
  ## drawn UNDER the carrier so the flag-runner is the brightest, most-tracked
  ## figure on the board (TagPro / TF2 carrier-glow convention). A blue player
  ## carrying the red flag glows red. Semi-transparent so it tints the floor
  ## without hiding the runner.
  result = newRgbaPixels(FlagAuraSize, FlagAuraSize)
  let
    base = Palette[teamColor(team) and 0x0f]
    c = float(FlagAuraSize - 1) / 2
  for y in 0 ..< FlagAuraSize:
    for x in 0 ..< FlagAuraSize:
      let d = sqrt((float(x) - c) * (float(x) - c) + (float(y) - c) * (float(y) - c))
      if d > c:
        continue
      let alpha = uint8(min(150.0, 30.0 + 130.0 * (1.0 - d / c)))
      result.putRawRgbaPixel(
        y * FlagAuraSize + x,
        uint8((base.r.int + 255) div 2),
        uint8((base.g.int + 255) div 2),
        uint8((base.b.int + 255) div 2),
        alpha
      )

proc flagLabel(team: Team): string =
  ## Returns the observation label for one team's flag sprite.
  teamText(team) & " flag"

proc addFlagSprites(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  packet: var seq[uint8]
) {.measure.} =
  ## Adds both team banner sprites (carried + big planted) plus carrier halos.
  for team in Team:
    packet.addSpriteChanged(
      spriteDefs,
      FlagSpriteBase + ord(team),
      FlagBannerW,
      FlagBannerH,
      buildFlagBannerSprite(team),
      flagLabel(team)
    )
    packet.addSpriteChanged(
      spriteDefs,
      PlantedFlagSpriteBase + ord(team),
      PlantedFlagW,
      PlantedFlagH,
      buildPlantedFlagSprite(team),
      flagLabel(team) & " planted"
    )
    packet.addSpriteChanged(
      spriteDefs,
      FlagAuraSpriteBase + ord(team),
      FlagAuraSize,
      FlagAuraSize,
      buildFlagAuraSprite(team),
      flagLabel(team) & " carrier glow"
    )

proc soldierOutlined(pixels: seq[uint8], outline: uint8): seq[uint8] =
  ## Returns a copy of a rasterized soldier sprite with a 2px selected-outline:
  ## any transparent pixel within 2px of a solid one is painted the outline
  ## color. Matches the legacy selected-crew highlight, but on true-color art.
  result = pixels
  let
    n = SoldierCanvas * SoldierCanvas
    oc = Palette[outline and 0x0f]
  var solid = newSeq[bool](n)
  for i in 0 ..< n:
    solid[i] = pixels[i * 4 + 3] >= 64'u8
  for y in 0 ..< SoldierCanvas:
    for x in 0 ..< SoldierCanvas:
      let i = y * SoldierCanvas + x
      if solid[i]:
        continue
      var adjacent = false
      for dy in -2 .. 2:
        for dx in -2 .. 2:
          let nx = x + dx
          let ny = y + dy
          if nx < 0 or ny < 0 or nx >= SoldierCanvas or ny >= SoldierCanvas:
            continue
          if solid[ny * SoldierCanvas + nx]:
            adjacent = true
      if adjacent:
        result.putRawRgbaPixel(i, oc.r, oc.g, oc.b, oc.a)

proc soldierCorpse(pixels: seq[uint8]): seq[uint8] =
  ## Returns a copy of a soldier sprite recolored as a corpse: every solid
  ## pixel desaturates to grey (luma-weighted) and drops to ~55% opacity, so a
  ## body reads as fallen debris — never a live soldier — in the ghost view.
  result = pixels
  let n = SoldierCanvas * SoldierCanvas
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
  ## Adds the pre-rotated top-down soldier sprites used by both views: one
  ## SoldierRotations-step set per team, plus a selected-outlined set for the
  ## map view. Replaces the old flat 8-variant + horizontal-flip crew set — the
  ## soldier's held paintball gun now sweeps with the aim angle instead.
  for team in Team:
    let color = teamText(team)
    for rot in 0 ..< SoldierRotations:
      let
        pixels = soldierRotPixels(team, rot)
        side = if soldierFacingRight(rot): " right" else: " left"
      # The HD sprite keeps its full 16-step rotation for the VISUAL; the label
      # stays the documented `player <color> <side>` (RULES.md) so exact-match
      # label readers keep working. Distinct rotation ids may share a side label
      # — the client keys sprites by id, not label, so that is harmless.
      packet.addSpriteChanged(
        spriteDefs,
        soldierPlayerSpriteId(team, rot),
        SoldierCanvas,
        SoldierCanvas,
        pixels,
        "player " & color & side
      )
      # A grey desaturated corpse per rotation: the ghost view shows fallen
      # bodies, and the documented `corpse <color> <side>` label (RULES.md)
      # keeps a label-scanning policy from mistaking a body for a live enemy.
      packet.addSpriteChanged(
        spriteDefs,
        corpseSoldierSpriteId(team, rot),
        SoldierCanvas,
        SoldierCanvas,
        soldierCorpse(pixels),
        "corpse " & color & side
      )
      if selected:
        packet.addSpriteChanged(
          spriteDefs,
          selectedSoldierPlayerSpriteId(team, rot),
          SoldierCanvas,
          SoldierCanvas,
          soldierOutlined(pixels, 8'u8),
          "selected player " & color & side
        )

proc buildSpriteProtocolInit(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition]
): seq[uint8] {.measure.} =
  ## Builds the initial global viewer snapshot.
  result = @[]
  result.addU8(0x04)
  result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
  result.addViewport(MapLayerId, sim.gameMap.width, sim.gameMap.height)
  result.addLayer(TopLeftLayerId, TopLeftLayerType, UiLayerFlag)
  result.addViewport(TopLeftLayerId, ScoreboardWidth, ScoreboardHeight)
  result.addLayer(InterstitialLayerId, InterstitialLayerType, UiLayerFlag)
  result.addViewport(InterstitialLayerId, ScreenWidth, ScreenHeight)
  result.addLayer(BottomRightLayerId, BottomRightLayerType, UiLayerFlag)
  result.addViewport(BottomRightLayerId, ScreenWidth, ScreenHeight)
  result.addLayer(TeamScoreLayerId, TeamScoreLayerType, UiLayerFlag)
  result.addViewport(TeamScoreLayerId, TeamScoreWidth, TextLineHeight + 2)
  # The map rides as horizontal bands (see addMapBands): one 1.09 MB map sprite
  # is a single message over the hosted 1 MiB WS frame cap — banding keeps every
  # pixel while making each message a fraction of the cap.
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
    "walkability map"
  )
  sim.addFlagSprites(spriteDefs, result)
  result.addSpriteChanged(
    spriteDefs,
    SpritePlayerFireSpriteId,
    sim.flagSprite.width,
    sim.flagSprite.height,
    buildSpriteProtocolRawSprite(sim.flagSprite),
    "fire icon"
  )
  result.addSpriteChanged(
    spriteDefs,
    SpritePlayerFireShadowSpriteId,
    sim.flagSprite.width,
    sim.flagSprite.height,
    buildSpriteProtocolShadowSprite(sim.flagSprite),
    "fire icon cooldown"
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
    packet.addObject(
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
    packet.addObject(
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
  for team in Team:
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
  flagTeamOrd: int
): tuple[width, height: int, pixels: seq[uint8]] {.measure.} =
  ## Builds a carrier's overhead label: the name in the normal color, then a
  ## small flag marker in the carried flag's team color set NEXT TO the name (so
  ## it's obvious who has the flag and whose flag it is), not overlapping it.
  let
    name = playerLabelText(player)
    nameW = sim.asciiSprites.textWidth(name)
    gap = 2
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

proc spriteActorSpriteId(player: Player, selectedJoinOrder: int): int =
  ## Returns the sprite id for a player in the global viewer: the team soldier
  ## pre-rotated to the player's aim angle (the held gun sweeps with the aim).
  let
    rot = soldierRotIndex(player.aimBrads)
    selected = player.joinOrder == selectedJoinOrder
  if selected:
    selectedSoldierPlayerSpriteId(player.team, rot)
  else:
    soldierPlayerSpriteId(player.team, rot)

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
  packet: var seq[uint8],
  viewerIndex = -1
) {.measure.} =
  ## Places each shot's tracer from fixed object pools as a COMET: a small
  ## colorless muzzle flash at the origin (who fired), a thin team-color trail
  ## that fades back toward the shooter, and a bright leading paintball at the
  ## impact end (the eye-anchor pointing at the target). The along-beam fade is
  ## baked per trail dot via its bucket. The map view passes no viewer and shows
  ## every part; a player view passes its viewer index and only receives the
  ## parts crossing its vision (each part fov-gated at its own pixel).
  var
    nextDot = 0
    bucketDefined: array[TrailBuckets, bool]
  for shotIndex in 0 ..< min(sim.recentShots.len, TracerMaxShots):
    let shot = sim.recentShots[shotIndex]
    let
      colorIndex = playerColorIndex(shot.color)
      age = sim.tickCount - shot.firedTick
      stage = clamp(age * TracerStages div ShotFxTicks, 0, TracerStages - 1)
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
      if viewerIndex >= 0 and not sim.fovVisibleAt(viewerIndex, mx, my):
        continue
      let
        beamT = s / steps                 ## 0 at muzzle → 1 at impact.
        bucket = clamp(int(beamT * float(TrailBuckets)), 0, TrailBuckets - 1)
      if pow((bucket.float + 1.0) / float(TrailBuckets), TrailFalloff) < TrailMinAlpha:
        continue                          ## far-tail dot too faint to bother.
      let spriteId = tracerDotSpriteId(colorIndex, stage, bucket)
      if not bucketDefined[bucket]:
        bucketDefined[bucket] = true
        packet.addSpriteChanged(
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
      packet.addObject(
        objectId,
        mx - TracerDotSize div 2,
        my - TracerDotSize div 2,
        30005,
        MapLayerId,
        spriteId
      )
    # Muzzle bloom at the origin — the colorless flash that says "fired here".
    if viewerIndex < 0 or sim.fovVisibleAt(viewerIndex, shot.x0, shot.y0):
      let bloomSpriteId = MuzzleBloomSpriteBase + stage
      packet.addSpriteChanged(
        spriteDefs,
        bloomSpriteId,
        MuzzleBloomSize,
        MuzzleBloomSize,
        buildMuzzleBloomSprite(stage),
        "muzzle bloom stage " & $stage
      )
      let bloomId = MuzzleBloomObjectBase + shotIndex
      currentIds.add(bloomId)
      packet.addObject(
        bloomId,
        shot.x0 - MuzzleBloomSize div 2,
        shot.y0 - MuzzleBloomSize div 2,
        30006,
        MapLayerId,
        bloomSpriteId
      )
    # Leading head at the impact end — bright white-hot ball that says
    # "struck here", pointing the beam at its target.
    if viewerIndex < 0 or sim.fovVisibleAt(viewerIndex, shot.x1, shot.y1):
      let headSpriteId = tracerHeadSpriteId(colorIndex, stage)
      packet.addSpriteChanged(
        spriteDefs,
        headSpriteId,
        TracerHeadSize,
        TracerHeadSize,
        buildTracerHeadSprite(colorIndex, stage),
        "shot head " & playerColorName(colorIndex) & " stage " & $stage
      )
      let headId = TracerHeadObjectBase + shotIndex
      currentIds.add(headId)
      packet.addObject(
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

proc addSoundRings(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8],
  viewerIndex: int
) {.measure.} =
  ## Places a brief semi-transparent ring near the muzzle of every recent
  ## shot the viewer could NOT see: gunfire is audible through the fog. The
  ## ring is jittered per shot (soundRingOffset) so it reveals a
  ## neighborhood, never the exact spot; a shot you can see needs no ring.
  for shotIndex in 0 ..< min(sim.recentShots.len, TracerMaxShots):
    let shot = sim.recentShots[shotIndex]
    if sim.fovVisibleAt(viewerIndex, shot.x0, shot.y0):
      continue
    packet.addSpriteChanged(
      spriteDefs,
      SoundRingSpriteId,
      SoundRingSize,
      SoundRingSize,
      buildSoundRingSprite(),
      "shot sound"
    )
    let
      (dx, dy) = soundRingOffset(shot)
      objectId = SoundRingObjectBase + shotIndex
    currentIds.add(objectId)
    packet.addObject(
      objectId,
      shot.x0 + dx - SoundRingSize div 2,
      shot.y0 + dy - SoundRingSize div 2,
      30000,
      MapLayerId,
      SoundRingSpriteId
    )

proc addRotatingDiamonds(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8]
) {.measure.} =
  ## Draws the center diamonds as slowly spinning carved-stone sprites over
  ## the floor the art bake left under them. Map geometry is always visible
  ## (never fog-gated), and the halves spin in mirrored directions. The spin
  ## angle derives from tickCount, so replays and every viewer agree; the
  ## collision masks still hold the static diamond — decoration only.
  for i in 0 ..< AnimatedDiamonds.len:
    let
      spot = AnimatedDiamonds[i]
      dir = if spot.cx < MapWidth div 2: 1 else: -1
      step = sim.tickCount div DiamondSpinTicksPerFrame
      frame = ((step * dir) mod DiamondSpinFrames + DiamondSpinFrames) mod
        DiamondSpinFrames
      (size, pixels) = rotatingDiamondPixels(spot.radius, frame)
      spriteId = RotDiamondSpriteBase + frame
    if spriteDefs.spriteDefinitionIndex(spriteId) < 0:
      packet.addSpriteChanged(
        spriteDefs, spriteId, size, size, pixels, "diamond"
      )
    let objectId = RotDiamondObjectBase + i
    currentIds.add(objectId)
    packet.addObject(
      objectId,
      spot.cx - size div 2,
      spot.cy - size div 2,
      spot.cy, MapLayerId, spriteId
    )

proc addSwords(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8],
  viewerIndex = -1
) {.measure.} =
  ## Places side-center sword pickups and carried markers.
  for i in 0 ..< sim.swordSpawns.len:
    let spawn = sim.swordSpawns[i]
    if not spawn.present:
      continue
    if viewerIndex >= 0 and not sim.fovVisibleAt(viewerIndex, spawn.x, spawn.y):
      continue
    if spriteDefs.spriteDefinitionIndex(SwordPickupSpriteId) < 0:
      packet.addSpriteChanged(
        spriteDefs,
        SwordPickupSpriteId,
        SwordPickupSize,
        SwordPickupSize,
        loadSwordSprite(SwordPickupSize),
        "sword"
      )
    let objectId = SwordPickupObjectBase + i
    currentIds.add(objectId)
    packet.addObject(
      objectId,
      spawn.x - SwordPickupSize div 2,
      spawn.y - SwordPickupSize div 2,
      spawn.y,
      MapLayerId,
      SwordPickupSpriteId
    )

  for i in 0 ..< sim.players.len:
    let player = sim.players[i]
    if not player.alive or not player.hasSword:
      continue
    if viewerIndex >= 0 and i != viewerIndex and
        not sim.playerVisibleTo(viewerIndex, i):
      continue
    if spriteDefs.spriteDefinitionIndex(SwordCarrySpriteId) < 0:
      packet.addSpriteChanged(
        spriteDefs,
        SwordCarrySpriteId,
        SwordCarrySize,
        SwordCarrySize,
        loadSwordSprite(SwordCarrySize),
        "sword carried"
      )
    let objectId = SwordCarryObjectBase + i
    currentIds.add(objectId)
    packet.addObject(
      objectId,
      player.x + CollisionW div 2 + HpBarWidth div 2 -
        SwordCarrySize div 2,
      player.overheadAnchorY() - OverheadYOffset - SwordCarrySize,
      30006,
      MapLayerId,
      SwordCarrySpriteId
    )

proc addSwordSwipes(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8],
  viewerIndex = -1
) {.measure.} =
  ## Places fading sword swipe arcs in front of their attackers.
  for i in 0 ..< min(sim.swordSwipes.len, SwordMaxSwipes):
    let swipe = sim.swordSwipes[i]
    if viewerIndex >= 0 and
        not sim.fovVisibleAt(viewerIndex, swipe.x, swipe.y):
      continue
    let
      age = max(0, sim.tickCount - swipe.tick)
      stage = clamp(age * SwordSwipeStages div SwordFxTicks,
        0, SwordSwipeStages - 1)
      colorIndex = playerColorIndex(swipe.color)
      spriteId = SwordSwipeSpriteBase +
        colorIndex * SwordSwipeStages + stage
      sweepBrads = SwordArcBrads -
        min(SwordArcBrads * 2, age * SwordArcBrads * 2 div
          max(1, SwordFxTicks - 1))
      (ux, uy) = aimVector(swipe.aimBrads + sweepBrads)
      px = swipe.x + int(round(ux * float(SwordRange) / 2.0))
      py = swipe.y + int(round(uy * float(SwordRange) / 2.0))
    if spriteDefs.spriteDefinitionIndex(spriteId) < 0:
      packet.addSpriteChanged(
        spriteDefs,
        spriteId,
        SwordSwipeSize,
        SwordSwipeSize,
        buildSwordSwipeSprite(colorIndex, stage),
        "sword swipe"
      )
    let objectId = SwordSwipeObjectBase + i
    currentIds.add(objectId)
    packet.addObject(
      objectId,
      px - SwordSwipeSize div 2,
      py - SwordSwipeSize div 2,
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
      packet.addSpriteChanged(
        spriteDefs, MedKitSpriteId,
        MedKitSize, MedKitSize,
        loadMedKitSprite(MedKitSize), "med kit"
      )
    let objectId = MedKitObjectBase + i
    currentIds.add(objectId)
    packet.addObject(
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
  ## (gated on seeing that player). The map/replay view passes no viewer and
  ## shows all. Sprites are defined lazily on first need per connection.
  for i in 0 ..< sim.shieldSpawns.len:
    let spawn = sim.shieldSpawns[i]
    if not spawn.present:
      continue
    if viewerIndex >= 0 and not sim.fovVisibleAt(viewerIndex, spawn.x, spawn.y):
      continue
    if spriteDefs.spriteDefinitionIndex(ShieldSpriteId) < 0:
      packet.addSpriteChanged(
        spriteDefs, ShieldSpriteId,
        ShieldSize, ShieldSize,
        loadShieldSprite(ShieldSize), "shield"
      )
    let objectId = ShieldObjectBase + i
    currentIds.add(objectId)
    packet.addObject(
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
    if spriteDefs.spriteDefinitionIndex(ShieldCarrySpriteId) < 0:
      packet.addSpriteChanged(
        spriteDefs, ShieldCarrySpriteId,
        ShieldCarrySize, ShieldCarrySize,
        loadShieldSprite(ShieldCarrySize), "shield carried"
      )
    let objectId = ShieldCarryObjectBase + i
    currentIds.add(objectId)
    packet.addObject(
      objectId,
      player.x + CollisionW div 2 - HpBarWidth div 2 - ShieldCarrySize div 2,
      player.overheadAnchorY() - OverheadYOffset - ShieldCarrySize,
      30006, MapLayerId, ShieldCarrySpriteId
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
      packet.addSpriteChanged(
        spriteDefs, PaintBombPickupSpriteId,
        PaintBombPickupSize, PaintBombPickupSize,
        loadPaintBombSprite(PaintBombPickupSize), "grenade"
      )
    let objectId = PaintBombPickupObjectBase + i
    currentIds.add(objectId)
    packet.addObject(
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
      packet.addSpriteChanged(
        spriteDefs, PaintBombAirSpriteId,
        PaintBombAirSize, PaintBombAirSize,
        loadPaintBombSprite(PaintBombAirSize), "grenade air"
      )
    let objectId = PaintBombAirObjectBase + i
    currentIds.add(objectId)
    packet.addObject(
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
        packet.addSpriteChanged(
          spriteDefs, PaintBombCarrySpriteId,
          PaintBombCarrySize, PaintBombCarrySize,
          loadPaintBombSprite(PaintBombCarrySize), "grenade carried"
        )
      let objectId = PaintBombCarryObjectBase + i
      currentIds.add(objectId)
      packet.addObject(
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
        packet.addSpriteChanged(
          spriteDefs, ThrowTargetSpriteId,
          ThrowTargetSize, ThrowTargetSize,
          buildThrowTargetSprite(), "throw target"
        )
      let objectId = ThrowTargetObjectBase + i
      currentIds.add(objectId)
      packet.addObject(
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
        spriteId = BlastSpriteBase + colorIndex * BlastStages + stage
      if spriteDefs.spriteDefinitionIndex(spriteId) < 0:
        packet.addSpriteChanged(
          spriteDefs, spriteId, BlastSize, BlastSize,
          buildBlastSprite(colorIndex, stage),
          "blast stage " & $stage
        )
      let objectId = BlastObjectBase + i
      currentIds.add(objectId)
      packet.addObject(
        objectId,
        blast.x - BlastSize div 2,
        blast.y - BlastSize div 2,
        blast.y - 2, MapLayerId, spriteId
      )
    elif viewer >= 0:
      if spriteDefs.spriteDefinitionIndex(SoundRingSpriteId) < 0:
        packet.addSpriteChanged(
          spriteDefs, SoundRingSpriteId, SoundRingSize, SoundRingSize,
          buildSoundRingSprite(), "grenade sound"
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
      packet.addObject(
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
  viewerIndex = -1
) {.measure.} =
  ## Places live shout speech bubbles. The map/broadcast view passes no viewer
  ## and floats each bubble over the shouter (following them while they move);
  ## a player view hears only shouts within ShoutRange and pins the bubble at
  ## deterministically jittered coordinates, like the shot sound rings — so a
  ## bot learns the neighborhood a shout came from, never the exact spot.
  for i in 0 ..< min(sim.recentShouts.len, ShoutMaxCount):
    let shout = sim.recentShouts[i]
    var
      anchorX = shout.x        # tail-tip x (bubble is centered on it)
      tailTipY = shout.y - ShoutFloat
    if viewerIndex >= 0:
      if not sim.shoutAudibleTo(viewerIndex, shout):
        continue
      let (dx, dy) = shoutOffset(shout)
      anchorX = shout.x + dx
      tailTipY = shout.y + dy - ShoutFloat
    else:
      # The broadcast pins the bubble over the shouter while they live, above
      # the name label; a dead or departed shouter leaves it where it was made.
      for player in sim.players:
        if player.address == shout.address:
          if player.alive:
            anchorX = player.x + CollisionW div 2
            tailTipY = player.overheadAnchorY() - OverheadYOffset -
              HpBarH - TextLineHeight - 2
          break
    let
      bubble = sim.buildShoutBubble(shout.team, shout.text)
      spriteId = ShoutSpriteBase + i
      objectId = ShoutObjectBase + i
    packet.addSpriteChanged(
      spriteDefs,
      spriteId,
      bubble.width,
      bubble.height,
      bubble.pixels,
      teamText(shout.team) & " shout " & shout.address & ": " & shout.text
    )
    currentIds.add(objectId)
    packet.addObject(
      objectId,
      anchorX - bubble.width div 2,
      tailTipY - bubble.height,
      ShoutBubbleZ,
      MapLayerId,
      spriteId
    )

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
    let litSegments = min(HpBarSegments,
      max(1, (player.hp * HpBarSegments + maxHp - 1) div maxHp))
    let spriteId = HpPipSpriteBase + litSegments
    packet.addSpriteChanged(
      spriteDefs,
      spriteId,
      HpBarWidth,
      HpBarH,
      buildHpBarSprite(litSegments),
      "hp " & $litSegments & "/" & $HpBarSegments
    )
    let objectId = HpPipObjectBase + i
    currentIds.add(objectId)
    packet.addObject(
      objectId,
      player.x + CollisionW div 2 - HpBarWidth div 2,
      player.overheadAnchorY() - OverheadYOffset - HpBarH,
      30001,
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
    packet.addSpriteChanged(
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
    packet.addObject(
      objectId,
      px,
      py,
      splatter.y - 100,
      MapLayerId,
      spriteId
    )

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
      stage = clamp(age * DamagePopStages div DamageFxTicks, 0,
        DamagePopStages - 1)
      colorIndex = playerColorIndex(pop.color)
      amount = clamp(pop.amount, 1, DamagePopMaxAmount)
      sprite = sim.buildDamagePopSprite(colorIndex, amount, stage)
      # Rise a few pixels over the full life so the number lifts off the player.
      rise = DamagePopRisePx * age div max(1, DamageFxTicks)
      px = pop.x - sprite.width div 2
      py = pop.y - sprite.height div 2 - rise
      spriteId = DamagePopSpriteBase +
        (colorIndex * DamagePopMaxAmount + (amount - 1)) * DamagePopStages +
        stage
    packet.addSpriteChanged(
      spriteDefs,
      spriteId,
      sprite.width,
      sprite.height,
      sprite.pixels,
      "damage pop " & playerColorName(colorIndex) & " -" & $amount &
        " stage " & $stage
    )
    let objectId = DamagePopObjectBase + nextPop
    inc nextPop
    currentIds.add(objectId)
    packet.addObject(objectId, px, py, DamagePopZ, MapLayerId, spriteId)

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
    result.addObject(
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
    result.addObject(MapObjectId, 0, 0, low(int16), MapLayerId, MapSpriteId)

    # The fog overlay dims everything outside this viewer's vision. Ghost
    # viewers (dead players) watch the whole map unfogged.
    if not viewerIsGhost:
      sim.addFogRuns(playerIndex, nextState.spriteDefs, currentIds, result)

    # The team flags: a pedestal flag is always visible (so an empty own
    # pedestal means the own flag is stolen); a carried flag rides its
    # carrier and is exactly as visible as that carrier.
    for team in Team:
      let flag = sim.flags[team]
      if viewerIsGhost or sim.flagVisibleTo(playerIndex, team):
        # A carried flag glows: the halo rides UNDER the carrier so the runner
        # is the brightest figure on the board.
        if flag.carrier >= 0:
          let auraId = FlagAuraObjectBase + ord(team)
          currentIds.add(auraId)
          result.addObject(
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
          result.addObject(
            objectId,
            flag.x - FlagBannerW div 2,
            flag.y - FlagBannerH div 2,
            flag.y - 1,
            MapLayerId,
            FlagSpriteBase + ord(team)
          )
        else:
          # Home: the BIG planted banner, centered + bottom-anchored on the pedestal.
          result.addObject(
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
      var spriteId = other.spriteActorSpriteId(-1)
      if not other.alive:
        # A body (ghost view only): grey corpse sprite + `corpse <color> <side>`
        # so it never reads as a live soldier to a label-scanning policy.
        spriteId = corpseSoldierSpriteId(other.team, soldierRotIndex(other.aimBrads))
      elif i == playerIndex and not viewerIsGhost:
        # Yourself reads as a distinct white-outlined soldier, pre-rotated to
        # your aim so the gun points where you're looking.
        let rot = soldierRotIndex(other.aimBrads)
        spriteId = SpritePlayerSelfSpriteBase + rot
        result.addSpriteChanged(
          nextState.spriteDefs,
          spriteId,
          SoldierCanvas,
          SoldierCanvas,
          soldierOutlined(soldierRotPixels(other.team, rot), 2'u8),
          # Documented self marker (RULES.md): `self <color> <side>`, only drawn
          # while alive. Side follows the aim exactly as the sim's flipH does.
          "self " & teamText(other.team) &
            (if soldierFacingRight(rot): " right" else: " left")
        )
      let objectId = other.spriteObjectId()
      currentIds.add(objectId)
      result.addObject(
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
    sim.addShotTracers(
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
    sim.addSwords(
      nextState.spriteDefs,
      currentIds,
      result,
      viewerIndex = playerIndex
    )
    sim.addSwordSwipes(
      nextState.spriteDefs,
      currentIds,
      result,
      viewerIndex = playerIndex
    )
    sim.addShouts(
      nextState.spriteDefs,
      currentIds,
      result,
      viewerIndex = playerIndex
    )
    if not viewerIsGhost:
      sim.addSoundRings(
        nextState.spriteDefs,
        currentIds,
        result,
        viewerIndex = playerIndex
      )

    # Fire-readiness icon on the bottom-left HUD layer.
    if player.alive:
      currentIds.add(SpritePlayerRemainingObjectId)
      result.addObject(
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
      livesText = $player.hp & "hp x" & $player.lives
      lives = sim.buildSpriteProtocolTextSprite([livesText], 2'u8)
    currentIds.add(SelectedTextObjectId)
    result.addSpriteChanged(
      nextState.spriteDefs,
      SpritePlayerRemainingSpriteId,
      lives.width,
      lives.height,
      lives.pixels,
      "lives " & livesText,
      changed = true
    )
    result.addObject(
      SelectedTextObjectId,
      23 - lives.width,
      1,
      0,
      HudTopRightLayerId,
      SpritePlayerRemainingSpriteId
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
    warning.label,
    changed = true
  )
  packet.addObject(
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
  packet.addSpriteChanged(
    state.spriteDefs,
    endzoneFadeSpriteId(team, stage),
    strip.w,
    strip.h,
    strip.pixels,
    "endzone " & (if team == Red: "red" else: "blue") & " power " & $stage
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
  let pairCount = 2 * (GlowFadeStages - 1)     # stages 1..7 per team; 0 never draws.
  let pairIndex = state.endzonePrewarmFrames div EndzonePrewarmEveryFrames
  if state.endzonePrewarmFrames mod EndzonePrewarmEveryFrames == 0 and
      pairIndex < pairCount:
    let
      team = if pairIndex < GlowFadeStages - 1: Red else: Blue
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
  for team in Team:
    let taken = sim.flags[team].carrier >= 0
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
    packet.addObject(
      objectId,
      box.x,
      box.y,
      low(int16) + 1,                  # just above the map, below all decals/actors.
      MapLayerId,
      endzoneFadeSpriteId(team, stage)
    )

proc buildSpriteProtocolUpdates*(
  sim: var SimServer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState,
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
          nextState.toggleSelectedJoinOrder(
            sim.selectSpritePlayer(nextState.mouseX, nextState.mouseY)
          )
    elif not nextState.povActive and nextState.mouseLayer == MapLayerId:
      nextState.toggleSelectedJoinOrder(
        sim.selectSpritePlayer(nextState.mouseX, nextState.mouseY)
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
  sim.addSplatters(nextState.spriteDefs, currentIds, result)
  sim.addDamagePops(nextState.spriteDefs, currentIds, result)
  sim.addShotTracers(nextState.spriteDefs, currentIds, result)
  sim.addRotatingDiamonds(nextState.spriteDefs, currentIds, result)
  sim.addMedKits(nextState.spriteDefs, currentIds, result)
  sim.addShields(nextState.spriteDefs, currentIds, result)
  sim.addGrenades(nextState.spriteDefs, currentIds, result)
  sim.addSwords(nextState.spriteDefs, currentIds, result)
  sim.addSwordSwipes(nextState.spriteDefs, currentIds, result)
  sim.addShouts(nextState.spriteDefs, currentIds, result)
  sim.addAimIndicators(nextState.spriteDefs, currentIds, result)
  sim.addHpPips(nextState.spriteDefs, currentIds, result)

  for playerIndex in 0 ..< sim.players.len:
    let player = sim.players[playerIndex]
    if not player.alive:
      continue
    let objectId = player.spriteObjectId()
    currentIds.add(objectId)
    result.addObject(
      objectId,
      player.spritePlayerX(),
      player.spritePlayerY(),
      player.y,
      MapLayerId,
      player.spriteActorSpriteId(nextState.selectedJoinOrder)
    )
    if sim.config.showPlayerLabels:
      let flagTeamOrd = sim.carriedFlagTeam(playerIndex)
      let
        label =
          if flagTeamOrd >= 0:
            # This player holds a flag: name + a team-colored flag marker beside
            # it, so it's obvious who is carrying and whose flag it is.
            sim.buildCarrierNameSprite(player, flagTeamOrd)
          else:
            sim.buildSpriteProtocolTextSprite(
              playerLabelLines(sim, player, playerIndex),
              PlayerNameColor
            )
        labelSpriteId = player.spritePlayerNameSpriteId()
        labelObjectId = player.spritePlayerNameObjectId()
        labelX = player.overheadAnchorX() +
          (SoldierBodyPx - label.width) div 2
        labelY = player.overheadAnchorY() - OverheadYOffset -
          HpBarH - label.height - 1
      currentIds.add(labelObjectId)
      result.addSprite(
        labelSpriteId,
        label.width,
        label.height,
        label.pixels
      )
      result.addObject(
        labelObjectId,
        labelX,
        labelY,
        PlayerNameZ,
        MapLayerId,
        labelSpriteId
      )

  # Both team flags: the banner planted on the home pedestal or riding the
  # carrier, with a floor-glow halo under any carrier so the flag-runner reads
  # as the brightest figure on the board.
  for team in Team:
    let
      flag = sim.flags[team]
      objectId = FlagObjectBase + ord(team)
    if flag.carrier >= 0:
      let auraId = FlagAuraObjectBase + ord(team)
      currentIds.add(auraId)
      result.addObject(
        auraId,
        flag.x - FlagAuraSize div 2,
        flag.y - FlagAuraSize div 2,
        flag.y - 1,
        MapLayerId,
        FlagAuraSpriteBase + ord(team)
      )
    currentIds.add(objectId)
    if flag.carrier >= 0:
      # Carried: the heart rides BEHIND the carrier (z below the player), so the
      # runner's body stays the readable figure and the heart peeks out around
      # them instead of covering them. Centered on the carrier; the aura +
      # nameplate still mark WHO runs it.
      result.addObject(
        objectId,
        flag.x - FlagBannerW div 2,
        flag.y - FlagBannerH div 2,
        flag.y - 1,
        MapLayerId,
        FlagSpriteBase + ord(team)
      )
    else:
      # Home: the BIG planted banner, centered + bottom-anchored on the pedestal.
      result.addObject(
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
    result.addObject(
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
      "replay scrubber",
      changed = true
    )
    result.addObject(
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
      "replay controls",
      changed = true
    )
    result.addObject(
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
