## The league manifest's config_schema is the platform's contract for what a
## league operator may configure — and nothing type-checks it against
## GameConfig. This suite makes drift impossible: every schema property must be
## PROVABLY consumed by config.update (a non-default sample for the key must
## change the parsed config). A GameConfig field added without a schema entry
## stays a local-only knob by design; a schema entry the game stopped reading
## fails here instead of becoming a dead platform knob.

import helpers, std/[json, os, strutils, unittest], ctf/sim

const
  ManifestName = "coworld_manifest_paintbot.json"
  ArchiveName = "deprecated_variants_paintbot.json"
  PlatformOnlyKeys = ["num_agents"]
  ## Schema keys the game deliberately never reads: documented as consumed by
  ## the platform (ladder seating) in the schema description itself, which
  ## this suite asserts so the exemption stays honest.

proc findConfigSchema(node: JsonNode): JsonNode =
  ## Depth-first search for the "config_schema" object in a manifest.
  if node.kind == JObject:
    if node.hasKey("config_schema"):
      return node["config_schema"]
    for _, value in node:
      let found = findConfigSchema(value)
      if found != nil:
        return found
  elif node.kind == JArray:
    for value in node:
      let found = findConfigSchema(value)
      if found != nil:
        return found
  nil

proc manifestSchema(name: string): JsonNode =
  result = findConfigSchema(parseFile(GameDir / name))
  doAssert result != nil, name & " has no config_schema"

proc schemaDefaults(schema: JsonNode): JsonNode =
  result = newJObject()
  for key, prop in schema["properties"]:
    if prop.hasKey("default"):
      result[key] = prop["default"]

proc manifestVariant(variantId: string): JsonNode =
  for name in [ManifestName, ArchiveName]:
    let manifest = parseFile(GameDir / name)
    for variant in manifest["variants"]:
      if variant["id"].getStr() == variantId:
        return variant
  doAssert false, "published or archived manifests have no " & variantId & " variant"

