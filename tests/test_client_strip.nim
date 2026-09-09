## B2-20: a test for client_strip.nim (OPT-13 half A, commit 56f0d66f).
##
## client_strip.nim is a 360-line hand-written JS/CSS/HTML comment tokenizer
## that server.nim runs INSIDE a `const` block on the client files' staticRead
## content, so it executes at COMPILE TIME (CTFE) and its output is baked
## into the shipped binary. Before this file, `git grep client_strip --
## tests` returned nothing: a mis-parse would silently corrupt every human's
## client with no CI signal. This file is wired into shard_1.nim (see
## tests/test_shard_wiring.nim's tripwire, which fails the whole suite if any
## tests/test_*.nim is not imported by some shard -- memory
## ctf-unwired-test-files-run-dark documents exactly this failure mode
## happening twice already).
##
## DEFINITION OF "tokenizes identically" used below (assertion A): the
## STRIPPED output of each real file must parse to the SAME AST as the
## ORIGINAL, modulo comments and source positions, per a REAL JS parser
## (acorn, via node -- both present in this environment; the check is
## written to skip gracefully with a checkpoint, not fail, if either is
## missing, so the suite's core guarantees never hang on an external
## toolchain elsewhere). This is the strongest available oracle: an earlier
## version of this test instead hand-rolled an independent quote-scanning
## oracle to check that every string/template literal survives byte-for-byte
## -- that approach was ABANDONED after actually running it against the real
## files (not just reasoning about it) surfaced a real gap: chrome_common.js
## line 403 has `/[&<>"]/g`, a regex character class containing a bare,
## unescaped `"`. Correctly skipping over that requires client_strip's own
## regex-vs-division heuristic (the very thing under test), so a naive
## quote-scanner misreads that `"` as opening a string and swallows a huge
## span of subsequent real code looking for the next one. A real parser does
## not have this problem, hence the pivot. Two more checks round out
## assertion A, both parser-independent: a byte-shrinkage measurement (the
## payoff this module exists for), and an idempotency property (stripping
## already-stripped text must be a no-op / fixed point) that is agnostic to
## every blind spot above.

import
  std/[os, osproc, strformat, strutils, unittest],
  helpers,
  ctf/client_strip

# ---------------------------------------------------------------------------
# HTML body extraction helpers (assertion A)
# ---------------------------------------------------------------------------

proc extractInlineScript(html: string): string =
  ## The one genuine inline `<script>...</script>` body in player_client.html
  ## (the two placeholders are `<script src="...">`  which never matches the
  ## bare "<script>" needle).
  let openAt = html.find("<script>")
  doAssert openAt >= 0, "player_client.html has no bare <script> tag anymore"
  let bodyStart = openAt + "<script>".len
  let closeAt = html.find("</script>", bodyStart)
  doAssert closeAt >= 0
  html[bodyStart ..< closeAt]

proc extractStyleBody(html: string): string =
  let openAt = html.find("<style>")
  doAssert openAt >= 0, "player_client.html has no <style> tag anymore"
  let bodyStart = openAt + "<style>".len
  let closeAt = html.find("</style>", bodyStart)
  doAssert closeAt >= 0
  html[bodyStart ..< closeAt]

# ---------------------------------------------------------------------------
# Best-effort real-parser (acorn) semantic-equivalence check
# ---------------------------------------------------------------------------

proc findAcornDir(): string =
  ## acorn is not a project dependency; it may be sitting in the npx cache
  ## from a prior `npx acorn` invocation on this machine. Best-effort only.
  let npxCache = getHomeDir() / ".npm" / "_npx"
  if not dirExists(npxCache): return ""
  for kind, path in walkDir(npxCache):
    if kind == pcDir and dirExists(path / "node_modules" / "acorn"):
      return path / "node_modules"
  ""

