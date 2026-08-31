## The one-page policy — a pure scoring VM, no engine coupling.
##
## Doc: docs/designs/ONE_PAGE_POLICY.md. **Three layers, per Maxwell's ruling
## (supersedes the doc's open question #1):** the LLM produces STRATEGY,
## which produces INTENTS, which produces ACTIONS/EVENTS.
##   - STRATEGY is this page. It never touches the action space.
##   - INTENTS are the middle layer: a small, fixed, NAMED menu (e.g. ENGAGE,
##     PEEL, LOOT, ROTATE_TO_RING, REGROUP_PARTNER — see the engine lane's
##     ratified list). The engine enumerates that menu once per decision
##     tick; this module scores each entry and `argmax` picks one.
##   - ACTIONS/EVENTS are the existing 8-bit mask. The engine resolves the
##     winning intent into concrete targets and then into that mask — this
##     page never sees it and never emits one.
##
## So: the page SCORES, it does not DRIVE. This module parses a small JSON
## expression tree ("the page"), validates it against an injected vocabulary
## of legal `get` paths (the `PathRegistry`), compiles it once into closures,
## and evaluates it per intent to produce a score. No loops, no `if` inside a
## score, no user-defined functions, no randomness, no mutation — a policy
## can only re-rank the fixed intent menu the engine already offered it.
##
## This module deliberately knows nothing about sim.nim / server.nim /
## baseline.nim / any intent-resolution engine. The vocabulary of legal
## `get` paths is injected via `PathRegistry` so an engine lane can drop in
## the real self/intent/partner state surface without this file changing at
## all.
##
## A BR cog gets exactly ONE life (no respawn — `killPlayer` forces `lives=0`
## on first death), so a page is flashed once per cog per episode, at the
## camera-ready boundary, never mid-episode. That simplifies the interning
## story: no mid-life reflash to worry about, only "many cogs, same page,
## compile once."
##
## Determinism is non-negotiable (replays re-simulate): no float
## non-determinism from iteration order, no `Table` iteration in the hot
## (per-intent, per-tick) path, and compiled closures capture their operands
## positionally rather than walking JSON at eval time.

import
  std/[algorithm, json, sequtils, sha1, strutils, tables]

# ----------------------------------------------------------------------------
# Errors
# ----------------------------------------------------------------------------

type
  PolicyParseError* = object of ValueError
    ## Raised by `parsePolicyPage` for structurally-invalid pages: bad JSON
    ## shape, an op outside the whitelist, or `if` used inside a score/when
    ## expression. These are hard parse errors by design (doc §"Rules for
    ## keeping it Sugarscape-simple") — they do not depend on a PathRegistry
    ## and so cannot be deferred to `validate`.

# ----------------------------------------------------------------------------
# The op whitelist — exactly these, no more (~18 ops, matches the doc).
# ----------------------------------------------------------------------------

const
  ArithmeticOps = @["+", "-", "*", "/", "min", "max", "abs", "clamp"]
  ComparisonOps = @["<", "<=", ">", ">=", "=="]
  LogicOps = @["and", "or", "not"]
  AccessOps = @["get", "trait"] ## handled specially in the parser: their sole
    ## argument is a literal string (a path or a trait name), never a
    ## sub-expression.
  ScoringOps = ArithmeticOps & ComparisonOps & LogicOps
    ## Every op that can appear as a `ekOp` node once `get`/`trait` have been
    ## peeled off by the parser.

# ----------------------------------------------------------------------------
# Expression tree
# ----------------------------------------------------------------------------

type
  ExprKind = enum
    ekNum   ## a literal number
    ekBool  ## a literal boolean (true/false)
    ekGet   ## ["get", "intent.exposure"] — resolved per-intent at eval time
    ekTrait ## ["trait", "nerve"] — resolved from the page's own traits table
    ekOp    ## [op, arg, arg, ...] — one of ScoringOps

  Expr = ref ExprObj
  ExprObj = object
    case kind: ExprKind
    of ekNum:
      numVal: float
    of ekBool:
      boolVal: bool
    of ekGet:
      path: string
    of ekTrait:
      traitName: string
    of ekOp:
      op: string
      args: seq[Expr]

  Rule* = object
    whenExpr*: Expr
    scoreExpr*: Expr

  PolicyPage* = object
    version*: int
    name*: string
    traits*: Table[string, float]
    rules*: seq[Rule]

