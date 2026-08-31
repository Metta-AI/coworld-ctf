## Benchmark for src/shell/canonical_fast.nim against the two ratified
## engineering acceptances the P0 measurements set (design doc §10 /
## Appendix H, 2026-08-30):
##
## - P1: 32-seat view build+encode ≤ 2.5 ms. The encode half is measured
##   here as the play_view golden encoded 32 times — three ways: the
##   std/json tree baseline (`canonicalJson`, what P0 measured inside its
##   5.77 ms), the writer's tree-walk bridge (`addJsonNode`), and the
##   engine fast path (direct streaming emit, no tree).
## - P3: per-emit validation ≤ 15 µs. The parse half is measured as the
##   intent golden — std/json `parseJson` baseline (the ~62 µs spike's
##   dominant cost), the whole-document canonicality skim
##   (`validateCanonical`), and a schema-shaped typed walk (the pattern
##   lane C's emit validator drives).
##
## The direct-emit and shaped-walk paths are verified byte-exact /
## value-exact against the goldens before any timing runs.
##
## Usage: nim c -r -d:release tools/benchmark_canonical_fast.nim
## (run from the repo root; fixtures are read from tests/fixtures/shell/)

import std/[json, monotimes, os, strformat, strutils, times]
import ../src/shell/canonical
import ../src/shell/canonical_fast

const
  FixtureDir = "tests" / "fixtures" / "shell"
  Seats = 32
  EncodeIters = 500      # iterations of the 32-frame batch
  ParseIters = 20000

var sink: int   # accumulated so no measured body can be optimized away

template bench(label: string, iters: int, body: untyped): float =
  block:
    for _ in 0 ..< 3: body          # warm-up
    let t0 = getMonoTime()
    for _ in 0 ..< iters: body
    let perIter = float((getMonoTime() - t0).inNanoseconds) /
                  1000.0 / float(iters)
    echo "  ", alignLeft(label, 52),
      align(formatFloat(perIter, ffDecimal, 2), 10), " us"
    perIter

# ---------------------------------------------------------------------------
# The play_view golden as a native fixture (what the engine holds before
# encoding), extracted at startup so every emitted value is a runtime read.
# ---------------------------------------------------------------------------

type
  Vec2 = array[2, int64]
  Rect = array[4, int64]
  TrackFix = object
    aimBrads: int64
    hasAim: bool
    bounty: bool
    freshTick: int64
    hp: int64
    hasHp: bool
    pos: Vec2
    seat: int64
    team: string

  PlayViewFix = object
    aggDir, aggTick: int64
    epoch: uint64
    grenPos, grenPred: Vec2
    grenTicks: int64
    throwRadius, throwRelease: int64
    throwTarget: Vec2
    sprayImpact: Vec2
    sprayDir: int64
    sprayKind: string
    sprayTick: int64
    intentArrive: float
    intentKind: string
    intentPoint: Vec2
    itemFresh: int64
    itemKind: string
    itemPos: Vec2
    itemPresent: bool
    killTeam: string
    killTick, killSeat: int64
    selfAim: int64
    selfAlive: bool
    selfHp: int64
    selfHpFrac: float
    selfPos: Vec2
    shoutPos: Vec2
    shoutLetter, shoutTeam, shoutText: string
    shoutTick: int64
    tick: int64
    tracks: seq[TrackFix]
    aliveTeams: int64
    zoneCurrent, zoneNext: Rect
    zoneDps, zonePhase, zoneShrink: int64

proc vec2(node: JsonNode): Vec2 =
  [node[0].getBiggestInt(), node[1].getBiggestInt()]
proc rect(node: JsonNode): Rect =
  for i in 0 .. 3: result[i] = node[i].getBiggestInt()

