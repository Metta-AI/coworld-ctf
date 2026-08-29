import
  std/[algorithm, atomics, json, locks, monotimes, nativesockets, os, strutils, tables, times],
  supersnappy,
  bitworld/client as bitworldClient, bitworld/profile, bitworld/spriteprotocol,
  bitworld/runtime,
  curly, mummy,
  sim, global, replays, broadcast, replay_runtime, events, wire_constants

when defined(posix):
  from std/posix import SHUT_RDWR, shutdown

type
  WebSocketSocketFields = object
    server: Server
    clientSocket: SocketHandle
    clientId: uint64

  SeatTakeover = object
    ## One human standing in for one policy seat. The human drives the seat's
    ## cog with the SAME eight-button InputState the policy was pressing —
    ## takeover changes WHO is read, nothing else about the sim.
    seat: int        ## config slot index (matches Player.joinOrder). MOVES
                     ## while the takeover is still pending — see
                     ## migratePendingTakeovers.
    requestedSeat: int ## the seat this human originally asked for. Never
                     ## changes, so a surface can find its own row after a
                     ## migration without guessing.
    name: string     ## guest display name, generated app-side.
    active: bool     ## false = "suiting up", pending the next respawn.
    cog: int         ## resolved sim player index, -1 while unresolved.
    observed: bool   ## true once a frame has sampled the cog's alive flag.
    prevAlive: bool  ## that flag on the previously sampled frame.
    cogX, cogY: int  ## where that cog stood on the last sampled frame, in map
                     ## pixels. It is the seat's OWN cog, which the human is
                     ## already looking at, so it hides nothing the fog hides —
                     ## and it is how "is the policy actually driving again?"
                     ## gets a numeric answer instead of a vibe.
    cogAlive: bool   ## the cog's alive flag as of the last sampled frame —
                     ## reported so a surface can say "your cog is down, you
                     ## are in at the next spawn" rather than just "waiting".
    policyMask: uint8 ## the mask the seat's POLICY was pressing on that same
                      ## frame, while it was being ignored. The pair
                      ## (lastMask, policyMask) is the arbitration made
                      ## visible: the policy never stopped playing, its input
                      ## is simply not what the seat applies while a human
                      ## drives — which is why the handback is seamless.
    directAim: bool  ## true when this human's connection asked for, and was
                     ## granted, the direct-aim channel: their turret takes the
                     ## bearing of their cursor in one tick instead of swinging
                     ## at `aimTurnRate`. Granted ONLY on a config that arms
                     ## `allowDirectAim`; a request on a league config is
                     ## refused at the upgrade rather than silently dropped.
    aimBrads: int    ## the bearing this seat's turret was last pointed at
                     ## through that channel, -1 when it is not driving one.
                     ## Echoed on /takeover/status so "am I actually pointing
                     ## where I am pointing?" has an honest answer.
    lastMask: uint8  ## the input mask this seat applied on the last frame,
                     ## echoed back on /takeover/status. It is the human's OWN
                     ## keypress coming back, so it leaks nothing the fog hides
                     ## — and it is the one honest answer to "are my keys
                     ## actually reaching the field?".

  SeatSnapshot = object
    ## One seat's liveness as of the last frame, published for the seat PICKER.
    ## The picker runs on the HTTP thread and the roster lives on the game
    ## thread, so the frame leaves this behind rather than reaching across.
    seat: int          ## config slot index (Player.joinOrder).
    cog: int           ## sim player index.
    alive: bool
    respawnTimer: int  ## ticks until this cog is back on its feet, 0 if up.

  WebSocketAppState = object
    lock: Lock
    replayServerMode: bool
    replayLoaded: bool
    pendingReplayUri: string
    loadingReplayUri: string
    currentReplayUri: string
    resetRequested: bool
    kickRequests: seq[string]
    kickedIdentities: Table[string, bool]
    inputMasks: Table[WebSocket, uint8]
    inputPressedMasks: Table[WebSocket, uint8]
    lastAppliedMasks: Table[WebSocket, uint8]
    chatMessages: Table[WebSocket, string]
    playerIndices: Table[WebSocket, int]
    playerAddresses: Table[WebSocket, string]
    playerSlots: Table[WebSocket, int]
    playerTokens: Table[WebSocket, string]
    playerReady: Table[WebSocket, bool]
    ## Sprites Off (0x87) senders: these clients get pixel-free sprite
    ## definitions — id, dimensions, and label with no pixel payload.
    spritesOff: Table[WebSocket, bool]
    globalViewers: Table[WebSocket, GlobalViewerState]
    playerViewers: Table[WebSocket, PlayerViewerState]
    rewardViewers: Table[WebSocket, bool]
    ## Human seat takeovers, keyed by the HUMAN's websocket. A takeover
    ## socket is deliberately NOT a roster player (see
    ## registerTakeoverWebSocket): it never enters `playerIndices`, so it
    ## never joins, never occupies a slot, and never writes a join/leave
    ## record. Empty on every config that leaves allowSeatTakeover off, which
    ## is what makes a league build byte-identical to a pre-takeover build.
    takeovers: Table[WebSocket, SeatTakeover]
    ## Per-seat liveness as of the last frame. Written only on a config that
    ## arms takeover, so it stays an empty seq for a league build's whole run.
    seatBoard: seq[SeatSnapshot]
    closedSockets: seq[WebSocket]
    nextAnonymousPlayer: int
    config: GameConfig

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

  PendingPlayerJoin = object
    websocket: WebSocket
    address: string
    token: string
    requestedSlot: int
    slotIndex: int

const
  # Sentinel for `appState.playerIndices`: a player websocket that has
  # registered but has not yet been resolved into a live `sim.players`
  # slot (join admission is strictly slot-sequential and can take more
  # than one tick). It is deliberately far outside any real array index so
  # the "still pending" scan (`== UnresolvedPlayerIndex`) never collides
  # with a resolved one. It must NEVER be treated as a real index by
  # arithmetic that shifts indices after a removal (see `removePlayer`) --
  # doing so corrupts it into a value that can never match the pending
  # scan again, permanently orphaning that socket even though it is still
  # connected.
  UnresolvedPlayerIndex = 0x7fffffff
  HealthPath = "/healthz"
  VerifyFrameHealthPath = "/health/frame"  # diagnostic-only, see verifyFrameCounter
  AdminWebSocketPath = "/admin"
  # Freeplay seat takeover. A dedicated websocket route rather than a flag on
  # /player: the stock player client force-copies name/token/slot onto
  # whatever `address` it is given, so a browser reaches this path with no
  # client change at all, and the roster's player path stays untouched.
  TakeoverWebSocketPath = "/takeover"
  TakeoverStatusPath = "/takeover/status"
  # "Which seat should this arrival take?" -- answered by the server because
  # only the server knows which cog is lying down right now.
  TakeoverSeatPath = "/takeover/seat"
  TakeoverClientPath = "/client/takeover"
  # What a human connection may be GRANTED here. Polled by the client before
  # it connects, so one bundle serves both a league server and a play server.
  CapabilitiesPath = "/capabilities"
  ControlRestartPath = "/control/restart"
  ControlKickPath = "/control/kick"
  ## Cap on player debug-sprite bytes accepted per player per tick.
  MaxDebugSpriteBytesPerTick* = 32 * 1024
  # The designed broadcast replay client, embedded at compile time. Served for
  # the replay routes in place of bitworld's generic global client; a single
  # self-contained file (shared chrome + core JS inlined). Live/player/global
  # paths are untouched and keep serving the bitworld client (§14 live column).
  # Final in-page script order: wire constants, shared chrome, core, page IIFE
  # (marker positions in the HTML fix that; the replace order here is free).
  EmbeddedBroadcastReplayHtml = staticRead("../../client/replay_broadcast.html").replace(
    "<!-- CHROME_COMMON -->",
    "<script>" & staticRead("../../client/chrome_common.js") & "</script>"
  ).replace(
    "<!-- BROADCAST_CORE -->",
    "<script>" & staticRead("../../client/broadcast_core.js") & "</script>"
  ).spliceWireConstants()
  # The League Replayer shell: a walled stone-pit viewer that EMBEDS the broadcast
  # client (via ?embed=1) as the lit pit floor and mounts the scorebug, KDA tables,
  # division standings and transport as flat panels over the dungeon walls. Served
  # at the bare replay route; embed=1 falls through to the plain broadcast client.
  # Shares the same chrome_common.js splice as the broadcast client.
  EmbeddedLeagueReplayerHtml = staticRead("../../client/league_replayer.html").replace(
    "<!-- CHROME_COMMON -->",
    "<script>" & staticRead("../../client/chrome_common.js") & "</script>"
  ).spliceWireConstants()
  # SEASON 2 HUMAN SEAT, ported from maxwell/s2-controls-on-seat (byte-matched
  # source, GameVersion 44 -> this GV45 tree; the 8-bit InputState mask and
  # the /player websocket handshake are untouched by the BR bump, per this
  # file's own GameVersion changelog comment in sim_types.nim). Our OWN player
  # client, vendored into this repo rather than patched into the pinned
  # ~/.nimby/pkgs/bitworld package -- the same ELEVATE-BY-REBUILD move the
  # replay routes above already make. player_controls.js carries the
  # keyboard/mouse -> action-space translation and is inlined so the page
  # stays a single self-contained file.
  EmbeddedPlayerClientHtml = staticRead("../../client/player_client.html").replace(
    "<script src=\"player_controls.js\"></script>",
    "<script>" & staticRead("../../client/player_controls.js") & "</script>"
  )
  # Dungeon-wall textures (nanobanana generations) served as static assets so the
  # shell HTML stays small and editable. Wide for top/bottom, tall for side walls.
  # Opaque stone, no alpha → JPEG (q82) keeps each well under any committed sprite.
  # The freeplay takeover shell: the stock player client in a frame plus the
  # seat's takeover state ("suiting up" -> "you're driving"), polled off
  # /takeover/status. Served only when allowSeatTakeover is on.
  EmbeddedTakeoverHtml = staticRead("../../client/takeover.html")
  WallTextureHorizontal = staticRead("../../client/art/walls/wall_h.jpg")
  WallTextureVertical = staticRead("../../client/art/walls/wall_v.jpg")
  # The broadcast client's pre-load curtain scene (nanobanana generations,
  # like the walls): the bot locker room as ONE empty-room plate (bg.jpg)
  # plus five alpha-sprite poses per cog (<bot>_<pose>.webp) that the
  # client layers and cycles on top. One entry per asset, served by path
  # lookup like the soldier art; content type derives from the suffix.
  LockerRoomAssets = [
    ("/client/art/lockerroom/bg.jpg",
      staticRead("../../client/art/lockerroom/bg.jpg")),
    ("/client/art/lockerroom/green_1.webp",
      staticRead("../../client/art/lockerroom/green_1.webp")),
    ("/client/art/lockerroom/green_2.webp",
      staticRead("../../client/art/lockerroom/green_2.webp")),
    ("/client/art/lockerroom/green_3.webp",
      staticRead("../../client/art/lockerroom/green_3.webp")),
    ("/client/art/lockerroom/green_5.webp",
      staticRead("../../client/art/lockerroom/green_5.webp")),
    ("/client/art/lockerroom/green_6.webp",
      staticRead("../../client/art/lockerroom/green_6.webp")),
    ("/client/art/lockerroom/blue_1.webp",
      staticRead("../../client/art/lockerroom/blue_1.webp")),
    ("/client/art/lockerroom/blue_2.webp",
      staticRead("../../client/art/lockerroom/blue_2.webp")),
    ("/client/art/lockerroom/blue_3.webp",
      staticRead("../../client/art/lockerroom/blue_3.webp")),
    ("/client/art/lockerroom/blue_5.webp",
      staticRead("../../client/art/lockerroom/blue_5.webp")),
    ("/client/art/lockerroom/blue_6.webp",
      staticRead("../../client/art/lockerroom/blue_6.webp")),
    ("/client/art/lockerroom/yellow_1.webp",
      staticRead("../../client/art/lockerroom/yellow_1.webp")),
    ("/client/art/lockerroom/yellow_2.webp",
      staticRead("../../client/art/lockerroom/yellow_2.webp")),
    ("/client/art/lockerroom/yellow_3.webp",
      staticRead("../../client/art/lockerroom/yellow_3.webp")),
    ("/client/art/lockerroom/yellow_5.webp",
      staticRead("../../client/art/lockerroom/yellow_5.webp")),
    ("/client/art/lockerroom/yellow_6.webp",
      staticRead("../../client/art/lockerroom/yellow_6.webp")),
    ("/client/art/lockerroom/red_1.webp",
      staticRead("../../client/art/lockerroom/red_1.webp")),
    ("/client/art/lockerroom/red_2.webp",
      staticRead("../../client/art/lockerroom/red_2.webp")),
    ("/client/art/lockerroom/red_3.webp",
      staticRead("../../client/art/lockerroom/red_3.webp")),
    ("/client/art/lockerroom/red_5.webp",
      staticRead("../../client/art/lockerroom/red_5.webp")),
    ("/client/art/lockerroom/red_6.webp",
      staticRead("../../client/art/lockerroom/red_6.webp")),
  ]
  BroadcastFont = staticRead("../../data/font.ttf")
  # Cog art for the first-person EYES PiP billboards (real body + legs + wheels
  # + cyan visor, team-tinted). Served as static PNGs so the raycast view can
  # blit the true cog instead of a procedural chassis.
  #
  # The _front masters are drawn from a HORIZONTAL, eye-level camera with the
  # smile visor tilted up toward the viewer (scripts/art/build_cvc_front.py) —
  # that is what the PiP blits. The plain soldier_{red,blue} masters are the
  # TOP-DOWN board sprites (the cog seen from ABOVE): they stay served as the
  # PiP's fallback, but an overhead projection in an eye-level view reads as a
  # flat plate with the face squashed onto its lower lip, so the front masters
  # are what the billboard actually wants.
  # ...and the same cogs holding their paintball marker forward at the camera.
  # A live cog always carries its gun, so this is the pose the PiP shows for any
  # armed cog; the empty-handed masters cover the unarmed read. One entry per
  # team x {top-down, front, front_gun}, served by path lookup.
  TeamNames: array[Team, string] = block:
    ## teamText as a compile-time table, so paths below can be staticRead.
    var n: array[Team, string]
    for team in Team:
      n[team] = teamText(team)
    n
  SoldierArtAssets = block:
    ## BR INTEGRATION: derived from the enum, not a hand-listed four. This
    ## list used to name Red/Blue/Green/Yellow literally, which meant the 12
    ## BR identities' front masters — present on disk since the tint lane —
    ## were never SERVED, so a plum or azure cog fell back to the top-down
    ## board sprite in the first-person PiP while its teammates in classic
    ## colours got the real eye-level art. That is exactly the "literal
    ## 4-multiplier" hazard BR_MAPGEN.md §6.2 calls out, in asset form.
    ##
    ## staticRead resolves at COMPILE time, so this block is also the
    ## strongest possible assertion that all 2 x 16 front masters exist: a
    ## missing one is a build failure, not a runtime fallback.
    var assets: seq[(string, string)]
    for team in Team:
      assets.add(
        ("/client/soldier_" & TeamNames[team] & "_front.png",
          staticRead("../../data/soldier_" & TeamNames[team] & "_front.png")))
      assets.add(
        ("/client/soldier_" & TeamNames[team] & "_front_gun.png",
          staticRead(
            "../../data/soldier_" & TeamNames[team] & "_front_gun.png")))
    assets
  LeagueReplayerPath = "/client/league"
  WallTextureHorizontalPath = "/client/art/walls/wall_h.jpg"
  WallTextureVerticalPath = "/client/art/walls/wall_v.jpg"
  BroadcastFontPath = "/client/font.ttf"
  # Hosted replay closes any WS frame larger than 1 MiB (sends 1009). We chunk
  # outbound sprite packets under a margin below that so no single frame trips it.
  MaxWsFrameBytes* = 900_000
  # SpriteClientReady (0x85) and SpriteClientDebugSprite (0x86) now come from
  # bitworld/spriteprotocol: the pin carries both, and still keeps ButtonC,
  # which the grenade input bit needs.

