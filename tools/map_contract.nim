## The published map-generator vocabulary, ASKED OF THE ENGINE rather than
## transcribed from it.
##
## `docs/RULES.md` is an external contract: a downstream config author or
## decoder reads it and builds against what it says. Before the hex migration
## that was fine, because the doc and the engine were written at the same time.
## After it, the doc kept publishing `mapEndzone: "column"` and
## `mapEndzone: "square"` — two values `arena.nim` now raises `CtfError` on —
## and nothing went red, because no test in this repo reads a markdown file.
##
## So the vocabulary is no longer WRITTEN in the doc. It is generated here and
## pasted into a delimited block, and `tests/test_doc_contract.nim` regenerates
## it and fails when the block and the engine disagree. Adding a token, retiring
## one, or changing a rejection message now breaks a test instead of quietly
## making the contract a lie.
##
## HOW THE ACCEPT/REJECT VERDICT IS OBTAINED. Each candidate token is fed to
## the real `generateMapAttempt` — this is a behavioural probe, not a parse of
## the source text, so it cannot be fooled by a `case` branch that is dead or a
## guard that runs somewhere else. To keep the probe cheap, the call also
## carries a SENTINEL: an out-of-range value on a knob the generator validates
## just AFTER the one under test. A token that survives its own vocabulary
## check then dies on the sentinel, which is the accept signal, and the probe
## costs nothing beyond the parameter solve. A token that is rejected dies on
## its own check first, and the engine's own message is what gets published.
##
## Usage:
##   nim c -r -d:release tools/map_contract.nim            # print the block
##   nim c -r -d:release tools/map_contract.nim --write    # rewrite RULES.md

import std/[json, strutils], ../src/ctf/[arena, hex, sim_types]

const
  RulesPath* = "docs/RULES.md"
  BlockBegin* = "<!-- BEGIN GENERATED map-vocabulary (tools/map_contract.nim) -->"
  BlockEnd* = "<!-- END GENERATED map-vocabulary -->"

  ProbeSeed = 4207
    ## Any seed works — the vocabulary checks run before the terrain draw. One
    ## fixed seed keeps the generated block byte-stable.

  RetiredTokens* = ["column", "square", "rot90", "corners", "plus"]
    ## The square board's vocabulary. These are what the doc used to publish;
    ## the probe below asserts the engine still refuses every one of them, and
    ## `tests/test_doc_contract.nim` additionally asserts no published doc
    ## names one without saying it is gone.

type
  Verdict* = object
    token*: string
    accepted*: bool
    reason*: string   ## the engine's own rejection message; "" when accepted

  Knob* = object
    field*: string          ## the JSON config key an operator writes
    candidates*: seq[string]
    verdicts*: seq[Verdict]

proc baseOverrides(): MapGenOverrides =
  MapGenOverrides(windows: -1, pits: -1, pitDensity: -1)

proc probe(overrides: MapGenOverrides, sentinel: string): tuple[
    ok: bool, reason: string] =
  ## Runs the generator and reports whether the token under test survived its
  ## own vocabulary check. `sentinel` is the substring of the deliberately
  ## induced downstream error — reaching it means the token was accepted.
  try:
    discard generateMapAttempt(ProbeSeed, overrides, teams = 2)
    ## No sentinel fired: the token was accepted and the map built anyway.
    (true, "")
  except CatchableError as err:
    if sentinel in err.msg: (true, "")
    else: (false, err.msg.strip())

proc symmetryKnob(): Knob =
  ## Sentinel: `baseDepth` below `HomeDepthMin`, validated at the end of the
  ## endzone block — downstream of the symmetry, layout AND endzone checks.
  result.field = "mapSymmetry"
  result.candidates = @[
    "", "mirror", "mirrorHex", "rot180", "rot60", "rot90", "rot120", "klein4"]
  for token in result.candidates:
    var overrides = baseOverrides()
    overrides.symmetry = token
    overrides.baseDepth = 1
    let (ok, reason) = probe(overrides, "mapBaseDepth")
    result.verdicts.add Verdict(token: token, accepted: ok, reason: reason)

