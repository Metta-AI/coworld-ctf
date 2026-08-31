## The fast path for the shell's canonical JSON encoding (canonical.nim,
## Appendix P.1) — the same one grammar, produced and consumed WITHOUT a
## `JsonNode` tree, because the tree is what the P0 measurements caught:
## ~62 µs per emit validation (ratified P3 acceptance ≤15 µs) and 5.77 ms
## for the 32-seat view encode (ratified P1 acceptance ≤2.5 ms) were both
## std/json tree costs, not contract costs.
##
## `canonical.nim` stays the NORMATIVE reference; this module changes no
## grammar. The two spelling procedures are shared, never copied:
## `canonicalFloat` is imported from canonical.nim and std/json's
## `escapeJson`/`escapeJsonUnquoted` (what canonicalJson calls) do the
## string escaping — so equal spelling is equality by construction, and
## the tests additionally prove writer output byte-equal to
## `canonicalJson` on every golden.
##
## Two halves:
##
## - `CanonicalWriter`: a direct byte writer. Callers stream structure
##   (`beginObject`/`key`/`endObject`, `beginArray`/`endArray`) and
##   scalars (`addInt`, `addUint64`, `addFloat`, `addString`, `addBool`,
##   `addNull`, or the `field` shorthands); bytes accumulate in one
##   buffer. Key sortedness is BY CONSTRUCTION: callers emit keys in
##   byte-ascending order, and `key` asserts it (assertions are on in
##   -d:release CI builds; only -d:danger drops the check).
## - `CanonicalReader`: a single-pass pull parser over canonical bytes
##   that yields values without building a tree, rejecting everything
##   non-canonical as it goes: any whitespace, unsorted or duplicated
##   keys, a non-canonical integer/float/string spelling, a malformed
##   uint64 identity, truncation, trailing bytes. It is the ENGINE for
##   §6.1 emit validation — a validator walks a known shape with
##   `enterObject`/`nextKey`/`readInt`/... and `skipValue` for the
##   fields a tolerant (`additionalProperties: true`) decoder ignores.
##
## Depth is capped at `MaxCanonicalDepth` (64): every shell schema is a
## few levels deep (`ParamNestingMax` bounds the deepest), so the cap is
## an engine safety bound on adversarial emissions, not a grammar rule.

import std/[algorithm, json, math, parseutils, unicode]
import canonical

const MaxCanonicalDepth* = 64

type
  CanonicalError* = object of ValueError

  CanonicalValueKind* = enum
    cvObject, cvArray, cvString, cvInt, cvFloat, cvBool, cvNull

# ---------------------------------------------------------------------------
# CanonicalWriter
# ---------------------------------------------------------------------------

type
  WriterFrame = object
    isObject: bool
    count: int          # values (array) or keys (object) written so far
    keyPending: bool    # object only: key written, its value expected
    lastKey: string     # assertion state for the sorted-keys rule

  CanonicalWriter* = object
    buf: string
    frames: seq[WriterFrame]
    rootDone: bool

proc initCanonicalWriter*(capacity: int = 256): CanonicalWriter =
  result.buf = newStringOfCap(capacity)

proc reset*(w: var CanonicalWriter) =
  ## Clears the writer for reuse, keeping the buffer's capacity — the
  ## per-tick encode path allocates nothing after warm-up.
  w.buf.setLen(0)
  w.frames.setLen(0)
  w.rootDone = false

proc beforeValue(w: var CanonicalWriter) =
  if w.frames.len == 0:
    assert not w.rootDone, "canonical document already holds its one root value"
    w.rootDone = true
  elif w.frames[^1].isObject:
    assert w.frames[^1].keyPending, "an object value needs key() first"
    w.frames[^1].keyPending = false
  else:
    if w.frames[^1].count > 0:
      w.buf.add(',')
    inc w.frames[^1].count

proc beginObject*(w: var CanonicalWriter) =
  w.beforeValue()
  w.frames.add(WriterFrame(isObject: true))
  w.buf.add('{')

proc endObject*(w: var CanonicalWriter) =
  assert w.frames.len > 0 and w.frames[^1].isObject and
    not w.frames[^1].keyPending, "endObject without a matching open object"
  w.frames.setLen(w.frames.len - 1)
  w.buf.add('}')

proc beginArray*(w: var CanonicalWriter) =
  w.beforeValue()
  w.frames.add(WriterFrame(isObject: false))
  w.buf.add('[')