# ----------------------------------------------------------------------------
# The path registry — the injection point.
# ----------------------------------------------------------------------------

type
  PathKind* = enum
    pkNumber
    pkBool

  PathRegistry* = object
    kinds: Table[string, PathKind]

proc newPathRegistry*(paths: openArray[(string, PathKind)]): PathRegistry =
  result = PathRegistry(kinds: initTable[string, PathKind]())
  for (path, kind) in paths:
    result.kinds[path] = kind

proc hasPath*(reg: PathRegistry, path: string): bool =
  reg.kinds.hasKey(path)

proc kindOf*(reg: PathRegistry, path: string): PathKind =
  reg.kinds[path]

proc allPaths*(reg: PathRegistry): seq[string] =
  ## Sorted for determinism — callers (e.g. the nearest-path suggestion)
  ## must never depend on Table iteration order.
  result = toSeq(reg.kinds.keys)
  result.sort()

const DefaultPaths* = [
  # REAL, resolver-backed as of the build-runner handoff — every path below
  # has a live resolver arm today (players/onepage/onepage.nim's
  # `numberPath`/`boolPath`/`intentTagBool` are `case` statements over
  # exactly these strings; nothing here is aspirational, and anything that
  # couldn't actually be computed from label-string perception was cut
  # before it reached this list). That resolver currently lives in a
  # disposable stub (players/onepage/onepage/policy_stub.nim + onepage.nim)
  # pending the real engine-side wiring, so the FILE backing this list will
  # change — but the VOCABULARY is real and load-bearing: James writes
  # strategies against it. Replace wholesale only if the resolver's own
  # path set changes; don't hand-add speculative entries here.
  #
  # Target mode is paintbot BATTLE ROYALE, 16 teams of DUOS (32 seats), not
  # solo FFA — the partner.* facts below are a real strategic axis, not
  # decoration. The reward is PLACEMENT, not kills-per-second: the
  # engagement-gated placement bonus is top-heavy —
  # `BrPlacementBonus[2..16] = [5,4,4,3,3,2,2,2,1,1,1,0,0,0,0]`, source-
  # verified on both BR branches — 2nd-5th carry nearly all the value, and
  # it is zero from 13th place on. Placement and score are NEVER surfaced
  # mid-episode, so there is deliberately no self.placement or self.score
  # path here.
  #
  # SENTINEL WARNING for page authors: several `world.*` distances use -1
  # to mean "never observed" (no enemy/medkit/item seen this life yet), NOT
  # "very close" — marked [SENTINEL] below. A raw
  # `["*", w, ["get","world.nearest_enemy_dist"]]` term silently inverts
  # sign on that value when nothing has been seen. Guard with a comparison
  # first, e.g. `["<", ["get","world.nearest_enemy_dist"], 0]`, before using
  # one of these arithmetically.

  # -- self --
  ("self.hp_frac", pkNumber), # bot.hp / MaxHp, off the "lives <hp>hp x<lives>" HUD text

  # -- partner (BR is duos, not solo FFA) --
  ("partner.alive", pkBool),      # our duo partner has a live track this life
  ("partner.dist", pkNumber),     # px to partner's last known pos; -1 if never seen [SENTINEL]
  ("partner.in_combat", pkBool),  # any tracked enemy within 200px of partner's last known pos

  # -- world (label-string-perceived state; enemy/item tracks have ~5s memory) --
  ("world.enemy_count", pkNumber),        # count of currently-remembered enemy tracks
  ("world.nearest_enemy_dist", pkNumber), # px to nearest remembered enemy; -1 if none [SENTINEL]
  ("world.weakest_enemy_hp", pkNumber),   # lowest hp among enemies ever hp-read; -1 if none read yet [SENTINEL]
  ("world.in_zone", pkBool),              # inside the current BR shrink-zone rect right now
  ("world.zone_dist", pkNumber),          # px to nearest zone-rect edge; 0 if inside or no zone marker yet
  ("world.medkit_dist", pkNumber),        # px to nearest medkit believed stocked; -1 if none known [SENTINEL]
  ("world.item_dist", pkNumber),          # px to nearest non-medkit pickup (shield/spray/grenade/barrier, one bucket); -1 if none known [SENTINEL]

  # -- intent (per-menu-item tag: true iff the row being scored IS that
  #    named intent; the engine resolves the winning intent into concrete
  #    targets/actions, which this page never sees) --
  ("intent.is_enemy", pkBool),    # EngageNearestEnemy / EngageWeakestEnemy / SupportPartner
  # NAME COLLISION, DELIBERATE SPELLING, UNRELATED CONCEPT: `is_peel` here is
  # the BR intent "isolate from partner/fight" (Disengage / AvoidContact),
  # not the Glory scoreboard deed PEEL (a combat-assist deed, see
  # ctf/glory.nim's `Deed`). Same word, two different vocabularies
  # (intent-menu vs. scoreboard) — flagged by the flash lane, confirmed by
  # the resolver lane.
  ("intent.is_peel", pkBool),     # Disengage / AvoidContact
  ("intent.is_recover", pkBool),  # SeekMedkit
  ("intent.is_item", pkBool),     # SeekItem
  ("intent.is_partner", pkBool),  # RegroupWithPartner / SupportPartner
  ("intent.is_zone", pkBool),     # RotateToZone / HoldCoverInPlace / AvoidContact

  # Per-candidate target annotations, NOT match-wide: computed with the same
  # targeting call the resolver will actually use for THIS intent this tick
  # (ENGAGE/PEEL/HOLD_RING_SAFE -> nearest enemy, FINISH -> weakest, THIRD_
  # PARTY -> fight-detection, SUPPORT_PARTNER -> nearest to partner,
  # USE_GRENADE -> in-band grenade target) -- so it can never disagree with
  # what the engine resolves the winning intent onto. -1 if the intent has
  # no single target this tick [SENTINEL -- see the warning above].
  ("intent.target_hp", pkNumber),   # landed after the first cut, real, resolver-backed; -1 if no target [SENTINEL]
  ("intent.target_dist", pkNumber), # landed after the first cut, real, resolver-backed; -1 if no target [SENTINEL]
]