proc liveProgressMaxTick(config: GameConfig): int =
  ## Returns the live viewer tick-bar budget.
  if config.maxTicks > 0:
    config.maxTicks
  else:
    MaxTicks

proc liveSpeedIndex(config: GameConfig): int =
  ## Returns the live playback speed index for a config.
  for i, speed in PlaybackSpeeds:
    if speed == config.speed:
      return i
  0

proc isWebSocketUpgrade(request: Request): bool =
  ## Returns true when the GET request is a websocket upgrade.
  request.headers["Sec-WebSocket-Key"].len > 0

proc replayFilePath(uri: string): string =
  ## Resolves one local replay URI to a host path.
  const FilePrefix = "file://"
  if uri.startsWith(FilePrefix):
    return uri[FilePrefix.len .. ^1]
  if "://" in uri:
    return ""
  uri

let replayDownloadPool = newCurlPool(1)

proc loadReplayUri(uri: string): ReplayData =
  ## Loads a replay from a local file URI or HTTP(S) URL.
  parseReplayBytes(readCogameUri(uri, CogameLoadReplayUriEnv))

proc readableReplayUri(uri: string): bool =
  ## Returns true when a replay URI can be opened by this server.
  if uri.len == 0:
    return false
  if uri.startsWith("http://") or uri.startsWith("https://"):
    return replayDownloadPool.head(uri).code == 200
  let path = replayFilePath(uri)
  path.len > 0 and fileExists(path)

proc rewardAddress(address: string): string =
  ## Formats one reward address as host:port.
  let parts = address.splitWhitespace()
  if parts.len >= 2:
    return parts[0] & ":" & parts[1]
  address

var appState: WebSocketAppState

# --- Verify-to-close instrumentation (01b2eead, 2026-08-28) --------------
# DIAGNOSTIC ONLY, additive, no gameplay effect: a lock-free tick heartbeat
# so a churn test can read the tick loop's real cadence without touching
# appState.lock (the thing under test). This lineage (br-demo-assembly,
# 7b0ab22) never received the /health/frame watchdog built on the churn-
# stall investigation branch (maxwell/s2-takeover-shout) -- ported the
# minimum slice needed to verify-to-close: a monotonically increasing
# frame counter, read-only, no lock, served ahead of any locking route.
var verifyFrameCounter: Atomic[int64]

proc markSocketClosed(websocket: WebSocket): bool =
  ## Queues a websocket for closed-socket cleanup and returns true once.
  result = websocket notin appState.closedSockets
  if result:
    appState.closedSockets.add(websocket)

proc initAppState() =
  initLock(appState.lock)
  appState.replayServerMode = false
  appState.replayLoaded = false
  appState.pendingReplayUri = ""
  appState.loadingReplayUri = ""
  appState.currentReplayUri = ""
  appState.resetRequested = false
  appState.kickRequests = @[]
  appState.kickedIdentities = initTable[string, bool]()
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.inputPressedMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.chatMessages = initTable[WebSocket, string]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerAddresses = initTable[WebSocket, string]()
  appState.playerSlots = initTable[WebSocket, int]()
  appState.playerTokens = initTable[WebSocket, string]()
  appState.playerReady = initTable[WebSocket, bool]()
  appState.globalViewers = initTable[WebSocket, GlobalViewerState]()
  appState.playerViewers = initTable[WebSocket, PlayerViewerState]()
  appState.rewardViewers = initTable[WebSocket, bool]()
  appState.takeovers = initTable[WebSocket, SeatTakeover]()
  appState.seatBoard = @[]
  appState.closedSockets = @[]
  appState.nextAnonymousPlayer = 1
  appState.config = defaultGameConfig()

proc comparePendingPlayerJoins(
  a,
  b: PendingPlayerJoin
): int =
  ## Orders pending players by resolved slot and identity.
  result = cmp(a.slotIndex, b.slotIndex)
  if result != 0:
    return
  result = cmp(a.address, b.address)

proc pendingPlayerJoin(
  sim: SimServer,
  websocket: WebSocket
): PendingPlayerJoin =
  ## Resolves one pending websocket into a join candidate.
  result.websocket = websocket
  result.address = appState.playerAddresses.getOrDefault(websocket, "unknown")
  result.requestedSlot = appState.playerSlots.getOrDefault(websocket, -1)
  result.token = appState.playerTokens.getOrDefault(websocket, "")
  result.slotIndex = sim.resolvePlayerSlot(
    result.address,
    result.token,
    result.requestedSlot
  )

proc removePlayerWebSocketState(websocket: WebSocket): int =
  ## Removes player-owned websocket state and returns its former index.
  result = -1
  if websocket in appState.playerViewers:
    appState.playerViewers.del(websocket)
  if websocket in appState.playerIndices:
    result = appState.playerIndices[websocket]
    appState.playerIndices.del(websocket)
  appState.inputMasks.del(websocket)
  appState.inputPressedMasks.del(websocket)
  appState.lastAppliedMasks.del(websocket)
  appState.chatMessages.del(websocket)
  appState.playerAddresses.del(websocket)
  appState.playerSlots.del(websocket)
  appState.playerTokens.del(websocket)
  appState.playerReady.del(websocket)
  appState.spritesOff.del(websocket)
  # Dropping the takeover entry IS the reverse handoff: the next frame finds
  # no driver for that cog and reads the policy socket's mask again.
  appState.takeovers.del(websocket)

proc isPlayerReadyPacket*(message: string): bool =
  ## Returns true for the one-byte Sprite v1 player-ready packet.
  message.len == 1 and message[0].uint8 == SpriteClientReady

proc isSpritesOffPacket*(message: string): bool =
  ## Returns true for the one-byte Sprite v1 sprites-off packet (0x87).
  ## The pinned bitworld predates the packet, so the id is declared here
  ## rather than imported.
  message.len == 1 and message[0].uint8 == 0x87'u8

proc addressIsKicked(address: string): bool =
  ## Returns true when an address is blocked from this match.
  let identity = address.rewardAddress()
  address in appState.kickedIdentities or identity in appState.kickedIdentities

proc registerPlayerWebSocket(
  websocket: WebSocket,
  identity: string,
  slot: int,
  token: string
): bool =
  ## Registers one websocket as a player connection.
  appState.globalViewers.del(websocket)
  appState.rewardViewers.del(websocket)
  discard removePlayerWebSocketState(websocket)
  if identity.addressIsKicked():
    return false
  appState.playerViewers[websocket] = initPlayerViewerState()
  appState.playerAddresses[websocket] = identity
  appState.playerSlots[websocket] = slot
  appState.playerTokens[websocket] = token
  appState.playerIndices[websocket] =
    if appState.replayLoaded:
      -1
    else:
      UnresolvedPlayerIndex
  appState.inputMasks[websocket] = 0
  appState.inputPressedMasks[websocket] = 0
  appState.lastAppliedMasks[websocket] = 0
  appState.playerReady[websocket] = false
  true

proc takeoverSeatTaken(seat: int): bool =
  ## Returns true when a human already holds (or is suiting up for) a seat.
  for _, takeover in appState.takeovers.pairs:
    if takeover.seat == seat:
      return true
  false

proc registerTakeoverWebSocket(
  websocket: WebSocket,
  seat: int,
  name: string,
  directAim: bool
) =
  ## Registers one websocket as a human seat-takeover connection.
  ##
  ## Deliberately NOT a roster registration: no `playerIndices` entry, no
  ## address, no token. The seat keeps its policy connection and its player
  ## index for the whole episode — the human only supplies that index's input
  ## mask once the swap lands, and watches the seat's own fogged view until
  ## it does.
  appState.globalViewers.del(websocket)
  appState.rewardViewers.del(websocket)
  discard removePlayerWebSocketState(websocket)
  appState.playerViewers[websocket] = initPlayerViewerState()
  appState.inputMasks[websocket] = 0
  appState.inputPressedMasks[websocket] = 0
  appState.lastAppliedMasks[websocket] = 0
  # Kept in playerReady only so the client's 0x85 ready packet is consumed by
  # the ready branch instead of falling through to the input decoder. The
  # readiness contract itself never sees it: resetPlayerReady/allPlayersReady
  # walk the frame's `sockets` array, which a takeover socket never enters.
  appState.playerReady[websocket] = false
  appState.takeovers[websocket] = SeatTakeover(
    seat: seat,
    requestedSeat: seat,
    name: name,
    active: false,
    cog: -1,
    observed: false,
    prevAlive: false,
    directAim: directAim,
    aimBrads: -1
  )

proc advanceSeatTakeover(
  takeover: var SeatTakeover,
  cog: int,
  cogAlive: bool,
  instant: bool = false
): bool =
  ## Advances one seat takeover by a frame; returns true on the frame the swap
  ## lands. `cog` is the seat's resolved player index (-1 when the seat has no
  ## cog right now — between matches, or before its policy has joined) and
  ## `cogAlive` is that cog's alive flag this frame.
  ##
  ## The rule, in modes that respawn: a pending takeover goes live on the
  ## cog's next false -> true `alive` edge. That is the one clean moment — the
  ## human always starts a life at spawn, and no cog is ever body-snatched
  ## mid-life. A cog that has yet to be sampled is never an edge (`observed`),
  ## so a human arriving mid-life waits out that life rather than taking the
  ## field at once.
  ##
  ## `instant` (brMode): a single-life elimination cog that is already alive
  ## on the FIRST sampled frame will never produce a false -> true edge — it
  ## only ever goes true -> false once, permanently, on elimination. Gating
  ## on the respawn edge in that mode means the takeover can never land: the
  ## human's socket is attached to the seat's view (so they see a vision
  ## cone) while the seat's input keeps reading from the policy forever (so
  ## an AI keeps driving). So in brMode, land on the very first sampled frame
  ## if the cog is alive right then — still exactly one frame late enough to
  ## avoid landing on a cog that is already dead when the human arrives (that
  ## case falls through to the ordinary edge, same as before).
  takeover.cog = cog
  takeover.cogAlive = cogAlive
  if takeover.active:
    return false
  if takeover.observed and not takeover.prevAlive and cogAlive:
    takeover.active = true
    result = true
  elif instant and not takeover.observed and cogAlive:
    takeover.active = true
    result = true
  takeover.observed = true
  takeover.prevAlive = cogAlive

proc seatWaitTicks(board: seq[SeatSnapshot], seat: int): int =
  ## How long a seat's cog is from its next spawn, in ticks. A cog that is UP
  ## is `int.high`: the swap lands at the next respawn, so a healthy cog is an
  ## unbounded wait, and this refuses to pretend otherwise. A seat with no cog
  ## at all is 0 — a new match lands every pending takeover at the whistle.
  for entry in board:
    if entry.seat == seat:
      return if entry.alive: int.high else: max(entry.respawnTimer, 0)
  0

