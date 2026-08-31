## Shell guard-expression API over the existing policy_page expression VM.
##
## This module is the runtime lane's narrow seam: callers hand it canonical
## JSON bytes for one boolean expression, but the underlying policy_page Expr
## type remains private to policy_page.nim.

import std/[json, strutils]

import ../ctf/policy_page
import canonical_fast, types

export policy_page.IntentContext, policy_page.PathKind, policy_page.PathRegistry,
  policy_page.newPathRegistry, policy_page.DefaultPathRegistry,
  policy_page.parseGuardExpression, policy_page.validateBooleanExpression

type
  GuardError* = object of CatchableError

  CompiledGuard* = object
    bytes*: string
    compiled: GuardFn

proc guardInvalid(detail: string) {.noreturn.} =
  raise newException(GuardError, detail)

proc readJsonNode(r: var CanonicalReader): JsonNode =
  case r.peekKind()
  of cvObject:
    result = newJObject()
    r.enterObject()
    var key: string
    while r.nextKey(key):
      result[key] = r.readJsonNode()
  of cvArray:
    result = newJArray()
    r.enterArray()
    while r.nextElement():
      result.add r.readJsonNode()
  of cvString:
    result = %r.readString()
  of cvInt:
    result = %r.readInt()
  of cvFloat:
    result = %r.readFloat()
  of cvBool:
    result = %r.readBool()
  of cvNull:
    r.readNull()
    result = newJNull()

proc parseCanonicalJson(bytes: string): JsonNode =
  var reader = initCanonicalReader(bytes)
  result = reader.readJsonNode()
  reader.finish()

proc compileGuard*(bytes: sink string,
                   registry: PathRegistry = DefaultPathRegistry):
                   CompiledGuard =
  try:
    let json = parseCanonicalJson(bytes)
    let guard = parseGuardExpression(json)
    let errors = validateBooleanExpression(guard, registry, GuardDepthMax,
      GuardNodeMax)
    if errors.len > 0:
      guardInvalid(errors.join("; "))
    result.bytes = move(bytes)
    result.compiled = compileBooleanExpression(guard, registry, GuardDepthMax,
      GuardNodeMax)
  except PolicyParseError as error:
    guardInvalid(error.msg)
  except CanonicalError as error:
    guardInvalid(error.msg)
  except ValueError as error:
    guardInvalid(error.msg)

proc evaluate*(guard: CompiledGuard, ctx: IntentContext): bool =
  if guard.compiled == nil:
    return true
  guard.compiled(ctx)
