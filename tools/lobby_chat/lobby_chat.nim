## lobby_chat -- one stdin/stdout call in the pre-game BR lobby conversation.
##
## This is the Nim-side primitive the field service (coworld-paintbot-player,
## server/lobbychat.mjs) spawns once per seat-turn. It does NOT run the
## multi-seat conversation itself (rounds, scoping, transcript, bounds) --
## that orchestration lives in the field service, in Node, because the field
## service owns the lobby/match lifecycle. This tool's whole job is: given a
## system prompt and a conversation-so-far, either (a) produce one more
## chat turn, or (b) produce and VALIDATE one final one-page policy --
## reusing the exact same two contracts `tools/flash/flash.nim` already
## proved out for single-page authoring:
##   - src/ctf/ais/{claude,gemini,xai}.nim's `talkToAI` (the LLM call itself
##     -- reused verbatim, never reimplemented; openai.nim/bedrock.nim are
##     skipped for the same reason flash.nim skips them: a different
##     return-type shape, not wired up here either)
##   - src/ctf/policy_page.nim's `parsePolicyPage`/`validate`/
##     `DefaultPathRegistry` (the real scoring-VM contract -- a page that
##     fails validation is never handed back as a success)
##
## Talking over stdin/stdout JSON (rather than a library import) mirrors how
## matchd.mjs already runs every bot: as a subprocess, so a hang, a crash, or
## a bad API key in ONE seat's LLM call can be killed by the caller's own
## timeout (Node's `execFile(..., {timeout})`) without special-casing Nim
## exceptions across a language boundary -- "never block the field" is
## enforced by the caller, this tool only has to fail LOUDLY and FAST.
##
## Wire contract (see docs/lobby-chat.md in coworld-paintbot-player for the
## full transcript/API shape this feeds):
##
##   nim c -r tools/lobby_chat/lobby_chat.nim -- turn <<'EOF'
##   {"model": "claude", "system": "...", "history": [{"role":"user","content":"..."}]}
##   EOF
##   -> {"ok": true, "reply": "..."}
##   -> {"ok": false, "error": "CLAUDE_KEY is not set"}
##
##   nim c -r tools/lobby_chat/lobby_chat.nim -- page <<'EOF'
##   {"model": "claude", "system": "...", "history": [...], "maxAttempts": 3}
##   EOF
##   -> {"ok": true, "page": {...validated PolicyPage JSON...}, "attempts": 1}
##   -> {"ok": false, "error": "no valid page after 3 attempts", "attempts": 3,
##       "lastErrors": ["..."]}
##
##   nim c -r tools/lobby_chat/lobby_chat.nim -- default-page
##   -> {"ok": true, "page": {...the embedded fallback page, FallbackPageJson below...}}
##      Used by the field service AND by this tool's own tests as the one
##      canonical "a seat falls back to a default strategy" artifact -- a
##      single hardcoded page, not re-derived per call, so "why did this cog
##      play so plainly" always has the same one-word answer: fallback.
##
## Every reply this tool ever returns is hard-truncated (see `MaxReplyChars`)
## regardless of what the model sent back -- a token-budget backstop that
## does not depend on trusting any adapter's own max_tokens setting.

import
  std/[json, os, strutils, sequtils]

import ../../src/ctf/policy_page
import ../../src/ctf/ais/claude as claudeAi
import ../../src/ctf/ais/gemini as geminiAi
import ../../src/ctf/ais/xai as xaiAi