proc migratePendingTakeovers(board: seq[SeatSnapshot]) =
  ## Re-points a still-PENDING takeover at whichever free seat gets it onto the
  ## field soonest.
  ##
  ## This is what turns "click play" into "play". The swap lands at a cog's next
  ## respawn, so a human handed a healthy cog waits out a whole life — an
  ## unbounded, unexplainable stall while they watch a cog they do not drive.
  ## Nobody arriving at Free Play asked for a PARTICULAR policy seat; they asked
  ## to play. So a pending takeover parks on whichever cog is already down.
  ##
  ## Only pending takeovers move — once someone is driving, the seat is theirs
  ## for good. And a takeover already parked on a DOWNED cog never moves again:
  ## that cog is about to stand up, which is the best case there is, and hopping
  ## off it for a marginally sooner one would be pure thrash.
  if appState.takeovers.len == 0 or board.len == 0:
    return
  var held: seq[int] = @[]
  for _, takeover in appState.takeovers.pairs:
    held.add(takeover.seat)
  for _, takeover in appState.takeovers.mpairs:
    if takeover.active:
      continue
    if seatWaitTicks(board, takeover.seat) != int.high:
      continue                      # already parked on a cog that is down
    var
      bestSeat = -1
      bestWait = int.high
    for entry in board:
      if entry.alive or entry.seat in held:
        continue
      let wait = max(entry.respawnTimer, 0)
      if wait < bestWait:
        bestWait = wait
        bestSeat = entry.seat
    if bestSeat < 0:
      continue
    for i in 0 ..< held.len:
      if held[i] == takeover.seat:
        held[i] = bestSeat
        break
    takeover.seat = bestSeat
    # Re-sampled from scratch on the new seat: the cog is down right now, so
    # the first sample is not an edge and the swap lands on its next spawn.
    takeover.cog = -1
    takeover.observed = false
    takeover.prevAlive = false

proc landSeatTakeoversOnNewMatch() =
  ## Lands every pending takeover at a new match's opening spawn.
  ##
  ## Not redundant with the alive edge: a reset empties the roster and re-seats
  ## it inside ONE locked block, so no frame ever samples the gap and the edge
  ## alone would miss it. A new match is a fresh spawn for every cog — the
  ## cleanest handoff moment there is — so anyone still suiting up takes the
  ## field with the whistle.
  for _, takeover in appState.takeovers.mpairs:
    takeover.active = true
    takeover.observed = false
    takeover.prevAlive = false

proc registerGlobalWebSocket(websocket: WebSocket) =
  ## Registers one websocket as a global viewer connection.
  discard removePlayerWebSocketState(websocket)
  appState.rewardViewers.del(websocket)
  appState.globalViewers[websocket] = initGlobalViewerState()

proc registerRewardWebSocket(websocket: WebSocket) =
  ## Registers one websocket as a reward stream connection.
  discard removePlayerWebSocketState(websocket)
  appState.globalViewers.del(websocket)
  appState.rewardViewers[websocket] = true

proc isPlayerWebSocket(websocket: WebSocket): bool =
  ## Returns true when a websocket is exclusively a player connection.
  result =
    websocket in appState.playerViewers and
      websocket notin appState.globalViewers and
      websocket notin appState.rewardViewers and
      websocket notin appState.takeovers

proc removeWebSocketState(websocket: WebSocket): int =
  ## Removes websocket-owned state and returns its former player index.
  if websocket in appState.globalViewers:
    appState.globalViewers.del(websocket)
  if websocket in appState.rewardViewers:
    appState.rewardViewers.del(websocket)
  result = removePlayerWebSocketState(websocket)

proc removePlayer(sim: var SimServer, websocket: WebSocket) =
  ## Removes a websocket and keeps live player indices consistent.
  let removedIndex = removeWebSocketState(websocket)
  if removedIndex >= 0 and removedIndex < sim.players.len:
    sim.removePlayerAt(removedIndex)
    # Re-index every OTHER socket that already held a resolved array
    # position -- but a socket still waiting on admission is tagged
    # UnresolvedPlayerIndex, not a real position, and that sentinel is
    # always > removedIndex. Decrementing it here (the bug: no exclusion)
    # turns it into a value that is neither a valid index nor the pending
    # sentinel, so the newSockets scan (`== UnresolvedPlayerIndex`) can
    # never find it again -- the socket stays connected forever but is
    # permanently invisible to admission. This is the lobby-fill wedge:
    # any one disconnect mid-fill orphans every OTHER still-pending
    # socket in the same pass, and nothing ever re-scans them.
    for ws, value in appState.playerIndices.mpairs:
      if value > removedIndex and value != UnresolvedPlayerIndex:
        dec value

proc admitPendingJoins(
  sim: var SimServer,
  pendingPlayers: var seq[PendingPlayerJoin],
  socketsToClose: var seq[WebSocket],
  liveOverlays: var seq[DebugOverlay]
): seq[PendingPlayerJoin] =
  ## Admits pending joins in resolved-slot order (the shared core of the main
  ## loop's and the reset path's join resolution): sorts candidates, seats
  ## every join whose slot is exactly the next open one, records the seat in
  ## appState.playerIndices/playerSlots, and grows liveOverlays to the roster.
  ## Returns the joins that were seated so each caller can run its own
  ## bookkeeping (replay join records vs. input-mask resets). Caller holds
  ## appState.lock.
  pendingPlayers.sort(comparePendingPlayerJoins)
  for join in pendingPlayers:
    if join.slotIndex != sim.nextPlayerSlot():
      continue
    try:
      appState.playerIndices[join.websocket] = sim.addPlayer(
        join.address,
        join.requestedSlot,
        join.token
      )
    except CtfError:
      sim.removePlayer(join.websocket)
      socketsToClose.add(join.websocket)
      continue
    appState.playerSlots[join.websocket] =
      sim.players[appState.playerIndices[join.websocket]].joinOrder
    while liveOverlays.len < sim.players.len:
      liveOverlays.add(DebugOverlay())
    result.add(join)

proc cleanPlayerName(name: string): string =
  ## Returns a protocol-safe player display name.
  result = name.strip()
  for ch in result.mitems:
    if ch.isSpaceAscii:
      ch = '_'

proc cleanGuestName*(name: string): string =
  ## Returns a display-safe guest name. Unlike `cleanPlayerName` this keeps
  ## the space — "Green Rookie" is the paintball register the app generates,
  ## and this name never enters the sim, the wire, or the replay: it is seat
  ## metadata the server reports back so a surface can say who is suiting up.
  for ch in name.strip():
    if result.len >= 24:
      break
    if ch.ord >= 32 and ch.ord < 127 and ch notin {'"', '<', '>', '&', '\\'}:
      result.add ch

proc generatedPlayerName*(index: int): string =
  ## Returns the generated display name for an anonymous player index.
  "Player" & $index

proc anonymousPlayerIdentity*(
  nextIndex: var int,
  existingNames: openArray[string]
): string =
  ## Returns a unique generated identity for one nameless player.
  if nextIndex <= 0:
    nextIndex = 1
  while true:
    result = generatedPlayerName(nextIndex)
    inc nextIndex
    var taken = false
    for name in existingNames:
      if name == result:
        taken = true
        break
    if not taken:
      return

proc nextAnonymousPlayerIdentity(): string =
  ## Returns a unique generated identity from current server state.
  {.gcsafe.}:
    withLock appState.lock:
      var existingNames: seq[string] = @[]
      for _, address in appState.playerAddresses.pairs:
        existingNames.add(address)
      for identity in appState.kickedIdentities.keys:
        existingNames.add(identity)
      result = anonymousPlayerIdentity(
        appState.nextAnonymousPlayer,
        existingNames
      )

proc playerIdentity(request: Request, slot: int, token: string): string =
  ## Returns the websocket player identity for rewards and displays.
  let name = request.queryParams.getOrDefault("name", "").cleanPlayerName()
  if name.len > 0:
    return name
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.config.configuredPlayerName(slot, token)
      if result.len > 0:
        return
  result = nextAnonymousPlayerIdentity()

proc playerSlot(request: Request): int =
  ## Returns the requested player slot or -1 for automatic assignment.
  let text = request.queryParams.getOrDefault("slot", "").strip()
  if text.len == 0:
    return -1
  try:
    result = parseInt(text)
  except ValueError:
    return MaxPlayers
  if result < 0 or result >= MaxPlayers:
    return MaxPlayers

proc playerToken(request: Request): string =
  ## Returns the player join token.
  request.queryParams.getOrDefault("token", "").strip()

proc controlHeaders(): HttpHeaders =
  ## Returns headers for admin-panel control requests.
  result["Content-Type"] = "text/plain; charset=utf-8"
  result["Cache-Control"] = "no-cache"
  result["Access-Control-Allow-Origin"] = "*"
  result["Access-Control-Allow-Methods"] = "POST, OPTIONS"
  result["Access-Control-Allow-Headers"] = "Content-Type"

proc respondControl(request: Request, status: int, body: string) =
  ## Sends a plain text control response.
  request.respond(status, controlHeaders(), body)

proc replayControlsDisabled(): bool =
  ## Returns true when live match controls are disabled.
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.replayLoaded

proc replayServerModeEnabled(): bool =
  ## Returns true when the process is serving Coworld replay sessions.
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.replayServerMode

proc disconnectWebSocket(websocket: WebSocket) =
  ## Tears down a player connection immediately.
  when defined(posix):
    let fields = cast[WebSocketSocketFields](websocket)
    discard shutdown(fields.clientSocket, SHUT_RDWR)
  else:
    websocket.close()

proc identityIsKicked(identity: string): bool =
  ## Returns true when an identity is blocked from rejoining this match.
  let rewardIdentity = identity.rewardAddress()
  {.gcsafe.}:
    withLock appState.lock:
      result =
        identity in appState.kickedIdentities or
        rewardIdentity in appState.kickedIdentities

proc respondKicked(request: Request) =
  ## Rejects a kicked player before upgrading to a WebSocket.
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  headers["Connection"] = "close"
  request.respond(409, headers, "player was kicked\n")

proc respondReplayRequestError(request: Request, status: int, body: string) =
  ## Rejects a replay websocket request before upgrade.
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  headers["Connection"] = "close"
  request.respond(status, headers, body)

proc respondForbiddenWebSocket(request: Request, reason: string) =
  ## Rejects a forbidden websocket request before upgrading.
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  headers["Connection"] = "close"
  request.respond(403, headers, reason & "\n")

proc hasPlayerCredentialParams*(name, slot, token: string): bool =
  ## Returns true when query fields identify a player connection.
  name.strip().len > 0 or slot.strip().len > 0 or token.strip().len > 0

proc hasPlayerCredentialParams(request: Request): bool =
  ## Returns true when a websocket request carries player credentials.
  hasPlayerCredentialParams(
    request.queryParams.getOrDefault("name", ""),
    request.queryParams.getOrDefault("slot", ""),
    request.queryParams.getOrDefault("token", "")
  )

proc respondForbiddenViewer(request: Request) =
  ## Rejects a viewer websocket request with player credentials.
  request.respondForbiddenWebSocket(
    "Viewer websocket cannot include player name, slot, or token."
  )

proc configuredPlayerJoinError(
  config: GameConfig,
  address: string,
  slot: int,
  token: string
): string =
  ## Returns a rejection reason for bad configured roster credentials.
  if config.playerJoinAllowed(address, slot, token):
    return ""
  if slot >= MaxPlayers:
    return "Player slot must be between 0 and " & $(MaxPlayers - 1) & "."
  if slot >= config.slots.len:
    if config.closedRoster:
      return "Player slot is outside configured roster."
    return ""
  if slot >= 0 and config.slots[slot].token.len > 0 and
      token != config.slots[slot].token:
    return "Player token does not match configured slot " & $slot & "."
  "Player credentials do not match configured roster."

proc replayRequestUri(request: Request): string =
  ## Returns the replay artifact URI requested by a Coworld replay client.
  request.queryParams.getOrDefault("uri", "").strip()

proc replayUriKnown(uri: string): bool =
  ## Returns true when this URI is queued, loading, or already active.
  if uri.len == 0:
    return false
  {.gcsafe.}:
    withLock appState.lock:
      result =
        uri == appState.pendingReplayUri or
        uri == appState.loadingReplayUri or
        uri == appState.currentReplayUri

proc queueReplayUri(uri: string) =
  ## Queues a replay switch once, even when HTML and websocket requests repeat it.
  if uri.len == 0:
    return
  {.gcsafe.}:
    withLock appState.lock:
      if uri != appState.pendingReplayUri and
          uri != appState.loadingReplayUri and
          uri != appState.currentReplayUri:
        appState.pendingReplayUri = uri

proc recordStartupReplayUri(loaded: bool) =
  ## Records the COGAME_LOAD_REPLAY_URI the process booted with as the active
  ## replay URI. readRuntimeConfig downloads that artifact and drops the URI,
  ## so without this a /client/replay or websocket request naming the same
  ## URI would queue a full reload (fetch + map regen + keyframes) of the
  ## replay that is already serving. Skipped when the startup load failed so
  ## a later request can retry it.
  if not loaded:
    return
  let uri = getEnv(CogameLoadReplayUriEnv).strip()
  if uri.len == 0:
    return
  {.gcsafe.}:
    withLock appState.lock:
      appState.currentReplayUri = uri

