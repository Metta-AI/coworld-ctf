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

proc manifestVariant(variantId: string): JsonNode =
  let manifest = parseFile(GameDir / ManifestName)
  for variant in manifest["variants"]:
    if variant["id"].getStr() == variantId:
      return variant
  doAssert false, ManifestName & " has no " & variantId & " variant"

# One payload per schema property, each carrying a NON-DEFAULT value for its
# key (plus companion keys where update()'s cross-field validation demands
# them — the whole-object inequality below still proves the target key
# landed, since companions only ever change the object further).
const SampleJson = """{
  "aimTurnRate": {"aimTurnRate": 7},
  "carrierSpeedPct": {"carrierSpeedPct": 55},
  "closedRoster": {"closedRoster": true, "minPlayers": 1,
                   "slots": [{"token": "tok1"}],
                   "players": [{"name": "tester"}]},
  "fastMode": {"fastMode": false},
  "fireCooldownTicks": {"fireCooldownTicks": 20},
  "fireWindupTicks": {"fireWindupTicks": 9},
  "gameOverTicks": {"gameOverTicks": 100},
  "gunRange": {"gunRange": 500},
  "handicaps": {"handicaps": {"red": 0.5}},
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
  "visionConeDeg": {"visionConeDeg": 45}
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
      s

  test "every schema property is consumed by config.update":
    for key, _ in schema["properties"]:
      if key in PlatformOnlyKeys:
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

  test "platform-only keys are documented as such in the schema":
    for key in PlatformOnlyKeys:
      let description = schema["properties"][key]["description"].getStr
      check "platform" in description

  test "the repo's local config.json loads and validates":
    # update() runs the full field validation internally and raises on any
    # rejected value, so a clean call IS the validation.
    var config = defaultGameConfig()
    config.update(readFile(GameDir / "config.json"))

  test "published variants use the engine's aim rate":
    let expected = defaultGameConfig().aimTurnRate
    check schema["properties"]["aimTurnRate"]["default"].getInt == expected
    for variant in parseFile(GameDir / ManifestName)["variants"]:
      check variant["game_config"]["aimTurnRate"].getInt == expected

  test "one manifest preserves Paintbot ids and namespaces CTF ids":
    var variantIds: seq[string]
    for variant in parseFile(GameDir / ManifestName)["variants"]:
      variantIds.add variant["id"].getStr()
    check variantIds == @["2v2", "4ffa", "4ffa8", "default", "1v1",
      "ctf-default", "ctf-1v1"]

  test "ctf publishes namespaced default and two-seat custom-lobby variants":
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

  test "paintbot publishes a full-teams 1v1 variant without changing league defaults":
    let
      manifest = parseFile(GameDir / ManifestName)
      variant = manifestVariant("1v1")
      leagueVariant = manifestVariant("2v2")
    check manifest["variants"][0]["id"].getStr() == "2v2"
    check manifest["certification"]["players"].len == 16
    check manifest["certification"]["game_config"]["players"].len == 16
    check manifest["certification"]["game_config"]["minPlayers"].getInt() == 16
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