proc loadFix(node: JsonNode): PlayViewFix =
  let agg = node["aggressors"][0]
  result.aggDir = agg["dir_brads"].getInt()
  result.aggTick = agg["tick"].getInt()
  result.epoch = parseUint64Key(node["epoch"])
  let gren = node["hazards"]["grenades"][0]
  result.grenPos = vec2(gren["pos"])
  result.grenPred = vec2(gren["predicted_blast_pos"])
  result.grenTicks = gren["ticks_to_blast"].getInt()
  let ownThrow = node["hazards"]["own_throw"]
  result.throwRadius = ownThrow["blast_radius"].getInt()
  result.throwRelease = ownThrow["release_tick"].getInt()
  result.throwTarget = vec2(ownThrow["target"])
  let spray = node["hazards"]["sprays"][0]
  result.sprayImpact = vec2(spray["impact_pos"])
  result.sprayDir = spray["incoming_dir_brads"].getInt()
  result.sprayKind = spray["kind"].getStr()
  result.sprayTick = spray["tick"].getInt()
  let intent = node["intent"]
  result.intentArrive = intent["arrive_radius"].getFloat()
  result.intentKind = intent["kind"].getStr()
  result.intentPoint = vec2(intent["point"])
  let item = node["items"][0]
  result.itemFresh = item["fresh_tick"].getInt()
  result.itemKind = item["kind"].getStr()
  result.itemPos = vec2(item["pos"])
  result.itemPresent = item["present"].getBool()
  let kill = node["kill_feed"][0]
  result.killTeam = kill["killer_team"].getStr()
  result.killTick = kill["tick"].getInt()
  result.killSeat = kill["victim_seat"].getInt()
  let selfNode = node["self"]
  result.selfAim = selfNode["aim_brads"].getInt()
  result.selfAlive = selfNode["alive"].getBool()
  result.selfHp = selfNode["hp"].getInt()
  result.selfHpFrac = selfNode["hp_frac"].getFloat()
  result.selfPos = vec2(selfNode["pos"])
  let shout = node["shouts"][0]
  result.shoutPos = vec2(shout["pos"])
  result.shoutLetter = shout["slot_letter"].getStr()
  result.shoutTeam = shout["team"].getStr()
  result.shoutText = shout["text"].getStr()
  result.shoutTick = shout["tick"].getInt()
  result.tick = node["tick"].getInt()
  for trackNode in node["tracks"]:
    var track = TrackFix(
      freshTick: trackNode["fresh_tick"].getInt(),
      pos: vec2(trackNode["pos"]),
      seat: trackNode["seat"].getInt(),
      team: trackNode["team"].getStr())
    if trackNode.hasKey("aim_brads"):
      track.hasAim = true
      track.aimBrads = trackNode["aim_brads"].getInt()
    if trackNode.hasKey("hp"):
      track.hasHp = true
      track.hp = trackNode["hp"].getInt()
    track.bounty = trackNode.hasKey("bounty") and
      trackNode["bounty"].getBool()
    result.tracks.add(track)
  let world = node["world"]
  result.aliveTeams = world["alive_teams"].getInt()
  let zone = world["zone"]
  result.zoneCurrent = rect(zone["current"])
  result.zoneDps = zone["dps"].getInt()
  result.zoneNext = rect(zone["next"])
  result.zonePhase = zone["phase"].getInt()
  result.zoneShrink = zone["ticks_to_shrink"].getInt()

proc addVec2(w: var CanonicalWriter, v: Vec2) =
  w.beginArray()
  w.addInt(v[0])
  w.addInt(v[1])
  w.endArray()

proc addRect(w: var CanonicalWriter, v: Rect) =
  w.beginArray()
  for x in v: w.addInt(x)
  w.endArray()