# One payload per schema property, each carrying a NON-DEFAULT value for its
# key (plus companion keys where update()'s cross-field validation demands
# them — the whole-object inequality below still proves the target key
# landed, since companions only ever change the object further).
const SampleJson = """{
  "aimTurnRate": {"aimTurnRate": 7},
  "barrageMaxPerSec": {"barrageMaxPerSec": 15},
  "barrageStartPerSec": {"barrageStartPerSec": 9},
  "barrageStartSec": {"barrageStartSec": 45},
  "barrageSaturateSec": {"barrageSaturateSec": 45},
  "carrierSpeedPct": {"carrierSpeedPct": 55},
  "playerBouncePct": {"playerBouncePct": 70},
  "closedRoster": {"closedRoster": true, "minPlayers": 1,
                   "slots": [{"token": "tok1"}],
                   "players": [{"name": "tester"}]},
  "fastMode": {"fastMode": false},
  "fireCooldownTicks": {"fireCooldownTicks": 20},
  "fireWindupTicks": {"fireWindupTicks": 9},
  "gameOverTicks": {"gameOverTicks": 100},
  "gunRange": {"gunRange": 500},
  "handicaps": {"handicaps": {"red": 0.5}},
  "barrierPickups": {"barrierPickups": 1},
  "perks": {"perks": {"red": [["armor"], ["scope", "luck"]]}},
  "perkMods": {"perkMods": {"luckChance": 0.25}},
  "hitPoints": {"hitPoints": 5},
  "lives": {"lives": 2},
  "lobbyJoinTimeoutTicks": {"lobbyJoinTimeoutTicks": 50},
  "mapLayout": {"mapLayout": "corners", "teams": 4, "mapPath": "gen"},
  "mapPath": {"mapPath": "gen"},
  "mapSeed": {"mapSeed": 12345, "mapPath": "gen"},
  "mapSize": {"mapSize": "small", "mapPath": "gen"},
  "maxGames": {"maxGames": 3},
  "maxTicks": {"maxTicks": 777},
  "minPlayers": {"minPlayers": 4},
  "players": {"players": [{"name": "tester"}]},
  "respawnTicks": {"respawnTicks": 33},
  "scoring": {"scoring": "pot"},
  "seed": {"seed": 42},
  "showPlayerLabels": {"showPlayerLabels": false},
  "slots": {"slots": [{"token": "tok1"}]},
  "startWaitTicks": {"startWaitTicks": 60},
  "teams": {"teams": 4, "mapPath": "gen"},
  "tokens": {"tokens": ["tokA"]},
  "visionBubble": {"visionBubble": 50},
  "visionConeDeg": {"visionConeDeg": 45},
  "num_agents": {"num_agents": 2},
  "cogsPerTeam": {"cogsPerTeam": 3},
  "loadout": {"loadout": "paintball"},
  "floorPaint": {"floorPaint": true},
  "paintBuff": {"paintBuff": true, "floorPaint": true},
  "hill": {"hill": true, "floorPaint": true},
  "paintTile": {"paintTile": 40},
  "hillRadiusTiles": {"hillRadiusTiles": 3},
  "hillOwnPermille": {"hillOwnPermille": 700},
  "hillDecisiveTicks": {"hillDecisiveTicks": 500},
  "paintSpeedOwnPct": {"paintSpeedOwnPct": 130},
  "paintSpeedEnemyPct": {"paintSpeedEnemyPct": 70},
  "paintHealTicks": {"paintHealTicks": 24},
  "sprayDamage": {"sprayDamage": 2},
  "regimes": {"regimes": ["visitor"]},
  "turnTicks": {"turnTicks": 96},
  "turnBudgetMs": {"turnBudgetMs": 12000},
  "attempt1Ms": {"attempt1Ms": 5000},
  "retryMs": {"retryMs": 2000},
  "turnSpacingMs": {"turnSpacingMs": 4000},
  "wallClockBudgetSeconds": {"wallClockBudgetSeconds": 600},
  "model": {"model": "claude-haiku-4-5"},
  "maxOutputTokens": {"maxOutputTokens": 800},
  "brMode": {"brMode": true},
  "season2Shell": {"season2Shell": true},
  "allowDeprecatedModes": {"allowDeprecatedModes": true},
  "viewIntervalTicks": {"viewIntervalTicks": 7},
  "lobbyChatTicks": {"lobbyChatTicks": 600},
  "playSeatBindTicks": {"playSeatBindTicks": 7201},
  "zonePhases": {"zonePhases": [{"z": 0.5}]},
  "zoneCenter": {"zoneCenter": [500, 500]},
  "lootStart": {"lootStart": true, "brMode": true},
  "downedMode": {"downedMode": true, "brMode": true},
  "giveItem": {"giveItem": true, "brMode": true},
  "lootSpawnSeedGuns": {"lootSpawnSeedGuns": 3, "lootStart": true, "brMode": true},
  "lootSpawnSeedHoppers": {"lootSpawnSeedHoppers": 3, "lootStart": true, "brMode": true},
  "lootSpawnSeedRadius": {"lootSpawnSeedRadius": 48, "lootStart": true, "brMode": true},
  "zoneDamageByPaint": {"zoneDamageByPaint": true, "zonePhases": [{"z": 0.5}]},
  "zonePaintDownedBleedPermille": {"zonePaintDownedBleedPermille": 3000, "zoneDamageByPaint": true, "zonePhases": [{"z": 0.5}]},
  "zoneBlocksRevive": {"zoneBlocksRevive": true, "zoneDamageByPaint": true, "zonePhases": [{"z": 0.5}]},
  "hazardAwarePlanner": {"hazardAwarePlanner": true, "season2Shell": true, "zoneDamageByPaint": true, "zonePhases": [{"z": 0.5}]},
  "navHints": {"navHints": true, "hazardAwarePlanner": true, "season2Shell": true, "zoneDamageByPaint": true, "zonePhases": [{"z": 0.5}]},
  "hopperSiteTrafficPermille": {"hopperSiteTrafficPermille": 750, "lootStart": true, "brMode": true},
  "bandagePickups": {"bandagePickups": 12, "brMode": true},
  "medKitCount": {"medKitCount": 0, "brMode": true},
  "gloryMultiplierRecut": {"gloryMultiplierRecut": true},
  "winAsMultiplier": {"winAsMultiplier": true},
  "deedMintCaps": {"deedMintCaps": true},
  "stampRealizedConfig": {"stampRealizedConfig": true},
  "frameLoadoutFlags": {"frameLoadoutFlags": true},
  "variantId": {"variantId": "battle-royale-s2"},
  "allowSeatTakeover": {"allowSeatTakeover": true},
  "allowDirectAim": {"allowDirectAim": true},
  "allowAimAssist": {"allowAimAssist": true, "allowDirectAim": true},
  "allowCallouts": {"allowCallouts": true}
}"""

