import
  helpers,
  std/[json, os, strutils, unittest],
  ctf/[replay_runtime, replays, sim],
  shell/[episode, runtime_boot]

const
  ReplayFixture = GameDir / "tests" / "replays" / "ctf.bitreplay"
  ManifestName = GameDir / "coworld_manifest_paintbot.json"

proc expectDeprecatedRefusal(config: GameConfig, expectedTriggers: string) =
  var caught = false
  try:
    config.checkDeprecatedMode()
  except CtfError as error:
    caught = true
    check "deprecated since 0.7.253" in error.msg
    check "allowDeprecatedModes" in error.msg
    check "[" & expectedTriggers & "]" in error.msg
  check caught

proc manifestVariantConfig(variantId: string): JsonNode =
  for variant in parseFile(ManifestName)["variants"]:
    if variant["id"].getStr() == variantId:
      return variant["game_config"]
  raise newException(ValueError, "missing manifest variant " & variantId)

suite "deprecated live-mode boot seam":
  test "classic live config refuses unless the override is set":
    var classic = defaultGameConfig()
    classic.numAgents = 16
    classic.brMode = false
    classic.expectDeprecatedRefusal("classic")

    classic.allowDeprecatedModes = true
    classic.checkDeprecatedMode()

  test "each trigger is named and multiple triggers stay ordered":
    block:
      var config = defaultGameConfig()
      config.brMode = true
      config.season2Shell = false
      config.expectDeprecatedRefusal("season1Shell")
    block:
      var config = defaultGameConfig()
      config.brMode = true
      config.loadout = LoadoutPaintball
      config.expectDeprecatedRefusal("paintball")
    block:
      var config = defaultGameConfig()
      config.brMode = true
      config.floorPaint = true
      config.expectDeprecatedRefusal("paintball")
    block:
      var config = defaultGameConfig()
      config.brMode = true
      config.paintBuff = true
      config.expectDeprecatedRefusal("paintball")
    block:
      var config = defaultGameConfig()
      config.brMode = true
      config.hill = true
      config.expectDeprecatedRefusal("paintball")
    block:
      var config = defaultGameConfig()
      config.brMode = true
      config.numAgents = 16
      config.cogsPerTeam = 4
      config.expectDeprecatedRefusal("squadMode")
    block:
      var config = defaultGameConfig()
      config.brMode = false
      config.season2Shell = false
      config.loadout = LoadoutPaintball
      config.numAgents = 16
      config.cogsPerTeam = 4
      config.expectDeprecatedRefusal(
        "classic, season1Shell, paintball, squadMode")

  test "season 2 battle royale shape does not refuse":
    var config = defaultGameConfig()
    config.brMode = true
    check config.season2Shell
    check config.loadout == LoadoutCtf
    check not config.floorPaint
    check not config.paintBuff
    check not config.hill
    check config.cogsPerTeam == 1
    config.checkDeprecatedMode()

  test "landed battle-royale-s2 manifest variant matches the supported shape":
    var config = defaultGameConfig()
    config.update($manifestVariantConfig("battle-royale-s2"))
    config.checkDeprecatedMode()

  test "legacy replay fixture drives the real replay path without override":
    let data = loadReplay(ReplayFixture)
    var replayConfig = defaultGameConfig()
    replayConfig.update(data.configJson)
    replayConfig.expectDeprecatedRefusal("classic")

    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      let runtime = initReplayRuntime(
        data, mismatchQuit = true, gameEventLoggingEnabled = false)
      check runtime.sim.tickCount >= 0
      check not runtime.config.allowDeprecatedModes
    finally:
      setCurrentDir(previousDir)

  test "echo rules for the live legacy override":
    var config = defaultGameConfig()
    config.update($ %*{"allowDeprecatedModes": true})
    let node = parseJson(config.configJson())
    check not node.hasKey("season2Shell")
    check node["allowDeprecatedModes"].getBool()

  test "runtime-stub binary refuses live play seats but not non-play configs":
    var noPlay = defaultGameConfig()
    noPlay.brMode = true
    noPlay.checkPlayRuntimeAvailable()

    var playSeat = defaultGameConfig()
    playSeat.update($ %*{
      "brMode": true,
      "minPlayers": 2,
      "closedRoster": true,
      "players": [{"name": "alpha"}, {"name": "beta"}],
      "tokens": ["t-alpha", "t-beta"],
      "slots": [{"team": "red", "control": "play"}, {"team": "blue"}]
    })
    when ShellRuntimeAvailable:
      playSeat.checkPlayRuntimeAvailable()
    else:
      var caught = false
      try:
        playSeat.checkPlayRuntimeAvailable()
      except CtfError as error:
        caught = true
        check "this binary was built without the play runtime" in error.msg
      check caught

  test "runtime-stub refusal exempts replay by caller placement":
    let data = loadReplay(ReplayFixture)
    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      let runtime = initReplayRuntime(
        data, mismatchQuit = true, gameEventLoggingEnabled = false)
      check runtime.sim.tickCount >= 0
    finally:
      setCurrentDir(previousDir)
