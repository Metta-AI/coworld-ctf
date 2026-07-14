import
  std/[algorithm, math, os],
  bitworld/pixelfonts, bitworld/profile, bitworld/spriteprotocol, bitworld/server,
  sim, hd

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
  ## The scoreboard is a top-left panel with one column per team: red on
  ## the left, blue on the right, mirroring the arena's territory sides.
  ScoreboardCols = 2
  ScoreboardColWidth = 74
  ScoreboardWidth = ScoreboardCols * ScoreboardColWidth
  ScoreboardY = 2
  ScoreboardRowHeight = 7
  ScoreboardPipX = 2
  ScoreboardPipSize = 4
  ScoreboardTextX = 8
  ScoreboardTextSpriteBase = 12000
  ScoreboardTextObjectBase = 12100
  ScoreboardPipSpriteBase = 12200
  ScoreboardPipObjectBase = 12300
  ScoreboardBgSpriteId = 12400
  ScoreboardBgObjectId = 12400
  ScoreboardHeadSpriteBase = 12500  ## +0 red header, +1 blue header.
  ScoreboardHeadObjectBase = 12500
  ScoreboardTextColor = 2'u8
  ScoreboardSelectedTextColor = 10'u8
  InterstitialObjectId = 4005
  InterstitialLayerId = 2
  InterstitialLayerType = 2
  OverheadYOffset = 4          ## px gap between a sprite top and overhead UI.
  HpPipSpriteBase = 820        ## hp pip bar sprites: 820 + remaining hp.
  HpPipObjectBase = 19000      ## hp pip bar object-id pool: one per player.
  HpPipSize = 2                ## px per pip square.
  HpPipGap = 1                 ## px between pips.
  CarriedFlagLift = 10         ## px a carried flag flies above its carrier.
  SoundRingSpriteId = 830      ## the shot "sound" ring sprite.
  SoundRingObjectBase = 19100  ## sound ring object-id pool (per recent shot).
  SoundRingSize = 12           ## px diameter of the sound ring.
  SoundRingJitter = 20         ## max px the ring strays from the true muzzle.
  TracerDotSpriteBase = 760    ## per-color tracer dot sprites: 760..775.
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
  ## dots 760..775, aim dots 780..795, self markers 5100..5101, team score
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

