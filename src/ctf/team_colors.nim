## The display-color funnel: ONE place that decides what color a team is
## PAINTED, for every surface the viewer shows.
##
## Read `docs/COLOR_CONTRACT.md` first. The short version:
##
##  - The engine's label WIRE words (`red|blue|green|yellow`) never change.
##    `teamText`, the identity labels, the roster JSON keys and
##    `tests/label_manifest.txt` are untouched by anything in this module — a
##    renamed wire token silently blinds every league policy. This module maps
##    *wire team word -> display slug -> RGB* and nothing else.
##  - The palette is `data/team_palette.json`, staticRead below. It is the ONLY
##    place the hexes live; do not re-type them anywhere.
##  - BOOT TIME ONLY. Paint stains are append-only one-shot sprites with a
##    `stainsSent` cursor that forbids re-sending, and every team-colored
##    sprite is baked once and cached, so the mapping must be installed before
##    the first sprite is baked. `setTeamDisplayColors` refuses a second call.
##  - With NO mapping installed, every proc here is the exact identity of what
##    the engine did before, so a stock replay renders pixel-identical.
##
## Two lookups come out of it, and the difference matters:
##
##  - `teamDisplayRgba(color)` — a RETRO PALETTE lookup with the team remap
##    layered on. Returns `Palette[color]` verbatim while nothing is recolored.
##    Use it where the engine has always drawn from the 16-entry palette (text
##    sprites, the name-flag chip) and stock pixels must not move.
##  - `teamTrueColorRgba(color)` / `teamDisplayColor(team)` — the TRUE team
##    display color (vivid cerulean, not the palette's muted lavender). Use it
##    for team-colored true-color art: paint FX, endzone glow, badges, auras.

import
  std/[base64, json, math, strutils],
  bitworld/spriteprotocol,
  pixie,
  sim_types

const TeamPaletteJson = staticRead("../../data/team_palette.json")
  ## The canonical palette, embedded from the single source of truth so the
  ## engine, the generated JS block and `scripts/validate_palette.py` can never
  ## disagree. Parsed at COMPILE time: a malformed palette fails the build.

type
  PaletteEntry* = object
    slug*: string        ## the shared display identifier ("teal", "purple"...)
    wire*: string        ## the wire team word this slug is the stock color of,
                         ## or "" for the four added display-only colors.
    display*: string     ## human name for UI ("Lagoon").
    game*: ColorRGBA     ## the vibrant in-game hex.
    gameHex*: string     ## the same color as "#rrggbb", for the JS block.

proc parseHexColor(hex: string): ColorRGBA =
  ## "#rrggbb" -> opaque RGBA. Compile-time safe (no pixie parsing).
  doAssert hex.len == 7 and hex[0] == '#', "palette hex must be #rrggbb: " & hex
  rgba(
    uint8(parseHexInt(hex[1 .. 2])),
    uint8(parseHexInt(hex[3 .. 4])),
    uint8(parseHexInt(hex[5 .. 6])),
    255
  )

const
  TeamPalette*: seq[PaletteEntry] = block:
    var entries: seq[PaletteEntry]
    let node = parseJson(TeamPaletteJson)
    for item in node["colors"]:
      let hex = item["game"].getStr
      entries.add PaletteEntry(
        slug: item["slug"].getStr,
        wire:
          if item["wire"].kind == JNull: ""
          else: item["wire"].getStr,
        display: item["display"].getStr,
        game: parseHexColor(hex),
        gameHex: hex
      )
    entries
  TeamPaletteVersion* = parseJson(TeamPaletteJson)["version"].getInt

  ColorPayloadVersion* = 1
    ## The `?colors=` payload schema version this build understands (§5).

static:
  # The contract freezes the first four entries as the stock wire colors, in
  # wire order, with the exact stock hexes. Everything below leans on that, so
  # prove it at build time rather than trusting a comment.
  doAssert TeamPalette.len >= 4
  doAssert TeamPalette[0].wire == "red" and TeamPalette[0].game == RedEndzoneColor
  doAssert TeamPalette[1].wire == "blue" and TeamPalette[1].game == BlueEndzoneColor
  doAssert TeamPalette[2].wire == "green" and TeamPalette[2].game == GreenEndzoneColor
  doAssert TeamPalette[3].wire == "yellow" and TeamPalette[3].game == YellowEndzoneColor

