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

import
  std/[algorithm, heapqueue, math, os, random, strutils],
  bitworld/spriteprotocol,
  whisky,
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

const
  WebSocketPath = "/player"
  RenderScale = 1             # 0.7.8 renderer restore: the wire is back to 1x
                              # Object coordinates and sprite sizes arrive
                              # multiplied by this; sprites stay centered on
                              # the same map points, so dividing the object
                              # center recovers exact legacy map coordinates.
  MapW = 1235
  MapH = 659
  CenterX = MapW div 2
  CenterY = MapH div 2
  PlayerHalf = 6              # solid footprint half-extent, matches the sim
  MuzzleBloomSize = 7         # staggerFire: the muzzle-flash sprite is 7px, drawn
                              # at a shooter's origin for the reload window; mirrors
                              # global.MuzzleBloomSize (player doesn't import ctf/global)
  NavCell = 8                 # nav grid cell size in px
  GridW = (MapW + NavCell - 1) div NavCell
  GridH = (MapH + NavCell - 1) div NavCell
  RepathTicks = 10            # refresh the cost field at least this often
  LookaheadCells = 6          # how far ahead on the path we aim the waypoint

  FireRange = 1250.0          # engage distance (the 1300px gun is map-wide)
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
  MateAimRayLen = 700.0       # trust a mate's aim line out to this range
  MateAimHitSlack = 22.0      # enemy within this perpendicular distance of a
                              # mate's aim ray counts as mate-targeted
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
  NadeMaxRange = 247.0        # full-charge throw distance = MapWidth div 5 (GV17
                              # engine truth; was a stale 240 → slight over-charge)
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
  ShieldGrabDetour = 120.0    # shieldTank: an escort grabs a shield within this detour.
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
  FireSlackPx = 11.0          # fire when the aim error's perpendicular miss
                              # at the target's range is inside this (the
                              # corridor half-width is ~14px; keep margin)
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
  ArcBreachSeek = 260.0       # grab an arc pickup within this detour when a line is live
  ArcBreachFireReach = 128.0  # fire the cone when a fresh enemy sits within this (just
                              # inside the engine's 136px reach, a margin for our aim/step)
  ArcBreachConeBrads = 12     # press attack when the target is within this of our aim
                              # (the ~14° half-cone; be on-bearing so the cone lands)
  ArcCarryRadius = 48.0       # attribute the "plasma arc carried" marker (floats
                              # ABOVE the head, higher than the hp pip) to the nearest
                              # actor within this — bigger than HpPipRadius(22) for the
                              # extra vertical offset. Verify empirically via cAprobe.
  AimOnConeBrads = 32         # aimThreat: gun bearing within this many brads of the
                              # line to us counts as "aimed at us" (~45°, generous
                              # since the enemy is still turning toward us). Beyond
                              # this the gun points elsewhere = a lesser threat.
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
  LatePushTick = 6800         # all-in on the clock: past this tick a draw is
                              # the default outcome, so commit to the capture

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
  ShoutHeardRange = 247.0     # ShoutRange (MapWidth div 5): reaction radius when
                              # WE hear a mate's contact shout
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
  LaneMid = float(CenterY)
  LaneBottom = 619.0          # open corridor below the mirrored obstacles
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
    carrierSprint: false,     # control: carrier fights (engage 110px) instead of running.
    carrierScreen: false,     # control: escort screens remembered threats, not the cone.
    carrierGrabDetect: false, # control: self-carry only when heart >16px off pedestal.
    dangerScore: false,       # control: flat facing tiebreak only (threatFacingBonus).
    twoSpeedScan: false,      # control: sentry sweep rakes past the hot bearing.
    boundingOverwatch: false, # control: advance across open ground even on cooldown.
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
    swordAmbush: false,       # control: a boxed-in bot never grabs a sword for a melee kill.
    medTopOff: false,         # control: a wounded bot never detours to a center med kit.
    satCap: false,            # control: a free gun dogpiles the nearest enemy, no saturation cap.
    noMask: false,            # control: a mover walks through a mate's live gun-line.
    assaultThrough: false,    # control: a surprise at knife range triggers the retreat/duck jink.
    offCone: false,           # control: an attacker beelines straight down the enemy's gun axis.
    fatalFunnel: false,       # control: an idle sentry two-speed-sweeps, never pre-lays the chokepoint.
    aimRotRead: false,        # control: aim intel comes only from the dead "aim dot" labels (none on v9).
    arcBreach: false,         # control: no bot ever grabs the plasma arc offensively to cone a line.
    gv21Press: false,         # control: fire-superiority break uses the standard outnumberMargin.
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
  result.tempoPress = true
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
  result.satCap = true
  result.noMask = true
  result.assaultThrough = true
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
  result.grabGate = true
  result.grabTiming = true
  result.regroupPush = true
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
  # ⚠️ arcBreach STAYS OFF in the shipped tune (2026-07-22). Unlike every other lever
  # here it has a real DOWNSIDE if it misfires — the breacher trades its gun for its
  # life, so an arc grabbed with no line to cone is a dead-weight disarmed body. It
  # fired 0 in the TURTLE line test (arc spawns sit at the far map x-edges, y=1/4
  # height; the trailing MidGuard breacher rarely reaches the 260px seek while a line
  # is live AND in earshot), so there is NO evidence it helps and a clear way it hurts.
  # "Code it right" > "ship it on": kept behind the ARCBREACH knob for a dedicated
  # hosted A/B, NOT baked. Re-enable only after a hosted xreq shows a positive delta.
  # result.arcBreach = true   # deliberately not enabled — see above
  # ── ⭐ GV21 AGGRESSION (v18 candidate, 2026-07-23). The hosted A/B proved v17 LOSES
  # to h006 (30-50) by getting out-killed −6 in open combat, and the engine moved to
  # GV21 (spawn-protection DELETED → fresh respawners killable; draws −1; 5000-tick
  # clock) — the win economy now demands decisive KILLS/wipes and punishes our patient
  # doctrine. gv21Press widens the fire-superiority break threshold so a lone gun keeps
  # trading through a 1-gun deficit instead of ceding the firefight the clock forces us
  # to win. Being A/B'd vs h006 (+daveey) seat-rotated as the v18 candidate.
  result.gv21Press = true

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

