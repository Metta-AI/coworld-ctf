import
  std/[algorithm, math, os, strutils],
  bitworld/pixelfonts, bitworld/profile, bitworld/spriteprotocol, bitworld/server,
  sim

const
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
  InterstitialObjectId = 4005
  InterstitialLayerId = 2
  InterstitialLayerType = 2
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
  CarriedFlagLift = -7         ## px the carried banner rides BELOW the head so it
                               ## sits on the carrier's body (like a flag held), and
                               ## never floats up into the nameplate. Negative = down.
  CarriedFlagSideX = 6         ## px the carried banner shifts toward the carrier's
                               ## facing side, so it reads as held-out, not centered.
  FlagBannerW = 16             ## px width of the carried banner sprite.
  FlagBannerH = 22             ## px height of the banner (bottom-anchored on the pole foot).
  PlantedFlagScale = 3         ## the HOME banner is drawn this many x bigger so it
                               ## reads as a real objective on the 96px pedestal.
  PlantedFlagW = FlagBannerW * PlantedFlagScale
  PlantedFlagH = FlagBannerH * PlantedFlagScale
  PlantedFlagSpriteBase = 704  ## scaled home-banner sprites: 704 red, 705 blue.
  FlagAuraSpriteBase = 702     ## carrier-glow sprites: 702 red-flag halo, 703 blue-flag halo.
  FlagAuraObjectBase = 19200   ## carrier-glow object pool (one per carried flag).
  FlagAuraSize = 26            ## px diameter of the carrier halo.
  SoundRingSpriteId = 830      ## the shot "sound" ring sprite.
  SoundRingObjectBase = 19100  ## sound ring object-id pool (per recent shot).
  SoundRingSize = 12           ## px diameter of the sound ring.
  SoundRingJitter = 20         ## max px the ring strays from the true muzzle.
  TracerStages = 4             ## age fade stages (protocol has no per-object alpha).
  TracerDotSpriteBase = 900    ## per color-and-fade-stage tracer dots: 900..963.
  TracerDotObjectBase = 15000  ## tracer object-id pool base.
  TracerDotSize = 3
  TracerDotSpacing = 12        ## px between sampled tracer dots along a shot.
  TracerMaxShots = 16          ## most tracers drawn at once (one per shooter).
  TracerDotsPerShot = GunRange div TracerDotSpacing + 4  ## dots per full-range shot, plus slack.
  TracerMaxDots = TracerMaxShots * TracerDotsPerShot  ## 1792 ids: 15000..16791.
  SplatterSpriteBase = 16000   ## per color-and-fade-stage splatter sprites: 16000..16063.
  SplatterObjectBase = 17000   ## splatter object-id pool base, above the tracer ids.
  SplatterSize = 13
  SplatterStages = 4           ## fade stages across SplatterFxTicks.
  SplatterMaxCount = 32        ## most splatters drawn at once.
  HitSpriteBase = 16100        ## per-color-and-stage hit-splat sprites: 16100..16163.
  HitSplatSize = 21            ## on-hit paint-splat canvas (~1.3x a 16px player).
  HitSplatCoreR = 6.0          ## px radius of the splat's main wet blob.
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
  ## dots 900..963 (color×fade-stage), aim dots 780..795, self markers 5100..5101, team score
  ## text 12100..12101, splatters 16000..16063, fog runs 21000..21155 (one
  ## per run width in cells), map markers 20000. Objects: flags 6500..6501
  ## (map view) / 5009..5010 (player view), team score text 9600..9601,
  ## tracer dots 15000..16791, splatters 17000..17031, aim dots
  ## 18000..18063, map markers 20000, fog runs 21000..23047.
  SpritePlayerFireSpriteId = 5000
  SpritePlayerFireShadowSpriteId = 5001
  SpritePlayerRemainingSpriteId = 5003
  SpritePlayerInterstitialSpriteId = 5006
  SpritePlayerWalkabilitySpriteId = 5007
  SpritePlayerInterstitialObjectId = 5006
  SpritePlayerRemainingObjectId = 5008
  SpritePlayerFlagObjectBase = 5009  ## 5009 red flag, 5010 blue flag.
  SpritePlayerSelfSpriteBase = 5100  ## 5100 right-facing, 5101 left-facing.
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

