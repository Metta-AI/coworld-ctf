## client_strip.nim — build-time comment strip for the inlined client
## (human-play optimization OPT-13, half A).
##
## server.nim inlines client/player_client.html, player_controls.js,
## player_hud.js, chrome_common.js and broadcast_core.js at COMPILE time via
## `staticRead` (see the `Embedded*Html` consts). player_client.html alone
## is 52% JS comments by byte count. This module strips `//` and `/* */` JS
## comments, `/* */` CSS comments, and `<!-- -->` HTML comments from that
## staticRead'd text, called from inside the same `const` block so the
## strip itself runs at compile time (CTFE) and costs nothing at serve
## time. It is a real tokenizer-aware state machine, NOT a regex pass:
## string literals ('...', "..."), template literals (`...` with arbitrary
## `${...}` interpolation nesting), and regex literals are tracked and
## their contents are copied through completely untouched. Any construct
## the scanner cannot classify with confidence (an unterminated string /
## template / comment at EOF) causes it to bail out and copy the remainder
## of the file through verbatim rather than guess.
##
## The first comment encountered in each file (a `/* */` block, or a run of
## consecutive leading `//` lines) is always preserved verbatim — this is
## the license/ownership banner every one of these files opens with.
##
## Regex-vs-division disambiguation: JavaScript's grammar is genuinely
## ambiguous here without a full parser, so this uses the standard
## heuristic (same one real lexers use): a `/` is treated as the start of a
## regex literal only when the previous significant token could NOT have
## produced a value (i.e. we are not immediately after an identifier,
## number, `)`, or `]`) — tracked as `regexAllowed` below, updated after
## every token, with a small keyword list (return/typeof/case/... ) that
## forces regexAllowed=true even though the keyword text itself looks like
## an identifier. Two special cases make the comment side of this safe
## regardless of that heuristic ever being wrong: an empty regex literal
## ("//") is invalid JavaScript, so two consecutive slashes are ALWAYS a
## line comment; and a regex body can never start with `*` ("/*" with
## nothing to quantify is a syntax error), so "/*" is ALWAYS a block
## comment. Both are compile-time facts about the language, not guesses.

import std/strutils

func isIdentChar(c: char): bool {.inline.} =
  c in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '$'}

const RegexAllowedKeywords = [
  "return", "typeof", "instanceof", "in", "of", "new", "delete", "void",
  "throw", "case", "yield", "await", "do", "else", "extends", "default",
  "from"
]

