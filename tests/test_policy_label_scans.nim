import
  std/[algorithm, os, sequtils, sets, strutils, tables, unittest],
  ctf/labels

# The CONSUMER half of the sprite-label contract.
#
# `tests/test_label_contract.nim` guards the producer half: every label in
# `labels.PolicyScannedLabels` must actually be emitted by the engine. That
# list is HAND-MAINTAINED, and `labels.nim` says so outright — nothing forces
# a new `spriteObjectsWithLabel` call in the bot to be registered there, so
# the guard only ever covered the labels somebody remembered to add.
#
# This test closes that gap from the other end. It DERIVES the scanned set by
# reading `players/baseline/baseline.nim` itself — every `spriteObjectsWithLabel`
# argument, resolved to the manifest pattern it builds — and asserts each one
# is a label the engine actually emits. Nothing to remember, nothing to
# register: add a scan and it is covered on the next run.
#
# Why it matters, concretely. An exact-match scan for a label the engine no
# longer emits returns an EMPTY SEQ, forever, and nothing else breaks: no
# exception, no warning, no failing test, no log line. The policy simply stops
# seeing a whole category of object, and the field symptom looks like a
# strategy regression rather than an engine rename. That has cost this policy
# a league round more than once — the 0.7.x spray-can reskin renamed
# `plasma arc` -> `spray can` and the bot's pickup scans matched nothing until
# somebody noticed the field was collecting spray cans 5x more often than we
# were.
#
# The test is pure text analysis over two source files and the manifest: no
# sim, no renderer, no assets. It is deliberately STRICT — an argument
# expression it cannot resolve is a FAILURE, not a skip, because a silent skip
# would reintroduce exactly the blind spot this exists to remove. If you write
# a scan in a shape the resolver does not know, teach the resolver.

const
  RepoRoot = currentSourcePath.parentDir.parentDir
  ManifestPath = currentSourcePath.parentDir / "label_manifest.txt"
  LabelsPath = RepoRoot / "src" / "ctf" / "labels.nim"
  PolicyPath = RepoRoot / "players" / "baseline" / "baseline.nim"
  ScanProc = "spriteObjectsWithLabel("

const PolicyColorVars = [
  ## Identifiers the policy uses to hold a TEAM COLOR token, which the manifest
  ## normalizes to `<color>`. Listed rather than pattern-matched on the name so
  ## a new variable has to be classified deliberately: a color that is NOT in
  ## this list resolves to nothing and fails the test loudly, which is the
  ## correct outcome for `spriteObjectsWithLabel(someNewThing & " flag")`.
  "color", "myColor", "enemyColor", "c", "teamColor", "col",
]

type RetiredScan = object
  ## A scan the policy still contains for a label the engine NO LONGER emits.
  pattern: string   ## the manifest pattern it resolves to
  why: string       ## why the dead call is allowed to stay

const RetiredScans = [
  ## Deliberately-kept scans for RETIRED labels. Each one is dead — it returns
  ## an empty seq on every tick — and each is here because the call sits behind
  ## a live fallback or an OFF tune gate, so deleting it would be churn in the
  ## champion for no behaviour change.
  ##
  ## This list is a two-way guard, and that is the point of it. Being here
  ## exempts a pattern from the "must be emitted" check, but ALSO asserts the
  ## engine really has retired it: if the label comes back to the manifest, the
  ## entry fails and you must rewire the scan instead of leaving a live label
  ## being read by code documented as inert. So an entry cannot rot into a
  ## permanent excuse — it expires the moment the premise stops holding.
  RetiredScan(
    pattern: "aim dot <color>",
    why: "The aim-indicator dots were retired from the renderer. Their three " &
      "readers (observedAim, mateAimBrads, actorsFor's dot attribution) are " &
      "PRE-GV26 fallbacks: the engine now states own aim outright via the " &
      "`own aim <brads>` marker, which ownAimBrads reads first and which " &
      "short-circuits the resync before a dot scan is ever reached, and mate/" &
      "enemy bearings come from aimRotRead's sprite ids. Each dead scan " &
      "yields -1 and the live path takes over, so the calls are harmless — " &
      "but they are also the reason a reader thinks aim intel comes from dots.",
  ),
  RetiredScan(
    pattern: "sword",
    why: "The sword was replaced by the plasma arc (now the spray can) at " &
      "GameVersion 15; no engine since emits a sword pickup. The scan is " &
      "gated behind tune.swordAmbush, which is off in every shipped bundle, " &
      "so it is a tombstone rather than a live read.",
  ),
  RetiredScan(
    pattern: "sword carried",
    why: "The carry marker for the same retired sword. This scan is NOT " &
      "gated — it runs every frame and always leaves iHaveSword false — but " &
      "false is the correct value on any engine since GameVersion 15, and " &
      "every use is `not iHaveSword` or an `and iHaveSword` under the same " &
      "off swordAmbush gate.",
  ),
]