proc astEquivalent(original, stripped: string): tuple[ran: bool, same: bool, detail: string] =
  ## Parses both `original` and `stripped` with acorn and deep-compares the
  ## ASTs with source positions stripped out. Returns ran=false (not a test
  ## failure) if node or acorn is not available on this machine.
  let nodeExe = findExe("node")
  let acornModules = findAcornDir()
  if nodeExe.len == 0 or acornModules.len == 0:
    return (false, false, "node or acorn not found on PATH/npx cache")
  let tmpOrig = getTempDir() / "b2strip_orig_" & $getCurrentProcessId() & ".js"
  let tmpStripped = getTempDir() / "b2strip_stripped_" & $getCurrentProcessId() & ".js"
  # ".cjs" forces CommonJS (plain `require`) regardless of any nearby
  # package.json "type": "module" -- ".mjs" would force ESM instead and
  # break plain `require` unconditionally, which is what the first run of
  # this test actually hit (ReferenceError: require is not defined).
  let tmpScript = getTempDir() / "b2strip_ast_check_" & $getCurrentProcessId() & ".cjs"
  writeFile(tmpOrig, original)
  writeFile(tmpStripped, stripped)
  writeFile(tmpScript, """
const acorn = require('acorn');
const fs = require('fs');
function parseFile(p) {
  const src = fs.readFileSync(p, 'utf8');
  return acorn.parse(src, { ecmaVersion: 2022, sourceType: 'script', allowReturnOutsideFunction: true });
}
function strip(node) {
  if (Array.isArray(node)) return node.map(strip);
  if (node && typeof node === 'object') {
    const out = {};
    for (const k of Object.keys(node)) {
      if (k === 'start' || k === 'end' || k === 'loc' || k === 'range') continue;
      out[k] = strip(node[k]);
    }
    return out;
  }
  return node;
}
const [, , origPath, strippedPath] = process.argv;
try {
  const a = JSON.stringify(strip(parseFile(origPath)));
  const b = JSON.stringify(strip(parseFile(strippedPath)));
  if (a === b) { console.log('AST_MATCH'); process.exit(0); }
  console.log('AST_MISMATCH');
  process.exit(1);
} catch (e) {
  console.log('AST_ERROR: ' + e.message);
  process.exit(2);
}
""")
  defer:
    removeFile(tmpOrig)
    removeFile(tmpStripped)
    removeFile(tmpScript)
  let cmd = &"NODE_PATH={quoteShell(acornModules)} {quoteShell(nodeExe)} {quoteShell(tmpScript)} {quoteShell(tmpOrig)} {quoteShell(tmpStripped)}"
  let (output, code) = execCmdEx(cmd)
  (true, code == 0 and "AST_MATCH" in output, output.strip())

# ---------------------------------------------------------------------------
# Assertion A: the real client files
# ---------------------------------------------------------------------------

suite "client_strip -- real client files":
  test "stripJsComments on the real .js files: shrinks, idempotent, and AST-equivalent to a real parser":
    for relPath in ["player_controls.js", "player_hud.js", "chrome_common.js",
                     "broadcast_core.js"]:
      let path = GameDir / "client" / relPath
      let original = readFile(path)
      let stripped = stripJsComments(original)

      echo &"{relPath}: {original.len} B -> {stripped.len} B " &
        &"({100 - (stripped.len * 100 div original.len)}% smaller)"
      check stripped.len < original.len

      # Idempotency: nothing left to strip on a second pass.
      check stripJsComments(stripped) == stripped

      # Real-parser AST equivalence -- the "tokenizes identically" proof.
      let (ran, same, detail) = astEquivalent(original, stripped)
      if ran:
        echo &"{relPath}: acorn AST check -> {detail}"
        check same
      else:
        echo &"{relPath}: acorn AST check SKIPPED ({detail})"

  test "stripHtmlComments on the real player_client.html: shrinks, idempotent, and its inline <script> body is AST-equivalent to a real parser":
    let path = GameDir / "client" / "player_client.html"
    let original = readFile(path)
    let stripped = stripHtmlComments(original)

    echo &"player_client.html: {original.len} B -> {stripped.len} B " &
      &"({100 - (stripped.len * 100 div original.len)}% smaller)"
    check stripped.len < original.len
    check stripHtmlComments(stripped) == stripped

    let origScript = extractInlineScript(original)
    let strippedScript = extractInlineScript(stripped)
    check stripJsComments(origScript) == strippedScript  # matches server.nim's own call

    let origStyle = extractStyleBody(original)
    let strippedStyle = extractStyleBody(stripped)
    check stripCssComments(origStyle) == strippedStyle

    let (ran, same, detail) = astEquivalent(origScript, strippedScript)
    if ran:
      echo &"player_client.html inline <script>: acorn AST check -> {detail}"
      check same
    else:
      echo &"player_client.html inline <script>: acorn AST check SKIPPED ({detail})"