proc addWorldObject(
  packet: var seq[uint8],
  objectId, x, y, z, layer, spriteId: int
) =
  ## Adds one object whose x/y are MAP-scale coordinates on a render-scaled
  ## zoomable layer. Placement math stays in map pixels (offsets subtract the
  ## map-scale sprite footprint); the wire coordinate is scaled here, and the
  ## HD sprite being exactly RenderScale times its map footprint keeps every
  ## sprite centered on the same map point as before the HD port.
  packet.addObject(
    objectId,
    x * RenderScale,
    y * RenderScale,
    z,
    layer,
    spriteId
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

proc buildHpPipsSprite(hp, maxHp: int): seq[uint8] {.measure.} =
  ## Builds the overhead hit-point bar at HD resolution: one bright pip per
  ## remaining hit point, one dark socket per lost one, so the bar length
  ## stays constant. Layout runs in map pixels and scales up per HD pixel.
  let
    width = maxHp * HpPipSize + (maxHp - 1) * HpPipGap
    hdWidth = width * RenderScale
    hdHeight = HpPipSize * RenderScale
  result = newRgbaPixels(hdWidth, hdHeight)
  for py in 0 ..< hdHeight:
    for px in 0 ..< hdWidth:
      let
        mx = px div RenderScale
        stride = HpPipSize + HpPipGap
        pip = mx div stride
      if mx mod stride >= HpPipSize:
        continue
      let i = py * hdWidth + px
      if pip < hp:
        result.putRawRgbaPixel(i, 96, 255, 96, 255)
      else:
        result.putRawRgbaPixel(i, 40, 40, 40, 200)

proc buildSoundRingSprite(): seq[uint8] {.measure.} =
  ## Builds the semi-transparent white "sound" ring: a faint filled circle
  ## with a brighter rim, colorless so it never leaks the shooter's team.
  let size = SoundRingSize * RenderScale
  result = newRgbaPixels(size, size)
  let c = float(size - 1) / 2
  for y in 0 ..< size:
    for x in 0 ..< size:
      let d = sqrt((float(x) - c) * (float(x) - c) +
        (float(y) - c) * (float(y) - c))
      if d <= c:
        let alpha = if d >= c - 1.5 * float(RenderScale): 150'u8 else: 45'u8
        result.putRawRgbaPixel(y * size + x, 255, 255, 255, alpha)

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

proc buildTracerDotSprite(colorIndex: int): seq[uint8] {.measure.} =
  ## Builds one shot-tracer dot sprite: the shooter's palette color mixed
  ## halfway toward white, so beams read bright on the dark floor but keep
  ## the shooter's hue.
  let size = TracerDotSize * RenderScale
  result = newRgbaPixels(size, size)
  let
    base = Palette[PlayerColors[colorIndex and 0x0f] and 0x0f]
    c = float(size - 1) / 2
  for y in 0 ..< size:
    for x in 0 ..< size:
      let d = sqrt((float(x) - c) * (float(x) - c) +
        (float(y) - c) * (float(y) - c))
      if d > c:
        continue
      # A hot core fading into a soft glow reads as a beam once the dots
      # overlap along the shot line.
      let alpha = uint8(clamp(int(290.0 * (1.0 - d / (c + 0.5))), 0, 255))
      result.putRawRgbaPixel(
        y * size + x,
        uint8((base.r.int + 255) div 2),
        uint8((base.g.int + 255) div 2),
        uint8((base.b.int + 255) div 2),
        alpha
      )

proc buildAimDotSprite(colorIndex: int): seq[uint8] {.measure.} =
  ## Builds one aim-indicator dot sprite: the player's palette color mixed
  ## halfway toward white, matching the tracer-dot styling.
  let size = AimDotSize * RenderScale
  result = newRgbaPixels(size, size)
  let
    base = Palette[PlayerColors[colorIndex and 0x0f] and 0x0f]
    c = float(size - 1) / 2
  for y in 0 ..< size:
    for x in 0 ..< size:
      let d = sqrt((float(x) - c) * (float(x) - c) +
        (float(y) - c) * (float(y) - c))
      if d > c:
        continue
      result.putRawRgbaPixel(
        y * size + x,
        uint8((base.r.int + 255) div 2),
        uint8((base.g.int + 255) div 2),
        uint8((base.b.int + 255) div 2),
        255
      )

proc buildSplatterSprite(colorIndex, stage: int): seq[uint8] {.measure.} =
  ## Builds one death-splatter blob: a dense irregular blob of the victim's
  ## color at stage 0 that grows sparser and darker toward the last stage.
  let size = SplatterSize * RenderScale
  result = newRgbaPixels(size, size)
  let
    color = PlayerColors[colorIndex and 0x0f]
    shade = ShadowMap[color and 0x0f]
    half = size div 2
  for y in 0 ..< size:
    for x in 0 ..< size:
      let
        dx = x - half
        dy = y - half
        d2 = dx * dx + dy * dy
      if d2 > half * half:
        continue
      var noise = uint32(x) * 374761393'u32 + uint32(y) * 668265263'u32
      noise = (noise xor (noise shr 13)) * 1274126177'u32
      # The density curve runs in map-pixel distance so the blob keeps the
      # legacy falloff at RenderScale times the size.
      let density = 120 - stage * 25 -
        d2 * 2 div (RenderScale * RenderScale)
      if int((noise shr 16) mod 100) < density:
        result.putRgbaPixel(
          y * size + x,
          if stage >= SplatterStages div 2: shade else: color
        )

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
    width * RenderScale,
    height * RenderScale,
    newRgbaPixels(width * RenderScale, height * RenderScale),
    label
  )
  packet.addWorldObject(objectId, x, y, MapMarkerZ, MapLayerId, spriteId)

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

