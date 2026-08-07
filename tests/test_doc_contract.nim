## The published docs are an EXTERNAL contract, and until now nothing held them
## to one.
##
## `docs/RULES.md` is what a downstream config author or decoder reads before
## writing anything. Through the whole hex migration it kept publishing
## `mapEndzone: "column"` and `mapEndzone: "square"` — two values `arena.nim`
## raises `CtfError` on — and it kept specifying `rot90` / `corners` / `plus`
## inside the four-team contract six lines after the same document declared
## those tokens deleted. The suite was 599 green the entire time, because no
## test in this repo reads a markdown file. That is the whole failure mode: the
## drift was not merely unfixed, it was UNDETECTABLE.
##
## Two things are held here, and neither is a spell-check:
##
##   1. The generated vocabulary block in `docs/RULES.md` is REGENERATED from
##      the engine and compared. `tools/map_contract.nim` feeds every candidate
##      token to the real `generateMapAttempt` / `mapFromSpecJson` and publishes
##      the verdict the engine returns. Retiring a token, adding one, or moving
##      a rejection message now breaks this test — which is the point. The doc
##      cannot be transcribed out of date because it is not transcribed.
##   2. No published doc may name a RETIRED token as if it were live. The
##      square board's vocabulary (`column`, `square`, `rot90`, `corners`,
##      `plus`) may appear only in a paragraph that also says it is gone. This
##      is the check that would have caught RULES.md's four-team bullet, which
##      named `corners` and `plus` as live layouts.
##
## Neither check can prove a doc is TRUE. They prove the two specific ways this
## file set went wrong cannot go wrong silently again.

import
  std/[os, strutils, unittest],
  ../tools/map_contract

const
  RepoDir = currentSourcePath.parentDir.parentDir

  ScannedDocs = [
    "docs/RULES.md",
    "docs/ENV_VARIATION.md",
    "docs/MAPKIT.md",
    "docs/PROTOCOL.md",
    "docs/DECODER_CONTRACT.md",
    "README.md",
    "REPLAY_DESIGN.md",
  ]
    ## The PUBLISHED set: what a reader outside this repo is expected to build
    ## against. The audit reports (`HEX_*.md`) and the dated plan docs under
    ## `docs/plans/` are deliberately absent — their job is to describe what the
    ## vocabulary USED to be, and a report that could not name a retired token
    ## would be useless.

  RetirementMarkers = [
    "delete", "retire", "reject", "refus", "no longer", "used to", "gone",
    "unknown", "raises", "superseded", "went with",
  ]
    ## Matched case-insensitively inside the same UNIT (see `units`). A
    ## sentence presenting a retired token as a live option contains none of
    ## these; one that correctly marks it retired contains at least one.

proc readDoc(relative: string): string =
  readFile(RepoDir / relative)

proc startsUnit(line: string): bool =
  ## A markdown block item: a table row or a list bullet.
  let stripped = line.strip()
  if stripped.startsWith("|"): return true
  for bullet in ["- ", "* ", "> - ", "> * "]:
    if stripped.startsWith(bullet): return true
  false

proc units(text: string): seq[string] =
  ## Splits into the smallest block a claim can live in: one table ROW, one
  ## list BULLET (with its wrapped continuation lines), or one prose
  ## paragraph.
  ##
  ## Paragraph granularity is not enough, and that is not a hypothetical: the
  ## bullet this test exists for sat in the SAME blank-line-delimited block as
  ## the bullet declaring its tokens deleted, so a paragraph-wide scan reads
  ## the neighbour's disclaimer and passes. A markdown table is worse — one
  ## honest row would exempt every other row in the table.
  var current: seq[string]
  template flush() =
    if current.len > 0:
      result.add current.join("\n")
      current.setLen(0)
  for line in text.splitLines():
    if line.strip().len == 0: flush()
    elif line.startsUnit():
      flush()
      current.add line
    else: current.add line
  flush()

proc namesRetiredToken(unit, token: string): bool =
  ## True when this unit uses `token` as MAP VOCABULARY rather than as an
  ## ordinary English word — the distinction that decides whether "the six
  ## corners of the box are permanent void" is a violation (it is not) or
  ## "the four grenade pickups move to the edge midpoints (corners layout)"
  ## is (it is: that sentence shipped, six lines under the paragraph saying
  ## `corners` was deleted).
  ##
  ## `rot90` is unambiguous — it is a token or it is nothing.
  if token == "rot90": return token in unit.toLowerAscii()
  let lowered = unit.toLowerAscii()
  ## Quoted or backticked: the form a doc uses to publish a config VALUE.
  for quoted in ["`" & token & "`", "\"" & token & "\"", "'" & token & "'"]:
    if quoted in lowered: return true
  ## Used as a modifier — how the retired vocabulary reads in prose.
  for noun in [" layout", " symmetry", " endzone", " orbit", " zone",
               " map", " board", "-fair"]:
    if token & noun in lowered: return true
  false

suite "published docs vs the engine":

  test "RULES.md's generated vocabulary block matches what the engine does":
    let
      rules = readDoc(RulesPath)
      lo = rules.find(BlockBegin)
      hi = rules.find(BlockEnd)
    check lo >= 0
    check hi > lo
    let published = rules[lo + BlockBegin.len ..< hi].strip()
    ## The failure message has to be actionable, because the fix is one
    ## command and nobody should have to diff two markdown tables by eye.
    if published != mapContractBlock():
      checkpoint(
        "docs/RULES.md's map-vocabulary block disagrees with the engine.\n" &
        "Regenerate it:  nim c -r -d:release tools/map_contract.nim --write\n" &
        "--- published ---\n" & published &
        "\n--- engine ---\n" & mapContractBlock())
      fail()

  test "every value the block publishes as ACCEPTED really is accepted":
    ## Guards the generator itself: a bug that classified every token as
    ## accepted would still round-trip through the block above and this test
    ## would still pass, so assert the shape of the answer independently —
    ## every knob must have at least one accepted AND at least one rejected
    ## token, or the probe has stopped probing.
    for knob in mapContractKnobs() & mapSpecKnobs():
      var accepted, rejected = 0
      for verdict in knob.verdicts:
        if verdict.accepted: inc accepted else: inc rejected
      checkpoint("knob: " & knob.field)
      check accepted > 0
      check rejected > 0
      for verdict in knob.verdicts:
        ## A rejection must carry the engine's own message. An empty one means
        ## the probe caught something it did not understand.
        if not verdict.accepted:
          checkpoint(knob.field & " / " & verdict.token)
          check verdict.reason.len > 0

  test "the square board's vocabulary is never published as live":
    ## The check that RULES.md:238-241 would have failed: it specified `rot90`,
    ## `corners` and `plus` as four-team facts six lines below the paragraph
    ## declaring them deleted.
    for doc in ScannedDocs:
      let text = readDoc(doc)
      ## The generated block is exempt: it is emitted from the engine's own
      ## verdicts, so by construction it names retired tokens correctly.
      var scanned = text
      let
        lo = scanned.find(BlockBegin)
        hi = scanned.find(BlockEnd)
      if lo >= 0 and hi > lo:
        scanned = scanned[0 ..< lo] & scanned[hi + BlockEnd.len .. ^1]
      for unit in scanned.units():
        let lowered = unit.toLowerAscii()
        for token in RetiredTokens:
          if not unit.namesRetiredToken(token):
            continue
          var marked = false
          for marker in RetirementMarkers:
            if marker in lowered:
              marked = true
              break
          if not marked:
            checkpoint(
              doc & " names the retired token `" & token &
              "` without saying it is gone:\n" & unit)
          check marked