proc endArray*(w: var CanonicalWriter) =
  assert w.frames.len > 0 and not w.frames[^1].isObject,
    "endArray without a matching open array"
  w.frames.setLen(w.frames.len - 1)
  w.buf.add(']')

proc key*(w: var CanonicalWriter, name: string) =
  ## Emits the next object key. Callers own the sorted-key rule: keys
  ## come in strictly ascending byte order (checked here by assert).
  assert w.frames.len > 0 and w.frames[^1].isObject,
    "key() outside an object"
  assert not w.frames[^1].keyPending, "key() while a value is pending"
  if w.frames[^1].count > 0:
    w.buf.add(',')
  when compileOption("assertions"):
    assert w.frames[^1].count == 0 or name > w.frames[^1].lastKey,
      "canonical keys must ascend bytewise: \"" & name & "\" after \"" &
      w.frames[^1].lastKey & "\""
    w.frames[^1].lastKey = name
  inc w.frames[^1].count
  escapeJson(name, w.buf)
  w.buf.add(':')
  w.frames[^1].keyPending = true

proc addInt*(w: var CanonicalWriter, value: int64) =
  w.beforeValue()
  w.buf.addInt(value)

proc addUint64*(w: var CanonicalWriter, value: uint64) =
  ## A 64-bit identity: the decimal STRING spelling (canonical.nim's
  ## `uint64Key`), never a JSON number.
  w.beforeValue()
  w.buf.add('"')
  w.buf.add($value)
  w.buf.add('"')

proc addFloat*(w: var CanonicalWriter, value: float) =
  w.beforeValue()
  w.buf.add(canonicalFloat(value))

proc addString*(w: var CanonicalWriter, value: string) =
  w.beforeValue()
  escapeJson(value, w.buf)

proc addBool*(w: var CanonicalWriter, value: bool) =
  w.beforeValue()
  w.buf.add(if value: "true" else: "false")

proc addNull*(w: var CanonicalWriter) =
  w.beforeValue()
  w.buf.add("null")

proc field*(w: var CanonicalWriter, name: string, value: int64) =
  w.key(name); w.addInt(value)

proc field*(w: var CanonicalWriter, name: string, value: float) =
  w.key(name); w.addFloat(value)

proc field*(w: var CanonicalWriter, name: string, value: string) =
  w.key(name); w.addString(value)

proc field*(w: var CanonicalWriter, name: string, value: bool) =
  w.key(name); w.addBool(value)

proc fieldUint64*(w: var CanonicalWriter, name: string, value: uint64) =
  w.key(name); w.addUint64(value)

proc bytes*(w: CanonicalWriter): lent string =
  ## The encoded bytes so far (complete once every open scope is closed).
  w.buf

proc take*(w: var CanonicalWriter): string =
  ## Moves the finished document out of the writer.
  assert w.frames.len == 0 and w.rootDone, "take() on an unfinished document"
  result = move(w.buf)
  w.reset()

proc addJsonNode*(w: var CanonicalWriter, node: JsonNode) =
  ## Bridge from a `JsonNode` tree: emits the tree under the canonical
  ## rules (sorting keys here, since a tree carries insertion order).
  ## This is the equivalence seam the tests pin against `canonicalJson`,
  ## and a migration aid for producers still holding trees; new fast-path
  ## code streams fields directly instead.
  case node.kind
  of JNull: w.addNull()
  of JBool: w.addBool(node.getBool())
  of JInt: w.addInt(node.getInt())
  of JFloat: w.addFloat(node.getFloat())
  of JString: w.addString(node.getStr())
  of JArray:
    w.beginArray()
    for item in node.elems:
      w.addJsonNode(item)
    w.endArray()
  of JObject:
    var keys = newSeqOfCap[string](node.len)
    for k in node.keys:
      keys.add(k)
    sort(keys)
    w.beginObject()
    for k in keys:
      w.key(k)
      w.addJsonNode(node[k])
    w.endObject()

# ---------------------------------------------------------------------------
# CanonicalReader
# ---------------------------------------------------------------------------

type
  ReaderFrame = object
    isObject: bool
    count: int
    lastKey: string     # sorted+unique key enforcement (normative here)

  CanonicalReader* = object
    data: string
    pos: int
    frames: seq[ReaderFrame]

proc initCanonicalReader*(data: sink string): CanonicalReader =
  result.data = data