proc addMapFurniture(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8]
) {.measure.} =
  ## Places the static HD arena: tiled floor, team territory washes, the
  ## textured wall shapes and border slabs, and the flag pedestals. Sprite
  ## definitions register once per connection (addSpriteChanged dedupes);
  ## objects re-emit per frame like every other entity so the stale-object
  ## sweep never collects them. Sent instead of one full-map image because a
  ## painterly 3705x1977 sprite would compress terribly; the tiled floor plus
  ## per-shape walls keep the init packet a few hundred KB.
  # Floor tiles.
  if spriteDefs.spriteDefinitionIndex(HdFloorSpriteId) < 0:
    packet.addSpriteChanged(
      spriteDefs,
      HdFloorSpriteId,
      HdFloorTileMapPx * RenderScale,
      HdFloorTileMapPx * RenderScale,
      hdFloorSpritePixels(),
      "floor"
    )
  var tileIndex = 0
  for tile in hdFloorTiles():
    let objectId = HdFloorObjectBase + tileIndex
    inc tileIndex
    currentIds.add(objectId)
    packet.addWorldObject(
      objectId, tile.x, tile.y, HdFloorZ, MapLayerId, HdFloorSpriteId
    )
  # Team territory washes over each half's floor.
  let tintSize = hdTintSize()
  for team in Team:
    let spriteId = HdTintSpriteBase + ord(team)
    if spriteDefs.spriteDefinitionIndex(spriteId) < 0:
      packet.addSpriteChanged(
        spriteDefs,
        spriteId,
        tintSize.width,
        tintSize.height,
        hdTintSpritePixels(team),
        teamText(team) & " territory"
      )
    let objectId = HdTintObjectBase + ord(team)
    currentIds.add(objectId)
    packet.addWorldObject(
      objectId,
      if team == Red: 0 else: MapWidth div 2,
      0,
      HdTintZ,
      MapLayerId,
      spriteId
    )
  # Interior wall shapes (deduped forms plus carved instances).
  var pieceIndex = 0
  for piece in hdWallPiecesList():
    if spriteDefs.spriteDefinitionIndex(piece.spriteId) < 0:
      let sprite = hdWallSprite(piece.spriteId)
      packet.addSpriteChanged(
        spriteDefs,
        piece.spriteId,
        sprite.width,
        sprite.height,
        sprite.pixels,
        "wall"
      )
    let objectId = HdWallObjectBase + pieceIndex
    inc pieceIndex
    currentIds.add(objectId)
    packet.addWorldObject(
      objectId, piece.x, piece.y, HdWallZ, MapLayerId, piece.spriteId
    )
  # Border slabs.
  for i in 0 ..< 4:
    let
      spriteId = HdBorderSpriteBase + i
      slab = hdBorderSlab(i)
    if spriteDefs.spriteDefinitionIndex(spriteId) < 0:
      packet.addSpriteChanged(
        spriteDefs, spriteId, slab.width, slab.height, slab.pixels, "wall"
      )
    let objectId = HdBorderObjectBase + i
    currentIds.add(objectId)
    packet.addWorldObject(
      objectId, slab.x, slab.y, HdWallZ, MapLayerId, spriteId
    )
  # Flag pedestals (cosmetic; the flag objects carry the game state).
  for team in Team:
    let spriteId = HdPedestalSpriteBase + ord(team)
    if spriteDefs.spriteDefinitionIndex(spriteId) < 0:
      packet.addSpriteChanged(
        spriteDefs,
        spriteId,
        HdPedestalSize,
        HdPedestalSize,
        hdPedestalSpritePixels(team),
        teamText(team) & " pedestal"
      )
    let
      home = sim.gameMap.flagHome(team)
      half = HdPedestalSize div (2 * RenderScale)
      objectId = HdPedestalObjectBase + ord(team)
    currentIds.add(objectId)
    packet.addWorldObject(
      objectId, home.x - half, home.y - half, HdPedestalZ, MapLayerId, spriteId
    )