proc stockTeamDisplayColor*(team: Team): ColorRGBA =
  ## The team's TRUE stock display color — what the board has always shown.
  case team
  of Red: RedEndzoneColor
  of Blue: BlueEndzoneColor
  of Green: GreenEndzoneColor
  of Yellow: YellowEndzoneColor

proc paletteIndexOfSlug*(slug: string): int =
  ## Index of a slug in the palette, or -1. Unknown slug = version skew; every
  ## caller must treat -1 as "keep stock", never as an error.
  for i, entry in TeamPalette:
    if entry.slug == slug:
      return i
  -1

proc teamForWire*(wire: string): int =
  ## Team ordinal for a wire team word, or -1. Uses `teamText` so this can
  ## never drift from the label wire.
  for team in Team:
    if teamText(team) == wire:
      return int(team)
  -1

var
  displaySlug: array[Team, string]
  displayColor: array[Team, ColorRGBA]
  displayShimmer: array[Team, string]
  displayRecolored: array[Team, bool]
  anyRecolor = false
  mappingInstalled = false

proc initTeamDisplayDefaults() =
  for team in Team:
    displaySlug[team] = teamText(team)
    displayColor[team] = stockTeamDisplayColor(team)
    displayShimmer[team] = ""
    displayRecolored[team] = false

initTeamDisplayDefaults()

proc teamDisplayColor*(team: Team): ColorRGBA =
  ## THE funnel. Every team-colored surface resolves its color through here.
  displayColor[team]

proc teamDisplaySlug*(team: Team): string =
  ## The palette slug this team is displayed as ("red" .. "orange").
  displaySlug[team]

proc teamDisplayIsRecolored*(team: Team): bool =
  ## True when this team is painted as something other than its stock color.
  displayRecolored[team]

proc anyTeamDisplayRecolored*(): bool =
  ## Fast "is this a stock render?" check. False => every lookup here is the
  ## exact pre-existing behaviour.
  anyRecolor

proc teamShimmerPolicy*(team: Team): string =
  ## The policy identity (seat-suffix already stripped by the platform, §5)
  ## whose agents wear the metallic shimmer on this team, or "" for none.
  ## Parsed and preserved here; the shimmer RENDER is a separate task.
  displayShimmer[team]

proc teamColorsInstalled*(): bool =
  ## True once a `?colors=` payload has been accepted (or rejected) for this
  ## process. Boot-time only: a second install is refused.
  mappingInstalled

proc teamOfPaletteColor(color: uint8): int =
  ## Team ordinal for one of the four retro TEAM palette slots, else -1.
  case color and 0x0f
  of RedTeamColor: int(Red)
  of BlueTeamColor: int(Blue)
  of GreenTeamColor: int(Green)
  of YellowTeamColor: int(Yellow)
  else: -1

proc teamDisplayRgba*(color: uint8): ColorRGBA =
  ## Retro-palette lookup WITH the team remap layered on. Identical to
  ## `Palette[color and 0x0f]` whenever nothing is recolored, so stock renders
  ## do not move a single pixel; a recolored team's palette-indexed surfaces
  ## follow it to the display color instead of stranding on the old hue.
  if anyRecolor:
    let team = teamOfPaletteColor(color)
    if team >= 0 and displayRecolored[Team(team)]:
      return displayColor[Team(team)]
  Palette[color and 0x0f]

proc teamTrueColorRgba*(color: uint8): ColorRGBA =
  ## Maps a sprite's palette TEAM color to the true team display color — the
  ## vivid hues the cog art and endzone floors actually show — rather than the
  ## retro palette slot (`Palette[BlueTeamColor]` is a muted lavender the board
  ## shows nowhere else). A non-team color (an individual player slot) falls
  ## back to its palette entry, remapped if that slot is a recolored team.
  let team = teamOfPaletteColor(color)
  if team >= 0:
    displayColor[Team(team)]
  else:
    teamDisplayRgba(color)

