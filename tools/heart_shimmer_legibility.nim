## Objective legibility harness for the HEART clearcoat: does the flagged team's
## planted gem measurably out-read its own unshimmered self at the zoom a
## spectator actually watches at — WITHOUT bleaching the team color off it?
##
## `tools/shimmer_legibility.nim` is the same instrument pointed at the cog. This
## one exists because the heart is a materially harder host and fails in the
## opposite direction:
##
## - The cog's problem is AREA. At the zoom a spectator watches (a ~1727 map px
##   board fitted into ~800 screen px, 0.46 screen per map px) a cog is ~16
##   screen px and its sheen is capped at ~9 by the head cube, which is why the
##   shipped cog mark was reported as invisible on a real replay. The planted
##   heart is 60 map px — ~28 screen px, static, always on screen at a fixed
##   corner — so area is not the binding constraint.
## - The heart's problem is COLOR. The gem is the single largest, most saturated
##   block of team color on the board and the whole reason the color feature
##   beside this one exists; and its hand-painted facets already run to ~248
##   luma, so there is no headroom to win the peak with white. The first build
##   here spent white freely and measured the exact catastrophe: 0.96 of the gem
##   read as teal before, 0.42 after.
##
## So the number this tool exists to print is `gemKeep` — the heart's version of
## the cog harness's `shellKeep`, and the SAME discipline: a COUNT over the gem's
## own pixels of how many can still be NAMED as the team color, not a mean
## saturation over a box (which is diluted by floor, pedestal and ink, and which
## scored a heart washed to milk-white as a harmless-looking -0.05).
##
##   nim c -d:release -r tools/heart_shimmer_legibility.nim [outDir] [screenPerMap] [palette]
##
## Prints a TSV table on stdout and, if outDir is given, writes a phase contact
## sheet plus off/on gem crops at the measured scale.
import
  std/[algorithm, math, os, strformat, strutils],
  pixie,
  ../src/ctf/[global, shimmer, sim, sim_types, team_colors],
  toolutil

const
  Seats = 8             ## 4 teams x 2 seats.
  Phases = 24           ## one full glide, sampled every ShimmerTicksPerFrame.
  TicksPerPhase = 4     ## must match ShimmerTicksPerFrame.
  HeartW = 60           ## bbox side in MAP px == PlantedFlagW, the planted gem's
                        ## own footprint (global.nim keeps that const private).
  HueTol = 25.0         ## degrees of hue a gem pixel may drift and still be
                        ## nameable as the same team color.
  SatKeep = 0.55        ## fraction of the stock gem's saturation a pixel must
                        ## retain to still count as team-colored.
  GemSat = 0.30         ## saturation floor that separates the GEM from the ink
                        ## outline, the pedestal stone and the floor inside the
                        ## same bbox. The reference set is taken from the
                        ## UNSHIMMERED render, so the denominator is fixed and
                        ## the sheen cannot shrink its own scoring set.
  ViewerScreenPerMap = 0.4656
                        ## the real thing: 1727 map px of 4-team board drawn into
                        ## ~804 screen px. Deliberately the default, because a
                        ## result that only holds at a kinder scale is not a
                        ## result.

type Stat = object
  peak: float           ## max Rec.709 luminance over the gem bbox, 0..255.
  p95: float
  meanLum: float
  gemSat: float         ## mean HSV S over the GEM pixels only.
  gemHue: float         ## saturation-weighted circular mean hue over the same.
  gemKeep: float        ## THE COLOR-IDENTITY CRITERION (see the header).

proc lum(c: ColorRGBX): float =
  0.2126 * float(c.r) + 0.7152 * float(c.g) + 0.0722 * float(c.b)

proc hsvOf(c: ColorRGBX): tuple[h, s, v: float] =
  let
    r = float(c.r) / 255.0
    g = float(c.g) / 255.0
    b = float(c.b) / 255.0
    mx = max(r, max(g, b))
    mn = min(r, min(g, b))
    d = mx - mn
  var h = 0.0
  if d > 1e-6:
    if mx == r: h = 60.0 * ((g - b) / d mod 6.0)
    elif mx == g: h = 60.0 * ((b - r) / d + 2.0)
    else: h = 60.0 * ((r - g) / d + 4.0)
  if h < 0: h += 360.0
  (h, (if mx > 1e-6: d / mx else: 0.0), mx)

proc boxDownsample(src: Image, factor: float): Image =
  ## Area-average downsample — what the browser does when it fits the emitted
  ## board into the embed box. A nearest sample would flatter the effect by
  ## preserving sub-pixel spikes the real viewer averages away, and on this
  ## feature the averaging is the whole story: one screen pixel is ~4.3x4.3
  ## emitted pixels, so a white feature does not merely shrink, it BLEEDS its
  ## paleness across every screen pixel it touches.
  let
    outW = max(1, int(float(src.width) * factor))
    outH = max(1, int(float(src.height) * factor))
    step = 1.0 / factor
  result = newImage(outW, outH)
  for oy in 0 ..< outH:
    let
      y0 = int(float(oy) * step)
      y1 = min(src.height, max(y0 + 1, int(float(oy + 1) * step)))
    for ox in 0 ..< outW:
      let
        x0 = int(float(ox) * step)
        x1 = min(src.width, max(x0 + 1, int(float(ox + 1) * step)))
      var r, g, b, n = 0.0
      for y in y0 ..< y1:
        for x in x0 ..< x1:
          let c = src.data[y * src.width + x]
          r += float(c.r); g += float(c.g); b += float(c.b); n += 1.0
      result.data[oy * outW + ox] = rgbx(
        uint8(clamp(r / n, 0.0, 255.0)),
        uint8(clamp(g / n, 0.0, 255.0)),
        uint8(clamp(b / n, 0.0, 255.0)), 255)

