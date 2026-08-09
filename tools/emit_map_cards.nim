## emit_map_cards — one STAT CARD per pool map (map-of-maps Layer 3, tasks#50).
##
## Writes `docs/evidence/map-cards/pool-NNNN.json`, one file per `MapPoolSeeds`
## entry, each holding a `map-card/v0` card (schema designed in tasks#44 c62816):
##   kind   — STATIC, fully populated here from the values `generateCtfMap` /
##            `evaluateMap` / `mapRules` / `map_taxonomy` already compute.
##   live   — telemetry, RESERVED null (no episodes yet; the serving loop that
##            fills this does not exist — see tasks#44 Part 3).
##   grades — derived over kind+live, RESERVED null (needs live).
##
## WRITE-ONLY: nothing in the tree consumes these cards. This tool reads the
## generator's outputs and writes JSON; it adds no new geometry, no new metric,
## and no card READER. It is a reporting tool (like `map_catalog`), not part of
## the server.
##
## Every coordinate is read off the SAME values the server and ranker already
## compute — the card records them, it does not re-derive or re-tune anything.
##
## Usage (from repo root):  nim c -d:release -r tools/emit_map_cards.nim
## Costs one best-of-K selection per seed (~1s on a standard board).

import std/[json, os, strutils, strformat]
import ../src/ctf/[arena, sim, map_pool, map_metrics, map_rules,
  map_archetypes, map_taxonomy]

const
  OutDir = "docs/evidence/map-cards"
  SchemaVersion = "map-card/v0"
  GameVersionTag = "gv" & GameVersion   ## sim_types.GameVersion == "42" -> "gv42"

proc symmetryTag(gameMap: CtfMap): string =
  ## The schema's clean symmetry name {mirror,rot180,rot90,quadMirror}, from the
  ## enum. `$MapSymmetry` yields the "sym"-prefixed identifier (symRot180); the
  ## card wants the wire-style short name, so drop the prefix and lowercase the
  ## first letter (symRot180 -> rot180, symQuadMirror -> quadMirror).
  var s = ($gameMap.symmetry)
  if s.startsWith("sym"): s = s[3 .. ^1]
  if s.len > 0: s[0] = s[0].toLowerAscii
  s

proc cardFor(seed: int): JsonNode =
  ## The stat card for one pool seed. The derivations mirror `tools/map_catalog`
  ## exactly (same imports, same calls) so the card and the catalog can never
  ## disagree about what a pool map IS.
  let
    gameMap = generateCtfMap(seed)
    m = evaluateMap(gameMap, "gen:" & $seed)
    sizeClass = gameMap.mapSizeClass()
    teams = gameMap.teamCount()
    r = mapRules(sizeClass, teams)
    arch = mapArchetypeFor(seed, teams)
    ct = contactTicks(r.playfieldPx, TunedOpponents)

  ## `style` (mapgen_styles.MapStyle {bsp,caves,maze,scatter}) is emitted as
  ## NULL, not fabricated: the schema field predates the archetype refactor and
  ## the SHIPPED pool generator (`generateCtfMap`) is archetype-driven and never
  ## assigns a `MapStyle` — that enum is only used by the manual `mapkit` tool.
  ## The discriminator role it once held is now carried by `archetype` below.
  let kind = %*{
    "seed": seed,
    "game_version": GameVersionTag,
    "size_class": sizeClass.sizeName(),
    "width": gameMap.width,
    "height": gameMap.height,
    "teams": teams,
    "symmetry": symmetryTag(gameMap),
    "style": newJNull(),
    "biome": $gameMap.biome,
    "game_mode": "ctf",
    "static_score": staticScore(m),
    "valid": m.valid,
    "archetype": $arch,
    "playtype": playtypeLabel(m, r),
    "pacing": pacingTier(ct, TunedContactTicks),
    "metrics": {
      "interiorFrac": m.interiorFrac,
      "chokeCount": m.chokeCount,
      "routeCountMin": m.routeCountMin,
      "longRunFrac": m.longRunFrac,
      "visDegreeCv": m.visDegreeCv,
      "coverPermille": m.coverPermille,
      "contactTicks": ct,
    },
  }

  result = %*{
    "map_id": &"pool:{seed}@{GameVersionTag}",
    "schema_version": SchemaVersion,
    "kind": kind,
    "live": newJNull(),
    "grades": newJNull(),
  }

when isMainModule:
  createDir(OutDir)
  var n = 0
  for seed in MapPoolSeeds:
    let card = cardFor(seed)
    let path = OutDir / (&"pool-{seed}.json")
    writeFile(path, card.pretty & "\n")
    echo "wrote ", path, "  (archetype=", card["kind"]["archetype"].getStr,
      " playtype=", card["kind"]["playtype"].getStr,
      " static=", formatFloat(card["kind"]["static_score"].getFloat, ffDecimal, 3), ")"
    inc n
  echo "emitted ", n, " cards into ", OutDir, " (MapPoolSeeds.len=", MapPoolSeeds.len, ")"
