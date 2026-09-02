## Production PlayView/PlayContext model selection and canonical JSON emit.
##
## Selection is intentionally separate from encoding. `selectPlayView` returns
## a typed, already-trimmed model: a future fixed-layout binary encoder must be
## able to consume that same model without changing which rows ship. The JSON
## encoder is the socket/replay path and writes canonical bytes directly with
## `CanonicalWriter`; it never builds a `JsonNode`.
##
## The byte cap is applied before encoding by an exact JSON cost model. Each
## candidate row's canonical encoded byte length is computed once with the same
## row writer used by the final JSON encoder, then a running total adds the row
## bytes plus the exact object/array/comma structure needed to place it in the
## final document. Selection never watches a partially written output buffer.
##
## Residual bytes are spent in this fixed cross-section order: standing intent,
## hazards, aggressors, tracks, items, kill feed, shouts. That keeps immediate
## body/safety facts ahead of lower-rate narrative facts under very small caps.
## Within each section the order is deterministic: tracks by distance then seat;
## items by freshness, distance, kind, event id; aggressors and kill feed by
## recency; hazards by Appendix R.1's urgency rule; shouts by recency, distance,
## team, slot, event id.

import std/[algorithm, options]

import ../ctf/sim_types
import body
import body_map
import canonical_fast
import finisher
import types

type
  PlayPoint* = BodyPoint

  PlayRect* = object
    x*, y*, w*, h*: int

  PlaySelf* = object
    pos*: PlayPoint
    hp*: int
    hpFrac*: float
    aimBrads*: int
    alive*: bool
    lives*: Option[int]
    carrying*: bool
    downed*: bool
      ## LOOT(s2): a frozen ghost -- never true unless downedMode is armed.
      ## Stays `alive == true` while downed (that is what makes it
      ## revivable), so a policy needs THIS bit, not `alive`, to know it
      ## cannot fire/loot/shout right now.

  PlayZone* = object
    phase*: int
    current*: PlayRect
    next*: Option[PlayRect]
    ticksToShrink*: int
    dps*: int

  ObjectiveState* = enum
    osHome
    osTaken
    osCaptured

  PlayObjective* = object
    team*: Team
    state*: ObjectiveState
    pos*: Option[PlayPoint]

  PlayTrack* = object
    seat*: int
    team*: Team
    pos*: PlayPoint
    aimBrads*: Option[int]
    hp*: Option[int]
    freshTick*: uint32
    bounty*: bool
    downed*: bool
      ## LOOT(s2): this tracked seat is a frozen ghost. For a fogged enemy
      ## track this rides the same visibility as the rest of the row; for
      ## the duo-partner grant row (playViewSourceFromBody) it is the
      ## deliberate reason this field exists at all -- a policy cannot
      ## revive a partner it cannot see is down.

  PlayItemKind* = enum
    pikGrenade
    pikMedkit
    pikShield
    pikSpray
    pikBarrier

  PlayItem* = object
    eventId*: uint64
    kind*: PlayItemKind
    pos*: PlayPoint
    present*: Option[bool]
    freshTick*: uint32

  PlayAggressor* = object
    eventId*: uint64
    tick*: uint32
    dirBrads*: int
    seat*: Option[int]

  PlayKillFeedRow* = object
    eventId*: uint64
    tick*: uint32
    killerTeam*: Team
    victimSeat*: int

  PlayShout* = object
    eventId*: uint64
    team*: Team
    slotLetter*: string
    text*: string
    pos*: PlayPoint
    tick*: uint32

  PlayGrenadeHazard* = object
    eventId*: uint64
    coversSelf*: bool
    pos*: PlayPoint
    predictedBlastPos*: PlayPoint
    ticksToBlast*: int

  PlayBlastCue* = object
    eventId*: uint64
    coversSelf*: bool
    pos*: PlayPoint
    tick*: uint32

  PlayOwnThrow* = object
    target*: PlayPoint
    releaseTick*: uint32
    blastRadius*: int

  PlaySprayHazardKind* = enum
    pshVisibleCone
    pshAnonymousImpact

  PlaySprayHazard* = object
    eventId*: uint64
    coversSelf*: bool
    tick*: uint32
    case kind*: PlaySprayHazardKind
    of pshVisibleCone:
      attackerSeat*: int
      origin*: PlayPoint
      aimBrads*: int
      reachPx*: int
      maxWidthPx*: int
    of pshAnonymousImpact:
      impactPos*: PlayPoint
      incomingDirBrads*: int

  PlayHazards* = object
    grenades*: seq[PlayGrenadeHazard]
    blastCues*: seq[PlayBlastCue]
    ownThrow*: Option[PlayOwnThrow]
    sprays*: seq[PlaySprayHazard]

  PlayViewSource* = object
    tick*: uint32
    mode*: GameMode
    epoch*: uint64
    self*: PlaySelf
    aliveTeams*: int
    zone*: Option[PlayZone]
    objectives*: seq[PlayObjective]
    intent*: Option[Intent]
    tracks*: seq[PlayTrack]
    items*: seq[PlayItem]
    aggressors*: seq[PlayAggressor]
    killFeed*: seq[PlayKillFeedRow]
    shouts*: seq[PlayShout]
    hazards*: PlayHazards

  PlayViewModel* = object
    tick*: uint32
    mode*: GameMode
    epoch*: uint64
    self*: PlaySelf
    aliveTeams*: int
    zone*: Option[PlayZone]
    objectives*: seq[PlayObjective]
    intent*: Option[Intent]
    tracks*: seq[PlayTrack]
    items*: seq[PlayItem]
    aggressors*: seq[PlayAggressor]
    killFeed*: seq[PlayKillFeedRow]
    shouts*: seq[PlayShout]
    hazards*: PlayHazards

  PlayContextControl* = enum
    pccInput
    pccPlay

  PlayContextRosterRow* = object
    seat*: int
    team*: Team
    control*: PlayContextControl
    name*: string
      ## The seat's display name (the closed roster's `players[].name`),
      ## capped by rosterDisplayName; empty when the episode has none.
      ## James's ruling 2026-09-02: huddle partners are addressed by name,
      ## so the context carries it — the LobbyChat packet stays seat-indexed
      ## and a policy maps seat -> name from this roster.

  PlayContextSource* = object
    mode*: GameMode
    mapName*: string
    mapWidth*: int
    mapHeight*: int
    roster*: seq[PlayContextRosterRow]
    selfSeat*: int
    selfTeam*: Team
    duoPartner*: Option[int]
    gunRange*: int
    viewInterval*: int

  PlayViewProducer* = ref object
    writer: CanonicalWriter

  PlayContextProducer* = ref object
    writer: CanonicalWriter

  PlayViewSizer = object
    bytes: int
    hazardsFieldCount: int

