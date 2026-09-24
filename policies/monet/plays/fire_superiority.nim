## `fire_superiority` -- MONET custom controller #2.
##
## Picasso's SEAL lever #9 (press-vs-break): the league is winner-take-all,
## so this play exists to FINISH fights we are winning and survive the ones
## we are losing -- the engine's default stalls at full health and lets the
## zone draw the game, and a draw pays nobody.
##
## Fog-honest superiority estimate, per step:
## - our guns   = self alive, +1 when the duo partner has a fresh live track
##   WITHIN engageDist of self (the duo partner rides its own unconditional
##   grant row -- view.nim partnerTelemetry, landed 9511b240 -- separate
##   from the ordinary same-team-excluded track loop the "their guns" count
##   below still uses; the grant carries pos/aim/downed every tick both
##   seats are alive). The engageDist gate is v-next (stranger-partner
##   audit): since S2 the second seat is a re-drawn stranger every episode
##   (measured forum change, R3746/47), not our own second Monet instance --
##   a fresh-but-distant partner track proves they are alive somewhere on
##   the map, never that they are IN this fight. Presence used to be
##   treated as proof of a second gun unconditionally; it is now held to
##   the exact distance the enemy count already uses, so a partner off
##   fighting their own battle elsewhere no longer flips an actual 1v2 into
##   a false "superior" read. This still cannot tell whether the stranger
##   is even armed (self.hasGun/hasHopper are never exposed to a policy,
##   same gap loot.nim's own header documents) -- proximity is the
##   cheapest honest proxy available given that blind spot, not a fix for
##   it,
## - their guns = fresh enemy tracks within engageDist,
## - wounded    = counted enemies with KNOWN hp <= 2; unknown hp is HEALTHY.
##
## Superior (outnumber, or match numbers with enough of them wounded):
## PRESS -- navigate to a pressRange band off a chosen enemy track, never
## melting into point-blank against a target that can still fight back
## (point-blank accuracy is inverted on this engine). EXCEPTION -- v10,
## measured gap: leaders bank dPointBlankKill 3x our rate, and the accuracy
## inversion is a risk against a live gun, not against one already known
## wounded (hp <= WoundedHpMax) and unlikely to out-trade us even at reduced
## accuracy. When the chosen press target is confirmed wounded, close to
## finishRange instead -- a fixed approximation of the engine's own
## `pointBlankPxFor` band (not exposed to plays, so not exactly reproduced;
## see glory.nim PointBlankPx/scaledByGunRange). Unknown-hp and full-health
## targets keep the wider pressRange band.
##
## Press-target choice among several live enemies (v11, the duo-partner
## grant closing a real safety gap): a wide spray that catches N enemies at
## once mints per-victim, compounding (our biggest single scoring events are
## clustered tags) -- but catching our OWN partner in that same cone is an
## uncapped compounding HALVING of the whole duo's take, and the engine's
## spray gate (`sprayContains`, src/shell/body.nim, ArcFireRangePx=170px
## reach / ArcMaxWidthPx=85px full width at max reach) has no partner
## exclusion of its own. `withinFireCone` below mirrors that exact gate
## (sqrt-free -- see tests/test_shell_body_spray_cone.nim for the pin
## against the real engine proc) to pick, among the enemies we could press
## toward, the one whose stand-and-fire position (a) never also catches our
## partner and, failing a tie, (b) catches the most OTHER enemies. This is a
## preference among targets we are already pressing, not a reason to wait --
## an all-candidates-catch-partner fallback keeps the old
## lowest-hp/nearest choice rather than holding off the fight.
##
## Partner-line exposure (v-next, stranger-partner audit -- the inverse of
## the paragraph above): that check only ever protects the partner from OUR
## spray. A stranger partner can just as easily spray THROUGH us toward
## their own chosen target, and the same uncapped compounding halving lands
## on their fire, not ours. Their actual aim cannot be read -- aimBrads
## only ever rides the wire as an opaque int and this SDK exposes no
## cos/sin table to turn it into a direction, so this cannot be the
## mirror-exact gate `clean` above is. The proxy used instead: treat every
## OTHER visible enemy as a plausible aim target FOR the partner
## (withinFireCone(partnerPos, thatEnemy, ourCandidateStand)) and
## deprioritize -- never forbid, an all-exposed field still has to fight --
## a stand position that falls in any of those lines, once `clean` is
## already tied. Positioning hygiene, not a promise: a stranger aiming at a
## THIRD target we cannot see at all stays unmodelled.
## Inferior by breakDeficit or more:
## BREAK -- facing cover, never navigating through the enemy bearing
## (composes with hold_vs_gun's never-turn-your-back doctrine). Even or no
## contact: hold at cover.

import ../../../play_sdk/play

