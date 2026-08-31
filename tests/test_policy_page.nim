## The one-page policy VM. docs/designs/ONE_PAGE_POLICY.md is the spec, as
## refined by Maxwell's three-layer ruling: the LLM produces STRATEGY (this
## page), which produces INTENTS (a small fixed named menu the engine
## enumerates), which produces ACTIONS/EVENTS (the existing 8-bit mask, never
## touched here). A page SCORES intents, it never DRIVES.
##
## The load-bearing property this file exists to prove is validation: an
## unknown `get` path must be a HARD REJECT, never a silent 0 -- an LLM-typo'd
## policy that scores nothing and nobody notices is exactly the failure mode
## the design doc calls out by name.

import
  std/[sequtils, strutils, tables, unittest],
  ctf/policy_page

proc mkCtx(nums: Table[string, float], bools: Table[string, bool]): IntentContext =
  ## Test-only convenience constructor. Not the hot-path shape the engine
  ## lane will actually wire up (that will bind directly to per-intent
  ## fields), but exactly the "pair of tables behind closures" the contract
  ## allows.
  let n = nums
  let b = bools
  IntentContext(
    resolveNumber: proc(path: string): float = n.getOrDefault(path, 0.0),
    resolveBool: proc(path: string): bool = b.getOrDefault(path, false),
  )

# The doc's own "Shape" example (docs/designs/ONE_PAGE_POLICY.md) -- a
# CTF-flavored fixture (peel/escort) written before the intent-menu ruling,
# quoted verbatim, so it gets its own bespoke registry naming its literal
# `cand.*` paths rather than DefaultPaths (which is BR-flavored, `intent.*`,
# per the current scope call).
const DoorstepDenierJson = """
{ "paintbot_policy": 1, "name": "doorstep-denier",
  "traits": { "nerve": 0.4, "greed": 0.25, "patience": 0.7 },
  "rules": [
    { "when": [">=", ["get","self.hp_frac"], 0.5],
      "score": ["+", ["*", 30, ["get","cand.is_peel"]],
                     ["*", 12, ["get","cand.is_escort"]],
                     ["*", -8, ["get","cand.exposure"]]] },
    { "when": ["<", ["get","self.hp_frac"], 0.5],
      "score": ["+", ["*", 40, ["get","cand.is_medkit"]],
                     ["*", -20, ["get","cand.threat"]]] }
  ]}
"""

let docExampleRegistry = newPathRegistry([
  ("self.hp_frac", pkNumber),
  ("cand.is_peel", pkBool),
  ("cand.is_escort", pkBool),
  ("cand.is_medkit", pkBool),
  ("cand.exposure", pkNumber),
  ("cand.threat", pkNumber),
])

suite "policy_page: parse + compile":

  test "the doc's exact example page parses and compiles":
    let page = parsePolicyPage(DoorstepDenierJson)
    check page.name == "doorstep-denier"
    check page.rules.len == 2
    check page.traits["nerve"] == 0.4

    let errs = validate(page, docExampleRegistry)
    check errs.len == 0

    let cp = compile(page, docExampleRegistry)
    check cp.name == "doorstep-denier"

  test "unknown get path rejects with the path named":
    let js = """
    { "paintbot_policy": 1, "name": "typo-page",
      "rules": [
        { "when": true, "score": ["*", 10, ["get", "cand.is_peeel"]] }
      ]}
    """
    let page = parsePolicyPage(js)
    let errs = validate(page, docExampleRegistry)
    check errs.len > 0
    check errs.anyIt("cand.is_peeel" in it)
    # never silently evaluates to 0 -- compile must refuse, not shrug
    expect ValueError:
      discard compile(page, docExampleRegistry)

  test "'if' in a score rejects":
    let js = """
    { "paintbot_policy": 1, "name": "branchy",
      "rules": [
        { "when": true,
          "score": ["if", ["get", "self.hp_frac"], 10, 0] }
      ]}
    """
    expect PolicyParseError:
      discard parsePolicyPage(js)

  test "bad arity rejects":
    let js = """
    { "paintbot_policy": 1, "name": "bad-clamp",
      "rules": [
        { "when": true, "score": ["clamp", 1, 2] }
      ]}
    """
    let page = parsePolicyPage(js)
    let errs = validate(page, docExampleRegistry)
    check errs.len > 0
    check errs.anyIt("clamp" in it)

  test "empty rules rejects":
    let js = """{ "paintbot_policy": 1, "name": "nothing", "rules": [] }"""
    let page = parsePolicyPage(js)
    let errs = validate(page, docExampleRegistry)
    check errs.len > 0
    check errs.anyIt("no rules" in it)

  test "an unknown op is a hard parse error naming the op":
    let js = """
    { "paintbot_policy": 1, "name": "sneaky",
      "rules": [ { "when": true, "score": ["frobnicate", 1, 2] } ]}
    """
    try:
      discard parsePolicyPage(js)
      check false
    except PolicyParseError as e:
      check "frobnicate" in e.msg

  test "when that isn't boolean-valued rejects":
    let js = """
    { "paintbot_policy": 1, "name": "num-when",
      "rules": [ { "when": ["+", 1, 2], "score": 5 } ]}
    """
    let page = parsePolicyPage(js)
    let errs = validate(page, docExampleRegistry)
    check errs.len > 0
    check errs.anyIt("when" in it)

