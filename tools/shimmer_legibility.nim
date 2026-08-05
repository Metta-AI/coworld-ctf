## Objective legibility harness for the metallic shimmer: does the ONE flagged
## cog measurably out-read its own stock teammates at the zoom a spectator
## actually watches at?
##
## `tools/shimmer_preview.nim` is the eyeball loop (a contact strip). This is the
## NUMBER loop. It renders the identical board twice — once with the shimmer
## policy installed, once without — poses one flagged cog and one stock control
## of the SAME team side by side on open floor, box-downsamples the emitted
## board to a real on-screen scale, and reports per-phase statistics.
##
## Why the downsample matters more than anything else here: the board emits at
## RenderScale (2x map px) and the viewer fits the whole 1235x659 field into the
## embed, so at the authored 760px-wide reference board one SCREEN pixel is the
## average of ~3.3x3.3 emitted pixels. A sheen feature narrower than ~3 emitted
## px is averaged into nothing before a human ever sees it. Measuring the raw
## sprite (or a 5x crop) hides exactly the failure this tool exists to catch.
##
##   nim c -d:release -r tools/shimmer_legibility.nim [outDir] [screenPerMap]
##
## Prints a TSV table on stdout and, if outDir is given, writes a 24-phase
## contact sheet plus full-board stills at the measured scale.
import
  std/[algorithm, math, os, strformat, strutils],
  pixie,
  ../src/ctf/[global, shimmer, sim, sim_types, team_colors],
  toolutil

const
  Cogs = 8              ## 4 teams x (flagged, control).
  Phases = CogMetalSweepFrames    ## one full glint cycle, one row per baked
                                  ## phase — so consecutive rows really ARE
                                  ## consecutive frames and the strobe bound
                                  ## below measures what a viewer sees.
  TicksPerPhase = CogMetalTicksPerFrame
  Spacing = 150         ## map px between posed cogs.
  HueTol = 25.0         ## degrees of hue a shell pixel may drift and still be
                        ## nameable as the same team color.
  SatKeep = 0.55        ## fraction of the control shell's saturation a pixel
                        ## must retain to still count as team-colored.
  BoxPx = 34            ## bbox side in MAP px == SoldierBodyPx, the cog's own
                        ## footprint. Deliberately not a tight crop on the dome:
                        ## the p95 has to beat the cog's own bright art (face
                        ## glyph, cyan aim accents, gun), not just the floor.

type Stat = object
  peak: float           ## max Rec.709 luminance in the bbox, 0..255.
  p95: float            ## 95th percentile luminance in the bbox.
  meanLum: float
  meanSat: float        ## HSV S, 0..1, averaged over the bbox.
  meanHue: float        ## circular mean hue in degrees.
  offSat: float         ## mean HSV S over the bbox MINUS the shell disc — the
                        ## team-color read of the parts of the cog the sheen
                        ## does not touch (legs, wheels, torso, gun: ~85% of the
                        ## footprint). A metallic SHELL is the feature; a
                        ## washed-out cog is the failure, and only this column
                        ## can tell them apart.
  offHue: float
  shellKeep: float      ## THE COLOR-IDENTITY CRITERION. Fraction of the SHELL
                        ## disc (the sheen's own footprint, the only place it can
                        ## act) whose pixels still read as the team color: hue
                        ## within HueTol of the control cog's own shell hue AND
                        ## saturation at least SatKeep of the control's shell
                        ## saturation. A bbox-wide mean saturation CANNOT see
                        ## this — it is diluted by floor, ink, shadow and the
                        ## whole untouched lower body, which is exactly how a
                        ## shell washed to near-white scored a harmless-looking
                        ## -0.04 and shipped as "modest". The question a
                        ## spectator actually answers is "can I still NAME this
                        ## cog's color", and that is a COUNT over shell pixels.
  shellHue: float
  shellSat: float

proc lum(c: ColorRGBX): float =
  ## Rec.709 luma on straight (un-premultiplied is irrelevant here: the board
  ## composite is fully opaque) 0..255 channels.
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
  ## board into the embed box. A nearest-neighbour sample would flatter the
  ## effect by preserving sub-pixel spikes the real viewer averages away.
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