const
  # v61 FOUR DIGITS lane (branch four-digits/w2-v61-persist, base 2161b880
  # v60): lever A opt-outs. Both are plain compile-time constants, DEFAULT
  # ON (false = lever armed) -- never read from a container env var, per
  # the owner's never-arm-a-lever-via-env ruling. Flip to true and rebuild
  # to fall back to byte-identical v60 press/break arithmetic; nothing
  # else in this file changes shape.
  NOFIREPERSIST = false
    ## v61 lever A: no-break window + raised breakDeficit (commit through
    ## the kill instead of handing a fight to one lost exchange). Jordan
    ## fires 3.38 shots per 1k alive ticks vs our 2.44 with flat
    ## return-fire latency (18 vs 19 ticks median) -- jordan-decode-
    ## tables.md; the gap is staying IN the fight once it starts, not
    ## reacting faster to start one.
  NOCLOSEBIAS = false
    ## v61 lever B: bounded close-on-enemy movement bias when guns are
    ## matched and a live target sits beyond pressRange. Jordan closes on
    ## a tracked enemy 65.2% of moving samples vs our 58.3%
    ## (jordan-decode-tables.md).

  NOPRESSFIRE = false
    ## v66 FOUR DIGITS lane (branch four-digits/v66-press) lever (1) PRESS
    ## FIRE. W14's press-range read (420 paired hosted episodes,
    ## ~/.ctf/handoff/2026-09-24-w14-press-range-analysis.md): we fire
    ## ZERO shots in 60-69% of our own <=220px engagements (v63 60.5%,
    ## a2fa8551 61.8%, v60 69.1%) vs 43.4% for episode winners, while hit
    ## rate on the shots we DO take is AT PARITY (85.8% vs 82.5%) -- a
    ## commitment gap, not an aim gap. Bypasses the `superior`/
    ## `baseInferior` gating below (play_step ~546/~616: PRESS only when
    ## we out-count or out-wound them, BREAK on breakDeficit alone) for
    ## any live tracked enemy already inside pressRange: fire now instead
    ## of first winning the gun-count argument.
  NOPRESSCOMMIT = false
    ## v66 lever (2) PRESS COMMIT. Extends lever A's FirePersistTicks
    ## no-break WINDOW (persistSeat/persistUntilTick above, 240 ticks,
    ## engageDist-wide) to UNCONDITIONAL, scoped to a hit landed WITH the
    ## target inside pressRange specifically: no retreat/cover intent
    ## (the `inferior` BREAK branch ~616, the heldByPersist cover branch
    ## ~672, the final cover fallback ~685) until the target is confirmed
    ## dead, its track goes stale for more than CommitLostTicks, or our
    ## own hp fraction drops below CommitHpFloorScaled. W14: kill|fired
    ## 51.1% vs winners' 73.2%, died|fired 43.2% vs 22.0%, shots/engagement
    ## 2.40 vs 3.13 despite our engagements running LONGER -- we get
    ## yielded off a trade before it's decided, not out-aimed in it.
  NOCLOSEIN = false
    ## v66 lever (3) CLOSE INTO PRESS. Lever B's close-on-enemy bias (see
    ## NOCLOSEBIAS above) stops at pressRange; against a confirmed lone
    ## target (exactly one live track within CloseInLoneRangePx, the same
    ## <=500px "1v1" definition W14's read used) with our own hp at or
    ## above theirs (same integer hitPoints scale WoundedHpMax already
    ## uses -- track.hp carries no hpFrac the way self.hp does), close to
    ## CloseInStandPx instead of stopping at pressRange so entries into
    ## the press band actually happen (W14: ~0.6 entries/episode on every
    ## build measured, ours vs winners' 0.80). Never against 2+ tracked
    ## enemies.

  NORANGEFIRE = false
    ## v68 FOUR DIGITS lane (branch four-digits/v68-range) lever (1) RANGE
    ## FIRE. W17's approach(<=500px)->entry(<=220px) funnel
    ## (~/.ctf/handoff/2026-09-24-w17-entry-analysis.md, 1,119 paired
    ## hosted episodes) found the gap ONE LEVEL ABOVE press range:
    ## P(entry|approach) is at parity (38.0% us vs 36.8% winners), but
    ## non-entry approaches resolve very differently -- winners kill their
    ## target at range before we ever reach press range 44.6% of the time
    ## vs our 27.1%, and WE die first 40.3% vs their 33.2%. That is what
    ## shortens our alive-time (814 vs 1,012 ticks/ep) and, mechanically,
    ## our approaches/episode. Widens v66's own PRESS FIRE gate (below,
    ## play_step, was `nearestDistSq <= sq(params.pressRange)`) from
    ## pressRange (220, tunable 60-500) to the fixed RangeFireBandPx (500,
    ## W17's own "approach" definition) -- identical candidate selection
    ## (nearest, or lower-hp within 20% of nearest) and identical
    ## stand/finish-band arithmetic (still params.pressRange/finishRange --
    ## this widens WHO we press toward, never how close we stop). A target
    ## already inside the original pressRange keeps the `fire_superiority:
    ## press` tag (v66's own, unchanged meaning; NORANGEFIRE alone reverts
    ## the gate to pressRange, matching v66 byte-for-byte here); the 220-500
    ## extension is tagged `fire_superiority:rangefire` so a wire read can
    ## tell the two sub-bands apart.
  NOFASTSHOT = false
    ## v68 lever (2) FAST SHOT. W17: inside press-range entries where we DO
    ## fire, our own median ticks from entry to first shot is 50 vs winners'
    ## 24 (hit rate at parity, so this is latency, not aim) -- a ~2x
    ## hesitation gap inside the fired population, on top of the separate
    ## zero-shot silence problem W14 found. Root cause (read against
    ## src/shell/body.nim's seatTick/gunActuationMask and the finisher):
    ## combat aim/fire is engine-autonomous once a tracked enemy is
    ## "shootable" (in the ~1050px weapon range, LOS clear), but that
    ## shootability itself rides the seat's OWN facing (src/ctf/sim.nim's
    ## applyFovCone is centered on aimBrads) -- and outside combat this
    ## play has never told the body where to look: the Intent field that
    ## exists for exactly this (`idle_aim_center_brads`, intent.schema.json,
    ## "the idle-aim center... the body requires it") has never been set by
    ## any play in this repo (grepped), so the finisher always stamps its
    ## hard-coded default of 0 (src/ctf/server.nim) regardless of where the
    ## enemy actually is. The aim then has to rotate the FULL delta from
    ## brads=0 once combat finally acquires a target -- bounded by the
    ## engine's own AimTurnRate per tick (src/shell/body.nim), a real floor
    ## this play cannot beat, but it CAN stop paying rotation for a wrong
    ## starting direction. Fix: whenever a live enemy is tracked (nearest,
    ## the same read the BREAK branch already turns into a cover bearing),
    ## point idle_aim_center_brads at them (sectorTo(...)*16 -- the exact
    ## same 16-way brads-space bearing this file already computes for
    ## nearestCover) instead of leaving it unset. Combat's own aim takes
    ## over completely once a target is actually acquired (needsIdleAim
    ## flips false in seatTick), so this can only ever shrink the
    ## rotation window, never fight the engine's own aim once armed. No
    ## exported play_sdk helper emits this field (checked); emitted here via
    ## a small local canonical-intent writer (emitIntentWithAim below) built
    ## only from play_sdk's already-exported emitRaw(bytes), so play_sdk
    ## itself stays untouched. Tag `fire_superiority:fastshot` marks the
    ## first tick we commit to a newly-tracked seat (not the one we were
    ## last pressing) -- the exact tick the hint had the most rotation to
    ## save; steady-state ticks against the same target keep press/rangefire
    ## as before.
  NORANGECOMMIT = false
    ## v68 lever (3) RANGE COMMIT (optional per the task; cheap, additive).
    ## v66's own PRESS COMMIT (NOPRESSCOMMIT above) is untouched -- this is
    ## a SEPARATE, narrower no-break rule for a hit landed in the NEW
    ## 220-500px sub-band specifically: same fog-honest hp-drop arm signal,
    ## independent bookkeeping (lastSeenHpRange, not lastSeenHp/
    ## lastSeenHpCommit), but a different release condition -- "do not
    ## break off while the target is alive, tracked, and our HP >= theirs"
    ## (task's own wording), not PRESS COMMIT's unconditional-in-band hold
    ## to a 30% hp floor. Composes as a THIRD term suppressing `inferior`
    ## alongside lever A's persistHolds, so it only ever prevents a BREAK
    ## the other levers would not already have prevented; never forces a
    ## press the way PRESS FIRE/PRESS COMMIT do. Tag `fire_superiority:
    ## rangecommit` (cover branch) / `fire_superiority:rangecommit-hold`
    ## (stationary fallback), mirroring lever A's persist/persist-hold pair.
  NOHITBACK = false
    ## v68 lever (4) TOOK-DAMAGE / HITBACK (coordinator update, W19:
    ## ~/.ctf/handoff/2026-09-24-w19-ranged-fight-analysis.md, 4,921 vs
    ## 1,658 ranged (220-500px) exchanges). Two confirmed gaps one level
    ## BELOW W17: (a) who fires first -- us 28.6% vs winners 51.6%, i.e.
    ## winners open the exchange far more often than we do (RANGE FIRE/FAST
    ## SHOT above already target this: firing on acquisition anywhere
    ## <=500px, aim pre-pointed at the target, rather than waiting to close
    ## or waiting to be shot at first); (b) return-fire persistence -- when
    ## we ARE fired upon first, win-rate is 39.6% (us) vs 57.6% (winners),
    ## and in exchanges we LOSE we fire a median of 0 more shots after the
    ## first hit taken (winners: 1) despite surviving LONGER afterward (96
    ## vs 78 ticks) -- we have the time and do not spend it; flinch
    ## (retreat-dominant in the 40 ticks after a hit) is 26.3% vs 21.5%.
    ## This lever targets (b): a confirmed drop in OUR OWN hp (self.hp, the
    ## same integer scale WoundedHpMax/CLOSE-IN already use -- fog-honest,
    ## this play has no aggressor-identity/bearing signal at all, see the
    ## file header, so the fire-back target is the same `nearest` tracked
    ## enemy every other branch here already uses for its bearing) arms an
    ## unconditional press toward `nearest` (bypassing superior/inferior,
    ## same precedent as PRESS FIRE/RANGE FIRE) AND suppresses BREAK
    ## (bypassing it, same precedent as persistHolds/rangeCommitHolds) for
    ## HitbackTicks, released early only once self hp fraction confirms
    ## below CommitHpFloorScaled (30%, PRESS COMMIT's own floor) -- "no
    ## retreat intent... unless HP < 30%" per the coordinator's own wording.
    ## Tag `fire_superiority:hitback`. RANGE FIRE already covers most
    ## post-hit ticks within 500px (same shape as v66's PRESS COMMIT vs
    ## PRESS FIRE precedent: the cheaper, earlier bypass usually reaches a
    ## tick first), so this branch's own tag mostly surfaces for the
    ## 500-600px residual and whenever RANGE FIRE's own gate does not apply
    ## this tick -- still architecturally live throughout HitbackTicks.

  RangeFireBandPx = 500'i32
    ## v68 levers (1)/(3): the engage-band ceiling, fixed (not the tunable
    ## params.pressRange) -- W17's own <=500px "approach" definition.
  HitbackTicks = 120'i32  ## v68 lever (4): no-retreat/press window post-hit.

  RaisedBreakDeficit = 4'i32     ## v61 lever A: was 2 (see DefaultBreakDeficit)
  DefaultBreakDeficit = 2'i32    ## v60 value, kept for the NOFIREPERSIST fallback
  EffectiveBreakDeficitDefault: int32 =
    (if NOFIREPERSIST: DefaultBreakDeficit else: RaisedBreakDeficit)

  FirePersistTicks = 240'i32
    ## v61 lever A: no-break window after a landed tag on a still-tracked,
    ## still-alive enemy inside engageDist.

  CommitLostTicks = 60'i32
    ## v66 lever (2): grace window after commitSeat's track goes stale
    ## (or drops from view entirely) before PRESS COMMIT releases it.
  CommitHpFloorScaled = 300_000'i32
    ## v66 lever (2): self.hpFracScaled (float64 hp fraction * 1_000_000,
    ## see play_sdk's f64ScaledAt) floor -- 30% -- below which PRESS
    ## COMMIT releases the seat even with the target still tracked.
  CloseInLoneRangePx = 500'i32   ## v66 lever (3): "1v1" definition.
  CloseInStandPx = 150'i32       ## v66 lever (3): closer than pressRange.

  MaxTrackedSeats = 32'i32  ## matches sim_types.MaxPlayers (seat id space)

  # ManifestBytes carries EffectiveBreakDeficitDefault as its literal
  # "breakDeficit" default -- two full strings, selected at compile time,
  # rather than string-building the JSON (this SDK's emitRaw wants a
  # static[string], and a literal is the least surprising way to keep
  # that true here).
  ManifestBytesV60 =
    "{\"abi\":1,\"class\":\"controller\",\"doc\":\"press-vs-break: count the guns you can see -- press a winning fight to a range band, break off only when truly outgunned\",\"modes\":[\"br\"],\"name\":\"fire_superiority\",\"params\":{\"breakDeficit\":{\"default\":2,\"integer\":true,\"kind\":\"number\",\"max\":8,\"min\":1},\"coverMax\":{\"default\":260,\"integer\":true,\"kind\":\"number\",\"max\":600,\"min\":0},\"engageDist\":{\"default\":600,\"integer\":true,\"kind\":\"number\",\"max\":1200,\"min\":100},\"finishRange\":{\"default\":140,\"integer\":true,\"kind\":\"number\",\"max\":260,\"min\":40},\"pressRange\":{\"default\":220,\"integer\":true,\"kind\":\"number\",\"max\":500,\"min\":60},\"woundedPct\":{\"default\":50,\"integer\":true,\"kind\":\"number\",\"max\":100,\"min\":0}},\"retune\":true}"
  ManifestBytesV61 =
    "{\"abi\":1,\"class\":\"controller\",\"doc\":\"press-vs-break: count the guns you can see -- press a winning fight to a range band, break off only when truly outgunned\",\"modes\":[\"br\"],\"name\":\"fire_superiority\",\"params\":{\"breakDeficit\":{\"default\":4,\"integer\":true,\"kind\":\"number\",\"max\":8,\"min\":1},\"coverMax\":{\"default\":260,\"integer\":true,\"kind\":\"number\",\"max\":600,\"min\":0},\"engageDist\":{\"default\":600,\"integer\":true,\"kind\":\"number\",\"max\":1200,\"min\":100},\"finishRange\":{\"default\":140,\"integer\":true,\"kind\":\"number\",\"max\":260,\"min\":40},\"pressRange\":{\"default\":220,\"integer\":true,\"kind\":\"number\",\"max\":500,\"min\":60},\"woundedPct\":{\"default\":50,\"integer\":true,\"kind\":\"number\",\"max\":100,\"min\":0}},\"retune\":true}"
  ManifestBytes = (when NOFIREPERSIST: ManifestBytesV60 else: ManifestBytesV61)

  # src/shell/cover_scorer.nim's half-sector slope thresholds (16 sectors).
  SlopeScale = 1_000_000'i64
  Tan1125 = 198_912'i64
  Tan3375 = 668_179'i64
  Tan5625 = 1_496_606'i64
  Tan7875 = 5_027_339'i64

  FreshGunTicks = 60'i32   ## a track older than this is not a live gun
  WoundedHpMax = 2'i32     ## known hp+shield at or below this = wounded

  # src/shell/body.nim: ArcFireRangePx (spray reach) / ArcMaxWidthPx (full
  # cone width AT that reach; width scales linearly with distance from 0 at
  # the muzzle). Pinned against the real engine proc `sprayContains` by
  # tests/test_shell_body_spray_cone.nim -- if the host retunes the cone,
  # that test catches the drift before this file goes stale silently.
  ArcFireRangePx = 170'i64
  ArcMaxWidthPx = 85'i64
  MaxCandidates = 32'i32  ## matches play_sdk MaxViewTracks