proc buildFogRunSprite(widthCells: int): seq[uint8] {.measure.} =
  ## Builds one translucent dark fog run sprite covering `widthCells`
  ## horizontally-adjacent 8px visibility cells.
  let
    width = widthCells * FovCellSize * RenderScale
    height = FovCellSize * RenderScale
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
        run.width * FovCellSize * RenderScale,
        FovCellSize * RenderScale,
        buildFogRunSprite(run.width),
        "fog"
      )
    let objectId = FogObjectBase + runIndex
    currentIds.add(objectId)
    packet.addWorldObject(
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

proc scaleRgbaPixels(
  pixels: seq[uint8],
  width, height, scale: int
): seq[uint8] =
  ## Nearest-neighbour integer upscale for RGBA sprite pixels.
  result = newSeq[uint8](width * scale * height * scale * 4)
  for y in 0 ..< height * scale:
    for x in 0 ..< width * scale:
      let
        src = ((y div scale) * width + x div scale) * 4
        dst = (y * width * scale + x) * 4
      result[dst] = pixels[src]
      result[dst + 1] = pixels[src + 1]
      result[dst + 2] = pixels[src + 2]
      result[dst + 3] = pixels[src + 3]

proc buildSpriteProtocolTextSprite(
  game: SimServer,
  lines: openArray[string],
  color: uint8,
  struck = false,
  scale = 1
): tuple[width, height: int, pixels: seq[uint8]] {.measure.} =
  ## Builds a transparent multi-line text sprite. UI layers use scale 1;
  ## text on the render-scaled map layer passes scale = RenderScale.
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
  if scale > 1:
    result.pixels = scaleRgbaPixels(
      result.pixels, result.width, result.height, scale
    )
    result.width *= scale
    result.height *= scale

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
  spriteDefs: var seq[SpriteDefinition],
  currentIds: var seq[int],
  packet: var seq[uint8],
  layer: int
) {.measure.} =
  ## Adds separate player sprites for the game over interstitial. The 128px
  ## interstitial is a UI layer, so the icons keep the small legacy crew art
  ## rather than the render-scaled map sprites.
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
      colorIndex = playerColorIndex(player.color)
      crew = sim.crewSpriteForSlot(player.joinOrder)
      col = i div rowsPerCol
      row = i mod rowsPerCol
      baseX = min(col, 1) * colW
      y = startY + row * rowH
      iconX = baseX + iconOffsetX
      iconY = y + (rowH - CrewSpriteSize) div 2
      objectId = ProtocolGameOverIconObjectBase + i
    packet.addSpriteChanged(
      spriteDefs,
      player.playerIconSpriteId(),
      crew.width + 2,
      crew.height + 2,
      buildCrewProtocolActorSprite(crew, player.color, false),
      "icon " & playerColorName(colorIndex)
    )
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

proc flagLabel(team: Team): string =
  ## Returns the observation label for one team's flag sprite.
  teamText(team) & " flag"

proc addFlagSprites(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  packet: var seq[uint8]
) {.measure.} =
  ## Adds both team flag sprite definitions from the HD art masters.
  discard sim
  for team in Team:
    packet.addSpriteChanged(
      spriteDefs,
      FlagSpriteBase + ord(team),
      HdFlagSize,
      HdFlagSize,
      hdFlagSpritePixels(team),
      flagLabel(team)
    )

proc playerSideText(player: Player): string =
  ## The observation label side suffix: the aim-derived sprite flip.
  if player.flipH: " left" else: " right"

proc addHdPlayerSprite(
  packet: var seq[uint8],
  spriteDefs: var seq[SpriteDefinition],
  player: Player,
  kind: HdCrewKind
): int {.measure.} =
  ## Registers (once per connection) and returns one player's HD sprite for
  ## its current aim rotation. Pixel buffers cache inside hd.nim, so the
  ## per-frame cost after the first sighting of a rotation is a lookup.
  let
    colorIndex = playerColorIndex(player.color)
    rot = hdRotIndex(player.aimBrads)
    spriteId = hdPlayerSpriteId(colorIndex, rot, kind)
    prefix =
      case kind
      of hdCrewNormal: "player "
      of hdCrewSelf: "self "
      of hdCrewSelected: "selected player "
      of hdCrewCorpse: "corpse "
  packet.addSpriteChanged(
    spriteDefs,
    spriteId,
    HdCrewSize,
    HdCrewSize,
    hdCrewSpritePixels(colorIndex, rot, kind),
    prefix & playerColorName(colorIndex) & player.playerSideText()
  )
  spriteId