proc findSelf(
    client: ProtocolClient, color: string): tuple[alive: bool, pos: Vec] =
  ## Our avatar via the distinct self marker, only drawn while we are alive.
  for facingRight in [true, false]:
    let label = "self " & color & (if facingRight: " right" else: " left")
    for o in client.spriteObjectsWithLabel(label):
      return (alive: true, pos: client.mapPos(o))

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
  for o in client.spriteObjectsWithLabel("plasma arc carried"):
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
  for o in client.spriteObjectsWithLabel("shield carried"):
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

proc homeDeepX(team: Team): float =
  ## A point well inside our capture zone (Red x <= ~206, Blue x >= ~1029).
  ## Blue mirrors Red exactly across the x = 617 center line.
  if team == Red: 150.0 else: float(MapW - 1) - 150.0

proc enemy(team: Team): Team =
  ## The opposing team.
  if team == Red: Blue else: Red

proc flagHome(team: Team): Vec =
  ## The STATIC pedestal position of one team's flag: the center of the
  ## team's protected spawn pocket (matches flagHome in src/ctf/sim.nim).
  if team == Red: vec(186, 329) else: vec(1049, 329)

proc chokeSpot(team: Team): Vec =
  ## Defender hold point between the flag and our home edge, mirrored
  ## exactly across the x = 617 center line.
  if team == Red: vec(390, 340) else: vec(float(MapW - 1) - 390.0, 340)

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

const DominateApproach = [   # #7: the ground an intruder MUST cross to reach
                             # our pedestal — waypoints on the three lanes at the
                             # mid line and just inside our half, mirrored per
                             # team via homeSign. These are where the occupancy
                             # heatmap shows enemy travel concentrates (mid
                             # crossings feeding the pedestal pocket).
  (0.0, LaneTop), (0.0, LaneMid), (0.0, LaneBottom),      # the mid crossing
  (170.0, LaneTop), (170.0, LaneMid), (170.0, LaneBottom) # just inside our half
]

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
      for w in DominateApproach:
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

proc buildNavGrid(bot: Bot, client: ProtocolClient) =
  ## Erodes the pixel walkability mask into a footprint-safe nav grid, then
  ## derives the cover model (cover cells, overwatch post, defender choke).
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

