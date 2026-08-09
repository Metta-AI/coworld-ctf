## spec_roundtrip_probe — does mapFromSpecJson(mapSpecJson(m)) == m for FRESHLY
## GENERATED maps, at both team counts?
##
## This is the one property in the rewrite that is a genuine ship-blocker. Seed
## -> map identity may be broken freely; spec -> map identity may NOT, because
## replays pin mapSpec. A map that does not survive the round-trip renders as a
## DIFFERENT BOARD on replay than it did in the episode.
##
## The suite's existing check ("every curated map spec round-trips byte-
## identically", test_map_editor_core.nim:230) sweeps the CURATED POOL, so on a
## generator that raises it dies on the raise before testing anything, and a
## real round-trip break would be indistinguishable from a stale pool. This
## probe generates fresh maps instead, which is also what exercises the new
## shape kinds — polygon masses and organic dithered biome edges push the spec
## encoder far harder than the old lattice's rects and r28 discs ever did.
##
##   nim c -d:release -r tools/spec_roundtrip_probe.nim [count] [teams]
import std/[os, strformat, strutils]
import ../src/ctf/[sim, arena]

proc main() =
  let
    count = if paramCount() >= 1: parseInt(paramStr(1)) else: 20
    teams = if paramCount() >= 2: parseInt(paramStr(2)) else: 2
  var
    tested = 0
    raised = 0
    jsonMismatch = 0
    mapMismatch = 0
    firstFailure = ""

  ## The hand-authored control goes in every batch. A round-trip check that
  ## skips `arena` cannot tell "the generator broke the encoder" from "the
  ## encoder was always broken".
  block control:
    let
      gameMap = loadCtfMapMetadata("arena")
      spec = mapSpecJson(gameMap)
      rebuilt = mapFromSpecJson(spec)
    echo &"CONTROL arena: json={mapSpecJson(rebuilt) == spec} " &
      &"map={rebuilt == gameMap} specBytes={spec.len}"

  for i in 0 ..< count:
    let seed = 1001 + i
    var gameMap: CtfMap
    try:
      gameMap = generateCtfMap(seed, teams = teams)
    except CtfError:
      inc raised
      continue
    inc tested
    let
      spec = mapSpecJson(gameMap)
      rebuilt = mapFromSpecJson(spec)
      reSpec = mapSpecJson(rebuilt)
    if reSpec != spec:
      inc jsonMismatch
      if firstFailure.len == 0:
        ## Report WHERE they diverge, not just that they do -- a byte offset
        ## localises the offending shape kind immediately.
        var at = 0
        while at < min(spec.len, reSpec.len) and spec[at] == reSpec[at]: inc at
        firstFailure = &"seed {seed}: json diverges at byte {at} of " &
          &"{spec.len}/{reSpec.len}\n    orig: ..." &
          spec[max(0, at - 40) ..< min(spec.len, at + 60)] & "\n    back: ..." &
          reSpec[max(0, at - 40) ..< min(reSpec.len, at + 60)]
    if rebuilt != gameMap:
      inc mapMismatch
      if firstFailure.len == 0:
        firstFailure = &"seed {seed}: json IDENTICAL but CtfMap differs -- " &
          "a field outside the spec, or a field the encoder drops"

  let denom = max(tested, 1)
  echo &"{teams}-team, {count} seeds: generated={tested}/{count} " &
    &"({100 * tested div max(count, 1)}%)  raised={raised}/{count} " &
    &"({100 * raised div max(count, 1)}%)"
  echo &"  json round-trip failures: {jsonMismatch}/{tested} " &
    &"({100 * jsonMismatch div denom}%)"
  echo &"  map  round-trip failures: {mapMismatch}/{tested} " &
    &"({100 * mapMismatch div denom}%)"
  if firstFailure.len > 0: echo "  first failure -> ", firstFailure
  else: echo "  SPEC->MAP IDENTITY HOLDS on every map that generated."

main()