proc readLabelConsts(): Table[string, string] =
  ## `LabelXxx* = "literal"` from src/ctf/labels.nim, so the resolver below
  ## shares ONE definition with the engine instead of restating the strings.
  ## Scraped from source rather than imported because the resolver needs to go
  ## from the identifier NAME (which is what appears in the policy's call) to
  ## its value, and Nim has no runtime name->const lookup.
  result = initTable[string, string]()
  for rawLine in readFile(LabelsPath).splitLines():
    let line = rawLine.strip()
    if not line.startsWith("Label"):
      continue
    let eq = line.find("* = \"")
    if eq < 0:
      continue
    let
      name = line[0 ..< eq]
      rest = line[eq + 5 .. ^1]
      close = rest.find('"')
    if close >= 0:
      result[name] = rest[0 ..< close]

proc splitTopLevel(expr: string, sep: char): seq[string] =
  ## Split on `sep` at bracket depth 0 and outside string literals, so
  ## `"a" & f(x, y) & "b"` splits into three terms and `"a, b"` does not split
  ## at all.
  var
    depth = 0
    inStr = false
    cur = ""
  for ch in expr:
    if inStr:
      cur.add(ch)
      if ch == '"':
        inStr = false
      continue
    case ch
    of '"':
      inStr = true
      cur.add(ch)
    of '(', '[', '{':
      inc depth
      cur.add(ch)
    of ')', ']', '}':
      dec depth
      cur.add(ch)
    else:
      if ch == sep and depth == 0:
        result.add(cur.strip())
        cur = ""
      else:
        cur.add(ch)
  result.add(cur.strip())

proc resolveTerm(term: string, consts: Table[string, string]): string =
  ## One `&`-separated term of a label expression, as the manifest PATTERN
  ## fragment it contributes. Returns "" for anything unrecognized — the
  ## caller turns that into a test failure rather than a skip.
  let t = term.strip()
  if t.len >= 2 and t[0] == '"' and t[^1] == '"':
    return t[1 ..< t.high]                     # string literal, verbatim
  if t in consts:
    return consts[t]                           # Label* const from labels.nim
  if t in PolicyColorVars or t.startsWith("TeamColorNames["):
    return "<color>"
  if t.startsWith("$"):
    # A stringified number. The hp bar's DENOMINATOR is the one number the
    # manifest keeps literal (see normalizeLabel in test_label_contract.nim):
    # it is a fixed contract value two constants must agree on, not a varying
    # count, so `$MaxHp` resolves to that value and a drift shows up here as
    # well as in the sibling denominator check.
    if t == "$MaxHp":
      return $LabelHpBarSegments
    return "<n>"
  if t.startsWith("(if ") and t.endsWith(")"):
    # A facing choice, `(if facingRight: " right" else: " left")`. Accept it
    # only when BOTH branches really are the side tokens — any other if-expr
    # falls through to the failure path.
    let sides = [" " & LabelSideRight, " " & LabelSideLeft]
    var hits = 0
    for side in sides:
      if ("\"" & side & "\"") in t:
        inc hits
    if hits == sides.len:
      return " <side>"
  ""

proc resolveExpr(expr: string, consts: Table[string, string]): string =
  ## A whole `spriteObjectsWithLabel` argument as a manifest pattern, or "".
  for term in expr.splitTopLevel('&'):
    let piece = resolveTerm(term, consts)
    if piece.len == 0:
      return ""
    result.add(piece)

