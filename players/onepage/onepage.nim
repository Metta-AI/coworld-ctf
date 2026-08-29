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
  ## The `intent.*` path family: fixed tags describing what KIND of
  ## candidate row this is, so a page can write rules like "boost
  ## intent.is_enemy rows while self.hp_frac is high". See onepage/
  ## policy_stub.nim's DefaultPaths for the full reported list.
  case path
  of "intent.is_enemy": intent in {Engage, Finish, SupportPartner, ThirdParty}
  of "intent.is_peel": intent in {Peel, AvoidFight}
  of "intent.is_recover": intent == Heal
  of "intent.is_item": intent == Loot
  of "intent.is_partner": intent in {RegroupPartner, SupportPartner}
  of "intent.is_zone": intent in {RotateToRing, HoldRingSafe, AvoidFight}
  of "intent.is_grenade": intent == UseGrenade
  else: false

proc numberPath(f: WorldFeatures, path: string): float =
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
  else: 0.0

proc boolPath(f: WorldFeatures, intent: Intent, path: string): bool =
  case path
  of "partner.alive": f.partnerAlive
  of "partner.in_combat": f.partnerInCombat
  of "world.in_zone": f.worldInZone
  of "world.carrying_nade": f.worldCarryingNade
  else: intentTagBool(intent, path)

proc selectIntentFor(page: PolicyPage, f: WorldFeatures): Intent =
  proc ctxFor(name: string): IntentContext =
    var intent = Intent(0)
    let ord = intentByName(name)
    if ord >= 0: intent = Intent(ord)
    IntentContext(
      resolveNumber: (proc(path: string): float = numberPath(f, path)),
      resolveBool: (proc(path: string): bool = boolPath(f, intent, path)),
    )
  var names: array[Intent, string]
  for it in Intent:
    names[it] = IntentNames[it]
  let chosen = policy_stub.selectIntent(page, names, ctxFor)
  let ord = intentByName(chosen)
  if ord >= 0: Intent(ord) else: Intent(0)

# -----------------------------------------------------------------------------
# Page loading (episode-start flash) + REFLASH (mid-episode swap).
#
# SWAP-BOUNDARY RULE (published for build-replayflash to implement the sim
# side against, bit-for-bit — see the handoff message):
#   Let T_req = the tick the sim first validates a player's reflash
#   proposal. Let T_effect = T_req + max(1, fireWindupRemaining_at_T_req)
#   computed ONCE at T_req (never re-evaluated tick by tick, so it needs no
#   forward-looking simulation). The sim stamps T_effect into the ratifying
#   marker as soon as it validates the proposal, BEFORE T_effect arrives.
#   Every consumer (live bot, spectator, replay resim) applies the swap by
#   comparing its OWN current tick against the stated T_effect — never by
#   "the tick I happened to first observe the marker" — so it is a pure
#   function of T_effect and immune to frame coalescing, wall-clock, or
#   arrival order. decide() calls for tick < T_effect run the OLD page;
#   tick >= T_effect run the NEW page.
#
# WIRE CONTRACT (PROPOSED, NOT YET IMPLEMENTED SERVER-SIDE — see the
# handoff message for the full reasoning):
#   Bot -> server: reuse the existing 0x86 "debug sprite" opcode (already a
#   generic arbitrary-length byte blob, already parsed generically by the
#   server; NO vendor/wire change) via `blobFromSpriteDebugSprites`, payload
#   `{"kind":"policy_reflash_propose","hash":"<hash>"}` (full page bytes
#   optional; we hold them locally, we only need the SIM to agree on a
#   tick).
#   Server -> bot: an assumed downlink label, ASSUMED_REFLASH_LABEL below —
#   NOT in src/ctf/labels.nim yet (deliberately not added there: its
#   producer does not exist, and labels.nim's own header calls an unproduced
#   consumer-only label exactly the kind of drift it exists to prevent).
#   Grammar: "policy reflash <color> <T_effect> <hash>", STICKY (re-emitted
#   every frame from T_effect onward until superseded) so a bot that
#   coalesces past several frames still recovers T_effect exactly.
# -----------------------------------------------------------------------------

const AssumedReflashLabelPrefix = "policy reflash "

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
  ## The episode-start flash: latch the loaded page as the one this life
  ## plays under. Called exactly once per episode, at the mapCameraReady
  ## false->true edge (see resetTransient below) — never mid-tick.
  bot.activePage = bot.startupPage
  bot.pageHasPending = false
  bot.pageSwapAtTick = -1
  # No echo here on purpose: this runs every tick of the lobby wait (mirrors
  # baseline.nim's own resetTransient, called the same way) — the edge
  # worth logging is "a live game actually started", logged once in runBot
  # where `playing` flips false->true.