proc crewPlayerSpriteId(colorIndex, slotId: int, flipH: bool): int =
  ## Returns the sprite id for one living crew variant.
  let
    variant = crewVariantIndex(slotId)
    side = if flipH: 1 else: 0
  PlayerSpriteBase + (colorIndex * CrewSpriteVariants + variant) * 2 + side

proc selectedCrewPlayerSpriteId(colorIndex, slotId: int, flipH: bool): int =
  ## Returns the selected sprite id for one living crew variant.
  let
    variant = crewVariantIndex(slotId)
    side = if flipH: 1 else: 0
  SelectedPlayerSpriteBase + (colorIndex * CrewSpriteVariants + variant) * 2 +
    side

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

proc buildTracerDotSprite(colorIndex, stage: int): seq[uint8] {.measure.} =
  ## Builds one shot-tracer dot sprite for one fade stage: the shooter's palette
  ## color mixed halfway toward white so beams read bright on the dark floor,
  ## with alpha ramping DOWN by age stage so a shot punches then fades out
  ## instead of a persistent full-strength dotted line (ux.replay L98). Stage 0
  ## is the fresh, brightest dot; the last stage is nearly gone.
  result = newRgbaPixels(TracerDotSize, TracerDotSize)
  let
    base = Palette[PlayerColors[colorIndex and 0x0f] and 0x0f]
    alpha = uint8(max(0, 255 - stage * 255 div TracerStages))
  for i in 0 ..< TracerDotSize * TracerDotSize:
    result.putRawRgbaPixel(
      i,
      uint8((base.r.int + 255) div 2),
      uint8((base.g.int + 255) div 2),
      uint8((base.b.int + 255) div 2),
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

proc buildMapSpritePixels(sim: SimServer): seq[uint8] {.measure.} =
  ## Returns the true-color map pixels for a global protocol sprite.
  if sim.mapRgba.len == sim.gameMap.width * sim.gameMap.height * 4:
    return sim.mapRgba
  result = newRgbaPixels(sim.gameMap.width, sim.gameMap.height)
  for i in 0 ..< sim.mapPixels.len:
    result.putRgbaPixel(i, sim.mapPixels[i])

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

proc blitSmallText(
  game: SimServer,
  target: var seq[uint8],
  targetWidth, targetHeight: int,
  text: string,
  baseX, baseY: int,
  color: uint8
) =
  ## Blits small text into protocol pixels.
  var x = baseX
  for ch in text:
    let glyph = game.asciiSprites.glyphAt(ch)
    target.blitGlyph(
      targetWidth,
      targetHeight,
      glyph,
      x,
      baseY,
      color
    )
    x += game.asciiSprites.glyphAdvance(ch)

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

proc playerIconSpriteId(player: Player): int =
  ## Returns the default right-facing player icon sprite id.
  crewPlayerSpriteId(
    playerColorIndex(player.color),
    player.joinOrder,
    false
  )

proc addProtocolGameOverActorSprites(
  sim: SimServer,
  currentIds: var seq[int],
  packet: var seq[uint8],
  layer: int
) {.measure.} =
  ## Adds separate player sprites for the game over interstitial.
  if sim.phase != GameOver:
    return
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
      iconY = y + (rowH - CrewSpriteSize) div 2
      objectId = ProtocolGameOverIconObjectBase + i
    currentIds.add(objectId)
    packet.addObject(
      objectId,
      iconX - 1,
      iconY - 1,
      30000,
      layer,
      player.playerIconSpriteId()
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
    sim.addProtocolGameOverActorSprites(currentIds, packet, layer)
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
  ## Builds one team's planted / carried CTF banner: a dark-wood pole with an
  ## ember-lit finial and a swallowtail fabric in the team color, a pale
  ## emblem, and a 1px dark outline so the flag reads on any floor. Replaces the
  ## reused task-icon flag with a purpose-built banner (ux.replay art direction
  ## #3): CTF fans expect a visible flag OBJECT, not a recolored pip. The fire
  ## HUD icon keeps the old task-icon (SpritePlayerFireSpriteId).
  const
    W = FlagBannerW
    H = FlagBannerH
  let
    body = teamColor(team)
    shade = ShadowMap[body and 0x0f]
  var kind = newSeq[uint8](W * H)  # 0 empty,1 pole,2 fabric,3 furl,4 emblem,5 rim,6 finial
  proc put(x, y: int, k: uint8) =
    if x >= 0 and x < W and y >= 0 and y < H:
      kind[y * W + x] = k
  proc rightEdge(y: int): int =
    ## The fabric's free right edge per row: full at top and bottom, notched in
    ## the middle rows to cut the classic swallowtail (fishtail) flag.
    case y
    of 3, 4, 5: 14
    of 6: 12
    of 7: 11
    of 8: 12
    of 9, 10, 11: 14
    else: -1
  for y in 2 .. 20:            # the pole
    put(6, y, 1)
    put(7, y, 1)
  put(6, 1, 6)                 # ember-lit finial cap
  put(7, 1, 6)
  for y in 3 .. 11:            # the fabric, attached just right of the pole
    let re = rightEdge(y)
    if re < 0:
      continue
    for x in 8 .. re:
      put(x, y, if x >= 12: 3'u8 else: 2'u8)  # trailing third furls into shade
  for x in 8 .. rightEdge(3):  # warm torch rim along the fabric's top edge
    put(x, 3, 5)
  for e in [(10, 6), (9, 7), (10, 7), (11, 7), (10, 8)]:  # pale emblem diamond
    if kind[e[1] * W + e[0]] in {2'u8, 3'u8}:
      put(e[0], e[1], 4)
  result = newRgbaPixels(W, H)
  for i in 0 ..< W * H:
    case kind[i]
    of 1: result.putRgbaPixel(i, 5'u8)                    # dark-brown wood pole
    of 2: result.putRgbaPixel(i, body)                    # team fabric
    of 3: result.putRgbaPixel(i, shade)                   # furled shade
    of 4: result.putRgbaPixel(i, 2'u8)                    # near-white emblem
    of 5: result.putRawRgbaPixel(i, 255, 163, 0, 255)     # ember rim
    of 6: result.putRawRgbaPixel(i, 255, 200, 90, 255)    # warm finial
    else: discard
  proc solid(x, y: int): bool =
    x >= 0 and x < W and y >= 0 and y < H and kind[y * W + x] != 0
  for y in 0 ..< H:            # 1px dark outline around the whole silhouette
    for x in 0 ..< W:
      if kind[y * W + x] != 0:
        continue
      if solid(x - 1, y) or solid(x + 1, y) or solid(x, y - 1) or solid(x, y + 1):
        result.putRgbaPixel(y * W + x, OutlineColor)

proc scaleRgbaSpriteNearest(
  src: seq[uint8], srcW, srcH, scale: int
): seq[uint8] {.measure.} =
  ## Nearest-neighbor upscale of an RGBA sprite buffer — keeps the crisp pixel-art
  ## edges (no blur), so the home banner grows to pedestal scale cleanly.
  let
    dstW = srcW * scale
    dstH = srcH * scale
  result = newSeq[uint8](dstW * dstH * 4)
  for y in 0 ..< dstH:
    let sy = y div scale
    for x in 0 ..< dstW:
      let
        sx = x div scale
        srcOff = (sy * srcW + sx) * 4
        dstOff = (y * dstW + x) * 4
      result[dstOff] = src[srcOff]
      result[dstOff + 1] = src[srcOff + 1]
      result[dstOff + 2] = src[srcOff + 2]
      result[dstOff + 3] = src[srcOff + 3]

proc buildPlantedFlagSprite(team: Team): seq[uint8] {.measure.} =
  ## The HOME (planted) banner, upscaled PlantedFlagScale× so it reads as a real
  ## objective standing on the pedestal instead of a thumbnail. Same art as the
  ## carried banner, just bigger; nearest-neighbor keeps the pixel edges crisp.
  scaleRgbaSpriteNearest(buildFlagBannerSprite(team), FlagBannerW, FlagBannerH,
    PlantedFlagScale)

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

proc addPlayerActorSprites(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  packet: var seq[uint8],
  selected: bool
) {.measure.} =
  ## Adds the team-colored player sprite variants used by both views.
  for i in 0 ..< PlayerColors.len:
    for variant in 0 ..< CrewSpriteVariants:
      let crew = sim.crewSprites[variant]
      packet.addSpriteChanged(
        spriteDefs,
        crewPlayerSpriteId(i, variant, false),
        crew.width + 2,
        crew.height + 2,
        buildCrewProtocolActorSprite(crew, PlayerColors[i], false),
        "player " & playerColorName(i) & " right"
      )
      packet.addSpriteChanged(
        spriteDefs,
        crewPlayerSpriteId(i, variant, true),
        crew.width + 2,
        crew.height + 2,
        buildCrewProtocolActorSprite(crew, PlayerColors[i], true),
        "player " & playerColorName(i) & " left"
      )
      if selected:
        packet.addSpriteChanged(
          spriteDefs,
          selectedCrewPlayerSpriteId(i, variant, false),
          crew.width + 2,
          crew.height + 2,
          buildCrewProtocolActorSprite(crew, PlayerColors[i], false, true),
          "selected player " & playerColorName(i) & " right"
        )
        packet.addSpriteChanged(
          spriteDefs,
          selectedCrewPlayerSpriteId(i, variant, true),
          crew.width + 2,
          crew.height + 2,
          buildCrewProtocolActorSprite(crew, PlayerColors[i], true, true),
          "selected player " & playerColorName(i) & " left"
        )

proc buildSpriteProtocolInit(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition]
): seq[uint8] {.measure.} =
  ## Builds the initial global viewer snapshot.
  result = @[]
  result.addU8(0x04)
  let mapPixels = sim.buildMapSpritePixels()
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
  result.addSpriteChanged(
    spriteDefs,
    MapSpriteId,
    sim.gameMap.width,
    sim.gameMap.height,
    mapPixels,
    "map"
  )
  result.addObject(MapObjectId, 0, 0, low(int16), MapLayerId, MapSpriteId)
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
  ## Returns the global viewer x position for a player sprite.
  player.x - SpriteDrawOffX - 1

proc spritePlayerY(player: Player): int =
  ## Returns the global viewer y position for a player sprite.
  player.y - SpriteDrawOffY - 1

proc spriteActorSpriteId(player: Player, selectedJoinOrder: int): int =
  ## Returns the sprite id for a player in the global viewer.
  let
    colorIndex = playerColorIndex(player.color)
    selected = player.joinOrder == selectedJoinOrder
  if selected:
    selectedCrewPlayerSpriteId(colorIndex, player.joinOrder, player.flipH)
  else:
    crewPlayerSpriteId(colorIndex, player.joinOrder, player.flipH)

proc selectSpritePlayer(
  sim: SimServer,
  mouseX,
  mouseY: int
): int {.measure.} =
  ## Returns the join order of the topmost player under the mouse.
  result = -1
  var bestY = low(int)
  for player in sim.players:
    let crew = sim.crewSpriteForSlot(player.joinOrder)
    let
      x = player.spritePlayerX()
      y = player.spritePlayerY()
      w = crew.width + 2
      h = crew.height + 2
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

proc tracerDotSpriteId(colorIndex, stage: int): int =
  ## Returns the sprite id for one tracer dot color and fade stage.
  TracerDotSpriteBase + colorIndex * TracerStages + stage

proc addShotTracers(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8],
  viewerIndex = -1
) {.measure.} =
  ## Places tracer dots in each shooter's color from a fixed object pool.
  ## The map view passes no viewer and shows every dot; a player view passes
  ## its viewer index and only receives the dots crossing its vision.
  var nextDot = 0
  for shotIndex in 0 ..< min(sim.recentShots.len, TracerMaxShots):
    let shot = sim.recentShots[shotIndex]
    let
      colorIndex = playerColorIndex(shot.color)
      age = sim.tickCount - shot.firedTick
      stage = clamp(age * TracerStages div ShotFxTicks, 0, TracerStages - 1)
      spriteId = tracerDotSpriteId(colorIndex, stage)
      dx = shot.x1 - shot.x0
      dy = shot.y1 - shot.y0
      length = max(abs(dx), abs(dy))
      steps = max(1, length div TracerDotSpacing)
    var definedSprite = false
    for s in 0 .. steps:
      if nextDot >= TracerMaxDots:
        break
      let
        mx = shot.x0 + dx * s div steps
        my = shot.y0 + dy * s div steps
      if viewerIndex >= 0 and not sim.fovVisibleAt(viewerIndex, mx, my):
        continue
      if not definedSprite:
        definedSprite = true
        packet.addSpriteChanged(
          spriteDefs,
          spriteId,
          TracerDotSize,
          TracerDotSize,
          buildTracerDotSprite(colorIndex, stage),
          "shot tracer " & playerColorName(colorIndex) & " stage " & $stage
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

proc addAimIndicators(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8],
  viewerIndex = -1
) {.measure.} =
  ## Places each living player's aim indicator: a short line of dots from the
  ## player's center along its aim angle, in the player's color, on the map
  ## layer. The map view passes no viewer and shows every aim; a player view
  ## passes its viewer index and only receives the aims of players it can see
  ## (a visible enemy's aim is readable intel). Object ids are a fixed pool
  ## keyed by player index; stale dots fall to the delete sweep.
  for i in 0 ..< sim.players.len:
    let player = sim.players[i]
    if not player.alive:
      continue
    if viewerIndex >= 0 and i != viewerIndex and
        not sim.playerVisibleTo(viewerIndex, i):
      continue
    let
      colorIndex = playerColorIndex(player.color)
      spriteId = AimDotSpriteBase + colorIndex
      (ax, ay) = aimVector(player.aimBrads)
      px = float(player.x + CollisionW div 2)
      py = float(player.y + CollisionH div 2)
    packet.addSpriteChanged(
      spriteDefs,
      spriteId,
      AimDotSize,
      AimDotSize,
      buildAimDotSprite(colorIndex),
      "aim dot " & playerColorName(colorIndex)
    )
    for d in 0 ..< AimDotsPerPlayer:
      let
        reach = float(AimDotStart + d * AimDotSpacing)
        mx = int(round(px + ax * reach))
        my = int(round(py + ay * reach))
        objectId = AimDotObjectBase + i * AimDotsPerPlayer + d
      currentIds.add(objectId)
      packet.addObject(
        objectId,
        mx - AimDotSize div 2,
        my - AimDotSize div 2,
        30003,
        MapLayerId,
        spriteId
      )

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
      player.spritePlayerY() - OverheadYOffset - HpBarH,
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
          # Carried: the small banner rides ON the carrier's body (shifted to the
          # facing side, well below the nameplate), so it never hides the name.
          let sideX =
            if flag.carrier < sim.players.len and sim.players[flag.carrier].flipH:
              -CarriedFlagSideX
            else: CarriedFlagSideX
          result.addObject(
            objectId,
            flag.x - FlagBannerW div 2 + sideX,
            flag.y - (FlagBannerH - 2) - CarriedFlagLift,
            flag.y + 1,
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
      if i == playerIndex and not viewerIsGhost:
        spriteId = SpritePlayerSelfSpriteBase + (if other.flipH: 1 else: 0)
        let crew = sim.crewSpriteForSlot(other.joinOrder)
        result.addSpriteChanged(
          nextState.spriteDefs,
          spriteId,
          crew.width + 2,
          crew.height + 2,
          buildCrewProtocolActorSprite(crew, other.color, other.flipH, true),
          "self " & playerColorText(other.color) &
            (if other.flipH: " left" else: " right")
        )
      let objectId = other.spriteObjectId()
      currentIds.add(objectId)
      result.addObject(
        objectId,
        other.x - SpriteDrawOffX - 1,
        other.y - SpriteDrawOffY - 1,
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
    sim.addShotTracers(
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
  sim.addSplatters(nextState.spriteDefs, currentIds, result)
  sim.addShotTracers(nextState.spriteDefs, currentIds, result)
  sim.addAimIndicators(nextState.spriteDefs, currentIds, result)
  sim.addHpPips(nextState.spriteDefs, currentIds, result)

  for playerIndex in 0 ..< sim.players.len:
    let player = sim.players[playerIndex]
    if not player.alive:
      continue
    let crew = sim.crewSpriteForSlot(player.joinOrder)
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
        labelX = player.spritePlayerX() +
          (crew.width + 2 - label.width) div 2
        labelY = player.spritePlayerY() - OverheadYOffset -
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
      # Carried: the small banner rides ON the carrier's body (shifted to the
      # facing side, well below the nameplate), so it never hides the name.
      let sideX =
        if flag.carrier < sim.players.len and sim.players[flag.carrier].flipH:
          -CarriedFlagSideX
        else: CarriedFlagSideX
      result.addObject(
        objectId,
        flag.x - FlagBannerW div 2 + sideX,
        flag.y - (FlagBannerH - 2) - CarriedFlagLift,
        flag.y + 1,
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
    currentIds.add(InterstitialObjectId)
    result.addObject(
      InterstitialObjectId,
      0,
      0,
      0,
      InterstitialLayerId,
      SpritePlayerInterstitialSpriteId
    )
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
