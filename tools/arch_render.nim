## arch_render — one SELECTED map per archetype, big enough to read the graph.
##
## The contact sheet answers "are fifty tiles different from each other". This
## answers the other half: "is a `ring` recognisably a ring". A 300 px tile can
## hide a corridor; a 620 px one cannot.
##
##   nim c -d:release -r tools/arch_render.nim [teams] [out.png] [firstSeed]
## Demo/curation tooling; not part of the server.
import std/[os, strformat, strutils]
import bitworld/pixelfonts
import pixie
import ../src/ctf/[arena, map_metrics, sim]
import map_render

const
  CellW = 620
  CellH = 380
  CaptionH = 30
  Pad = 10
  Cols = 2
  Paper = rgba(246, 244, 240, 255)
  Ink = rgba(38, 36, 33, 255)

proc drawText(dst: Image, font: PixelFont, text: string, x, y: int,
    color: ColorRGBA) =
  var penX = x
  for ch in text:
    let glyph = font.glyphAt(ch)
    if glyph.width > 0:
      for gy in 0 ..< font.height:
        for gx in 0 ..< glyph.width:
          if glyph.glyphPixel(gx, gy):
            let (px, py) = (penX + gx, y + gy)
            if px >= 0 and py >= 0 and px < dst.width and py < dst.height:
              dst.unsafe[px, py] = color.rgbx
    penX += font.glyphAdvance(ch)

proc main() =
  let
    teams = if paramCount() >= 1: parseInt(paramStr(1)) else: 2
    outPath = if paramCount() >= 2: paramStr(2) else: "archetypes.png"
    firstSeed = if paramCount() >= 3: parseInt(paramStr(3)) else: 1001
  let wanted = legalArchetypes(teams)
  ## One seed per archetype: the first that draws it AND validates.
  var picks: seq[tuple[arch: MapArchetype, seed: int, gameMap: CtfMap]]
  for arch in wanted:
    var seed = firstSeed
    while seed < firstSeed + 400:
      if mapArchetypeFor(seed, teams) == arch:
        try:
          picks.add (arch, seed, generateCtfMap(seed, teams = teams))
          break
        except CtfError:
          discard
      inc seed
  let rows = (picks.len + Cols - 1) div Cols
  var sheet = newImage(Cols * (CellW + Pad) + Pad,
                       rows * (CellH + CaptionH + Pad) + Pad)
  sheet.fill(Paper)
  let font = readTiny5Font()
  for i, pick in picks:
    let
      img = renderMap(pick.gameMap, MapRenderOptions(
        maxDimension: max(CellW, CellH), overlays: {overlayProtected})).image
      m = evaluateMap(pick.gameMap, "gen")
      x0 = Pad + (i mod Cols) * (CellW + Pad)
      y0 = Pad + (i div Cols) * (CellH + CaptionH + Pad)
      scale = min(CellW / img.width, CellH / img.height)
      dw = int(img.width.float * scale)
      dh = int(img.height.float * scale)
    sheet.draw(img, translate(vec2(float(x0 + (CellW - dw) div 2),
                                   float(y0 + (CellH - dh) div 2))) *
                    scale(vec2(scale, scale)))
    sheet.drawText(font, &"{pick.arch}  seed {pick.seed}  " &
      &"{pick.gameMap.mapSizeClass()}", x0, y0 + CellH + 6, Ink)
    sheet.drawText(font,
      &"score {m.staticScore():.3f}  interior {m.interiorFrac:.3f}  " &
      &"cover {m.coverPermille}pm  routes {m.routeCountMin}",
      x0, y0 + CellH + 17, Ink)
    echo &"{pick.arch:<12} seed {pick.seed} {pick.gameMap.width}x" &
      &"{pick.gameMap.height} routes={m.routeCountMin} int={m.interiorFrac:.3f}"
  sheet.writeFile(outPath)
  echo &"{picks.len} archetypes -> {outPath}"

when isMainModule:
  main()