type
  DecisionKind = enum
    dkNone
    dkHold
    dkPress
    dkCover
    dkZone
    dkClose  ## v61 lever B: bounded close-on-enemy step (see play_step)
    dkCommit ## v66 lever (2): press toward a committed target (see play_step)

  FsParams = object
    valid: bool
    breakDeficit: int32
    coverMax: int32
    engageDist: int32
    finishRange: int32
    pressRange: int32
    woundedPct: int32

var
  params: FsParams
  selfTeam: SdkTeam
  selfSeat: int32
  partnerSeat: int32
  lastKind: DecisionKind
  lastX, lastY: int32
  # v61 lever A state (episode-scoped; reset in play_init, never in
  # play_retune -- a retune is a doctrine-param change, not a new fight).
  lastSeenHp: array[MaxTrackedSeats, int32]  ## -1 = never observed
  persistSeat: int32
  persistUntilTick: int32
  # v66 lever (2) PRESS COMMIT state (episode-scoped; reset in play_init,
  # never in play_retune, same discipline as lever A's persist* vars above
  # -- fully independent bookkeeping from lever A's so NOFIREPERSIST and
  # NOPRESSCOMMIT stay orthogonal, per the house "no opt-out silently
  # disables another" rule (see NOFSWHEN's own comment in policy.py)).
  lastSeenHpCommit: array[MaxTrackedSeats, int32]  ## -1 = never observed
  commitSeat: int32
  commitLastSeenTick: int32
  commitLastPos: SdkPoint
  # v68 lever (3) RANGE COMMIT state -- same discipline, independent
  # bookkeeping from lever (2)'s commit* vars above (NOPRESSCOMMIT and
  # NORANGECOMMIT stay orthogonal).
  lastSeenHpRange: array[MaxTrackedSeats, int32]  ## -1 = never observed
  rangeCommitSeat: int32
  rangeCommitLastSeenTick: int32
  rangeCommitLastHp: int32  ## high(int32) = unknown
  # v68 lever (2) FAST SHOT: which seat we last committed the PRESS
  # FIRE/RANGE FIRE bypass to, episode-scoped so re-engaging a target we
  # only just lost keeps counting as the SAME engagement -- reset in
  # play_init only.
  lastFastShotSeat: int32
  # v68 lever (2): this TICK's idle-aim hint (see play_step), a plain
  # per-tick scratch value, not episode state -- reset unconditionally at
  # the top of every play_step, before the zone-escape early return, so a
  # stale hint from a prior tick's engagement can never leak into an
  # unrelated emission. -1 = no hint (falls back to play_sdk's own
  # emitHoldController/emitNavigateController, byte-identical to pre-v68).
  currentAimHint: int32
  # v68 lever (4) TOOK-DAMAGE / HITBACK state (episode-scoped; reset in
  # play_init, never in play_retune, same discipline as every other lever's
  # own state in this file).
  lastSelfHp: int32       ## -1 = never observed
  hitbackUntilTick: int32

proc play_manifest*() {.exportc, cdecl.} =
  discard emitRaw(ManifestBytes)

proc absI64(value: int64): int64 {.inline.} =
  if value < 0: -value else: value

proc minI(a, b: int32): int32 {.inline.} =
  if a < b: a else: b

proc maxI(a, b: int32): int32 {.inline.} =
  if a > b: a else: b

proc clampI(value, lo, hi: int32): int32 {.inline.} =
  if value < lo: lo
  elif value > hi: hi
  else: value

proc sq(value: int32): int64 {.inline.} =
  int64(value) * int64(value)

proc distSq(a, b: SdkPoint): int64 {.inline.} =
  sq(a.x - b.x) + sq(a.y - b.y)

