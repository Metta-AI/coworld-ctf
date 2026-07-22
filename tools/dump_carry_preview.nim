## Renders the APPROVED CvC carry pose on the cog (broadcast view only) and
## echoes the measured mount numbers the engine wiring needs. The pose, locked
## by eyes-on review 2026-07-21: the heart is CRADLED IN FRONT of the head
## along the aim ray, drawn z-BETWEEN the cog's bottom half (wheels) and top
## half (head) — wheels behind it, head chin over it — and the gun rides the
## RIGHT FACE of the head, handle-anchored and flipped so the hopper faces
## outward while the muzzle stays on the aim ray. Renders a Blue cog carrying
## the Red heart at 4 aim rotations. Cosmetic / broadcast-only: the RL POV is
## untouched.
##
## The head/wheels z-split mirrors the in-flight engine work that splits the
## player sprite into a swiveling head and movement-driven wheels; here both
## halves still rotate together — only the SANDWICH matters for judging. The
## `candidates` list re-opens to multiple columns if a future round wants to
## iterate again; the echoed "measured mount numbers" block is the handoff
## spec for wiring the pose once the sprite split lands.

import
  pixie,
  ../src/ctf/sim

proc spriteToImage(pixels: seq[uint8], width, height: int): Image =
  result = newImage(width, height)
  for i in 0 ..< width * height:
    result.data[i] = rgba(
      pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2], pixels[i * 4 + 3]
    ).rgbx()

const
  CarryTeam = Red            ## the stolen heart's team (crimson), carried by Blue.
  HeartPx = 20               ## FlagBannerW today.
  Cell = 190                 ## px per preview cell.
  Zoom = 2.0                 ## map px -> preview px, to judge the read up close.
  AuraSize = 26              ## matches FlagAuraSize in global.nim.
  HeadCutRow = 62            ## master row splitting head (above) from legs/feet
                             ## (below). Side wheels straddle it; fine for a
                             ## placement preview.

# Both placements are LOCKED (4 rounds of eyes-on review): the heart 12px
# forward along the aim, sandwiched wheels -> heart -> head; the gun's HANDLE
# (~mid-length of the master) on the head's RIGHT face, +3px outboard of the
# measured face edge, flipped so the hopper faces outward. Both the head
# center (along aim; the head sits BEHIND the pivot in this master) and the
# head's right-face offset are MEASURED from the sprite's solid pixels at
# runtime, so the numbers survive a re-painted master.
# Each candidate is (label, fwdDelta, sideDelta) in map px relative to the
# measured head-center / right-face mount.
let
  heartFwd = 12.0
  candidates = [
    ("FINAL: +3 out", 0.0, 3.0),
  ]

