## PLACEHOLDER for `src/ctf/policy_page.nim` — the real one-page scoring VM,
## owned by a different agent ("build-vm") on a different branch. It does
## not exist on this branch (b800d17) yet, so this file stands in behind
## the SAME interface build-vm described mid-build:
##
##   type PathKind* = enum pkNumber, pkBool
##   proc newPathRegistry*(paths: openArray[(string, PathKind)]): PathRegistry
##   const DefaultPaths* = [("self.hp_frac", pkNumber), ("intent.is_enemy", pkBool), ...]
#   let DefaultPathRegistry* = newPathRegistry(DefaultPaths)
#   IntentContext.resolveNumber/resolveBool: opaque string -> float/bool
#     closures the CALLER supplies, one per candidate row being scored.
##
# `DefaultPaths` below is the actual answer to build-vm's ask: every path
# this bot's resolver can ACTUALLY compute today from label-string
# perception (see onepage.nim: numberPath/boolPath/intentTagBool), and
# NOTHING ELSE — no aspirational fields. It is reported verbatim in the
# handoff message so build-vm can drop it into the real
# src/ctf/policy_page.DefaultPaths.
##
# Swap plan: once src/ctf/policy_page.nim lands, delete everything below
# `DefaultPaths` in this file and replace this whole module's body with
# `import ctf/policy_page` (re-exported under the same names onepage.nim
# already calls: PolicyPage, IntentContext, compilePage, selectIntent).
# onepage.nim's own call sites should not need to change at all.
##
# STRUCTURAL note per build-vm's ask: this registry is not a hand-
# maintained list independent of the resolver's dispatch — `numberPath`/
# `boolPath`/`intentTagBool` in onepage.nim are `case` statements over the
# exact path STRINGS listed in `DefaultPaths` below, so a path declared
# here without a resolver arm is a compile-time-checkable gap on OUR side
# (grep the string), not a silent one. A closed `PathId` enum with an
# exhaustive `case` would make the Nim compiler enforce this instead of a
# grep; left as a follow-up since this file is disposable once the real
# VM lands.

import std/json

type
  PathKind* = enum
    pkNumber, pkBool

  IntentContext* = object
    resolveNumber*: proc(path: string): float {.closure.}
    resolveBool*: proc(path: string): bool {.closure.}

const DefaultPaths* = [
  (path: "self.hp_frac", kind: pkNumber),
    # bot.hp / MaxHp. Read from the "lives <hp>hp x<lives>" HUD text.
  (path: "partner.alive", kind: pkBool),
    # bot.mates.len > 0 — our one BR-duo partner has a live track.
  (path: "partner.dist", kind: pkNumber),
    # px to the partner's last known position; -1 if never seen this life.
  (path: "partner.in_combat", kind: pkBool),
    # any tracked enemy within ThreatRange (200px) of the partner's last
    # known position.
  (path: "world.enemy_count", kind: pkNumber),
    # count of currently-remembered enemy tracks (TrackTtl ~5s memory).
  (path: "world.nearest_enemy_dist", kind: pkNumber),
    # px to the nearest remembered enemy; -1 if none.
  (path: "world.weakest_enemy_hp", kind: pkNumber),
    # lowest hp among enemies whose hp has EVER been read (the overhead
    # pip bar is fog-gated with its player); -1 if none read yet.
  (path: "world.in_zone", kind: pkBool),
    # whether we are inside the CURRENT shrink-zone rect right now.
  (path: "world.zone_dist", kind: pkNumber),
    # px from our position to the nearest edge of the current zone rect;
    # 0 while inside (or before any zone marker has ever arrived).
  (path: "world.medkit_dist", kind: pkNumber),
    # px to the nearest medkit believed stocked right now; -1 if none known.
  (path: "world.item_dist", kind: pkNumber),
    # px to the nearest non-medkit pickup (shield/spray can/grenade/
    # barrier, one bucket) believed stocked right now; -1 if none known.
  (path: "intent.is_enemy", kind: pkBool),
    # tag: true for EngageNearestEnemy / EngageWeakestEnemy / SupportPartner
    # — rows that target an enemy directly.
  (path: "intent.is_peel", kind: pkBool),
    # tag: true for Disengage / AvoidContact — the "put distance between us
    # and a threat" rows. NAMING COLLISION FLAGGED BY build-vm: this is BR
    # "isolate from partner/fight", unrelated to the Glory PEEL deed.
  (path: "intent.is_recover", kind: pkBool),
    # tag: true only for SeekMedkit.
  (path: "intent.is_item", kind: pkBool),
    # tag: true only for SeekItem.
  (path: "intent.is_partner", kind: pkBool),
    # tag: true for RegroupWithPartner / SupportPartner.
  (path: "intent.is_zone", kind: pkBool),
    # tag: true for RotateToZone / HoldCoverInPlace / AvoidContact.
]