proc withinFireCone(origin, aimAt, other: SdkPoint): bool =
  ## Mirrors the engine's `sprayContains` (src/shell/body.nim) for the case
  ## that matters here: a body standing at `origin` and aiming straight at
  ## `aimAt` (an actual track position, exactly what happens once this play
  ## presses into range and the phase-4 selector commits to that seat).
  ## `other` is caught if it falls in the same forward-widening triangle.
  ## No sqrt (this runtime carries no libm): the shared |aimAt-origin|
  ## factor is cancelled algebraically instead of normalized away --
  ## tests/test_shell_body_spray_cone.nim cross-checks this against the
  ## real `sprayContains` across a grid of points and aim angles.
  let
    dx = int64(aimAt.x - origin.x)
    dy = int64(aimAt.y - origin.y)
    dSq = dx * dx + dy * dy
  if dSq <= 0:
    return false
  let
    vx = int64(other.x - origin.x)
    vy = int64(other.y - origin.y)
    forward = vx * dx + vy * dy
    cross = vx * dy - vy * dx
  if forward <= 0:
    return false
  if forward * forward > ArcFireRangePx * ArcFireRangePx * dSq:
    return false
  2'i64 * ArcFireRangePx * absI64(cross) <= ArcMaxWidthPx * forward

proc quadrantSector(adx, ady: int64): int32 =
  if ady * SlopeScale <= adx * Tan1125: 0
  elif ady * SlopeScale < adx * Tan3375: 1
  elif ady * SlopeScale <= adx * Tan5625: 2
  elif ady * SlopeScale < adx * Tan7875: 3
  else: 4

proc sectorTo(a, b: SdkPoint): int32 =
  ## Same 16-sector classification as the host cover scorer.
  let dx = b.x - a.x
  let dy = b.y - a.y
  let offset = quadrantSector(absI64(int64(dx)), absI64(int64(dy)))
  if dx == 0 and dy == 0: 0
  elif dx >= 0:
    if dy >= 0: offset else: (16 - offset) mod 16
  elif dy >= 0: 8 - offset
  else: 8 + offset

proc sectorGap(a, b: int32): int32 =
  let d = ((a - b) mod 16 + 16) mod 16
  if d > 8: 16 - d else: d

proc projectFrom(origin, toward: SdkPoint; distance: int32): SdkPoint =
  ## `distance` px from `origin` toward `toward`, Manhattan-normalized
  ## (jackal's own helper; exact bearing precision is not load-bearing --
  ## the goal goes through nearestReachable anyway).
  result = origin
  let
    dx = toward.x - origin.x
    dy = toward.y - origin.y
    ax = if dx < 0: -dx else: dx
    ay = if dy < 0: -dy else: dy
  if ax + ay <= 0:
    return
  result.x = origin.x + int32((int64(dx) * int64(distance)) div int64(ax + ay))
  result.y = origin.y + int32((int64(dy) * int64(distance)) div int64(ax + ay))

proc keyIs(buf: ptr UncheckedArray[byte]; start, length: int32;
           expected: static[string]): bool =
  if length != expected.len.int32:
    return false
  for index in 0 ..< expected.len:
    if char(buf[start + index.int32]) != expected[index]:
      return false
  true

proc readParams(dataPtr, dataLen: int32): FsParams =
  ## Strict reader over the canonical params bytes; missing keys keep the
  ## manifest defaults, anything undeclared or out of range is invalid.
  result = FsParams(valid: true, breakDeficit: EffectiveBreakDeficitDefault,
    coverMax: 260, engageDist: 600, finishRange: 140, pressRange: 220,
    woundedPct: 50)
  if dataLen <= 0:
    return
  let buf = cast[ptr UncheckedArray[byte]](dataPtr)
  var pos = 0'i32
  template cur(): char =
    (if pos < dataLen: char(buf[pos]) else: '\0')
  template fail() =
    result.valid = false
    return
  if cur() != '{': fail()
  inc pos
  if cur() == '}':
    inc pos
    result.valid = pos == dataLen
    return
  while true:
    if cur() != '"': fail()
    inc pos
    let keyStart = pos
    while pos < dataLen and char(buf[pos]) != '"':
      inc pos
    if pos >= dataLen: fail()
    let keyLen = pos - keyStart
    inc pos
    if cur() != ':': fail()
    inc pos
    var value = 0'i32
    var digits = 0
    while cur() in {'0' .. '9'}:
      if digits >= 6: fail()
      value = value * 10 + int32(ord(cur()) - ord('0'))
      inc digits
      inc pos
    if digits == 0: fail()
    if buf.keyIs(keyStart, keyLen, "breakDeficit"):
      result.breakDeficit = value
      if value < 1 or value > 8: result.valid = false
    elif buf.keyIs(keyStart, keyLen, "coverMax"):
      result.coverMax = value
      if value > 600: result.valid = false
    elif buf.keyIs(keyStart, keyLen, "engageDist"):
      result.engageDist = value
      if value < 100 or value > 1200: result.valid = false
    elif buf.keyIs(keyStart, keyLen, "finishRange"):
      result.finishRange = value
      if value < 40 or value > 260: result.valid = false
    elif buf.keyIs(keyStart, keyLen, "pressRange"):
      result.pressRange = value
      if value < 60 or value > 500: result.valid = false
    elif buf.keyIs(keyStart, keyLen, "woundedPct"):
      result.woundedPct = value
      if value > 100: result.valid = false
    else:
      result.valid = false
    if cur() == ',':
      inc pos
      continue
    break
  if cur() != '}': fail()
  inc pos
  if pos != dataLen: result.valid = false

# v68 lever (2) FAST SHOT: a small LOCAL canonical-intent writer, built only
# from play_sdk's already-exported emitRaw(bytes: openArray[byte]) -- the
# convenience wrappers emitHoldController/emitNavigateController (play_sdk/
# play.nim) have no idle_aim_center_brads parameter, and their own internal
# byte buffer (emitBuffer/appendByte/appendInt/clearEmitBuffer) is module-
# private, so play_sdk itself stays untouched (per the task's own scope).
# Field order/shape matches intent.schema.json and emit_validator.nim's
# parseIntent (a name-keyed `case key of ...` reader over CanonicalReader --
# object key ORDER is not semantically required for acceptance, but this
# still emits the schema's documented byte-wise-ascending order:
# arrive_radius, idle_aim_center_brads, kind, point, reason, schema, v).
const IntentBufferBytes = 192'i32  ## generous headroom over any point/reason/brads
var
  intentBuf: array[IntentBufferBytes, byte]
  intentLen: int32

proc iClear() {.inline.} =
  intentLen = 0

proc iByte(value: byte) {.inline.} =
  if intentLen < IntentBufferBytes:
    intentBuf[intentLen] = value
    inc intentLen

template iLiteral(text: static[string]) =
  for ch in text:
    iByte(byte(ord(ch)))

proc iInt(value: int32) =
  if value == 0:
    iByte(byte(ord('0')))
    return
  var digits: array[12, byte]
  var remaining = value
  var count = 0
  if remaining < 0:
    iByte(byte(ord('-')))
    remaining = -remaining
  while remaining > 0:
    digits[count] = byte(ord('0') + remaining mod 10)
    remaining = remaining div 10
    inc count
  while count > 0:
    dec count
    iByte(digits[count])

proc emitIntentWithAim(hasGoal: bool; gx, gy: int32;
                        arriveRadius: static[string]; aimBrads: int32;
                        reason: static[string]): int32 =
  ## Only called with aimBrads in 0..255 (sectorTo(...)*16, see play_step) --
  ## callers never pass a raw/unclamped value in here.
  iClear()
  iLiteral("{\"arrive_radius\":")
  iLiteral(arriveRadius)
  iLiteral(",\"idle_aim_center_brads\":")
  iInt(aimBrads)
  if hasGoal:
    iLiteral(",\"kind\":\"navigate_to\",\"point\":[")
    iInt(gx)
    iByte(byte(ord(',')))
    iInt(gy)
    iByte(byte(ord(']')))
  else:
    iLiteral(",\"kind\":\"hold\"")
  when reason.len > 0:
    iLiteral(",\"reason\":\"")
    iLiteral(reason)
    iByte(byte(ord('"')))
  iLiteral(",\"schema\":\"intent\",\"v\":1}")
  emitRaw(intentBuf.toOpenArray(0, intentLen - 1))

proc sameDecision(kind: DecisionKind; x = 0'i32; y = 0'i32): bool =
  lastKind == kind and (kind == dkHold or (lastX == x and lastY == y))

proc remember(kind: DecisionKind; x = 0'i32; y = 0'i32) =
  lastKind = kind
  lastX = x
  lastY = y