let DefaultPathRegistry* = newPathRegistry(DefaultPaths)

# ----------------------------------------------------------------------------
# Parser
# ----------------------------------------------------------------------------

proc parseExpr(js: JsonNode): Expr =
  case js.kind
  of JInt, JFloat:
    result = Expr(kind: ekNum, numVal: js.getFloat)
  of JBool:
    result = Expr(kind: ekBool, boolVal: js.getBool)
  of JArray:
    if js.elems.len == 0:
      raise newException(PolicyParseError, "empty expression array")
    let head = js.elems[0]
    if head.kind != JString:
      raise newException(PolicyParseError,
        "expression head must be an operator name (string), got " & $head.kind)
    let op = head.getStr

    if op == "if":
      raise newException(PolicyParseError,
        "'if' is forbidden inside a score/when expression — a policy scores, it does not branch")

    if op == "get" or op == "trait":
      if js.elems.len != 2 or js.elems[1].kind != JString:
        raise newException(PolicyParseError,
          "'" & op & "' requires exactly one string argument (a path/trait name)")
      let nameStr = js.elems[1].getStr
      if op == "get":
        return Expr(kind: ekGet, path: nameStr)
      else:
        return Expr(kind: ekTrait, traitName: nameStr)

    if op notin ScoringOps:
      raise newException(PolicyParseError,
        "unknown op '" & op & "' — not in the op whitelist (" & ScoringOps.join(", ") & ", get, trait)")

    var args: seq[Expr] = @[]
    for i in 1 ..< js.elems.len:
      args.add parseExpr(js.elems[i])
    result = Expr(kind: ekOp, op: op, args: args)
  of JString:
    raise newException(PolicyParseError,
      "bare string literal not allowed here (did you mean [\"get\", \"" & js.getStr &
      "\"] or [\"trait\", \"" & js.getStr & "\"]?)")
  else:
    raise newException(PolicyParseError, "unsupported literal in expression: " & $js.kind)