proc gemBox(img: Image, fxMap, fyMap: int, screenPerMap: float):
    tuple[x0, y0, x1, y1: int] =
  ## The planted gem's bbox in SCREEN px. The banner is centered on the flag in
  ## x and bottom-anchored on the pedestal in y (see the board flag loop), so the
  ## box hangs upward from the flag position.
  let
    side = float(HeartW) * screenPerMap
    cx = float(fxMap) * screenPerMap
    cy = float(fyMap) * screenPerMap
  (max(0, int(cx - side / 2.0)),
   max(0, int(cy - side + 2.0 * screenPerMap)),
   min(img.width, int(cx + side / 2.0) + 1),
   min(img.height, int(cy + 2.0 * screenPerMap) + 1))

proc gemMask(img: Image, box: tuple[x0, y0, x1, y1: int]): seq[bool] =
  ## Which pixels of the bbox are GEM, decided on the unshimmered render.
  result = newSeq[bool]()
  for y in box.y0 ..< box.y1:
    for x in box.x0 ..< box.x1:
      result.add hsvOf(img.data[y * img.width + x]).s >= GemSat

proc statOf(img: Image, box: tuple[x0, y0, x1, y1: int], mask: seq[bool],
            refHue = -1.0, refSat = 0.0): Stat =
  var
    lums: seq[float]
    sumLum, n = 0.0
    gs, ghx, ghy, gn, keep = 0.0
    i = 0
  for y in box.y0 ..< box.y1:
    for x in box.x0 ..< box.x1:
      let
        c = img.data[y * img.width + x]
        l = lum(c)
        (h, s, _) = hsvOf(c)
      lums.add l
      sumLum += l
      n += 1.0
      if i < mask.len and mask[i]:
        gn += 1.0
        gs += s
        ghx += s * cos(h * PI / 180.0)
        ghy += s * sin(h * PI / 180.0)
        if refHue >= 0.0:
          var dh = abs(h - refHue)
          if dh > 180.0: dh = 360.0 - dh
          if dh <= HueTol and s >= SatKeep * refSat:
            keep += 1.0
      inc i
  lums.sort()
  result.peak = lums[^1]
  result.p95 = lums[int(float(lums.len - 1) * 0.95)]
  result.meanLum = sumLum / n
  result.gemSat = (if gn > 0: gs / gn else: 0.0)
  result.gemHue = arctan2(ghy, ghx) * 180.0 / PI
  if result.gemHue < 0: result.gemHue += 360.0
  result.gemKeep = (if gn > 0 and refHue >= 0.0: keep / gn else: 0.0)

proc buildSim(): SimServer =
  ## A 4-team board with the flagged policy on RED ONLY, so the other three
  ## gems are in-frame controls: any sheen on them is a gate bug, and their
  ## stock reading is what "a heart that is not marked" looks like in the same
  ## light.
  var config = defaultGameConfig()
  config.teams = 4
  config.mapPath = "gen"
  config.mapGen.layout = "corners"
  config.mapSeed = 42
  config.slots.setLen(Seats)
  result = initSimServer(config)
  for i in 0 ..< Seats:
    discard result.addPlayer(
      (if i == 0: "metalpolicy" else: "stockpolicy") & "_(" & $i & ")")
  result.startGame()