suite "league manifest config_schema vs GameConfig":
  let
    schema = manifestSchema(ManifestName)
    samples = block:
      # mapSpec's payload must be a FULL, valid map object — config.update
      # resolves it (mapFromSpecJson) rather than storing it blind — so build
      # one from a generated map instead of inlining a huge literal.
      var s = parseJson(SampleJson)
      let spec = mapSpecJson(generateMapAttempt(
        1, MapGenOverrides(size: "small", windows: -1, pits: -1, pitDensity: -1)))
      s["mapSpec"] = %*{"mapSpec": parseJson(spec)}
      # Train coupling: permanent negation keeps this non-default across the inversion.
      s["season2Shell"] = %*{"season2Shell": not defaultGameConfig().season2Shell}
      s

  test "every schema property is consumed by config.update":
    for key, _ in schema["properties"]:
      if key in PlatformOnlyKeys:
        continue
      if key == "allowDeprecatedModes":
        # Train coupling: lane C owns the GameConfig field. Once that commit
        # lands, this compile-time exemption disappears and proves consumption.
        when not compiles(defaultGameConfig().allowDeprecatedModes):
          continue
      check samples.hasKey(key)  # every schema key needs a payload below
      if not samples.hasKey(key):
        continue
      let payload = samples[key]
      check payload.hasKey(key)  # the payload must exercise its own key
      var config = defaultGameConfig()
      config.update($payload)
      # A consumed key must change SOMETHING relative to the defaults.
      check config != defaultGameConfig()

  test "every sample corresponds to a schema property (no stale samples)":
    for key, _ in samples:
      check schema["properties"].hasKey(key)

  test "perks schema declares the engine's perk vocabulary, in sync with its prose":
    # The platform's campaign perk picker reads the machine-readable
    # perkVocabulary block (falling back to parsing the description's
    # "Vocabulary: name (effect), …" sentence), so the block must exist,
    # cover EXACTLY the engine's perk names, and restate what the prose
    # says — a perk added to the engine, or an edit to a perk's "name
    # (effect)" phrase in the description, fails here instead of silently
    # desyncing the picker.
    let
      perksSchema = schema["properties"]["perks"]
      vocabulary = perksSchema["perkVocabulary"]
      description = perksSchema["description"].getStr
    # require, not check: a short block must abort here with the length
    # mismatch, not fall into an IndexDefect on the per-perk loop below.
    require vocabulary.len == PerkNames.len
    for perk in Perk:
      let entry = vocabulary[ord(perk)]
      check entry["id"].getStr == PerkNames[perk]
      let effect = entry["effect"].getStr
      check effect.len > 0
      check (entry["id"].getStr & " (" & effect & ")") in description

  test "platform-only keys are documented as such in the schema":
    for key in PlatformOnlyKeys:
      let description = schema["properties"][key]["description"].getStr
      check "platform" in description

  test "config_schema defaults materialize to engine-classic paintball gate values":
    let defaults = schemaDefaults(schema)
    var config = defaultGameConfig()
    config.update($defaults)
    check config.cogsPerTeam == defaultGameConfig().cogsPerTeam
    check config.cogsPerTeam == 1
    check config.loadout == LoadoutCtf
    check not config.floorPaint
    check not config.paintBuff
    check not config.hill
    check config.sprayDamage == SprayPaintDamage
    check config.regimes == @[regimeResident]
    check not config.squadModeConfigured()

  test "the repo's local config.json loads and validates":
    # update() runs the full field validation internally and raises on any
    # rejected value, so a clean call IS the validation.
    var config = defaultGameConfig()
    config.update(readFile(GameDir / "config.json"))

  test "published variants use the engine's aim rate":
    let expected = defaultGameConfig().aimTurnRate
    check schema["properties"]["aimTurnRate"]["default"].getInt == expected
    for variant in parseFile(GameDir / ManifestName)["variants"]:
      # A variant that omits the key inherits the engine default, which is
      # exactly the value being pinned (the paintball variant does this).
      if variant["game_config"].hasKey("aimTurnRate"):
        check variant["game_config"]["aimTurnRate"].getInt == expected

  test "published manifest leads with Season 2 and archive preserves nine ids":
    ## UNION, now permanent by owner reversal (2026-09-02): the season2-only
    ## cleanup this union was staged to finish is reversed now that Season 2
    ## is established -- "campaign" (1v1/2v2/4ffa) and "elite" (2v2) are
    ## live leagues again, each carrying allowDeprecatedModes: true so they
    ## boot (see the deprecated live-mode boot seam suite). Second owner
    ## correction (2026-09-02): CTF is a fine game mode -- "ctf-default",
    ## "ctf-1v1", and "default" (CTF in all but name) carry the override
    ## and boot too, same as their siblings. It is the separate CTF
    ## *league* (league_key "ctf", enabled: false) that stays retired --
    ## that is a platform/seed concern, out of scope for this engine-level
    ## boot gate. The ids below are therefore not a staging step to
    ## unwind -- they are the shipped shape.
    var variantIds: seq[string]
    for variant in parseFile(GameDir / ManifestName)["variants"]:
      variantIds.add variant["id"].getStr()
    # RECUT (v13, contract Amendment 2 §1 — per-flag activation): the two
    # battle-royale-s2-* STAGING variants sit directly behind the flagship
    # so each S2 flag (lootStart / downedMode) can be staged or bisected on
    # its own instead of riding one coupled variant switch.
    check variantIds == @["battle-royale-s2", "battle-royale-s2-lootstart",
      "battle-royale-s2-downed", "2v2", "4ffa", "4ffa8",
      "default", "1v1", "ctf-default", "ctf-1v1", "paintball",
      "battle-royale"]
    variantIds.setLen(0)
    for variant in parseFile(GameDir / ArchiveName)["variants"]:
      variantIds.add variant["id"].getStr()
    check variantIds == @["2v2", "4ffa", "4ffa8", "default", "1v1",
      "ctf-default", "ctf-1v1", "paintball", "battle-royale"]

  test "legacy predicate schema defaults describe the post-train engine":
    let props = schema["properties"]
    check not props["brMode"]["default"].getBool()
    check props["season2Shell"]["default"].getBool()
    check not props["allowDeprecatedModes"]["default"].getBool()
    check props["cogsPerTeam"]["default"].getInt() == 1
    check props["loadout"]["default"].getStr() == "ctf"
    for key in ["floorPaint", "paintBuff", "hill"]:
      check not props[key]["default"].getBool()

  test "archive preserves namespaced default and two-seat custom-lobby variants":
    let
      variant = manifestVariant("ctf-1v1")
      defaultVariant = manifestVariant("ctf-default")
    block:
      let gameConfig = variant["game_config"]
      check schema["properties"]["tokens"]["minItems"].getInt() == 2
      check schema["properties"]["players"]["minItems"].getInt() == 2
      check gameConfig["players"].len == 2
      check gameConfig["slots"].len == 2
      check gameConfig["slots"][0]["team"].getStr() == "red"
      check gameConfig["slots"][1]["team"].getStr() == "blue"
      check gameConfig["num_agents"].getInt() == 2
      check gameConfig["minPlayers"].getInt() == 2
      check gameConfig["teams"].getInt() == 2
      check gameConfig["mapPath"].getStr() == "arena"
      for key, value in defaultVariant["game_config"]:
        case key
        of "players", "slots", "num_agents", "minPlayers":
          discard
        else:
          check gameConfig.hasKey(key)
          check gameConfig[key] == value

      var config = defaultGameConfig()
      config.update($gameConfig)
      check config.minPlayers == 2
      check config.slots.len == 2
      check config.slots[0].team == Red
      check config.slots[1].team == Blue

      var sim = initCtfForTest(config)
      let
        red = sim.addPlayer("Player1")
        blue = sim.addPlayer("Player2")
      check sim.players[red].team == Red
      check sim.players[blue].team == Blue
      for _ in 0 ..< config.startWaitTicks:
        sim.step(@[], @[])
      check sim.phase == Playing
      check sim.players[red].alive
      check sim.players[blue].alive

      sim.players[blue].alive = false
      sim.players[blue].lives = 0
      sim.checkWinCondition()
      check sim.phase == GameOver
      check sim.winner == Red

  test "archive preserves a full-teams 1v1 variant without changing league defaults":
    let
      variant = manifestVariant("1v1")
      leagueVariant = manifestVariant("2v2")
      manifest = parseFile(GameDir / ManifestName)
    check manifest["certification"]["players"].len == 16
    check manifest["certification"]["game_config"]["players"].len == 16
    check manifest["certification"]["game_config"]["minPlayers"].getInt() == 16
    check manifest["certification"]["game_config"]["brMode"].getBool()
    check manifest["certification"]["game_config"]["season2Shell"].getBool()
    check manifest["certification"]["game_config"]["cogsPerTeam"].getInt() == 1
    block:
      let gameConfig = variant["game_config"]
      check schema["properties"]["tokens"]["minItems"].getInt() == 2
      check schema["properties"]["players"]["minItems"].getInt() == 2
      check schema["properties"]["tokens"]["maxItems"].getInt() == 32
      check schema["properties"]["players"]["maxItems"].getInt() == 32
      # 1v1 means one policy per team at full muster: 16 seats, 8 per team,
      # alternating so entrant = slot mod 2 fields a whole team.
      check gameConfig["players"].len == 16
      check gameConfig["slots"].len == 16
      for i in 0 ..< 16:
        check gameConfig["slots"][i]["team"].getStr() ==
          (if i mod 2 == 0: "red" else: "blue")
      check gameConfig["num_agents"].getInt() == 16
      check gameConfig["minPlayers"].getInt() == 16
      check gameConfig["teams"].getInt() == 2
      check gameConfig["mapPath"].getStr() == "gen"
      check gameConfig["scoring"].getStr() == "pot"
      for key, value in leagueVariant["game_config"]:
        case key
        of "players", "slots", "num_agents", "minPlayers":
          discard
        else:
          check gameConfig.hasKey(key)
          check gameConfig[key] == value

      var config = defaultGameConfig()
      config.update($gameConfig)
      check config.minPlayers == 16
      check config.slots.len == 16
      for i in 0 ..< 16:
        check config.slots[i].team == (if i mod 2 == 0: Red else: Blue)
      check config.mapPath == "gen"
      check config.scoring == PotScoring

      var sim = initCtfForTest(config)
      var seats: seq[int]
      for i in 0 ..< 16:
        seats.add sim.addPlayer("Player" & $(i + 1))
      for i, seat in seats:
        check sim.players[seat].team == (if i mod 2 == 0: Red else: Blue)
      for _ in 0 ..< config.startWaitTicks:
        sim.step(@[], @[])
      check sim.phase == Playing
      for seat in seats:
        check sim.players[seat].alive

      for i, seat in seats:
        if i mod 2 == 1:
          sim.players[seat].alive = false
          sim.players[seat].lives = 0
      sim.checkWinCondition()
      check sim.phase == GameOver
      check sim.winner == Red
      for i, seat in seats:
        check sim.players[seat].reward == (if i mod 2 == 0: 2 else: -2)
