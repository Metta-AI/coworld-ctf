## The one-page policy runner for paintbot BATTLE ROYALE.
##
## Architecture (Maxwell's ruling): an LLM produces a STRATEGY — a one-page
## JSON scoring sheet — which selects an INTENT from a fixed menu, which
## RESOLVES to an ACTION (moveMask, desiredAim, wantFire: the same three
## values `players/baseline/baseline.nim`'s tactics tree computes at
## baseline.nim:3055-3310) which a common tail turns into the 8-bit input
## mask and edge-fires ButtonA, EXACTLY like baseline's tail
## (baseline.nim:3296-3309) — see `actToMask` below, a byte-for-byte port.
##
## REUSE BOUNDARY (why this file exists instead of editing baseline.nim):
## baseline.nim's tactics tree (roughly lines 1547-3310) is a fixed if/elif
## CTF playbook (flag roles, rushing, pocket-rush) that does not describe BR
## (16 duos, one life, a shrink zone, no flag). That tree is REPLACED here by
## the intent menu + resolvers. Everything BELOW the tactics tree — the wire
## decode (`baseline/protocols`), the label vocabulary (`ctf/labels`), the
## steering primitives (octantBits/bradsOf/bradsErr/navSteer) — is generic
## and is reused. `protocols.nim` is imported directly (see config.nims);
## the small pure-math/nav primitives (octantBits, bradsOf, bradsErr,
## bradsDir, the nav-grid cost field, navSteer, findDuckCell, updateTracks,
## trackPickups) are copied verbatim (byte-identical bodies, cited by
## baseline.nim line number at each site) because Nim has no exported
## symbols to import them by — baseline.nim marks nothing `*` and must not
## be edited for this (other agents are actively changing it on this same
## branch). If baseline.nim ever exports these, replace the copies with
## imports; nothing here changes the algorithms.
##
## VM SEAM (read before touching `onepage/policy_stub.nim`): another agent
## ("build-vm") owns `src/ctf/policy_page.nim` — the real scoring VM — on a
## different branch; it does not exist on this branch yet. `onepage/
## policy_stub.nim` is a PLACEHOLDER implementing the interface build-vm
## described (PathKind, a string-keyed path registry, IntentContext with
## opaque resolveNumber/resolveBool closures, a compile+argmax pair) so the
## swap is close to a rename once the real module lands. See that file's
## header for the exact assumed shape and `DefaultPaths` — the perception-
## true path list reported back to build-vm.
##
## REFLASH (mid-episode strategy swap): see the "REFLASH" section near the
## bottom for the swap-boundary state machine and the assumed wire contract
## for the propose/ratify round trip. That server-side ratification does
## not exist yet (a different lane's work); this file implements the bot-
## side propose-send, receive-scan, and the deterministic apply-at-tick
## logic against the documented, assumed contract.

import
  std/[algorithm, heapqueue, math, net, os, random, strutils],
  bitworld/spriteprotocol,
  ctf/labels,
  whisky,
  protocols,
  onepage/policy_stub

# -----------------------------------------------------------------------------
# Consts
# -----------------------------------------------------------------------------

const
  WebSocketPath = "/player"
  PlayerHalf = 6              # solid footprint half-extent (baseline.nim:96)
  NavCell = 8                 # nav grid cell size in px (baseline.nim:97)
  RepathTicks = 10            # refresh the cost field at least this often
  LookaheadCells = 6          # waypoint lookahead distance, in nav cells

  AimBrads = 256               # aim angle units per full turn (baseline.nim:128)
  AimRate = 5                  # brads/tick a held rotate button turns the aim
  MaxHp = 3                    # hitPoints per life (config default)
  CombatDeadband = 2           # stop the traverse within this error (brads)
  FireSlackPx = 11.0           # fire when the aim error's perpendicular miss
                                # at the target's range is inside this corridor
                                # (baseline.nim:3108-3120, same gate, reused)

  StepCost = 5'i32             # orthogonal move cost in the nav cost field
  DiagCost = 7'i32              # ~sqrt(2) * StepCost

  TrackMatchDist = 40.0        # a sighting matches a track within this distance
  TrackTtl = 120                # forget a player not seen for ~5s
  EnemyTrackCap = 30            # up to 31 other seats in a 32-seat BR match
  PickupSeenClear = 55.0        # inside this range an empty spot is truly
                                 # empty (bubble vision), not just fogged
  PickupRespawn = 30 * 24       # a taken pickup refills after ~30s (sim const)

  DuckSearchCells = 3           # duck-cell search radius in nav cells
  ThreatRange = 200.0           # "in combat" radius used for partner.in_combat
  ArriveRadius = 12.0           # close enough to a nav target to hold position
  PeelRange = 200.0        # how far a peel tries to put between us and
                                 # the nearest threat
  AvoidStepOut = 300.0          # how far AvoidFight steps away from the
                                 # enemy centroid per tick, before zone-clamping
  ThirdPartyFightRange = 180.0  # two ENEMY tracks of different colors this
                                 # close together read as a fight already
                                 # under way between two OTHER duos

  ButtonC = 1'u8 shl 7          # grenade charge/throw (baseline.nim:148)
  NadeMaxRange = 240.0          # full-charge throw distance (baseline.nim:149)
  NadeMinRange = 78.0           # never lob inside this (baseline.nim:150)
  NadeFullChargeTicks = 24      # ~1s of holding C reaches max range
                                 # (baseline.nim:157)

var
  MapW = 1235                   # adopted from the walkability sprite's size
  MapH = 659
  GridW = (MapW + NavCell - 1) div NavCell
  GridH = (MapH + NavCell - 1) div NavCell
  RealTeamCount = 2             # from the `game teams <n> map <w>x<h>` marker

const TeamColorNames = ["red", "blue", "green", "yellow"]

const BrRosterColorNames = [
  "red", "blue", "green", "yellow", "black", "silver", "ivory", "pink",
  "umber", "rust", "orange", "plum", "lime", "navy", "azure", "peach",
]
  ## Wire color tokens in engine seat-deal order (baseline.nim:334-337): a
  ## BR match's 16 duos span this whole list, not just the 4-color
  ## classic-ladder slice.

proc rosterColorCount(): int =
  ## baseline.nim:345-350, verbatim logic: how many colors are actually in
  ## play.
  if RealTeamCount > TeamColorNames.len: RealTeamCount else: max(2, RealTeamCount)

proc rosterColor(i: int): string =
  ## baseline.nim:352-357, verbatim logic.
  if RealTeamCount > TeamColorNames.len: BrRosterColorNames[i] else: TeamColorNames[i]

# -----------------------------------------------------------------------------
# Types
# -----------------------------------------------------------------------------

type
  Vec = object                 # a map-space point or direction
    x, y: float

  Actor = object                # a player visible this frame
    pos: Vec
    facingRight: bool
    hp: int
    color: string                 # wire color this Actor was scanned under

  Track = object                 # a remembered player
    pos, vel: Vec
    lastSeen: int
    facingRight: bool
    hp: int
    color: string                 # carried over from the Actor that fed it

  Intent* = enum
    ## The fixed BR intent menu. Each has exactly one short resolver below
    ## (see "Resolvers"); if a resolver starts growing, the intent is too
    ## vague and should split instead.
    RotateToRing
    HoldRingSafe
    Engage
    Finish
    Peel
    Heal
    Loot
    RegroupPartner
    SupportPartner
    AvoidFight
    ThirdParty
    UseGrenade

  Act = object
    ## The exact three-value handoff baseline.nim's tactics tree produces
    ## (baseline.nim:3057-3061): moveMask (d-pad), desiredAim (-1 = hold the
    ## current aim), wantFire. `holdC` is the one addition (UseGrenade's
    ## charge-hold) — everything else still just sets the first three.
    moveMask: uint8
    desiredAim: int
    wantFire: bool
    holdC: bool

  OnepageBot = ref object
    slot: int
    myColor: string
    colorLocked: bool
    tick: int
    gameStart: int
    estAim: int
    rotSign: int
    firedLast: bool
    hp: int
    navBuilt: bool
    cellWalkable: seq[bool]
    navDist: seq[int32]
    navGoal: int
    navStamp: int
    enemies: seq[Track]
    mates: seq[Track]           # BR duo: at most one real entry (our partner)
    medkitPos: seq[Vec]
    medkitAbsentAt: seq[int]
    itemPos: seq[Vec]            # shield / spray can / grenade / barrier
    itemAbsentAt: seq[int]
    zoneKnown: bool
    zoneX0, zoneY0, zoneX1, zoneY1: float
    zoneNextKnown: bool
    zoneNextX0, zoneNextY0, zoneNextX1, zoneNextY1: float
    lastIntent: Intent
    startupPage: PolicyPage       # the page loaded at process start
    activePage: PolicyPage        # latched at the flash edge / a reflash swap
    pendingPage: PolicyPage       # a page received mid-episode, not yet live
    pageHasPending: bool
    pageSwapAtTick: int           # -1 = no swap scheduled
    proposedPageRaw: string        # the raw JSON of our last reflash proposal
    proposedPageHash: string
    lastAppliedReflashHash: string
    pendingProposal: string         # a candidate raw page waiting to be sent
                                    # over the wire (see pollForNewPage)
    carryingNade: bool              # our OWN grenade-carry marker, within
                                    # 30px of us (baseline.nim:2769-2774)
    nadeCharge: int                 # ticks ButtonC has been held; 0 = idle
    nadeNeed: int                   # charge ticks the current lob needs
    lastFireTick: int               # tick of our last FRESH ButtonA press —
                                    # drives the local fire-windup estimate a
                                    # reflash must not swap out from under
                                    # (see maybeApplyReflash)

