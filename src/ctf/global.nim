import
  std/[math, os],
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
  ScoreboardWidth = 160
  ScoreboardHeight = 130
  ScoreboardY = 2
  ScoreboardRowHeight = 8
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
  CarrierBarSpriteBase = 740
  CarrierBarObjectBase = 5000
  CarrierBarWidth = 10
  CarrierBarHeight = 2
  CarrierBarYOffset = 4
  CarrierBarColor = 2'u8
  TrailDotSpriteBase = 720
  TrailDotObjectBase = 6000
  TrailDotSize = 3
  TrailDotSpacing = 10
  TrailMaxDots = 10
  TracerDotSpriteId = 760      ## single bright shot-tracer dot sprite.
  TracerDotObjectBase = 15000  ## tracer object-id pool base.
  TracerDotSize = 3
  TracerDotSpacing = 5         ## px between sampled tracer dots along a shot.
  TracerDotColor = 8'u8        ## bright yellow (255,236,39): pops on the dark arena.
  TracerMaxShots = 8           ## most tracers drawn at once (one per shooter).
  TracerDotsPerShot = 34       ## dots per shot (gunRange / spacing, plus slack).
  TracerMaxDots = TracerMaxShots * TracerDotsPerShot
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
  SpritePlayerFireSpriteId = 5000
  SpritePlayerFireShadowSpriteId = 5001
  SpritePlayerRemainingSpriteId = 5003
  SpritePlayerArrowSpriteId = 5005
  SpritePlayerInterstitialSpriteId = 5006
  SpritePlayerWalkabilitySpriteId = 5007
  SpritePlayerInterstitialObjectId = 5006
  SpritePlayerRemainingObjectId = 5008
  SpritePlayerFlagObjectId = 5009
  SpritePlayerShadowSpriteId = 5010
  SpritePlayerShadowObjectId = 13000
  SpritePlayerShadowZ = -32767
  SpritePlayerCarrierObjectId = 10004
  SpritePlayerArrowObjectId = 7001
  FlagObjectId = 6500
  MapMarkerSpriteBase = 20000
  MapMarkerObjectBase = 20000
  MapMarkerZ = -32767
  ProtocolTextSpriteBase = 9000
  ProtocolTextObjectBase = 9000
  ProtocolTextZ = 30010
  ProtocolTextColor = 2'u8
  ProtocolLobbyIconObjectBase = 9400
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
  TrailDot = object
    x, y: int
    colorIndex: int

  PlayerTrail = ref object
    joinOrder: int
    lastX, lastY: int
    dots: seq[TrailDot]

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
    trails: seq[PlayerTrail]
    spriteDefs: seq[SpriteDefinition]

  PlayerViewerState* = ref object
    initialized*: bool
    objectIds*: seq[int]
    spriteDefs: seq[SpriteDefinition]
    shadowReady: bool
    shadowCameraX: int
    shadowCameraY: int
    shadowOriginMx: int
    shadowOriginMy: int

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

proc buildCarrierBarSprite(color: uint8): seq[uint8] {.measure.} =
  ## Builds the flag-carrier indicator bar sprite.
  result = newRgbaPixels(CarrierBarWidth, CarrierBarHeight)
  for i in 0 ..< CarrierBarWidth * CarrierBarHeight:
    result.putRgbaPixel(i, color)

proc buildTrailDotSprite(color: uint8): seq[uint8] {.measure.} =
  ## Builds one global-only player trail dot sprite.
  result = newRgbaPixels(TrailDotSize, TrailDotSize)
  for i in 0 ..< TrailDotSize * TrailDotSize:
    result.putRgbaPixel(i, color)

proc buildTracerDotSprite(): seq[uint8] {.measure.} =
  ## Builds the single bright shot-tracer dot sprite.
  result = newRgbaPixels(TracerDotSize, TracerDotSize)
  for i in 0 ..< TracerDotSize * TracerDotSize:
    result.putRgbaPixel(i, TracerDotColor)

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