# --- payload parsing (§5) ----------------------------------------------------
# Every failure mode here lands on "keep stock": no param, malformed base64,
# malformed JSON, unknown payload version, missing team key, unknown slug. The
# viewer must never error or blank over this param.

proc decodeColorPayload(raw: string): string =
  ## Returns the payload JSON text, or "" when it cannot be recovered. Accepts
  ## the wire form (base64 of UTF-8 JSON, per the contract) and, for CLI/env
  ## ergonomics on the native path, raw JSON.
  let trimmed = raw.strip()
  if trimmed.len == 0:
    return ""
  if trimmed.startsWith("{"):
    return trimmed
  try:
    # URL-safe base64 is tolerated: the platform is told to URL-ENCODE the
    # standard alphabet, but a hand-built link that swapped +/ for -_ should
    # still decode rather than silently render stock.
    var text = trimmed.replace('-', '+').replace('_', '/')
    while text.len mod 4 != 0:
      text.add '='
    result = decode(text)
    if not result.strip().startsWith("{"):
      return ""
  except CatchableError:
    return ""

proc setTeamDisplayColors*(raw: string): bool {.discardable.} =
  ## Installs the platform's resolved team -> slug mapping. `raw` is the
  ## `?colors=` param value verbatim (base64 JSON, or raw JSON).
  ##
  ## BOOT TIME ONLY — call before the first sprite is baked. Returns true when
  ## at least one team was actually recolored. Never raises: any malformed or
  ## skewed payload leaves every team on its stock color.
  if mappingInstalled:
    return anyRecolor
  mappingInstalled = true
  let text = decodeColorPayload(raw)
  if text.len == 0:
    return false
  var payload: JsonNode
  try:
    payload = parseJson(text)
  except CatchableError:
    return false
  if payload.kind != JObject:
    return false
  # Unknown payload version => ignore the WHOLE payload and render stock (§5).
  if not payload.hasKey("v") or payload["v"].kind != JInt or
      payload["v"].getInt != ColorPayloadVersion:
    return false
  if not payload.hasKey("teams") or payload["teams"].kind != JObject:
    return false
  for wire, value in payload["teams"].pairs:
    let teamOrd = teamForWire(wire)
    if teamOrd < 0 or value.kind != JObject:
      continue                       # unknown wire word => nothing to recolor.
    let team = Team(teamOrd)
    if value.hasKey("shimmer") and value["shimmer"].kind == JString:
      displayShimmer[team] = value["shimmer"].getStr
    if not value.hasKey("slug") or value["slug"].kind != JString:
      continue                       # shimmer without a slug is legal.
    let
      slug = value["slug"].getStr
      index = paletteIndexOfSlug(slug)
    if index < 0:
      continue                       # version skew => this team keeps stock.
    displaySlug[team] = slug
    displayColor[team] = TeamPalette[index].game
    if slug != teamText(team):
      displayRecolored[team] = true
      anyRecolor = true
  anyRecolor

proc resetTeamDisplayColorsForTests*() =
  ## Test-only: drop the installed mapping so one process can exercise several
  ## payloads. Never call this from the engine — see the boot-time rule.
  initTeamDisplayDefaults()
  anyRecolor = false
  mappingInstalled = false

# --- pre-tinted ART re-tint --------------------------------------------------
# The cog masters, hearts, pedestals and rig segments are PNGs tinted offline
# (scripts/art/build_cvc_masters.py pushes team color through a selective mask
# at 0.75 strength; scripts/art/retint_team_props.py hue-rotates the red heart
# and pedestal). Baking eight slugs of every asset would multiply the shipped
# art and the wasm bundle for a display-only feature, so a recolored team is
# re-tinted at ASSET LOAD instead — once, into the same caches the stock art
# uses, before any sprite is baked.
#
# The key is the art's own hue: measuring the shipped masters, the team-carrying
# pixels sit in a tight cluster at the stock team hue (~45% of the cog's opaque
# pixels) while the cyan visor is a hard cluster at hue 180 in EVERY master and
# the ink/wheels/shadow are near-neutral. So a hue-distance gate against the
# stock team color selects exactly the offline mask's pixels, and nothing else.
# Selected pixels rotate to the target hue and scale their saturation/value
# toward the target's — the same move retint_team_props.py makes, so a recolored
# cog keeps its painted shading instead of turning into a flat decal.

