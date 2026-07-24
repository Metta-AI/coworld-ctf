## Generates the crown skin masters from the canonical team soldier art.
##
## Run from the repository root:
##   nim r tools/generate_crown_skins.nim
##
## The crown is drawn in the masters' painted style: a shaded gold band that
## hugs the helmet dome (centered on the measured helmet center, x~43), three
## ball-tipped points, a team-colored jewel, and a thin warm outline. Geometry
## is in master pixels (127x116); the helmet crest spans roughly x 22..65 with
## its top at y~8.

import pixie

type TeamArt = object
  sourcePath: string
  outputPath: string
  jewel: Color

const SoldierSkins = [
  TeamArt(
    sourcePath: "data/soldier_red.png",
    outputPath: "data/soldier_red_crown.png",
    jewel: color(0.90, 0.28, 0.30, 1)
  ),
  TeamArt(
    sourcePath: "data/soldier_blue.png",
    outputPath: "data/soldier_blue_crown.png",
    jewel: color(0.30, 0.55, 0.91, 1)
  )
]

const
  CrownCx = 43.0      ## helmet dome center in master pixels.
  CrownHalfW = 17.0   ## half-width of the band: x 26..60 on a ~43px helmet.
  BandTopY = 14.0     ## band upper edge at the band ends.
  BandBotY = 21.0     ## band lower edge at the ends; sags 3px mid-dome.
  BandSag = 3.0       ## downward bow so the band reads as wrapped on the dome.
  SidePointTipY = 4.0
  MidPointTipY = 0.5
  TipBallR = 2.6
  Outline = 2.2

proc crownBody(): Path =
  ## One closed path: base band with a sagging bottom arc, three points
  ## rising off the band top. Left/right points lean slightly outward.
  let
    l = CrownCx - CrownHalfW
    r = CrownCx + CrownHalfW
  result = newPath()
  # Bottom edge, left to right, bowed down mid-dome.
  result.moveTo(l, BandBotY)
  result.quadraticCurveTo(CrownCx, BandBotY + BandSag * 2, r, BandBotY)
  # Right side up to the right point tip (leaning slightly outward).
  result.lineTo(r, BandTopY)
  result.lineTo(r + 1.0, SidePointTipY)
  # Valley, then the taller middle point.
  result.lineTo(CrownCx + 6.5, BandTopY + 1.5)
  result.lineTo(CrownCx, MidPointTipY)
  result.lineTo(CrownCx - 6.5, BandTopY + 1.5)
  # Left point, mirroring the right.
  result.lineTo(l - 1.0, SidePointTipY)
  result.lineTo(l, BandTopY)
  result.closePath()

proc tipBall(cx, cy: float): Path =
  result = newPath()
  result.circle(cx, cy, TipBallR)

proc addCrown(master: Image, jewel: Color): Image =
  ## Composites the crown over the cog's helmet in the painted house style.
  result = newImage(master.width, master.height)
  result.draw(master)

  let
    outlineColor = color(0.36, 0.24, 0.09, 1)
    goldPaint = newPaint(LinearGradientPaint)
  # Vertical gold gradient: sunlit top, brassy base — matches the soft
  # shading of the painted masters better than a flat fill.
  goldPaint.gradientHandlePositions = @[
    vec2(CrownCx, MidPointTipY),
    vec2(CrownCx, BandBotY + BandSag * 2)
  ]
  goldPaint.gradientStops = @[
    ColorStop(color: color(0.99, 0.90, 0.55, 1), position: 0),
    ColorStop(color: color(0.87, 0.66, 0.22, 1), position: 1)
  ]

  let body = crownBody()
  result.fillPath(body, goldPaint)
  result.strokePath(body, outlineColor, strokeWidth = Outline)

  # Ball tips: a slightly lighter gold so they read as separate knobs.
  let ballGold = color(0.98, 0.86, 0.45, 1)
  for (cx, cy) in [
    (CrownCx - CrownHalfW - 1.0, SidePointTipY),
    (CrownCx, MidPointTipY),
    (CrownCx + CrownHalfW + 1.0, SidePointTipY)
  ]:
    let ball = tipBall(cx, cy - 1.0)
    result.fillPath(ball, ballGold)
    result.strokePath(ball, outlineColor, strokeWidth = 1.6)

  # Team-colored jewel centered on the band, with a small white glint.
  var gem = newPath()
  gem.ellipse(CrownCx, BandTopY + 4.5, 3.2, 3.8)
  result.fillPath(gem, jewel)
  result.strokePath(gem, outlineColor, strokeWidth = 1.4)
  var glint = newPath()
  glint.circle(CrownCx - 1.0, BandTopY + 3.2, 0.9)
  result.fillPath(glint, color(1, 1, 1, 0.85))

when isMainModule:
  for art in SoldierSkins:
    let master = readImage(art.sourcePath)
    master.addCrown(art.jewel).writeFile(art.outputPath)
    echo "wrote ", art.outputPath