when isMainModule:
  let
    floor = readImage("data/arena_floor.png")
    master = readImage("data/soldier_blue.png")
    gunMaster = readImage("data/paintgun.png")
    rots = [0, 4, 8, 12]           ## E, N, W, S aim steps (16 per turn).
    outPath = "/tmp/carry_preview.png"
    cols = candidates.len
    rows = rots.len

  # Body pivot + scale, exactly like sim.nim's measureSoldierBody (alpha >= 200
  # = the cog shell; the baked drop shadow is excluded).
  var
    sumX, sumY = 0.0
    n = 0
    top = master.height
    bot = -1
  for y in 0 ..< master.height:
    for x in 0 ..< master.width:
      if master.data[y * master.width + x].a >= 200:
        sumX += float(x); sumY += float(y); inc n
        top = min(top, y); bot = max(bot, y)
  let
    pivotX = sumX / float(n)
    pivotY = sumY / float(n)
    bodyScale = float(SoldierBodyPx) / max(1.0, float(bot - top + 1))

  # Measure the HEAD box (solid pixels above HeadCutRow) for the gun mount:
  # the head's center along the aim axis and its right-face edge. The master
  # faces SOUTH, so master +y = aim (unit +x) and the cog's RIGHT hand is
  # master -x (image left).
  var
    headMinX = master.width
    headSumY = 0.0
    headN = 0
  for y in 0 ..< min(HeadCutRow, master.height):
    for x in 0 ..< master.width:
      if master.data[y * master.width + x].a >= 200:
        headMinX = min(headMinX, x)
        headSumY += float(y)
        inc headN
  let
    headCy = headSumY / float(max(1, headN))
    # Map px, unit space: mount = center of the head's right face, tucked
    # INWARD (the gun is bolted to the head, not held at arm's length — the
    # barrel line rides a couple px inside the face edge).
    mountFwd = (headCy - pivotY) * bodyScale
    mountSide = (pivotX - float(headMinX)) * bodyScale - 2.0

  # Split the master into head (rows < HeadCutRow) and wheels/legs halves so
  # the heart can be drawn BETWEEN them.
  var
    headImg = newImage(master.width, master.height)
    baseImg = newImage(master.width, master.height)
  for y in 0 ..< master.height:
    for x in 0 ..< master.width:
      let px = master.data[y * master.width + x]
      if y < HeadCutRow:
        headImg.data[y * master.width + x] = px
      else:
        baseImg.data[y * master.width + x] = px

  let gunScale = float(GunLengthPx) / max(1.0, float(gunMaster.width))

  var canvas = newImage(cols * Cell, rows * Cell + 24)
  var ty = 0
  while ty < canvas.height:
    var tx = 0
    while tx < canvas.width:
      canvas.draw(floor, translate(vec2(float32(tx), float32(ty))))
      tx += floor.width
    ty += floor.height

  for ci, cand in candidates:
    let
      (_, fwdDelta, sideDelta) = cand
      gunFwd = mountFwd + fwdDelta
      gunSide = mountSide + sideDelta
    for ri, rot in rots:
      let
        cx = float32(ci * Cell + Cell div 2)
        cy = float32(ri * Cell + Cell div 2 + 12)
        brads = rot * (AimBradsTurn div SoldierRotations)
        (ax, ay) = aimVector(brads)          # unit aim, screen coords.
        angle = float(rot) * 2.0 * PI / float(SoldierRotations)
        # Mirrors soldierRotPixels: unit space +x = aim; the extra -90 deg turns
        # the south-facing master so the face leads the aim. Zoom folds into
        # the scale and the pre-rotation offsets.
        unitRot =
          translate(vec2(cx, cy)) *
          rotate(float32(-angle))
        bodyMat =
          unitRot *
          rotate(float32(-PI / 2)) *
          scale(vec2(float32(bodyScale * Zoom), float32(bodyScale * Zoom))) *
          translate(vec2(float32(-pivotX), float32(-pivotY)))
        # Gun anchored by its MID-LENGTH (the handle, image center-x) at
        # (gunFwd, gunSide) in unit space: +x = aim, +y = the cog's right hand
        # side (screen-down at east aim). Mirrored across the barrel midline
        # (y' = h - y) so the hopper faces AWAY from the head; the muzzle
        # still points exactly along +x, so tracers keep lining up.
        gunMat =
          unitRot *
          translate(vec2(
            float32(gunFwd * Zoom), float32(gunSide * Zoom))) *
          scale(vec2(float32(gunScale * Zoom), float32(gunScale * Zoom))) *
          translate(vec2(
            float32(-gunMaster.width) / 2, float32(-gunMaster.height) / 2)) *
          translate(vec2(0, float32(gunMaster.height))) * scale(vec2(1, -1))
        heart = spriteToImage(
          loadHeartSprite(CarryTeam, int(float(HeartPx) * Zoom)),
          int(float(HeartPx) * Zoom), int(float(HeartPx) * Zoom))
        heartX = cx + float32(heartFwd * Zoom) * ax - float32(heart.width) / 2
        heartY = cy + float32(heartFwd * Zoom) * ay - float32(heart.height) / 2

      # Carrier aura disc (soft red glow) UNDER everything, as in the real
      # render.
      let auraPx = int(AuraSize.float * Zoom)
      var aura = newImage(auraPx, auraPx)
      let c = float(auraPx - 1) / 2
      for yy in 0 ..< auraPx:
        for xx in 0 ..< auraPx:
          let d = sqrt((float(xx) - c) * (float(xx) - c) +
                       (float(yy) - c) * (float(yy) - c))
          if d > c: continue
          let a = uint8(min(150.0, 30.0 + 130.0 * (1.0 - d / c)))
          aura.data[yy * auraPx + xx] = rgba(255, 120, 120, a).rgbx()
      canvas.draw(aura, translate(vec2(cx - float32(auraPx) / 2,
                                       cy - float32(auraPx) / 2)))

      # The cradle: wheels -> heart -> head -> gun (right hand).
      canvas.draw(baseImg, bodyMat)
      canvas.draw(heart, translate(vec2(heartX, heartY)))
      canvas.draw(headImg, bodyMat)
      canvas.draw(gunMaster, gunMat)

  canvas.writeFile(outPath)
  echo "wrote ", outPath
  echo "columns (L->R): "
  for cand in candidates:
    echo "  - ", cand[0]
  echo "rows (T->B): aim E, N, W, S"
  echo ""
  echo "measured mount numbers (master ", master.width, "x", master.height, "):"
  echo "  pivot        = (", pivotX, ", ", pivotY, ") master px"
  echo "  bodyScale    = ", bodyScale, " (SoldierBodyPx ", SoldierBodyPx, " / solid height)"
  echo "  headCy       = ", headCy, " master px, headMinX = ", headMinX
  echo "  mountFwd     = ", mountFwd, " map px along aim (head center; negative = behind pivot)"
  echo "  mountSide    = ", mountSide, " map px to cog's right (face edge - 2 tuck)"
  echo "  FINAL gun    = (fwd ", mountFwd + candidates[0][1],
       ", side ", mountSide + candidates[0][2], ") map px, handle-anchored, v-flipped"
  echo "  FINAL heart  = 12.0 map px along aim, ", HeartPx, "px sprite"