const
  CogHueBand* = 20.0      ## degrees of full-strength hue capture around the
                          ## stock team hue. The visor (180) is >=28 away from
                          ## every stock team hue, so it never moves.
  CogHueSoft* = 10.0      ## fade-out width past the band (no hard edge).
  CogSatLo* = 0.10        ## below this saturation a pixel is ink/shadow.
  CogSatHi* = 0.22        ## at/above this it is fully team-colored.
  PropHueBand* = 45.0     ## hearts/pedestals are hand-painted with a much
  PropHueSoft* = 12.0     ## wider warm band; these reproduce the offline
  PropSatLo* = 0.20       ## retint_team_props.py gates (band 45, sat > 0.25).
  PropSatHi* = 0.30

type ArtTintSpec* = object
  ## How to obtain one team's art for the color it is DISPLAYED as.
  sourceTeam*: Team    ## whose shipped PNG to read.
  retint*: bool        ## re-tint it after loading?
  fromColor*: ColorRGBA
  toColor*: ColorRGBA

proc rgbToHsv(c: ColorRGBA): tuple[h, s, v: float] =
  let
    r = float(c.r) / 255.0
    g = float(c.g) / 255.0
    b = float(c.b) / 255.0
    mx = max(r, max(g, b))
    mn = min(r, min(g, b))
    d = mx - mn
  result.v = mx
  result.s = if mx > 0.0: d / mx else: 0.0
  if d <= 1e-6:
    result.h = 0.0
  elif mx == r:
    result.h = floorMod(60.0 * ((g - b) / d), 360.0)
  elif mx == g:
    result.h = 60.0 * ((b - r) / d) + 120.0
  else:
    result.h = 60.0 * ((r - g) / d) + 240.0

proc hsvToRgb(h, s, v: float): tuple[r, g, b: float] =
  let
    h6 = floorMod(h / 60.0, 6.0)
    i = int(floor(h6))
    f = h6 - floor(h6)
    p = v * (1.0 - s)
    q = v * (1.0 - s * f)
    t = v * (1.0 - s * (1.0 - f))
  case i
  of 0: (v, t, p)
  of 1: (q, v, p)
  of 2: (p, v, t)
  of 3: (p, q, v)
  of 4: (t, p, v)
  else: (v, p, q)

proc retintTeamImage*(
  image: Image,
  fromColor, toColor: ColorRGBA,
  hueBand, hueSoft, satLo, satHi: float
) =
  ## Re-tints one already-team-tinted master IN PLACE, moving the pixels that
  ## carry `fromColor`'s hue onto `toColor` and leaving the visor, ink, wheels
  ## and drop shadow exactly where the artist put them. A no-op when the two
  ## colors are equal, so calling it on a stock team cannot perturb the art.
  if fromColor == toColor:
    return
  let
    src = rgbToHsv(fromColor)
    dst = rgbToHsv(toColor)
    # Shortest-way-around hue rotation, so red (9) -> magenta (326) turns 43
    # degrees back through red rather than 317 degrees forward through green.
    hueDelta = floorMod(dst.h - src.h + 180.0, 360.0) - 180.0
    satScale = if src.s > 1e-3: dst.s / src.s else: 1.0
    valScale = if src.v > 1e-3: dst.v / src.v else: 1.0
  for i in 0 ..< image.data.len:
    let straight = image.data[i].rgba()
    if straight.a == 0:
      continue
    let hsv = rgbToHsv(straight)
    # Angular distance from the master's team hue, 0..180.
    let dist = abs(floorMod(hsv.h - src.h + 180.0, 360.0) - 180.0)
    if dist >= hueBand + hueSoft or hsv.s <= satLo:
      continue
    let
      hueGate = clamp((hueBand + hueSoft - dist) / hueSoft, 0.0, 1.0)
      satGate = clamp((hsv.s - satLo) / max(satHi - satLo, 1e-6), 0.0, 1.0)
      w = hueGate * satGate
    if w <= 0.0:
      continue
    let
      h2 = floorMod(hsv.h + w * hueDelta, 360.0)
      s2 = clamp(hsv.s * (1.0 + w * (satScale - 1.0)), 0.0, 1.0)
      v2 = clamp(hsv.v * (1.0 + w * (valScale - 1.0)), 0.0, 1.0)
      (r, g, b) = hsvToRgb(h2, s2, v2)
    image.data[i] = rgba(
      uint8(clamp(r * 255.0, 0.0, 255.0)),
      uint8(clamp(g * 255.0, 0.0, 255.0)),
      uint8(clamp(b * 255.0, 0.0, 255.0)),
      straight.a
    ).rgbx()

