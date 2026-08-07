import
  helpers,
  std/[base64, json, os, strutils, unittest],
  bitworld/spriteprotocol,
  pixie,
  ctf/[shimmer, sim_types, team_colors]

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

# ---------------------------------------------------------------------------
# DELIVERY-PATH ROUTING (docs/COLOR_CONTRACT.md §5.1)
#
# The funnel itself is covered above. What this suite pins is the WIRING that
# carries a `?colors=` value INTO the funnel on each of the two shipping paths
# — and every failure mode here is SILENT. A viewer that never calls the funnel
# renders a perfectly good stock board; nothing logs, nothing throws, no test
# above goes red. The bugs this catches were all found by hand:
#
#  - the wasm call drifting away from `ctf_load_replay` (it must sit AFTER
#    emscripten's callMain, which runs Nim's module initializers and resets the
#    mapping to stock, and BEFORE the load, which bakes the first frame);
#  - the league shell dropping `?colors=` when it composes the board iframe src;
#  - the native entrypoint losing its env read, or calling it after the server
#    loop has already baked;
#  - the Dockerfile not shipping `static_replay.js` (the whole wasm hand-off) or
#    green/yellow front art into `dist/`, which 404s only in the static bundle
#    and only on 4-team boards (CODEBASE_AUDIT.md flagged exactly this).
#
# These are source-text assertions on purpose: the delivery seams are JS, HTML
# and a Dockerfile, none of which the Nim suite can execute, and a grep-shaped
# pin is worth far more than no pin at all on a path that fails quietly.

const
  StaticReplayJs = staticRead("../replay-viewer/static_replay.js")
  ReplayViewerNim = staticRead("../replay-viewer/ctf_replay.nim")
  LeagueReplayerHtml = staticRead("../client/league_replayer.html")
  ServerEntrypointNim = staticRead("../src/ctf.nim")
  ViewerDockerfile = staticRead("../Dockerfile.replay-viewer")

proc orderedIn(haystack: string, needles: varargs[string]): bool =
  ## True when every needle appears, each strictly after the previous one.
  var cursor = 0
  for needle in needles:
    let at = haystack.find(needle, cursor)
    if at < 0:
      return false
    cursor = at + needle.len
  true

suite "team color delivery paths":

  test "the wasm bundle reads ?colors= and hands it to the engine":
    check StaticReplayJs.contains("params.get('colors')")
    check ReplayViewerNim.contains("exportc: \"ctf_set_team_colors\"")
    check StaticReplayJs.contains("Module._ctf_set_team_colors")

  test "the wasm color call sits between callMain and the first bake":
    # AFTER `await fetch` (so past emscripten's callMain, which re-runs Nim's
    # module initializers and would reset the mapping) and BEFORE
    # `_ctf_load_replay` (which bakes every team-colored sprite, once).
    check StaticReplayJs.orderedIn(
      "await fetch", "Module._ctf_set_team_colors", "Module._ctf_load_replay")

  test "the league shell forwards ?colors= onto the board iframe":
    # The mapping must ride the SRC, not a postMessage: a message can only land
    # after the board has loaded and started baking.
    check LeagueReplayerHtml.contains("params.get('colors')")
    check LeagueReplayerHtml.contains("'&colors=' + encodeURIComponent(colorsParam)")
    check LeagueReplayerHtml.orderedIn(
      "colorsParam", "'&colors=' + encodeURIComponent(colorsParam)",
      "$('game').src = src")

  test "the native server reads CTF_TEAM_COLORS before it serves":
    check ServerEntrypointNim.contains("\"CTF_TEAM_COLORS\"")
    check ServerEntrypointNim.orderedIn(
      "setTeamDisplayColors(getEnv(TeamColorsEnv))",
      "installPayloadShimmer()",
      "runServerLoop(")

  test "both paths install the shimmer channel next to the colors":
    # A payload may carry `shimmer` with no `teams` at all (§5), so every caller
    # of setTeamDisplayColors must also call installPayloadShimmer — otherwise a
    # shimmer-only payload silently does nothing.
    check ServerEntrypointNim.orderedIn(
      "setTeamDisplayColors(", "installPayloadShimmer()")
    check ReplayViewerNim.orderedIn(
      "setTeamDisplayColors(", "installPayloadShimmer()")

  test "the static bundle ships the hand-off and all four teams' front art":
    # static_replay.js IS the wasm hand-off; without it the bundle renders a
    # stock board. The green/yellow front masters 404 only in the static bundle
    # and only on 4-team boards, so nothing but this list catches their loss.
    check ViewerDockerfile.contains("static_replay.js")
    for team in ["red", "blue", "green", "yellow"]:
      check ViewerDockerfile.contains("soldier_" & team & "_front.png")
      check ViewerDockerfile.contains("soldier_" & team & "_front_gun.png")

  test "no viewer asset path is rooted at the origin":
    # The viewer is served at THREE path depths and prod's static bundle 404s on
    # a leading slash — silently, because cogArtReady() just falls back to the
    # procedural chassis. Two legal shapes only: a `./`-relative path, or a
    # `/client/...` route concatenated onto a pathname-derived ROUTE_BASE.
    for src in [LeagueReplayerHtml, StaticReplayJs]:
      check not src.contains("src=\"/")
      check not src.contains("href=\"/")
      # Every `/client/` string literal must be joined onto ROUTE_BASE.
      var cursor = 0
      while true:
        let at = src.find("'/client/", cursor)
        if at < 0:
          break
        check src[max(0, at - 24) ..< at].contains("ROUTE_BASE")
        cursor = at + 9
    # The wasm runtime resolves its own siblings (.wasm/.data) relatively too.
    check StaticReplayJs.contains("Module.locateFile")
    check StaticReplayJs.contains("return './' + path")

