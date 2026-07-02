import
  std/[json, math, os, random, strutils],
  bitworld/aseprite, bitworld/client as bitworldClient,
  bitworld/pixelfonts, bitworld/profile, bitworld/spriteprotocol,
  bitworld/server,
  jsony, pixie

const
  GameName* = "ctf"
  GameVersion* = "1"
  ReplayFps* = 24
  DefaultMapPath* = "arena"
  DarkBgPath* = "data/darkbg.aseprite"
  SpriteSheetAsepritePath = "data/spritesheet.aseprite"
  MapWidth* = 1235
  MapHeight* = 659
  SpriteSize* = 12
  CrewSpriteSize* = 16
  CrewSpriteVariants* = 8
  CollisionW* = 1
  CollisionH* = 1
  PlayerHalf* = 6             ## half-extent of the solid player footprint, in px.
  SpriteDrawOffX* = 8
  SpriteDrawOffY* = 8
  MotionScale* = 256
  Accel* = 76
  FrictionNum* = 144
  FrictionDen* = 256
  MaxSpeed* = 704
  StopThreshold* = 8
  MovementSlideMaxScan = 3
  TargetFps* = 24
  SpaceColor* = 0'u8
  MapVoidColor* = 12'u8
  TintColor* = 3'u8
  ShadeTintColor* = 9'u8
  OutlineColor* = 0'u8

  # CTF tuning defaults (RULES.md). Second-based values convert at 24 ticks/sec.
  Lives* = 3
  RespawnTicks* = 72          ## ~3s before respawning at home.
  SpawnProtectTicks* = 24     ## ~1s spawn invulnerability.
  GunRange* = 1300            ## px, effectively map-wide; LOS and the cone are the real limits.
  GunConeDeg* = 25            ## firing cone half-angle in degrees.
  FireCooldownTicks* = 12     ## ~0.5s between shots.
  ShotFxTicks* = 12           ## ~0.5s a shot tracer stays visible (cosmetic only).
  SplatterFxTicks* = 120      ## ~5s a death splatter stays visible (cosmetic only).
  CarrierSpeedPct* = 70       ## carrier moves at 70% speed.

  StartWaitTicks* = 5 * TargetFps
  GameOverTicks* = 360
  MaxTicks* = 10_000  ## 0 = no limit.
  MaxGames* = 0  ## 0 = no limit.
  MaxPlayers* = 16
  MinPlayers* = 16

  WinReward* = 100

  FlagPickupRange* = 12       ## touch radius to pick up a loose flag.
  CaptureZoneWidth* = 40      ## width of each home-edge capture zone.

  TextColor* = 2'u8
  TextLineHeight* = 7
  MapSpriteId* = 1
  MapObjectId* = 1
  MapLayerId* = 0
  MapLayerType* = 0
  TopLeftLayerId* = 1
  TopLeftLayerType* = 1
  BottomRightLayerId* = 3
  BottomRightLayerType* = 3
  ZoomableLayerFlag* = 1
  UiLayerFlag* = 2
  PlayerSpriteBase* = 100
  FlagSpriteId* = 700
  SelectedPlayerSpriteBase* = 800
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

type
  Team* = enum
    Red
    Blue

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
    ## thickness between two endpoints.
    case kind*: ArenaShapeKind
    of shapeRect:
      rect*: MapRect
    of shapeDisc, shapeDiamond:
      cx*, cy*, radius*: int
    of shapeDiagonal:
      x0*, y0*, x1*, y1*, thickness*: int

  MapPoint* = object
    x*, y*: int

  CtfMap* = object
    name*: string
    path*: string
    width*, height*: int
    mapLayer*, walkLayer*, wallLayer*: int
    center*: MapPoint
    rooms*: seq[Room]

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
    hasTeam*: bool
    hasColor*: bool

  GameConfig* = object
    motionScale*: int
    accel*: int
    frictionNum*: int
    frictionDen*: int
    maxSpeed*: int
    stopThreshold*: int
    seed*: int
    speed*: int
    lives*: int
    respawnTicks*: int
    spawnProtectTicks*: int
    gunRange*: int
    gunConeDeg*: int
    fireCooldownTicks*: int
    carrierSpeedPct*: int
    minPlayers*: int
    startWaitTicks*: int
    gameOverTicks*: int
    maxTicks*: int
    maxGames*: int
    showPlayerLabels*: bool
    mapPath*: string
    closedRoster*: bool
    slots*: seq[PlayerSlotConfig]

  Player* = object
    x*, y*: int
    homeX*, homeY*: int
    velX*, velY*: int
    carryX*, carryY*: int
    flipH*: bool
    facingDx*, facingDy*: int
    team*: Team
    alive*: bool
    lives*: int
    respawnTimer*: int
    fireCooldown*: int
    spawnProtect*: int
    carryingFlag*: bool
    joinOrder*: int
    address*: string
    color*: uint8
    reward*: int
    kills*: int
    deaths*: int
    captures*: int

  ShadowPathCache = object
    ready: bool
    originSx, originSy: int
    starts: seq[int]
    offsets: seq[int32]
    xs, ys: seq[int16]

  PlayerShadowMask = object
    valid: bool
    cameraX, cameraY: int
    originMx, originMy: int
    mask: seq[bool]

  ShotFx* = object
    ## A cosmetic shot tracer segment; never enters gameHash (replay-safe).
    x0*, y0*, x1*, y1*: int
    firedTick*: int
    color*: uint8

  SplatterFx* = object
    ## A cosmetic death splatter mark; never enters gameHash (replay-safe).
    x*, y*: int
    tick*: int
    color*: uint8

  SimServer* = object
    config*: GameConfig
    players*: seq[Player]
    rewardAccounts*: seq[RewardAccount]
    crewSprites*: seq[CrewSprite]
    flagSprite*: Sprite
    gameMap*: CtfMap
    rooms*: seq[Room]
    flagX*, flagY*: int
    flagCarrier*: int          ## player index carrying the flag, -1 when loose.
    mapPixels*: seq[uint8]
    mapRgba*: seq[uint8]
    darkBgPixels*: seq[uint8]
    walkMask*: seq[bool]
    wallMask*: seq[bool]
    shadowBuf*: seq[bool]
    shadowCaches: seq[PlayerShadowMask]
    rng*: Rand
    nextJoinOrder*: int
    tickCount*: int
    recentShots*: seq[ShotFx]  ## cosmetic shot tracers; excluded from gameHash.
    splatters*: seq[SplatterFx]  ## cosmetic death splatters; excluded from gameHash.
    gameStartTick*: int
    startWaitTimer*: int
    phase*: GamePhase
    asciiSprites*: PixelFont
    winner*: Team
    gameOverTimer*: int
    timeLimitReached*: bool
    isDraw*: bool
    needsReregister*: bool
    gameEventLoggingEnabled*: bool
    lastLobbyPlayersLogged*: int
    lastLobbyNeededLogged*: int
    lastLobbySecondsLogged*: int

  PlayerView* = object
    cameraX*, cameraY*: int
    originMx*, originMy*: int
    viewerIsGhost*: bool