proc replayRequestUriOrPending(request: Request): tuple[uri: string, loaded: bool] =
  ## Returns the websocket URI, falling back to the URI captured when serving
  ## /client/replay. Kubernetes service-proxy websocket upgrades do not
  ## preserve query params, so the preceding client HTML request is the durable
  ## place to capture the artifact URI.
  result.uri = request.replayRequestUri()
  {.gcsafe.}:
    withLock appState.lock:
      result.loaded = appState.replayLoaded
      if result.uri.len == 0:
        if appState.pendingReplayUri.len > 0:
          result.uri = appState.pendingReplayUri
        elif appState.loadingReplayUri.len > 0:
          result.uri = appState.loadingReplayUri
        else:
          result.uri = appState.currentReplayUri

proc seatTakeoverEnabled(): bool =
  ## Returns true when this config turns the freeplay takeover mode on.
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.config.allowSeatTakeover

proc takeoverRejection*(
  config: GameConfig,
  seat: int,
  token: string,
  wantsDirectAim: bool,
  seatTaken: bool
): string =
  ## The whole admission gate for a human takeover connection: "" admits,
  ## anything else is the 403 text.
  ##
  ## A proc rather than a chain inside the route because this gate is the only
  ## thing standing between a league server and a client that asks it for play
  ## capabilities, and a gate that is not tested for DISCRIMINATION — admitting
  ## what it should and refusing what it should — is not a gate. Note the
  ## direct-aim arm REFUSES rather than downgrading: a client silently granted
  ## a lesser capability than it asked for would aim at one thing and shoot at
  ## another.
  if not config.allowSeatTakeover:
    return "Seat takeover is not enabled on this server."
  if wantsDirectAim and not config.allowDirectAim:
    return "Direct aim is not enabled on this server."
  if seat < 0 or seat >= MaxPlayers or seat >= config.slots.len:
    return "Seat takeover requires a configured slot."
  if config.slots[seat].token.len > 0 and token != config.slots[seat].token:
    return "Takeover token does not match seat " & $seat & "."
  if seatTaken:
    return "Seat " & $seat & " is already being taken over."
  ""

proc directAimEnabled(): bool =
  ## Returns true when this config arms the human direct-aim channel.
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.config.allowDirectAim

proc capabilitiesJson(): string =
  ## What this server will GRANT a human connection. The same client bundle is
  ## served to league and play servers, so the client feature-DETECTS here
  ## rather than being built two ways. A league config advertises both as
  ## false, and asking anyway is refused at the upgrade — advertising and
  ## enforcement read the same config field, so they cannot drift.
  $(%*{
    "seatTakeover": seatTakeoverEnabled(),
    "directAim": directAimEnabled()
  })

proc pickFreeplaySeat*(
  board: seq[SeatSnapshot],
  taken: seq[int],
  seatCount: int
): tuple[seat, waitTicks: int] =
  ## Picks the seat a Free Play arrival should be handed, and says how long
  ## that arrival will stand around before it drives.
  ##
  ## THE SPEED RULE: prefer a cog that is already DOWN, soonest respawn first.
  ## The swap lands on the cog's next respawn, so handing someone a healthy cog
  ## makes them wait out a whole life for no reason, while a cog with 9 ticks
  ## left on its timer puts them on the field in under half a second. This is
  ## the difference between "click play and play" and "click play and wonder".
  ##
  ## A seat with no cog yet (between matches) is next best: the opening spawn
  ## lands every pending takeover at once. A healthy cog is the last resort,
  ## and its wait is unknowable from here -- reported as -1, never as a guess.
  result = (-1, -1)
  var bestWait = int.high
  for entry in board:
    if entry.seat < 0 or entry.seat >= seatCount or entry.seat in taken:
      continue
    let wait =
      if entry.alive:
        int.high - 1        # ranked last, and its wait is not knowable here
      else:
        max(entry.respawnTimer, 0)
    if wait < bestWait:
      bestWait = wait
      result = (entry.seat, (if entry.alive: -1 else: wait))
  if result.seat >= 0:
    return
  # No roster yet (between matches, or before the policies have joined): any
  # configured seat that nobody holds will land at the opening whistle.
  for seat in 0 ..< seatCount:
    if seat notin taken:
      return (seat, 0)

proc freeplaySeatJson(): string =
  ## The one call an app makes to answer "which seat do I put this person in?".
  ## Returns the seat and the wait in ticks and milliseconds, so a surface can
  ## say "you are in in 0.4s" instead of an unbounded "suiting up...". A wait
  ## of -1 means the cog is healthy and the wait is genuinely not knowable --
  ## reported honestly rather than guessed.
  var
    board: seq[SeatSnapshot] = @[]
    taken: seq[int] = @[]
    seatCount = 0
    enabled = false
  {.gcsafe.}:
    withLock appState.lock:
      enabled = appState.config.allowSeatTakeover
      if enabled:
        board = appState.seatBoard
        seatCount = appState.config.slots.len
        for _, takeover in appState.takeovers.pairs:
          taken.add(takeover.seat)
  if not enabled:
    return $(%*{"enabled": false, "seat": -1})
  let pick = pickFreeplaySeat(board, taken, seatCount)
  $(%*{
    "enabled": true,
    "directAim": directAimEnabled(),
    "seat": pick.seat,
    "waitTicks": pick.waitTicks,
    "waitMs":
      (if pick.waitTicks < 0: -1
       else: pick.waitTicks * 1000 div ReplayFps)
  })

proc takeoverStatusJson(): string =
  ## Returns the seat-takeover state a surface renders: who is on which seat
  ## and whether they are still suiting up. Ordered by seat so the strip does
  ## not reshuffle between polls.
  let enabled = seatTakeoverEnabled()
  var rows: seq[SeatTakeover] = @[]
  {.gcsafe.}:
    withLock appState.lock:
      for _, takeover in appState.takeovers.pairs:
        rows.add(takeover)
  rows.sort(proc (a, b: SeatTakeover): int = cmp(a.seat, b.seat))
  var seats = newJArray()
  for takeover in rows:
    seats.add(%*{
      "seat": takeover.seat,
      "requestedSeat": takeover.requestedSeat,
      "name": takeover.name,
      "state": (if takeover.active: "driving" else: "suiting-up"),
      "cog": takeover.cog,
      "cogAlive": takeover.cogAlive,
      "cogX": takeover.cogX,
      "cogY": takeover.cogY,
      "mask": int(takeover.lastMask),
      "policyMask": int(takeover.policyMask),
      "directAim": takeover.directAim,
      "aimBrads": takeover.aimBrads
    })
  $(%*{
    "enabled": enabled,
    "directAim": directAimEnabled(),
    "seats": seats
  })

proc httpHandler(request: Request) =
  if request.path == HealthPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    request.respond(200, headers, "healthy")
  elif request.path == VerifyFrameHealthPath and request.httpMethod == "GET":
    # Deliberately BEFORE any route that takes appState.lock, and takes no
    # lock itself: a churn-verification tool reads the tick loop's real
    # cadence without depending on the thing under test.
    var headers: HttpHeaders
    headers["Content-Type"] = "application/json; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    headers["Access-Control-Allow-Origin"] = "*"
    request.respond(200, headers, $(%*{
      "tick": verifyFrameCounter.load(),
      "coldDedup": global.coldDedupCalls.load()
    }))
  elif request.path == CapabilitiesPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "application/json; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    headers["Access-Control-Allow-Origin"] = "*"
    request.respond(200, headers, capabilitiesJson())
  elif request.path == TakeoverSeatPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "application/json; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    headers["Access-Control-Allow-Origin"] = "*"
    request.respond(200, headers, freeplaySeatJson())
  elif request.path == TakeoverStatusPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "application/json; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    headers["Access-Control-Allow-Origin"] = "*"
    request.respond(200, headers, takeoverStatusJson())
  elif request.path == TakeoverClientPath and request.httpMethod == "GET":
    if not seatTakeoverEnabled():
      request.respondForbiddenWebSocket(
        "Seat takeover is not enabled on this server."
      )
      return
    var headers: HttpHeaders
    headers["Content-Type"] = "text/html; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    request.respond(200, headers, EmbeddedTakeoverHtml)
  elif request.path == TakeoverWebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    # A human asking to stand in for an occupied seat. The seat's token is the
    # takeover token: whoever the app hands the seat to may drive it.
    let
      seat = request.playerSlot()
      token = request.playerToken()
      requestedName =
        request.queryParams.getOrDefault("name", "").cleanGuestName()
      # Opt-in, and REFUSED rather than ignored when the config does not arm
      # it. A silent downgrade would let a client believe it is pointing while
      # the server is still swinging, and — worse — would let a league server
      # answer a play client at all.
      wantsDirectAim = request.queryParams.getOrDefault("directAim", "") in
        ["1", "true", "yes"]
    var reject = ""
    {.gcsafe.}:
      withLock appState.lock:
        reject = appState.config.takeoverRejection(
          seat, token, wantsDirectAim, seat.takeoverSeatTaken())
    if reject.len > 0:
      request.respondForbiddenWebSocket(reject)
      return
    let websocket = request.upgradeToWebSocket()
    var
      guestName = requestedName
      lost = false
    {.gcsafe.}:
      withLock appState.lock:
        # Re-checked under the lock: two upgrades can race between the
        # pre-upgrade check and here, and a seat takes exactly one human.
        if not appState.config.allowSeatTakeover or seat.takeoverSeatTaken():
          lost = true
        else:
          if guestName.len == 0:
            guestName = "Guest" & $(appState.takeovers.len + 1)
          websocket.registerTakeoverWebSocket(
            seat,
            guestName,
            wantsDirectAim and appState.config.allowDirectAim
          )
    if lost:
      websocket.disconnectWebSocket()
      return
    echo "seat takeover requested: ", guestName, " -> seat ", seat
  elif request.path == WebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let
      slot = request.playerSlot()
      token = request.playerToken()
      identity = request.playerIdentity(slot, token)
    {.gcsafe.}:
      withLock appState.lock:
        let joinError = appState.config.configuredPlayerJoinError(
          identity,
          slot,
          token
        )
        if joinError.len > 0:
          request.respondForbiddenWebSocket(joinError)
          return
    if identity.identityIsKicked():
      request.respondKicked()
      return
    let websocket = request.upgradeToWebSocket()
    var accepted = false
    {.gcsafe.}:
      withLock appState.lock:
        accepted = websocket.registerPlayerWebSocket(identity, slot, token)
    if not accepted:
      websocket.disconnectWebSocket()
      return
    echo "player connected: ", identity
  elif request.path == GlobalWebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    if request.hasPlayerCredentialParams():
      request.respondForbiddenViewer()
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        websocket.registerGlobalWebSocket()
  elif request.path == ReplayWebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    if request.hasPlayerCredentialParams():
      request.respondForbiddenViewer()
      return
    let replayServerMode = replayServerModeEnabled()
    let replayRequest =
      if replayServerMode:
        request.replayRequestUriOrPending()
      else:
        (uri: "", loaded: false)
    if replayServerMode:
      if replayRequest.uri.len == 0 and not replayRequest.loaded:
        request.respondReplayRequestError(400, "missing replay uri\n")
        return
      if replayRequest.uri.len > 0 and
          not replayRequest.uri.replayUriKnown() and
          not replayRequest.uri.readableReplayUri():
        request.respondReplayRequestError(404, "replay uri is not readable\n")
        return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        websocket.registerGlobalWebSocket()
        if replayServerMode and replayRequest.uri.len > 0 and
            replayRequest.uri != appState.pendingReplayUri and
            replayRequest.uri != appState.loadingReplayUri and
            replayRequest.uri != appState.currentReplayUri:
          appState.pendingReplayUri = replayRequest.uri
  elif request.path == AdminWebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    if request.hasPlayerCredentialParams():
      request.respondForbiddenViewer()
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        websocket.registerGlobalWebSocket()
  elif request.path == RewardWebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        websocket.registerRewardWebSocket()
  elif (request.path == ControlRestartPath or request.path == ControlKickPath) and
      request.httpMethod == "OPTIONS":
    request.respondControl(204, "")
  elif request.path == ControlRestartPath and request.httpMethod == "POST":
    if replayControlsDisabled():
      request.respondControl(409, "match controls are disabled for replays\n")
    else:
      {.gcsafe.}:
        withLock appState.lock:
          appState.resetRequested = true
      request.respondControl(202, "restart queued\n")
  elif request.path == ControlKickPath and request.httpMethod == "POST":
    if replayControlsDisabled():
      request.respondControl(409, "match controls are disabled for replays\n")
    else:
      let identity = request.queryParams.getOrDefault(
        "identity",
        ""
      ).cleanPlayerName()
      if identity.len == 0:
        request.respondControl(400, "missing identity\n")
      else:
        {.gcsafe.}:
          withLock appState.lock:
            appState.kickRequests.add(identity)
        request.respondControl(202, "kick queued\n")
  elif request.path in [WallTextureHorizontalPath, WallTextureVerticalPath] and
      request.httpMethod == "GET":
    # Dungeon-wall textures for the League Replayer shell (static JPEG assets).
    var texHeaders: HttpHeaders
    texHeaders["Content-Type"] = "image/jpeg"
    texHeaders["Cache-Control"] = "public, max-age=3600"
    if request.path == WallTextureHorizontalPath:
      request.respond(200, texHeaders, WallTextureHorizontal)
    else:
      request.respond(200, texHeaders, WallTextureVertical)
  elif request.httpMethod == "GET" and (block:
      var lockerHit = false
      for (path, art) in LockerRoomAssets:
        if request.path == path:
          lockerHit = true
          break
      lockerHit):
    # The broadcast client's locker-room loading-scene assets: the JPEG
    # room plate and the per-cog alpha-sprite poses (WebP).
    var lockerHeaders: HttpHeaders
    lockerHeaders["Content-Type"] =
      if request.path.endsWith(".webp"): "image/webp"
      else: "image/jpeg"
    lockerHeaders["Cache-Control"] = "public, max-age=3600"
    for (path, art) in LockerRoomAssets:
      if request.path == path:
        request.respond(200, lockerHeaders, art)
        break
  elif request.httpMethod == "GET" and (block:
      var hit = false
      for (path, art) in SoldierArtAssets:
        if request.path == path:
          hit = true
          break
      hit):
    # Cog art for the EYES PiP billboards (static PNG assets): the _front
    # eye-level masters the billboard blits (with and without the gun); a
    # missing master falls back to the procedural chassis client-side.
    var artHeaders: HttpHeaders
    artHeaders["Content-Type"] = "image/png"
    artHeaders["Cache-Control"] = "public, max-age=3600"
    for (path, art) in SoldierArtAssets:
      if request.path == path:
        request.respond(200, artHeaders, art)
        break
  elif request.path == BroadcastFontPath and request.httpMethod == "GET":
    var fontHeaders: HttpHeaders
    fontHeaders["Content-Type"] = "font/ttf"
    fontHeaders["Cache-Control"] = "public, max-age=3600"
    request.respond(200, fontHeaders, BroadcastFont)
  elif request.path in [
      bitworldClient.ReplayClientRoute,
      bitworldClient.CoworldReplayClientRoute,
      LeagueReplayerPath
    ] and request.httpMethod == "GET":
    if replayServerModeEnabled():
      let replayRequest = request.replayRequestUriOrPending()
      if replayRequest.uri.len == 0 and not replayRequest.loaded:
        request.respondReplayRequestError(400, "missing replay uri\n")
        return
      if replayRequest.uri.len > 0 and
          not replayRequest.uri.replayUriKnown() and
          not replayRequest.uri.readableReplayUri():
        request.respondReplayRequestError(404, "replay uri is not readable\n")
        return
      if replayRequest.uri.len > 0:
        replayRequest.uri.queueReplayUri()
    # The regular replay routes serve the plain designed broadcast client (the
    # board) exactly as before. /client/league is an ADD-ON that serves the
    # walled-pit League Replayer SHELL, which itself embeds the board in an
    # iframe at /client/replay?embed=1 — the board client reads ?embed=1 to hide
    # its own chrome so the shell owns the walls/scorebug/rosters. One websocket,
    # perfect tick sync. (ELEVATE-BY-REBUILD: our HTML, not bitworld's.)
    var replayHeaders: HttpHeaders
    replayHeaders["Content-Type"] = "text/html; charset=utf-8"
    replayHeaders["Cache-Control"] = "no-cache"
    if request.path == LeagueReplayerPath:
      request.respond(200, replayHeaders, EmbeddedLeagueReplayerHtml)
    else:
      request.respond(200, replayHeaders, EmbeddedBroadcastReplayHtml)
  elif request.path in [
      bitworldClient.PlayerClientRoute,
      bitworldClient.PlayerClientHtmlRoute
    ] and request.httpMethod == "GET":
    # Season 2 human seat: ours wins because this branch sits AHEAD of the
    # bitworld fallback below, which would otherwise serve the generic
    # global/spectator client at this same path.
    var playerHeaders: HttpHeaders
    playerHeaders["Content-Type"] = "text/html; charset=utf-8"
    playerHeaders["Cache-Control"] = "no-cache"
    request.respond(200, playerHeaders, EmbeddedPlayerClientHtml)
  elif bitworldClient.serveClientRoute(
    request,
    bitworldClient.GlobalClientRoute
  ):
    discard
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "CTF server")

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) =
  case event
  of OpenEvent:
    var closeKickedSocket = false
    {.gcsafe.}:
      withLock appState.lock:
        if websocket in appState.globalViewers or
            websocket in appState.rewardViewers:
          discard removePlayerWebSocketState(websocket)
        elif websocket.isPlayerWebSocket():
          let address = appState.playerAddresses.getOrDefault(websocket, "")
          if address.addressIsKicked():
            discard removePlayerWebSocketState(websocket)
            closeKickedSocket = true
          elif websocket notin appState.playerIndices:
            appState.playerIndices[websocket] =
              if appState.replayLoaded:
                -1
              else:
                UnresolvedPlayerIndex
            appState.inputMasks[websocket] = 0
            appState.inputPressedMasks[websocket] = 0
            appState.lastAppliedMasks[websocket] = 0
            appState.playerReady[websocket] = false
    if closeKickedSocket:
      websocket.disconnectWebSocket()
  of MessageEvent:
    if message.kind == Ping:
      websocket.send(message.data, Pong)
    elif message.kind == BinaryMessage:
      {.gcsafe.}:
        withLock appState.lock:
          if message.data.isPlayerReadyPacket() and
              websocket in appState.playerReady:
            appState.playerReady[websocket] = true
          elif message.data.isSpritesOffPacket():
            appState.spritesOff[websocket] = true
          elif websocket in appState.globalViewers:
            appState.globalViewers[websocket].applyGlobalViewerMessage(
              message.data
            )
          elif websocket in appState.playerViewers and
              not appState.replayLoaded:
            var
              mask = appState.inputMasks.getOrDefault(websocket, 0)
              pressedMask = appState.inputPressedMasks.getOrDefault(
                websocket,
                0
              )
              chatText = ""
            appState.playerViewers[websocket].applyPlayerViewerMessage(
              message.data,
              mask,
              pressedMask,
              chatText
            )
            appState.inputMasks[websocket] = mask
            appState.inputPressedMasks[websocket] = pressedMask
            if chatText.len > 0:
              appState.chatMessages[websocket] = chatText
  of ErrorEvent, CloseEvent:
    var who = ""
    {.gcsafe.}:
      withLock appState.lock:
        let newlyClosed = markSocketClosed(websocket)
        if newlyClosed and websocket in appState.playerAddresses:
          who = appState.playerAddresses[websocket]
    if who.len > 0:
      echo "player disconnected: ", who

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