const
  MaxAttemptsDefault = 3
  MaxReplyChars = 600 ## hard cap on what a single turn can add to the
    ## transcript, independent of any adapter's own token limit -- "brief"
    ## is enforced here, not just requested in the prompt.
  UsageText = """
Usage:
  nim c -r tools/lobby_chat/lobby_chat.nim -- turn          < request.json
  nim c -r tools/lobby_chat/lobby_chat.nim -- page           < request.json
  nim c -r tools/lobby_chat/lobby_chat.nim -- default-page
"""

  ## The one canonical fallback page. Deliberately plain and deliberately
  ## valid against DefaultPathRegistry (see tests/test_lobby_chat.nim) --
  ## covers the two situations every cog fallback-or-not must cover: hold
  ## the peel while healthy, break for a medkit and duck the biggest threat
  ## once hurt. Same JSON shape/vocabulary as tools/flash/playbook/*.json
  ## (build-flash's hand-authored examples) -- not copied from there, so a
  ## change to that playbook can never silently change what every fallback
  ## seat plays.
  FallbackPageJson* = """
{
  "paintbot_policy": 1,
  "name": "lobby-chat-fallback",
  "doc": "The default strategy a seat plays when its lobby-chat LLM call never lands: no key, an error, a timeout, or an invalid page. Deliberately plain -- hold the peel while healthy, break for care and duck the biggest threat once hurt.",
  "traits": { "nerve": 0.5, "greed": 0.3, "patience": 0.6 },
  "rules": [
    { "when": [">=", ["get", "self.hp_frac"], 0.5],
      "score": ["+",
        ["*", 25, ["get", "intent.is_peel"]],
        ["*", 15, ["get", "intent.is_enemy"]],
        ["*", -12, ["get", "intent.exposure"]]
      ]
    },
    { "when": ["<", ["get", "self.hp_frac"], 0.5],
      "score": ["+",
        ["*", 35, ["get", "intent.is_medkit"]],
        ["*", 10, ["get", "intent.is_cover"]],
        ["*", -20, ["get", "intent.threat"]]
      ]
    }
  ]
}
"""

type
  CliError = object of CatchableError
  AiModel = enum
    amClaude = "claude"
    amGemini = "gemini"
    amXai = "xai"

proc fail(msg: string) =
  raise newException(CliError, msg)

proc parseModel(s: string): AiModel =
  case s.toLowerAscii()
  of "claude": amClaude
  of "gemini": amGemini
  of "xai", "grok": amXai
  else: fail("unknown model '" & s & "' (expected claude, gemini, or xai)"); amClaude

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
  ## Same per-adapter dispatch as tools/flash/flash.nim's `talk()` -- each
  ## src/ctf/ais module declares its OWN ConversationMessage type, so the
  ## seq is rebuilt per branch rather than shared across them.
  case model
  of amClaude:
    var messages = @[claudeAi.ConversationMessage(role: "system", content: systemPrompt)]
    for h in history: messages.add claudeAi.ConversationMessage(role: h.role, content: h.content)
    claudeAi.talkToAI(messages)
  of amGemini:
    var messages = @[geminiAi.ConversationMessage(role: "system", content: systemPrompt)]
    for h in history: messages.add geminiAi.ConversationMessage(role: h.role, content: h.content)
    geminiAi.talkToAI(messages)
  of amXai:
    var messages = @[xaiAi.ConversationMessage(role: "system", content: systemPrompt)]
    for h in history: messages.add xaiAi.ConversationMessage(role: h.role, content: h.content)
    xaiAi.talkToAI(messages)

proc truncated(s: string): string =
  if s.len <= MaxReplyChars: s
  else: s[0 ..< MaxReplyChars] & " …[truncated]"

proc extractJson(reply: string): string =
  ## Best-effort recovery of a raw JSON object from a reply that ignored
  ## "raw JSON only" -- strips a ```/```json fence if present, then slices
  ## from the first `{` to the last `}`. Identical in spirit to flash.nim's
  ## helper of the same name (duplicated, not imported: flash.nim is a
  ## single-file `isMainModule` tool with no exported library surface, same
  ## convention this file itself follows for its own callers).
  var s = reply.strip()
  if s.startsWith("```"):
    let firstNl = s.find('\n')
    if firstNl >= 0: s = s[firstNl + 1 .. ^1]
    if s.endsWith("```"): s = s[0 ..< s.len - 3]
    s = s.strip()
  let first = s.find('{')
  let last = s.rfind('}')
  if first >= 0 and last > first: s = s[first .. last]
  s

proc validateText(text: string): seq[string] =
  try:
    let page = parsePolicyPage(text)
    validate(page, DefaultPathRegistry)
  except CatchableError as e:
    @["parse error: " & e.msg]