proc statOf(img: Image, cxMap, cyMap: int, screenPerMap: float,
            debugProfile = false, refHue = -1.0, refSat = 0.0): Stat =
  ## Statistics over one cog's SoldierBodyPx bbox, in screen pixels.
  let
    half = float(BoxPx) * screenPerMap / 2.0
    cx = float(cxMap) * screenPerMap
    cy = float(cyMap) * screenPerMap
    x0 = max(0, int(cx - half))
    x1 = min(img.width, int(cx + half) + 1)
    y0 = max(0, int(cy - half))
    y1 = min(img.height, int(cy + half) + 1)
  var
    lums: seq[float]
    sumSat, sumLum, sumHx, sumHy, n = 0.0
    offSat, offHx, offHy, offN = 0.0
  # Shell disc: the sheen's own footprint, in screen px. Anything outside it is
  # cog art the overlay never draws on.
  let shellR = 9.0 * screenPerMap
  for y in y0 ..< y1:
    for x in x0 ..< x1:
      let
        c = img.data[y * img.width + x]
        l = lum(c)
        (h, s, _) = hsvOf(c)
      lums.add l
      sumLum += l
      sumSat += s
      # Weight the hue mean by saturation: unsaturated floor/shadow pixels have
      # no meaningful hue and would otherwise inject noise into the circular mean.
      sumHx += s * cos(h * PI / 180.0)
      sumHy += s * sin(h * PI / 180.0)
      n += 1.0
      let
        rx = float(x) - cx
        ry = float(y) - cy
      if rx * rx + ry * ry > shellR * shellR:
        offSat += s
        offHx += s * cos(h * PI / 180.0)
        offHy += s * sin(h * PI / 180.0)
        offN += 1.0
  # Shell-identity pass. `ref` is the control cog's own shell reading, so the
  # test is always flagged-vs-teammate on the same palette entry rather than
  # against an absolute that would move with the slug.
  block:
    var
      hues: seq[float]
      sats: seq[float]
    for y in y0 ..< y1:
      for x in x0 ..< x1:
        let
          rx = float(x) - cx
          ry = float(y) - cy
        if rx * rx + ry * ry > shellR * shellR: continue
        let (h, s, _) = hsvOf(img.data[y * img.width + x])
        if s >= 0.20:                 # ink, visor and shadow are not shell.
          hues.add h
          sats.add s
    if sats.len > 0:
      var hx, hy = 0.0
      for h in hues:
        hx += cos(h * PI / 180.0); hy += sin(h * PI / 180.0)
      result.shellHue = arctan2(hy, hx) * 180.0 / PI
      if result.shellHue < 0: result.shellHue += 360.0
      sats.sort()
      result.shellSat = sats[sats.len div 2]
  if refHue >= 0.0:
    var keep, tot = 0.0
    for y in y0 ..< y1:
      for x in x0 ..< x1:
        let
          rx = float(x) - cx
          ry = float(y) - cy
        if rx * rx + ry * ry > shellR * shellR: continue
        let (h, s, _) = hsvOf(img.data[y * img.width + x])
        tot += 1.0
        var dh = abs(h - refHue)
        if dh > 180.0: dh = 360.0 - dh
        if dh <= HueTol and s >= SatKeep * refSat: keep += 1.0
    result.shellKeep = if tot > 0: keep / tot else: 0.0
  lums.sort()
  if debugProfile:
    # Top of the luminance distribution, brightest first. When a margin is thin
    # this is the only thing that says WHY: too few sheen pixels, or enough
    # pixels that are not bright enough.
    var s = "#   top30: "
    for i in countdown(lums.high, max(0, lums.len - 30)):
      s.add lums[i].formatFloat(ffDecimal, 0) & " "
    echo s, " (n=", lums.len, ")"
  result.offSat = offSat / offN
  result.offHue = arctan2(offHy, offHx) * 180.0 / PI
  if result.offHue < 0: result.offHue += 360.0
  result.peak = lums[^1]
  result.p95 = lums[int(float(lums.len - 1) * 0.95)]
  result.meanLum = sumLum / n
  result.meanSat = sumSat / n
  result.meanHue = arctan2(sumHy, sumHx) * 180.0 / PI
  if result.meanHue < 0: result.meanHue += 360.0

proc hueDelta(a, b: float): float =
  var d = abs(a - b)
  if d > 180.0: d = 360.0 - d
  d