proc teamArtTint*(team: Team, propArt = false): ArtTintSpec =
  ## Which shipped master to load for `team`, and whether to re-tint it.
  ##
  ##  - stock team          -> its own file, untouched (pixel-identical).
  ##  - displayed as another WIRE color -> that team's own hand-made file. A red
  ##    team shown as `blue` gets the real blue cog, not a computed one.
  ##  - displayed as an added slug -> re-tint. Cog art re-tints from the team's
  ##    OWN master (its team hue is the palette hue, a clean key). PROP art
  ##    (heart/pedestal) re-tints from the RED master instead: `heart_blue` and
  ##    `ped_blue` are separate hand-painted pieces whose team ink sits at ~178
  ##    and whose stone is warm, so blue is not a usable key — red is the master
  ##    the shipped green/yellow props were themselves derived from.
  result = ArtTintSpec(sourceTeam: team, retint: false)
  if not displayRecolored[team]:
    return
  let index = paletteIndexOfSlug(displaySlug[team])
  if index < 0:
    return
  let entry = TeamPalette[index]
  if entry.wire.len > 0:
    let wireTeam = teamForWire(entry.wire)
    if wireTeam >= 0:
      result.sourceTeam = Team(wireTeam)
      return
  result.sourceTeam = if propArt: Red else: team
  result.retint = true
  result.fromColor = stockTeamDisplayColor(result.sourceTeam)
  result.toColor = entry.game

proc applyTeamArtTint*(image: Image, spec: ArtTintSpec, propArt = false) =
  ## Applies `teamArtTint`'s decision to a freshly loaded master.
  if not spec.retint:
    return
  if propArt:
    image.retintTeamImage(spec.fromColor, spec.toColor,
      PropHueBand, PropHueSoft, PropSatLo, PropSatHi)
  else:
    image.retintTeamImage(spec.fromColor, spec.toColor,
      CogHueBand, CogHueSoft, CogSatLo, CogSatHi)

# --- the JS side of the same palette -----------------------------------------

proc teamPaletteJs*(): string =
  ## `window.CTF_PALETTE` for the browser chrome, rendered from the SAME
  ## embedded palette the engine paints with. The chrome needs slug -> hex to
  ## recolor its CSS vars, and re-typing the hex list in JavaScript is exactly
  ## the drift the contract forbids — so it is generated, like CTF_WIRE.
  result = "window.CTF_PALETTE={v:" & $TeamPaletteVersion & ",payloadV:" &
    $ColorPayloadVersion & ",colors:["
  for i, entry in TeamPalette:
    if i > 0:
      result.add ","
    result.add "{slug:\"" & entry.slug & "\",wire:" &
      (if entry.wire.len == 0: "null" else: "\"" & entry.wire & "\"") &
      ",display:\"" & entry.display & "\",game:\"" & entry.gameHex & "\"}"
  result.add "]};"
