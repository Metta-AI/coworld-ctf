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
  GunRange* = 1300            ## px, effectively map-wide; LOS and aim are the real limits.
  BulletHalfWidth* = 8.0      ## the bullet corridor half-width: a shot travels
                              ## along the facing ray and hits the FIRST player
                              ## whose footprint crosses it.
  FireCooldownTicks* = 12     ## ~0.5s between shots.
  FireWindupTicks* = 5        ## ~0.2s from trigger pull to the shot; aim locks
                              ## at the pull, so a peeking target can duck back.
  ShotFxTicks* = 12           ## ~0.5s a shot tracer stays visible (cosmetic only).
  SplatterFxTicks* = 120      ## ~5s a death splatter stays visible (cosmetic only).
  CarrierSpeedPct* = 70       ## carrier moves at 70% speed.
  AimBradsTurn* = 256         ## aim angle units per full turn (binary radians).
  AimTurnRate* = 5            ## brads/tick a held rotate button turns the aim
                              ## (~7 deg/tick; a full turn takes ~2.1s).
  VisionConeDeg* = 45         ## vision cone half-angle around the aim angle.
  VisionBubble* = 90          ## omnidirectional vision radius in px.

  FovCellSize* = 8            ## fog-of-war visibility grid cell size in px.
  FovGridW* = (MapWidth + FovCellSize - 1) div FovCellSize
  FovGridH* = (MapHeight + FovCellSize - 1) div FovCellSize
  FovCellCount* = FovGridW * FovGridH

  StartWaitTicks* = 5 * TargetFps
  GameOverTicks* = 360
  MaxTicks* = 10_000  ## 0 = no limit.
  MaxGames* = 0  ## 0 = no limit.
  MaxPlayers* = 16
  MinPlayers* = 16

  WinReward* = 100

  FlagPickupRange* = 12       ## touch radius to steal the enemy flag.
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
  FlagSpriteBase* = 700       ## team flag sprites: 700 red flag, 701 blue flag.
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
    mapPath*: string
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
    respawnTimer*: int
    fireCooldown*: int
    fireWindup*: int           ## ticks until a pulled trigger releases its shot.
    windupBrads*: int          ## aim angle locked at the trigger pull, -1 = none.
    spawnProtect*: int
    carryingFlag*: bool
    joinOrder*: int
    address*: string
    color*: uint8
    reward*: int
    kills*: int
    deaths*: int
    captures*: int

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

  SplatterFx* = object
    ## A cosmetic death splatter mark; never enters gameHash (replay-safe).
    x*, y*: int
    tick*: int
    color*: uint8

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
  ArenaFlagRing = 70           ## clear radius of the open center ring.
  ArenaCaptureClear = 210      ## x-columns kept traversable for carriers.
  ArenaSpawnClearW = 70        ## half-width of the open spawn pockets.
  ArenaSpawnClearH = 130       ## half-height of the open spawn pockets.

  ArenaFloor = rgba(24, 26, 34, 255)      ## dark walkable floor.
  ArenaWall = rgba(96, 104, 128, 255)     ## lighter, distinct wall.
  ArenaBorderColor = rgba(60, 66, 84, 255)
  ArenaRedTint = rgba(120, 40, 44, 70)    ## territory wash over Red half.
  ArenaBlueTint = rgba(44, 60, 128, 70)   ## territory wash over Blue half.
  ArenaRedPedestal = rgba(224, 96, 88, 255)   ## Red flag pedestal marker.
  ArenaBluePedestal = rgba(96, 128, 232, 255) ## Blue flag pedestal marker.

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
  ## Draw a small team-colored pedestal marker under each flag home (stays
  ## walkable; the pedestals sit inside the protected spawn pockets).
  for team in Team:
    let
      home = gameMap.flagHome(team)
      color = (if team == Red: ArenaRedPedestal else: ArenaBluePedestal)
    for dy in -4 .. 4:
      for dx in -4 .. 4:
        if dx * dx + dy * dy <= 16:
          result.mapImage[home.x + dx, home.y + dy] = color

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
  if config.fireWindupTicks < 0:
    raise newException(CtfError, "Config field fireWindupTicks must not be negative.")
  if config.carrierSpeedPct <= 0 or config.carrierSpeedPct > 100:
    raise newException(CtfError, "Config field carrierSpeedPct must be 1..100.")
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
    result.mixHashInt(player.respawnTimer)
    result.mixHashInt(player.fireCooldown)
    result.mixHashInt(player.fireWindup)
    result.mixHashInt(player.windupBrads)
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

