## test_map_cards — the GUARD that ties `docs/evidence/map-cards/` to
## `MapPoolSeeds` (tasks#49/#50). Lane C (tasks#50) emits one stat card per
## pool seed via `tools/emit_map_cards.nim`, but nothing related the card COUNT
## to the pool, so a pool append (the tasks#49 siege/rush seeds) silently left
## three seeds cardless and no test went red. This module turns that drift into
## a failing test: a card file must exist for EVERY `MapPoolSeeds` entry, there
## must be no orphan cards, and each card must name its own seed.
##
## Pure filesystem + JSON — no map generation, no best-of-K — so it is cheap and
## lives in the fast shard next to the other map-of-maps tests. It reads the
## cards as data; it does not regenerate them (regeneration is the tool's job,
## `nim c -d:release -r tools/emit_map_cards.nim`).

import
  std/[json, os, sets, strutils, strformat, unittest],
  ctf/map_pool

const CardDir = currentSourcePath.parentDir.parentDir / "docs" / "evidence" /
  "map-cards"

proc cardPath(seed: int): string = CardDir / (&"pool-{seed}.json")

suite "map cards track the pool (tasks#49/#50 guard)":
  test "every MapPoolSeeds entry has a card file":
    var missing: seq[int]
    for seed in MapPoolSeeds:
      if not fileExists(cardPath(seed)):
        missing.add seed
    check missing.len == 0
    if missing.len > 0:
      checkpoint "cardless pool seeds (run tools/emit_map_cards.nim): " &
        missing.join(", ")

  test "no orphan cards — every card file names a current pool seed":
    var poolSeeds: HashSet[int]
    for seed in MapPoolSeeds: poolSeeds.incl seed
    var orphans: seq[string]
    for kind, path in walkDir(CardDir):
      if kind != pcFile: continue
      let name = path.extractFilename
      if not (name.startsWith("pool-") and name.endsWith(".json")): continue
      let seedStr = name[5 .. ^6]   # strip "pool-" .. ".json"
      let seed =
        try: parseInt(seedStr)
        except ValueError: -1
      if seed notin poolSeeds:
        orphans.add name
    check orphans.len == 0
    if orphans.len > 0:
      checkpoint "cards with no matching pool seed: " & orphans.join(", ")

  test "card count equals MapPoolSeeds.len":
    var n = 0
    for kind, path in walkDir(CardDir):
      if kind == pcFile and path.extractFilename.startsWith("pool-") and
          path.extractFilename.endsWith(".json"):
        inc n
    check n == MapPoolSeeds.len

  test "each card's kind.seed matches its filename":
    for seed in MapPoolSeeds:
      let path = cardPath(seed)
      if not fileExists(path): continue   # covered by the first test
      let card = parseJson(readFile(path))
      check card["kind"]["seed"].getInt == seed
