import
  std/[algorithm, json, locks, monotimes, nativesockets, options, os,
    strutils, tables, times],
  supersnappy,
  bitworld/client as bitworldClient, bitworld/profile, bitworld/spriteprotocol,
  bitworld/runtime,
  curly, mummy,
  sim, global, replays, broadcast, replay_runtime, events, wire_constants,
  control, directives, baselines, decide, mux,
  ../shell/[body, body_map, episode, standing_order, transport],
  ../shell/dispatch, ../shell/packets, ../shell/seats

when defined(posix):
  from std/posix import SHUT_RDWR, shutdown

type
  PlayModuleUploadConsumer* = proc(
    websocket: WebSocket,
    seat: int,
    packet: ModuleUploadPacket,
  ) {.gcsafe.}

  PlayCallConsumer* = proc(
    websocket: WebSocket,
    seat: int,
    packet: PlayCallPacket,
  ) {.gcsafe.}

  PlayStatusAckConsumer* = proc(
    websocket: WebSocket,
    seat: int,
    packet: StatusAckPacket,
  ) {.gcsafe.}

  PlayLobbyChatConsumer* = proc(
    websocket: WebSocket,
    seat: int,
    packet: LobbyChatSendPacket,
  ) {.gcsafe.}

  PlayReceiveConsumers = object
    moduleUpload: PlayModuleUploadConsumer
    playCall: PlayCallConsumer
    statusAck: PlayStatusAckConsumer
    lobbyChat: PlayLobbyChatConsumer

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
    policyPageFlashes: Table[WebSocket, string]
      ## One-page-policy REFLASH inbox, one pending page per seat socket,
      ## drained at the next tick boundary exactly like chatMessages beside
      ## it. A page handed to the sim anywhere but a tick boundary would land
      ## between two hashes and be unrecordable at any single tick, so the
      ## receive side (the websocket handler, which is the policy runner's
      ## half of this feature) never touches the sim — it only drops the page
      ## here.
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
    playProtocolRejected: int
    playSpriteInputIgnored: int
    playSpriteReadyIgnored: int
    playSpriteDebugIgnored: int

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

var playReceiveConsumers: PlayReceiveConsumers

proc registerPlayModuleUploadConsumer*(consumer: PlayModuleUploadConsumer) =
  ## Startup-only registration seam consumed by the play-runtime lane.
  playReceiveConsumers.moduleUpload = consumer

proc registerPlayCallConsumer*(consumer: PlayCallConsumer) =
  ## Startup-only registration seam consumed by the play-runtime lane.
  playReceiveConsumers.playCall = consumer

proc registerPlayStatusAckConsumer*(consumer: PlayStatusAckConsumer) =
  ## Startup-only registration seam consumed by the play-runtime lane.
  playReceiveConsumers.statusAck = consumer

proc registerPlayLobbyChatConsumer*(consumer: PlayLobbyChatConsumer) =
  ## Startup-only registration seam consumed by Maxwell's lobby implementation.
  playReceiveConsumers.lobbyChat = consumer