proc parsePolicyPage*(js: JsonNode): PolicyPage =
  if js.kind != JObject:
    raise newException(PolicyParseError, "policy page must be a JSON object")

  if not js.hasKey("paintbot_policy"):
    raise newException(PolicyParseError, "missing required field 'paintbot_policy'")
  let verNode = js["paintbot_policy"]
  if verNode.kind != JInt:
    raise newException(PolicyParseError, "'paintbot_policy' must be an integer")
  let ver = verNode.getInt
  if ver != 1:
    raise newException(PolicyParseError, "unsupported paintbot_policy version: " & $ver)

  var name = ""
  if js.hasKey("name"):
    if js["name"].kind != JString:
      raise newException(PolicyParseError, "'name' must be a string")
    name = js["name"].getStr

  var traits = initTable[string, float]()
  if js.hasKey("traits"):
    let tn = js["traits"]
    if tn.kind != JObject:
      raise newException(PolicyParseError, "'traits' must be an object")
    for k, v in tn.pairs:
      if v.kind notin {JInt, JFloat}:
        raise newException(PolicyParseError, "trait '" & k & "' must be a number")
      traits[k] = v.getFloat

  if not js.hasKey("rules"):
    raise newException(PolicyParseError, "missing required field 'rules'")
  let rulesNode = js["rules"]
  if rulesNode.kind != JArray:
    raise newException(PolicyParseError, "'rules' must be an array")

  var rules: seq[Rule] = @[]
  for i, rn in rulesNode.elems:
    if rn.kind != JObject:
      raise newException(PolicyParseError, "rule " & $i & " must be an object")
    if not rn.hasKey("when") or not rn.hasKey("score"):
      raise newException(PolicyParseError, "rule " & $i & " must have both 'when' and 'score'")
    let whenExpr = parseExpr(rn["when"])
    let scoreExpr = parseExpr(rn["score"])
    rules.add Rule(whenExpr: whenExpr, scoreExpr: scoreExpr)

  result = PolicyPage(version: ver, name: name, traits: traits, rules: rules)

proc parsePolicyPage*(s: string): PolicyPage =
  parsePolicyPage(parseJson(s))

# ----------------------------------------------------------------------------
# Validation — the load-bearing feature. An unknown `get` path (or any other
# semantic defect) must NEVER silently evaluate to 0; it is a hard reject
# reported here.
# ----------------------------------------------------------------------------

type ValueKind = enum
  vkNumber
  vkBool

proc levenshtein(a, b: string): int =
  let n = a.len
  let m = b.len
  if n == 0: return m
  if m == 0: return n
  var prev = newSeq[int](m + 1)
  var cur = newSeq[int](m + 1)
  for j in 0 .. m: prev[j] = j
  for i in 1 .. n:
    cur[0] = i
    for j in 1 .. m:
      let cost = if a[i - 1] == b[j - 1]: 0 else: 1
      cur[j] = min(min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost)
    prev = cur
  result = prev[m]

proc nearestPath(paths: seq[string], target: string): string =
  ## `paths` must already be in a deterministic (sorted) order.
  var bestDist = high(int)
  for p in paths:
    let d = levenshtein(target, p)
    if d < bestDist:
      bestDist = d
      result = p

proc arityOk(op: string, n: int): bool =
  case op
  of "+", "*", "min", "max", "and", "or", "-": n >= 1
  of "/", "<", "<=", ">", ">=", "==": n == 2
  of "abs", "not": n == 1
  of "clamp": n == 3
  else: false

