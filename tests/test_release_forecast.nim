import
  std/[json, math, os, strutils, tables, unittest],
  zippy/ziparchives,
  ../players/baseline/baseline,
  ../players/baseline/baseline/artlog

type
  Point = tuple[x, y: float]
  TrackObs = tuple[
    pos: Point,
    vel: Point,
    age: int,
    synthetic: bool,
    losClear: bool
  ]
  ForecastResult = tuple[
    veto: bool,
    reason: string,
    targetAlong, targetPerp, mateAlong, matePerp: float,
    lockedBrads: int
  ]

const
  Up = 1'u8
  Down = 2'u8
  Right = 8'u8
  ForecastSteps = 6
  Accel = 76.0 / 256.0
  Friction = 144.0 / 256.0

proc rayPoint(
    origin: Point,
    brads: int,
    along: float,
    perp = 0.0
): Point =
  let
    angle = float(brads) * PI / 128.0
    dx = cos(angle)
    dy = -sin(angle)
  (origin.x + dx * along + dy * perp,
   origin.y + dy * along - dx * perp)

proc rayPerp(origin, point: Point, brads: int): float =
  let
    angle = float(brads) * PI / 128.0
    dx = cos(angle)
    dy = -sin(angle)
  abs((point.x - origin.x) * dy - (point.y - origin.y) * dx)

proc observedVelocity(delta: Point, driveX, driveY: int): Point =
  var neutralFactor = 0.0
  var decay = 1.0
  # The sixth neutral decay falls below production's 8/256 stop threshold
  # for the one-pixel replay deltas used by these inverse fixtures.
  for _ in 0 ..< (ForecastSteps - 1):
    decay *= Friction
    neutralFactor += decay
  let drivenBias = Accel * float(
    ForecastSteps * (ForecastSteps + 1) div 2)
  result.x =
    if driveX == 0: delta.x / neutralFactor
    else: (delta.x - float(driveX) * drivenBias) / float(ForecastSteps)
  result.y =
    if driveY == 0: delta.y / neutralFactor
    else: (delta.y - float(driveY) * drivenBias) / float(ForecastSteps)

proc track(
    pos: Point,
    vel: Point = (0.0, 0.0),
    age = 0,
    synthetic = false,
    losClear = true
): TrackObs =
  (pos, vel, age, synthetic, losClear)

proc project(obs: TrackObs): Point =
  testForecastTrackRelease(
    obs.pos.x, obs.pos.y, obs.vel.x, obs.vel.y, obs.age)

proc rawDecision(
    shooter, shooterVel: Point,
    moveMask: uint8,
    target: TrackObs,
    estAim: int,
    mates: seq[TrackObs] = @[],
    gunAction = true,
    targetLosClear = true,
    emitTelemetry = false,
    aimUncertainty = 0,
    observedBucket = -1
): ForecastResult =
  let
    projectedShooter = testForecastShooterRelease(
      shooter.x, shooter.y, shooterVel.x, shooterVel.y, moveMask)
    projectedTarget = project(target)
  var projectedMates: seq[
    tuple[x, y: float, age: int, losClear: bool]]
  for mate in mates:
    if mate.age < 0 or mate.age > 12:
      continue
    let projected = project(mate)
    projectedMates.add(
      (projected.x, projected.y, mate.age, mate.losClear))
  testReleaseForecast(
    gunAction,
    projectedShooter.x, projectedShooter.y,
    projectedTarget.x, projectedTarget.y,
    estAim,
    targetLosClear,
    projectedMates,
    emitTelemetry,
    target.age == 0,
    target.synthetic,
    aimUncertainty,
    (if observedBucket >= 0: observedBucket else: estAim))

