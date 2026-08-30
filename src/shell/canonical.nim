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

import std/[json, algorithm, math, strutils]

proc canonicalFloat*(value: float): string =
  ## The canonical spelling of a JSON float — ONE grammar every language
  ## reproduces (this proc is the reference implementation):
  ##
  ## - NaN and the infinities are not JSON and raise; a producer must never
  ##   emit them (the guard language likewise rejects non-finite literals).
  ## - Zero (negative zero included) is "0.0".
  ## - The digits are always the shortest round-trip decimal
  ##   (Ryu/Schubfach — what Nim's `$`, ECMAScript, Rust and modern C++
  ##   produce), leading and trailing zeros stripped.
  ## - PLAIN notation for 1e-6 <= |x| < 1e21, with an integral value
  ##   keeping its ".0" (JSON cannot distinguish 24 from 24.0, so the
  ##   producer's type decides the spelling).
  ## - EXPONENT notation outside that interval (Appendix P.1 permits any
  ##   finite number, so no magnitude is refused):
  ##   `d[.ddd]e<sign><exponent>` — one digit before the point, the sign
  ##   always present ('+' or '-'), the exponent unpadded. "1e-7",
  ##   "1.5e-7", "1e+21", "2.5e+30".
  if value.classify in {fcNan, fcInf, fcNegInf}:
    raise newException(ValueError, "non-finite floats are not encodable")
  if value == 0.0:
    return "0.0"
  # Extract the shortest digits and the decimal point position from Nim's
  # shortest representation, whichever notation it chose.
  var text = $value
  var negative = false
  if text[0] == '-':
    negative = true
    text = text[1 .. ^1]
  var mantissa = text
  var exp10 = 0
  let eIdx = text.find({'e', 'E'})
  if eIdx >= 0:
    mantissa = text[0 ..< eIdx]
    exp10 = parseInt(text[eIdx + 1 .. ^1])
  let dotPos = mantissa.find('.')
  let intLen = if dotPos < 0: mantissa.len else: dotPos
  var digits = mantissa.replace(".", "")
  var pointAt = intLen + exp10   # the point sits before digits[pointAt]
  var lead = 0
  while lead < digits.len - 1 and digits[lead] == '0':
    inc lead
  digits = digits[lead .. ^1]
  pointAt -= lead
  while digits.len > 1 and digits[^1] == '0':
    digits.setLen(digits.len - 1)
  let magnitude = abs(value)
  if magnitude >= 1e-6 and magnitude < 1e21:
    if pointAt <= 0:
      result = "0." & repeat("0", -pointAt) & digits
    elif pointAt >= digits.len:
      result = digits & repeat("0", pointAt - digits.len) & ".0"
    else:
      result = digits[0 ..< pointAt] & "." & digits[pointAt .. ^1]
  else:
    let canonicalExp = pointAt - 1
    result = $digits[0]
    if digits.len > 1:
      result.add("." & digits[1 .. ^1])
    result.add("e")
    result.add(if canonicalExp >= 0: "+" else: "-")
    result.add($abs(canonicalExp))
  if negative:
    result = "-" & result

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
    result = canonicalFloat(node.getFloat())
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
