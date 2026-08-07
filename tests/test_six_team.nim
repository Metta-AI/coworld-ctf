## SIX-team CTF: the contract for a mode blocked one layer deeper than 3-team.
##
## Read `tests/test_three_team.nim` first — the geometry half of the story is
## identical (C6 contains C3, so `symRot60` is refused for exactly the reason
## `symRot120` is: 60- and 120-degree rotations are not exact on a square pixel
## lattice and must be walked in cube coordinates).
##
## What makes 6 teams DIFFERENT, and why it gets its own file: the blocker is
## not only geometry. `Team` has four members. A game's active teams are always
## a prefix of that enum, so 5 and 6 have no name to be called by — not a
## rounded coordinate, not a missing board, an absent identity. Everything
## keyed to the enum widens with it: team colors on the wire, the label
## vocabulary a policy reads, sprite pool seats, the scoring pot's
## per-loser split. That is the "enum growth, sprite pool relayout" work, and
## it is why `validateMap` refuses `layoutHex6` with a DIFFERENT message than
## it refuses `symRot60`.
##
## Both refusals are pinned below, separately and by their own text, because
## they will be lifted at different times: the geometry can land (Stage 2b)
## while the enum is still four wide, and a 6-team board that validates on a
## 4-member enum would seat two teams into nothing at all.
import
  helpers,
  std/[strutils, unittest],
  ctf/[arena, sim, sim_types]

suite "six team ctf":
  test "the layout EXISTS in the wire vocabulary but the enum does not reach it":
    ## The two halves of the blocker, side by side. `layoutHex6` is spellable
    ## and says 6; `Team` stops at four. This check is the whole task in one
    ## line, and it goes red the moment the enum grows — which is exactly when
    ## the rest of this file needs rewriting rather than relaxing.
    check layoutHex6.teamCount() == 6
    check int(Team.high) + 1 == 4

  test "60-degree rotations are REFUSED on the pixel lattice, not rounded":
    ## C6 = {e, 60, 120, 180, 240, 300}. Exactly one non-identity element of it
    ## (the half turn) is exact on the pixel lattice; the other four are not,
    ## so a 6-team board cannot be built by the pixel-exact path at all.
    let gameMap = hexTeamMap()
    var exact = 0
    for op in [hexRot60, hexRot120, hexRot180, hexRot240, hexRot300]:
      try:
        discard gameMap.pixelImage(MapPoint(x: 100, y: 100), op)
        inc exact
      except CtfError:
        discard
    check exact == 1

  test "a 6-team LAYOUT is refused for the enum, not for the geometry":
    ## Deliberately paired with a symmetry that IS pixel-exact, so the only
    ## thing left to refuse is the team count. If this ever starts reporting a
    ## geometry reason instead, the enum check has been lost.
    var gameMap = hexTeamMap()
    gameMap.layout = layoutHex6
    var message = ""
    try:
      discard mapFromSpecJson(mapSpecJson(gameMap))
    except CatchableError as err:
      message = err.msg
    check "Team enum" in message
    check "cube" notin message
    ## And it must be CATCHABLE. This started life as a `doAssert` inside
    ## `activeTeams`, which the spec rebuild reaches while deriving zones — so
    ## a `layout: "hex6"` string arriving from a config or a replay spec took
    ## the whole process down with an AssertionDefect instead of being
    ## rejected as a bad map, and vanished altogether under `-d:danger`. The
    ## `try/except CatchableError` above IS the assertion; it would not have
    ## caught a Defect.

  test "a 6-team SYMMETRY is refused for the geometry":
    ## The other half, with its own message — these are lifted at different
    ## times, so they are asserted apart.
    var gameMap = hexTeamMap()
    gameMap.symmetry = symRot60
    var message = ""
    try:
      discard mapFromSpecJson(mapSpecJson(gameMap))
    except CtfError as err:
      message = err.msg
    check message.len > 0
    check "Team enum" notin message

  test "generating a 6-team map is refused":
    var config = defaultGameConfig()
    config.teams = 6
    config.mapPath = "gen"
    config.mapSeed = 4242
    var message = ""
    try:
      discard resolveCtfMapMetadata(config)
    except CatchableError as err:
      message = err.msg
    check message.len > 0

  test "no NAMED board seats more than four teams":
    for name in ["arena", "arena-large", "arena-hex4", "arena-hex4-giant"]:
      check loadCtfMapMetadata(name).teamCount() <= 4