proc buildSim(flagged: bool): SimServer =
  var config = defaultGameConfig()
  config.teams = 4
  config.mapPath = "gen"
  config.mapGen.layout = "corners"
  config.mapSeed = 42
  config.slots.setLen(Cogs)
  result = initSimServer(config)
  for i in 0 ..< Cogs:
    discard result.addPlayer(
      (if i mod 2 == 0: "metalpolicy" else: "stockpolicy") & "_(" & $i & ")")
  result.startGame()
  discard flagged

proc pose(sim: var SimServer) =
  ## Park the cogs in a line across open floor, all aiming east, all alive.
  let
    cx = sim.gameMap.center.x
    cy = sim.gameMap.center.y
  for i in 0 ..< Cogs:
    sim.players[i].team = Team(i div 2)
    sim.players[i].x = cx - (Cogs div 2) * Spacing + i * Spacing + Spacing div 2
    sim.players[i].y = cy
    # SHIM_AIM rotates every posed cog, so the overhang of the shell disc past
    # the head cube can be checked at aims other than due east (the cube is
    # 18x16 axis-aligned and ~18x18 at 45 degrees).
    sim.players[i].aimBrads = parseInt(getEnv("SHIM_AIM", "0"))
    sim.players[i].alive = true
  sim.phase = Playing