proc layoutKnob(): Knob =
  result.field = "mapLayout"
  result.candidates = @[
    "", "hex2", "sides", "hex3", "hex4", "hex6", "corners", "plus"]
  for token in result.candidates:
    var overrides = baseOverrides()
    overrides.layout = token
    overrides.baseDepth = 1
    let (ok, reason) = probe(overrides, "mapBaseDepth")
    result.verdicts.add Verdict(token: token, accepted: ok, reason: reason)

proc endzoneKnob(): Knob =
  result.field = "mapEndzone"
  result.candidates = @["", "disc", "column", "square", "sector"]
  for token in result.candidates:
    var overrides = baseOverrides()
    overrides.endzone = token
    overrides.baseDepth = 1
    let (ok, reason) = probe(overrides, "mapBaseDepth")
    result.verdicts.add Verdict(token: token, accepted: ok, reason: reason)

proc centerFeatureKnob(): Knob =
  ## Sentinel: `columns` below the floor, validated immediately after the
  ## center-feature check.
  result.field = "mapCenterFeature"
  result.candidates = @["", "bracket", "ring", "walls", "cross"]
  for token in result.candidates:
    var overrides = baseOverrides()
    overrides.centerFeature = token
    overrides.columns = 1
    let (ok, reason) = probe(overrides, "mapColumns")
    result.verdicts.add Verdict(token: token, accepted: ok, reason: reason)

proc sizeKnob(): Knob =
  ## `mapSize` resolves through `hexSizeClass`, so the vocabulary IS
  ## `HexClassNames` — read straight off the table rather than probed, because
  ## an accepted size builds a whole board and `colossal` alone is 5819x5039.
  ## An unknown name raises out of `hexSizeClass`, which the probe confirms.
  result.field = "mapSize"
  for name in HexClassNames:
    result.candidates.add name
    result.verdicts.add Verdict(token: name, accepted: true)
  result.candidates.add "medium"
  var overrides = baseOverrides()
  overrides.size = "medium"
  overrides.baseDepth = 1
  let (ok, reason) = probe(overrides, "mapBaseDepth")
  result.verdicts.add Verdict(token: "medium", accepted: ok, reason: reason)

proc specProbe(field, token: string): tuple[ok: bool, reason: string] =
  ## The OTHER vocabulary: `mapSpec`, the pinned map a replay or a league
  ## config carries. `mapFromSpecJson` parses it with its own `case` statements,
  ## which are deliberately WIDER than the generator's — a spec may name a
  ## 3/4/6-team layout the generator will never draw. Publishing one list for
  ## both paths would be wrong in whichever direction it was written, so both
  ## are probed.
  var spec = parseJson(
    generateMapAttempt(ProbeSeed, baseOverrides(), teams = 2).mapSpecJson())
  spec[field] = %token
  try:
    discard mapFromSpecJson($spec)
    (true, "")
  except CatchableError as err:
    (false, err.msg.strip())

proc specKnob(field: string, candidates: seq[string]): Knob =
  result.field = field
  result.candidates = candidates
  for token in candidates:
    let (ok, reason) = specProbe(field, token)
    result.verdicts.add Verdict(token: token, accepted: ok, reason: reason)

proc mapContractKnobs*(): seq[Knob] =
  @[sizeKnob(), symmetryKnob(), layoutKnob(), endzoneKnob(),
    centerFeatureKnob()]

proc mapSpecKnobs*(): seq[Knob] =
  @[
    specKnob("symmetry", @[
      "mirror", "mirrorHex", "rot180", "rot60", "rot120", "klein4", "rot90"]),
    specKnob("layout", @[
      "hex2", "sides", "hex3", "hex4", "hex6", "corners", "plus"]),
    specKnob("endzone", @["disc", "column", "square"]),
  ]

proc tokenText(token: string): string =
  if token.len == 0: "`\"\"` (draw)" else: "`" & token & "`"

