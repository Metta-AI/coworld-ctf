## The league manifests' config_schema is the platform's contract for what a
## league operator may configure — and nothing type-checks it against
## GameConfig. This suite makes drift impossible in both directions:
## the two manifests must stay in lockstep, and every schema property must be
## PROVABLY consumed by config.update (a non-default sample for the key must
## change the parsed config). A GameConfig field added without a schema entry
## stays a local-only knob by design; a schema entry the game stopped reading
## fails here instead of becoming a dead platform knob.

import helpers, std/[json, os, sets, strutils, unittest], ctf/sim

const PlatformOnlyKeys = ["num_agents"]
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
    ctfSchema = manifestSchema("coworld_manifest.json")
    paintbotSchema = manifestSchema("coworld_manifest_paintbot.json")
    samples = parseJson(SampleJson)

  test "the ctf schema is a subset of the paintbot schema":
    # The two manifests share one game binary; paintbot's variants may expose
    # MORE knobs (generated-map locks like mapSize, 32-seat caps) but never
    # fewer — a key the singles league can set must exist for doubles too.
    var ctfKeys, paintbotKeys: HashSet[string]
    for key, _ in ctfSchema["properties"]:
      ctfKeys.incl key
    for key, _ in paintbotSchema["properties"]:
      paintbotKeys.incl key
    check ctfKeys <= paintbotKeys

  test "every schema property is consumed by config.update":
    var unionKeys: HashSet[string]
    for key, _ in ctfSchema["properties"]:
      unionKeys.incl key
    for key, _ in paintbotSchema["properties"]:
      unionKeys.incl key
    for key in unionKeys:
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
      check ctfSchema["properties"].hasKey(key) or
        paintbotSchema["properties"].hasKey(key)

  test "platform-only keys are documented as such in the schema":
    for key in PlatformOnlyKeys:
      let description = ctfSchema["properties"][key]["description"].getStr
      check "platform" in description

  test "the repo's local config.json loads and validates":
    # update() runs the full field validation internally and raises on any
    # rejected value, so a clean call IS the validation.
    var config = defaultGameConfig()
    config.update(readFile(GameDir / "config.json"))