proc main() =
  chdirGameDir()
  let
    outDir = if paramCount() >= 1: paramStr(1) else: ""
    screenPerMap = if paramCount() >= 2: parseFloat(paramStr(2)) else: 0.615
    palette = if paramCount() >= 3: paramStr(3) else: ""
  if palette.len > 0:
    doAssert setTeamDisplayColors(palette), "palette payload rejected: " & palette
  var
    simOn = buildSim(true)
    simOff = buildSim(false)
  simOn.pose()
  simOff.pose()
  let
    scale = boardRenderScaleFor(simOn.gameMap.width, simOn.gameMap.height)
    factor = screenPerMap / float(scale)

  echo "# screenPerMap=", screenPerMap, " boardScale=", scale,
    " downsample=", factor.formatFloat(ffDecimal, 3),
    " bbox=", BoxPx, "map px -> ", int(float(BoxPx) * screenPerMap), "screen px",
    (if palette.len > 0: " palette=" & palette else: "")
  # nsSat/nsHue = the SAME flagged cog rendered with the shimmer policy removed —
  # the exact counterfactual for "what did the sheen cost the color axis".
  # xSat/xHue = the same pair measured OUTSIDE the shell disc.
  echo "phase\tteam\tslug\tfPeak\tcPeak\tdPeak\tfP95\tcP95\tdP95\t" &
    "fSat\tcSat\tdSat\tfHue\tcHue\tdHue\tnsSat\tdSatOwn\tnsHue\tdHueOwn\t" &
    "fxSat\tnsxSat\tdxSat\tdxHue\tfKeep\tcKeep\tfShellHue\tcShellHue\tdShellHue"

  var
    sheets: seq[Image]
    worstDPeak = 1e9
    worstDP95 = 1e9
    worstPhase = -1
    worstTeam = 0
    maxSatDrop = 0.0
    maxHueShift = 0.0
    prevPeak: array[4, float]
    maxStrobe = 0.0

  for phase in 0 ..< Phases:
    let want = phase * TicksPerPhase
    for s in [addr simOn, addr simOff]:
      while s[].tickCount < want:
        s[].step(newSeq[InputState](s[].players.len),
                 newSeq[InputState](s[].players.len))
        s[].pose()
      s[].pose()
    # The shimmer registry is PROCESS-global, so it has to be flipped around each
    # render rather than baked into the two sims at construction.
    setShimmerPolicy("metalpolicy")
    let boardOn = boxDownsample(simOn.renderBoardFrame(scale = scale), factor)
    setShimmerPolicy("")
    let boardOff = boxDownsample(simOff.renderBoardFrame(scale = scale), factor)
    for t in 0 ..< 4:
      let
        fi = t * 2          # flagged seat
        ci = t * 2 + 1      # stock control, same team
        dbg = phase == 0 and getEnv("SHIM_PROFILE").len > 0
        c = boardOn.statOf(simOn.players[ci].x, simOn.players[ci].y, screenPerMap, dbg)
        f = boardOn.statOf(simOn.players[fi].x, simOn.players[fi].y, screenPerMap, dbg,
                           c.shellHue, c.shellSat)
        cSelf = boardOn.statOf(simOn.players[ci].x, simOn.players[ci].y, screenPerMap,
                               false, c.shellHue, c.shellSat)
        fOff = boardOff.statOf(
          simOff.players[fi].x, simOff.players[fi].y, screenPerMap)
        dPeak = f.peak - c.peak
        dP95 = f.p95 - c.p95
        dSat = f.meanSat - c.meanSat
        dSatOwn = f.meanSat - fOff.meanSat
        dHue = hueDelta(f.meanHue, c.meanHue)
      # The per-seat phase stride means seat fi's own glint frame is
      # cogMetalPhase(tick, seat); label rows by that so the WORST row names the
      # real baked frame, not the sample index.
      let ownPhase = cogMetalPhase(want, fi)
      echo &"{ownPhase}\t{t}\t{teamDisplaySlug(Team(t))}\t" &
        &"{f.peak:.1f}\t{c.peak:.1f}\t{dPeak:+.1f}\t" &
        &"{f.p95:.1f}\t{c.p95:.1f}\t{dP95:+.1f}\t" &
        &"{f.meanSat:.3f}\t{c.meanSat:.3f}\t{dSat:+.3f}\t" &
        &"{f.meanHue:.1f}\t{c.meanHue:.1f}\t{dHue:.1f}\t" &
        &"{fOff.meanSat:.3f}\t{dSatOwn:+.3f}\t" &
        &"{fOff.meanHue:.1f}\t{hueDelta(f.meanHue, fOff.meanHue):.1f}\t" &
        &"{f.offSat:.3f}\t{fOff.offSat:.3f}\t{f.offSat - fOff.offSat:+.3f}\t" &
        &"{hueDelta(f.offHue, fOff.offHue):.1f}\t" &
        &"{f.shellKeep:.3f}\t{cSelf.shellKeep:.3f}\t" &
        &"{f.shellHue:.1f}\t{c.shellHue:.1f}\t{hueDelta(f.shellHue, c.shellHue):.1f}"
      if dPeak < worstDPeak:
        worstDPeak = dPeak; worstPhase = ownPhase; worstTeam = t
      worstDP95 = min(worstDP95, dP95)
      maxSatDrop = max(maxSatDrop, -dSatOwn)
      maxHueShift = max(maxHueShift, hueDelta(f.meanHue, fOff.meanHue))
      if phase > 0:
        maxStrobe = max(maxStrobe, abs(f.peak - prevPeak[t]))
      prevPeak[t] = f.peak
    if outDir.len > 0:
      # Contact tile: the flagged RED cog, cropped to its bbox, at the measured
      # screen scale then nearest-upscaled 6x so a reader can see what the
      # numbers describe without the crop flattering the effect.
      let
        side = int(float(BoxPx) * screenPerMap)
        px = int(float(simOn.players[0].x) * screenPerMap) - side div 2
        py = int(float(simOn.players[0].y) * screenPerMap) - side div 2
      var tile = newImage(side * 6, side * 6)
      for y in 0 ..< side * 6:
        for x in 0 ..< side * 6:
          let
            sx = px + x div 6
            sy = py + y div 6
          if sx >= 0 and sy >= 0 and sx < boardOn.width and sy < boardOn.height:
            tile.data[y * tile.width + x] = boardOn.data[sy * boardOn.width + sx]
      sheets.add tile
      if phase == 0:
        boardOn.writeFile(outDir / "board_shimmer_on.png")
        boardOff.writeFile(outDir / "board_shimmer_off.png")

  echo "#"
  echo &"# WORST phase (min peak margin): frame {worstPhase} team {worstTeam} " &
    &"({teamDisplaySlug(Team(worstTeam))})  dPeak={worstDPeak:+.1f}"
  echo &"# worst p95 margin over all phases/teams: {worstDP95:+.1f}"
  echo &"# max saturation drop vs same cog unshimmered: {maxSatDrop:.3f}"
  echo &"# max hue shift vs same cog unshimmered: {maxHueShift:.1f} deg"
  echo &"# max frame-to-frame peak swing (strobe bound): {maxStrobe:.1f}"

  if outDir.len > 0 and sheets.len > 0:
    let
      tw = sheets[0].width
      th = sheets[0].height
    var sheet = newImage(tw * sheets.len, th)
    for i, tile in sheets:
      sheet.draw(tile, translate(vec2(float32(i * tw), 0)))
    sheet.writeFile(outDir / "contact_sheet.png")
    echo "# wrote ", outDir / "contact_sheet.png"

main()