const
  MaxTrackRows = 32
  MaxItemRows = 32
  MaxAggressorRows = 16
  MaxKillFeedRows = 32
  MaxShoutRows = 32
  MaxGrenadeRows = 8
  MaxBlastCueRows = 4
  MaxSprayRows = 8

proc newPlayViewProducer*(): PlayViewProducer =
  PlayViewProducer(writer: initCanonicalWriter(MaxViewFrameBytes))

proc newPlayContextProducer*(): PlayContextProducer =
  PlayContextProducer(writer: initCanonicalWriter(MaxContextBytes))

proc modeName(mode: GameMode): string {.inline.} =
  case mode
  of gmCtf: "ctf"
  of gmKoth: "koth"
  of gmBr: "br"

proc objectiveName(state: ObjectiveState): string {.inline.} =
  case state
  of osHome: "home"
  of osTaken: "taken"
  of osCaptured: "captured"

proc itemName(kind: PlayItemKind): string {.inline.} =
  case kind
  of pikGrenade: "grenade"
  of pikMedkit: "medkit"
  of pikShield: "shield"
  of pikSpray: "spray"
  of pikBarrier: "barrier"

proc writePoint(w: var CanonicalWriter, point: PlayPoint) =
  w.beginArray()
  w.addInt(int64(point.x))
  w.addInt(int64(point.y))
  w.endArray()

proc writeRect(w: var CanonicalWriter, rect: PlayRect) =
  w.beginArray()
  w.addInt(int64(rect.x))
  w.addInt(int64(rect.y))
  w.addInt(int64(rect.w))
  w.addInt(int64(rect.h))
  w.endArray()

proc distanceSquared(a, b: PlayPoint): int64 =
  let
    dx = int64(a.x) - int64(b.x)
    dy = int64(a.y) - int64(b.y)
  dx * dx + dy * dy

proc validateIntentForView(intent: Intent) =
  var seen: set[PreferTag]
  for tag in intent.combat.prefer:
    if tag in seen:
      raise newException(ValueError,
        "combat.prefer duplicates are rejected by name")
    seen.incl(tag)

proc validateSourceRows(source: PlayViewSource) =
  if source.tracks.len > MaxPlayers:
    raise newException(ValueError, "track source exceeds roster cap")
  if source.intent.isSome:
    validateIntentForView(source.intent.get)
  for track in source.tracks:
    if track.seat < 0 or track.seat >= MaxPlayers:
      raise newException(ValueError, "track seat is out of range")
    if track.aimBrads.isSome and track.aimBrads.get notin 0 .. 255:
      raise newException(ValueError, "track aim_brads is out of range")
  for aggressor in source.aggressors:
    if aggressor.dirBrads notin 0 .. 255:
      raise newException(ValueError, "aggressor dir_brads is out of range")
    if aggressor.seat.isSome and
        aggressor.seat.get notin 0 ..< MaxPlayers:
      raise newException(ValueError, "aggressor seat is out of range")
  for shout in source.shouts:
    if shout.text.len > 10:
      raise newException(ValueError, "shout text exceeds maxLength 10")
  for spray in source.hazards.sprays:
    if spray.tick > source.tick:
      raise newException(ValueError, "spray hazard is from a future tick")
  if source.self.aimBrads notin 0 .. 255:
    raise newException(ValueError, "self aim_brads is out of range")

proc writeJson*(w: var CanonicalWriter, value: PlaySelf, mode: GameMode) =
  w.beginObject()
  w.field("aim_brads", int64(value.aimBrads))
  w.field("alive", value.alive)
  if value.carrying:
    w.field("carrying", true)
  if value.downed:
    w.field("downed", true)
  w.field("hp", int64(value.hp))
  w.field("hp_frac", value.hpFrac)
  if mode != gmBr and value.lives.isSome:
    w.field("lives", int64(value.lives.get))
  w.key("pos")
  w.writePoint(value.pos)
  w.endObject()

