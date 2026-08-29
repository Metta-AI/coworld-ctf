## BR base ranges (Maxwell directive, 2026-08-29): "increase base vision cone
## and base shot distance by 50% in BR" -- the CTF lengths carried straight
## over to BR were judged too short (a scope-item perk will stretch them
## further later; this is the BASE it will multiply). One lever does both:
## `config.gunRange` is the gun's hit-resolution range AND the miss tracer's
## max travel (sim.nim's selectFireTarget/applyFire), and `visionRange()`
## (sim.nim) is ALWAYS 1.5x the live gunRange (GV34) -- the same reach that
## drives both the human first-person cone render (sim_types.nim's GV33
## note: "The first-person strip's wall march follows visionRange too") and
## the fog-of-war grid every policy's observation is built from. Bumping the
## BR default gunRange therefore bumps both together, automatically, with no
## second constant to keep in sync.
##
## Classic (brMode off, the default) is untouched byte-for-byte: the bump
## lives entirely inside the `if not node.hasKey("gunRange")` DEFAULT
## resolution branch in sim_config.nim's `update()` (config-resolvable, not
## a hardcoded BR-only constant, so a later scope perk multiplies the same
## `gunRange` field further) and is itself gated on `config.brMode`.

import
  helpers,
  std/unittest,
  bitworld/spriteprotocol,
  ctf/[global, sim]

suite "BR base ranges: config-resolved values (real default map)":
  test "classic default gun range and vision-cone reach are untouched":
    let config = defaultGameConfig()
    check config.brMode == false
    check config.gunRange == GunRange                     # 1050.
    let sim = initCtfForTest(config)
    check sim.visionRange() == GunRange * 3 div 2          # 1575 (GV34's 1.5x).

  test "BR default gun range and vision-cone reach are exactly 1.5x classic":
    var config = defaultGameConfig()
    config.update("""{"brMode": true}""")
    check config.gunRange == GunRange * 3 div 2             # 1575.
    let sim = initCtfForTest(config)
    check sim.visionRange() == (GunRange * 3 div 2) * 3 div 2  # 2362.
    # The literal before -> after Maxwell's directive names, pinned so a
    # future GunRange retune can't silently drift what this test proves:
    check GunRange == 1050
    check config.gunRange == 1575
    check sim.visionRange() == 2362

  test "an explicit gunRange override in BR wins unscaled":
    # Same rule the map-derived default already followed one line above it
    # in sim_config.nim: `not node.hasKey("gunRange")` gates BOTH the
    # map default AND the BR bump, so a league config that pins its own
    # number keeps getting exactly that number, BR or not.
    var config = defaultGameConfig()
    config.update("""{"brMode": true, "gunRange": 900}""")
    check config.gunRange == 900

  test "brMode:false leaves the default gun range at classic's":
    var config = defaultGameConfig()
    config.update("""{"brMode": false}""")
    check config.gunRange == GunRange

suite "BR base ranges: physical discrimination (open field, scope-locked zero jitter)":
  ## No hand-authored arena has a corridor long enough to fire this far --
  ## test_gun_jitter.nim's own docstring: "the widest fully clear corridor on
  ## the default arena is ~313px" -- so this suite installs its own
  ## obstacle-free field via mapSpec, the same mechanism a generated map's
  ## resolved geometry already pins into a replay (sim_config.nim's
  ## `update()`). PerkScope + perkMods.scopeAim: 1.0 collapses
  ## aimJitterSigma to exactly 0 (sim.nim: `result * (1000 - 1000) / 1000`),
  ## so the shot is a deterministic, dead-straight ray with no per-run flake
  ## risk -- the ONLY variable across the two tests below is brMode.
  const
    FieldWidth = 1600
    FieldHeight = 300
    ShooterX = 100
    ShooterY = 150
    HitDistance = GunRange * 13 div 10   # 1365px: 1.3x classic's default range.

  proc openField(): CtfMap =
    result.name = "test-open-field"
    result.path = "test-open-field"
    result.width = FieldWidth
    result.height = FieldHeight
    result.mapLayer = 0
    result.walkLayer = 1
    result.wallLayer = 2
    result.center = MapPoint(x: FieldWidth div 2, y: FieldHeight div 2)
    result.flagRing = 30
    result.captureClear = 40
    result.spawnClearW = 30
    result.spawnClearH = 30
    result.gunRange = GunRange           # same baked default as arena/gen.
    result.leftObstacles = @[]           # border wall only -- zero interior.

  proc fieldGame(brMode: bool): SimServer =
    var config = defaultGameConfig()
    let brJson = if brMode: "true" else: "false"
    config.update(
      "{\"mapSpec\": " & mapSpecJson(openField()) & ", \"brMode\": " & brJson &
      ", \"hitPoints\": 1}")   # one hit is one kill: a clean 0-vs-1 kill signal.
    result = initCtfForTest(config)
    discard result.addPlayer("shooter")
    discard result.addPlayer("target")
    result.startGame()
    result.players[0].team = Red
    result.players[1].team = Blue
    result.players[0].perks = {PerkScope}
    result.config.perkMods.scopeAim = 1000   # 100%: zero aim jitter.
    result.players[0].x = ShooterX
    result.players[0].y = ShooterY
    result.players[0].aimBrads = 0            # due east.
    result.players[0].fireCooldown = 0
    result.players[0].windupBrads = -1
    result.players[1].y = ShooterY

  test "classic: a dead-straight shot at 1.3x the default gun range misses":
    var sim = fieldGame(brMode = false)
    check sim.config.gunRange == GunRange                  # 1050, unbumped.
    sim.players[1].x = ShooterX + HitDistance               # 1365px away.

    sim.tryFire(0)

    check sim.players[0].kills == 0
    check sim.players[1].alive

  test "BR: the identical dead-straight shot at 1.3x the OLD range connects":
    var sim = fieldGame(brMode = true)
    check sim.config.gunRange == GunRange * 3 div 2          # 1575: the +50% base.
    sim.players[1].x = ShooterX + HitDistance                 # same 1365px.

    sim.tryFire(0)

    check sim.players[0].kills == 1
    check not sim.players[1].alive

# The suite above installs a custom, non-default-sized field as THE process
# map (selectCtfMap runs inside initSimServer) -- process-wide state
# (MapWidth/MapHeight/FovGridW/H and the render caches) -- so it must leave
# no footprint for whatever runs after it in the same process, exactly the
# rule test_replay_switch_caches.nim's own module-end comment states
# (`tests.nim` runs every shard in ONE process, unlike CI's four binaries).
discard loadCtfMap()
invalidateBoardMapCaches()