type Request = object
  model: AiModel
  system: string
  history: seq[tuple[role, content: string]]
  maxAttempts: int

proc readRequest(): Request =
  let raw = stdin.readAll()
  var js: JsonNode
  try:
    js = parseJson(raw)
  except CatchableError as e:
    fail("bad request JSON on stdin: " & e.msg)
  if js.kind != JObject: fail("request must be a JSON object")
  if not js.hasKey("model") or js["model"].kind != JString:
    fail("request.model must be a string (claude, gemini, or xai)")
  let model = parseModel(js["model"].getStr)
  let system = (if js.hasKey("system") and js["system"].kind == JString: js["system"].getStr else: "")
  var history: seq[tuple[role, content: string]] = @[]
  if js.hasKey("history") and js["history"].kind == JArray:
    for m in js["history"].elems:
      if m.kind != JObject: continue
      let role = (if m.hasKey("role") and m["role"].kind == JString: m["role"].getStr else: "user")
      let content = (if m.hasKey("content") and m["content"].kind == JString: m["content"].getStr else: "")
      history.add (role: role, content: content)
  let maxAttempts =
    if js.hasKey("maxAttempts") and js["maxAttempts"].kind == JInt: js["maxAttempts"].getInt
    else: MaxAttemptsDefault
  Request(model: model, system: system, history: history, maxAttempts: max(1, maxAttempts))

proc emit(js: JsonNode) =
  stdout.writeLine($js)
  stdout.flushFile()

proc cmdTurn(req: Request): int =
  if not hasKey(req.model):
    emit(%*{"ok": false, "error": keyName(req.model) & " is not set"})
    return 0
  try:
    let reply = talk(req.model, req.system, req.history)
    if reply.strip().len == 0:
      emit(%*{"ok": false, "error": "empty reply from " & $req.model & " (the adapter logged the HTTP error to its own stdout)"})
    else:
      emit(%*{"ok": true, "reply": truncated(reply)})
  except CatchableError as e:
    emit(%*{"ok": false, "error": e.msg})
  0

proc cmdPage(req: Request): int =
  if not hasKey(req.model):
    emit(%*{"ok": false, "error": keyName(req.model) & " is not set", "attempts": 0})
    return 0
  var history = req.history
  if history.len == 0:
    history.add (role: "user", content: "Write the page now. Raw JSON only, no prose, no fences.")
  var lastErrors: seq[string] = @[]
  for attempt in 1 .. req.maxAttempts:
    var reply: string
    try:
      reply = talk(req.model, req.system, history)
    except CatchableError as e:
      emit(%*{"ok": false, "error": e.msg, "attempts": attempt})
      return 0
    history.add (role: "assistant", content: reply)
    let candidateText = extractJson(reply)
    let errors = validateText(candidateText)
    if errors.len == 0:
      emit(%*{"ok": true, "page": parseJson(candidateText), "attempts": attempt})
      return 0
    lastErrors = errors
    if attempt < req.maxAttempts:
      history.add (role: "user", content:
        "That page failed validation with these errors:\n" &
        errors.mapIt("- " & it).join("\n") &
        "\nReturn the corrected page. Raw JSON only, no prose, no fences.")
  emit(%*{"ok": false, "error": "no valid page after " & $req.maxAttempts & " attempts",
          "attempts": req.maxAttempts, "lastErrors": lastErrors})
  0

proc cmdDefaultPage(): int =
  ## Same envelope shape as `turn`/`page` ({"ok": true, ...}) so a caller
  ## never needs a THIRD parsing convention -- one compact JSON line, always.
  emit(%*{"ok": true, "page": parseJson(FallbackPageJson)})
  0

proc main(): int =
  if paramCount() < 1:
    stderr.writeLine UsageText
    return 1
  case paramStr(1)
  of "turn": cmdTurn(readRequest())
  of "page": cmdPage(readRequest())
  of "default-page": cmdDefaultPage()
  else:
    stderr.writeLine UsageText
    1

when isMainModule:
  quit(main())