const
  SpritePlayerObservationHeaderFeatures = 4
  SpritePlayerObservationGridSize = 32
  SpritePlayerObservationGridFeatures = SpritePlayerObservationGridSize * SpritePlayerObservationGridSize
  SpritePlayerObservationPlayerSlots = MaxPlayers
  SpritePlayerObservationPlayerFeatures = 4
  SpritePlayerObservationFlagSlots = 1
  SpritePlayerObservationFlagFeatures = 4
  SpritePlayerObservationArrowSlots = 1
  SpritePlayerObservationArrowFeatures = 5
  SpritePlayerObservationGridOffset = SpritePlayerObservationHeaderFeatures
  SpritePlayerObservationPlayerOffset = SpritePlayerObservationGridOffset + SpritePlayerObservationGridFeatures
  SpritePlayerObservationFlagOffset =
    SpritePlayerObservationPlayerOffset + SpritePlayerObservationPlayerSlots * SpritePlayerObservationPlayerFeatures
  SpritePlayerObservationArrowOffset =
    SpritePlayerObservationFlagOffset + SpritePlayerObservationFlagSlots * SpritePlayerObservationFlagFeatures
  SpritePlayerObservationFeatures* =
    SpritePlayerObservationArrowOffset + SpritePlayerObservationArrowSlots * SpritePlayerObservationArrowFeatures

  RenderHeaderFireIcon = 1
  RenderHeaderLives = 2

  RenderPlayerFlagsFeature = 3
  RenderFlagFlagsFeature = 3
  RenderArrowFlagsFeature = 4

  RenderPlayerPresent = 1'u8
  RenderPlayerAlive = 4'u8
  RenderPlayerFlipH = 16'u8
  RenderPlayerGhost = 32'u8
  RenderPlayerCarrier = 64'u8

  RenderFlagLoose = 1'u8
  RenderFlagCarried = 2'u8

  RenderArrowVisible = 2'u8

var
  ShadowPaths: ShadowPathCache

proc gameDir*(): string =
  ## Returns the CTF game directory.
  getCurrentDir()

proc clientDataDir*(): string =
  ## Returns the shared client data directory.
  bitworldClient.clientDir() / "data"

proc spriteSheetPath(): string =
  ## Returns the sprite sheet aseprite path.
  gameDir() / SpriteSheetAsepritePath

proc loadSpriteSheet*(): Image =
  ## Loads the sprite sheet from aseprite.
  readAsepriteImage(spriteSheetPath())

proc crewSheetPath(): string =
  ## Returns the crew sprite sheet path.
  let path = clientDataDir() / "crew.aseprite"
  if fileExists(path):
    return path
  gameDir() / "data" / "crew.aseprite"

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
    image = readAsepriteImage(path)
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
  if gameMap.width != MapWidth or gameMap.height != MapHeight:
    raise newException(
      CtfError,
      "Map dimensions must be " & $MapWidth & "x" & $MapHeight & "."
    )
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
  ArenaBorder = 10             ## perimeter wall thickness in px.
  ArenaFlagRing = 70           ## clear radius around the center flag.
  ArenaCaptureClear = 210      ## x-columns kept traversable for carriers.
  ArenaSpawnClearW = 70        ## half-width of the open spawn pockets.
  ArenaSpawnClearH = 130       ## half-height of the open spawn pockets.

  ArenaFloor = rgba(24, 26, 34, 255)      ## dark walkable floor.
  ArenaWall = rgba(96, 104, 128, 255)     ## lighter, distinct wall.
  ArenaBorderColor = rgba(60, 66, 84, 255)
  ArenaRedTint = rgba(120, 40, 44, 70)    ## territory wash over Red half.
  ArenaBlueTint = rgba(44, 60, 128, 70)   ## territory wash over Blue half.
  ArenaPedestal = rgba(210, 200, 120, 255)

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
  ## rect/diamond stubs flanking the flag ring. The chevron pair straddling
  ## the horizontal midline closes the mid lane outside the flag ring; the
  ## ring itself stays an open disc for close flag fights. Shapes sit
  ## between the capture/spawn columns and the flag ring; isProtectedFloor
  ## carves them out of the ring, pockets, and capture columns.
  ArenaLeftObstacles = [
    # Column 1 (x=268..286): rect stubs, phase 0, border-attached ends.
    ArenaShape(kind: shapeRect, rect: MapRect(x: 268, y: 10, w: 18, h: 62)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 268, y: 108, w: 18, h: 60)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 268, y: 204, w: 18, h: 60)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 268, y: 300, w: 18, h: 59)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 268, y: 395, w: 18, h: 60)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 268, y: 491, w: 18, h: 60)),
    ArenaShape(kind: shapeRect, rect: MapRect(x: 268, y: 587, w: 18, h: 62)),
    # Column 2 (x=349): diamonds, phase +48 (half period) vs column 1.
    ArenaShape(kind: shapeDiamond, cx: 349, cy: 90, radius: 28),
    ArenaShape(kind: shapeDiamond, cx: 349, cy: 186, radius: 28),
    ArenaShape(kind: shapeDiamond, cx: 349, cy: 282, radius: 28),
    ArenaShape(kind: shapeDiamond, cx: 349, cy: 376, radius: 28),
    ArenaShape(kind: shapeDiamond, cx: 349, cy: 472, radius: 28),
    ArenaShape(kind: shapeDiamond, cx: 349, cy: 568, radius: 28),
    # Column 3 (x=421): discs, phase +24.
    ArenaShape(kind: shapeDisc, cx: 421, cy: 66, radius: 28),
    ArenaShape(kind: shapeDisc, cx: 421, cy: 162, radius: 28),
    ArenaShape(kind: shapeDisc, cx: 421, cy: 258, radius: 28),
    ArenaShape(kind: shapeDisc, cx: 421, cy: 400, radius: 28),
    ArenaShape(kind: shapeDisc, cx: 421, cy: 496, radius: 28),
    ArenaShape(kind: shapeDisc, cx: 421, cy: 592, radius: 28),
    # Column 4 (x=479..509): 45-degree chevron walls, phase +72; the pair
    # straddling the midline forms one continuous zigzag that closes the
    # old mid lane at mid range.
    ArenaShape(kind: shapeDiagonal, x0: 479, y0: 86, x1: 507, y1: 114, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 507, y0: 114, x1: 479, y1: 142, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 507, y0: 182, x1: 479, y1: 210, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 479, y0: 210, x1: 507, y1: 238, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 479, y0: 276, x1: 506, y1: 303, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 506, y0: 303, x1: 479, y1: 330, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 479, y0: 329, x1: 506, y1: 356, thickness: 12),
    ArenaShape(kind: shapeDiagonal, x0: 506, y0: 356, x1: 479, y1: 383, thickness: 12),
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

proc arenaCtfMap(): CtfMap =
  ## Returns the procedurally-defined symmetric arena metadata.
  result.name = ArenaName
  result.path = ArenaName
  result.width = MapWidth
  result.height = MapHeight
  result.mapLayer = 0
  result.walkLayer = 1
  result.wallLayer = 2
  result.center = MapPoint(x: MapWidth div 2, y: MapHeight div 2)
  result.rooms = @[
    Room(name: "Center", x: MapWidth div 2 - 80, y: MapHeight div 2 - 80,
         w: 160, h: 160),
    Room(name: "Red Base", x: 0, y: MapHeight div 2 - 130,
         w: ArenaCaptureClear, h: 260),
    Room(name: "Blue Base", x: MapWidth - ArenaCaptureClear,
         y: MapHeight div 2 - 130, w: ArenaCaptureClear, h: 260),
  ]
  result.validateMap()

proc loadCtfMap*(path = ""): CtfMap =
  ## Returns the procedurally-generated symmetric CTF arena.
  arenaCtfMap()

proc loadCtfMapMetadata*(path = ""): CtfMap =
  ## Returns arena metadata (same as loadCtfMap; nothing is read from disk).
  arenaCtfMap()