proc emitHoldIfChanged(
    reason: static[string] = "fire_superiority:hold"): int32 =
  if sameDecision(dkHold):
    resetArena()
    return 0
  let code =
    if currentAimHint >= 0:
      emitIntentWithAim(false, 0'i32, 0'i32, "0.0", currentAimHint, reason)
    else:
      emitHoldController(reason)
  if code < 0:
    return code
  remember(dkHold)
  resetArena()
  0

proc emitGoal(kind: DecisionKind; goal: ValidatedGoal;
              reason: static[string]): int32 =
  if sameDecision(kind, goal.x, goal.y):
    resetArena()
    return 0
  let code =
    if currentAimHint >= 0:
      emitIntentWithAim(true, goal.x, goal.y, "24.0", currentAimHint, reason)
    else:
      emitNavigateController(goal, "24.0", reason)
  if code < 0:
    return code
  remember(kind, goal.x, goal.y)
  resetArena()
  0

proc loadParams(dataPtr, dataLen: int32; clearCache: bool): int32 =
  let decoded = readParams(dataPtr, dataLen)
  if not decoded.valid:
    return 1
  params = decoded
  if clearCache:
    lastKind = dkNone
    lastX = 0
    lastY = 0
  0

proc loadContext(ctxPtr, ctxLen: int32) =
  var decoded: SdkContext
  selfTeam = stUnknown
  selfSeat = -1
  partnerSeat = -1
  if readBinaryContextInto(context(ctxPtr, ctxLen), decoded):
    if decoded.selfTeamPresent:
      selfTeam = decoded.selfTeam
    if decoded.selfSeatPresent:
      selfSeat = decoded.selfSeat
    if decoded.duoPartnerPresent:
      partnerSeat = decoded.duoPartner

proc play_init*(paramsPtr, paramsLen, ctxPtr, ctxLen: int32): int32 {.
    exportc, cdecl.} =
  resetArena()
  loadContext(ctxPtr, ctxLen)
  # v61 lever A: fresh episode, fresh persist memory -- a hp drop observed
  # in a PRIOR episode must never arm this one's no-break window.
  for i in 0 ..< MaxTrackedSeats:
    lastSeenHp[i] = -1'i32
    lastSeenHpCommit[i] = -1'i32  ## v66 lever (2): same discipline
    lastSeenHpRange[i] = -1'i32   ## v68 lever (3): same discipline
  persistSeat = -1'i32
  persistUntilTick = -1'i32
  commitSeat = -1'i32            ## v66 lever (2)
  commitLastSeenTick = -1'i32
  commitLastPos = SdkPoint(present: false, x: 0, y: 0)
  rangeCommitSeat = -1'i32       ## v68 lever (3)
  rangeCommitLastSeenTick = -1'i32
  rangeCommitLastHp = high(int32)
  lastFastShotSeat = -1'i32      ## v68 lever (2)
  currentAimHint = -1'i32        ## v68 lever (2)
  lastSelfHp = -1'i32             ## v68 lever (4)
  hitbackUntilTick = -1'i32
  loadParams(paramsPtr, paramsLen, true)

const ZoneInsetPx = 64'i32

proc zoneTargets(decoded: SdkView; clamped, biased: var SdkPoint) =
  ## Outside the current safe zone nothing else matters: the re-entry point
  ## is self clamped into the rect (inset), plus a center-biased variant --
  ## both are only ever emitted through nearest_reachable, which resolves to
  ## self's own connectivity component (owner field report 2026-09-02: raw
  ## clamp beelines cornered us in building pockets).
  clamped.present = false
  biased.present = false
  let zone = decoded.world.zone.current
  if not zone.present or not decoded.self.pos.present:
    return
  let
    lox = minI(zone.x1, zone.x2)
    hix = maxI(zone.x1, zone.x2)
    loy = minI(zone.y1, zone.y2)
    hiy = maxI(zone.y1, zone.y2)
  if decoded.self.pos.x >= lox and decoded.self.pos.x <= hix and
      decoded.self.pos.y >= loy and decoded.self.pos.y <= hiy:
    return                        # already inside: no zone move
  let
    ix = minI(ZoneInsetPx, (hix - lox) div 2)
    iy = minI(ZoneInsetPx, (hiy - loy) div 2)
  clamped.present = true
  clamped.x = clampI(decoded.self.pos.x, lox + ix, hix - ix)
  clamped.y = clampI(decoded.self.pos.y, loy + iy, hiy - iy)
  biased.present = true
  biased.x = (clamped.x + (lox + hix) div 2) div 2
  biased.y = (clamped.y + (loy + hiy) div 2) div 2

