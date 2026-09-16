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

  test "battle-royale-s2 manifest entry carries no override -- the gate stays live for it":
    ## Elite/Campaign's fix is scoped to the classic templates below; this
    ## guards against "fix" meaning "defeat the gate for everyone".
    let s2GameConfig = manifestVariantConfig("battle-royale-s2")
    check not s2GameConfig.hasKey("allowDeprecatedModes")

  test "every classic manifest variant boots with the deprecated-mode override":
    ## Root cause of the game_unhealthy crash on Elite (resolves to "2v2")
    ## and Campaign (resolves to "1v1"/"2v2"/"4ffa", one per board cell
    ## mode): every classic (non-Season-2) template hits
    ## checkDeprecatedMode's CtfError at live boot unless its game_config
    ## carries allowDeprecatedModes: true. This loads each id's REAL shipped
    ## game_config out of the manifest file and boots it for real -- drop
    ## the flag from any one entry (or from the manifest generally) and
    ## only this test catches it; that's the discriminating property, not
    ## just an engine-level check against a hand-built config.
    ##
    ## Owner correction (2026-09-02): CTF is a fine game mode -- only the
    ## CTF *league* (a separate, still-retired thing) stays gone. So
    ## "default", "ctf-default", and "ctf-1v1" carry the override and boot
    ## here too, same as their siblings. "4ffa8", "paintball", and
    ## "battle-royale" also ride along: they are gated by this exact same
    ## non-variant-specific check, are not literally CTF (4ffa8 is 4ffa's
    ## own ruleset at double muster; paintball is a different loadout
    ## entirely; battle-royale is explicitly flagless), and leaving any of
    ## them refusing while their siblings boot would just be a landmine
    ## for whatever else references them. Every classic template is
    ## CTF-lineage in some sense, so singling any of them out would be
    ## arbitrary -- battle-royale-s2 is the one principled exception,
    ## because it is natively supported and needs no override at all.
    for variantId in ["2v2", "4ffa", "4ffa8", "default", "1v1",
        "ctf-default", "ctf-1v1", "paintball", "battle-royale"]:
      var config = defaultGameConfig()
      config.update($manifestVariantConfig(variantId))
      check config.allowDeprecatedModes
      config.checkDeprecatedMode()

  test "CTF-branded classic templates boot too -- only the CTF league stays gone":
    ## Inverted (2026-09-02): this test originally asserted "ctf-default",
    ## "ctf-1v1", and "default" (CTF in all but name -- its description is
    ## the byte-identical "Sixteen-player 8v8 CTF episode using the default
    ## balanced game settings." as ctf-default's) carried no override and
    ## still refused to boot, on the theory that "CTF stays gone" meant the
    ## game mode. Owner correction: it is the separate CTF *league*
    ## (league_key "ctf", enabled: false -- a platform/seed concern out of
    ## scope for this engine-level gate) that stays retired, not the CTF
    ## game mode itself; every classic template here is CTF-lineage. A
    ## revived CTF league would otherwise hit this exact boot gate for no
    ## reason, the same way Elite/Campaign did before PR #363. This test
    ## is now the inverse of its original self and deliberately redundant
    ## with the comprehensive test above, kept as a named regression guard
    ## on these three specific ids so nobody re-excludes them by
    ## copy-pasting this test's original (backwards) intent.
    for variantId in ["ctf-default", "ctf-1v1", "default"]:
      let gameConfig = manifestVariantConfig(variantId)
      check gameConfig.hasKey("allowDeprecatedModes")
      var config = defaultGameConfig()
      config.update($gameConfig)
      check config.allowDeprecatedModes
      config.checkDeprecatedMode()

  test "legacy replay fixture drives the real replay path without override":
    ## The fixture is cut by tools/record_fixture.sh, which boots the live
    ## server with the legacy override (a classic game refuses to boot
    ## without it since 2653b7cc) and echoShellKeys records that override in
    ## the header. The property under test is the REPLAY path's: the same
    ## classic config is refused at live boot without the override, yet the
    ## recording plays back regardless of it — playback never consults the
    ## seam. So the refusal is checked on the header minus the override,
    ## and playback is checked on the header as recorded.
    let data = loadReplay(ReplayFixture)
    var recorded = parseJson(data.configJson)
    if recorded.hasKey("allowDeprecatedModes"):
      recorded.delete("allowDeprecatedModes")
    var replayConfig = defaultGameConfig()
    replayConfig.update($recorded)
    replayConfig.expectDeprecatedRefusal("classic")

    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      let runtime = initReplayRuntime(
        data, mismatchQuit = true, gameEventLoggingEnabled = false)
      check runtime.sim.tickCount >= 0
      check not runtime.config.brMode          # it really is the classic game
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