func defuseScriptClose(src: string): string =
  ## Splicing a staticRead'd JS file inline as `<script>` + content +
  ## `</script>` is only safe if the content never contains the literal
  ## bytes "</script" -- HTML's script-raw-text-end scan matches that
  ## sequence case-insensitively no matter where it sits (inside a JS
  ## string, a `/* comment */`, anywhere), and ends the tag right there,
  ## silently truncating the rest of the file and corrupting whatever
  ## HTML gets parsed after it. player_hud.js's own header comment shows
  ## its `<script src="player_hud.js"></script>` include line as example
  ## text, which trips exactly this. Defuse every occurrence (case
  ## insensitive) by splitting the sequence with a backslash -- inert
  ## inside a JS comment or string, but no longer a tag-close to the
  ## HTML parser -- before any inline splice.
  result = newStringOfCap(src.len)
  var i = 0
  while i < src.len:
    if i + 8 <= src.len and src[i] == '<' and src[i + 1] == '/' and
        src[i + 2 ..< i + 8].toLowerAscii() == "script":
      result.add("<\\/script")
      i += 8
    else:
      result.add(src[i])
      inc i

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
  # source, GameVersion 44 origin; this tree sits on main's GV47 after the
  # wave-1 reconciliation — the 8-bit InputState mask and the /player
  # websocket handshake are untouched by any of it, per sim_types.nim's
  # GameVersion changelog comment). Our OWN player
  # client, vendored into this repo rather than patched into the pinned
  # ~/.nimby/pkgs/bitworld package -- the same ELEVATE-BY-REBUILD move the
  # replay routes above already make. player_controls.js carries the
  # keyboard/mouse -> action-space translation and is inlined so the page
  # stays a single self-contained file. player_hud.js (maxwell/player-hud) gets
  # the same treatment: the inlined <script> block IS what /client/player
  # serves, at compile time (staticRead reads this file's CURRENT bytes into
  # the binary), so the page never depends on a separate runtime fetch for
  # either file, and any branch that edits client/player_hud.js and merges
  # its changes here picks them up automatically on the next build -- no
  # extra wiring needed. Do NOT also add a real <script src="player_hud.js">
  # tag or a server route that serves this file's CONTENT at that URL: the
  # HUD is already loaded via the inline block above, so either one would
  # execute the whole script a second time. `/client/player_hud.js` as a
  # bare URL is intentionally never given real content; the unmatched-path
  # fallback below (see the /client/* 404 branch) is what keeps a stray
  # direct request to it from lying with a 200 instead of failing loud.
  # DO NOT move this HTML to a different serving route or base path. Its
  # OTHER bare <script src=...> tag (snappyjs.min.js) resolves relative to
  # wherever this page is served from -- currently /client/player, which
  # happens to line up with bitworld's OWN generic client router serving
  # /client/snappyjs.min.js (a completely separate staticRead'd asset, from
  # the vendored bitworld package, not this repo's client/ dir). That
  # alignment is accidental, not designed, and there is no static route
  # here to fall back on if it breaks: a human client would silently lose
  # snappy sprite decode, desync mid-packet, and have its websocket closed
  # -- bots keep playing, humans go dark. Changing this route is a decision
  # for whoever owns that risk, not a drive-by tidy-up.
  EmbeddedPlayerClientHtml = staticRead("../../client/player_client.html").replace(
    "<script src=\"player_controls.js\"></script>",
    "<script>" & defuseScriptClose(staticRead("../../client/player_controls.js")) &
      "</script>"
  ).replace(
    "<script src=\"player_hud.js\"></script>",
    "<script>" & defuseScriptClose(staticRead("../../client/player_hud.js")) &
      "</script>"
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
  ShutdownGraceSeconds = 20  ## paintball squad mode: /healthz + /global keep
                             ## answering this long after the artifacts are
                             ## written, then the process exits.
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
  appState.policyPageFlashes = initTable[WebSocket, string]()
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
  appState.playProtocolRejected = 0
  appState.playSpriteInputIgnored = 0
  appState.playSpriteReadyIgnored = 0
  appState.playSpriteDebugIgnored = 0

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
  appState.policyPageFlashes.del(websocket)
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

proc seatWaitTicks(
  board: seq[SeatSnapshot],
  seat: int,
  preferAlive: bool = false
): int =
  ## How long a seat's cog is from its next spawn, in ticks. A cog that is UP
  ## is `int.high`: the swap lands at the next respawn, so a healthy cog is an
  ## unbounded wait, and this refuses to pretend otherwise. A seat with no cog
  ## at all is 0 — a new match lands every pending takeover at the whistle.
  ##
  ## `preferAlive` (brMode) inverts which state is "unbounded": a brMode cog
  ## that is DOWN is permanently eliminated (sim.nim's killPlayer forces
  ## lives=0, respawnTimer=0 for the rest of the round in brMode) and will
  ## never spawn again until the next full match reset, while a cog that is
  ## UP lands the swap on literally the next sampled frame via
  ## advanceSeatTakeover's `instant` branch. So in brMode, ALIVE is the
  ## near-zero wait and DOWN is the unbounded one — the exact opposite of the
  ## respawning-mode rule above.
  for entry in board:
    if entry.seat == seat:
      return
        if preferAlive:
          (if entry.alive: 0 else: int.high)
        else:
          (if entry.alive: int.high else: max(entry.respawnTimer, 0))
  0

proc migratePendingTakeovers(board: seq[SeatSnapshot], preferAlive: bool = false) =
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
  ##
  ## `preferAlive` (brMode): the "good landing spot" and the "keep searching"
  ## target swap places, mirroring seatWaitTicks above -- a takeover already
  ## parked on an ALIVE brMode cog is parked exactly right (the instant branch
  ## lands it on the next sampled frame) and must never be moved off it onto a
  ## cog that is down, which in brMode means permanently eliminated.
  if appState.takeovers.len == 0 or board.len == 0:
    return
  var held: seq[int] = @[]
  for _, takeover in appState.takeovers.pairs:
    held.add(takeover.seat)
  for _, takeover in appState.takeovers.mpairs:
    if takeover.active:
      continue
    if seatWaitTicks(board, takeover.seat, preferAlive) != int.high:
      continue                      # already parked on a good landing spot
    var
      bestSeat = -1
      bestWait = int.high
    for entry in board:
      let isCandidate = if preferAlive: entry.alive else: not entry.alive
      if not isCandidate or entry.seat in held:
        continue
      let wait = if preferAlive: 0 else: max(entry.respawnTimer, 0)
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

proc playSeatIndex(websocket: WebSocket): int =
  ## Returns the stable configured seat for a play socket, or -1. The gate is
  ## intentionally conjunctive: season2Shell on with an all-input roster is
  ## byte-identical to the legacy path.
  let seat = appState.playerSlots.getOrDefault(websocket, -1)
  if appState.config.isPlaySeat(seat):
    return seat
  -1

proc applyPlayerSpriteMessage(websocket: WebSocket, data: string) =
  ## Applies one complete Sprite-protocol WebSocket message. Caller holds
  ## appState.lock; this is the unchanged legacy non-play path.
  var
    mask = appState.inputMasks.getOrDefault(websocket, 0)
    pressedMask = appState.inputPressedMasks.getOrDefault(websocket, 0)
    chatText = ""
    policyPage = ""
  appState.playerViewers[websocket].applyPlayerViewerMessage(
    data,
    mask,
    pressedMask,
    chatText,
    policyPage
  )
  appState.inputMasks[websocket] = mask
  appState.inputPressedMasks[websocket] = pressedMask
  if chatText.len > 0:
    appState.chatMessages[websocket] = chatText
  # The one-page-policy REFLASH receive arm, parked in the inbox the tick
  # loop drains. Admission remains a tick-boundary sim decision.
  if policyPage.len > 0:
    appState.policyPageFlashes[websocket] = policyPage

proc applyPlaySeatSpriteMessage(websocket: WebSocket, data: string) =
  ## Preserves the shared Sprite parser's chat and mouse behavior, but never
  ## lets embedded input or debug-sprite packets cross the play boundary.
  ## Leading forbidden packets are filtered by dispatch; this catches them
  ## behind another legal opcode in the same WebSocket message.
  let
    originalMask = appState.inputMasks.getOrDefault(websocket, 0)
    originalPressedMask =
      appState.inputPressedMasks.getOrDefault(websocket, 0)
    originalDebugCount =
      appState.playerViewers[websocket].pendingDebugSprites.len
  var hasDebugSprite = false
  for item in data.parseSpriteClientMessages():
    if item.kind == SpriteClientDebugSpriteMessage:
      hasDebugSprite = true
  var
    discardedMask = originalMask
    discardedPressedMask = originalPressedMask
    chatText = ""
    policyPage = ""
  appState.playerViewers[websocket].applyPlayerViewerMessage(
    data,
    discardedMask,
    discardedPressedMask,
    chatText,
    policyPage
  )
  if discardedMask != originalMask or
      discardedPressedMask != originalPressedMask:
    inc appState.playSpriteInputIgnored
  if hasDebugSprite:
    appState.playerViewers[websocket].pendingDebugSprites.setLen(
      originalDebugCount)
    inc appState.playSpriteDebugIgnored
  if chatText.len > 0:
    appState.chatMessages[websocket] = chatText

proc dispatchPlaySeatMessage(websocket: WebSocket, seat: int, data: string) =
  ## Owns the play socket's leading-byte switch. Shell framing is decoded
  ## before any Sprite parser sees the message; absent downstream consumers
  ## reject at the seam rather than silently falling into Sprite parsing.
  let received = data.classifyPlaySeatMessage()
  case received.kind
  of prSprite:
    websocket.applyPlaySeatSpriteMessage(received.spriteBytes)
  of prIgnoredSpriteInput:
    inc appState.playSpriteInputIgnored
  of prIgnoredSpriteReady:
    inc appState.playSpriteReadyIgnored
  of prIgnoredSpriteDebug:
    inc appState.playSpriteDebugIgnored
  of prModuleUpload:
    if playReceiveConsumers.moduleUpload == nil:
      inc appState.playProtocolRejected
    else:
      playReceiveConsumers.moduleUpload(websocket, seat, received.moduleUpload)
  of prPlayCall:
    if playReceiveConsumers.playCall == nil:
      inc appState.playProtocolRejected
    else:
      playReceiveConsumers.playCall(websocket, seat, received.playCall)
  of prStatusAck:
    if playReceiveConsumers.statusAck == nil:
      inc appState.playProtocolRejected
    else:
      playReceiveConsumers.statusAck(websocket, seat, received.statusAck)
  of prLobbyChat:
    if playReceiveConsumers.lobbyChat == nil:
      inc appState.playProtocolRejected
    else:
      playReceiveConsumers.lobbyChat(websocket, seat, received.lobbyChat)
  of prRejected:
    inc appState.playProtocolRejected

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

proc playerUpgradeUsesPlaySeatTransport*(config: GameConfig, slot: int): bool =
  ## Chooses the larger socket caps only for a configured play seat under the
  ## conjunctive Season 2 gate. Limits are transport caps, not admission.
  config.isPlaySeat(slot)

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

proc evictSeatTakeover(seat: int) =
  ## Drops whichever websocket currently holds `seat`'s takeover, if any.
  ##
  ## This is the RESUME half of a reload: a browser tab that closes and
  ## reopens (same seat, same token) fires its new /takeover upgrade on a
  ## worker thread that can easily win the race against this process's own
  ## cleanup of the OLD socket -- that cleanup is a once-per-tick affair
  ## (the `closedSockets` drain, main loop), while a page reload's new
  ## connection can land within the same tick the old one's close event is
  ## still queued. Before this proc existed, `takeoverSeatTaken` saw the
  ## stale entry as still live and `takeoverRejection` refused the reconnect
  ## outright (403, at the WS upgrade -- before this engine ever gets a
  ## chance to hand the new socket its one-time arena init), stranding the
  ## reload on the client's blind ~2s retry (see player_client.html's own
  ## comment on that retry: "the SAME identity/slot/token would happily be
  ## re-admitted a moment later" -- true only once this proc closes the gap).
  ##
  ## Callers gate this on the reconnecting request already having proven it
  ## holds the seat's own pinned token (see the call site) -- an UNTOKENED
  ## seat has no secret to check, so it keeps the old first-come-first-served
  ## exclusivity and never reaches here.
  ##
  ## Deliberately drops only the BOOKKEEPING, never calls disconnectWebSocket
  ## on the stale entry: that proc shuts down a raw OS socket FD by number
  ## (WebSocketSocketFields.clientSocket), and the whole reason this websocket
  ## is "stale" is that its underlying connection is already closing or
  ## closed on the client end -- exactly the condition under which the OS is
  ## most likely to have ALREADY recycled that FD number for the brand-new
  ## incoming connection this proc is trying to admit. Shutting it down here
  ## risked shutting down the NEW socket instead (measured: intermittently
  ## reproduced as "Connection closed before receiving a handshake response"
  ## on the reconnecting client). Dropping the state is sufficient: the stale
  ## socket, real or already-gone, simply stops appearing in any per-tick
  ## loop (sockets/takeoverSockets are rebuilt from these tables every tick),
  ## so it is silently retired either way, and its own eventual close event
  ## (if it ever arrives) finds nothing left to clean up.
  var stale: seq[WebSocket] = @[]
  for websocket, takeover in appState.takeovers.pairs:
    if takeover.seat == seat:
      stale.add(websocket)
  for websocket in stale:
    discard removePlayerWebSocketState(websocket)

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
  # A pinned token that matched the line above IS proof of identity: this
  # connection holds the seat's own secret, so it is that seat's rightful
  # human reconnecting (a browser reload is the common case), not a
  # stranger trying to steal an occupied seat. Refusing it here behind a
  # stale/zombie holder -- whose cleanup is a once-per-tick affair the
  # reload's new socket can easily out-race (see evictSeatTakeover) -- is
  # exactly the resume-vs-fresh-join asymmetry that left a reloaded /play
  # tab stuck on the client's blind retry loop with a black arena in the
  # meantime. Only an UNTOKENED seat (no secret to check identity against)
  # keeps the old first-come-first-served exclusivity.
  if seatTaken and config.slots[seat].token.len == 0:
    return "Seat " & $seat & " is already being taken over."
  ""

proc directAimEnabled(): bool =
  ## Returns true when this config arms the human direct-aim channel.
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.config.allowDirectAim

proc aimAssistEnabled(): bool =
  ## Returns true when this config arms freeplay aim assist.
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.config.allowAimAssist

proc calloutsEnabled(): bool =
  ## Returns true when this config arms the callout channel.
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.config.allowCallouts

proc capabilitiesJson(): string =
  ## What this server will GRANT a human connection. The same client bundle is
  ## served to league and play servers, so the client feature-DETECTS here
  ## rather than being built two ways. A league config advertises all four as
  ## false, and asking anyway is refused at the upgrade (or, for aim
  ## assist/callouts, simply never applied) — advertising and enforcement
  ## read the same config fields, so they cannot drift. All four of this
  ## config's armed gates are mirrored here, not just the two the shipped
  ## takeover.html shell happens to read today — a future consumer asking
  ## this endpoint about aim assist or callouts gets a real answer instead of
  ## a silent `undefined`.
  $(%*{
    "seatTakeover": seatTakeoverEnabled(),
    "directAim": directAimEnabled(),
    "allowAimAssist": aimAssistEnabled(),
    "allowCallouts": calloutsEnabled()
  })

proc pickFreeplaySeat*(
  board: seq[SeatSnapshot],
  taken: seq[int],
  seatCount: int,
  preferAlive: bool = false
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
  ##
  ## `preferAlive` (brMode) INVERTS the speed rule: sim.nim's killPlayer
  ## forces lives=0/respawnTimer=0 on a brMode death, permanently -- a brMode
  ## cog reported "down" in a lives:1 game means eliminated for the rest of
  ## the round, not "back in a few ticks", and advanceSeatTakeover's `instant`
  ## branch only ever lands on a cog that is ALIVE on its first sampled frame.
  ## Applying the respawning-mode rule to brMode would confidently hand every
  ## arrival the ONE cog guaranteed to never come back until the next full
  ## reset -- measured before this fix as 7-15s+ mid-round joins climbing
  ## with roster size. So in brMode: alive is the near-zero wait (the instant
  ## branch fires next frame), down is the unknowable one.
  result = (-1, -1)
  var bestWait = int.high
  for entry in board:
    if entry.seat < 0 or entry.seat >= seatCount or entry.seat in taken:
      continue
    let wait =
      if preferAlive:
        (if entry.alive: 0 else: int.high - 1)
      elif entry.alive:
        int.high - 1        # ranked last, and its wait is not knowable here
      else:
        max(entry.respawnTimer, 0)
    if wait < bestWait:
      bestWait = wait
      result = (
        entry.seat,
        if preferAlive: (if entry.alive: 0 else: -1)
        else: (if entry.alive: -1 else: wait)
      )
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
    brMode = false
  {.gcsafe.}:
    withLock appState.lock:
      enabled = appState.config.allowSeatTakeover
      if enabled:
        board = appState.seatBoard
        seatCount = appState.config.slots.len
        brMode = appState.config.brMode
        for _, takeover in appState.takeovers.pairs:
          taken.add(takeover.seat)
  if not enabled:
    return $(%*{"enabled": false, "seat": -1})
  let pick = pickFreeplaySeat(board, taken, seatCount, brMode)
  $(%*{
    "enabled": true,
    "directAim": directAimEnabled(),
    "seat": pick.seat,
    "waitTicks": pick.waitTicks,
    "waitMs":
      (if pick.waitTicks < 0: -1
       else: pick.waitTicks * 1000 div ReplayFps)
  })

proc takeoverStateLabel(takeover: SeatTakeover, brMode: bool): string =
  ## The status word a surface renders for one pending/driving takeover row.
  ##
  ## "driving": the swap has landed, this human is in the sim right now.
  ##
  ## "seated-awaiting-round" (brMode only): the request is bound to a seat
  ## whose cog is down RIGHT NOW in a mode where a down cog never respawns
  ## mid-round (sim.nim's killPlayer forces lives=0/respawnTimer=0 for the
  ## rest of the round in brMode) — so nothing sub-second is coming for this
  ## seat; the swap lands at the next spawn, which in brMode means the next
  ## round (landSeatTakeoversOnNewMatch). Distinct from "suiting-up" so a
  ## client can show honest "you're in next round" copy instead of implying
  ## an imminent respawn that is not going to happen.
  ##
  ## "suiting-up": every other pending case — a CTF cog mid-respawn-timer, a
  ## seat with no cog sampled yet, or a brMode cog that is ALIVE right now and
  ## about to land on literally the next frame (the `instant` path).
  if takeover.active:
    "driving"
  elif brMode and takeover.observed and not takeover.cogAlive:
    "seated-awaiting-round"
  else:
    "suiting-up"

proc takeoverStatusJson(): string =
  ## Returns the seat-takeover state a surface renders: who is on which seat
  ## and whether they are still suiting up. Ordered by seat so the strip does
  ## not reshuffle between polls.
  let enabled = seatTakeoverEnabled()
  var rows: seq[SeatTakeover] = @[]
  var brMode = false
  {.gcsafe.}:
    withLock appState.lock:
      brMode = appState.config.brMode
      for _, takeover in appState.takeovers.pairs:
        rows.add(takeover)
  rows.sort(proc (a, b: SeatTakeover): int = cmp(a.seat, b.seat))
  var seats = newJArray()
  for takeover in rows:
    seats.add(%*{
      "seat": takeover.seat,
      "requestedSeat": takeover.requestedSeat,
      "name": takeover.name,
      "state": takeover.takeoverStateLabel(brMode),
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
  # "/health" (no z) is not a route this server ever defined, but it is the
  # path tooling reaches for by reflex -- and until this fix it fell through
  # to the "CTF server" catch-all below, which answers 200 for literally any
  # unmatched path. That made a monitor curling /health indistinguishable
  # from one curling the real health check: both saw 200. Answered as a real
  # alias of HealthPath (same "healthy" body) rather than 404'd, because
  # something IS already polling it expecting 200 -- this makes that 200
  # true instead of refusing it outright.
  if request.path in [HealthPath, "/health"] and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    request.respond(200, headers, "healthy")
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
        #
        # `tokenProvesIdentity` mirrors takeoverRejection's own reasoning: a
        # non-empty, already-token-matched seat means THIS connection is
        # provably the seat's rightful holder (a reload is the common case),
        # so it supersedes whatever stale/zombie socket still holds the seat
        # (evictSeatTakeover) instead of queuing behind a cleanup pass that
        # only runs once per main-loop tick. An untokened seat has no secret
        # to check identity against, so it keeps the old exclusivity.
        let tokenProvesIdentity =
          seat >= 0 and seat < appState.config.slots.len and
          appState.config.slots[seat].token.len > 0
        if not appState.config.allowSeatTakeover or
            (seat.takeoverSeatTaken() and not tokenProvesIdentity):
          lost = true
        else:
          if seat.takeoverSeatTaken():
            evictSeatTakeover(seat)
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
    var usePlaySeatTransport = false
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
        usePlaySeatTransport =
          appState.config.playerUpgradeUsesPlaySeatTransport(slot)
    if identity.identityIsKicked():
      request.respondKicked()
      return
    let websocket =
      if usePlaySeatTransport:
        request.upgradePlaySeatWebSocket()
      else:
        request.upgradeToWebSocket()
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
  elif request.path in [
      bitworldClient.GlobalClientRoute,
      bitworldClient.CoworldGlobalClientRoute
    ] and request.httpMethod == "GET":
    # LIVE spectator chrome (proof stakes #7/#9): this used to fall straight
    # through to bitworld's bare "Global Viewer" below — a canvas with no
    # teams-alive strip, no endcard, no BR identity, while /client/replay's
    # rich broadcast chrome sat unreachable until AFTER a match was recorded
    # and reloaded as a file. That rich chrome is driven entirely by the
    # global-viewer sprite-protocol stream (ensured by /replay ALSO calling
    # registerGlobalWebSocket() when this process is not a dedicated replay
    # server — see the ReplayWebSocketPath branch below), so a live match and
    # a loaded replay already speak the identical wire protocol to this same
    # HTML; the only thing missing was the route. broadcast_core.js's
    # websocketPathForClientPage() points THIS path's socket at plain /global
    # (GlobalWebSocketPath) rather than /replay, on purpose: the live route
    # must never carry replay-server uri-load semantics, even if this process
    # happens to be configured as one.
    var globalHeaders: HttpHeaders
    globalHeaders["Content-Type"] = "text/html; charset=utf-8"
    globalHeaders["Cache-Control"] = "no-cache"
    request.respond(200, globalHeaders, EmbeddedBroadcastReplayHtml)
  elif bitworldClient.serveClientRoute(
    request,
    bitworldClient.GlobalClientRoute
  ):
    discard
  elif request.path.startsWith("/client/"):
    # An unmatched /client/* path is, by construction, a missing static
    # asset -- e.g. a direct GET to /client/player_hud.js, which names a
    # real file in this repo's client/ dir but is never served at that URL
    # (its content only ever reaches the browser inlined into /client/player
    # -- see the long comment on EmbeddedPlayerClientHtml above). The blanket
    # "CTF server" fallback below returns 200 for that case, which is
    # precisely the failure class that hid this project's worst client bug
    # twice: a status/byte-count check sees a healthy-looking 200 while the
    # body is either ten bytes of plain text a <script> tag would try to
    # execute and die on, or (the prior, worse case) a fully-formed HTML
    # page for the WRONG route. Scoped to the /client/ namespace only --
    # nothing here changes the response for any other unmatched path (root,
    # health probes, etc.), since this lane has no visibility into what
    # external tooling may depend on that behaviour.
    var notFoundHeaders: HttpHeaders
    notFoundHeaders["Content-Type"] = "text/plain"
    request.respond(404, notFoundHeaders, "not found\n")
  elif request.path notin [
      HealthPath, "/health", AdminWebSocketPath, TakeoverWebSocketPath,
      TakeoverStatusPath, TakeoverSeatPath, CapabilitiesPath,
      ControlRestartPath, ControlKickPath, WebSocketPath, GlobalWebSocketPath,
      ReplayWebSocketPath, RewardWebSocketPath
    ]:
    # Same failure class as the /client/* branch above, extended to the rest
    # of the surface: a path outside /client/ that is not one of this
    # server's own top-level routes is, by construction, not a route at all
    # -- e.g. /status or a typo'd /health (before the alias above), both
    # measured live returning 200 "CTF server" and indistinguishable from a
    # real check without reading the body. Investigated before narrowing
    # this: neither the pbnf tooling (pbnf-swap/-route/-deploy all assert on
    # /_app/health, /capabilities, or /api/field content -- never a bare
    # unmatched path) nor the Node proxy in front of this process (app.mjs's
    # own routes own everything under /api/ /lobby/ /match/ /assets/ /_app/
    # and the exact page set; matchd.mjs's readiness probe is a raw TCP
    # connect, no path at all) depends on an unrecognized top-level path
    # answering 200. A path that IS one of ours but got the wrong method or
    # missing upgrade headers still falls to the 200 branch below, unchanged
    # -- this only narrows the "not a route we have at all" case.
    var topLevelNotFoundHeaders: HttpHeaders
    topLevelNotFoundHeaders["Content-Type"] = "text/plain"
    request.respond(404, topLevelNotFoundHeaders, "not found\n")
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
          let playSeat = websocket.playSeatIndex()
          if playSeat >= 0 and websocket in appState.playerViewers and
              not appState.replayLoaded:
            websocket.dispatchPlaySeatMessage(playSeat, message.data)
          elif message.data.isPlayerReadyPacket() and
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
            websocket.applyPlayerSpriteMessage(message.data)
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
    if muxState.enabled:
      withLock muxState.lock:
        for slot in 0 ..< MaxMuxSeats:
          if muxState.seats[slot].joined and
              muxState.seats[slot].playerIndex >= 0 and
              muxState.seats[slot].playerIndex < playerCount:
            muxState.seats[slot].ready = false

proc allPlayersReady(
  sockets: openArray[WebSocket],
  playerIndices: openArray[int],
  playerCount: int
): bool =
  ## Returns true when every active player (socket or mux seat) sent ready.
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
    if muxState.enabled:
      withLock muxState.lock:
        for slot in 0 ..< MaxMuxSeats:
          if muxState.seats[slot].joined and
              muxState.seats[slot].playerIndex >= 0 and
              muxState.seats[slot].playerIndex < playerCount:
            inc activePlayers
            if not muxState.seats[slot].ready:
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
      let compressedLen = packet.packetU32(offset + 6)
      offset += 10 + compressedLen
      let labelLen = packet.packetU16(offset)
      offset += 2 + labelLen
      metrics.players[playerIndex].bytesImage += int64(offset - messageStart)
    of 0x02, 0x03, 0x04:
      if messageType != 0x04:
        let objectId = packet.packetU16(offset)
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
      result.addStatLine("team_kills", identity, account.teamKills)
      result.addStatLine("hit_damage", identity, account.hitDamage)
      result.addStatLine("team_hit_damage", identity, account.teamHitDamage)
      result.addStatLine("deaths", identity, account.deaths)
      result.addStatLine("captures", identity, account.captures)

proc buildShotFeedbackPacket(
  sim: SimServer,
  feedback: seq[ShotFeedbackFx],
  cog: int
): string {.measure.} =
  ## Builds the PRIVATE combat-outcome JSON for one takeover socket's cog
  ## this tick (GameConfig.allowShotFeedback), from whichever entries in
  ## `feedback` name `cog` as shooter or victim — the caller (this proc's one
  ## call site, the takeover send pass below) has already filtered `feedback`
  ## down to entries touching this cog at all, so every entry here matches at
  ## least one of the two branches below.
  ##
  ## Deliberately built here as a plain JSON string, sent as its own
  ## TextMessage — NOT folded into global.nim's sprite/label wire, which is
  ## shared with every policy socket. Returns "" when neither array would
  ## have anything in it, so the caller can skip the send outright.
  ##
  ## Delivered UNFOGGED: no fovVisibleAt check gates victimTeam/victimColor/
  ## killerTeam/killerColor here. See ShotFeedbackFx's doc comment for why —
  ## a direct participant in a combat event is entitled to its outcome
  ## regardless of their own fog at the moment it resolved. This proc never
  ## runs for any other seat, so that exception stays exactly as narrow as
  ## the two participants of each individual event.
  var shotsLanded = newJArray()
  var hitsTaken = newJArray()
  for fx in feedback:
    if fx.shooterIndex == cog and fx.targetIndex >= 0 and
        fx.targetIndex < sim.players.len:
      let victim = sim.players[fx.targetIndex]
      shotsLanded.add(%*{
        "kill": fx.kill,
        "friendlyFire": fx.friendlyFire,
        "weapon": fx.weapon,
        "distance": fx.distance,
        "victimTeam": teamText(victim.team),
        "victimColor": playerColorText(victim.color)
      })
    if fx.targetIndex == cog and fx.shooterIndex >= 0 and
        fx.shooterIndex < sim.players.len:
      let killer = sim.players[fx.shooterIndex]
      var taken = %*{
        "kill": fx.kill,
        "friendlyFire": fx.friendlyFire,
        "weapon": fx.weapon,
        "distance": fx.distance,
        "killerTeam": teamText(killer.team),
        "killerColor": playerColorText(killer.color)
      }
      if fx.kill:
        # Killcam: the killer's position, on the FATAL record ONLY — so the
        # victim's client can point a camera at who got them. A per-hit
        # shooter position would be a live wallhack for a still-standing
        # victim; a dead one cannot move or shoot, so revealing where their
        # killer stood at the death moment is the same narrow, principled
        # fog exception as the unfogged identity fields above and the
        # own-death pop (ShotFeedbackFx's doc comment) — scoped to the one
        # participant the round is already over for. shooterX/shooterY are
        # the impact-moment center captured at the populate site
        # (sim_types.nim); killerAlive is read HERE, at delivery on the
        # death tick, so a mutual trade correctly points the camera at a
        # corpse. Non-fatal entries are byte-identical to before this field
        # existed (nothing is appended), and the gate-off wire is untouched
        # (no record is ever populated).
        taken["killerX"] = %fx.shooterX
        taken["killerY"] = %fx.shooterY
        taken["killerAlive"] = %killer.alive
      hitsTaken.add(taken)
  if shotsLanded.len == 0 and hitsTaken.len == 0:
    return ""
  $(%*{"shotsLanded": shotsLanded, "hitsTaken": hitsTaken})

const CosmeticFxShotSamples = 14
  ## Points sampled along one in-flight shot's beam for the cosmetic-fx
  ## channel below — the same count broadcast.nim's firstPersonJson uses for
  ## the PiP's tracer polyline, kept in step even though this channel draws
  ## top-down (raw world xy) instead of the PiP's projected bearing/range.

proc buildCosmeticFxPacket(
  sim: SimServer,
  viewerIndex: int
): string {.measure.} =
  ## Builds the fog-clipped cosmetic-effects JSON for one takeover socket's
  ## cog this tick (GameConfig.allowCosmeticFx): the two effects
  ## global.nim's addShotTracers/addPaintStains draw for the spectator/
  ## broadcast board only — paint tracers and permanent ground stains —
  ## rebuilt here straight from sim.recentShots/sim.paintStains and
  ## fog-clipped to `viewerIndex` with the same sim.fovVisibleAt check those
  ## two procs (and addSplatters' player path) already use.
  ##
  ## Deliberately a SEPARATE JSON TextMessage, like buildShotFeedbackPacket
  ## beside it — NOT folded into global.nim's sprite/label wire, which is
  ## shared with every policy/mux socket. That is what makes this channel
  ## safe BY CONSTRUCTION rather than by filtering: this proc has exactly
  ## one caller (the takeover send pass below), so a policy's own connection
  ## for this exact seat is simply never a target of the call, regardless of
  ## the gate — see GameConfig.allowCosmeticFx's own doc comment. Returns ""
  ## when nothing survives the fog clip, so the caller can skip the send.
  ##
  ## Wire shape — one effect FAMILY, `kind`-tagged so a future member (a
  ## glory toast, a killstreak) is an additive new object in the same array,
  ## never a new message type:
  ##   {"fx": [
  ##     {"kind":"tracer", "pts":[[x,y]|null, ...], "age":int,
  ##      "color":string, "hit":bool},
  ##     {"kind":"stain", "x":int, "y":int, "color":string, "onWall":bool},
  ##     ...
  ##   ]}
  ## A tracer's `pts` walks muzzle -> impact; a sample this seat's fog does
  ## not currently cover is `null` rather than omitted, so the client BREAKS
  ## the line there instead of drawing a straight shot through fog — the
  ## same contract broadcast.nim's firstPersonJson already uses for the PiP
  ## inset. `color` is the same word playerColorText already gives
  ## buildShotFeedbackPacket's victimColor/killerColor, so the client's
  ## existing colorWordCss() palette lookup (player_client.html) applies
  ## unchanged.
  if not sim.config.allowCosmeticFx:
    return ""
  if viewerIndex < 0 or viewerIndex >= sim.players.len:
    return ""
  var fx = newJArray()
  for shot in sim.recentShots:
    let
      sx0 = float(shot.x0)
      sy0 = float(shot.y0)
      sx1 = float(shot.x1)
      sy1 = float(shot.y1)
    var
      pts = newJArray()
      anyVisible = false
    for s in 0 ..< CosmeticFxShotSamples:
      let
        f = float(s) / float(CosmeticFxShotSamples - 1)
        wx = sx0 + (sx1 - sx0) * f
        wy = sy0 + (sy1 - sy0) * f
      if sim.fovVisibleAt(viewerIndex, int(wx), int(wy)):
        anyVisible = true
        pts.add(%*[int(wx), int(wy)])
      else:
        pts.add(newJNull())
    if not anyVisible:
      continue
    fx.add(%*{
      "kind": "tracer",
      "pts": pts,
      "age": sim.tickCount - shot.firedTick,
      "color": playerColorText(shot.color),
      "hit": shot.hit
    })
  for stain in sim.paintStains:
    if not sim.fovVisibleAt(viewerIndex, stain.x, stain.y):
      continue
    fx.add(%*{
      "kind": "stain",
      "x": stain.x,
      "y": stain.y,
      "color": playerColorText(stain.color),
      "onWall": stain.onWall
    })
  if fx.len == 0:
    return ""
  $(%*{"fx": fx})

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

proc parseRegistration(
  text: string
): tuple[ok: bool, prompt, scripted, policy: string] =
  ## A seat's ONE Sprite v1 chat message, read as its registration:
  ##   {"type":"register","prompt":"…","scripted":"holdline"|null,"policy":"…"}
  ## Anything that is not that object is not a registration.
  result = (false, "", "", "")
  if text.len == 0 or text[0] != '{':
    return
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return
  if node.kind != JObject or node{"type"}.getStr() != "register":
    return
  result.ok = true
  result.prompt = node{"prompt"}.getStr()
  if not node{"scripted"}.isNil and node{"scripted"}.kind == JString:
    result.scripted = node{"scripted"}.getStr()
  result.policy = node{"policy"}.getStr()

proc squadAlias(sim: SimServer, order: int): string =
  ## The ANONYMOUS in-game name of the cog that will occupy slot `order`,
  ## resolved from the config alone so it is identical on every replay.
  toUpperAscii(teamText(sim.teamForSlot(order))) & "-" &
    IdentityNames[sim.slotIdentityIndex(order)]

proc bodyPoint(player: Player): BodyPoint =
  (player.x + CollisionW div 2, player.y + CollisionH div 2)

proc firstLightSelfState(sim: SimServer, playerIndex: int): BodySelfState =
  let player = sim.players[playerIndex]
  let maxHp = max(1, sim.config.maxHpFor(player.team, player.perks))
  BodySelfState(
    pos: player.bodyPoint,
    hpFrac: float(player.hp + player.shieldHp) / float(maxHp + ShieldLayerHp),
    aimBrads: player.aimBrads,
    alive: player.alive,
    carrying: player.carryingFlag)

proc firstLightPartner(sim: SimServer, playerIndex: int): Option[PartnerSample] =
  let player = sim.players[playerIndex]
  for otherIndex, other in sim.players:
    if otherIndex != playerIndex and other.team == player.team and
        other.joinOrder >= 0 and other.joinOrder < MaxPlayers:
      return some(PartnerSample(
        seat: uint8(other.joinOrder),
        pos: other.bodyPoint,
        aimBrads: other.aimBrads,
        alive: other.alive))
  none(PartnerSample)

proc firstLightBodyInputs(sim: var SimServer, playerIndex: int): BodyTickInputs =
  let player = sim.players[playerIndex]
  discard sim.refreshPlayerFov(playerIndex)
  result.self = sim.firstLightSelfState(playerIndex)
  result.partner = sim.firstLightPartner(playerIndex)
  for targetIndex, target in sim.players:
    if targetIndex == playerIndex or not target.alive:
      continue
    if target.team == player.team:
      continue
    if target.joinOrder < 0 or target.joinOrder >= MaxPlayers:
      continue
    if sim.playerVisibleTo(playerIndex, targetIndex):
      result.visibleTracks.add(BodyTrackUpdate(
        seat: target.joinOrder,
        pos: target.bodyPoint,
        team: target.team,
        aimBrads: target.aimBrads,
        hpKnown: some(target.hp + target.shieldHp),
        tick: uint32(sim.tickCount + 1)))

proc ticksToNextZoneShrink(sim: SimServer, elapsedTicks: int): int =
  if sim.config.zonePhases.len == 0:
    return high(int) div 4
  var remaining = max(0, elapsedTicks)
  for phase in sim.config.zonePhases:
    if remaining < phase.waitTicks:
      return phase.waitTicks - remaining
    remaining -= phase.waitTicks
    if remaining < phase.shrinkTicks:
      return 0
    remaining -= phase.shrinkTicks
  high(int) div 4

proc rectCenter(rect: MapRect): BodyPoint =
  (rect.x + rect.w div 2, rect.y + rect.h div 2)

proc firstLightRotateTarget(selfPos: BodyPoint, zone: MapRect): BodyPoint =
  ## FIRST LIGHT fallback fact: pick a short validated goal in the direction of
  ## the next zone. Lane A still owns path planning and the final movement mask.
  const MaxRotateStepPx = 192
  let target = zone.rectCenter
  let dx = target.x - selfPos.x
  let dy = target.y - selfPos.y
  let distance = max(abs(dx), abs(dy))
  if distance <= MaxRotateStepPx:
    target
  else:
    (selfPos.x + dx * MaxRotateStepPx div distance,
     selfPos.y + dy * MaxRotateStepPx div distance)

proc firstLightFallbacks(sim: SimServer,
                         selfPos: BodyPoint): BrDefaultFallbacks =
  let elapsed = sim.tickCount - sim.gameStartTick
  let zone =
    if sim.config.zonePhases.len == 0:
      (cur: MapRect(x: 0, y: 0, w: sim.gameMap.width, h: sim.gameMap.height),
       next: MapRect(x: 0, y: 0, w: sim.gameMap.width, h: sim.gameMap.height),
       dps: 0)
    else:
      sim.zoneRectAndDps(elapsed)
  BrDefaultFallbacks(
    currentZone: zone.cur,
    nextZone: zone.next,
    ticksToNextShrink: sim.ticksToNextZoneShrink(elapsed),
    zoneDps: zone.dps,
    idleAimCenterBrads: 0,
    rotateTarget: some(firstLightRotateTarget(selfPos, zone.next)),
    coverGoal: none(ValidatedGoal))

type FirstLightControlSet = tuple[
  controls: seq[SlotControl],
  hasPlaySeat: bool
]

proc firstLightControlSet(config: GameConfig): FirstLightControlSet =
  for slot in config.slots:
    result.controls.add(slot.control)
    if slot.control == scPlay:
      result.hasPlaySeat = true

proc resetFirstLightForSim(episode: var FirstLightEpisode,
                           replayLoaded: bool,
                           config: GameConfig,
                           sim: SimServer,
                           reason: string) =
  let controlSet = config.firstLightControlSet()
  if not replayLoaded and config.season2Shell and controlSet.hasPlaySeat:
    episode.resetFirstLightEpisode(
      config.season2Shell, config.brMode, controlSet.controls,
      newBodyMap(sim.gameMap), config.gunRange)
    echo "FIRST_LIGHT enabled play_seats=", episode.seats.len,
      " executor=lane-a-fl-b reset=", reason
  else:
    episode = FirstLightEpisode()

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

  # --- mux transport (RL training) -----------------------------------------
  # COGAME_MUX_SOCKET multiplexes every policy seat of this env over ONE Unix
  # domain socket (see ctf/mux.nim). Unset (prod, live play): no listener, no
  # behavior change anywhere.
  let muxSocketPath = getEnv("COGAME_MUX_SOCKET")
  if muxSocketPath.len > 0:
    if replayLoaded:
      raise newException(CtfError, "COGAME_MUX_SOCKET is not a replay-mode transport")
    startMux(muxSocketPath)
  defer: closeMux()
  var muxViewers: array[MaxMuxSeats, PlayerViewerState]

  # --- paintball squad mode -------------------------------------------------
  # `num_agents` seats drive `num_agents * cogsPerTeam` cogs. The seats join
  # exactly as the starter's players do (slots 0..num_agents-1, token-checked);
  # once they are all in, the server fills the rest of the squads with trusted
  # joins carrying only the cogs' ANONYMOUS aliases, and from then on every
  # actuator mask comes from the control layer rather than from a socket.
  let squadMode = not replayLoaded and config.numAgents > 0 and
    config.cogsPerTeam > 1
  var
    engine =
      if squadMode: initDecisionEngine(sim) else: DecisionEngine()
    squadsBuilt = false
    squadForceStart = false
    lastTurnKey = -1
    episodeStart = getMonoTime()
    deadlineHit = false
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
    firstLightEpisode: FirstLightEpisode

  # FIRST LIGHT is reachable only under the two-part runtime gate. Gate-on
  # with an all-input roster and every gate-off configuration leave the zero
  # value untouched and never call into the episode owner.
  firstLightEpisode.resetFirstLightForSim(replayLoaded, config, sim, "startup")

  while true:
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

    # The engine's own hard stop, checked before anything else this
    # iteration: `wallClockBudgetSeconds` is 57.5% of the assumed 1200 s
    # episodeTimeoutSeconds, so paintball always settles and scores itself
    # rather than being silently discarded for overrunning.
    if squadMode and not deadlineHit and
        (getMonoTime() - episodeStart).inSeconds.int >=
          config.wallClockBudgetSeconds:
      deadlineHit = true
      sim.endReason = ReasonDeadline
      sim.endRule = EndRuleWallClock
      let leader = sim.hillLeader()
      echo "wall-clock budget of ", config.wallClockBudgetSeconds,
        "s reached; settling the episode from the hill counts at this tick"
      sim.finishGame(leader.team, isDraw = leader.draw)
      quitAfterFrame = true

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
        firstLightEpisode.resetFirstLightForSim(
          replayLoaded, config, sim, "replay_switch")
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
          appState.policyPageFlashes.clear()
        for websocket in appState.closedSockets:
          if squadMode:
            # A seat that drops does NOT remove its cogs: the squad is fixed
            # for the whole episode, its directive source degrades to the
            # holdline baseline, and the seat revives on reconnect. Deleting
            # the row would renumber every later cog mid-replay.
            discard removeWebSocketState(websocket)
            continue
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
        if squadMode and not squadsBuilt and sim.lobbyJoinTimedOut():
          # A seat that never connects does NOT end the episode. Report the
          # no-show to the platform (lowest missing slot only), then build the
          # squads anyway: that seat's cogs run the published holdline
          # baseline for the whole episode and both games play to full time.
          let stuckSlot = sim.nextPlayerSlot()
          declarePlayerFailure(
            stuckSlot,
            "player slot " & $stuckSlot & " never joined the lobby within " &
              $sim.config.lobbyJoinTimeoutTicks & " lobby ticks (~" &
              $(sim.config.lobbyJoinTimeoutTicks div TargetFps) &
              "s); its squad plays the holdline baseline"
          )
          squadForceStart = true
        if not replayLoaded and not squadMode and sim.lobbyJoinTimedOut():
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
        if not replayLoaded and not squadMode and sim.shouldAbortFiniteMatch():
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
            # Mux seats join through the same strictly slot-sequential
            # admission: a pending mux JOIN is seated exactly when its slot is
            # the next open one, interleaving freely with websocket joins
            # (external baseline bots keep using websockets).
            if muxState.enabled and sim.phase == Lobby:
              var muxJoins: seq[MuxJoinRequest] = @[]
              withLock muxState.lock:
                muxJoins = muxState.pendingJoins
              for join in muxJoins:
                if join.slot != sim.nextPlayerSlot():
                  continue
                # Same identity resolution as the websocket upgrade path: a
                # token that names a configured slot plays under that slot's
                # configured identity.
                let configuredName =
                  sim.config.configuredPlayerName(join.slot, join.token)
                let address =
                  if configuredName.len > 0: configuredName else: join.address
                var admittedIndex = -1
                try:
                  admittedIndex = sim.addPlayer(address, join.slot, join.token)
                except CtfError as error:
                  echo "mux: join for slot ", join.slot, " refused: ", error.msg
                withLock muxState.lock:
                  for i in 0 ..< muxState.pendingJoins.len:
                    if muxState.pendingJoins[i].slot == join.slot:
                      muxState.pendingJoins.delete(i)
                      break
                  if admittedIndex >= 0:
                    muxState.seats[join.slot].playerIndex = admittedIndex
                    muxState.seats[join.slot].ready = false
                if admittedIndex >= 0:
                  muxViewers[join.slot] = initPlayerViewerState()
                  replayWriter.writeJoin(
                    tickTime(sim.tickCount), admittedIndex, address,
                    join.slot, join.token)
                  while replayWriter.lastMasks.len < sim.players.len:
                    replayWriter.lastMasks.add(0)
                  while liveOverlays.len < sim.players.len:
                    liveOverlays.add(DebugOverlay())
                  progressed = true

          # --- squad construction ------------------------------------------
          # Once every seat is seated (or the lobby budget expired and a
          # no-show has been reported), fill the rest of both squads with
          # trusted joins. The cogs carry ONLY their anonymous aliases, so the
          # replay's join stream leaks no policy identity; the real names ride
          # in the config JSON and in the redacted `register` records.
          if squadMode and not squadsBuilt and sim.phase == Lobby and
              (sim.players.len >= config.numAgents or squadForceStart):
            for order in sim.players.len ..< sim.totalCogs():
              try:
                discard sim.addPlayer(
                  sim.squadAlias(order), order, "", trusted = true)
              except CtfError as error:
                echo "squad construction failed at cog ", order, ": ",
                  error.msg
                break
              replayWriter.writeJoin(
                tickTime(sim.tickCount), order, sim.squadAlias(order),
                order, "")
              while replayWriter.lastMasks.len < sim.players.len:
                replayWriter.lastMasks.add(0)
              while liveOverlays.len < sim.players.len:
                liveOverlays.add(DebugOverlay())
            squadsBuilt = sim.players.len >= sim.totalCogs()
            if squadsBuilt:
              for seat in 0 ..< config.numAgents:
                if seat < sim.players.len and seat <= sim.seatNames.high:
                  sim.seatNames[seat] = sim.players[seat].address
                  sim.seatPolicyKind[seat] = engine.policyKind(seat)
              echo "squads built: ", sim.players.len, " cogs, ",
                config.numAgents, " seats, regime ", regimeText(sim.regime)

        # (The Paintball KOTH squad-construction block that earlier ports of
        # this branch hand-skipped is REAL now: the season-2 wave-1 merge
        # brought the paintball lineage in, and the restored block sits
        # directly above.)
        #
        # The seat-liveness-board populate call was ALSO hand-skipped on this
        # port (see git blame on this comment) -- the SeatSnapshot type,
        # seatBoard field, and seatWaitTicks/migratePendingTakeovers procs
        # auto-merged in and still compiled, so nothing errored, but with the
        # board never written the /takeover/seat PICKER route answered "no
        # candidate" (-1) forever, on EVERY config, which pushed every Free
        # Play arrival onto the app's own blind local fallback pick (no
        # aliveness information at all) instead of this engine's live one.
        # THIS is the seat-resolution delay family's root cause on the
        # engine side: restored here, plus a brMode-aware ranking
        # (pickFreeplaySeat/seatWaitTicks/migratePendingTakeovers all take a
        # `preferAlive` param now) -- the un-inverted ranking would have
        # confidently pointed every BR arrival at whichever cog is
        # PERMANENTLY eliminated (brMode death forces respawnTimer=0
        # forever, sim.nim's killPlayer), which is worse than the blind
        # fallback it replaces, not better.
        # Already inside this loop's own `withLock appState.lock:` (opened
        # above this whole admission block) -- appState.seatBoard is written
        # directly, never through a second acquire, which would deadlock on
        # a non-recursive Lock.
        if not replayLoaded and appState.config.allowSeatTakeover:
          var board: seq[SeatSnapshot] = @[]
          for i in 0 ..< sim.players.len:
            board.add(SeatSnapshot(
              seat: sim.players[i].joinOrder,
              cog: i,
              alive: sim.players[i].alive,
              respawnTimer: sim.players[i].respawnTimer))
          appState.seatBoard = board
          migratePendingTakeovers(appState.seatBoard, appState.config.brMode)
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
          if squadMode:
            # Seats send NO inputs: every actuator mask comes from the
            # control layer below, indexed by COG. Sampling the socket here
            # would write a second, conflicting mask record per tick.
            appState.inputPressedMasks[websocket] = 0
            continue
          if firstLightEpisode.enabled and playerIndex >= 0 and
              playerIndex < sim.players.len:
            let slot = sim.players[playerIndex].joinOrder
            if slot >= 0 and slot < config.slots.len and
                config.slots[slot].control == scPlay:
              # A play socket supplies presence and receives its view; it can
              # never supply an actuator mask. FIRST LIGHT's lane-A seatTick
              # handoff below is the sole source for this configured seat.
              appState.inputMasks[websocket] = 0
              appState.inputPressedMasks[websocket] = 0
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
        if muxState.enabled and not replayLoaded and not squadMode:
          # Mux seat inputs, sampled with the same down/pressed edge
          # semantics as the websocket loop above.
          withLock muxState.lock:
            for slot in 0 ..< MaxMuxSeats:
              if not muxState.seats[slot].joined:
                continue
              let playerIndex = muxState.seats[slot].playerIndex
              if playerIndex < 0 or playerIndex >= inputs.len:
                continue
              if firstLightEpisode.enabled and
                  playerIndex < sim.players.len:
                let playerSlot = sim.players[playerIndex].joinOrder
                if playerSlot >= 0 and playerSlot < config.slots.len and
                    config.slots[playerSlot].control == scPlay:
                  continue
              let pressedMask = muxState.seats[slot].pressedMask
              muxState.seats[slot].pressedMask = 0
              let currentMask = muxState.seats[slot].inputMask
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
        if not replayLoaded:
          # Registrations that cannot be applied YET are HELD, not dropped.
          # Joins are strictly slot-sequential, so a seat whose slot is not the
          # next open one waits for the lower slots — and the lobby sends
          # frames to a socket before it has been admitted, so both the seat's
          # first registration and the one it re-sends after its first frame
          # can arrive while its player index is still 0x7fffffff. Clearing the
          # table then discarded them for good and the champion played the
          # scripted holdline baseline for the whole episode with no `register`
          # record at all (paintball round 3, 2026-08-25: "player connected:
          # daveey-1" first, then only "seat 0 registered" twice). Bounded by
          # construction: one entry per live socket, dropped with the socket.
          var heldRegistrations: seq[(WebSocket, string)] = @[]
          for websocket, chatText in appState.chatMessages.pairs:
            let playerIndex = appState.playerIndices.getOrDefault(
              websocket,
              -1
            )
            if squadMode:
              # A seat's chat is its REGISTRATION, consumed here and never
              # applied as a shout or written to the replay chat stream: the
              # prompt is a secret. What the replay gets is a redacted
              # `register` record — the policy label and kind only. Any other
              # chat text from a seat is dropped: cogs shout, seats do not.
              if playerIndex < 0 or playerIndex >= config.numAgents:
                if websocket.isPlayerWebSocket() and
                    parseRegistration(chatText).ok:
                  heldRegistrations.add((websocket, chatText))
                continue
              let registration = parseRegistration(chatText)
              if not registration.ok:
                continue
              var policy = engine.seats[playerIndex]
              let firstRegistration = not policy.registered
              policy.registered = true
              policy.prompt = registration.prompt.truncateRunes(MaxPromptRunes)
              policy.isLlm = policy.prompt.len > 0
              policy.baseline = parseBaseline(registration.scripted)
              policy.label =
                if registration.policy.len > 0: registration.policy
                elif policy.isLlm: "prompt"
                else: $policy.baseline
              engine.seats[playerIndex] = policy
              if playerIndex <= sim.seatPolicyKind.high:
                sim.seatPolicyKind[playerIndex] =
                  engine.policyKind(playerIndex)
              # One `register` record and one log line per seat. The seat
              # re-sends its registration for the first ~10 s of frames (see
              # src/paintball_player.nim), so recording every copy would put
              # ten identical records in the replay and ten identical lines in
              # the game log.
              if firstRegistration:
                replayWriter.writeChat(
                  tickTime(sim.tickCount),
                  playerIndex,
                  registerRecord(
                    playerIndex,
                    teamText(sim.teamForSlot(playerIndex)),
                    policy.label,
                    engine.policyKind(playerIndex),
                    $policy.baseline
                  )
                )
                echo "seat ", playerIndex, " registered: kind=",
                  engine.policyKind(playerIndex), " baseline=", $policy.baseline
              continue
            if sim.applyShout(playerIndex, chatText):
              replayWriter.writeChat(
                tickTime(sim.tickCount),
                playerIndex,
                chatText
              )
          appState.chatMessages.clear()
          # The one-page-policy REFLASH drain, written in the shout drain's
          # shape on purpose: apply at a tick boundary, and record EXACTLY
          # what the sim accepted, stamped with the tick it was accepted on.
          # `applyPolicyPage` is the single predicate both this path and
          # playback consult, so the file can never claim a flash the sim
          # refused, nor omit one it took.
          for websocket, page in appState.policyPageFlashes.pairs:
            let playerIndex = appState.playerIndices.getOrDefault(
              websocket,
              -1
            )
            if sim.applyPolicyPage(playerIndex, page):
              replayWriter.writePolicyPageFlash(
                tickTime(sim.tickCount),
                playerIndex,
                page
              )
          appState.policyPageFlashes.clear()
          for (websocket, chatText) in heldRegistrations:
            appState.chatMessages[websocket] = chatText
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
      firstLightEpisode.resetFirstLightForSim(replayLoaded, config, sim, "reset")
      # One file describes ONE match. A reset that kept the previous match's
      # events would concatenate two games under a single episode id.
      collectedEvents.setLen(0)
      # The live chrome tracker (stakes #7/#9) is a brand-new-match object too:
      # a fresh SimServer means a fresh roster (possibly a different player
      # count), and the OLD tracker's per-index kills/deaths/alive arrays are
      # sized for the match that just ended. The replay path never needs this
      # reset -- one replay file is one match, so its tracker's lifetime never
      # crosses a reset -- this is the live-only case that owns it.
      broadcastTracker = initBroadcastTracker()
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

    # ------------------------------------------------------------------
    #  PAINTBALL: the decision turn, then the control-compiled actuator
    #  masks. This is the determinism boundary — the control layer and the
    #  LLM live on THIS side of it, and only the masks below are recorded,
    #  so the wasm viewer re-derives the whole match from them without ever
    #  running either.
    # ------------------------------------------------------------------
    if squadMode and squadsBuilt and sim.phase == Playing:
      let
        elapsedSeconds = (getMonoTime() - episodeStart).inSeconds.int
        turnTicks = max(1, config.turnTicks)
        turnIndex = sim.gameTicksElapsed() div turnTicks
        turnKey = sim.gameIndex * 1_000_000 + turnIndex
      engine.ctl.observeEnemies(sim)
      if sim.gameTicksElapsed() mod turnTicks == 0 and turnKey != lastTurnKey:
        lastTurnKey = turnKey
        let turnsPerGame =
          if config.maxTicks > 0: max(1, config.maxTicks div turnTicks) else: 0
        let records = engine.turn(sim, turnIndex, turnsPerGame, elapsedSeconds)
        for record in records:
          replayWriter.writeChat(tickTime(sim.tickCount), 0, record)
        for seat in 0 ..< engine.directives.len:
          if not engine.haveDirective[seat]:
            continue
          let directive = engine.directives[seat]
          case directive.source
          of dsLlm: inc sim.llmTurns[min(seat, sim.llmTurns.high)]
          of dsFallback: inc sim.fallbackTurns[min(seat, sim.fallbackTurns.high)]
          of dsScripted: discard
          let record = directive.boundedDirectiveRecord(
            sim.gameIndex + 1, turnIndex, seat,
            teamText(sim.teamForSlot(seat)), regimeText(sim.regime))
          replayWriter.writeChat(tickTime(sim.tickCount), seat, record)
          sim.pushFeedDirective(record)
          sim.emitEvent(
            Directive, source = seat, weapon = $directive.source,
            amount = turnIndex, content = directive.note)
          # A cog's `say` is a REAL in-game shout: hashed state both sides
          # hear, so it is written to the replay chat stream by cog index and
          # re-applied identically at playback.
          for order in directive.orders:
            if order.say.len == 0:
              continue
            if sim.applyShout(order.cogIndex, order.say):
              replayWriter.writeChat(
                tickTime(sim.tickCount), order.cogIndex, order.say)
      # Compile one mask per COG, in index order, every tick.
      inputs = newSeq[InputState](sim.players.len)
      for cogIndex in 0 ..< sim.players.len:
        let seat = sim.cogSeat(cogIndex)
        var order: CogOrder
        var found = false
        if sim.seatCommands(seat, cogIndex) and seat < engine.directives.len and
            engine.haveDirective[seat]:
          for candidate in engine.directives[seat].orders:
            if candidate.cogIndex == cogIndex:
              order = candidate
              found = true
              break
        if not found:
          # Either this cog is a scripted teammate in a `visitor` game, or its
          # seat has no directive yet. Both play the published holdline
          # baseline, which is what "adapt to a partner you know the rules of"
          # means here.
          let scripted = engine.holdlineFor(sim, @[cogIndex])
          if scripted.orders.len > 0:
            order = scripted.orders[0]
            found = true
        if not found:
          continue
        let mask = engine.ctl.compileMask(sim, order, cogIndex)
        inputs[cogIndex] = decodeInputMask(mask)
        replayWriter.writeInputMaskChange(
          tickTime(sim.tickCount), cogIndex, mask)
      downInputs = inputs
    elif squadMode and squadsBuilt and sim.players.len > 0:
      # NOT playing (the lobby between the two games of an episode, or the
      # game-over hold): the server steps with all-zero inputs, so the replay
      # has to be told that. Without it, playback keeps re-applying the last
      # masks of the previous game and the first Playing tick of the next one
      # sees a different `prev` — which decides whether a fresh A press fires,
      # and diverges the hash chain at exactly that tick.
      for cogIndex in 0 ..< sim.players.len:
        replayWriter.writeInputMaskChange(tickTime(sim.tickCount), cogIndex, 0)

    var frameEvents = newJArray()
    # Drained once per frame below (same "drain, then setLen(0)" shape as
    # collectedEvents/sim.events just under this), and consumed ONLY by the
    # takeover send pass further down — the ordinary per-seat (policy) send
    # pass never reads it. Declared out here (not inside the `else:` step
    # loop) so it survives to that later pass; stays empty for a replay
    # frame, which is fine, since replay playback never has a takeover
    # socket to deliver it to (takeoverSockets is only ever populated on the
    # `not replayLoaded` path above).
    var frameShotFeedback: seq[ShotFeedbackFx] = @[]
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
        if firstLightEpisode.enabled:
          var frames: seq[FirstLightSeatFrame]
          for playerIndex, player in sim.players:
            let slot = player.joinOrder
            if slot < 0 or slot >= config.slots.len or
                config.slots[slot].control != scPlay:
              continue
            let bodyInputs = sim.firstLightBodyInputs(playerIndex)
            frames.add(FirstLightSeatFrame(
              seat: uint8(slot),
              playerIndex: playerIndex,
              present: true,
              playing: sim.phase == Playing,
              alive: player.alive,
              bodyInputs: bodyInputs,
              defaultFallbacks: sim.firstLightFallbacks(bodyInputs.self.pos)))
          let firstLight = firstLightEpisode.step(
            frames, uint32(sim.tickCount + 1))
          var firstLightMoving, firstLightAiming = 0
          for mask in firstLight.masks:
            let encoded = mask.input.encodeInputMask()
            if (encoded and (ButtonUp or ButtonDown or
                ButtonLeft or ButtonRight)) != 0:
              inc firstLightMoving
            if (encoded and (ButtonB or ButtonSelect)) != 0:
              inc firstLightAiming
            if mask.playerIndex < 0 or mask.playerIndex >= stepInputs.len:
              continue
            stepInputs[mask.playerIndex] = mask.input
            if mask.playerIndex < downInputs.len:
              downInputs[mask.playerIndex] = mask.input
            replayWriter.writeInputMaskChange(
              tickTime(sim.tickCount), mask.playerIndex,
              encoded)
          if firstLight.masks.len > 0 and (firstLightMoving > 0 or
              firstLightAiming > 0 or (sim.tickCount mod 24) == 0):
            echo "FIRST_LIGHT_MOVEMENT tick=", sim.tickCount + 1,
              " seats=", firstLight.masks.len,
              " moving=", firstLightMoving,
              " aiming=", firstLightAiming
          for install in firstLight.installs:
            echo install.formatInstall()
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
        # The paintball `fault` end conditions (design §End conditions rows 5
        # and 6), now live on this branch: squadMode and the EndRuleSimFault/
        # EndRuleHostError constants landed via this same main-merge (an
        # earlier revision of this file hand-skipped this wrap because
        # neither existed yet on the unmerged Paintball KOTH lineage — that
        # note is now stale). A tripped sim invariant or any other exception
        # out of the tick is NOT a silent non-zero exit there: the episode
        # ends here, both seats score 0.500 (roster.playerResultsJson's fault
        # branch), and the artifact block below still writes the partial
        # replay, the results and the events. A CLASSIC/BR game keeps its
        # historical behavior: an exception out of step() propagates and the
        # runner sees the crash, exactly as it did before this merge.
        var faultRule = ""
        try:
          sim.step(stepInputs, stepPrevInputs)
        except SimGuardError as guard:
          if not squadMode:
            raise
          echo "paintball: SIM GUARD tripped at tick ", sim.tickCount, ": ",
            guard.msg
          faultRule = EndRuleSimFault
        except CatchableError as error:
          if not squadMode:
            raise
          echo "paintball: HOST ERROR at tick ", sim.tickCount, ": ",
            error.msg
          faultRule = EndRuleHostError
        if faultRule.len > 0:
          sim.endReason = ReasonFault
          sim.endRule = faultRule
          sim.phase = GameOver
          quitAfterFrame = true
          break
        if firstLightEpisode.enabled:
          # Death is observed immediately after the sim step that caused it,
          # so clear-on-death carries that completed tick rather than waiting
          # for the next actuator pass. This hook performs no second default,
          # body call, or mask handoff.
          var lifecycleFrames: seq[FirstLightSeatFrame]
          for playerIndex, player in sim.players:
            let slot = player.joinOrder
            if slot < 0 or slot >= config.slots.len or
                config.slots[slot].control != scPlay:
              continue
            let selfState = sim.firstLightSelfState(playerIndex)
            lifecycleFrames.add(FirstLightSeatFrame(
              seat: uint8(slot),
              playerIndex: playerIndex,
              present: true,
              playing: false,
              alive: player.alive,
              bodyInputs: BodyTickInputs(self: selfState),
              defaultFallbacks: sim.firstLightFallbacks(selfState.pos)))
          for annotation in firstLightEpisode.observeDeaths(
              lifecycleFrames, uint32(sim.tickCount)):
            echo annotation.formatLifecycleAnnotation()
        if sim.collectEvents:
          # Drained every tick, like the extractor's walk: the sink is a plain
          # seq on the sim and would otherwise grow for the whole match.
          for event in sim.events:
            collectedEvents.add(event)
          sim.events.setLen(0)
        # Same drain shape as sim.events just above, for the private
        # shot-feedback channel (GameConfig.allowShotFeedback): empty on
        # every config that leaves the gate off, since applyFire/
        # resolveActiveArcCones/explodeGrenade only ever push to it when the
        # gate is on. Accumulated across every step this frame (playbackSpeed
        # can run several steps per frame), consumed once below by the
        # takeover send pass only.
        for fx in sim.shotFeedback:
          frameShotFeedback.add fx
        sim.shotFeedback.setLen(0)
        # Broadcast chrome's kill-feed/phase/gameover beats (stakes #7/#9):
        # the SAME diff-the-tracker-against-this-tick call the replay path
        # makes once per stepped tick via advanceReplayPlayback's callback,
        # so a >1x live speed still attributes every kill in the frame
        # instead of collapsing several ticks into one ambiguous marker.
        # Read-only against sim (see stepEvents/killerThisStep signatures) --
        # cannot touch gameHash, which is hashed just below on the same tick.
        sim.stepEvents(broadcastTracker, frameEvents)
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
          if squadMode:
            # Archive this half and arm the next one's regime BEFORE the
            # lobby reset that precedes the next startGame.
            sim.gameHill.add(sim.hillTicks)
            sim.gameRegimes.add(sim.regime)
            sim.gameIndex = gamesPlayed
            if config.regimes.len > 0:
              sim.regime = config.regimes[min(gamesPlayed, config.regimes.high)]
            squadsBuilt = false
            lastTurnKey = -1
            echo "game ", gamesPlayed, " done; hill red=",
              sim.gameHill[^1][Red], " blue=", sim.gameHill[^1][Blue],
              "; next regime ", regimeText(sim.regime)
        if config.maxGames > 0 and gamesPlayed >= config.maxGames:
          quitAfterFrame = true
          break
        if sim.needsReregister:
          break
      prevInputs = lastStepInputs

    let rewardPacket = sim.buildRewardPacket()

    if not replayLoaded and sim.needsReregister:
      sim.needsReregister = false
      firstLightEpisode.resetFirstLightForSim(
        replayLoaded, config, sim, "reregister")
      liveOverlays = @[]
      # A round transition WITHIN the same match (roster/tick count both
      # carry forward, unlike the full shouldReset above) -- resync rather
      # than reinit, the same "state jumped, don't diff across the jump"
      # move the replay path makes on its own seek/command jumps
      # (advanceReplayFrame's `if didSeek: tracker.resync(sim)`).
      broadcastTracker.resync(sim)
      {.gcsafe.}:
        withLock appState.lock:
          for websocket in appState.playerIndices.keys:
            if websocket.isPlayerWebSocket():
              appState.playerIndices[websocket] = UnresolvedPlayerIndex
          for websocket in appState.playerViewers.keys:
            # Bots/policies (spritesOff) keep the historical full wipe so
            # their observation stream stays byte-identical to before this
            # change. Human viewers get the soft reset: the map bands,
            # walkability mask, and HUD layers this socket already holds
            # survive the round transition (see
            # resetPlayerViewerStateForRound) instead of being re-sent from
            # scratch on every round — the cause of the multi-megabyte
            # per-round resend (and the mid-transfer socket teardowns it
            # produced) that this fix targets.
            if appState.spritesOff.getOrDefault(websocket, false):
              appState.playerViewers[websocket] = initPlayerViewerState()
            else:
              appState.playerViewers[websocket].resetPlayerViewerStateForRound()
          landSeatTakeoversOnNewMatch()
      if muxState.enabled:
        # Between-games roster reset (multi-trial episodes): mux seats rejoin
        # through the admission loop like websocket seats do.
        muxRequeueJoins()
        for slot in 0 ..< MaxMuxSeats:
          muxViewers[slot] = initPlayerViewerState()

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
      # Private combat-outcome channel (GameConfig.allowShotFeedback): a
      # SEPARATE TextMessage, never folded into the binary sprite/label wire
      # above, so it can never reach the seat's underlying policy socket —
      # only this takeover pass ever calls buildShotFeedbackPacket. Empty
      # frameShotFeedback (the gate is off, or nothing landed this tick) is
      # the overwhelmingly common case, so this filters and builds only when
      # there is anything to say at all.
      if frameShotFeedback.len > 0:
        var cogShotFeedback: seq[ShotFeedbackFx] = @[]
        for fx in frameShotFeedback:
          if fx.shooterIndex == takeoverCogs[i] or fx.targetIndex == takeoverCogs[i]:
            cogShotFeedback.add fx
        if cogShotFeedback.len > 0:
          let shotFeedbackPacket =
            sim.buildShotFeedbackPacket(cogShotFeedback, takeoverCogs[i])
          if shotFeedbackPacket.len > 0:
            try:
              takeoverSockets[i].send(shotFeedbackPacket, TextMessage)
            except:
              {.gcsafe.}:
                withLock appState.lock:
                  discard markSocketClosed(takeoverSockets[i])
      # Cosmetic-effects channel (GameConfig.allowCosmeticFx): same shape as
      # the shot-feedback block just above — a SEPARATE TextMessage that only
      # this takeover pass ever builds or sends, so it can never reach the
      # seat's underlying policy/mux socket regardless of the gate. Rebuilt
      # fresh from live sim state every tick (sim.recentShots/sim.paintStains
      # are already fog-clipped inside the builder), not drained from a
      # per-frame buffer like shot feedback — there is nothing to accumulate
      # across steps here.
      let cosmeticFxPacket = sim.buildCosmeticFxPacket(takeoverCogs[i])
      if cosmeticFxPacket.len > 0:
        try:
          takeoverSockets[i].send(cosmeticFxPacket, TextMessage)
        except:
          {.gcsafe.}:
            withLock appState.lock:
              discard markSocketClosed(takeoverSockets[i])

    if muxConnected():
      # Mux seat frames: the exact wire bytes the websocket path would send
      # (same builder, dedup, and chunking; one record per would-be message,
      # including the empty frame-count message), batched into one write.
      var muxSeatRows: seq[(int, int)] = @[]
      {.gcsafe.}:
        withLock muxState.lock:
          for slot in 0 ..< MaxMuxSeats:
            if muxState.seats[slot].joined:
              muxSeatRows.add((slot, muxState.seats[slot].playerIndex))
      var muxBatch = ""
      for (slot, muxPlayerIndex) in muxSeatRows:
        var nextState: PlayerViewerState
        let framePacket = sim.buildSpriteProtocolPlayerUpdates(
          muxPlayerIndex,
          muxViewers[slot],
          nextState,
          spritesOff = false
        )
        # Stored before dedup mutates nextState.sentPlacements — the same
        # ordering as the websocket loop above, so frames stay byte-identical.
        muxViewers[slot] = nextState
        let wirePacket = dedupObjectPlacements(
          framePacket,
          nextState.sentPlacements
        )
        serverMetrics.recordTraffic(muxPlayerIndex, wirePacket)
        if wirePacket.len == 0:
          muxAppendFrame(muxBatch, slot, [])
        for chunk in global.chunkSpritePacket(wirePacket, MaxWsFrameBytes):
          muxAppendFrame(muxBatch, slot, chunk)
      muxSend(muxBatch)

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
          sim.buildLiveViewerPacket(
            globalStates[i],
            nextState,
            liveOverlays,
            sim.tickCount,
            liveProgressMaxTick(config),
            playbackSpeed(liveSpeedIndex),
            replayPlayer.playing,
            replayPlayer.looping,
            frameEvents
          )
      if packet.len == 0:
        continue
      try:
        # The JSON chrome channel rides the SAME binary sprite channel as the
        # board — as the label of a reserved never-drawn 1×1 sprite
        # (BroadcastChromeSpriteId) — because that is the ONLY channel that
        # survives a hosted replay. The legacy opt-in `TextMessage` path never
        # routes the client→server `hud:on` through the recorded stream, so
        # hosted the HUD froze at its DOM defaults while the board played.
        # Piggybacking on the binary channel makes the chrome survive every
        # playback path (live serve, generic client, hosted replay), with no
        # opt-in. The generic bitworld client simply ignores an unknown sprite
        # id. (stakes #7/#9: this channel used to be built ONLY on the
        # `replayLoaded` branch above via buildReplayViewerPacket -- a live
        # match's global viewers got the bare board with no chrome sprite at
        # all, which is why /client/global rendering the rich broadcast HTML
        # was not by itself enough to show the teams-alive bar/end-card;
        # buildLiveViewerPacket now appends the same sprite from live sim
        # state instead of a ReplayPlayer.)
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
      if squadMode:
        # The `result` control record: the full results document, written once
        # into the replay chat stream at episode end (docs/PROTOCOL.md record
        # table), so a paintball replay is self-sufficient — the outcome would
        # otherwise live only at COGAME_RESULTS_URI, which a spectator with
        # the bytes cannot read. Never applied as a shout at playback (a
        # leading '{' marks a control record in squad mode), so the hash chain
        # is untouched. Classic replays never carry it.
        replayWriter.writeChat(tickTime(sim.tickCount), 0, resultRecord(sim))
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
      if squadMode:
        # Bounded shutdown grace: the certification runner pings /healthz and
        # /global AFTER the player pods start, and a short squad episode can
        # already have written its artifacts by then. Keep answering for a
        # bounded window, then exit — the runner waits on process exit anyway.
        # Classic games exit immediately, as they always have.
        let graceUntil =
          getMonoTime() + initDuration(seconds = ShutdownGraceSeconds)
        while getMonoTime() < graceUntil:
          sleep(200)
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