proc expectedArityDesc(op: string): string =
  case op
  of "+", "*", "min", "max", "and", "or", "-": "at least 1 argument"
  of "/", "<", "<=", ">", ">=", "==": "exactly 2 arguments"
  of "abs", "not": "exactly 1 argument"
  of "clamp": "exactly 3 arguments"
  else: "a valid arity"

proc inferKind(e: Expr, registry: PathRegistry, traits: Table[string, float],
                errors: var seq[string]): ValueKind =
  case e.kind
  of ekNum: vkNumber
  of ekBool: vkBool
  of ekGet:
    if not registry.hasPath(e.path):
      let suggestion = nearestPath(registry.allPaths(), e.path)
      if suggestion.len > 0:
        errors.add "unknown get path '" & e.path & "' (nearest known path: '" & suggestion & "')"
      else:
        errors.add "unknown get path '" & e.path & "' (registry has no paths at all)"
      vkNumber # best-guess, so the rest of the tree still type-checks
    else:
      case registry.kindOf(e.path)
      of pkNumber: vkNumber
      of pkBool: vkBool
  of ekTrait:
    if not traits.hasKey(e.traitName):
      errors.add "unknown trait '" & e.traitName & "' (not declared in this page's traits table)"
    vkNumber
  of ekOp:
    if not arityOk(e.op, e.args.len):
      errors.add "op '" & e.op & "' expects " & expectedArityDesc(e.op) &
        ", got " & $e.args.len
    for a in e.args:
      discard inferKind(a, registry, traits, errors) # recurse for nested errors only
    case e.op
    of "+", "-", "*", "/", "min", "max", "abs", "clamp":
      # A boolean operand (a bare `true`/`false`, or a `get`/`trait` of
      # boolean kind) is a legal numeric 0/1 here BY DESIGN — the doc's own
      # canonical example scores `["*", 30, ["get","cand.is_peel"]]`
      # (`intent.is_peel` in the current registry), i.e. "weight times
      # indicator", throughout. Booleans and numbers are one runtime
      # representation (float) and this is the load-bearing use of that
      # fact, not a hole in the type system.
      vkNumber
    of "<", "<=", ">", ">=", "==":
      # Both operands coerce to float the same way arithmetic operands do;
      # no separate strictness here either.
      vkBool
    of "and", "or", "not":
      vkBool
    else:
      vkNumber # unreachable: op already whitelisted at parse time

proc validate*(page: PolicyPage, registry: PathRegistry): seq[string] =
  result = @[]
  if page.rules.len == 0:
    result.add "policy has no rules"
  for i, r in page.rules:
    var errs: seq[string] = @[]
    let whenKind = inferKind(r.whenExpr, registry, page.traits, errs)
    if whenKind != vkBool:
      errs.add "'when' must be boolean-valued"
    let scoreKind = inferKind(r.scoreExpr, registry, page.traits, errs)
    if scoreKind != vkNumber:
      errs.add "'score' must be numeric-valued"
    for e in errs:
      result.add "rule " & $i & ": " & e

# ----------------------------------------------------------------------------
# Compile + intern
# ----------------------------------------------------------------------------

type
  IntentContext* = object
    ## A cheap, allocation-free-at-eval-time abstraction over "resolve this
    ## path to a number/bool for THIS named intent (self.*/intent.*/
    ## partner.* alike)". The engine lane supplies these closures however is
    ## fastest for its own data (direct struct field reads, a small case
    ## statement, etc.) — this module never walks JSON or a Table in the hot
    ## path itself.
    resolveNumber*: proc(path: string): float {.closure.}
    resolveBool*: proc(path: string): bool {.closure.}

  NumFn = proc(ctx: IntentContext): float {.closure.}

  CompiledRule = object
    whenFn: NumFn
    scoreFn: NumFn

  CompiledPage* = ref object
    ## Ref so interning ("two identical pages intern to ONE compiled object")
    ## is a plain identity check.
    name*: string
    hash*: string
    rules: seq[CompiledRule]