proc fail(r: CanonicalReader, msg: string) {.noreturn, noinline.} =
  raise newException(CanonicalError, msg & " at byte " & $r.pos)

proc atEnd(r: CanonicalReader): bool {.inline.} =
  r.pos >= r.data.len

proc cur(r: CanonicalReader): char {.inline.} =
  r.data[r.pos]

proc numberTokenEnd(r: CanonicalReader): int =
  ## First index past the current number token (the next structural
  ## delimiter or end of input). Canonical bytes have no whitespace, so
  ## only ',', '}', ']' can follow a top-of-value token.
  result = r.pos
  while result < r.data.len and r.data[result] notin {',', '}', ']'}:
    inc result

proc peekKind*(r: CanonicalReader): CanonicalValueKind =
  ## Classifies the next value without consuming it. A number token is
  ## scanned to its delimiter to split `cvInt` from `cvFloat` (the
  ## canonical grammar spells them disjointly: a float always carries
  ## '.' or 'e').
  if r.atEnd:
    r.fail("unexpected end of input")
  case r.cur
  of '{': cvObject
  of '[': cvArray
  of '"': cvString
  of 't', 'f': cvBool
  of 'n': cvNull
  of '-', '0' .. '9':
    var i = r.pos
    let stop = r.numberTokenEnd()
    while i < stop:
      if r.data[i] in {'.', 'e', 'E'}:
        return cvFloat
      inc i
    cvInt
  else:
    r.fail("unexpected byte '" & $r.cur & "'")

# --- scalars ---------------------------------------------------------------