proc writeJson*(w: var CanonicalWriter, value: PlayZone) =
  w.beginObject()
  w.key("current")
  w.writeRect(value.current)
  if value.dps != 0:
    w.field("dps", int64(value.dps))
  if value.next.isSome:
    w.key("next")
    w.writeRect(value.next.get)
  w.field("phase", int64(value.phase))
  w.field("ticks_to_shrink", int64(value.ticksToShrink))
  w.endObject()

proc writeJson*(w: var CanonicalWriter, value: PlayObjective) =
  w.beginObject()
  if value.pos.isSome:
    w.key("pos")
    w.writePoint(value.pos.get)
  w.field("state", value.state.objectiveName)
  w.field("team", teamText(value.team))
  w.endObject()

proc writeJson*(w: var CanonicalWriter, value: PlayTrack) =
  w.beginObject()
  if value.aimBrads.isSome:
    w.field("aim_brads", int64(value.aimBrads.get))
  if value.bounty:
    w.field("bounty", true)
  if value.downed:
    w.field("downed", true)
  w.field("fresh_tick", int64(value.freshTick))
  if value.hp.isSome:
    w.field("hp", int64(value.hp.get))
  w.key("pos")
  w.writePoint(value.pos)
  w.field("seat", int64(value.seat))
  w.field("team", teamText(value.team))
  w.endObject()

proc writeJson*(w: var CanonicalWriter, value: PlayItem) =
  w.beginObject()
  w.field("fresh_tick", int64(value.freshTick))
  w.field("kind", value.kind.itemName)
  w.key("pos")
  w.writePoint(value.pos)
  if value.present.isSome:
    w.field("present", value.present.get)
  w.endObject()

proc writeJson*(w: var CanonicalWriter, value: PlayAggressor) =
  w.beginObject()
  w.field("dir_brads", int64(value.dirBrads))
  if value.seat.isSome:
    w.field("seat", int64(value.seat.get))
  w.field("tick", int64(value.tick))
  w.endObject()

proc writeJson*(w: var CanonicalWriter, value: PlayKillFeedRow) =
  w.beginObject()
  w.field("killer_team", teamText(value.killerTeam))
  w.field("tick", int64(value.tick))
  w.field("victim_seat", int64(value.victimSeat))
  w.endObject()

proc writeJson*(w: var CanonicalWriter, value: PlayShout) =
  w.beginObject()
  w.key("pos")
  w.writePoint(value.pos)
  w.field("slot_letter", value.slotLetter)
  w.field("team", teamText(value.team))
  w.field("text", value.text)
  w.field("tick", int64(value.tick))
  w.endObject()

proc writeJson*(w: var CanonicalWriter, value: PlayGrenadeHazard) =
  w.beginObject()
  w.key("pos")
  w.writePoint(value.pos)
  w.key("predicted_blast_pos")
  w.writePoint(value.predictedBlastPos)
  w.field("ticks_to_blast", int64(value.ticksToBlast))
  w.endObject()

proc writeJson*(w: var CanonicalWriter, value: PlayBlastCue) =
  w.beginObject()
  w.key("pos")
  w.writePoint(value.pos)
  w.field("tick", int64(value.tick))
  w.endObject()

proc writeJson*(w: var CanonicalWriter, value: PlayOwnThrow) =
  w.beginObject()
  w.field("blast_radius", int64(value.blastRadius))
  w.field("release_tick", int64(value.releaseTick))
  w.key("target")
  w.writePoint(value.target)
  w.endObject()

proc writeJson*(w: var CanonicalWriter, value: PlaySprayHazard) =
  w.beginObject()
  case value.kind
  of pshVisibleCone:
    w.field("aim_brads", int64(value.aimBrads))
    w.field("attacker_seat", int64(value.attackerSeat))
    w.field("covers_self", value.coversSelf)
    w.field("kind", "visible_cone")
    w.field("max_width_px", int64(value.maxWidthPx))
    w.key("origin")
    w.writePoint(value.origin)
    w.field("reach_px", int64(value.reachPx))
    w.field("tick", int64(value.tick))
  of pshAnonymousImpact:
    w.key("impact_pos")
    w.writePoint(value.impactPos)
    w.field("incoming_dir_brads", int64(value.incomingDirBrads))
    w.field("kind", "anonymous_impact")
    w.field("tick", int64(value.tick))
  w.endObject()

template encodedWith(sizeWriter: var CanonicalWriter, writerBody: untyped): int =
  block:
    sizeWriter.reset()
    writerBody
    let encodedLen {.gensym.} = sizeWriter.bytes.len
    sizeWriter.reset()
    encodedLen

proc encodedSize(value: Intent, sizeWriter: var CanonicalWriter): int =
  encodedWith(sizeWriter):
    sizeWriter.writeIntent(value)

proc encodedSize(value: PlayTrack, sizeWriter: var CanonicalWriter): int =
  encodedWith(sizeWriter):
    sizeWriter.writeJson(value)

proc jsonEncodedSize*(value: PlayTrack): int =
  var sizeWriter = initCanonicalWriter(256)
  value.encodedSize(sizeWriter)