proc emitPlayView(w: var CanonicalWriter, f: PlayViewFix) =
  ## The engine fast path: fields streamed directly in sorted-key order,
  ## no tree anywhere. Structure mirrors the play_view golden.
  w.beginObject()
  w.key("aggressors")
  w.beginArray()
  w.beginObject()
  w.field("dir_brads", f.aggDir)
  w.field("tick", f.aggTick)
  w.endObject()
  w.endArray()
  w.fieldUint64("epoch", f.epoch)
  w.key("hazards")
  w.beginObject()
  w.key("grenades")
  w.beginArray()
  w.beginObject()
  w.key("pos"); w.addVec2(f.grenPos)
  w.key("predicted_blast_pos"); w.addVec2(f.grenPred)
  w.field("ticks_to_blast", f.grenTicks)
  w.endObject()
  w.endArray()
  w.key("own_throw")
  w.beginObject()
  w.field("blast_radius", f.throwRadius)
  w.field("release_tick", f.throwRelease)
  w.key("target"); w.addVec2(f.throwTarget)
  w.endObject()
  w.key("sprays")
  w.beginArray()
  w.beginObject()
  w.key("impact_pos"); w.addVec2(f.sprayImpact)
  w.field("incoming_dir_brads", f.sprayDir)
  w.field("kind", f.sprayKind)
  w.field("tick", f.sprayTick)
  w.endObject()
  w.endArray()
  w.endObject()
  w.key("intent")
  w.beginObject()
  w.field("arrive_radius", f.intentArrive)
  w.field("kind", f.intentKind)
  w.key("point"); w.addVec2(f.intentPoint)
  w.field("schema", "intent")
  w.field("v", 1'i64)
  w.endObject()
  w.key("items")
  w.beginArray()
  w.beginObject()
  w.field("fresh_tick", f.itemFresh)
  w.field("kind", f.itemKind)
  w.key("pos"); w.addVec2(f.itemPos)
  w.field("present", f.itemPresent)
  w.endObject()
  w.endArray()
  w.key("kill_feed")
  w.beginArray()
  w.beginObject()
  w.field("killer_team", f.killTeam)
  w.field("tick", f.killTick)
  w.field("victim_seat", f.killSeat)
  w.endObject()
  w.endArray()
  w.field("schema", "play_view")
  w.key("self")
  w.beginObject()
  w.field("aim_brads", f.selfAim)
  w.field("alive", f.selfAlive)
  w.field("hp", f.selfHp)
  w.field("hp_frac", f.selfHpFrac)
  w.key("pos"); w.addVec2(f.selfPos)
  w.endObject()
  w.key("shouts")
  w.beginArray()
  w.beginObject()
  w.key("pos"); w.addVec2(f.shoutPos)
  w.field("slot_letter", f.shoutLetter)
  w.field("team", f.shoutTeam)
  w.field("text", f.shoutText)
  w.field("tick", f.shoutTick)
  w.endObject()
  w.endArray()
  w.field("tick", f.tick)
  w.key("tracks")
  w.beginArray()
  for track in f.tracks:
    w.beginObject()
    if track.hasAim: w.field("aim_brads", track.aimBrads)
    if track.bounty: w.field("bounty", true)
    w.field("fresh_tick", track.freshTick)
    if track.hasHp: w.field("hp", track.hp)
    w.key("pos"); w.addVec2(track.pos)
    w.field("seat", track.seat)
    w.field("team", track.team)
    w.endObject()
  w.endArray()
  w.field("v", 1'i64)
  w.key("world")
  w.beginObject()
  w.field("alive_teams", f.aliveTeams)
  w.key("zone")
  w.beginObject()
  w.key("current"); w.addRect(f.zoneCurrent)
  w.field("dps", f.zoneDps)
  w.key("next"); w.addRect(f.zoneNext)
  w.field("phase", f.zonePhase)
  w.field("ticks_to_shrink", f.zoneShrink)
  w.endObject()
  w.endObject()
  w.endObject()

# ---------------------------------------------------------------------------
# The intent golden's shaped validation (the lane-C driving pattern).
# ---------------------------------------------------------------------------

proc validateIntentShaped(bytes: string) =
  ## A basic emit-validation proxy: typed reads and range checks on the
  ## intent's top-level fields, canonicality-checked skips elsewhere
  ## (the combat subtree in the golden). Lane C's real validator walks
  ## the same reader API with the full schema table.
  var r = initCanonicalReader(bytes)
  r.enterObject()
  var key, text: string
  var sawSchema, sawV, sawArrive, sawPoint = false
  var kind = ""
  while r.nextKey(key):
    case key
    of "arrive_radius":
      if r.readNumber() < 0.0:
        raise newException(CanonicalError, "arrive_radius out of range")
      sawArrive = true
    of "kind":
      kind = r.readString()
      if kind notin ["navigate_to", "hold"]:
        raise newException(CanonicalError, "unknown intent kind")
    of "schema":
      if r.readString() != "intent":
        raise newException(CanonicalError, "wrong schema tag")
      sawSchema = true
    of "v":
      if r.readInt() != 1:
        raise newException(CanonicalError, "wrong version")
      sawV = true
    of "point":
      r.enterArray()
      var coords = 0
      while r.nextElement():
        discard r.readInt()
        inc coords
      if coords != 2:
        raise newException(CanonicalError, "point needs 2 coordinates")
      sawPoint = true
    of "micro":
      r.enterArray()
      while r.nextElement():
        r.readStringInto(text)
        if text notin ["formation_bias", "peek_duck", "separation",
                       "steal_rush_exempt"]:
          raise newException(CanonicalError, "unknown micro flag")
    of "idle_aim_center_brads":
      let brads = r.readInt()
      if brads < 0 or brads > 255:
        raise newException(CanonicalError, "brads out of range")
    of "moving_goal", "clamp_to_endzone", "suppress_fire_freeze":
      discard r.readBool()
    of "profile":
      if r.readString() notin ["default", "carrier", "hunter"]:
        raise newException(CanonicalError, "unknown profile")
    of "reason":
      r.readStringInto(text)
      if text.len > 64:
        raise newException(CanonicalError, "reason over its byte cap")
    of "combat":
      r.skipValue()
    else:
      raise newException(CanonicalError, "unknown field " & key)
  r.finish()
  if not (sawSchema and sawV and kind.len > 0 and sawArrive):
    raise newException(CanonicalError, "missing required field")
  if (kind == "navigate_to") != sawPoint:
    raise newException(CanonicalError, "point/kind arm violation")

# ---------------------------------------------------------------------------

proc main() =
  let playViewBytes = readFile(FixtureDir / "play_view.golden.json")
  let intentBytes = readFile(FixtureDir / "intent.golden.json")
  let playViewNode = parseJson(playViewBytes)
  let fix = loadFix(playViewNode)

  # Correctness gates before any timing.
  var w = initCanonicalWriter(playViewBytes.len)
  w.addJsonNode(playViewNode)
  doAssert w.take() == playViewBytes, "addJsonNode diverged from the golden"
  w.reset()
  emitPlayView(w, fix)
  doAssert w.take() == playViewBytes, "direct emit diverged from the golden"
  validateIntentShaped(intentBytes)

  echo &"canonical_fast benchmark — {Seats}-frame view encode " &
    &"({playViewBytes.len} B/frame), intent parse ({intentBytes.len} B)"

  echo "encode play_view x32 (P1 framing: <=2500 us per 32-seat encode):"
  discard bench("canonicalJson from a JsonNode tree (baseline)",
      EncodeIters):
    for _ in 0 ..< Seats:
      sink += canonicalJson(playViewNode).len
  discard bench("writer.addJsonNode (tree-walk bridge)", EncodeIters):
    for _ in 0 ..< Seats:
      w.reset()
      w.addJsonNode(playViewNode)
      sink += w.bytes.len
  let directUs = bench("writer direct streaming emit (engine fast path)",
      EncodeIters):
    for _ in 0 ..< Seats:
      w.reset()
      emitPlayView(w, fix)
      sink += w.bytes.len

  echo "parse+validate intent (P3 framing: <=15 us per emit):"
  discard bench("std/json parseJson (baseline, the tree cost)",
      ParseIters):
    sink += parseJson(intentBytes).len
  discard bench("validateCanonical (whole-document skim)", ParseIters):
    validateCanonical(intentBytes)
    sink += 1
  let shapedUs = bench("shaped walk: typed reads + range checks",
      ParseIters):
    validateIntentShaped(intentBytes)
    sink += 1

  # Scaling check at the emit cap: a synthetic canonical payload right
  # under MaxEmitBytes (4096), skim-validated — the adversarial size a
  # single emit can reach.
  var big = initCanonicalWriter(4096)
  big.beginArray()
  var n = 0
  while big.bytes.len < 4096 - 64:
    big.beginObject()
    big.field("flag", (n mod 2) == 0)
    big.field("name", "entry_" & $n)
    big.field("value", int64(n) * 977)
    big.field("weight", float(n) + 0.5)
    big.endObject()
    inc n
  big.endArray()
  let bigBytes = big.take()
  validateCanonical(bigBytes)
  discard bench("validateCanonical of a " & $bigBytes.len &
      " B payload (MaxEmitBytes scale)", ParseIters):
    validateCanonical(bigBytes)
    sink += 1

  echo ""
  echo &"P1 encode: {directUs:.1f} us per 32 frames vs 2500 us budget — " &
    (if directUs <= 2500.0: "PASS" else: "FAIL")
  echo &"P3 validate: {shapedUs:.2f} us per emit vs 15 us budget — " &
    (if shapedUs <= 15.0: "PASS" else: "FAIL")
  echo &"(sink {sink})"

main()