proc resetFlag*(sim: var SimServer, team: Team) =
  ## Returns one team's flag to its home pedestal.
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
  for team in Team:
    if sim.flags[team].carrier == playerIndex:
      sim.logGameEvent(teamText(team) & " flag returned home")
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
    joinOrder: order,
    address: address,
    color: color,
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
    sim.players[i].fireWindup = 0
    sim.players[i].windupBrads = -1
    sim.players[i].aimBrads = spawnAimBrads(sim.players[i].team)
    sim.players[i].flipH = sim.players[i].team == Blue
    sim.players[i].spawnProtect = sim.config.spawnProtectTicks
    sim.players[i].carryingFlag = false
    sim.players[i].kills = 0
    sim.players[i].deaths = 0
    sim.players[i].captures = 0
    sim.recordGameTeamAssigned(i)
  sim.resetFlags()
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
  # A dying trigger pull never releases.
  sim.players[targetIndex].fireWindup = 0
  sim.players[targetIndex].windupBrads = -1
  for team in Team:
    if sim.flags[team].carrier == targetIndex:
      sim.players[targetIndex].carryingFlag = false
      sim.logGameEvent(teamText(team) & " flag returned home")
      sim.resetFlag(team)
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

proc canFire(sim: SimServer, shooterIndex: int): bool =
  ## Returns whether one player is able to fire a shot right now.
  if shooterIndex < 0 or shooterIndex >= sim.players.len:
    return false
  let shooter = sim.players[shooterIndex]
  shooter.alive and shooter.fireCooldown <= 0

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
  ## the locked aim direction and stops at the first footprint it crosses
  ## (friendly fire on) or the first wall — or -1 for a miss.
  result = -1
  let
    shooter = sim.players[shooterIndex]
    (ux, uy) = sim.fireDirection(shooterIndex)
    sx = shooter.x + CollisionW div 2
    sy = shooter.y + CollisionH div 2
    maxRange = float(sim.config.gunRange)
    corridor = BulletHalfWidth + float(PlayerHalf)
  var bestT = maxRange + 1.0
  for i in 0 ..< sim.players.len:
    if i == shooterIndex or not sim.players[i].alive:
      continue
    if sim.players[i].spawnProtect > 0:
      continue
    let
      vx = float(sim.players[i].x + CollisionW div 2 - sx)
      vy = float(sim.players[i].y + CollisionH div 2 - sy)
      t = vx * ux + vy * uy            # distance along the ray
    if t <= 0 or t > maxRange:
      continue
    let perp = abs(vx * uy - vy * ux)  # distance off the ray
    if perp > corridor:
      continue
    if not sim.lineOfSightClear(
      sx, sy,
      sim.players[i].x + CollisionW div 2,
      sim.players[i].y + CollisionH div 2
    ):
      continue
    if t < bestT:
      bestT = t
      result = i