proc addHdPlayerObject(
  packet: var seq[uint8],
  objectId: int,
  player: Player,
  spriteId: int
) =
  ## Places one HD player sprite centered on the player's map position.
  packet.addObject(
    objectId,
    player.x * RenderScale - HdCrewSize div 2,
    player.y * RenderScale - HdCrewSize div 2,
    player.y,
    MapLayerId,
    spriteId
  )

proc scoreboardCell(sim: SimServer, index: int): tuple[col, row: int] =
  ## Grid cell for one player: the team picks the column (red left, blue
  ## right, mirroring the arena sides), join order picks the row.
  let team = sim.players[index].team
  var row = 0
  for i in 0 ..< index:
    if sim.players[i].team == team:
      inc row
  (ord(team), row)

proc scoreboardRows(sim: SimServer): int =
  ## Returns the number of grid rows the roster occupies.
  var counts: array[Team, int]
  for player in sim.players:
    inc counts[player.team]
  max(1, max(counts[Red], counts[Blue]))

proc scoreboardHeight(sim: SimServer): int =
  ## Returns the panel's content height: team header row plus player rows.
  ScoreboardY + (sim.scoreboardRows() + 1) * ScoreboardRowHeight + 2

proc buildSpriteProtocolInit(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition]
): seq[uint8] {.measure.} =
  ## Builds the initial global viewer snapshot.
  hdEnsureLoaded(sim.gameMap)
  result = @[]
  result.addU8(0x04)
  result.addLayer(
    MapLayerId, MapLayerType, ZoomableLayerFlag or SmoothLayerFlag
  )
  result.addViewport(
    MapLayerId,
    sim.gameMap.width * RenderScale,
    sim.gameMap.height * RenderScale
  )
  result.addLayer(ScoreboardLayerId, ScoreboardLayerType, UiLayerFlag)
  result.addViewport(ScoreboardLayerId, ScoreboardWidth, sim.scoreboardHeight())
  result.addLayer(InterstitialLayerId, InterstitialLayerType, UiLayerFlag)
  result.addViewport(InterstitialLayerId, ScreenWidth, ScreenHeight)
  result.addLayer(BottomRightLayerId, BottomRightLayerType, UiLayerFlag)
  result.addViewport(BottomRightLayerId, ScreenWidth, ScreenHeight)
  result.addLayer(TeamScoreLayerId, TeamScoreLayerType, UiLayerFlag)
  result.addViewport(TeamScoreLayerId, TeamScoreWidth, TextLineHeight + 2)
  # A tiny transparent anchor keeps the (object 1, sprite 1) map origin that
  # sprite agents use as their camera reference; the visible arena arrives as
  # tiled furniture (addMapFurniture).
  result.addSpriteChanged(
    spriteDefs,
    MapSpriteId,
    1,
    1,
    newRgbaPixels(1, 1),
    "map"
  )
  result.addObject(MapObjectId, 0, 0, low(int16), MapLayerId, MapSpriteId)
  sim.addMapMarkers(spriteDefs, result)
  sim.addFlagSprites(spriteDefs, result)
  sim.addSpriteProtocolInterstitialSprites(spriteDefs, result)

proc buildSpriteProtocolPlayerInit(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition]
): seq[uint8] {.measure.} =
  ## Builds the initial sprite player snapshot: the full-map view (the client
  ## scales the whole arena to the window), the fog overlay layer, and the
  ## screen-corner HUD layers.
  hdEnsureLoaded(sim.gameMap)
  result = @[]
  result.addU8(0x04)
  result.addLayer(
    MapLayerId, MapLayerType, ZoomableLayerFlag or SmoothLayerFlag
  )
  result.addViewport(
    MapLayerId,
    sim.gameMap.width * RenderScale,
    sim.gameMap.height * RenderScale
  )
  result.addLayer(
    FogLayerId, MapLayerType, ZoomableLayerFlag or SmoothLayerFlag
  )
  result.addViewport(
    FogLayerId,
    sim.gameMap.width * RenderScale,
    sim.gameMap.height * RenderScale
  )
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
    1,
    1,
    newRgbaPixels(1, 1),
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