proc mapContractBlock*(): string =
  ## The markdown between the two sentinels in `docs/RULES.md`.
  let knobs = mapContractKnobs()
  var lines: seq[string]
  lines.add "| Config field | Values the engine ACCEPTS |"
  lines.add "|---|---|"
  for knob in knobs:
    var accepted: seq[string]
    for v in knob.verdicts:
      if v.accepted: accepted.add tokenText(v.token)
    lines.add "| `" & knob.field & "` | " & accepted.join(" · ") & " |"
  lines.add ""
  lines.add "| Config field | Value the engine REJECTS | The engine's own message |"
  lines.add "|---|---|---|"
  for knob in knobs:
    for v in knob.verdicts:
      if not v.accepted:
        lines.add "| `" & knob.field & "` | `" & v.token & "` | " &
          v.reason.replace("|", "\\|") & " |"
  lines.add ""
  lines.add "Size classes and the BOUNDING BOX each one builds (`hex.nim`, " &
    "`HexSizes`). The playfield is the hexagon inscribed in the box, not the " &
    "box:"
  lines.add ""
  lines.add "| `mapSize` | Bounding box | Field scale | Drawn at random? | " &
    "`mapEndzoneRadius` accepted here |"
  lines.add "|---|---|---|---|---|"
  var drawn: seq[string]
  for name in HexSizeNames: drawn.add name
  for cls in HexSizeClass:
    let box = HexSizes[cls]
    lines.add "| `" & HexClassNames[cls] & "` | " & $box.width & "x" &
      $box.height & " | " & $HexClassScale[cls] & " | " &
      (if HexClassNames[cls] in drawn: "yes" else: "no — override only") &
      " | " & $minEndzoneRadius(box.height) & ".." &
      $maxEndzoneRadius(box.height) & " px |"
  lines.add ""
  lines.add "`mapEndzoneRadius` is keyed on the SHORT axis, so its legal " &
    "window moves with the size class — a value legal on one board is " &
    "rejected on another. `mapBaseDepth` is scale-free: **" & $HomeDepthMin &
    ".." & $HomeDepthMax & "** permille on every class, and `0` does not draw " &
    "from a fixed range but SOLVES a window against the board (see " &
    "`homeDepthWindow`), so no draw interval is published here — there is " &
    "not one number to publish."
  lines.add ""
  lines.add "A PINNED `mapSpec` — what a replay carries and what a decoder " &
    "reads — parses against a WIDER vocabulary than the generator draws " &
    "from, so a spec may legally name a board `\"mapPath\": \"gen\"` will " &
    "never produce:"
  lines.add ""
  lines.add "| `mapSpec` key | Parses on a 2-team spec | Parses, but needs a " &
    "board this spec is not | UNKNOWN token — deleted |"
  lines.add "|---|---|---|---|"
  for knob in mapSpecKnobs():
    var accepted, elsewhere, unknown: seq[string]
    for v in knob.verdicts:
      if v.accepted: accepted.add "`" & v.token & "`"
      elif v.reason.startsWith("Unknown map spec"):
        unknown.add "`" & v.token & "`"
      else: elsewhere.add "`" & v.token & "`"
    proc cell(items: seq[string]): string =
      if items.len == 0: "—" else: items.join(" · ")
    lines.add "| `" & knob.field & "` | " & cell(accepted) & " | " &
      cell(elsewhere) & " | " & cell(unknown) & " |"
  lines.join("\n")

proc rewriteRules*(path: string): bool =
  ## Replaces the delimited block in place. Returns true when the file moved.
  let
    original = readFile(path)
    lo = original.find(BlockBegin)
    hi = original.find(BlockEnd)
  if lo < 0 or hi < 0:
    raise newException(
      ValueError, path & " is missing the generated-vocabulary sentinels.")
  let updated = original[0 ..< lo + BlockBegin.len] & "\n\n" &
    mapContractBlock() & "\n\n" & original[hi .. ^1]
  if updated == original: return false
  writeFile(path, updated)
  true

when isMainModule:
  ## `std/os` is CLI-only — importing it at module scope would warn in
  ## `tests/test_doc_contract.nim`, which imports this module as a library.
  import std/os
  if paramCount() >= 1 and paramStr(1) == "--write":
    let path = if paramCount() >= 2: paramStr(2) else: RulesPath
    if rewriteRules(path): echo "rewrote ", path
    else: echo path, " already matches the engine"
  else:
    echo mapContractBlock()