proc resetPlayerReady(
  sockets: openArray[WebSocket],
  playerIndices: openArray[int],
  playerCount: int
) =
  ## Clears readiness for active player sockets before sending one frame.
  {.gcsafe.}:
    withLock appState.lock:
      for i, websocket in sockets:
        if i < playerIndices.len and playerIndices[i] >= 0 and
            playerIndices[i] < playerCount and
            websocket in appState.playerReady:
          appState.playerReady[websocket] = false

proc allPlayersReady(
  sockets: openArray[WebSocket],
  playerIndices: openArray[int],
  playerCount: int
): bool =
  ## Returns true when every active player socket sent ready.
  var activePlayers = 0
  {.gcsafe.}:
    withLock appState.lock:
      for i, websocket in sockets:
        if i >= playerIndices.len or playerIndices[i] < 0 or
            playerIndices[i] >= playerCount:
          continue
        inc activePlayers
        if not appState.playerReady.getOrDefault(websocket, false):
          return false
  activePlayers > 0

type
  FrameAdvance = enum
    LateFrame,    ## the frame budget was already spent before the limiter ran
    SkippedFrame, ## fastMode: every player reported ready before the budget
    WaitedFrame   ## slept out the remaining wall-clock frame budget

  PlayerTraffic = object
    bytesTotal, bytesImage, bytesObject, bytesOther: int64

  ServerMetrics = object
    frames: array[FrameAdvance, int]
    players: seq[PlayerTraffic]
    ## Object-update bytes bucketed by BoardObjectPools pool name; ids
    ## outside every pool (map, flags, players, HUD) land in "core".
    objectPools: Table[string, int64]

proc runFrameLimiter(
  previousTick: var MonoTime,
  fastMode: bool,
  sockets: openArray[WebSocket],
  playerIndices: openArray[int],
  playerCount: int
): FrameAdvance =
  let frameDuration = initDuration(microseconds = 1_000_000 div TargetFps)
  var slept = false
  while true:
    let elapsed = getMonoTime() - previousTick
    if elapsed >= frameDuration:
      result = if slept: WaitedFrame else: LateFrame
      break
    if fastMode and sockets.allPlayersReady(playerIndices, playerCount):
      result = SkippedFrame
      break
    let remaining = frameDuration - elapsed
    sleep(max(1, min(2, int(remaining.inMilliseconds))))
    slept = true
  previousTick = getMonoTime()

proc recordTraffic(
  metrics: var ServerMetrics,
  playerIndex: int,
  packet: openArray[uint8]
) =
  ## Tallies one outgoing player packet, split by sprite-protocol message
  ## type: sprite definitions carry pixel maps, board objects carry the
  ## per-tick state; viewport/layer chrome counts as other.
  if playerIndex < 0 or playerIndex >= MaxPlayers or packet.len == 0:
    return
  if playerIndex >= metrics.players.len:
    metrics.players.setLen(playerIndex + 1)
  metrics.players[playerIndex].bytesTotal += packet.len.int64
  var offset = 0
  while offset < packet.len:
    let messageStart = offset
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01:  # sprite: id,w,h (6) + clen (4) + pixels + llen (2) + label
      let compressedLen = packet.readU32(offset + 6)
      offset += 10 + compressedLen
      let labelLen = packet.readU16(offset)
      offset += 2 + labelLen
      metrics.players[playerIndex].bytesImage += int64(offset - messageStart)
    of 0x02, 0x03, 0x04:
      if messageType != 0x04:
        let objectId = packet.readU16(offset)
        metrics.objectPools.mgetOrPut(boardObjectPoolName(objectId), 0) +=
          int64(if messageType == 0x02: 12 else: 3)
      offset += (if messageType == 0x02: 11 elif messageType == 0x03: 2 else: 0)
      metrics.players[playerIndex].bytesObject += int64(offset - messageStart)
    of 0x05, 0x06:
      offset += (if messageType == 0x05: 5 else: 3)
      metrics.players[playerIndex].bytesOther += int64(offset - messageStart)
    else:
      # Unknown message: its size is unknowable, so attribute the remainder
      # and stop — mirrors chunkSpritePacket's bail-out.
      metrics.players[playerIndex].bytesOther += int64(packet.len - messageStart)
      break

proc metricsJson(metrics: ServerMetrics, sim: SimServer, ticks: int): string =
  ## Serializes the performance counters recorded over one server run.
  var players = newJArray()
  for i in 0 ..< metrics.players.len:
    let traffic = metrics.players[i]
    players.add(%*{
      "slot": i,
      "name": if i < sim.players.len: sim.players[i].address else: "",
      "bytesTotal": traffic.bytesTotal,
      "bytesImage": traffic.bytesImage,
      "bytesObject": traffic.bytesObject,
      "bytesOther": traffic.bytesOther
    })
  var objectPools = newJObject()
  for name, bytes in metrics.objectPools:
    objectPools[name] = %bytes
  $(%*{
    "ticks": ticks,
    "frames": {
      "skipped": metrics.frames[SkippedFrame],
      "waited": metrics.frames[WaitedFrame],
      "late": metrics.frames[LateFrame],
      "total": metrics.frames[SkippedFrame] + metrics.frames[WaitedFrame] +
        metrics.frames[LateFrame]
    },
    "objectPools": objectPools,
    "players": players
  })

proc rewardAccountFor(sim: SimServer, address: string): int =
  ## Returns the reward account index for one address.
  for i in 0 ..< sim.rewardAccounts.len:
    if sim.rewardAccounts[i].address == address:
      return i
  -1

proc writeInputFrameMasks(
  replayWriter: var ReplayWriter,
  time: uint32,
  playerIndex: int,
  appliedMask,
  pressedMask: uint8
) =
  ## Writes replay input changes for one sampled player frame.
  if playerIndex < 0 or playerIndex >= replayWriter.lastMasks.len:
    return
  let repeatedPressedMask = pressedMask and replayWriter.lastMasks[playerIndex]
  if repeatedPressedMask != 0:
    replayWriter.writeInputMaskChange(
      time,
      playerIndex,
      replayWriter.lastMasks[playerIndex] and not repeatedPressedMask
    )
  replayWriter.writeInputMaskChange(time, playerIndex, appliedMask)

proc drainPlayerDebugSprites*(
  state: PlayerViewerState,
  time: uint32,
  playerIndex: int,
  replayWriter: var ReplayWriter,
  overlay: var DebugOverlay
) =
  ## Drains, caps, records, and folds one player's pending debug packets.
  let packets = state.pendingDebugSprites
  state.pendingDebugSprites = @[]
  var usedBytes = 0
  for packet in packets:
    if packet.len > MaxDebugSpriteBytesPerTick - usedBytes:
      if not state.debugSpriteLimitWarned:
        echo "debug sprite byte limit exceeded for player ", playerIndex
        state.debugSpriteLimitWarned = true
      continue
    usedBytes += packet.len
    try:
      packet.validateDebugSpritePacket()
      overlay.applyDebugSpritePacket(packet)
    except SpriteProtocolError, SnappyError:
      continue
    replayWriter.writeDebugSprite(time, playerIndex, packet)

proc clearPressedInputMask(input: var InputState, mask: uint8) =
  ## Clears previous input bits that were pressed this frame.
  if (mask and ButtonUp) != 0:
    input.up = false
  if (mask and ButtonDown) != 0:
    input.down = false
  if (mask and ButtonLeft) != 0:
    input.left = false
  if (mask and ButtonRight) != 0:
    input.right = false
  if (mask and ButtonSelect) != 0:
    input.select = false
  if (mask and ButtonA) != 0:
    input.attack = false
  if (mask and ButtonB) != 0:
    input.b = false
  if (mask and ButtonC) != 0:
    input.c = false