suite "policy_page: interning":

  test "two identical pages intern to ONE compiled object":
    let a = flash(DoorstepDenierJson, docExampleRegistry)
    let b = flash(DoorstepDenierJson, docExampleRegistry)
    check a == b # ref equality: the cache returned the SAME object, not a copy

    # A structurally-identical page with different whitespace/key order also
    # interns to the same object, because pageHash is over the canonical AST.
    let jsReordered = """
    {"name": "doorstep-denier", "paintbot_policy": 1,
     "traits": {"patience": 0.7, "nerve": 0.4, "greed": 0.25},
     "rules": [
       { "score": ["+", ["*", 30, ["get","cand.is_peel"]],
                       ["*", 12, ["get","cand.is_escort"]],
                       ["*", -8, ["get","cand.exposure"]]],
         "when": [">=", ["get","self.hp_frac"], 0.5] },
       { "score": ["+", ["*", 40, ["get","cand.is_medkit"]],
                       ["*", -20, ["get","cand.threat"]]],
         "when": ["<", ["get","self.hp_frac"], 0.5] }
     ]}
    """
    let c = flash(jsReordered, docExampleRegistry)
    check c == a

  test "a different page compiles to a different object":
    let js2 = """
    { "paintbot_policy": 1, "name": "other",
      "rules": [ { "when": true, "score": 1 } ] }
    """
    let d = flash(js2, docExampleRegistry)
    let a = flash(DoorstepDenierJson, docExampleRegistry)
    check d != a