proc buildPlayerShadowSprite(
  sim: SimServer,
  cameraX, cameraY: int
): seq[uint8] {.measure.} =
  ## Builds one screen-sized transparent shadow overlay.
  result = newRgbaPixels(ScreenWidth, ScreenHeight)
  for sy in 0 ..< ScreenHeight:
    for sx in 0 ..< ScreenWidth:
      let
        screenIndex = sy * ScreenWidth + sx
        mx = cameraX + sx
        my = cameraY + sy
      if not sim.shadowBuf[screenIndex]:
        continue
      if mx < 0 or my < 0 or mx >= MapWidth or my >= MapHeight:
        continue
      let mapPixel = mapIndex(mx, my)
      if sim.wallMask[mapPixel]:
        continue
      result.putRgbaPixel(
        screenIndex,
        ShadowMap[sim.mapPixels[mapPixel] and 0x0f]
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

proc addProtocolLobbyActorSprites(
  sim: SimServer,
  currentIds: var seq[int],
  packet: var seq[uint8],
  layer: int
) {.measure.} =
  ## Adds separate player sprites for the lobby interstitial.
  if sim.phase != Lobby:
    return
  let
    cols = max(1, min(sim.players.len, 6))
    cellW = CrewSpriteSize + 2
    cellH = CrewSpriteSize + 2
    totalW = cols * cellW
    startX = (ScreenWidth - totalW) div 2
    startY = sim.lobbyIconStartY()
  for i in 0 ..< sim.players.len:
    let
      col = i mod cols
      row = i div cols
      sx = startX + col * cellW
      sy = startY + row * cellH
      objectId = ProtocolLobbyIconObjectBase + i
    currentIds.add(objectId)
    packet.addObject(
      objectId,
      sx - 1,
      sy - 1,
      30000,
      layer,
      sim.players[i].playerIconSpriteId()
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
  of Lobby:
    sim.addProtocolLobbyActorSprites(currentIds, packet, layer)
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

proc buildFlagSprite(sim: SimServer): seq[uint8] {.measure.} =
  ## Builds the neutral flag sprite from the reused icon cell.
  buildSpriteProtocolRawSprite(sim.flagSprite)

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
  result.addSpriteChanged(
    spriteDefs,
    FlagSpriteId,
    sim.flagSprite.width,
    sim.flagSprite.height,
    sim.buildFlagSprite(),
    "flag"
  )
  result.addSpriteChanged(
    spriteDefs,
    CarrierBarSpriteBase,
    CarrierBarWidth,
    CarrierBarHeight,
    buildCarrierBarSprite(CarrierBarColor),
    "carrier indicator"
  )
  for i in 0 ..< PlayerColors.len:
    result.addSpriteChanged(
      spriteDefs,
      TrailDotSpriteBase + i,
      TrailDotSize,
      TrailDotSize,
      buildTrailDotSprite(PlayerColors[i]),
      "trail " & playerColorName(i)
    )
  result.addSpriteChanged(
    spriteDefs,
    TracerDotSpriteId,
    TracerDotSize,
    TracerDotSize,
    buildTracerDotSprite(),
    "shot tracer"
  )
  sim.addSpriteProtocolInterstitialSprites(spriteDefs, result)
  sim.addPlayerActorSprites(spriteDefs, result, selected = true)

proc buildSpriteProtocolPlayerInit(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition]
): seq[uint8] {.measure.} =
  ## Builds the initial sprite player snapshot.
  result = @[]
  result.addU8(0x04)
  let mapPixels = sim.buildMapSpritePixels()
  result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
  result.addViewport(MapLayerId, ScreenWidth, ScreenHeight)
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
  result.addSpriteChanged(
    spriteDefs,
    FlagSpriteId,
    sim.flagSprite.width,
    sim.flagSprite.height,
    sim.buildFlagSprite(),
    "flag"
  )
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
  result.addSpriteChanged(
    spriteDefs,
    SpritePlayerArrowSpriteId,
    1,
    1,
    buildSolidSprite(1, 1, 8'u8),
    "flag arrow"
  )
  result.addSpriteChanged(
    spriteDefs,
    CarrierBarSpriteBase,
    CarrierBarWidth,
    CarrierBarHeight,
    buildCarrierBarSprite(CarrierBarColor),
    "carrier indicator"
  )
  result.addSpriteChanged(
    spriteDefs,
    TracerDotSpriteId,
    TracerDotSize,
    TracerDotSize,
    buildTracerDotSprite(),
    "shot tracer"
  )
  sim.addSpriteProtocolInterstitialSprites(spriteDefs, result)
  sim.addPlayerActorSprites(spriteDefs, result, selected = false)

proc spriteObjectId(player: Player): int =
  ## Returns the stable global protocol object id for a player.
  PlayerObjectBase + player.joinOrder

proc spriteCarrierBarObjectId(player: Player): int =
  ## Returns the stable global protocol object id for a carrier bar.
  CarrierBarObjectBase + player.joinOrder

proc spriteCarrierBarSpriteId(player: Player): int =
  ## Returns the global protocol sprite id for one carrier bar.
  CarrierBarSpriteBase

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

proc scoreboardTeamTag(player: Player): string =
  ## Returns the compact scoreboard team tag for one player.
  case player.team
  of Red:
    "red"
  of Blue:
    "blue"

proc scoreboardName(player: Player): string =
  ## Returns the clickable scoreboard player label.
  player.playerLabelText() & " (" & player.scoreboardTeamTag() & ")"

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

proc spriteTrailDotObjectId(joinOrder, dotIndex: int): int =
  ## Returns the stable global protocol object id for a trail dot.
  TrailDotObjectBase + joinOrder * TrailMaxDots + dotIndex

proc spritePlayerX(player: Player): int =
  ## Returns the global viewer x position for a player sprite.
  player.x - SpriteDrawOffX - 1

proc spritePlayerY(player: Player): int =
  ## Returns the global viewer y position for a player sprite.
  player.y - SpriteDrawOffY - 1

proc trailCenter(player: Player): tuple[x, y: int] =
  ## Returns the map position used for a player's trail.
  (
    x: player.x + CollisionW div 2,
    y: player.y + CollisionH div 2
  )

proc trailIndex(state: GlobalViewerState, joinOrder: int): int =
  ## Returns the trail index for one player join order.
  for i in 0 ..< state.trails.len:
    if state.trails[i].joinOrder == joinOrder:
      return i
  -1

proc playerExists(sim: SimServer, joinOrder: int): bool =
  ## Returns true when a player join order is still present.
  for player in sim.players:
    if player.joinOrder == joinOrder:
      return true
  false

proc updateTrails(state: var GlobalViewerState, sim: SimServer) {.measure.} =
  ## Updates global-only player trails from current player positions.
  for i in countdown(state.trails.high, 0):
    if not sim.playerExists(state.trails[i].joinOrder):
      state.trails.delete(i)

  for player in sim.players:
    let
      center = player.trailCenter()
      colorIndex = playerColorIndex(player.color)
    var index = state.trailIndex(player.joinOrder)
    if index < 0:
      state.trails.add PlayerTrail(
        joinOrder: player.joinOrder,
        lastX: center.x,
        lastY: center.y,
        dots: @[TrailDot(
          x: center.x,
          y: center.y,
          colorIndex: colorIndex
        )]
      )
      continue
    if distSq(
      center.x,
      center.y,
      state.trails[index].lastX,
      state.trails[index].lastY
    ) >= TrailDotSpacing * TrailDotSpacing:
      state.trails[index].dots.add TrailDot(
        x: center.x,
        y: center.y,
        colorIndex: colorIndex
      )
      state.trails[index].lastX = center.x
      state.trails[index].lastY = center.y
      while state.trails[index].dots.len > TrailMaxDots:
        state.trails[index].dots.delete(0)

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

proc addSpritePlayerFlagArrow(
  sim: SimServer,
  playerIndex: int,
  cameraX,
  cameraY: int,
  currentIds: var seq[int],
  packet: var seq[uint8]
) {.measure.} =
  ## Adds an off-screen direction marker pointing toward the flag.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let
    flagSx = sim.flagX - SpriteSize div 2 - cameraX
    flagSy = sim.flagY - SpriteSize div 2 - cameraY
  if flagSx + SpriteSize > 0 and flagSy + SpriteSize > 0 and
      flagSx < ScreenWidth and flagSy < ScreenHeight:
    return
  let
    player = sim.players[playerIndex]
    px = float(player.x + CollisionW div 2 - cameraX)
    py = float(player.y + CollisionH div 2 - cameraY)
    dx = float(sim.flagX - cameraX) - px
    dy = float(sim.flagY - cameraY) - py
  if abs(dx) < 0.5 and abs(dy) < 0.5:
    return
  var ex, ey: float
  let
    minX = 0.0
    maxX = float(ScreenWidth - 1)
    minY = 0.0
    maxY = float(ScreenHeight - 1)
  if abs(dx) > abs(dy):
    ex = if dx > 0: maxX else: minX
    ey = clamp(py + dy * (ex - px) / dx, minY, maxY)
  else:
    ey = if dy > 0: maxY else: minY
    ex = clamp(px + dx * (ey - py) / dy, minX, maxX)
  currentIds.add(SpritePlayerArrowObjectId)
  packet.addObject(
    SpritePlayerArrowObjectId,
    int(ex),
    int(ey),
    30000,
    MapLayerId,
    SpritePlayerArrowSpriteId
  )

proc addShotTracers(
  sim: SimServer,
  cameraX, cameraY: int,
  clipToFrame: bool,
  currentIds: var seq[int],
  packet: var seq[uint8]
) {.measure.} =
  ## Places bright tracer dots for each active shot from a fixed object pool.
  ## Map view passes camera (0, 0) and clipToFrame = false; the per-player POV
  ## passes its camera offset and clips dots outside the 128x128 window.
  var nextDot = 0
  for shotIndex in 0 ..< min(sim.recentShots.len, TracerMaxShots):
    let shot = sim.recentShots[shotIndex]
    let
      dx = shot.x1 - shot.x0
      dy = shot.y1 - shot.y0
      length = max(abs(dx), abs(dy))
      steps = max(1, length div TracerDotSpacing)
    for s in 0 .. steps:
      if nextDot >= TracerMaxDots:
        break
      let
        mx = shot.x0 + dx * s div steps
        my = shot.y0 + dy * s div steps
        px = mx - cameraX - TracerDotSize div 2
        py = my - cameraY - TracerDotSize div 2
      if clipToFrame and (
        px + TracerDotSize <= 0 or py + TracerDotSize <= 0 or
        px >= ScreenWidth or py >= ScreenHeight
      ):
        continue
      let objectId = TracerDotObjectBase + nextDot
      inc nextDot
      currentIds.add(objectId)
      packet.addObject(
        objectId,
        px,
        py,
        30005,
        MapLayerId,
        TracerDotSpriteId
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
      MapLayerId,
      SpritePlayerInterstitialSpriteId
    )
    sim.addProtocolTextSprites(
      nextState.spriteDefs,
      currentIds,
      result,
      MapLayerId,
      playerIndex
    )
    sim.addProtocolInterstitialActorSprites(
      nextState.spriteDefs,
      currentIds,
      result,
      MapLayerId,
      playerIndex
    )
  else:
    let
      player = sim.players[playerIndex]
      view = sim.playerView(playerIndex)
      cameraX = view.cameraX
      cameraY = view.cameraY
      viewerIsGhost = view.viewerIsGhost
    let
      shadowViewChanged =
        not nextState.shadowReady or
        nextState.shadowCameraX != cameraX or
        nextState.shadowCameraY != cameraY or
        nextState.shadowOriginMx != view.originMx or
        nextState.shadowOriginMy != view.originMy
      shadowChanged =
        if viewerIsGhost:
          false
        else:
          sim.usePlayerShadowMask(playerIndex, view)
    currentIds.add(MapObjectId)
    result.addObject(
      MapObjectId,
      -cameraX,
      -cameraY,
      low(int16),
      MapLayerId,
      MapSpriteId
    )
    if not viewerIsGhost:
      currentIds.add(SpritePlayerShadowObjectId)
      if shadowChanged or shadowViewChanged or
          nextState.spriteDefs.spriteDefinitionIndex(
            SpritePlayerShadowSpriteId
          ) < 0:
        result.addSpriteChanged(
          nextState.spriteDefs,
          SpritePlayerShadowSpriteId,
          ScreenWidth,
          ScreenHeight,
          sim.buildPlayerShadowSprite(cameraX, cameraY),
          "shadow",
          changed = shadowChanged or shadowViewChanged
        )
      nextState.shadowReady = true
      nextState.shadowCameraX = cameraX
      nextState.shadowCameraY = cameraY
      nextState.shadowOriginMx = view.originMx
      nextState.shadowOriginMy = view.originMy
      result.addObject(
        SpritePlayerShadowObjectId,
        0,
        0,
        SpritePlayerShadowZ,
        MapLayerId,
        SpritePlayerShadowSpriteId
      )
    else:
      nextState.shadowReady = false

    # The flag, when visible.
    if sim.screenPointVisible(view, sim.flagX, sim.flagY):
      currentIds.add(SpritePlayerFlagObjectId)
      result.addObject(
        SpritePlayerFlagObjectId,
        sim.flagX - SpriteSize div 2 - cameraX,
        sim.flagY - SpriteSize div 2 - cameraY,
        sim.flagY,
        MapLayerId,
        FlagSpriteId
      )

    for other in sim.players:
      if not view.screenPointInFrame(
        other.x + CollisionW div 2,
        other.y + CollisionH div 2
      ):
        continue
      if other.alive:
        if other.joinOrder != player.joinOrder:
          if not sim.screenPointVisible(
            view,
            other.x + CollisionW div 2,
            other.y + CollisionH div 2
          ):
            continue
      elif not viewerIsGhost:
        continue
      let objectId = other.spriteObjectId()
      currentIds.add(objectId)
      result.addObject(
        objectId,
        other.x - SpriteDrawOffX - 1 - cameraX,
        other.y - SpriteDrawOffY - 1 - cameraY,
        other.y,
        MapLayerId,
        other.spriteActorSpriteId(-1)
      )

    sim.addSpritePlayerFlagArrow(
      playerIndex,
      cameraX,
      cameraY,
      currentIds,
      result
    )

    sim.addShotTracers(cameraX, cameraY, clipToFrame = true, currentIds, result)

    # Fire-cooldown icon in the bottom-left corner.
    if player.alive:
      let
        fireIconX = 1
        fireIconY = ScreenHeight - SpriteSize - 1
      currentIds.add(SpritePlayerRemainingObjectId)
      result.addObject(
        SpritePlayerRemainingObjectId,
        fireIconX,
        fireIconY,
        30002,
        MapLayerId,
        if player.fireCooldown > 0:
          SpritePlayerFireShadowSpriteId
        else:
          SpritePlayerFireSpriteId
      )

    # Lives counter in the top-right corner.
    let
      livesText = "x" & $player.lives
      lives = sim.buildSpriteProtocolTextSprite([livesText], 2'u8)
      textX = ScreenWidth - lives.width
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
      textX,
      0,
      30003,
      MapLayerId,
      SpritePlayerRemainingSpriteId
    )

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

  nextState.updateTrails(sim)
  var currentIds: seq[int] = @[]
  sim.addScoreboard(
    nextState.spriteDefs,
    currentIds,
    result,
    nextState.selectedJoinOrder
  )
  for trail in nextState.trails:
    for i in 0 ..< trail.dots.len:
      let
        dot = trail.dots[i]
        objectId = spriteTrailDotObjectId(trail.joinOrder, i)
      currentIds.add(objectId)
      result.addObject(
        objectId,
        dot.x - TrailDotSize div 2,
        dot.y - TrailDotSize div 2,
        dot.y - 100,
        MapLayerId,
        TrailDotSpriteBase + dot.colorIndex
      )

  sim.addShotTracers(0, 0, clipToFrame = false, currentIds, result)

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
    if player.carryingFlag:
      let
        barObjectId = player.spriteCarrierBarObjectId()
        barSpriteId = player.spriteCarrierBarSpriteId()
        barX = player.spritePlayerX() +
          (crew.width + 2 - CarrierBarWidth) div 2
        barY = player.spritePlayerY() - CarrierBarYOffset
      currentIds.add(barObjectId)
      result.addObject(
        barObjectId,
        barX,
        barY,
        30001,
        MapLayerId,
        barSpriteId
      )

    if sim.config.showPlayerLabels:
      let
        labelLines = playerLabelLines(sim, player, playerIndex)
        label = sim.buildSpriteProtocolTextSprite(
          labelLines,
          PlayerNameColor
        )
        labelSpriteId = player.spritePlayerNameSpriteId()
        labelObjectId = player.spritePlayerNameObjectId()
        labelX = player.spritePlayerX() +
          (crew.width + 2 - label.width) div 2
        labelY = player.spritePlayerY() - CarrierBarYOffset -
          label.height - 1
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

  # The flag, when loose on the ground (carried flags ride the carrier sprite).
  if sim.flagCarrier < 0:
    currentIds.add(FlagObjectId)
    result.addObject(
      FlagObjectId,
      sim.flagX - SpriteSize div 2,
      sim.flagY - SpriteSize div 2,
      sim.flagY,
      MapLayerId,
      FlagSpriteId
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
