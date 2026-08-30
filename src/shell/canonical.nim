## The shell's ONE canonical JSON byte encoding (Appendix P.1 of
## docs/designs/strategy-play-calling-shell-2026-08-29.md), shared by every
## producer and consumer so "on change" can mean byte inequality and golden
## fixtures pin bytes, not shapes.
##
## The rules, normatively:
## - Object keys sorted (byte-wise ascending), no insignificant whitespace.
## - Arrays keep their order (ordered-list kinds are meaning; set kinds are
##   sorted + deduplicated BEFORE encoding by their producers).
## - Integers as plain JSON numbers; floats via Nim's shortest-round-trip
##   `$` (an integral float carries its ".0").
## - Every 64-bit identity (uploadId, proposalId, epoch, ordinals,
##   generations) is a decimal STRING with no leading zeros, never a JSON
##   number (§5: a JSON number cannot carry the full uint64 range through
##   common clients).
## - Neutral/absent optional fields are OMITTED (the neutral value is the
##   default, §4.1), so two semantically equal values encode identically.
##
## This module is dependency-free on purpose: the SDK, the server, and the
## test harness all compile it unchanged.

import std/[json, algorithm]


proc canonicalJson*(node: JsonNode): string =
  ## Serializes a JSON tree under the canonical rules above. The tree's
  ## producer is responsible for set-kind sorting and neutral-field
  ## omission; this proc owns key order, spacing, and scalar formatting.
  case node.kind
  of JNull:
    result = "null"
  of JBool:
    result = if node.getBool(): "true" else: "false"
  of JInt:
    result = $node.getInt()
  of JFloat:
    result = $node.getFloat()
  of JString:
    result = escapeJson(node.getStr())
  of JArray:
    result = "["
    for i, item in node.elems:
      if i > 0:
        result.add(",")
      result.add(canonicalJson(item))
    result.add("]")
  of JObject:
    var keys: seq[string]
    for key in node.keys:
      keys.add(key)
    keys.sort()
    result = "{"
    for i, key in keys:
      if i > 0:
        result.add(",")
      result.add(escapeJson(key))
      result.add(":")
      result.add(canonicalJson(node[key]))
    result.add("}")

proc uint64Key*(value: uint64): JsonNode =
  ## The canonical spelling of a 64-bit identity: a decimal string, no
  ## leading zeros, full range. A numeric or malformed spelling is a schema
  ## rejection on decode.
  %($value)

proc parseUint64Key*(node: JsonNode): uint64 =
  ## Decodes the spelling above, rejecting anything non-canonical: not a
  ## string, empty, a leading zero (except "0" itself), a non-digit, or a
  ## value past the uint64 range.
  if node.kind != JString:
    raise newException(ValueError, "uint64 identity must be a string")
  let text = node.getStr()
  if text.len == 0 or text.len > 20:
    raise newException(ValueError, "uint64 identity out of range")
  if text.len > 1 and text[0] == '0':
    raise newException(ValueError, "uint64 identity has a leading zero")
  result = 0
  for ch in text:
    if ch notin {'0' .. '9'}:
      raise newException(ValueError, "uint64 identity has a non-digit")
    let digit = uint64(ord(ch) - ord('0'))
    if result > (high(uint64) - digit) div 10:
      raise newException(ValueError, "uint64 identity out of range")
    result = result * 10 + digit