suite "four-team payloads":
  ## §5's worked example remaps two teams. A 4-team board remaps all four, and
  ## that is the shape the platform actually sends for ffa4 — the case where a
  ## half-applied mapping would corrupt the paint-stain score read.

  teardown:
    resetTeamDisplayColorsForTests()
    setShimmerPolicy("")

  test "all four teams remap at once, with the shimmer riding along":
    const payload = """{"v":1,"palette":1,"shimmer":"picasso","teams":{
      "red":{"slug":"orange"},"blue":{"slug":"teal"},
      "green":{"slug":"purple"},"yellow":{"slug":"magenta"}}}"""
    check install(encodePayload(payload))
    installPayloadShimmer()
    check teamDisplayColor(Red) == rgba(0xe0, 0x8a, 0x2e, 255)
    check teamDisplayColor(Blue) == rgba(0x35, 0xa8, 0xa8, 255)
    check teamDisplayColor(Green) == rgba(0x84, 0x52, 0xcf, 255)
    check teamDisplayColor(Yellow) == rgba(0xd1, 0x5a, 0x9e, 255)
    # Every displayed color is distinct: the platform's §5 guarantee, and the
    # property the paint-stain scoreboard depends on.
    let shown = [teamDisplayColor(Red), teamDisplayColor(Blue),
                 teamDisplayColor(Green), teamDisplayColor(Yellow)]
    for i in 0 ..< shown.len:
      for j in i + 1 ..< shown.len:
        check shown[i] != shown[j]
    check shimmerPolicy() == "picasso"

  test "the wire words survive a full four-team remap":
    # 15 label families parse these; a rename blinds every league policy.
    const payload = """{"v":1,"teams":{"red":{"slug":"orange"},"blue":{"slug":"teal"},
      "green":{"slug":"purple"},"yellow":{"slug":"magenta"}}}"""
    check install(encodePayload(payload))
    check teamText(Red) == "red"
    check teamText(Blue) == "blue"
    check teamText(Green) == "green"
    check teamText(Yellow) == "yellow"

suite "the embed cookbook is executable":
  ## §8 hands the webpage window four base64 strings to copy. If one of them
  ## ever stopped parsing, the other team would integrate against a dead
  ## example and see a stock board with nothing logged. Decode each one here so
  ## the doc and the parser cannot drift apart.

  teardown:
    resetTeamDisplayColorsForTests()
    setShimmerPolicy("")

  test "8.2(b) two teams recolored":
    const B = "eyJ2IjoxLCJwYWxldHRlIjoxLCJ0ZWFtcyI6eyJyZWQiOnsic2x1ZyI6Im9y" &
              "YW5nZSJ9LCJibHVlIjp7InNsdWciOiJ0ZWFsIn19fQ=="
    check install(B)
    check teamDisplaySlug(Red) == "orange"
    check teamDisplaySlug(Blue) == "teal"
    check teamDisplaySlug(Green) == "green"
    check payloadShimmerPolicy() == ""

  test "8.2(c) all four teams recolored, with the league #1 marked":
    const C = "eyJ2IjoxLCJwYWxldHRlIjoxLCJzaGltbWVyIjoicGljYXNzbyIsInRlYW1z" &
              "Ijp7InJlZCI6eyJzbHVnIjoib3JhbmdlIn0sImJsdWUiOnsic2x1ZyI6InRl" &
              "YWwifSwiZ3JlZW4iOnsic2x1ZyI6InB1cnBsZSJ9LCJ5ZWxsb3ciOnsic2x1" &
              "ZyI6Im1hZ2VudGEifX19"
    check install(C)
    installPayloadShimmer()
    check teamDisplaySlug(Red) == "orange"
    check teamDisplaySlug(Blue) == "teal"
    check teamDisplaySlug(Green) == "purple"
    check teamDisplaySlug(Yellow) == "magenta"
    check shimmerPolicy() == "picasso"

  test "8.2(d) shimmer only, no teams":
    const D = "eyJ2IjoxLCJzaGltbWVyIjoicGljYXNzbyJ9"
    check not install(D)          # nothing was re-COLORED...
    installPayloadShimmer()
    check shimmerPolicy() == "picasso"   # ...but the mark still lands.
    for team in Team:
      check not teamDisplayIsRecolored(team)