proc maybeApplyReflash(bot: OnepageBot) =
  ## Applies a pending reflash at the swap boundary rule above. Pure
  ## function of bot.tick vs the stated T_effect — never "did we just now
  ## see the marker".
  if bot.pageHasPending and bot.tick >= bot.pageSwapAtTick:
    bot.activePage = bot.pendingPage
    bot.pageHasPending = false
    bot.pageSwapAtTick = -1
    bot.lastAppliedReflashHash = bot.proposedPageHash
    echo "policy reflash applied at tick=", bot.tick

proc scanForReflashRatification(bot: OnepageBot, client: ProtocolClient) =
  ## Watches for the ASSUMED downlink marker ratifying OUR OWN outstanding
  ## proposal (color-filtered) and schedules the swap at its stated
  ## T_effect. We only know how to apply a page whose bytes we hold
  ## locally (the one we proposed) — a hash we do not recognize means the
  ## round trip has not completed on our side, and is ignored rather than
  ## guessed at.
  if bot.proposedPageHash.len == 0 or bot.proposedPageHash == bot.lastAppliedReflashHash:
    return
  for (o, label) in client.spriteObjectsWithLabelPrefix(AssumedReflashLabelPrefix):
    let parts = label[AssumedReflashLabelPrefix.len .. ^1].split(' ')
    if parts.len != 3 or parts[0] != bot.myColor or parts[2] != bot.proposedPageHash:
      continue
    try:
      bot.pendingPage = policy_stub.compilePage(bot.proposedPageRaw, IntentNames)
      bot.pageSwapAtTick = parseInt(parts[1])
      bot.pageHasPending = true
    except ValueError:
      discard

proc proposeReflash(ws: WebSocket, bot: OnepageBot, raw: string) =
  ## The bot-side SEND half of the reflash channel: per build-replayflash's
  ## published contract (`appState.policyPageFlashes[websocket] = pageJson`
  ## in src/ctf/server.nim, drained into `sim.applyPolicyPage` at the tick
  ## boundary), the server wants the RAW PAGE BYTES themselves, not a hash
  ## or an envelope — so that is exactly what goes over the wire. Reuses
  ## the existing 0x86 "debug sprite" opcode (already a generic arbitrary-
  ## length byte blob, already parsed server-side; NO vendor/wire-format
  ## change) as the carrier — PROPOSED, pending build-replayflash confirming
  ## the matching server.nim receive arm (see the handoff message).
  ##
  ## The TRIGGER — how a page ready to propose actually reaches this
  ## process mid-episode — is outside this file's scope (the field
  ## service's delivery channel, per the brief); `pollForNewPage` below is a
  ## documented stand-in so the full local state machine is exercisable.
  if raw == bot.proposedPageRaw:
    return                                  # already proposed; do not spam
  bot.proposedPageRaw = raw
  var hash = 0'u64
  for c in raw:
    hash = hash * 31 + uint64(ord(c))
  bot.proposedPageHash = toHex(hash)
  var bytes = newSeq[uint8](raw.len)
  for i, c in raw: bytes[i] = uint8(c)
  ws.send(blobFromSpriteDebugSprites(bytes), BinaryMessage)
  echo "proposed policy reflash (", raw.len, " bytes, hash=", bot.proposedPageHash, ")"

proc pollForNewPage(bot: OnepageBot): string =
  ## STAND-IN trigger: re-reads COWORLD_POLICY_PAGE_FILE if its content
  ## changed since the last flash/proposal. The REAL trigger (the field
  ## service telling this process "a new page is ready") is a different
  ## lane's delivery mechanism; this only exists so proposeReflash has
  ## something to call locally.
  let path = getEnv("COWORLD_POLICY_PAGE_FILE")
  if path.len == 0 or not fileExists(path):
    return ""
  readFile(path)

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
  bot.scanForReflashRatification(client)
  bot.maybeApplyReflash()
  let f = buildFeatures(bot, me)
  let intent = selectIntentFor(bot.activePage, f)
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
      discard policy_stub.compilePage(maybeNewRaw, IntentNames)  # validate before proposing
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
          echo "policy flashed at tick=", component.bot.tick,
            " rows=", component.bot.activePage.row.len
        if component.bot.pendingProposal.len > 0:
          proposeReflash(ws, component.bot, component.bot.pendingProposal)
          component.bot.pendingProposal = ""
        for reply in component.policyReplies():
          ws.send(reply, BinaryMessage)
    except Exception as e:
      if everConnected:
        echo "game over, exiting: ", e.msg
        quit(0)
      echo "connect retry: ", e.msg
      sleep(250)

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if url.len == 0:
    stderr.writeLine("FATAL: COWORLD_PLAYER_WS_URL is required.")
    quit(1)
  var startupPage: PolicyPage
  try:
    startupPage = policy_stub.compilePage(loadPageRaw(), IntentNames)
  except ValueError as e:
    stderr.writeLine("FATAL: invalid one-page policy: " & e.msg)
    quit(1)
  runBot(url, startupPage)
