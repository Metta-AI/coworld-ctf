## Renders a CONTACT SHEET of many generated maps in one image, so a whole
## slice of the generator's output can be judged at a glance instead of one
## map at a time. The point is the DISTRIBUTION: sameness, dead space and
## repeated motifs are visible across a grid and invisible in a single render.
##
## Every tile is scaled to a common cell and letterboxed, so boards of
## different size classes stay comparable rather than one giant map dwarfing
## the rest. The cell caption carries seed, size class and the two numbers
## that matter most (staticScore, interiorFrac) so the picture and the
## measurement are read together — a lesson paid for twice this session,
## where the best-scoring shapes rendered as a barcode and as confetti.
##
## Usage: nim c -d:release -r tools/map_sheet.nim [count] [out.png] [teams]
##                                                 [--label]
##
## `--label` prints each tile's ARCHETYPE in the caption. It is off by
## default on purpose: the brief's acceptance test is that an observer can
## point at a tile and say which archetype it is FROM THE PICTURE, and a
## caption that answers the question voids the test. Render the plain sheet
## first, name the tiles, then render the labelled one as the answer key.
## Demo/curation tooling; not part of the server.
import
  std/[os, strformat, strutils],
  bitworld/pixelfonts,
  pixie,
  ../src/ctf/[arena, map_metrics, sim],
  map_render

const
  CellW = 300          ## per-tile box, wide enough to read structure at a glance
  CellH = 190
  CaptionH = 26
  Pad = 6
  Cols = 5
  Paper = rgba(246, 244, 240, 255)   ## warm near-white, never pure #fff
  Ink = rgba(38, 36, 33, 255)        ## warm near-black

proc drawText(dst: Image, font: PixelFont, text: string, x, y: int,
    color: ColorRGBA) =
  ## Blits one line of the embedded pixel font. `pixelfonts` exposes glyphs but
  ## no compositor, and the board art is pixel work, so a 1:1 blit is both the
  ## simplest and the most legible option here.
  var penX = x
  for ch in text:
    let glyph = font.glyphAt(ch)
    if glyph.width > 0:
      for gy in 0 ..< font.height:
        for gx in 0 ..< glyph.width:
          if glyph.glyphPixel(gx, gy):
            let
              px = penX + gx
              py = y + gy
            if px >= 0 and py >= 0 and px < dst.width and py < dst.height:
              dst.unsafe[px, py] = color.rgbx
    penX += font.glyphAdvance(ch)

when isMainModule:
  let
    count = if paramCount() >= 1: parseInt(paramStr(1)) else: 50
    outPath = if paramCount() >= 2: paramStr(2) else: "map-sheet.png"
    teams =
      if paramCount() >= 3 and not paramStr(3).startsWith("--"):
        parseInt(paramStr(3))
      else: 2
    label = "--label" in commandLineParams()
    rows = (count + Cols - 1) div Cols
    sheetW = Cols * (CellW + Pad) + Pad
    sheetH = rows * (CellH + CaptionH + Pad) + Pad
  var sheet = newImage(sheetW, sheetH)
  sheet.fill(Paper)
  let font = readTiny5Font()

  var
    scoreSum = 0.0
    interiorSum = 0.0
    scored = 0
  for i in 0 ..< count:
    let seed = 1000 + i
    var gameMap: CtfMap
    try:
      gameMap = generateCtfMap(seed, teams = teams)
    except CatchableError as e:
      echo &"seed {seed}: FAILED — {e.msg}"
      continue
    let
      m = evaluateMap(gameMap, "gen")
      score = staticScore(m)
    scoreSum += score
    interiorSum += m.interiorFrac
    inc scored
    # Render at the tile's scale, letterboxed into the cell.
    let img = renderMap(gameMap, MapRenderOptions(
      maxDimension: max(CellW, CellH),
      overlays: {overlayProtected},
    )).image
    let
      col = i mod Cols
      row = i div Cols
      x0 = Pad + col * (CellW + Pad)
      y0 = Pad + row * (CellH + CaptionH + Pad)
      scale = min(CellW / img.width, CellH / img.height)
      dw = int(img.width.float * scale)
      dh = int(img.height.float * scale)
    var tf = translate(vec2(float(x0 + (CellW - dw) div 2),
                            float(y0 + (CellH - dh) div 2))) *
             scale(vec2(scale, scale))
    sheet.draw(img, tf)
    let sizeName = gameMap.mapSizeClass()
    let caption =
      if label: &"{seed} {sizeName} {mapArchetypeFor(seed, teams)}"
      else: &"{seed} {sizeName}"
    sheet.drawText(font, caption, x0, y0 + CellH + 4, Ink)
    sheet.drawText(font, &"s{score:.3f} i{m.interiorFrac:.3f}",
      x0, y0 + CellH + 14, Ink)

  sheet.writeFile(outPath)
  echo &"{scored} maps -> {outPath}  ({sheetW}x{sheetH})"
  if scored > 0:
    echo &"mean staticScore {scoreSum / scored.float:.3f}   " &
      &"mean interiorFrac {interiorSum / scored.float:.3f}   " &
      &"(arena control: 1.000 / 0.342)"