proc encodedSize(value: PlayItem, sizeWriter: var CanonicalWriter): int =
  encodedWith(sizeWriter):
    sizeWriter.writeJson(value)

proc jsonEncodedSize*(value: PlayItem): int =
  var sizeWriter = initCanonicalWriter(256)
  value.encodedSize(sizeWriter)

proc encodedSize(value: PlayAggressor, sizeWriter: var CanonicalWriter): int =
  encodedWith(sizeWriter):
    sizeWriter.writeJson(value)

proc jsonEncodedSize*(value: PlayAggressor): int =
  var sizeWriter = initCanonicalWriter(256)
  value.encodedSize(sizeWriter)

proc encodedSize(value: PlayKillFeedRow, sizeWriter: var CanonicalWriter): int =
  encodedWith(sizeWriter):
    sizeWriter.writeJson(value)

proc jsonEncodedSize*(value: PlayKillFeedRow): int =
  var sizeWriter = initCanonicalWriter(256)
  value.encodedSize(sizeWriter)

proc encodedSize(value: PlayShout, sizeWriter: var CanonicalWriter): int =
  encodedWith(sizeWriter):
    sizeWriter.writeJson(value)

proc jsonEncodedSize*(value: PlayShout): int =
  var sizeWriter = initCanonicalWriter(256)
  value.encodedSize(sizeWriter)

proc encodedSize(value: PlayGrenadeHazard, sizeWriter: var CanonicalWriter): int =
  encodedWith(sizeWriter):
    sizeWriter.writeJson(value)

proc jsonEncodedSize*(value: PlayGrenadeHazard): int =
  var sizeWriter = initCanonicalWriter(256)
  value.encodedSize(sizeWriter)

proc encodedSize(value: PlayBlastCue, sizeWriter: var CanonicalWriter): int =
  encodedWith(sizeWriter):
    sizeWriter.writeJson(value)

proc jsonEncodedSize*(value: PlayBlastCue): int =
  var sizeWriter = initCanonicalWriter(256)
  value.encodedSize(sizeWriter)

proc encodedSize(value: PlayOwnThrow, sizeWriter: var CanonicalWriter): int =
  encodedWith(sizeWriter):
    sizeWriter.writeJson(value)

proc jsonEncodedSize*(value: PlayOwnThrow): int =
  var sizeWriter = initCanonicalWriter(256)
  value.encodedSize(sizeWriter)

proc encodedSize(value: PlaySprayHazard, sizeWriter: var CanonicalWriter): int =
  encodedWith(sizeWriter):
    sizeWriter.writeJson(value)

proc jsonEncodedSize*(value: PlaySprayHazard): int =
  var sizeWriter = initCanonicalWriter(256)
  value.encodedSize(sizeWriter)

proc hasHazards(hazards: PlayHazards): bool =
  hazards.grenades.len > 0 or hazards.blastCues.len > 0 or
    hazards.ownThrow.isSome or hazards.sprays.len > 0

proc writeWorld(w: var CanonicalWriter, model: PlayViewModel) =
  w.beginObject()
  w.field("alive_teams", int64(model.aliveTeams))
  if model.mode == gmKoth:
    w.key("hill")
    w.beginObject()
    w.endObject()
  if model.mode == gmCtf and model.objectives.len > 0:
    w.key("objectives")
    w.beginArray()
    for objective in model.objectives:
      w.writeJson(objective)
    w.endArray()
  if model.mode == gmBr and model.zone.isSome:
    w.key("zone")
    w.writeJson(model.zone.get)
  w.endObject()

proc writeHazards(w: var CanonicalWriter, hazards: PlayHazards) =
  w.beginObject()
  if hazards.blastCues.len > 0:
    w.key("blast_cues")
    w.beginArray()
    for row in hazards.blastCues:
      w.writeJson(row)
    w.endArray()
  if hazards.grenades.len > 0:
    w.key("grenades")
    w.beginArray()
    for row in hazards.grenades:
      w.writeJson(row)
    w.endArray()
  if hazards.ownThrow.isSome:
    w.key("own_throw")
    w.writeJson(hazards.ownThrow.get)
  if hazards.sprays.len > 0:
    w.key("sprays")
    w.beginArray()
    for row in hazards.sprays:
      w.writeJson(row)
    w.endArray()
  w.endObject()

