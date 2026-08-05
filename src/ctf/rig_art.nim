## Broadcast-side art and asset loading: sprite-sheet/crew/relic PNG
## loaders, the HD soldier renderer (soldierRotPixels), the articulated
## turret rig (rig segments, gun, spray can), and the cog driving physics
## (stepCogDrive) — stage 2 of docs/plans/2026-08-01-sim-split.md.
##
## Everything here is BROADCAST-ONLY: no sim state, nothing in gameHash, no
## GameVersion bump for changes (the section carried that contract as a
## comment inside sim.nim). sim.nim imports and re-exports this module, so
## existing consumers (global.nim, preview tools, tests) are unchanged.

import
  std/[math, os, strutils],
  bitworld/aseprite,
  pixie,
  sim_types, team_colors

when not defined(emscripten):
  import bitworld/client as bitworldClient

proc gameDir*(): string =
  ## Returns the CTF game directory.
  getCurrentDir()

proc clientDataDir*(): string =
  ## Returns the shared client data directory.
  when defined(emscripten):
    gameDir() / "data"
  else:
    bitworldClient.clientDir() / "data"

proc spriteSheetPath(): string =
  ## Returns the sprite sheet aseprite path.
  gameDir() / SpriteSheetAsepritePath

proc loadSpriteSheet*(): Image =
  ## Loads the sprite sheet from aseprite.
  readAsepriteImage(spriteSheetPath())

proc crewSheetPath(): string =
  ## Returns the crew sprite sheet path. A hand-pixeled crew.png (the
  ## purpose-built tactical soldier) is preferred; the legacy crew.aseprite is
  ## the fallback so an art rollback needs no code change.
  for candidate in [
    gameDir() / "data" / "crew.png",
    clientDataDir() / "crew.png",
    clientDataDir() / "crew.aseprite",
    gameDir() / "data" / "crew.aseprite",
  ]:
    if fileExists(candidate):
      return candidate
  gameDir() / "data" / "crew.aseprite"

proc readCrewSheetImage(path: string): Image =
  ## Reads the crew sheet as a Pixie image from either a PNG or an aseprite
  ## file (both render to the same RGBA Image the crew tint path consumes).
  if path.toLowerAscii.endsWith(".png"):
    readImage(path)
  else:
    readAsepriteImage(path)

proc crewSpriteOffset*(sprite: CrewSprite, x, y: int): int =
  ## Returns the RGBA byte offset for one crew sprite pixel.
  (y * sprite.width + x) * 4

proc crewSpriteFromImage(image: Image, index, row: int): CrewSprite =
  ## Extracts one raw 16x16 crew sprite from one sheet row.
  result = CrewSprite(
    width: CrewSpriteSize,
    height: CrewSpriteSize,
    rgba: newSeq[uint8](CrewSpriteSize * CrewSpriteSize * 4)
  )
  let
    baseX = index * CrewSpriteSize
    baseY = row * CrewSpriteSize
  for y in 0 ..< CrewSpriteSize:
    for x in 0 ..< CrewSpriteSize:
      let
        pixel = image[baseX + x, baseY + y]
        offset = result.crewSpriteOffset(x, y)
      result.rgba[offset] = pixel.r
      result.rgba[offset + 1] = pixel.g
      result.rgba[offset + 2] = pixel.b
      result.rgba[offset + 3] = pixel.a

proc loadCrewSpriteRow*(row: int, label: string): seq[CrewSprite] =
  ## Loads eight 16x16 crew sprites from one sheet row.
  if row < 0:
    raise newException(CtfError, "Crew sprite sheet row is negative.")
  let
    path = crewSheetPath()
    image = readCrewSheetImage(path)
  if image.width < CrewSpriteSize * CrewSpriteVariants or
      image.height < CrewSpriteSize * (row + 1):
    raise newException(
      CtfError,
      label & " sprite sheet row is missing eight 16x16 sprites: " & path
    )
  for i in 0 ..< CrewSpriteVariants:
    result.add(image.crewSpriteFromImage(i, row))

proc loadCrewSprites*(): seq[CrewSprite] =
  ## Loads the first eight 16x16 living crew sprites.
  loadCrewSpriteRow(0, "Crew")

proc rgbaSpriteFromImage*(
  source: Image, size: int, alphaCutoff = 0'u8
): seq[uint8] =
  ## The pixel half of `loadRgbaSprite`, split out so a team-recolored master
  ## can be re-tinted in memory before it is scaled into a sprite buffer.
  let image = source.resize(size, size)
  result = newSeq[uint8](size * size * 4)
  for y in 0 ..< size:
    for x in 0 ..< size:
      let
        pixel = image[x, y].rgba
        offset = (y * size + x) * 4
        alpha = if alphaCutoff == 0'u8: pixel.a
                elif pixel.a >= alphaCutoff: 255'u8
                else: 0'u8
      result[offset] = pixel.r
      result[offset + 1] = pixel.g
      result[offset + 2] = pixel.b
      result[offset + 3] = alpha