proc clearPressedInputMasks(
  inputs: var seq[InputState],
  masks: openArray[uint8]
) =
  ## Clears previous input bits for each per-frame pressed mask.
  for playerIndex, mask in masks:
    if playerIndex < inputs.len:
      inputs[playerIndex].clearPressedInputMask(mask)

proc resetInputMasks(masks: var seq[uint8]) =
  ## Clears all per-frame pressed masks.
  for mask in masks.mitems:
    mask = 0

proc addStatLine(
  packet: var string,
  name, identity: string,
  value: int
) =
  ## Appends one metric line to a reward protocol packet.
  packet.add(name)
  packet.add(' ')
  packet.add(identity)
  packet.add(' ')
  packet.add($value)
  packet.add('\n')

proc buildRewardPacket(sim: SimServer): string {.measure.} =
  ## Builds one reward protocol packet for the current tick.
  for player in sim.players:
    let
      identity = player.address.rewardAddress()
      accountIndex = sim.rewardAccountFor(player.address)
    result.addStatLine("reward", identity, player.reward)
    if accountIndex >= 0:
      let account = sim.rewardAccounts[accountIndex]
      # One wins/games line per ACTIVE team: 2-team games emit exactly the
      # classic wins_red..games_blue quartet, 4-team games add green/yellow.
      for team in sim.teams():
        result.addStatLine("wins_" & teamText(team), identity,
          account.wins[team])
      for team in sim.teams():
        result.addStatLine("games_" & teamText(team), identity,
          account.games[team])
      result.addStatLine("kills", identity, account.kills)
      result.addStatLine("deaths", identity, account.deaths)
      result.addStatLine("captures", identity, account.captures)

proc declarePlayerFailure(slot: int, message: string) =
  ## Publishes the game-declared terminal player failure the platform runner
  ## polls for (COGAME_PLAYER_FAILURE_URI -> player_failure.json), so a lobby
  ## no-show or mid-form drop is charged to the seat that caused it instead of
  ## poisoning the whole episode unattributed. Best-effort: the abort that
  ## follows must never be masked by a declaration write failure, and outside
  ## the platform (env unset) this is a no-op.
  try:
    writeCogameEnv(
      "COGAME_PLAYER_FAILURE_URI",
      $(%*{"failed_policy_index": slot, "message": message}),
      "application/json"
    )
  except CatchableError as e:
    echo "player-failure declaration failed: ", e.msg

