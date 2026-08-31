## Standalone shell guard validation over the policy_page expression VM.

import std/[json, sequtils, strutils, tables, unittest]

import ../src/shell/guards
import ../src/shell/types

proc ctx(nums: Table[string, float], bools: Table[string, bool]): IntentContext =
  let n = nums
  let b = bools
  IntentContext(
    resolveNumber: proc(path: string): float = n.getOrDefault(path, 0.0),
    resolveBool: proc(path: string): bool = b.getOrDefault(path, false))

proc nestedNot(depth: int): string =
  if depth <= 1:
    "true"
  else:
    "[\"not\"," & nestedNot(depth - 1) & "]"

proc andWithTerms(terms: int): string =
  result = "[\"and\""
  for _ in 0 ..< terms:
    result.add ",true"
  result.add "]"

suite "shell guards":
  test "canonical guard bytes parse, validate, and evaluate":
    let guard = compileGuard(
      "[\"and\",[\"get\",\"partner.alive\"],[\"<\",[\"get\",\"partner.dist\"],64]]")
    check guard.evaluate(ctx({"partner.dist": 32.0}.toTable,
      {"partner.alive": true}.toTable))
    check not guard.evaluate(ctx({"partner.dist": 96.0}.toTable,
      {"partner.alive": true}.toTable))

  test "unknown guard paths keep policy_page nearest-path suggestions":
    try:
      discard compileGuard("[\"get\",\"partner.alvie\"]")
      check false
    except GuardError as error:
      check "partner.alvie" in error.msg
      check "nearest known path: 'partner.alive'" in error.msg

  test "non-boolean and forbidden guard expressions reject by name":
    expect GuardError:
      discard compileGuard("[\"+\",1,2]")
    expect GuardError:
      discard compileGuard("[\"if\",true,1,0]")

  test "guard depth cap accepts minus and at, rejects one over":
    discard compileGuard(nestedNot(GuardDepthMax - 1))
    discard compileGuard(nestedNot(GuardDepthMax))
    expect GuardError:
      discard compileGuard(nestedNot(GuardDepthMax + 1))

  test "guard node cap accepts minus and at, rejects one over":
    discard compileGuard(andWithTerms(GuardNodeMax - 2))
    discard compileGuard(andWithTerms(GuardNodeMax - 1))
    expect GuardError:
      discard compileGuard(andWithTerms(GuardNodeMax))

  test "guard finite-number cap is enforced by the policy_page API":
    let node = newJArray()
    node.add newJString("<")
    node.add newJFloat(Inf)
    node.add newJInt(1)
    let guard = parseGuardExpression(node)
    let errors = validateBooleanExpression(guard, DefaultPathRegistry,
      GuardDepthMax, GuardNodeMax)
    check errors.anyIt("finite" in it)
