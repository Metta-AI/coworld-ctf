## Baseline capture-the-flag bot for Coworld CTF (8v8, classic two-flag,
## dense-cover arena, FOG-OF-WAR full-map vision).
##
## Speaks the Bitworld Sprite v1 protocol over a websocket. The observation is
## the FULL map in map coordinates, but entities are fogged: an enemy (and an
## enemy carrying our flag) is only streamed while it sits inside OUR vision —
## a forward cone (half-angle ~45 degrees around our AIM ANGLE, unlimited
## range, walls block) plus a small omnidirectional bubble (~90px). Always
## visible: the static map, BOTH flag pedestals (teammates are fogged too),
## our own flag's state (an empty own pedestal means it is stolen), and
## ourselves via the distinct "self <color> right|left" marker. AIM IS
## DECOUPLED FROM MOVEMENT: a continuous per-player aim angle (0..255 brads,
## 0 = east, counter-clockwise on screen) turns while B (CCW) or Select (CW)
## is held at ~5 brads/tick; the d-pad never touches it. The aim drives the
## gun, the vision cone, and the sprite flip, so pointing it is THE core
## tactical decision. The bot keeps a persistent world model on top of that:
##
## - **Nav grid**: the full walkability mask arrives once at init; we erode it
##   by the player footprint into an 8px cell grid and run a cost field
##   (Dijkstra) to any goal, then follow the path with waypoint lookahead.
## - **Cover model**: walkable cells adjacent to an obstacle are "cover
##   cells". Cells a remembered enemy could shoot into (range + coarse LOS)
##   get a soft path cost, so movement naturally advances cover-to-cover and
##   keeps obstacles between us and known threats.
## - **Flag model** (two flags): pedestals are STATIC known positions and
##   pedestal flags are never fogged. Only OUR team can carry the enemy flag,
##   so the "<enemy color> heart" sprite is always visible and fully describes
##   our attack (pedestal / on me / on a mate). Only the enemy can carry OUR
##   heart: the "<my color> heart" sprite on its pedestal means safe, visible
##   off-pedestal is a live thief fix, and ABSENT means stolen by a fogged
##   carrier somewhere between our pedestal and its home edge.
## - **Memory**: visible players are matched to tracks (position, velocity,
##   last-seen tick) that persist through fog, and the last thief fix guides
##   the hunt after the carrier fogs out.
## - **Roles** (deterministic from the per-team seat, 8 seats): a mid QUAD
##   races lanes to the ENEMY pedestal, two flankers route wide and hit the
##   pocket from behind, one overwatch sniper holds a shielded cover post
##   whose peek cell owns the longest firing line over mid — under fog a lane
##   watcher SEES map-wide down its open lane, so overwatch is also the radar
##   — and one home defender guards the choke before our pedestal. The attack
##   wave is deliberately six strong: with no global flag tracking, a carrier
##   that slips the contest is hard to reacquire, so committed offense turns
##   steals into captures. While our flag is stolen the back line hunts the
##   thief along its predicted route toward ITS home edge; attackers press on
##   — captures are instant wins both ways, so the race stays on.
## - **Turret controller**: the bot dead-reckons its own aim (spawn aim is
##   toward the enemy side; each held rotate button turns it 5 brads/tick)
##   and resyncs it every frame from its own rendered aim-indicator dots.
##   Each tick it outputs the rotate button that traverses toward the desired
##   aim by the shortest arc, and fires only when the bullet corridor
##   (~14px half-width) covers the target at its range.
## - **Scanning**: units holding a position (overwatch posts, the defender's
##   choke, cooldown ducks) sweep the aim back and forth across the watch arc
##   with genuine rotate-button sweeps, raking the vision cone over it while
##   standing perfectly still. On the move, the aim leads the movement
##   direction when no target demands it, so attackers watch down-lane.
## - **Peek-and-shoot**: the default combat mode. With the gun up and a
##   remembered enemy blocked by a wall, PRE-LAY the aim on the firing line
##   while stepping sideways to the nearest cell that opens it — the shot is
##   ready the moment the ray clears; during the 12-tick cooldown, duck
##   behind the nearest cover that breaks the threat's line and hold there.
## - **Fire discipline**: the bullet is a corridor hitscan along the aim, so
##   the fire gate is geometric: shoot when the aim error's perpendicular
##   miss at the target's range is inside the corridor. Skip targets with a
##   remembered teammate near the fire axis (friendly fire is on; the server
##   kills the NEAREST player in the corridor).
##
## Coordinate model: the map object sits at (0, 0), so object positions ARE
## map coordinates; we find ourselves via the self marker. Only a fresh A
## press fires, and the aim angle locks at the pull (the bullet leaves after
## a short windup), so we stop rotating on the tick we pull.

when defined(tgtprobe):
  var tpFrames = 0

when defined(perfprobe):
  import std/monotimes, std/times
  var ppFrames = 0
  var ppDecideNs, ppFieldNs, ppNavBuildNs: int64
  var ppFields = 0

import
  std/[algorithm, heapqueue, math, os, random, strutils],
  bitworld/spriteprotocol,
  whisky,
  ctf/labels,
  baseline/protocols

when defined(hsprobe):
  # -d:hsprobe ONLY: count how often the carrierHomeStretch branch fires and how
  # often it actually MOVES the target off the lane-Y it would otherwise use.
  # If fire=0 the trigger never occurs in self-play (field-only, like huntCarrier);
  # if fire>0 but moved=0 the override is a no-op vs the lane path. Never compiled
  # into the shipped player.
  var hsFireCount = 0
  var hsMovedCount = 0

when defined(rgprobe):
  # -d:rgprobe ONLY: instrument the regroupPush gate as a FUNNEL so a 0-fire
  # result is diagnosable (correctly gated & field-only vs dead code / logic bug).
  # Each counter is the count of decide()-frames surviving one more sub-condition.
  # Never compiled into the shipped player.
  var rgMid = 0       # alive mid seat with regroupPush on (the population the guard filters)
  var rgNoCarry = 0   # ...and not iCarry/mateCarry (the suspect gate)
  var rgNoStolen = 0  # ...and own flag not stolen
  var rgReach = 0     # passed the FULL outer guard (also not retreating/pushOut, off the pedestal)
  var rgDeep = 0      # ...and armed (over-extended past the trigger depth)
  var rgVac = 0       # ...and local vacuum (no fresh enemy near)
  var rgLone = 0      # ...and not yet grouped (a real solo over-extension)
  var rgJoin = 0      # ...and support inbound (a fresh mate homeward to wait for)
  var rgFireCount = 0 # ...and uncommitted => the rally-hold actually fired

when defined(gtprobe):
  # -d:gtprobe ONLY: instrument the grabTiming gate as a FUNNEL so a 0-fire result
  # is diagnosable (correctly gated & field-only vs dead code / a stack that never
  # forms in the mirror). Each counter = decide()-frames surviving one more gate.
  # Never compiled into the shipped player.
  var gtWant = 0      # frames a bot geometrically WANTS the pocket rush
  var gtEligible = 0  # ...and grabTiming on, not pushOut, off the commit ring
  var gtStacked = 0   # ...and the pocket is stacked (>=GrabStackDefenders)
  var gtNoCover = 0   # ...and no mate covering in place
  var gtFireCount = 0 # ...and a mate inbound => the hold actually fired

when defined(hlprobe):
  # -d:hlprobe ONLY: instrument the holdLine gate as a FUNNEL so a 0-fire result is
  # diagnosable (correctly gated vs dead code / a line that never forms in the mirror).
  # Each counter = decide()-frames surviving one more sub-condition. Never shipped.
  var hlMid = 0       # alive mid seat with holdLine on (the population the guard filters)
  var hlReach = 0     # ...passed the full outer guard (not carry/stolen/retreat/pushOut, off pedestal)
  var hlDeep = 0      # ...and armed (over-extended past the trigger depth into enemy half)
  var hlLine = 0      # ...and a fresh enemy line is to our front (not an empty vacuum)
  var hlOutgun = 0    # ...and we LACK local fire-superiority (fresh mates near < fresh enemy near)
  var hlLone = 0      # ...and not a lone last body (support genuinely inbound to wait for)
  var hlFireCount = 0 # ...and uncommitted => the line-hold actually fired

when defined(ggprobe):
  # -d:ggprobe ONLY: instrument the grabGate as a FUNNEL so a 0-fire result is
  # diagnosable. Each counter = decide()-frames surviving one more gate. Never shipped.
  var ggWant = 0      # frames a bot geometrically WANTS the pocket rush
  var ggEligible = 0  # ...and grabGate on, not pushOut, off the commit ring, not lone-last
  var ggOutgun = 0    # ...and outgunned locally at the pedestal (deficit >= GrabGateDeficit)
  var ggFireCount = 0 # ...=> the grab-gate actually fired (dive held)

when defined(commsprobe):
  # -d:commsprobe ONLY: prove the comms bus is LIVE — codewords emitted, heard,
  # and adopted. A 0-heard result vs a >0-emit result diagnoses a wire/range gap.
  var csEmit = 0      # frames a bot broadcast a scenario codeword
  var csHeard = 0     # frames a bot decoded a mate's codeword (adopted a play)
  var csAdopt = 0     # frames the adopted heard play actually drove selectScenarioPlay
  var csStack = 0     # local classifications: ScStack
  var csWipe = 0      # ...ScWipe
  var csPeel = 0      # ...ScPeel
  var csLine = 0      # ...ScLine (standing enemy line to our front)
  var csNadeLine = 0  # frames a grenade carrier picked a CLUSTER (line/pocket) target
                      # — the multikill lob that breaks the line before the wave punches
  var csLineArm = 0   # frames a HEARD line armed holdLine's rally without a local line
                      # sighting (the cross-fog convergence the callout buys)
  var csArcSeek = 0   # frames the breacher seat detoured to grab a plasma arc on a line
  var csArcFire = 0   # frames the breacher pressed the cone at a cluster (the multikill)
  var csWipeArm = 0   # frames a HEARD wipe armed regroupPush's rally without a
                      # local over-extend read (the coordination the bus buys —
                      # a trailing mid converges on a wipe it never saw itself)

when defined(ssprobe):
  # -d:ssprobe ONLY (v7): count how often the avoidDisarm repulsion is ACTIVE
  # (a pickup we're not collecting sits inside DisarmAvoidRadius and bends the
  # steer) and how often swordAmbush/shieldTank actually seek/swing. Proves the
  # levers are live code even when accidental grabs are already near zero.
  var ssAvoidActive = 0   # navigate frames where a sword/shield repulsion pushed us
  var ssTankSeek = 0      # frames shieldTank steered toward a shield pickup
  var ssAmbushSeek = 0    # frames swordAmbush steered toward a sword pickup
  var ssAmbushSwing = 0   # frames swordAmbush actually pressed the melee swing

when defined(mtprobe):
  # -d:mtprobe ONLY (v9): instrument the medTopOff gate as a FUNNEL so a 0-fire
  # result is diagnosable (correctly gated & rare vs dead code / a logic bug).
  # Each counter = decide()-frames surviving one more sub-condition. Never
  # compiled into the shipped player.
  var mtOn = 0        # alive frames with medTopOff on and read hp (the population)
  var mtWounded = 0   # ...and wounded (ownHp in 1..<MaxHp)
  var mtSafe = 0      # ...and out of contact (engage<0 and nearThreat<0)
  var mtFree = 0      # ...and not carrier/grabber/escort/stolen-flag (a free bot)
  var mtVisible = 0   # ...and a med-kit pickup is visible at all this frame
  var mtFireCount = 0 # ...and one sits within MedKitDetour => the detour actually fired

when defined(meprobe):
  # -d:meprobe ONLY (2026-07-28): instrument the medEcon gate as a FUNNEL, the same
  # way mtprobe does for medTopOff, so "did the fix actually open the gate?" is a
  # measurement and not a guess. The whole point of medEcon is that medTopOff's
  # funnel collapsed at mtSafe/mtVisible; compare meSafe/meFireCount against those.
  # Never compiled into the shipped player.
  var meOn = 0         # alive frames with medEcon on and read hp (the population)
  var meWounded = 0    # ...and wounded (ownHp in 1..<MaxHp)
  var meFree = 0       # ...and not carrier/grabber/escort/stolen-flag/pickup-seeker
  var meLightBreak = 0 # ...and IN contact but at 1 hp with no gun on us (the new case)
  var meSafe = 0       # ...and cleared the contact rule (out of contact or light-break)
  var meFireCount = 0  # ...and a known kit sits within MedKitEconDetour => fired

when defined(msprobe):
  # -d:msprobe ONLY (plan #16): instrument medSee — does routing medEcon at a kit
  # we can SEE actually change the chosen target, and does it convert into heals?
  # Two families of counter:
  #   * AVAILABILITY (msVis*) runs whether or not the tune bit is set, so one
  #     binary measures ON and OFF apples-to-apples on the same seeds;
  #   * PICK (msPick*) counts which family supplied the target medEcon committed to.
  # Plus a tune-INDEPENDENT heal funnel in damageSense, so heals/10k wounded frames
  # is comparable to the FIELD unit (ours 2.4, richard 7.0). Never shipped.
  var msScan = 0        # medEcon frames that cleared every veto and reached the scan
  var msVisAny = 0      # ...with >=1 HUD-filtered visible kit sprite in view
  var msVisNear = 0     # ...with >=1 visible kit inside MedKitEconDetour
  var msVisOffSpot = 0  # ...with >=1 visible kit inside the detour and OFF both formula spots
  var msFire = 0        # ...and medEcon actually set a target (either family)
  var msPickSpot = 0    # ...target came from the two hard-coded formula spots
  var msPickVis = 0     # ...target came from the VISIBLE family (the new branch)
  var msPickVisOff = 0  # ...and that visible kit is NOT at a formula spot  <= THE counter
  var msWoundedFrames = 0  # tune-independent: frames our own hp read 1..<MaxHp
  var msHeals = 0          # tune-independent: wounded -> full transitions (a kit taken)

const MedSeeProbeScan* = defined(msprobe)
  ## Compile-time only: under -d:msprobe the medEcon block walks the VISIBLE-kit
  ## scan even with the lever OFF, so ONE binary measures availability ON and OFF
  ## on the same seeds. It never selects a target unless bot.tune.medSee is set,
  ## and folds to `false` in every shipped build.

when defined(wbprobe):
  # -d:wbprobe ONLY (plan #13): instrument woundedBank as a FUNNEL plus the
  # hp-1 SEGMENT FATE metric (the plan's §3.1 mechanism probe). Counters are
  # module globals shared across the in-process harness's 16 bots — common-mode
  # is fine for "does it fire". The hp-1 segment counters run tune-independent
  # so a WBANK-unset run of the same binary is the control. Never compiled into
  # the shipped player.
  var wbAllFrames = 0      # alive decide frames with a read hp (dump clock)
  var wbEntries = 0        # FIGHT→BANK segment entries
  var wbFrames = 0         # banking frames
  var wbFinishSuspend = 0  # frames the finish-window suspended an armed bank
  var wbLineSegs = 0       # bank segments where a fresh threat line was on us
  var wbBreak60 = 0        # ...and that line was BROKEN within 60t of entry
  var wbBankDeaths = 0     # bank segments ending in death
  var wbBankHeals = 0      # heals to full WHILE banking (the re-arm)
  var wbHp1Segs = 0        # closed hp-1 segments (all bots, tune-independent)
  var wbHp1Heals = 0       # ...ending in a heal to full (alive)
  var wbHp1Deaths = 0      # ...ending in death
  var wbHp1Ticks = 0       # total ticks spent at hp 1 across closed segments

when defined(scprobe):
  # -d:scprobe ONLY (v9): instrument the satCap redistribution as a FUNNEL so a
  # null A/B is diagnosable (pair-saturation never occurs in range vs occurs but
  # the pick never actually spreads). Never compiled into the shipped player.
  var scEngaged = 0   # decide frames with satCap on and an engage pick made
  var scSatSeen = 0   # ...where >=1 fresh in-range candidate was saturated
  var scRedirect = 0  # ...and the final pick was NOT a saturated enemy (spread)
  var scDogpile = 0   # ...and the final pick WAS saturated (commit / only target)
  var scCov1 = 0      # in-range candidate evals with >=1 mate gun lined (diag)
  var scCov2 = 0      # ...with >=2 mate guns lined (the pair threshold, diag)
  var scHp1 = 0       # ...with a read 1-hp (one lined gun suffices, diag)
  var scMateFresh = 0 # mate tracks seen within 2 ticks (dot-read population, diag)
  var scMateRead = 0  # ...whose aim-dot line actually read back (mAim >= 0, diag)
  var scRayHit = 0    # (mate-ray, fresh-enemy) pairs where the ray covers it (diag)

when defined(arprobe):
  # -d:arprobe ONLY (v9): prove the aimRotRead sprite-id readback is LIVE and
  # measure its coverage — how many visible actors yield a bearing from the
  # rotation id, and how often the self-resync path fires. Never shipped.
  var arFrames = 0    # decide frames with aimRotRead on
  var arSelfRead = 0  # ...where the self rotation id yielded our aim
  var arEnemySeen = 0 # visible enemy actors scanned (population)
  var arEnemyRead = 0 # ...with aimBrads >= 0 off the rotation id
  var arMateSeen = 0  # visible mate actors scanned
  var arMateRead = 0  # ...with aimBrads >= 0 off the rotation id
  var arResync = 0    # frames the rot readback actually corrected estAim

when defined(caprobe):
  # -d:caprobe ONLY: counterArc (Play C) funnel — verify the "plasma arc carried"
  # attribution fires and the priority bump reaches a real engage. Also the place
  # to empirically tune ArcCarryRadius (attrib should track actual enemy carriers).
  var caArcAttrib = 0 # actors tagged hasArc via the carried-marker attribution
  var caSeen = 0      # enemy tracks scanned in dangerScore with counterArc on
  var caBump = 0      # tracks that got the disarmed-carrier priority credit

when defined(sgprobe):
  # -d:sgprobe ONLY (2026-07-24 dive-death fix): the adaptive pocket-commit funnel. Never shipped.
  var sgWant = 0      # frames a bot wanted the pocket rush (frontmost body inside PocketRushRange)
  var sgDefended = 0  # ...and the pocket was DEFENDED (>=GrabStackDefenders fresh guns on it)
  var sgHold = 0      # ...and we HELD at standoff (no Captain advantage) — the suicide dive PREVENTED
  var sgCommit = 0    # ...and we COMMITTED the touch WITH advantage (pickEdge/PhForce/cover) — team push

when defined(tcprobe):
  # -d:tcprobe ONLY (2026-07-29 touch latch): does the latch arm, and what did it PREEMPT?
  # The point is not just "did we grab" but "which branch would otherwise have stolen the
  # tick" — the four counters below are the measured preemption census. Never shipped.
  var tcLatch = 0     # frames the touch latch was armed (a body inside GrabCommitRing)
  var tcNade = 0      # ...where the grenade charge/throw would have frozen us
  var tcEngage = 0    # ...where the engage branch would have advanced on the ENEMY instead
  var tcDuck = 0      # ...where the cooldown duck would have crawled to cover
  var tcPeek = 0      # ...where the peek sidestep would have opened a firing line

when defined(fsprobe):
  # -d:fsprobe ONLY (2026-07-24, the focus-fire audit): quantify the two reported
  # SEALs-violating behaviors. Never compiled into the shipped player.
  var fsSwitch = 0    # frames the engage target CHANGED while the PRIOR locked target was
                      # still alive + fresh + within engage range (target-switch mid-kill)
  var fsSwitchLive = 0# ...and that abandoned prior target had its gun ON us (the lethal case)
  var fsBackTurn = 0  # frames a gun-DOWN bot set moveMask AWAY from a fresh enemy whose gun
                      # is on us within HoldVsGunRange, with NO cover-mate (turning the back)
  var fsHold = 0      # ...frames the new holdVsGun guard actually caught + held that case

when defined(arcprobe):
  # -d:arcprobe ONLY (Stage 2, 2026-07-24): the OFFENSIVE arc-breacher funnel.
  # Each counter = decide()-frames of the designated breacher seat surviving one
  # more sub-condition, so a stage that zeroes the count NAMES the gating condition
  # (the diagnostic the audit lacked when it shipped the lever OFF). Never compiled
  # into the shipped player.
  var apBreacher = 0   # frames the fixed breacher seat is alive with arcBreach on (population)
  var apLineLive = 0   # ...and a line is live for us (classified OR heard)
  var apEligible = 0   # ...and free to break off (no arc yet, not carry/escort/stolen)
  var apSeek = 0       # ...=> steered toward the STATIC own-side arc spawn (the run)
  var apArmed = 0      # frames the breacher actually HOLDS the arc (pickup landed)
  var apCharge = 0     # ...and charged the seam with no cluster in cone yet (advancing)
  var apInReach = 0    # ...and a fresh enemy sat inside the cone reach (a shot exists)
  var apFire = 0       # ...=> pressed the cone on-bearing (the multikill press)
  var apClusterSum = 0 # sum of cluster sizes at each fire (mean multikill = sum/apFire)
  var apMaxCluster = 0 # the fattest cluster ever coned (a true multikill proof)

when defined(nmprobe):
  # -d:nmprobe ONLY (v9): instrument the noMask mover-side repel as a FUNNEL so
  # a null A/B is diagnosable (no live support ray ever forms vs rays form but
  # the mover never crosses one). Never compiled into the shipped player.
  var nmNavFrames = 0 # navigate-steer frames with noMask on (the population)
  var nmRays = 0      # live support rays present across those frames
  var nmRepel = 0     # lateral repel vectors actually applied (mover in corridor)

when defined(ocprobe):
  # -d:ocprobe ONLY (v9): instrument the offCone approach bend as a FUNNEL so a
  # null A/B is diagnosable (cone never readable vs readable but never on us vs
  # on us but the bend gated out). Never compiled into the shipped player.
  var ocAdvance = 0   # engage-advance frames with offCone on (the population)
  var ocConeRead = 0  # ...where the target's aimBrads was readable
  var ocOnUs = 0      # ...and its cone was ON us (inside AimOnConeBrads)
  var ocBend = 0      # ...and the tangential bend was actually applied

when defined(asprobe):
  # -d:asprobe ONLY (v9): instrument the assaultThrough trigger as a FUNNEL so
  # a null A/B is diagnosable (surprises never happen vs gun never on us vs
  # cover always nearer vs committed but the charge frames never run). Never
  # compiled into the shipped player.
  var asSurprise = 0  # surprise contacts scanned with assaultThrough on
  var asGunOnMe = 0   # ...whose gun-cone was ON us at the moment of surprise
  var asNoCover = 0   # ...with no duck cover nearer than the enemy → COMMITTED
  var asCharge = 0    # duck-branch frames the charge override actually drove

when defined(ffprobe):
  # -d:ffprobe ONLY (v9): instrument the fatalFunnel pre-lay so a null A/B is
  # diagnosable (sentries never idle vs idle but a fresh track always keeps the
  # sweep vs the throat never computed). Never compiled into the shipped player.
  var ffHold = 0      # sentry hold frames with fatalFunnel on (the population)
  var ffIdle = 0      # ...with NO fresh enemy track (eligible to pre-lay)
  var ffPreLay = 0    # ...where the turret actually pre-laid on the throat

## ── PAINTBOT: the map and the match shape are drawn per EPISODE ──────────────
## Everything position-shaped derives from these. They used to be compile-time
## consts pinned to the old 1235x659 league arena; paintbot generates a new map
## every episode (up to 2496x2496 on a giant 4-team board), so a fixed rectangle
## made the nav grid cover 13% of the field and clamped every coordinate outside
## it into a place that does not exist. Adopted at nav-grid build from the
## walkability sprite, which always spans the whole arena.
var
  MapW = 1235
  MapH = 659
  CenterX = MapW div 2
  CenterY = MapH div 2
  GridW = 0                   # set by adoptMapSize (NavCell is declared below)
  GridH = 0
  LaneMid = float(CenterY)
  LaneBottom = float(MapH) - 40.0
  FireRange = 1250.0
    ## Engage distance. GV34 fixed the gun at config.gunRange on EVERY map
    ## (1300px in all four paintbot variants), so this is the gun's reach
    ## capped by the board — never a map-width, which on a giant board would
    ## admit targets 1200px past anything we can actually hit.
  NadeMaxRange = 247.0        ## sim: MapWidth div 5, so it scales with the map
  ShoutHeardRange = 247.0     ## sim ShoutRange: MapWidth div 5, likewise
  MedKitAX = float(MapW div 2)
  MedKitAY = float(MapH div 3)
  MedKitBX = float(MapW div 2)
  MedKitBY = float(2 * MapH div 3)
  GameTeams = 2
    ## How many teams share the board, from the `game teams <n> map <w>x<h>`
    ## init marker. 2 keeps every classic mirrored-arena path untouched; 4
    ## re-deals our color (seats go round the teams, slot mod GameTeams).
  EndzoneMarks: seq[tuple[color, shape: string, x0, y0, x1, y1: int]]
    ## Every team's stated home capture region, from the per-team
    ## `endzone <color> <shape> <x0>,<y0> <x1>,<y1>` init markers. On a
    ## generated board these markers ARE the scoring geometry — we no longer
    ## reconstruct it from our own copy of the zone formulas.

var
  HeartHome: array[4, bool]     ## per-colour: that team's heart is ON its
                                ## pedestal right now. The planted banner is
                                ## never fogged, so this is free truth every
                                ## frame — and raiding a pedestal whose heart
                                ## is already stolen or retired (GV33) is a
                                ## walk across the board for nothing.
  SelfColor = "red"             ## our confirmed wire color (see the self marker)
  SelfEnemyColor = "blue"       ## the raid target's color

const TeamColorNames = ["red", "blue", "green", "yellow"]
  ## Wire color tokens in engine seat-deal order: a game's active teams are
  ## always a prefix of this list, and seats go round them (slot mod teams).

const
  WebSocketPath = "/player"
  RenderScale = 1             # 0.7.8 renderer restore: the wire is back to 1x
                              # Object coordinates and sprite sizes arrive
                              # multiplied by this; sprites stay centered on
                              # the same map points, so dividing the object
                              # center recovers exact legacy map coordinates.
  PlayerHalf = 6              # solid footprint half-extent, matches the sim
  MuzzleBloomSize = 7         # staggerFire: the muzzle-flash sprite is 7px, drawn
                              # at a shooter's origin for the reload window; mirrors
                              # global.MuzzleBloomSize (player doesn't import ctf/global)
  GunRangePx = 1300.0         # config.gunRange in every paintbot variant. GV34
                              # made the gun a FIXED range on every map instead
                              # of "comfortably wider than the board", so this
                              # is a real ceiling now, not a formality.
  NavCell = 8                 # nav grid cell size in px
  RepathTicks = 10            # refresh the cost field at least this often
  LookaheadCells = 6          # how far ahead on the path we aim the waypoint

  # FireRange is map-derived (adoptMapSize): the gun no longer outranges every
  # board. GV34 fixed it at config.gunRange (1300 in every paintbot variant),
  # and a giant board is 2500px+ wide — engaging past the gun wastes the cycle.
  CarrierFireRange = 110.0    # while carrying, only shoot enemies this close
  RushEngageRange = 230.0     # racing for the steal: only fight what blocks it
  EscortEngageRange = 320.0   # escorting a run: only fight near threats
  PocketRushRange = 210.0     # this close to the enemy pedestal, just GRAB
  ThreatRange = 200.0         # react to a visible enemy this close facing us
  DuckRange = 340.0           # duck from remembered threats this close on cooldown
  TempoPressRange = 150.0     # #8: within this range, press a wounded/turned
                              # threat during our reload instead of ducking
  TempoFreshTicks = 12        # #8: only press a threat seen this recently (a
                              # stale fix is not a real half-beat opportunity)
  BoundThreatRange = 720.0    # #6: an observed clear-line threat within this
                              # (but beyond DuckRange) makes an advance across
                              # open ground while reloading a bounding hold
  BoundThreatTtl = 24         # #6: only bound for a threat remembered this recently
  BoundMateRange = 340.0      # #6: a covering mate must be within this support radius
  BoundMateTtl = 30           # #6: the covering mate must be this freshly seen
  BoundMateDepth = 60.0       # #6: the covering mate is not deeper into the enemy
                              # jaws than us by more than this (it covers from behind)
  HoldVsGunRange = 900.0      # holdVsGun: a SOLO gun-down bot never turns its back on a
                              # fresh enemy whose gun is ON us within this range (past
                              # DuckRange, where the close-duck already covers). Short of
                              # the map-wide fireRange(1250) on purpose — a gun at ~1000px+
                              # is a rumor we can cross while reloading; a dead-on gun
                              # inside 900 will punish a turned back before our gun returns.
  HoldVsGunTtl = 20           # holdVsGun: only hold for a threat seen this recently (a
                              # fresh, gun-on-us read — not a stale fix)
  FinishRange = 260.0         # woundedBank: the finish-window — a fresh 1-hp enemy
                              # inside this with our clear line is one trigger pull
                              # from a won exchange; banking suspends (per-frame)
                              # to convert it (disengaging a won exchange is the
                              # REF-force trap)
  BankSearchCells = 10        # woundedBank: bank-cell search radius in nav cells
                              # (DuckSearchCells is a duck, not a disengage — the
                              # bank needs the wider cover model)
  BankRecalc = 12             # woundedBank: keep a chosen bank cell this many ticks
                              # (no dithering between near-equal cover cells)
  BankBlindTicks = 16         # woundedBank: no fresh threat line on us for this
                              # long => HOLD sub-mode (park at the bank cell, aim
                              # the re-emergence bearing, let medEcon route to a kit)
  BankStandoffGain = 40.0     # woundedBank: an open-floor (non-LOS-breaking) cell
                              # only qualifies with at least this much standoff GAIN
                              # (radial-only retreat is the measured-useless shape)
  BankKitLambda = 0.25        # woundedBank: kit-gravity tiebreak weight toward the
                              # nearest static kit spot (disengage-to-heal synergy)
  DominateGuardBand = 300.0   # #7: search the domination post within this x-band
                              # inside our half of the center line (toward home)
  MateSpacing = 40.0          # soft repulsion radius between teammates
  CorridorHalfWidth = 15.0    # friendly-fire corridor half width along the ray
  LeadTicks = 6.0             # aim this many ticks ahead of a moving enemy:
                              # the 5-tick windup releases the bullet late
  TrackMatchDist = 40.0       # a sighting matches a track within this distance
  TrackTtl = 120              # forget a player not seen for ~5s
  TrackCap = 8                # eight real opponents / teammates per side
  FreshShotTicks = 24         # only fire at tracks seen this recently; the
                              # turret needs traverse time, so chases keep
                              # shooting a bit after the target fogs out
  ThiefFixTtl = 40            # a thief position fix guides the chase this long

  AimBrads = 256              # aim angle units per full turn
  AimRate = 5                 # brads/tick a held rotate button turns the aim
                              # (matches the server's aimTurnRate default)
  AimDotRadius = 16.0         # own aim-indicator dots sit within this radius
  AimResyncBrads = 4          # trust dead reckoning inside this error
  # --- v9 soldier rotation-sprite aim readback (aimRotRead) ---
  # GameVersion 7 RETIRED the floating "aim dot <color>" line (addAimIndicators
  # is a kept-as-no-op stub since e3bcf2e): the aim is now shown by the soldier
  # sprite itself, pre-rotated through 16 steps that sweep with aimBrads. The
  # label collapses to "player <color> <side>" for every step — the aim signal
  # moved from the LABEL/geometry channel into the SPRITE ID. These mirror the
  # engine pools (src/ctf/sim.nim + global.nim; verify on any engine bump):
  #   sprite id = base + ord(team) * SoldierRotations + rot
  #   rot       = soldierRotIndex(aimBrads) — nearest step, 16 brads apart
  RotPlayerSpriteBase = 100   # live soldiers (PlayerSpriteBase, sim.nim)
  RotSelfSpriteBase = 5100    # our white-outlined self, one id per rot (no team)
  RotSteps = 16               # SoldierRotations: pre-rendered aim steps
  RotBradsPerStep = 16        # AimBradsTurn(256) / SoldierRotations(16)
  MaxHp = 3                   # hitPoints per life (config default); pip labels
                              # read "hp <n>/<MaxHp>"
  HpPipRadius = 22.0          # a player's overhead hp bar sits within this
  HpFocusBonus = 60.0         # px of effective-distance credit per missing
                              # enemy hit point — a tiebreak between
                              # comparably-engageable targets, never a reason
                              # to swing the turret across the map
  FocusFireBonus = 45.0       # px of credit when a visible mate's aim line
                              # already covers the target (finish together)
  ShieldGunWeight = 1.5       # a shielded enemy (6-hp tank) counts as this many
                              # guns in the fire-superiority break math — more than
                              # a bare cog: it outlasts a normal exchange, so don't
                              # commit a duel we can't finish (shieldTank awareness)
  SatCapPenalty = 220.0       # satCap: px of priority DEBIT on an enemy already
                              # saturated (enough mate guns lined to finish it) so
                              # a further free gun spreads to an uncovered live
                              # enemy instead of dogpiling. Sized to outweigh the
                              # focus/hp credits + a typical distance gap, but well
                              # under CommitBonus (400) so a gun already committed
                              # to the target never breaks off its own kill; and a
                              # penalty (not a veto) so a lone saturated target is
                              # still engaged when nothing else is in range.
  TraversePxPerBrad = 1.6     # px of effective distance per brad of turret
                              # swing needed to lay on the target: err/AimRate
                              # ticks of traverse at ~8px of enemy closing
                              # motion per tick = 8/5 px per brad
  MateAimHitSlack = 22.0      # enemy within this perpendicular distance of a
                              # mate's aim ray counts as mate-targeted
  MateAimRayLen = 90.0        # ⭐ trust a mate's aim line only this far (2026-07-29). WAS 700,
                              # which GV24 turned into noise: a mate's rendered gun rotation is
                              # fuzzed by up to ±AimFuzzBrads(14), and at 700px that displaces
                              # the ray by 700·sin(19.7°) ≈ 236px — TEN TIMES the 22px slack
                              # this test allows, so "which enemy is my mate shooting at" was
                              # a coin flip past ~65px. The honest trust radius is where the
                              # fuzz displacement stays inside the slack:
                              # 22 / sin(19.7°) ≈ 65px, plus a small margin. Beyond that we
                              # simply do not know, and pretending otherwise fed satCap/noMask
                              # random bearings. Shortening this is a LOSS of intel we never
                              # actually had — the alternative is acting on noise.
  NoMaskAvoid = 30.0          # noMask: soft-repel this far off a mate's live
                              # gun-line (support ray). CorridorHalfWidth(15) +
                              # PlayerHalf(6) + a step of margin, so the mover
                              # bends off BEFORE it would trigger the shooter's
                              # friendlyBlocked veto (which costs the whole
                              # ~17-tick fire cycle plus a re-lay).
  OffConeCloseRange = 70.0    # offCone: inside this, charge straight — at knife
                              # range a tangent step just orbits the enemy while
                              # its whole cone covers us anyway.
  AssaultHold = 45            # assaultThrough: ticks the near-ambush charge is
                              # committed once triggered (~enough to close the
                              # 95px surprise bubble; hysteresis so one fogged
                              # frame doesn't flip charge->duck->charge).
  AssaultPressRange = 130.0   # assaultThrough: only charge a threat this close
                              # (the surprise bubble plus closing slack) — a
                              # threat that opened the range back out is a far
                              # ambush again: break contact normally.
  FunnelBand = 160.0          # fatalFunnel: a passage only counts as the throat
                              # if it intersects this y-band around our pedestal
                              # (the approach axis a raider must cross to reach
                              # the flag; passages off-axis are not our funnel).
  FunnelFreshTtl = 60         # fatalFunnel: any enemy track fresher than this
                              # returns the sentry to the two-speed sweep (which
                              # dwells on real threats) — only a genuinely idle,
                              # no-track sentry pre-lays (REF-hunt guardrail).
  OffConeBendMin = 0.35       # offCone: tangential blend at the cone EDGE (a
                              # nudge keeps us sliding out of the arc)...
  OffConeBendMax = 0.9        # ...ramping to this when its gun is DEAD-ON us
                              # (bend hard: every brad of forced slew is a tick
                              # of its 5-brad turret we fight without return fire).
  ButtonC = 1'u8 shl 7        # grenade charge/throw (input mask bit 128)
  # NadeMaxRange is map-derived (adoptMapSize): the sim computes it as
  # MapWidth div 5, so a giant board doubles it. Old fixed value 247.0.
  NadeMinRange = 72.0         # never lob inside this — the 52px blast + drift would
                              # clip us (keeps the old ~20px self-clearance vs blast)
  NadeBlast = 52.0            # blast radius (GV17 GrenadeBlastRadius, was a stale 40
                              # → cluster/pair targeting missed 40-52px spacings, the
                              # exact line-cluster gap grenades exist to punish)
  NadeFullChargeTicks = 24    # ~1s of holding C reaches max range
  NadePickupDetour = 90.0     # grab a corner pickup within this detour range
  # --- v7 sword/shield (GameVersion 7) ---
  DisarmAvoidRadius = 34.0    # avoidDisarm: steer this far around a sword/shield
                              # pickup we're NOT deliberately collecting (a body is
                              # ~24px; a shell of margin clears the 12px touch grab).
  SprayGrabDetour = 170.0     # opportunistic spray pickup budget (GV36 melee)
  ShieldGrabDetour = 120.0    # shieldTank: an escort grabs a shield within this detour.
  ShieldRushSeat = 3          # the designated shield-rusher team-seat: seat 3 is the
                              # closest-spawn rusher (roleForSeat) — the bot most likely to
                              # reach the pocket first and become the carrier. Only this seat
                              # detours for the shield, so the rest of the wave rushes on time.
  ShieldRushWindow = 240      # only shield-detour in the first ~10s of a life (from gameStart)
                              # — a quick opening grab, never mid-game backtracking.
  ShieldOnSpotPx = 20.0       # "on the spawn spot": if we're this close and no shield is
                              # visible here, it's already taken → give up and rush.
  SwordGrabDetour = 90.0      # swordAmbush: grab a sword within this detour when boxed.
  SwordReach = 26.0           # sword melee arc range (mirrors SwordRange in sim.nim).
  SwordCloseRange = 70.0      # swordAmbush only engages an enemy within this (charge-in).
  # --- v9 med kit (GameVersion 9) ---
  MedKitDetour = 150.0        # medTopOff: a wounded, out-of-contact bot routes to a
                              # VISIBLE center med kit within this detour to heal to full
                              # (sim heals on a 12px touch). Larger than the pickup detours
                              # (a full heal is worth more than a grenade) but capped so the
                              # bot never abandons its lane to chase a far kit; fog reveals a
                              # kit only near center, so this rarely binds anyway.
  # --- medEcon (2026-07-28): the med kits are a STATIC, renewable HP economy ---
  # League measurement over 20 real episodes: the field took 42 heals to our 11
  # (3.8x). With 3 hp per life and 3 lives, a full heal is worth a whole life's
  # damage, so that gap alone explains a chunk of our -63 K-D. Root cause was the
  # old gate: it needed the kit VISIBLE in the fog cone within MedKitDetour AND no
  # contact whatsoever, a conjunction almost never true in the tick-1000..3000
  # mass-engagement window where 81% of our kill deficit is booked.
  #
  # Both kits sit at DETERMINISTIC coords the engine recomputes every reset:
  # (MapWidth div 2, MapHeight div 3) and (MapWidth div 2, 2*MapHeight div 3),
  # each nudged to the nearest walkable floor (sim.resetMedKits). Verified against
  # 53 real league heal events, which cluster at (617,219) and (617,439). So the
  # position needs NO fog read at all - like the pedestals, it is static knowledge.
  # (MedKitAX/AY/BX/BY are map-derived and live in the adopted `var` block —
  # paintbot draws a new map every episode, and on a 4-team board the kits are
  # a rot90 diamond of FOUR, not this 2-team pair. See adoptMapSize.)
  MedKitEconDetour = 320.0   # medEcon: how far a WOUNDED bot will divert to a known
                              # kit. Wider than MedKitDetour because the target no
                              # longer has to be visible - the walk is the whole cost,
                              # and a 1-hp bot is worth less than the detour.
  MedKitOnSpotPx = 26.0       # "we are standing on the spot": if this close and the
                              # kit sprite is NOT visible, it is taken - stop going.
  MedKitLightContactHp = 1    # medEcon: at or below this hp a bot breaks LIGHT contact
                              # (a threat that is not aiming at us) to go heal. At 1 hp
                              # the next bullet is death, so healing outranks the duel.
  CarrySelfRadius = 26.0      # a carried heart rides CarriedFlagLift (~10 map
                              # px) above its carrier's center, so our own
                              # carry shows as the enemy heart floating just
                              # over our head — never within the old 4px test
  CarriedFlagLift = 10.0      # px a carried heart flies above its carrier's
                              # center (mirrors CarriedFlagLift in src/ctf/global.nim).
  FlagPickupRange = 12.0      # touch radius to steal the enemy heart off its
                              # pedestal (mirrors FlagPickupRange in src/ctf/sim.nim).
  CarrierEstSpeed = 1.0       # px/tick a fogged mate-carrier is assumed to
                              # advance homeward (carrier moves at ~70% speed)
  CombatDeadband = 2          # stop the traverse within this error (brads);
                              # AimRate 5 cannot settle tighter than +-2
  CruiseDeadband = 8          # sloppier deadband for non-combat aim
  FightOutRadius = 260.0      # the breakout ring after a snatch: inside it the
                              # carrier keeps a point-blank gun (fight off the X)
  CqbRange = 180.0            # ⭐ CQB plant-and-settle applies inside this range
  CqbFireSlackPx = 6.0        # ...with the corridor halved: field census (24 real
                              # arena episodes, 2026-08-04) — our locked heading is
                              # OFF the body on 27% of point-blank shots vs the
                              # field's 13%, and we fire while MOVING >8px during
                              # the windup on 33% of them vs their 8%. Hit% falls
                              # 59->20 with windup self-movement: the locked ray
                              # parallel-shifts with the shooter. The field plants
                              # to shoot; run-and-gun buys no defense (constant-
                              # velocity strafe is fully lead-compensable — they
                              # hit us 65.6% regardless). REF-slack refuted GLOBAL
                              # knob tuning; this is the range-conditioned LOGIC
                              # fork it prescribes, >=CqbRange untouched.
  WindupPlantTicks = 5        # suppress movement this long after a CQB pull
                              # (the fire windup: aim locks at pull, bullet
                              # leaves 5 ticks later from wherever we drifted)
  FireSlackPx = 11.0          # fire when the aim error's perpendicular miss
                              # at the target's range is inside this (the
                              # corridor half-width is ~14px; keep margin)
  StickyDangerCap = 60.0      # stickyCommit: a NON-committed target's danger credit is
                              # capped at commitBonus - this, so a fresh dead-on threat stays
                              # at least this far below a committed kill in priority (switch
                              # hysteresis — kills the single-frame target flip off a kill).
  CommitBonus = 400.0         # px of priority credit for the committed target,
                              # so we finish the enemy we are already killing
                              # instead of switching to a marginally closer one
  LockTtl = 48                # hold a target commitment this many ticks past
                              # the last frame we could engage it (~2 shots)
  LockMatchDist = 60.0        # a candidate this close to the lock fix IS it
  AimHoldTtl = 60             # TARGET-LOCK: keep the turret (and the vision
                              # cone, which rides the aim) pinned on a committed
                              # enemy's bearing for this many ticks past the last
                              # sighting. The server turns a fixed 5 brads/tick
                              # (aimTurnRate, uncappable), so LOSING a target into
                              # fog and re-slewing to re-acquire is the single
                              # costliest waste of the scarcest resource; holding
                              # the bearing keeps them lit AND pre-lined.
  PreSlewOffUsPx = 3.0        # ⭐ FIRE FIRST (v8): px of pre-lay credit per brad the
                              # candidate enemy's gun points OFF us. Among the same
                              # engageable-range fresh set aimLock already picks from,
                              # discount the enemy whose turret is most off our bearing
                              # (the draw we WIN — our windup finishes while its gun is
                              # still slewing onto us). Requires aimThreat's aim-dot read;
                              # an unreadable dot leaves the pick on pure distance.
  HuntSweepTtl = 90           # HUNTING POSTURE: with no engageable target, aim
                              # toward the nearest enemy remembered this recently
                              # instead of blindly down the movement lane.
  AimThreatBonus = 120.0      # px of priority credit for an enemy currently
                              # FACING us (about to shoot) — engage the greatest
                              # threat first.
  DangerCloseBonus = 200.0    # #1: extra facing-credit at point-blank, tapering
                              # linearly to 0 at DangerFalloff — a close aligned
                              # gun kills us THIS second, a far one barely threatens
  DangerFalloff = 620.0       # range (px) at which a facing enemy's added danger
                              # decays to nothing (~half the map-wide gun range)
  DangerWoundedBonus = 90.0   # #1: extra credit for a target that is BOTH facing
                              # us AND wounded — the cheapest, most dangerous kill
  # --- counterArc (Play C, GameVersion 15 plasma arc) ---
  PlasmaArcReachPx = 136.0    # sim.nim PlasmaArcReach = 4*SoldierBodyPx(34): the
                              # enemy cone's max reach. Beyond it a plasma carrier
                              # is DISARMED (gun off while holding) AND out of cone
                              # range = a free kill. Local copy (player can't import
                              # sim); re-verify vs sim.nim on every engine bump.
  CounterArcBonus = 240.0     # px of priority credit for an enemy arc-carrier we can
                              # kill from OUTSIDE its cone. Above AimThreatBonus(120)
                              # so it beats a generic/far/wounded enemy, but BELOW
                              # CommitBonus(400) so it NEVER drops a target we're one
                              # hit from killing (protects the commit lock + OBJ-1).
  CounterArcReachBuffer = 24.0 # margin past PlasmaArcReachPx before we treat a
                              # carrier as "safely disarmed" — covers the 5-tick cone
                              # sweep + our closing speed so we don't mis-classify a
                              # carrier about to be in reach.
  # --- arcBreach (anti-line OFFENSE, GameVersion 17 plasma arc) ---
  ArcBreachSeat = 1           # the FIXED team-seat (0..7) that plays breacher when a
                              # line is called — a deterministic seat, NOT lowest-alive
                              # (teammates are fogged, so no bot can see who else is up).
                              # Seat 1 = the MidGuard (trailing mid) so a front rusher
                              # never trades its gun; the breacher arms up from behind.
  ArcBreachSeek = 260.0       # (legacy) see-radius of the OLD LOS-gated seek. The arc
                              # spawns in our own BACK CORNER (arcSpawn), ~200px behind a
                              # forward breacher and far outside the 90px vision bubble, so
                              # a see-it scan fired ~0 (the shipped-OFF bug). The seek now
                              # navigates to the STATIC arcSpawn coordinate, no LOS needed.
  ArcBreachCommit = 520       # once the breacher commits to the arc run (a line was live
                              # and it broke off), hold the run this many ticks past the
                              # last live-line frame so a FLICKERING line read can't abort
                              # the trek. Sized to the WORST-CASE round-trip: a breacher
                              # deep at the seam (~x 707) must path BACK to the arc corner
                              # (x 50) then out again = ~1314px / 2.75px·t⁻¹ ≈ 478t; 520
                              # covers it (the old 170 covered only one leg → aborted runs).
  ArcLineMemoryTicks = 900    # PROACTIVE ARM opponent-adaptivity: pre-arm off a Captain
                              # pressure phase ONLY if a real line was seen within this window
                              # (~37s). So the breacher wakes up vs a line-playing opponent
                              # (h006) and stays a dormant full gun vs an aggressive no-line
                              # field — it never trades its gun for a line that never comes.
  ArcArmMaxDepth = 40.0       # PROACTIVE ARM (the geometry fix): only START an arc run while
                              # the breacher is SHALLOW — at most this far past center into the
                              # enemy half (so it's near/behind mid, a cheap ~one-leg detour to
                              # the own-corner arcSpawn). A breacher already DEEP forward would
                              # face the ~478t round trip the audit killed, so it never arms
                              # there; it arms off-spawn / while trailing, on a Captain line-prone
                              # read, THEN carries the armed cone forward to the called cluster.
  ArcConeMinCluster = 2       # MIN fresh enemies inside one cone before we FIRE it. The arc
                              # trades our gun for LIFE, so coning a SINGLETON (cluster 1) is
                              # a net DPS loss vs just shooting it (25t recharge, disarmed for
                              # life). Field-measured: without this gate the cone averaged 1.33
                              # hits (mostly singletons). Only spend the cone on a real cluster.
  ArcBreachFireReach = 128.0  # fire the cone when a fresh enemy sits within this (just
                              # inside the engine's 136px reach, a margin for our aim/step)
  ArcBreachConeBrads = 12     # press attack when the target is within this of our aim
                              # (the ~14° half-cone; be on-bearing so the cone lands)
  ArcApproachRadius = 300.0   # a DISARMED breacher CLOSES on a fat cluster (>= ArcConeMinCluster
                              # fresh enemies within one PlasmaArcReach of each other) detected
                              # within this radius — wider than the 128px fire reach, because to
                              # cone a DEEP line the gunless body must first close the gap. This
                              # approach is the +EV act the weapon exists for (area-denial vs a
                              # cluster; doctrine "numbers are the currency"), NOT feeding: it is
                              # gated on a REAL cluster, never a singleton (that's the dry case).
  ArcSeamHoldDepth = 55.0     # a DISARMED breacher with NO cluster anywhere (the dry case) must
                              # NOT charge its gunless body INTO the line to be focus-fired for
                              # free. Hold at this shallow depth just past center — a live cone is
                              # a THREAT that shapes the line (enemies space to dodge AoE) even
                              # unfired, and we stay poised to close the instant a cluster forms.
  ArcCarryRadius = 48.0       # attribute the "plasma arc carried" marker (floats
                              # ABOVE the head, higher than the hp pip) to the nearest
                              # actor within this — bigger than HpPipRadius(22) for the
                              # extra vertical offset. Verify empirically via cAprobe.
  AimOnConeBrads = 32         # aimThreat: gun bearing within this many brads of the
                              # line to us counts as "aimed at us" (~45°, generous
                              # since the enemy is still turning toward us). Beyond
                              # this the gun points elsewhere = a lesser threat.
  AimFuzzBrads = 14           # ⭐ GV24: every OTHER soldier's rendered gun rotation is the
                              # true aim plus a deterministic offset of up to ±14 brads
                              # (~±20°), re-rolled every 12 ticks — so an enemy's aim read
                              # off the sprite is NEVER exact and cannot be averaged out
                              # (the window outlives the 5-tick windup, by design). Mirrors
                              # the engine's AimRenderFuzzBrads. Our OWN aim is exempt again
                              # (GV26), so this applies ONLY to enemies and mates.
  AimFuzzFloor = 0.25         # ⭐ never HARD-ZERO a threat on a fuzzed read: a gun measured
                              # "off cone" may really be dead on us. This is the residual
                              # danger credit such a target keeps — small enough that a
                              # genuinely-aside gun still loses the tiebreak, large enough
                              # that it is not invisible.
  AimDeadOnBrads = 8          # aimThreat: gun within this of dead-on = maximal
                              # danger scale (lethal THIS tick); credit tapers
                              # linearly from full at 0 to the on-cone floor here.
  RetreatRadius = 260.0       # local force-balance radius: count the fresh
                              # enemies and friendlies within this of us
  OutnumberMargin = 2         # fall back when fresh local enemies outnumber
                              # local friendlies (incl. self) by >= this
  Gv21OutnumberMargin = 3     # gv21Press: the WIDER break threshold — hold and trade
                              # until the enemy overmatch is this big. GV21 deleted
                              # spawn-protection + punishes draws, so a 1-gun deficit
                              # is worth pressing (the kill wins the wipe) not ceding.
  LocalFreshTicks = 20        # a track counts toward local balance only if
                              # seen this recently
  RetreatHold = 24            # once outnumbered, commit to the withdrawal for
                              # this many ticks (hysteresis; no flip-flopping)
  RegroupRadius = 460.0       # fall back onto a remembered mate within this
                              # range (re-form the wave), else straight home
  RetreatStep = 240.0         # else withdraw this far toward our home side
  ScanArc = 44                # scan sweeps this many brads each side of the
                              # watch heading (cone half-angle is 32 brads)
  ScanDwellRange = 900.0      # #3: a sentry dwells on a fresh threat inside its
                              # arc within this range instead of sweeping past it
  ScanDwellTtl = 40           # #3: dwell only on a threat remembered this recently
  PushOutTicks = 360          # endgame push: no enemy seen for ~15s...
  PushOutMinGame = 2400       # ...this deep into the game breaks the posts
  LatePushTick = 4200         # all-in on the clock: past this tick a draw is
                              # the default outcome, so commit to the capture. Was 6800 —
                              # DEAD on the 5000-tick clock (MaxTicks 5000), so post-break
                              # never fired and defenders camped posts into a timeout=−1 draw.
                              # 4200 aligns with ForceClockTick(3800): break posts + go win late.

  # --- post-wipe consolidation (regroupPush) ----------------------------------
  # The v14 loss cause (2026-07-18 replay study): after we clear the enemy nest
  # we TRICKLE mids into the ~72t respawn wave one body at a time and die
  # piecemeal — "cash the wipe 0% of the time, squander 47%" in losses. The fix
  # is a TIMING correction, not a depth cut: depth correlates with WINNING (we
  # die deeper in their half in WINS), so this must fire ONLY in the squander
  # signature — a mid over-extended into the enemy half, local area cleared of
  # live enemies (the post-wipe vacuum), and strung out from its mates. It then
  # holds a shallow midfield rally until the trio re-forms, then RELEASES to push
  # deep together. When grouped it does nothing (full-depth push preserved).
  RegroupPushRallyDepth = 70.0  # hold the rally this far INTO the enemy half (past
                                # center) — forward of mid so we don't cede ground,
                                # shallow enough that strung-out mates re-form fast
  RegroupPushTrigDepth = 130.0  # only consolidate once we've pushed at least THIS
                                # deep into the enemy half alone (genuinely committed
                                # / over-extended, not merely crossing midfield)
  RegroupPushPack = 2           # release and push once this many FRESH mates are
                                # grouped near us (self + this = a 3-body wave)
  RegroupPushRadius = 200.0     # a mate counts toward the pack within this range
  RegroupPushClearRange = 240.0 # "vacuum": no fresh enemy within this of us (the
                                # nest is cleared — the moment we tend to trickle in)
  RegroupPushCommit = 90        # once grouped, commit the joint push for this many
                                # ticks (hysteresis: don't re-hold as the wave spreads)

  # --- grab timing (anti-stacked-dive) ----------------------------------------
  # The dive-death finding (96 hash-clean H2H, 2026-07-20): 96% of our carrier
  # deaths are AT the enemy pedestal (<210px), 85% within 50px of the grab, and
  # grab->cap conversion is 0% in EVERY loss. We out-grab the field 2x but rush a
  # lone, often gun-down body into a STACKED pocket and it is shot on the touch.
  # The pocket is the ONE place commit's kill-to-convert mechanism structurally
  # cannot fire: selectFireTarget SKIPS spawn-protected bodies (sim.nim:2854), so
  # a fresh respawner is UNKILLABLE for SpawnProtectTicks(24) yet still shoots our
  # toucher. grabTiming is the fireSuperiority "break only if you can't win the
  # exchange AND no mate is free to assault" carve-out applied to exactly that
  # spot — it DELAYS/SEQUENCES the dive when the pocket is stacked and cover is
  # inbound, it never abandons the objective (a lone last body still dives).
  GrabStackDefenders = 2        # "stacked": this many fresh enemy guns within
                                # GrabStackRange of the pedestal make a solo dive
                                # a coin-flip death — hold for a covering mate.
  GrabStackRange = 150.0        # count pocket defenders within this of the pedestal
                                # (a gun this close to the heart covers the touch)
  GrabCommitRing = 60.0         # once inside this of the pedestal we are committed —
                                # a hold here just feeds ticks, so dive through it.
  GrabHoldStandoff = 150.0      # hold the gun up at this radius off the pedestal
                                # (outside GrabStackRange so we suppress from beyond
                                # the defenders' tightest cover, still pressuring).
  GrabCoverRange = 110.0        # a mate this close to US at the pocket is cover in
                                # place — release and grab TOGETHER (the point of it)
  GrabInboundGap = 20.0         # a mate this much homeward of us is genuinely
                                # inbound support worth waiting a beat for.
  GrabMateFreshTicks = 90       # mate tracks count for cover/inbound up to this
                                # stale: the diving rusher's cone is welded to its
                                # aim ON the pocket, so a mate approaching from
                                # homeward sits BEHIND the cone and can't be seen
                                # fresh at the moment of the hold decision. At
                                # LocalFreshTicks(20) the inbound count was
                                # structurally 0 (gtprobe: noCover 144 -> FIRED 0).

  # --- holdLine (anti-over-extend vs a standing line) -------------------------
  # The h006 line-defense finding (2026-07-22 corpus): the #1 policy forms a line
  # in its own half and lets us over-push into a converging kill. We die 39% in the
  # enemy half; h006 ~14%. Sibling of regroupPush (shares its movement-only, lone-
  # survivor-presses, release-when-grouped guard structure and its REF-force
  # firewall) but the OPPOSITE trigger: regroupPush holds in a post-wipe VACUUM;
  # holdLine holds when we have over-extended into the enemy half AND fresh enemies
  # are present AND we lack LOCAL fire-superiority (fresh mates near us < fresh enemy
  # guns near us). It rallies at a shallow line so the wave engages the defense
  # together instead of trickling in one body at a time to be farmed.
  HoldLineTrigDepth = 90.0      # only bite once we've pushed at least this deep into
                                # the enemy half alone (shallower than regroupPush's
                                # 130: a standing line kills earlier than a vacuum lets
                                # us wander, so hold before we reach the kill pocket)
  HoldLineRallyDepth = 40.0     # rally this far into the enemy half at our lane (still
                                # forward of mid — we never cede ground, just re-form)
  HoldLineEnemyRange = 200.0    # a fresh enemy gun within this of us = a live line to
                                # our front (not an empty vacuum — regroupPush's job)
  HoldLineMateRange = 200.0     # a fresh mate within this counts toward our local pack
  HoldLineSuperiority = 0       # release the hold when (fresh mates near) - (fresh enemy
                                # near) >= this: we have the local edge to engage the line
  HoldLinePack = 2              # OR release once this many fresh mates are grouped (a
                                # 3-body wave hits the line together = regroupPush parity)
  HoldLineCommit = 90           # once released, commit the joint push for this many ticks
                                # (hysteresis; mirrors RegroupPushCommit)

  # --- grabGate (numbers-gated pocket rush) -----------------------------------
  # The h006 grab-discipline finding (2026-07-22): h006 grabs almost only when up
  # bodies (steal->cap 46-64% vs our 28%); we grab even/behind and feed the carrier.
  # Distinct from grabTiming (pocket-STACKING gate): grabGate gates the pocket-rush
  # itself on LOCAL fire-superiority near the pedestal. Teammates are fogged, so we
  # use fresh-mate-vs-fresh-enemy-gun proxies around stealTarget, never a global
  # headcount (that would be the falsified forceBalance). Same lone-last-body /
  # pushOut / commit-ring carve-outs as grabTiming: it DELAYS the open, never abandons.
  GrabGateEnemyRange = 150.0    # count fresh enemy guns within this of the pedestal
                                # (matches GrabStackRange — the same defense grabTiming sees)
  GrabGateMateRange = 170.0     # an inbound mate must be within this of US to count as
                                # support arriving in time (a mate homeward but far back
                                # is not converting THIS grab)
  GrabGateDeficit = 1           # gate the dive when (pocket enemies) - (me + inbound
                                # support) >= this: the defense beats our local force at
                                # the touch by this margin — the exact suicide-grab state

  # --- team comms (shouts) & damage awareness ---------------------------------
  # The engine gives each player ONE shout channel: <=ShoutMaxChars (10) chars,
  # at most one per second, heard by teammates within ~247px THROUGH walls and
  # fog. We use it for four messages on one prioritized slot (see decide()):
  #   "oh shit!"  surprise: an enemy appeared in our face after a blind gap
  #   "die"       pre-fire: we are about to shoot with a mate in earshot
  #   "E <cell>.." enemy callout: chess-cell fixes on fresh enemy tracks
  #   "C<cx> <cy>" carrier heartbeat (existing; lowest priority)
  ChessFiles = 26             # A..Z map columns for the callout grid
  ChessRanks = 14             # 1..14 map rows: ~47x47px cells (MapW/26, MapH/14)
  ShoutGapTicks = 26          # min ticks between our own shouts (server caps at
                              # ReplayFps ~1/s; we self-rate a touch slower)
  CalloutFreshTicks = 20      # only call out enemies seen this recently
  CalloutMaxCells = 2         # name at most this many enemy cells per shout
                              # ("E M9 C4" fits the 10-char budget)
  SurpriseRadius = 95.0       # an enemy THIS close that we were not tracking is
                              # "in our face" — the corner-ambush jump scare
  SurpriseGapTicks = 40       # ...and unseen for at least this long before now
                              # (or brand new) — genuinely a surprise, not an
                              # enemy we watched approach
  SurpriseShoutCooldown = 150 # one "oh shit!" per bot per ~6s (flavor, not spam)
  DieEarshot = 200.0          # shout "die" when a friendly is within this of us
                              # as we fire — close enough to hear and help
  DieShoutCooldown = 90       # one "die" per bot per ~3.75s
  VanityShoutChance = 5       # % of eligible frames that actually emit a vanity
                              # ("oh shit!"/"die") shout. Without this the cooldown
                              # is the ONLY throttle, so in a clustered 8v8 a mate
                              # is almost always in earshot and every bot fires
                              # "die" every DieShoutCooldown ticks = a wall of
                              # bubbles on screen. This is a rare-flavor gate: keep
                              # the lines occasional, not constant. Uses a
                              # per-(slot,tick) hash, NOT rand(), so the shared RNG
                              # stream stays untouched and the mask stays neutral.
  # ShoutHeardRange is map-derived (adoptMapSize): the sim's ShoutRange is
  # MapWidth div 5, so a fixed 247 DISCARDS shouts we really heard on a big
  # board — the comms bus loses half its intake. Old fixed value 247.0.
  ContactWatchTicks = 30      # after hearing "oh shit!"/"die"/callout, orient
                              # the vision cone toward the fix for this long
  HpDropOrientTicks = 24      # after taking a hit from an unseen direction,
                              # orient toward the muzzle-ring bearing this long
  ShotSoundRange = 300.0      # only react to "shot sound" muzzle rings within
                              # this of us (a nearby unseen shooter, likely at us)
  # ── Shout-reaction gate (calloutGate, 2026-07-16): a heard callout is
  # INTEL, not an order. Listening (banking the enemy track) is always cheap;
  # REACTING (turning the cone / moving) must clear a distraction bar keyed to
  # the bot's own task priority — SEAL "priority of work / need-to-know". These
  # gate the reaction, they do NOT gate the intel intake.
  CalloutSelfBubble = 130.0   # a callout THIS close to us is a threat to our OWN
                              # survival — even a committed carrier/grabber glances
                              # (OrientOnly), because a dead carrier captures nothing.
  CalloutLaneCone = 40        # brads: half-cone around our travel bearing. A
                              # callout inside it is a threat we are about to walk
                              # INTO, so even a committed bot orients to it.
  CalloutSectorRange = 300.0  # a posted defender (Overwatch/HomeDefender) reacts
                              # to a callout only within this of the thing it guards
                              # (the carrier it covers, or our own flag) — need-to-know.
  CalloutLaneReach = 520.0    # the lane-cone proximity override reaches this far
                              # down our travel bearing — a called threat farther
                              # than this on our path is not yet a walk-into risk.

  # ── COMMS BUS (C1/C2, 2026-07-22, Track B) ──────────────────────────────────
  # Event-driven team plays over the one shout channel. A bot classifies a LIVE
  # scenario from its OWN fresh local reads (classifyScenario) and broadcasts an
  # opaque 2-char codeword; teammates in earshot adopt it (heardPlay) and fold it
  # with their own read through ONE shared matrix (selectScenarioPlay) so the team
  # converges without a captain and degrades to the clock playbook if it hears
  # nothing. Emit is mask-neutral (rides shoutWant); adoption moves MOVEMENT INTENT
  # only, never the turret (the v1/v2 cone-diversion lesson, REF-comms).
  CommsScanRange = 240.0      # a fresh enemy/mate within this of us counts toward
                              # the local STACK/WIPE read (~the pocket + a lane)
  CommsStackDefenders = 2     # >= this many fresh enemy guns clustered near the
                              # steal target = the pocket is STACKED (ScStack)
  CommsWipeMax = 0            # <= this many fresh enemies near us while our guns are
                              # up + we are deep = a local WIPE vacuum (ScWipe)
  CommsLineGuns = 2           # >= this many fresh enemy guns clustered to our front
                              # while we're deep but NOT at the pocket = a standing
                              # defensive LINE (ScLine) — the h006 farm-our-push posture
  CommsPlayTtl = 90           # a heard/derived scenario play is held this many ticks
                              # (~3.75s — a play beat) then decays to the clock fallback
  CommsEmitCooldown = 40      # min ticks between our own codeword emits (own rate
                              # limit on top of ShoutGapTicks; a play beat, not spam)
  CommsSalt = 0x5A17          # compiled-in team secret for the rotating codeword
                              # table (commsCrypto). Rotate this each upload if a
                              # clone ships our exact salt (the C2 hedge).
  # The 1-char play tokens (the SECOND char carries the flank for flip plays). The
  # scheme rotates which glyph maps to which play per round (commsCrypto); this pool
  # is the alphabet drawn from. Opaque single letters, not "PushTop" — a clone reads
  # a letter, not our play. Order matters ONLY as the rotation base.
  CommsTokenPool = "kqxzjvwy" # 8 low-frequency glyphs; index = (play + roundSalt) mod 8

  CoverShieldDist = 42.0      # an obstacle this close blocks a threat direction
  PeekLineDist = 150.0        # floor for an overwatch peek firing line; post
                              # scoring strongly prefers the longest line
  DuckSearchCells = 3         # duck-cell search radius in nav cells
  PeekSearchCells = 3         # peek-cell search radius in nav cells
  ExposureRange = 380.0       # enemy threat radius used for exposure costing
  ExposureThreats = 3         # cost only the freshest few remembered threats
  ExposureTrackTtl = 60       # only cost threats remembered this recently
  UnderFireTrackTtl = 16      # tracks this fresh can pin us on open ground
  SerpentineNear = 100.0      # serpentine band: closer threats are jink/duck
  SerpentineFar = 400.0       # ... and farther tracks cannot really aim at us
  StepCost = 5'i32            # orthogonal move cost in the nav field
  DiagCost = 7'i32            # ~sqrt(2) * StepCost
  ExposedCost = 14'i32        # extra cost to enter a threat-exposed cell:
                              # under fog the exposure model (enemy sniper
                              # posts + fresh tracks) is the only warning of
                              # watched lanes, so routes respect it hard
  FlankDepth = 260.0          # wide flankers cross this far past mid
  WeaveBand = 280.0           # rushers serpentine within this x-band of mid

  LaneTop = 40.0              # open corridor above the mirrored obstacles
  # LaneMid / LaneBottom are map-derived (adoptMapSize).
  RespawnBandHalf = 84.0      # fresh enemies respawn at pedestal height ±72px
                              # aimed E-W; a carrier at that height runs straight
                              # down the invulnerable respawner's firing line, so
                              # a carrier clears this band vertically before the run.
  PocketClearX = 130.0        # while this close (x) to the robbed pedestal, the
                              # carrier is still in the respawn pocket.
  CarrierFinishBand = 150.0   # within this x-distance of our home-deep point the
                              # whole capture column is protected open floor at
                              # every y, so the carrier drives straight in at its
                              # current height instead of diagonally to a stub-lined
                              # extreme lane (the home-wall wedge fix).
  EscortRunThreatRange = 260.0 # #esc: a remembered enemy within this of the carrier
                              # (anywhere on the OPEN run home, not just the pocket
                              # cone carrierScreen covers) makes the nearest free mate
                              # interpose on the threat->carrier ray. Round-624 decode:
                              # our carrier died at minDist=280 in MIDFIELD, ~585px from
                              # the robbed pocket — outside carrierScreen's ~390px reach
                              # and outside CarrierFinishBand — alone, un-interposed.
  EscortRunGap = 34.0         # #esc: the escort sits this many px toward the threat
                              # from the carrier, one body onto the incoming ray (the
                              # gun kills the NEAREST body in the cone, so the escort
                              # eats the shot). Tuned near a body radius.
  EscortRunMateRange = 520.0  # #esc: only a mate already within this of the carrier
                              # commits to escort — a distant bot pressing the enemy
                              # pedestal keeps the capture race on, doesn't peel back.
  HuntCarrierStaleTtl = 240   # #hunt: keep hunting an enemy carrier this long after
                              # the last fix (vs ThiefFixTtl's short converge window).
                              # Round-624 decode: their carrier ran EXPOSED 518 ticks
                              # and we never chased — the interceptor gave up the instant
                              # the fix went stale and parked on a static lane guess.
  HuntCarrierStandoff = 120.0 # #hunt: intercept the enemy carrier THIS many px in front
                              # of (toward center from) its capture edge, on its last-seen
                              # lane — cut the corner of the race and MEET the runner near
                              # the finish, rather than trailing a stale-velocity phantom.
  SentryDwellTicks = 90       # a sentry (overwatch / home defender) holds a post
                              # ~3.6s of scanning, then DISPLACES to an adjacent
                              # covered vantage — SEAL "never a static target," and
                              # it fixes the "our guys stay still far too much"
                              # complaint without abandoning the ground it commands.
  SentryShiftPx = 96.0        # how far a displacing sentry slides along its watch
                              # face to the next vantage (a lateral cover step, not
                              # a retreat: same x-band, ± along the crossing it owns).
  PlayPeriod = 450            # PLAYBOOK: the favored attack flank flips every this many
                              # elapsed round-ticks (~18s). Long enough to actually mass
                              # and commit a flank push before switching; short enough that
                              # an opponent can't scout a fixed side. Shared across all 8
                              # bots via elapsed = tick - gameStart, so no comms needed.
  PlayFlankPull = 150.0       # how hard an off-role attacker is pulled toward the favored
                              # lane when its play says PUSH there (px of Y bias toward the
                              # strong flank; the two feint holders keep the other lane).
  # ── CONTINGENCY STATE MACHINE (teamPhase) timing. GV21 games are 5000 ticks
  # (MaxTicks halved from 10000) and a timeout draw is −1 for BOTH sides, so the
  # plan must force a decisive attempt WELL before the clock and win the opening.
  OpenPhaseTicks = 600        # the OPENING window (~25s): contest mid TOGETHER to win
                              # the first clash grouped (we currently lose it 14-6 by
                              # trickling to lane roles). After this, fall to PROBE.
  ForceClockTick = 3800       # past this elapsed tick (~76% of the 5000 clock) with no
                              # decisive edge, commit a grouped all-in flag attempt — a
                              # "good enough" hit beats stalling into the −1 timeout draw.
  OpenGroupPull = 200.0       # PhOpen: px of Y bias pulling the attack wave toward the
                              # shared mid lane so the opening clash lands as a GROUP,
                              # not eight bots trickling up their own lanes to be picked.
  EscortCollapseRange = 900.0 # PhEscort: a free gun within this of the carrier collapses
                              # onto its home lane to suppress chasers (body-block is void
                              # on this engine — CollisionW=1 — so escort value = kill the
                              # chaser, per the cqc-video-game-lens focus-fire principle).
  PickEdgeRange = 300.0       # PhPress: a fresh enemy corpse / our recent kill within this
                              # of us = a local man-advantage window worth pressing.
  # ── v29 (2026-07-29) MEASURED phase timing + recapture geometry. The phase-occupancy
  # probe (-d:phprobe, 12 games GV23) read PhForce at 0 frames of 266,279: games end by
  # WIPE at mean 2410 ticks (min 1541, max 4004) so a 3800 trigger never armed. GV23's
  # action-clock floor (ActionClockFloorTicks 500 banked into overtimeTicks on every kill
  # or steal) only extends games that are still ACTIVE, which does not rescue the trigger.
  ForceClockTickTuned = 2000   # forceTiming: arm the late all-in at ~40% of the nominal
                               # clock — past the opening + a probe window, but inside the
                               # mean 2410-tick life of a real game, so FORCE actually fires.
  DefendInterceptPush = 40.0   # defendTeeth: px past the thief fix, toward ITS capture edge —
                               # cut the thief off ahead rather than trailing the fix (the same
                               # lead the HomeDefender intercept already applies).
  DefendCrossGuard = 60.0      # defendTeeth: with a STALE fix the thief is fogged but MUST
                               # cross mid toward its own edge; hold this far onto our side of
                               # center and guard the crossing instead of chasing a phantom.
  DefendPicketSpread = 90.0    # defendTeeth: px of Y separation between recapture seats at the
                               # crossing. Six bots on ONE pixel is grenade bait (the cluster
                               # lesson from the anti-line work) and covers a single row; a
                               # 3-wide picket spans the lane the fogged thief may drift into.

type
  Team = enum
    Red, Blue

  Role = enum
    MidTop, MidBottom, MidGuard, FlankTop, FlankBottom,
    Overwatch, HomeDefender

  Play = enum                 # PLAYBOOK: the team's current shared posture, computed
                              # identically by every bot from shared signals only.
    PushTop,                  # mass the attack wave on the TOP flank, feint bottom
    PushBottom,               # mass on the BOTTOM flank, feint top
    StackDefense              # own flag stolen: converge on the thief / recapture
                              # (posture already handled by the ownStolen branches;
                              # this is the label the play layer reports for it)

  EnemyFlagState = enum       # ⭐ PLAN LAYER: the enemy heart's state — GLOBALLY LEGIBLE
                              # (the "<enemy> heart" sprite is always visible, bot header
                              # L27-29), so every bot reads it identically with NO comms.
    EfPedestal,               # enemy heart sits on its pedestal — nobody has stolen it
    EfCarried,                # WE are carrying it (on me or a mate) — the escort window
    EfDropped                 # off-pedestal but uncarried (a dropped/contested steal)

  TeamPhase = enum            # ⭐⭐ CONTINGENCY STATE MACHINE (2026-07-23, "chess not
                              # checkers"): the team's shared plan PHASE, a pure function
                              # of the three shared signals (elapsed clock, ownStolen,
                              # enemyFlagState) so all 8 bots compute the SAME phase on the
                              # SAME tick and flow branch→branch with no thrash. Each phase
                              # is a default posture PLUS pre-briefed transitions — the plan
                              # is planned AHEAD (see docs/designs/contingency-plan-arch.md).
    PhOpen,                   # opening: contest mid TOGETHER (win the first clash grouped,
                              # not trickle to lane roles and get picked off individually)
    PhProbe,                  # mid-game default: pressure the read, hold the finish
    PhPress,                  # up a body (local pick): group + hit the up-side FAST before
                              # the downed enemy respawns (the man-advantage window)
    PhEscort,                 # WE carry the heart: everyone collapses to the carrier lane,
                              # suppress its chasers, trade for the capture
    PhDefend,                 # own flag stolen: full-team collapse to recapture (never a
                              # half hedge — "never split-decide")
    PhForce                   # clock late + no decisive edge: commit a grouped all-in flag
                              # attempt (a "good enough" hit beats stalling into the −1 draw)

  Scenario = enum             # ⭐ COMMS BUS C1: the live team-event a bot classifies from
                              # its own fresh local reads (the event-driven layer above the
                              # clock playbook). Maps through the shared matrix (selectScenario
                              # Play) to a Play, so two bots on the same picture pick the same
                              # play with no comms; the bus only propagates the read so more
                              # bots converge sooner. Emitted as an opaque 2-char codeword.
    ScNone,                   # no live event — fall through to the clock playbook
    ScStack,                  # the enemy pocket in front of us is CONTESTED/stacked:
                              # converge a second gun, gate the dive (feeds grabTiming/grabGate)
    ScWipe,                   # we just cleared the enemy in front of us (post-wipe vacuum):
                              # rally + push the respawn wave together (feeds regroupPush)
    ScPeel,                   # an exposed enemy is carrying OUR flag near us: peel to the
                              # recapture race (feeds huntCarrier/StackDefense)
    ScLine                    # ⭐ ANTI-h006: a STANDING ENEMY LINE to our front (>=2 fresh
                              # guns clustered forward, NOT at the pedestal pocket) that
                              # farms a lone push. The SEAL counter to a prepared line is
                              # combined-arms, not a frontal charge: rally the wave (don't
                              # trickle) + SATURATE the cluster with grenades (a line is a
                              # cluster; area weapons punish clustering) then punch the gap.
                              # Broadcasting it converges mates a lane away who can't see the
                              # line (feeds holdLine's rally + the grenade cluster-target).

  ReactPlay = enum            # COMMS BUS: the adopted play a bot decodes from a heard
                              # codeword — the same set the classifier can trigger, so the
                              # heard play and the local read fold through one matrix.
    RpNone, RpStack, RpWipe, RpPeel, RpFlipTop, RpFlipBottom, RpLine

  ReactLevel = enum           # SHOUT-REACTION GATE: how far a heard callout may
                              # move this bot, keyed on its own task priority.
                              # Every seat in this policy is always OCCUPIED by an
                              # objective (rush / carry / escort / post), so a
                              # report never moves the FEET — the strongest verdict
                              # is a cone glance; the intel is banked regardless.
    None,                     # bank the intel only — never touch the aim
    OrientOnly                # swing the vision cone onto it (turn-and-watch)

  Vec = object                # a map-space point or direction
    x, y: float

  Actor = object              # a player visible this frame
    pos: Vec
    facingRight: bool
    hp: int                   # from the overhead pip bar; 0 = not read
    aimBrads: int             # gun bearing read from the aim-dot line; -1 unknown
    hasArc: bool              # carrying a plasma arc ("plasma arc carried" over
                              # the head) => gun DISABLED, a 136px cone specialist
    hasShield: bool           # carrying a shield ("shield carried" over the head)
                              # => 6 HP (a 4+-hp bubble) + fires 3x SLOWER. The hp
                              # pip CANNOT show this (it renders 3/3, capped at the
                              # 3-seg bar), so this marker is the only tell — without
                              # it we fight a 6-hp tank as a 3-hp cog and undershoot.

  Track = object              # a remembered player
    pos, vel: Vec
    lastSeen: int
    facingRight: bool
    hp: int                   # last observed hit points; 0 = never read
    aimBrads: int             # last observed gun bearing (aim dots); -1 unknown
    hasArc: bool              # last observed plasma-arc possession (disarmed)
    hasShield: bool           # last observed shield possession (6-hp tank, slow fire)

  CombatTune = object
    ## The fire/engage decision knobs, made per-bot so a forked policy can
    ## sharpen its shooting without touching the shipped baseline. Every field
    ## mirrors a module const; `defaultCombatTune` fills them WITH those consts,
    ## so a bot left on the default decides bit-identically to the old code —
    ## the shipped path is provably unchanged. Only the fields the const used to
    ## drive in the COMBAT decision are here; nav/post/peek geometry still reads
    ## the consts directly, so a hunter's tune never perturbs its navigation.
    fireSlackPx: float        # perp-miss corridor a shot must sit inside
    freshShotTicks: int       # only fire at tracks seen this recently
    leadTicks: float          # aim this many ticks ahead of a moving enemy
    combatDeadband: int       # settle the traverse within this error (brads)
    fireRange: float          # default engage distance
    carrierFireRange: float   # engage cap while carrying the flag
    rushEngageRange: float    # engage cap while racing for the steal
    escortEngageRange: float  # engage cap while escorting a carrier
    pocketRushRange: float    # inside this of the enemy pedestal, just GRAB
    commit: bool              # target commitment: keep firing on the enemy we
                              # already wounded until it dies/fogs, instead of
                              # re-picking the nearest each frame. Off => shipped.
    commitBonus: float        # px of priority credit for the committed target
    stickyCommit: bool        # ⭐ FINISH THE KILL (2026-07-24 focus-fire audit, Bug 1):
                              # the commit lock must SURVIVE satCap's spread-debit and the
                              # dangerScore pull-off when the LOCKED target is one-hit-from-
                              # death OR has its gun on us. Without it, a half-killed enemy
                              # that our mates also shoot (saturated, +220) or a fresh nearer
                              # dead-on threat (-320 danger) out-scores the lock and our gun
                              # SWITCHES off the enemy we'd already wounded — it recovers and
                              # kills us. SEALs: commit to a target and FINISH it.
    forceBalance: bool        # local numbers awareness (FALSIFIED 2026-07-14 as
                              # a win lever; kept behind this flag, OFF).
    outnumberMargin: int      # fall back when localEnemies - localFriends >= this
    unstuckEngaged: bool      # BUG FIX: let the stuck-recovery jink fire even
                              # while a target is selected, so a bot grinding an
                              # obstacle corner as it advances can break free.
    aimLock: bool             # ⭐ TARGET-LOCK: hold the turret on a committed
                              # enemy's bearing whenever we have a fresh track,
                              # and never reset aim to the move lane while locked.
    huntSweep: bool           # HUNTING POSTURE: with no shot, aim at the nearest
                              # remembered enemy instead of down the move lane.
    fireOnRealBody: bool      # gate the trigger on the perp-miss to the target's
                              # REAL last-seen position, not the full lead phantom.
    threatFacingBonus: bool   # danger-score: credit an enemy FACING us so we
                              # engage the greatest threat first.
    shout: bool               # EMIT shouts at all (carrier heartbeat + enemy
                              # callouts + "oh shit!" + "die"). Off => silent.
    shoutCallout: bool        # emit "E <cell>.." chess enemy-position callouts.
    shoutSurprise: bool       # emit "oh shit!" when ambushed at close range.
    shoutDie: bool            # emit "die" pre-fire when a mate is in earshot.
    reactContact: bool        # REACT to a heard mate shout: orient the vision
                              # cone toward the fix (turn-and-watch, not a rush).
    commsBus: bool            # ⭐ COMMS BUS C1 (2026-07-22, Track B): EMIT a 2-char
                              # scenario codeword ("<tok><flank>") on the shout channel
                              # when a bot classifies a live team event (STACK/WIPE/PEEL/
                              # FLIP) from its own fresh local reads. The token is opaque
                              # (a rotating table, commsCrypto) so daveey's clone can't
                              # read our play off the wire. Emit-only + mask-neutral
                              # (rides shoutWant AFTER the button mask, like vanity shouts)
                              # — turning it on never swings the gun/feet, so it cannot
                              # incur the v1/v2 cone-diversion loss on its own.
    commsPlay: bool           # ⭐ COMMS BUS C1 adopt-side: when a bot HEARS a mate's
                              # scenario codeword it adopts that play as bot.heardPlay
                              # for CommsPlayTtl ticks. selectScenarioPlay folds the
                              # heard play + the bot's OWN classification through the
                              # same shared matrix, so two bots on the same picture pick
                              # the same play and a bot that missed the shout degrades to
                              # its own read + the clock fallback (never a split, never
                              # worse than today's clock playbook). Requires playbook ON
                              # (it extends selectPlay). Reaction is MOVEMENT-INTENT only
                              # (which flank/rally), never a turret bearing (the v2 lesson).
    commsCrypto: bool         # ⭐ COMMS BUS C2: rotate the play->token table each round
                              # by a shared salt (hash of roundStart + team + a compiled-in
                              # secret) that our 8 bots derive identically but a hand-copied
                              # clone can't. Off => a fixed plaintext-ish token table (still
                              # 2-char codes, but static — fine for the FIRST value test).
    damageAware: bool         # orient toward the shooter when hit from an unseen
                              # direction (own-HP drop + "shot sound" ring).
    carrierFlee: bool         # a carrier keeps MOVING home while engaged (gun
                              # still fires) instead of advancing — FALSIFIED
                              # 2026-07-15 (net -3, conv worse): fleeing turns the
                              # back to the respawner without clearing its cone.
    carrierClearBand: bool    # ⭐ CAPTURE CONVERSION: inside the robbed pocket,
                              # route the carrier DIAGONALLY out of the respawn
                              # firing band (pedestal height ±72px, where fresh
                              # invulnerable respawners spawn aimed E-W) before the
                              # home run — never pick the mid lane that IS the cone.
    carrierSerpentine: bool   # ⭐ CARRIER-RUN SURVIVAL (2026-07-24): the carrier WEAVES while
                              # crossing watched ground on the run home. Carriers were EXEMPT
                              # from the serpentine (speed-beats-evasion) — wrong for the SLOWEST
                              # (70% speed), highest-value unit vs a map-wide hitscan gun with no
                              # back-armor: a straight predictable line is a free shot in transit.
                              # A shallow weave (small amplitude, net homeward progress preserved)
                              # forces the gun to re-slew each beat. Movement-only.
    carrierSprint: bool       # ⭐⭐ CAPTURE CONVERSION (survive=110t/drop@home=4%
                              # diagnosis): a carrier NEVER enters the combat branch
                              # (engage range 0, like pocketRush). It was burning
                              # ~4.5s pinned in the pocket firing at the INVULNERABLE
                              # spawn-protected respawner (selectFireTarget skips it,
                              # so 100% wasted) while advancing INTO the nest. Drop
                              # combat entirely: pure-navigate home at full speed.
                              # FALSIFIED 2026-07-15 (net -3): the gun buys survival
                              # by suppressing KILLABLE pursuers; a pure runner is
                              # shot in the back and dies FASTER. Kept behind flag.
    carrierScreen: bool       # ⭐⭐⭐ COORDINATION: the escort nearest the robbed
                              # pocket bodies-blocks the respawn cone — sits at the
                              # carrier's EXACT y, one body toward the pocket, so a
                              # westward/eastward respawner shot aimed at the carrier
                              # crosses the escort FIRST (selectFireTarget stops at
                              # the first body; friendly fire ON). The one mechanism
                              # the mirror can't refute away: a screen is physics.
    carrierGrabDetect: bool   # ⭐⭐⭐⭐ WAKEUP DEADLOCK FIX: the self-carry test only
                              # fires when the heart is >16px off its pedestal, but a
                              # carrier standing ON the robbed pedestal keeps the heart
                              # ~7px away (CarriedFlagLift=10) → iCarry stays FALSE →
                              # the bot never routes home and camps the pedestal it
                              # already robbed until timeout (hosted replays: 67-75% of
                              # a game frozen at the enemy pedestal → a DRAW that should
                              # have been a win). Fix via the auto-pickup invariant: a
                              # living player within FlagPickupRange of an un-carried
                              # enemy pedestal heart is INSTANTLY made carrier by the
                              # sim, so if the heart is on me AND I'm inside pickup range
                              # of the pedestal with no mate closer, I MUST be carrying.
    # ── SEAL/CQB v4 levers (2026-07-16). Each defaults false (control), all ON
    # in shippedCombatTune, each with its own harness env knob. Derived from the
    # recovered ctf-combat-strategy doctrine, reinterpreted for WIN-ONLY scoring
    # (serve winning firefights that clear a carrier's path / hold the flag →
    # captures & wipes, NOT raw kill volume).
    dangerScore: bool         # #1 GREATEST-THREAT-FIRST: a richer target danger
                              # score — a facing enemy's engage credit scales UP
                              # with proximity (a close aligned gun kills us THIS
                              # second; a far one barely threatens), and a facing
                              # AND wounded enemy is the top-value engage. Supersedes
                              # the flat threatFacingBonus tiebreak.
    twoSpeedScan: bool        # #3 TWO-SPEED SCAN: a sentry's idle sweep DWELLS on
                              # the bearing of the nearest fresh threat inside its
                              # arc for a few ticks instead of raking straight past
                              # the one bearing that matters (the turret turns at a
                              # fixed rate, so "slow" = pause on the hot bearing).
    boundingOverwatch: bool   # #6 BUDDY BOUNDING OVERWATCH: do not stroll forward
                              # across a threatened open lane while MY gun is on
                              # cooldown and a covering mate is up — duck to cover
                              # for the reload, then bound forward when the gun is
                              # live. Keeps at least one team gun always up.
    holdVsGun: bool           # ⭐ NEVER TURN YOUR BACK ON A LIVE GUN (2026-07-24, the
                              # focus-fire audit fix). boundingOverwatch only guards a
                              # gun-down bot that has a covering MATE within 720px — a
                              # SOLO bot with its gun on cooldown and a fresh enemy whose
                              # gun is ON us out to fireRange falls through to objective
                              # movement and strolls away, dying to the map-wide gun in
                              # the back. This guard catches that SOLO case: face the
                              # threat + break its line (duck) instead of turning away.
                              # SEALs: never present your back to an unsuppressed gun.
    woundedBank: bool         # ⭐ WOUNDED BANK (plan #13, the hp-keyed survival
                              # posture). At own hp == 1 (own-state ONLY — headcount
                              # appears NOWHERE in entry/exit, the REF-force
                              # distinction) disengage on the COVER model: route to
                              # a bank cell that BREAKS the fresh threat lines (out-
                              # geometry, not out-run — equal top speeds make radial
                              # retreat useless), gun held on the chaser the whole
                              # withdraw. Suspended per-frame by the finish-window
                              # (a fresh 1-hp enemy with our clear line inside
                              # FinishRange — one pull from a won exchange) and by
                              # an imminent grab (inside GrabCommitRing). Carriers
                              # never bank (carrierFlee owns them). A banked 1-hp
                              # life still counts toward the lives/wipe economy and
                              # re-arms to FULL off a kit (sim heals to MaxHp).
    pointOfDomination: bool   # #7 POINT OF DOMINATION: score overwatch posts by
                              # clear-LOS coverage of the cells where enemies
                              # ACTUALLY travel (baked from the occupancy heatmap),
                              # and give the home defender a domination post too —
                              # dominate the ground the enemy must cross.
    tempoPress: bool          # #8 TEMPO / AUDACITY: press on the half-beat — when
                              # the near threat is wounded or just fired (mid-
                              # cooldown, can't punish us), DON'T duck; close for
                              # the kill in its dead time.
    fireSuperiority: bool     # #9 PRESS-VS-BREAK ON FIRE SUPERIORITY (the correct
                              # forceBalance): break off only when we are genuinely
                              # fire-INFERIOR (outnumbered AND their guns are real,
                              # not mostly wounded), never on raw head-count — and
                              # PRESS whenever we can win the trade.
    calloutGate: bool         # SHOUT-REACTION GATE (2026-07-16): gate the REACTION
                              # to a heard callout by the bot's own task priority
                              # (SEAL need-to-know) instead of reorienting anyone in
                              # earshot. Requires shout/reactContact ON to have any
                              # callouts to gate. Off => the old indiscriminate react.
    aimThreat: bool           # AIM-DOT THREAT (2026-07-16, task #19): read a visible
                              # enemy's gun bearing from its rendered aim-dot line and
                              # replace the coarse facingRight half-plane test with a
                              # precise gun-on-me cone. Danger credit scales with how
                              # tightly the gun points at us (dead-on = lethal now).
                              # Falls back to facingRight when the dots are unreadable.
                              # Requires dangerScore (it sharpens that block's threat).
    carrierHomeStretch: bool  # CARRIER FINISH FIX (2026-07-16): on the final approach
                              # the capture column (x < ArenaCaptureClear) is protected
                              # open floor at EVERY y, so drive STRAIGHT into it at our
                              # current height instead of diagonally to an extreme lane.
                              # The extreme lanes (y≈40 / y≈619) are exactly the rows the
                              # border-attached stub columns sit on near home, and a
                              # carrier aimed at that corner wedges on the stub and never
                              # crosses the threshold — the "stuck on the last wall at the
                              # bottom of the map" deadlock. Also biases the stuck-jink
                              # toward home so a corner-grind actually breaks free.
    chaseThief: bool          # THIEF PURSUIT (2026-07-16): when OUR flag is stolen and a
                              # thief (or any enemy on our side) is in sight, CLOSE and
                              # shoot instead of sidestepping away. The generic threat-jink
                              # made a defender who spotted the carrier flee "out of fear";
                              # the capture race is lost if nobody hunts the runner.
    playbook: bool            # PLAYBOOK (2026-07-16): observation-triggered team plays.
                              # The favored attack flank OSCILLATES on the shared round
                              # clock (elapsed div PlayPeriod), so all 8 bots agree on the
                              # strong side WITHOUT comms and an opponent can't pre-stack a
                              # fixed flank. Attackers mass on the favored lane; the off-lane
                              # keeps a light feint. Posture (offense/defense) already keys
                              # off shared flag state. Verified consensus-safe: elapsed and
                              # flag-state are identical across teammates; per-game entropy
                              # does NOT exist (spawns are deterministic) so we vary on TIME.
    topBias: bool             # COUNTER-DAVEEY (2026-07-16): the observed field crosses
                              # and runs the flag along the TOP lane far more than the
                              # bottom ("daveey always goes to the top of the map"). When
                              # our flag is stolen and the thief is FOGGED (never seen this
                              # life), guess LaneTop instead of LaneMid, and post the idle
                              # home sentry high. A cheap DEFENSIVE prior: costs ~nothing
                              # when wrong (a high post still covers mid on the sweep) and
                              # puts a gun on the runner's actual lane when right.
    sentryDisplace: bool      # SENTRY DISPLACE (2026-07-16): a sentry (overwatch /
                              # home defender) that has held its post for SentryDwellTicks
                              # with nothing to shoot slides to an adjacent covered vantage
                              # instead of standing frozen. SEAL "shoot-move-communicate,
                              # never a static target"; fixes "our guys stay still far too
                              # much." It keeps commanding the same crossing (a lateral step
                              # along the watch face, ± SentryShiftPx), so coverage holds.
    cornerPreAim: bool        # CORNER PRE-AIM (2026-07-16): when a target is wall-blocked,
                              # pre-lay the turret on its EMERGENCE CORNER (the nearest cell
                              # from which the enemy can see us) instead of on its body
                              # behind the wall. The enemy's body appears exactly at that
                              # corner when it peeks, so our bullet is already on-bearing and
                              # the vision cone is already there — winning the trade instead
                              # of shooting the wall and eating the shot as it steps out.
    escortRun: bool           # ESCORT RUN (2026-07-17, round-624 KILL-case fix): when a
                              # mate carries our stolen heart and a remembered enemy is
                              # within EscortRunThreatRange of the carrier ANYWHERE on the
                              # open run home, the nearest free mate interposes one body
                              # onto the threat->carrier ray (the gun kills the nearest
                              # body in the cone, so the escort eats the shot). Distinct
                              # from carrierScreen (which only body-blocks the E-W RESPAWN
                              # cone within ~390px of the robbed pocket): the 624 carrier
                              # died at minDist=280 in MIDFIELD, alone, past every existing
                              # screen. ⚠️ partly a COORDINATION lever — the mirror measures
                              # the MECHANICAL half (carrier-survival, path-eff) but not the
                              # economy half (thinning the press); a hosted mixed-field xreq
                              # settles that. See [[CAP-escort]].
    huntCarrier: bool         # HUNT CARRIER (2026-07-17, round-624 OUT-RACE-case fix): when
                              # OUR flag is stolen, keep PURSUING the enemy carrier toward its
                              # capture edge for HuntCarrierStaleTtl after the last fix, instead
                              # of giving up when the short ThiefFixTtl converge-window lapses
                              # and parking on a static lane guess. Round-624 decode: their
                              # carrier ran EXPOSED 518 ticks and no one chased it while our
                              # own carry lost the parallel race. Pairs with carrierHomeStretch
                              # (our finish speed) — this is the DEFENSIVE half of the race.
                              # Asymmetric (turns a would-be enemy capture into a recapture
                              # race) so the self-play mirror CAN measure it. See [[CAP-homestretch]].
    preSlew: bool             # ⭐ FIRE FIRST (v8, 2026-07-18): when we have no clear
                              # shot THIS frame, pre-lay the turret (via aimLock's
                              # hold) on the freshest engageable-range enemy whose
                              # gun is most OFF us — the draw we win — instead of the
                              # merely-nearest. Our 5-tick windup then completes while
                              # its turret is still slewing onto us (OODA half-beat),
                              # so our bullet leaves first. A fire-TIMING choice inside
                              # aimLock's on-objective candidate set; requires aimThreat
                              # (enemy aim-dot read) and falls back to nearest when a dot
                              # is unreadable. NOT the refuted huntSweep (that aims off-
                              # objective at any enemy and trades wins for kills).
    staggerFire: bool         # ⭐ STAGGERED BOUNDING (v8, 2026-07-18, §G4): the
                              # complement of boundingOverwatch — when MY gun is up
                              # but a covering mate's gun is DOWN (a muzzle bloom on
                              # it = fired within the 12t reload), HOLD my up-gun on
                              # the crossing to cover its reload instead of bounding
                              # forward and leaving the lane with no live team gun.
                              # Turns a pair into alternating bounds (one gun always
                              # live), killing the "both empty on one beat → focus-
                              # fired wipe" death-burst. Movement-only; never throttles
                              # my own trigger (the engage branch always wins a clear
                              # shot), so it can't regress into fire-discipline tuning.
    regroupPush: bool         # ⭐ POST-WIPE CONSOLIDATION (2026-07-18): the v14 loss
                              # cause — after clearing the enemy nest we feed the ~72t
                              # respawn wave one body at a time and die piecemeal
                              # (losses: cash-the-wipe 0%, squander 47%). When a mid is
                              # over-extended into the enemy half, its local area is a
                              # post-wipe VACUUM (no fresh enemy near), and it is strung
                              # out from its mates, HOLD a shallow midfield rally until
                              # the trio re-forms, then release to push deep TOGETHER.
                              # A timing lever, NOT a depth cut (depth correlates with
                              # winning) — it only bites in the squander signature and
                              # does nothing once the wave is grouped. ⚠️ COORDINATION
                              # lever: the self-play mirror gives BOTH teams the regroup
                              # (benefit cancels) and its trigger — a clean wipe with the
                              # enemy carrier already dead — barely occurs in the mirror;
                              # validate on a hosted/asymmetric mixed field, not the lab.
    grabTiming: bool          # ⭐ ANTI-STACKED-DIVE (2026-07-20, the dive-death
                              # finding): 96% of our carrier deaths are AT the enemy
                              # pedestal, 0% grab->cap in every loss — we rush a lone
                              # (often gun-down) body into a stacked pocket and it dies
                              # on the touch. When the pocket is STACKED (>=GrabStack
                              # Defenders fresh guns within GrabStackRange of it), NO
                              # mate is covering us in place, and a mate IS inbound,
                              # HOLD the grab: keep the gun UP at GrabHoldStandoff and
                              # suppress the KILLABLE defenders instead of diving unarmed,
                              # then grab once a mate arrives to cover. Self-limiting: a
                              # lone last body (no inbound mate) dives NOW (= shipped),
                              # cover-in-place releases the dive, and pushOut/late all-in
                              # suicide-grabs as today. DELAYS the dive, never abandons it
                              # (NOT the refuted forceBalance/pocketRush — the pedestal is
                              # the one spot commit's kill-to-convert can't fire: spawn-
                              # protected respawners are unkillable but shoot). Asymmetric
                              # (turns a wasted grab into a covered one) so mirror-measurable
                              # on grab->cap; the "vs a real stacked defense" edge is field.
    smartGrab: bool           # ⭐⭐ ADAPTIVE POCKET COMMIT (2026-07-24, THE dive-death fix). Replaces
                              # grabTiming+grabGate's hard thresholds + suicide carve-out with a
                              # Captain-brain gate: commit the disarmed pocket touch ONLY on a real
                              # advantage read (pickEdge local numbers edge / PhForce grouped all-in /
                              # a mate covering in place); otherwise HOLD at a firing standoff and
                              # suppress the clustered pocket from range as a team. No lone suicide dive.
    touchCommit: bool         # ⭐⭐ THE TOUCH LATCH (2026-07-29, THE grab-conversion fix). FIELD-
                              # MEASURED on 123 GV26 league episodes: a steal is THE deciding
                              # axis (steal once -> we win 66.7%; never steal -> 26.4%), and we
                              # never steal at all in 58.5% of episodes. The gap is NOT approach
                              # and NOT conversion: we reach within 40px of the enemy heart as
                              # often as the field does (71 vs 79 episodes) but convert that
                              # approach to a steal only 71.8% vs THEIR 94.9%. In 20 episodes a
                              # bot sat 5-39px from the heart — pickup range is 12px — and never
                              # took it. Cause: GrabCommitRing existed but only ever DISABLED
                              # holdGrab; it set no flag, so once inside the ring four LIVE
                              # branches still outrank the 12px touch — the grenade charge
                              # (holdStill, gated on iCarry but NOT pocketRush), the engage
                              # branch (an armedPocket advances on the ENEMY, not the heart),
                              # and duck/peek (guarded on `rushing`, which is Mid-only, while
                              # wantPocketRush includes the FLANKERS — that is the 5-39px
                              # cohort). touchCommit latches a bot inside GrabCommitRing onto
                              # the heart: nothing preempts a touch that is one step away.
                              # Deliberately NOT a return to the suicide dive smartGrab fixed —
                              # the latch arms only INSIDE the ring, where the body is already
                              # committed and the cheapest way out is forward onto the heart.
    armedRush: bool           # ⭐ NEVER DISARM INTO A STACK (2026-07-24, THE dive-death fix).
                              # pocketRush's maxEngage=0 (gun OFF, no duck/dodge) rests on an
                              # OBSOLETE premise — that pedestal respawners are spawn-protected
                              # (unkillable), so shooting them is wasted. GV20+ REMOVED spawn
                              # protection (0 refs in GV22 sim.nim): those defenders are KILLABLE
                              # now. So a rusher that disarms and dives a defended pocket dies
                              # doing nothing — >half our deaths, pure waste. armedRush: when
                              # ANY fresh defender guards the pocket, keep the gun UP (engage a
                              # close band + re-enable the duck/dodge/aim branches) and SHOOT the
                              # way in / dodge, instead of a blind unarmed dive. Only a genuinely
                              # UNCONTESTED touch (no fresh defender) still rushes disarmed for
                              # speed. Offensive by construction: arrive shooting, never as a
                              # free kill. Asymmetric (turns a wasted death into fire on the
                              # pocket) so mirror-measurable on grab->cap + K/D.
    holdLine: bool            # ⭐ ANTI-OVER-EXTEND (2026-07-22, the h006 line-defense
                              # finding): the new #1 (h006) forms a LINE in its own half and
                              # lets us over-push into a converging kill (loss diag: 39% of
                              # our deaths are in the ENEMY half vs h006's ~14%; our over-
                              # extension MANUFACTURES their clean 2.97 hits/kill). SIBLING
                              # of regroupPush but the OPPOSITE trigger: regroupPush holds a
                              # mid in a post-wipe VACUUM (no fresh enemy); holdLine holds a
                              # mid that has over-extended into the enemy half INTO A STANDING
                              # DEFENSE (fresh enemies present + not local fire-superiority),
                              # rallying it at a shallow line until the wave re-forms so we
                              # engage the line together instead of trickling in to be farmed.
                              # Movement-target ONLY (combat still takes any clear shot); a
                              # lone last body / carrier / own-flag-stolen never holds; and
                              # it uses LOCAL fresh-mate-vs-fresh-enemy proxies, never a global
                              # headcount (teammates are fogged) — so it is NOT the falsified
                              # forceBalance retreat. Releases on local fire-superiority or a
                              # grouped wave. Asymmetric (we stop feeding isolated cogs) so the
                              # mirror can measure the K-D/own-half delta; the full edge is field.
    grabGate: bool            # ⭐ NUMBERS-GATED GRAB (2026-07-22, the h006 grab-discipline
                              # finding): h006 commits to the heart almost ONLY when up bodies
                              # (its carries start at a local numbers lead; steal->cap 46-64%
                              # vs our 28%); we grab at even/behind and throw the carrier away.
                              # Distinct from grabTiming (which gates a solo dive on POCKET
                              # STACKING): grabGate gates the pocket-rush on LOCAL fire-
                              # superiority near the pedestal (fresh mates vs fresh enemy guns
                              # around stealTarget) — don't open the unarmed dive unless we have
                              # the local edge that converts it. Same guard structure + REF-force
                              # firewall as grabTiming (lone last body dives NOW; pushOut/late
                              # all-in dives; DELAYS never abandons). Mirror-measurable on grab->cap.
    avoidDisarm: bool         # ⭐ SWORD/SHIELD AVOID (v7, 2026-07-19): the live league
                              # runs GameVersion 7 — a sword or shield picked up on a 12px
                              # touch is AUTOMATIC and sets canFire=false (silent disarm:
                              # the gun goes dead until death). Our unadapted pathing walks
                              # over one ~0.4×/game (measured, SS-PROBE) and then "fires"
                              # air for ~13s. This adds a soft repulsion from a "sword"/
                              # "shield" pickup sprite so a bot that is NOT deliberately
                              # collecting one steers a body-width around it. Pure downside
                              # removed; MIRROR-MEASURABLE (SS-PROBE pickup count → ~0). The
                              # ONLY v7 lever safe to lab-prove; the two below are field-only.
    shieldTank: bool          # ⭐ SHIELD-TANK ESCORT (v7, 2026-07-19): a shield gives 6 HP
                              # but canFire=false. A carrier-escort with our flag stolen and
                              # a shield pickup in reach deliberately grabs it, then body-
                              # blocks the carrier's respawn/threat cone as a 6-HP wall (it
                              # can't shoot anyway, so trading its gun for a 2× tank on the
                              # ray is free). Extends carrierScreen/escortRun with a fat
                              # shield. ⚠️ COORDINATION lever — the mirror gives both teams
                              # the tank and its trigger (mate carrying past our shield) is
                              # rare in self-play. Validate hosted, gated OFF.
    sprayGrab: bool           # GV36 melee: opportunistic spray-can pickup
    nadeLob: bool             # GV36 lob discipline: the engine throws along the CURRENT
                              # aim at C-release, and a mid-charge slot-servo correction
                              # sweeps whole revolutions (13 ticks for ±1 slot) — so a
                              # release mid-sweep flies the WRONG WAY (field-observed).
                              # Freeze the lob bearing at charge start; release only on
                              # a settled turret (holding C past full just caps range).
    spinCap: bool             # GV36 spin budget: gcd(5,32)=1 makes an EXACT ±1-slot
                              # correction cost 13 held ticks = two full blind
                              # revolutions (vision rides the aim). Cap the budget at 4
                              # ticks; settle on the best cheaply-reachable slot and let
                              # fire-gate slack govern the residual ≤1 slot (11.25°).
    spinCapRangePx: float     # ⭐ RANGE-AWARE SPIN BUDGET (the spinCap logic fork). The
                              # accepted residual is ANGULAR but the fire corridor is
                              # LINEAR: perpMiss = D·sin(err). One slot of residual (8
                              # brads) costs 0.195·D of miss, so past D=87px it exceeds
                              # the 17px corridor and the trigger can NEVER open — the
                              # budget is free in CQB and a fire-gate LOCKOUT at range.
                              # Apply it only to combat traverses inside this range;
                              # beyond it pay the exact plan (the v38 servo) so err→0 and
                              # the corridor actually opens. Non-combat traverses always
                              # keep the budget (nothing fires there, so the blind
                              # multi-rev spin is pure cost). Inf == plain v39.
    shieldRush: bool          # ⭐⭐ SHIELD-RUSH CARRIER (2026-07-23, the grab→cap fix): the
                              # A/B + n=37 teardown proved we LOSE ON THE RUN HOME — 34 steals /
                              # 4 caps (12%) vs h006, carriers die at MIDFIELD crossing back. A
                              # shield = 6 HP (survive 6 hits vs 3) and a carrier can hold BOTH
                              # flag + shield and still CAPTURE (tryPickupFlags/checkWin don't
                              # exclude it). The prior "grab a shield AFTER stealing" variants
                              # were geometry-void (enemy shield is DEEPER in). This grabs OUR
                              # OWN endzone shield PRE-steal (home-side ¾-height, near spawn — a
                              # cheap detour TOWARD home), so the rusher carries home at 6 HP the
                              # whole way. Mirror-MEASURABLE (per-team HP edge → grab→cap), unlike
                              # the coordination levers. GV21 makes it stronger (no spawn-protect
                              # → carriers more exposed). Gated to the rusher seat.
    planLayer: bool           # ⭐⭐ CONTINGENCY STATE MACHINE (2026-07-23, "chess not
                              # checkers"): drives movement posture from teamPhase (OPEN/
                              # PROBE/PRESS/ESCORT/DEFEND/FORCE) instead of the flat one-
                              # scenario-one-play matrix. OPEN groups the opening clash;
                              # ESCORT full-collapses the free guns onto the carrier lane;
                              # FORCE commits a grouped all-in before the −1 timeout. All
                              # phases are a pure fn of shared signals so the team flows
                              # branch→branch unanimously (no thrash / no split-decide).
    defendTeeth: bool         # ⭐ PhDefend RECAPTURE TEETH (v29, 2026-07-29). v26 gave DEFEND
                              # an intercept target, but it aimed at `mateCarryPos` — the
                              # position of OUR mate carrying the ENEMY heart, NOT the thief
                              # holding ours. Wrong entity, and it is (0,0) whenever no mate
                              # carries, so the `> 0.5` guard fell through to `me.y` and the
                              # "converge on the thief's lane" collapse never converged. This
                              # routes the 6 attacker seats at the REAL thief fix (bot.carrierPos
                              # / carrierSeen — the same globally-legible read huntCarrier uses),
                              # predicting the intercept toward the thief's own capture edge and
                              # guarding the mid crossing it MUST pass when the fix is stale.
                              # Recapture = KILL (body-block is void), so the engage teeth stay.
    forceClockTick: int       # forceTiming's actual trigger tick (sweepable by the eval
                              # harness via FORCE_TICK so the timing constant gets a real
                              # sweep instead of a second guess). Ignored unless forceTiming.
    forceTiming: bool         # ⭐ PhForce TIMING (v29, 2026-07-29). ForceClockTick=3800 was a
                              # first-guess constant ("~76% of the 5000 clock") and MEASURED at
                              # 0 firing frames out of 266k: GV23 games end by WIPE at mean 2410
                              # ticks (min 1541 max 4004), so the late all-in never armed. Moves
                              # the trigger to ForceClockTickTuned (sweepable via the harness) so
                              # the force window lands inside a real game's lifetime.
    swordAmbush: bool         # ⭐ SWORD AMBUSH (v7, 2026-07-19): a sword is a 26px forward-
                              # arc GUARANTEED kill (instant, no windup, ignores the 3-hit
                              # gun) but canFire=false while held. A back-line/pocket bot
                              # with no clear ranged shot and a sword pickup in reach grabs
                              # it, then treats the attack button as melee: it closes on the
                              # nearest enemy inside SwordReach and swings. Wins the point-
                              # blank scrum the windup gun loses. ⚠️ trades the gun for melee
                              # — only fires when boxed in close with a sword handy; a
                              # COORDINATION/positional lever, validate hosted, gated OFF.
    medTopOff: bool           # ⭐ MED-KIT TOP-OFF (2026-07-20, doctrine: an operator
                              # tops off HP between contacts, never fights hurt when a
                              # kit is free). GameVersion 9 seeds two center-line med
                              # kits; a wounded living bot heals to FULL on a 12px touch
                              # (sim tryPickupMedKits) and a healthy bot walks over one
                              # untouched, so a kit is never wasted — a pure-upside
                              # MOVEMENT lever (never touches the trigger). A wounded,
                              # out-of-contact bot routes to the nearest VISIBLE kit
                              # within MedKitDetour. Fog only reveals a kit near center,
                              # so distance already self-limits the pull; the gate fires
                              # ONLY when safe (engage<0 AND nearThreat<0) and never for a
                              # carrier / committed grabber / escort / stolen-flag defender
                              # (they own a higher objective), so it can't pull a bot off a
                              # live objective or into a gunfight. Mirror-measurable: both
                              # sides get chipped near mid, so the healthier survivor wins
                              # the next contact — an asymmetric survival edge the self-play
                              # mirror can score (carrier-survival / K-D / deaths).
    medEcon: bool             # ⭐⭐ MED-KIT ECONOMY (2026-07-28, from the live-league Elo
                              # assessment: the field took 42 heals to our 11 over 20 real
                              # episodes). medTopOff had the right doctrine but a gate that
                              # almost never opens mid-game. medEcon keeps the doctrine and
                              # fixes the three things that closed the gate:
                              #   1. STATIC POSITION — the kits are at fixed engine coords
                              #      (verified vs 53 league heal events), so stop requiring
                              #      the sprite to be VISIBLE in the fog cone. A wounded bot
                              #      walks to a remembered kit the way it walks to a pedestal.
                              #      This is the big one: the old visibility requirement is
                              #      why a 320px-away kit was invisible and thus ignored.
                              #   2. WIDER DETOUR — MedKitEconDetour(320) over MedKitDetour(150),
                              #      because the walk is now the only cost.
                              #   3. LIGHT CONTACT — at MedKitLightContactHp a bot breaks
                              #      contact with a threat that is NOT aiming at it to heal.
                              #      At 1 hp the next bullet kills, so the heal outranks the
                              #      duel; a threat actually pointing at us still wins (we
                              #      never turn our back on a live gun — the holdVsGun rule).
                              # Still a pure MOVEMENT lever (never touches the trigger) and
                              # still yields to every real objective (carrier / escort /
                              # committed grabber / stolen-flag defender / pickup seeker).
                              # Mirror-measurable for the same reason medTopOff was: it is a
                              # resource RACE, not a coordination lever, so self-play scores
                              # it (heals, deaths, K-D) — unlike comms.
    medSee: bool              # ⭐⭐ medSee (2026-08-05, issue #16): give medEcon its EYES.
                              # medEcon above buys the RIGHT doctrine with a TWO-TEAM ARENA
                              # coordinate: its candidate set is exactly the two formula spots
                              # (MapW/2, MapH/3) and (MapW/2, 2*MapH/3), and its only use of
                              # the kit SPRITE is the on-spot presence check — so it can never
                              # route to a kit it can SEE. On a generated board (every paintbot
                              # episode) the formula is wrong: the generator DRAWS the pair's y
                              # per map from a random band, and on a 4-team board there are FOUR
                              # kits in a rot90 orbit that is nowhere near the centre line.
                              # A wounded bot therefore walks to an empty patch of floor while a
                              # real kit sits in its vision cone (Maxwell's replay read).
                              # medSee makes the candidate set {VISIBLE kit sprites} UNION {the
                              # known formula spots}, nearest wins, both capped by
                              # MedKitEconDetour. It changes NOTHING else: same hp gate, same
                              # higher-objective yields, same in-contact rule, same aimedAtUs
                              # hold-vs-gun rule, same HUD-indicator edge filter, and the formula
                              # spots keep their on-spot presence check (a visible sprite needs
                              # none — seeing it IS presence).
                              # ⚠️ It adds ZERO new disengagement: a bot walking under medSee was
                              # ALREADY walking under the champion, just to the wrong place. That
                              # is the discriminator from woundedBank / learned-kit-spots, which
                              # both removed a gun from the fight and lost.
    satCap: bool              # ⭐ DISTRIBUTED FIRE (2026-07-20, backlog #2, FM 3-90
                              # fire-distribution): "destroy the greatest threat first,
                              # THEN distribute fires — avoid target overkill." Enough
                              # guns to kill is sufficient; a further free gun reassigns
                              # to the highest-danger UNCOVERED live enemy. We already
                              # count mate aim-rays (mateTargeted). When >=2 mate guns are
                              # already lined on an enemy whose hp the pair can finish
                              # (pendingKill), a THIRD gun gets no focus credit for it —
                              # and if a fresh UNCOVERED live enemy is also engageable, it
                              # is preferred, so no live gun is left unengaged. A
                              # complement to commit/aimLock (NOT a dilution): it fires
                              # ONLY past the kill-sufficiency threshold, so the proven
                              # concentration still gets its 2 guns; the 3rd+ just stops
                              # dogpiling. Mirror-measurable (changes which enemies die and
                              # how many free shots we eat), no comms.
    noMask: bool              # ⭐ DON'T MASK FIRES — mover-side (2026-07-20, backlog #3,
                              # ATP 3-21.8): "the moving element must not mask the fires of
                              # the base-of-fire element." friendlyBlocked handles this only
                              # from the SHOOTER'S side (the mate holds fire, losing a whole
                              # ~17t fire cycle). Move the cost to the MOVER (who has slack):
                              # a navigation step is soft-repelled off any cell on the ray
                              # between a mate holding a live (off-cooldown) gun and that
                              # mate's target, so we don't walk into the mate's shot. Pays
                              # OBJ-2 fire-time in the exact focus-fire geometry we win with;
                              # one-sided (realized per team) so mirror-measurable. Turret-
                              # neutral, no comms.
    assaultThrough: bool      # ⭐ NEAR-AMBUSH → ASSAULT THROUGH (2026-07-20, backlog #6,
                              # Battle Drill 4): caught in a NEAR ambush (point-blank, in
                              # the kill zone), return fire and assault THROUGH — never turn
                              # your back at knife-fight range. When an UNTRACKED enemy
                              # appears inside SurpriseRadius (the existing surprisePos read)
                              # with its gun-cone on us and no cover nearer than the enemy,
                              # suppress the retreat/duck branch and close-and-fire straight
                              # down the bearing: charging keeps our gun on-axis and lowers
                              # the enemy's angular rate (nulls bearing error faster) while
                              # the slow 5-brad turret would lose a turn-and-run. ⚠️ GATED
                              # HARD vs REF-force: this is CHARGE keyed to surprise + close
                              # range + gun-on-me, NEVER to head-count; it does not break or
                              # retreat. Today surprisePos drives only a vanity shout. Aim +
                              # movement reflex, no comms, mirror-measurable.
    offCone: bool             # ⭐ OFF-CONE APPROACH (2026-07-20, backlog #4, Battle
                              # Drill 6 "Knock Out a Bunker"): never assault an oriented
                              # gun down the axis it covers — approach through its blind
                              # side. The offensive dual of aimThreat: when closing on an
                              # engage target whose aim-dot cone (aimBrads) is laid on a
                              # lane, bend the APPROACH bearing so we arrive from OUTSIDE
                              # its ±AimOnConeBrads cone — it must slew the uncappable
                              # 5-brad/tick turret to face us while our gun is already on
                              # its body. A movement-only override (touches the feet, not
                              # desiredAim, which stays on the enemy); scores approach cells
                              # by the enemy's required slew-to-face and picks the max, then
                              # nav-steers there so walls are respected. Requires aimThreat
                              # (needs a readable cone); falls back to the shipped beeline
                              # when the dot is unreadable. Mirror-measurable (wins aim
                              # races), no comms.
    fatalFunnel: bool         # ⭐ DEFENSIVE FATAL FUNNEL (2026-07-20, backlog #5, FM
                              # 90-10-1 App K): the defender's half of the fatal funnel —
                              # orient the weapon ON the chokepoint a channelized enemy MUST
                              # cross, before any target is seen, so fire is immediate with
                              # zero orient/lay delay. An idle Overwatch/HomeDefender sentry
                              # with NO live track pre-aims the turret at the throat of the
                              # nearest chokepoint on the enemy's approach axis (toward our
                              # pedestal) instead of the two-speed sweep. Vision rides the
                              # aim, so the cone lights the throat; the 5-brad turret is thus
                              # already lined when a body funnels through — acquisition ~0
                              # instead of a 15-30t re-slew. Breaks to a real target the
                              # instant one appears (LOCK-1 style). ⚠️ GUARDRAIL vs REF-hunt:
                              # only the idle no-track sentry pre-lays, and it must not tunnel
                              # onto a dead lane. Mirror-PARTIAL (like huntCarrier the mirror
                              # rarely mounts a deep unchallenged approach to defend against)
                              # — may need a hosted field to score. Gated OFF.
    aimRotRead: bool          # ⭐⭐ AIM READBACK RESTORATION (2026-07-20): GameVersion 7
                              # retired the "aim dot <color>" line (no-op addAimIndicators
                              # since e3bcf2e) — so observedAim (our own drift resync),
                              # mateAimBrads (focus-fire mate rays), and enemy aimBrads
                              # (aimThreat's full-cone dangerScore + preSlew's off-us read)
                              # have ALL been silently dead on the live engine since v7.
                              # aimThreat/dangerScore degrade to the coarse facingRight
                              # half-plane; focus fire and preSlew are inert. This reads the
                              # aim back from the soldier sprite ID instead (16 pre-rotated
                              # steps sweep with aimBrads, id = base + team*16 + rot), ~±8
                              # brad resolution vs the dots' ~±2 — coarser but alive. Label-
                              # blindness family: the DATA CONTRACT moved channels (label →
                              # sprite id); fix-forward, gated OFF until the A/B proves it.
    counterArc: bool          # ⭐ COUNTER-ARC (Play C, GameVersion 15 plasma arc): an enemy
                              # holding a plasma arc has its 1300px gun DISABLED for the rest
                              # of its life (canFire=false while hasPlasmaArc, no drop) and
                              # its lethal cone reaches only 136px. Beyond that it is the
                              # softest high-value target on the board — a free kill that also
                              # deletes the enemy's whole AoE play. This bumps such a carrier's
                              # engage priority (prio -= CounterArcBonus) ONLY when it sits
                              # beyond PlasmaArcReachPx+buffer (safely disarmed); inside the
                              # cone the existing close+aim danger terms already top it. Reads
                              # the "plasma arc carried" sprite (fog-gated). Requires
                              # dangerScore (sharpens that block, like aimThreat). Retarget-
                              # ONLY — no movement/back-off branch (that's a separate future
                              # arcStandoff lever, kept clear of REF-force). Mirror-measurable
                              # (symmetric readable object, asymmetric kill value, no comms).
    arcBreach: bool           # ⭐ ARC BREACHER (2026-07-22, the anti-line OFFENSE): the
                              # plasma arc is a MULTIKILL cone (136px reach, dmg 3, hits
                              # everyone in the ~14° arc at once, instant/no-windup). A
                              # line is a CLUSTER — the perfect cone target. When a line
                              # is classified/heard, ONE designated breacher seat (fixed,
                              # not lowest-alive — teammates are fogged) grabs the arc,
                              # charges the seam, and fires the cone across the cluster
                              # while the rest are base-of-fire. Trades the breacher's gun
                              # for its life (canFire=false while held) — a deliberate
                              # specialist swap, so gated to the breacher seat + a live
                              # line only. Movement+attack-intent; requires commsPlay (the
                              # line read). Field-only (no line forms in the mirror).
    gv21Press: bool           # ⭐ GV21 AGGRESSION (2026-07-23, the h006-loss recalibration):
                              # the engine deleted spawn-protection (fresh respawners are
                              # KILLABLE now, not a 1s invuln wall) and made draws −1 with a
                              # 5000-tick clock — so decisive KILLS/wipes win and caution
                              # loses. A/B teardown: we lose to h006 by −6 K/D, out-killed in
                              # open combat. This presses harder: the fire-superiority break
                              # only trips at a WIDER enemy overmatch (gv21OutnumberMargin),
                              # so a lone gun keeps trading instead of ceding the firefight
                              # that the clock now forces us to win. Pure combat posture.

  Bot = ref object
    slot: int
    team: Team
    myColor: string           # our ACTUAL wire color ("red".."yellow"): the
                              # slot-dealt guess until the self marker — the one
                              # sprite only we ever see — confirms it. On a
                              # 4-team board the red/blue parity guess is wrong
                              # for half the seats, and a wrong color blinds
                              # every label scan (the statue bug).
    colorLocked: bool         # self marker seen this game: myColor is truth
    stealPedPos: Vec          # OBSERVED enemy pedestal (never fogged); cached
    stealPedSeen: bool        # because the banner vanishes while it is carried
    ownPedPos: Vec            # our own pedestal, likewise observed
    ownPedSeen: bool
    wasCarrying: bool         # edge detector for our OWN carry (grabPos stamp)
    grabPos: Vec              # where THIS carry began: the fight-out breakout
                              # is measured from the actual snatch point
    aimStepBrads: int         # GV36: brads the server turns per held rotate
                              # tick (aimTurnRate SLOTS x 8). Inferred live
                              # from own-aim marker deltas (default 40 = the
                              # league manifest's aimTurnRate 5), so a config
                              # change cannot silently break the servo again.
    prevStatedAim: int        # last frame's stated aim, for the inference
    lifeStart: int            # tick of this life's (re)spawn; shieldRush's
                              # opening window is per LIFE, since every respawn
                              # starts at the shield's own column
    plantUntil: int           # CQB plant: movement suppressed until this tick
                              # (set on a close-range trigger pull; the locked
                              # ray must not parallel-shift during the windup)
    role: Role
    tune: CombatTune          # fire/engage knobs; default == baseline consts
    tick: int                 # sim ticks, advanced by frames received
    navBuilt: bool
    cellWalkable: seq[bool]   # eroded walkability, GridW x GridH
    coverCell: seq[bool]      # walkable cells hugging an obstacle
    exposure: seq[bool]       # cells a remembered enemy could shoot into
    navDist: seq[int32]       # cost field toward navGoal
    navGoal: int              # goal cell of the current field, -1 = stale
    navStamp: int             # tick the field was computed
    postHold, postPeek: Vec   # overwatch cover post and its peek cell
    postReady: bool
    enemyPosts: seq[Vec]      # the mirrored ENEMY sniper peek cells
    chokeHold: Vec            # defender hold point snapped to cover
    funnelThroat: Vec         # fatalFunnel: center of the narrowest walkable
                              # passage on the enemy's approach axis to our
                              # pedestal (pure deterministic map geometry,
                              # computed once from the walkability grid)
    funnelReady: bool
    dominatePost: Vec         # #7 POINT OF DOMINATION: the defensive cover cell
    dominateReady: bool       # with the widest clear LOS over the enemy approach
    behindLines: bool         # flanker has crossed deep into the enemy half
    enemies: seq[Track]
    mates: seq[Track]
    carrierPos, carrierVel: Vec   # last fix on the thief carrying OUR flag
    carrierSeen: int
    lastEnemySeen: int        # last tick ANY enemy was inside our vision
    gameStart: int            # tick of the last lobby-to-playing transition
    firedLast: bool           # A was set on the previous sent mask
    estAim: int               # dead-reckoned own aim angle in brads
    rotSign: int              # rotation of the last sent mask: +1 B, -1 Select
    wasDead: bool             # respawn resets the aim to the spawn heading
    scanHigh: bool            # scan sweep currently heading to the high end
    lastPos: Vec
    stuckTicks: int
    jinkUntil: int
    jinkBits: uint8
    nadeCharge: int           # ticks the C button has been held; 0 = idle
    mateFixPos: Vec           # last SEEN position of a mate-carried enemy heart
    mateFixTick: int          # tick of that sighting; 0 = never seen this game
    nadeNeed: int             # charge ticks required for the planned throw
    nadeLockAim: int          # nadeLob: lob bearing frozen at charge start (-1 idle)
    nadeHold: int             # nadeLob: full-charge ticks spent waiting for the turret
    shoutWant: string         # chat packet to send after this frame's input
    lastShoutTick: int        # rate limit: server allows one shout per second
    heardPlay: ReactPlay      # COMMS BUS: play decoded from the last heard codeword
    heardPlayTick: int        # tick that codeword was heard (decays after CommsPlayTtl)
    lastCommsTick: int        # own rate limit for emitting a scenario codeword
    lockPos: Vec              # committed target's last-known position, matched
    lockUntil: int            # frame-to-frame; commit holds it until this tick
    lockHp: int               # committed target's last-seen hp (0 = unknown)
    aimLockPos: Vec           # TARGET-LOCK: the enemy the turret is pinned on,
    aimLockUntil: int         # held (aim stays on its bearing) until this tick
    retreatUntil: int         # force-balance withdrawal committed until this tick
    bankCell: int             # woundedBank: cached LOS-break bank cell (-1 = none)
    bankCellTick: int         # woundedBank: tick that cell was computed (BankRecalc)
    bankBlindSince: int       # woundedBank: last tick a fresh threat had a clear
                              # pixel ray to us (HOLD sub-mode after BankBlindTicks)
    when defined(wbprobe):
      pWasBanking: bool       # probe: banking state last frame (segment edges)
      pBankEnter: int         # probe: tick the current bank segment began
      pHadLine: bool          # probe: a fresh threat line existed this segment
      pBroke: bool            # probe: that line was broken this segment
      pHp1Since: int          # probe: tick own hp became 1 (-1 = not at hp 1)
    shieldRushDone: bool      # shieldRush: latched once we grabbed the opening shield OR
                              # gave up (mate took it) — stops re-detouring mid-run
    assaultUntil: int         # assaultThrough: near-ambush charge committed until
                              # this tick (Battle Drill 4 — never turn your back
                              # at knife range once the charge is on)
    regroupReleaseUntil: int  # regroupPush: once the wave is grouped, the joint
                              # push is committed until this tick (hysteresis so we
                              # don't re-hold the rally as the pack naturally spreads)
    regroupHoldUntil: int     # regroupPush: sticky rally-hold — set while holding so
                              # pulling back below the trigger depth keeps holding
                              # (continue at the shallower rally line) instead of
                              # stuttering forward across the trigger line and back
    holdLineReleaseUntil: int # holdLine: once local fire-superiority / a grouped wave
                              # releases the line-hold, commit the joint push until this
                              # tick (hysteresis, mirrors regroupReleaseUntil)
    holdLineHoldUntil: int    # holdLine: sticky rally-hold (mirrors regroupHoldUntil)
    ownHp: int                # our own hp last frame (MaxHp = full); 0 = unread
    surpriseShoutTick: int    # last tick we shouted "oh shit!" (own rate limit)
    dieShoutTick: int         # last tick we shouted "die" (own rate limit)
    orientPos: Vec            # a heard-shout / damage bearing to face for a beat
    orientUntil: int          # keep the vision cone on orientPos until this tick
    calloutPos: Vec           # SHOUT-REACTION GATE: nearest callout heard THIS
    calloutTick: int          # frame — STAGED for the task gate (start of decide),
                              # not yet acted on. The gate (once commitment state
                              # is known) decides whether it earns a cone glance,
                              # which reuses orientPos/orientUntil.
    sentrySince: int          # SENTRY DISPLACE: tick this sentry settled on its
                              # current post; a dwell past SentryDwellTicks with no
                              # target triggers a lateral shift to the next vantage.
    sentryShift: float        # current lateral offset (± along the watch face) the
                              # sentry adds to its post; flips sign each displacement.
    arcBreachUntil: int       # ARC BREACHER: once the designated seat commits to the
                              # arc run (a line was live and we broke off for the pickup),
                              # hold the commit until this tick so a FLICKERING line read
                              # (localSc/heardPlay decay frame-to-frame) can't abort the
                              # ~200px trek to the back-corner spawn mid-run. Movement-only.
    arcLinePos: Vec           # ARC BREACHER convergence: last-known location of the called
                              # line (own cluster centroid when we classify ScLine, or a
                              # heard caller's bubble when we adopt RpLine). A disarmed dry
                              # breacher charges HERE, not a blind me.y seam (the audit's
                              # "cones an empty lane" fix) — so the armed cone converges on
                              # the REAL cluster across fog. (-1,-1) = no line located yet.
    arcLineTick: int          # tick arcLinePos was set; decays with CommsPlayTtl so a stale
                              # location doesn't pull the breacher onto a line that's gone.
    sawLineTick: int          # ARC BREACHER opponent-adaptivity: last tick ANY line was seen
                              # (classified locally OR heard). The proactive pre-arm requires
                              # this to be recent — so the breacher only trades its gun for the
                              # arc vs opponents that ACTUALLY play defensive lines (h006-style).
                              # vs an aggressive no-line field it stays a full gun (dormant),
                              # never paying the disarm cost for a line that never comes.

proc roleForSeat(seat: int, team: Team): Role =
  ## Deterministic role spread over the 8 per-team seats. Seats 2 and 3 both
  ## spawn at flag height, but the sim's un-mirrored +-6px spawn offset makes
  ## seat 3 the closest spawn to the flag for Red and seat 2 for Blue — the
  ## rusher takes whichever is closest so we win the opening pickup race.
  ## Under fog the attack wave is six strong (a mid quad plus two flankers):
  ## with no global flag tracking a carrier that slips the contest is hard to
  ## reacquire, so committed offense converts steals into captures, and the
  ## back line is one lane sniper plus the home defender.
  when defined(rushAll):
    # Shuffled-seat leagues deal this policy 1-2 agents onto random mixed
    # teams: coordinated-wave roles waste the seat, and a single capture wins
    # the episode outright, so every seat plays the flag-racing rusher.
    MidTop
  else:
    # ⭐ PREFIX-BALANCED SPREAD. The old order allotted eight roles to eight
    # seats and assumed we owned ALL of them — true in the 8v8 league, false in
    # every paintbot variant. Paintbot seats four entrant policies per episode,
    # so we hold a STRIDED SUBSET of our team: team-seats {0,2,4,6} on a 2-team
    # board, {0,1,2,3} on a 16-seat four-team board, all eight only on 4ffa8.
    # Under the old order those subsets came out as four attackers and NO
    # defender and NO overwatch (and on 4ffa8 the div-2 clamp saturated and
    # produced FOUR home defenders on a giant map).
    #
    # So the order is now balanced on the prefixes we actually get dealt, and
    # the squad is self-sufficient instead of assuming the other half of the
    # team complements it — we do not control those seats, and in 2v2 they are
    # a different entrant with its own plan.
    #   {0,2,4,6} -> MidTop, HomeDefender, MidBottom, Overwatch
    #   {0,1,2,3} -> MidTop, MidBottom, HomeDefender, MidGuard
    #   {0..7}    -> three mids, two flanks, guard, overwatch, defender
    # Every one of those carries at least one body on our own heart, which in a
    # free-for-all is existential: a capture ELIMINATES us outright (GV32).
    # ⚠️ The prefix-balanced REORDER of this table was measured and REJECTED:
    # seat-rotated 2v2 A/B, 8 seeds both seatings, kill differential armR -46 /
    # armB +5 (seat-adjusted -20.5). It has to be positive on BOTH seatings to
    # count, and it was strongly negative on one. Plausible mechanism: in a
    # regime where captures almost never happen (1 in 13 games locally), the
    # HomeDefender and Overwatch it buys have nothing to do, and it paid two
    # attackers for them. The ORIGINAL order stands.
    #
    # What survives from that work is the SEAT INDEX below (slot div teams,
    # the engine's own slotIdentityIndex) — that is a plain bug fix: the old
    # div-2 reading ran past this table on a 32-seat four-team board and
    # clamped four seats onto HomeDefender.
    # ⛔ MEASURED AND REJECTED (2026-08-03): a free-for-all role spread that
    # promoted seats to HomeDefender when GameTeams > 2, on the reasoning that
    # you win a 4-team board by being last standing so survival dominates.
    # Paired mixed-opponent 4ffa8, 3 seeds, our policy vs a different policy on
    # the other three teams: mean change in alive-fraction 0.00, mean change in
    # our-heart-retention 84 ticks WORSE. A wash. Offence was unchanged (both
    # arms carried an enemy heart zero times) — the earlier "it gave up
    # offence" read came from an unpaired run on a nondeterministic rig.
    # The premise may still be right; this implementation of it bought nothing.
    case seat
    of 0: FlankBottom      # wide bottom lane, get behind the contest
    of 1: MidGuard         # third mid, trails offset high and cleans up
    of 2: (if team == Blue: MidTop else: MidBottom)
    of 3: (if team == Red: MidTop else: MidBottom)
    of 4: MidBottom        # fourth mid: the second trailing attacker
    of 5: Overwatch        # cover post flanking the ring: the lane sniper
    of 6: FlankTop         # wide top lane, get behind the contest
    else: HomeDefender     # choke guard before our capture column

proc selectPlay(elapsed: int, ownStolen: bool): Play =
  ## The team's shared play, computed from SHARED signals ONLY so all 8 bots
  ## converge on it independently (no comms). `elapsed` = tick - gameStart is
  ## identical across teammates; `ownStolen` is globally legible flag state.
  ## Deliberately keys off NOTHING local (my own sightings) — a local read would
  ## split the team. Own flag stolen => everyone knows to defend/recapture; else
  ## the favored attack flank oscillates on the shared clock so the strong side
  ## is unpredictable to an opponent without per-game entropy (which doesn't
  ## exist — spawns are deterministic).
  if ownStolen:
    StackDefense
  elif ((elapsed div PlayPeriod) and 1) == 0:
    PushTop
  else:
    PushBottom

when defined(phprobe):
  # -d:phprobe ONLY (2026-07-29): the contingency phase machine's OCCUPANCY. Answers the
  # two questions the v21 design doc left as guesses: which phases the team actually
  # occupies, and how late the GV23 clock (MaxTicks 5000 + banked overtimeTicks) runs.
  # Never compiled into the shipped player.
  var phFrames*: array[TeamPhase, int]   # decide() frames spent in each phase
  var phMaxElapsed* = 0                  # the latest elapsed round-tick any bot observed
  # defendTeeth funnel: which freshness tier the recapture intercept resolved to. A tier
  # that stays 0 NAMES the gating condition (the diagnostic the v26 fix never had).
  var dtFresh* = 0                       # frames steered at a FRESH predicted thief fix
  var dtStale* = 0                       # ...at the crossing guard on the last fix's lane
  var dtBlind* = 0                       # ...no usable fix at all (the v26 fallback)
  var dtPhase* = 0                       # frames in PhDefend at all (the population)
  var dtNotCarry* = 0                    # ...and not carrying (the movement block's gate)
  var dtAttacker* = 0                    # ...and holding an ATTACKER seat (the 6 hunters)
  var dtOn* = 0                          # ...and defendTeeth is actually ON in the tune

proc teamPhase(elapsed: int, ownStolen: bool, efState: EnemyFlagState,
               pickEdge: bool, forceTick: int = ForceClockTick): TeamPhase =
  ## ⭐⭐ THE CONTINGENCY STATE MACHINE. A PURE function of shared signals so all 8
  ## bots pick the SAME phase independently (the "backstop the caller" design — no
  ## unit must survive to hold the plan). Priority order IS the branch tree: the
  ## higher-priority trigger always wins, so a phase transition is unanimous and
  ## instant across the team (no thrash, no split-decide). Order:
  ##   1. ownStolen        (globally legible)      → DEFEND  — flag safety first, always
  ##   2. we carry the heart (globally legible)    → ESCORT  — the capture window, collapse
  ##   3. clock late + no edge (shared clock)      → FORCE   — beat the −1 timeout draw
  ##   4. local pick edge (comms-accelerated hint) → PRESS   — spend the man-advantage
  ##   5. opening window (shared clock)            → OPEN    — win the first clash grouped
  ##   6. otherwise                                → PROBE   — pressure the read, hold finish
  ## pickEdge is the ONE local-approximated input (a fresh local kill-advantage); it is a
  ## convergence ACCELERATOR, not load-bearing — with pickEdge always false the machine
  ## still flows OPEN→PROBE→(ESCORT/DEFEND/FORCE) purely on shared signals.
  ## `forceTick` is the FORCE trigger (default = the untuned ForceClockTick constant so an
  ## unflagged caller is byte-identical); forceTiming passes the measured ForceClockTickTuned.
  ## It stays a parameter rather than a tune read so the machine remains a pure function of
  ## its inputs — every bot passes the same compiled-in value, so the phase stays unanimous.
  if ownStolen:
    PhDefend
  elif efState == EfCarried:
    PhEscort
  elif elapsed >= forceTick:
    PhForce
  elif pickEdge:
    PhPress
  elif elapsed < OpenPhaseTicks:
    PhOpen
  else:
    PhProbe

# ── COMMS BUS core (C1/C2, 2026-07-22) ────────────────────────────────────────
proc roundSalt(gameStart: int, team: Team, crypto: bool): int =
  ## The per-round rotation offset for the codeword table. With commsCrypto ON
  ## it is a hash of (roundStart, team, the compiled-in secret) — identical
  ## across our 8 same-team bots (they share gameStart + team + salt) but opaque
  ## to a clone that hand-copied a static token→play map (it can't derive our
  ## rotation without the salt). OFF => 0 = a fixed table (still 2-char codes).
  if not crypto:
    return 0
  var h = uint32((gameStart * 2654435761'i64) and 0xFFFFFFFF)
  h = h xor uint32(((ord(team) + 1) * 40503 + CommsSalt * 2246822519'i64) and 0xFFFFFFFF)
  h = h * 2246822519'u32
  h = h xor (h shr 13)
  int(h mod uint32(CommsTokenPool.len))

proc commsToken(rp: ReactPlay, salt: int): char =
  ## play → opaque glyph. The play ordinal is rotated by the round salt into the
  ## glyph pool, so which letter means which play changes every round (C2).
  let idx = (ord(rp) + salt) mod CommsTokenPool.len
  CommsTokenPool[idx]

proc decodeCommsToken(c: char, salt: int): ReactPlay =
  ## glyph → play (the inverse table every same-team bot builds identically).
  let pos = CommsTokenPool.find(c)
  if pos < 0:
    return RpNone
  let ord0 = (pos - salt + CommsTokenPool.len * 4) mod CommsTokenPool.len
  if ord0 > ord(high(ReactPlay)):
    RpNone
  else:
    ReactPlay(ord0)

proc scenarioToPlay(sc: Scenario, flank: Play): ReactPlay =
  ## The shared SEAL contingency matrix: scenario → the play to broadcast/adopt.
  ## FLIP carries the clock flank so a heard flip still names top/bottom.
  case sc
  of ScNone:  (if flank == PushTop: RpFlipTop else: RpFlipBottom)
  of ScStack: RpStack
  of ScWipe:  RpWipe
  of ScPeel:  RpPeel
  of ScLine:  RpLine

proc selectScenarioPlay(bot: Bot, elapsed: int, ownStolen: bool,
                        localSc: Scenario): Play =
  ## The event-driven play layer above selectPlay. Folds THREE inputs through one
  ## shared, deterministic matrix so two bots on the same picture agree and a bot
  ## that heard nothing degrades to its own read + the clock fallback (never a
  ## split, never worse than the clock playbook):
  ##   1. own-flag-stolen (globally legible) → StackDefense, as today, always wins
  ##   2. a live heard play (commsPlay) within CommsPlayTtl, OR our own localSc
  ##   3. the clock flank (selectPlay) as the tiebreak/fallback
  ## Returns a Play; STACK/WIPE/PEEL map onto the existing posture set (they bias
  ## the SAME flank machinery — the executor levers grabGate/regroupPush/huntCarrier
  ## do the actual stack-hold / rally / peel; this only SELECTS + SYNCs them).
  let clock = selectPlay(elapsed, ownStolen)
  if ownStolen:
    return StackDefense
  # our own fresh classification takes priority; else a fresh heard play; else clock.
  var rp = scenarioToPlay(localSc, clock)
  if rp in {RpFlipTop, RpFlipBottom} and bot.tune.commsPlay and
      bot.heardPlay != RpNone and bot.tick - bot.heardPlayTick <= CommsPlayTtl:
    rp = bot.heardPlay          # no local event of our own — adopt the mate's read
    when defined(commsprobe):
      inc csAdopt
  case rp
  of RpFlipTop:    PushTop
  of RpFlipBottom: PushBottom
  of RpPeel:       StackDefense # peel to the recapture race (huntCarrier executes)
  of RpStack, RpWipe, RpLine, RpNone:
    # STACK/WIPE/LINE don't change the flank posture (grabGate/regroupPush/holdLine +
    # the grenade cluster-target execute off their own local triggers); keep the
    # shared flank so the wave still coheres while those executors do the real work.
    clock

proc defaultCombatTune(): CombatTune =
  ## The shipped baseline's combat knobs, verbatim from the module consts.
  ## A Bot constructed without an explicit tune (every shipped seat) gets this,
  ## so its fire/engage decisions are byte-identical to the pre-refactor code.
  CombatTune(
    fireSlackPx: FireSlackPx,
    freshShotTicks: FreshShotTicks,
    leadTicks: LeadTicks,
    combatDeadband: CombatDeadband,
    fireRange: FireRange,
    carrierFireRange: CarrierFireRange,
    rushEngageRange: RushEngageRange,
    escortEngageRange: EscortEngageRange,
    pocketRushRange: PocketRushRange,
    commit: false,            # the pure-baseline control: re-pick nearest each frame.
    commitBonus: CommitBonus,
    stickyCommit: false,      # control: satCap/dangerScore can pull the gun off a committed kill.
    forceBalance: false,      # control: always press, no numbers awareness.
    outnumberMargin: OutnumberMargin,
    unstuckEngaged: false,    # control: shipped disables the jink when engaged.
    aimLock: false,           # control: aim resets to the move lane off-target.
    huntSweep: false,         # control: no active acquisition sweep.
    fireOnRealBody: false,    # control: fire gate uses the full lead phantom.
    threatFacingBonus: false, # control: danger score ignores enemy facing.
    shout: false,             # control: never shout.
    shoutCallout: false,      # control: no enemy callouts.
    shoutSurprise: false,     # control: no "oh shit!".
    shoutDie: false,          # control: no "die".
    reactContact: false,      # control: ignore heard shouts.
    commsBus: false,          # control: never emit scenario codewords.
    commsPlay: false,         # control: ignore heard scenario codewords (clock playbook only).
    commsCrypto: false,       # control: no codeword rotation.
    damageAware: false,       # control: no orient-to-shooter reaction.
    carrierFlee: false,       # control: carrier advances toward a point-blank enemy.
    carrierClearBand: false,  # control: carrier lane may sit in the respawn cone.
    carrierSerpentine: false, # control: carrier runs a straight predictable line home.
    carrierSprint: false,     # control: carrier fights (engage 110px) instead of running.
    carrierScreen: false,     # control: escort screens remembered threats, not the cone.
    carrierGrabDetect: false, # control: self-carry only when heart >16px off pedestal.
    dangerScore: false,       # control: flat facing tiebreak only (threatFacingBonus).
    twoSpeedScan: false,      # control: sentry sweep rakes past the hot bearing.
    boundingOverwatch: false, # control: advance across open ground even on cooldown.
    holdVsGun: false,         # control: a solo gun-down bot strolls away from a live gun.
    woundedBank: false,       # control: a 1-hp bot fights on with its posture unchanged.
    pointOfDomination: false, # control: overwatch posts scored by raw line length.
    tempoPress: false,        # control: always duck on cooldown, never press dead time.
    fireSuperiority: false,   # control: no press-vs-break judgement.
    calloutGate: false,       # control: a heard callout reorients anyone in earshot.
    aimThreat: false,         # control: threat uses the coarse facingRight half-plane.
    cornerPreAim: false,      # control: a blocked target's aim leads its hidden body.
    sentryDisplace: false,    # control: sentries root at one post and only sweep aim.
    topBias: false,           # control: a fogged thief is guessed on the mid lane.
    playbook: false,          # control: fixed role lanes, no shared-clock flank flip.
    escortRun: false,         # control: no midfield interpose; carrier runs home alone.
    huntCarrier: false,       # control: drop the chase when the thief fix goes stale.
    preSlew: false,           # control: no-shot aim holds the NEAREST enemy, not the winnable draw.
    staggerFire: false,       # control: a bot bounds forward on its own gun state, ignoring the mate's.
    regroupPush: false,       # control: a lone over-extended mid feeds the respawn wave, no rally.
    grabTiming: false,        # control: a rusher dives the pedestal unarmed even into a stacked pocket.
    holdLine: false,          # control: an over-extended mid pushes into a standing enemy line alone.
    grabGate: false,          # control: a rusher opens the unarmed dive without a local numbers edge.
    avoidDisarm: false,       # control: pathing walks over v7 sword/shield pickups and self-disarms.
    shieldTank: false,        # control: an escort never grabs a shield to body-block as a tank.
    shieldRush: false,        # control: the rusher never pre-grabs a shield to carry home at 6 HP.
    planLayer: false,         # control: flat scenario→play matrix, no contingency phase machine.
    defendTeeth: false,       # control: PhDefend intercepts the WRONG entity (mateCarryPos).
    forceClockTick: ForceClockTickTuned,  # only consulted when forceTiming is on.
    forceTiming: false,       # control: PhForce stays at 3800 — measured 0 firing frames.
    swordAmbush: false,       # control: a boxed-in bot never grabs a sword for a melee kill.
    medTopOff: false,         # control: a wounded bot never detours to a center med kit.
    medEcon: false,           # control: no static-coord kit routing (fog-visible kits only).
    medSee: false,            # control: medEcon's candidates are the two formula spots only.
    satCap: false,            # control: a free gun dogpiles the nearest enemy, no saturation cap.
    noMask: false,            # control: a mover walks through a mate's live gun-line.
    assaultThrough: false,    # control: a surprise at knife range triggers the retreat/duck jink.
    offCone: false,           # control: an attacker beelines straight down the enemy's gun axis.
    fatalFunnel: false,       # control: an idle sentry two-speed-sweeps, never pre-lays the chokepoint.
    aimRotRead: false,        # control: aim intel comes only from the dead "aim dot" labels (none on v9).
    arcBreach: false,         # control: no bot ever grabs the plasma arc offensively to cone a line.
    gv21Press: false,         # control: fire-superiority break uses the standard outnumberMargin.
    touchCommit: false,       # control: inside GrabCommitRing the grenade/engage/duck/peek branches
                              # still outrank the 12px touch (the 71.8%-vs-94.9% conversion gap).
  )

proc shippedCombatTune(): CombatTune =
  ## The tune the DEPLOYED player runs. Identical to the baseline default plus
  ## target commitment + target-lock + the corner-grind unstick fix (the proven
  ## Picasso gunfighter levers). `defaultCombatTune` stays the untouched control
  ## the harness A/Bs against; this is what runBot actually plays.
  result = defaultCombatTune()
  result.commit = true
  result.aimLock = true
  result.unstuckEngaged = true
  # WAKEUP DEADLOCK FIX (2026-07-16): recognize self-carry the instant we grab
  # the heart standing ON the enemy pedestal, so the carrier routes home instead
  # of camping the robbed pedestal until timeout. Seat-rotated self-play A/B
  # (12g/side, paired seed 100) net +7 seat-adjusted, grab->cap up in BOTH
  # seatings (Red 23.8% vs 13.0% baseline, Blue 26.3% vs 5.9%). Asymmetric fix
  # (converts would-be-draws to wins for the fixed side) so the mirror measures
  # it, unlike the six falsified combat levers.
  result.carrierGrabDetect = true
  # ── SEAL/CQB v4 (2026-07-16): the six doctrine levers, now the PROVEN champion
  # base. Corrected seat-rotated A/B (24g/side, seed 100, candidate = this + core
  # vs control = v3 core alone) = +8 SEAT-ADJUSTED, positive on BOTH seatings
  # (Run A Red +6, Run B Blue +10; true seat bias only ±2). Mechanism = the v4
  # side out-GRABS and out-CAPTURES both seatings (fire-superiority press + tempo
  # + danger-score threat pick win firefights near the objective → more wipes +
  # heart-runs). ⚠️ LAB-vs-v3 only, NOT hosted-field-confirmed (Maxwell: skip the
  # mixed-field step). Each is still individually harness-gated (DANGER/TWOSCAN/
  # BOUND/DOMINATE/TEMPO/FIRESUP) so a regression can be bisected; CONTROL_SHIPPED
  # now means v4, so the NEXT lever (shout gate) A/Bs cleanly on top of this.
  result.dangerScore = true
  result.twoSpeedScan = true
  result.boundingOverwatch = true
  result.pointOfDomination = true
  # ⭐ tempoPress RETIRED (2026-07-29 audit), TEMPO=1 restores it for the A/B. Its stated
  # premise is UNOBSERVABLE on this engine: "their reload is dead time too" needs to know an
  # enemy is mid-cooldown, but firing is SILENT (RULES.md: the muzzle emits no signal), bullets
  # are invisible, and the muzzle bloom is spectator-only. So the branch cannot test what it
  # claims. What it ACTUALLY tests is "wounded OR turned away", where turned-away is the coarse
  # facingRight half-plane — which GV24+ derives from the FUZZED sprite rotation. Result: it
  # abandons cover to cross 150px (~55 ticks at 2.75px/tick) into a gun on a 12-tick cooldown,
  # i.e. ~4 free trigger pulls, and it fires on a full-hp enemy whenever the flip mislabels it.
  result.tempoPress = getEnv("TEMPO").len > 0
  result.fireSuperiority = true
  # ── AIM-DOT THREAT (2026-07-16, task #19). Shipped on Maxwell's EXPLICIT
  # go-ahead ("we can swap champion to revert ... but let's upload") BEFORE the
  # lab A/B finished — the seat-rotated A/B is still running; if it goes negative
  # the revert is: DELETE this line, or swap the league champion back to the v4
  # version. NOT yet proven; this is an early upload by request, not a proven
  # champion. Replaces the coarse facingRight half-plane in the dangerScore block
  # with a precise gun-on-me cone read from the enemy's aim-dot line.
  result.aimThreat = true
  # ── CARRIER FINISH + THIEF PURSUIT (2026-07-16). Two field-reported deadlocks
  # fixed together: (1) carriers were wedging on the border-attached stub columns
  # near the home edge because safestLaneY steered them to the extreme lanes
  # (y≈40 / y≈619) that those stubs sit on — the "stuck on the last wall at the
  # bottom of the map" report, CONFIRMED in the 0.7.8 grab/capture probe (a Blue
  # carrier froze at (942,583) grinding the stub, 80px short of the open capture
  # column, until the other team scored). (2) a defender that SAW the enemy
  # carrying our flag would sidestep AWAY from it (the generic threat-jink) rather
  # than hunt it — "we run away out of fear." Both are asymmetric finish fixes
  # (turn would-be losses into captures / recaptures) so the self-play mirror can
  # measure them.
  result.carrierHomeStretch = true
  result.chaseThief = true
  # ⭐⭐ CARRIER-RUN SURVIVAL (2026-07-24, the grab->cap conversion leak). The audit found
  # the dive fix moved deaths downfield: carriers now die MID-RUN because every mid-run
  # survival lever was left at its OFF control value while only the FINISH fix
  # (carrierHomeStretch) + the LOS-limited KILL escort (planLayer/PhEscort) shipped. Given
  # CarrierSpeedPct=70 (a full-speed chaser always closes) + map-wide hitscan + no back-armor,
  # "run home in a straight line, alone" is a death sentence — grab->cap (~THE win lever) leaks.
  #   carrierFlee  — the carrier keeps NAV-ing home while taking the free on-line trade, instead
  #                  of the else-branch that WALKS INTO a point-blank chaser (the biggest leak).
  #   carrierSerpentine — the slowest, highest-value unit finally WEAVES across watched ground so
  #                  the map-wide hitscan must re-slew each beat (carriers were exempt from weave).
  #   escortRun    — a free escort interposes a body on the chaser->carrier RAY (friendly-fire ON
  #                  → the bullet is EATEN; movement body-block is void but bullet-eat is real).
  #   carrierScreen— screen the pocket-exit respawn cone as the carrier breaks contact.
  # carrierFlee is asymmetric (converts a would-be carrier death into a capture) so the mirror
  # measures it; the escort levers are coordination (mirror-cancels) → validate on the field.
  result.carrierFlee = true
  result.carrierSerpentine = true
  result.escortRun = true
  result.carrierScreen = true
  # v26: the two "⭐⭐ CAPTURE CONVERSION" levers the first carrier flip MISSED — the whole-
  # policy audit (carrier-play 72) found carrierFlee fixes the walk-into-the-nest MOVEMENT but
  # the carrier still (a) EXPENDS fire pinning the respawner (engage stays carrierFireRange 110,
  # not 0) and (b) keeps its y ON the respawner's E-W firing line. carrierSprint drops the combat
  # branch entirely (engage 0 = pure nav home, mirror-A/B-measurable); carrierClearBand routes it
  # vertically out of the pedestal-height respawn band before the home run.
  result.carrierSprint = true
  result.carrierClearBand = true
  # ── CORNER PRE-AIM (2026-07-16). Replay-reported miss ("we shoot the WALL our
  # enemy hides behind, they step out, we miss by aiming at the wall, they kill
  # us — daveey's shots land on the body"). Root cause: the peek/blocked branch
  # pre-laid the turret on the target's predicted body BEHIND the wall, so the gun
  # sat pointed at solid wall and had to traverse to catch the enemy after it
  # emerged — surrendering the first shot. Fix: aim the EMERGENCE CORNER (the
  # nearest cell the enemy can shoot us from), where its body actually appears, so
  # our bullet is already on-bearing as it rounds the cover. Measured by the new
  # per-team hit-rate metric (redHits/redShots) in the eval harness.
  result.cornerPreAim = true
  # ── SENTRY DISPLACE (2026-07-16). Replay/steering complaint: "our guys stay
  # still far too much for navy seal training." The two sentry roles (overwatch,
  # home defender) rooted at one post and only swept the aim — 2 of 8 bots frozen
  # most of the game. SEAL doctrine is shoot-move-communicate: a sentry with no
  # live target displaces to an adjacent covered vantage on a dwell timer, so it
  # is never a static target and re-angles the crossing it commands (coverage is
  # preserved — the shift is lateral along the watch face, not a retreat).
  result.sentryDisplace = true
  # ── COUNTER-DAVEEY TOP BIAS (2026-07-16). Field report: "daveey always goes to
  # the top of the map." A fogged thief was guessed on LaneMid; bias that prior to
  # LaneTop and post the idle home sentry high. Purely a DEFENSIVE prior on the
  # reacquisition guess — no cost when wrong (a high post still rakes mid on its
  # sweep), a gun on the runner's real lane when right. Asymmetric (converts a
  # would-be enemy capture into a recapture race) so the mirror can measure it.
  result.topBias = true
  # ── SEAL PLAYBOOK (2026-07-16). Steering: "our guys stay still far too much for
  # navy seal training" + "run the playbook." Observation-triggered team plays
  # without comms: all 8 teammates share the SAME deterministic clock
  # (elapsed = tick - gameStart) and the SAME flag STATE, so a play selected off
  # those shared signals is consensus WITHOUT splitting the squad. selectPlay
  # oscillates the pushed flank (PushTop / PushBottom) every PlayPeriod ticks and
  # collapses to StackDefense when our own flag is stolen. Mid-lane feint holders
  # (MidTop/MidBottom) stay to hold the center so the flip is a real pincer, not
  # a whole-team drift. Local sightings deliberately do NOT drive the play (they
  # would desync the team); only the shared clock/state do.
  result.playbook = true
  # ── VANITY SHOUTS (2026-07-16, KEPT — Maxwell: "they were finally tuned right").
  # The v5 5% rarity gate (vanityRoll hash coin) throttles "oh shit!"/"die" to
  # ~1-in-20 eligible windows so the board isn't a wall of bubbles. EMIT-ONLY and
  # provably MASK-NEUTRAL (the emit block runs AFTER the button mask is finalized,
  # only staging bot.shoutWant). daveey cloned this (his "copy softmaxwell" policy),
  # which is confirmation it belongs, not a reason to drop it.
  result.shout = true
  result.shoutSurprise = true
  result.shoutDie = true
  # ── v7 SWORD/SHIELD ADAPTATION (2026-07-19, shipped on Maxwell's EXPLICIT
  # go-ahead: "put all of those ideas that were proven in research into the
  # policy … upload and submit if the policy is better"). The hosted league runs
  # GameVersion 7 (sword/shield/med-kit); the champion had been BLIND to the new
  # objects. Three levers, all field-relevant:
  #   avoidDisarm — pure-downside fix: soft-repel from a sword/shield pickup we're
  #     NOT collecting (auto-pickup on 12px touch sets canFire=false = silent
  #     disarm). Mirror-measurable; proven-live (562/158 repel-frames in the A/B).
  #   shieldTank  — a carrier-escort grabs a shield to body-block as a 6-HP wall.
  #   swordAmbush — a boxed-in bot with no ranged shot grabs a sword for a 26px
  #     guaranteed-kill melee swing.
  # Ship rationale: the seat-rotated v7-bed A/B (24g/side, seed 100, candidate =
  # this + all three vs control = full champion) is byte-even on the leaderboard
  # metric — Red 14–10 on BOTH seatings, seat-adjusted delta 0 — so the composite
  # is PROVABLY NON-REGRESSIVE on everything the mirror can score. avoidDisarm's
  # downside removal is below the noise floor at this tune (~1–3 accidental grabs
  # /24g on both arms); shieldTank fires 0× in self-play (tank-seek 0) because its
  # deliberate-grab trigger is STRUCTURALLY field-only — a mate carrying past our
  # endzone shield barely occurs against our own mirror. Its upside is only
  # reachable on the hosted mixed field, which is why gating it off meant never
  # finding out. Guards are conservative (narrow role/state/proximity gates) so it
  # can't misfire into a harmful behavior. Each stays behind its harness knob
  # (AVOIDDISARM/SHIELDTANK) for bisection.
  #
  # v15 ENGINE UPDATE (2026-07-21): the SWORD was REMOVED, replaced by the plasma
  # arc — so swordAmbush is INERT (no "sword" pickup exists) and is DROPPED from
  # the shipped bundle here (code kept, gated OFF, for the record). avoidDisarm is
  # REPOINTED to the plasma arc (the only remaining disarm object; shield now =
  # 6 HP + 3x-slow-fire, no gun loss). The captain-coordinated plasma OFFENSE is
  # built + tested in Track B (the comms xreq image), not this lab bundle.
  result.avoidDisarm = true
  result.shieldTank = true
  # ── v16 SEAL-lens bundle (aimRotRead/medTopOff/satCap/noMask/assaultThrough).
  # RE-GATED + RE-BAKED on GameVersion 15 (2026-07-21 PM). The field moved 9→15
  # (44 commits), VOIDING the v9 composite gate — so these were un-baked and
  # re-gated as knobs vs the true v15 champion (avoidDisarm[plasma]+shieldTank).
  # v15 GATE RESULT (60g/side/block, seat-rotated, seeds 100+300, all 60/60
  # decisive): seat-adjusted vs the same-seat null (s100 RED−12/BLUE+12, s300 0/0)
  # = +22 / −10 / −6 / +6, POOLED +12/240g (SD ~±15 → non-regressive, win-signal
  # inside the noise floor). NO FUNNEL-shaped harm on any block (worst −10 = floor;
  # the falsified fatalFunnel was −22/−18). The real signal is in CONVERSION (the
  # mirror-win-blind metric): grab→cap on the seat-DISADVANTAGED BLUE arm lifted
  # 5.9→15.6% (s100) and 9.5→14.6% (s300) while the strong RED arm held flat; K-D
  # flipped positive on the candidate arm 3 of 4 blocks. Same ship rationale as the
  # v15 precedent: mirror-non-regressive composite whose upside is field-only.
  #   aimRotRead — REPAIR: aim intel rides soldier-rotation sprite ids (v7+); the
  #     proven aimThreat cone / focus-fire rays / preSlew read the sprite-id
  #     channel. Confirmed intact on v15 (PlayerSpriteBase=100, self 5100+rot).
  #   medTopOff — wounded out-of-contact bot tops off at a visible center med kit.
  #   satCap — past kill-sufficiency, a free gun re-assigns to the highest-danger
  #     UNCOVERED enemy instead of dogpiling.
  #   noMask — a mover soft-repels off a mate's live gun-line (mover-side).
  #   assaultThrough — near-ambush: charge and fire down the bearing, never turn.
  # grabTiming stays OFF here (mirror A/B sign-flipped within the null floor);
  # it ships only in the Track B comms xreq image where clear-base builds on it.
  # Each keeps its harness knob (AIMROT/MEDKIT/SATCAP/NOMASK/ASSAULT) for bisection.
  result.aimRotRead = true
  result.medTopOff = true
  # ⭐⭐ medEcon BAKED ON (2026-07-28, Maxwell greenlit "upload and submit"). This is
  # the first lever in this lineage whose PREMISE was measured on the real field
  # rather than guessed in the lab: 20 live league episodes re-simulated with
  # tools/extract_events showed the field consuming 42 med kits to our 11 (3.8x),
  # while 8 of 13 losses were full WIPES and 81% of our kill deficit booked in ticks
  # 1000-3000. medTopOff above already had the right doctrine but a gate that almost
  # never opens mid-game (kit VISIBLE in the fog cone within 150px AND zero contact);
  # medEcon routes to the kits' STATIC engine coords instead, widens the detour to
  # 320, and lets a 1-hp bot break contact with a threat that is not aiming at it.
  # GATES (all four, details in ~/.ctf/knowledge/experiments/successful.md):
  #   funnel  -d:meprobe vs -d:mtprobe: the detour FIRES 284 -> 4261 frames (15x);
  #           the old gate died at kitVisible 871, medEcon has no visibility stage.
  #   heals   117 vs 41 pooled over both candidate arms (2.85x) vs a symmetric
  #           0.89x null — the mechanism metric, and the one the field measured.
  #   A/B     seat-rotated 30g/seating vs this champion: RED +6 wins/+12 K-D,
  #           BLUE +6/+41, seat-adjusted +6.0/+26.5, POSITIVE ON BOTH SEATINGS
  #           (null correctly specified as SHIPBASE=1 CONTROL_SHIPPED=1 = ~0).
  #   gate    MEDECON=1 grabprobe @ the live 5000t cap: 3/3 decisive, 0 draws,
  #           grabs 5 (vs 3), accuracy 59.6% unchanged — no kit-orbiting draw
  #           machine, and it never touches the trigger.
  # The +6 win delta alone sits UNDER the 60g noise floor (sigma ~7.7), so the case
  # rests on the funnel + heal ratio + both-seatings K-D, per the null-calibration
  # rule. Keeps its MEDECON knob for bisection.
  result.medEcon = true
  # ⭐ medSee (plan #16): medEcon's candidate set gains the kits we can SEE. UNPROVEN —
  # stays ENV-ARMED ONLY until the pre-registered A/B passes (the contaminated-control
  # trap, failed.md: never bake an unproven lever into the champion tune). MEDSEE=1 arms
  # it per-process for the env-server A/B rig.
  result.medSee = getEnv("MEDSEE").len > 0
  # ⭐ satCap RETIRED (2026-07-29 audit), SATCAP=1 restores it. Past "enough guns are already
  # on this target" it re-assigns a free gun to the highest-danger UNCOVERED enemy — but the
  # saturation read is GEOMETRIC (is a mate's aim ray near the target), and that ray is now
  # fuzzed: at the old 700px trust radius the displacement was ~236px against a 22px slack, so
  # "covered" was noise. Worse, it fires against the win condition: it abandons a WOUNDED
  # target (forfeiting the hp-focus and focus-fire credit, a ~415px priority swing) at the one
  # moment finishing is cheapest, and on this engine a fled 1-hp enemy respawns at FULL 3/3
  # after 72 ticks. Spreading damage across enemies who then reset is exactly the measured
  # tick-1000..3000 deficit. MateAimRayLen is now honest (90px), which also shrinks satCap's
  # input to almost nothing — retiring it is the same decision stated once.
  # satCap: the audit's case against it is strong on paper (it abandons a WOUNDED target — a
  # ~415px priority swing — at the moment finishing is cheapest, and a fled 1-hp enemy respawns
  # at full 3/3 in 72 ticks), but I did NOT get a clean isolated measurement of it, and the one
  # bundle it rode in was a null. Shipping it OFF would be shipping an UNMEASURED change.
  # Stays ON (= v28 behaviour) so v30 is a genuine single-variable delta; NOSATCAP=1 turns it
  # off for the isolation run that has to happen before it can ship either way.
  result.satCap = getEnv("NOSATCAP").len == 0
  result.noMask = true
  result.assaultThrough = true
  # ⭐ fireOnRealBody MEASURED AND REJECTED (2026-07-29). The audit ranked it a top fix — the
  # aim leads 6 ticks on a HITSCAN gun whose bearing locks at the pull, so in theory the lead
  # phantom falls outside the 11px slack while the real body is dead on our line, and this
  # opens the trigger on a shot that would land. The reasoning was sound and the measurement
  # refuted it: 24g seed 100 paired off ONE binary, enabling it took 460 MORE shots
  # (5334 -> 5794, +8.6%) for ELEVEN FEWER hits — the marginal accuracy of the extra shots is
  # ~0.0, and accuracy fell 62.6% -> 57.4%. Each wasted shot also books a 12-tick cooldown, so
  # this is worse than neutral. The real-body gate re-checks the corridor but NOT the 5-tick
  # windup: by the time the bullet leaves, the juking body it was aimed at has moved on.
  # REALBODY=1 re-enables it for anyone who wants to re-measure; it ships OFF.
  result.fireOnRealBody = getEnv("REALBODY").len > 0
  # counterArc (Play C, GameVersion 15 plasma arc): prioritize a DISARMED enemy
  # arc-carrier (gun off for life while holding) beyond its 136px cone — a free
  # kill that deletes the enemy's whole AoE play. Ships on the SAME field-only
  # precedent as shieldTank/avoidDisarm: caprobe shows detection LIVE (arcAttrib
  # 316/8g) but the retarget is STRUCTURALLY mirror-inert (bump 0 — arc-carriers
  # only reach engage range after closing inside 136px in self-play), so the
  # non-regression A/B came out BYTE-IDENTICAL candidate-vs-control (provably 0
  # cost). The upside is hosted-only (opponents that grab the arc + advance it into
  # the open). Retarget-only (no movement branch — that's the future arcStandoff);
  # 240 credit sits below CommitBonus(400) so it never drops a locked kill. Keeps
  # its COUNTERARC harness knob for bisection.
  result.counterArc = true
  # ── ANTI-h006 POSITIONING SET + COMMS BUS (2026-07-22, Track B, shipped on
  # Maxwell's explicit go-ahead: "ship them with the policy, we know they work if
  # you code it right … improve the policy to beat Alex Smith"). The new #1
  # ctf-h006:v1 ("Alex Smith", 0.875) beats us by POSITIONING, not aim (accuracy
  # ~50% for everyone): it forms a LINE in its own half and farms our over-extend —
  # we die 39% of the time in the ENEMY half vs its ~14%, and 72–82% of our carriers
  # die AT the enemy pedestal (grabbed even/behind = the suicide-grab). Its whole
  # doctrine is "win the attrition on your OWN ground, refuse to over-commit, grab
  # only when up bodies." These five levers are the direct counter, ALL previously
  # gated OFF, ALL movement-intent only (never touch the turret / carry / defense
  # states), each still behind its harness knob for bisection:
  #   holdLine   — over-extended into a fresh enemy LINE while locally outgunned →
  #                rally the mid wave shallow and hit the line together, don't
  #                trickle in to be farmed. (TURTLE probe FIRED 71; mirror ~flat.)
  #   grabGate   — RELATIVE numbers gate on the unarmed pedestal dive: open when
  #                (me + inbound support) can beat the defense, hold at the standoff
  #                ring when genuinely outgunned = the h006 "grab only +bodies"
  #                discipline. (TURTLE FIRED 61; mirror no-regression CONFIRMED — the
  #                seat-100 "loss" is 100% Blue-seat bias, byte-identical to the null.)
  #   grabTiming — anti-stacked-dive sibling (ABSOLUTE stack ≥2 + mate inbound): a
  #                solo unarmed dive into a stacked pocket is shot on the touch (96%
  #                of carrier deaths, 0% cap in losses). Delays/sequences, never abandons.
  #   regroupPush— post-wipe consolidation (the v14 squander fix): a lone mid over-
  #                extended into a cleared vacuum with support inbound holds a shallow
  #                rally until the trio re-forms, then pushes deep TOGETHER instead of
  #                feeding the ~72t respawn wave one body at a time.
  # These are ASYMMETRIC-OPPONENT levers — their triggers (a standing line, a stacked
  # pocket, a squander vacuum) cannot form in the symmetric mirror, so a self-play A/B
  # proves NO-REGRESSION only; the real edge is the hosted field vs h006 (field-only
  # ship precedent, same class as counterArc/shieldTank). Verified: shipped champion
  # builds clean + grabprobe not-blind on GV17 (19 grabs / 3 caps / 58% acc, seed 100).
  result.holdLine = true
  result.regroupPush = true
  # ⭐⭐ SMART GRAB (2026-07-24, THE dive-death fix) REPLACES grabGate+grabTiming. Those were
  # hard-threshold gates with a lone-body-dives-NOW carve-out that IS the pointless suicide
  # dive (>half our deaths, 0 damage). smartGrab is the adaptive Captain-brain commit: hold at
  # a firing standoff + suppress the pocket from range UNLESS we have a real advantage (pickEdge
  # local numbers edge / PhForce grouped all-in / a mate covering in place); armedRush keeps the
  # gun UP on any defended touch so we never disarm into fire; holdVsGun stops a solo gun-down
  # bot presenting its back to a live gun; stickyCommit keeps the gun finishing a committed kill.
  # grabGate/grabTiming left OFF (code kept for the record + their harness knobs).
  result.smartGrab = true
  result.armedRush = true
  result.holdVsGun = true
  result.stickyCommit = true
  # ⭐⭐ THE TOUCH LATCH (2026-07-29) — the COMPANION to smartGrab, not a rollback of it.
  # smartGrab fixed the APPROACH (no lone suicide dive into a stacked pocket) and it works.
  # It left the LAST 60px unfixed: GrabCommitRing marked "we are committed" but set no flag,
  # so four LIVE branches still beat the 12px touch once a bot was already there. Field
  # ground truth, 123 GV26 episodes: we reach <40px of the enemy heart as often as the field
  # (71 vs 79 eps) but convert to a steal 71.8% vs THEIR 94.9%; 20 episodes had a bot sitting
  # 5-39px from it, never taking it. Since a steal swings the episode from 26.4% to 66.7%,
  # that unconverted approach is the single largest recoverable loss in the policy.
  # TOUCHOFF=1 turns the latch back off so the eval rig can A/B candidate vs control from ONE
  # binary — a separate control build is a second variable, and the null-calibration lesson is
  # that a 60-game win delta is already at the noise floor without adding one.
  # ⭐ THE TOUCH LATCH ships GATED OFF in v30, on purpose. The FIELD premise is the strongest
  # in the lineage (123 GV26 episodes: we reach <40px of the enemy heart as often as the field,
  # 71 vs 79 eps, but convert to a steal 71.8% vs THEIR 94.9%; 20 episodes had a bot 5-39px
  # from a 12px pickup radius; 445-vs-90 deaths in the 60-260px standoff ring), and the latch
  # verifiably ARMS (310-514 frames/24g) and removes the preemptions it targets (engage 4 -> 0
  # once armedRush got its range floor). But a MIRROR cannot score it: the change is symmetric,
  # so both sides get the same latch and the marginal advantage cancels — measured as a null
  # that flips sign across seatings. Same category as medEcon/shieldTank/avoidDisarm, whose
  # upside was field-only. TOUCH=1 arms it for the hosted ASYMMETRIC A/B that is the correct
  # gate. Do not flip this default without that field result.
  result.touchCommit = getEnv("TOUCH").len > 0
  # ⭐ woundedBank (plan #13): the hp-keyed wounded survival posture. UNPROVEN —
  # stays ENV-ARMED ONLY until the pre-registered A/B passes (the contaminated-
  # control trap, failed.md: never bake an unproven lever into the champion
  # tune). WBANK=1 arms it per-process for the env-server A/B rig.
  result.woundedBank = getEnv("WBANK").len > 0
  # ── COMMS BUS (C1/C2 + the WIPE coupling). Event-driven team plays over the one
  # shout channel: a bot classifies a LIVE scenario from its own fresh local reads
  # and broadcasts an opaque rotating 2-char codeword; teammates in earshot adopt it
  # as MOVEMENT INTENT only (never a turret bearing — the REF-comms v1/v2 lesson) and
  # fold it with their own read through one shared matrix, so the squad converges
  # WITHOUT a captain and degrades to the clock playbook if it hears nothing. Emit is
  # mask-neutral (rides shoutWant AFTER the button mask is finalized, like the vanity
  # shouts). The ⭐ payload coupling: a HEARD wipe arms a trailing mid's regroupPush
  # rally even when that mid never saw the vacuum — the ONE thing the shared clock /
  # legible flag state cannot sync across fog (flip is already clock-consensus, peel
  # is already empty-pedestal-legible), so without it the bus would be inert transport.
  # commsCrypto rotates the token→play table per round off a compiled-in salt so a
  # clone that hand-copied a static map can't read our codewords. Mirror-INVISIBLE by
  # construction (both teams get the bus symmetrically → it cancels), so per Maxwell
  # we ship it coded-correct rather than lab-testing it; the edge only exists on the
  # asymmetric hosted field. commsPlay turns playbook on (it extends that machinery).
  result.commsBus = true
  result.commsPlay = true
  result.commsCrypto = true
  result.playbook = true  # commsPlay adopts flank plays through the playbook matrix
  # ── ⭐⭐ CONTINGENCY STATE MACHINE (planLayer, v20 candidate, 2026-07-23). The
  # architectural fix for "chess not checkers": teamPhase drives a shared-state plan
  # (OPEN→PROBE→PRESS→ESCORT→DEFEND→FORCE) so the team flows branch→branch unanimously
  # instead of the flat reactive matrix that bleeds lives when countered. Directly
  # attacks the measured deficit — we lose the opening clash 14-6 (PhOpen groups it),
  # trickle carriers to their death (PhEscort full-collapses), and stall into the −1
  # timeout (PhForce commits before the clock). Movement-intent only; pure fn of shared
  # signals (the backstop-the-caller design — no unit must survive to hold the plan).
  result.planLayer = true
  # ── ⭐ ARC BREACHER (anti-line offense) + enemy-shield awareness. The plasma arc
  # is a MULTIKILL cone and a line is a cluster: when a line is called, the fixed
  # breacher seat (MidGuard) grabs the arc and cones the seam while the wave is base-
  # of-fire. Trades that one bot's gun for its life (a deliberate specialist swap),
  # gated to the breacher seat + a live line only, so it can't misfire team-wide.
  # Enemy-shield awareness ships unconditionally in the reader (Actor/Track.hasShield
  # from the "shield carried" marker) — the fire model now knows a shielded enemy is
  # a 6-HP tank (the pip bar lies 3/3), needs more guns (satNeed), and weighs more in
  # the break math (ShieldGunWeight); no flag, it's a straight correctness repair.
  #
  # ⚠️ arcBreach: OFF in the default shipped tune, but the pre-A/B audit's 3 kill-shots were
  # all against the REACTIVE LONE-WOLF breacher — and the 2026-07-24 reframe turned each into
  # a Captain-coordinated design that the arcprobe funnel confirms fixes it:
  #   1. GEOMETRY (was ~485t reactive round trip): PROACTIVE ARM while shallow (ArcArmMaxDepth)
  #      off a Captain PhProbe/PhPress read — the own-corner arc is a cheap one-leg grab, then
  #      the armed cone is carried forward. A deep breacher never starts the retreat.
  #   2. DISARM (was gunless 82% of the time): OPPONENT-ADAPTIVE (sawLineTick/ArcLineMemoryTicks)
  #      — pre-arm only if a real line was seen this game, so the breacher WAKES vs a line-player
  #      and stays a DORMANT full gun vs an aggressive no-line field; min-cluster gate never cones
  #      a singleton; when dry it holds the seam as a threat, never feeds the gunless body in.
  #   3. DOCTRINE/REDUNDANCY: LINE-LOCATION relay converges it on the real cluster (mean cone
  #      2.98 / fattest 5 vs a line); it's COMBINED ARMS with the grenade (one-shot lob over
  #      walls) not a duplicate — the arc is the SUSTAINED repeatable follow-up cone.
  # -d:arcOn bakes it ON for the hosted-A/B CANDIDATE image (base image = this flag off = the
  # v21 champion on GV22). The mirror can't score the win-credit; the A/B decides bake-vs-gate.
  when defined(arcOn):
    result.arcBreach = true
  # ── gv21Press (v18) — FALSIFIED 2026-07-23. Hosted A/B vs h006: v18 24-55, WORSE than
  # v17's 30-50. Pressing harder just extended the grind (endTick 2600→3400) and fed
  # deaths without raising our kills — the problem is not caution, it's that we LOSE the
  # duels and (the real lever) never CONVERT steals to captures (34 steals / 4 caps =
  # 12% vs h006). Reverted; kept behind the GV21PRESS knob only. See JOURNAL 07-23 PM3/PM4.
  # result.gv21Press = true
  # ── ⭐⭐ SHIELD-RUSH (v19 candidate, 2026-07-23) — attacks the REAL deficit: grab→cap
  # conversion (34 steals / 4 caps = 12% vs h006; carriers die at midfield on the run
  # home). The rusher pre-grabs OUR OWN endzone shield (home-side, cheap detour) and
  # carries the heart home at 6 HP — survives 6 hits vs 3. Co-carry + capture-while-
  # shielded both confirmed legal on GV21; first-mover mechanic (h006 doesn't use it).
  # Mirror-MEASURABLE (per-team HP → grab→cap), so lab-screened before the hosted A/B.
  result.shieldRush = true
  result.sprayGrab = true
  # GV36 aim-mechanics levers (2026-08-05, from Maxwell's replay observations:
  # wrong-direction grenades + field-wide turret spin). A/B 12g seat-rotated,
  # per-process env rig: kills +64%, deaths -40%, positive both seatings;
  # gated-off path byte-identical to v38; nade release err >6 brads 4% -> 0%.
  result.nadeLob = true
  result.spinCap = true
  # ⭐ spinCap RANGE FORK (issue #8 residual, 2026-08-05). Measured on the shipped
  # trees: the 4-tick budget parks the turret at a ≤2-slot residual, and because
  # perpMiss = D·sin(err) the 17px corridor then only opens inside ~87px — v39's
  # shot-release range collapsed (median 247→113px, share beyond 300px 42%→19%)
  # while the CQB arena A/B that proved the lever could not sample that axis. Two
  # per-process knobs so ONE frozen binary can serve every arm of the giant-terrain
  # A/B (the ab_aimfix.sh pattern — no in-process tune contamination):
  #   NOSPINCAP=1   → drop the budget entirely (the v38 exact-plan servo).
  #   SPINRANGE=<px>→ the LOGIC FORK: budget inside <px>, exact plan beyond it.
  # Default stays Inf (plain v39) until the A/B pays for a change. [[REF-slack]]
  # forbids tuning the fire-gate KNOB; this is the range-conditioned logic fork it
  # prescribes instead, and it touches the TRAVERSE, not the trigger.
  result.spinCapRangePx = Inf
  if getEnv("NOSPINCAP").len > 0:
    result.spinCap = false
  let spinRange = getEnv("SPINRANGE")
  if spinRange.len > 0:
    result.spinCapRangePx = parseFloat(spinRange)


when defined(rngprobe):
  # ── RANGED-CORRIDOR PROBE (pure instrumentation, identical in every tree).
  # Bands: 0=<150px 1=150-300 2=300-600 3=600-1000 4=>=1000
  var
    rpFrames*: array[2, array[5, int]]
    rpOpen*: array[2, array[5, int]]
    rpFire*: array[2, array[5, int]]
    rpErrSum*: array[2, array[5, int]]
    rpDistSum*: array[2, array[5, float]]
    rpBand* = -1
    rpSide* = 0
    rpNextDump* = 0
    rpCalls* = 0
    rpCap*: array[2, int]
    rpCapErr*: array[2, int]
  proc rpBandOf*(d: float): int =
    if d < 150.0: 0
    elif d < 300.0: 1
    elif d < 600.0: 2
    elif d < 1000.0: 3
    else: 4

proc vec(x, y: float): Vec =
  Vec(x: x, y: y)

proc `+`(a, b: Vec): Vec = vec(a.x + b.x, a.y + b.y)
proc `-`(a, b: Vec): Vec = vec(a.x - b.x, a.y - b.y)
proc `*`(a: Vec, s: float): Vec = vec(a.x * s, a.y * s)

proc len(a: Vec): float =
  hypot(a.x, a.y)

proc dist(a, b: Vec): float =
  len(a - b)

proc norm(a: Vec): Vec =
  let l = a.len()
  if l < 1e-6: vec(0, 0) else: a * (1.0 / l)

proc dot(a, b: Vec): float =
  a.x * b.x + a.y * b.y

proc cross(a, b: Vec): float =
  a.x * b.y - a.y * b.x

proc octantBits(d: Vec): uint8 =
  ## D-pad bits for the 8-way direction nearest to `d`. The worst-case aim
  ## error is 22.5 degrees, safely inside the 25-degree firing cone.
  if d.len() < 1e-6:
    return 0
  let octant = (int(round(arctan2(d.y, d.x) / (PI / 4))) + 8) mod 8
  case octant
  of 0: ButtonRight
  of 1: ButtonRight or ButtonDown
  of 2: ButtonDown
  of 3: ButtonDown or ButtonLeft
  of 4: ButtonLeft
  of 5: ButtonLeft or ButtonUp
  of 6: ButtonUp
  else: ButtonUp or ButtonRight

proc bradsOf(d: Vec): int =
  ## The aim angle in brads pointing along `d`: 0 = east (+x), increasing
  ## counter-clockwise on screen (64 = north; map y grows downward).
  if d.len() < 1e-6:
    return 0
  (int(round(arctan2(-d.y, d.x) * float(AimBrads div 2) / PI)) +
    AimBrads) mod AimBrads

proc bradsDir(brads: int): Vec =
  ## The unit vector of one aim angle in brads (the true fire axis).
  let angle = float(brads) * PI / float(AimBrads div 2)
  vec(cos(angle), -sin(angle))

proc bradsErr(desired, current: int): int =
  ## The signed shortest arc from `current` to `desired` in -128..127:
  ## positive means rotate counter-clockwise (hold B).
  (desired - current + AimBrads + AimBrads div 2) mod AimBrads -
    AimBrads div 2

proc spawnAim(team: Team): int =
  ## The spawn/respawn aim angle: toward the enemy side.
  if team == Red: 0 else: AimBrads div 2

proc chessCell(p: Vec): string =
  ## Encodes a map point as a chess-style cell "F9": file A..Z across the
  ## width (~47px each), rank 1..14 down the height. A short, replay-legible
  ## address that pins an enemy to a ~47px neighborhood — plenty to turn a
  ## teammate's turret onto it (its own vision/tracking reacquire from there).
  let
    fw = float(MapW) / float(ChessFiles)
    rh = float(MapH) / float(ChessRanks)
    f = clamp(int(p.x / fw), 0, ChessFiles - 1)
    r = clamp(int(p.y / rh), 0, ChessRanks - 1)
  $chr(ord('A') + f) & $(r + 1)

proc chessDecode(cell: string): Vec =
  ## Inverse of chessCell: the CENTER of the named cell, or (-1,-1) if the
  ## address is malformed (an out-of-range file letter or non-numeric rank).
  if cell.len < 2 or cell[0] notin {'A' .. 'Z'}:
    return vec(-1, -1)
  var rank: int
  try:
    rank = parseInt(cell[1 .. ^1])
  except ValueError:
    return vec(-1, -1)
  let f = ord(cell[0]) - ord('A')
  if f >= ChessFiles or rank < 1 or rank > ChessRanks:
    return vec(-1, -1)
  let
    fw = float(MapW) / float(ChessFiles)
    rh = float(MapH) / float(ChessRanks)
  vec((float(f) + 0.5) * fw, (float(rank - 1) + 0.5) * rh)

proc slotFromUrl(url: string): int =
  ## Reads the `slot` query parameter from the websocket URL.
  let key = "slot="
  let at = url.find(key)
  if at < 0:
    return 0
  var i = at + key.len
  var digits = ""
  while i < url.len and url[i] in {'0' .. '9'}:
    digits.add(url[i])
    inc i
  if digits.len == 0: 0 else: digits.parseInt()

proc mapPos(client: ProtocolClient, o: SpriteObjectInfo): Vec =
  ## Map-space center of a sprite object (the map object sits at the origin,
  ## so the camera offset is zero; keep it for exactness). The wire carries
  ## RenderScale-scaled coordinates with sprites centered on scaled map
  ## points, so the division is exact for every entity the bot reads.
  vec(
    float((o.x + o.width div 2) div RenderScale + client.mapCameraX),
    float((o.y + o.height div 2) div RenderScale + client.mapCameraY)
  )

proc activeColors(): int =
  ## How many team colors are actually in play this episode.
  max(GameTeams, 2)

proc enemyColorFor(myColor: string): string =
  ## The color of our RAID TARGET — the heart we try to steal.
  ##
  ## On a 2-team board this is simply the other side, exactly as before. On a
  ## 4-team board there are THREE enemy hearts and picking one matters: we take
  ## the rival whose stated endzone sits furthest from ours along x, because the
  ## whole mirrored-arena advance is written east-west and a north/south target
  ## degenerates it. Falls back to the next color round the deal if the endzone
  ## markers are missing.
  if activeColors() <= 2:
    return (if myColor == "red": "blue" else: "red")
  var
    home = vec(float(CenterX), float(CenterY))
    haveHome = false
  for z in EndzoneMarks:
    if z.color == myColor:
      home = vec(float(z.x0 + z.x1) * 0.5, float(z.y0 + z.y1) * 0.5)
      haveHome = true
      break
  if haveHome:
    # ⭐ RAID THE NEAREST RIVAL, not the furthest.
    #
    # This used to take the endzone with the largest HORIZONTAL offset, so the
    # old east-west advance math could not degenerate on a north/south
    # neighbour. That reason is gone — the geometry now comes from the stated
    # zones and the observed pedestals — and on a giant board it was actively
    # awful: it sent the bottom-left team diagonally across 2245px of a
    # 2496x2496 map, past its own neighbour, through three other teams, to
    # reach the furthest heart on the board. Measured: nobody ever arrived.
    #
    # Nearest is strictly better here. The trip is shorter, the exposure is
    # shorter, and a capture is worth the same whoever it lands on — GV32 makes
    # any capture ELIMINATE that team, so there is no bonus for picking a
    # particular rival, only a cost for walking further to reach one.
    # Two passes: prefer a rival whose heart is actually THERE to take. Falling
    # back to plain nearest keeps this inert before the first frame of banner
    # data, and on any map where the scan comes up empty.
    for requireHeart in [true, false]:
      var
        best = ""
        bestD = 1e18
      for z in EndzoneMarks:
        if z.color == myColor:
          continue
        let ci = TeamColorNames.find(z.color)
        if requireHeart and (ci < 0 or not HeartHome[ci]):
          continue
        let d = dist(vec(float(z.x0 + z.x1) * 0.5, float(z.y0 + z.y1) * 0.5), home)
        if d < bestD:
          bestD = d
          best = z.color
      if best.len > 0:
        return best
  let mine = TeamColorNames.find(myColor)
  TeamColorNames[(max(mine, 0) + activeColors() div 2) mod activeColors()]

proc ownAimBrads(client: ProtocolClient): int =
  ## The engine-stated own-aim angle from the `own aim <brads>` HUD marker,
  ## or -1 when the marker is absent (pre-marker engines) or unparsable.
  for o in client.spriteObjects():
    if o.label.startsWith(LabelPrefixOwnAim):
      let tail = o.label[LabelPrefixOwnAim.len .. ^1]
      try:
        return parseInt(tail)
      except ValueError:
        return -1
  -1

proc findSelf(
    client: ProtocolClient, color: string): tuple[alive: bool, pos: Vec] =
  ## Our avatar via the distinct self marker, only drawn while we are alive.
  for facingRight in [true, false]:
    let label = "self " & color & (if facingRight: " right" else: " left")
    for o in client.spriteObjectsWithLabel(label):
      return (alive: true, pos: client.mapPos(o))

proc plantedPedestalPos(client: ProtocolClient, o: SpriteObjectInfo): Vec =
  ## The TRUE pedestal point under a planted-banner sprite. The big home banner
  ## is BOTTOM-ANCHORED (global.nim: object top = flag.y - (PlantedFlagH - 2)),
  ## so the sprite CENTER that mapPos returns floats PlantedFlagH/2 - 2 = 28px
  ## NORTH of the heart. Caching that as the pedestal put a grab-committed bot
  ## 28px off a ~26px pickup — hovering forever just outside the touch (the
  ## grabs 6 -> 2 gate regression). Anchor on the bottom edge instead.
  vec(
    float((o.x + o.width div 2) div RenderScale + client.mapCameraX),
    float((o.y + o.height) div RenderScale + client.mapCameraY - 2)
  )

proc rotFromSpriteId(spriteId: int): int =
  ## aimRotRead: the aim rotation step baked into a v9 soldier sprite id, or
  ## -1 when the id is outside the soldier rotation pools. Live soldiers use
  ## RotPlayerSpriteBase + ord(team)*RotSteps + rot (the team offset mods out);
  ## the viewer's own outlined self uses RotSelfSpriteBase + rot.
  if spriteId >= RotPlayerSpriteBase and
      spriteId < RotPlayerSpriteBase + 2 * RotSteps:
    return (spriteId - RotPlayerSpriteBase) mod RotSteps
  if spriteId >= RotSelfSpriteBase and spriteId < RotSelfSpriteBase + RotSteps:
    return spriteId - RotSelfSpriteBase
  -1

proc rotBrads(rot: int): int =
  ## Center bearing (brads) of one soldier rotation step. The engine quantizes
  ## soldierRotIndex to the NEAREST step, so the true aim is within ±RotBrads
  ## PerStep/2 (±8) of this — coarser than the retired dots (~±2) but alive.
  rot * RotBradsPerStep

proc selfRotAim(client: ProtocolClient, color: string): int =
  ## aimRotRead: our own aim from the self soldier sprite's rotation id
  ## (RotSelfSpriteBase + rot). The outlined self marker is only ever drawn
  ## for the viewer, so there is no attribution ambiguity. -1 when dead.
  result = -1
  for facingRight in [true, false]:
    let label = "self " & color & (if facingRight: " right" else: " left")
    for o in client.spriteObjectsWithLabel(label):
      let rot = rotFromSpriteId(o.spriteId)
      if rot >= 0:
        return rotBrads(rot)

proc observedAim(client: ProtocolClient, me: Vec, color: string): int =
  ## Our actual aim read back from our own rendered aim-indicator dots: the
  ## farthest "aim dot <color>" object within the indicator radius points
  ## along the aim. Returns -1 when no dot is close enough (teammate dots
  ## share our color but hug their own player). Resolution is ~2 brads —
  ## an absolute fix that caps dead-reckoning drift.
  result = -1
  var bestD = 0.0
  for o in client.spriteObjectsWithLabel("aim dot " & color):
    let
      p = client.mapPos(o)
      d = dist(p, me)
    if d <= AimDotRadius and d > bestD:
      bestD = d
      result = bradsOf(p - me)

proc actorsFor(client: ProtocolClient, color: string,
    rotRead = false): seq[Actor] =
  ## Visible players of one color in map coordinates plus horizontal facing
  ## and hit points. The overhead "hp <n>/<max>" pip bar is fog-culled with
  ## its player, so whenever the player is visible its hp is too: attach the
  ## nearest pip bar within HpPipRadius. With rotRead (aimRotRead), the gun
  ## bearing comes from the soldier sprite's rotation id — per-object, so no
  ## attribution step and no close-pair ambiguity, unlike the retired dots.
  for facingRight in [true, false]:
    let label = "player " & color & (if facingRight: " right" else: " left")
    for o in client.spriteObjectsWithLabel(label):
      var ab = -1
      if rotRead:
        let rot = rotFromSpriteId(o.spriteId)
        if rot >= 0:
          ab = rotBrads(rot)
      result.add(Actor(pos: client.mapPos(o), facingRight: facingRight,
        aimBrads: ab))
  for hp in 1 .. MaxHp:
    for o in client.spriteObjectsWithLabel("hp " & $hp & "/" & $MaxHp):
      let p = client.mapPos(o)
      var best = -1
      var bestD = HpPipRadius
      for i in 0 ..< result.len:
        let d = dist(result[i].pos, p)
        if d < bestD:
          bestD = d
          best = i
      if best >= 0:
        result[best].hp = hp
  # Plasma-arc possession: a carrier renders a "plasma arc carried" marker ABOVE
  # its head (higher than the hp pip). The label carries NO color, so — like the
  # hp pip — attribute it to the nearest actor of THIS color (this proc is called
  # per color; our own marker hugs us, an enemy's hugs the enemy). A carrier's
  # 1300px gun is disabled for life, so this flags a disarmed high-value target.
  for o in client.spriteObjectsWithLabel(LabelSprayCanCarried):
    let p = client.mapPos(o)
    var best = -1
    var bestD = ArcCarryRadius
    for i in 0 ..< result.len:
      let d = dist(result[i].pos, p)
      if d < bestD:
        bestD = d
        best = i
    if best >= 0:
      result[best].hasArc = true
      when defined(caprobe): inc caArcAttrib
  # Shield possession: a carrier renders a "shield carried" marker over its head
  # (same attribution as the arc — the label carries no color, this proc runs per
  # color so the nearest same-color actor owns it). A shielded player has 6 HP (vs
  # the 3-hp cog the pip bar always shows) and fires 3x slower — a tank we must put
  # more guns on but whose slow fire is a free-shot window.
  for o in client.spriteObjectsWithLabel(LabelShieldCarried):
    let p = client.mapPos(o)
    var best = -1
    var bestD = ArcCarryRadius
    for i in 0 ..< result.len:
      let d = dist(result[i].pos, p)
      if d < bestD:
        bestD = d
        best = i
    if best >= 0:
      result[best].hasShield = true
  # Aim bearing: each living player renders a short "aim dot <color>" line from
  # its center along its gun angle. Attribute each dot to the nearest actor and
  # keep the FARTHEST attributed dot per actor — its bearing from the actor is
  # the gun direction (same absolute readback observedAim/mateAimBrads use). Two
  # actors closer than 2*AimDotRadius can't be told apart, so leave both at -1.
  var farDot = newSeq[float](result.len)          # 0 = no dot yet
  for o in client.spriteObjectsWithLabel("aim dot " & color):
    let p = client.mapPos(o)
    var best = -1
    var bestD = AimDotRadius
    for i in 0 ..< result.len:
      let d = dist(result[i].pos, p)
      if d < bestD:
        bestD = d
        best = i
    if best >= 0 and bestD > farDot[best]:
      farDot[best] = bestD
      result[best].aimBrads = bradsOf(p - result[best].pos)
  # Ambiguity guard: if two actors sit within 2*AimDotRadius their dot lines
  # overlap and attribution is unreliable — drop both to unknown.
  for i in 0 ..< result.len:
    for j in i + 1 ..< result.len:
      if dist(result[i].pos, result[j].pos) <= 2.0 * AimDotRadius:
        result[i].aimBrads = -1
        result[j].aimBrads = -1

proc actorsForEnemies(client: ProtocolClient, myColor: string,
    rotRead = false): seq[Actor] =
  ## Every visible player who is NOT on our team.
  ##
  ## The 2-team policy scanned exactly ONE enemy color, which on a free-for-all
  ## board leaves two of the three rival teams invisible to the entire combat
  ## layer — never tracked, never shot at, never ducked. In a FFA everyone who
  ## is not us is hostile, so the scan is the union over the active colors. On
  ## a 2-team board this is exactly the old behavior.
  for c in TeamColorNames.toOpenArray(0, activeColors() - 1):
    if c == myColor:
      continue
    result.add client.actorsFor(c, rotRead)

proc selfHp(client: ProtocolClient, me: Vec, color: string): tuple[have: bool, hp: int] =
  ## Our own current hit points, read from the overhead pip bar the engine
  ## always sends the viewer for itself. The bar sits within HpPipRadius of our
  ## avatar; a mate's bar shares the label but hugs its own player, so match the
  ## nearest bar to us. A drop between frames is proof we were just hit.
  result = (have: false, hp: 0)
  var bestD = HpPipRadius
  for hp in 1 .. MaxHp:
    for o in client.spriteObjectsWithLabel("hp " & $hp & "/" & $MaxHp):
      let d = dist(client.mapPos(o), me)
      if d < bestD:
        bestD = d
        result = (have: true, hp: hp)

proc mateAimBrads(client: ProtocolClient, mate, me: Vec, color: string): int =
  ## A visible mate's aim angle read from ITS rendered aim-indicator dots
  ## (the same absolute readback observedAim does for our own turret).
  ## Returns -1 when the mate is too close to us to attribute dots safely.
  if dist(mate, me) <= 2.0 * AimDotRadius:
    return -1
  result = -1
  var bestD = 0.0
  for o in client.spriteObjectsWithLabel("aim dot " & color):
    let
      p = client.mapPos(o)
      d = dist(p, mate)
    if d <= AimDotRadius and d > bestD and dist(p, me) > AimDotRadius:
      bestD = d
      result = bradsOf(p - mate)

proc mateGunDown(client: ProtocolClient, mate: Vec): bool =
  ## staggerFire (v8): true when a "muzzle bloom" flash sits on this mate's
  ## body — the server draws the bloom at the shooter's origin for exactly
  ## ShotFxTicks (12) ticks, which equals FireCooldownTicks (12), so a bloom on
  ## a mate means its gun FIRED within the reload window and is DOWN right now.
  ## Fog-gated with the mate (the bloom is fov-culled), so we only read it for a
  ## mate we can actually see. The bloom is colorless and small (7px), so match
  ## it to THIS mate by proximity; another player's bloom sits on that player.
  for stage in 0 ..< 4:
    for o in client.spriteObjectsWithLabel("muzzle bloom stage " & $stage):
      if dist(client.mapPos(o), mate) <= float(MuzzleBloomSize):
        return true
  false

proc walkableAt(client: ProtocolClient, x, y: int): bool =
  if x < 0 or y < 0 or x >= client.walkabilityWidth or
      y >= client.walkabilityHeight:
    return false
  client.walkabilityMask[y * client.walkabilityWidth + x]

proc footprintFits(client: ProtocolClient, x, y: int): bool =
  ## True when the player's solid box centered at (x, y) is all walkable,
  ## mirroring canOccupy in the sim.
  for dy in -PlayerHalf .. PlayerHalf:
    for dx in -PlayerHalf .. PlayerHalf:
      if not client.walkableAt(x + dx, y + dy):
        return false
  true

proc cellOf(p: Vec): int =
  let
    cx = clamp(int(p.x) div NavCell, 0, GridW - 1)
    cy = clamp(int(p.y) div NavCell, 0, GridH - 1)
  cy * GridW + cx

proc cellCenter(cell: int): Vec =
  vec(
    float((cell mod GridW) * NavCell + NavCell div 2),
    float((cell div GridW) * NavCell + NavCell div 2)
  )

proc pixelRayClear(client: ProtocolClient, a, b: Vec): bool =
  ## True when no wall pixel blocks the segment; mirrors lineOfSightClear in
  ## the sim (walls are exactly the non-walkable pixels).
  let
    ax = int(a.x)
    ay = int(a.y)
    bx = int(b.x)
    by = int(b.y)
    steps = max(abs(bx - ax), abs(by - ay))
  if steps == 0:
    return true
  for s in 1 .. steps:
    if not client.walkableAt(ax + (bx - ax) * s div steps,
                             ay + (by - ay) * s div steps):
      return false
  true

proc rayClearCoarse(client: ProtocolClient, a, b: Vec, step: float): bool =
  ## Coarsely-sampled walkability raycast for cover scoring and exposure
  ## costing, where an occasional missed thin corner is an acceptable trade.
  let
    d = b - a
    l = d.len()
  if l < 1e-6:
    return true
  let n = max(1, int(l / step))
  for s in 1 .. n:
    let p = a + d * (float(s) / float(n))
    if not client.walkableAt(int(p.x), int(p.y)):
      return false
  true

proc openLineLen(client: ProtocolClient, a, dir: Vec, maxLen, step: float): float =
  ## Length of the wall-free ray from `a` along unit `dir`, capped at maxLen.
  ## Sizes sniper firing lines and arrow-snipe rays under the map-wide gun.
  var l = step
  while l <= maxLen:
    let p = a + dir * l
    if not client.walkableAt(int(p.x), int(p.y)):
      return l - step
    l += step
  maxLen

proc homeSign(team: Team): float =
  ## -1 toward Red's home edge (left), +1 toward Blue's (right).
  if team == Red: -1.0 else: 1.0

var SelfStrategyTeam = Red
  ## This process's own team, mirrored into a module global so the
  ## team-parameterised geometry procs can tell "ours" from "theirs" without
  ## threading the Bot through every call site (one bot per process).

proc statedZone(color: string): tuple[
    have: bool, compact: bool, c: Vec, x0, y0, x1, y1: float] =
  ## One team's capture region as the ENGINE states it, from the per-team
  ## endzone init marker. `compact` marks the archetypes that bound y as well
  ## as x (square / disc / corner / arm) — the classic `column` runs the full
  ## height, which is what all the old mirrored-arena math assumed.
  for z in EndzoneMarks:
    if z.color == color:
      return (have: true,
              compact: z.shape != LabelEndzoneShapeColumn,
              c: vec(float(z.x0 + z.x1) * 0.5, float(z.y0 + z.y1) * 0.5),
              x0: float(z.x0), y0: float(z.y0),
              x1: float(z.x1), y1: float(z.y1))

proc homeDeepX(team: Team): float =
  ## The x a carrier drives to in order to SCORE.
  ##
  ## This used to be a flat 150px off the home edge — correct only for the
  ## classic full-height home column. Generated maps pull half their bases
  ## well OFF the home edge and wrap them in a disc or square, which turns
  ## that border strip into ordinary wilderness: measured on 8 generated
  ## seeds, x=150 fell OUTSIDE the real capture zone on 3 of them, so a steal
  ## on those maps could never be converted no matter how well it was escorted.
  ## The engine states every zone up front, so use it.
  let
    z = statedZone(if team == SelfStrategyTeam: SelfColor else: SelfEnemyColor)
    tuned = (if team == Red: 150.0 else: float(MapW - 1) - 150.0)
  # A COMPACT zone is the case the tuned depth gets outright wrong — it sits in
  # wilderness there. A full-height COLUMN zone is the case the tuned depth was
  # MEASURED for, so leave it alone: the zone centre is ~47px deeper on the
  # stock arena, which is further into our own spawn pocket for no gain. Only
  # fall back to the centre if a narrow column would put the tuned point
  # outside the stated box.
  if z.have and z.compact:
    return z.c.x
  if z.have and (tuned < z.x0 or tuned > z.x1):
    return z.c.x
  tuned

proc captureAim(team: Team, me: Vec, laneY: float): Vec =
  ## Where a carrier should actually steer to score. A compact endzone bounds
  ## BOTH axes, so holding the old lane height (LaneTop/LaneBottom sit at the
  ## board edges) walks the carrier past the zone entirely — there, aim at the
  ## stated centre. A column zone is full-height, so the tuned lane choice
  ## still applies and only x matters.
  let z = statedZone(if team == SelfStrategyTeam: SelfColor else: SelfEnemyColor)
  if z.have and z.compact:
    return z.c
  vec(homeDeepX(team), laneY)

proc enemy(team: Team): Team =
  ## The opposing team.
  if team == Red: Blue else: Red

proc flagHome(team: Team): Vec =
  ## The STATIC pedestal position of one team's flag: the center of the
  ## team's protected spawn pocket (matches flagHome in src/ctf/sim.nim).
  if team == Red: vec(186, 329) else: vec(1049, 329)

const ChokeOffset = 204.0
  ## How far the defender posts OFF its own pedestal, toward the field. The
  ## stock arena's tuned pair was pedestal x=186 / choke x=390.

proc chokeSpot(team: Team): Vec =
  ## Defender hold point between our heart and the field it is threatened from.
  ##
  ## This used to be the arena's mirrored constant, which only ever knew Red and
  ## Blue. On a four-team board green and yellow got BLUE's post: measured on a
  ## 2496x2496 board, green's defender held station 2503px from the heart it
  ## exists to guard, yellow's 1809px. Half our four-team seats therefore left
  ## their heart completely unguarded — and losing the heart is not a setback
  ## there, it is ELIMINATION (GV32).
  ##
  ## Derived instead from the team's own stated home, offset toward the board
  ## centre so the post sits on the approach. On the stock arena this reproduces
  ## the tuned value: pedestal (186,329) + 204px toward centre = (390,329).
  let z = statedZone(if team == SelfStrategyTeam: SelfColor else: SelfEnemyColor)
  if z.have:
    let
      centre = vec(float(CenterX), float(CenterY))
      away = centre - z.c
      d = away.len()
    if d > 1.0:
      return z.c + away * (ChokeOffset / d)
    return z.c
  if team == Red: vec(390, 340) else: vec(float(MapW - 1) - 390.0, 340)

proc ownShieldSpawn(team: Team): Vec =
  ## Our team's endzone shield spawn — a STATIC known point (sim resetShields:
  ## inset x = ArenaBorder(10)+GrenadeSpawnInset(40) = 50, y = 3/4 map height),
  ## mirrored across center. Known like the pedestals, so a rusher navigates to
  ## it WITHOUT needing line-of-sight (VisionBubble is only 90px — the shield sits
  ## behind the spawn cone and is never "seen"; that's why the see-it scan fired 0).
  let y = float(3 * MapH div 4)
  if team == Red: vec(50, y) else: vec(float(MapW - 50), y)

proc arcSpawn(team: Team): Vec =
  ## Our team's plasma-arc spawn — the STATIC point vertically OPPOSITE the shield
  ## (sim plasmaArcSpawnPoints: same inset x=50 back column, but y=1/4 map height —
  ## arcs high, shields low). Deep in our OWN back corner, so a SAFE grab route on
  ## our side, but it sits ~200px behind a forward breacher and WAY outside the 90px
  ## vision bubble: the breacher must navigate to the known coordinate, it can never
  ## SEE the sprite to home on it (the fires-0 bug the LOS-gated seek had). The pickup
  ## respawns 30s after a grab, so a fresh one is essentially always waiting here.
  let y = float(MapH div 4)
  if team == Red: vec(50, y) else: vec(float(MapW - 50), y)

proc nearestOpenCell(bot: Bot, cell: int): int =
  ## The nearest walkable nav cell, searched in expanding rings.
  if bot.cellWalkable[cell]:
    return cell
  let
    cx = cell mod GridW
    cy = cell div GridW
  for r in 1 .. 16:
    for dy in -r .. r:
      for dx in -r .. r:
        if abs(dx) != r and abs(dy) != r:
          continue
        let
          nx = cx + dx
          ny = cy + dy
        if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
          continue
        if bot.cellWalkable[ny * GridW + nx]:
          return ny * GridW + nx
  cell

proc snapToCover(bot: Bot, p: Vec): Vec =
  ## The nearest cover cell within a few cells of a point, else the point.
  let
    c0 = bot.nearestOpenCell(cellOf(p))
    cx = c0 mod GridW
    cy = c0 div GridW
  var bestD = 1e18
  result = p
  for dy in -6 .. 6:
    for dx in -6 .. 6:
      let
        nx = cx + dx
        ny = cy + dy
      if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
        continue
      let nc = ny * GridW + nx
      if not bot.coverCell[nc]:
        continue
      let d = dist(cellCenter(nc), p)
      if d < bestD:
        bestD = d
        result = cellCenter(nc)

proc scanPost(
    bot: Bot, client: ProtocolClient, eSign, wantY: float
): tuple[hold, peek: Vec, ready: bool] =
  ## Finds one overwatch sniper post for the side whose guns point along
  ## `eSign`: a cover cell hugging the center ring, shielded from the front,
  ## with a sideways peek cell that owns the LONGEST clear firing line — the
  ## map-wide gun makes the lane length the post's value.
  var bestScore = 1e18
  for cy in 0 ..< GridH:
    for cx in 0 ..< GridW:
      let c = cy * GridW + cx
      if not bot.coverCell[c]:
        continue
      let
        p = cellCenter(c)
        fwd = eSign * (p.x - float(CenterX))
      if fwd > -40.0 or fwd < -160.0:
        continue                         # this side of the ring, hugging it
      if rayClearCoarse(client, p, p + vec(eSign * CoverShieldDist, 0.0), 4.0):
        continue                         # nothing shields us from the front
      var
        peek: Vec
        peekLine = 0.0
      for dyc in [-2, 2, -1, 1]:
        let ny = cy + dyc
        if ny < 0 or ny >= GridH or not bot.cellWalkable[ny * GridW + cx]:
          continue
        let q = cellCenter(ny * GridW + cx)
        let line = openLineLen(client, q, vec(eSign, 0.0), FireRange, 6.0)
        if line > peekLine:
          peekLine = line
          peek = q
      if peekLine < PeekLineDist:
        continue
      # The firing-line length dominates; the position terms break near-ties
      # toward the wanted flank height and hugging the flag ring.
      let score = abs(p.y - wantY) + abs(fwd + 90.0) * 0.7 - peekLine * 0.7
      if score < bestScore:
        bestScore = score
        result.hold = p
        result.peek = peek
        result.ready = true

proc findFunnelThroat(bot: Bot) =
  ## fatalFunnel (backlog #5, FM 90-10-1 App K): the THROAT of the enemy's
  ## approach to our pedestal — the narrowest walkable vertical gap between the
  ## center line and our flag, inside the pedestal's y-band. A raider coming
  ## for our heart MUST cross it; it is pure deterministic map geometry (the
  ## walkability grid), identical for every seat, so no comms are involved.
  ## Scan each grid column between the pedestal and the center ring; per
  ## column, find the longest contiguous walkable y-run that overlaps the
  ## pedestal band; the column whose best run is NARROWEST is the funnel, and
  ## the throat is that run's center.
  bot.funnelReady = false
  let
    sign = homeSign(bot.team)
    ped = flagHome(bot.team)
    x0 = cellOf(vec(min(ped.x + sign * 40.0, float(CenterX)), 0.0)) mod GridW
    x1 = cellOf(vec(max(ped.x + sign * 40.0, float(CenterX)), 0.0)) mod GridW
  var bestWidth = int.high
  for cx in min(x0, x1) .. max(x0, x1):
    if cx < 0 or cx >= GridW:
      continue
    var runStart = -1
    var colBestW = int.high
    var colBestY = -1
    for cy in 0 .. GridH:                # sentinel row closes the last run
      let open = cy < GridH and bot.cellWalkable[cy * GridW + cx]
      if open and runStart < 0:
        runStart = cy
      elif not open and runStart >= 0:
        let
          runEnd = cy - 1
          loY = cellCenter(runStart * GridW + cx).y
          hiY = cellCenter(runEnd * GridW + cx).y
        # the run must overlap the pedestal band (the approach axis)
        if hiY >= ped.y - FunnelBand and loY <= ped.y + FunnelBand:
          let w = cy - runStart
          if w < colBestW:
            colBestW = w
            colBestY = (runStart + runEnd) div 2
        runStart = -1
    if colBestY >= 0 and colBestW < bestWidth:
      bestWidth = colBestW
      bot.funnelThroat = cellCenter(colBestY * GridW + cx)
      bot.funnelReady = true

proc pickPost(bot: Bot, client: ProtocolClient) =
  ## Chooses our own overwatch post (the overwatch seat only): fire from the
  ## peek, duck back to the hold during cooldown.
  bot.postReady = false
  if bot.role != Overwatch:
    return
  let
    eSign = -homeSign(bot.team)
    wantY = float(CenterY) + 60.0
  let post = bot.scanPost(client, eSign, wantY)
  if post.ready:
    bot.postHold = post.hold
    bot.postPeek = post.peek
    bot.postReady = true

proc findEnemyPosts(bot: Bot, client: ProtocolClient) =
  ## Precomputes the standing virtual threats every carrier run has to
  ## respect, fed into exposure costing and lane choice: the mirrored ENEMY
  ## overwatch post (a stationary, hidden killer) and the ENEMY spawn
  ## pocket — every kill respawns an armed, spawn-protected enemy at the
  ## pedestal aiming our way, so the pocket mouth (and its mid lane) is
  ## permanently watched ground even when no track remembers anyone there.
  bot.enemyPosts.setLen(0)
  let post = bot.scanPost(client, homeSign(bot.team), float(CenterY) + 60.0)
  if post.ready:
    bot.enemyPosts.add(post.peek)
  bot.enemyPosts.add(flagHome(enemy(bot.team)))

proc dominateApproach(): array[6, (float, float)] =
  ## #7: the ground an intruder MUST cross to reach our pedestal — waypoints on
  ## the three lanes at the mid line and just inside our half, mirrored per team
  ## via homeSign. These are where the occupancy heatmap shows enemy travel
  ## concentrates (mid crossings feeding the pedestal pocket). A proc, not a
  ## const, because the lanes are map-derived now (adoptMapSize).
  [(0.0, LaneTop), (0.0, LaneMid), (0.0, LaneBottom),      # the mid crossing
   (170.0, LaneTop), (170.0, LaneMid), (170.0, LaneBottom)] # just inside our half

proc pickDominatePost(bot: Bot, client: ProtocolClient) =
  ## #7 POINT OF DOMINATION (home defender): rather than sit on a fixed choke
  ## spot, hold the cover cell on our side of the ring that COMMANDS the most of
  ## the ground an intruder has to cross to reach our pedestal — the cell whose
  ## clear firing lines cover the largest count of the enemy-approach waypoints
  ## (the mid-lane crossings the heatmap shows enemies funnel through). Under a
  ## map-wide gun, the seat that sees the most approach lanes kills the thief
  ## before it reaches the pocket. Computed once at nav build; a tiebreak keeps
  ## it near the classic choke so it does not wander off our capture column.
  bot.dominateReady = false
  if bot.role != HomeDefender:
    return
  let
    sign = homeSign(bot.team)
    choke = chokeSpot(bot.team)
    # Anchor the approach waypoints into map space for this team.
    lo = int((float(CenterX) + sign * DominateGuardBand) / float(NavCell))
    hi = int(float(CenterX) / float(NavCell))
    (x0, x1) = (min(lo, hi), max(lo, hi))
  var bestScore = -1e18
  for cy in 0 ..< GridH:
    for cx in x0 .. x1:
      if cx < 0 or cx >= GridW:
        continue
      let c = cy * GridW + cx
      if not bot.coverCell[c]:
        continue
      let p = cellCenter(c)
      # Must sit on OUR side of the ring, not out past the center line.
      if sign * (p.x - float(CenterX)) < 0.0:
        continue
      var covered = 0
      for w in dominateApproach():
        let wp = vec(float(CenterX) + sign * w[0], w[1])
        if dist(p, wp) <= FireRange and client.pixelRayClear(p, wp):
          inc covered
      if covered == 0:
        continue
      # Lanes commanded dominate; break near-ties toward the classic choke so
      # the defender still screens our own capture column.
      let score = float(covered) * 1000.0 - dist(p, choke)
      if score > bestScore:
        bestScore = score
        bot.dominatePost = p
        bot.dominateReady = true

proc adoptMapSize(client: ProtocolClient) =
  ## The walkability sprite spans the whole arena: adopt its dimensions as THE
  ## map size and rederive everything position-shaped. Paintbot draws a fresh
  ## map every episode, so the size must be read off the wire, never assumed.
  MapW = client.walkabilityWidth
  MapH = client.walkabilityHeight
  CenterX = MapW div 2
  CenterY = MapH div 2
  GridW = (MapW + NavCell - 1) div NavCell
  GridH = (MapH + NavCell - 1) div NavCell
  LaneMid = float(CenterY)
  LaneBottom = float(MapH) - LaneTop
  # The gun is a FIXED config.gunRange on every board since GV34 (1300px in
  # every paintbot variant). Engage at the gun's reach, capped by the board's
  # own diagonal so a small map never inflates the cap.
  FireRange = min(GunRangePx, sqrt(float(MapW * MapW + MapH * MapH)))
  NadeMaxRange = float(MapW div 5)      # sim GrenadeMaxRange
  ShoutHeardRange = float(MapW div 5)   # sim ShoutRange
  MedKitAX = float(MapW div 2)
  MedKitAY = float(MapH div 3)
  MedKitBX = float(MapW div 2)
  MedKitBY = float(2 * MapH div 3)

proc adoptGameParams(client: ProtocolClient) =
  ## Reads the stated episode parameters off the init marker
  ## `game teams <count> map <width>x<height>` (LabelPrefixGameParams). The
  ## team count is the marker's unique intel; the size restates the
  ## walkability sprite, which adoptMapSize already took.
  for o in client.spriteObjects():
    if o.label.startsWith(LabelPrefixGameParams):
      let parts = o.label[LabelPrefixGameParams.len .. ^1].split(' ')
      if parts.len == 3:
        try:
          GameTeams = clamp(parseInt(parts[0]), 2, 4)
        except ValueError:
          discard
      break

proc adoptEndzones(client: ProtocolClient) =
  ## Reads every team's stated home capture region off the per-team init
  ## markers `endzone <color> <shape> <x0>,<y0> <x1>,<y1>`. The shape token is
  ## validated against the closed LabelEndzoneShapes vocabulary, which also
  ## skips the spectator-only `endzone <color> power <n>` glow labels.
  EndzoneMarks.setLen(0)
  for o in client.spriteObjects():
    if not o.label.startsWith(LabelPrefixEndzone):
      continue
    let parts = o.label[LabelPrefixEndzone.len .. ^1].split(' ')
    if parts.len != 4 or parts[1] notin LabelEndzoneShapes:
      continue
    let
      lo = parts[2].split(',')
      hi = parts[3].split(',')
    if lo.len != 2 or hi.len != 2:
      continue
    try:
      EndzoneMarks.add (
        color: parts[0], shape: parts[1],
        x0: parseInt(lo[0]), y0: parseInt(lo[1]),
        x1: parseInt(hi[0]), y1: parseInt(hi[1]))
    except ValueError:
      discard

proc buildNavGrid(bot: Bot, client: ProtocolClient) =
  ## Erodes the pixel walkability mask into a footprint-safe nav grid, then
  ## derives the cover model (cover cells, overwatch post, defender choke).
  adoptMapSize(client)
  adoptGameParams(client)
  adoptEndzones(client)
  # ⭐⭐ THE STATUE FIX. A 4-team board deals seats round the teams (slot mod
  # teams, roster.teamForSlot), so the classic red/blue parity guess is wrong
  # for half of them — and a wrong color makes EVERY label scan blind,
  # including findSelf, which then reports us dead and returns a zero input
  # mask forever. Measured: green and yellow travelled exactly 0px across a
  # whole episode. Re-deal the color now that the team count is stated; the
  # self marker confirms or corrects it on the first alive frame.
  if GameTeams > 2 and not bot.colorLocked:
    bot.myColor = TeamColorNames[bot.slot mod GameTeams]
  # Our rank WITHIN our own team is slot div teams (the engine's own
  # slotIdentityIndex): seats deal round the active teams. The old slot-div-2
  # reading is only correct on a 2-team board, and on a 32-seat four-team board
  # it ran off the end of the role table and clamped four seats onto
  # HomeDefender.
  bot.role = roleForSeat(clamp(bot.slot div max(GameTeams, 2), 0, 7), bot.team)
  bot.cellWalkable = newSeq[bool](GridW * GridH)
  for cy in 0 ..< GridH:
    for cx in 0 ..< GridW:
      bot.cellWalkable[cy * GridW + cx] = client.footprintFits(
        cx * NavCell + NavCell div 2, cy * NavCell + NavCell div 2)
  bot.coverCell = newSeq[bool](GridW * GridH)
  for cy in 0 ..< GridH:
    for cx in 0 ..< GridW:
      let c = cy * GridW + cx
      if not bot.cellWalkable[c]:
        continue
      block adjacency:
        for dy in -1 .. 1:
          for dx in -1 .. 1:
            if dx == 0 and dy == 0:
              continue
            let
              nx = cx + dx
              ny = cy + dy
            if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
              continue
            if not bot.cellWalkable[ny * GridW + nx]:
              bot.coverCell[c] = true
              break adjacency
  bot.exposure = newSeq[bool](GridW * GridH)
  bot.navDist = newSeq[int32](GridW * GridH)
  bot.navGoal = -1
  bot.pickPost(client)
  bot.findEnemyPosts(client)
  bot.pickDominatePost(client)
  bot.chokeHold = bot.snapToCover(chokeSpot(bot.team))
  bot.findFunnelThroat()
  bot.navBuilt = true

const NavNeighbors = [
  (1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)
]

proc rebuildExposure(bot: Bot, client: ProtocolClient) =
  ## Marks nav cells the freshest remembered enemies — plus the mirrored
  ## enemy sniper posts, which are stationary hidden threats all game —
  ## could shoot into (inside gun range with a coarsely-clear line). Used as
  ## a soft path cost.
  for i in 0 ..< bot.exposure.len:
    bot.exposure[i] = false
  var
    threatSpots: seq[Vec] = bot.enemyPosts
    threats = 0
  for t in bot.enemies:                  # already sorted freshest-first
    if threats >= ExposureThreats or bot.tick - t.lastSeen > ExposureTrackTtl:
      break
    inc threats
    threatSpots.add(t.pos)
  for spot in threatSpots:
    let
      x0 = max(0, int(spot.x - ExposureRange) div NavCell)
      x1 = min(GridW - 1, int(spot.x + ExposureRange) div NavCell)
      y0 = max(0, int(spot.y - ExposureRange) div NavCell)
      y1 = min(GridH - 1, int(spot.y + ExposureRange) div NavCell)
    for cy in y0 .. y1:
      for cx in x0 .. x1:
        let c = cy * GridW + cx
        if bot.exposure[c] or not bot.cellWalkable[c]:
          continue
        let p = cellCenter(c)
        if dist(p, spot) <= ExposureRange and
            rayClearCoarse(client, spot, p, 8.0):
          bot.exposure[c] = true

proc computeFieldInner(bot: Bot, client: ProtocolClient, goal: int) =
  ## Cost field (Dijkstra) over the nav grid toward one goal cell. Steps cost
  ## StepCost/DiagCost and entering a threat-exposed cell adds ExposedCost, so
  ## paths prefer segments that keep obstacles between us and known enemies.
  ## Diagonal steps require both orthogonal neighbors open (no corner cuts).
  bot.rebuildExposure(client)
  for i in 0 ..< bot.navDist.len:
    bot.navDist[i] = -1
  var heap = initHeapQueue[(int32, int32)]()
  bot.navDist[goal] = 0
  heap.push((0'i32, int32(goal)))
  while heap.len > 0:
    let
      (dcur, cur32) = heap.pop()
      cur = int(cur32)
    if dcur > bot.navDist[cur]:
      continue
    let
      cx = cur mod GridW
      cy = cur div GridW
    for (dx, dy) in NavNeighbors:
      let
        nx = cx + dx
        ny = cy + dy
      if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
        continue
      let nc = ny * GridW + nx
      if not bot.cellWalkable[nc]:
        continue
      if dx != 0 and dy != 0 and
          not (bot.cellWalkable[cy * GridW + nx] and
               bot.cellWalkable[ny * GridW + cx]):
        continue
      var step = (if dx != 0 and dy != 0: DiagCost else: StepCost)
      if bot.exposure[nc]:
        step += ExposedCost
      let nd = bot.navDist[cur] + step
      if bot.navDist[nc] < 0 or nd < bot.navDist[nc]:
        bot.navDist[nc] = nd
        heap.push((nd, int32(nc)))

proc gridRayClear(bot: Bot, a, b: Vec): bool =
  ## True when the eroded nav grid is open along the whole segment.
  let
    d = b - a
    steps = int(d.len() / 4.0) + 1
  for s in 0 .. steps:
    let p = a + d * (float(s) / float(steps))
    if not bot.cellWalkable[cellOf(p)]:
      return false
  true

proc computeField(bot: Bot, client: ProtocolClient, goal: int) =
  when defined(perfprobe):
    let t0 = getMonoTime()
    bot.computeFieldInner(client, goal)
    ppFieldNs += (getMonoTime() - t0).inNanoseconds
    inc ppFields
  else:
    bot.computeFieldInner(client, goal)

proc navSteer(bot: Bot, client: ProtocolClient, me, target: Vec): Vec =
  ## Direction along the cost-field path toward `target`, with waypoint
  ## lookahead. Falls back to a beeline before the grid exists or when
  ## unreachable.
  if not bot.navBuilt:
    return target - me
  let goal = bot.nearestOpenCell(cellOf(target))
  if goal != bot.navGoal or bot.tick - bot.navStamp >= RepathTicks:
    bot.computeField(client, goal)
    bot.navGoal = goal
    bot.navStamp = bot.tick
  let start = bot.nearestOpenCell(cellOf(me))
  if bot.navDist[start] < 0:
    return target - me
  if bot.navDist[start] == 0:
    return target - me
  var
    node = start
    waypoint = cellCenter(start)
    haveClear = false
  for _ in 0 ..< LookaheadCells:
    var next = -1
    var bestD = bot.navDist[node]
    let
      cx = node mod GridW
      cy = node div GridW
    for (dx, dy) in NavNeighbors:
      let
        nx = cx + dx
        ny = cy + dy
      if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
        continue
      let nc = ny * GridW + nx
      if bot.navDist[nc] < 0 or bot.navDist[nc] >= bestD:
        continue
      if dx != 0 and dy != 0 and
          not (bot.cellWalkable[cy * GridW + nx] and
               bot.cellWalkable[ny * GridW + cx]):
        continue
      bestD = bot.navDist[nc]
      next = nc
    if next < 0:
      break
    node = next
    if bot.gridRayClear(me, cellCenter(node)):
      waypoint = cellCenter(node)
      haveClear = true
    else:
      break
  if not haveClear:
    waypoint = cellCenter(node)
  waypoint - me

proc findDuckCell(bot: Bot, client: ProtocolClient, me, threat: Vec): int =
  ## The nearest directly-reachable cell around us whose center the threat
  ## cannot see; -1 when no nearby cover breaks the line.
  result = -1
  let
    c0 = cellOf(me)
    cx0 = c0 mod GridW
    cy0 = c0 div GridW
  var bestD = 1e18
  for dy in -DuckSearchCells .. DuckSearchCells:
    for dx in -DuckSearchCells .. DuckSearchCells:
      let
        nx = cx0 + dx
        ny = cy0 + dy
      if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
        continue
      let nc = ny * GridW + nx
      if not bot.cellWalkable[nc]:
        continue
      let p = cellCenter(nc)
      if not bot.gridRayClear(me, p):
        continue
      if client.pixelRayClear(p, threat):
        continue                          # the threat can still see this cell
      let d = dist(p, me)
      if d < bestD:
        bestD = d
        result = nc

proc findBankCell(bot: Bot, client: ProtocolClient, me: Vec,
                  threats: seq[Vec]): int =
  ## woundedBank (plan #13 §1.2): the BANK cell — a directly-reachable cell
  ## that breaks the fresh threat lines. Equal top speeds mean radial retreat
  ## holds the gap constant while the map-scale hitscan keeps landing (the
  ## arcStandoff finding: you cannot outrun; you out-GEOMETRY), so the search
  ## prefers ANY LOS-breaking cell over any open one:
  ##   tier 2  breaks EVERY fresh threat line
  ##   tier 1  breaks the nearest threat's line
  ##   tier 0  open floor, admitted only with >= BankStandoffGain standoff GAIN
  ## Within a tier: nearest cell wins, kit-gravity tiebreak toward the nearest
  ## static kit spot (kits are hurt-only and heal to full — the disengage-to-
  ## heal synergy). Never a cell deeper into enemy territory (the regroup
  ## home-side rule). -1 when nothing qualifies.
  result = -1
  if threats.len == 0:
    return
  var nearIdx = 0
  var nearD = 1e18
  for i in 0 ..< threats.len:
    let d = dist(threats[i], me)
    if d < nearD:
      nearD = d
      nearIdx = i
  let
    kitA = vec(MedKitAX, MedKitAY)
    kitB = vec(MedKitBX, MedKitBY)
    c0 = cellOf(me)
    cx0 = c0 mod GridW
    cy0 = c0 div GridW
  var bestTier = -1
  var bestCost = 1e18
  for dy in -BankSearchCells .. BankSearchCells:
    for dx in -BankSearchCells .. BankSearchCells:
      let
        nx = cx0 + dx
        ny = cy0 + dy
      if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
        continue
      let nc = ny * GridW + nx
      if not bot.cellWalkable[nc]:
        continue
      let p = cellCenter(nc)
      if not bot.gridRayClear(me, p):
        continue                          # not directly reachable
      if homeSign(bot.team) * (p.x - me.x) < -20.0:
        continue                          # deeper into enemy territory
      var tier = 0
      if not client.pixelRayClear(p, threats[nearIdx]):
        tier = 1
        var breaksAll = true
        for t in threats:
          if client.pixelRayClear(p, t):
            breaksAll = false
            break
        if breaksAll:
          tier = 2
      elif dist(p, threats[nearIdx]) < nearD + BankStandoffGain:
        continue                          # open floor with no real standoff gain
      let cost = dist(p, me) +
        BankKitLambda * min(dist(p, kitA), dist(p, kitB))
      if tier > bestTier or (tier == bestTier and cost < bestCost):
        bestTier = tier
        bestCost = cost
        result = nc

proc findPeekCell(bot: Bot, client: ProtocolClient, me, aim: Vec): int =
  ## The nearest directly-reachable cell that opens a firing line to `aim`
  ## within gun range; -1 when no sidestep grants the shot.
  result = -1
  let
    c0 = cellOf(me)
    cx0 = c0 mod GridW
    cy0 = c0 div GridW
  var bestD = 1e18
  for dy in -PeekSearchCells .. PeekSearchCells:
    for dx in -PeekSearchCells .. PeekSearchCells:
      let
        nx = cx0 + dx
        ny = cy0 + dy
      if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
        continue
      let nc = ny * GridW + nx
      if not bot.cellWalkable[nc]:
        continue
      let p = cellCenter(nc)
      if dist(p, aim) > FireRange or not bot.gridRayClear(me, p):
        continue
      if not client.pixelRayClear(p, aim):
        continue
      let d = dist(p, me)
      if d < bestD:
        bestD = d
        result = nc

proc enemyEmergeAim(bot: Bot, client: ProtocolClient, me, foe: Vec): Vec =
  ## Where a wall-blocked enemy's body FIRST appears when it peeks to shoot us:
  ## the walkable cell NEAREST its hidden body that already has a clear pixel line
  ## to `me`. The enemy steps the shortest distance to get its shot, so that cell
  ## is the highest-probability emergence point — pre-aiming it means our bullet is
  ## already on-bearing as it rounds the corner (vs aiming the body behind the wall
  ## and having to traverse after it shows). Returns a sentinel (x < 0) when no such
  ## corner is within a few cells (the target is deep behind cover, not peeking).
  result = vec(-1, -1)
  let
    c0 = cellOf(foe)
    cx0 = c0 mod GridW
    cy0 = c0 div GridW
  var bestD = 1e18
  for dy in -PeekSearchCells .. PeekSearchCells:
    for dx in -PeekSearchCells .. PeekSearchCells:
      let
        nx = cx0 + dx
        ny = cy0 + dy
      if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
        continue
      let nc = ny * GridW + nx
      if not bot.cellWalkable[nc]:
        continue
      let p = cellCenter(nc)
      if not client.pixelRayClear(me, p):
        continue                         # this cell can't yet see us: not an exit
      let d = dist(p, foe)               # nearest exit to the body = first peek
      if d < bestD:
        bestD = d
        result = p

proc updateTracks(bot: Bot, tracks: var seq[Track], seen: seq[Actor]) =
  ## Matches this frame's sightings to remembered tracks and prunes stale
  ## ones. Velocity is a blended px/tick estimate used to lead shots.
  var claimed = newSeq[bool](tracks.len)
  for a in seen:
    var
      best = -1
      bestD = TrackMatchDist
    for i in 0 ..< tracks.len:
      if claimed[i]:
        continue
      let d = dist(tracks[i].pos, a.pos)
      if d < bestD:
        bestD = d
        best = i
    if best >= 0:
      let
        dt = float(max(1, bot.tick - tracks[best].lastSeen))
        v = (a.pos - tracks[best].pos) * (1.0 / dt)
      tracks[best].vel = vec(
        clamp((tracks[best].vel.x + v.x) * 0.5, -3.0, 3.0),
        clamp((tracks[best].vel.y + v.y) * 0.5, -3.0, 3.0)
      )
      tracks[best].pos = a.pos
      tracks[best].facingRight = a.facingRight
      tracks[best].lastSeen = bot.tick
      if a.hp > 0:
        tracks[best].hp = a.hp
      tracks[best].aimBrads = a.aimBrads   # -1 when this frame's dots unreadable
      if a.hasArc: tracks[best].hasArc = true  # arc is permanent-for-life: sticky
      # Shield tracks the live marker (a carrier can burn it down / it drops on
      # death); refresh both ways so a track that lost its shield stops reading tank.
      tracks[best].hasShield = a.hasShield
      claimed[best] = true
    else:
      tracks.add(Track(
        pos: a.pos, lastSeen: bot.tick, facingRight: a.facingRight, hp: a.hp,
        aimBrads: a.aimBrads, hasArc: a.hasArc, hasShield: a.hasShield))
      claimed.add(true)
  var kept: seq[Track]
  for t in tracks:
    if bot.tick - t.lastSeen <= TrackTtl:
      kept.add(t)
  kept.sort(proc(a, b: Track): int = cmp(b.lastSeen, a.lastSeen))
  if kept.len > TrackCap:                # there are only eight real players
    kept.setLen(TrackCap)
  tracks = kept

proc resetTransient(bot: Bot) =
  ## Drops per-game memory between rounds (lobby / game-over interstitials).
  bot.colorLocked = false      # re-earn the lock from the next game's self
                               # marker; the dealt guess persists as the seed
  bot.stealPedSeen = false     # pedestals are per-episode geometry
  bot.ownPedSeen = false
  bot.plantUntil = 0
  bot.prevStatedAim = -1
  if bot.aimStepBrads <= 0: bot.aimStepBrads = 40
  bot.enemies.setLen(0)
  bot.mates.setLen(0)
  bot.nadeCharge = 0
  bot.nadeLockAim = -1
  bot.nadeHold = 0
  bot.mateFixTick = 0
  bot.shoutWant = ""
  bot.lastShoutTick = 0
  bot.heardPlay = RpNone
  bot.heardPlayTick = 0
  bot.lastCommsTick = 0
  bot.carrierSeen = -100_000
  bot.lastEnemySeen = bot.tick
  bot.gameStart = bot.tick
  bot.firedLast = false
  bot.estAim = spawnAim(bot.team)
  bot.rotSign = 0
  bot.wasDead = false
  bot.scanHigh = false
  bot.stuckTicks = 0
  bot.jinkUntil = 0
  bot.behindLines = false
  bot.navGoal = -1
  bot.lockUntil = -100_000
  bot.aimLockUntil = -100_000
  bot.retreatUntil = -100_000
  bot.bankCell = -1
  bot.bankCellTick = -100_000
  bot.bankBlindSince = bot.tick
  when defined(wbprobe):
    bot.pWasBanking = false
    bot.pBankEnter = 0
    bot.pHadLine = false
    bot.pBroke = false
    bot.pHp1Since = -1
  bot.shieldRushDone = false
  bot.assaultUntil = -100_000
  bot.arcBreachUntil = -100_000
  bot.arcLinePos = vec(-1, -1)
  bot.arcLineTick = -100_000
  bot.sawLineTick = -100_000
  bot.ownHp = 0
  bot.surpriseShoutTick = -100_000
  bot.dieShoutTick = -100_000
  bot.orientUntil = -100_000
  bot.sentrySince = bot.tick
  bot.sentryShift = 0.0

proc scanAim(bot: Bot, watch: Vec, me: Vec = vec(-1, -1)): int =
  ## The scan-sweep aim while holding a position: rake the vision cone back
  ## and forth across the arc around the `watch` heading with real rotation.
  ## Flip the sweep direction whenever the current end is nearly reached.
  let center = bradsOf(watch)
  # #3 TWO-SPEED SCAN: a sentry's sweep should DWELL on the one bearing that
  # matters — the nearest fresh (recently-remembered) threat whose direction
  # falls inside the scan arc — instead of raking straight past it and letting
  # it close in the blind half of the cycle. The turret turns at a fixed rate,
  # so "slow near the danger" means: while such a threat exists, hold the cone
  # on its bearing (dwell); resume the full sweep once it fogs out. Only when a
  # position (`me`) is supplied and the lever is on.
  if bot.tune.twoSpeedScan and me.x >= 0:
    var
      best = -1
      bestD = ScanDwellRange
    for i in 0 ..< bot.enemies.len:
      if bot.tick - bot.enemies[i].lastSeen > ScanDwellTtl:
        continue
      let bearing = bradsOf(bot.enemies[i].pos - me)
      if abs(bradsErr(bearing, center)) > ScanArc:
        continue                         # outside the arc we are responsible for
      let d = dist(bot.enemies[i].pos, me)
      if d < bestD:
        bestD = d
        best = i
    if best >= 0:
      return bradsOf(bot.enemies[best].pos - me)
  var goal = (center + (if bot.scanHigh: ScanArc else: -ScanArc) +
    AimBrads) mod AimBrads
  if abs(bradsErr(goal, bot.estAim)) <= CombatDeadband:
    bot.scanHigh = not bot.scanHigh
    goal = (center + (if bot.scanHigh: ScanArc else: -ScanArc) +
      AimBrads) mod AimBrads
  goal

proc safestLaneY(bot: Bot, me: Vec): float =
  ## The carrier's lane home: fewest remembered enemies AND the best cover
  ## continuity — under map-wide guns a lane whose run has no cover nearby is
  ## a shooting gallery even when it looks empty.
  var
    bestLane = LaneMid
    bestScore = 1e18
  for lane in [LaneTop, LaneMid, LaneBottom]:
    var score = abs(me.y - lane) / 500.0     # mild bias toward the nearest lane
    for t in bot.enemies:
      let towardHome =
        if bot.team == Red: t.pos.x < me.x + 200
        else: t.pos.x > me.x - 200
      if towardHome and abs(t.pos.y - lane) < 120:
        score += 1.0
    for post in bot.enemyPosts:
      # The mirrored enemy sniper posts are standing threats on the run home
      # even when nobody has been seen there.
      if abs(post.y - lane) < 120:
        score += 1.0
    if bot.navBuilt:
      # Cover continuity: sample the run home along the lane and charge each
      # sample with no cover cell in its 3x3 nav neighborhood.
      let
        goalX = homeDeepX(bot.team)
        stepX = (if goalX > me.x: 32.0 else: -32.0)
      var
        x = me.x
        samples = 0
        bare = 0
      while (stepX > 0.0 and x < goalX) or (stepX < 0.0 and x > goalX):
        inc samples
        let
          c = cellOf(vec(x, lane))
          cx = c mod GridW
          cy = c div GridW
        block covered:
          for dy in -1 .. 1:
            for dx in -1 .. 1:
              let
                nx = cx + dx
                ny = cy + dy
              if nx >= 0 and ny >= 0 and nx < GridW and ny < GridH and
                  bot.coverCell[ny * GridW + nx]:
                break covered
          inc bare
        x += stepX
      if samples > 0:
        score += float(bare) / float(samples) * 2.0
    if score < bestScore:
      bestScore = score
      bestLane = lane
  bestLane

proc vanityRoll(slot, tick, salt: int): bool =
  ## Deterministic per-(slot, tick) coin for the vanity-shout rarity gate.
  ## Returns true on ~VanityShoutChance% of frames. Deliberately does NOT touch
  ## the shared rand() stream so the button mask stays byte-identical (the
  ## vanity shouts are proven mask-neutral only because the emit block never
  ## perturbs movement/aim jitter). A cheap integer hash gives per-bot,
  ## per-tick decorrelated draws without any global state.
  var h = uint32(slot * 2654435761'i64 and 0xFFFFFFFF)
  h = h xor uint32((tick * 40503 + salt * 2246822519'i64) and 0xFFFFFFFF)
  h = h * 2246822519'u32
  h = h xor (h shr 15)
  int(h mod 100'u32) < VanityShoutChance

proc friendlyBlocked(bot: Bot, me, aim: Vec, enemyDist: float): bool =
  ## True when a remembered teammate could eat the shot: the bullet is a
  ## corridor hitscan (~14px half width) along the aim ray and the server
  ## kills the NEAREST player inside it, friend or foe — 8v8 puts many
  ## teammates downrange. The fire axis is the exact angle the turret would
  ## fire at right now.
  let dir = bradsDir(bradsOf(aim - me))
  for t in bot.mates:
    let age = float(bot.tick - t.lastSeen)
    if age > 36:
      continue
    let
      rel = t.pos - me
      d = rel.len()
      along = dot(rel, dir)
    if along <= 0 or d < 1e-6:
      continue
    if along >= enemyDist + 14.0:
      continue                          # beyond the target: the target dies first
    if abs(cross(rel, dir)) < CorridorHalfWidth + age * 0.35:
      return true
  false

proc decide(bot: Bot, client: ProtocolClient): uint8 =
  ## Core CTF policy for one frame.
  when defined(statue):
    return 0'u8                          # test dummy: stand still all game
  # ⭐⭐ COLOR TRUTH. The self marker is the ONE sprite only we ever see, so it
  # is the authoritative statement of our own color. Sweep the active team
  # colors until one answers, then LOCK it: a wrong color makes findSelf
  # return "not alive", which makes decide() return a zero input mask, which
  # is a bot that stands on its pedestal for the whole episode. Locking off
  # the marker also means we no longer depend on the slot-parity guess being
  # right — it only has to be a good first try.
  var
    myColor = (if bot.myColor.len > 0: bot.myColor
               else: (if bot.team == Red: "red" else: "blue"))
    probe = client.findSelf(myColor)
  if not probe.alive and not bot.colorLocked:
    for c in TeamColorNames.toOpenArray(0, max(GameTeams, 2) - 1):
      if c == myColor:
        continue
      let alt = client.findSelf(c)
      if alt.alive:
        myColor = c
        probe = alt
        break
  if probe.alive and not bot.colorLocked:
    bot.myColor = myColor
    bot.colorLocked = true
    SelfColor = myColor
    # Our color also fixes which team we are on for the mirrored-arena math:
    # colors past blue have no 2-team analogue, so they keep the parity team
    # and lean on the endzone markers for geometry instead.
    if myColor == "red":
      bot.team = Red
    elif myColor == "blue":
      bot.team = Blue
    SelfStrategyTeam = bot.team
  SelfColor = myColor
  SelfEnemyColor = enemyColorFor(myColor)
  SelfStrategyTeam = bot.team
    # Re-stamped EVERY decide, not just at the colour lock: the eval harness
    # runs all 16 bots in ONE process, so a once-per-lock global holds the
    # LAST locked bot's team and the `team == SelfStrategyTeam` discrimination
    # inside the geometry procs turns to garbage. Measured: a RED carrier
    # hauled the stolen flag to the BLUE zone centre (homeDeepX returned 1131
    # for a red seat) and parked there for 8000 ticks — every 10000-tick
    # grab-no-cap DRAW in the v32-v35 gates was this artifact. Production has
    # one bot per process and never sees it; the re-stamp makes the harness
    # faithful and is a no-op live.
  let
    enemyColor = enemyColorFor(myColor)
    alive = probe.alive
    me = probe.pos
  if not alive:
    # Dead: the view is fully fogged (only our corpse renders) and inputs
    # are ignored, so skip perception entirely.
    bot.firedLast = false
    bot.rotSign = 0
    bot.wasDead = true
    when defined(wbprobe):
      if bot.pHp1Since >= 0:
        inc wbHp1Segs
        inc wbHp1Deaths
        wbHp1Ticks += bot.tick - bot.pHp1Since
        bot.pHp1Since = -1
      if bot.pWasBanking:
        inc wbBankDeaths
        bot.pWasBanking = false
    return 0
  if bot.wasDead:
    # Respawned: the server points the aim back at the enemy side.
    bot.wasDead = false
    bot.estAim = spawnAim(bot.team)
    # ⭐ SHIELD RE-ARM (2026-08-04, force protection): the shield respawns 30s
    # after being taken, and WE respawn inside our own endzone — the shield's
    # own back column (GV25) — so re-arming after death is a near-zero detour
    # from the spawn point. The old once-per-game latch left every later life
    # bare: field carries 2.4 shields/game to our 1.3 on the arena, where our
    # coordinates are right — the deficit is UPTAKE. Fire cost is nil for the
    # seat that matters: slowdowns compose by MAX, and a carrier is already at
    # 3x, so a shielded carrier pays nothing and gains 3 hp (the proven
    # shieldRush premise, now per life instead of once).
    bot.shieldRushDone = false
    bot.lifeStart = bot.tick
  # Absolute turret fix: our own rendered aim-indicator dots show the actual
  # aim every frame, capping any dead-reckoning drift (mask-apply races).
  block resync:
    # ⭐ THE ENGINE STATES OUR EXACT AIM (2026-08-04). The `own aim <brads>`
    # HUD marker (LabelPrefixOwnAim, self-only, TRUE since GV26) states the
    # turret angle outright every frame. This tree predates it and was
    # resyncing off the rotation-SPRITE readback instead — quantized to ±8
    # brads and only corrected past 16. ±8 brads at 100px is ~19px of ray
    # error: MORE than a body radius, invisible to our own trigger gate
    # (which checks estAim, not truth). Fits the field census exactly: our
    # locked heading lands off-body on 27% of CQB shots vs the field's 13%.
    let stated = client.ownAimBrads()
    if stated >= 0 and bot.prevStatedAim >= 0 and bot.rotSign != 0 and
        client.frameAdvance == 1:
      # Infer the true per-tick step from consecutive stated aims across one
      # held-rotate tick. GV36 reinterpreted aimTurnRate as SLOTS/tick, so the
      # honest step is config-dependent and the config is not observable —
      # but its effect is, every frame.
      let d = bradsErr(stated, bot.prevStatedAim) * bot.rotSign
      if d >= 8 and d <= 64 and d mod 8 == 0:
        bot.aimStepBrads = d
    if stated >= 0:
      bot.prevStatedAim = stated
    if stated >= 0:
      # Exact truth: adopt it outright. The old >AimResyncBrads(4) tolerance
      # existed to stop QUANTIZED readbacks fighting healthy dead reckoning;
      # tolerating 4 brads of known error is 10px of ray at 100px for nothing.
      bot.estAim = stated
      break resync
    var seen = client.observedAim(me, myColor)
    if seen < 0 and bot.tune.aimRotRead:
      # v9: no dots exist — read our aim off the self soldier's rotation id
      # instead. ±8 brad quantization vs AimResyncBrads=4: only correct a
      # drift larger than one rotation step, else quantization noise would
      # fight healthy dead reckoning.
      let rotSeen = client.selfRotAim(myColor)
      when defined(arprobe):
        if rotSeen >= 0: inc arSelfRead
      if rotSeen >= 0 and
          abs(bradsErr(rotSeen, bot.estAim)) > RotBradsPerStep:
        seen = rotSeen
        when defined(arprobe): inc arResync
    if seen >= 0 and abs(bradsErr(seen, bot.estAim)) > AimResyncBrads:
      bot.estAim = seen
  let
    shotReady = client.spriteObjectsWithLabel(LabelFireIcon).len > 0
    seenEnemies = client.actorsForEnemies(myColor, bot.tune.aimRotRead)
    seenMates = client.actorsFor(myColor, bot.tune.aimRotRead)
  when defined(arprobe):
    if bot.tune.aimRotRead:
      inc arFrames
      for a in seenEnemies:
        inc arEnemySeen
        if a.aimBrads >= 0: inc arEnemyRead
      for a in seenMates:
        inc arMateSeen
        if a.aimBrads >= 0: inc arMateRead
  # Surprise sensing (read BEFORE updateTracks rewrites lastSeen): an enemy in
  # our face that we were NOT already tracking freshly is a jump-scare — the
  # corner-turn ambush. Drives the "oh shit!" shout.
  # Nearest visible teammate: a genuine ambush is an ENEMY closer than any mate.
  # In a clustered brawl the closest actor is usually a friendly, and a fleeing/
  # dying enemy read a frame stale used to fire "oh shit!" while we were buried
  # in teammates (Maxwell 2026-07-16). Require the surprising enemy to be
  # strictly closer than our nearest mate so it only ever fires on an OPPONENT
  # in our face, never a nearby friendly.
  var nearestMateD = Inf
  for m in seenMates:
    let dm = dist(m.pos, me)
    if dm < nearestMateD:
      nearestMateD = dm
  var surprisePos = vec(-1, -1)
  var surpriseD = SurpriseRadius
  var surpriseGunOnMe = false
  for a in seenEnemies:
    let d = dist(a.pos, me)
    if d >= surpriseD or d >= nearestMateD:
      continue
    var trackedFresh = false
    for t in bot.enemies:
      if dist(t.pos, a.pos) <= TrackMatchDist and
          bot.tick - t.lastSeen <= SurpriseGapTicks:
        trackedFresh = true
        break
    if not trackedFresh:
      surpriseD = d
      surprisePos = a.pos
      # assaultThrough: is the surpriser's gun ON us at the moment of contact?
      # Full cone via the rotation-id bearing when readable, else the coarse
      # facingRight half-plane (same fallback ladder as aimThreat).
      # Widened by AimFuzzBrads (GV24): a point-blank ambusher whose gun reads "aside" on a
      # fuzzed sample is exactly the case where being wrong is fatal — at knife range its
      # next shot cannot miss, so assume the gun is on us unless it is clearly not.
      if a.aimBrads >= 0:
        surpriseGunOnMe =
          abs(bradsErr(a.aimBrads, bradsOf(me - a.pos))) <=
            AimOnConeBrads + AimFuzzBrads
      else:
        surpriseGunOnMe =
          (a.facingRight and a.pos.x < me.x) or
          (not a.facingRight and a.pos.x > me.x)
  # assaultThrough: NEAR-AMBUSH → ASSAULT THROUGH (backlog #6, Battle Drill 4).
  # Caught point-blank in a kill zone (untracked enemy inside SurpriseRadius,
  # gun on us) with NO cover nearer than the enemy, the duck branch below would
  # turn and crawl for cover we don't have — dying with our gun off-axis at a
  # range where its next shot can't miss. Commit to close-and-fire instead:
  # charging keeps our gun on-axis (the turret never has to slew off the fight)
  # and shrinks our angular rate across ITS cone. ⚠️ REF-force guardrail: keyed
  # ONLY to surprise + close range + gun-on-me — NEVER to head-count, and it
  # never retreats; it merely swaps duck-for-charge in this one geometry.
  if bot.tune.assaultThrough and surprisePos.x >= 0 and surpriseGunOnMe:
    when defined(asprobe):
      inc asGunOnMe
    let duck = bot.findDuckCell(client, me, surprisePos)
    if duck < 0 or dist(cellCenter(duck), me) >= surpriseD:
      bot.assaultUntil = bot.tick + AssaultHold
      when defined(asprobe):
        inc asNoCover
  when defined(asprobe):
    if bot.tune.assaultThrough and surprisePos.x >= 0:
      inc asSurprise
  bot.updateTracks(bot.enemies, seenEnemies)
  bot.updateTracks(bot.mates, seenMates)
  if seenEnemies.len > 0:
    bot.lastEnemySeen = bot.tick

  # Damage awareness (SIGHT + SOUND): our own hp pip bar is always sent to us,
  # so a drop since last frame means we were just hit. If no enemy is in front
  # of us (nothing fresh in our cone), find the nearest "shot sound" muzzle
  # ring — a fogged shooter firing at us — and orient toward that bearing so we
  # stop getting shot in the back. Gated behind tune.damageAware.
  block damageSense:
    let (haveHp, hp) = client.selfHp(me, myColor)
    if not haveHp:
      break damageSense
    let prevHp = bot.ownHp
    bot.ownHp = hp
    when defined(msprobe):
      # plan #16 heal funnel, TUNE-INDEPENDENT so a MEDSEE-unset run of the SAME
      # binary is the control. A death reads hp as unread (0) on the dead path, so
      # a respawn cannot masquerade as a heal: only wounded -> full counts.
      if hp in 1 ..< MaxHp: inc msWoundedFrames
      if prevHp in 1 ..< MaxHp and hp >= MaxHp: inc msHeals
    when defined(wbprobe):
      # hp-1 SEGMENT FATE (tune-independent — a WBANK-unset run is the control):
      # a segment opens the frame hp reads 1 and closes on a heal-to-full here
      # or on death in the dead path above. Game-end truncations = opened −
      # closed at the last dump.
      inc wbAllFrames
      if hp == 1 and bot.pHp1Since < 0:
        bot.pHp1Since = bot.tick
      elif hp >= MaxHp and bot.pHp1Since >= 0:
        inc wbHp1Segs
        inc wbHp1Heals
        wbHp1Ticks += bot.tick - bot.pHp1Since
        if bot.pWasBanking:
          inc wbBankHeals
        bot.pHp1Since = -1
      if wbAllFrames mod 20000 == 0:
        stderr.writeLine "WBPROBE frames=" & $wbAllFrames &
          " entries=" & $wbEntries & " bankFrames=" & $wbFrames &
          " finishSusp=" & $wbFinishSuspend & " lineSegs=" & $wbLineSegs &
          " break60=" & $wbBreak60 & " bankDeaths=" & $wbBankDeaths &
          " bankHeals=" & $wbBankHeals & " hp1Segs=" & $wbHp1Segs &
          " hp1Heals=" & $wbHp1Heals & " hp1Deaths=" & $wbHp1Deaths &
          " hp1Ticks=" & $wbHp1Ticks
    if not bot.tune.damageAware or prevHp <= 0 or hp >= prevHp:
      break damageSense                  # first read, respawn, or no damage
    # We took a hit. Is a threat already in view? If so, combat handles it.
    var haveFreshVisible = false
    for a in seenEnemies:
      if dist(a.pos, me) <= FireRange:
        haveFreshVisible = true
        break
    if haveFreshVisible:
      break damageSense
    # Shot from an unseen direction: orient toward the nearest muzzle ring.
    var ringPos = vec(-1, -1)
    var ringD = ShotSoundRange
    for o in client.spriteObjectsWithLabel(LabelShotImpact):
      let p = client.mapPos(o)
      let d = dist(p, me)
      if d < ringD:
        ringD = d
        ringPos = p
    if ringPos.x >= 0:
      bot.orientPos = ringPos
      bot.orientUntil = bot.tick + HpDropOrientTicks

  # Flag bookkeeping (two flags; a carried flag rides its carrier's exact
  # position). The enemy flag can only be carried by OUR team, so its sprite
  # is never fogged and fully describes our attack (pedestal / on me / on a
  # mate). Our own flag can only be carried by the enemy: on its pedestal it
  # is safe, visible off-pedestal is a live thief fix, and ABSENT means a
  # fogged thief is running it toward its home edge.
  var
    iCarry = false
    mateCarry = false
    mateCarryPos: Vec
  let
    # 0.7.8 renderer restore: the objective is a FLAG again, split into two
    # distinct sprites — "<color> flag planted" is the always-visible pedestal
    # banner (present ONLY while the flag sits home), "<color> flag" is the
    # carried banner centered EXACTLY on its carrier (fogged with the carrier).
    # The pre-0.7.8 single "<color> heart" sprite that floated CarriedFlagLift
    # above the carrier is gone; the carried banner now sits ON the carrier.
    enemyPlanted = client.spriteObjectsWithLabel(enemyColor & " flag planted")
    enemyFlags = client.spriteObjectsWithLabel(enemyColor & " flag")
    ownPlanted = client.spriteObjectsWithLabel(myColor & " flag planted")
    ownFlags = client.spriteObjectsWithLabel(myColor & " flag")
  # ⭐⭐ THE PEDESTALS ARE OBSERVED, NOT ASSUMED.
  #
  # This used to be `flagHome(enemy(bot.team))`, which returned the stock
  # arena's coordinates — (186,329) and (1049,329) — on EVERY map. On a
  # 2496x2496 four-team board that is a point from a different game: our
  # attackers marched to open ground and the grab gate (which needs to be
  # within PocketRushRange of the pedestal) never opened at all. Measured on a
  # giant board: 32 agents, 6491 ticks, the closest ANY of them ever came to an
  # enemy heart was 386px, median 772px, and not one flag was carried all game.
  #
  # RULES: "Always visible regardless of fog: ... both heart pedestals". The
  # planted banner states the exact position every frame we can see it, so cache
  # it the first time and keep it — a pedestal never moves during an episode.
  # While a heart is being CARRIED its planted banner is absent, which is
  # exactly when the cached fix matters.
  # The planted banner is never fogged, so a colour with no banner either had
  # its heart stolen or has been eliminated (GV33 retires a dead team's heart).
  # Either way there is nothing there to raid.
  for i in 0 ..< max(GameTeams, 2):
    HeartHome[i] = client.spriteObjectsWithLabel(
      TeamColorNames[i] & " flag planted").len > 0
  if enemyPlanted.len > 0:
    bot.stealPedPos = client.plantedPedestalPos(enemyPlanted[0])
    bot.stealPedSeen = true
  if ownPlanted.len > 0:
    bot.ownPedPos = client.plantedPedestalPos(ownPlanted[0])
    bot.ownPedSeen = true
  let
    stealTarget =
      if bot.stealPedSeen: bot.stealPedPos
      else:
        let z = statedZone(enemyColor)      # stated endzone centre: their base
        if z.have: z.c else: flagHome(enemy(bot.team))
    ownHome =
      if bot.ownPedSeen: bot.ownPedPos
      else:
        let z = statedZone(myColor)
        if z.have: z.c else: flagHome(bot.team)
  when defined(tgtprobe):
    inc tpFrames
    if tpFrames mod 120 == 0:
      stderr.writeLine "TGT slot=" & $bot.slot & " color=" & myColor &
        " enemyColor=" & enemyColor &
        " pedSeen=" & $bot.stealPedSeen &
        " stealTarget=" & $int(stealTarget.x) & "," & $int(stealTarget.y) &
        " me=" & $int(me.x) & "," & $int(me.y) &
        " distToSteal=" & $int(dist(me, stealTarget)) &
        " role=" & $bot.role & " iCarry=" & $iCarry
  if bot.tune.shout or bot.tune.reactContact or bot.tune.commsPlay:
    # Team comms intake: teammates broadcast on the one shout channel — a
    # 10-char message heard through walls/fog within ~247px. We read the label
    # "<myColor> shout <addr>: <text>" and decode by leading token:
    #   "C<cx> <cy>" carrier's own position (8px grid) — escort fix
    #   "E <cell> <cell>.." enemy callouts on the chess grid — orient the cone
    #   "oh shit!" / "die"  contact shouts — orient toward the shouter's bubble
    #   "P<tok>"    COMMS BUS scenario codeword — adopt the play (movement only)
    # The bubble's own jittered coordinates give the shouter's rough position,
    # used only for the "orient toward the panic/fire" contact reaction.
    let commsSalt = roundSalt(bot.gameStart, bot.team, bot.tune.commsCrypto)
    for o in client.spriteObjects():
      if not o.label.startsWith(myColor & " shout "):
        continue
      let sep = o.label.rfind(": ")
      if sep < 0:
        continue
      let text = o.label[sep + 2 .. ^1]
      if text.len == 0:
        continue
      # Shouter's rough (jittered) location — same map-space math as mapPos, but
      # spriteObjects() yields a bare tuple (no SpriteObjectInfo), so inline it.
      let bubblePos = vec(
        float((o.x + o.width div 2) div RenderScale + client.mapCameraX),
        float((o.y + o.height div 2) div RenderScale + client.mapCameraY))
      if text[0] == 'P' and text.len >= 2 and bot.tune.commsPlay:
        # COMMS BUS: a mate's opaque scenario codeword. Decode with the shared
        # rotating table and bank the play for CommsPlayTtl — adopted as MOVEMENT
        # INTENT only (selectScenarioPlay), never a turret bearing (REF-comms v2).
        let rp = decodeCommsToken(text[1], commsSalt)
        if rp != RpNone:
          bot.heardPlay = rp
          bot.heardPlayTick = bot.tick
          # ⭐ A heard LINE call carries the caller's rough (jittered) bubble position —
          # the caller is AT/just-behind the line it's classifying, so its bubble is a
          # good proxy for where the enemy cluster is. The arc breacher converges here
          # instead of a blind seam, so its cone lands on the REAL line across fog.
          if rp == RpLine:
            bot.arcLinePos = bubblePos
            bot.arcLineTick = bot.tick
          when defined(commsprobe):
            inc csHeard
      elif text[0] == 'C':
        # Carrier heartbeat: fresher than any dead-reckoned escort estimate.
        let parts = text[1 .. ^1].split(' ')
        if parts.len == 2:
          try:
            bot.mateFixPos = vec(float(parseInt(parts[0]) * 8 + 4),
              float(parseInt(parts[1]) * 8 + 4))
            bot.mateFixTick = bot.tick
          except ValueError:
            discard
      elif text[0] == 'E' and bot.tune.reactContact:
        # Enemy callout: seed a fresh track at each named cell we don't already
        # have fresher eyes on, and orient the vision cone toward the nearest.
        var nearest = vec(-1, -1)
        var nearestD = 1e18
        for cell in text[1 .. ^1].split(' '):
          if cell.len == 0:
            continue
          let p = chessDecode(cell)
          if p.x < 0:
            continue
          if dist(p, me) < nearestD:
            nearestD = dist(p, me)
            nearest = p
          # Only adopt if we have no fresh track already near this cell.
          var known = false
          for t in bot.enemies:
            if bot.tick - t.lastSeen <= CalloutFreshTicks and
                dist(t.pos, p) <= float(MapW) / float(ChessFiles):
              known = true
              break
          if not known:
            bot.enemies.add(Track(pos: p, vel: vec(0, 0),
              lastSeen: bot.tick - FreshShotTicks - 1, hp: 0,
              aimBrads: -1))  # a lead, not a shot — no gun bearing known
        # ⭐ Seeding the track above is the ALWAYS-ON intel intake — even a
        # committed carrier now KNOWS the called enemy. The REACTION (turn the
        # cone / move the feet) is separate: with the gate on, only STAGE the
        # nearest callout; the task-priority gate below (after all commitment
        # states are known) decides whether to act on it. Gate off => the old
        # indiscriminate reorient of anyone in earshot.
        if nearest.x >= 0 and nearestD <= ShoutHeardRange:
          if bot.tune.calloutGate:
            bot.calloutPos = nearest
            bot.calloutTick = bot.tick
          else:
            bot.orientPos = nearest
            bot.orientUntil = bot.tick + ContactWatchTicks
      elif (text == "oh shit!" or text == "die") and bot.tune.reactContact:
        # Contact shout from a mate in earshot: turn the vision cone toward the
        # panic/fire so someone covers the ambush (turn-and-watch, not a rush).
        if dist(bubblePos, me) <= ShoutHeardRange:
          if bot.tune.calloutGate:
            bot.calloutPos = bubblePos
            bot.calloutTick = bot.tick
          else:
            bot.orientPos = bubblePos
            bot.orientUntil = bot.tick + ContactWatchTicks
  if enemyPlanted.len > 0:
    discard                              # enemy flag sits home: nobody carries
  elif enemyFlags.len > 0:
    let fp = client.mapPos(enemyFlags[0])
    # Self-carry test: the carried banner is centered EXACTLY on its carrier, so
    # "am I the carrier" is "is the flag on ME and on nobody else" — a visible
    # mate closer to it than us means the mate is the carrier. With the 0.7.8
    # on-carrier banner (no +10px lift, and a separate "flag planted" pedestal
    # sprite) there is no on-pedestal deadlock to special-case: seeing the
    # carried banner at all means the flag is genuinely off its pedestal.
    var mateCloser = false
    let dSelf = dist(fp, me)
    for t in bot.mates:
      if bot.tick - t.lastSeen <= 2 and dist(t.pos, fp) < dSelf:
        mateCloser = true
        break
    if dSelf <= CarrySelfRadius and not mateCloser:
      iCarry = true
    else:
      mateCarry = true                   # only a teammate can be carrying it
      mateCarryPos = fp
      bot.mateFixPos = fp
      bot.mateFixTick = bot.tick
  else:
    # No planted banner and no carried banner in the frame: the flag is off its
    # pedestal on a FOGGED carrier — and only OUR team can carry it, so a
    # teammate is running it home right now even though we cannot see it.
    # Without this inference the whole wave keeps pressing an empty pedestal
    # instead of covering the run. Escort a dead-reckoned fix: the last sighting
    # (or the pedestal it was lifted from) advanced homeward at carrier speed.
    mateCarry = true
    var est =
      if bot.mateFixTick > 0: bot.mateFixPos
      else: stealTarget
    let elapsed = float(bot.tick - max(bot.mateFixTick, bot.gameStart))
    est.x += homeSign(bot.team) * min(
      abs(ownHome.x - est.x),
      elapsed * CarrierEstSpeed
    )
    mateCarryPos = est
  when defined(carryDebug):
    if bot.tick mod 50 == 0 and (iCarry or mateCarry):
      var fpS = "none"
      if enemyFlags.len > 0:
        let fp = client.mapPos(enemyFlags[0])
        fpS = $int(fp.x) & "," & $int(fp.y) & " d=" & $int(dist(fp, me))
      echo "CARRY t=", bot.tick, " slot=", bot.slot, " role=", bot.role,
        " iCarry=", iCarry, " mateCarry=", mateCarry,
        " me=", int(me.x), ",", int(me.y), " fp=", fpS,
        " mateCarryPos=", int(mateCarryPos.x), ",", int(mateCarryPos.y)
      flushFile(stdout)
  var ownStolen = ownPlanted.len == 0
  var sawThief = false
  if ownPlanted.len > 0:
    bot.carrierSeen = -100_000           # our flag is safely home on its pedestal
  elif ownFlags.len > 0:
    # The thief holding our flag is inside our vision: take a fresh fix. The
    # carried banner is centered on the thief, so its position IS the thief's.
    let fp = client.mapPos(ownFlags[0])
    ownStolen = true
    sawThief = true
    bot.carrierPos = fp
    bot.carrierVel = vec(0, 0)
    for t in bot.enemies:
      if dist(t.pos, fp) <= 8:
        bot.carrierVel = t.vel
        break
    bot.carrierSeen = bot.tick

  # (Shout EMIT is deferred to the end of decide(): the "die" pre-fire call
  # needs this frame's fire decision, so all four messages are prioritized and
  # emitted together once the button mask is known — see the emit block below.)

  # Flank progress: sticky so lane-runners do not oscillate at the boundary.
  if bot.role in {FlankTop, FlankBottom}:
    let fwd = -homeSign(bot.team) * (me.x - float(CenterX))
    if fwd >= FlankDepth - 50.0:
      bot.behindLines = true
    elif fwd < 20.0:
      bot.behindLines = false

  # Endgame push: our flag is safe and nobody on OUR side has seen an enemy
  # for a long while deep into the game. The survivors by then are usually
  # the defensive seats, and holding their posts forever is a guaranteed
  # tiebreak stalemate — break the posts and go win by capture (the enemy
  # team pushes symmetrically, so somebody makes something happen).
  let pushOut = not ownStolen and (
    (bot.tick - bot.gameStart > PushOutMinGame and
     bot.tick - bot.lastEnemySeen > PushOutTicks) or
    # Late all-in: a timeout is a scoreless draw, so deep into a game with no
    # capture the posts are worth nothing — break them and go win. Standoffs
    # keep enemies in sight, so the quiet-field trigger above never fires
    # against a peek-duck opponent; this one is on the clock.
    bot.tick - bot.gameStart > LatePushTick
  )

  # ── COMMS BUS C1: classify the live team scenario from OUR OWN fresh local
  # reads (globally-legible ownStolen/sawThief + local enemy/mate clustering).
  # This is the read a bot BROADCASTS and folds into its own play; a mate that
  # can't see it adopts the codeword instead. Movement-intent only downstream —
  # the classifier never touches the turret. Computed only when the bus is wired
  # (commsBus emit OR commsPlay adopt) to keep the shipped path byte-identical.
  var localSc = ScNone
  if (bot.tune.commsBus or bot.tune.commsPlay) and not iCarry:
    if sawThief and ownStolen:
      localSc = ScPeel                     # an exposed thief has our flag — peel
    else:
      # Count fresh enemy guns + fresh mates near the contested pocket / us, and sum
      # the fresh-enemy positions so a called line carries its CENTROID (the breacher
      # converges on the real cluster, not a blind seam).
      var freshEnemyNear = 0
      var freshMateNear = 0
      var enemySum = vec(0, 0)
      for t in bot.enemies:
        if bot.tick - t.lastSeen <= LocalFreshTicks and
            (dist(t.pos, stealTarget) <= CommsScanRange or
             dist(t.pos, me) <= CommsScanRange):
          inc freshEnemyNear
          enemySum = enemySum + t.pos
      for t in bot.mates:
        if bot.tick - t.lastSeen <= LocalFreshTicks and dist(t.pos, me) <= CommsScanRange:
          inc freshMateNear
      let deep = -homeSign(bot.team) * (me.x - float(CenterX)) >= HoldLineTrigDepth
      if freshEnemyNear >= CommsStackDefenders and
          dist(me, stealTarget) <= CommsScanRange:
        localSc = ScStack                  # stacked pocket in front of us
      elif deep and freshEnemyNear <= CommsWipeMax and freshMateNear >= 1:
        localSc = ScWipe                    # we cleared the enemy half — rally the wave
      elif deep and freshEnemyNear >= CommsLineGuns and
          dist(me, stealTarget) > CommsScanRange:
        # ⭐ ANTI-h006 LINE: we've over-extended into the enemy half (deep) and >=2
        # fresh enemy guns are clustered to our front, but we are NOT at the steal
        # pocket (that's ScStack) — a standing defensive line farming our push. Call
        # it so mates a lane away converge + a grenade carrier saturates the cluster.
        localSc = ScLine
        # Record the line's CENTROID for the arc breacher's convergence (own eyes here).
        bot.arcLinePos = enemySum * (1.0 / float(freshEnemyNear))
        bot.arcLineTick = bot.tick
    when defined(commsprobe):
      if localSc == ScStack: inc csStack
      elif localSc == ScWipe: inc csWipe
      elif localSc == ScPeel: inc csPeel
      elif localSc == ScLine: inc csLine

  # Local force balance: an attacker that finds itself outnumbered by fresh
  # enemies inside RetreatRadius — more enemy guns than friendly guns, self
  # included — breaks off and regroups instead of feeding a 1-vs-N duel.
  # Gated behind tune.forceBalance (OFF in the shipped tune — FALSIFIED
  # 2026-07-14 as a win lever, retained only so the harness BALANCE=1 knob
  # still exercises it).
  let offenseRole = bot.role in
    {MidTop, MidBottom, MidGuard, FlankTop, FlankBottom}
  let onOffense = (bot.tune.forceBalance or bot.tune.fireSuperiority) and
    offenseRole and
    not iCarry and not mateCarry and not ownStolen and
    dist(me, stealTarget) >= bot.tune.pocketRushRange
  if onOffense:
    if bot.tune.fireSuperiority:
      # #9 PRESS-VS-BREAK ON FIRE SUPERIORITY (the corrected forceBalance —
      # the head-count version was FALSIFIED because breaking on raw numbers
      # fights the win mechanism: firefights won → wipes/cleared carrier lanes
      # → captures). Break off ONLY when we are genuinely fire-INFERIOR, i.e.
      # the enemy's REAL guns outweigh ours. A wounded enemy is a fractional
      # gun (a 1-hp enemy is one of our trigger-pulls from gone), so weight each
      # fresh local enemy by its remaining hp fraction; unknown hp counts full.
      # Our side counts self + fresh local mates as whole guns. Press (never set
      # retreatUntil) whenever that effective margin is within reach — audacity
      # by default, withdraw only against a real overmatch.
      var enemyGuns = 0.0
      var friendGuns = 1.0               # ourselves, a whole gun
      for t in bot.enemies:
        if bot.tick - t.lastSeen <= LocalFreshTicks and
            dist(t.pos, me) <= RetreatRadius:
          # A shielded enemy is a 6-hp tank that outlasts a normal exchange — count
          # it as more than one gun so we don't press a duel we can't finish. Else
          # weight by hp fraction (a 1-hp enemy is a trigger-pull from gone).
          enemyGuns += (if t.hasShield: ShieldGunWeight
                        elif t.hp in 1 ..< MaxHp: t.hp.float / MaxHp.float
                        else: 1.0)
      for t in bot.mates:
        if bot.tick - t.lastSeen <= LocalFreshTicks and
            dist(t.pos, me) <= RetreatRadius:
          friendGuns += 1.0
      let breakMargin = (if bot.tune.gv21Press: Gv21OutnumberMargin
                         else: bot.tune.outnumberMargin).float
      if enemyGuns - friendGuns >= breakMargin:
        bot.retreatUntil = bot.tick + RetreatHold  # commit the fall-back (hysteresis)
    else:
      var localEnemies = 0
      var localFriends = 1               # ourselves
      for t in bot.enemies:
        if bot.tick - t.lastSeen <= LocalFreshTicks and
            dist(t.pos, me) <= RetreatRadius:
          inc localEnemies
      for t in bot.mates:
        if bot.tick - t.lastSeen <= LocalFreshTicks and
            dist(t.pos, me) <= RetreatRadius:
          inc localFriends
      if localEnemies - localFriends >= bot.tune.outnumberMargin:
        bot.retreatUntil = bot.tick + RetreatHold  # hysteresis: commit the fall-back
  let retreating = onOffense and bot.tick <= bot.retreatUntil
  # ── ⭐ WOUNDED BANK entry (plan #13 §1.1). The trigger is OWN hp state only:
  # hp == 1, where we measured 100% death (n=160 lives, median 83t) — there is
  # no won fight being thrown away at hp1 as a class, and headcount appears
  # NOWHERE in entry/exit (the REF-force distinction). Suspended per-frame by:
  #   • the finish-window — a fresh 1-hp enemy with our clear pixel line inside
  #     FinishRange is one trigger pull from a won exchange (the AGG-E3 state);
  #   • an imminent grab — inside GrabCommitRing the touch ends the episode
  #     (grab→capture is the other proven lever family);
  #   • carrying — carrierFlee + the fight-out ring own carriers (a banked
  #     carrier forfeits the capture). Exit is implicit: a kit heals to FULL
  #     (hp >= 2 fails the entry read next frame) and death re-reads 3.
  var banking = false
  if bot.tune.woundedBank and bot.ownHp == 1 and not iCarry and
      dist(me, stealTarget) > GrabCommitRing:
    banking = true
    for t in bot.enemies:
      if bot.tick - t.lastSeen <= TempoFreshTicks and t.hp == 1 and
          dist(t.pos, me) <= FinishRange and
          client.pixelRayClear(me, t.pos):
        banking = false                    # finish-window: convert, don't bank
        when defined(wbprobe):
          inc wbFinishSuspend
        break
  # BANK sub-mode clock: bankBlindSince = the last tick a fresh threat held a
  # clear pixel ray to us. Blind for >= BankBlindTicks => HOLD (park at the
  # bank cell, aim the re-emergence bearing). medEcon's aimedAtUs veto passes
  # exactly once the line is broken, so kit routing takes over — banking is
  # the missing under-the-gun tier medEcon deliberately refuses to handle.
  var bankLineOnUs = false
  if banking:
    for t in bot.enemies:
      if bot.tick - t.lastSeen <= HoldVsGunTtl and
          dist(t.pos, me) <= HoldVsGunRange and
          client.pixelRayClear(me, t.pos):
        bankLineOnUs = true
        break
    if bankLineOnUs:
      bot.bankBlindSince = bot.tick
  elif bot.tune.woundedBank:
    bot.bankBlindSince = bot.tick          # not banking: keep the blind clock idle
  when defined(wbprobe):
    if banking:
      inc wbFrames
      if not bot.pWasBanking:
        inc wbEntries
        bot.pBankEnter = bot.tick
        bot.pHadLine = false
        bot.pBroke = false
      if bankLineOnUs:
        if not bot.pHadLine:
          bot.pHadLine = true
          inc wbLineSegs
      elif bot.pHadLine and not bot.pBroke:
        bot.pBroke = true
        if bot.tick - bot.pBankEnter <= 60:
          inc wbBreak60
    bot.pWasBanking = banking
  # The fall-back point: regroup on the nearest fresh mate who is NOT deeper in
  # enemy territory than we are (two guns beat the 1-vs-N), else withdraw toward
  # our own side.
  var regroupTo = vec(me.x + homeSign(bot.team) * RetreatStep, me.y)
  if retreating:
    var bestD = RegroupRadius
    for t in bot.mates:
      if bot.tick - t.lastSeen > LocalFreshTicks:
        continue
      if homeSign(bot.team) * (t.pos.x - me.x) < -20.0:
        continue                         # this mate is further into the jaws
      let d = dist(t.pos, me)
      if d < bestD:
        bestD = d
        regroupTo = t.pos
    regroupTo.x = clamp(regroupTo.x, 20.0, float(MapW - 20))
    regroupTo.y = clamp(regroupTo.y, 20.0, float(MapH - 20))

  # Movement target from role and flag situation.
  var target: Vec
  if retreating:
    # Outnumbered locally: pull back to regroup. The combat block below still
    # fires at anything already lined up while we withdraw (a free trade on the
    # way out is fine) — we just stop ADVANCING into the losing cluster.
    target = regroupTo
  elif iCarry:
    # Run the stolen enemy flag home along the emptiest lane; the exposure
    # cost in the path field keeps the route hugging cover past remembered
    # enemies.
    let
      pocket = flagHome(enemy(bot.team))
    var laneY = bot.safestLaneY(me)
    let
      ezc = statedZone(SelfEnemyColor)
      arenaExit = GameTeams <= 2 and not (ezc.have and ezc.compact)
        # The vertical-bugout + border-lane exit is ARENA geometry. On a
        # compact/wrapped endzone or any 4-team layout those lanes are
        # fiction — live census: surviving carriers wandered the pocket for
        # 300-900 ticks at ~0% progress with the override steering them.
        # There, the eroded live nav grid knows the real walls: navSteer
        # straight at captureAim.
    if bot.tune.carrierClearBand and arenaExit:
      # ⭐ Grab-survival: every kill respawns an armed, spawn-protected (thus
      # UNKILLABLE) enemy at this pedestal aimed E-W across pedestal height. A
      # carrier lane at that height (safestLaneY often picks LaneMid) is a
      # straight run down that firing line — the drop@home~4% death. Force the
      # lane to the nearer band-clear corridor and, while still in the pocket
      # AND inside the respawn band, drive PURE-VERTICAL to clear the cone in the
      # fewest ticks before turning for home.
      if abs(laneY - float(CenterY)) < RespawnBandHalf:
        laneY = (if me.y < float(CenterY): LaneTop else: LaneBottom)
      if abs(me.x - pocket.x) < PocketClearX and
          abs(me.y - float(CenterY)) < RespawnBandHalf:
        target = vec(me.x, laneY)          # straight out of the cone, no home-x yet
      else:
        target = captureAim(bot.team, me, laneY)
    elif arenaExit and abs(me.x - pocket.x) < 60.0 and abs(me.y - laneY) > 70.0:
      # Bug out of the pocket VERTICALLY first: every kill respawns an
      # armed, spawn-protected enemy at this pedestal whose spawn aim points
      # along the east-west axis — pure-vertical movement exits that cone
      # fastest, then the border lane runs home outside it.
      target = vec(pocket.x, laneY)
    else:
      target = captureAim(bot.team, me, laneY)
    if bot.tune.carrierHomeStretch:
      # ⭐ FINISH FIX: within CarrierFinishBand of our home edge the entire
      # capture column (x < ArenaCaptureClear = 210, mirrored for Blue) is
      # PROTECTED open floor at EVERY y — a capture scores the instant our
      # center-x crosses the threshold, regardless of height. So once we're
      # this close, stop steering toward an extreme lane (y≈40 / y≈619) whose
      # rows carry the border-attached stub columns near home — that diagonal
      # walks the carrier's corner straight into a stub and wedges it 80px short
      # (the confirmed "stuck on the last wall, bottom of the map" deadlock).
      # Drive STRAIGHT for the column at our current height: the shortest, wall-
      # free line into the score zone.
      # Only a COLUMN zone is protected open floor at every y; a compact
      # endzone would have us drive along our current height straight past it.
      let hz = statedZone(SelfColor)
      if (not (hz.have and hz.compact)) and
          abs(me.x - homeDeepX(bot.team)) < CarrierFinishBand:
        when defined(hsprobe):
          inc hsFireCount
          if abs(target.y - me.y) > 0.5: inc hsMovedCount
        target = vec(homeDeepX(bot.team), me.y)
  elif banking:
    # ⭐ WOUNDED BANK movement (plan #13 §1.2): out-GEOMETRY, not out-run.
    # Route to the bank cell — the nearest reachable cell that breaks the
    # fresh threat lines (kit-gravity tiebreak, never deeper into enemy
    # territory). Position after the carrier arm and before every role/steal
    # arm: a 1-hp attacker is a fed life, not an attacker, so steal pursuit,
    # roles and pickups are overridden while banking (§1.5); the imminent-grab
    # exemption already kept a bot inside GrabCommitRing out of BANK. The gun
    # is NOT touched here — the engage branch still fires the free trade while
    # the feet withdraw, and aimLock/orient keep the cone on the chaser.
    var bankThreats: seq[Vec]
    var bankNear = vec(-1.0, -1.0)
    var bankNearD = 1e18
    var bankRemembered = vec(-1.0, -1.0)   # any-age nearest track (re-emergence)
    var bankRememberedD = 1e18
    for t in bot.enemies:
      let d = dist(t.pos, me)
      if d < bankRememberedD:
        bankRememberedD = d
        bankRemembered = t.pos
      if bot.tick - t.lastSeen > HoldVsGunTtl or d > HoldVsGunRange:
        continue
      bankThreats.add t.pos
      if d < bankNearD:
        bankNearD = d
        bankNear = t.pos
    if bankThreats.len > 0 and
        (bot.bankCell < 0 or bot.tick - bot.bankCellTick > BankRecalc):
      bot.bankCell = bot.findBankCell(client, me, bankThreats)
      bot.bankCellTick = bot.tick
    let bankHold = bot.tick - bot.bankBlindSince >= BankBlindTicks
    if bankHold:
      # HOLD: no fresh line on us for BankBlindTicks. Park at/near the bank
      # cell and aim the RE-EMERGENCE bearing (the threat's last position —
      # the cornerPreAim idea) via the orient mechanism; medEcon below is free
      # to override the target toward a kit (its aimedAtUs veto now passes).
      target = (if bot.bankCell >= 0: cellCenter(bot.bankCell) else: me)
      if bankRemembered.x >= 0:
        bot.orientPos = bankRemembered
        bot.orientUntil = bot.tick + 2
    elif bot.bankCell >= 0:
      target = cellCenter(bot.bankCell)    # SEEK: break the line via cover
    elif bankNear.x >= 0:
      # Open-map fallback (§5.4 caveat): DIAGONAL withdraw, the press-branch
      # pattern mirrored — away + perpendicular-with-clearance, biased toward
      # our side. Radial-only is the measured-useless shape.
      let away = norm(me - bankNear)
      var side = vec(-away.y, away.x)
      if not bot.gridRayClear(me, me + side * 24.0):
        side = side * -1.0
      var dirv = away + side * 0.8
      dirv.x += homeSign(bot.team) * 0.4
      let fb = me + norm(dirv) * 96.0
      target = vec(clamp(fb.x, 20.0, float(MapW - 20)),
                   clamp(fb.y, 20.0, float(MapH - 20)))
    else:
      target = me                          # no threat known: hold; medEcon routes
  elif ownStolen and (bot.role == HomeDefender or
      (bot.role == Overwatch and
       bot.tick - bot.carrierSeen <= (if bot.tune.huntCarrier: HuntCarrierStaleTtl
                                      else: ThiefFixTtl)) or
      (defined(swarm) and not iCarry and not mateCarry and
       bot.tick - bot.carrierSeen <= ThiefFixTtl)):
    # swarm: in shuffled-seat leagues this policy fields only 2-3 agents and
    # their roles are seat-lottery — when our flag is stolen with a fresh fix,
    # whoever sees it hunts, or an enemy capture ends the episode against us.
    # The back line intercepts the thief running OUR flag toward ITS home
    # edge; attackers keep pressing the enemy pedestal so the capture race
    # stays on. With a fresh fix, converge on the predicted route; without
    # one the thief is fogged but MUST cross mid toward its home edge, so
    # the defender guards the crossing on the lane nearest the last fix and
    # sweeps its vision — reacquisition takes eyes, not magic.
    if bot.tick - bot.carrierSeen <= ThiefFixTtl:
      # Converge on the thief's predicted path toward the enemy capture edge.
      var predicted = bot.carrierPos +
        bot.carrierVel * float(18 + bot.tick - bot.carrierSeen)
      predicted.x += -homeSign(bot.team) * 40.0
      target = vec(clamp(predicted.x, 20.0, float(MapW - 20)),
                   clamp(predicted.y, 20.0, float(MapH - 20)))
    elif bot.tune.huntCarrier and bot.carrierSeen > -100_000 and
        bot.tick - bot.carrierSeen <= HuntCarrierStaleTtl:
      # HUNT CARRIER (round-624 OUT-RACE fix): the fix is stale but the flag is
      # STILL out there and the enemy is racing it home. Do NOT park on a static
      # lane guess (the old behavior that let their carrier run EXPOSED 518 ticks
      # unchallenged) and do NOT extrapolate a stale velocity into an off-map
      # phantom — race to the INTERCEPT. The enemy carrier MUST reach its own
      # capture edge (enemy home x), so head for that edge on the lane we last saw
      # it, standing off HuntCarrierStandoff px toward center so we cut the corner
      # and MEET the runner instead of trailing its tail. This is the defensive half
      # of the capture race that pairs with carrierHomeStretch (our finish speed).
      # ⚠️ NOTE (A/B 2026-07-17): this branch NEVER fires in the self-play mirror —
      # the 41–240t stale-fix window it needs is a FIELD-only scenario (self-play
      # kills enemy carriers before the fix goes stale). Validate hosted, not in lab.
      let capEdgeX = flagHome(enemy(bot.team)).x
      target = vec(clamp(capEdgeX + homeSign(bot.team) * HuntCarrierStandoff,
                         20.0, float(MapW - 20)),
                   clamp(bot.carrierPos.y, 20.0, float(MapH - 20)))
    elif GameTeams > 2:
      # ⭐ MULTI-TEAM ROUTE INTERCEPT (FFA-4, 2026-08-03). The 2-team fallback
      # below guards the map centre at an arena lane height — on a 4-team board
      # that is a random midfield point. But a stolen heart can only be CAPTURED
      # at one of exactly three STATED places (the rival endzones, init
      # markers), and it starts from one KNOWN place (our pedestal). Post on
      # the route: measured before this branch existed, our heart was carried
      # 1094 ticks while our nearest bot drifted from 668px to 1239px AWAY.
      #
      # Which zone? Unknowable without a sighting, so cover the two most
      # probable by seat parity (all bots agree — pure function of shared
      # state): nearest zone to our pedestal first (shortest carry, and the
      # rival we contact most), second-nearest for the odd seats. Stand at the
      # route midpoint, not in their zone — their spawn pocket is a grinder.
      var zones: seq[Vec]
      for z in EndzoneMarks:
        if z.color != SelfColor:
          zones.add vec(float(z.x0 + z.x1) * 0.5, float(z.y0 + z.y1) * 0.5)
      if zones.len > 0:
        let anchor = (if bot.ownPedSeen: bot.ownPedPos
                      else: vec(float(CenterX), float(CenterY)))
        for i in 0 ..< zones.len:     # nearest-first, tiny fixed-size sort
          for j in i + 1 ..< zones.len:
            if dist(zones[j], anchor) < dist(zones[i], anchor):
              swap(zones[i], zones[j])
        let pick = zones[min((bot.slot div GameTeams) mod 2, zones.len - 1)]
        target = anchor + (pick - anchor) * 0.55
      else:
        target = vec(float(CenterX), float(CenterY))
    else:
      # No fix this life: guess the lane. Default mid; COUNTER-DAVEEY top-bias
      # guesses LaneTop against a top-heavy field. A stale prior fix (seen earlier
      # this life) still wins over the guess — snap to the lane nearest that.
      var laneY = (if bot.tune.topBias: LaneTop else: LaneMid)
      if bot.carrierSeen > -100_000:
        var bestD = 1e18
        for lane in [LaneTop, LaneMid, LaneBottom]:
          if abs(bot.carrierPos.y - lane) < bestD:
            bestD = abs(bot.carrierPos.y - lane)
            laneY = lane
      target = vec(float(CenterX) - homeSign(bot.team) * 60.0, laneY)
  elif mateCarry and bot.tune.carrierScreen and
      bot.role in {MidBottom, FlankBottom, MidGuard}:
    # ⭐⭐⭐ CONE SCREEN: the killer of a fresh carrier is the INVULNERABLE
    # respawner at the robbed pedestal, shooting straight E-W (spawn aim) at the
    # carrier's y. It is not a "remembered enemy" (it just spawned), so the old
    # nearest-threat screen never sees it. Body-block the ray instead: sit at
    # the carrier's EXACT y, one body toward the enemy pocket the shot comes
    # from — selectFireTarget stops at the first body (friendly fire ON), so the
    # escort eats the shot meant for the carrier. Only while the carrier is
    # still in the danger corridor near the pocket; past that, normal escort.
    let
      pocket = flagHome(enemy(bot.team))
      pocketDist = abs(mateCarryPos.x - pocket.x)
    if pocketDist < PocketClearX * 3.0:
      # -homeSign points from the carrier back toward the enemy pocket.
      target = vec(mateCarryPos.x - homeSign(bot.team) * 30.0, mateCarryPos.y)
    else:
      target = mateCarryPos + vec(homeSign(bot.team) * 40.0, 0.0)
  elif mateCarry:
    case bot.role
    of MidTop, FlankTop:
      target = mateCarryPos + vec(homeSign(bot.team) * 46.0, -30.0)
    of MidBottom, FlankBottom:
      # Rear guard: sit between the carrier and the enemy pocket it just
      # robbed — respawners chase from there, and the gun kills the NEAREST
      # player in the cone, so a body on the ray shields the carrier.
      target = mateCarryPos + vec(
        -homeSign(bot.team) * 42.0,
        (if bot.role == MidBottom: 22.0 else: -22.0)
      )
    of MidGuard:
      # Screen the carrier from the nearest remembered threat.
      var threat = -1
      var threatD = 1e18
      for i in 0 ..< bot.enemies.len:
        let d = dist(bot.enemies[i].pos, mateCarryPos)
        if d < threatD:
          threatD = d
          threat = i
      if threat >= 0:
        target = mateCarryPos + norm(bot.enemies[threat].pos - mateCarryPos) * 30.0
      else:
        target = mateCarryPos + vec(-homeSign(bot.team) * 32.0, 0.0)
    of Overwatch:
      when defined(swarm):
        # Only 2-3 of our agents exist: a completed capture ends the episode,
        # so even the back line escorts the run home.
        target = mateCarryPos + vec(homeSign(bot.team) * 40.0, 24.0)
      else:
        # The posts already overwatch the carrier's retreat across mid.
        target =
          if bot.postReady: bot.postHold
          else: mateCarryPos + vec(-homeSign(bot.team) * 32.0, 0.0)
    of HomeDefender:
      when defined(swarm):
        target = mateCarryPos + vec(homeSign(bot.team) * 40.0, -24.0)
      else:
        target =
          if bot.tune.pointOfDomination and bot.dominateReady: bot.dominatePost
          else: bot.chokeHold      # #7: command the crossing while we attack
    # ESCORT RUN (round-624 KILL-case fix): the role offsets above TRAIL the
    # carrier; they leave no body on the ray of a threat closing from the SIDE or
    # FRONT in open midfield — exactly how the 624 carrier died (minDist=280, alone,
    # past carrierScreen's pocket-cone reach). When a remembered enemy is genuinely
    # closing on the carrier and this bot is a nearby escort, override the trailing
    # offset and INTERPOSE one body onto the threat->carrier ray (friendly fire ON =
    # the first body in the cone eats the shot). Only overrides when a threat is
    # actually near — normal trailing escort is preserved otherwise.
    if bot.tune.escortRun and dist(me, mateCarryPos) < EscortRunMateRange:
      var thr = -1
      var thrD = EscortRunThreatRange
      for i in 0 ..< bot.enemies.len:
        let d = dist(bot.enemies[i].pos, mateCarryPos)
        if d < thrD:
          thrD = d
          thr = i
      if thr >= 0:
        # One body toward the threat from the carrier, onto the incoming ray.
        target = mateCarryPos + norm(bot.enemies[thr].pos - mateCarryPos) * EscortRunGap
  elif bot.role == HomeDefender and not pushOut:
    # Hold the choke on our pedestal approach; break off to chase the nearest
    # intruder on our half (every steal has to come through here).
    var intruder = -1
    var intruderD = 1e18
    for i in 0 ..< bot.enemies.len:
      let onOurHalf =
        if bot.team == Red: bot.enemies[i].pos.x < float(CenterX) + 60
        else: bot.enemies[i].pos.x > float(CenterX) - 60
      if not onOurHalf:
        continue
      let d = dist(bot.enemies[i].pos, me)
      if d < intruderD:
        intruderD = d
        intruder = i
    if intruder >= 0:
      target = bot.enemies[intruder].pos + bot.enemies[intruder].vel * 6.0
    elif bot.tune.pointOfDomination and bot.dominateReady:
      # #7 POINT OF DOMINATION: hold the cover cell that commands the most of the
      # ground an intruder must cross, not a fixed choke — see the thief coming
      # down any lane and kill it before the pocket.
      target = bot.dominatePost
    else:
      target = bot.chokeHold
    # COUNTER-DAVEEY: no intruder in sight — bias the idle post HIGH toward the
    # lane the field favours, so a gun already looks down the top crossing the
    # thief usually takes. Only when holding a fixed choke (not while actively
    # chasing an intruder or on a domination post already scored for coverage).
    if bot.tune.topBias and intruder < 0 and target.y > LaneTop + 40.0:
      target = vec(target.x, max(LaneTop, target.y - 120.0))
  elif bot.role == Overwatch and not pushOut:
    if bot.postReady:
      # Peek-and-shoot cycle: hold behind the post; with the gun up and a
      # remembered enemy in reach, sidestep to the peek cell to open the
      # line (the combat block below takes the shot and ducks us back).
      target = bot.postHold
      if shotReady:
        for t in bot.enemies:
          if bot.tick - t.lastSeen <= 24 and
              dist(t.pos, bot.postHold) < FireRange + 30.0:
            target = bot.postPeek
            break
    else:
      target = vec(float(CenterX) + homeSign(bot.team) * 70.0, float(CenterY))
  else:
    # Attackers: route to the ENEMY pedestal — a fixed, known position by
    # team side. The lead rusher races it dead straight (its seat spawns at
    # pedestal height), the second mid trails behind and offset so one enemy
    # cone cannot kill the pair; flankers run the extreme lanes deep past
    # mid, then hit the pedestal pocket from behind.
    target = stealTarget
    case bot.role
    of MidBottom:
      if dist(me, stealTarget) > 90:
        target = stealTarget + vec(homeSign(bot.team) * 34.0, 26.0)
    of MidGuard:
      if dist(me, stealTarget) > 90:
        target = stealTarget + vec(homeSign(bot.team) * 60.0, -26.0)
    of FlankTop, FlankBottom:
      # Run the wide lane deep, then turn straight in for the grab so the
      # flankers hit the pocket together with the mid trio instead of
      # trickling in.
      let laneY = (if bot.role == FlankTop: LaneTop else: LaneBottom)
      if not bot.behindLines and dist(me, stealTarget) > 170.0:
        target = vec(float(CenterX) - homeSign(bot.team) * FlankDepth, laneY)
    else:
      discard

    # PLAYBOOK: mass the wave on the favored flank. The play (PushTop/PushBottom)
    # is computed from the shared round clock, so all 8 attackers agree on the
    # strong side without comms and it flips every PlayPeriod ticks — an opponent
    # can't pre-stack a fixed lane. Two designated feint holders (the two mids that
    # spawn at flag height) keep the OFF lane so the pedestal is still pressured;
    # the other four attackers bias toward the strong flank on the APPROACH only
    # (not once in the pocket, where everyone must converge on the pedestal).
    if bot.tune.playbook and not iCarry and dist(me, stealTarget) > 150.0:
      # With the comms bus wired, fold our own scenario read + a heard mate play
      # through the shared matrix; otherwise the plain shared-clock flank (the
      # shipped path is byte-identical — selectScenarioPlay reduces to selectPlay
      # when no scenario fires and no play was heard).
      let play =
        if bot.tune.commsPlay or bot.tune.commsBus:
          selectScenarioPlay(bot, bot.tick - bot.gameStart, ownStolen, localSc)
        else:
          selectPlay(bot.tick - bot.gameStart, ownStolen)
      let feintHolder = bot.role in {MidTop, MidBottom}   # the two flag-height mids
      if play == PushTop and not feintHolder:
        target = vec(target.x, max(LaneTop, target.y - PlayFlankPull))
      elif play == PushBottom and not feintHolder:
        target = vec(target.x, min(LaneBottom, target.y + PlayFlankPull))

  # ⭐⭐ CONTINGENCY STATE MACHINE (planLayer). Layers the shared-plan PHASE posture
  # on top of the flank bias above. The phase is a pure fn of shared signals so all 8
  # bots agree and flow branch→branch unanimously. Drives movement HERE and the
  # engage/combat aggression BELOW (botPhase is hoisted so the combat block reads it).
  var botPhase = PhProbe        # function-scope so the combat block can key maxEngage on it
  var pickEdge = false          # function-scope: the Captain's LOCAL man-advantage read, reused
                                # by the pocket-commit gate (commit the dive only WITH advantage)
  if bot.tune.planLayer:
    # Enemy heart state — globally legible. Only OUR team can carry it, so it is either
    # on its pedestal or being carried by us (iCarry => we carry).
    let efState = (if iCarry or mateCarry: EfCarried else: EfPedestal)
    # pickEdge: a LOCAL man-advantage (more fresh mates than fresh enemies near me) — the
    # non-load-bearing accelerator; the machine flows on shared signals without it.
    var freshM = 0
    var freshE = 0
    for t in bot.mates:
      if bot.tick - t.lastSeen <= LocalFreshTicks and dist(t.pos, me) <= PickEdgeRange: inc freshM
    for t in bot.enemies:
      if bot.tick - t.lastSeen <= LocalFreshTicks and dist(t.pos, me) <= PickEdgeRange: inc freshE
    pickEdge = freshM > freshE and freshM >= 1
    botPhase = teamPhase(bot.tick - bot.gameStart, ownStolen, efState, pickEdge,
      (if bot.tune.forceTiming: bot.tune.forceClockTick else: ForceClockTick))
    when defined(phprobe):
      # -d:phprobe ONLY (2026-07-29): phase OCCUPANCY — how many decide() frames the
      # team actually spends in each phase, and how late the clock actually runs. This
      # is the empirical premise the v21 design doc guessed at ("games end ~2500t so
      # PhForce at 3800 rarely fires"); GV23's action-clock floor (overtimeTicks) makes
      # the guess even more suspect, so MEASURE before tuning the constant.
      inc phFrames[botPhase]
      if botPhase == PhDefend: inc dtPhase
      let el = bot.tick - bot.gameStart
      if el > phMaxElapsed: phMaxElapsed = el
      # WS-path emit (2026-08-03): the tallies above only ever printed through the
      # in-process eval harness, which is 2-team-only — on a real 4-team server
      # game the counters incremented and nothing reported them. Same counters,
      # periodic stderr line, so the probe works on ANY board.
      var phTot = 0
      for ph in TeamPhase: phTot += phFrames[ph]
      if phTot mod 100 == 0:
        var line = "PHOCC slot=" & $bot.slot & " tot=" & $phTot
        for ph in TeamPhase:
          line &= " " & ($ph)[2..^1] & "=" & $phFrames[ph]
        line &= " ownStolenNow=" & $ownStolen
        stderr.writeLine line
  if bot.tune.planLayer and not iCarry:
    let phase = botPhase
    let attacker = bot.role in {MidTop, MidBottom, MidGuard, FlankTop, FlankBottom}
    case phase
    of PhOpen:
      # Win the opening clash as a GROUP: pull attackers toward the shared mid lane so
      # the first contact lands together, not eight bots trickling up separate lanes.
      if attacker and dist(me, stealTarget) > PocketRushRange:
        let midPull = clamp(float(CenterY) - me.y, -OpenGroupPull, OpenGroupPull)
        target = vec(target.x, clamp(me.y + midPull, LaneTop, LaneBottom))
    of PhPress:
      # Up a body locally: press the objective — bias deeper toward the pocket to spend
      # the man-advantage before the downed enemy respawns (regroupPush executes the rally).
      if attacker and dist(me, stealTarget) > PocketRushRange:
        target = vec(target.x + homeSign(bot.team) * -PlayFlankPull * 0.5, target.y)
    of PhEscort:
      # WE carry: every free gun collapses onto the carrier's home lane to suppress its
      # chasers (body-block is void — CollisionW=1 — so escort = KILL the chaser). Move
      # toward the carrier's Y so the wave shields the run home; combat handles the kill.
      if attacker and dist(me, mateCarryPos) <= EscortCollapseRange:
        target = vec(target.x, clamp(mateCarryPos.y, LaneTop, LaneBottom))
    of PhForce:
      # Clock late, no decisive edge: commit a grouped all-in on the pedestal — a
      # "good enough" hit beats stalling into the −1 timeout draw. v26: the two DEFENSIVE
      # seats (Overwatch/HomeDefender) join the all-in too — camping a post into a −1
      # timeout draw is the worst outcome, so EVERY seat commits to the enemy pedestal.
      target = stealTarget
    of PhDefend:
      # v26 (defense-recapture 62 → the marquee phase was an inert `discard`): a real
      # FULL-TEAM recapture collapse. Our heart is stolen; the thief runs it toward the
      # ENEMY half, so free ATTACKER seats (the 6 that would otherwise keep pressing the
      # enemy pedestal) turn around and converge on the intercept lane between the thief's
      # last-known spot and the enemy capture edge — body-block is void, so this is to KILL
      # the carrier (combat teeth below raise their engage). The home defenders already hold
      # the pedestal (ownStolen branches); this adds the 6 hunters the phase always promised.
      when defined(phprobe):
        inc dtNotCarry
        if attacker: inc dtAttacker
        if attacker and bot.tune.defendTeeth: inc dtOn
      if attacker:
        if bot.tune.defendTeeth:
          # ⭐ v29 RECAPTURE TEETH — the fix v26 got WRONG. v26 aimed the collapse at
          # `mateCarryPos`, which is where OUR mate carries the ENEMY heart: the wrong
          # entity entirely, and (0,0) whenever no mate carries, so the `> 0.5` guard fell
          # through to `me.y` and the "converge on the thief's lane" collapse resolved to
          # "walk to mid at whatever height I already am" — a mid rally, not a recapture.
          # The thief's real position is `bot.carrierPos` @ `carrierSeen` (the own-flag
          # banner is centered on its carrier), the same read the HomeDefender intercept
          # and huntCarrier already trust. Three tiers by fix freshness:
          if bot.tick - bot.carrierSeen <= ThiefFixTtl:
            when defined(phprobe): inc dtFresh
            # FRESH fix: lead the thief toward ITS capture edge and cut it off ahead.
            var predicted = bot.carrierPos +
              bot.carrierVel * float(18 + bot.tick - bot.carrierSeen)
            predicted.x += -homeSign(bot.team) * DefendInterceptPush
            target = vec(clamp(predicted.x, 20.0, float(MapW - 20)),
                         clamp(predicted.y, 20.0, float(MapH - 20)))
          elif bot.carrierSeen > -100_000 and
              bot.tick - bot.carrierSeen <= HuntCarrierStaleTtl:
            when defined(phprobe): inc dtStale
            # STALE but still out there: do not extrapolate a dead velocity into an
            # off-map phantom (huntCarrier's lesson). Race to the crossing the thief MUST
            # pass, on the lane of the last fix — reacquisition takes eyes, not magic.
            target = vec(float(CenterX) + homeSign(bot.team) * DefendCrossGuard,
                         clamp(bot.carrierPos.y, LaneTop, LaneBottom))
          else:
            when defined(phprobe): inc dtBlind
            # NO usable fix — and MEASURED to be the dominant tier: 1215 of 1263 recapture
            # frames (96%). Of course it is: the 6 attacker seats are deep in enemy ground
            # when the steal lands, so the thief is never in their fog cone. v26 answered
            # this by standing at mid at the bot's own height, which is where an attacker
            # already was — the reason the "collapse" was invisible.
            # But the thief's ROUTE is STATIC GEOMETRY, no fog read needed: it must run from
            # OUR pedestal (flagHome, a known constant) to ITS OWN capture edge. Cut that
            # line at the mid crossing instead of loitering at our own height — the same
            # move that made medEcon work (route to known coords, don't wait to see it).
            # Both pedestals sit at the same height (flagHome y=329 either side), so the
            # route IS the pedestal lane — guard the crossing at THAT height, not ours.
            # Spread the seats into a PICKET across the crossing rather than stacking all
            # six on one pixel: a cluster is what area weapons farm (the grenade lesson
            # from the anti-line work), and a picket covers the lane the thief may drift to.
            let lane = flagHome(bot.team).y
            let spread = float((ord(bot.role) mod 3) - 1) * DefendPicketSpread
            target = vec(float(CenterX) + homeSign(bot.team) * DefendCrossGuard,
                         clamp(lane + spread, LaneTop, LaneBottom))
        else:
          let interceptY = (if mateCarryPos.y > 0.5: clamp(mateCarryPos.y, LaneTop, LaneBottom)
                            else: me.y)
          # Cut toward our own half's crossing (where the thief must run THROUGH), not the
          # enemy pedestal — reverse the attacker's default outbound bias.
          target = vec(float(CenterX) + homeSign(bot.team) * 60.0, interceptY)
    of PhProbe:
      discard   # PROBE = the flank default above

  # SENTRY DISPLACE: a sentry (overwatch / home defender) settled on its post
  # with no live target and no fresh intruder has been standing scanning. SEAL
  # doctrine — never a static target: after a dwell it slides laterally along the
  # watch face to the next covered vantage and re-angles the crossing it commands.
  # The offset is added to the post target (Y for the vertical mid crossing the
  # overwatch owns; toward-mid X nudge for the home choke), flips sign each shift,
  # and only arms when the sentry is actually AT its post with nothing to engage —
  # a real intruder chase (target already set to the enemy) is left untouched.
  if bot.tune.sentryDisplace and bot.role in {Overwatch, HomeDefender} and
      not pushOut and not iCarry and not mateCarry:
    # Effective post = the base post plus the CURRENT lateral shift. atPost is
    # measured against that effective post (not the base) so arriving at a shifted
    # vantage counts as settled — otherwise the dwell timer resets forever and the
    # sentry never oscillates back. Once dwelt at the effective post, flip the
    # shift so NEXT frame's effective post is the opposite vantage and the bot
    # walks there: a continuous shoot-move cycle across the crossing it owns.
    proc effPost(base: Vec, shift: float, home: float): Vec =
      if bot.role == Overwatch:
        vec(base.x, clamp(base.y + shift, LaneTop, LaneBottom))
      else:
        vec(base.x - home * abs(shift) * 0.5,
            clamp(base.y + shift, LaneTop, LaneBottom))
    let base = target
    let cur = effPost(base, bot.sentryShift, homeSign(bot.team))
    if dist(me, cur) >= 20.0:
      bot.sentrySince = bot.tick              # still travelling to the vantage
    elif bot.tick - bot.sentrySince >= SentryDwellTicks:
      bot.sentrySince = bot.tick
      bot.sentryShift =
        (if bot.sentryShift >= 0.0: -SentryShiftPx else: SentryShiftPx)
    let shifted = effPost(base, bot.sentryShift, homeSign(bot.team))
    if bot.gridRayClear(me, shifted): target = shifted

  # POST-WIPE CONSOLIDATION (regroupPush): the v14 squander fix. A mid that has
  # pushed deep into the enemy half ALONE, into an area cleared of live enemies
  # (the post-wipe vacuum), with support still inbound behind it, HOLDS a shallow
  # midfield rally until the trio re-forms, then releases and pushes deep TOGETHER
  # — instead of feeding the ~72t respawn wave one body at a time. Purely a timing
  # gate on the attacker's movement target: the combat block below still fires at
  # anything lined up while we rally (a free trade out is fine), it never touches
  # carry/defense states, and it releases the instant the wave is grouped, so
  # full-depth aggression (which correlates with WINNING) is preserved. Restricted
  # to the mid trio — flankers keep their wide independent runs.
  when defined(rgprobe):
    if bot.tune.regroupPush and bot.role in {MidTop, MidBottom, MidGuard}:
      inc rgMid
      if not iCarry and not mateCarry: inc rgNoCarry
      if not iCarry and not mateCarry and not ownStolen: inc rgNoStolen
  if bot.tune.regroupPush and not iCarry and not mateCarry and not ownStolen and
      not retreating and not pushOut and
      bot.role in {MidTop, MidBottom, MidGuard} and
      dist(me, stealTarget) >= PocketRushRange:
    # Depth INTO the enemy half: 0 at center, grows toward the enemy pedestal.
    let depth = -homeSign(bot.team) * (me.x - float(CenterX))
    var packMates = 0        # fresh mates grouped near me RIGHT NOW
    var joinMates = 0        # fresh mates homeward of me — support genuinely inbound
    for t in bot.mates:
      if bot.tick - t.lastSeen > LocalFreshTicks: continue
      if dist(t.pos, me) <= RegroupPushRadius: inc packMates
      if homeSign(bot.team) * (t.pos.x - me.x) > 20.0: inc joinMates
    var enemyNear = false
    for t in bot.enemies:
      if bot.tick - t.lastSeen <= LocalFreshTicks and
          dist(t.pos, me) <= RegroupPushClearRange:
        enemyNear = true
        break
    let grouped = packMates >= RegroupPushPack
    if grouped:
      # The wave is together — commit the joint push (hysteresis: don't re-hold
      # the rally as the pack naturally spreads out over the next stretch).
      bot.regroupReleaseUntil = bot.tick + RegroupPushCommit
    # ⭐ COMMS COUPLING (2026-07-22): a mate who SAW a post-wipe vacuum called it
    # ("P<wipe>"); a trailing mid that heard the codeword but has NOT itself
    # over-extended still converges on the rally so the wave re-forms across fog —
    # the one thing the shared clock / globally-legible flag state can NOT sync (a
    # local vacuum is invisible to a mate a lane away). This is the ONLY behavior
    # the bus buys that isn't already consensus without it (flip = shared clock,
    # peel = empty-pedestal legible). Gated behind commsPlay + a FRESH heard wipe;
    # arms only inside the squander band (already committed forward of the rally
    # line) so it never pulls a home-side mid up, and it still passes through EVERY
    # downstream guard below (vacuum, not-grouped, support-inbound) — it lowers the
    # depth trigger for an informed mid, it does not bypass the squander signature.
    let heardWipe = bot.tune.commsPlay and bot.heardPlay == RpWipe and
      bot.tick - bot.heardPlayTick <= CommsPlayTtl
    # Arm the hold when over-extended past the trigger depth, OR still ahead of the
    # rally line inside a live hold window (sticky — pulling back below the trigger
    # keeps holding at the shallower rally rather than stuttering across the line),
    # OR a fresh heard wipe + already forward of the rally line (the comms converge).
    let armed = depth >= RegroupPushTrigDepth or
      (bot.tick <= bot.regroupHoldUntil and depth >= RegroupPushRallyDepth) or
      (heardWipe and depth >= RegroupPushRallyDepth)
    when defined(commsprobe):
      if heardWipe and depth >= RegroupPushRallyDepth and depth < RegroupPushTrigDepth and
          not enemyNear and not grouped and joinMates >= 1 and
          bot.tick > bot.regroupReleaseUntil:
        inc csWipeArm
    when defined(rgprobe):
      inc rgReach
      if armed: inc rgDeep
      if armed and not enemyNear: inc rgVac
      if armed and not enemyNear and not grouped: inc rgLone
      if armed and not enemyNear and not grouped and joinMates >= 1: inc rgJoin
    # Hold ONLY in the full squander signature: over-extended, area cleared
    # (vacuum), not yet grouped, support inbound to actually wait for, and not
    # inside a committed joint push. A lone last survivor (joinMates == 0) never
    # holds — nobody is coming, so it presses the grab.
    if armed and not enemyNear and not grouped and joinMates >= 1 and
        bot.tick > bot.regroupReleaseUntil:
      bot.regroupHoldUntil = bot.tick + RegroupPushCommit
      # Rally line: a shallow point just inside the enemy half at our current
      # height (the lane we advanced up), so strung-out mates converge on it.
      let rallyX = float(CenterX) - homeSign(bot.team) * RegroupPushRallyDepth
      target = vec(rallyX, me.y)
      when defined(rgprobe):
        inc rgFireCount

  # ⭐ holdLine (2026-07-22, the h006 line-defense finding): the #1 policy forms a
  # standing line in its OWN half and lets us over-push into a converging kill — we
  # die 39% in the enemy half vs h006's ~14%, and that over-extension is what
  # manufactures its clean hits/kill. holdLine is regroupPush's sibling with the
  # OPPOSITE trigger: regroupPush rallies in a post-wipe VACUUM (no fresh enemy);
  # holdLine rallies when a fresh enemy LINE is to our front AND we've over-extended
  # AND we lack LOCAL fire-superiority — so the mid re-forms a shallow wave inside the
  # enemy half and hits the line together instead of trickling one body at a time into
  # the farm. Movement-target ONLY (combat below still trades out anything lined up);
  # never touches carry/defense states; releases the instant we have the local edge or
  # a grouped wave; a lone last body (no inbound support) never holds — it presses.
  # LOCAL fire proxies only (fogged teammates); never a global headcount (falsified
  # forceBalance). Runs AFTER regroupPush so a live vacuum-rally wins the target.
  when defined(hlprobe):
    if bot.tune.holdLine and bot.role in {MidTop, MidBottom, MidGuard}:
      inc hlMid
  if bot.tune.holdLine and not iCarry and not mateCarry and not ownStolen and
      not retreating and not pushOut and
      bot.role in {MidTop, MidBottom, MidGuard} and
      dist(me, stealTarget) >= PocketRushRange:
    when defined(hlprobe):
      inc hlReach
    # Depth INTO the enemy half: 0 at center, grows toward the enemy pedestal.
    let depth = -homeSign(bot.team) * (me.x - float(CenterX))
    var freshMatesNear = 0   # fresh mates within our local pack radius RIGHT NOW
    var joinMates = 0        # fresh mates homeward of me — support genuinely inbound
    for t in bot.mates:
      if bot.tick - t.lastSeen > LocalFreshTicks: continue
      if dist(t.pos, me) <= HoldLineMateRange: inc freshMatesNear
      if homeSign(bot.team) * (t.pos.x - me.x) > 20.0: inc joinMates
    var freshEnemyNear = 0   # fresh enemy guns to our front = the standing line
    for t in bot.enemies:
      if bot.tick - t.lastSeen <= LocalFreshTicks and
          dist(t.pos, me) <= HoldLineEnemyRange:
        inc freshEnemyNear
    let line = freshEnemyNear >= 1
    # ⭐ COMMS COUPLING (anti-h006): a mate a lane away CALLED a line ("P<line>") that
    # this bot can't see. A forward, strung-out, supported mid converges on the rally
    # so the wave masses up instead of trickling its own push into the farm — the
    # cross-fog convergence holdLine lacked (the WIPE coupling's sibling for a LINE).
    # Bounded: fires only forward of the rally line, with support inbound, decaying
    # after CommsPlayTtl — it never pulls a home-side mid up or holds on empty ground.
    let heardLine = bot.tune.commsPlay and bot.heardPlay == RpLine and
      bot.tick - bot.heardPlayTick <= CommsPlayTtl
    # Local fire-superiority: we release (and commit) once fresh mates near us match or
    # beat the fresh enemy guns to our front, OR a full pack has grouped up. ⚠️ superior
    # is gated on `line`: with no enemy to our front, (mates - 0) >= 0 is trivially true
    # during the empty-space APPROACH — arming the release window every frame so it is
    # still live when we finally reach the line and the first hold never fires (the
    # TURTLE probe caught exactly this: outgun 1385 -> support 311 -> FIRED 0). We only
    # "have superiority" when there is actually a line to be superior OVER.
    let superior = line and (freshMatesNear - freshEnemyNear) >= HoldLineSuperiority
    let grouped = freshMatesNear >= HoldLinePack
    # Arm the release/commit window ONLY when a line is present (superior already gates
    # on line; grouped must too — a grouped APPROACH with no line to our front must not
    # pre-arm the window, or the first hold at the line is suppressed for HoldLineCommit).
    if superior or (line and grouped):
      bot.holdLineReleaseUntil = bot.tick + HoldLineCommit
    # Arm the hold when over-extended past the trigger depth, OR still ahead of the
    # rally line inside a live hold window (sticky — mirrors regroupPush's hysteresis).
    let armed = depth >= HoldLineTrigDepth or
      (bot.tick <= bot.holdLineHoldUntil and depth >= HoldLineRallyDepth)
    let outgunned = (freshMatesNear - freshEnemyNear) < HoldLineSuperiority
    when defined(hlprobe):
      if armed: inc hlDeep
      if armed and line: inc hlLine
      if armed and line and outgunned: inc hlOutgun
      if armed and line and outgunned and joinMates >= 1: inc hlLone
    # Hold ONLY in the full over-extend signature: over-extended, a fresh line to our
    # front (locally seen OR a fresh heard call), outgunned locally, support inbound to
    # actually wait for, and not inside a committed joint push. A lone last body
    # (joinMates == 0) never holds — nobody is coming, so it presses the objective
    # (identical carve-out to regroupPush). The heardLine arm requires forward depth so
    # a called line converges the wave without needing this bot's own line sighting.
    if armed and (line or heardLine) and (outgunned or heardLine) and joinMates >= 1 and
        bot.tick > bot.holdLineReleaseUntil:
      bot.holdLineHoldUntil = bot.tick + HoldLineCommit
      # Rally line: a shallow point just inside the enemy half at our current height
      # (the lane we advanced up), so the strung-out wave converges before the line.
      let rallyX = float(CenterX) - homeSign(bot.team) * HoldLineRallyDepth
      target = vec(rallyX, me.y)
      when defined(commsprobe):
        if heardLine and not line: inc csLineArm  # cross-fog line convergence fired
      when defined(hlprobe):
        inc hlFireCount

  # The mid trio plays for the flag, not for position: pickup races and
  # carrier chases are lost to peek/duck detours, so mids keep moving and
  # shoot on the move whenever a mate is not already carrying.
  let rushing = not iCarry and not mateCarry and
    bot.role in {MidTop, MidBottom, MidGuard}
  # The pocket endgame: duelling at the pocket edge is an infinite respawn
  # grinder (respawners appear spawn-protected AT the pedestal), so the
  # attacker CLOSEST to the pedestal commits to the touch, unarmed and
  # undistracted, while the rest of the wave keeps its guns up to cover the
  # grab — even a suicide grab forces the enemy back onto defense, and a
  # lucky one starts the capture run.
  var nearestMateToSteal = 1e18
  for t in bot.mates:
    if bot.tick - t.lastSeen > 48:
      continue
    nearestMateToSteal = min(nearestMateToSteal, dist(t.pos, stealTarget))
  # `not banking` (plan #13 §1.5): a 1-hp attacker outside GrabCommitRing is a
  # fed life, not an attacker — steal pursuit is overridden while banking (the
  # imminent-grab exemption already keeps a bot inside the ring out of BANK).
  let wantPocketRush = not iCarry and not mateCarry and not banking and
    bot.role in {MidTop, MidBottom, MidGuard, FlankTop, FlankBottom} and
    dist(me, stealTarget) < PocketRushRange and
    dist(me, stealTarget) < nearestMateToSteal + 8.0
  # ⭐⭐ SMART GRAB (2026-07-24, THE dive-death fix — Maxwell's adaptive-Captain directive).
  # The OLD grabTiming/grabGate were HARD-THRESHOLD gates with a fatal carve-out: a solo,
  # outgunned body with no inbound mate "dives NOW" (theory: a suicide grab forces the enemy
  # onto defense). FALSIFIED in play — >half our deaths are that dive doing ZERO damage; a
  # dead body forces nothing. And "outgunned unless >=1 inbound mate" is wrong anyway — one
  # mate can't beat a full defending team. The fix is ADAPTIVE via the Captain brain: commit
  # the disarmed touch ONLY when we genuinely have the advantage the Captain already reads;
  # otherwise HOLD at a firing standoff, gun UP, and SUPPRESS the clustered pocket from range
  # (the map-wide gun; a cluster is a focus-fire gift) as a TEAM, until we're up. No lone
  # suicide dive, ever. OFFENSIVE by construction: we arrive shooting + commit the kill.
  var holdGrab = false
  if bot.tune.smartGrab and wantPocketRush and not pushOut and
      dist(me, stealTarget) > GrabCommitRing:
    # The pocket defense: fresh enemy guns clustered on the pedestal.
    var defenders = 0
    for t in bot.enemies:
      if bot.tick - t.lastSeen <= LocalFreshTicks and
          dist(t.pos, stealTarget) <= GrabStackRange:
        inc defenders
    # Cover in place: a fresh mate AT the pocket with us (already trading, so the touch is
    # covered) releases the hold — that's a genuine team push, not a solo dive.
    var coverMates = 0
    for t in bot.mates:
      if bot.tick - t.lastSeen > GrabMateFreshTicks: continue
      if dist(t.pos, me) <= GrabCoverRange: inc coverMates
    # ADVANTAGE to commit the touch = the Captain's shared read, NOT a fixed mate count:
    #   • pickEdge      — a real LOCAL numbers edge near us (freshM>freshE) — we're up, push.
    #   • PhForce       — the Captain's deliberate grouped all-in before the -1 timeout.
    #   • cover in place — a mate is already at the pocket trading (the push has arrived).
    # ownStolen is handled by its own recapture branches; a defended pocket with NONE of
    # these = HOLD and suppress from standoff. An UNDEFENDED pocket always commits (fast
    # uncontested touch). This is the chess-not-checkers pocket: the Captain calls the push.
    let haveAdvantage = pickEdge or (bot.tune.planLayer and botPhase == PhForce) or
      coverMates >= 1
    holdGrab = defenders >= GrabStackDefenders and not haveAdvantage
    when defined(sgprobe):
      inc sgWant
      if defenders >= GrabStackDefenders: inc sgDefended
      if defenders >= GrabStackDefenders and not haveAdvantage: inc sgHold
      if defenders >= GrabStackDefenders and haveAdvantage: inc sgCommit

  if holdGrab:
    # Hold the gun up at a standoff ring off the pedestal (outside the defenders'
    # tightest cover) and suppress from there instead of diving unarmed.
    target = stealTarget + norm(me - stealTarget) * GrabHoldStandoff
  let pocketRush = wantPocketRush and not holdGrab
  # ⭐ ARMED RUSH (the dive-death fix): is the pocket DEFENDED by a fresh, killable gun?
  # pocketRush's disarm (maxEngage=0) assumed pedestal respawners were spawn-protected
  # (unkillable) — GV20+ removed that, so a defended dive is a free death. When defended,
  # keep the gun UP (below) so we shoot the way in + the duck/dodge branches re-enable.
  # ⭐⭐ RANGE FLOOR (2026-07-29, the grab-conversion fix): armedRush had NO distance floor
  # while its sibling holdGrab is floored at `> GrabCommitRing` (4435). So holdGrab correctly
  # refuses to ENTER a stacked pocket, but once a body was already inside the ring armedRush
  # re-armed it — gun up, duck/dodge branches back on — at 5-39px from a heart whose pickup
  # radius is 12px. That is the measured close-range failure: 20 GV26 episodes with a bot
  # beside the heart never taking it, and only 41 of our shots (0.3%) fired inside 60px of it.
  # Arming to shoot is right on the APPROACH and wrong at arm's length: two steps from the
  # heart the touch ends the episode, and no amount of covering fire does.
  var pocketDefended = false
  if bot.tune.armedRush and pocketRush and
      not (bot.tune.touchCommit and dist(me, stealTarget) <= GrabCommitRing):
    for t in bot.enemies:
      if bot.tick - t.lastSeen <= FreshShotTicks and
          dist(t.pos, stealTarget) <= GrabStackRange:
        pocketDefended = true
        break
  # A pocketRush stays DISARMED (fast unopposed touch) only when NOT defended; a defended
  # pocket keeps the gun up (armedPocket) so every `not pocketRush` combat branch re-enables.
  let armedPocket = pocketRush and pocketDefended
  # disarmedRush = the ONLY state that suppresses combat (gun off, no duck/dodge): a pocket
  # rush that is NOT armed (uncontested touch). An armedPocket rush fights its way in, so the
  # combat branches below key on disarmedRush, not raw pocketRush.
  let disarmedRush = pocketRush and not armedPocket
  # ⭐⭐ THE TOUCH LATCH: inside GrabCommitRing the heart is ~2 steps away and the body is
  # already inside the defenders' fire. Every alternative from here is strictly worse than
  # closing: a grenade lob, a duel, or a duck all leave us in the same fire WITHOUT the heart,
  # and a steal is worth the episode (26.4% -> 66.7%). So once inside the ring, the touch
  # OUTRANKS everything. Note this deliberately ignores holdGrab/pocketDefended: holdGrab
  # already declines to ENTER the ring when the pocket is stacked and we have no advantage —
  # that is the approach decision and it stays. This is only about a body that is already
  # there, where retreating costs the same exposure as finishing.
  let touchLatch = bot.tune.touchCommit and not iCarry and not mateCarry and
    bot.role in {MidTop, MidBottom, MidGuard, FlankTop, FlankBottom} and
    dist(me, stealTarget) <= GrabCommitRing
  when defined(tcprobe):
    if touchLatch: inc tcLatch
  if touchLatch:
    # Drive straight onto the pedestal and let the act-chain guards below stand down.
    target = stealTarget
  when defined(prprobe):
    if pocketRush: inc prRush
    if armedPocket: inc prArmed

  # Combat: the nearest fresh track with a clear pixel ray AND a mate-free
  # fire cone is the engage target; the nearest fresh-but-wall-blocked track
  # is the peek candidate. The map-wide gun engages fresh tracks far beyond
  # the view, so chases keep killing after the target leaves the window —
  # but objective play caps the range: the carrier only fights point-blank,
  # rushers racing for the steal and escorts guarding a run only fight what
  # is actually in the way, instead of frag-chasing across the map.
  if iCarry and not bot.wasCarrying:
    bot.grabPos = me
  bot.wasCarrying = iCarry
  var maxEngage =
    if disarmedRush: 0.0         # ONLY an uncontested pocket touch disarms; a DEFENDED
                                 # pocket keeps the gun up (armedPocket) and fights its way in
    elif iCarry and bot.tune.carrierSprint:
      # ⭐ FIGHT OFF THE X (2026-08-04): live-replay carrier census, 10 carries —
      # median progress toward home at span end was MINUS 2%, 7 of 10 died at
      # <30%, half GRABBED at 1-2 hp with up to 3 defenders inside 300px. Our
      # carriers do not die on the run home; they die AT THE PEDESTAL — which
      # GV25 made the enemy's own respawn zone — holding a gun the old rule
      # disarmed at the instant of the grab. The disarmed sprint stays proven
      # for the RUN; the first 260px after the snatch is a breakout, not a
      # run. Point-blank gun until clear, then sprint.
      (if dist(me, bot.grabPos) < FightOutRadius: bot.tune.carrierFireRange
       else: 0.0)                # ⭐⭐ past the ring: carrier never fights:
      # the diagnosis showed carriers survive ~110t but travel ~4% of the run —
      # PINNED firing at the invulnerable spawn-protected respawner (wasted) while
      # advancing into the nest. Engage 0 drops the combat branch so the carrier
      # pure-navigates home at full speed, turret free (still nav-steered).
    elif iCarry: bot.tune.carrierFireRange
    elif rushing: bot.tune.rushEngageRange
    elif mateCarry: bot.tune.escortEngageRange
    else: bot.tune.fireRange
  # ⭐⭐ PLAN-LAYER COMBAT TEETH: the phase drives ENGAGEMENT, not just movement, so a
  # called play actually WINS its fight instead of gently repositioning. PhOpen/PhPress
  # widen the attacker's engage range so the grouped opening clash + the man-advantage
  # window are fought to a kill (we lose the opening 14-6 by NOT committing the fire);
  # PhEscort lets a free gun near the carrier hunt the carrier's chasers to the fireRange
  # (kill the threat — body-block is void), instead of only sliding to its lane. Never
  # overrides the pocketRush/carrier gun-discipline above (those stay 0).
  if bot.tune.planLayer and maxEngage > 0.0 and not iCarry:
    case botPhase
    of PhOpen, PhPress:
      if rushing or bot.role in {FlankTop, FlankBottom}:
        maxEngage = max(maxEngage, bot.tune.fireRange)   # commit the clash to a kill
    of PhEscort:
      if mateCarry and dist(me, mateCarryPos) <= EscortCollapseRange:
        maxEngage = max(maxEngage, bot.tune.fireRange)   # hunt the carrier's chasers
    of PhDefend:
      # v26: RECAPTURE has teeth — every seat presses the kill to delete the thief/escort
      # (body-block is void, so recapture = KILL). The marquee "full-team collapse" phase
      # was toothless (engage unchanged); now the hunters widen to map-wide to finish it.
      maxEngage = max(maxEngage, bot.tune.fireRange)
    of PhForce:
      # v26: the late all-in FIGHTS to a kill — on a wipe-economy engine the force window
      # must remove enemy guns, not gently reposition. Every seat widens to fireRange.
      maxEngage = max(maxEngage, bot.tune.fireRange)
    else: discard
  # Focus-fire intel: which remembered enemies sit on a visible mate's aim
  # line right now. A mate's rendered aim dots are an absolute readback of
  # where it is about to shoot; piling our shot onto the same target converts
  # two 1-damage hits into a kill instead of two wounded runners.
  var mateTargeted = newSeq[bool](bot.enemies.len)
  var mateGuns = newSeq[int](bot.enemies.len)   # satCap: HOW MANY mate aim lines
                                                # cover each enemy, not just any
  var supportRays: seq[tuple[origin, dir: Vec, length: float]]
                                                # noMask: live mate gun-lines
                                                # (an up gun with a fresh target
                                                # on its bearing) the NAVIGATE
                                                # branch must not walk across
  for m in bot.mates:
    if bot.tick - m.lastSeen > 2:
      continue                          # dots exist only while the mate is visible
    when defined(scprobe):
      if bot.tune.satCap: inc scMateFresh
    var mAim = client.mateAimBrads(m.pos, me, myColor)
    if mAim < 0 and bot.tune.aimRotRead:
      mAim = m.aimBrads                 # v9: the dots are retired; the track's
                                        # bearing comes from the mate's soldier
                                        # rotation id (actorsFor rotRead)
    if mAim < 0:
      continue
    when defined(scprobe):
      if bot.tune.satCap: inc scMateRead
    let dir = bradsDir(mAim)
    var rayTargetD = -1.0               # noMask: nearest fresh enemy ON this ray
    for i in 0 ..< bot.enemies.len:
      if bot.tick - bot.enemies[i].lastSeen > FreshShotTicks:
        continue
      let rel = bot.enemies[i].pos - m.pos
      let along = dot(rel, dir)
      if along <= 0.0 or along > MateAimRayLen:
        continue
      if abs(cross(rel, dir)) <= MateAimHitSlack:
        mateTargeted[i] = true
        inc mateGuns[i]
        if rayTargetD < 0.0 or along < rayTargetD:
          rayTargetD = along
        when defined(scprobe):
          if bot.tune.satCap: inc scRayHit
    # noMask: a mate line only counts as a SUPPORT ray when the gun is UP (no
    # muzzle bloom = off cooldown) and a fresh target sits on the bearing —
    # that is the shot the mover must not walk into. The bullet stops at the
    # target, so the corridor ends there.
    if bot.tune.noMask and rayTargetD > 0.0 and
        not client.mateGunDown(m.pos):
      supportRays.add((origin: m.pos, dir: dir, length: rayTargetD))

  var
    engage = -1
    engageD = maxEngage
    engagePrio = maxEngage
    aim: Vec
    engageBody: Vec                     # the engage target's REAL last-seen pos
    blockedAim: Vec
    blockedBody: Vec                    # the blocked target's REAL last-seen pos,
                                        # for the corner-pre-aim emergence search.
    haveBlocked = false
    blockedD = maxEngage
    anySaturated = false                # satCap: some in-range candidate was saturated
    engageSat = false                   # satCap: the FINAL pick was saturated
  for i in 0 ..< bot.enemies.len:
    let t = bot.enemies[i]
    if bot.tick - t.lastSeen > bot.tune.freshShotTicks:
      continue
    # ⭐ RANGE-SCALED LEAD (2026-08-04, the CQB accuracy crater). Field census,
    # 24 real Default episodes: our hit% by range is 36.7 / 60.4 / 68.7 / 56.4
    # across 0-150 / 150-300 / 300-500 / 500-700px vs the field's 65.6 / 65.6 /
    # 61.7 / 44.2 — we WIN every band past 300px and lose 0-150 by 29 points,
    # where 43% of our shots are fired. The fixed ~16px lead is 2 degrees at
    # 400px and ~12 at 75px — at point-blank it aims off the body edge of a
    # jinking target. Scale the lead in below 300px (full lead above; at 60px
    # ~20%). [[REF-realbody]] refuted DELETING the lead globally (undershot at
    # range); the range-scaled form keeps the ranged lead that verdict protects.
    let
      rawRange = dist(t.pos, me)
      leadScale = clamp(rawRange / 300.0, 0.15, 1.0)
      predicted = t.pos + t.vel *
        (float(bot.tick - t.lastSeen) + bot.tune.leadTicks * leadScale)
    let d = dist(predicted, me)
    if d >= maxEngage:
      continue
    # Target priority: distance plus the turret swing needed to lay on the
    # target (the traverse is slow, so a target near the current aim line
    # dies sooner than a nearer one behind us), discounted for wounded
    # targets (a 1-hp enemy dies to one shot — finish it before it resets on
    # respawn) and for targets a visible mate is already lined up on (focus
    # fire). The discounts are tiebreaks between comparably-engageable
    # targets, deliberately smaller than a real positional difference.
    var prio = d +
      float(abs(bradsErr(bradsOf(predicted - me), bot.estAim))) * TraversePxPerBrad
    # satCap DISTRIBUTED FIRE: enough guns to kill is sufficient. A 1-hp enemy
    # needs one lined mate gun, anything else two (a pair of 1-damage hitscan
    # guns finishes a 3-hp target across their cycles). ⭐ A SHIELDED enemy is a
    # 6-hp tank (the pip bar lies "3/3"), so it takes far more sustained fire —
    # never call it saturated at two guns or a free gun peels off and leaves the
    # tank alive. Past the threshold this enemy is SATURATED: a further free gun
    # flips its focus credit into a debit so it spreads to an uncovered live enemy
    # — the priority form keeps it a nudge (a lone saturated target in range is
    # still engaged), and CommitBonus (400 > 220) still holds a gun in the kill.
    let satNeed = (if t.hasShield: 4 elif t.hp == 1: 1 else: 2)
    # ⭐ FINISH THE KILL (Bug 1): is THIS candidate the target we're already committed to?
    # A committed target that we're one hit from killing (or whose gun is on us) must NOT be
    # abandoned by satCap's spread-debit — satCap redirects a FREE gun, never the one closing
    # a kill. Compute the lock match here so the satCap + danger terms below can protect it.
    let isLocked = bot.tune.commit and bot.tick <= bot.lockUntil and
      dist(t.pos, bot.lockPos) <= LockMatchDist
    let stick = bot.tune.stickyCommit and isLocked
    let saturated = bot.tune.satCap and mateGuns[i] >= satNeed and not stick
    when defined(scprobe):
      if bot.tune.satCap:
        if mateGuns[i] >= 1: inc scCov1
        if mateGuns[i] >= 2: inc scCov2
        if t.hp == 1: inc scHp1
    # ⭐ FINISH THE KILL (Bug 1, v2): accumulate every DISCRETIONARY pull (hpFocus, focus-
    # fire, danger, counterArc) into `pull` rather than subtracting each straight into prio.
    # For a NON-committed challenger the TOTAL pull is then capped below commitBonus, so no
    # stack of credits (danger 340 + hpFocus 120 + focus×3 135 = 595 uncapped!) can ever
    # out-pull the enemy we're already closing a kill on. The committed target keeps its full
    # uncapped pull (it IS the finish). Fixes the audit's mid-fight switch when the locked
    # target's gun momentarily slews off us (danger→0) and a fresh challenger's hp+focus wins.
    var pull = 0.0
    if saturated:
      anySaturated = true
      prio += SatCapPenalty
    else:
      if t.hp in 1 ..< MaxHp:
        pull += float(MaxHp - t.hp) * HpFocusBonus
      if mateTargeted[i]:
        # ⭐⭐ PLAN-LAYER FOCUS FIRE: in the opening clash / man-advantage window, the
        # wave must CONCENTRATE fire to remove enemy guns fast and win the trade (the
        # cqc-lens "focus-fire removes a gun" — we lose the opening 14-6 by spreading).
        # Amplify the pile-on bonus during PhOpen/PhPress so mates share a target on
        # the same beat; normal tiebreak otherwise. satCap still caps over-saturation.
        let focus =
          if bot.tune.planLayer and botPhase in {PhOpen, PhPress}: FocusFireBonus * 3.0
          else: FocusFireBonus
        pull += focus
    # Greatest-threat-first: an enemy FACING us can shoot this instant, so it
    # is more dangerous than an equidistant one looking away (gated OFF).
    let facingMe =
      (t.facingRight and t.pos.x < me.x) or
      (not t.facingRight and t.pos.x > me.x)
    # AIM-DOT THREAT (#19): the coarse facingRight test only knows which half-
    # plane the enemy faces — it flags a gun pointed 89° off us as "facing." When
    # aimThreat is on and we read the enemy's aim-dot line, replace that with a
    # real gun-on-me cone: aimScale is 1.0 when the gun is dead-on us, tapers to
    # a floor at the cone edge, and 0 when the gun points elsewhere (NOT a threat
    # this instant). Falls back to the half-plane (aimScale 1/0) when the dots are
    # unreadable, so we never lose the old signal.
    var aimScale = (if facingMe: 1.0 else: 0.0)
    if bot.tune.aimThreat and t.aimBrads >= 0:
      let aimErr = abs(bradsErr(t.aimBrads, bradsOf(me - t.pos)))
      # ⭐⭐ FUZZ-TOLERANT THREAT READ (2026-07-29). GV24 made every enemy's rendered gun
      # rotation wrong by up to ±AimFuzzBrads, so this measurement has a known error bar and
      # must be treated as evidence, not fact. Two changes, both about the ERROR BAR:
      #   • widen the cone by the fuzz, so a gun that is truly on us is not read as aside
      #     (the miss direction: we ignore a lethal threat — measured 1.1% of reads, but its
      #     cost is a death);
      #   • replace the HARD ZERO with AimFuzzFloor. "Off cone" now means "probably aside",
      #     not "harmless" — the old 0.0 dismissed a dead-on gun outright whenever the roll
      #     went against us. The false-alarm direction (~13.5% of reads) is self-limiting
      #     because the taper already scales it down; the hard zero was not.
      # Deliberately NOT tightened instead: the read cannot be made exact by any label (the
      # side bit is 1 bit and is itself fuzz-flipped), so the only honest response is to stop
      # gating hard on it. Our OWN aim is exact again (GV26) and is untouched by this.
      if aimErr <= AimOnConeBrads + AimFuzzBrads:
        let tight = clamp(
          float(AimOnConeBrads + AimFuzzBrads - aimErr) /
            float(AimOnConeBrads + AimFuzzBrads - AimDeadOnBrads), 0.0, 1.0)
        aimScale = max(AimFuzzFloor, 0.4 + 0.6 * tight)
      else:
        aimScale = AimFuzzFloor          # probably aside — but a fuzzed read is not proof
    if bot.tune.dangerScore:
      # #1 GREATEST-THREAT-FIRST (richer danger score, supersedes the flat
      # facing tiebreak): a gun that is BOTH pointed at us AND close can kill us
      # THIS second — that is the target to neutralize first, ahead of a nearer
      # one looking away. Scale the facing credit UP as range closes (a facing
      # enemy at point-blank is lethal now; one at 600px is a rumor), and stack
      # an extra increment when it is also wounded (facing + one hit from death
      # = the cheapest kill that also removes the most danger). Credit is capped
      # so it stays a strong PRIORITY nudge, never a reason to fire past cover.
      if aimScale > 0.0:
        let closeFrac = clamp(1.0 - d / DangerFalloff, 0.0, 1.0)
        var danger = (AimThreatBonus + DangerCloseBonus * closeFrac) * aimScale
        if t.hp in 1 ..< MaxHp:
          danger += DangerWoundedBonus * aimScale
        pull += danger                     # capped as part of the TOTAL pull below
    elif bot.tune.threatFacingBonus:
      if facingMe:
        pull += AimThreatBonus
    # counterArc (Play C): an enemy holding a plasma arc has NO gun for the rest
    # of its life and a cone that only reaches 136px. Beyond PlasmaArcReachPx +
    # buffer it is a defenseless high-value target — kill it to delete the enemy's
    # whole AoE play. Credit (240) beats a generic/wounded enemy but sits below
    # CommitBonus(400), so it never drops a target we're one hit from finishing.
    # Retarget-only: no movement bias here (that's the separate arcStandoff lever).
    # Inside the cone band we add nothing — the close+aim danger terms already top
    # it, and stacking credit there risks thrashing.
    when defined(caprobe):
      if bot.tune.counterArc: inc caSeen
    if bot.tune.counterArc and t.hasArc and
        d > PlasmaArcReachPx + CounterArcReachBuffer:
      pull += CounterArcBonus
      when defined(caprobe): inc caBump
    # ⭐ FINISH THE KILL: cap the TOTAL discretionary pull of a NON-committed challenger below
    # commitBonus (by the StickyDangerCap margin), so no stack of hp+focus+danger+arc credit can
    # out-pull the kill we're committed to. The committed target's pull is uncapped (it's the one
    # we finish). Off (stickyCommit false) => behaves exactly as before (no cap), shipped-identical.
    if bot.tune.stickyCommit and not isLocked:
      pull = min(pull, bot.tune.commitBonus - StickyDangerCap)
    prio -= pull
    # Target commitment: heavily favour the enemy we are already engaged with
    # (matched by its last-known position) so three shots land on ONE target
    # and kill it, rather than one shot each spread across many wounded ones.
    if isLocked:
      prio -= bot.tune.commitBonus
    if client.pixelRayClear(me, predicted):
      if bot.friendlyBlocked(me, predicted, d):
        continue                        # prefer a target with an empty corridor
      if engage < 0 or prio < engagePrio:
        engagePrio = prio
        engageD = d
        engage = i
        aim = predicted
        engageBody = t.pos
        engageSat = saturated
    elif d < blockedD:
      blockedD = d
      blockedAim = predicted
      blockedBody = t.pos
      haveBlocked = true

  when defined(scprobe):
    if bot.tune.satCap and engage >= 0:
      inc scEngaged
      if anySaturated:
        inc scSatSeen
        if engageSat: inc scDogpile else: inc scRedirect

  # Refresh the commitment lock onto whichever target we chose this frame, so
  # next frame's selection is drawn back to it until it dies or fogs out.
  if bot.tune.commit and engage >= 0:
    bot.lockPos = bot.enemies[engage].pos
    bot.lockHp = bot.enemies[engage].hp
    bot.lockUntil = bot.tick + LockTtl

  # TARGET-LOCK: pin the turret on a committed enemy's bearing so the vision
  # cone (which rides the aim) keeps them lit and the gun stays pre-lined.
  # Refresh onto the engage target when we have one; otherwise hold onto the
  # freshest engageable-range enemy so a brief fog-out does not throw the aim
  # back to the movement lane.
  if bot.tune.aimLock:
    if engage >= 0:
      bot.aimLockPos = bot.enemies[engage].pos
      bot.aimLockUntil = bot.tick + AimHoldTtl
    else:
      # No clear shot this frame: pre-lay the turret on the freshest engageable-
      # range enemy so a brief fog-out doesn't throw the aim back to the move lane.
      # preSlew (v8 "fire first", 2026-07-18): among that SAME engageable-range
      # fresh set, prefer the enemy whose gun is NOT on us — the draw we WIN. We
      # complete our 5-tick windup while its turret is still slewing onto us, so
      # our bullet leaves first (OODA half-beat). This is a fire-TIMING choice
      # inside aimLock's existing on-objective candidate set — NOT the refuted
      # huntSweep (which aims off-objective at ANY remembered enemy regardless of
      # range/objective and trades wins for kills, see failed.md ⛔huntSweep).
      # Requires aimThreat (the enemy aim-dot read) to know whose gun is off us;
      # with no dot readback it falls straight back to nearest, so the shipped
      # behavior is unchanged when preSlew can't actually tell.
      let preSlewOn = bot.tune.preSlew and bot.tune.aimThreat
      var best = -1
      var bestScore = 1e18
      for i in 0 ..< bot.enemies.len:
        if bot.tick - bot.enemies[i].lastSeen > bot.tune.freshShotTicks:
          continue
        let d = dist(bot.enemies[i].pos, me)
        if d >= maxEngage:
          continue
        # Default score = distance (the shipped nearest-pick). With preSlew on
        # AND a readable enemy aim dot, discount an enemy whose gun points AWAY
        # from us: a big off-us aim error is the draw we WIN — pre-lay there so
        # our windup finishes while its turret is still slewing onto us. An
        # unreadable dot keeps offUs=0, so it still competes on pure distance
        # (never dropped) and the pick is identical to shipped when no dot reads.
        var score = d
        if preSlewOn and bot.enemies[i].aimBrads >= 0:
          let offUs = float(abs(bradsErr(bot.enemies[i].aimBrads, bradsOf(me - bot.enemies[i].pos))))
          score = d - offUs * PreSlewOffUsPx
        if best < 0 or score < bestScore:
          bestScore = score
          best = i
      if best >= 0:
        bot.aimLockPos = bot.enemies[best].pos
        bot.aimLockUntil = bot.tick + AimHoldTtl

  # The nearest remembered enemy that could be threatening us right now,
  # used to pick which line to break when ducking through cooldown.
  var
    nearThreat = -1
    nearThreatD = DuckRange
  for i in 0 ..< bot.enemies.len:
    if bot.tick - bot.enemies[i].lastSeen > 30:
      continue
    let d = dist(bot.enemies[i].pos, me)
    if d < nearThreatD:
      nearThreatD = d
      nearThreat = i

  # #6 BUDDY BOUNDING OVERWATCH: never stroll forward across a threatened open
  # lane while MY gun is on cooldown. A gun that is down cannot answer a shot,
  # so advancing into a live enemy line during the reload is how an attacker
  # trades itself for nothing. Instead HOLD at cover for the reload while a
  # covering mate's gun stays up, then bound forward when my gun is live again.
  # This keeps at least one team gun always trained on the crossing. Only for
  # advancing attackers (rushers who cross the open middle), only vs a threat
  # with a clear line to us beyond duck range (the duck branch owns the close
  # ones), and only when a fresh mate is nearby and not deeper in the jaws (so
  # the bound is genuinely covered, not a solo freeze that surrenders tempo).
  var boundHold = false
  var boundThreatPos: Vec
  if bot.tune.boundingOverwatch and not shotReady and
      not iCarry and not mateCarry and not pocketRush and
      bot.role in {MidTop, MidBottom, MidGuard, FlankTop, FlankBottom}:
    var lineThreat = -1
    var lineThreatD = BoundThreatRange
    for i in 0 ..< bot.enemies.len:
      if bot.tick - bot.enemies[i].lastSeen > BoundThreatTtl:
        continue
      let d = dist(bot.enemies[i].pos, me)
      if d <= DuckRange or d >= lineThreatD:
        continue                           # duck branch owns close; ignore far
      if client.pixelRayClear(me, bot.enemies[i].pos):
        lineThreatD = d
        lineThreat = i
    if lineThreat >= 0:
      var covered = false
      for t in bot.mates:
        if bot.tick - t.lastSeen > BoundMateTtl:
          continue
        if dist(t.pos, me) > BoundMateRange:
          continue
        if homeSign(bot.team) * (t.pos.x - me.x) < -BoundMateDepth:
          continue                         # this mate is further into the jaws
        covered = true
        break
      if covered:
        boundHold = true
        boundThreatPos = bot.enemies[lineThreat].pos

  # staggerFire (v8, 2026-07-18): the COMPLEMENT of boundingOverwatch. My gun is
  # UP, but a nearby covering-position mate's gun is DOWN — it just fired (a
  # muzzle bloom sits on it, and the bloom lifetime ShotFxTicks == the 12t reload
  # FireCooldownTicks). If I bound forward across the threatened open lane now, I
  # spend my overwatch and leave the crossing with NO live team gun while my mate
  # reloads — the "whole pair empties on one beat, wiped by a focus-fire wave"
  # death-burst (4.8 vs 3.6 in the H2H decode). So HOLD my up-gun on the crossing
  # to cover the mate's reload; when its gun is back up (bloom gone) I bound.
  # Turns a pair into true alternating bounds — one gun always live on the lane.
  # MOVEMENT ONLY: the engage branch still wins whenever I have a clear shot
  # (boundHold is reached only with no clear engage), so this never throttles my
  # own trigger and cannot regress into the refuted fire-discipline knob.
  if bot.tune.staggerFire and shotReady and not boundHold and
      not iCarry and not mateCarry and not pocketRush and
      bot.role in {MidTop, MidBottom, MidGuard, FlankTop, FlankBottom}:
    var lineThreat = -1
    var lineThreatD = BoundThreatRange
    for i in 0 ..< bot.enemies.len:
      if bot.tick - bot.enemies[i].lastSeen > BoundThreatTtl:
        continue
      let d = dist(bot.enemies[i].pos, me)
      if d <= DuckRange or d >= lineThreatD:
        continue                           # duck branch owns close; ignore far
      if client.pixelRayClear(me, bot.enemies[i].pos):
        lineThreatD = d
        lineThreat = i
    if lineThreat >= 0:
      # A covering-position mate (near, not deeper in the jaws) whose gun is DOWN.
      var mateReloading = false
      for t in bot.mates:
        if bot.tick - t.lastSeen > BoundMateTtl:
          continue
        if dist(t.pos, me) > BoundMateRange:
          continue
        if homeSign(bot.team) * (t.pos.x - me.x) < -BoundMateDepth:
          continue                         # this mate is further into the jaws
        if client.mateGunDown(t.pos):
          mateReloading = true
          break
      if mateReloading:
        boundHold = true
        boundThreatPos = bot.enemies[lineThreat].pos

  # ⭐ SHOUT-REACTION GATE (calloutGate): a heard callout is INTEL, and the
  # track was already banked at intake — even a committed carrier now KNOWS the
  # called enemy. This gate decides only whether the report earns a vision-cone
  # GLANCE, keyed on the bot's task priority (SEAL "priority of work / need-to-
  # know"), now that every commitment state is settled. It NEVER moves the feet:
  # v1 (2026-07-16) mis-classed the pedestal-rushers as "free guns" and let a
  # callout pull 5/8 seats off the heart-rush → grabs collapsed, −12 seat-adj.
  # Maxwell's correction: a rusher advancing on the pedestal is ALREADY occupied
  # by an objective, so it joins the committed tier — and since every seat in
  # this policy always has a job, no report ever earns the feet. Cone-only.
  if bot.tune.calloutGate and bot.calloutTick == bot.tick:
    let
      cp = bot.calloutPos
      selfD = dist(cp, me)
      # Proximity override: a callout inside our own tight bubble, or dead-ahead
      # in a narrow cone on our travel bearing (a threat we are about to walk
      # INTO), earns a glance even from a committed bot — a dead carrier/rusher
      # captures nothing, so surviving the walk-in IS serving the objective.
      inLaneCone = abs(bradsErr(bradsOf(cp - me), bradsOf(target - me))) <=
        CalloutLaneCone
      proximity = selfD <= CalloutSelfBubble or
        (inLaneCone and selfD <= CalloutLaneReach)
    var glance = false
    if engage >= 0 or boundHold:
      # Owns a fresh target / bounding across a covered lane: already committed
      # to a threat we can win — a report never preempts a gun we're winning.
      glance = false
    elif iCarry or pocketRush or rushing:
      # OCCUPIED BY THE OBJECTIVE: the carry, the final grab, and an attacker
      # advancing on the pedestal all outrank a report (Maxwell: rushers "are
      # occupied by a current objective already"; his example — "enemy next to
      # the heart" is worth KNOWING, not worth stopping the grab). Only the
      # survival proximity override earns the glance.
      glance = proximity
    elif mateCarry:
      # Escorting a carrier run: a real job. Glance only at a callout near the
      # carrier we screen or on our own body — need-to-know for the run we cover.
      glance = dist(cp, mateCarryPos) <= CalloutSectorRange or proximity
    elif bot.role in {Overwatch, HomeDefender}:
      # Posted: need-to-know. Glance ONLY at a callout inside the sector this bot
      # guards (the thief/our home for the defender, its post for the sniper) —
      # a defender never leaves its post for a report, but it MUST look when the
      # contact is on the ground it was placed to hold.
      let guardPt =
        if bot.role == HomeDefender:
          (if ownStolen: bot.carrierPos else: ownHome)
        elif bot.postReady: bot.postHold
        else: me
      glance = dist(cp, guardPt) <= CalloutSectorRange or proximity
    else:
      # No commitment matched (e.g. a flanker recalled off its deep lane with no
      # rush active): the only genuinely uncommitted case. Glance if in earshot.
      glance = selfD <= ShoutHeardRange
    if glance:
      bot.orientPos = cp
      bot.orientUntil = bot.tick + ContactWatchTicks

  # Grenades (0.7.0): a lobbed blast that flies over every wall — the counter to
  # cover-campers the hitscan gun can never reach AND the MULTIKILL answer to a
  # clustered enemy line (a line is a cluster; the 52px blast punishes clustering).
  # Carry one when a corner pickup is a short detour away; spend it on a wall-
  # blocked fresh track (value the gun cannot collect) or on the DENSEST cluster in
  # range. ⭐ ANTI-h006: when a standing line is classified or heard, we prioritize
  # the fattest cluster (most fresh enemies inside one blast) over mere nearness —
  # break the line BEFORE the wave punches the gap, instead of trading down its front.
  var carryingNade = false
  for o in client.spriteObjectsWithLabel(LabelGrenadeCarried):
    # The marker floats above-right of its carrier (+8 x, ~-20 y from center).
    if dist(client.mapPos(o), me) <= 30.0:
      carryingNade = true
      break
  # A line is live for us this frame if we classified one OR heard one called.
  let lineLive = localSc == ScLine or
    (bot.tune.commsPlay and bot.heardPlay == RpLine and
     bot.tick - bot.heardPlayTick <= CommsPlayTtl)
  var
    nadeAim = -1
    nadeThrowD = 0.0
  if carryingNade and not iCarry:
    # Score each candidate by CLUSTER SIZE (fresh enemies within one blast of the
    # aim point), tie-broken by nearness. A wall-blocked lone target still qualifies
    # (the gun can't reach it); an open target needs a cluster >=2 (a lone open
    # enemy is the gun's job, not a spent grenade) UNLESS a line is live, where even
    # thinning the front is worth the lob.
    var bestScore = -1
    var bestD = 1e18
    for i in 0 ..< bot.enemies.len:
      let t = bot.enemies[i]
      if bot.tick - t.lastSeen > FreshShotTicks:
        continue
      let p = t.pos + t.vel * float(bot.tick - t.lastSeen)
      let d = dist(p, me)
      if d < NadeMinRange or d > NadeMaxRange:
        continue
      let blocked = not client.pixelRayClear(me, p)
      var cluster = 1                    # the target itself
      for j in 0 ..< bot.enemies.len:
        if j != i and bot.tick - bot.enemies[j].lastSeen <= FreshShotTicks and
            dist(bot.enemies[j].pos, p) <= NadeBlast:
          inc cluster
      # Worth a throw: wall-blocked (gun can't collect), OR a real cluster (>=2),
      # OR a live line where even a single front body thins the wall we must cross.
      if blocked or cluster >= 2 or lineLive:
        # Prefer the fattest cluster; nearer breaks ties (flatter lob, less drift).
        if cluster > bestScore or (cluster == bestScore and d < bestD):
          bestScore = cluster
          bestD = d
          nadeAim = bradsOf(p - me)
          nadeThrowD = d
    when defined(commsprobe):
      if nadeAim >= 0 and (lineLive or bestScore >= 2): inc csNadeLine
  elif not carryingNade and not iCarry and not mateCarry and not pocketRush and
      not banking:
    # Collect a pickup: anyone grabs one within a short detour, and the two
    # flankers own their lane's friendly-side corner spawn — it sits right on
    # their border route, so they arm up on the way out every respawn cycle.
    for o in client.spriteObjectsWithLabel(LabelGrenade):
      let p = client.mapPos(o)
      if p.x < 40.0 or p.y < 40.0 or p.x > float(MapW - 40) or
          p.y > float(MapH - 40):
        continue                     # HUD indicator shares the label
      let laneMatch =
        (bot.role == FlankTop and p.y < float(CenterY) and
         homeSign(bot.team) * (p.x - float(CenterX)) > 0) or
        (bot.role == FlankBottom and p.y > float(CenterY) and
         homeSign(bot.team) * (p.x - float(CenterX)) > 0)
      let reach = if laneMatch: 1e9 else: NadePickupDetour
      if dist(p, me) <= reach:
        when defined(nadeDebug):
          echo "DETOUR to pickup at ", p.x, ",", p.y, " role ", bot.role
        target = p
        break

  # ── SWORD / SHIELD / PLASMA-ARC pickups. The disarm object MOVED with the
  # engine: on GameVersion 15 the SWORD IS GONE (replaced by the plasma arc) and
  # the SHIELD NO LONGER DISARMS (it now grants 6 HP + 3x-slower fire, no gun
  # loss). The ONLY thing that sets canFire=false is holding a PLASMA ARC
  # (canFire = ... and not hasPlasmaArc). Behaviours, each gated:
  #   avoidDisarm — steer around a PLASMA-ARC pickup we're NOT collecting (the
  #     real disarm now; the pure-downside fix, repointed off the dead sword +
  #     no-longer-disarming shield).
  #   shieldTank  — an escort grabs a shield to body-block the carrier (still a
  #     6-HP wall; the premise survives — shield still tanks + blocks bodies).
  #   swordAmbush — INERT on v15 (no sword to grab); code kept, gated, never fires.
  # Detect our own possession from the "shield carried"/"plasma arc carried"
  # markers that float over our head (the "grenade carried" pattern). iHaveSword
  # stays wired for the inert swordAmbush path but never trips ("sword carried"
  # no longer emitted).
  var
    iHaveShield = false
    iHaveSword = false
    iHavePlasma = false
  for o in client.spriteObjectsWithLabel(LabelShieldCarried):
    if dist(client.mapPos(o), me) <= 30.0:
      iHaveShield = true
      break
  for o in client.spriteObjectsWithLabel("sword carried"):
    if dist(client.mapPos(o), me) <= 30.0:
      iHaveSword = true
      break
  for o in client.spriteObjectsWithLabel(LabelSprayCanCarried):
    if dist(client.mapPos(o), me) <= 30.0:
      iHavePlasma = true
      break
  # Pickup points in view (each filtered against the HUD indicator that shares
  # the label, exactly like the grenade pickup scan).
  var
    swordPickups: seq[Vec]
    shieldPickups: seq[Vec]
    plasmaPickups: seq[Vec]
  if bot.tune.swordAmbush:            # inert on v15 (no "sword" pickup emitted)
    for o in client.spriteObjectsWithLabel("sword"):
      let p = client.mapPos(o)
      if p.x < 40.0 or p.y < 40.0 or p.x > float(MapW - 40) or p.y > float(MapH - 40):
        continue
      swordPickups.add(p)
  if bot.tune.avoidDisarm or bot.tune.sprayGrab:
    for o in client.spriteObjectsWithLabel(LabelSprayCan):
      let p = client.mapPos(o)
      if p.x < 40.0 or p.y < 40.0 or p.x > float(MapW - 40) or p.y > float(MapH - 40):
        continue
      plasmaPickups.add(p)
  if bot.tune.shieldTank or bot.tune.shieldRush:  # shield = 6 HP (no longer a disarm)
    for o in client.spriteObjectsWithLabel(LabelShield):
      let p = client.mapPos(o)
      if p.x < 40.0 or p.y < 40.0 or p.x > float(MapW - 40) or p.y > float(MapH - 40):
        continue
      shieldPickups.add(p)
  # shieldTank: an escort with our heart stolen and a shield in easy reach grabs
  # it to become a fat body-block on the carrier's cone (it can't shoot anyway).
  var seekingPickup = false
  if bot.tune.shieldTank and not iHaveShield and not iHaveSword and
      not iCarry and not banking and mateCarry and
      bot.role in {MidBottom, FlankBottom, MidGuard} and
      dist(me, mateCarryPos) < EscortRunMateRange:
    var best = 1e18
    for p in shieldPickups:
      let d = dist(p, me)
      if d <= ShieldGrabDetour and d < best:
        best = d
        target = p
        seekingPickup = true
    when defined(ssprobe):
      if seekingPickup: inc ssTankSeek
  # ⭐ SPRAY GRAB (2026-08-04, GV36 melee doctrine — Maxwell's swap framing).
  # The cone is not a sidearm: carrying it REPLACES the gun with a 3-dmg/touch
  # close-range weapon that one-shots a bare cog. Census of 18 live post-GV36
  # episodes: the post-churn league #1 takes 31% of his kills with the cone
  # (5.77 kills/1k carry-ticks, short frequent carries), and NOBODY in the
  # sample died while carrying — the gun you give up is broken at range
  # anyway, so the swap is currently FREE. Our per-carry efficiency already
  # beats focusfire's; we simply never picked one up (1% carry time).
  # Opportunistic and VISIBLE-ONLY (no spawn-coordinate guessing — the kit
  # lesson): any free attacker seat that sees a can nearby grabs it.
  if bot.tune.sprayGrab and not seekingPickup and not iHavePlasma and
      not banking and
      not iHaveShield and not iCarry and not mateCarry and not ownStolen and
      bot.role in {MidTop, MidBottom, MidGuard, FlankTop, FlankBottom}:
    var best = 1e18
    for p in plasmaPickups:
      let d = dist(p, me)
      if d <= SprayGrabDetour and d < best:
        best = d
        target = p
        seekingPickup = true
  # ⭐⭐ shieldRush: the rusher grabs OUR OWN endzone shield BEFORE the steal so it
  # carries the heart home at 6 HP (survive 6 hits vs 3 = the grab→cap fix). Gated to
  # the rusher seats, only while still home-side (ShieldRushMaxDepth) and not already
  # carrying/shielded/seeking — a cheap detour toward home, never a backtrack once
  # forward. The shield sits at our endzone (¾ height), so it's on the way out.
  if bot.tune.shieldRush and not bot.shieldRushDone and not seekingPickup and
      not banking and
      not iHaveShield and not iCarry and not mateCarry and not ownStolen and
      bot.role == roleForSeat(ShieldRushSeat, bot.team) and
      bot.tick - max(bot.gameStart, bot.lifeStart) <= ShieldRushWindow:
    # Navigate to the STATIC known shield spawn (no LOS needed — VisionBubble is 90px
    # and the shield sits behind the spawn cone, so the see-it scan fired 0). One
    # designated seat grabs it; a give-up latch stops re-detouring if a mate took it.
    let sp = ownShieldSpawn(bot.team)
    if iHaveShield:
      bot.shieldRushDone = true              # got it — carry on to the steal
    elif dist(me, sp) <= ShieldOnSpotPx and shieldPickups.len == 0:
      bot.shieldRushDone = true              # on the spot but no shield here = taken; give up
    else:
      target = sp
      seekingPickup = true
      when defined(commsprobe): inc csArcSeek  # reuse a probe slot for shield-rush seek
  elif iHaveShield:
    bot.shieldRushDone = true
  # swordAmbush: a bot with no clear ranged shot, boxed in close to an enemy,
  # with a sword within reach, grabs it to melee. Only when a fresh enemy is
  # inside SwordCloseRange (a pocket scrum the windup gun loses) and we're not
  # carrying / defending a run.
  var swordTarget = -1
  if bot.tune.swordAmbush and not iCarry and not mateCarry and not ownStolen:
    if iHaveSword:
      # Already armed with melee: close on and swing at the nearest fresh enemy.
      var best = SwordCloseRange
      for i in 0 ..< bot.enemies.len:
        if bot.tick - bot.enemies[i].lastSeen > bot.tune.freshShotTicks:
          continue
        let d = dist(bot.enemies[i].pos, me)
        if d < best:
          best = d
          swordTarget = i
    elif not seekingPickup and engage < 0 and swordPickups.len > 0:
      # No ranged engage this frame and a close enemy — grab a sword if handy.
      var enemyClose = false
      for i in 0 ..< bot.enemies.len:
        if bot.tick - bot.enemies[i].lastSeen <= bot.tune.freshShotTicks and
            dist(bot.enemies[i].pos, me) <= SwordCloseRange * 2.0:
          enemyClose = true
          break
      if enemyClose:
        var best = 1e18
        for p in swordPickups:
          let d = dist(p, me)
          if d <= SwordGrabDetour and d < best:
            best = d
            target = p
            seekingPickup = true
        when defined(ssprobe):
          if seekingPickup: inc ssAmbushSeek

  # ── ⭐ ARC BREACHER SEEK (anti-line OFFENSE). When a line is live (classified or
  # heard) and we are the designated breacher seat, break off and grab the plasma
  # arc so we can cone the clustered line. Deliberately trades our gun (canFire=false
  # while holding) — a specialist swap, so ONLY the fixed breacher seat, ONLY on a
  # live line (or a committed run), ONLY when not carrying/escorting/defending. The
  # FIRE half is in the mask block below (a sibling of the sword-melee swing).
  #
  # ⭐ CAPTAIN-COORDINATED ARM (2026-07-24, the reframe). The lone-wolf breacher failed
  # the audit on GEOMETRY: grabbing REACTIVELY after a line forms means the breacher is
  # already deep forward, so the round trip back to the own-corner arcSpawn and out again
  # is ~478t — longer than the line lives. The fix is to arm PROACTIVELY while SHALLOW:
  # the arc sits in our own back corner NEXT to spawn, so a breacher that's near/behind
  # mid grabs it on a cheap ~one-leg detour, THEN carries the armed cone forward to the
  # called cluster. The Captain-mind (teamPhase) supplies the proactive trigger — an
  # ATTACKING phase (Open/Probe/Press) is exactly when the enemy answers with a standing
  # line, so a shallow breacher pre-arms for it; a live/heard line (lineLive) also arms.
  # The seek navigates to the STATIC arcSpawn (no LOS — the fires-0 fix), and the commit
  # window (arcBreachUntil) holds the run through line-read flicker. Once armed the FIRE
  # block owns the bot (iHavePlasma) and carries the cone to the cluster regardless of depth.
  let teamSeat = clamp(bot.slot div 2, 0, 7)
  let iAmBreacher = bot.tune.arcBreach and teamSeat == ArcBreachSeat
  let breachDepth = -homeSign(bot.team) * (me.x - float(CenterX))   # + = into enemy half
  # Remember that a line was seen (this bot's own classification OR a heard call) — the
  # proof this OPPONENT plays defensive lines. Opponent-adaptivity hinges on this memory.
  if iAmBreacher and lineLive:
    bot.sawLineTick = bot.tick
  # A line is likely when it's actually called (lineLive) OR the Captain has us in a mid-game
  # PRESSURE phase (Probe/Press) AND this opponent has shown a line recently (ArcLineMemory).
  # NOT PhOpen (the opening needs every gun grouped). The line-memory gate is what keeps the
  # breacher DORMANT (a full gun) vs an aggressive no-line field — it only pre-commits its gun
  # to the arc against opponents that actually stand lines, so we never pay disarm for nothing.
  let sawLineRecently = bot.tick - bot.sawLineTick <= ArcLineMemoryTicks
  let linePendingPhase = bot.tune.planLayer and botPhase in {PhProbe, PhPress} and sawLineRecently
  let armProactive = lineLive or linePendingPhase
  when defined(arcprobe):
    if iAmBreacher: inc apBreacher
    if iAmBreacher and lineLive: inc apLineLive
  # ARM the commit window only while SHALLOW (a cheap grab); a deep breacher must NOT
  # start the ~478t retreat the audit killed — it stays a gun on the line until it falls
  # back naturally, then arms shallow. Once armed (iHavePlasma) the window is irrelevant.
  if iAmBreacher and armProactive and not iHavePlasma and breachDepth <= ArcArmMaxDepth:
    bot.arcBreachUntil = bot.tick + ArcBreachCommit
  let arcRunLive = iAmBreacher and bot.tick <= bot.arcBreachUntil
  if iAmBreacher and not iHavePlasma and not iCarry and not mateCarry and
      not ownStolen and arcRunLive and not seekingPickup:
    when defined(arcprobe): inc apEligible
    # Navigate to the KNOWN own-side arc spawn — it's on our half (safe route) and a
    # fresh pickup is essentially always waiting there (30s respawn), so no sighting
    # is needed. Auto-pickup on a 12px touch arms us; the FIRE block takes over.
    target = arcSpawn(bot.team)
    seekingPickup = true
    when defined(arcprobe): inc apSeek
    when defined(commsprobe): inc csArcSeek

  # ── v9 MED-KIT TOP-OFF (GameVersion 9). A wounded, out-of-contact bot detours
  # to the nearest VISIBLE center med kit to heal to FULL on a 12px touch (sim
  # tryPickupMedKits; a healthy bot never consumes one, so a kit is never wasted).
  # A pure MOVEMENT override — it only moves the target, never the trigger — so it
  # can't regress into fire discipline. Gated hard to SAFE + FREE: fires only with
  # no active engage and no near threat (topping off is a between-contacts act,
  # never mid-fight), and never for a carrier / escort / committed grabber /
  # stolen-flag defender (they own a higher objective). Skips a deliberate v7
  # sword/shield seeker so it can't clobber that target. Fog reveals a kit only
  # near center, so the detour is naturally self-limiting; MedKitDetour caps it so
  # a bot never abandons its lane for a far kit.
  block medKitTopOff:
    when defined(mtprobe):
      if bot.tune.medTopOff and bot.ownHp > 0: inc mtOn
    if not bot.tune.medTopOff: break medKitTopOff
    if bot.ownHp notin 1 ..< MaxHp: break medKitTopOff   # unread(0) or full: no detour
    when defined(mtprobe): inc mtWounded
    if engage >= 0 or nearThreat >= 0: break medKitTopOff # in contact: fight/duck, don't wander
    when defined(mtprobe): inc mtSafe
    if iCarry or mateCarry or pocketRush or ownStolen or
        seekingPickup or iHaveShield or iHaveSword or iHavePlasma:
      break medKitTopOff                                 # a higher objective owns this bot
    when defined(mtprobe): inc mtFree
    var best = MedKitDetour
    var haveKit = false
    var chosen: Vec
    for o in client.spriteObjectsWithLabel(LabelMedKit):
      let p = client.mapPos(o)
      if p.x < 40.0 or p.y < 40.0 or p.x > float(MapW - 40) or
          p.y > float(MapH - 40):
        continue                                         # HUD indicator shares the label
      let d = dist(p, me)
      if d < best:
        best = d
        chosen = p
        haveKit = true
    when defined(mtprobe):
      if haveKit or client.spriteObjectsWithLabel(LabelMedKit).len > 0: inc mtVisible
    if haveKit:
      target = chosen
      when defined(mtprobe): inc mtFireCount

  # ── ⭐⭐ medEcon: THE MED KITS ARE A STATIC, RENEWABLE HP ECONOMY (2026-07-28).
  # Measured on 20 real league episodes: the field took 42 heals to our 11 (3.8x),
  # while 81% of our kill deficit books in ticks 1000-3000 and 8 of 13 losses were
  # full WIPES. With 3 hp per life a free full heal is worth a life's damage, so
  # this is the single largest resource asymmetry we could find.
  #
  # medTopOff above has the right DOCTRINE but a gate that almost never opens: it
  # requires the kit sprite to be VISIBLE in the fog cone within 150px AND zero
  # contact. In a mid-game where contact is ~constant that conjunction is dead.
  # medEcon fixes exactly the three closed conditions and changes nothing else:
  #   1. the kits sit at STATIC engine coords (sim.resetMedKits; verified against
  #      53 league heal events clustering at (617,219)/(617,439)), so we route to
  #      remembered positions like a pedestal — no fog read needed at all;
  #   2. MedKitEconDetour(320) instead of 150, since the walk is now the only cost;
  #   3. at MedKitLightContactHp a bot breaks LIGHT contact (a threat NOT aiming at
  #      us) to heal — at 1 hp the next bullet is death, so the heal outranks the
  #      duel. A threat whose gun IS on us still wins: we never turn our back on a
  #      live gun (the holdVsGun rule), so that case falls through to combat.
  # Still a pure MOVEMENT override (never touches the trigger), and it still yields
  # to every genuine objective. A kit we are standing on but cannot see is TAKEN
  # (its sprite would be in our bubble), so give up rather than orbit an empty spot.
  block medKitEcon:
    if not bot.tune.medEcon: break medKitEcon
    when defined(meprobe):
      if bot.ownHp > 0: inc meOn
    if bot.ownHp notin 1 ..< MaxHp: break medKitEcon    # unread(0) or full: no detour
    when defined(meprobe): inc meWounded
    if iCarry or mateCarry or pocketRush or ownStolen or
        seekingPickup or iHaveShield or iHaveSword or iHavePlasma:
      break medKitEcon                                 # a higher objective owns this bot
    when defined(meprobe): inc meFree

    # Contact rule. Out of contact: always free to top off (the medTopOff intent).
    # In contact: only a bot at MedKitLightContactHp may disengage, and only from a
    # threat that is NOT pointing at it. Anything else keeps fighting.
    if engage >= 0 or nearThreat >= 0:
      if bot.ownHp > MedKitLightContactHp: break medKitEcon
      var aimedAtUs = false
      for i in 0 ..< bot.enemies.len:
        let t = bot.enemies[i]
        if bot.tick - t.lastSeen > HoldVsGunTtl or t.aimBrads < 0:
          continue
        # Widened by AimFuzzBrads (GV24): this gate decides whether a WOUNDED bot turns its
        # back and walks to a kit. A fuzzed read that says "not on us" when the gun really is
        # buys a free shot in the back, so the error bar belongs on the SAFE side here.
        if abs(bradsErr(t.aimBrads, bradsOf(me - t.pos))) >
            AimOnConeBrads + AimFuzzBrads:
          continue                                     # its gun is not on us
        if not client.pixelRayClear(me, t.pos):
          continue                                     # no line: it cannot punish the walk
        aimedAtUs = true
        break
      if aimedAtUs: break medKitEcon                   # a live gun on us: hold, don't flee
      when defined(meprobe): inc meLightBreak
    when defined(meprobe): inc meSafe

    # Route to the nearest kit whose spot is not known-empty. The position is
    # static knowledge; only the PRESENCE needs a sight check, and only once we
    # are close enough that an absent sprite proves the kit is gone.
    var bestEcon = MedKitEconDetour
    var haveEconKit = false
    var chosenEcon: Vec
    var pickedVisible = false      # which family supplied the target (probe/mechanism)
    var pickedVisOffSpot = false   # ...and that visible kit is NOT at a formula spot

    # ── ⭐⭐ medSee (plan #16): the kits we can SEE are candidates too.
    # The two formula spots below are an ARENA truth: on a generated board the
    # generator draws the pair's y per map, and a 4-team board carries FOUR kits
    # in a rot90 orbit — so a wounded bot walks to empty floor while a real kit
    # sits in its cone. A visible sprite needs no presence check (seeing it IS
    # presence) but keeps the SAME HUD-indicator edge filter and the SAME
    # MedKitEconDetour cap; nearest across both families wins. Nothing above this
    # point changes — same hp gate, same objective yields, same in-contact and
    # aimedAtUs rules — so this adds no new disengagement, only a better address.
    if bot.tune.medSee or MedSeeProbeScan:
      var visAny = false
      var visNear = false
      var visOff = false
      for o in client.spriteObjectsWithLabel(LabelMedKit):
        let p = client.mapPos(o)
        if p.x < 40.0 or p.y < 40.0 or p.x > float(MapW - 40) or
            p.y > float(MapH - 40):
          continue                                     # HUD indicator shares the label
        visAny = true
        let d = dist(p, me)
        if d >= MedKitEconDetour:
          continue                                     # outside the detour budget
        visNear = true
        let offSpot = dist(p, vec(MedKitAX, MedKitAY)) > MedKitOnSpotPx and
                      dist(p, vec(MedKitBX, MedKitBY)) > MedKitOnSpotPx
        if offSpot:
          visOff = true
        if not bot.tune.medSee:
          continue                                     # probe build, lever off: count only
        if d >= bestEcon:
          continue
        bestEcon = d
        chosenEcon = p
        haveEconKit = true
        pickedVisible = true
        pickedVisOffSpot = offSpot
      when defined(msprobe):
        inc msScan
        if visAny: inc msVisAny
        if visNear: inc msVisNear
        if visOff: inc msVisOffSpot

    for spot in [vec(MedKitAX, MedKitAY), vec(MedKitBX, MedKitBY)]:
      let d = dist(spot, me)
      if d >= bestEcon:
        continue
      if d <= MedKitOnSpotPx:
        # Standing on it: if no kit sprite is here it has been taken — a kit in
        # our own bubble is never fogged, so absence is proof, not ignorance.
        var present = false
        for o in client.spriteObjectsWithLabel(LabelMedKit):
          let p = client.mapPos(o)
          if p.x < 40.0 or p.y < 40.0 or p.x > float(MapW - 40) or
              p.y > float(MapH - 40):
            continue                                   # HUD indicator shares the label
          if dist(p, spot) <= MedKitOnSpotPx:
            present = true
            break
        if not present:
          continue
      bestEcon = d
      chosenEcon = spot
      haveEconKit = true
      pickedVisible = false
      pickedVisOffSpot = false
    if haveEconKit:
      target = chosenEcon
      when defined(meprobe): inc meFireCount
      when defined(msprobe):
        inc msFire
        if pickedVisible:
          inc msPickVis
          if pickedVisOffSpot: inc msPickVisOff
        else:
          inc msPickSpot

  # Grenade danger: a visible throw-target ring marks where an enemy's lob
  # will land, and an airborne grenade is seconds from bursting — anything
  # inside the blast radius eats 2 of 3 hit points. Fleeing the marked spot
  # outranks every movement goal except nothing: dead carriers drop the run.
  var
    nadeDanger = false
    nadeDangerFrom: Vec
  block nadeDangerScan:
    for label in ["throw target", "grenade air"]:
      for o in client.spriteObjectsWithLabel(label):
        let p = client.mapPos(o)
        if dist(p, me) <= NadeBlast + 18.0:
          nadeDanger = true
          nadeDangerFrom = p
          break nadeDangerScan

  # Turret + locomotion, decided together but on separate buttons: moveMask
  # is the d-pad, desiredAim feeds the rotate buttons, wantFire pulls A.
  var
    moveMask: uint8
    desiredAim = -1
    deadband = bot.tune.combatDeadband
    wantFire = false
    acted = false
    holdStill = false
    nadeC = false
    aimTargetD = -1.0         # range of the COMBAT traverse this tick (-1 = the
                              # turret is not slewing onto a shootable target), the
                              # conditioning variable for the spinCap range fork.
  if touchLatch and bot.nadeCharge == 0:
    # ⭐⭐ TOUCH LATCH wins the act-priority race. It is placed FIRST deliberately: the
    # grenade branch below used to own this slot and sets holdStill, so a bot 15px from the
    # heart with a charge available would stop and lob (a defended pocket is exactly the
    # cluster>=2 the lob wants, and NadeMinRange=72 still fires from inside grab range).
    # Move onto the pedestal and keep the turret where the nav is going; do not fire, do not
    # hold still. An already-charging throw (nadeCharge > 0) is allowed to release rather than
    # be abandoned mid-charge — dropping a live charge wastes the grenade for nothing.
    moveMask = octantBits(stealTarget - me)
    acted = true
    when defined(tcprobe):
      if nadeAim >= 0: inc tcNade
      if engage >= 0 and shotReady: inc tcEngage
      if not shotReady and nearThreat >= 0: inc tcDuck
      if shotReady and haveBlocked: inc tcPeek
  elif bot.nadeCharge > 0 or nadeAim >= 0:
    # Charge-throw: lay the turret on the lob line, then hold C for the ticks
    # the planned distance needs and release — the grenade leaves along the
    # CURRENT aim on release. Pre-GV36 the turret could keep correcting while
    # charging (5 brads/tick drifts stay near the line); on the GV36 slot grid
    # a mid-charge correction is a 40-brad/tick multi-revolution sweep, so an
    # uncgated release flies the WRONG WAY. nadeLob: freeze the lob bearing at
    # charge start (no cluster-chasing) and release only on a settled turret —
    # the engine holds max charge indefinitely, so waiting is legal; the cost
    # is range creep toward the cap, bounded by the NadeHoldMax bail-out.
    if bot.nadeCharge == 0:
      bot.nadeNeed = max(3, int(float(NadeFullChargeTicks) *
        (nadeThrowD - 30.0) / (NadeMaxRange - 30.0)))
      if bot.tune.nadeLob:
        bot.nadeLockAim = nadeAim
        bot.nadeHold = 0
    if bot.tune.nadeLob and bot.nadeLockAim >= 0:
      desiredAim = bot.nadeLockAim
    elif nadeAim >= 0:
      desiredAim = nadeAim
    if bot.nadeCharge > 0 or (desiredAim >= 0 and
        abs(bradsErr(desiredAim, bot.estAim)) <= CombatDeadband + 2):
      if bot.nadeCharge < bot.nadeNeed:
        nadeC = true
        inc bot.nadeCharge
      else:
        const NadeHoldMax = 20         # settle-wait bail-out (ticks)
        if bot.tune.nadeLob and desiredAim >= 0 and
            abs(bradsErr(desiredAim, bot.estAim)) > 6 and
            bot.nadeHold < NadeHoldMax:
          nadeC = true                 # keep holding: turret not on the line yet
          inc bot.nadeHold
        else:
          when defined(nadeprobe):
            if desiredAim >= 0:
              stderr.writeLine "NADEREL slot=" & $bot.slot & " t=" & $bot.tick &
                " err=" & $abs(bradsErr(desiredAim, bot.estAim)) &
                " held=" & $bot.nadeHold
          bot.nadeCharge = 0           # release this tick = the throw
          bot.nadeLockAim = -1
    holdStill = true
    acted = true
  elif bot.tune.swordAmbush and iHaveSword and swordTarget >= 0:
    # SWORD MELEE: holding a sword makes canFire=false and turns the attack
    # button into a 26px forward-arc INSTANT kill. Close on the nearest fresh
    # enemy and swing when it sits inside the arc — a guaranteed kill the 3-hit
    # windup gun would lose at point-blank. The swing eats fireCooldown, so only
    # press when the enemy is actually within reach and roughly in front.
    let
      tgt = bot.enemies[swordTarget].pos
      d = dist(tgt, me)
    desiredAim = bradsOf(tgt - me)
    moveMask = octantBits(tgt - me)          # charge straight in
    if d <= SwordReach + 6.0:
      let err = abs(bradsErr(desiredAim, bot.estAim))
      wantFire = err <= AimBrads div 4        # within the ~forward half-arc
      when defined(ssprobe):
        if wantFire: inc ssAmbushSwing
    acted = true
  elif iHavePlasma:
    # ⭐ ARC BREACHER FIRE: holding the arc, canFire=false — the attack button now
    # fires a 136px forward CONE (dmg 3, hits everyone in the ~14° arc at once).
    # Aim at the FATTEST cluster of fresh enemies in reach (a line is a cluster; the
    # cone is a multikill), close to reach, and press attack when on-bearing so the
    # cone lands. Same edge-triggered attack the sim reads for the cone (input.attack
    # and not prev.attack); firedLast gating below keeps it a clean press, not a hold.
    when defined(arcprobe): inc apArmed
    # The cone only earns its disarmed-for-life cost against a real CLUSTER (>=
    # ArcConeMinCluster fresh enemies inside one PlasmaArcReach): coning a SINGLETON is a
    # net DPS loss (a 25t-recharge weapon vs one cog we'd have shot anyway; field-measured
    # 1.33 mean hits WITHOUT this gate). Doctrine: the arc is AREA-DENIAL — its value is
    # >=2-at-once; good opponents space to dodge AoE, so a lone target is not its job.
    # Compute, for every fresh enemy, the cluster size around it (peers within one arc
    # reach). Track the fattest cluster that is (a) inside FIRE reach + clear LOS, and
    # (b) the fattest within the wider APPROACH radius (to close a deep line before firing).
    var fireCluster = 0
    var fireAim = -1
    var fireTgt: Vec
    var approachCluster = 0
    var approachTgt: Vec
    var nearFoe = -1
    var nearD = 1e18
    for i in 0 ..< bot.enemies.len:
      if bot.tick - bot.enemies[i].lastSeen > bot.tune.freshShotTicks:
        continue
      let tp = bot.enemies[i].pos
      let dme = dist(tp, me)
      if dme < nearD:
        nearD = dme
        nearFoe = i
      var cluster = 1
      for j in 0 ..< bot.enemies.len:
        if j != i and bot.tick - bot.enemies[j].lastSeen <= bot.tune.freshShotTicks and
            dist(bot.enemies[j].pos, tp) <= PlasmaArcReachPx:
          inc cluster
      # Approach candidate: the fattest cluster within the (wider) approach radius.
      if dme <= ArcApproachRadius and cluster > approachCluster:
        approachCluster = cluster
        approachTgt = tp
      # Fire candidate: must be inside cone reach with clear LOS (the sim gates the cone).
      if dme <= ArcBreachFireReach and client.pixelRayClear(me, tp) and cluster > fireCluster:
        fireCluster = cluster
        fireTgt = tp
        fireAim = bradsOf(tp - me)
    let depth = -homeSign(bot.team) * (me.x - float(CenterX))   # how deep we are (+ = enemy half)
    if fireAim >= 0 and fireCluster >= ArcConeMinCluster:
      # A real cluster IN REACH: close onto it and CONE it (the multikill this weapon is for).
      when defined(arcprobe): inc apInReach
      desiredAim = fireAim
      moveMask = octantBits(fireTgt - me)      # close to keep the cluster in the cone
      let err = abs(bradsErr(desiredAim, bot.estAim))
      wantFire = err <= ArcBreachConeBrads     # on-bearing so the cone covers them
      when defined(commsprobe):
        if wantFire: inc csArcFire
      when defined(arcprobe):
        if wantFire:
          inc apFire
          apClusterSum += fireCluster
          if fireCluster > apMaxCluster: apMaxCluster = fireCluster
    elif approachCluster >= ArcConeMinCluster:
      # A real cluster is in view but OUT of cone reach: CLOSE the gap onto its centroid.
      # This is the sanctioned approach (we're closing to land a multikill — +EV per the
      # numbers doctrine), NOT feeding: it is gated on a genuine cluster, and we keep the
      # cone trained on it the whole way so it lands the instant we're in reach.
      when defined(arcprobe): inc apCharge
      moveMask = octantBits(approachTgt - me)
      desiredAim = bradsOf(approachTgt - me)
    elif bot.arcLinePos.x >= 0 and bot.tick - bot.arcLineTick <= CommsPlayTtl and
        dist(bot.arcLinePos, me) > ArcBreachFireReach:
      # ⭐ CONVERGE on the CALLED line (Captain-coordinated). We can't SEE the cluster yet
      # (no fresh tracks), but we KNOW where it was called — our own centroid or a heard
      # caller's bubble. Walk toward it so the line comes into vision + cone reach, then the
      # cluster scan above takes over. This is the fog-crossing convergence the callout buys:
      # a breacher a lane away brings its sustained cone to the real line, not a blind seam.
      # Stop short of overrunning (the cone reach margin), and keep the vision cone on it.
      when defined(arcprobe): inc apCharge
      moveMask = octantBits(bot.navSteer(client, me, bot.arcLinePos))
      desiredAim = bradsOf(bot.arcLinePos - me)
    else:
      # DRY: no fat cluster anywhere and no fresh line location (a singleton or nothing). We
      # hold a disarmed gun for the rest of this life, so the worst thing we can do is charge
      # that gunless body INTO the line to be focus-fired for free. Ease to a SHALLOW threat
      # depth and hold — a live cone shapes the line (enemies space to dodge AoE) even unfired,
      # and we stay poised to close the instant a real cluster forms or a line is called. A
      # disarmed unit has no gun to trade.
      when defined(arcprobe): inc apCharge
      if depth < ArcSeamHoldDepth:
        let seam = vec(float(CenterX) - homeSign(bot.team) * ArcSeamHoldDepth, me.y)
        moveMask = octantBits(bot.navSteer(client, me, seam))
        desiredAim = bradsOf(seam - me)
      elif nearFoe >= 0:
        # At the threat line: hold depth, keep the cone on the nearest foe (poised to cone).
        desiredAim = bradsOf(bot.enemies[nearFoe].pos - me)
      else:
        desiredAim = bradsOf(vec(-homeSign(bot.team), 0.0))  # face the enemy half
    acted = true
  elif engage >= 0 and shotReady:
    # Traverse onto the target and fire once the corridor covers it: the
    # perpendicular miss of the current aim error at the target's range must
    # sit inside the ~14px bullet corridor. Advancing scales that miss down
    # linearly, so keep closing while the turret settles.
    desiredAim = bradsOf(aim - me)
    aimTargetD = engageD      # this traverse is a SHOOTING traverse at this range
    let
      err = abs(bradsErr(desiredAim, bot.estAim))
      perpMiss = engageD * sin(float(err) * PI / float(AimBrads div 2))
    # GV36 recalibration: settled on the NEAREST slot the residual error is
    # up to 4 brads (5.6 deg) — at 150px that is 14.7px of perp-miss against
    # a slack tuned for 5-brad precision that no longer exists. Inside 300px
    # widen to body+corridor (17px); beyond, the old slack stands (a ray that
    # far off really does miss).
    wantFire = perpMiss <=
      (if engageD < 300.0: max(bot.tune.fireSlackPx, 17.0)
       else: bot.tune.fireSlackPx)
    when defined(rngprobe):
      rpBand = rpBandOf(engageD)
      rpSide = ord(bot.team)
      inc rpFrames[rpSide][rpBand]
      rpErrSum[rpSide][rpBand] += err
      rpDistSum[rpSide][rpBand] += engageD
      if wantFire: inc rpOpen[rpSide][rpBand]
    if bot.tune.fireOnRealBody:
      # Also open the trigger when the current aim's perp-miss to the target's
      # REAL last-seen position sits in the corridor (the lead phantom swings
      # wide on a juking target). Aim still LEADS; this only OPENS the trigger.
      let
        bodyAim = bradsOf(engageBody - me)
        bodyErr = abs(bradsErr(bodyAim, bot.estAim))
        bodyD = dist(engageBody, me)
        bodyMiss = bodyD * sin(float(bodyErr) * PI / float(AimBrads div 2))
      if bodyMiss <= bot.tune.fireSlackPx and
          client.pixelRayClear(me, engageBody) and
          not bot.friendlyBlocked(me, engageBody, bodyD):
        wantFire = true
    if retreating or banking or (bot.tune.carrierFlee and iCarry):
      # Outnumbered (retreat) OR banking at 1 hp OR carrying the heart (flee):
      # keep the gun on the
      # lined-up target and take the free trade, but MOVE toward our objective
      # (the regroup point / home capture edge) instead of advancing into the
      # enemy. A carrier that steps toward a point-blank respawner walks into the
      # invulnerable respawn nest at the pedestal and dies at ~2% of the run home
      # — the single biggest leak in the grab->capture funnel. The heart only
      # scores by reaching our edge, so the carrier NEVER trades ground for a kill.
      moveMask = octantBits(bot.navSteer(client, me, target))
    else:
      # offCone: OFF-CONE APPROACH (backlog #4, Battle Drill 6). Never close on
      # an oriented gun down the axis it covers: when the engage target's read
      # bearing (aimRotRead) has its cone ON us, bend the approach TANGENTIALLY
      # around it toward the cone's edge — it must slew its uncappable 5-brad/
      # tick turret to keep us while our gun stays on its body (desiredAim is
      # untouched; feet only). aimErr is the signed arc from our bearing (as
      # seen from the enemy) to its aim: positive = its gun lies CCW of us, so
      # escape CW; the CCW tangent around the enemy is vec(rel.y, -rel.x) in
      # screen coords. The bend ramps with how dead-on the gun is; inside
      # OffConeCloseRange charge straight (a tangent step just orbits at knife
      # range); a wall on the escape side cancels the bend (crossing THROUGH
      # the aim axis to the far edge walks the dead-on line — worse).
      var advance = norm(aim - me)
      when defined(ocprobe):
        if bot.tune.offCone and bot.tune.aimThreat: inc ocAdvance
      if bot.tune.offCone and bot.tune.aimThreat and
          engageD > OffConeCloseRange and
          bot.enemies[engage].aimBrads >= 0:
        when defined(ocprobe):
          inc ocConeRead
        let
          rel = me - engageBody
          aimErr = bradsErr(bot.enemies[engage].aimBrads, bradsOf(rel))
        if abs(aimErr) <= AimOnConeBrads:
          when defined(ocprobe):
            inc ocOnUs
          var tangent = norm(vec(rel.y, -rel.x))      # CCW around the enemy
          if aimErr > 0 or (aimErr == 0 and (bot.slot and 1) == 1):
            tangent = tangent * -1.0                  # its gun is CCW: go CW
          if bot.gridRayClear(me, me + tangent * 24.0):
            let tight = clamp(
              float(AimOnConeBrads - abs(aimErr)) /
                float(AimOnConeBrads - AimDeadOnBrads), 0.0, 1.0)
            advance = advance + tangent *
              (OffConeBendMin + (OffConeBendMax - OffConeBendMin) * tight)
            when defined(ocprobe):
              inc ocBend
      moveMask = octantBits(advance)
    if bot.tune.unstuckEngaged and bot.tick < bot.jinkUntil:
      # A stuck burst is in flight while we advance on the target: keep jinking
      # so a corner-grind actually breaks free instead of re-grinding the wall
      # every frame. The gun still fires on-line.
      moveMask = bot.jinkBits
    acted = true
  elif not iCarry and not rushing and not disarmedRush and not shotReady and
      nearThreat >= 0:
    # Cooldown: our gun is down and a threat is near. Default = duck behind the
    # nearest cover that breaks its line and hold there until the gun is back
    # up, keeping the aim (and the vision cone) on the arc it would push through.
    let tp = bot.enemies[nearThreat]
    let facingMe =
      (tp.facingRight and tp.pos.x < me.x) or
      (not tp.facingRight and tp.pos.x > me.x)
    # assaultThrough: an armed near-ambush charge is COMMITTED (set at the
    # surprise scan: untracked contact in our face, gun on us, no cover nearer
    # than the enemy). Battle Drill 4 says fight THROUGH it — take the press
    # branch even against a facing full-hp gun, because the duck we'd otherwise
    # pick has no cover to reach and turns our gun off-axis at can't-miss range.
    let assaultOn =
      bot.tune.assaultThrough and bot.tick <= bot.assaultUntil and
      dist(tp.pos, me) <= AssaultPressRange
    when defined(asprobe):
      if assaultOn: inc asCharge
    # woundedBank: a 1-hp bot never closes into spray range on a reload gamble
    # (that close IS the median-83-tick death) — the one offensive suppression.
    let pressWorth = not banking and (assaultOn or (
      bot.tune.tempoPress and bot.tick - tp.lastSeen <= TempoFreshTicks and
      # #8 TEMPO / AUDACITY — press on the half-beat: our reload is dead time,
      # but so is theirs if the threat can't punish us right now. When it is
      # WOUNDED (one or two of our returning trigger-pulls from dead) or TURNED
      # AWAY (its gun isn't on us this instant), don't surrender tempo to a duck
      # — CLOSE the distance while jinking, so the moment our gun is live we are
      # on top of it and finish it in ITS dead time. Only inside a band where
      # closing actually pays; a facing, full-hp gun still gets the duck.
      ((tp.hp in 1 ..< MaxHp) or not facingMe) and
      dist(tp.pos, me) <= TempoPressRange))
    if pressWorth:
      desiredAim = bradsOf(tp.pos - me)      # pre-lay for the returning shot
      # Close on a jinking line (never a static/straight target): step toward
      # the threat with a sideways weave so we are not walking a clean corridor
      # into a gun that may come back up first.
      let toward = norm(tp.pos - me)
      var side = vec(-toward.y, toward.x)
      if (bot.tick div 10 + bot.slot div 2) mod 2 == 0:
        side = side * -1.0
      if not bot.gridRayClear(me, me + side * 24.0):
        side = side * -1.0
      moveMask = octantBits(toward + side * 0.5)
      acted = true
    else:
      let duck = bot.findDuckCell(client, me, tp.pos)
      if duck >= 0:
        desiredAim = bradsOf(tp.pos - me)
        if dist(cellCenter(duck), me) < 5.0:
          holdStill = true
        else:
          moveMask = octantBits(cellCenter(duck) - me)
        acted = true
  elif boundHold:
    # #6 BUDDY BOUNDING OVERWATCH: our gun is down and a mid-range enemy has a
    # clear line to us across open ground, but a covering mate's gun is up. Do
    # NOT bound forward into that line while reloading — duck to the nearest
    # cover that breaks the line and hold there, cone on the threat, until our
    # gun is live again (then shotReady flips and the engage/advance branches
    # resume the bound). One team gun stays trained on the crossing the whole
    # time. If no cover breaks the line, at least stop advancing (hold still).
    let duck = bot.findDuckCell(client, me, boundThreatPos)
    desiredAim = bradsOf(boundThreatPos - me)
    if duck >= 0 and dist(cellCenter(duck), me) >= 5.0:
      moveMask = octantBits(cellCenter(duck) - me)
    else:
      holdStill = true
    acted = true
  elif bot.tune.holdVsGun and not shotReady and not iCarry and not pocketRush and
      not retreating and not banking:
    # (banking already keeps the gun on the threat while withdrawing — avoid
    # double-owning the frame; plan #13 touch 12.)
    # ⭐ NEVER TURN YOUR BACK ON A LIVE GUN (focus-fire audit fix). boundHold above only
    # holds a gun-down bot that has a covering MATE; a SOLO bot (no wingman) with its gun
    # on cooldown and a fresh enemy whose gun is ON us past DuckRange but inside
    # HoldVsGunRange would otherwise fall through to the objective-movement branches and
    # STROLL AWAY — the map-wide gun kills it in the back. Find that dead-on threat and,
    # if there is one, break its line the same way boundHold does (duck to cover / hold),
    # aim held on it. Requires the aim-dot read (aimThreat) to know the gun is truly on us;
    # with no readback it does nothing (falls through), so it never fires blindly. Skips
    # when retreating (that branch already keeps the gun on the trade while moving to rally)
    # and when a clear engage exists (the engage branch owns that — this is a no-shot tier).
    var gunThreat = -1
    var gunThreatD = HoldVsGunRange
    if bot.tune.aimThreat:
      for i in 0 ..< bot.enemies.len:
        let t = bot.enemies[i]
        if bot.tick - t.lastSeen > HoldVsGunTtl or t.aimBrads < 0:
          continue
        let d = dist(t.pos, me)
        if d <= DuckRange or d >= gunThreatD:
          continue                         # close-duck owns <=DuckRange; ignore far
        # Widened by AimFuzzBrads (GV24), same reasoning as the medEcon disengage gate: the
        # whole point of this branch is "never turn your back on a live gun", so a fuzzed
        # read must not be allowed to declare a gun harmless.
        if abs(bradsErr(t.aimBrads, bradsOf(me - t.pos))) >
            AimOnConeBrads + AimFuzzBrads:
          continue                         # its gun is NOT on us — not a back-turn danger
        if not client.pixelRayClear(me, t.pos):
          continue                         # no clear line: it can't shoot our back anyway
        gunThreatD = d
        gunThreat = i
    if gunThreat >= 0:
      when defined(fsprobe): inc fsHold
      let tp = bot.enemies[gunThreat]
      desiredAim = bradsOf(tp.pos - me)      # keep the gun/cone ON the threat
      let duck = bot.findDuckCell(client, me, tp.pos)
      if duck >= 0 and dist(cellCenter(duck), me) >= 5.0:
        moveMask = octantBits(cellCenter(duck) - me)  # break its line to cover
      else:
        holdStill = true                     # no cover: at least don't present the back
      acted = true
  elif not iCarry and not rushing and shotReady and haveBlocked:
    # Peek: PRE-LAY the aim on the blocked target while stepping sideways to
    # the nearest cell that opens the firing line — the engage branch fires
    # the moment the ray clears, with the traverse already done.
    #
    # CORNER PRE-AIM: aim the EMERGENCE CORNER, not the body behind the wall.
    # The enemy's body appears at the cell nearest it that can see us when it
    # peeks; laying the turret there means our shot is already on-bearing as it
    # rounds the cover (winning the trade) instead of pointed at solid wall and
    # traversing after it shows — the replay-reported "we shoot the wall, they
    # step out and kill us" miss. Falls back to the body lead when no emergence
    # corner is found (target deep behind cover, not about to peek).
    if bot.tune.cornerPreAim:
      let emerge = bot.enemyEmergeAim(client, me, blockedBody)
      if emerge.x >= 0.0:
        desiredAim = bradsOf(emerge - me)
      else:
        desiredAim = bradsOf(blockedAim - me)
    else:
      desiredAim = bradsOf(blockedAim - me)
    let peek = bot.findPeekCell(client, me, blockedAim)
    if peek >= 0 and dist(cellCenter(peek), me) > 4.0:
      moveMask = octantBits(cellCenter(peek) - me)
      acted = true

  if not acted:
    # Threat jink: sidestep a visible enemy that is aiming our way while our
    # own shot is not lined up, instead of walking into its muzzle.
    var threat = -1
    var threatD = ThreatRange
    for i in 0 ..< seenEnemies.len:
      let a = seenEnemies[i]
      let facingMe =
        (a.facingRight and a.pos.x < me.x) or
        (not a.facingRight and a.pos.x > me.x)
      let d = dist(a.pos, me)
      if facingMe and d < threatD:
        threatD = d
        threat = i
    # THIEF PURSUIT: when OUR flag is stolen and a threat is in sight, that
    # enemy is either the carrier or its escort on OUR side of the field — the
    # capture race is lost if nobody hunts. Do NOT jink away "out of fear":
    # CLOSE on the nearest one and lay the gun, weaving so the approach isn't a
    # clean corridor. This overrides the generic sidestep (which was making a
    # defender who spotted the runner flee) but keeps the free-trade shot.
    if bot.tune.chaseThief and ownStolen and threat >= 0 and
        not iCarry and not disarmedRush:
      let toward = norm(seenEnemies[threat].pos - me)
      var side = vec(-toward.y, toward.x)
      if (bot.tick div 10 + bot.slot div 2) mod 2 == 0:
        side = side * -1.0
      if not bot.gridRayClear(me, me + side * 24.0):
        side = side * -1.0
      moveMask = octantBits(toward + side * 0.4)
      desiredAim = bradsOf(seenEnemies[threat].pos - me)
    elif threat >= 0 and not iCarry and not disarmedRush:
      let away = norm(me - seenEnemies[threat].pos)
      var side = vec(-away.y, away.x)
      if (bot.tick div 12 + bot.slot div 2) mod 2 == 0:
        side = side * -1.0
      if not bot.gridRayClear(me, me + side * 24.0):
        side = side * -1.0
      moveMask = octantBits(side + away * 0.4)
      if desiredAim < 0:
        desiredAim = bradsOf(seenEnemies[threat].pos - me)
    elif bot.role in {Overwatch, HomeDefender} and
        dist(me, target) < 6.0:
      # Holding a watch position: the aim carries the vision cone, so sweep
      # it back and forth across the arc threats cross while standing still.
      # While our flag is stolen the thief comes from our own half;
      # otherwise intruders come from the enemy half.
      let watch =
        if ownStolen: vec(homeSign(bot.team), 0.0)
        else: vec(-homeSign(bot.team), 0.0)
      # fatalFunnel: DEFENSIVE FATAL FUNNEL pre-lay (backlog #5, FM 90-10-1
      # App K). A truly idle sentry (no enemy track fresh within FunnelFreshTtl)
      # parks the turret ON the throat of the approach funnel instead of
      # sweeping: vision rides the aim so the cone lights the throat, and the
      # 5-brad/tick turret is already lined when a body funnels through —
      # acquisition ~0 instead of a 15-30t re-slew. REF-hunt guardrail: ANY
      # fresh track returns the two-speed sweep (which dwells on real threats),
      # so we never tunnel a defender onto an empty lane while a raider is
      # actually being tracked; the engage branch breaks the pre-lay the
      # instant a target appears (it owns desiredAim before this branch runs).
      var funnelIdle = false
      if bot.tune.fatalFunnel and bot.funnelReady and not ownStolen:
        funnelIdle = true
        for t in bot.enemies:
          if bot.tick - t.lastSeen <= FunnelFreshTtl:
            funnelIdle = false
            break
      when defined(ffprobe):
        if bot.tune.fatalFunnel:
          inc ffHold
          if funnelIdle: inc ffIdle
      if desiredAim < 0 and funnelIdle and
          dist(bot.funnelThroat, me) > 12.0:
        desiredAim = bradsOf(bot.funnelThroat - me)
        when defined(ffprobe):
          inc ffPreLay
      if desiredAim < 0:
        desiredAim = bot.scanAim(watch, me)
      holdStill = true
    else:
      # Navigate: cover-aware path steering plus soft repulsion from nearby
      # teammates so one burst (or our own shot) cannot hit two of us.
      var steer = norm(bot.navSteer(client, me, target))
      for t in bot.mates:
        if bot.tick - t.lastSeen > 12:
          continue
        let d = dist(t.pos, me)
        if d < MateSpacing and d > 0.5:
          steer = steer + norm(me - t.pos) * ((MateSpacing - d) / MateSpacing) * 0.9
      # avoidDisarm: soft-repel from a PLASMA-ARC pickup we are NOT out to collect
      # (auto-pickup on 12px touch => canFire=false, gun lost until fired+dropped).
      # Repointed off the dead sword + no-longer-disarming shield: the arc is the
      # only disarm on v15. Skip when we already hold the arc, or are deliberately
      # seeking a pickup (shieldTank sets seekingPickup).
      if bot.tune.avoidDisarm and not seekingPickup and not iHavePlasma:
        for p in plasmaPickups:
          let d = dist(p, me)
          if d < DisarmAvoidRadius and d > 0.5:
            steer = steer + norm(me - p) * ((DisarmAvoidRadius - d) / DisarmAvoidRadius) * 1.2
            when defined(ssprobe):
              inc ssAvoidActive
      # noMask: DON'T MASK FIRES, mover-side (backlog #3, ATP 3-21.8). Soft-
      # repel LATERALLY off any mate's live support ray (up gun + fresh target
      # on the bearing, built with the focus-fire scan above). friendlyBlocked
      # already protects from the SHOOTER'S side — by holding fire, spending
      # the mate's whole ~17t fire cycle; this moves the cost to the mover,
      # who has slack, so the mate's shot survives. Perpendicular push only
      # (never along the ray) so progress toward the target is preserved —
      # the same soft-repel family as MateSpacing/avoidDisarm above. Carriers
      # and the pocket grab are exempt (speed beats etiquette on the run).
      when defined(nmprobe):
        if bot.tune.noMask:
          inc nmNavFrames
          nmRays += supportRays.len
      if bot.tune.noMask and not iCarry and not pocketRush:
        for ray in supportRays:
          let rel = me - ray.origin
          let along = dot(rel, ray.dir)
          if along <= 0.0 or along >= ray.length:
            continue                    # behind the muzzle / past the target
          let side = cross(rel, ray.dir)
          if abs(side) >= NoMaskAvoid:
            continue                    # already clear of the corridor
          # push perpendicular, away from whichever side of the line I'm on
          # (dead-center picks the side my steer already leans toward). With
          # perp = (-dir.y, dir.x), a body displaced along +perp reads
          # cross(rel, dir) NEGATIVE — so flip on side > 0.
          var perp = vec(-ray.dir.y, ray.dir.x)
          if (if abs(side) > 1e-3: side > 0.0
              else: cross(steer, ray.dir) > 0.0):
            perp = perp * -1.0
          steer = steer + perp * ((NoMaskAvoid - abs(side)) / NoMaskAvoid) * 1.2
          when defined(nmprobe):
            inc nmRepel
      # Serpentine when a straight run would cross watched ground. Fog cuts
      # both ways: a fresh remembered enemy with a clear pixel line pins
      # anyone, and rushers crossing the contested MIDDLE weave even without
      # intel — the snipers watching their lane are exactly the enemies they
      # cannot see. Close threats are the jink/duck branches' job; carriers
      # and the pocket grab skip it — for them speed beats evasion.
      # A CARRIER now weaves too (carrierSerpentine): the slowest (70%), highest-value unit
      # is the one that most needs to break a map-wide hitscan's firing solution — but with a
      # SHALLOWER amplitude so net homeward progress is preserved (it must still reach home).
      let carrierWeaves = iCarry and bot.tune.carrierSerpentine
      if (not iCarry and not pocketRush) or carrierWeaves:
        var weave = false
        if rushing:
          weave = abs(me.x - float(CenterX)) < WeaveBand
        else:
          for t in bot.enemies:
            if bot.tick - t.lastSeen > UnderFireTrackTtl:
              continue
            let d = dist(t.pos, me)
            if d >= SerpentineNear and d <= SerpentineFar and
                client.pixelRayClear(me, t.pos):
              weave = true
              break
        if weave:
          var side = vec(-steer.y, steer.x)
          if (bot.tick div 8 + bot.slot div 2) mod 2 == 0:
            side = side * -1.0
          # Shallower weave for the carrier (0.35 vs 0.6) — dodge without stalling the run.
          steer = norm(steer) + side * (if carrierWeaves: 0.35 else: 0.6)
      steer = steer + vec(rand(-0.12 .. 0.12), rand(-0.12 .. 0.12))
      moveMask = octantBits(steer)
      if bot.tick < bot.jinkUntil:
        moveMask = bot.jinkBits            # unsticking burst
      # Carriers and the pocket-grab rusher keep the cone down their escape
      # lane — for them speed beats gunfighting, so the lock/hunt overrides skip.
      let mayHunt = not iCarry and not disarmedRush
      if desiredAim < 0 and mayHunt and bot.tune.aimLock and
          bot.tick <= bot.aimLockUntil:
        # ⭐ TARGET-LOCK: we hold a fresh enemy but have no clear shot THIS
        # frame (fogged, wall-blocked, or on cooldown). Do NOT snap the aim to
        # the movement lane — that surrenders a bearing we paid 5-brads/tick to
        # acquire and drops the enemy out of the cone. Keep the turret smoothly
        # pursuing the locked body so the moment the line clears we fire.
        desiredAim = bradsOf(bot.aimLockPos - me)
      elif desiredAim < 0 and mayHunt and bot.tune.huntSweep:
        # HUNTING POSTURE: no lock, but actively acquire — aim at the nearest
        # recently-remembered enemy rather than blindly down-lane.
        var best = -1
        var bestD = 1e18
        for i in 0 ..< bot.enemies.len:
          if bot.tick - bot.enemies[i].lastSeen > HuntSweepTtl:
            continue
          let d = dist(bot.enemies[i].pos, me)
          if d < bestD:
            bestD = d
            best = i
        if best >= 0:
          desiredAim = bradsOf(bot.enemies[best].pos - me)
        else:
          desiredAim = bradsOf(steer)
          deadband = CruiseDeadband
      if desiredAim < 0 and mayHunt and bot.tick <= bot.orientUntil and
          bot.orientPos.x >= 0:
        # CONTACT ORIENT: a mate's "oh shit!"/"die"/callout or an own-HP drop
        # from an unseen shooter gave us a bearing to face for a beat. With no
        # target of our own pulling the turret, swing the vision cone onto it
        # (turn-and-watch) so we pick the threat up instead of walking blind.
        desiredAim = bradsOf(bot.orientPos - me)
        deadband = CruiseDeadband
      if desiredAim < 0:
        # No target demands the turret: the aim leads the movement direction
        # so the vision cone watches down-lane where we are heading. Movement
        # no longer leaks our vision, so this is a choice, not a side effect.
        desiredAim = bradsOf(steer)
        deadband = CruiseDeadband

  # Stuck detection: if we have not moved for a second (and are not holding
  # behind cover on purpose), burst in a random direction and force a repath.
  if dist(me, bot.lastPos) < 0.8:
    inc bot.stuckTicks
  else:
    bot.stuckTicks = 0
  bot.lastPos = me
  if holdStill:
    bot.stuckTicks = 0
  if bot.stuckTicks > 20 and
      (engage < 0 or retreating or bot.tune.unstuckEngaged):
    bot.stuckTicks = 0
    bot.jinkUntil = bot.tick + 10
    bot.jinkBits = octantBits(vec(rand(-1.0 .. 1.0), rand(-1.0 .. 1.0)))
    bot.navGoal = -1
    if bot.jinkBits == 0:
      bot.jinkBits = ButtonUp
    moveMask = bot.jinkBits

  if nadeDanger:
    # Sprint straight out of the marked blast zone; drop any hold/duck.
    let away = me - nadeDangerFrom
    moveMask = octantBits(
      if len(away) < 1.0: vec(homeSign(bot.team), 0.3) else: away
    )
    holdStill = false

  if moveMask == 0 and not holdStill:
    moveMask = octantBits(vec(rand(-1.0 .. 1.0), rand(-1.0 .. 1.0)))

  when defined(carryDebug):
    if iCarry and abs(me.x - homeDeepX(bot.team)) < 320.0:
      echo "RUN t=", bot.tick, " slot=", bot.slot, " team=", bot.team,
        " me=", int(me.x), ",", int(me.y),
        " tgt=", int(target.x), ",", int(target.y),
        " mask=", moveMask, " stuck=", bot.stuckTicks,
        " eng=", engage, " retreat=", retreating
      flushFile(stdout)

  # Rotate toward the desired aim by the shortest arc; inside the deadband
  # (AimRate cannot settle tighter than +-AimRate/2) hold the turret still.
  var rotBits: uint8 = 0
  if desiredAim >= 0:
    # ⭐ GV36 SLOT SERVO. The aim occupies 32 discrete slots and a held rotate
    # steps aimTurnRate SLOTS per tick (league config: 5 slots = 40 brads =
    # 56 degrees). Proportional shortest-arc turning cannot settle: gcd
    # arithmetic means reaching an ADJACENT slot can take 13 ticks the long
    # way round, and a naive servo oscillates or parks 20 brads off — which
    # is why ranged gunfire died league-wide (measured on live physics: hit%
    # 0.0 past 300px, 83% of all shots under 150px). Plan in slot space: take
    # whichever direction reaches the desired slot in fewer held ticks, even
    # when that transiently widens the raw error.
    let
      sSlots = max(1, bot.aimStepBrads div 8)
      cur = ((bot.estAim + 4) div 8) mod 32
      des = ((desiredAim + 4) div 8) mod 32
      delta = ((des - cur) mod 32 + 32) mod 32
    if delta != 0:
      var kp = -1
      var km = -1
      for k in 1 .. 32:
        if kp < 0 and (k * sSlots) mod 32 == delta: kp = k
        if km < 0 and (k * sSlots) mod 32 == (32 - delta) mod 32: km = k
        if kp >= 0 and km >= 0: break
      # ⭐ SPINCAP (gated): with step 5 and gcd(5,32)=1, the EXACT plan for a
      # ±1-slot correction is 13 held ticks — 65 slots swept, two full BLIND
      # revolutions (the vision cone rides the aim), and the field-visible
      # "turret spinning the long way". When the exact plan exceeds the
      # budget, steer to the reachable slot with the least angular error
      # inside it (often: hold, accepting ≤1 slot = 11.25°) and let the
      # fire-gate slack + the target's own bearing drift close the rest.
      # ⭐ THE RANGE FORK: the budget's accepted residual is ANGULAR, the fire
      # corridor is LINEAR (perpMiss = D·sin err), so the same ≤2-slot residual
      # that is invisible at 60px is a permanent trigger LOCKOUT at 600px. Spend
      # the budget only where it is cheap; beyond spinCapRangePx pay the exact
      # plan so the error actually reaches 0 and the corridor opens. A traverse
      # with no shootable target (aimTargetD < 0) always keeps the budget — it
      # cannot cost a shot, and the blind multi-rev spin is pure vision loss.
      let spinBudgeted = bot.tune.spinCap and
        (aimTargetD < 0.0 or aimTargetD <= bot.tune.spinCapRangePx)
      var capped = false
      if spinBudgeted:
        const SpinCapTicks = 4
        let kbest = (if kp >= 0 and (km < 0 or kp <= km): kp
                     elif km >= 0: km else: 99)
        if kbest > SpinCapTicks:
          capped = true
          when defined(rngprobe): inc rpCap[ord(bot.team)]
          var bestJ = 0
          var bestErr = 99
          for jj in -SpinCapTicks .. SpinCapTicks:
            let net = (((cur + jj * sSlots - des) mod 32) + 32) mod 32
            let e = min(net, 32 - net)
            if e < bestErr or (e == bestErr and abs(jj) < abs(bestJ)):
              bestErr = e
              bestJ = jj
          when defined(rngprobe): rpCapErr[ord(bot.team)] += bestErr
          if bestJ > 0: rotBits = ButtonB
          elif bestJ < 0: rotBits = ButtonSelect
      if not capped:
        if kp >= 0 and (km < 0 or kp <= km): rotBits = ButtonB
        elif km >= 0: rotBits = ButtonSelect

  # Only a FRESH A press fires, and the pull locks the aim angle on the same
  # tick — never rotate on the pull tick so the lock takes the settled aim.
  # ⛔ CQB PLANT was here — MEASURED AND REVERTED (2026-08-04). 12-game frozen
  # A/B: moving-while-firing 63% -> 0.1% (mechanism perfect) and CQB hit%
  # 36.0 -> 36.1 (NO effect), while shots -19%, hits -25%, kills -34%,
  # deaths +34%, W-L-D 1-9-2. The REF-slack failure plus a stationary-target
  # penalty. The field's plant/hit correlation was a SIDE-COMPOSITION
  # confound (within-side gradient only 8pp). Movement was never the cause.
  when defined(carrytrace):
    if iCarry and bot.tick mod 60 < 2:
      stderr.writeLine "CARRY slot=" & $bot.slot & " t=" & $bot.tick &
        " me=" & $int(me.x) & "," & $int(me.y) &
        " target=" & $int(target.x) & "," & $int(target.y) &
        " hp=" & $bot.ownHp & " engage=" & $engage &
        " homeDeepX=" & $int(homeDeepX(bot.team)) &
        " ownHome=" & $int(ownHome.x) & "," & $int(ownHome.y)
  var mask = moveMask or rotBits
  if wantFire and not bot.firedLast:
    mask = moveMask or ButtonA
    when defined(rngprobe):
      if rpBand >= 0: inc rpFire[rpSide][rpBand]
  when defined(rngprobe):
    rpBand = -1
    # Live-server dump: the bot processes are SIGTERM'd by the A/B script, so
    # write a running tally every 500 ticks and read the LAST line per slot.
    inc rpCalls
    if rpCalls mod 50 == 0:
      var s = "RNG slot=" & $bot.slot & " t=" & $bot.tick & " calls=" & $rpCalls
      let sd = ord(bot.team)
      for b in 0 .. 4:
        s.add " b" & $b & "=" & $rpFrames[sd][b] & "/" & $rpOpen[sd][b] & "/" &
          $rpFire[sd][b] & "/" & $rpErrSum[sd][b] & "/" & $int(rpDistSum[sd][b])
      s.add " cap=" & $rpCap[sd] & " capErr=" & $rpCapErr[sd]
      stderr.writeLine s
      flushFile(stderr)
  if nadeC:
    mask = mask or ButtonC
  bot.firedLast = (mask and ButtonA) != 0
  bot.rotSign =
    if (mask and ButtonB) != 0: 1
    elif (mask and ButtonSelect) != 0: -1
    else: 0

  # ── COMMS BUS emit (highest priority, shares the one shout slot): when we
  # classified a live team scenario (STACK/WIPE/PEEL — a LOCAL read a mate may
  # not see), broadcast its opaque rotating codeword "P<tok>" so the squad
  # converges. Emit-only + mask-neutral (staged in shoutWant AFTER the mask is
  # finalized, exactly like the vanity shouts — proven not to perturb aim/move).
  # Consumes the shared shout slot (updates lastShoutTick) so it wins over vanity
  # this frame. Own CommsEmitCooldown keeps it to a play-beat, not per-frame spam.
  if bot.tune.commsBus and localSc != ScNone and
      bot.tick - bot.lastShoutTick >= ShoutGapTicks and
      bot.tick - bot.lastCommsTick >= CommsEmitCooldown:
    let salt = roundSalt(bot.gameStart, bot.team, bot.tune.commsCrypto)
    let clockFlank = selectPlay(bot.tick - bot.gameStart, ownStolen)
    let rp = scenarioToPlay(localSc, clockFlank)
    if rp != RpNone:
      bot.shoutWant = "P" & $commsToken(rp, salt)
      bot.lastShoutTick = bot.tick
      bot.lastCommsTick = bot.tick
      when defined(commsprobe):
        inc csEmit

  # ── Team shout emit (one channel, server-capped ~1/s): pick the single
  # highest-value message this frame and stage it in shoutWant for the caller
  # to send. Priority: a close-range ambush ("oh shit!") > a pre-fire warning
  # ("die") > enemy position callouts ("E <cell>..") > the carrier's own-
  # position heartbeat ("C<cx> <cy>"). Each flavor has its own cooldown so none
  # spams; ShoutGapTicks (> the server's ShoutCooldownTicks) keeps us under the
  # cap. Every flavor is independently gated so the harness can A/B one at a
  # time; the whole emitter is off unless tune.shout.
  if bot.tune.shout and bot.shoutWant.len == 0 and
      bot.tick - bot.lastShoutTick >= ShoutGapTicks:
    var say = ""
    if bot.tune.shoutSurprise and surprisePos.x >= 0 and
        bot.tick - bot.surpriseShoutTick >= SurpriseShoutCooldown:
      # Consume the cooldown window whether or not we actually yell, then emit
      # on only VanityShoutChance% of windows — otherwise the roll just re-fires
      # every frame and the cooldown stays the real (spammy) throttle.
      bot.surpriseShoutTick = bot.tick
      if vanityRoll(bot.slot, bot.tick, 1):
        say = "oh shit!"
    elif bot.tune.shoutDie and (mask and ButtonA) != 0 and
        bot.tick - bot.dieShoutTick >= DieShoutCooldown:
      # We are opening fire this tick: warn a nearby friendly so they take
      # cover or look our way and help finish the kill.
      var mateNear = false
      for t in bot.mates:
        if bot.tick - t.lastSeen <= LocalFreshTicks and
            dist(t.pos, me) <= DieEarshot:
          mateNear = true
          break
      if mateNear:
        # Same rare-flavor gate: consume the window, emit ~VanityShoutChance%.
        bot.dieShoutTick = bot.tick
        if vanityRoll(bot.slot, bot.tick, 2):
          say = "die"
    if say.len == 0 and bot.tune.shoutCallout:
      # Enemy callout: name the nearest fresh enemy cells on the chess grid so
      # mates who cannot see them swing their cones over. Dedupe cells and cap
      # the count so the address fits the 10-char shout.
      var chosen: seq[Track] = @[]
      for t in bot.enemies:
        if bot.tick - t.lastSeen <= CalloutFreshTicks:
          chosen.add t
      chosen.sort(proc(a, b: Track): int =
        cmp(dist(a.pos, me), dist(b.pos, me)))
      var cells: seq[string] = @[]
      for t in chosen:
        let c = chessCell(t.pos)
        if c notin cells:
          cells.add c
        if cells.len >= CalloutMaxCells:
          break
      if cells.len > 0:
        say = "E " & cells.join(" ")
    if say.len == 0 and iCarry and bot.tune.shoutCallout:
      # Carrier heartbeat: our own 8px-grid position so escorts converge. This
      # is STRATEGIC comms (broadcasts the carrier's exact spot — a position
      # tell to any shout-parsing enemy, since the bubble is range-audible to
      # both teams), so it rides shoutCallout, NOT the bare shout master: the
      # vanity-only champion (shout+surprise+die, callout off) must NOT leak the
      # carrier. It only ever HELPED when escorts reacted (reactContact), which
      # the shelved-comms champion also runs off — so off it's pure cost.
      say = "C" & $(int(me.x) div 8) & " " & $(int(me.y) div 8)
    if say.len > 0:
      bot.shoutWant = say
      bot.lastShoutTick = bot.tick

  mask

proc runBot(url: string) =
  ## Connects, then loops frames forever, reconnecting on disconnect.
  let
    slot = slotFromUrl(url)
    team = (if slot mod 2 == 0: Team.Red else: Team.Blue)
    role = roleForSeat(clamp(slot div 2, 0, 7), team)
      # provisional: GameTeams is unknown until the init markers land, so this
      # is the 2-team reading. buildNavGrid re-derives it once teams are stated.
    endpoint = ensureWsPath(url, WebSocketPath)
  randomize(slot * 7919 + 1)
  let bot = Bot(slot: slot, team: team, role: role, tune: shippedCombatTune(),
                aimStepBrads: 40, prevStatedAim: -1, nadeLockAim: -1,
                myColor: (if team == Red: "red" else: "blue"))
    # myColor is only the slot-PARITY guess here: the team count is not known
    # until the init markers arrive. buildNavGrid re-deals it on a 4-team board
    # and the self marker locks the truth on the first alive frame.
  SelfStrategyTeam = team
  SelfColor = bot.myColor
  bot.resetTransient()
  echo "baseline slot=", slot, " team=", team, " role=", role, " -> ", endpoint
  let client = initProtocolClient()
  var everConnected = false
  while true:
    try:
      let ws = newWebSocket(endpoint)
      echo "connected ", endpoint
      everConnected = true
      # ⛔ sprites-off (0x87) MEASURED AND HELD (2026-08-04): pooled 16-game
      # frozen A/B vs this same build without it — shots/kills flat, but
      # deaths +14% (9.9 -> 11.3/g), the one delta that SURVIVED doubling the
      # sample. Every channel we read is kept by design, so the mechanism is
      # unidentified (suspects: a subtle dropped-FX interaction, or speed-16
      # readiness micro-timing that would not exist live). A no-op claim must
      # measure flat; this did not. Helper stays; revisit if the fleet makes
      # it mandatory or a live-speed test exonerates it.
      client.reset()
      bot.navBuilt = false
      bot.resetTransient()
      var lastMask = 0xff'u8
      while true:
        if not client.receiveLatestFrame(ws, false):
          continue
        let advance = max(1, client.frameAdvance)
        bot.tick += advance
        # Dead-reckon the aim: the last sent mask keeps rotating on the
        # server for every elapsed sim tick until we change it.
        bot.estAim = floorMod(
          bot.estAim + bot.rotSign * bot.aimStepBrads * advance, AimBrads)
        if not client.mapCameraReady:
          bot.resetTransient()             # lobby / game-over interstitial
          continue
        if not bot.navBuilt and client.walkabilityReady:
          when defined(perfprobe):
            let ppN0 = getMonoTime()
            bot.buildNavGrid(client)
            ppNavBuildNs += (getMonoTime() - ppN0).inNanoseconds
          else:
            bot.buildNavGrid(client)
        when defined(perfprobe):
          let ppT0 = getMonoTime()
        let mask = bot.decide(client)
        when defined(perfprobe):
          ppDecideNs += (getMonoTime() - ppT0).inNanoseconds
          inc ppFrames
          if ppFrames mod 200 == 0:
            stderr.writeLine "PERF slot=" & $bot.slot &
              " map=" & $MapW & "x" & $MapH & " cells=" & $(GridW * GridH) &
              " frames=" & $ppFrames &
              " decide_avg_us=" & $(ppDecideNs div ppFrames div 1000) &
              " field_calls=" & $ppFields &
              " field_avg_us=" & $(if ppFields > 0: ppFieldNs div ppFields div 1000 else: 0) &
              " navbuild_ms=" & $(ppNavBuildNs div 1_000_000)
        if mask != lastMask:
          ws.send(inputBlob(mask), BinaryMessage)
          lastMask = mask
        # decide() stages at most one shout per frame (already self-rate-limited
        # under the server cap, and only ever set when tune.shout is on).
        if bot.shoutWant.len > 0:
          ws.send(chatBlob(bot.shoutWant), BinaryMessage)
          bot.shoutWant = ""
    except Exception as e:
      if everConnected:
        # The game ended and the server went away: exit so the episode
        # runner sees a clean player shutdown.
        echo "game over, exiting: ", e.msg
        quit(0)
      echo "connect retry: ", e.msg
      sleep(250)

when isMainModule and not defined(ctfEvalHarness):
  # The eval harness `include`s this file to drive the BYTE-IDENTICAL decision
  # path in-process; -d:ctfEvalHarness suppresses only this WS entrypoint so
  # the shipped player build (no such define) is completely unchanged.
  let url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if url.len == 0:
    raise newException(ValueError, "COWORLD_PLAYER_WS_URL is required.")
  runBot(url)