proc computeField(bot: Bot, client: ProtocolClient, goal: int) =
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
  bot.enemies.setLen(0)
  bot.mates.setLen(0)
  bot.nadeCharge = 0
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
  bot.assaultUntil = -100_000
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
  let
    myColor = (if bot.team == Red: "red" else: "blue")
    enemyColor = (if bot.team == Red: "blue" else: "red")
    (alive, me) = client.findSelf(myColor)
  if not alive:
    # Dead: the view is fully fogged (only our corpse renders) and inputs
    # are ignored, so skip perception entirely.
    bot.firedLast = false
    bot.rotSign = 0
    bot.wasDead = true
    return 0
  if bot.wasDead:
    # Respawned: the server points the aim back at the enemy side.
    bot.wasDead = false
    bot.estAim = spawnAim(bot.team)
  # Absolute turret fix: our own rendered aim-indicator dots show the actual
  # aim every frame, capping any dead-reckoning drift (mask-apply races).
  block resync:
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
    shotReady = client.spriteObjectsWithLabel("fire icon").len > 0
    seenEnemies = client.actorsFor(enemyColor, bot.tune.aimRotRead)
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
      if a.aimBrads >= 0:
        surpriseGunOnMe =
          abs(bradsErr(a.aimBrads, bradsOf(me - a.pos))) <= AimOnConeBrads
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
    for o in client.spriteObjectsWithLabel("shot sound"):
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
    stealTarget = flagHome(enemy(bot.team))  # the enemy pedestal is static
    ownHome = flagHome(bot.team)
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
      # Count fresh enemy guns + fresh mates near the contested pocket / us.
      var freshEnemyNear = 0
      var freshMateNear = 0
      for t in bot.enemies:
        if bot.tick - t.lastSeen <= LocalFreshTicks and
            (dist(t.pos, stealTarget) <= CommsScanRange or
             dist(t.pos, me) <= CommsScanRange):
          inc freshEnemyNear
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
    if bot.tune.carrierClearBand:
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
        target = vec(homeDeepX(bot.team), laneY)
    elif abs(me.x - pocket.x) < 60.0 and abs(me.y - laneY) > 70.0:
      # Bug out of the pocket VERTICALLY first: every kill respawns an
      # armed, spawn-protected enemy at this pedestal whose spawn aim points
      # along the east-west axis — pure-vertical movement exits that cone
      # fastest, then the border lane runs home outside it.
      target = vec(pocket.x, laneY)
    else:
      target = vec(homeDeepX(bot.team), laneY)
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
      if abs(me.x - homeDeepX(bot.team)) < CarrierFinishBand:
        when defined(hsprobe):
          inc hsFireCount
          if abs(target.y - me.y) > 0.5: inc hsMovedCount
        target = vec(homeDeepX(bot.team), me.y)
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
  let wantPocketRush = not iCarry and not mateCarry and
    bot.role in {MidTop, MidBottom, MidGuard, FlankTop, FlankBottom} and
    dist(me, stealTarget) < PocketRushRange and
    dist(me, stealTarget) < nearestMateToSteal + 8.0
  # ⭐ grabTiming (2026-07-20, the dive-death finding): a solo unarmed dive into a
  # STACKED pocket is shot on the touch (96% of our carrier deaths are here, 0%
  # cap in every loss). When the pocket is stacked, no mate is covering us in
  # place, and a mate is genuinely inbound, HOLD short: pocketRush goes false so
  # we revert to the normal rusher combat path (gun UP — every aim/duck/lock
  # branch gates on `not pocketRush` — suppressing the KILLABLE defenders) and we
  # pin the move target at a standoff ring off the pedestal until cover arrives.
  # Self-limiting and anti-timidity by construction: a lone last body (no inbound
  # mate) still dives NOW, cover-in-place releases the dive, pushOut/late all-in
  # suicide-grabs as today, and inside GrabCommitRing we're committed and dive
  # through. DELAYS/SEQUENCES the dive, never abandons the objective.
  var holdGrab = false
  if bot.tune.grabTiming and wantPocketRush and not pushOut and
      dist(me, stealTarget) > GrabCommitRing:
    var defenders = 0        # fresh enemy guns clustered on the pedestal
    for t in bot.enemies:
      if bot.tick - t.lastSeen <= LocalFreshTicks and
          dist(t.pos, stealTarget) <= GrabStackRange:
        inc defenders
    var coverMates = 0       # a fresh mate at the pocket with us = cover in place
    var inboundMates = 0     # a fresh mate homeward of us = genuinely inbound support
    for t in bot.mates:
      # GrabMateFreshTicks, not LocalFreshTicks: mates approach from BEHIND the
      # diver's pocket-welded vision cone, so their tracks are stale-but-real.
      if bot.tick - t.lastSeen > GrabMateFreshTicks: continue
      if dist(t.pos, me) <= GrabCoverRange: inc coverMates
      if homeSign(bot.team) * (t.pos.x - me.x) > GrabInboundGap: inc inboundMates
    holdGrab = defenders >= GrabStackDefenders and coverMates < 1 and inboundMates >= 1
    when defined(gtprobe):
      inc gtEligible
      if defenders >= GrabStackDefenders: inc gtStacked
      if defenders >= GrabStackDefenders and coverMates < 1: inc gtNoCover
      if holdGrab: inc gtFireCount
  when defined(gtprobe):
    if wantPocketRush: inc gtWant

  # ⭐ grabGate (2026-07-22, the h006 grab-discipline finding): h006 commits to the
  # heart almost only when up bodies (steal->cap 46-64%); Picasso grabs even/behind
  # and 72-82% of our carriers die at the enemy pedestal — the diagnosed suicide-grab.
  # Distinct from grabTiming (which holds on an ABSOLUTE stack >=2 with a mate inbound):
  # grabGate is a RELATIVE numbers gate — it opens the dive when OUR local force (me +
  # inbound support) can beat the defense, and holds only when genuinely OUTGUNNED at
  # the touch. So grabGate is LESS timid than grabTiming when support is present (it
  # dives into a stack we have the bodies to convert = the h006 "grab when +bodies"
  # doctrine) and gates a single defender we can't beat. Teammates are fogged, so the
  # rusher (frontmost body by construction: dist<nearestMate+8) counts INBOUND support
  # homeward of it — NOT mates "at the pedestal" (structurally ~0, the falsified-proxy
  # trap that made the first cut FIRE 0), and NEVER a global headcount (forceBalance).
  # Carve-outs mirror grabTiming: a lone last body (no inbound support) dives NOW,
  # pushOut / inside-GrabCommitRing dive through. DELAYS the open on numbers; never abandons.
  if bot.tune.grabGate and wantPocketRush and not pushOut and
      dist(me, stealTarget) > GrabCommitRing and not holdGrab:
    var pocketEnemies = 0    # fresh enemy guns clustered on the pedestal = the defense
    for t in bot.enemies:
      if bot.tick - t.lastSeen <= LocalFreshTicks and
          dist(t.pos, stealTarget) <= GrabGateEnemyRange:
        inc pocketEnemies
    var inboundMates = 0     # fresh mates homeward of me within support range = the wave
    for t in bot.mates:      # coming to convert the grab (GrabMateFreshTicks: they close
      if bot.tick - t.lastSeen > GrabMateFreshTicks: continue   # from behind our cone)
      if homeSign(bot.team) * (t.pos.x - me.x) > GrabInboundGap and
          dist(t.pos, me) <= GrabGateMateRange: inc inboundMates
    # Our local force at the touch = me + the inbound support wave. Outgunned when the
    # defense beats it by the deficit margin — the exact suicide-grab state.
    let ourForce = 1 + inboundMates
    let outgunned = (pocketEnemies - ourForce) >= GrabGateDeficit
    # Lone-last-body carve-out: no inbound support => nobody is coming to convert, so a
    # solo dive NOW still forces the enemy onto defense (identical to grabTiming's rule).
    if outgunned and inboundMates >= 1:
      holdGrab = true
    when defined(ggprobe):
      inc ggEligible
      if outgunned: inc ggOutgun
      if outgunned and inboundMates >= 1: inc ggFireCount
  when defined(ggprobe):
    if wantPocketRush: inc ggWant

  if holdGrab:
    # Hold the gun up at a standoff ring off the pedestal (outside the defenders'
    # tightest cover) and suppress from there instead of diving unarmed.
    target = stealTarget + norm(me - stealTarget) * GrabHoldStandoff
  let pocketRush = wantPocketRush and not holdGrab

  # Combat: the nearest fresh track with a clear pixel ray AND a mate-free
  # fire cone is the engage target; the nearest fresh-but-wall-blocked track
  # is the peek candidate. The map-wide gun engages fresh tracks far beyond
  # the view, so chases keep killing after the target leaves the window —
  # but objective play caps the range: the carrier only fights point-blank,
  # rushers racing for the steal and escorts guarding a run only fight what
  # is actually in the way, instead of frag-chasing across the map.
  let maxEngage =
    if pocketRush: 0.0
    elif iCarry and bot.tune.carrierSprint: 0.0  # ⭐⭐ carrier never fights:
      # the diagnosis showed carriers survive ~110t but travel ~4% of the run —
      # PINNED firing at the invulnerable spawn-protected respawner (wasted) while
      # advancing into the nest. Engage 0 drops the combat branch so the carrier
      # pure-navigates home at full speed, turret free (still nav-steered).
    elif iCarry: bot.tune.carrierFireRange
    elif rushing: bot.tune.rushEngageRange
    elif mateCarry: bot.tune.escortEngageRange
    else: bot.tune.fireRange
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
    let predicted = t.pos + t.vel * (float(bot.tick - t.lastSeen) + bot.tune.leadTicks)
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
    let saturated = bot.tune.satCap and mateGuns[i] >= satNeed
    when defined(scprobe):
      if bot.tune.satCap:
        if mateGuns[i] >= 1: inc scCov1
        if mateGuns[i] >= 2: inc scCov2
        if t.hp == 1: inc scHp1
    if saturated:
      anySaturated = true
      prio += SatCapPenalty
    else:
      if t.hp in 1 ..< MaxHp:
        prio -= float(MaxHp - t.hp) * HpFocusBonus
      if mateTargeted[i]:
        prio -= FocusFireBonus
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
      if aimErr <= AimOnConeBrads:
        let tight = clamp(
          float(AimOnConeBrads - aimErr) /
            float(AimOnConeBrads - AimDeadOnBrads), 0.0, 1.0)
        aimScale = 0.4 + 0.6 * tight     # 0.4 on-cone floor → 1.0 dead-on
      else:
        aimScale = 0.0                   # gun points elsewhere: no threat now
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
        prio -= (AimThreatBonus + DangerCloseBonus * closeFrac) * aimScale
        if t.hp in 1 ..< MaxHp:
          prio -= DangerWoundedBonus * aimScale
    elif bot.tune.threatFacingBonus:
      if facingMe:
        prio -= AimThreatBonus
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
      prio -= CounterArcBonus
      when defined(caprobe): inc caBump
    # Target commitment: heavily favour the enemy we are already engaged with
    # (matched by its last-known position) so three shots land on ONE target
    # and kill it, rather than one shot each spread across many wounded ones.
    if bot.tune.commit and bot.tick <= bot.lockUntil and
        dist(t.pos, bot.lockPos) <= LockMatchDist:
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
  for o in client.spriteObjectsWithLabel("grenade carried"):
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
  elif not carryingNade and not iCarry and not mateCarry and not pocketRush:
    # Collect a pickup: anyone grabs one within a short detour, and the two
    # flankers own their lane's friendly-side corner spawn — it sits right on
    # their border route, so they arm up on the way out every respawn cycle.
    for o in client.spriteObjectsWithLabel("grenade"):
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
  for o in client.spriteObjectsWithLabel("shield carried"):
    if dist(client.mapPos(o), me) <= 30.0:
      iHaveShield = true
      break
  for o in client.spriteObjectsWithLabel("sword carried"):
    if dist(client.mapPos(o), me) <= 30.0:
      iHaveSword = true
      break
  for o in client.spriteObjectsWithLabel("plasma arc carried"):
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
  if bot.tune.avoidDisarm:            # the real disarm object on v15
    for o in client.spriteObjectsWithLabel("plasma arc"):
      let p = client.mapPos(o)
      if p.x < 40.0 or p.y < 40.0 or p.x > float(MapW - 40) or p.y > float(MapH - 40):
        continue
      plasmaPickups.add(p)
  if bot.tune.shieldTank:             # shield still = 6-HP wall (no longer a disarm)
    for o in client.spriteObjectsWithLabel("shield"):
      let p = client.mapPos(o)
      if p.x < 40.0 or p.y < 40.0 or p.x > float(MapW - 40) or p.y > float(MapH - 40):
        continue
      shieldPickups.add(p)
  # shieldTank: an escort with our heart stolen and a shield in easy reach grabs
  # it to become a fat body-block on the carrier's cone (it can't shoot anyway).
  var seekingPickup = false
  if bot.tune.shieldTank and not iHaveShield and not iHaveSword and
      not iCarry and mateCarry and
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
  # heard) and we are the designated breacher seat, grab a plasma-arc pickup so we
  # can cone the clustered line. Deliberately trades our gun (canFire=false while
  # holding) — a specialist swap, so ONLY the fixed breacher seat, ONLY on a live
  # line, ONLY when not carrying/escorting/defending. The FIRE half is in the mask
  # block below (a sibling of the sword-melee swing). The pickup scan is its own so
  # it doesn't depend on avoidDisarm populating plasmaPickups.
  let teamSeat = clamp(bot.slot div 2, 0, 7)
  let iAmBreacher = bot.tune.arcBreach and teamSeat == ArcBreachSeat
  if iAmBreacher and not iHavePlasma and not iCarry and not mateCarry and
      not ownStolen and lineLive and not seekingPickup:
    var best = ArcBreachSeek
    for o in client.spriteObjectsWithLabel("plasma arc"):
      let p = client.mapPos(o)
      if p.x < 40.0 or p.y < 40.0 or p.x > float(MapW - 40) or p.y > float(MapH - 40):
        continue                                  # HUD indicator shares the label
      let d = dist(p, me)
      if d < best:
        best = d
        target = p
        seekingPickup = true
    when defined(commsprobe):
      if seekingPickup: inc csArcSeek

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
    for o in client.spriteObjectsWithLabel("med kit"):
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
      if haveKit or client.spriteObjectsWithLabel("med kit").len > 0: inc mtVisible
    if haveKit:
      target = chosen
      when defined(mtprobe): inc mtFireCount

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
  if bot.nadeCharge > 0 or nadeAim >= 0:
    # Charge-throw: lay the turret on the lob line, then hold C for the ticks
    # the planned distance needs and release — the grenade leaves along the
    # CURRENT aim on release, so the turret keeps correcting while charging.
    if bot.nadeCharge == 0:
      bot.nadeNeed = max(3, int(float(NadeFullChargeTicks) *
        (nadeThrowD - 30.0) / (NadeMaxRange - 30.0)))
    if nadeAim >= 0:
      desiredAim = nadeAim
    if bot.nadeCharge > 0 or (desiredAim >= 0 and
        abs(bradsErr(desiredAim, bot.estAim)) <= CombatDeadband + 2):
      if bot.nadeCharge < bot.nadeNeed:
        nadeC = true
        inc bot.nadeCharge
      else:
        bot.nadeCharge = 0           # release this tick = the throw
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
    var bestCluster = 0
    var bestAim = -1
    var bestTgt: Vec
    for i in 0 ..< bot.enemies.len:
      if bot.tick - bot.enemies[i].lastSeen > bot.tune.freshShotTicks:
        continue
      let tp = bot.enemies[i].pos
      if dist(tp, me) > ArcBreachFireReach:
        continue
      if not client.pixelRayClear(me, tp):     # the cone needs clear LOS (sim gates it)
        continue
      var cluster = 1
      for j in 0 ..< bot.enemies.len:
        if j != i and bot.tick - bot.enemies[j].lastSeen <= bot.tune.freshShotTicks and
            dist(bot.enemies[j].pos, tp) <= PlasmaArcReachPx:
          inc cluster
      if cluster > bestCluster:
        bestCluster = cluster
        bestTgt = tp
        bestAim = bradsOf(tp - me)
    if bestAim >= 0:
      desiredAim = bestAim
      moveMask = octantBits(bestTgt - me)      # close to keep the cluster in the cone
      let err = abs(bradsErr(desiredAim, bot.estAim))
      wantFire = err <= ArcBreachConeBrads     # on-bearing so the cone covers them
      when defined(commsprobe):
        if wantFire: inc csArcFire
    else:
      # Armed but no target in reach yet: advance toward the called line/nearest foe.
      var nd = 1e18
      for i in 0 ..< bot.enemies.len:
        if bot.tick - bot.enemies[i].lastSeen > bot.tune.freshShotTicks: continue
        let dd = dist(bot.enemies[i].pos, me)
        if dd < nd:
          nd = dd
          moveMask = octantBits(bot.enemies[i].pos - me)
    acted = true
  elif engage >= 0 and shotReady:
    # Traverse onto the target and fire once the corridor covers it: the
    # perpendicular miss of the current aim error at the target's range must
    # sit inside the ~14px bullet corridor. Advancing scales that miss down
    # linearly, so keep closing while the turret settles.
    desiredAim = bradsOf(aim - me)
    let
      err = abs(bradsErr(desiredAim, bot.estAim))
      perpMiss = engageD * sin(float(err) * PI / float(AimBrads div 2))
    wantFire = perpMiss <= bot.tune.fireSlackPx
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
    if retreating or (bot.tune.carrierFlee and iCarry):
      # Outnumbered (retreat) OR carrying the heart (flee): keep the gun on the
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
  elif not iCarry and not rushing and not pocketRush and not shotReady and
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
    let pressWorth = assaultOn or (
      bot.tune.tempoPress and bot.tick - tp.lastSeen <= TempoFreshTicks and
      # #8 TEMPO / AUDACITY — press on the half-beat: our reload is dead time,
      # but so is theirs if the threat can't punish us right now. When it is
      # WOUNDED (one or two of our returning trigger-pulls from dead) or TURNED
      # AWAY (its gun isn't on us this instant), don't surrender tempo to a duck
      # — CLOSE the distance while jinking, so the moment our gun is live we are
      # on top of it and finish it in ITS dead time. Only inside a band where
      # closing actually pays; a facing, full-hp gun still gets the duck.
      ((tp.hp in 1 ..< MaxHp) or not facingMe) and
      dist(tp.pos, me) <= TempoPressRange)
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
        not iCarry and not pocketRush:
      let toward = norm(seenEnemies[threat].pos - me)
      var side = vec(-toward.y, toward.x)
      if (bot.tick div 10 + bot.slot div 2) mod 2 == 0:
        side = side * -1.0
      if not bot.gridRayClear(me, me + side * 24.0):
        side = side * -1.0
      moveMask = octantBits(toward + side * 0.4)
      desiredAim = bradsOf(seenEnemies[threat].pos - me)
    elif threat >= 0 and not iCarry and not pocketRush:
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
      if not iCarry and not pocketRush:
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
          steer = norm(steer) + side * 0.6
      steer = steer + vec(rand(-0.12 .. 0.12), rand(-0.12 .. 0.12))
      moveMask = octantBits(steer)
      if bot.tick < bot.jinkUntil:
        moveMask = bot.jinkBits            # unsticking burst
      # Carriers and the pocket-grab rusher keep the cone down their escape
      # lane — for them speed beats gunfighting, so the lock/hunt overrides skip.
      let mayHunt = not iCarry and not pocketRush
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
    let err = bradsErr(desiredAim, bot.estAim)
    if err > deadband:
      rotBits = ButtonB
    elif err < -deadband:
      rotBits = ButtonSelect

  # Only a FRESH A press fires, and the pull locks the aim angle on the same
  # tick — never rotate on the pull tick so the lock takes the settled aim.
  var mask = moveMask or rotBits
  if wantFire and not bot.firedLast:
    mask = moveMask or ButtonA
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
    endpoint = ensureWsPath(url, WebSocketPath)
  randomize(slot * 7919 + 1)
  let bot = Bot(slot: slot, team: team, role: role, tune: shippedCombatTune())
  bot.resetTransient()
  echo "baseline slot=", slot, " team=", team, " role=", role, " -> ", endpoint
  let client = initProtocolClient()
  var everConnected = false
  while true:
    try:
      let ws = newWebSocket(endpoint)
      echo "connected ", endpoint
      everConnected = true
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
          bot.estAim + bot.rotSign * AimRate * advance, AimBrads)
        if not client.mapCameraReady:
          bot.resetTransient()             # lobby / game-over interstitial
          continue
        if not bot.navBuilt and client.walkabilityReady:
          bot.buildNavGrid(client)
        let mask = bot.decide(client)
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