proc argExprs(source: string, callStart: int): seq[string] =
  ## The argument expression at one call site, whitespace-collapsed. A bare
  ## identifier is chased BACKWARDS to the `let x = ...` or `for x in [...]`
  ## that bound it — the policy hoists a couple of label builds into a local,
  ## and a resolver that gave up on those would silently cover less than it
  ## appears to.
  var
    depth = 1
    i = callStart
  while i < source.len and depth > 0:
    case source[i]
    of '(': inc depth
    of ')': dec depth
    else: discard
    inc i
  let expr = source[callStart ..< i - 1].splitWhitespace().join(" ")
  if expr.len == 0:
    return
  # Not a bare identifier? Use it as written.
  if not expr.allCharsInSet({'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}):
    return @[expr]
  # Bare identifier: find its binding in the preceding lines.
  let before = source[0 ..< callStart].splitLines()
  for back in countdown(before.high, max(0, before.len - 40)):
    let line = before[back].strip()
    if line.startsWith("let " & expr & " ="):
      return @[line[("let " & expr & " =").len .. ^1].strip()]
    if line.startsWith("for " & expr & " in "):
      var list = line[("for " & expr & " in ").len .. ^1].strip()
      if list.endsWith(":"):
        list = list[0 ..< list.high].strip()
      if list.startsWith("[") and list.endsWith("]"):
        return list[1 ..< list.high].splitTopLevel(',')
      return @[list]
  @[expr]                                      # unbound: fail downstream

type Scan = object
  expr: string
  line: int
  pattern: string

proc policyScans(consts: Table[string, string]): seq[Scan] =
  ## Every exact-match label scan in the reference policy, resolved.
  let source = readFile(PolicyPath)
  var search = 0
  while true:
    let at = source.find(ScanProc, start = search)
    if at < 0:
      break
    search = at + ScanProc.len
    let lineNo = source[0 ..< at].count('\n') + 1
    for expr in source.argExprs(search):
      result.add(Scan(
        expr: expr, line: lineNo, pattern: expr.resolveExpr(consts)))

proc readManifest(): HashSet[string] =
  for rawLine in readFile(ManifestPath).splitLines():
    let line = rawLine.strip()
    if line.len > 0 and not line.startsWith("#"):
      result.incl(line)

suite "policy label scans":
  let
    consts = readLabelConsts()
    manifest = readManifest()
    scans = policyScans(consts)

  test "the scan extractor still finds the policy's scans":
    # A vacuous pass is the one way this whole test can lie: if the policy
    # moves, gets renamed, or wraps its scans in a helper, every check below
    # passes over an EMPTY list and reports green while covering nothing.
    # Pin a floor so that failure is loud.
    check fileExists(PolicyPath)
    check consts.len >= 10
    check manifest.len >= 50
    checkpoint("resolved " & $scans.len & " scan sites in " & PolicyPath)
    check scans.len >= 20

  test "every scanned label expression resolves to a manifest pattern":
    # Deliberately a failure and not a skip: an expression the resolver cannot
    # read is an UNCHECKED scan, which is the blind spot this test exists to
    # remove. Teach resolveTerm the new shape instead of relaxing this.
    var bad: seq[string]
    for scan in scans:
      if scan.pattern.len == 0:
        bad.add("  baseline.nim:" & $scan.line & "  " & scan.expr)
    if bad.len > 0:
      checkpoint("\nUNRESOLVABLE LABEL EXPRESSIONS:\n" & bad.join("\n") & """

    These calls pass a label shape this test cannot turn into a manifest
    pattern, so nothing checks that the engine still emits what they ask for.
    Add the shape to resolveTerm/argExprs in tests/test_policy_label_scans.nim.
""")
      fail()

  test "every label the policy exact-match scans is emitted by the engine":
    let retired = RetiredScans.mapIt(it.pattern).toHashSet()
    var bad: seq[string]
    for scan in scans:
      if scan.pattern.len == 0 or scan.pattern in retired:
        continue
      if scan.pattern notin manifest:
        bad.add("  baseline.nim:" & $scan.line & "  " & scan.expr &
          "\n      -> \"" & scan.pattern & "\"")
    if bad.len > 0:
      bad.sort()
      checkpoint("\nPOLICY SCANS A LABEL THE ENGINE DOES NOT EMIT:\n" &
        bad.deduplicate().join("\n") & """

    spriteObjectsWithLabel matches EXACTLY, so each of these returns an empty
    seq on every tick of every game — with no exception, no warning and no
    other failing test. The policy is blind to whatever the label named.
    Fix one of three ways:
      * the label was RENAMED  -> scan the new name (via a const in
        src/ctf/labels.nim, never a hand-written string);
      * the label was DROPPED by mistake -> restore it in src/ctf/global.nim;
      * the label is genuinely RETIRED -> delete the scan, or register it in
        RetiredScans above with the reason the dead call may stay.
""")
      fail()

  test "every retired scan names a label the engine really has retired":
    # The other direction, so RetiredScans cannot rot into a blanket excuse.
    # If a retired label comes BACK, the exemption is wrong and the scan needs
    # rewiring rather than an entry here.
    for entry in RetiredScans:
      if entry.pattern in manifest:
        checkpoint("\nRETIRED SCAN IS LIVE AGAIN: \"" & entry.pattern & "\"\n" &
          "    It is exempted in RetiredScans because:\n      " & entry.why &
          "\n" & """
    But tests/label_manifest.txt says the engine emits it today, so the
    premise no longer holds. Drop the RetiredScans entry and wire the scan up
    for real — code documented as inert is now reading live observations.
""")
        fail()

  test "every retired scan is still present in the policy":
    # And the third direction: an entry whose scan has since been deleted is
    # dead weight that makes the exemption list look bigger than the debt.
    let seen = scans.mapIt(it.pattern).toHashSet()
    for entry in RetiredScans:
      if entry.pattern notin seen:
        checkpoint("\nSTALE RetiredScans ENTRY: \"" & entry.pattern &
          "\"\n    No scan in " & PolicyPath & " resolves to it any more." &
          " Delete the entry.")
        fail()