# -----------------------------------------------------------------------------
# Vector math (baseline.nim:541-563, verbatim)
# -----------------------------------------------------------------------------

proc vec(x, y: float): Vec = Vec(x: x, y: y)
proc `+`(a, b: Vec): Vec = vec(a.x + b.x, a.y + b.y)
proc `-`(a, b: Vec): Vec = vec(a.x - b.x, a.y - b.y)
proc `*`(a: Vec, s: float): Vec = vec(a.x * s, a.y * s)
proc len(a: Vec): float = hypot(a.x, a.y)
proc dist(a, b: Vec): float = len(a - b)
proc norm(a: Vec): Vec =
  let l = a.len()
  if l < 1e-6: vec(0, 0) else: a * (1.0 / l)

# -----------------------------------------------------------------------------
# Steering primitives — copied verbatim from players/baseline/baseline.nim,
# cited by line number. Do NOT reimplement the math if this ever drifts;
# diff against the cited lines instead.
# -----------------------------------------------------------------------------

proc octantBits(d: Vec): uint8 =
  ## baseline.nim:564-578, verbatim.
  if d.len() < 1e-6:
    return 0
  let octant = (int(round(arctan2(d.y, d.x) / (PI / 4))) + 8) mod 8
  case octant
  of 0: ButtonRight
  of 1: ButtonRight or ButtonDown
  of 2: ButtonDown
  of 3: ButtonDown or ButtonLeft
  of 4: ButtonLeft
  of 5: ButtonLeft or ButtonUp
  of 6: ButtonUp
  else: ButtonUp or ButtonRight

proc bradsOf(d: Vec): int =
  ## baseline.nim:580-586, verbatim.
  if d.len() < 1e-6:
    return 0
  (int(round(arctan2(-d.y, d.x) * float(AimBrads div 2) / PI)) +
    AimBrads) mod AimBrads

proc bradsErr(desired, current: int): int =
  ## baseline.nim:593-597, verbatim.
  (desired - current + AimBrads + AimBrads div 2) mod AimBrads - AimBrads div 2

proc slotFromUrl(url: string): int =
  ## baseline.nim:607-618, verbatim.
  let key = "slot="
  let at = url.find(key)
  if at < 0:
    return 0
  var i = at + key.len
  var digits = ""
  while i < url.len and url[i] in {'0' .. '9'}:
    digits.add(url[i])
    inc i
  if digits.len == 0: 0 else: digits.parseInt()

proc mapPos(client: ProtocolClient, o: SpriteObjectInfo): Vec =
  ## baseline.nim:620-629, verbatim.
  vec(
    float(o.x + o.width div 2 + client.mapCameraX),
    float(o.y + o.height div 2 + client.mapCameraY)
  )

proc ownAimBrads(client: ProtocolClient): int =
  ## baseline.nim:631-641, verbatim.
  for o in client.spriteObjects():
    if o.label.startsWith(LabelPrefixOwnAim):
      let tail = o.label[LabelPrefixOwnAim.len .. ^1]
      try:
        return parseInt(tail)
      except ValueError:
        return -1
  -1

proc findSelf(client: ProtocolClient, color: string): tuple[alive: bool, pos: Vec] =
  ## baseline.nim:643-650, verbatim.
  for facingRight in [true, false]:
    let label = labelSelf(color, if facingRight: LabelSideRight else: LabelSideLeft)
    for o in client.spriteObjectsWithLabel(label):
      return (alive: true, pos: client.mapPos(o))

const HpPipRadius = 22.0

proc actorsFor(client: ProtocolClient, color: string): seq[Actor] =
  ## baseline.nim:652-685, verbatim (own avatar excluded automatically: it
  ## renders under the DISTINCT "self " prefix, never "player ").
  for facingRight in [true, false]:
    let label = labelPlayer(color, if facingRight: LabelSideRight else: LabelSideLeft)
    for o in client.spriteObjectsWithLabel(label):
      result.add(Actor(pos: client.mapPos(o), facingRight: facingRight, color: color))
  for (o, label) in client.spriteObjectsWithLabelPrefix(LabelPrefixHp):
    let tail = label[LabelPrefixHp.len .. ^1]
    let slash = tail.find('/')
    if slash <= 0:
      continue
    var hp = 0
    try:
      hp = parseInt(tail[0 ..< slash])
    except ValueError:
      continue
    let p = client.mapPos(o)
    var best = -1
    var bestD = HpPipRadius
    for i in 0 ..< result.len:
      let d = dist(result[i].pos, p)
      if d < bestD:
        bestD = d
        best = i
    if best >= 0:
      result[best].hp = hp

proc walkableAt(client: ProtocolClient, x, y: int): bool =
  ## baseline.nim:687-691, verbatim.
  if x < 0 or y < 0 or x >= client.walkabilityWidth or y >= client.walkabilityHeight:
    return false
  client.walkabilityMask[y * client.walkabilityWidth + x]

proc footprintFits(client: ProtocolClient, x, y: int): bool =
  ## baseline.nim:693-700, verbatim.
  for dy in -PlayerHalf .. PlayerHalf:
    for dx in -PlayerHalf .. PlayerHalf:
      if not client.walkableAt(x + dx, y + dy):
        return false
  true

proc cellOf(p: Vec): int =
  ## baseline.nim:702-706, verbatim.
  let
    cx = clamp(int(p.x) div NavCell, 0, GridW - 1)
    cy = clamp(int(p.y) div NavCell, 0, GridH - 1)
  cy * GridW + cx

proc cellCenter(cell: int): Vec =
  ## baseline.nim:708-712, verbatim.
  vec(
    float((cell mod GridW) * NavCell + NavCell div 2),
    float((cell div GridW) * NavCell + NavCell div 2)
  )

proc pixelRayClear(client: ProtocolClient, a, b: Vec): bool =
  ## baseline.nim:714-729, verbatim.
  let
    ax = int(a.x)
    ay = int(a.y)
    bx = int(b.x)
    by = int(b.y)
    steps = max(abs(bx - ax), abs(by - ay))
  if steps == 0:
    return true
  for s in 1 .. steps:
    if not client.walkableAt(ax + (bx - ax) * s div steps, ay + (by - ay) * s div steps):
      return false
  true

const NavNeighbors = [
  (1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)
]

proc nearestOpenCell(bot: OnepageBot, cell: int): int =
  ## baseline.nim:808-822-ish, verbatim ring-search logic.
  if bot.cellWalkable[cell]:
    return cell
  let
    cx0 = cell mod GridW
    cy0 = cell div GridW
  for r in 1 .. max(GridW, GridH):
    for dy in -r .. r:
      for dx in -r .. r:
        if max(abs(dx), abs(dy)) != r:
          continue
        let
          nx = cx0 + dx
          ny = cy0 + dy
        if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
          continue
        let nc = ny * GridW + nx
        if bot.cellWalkable[nc]:
          return nc
  cell