proc runServerLoop*(
  host = DefaultHost,
  port = DefaultPort,
  initialConfig = defaultGameConfig(),
  saveReplayPath = "",
  loadReplayPath = "",
  saveScoresPath = "",
  runtimeConfig = RuntimeConfig()
) =
  initAppState()
  if saveReplayPath.len > 0 and loadReplayPath.len > 0:
    raise newException(ReplayError, "Cannot save and load a replay together")
  var replayLoaded = loadReplayPath.len > 0
  var replayData =
    if replayLoaded:
      try:
        loadReplay(loadReplayPath)
      except CatchableError as e:
        # A bad or version-mismatched replay must not kill the server: the
        # viewer would see a dead socket (frozen shell, 0/0 scrubber, empty
        # lives) with no explanation. Serve the empty lobby and say why.
        echo "replay load failed (serving without replay): ", e.msg
        replayLoaded = false
        ReplayData()
    else:
      ReplayData()
  var initializedReplay =
    if replayLoaded:
      initReplayRuntime(replayData, runtimeConfig.mismatchQuit)
    else:
      InitializedReplay()
  var config =
    if replayLoaded: move(initializedReplay.config)
    else: initialConfig
  var
    replayWriter = openReplayWriter(saveReplayPath, config.configJson())
    # Per-cog last RECORDED direct-aim bearing, -1 = channel off. Lives beside
    # the writer it feeds, for the writer's whole life, because the aim stream
    # is deduped exactly like the mask stream: a record is written only when
    # the bearing changes and playback holds it in between.
    lastDirectAim: seq[int] = @[]
    replayPlayer =
      if replayLoaded:
        move(initializedReplay.player)
      else:
        ReplayPlayer()
  startProfileTrace()
  defer:
    finishProfileTrace()
    replayWriter.closeReplayWriter()
  appState.replayLoaded = replayLoaded
  appState.replayServerMode = replayLoaded
  appState.config = config
  recordStartupReplayUri(replayLoaded)

  # Tier-2 event sink. Off unless the platform configured a destination, so a
  # live server that nobody is analysing keeps paying nothing — which is the
  # property `emitEvent`'s `collectEvents` guard exists to preserve.
  #
  # file:// ONLY, and it fails loudly otherwise rather than silently dropping
  # the stream: the dispatcher writes this as a workdir path and the runner
  # uploads the file afterwards, so an http target would mean the contract
  # changed underneath us and the operator needs to know.
  let eventsPath = block:
    let uri = getEnv("COGAME_EVENTS_URI")
    if uri.len == 0:
      ""
    elif uri.startsWith("file://"):
      uri[7 .. ^1]
    else:
      raise newException(
        ValueError,
        "COGAME_EVENTS_URI must be a file:// path, got: " & uri
      )

  # Optional performance-metrics sink, same file:// contract as events.
  let metricsPath = block:
    let uri = getEnv("COGAME_METRICS_URI")
    if uri.len == 0:
      ""
    elif uri.startsWith("file://"):
      uri[7 .. ^1]
    else:
      raise newException(
        ValueError,
        "COGAME_METRICS_URI must be a file:// path, got: " & uri
      )

  var
    sim =
      if replayLoaded: move(initializedReplay.sim)
      else: initSimServer(config)
    lastTick = getMonoTime()
    collectedEvents: seq[SimEvent] = @[]
  sim.collectEvents = eventsPath.len > 0
  block:
    # Bake the supersampled spectator render caches (map, endzone fades,
    # soldier rotations) BEFORE the listener opens: a viewer's first-message
    # clock starts at its successful connect (the coworld certifier allows
    # only seconds), so nothing may be accepted until every frame the loop
    # will ever build can be assembled instantly.
    let warmStart = getMonoTime()
    sim.warmBoardRenderCaches()
    echo "board render caches baked in ",
      (getMonoTime() - warmStart).inMilliseconds, " ms"

  let httpServer = newServer(
    httpHandler,
    websocketHandler,
    workerThreads = 4
  )

  var
    serverThread: Thread[ServerThreadArgs]
    serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(
    serverThread,
    serverThreadProc,
    ServerThreadArgs(server: serverPtr, address: host, port: port)
  )
  httpServer.waitUntilReady()

  var
    liveOverlays: seq[DebugOverlay] = @[]
    prevInputs: seq[InputState]
    liveSpeedIndex = config.liveSpeedIndex()
    gamesPlayed = 0
    serverMetrics = ServerMetrics()
    lastLobbyLeaverSlot = -1  ## last configured slot that left during Lobby;
                              ## blamed if the mid-form drop dissolves the match.
    broadcastTracker =
      if replayLoaded: move(initializedReplay.tracker)
      else: initBroadcastTracker()

  while true:
    discard verifyFrameCounter.fetchAdd(1)
    var
      pendingReplayUri = ""
      sockets: seq[WebSocket] = @[]
      socketsToClose: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      inputs: seq[InputState]
      downInputs: seq[InputState]
      downInputMasks: seq[uint8]
      pressedInputMasks: seq[uint8]
      globalViewers: seq[WebSocket] = @[]
      globalStates: seq[GlobalViewerState] = @[]
      rewardViewers: seq[WebSocket] = @[]
      playerViewerStates: seq[PlayerViewerState] = @[]
      # Human seat takeovers this frame: the cog each human drives, and the
      # sockets that get that cog's view. Kept OUT of `sockets`, which carries
      # the readiness/pacing contract for roster players.
      drivers = initTable[int, WebSocket]()
      takeoverSockets: seq[WebSocket] = @[]
      takeoverCogs: seq[int] = @[]
      takeoverStates: seq[PlayerViewerState] = @[]
      # Where each human-driven cog's cursor is this frame, in map pixels.
      # Indexed BY COG so the step loop can re-derive the bearing after every
      # step — the cursor holds still, but the cog moves under it, and "points
      # wherever the mouse is" has to stay true while you walk.
      aimTargets: seq[tuple[valid: bool, x, y: int]] = @[]
      replayCommands: seq[char] = @[]
      replaySeekTicks: seq[int] = @[]
      shouldReset = false
      quitAfterFrame = false

    {.gcsafe.}:
      withLock appState.lock:
        pendingReplayUri = appState.pendingReplayUri
        appState.pendingReplayUri = ""
        if pendingReplayUri.len > 0:
          appState.loadingReplayUri = pendingReplayUri
    if pendingReplayUri.len > 0:
      var
        pendingData: ReplayData
        pendingOk = true
      try:
        pendingData = loadReplayUri(pendingReplayUri)
      except CatchableError as e:
        # An unreadable or version-mismatched replay must not kill the serve
        # loop (it serves every connected viewer). Keep the current state and
        # log why the switch was refused.
        echo "replay switch failed (keeping current state): ", e.msg
        pendingOk = false
        {.gcsafe.}:
          withLock appState.lock:
            if appState.loadingReplayUri == pendingReplayUri:
              appState.loadingReplayUri = ""
      if pendingOk:
        replayData = pendingData
        initializedReplay = initReplayRuntime(
          replayData,
          runtimeConfig.mismatchQuit
        )
        config = move(initializedReplay.config)
        sim = move(initializedReplay.sim)
        replayPlayer = move(initializedReplay.player)
        broadcastTracker = move(initializedReplay.tracker)
        replayLoaded = true
        # The switched-in sim carries a new map, but the board render caches
        # are process-wide — without this, addMapBands keeps splicing the OLD
        # map's cached band bytes into every new viewer's init packet. Rebake
        # before publishing the switch so the first viewer doesn't pay the
        # supersampled bake inside the serve loop (same budget reasoning as
        # the startup warm above).
        invalidateBoardMapCaches()
        block:
          let warmStart = getMonoTime()
          sim.warmBoardRenderCaches()
          echo "board render caches rebaked in ",
            (getMonoTime() - warmStart).inMilliseconds, " ms"
        {.gcsafe.}:
          withLock appState.lock:
            appState.replayLoaded = true
            appState.config = config
            appState.currentReplayUri = pendingReplayUri
            if appState.loadingReplayUri == pendingReplayUri:
              appState.loadingReplayUri = ""

    {.gcsafe.}:
      withLock appState.lock:
        if not replayLoaded and appState.resetRequested:
          shouldReset = true
          appState.resetRequested = false
          appState.chatMessages.clear()
        for websocket in appState.closedSockets:
          if not replayLoaded and sim.phase == Lobby and
              websocket in appState.playerIndices:
            let leaverSlot = appState.playerSlots.getOrDefault(websocket, -1)
            if leaverSlot >= 0:
              lastLobbyLeaverSlot = leaverSlot
          if not replayLoaded and websocket in appState.playerIndices:
            let playerIndex = appState.playerIndices[websocket]
            if playerIndex >= 0 and playerIndex < sim.players.len:
              sim.recordGameAbandon(playerIndex)
              replayWriter.writeLeave(tickTime(sim.tickCount), playerIndex)
              if playerIndex < replayWriter.lastMasks.len:
                replayWriter.lastMasks.delete(playerIndex)
              if playerIndex < prevInputs.len:
                prevInputs.delete(playerIndex)
              if playerIndex < liveOverlays.len:
                liveOverlays.delete(playerIndex)
          sim.removePlayer(websocket)
        appState.closedSockets.setLen(0)
        if not replayLoaded and appState.kickRequests.len > 0:
          let requestedKicks = appState.kickRequests
          appState.kickRequests = @[]
          var socketsToKick: seq[WebSocket] = @[]
          for websocket, address in appState.playerAddresses.pairs:
            let identity = address.rewardAddress()
            for requestedIdentity in requestedKicks:
              if address == requestedIdentity or identity == requestedIdentity:
                appState.kickedIdentities[address] = true
                appState.kickedIdentities[identity] = true
                if websocket notin socketsToKick:
                  socketsToKick.add(websocket)
          for websocket in socketsToKick:
            if websocket in appState.playerIndices:
              let playerIndex = appState.playerIndices[websocket]
              if playerIndex >= 0 and playerIndex < sim.players.len:
                sim.recordGameAbandon(playerIndex)
                replayWriter.writeLeave(tickTime(sim.tickCount), playerIndex)
                if playerIndex < replayWriter.lastMasks.len:
                  replayWriter.lastMasks.delete(playerIndex)
                if playerIndex < prevInputs.len:
                  prevInputs.delete(playerIndex)
                if playerIndex < liveOverlays.len:
                  liveOverlays.delete(playerIndex)
            sim.removePlayer(websocket)
            socketsToClose.add(websocket)
        if not replayLoaded and sim.lobbyJoinTimedOut():
          # Joins are strictly slot-sequential, so the seat the lobby is stuck
          # waiting on is exactly nextPlayerSlot(). Declare it before dying so
          # the platform charges the no-show to that policy (player_error with
          # failed_policy_index) instead of burning the episode timeout with
          # every seat punished and none attributed.
          let stuckSlot = sim.nextPlayerSlot()
          declarePlayerFailure(
            stuckSlot,
            "player slot " & $stuckSlot & " never joined the lobby within " &
              $sim.config.lobbyJoinTimeoutTicks & " lobby ticks (~" &
              $(sim.config.lobbyJoinTimeoutTicks div TargetFps) & "s)"
          )
          raise newException(
            CtfError,
            "lobby join timeout: slot " & $stuckSlot &
              " never joined within " & $sim.config.lobbyJoinTimeoutTicks &
              " lobby ticks"
          )
        if not replayLoaded and sim.shouldAbortFiniteMatch():
          # Playing/GameOver roster loss now resolves deterministically
          # inside sim.step (recorded leaves re-derive it in replays); only
          # the lobby dissolve and process exit stay live-server concerns.
          if sim.phase == Lobby:
            if lastLobbyLeaverSlot >= 0:
              declarePlayerFailure(
                lastLobbyLeaverSlot,
                "player slot " & $lastLobbyLeaverSlot &
                  " left during the lobby start countdown and dropped the " &
                  "finite match roster below minPlayers"
              )
            raise newException(
              CtfError,
              "finite match roster dropped below minPlayers before roles were assigned"
            )
          quitAfterFrame = true
        if sim.phase != Lobby:
          # A remembered lobby leaver is only blame-worthy while THIS lobby is
          # still forming; once a game starts (or the phase moves on) the slot
          # may be reassigned and must not be charged for a later dissolve.
          lastLobbyLeaverSlot = -1

        if not replayLoaded:
          var newSockets: seq[WebSocket] = @[]
          for websocket in appState.playerIndices.keys:
            if websocket.isPlayerWebSocket() and
                appState.playerIndices[websocket] == UnresolvedPlayerIndex:
              newSockets.add(websocket)
          var progressed = true
          while progressed:
            progressed = false
            var pendingPlayers: seq[PendingPlayerJoin] = @[]
            for websocket in newSockets:
              if websocket notin appState.playerIndices or
                  appState.playerIndices[websocket] != UnresolvedPlayerIndex:
                continue
              let address = appState.playerAddresses.getOrDefault(
                websocket,
                "unknown"
              )
              let identity = address.rewardAddress()
              if address in appState.kickedIdentities or
                  identity in appState.kickedIdentities:
                sim.removePlayer(websocket)
                socketsToClose.add(websocket)
                continue
              let
                slot = appState.playerSlots.getOrDefault(websocket, -1)
                token = appState.playerTokens.getOrDefault(websocket, "")
              if sim.phase == Lobby and
                  (sim.canAddPlayer() or slot >= 0 or token.len > 0):
                try:
                  pendingPlayers.add(sim.pendingPlayerJoin(websocket))
                except CtfError:
                  sim.removePlayer(websocket)
                  socketsToClose.add(websocket)
              else:
                appState.playerIndices[websocket] = -1
            for join in sim.admitPendingJoins(
                pendingPlayers, socketsToClose, liveOverlays):
              replayWriter.writeJoin(
                tickTime(sim.tickCount),
                appState.playerIndices[join.websocket],
                join.address,
                join.requestedSlot,
                join.token
              )
              while replayWriter.lastMasks.len < sim.players.len:
                replayWriter.lastMasks.add(0)
              progressed = true

        # NOTE: d5f8bb6 (s2-play-engine) also carried a "squad construction"
        # block here (squadMode/numAgents/squadAlias/totalCogs/seatPolicyKind)
        # from the unmerged Paintball KOTH lineage, and a seat-liveness-board
        # populate call for the /takeover/seat PICKER route. Both hand-skipped
        # as out of scope for this port (allowDirectAim/allowAimAssist only):
        # squadMode has no definition anywhere on this branch, and the picker
        # is a separate, unrequested feature. The SeatSnapshot type, seatBoard
        # field, seatWaitTicks/migratePendingTakeovers procs and the
        # /takeover/seat route auto-merged in and still compile — they are
        # just never populated, so the route honestly answers "no candidate"
        # (-1) rather than doing anything wrong.
        # ---- seat takeover: resolve each seat, land pending swaps --------
        # A pending takeover goes live on its cog's next false -> true `alive`
        # edge. That is the ONE clean moment: the human always starts a life
        # at spawn and no cog is ever body-snatched mid-fight. The same edge
        # covers a new match — resetToLobby empties the roster (cog -1, so
        # "not alive"), and the seat's first spawn of the next match is the
        # edge — so serve-forever needs no separate case.
        #
        # brMode is the one exception: a single-life elimination cog only
        # ever goes true -> false, once, on elimination -- it never respawns,
        # so the edge above can never fire for a seat that is already alive
        # when the human arrives (the normal BR case). advanceSeatTakeover's
        # `instant` flag lands those seats on the first sampled frame instead.
        if not replayLoaded and appState.takeovers.len > 0:
          for websocket, takeover in appState.takeovers.mpairs:
            var cog = -1
            for i in 0 ..< sim.players.len:
              if sim.players[i].joinOrder == takeover.seat:
                cog = i
                break
            let nowAlive = cog >= 0 and sim.players[cog].alive
            if cog >= 0:
              takeover.cogX = sim.players[cog].x
              takeover.cogY = sim.players[cog].y
            if takeover.advanceSeatTakeover(cog, nowAlive, appState.config.brMode):
              echo "seat takeover live: ", takeover.name, " drives seat ",
                takeover.seat, " (cog ", takeover.cog, ")"
            if takeover.active and takeover.cog >= 0:
              drivers[takeover.cog] = websocket
            if takeover.cog >= 0 and takeover.cog < sim.players.len:
              takeoverSockets.add(websocket)
              takeoverCogs.add(takeover.cog)
              takeoverStates.add(appState.playerViewers[websocket])
            takeover.aimBrads =
              if takeover.cog >= 0 and takeover.cog < lastDirectAim.len:
                lastDirectAim[takeover.cog]
              else:
                -1
            if takeover.active and takeover.directAim and takeover.cog >= 0 and
                appState.config.allowDirectAim:
              let viewer = appState.playerViewers[websocket]
              if viewer.hasMouse:
                while aimTargets.len <= takeover.cog:
                  aimTargets.add((false, 0, 0))
                aimTargets[takeover.cog] = (true, viewer.mouseX, viewer.mouseY)
        if not replayLoaded:
          inputs = newSeq[InputState](sim.players.len)
          downInputs = newSeq[InputState](sim.players.len)
          downInputMasks = newSeq[uint8](sim.players.len)
          pressedInputMasks = newSeq[uint8](sim.players.len)
        for websocket, playerIndex in appState.playerIndices.pairs:
          if not websocket.isPlayerWebSocket():
            continue
          sockets.add(websocket)
          playerIndices.add(playerIndex)
          playerViewerStates.add(appState.playerViewers[websocket])
          if replayLoaded:
            continue
          # THE SWAP, and the whole of it: while a human drives this cog the
          # seat's mask is read off the human's socket instead of the policy's.
          # Same cog, same team, same eight buttons, same replay record under
          # the same player index — only the source of the bits moves. The
          # policy socket is still drained every tick (so nothing piles up)
          # and still receives its view, which is what makes the reverse
          # handoff seamless: it never stopped playing.
          let inputSocket =
            if playerIndex >= 0 and playerIndex in drivers:
              drivers[playerIndex]
            else:
              websocket
          let pressedMask = appState.inputPressedMasks.getOrDefault(
            inputSocket,
            0
          )
          appState.inputPressedMasks[websocket] = 0
          appState.inputPressedMasks[inputSocket] = 0
          if playerIndex < 0 or playerIndex >= inputs.len:
            appState.playerViewers[websocket].pendingDebugSprites = @[]
            continue
          while liveOverlays.len < sim.players.len:
            liveOverlays.add(DebugOverlay())
          appState.playerViewers[websocket].drainPlayerDebugSprites(
            tickTime(sim.tickCount),
            playerIndex,
            replayWriter,
            liveOverlays[playerIndex]
          )
          let currentMask = appState.inputMasks.getOrDefault(inputSocket, 0)
          let appliedMask = currentMask or pressedMask
          inputs[playerIndex] = decodeInputMask(appliedMask)
          downInputs[playerIndex] = decodeInputMask(currentMask)
          downInputMasks[playerIndex] = currentMask
          pressedInputMasks[playerIndex] = pressedMask
          replayWriter.writeInputFrameMasks(
            tickTime(sim.tickCount),
            playerIndex,
            appliedMask,
            pressedMask
          )
          appState.lastAppliedMasks[websocket] = appliedMask
          if inputSocket != websocket and inputSocket in appState.takeovers:
            appState.takeovers[inputSocket].lastMask = appliedMask
            appState.takeovers[inputSocket].policyMask =
              appState.inputMasks.getOrDefault(websocket, 0)
        if not replayLoaded:
          for websocket, chatText in appState.chatMessages.pairs:
            let playerIndex = appState.playerIndices.getOrDefault(
              websocket,
              -1
            )
            if sim.applyShout(playerIndex, chatText):
              replayWriter.writeChat(
                tickTime(sim.tickCount),
                playerIndex,
                chatText
              )
          appState.chatMessages.clear()
        for websocket, state in appState.globalViewers.pairs:
          globalViewers.add(websocket)
          globalStates.add(state)
          if state.replaySeekTick >= 0:
            replaySeekTicks.add(state.replaySeekTick)
          for command in state.replayCommands:
            replayCommands.add(command)
          appState.globalViewers[websocket].replayCommands.setLen(0)
          appState.globalViewers[websocket].replaySeekTick = -1
        for websocket in appState.rewardViewers.keys:
          rewardViewers.add(websocket)

    for websocket in socketsToClose:
      websocket.disconnectWebSocket()

    if shouldReset:
      let rewardAccounts = sim.rewardAccounts
      inc config.seed
      sim = initSimServer(config)
      sim.collectEvents = eventsPath.len > 0
      # One file describes ONE match. A reset that kept the previous match's
      # events would concatenate two games under a single episode id.
      collectedEvents.setLen(0)
      liveOverlays = @[]
      sim.rewardAccounts = rewardAccounts
      prevInputs = @[]
      replayWriter.lastMasks = @[]
      sockets.setLen(0)
      playerIndices.setLen(0)
      rewardViewers.setLen(0)
      playerViewerStates.setLen(0)
      {.gcsafe.}:
        withLock appState.lock:
          appState.kickedIdentities.clear()
          landSeatTakeoversOnNewMatch()
          var reconnectSockets: seq[WebSocket] = @[]
          for websocket in appState.playerIndices.keys:
            if websocket.isPlayerWebSocket():
              reconnectSockets.add(websocket)
          for websocket in reconnectSockets:
            appState.playerIndices[websocket] = UnresolvedPlayerIndex
          var progressed = true
          while progressed:
            progressed = false
            var pendingPlayers: seq[PendingPlayerJoin] = @[]
            for websocket in reconnectSockets:
              if websocket notin appState.playerIndices or
                  appState.playerIndices[websocket] != UnresolvedPlayerIndex:
                continue
              let
                slot = appState.playerSlots.getOrDefault(websocket, -1)
                token = appState.playerTokens.getOrDefault(websocket, "")
              if not sim.canAddPlayer() and slot < 0 and token.len == 0:
                appState.playerIndices[websocket] = -1
                continue
              try:
                pendingPlayers.add(sim.pendingPlayerJoin(websocket))
              except CtfError:
                sim.removePlayer(websocket)
                socketsToClose.add(websocket)
            for join in sim.admitPendingJoins(
                pendingPlayers, socketsToClose, liveOverlays):
              appState.inputMasks[join.websocket] = 0
              appState.inputPressedMasks[join.websocket] = 0
              appState.lastAppliedMasks[join.websocket] = 0
              appState.playerReady[join.websocket] = false
              sockets.add(join.websocket)
              playerIndices.add(appState.playerIndices[join.websocket])
              appState.playerViewers[join.websocket] =
                initPlayerViewerState()
              playerViewerStates.add(appState.playerViewers[join.websocket])
              progressed = true
          replayWriter.lastMasks.setLen(sim.players.len)
          for websocket in appState.rewardViewers.keys:
            rewardViewers.add(websocket)

      let rewardPacket = sim.buildRewardPacket()
      var spritesOffFlags = newSeq[bool](sockets.len)
      {.gcsafe.}:
        withLock appState.lock:
          for i in 0 ..< sockets.len:
            spritesOffFlags[i] =
              appState.spritesOff.getOrDefault(sockets[i], false)
      for i in 0 ..< sockets.len:
        var nextState: PlayerViewerState
        let framePacket = sim.buildSpriteProtocolPlayerUpdates(
          playerIndices[i],
          playerViewerStates[i],
          nextState,
          spritesOff = spritesOffFlags[i]
        )
        {.gcsafe.}:
          withLock appState.lock:
            if sockets[i] in appState.playerViewers:
              appState.playerViewers[sockets[i]] = nextState
        let wirePacket = dedupObjectPlacements(
          if spritesOffFlags[i]: framePacket.stripSpritePixels()
          else: framePacket,
          nextState.sentPlacements
        )
        serverMetrics.recordTraffic(playerIndices[i], wirePacket)
        try:
          if wirePacket.len == 0:
            # One binary message per tick is the frame contract — clients
            # count messages to advance. An all-deduped frame still ships,
            # as an empty message.
            sockets[i].send("", BinaryMessage)
          for chunk in global.chunkSpritePacket(wirePacket, MaxWsFrameBytes):
            sockets[i].send(blobFromBytes(chunk), BinaryMessage)
        except:
          {.gcsafe.}:
            withLock appState.lock:
              discard markSocketClosed(sockets[i])
      for websocket in rewardViewers:
        try:
          websocket.send(rewardPacket, TextMessage)
        except:
          {.gcsafe.}:
            withLock appState.lock:
              discard markSocketClosed(websocket)
      # The lobby always paces at wall clock: fast-forwarding here spins the
      # loop hot on whichever seats joined first, and the appState-lock churn
      # starves mummy's upgrade path so the remaining seats never finish
      # connecting (certifier deadlock at "waiting for players").
      discard runFrameLimiter(
        lastTick, false, sockets, playerIndices, sim.players.len)
      continue

    var frameEvents = newJArray()
    if replayLoaded:
      frameEvents = replayPlayer.advanceReplayFrame(
        sim,
        broadcastTracker,
        replaySeekTicks,
        replayCommands
      )
    else:
      for command in replayCommands:
        liveSpeedIndex.applySpeedCommand(command)
      var
        stepPrevInputs = prevInputs
        stepInputs = inputs
        stepPressedInputMasks = pressedInputMasks
        lastStepInputs = prevInputs
      for _ in 0 ..< playbackSpeed(liveSpeedIndex):
        let phaseBeforeStep = sim.phase
        stepPrevInputs.clearPressedInputMasks(stepPressedInputMasks)
        # ---- direct aim: point the turret, THEN run the tick ------------
        # The one write that makes a human's aim absolute instead of a
        # traverse. Re-derived per STEP, not per frame: at >1x the frame runs
        # several ticks and the cog moves under a still cursor between them.
        #
        # Recorded to the replay in the same breath as it is applied, because
        # this bearing is not a button any mask could carry — a PLAY replay
        # that dropped it would re-simulate the human's match with the turret
        # on its policy heading and every shot missing. Playback applies the
        # held bearing at the matching point in stepReplay, so the two
        # orderings are one ordering.
        #
        # NOTE: d5f8bb6 wrapped the following sim.step in a squadMode-gated
        # try/except (SimGuardError/CatchableError -> a paintball "fault" end
        # condition, EndRuleSimFault/EndRuleHostError). squadMode and those
        # EndRule constants have no definition anywhere on this branch (the
        # unmerged Paintball KOTH lineage) -- hand-skipped, same as the squad
        # construction block above. A CLASSIC/BR game keeps its historical
        # behavior: an exception out of step() propagates and the runner sees
        # the crash, exactly as it did before this cherry-pick.
        if not replayLoaded and appState.config.allowDirectAim:
          for cog in 0 ..< sim.players.len:
            var brads = -1
            if cog < aimTargets.len and aimTargets[cog].valid and
                sim.players[cog].alive:
              brads = sim.players[cog].directAimBrads(
                aimTargets[cog].x, aimTargets[cog].y)
              sim.applyDirectAim(cog, brads)
            replayWriter.writeDirectAimChange(
              lastDirectAim, tickTime(sim.tickCount), cog, brads)
        sim.step(stepInputs, stepPrevInputs)
        if sim.collectEvents:
          # Drained every tick, like the extractor's walk: the sink is a plain
          # seq on the sim and would otherwise grow for the whole match.
          for event in sim.events:
            collectedEvents.add(event)
          sim.events.setLen(0)
        lastStepInputs = stepInputs
        stepPrevInputs = stepInputs
        stepPressedInputMasks.resetInputMasks()
        replayWriter.writeHash(uint32(sim.tickCount), sim.gameHash())
        if stepInputs.len > 0 and stepInputs != downInputs:
          for playerIndex, mask in downInputMasks:
            replayWriter.writeInputMaskChange(
              tickTime(sim.tickCount),
              playerIndex,
              mask
            )
          stepInputs = downInputs
        if config.maxGames > 0 and phaseBeforeStep != GameOver and
            sim.phase == GameOver:
          inc gamesPlayed
        if config.maxGames > 0 and gamesPlayed >= config.maxGames:
          quitAfterFrame = true
          break
        if sim.needsReregister:
          break
      prevInputs = lastStepInputs

    let rewardPacket = sim.buildRewardPacket()

    if not replayLoaded and sim.needsReregister:
      sim.needsReregister = false
      liveOverlays = @[]
      {.gcsafe.}:
        withLock appState.lock:
          for websocket in appState.playerIndices.keys:
            if websocket.isPlayerWebSocket():
              appState.playerIndices[websocket] = UnresolvedPlayerIndex
          for websocket in appState.playerViewers.keys:
            appState.playerViewers[websocket] = initPlayerViewerState()
          landSeatTakeoversOnNewMatch()

    if not replayLoaded and config.fastMode:
      sockets.resetPlayerReady(playerIndices, sim.players.len)

    var spritesOffFlags = newSeq[bool](sockets.len)
    {.gcsafe.}:
      withLock appState.lock:
        for i in 0 ..< sockets.len:
          spritesOffFlags[i] =
            appState.spritesOff.getOrDefault(sockets[i], false)
    for i in 0 ..< sockets.len:
      var nextState: PlayerViewerState
      let framePacket = sim.buildSpriteProtocolPlayerUpdates(
        playerIndices[i],
        playerViewerStates[i],
        nextState,
        spritesOff = spritesOffFlags[i]
      )
      {.gcsafe.}:
        withLock appState.lock:
          if sockets[i] in appState.playerViewers:
            appState.playerViewers[sockets[i]] = nextState
      let wirePacket = dedupObjectPlacements(
        if spritesOffFlags[i]: framePacket.stripSpritePixels()
        else: framePacket,
        nextState.sentPlacements
      )
      serverMetrics.recordTraffic(playerIndices[i], wirePacket)
      try:
        if wirePacket.len == 0:
          # One binary message per tick is the frame contract — clients
          # count messages to advance. An all-deduped frame still ships,
          # as an empty message.
          sockets[i].send("", BinaryMessage)
        for chunk in global.chunkSpritePacket(wirePacket, MaxWsFrameBytes):
          sockets[i].send(blobFromBytes(chunk), BinaryMessage)
      except:
        {.gcsafe.}:
          withLock appState.lock:
            discard markSocketClosed(sockets[i])

    # Humans standing in for a seat see exactly what that seat sees — the same
    # fogged view, built from the cog's index. A separate pass, because a
    # takeover socket must never enter `sockets`: that array is the frame's
    # readiness and traffic contract for roster players.
    for i in 0 ..< takeoverSockets.len:
      var nextState: PlayerViewerState
      let framePacket = sim.buildSpriteProtocolPlayerUpdates(
        takeoverCogs[i],
        takeoverStates[i],
        nextState
      )
      {.gcsafe.}:
        withLock appState.lock:
          if takeoverSockets[i] in appState.playerViewers:
            appState.playerViewers[takeoverSockets[i]] = nextState
      let wirePacket = dedupObjectPlacements(
        framePacket,
        nextState.sentPlacements
      )
      try:
        if wirePacket.len == 0:
          takeoverSockets[i].send("", BinaryMessage)
        for chunk in global.chunkSpritePacket(wirePacket, MaxWsFrameBytes):
          takeoverSockets[i].send(blobFromBytes(chunk), BinaryMessage)
      except:
        {.gcsafe.}:
          withLock appState.lock:
            discard markSocketClosed(takeoverSockets[i])

    for websocket in rewardViewers:
      try:
        websocket.send(rewardPacket, TextMessage)
      except:
        {.gcsafe.}:
          withLock appState.lock:
            discard markSocketClosed(websocket)

    for i in 0 ..< globalViewers.len:
      var nextState: GlobalViewerState
      let packet =
        if replayLoaded:
          sim.buildReplayViewerPacket(
            replayPlayer,
            globalStates[i],
            nextState,
            frameEvents
          )
        else:
          sim.buildSpriteProtocolUpdates(
            globalStates[i],
            nextState,
            liveOverlays,
            sim.tickCount,
            replayPlayer.playing,
            playbackSpeed(liveSpeedIndex),
            liveProgressMaxTick(config),
            replayPlayer.looping,
            false,
            -1
          )
      if packet.len == 0:
        continue
      try:
        # The JSON chrome channel is REPLAY-ONLY. It rides the SAME binary sprite
        # channel as the board — as the label of a reserved never-drawn 1×1
        # sprite (BroadcastChromeSpriteId) — because that is the ONLY channel
        # that survives a hosted replay. The legacy opt-in `TextMessage` path
        # never routes the client→server `hud:on` through the recorded stream,
        # so hosted the HUD froze at its DOM defaults while the board played.
        # Piggybacking on the binary channel makes the chrome survive every
        # playback path (live serve, generic client, hosted replay), with no
        # opt-in. The generic bitworld client simply ignores an unknown sprite id.
        # Ship in WS-frame-sized chunks at message boundaries: the hosted replay
        # viewer closes any frame over 1 MiB (1009 "message too big"). The client
        # accumulates sprite/object state across binary messages, so N chunks are
        # equivalent to one packet. The init frame (banded map + atlas + chrome)
        # is the only one that ever exceeds the cap; steady-state frames pass
        # through as a single chunk.
        for chunk in global.chunkSpritePacket(packet, MaxWsFrameBytes):
          globalViewers[i].send(blobFromBytes(chunk), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            if globalViewers[i] in appState.globalViewers:
              # The websocket thread keeps writing viewer INPUT into this table
              # entry while the frame was being built from an earlier snapshot.
              # Blindly storing nextState would erase any input that arrived in
              # between — a seek/command/click landing there was silently lost
              # (scrub-back from the end screen was the visible casualty).
              # Merge: render state comes from nextState, but the latest mouse
              # fields and any not-yet-collected one-shot inputs survive.
              let pending = appState.globalViewers[globalViewers[i]]
              var merged = nextState
              merged.mouseX = pending.mouseX
              merged.mouseY = pending.mouseY
              merged.mouseLayer = pending.mouseLayer
              merged.mouseDown = pending.mouseDown
              if pending.clickPending:
                merged.clickPending = true
              if pending.replaySeekTick >= 0:
                merged.replaySeekTick = pending.replaySeekTick
              if pending.replayCommands.len > 0:
                merged.replayCommands.add(pending.replayCommands)
              if pending.povSelectPending >= -1:
                merged.povSelectPending = pending.povSelectPending
              appState.globalViewers[globalViewers[i]] = merged
      except:
        {.gcsafe.}:
          withLock appState.lock:
            discard markSocketClosed(globalViewers[i])

    if profileShouldDump(sim.gameTicksElapsed()):
      finishProfileTrace()

    if quitAfterFrame:
      if saveReplayPath.len > 0:
        echo "Writing replay file: ", saveReplayPath
      replayWriter.closeReplayWriter()
      if saveReplayPath.len > 0 and fileExists(saveReplayPath):
        echo "Replay written: ", saveReplayPath,
          " (", getFileSize(saveReplayPath), " bytes)"
        runtimeConfig.writeReplay(readFile(saveReplayPath))
      if eventsPath.len > 0:
        # Always written when a sink is configured, even with zero events: the
        # summary row is how a reader tells "this match had none" from "the
        # upload never happened".
        writeFile(eventsPath, collectedEvents.eventsJsonl(sim.tickCount))
        echo "Events written: ", eventsPath,
          " (", collectedEvents.len, " events, ", getFileSize(eventsPath), " bytes)"
      if runtimeConfig.resultsUri.len > 0:
        let scoresJson = sim.playerResultsJson() & "\n"
        runtimeConfig.writeResults(scoresJson)
      elif saveScoresPath.len > 0:
        writeFile(saveScoresPath, sim.playerResultsJson() & "\n")
        echo "Scores written: ", saveScoresPath,
          " (", getFileSize(saveScoresPath), " bytes)"
      block:
        let framesTotal = serverMetrics.frames[SkippedFrame] +
          serverMetrics.frames[WaitedFrame] + serverMetrics.frames[LateFrame]
        proc pct(part: int): string =
          formatFloat(part.float * 100.0 / max(1, framesTotal).float,
            ffDecimal, 1) & "%"
        echo "Frame pacing: ", framesTotal, " playing frames — skipped ",
          serverMetrics.frames[SkippedFrame], " (",
          pct(serverMetrics.frames[SkippedFrame]), "), waited ",
          serverMetrics.frames[WaitedFrame], " (",
          pct(serverMetrics.frames[WaitedFrame]), "), late ",
          serverMetrics.frames[LateFrame], " (",
          pct(serverMetrics.frames[LateFrame]), ")"
        var totalBytes, imageBytes, objectBytes: int64
        for traffic in serverMetrics.players:
          totalBytes += traffic.bytesTotal
          imageBytes += traffic.bytesImage
          objectBytes += traffic.bytesObject
        proc mb(bytes: int64): string =
          formatFloat(bytes.float / 1e6, ffDecimal, 1) & " MB"
        proc share(part: int64): string =
          formatFloat(part.float * 100.0 / max(1'i64, totalBytes).float,
            ffDecimal, 1) & "%"
        echo "Player traffic: ", mb(totalBytes), " to ",
          serverMetrics.players.len, " players — images ", mb(imageBytes),
          " (", share(imageBytes), "), objects ", mb(objectBytes), " (",
          share(objectBytes), ")"
        if metricsPath.len > 0:
          writeFile(metricsPath,
            serverMetrics.metricsJson(sim, sim.tickCount) & "\n")
          echo "Metrics written: ", metricsPath,
            " (", getFileSize(metricsPath), " bytes)"
      httpServer.close()
      joinThread(serverThread)
      break

    let frameAdvance = runFrameLimiter(
      lastTick,
      not replayLoaded and config.fastMode,
      sockets,
      playerIndices,
      sim.players.len
    )
    # Pacing is only meaningful while a game is actually running: the lobby
    # paces at wall clock by design, and end-card frames idle by design.
    if sim.phase == Playing:
      inc serverMetrics.frames[frameAdvance]