proc mirrorX(rect: MapRect): MapRect =
  ## Mirrors one rectangle across the vertical center line.
  MapRect(x: MapWidth - rect.x - rect.w, y: rect.y, w: rect.w, h: rect.h)

proc mirrorX(shape: ArenaShape): ArenaShape =
  ## Mirrors one arena shape across the vertical center line.
  case shape.kind
  of shapeRect:
    ArenaShape(kind: shapeRect, rect: shape.rect.mirrorX())
  of shapeDisc:
    ArenaShape(
      kind: shapeDisc,
      cx: MapWidth - 1 - shape.cx,
      cy: shape.cy,
      radius: shape.radius
    )
  of shapeDiamond:
    ArenaShape(
      kind: shapeDiamond,
      cx: MapWidth - 1 - shape.cx,
      cy: shape.cy,
      radius: shape.radius
    )
  of shapeDiagonal:
    ArenaShape(
      kind: shapeDiagonal,
      x0: MapWidth - 1 - shape.x0,
      y0: shape.y0,
      x1: MapWidth - 1 - shape.x1,
      y1: shape.y1,
      thickness: shape.thickness
    )

proc inRect(x, y: int, rect: MapRect): bool =
  ## Returns true when (x, y) lies inside the rectangle.
  x >= rect.x and x < rect.x + rect.w and
    y >= rect.y and y < rect.y + rect.h

proc inShape(x, y: int, shape: ArenaShape): bool =
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
      let
        vx = shape.x1 - shape.x0
        vy = shape.y1 - shape.y0
        wx = x - shape.x0
        wy = y - shape.y0
        len2 = vx * vx + vy * vy
        t = clamp(wx * vx + wy * vy, 0, len2)
        dx = wx * len2 - t * vx
        dy = wy * len2 - t * vy
      dx * dx + dy * dy <=
        shape.thickness * shape.thickness * len2 * len2 div 4

const ArenaObstacles = block:
  ## The full obstacle set: every left-half shape plus its x-mirror,
  ## precomputed once so the per-pixel wall test never re-mirrors.
  var shapes: seq[ArenaShape]
  for shape in ArenaLeftObstacles:
    shapes.add shape
    shapes.add shape.mirrorX()
  shapes

proc isProtectedFloor(x, y, cx, cy: int): bool =
  ## Regions that MUST stay walkable: the flag ring, both spawn pockets,
  ## and the two home capture columns. Walls are never carved here.
  if x < ArenaCaptureClear or x >= MapWidth - ArenaCaptureClear:
    return true
  let
    dx = x - cx
    dy = y - cy
  if dx * dx + dy * dy <= ArenaFlagRing * ArenaFlagRing:
    return true
  for homeX in [186, 1049]:
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

proc overTint(base, tint: ColorRGBA): ColorRGBA =
  ## Alpha-composites a translucent tint over an opaque base color.
  let a = tint.a.int
  rgba(
    uint8((base.r.int * (255 - a) + tint.r.int * a) div 255),
    uint8((base.g.int * (255 - a) + tint.g.int * a) div 255),
    uint8((base.b.int * (255 - a) + tint.b.int * a) div 255),
    255
  )

proc loadMapLayers*(gameMap: CtfMap): tuple[mapImage, walkImage, wallImage: Image] =
  ## Builds the visual map plus the walk and wall masks for the arena.
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
  for y in 0 ..< h:
    for x in 0 ..< w:
      let
        onBorder = x < ArenaBorder or y < ArenaBorder or
          x >= w - ArenaBorder or y >= h - ArenaBorder
        wall = isArenaWall(x, y, cx, cy)
      var color =
        if onBorder: ArenaBorderColor
        elif wall: ArenaWall
        else: ArenaFloor
      if not wall:
        ## Team territory wash on the readable floor.
        if x < cx:
          color = overTint(color, ArenaRedTint)
        else:
          color = overTint(color, ArenaBlueTint)
      result.mapImage[x, y] = color
      result.walkImage[x, y] = if wall: clear else: opaque
      result.wallImage[x, y] = if wall: opaque else: clear
  ## Draw a small pedestal marker at the flag center (stays walkable).
  for dy in -4 .. 4:
    for dx in -4 .. 4:
      if dx * dx + dy * dy <= 16:
        result.mapImage[cx + dx, cy + dy] = ArenaPedestal

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
    seed: 0xA6019,
    speed: 1,
    lives: Lives,
    respawnTicks: RespawnTicks,
    spawnProtectTicks: SpawnProtectTicks,
    gunRange: GunRange,
    gunConeDeg: GunConeDeg,
    fireCooldownTicks: FireCooldownTicks,
    carrierSpeedPct: CarrierSpeedPct,
    minPlayers: MinPlayers,
    startWaitTicks: StartWaitTicks,
    gameOverTicks: GameOverTicks,
    maxTicks: MaxTicks,
    maxGames: MaxGames,
    showPlayerLabels: true,
    mapPath: DefaultMapPath,
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
  if config.gunRange <= 0:
    raise newException(CtfError, "Config field gunRange must be positive.")
  if config.gunConeDeg < 0 or config.gunConeDeg > 180:
    raise newException(CtfError, "Config field gunConeDeg must be between 0 and 180.")
  if config.carrierSpeedPct <= 0 or config.carrierSpeedPct > 100:
    raise newException(CtfError, "Config field carrierSpeedPct must be 1..100.")
  if config.speed notin [1, 2, 3, 4, 8, 16]:
    raise newException(
      CtfError,
      "Config field speed must be 1, 2, 3, 4, 8, or 16."
    )
  if config.startWaitTicks < 0:
    raise newException(CtfError, "Config field startWaitTicks must be non-negative.")
  if config.respawnTicks < 0 or config.spawnProtectTicks < 0 or
      config.fireCooldownTicks < 0:
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
  node.readConfigInt("seed", config.seed)
  node.readConfigInt("speed", config.speed)
  node.readConfigInt("lives", config.lives)
  node.readConfigInt("respawnTicks", config.respawnTicks)
  node.readConfigInt("spawnProtectTicks", config.spawnProtectTicks)
  node.readConfigInt("gunRange", config.gunRange)
  node.readConfigInt("gunConeDeg", config.gunConeDeg)
  node.readConfigInt("fireCooldownTicks", config.fireCooldownTicks)
  node.readConfigInt("carrierSpeedPct", config.carrierSpeedPct)
  node.readConfigInt("minPlayers", config.minPlayers)
  node.readConfigInt("startWaitTicks", config.startWaitTicks)
  node.readConfigInt("gameStartWaitTicks", config.startWaitTicks)
  node.readConfigInt("gameOverTicks", config.gameOverTicks)
  node.readConfigInt("maxTicks", config.maxTicks)
  node.readConfigInt("maxGameTicks", config.maxTicks)
  node.readConfigInt("maxGames", config.maxGames)
  node.readConfigBool("showPlayerLabels", config.showPlayerLabels)
  node.readConfigString("map", config.mapPath)
  node.readConfigString("mapPath", config.mapPath)
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
    slots.add(item)
  var node = %*{
    "motionScale": config.motionScale,
    "accel": config.accel,
    "frictionNum": config.frictionNum,
    "frictionDen": config.frictionDen,
    "maxSpeed": config.maxSpeed,
    "stopThreshold": config.stopThreshold,
    "seed": config.seed,
    "speed": config.speed,
    "lives": config.lives,
    "respawnTicks": config.respawnTicks,
    "spawnProtectTicks": config.spawnProtectTicks,
    "gunRange": config.gunRange,
    "gunConeDeg": config.gunConeDeg,
    "fireCooldownTicks": config.fireCooldownTicks,
    "carrierSpeedPct": config.carrierSpeedPct,
    "minPlayers": config.minPlayers,
    "startWaitTicks": config.startWaitTicks,
    "gameOverTicks": config.gameOverTicks,
    "maxTicks": config.maxTicks,
    "maxGameTicks": config.maxTicks,
    "maxGames": config.maxGames,
    "mapPath": config.mapPath,
    "closedRoster": config.closedRoster,
    "showPlayerLabels": config.showPlayerLabels,
    "tokens": tokens,
    "slots": slots
  }
  if includePlayers:
    node["players"] = players
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