func stripJsComments*(src: string): string =
  ## Strip `//` and `/* */` comments from JavaScript source. Never touches
  ## the contents of '...' / "..." strings, `...` template literals
  ## (including nested `${...}` interpolation, to arbitrary depth), or
  ## /regex/ literals.
  result = newStringOfCap(src.len)
  let n = src.len
  var i = 0
  # Context stack: 'T' = scanning template-literal text, 'I' = scanning code
  # inside a `${...}` interpolation, 'B' = scanning code inside a plain `{}`
  # block/object. We are in "template text" mode iff the stack is non-empty
  # and its top is 'T'; otherwise we are in "code" mode (this also covers
  # top-level code, where the stack is simply empty).
  var stack: seq[char] = @[]
  var regexAllowed = true
  var keywordBuf = ""
  var firstCommentDone = false

  template inTemplateText(): bool = stack.len > 0 and stack[^1] == 'T'

  while i < n:
    let c = src[i]

    if inTemplateText():
      if c == '\\' and i + 1 < n:
        result.add(c); result.add(src[i + 1]); i += 2
      elif c == '`':
        result.add(c); inc i
        discard stack.pop()
      elif c == '$' and i + 1 < n and src[i + 1] == '{':
        result.add("${"); i += 2
        stack.add('I')
        regexAllowed = true
        keywordBuf = ""
      else:
        result.add(c); inc i
      continue

    # ---- code mode from here ----

    if c == '/' and i + 1 < n and src[i + 1] == '*':
      # Block comment. "/*" can never validly open a regex (see module
      # doc), so this is unambiguous regardless of regexAllowed.
      var j = i + 2
      var closed = false
      while j + 1 < n:
        if src[j] == '*' and src[j + 1] == '/':
          closed = true
          j += 2
          break
        inc j
      if not closed:
        result.add(src[i .. ^1])  # unterminated -- bail out safely
        return
      if not firstCommentDone:
        result.add(src[i ..< j])
        firstCommentDone = true
      i = j
      continue

    if c == '/' and i + 1 < n and src[i + 1] == '/':
      # Line comment. "//" can never validly open a regex (empty regex
      # literals are a syntax error), so this is unambiguous too.
      var j = i
      while j < n and src[j] != '\n': inc j
      if not firstCommentDone:
        result.add(src[i ..< j])
        firstCommentDone = true
        # Preserve the whole leading run of consecutive "//" lines as one
        # banner block (player_controls.js's header is 8+ such lines).
        var k = j
        while true:
          var p = k
          if p < n and src[p] == '\n': inc p
          var q = p
          while q < n and (src[q] == ' ' or src[q] == '\t'): inc q
          if q + 1 < n and src[q] == '/' and src[q + 1] == '/':
            var lineEnd = q
            while lineEnd < n and src[lineEnd] != '\n': inc lineEnd
            result.add('\n')
            result.add(src[p ..< lineEnd])
            k = lineEnd
          else:
            break
        i = k
      else:
        i = j  # drop the comment text, keep the newline itself (ASI-safe)
      continue

    if c == '\'' or c == '"':
      let quote = c
      result.add(c); inc i
      var terminated = false
      while i < n:
        if src[i] == '\\' and i + 1 < n:
          result.add(src[i]); result.add(src[i + 1]); i += 2
          continue
        if src[i] == quote:
          result.add(src[i]); inc i
          terminated = true
          break
        if src[i] == '\n':
          break  # unterminated string literal -- not valid JS, bail below
        result.add(src[i]); inc i
      if not terminated:
        result.add(src[i .. ^1])
        return
      regexAllowed = false
      keywordBuf = ""
      continue

    if c == '`':
      result.add(c); inc i
      stack.add('T')
      continue

    if c == '{':
      result.add(c); inc i
      stack.add('B')
      regexAllowed = true
      keywordBuf = ""
      continue

    if c == '}':
      result.add(c); inc i
      if stack.len > 0: discard stack.pop()
      regexAllowed = true
      keywordBuf = ""
      continue

    if c == '/' and regexAllowed:
      # Candidate regex literal. Char-class aware so an unescaped '/'
      # inside `[...]` (e.g. `/[/]/`) does not end it early.
      var j = i + 1
      var inClass = false
      var ok = false
      while j < n:
        let cj = src[j]
        if cj == '\\' and j + 1 < n:
          j += 2
          continue
        if cj == '\n':
          break
        if cj == '[':
          inClass = true
        elif cj == ']':
          inClass = false
        elif cj == '/' and not inClass:
          ok = true
          inc j
          break
        inc j
      if ok:
        while j < n and isIdentChar(src[j]): inc j  # trailing flags
        result.add(src[i ..< j])
        i = j
        regexAllowed = false
        keywordBuf = ""
        continue
      # Not a real regex on this line -- fall through and treat '/' as a
      # plain (division) character rather than guess wrong.

    if isIdentChar(c):
      result.add(c)
      keywordBuf.add(c)
      inc i
      if i >= n or not isIdentChar(src[i]):
        regexAllowed = keywordBuf in RegexAllowedKeywords
        keywordBuf = ""
      continue

    result.add(c)
    inc i
    case c
    of ')', ']':
      regexAllowed = false
    of ' ', '\t', '\r', '\n':
      discard  # whitespace never changes regex-allowed context
    else:
      regexAllowed = true