proc writeJson*(w: var CanonicalWriter, model: PlayViewModel) =
  w.beginObject()
  if model.aggressors.len > 0:
    w.key("aggressors")
    w.beginArray()
    for row in model.aggressors:
      w.writeJson(row)
    w.endArray()
  w.fieldUint64("epoch", model.epoch)
  if model.hazards.hasHazards:
    w.key("hazards")
    w.writeHazards(model.hazards)
  if model.intent.isSome:
    w.key("intent")
    w.writeIntent(model.intent.get)
  if model.items.len > 0:
    w.key("items")
    w.beginArray()
    for row in model.items:
      w.writeJson(row)
    w.endArray()
  if model.killFeed.len > 0:
    w.key("kill_feed")
    w.beginArray()
    for row in model.killFeed:
      w.writeJson(row)
    w.endArray()
  w.field("schema", "play_view")
  w.key("self")
  w.writeJson(model.self, model.mode)
  if model.shouts.len > 0:
    w.key("shouts")
    w.beginArray()
    for row in model.shouts:
      w.writeJson(row)
    w.endArray()
  w.field("tick", int64(model.tick))
  if model.tracks.len > 0:
    w.key("tracks")
    w.beginArray()
    for row in model.tracks:
      w.writeJson(row)
    w.endArray()
  w.field("v", 1'i64)
  w.key("world")
  w.writeWorld(model)
  w.endObject()

proc writeJson*(w: var CanonicalWriter, source: PlayContextSource) =
  if source.roster.len < 2 or source.roster.len > MaxPlayers:
    raise newException(ValueError, "play_context roster must have 2..32 rows")
  if (source.mode == gmBr) != source.duoPartner.isSome:
    raise newException(ValueError,
      "play_context duo_partner is present exactly in br mode")
  w.beginObject()
  w.field("gun_range", int64(source.gunRange))
  w.key("map")
  w.beginObject()
  w.field("height", int64(source.mapHeight))
  w.field("name", source.mapName)
  w.field("width", int64(source.mapWidth))
  w.endObject()
  w.field("mode", source.mode.modeName)
  w.key("roster")
  w.beginArray()
  for row in source.roster:
    w.beginObject()
    if row.control == pccPlay:
      w.field("control", "play")
    if row.name.len > 0:
      w.field("name", row.name)
    w.field("seat", int64(row.seat))
    w.field("team", teamText(row.team))
    w.endObject()
  w.endArray()
  w.field("schema", "play_context")
  w.key("self")
  w.beginObject()
  if source.mode == gmBr:
    w.field("duo_partner", int64(source.duoPartner.get))
  w.field("seat", int64(source.selfSeat))
  w.field("team", teamText(source.selfTeam))
  w.endObject()
  w.field("v", 1'i64)
  w.field("view_interval", int64(source.viewInterval))
  w.endObject()

const MaxRosterNameBytes* = 64
  ## Cap on one roster row's display name in the PlayContext. Thirty-two
  ## rows of 64 bytes is 2 KB of a 65536-byte context, so the map-and-roster
  ## size bound (MaxContextBytes) still holds for any platform-supplied name.

proc rosterDisplayName*(name: string): string =
  ## The roster name as the context carries it: unchanged when it fits,
  ## otherwise cut to MaxRosterNameBytes on a UTF-8 boundary so the canonical
  ## writer never sees a torn multibyte scalar.
  if name.len <= MaxRosterNameBytes:
    return name
  var cut = MaxRosterNameBytes
  while cut > 0 and (uint8(name[cut]) and 0xC0'u8) == 0x80'u8:
    dec cut
  name[0 ..< cut]

proc playContextRosterRows*(controls: openArray[SlotControl],
                            teams: openArray[Team],
                            names: openArray[string]): seq[PlayContextRosterRow] =
  ## THE roster the PlayContext carries, in seat order, from the configured
  ## slots' control, team, and display name (`names` may be empty: no names).
  ## Both producers — episode.nim's contextRoster (play_init) and server.nim's
  ## socket 0xB0 — build through here, so the two payloads cannot drift: they
  ## did once (names shipped on the episode side only, round 3641).
  if teams.len != controls.len:
    raise newException(ValueError,
      "roster team/control facts must have the same length")
  if names.len > 0 and names.len != controls.len:
    raise newException(ValueError,
      "roster name/control facts must have the same length")
  for index, control in controls:
    result.add(PlayContextRosterRow(
      seat: index,
      team: teams[index],
      control: if control == scPlay: pccPlay else: pccInput,
      name: if names.len > 0: rosterDisplayName(names[index]) else: ""))

proc jsonEncodedSize*(model: PlayViewModel): int =
  var sizeWriter = initCanonicalWriter(MaxViewFrameBytes)
  encodedWith(sizeWriter):
    sizeWriter.writeJson(model)

proc selectedBase(source: PlayViewSource): PlayViewModel =
  PlayViewModel(tick: source.tick, mode: source.mode, epoch: source.epoch,
    self: source.self, aliveTeams: source.aliveTeams, zone: source.zone,
    objectives: source.objectives)

proc keyColonSize(key: string): int {.inline.} =
  ## All play_view keys are fixed ASCII literals, so the canonical JSON key
  ## token is exactly the raw key plus two quotes and a colon.
  key.len + 3

proc topFieldDelta(key: string, valueSize: int): int {.inline.} =
  ## Base play_view always has fields (`epoch`, `schema`, `self`, `tick`, `v`,
  ## `world`), so each optional top-level field adds one separating comma.
  1 + key.keyColonSize + valueSize

proc objectFieldDelta(key: string, valueSize: int,
                      priorFields: int): int {.inline.} =
  (if priorFields > 0: 1 else: 0) + key.keyColonSize + valueSize

proc fits(sizer: PlayViewSizer, byteCap: int): bool {.inline.} =
  sizer.bytes <= byteCap

proc initSizer(model: PlayViewModel): PlayViewSizer =
  PlayViewSizer(bytes: model.jsonEncodedSize)

proc arrayRowDelta(key: string, currentLen, rowSize: int): int {.inline.} =
  if currentLen == 0:
    topFieldDelta(key, rowSize + 2)
  else:
    rowSize + 1

proc hazardEnvelopeDelta(sizer: PlayViewSizer): int {.inline.} =
  if sizer.hazardsFieldCount == 0:
    topFieldDelta("hazards", 2)
  else:
    0

proc hazardArrayRowDelta(sizer: PlayViewSizer, key: string, currentLen,
                         rowSize: int): int {.inline.} =
  if currentLen == 0:
    sizer.hazardEnvelopeDelta +
      objectFieldDelta(key, rowSize + 2, sizer.hazardsFieldCount)
  else:
    rowSize + 1

proc addTopValueIfFits(sizer: var PlayViewSizer, key: string, valueSize,
                       byteCap: int): bool =
  let delta = topFieldDelta(key, valueSize)
  if sizer.bytes + delta <= byteCap:
    sizer.bytes += delta
    true
  else:
    false

proc addArrayRowIfFits[T](sizer: var PlayViewSizer, target: var seq[T],
                          key: string, row: T, rowSize,
                          byteCap: int): bool =
  let delta = arrayRowDelta(key, target.len, rowSize)
  if sizer.bytes + delta <= byteCap:
    target.add(row)
    sizer.bytes += delta
    true
  else:
    false

proc addHazardArrayRowIfFits[T](sizer: var PlayViewSizer, target: var seq[T],
                                key: string, row: T, rowSize,
                                byteCap: int): bool =
  let wasEmpty = target.len == 0
  let delta = sizer.hazardArrayRowDelta(key, target.len, rowSize)
  if sizer.bytes + delta <= byteCap:
    target.add(row)
    sizer.bytes += delta
    if wasEmpty:
      inc sizer.hazardsFieldCount
    true
  else:
    false

proc addOwnThrowIfFits(sizer: var PlayViewSizer, model: var PlayViewModel,
                       row: PlayOwnThrow, rowSize, byteCap: int): bool =
  let delta = sizer.hazardEnvelopeDelta +
    objectFieldDelta("own_throw", rowSize, sizer.hazardsFieldCount)
  if sizer.bytes + delta <= byteCap:
    model.hazards.ownThrow = some(row)
    sizer.bytes += delta
    inc sizer.hazardsFieldCount
    true
  else:
    false

proc sortedTracks(source: PlayViewSource): seq[PlayTrack] =
  result = source.tracks
  let selfPos = source.self.pos
  result.sort(proc(a, b: PlayTrack): int =
    result = cmp(distanceSquared(selfPos, a.pos), distanceSquared(selfPos, b.pos))
    if result == 0: result = cmp(a.seat, b.seat))
  if result.len > MaxTrackRows:
    result.setLen(MaxTrackRows)

proc sortedItems(source: PlayViewSource): seq[PlayItem] =
  result = source.items
  let selfPos = source.self.pos
  result.sort(proc(a, b: PlayItem): int =
    result = cmp(b.freshTick, a.freshTick)
    if result == 0:
      result = cmp(distanceSquared(selfPos, a.pos), distanceSquared(selfPos, b.pos))
    if result == 0: result = cmp(ord(a.kind), ord(b.kind))
    if result == 0: result = cmp(a.eventId, b.eventId))
  if result.len > MaxItemRows:
    result.setLen(MaxItemRows)

proc sortedAggressors(source: PlayViewSource): seq[PlayAggressor] =
  result = source.aggressors
  result.sort(proc(a, b: PlayAggressor): int =
    result = cmp(b.tick, a.tick)
    if result == 0: result = cmp(a.eventId, b.eventId))
  if result.len > MaxAggressorRows:
    result.setLen(MaxAggressorRows)

proc sortedKillFeed(source: PlayViewSource): seq[PlayKillFeedRow] =
  result = source.killFeed
  result.sort(proc(a, b: PlayKillFeedRow): int =
    result = cmp(b.tick, a.tick)
    if result == 0: result = cmp(a.eventId, b.eventId))
  if result.len > MaxKillFeedRows:
    result.setLen(MaxKillFeedRows)

proc sortedShouts(source: PlayViewSource): seq[PlayShout] =
  result = source.shouts
  let selfPos = source.self.pos
  result.sort(proc(a, b: PlayShout): int =
    result = cmp(b.tick, a.tick)
    if result == 0:
      result = cmp(distanceSquared(selfPos, a.pos), distanceSquared(selfPos, b.pos))
    if result == 0: result = cmp(teamText(a.team), teamText(b.team))
    if result == 0: result = cmp(a.slotLetter, b.slotLetter)
    if result == 0: result = cmp(a.eventId, b.eventId))
  if result.len > MaxShoutRows:
    result.setLen(MaxShoutRows)

proc sortedGrenades(source: PlayViewSource): seq[PlayGrenadeHazard] =
  result = source.hazards.grenades
  let selfPos = source.self.pos
  result.sort(proc(a, b: PlayGrenadeHazard): int =
    result = cmp(b.coversSelf, a.coversSelf)
    if result == 0: result = cmp(a.ticksToBlast, b.ticksToBlast)
    if result == 0:
      result = cmp(distanceSquared(selfPos, a.predictedBlastPos),
        distanceSquared(selfPos, b.predictedBlastPos))
    if result == 0: result = cmp(a.eventId, b.eventId))
  if result.len > MaxGrenadeRows:
    result.setLen(MaxGrenadeRows)

proc sortedBlastCues(source: PlayViewSource): seq[PlayBlastCue] =
  result = source.hazards.blastCues
  let selfPos = source.self.pos
  result.sort(proc(a, b: PlayBlastCue): int =
    result = cmp(b.coversSelf, a.coversSelf)
    if result == 0: result = cmp(b.tick, a.tick)
    if result == 0:
      result = cmp(distanceSquared(selfPos, a.pos), distanceSquared(selfPos, b.pos))
    if result == 0: result = cmp(a.eventId, b.eventId))
  if result.len > MaxBlastCueRows:
    result.setLen(MaxBlastCueRows)

proc sortedSprays(source: PlayViewSource): seq[PlaySprayHazard] =
  result = source.hazards.sprays
  let selfPos = source.self.pos
  proc anchor(spray: PlaySprayHazard): PlayPoint =
    case spray.kind
    of pshVisibleCone: spray.origin
    of pshAnonymousImpact: spray.impactPos
  result.sort(proc(a, b: PlaySprayHazard): int =
    result = cmp(b.coversSelf, a.coversSelf)
    if result == 0: result = cmp(b.tick, a.tick)
    if result == 0:
      result = cmp(distanceSquared(selfPos, a.anchor),
        distanceSquared(selfPos, b.anchor))
    if result == 0: result = cmp(a.eventId, b.eventId))
  if result.len > MaxSprayRows:
    result.setLen(MaxSprayRows)

proc selectPlayViewWithSize*(source: PlayViewSource,
                             byteCap: int = MaxViewFrameBytes):
    tuple[model: PlayViewModel, encodedSize: int] =
  ## Returns the typed view model whose canonical JSON encoding is at or below
  ## `byteCap`. If the required skeleton cannot fit, the cap is impossible and
  ## this raises instead of returning malformed or truncated JSON.
  if byteCap <= 0:
    raise newException(ValueError, "play_view byte cap must be positive")
  source.validateSourceRows()
  result.model = source.selectedBase()
  var sizer = result.model.initSizer()
  if not sizer.fits(byteCap):
    raise newException(ValueError,
      "play_view required skeleton exceeds byte cap")

  var sizeWriter = initCanonicalWriter(256)
  if source.intent.isSome:
    let intentSize = source.intent.get.encodedSize(sizeWriter)
    if not sizer.addTopValueIfFits("intent", intentSize, byteCap):
      raise newException(ValueError,
        "play_view standing intent exceeds byte cap")
    result.model.intent = source.intent

  for row in source.sortedGrenades:
    if not sizer.addHazardArrayRowIfFits(result.model.hazards.grenades,
        "grenades", row, row.encodedSize(sizeWriter), byteCap):
      break
  for row in source.sortedBlastCues:
    if not sizer.addHazardArrayRowIfFits(result.model.hazards.blastCues,
        "blast_cues", row, row.encodedSize(sizeWriter), byteCap):
      break
  if source.hazards.ownThrow.isSome:
    let row = source.hazards.ownThrow.get
    discard sizer.addOwnThrowIfFits(result.model, row,
      row.encodedSize(sizeWriter), byteCap)
  for row in source.sortedSprays:
    if not sizer.addHazardArrayRowIfFits(result.model.hazards.sprays,
        "sprays", row, row.encodedSize(sizeWriter), byteCap):
      break

  for row in source.sortedAggressors:
    if not sizer.addArrayRowIfFits(result.model.aggressors, "aggressors",
        row, row.encodedSize(sizeWriter), byteCap):
      break
  for row in source.sortedTracks:
    if not sizer.addArrayRowIfFits(result.model.tracks, "tracks", row,
        row.encodedSize(sizeWriter), byteCap):
      break
  for row in source.sortedItems:
    if not sizer.addArrayRowIfFits(result.model.items, "items", row,
        row.encodedSize(sizeWriter), byteCap):
      break
  for row in source.sortedKillFeed:
    if not sizer.addArrayRowIfFits(result.model.killFeed, "kill_feed", row,
        row.encodedSize(sizeWriter), byteCap):
      break
  for row in source.sortedShouts:
    if not sizer.addArrayRowIfFits(result.model.shouts, "shouts", row,
        row.encodedSize(sizeWriter), byteCap):
      break
  result.encodedSize = sizer.bytes

proc selectPlayView*(source: PlayViewSource,
                     byteCap: int = MaxViewFrameBytes): PlayViewModel =
  source.selectPlayViewWithSize(byteCap).model

proc toPlayItemKind(kind: BodyItemKind): PlayItemKind =
  case kind
  of bikGrenade: pikGrenade
  of bikMedkit: pikMedkit
  of bikShield: pikShield
  of bikSpray: pikSpray
  of bikBarrier: pikBarrier

proc toPlaySprayHazard(hazard: BodySprayHazard): PlaySprayHazard =
  case hazard.kind
  of bshVisibleCone:
    PlaySprayHazard(kind: pshVisibleCone, eventId: hazard.eventId,
      coversSelf: hazard.coversSelf, tick: hazard.tick,
      attackerSeat: hazard.attackerSeat, origin: hazard.origin,
      aimBrads: hazard.aimBrads, reachPx: hazard.reachPx,
      maxWidthPx: hazard.maxWidthPx)
  of bshAnonymousImpact:
    PlaySprayHazard(kind: pshAnonymousImpact, eventId: hazard.eventId,
      coversSelf: hazard.coversSelf, tick: hazard.tick,
      impactPos: hazard.impactPos,
      incomingDirBrads: hazard.incomingDirBrads)

proc playViewSourceFromBody*(body: SeatBody, tick: uint32, mode: GameMode,
                             aliveTeams: int, zone = none(PlayZone),
                             objectives: openArray[PlayObjective] = [],
                             includeStandingIntent = true): PlayViewSource =
  ## Convenience adapter from body-retained belief to the frozen view row
  ## shapes. Callers decide whether the standing order has been installed;
  ## before the first standing order, pass `includeStandingIntent = false` so
  ## `intent` is omitted.
  result.tick = tick
  result.mode = mode
  result.epoch = body.effectiveEpoch
  result.self = PlaySelf(pos: body.selfState.pos, hp: body.selfState.hp,
    hpFrac: body.selfState.hpFrac, aimBrads: body.selfState.aimBrads,
    alive: body.selfState.alive, carrying: body.selfState.carrying,
    lives: body.selfState.lives, downed: body.selfState.downed)
  result.aliveTeams = aliveTeams
  result.zone = zone
  result.objectives = @objectives
  if includeStandingIntent:
    result.intent = some(body.standingIntent)
  for seat in 0 ..< MaxPlayers:
    if body.tracks[seat].isSome:
      let track = body.tracks[seat].get
      result.tracks.add(PlayTrack(seat: seat, team: track.team,
        pos: track.pos, aimBrads: track.aimBrads,
        hp: track.hpKnown, freshTick: track.freshTick,
        bounty: track.freshTick == tick and track.veteranMarker,
        downed: track.downed))
  # The duo partner's row is a DELIBERATE GRANT (play_view.schema.json §world
  # tracks comment, §5.2): full trust, not fog-limited like the loop above.
  # `body.tracks[]` never carries the partner (same-team seats are excluded
  # from `visibleTracks` at the seam, src/ctf/server.nim
  # firstLightBodyInputs), so this is the only place a partner row can come
  # from. `downed` is why this row exists for LOOT(s2): a policy cannot
  # revive a partner it cannot see is down.
  let partner = body.partnerTelemetry()
  if partner.isSome:
    let grant = partner.get
    result.tracks.add(PlayTrack(seat: grant.seat.int, team: grant.team,
      pos: grant.pos, aimBrads: some(grant.aimBrads), hp: none(int),
      freshTick: tick, bounty: false, downed: grant.downed))
  for item in body.items:
    result.items.add(PlayItem(eventId: item.eventId,
      kind: item.kind.toPlayItemKind, pos: item.pos,
      present: some(item.present), freshTick: item.freshTick))
  for event in body.aggressorEvents:
    result.aggressors.add(PlayAggressor(eventId: event.eventId,
      tick: event.tick, dirBrads: event.dirBrads, seat: event.seat))
  for event in body.killFeed:
    result.killFeed.add(PlayKillFeedRow(eventId: event.eventId,
      tick: event.tick, killerTeam: event.killerTeam,
      victimSeat: event.victimSeat))
  for event in body.shouts:
    result.shouts.add(PlayShout(eventId: event.eventId, team: event.team,
      slotLetter: event.slotLetter, text: event.text, pos: event.pos,
      tick: event.tick))
  for hazard in body.hazards.grenades:
    result.hazards.grenades.add(PlayGrenadeHazard(
      eventId: hazard.eventId, coversSelf: hazard.coversSelf,
      pos: hazard.pos, predictedBlastPos: hazard.predictedBlastPos,
      ticksToBlast: hazard.ticksToBlast))
  for hazard in body.hazards.blastCues:
    result.hazards.blastCues.add(PlayBlastCue(eventId: hazard.eventId,
      coversSelf: hazard.coversSelf, pos: hazard.pos, tick: hazard.tick))
  if body.hazards.ownThrow.isSome:
    let ownThrow = body.hazards.ownThrow.get
    result.hazards.ownThrow = some(PlayOwnThrow(target: ownThrow.target,
      releaseTick: ownThrow.releaseTick, blastRadius: ownThrow.blastRadius))
  for hazard in body.hazards.sprays:
    result.hazards.sprays.add(hazard.toPlaySprayHazard)

proc buildPlayView*(producer: PlayViewProducer, source: PlayViewSource,
                    byteCap: int = MaxViewFrameBytes): string =
  let model = selectPlayView(source, byteCap)
  producer.writer.reset()
  producer.writer.writeJson(model)
  result = producer.writer.take()
  assert result.len <= byteCap

proc buildPlayView*(source: PlayViewSource,
                    byteCap: int = MaxViewFrameBytes): string =
  newPlayViewProducer().buildPlayView(source, byteCap)

proc buildPlayContext*(producer: PlayContextProducer,
                       source: PlayContextSource,
                       byteCap: int = MaxContextBytes): string =
  if byteCap <= 0:
    raise newException(ValueError, "play_context byte cap must be positive")
  producer.writer.reset()
  producer.writer.writeJson(source)
  result = producer.writer.take()
  if result.len > byteCap:
    raise newException(ValueError, "play_context exceeds byte cap")

proc buildPlayContext*(source: PlayContextSource,
                       byteCap: int = MaxContextBytes): string =
  newPlayContextProducer().buildPlayContext(source, byteCap)