proc teamText(team: Team): string =
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

proc lobbyIconStartY*(sim: SimServer): int =
  ## Returns the lobby icon row y coordinate.
  if sim.lobbyIsStarting(): 32 else: 26

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
  result.mixHashBool(sim.isDraw)
  result.mixHashBool(sim.needsReregister)
  result.mixHashInt(sim.nextJoinOrder)
  result.mixHashInt(sim.flagX)
  result.mixHashInt(sim.flagY)
  result.mixHashInt(sim.flagCarrier)
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
    result.mixHashInt(player.facingDx)
    result.mixHashInt(player.facingDy)
    result.mixHashInt(ord(player.team))
    result.mixHashBool(player.alive)
    result.mixHashInt(player.lives)
    result.mixHashInt(player.respawnTimer)
    result.mixHashInt(player.fireCooldown)
    result.mixHashInt(player.spawnProtect)
    result.mixHashBool(player.carryingFlag)
    result.mixHashInt(player.joinOrder)
    result.mixHashInt(int(player.color))
    result.mixHashInt(player.reward)
    result.mixHashInt(player.kills)
    result.mixHashInt(player.deaths)
    result.mixHashInt(player.captures)

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
  case team
  of Red:
    sim.gameMap.center.x - (sim.gameMap.center.x * 7 div 10)
  of Blue:
    sim.gameMap.center.x + ((MapWidth - sim.gameMap.center.x) * 7 div 10)

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

proc resetPlayerToHome*(sim: var SimServer, playerIndex: int) =
  ## Moves one player back to its team home spawn position.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  sim.players[playerIndex].x = sim.players[playerIndex].homeX
  sim.players[playerIndex].y = sim.players[playerIndex].homeY
  sim.players[playerIndex].velX = 0
  sim.players[playerIndex].velY = 0
  sim.players[playerIndex].carryX = 0
  sim.players[playerIndex].carryY = 0

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

proc resetFlag*(sim: var SimServer) =
  ## Returns the flag to the center, loose.
  sim.flagX = sim.gameMap.center.x
  sim.flagY = sim.gameMap.center.y
  sim.flagCarrier = -1

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

proc findSpawn*(sim: SimServer): tuple[x, y: int] =
  ## Returns the next lobby spawn position.
  let order = sim.players.len
  sim.spawnPosition(sim.teamForSlot(order), order div 2)

