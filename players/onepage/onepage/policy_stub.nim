## THE SWAP: `src/ctf/policy_page.nim` (the real one-page scoring VM, built by
## a different agent on `maxwell/br-onepage-vm`) has landed. Per this file's
## own swap plan (see git history), this module's body is now that import,
## re-exported under the names onepage.nim already calls
## (`PolicyPage`, `IntentContext`, `PathKind`, `DefaultPaths`, `compilePage`,
## `selectIntent`) plus a thin adapter for the two signature differences:
##
##   - the real VM scores a FIXED rule set per intent-context and argmaxes
##     over intents (`compile`/`argmax`), rather than a per-candidate-row
##     linear model (`rows`/`weights`) the old placeholder invented. A real
##     playbook page (tools/flash/playbook/*.json, schema
##     `{"paintbot_policy": 1, "rules": [{"when":..., "score":...}]}`) only
##     ever speaks the rules schema, so this adapter is what lets those real
##     pages run against onepage.nim's call sites unchanged.
##   - `compilePage`'s `candidates` param (IntentNames) is unused by the real
##     VM (a rule set is not per-candidate), kept only so the call sites in
##     onepage.nim do not need to change, matching this file's own swap-plan
##     promise.
##
## onepage.nim's own call sites are untouched by this swap, exactly as
## promised: `policy_stub.compilePage(raw, IntentNames, fullPathRegistry())`
## and `policy_stub.selectIntent(page, names, ctxFor)` still compile as-is.

import ../../../src/ctf/policy_page as vm

export vm.PathKind
export vm.IntentContext
export vm.DefaultPaths

type
  PolicyPage* = object
    compiled: vm.CompiledPage
    raw*: string

proc compilePage*(raw: string, candidates: openArray[string],
    registry: openArray[tuple[path: string, kind: vm.PathKind]] = vm.DefaultPaths
    ): PolicyPage =
  ## Parses + validates + compiles `raw` against `registry` (onepage.nim
  ## always passes its own `fullPathRegistry()`, DefaultPaths plus the fine
  ## per-intent tag family). Raises ValueError (via `vm.PolicyParseError`,
  ## a ValueError subtype, or `compile`'s own validation-failure raise) on
  ## anything invalid — same "fail loud, name the bad key" contract the
  ## placeholder documented, now enforced by the real VM's own `validate`.
  let reg = vm.newPathRegistry(registry)
  let page = vm.parsePolicyPage(raw)
  result.raw = raw
  result.compiled = vm.compile(page, reg)

proc selectIntent*(page: PolicyPage, candidates: openArray[string],
    ctxFor: proc(name: string): vm.IntentContext): string =
  ## Builds one IntentContext per candidate (onepage.nim's fixed 12-entry
  ## intent menu, in order), argmaxes the compiled rule set over them, and
  ## returns the winning candidate's NAME — never gameHash-material data
  ## more granular than that. Ties keep the first (lowest-index) candidate,
  ## matching argmax's own documented tie rule.
  doAssert candidates.len > 0
  var intents = newSeq[vm.IntentContext](candidates.len)
  for i, name in candidates:
    intents[i] = ctxFor(name)
  let idx = vm.argmax(page.compiled, intents)
  result = if idx < 0: candidates[0] else: candidates[idx]
