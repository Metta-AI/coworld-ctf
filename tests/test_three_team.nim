## THREE-team CTF: the contract for a mode the engine does not seat yet.
##
## A hexagon is the shape that makes 3 and 6 teams natural — C3 and C6 are
## subgroups of D6 the way a rectangle never offered — so "3-team hex" reads
## like something that must already half-work. It does not, and this file
## exists so that stays TRUE OUT LOUD rather than true by accident.
##
## The failure mode this guards against is the one that runs through the whole
## hex migration: in this codebase a geometry that is merely *unreachable*
## looks exactly like a geometry that is *correct*. Nothing crashes, no label
## goes missing, no log line appears — a 3-team config would simply resolve
## some board and seat somebody. So every refusal below is asserted to be a
## refusal WITH ITS REASON, and each one names the thing that must change:
##
##   * `symRot120` is refused by `validateMap` — the 120-degree orbit is not
##     pixel-exact (sin 60), so it has to be walked in CUBE coordinates and
##     rasterized once. `pixelImage` raises rather than rounding, which is the
##     whole point: a rounded rotation is silent team unfairness, exactly what
##     the deleted rot90 validator existed to prevent.
##   * `generateMapAttempt` is refused for any team count but 2.
##   * `resolveCtfMapMetadata` refuses a `teams` value no board seats.
##
## When the 3/6-team mode lands, these tests go RED and hand over the list of
## everything that has to be true. That is the intended way to delete them:
## replace each `expect` with the behaviour it was standing in for. Do NOT
## relax one to green without the geometry behind it — a 3-team board carried
## by a rounded rotation is unfair in a way no test here would catch.
import
  helpers,
  std/[strutils, unittest],
  ctf/[arena, sim, sim_types]

suite "three team ctf":
  test "the layout and symmetry EXIST in the wire vocabulary":
    ## They are spellable, and they round-trip through the spec's string
    ## forms — the mode is blocked on geometry, not on a missing enum. If this
    ## goes red the token was deleted, and every replay carrying it stops
    ## loading.
    check layoutHex3.teamCount() == 3
    check $symRot120 == "symRot120"

  test "a 120-degree rotation is REFUSED on the pixel lattice, not rounded":
    ## The load-bearing one. Only the identity, the two axis mirrors and the
    ## half turn act exactly on a square pixel lattice — precisely V4, which is
    ## every symmetry the 2- and 4-team boards use. C3 is not in it.
    let gameMap = hexTeamMap()
    for op in [hexRot120, hexRot240]:
      expect CtfError:
        discard gameMap.pixelImage(MapPoint(x: 100, y: 100), op)

  test "a hand-built 3-team spec is refused, with its reason":
    ## Built by hand so the refusal is not the GENERATOR's — those are two
    ## different gates and both have to hold. Note WHICH gate fires: the spec
    ## rebuild derives each team's capture zone through `teamImagePoint`, so
    ## `pixelImage` raises on the inexact rotation BEFORE `validateMap`'s own
    ## rot120 branch is ever reached. Both refuse; this pins the one that
    ## actually runs, so the message a 3-team author sees cannot silently
    ## become a rounded coordinate.
    var gameMap = hexTeamMap()
    gameMap.symmetry = symRot120
    gameMap.layout = layoutHex3
    var message = ""
    try:
      discard mapFromSpecJson(mapSpecJson(gameMap))
    except CtfError as err:
      message = err.msg
    check "not exact on a pixel lattice" in message
    check "cube coordinates" in message

  test "generating a 3-team map is refused":
    var config = defaultGameConfig()
    config.teams = 3
    config.mapPath = "gen"
    config.mapSeed = 4242
    var message = ""
    try:
      discard resolveCtfMapMetadata(config)
    except CtfError as err:
      message = err.msg
    check "2-team maps only" in message

  test "no NAMED board seats three teams":
    ## The 4-team escape hatch is a named hand-authored board; there is no
    ## 3-team equivalent, so `teams: 3` has nowhere to land at all. This is the
    ## test that goes red the moment someone adds one — which is the point at
    ## which the rest of this file needs revisiting.
    for name in ["arena", "arena-large", "arena-hex4", "arena-hex4-giant"]:
      check loadCtfMapMetadata(name).teamCount() != 3