proc scoreboardText(sim: SimServer, player: Player): string =
  ## Returns one compact scoreboard cell: name plus kills/deaths, with the
  ## name truncated until the cell text fits its grid column.
  var name = player.scoreboardName()
  let stats = " " & $player.kills & "/" & $player.deaths
  while name.len > 3 and
      sim.asciiSprites.textWidth(name & stats) >
        ScoreboardColWidth - ScoreboardTextX:
    name.setLen(name.len - 1)
  name & stats

proc scoreboardJoinOrderAt(
  sim: SimServer,
  layer,
  mouseX,
  mouseY: int
): int =
  ## Returns the join order for a clicked scoreboard cell. The whole grid
  ## cell is the click target so the roster stays easy to hit.
  if layer != ScoreboardLayerId:
    return -1
  let
    col = mouseX div ScoreboardColWidth
    row = (mouseY - ScoreboardY) div ScoreboardRowHeight - 1
  if col < 0 or col >= ScoreboardCols or row < 0 or
      row >= sim.scoreboardRows():
    return -1
  for i in 0 ..< sim.players.len:
    if sim.scoreboardCell(i) == (col, row):
      return sim.players[i].joinOrder
  -1

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
  ## Adds the top-left roster panel (kills/deaths score picker), one column
  ## per team: red left, blue right.
  packet.addLayer(ScoreboardLayerId, ScoreboardLayerType, UiLayerFlag)
  packet.addViewport(
    ScoreboardLayerId,
    ScoreboardWidth,
    sim.scoreboardHeight()
  )
  # A translucent panel behind the grid: readable over the arena, and the
  # client only routes clicks to a UI layer when the cursor is over one of
  # its objects, so the panel makes the whole bar a click target.
  var bg = newRgbaPixels(ScoreboardWidth, sim.scoreboardHeight())
  for i in 0 ..< ScoreboardWidth * sim.scoreboardHeight():
    bg[i * 4 + 3] = 150
  currentIds.add(ScoreboardBgObjectId)
  packet.addSpriteChanged(
    spriteDefs,
    ScoreboardBgSpriteId,
    ScoreboardWidth,
    sim.scoreboardHeight(),
    bg,
    "scoreboard"
  )
  packet.addObject(
    ScoreboardBgObjectId,
    0,
    0,
    -1,
    ScoreboardLayerId,
    ScoreboardBgSpriteId
  )
  # Team kills/deaths header atop each team column.
  var kills, deaths: array[Team, int]
  for p in sim.players:
    kills[p.team] += p.kills
    deaths[p.team] += p.deaths
  for team in Team:
    let
      headText = (if team == Red: "RED " else: "BLUE ") &
        $kills[team] & "/" & $deaths[team]
      head = sim.buildSpriteProtocolTextSprite([headText], teamColor(team))
      headObjectId = ScoreboardHeadObjectBase + ord(team)
    currentIds.add(headObjectId)
    packet.addSpriteChanged(
      spriteDefs,
      ScoreboardHeadSpriteBase + ord(team),
      head.width,
      head.height,
      head.pixels,
      "team score " & headText,
      changed = true
    )
    packet.addObject(
      headObjectId,
      ord(team) * ScoreboardColWidth + ScoreboardTextX,
      ScoreboardY,
      0,
      ScoreboardLayerId,
      ScoreboardHeadSpriteBase + ord(team)
    )
  for i in 0 ..< sim.players.len:
    let
      player = sim.players[i]
      colorIndex = playerColorIndex(player.color)
      pipSpriteId = scoreboardPipSpriteId(colorIndex)
      pipObjectId = scoreboardPipObjectId(i)
      textSpriteId = scoreboardTextSpriteId(i)
      textObjectId = scoreboardTextObjectId(i)
      (cellCol, cellRow) = sim.scoreboardCell(i)
      cellX = cellCol * ScoreboardColWidth
      rowY = ScoreboardY + (cellRow + 1) * ScoreboardRowHeight
      color =
        if player.joinOrder == selectedJoinOrder:
          ScoreboardSelectedTextColor
        else:
          ScoreboardTextColor
      rowText = sim.scoreboardText(player)
      text = sim.buildSpriteProtocolTextSprite([rowText], color)
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
      cellX + ScoreboardPipX,
      rowY + 1,
      0,
      ScoreboardLayerId,
      pipSpriteId
    )
    packet.addSpriteChanged(
      spriteDefs,
      textSpriteId,
      text.width,
      text.height,
      text.pixels,
      "score " & rowText & " color " & $color
    )
    packet.addObject(
      textObjectId,
      cellX + ScoreboardTextX,
      rowY,
      0,
      ScoreboardLayerId,
      textSpriteId
    )

