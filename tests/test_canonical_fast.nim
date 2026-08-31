## The fast canonical path (src/shell/canonical_fast.nim) held to the
## reference implementation (src/shell/canonical.nim, normative):
##
## - EQUIVALENCE: on every golden in tests/fixtures/shell/, the streaming
##   writer's bytes == canonicalJson's bytes == the file, and a full
##   reader->writer echo (parse events, re-emit) reproduces the file too,
##   proving the reader yields complete information without a tree.
## - REJECTION: the reader refuses everything non-canonical — every
##   strict prefix of every golden (truncation, exhaustively), whitespace,
##   unsorted or duplicate keys, non-canonical integer/float/string
##   spellings, malformed uint64 identities, bad escapes, trailing bytes,
##   over-deep nesting.

import std/[json, os, unittest]
import ../src/shell/canonical
import ../src/shell/canonical_fast

const FixtureDir = "tests" / "fixtures" / "shell"

const GoldenFiles = [
  "intent.golden.json", "intent_safe_hold.golden.json",
  "combat_policy.golden.json",
  "status_module_accepted.golden.json", "status_module_ready.golden.json",
  "status_module_rejected.golden.json", "status_call_accepted.golden.json",
  "status_call_rejected.golden.json", "status_retune_refused.golden.json",
  "status_play_faulted.golden.json",
  "control_view.golden.json", "control_context.golden.json",
  "play_context.golden.json", "play_view.golden.json",
  "manifest_edge_ride.golden.json", "manifest_pact.golden.json",
  "ladder_call.golden.json",
  "floats.golden.json"
]

proc echoValue(r: var CanonicalReader, w: var CanonicalWriter) =
  ## Reader -> writer round trip: every event re-emitted through the
  ## streaming writer. Byte equality with the source is the proof that
  ## the reader loses nothing and the writer spells everything the
  ## reference way.
  case r.peekKind()
  of cvObject:
    r.enterObject()
    w.beginObject()
    var key: string
    while r.nextKey(key):
      w.key(key)
      echoValue(r, w)
    w.endObject()
  of cvArray:
    r.enterArray()
    w.beginArray()
    while r.nextElement():
      echoValue(r, w)
    w.endArray()
  of cvString: w.addString(r.readString())
  of cvInt: w.addInt(r.readInt())
  of cvFloat: w.addFloat(r.readFloat())
  of cvBool: w.addBool(r.readBool())
  of cvNull:
    r.readNull()
    w.addNull()

proc rejects(bytes: string): bool =
  try:
    validateCanonical(bytes)
    false
  except CanonicalError:
    true

suite "canonical_fast: equivalence with canonical.nim":
  test "writer reproduces every golden byte-for-byte (== canonicalJson)":
    for name in GoldenFiles:
      let bytes = readFile(FixtureDir / name)
      let node = parseJson(bytes)
      var w = initCanonicalWriter()
      w.addJsonNode(node)
      let fast = w.take()
      checkpoint(name)
      check fast == bytes
      check fast == canonicalJson(node)

  test "reader accepts every golden and echoes it byte-for-byte":
    for name in GoldenFiles:
      let bytes = readFile(FixtureDir / name)
      checkpoint(name)
      validateCanonical(bytes)
      var r = initCanonicalReader(bytes)
      var w = initCanonicalWriter(bytes.len)
      echoValue(r, w)
      r.finish()
      check w.take() == bytes

  test "writer uint64 identities match uint64Key's spelling":
    for value in [0'u64, 9007199254740991'u64, 9007199254740992'u64,
                  high(uint64)]:
      var w = initCanonicalWriter()
      w.addUint64(value)
      check w.take() == canonicalJson(uint64Key(value))

  test "writer floats match canonicalFloat across the goldens' grammar":
    for value in [0.0, -0.0, 0.5, 24.0, -2.5, 0.000001,
                  0.3333333333333333, 1e-7, 1.5e-7, 1e21, 2.5e30, 1e-100]:
      var w = initCanonicalWriter()
      w.addFloat(value)
      check w.take() == canonicalFloat(value)