proc applyFire(sim: var SimServer, shooterIndex, targetIndex: int) =
  ## Applies one selected shot: cooldown, tracer, and the kill. The target
  ## may already have died to another shot this tick; the shot still lands
  ## (tracer and all) but only an alive target yields a kill.
  let
    shooter = sim.players[shooterIndex]
    (ux, uy) = sim.fireDirection(shooterIndex)
    sx = shooter.x + CollisionW div 2
    sy = shooter.y + CollisionH div 2
  sim.players[shooterIndex].fireCooldown = sim.config.fireCooldownTicks
  sim.players[shooterIndex].windupBrads = -1
  # Record a cosmetic tracer for the shot (never enters gameHash). It ends at
  # the victim, so a bullet visibly never travels past its first hit.
  var
    ex = sx
    ey = sy
  if targetIndex >= 0:
    ex = sim.players[targetIndex].x + CollisionW div 2
    ey = sim.players[targetIndex].y + CollisionH div 2
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
    color: shooter.color
  )
  if targetIndex >= 0 and sim.players[targetIndex].alive:
    sim.killPlayer(targetIndex, shooterIndex)
    sim.recordKill(shooterIndex)

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
  sim.players[shooterIndex].fireWindup = sim.config.fireWindupTicks
  sim.players[shooterIndex].windupBrads = sim.players[shooterIndex].aimBrads

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
    sim.logGameEvent(
      teamText(sim.players[playerIndex].team) & " stole the " &
        teamText(flagTeam) & " flag"
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
      sim.logGameEvent(teamText(team) & " flag returned home")
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
  ## are ghosts and see everything. Call refreshPlayerFov first.
  if not sim.players[playerIndex].alive:
    return true
  if playerIndex >= sim.fovCaches.len or not sim.fovCaches[playerIndex].valid:
    return true
  let (cx, cy) = fovCellAt(x, y)
  sim.fovCaches[playerIndex].visible[fovCellIndex(cx, cy)]

proc playerVisibleTo*(sim: SimServer, viewerIndex, targetIndex: int): bool =
  ## Returns whether one player is observable by a viewer: yourself and your
  ## teammates always are (team radio); enemies only inside your vision.
  if viewerIndex == targetIndex:
    return true
  if sim.players[viewerIndex].team == sim.players[targetIndex].team:
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
  ## Returns how far the ENEMY flag has been advanced toward this team's
  ## home while carried; 0 when it sits on its pedestal.
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
      sim.logGameEvent(
        teamText(carrier.team) & " captured the " & teamText(flagTeam) & " flag"
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

  result.fovBlocked = buildFovBlocked(result.wallMask)
  result.fovCaches = @[]
  result.players = @[]
  result.nextJoinOrder = 0
  result.gameStartTick = -1
  result.startWaitTimer = 0
  result.gameEventLoggingEnabled = true
  result.resetFlags()
  result.lastLobbyPlayersLogged = -1
  result.lastLobbyNeededLogged = -1
  result.lastLobbySecondsLogged = -1

proc resetToLobby*(sim: var SimServer) =
  sim.phase = Lobby
  sim.players = @[]
  sim.fovCaches = @[]
  sim.recentShots = @[]
  sim.splatters = @[]
  sim.nextJoinOrder = 0
  sim.tickCount = 0
  sim.gameStartTick = -1
  sim.startWaitTimer = 0
  sim.timeLimitReached = false
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
        sim.players[i].aimBrads = spawnAimBrads(sim.players[i].team)
        sim.players[i].flipH = sim.players[i].team == Blue

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

  # Playing: move everyone first, then resolve every shot that releases this
  # tick at once against the post-movement snapshot (no processing-order
  # advantage). A fresh trigger pull arms a windup with the aim locked at the
  # pull; the bullet leaves fireWindupTicks later from the shooter's current
  # position, so a target that ducks back behind cover survives the shot.
  var firing: seq[int] = @[]
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
    if input.attack and not prev.attack:
      if sim.config.fireWindupTicks <= 0:
        if sim.canFire(playerIndex) and sim.players[playerIndex].fireWindup == 0:
          firing.add(playerIndex)
      else:
        sim.startFireWindup(playerIndex)
  sim.resolveSimultaneousFire(firing)

  for playerIndex in 0 ..< sim.players.len:
    sim.tryPickupFlags(playerIndex)
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
  var keptSplatters: seq[SplatterFx] = @[]
  for splatter in sim.splatters:
    if sim.tickCount - splatter.tick < SplatterFxTicks:
      keptSplatters.add splatter
  sim.splatters = keptSplatters