# ---------------------------------------------------------------------------
# Assertion B: adversarial fixtures. Every fixture opens with a disposable
# `// fixture banner` line -- client_strip.nim always preserves the FIRST
# comment it sees verbatim (the real files' license headers), so without a
# sacrificial first comment, a fixture containing exactly one real comment
# would have that comment preserved instead of stripped, which would test
# the wrong thing. Each fixture below therefore always has the banner AS THE
# preserved first comment, and its own interesting comment/construct as the
# thing actually exercised.
# ---------------------------------------------------------------------------

suite "client_strip -- adversarial fixtures":
  test "1: `//` inside a string literal is not treated as a comment":
    let src = "// fixture banner\n" &
      "const s = \"http://example.com//not-a-comment\";\n" &
      "const t = 1; // real comment here\n"
    let stripped = stripJsComments(src)
    checkpoint stripped
    check "http://example.com//not-a-comment" in stripped
    check "real comment here" notin stripped
    check "fixture banner" in stripped
    check "const t = 1;" in stripped

  test "2: `/* */` inside a template literal is not treated as a comment":
    let src = "// fixture banner\n" &
      "const s = `a /* not a comment */ b`;\n" &
      "const t = 1; /* real comment */\n"
    let stripped = stripJsComments(src)
    checkpoint stripped
    check "`a /* not a comment */ b`" in stripped
    check "real comment" notin stripped
    check "fixture banner" in stripped

  test "3: a regex literal containing `/*` (inside a char class) is preserved whole":
    let src = "// fixture banner\n" &
      "const re = /[/*]/;\n" &
      "const t = 1; // trailing\n"
    let stripped = stripJsComments(src)
    checkpoint stripped
    check "/[/*]/" in stripped
    check "trailing" notin stripped
    check "fixture banner" in stripped

  test "4: a division operator is not misread as a regex start":
    # Deliberately only ONE '/' between the division and the real trailing
    # comment (an earlier draft of this fixture used "a / 2 / 5", but the
    # SECOND division slash silently absorbed a "always treat '/' as regex"
    # mutation -- the fake regex scan starting at the first slash terminated
    # on the second slash before ever reaching the comment, so that version
    # of this fixture stayed GREEN even with the tokenizer broken exactly
    # the way this test claims to guard against. Caught by actually running
    # the RED verification, not by inspection -- see B2-20's report. This
    # version has no second '/' to hide behind: if '/' after an identifier
    # is ever misread as a regex start, the fake regex's own scan is forced
    # to run all the way into "// trailing"'s first slash looking for a
    # terminator, eating half the real comment marker and leaving "trailing"
    # sitting in the output as bare, unstripped text.
    let src = "// fixture banner\n" &
      "const a = 10; const total = 4; const b = a / total; // trailing\n"
    let stripped = stripJsComments(src)
    checkpoint stripped
    check "a / total" in stripped
    check "trailing" notin stripped
    check "fixture banner" in stripped

  test "5: an unterminated template literal at EOF passes through untouched":
    # Once inside template-literal text, client_strip never interprets `//`
    # or `/*` as comments (correctly -- neither is a comment in real template
    # text either), so an unterminated template simply flows to EOF verbatim.
    # No corruption, no crash, no infinite loop: the whole input is the
    # expected output, byte for byte.
    let src = "// fixture banner\n" &
      "const s = `unterminated template with // fake comment " &
      "and /* fake block */ inside\n"
    let stripped = stripJsComments(src)
    checkpoint stripped
    check stripped == src

  test "6: a nested template `${}` containing a comment strips it":
    let src = "// fixture banner\n" &
      "const s = `outer ${ /* inner comment */ 1 + 2 } end`;\n" &
      "const t = 1; // trailing\n"
    let stripped = stripJsComments(src)
    checkpoint stripped
    check "outer $" in stripped
    check "1 + 2" in stripped
    check "end`;" in stripped
    check "inner comment" notin stripped
    check "trailing" notin stripped
    check "fixture banner" in stripped

  test "7 (bonus): stripHtmlComments recurses into <script>/<style> bodies and leaves src= placeholders untouched":
    # Each recursive stripJsComments/stripCssComments call gets its OWN fresh
    # first-comment slot (independent of the outer HTML-level one and of each
    # other) -- hence a sacrificial "// js banner" here too, same reasoning
    # as every fixture above.
    let src = "<!-- fixture banner -->\n" &
      "<style>/* KEEP_CSS_FIRST */ .a { color: red; } /* DROP_CSS_SECOND */</style>\n" &
      "<script src=\"external.js\"></script>\n" &
      "<script>// js banner\nconst s = \"</scr\" + \"ipt is not a real close tag here\"; " &
      "// DROP_JS_TRAILING\n</script>\n" &
      "<!-- DROP_HTML_SECOND -->\n"
    let stripped = stripHtmlComments(src)
    checkpoint stripped
    check "fixture banner" in stripped              # first HTML comment preserved
    check "DROP_HTML_SECOND" notin stripped          # later HTML comment stripped
    check "KEEP_CSS_FIRST" in stripped               # each <style> body gets its
    check "DROP_CSS_SECOND" notin stripped           # own fresh first-comment slot
    check "DROP_JS_TRAILING" notin stripped          # inline <script> body stripped
    check "<script src=\"external.js\"></script>" in stripped  # src= placeholder untouched
    # the split string survives whole -- the real </script> was found, not a
    # false match on the "</scr" + "ipt" text (see fixture 8 for the case
    # where the split does NOT protect it)
    check "\"</scr\" + \"ipt is not a real close tag here\"" in stripped

  test "8 (documents a known hazard, not a client_strip bug): a literal contiguous `</script` inside an inline <script> body is found by the same byte-level scan a real HTML5 parser uses":
    # HTML5's tokenizer treats <script> as a RAW TEXT element: it ends the
    # element at the first literal byte sequence "</script" (case
    # insensitive), with NO awareness of JS syntax -- a real browser would
    # mis-end the element at the exact same point given this source.
    # client_strip's findCloseTag deliberately matches that spec behaviour
    # rather than trying to be JS-aware. VERIFIED (by actually running this
    # fixture, not by hand-tracing): the false split here happens to land
    # such that the body-up-to-the-false-tag, the (byte-identical) fake
    # close-tag text, and the untouched remainder reassemble into EXACTLY
    # the original bytes -- client_strip fails SAFE (verbatim passthrough,
    # no corruption) rather than mangling the file. The cost is silent: the
    # "// never reached" comment sits downstream of the false split, so it
    # is no longer treated as JS and does NOT get stripped either -- it
    # merely survives unchanged, same as everything else here. This is
    # exactly why server.nim's own splice path runs defuseScriptClose on
    # player_controls.js/player_hud.js before inlining them, rather than
    # relying on this safe-but-silent fallback: a literal "</script" is
    # already a landmine for a real browser, comment-stripped or not.
    let src = "<!-- fixture banner -->\n" &
      "<script>const s = \"</script>\"; // never reached\n</script>\n" &
      "<p>after</p>\n"
    let stripped = stripHtmlComments(src)
    checkpoint stripped
    check stripped == src  # safe passthrough, not corruption, on this collision

suite "shard wiring proof":
  test "client_strip is exported and callable from this test binary":
    # Trivial existence check: if the import above failed to resolve
    # ctf/client_strip, this whole module would not compile, and
    # test_shard_wiring's tripwire (tests/test_shard_wiring.nim) fails the
    # suite the moment this file is not imported by some shard.
    check stripJsComments("// x\n").len > 0