suite "v15 gun release forecast":
  test "projection starts at the pre-trigger observation and applies six moves":
    let
      shooter = testForecastShooterRelease(
        100.0, 100.0, 0.0, 0.0, Right)
      currentTrack = testForecastTrackRelease(
        100.0, 100.0, 2.0, -1.0, 0)
      agedTrack = testForecastTrackRelease(
        100.0, 100.0, 2.0, -1.0, 2)
    check abs(shooter.x - (100.0 + 21.0 * Accel)) < 0.0001
    check abs(shooter.y - 100.0) < 0.0001
    check abs(currentTrack.x - 112.0) < 0.0001
    check abs(currentTrack.y - 94.0) < 0.0001
    check abs(agedTrack.x - 116.0) < 0.0001
    check abs(agedTrack.y - 92.0) < 0.0001

  test "tick 2426 projects shooter movement into a stationary mate":
    let
      heading = 231
      shooter: Point = (250.0, 69.0)
      releaseShooter: Point = (251.0, 76.0)
      shooterVel = observedVelocity((1.0, 7.0), 0, 1)
      mate = rayPoint(releaseShooter, heading, 100.0, -11.4)
      projectedShooter = testForecastShooterRelease(
        shooter.x, shooter.y, shooterVel.x, shooterVel.y, Down)
      result = rawDecision(
        shooter, shooterVel, Down,
        track(rayPoint(releaseShooter, heading, 300.0)),
        heading,
        @[track(mate)])
    check abs(projectedShooter.x - releaseShooter.x) < 0.001
    check abs(projectedShooter.y - releaseShooter.y) < 0.001
    check rayPerp(shooter, mate, heading) > 14.0
    check abs(rayPerp(releaseShooter, mate, heading) - 11.4) < 0.01
    check result.veto
    check result.reason == "friendly_first"

  test "tick 4957 projects combined shooter and mate movement":
    let
      heading = 56
      shooter = (300.0, 300.0)
      releaseShooter = (299.0, 293.0)
      shooterVel = observedVelocity((-1.0, -7.0), 0, -1)
      triggerMate = rayPoint(shooter, heading, 100.0, 28.6)
      mateVel = (13.0 / 6.0, 1.0 / 6.0)
      releaseMate = project(track(triggerMate, mateVel))
      result = rawDecision(
        shooter, shooterVel, Up,
        track(rayPoint(releaseShooter, heading, 300.0)),
        heading,
        @[track(triggerMate, mateVel)])
    check abs(rayPerp(shooter, triggerMate, heading) - 28.6) < 0.01
    check abs(rayPerp(releaseShooter, releaseMate, heading) - 13.3) < 0.05
    check result.veto
    check result.reason == "friendly_first"

  test "tick 3236 projects both bodies onto the locked ray":
    let
      heading = 201
      shooter = (198.0, 302.0)
      releaseShooter = (204.0, 295.0)
      shooterVel = observedVelocity((6.0, -7.0), 1, -1)
      triggerMate = (244.0, 412.0)
      mateVel = (-8.0 / 6.0, -9.0 / 6.0)
      releaseMate = project(track(triggerMate, mateVel))
      result = rawDecision(
        shooter, shooterVel, Right or Up,
        track(rayPoint(releaseShooter, heading, 300.0)),
        heading,
        @[track(triggerMate, mateVel)])
    check abs(rayPerp(shooter, triggerMate, heading) - 20.8) < 0.1
    check abs(rayPerp(releaseShooter, releaseMate, heading) - 7.6) < 0.1
    check result.veto
    check result.reason == "friendly_first"

  test "tick 3271 uses the self bucket around the true locked heading":
    let
      shooter = (217.0, 28.0)
      result = rawDecision(
        shooter, (0.0, 0.0), 0,
        track(rayPoint(shooter, 186, 314.0)),
        192,
        @[track((209.0, 263.0))],
        aimUncertainty = 8)
    check abs(rayPerp(shooter, (209.0, 263.0), 192) - 8.0) < 0.01
    check result.veto
    check result.reason == "friendly_first"

  test "tick 3455 uses bucket 176 for the observed 177-brad heading":
    let
      shooter = (221.0, 26.0)
      result = rawDecision(
        shooter, (0.0, 0.0), 0,
        track(rayPoint(shooter, 186, 285.0)),
        176,
        @[track((181.0, 117.0))],
        aimUncertainty = 8)
    check abs(rayPerp(shooter, (181.0, 117.0), 177) - 4.57) < 0.01
    check result.veto
    check result.reason == "friendly_first"

  test "tick 1697 uses bucket 32 for the observed 36-brad heading":
    let
      shooter = (174.0, 635.0)
      result = rawDecision(
        shooter, (0.0, 0.0), 0,
        track(rayPoint(shooter, 26, 459.0)),
        32,
        @[track((225.0, 584.0))],
        aimUncertainty = 8)
    check abs(rayPerp(shooter, (225.0, 584.0), 36) - 7.07) < 0.01
    check result.veto
    check result.reason == "friendly_first"

  test "the self bucket includes minus eight through plus seven only":
    let headings = testReleaseAimHeadings(0)
    check headings.len == 16
    check headings[0] == 248
    check headings[^1] == 7
    check 8 notin headings

  test "all sixteen possible headings must authorize the target":
    let
      shooter: Point = (100.0, 100.0)
      certain = track(rayPoint(shooter, 0, 70.0))
      uncertain = track(rayPoint(shooter, 0, 75.0))
    check not rawDecision(
      shooter, (0.0, 0.0), 0, certain, 0,
      aimUncertainty = 8).veto
    let oneHeadingMisses = rawDecision(
      shooter, (0.0, 0.0), 0, uncertain, 0,
      aimUncertainty = 8)
    check oneHeadingMisses.veto
    check oneHeadingMisses.reason == "target_corridor"

  test "production quantifier excludes plus eight behaviorally":
    let
      shooter: Point = (100.0, 100.0)
      angle = -0.5 * PI / 128.0
      target = track((
        shooter.x + cos(angle) * 75.0,
        shooter.y - sin(angle) * 75.0))
      result = rawDecision(
        shooter, (0.0, 0.0), 0, target, 0,
        aimUncertainty = 8)
    check not result.veto

  test "one unsafe friendly heading wins over target uncertainty":
    let
      shooter = (100.0, 100.0)
      target = track(rayPoint(shooter, 0, 75.0))
      mate = track(rayPoint(shooter, -8, 35.0))
      result = rawDecision(
        shooter, (0.0, 0.0), 0, target, 0, @[mate],
        aimUncertainty = 8)
    check result.veto
    check result.reason == "friendly_first"

  test "a tracked heading outside its observed bucket fails closed":
    let
      shooter = (100.0, 100.0)
      target = track(rayPoint(shooter, 9, 300.0))
      result = rawDecision(
        shooter, (0.0, 0.0), 0, target, 9,
        aimUncertainty = 8,
        observedBucket = 0)
    check result.veto
    check result.reason == "aim_unavailable"

  test "five-sample silhouette reaches 14px and LOS fails closed":
    let
      shooter = (100.0, 100.0)
      targetAt14 = track(rayPoint(shooter, 0, 100.0, 14.0))
      targetPast14 = track(rayPoint(shooter, 0, 100.0, 14.001))
      edgeVisible = rawDecision(
        shooter, (0.0, 0.0), 0, targetAt14, 0,
        targetLosClear = true, aimUncertainty = 0)
      edgeOccluded = rawDecision(
        shooter, (0.0, 0.0), 0, targetAt14, 0,
        targetLosClear = false, aimUncertainty = 0)
      outside = rawDecision(
        shooter, (0.0, 0.0), 0, targetPast14, 0,
        aimUncertainty = 0)
    check not edgeVisible.veto
    check edgeOccluded.veto
    check edgeOccluded.reason == "target_los"
    check outside.veto
    check outside.reason == "target_corridor"

  test "mate silhouette uses the same inclusive boundary and LOS":
    let
      shooter = (100.0, 100.0)
      target = track(rayPoint(shooter, 0, 100.0))
      at14 = track(rayPoint(shooter, 0, 50.0, 14.0))
      past14 = track(rayPoint(shooter, 0, 50.0, 14.001))
      occluded = track(
        rayPoint(shooter, 0, 50.0, 14.0), losClear = false)
    check rawDecision(
      shooter, (0.0, 0.0), 0, target, 0, @[at14],
      aimUncertainty = 0).reason == "friendly_first"
    check not rawDecision(
      shooter, (0.0, 0.0), 0, target, 0, @[past14],
      aimUncertainty = 0).veto
    check not rawDecision(
      shooter, (0.0, 0.0), 0, target, 0, @[occluded],
      aimUncertainty = 0).veto

  test "an equal-distance mate blocks while a beyond-target mate clears":
    let
      shooter = (100.0, 100.0)
      target = track(rayPoint(shooter, 0, 100.0))
      tied = track(rayPoint(shooter, 0, 100.0))
      beyond = track(rayPoint(shooter, 0, 100.001))
    let blocked = rawDecision(
      shooter, (0.0, 0.0), 0, target, 0, @[tied],
      aimUncertainty = 0)
    check blocked.veto
    check blocked.reason == "friendly_first"
    check not rawDecision(
      shooter, (0.0, 0.0), 0, target, 0, @[beyond],
      aimUncertainty = 0).veto

  test "fresh, stale, synthetic, and aim-unavailable targets fail safely":
    let
      shooter = (100.0, 100.0)
      targetPos = rayPoint(shooter, 0, 100.0)
      fresh = rawDecision(
        shooter, (0.0, 0.0), 0, track(targetPos), 0)
      stale = rawDecision(
        shooter, (0.0, 0.0), 0, track(targetPos, age = 1), 0)
      synthetic = rawDecision(
        shooter, (0.0, 0.0), 0,
        track(targetPos, synthetic = true), 0)
      unavailable = rawDecision(
        shooter, (0.0, 0.0), 0, track(targetPos), -1)
    check not fresh.veto
    check stale.veto
    check stale.reason == "target_invalid"
    check synthetic.veto
    check synthetic.reason == "target_synthetic"
    check unavailable.veto
    check unavailable.reason == "aim_unavailable"

  test "stale mates are excluded while fresh projected mates block":
    let
      shooter = (100.0, 100.0)
      target = track(rayPoint(shooter, 0, 100.0))
      matePos = rayPoint(shooter, 0, 50.0)
      fresh = rawDecision(
        shooter, (0.0, 0.0), 0, target, 0,
        @[track(matePos, age = 12)])
      stale = rawDecision(
        shooter, (0.0, 0.0), 0, target, 0,
        @[track(matePos, age = 13)])
    check fresh.veto
    check fresh.reason == "friendly_first"
    check not stale.veto

  test "collision guard uses the proven inclusive 46px reach":
    check not testReleaseActorStable(45.0)
    check not testReleaseActorStable(46.0)
    check testReleaseActorStable(47.0)
    check not testReleaseActorStable(46.0, age = 9)
    check testReleaseActorStable(46.0, age = 10)

  test "origin requires open terrain across the hidden-collider bound":
    check not testReleaseTerrainStable(84)
    check testReleaseTerrainStable(85)

  test "nine settle frames complete eight neutral simulation steps":
    check testReleaseSettleFrames() == 9

  test "teammate reach includes wall slides and diamond pushes":
    check testReleaseMateReach(0) == 76.0
    check testReleaseMateReach(12) == 226.0

  test "future respawns cannot perturb origin or precede the target":
    check not testReleaseRespawnOriginStable(218.0)
    check testReleaseRespawnOriginStable(219.0)
    check testReleaseRespawnOriginStable(1016.0)
    check not testReleaseRespawnOriginStable(1017.0)
    check not testReleaseRespawnTargetStable(true, 206.0)
    check testReleaseRespawnTargetStable(true, 207.0)
    check testReleaseRespawnTargetStable(false, 1028.0)
    check not testReleaseRespawnTargetStable(false, 1029.0)

  test "reachable teammate AABB projects onto the shot axes":
    let
      outside = testReleaseMateEnvelope(50.0, 31.1, 17.0)
      grazing = testReleaseMateEnvelope(50.0, 31.0, 17.0)
      diagonal = testReleaseMateEnvelope(
        50.0, 38.0, 17.0, brads = 32)
      visibleBeyond = testReleaseMateEnvelope(
        120.0, 0.0, 25.0, losClear = true)
    check not outside.hit
    check grazing.hit
    check abs(grazing.perp - 14.0) < 0.0001
    check diagonal.hit
    check visibleBeyond.hit
    check abs(visibleBeyond.along - 95.0) < 0.0001

  test "one visible silhouette sample is enough for a partial-body hit":
    let
      partial = testReleasePartialBodyLos(true)
      blocked = testReleasePartialBodyLos(false)
    check partial.geometry
    check partial.hit
    check blocked.geometry
    check not blocked.hit

  test "six-step diamond lookahead crosses one or two frame boundaries":
    check testReleaseDiaFrameAhead(0, 5, 1) == 6
    check testReleaseDiaFrameAhead(1, 5, 1) == 6
    check testReleaseDiaFrameAhead(2, 5, 1) == 7
    check testReleaseDiaFrameAhead(3, 5, 1) == 7
    check testReleaseDiaFrameAhead(2, 5, -1) == 3

  test "pre-lock diamond uncertainty is confined to its swept pixels":
    check testReleaseDiaVerdictPrelock(10, 0, 0) == -2
    check testReleaseDiaVerdictPrelock(10, 10, 10) == -1

  test "plasma and every other non-gun action bypass the forecast":
    let
      shooter = (100.0, 100.0)
      target = track(rayPoint(shooter, 0, 100.0))
      mate = track(rayPoint(shooter, 0, 50.0))
    check not rawDecision(
      shooter, (0.0, 0.0), Right, target, 0, @[mate],
      gunAction = false).veto

  test "a veto emits auditable shot_veto geometry without a shot event":
    let
      dir = getTempDir() / "release_forecast_artlog_test"
      dest = dir / "artifact.zip"
      shooter = (100.0, 100.0)
      target = track(rayPoint(shooter, 0, 100.0))
      mate = track(rayPoint(shooter, 0, 50.0))
    removeDir(dir)
    putEnv("COWORLD_PLAYER_ARTIFACT_UPLOAD_URL", "file://" & dest)
    artInit(0, "Red", "MidTop")
    let veto = rawDecision(
      shooter, (0.0, 0.0), 0, target, 0, @[mate],
      emitTelemetry = true)
    check veto.veto
    artFrame(FrameSnap(
      tick: 42,
      alive: true,
      x: 100,
      y: 100,
      hp: 3,
      aim: 0,
      objective: "attack",
      action: "fire",
      engageDist: 100,
      fired: false))
    artFlush()

    let reader = openZipArchive(dest)
    var files: Table[string, string]
    for path in reader.walkFiles:
      files[path] = reader.extractFile(path)
    reader.close()
    check parseJson(files["meta.json"])["defines"].contains(
      %"releaseForecast")
    var
      vetoEvents = 0
      shotEvents = 0
    for line in files["events.jsonl"].splitLines:
      if line.len == 0:
        continue
      let row = parseJson(line)
      case row["e"].getStr
      of "shot_veto":
        inc vetoEvents
        check row["reason"].getStr == "friendly_first"
        check row["aim_uncertainty"].getInt == 8
        check row.hasKey("sx")
        check row.hasKey("target_along")
        check row.hasKey("mate_perp")
      of "shot":
        inc shotEvents
      else:
        discard
    check vetoEvents == 1
    check shotEvents == 0