func stripCssComments*(src: string): string =
  ## Strip `/* */` comments from CSS. CSS has no `//` comments and no
  ## regex/template literals, so this is a much smaller state machine:
  ## just string-literal tracking plus block comments.
  result = newStringOfCap(src.len)
  let n = src.len
  var i = 0
  var firstCommentDone = false
  while i < n:
    let c = src[i]
    if c == '\'' or c == '"':
      let quote = c
      result.add(c); inc i
      var terminated = false
      while i < n:
        if src[i] == '\\' and i + 1 < n:
          result.add(src[i]); result.add(src[i + 1]); i += 2
          continue
        if src[i] == quote:
          result.add(src[i]); inc i
          terminated = true
          break
        result.add(src[i]); inc i
      if not terminated:
        result.add(src[i .. ^1])
        return
      continue
    if c == '/' and i + 1 < n and src[i + 1] == '*':
      var j = i + 2
      var closed = false
      while j + 1 < n:
        if src[j] == '*' and src[j + 1] == '/':
          closed = true
          j += 2
          break
        inc j
      if not closed:
        result.add(src[i .. ^1])
        return
      if not firstCommentDone:
        result.add(src[i ..< j])
        firstCommentDone = true
      i = j
      continue
    result.add(c)
    inc i

func findCloseTag(src: string, fromIdx: int, tagLower: string): int =
  ## Index of the first byte of the matching `</tagLower` close tag
  ## (case-insensitive), searching from `fromIdx`; -1 if none is found.
  let needle = "</" & tagLower
  let n = src.len
  var i = fromIdx
  while i < n:
    if i + needle.len <= n and toLowerAscii(src[i ..< i + needle.len]) == needle:
      return i
    inc i
  -1

func stripHtmlComments*(src: string): string =
  ## Strip `<!-- -->` HTML comments from the shell markup, and recurse into
  ## `<style>...</style>` / inline `<script>...</script>` bodies with the
  ## CSS / JS strippers above. `<script src="...">` tags (no inline body,
  ## e.g. the player_controls.js / player_hud.js placeholders server.nim
  ## splices real content into afterwards) are left exactly as-is.
  result = newStringOfCap(src.len)
  let n = src.len
  var i = 0
  var firstCommentDone = false
  while i < n:
    let c = src[i]
    if c == '<' and i + 4 <= n and src[i ..< i + 4] == "<!--":
      var j = i + 4
      var closed = false
      while j + 3 <= n:
        if src[j] == '-' and src[j + 1] == '-' and src[j + 2] == '>':
          closed = true
          j += 3
          break
        inc j
      if not closed:
        result.add(src[i .. ^1])
        return
      if not firstCommentDone:
        result.add(src[i ..< j])
        firstCommentDone = true
      i = j
      continue
    if c == '<' and i + 6 <= n and toLowerAscii(src[i ..< i + 6]) == "<style" and
        (i + 6 >= n or src[i + 6] in {' ', '\t', '\n', '\r', '>'}):
      var openEnd = i
      while openEnd < n and src[openEnd] != '>': inc openEnd
      if openEnd < n: inc openEnd
      result.add(src[i ..< openEnd])
      let bodyStart = openEnd
      let closeAt = findCloseTag(src, bodyStart, "style")
      if closeAt == -1:
        result.add(src[bodyStart .. ^1])
        return
      result.add(stripCssComments(src[bodyStart ..< closeAt]))
      var tagEnd = closeAt
      while tagEnd < n and src[tagEnd] != '>': inc tagEnd
      if tagEnd < n: inc tagEnd
      result.add(src[closeAt ..< tagEnd])
      i = tagEnd
      continue
    if c == '<' and i + 7 <= n and toLowerAscii(src[i ..< i + 7]) == "<script" and
        (i + 7 >= n or src[i + 7] in {' ', '\t', '\n', '\r', '>'}):
      var openEnd = i
      while openEnd < n and src[openEnd] != '>': inc openEnd
      if openEnd < n: inc openEnd
      let openTag = src[i ..< openEnd]
      result.add(openTag)
      let bodyStart = openEnd
      let closeAt = findCloseTag(src, bodyStart, "script")
      if closeAt == -1:
        result.add(src[bodyStart .. ^1])
        return
      let body = src[bodyStart ..< closeAt]
      if "src=" in toLowerAscii(openTag):
        result.add(body)  # external ref placeholder -- nothing inline to strip
      else:
        result.add(stripJsComments(body))
      var tagEnd = closeAt
      while tagEnd < n and src[tagEnd] != '>': inc tagEnd
      if tagEnd < n: inc tagEnd
      result.add(src[closeAt ..< tagEnd])
      i = tagEnd
      continue
    result.add(c)
    inc i