proc play_step*(viewPtr, viewLen: int32): int32 {.exportc, cdecl.} =
  var decoded: SdkView
  if not readBinaryViewInto(view(viewPtr, viewLen), decoded):
    return 1
  currentAimHint = -1'i32  ## v68 lever (2): reset every tick, before any emit
  if not decoded.self.pos.present or
      (decoded.self.alivePresent and not decoded.self.alive):
    return emitHoldIfChanged()

  # Zone discipline first: no press and no break is worth standing in the
  # storm for -- walk back inside by reachable targets only (center-biased
  # request first, raw clamp second; 2 calls = MaxSpatialCallsPerStep).
  var zClamped, zBiased: SdkPoint
  zoneTargets(decoded, zClamped, zBiased)
  if zClamped.present:
    var goal = nearestReachable(zBiased.x, zBiased.y)
    if not goal.ok:
      goal = nearestReachable(zClamped.x, zClamped.y)
    if goal.ok:
      return emitGoal(dkZone, goal, "fire_superiority:zone")
    return emitHoldIfChanged()

  # Count the guns we can SEE (fog-honest; unknown hp is HEALTHY).
  var theirGuns = 0'i32
  var wounded = 0'i32
  var partnerFresh = false
  var partnerPos: SdkPoint
  var nearestFound = false
  var nearest: SdkPoint
  var nearestDistSq = high(int64)
  var candCount = 0'i32
  var candPos: array[MaxCandidates, SdkPoint]
  var candHp: array[MaxCandidates, int32]
  var candSeat: array[MaxCandidates, int32]  ## v61 lever A: persist lookup
  for index in 0 ..< decoded.trackCount:
    let track = decoded.tracks[index]
    if not track.pos.present:
      continue
    let fresh = not (track.freshTickPresent and decoded.tickPresent and
      decoded.tick - track.freshTick > FreshGunTicks)
    let ally = (track.seatPresent and track.seat == partnerSeat and
        partnerSeat >= 0) or
      (track.teamPresent and selfTeam != stUnknown and track.team == selfTeam)
    if track.seatPresent and track.seat == selfSeat:
      continue
    if ally:
      # v-next: alive somewhere on the map is not "in this fight" -- hold
      # the partner to the same engageDist enemies already clear (see the
      # file header's "our guns" note).
      if fresh and not (track.hpPresent and track.hp <= 0) and
          distSq(decoded.self.pos, track.pos) <= sq(params.engageDist):
        partnerFresh = true
        partnerPos = track.pos
      continue
    if not fresh:
      continue
    let d = distSq(decoded.self.pos, track.pos)
    if d > sq(params.engageDist):
      continue
    inc theirGuns
    let hpKnown = track.hpPresent
    if hpKnown and track.hp <= WoundedHpMax:
      inc wounded
    if not NOFIREPERSIST and track.seatPresent and decoded.tickPresent:
      # v61 lever A: a fresh, in-range enemy's known hp just dropped since
      # we last saw them -- a fog-honest proxy for "we (or our duo)
      # landed a tag on them" (this play has no direct hit-confirm signal;
      # same fog-honesty convention the "our guns"/"their guns" counts
      # above already use). Arms the no-break window read below.
      let seat = track.seat
      if seat >= 0 and seat < MaxTrackedSeats:
        if hpKnown and lastSeenHp[seat] >= 0 and track.hp < lastSeenHp[seat]:
          persistSeat = seat
          persistUntilTick = decoded.tick + FirePersistTicks
        if hpKnown:
          lastSeenHp[seat] = track.hp
    if not NOPRESSCOMMIT and track.seatPresent and decoded.tickPresent:
      # v66 lever (2): same fog-honest hp-drop proxy as lever A above, but
      # independent bookkeeping (lastSeenHpCommit, not lastSeenHp) and
      # scoped to a hit landed WITH the target inside pressRange -- lever
      # A's window is engageDist-wide and time-boxed; this one is
      # unconditional-in-band (see commitHolds below) and needs its own
      # arm signal. Also keeps commitSeat's last-seen tick/position fresh
      # on every sighting (not just the hit tick), and clears it outright
      # once the target's hp reads <=0 (confirmed dead, not just lost).
      let seat = track.seat
      if seat >= 0 and seat < MaxTrackedSeats:
        let hpDropped = hpKnown and lastSeenHpCommit[seat] >= 0 and
          track.hp < lastSeenHpCommit[seat]
        if hpDropped and d <= sq(params.pressRange):
          commitSeat = seat
          commitLastSeenTick = decoded.tick
          commitLastPos = track.pos
        elif seat == commitSeat:
          if hpKnown and track.hp <= 0:
            commitSeat = -1'i32
            commitLastSeenTick = -1'i32
          else:
            commitLastSeenTick = decoded.tick
            commitLastPos = track.pos
        if hpKnown:
          lastSeenHpCommit[seat] = track.hp
    if not NORANGECOMMIT and track.seatPresent and decoded.tickPresent:
      # v68 lever (3): same fog-honest hp-drop arm signal as PRESS COMMIT
      # above, but scoped to the NEW 220-500px sub-band specifically (a hit
      # already inside pressRange keeps arming PRESS COMMIT above,
      # untouched) and independent bookkeeping (lastSeenHpRange). Tracks
      # the target's own hp (rangeCommitLastHp), not just a position --
      # rangeCommitHolds below compares it against self.hp directly.
      let seat = track.seat
      if seat >= 0 and seat < MaxTrackedSeats:
        let hpDropped = hpKnown and lastSeenHpRange[seat] >= 0 and
          track.hp < lastSeenHpRange[seat]
        if hpDropped and d > sq(params.pressRange) and
            d <= sq(RangeFireBandPx):
          rangeCommitSeat = seat
          rangeCommitLastSeenTick = decoded.tick
          if hpKnown:
            rangeCommitLastHp = track.hp
        elif seat == rangeCommitSeat:
          if hpKnown and track.hp <= 0:
            rangeCommitSeat = -1'i32
            rangeCommitLastSeenTick = -1'i32
          else:
            rangeCommitLastSeenTick = decoded.tick
            if hpKnown:
              rangeCommitLastHp = track.hp
        if hpKnown:
          lastSeenHpRange[seat] = track.hp
    if not nearestFound or d < nearestDistSq:
      nearestFound = true
      nearest = track.pos
      nearestDistSq = d
    if candCount < MaxCandidates:
      candPos[candCount] = track.pos
      candHp[candCount] = if hpKnown: track.hp else: high(int32)
      candSeat[candCount] = if track.seatPresent: track.seat else: -1'i32
      inc candCount

  if theirGuns == 0:
    # No live contact: the ladder guard normally keeps us from owning this.
    return emitHoldIfChanged()

  # v68 lever (2) FAST SHOT: arm this tick's idle-aim hint toward `nearest`
  # (the same track already driving the BREAK branch's cover bearing below)
  # -- see NOFASTSHOT's own comment for why. Every emitGoal/emitHoldIfChanged
  # call from here on picks this up automatically (see their own bodies);
  # nothing below this line needs to thread it through by hand.
  if not NOFASTSHOT:
    currentAimHint = sectorTo(decoded.self.pos, nearest) * 16

  # v68 lever (4) TOOK-DAMAGE / HITBACK: arm on a CONFIRMED drop in our own
  # hp since we last evaluated it -- same fog-honest hp-drop convention as
  # every enemy-hp-drop proxy in this file, mirrored onto self.hp instead.
  if not NOHITBACK and decoded.self.hpPresent and decoded.tickPresent:
    if lastSelfHp >= 0 and decoded.self.hp < lastSelfHp:
      hitbackUntilTick = decoded.tick + HitbackTicks
    lastSelfHp = decoded.self.hp

  let ourGuns = 1'i32 + (if partnerFresh: 1'i32 else: 0'i32)
  let superior = ourGuns > theirGuns or
    (ourGuns >= theirGuns and wounded * 100 >= params.woundedPct * theirGuns)
  let baseInferior = theirGuns - ourGuns >= params.breakDeficit

  # v61 lever A: no-break window -- if we tagged persistSeat within the
  # last FirePersistTicks AND that seat is STILL a live, fresh, in-range
  # candidate THIS tick (membership in candCount already requires that --
  # the loop above only adds fresh, in-engageDist enemy tracks to it),
  # suppress BREAK regardless of baseInferior: commit through the kill
  # instead of handing a winnable fight to one lost exchange. Expires the
  # moment persistSeat dies, loses track, ages out of engageDist, or the
  # window itself elapses -- no separate "target died" signal needed.
  var persistHolds = false
  if not NOFIREPERSIST and persistSeat >= 0 and decoded.tickPresent and
      decoded.tick <= persistUntilTick:
    for i in 0 ..< candCount:
      if candSeat[i] == persistSeat:
        persistHolds = true
        break

  # v68 lever (3) RANGE COMMIT (opt-out NORANGECOMMIT): "do not break off
  # while the target is alive, tracked, and our HP >= theirs" (task's own
  # wording) for a hit landed in the 220-500px sub-band (rangeCommitSeat,
  # armed in the loop above). Only ever suppresses BREAK, same shape as
  # lever A's persistHolds -- composes as a third term below, never forces
  # a press the way PRESS FIRE/PRESS COMMIT do.
  let rangeCommitHolds = not NORANGECOMMIT and rangeCommitSeat >= 0 and
    decoded.tickPresent and
    decoded.tick - rangeCommitLastSeenTick <= CommitLostTicks and
    decoded.self.hpPresent and rangeCommitLastHp != high(int32) and
    decoded.self.hp >= rangeCommitLastHp

  # v68 lever (4) HITBACK: "no retreat intent... unless HP < 30%" -- released
  # early only once self hp fraction CONFIRMS below CommitHpFloorScaled;
  # unknown hp fraction is treated as "not yet confirmed low" (same
  # fog-honest convention commitHolds above already uses).
  let hitbackHolds = not NOHITBACK and decoded.tickPresent and
    decoded.tick <= hitbackUntilTick and
    not (decoded.self.hpFracPresent and
         decoded.self.hpFracScaled < CommitHpFloorScaled)

  let inferior = baseInferior and not persistHolds and not rangeCommitHolds and
    not hitbackHolds

  # v66 lever (2) PRESS COMMIT (opt-out NOPRESSCOMMIT): unconditional --
  # ignores breakDeficit/baseInferior entirely (unlike lever A's
  # persistHolds above, which only suppresses BREAK while baseInferior
  # would otherwise fire) -- true whenever a hit we landed inside
  # pressRange is still fresh (CommitLostTicks grace since commitSeat was
  # last sighted, tracked in the loop above) and our own hp hasn't
  # confirmed-dropped below CommitHpFloorScaled. Self hp unknown
  # (hpFracPresent false) is treated as "not yet confirmed low" -- keep
  # holding, matching this file's existing fog-honest convention of never
  # breaking off on an absence of evidence. Consumed below, both right
  # after this gate (in place of `superior`'s multi-target selection when
  # that doesn't apply) and again after it (in place of `inferior`'s
  # BREAK) -- see the two new branches.
  let commitHolds = not NOPRESSCOMMIT and commitSeat >= 0 and
    decoded.tickPresent and
    decoded.tick - commitLastSeenTick <= CommitLostTicks and
    not (decoded.self.hpFracPresent and
         decoded.self.hpFracScaled < CommitHpFloorScaled)

  # v66 lever (1) PRESS FIRE (opt-out NOPRESSFIRE) widened by v68 lever (1)
  # RANGE FIRE (opt-out NORANGEFIRE): a live tracked enemy is already
  # inside the fire-gate band -- we have a shot by the same fog-honest
  # freshness proxy the candidate loop above already uses to populate
  # candPos/candHp (no LOS primitive is exposed to a policy, see the file
  # header). Bypasses the `superior` gate right below (only PRESSes when
  # we out-count or out-wound them) and the `inferior` BREAK branch further
  # down (theirGuns/ourGuns deficit alone can send us to cover even with a
  # live target already this close) for this band specifically: fire now
  # instead of first winning the gun-count argument. Target = nearest
  # candidate inside the band, or a lower-hp one if it sits within 20%
  # of the nearest one's distance (1.44 = 1.2^2 applied to distSq) --
  # never chase a farther kill past a closer live gun. NORANGEFIRE alone
  # reverts fireGateBandSq to pressRange, matching v66 byte-for-byte here
  # (inPress is then always true -- `rangefire` can never be tagged).
  let fireGateBandSq =
    if NORANGEFIRE: sq(params.pressRange) else: sq(RangeFireBandPx)
  if not NOPRESSFIRE and nearestFound and nearestDistSq <= fireGateBandSq:
    var pfIdx = -1'i32
    var pfDistSq = high(int64)
    for i in 0 ..< candCount:
      let d = distSq(decoded.self.pos, candPos[i])
      if d <= fireGateBandSq and d < pfDistSq:
        pfIdx = i
        pfDistSq = d
    if pfIdx >= 0:
      let distCeil = (pfDistSq * 36'i64) div 25'i64
      for i in 0 ..< candCount:
        let d = distSq(decoded.self.pos, candPos[i])
        if d <= fireGateBandSq and d <= distCeil and
            candHp[i] < candHp[pfIdx]:
          pfIdx = i
      let band = if candHp[pfIdx] <= WoundedHpMax: params.finishRange
                 else: params.pressRange
      let chosenDistSq = distSq(decoded.self.pos, candPos[pfIdx])
      let inPress = chosenDistSq <= sq(params.pressRange)
      # v68 lever (2) FAST SHOT: the first tick we commit PRESS FIRE/RANGE
      # FIRE to a seat we were NOT already pressing is a new engagement --
      # tag it distinctly (fire_superiority:fastshot) instead of press/
      # rangefire, exactly the tick the aim hint (armed above) had the most
      # rotation to save. NOFASTSHOT alone keeps every tick on press/
      # rangefire, matching v68-minus-lever-2 exactly.
      let chosenSeat = candSeat[pfIdx]
      let freshContact = not NOFASTSHOT and chosenSeat >= 0 and
        chosenSeat != lastFastShotSeat
      if freshContact:
        lastFastShotSeat = chosenSeat
      if chosenDistSq <= sq(band):
        if freshContact:
          return emitHoldIfChanged("fire_superiority:fastshot")
        if inPress:
          return emitHoldIfChanged("fire_superiority:press")
        return emitHoldIfChanged("fire_superiority:rangefire")
      let stand = projectFrom(candPos[pfIdx], decoded.self.pos, band)
      let goal = nearestReachable(stand.x, stand.y)
      if goal.ok:
        if freshContact:
          return emitGoal(dkPress, goal, "fire_superiority:fastshot")
        if inPress:
          return emitGoal(dkPress, goal, "fire_superiority:press")
        return emitGoal(dkPress, goal, "fire_superiority:rangefire")
      if freshContact:
        return emitHoldIfChanged("fire_superiority:fastshot")
      if inPress:
        return emitHoldIfChanged("fire_superiority:press")
      return emitHoldIfChanged("fire_superiority:rangefire")

  # v68 lever (4) TOOK-DAMAGE / HITBACK: unconditional press toward
  # `nearest`, bypassing superior/inferior exactly like PRESS FIRE/RANGE
  # FIRE above. RANGE FIRE's own gate (<=500px) already returned above for
  # most hitback ticks (same precedent as v66's PRESS COMMIT residual branch
  # vs PRESS FIRE) -- this is the residual: the 500-600px sub-band, or any
  # tick RANGE FIRE's own gate did not reach this time.
  if hitbackHolds and nearestFound:
    var hbIdx = -1'i32
    var hbDistSq = high(int64)
    for i in 0 ..< candCount:
      let d = distSq(decoded.self.pos, candPos[i])
      if d < hbDistSq:
        hbIdx = i
        hbDistSq = d
    if hbIdx >= 0:
      let band = if candHp[hbIdx] <= WoundedHpMax: params.finishRange
                 else: params.pressRange
      if hbDistSq <= sq(band):
        return emitHoldIfChanged("fire_superiority:hitback")
      let stand = projectFrom(candPos[hbIdx], decoded.self.pos, band)
      let goal = nearestReachable(stand.x, stand.y)
      if goal.ok:
        return emitGoal(dkPress, goal, "fire_superiority:hitback")
      return emitHoldIfChanged("fire_superiority:hitback")

  if superior:
    # Choose which live enemy to press, among candCount options, by the
    # actual fire-cone consequence of standing at that press band and
    # aiming at them: never a candidate that would also catch our partner
    # (uncapped compounding loss) unless every candidate does, then prefer
    # whichever candidate's cone also catches the most OTHER enemies
    # (compounding gain) -- see the file header and withinFireCone above.
    # Ties, and the all-unsafe fallback, keep the original lowest-hp /
    # nearest tie-break so behavior is unchanged whenever there is only one
    # live enemy or no partner/cluster distinction to make.
    var bestIdx = 0'i32
    var bestClean = false
    var bestExposed = true
    var bestCluster = -1'i32
    var bestHp = high(int32)
    var bestDistSq = high(int64)
    for i in 0 ..< candCount:
      let band = if candHp[i] <= WoundedHpMax: params.finishRange
                 else: params.pressRange
      let stand = projectFrom(candPos[i], decoded.self.pos, band)
      var cluster = 0'i32
      for j in 0 ..< candCount:
        if j != i and withinFireCone(stand, candPos[i], candPos[j]):
          inc cluster
      let clean = not (partnerFresh and
        withinFireCone(stand, candPos[i], partnerPos))
      # PARTNER-LINE EXPOSURE (v-next): would this stand point sit in a
      # plausible partner fire line -- the partner aiming at some OTHER
      # visible enemy? See the file header; a proxy, not a read of their
      # actual aim. Ranked below `clean` (protecting the partner from OUR
      # fire still comes first) but above the cluster/hp/distance ties.
      var exposed = false
      if partnerFresh:
        for k in 0 ..< candCount:
          if k != i and withinFireCone(partnerPos, candPos[k], stand):
            exposed = true
            break
      let d = distSq(decoded.self.pos, candPos[i])
      let better =
        if i == 0: true
        elif clean != bestClean: clean
        elif exposed != bestExposed: not exposed
        elif cluster != bestCluster: cluster > bestCluster
        elif candHp[i] != bestHp: candHp[i] < bestHp
        else: d < bestDistSq
      if better:
        bestIdx = i
        bestClean = clean
        bestExposed = exposed
        bestCluster = cluster
        bestHp = candHp[i]
        bestDistSq = d

    # PRESS to the range band; inside it the body finishes the work. A
    # target we KNOW is wounded (hp <= WoundedHpMax) is worth closing to
    # finishRange for -- the inverted-accuracy risk is against a live gun
    # that can still out-trade us, not one already this close to done.
    # Unknown-hp and healthy targets keep the wider pressRange band.
    let target = candPos[bestIdx]
    let targetHp = candHp[bestIdx]
    let band = if targetHp <= WoundedHpMax: params.finishRange
               else: params.pressRange
    if bestDistSq <= sq(band):
      return emitHoldIfChanged()
    let stand = projectFrom(target, decoded.self.pos, band)
    let goal = nearestReachable(stand.x, stand.y)
    if not goal.ok:
      return emitHoldIfChanged()
    return emitGoal(dkPress, goal, "fire_superiority:press")

  # v66 lever (2) PRESS COMMIT continued: still committed to a target we
  # already hit inside press range (commitHolds, computed above), but
  # neither lever (1) (the tracked target has since moved back outside
  # pressRange, so that bypass didn't trigger) nor `superior` applied this
  # tick. Press the committed target directly instead of falling through
  # to `inferior`'s BREAK right below, or either of the cover fallbacks
  # further down (heldByPersist's cover-facing branch, the final "even"
  # cover branch) -- no retreat/cover intent while committed, per the
  # lever's own doctrine. Uses commitSeat's CURRENT candidate position
  # when still tracked this tick, else its last-seen position (fresh
  # within the CommitLostTicks grace commitHolds already checked).
  if commitHolds:
    var commitPos = commitLastPos
    var commitHp = high(int32)
    var haveCommitPos = commitLastPos.present
    for i in 0 ..< candCount:
      if candSeat[i] == commitSeat:
        commitPos = candPos[i]
        commitHp = candHp[i]
        haveCommitPos = true
        break
    if haveCommitPos:
      let band = if commitHp <= WoundedHpMax: params.finishRange
                 else: params.pressRange
      if distSq(decoded.self.pos, commitPos) <= sq(band):
        return emitHoldIfChanged("fire_superiority:commit")
      let stand = projectFrom(commitPos, decoded.self.pos, band)
      let goal = nearestReachable(stand.x, stand.y)
      if goal.ok:
        return emitGoal(dkCommit, goal, "fire_superiority:commit")
    return emitHoldIfChanged("fire_superiority:commit")

  if inferior:
    # BREAK to facing cover; never navigate through the enemy bearing.
    if params.coverMax > 0:
      let bearing = sectorTo(decoded.self.pos, nearest) * 16
      let goal = nearestCover(decoded.self.pos.x, decoded.self.pos.y,
        params.coverMax, bearing)
      if goal.ok:
        let goalPoint = SdkPoint(present: true, x: goal.x, y: goal.y)
        if sectorGap(sectorTo(decoded.self.pos, goalPoint),
            sectorTo(decoded.self.pos, nearest)) > 1:
          return emitGoal(dkCover, goal, "fire_superiority:break")
    return emitHoldIfChanged()

  # v61 lever A wire signature: baseInferior was true but persistHolds
  # suppressed it -- we would have broken off; the no-break window kept
  # us in the fight instead. Tagged distinctly below
  # ("fire_superiority:persist"/"fire_superiority:persist-hold") so a
  # read can tell the lever fired, same discipline as every clamp tag
  # elsewhere in this codebase.
  let heldByPersist = baseInferior and persistHolds

  # v68 lever (3) wire signature: baseInferior was true, persistHolds did
  # NOT already cover it (heldByPersist keeps its own exact pre-v68
  # semantics above), and rangeCommitHolds did -- tagged distinctly
  # (`fire_superiority:rangecommit`/`fire_superiority:rangecommit-hold`)
  # below, mirroring heldByPersist's own persist/persist-hold pair.
  let heldByRangeCommit = baseInferior and not persistHolds and rangeCommitHolds

  # v61 lever B (close-on-enemy movement bias, opt-out NOCLOSEBIAS): guns
  # matched (not superior, not held off by BREAK) and a live target is
  # still farther than our own pressRange -- Jordan closes on a tracked
  # enemy 65.2% of moving samples vs our 58.3% (jordan-decode-tables.md).
  # Bounded to the SAME pressRange band the PRESS branch above already
  # presses to (never past it -- never the point-blank band a live,
  # undamaged gun can punish, see the file header's press-target
  # doctrine) and gated off whenever the persist window is already
  # driving this tick (heldByPersist keeps the original "hold at cover,
  # face the bearing" shape so the two levers never fight over the same
  # tick). Only fires while the server's own native zone-escape reflex is
  # judged not about to preempt us: zoneTargets() above already proved
  # self is inside the CURRENT zone rect, so the one remaining
  # reflex-arming risk is the NEXT rect (reflexes.nim
  # zoneActive/ReflexZoneTriggerTicks=72 -- server-internal state, not on
  # our wire; self already inside `next`, or no `next` data at all, is
  # the nearest honest proxy for "nothing to arm toward").
  if not NOCLOSEBIAS and not heldByPersist and not heldByRangeCommit and
      nearestFound and nearestDistSq > sq(params.pressRange):
    let nextZone = decoded.world.zone.next
    let reflexSafe = not nextZone.present or
      (decoded.self.pos.x >= minI(nextZone.x1, nextZone.x2) and
       decoded.self.pos.x <= maxI(nextZone.x1, nextZone.x2) and
       decoded.self.pos.y >= minI(nextZone.y1, nextZone.y2) and
       decoded.self.pos.y <= maxI(nextZone.y1, nextZone.y2))
    if reflexSafe:
      # v66 lever (3) CLOSE INTO PRESS (opt-out NOCLOSEIN): against a
      # confirmed lone target -- exactly one live tracked candidate within
      # CloseInLoneRangePx (500px, the same "1v1" definition W14's read
      # used) -- with our own hp at or above theirs on the shared integer
      # hitPoints scale (self.hp/track.hp; no hpFrac on a track, so this
      # is a proxy, not a true percentage -- same convention WoundedHpMax
      # already uses elsewhere in this file), close past the v61 lever B
      # stop above to CloseInStandPx instead: entries into the press band
      # sit at ~0.6/episode on every build measured (W14), 0.15 below
      # winners' 0.80. Never against 2+ tracked enemies -- loneCount must
      # be exactly 1.
      var standDist = params.pressRange
      var closedIn = false
      if not NOCLOSEIN:
        var loneCount = 0'i32
        var loneIdx = -1'i32
        for i in 0 ..< candCount:
          if distSq(decoded.self.pos, candPos[i]) <= sq(CloseInLoneRangePx):
            inc loneCount
            loneIdx = i
        if loneCount == 1 and decoded.self.hpPresent and
            candHp[loneIdx] != high(int32) and
            decoded.self.hp >= candHp[loneIdx]:
          standDist = CloseInStandPx
          closedIn = true
      let stand = projectFrom(nearest, decoded.self.pos, standDist)
      let goal = nearestReachable(stand.x, stand.y)
      if goal.ok:
        if closedIn:
          return emitGoal(dkClose, goal, "fire_superiority:close_in")
        return emitGoal(dkClose, goal, "fire_superiority:close")

  # Even: hold at cover -- no advancing across open toward the enemy.
  # Also reached whenever v61 lever A's no-break window suppressed what
  # would otherwise have been a BREAK (heldByPersist) -- tagged distinctly
  # below so a read can tell the lever fired.
  if heldByPersist:
    if params.coverMax > 0:
      let bearing = sectorTo(decoded.self.pos, nearest) * 16
      let goal = nearestCover(decoded.self.pos.x, decoded.self.pos.y,
        params.coverMax, bearing)
      if goal.ok:
        let goalPoint = SdkPoint(present: true, x: goal.x, y: goal.y)
        let closes = distSq(goalPoint, nearest) < nearestDistSq
        if not (closes and sectorGap(sectorTo(decoded.self.pos, goalPoint),
            sectorTo(decoded.self.pos, nearest)) <= 1):
          return emitGoal(dkCover, goal, "fire_superiority:persist")
    return emitHoldIfChanged("fire_superiority:persist-hold")

  # v68 lever (3): same shape as the heldByPersist branch just above, for
  # the case where RANGE COMMIT (not lever A's persist window) is the one
  # suppressing what would otherwise have been a BREAK this tick.
  if heldByRangeCommit:
    if params.coverMax > 0:
      let bearing = sectorTo(decoded.self.pos, nearest) * 16
      let goal = nearestCover(decoded.self.pos.x, decoded.self.pos.y,
        params.coverMax, bearing)
      if goal.ok:
        let goalPoint = SdkPoint(present: true, x: goal.x, y: goal.y)
        let closes = distSq(goalPoint, nearest) < nearestDistSq
        if not (closes and sectorGap(sectorTo(decoded.self.pos, goalPoint),
            sectorTo(decoded.self.pos, nearest)) <= 1):
          return emitGoal(dkCover, goal, "fire_superiority:rangecommit")
    return emitHoldIfChanged("fire_superiority:rangecommit-hold")

  if params.coverMax > 0:
    let bearing = sectorTo(decoded.self.pos, nearest) * 16
    let goal = nearestCover(decoded.self.pos.x, decoded.self.pos.y,
      params.coverMax, bearing)
    if goal.ok:
      let goalPoint = SdkPoint(present: true, x: goal.x, y: goal.y)
      let closes = distSq(goalPoint, nearest) < nearestDistSq
      if not (closes and sectorGap(sectorTo(decoded.self.pos, goalPoint),
          sectorTo(decoded.self.pos, nearest)) <= 1):
        return emitGoal(dkCover, goal, "fire_superiority:cover")
  emitHoldIfChanged()

proc play_retune*(oldPtr, oldLen, newPtr, newLen: int32): int32 {.
    exportc, cdecl.} =
  discard oldPtr
  discard oldLen
  resetArena()
  loadParams(newPtr, newLen, true)