proc canonicalExprRepr(e: Expr): string =
  case e.kind
  of ekNum: "n:" & $e.numVal
  of ekBool: "b:" & $e.boolVal
  of ekGet: "g:" & e.path
  of ekTrait: "t:" & e.traitName
  of ekOp: "(" & e.op & " " & e.args.mapIt(canonicalExprRepr(it)).join(" ") & ")"

proc canonicalPageRepr(page: PolicyPage): string =
  var parts: seq[string] = @[]
  parts.add "v=" & $page.version
  parts.add "name=" & page.name
  var traitKeys = toSeq(page.traits.keys)
  traitKeys.sort()
  for k in traitKeys:
    parts.add "trait:" & k & "=" & $page.traits[k]
  for r in page.rules:
    parts.add "when=" & canonicalExprRepr(r.whenExpr)
    parts.add "score=" & canonicalExprRepr(r.scoreExpr)
  result = parts.join("|")

proc pageHash*(page: PolicyPage): string =
  ## A content hash over the page's canonical form — stable across Table
  ## iteration order and JSON key order/whitespace, since it hashes our own
  ## sorted AST representation rather than raw input text.
  $secureHash(canonicalPageRepr(page))

proc compileExpr(e: Expr, registry: PathRegistry, traits: Table[string, float]): NumFn =
  case e.kind
  of ekNum:
    let v = e.numVal
    result = proc(ctx: IntentContext): float = v
  of ekBool:
    let v: float = (if e.boolVal: 1.0 else: 0.0)
    result = proc(ctx: IntentContext): float = v
  of ekGet:
    let path = e.path
    case registry.kindOf(path)
    of pkNumber:
      result = proc(ctx: IntentContext): float = ctx.resolveNumber(path)
    of pkBool:
      result = proc(ctx: IntentContext): float =
        (if ctx.resolveBool(path): 1.0 else: 0.0)
  of ekTrait:
    let v = traits.getOrDefault(e.traitName, 0.0)
    result = proc(ctx: IntentContext): float = v
  of ekOp:
    var fns: seq[NumFn] = @[]
    for a in e.args:
      fns.add compileExpr(a, registry, traits)
    case e.op
    of "+":
      result = proc(ctx: IntentContext): float =
        var acc = 0.0
        for f in fns: acc += f(ctx)
        acc
    of "-":
      if fns.len == 1:
        let f0 = fns[0]
        result = proc(ctx: IntentContext): float = -f0(ctx)
      else:
        result = proc(ctx: IntentContext): float =
          var acc = fns[0](ctx)
          for i in 1 ..< fns.len: acc -= fns[i](ctx)
          acc
    of "*":
      result = proc(ctx: IntentContext): float =
        var acc = 1.0
        for f in fns: acc *= f(ctx)
        acc
    of "/":
      let f0 = fns[0]
      let f1 = fns[1]
      result = proc(ctx: IntentContext): float =
        let d = f1(ctx)
        (if d == 0.0: 0.0 else: f0(ctx) / d)
    of "min":
      result = proc(ctx: IntentContext): float =
        var acc = fns[0](ctx)
        for i in 1 ..< fns.len: acc = min(acc, fns[i](ctx))
        acc
    of "max":
      result = proc(ctx: IntentContext): float =
        var acc = fns[0](ctx)
        for i in 1 ..< fns.len: acc = max(acc, fns[i](ctx))
        acc
    of "abs":
      let f0 = fns[0]
      result = proc(ctx: IntentContext): float = abs(f0(ctx))
    of "clamp":
      let fv = fns[0]
      let flo = fns[1]
      let fhi = fns[2]
      result = proc(ctx: IntentContext): float = clamp(fv(ctx), flo(ctx), fhi(ctx))
    of "<":
      let f0 = fns[0]; let f1 = fns[1]
      result = proc(ctx: IntentContext): float = (if f0(ctx) < f1(ctx): 1.0 else: 0.0)
    of "<=":
      let f0 = fns[0]; let f1 = fns[1]
      result = proc(ctx: IntentContext): float = (if f0(ctx) <= f1(ctx): 1.0 else: 0.0)
    of ">":
      let f0 = fns[0]; let f1 = fns[1]
      result = proc(ctx: IntentContext): float = (if f0(ctx) > f1(ctx): 1.0 else: 0.0)
    of ">=":
      let f0 = fns[0]; let f1 = fns[1]
      result = proc(ctx: IntentContext): float = (if f0(ctx) >= f1(ctx): 1.0 else: 0.0)
    of "==":
      let f0 = fns[0]; let f1 = fns[1]
      result = proc(ctx: IntentContext): float = (if f0(ctx) == f1(ctx): 1.0 else: 0.0)
    of "and":
      result = proc(ctx: IntentContext): float =
        for f in fns:
          if f(ctx) == 0.0: return 0.0
        1.0
    of "or":
      result = proc(ctx: IntentContext): float =
        for f in fns:
          if f(ctx) != 0.0: return 1.0
        0.0
    of "not":
      let f0 = fns[0]
      result = proc(ctx: IntentContext): float = (if f0(ctx) == 0.0: 1.0 else: 0.0)
    else:
      raise newException(PolicyParseError, "unknown op at compile time: '" & e.op & "'")