proc main() =
  chdirGameDir()
  let
    outDir = if paramCount() >= 1: paramStr(1) else: ""
    screenPerMap =
      if paramCount() >= 2: parseFloat(paramStr(2)) else: ViewerScreenPerMap
    palette = if paramCount() >= 3: paramStr(3) else: ""
  if palette.len > 0:
    doAssert setTeamDisplayColors(palette), "palette payload rejected: " & palette
  var
    simOn = buildSim()
    simOff = buildSim()
  # Seat 0 is dealt to Red by roster.teamForSlot; assert rather than assume, so
  # a roster change turns into a failure instead of a silently empty control.
  doAssert simOn.players[0].team == Red, "seat 0 is expected to be Red"
  let
    scale = boardRenderScaleFor(simOn.gameMap.width, simOn.gameMap.height)
    factor = screenPerMap / float(scale)
  echo "# screenPerMap=", screenPerMap, " boardScale=", scale,
    " downsample=", factor.formatFloat(ffDecimal, 3),
    " gem=", HeartW, "map px -> ", int(float(HeartW) * screenPerMap),
    "screen px",
    (if palette.len > 0: " palette=" & palette else: "")
  echo "# team 0 (red) is the FLAGGED one; 1..3 are in-frame controls."
  echo "phase\tteam\tslug\tkeepOff\tkeepOn\tdKeep\tfPeak\tcPeak\tdPeak\t" &
    "fP95\tcP95\tdP95\tfMean\tcMean\tdMean\tfGemSat\tcGemSat\tdGemSat\tdHue"

  var
    tiles: seq[Image]
    worstKeep = 1e9
    worstKeepPhase = -1
    worstDP95 = 1e9
    maxSatDrop = 0.0
    maxHueShift = 0.0
    maxLeak = 0.0
    prevMean: array[4, float]
    maxStrobe = 0.0

  for phase in 0 ..< Phases:
    let want = phase * TicksPerPhase
    for s in [addr simOn, addr simOff]:
      while s[].tickCount < want:
        s[].step(newSeq[InputState](s[].players.len),
                 newSeq[InputState](s[].players.len))
      s[].phase = Playing
    setShimmerPolicy("metalpolicy")
    let boardOn = boxDownsample(simOn.renderBoardFrame(scale = scale), factor)
    setShimmerPolicy("")
    let boardOff = boxDownsample(simOff.renderBoardFrame(scale = scale), factor)
    for t in 0 ..< 4:
      let
        team = Team(t)
        flag = simOff.flags[team]
        box = boardOff.gemBox(flag.x, flag.y, screenPerMap)
        mask = boardOff.gemMask(box)
        # The reference is this gem's OWN unshimmered reading, so the criterion
        # is always "can I still name THIS heart's color" and never drifts with
        # the slug the payload happened to pick.
        c = boardOff.statOf(box, mask)
        cRef = boardOff.statOf(box, mask, c.gemHue, c.gemSat)
        f = boardOn.statOf(box, mask, c.gemHue, c.gemSat)
      var dHue = abs(f.gemHue - c.gemHue)
      if dHue > 180.0: dHue = 360.0 - dHue
      echo &"{phase}\t{t}\t{teamDisplaySlug(team)}\t" &
        &"{cRef.gemKeep:.3f}\t{f.gemKeep:.3f}\t{f.gemKeep - cRef.gemKeep:+.3f}\t" &
        &"{f.peak:.1f}\t{c.peak:.1f}\t{f.peak - c.peak:+.1f}\t" &
        &"{f.p95:.1f}\t{c.p95:.1f}\t{f.p95 - c.p95:+.1f}\t" &
        &"{f.meanLum:.1f}\t{c.meanLum:.1f}\t{f.meanLum - c.meanLum:+.1f}\t" &
        &"{f.gemSat:.3f}\t{c.gemSat:.3f}\t{f.gemSat - c.gemSat:+.3f}\t{dHue:.1f}"
      if t == 0:
        if f.gemKeep < worstKeep:
          worstKeep = f.gemKeep; worstKeepPhase = phase
        worstDP95 = min(worstDP95, f.p95 - c.p95)
        maxSatDrop = max(maxSatDrop, c.gemSat - f.gemSat)
        maxHueShift = max(maxHueShift, dHue)
        if phase > 0:
          maxStrobe = max(maxStrobe, abs(f.meanLum - prevMean[t]))
      else:
        # An unflagged gem must be BYTE-identical between the two renders.
        maxLeak = max(maxLeak, abs(f.meanLum - c.meanLum))
      prevMean[t] = f.meanLum
    if outDir.len > 0:
      let
        flag = simOff.flags[Red]
        box = boardOff.gemBox(flag.x, flag.y, screenPerMap)
        w = box.x1 - box.x0
        h = box.y1 - box.y0
      var tile = newImage(w * 6, h * 6)
      for y in 0 ..< h * 6:
        for x in 0 ..< w * 6:
          tile.data[y * tile.width + x] =
            boardOn.data[(box.y0 + y div 6) * boardOn.width + box.x0 + x div 6]
      tiles.add tile
      if phase == 0:
        boardOn.writeFile(outDir / "board_heart_on.png")
        boardOff.writeFile(outDir / "board_heart_off.png")

  echo "#"
  echo &"# WORST gemKeep on the flagged heart: {worstKeep:.3f} (phase " &
    &"{worstKeepPhase}) — the fraction of the gem still nameable as its team color"
  echo &"# worst p95 margin vs the same heart unshimmered: {worstDP95:+.1f}"
  echo &"# max gem saturation drop: {maxSatDrop:.3f}"
  echo &"# max gem hue shift: {maxHueShift:.1f} deg"
  echo &"# max frame-to-frame mean-luma swing (strobe bound): {maxStrobe:.1f}"
  echo &"# max leak onto an UNFLAGGED team's heart (must be 0.0): {maxLeak:.3f}"

  if outDir.len > 0 and tiles.len > 0:
    let
      tw = tiles[0].width
      th = tiles[0].height
    var sheet = newImage(tw * 6, th * 4)
    for i, tile in tiles:
      sheet.draw(tile, translate(vec2(
        float32((i mod 6) * tw), float32((i div 6) * th))))
    sheet.writeFile(outDir / "heart_contact_sheet.png")
    echo "# wrote ", outDir / "heart_contact_sheet.png"

main()
