## flash -- the paintbot Battle Royale one-page-policy authoring loop.
##
## Turns an LLM into a policy author against the `src/ctf/policy_page.nim`
## contract (`parsePolicyPage`, `validate`, `DefaultPathRegistry`). A page that fails
## validation never reaches disk: `flash author` feeds validation errors
## straight back to the model and retries, up to a fixed attempt cap.
##
## Subcommands:
##   flash author "<brief>" [--model claude|gemini|xai] [--out <name>]
##     Asks the LLM for one policy page scoped to <brief>, validates it, and
##     on failure retries with the errors appended to the conversation (up to
##     MaxAttempts total calls). On success writes playbook/<name>.json.
##   flash validate <file.json>
##     Parses and validates one page. Exit 0 and prints OK, or exit 1 and
##     prints every validation error. This is the CI gate.
##   flash lint <dir>
##     Validates every *.json page in <dir> and prints a pass/fail table.
##     Exit 1 if any page fails.
##
## Usage: nim c -r tools/flash/flash.nim -- <subcommand> [args]

import
  std/[json, os, strutils, sequtils, algorithm]

# Parallel lane (build-vm) owns this module.
import ../../src/ctf/policy_page

import ../../src/ctf/ais/claude as claudeAi
import ../../src/ctf/ais/gemini as geminiAi
import ../../src/ctf/ais/xai as xaiAi

const
  FlashDir = currentSourcePath().parentDir()
  DefaultPlaybookDir = FlashDir / "playbook"
  SchemaPath = FlashDir / "SCHEMA.md"
  PromptPath = FlashDir / "prompt.md"
  MaxAttempts = 3
  UsageText = """
Usage:
  nim c -r tools/flash/flash.nim -- author "<brief>" [--model claude|gemini|xai] [--out <name>]
  nim c -r tools/flash/flash.nim -- validate <file.json>
  nim c -r tools/flash/flash.nim -- lint <dir>
"""

type
  FlashError = object of CatchableError
  AiModel = enum
    amClaude = "claude"
    amGemini = "gemini"
    amXai = "xai"

proc fail(msg: string) =
  raise newException(FlashError, msg)

proc parseModel(s: string): AiModel =
  case s.toLowerAscii()
  of "claude": amClaude
  of "gemini": amGemini
  of "xai", "grok": amXai
  else:
    fail("unknown --model '" & s & "' (expected claude, gemini, or xai)")
    amClaude # unreachable, quiets the compiler

proc keyName(model: AiModel): string =
  case model
  of amClaude: "CLAUDE_KEY"
  of amGemini: "GEMINI_KEY"
  of amXai: "XAI_KEY"

proc hasKey(model: AiModel): bool =
  case model
  of amClaude: claudeAi.claudeKey.len > 0
  of amGemini: geminiAi.geminiKey.len > 0
  of amXai: xaiAi.xaiKey.len > 0

proc talk(model: AiModel, systemPrompt: string,
          history: seq[tuple[role, content: string]]): string =
  ## Sends systemPrompt + the accumulated (user/assistant) history to the
  ## chosen adapter and returns its reply. Each adapter module in
  ## src/ctf/ais declares its OWN `ConversationMessage` type (they are not
  ## shared), so the seq is rebuilt per call rather than passed across
  ## branches.
  case model
  of amClaude:
    var messages = @[claudeAi.ConversationMessage(role: "system", content: systemPrompt)]
    for h in history:
      messages.add claudeAi.ConversationMessage(role: h.role, content: h.content)
    claudeAi.talkToAI(messages)
  of amGemini:
    var messages = @[geminiAi.ConversationMessage(role: "system", content: systemPrompt)]
    for h in history:
      messages.add geminiAi.ConversationMessage(role: h.role, content: h.content)
    geminiAi.talkToAI(messages)
  of amXai:
    var messages = @[xaiAi.ConversationMessage(role: "system", content: systemPrompt)]
    for h in history:
      messages.add xaiAi.ConversationMessage(role: h.role, content: h.content)
    xaiAi.talkToAI(messages)

proc extractJson(reply: string): string =
  ## Best-effort recovery of a raw JSON object from a model reply that
  ## ignored the "raw JSON only" instruction -- strips a ```/```json fence
  ## if present, then slices from the first `{` to the last `}`.
  var s = reply.strip()
  if s.startsWith("```"):
    let firstNl = s.find('\n')
    if firstNl >= 0:
      s = s[firstNl + 1 .. ^1]
    if s.endsWith("```"):
      s = s[0 ..< s.len - 3]
    s = s.strip()
  let first = s.find('{')
  let last = s.rfind('}')
  if first >= 0 and last > first:
    s = s[first .. last]
  s

proc validateText(text: string): seq[string] =
  ## Parses + validates raw page JSON against the policy_page contract,
  ## folding a parse-time exception into the same error-string shape
  ## `validate` returns, so callers have one uniform error list regardless
  ## of which stage failed.
  try:
    let page = parsePolicyPage(text)
    validate(page, DefaultPathRegistry)
  except CatchableError as e:
    @["parse error: " & e.msg]