suite "canonical_fast: writer contract":
  test "field helpers and reset produce stable bytes":
    var w = initCanonicalWriter()
    for _ in 0 .. 1:
      w.beginObject()
      w.field("alive", true)
      w.field("hp", 3'i64)
      w.field("hp_frac", 0.5)
      w.fieldUint64("mark", high(uint64))
      w.field("name", "a\"b\nc")
      w.key("point")
      w.beginArray()
      w.addInt(512)
      w.addInt(288)
      w.endArray()
      w.endObject()
      check w.take() ==
        """{"alive":true,"hp":3,"hp_frac":0.5,""" &
        """"mark":"18446744073709551615","name":"a\"b\nc",""" &
        """"point":[512,288]}"""
      w.reset()

  when compileOption("assertions"):
    test "out-of-order keys are caught at the writer (debug assert)":
      var w = initCanonicalWriter()
      w.beginObject()
      w.key("b")
      w.addInt(1)
      expect AssertionDefect:
        w.key("a")

suite "canonical_fast: reader rejection":
  test "every strict prefix of every golden is rejected (truncation)":
    for name in GoldenFiles:
      let bytes = readFile(FixtureDir / name)
      for cut in 0 ..< bytes.len:
        if not rejects(bytes[0 ..< cut]):
          checkpoint(name & " accepted a prefix of " & $cut & " bytes")
          check false
    check true

  test "trailing bytes after the root value are rejected":
    for tail in ["x", " ", "\n", "{}", "1"]:
      check rejects("{}" & tail)

  test "whitespace anywhere is non-canonical":
    for bad in [" {}", "{} ", "{\"a\":1, \"b\":2}", "{\"a\" :1}",
                "{\"a\": 1}", "[1, 2]", "[ ]", "{ }", "\t0", "0\n"]:
      checkpoint(bad)
      check rejects(bad)

  test "unsorted and duplicate keys are rejected":
    check rejects("""{"b":1,"a":2}""")
    check rejects("""{"a":1,"a":2}""")
    check rejects("""{"ab":1,"a":2}""")

  test "structurally malformed inputs are rejected":
    for bad in ["", ",", "}", "]", "{", "[", "{\"a\":}", "{:1}", "{1:2}",
                "[1,]", "[,1]", "{\"a\":1,}", "{\"a\"1}", "[1 2]",
                "{\"a\":1", "\"abc"]:
      checkpoint(bad)
      check rejects(bad)

  test "non-canonical integer spellings are rejected":
    for bad in ["01", "-0", "+1", "007", "--1", "1-",
                "9223372036854775808", "-9223372036854775809"]:
      checkpoint(bad)
      check rejects(bad)
    validateCanonical("9223372036854775807")
    validateCanonical("-9223372036854775808")
    validateCanonical("0")

  test "non-canonical float spellings are rejected":
    for bad in ["1.50", "0.10", "24.00", "1E5", "1e5", "1e+5", "1.",
                ".5", "00.5", "-0.0", "0.0000001", "1.0e+21", "1e21",
                "1.5e+007", "1e+308000", "1e"]:
      checkpoint(bad)
      check rejects(bad)
    # The canonical spellings of the same values pass.
    for good in ["1.5", "0.1", "24.0", "100000.0", "0.0", "1e-7",
                 "1e+21", "1.5e-7"]:
      checkpoint(good)
      validateCanonical(good)

  test "non-canonical string spellings and bad escapes are rejected":
    for bad in ["\"\\u0041\"",     # \u for a printable char
                "\"\\/\"",          # solidus escape (escapeJson never emits)
                "\"\\u000B\"",      # canonical spelling is \u000b
                "\"a\tb\"",         # raw control character
                "\"\\x\"", "\"\\u12g4\"", "\"\\u12\""]:
      checkpoint(bad)
      check rejects(bad)
    for good in ["\"\"", "\"a\\\"b\\nc\"", "\"\\u000b\"", "\"\\u001F\"",
                 "\"héllo\""]:
      checkpoint(good)
      validateCanonical(good)

  test "literal misspellings are rejected":
    for bad in ["True", "nul", "FALSE", "None", "NaN", "Infinity"]:
      checkpoint(bad)
      check rejects(bad)

  test "nesting past MaxCanonicalDepth is rejected; below it passes":
    var deep = ""
    for _ in 0 ..< MaxCanonicalDepth + 1:
      deep.add('[')
    deep.add('1')
    for _ in 0 ..< MaxCanonicalDepth + 1:
      deep.add(']')
    check rejects(deep)
    var legal = ""
    for _ in 0 ..< MaxCanonicalDepth:
      legal.add('[')
    legal.add('1')
    for _ in 0 ..< MaxCanonicalDepth:
      legal.add(']')
    validateCanonical(legal)

suite "canonical_fast: typed reads":
  test "readUint64 enforces the identity spelling rules":
    proc readsAs(bytes: string): uint64 =
      var r = initCanonicalReader(bytes)
      result = r.readUint64()
      r.finish()
    check readsAs("\"0\"") == 0'u64
    check readsAs("\"9007199254740991\"") == 9007199254740991'u64
    check readsAs("\"9007199254740992\"") == 9007199254740992'u64
    check readsAs("\"18446744073709551615\"") == high(uint64)
    for bad in ["7",                        # numeric, not a string
                "\"\"", "\"07\"", "\"12x\"", "\"-1\"", "\" 1\"",
                "\"18446744073709551616\"",  # 2^64
                "\"111111111111111111111\""]: # 21 digits
      checkpoint(bad)
      var r = initCanonicalReader(bad)
      expect CanonicalError:
        discard r.readUint64()

  test "readNumber accepts both canonical number spellings":
    proc numberOf(bytes: string): float =
      var r = initCanonicalReader(bytes)
      result = r.readNumber()
      r.finish()
    check numberOf("24") == 24.0
    check numberOf("24.0") == 24.0
    check numberOf("-2.5") == -2.5
    check numberOf("1e-7") == 1e-7

  test "a known-shape walk reads the intent golden's typed fields":
    ## The lane-C driving pattern: enterObject / nextKey / typed reads /
    ## skipValue for the rest.
    var r = initCanonicalReader(readFile(FixtureDir / "intent.golden.json"))
    var kind, schema, profile: string
    var arrive = -1.0
    var v = 0'i64
    r.enterObject()
    var key: string
    while r.nextKey(key):
      case key
      of "arrive_radius": arrive = r.readNumber()
      of "kind": kind = r.readString()
      of "schema": schema = r.readString()
      of "profile": profile = r.readString()
      of "v": v = r.readInt()
      else: r.skipValue()
    r.finish()
    check schema == "intent" and v == 1
    check kind == "navigate_to" and profile == "hunter"
    check arrive == 24.0
