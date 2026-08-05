import
  helpers,
  std/[base64, json, os, strutils, unittest],
  bitworld/spriteprotocol,
  pixie,
  ctf/[sim_types, team_colors]

# The display-color funnel (docs/COLOR_CONTRACT.md).
#
# Three properties this file exists to hold:
#
#  1. NO PARAM => STOCK. Every lookup with no mapping installed is the exact
#     value the engine used before the feature existed. This is the regression
#     bar: an old replay must render pixel-identical.
#  2. GRACEFUL AT EVERY LEVEL. Garbage base64, garbage JSON, an unknown payload
#     version, a missing team key, an unknown slug — each falls back to stock
#     and NONE of them raise. The viewer must never blank over this param.
#  3. THE WIRE IS UNTOUCHED. `teamText` still says red|blue|green|yellow no
#     matter what a team is painted, because 15 label families are built on
#     those words and a rename blinds every league policy silently.
#
# Every test resets the process-global mapping afterwards: it is boot-time
# state shared with the art caches, so leaking it would recolor whatever test
# runs next in the same shard binary.

proc install(payload: string): bool =
  resetTeamDisplayColorsForTests()
  setTeamDisplayColors(payload)

proc encodePayload(json: string): string =
  encode(json)

suite "team display colors":

  teardown:
    resetTeamDisplayColorsForTests()

  test "no mapping renders every team its stock color":
    resetTeamDisplayColorsForTests()
    check teamDisplayColor(Red) == RedEndzoneColor
    check teamDisplayColor(Blue) == BlueEndzoneColor
    check teamDisplayColor(Green) == GreenEndzoneColor
    check teamDisplayColor(Yellow) == YellowEndzoneColor
    check not anyTeamDisplayRecolored()
    for team in Team:
      check not teamDisplayIsRecolored(team)
      check teamDisplaySlug(team) == teamText(team)
    # The retro-palette funnel is the IDENTITY of the old lookup, so no
    # palette-indexed sprite moves a pixel.
    for index in 0'u8 .. 15'u8:
      check teamDisplayRgba(index) == Palette[index and 0x0f]
    # The true-color funnel keeps its historical four-way mapping.
    check teamTrueColorRgba(RedTeamColor) == RedEndzoneColor
    check teamTrueColorRgba(BlueTeamColor) == BlueEndzoneColor
    check teamTrueColorRgba(GreenTeamColor) == GreenEndzoneColor
    check teamTrueColorRgba(YellowTeamColor) == YellowEndzoneColor
    check teamTrueColorRgba(5'u8) == Palette[5]

  test "the palette is the file, in the frozen contract order":
    check TeamPaletteVersion == 1
    check TeamPalette.len == 8
    # The first four are the stock wire colors, in wire order, unrepainted.
    check TeamPalette[0].slug == "red" and TeamPalette[0].wire == "red"
    check TeamPalette[1].slug == "blue" and TeamPalette[1].wire == "blue"
    check TeamPalette[2].slug == "green" and TeamPalette[2].wire == "green"
    check TeamPalette[3].slug == "yellow" and TeamPalette[3].wire == "yellow"
    check TeamPalette[0].game == RedEndzoneColor
    check TeamPalette[1].game == BlueEndzoneColor
    check TeamPalette[2].game == GreenEndzoneColor
    check TeamPalette[3].game == YellowEndzoneColor
    # The four added slugs are display-only: no wire word may claim them.
    for i in 4 ..< TeamPalette.len:
      check TeamPalette[i].wire.len == 0
    # The embedded copy IS data/team_palette.json — not a re-typed second one.
    let onDisk = parseJson(readFile(GameDir / "data" / "team_palette.json"))
    check onDisk["colors"].len == TeamPalette.len
    for i, entry in TeamPalette:
      check onDisk["colors"][i]["slug"].getStr == entry.slug
      check onDisk["colors"][i]["game"].getStr == entry.gameHex

  test "a resolved mapping repaints the team everywhere at once":
    check install(encodePayload(
      """{"v":1,"palette":1,"teams":{"blue":{"slug":"teal"}}}"""))
    let teal = TeamPalette[paletteIndexOfSlug("teal")].game
    check teamDisplayColor(Blue) == teal
    check teamDisplaySlug(Blue) == "teal"
    check teamDisplayIsRecolored(Blue)
    check anyTeamDisplayRecolored()
    # Paint FX, endzone glow and every true-color surface read this funnel.
    check teamTrueColorRgba(BlueTeamColor) == teal
    # Palette-indexed surfaces follow the recolored team...
    check teamDisplayRgba(BlueTeamColor) == teal
    # ...and every OTHER slot is still the untouched retro palette.
    check teamDisplayRgba(RedTeamColor) == Palette[RedTeamColor]
    check teamDisplayRgba(5'u8) == Palette[5]
    check teamDisplayColor(Red) == RedEndzoneColor
    check not teamDisplayIsRecolored(Red)
    # THE WIRE NEVER MOVES: the team is still `blue` to every policy.
    check teamText(Blue) == "blue"

  test "the contract's own example payload decodes as documented":
    # Copied verbatim from docs/COLOR_CONTRACT.md §5 — if the doc and the
    # parser ever disagree, this is where it shows. The base64 is asserted to
    # decode to the doc's minified JSON byte for byte before it is installed,
    # so a doc example that was edited without re-encoding fails here rather
    # than quietly documenting a string nobody can use.
    const
      Example =
        "eyJ2IjoxLCJwYWxldHRlIjoxLCJzaGltbWVyIjoicGljYXNzbyIsInRlYW1zIjp7In" &
        "JlZCI6eyJzbHVnIjoib3JhbmdlIn0sImJsdWUiOnsic2x1ZyI6InRlYWwifX19"
      ExampleJson =
        """{"v":1,"palette":1,"shimmer":"picasso",""" &
        """"teams":{"red":{"slug":"orange"},"blue":{"slug":"teal"}}}"""
    check decode(Example) == ExampleJson
    check encodePayload(ExampleJson) == Example
    check install(Example)
    check teamDisplaySlug(Red) == "orange"
    check teamDisplaySlug(Blue) == "teal"
    # Teams the payload does not name keep stock — any subset of the four wire
    # words is legal.
    check teamDisplaySlug(Green) == "green"
    check teamDisplaySlug(Yellow) == "yellow"
    check not teamDisplayIsRecolored(Green)
    check teamDisplayColor(Green) == GreenEndzoneColor
    # shimmer is a separate, ROOT-level feature: parsed and exposed, never a
    # color, and one string for the whole lobby rather than one per team.
    check payloadShimmerPolicy() == "picasso"

  test "a stale per-team shimmer key is ignored, not honored":
    # `shimmer` used to live inside each `teams` entry. An old platform build
    # still sending that shape must mark NOBODY: reading it would flag one
    # policy per team — up to four at once — when the whole point is that at
    # most ONE policy in the lobby (the #1) ever wears the sheen.
    check install(encodePayload(
      """{"v":1,"teams":{"red":{"slug":"orange","shimmer":"picasso"},""" &
      """"blue":{"slug":"teal","shimmer":"focusfire"}}}"""))
    check payloadShimmerPolicy() == ""
    # The COLOR half of a stale payload is still honored — only the moved key
    # is dropped, so an old link keeps working, just without a false mark.
    check teamDisplaySlug(Red) == "orange"
    check teamDisplaySlug(Blue) == "teal"

  test "a shimmer-only payload needs no teams at all":
    # The two channels are read independently (§5): no team is recolored here,
    # so `setTeamDisplayColors` reports false, and the shimmer still lands.
    check not install("""{"v":1,"shimmer":"picasso"}""")
    check payloadShimmerPolicy() == "picasso"
    for team in Team:
      check not teamDisplayIsRecolored(team)
    # And an unknown payload VERSION still drops everything, shimmer included.
    check not install("""{"v":99,"shimmer":"picasso"}""")
    check payloadShimmerPolicy() == ""

  test "every malformed or skewed payload falls back to stock, silently":
    for payload in [
      "",                                   # no param at all
      "   ",
      "not base64 at all !!!",
      encodePayload("{ this is not json"),
      encodePayload("[1,2,3]"),             # JSON, wrong shape
      encodePayload("""{"teams":{"red":{"slug":"teal"}}}"""),   # no version
      encodePayload("""{"v":99,"teams":{"red":{"slug":"teal"}}}"""),  # skew
      encodePayload("""{"v":1}"""),                             # no teams
      encodePayload("""{"v":1,"teams":{"red":{"slug":"chartreuse"}}}"""),
      encodePayload("""{"v":1,"teams":{"vermillion":{"slug":"teal"}}}"""),
      encodePayload("""{"v":1,"teams":{"red":{}}}"""),
      encodePayload("""{"v":1,"teams":{"red":"teal"}}"""),      # wrong type
    ]:
      check not install(payload)
      for team in Team:
        check teamDisplayColor(team) == stockTeamDisplayColor(team)
        check not teamDisplayIsRecolored(team)

  test "a missing team key leaves that team stock":
    check install(encodePayload(
      """{"v":1,"teams":{"red":{"slug":"purple"}}}"""))
    check teamDisplayIsRecolored(Red)
    for team in [Blue, Green, Yellow]:
      check teamDisplayColor(team) == stockTeamDisplayColor(team)
      check not teamDisplayIsRecolored(team)

  test "raw JSON is accepted for the env-var and hand-run paths":
    check install("""{"v":1,"teams":{"yellow":{"slug":"purple"}}}""")
    check teamDisplaySlug(Yellow) == "purple"

  test "the mapping is boot-time only: a second install is refused":
    check install(encodePayload("""{"v":1,"teams":{"red":{"slug":"teal"}}}"""))
    check teamDisplaySlug(Red) == "teal"
    # Paint stains are append-only with a send cursor, so there is no live
    # recolor to be had — a later payload must not half-apply.
    discard setTeamDisplayColors(
      encodePayload("""{"v":1,"teams":{"red":{"slug":"purple"}}}"""))
    check teamDisplaySlug(Red) == "teal"

suite "team display art":

  teardown:
    resetTeamDisplayColorsForTests()

  test "a stock team reads its own shipped master, untouched":
    resetTeamDisplayColorsForTests()
    for team in Team:
      let spec = teamArtTint(team)
      check spec.sourceTeam == team
      check not spec.retint

  test "a team displayed as another wire color borrows that art":
    check install(encodePayload("""{"v":1,"teams":{"red":{"slug":"green"}}}"""))
    let spec = teamArtTint(Red)
    # The hand-made green cog, not a computed one.
    check spec.sourceTeam == Green
    check not spec.retint

  test "an added slug re-tints, from the team's own cog and the RED prop":
    check install(encodePayload("""{"v":1,"teams":{"blue":{"slug":"purple"}}}"""))
    let purple = TeamPalette[paletteIndexOfSlug("purple")].game
    let cog = teamArtTint(Blue)
    check cog.sourceTeam == Blue          # blue's team hue IS the palette hue
    check cog.retint
    check cog.fromColor == BlueEndzoneColor
    check cog.toColor == purple
    # heart_blue / ped_blue are separate hand-painted pieces whose team ink is
    # not at the palette blue hue, so props key off the red master instead.
    let prop = teamArtTint(Blue, propArt = true)
    check prop.sourceTeam == Red
    check prop.retint
    check prop.fromColor == RedEndzoneColor
    check prop.toColor == purple

  test "re-tinting moves the team pixels and spares the visor":
    # Real art, real numbers: the cog master's team pixels cluster at the stock
    # team hue while the cyan visor is a hard cluster at hue 180 in EVERY
    # master. A muddied visor is the classic failure, so measure it.
    let
      master = readImage(GameDir / "data" / "soldier_red.png")
      target = TeamPalette[paletteIndexOfSlug("teal")].game
    var
      visorBefore, visorAfter: int
      teamBefore, teamAfter: int
    proc isVisor(c: ColorRGBA): bool =
      ## Cyan: green and blue both well above red.
      c.a > 16'u8 and c.g.int > c.r.int + 40 and c.b.int > c.r.int + 40
    proc isWarm(c: ColorRGBA): bool =
      c.a > 16'u8 and c.r.int > c.g.int + 40 and c.r.int > c.b.int + 40
    for pixel in master.data:
      let c = pixel.rgba()
      if isVisor(c): inc visorBefore
      if isWarm(c): inc teamBefore
    check visorBefore > 100
    check teamBefore > 1000
    master.retintTeamImage(RedEndzoneColor, target,
      CogHueBand, CogHueSoft, CogSatLo, CogSatHi)
    for pixel in master.data:
      let c = pixel.rgba()
      if isVisor(c): inc visorAfter
      if isWarm(c): inc teamAfter
    # The visor survives intact; the red shell is gone.
    check visorAfter >= visorBefore
    check teamAfter * 20 < teamBefore

  test "re-tinting to the source color is a byte-for-byte no-op":
    let
      a = readImage(GameDir / "data" / "soldier_blue.png")
      b = readImage(GameDir / "data" / "soldier_blue.png")
    b.retintTeamImage(BlueEndzoneColor, BlueEndzoneColor,
      CogHueBand, CogHueSoft, CogSatLo, CogSatHi)
    check a.data == b.data

  test "the generated JS palette block carries every slug and hex":
    let js = teamPaletteJs()
    check js.startsWith("window.CTF_PALETTE={")
    check js.endsWith("};")
    for entry in TeamPalette:
      check js.contains("\"" & entry.slug & "\"")
      check js.contains("\"" & entry.gameHex & "\"")