proc rawField(text: string, key: string): string =
  ## Reads a display-only string field (name/doc) straight out of the raw
  ## JSON via std/json, independent of whatever fields PolicyPage itself
  ## models -- this file only depends on the contractual procs and
  ## DefaultPathRegistry, never on PolicyPage's field set.
  try:
    let node = parseJson(text)
    if node.hasKey(key) and node[key].kind == JString:
      return node[key].getStr()
  except CatchableError:
    discard
  ""

proc loadPromptTemplate(brief: string): string =
  let schema = readFile(SchemaPath)
  var prompt = readFile(PromptPath)
  prompt = prompt.replace("{{SCHEMA}}", schema)
  prompt = prompt.replace("{{BRIEF}}", brief)
  prompt

proc cmdAuthor(brief: string, model: AiModel, outName: string): int =
  if not hasKey(model):
    echo "ERROR: ", keyName(model), " is not set -- cannot call ", $model, "."
    return 1
  let systemPrompt = loadPromptTemplate(brief)
  var history: seq[tuple[role, content: string]] =
    @[(role: "user", content: "Write the page now.")]
  for attempt in 1 .. MaxAttempts:
    stderr.writeLine "flash: attempt " & $attempt & "/" & $MaxAttempts &
      " (" & $model & ")"
    let reply = talk(model, systemPrompt, history)
    history.add (role: "assistant", content: reply)
    let candidateText = extractJson(reply)
    let errors = validateText(candidateText)
    if errors.len == 0:
      let name =
        if outName.len > 0: outName
        else: rawField(candidateText, "name")
      if name.len == 0:
        echo "ERROR: page validated but has no usable name; pass --out <name>."
        return 1
      createDir(DefaultPlaybookDir)
      let outPath = DefaultPlaybookDir / (name & ".json")
      writeFile(outPath, parseJson(candidateText).pretty())
      echo "wrote " & outPath
      return 0
    stderr.writeLine "flash: attempt " & $attempt & " failed validation:"
    for e in errors:
      stderr.writeLine "  - " & e
    if attempt < MaxAttempts:
      history.add (role: "user", content:
        "That page failed validation with these errors:\n" &
        errors.mapIt("- " & it).join("\n") &
        "\nReturn the corrected page. Raw JSON only, no prose, no fences.")
  echo "FAILED: no valid page after " & $MaxAttempts & " attempts -- nothing written."
  1

proc cmdValidate(path: string): int =
  let text = readFile(path)
  let errors = validateText(text)
  if errors.len == 0:
    echo "OK    " & path
    return 0
  echo "FAIL  " & path
  for e in errors:
    echo "  - " & e
  1

proc cmdLint(dir: string): int =
  var
    anyFail = false
    rows: seq[tuple[name, doc, status: string]]
  for path in walkFiles(dir / "*.json"):
    let text = readFile(path)
    let errors = validateText(text)
    let name = block:
      let n = rawField(text, "name")
      if n.len > 0: n else: path.extractFilename()
    let doc = rawField(text, "doc")
    let status =
      if errors.len == 0: "VALID"
      else:
        anyFail = true
        $errors.len & " error(s): " & errors[0]
    rows.add (name, doc, status)
  rows.sort(proc(a, b: tuple[name, doc, status: string]): int = cmp(a.name, b.name))
  let nameW = max(4, rows.mapIt(it.name.len).foldl(max(a, b), 0))
  let statusW = max(6, rows.mapIt(it.status.len).foldl(max(a, b), 0))
  echo alignLeft("NAME", nameW), "  ", alignLeft("STATUS", statusW), "  DOC"
  for r in rows:
    echo alignLeft(r.name, nameW), "  ", alignLeft(r.status, statusW), "  ", r.doc
  if anyFail: 1 else: 0

proc main(): int =
  if paramCount() < 1:
    echo UsageText
    return 1
  let cmd = paramStr(1)
  case cmd
  of "author":
    if paramCount() < 2:
      echo UsageText
      return 1
    var brief = ""
    var model = amClaude
    var outName = ""
    var i = 2
    while i <= paramCount():
      let a = paramStr(i)
      case a
      of "--model":
        inc i
        model = parseModel(paramStr(i))
      of "--out":
        inc i
        outName = paramStr(i)
      else:
        if brief.len == 0: brief = a
        else: fail("unexpected argument: " & a)
      inc i
    if brief.len == 0:
      echo UsageText
      return 1
    cmdAuthor(brief, model, outName)
  of "validate":
    if paramCount() < 2:
      echo UsageText
      return 1
    cmdValidate(paramStr(2))
  of "lint":
    let dir = if paramCount() >= 2: paramStr(2) else: DefaultPlaybookDir
    cmdLint(dir)
  else:
    echo UsageText
    1

when isMainModule:
  quit(main())
