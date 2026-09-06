## ALLIANCE P1: the pact REGISTRY (formal-alliances design, 2026-09-02/03,
## GameVersion 54). Dark by design -- nothing in scoring reads `pactMask`
## yet, so these tests pin STATE/PLUMBING correctness
## (symmetry, config seeding + mutuality, dissolution, hash inclusion, and
## zero behavioral drift), never a glory number. See sim_types.nim's
## `pactMask`/`allies` field comments and sim_state.nim's
## registerPact/dissolvePact/clearPactsFor for the contracts this suite
## exercises.
import
  helpers,
  std/[json, unittest],
  ctf/sim

proc fourTeamPactConfig(): GameConfig =
  ## Four active teams (Red/Blue/Green/Yellow), one seat each -- enough
  ## teams to tell "this pair's pact" apart from "every pact this team
  ## holds" in the clearPactsFor / multi-pact cases below.
  result = defaultGameConfig()
  result.teams = 4
  result.mapPath = "gen"
  result.mapGen.layout = "corners"
  result.mapSeed = 42

proc fourTeamPactGame(): SimServer =
  result = initCtfForTest(fourTeamPactConfig())
  for i in 0 ..< 4:
    discard result.addPlayer("p" & $i)
  result.startGame()

proc namedPactConfig(alliesA, alliesB: seq[string]): GameConfig =
  ## Two named seats, Red ("alice") and Blue ("bob"), each with an
  ## independently configurable `allies` list -- the shape every mutuality
  ## case needs. Built by direct field construction (not JSON) so this test
  ## exercises resolveConfiguredPacts/teamForSlot in isolation from the JSON
  ## reader, which test_sim_config.nim-style cases below cover separately.
  result = defaultGameConfig()
  result.slots = @[
    PlayerSlotConfig(name: "alice", team: Red, hasTeam: true, allies: alliesA),
    PlayerSlotConfig(name: "bob", team: Blue, hasTeam: true, allies: alliesB),
  ]

proc namedPactGame(alliesA, alliesB: seq[string]): SimServer =
  result = initCtfForTest(namedPactConfig(alliesA, alliesB))
  discard result.addPlayer("alice")
  discard result.addPlayer("bob")
  result.startGame()