suite "policy_page: evaluate":

  test "a rule whose when is false contributes zero":
    let js = """
    { "paintbot_policy": 1, "name": "half-page",
      "rules": [
        { "when": false, "score": 999 },
        { "when": true, "score": 7 }
      ]}
    """
    let cp = compile(parsePolicyPage(js), docExampleRegistry)
    let ctx = mkCtx(initTable[string, float](), initTable[string, bool]())
    check scoreIntent(cp, ctx) == 7.0

  test "argmax picks the right intent on a hand-built fixture":
    let cp = compile(parsePolicyPage(DoorstepDenierJson), docExampleRegistry)
    # healthy: prefers peel over escort, penalized by exposure
    let peelNums = {"self.hp_frac": 0.9, "cand.exposure": 0.1, "cand.threat": 0.0}.toTable
    let peelBools = {"cand.is_peel": true, "cand.is_escort": false, "cand.is_medkit": false}.toTable
    let peelCtx = mkCtx(peelNums, peelBools)

    let escortNums = {"self.hp_frac": 0.9, "cand.exposure": 0.1, "cand.threat": 0.0}.toTable
    let escortBools = {"cand.is_peel": false, "cand.is_escort": true, "cand.is_medkit": false}.toTable
    let escortCtx = mkCtx(escortNums, escortBools)

    let idx = argmax(cp, [escortCtx, peelCtx])
    check idx == 1 # peelCtx: 30 > 12

  test "argmax: ring-close pressure picks the ring-safe intent over a juicy low-hp enemy":
    # Canonical BR judgment call: when the ring is about to close, safety
    # must outrank a tempting kill. Proves the when/score split works on
    # real BR semantics, not just the CTF doc example. Uses the `intent.*`
    # namespace (the ratified vocabulary), not the doc's historical `cand.*`.
    let brRegistry = newPathRegistry([
      ("self.ticks_to_ring_close", pkNumber),
      ("intent.is_ring_safe", pkBool),
      ("intent.is_enemy", pkBool),
      ("intent.exposure", pkNumber),
      ("intent.enemy_hp_frac", pkNumber),
    ])
    let js = """
    { "paintbot_policy": 1, "name": "ring-aware",
      "rules": [
        { "when": ["<", ["get","self.ticks_to_ring_close"], 30],
          "score": ["+", ["*", 50, ["get","intent.is_ring_safe"]],
                         ["*", -10, ["get","intent.exposure"]]] },
        { "when": [">=", ["get","self.ticks_to_ring_close"], 30],
          "score": ["+", ["*", 40, ["get","intent.is_enemy"]],
                         ["*", 20, ["-", 1, ["get","intent.enemy_hp_frac"]]]] }
      ]}
    """
    let cp = compile(parsePolicyPage(js), brRegistry)

    let selfNums = {"self.ticks_to_ring_close": 5.0}.toTable # ring is about to close

    var safeNums = selfNums
    safeNums["intent.exposure"] = 0.2
    safeNums["intent.enemy_hp_frac"] = 0.0
    let safeCtx = mkCtx(safeNums, {"intent.is_ring_safe": true, "intent.is_enemy": false}.toTable)

    var enemyNums = selfNums
    enemyNums["intent.exposure"] = 0.0
    enemyNums["intent.enemy_hp_frac"] = 0.05 # juicy, nearly-dead enemy
    let enemyCtx = mkCtx(enemyNums, {"intent.is_ring_safe": false, "intent.is_enemy": true}.toTable)

    let idx = argmax(cp, [enemyCtx, safeCtx])
    check idx == 1 # safeCtx wins: the ring-close rule dominates, ignoring the enemy rule entirely

  test "partner-aware paths resolve against DefaultPaths (BR is duos, not solo FFA)":
    # Names are the resolver-backed reality from the build-runner handoff:
    # partner.alive / partner.dist / partner.in_combat -- NOT self.partner_*
    # or partner.hp_frac, which were the earlier (pre-resolver) guesses.
    let js = """
    { "paintbot_policy": 1, "name": "regroup-aware",
      "rules": [
        { "when": ["and", ["get","partner.alive"], ["get","partner.in_combat"]],
          "score": ["+", 50, ["*", -1, ["get","partner.dist"]]] },
        { "when": ["not", ["get","partner.alive"]],
          "score": 0 }
      ]}
    """
    let page = parsePolicyPage(js)
    let errs = validate(page, DefaultPathRegistry)
    check errs.len == 0
    let cp = compile(page, DefaultPathRegistry)
    let ctx = mkCtx(
      {"partner.dist": 12.0}.toTable,
      {"partner.alive": true, "partner.in_combat": true}.toTable,
    )
    check scoreIntent(cp, ctx) == 38.0 # 50 - 12

  test "determinism: same page + same ctx scores identically, twice":
    let cp = compile(parsePolicyPage(DoorstepDenierJson), docExampleRegistry)
    let nums = {"self.hp_frac": 0.42, "cand.exposure": 0.33, "cand.threat": 0.1}.toTable
    let bools = {"cand.is_peel": true, "cand.is_escort": false, "cand.is_medkit": true}.toTable
    let ctx = mkCtx(nums, bools)
    let s1 = scoreIntent(cp, ctx)
    let s2 = scoreIntent(cp, ctx)
    check s1 == s2
    # and a fresh compile of the identical page must agree bit-for-bit too
    let cp2 = compile(parsePolicyPage(DoorstepDenierJson), docExampleRegistry)
    let s3 = scoreIntent(cp2, ctx)
    check s1 == s3

  test "a nil page is the empty page: scores 0, argmax ties to the first candidate":
    # Regression for a real crash: flashPage() installs a default
    # PolicyPage() (compiled == nil, CompiledPage is a ref) and the
    # onepage runner's determinism design lands the episode-start flash at
    # tick+1 -- wire first, swap at the boundary -- so every seat's first
    # decide() argmaxes a nil CompiledPage. 31 of 32 seats SIGSEGV'd on a
    # full recording before this guard: scoreIntent must treat nil as the
    # documented empty page (zero rules, every intent scores 0) instead of
    # iterating cp.rules on a nil ref.
    var cp: CompiledPage
    check cp.isNil
    let ctx = mkCtx(initTable[string, float](), initTable[string, bool]())
    check scoreIntent(cp, ctx) == 0.0

    let ctxA = mkCtx({"self.hp_frac": 0.9}.toTable, {"cand.is_peel": true}.toTable)
    let ctxB = mkCtx({"self.hp_frac": 0.1}.toTable, {"cand.is_medkit": true}.toTable)
    let idx = argmax(cp, [ctxA, ctxB])
    check idx == 0 # every intent ties at 0 against a nil page; first candidate wins