proc playerLabelLines(
  sim: SimServer,
  player: Player,
  playerIndex: int
): seq[string] =
  ## Returns label lines (name plus lives) for one player.
  result = @[playerLabelText(player)]

proc spritePlayerY(player: Player): int =
  ## Returns the global viewer y position for a player sprite.
  player.y - SpriteDrawOffY - 1

proc selectSpritePlayer(
  sim: SimServer,
  mouseX,
  mouseY: int
): int {.measure.} =
  ## Returns the join order of the topmost player under the mouse. Mouse
  ## coordinates arrive in map-layer (render-scaled) pixels; the HD sprite
  ## spans HdCrewSize around the player center.
  result = -1
  var bestY = low(int)
  let half = HdCrewSize div 2
  for player in sim.players:
    let
      x = player.x * RenderScale - half
      y = player.y * RenderScale - half
    if mouseX >= x and mouseX < x + HdCrewSize and
        mouseY >= y and mouseY < y + HdCrewSize and
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

proc tracerDotSpriteId(colorIndex: int): int =
  ## Returns the sprite id for one tracer dot color.
  TracerDotSpriteBase + colorIndex

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
      spriteId = tracerDotSpriteId(colorIndex)
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
          TracerDotSize * RenderScale,
          TracerDotSize * RenderScale,
          buildTracerDotSprite(colorIndex),
          "shot tracer " & playerColorName(colorIndex)
        )
      let objectId = TracerDotObjectBase + nextDot
      inc nextDot
      currentIds.add(objectId)
      packet.addWorldObject(
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
      AimDotSize * RenderScale,
      AimDotSize * RenderScale,
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
      packet.addWorldObject(
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
      SoundRingSize * RenderScale,
      SoundRingSize * RenderScale,
      buildSoundRingSprite(),
      "shot sound"
    )
    let
      (dx, dy) = soundRingOffset(shot)
      objectId = SoundRingObjectBase + shotIndex
    currentIds.add(objectId)
    packet.addWorldObject(
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
  ## Places a hit-point pip bar above each living player's head. The map view
  ## passes no viewer and shows every bar; a player view passes its viewer
  ## index and only receives the bars of players it can see (a wounded
  ## enemy's hp is readable intel). Object ids are a fixed pool keyed by
  ## player index; stale bars fall to the delete sweep.
  let maxHp = sim.config.hitPoints
  let width = maxHp * HpPipSize + (maxHp - 1) * HpPipGap
  for i in 0 ..< sim.players.len:
    let player = sim.players[i]
    if not player.alive:
      continue
    if viewerIndex >= 0 and i != viewerIndex and
        not sim.playerVisibleTo(viewerIndex, i):
      continue
    let spriteId = HpPipSpriteBase + player.hp
    packet.addSpriteChanged(
      spriteDefs,
      spriteId,
      width * RenderScale,
      HpPipSize * RenderScale,
      buildHpPipsSprite(player.hp, maxHp),
      "hp " & $player.hp & "/" & $maxHp
    )
    let objectId = HpPipObjectBase + i
    currentIds.add(objectId)
    packet.addWorldObject(
      objectId,
      player.x + CollisionW div 2 - width div 2,
      player.spritePlayerY() - OverheadYOffset - HpPipSize,
      30001,
      MapLayerId,
      spriteId
    )

proc splatterSpriteId(colorIndex, stage: int): int =
  ## Returns the sprite id for one splatter color and fade stage.
  SplatterSpriteBase + colorIndex * SplatterStages + stage

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
      stage = clamp(
        age * SplatterStages div SplatterFxTicks,
        0,
        SplatterStages - 1
      )
      colorIndex = playerColorIndex(splatter.color)
      px = splatter.x - SplatterSize div 2
      py = splatter.y - SplatterSize div 2
    let spriteId = splatterSpriteId(colorIndex, stage)
    packet.addSpriteChanged(
      spriteDefs,
      spriteId,
      SplatterSize * RenderScale,
      SplatterSize * RenderScale,
      buildSplatterSprite(colorIndex, stage),
      "splatter " & playerColorName(colorIndex) & " stage " & $stage
    )
    let objectId = SplatterObjectBase + nextSplatter
    inc nextSplatter
    currentIds.add(objectId)
    packet.addWorldObject(
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
  nextState: var PlayerViewerState,
  includeTeamScore = true
): seq[uint8] {.measure.} =
  ## Builds sprite protocol updates for one playable player view. The
  ## global viewer's embedded POV passes includeTeamScore = false because
  ## its roster panel already carries the team scores in the same corner.
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
    sim.addMapFurniture(nextState.spriteDefs, currentIds, result)

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
        let
          objectId = SpritePlayerFlagObjectBase + ord(team)
          lift = if flag.carrier >= 0: CarriedFlagLift else: 0
        currentIds.add(objectId)
        result.addWorldObject(
          objectId,
          flag.x - HdFlagSize div (2 * RenderScale),
          flag.y - HdFlagSize div (2 * RenderScale) - lift,
          flag.y + 1,
          MapLayerId,
          FlagSpriteBase + ord(team)
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
      let kind =
        if not other.alive:
          hdCrewCorpse
        elif i == playerIndex and not viewerIsGhost:
          hdCrewSelf
        else:
          hdCrewNormal
      let spriteId = result.addHdPlayerSprite(
        nextState.spriteDefs, other, kind
      )
      let objectId = other.spriteObjectId()
      currentIds.add(objectId)
      result.addHdPlayerObject(objectId, other, spriteId)

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

  if includeTeamScore:
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
      povState,
      includeTeamScore = false
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
  sim.addMapFurniture(nextState.spriteDefs, currentIds, result)
  sim.addSplatters(nextState.spriteDefs, currentIds, result)
  sim.addShotTracers(nextState.spriteDefs, currentIds, result)
  sim.addAimIndicators(nextState.spriteDefs, currentIds, result)
  sim.addHpPips(nextState.spriteDefs, currentIds, result)

  for playerIndex in 0 ..< sim.players.len:
    let player = sim.players[playerIndex]
    if not player.alive:
      continue
    let kind =
      if player.joinOrder == nextState.selectedJoinOrder:
        hdCrewSelected
      else:
        hdCrewNormal
    let spriteId = result.addHdPlayerSprite(
      nextState.spriteDefs, player, kind
    )
    let objectId = player.spriteObjectId()
    currentIds.add(objectId)
    result.addHdPlayerObject(objectId, player, spriteId)
    if sim.config.showPlayerLabels:
      let
        labelLines = playerLabelLines(sim, player, playerIndex)
        label = sim.buildSpriteProtocolTextSprite(
          labelLines,
          PlayerNameColor,
          scale = RenderScale
        )
        labelSpriteId = player.spritePlayerNameSpriteId()
        labelObjectId = player.spritePlayerNameObjectId()
        # HD-pixel placement: centered over the player, clear of the hp bar.
        labelX = player.x * RenderScale - label.width div 2
        labelY = (player.spritePlayerY() - OverheadYOffset - HpPipSize) *
          RenderScale - label.height - RenderScale
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

  # Both team flags: on the home pedestal or riding the carrier sprite.
  for team in Team:
    let
      flag = sim.flags[team]
      objectId = FlagObjectBase + ord(team)
      lift = if flag.carrier >= 0: CarriedFlagLift else: 0
    currentIds.add(objectId)
    result.addWorldObject(
      objectId,
      flag.x - HdFlagSize div (2 * RenderScale),
      flag.y - HdFlagSize div (2 * RenderScale) - lift,
      flag.y + 1,
      MapLayerId,
      FlagSpriteBase + ord(team)
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
  for objectId in state.objectIds:
    if objectId notin currentIds:
      result.addDeleteObject(objectId)
  nextState.objectIds = currentIds