suite "alliance pact registry -- mutation invariants":
  test "registerPact sets both mirrored bits":
    var game = fourTeamPactGame()
    game.registerPact(Red, Blue)
    check game.pactActive(Red, Blue)
    check game.pactActive(Blue, Red)
    check (game.pactMask[Red] and (1'u16 shl ord(Blue))) != 0
    check (game.pactMask[Blue] and (1'u16 shl ord(Red))) != 0
    # Uninvolved teams stay untouched.
    check not game.pactActive(Green, Yellow)
    check game.pactMask[Green] == 0

  test "dissolvePact clears both mirrored bits and is idempotent":
    var game = fourTeamPactGame()
    game.registerPact(Red, Blue)
    game.dissolvePact(Red, Blue)
    check not game.pactActive(Red, Blue)
    check not game.pactActive(Blue, Red)
    game.dissolvePact(Red, Blue)  # dissolving an inactive pact is a no-op
    check not game.pactActive(Red, Blue)

  test "a team can hold multiple simultaneous pacts":
    var game = fourTeamPactGame()
    game.registerPact(Red, Blue)
    game.registerPact(Red, Green)
    check game.pactActive(Red, Blue)
    check game.pactActive(Red, Green)
    check not game.pactActive(Blue, Green)
    check not game.pactActive(Red, Yellow)

  test "clearPactsFor drops every pact one team holds, in both directions":
    var game = fourTeamPactGame()
    game.registerPact(Red, Blue)
    game.registerPact(Red, Green)
    game.registerPact(Blue, Yellow)  # unrelated to Red -- must survive
    game.clearPactsFor(Red)
    check game.pactMask[Red] == 0
    check not game.pactActive(Blue, Red)
    check not game.pactActive(Green, Red)
    check game.pactActive(Blue, Yellow)  # untouched

suite "alliance pact registry -- config seeding + mutuality":
  test "a mutual seed registers the pact at game start":
    let game = namedPactGame(@["bob"], @["alice"])
    check game.pactActive(Red, Blue)

  test "a unilateral seed is dropped, never registered":
    let game = namedPactGame(@["bob"], @[])
    check not game.pactActive(Red, Blue)

  test "an ally name that resolves to nobody is dropped, never registered":
    let game = namedPactGame(@["nobody-by-this-name"], @[])
    check not game.pactActive(Red, Blue)
    check game.pactMask[Red] == 0
    check game.pactMask[Blue] == 0

  test "no allies configured leaves every pact mask at zero":
    let game = namedPactGame(@[], @[])
    for team in game.teams():
      check game.pactMask[team] == 0

  test "readConfigSlots parses the allies array onto the slot":
    var config = defaultGameConfig()
    let raw = $(%*{
      "slots": [
        {"team": "red", "allies": ["bob"]},
        {"team": "blue", "allies": ["alice"]}
      ]
    })
    config.update(raw)
    check config.slots.len == 2
    check config.slots[0].allies == @["bob"]
    check config.slots[1].allies == @["alice"]

  test "readConfigSlots rejects a non-array allies field":
    var config = defaultGameConfig()
    let raw = $(%*{"slots": [{"team": "red", "allies": "bob"}]})
    expect(CtfError):
      config.update(raw)

  test "readConfigSlots rejects a non-string element inside allies":
    var config = defaultGameConfig()
    let raw = $(%*{"slots": [{"team": "red", "allies": [7]}]})
    expect(CtfError):
      config.update(raw)

  test "configJson round-trips a configured allies list":
    var config = defaultGameConfig()
    config.slots = @[
      PlayerSlotConfig(name: "alice", team: Red, hasTeam: true,
                        allies: @["bob"]),
      PlayerSlotConfig(name: "bob", team: Blue, hasTeam: true,
                        allies: @["alice"]),
    ]
    let node = parseJson(config.configJson())
    check node["slots"][0]["allies"].getElems().len == 1
    check node["slots"][0]["allies"][0].getStr() == "bob"

suite "alliance pact registry -- dissolution hooks":
  test "any damage between allied teams dissolves the pact immediately":
    var game = namedPactGame(@["bob"], @["alice"])
    check game.pactActive(Red, Blue)
    discard game.absorbDamage(1, 1, 0)  # seat 0 (Red/alice) hits seat 1 (Blue/bob)
    check not game.pactActive(Red, Blue)

  test "zero-amount damage does not dissolve a pact":
    var game = namedPactGame(@["bob"], @["alice"])
    discard game.absorbDamage(1, 0, 0)
    check game.pactActive(Red, Blue)

  test "damage between non-allied teams never touches an unrelated pact":
    var game = fourTeamPactGame()
    game.registerPact(Red, Blue)
    discard game.absorbDamage(2, 5, 3)  # Green hits Yellow -- unrelated
    check game.pactActive(Red, Blue)

  test "a seat's death clears its team's whole pact row and column":
    var game = fourTeamPactGame()
    game.registerPact(Red, Blue)
    game.registerPact(Red, Green)
    game.registerPact(Blue, Yellow)  # unrelated to Red -- must survive
    game.killPlayer(0, -1)  # seat 0 is Red (four-team round-robin deal)
    check game.pactMask[Red] == 0
    check not game.pactActive(Blue, Red)
    check not game.pactActive(Green, Red)
    check game.pactActive(Blue, Yellow)

  test "a new game never inherits a previous game's dissolved-or-registered pacts":
    var game = namedPactGame(@["bob"], @["alice"])
    check game.pactActive(Red, Blue)
    discard game.absorbDamage(1, 1, 0)
    check not game.pactActive(Red, Blue)
    game.startGame()  # resetGloryLedger reseeds from the same config
    check game.pactActive(Red, Blue)

suite "alliance pact registry -- hash inclusion":
  test "registering a pact moves gameHash":
    var game = fourTeamPactGame()
    let before = game.gameHash()
    game.registerPact(Red, Blue)
    let after = game.gameHash()
    check before != after

  test "dissolving a pact moves gameHash back":
    var game = fourTeamPactGame()
    let baseline = game.gameHash()
    game.registerPact(Red, Blue)
    check game.gameHash() != baseline
    game.dissolvePact(Red, Blue)
    check game.gameHash() == baseline

suite "alliance pact registry -- P1 is dark (no behavior may change)":
  test "a seeded mutual pact never alters the tick trajectory of anything but the hash":
    ## Twin-run: one sim seeded with a mutual pact, one with none, driven by
    ## the IDENTICAL input stream. Every player-visible field must match
    ## tick for tick -- P1 wires state and a hash, nothing else. Only
    ## `gameHash()` (which is SUPPOSED to move, per the suite above) is
    ## allowed to differ.
    var
      withPact = namedPactGame(@["bob"], @["alice"])
      noPact = namedPactGame(@[], @[])
    check withPact.pactActive(Red, Blue)
    check not noPact.pactActive(Red, Blue)
    for tick in 0 ..< 60:
      let inputs = withPact.none()
      let prev = withPact.none()
      withPact.step(inputs, prev)
      noPact.step(inputs, prev)
      for i in 0 ..< withPact.players.len:
        check withPact.players[i].x == noPact.players[i].x
        check withPact.players[i].y == noPact.players[i].y
        check withPact.players[i].hp == noPact.players[i].hp
        check withPact.players[i].alive == noPact.players[i].alive
        check withPact.players[i].team == noPact.players[i].team
        check withPact.players[i].kills == noPact.players[i].kills
        check withPact.players[i].deaths == noPact.players[i].deaths
      check withPact.phase == noPact.phase
      check withPact.tickCount == noPact.tickCount
    # The hash is the one thing allowed -- and expected -- to disagree.
    check withPact.gameHash() != noPact.gameHash()