proc knownPathKind(path: string): int =
  ## Index into DefaultPaths, or -1. (`newPathRegistry`'s real job; this is
  ## the whole registry a placeholder this small needs.)
  for i in 0 ..< DefaultPaths.len:
    if DefaultPaths[i].path == path:
      return i
  -1

type
  PageRow = object
    bias: float
    weight: seq[tuple[path: string, w: float]]

  PolicyPage* = object
    row*: seq[tuple[name: string, r: PageRow]]
    raw*: string

proc rowFor(page: PolicyPage, name: string): PageRow =
  for (n, r) in page.row:
    if n == name:
      return r
  PageRow(bias: 0.0, weight: @[])

proc compilePage*(raw: string, candidates: openArray[string]): PolicyPage =
  ## PLACEHOLDER for the real VM's `compile`/`validate`. Schema:
  ##   {"rows": {"<candidate name>": {"bias": <n>, "weights": {"<path>": <n>}}}}
  ## Validates every row key against `candidates` and every weight key
  ## against `DefaultPaths` and FAILS LOUD — raises ValueError naming the
  ## exact bad key — on anything unrecognized. Never silently scores zero
  ## for a typo'd intent or path name.
  var j: JsonNode
  try:
    j = parseJson(raw)
  except Exception as e:
    raise newException(ValueError, "policy page is not valid JSON: " & e.msg)
  if j.kind != JObject or not j.hasKey("rows") or j["rows"].kind != JObject:
    raise newException(ValueError,
      "policy page must be a JSON object with a top-level \"rows\" object")
  result.raw = raw
  for key, rowJ in j["rows"].pairs:
    if key notin candidates:
      raise newException(ValueError, "policy page rows: unknown intent \"" & key & "\"")
    if rowJ.kind != JObject:
      raise newException(ValueError, "policy page rows[\"" & key & "\"] must be an object")
    var row: PageRow
    if rowJ.hasKey("bias"):
      row.bias = rowJ["bias"].getFloat()
    if rowJ.hasKey("weights"):
      if rowJ["weights"].kind != JObject:
        raise newException(ValueError, "policy page rows[\"" & key & "\"].weights must be an object")
      for pname, wJ in rowJ["weights"].pairs:
        if knownPathKind(pname) < 0:
          raise newException(ValueError,
            "policy page rows[\"" & key & "\"].weights: unknown path \"" & pname & "\"")
        row.weight.add (pname, wJ.getFloat())
    result.row.add (key, row)

proc selectIntent*(page: PolicyPage, candidates: openArray[string],
    ctxFor: proc(name: string): IntentContext): string =
  ## PLACEHOLDER for the real VM's argmax: linear
  ## bias + sum(weight * resolve(path)) per candidate row, first-listed
  ## candidate wins ties (deterministic, no randomness).
  doAssert candidates.len > 0
  result = candidates[0]
  var best = NegInf
  for name in candidates:
    let row = page.rowFor(name)
    let ctx = ctxFor(name)
    var score = row.bias
    for (path, w) in row.weight:
      if w == 0.0:
        continue
      let i = knownPathKind(path)
      if i < 0:
        continue                      # unreachable post-compilePage validation
      let kind = DefaultPaths[i].kind
      score += w * (if kind == pkNumber: ctx.resolveNumber(path)
                    else: (if ctx.resolveBool(path): 1.0 else: 0.0))
    if score > best:
      best = score
      result = name