proc playerSlotLimit(config: GameConfig): int =
  ## Returns the number of slots players may occupy.
  if config.closedRoster: config.slots.len else: MaxPlayers

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
  if sim.flagCarrier == playerIndex:
    sim.logGameEvent("flag returned to center")
    sim.resetFlag()
  elif sim.flagCarrier > playerIndex:
    dec sim.flagCarrier
  sim.players.delete(playerIndex)
  if playerIndex < sim.shadowCaches.len:
    sim.shadowCaches.delete(playerIndex)

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
    facingDx: (if team == Red: 1 else: -1),
    facingDy: 0,
    team: team,
    alive: true,
    lives: sim.config.lives,
    joinOrder: order,
    address: address,
    color: color,
    reward: sim.rewardAccounts[accountIndex].reward
  )
  sim.shadowCaches.add PlayerShadowMask(
    valid: false,
    mask: newSeq[bool](ScreenWidth * ScreenHeight)
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
  results["names"] = names
  results["scores"] = scores
  results["win"] = win
  results["team"] = teamList
  results["kills"] = killsList
  results["deaths"] = deathsList
  results["captures"] = capturesList
  $results

proc startGame*(sim: var SimServer) =
  sim.logGameEvent("game started: players=" & $sim.players.len)
  sim.recentShots = @[]
  sim.splatters = @[]
  sim.arrangeHomePositions()
  for i in 0 ..< sim.players.len:
    sim.players[i].alive = true
    sim.players[i].lives = sim.config.lives
    sim.players[i].respawnTimer = 0
    sim.players[i].fireCooldown = 0
    sim.players[i].spawnProtect = sim.config.spawnProtectTicks
    sim.players[i].carryingFlag = false
    sim.players[i].kills = 0
    sim.players[i].deaths = 0
    sim.players[i].captures = 0
    sim.recordGameTeamAssigned(i)
  sim.resetFlag()
  sim.phase = Playing
  sim.gameStartTick = sim.tickCount
  sim.timeLimitReached = false
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

proc canSlideHorizontal(
  sim: SimServer,
  x, y, step, offset: int
): bool =
  ## Returns true when a horizontal step can slide by one offset.
  if offset == 0:
    return false
  let slideStep = signOf(offset)
  for i in 1 .. abs(offset):
    if not sim.canOccupy(x, y + slideStep * i):
      return false
  sim.canOccupy(x + step, y + offset)

proc canSlideVertical(
  sim: SimServer,
  x, y, step, offset: int
): bool =
  ## Returns true when a vertical step can slide by one offset.
  if offset == 0:
    return false
  let slideStep = signOf(offset)
  for i in 1 .. abs(offset):
    if not sim.canOccupy(x + slideStep * i, y):
      return false
  sim.canOccupy(x + offset, y + step)

proc trySlideOffset(
  sim: SimServer,
  player: var Player,
  step, offset: int,
  horizontal: bool
): bool =
  ## Tries one candidate slide offset for a blocked movement step.
  if horizontal:
    if not sim.canSlideHorizontal(player.x, player.y, step, offset):
      return false
    player.x += step
    player.y += offset
  else:
    if not sim.canSlideVertical(player.x, player.y, step, offset):
      return false
    player.x += offset
    player.y += step
  true

proc trySlideMove(
  sim: SimServer,
  player: var Player,
  step, radius, preferredSlide: int,
  horizontal: bool
): bool =
  ## Tries nearby slide offsets for one blocked movement step.
  if radius <= 0:
    return false
  let preferred = signOf(preferredSlide)
  for distance in 1 .. radius:
    if preferred != 0:
      if sim.trySlideOffset(
        player,
        step,
        preferred * distance,
        horizontal
      ):
        return true
      if sim.trySlideOffset(
        player,
        step,
        -preferred * distance,
        horizontal
      ):
        return true
    else:
      if sim.trySlideOffset(player, step, -distance, horizontal):
        return true
      if sim.trySlideOffset(player, step, distance, horizontal):
        return true
  false

proc applyMomentumAxis(
  sim: SimServer,
  player: var Player,
  carry: var int,
  velocity, preferredSlide: int,
  horizontal: bool
) =
  ## Applies one fixed-point movement axis with collision sliding.
  carry += velocity
  while abs(carry) >= sim.config.motionScale:
    let step = if carry < 0: -1 else: 1
    let
      nx = if horizontal: player.x + step else: player.x
      ny = if horizontal: player.y else: player.y + step
    if sim.canOccupy(nx, ny):
      if horizontal:
        player.x = nx
      else:
        player.y = ny
      carry -= step * sim.config.motionScale
    else:
      let radius = sim.slideScanRadius(carry, velocity)
      if sim.trySlideMove(
        player,
        step,
        radius,
        preferredSlide,
        horizontal
      ):
        carry -= step * sim.config.motionScale
      else:
        carry = 0
        break

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

proc lineOfSightClear(sim: SimServer, ax, ay, bx, by: int): bool =
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

proc killPlayer(sim: var SimServer, targetIndex, killerIndex: int) =
  ## Applies a fatal hit: return the flag to center, decrement lives, start
  ## respawn.
  if targetIndex < 0 or targetIndex >= sim.players.len:
    return
  if not sim.players[targetIndex].alive:
    return
  sim.logGameEvent(
    playerColorText(sim.players[targetIndex].color) &
      " killed by " & sim.playerText(killerIndex)
  )
  if sim.players[targetIndex].carryingFlag or sim.flagCarrier == targetIndex:
    sim.players[targetIndex].carryingFlag = false
    sim.logGameEvent("flag returned to center")
    sim.resetFlag()
  # Leave a cosmetic splatter at the death spot (never enters gameHash).
  sim.splatters.add SplatterFx(
    x: sim.players[targetIndex].x,
    y: sim.players[targetIndex].y,
    tick: sim.tickCount,
    color: sim.players[targetIndex].color
  )
  sim.players[targetIndex].alive = false
  sim.players[targetIndex].velX = 0
  sim.players[targetIndex].velY = 0
  sim.players[targetIndex].carryX = 0
  sim.players[targetIndex].carryY = 0
  sim.recordDeath(targetIndex)
  if sim.players[targetIndex].lives > 0:
    dec sim.players[targetIndex].lives
  sim.players[targetIndex].respawnTimer =
    if sim.players[targetIndex].lives > 0:
      max(1, sim.config.respawnTicks)
    else:
      0

proc tryFire*(sim: var SimServer, shooterIndex: int) =
  ## Casts a hitscan shot along the shooter's facing and kills the first
  ## valid target in range, cone, and clear line of sight (friendly fire on).
  if shooterIndex < 0 or shooterIndex >= sim.players.len:
    return
  let shooter = sim.players[shooterIndex]
  if not shooter.alive or shooter.fireCooldown > 0:
    return
  if shooter.facingDx == 0 and shooter.facingDy == 0:
    return
  let
    sx = shooter.x + CollisionW div 2
    sy = shooter.y + CollisionH div 2
    rangeSq = sim.config.gunRange * sim.config.gunRange
    fdx = float(shooter.facingDx)
    fdy = float(shooter.facingDy)
    facingLen = sqrt(fdx * fdx + fdy * fdy)
    coneCos = cos(float(sim.config.gunConeDeg) * 3.14159265358979 / 180.0)
  var
    bestDist = high(int)
    bestTarget = -1
  for i in 0 ..< sim.players.len:
    if i == shooterIndex or not sim.players[i].alive:
      continue
    if sim.players[i].spawnProtect > 0:
      continue
    let
      tx = sim.players[i].x + CollisionW div 2
      ty = sim.players[i].y + CollisionH div 2
      d = distSq(sx, sy, tx, ty)
    if d > rangeSq or d == 0:
      continue
    let
      vx = float(tx - sx)
      vy = float(ty - sy)
      vlen = sqrt(vx * vx + vy * vy)
    if vlen <= 0 or facingLen <= 0:
      continue
    let dot = (vx * fdx + vy * fdy) / (vlen * facingLen)
    if dot < coneCos:
      continue
    if not sim.lineOfSightClear(sx, sy, tx, ty):
      continue
    if d < bestDist:
      bestDist = d
      bestTarget = i
  sim.players[shooterIndex].fireCooldown = sim.config.fireCooldownTicks
  # Record a cosmetic tracer for the shot (never enters gameHash).
  var
    ex = sx
    ey = sy
  if bestTarget >= 0:
    ex = sim.players[bestTarget].x + CollisionW div 2
    ey = sim.players[bestTarget].y + CollisionH div 2
  else:
    # March along the normalized facing to the last wall-free pixel or max
    # range (checking each sampled pixel keeps this O(range) at 1300px).
    let maxRange = sim.config.gunRange
    var lastClear = 0
    for step in 1 .. maxRange:
      let
        rx = sx + int(round(fdx / facingLen * float(step)))
        ry = sy + int(round(fdy / facingLen * float(step)))
      if sim.isWall(rx, ry):
        break
      lastClear = step
    ex = sx + int(round(fdx / facingLen * float(lastClear)))
    ey = sy + int(round(fdy / facingLen * float(lastClear)))
  sim.recentShots.add ShotFx(
    x0: sx,
    y0: sy,
    x1: ex,
    y1: ey,
    firedTick: sim.tickCount,
    color: shooter.color
  )
  if bestTarget >= 0:
    sim.killPlayer(bestTarget, shooterIndex)
    sim.recordKill(shooterIndex)

proc tryPickupFlag(sim: var SimServer, playerIndex: int) =
  ## Picks up a loose flag when a living player touches it.
  if sim.flagCarrier >= 0:
    return
  if not sim.players[playerIndex].alive:
    return
  let
    px = sim.players[playerIndex].x + CollisionW div 2
    py = sim.players[playerIndex].y + CollisionH div 2
    rangeSq = FlagPickupRange * FlagPickupRange
  if distSq(px, py, sim.flagX, sim.flagY) <= rangeSq:
    sim.flagCarrier = playerIndex
    sim.players[playerIndex].carryingFlag = true
    sim.logGameEvent(sim.playerText(playerIndex) & " picked up the flag")

proc updateFlag(sim: var SimServer) =
  ## Keeps the flag glued to its carrier; a carrier that stops carrying for
  ## any reason other than capture sends the flag straight back to center.
  if sim.flagCarrier >= 0 and sim.flagCarrier < sim.players.len and
      sim.players[sim.flagCarrier].alive:
    sim.flagX = sim.players[sim.flagCarrier].x + CollisionW div 2
    sim.flagY = sim.players[sim.flagCarrier].y + CollisionH div 2
  elif sim.flagCarrier >= 0:
    # Carrier vanished; the flag goes straight back to center.
    sim.logGameEvent("flag returned to center")
    sim.resetFlag()

proc applyInput*(
  sim: var SimServer,
  playerIndex: int,
  input: InputState,
  prevInput: InputState
) {.measure.} =
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

  if inputX != 0 or inputY != 0:
    player.facingDx = inputX
    player.facingDy = inputY

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

  if inputX < 0:
    player.flipH = true
  elif inputX > 0:
    player.flipH = false

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
  sim.applyMomentumAxis(
    player,
    player.carryX,
    player.velX,
    preferredSlideY,
    true
  )
  sim.applyMomentumAxis(
    player,
    player.carryY,
    player.velY,
    preferredSlideX,
    false
  )

  let freshA = input.attack and not prevInput.attack
  if freshA:
    sim.tryFire(playerIndex)

proc playerView*(sim: SimServer, playerIndex: int): PlayerView =
  ## Returns the canonical per-player camera and visibility origin.
  let
    player = sim.players[playerIndex]
    spriteX = player.x - SpriteDrawOffX
    spriteY = player.y - SpriteDrawOffY
    centerX = spriteX + SpriteSize div 2
    centerY = spriteY + SpriteSize div 2
  result.cameraX = centerX - ScreenWidth div 2
  result.cameraY = centerY - ScreenHeight div 2
  result.originMx = player.x + CollisionW div 2
  result.originMy = player.y + CollisionH div 2
  result.viewerIsGhost = not player.alive

proc screenPointInFrame*(view: PlayerView, worldX, worldY: int): bool =
  ## Returns true when a world point lands inside this player's camera frame.
  let
    sx = worldX - view.cameraX
    sy = worldY - view.cameraY
  sx >= 0 and sx < ScreenWidth and sy >= 0 and sy < ScreenHeight

proc screenPointVisible*(sim: SimServer, view: PlayerView, worldX, worldY: int): bool =
  ## Returns true when a world point is visible in this player's rendered view.
  let
    sx = worldX - view.cameraX
    sy = worldY - view.cameraY
  if not screenPointInFrame(view, worldX, worldY):
    return false
  view.viewerIsGhost or not sim.shadowBuf[sy * ScreenWidth + sx]

const ScreenPixelCount = ScreenWidth * ScreenHeight

proc ensureShadowPaths(originSx, originSy: int) {.measure.} =
  ## Builds reusable screen-space shadow rays for one origin.
  if ShadowPaths.ready and
      ShadowPaths.originSx == originSx and
      ShadowPaths.originSy == originSy:
    return

  ShadowPaths = ShadowPathCache(
    ready: true,
    originSx: originSx,
    originSy: originSy,
    starts: newSeq[int](ScreenPixelCount + 1),
    offsets: newSeqOfCap[int32](ScreenPixelCount * 64),
    xs: newSeqOfCap[int16](ScreenPixelCount * 64),
    ys: newSeqOfCap[int16](ScreenPixelCount * 64)
  )

  for sy in 0 ..< ScreenHeight:
    for sx in 0 ..< ScreenWidth:
      let
        pixelIndex = sy * ScreenWidth + sx
        dx = sx - originSx
        dy = sy - originSy
        steps = max(abs(dx), abs(dy))
      ShadowPaths.starts[pixelIndex] = ShadowPaths.offsets.len
      if steps == 0:
        continue
      for step in 1 .. steps:
        let
          rx = originSx + dx * step div steps
          ry = originSy + dy * step div steps
        ShadowPaths.offsets.add(int32(ry * MapWidth + rx))
        ShadowPaths.xs.add(int16(rx))
        ShadowPaths.ys.add(int16(ry))
  ShadowPaths.starts[ScreenPixelCount] = ShadowPaths.offsets.len

proc clearShadowBuffer(sim: var SimServer) =
  ## Clears the active screen shadow buffer.
  if sim.shadowBuf.len != ScreenPixelCount:
    sim.shadowBuf = newSeq[bool](ScreenPixelCount)
    return
  if sim.shadowBuf.len > 0:
    zeroMem(addr sim.shadowBuf[0], sim.shadowBuf.len * sizeof(bool))

proc copyShadowMask(dst: var seq[bool], src: seq[bool]) =
  ## Copies a screen-sized shadow mask.
  if dst.len != ScreenPixelCount:
    dst = newSeq[bool](ScreenPixelCount)
  if src.len != ScreenPixelCount:
    zeroMem(addr dst[0], dst.len * sizeof(bool))
    return
  copyMem(addr dst[0], unsafeAddr src[0], dst.len * sizeof(bool))

proc ensureShadowCacheSlots(sim: var SimServer) =
  ## Keeps player-indexed shadow cache storage aligned with players.
  while sim.shadowCaches.len < sim.players.len:
    sim.shadowCaches.add PlayerShadowMask(
      valid: false,
      mask: newSeq[bool](ScreenPixelCount)
    )
  if sim.shadowCaches.len > sim.players.len:
    sim.shadowCaches.setLen(sim.players.len)
  for cache in sim.shadowCaches.mitems:
    if cache.mask.len != ScreenPixelCount:
      cache.valid = false
      cache.mask = newSeq[bool](ScreenPixelCount)

{.push checks: off.}
proc castShadows*(
  sim: var SimServer,
  originMx,
  originMy,
  cameraX,
  cameraY: int
) {.measure.} =
  let
    originSx = originMx - cameraX
    originSy = originMy - cameraY
  ensureShadowPaths(originSx, originSy)
  sim.clearShadowBuffer()

  let
    viewportInside =
      cameraX >= 0 and cameraY >= 0 and
      cameraX + ScreenWidth <= MapWidth and
      cameraY + ScreenHeight <= MapHeight
    baseIndex = cameraY * MapWidth + cameraX
    starts = cast[ptr UncheckedArray[int]](addr ShadowPaths.starts[0])
    offsets = cast[ptr UncheckedArray[int32]](addr ShadowPaths.offsets[0])
    wallMask = cast[ptr UncheckedArray[bool]](addr sim.wallMask[0])
    shadowBuf = cast[ptr UncheckedArray[bool]](addr sim.shadowBuf[0])

  if viewportInside:
    for pixelIndex in 0 ..< ScreenPixelCount:
      let finish = starts[pixelIndex + 1]
      var stepIndex = starts[pixelIndex]
      while stepIndex < finish:
        if wallMask[baseIndex + int(offsets[stepIndex])]:
          shadowBuf[pixelIndex] = true
          break
        inc stepIndex
    return

  let
    xs = cast[ptr UncheckedArray[int16]](addr ShadowPaths.xs[0])
    ys = cast[ptr UncheckedArray[int16]](addr ShadowPaths.ys[0])
  for pixelIndex in 0 ..< ScreenPixelCount:
    let finish = starts[pixelIndex + 1]
    var stepIndex = starts[pixelIndex]
    while stepIndex < finish:
      let
        mx = cameraX + int(xs[stepIndex])
        my = cameraY + int(ys[stepIndex])
      if mx < 0 or my < 0 or mx >= MapWidth or my >= MapHeight or
          wallMask[my * MapWidth + mx]:
        shadowBuf[pixelIndex] = true
        break
      inc stepIndex

proc usePlayerShadowMask*(
  sim: var SimServer,
  playerIndex: int,
  view: PlayerView
): bool {.measure.} =
  ## Loads the shadow mask and returns true when it was refreshed.
  if playerIndex < 0 or playerIndex >= sim.players.len or view.viewerIsGhost:
    sim.clearShadowBuffer()
    return false

  sim.ensureShadowCacheSlots()
  template cache: untyped = sim.shadowCaches[playerIndex]
  if cache.valid and
      cache.cameraX == view.cameraX and
      cache.cameraY == view.cameraY and
      cache.originMx == view.originMx and
      cache.originMy == view.originMy:
    sim.shadowBuf.copyShadowMask(cache.mask)
    return false

  sim.castShadows(view.originMx, view.originMy, view.cameraX, view.cameraY)
  cache.valid = true
  cache.cameraX = view.cameraX
  cache.cameraY = view.cameraY
  cache.originMx = view.originMx
  cache.originMy = view.originMy
  cache.mask.copyShadowMask(sim.shadowBuf)
  result = true
{.pop.}

proc finishGame*(sim: var SimServer, winner: Team, isDraw = false, timeLimitReached = false) =
  ## Moves to game over and awards all winning players.
  if sim.phase == GameOver:
    return
  if isDraw:
    sim.logGameEvent("draw")
  else:
    sim.logGameEvent(teamText(winner) & " win")
  sim.phase = GameOver
  sim.winner = winner
  sim.isDraw = isDraw
  sim.gameOverTimer = sim.config.gameOverTicks
  sim.timeLimitReached = timeLimitReached
  if isDraw:
    return
  var awardedAccounts = newSeq[bool](sim.rewardAccounts.len)
  for i in 0 ..< sim.players.len:
    if sim.players[i].team == winner:
      let accountIndex = sim.rewardAccountForPlayer(i)
      if awardedAccounts.len < sim.rewardAccounts.len:
        awardedAccounts.setLen(sim.rewardAccounts.len)
      if accountIndex >= 0 and accountIndex < awardedAccounts.len:
        awardedAccounts[accountIndex] = true
      sim.addReward(i, WinReward)
      sim.recordGameWin(i)
  for i in 0 ..< sim.rewardAccounts.len:
    if i < awardedAccounts.len and awardedAccounts[i]:
      continue
    if not sim.rewardAccounts[i].hasTeam or sim.rewardAccounts[i].team != winner:
      continue
    sim.rewardAccounts[i].reward += WinReward
    sim.rewardAccounts[i].won = true
    if winner == Red:
      inc sim.rewardAccounts[i].winsRed
    else:
      inc sim.rewardAccounts[i].winsBlue

proc gameTicksElapsed*(sim: SimServer): int =
  ## Returns ticks elapsed since the current game left the lobby.
  if sim.gameStartTick < 0:
    return 0
  max(0, sim.tickCount - sim.gameStartTick)

proc maxTicksReached(sim: SimServer): bool =
  sim.config.maxTicks > 0 and sim.phase == Playing and
    sim.gameTicksElapsed() >= sim.config.maxTicks

proc teamLivesRemaining(sim: SimServer, team: Team): int =
  ## Returns total lives remaining (alive players count their current life).
  for p in sim.players:
    if p.team != team:
      continue
    result += p.lives
    if p.alive:
      inc result

proc teamFlagProgress(sim: SimServer, team: Team): int =
  ## Returns how far the flag has progressed toward a team's home edge.
  ## Higher is closer to that team's home.
  case team
  of Red:
    MapWidth - sim.flagX
  of Blue:
    sim.flagX

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
  # Capture: a living carrier inside their own home capture zone.
  if sim.flagCarrier >= 0 and sim.flagCarrier < sim.players.len and
      sim.players[sim.flagCarrier].alive:
    let
      carrier = sim.players[sim.flagCarrier]
      zone = sim.captureZoneXRange(carrier.team)
      cx = carrier.x + CollisionW div 2
    if cx >= zone.lo and cx <= zone.hi:
      sim.recordCapture(sim.flagCarrier)
      sim.logGameEvent(teamText(carrier.team) & " captured the flag")
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
  ## Resolves a time-limit tiebreak.
  if not sim.maxTicksReached():
    return
  let
    redLives = sim.teamLivesRemaining(Red)
    blueLives = sim.teamLivesRemaining(Blue)
  if redLives > blueLives:
    sim.finishGame(Red, timeLimitReached = true)
  elif blueLives > redLives:
    sim.finishGame(Blue, timeLimitReached = true)
  else:
    let
      redProgress = sim.teamFlagProgress(Red)
      blueProgress = sim.teamFlagProgress(Blue)
    if redProgress > blueProgress:
      sim.finishGame(Red, timeLimitReached = true)
    elif blueProgress > redProgress:
      sim.finishGame(Blue, timeLimitReached = true)
    else:
      sim.finishGame(Red, isDraw = true, timeLimitReached = true)

proc spritePlayerObservationPointShadowed(
  sim: SimServer,
  originMx, originMy, worldX, worldY: int
): bool {.inline.} =
  let
    dx = worldX - originMx
    dy = worldY - originMy
    steps = max(abs(dx), abs(dy))
  if steps == 0:
    return false
  for s in 1 .. steps:
    let
      rx = originMx + dx * s div steps
      ry = originMy + dy * s div steps
    if sim.isWall(rx, ry):
      return true
  false

proc spritePlayerObservationWorldPointVisible(
  sim: SimServer,
  view: PlayerView,
  worldX, worldY: int
): bool {.inline.} =
  if not view.screenPointInFrame(worldX, worldY):
    return false
  view.viewerIsGhost or not sim.spritePlayerObservationPointShadowed(
    view.originMx,
    view.originMy,
    worldX,
    worldY
  )

proc spritePlayerObservationFireIconByte(sim: SimServer, playerIndex: int): uint8 =
  if sim.phase != Playing or playerIndex < 0 or playerIndex >= sim.players.len:
    return 0'u8
  let player = sim.players[playerIndex]
  if not player.alive:
    return 0'u8
  if player.fireCooldown > 0: 1'u8 else: 255'u8

proc writeSpritePlayerObservationHeader(
  sim: SimServer,
  playerIndex: int,
  output: var openArray[uint8]
) =
  output[0] = uint8(ord(sim.phase))
  if sim.phase == Playing and playerIndex >= 0 and playerIndex < sim.players.len:
    output[RenderHeaderFireIcon] = sim.spritePlayerObservationFireIconByte(playerIndex)
    output[RenderHeaderLives] = uint8(clamp(sim.players[playerIndex].lives, 0, 255))

proc writeSpritePlayerObservationGrid(
  sim: SimServer,
  playerIndex: int,
  output: var openArray[uint8]
) =
  if sim.phase != Playing or playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let
    view = sim.playerView(playerIndex)
    step = ScreenWidth div SpritePlayerObservationGridSize
  for gy in 0 ..< SpritePlayerObservationGridSize:
    for gx in 0 ..< SpritePlayerObservationGridSize:
      let
        sx = gx * step + step div 2
        sy = gy * step + step div 2
        mx = view.cameraX + sx
        my = view.cameraY + sy
        index = SpritePlayerObservationGridOffset + gy * SpritePlayerObservationGridSize + gx
      var color = MapVoidColor
      if mx >= 0 and my >= 0 and mx < MapWidth and my < MapHeight:
        let mapIdx = mapIndex(mx, my)
        color = sim.mapPixels[mapIdx] and 0x0F
      output[index] = color

proc writeSpritePlayerObservationPlayerSlot(
  sim: SimServer,
  targetIndex, slotIndex, sx, sy: int,
  flags: uint8,
  output: var openArray[uint8]
) =
  let
    player = sim.players[targetIndex]
    base = SpritePlayerObservationPlayerOffset + slotIndex * SpritePlayerObservationPlayerFeatures
  output[base] = uint8(clamp(sx, 0, 255))
  output[base + 1] = uint8(clamp(sy, 0, 255))
  output[base + 2] = player.color
  output[base + RenderPlayerFlagsFeature] = flags

proc writeSpritePlayerObservationPlayingPlayers(
  sim: SimServer,
  playerIndex: int,
  output: var openArray[uint8]
) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let
    view = sim.playerView(playerIndex)
    cameraX = view.cameraX
    cameraY = view.cameraY
  for i in 0 ..< sim.players.len:
    let
      p = sim.players[i]
      sx = p.x - SpriteDrawOffX - cameraX
      sy = p.y - SpriteDrawOffY - cameraY
    if not view.screenPointInFrame(p.x + CollisionW div 2, p.y + CollisionH div 2):
      continue
    var flags = RenderPlayerPresent
    if p.alive:
      if i != playerIndex and
          not sim.spritePlayerObservationWorldPointVisible(
            view,
            p.x + CollisionW div 2,
            p.y + CollisionH div 2
          ):
        continue
      flags = flags or RenderPlayerAlive
    elif view.viewerIsGhost:
      flags = flags or RenderPlayerGhost
    else:
      continue
    if p.flipH:
      flags = flags or RenderPlayerFlipH
    if p.carryingFlag:
      flags = flags or RenderPlayerCarrier
    sim.writeSpritePlayerObservationPlayerSlot(i, i, sx, sy, flags, output)

proc writeSpritePlayerObservationUiPlayers(
  sim: SimServer,
  playerIndex: int,
  output: var openArray[uint8]
) =
  let n = sim.players.len
  if n == 0:
    return
  case sim.phase
  of Lobby:
    let startY = sim.lobbyIconStartY()
    for i in 0 ..< n:
      let
        col = i mod 6
        row = i div 6
        sx = 5 + col * 9
        sy = startY + row * 9
      let flags = RenderPlayerPresent or RenderPlayerAlive
      sim.writeSpritePlayerObservationPlayerSlot(i, i, sx, sy, flags, output)
  of GameOver:
    let
      rowH = 14
      rowsPerCol = 8
      colW = ScreenWidth div 2
      iconOffsetX = 4
      startY = 16
    for i in 0 ..< n:
      let
        col = i div rowsPerCol
        row = i mod rowsPerCol
        baseX = min(col, 1) * colW
        y = startY + row * rowH
        iconX = baseX + iconOffsetX
        iconY = y + (rowH - CrewSpriteSize) div 2
      var flags = RenderPlayerPresent
      if sim.players[i].alive:
        flags = flags or RenderPlayerAlive
      sim.writeSpritePlayerObservationPlayerSlot(i, i, iconX, iconY, flags, output)
  of Playing:
    discard

proc writeSpritePlayerObservationFlag(
  sim: SimServer,
  playerIndex: int,
  output: var openArray[uint8]
) =
  if sim.phase != Playing or playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let view = sim.playerView(playerIndex)
  if not sim.spritePlayerObservationWorldPointVisible(view, sim.flagX, sim.flagY):
    return
  let
    base = SpritePlayerObservationFlagOffset
    sx = sim.flagX - view.cameraX
    sy = sim.flagY - view.cameraY
  output[base] = uint8(clamp(sx, 0, 255))
  output[base + 1] = uint8(clamp(sy, 0, 255))
  output[base + 2] = uint8(clamp(sim.flagCarrier + 1, 0, 255))
  output[base + RenderFlagFlagsFeature] =
    if sim.flagCarrier >= 0: RenderFlagCarried else: RenderFlagLoose

proc writeSpritePlayerObservationArrow(
  sim: SimServer,
  playerIndex: int,
  output: var openArray[uint8]
) =
  ## Writes an off-screen direction marker pointing toward the flag.
  if sim.phase != Playing or playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let view = sim.playerView(playerIndex)
  # Skip when the flag is already on screen and visible.
  if sim.spritePlayerObservationWorldPointVisible(view, sim.flagX, sim.flagY):
    return
  let
    px = float(view.originMx - view.cameraX)
    py = float(view.originMy - view.cameraY)
    dx = float(sim.flagX - view.cameraX) - px
    dy = float(sim.flagY - view.cameraY) - py
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
  let base = SpritePlayerObservationArrowOffset
  output[base + 2] = uint8(int(ex))
  output[base + 3] = uint8(int(ey))
  output[base + RenderArrowFlagsFeature] = RenderArrowVisible

proc writeSpritePlayerObservation*(
  sim: var SimServer,
  playerIndex: int,
  output: var openArray[uint8]
) {.measure.} =
  ## Writes a compact sprite-player observation with only visible fields.
  if output.len != SpritePlayerObservationFeatures:
    raise newException(
      CtfError,
      "SpritePlayer observation must be " & $SpritePlayerObservationFeatures & " bytes."
    )
  for i in 0 ..< output.len:
    output[i] = 0
  sim.writeSpritePlayerObservationHeader(playerIndex, output)
  sim.writeSpritePlayerObservationGrid(playerIndex, output)
  if sim.phase == Playing:
    sim.writeSpritePlayerObservationPlayingPlayers(playerIndex, output)
    sim.writeSpritePlayerObservationFlag(playerIndex, output)
    sim.writeSpritePlayerObservationArrow(playerIndex, output)
  else:
    sim.writeSpritePlayerObservationUiPlayers(playerIndex, output)

proc initSimServer*(config: GameConfig): SimServer =
  result.config = config
  result.rng = initRand(config.seed)
  loadPalette(clientDataDir() / "pallete.png")
  result.asciiSprites = readTiny5Font()

  let sheet = loadSpriteSheet()
  result.crewSprites = loadCrewSprites()
  # Reuse the former task-icon cell as the flag sprite.
  result.flagSprite = spriteFromImage(
    sheet.subImage(SpriteSize * 4, 0, SpriteSize, SpriteSize)
  )

  result.gameMap = loadCtfMap(config.mapPath)
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

  result.shadowBuf = newSeq[bool](ScreenWidth * ScreenHeight)
  result.shadowCaches = @[]
  ensureShadowPaths(ScreenWidth div 2, ScreenHeight div 2)
  result.players = @[]
  result.nextJoinOrder = 0
  result.gameStartTick = -1
  result.startWaitTimer = 0
  result.gameEventLoggingEnabled = true
  result.flagCarrier = -1
  result.flagX = result.gameMap.center.x
  result.flagY = result.gameMap.center.y
  result.lastLobbyPlayersLogged = -1
  result.lastLobbyNeededLogged = -1
  result.lastLobbySecondsLogged = -1

proc resetToLobby*(sim: var SimServer) =
  sim.phase = Lobby
  sim.players = @[]
  sim.shadowCaches = @[]
  sim.recentShots = @[]
  sim.splatters = @[]
  sim.nextJoinOrder = 0
  sim.tickCount = 0
  sim.gameStartTick = -1
  sim.startWaitTimer = 0
  sim.timeLimitReached = false
  sim.isDraw = false
  sim.needsReregister = true
  sim.resetFlag()
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
  ## Ticks respawn timers and brings dead players back at home.
  for i in 0 ..< sim.players.len:
    if sim.players[i].alive:
      if sim.players[i].spawnProtect > 0:
        dec sim.players[i].spawnProtect
      continue
    if sim.players[i].lives <= 0:
      continue
    if sim.players[i].respawnTimer > 0:
      dec sim.players[i].respawnTimer
      if sim.players[i].respawnTimer <= 0:
        sim.resetPlayerToHome(i)
        sim.players[i].alive = true
        sim.players[i].spawnProtect = sim.config.spawnProtectTicks
        sim.players[i].facingDx = if sim.players[i].team == Red: 1 else: -1
        sim.players[i].facingDy = 0

proc step*(
  sim: var SimServer,
  inputs: openArray[InputState],
  prevInputs: openArray[InputState]
) {.measure.} =
  inc sim.tickCount

  if sim.phase == Lobby:
    sim.stepLobby()
    return

  if sim.phase == GameOver:
    dec sim.gameOverTimer
    if sim.gameOverTimer <= 0:
      sim.resetToLobby()
    return

  # Playing.
  for playerIndex in 0 ..< sim.players.len:
    if sim.players[playerIndex].fireCooldown > 0:
      dec sim.players[playerIndex].fireCooldown
    let input =
      if playerIndex < inputs.len: inputs[playerIndex]
      else: InputState()
    let prev =
      if playerIndex < prevInputs.len: prevInputs[playerIndex]
      else: InputState()
    sim.applyInput(playerIndex, input, prev)

  for playerIndex in 0 ..< sim.players.len:
    sim.tryPickupFlag(playerIndex)
  sim.updateFlag()
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
  var keptSplatters: seq[SplatterFx] = @[]
  for splatter in sim.splatters:
    if sim.tickCount - splatter.tick < SplatterFxTicks:
      keptSplatters.add splatter
  sim.splatters = keptSplatters