proc loadRgbaSprite*(name: string, size: int, alphaCutoff = 0'u8): seq[uint8] =
  ## Loads a hand-painted relic PNG from data/ and returns it as a straight-alpha
  ## RGBA buffer scaled to size×size for the Sprite v1 protocol. The PNGs carry
  ## real transparency (alpha-knocked from the art), and pixie stores
  ## premultiplied alpha internally, so we take `.rgba` to hand the protocol
  ## un-premultiplied colors.
  ##
  ## `alphaCutoff` > 0 snaps the resized alpha to a HARD edge (>= cutoff opaque,
  ## else fully clear). Pixie's `resize` is bilinear, so downscaling a big PNG
  ## feathers its bold dark outline into a ring of semi-transparent pixels that
  ## reads as a fuzzy colored halo bleeding onto the floor. Snapping the alpha
  ## keeps the SAME art but restores the crisp outline; the interior facets are
  ## untouched (they were already fully opaque). 128 is the sweet spot at both
  ## the carried (20px) and planted (60px) footprints.
  rgbaSpriteFromImage(readImage(gameDir() / name), size, alphaCutoff)

proc loadHeartSprite*(team: Team, size: int): seq[uint8] =
  ## The CTF objective, a glowing team-colored heart-gem relic (0.7.0 renamed the
  ## "flag" a heart in-sim). Red = crimson life-crystal, Blue = frost life-crystal.
  ## Hard alpha edge (cutoff 128) so the bold painted outline stays crisp at the
  ## sprite footprint instead of feathering into a fuzzy halo on the floor.
  ##
  ## A recolored team (docs/COLOR_CONTRACT.md) borrows another wire color's
  ## hand-painted gem, or gets the red gem re-tinted to its display color.
  let spec = teamArtTint(team, propArt = true)
  if not spec.retint:
    return loadRgbaSprite(
      "data/heart_" & teamText(spec.sourceTeam) & ".png",
      size,
      alphaCutoff = 128'u8
    )
  let image = readImage(
    gameDir() / "data/heart_" & teamText(spec.sourceTeam) & ".png")
  image.applyTeamArtTint(spec, propArt = true)
  rgbaSpriteFromImage(image, size, alphaCutoff = 128'u8)

proc loadMedKitSprite*(size: int): seq[uint8] =
  ## The center-field healing pickup: a chunky white healer's kit with a red
  ## cross, matching the bold-outline painted item style (heart gem, paint
  ## bomb). Hard alpha edge keeps the outline crisp on the floor.
  loadRgbaSprite("data/medkit.png", size, alphaCutoff = 128'u8)

proc loadShieldSprite*(size: int): seq[uint8] =
  ## The endzone protective pickup: a chunky bold-outline heater shield in the
  ## same painted-item style as the med kit and paint bomb. Hard alpha edge
  ## keeps the outline crisp on the floor.
  loadRgbaSprite("data/shield.png", size, alphaCutoff = 128'u8)

proc loadPaintBombSprite*(size: int): seq[uint8] =
  ## The thrown grenade, a kid-friendly dungeon-crawler alchemical paint-bomb orb
  ## (cork-stopped rune bottle of swirling paint — NO fuse). Used for the corner
  ## pickup, the carried icon, and the in-flight projectile.
  loadRgbaSprite("data/paintbomb.png", size)

proc loadSprayCanSprite*(size: int): seq[uint8] =
  ## The side-column cone weapon: a chunky aerosol spray-paint can, in the same
  ## bold-outline painted style as the med kit, shield, and paint bomb (this is
  ## paintball — the short-range weapon sprays paint, it does not fire plasma).
  ## Used for the floor pickup and the carried marker. Hard alpha edge keeps the
  ## ink outline crisp on the floor instead of feathering into a halo.
  loadRgbaSprite("data/spraycan.png", size, alphaCutoff = 128'u8)

## --- HD top-down soldier: CvC cog + gun, rotated as one rigid unit ---
## Each team's master (soldier_red/blue.png) is the canonical Cogs-vs-Clips cog
## facing SOUTH, smile visor visible, used exactly as drawn. It is measured for
## its body pivot (solid-pixel centroid) and scaled so the body fills
## SoldierBodyPx. The shared gun master (paintgun.png: muzzle east, barrel
## centerline at image mid-height) mounts GunGripPx east of the body center
## with its barrel on the aim ray, and body + gun pre-rotate TOGETHER around
## the body center — the cog spins with its gun, so east aim (rot 0) shows the
## master exactly as drawn and tracers always line up with the muzzle.
const SoldierMasterPaths: array[Skin, array[Team, string]] = [
  DefaultSkin: [
    Red: "data/soldier_red.png",
    Blue: "data/soldier_blue.png",
    Green: "data/soldier_green.png",
    Yellow: "data/soldier_yellow.png"
  ],
  CrownSkin: [
    Red: "data/soldier_red_crown.png",
    Blue: "data/soldier_blue_crown.png",
    Green: "data/soldier_green_crown.png",
    Yellow: "data/soldier_yellow_crown.png"
  ]
]

var
  soldierMasters: array[Skin, array[Team, Image]]
  soldierPivotX, soldierPivotY: array[Skin, array[Team, float]]
  soldierScale: array[Skin, array[Team, float]]
  soldierLoaded: array[Skin, array[Team, bool]]
  soldierRotCache: array[
    Skin,
    array[Team, array[SoldierRotations, seq[tuple[
      scale: int, pixels: seq[uint8]
    ]]]]
  ]
  gunMaster: Image
  gunScale: float
  gunLoaded: bool
  sprayMaster: Image
  sprayScale: float
  sprayLoaded: bool

proc measureSoldierBody(skin: Skin, team: Team, master: Image) =
  ## Finds the body pivot and the master->canvas scale: the centroid and
  ## vertical span of the SOLID pixels (alpha >= 200 — the cog shell; the
  ## baked-in soft drop shadow sits below that and is excluded, so the cog
  ## itself, not its shadow, is what centers and fills SoldierBodyPx).
  var
    sumX = 0.0
    sumY = 0.0
    n = 0
    top = master.height
    bot = -1
  for y in 0 ..< master.height:
    for x in 0 ..< master.width:
      if master.data[y * master.width + x].a >= 200:
        sumX += float(x); sumY += float(y); inc n
        top = min(top, y); bot = max(bot, y)
  if n == 0:
    soldierPivotX[skin][team] = float(master.width) / 2
    soldierPivotY[skin][team] = float(master.height) / 2
    soldierScale[skin][team] =
      float(SoldierBodyPx) / max(1.0, float(master.height))
  else:
    soldierPivotX[skin][team] = sumX / float(n)
    soldierPivotY[skin][team] = sumY / float(n)
    soldierScale[skin][team] =
      float(SoldierBodyPx) / max(1.0, float(bot - top + 1))

proc ensureSoldierLoaded(skin: Skin, team: Team) =
  ## Loads (once) the cog master this team is DISPLAYED as. A stock team reads
  ## its own shipped PNG byte-for-byte; a team the platform recolored either
  ## borrows another wire color's hand-tinted master or gets its own re-tinted
  ## at load — see team_colors.teamArtTint. Boot-time: the master feeds every
  ## cached rotation below, so this must run before the first sprite is baked.
  if soldierLoaded[skin][team]:
    return
  let spec = teamArtTint(team)
  let master = readImage(gameDir() / SoldierMasterPaths[skin][spec.sourceTeam])
  master.applyTeamArtTint(spec)
  soldierMasters[skin][team] = master
  measureSoldierBody(skin, team, master)
  soldierLoaded[skin][team] = true

proc ensureGunLoaded() =
  if gunLoaded:
    return
  # Top-down paintball marker, muzzle east, barrel on the image mid-line. Scaled
  # by WIDTH so GunLengthPx spans the full stock-to-muzzle length along the aim.
  gunMaster = readImage(gameDir() / "data/paintgun_topdown.png")
  gunScale = float(GunLengthPx) / max(1.0, float(gunMaster.width))
  gunLoaded = true

proc ensureSprayLoaded() =
  if sprayLoaded:
    return
  # The held spray can: same convention as the gun master (nozzle EAST, body on
  # the image mid-line) so the identical grip math mounts it. Scaled to
  # SprayHeldLengthPx — a can is a short fistful, not a long marker.
  sprayMaster = readImage(gameDir() / "data/spraycan_held.png")
  sprayScale = float(SprayHeldLengthPx) / max(1.0, float(sprayMaster.width))
  sprayLoaded = true

proc soldierRotPixels*(
  team: Team,
  skin: Skin,
  rot: int,
  renderScale = 1
): seq[uint8] =
  ## One pre-rendered soldier sprite (SoldierCanvas·renderScale square,
  ## straight-alpha RGBA): body + gun as one rigid unit, rotated to aim step
  ## `rot`. The master's FACE side (south) leads the aim with the gun held in
  ## front of it — aiming south shows the master exactly as drawn. The masters
  ## are ~120px art rendered down to a 34px body at 1×, so a renderScale > 1
  ## raster recovers genuine painted detail, not upscaled blocks.
  let r = ((rot mod SoldierRotations) + SoldierRotations) mod SoldierRotations
  for cached in soldierRotCache[skin][team][r]:
    if cached.scale == renderScale:
      return cached.pixels
  ensureSoldierLoaded(skin, team)
  ensureGunLoaded()
  let
    master = soldierMasters[skin][team]
    outCanvas = SoldierCanvas * renderScale
    # aim increases counter-clockwise on screen (0=east, 64=north); screen y is
    # down, so a positive brad step rotates the art clockwise in image space —
    # i.e. draw at angle -theta to match aimVector.
    angle = float(r) * 2.0 * PI / float(SoldierRotations)
    s = soldierScale[skin][team] * float(renderScale)
    center = float32(outCanvas) / 2
  var canvas = newImage(outCanvas, outCanvas)
  let
    unitRot =
      translate(vec2(center, center)) *
      rotate(float32(-angle))
    # Unit space: +x = aim. The extra -90° turns the master so its SOUTH side
    # (the smile visor) points along +x — the face leads the aim, right behind
    # the gun.
    bodyMat =
      unitRot *
      rotate(float32(-PI / 2)) *
      scale(vec2(float32(s), float32(s))) *
      translate(
        vec2(
          float32(-soldierPivotX[skin][team]),
          float32(-soldierPivotY[skin][team])
        )
      )
    # Gun-local (0, height/2) — the stock end of the barrel centerline — mounts
    # GunGripPx along the aim (stock behind the hub, barrel reaching out front)
    # and GunRightPx off the aim ray to the cog's RIGHT (+y = right when facing
    # +x/east); it spins with the unit so the marker rides the head's right.
    gunMat =
      unitRot *
      translate(vec2(
        float32(GunGripPx * renderScale), float32(GunRightPx * renderScale))) *
      scale(vec2(
        float32(gunScale * float(renderScale)),
        float32(gunScale * float(renderScale))
      )) *
      translate(vec2(0, float32(-gunMaster.height) / 2))
  canvas.draw(master, bodyMat)
  canvas.draw(gunMaster, gunMat)
  # Straight-alpha RGBA for the Sprite v1 protocol (pixie stores premultiplied).
  var pixels = newSeq[uint8](outCanvas * outCanvas * 4)
  for i in 0 ..< outCanvas * outCanvas:
    let c = canvas.data[i].rgba()
    pixels[i * 4] = c.r
    pixels[i * 4 + 1] = c.g
    pixels[i * 4 + 2] = c.b
    pixels[i * 4 + 3] = c.a
  soldierRotCache[skin][team][r].add((scale: renderScale, pixels: pixels))
  pixels

proc soldierRotIndex*(aimBrads: int): int =
  ## Quantizes an aim angle to the nearest pre-rotated sprite step.
  ((aimBrads + AimBradsTurn div (SoldierRotations * 2)) *
    SoldierRotations div AimBradsTurn) mod SoldierRotations

## --- Articulated TURRET rig: the REAL CvC cog, segmented (broadcast board only) ---
## The SAME real master art as soldierRotPixels, SLICED (scripts/art/build_cvc_rig.py)
## into 9 pieces that recompose to the south master at rest but articulate like a
## tank trike when moving:
##   head  - cube + cyan visor + center pistons + the held GUN. Faces AIM. Drawn
##           LAST so it covers the hub/leg-joins (no head-hole).
##   armL/R- the two shoulder assemblies. Face AIM. TUCKED at rest; reach FORWARD
##           to cradle the carried heart only while carrying (carry-gated caller).
##   legFL/FR/Rear - the three leg struts (tire removed). Face the MOVEMENT heading
##           (CogDriveState.bodyHeading), each hinged about its own hip with a
##           differential turn swing; the INNER leg SHORTENS into a turn.
##   wheelL/R/Rear - the three tires, cut out of the legs, each CASTERING (rotating
##           about its axle) toward the roll direction, capped so a tall top-down
##           tire only tilts to hint the turn (never swings fully broadside).
## The head/arms track AIM while the legs/wheels track MOVEMENT — a true turret
## swivel. All broadcast-only (no sim state, no GameVersion bump); POV keeps the
## unified soldierRotPixels sprite.
##
## Every segment is baked in the SAME 192px master frame space through ONE code
## path (rigSegPixels): rotate the segment about its ANCHOR by a base angle (aim
## for head/arms, bodyHeading for legs/wheels) plus an articulation, then place the
## HUB on the player. At rest everything rotates by the same aim delta about anchors
## that ARE its master pixels, so the composite == the south master.
type
  RigSeg* = enum
    rsHead, rsArmL, rsArmR, rsLegFL, rsLegFR, rsLegRear,
    rsWheelL, rsWheelR, rsWheelRear

const
  RigCanvas* = 96             ## px square rig segment canvas at 1x (fits the
                              ## swung legs + castered wheels + reaching arms).
  # Anchors in 192px master-frame space (scripts/art/build_cvc_rig.py anchors.json).
  RigHub: tuple[x, y: float] = (96.0, 88.0)   ## cog rotation center (head-cube
                              ## center); head, arms and leg-hips all measured here.
  RigAnchor: array[RigSeg, tuple[x, y: float]] = [
    (96.0, 88.0),     # rsHead      (== hub; head rotates about the hub to aim)
    (70.0, 84.0),     # rsArmL      left shoulder attach
    (120.0, 84.0),    # rsArmR      right shoulder attach
    (72.0, 100.0),    # rsLegFL     left front hip
    (120.0, 100.0),   # rsLegFR     right front hip
    (96.0, 80.0),     # rsLegRear   rear hip — flipped 180° about hub to the BACK
    # Wheels caster about their TIRE CENTROID (measured), not the axle at the top —
    # pivoting mid-tire spins the wheel in place, not swinging the tire body out.
    (73.5, 134.0),    # rsWheelL    left front tire centroid
    (117.3, 132.7),   # rsWheelR    right front tire centroid
    (94.7, 48.3)]     # rsWheelRear rear tire centroid — flipped 180° to the BACK
  # Articulation feel (degrees). Legs differential-steer: rest tuck ± splay on the
  # turn signal; the INNER leg shortens instead of splaying wide.
  RigRestTuckDeg = 2.0
  RigSplayDeg = 5.0           ## outer leg barely swings — the inner-leg SHORTEN +
                              ## wheel caster carry the turn read; a big swing on
                              ## the far leg reads as a splayed spider strut.
  RigRearCounterFrac = 0.3    ## rear leg counter-swings this fraction of splay.
  RigInnerShorten = 0.34      ## inner leg shrinks up to this fraction on a turn.
  RigArmReachDeg = 22.0       ## arms swing forward this far to cradle a carried
                              ## heart (art step 1); 0 at rest (tucked shoulders).
  RigShortenSteps* = 4        ## baked leg-length steps (0 = full .. this = shortest).
  RigSteps* = 16              ## baked steps per rotating quantity (aim / heading).
  RigLegSwingSteps* = 3       ## baked leg swing steps across the full turn range.
                              ## The swing range is only ±RigSplayDeg (5°), so a
                              ## handful of steps is already sub-2° — finer steps
                              ## just multiply the pose pool the replay viewer
                              ## must bake, ship, and hold as textures.
  # Wheel caster: capped TIGHT so a tall top-down tire only tilts to hint the roll
  # direction. Expressed in brads (AimBradsTurn=256): 16 brads ≈ 22°.
  RigCasterMaxBrads* = 16
  RigCasterSteps* = 4         ## baked caster tilt steps across ±RigCasterMaxBrads
                              ## (~5.5° per step — a tilt hint, not a smooth roll,
                              ## so coarse steps read fine; see RigLegSwingSteps
                              ## on why the pool is kept small).

var
  rigLoaded: array[Team, bool]
  rigSegImg: array[Team, array[RigSeg, Image]]
  rigHeadImg: array[Skin, array[Team, Image]]
  rigScale: array[Team, float]   ## master-frame px -> map px (body fills body px).
  # The head asset is skin-specific; all other rig segments are shared.
  # Bake cache keyed by skin and (baseStep, artStep, shortenStep, scale).
  # baseStep is the aim step (head/arms) or heading step (legs/wheels); artStep
  # is the leg swing or wheel caster; shortenStep is the leg-length index
  # (0 for non-legs).
  rigSegCache: array[Skin, array[Team, array[RigSeg, seq[tuple[
    baseStep, artStep, shortenStep, scale: int, pixels: seq[uint8]]]]]]

proc rigSegPath(seg: RigSeg): string =
  case seg
  of rsHead: "head"
  of rsArmL: "arm_l"
  of rsArmR: "arm_r"
  of rsLegFL: "leg_fl"
  of rsLegFR: "leg_fr"
  of rsLegRear: "leg_rear"
  of rsWheelL: "wheel_l"
  of rsWheelR: "wheel_r"
  of rsWheelRear: "wheel_rear"

proc rigSegIsLeg*(seg: RigSeg): bool =
  seg in {rsLegFL, rsLegFR, rsLegRear}

proc rigSegIsWheel*(seg: RigSeg): bool =
  seg in {rsWheelL, rsWheelR, rsWheelRear}

proc ensureRigLoaded(team: Team) =
  if rigLoaded[team]:
    return
  # Same display-color rule as the unified cog master: the rig segments are
  # slices of that art, so they take the identical source + re-tint decision.
  let
    spec = teamArtTint(team)
    dir = gameDir() / "data/rig_real" / teamText(spec.sourceTeam)
  for seg in RigSeg:
    rigSegImg[team][seg] = readImage(dir / rigSegPath(seg) & ".png")
    rigSegImg[team][seg].applyTeamArtTint(spec)
  rigHeadImg[DefaultSkin][team] = rigSegImg[team][rsHead]
  rigHeadImg[CrownSkin][team] = readImage(dir / "head_crown.png")
  rigHeadImg[CrownSkin][team].applyTeamArtTint(spec)
  # Scale the rig so its body matches the unified soldier footprint. The solid
  # body spans ~99px in the 192px frame (y56..154); map that to SoldierBodyPx.
  ensureSoldierLoaded(DefaultSkin, team)
  rigScale[team] = float(SoldierBodyPx) / 99.0
  rigLoaded[team] = true

proc soldierCanvasToPixels(canvas: Image): seq[uint8] =
  ## Straight-alpha RGBA (Sprite v1 protocol) from a pixie canvas.
  result = newSeq[uint8](canvas.width * canvas.height * 4)
  for i in 0 ..< canvas.width * canvas.height:
    let c = canvas.data[i].rgba()
    result[i * 4] = c.r
    result[i * 4 + 1] = c.g
    result[i * 4 + 2] = c.b
    result[i * 4 + 3] = c.a

proc rigSegPixels*(team: Team, seg: RigSeg, baseStep, artStep: int,
    shortenStep = 0, renderScale = 1, skin = DefaultSkin): seq[uint8] =
  ## One rig segment baked into a RigCanvas sprite, HUB-centered.
  ##  - baseStep: the segment's base rotation step (RigSteps) — the AIM step for
  ##    the head/arms, the movement-HEADING step for legs/wheels. This IS the
  ##    turret swivel: head/arms and legs get DIFFERENT baseSteps.
  ##  - artStep: leg differential swing (signed, RigLegSwingSteps) or wheel caster
  ##    tilt (signed, RigCasterSteps); ignored for the head.
  ##  - shortenStep: leg-length index 0..RigShortenSteps (legs only; inner-leg
  ##    shorten). 0 for everything else.
  ## Each segment rotates about its ANCHOR by baseDeg + articulation, then the HUB
  ## lands at canvas center — so at rest (all baseSteps equal, art 0) the segments
  ## recompose to the south master exactly.
  let
    b = ((baseStep mod RigSteps) + RigSteps) mod RigSteps
    art = artStep
    sh = clamp(shortenStep, 0, RigShortenSteps)
    effectiveSkin = if seg == rsHead: skin else: DefaultSkin
  for cached in rigSegCache[effectiveSkin][team][seg]:
    if cached.baseStep == b and cached.artStep == art and
        cached.shortenStep == sh and cached.scale == renderScale:
      return cached.pixels
  ensureRigLoaded(team)
  let
    outCanvas = RigCanvas * renderScale
    img =
      if seg == rsHead:
        rigHeadImg[effectiveSkin][team]
      else:
        rigSegImg[team][seg]
    s = rigScale[team] * float(renderScale)
    center = float32(outCanvas) / 2
    anchor = RigAnchor[seg]
    hub = RigHub
    # base delta: rot 0 = east; the master faces SOUTH so the −90° turn makes the
    # face lead the base direction. Angle increases CCW; screen y down → rotate −.
    baseAngle = float(b) * 2.0 * PI / float(RigSteps)
    baseDeg = -baseAngle - PI / 2.0
    # The gun mounts in PURE aim space (no −90° — the master-south turn is only for
    # the body art), like soldierRotPixels: unitRot = rotate(−aimAngle).
    unitDeg = -baseAngle
  # Articulation about the segment's own anchor (radians, screen CCW+).
  var artDeg = 0.0
  if rigSegIsLeg(seg):
    let sw = float(art) / float(RigLegSwingSteps) * RigSplayDeg  # signed swing
    case seg
    of rsLegFL:  artDeg = (-RigRestTuckDeg + sw) * PI / 180.0
    of rsLegFR:  artDeg = ( RigRestTuckDeg + sw) * PI / 180.0
    of rsLegRear: artDeg = (sw * RigRearCounterFrac) * PI / 180.0
    else: discard
  elif rigSegIsWheel(seg):
    # caster tilt: art is the signed caster step; convert to a small angle.
    let tilt = float(art) / float(RigCasterSteps) *
      (float(RigCasterMaxBrads) * 2.0 * PI / float(AimBradsTurn))
    artDeg = -tilt
  elif seg in {rsArmL, rsArmR}:
    # Arms: art 0 = tucked (rest); art 1 = REACHING forward to cradle a carried
    # heart. The reach swings each shoulder inward-and-forward about its attach so
    # the two arms close in front of the aim (where the heart rides).
    if art != 0:
      artDeg = (if seg == rsArmL: RigArmReachDeg else: -RigArmReachDeg) *
        PI / 180.0
  # Leg-length shorten: scale the leg toward its hip along the hip→foot (down)
  # axis. The leg art hangs below its hip anchor, so scaling y about the anchor
  # pulls the foot (and its wheel, placed separately) up toward the hip.
  let shortenF = 1.0 - float(sh) / float(RigShortenSteps) * RigInnerShorten
  var canvas = newImage(outCanvas, outCanvas)
  let
    toCenter = translate(vec2(center, center))
    baseRot = rotate(float32(baseDeg))
    scl = scale(vec2(float32(s), float32(s)))
    hubToOrigin = translate(vec2(float32(-hub.x), float32(-hub.y)))
    artMat =
      translate(vec2(float32(anchor.x), float32(anchor.y))) *
      rotate(float32(artDeg)) *
      scale(vec2(1.0'f32, float32(shortenF))) *
      translate(vec2(float32(-anchor.x), float32(-anchor.y)))
    mat = toCenter * baseRot * scl * hubToOrigin * artMat
  # NB: the held gun is NO LONGER baked into the head — it is its own board object
  # (rigGunPixels), drawn ABOVE the head with a backlight glow so it reads clearly
  # and can be gated off if a cog is ever disarmed. The head is a clean turret.
  canvas.draw(img, mat)
  let pixels = soldierCanvasToPixels(canvas)
  rigSegCache[effectiveSkin][team][seg].add(
    (baseStep: b, artStep: art, shortenStep: sh, scale: renderScale,
     pixels: pixels))
  pixels

## --- Metallic clearcoat: the league #1's cog is made of a different MATERIAL ---
## The mark for the #1-ranked policy (src/ctf/shimmer.nim, docs/COLOR_CONTRACT.md
## §5) is not a decal laid over the cog — it is a re-bake of the cog's own shell
## art through a metallic-paint transform. Everything below is BROADCAST-ONLY and
## purely a function of (team, skin, aim step, phase), so every viewer of a replay
## bakes byte-identical pixels.
##
## WHY A RE-BAKE AND NOT AN OVERLAY. The eye reads "metal" from ONE cue above all
## others: the highlight moves when the object turns. A composited sprite cannot
## have that property — it slides across the cog like a sticker. The cog art is
## already baked per AIM STEP (RigSteps = 16), so a material evaluated inside the
## bake gets orientation coupling for free: the shell's facets are anchored in the
## cog's OWN frame, the light is anchored in the WORLD, and turning the cog sweeps
## the specular from one facet to the next. The overlay could never do that
## without 16x its sprites, which is exactly the trade the old build declined.
##
## THE FIVE LAYERS, and what each one is doing for the read:
##
##  1. BASE COAT — a gamma curve on LUMINANCE with the channel ratios held fixed.
##     Automotive paint is not brighter than matte plastic, it is DEEPER: darker
##     darks under a hot specular. Scaling all three channels by one factor moves
##     luminance and leaves HSV hue and saturation mathematically untouched, so
##     the whole contrast half of this effect costs the team-colour budget exactly
##     nothing. (The two rejected builds both spent their budget raising pixels
##     toward white, which is the one operation that DOES destroy hue.)
##  2. CHROME HORIZON — the body shade, QUANTIZED into `bands` hard tone steps by
##     a fixed world light. A polished ball outdoors reflects bright sky over its
##     upper half and dark ground under it across a hard edge; a matte one has a
##     smooth cosine ramp. At the size a cog actually occupies — a ~10 screen px
##     head, a third of which is the visor — the smooth ramp box-filters into one
##     flat mid-tone and the hard steps do not, so this layer is where most of the
##     metallic read actually comes from. Also multiplicative, also colour-free.
##  3. CANDY COAT — extra saturation on the lit half. A metallic finish's lit side
##     is a RICHER version of the colour, not a paler one, so this layer ADDS to
##     the team-colour budget and pays for the achromatic pixels below.
##  4. THE SPECULAR — one small, near-opaque, achromatic spot, and it moves for
##     TWO reasons at once. Its home is the chamfer flat currently turned toward
##     the light: the flats are fixed in OBJECT space (CogMetalFacets of them), so
##     turning the cog makes the spot JUMP from flat to flat and the whole shell
##     WINK as the alignment passes through cos(22.5°) between them — that is the
##     orientation cue, and it is the one a composited decal structurally cannot
##     have. On top of that it slides across the flat over the glint cycle, so a
##     cog holding one angle still shimmers. ONE spot rather than a fixed specular
##     plus an orbiting glint: two white features were built first and measured,
##     and they cost twice the shell area for the same read — area is the entire
##     team-colour budget.
##  5. FRESNEL EDGE — bright where the shell turns away from the viewer on the lit
##     side, dark on the shaded side. A polished edge catches light all the way
##     round; a matte one does not.
##
## Layers 1-3 are colour-safe by construction; only 4-5 spend achromatic white,
## and they are deliberately the compact ones (tools/shimmer_legibility.nim
## `shellKeep`). Flake sparkle is deliberately ABSENT: a flake grain is ~1 map px
## and the viewer averages ~4x4 emitted px into one screen px, so flake is a
## zoomed-in-only feature that costs saturation and buys nothing on screen. The
## same measurement is why the specular is as LARGE as it is — a genuinely tight
## specular is under one screen pixel and the box filter erases it outright.
const
  CogMetalShellPx* = 11.0     ## radius, in MAP px, of the modelled shell — the
                              ## head cube's own footprint (18x16 map px, ~18x18
                              ## at 45 degrees). The material is masked by the
                              ## art's alpha as well, so unlike the old overlay
                              ## disc nothing can spill onto the floor; this
                              ## number only sets where "rim" is.
  CogMetalFacets* = 8         ## chamfered-cube flats around the shell. 8 over 16
                              ## aim steps means the hot flat changes every 2
                              ## steps — often enough that a turning cog visibly
                              ## sweeps, coarse enough that each flat is a ~45
                              ## degree wedge and survives the downsample.
  CogMetalSweepFrames* = 6    ## baked glint positions per cycle. Small ON PURPOSE
                              ## now that rotation carries most of the motion:
                              ## every extra frame multiplies a 4-team pool of
                              ## RigCanvas bakes, and 6 positions around a circle
                              ## is one hot arc-width per step.
  CogMetalLightX = -0.5145    ## fixed WORLD light, upper-left (screen y is down).
  CogMetalLightY = -0.8575    ## The world anchor is half of the rotation cue: the
                              ## facets turn, the light does not.

type CogMetalTune = object
  ## Every shaping number of the material in one record so the dev tuner
  ## (-d:metalTune) can sweep them without a recompile per value.
  gamma: float        ## luminance curve; > 1 deepens the darks.
  shadeLo, shadeHi: float  ## body-shade multiplier away from / toward the light.
  bands: float        ## number of QUANTIZED tone steps the body shade is snapped
                      ## to. At the size a cog actually occupies (~10 screen px
                      ## of shell, of which the visor eats a third) a continuous
                      ## ramp box-filters into one flat mid-tone; hard steps are
                      ## how pixel art has always drawn chrome, and they are the
                      ## only form of contrast that survives the downsample.
  horizon: float      ## HALF-WIDTH of the light/dark transition, in units of the
                      ## `lit` term. Small = a hard chrome horizon, large = a
                      ## soft diffuse ramp. This one number is the difference
                      ## between "polished" and "in shadow" at 10 screen px.
  chromaLit: float    ## extra SATURATION on the lit half. Metallic paint's lit
                      ## side is a deeper, candy-richer version of the colour,
                      ## not a paler one — so this layer BUYS team colour back
                      ## instead of spending it.
  rimPx: float        ## fresnel width, in MAP px, measured in from the silhouette.
  rimBright: float    ## additive white alpha on the lit edge.
  rimDark: float      ## multiplicative darkening on the shaded edge.
  facetGain: float    ## additive white alpha of the lit facet wedge.
  facetPow: float     ## facet lobe exponent; higher = tighter, harder wink.
  facetFloor: float   ## how much of the facet term survives off the hot flat.
  hotGain: float      ## the blown highlight: the ONE achromatic spot.
  hotR: float         ## its centre, in shell radii from the hub.
  hotSigma: float     ## its gaussian radius, in shell radii. SMALL by contract.
  travelArc: float    ## radians the spot slides across the lit side over one
                      ## glint cycle. This is the TIME half of the motion; the
                      ## facet jump is the ORIENTATION half, and they share one
                      ## spot so the whole animation costs one white footprint
                      ## instead of two.
  travelR: float      ## how far the spot also drifts outward over that cycle.
  annLo, annHi: float ## shell radii (0..1) the facet wedge lives between.

const DefaultCogMetalTune = CogMetalTune(
  gamma: 1.45, shadeLo: 0.30, shadeHi: 1.55, bands: 4.0, horizon: 0.50,
  chromaLit: 0.95,
  rimPx: 2.4, rimBright: 0.28, rimDark: 0.55,
  facetGain: 0.12, facetPow: 7.0, facetFloor: 0.04,
  hotGain: 1.00, hotR: 0.50, hotSigma: 0.38,
  travelArc: 1.75, travelR: 0.22,
  annLo: 0.22, annHi: 1.20)

when defined(metalTune):
  import std/envvars
  proc envF(name: string, fallback: float): float =
    let v = getEnv("METAL_" & name)
    if v.len == 0: fallback else: parseFloat(v)
  proc cogMetalTune(): CogMetalTune =
    let d = DefaultCogMetalTune
    CogMetalTune(
      gamma: envF("GAMMA", d.gamma),
      shadeLo: envF("SHADELO", d.shadeLo), shadeHi: envF("SHADEHI", d.shadeHi),
      bands: envF("BANDS", d.bands), horizon: envF("HORIZON", d.horizon),
      chromaLit: envF("CHROMALIT", d.chromaLit),
      rimPx: envF("RIMPX", d.rimPx), rimBright: envF("RIMBRIGHT", d.rimBright),
      rimDark: envF("RIMDARK", d.rimDark),
      facetGain: envF("FACETGAIN", d.facetGain),
      facetPow: envF("FACETPOW", d.facetPow),
      facetFloor: envF("FACETFLOOR", d.facetFloor),
      hotGain: envF("HOTGAIN", d.hotGain), hotR: envF("HOTR", d.hotR),
      hotSigma: envF("HOTSIGMA", d.hotSigma),
      travelArc: envF("TRAVELARC", d.travelArc),
      travelR: envF("TRAVELR", d.travelR),
      annLo: envF("ANNLO", d.annLo), annHi: envF("ANNHI", d.annHi))
else:
  proc cogMetalTune(): CogMetalTune = DefaultCogMetalTune

proc metalSmoothstep(e0, e1, x: float): float {.inline.} =
  ## Hermite ramp. The material is built out of soft-edged REGIONS rather than
  ## thin gaussians because a region survives the viewer's box filter (one screen
  ## pixel is the average of ~4x4 emitted pixels) and a thin feature does not.
  if e1 <= e0: return (if x >= e1: 1.0 else: 0.0)
  let t = clamp((x - e0) / (e1 - e0), 0.0, 1.0)
  t * t * (3.0 - 2.0 * t)

proc alphaEdgeDistance(pixels: openArray[uint8], side: int): seq[float32] =
  ## Chamfer (3,4)-style distance transform: px from each opaque pixel to the
  ## nearest transparent one. This is what makes the fresnel edge follow the
  ## ART's real silhouette — including the cut corners of the head cube as it
  ## rotates — instead of an idealized circle that would light up empty canvas.
  const Big = 1.0e9'f32
  result = newSeq[float32](side * side)
  for i in 0 ..< side * side:
    result[i] = if pixels[i * 4 + 3] >= 96'u8: Big else: 0.0'f32
  for y in 0 ..< side:
    for x in 0 ..< side:
      let i = y * side + x
      if result[i] == 0.0'f32: continue
      var m = result[i]
      if x > 0: m = min(m, result[i - 1] + 1.0'f32)
      if y > 0: m = min(m, result[i - side] + 1.0'f32)
      if x > 0 and y > 0: m = min(m, result[i - side - 1] + 1.41421'f32)
      if x < side - 1 and y > 0: m = min(m, result[i - side + 1] + 1.41421'f32)
      result[i] = m
  for y in countdown(side - 1, 0):
    for x in countdown(side - 1, 0):
      let i = y * side + x
      if result[i] == 0.0'f32: continue
      var m = result[i]
      if x < side - 1: m = min(m, result[i + 1] + 1.0'f32)
      if y < side - 1: m = min(m, result[i + side] + 1.0'f32)
      if x < side - 1 and y < side - 1:
        m = min(m, result[i + side + 1] + 1.41421'f32)
      if x > 0 and y < side - 1: m = min(m, result[i + side - 1] + 1.41421'f32)
      result[i] = m

proc applyCogMetal*(pixels: var seq[uint8], side, renderScale,
                    aimStep, phase: int) =
  ## Re-paints one already-baked, hub-centered rig segment in metallic clearcoat,
  ## in place. `aimStep` is the segment's baked aim step (0..RigSteps-1) — the
  ## object frame the facets are anchored in — and `phase` is the glint position
  ## (0..CogMetalSweepFrames-1). Alpha is never touched: the material can only
  ## darken, brighten or tint pixels the cog art already owns, so the silhouette
  ## a label scanner sees is bit-identical to the stock bake.
  let
    t = cogMetalTune()
    dist = alphaEdgeDistance(pixels, side)
    scale = float(renderScale)
    c = float(side - 1) / 2.0
    r = CogMetalShellPx * scale
    rimPx = t.rimPx * scale
    # Aim azimuth in CANVAS space. rigSegPixels rotates the art by
    # -baseAngle - PI/2 and screen y is down, so the cog's forward direction sits
    # at canvas azimuth -baseAngle; the object frame is the canvas frame turned
    # by that much.
    aimAz = -float(((aimStep mod RigSteps) + RigSteps) mod RigSteps) *
      2.0 * PI / float(RigSteps)
    lightAz = arctan2(CogMetalLightY, CogMetalLightX)
    facetArc = 2.0 * PI / float(CogMetalFacets)
    # THE ORIENTATION CUE, in three lines. `hotFacet` is the chamfer flat whose
    # OBJECT-space normal currently points nearest the world light; `hotAz` is
    # where that flat sits on screen once the cog is turned. Because the flats
    # are quantized, turning the cog makes the blown highlight JUMP from one flat
    # to the next (every two aim steps, at 8 flats over 16 steps) rather than
    # crawl — and `hotAlign` falls to cos(22.5 deg) in between, so the cog also
    # WINKS as it turns. Both are things only a surface does; a decal cannot.
    hotFacet = floor((lightAz - aimAz) / facetArc + 0.5)
    hotAz = hotFacet * facetArc + aimAz
    hotAlign = max(0.0, cos(hotAz - lightAz))
    # THE TIME CUE, riding the SAME spot. The glint slides across the lit flat
    # over one cycle and drifts outward as it goes, so a cog holding one angle
    # still visibly shimmers. Two separate white features (a fixed specular plus
    # an orbiting glint) were built first and measured: they cost twice the shell
    # area, and area is the entire team-colour budget — so the two motions share
    # one spot instead.
    travel = float(phase) / float(CogMetalSweepFrames) - 0.5
    spotAz = hotAz + t.travelArc * travel
    spotR = t.hotR + t.travelR * travel
    hotX = spotR * cos(spotAz)
    hotY = spotR * sin(spotAz)
  for y in 0 ..< side:
    for x in 0 ..< side:
      let i = y * side + x
      if pixels[i * 4 + 3] == 0'u8:
        continue
      let
        dx = (float(x) - c) / r
        dy = (float(y) - c) / r
        u = sqrt(dx * dx + dy * dy)
        lit = if u > 1.0e-6: (dx * CogMetalLightX + dy * CogMetalLightY) /
                max(u, 1.0e-6) * min(u, 1.0)
              else: 0.0
        phiCanvas = arctan2(dy, dx)
        phiObj = phiCanvas - aimAz
        # Which chamfer flat this pixel belongs to, in the cog's OWN frame, and
        # where that flat's normal points in the WORLD once the cog is turned.
        facetIdx = floor(phiObj / facetArc + 0.5)
        facetWorld = facetIdx * facetArc + aimAz
        lobe = max(0.0, cos(facetWorld - lightAz))
        facet = t.facetFloor + (1.0 - t.facetFloor) * pow(lobe, t.facetPow)
        # The specular layers live in a CHUNKY outer band, not a hairline ring:
        # at true viewer zoom the shell is ~10 screen px across, so a window
        # narrower than a quarter of the radius is box-filtered into nothing.
        ann = metalSmoothstep(t.annLo, t.annLo + 0.30, u) *
          (1.0 - metalSmoothstep(t.annHi - 0.35, t.annHi, u))
        edge = float(dist[i]) / max(rimPx, 1.0e-6)
        rim = 1.0 - metalSmoothstep(0.0, 1.0, edge)
        hotD2 = (dx - hotX) * (dx - hotX) + (dy - hotY) * (dy - hotY)
        # A hard-edged DISC, not a gaussian falloff: a soft blob averages down
        # into a haze over the cog (the two rejected builds both looked like
        # fog); a disc with a one-pixel edge averages down into a bright pixel,
        # which is what a specular is.
        spot = 1.0 -
          metalSmoothstep(t.hotSigma * 0.55, t.hotSigma, sqrt(hotD2))
      var
        cr = float(pixels[i * 4]) / 255.0
        cg = float(pixels[i * 4 + 1]) / 255.0
        cb = float(pixels[i * 4 + 2]) / 255.0
      # 1+2. BASE COAT and BODY SHADE, as ONE luminance scale. Multiplying all
      # three channels by a single factor is an exact no-op on HSV hue and
      # saturation, so the contrast that does most of the metallic work here is
      # free on the color axis the shimmer feature is forbidden to spend.
      let
        lum = 0.2126 * cr + 0.7152 * cg + 0.0722 * cb
        # THE CHROME HORIZON. A polished ball outdoors reflects bright sky over
        # its upper half and dark ground under it, split by a HARD edge; that
        # split is the single most recognizable "this is metal" silhouette there
        # is, and unlike a specular dot it survives being averaged down to ten
        # screen pixels. A soft cosine ramp in its place reads as a matte ball
        # sitting in shadow — which is exactly how the first pass measured.
        shadeRaw = metalSmoothstep(-t.horizon, t.horizon, lit)
        # QUANTIZE. `bands` hard tone steps instead of a continuous ramp: a
        # stepped surface reads as polished, a smooth one reads as matte, and at
        # this footprint the smooth one does not read at all.
        shadeT = if t.bands >= 2.0:
            min(floor(shadeRaw * t.bands), t.bands - 1.0) / (t.bands - 1.0)
          else: shadeRaw
        shade = t.shadeLo + (t.shadeHi - t.shadeLo) * shadeT
        darken = t.rimDark * rim * metalSmoothstep(-0.15, 0.55, -lit)
      if lum > 1.0e-4:
        let
          want = pow(lum, t.gamma) * shade * (1.0 - darken)
          mx = max(cr, max(cg, cb))
          # Cap the scale so no channel clips: a clipped channel silently
          # desaturates, which is the failure mode this whole feature exists to
          # avoid, and it would do it worst on the brightest palette slugs.
          s = min(want / lum, if mx > 1.0e-4: 1.0 / mx else: 1.0)
        cr *= s; cg *= s; cb *= s
      # 2b. CANDY COAT. A metallic finish's lit side is a RICHER version of the
      # base colour, so the lit half gets its chroma pushed AWAY from its own
      # luminance. Hue is untouched (every channel moves along the same axis
      # through the grey point) and HSV saturation goes UP, so this is the one
      # layer of the material that adds to the `shellKeep` budget rather than
      # spending it — which is what pays for the achromatic pip below.
      if t.chromaLit > 0.0:
        let
          lum2 = 0.2126 * cr + 0.7152 * cg + 0.0722 * cb
          mx2 = max(cr, max(cg, cb))
          wantK = 1.0 + t.chromaLit * shadeT
          # Cap so the brightest channel still lands under 1.0: a clipped channel
          # silently DESATURATES, undoing the very thing this layer is for.
          k = if mx2 - lum2 > 1.0e-4: min(wantK, (1.0 - lum2) / (mx2 - lum2))
              else: wantK
        cr = lum2 + (cr - lum2) * k
        cg = lum2 + (cg - lum2) * k
        cb = lum2 + (cb - lum2) * k
        cr = max(cr, 0.0); cg = max(cg, 0.0); cb = max(cb, 0.0)
      # 3-5. The achromatic layers, straight-alpha "over" onto the base coat.
      # These are the only pixels the material spends on white, which is why each
      # one is compact: peak luminance is won by a handful of pixels, team
      # identity is lost by many.
      template white(a: float) =
        let sa = clamp(a, 0.0, 1.0)
        if sa > 0.0:
          cr += (1.0 - cr) * sa
          cg += (1.0 - cg) * sa
          cb += (1.0 - cb) * sa
      # The lit facet WEDGE: a moderate brightening of the flat currently turned
      # toward the light, so the shell has a lit side and a dark side that swap
      # as the cog turns. Deliberately modest — this layer covers area, and area
      # is what costs team colour.
      white(t.facetGain * facet * ann)
      # The BLOWN HIGHLIGHT: small, near-opaque, sitting on the hot flat. It owns
      # the top of the luminance distribution, which is what lets the flagged cog
      # out-read its stock teammate's own brightest art (a citrine-yellow cog
      # leaves only ~64 luma of headroom, so the peak has to be nearly white),
      # and it is small precisely so it can afford to be that bright: peak
      # luminance is won by a handful of pixels, team identity is lost by many.
      white(t.hotGain * hotAlign * spot)
      white(t.rimBright * rim * metalSmoothstep(-0.05, 0.65, lit))
      pixels[i * 4] = uint8(clamp(cr, 0.0, 1.0) * 255.0)
      pixels[i * 4 + 1] = uint8(clamp(cg, 0.0, 1.0) * 255.0)
      pixels[i * 4 + 2] = uint8(clamp(cb, 0.0, 1.0) * 255.0)

const
  CogMetalTicksPerFrame* = 8  ## 48 ticks = 2s per glint lap at 24 ticks/s. Slow
                              ## on purpose: the brief is a sheen, not a strobe,
                              ## and the ROTATION cue already fires every time the
                              ## cog turns two aim steps, which in a real match is
                              ## most of the time.
  CogMetalSeatStride* = 5     ## per-seat phase offset in frames. Coprime with
                              ## CogMetalSweepFrames so consecutive seats of one
                              ## policy land on distinct phases — a squad glinting
                              ## in unison reads as a UI blink, not as light on a
                              ## surface.
  RigMetalSegSpriteBase* = 80000
    ## Logical KEY base for the metallic segment pool (not a wire id — the
    ## caller remaps through the dense dynamic window like every other rig
    ## pose). Sits above the rig pose key space (40000..76663) and far below the
    ## debug namespace at 1_000_000. Width: seg(2) x skin(2) x team(4) x
    ## aim(16) x phase(CogMetalSweepFrames) = 1536 keys, of which a real episode
    ## touches only the flagged policy's own team.

proc cogMetalPhase*(tick, seat: int): int =
  ## The glint phase one seat shows at one tick. A pure function of tickCount
  ## (plus a per-seat offset), like the diamond spin — so every viewer, live or
  ## replayed, at any scrub position, agrees without any animation state to sync.
  ((tick div CogMetalTicksPerFrame) + seat * CogMetalSeatStride) mod
    CogMetalSweepFrames

proc rigMetalSegSpriteKey*(team: Team, seg: RigSeg, skin: Skin,
    aimStep, phase: int): int =
  ## Logical sprite key for one baked metallic segment. Only the three
  ## AIM-tracking segments can be metal (head, armL, armR — the shell panels);
  ## the legs and wheels are struts and rubber and stay stock, which is both
  ## right for the material and what keeps this pool small.
  let segIdx = case seg
    of rsHead: 0
    of rsArmL: 1
    else: 2
  RigMetalSegSpriteBase +
    (((segIdx * 2 + ord(skin)) * 4 + ord(team)) * RigSteps + aimStep) *
      CogMetalSweepFrames + phase

var rigMetalCache: array[Skin, array[Team, array[RigSeg, seq[tuple[
  aimStep, phase, scale: int, pixels: seq[uint8]]]]]]

proc rigMetalSegPixels*(team: Team, seg: RigSeg, aimStep, phase: int,
    renderScale = 1, skin = DefaultSkin): seq[uint8] =
  ## The metallic variant of one AIM-tracking rig segment (head, arms): the exact
  ## stock bake, re-painted through `applyCogMetal`. Cached in its own pool so
  ## the stock path — every cog in every episode that has no flagged policy on the
  ## board, which is most of them — is untouched and pays nothing.
  let
    a = ((aimStep mod RigSteps) + RigSteps) mod RigSteps
    p = ((phase mod CogMetalSweepFrames) + CogMetalSweepFrames) mod
      CogMetalSweepFrames
    effectiveSkin = if seg == rsHead: skin else: DefaultSkin
  for cached in rigMetalCache[effectiveSkin][team][seg]:
    if cached.aimStep == a and cached.phase == p and cached.scale == renderScale:
      return cached.pixels
  var pixels = rigSegPixels(team, seg, a, 0, 0, renderScale, skin)
  applyCogMetal(pixels, RigCanvas * renderScale, renderScale, a, p)
  rigMetalCache[effectiveSkin][team][seg].add(
    (aimStep: a, phase: p, scale: renderScale, pixels: pixels))
  pixels

var rigGunCache: array[Team, seq[tuple[aimStep, scale: int, pixels: seq[uint8]]]]

proc rigHeldWeaponPixels(
  cache: var array[Team, seq[tuple[aimStep, scale: int, pixels: seq[uint8]]]],
  team: Team,
  aimStep, renderScale: int,
  master: Image,
  masterScale: float,
  gripPx: int
): seq[uint8] =
  ## Shared held-weapon compositor for the gun and the spray can: the weapon
  ## as its own HUB-centered rig object, mounted at the cog's RIGHT
  ## (GunRightPx off the aim ray, gripPx along aim) with its business end on
  ## +aim, and a warm backlight glow composited BEHIND it so the dark weapon
  ## pops off the dark floor/legs. Cached per team/aim-step/scale.
  let a = ((aimStep mod RigSteps) + RigSteps) mod RigSteps
  for cached in cache[team]:
    if cached.aimStep == a and cached.scale == renderScale:
      return cached.pixels
  let
    outCanvas = RigCanvas * renderScale
    center = float32(outCanvas) / 2
    baseAngle = float(a) * 2.0 * PI / float(RigSteps)
    unitDeg = -baseAngle                 # pure aim space (muzzle/nozzle on +aim)
    ws = masterScale * float(renderScale)
    mat =
      translate(vec2(center, center)) * rotate(float32(unitDeg)) *
      translate(vec2(
        float32(gripPx * renderScale), float32(GunRightPx * renderScale))) *
      scale(vec2(float32(ws), float32(ws))) *
      translate(vec2(0'f32, float32(-master.height) / 2))
  # 1) lay the weapon on a transparent canvas, 2) build a warm-amber backlight
  # from its silhouette (spread + blur), 3) draw glow THEN weapon.
  var weaponLayer = newImage(outCanvas, outCanvas)
  weaponLayer.draw(master, mat)
  let glow = weaponLayer.shadow(
    offset = vec2(0, 0),
    spread = float32(GunGlowSpread * float(renderScale)),
    blur = float32(GunGlowRadius * float(renderScale)),
    color = rgba(255, 214, 138, GunGlowAlpha).color)  # faint warm rim light
  var canvas = newImage(outCanvas, outCanvas)
  canvas.draw(glow)                      # subtle warm edge behind the weapon
  canvas.draw(weaponLayer)
  let pixels = soldierCanvasToPixels(canvas)
  cache[team].add((aimStep: a, scale: renderScale, pixels: pixels))
  pixels

proc rigGunPixels*(team: Team, aimStep: int, renderScale = 1): seq[uint8] =
  ## The held top-down paintball MARKER as its OWN HUB-centered rig object (not
  ## baked into the head): mounted at the cog's RIGHT (GunRightPx off the aim ray,
  ## stock GunGripPx along aim), barrel on +aim so tracers line up. A soft warm
  ## backlight glow is composited BEHIND the marker so the dark gun pops off the
  ## dark floor/legs. Team-independent shape, but cached per team for symmetry with
  ## the other rig segments. Emitted ABOVE the head z; gate the caller on a
  ## `hasGun` flag to hide it when a cog is disarmed.
  ensureGunLoaded()
  rigHeldWeaponPixels(
    rigGunCache, team, aimStep, renderScale, gunMaster, gunScale, GunGripPx)

var rigSprayCache: array[Team, seq[tuple[aimStep, scale: int, pixels: seq[uint8]]]]

proc rigSprayCanPixels*(team: Team, aimStep: int, renderScale = 1): seq[uint8] =
  ## The held SPRAY CAN, the swap-in for rigGunPixels while a cog carries one:
  ## same grip (the cog's RIGHT, GunRightPx off the aim ray) and the same
  ## nozzle-on-+aim convention, so the spray cone leaves the nozzle exactly where
  ## tracers leave the muzzle. Mounted SprayHeldGripPx along aim and scaled to
  ## SprayHeldLengthPx: a can is a short fistful, so its silhouette reads clearly
  ## different from the long marker — that difference is how a viewer tells which
  ## weapon a cog is holding.
  ensureSprayLoaded()
  rigHeldWeaponPixels(
    rigSprayCache, team, aimStep, renderScale, sprayMaster, sprayScale,
    SprayHeldGripPx)

proc soldierIconPixels*(team: Team, sizePx: int): seq[uint8] =
  ## A compact roster chip: the face-on cog scaled so the body fills the icon
  ## (no gun — the smile visor IS the identity). Used by the game-over list.
  ensureSoldierLoaded(DefaultSkin, team)
  let
    master = soldierMasters[DefaultSkin][team]
    s =
      float(sizePx) / float(SoldierBodyPx) *
        soldierScale[DefaultSkin][team]
  var canvas = newImage(sizePx, sizePx)
  let mat =
    translate(vec2(float32(sizePx) / 2, float32(sizePx) / 2)) *
    scale(vec2(float32(s), float32(s))) *
    translate(vec2(
      float32(-soldierPivotX[DefaultSkin][team]),
      float32(-soldierPivotY[DefaultSkin][team])
    ))
  canvas.draw(master, mat)
  result = newSeq[uint8](sizePx * sizePx * 4)
  for i in 0 ..< sizePx * sizePx:
    let c = canvas.data[i].rgba()
    result[i * 4] = c.r
    result[i * 4 + 1] = c.g
    result[i * 4 + 2] = c.b
    result[i * 4 + 3] = c.a


## --- Cog driving physics: how the segmented trike steers/turns (broadcast-only) ---
## Ports the Maxwell-approved CogDriveState model (from maxwell/cog-base-turret-
## split): the body heading eases slowly toward travel; each wheel casters toward
## its foot's travel direction near-instantly (so tyres never scrape); the leg
## splay follows a smoothed turn signal. Everything derives from the already-known
## velocity, so it stays broadcast-only and replay-deterministic.
const
  CogBodyTurnRate* = 28       ## max brads/frame the body heading eases toward the
                              ## travel direction — the base is a TRUE TANK track
                              ## that snaps to where it rolls (fast + accurate),
                              ## fully independent of the head/aim.
  CogWheelTurnRate* = 48      ## brads/frame a wheel casters toward travel (even
                              ## faster than the base, so tyres never scrape).
  CogReverseMaxBrads* = 112   ## |heading-travel| beyond this (~158°) = reversing;
                              ## below it the base just turns to face travel.
  CogReverseCommitFrames* = 8   ## backward frames before committing to a U-turn.
  CogMoveMinSpeed* = StopThreshold
  CogTurnFullBrads* = 6       ## heading angular velocity mapped to full splay.
  CogTurnAmtEase* = 200       ## turnAmt eases toward target this many milli/frame.

type
  CogDriveState* = object
    ## Per-player broadcast animation state for the segmented trike. NOT in the
    ## sim / gameHash — lives in the viewer state, evolved once per frame.
    initialized*: bool
    bodyHeading*: int          ## brads the chassis currently faces.
    reverseFrames*: int        ## consecutive backward frames (commit counter).
    turnAmt*: int              ## signed steer signal, -1000..1000 (x1000). + = left.
    casterFL*, casterFR*, casterRear*: int  ## brads each wheel points.

proc bradDiff*(a, b: int): int =
  ## Shortest signed difference a-b wrapped to (-128, 128] brads.
  var d = ((a - b) mod AimBradsTurn + AimBradsTurn) mod AimBradsTurn
  if d > AimBradsTurn div 2:
    d -= AimBradsTurn
  d

proc easeBrads*(cur, target, maxStep: int): int =
  ## Steps `cur` toward `target` by at most `maxStep` brads along the shortest
  ## arc, wrapping into 0..AimBradsTurn-1.
  let d = bradDiff(target, cur)
  let step = clamp(d, -maxStep, maxStep)
  ((cur + step) mod AimBradsTurn + AimBradsTurn) mod AimBradsTurn

proc initCogDriveState*(aimBrads: int): CogDriveState =
  ## A freshly-spawned cog faces where it aims, wheels aligned, not reversing,
  ## legs at rest. Reset on any scrub/respawn so a jump never inherits a stale pose.
  CogDriveState(initialized: true, bodyHeading: aimBrads, reverseFrames: 0,
    turnAmt: 0, casterFL: aimBrads, casterFR: aimBrads, casterRear: aimBrads)

proc stepCogDrive*(state: CogDriveState, velX, velY, aimBrads: int):
    CogDriveState =
  ## Advances the trike's driving animation ONE frame from the current velocity.
  ## Deterministic: same (state, vel, aim) always yields the same next state.
  if not state.initialized:
    return initCogDriveState(aimBrads)
  result = state
  let speed = abs(velX) + abs(velY)
  if speed < CogMoveMinSpeed:
    # Parked: hold heading, coast every caster back to the heading, relax legs.
    result.reverseFrames = max(0, state.reverseFrames - 1)
    result.turnAmt = state.turnAmt -
      clamp(state.turnAmt, -CogTurnAmtEase, CogTurnAmtEase)
    result.casterFL = easeBrads(state.casterFL, state.bodyHeading, CogWheelTurnRate)
    result.casterFR = easeBrads(state.casterFR, state.bodyHeading, CogWheelTurnRate)
    result.casterRear = easeBrads(state.casterRear, state.bodyHeading, CogWheelTurnRate)
    return
  let
    travel = bradsOfVector(velX, velY)
    offBody = bradDiff(travel, state.bodyHeading).abs
    goingBackward = offBody > CogReverseMaxBrads
  if goingBackward:
    result.reverseFrames = min(state.reverseFrames + 1, CogReverseCommitFrames * 2)
  else:
    result.reverseFrames = max(0, state.reverseFrames - 2)
  let committed = result.reverseFrames >= CogReverseCommitFrames
  let headingTarget =
    if goingBackward and not committed: state.bodyHeading
    else: travel
  # The base snaps toward travel at a FLAT fast rate (a tank track grips and
  # turns hard) — no speed penalty, so a direction change is tracked promptly and
  # accurately instead of lagging a quarter-second behind.
  result.bodyHeading = easeBrads(state.bodyHeading, headingTarget, CogBodyTurnRate)
  # turnAmt: smoothed signed heading angular velocity / CogTurnFull, ×1000.
  let w = bradDiff(result.bodyHeading, state.bodyHeading)
  let tInst = clamp(w * 1000 div max(1, CogTurnFullBrads), -1000, 1000)
  let smoothed = (state.turnAmt * 7 + tInst * 3) div 10
  result.turnAmt = state.turnAmt +
    clamp(smoothed - state.turnAmt, -CogTurnAmtEase, CogTurnAmtEase)
  # Each wheel casters toward the travel direction (with a small turn lean so the
  # wheels visibly lead the arc). Rear leans opposite (pivot foot).
  let lean = clamp(result.turnAmt * (AimBradsTurn div 8) div 1000,
    -(AimBradsTurn div 8), AimBradsTurn div 8)
  result.casterFL = easeBrads(state.casterFL, travel + lean, CogWheelTurnRate)
  result.casterFR = easeBrads(state.casterFR, travel + lean, CogWheelTurnRate)
  result.casterRear = easeBrads(state.casterRear, travel - lean, CogWheelTurnRate)

proc rigHeadingStep*(headingBrads: int): int =
  ## The base rotation step for the movement-facing legs/wheels (quantized to
  ## RigSteps). Same quantization as soldierRotIndex, on the body heading.
  soldierRotIndex(headingBrads)

proc rigLegSwingStep*(seg: RigSeg, turnAmt: int): int =
  ## SIGNED leg swing step (−RigLegSwingSteps..RigLegSwingSteps) from the turn
  ## signal (turnAmt ×1000, + = LEFT/CCW). Both front legs swing together with the
  ## turn (the outer leg widens, the inner one is SHORTENED separately); the rear
  ## counter-swings. Non-leg segments return 0.
  let t = clamp(turnAmt, -1000, 1000)
  if rigSegIsLeg(seg):
    int(round(float(t) / 1000.0 * float(RigLegSwingSteps)))
  else: 0

proc rigLegShortenStep*(seg: RigSeg, turnAmt: int): int =
  ## Leg-length shorten step (0..RigShortenSteps) for the INNER leg of the turn.
  ## +turnAmt = LEFT/CCW ⇒ the LEFT (inner) front leg shortens; −turnAmt ⇒ RIGHT.
  let t = clamp(turnAmt, -1000, 1000)
  case seg
  of rsLegFL:  int(round(float(max(0, t)) / 1000.0 * float(RigShortenSteps)))
  of rsLegFR:  int(round(float(max(0, -t)) / 1000.0 * float(RigShortenSteps)))
  else: 0

proc rigCasterStep*(casterBrads, headingBrads: int): int =
  ## SIGNED wheel caster tilt step (−RigCasterSteps..RigCasterSteps): the caster
  ## direction relative to the base HEADING (the wheel is baked rotated by the
  ## heading, so its extra tilt is caster − heading), clamped to ±RigCasterMaxBrads
  ## so a tall top-down tire only tilts to hint the turn.
  let capped = clamp(bradDiff(casterBrads, headingBrads),
    -RigCasterMaxBrads, RigCasterMaxBrads)
  int(round(float(capped) / float(RigCasterMaxBrads) * float(RigCasterSteps)))

const RigBaseMaxDivergeBrads* = 14  ## ~20°: the leg base only LEANS a little toward
                                    ## the movement heading — it never swings far
                                    ## sideways (the spidery look). The HEAD still
                                    ## aims freely for the full turret swivel.

proc clampBaseHeading*(headingBrads, aimBrads: int): int =
  ## Clamps the leg-base heading to within ±RigBaseMaxDivergeBrads of the aim, so
  ## the base only LEANS into a strafe/turn while the head swivels freely. Returns
  ## a wrapped 0..AimBradsTurn-1 heading.
  let d = clamp(bradDiff(headingBrads, aimBrads),
    -RigBaseMaxDivergeBrads, RigBaseMaxDivergeBrads)
  ((aimBrads + d) mod AimBradsTurn + AimBradsTurn) mod AimBradsTurn