proc computeField(bot: OnepageBot, client: ProtocolClient, goal: int) =
  ## baseline.nim:1155-1194, verbatim MINUS the threat-exposure cost term
  ## (rebuildExposure/bot.exposure): this bot has no threat-exposure model
  ## yet, so every step costs the plain StepCost/DiagCost. The algorithm
  ## (Dijkstra, no corner-cutting) is unchanged.
  for i in 0 ..< bot.navDist.len:
    bot.navDist[i] = -1
  var heap = initHeapQueue[(int32, int32)]()
  bot.navDist[goal] = 0
  heap.push((0'i32, int32(goal)))
  while heap.len > 0:
    let
      (dcur, cur32) = heap.pop()
      cur = int(cur32)
    if dcur > bot.navDist[cur]:
      continue
    let
      cx = cur mod GridW
      cy = cur div GridW
    for (dx, dy) in NavNeighbors:
      let
        nx = cx + dx
        ny = cy + dy
      if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
        continue
      let nc = ny * GridW + nx
      if not bot.cellWalkable[nc]:
        continue
      if dx != 0 and dy != 0 and
          not (bot.cellWalkable[cy * GridW + nx] and bot.cellWalkable[ny * GridW + cx]):
        continue
      let step = (if dx != 0 and dy != 0: DiagCost else: StepCost)
      let nd = bot.navDist[cur] + step
      if bot.navDist[nc] < 0 or nd < bot.navDist[nc]:
        bot.navDist[nc] = nd
        heap.push((nd, int32(nc)))

proc gridRayClear(bot: OnepageBot, a, b: Vec): bool =
  ## baseline.nim:1196-1205, verbatim.
  let
    d = b - a
    steps = int(d.len() / 4.0) + 1
  for s in 0 .. steps:
    let p = a + d * (float(s) / float(steps))
    if not bot.cellWalkable[cellOf(p)]:
      return false
  true

proc navSteer(bot: OnepageBot, client: ProtocolClient, me, target: Vec): Vec =
  ## baseline.nim:1207-1258, verbatim: direction along the cost-field path
  ## toward `target`, with waypoint lookahead. Falls back to a beeline
  ## before the grid exists or when unreachable.
  if not bot.navBuilt:
    return target - me
  let goal = bot.nearestOpenCell(cellOf(target))
  if goal != bot.navGoal or bot.tick - bot.navStamp >= RepathTicks:
    bot.computeField(client, goal)
    bot.navGoal = goal
    bot.navStamp = bot.tick
  let start = bot.nearestOpenCell(cellOf(me))
  if bot.navDist[start] < 0:
    return target - me
  if bot.navDist[start] == 0:
    return target - me
  var
    node = start
    waypoint = cellCenter(start)
    haveClear = false
  for _ in 0 ..< LookaheadCells:
    var next = -1
    var bestD = bot.navDist[node]
    let
      cx = node mod GridW
      cy = node div GridW
    for (dx, dy) in NavNeighbors:
      let
        nx = cx + dx
        ny = cy + dy
      if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
        continue
      let nc = ny * GridW + nx
      if bot.navDist[nc] < 0 or bot.navDist[nc] >= bestD:
        continue
      if dx != 0 and dy != 0 and
          not (bot.cellWalkable[cy * GridW + nx] and bot.cellWalkable[ny * GridW + cx]):
        continue
      bestD = bot.navDist[nc]
      next = nc
    if next < 0:
      break
    node = next
    if bot.gridRayClear(me, cellCenter(node)):
      waypoint = cellCenter(node)
      haveClear = true
    else:
      break
  if not haveClear:
    waypoint = cellCenter(node)
  waypoint - me

proc findDuckCell(bot: OnepageBot, client: ProtocolClient, me, threat: Vec): int =
  ## baseline.nim:1260-1287, verbatim: nearest directly-reachable cell around
  ## us whose center the threat cannot see; -1 when nothing nearby breaks
  ## the line.
  result = -1
  let
    c0 = cellOf(me)
    cx0 = c0 mod GridW
    cy0 = c0 div GridW
  var bestD = 1e18
  for dy in -DuckSearchCells .. DuckSearchCells:
    for dx in -DuckSearchCells .. DuckSearchCells:
      let
        nx = cx0 + dx
        ny = cy0 + dy
      if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
        continue
      let nc = ny * GridW + nx
      if not bot.cellWalkable[nc]:
        continue
      let p = cellCenter(nc)
      if not bot.gridRayClear(me, p):
        continue
      if client.pixelRayClear(p, threat):
        continue
      let d = dist(p, me)
      if d < bestD:
        bestD = d
        result = nc

proc updateTracks(bot: OnepageBot, tracks: var seq[Track], seen: seq[Actor], cap: int) =
  ## baseline.nim:1318-1368, verbatim (TrackCap parameterized: BR needs up
  ## to 31 tracked opponents, not CTF's fixed 8).
  var claimed = newSeq[bool](tracks.len)
  for a in seen:
    var
      best = -1
      bestD = TrackMatchDist
    for i in 0 ..< tracks.len:
      if claimed[i]:
        continue
      let d = dist(tracks[i].pos, a.pos)
      if d < bestD:
        bestD = d
        best = i
    if best >= 0:
      let
        dt = float(max(1, bot.tick - tracks[best].lastSeen))
        v = (a.pos - tracks[best].pos) * (1.0 / dt)
      tracks[best].vel = vec(
        clamp((tracks[best].vel.x + v.x) * 0.5, -3.0, 3.0),
        clamp((tracks[best].vel.y + v.y) * 0.5, -3.0, 3.0)
      )
      tracks[best].pos = a.pos
      tracks[best].facingRight = a.facingRight
      tracks[best].lastSeen = bot.tick
      tracks[best].color = a.color
      if a.hp > 0:
        tracks[best].hp = a.hp
      claimed[best] = true
    else:
      tracks.add(Track(pos: a.pos, lastSeen: bot.tick, facingRight: a.facingRight,
        hp: a.hp, color: a.color))
      claimed.add(true)
  var kept: seq[Track]
  for t in tracks:
    if bot.tick - t.lastSeen <= TrackTtl:
      kept.add(t)
  kept.sort(proc(a, b: Track): int = cmp(b.lastSeen, a.lastSeen))
  if kept.len > cap:
    kept.setLen(cap)
  tracks = kept

proc trackPickups(positions: var seq[Vec], absentAt: var seq[int], seen: seq[Vec], me: Vec, tick: int) =
  ## baseline.nim:1370-1396, verbatim.
  for p in seen:
    var known = false
    for i in 0 ..< positions.len:
      if dist(positions[i], p) < 24.0:
        known = true
        absentAt[i] = -1
    if not known:
      positions.add(p)
      absentAt.add(-1)
  for i in 0 ..< positions.len:
    if dist(positions[i], me) <= PickupSeenClear and absentAt[i] < 0:
      var present = false
      for p in seen:
        if dist(positions[i], p) < 24.0:
          present = true
      if not present:
        absentAt[i] = tick

proc pickupAvailable(absentAt: seq[int], i, tick: int): bool =
  ## baseline.nim:1398-1399, verbatim.
  absentAt[i] < 0 or tick - absentAt[i] > PickupRespawn + 48

proc nearestAvailable(pos: seq[Vec], absentAt: seq[int], tick: int, me: Vec): int =
  result = -1
  var bestD = 1e18
  for i in 0 ..< pos.len:
    if not pickupAvailable(absentAt, i, tick):
      continue
    let d = dist(pos[i], me)
    if d < bestD:
      bestD = d
      result = i

# -----------------------------------------------------------------------------
# Perception: adopt map size / game params, read own hp/aim, track enemies,
# our partner, medkits, generic items, and the shrink zone.
# -----------------------------------------------------------------------------

proc adoptMapSize(client: ProtocolClient) =
  MapW = client.walkabilityWidth
  MapH = client.walkabilityHeight
  GridW = (MapW + NavCell - 1) div NavCell
  GridH = (MapH + NavCell - 1) div NavCell

proc adoptGameParams(client: ProtocolClient) =
  ## baseline.nim:938-954, trimmed to the un-clamped BR count (RealTeamCount)
  ## this bot actually needs — no GameTeams 2-4 clamp, BR runs up to 16.
  for o in client.spriteObjects():
    if o.label.startsWith(LabelPrefixGameParams):
      let parts = o.label[LabelPrefixGameParams.len .. ^1].split(' ')
      if parts.len == 3:
        try:
          RealTeamCount = clamp(parseInt(parts[0]), 2, BrRosterColorNames.len)
        except ValueError:
          discard
      break

proc buildNavGrid(bot: OnepageBot, client: ProtocolClient) =
  ## baseline.nim:1055-1118, trimmed: no cover model / overwatch posts /
  ## defender choke (those are CTF-role concepts this bot has no roles for).
  adoptMapSize(client)
  adoptGameParams(client)
  if not bot.colorLocked:
    bot.myColor = rosterColor(bot.slot mod rosterColorCount())
  bot.cellWalkable = newSeq[bool](GridW * GridH)
  for cy in 0 ..< GridH:
    for cx in 0 ..< GridW:
      bot.cellWalkable[cy * GridW + cx] = client.footprintFits(
        cx * NavCell + NavCell div 2, cy * NavCell + NavCell div 2)
  bot.navDist = newSeq[int32](GridW * GridH)
  bot.navGoal = -1
  bot.navBuilt = true

proc updateZone(bot: OnepageBot, client: ProtocolClient) =
  ## Reads `zone <x0>,<y0> <x1>,<y1>` / `zonenext ...` (labels.nim:238-259).
  ## Absent entirely when zonePhases is empty — zoneKnown stays false, and
  ## every zone-aware resolver degrades to "hold position" rather than
  ## steering toward a rect that does not exist.
  for (o, label) in client.spriteObjectsWithLabelPrefix(LabelPrefixZone):
    if label.startsWith(LabelPrefixZoneNext):
      continue
    let parts = label[LabelPrefixZone.len .. ^1].split(' ')
    if parts.len != 2:
      continue
    let lo = parts[0].split(',')
    let hi = parts[1].split(',')
    if lo.len != 2 or hi.len != 2:
      continue
    try:
      bot.zoneX0 = parseFloat(lo[0]); bot.zoneY0 = parseFloat(lo[1])
      bot.zoneX1 = parseFloat(hi[0]); bot.zoneY1 = parseFloat(hi[1])
      bot.zoneKnown = true
    except ValueError:
      discard
  for (o, label) in client.spriteObjectsWithLabelPrefix(LabelPrefixZoneNext):
    let parts = label[LabelPrefixZoneNext.len .. ^1].split(' ')
    if parts.len != 2:
      continue
    let lo = parts[0].split(',')
    let hi = parts[1].split(',')
    if lo.len != 2 or hi.len != 2:
      continue
    try:
      bot.zoneNextX0 = parseFloat(lo[0]); bot.zoneNextY0 = parseFloat(lo[1])
      bot.zoneNextX1 = parseFloat(hi[0]); bot.zoneNextY1 = parseFloat(hi[1])
      bot.zoneNextKnown = true
    except ValueError:
      discard

proc updatePerception(bot: OnepageBot, client: ProtocolClient, me: Vec) =
  # Own hp: "lives <hp>hp x<lives>" (baseline.nim:1897-1908, verbatim parse).
  for o in client.spriteObjects():
    if o.label.startsWith(LabelPrefixLives):
      let text = o.label[LabelPrefixLives.len .. ^1]
      let cut = text.find("hp")
      if cut > 0:
        try:
          bot.hp = clamp(parseInt(text[0 ..< cut]), 1, 9)
        except ValueError:
          discard
      break
  # Own aim: resync from the stated HUD marker (baseline.nim:1603-1605).
  let statedAim = client.ownAimBrads()
  if statedAim >= 0:
    bot.estAim = statedAim
  # Own grenade carry: the carried-marker is generic (any visible carrier),
  # but it floats within 30px of its carrier, and nobody else stands that
  # close to our own center on the frame we read it (baseline.nim:2769-2774,
  # verbatim distance check).
  bot.carryingNade = false
  for o in client.spriteObjectsWithLabel(LabelGrenadeCarried):
    if dist(client.mapPos(o), me) <= 30.0:
      bot.carryingNade = true
      break
  # Enemies: every OTHER color in the FULL BR roster (rosterColorCount(),
  # not a 4-color clamp) — the exact gap baseline.nim:301-312 documents on
  # the ladder's own bot, closed here from the start.
  var seenEnemies: seq[Actor]
  for i in 0 ..< rosterColorCount():
    let c = rosterColor(i)
    if c == bot.myColor:
      continue
    seenEnemies.add(client.actorsFor(c))
  bot.updateTracks(bot.enemies, seenEnemies, EnemyTrackCap)
  # Partner: same color as us, minus our own avatar (which renders under the
  # distinct "self " prefix, never "player ") — in a BR duo this is exactly
  # our one partner when visible.
  let seenMates = client.actorsFor(bot.myColor)
  bot.updateTracks(bot.mates, seenMates, 1)
  # Pickups: medkits are their own label; every other pickup type (shield,
  # spray can, grenade, barrier) folds into one generic "item" bucket — the
  # intent menu only distinguishes "heal" from "everything else you'd want".
  var seenKits: seq[Vec]
  for o in client.spriteObjectsWithLabel(LabelMedKit):
    seenKits.add(client.mapPos(o))
  trackPickups(bot.medkitPos, bot.medkitAbsentAt, seenKits, me, bot.tick)
  var seenItems: seq[Vec]
  for lbl in [LabelShield, LabelSprayCan, LabelGrenade, LabelBarrier]:
    for o in client.spriteObjectsWithLabel(lbl):
      seenItems.add(client.mapPos(o))
  trackPickups(bot.itemPos, bot.itemAbsentAt, seenItems, me, bot.tick)
  bot.updateZone(client)

# -----------------------------------------------------------------------------
# Resolvers: each takes the world as it stands and returns exactly
# (moveMask, desiredAim, wantFire). Kept short on purpose — see the Intent
# doc comment.
# -----------------------------------------------------------------------------

proc actMove(bot: OnepageBot, client: ProtocolClient, me, target: Vec): Act =
  ## Shared "walk toward a point, face the way you're walking" motion used
  ## by every non-combat intent.
  if dist(me, target) < ArriveRadius:
    return Act(moveMask: 0, desiredAim: -1, wantFire: false)
  let dir = navSteer(bot, client, me, target)
  Act(
    moveMask: octantBits(dir),
    desiredAim: (if dir.len() > 1e-6: bradsOf(dir) else: -1),
    wantFire: false)

proc fireGate(bot: OnepageBot, targetPos, me: Vec): tuple[aim: int, fire: bool] =
  ## The SAME gate baseline.nim's fire branch uses (baseline.nim:3108-3120):
  ## traverse onto the target, fire once the bullet corridor at its range
  ## covers it.
  let desiredAim = bradsOf(targetPos - me)
  let err = abs(bradsErr(desiredAim, bot.estAim))
  let engageD = dist(targetPos, me)
  let perpMiss = engageD * sin(float(err) * PI / float(AimBrads div 2))
  (aim: desiredAim, fire: perpMiss <= FireSlackPx)

proc nearestEnemyIdx(bot: OnepageBot, me: Vec): int =
  result = -1
  var bestD = 1e18
  for i in 0 ..< bot.enemies.len:
    let d = dist(bot.enemies[i].pos, me)
    if d < bestD:
      bestD = d
      result = i

proc weakestEnemyIdx(bot: OnepageBot, me: Vec): int =
  ## Lowest known hp (never-observed tracks, hp == 0, are skipped — we
  ## cannot claim to know who is weakest among them); nearest breaks ties.
  ## Falls back to nearest-of-any when no enemy's hp has ever been read.
  result = -1
  var bestHp = high(int)
  var bestD = 1e18
  for i in 0 ..< bot.enemies.len:
    if bot.enemies[i].hp <= 0:
      continue
    let d = dist(bot.enemies[i].pos, me)
    if bot.enemies[i].hp < bestHp or (bot.enemies[i].hp == bestHp and d < bestD):
      bestHp = bot.enemies[i].hp
      bestD = d
      result = i
  if result < 0:
    result = nearestEnemyIdx(bot, me)

proc resolveEngageIdx(bot: OnepageBot, client: ProtocolClient, me: Vec, idx: int): Act =
  if idx < 0:
    return Act(moveMask: 0, desiredAim: -1, wantFire: false)
  let targetPos = bot.enemies[idx].pos
  let (aim, fire) = bot.fireGate(targetPos, me)
  let dir = navSteer(bot, client, me, targetPos)
  Act(moveMask: octantBits(dir), desiredAim: aim, wantFire: fire)

proc resolveRotateToRing(bot: OnepageBot, client: ProtocolClient, me: Vec): Act =
  ## Walk to the CURRENT zone's center; once inside, pre-rotate toward where
  ## the NEXT zone is heading so a late shrink never catches us mid-turn.
  if not bot.zoneKnown:
    return Act(moveMask: 0, desiredAim: -1, wantFire: false)
  let inside = me.x >= bot.zoneX0 and me.x <= bot.zoneX1 and
               me.y >= bot.zoneY0 and me.y <= bot.zoneY1
  if not inside:
    let center = vec((bot.zoneX0 + bot.zoneX1) * 0.5, (bot.zoneY0 + bot.zoneY1) * 0.5)
    return actMove(bot, client, me, center)
  if bot.zoneNextKnown:
    let nextCenter = vec((bot.zoneNextX0 + bot.zoneNextX1) * 0.5,
                         (bot.zoneNextY0 + bot.zoneNextY1) * 0.5)
    return Act(moveMask: 0, desiredAim: bradsOf(nextCenter - me), wantFire: false)
  Act(moveMask: 0, desiredAim: -1, wantFire: false)

proc resolveHoldRingSafe(bot: OnepageBot, client: ProtocolClient, me: Vec): Act =
  ## Duck behind the nearest cover that breaks the closest threat's line and
  ## hold there — a defensive intent; it never fires (that is EngageX's job).
  let i = nearestEnemyIdx(bot, me)
  if i < 0:
    return Act(moveMask: 0, desiredAim: -1, wantFire: false)
  let threat = bot.enemies[i].pos
  let duck = bot.findDuckCell(client, me, threat)
  if duck >= 0 and dist(cellCenter(duck), me) > 5.0:
    return actMove(bot, client, me, cellCenter(duck))
  Act(moveMask: 0, desiredAim: bradsOf(threat - me), wantFire: false)

proc resolveEngage(bot: OnepageBot, client: ProtocolClient, me: Vec): Act =
  bot.resolveEngageIdx(client, me, nearestEnemyIdx(bot, me))

proc resolveFinish(bot: OnepageBot, client: ProtocolClient, me: Vec): Act =
  bot.resolveEngageIdx(client, me, weakestEnemyIdx(bot, me))

proc resolvePeel(bot: OnepageBot, client: ProtocolClient, me: Vec): Act =
  ## Peel off the nearest threat: back away while keeping the gun on it, but
  ## never pull the trigger — that is what distinguishes a peel from a trade.
  let i = nearestEnemyIdx(bot, me)
  if i < 0:
    return Act(moveMask: 0, desiredAim: -1, wantFire: false)
  let threat = bot.enemies[i].pos
  let away = me + norm(me - threat) * PeelRange
  let dir = navSteer(bot, client, me, away)
  Act(moveMask: octantBits(dir), desiredAim: bradsOf(threat - me), wantFire: false)

proc resolveHeal(bot: OnepageBot, client: ProtocolClient, me: Vec): Act =
  let i = nearestAvailable(bot.medkitPos, bot.medkitAbsentAt, bot.tick, me)
  if i < 0:
    return Act(moveMask: 0, desiredAim: -1, wantFire: false)
  actMove(bot, client, me, bot.medkitPos[i])

proc resolveLoot(bot: OnepageBot, client: ProtocolClient, me: Vec): Act =
  let i = nearestAvailable(bot.itemPos, bot.itemAbsentAt, bot.tick, me)
  if i < 0:
    return Act(moveMask: 0, desiredAim: -1, wantFire: false)
  actMove(bot, client, me, bot.itemPos[i])

proc resolveRegroupPartner(bot: OnepageBot, client: ProtocolClient, me: Vec): Act =
  if bot.mates.len == 0:
    return Act(moveMask: 0, desiredAim: -1, wantFire: false)
  actMove(bot, client, me, bot.mates[0].pos)

proc resolveSupportPartner(bot: OnepageBot, client: ProtocolClient, me: Vec): Act =
  ## Close on whichever enemy sits nearest our PARTNER's last known position
  ## — the fight we may not see ourselves but our partner can — and help
  ## finish it once in range.
  if bot.mates.len == 0:
    return Act(moveMask: 0, desiredAim: -1, wantFire: false)
  let partnerPos = bot.mates[0].pos
  var idx = -1
  var bestD = 1e18
  for i in 0 ..< bot.enemies.len:
    let d = dist(bot.enemies[i].pos, partnerPos)
    if d < bestD:
      bestD = d
      idx = i
  if idx < 0:
    return actMove(bot, client, me, partnerPos)
  bot.resolveEngageIdx(client, me, idx)

proc resolveAvoidFight(bot: OnepageBot, client: ProtocolClient, me: Vec): Act =
  ## Edge play: step away from the known-enemy centroid, clamped to stay
  ## inside the current zone (never OUT of it just to duck a fight).
  if not bot.zoneKnown:
    return Act(moveMask: 0, desiredAim: -1, wantFire: false)
  var centroid = vec((bot.zoneX0 + bot.zoneX1) * 0.5, (bot.zoneY0 + bot.zoneY1) * 0.5)
  if bot.enemies.len > 0:
    centroid = vec(0, 0)
    for e in bot.enemies:
      centroid = centroid + e.pos
    centroid = centroid * (1.0 / float(bot.enemies.len))
  let away = norm(me - centroid)
  let target = vec(
    clamp(me.x + away.x * AvoidStepOut, bot.zoneX0 + 20.0, bot.zoneX1 - 20.0),
    clamp(me.y + away.y * AvoidStepOut, bot.zoneY0 + 20.0, bot.zoneY1 - 20.0))
  actMove(bot, client, me, target)

proc findThirdPartyTarget(bot: OnepageBot, me: Vec): int =
  ## Two enemy tracks of DIFFERENT colors within ThirdPartyFightRange of
  ## each other read as a fight already under way between two OTHER duos —
  ## jump whichever of that pair sits closer to US. -1 when no such pair is
  ## currently visible/remembered.
  result = -1
  var bestD = 1e18
  for i in 0 ..< bot.enemies.len:
    for j in 0 ..< bot.enemies.len:
      if i == j or bot.enemies[i].color.len == 0 or
          bot.enemies[i].color == bot.enemies[j].color:
        continue
      if dist(bot.enemies[i].pos, bot.enemies[j].pos) > ThirdPartyFightRange:
        continue
      let d = dist(bot.enemies[i].pos, me)
      if d < bestD:
        bestD = d
        result = i

proc resolveThirdParty(bot: OnepageBot, client: ProtocolClient, me: Vec): Act =
  ## Jump a fight already under way between two OTHER duos: same engage
  ## mechanics as ENGAGE/FINISH, just a different target selection.
  bot.resolveEngageIdx(client, me, findThirdPartyTarget(bot, me))

proc bestGrenadeTargetIdx(bot: OnepageBot, me: Vec): tuple[idx: int, d: float] =
  ## Nearest enemy inside the lob's [NadeMinRange, NadeMaxRange] band —
  ## never lob inside NadeMinRange (baseline.nim:150: the blast would clip
  ## us) or beyond a full-charge throw's reach.
  result = (idx: -1, d: 0.0)
  var bestD = 1e18
  for i in 0 ..< bot.enemies.len:
    let d = dist(bot.enemies[i].pos, me)
    if d >= NadeMinRange and d <= NadeMaxRange and d < bestD:
      bestD = d
      result = (idx: i, d: d)

proc resolveUseGrenade(bot: OnepageBot, client: ProtocolClient, me: Vec): Act =
  ## Charge-and-release lob at the nearest in-band enemy — the same charge
  ## state machine baseline.nim's nade branch runs (baseline.nim:3066-3082):
  ## hold ButtonC for a distance-scaled tick count once the turret settles
  ## on the target, release (stop holding C) the tick the charge completes,
  ## and hold still throughout — a lob is not a moving action.
  if not bot.carryingNade:
    bot.nadeCharge = 0
    return Act(moveMask: 0, desiredAim: -1, wantFire: false)
  let (idx, throwD) = bestGrenadeTargetIdx(bot, me)
  if idx < 0:
    bot.nadeCharge = 0
    return Act(moveMask: 0, desiredAim: -1, wantFire: false)
  let aim = bradsOf(bot.enemies[idx].pos - me)
  if bot.nadeCharge == 0:
    bot.nadeNeed = max(3, int(float(NadeFullChargeTicks) *
      (throwD - 30.0) / (NadeMaxRange - 30.0)))
  var holdC = false
  if abs(bradsErr(aim, bot.estAim)) <= CombatDeadband + 2:
    if bot.nadeCharge < bot.nadeNeed:
      inc bot.nadeCharge
      holdC = true
    else:
      bot.nadeCharge = 0                # release this tick = the throw
  Act(moveMask: 0, desiredAim: aim, wantFire: false, holdC: holdC)

const Resolvers: array[Intent, proc(bot: OnepageBot, client: ProtocolClient, me: Vec): Act {.nimcall.}] = [
  RotateToRing: resolveRotateToRing,
  HoldRingSafe: resolveHoldRingSafe,
  Engage: resolveEngage,
  Finish: resolveFinish,
  Peel: resolvePeel,
  Heal: resolveHeal,
  Loot: resolveLoot,
  RegroupPartner: resolveRegroupPartner,
  SupportPartner: resolveSupportPartner,
  AvoidFight: resolveAvoidFight,
  ThirdParty: resolveThirdParty,
  UseGrenade: resolveUseGrenade,
]

const IntentNames: array[Intent, string] = [
  ## The RATIFIED page-facing vocabulary (Maxwell's 12-intent menu). This
  ## array is the ONLY place that vocabulary is written down — the Nim enum
  ## above stays idiomatic PascalCase; a page's "rows" keys must be the
  ## ALL_CAPS strings on the right, exactly.
  RotateToRing: "ROTATE_TO_RING",
  HoldRingSafe: "HOLD_RING_SAFE",
  Engage: "ENGAGE",
  Finish: "FINISH",
  Peel: "PEEL",
  Heal: "HEAL",
  Loot: "LOOT",
  RegroupPartner: "REGROUP_PARTNER",
  SupportPartner: "SUPPORT_PARTNER",
  AvoidFight: "AVOID_FIGHT",
  ThirdParty: "THIRD_PARTY",
  UseGrenade: "USE_GRENADE",
]

proc intentByName(name: string): int =
  for it in Intent:
    if IntentNames[it] == name:
      return ord(it)
  -1

const IntentTagName: array[Intent, string] = [
  ## snake_case tokens for the PER-INTENT `intent.is_<name>` path family
  ## below — see `fullPathRegistry`. Ratified-vocabulary spelling (matches
  ## IntentNames lowercased), so a page author reads "is_finish" and knows
  ## exactly which row it means without cross-referencing the Nim enum.
  RotateToRing: "rotate_to_ring",
  HoldRingSafe: "hold_ring_safe",
  Engage: "engage",
  Finish: "finish",
  Peel: "peel",
  Heal: "heal",
  Loot: "loot",
  RegroupPartner: "regroup_partner",
  SupportPartner: "support_partner",
  AvoidFight: "avoid_fight",
  ThirdParty: "third_party",
  UseGrenade: "use_grenade",
]

proc targetNone(bot: OnepageBot, me: Vec): int = -1
  ## No single enemy is "the target" of this intent (it's positional:
  ## ROTATE_TO_RING, HOLD_RING_SAFE's cover cell, HEAL, LOOT,
  ## REGROUP_PARTNER, AVOID_FIGHT's centroid-flee).

proc targetThreat(bot: OnepageBot, me: Vec): int = nearestEnemyIdx(bot, me)
  ## The nearest enemy — what ENGAGE fires at, what HOLD_RING_SAFE ducks
  ## from, and what PEEL is fleeing; sharing one target keeps all three
  ## consistent about "who is the threat" instead of drifting apart.

proc targetWeakest(bot: OnepageBot, me: Vec): int = weakestEnemyIdx(bot, me)
proc targetThirdPartyIdx(bot: OnepageBot, me: Vec): int = findThirdPartyTarget(bot, me)
proc targetNearestToPartner(bot: OnepageBot, me: Vec): int =
  if bot.mates.len == 0:
    return -1
  let partnerPos = bot.mates[0].pos
  result = -1
  var bestD = 1e18
  for i in 0 ..< bot.enemies.len:
    let d = dist(bot.enemies[i].pos, partnerPos)
    if d < bestD:
      bestD = d
      result = i
proc targetGrenade(bot: OnepageBot, me: Vec): int = bestGrenadeTargetIdx(bot, me).idx

const TargetIdx: array[Intent, proc(bot: OnepageBot, me: Vec): int {.nimcall.}] = [
  ## The SAME per-intent "who/what am I acting on" logic each resolver
  ## above already runs, exposed once so `intent.target_hp`/
  ## `intent.target_dist` (see `fullPathRegistry`) can never disagree with
  ## what the resolver will actually do this tick.
  RotateToRing: targetNone,
  HoldRingSafe: targetThreat,
  Engage: targetThreat,
  Finish: targetWeakest,
  Peel: targetThreat,
  Heal: targetNone,
  Loot: targetNone,
  RegroupPartner: targetNone,
  SupportPartner: targetNearestToPartner,
  AvoidFight: targetNone,
  ThirdParty: targetThirdPartyIdx,
  UseGrenade: targetGrenade,
]

proc intentTargetHp(bot: OnepageBot, me: Vec, intent: Intent): float =
  let idx = TargetIdx[intent](bot, me)
  if idx < 0 or idx >= bot.enemies.len or bot.enemies[idx].hp <= 0: -1.0
  else: float(bot.enemies[idx].hp)

proc intentTargetDist(bot: OnepageBot, me: Vec, intent: Intent): float =
  let idx = TargetIdx[intent](bot, me)
  if idx < 0 or idx >= bot.enemies.len: -1.0
  else: dist(bot.enemies[idx].pos, me)

proc fullPathRegistry(): seq[tuple[path: string, kind: PathKind]] =
  ## The registry `compilePage`/`selectIntent` validate and score against:
  ## policy_stub's coarse/world/self/partner DefaultPaths (already reported
  ## to build-vm), PLUS the fine per-intent family generated HERE from
  ## IntentTagName/TargetIdx — the SAME tables Resolvers/IntentNames are
  ## indexed by. "Declared but unresolvable" cannot happen structurally:
  ## there is no second, hand-maintained path list to drift from this one.
  ##
  ## PENDING MAXWELL'S RULING on the fine `is_<intent>` family (the
  ## coordinator's recommendation, not yet decided) — additive alongside
  ## the coarse tags either way, never a replacement.
  result = @DefaultPaths
  for it in Intent:
    result.add (path: "intent.is_" & IntentTagName[it], kind: pkBool)
  result.add (path: "intent.target_hp", kind: pkNumber)
  result.add (path: "intent.target_dist", kind: pkNumber)
  # BR-SEASON2-INTEGRATION: playbook-page vocabulary aliases/gaps (see
  # numberPath/boolPath/intentTagBool's matching cases and policy_stub.nim's
  # swap note for what each one really resolves to).
  result.add (path: "intent.is_ring_safe", kind: pkBool)
  result.add (path: "intent.is_cover", kind: pkBool)
  result.add (path: "intent.is_medkit", kind: pkBool)
  result.add (path: "intent.dist", kind: pkNumber)
  result.add (path: "intent.enemy_hp_frac", kind: pkNumber)
  result.add (path: "partner.hp_frac", kind: pkNumber)
  result.add (path: "self.ticks_to_ring_close", kind: pkNumber)
  result.add (path: "self.in_ring", kind: pkBool)
  result.add (path: "self.partner_alive", kind: pkBool)
  result.add (path: "intent.exposure", kind: pkNumber)

# -----------------------------------------------------------------------------
# World -> path resolution: the concrete (perception-true) feature set this
# bot can compute, wired into the VM-seam interface (onepage/policy_stub).
# -----------------------------------------------------------------------------

type WorldFeatures = object
  selfHpFrac: float
  partnerAlive: bool
  partnerDist: float            # -1 = unknown
  partnerInCombat: bool
  worldEnemyCount: int
  worldNearestEnemyDist: float   # -1 = none visible/remembered
  worldWeakestEnemyHp: float      # -1 = no enemy hp ever read
  worldInZone: bool
  worldZoneDist: float
  worldMedkitDist: float          # -1 = none known
  worldItemDist: float            # -1 = none known
  worldThirdPartyDist: float       # -1 = no fight-between-others visible
  worldCarryingNade: bool

proc buildFeatures(bot: OnepageBot, me: Vec): WorldFeatures =
  result.selfHpFrac = float(bot.hp) / float(MaxHp)
  result.partnerAlive = bot.mates.len > 0
  result.partnerDist = (if bot.mates.len > 0: dist(bot.mates[0].pos, me) else: -1.0)
  if bot.mates.len > 0:
    for e in bot.enemies:
      if dist(e.pos, bot.mates[0].pos) < ThreatRange:
        result.partnerInCombat = true
        break
  result.worldEnemyCount = bot.enemies.len
  result.worldNearestEnemyDist = -1.0
  block:
    let i = nearestEnemyIdx(bot, me)
    if i >= 0:
      result.worldNearestEnemyDist = dist(bot.enemies[i].pos, me)
  result.worldWeakestEnemyHp = -1.0
  for e in bot.enemies:
    if e.hp > 0 and (result.worldWeakestEnemyHp < 0 or float(e.hp) < result.worldWeakestEnemyHp):
      result.worldWeakestEnemyHp = float(e.hp)
  result.worldInZone = bot.zoneKnown and me.x >= bot.zoneX0 and me.x <= bot.zoneX1 and
    me.y >= bot.zoneY0 and me.y <= bot.zoneY1
  result.worldZoneDist =
    if not bot.zoneKnown or result.worldInZone: 0.0
    else:
      let cx = clamp(me.x, bot.zoneX0, bot.zoneX1)
      let cy = clamp(me.y, bot.zoneY0, bot.zoneY1)
      dist(me, vec(cx, cy))
  result.worldMedkitDist = -1.0
  block:
    let i = nearestAvailable(bot.medkitPos, bot.medkitAbsentAt, bot.tick, me)
    if i >= 0: result.worldMedkitDist = dist(bot.medkitPos[i], me)
  result.worldItemDist = -1.0
  block:
    let i = nearestAvailable(bot.itemPos, bot.itemAbsentAt, bot.tick, me)
    if i >= 0: result.worldItemDist = dist(bot.itemPos[i], me)
  result.worldThirdPartyDist = -1.0
  block:
    let i = findThirdPartyTarget(bot, me)
    if i >= 0: result.worldThirdPartyDist = dist(bot.enemies[i].pos, me)
  result.worldCarryingNade = bot.carryingNade

proc intentTagBool(intent: Intent, path: string): bool =
  ## The COARSE `intent.*` tags: what KIND of row this is, so a page can
  ## write rules like "boost intent.is_enemy rows while self.hp_frac is
  ## high". See onepage/policy_stub.nim's DefaultPaths for the full
  ## reported list. Falls through to the FINE per-intent family below —
  ## PENDING MAXWELL'S RULING, additive, never a replacement for these.
  case path
  of "intent.is_enemy": intent in {Engage, Finish, SupportPartner, ThirdParty}
  of "intent.is_peel": intent in {Peel, AvoidFight}
  of "intent.is_recover": intent == Heal
  of "intent.is_item": intent == Loot
  of "intent.is_partner": intent in {RegroupPartner, SupportPartner}
  of "intent.is_zone": intent in {RotateToRing, HoldRingSafe, AvoidFight}
  of "intent.is_grenade": intent == UseGrenade
  # BR-SEASON2-INTEGRATION ALIASES: tools/flash/playbook/*.json (authored on
  # maxwell/br-onepage-vm) uses these three names for tags this resolver
  # already computes under a different name — same real perception, no new
  # data. See policy_stub.nim's swap-note header for the merge that exposed
  # this vocabulary drift between the two branches.
  of "intent.is_ring_safe": intent == HoldRingSafe
  of "intent.is_cover": intent == HoldRingSafe
  of "intent.is_medkit": intent == Heal
  else: path == ("intent.is_" & IntentTagName[intent])

proc numberPath(bot: OnepageBot, me: Vec, f: WorldFeatures, intent: Intent, path: string): float =
  case path
  of "self.hp_frac": f.selfHpFrac
  of "partner.dist": f.partnerDist
  of "world.enemy_count": float(f.worldEnemyCount)
  of "world.nearest_enemy_dist": f.worldNearestEnemyDist
  of "world.weakest_enemy_hp": f.worldWeakestEnemyHp
  of "world.zone_dist": f.worldZoneDist
  of "world.medkit_dist": f.worldMedkitDist
  of "world.item_dist": f.worldItemDist
  of "world.third_party_dist": f.worldThirdPartyDist
  of "intent.target_hp": intentTargetHp(bot, me, intent)
  of "intent.target_dist": intentTargetDist(bot, me, intent)
  # BR-SEASON2-INTEGRATION ALIASES / GAPS (see policy_stub.nim's swap note):
  of "intent.dist": intentTargetDist(bot, me, intent)                # alias
  of "intent.enemy_hp_frac":                                         # real, derived
    let hp = intentTargetHp(bot, me, intent)
    (if hp < 0: -1.0 else: hp / float(MaxHp))
  of "partner.hp_frac":                                              # real, derived
    (if bot.mates.len > 0: float(bot.mates[0].hp) / float(MaxHp) else: -1.0)
  of "self.ticks_to_ring_close":
    # GAP, NOT FIXED: no zone-phase countdown reaches this bot (only the
    # current/next zone RECT, never its timing) — reported honestly rather
    # than invented. Conservative default ("plenty of time left") so a page
    # gating on this falls back to its "not self.in_ring" branch instead of
    # a fabricated countdown.
    999999.0
  of "intent.exposure":
    # GAP, NOT FIXED: this resolver has no line-of-sight/cover-density signal
    # (no "am I in the open" perception exists in this branch's onepage.nim
    # at all). Neutral default (never penalizes, never rewards) rather than
    # a fabricated exposure model.
    0.0
  else: 0.0

proc boolPath(f: WorldFeatures, intent: Intent, path: string): bool =
  case path
  of "partner.alive": f.partnerAlive
  of "partner.in_combat": f.partnerInCombat
  of "world.in_zone": f.worldInZone
  of "world.carrying_nade": f.worldCarryingNade
  of "self.in_ring": f.worldInZone                # alias, real
  of "self.partner_alive": f.partnerAlive          # alias, real
  else: intentTagBool(intent, path)

proc selectIntentFor(bot: OnepageBot, me: Vec, page: PolicyPage, f: WorldFeatures): Intent =
  proc ctxFor(name: string): IntentContext =
    var intent = Intent(0)
    let ord = intentByName(name)
    if ord >= 0: intent = Intent(ord)
    IntentContext(
      resolveNumber: (proc(path: string): float = numberPath(bot, me, f, intent, path)),
      resolveBool: (proc(path: string): bool = boolPath(f, intent, path)),
    )
  var names: array[Intent, string]
  for it in Intent:
    names[it] = IntentNames[it]
  let chosen = policy_stub.selectIntent(page, names, ctxFor)
  let ord = intentByName(chosen)
  if ord >= 0: Intent(ord) else: Intent(0)

# -----------------------------------------------------------------------------
# Page loading (episode-start flash) + REFLASH (mid-episode swap), unified.
#
# DETERMINISM (per the coordinator's ruling): the page an env var delivers
# into THIS PROCESS never touches the wire on its own, so a replay re-
# simulating the episode has no record of which strategy a cog actually
# played — a hidden input outside the replay, worse than the same hole
# mid-episode because the starting page governs most of the episode. Fix:
# there is exactly ONE way `activePage` ever changes — `maybeApplyReflash`,
# fed only by `proposeReflash` — and the episode-start flash goes through
# that SAME call (see runBot's `playing` edge below) instead of setting
# `activePage` directly. `flashPage` below only clears state; it never sets
# `activePage` to anything but an empty (all-zero-score) page, so the
# window between "a game started" and "our first proposeReflash lands" — a
# few ticks at most, before any real target exists anyway — defaults
# deterministically to Intent(0) (ROTATE_TO_RING), never to a page nobody
# recorded.
#
# SWAP-BOUNDARY RULE — confirmed against build-replayflash's actual
# `applyPolicyPage`: it writes bookkeeping ONLY (policyPage/Hash/Tick/Epoch,
# feeding gameHash and a future viewer) and drives ZERO sim decisions —
# applied unconditionally at whatever tick it's drained, no windup check.
# This process is the ONLY thing that ever turns "a new page" into a
# different button press (this bot has no direct sim access — it only ever
# emits masks), so the boundary is entirely LOCAL: hold masks computed off
# the OLD page until OUR OWN view of the fire windup (a fresh ButtonA
# press arms ~FireWindupTicksLocal ticks, mirroring sim_types.
# FireWindupTicks — ours is an estimate, since we cannot read the sim's
# real fireWindup countdown) says the shot has resolved, THEN start
# computing off the NEW page. Whatever masks we send meanwhile get
# recorded verbatim, exactly like a human's held key — no engine timing
# change required. (Two other things build-replayflash's review settled:
# no downlink marker is needed for OUR OWN swap timing — see above — and
# the wire send below carries the RAW PAGE BYTES verbatim, magic-prefixed,
# matching `appState.policyPageFlashes[websocket] = pageBytes` exactly.)
#
# WIRE CONTRACT (bot -> server; the server.nim/global.nim receive arm is a
# separate, precisely-scoped change — see the handoff message for the exact
# diff location, src/ctf/global.nim:2001's `applyPlayerViewerMessage`):
#   Reuses the existing 0x86 "debug sprite" opcode (`blobFromSpriteDebugSprites`,
#   already a generic byte blob, already parsed server-side — NO vendor/wire
#   change) as the carrier. Since that opcode ALSO carries real debug-
#   overlay packets (falling through to `pendingDebugSprites.add` otherwise
#   — build-replayflash's review), our payload is self-identifying: a fixed
#   magic prefix (`PolicyPageMagic` below) no real overlay packet could
#   ever produce, followed by the raw page JSON bytes verbatim.
# -----------------------------------------------------------------------------

# PolicyPageMagic is NOT declared here. It comes from `ctf/labels`, the
# module this bot already imports for the shared observation vocabulary, so
# the sender below and the server's receive arm read ONE definition. It used
# to be typed out in both files, which nothing checked: editing either copy
# would have failed no build and no test, and simply made every proposal
# decode as a debug-overlay packet instead of a reflash.

const FireWindupTicksLocal = 5
  ## Mirrors sim_types.FireWindupTicks (~0.2s from trigger pull to the shot;
  ## aim locks at the pull) — see the SWAP-BOUNDARY note above for why this
  ## is a local ESTIMATE (we cannot read the sim's authoritative countdown),
  ## not a value the engine needs to agree with us on: we only ever use it
  ## to avoid swapping OUR OWN policy out from under OUR OWN pulled trigger.

proc loadPageRaw(): string =
  let inline = getEnv("COWORLD_POLICY_PAGE")
  if inline.len > 0:
    return inline
  let path = getEnv("COWORLD_POLICY_PAGE_FILE")
  if path.len > 0:
    if not fileExists(path):
      raise newException(ValueError, "COWORLD_POLICY_PAGE_FILE set but not found: " & path)
    return readFile(path)
  raise newException(ValueError,
    "no policy page: set COWORLD_POLICY_PAGE (raw JSON) or COWORLD_POLICY_PAGE_FILE (path)")

proc flashPage(bot: OnepageBot) =
  ## Clears reflash bookkeeping at the episode-start edge. Deliberately
  ## does NOT set `activePage` to `bot.startupPage` — see the DETERMINISM
  ## note above; that only happens via `maybeApplyReflash`, once runBot's
  ## `playing` edge below has actually sent it on the wire.
  bot.activePage = PolicyPage()          # empty: every row scores 0
  bot.pageHasPending = false
  bot.pageSwapAtTick = -1
  bot.proposedPageRaw = ""               # forces the NEXT episode's first
  bot.proposedPageHash = ""              # proposeReflash call to actually
                                          # send, not no-op as "unchanged"

proc windupTicksRemaining(bot: OnepageBot): int =
  ## Ticks until our own last fire-press's shot has (probably) resolved,
  ## estimated from `bot.lastFireTick` — see FireWindupTicksLocal above.
  if not bot.firedLast:
    return 0
  max(0, FireWindupTicksLocal - (bot.tick - bot.lastFireTick))

proc scheduleSwap(bot: OnepageBot, page: PolicyPage) =
  ## Schedules `page` to become active at the swap-boundary rule: never
  ## mid-windup on our own last shot.
  bot.pendingPage = page
  bot.pageSwapAtTick = bot.tick + max(1, bot.windupTicksRemaining())
  bot.pageHasPending = true

proc maybeApplyReflash(bot: OnepageBot) =
  ## Applies a scheduled swap once its tick arrives. This is the ONLY
  ## place `activePage` changes.
  if bot.pageHasPending and bot.tick >= bot.pageSwapAtTick:
    bot.activePage = bot.pendingPage
    bot.pageHasPending = false
    bot.pageSwapAtTick = -1
    echo "policy reflash applied at tick=", bot.tick, " hash=", bot.proposedPageHash

proc proposeReflash(ws: WebSocket, bot: OnepageBot, raw: string) =
  ## SEND (for the replay's record) and locally SCHEDULE the swap, in the
  ## same call — see the module header for why both halves belong here.
  ## Used identically for the episode-start flash and a mid-episode
  ## reflash (see runBot's `playing` edge and `pollForNewPage`).
  if raw == bot.proposedPageRaw:
    return                                  # already proposed; do not spam
  var page: PolicyPage
  try:
    page = policy_stub.compilePage(raw, IntentNames, fullPathRegistry())
  except ValueError as e:
    echo "reflash rejected (not sent, not applied): ", e.msg
    return
  bot.proposedPageRaw = raw
  var hash = 0'u64
  for c in raw:
    hash = hash * 31 + uint64(ord(c))
  bot.proposedPageHash = toHex(hash)
  var bytes = newSeq[uint8](PolicyPageMagic.len + raw.len)
  for i, c in PolicyPageMagic: bytes[i] = uint8(c)
  for i, c in raw: bytes[PolicyPageMagic.len + i] = uint8(c)
  ws.send(blobFromSpriteDebugSprites(bytes), BinaryMessage)
  bot.scheduleSwap(page)
  echo "proposed policy reflash (", raw.len, " bytes, hash=", bot.proposedPageHash,
    ", effective tick=", bot.pageSwapAtTick, ")"

proc pollForNewPage(bot: OnepageBot): string =
  ## STAND-IN trigger for a MID-EPISODE candidate: re-reads
  ## COWORLD_POLICY_PAGE_FILE if its content differs from what we last
  ## proposed. The REAL trigger (the field service telling this process
  ## "a new page is ready") is a different lane's delivery mechanism; this
  ## only exists so proposeReflash has something to call locally. The
  ## episode-start flash does NOT go through this — see runBot.
  let path = getEnv("COWORLD_POLICY_PAGE_FILE")
  if path.len == 0 or not fileExists(path):
    return ""
  let raw = readFile(path)
  if raw == bot.proposedPageRaw: "" else: raw


# -----------------------------------------------------------------------------
# Main decide loop
# -----------------------------------------------------------------------------

proc actToMask(bot: OnepageBot, act: Act): uint8 =
  ## baseline.nim:3296-3309, verbatim tail: rotate toward desiredAim by the
  ## shortest arc, edge-fire ButtonA (never rotate on the pull tick).
  var mask = act.moveMask
  if act.desiredAim >= 0:
    let err = bradsErr(act.desiredAim, bot.estAim)
    if err > CombatDeadband:
      mask = mask or ButtonB
    elif err < -CombatDeadband:
      mask = mask or ButtonSelect
  if act.wantFire and not bot.firedLast:
    mask = act.moveMask or ButtonA
  if (mask and ButtonA) != 0 and not bot.firedLast:
    bot.lastFireTick = bot.tick           # fresh press: a windup just armed
  bot.firedLast = (mask and ButtonA) != 0
  if act.holdC:
    mask = mask or ButtonC
  bot.rotSign =
    if (mask and ButtonB) != 0: 1
    elif (mask and ButtonSelect) != 0: -1
    else: 0
  mask

proc resetTransient(bot: OnepageBot) =
  ## Drops per-episode memory at the lobby/game-over interstitial
  ## (baseline.nim:1419-1455, trimmed to this bot's fields) and re-flashes
  ## the startup page — the episode-start flash edge.
  bot.enemies.setLen(0)
  bot.mates.setLen(0)
  bot.hp = MaxHp
  for i in 0 ..< bot.medkitAbsentAt.len: bot.medkitAbsentAt[i] = -1
  for i in 0 ..< bot.itemAbsentAt.len: bot.itemAbsentAt[i] = -1
  bot.colorLocked = false
  bot.gameStart = bot.tick
  bot.firedLast = false
  bot.estAim = 0
  bot.rotSign = 0
  bot.navGoal = -1
  bot.zoneKnown = false
  bot.zoneNextKnown = false
  bot.flashPage()

proc decide(bot: OnepageBot, client: ProtocolClient): uint8 =
  if not bot.colorLocked:
    for i in 0 ..< rosterColorCount():
      let c = rosterColor(i)
      if client.findSelf(c).alive:
        bot.colorLocked = true
        bot.myColor = c
        break
  let (alive, me) = client.findSelf(bot.myColor)
  if not alive:
    bot.firedLast = false
    bot.rotSign = 0
    return 0
  bot.updatePerception(client, me)
  bot.maybeApplyReflash()
  let f = buildFeatures(bot, me)
  let intent = selectIntentFor(bot, me, bot.activePage, f)
  bot.lastIntent = intent
  let act = Resolvers[intent](bot, client, me)
  actToMask(bot, act)

# -----------------------------------------------------------------------------
# Wire loop (mirrors players/baseline/baseline.nim:3339-3457's shape)
# -----------------------------------------------------------------------------

type OnepageComponent = object
  bot: OnepageBot
  client: ProtocolClient
  lastMask: uint8
  hasSent: bool

proc initOnepageComponent(slot: int, startupPage: PolicyPage): OnepageComponent =
  randomize(slot * 7919 + 1)
  result.bot = OnepageBot(slot: slot, startupPage: startupPage)
  result.bot.myColor = rosterColor(slot mod rosterColorCount())
  result.client = initProtocolClient()

proc advancePolicy(component: var OnepageComponent, advance: int) =
  component.bot.tick += advance
  component.bot.estAim = floorMod(
    component.bot.estAim + component.bot.rotSign * AimRate * advance, AimBrads)

proc policyReplies(component: var OnepageComponent): seq[string] =
  if not component.client.mapCameraReady:
    component.bot.resetTransient()
    return
  if not component.bot.navBuilt and component.client.walkabilityReady:
    component.bot.buildNavGrid(component.client)
  let maybeNewRaw = pollForNewPage(component.bot)
  if maybeNewRaw.len > 0:
    try:
      discard policy_stub.compilePage(maybeNewRaw, IntentNames, fullPathRegistry())  # validate before proposing
      component.bot.pendingProposal = maybeNewRaw
    except ValueError as e:
      echo "reflash candidate rejected (not proposed): ", e.msg
  let mask = component.bot.decide(component.client)
  if not component.hasSent or mask != component.lastMask:
    result.add(inputBlob(mask))
    component.lastMask = mask
    component.hasSent = true

proc onMessage*(component: var OnepageComponent, message: string): seq[string] =
  component.client.applyFrame(message)
  component.advancePolicy(component.client.frameAdvance)
  component.policyReplies()

proc runBot(url: string, startupPage: PolicyPage) =
  let
    slot = slotFromUrl(url)
    endpoint = ensureWsPath(url, WebSocketPath)
    # Opt-in ONLY, mirrors baseline.nim's CTF_BOT_FAST_READY exactly
    # (baseline.nim:3400-3406): the per-frame ready send measurably corrupts
    # baseline's dead-reckoned-aim timing in competitive play, so league/
    # xreq runners never set this. Recording harnesses DO want it — without
    # it a fastMode server never skips frames while an onepage seat is in
    # the match, so a recording session runs at wall-clock pace instead of
    # as-fast-as-possible (a real harness measured this the hard way).
    fastReadyEnabled = getEnv("CTF_BOT_FAST_READY").len > 0
  var component = initOnepageComponent(slot, startupPage)
  echo "onepage slot=", slot, " -> ", endpoint
  var everConnected = false
  var playing = false
  while true:
    try:
      let ws = newWebSocket(endpoint)
      ws.socket.setSockOpt(OptNoDelay, true, level = IPPROTO_TCP.cint)
      ws.send(spritesOffBlob(), BinaryMessage)
      echo "connected ", endpoint
      everConnected = true
      component.client.reset()
      component.bot.navBuilt = false
      component.bot.resetTransient()
      component.hasSent = false
      while true:
        if not component.client.receiveLatestFrame(ws, false):
          continue
        let advance = max(1, component.client.frameAdvance)
        component.advancePolicy(advance)
        if not component.client.mapCameraReady:
          if playing:
            playing = false
          component.bot.resetTransient()
          continue
        if not playing:
          playing = true
          # DETERMINISM: the episode-start page is delivered by an env var
          # (a hidden input outside the replay), so its very first use goes
          # through the SAME propose/schedule path a mid-episode reflash
          # uses (see the module header) — the replay's record of "which
          # strategy this cog played" starts here, not from a silent local
          # assignment.
          proposeReflash(ws, component.bot, startupPage.raw)
        if component.bot.pendingProposal.len > 0:
          proposeReflash(ws, component.bot, component.bot.pendingProposal)
          component.bot.pendingProposal = ""
        for reply in component.policyReplies():
          ws.send(reply, BinaryMessage)
        if fastReadyEnabled:
          ws.send(readyBlob(), BinaryMessage)
    except Exception as e:
      if everConnected:
        echo "game over, exiting: ", e.msg
        quit(0)
      echo "connect retry: ", e.msg
      sleep(250)

when isMainModule:
  # A harness that tails our stdout (e.g. keying a mid-episode reflash
  # trigger off "proposed policy reflash") will otherwise see NOTHING until
  # the process exits: stdout defaults to fully block-buffered whenever
  # it's not a live tty, i.e. every time it's redirected to a file — the
  # exact case a recording harness always is. A real harness run silently
  # recorded only the opening flash before this fix. echo now lands live.
  setStdIoUnbuffered()
  let url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if url.len == 0:
    stderr.writeLine("FATAL: COWORLD_PLAYER_WS_URL is required.")
    quit(1)
  var startupPage: PolicyPage
  try:
    startupPage = policy_stub.compilePage(loadPageRaw(), IntentNames, fullPathRegistry())
  except ValueError as e:
    stderr.writeLine("FATAL: invalid one-page policy: " & e.msg)
    quit(1)
  runBot(url, startupPage)