proc readInt*(r: var CanonicalReader): int64 =
  ## A canonical integer: optional '-', digits, no leading zero, no "-0",
  ## int64 range (exactly what `$` on Nim's int64 produces).
  if r.atEnd:
    r.fail("unexpected end of input")
  var i = r.pos
  var negative = false
  if r.data[i] == '-':
    negative = true
    inc i
  if i >= r.data.len or r.data[i] notin {'0' .. '9'}:
    r.fail("malformed integer")
  if r.data[i] == '0' and i + 1 < r.data.len and
      r.data[i + 1] in {'0' .. '9'}:
    r.fail("integer has a leading zero")
  var magnitude = 0'u64
  let bound = if negative: 0x8000000000000000'u64
              else: uint64(high(int64))
  while i < r.data.len and r.data[i] in {'0' .. '9'}:
    let digit = uint64(ord(r.data[i]) - ord('0'))
    if magnitude > (bound - digit) div 10:
      r.fail("integer out of int64 range")
    magnitude = magnitude * 10 + digit
    inc i
  if i < r.data.len and r.data[i] notin {',', '}', ']'}:
    r.fail("malformed integer")
  if negative and magnitude == 0:
    r.fail("\"-0\" is not a canonical integer")
  r.pos = i
  result = if negative: cast[int64](0'u64 - magnitude)
           else: int64(magnitude)

proc readFloat*(r: var CanonicalReader): float =
  ## A canonical float. The check is exact and grammar-free: parse the
  ## token, then require `canonicalFloat` (the reference spelling) to
  ## reproduce it byte-for-byte — every non-canonical spelling ("1.50",
  ## "1E5", "-0.0", "24") fails the comparison.
  let stop = r.numberTokenEnd()
  if stop == r.pos:
    r.fail("unexpected end of input")
  var value: BiggestFloat
  let used = parseBiggestFloat(r.data, value, r.pos)
  if used != stop - r.pos:
    r.fail("malformed float")
  if value.classify in {fcNan, fcInf, fcNegInf}:
    r.fail("float out of range")
  let spelling = canonicalFloat(value)
  if spelling.len != stop - r.pos:
    r.fail("non-canonical float spelling")
  for i in 0 ..< spelling.len:
    if spelling[i] != r.data[r.pos + i]:
      r.fail("non-canonical float spelling")
  r.pos = stop
  result = value

proc readNumber*(r: var CanonicalReader): float =
  ## Either canonical number spelling, as a float — the read for schema
  ## `number` fields, where the producer's type picked int or float.
  if r.peekKind() == cvInt:
    float(r.readInt())
  else:
    r.readFloat()

type StringScan = object
  start: int      # first content byte (past the opening quote)
  stop: int       # index of the closing quote
  hasEscape: bool

proc scanString(r: var CanonicalReader): StringScan =
  ## Validates the raw shape of a string token (structure only; escape
  ## canonicality is checked by the decode+re-escape in decodeString).
  if r.atEnd or r.cur != '"':
    r.fail("expected a string")
  result.start = r.pos + 1
  var i = result.start
  while true:
    if i >= r.data.len:
      r.fail("unterminated string")
    let c = r.data[i]
    if c == '"':
      break
    elif c == '\\':
      result.hasEscape = true
      inc i
      if i >= r.data.len:
        r.fail("unterminated string")
      case r.data[i]
      of '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
        inc i
      of 'u':
        if i + 4 >= r.data.len:
          r.fail("unterminated string")
        for k in 1 .. 4:
          if r.data[i + k] notin {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}:
            r.fail("bad \\u escape")
        i += 5
      else:
        r.fail("bad escape '\\" & $r.data[i] & "'")
    elif ord(c) < 0x20:
      r.fail("raw control character in string")
    else:
      inc i
  result.stop = i

proc decodeString(r: var CanonicalReader, scan: StringScan,
                  into: var string) =
  ## Decodes a scanned token and enforces spelling canonicality: the
  ## decoded value re-escaped through std/json's `escapeJsonUnquoted`
  ## (what canonicalJson emits with) must reproduce the raw bytes, so
  ## "\/" , "A" and every other legal-but-different JSON spelling
  ## is rejected. A token with no backslash is canonical iff it scanned
  ## clean, which scanString already proved.
  into.setLen(0)
  if not scan.hasEscape:
    for i in scan.start ..< scan.stop:
      into.add(r.data[i])
  else:
    var i = scan.start
    while i < scan.stop:
      let c = r.data[i]
      if c != '\\':
        into.add(c)
        inc i
      else:
        inc i
        case r.data[i]
        of '"': into.add('"'); inc i
        of '\\': into.add('\\'); inc i
        of '/': into.add('/'); inc i
        of 'b': into.add('\b'); inc i
        of 'f': into.add('\f'); inc i
        of 'n': into.add('\n'); inc i
        of 'r': into.add('\r'); inc i
        of 't': into.add('\t'); inc i
        of 'u':
          var code = 0
          for k in 1 .. 4:
            let h = r.data[i + k]
            code = code * 16 + (case h
              of '0' .. '9': ord(h) - ord('0')
              of 'a' .. 'f': ord(h) - ord('a') + 10
              else: ord(h) - ord('A') + 10)
          if code < 0x80:
            into.add(char(code))
          else:
            into.add(Rune(code).toUTF8())
          i += 5
        else:
          r.fail("bad escape")   # unreachable: scanString validated
    var reEscaped = newStringOfCap(scan.stop - scan.start)
    escapeJsonUnquoted(into, reEscaped)
    if reEscaped.len != scan.stop - scan.start:
      r.fail("non-canonical string escape")
    for i in 0 ..< reEscaped.len:
      if reEscaped[i] != r.data[scan.start + i]:
        r.fail("non-canonical string escape")
  r.pos = scan.stop + 1

proc readStringInto*(r: var CanonicalReader, into: var string) =
  ## `readString` into a caller-owned buffer (reused across calls, the
  ## validator loop allocates nothing after warm-up).
  let scan = r.scanString()
  r.decodeString(scan, into)

proc readString*(r: var CanonicalReader): string =
  r.readStringInto(result)

proc readUint64*(r: var CanonicalReader): uint64 =
  ## A 64-bit identity: the decimal-string spelling, held to
  ## `parseUint64Key`'s exact rules (string, 1..20 digits, no leading
  ## zero, uint64 range).
  let scan = r.scanString()
  if scan.hasEscape:
    r.fail("uint64 identity has a non-digit")
  let length = scan.stop - scan.start
  if length == 0 or length > 20:
    r.fail("uint64 identity out of range")
  if length > 1 and r.data[scan.start] == '0':
    r.fail("uint64 identity has a leading zero")
  result = 0
  for i in scan.start ..< scan.stop:
    let c = r.data[i]
    if c notin {'0' .. '9'}:
      r.fail("uint64 identity has a non-digit")
    let digit = uint64(ord(c) - ord('0'))
    if result > (high(uint64) - digit) div 10:
      r.fail("uint64 identity out of range")
    result = result * 10 + digit
  r.pos = scan.stop + 1

proc expectLiteral(r: var CanonicalReader, literal: string) =
  if r.pos + literal.len > r.data.len:
    r.fail("unexpected end of input")
  for i in 0 ..< literal.len:
    if r.data[r.pos + i] != literal[i]:
      r.fail("expected \"" & literal & "\"")
  r.pos += literal.len

proc readBool*(r: var CanonicalReader): bool =
  if not r.atEnd and r.cur == 't':
    r.expectLiteral("true")
    true
  else:
    r.expectLiteral("false")
    false

proc readNull*(r: var CanonicalReader) =
  r.expectLiteral("null")

# --- structure -------------------------------------------------------------

proc enterObject*(r: var CanonicalReader) =
  if r.atEnd or r.cur != '{':
    r.fail("expected an object")
  if r.frames.len >= MaxCanonicalDepth:
    r.fail("nesting deeper than MaxCanonicalDepth")
  inc r.pos
  r.frames.add(ReaderFrame(isObject: true))

proc enterArray*(r: var CanonicalReader) =
  if r.atEnd or r.cur != '[':
    r.fail("expected an array")
  if r.frames.len >= MaxCanonicalDepth:
    r.fail("nesting deeper than MaxCanonicalDepth")
  inc r.pos
  r.frames.add(ReaderFrame(isObject: false))

proc nextKey*(r: var CanonicalReader, key: var string): bool =
  ## Advances to the next key of the innermost object. Returns false —
  ## consuming the '}' and closing the scope — when the object ends;
  ## returns true with `key` filled (and ':' consumed) when a value
  ## follows. Enforces strictly ascending byte order, which makes a
  ## duplicated key a rejection too.
  assert r.frames.len > 0 and r.frames[^1].isObject,
    "nextKey() outside an object"
  if r.atEnd:
    r.fail("unterminated object")
  if r.cur == '}':
    inc r.pos
    r.frames.setLen(r.frames.len - 1)
    return false
  if r.frames[^1].count > 0:
    if r.cur != ',':
      r.fail("expected ',' or '}'")
    inc r.pos
  let scan = r.scanString()
  r.decodeString(scan, key)
  if r.frames[^1].count > 0 and key <= r.frames[^1].lastKey:
    r.fail("object keys not in strict ascending order (\"" & key & "\")")
  r.frames[^1].lastKey = key
  inc r.frames[^1].count
  if r.atEnd or r.cur != ':':
    r.fail("expected ':' after a key")
  inc r.pos
  true

proc nextElement*(r: var CanonicalReader): bool =
  ## Advances to the next element of the innermost array: false —
  ## consuming the ']' and closing the scope — at the end, true when a
  ## value follows.
  assert r.frames.len > 0 and not r.frames[^1].isObject,
    "nextElement() outside an array"
  if r.atEnd:
    r.fail("unterminated array")
  if r.cur == ']':
    inc r.pos
    r.frames.setLen(r.frames.len - 1)
    return false
  if r.frames[^1].count > 0:
    if r.cur != ',':
      r.fail("expected ',' or ']'")
    inc r.pos
  inc r.frames[^1].count
  true

proc skipValue*(r: var CanonicalReader) =
  ## Consumes one whole value, validating full canonicality on the way —
  ## the read for fields a tolerant decoder ignores, and (with `finish`)
  ## a whole-document canonicality check.
  case r.peekKind()
  of cvObject:
    r.enterObject()
    var key: string
    while r.nextKey(key):
      r.skipValue()
  of cvArray:
    r.enterArray()
    while r.nextElement():
      r.skipValue()
  of cvString:
    var scratch: string
    r.readStringInto(scratch)
  of cvInt:
    discard r.readInt()
  of cvFloat:
    discard r.readFloat()
  of cvBool:
    discard r.readBool()
  of cvNull:
    r.readNull()

proc finish*(r: var CanonicalReader) =
  ## Asserts the document is complete: every scope closed and no byte
  ## past the single root value (a canonical document is exactly one).
  if r.frames.len > 0:
    r.fail("unclosed scope at end of value")
  if r.pos != r.data.len:
    r.fail("trailing bytes after the root value")

proc validateCanonical*(bytes: sink string) =
  ## One-call whole-document canonicality check: raises `CanonicalError`
  ## unless `bytes` is exactly one canonical JSON value.
  var r = initCanonicalReader(bytes)
  r.skipValue()
  r.finish()