proc compile*(page: PolicyPage, registry: PathRegistry): CompiledPage =
  let errs = validate(page, registry)
  if errs.len > 0:
    raise newException(ValueError,
      "cannot compile invalid policy page '" & page.name & "': " & errs.join("; "))
  var rules: seq[CompiledRule] = @[]
  for r in page.rules:
    let whenFn = compileExpr(r.whenExpr, registry, page.traits)
    let scoreFn = compileExpr(r.scoreExpr, registry, page.traits)
    rules.add CompiledRule(whenFn: whenFn, scoreFn: scoreFn)
  result = CompiledPage(name: page.name, hash: pageHash(page), rules: rules)

var pageCache {.threadvar.}: Table[string, CompiledPage]
  ## Module-level intern cache keyed by `pageHash` — sixteen cogs sharing a
  ## page compile once. `{.threadvar.}` so each thread gets its own table
  ## rather than sharing un-synchronized mutable state; correctness doesn't
  ## depend on cross-thread sharing, only on same-page-same-hash reuse.

proc flash*(json: string, registry: PathRegistry): CompiledPage =
  ## Cache-aware entry point: resolve hash, hand over the compiled closure.
  let page = parsePolicyPage(json)
  let h = pageHash(page)
  if pageCache.hasKey(h):
    return pageCache[h]
  let cp = compile(page, registry)
  pageCache[h] = cp
  result = cp

proc flash*(json: string): CompiledPage =
  flash(json, DefaultPathRegistry)

# ----------------------------------------------------------------------------
# Evaluate
# ----------------------------------------------------------------------------

proc scoreIntent*(cp: CompiledPage, ctx: IntentContext): float =
  ## Rules apply in order; a rule whose `when` is false contributes nothing.
  ## A nil page IS the empty page: zero rules, every intent scores 0. This
  ## is what a caller holding a default/unflashed page gets, and it must
  ## score, not crash -- the runner's decide loop runs on the flash edge's
  ## own frame, one tick before the scheduled swap lands.
  if cp.isNil:
    return 0.0
  var acc = 0.0
  for r in cp.rules:
    if r.whenFn(ctx) != 0.0:
      acc += r.scoreFn(ctx)
  acc

proc argmax*(cp: CompiledPage, intents: openArray[IntentContext]): int =
  ## Selects an INTENT (an index into the engine's fixed named intent menu),
  ## never a concrete target — the engine resolves the winner into targets
  ## and then the action mask. -1 if `intents` is empty. Ties keep the first
  ## (lowest-index) winner — deterministic, no dependence on iteration/hash
  ## order. A nil (unflashed/empty) page ties every intent at 0, so the
  ## first candidate wins — same rule, degenerate input.
  result = -1
  var best = NegInf
  for i in 0 ..< intents.len:
    let s = scoreIntent(cp, intents[i])
    if result == -1 or s > best:
      best = s
      result = i
