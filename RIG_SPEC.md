# Articulated cog rig — ART + GEOMETRY ground truth

> The separable-segment spec for the differential-steer trike. All coordinates are
> in the **cog_layers.json layer space** unless noted; the assembled master canvas is
> 1046×1024 (layer→canvas factor ≈ ×1.5162 for the legset).

## The design (Maxwell's spec, restated)
A differential-steer trike. Each of 3 legs is independent: it **splays** wide/narrow at
the hip, and its foot is a **top-down caster wheel that spins a full 360°** to point where
it actually rolls. Turning is *powered*: inner leg retracts + outer leg extends + rear wheel
casters into the arc, tightening the inner radius vs the outer — so it reads as *in control*,
not shoved. Reconfigures which leg is "rear" as travel direction changes. Always visible every
frame: all 3 legs+wheels, the head, the gun, and any carried heart.

## Renderer constraint (why this shape)
The Bitworld Sprite v1 board object is `{id, x, y, z, layer, spriteId}` — **NO rotation, NO
scale** (`spriteprotocol.nim`; client `blitObject` is a pure x/y pixel copy). Hosted cert renders
through the shared viewer; **no bitworld fork allowed** (REPLAY_DESIGN.md). ⇒ every angle must be
a **pre-baked sprite**, and every independently-moving part must be **its own board object**,
positioned by server-side forward kinematics each frame. Client-side rotation is impossible.

## Separable art (all CLEAN, already cut by the sprite editor — sources below)
Source layers live in `/tmp/cog_layers.json` + `/tmp/rig_layers.json` (editor exports). The
build pipeline must import these into `data/` as the rig masters (see task: import segment art).

| Part | Source layer | Size (px) | Pivot/anchor in-frame | Notes |
|------|--------------|-----------|-----------------------|-------|
| **caster wheel** | rig_layers `wheel` | 84×250 | axle = (44,121) | top-down tire, tread up, forks removed. Rolls along its LONG axis (+y in-frame). Spins 360° about axle. |
| **chassis (legset)** | cog_layers `legset` | 680×674 | hub hole = (346,271) | Y-body + hub ring + 3 empty caster forks. Wedge-cut into 3 legs (below). |
| **head/turret** | cog_layers `head` | 434×514 | cube center; visor toward −y (front) | aims independently; gun mounts on the RIGHT FACE (CvC carry-pose spec, off the aim ray). |

`wheel2` (102×261) is a dirtier duplicate of the same tire — use `wheel`.

## Legset → 3 independent legs (wedge cut about the hub)
Angular histogram (r>110 from hub) shows **3 clean lobes separated by wide empty gaps** — the
cut lines cross zero material:

- **FRONT-RIGHT** leg: material ~15–45°, fork tip (wheel mount) = **(645, 56)**, len ~420.
- **FRONT-LEFT** leg: material ~130–165°, fork tip = **(44, 56)**, len ~426.
- **REAR** leg: material ~250–285°, fork tip = **(346, 616)**, len ~402.
- **Cut wedges at gap midpoints** ≈ 87° / 210° / 330°. Hip = leg root at the hub ring (r≈110).

The two front legs are **mirror-symmetric** (mirror IoU 0.86); rear is the same leg to south.
Cut ONE leg, place 3× by rotation about the hub (mirror the fronts). Foot points are the
wheel-mount anchors.

## ⚠️ SPLAY IS A RUNTIME DOF — NEVER BAKED INTO A POSE
The differential turn animates the splay CONTINUOUSLY (inner leg swings back / outer swings
forward while turning). So splay must NOT be baked into the chassis or into a fixed leg
arrangement — a baked splay would freeze the turn. Instead:

- **Chassis object** = hub ring + central body ONLY (legs NOT baked in). 16 facings.
- **Each leg** = its own object, baked STANDALONE at fine *absolute* angle steps (≈32–64 around
  the full circle). Per frame the controller computes each leg's absolute angle
  `legAngle = bodyHeading + legMountAngle + splayDelta` and picks the nearest baked step — so
  body facing AND live splay BOTH fold into one index. Splay animates across steps; nothing
  is frozen. Extend/retract = the hip swing moving the foot fore/aft = a different index +
  repositioning the wheel object (no "retracted" sprite).
- **Each wheel** = its own object, baked at caster-yaw steps (≈32), positioned by FK at the
  leg's live fork-tip. Yaw picks nearest step from the live wheelToe/travel.

"Added not multiplied": `chassis(16) + leg(≈64) + wheel(≈32)` per team ≈ ~112 sprites, and ANY
splay/turn/reverse/turn-around combo is reachable because each frame is assembled from
independent parts. No baked pose constrains the animation.

## Shared pivot (all parts rotate about this)
**Assembled-canvas pivot = (523, 412)** on 1046×1024 (legset hub → (524,411); head cube center
→ (522,414); cross-checked). Front = north (−y): head visor sits directly above cube center at −y.

## The already-built driving controller (the hook — currently UNWIRED)
`sim.nim` `CogDriveState` + `stepCogDrive` (advanced every frame at `global.nim:4899-4914`,
scrub-safe + replay-deterministic) computes `bodyHeading` / `wheelToe` / `reverseFrames` — and
today **throws them away** (the base sprite uses raw `soldierMoveRotIndex`). This is the exact
seam the articulated emission consumes: bodyHeading→chassis facing, wheelToe→leg/wheel steer,
reverseFrames→forward/reverse pose + the extend/retract differential.

## ⚠️ SCALE GOTCHA (cost real time — do not repeat)
The rigger export's `scale×` (head 0.430, wheel 0.444, legset 1.191) is relative to the
rigger's ORIGINAL reference layer, NOT the art's own native px. To get the true
art-native→screen factor you MUST divide by the part's `toOrig` (the original layer's
downscale, ~1.397). Verified against the rigger's own headless stage sizes, the correct
NATIVE render factors are: **head 0.6006, legset 0.6016, wheel 0.6202** (their RATIO is what
matters; multiply all by one `size` dial). Using the raw export scales made head+wheels
~28% too small. Ground-truth check: drive rigger_final.html headless and read
`exportScale * o.scale * (o.toOrig/s.toOrig)` per layer (tools: /tmp/verify_scale.cjs).

## LIVE PREVIEW (the eyes-on tool)
`/tmp/cog_anim_final.html` — the REAL articulated rig (correct scales, your export, ported
controller). WASD drive, mouse aims head, B = bones (hip=orange, ankle/caster=teal, bone
lines=yellow, hub=orange, heading=gold ray, aim=teal ray). Differential swing EASES ∝ turn
rate (build/relax, not instant); per-wheel caster EASES toward travel (see it turn, not snap).
Rebuild data: tools/rig_preview.py leg_parts + the /tmp/rig_data.json emitter.

## ⚠️ THE TWO KINEMATICS BUGS (fixed 2026-07-22 — the core of "make differential work in 2D")
1. **Differential must pivot each leg about ITS OWN HIP, not the body hub.** Rotating a leg
   about the hub just adds to the whole-body spin and washes out (zero visible differential).
   Pinning each leg at its hip (on the hub rim, carried by body rotation) and rotating the leg
   art by (dHead + swing) about that hip makes the FOOT ARC while the inner end stays put — THAT
   is the visible steer, and it can't gap (hip stays under the hub disc). Hips/feet measured per
   leg wedge (tools/rig_preview.py leg_parts; in /tmp/rig_data.json).
2. **Swing must be driven by a SMOOTHED turn rate (EMA of w), NOT raw per-frame w or heading
   error.** The CTF controller eases heading→travel in ~1 frame, so raw error/w spikes then
   vanishes → swing collapses instantly (looked like "no differential"). An EMA
   `wAvg = wAvg*0.82 + w*0.18` PERSISTS through the whole turn: legs hold the steer pose while
   turning, relax when straight. Verified: swing holds −14° through a sustained arc, 0 straight,
   +30° hard the other way. Also: slow the body turn rate (~4) so turns take several frames.
3. **Caster sign:** tire long axis is vertical (rolls N/S at rot0); to roll toward screen angle
   wr, pass rotDeg=(wr−90) to drawPart (which negates). Passing −(wr−90) casters PERPENDICULAR.
   Verified empirically (tools: /tmp/wheel_axis.jpg).
4. **Wheels point along each foot's ACTUAL velocity, not shared body-travel.** A wheel's velocity
   = translation + ω×r (rotation) + leg-swing. Castering only to translational travel makes wheels
   DRAG PERPENDICULAR during a spin (feet move tangentially but wheels point along body travel).
   Fix: finite-difference each foot's screen position frame-to-frame → that vector IS the true
   per-wheel velocity (includes rotation+swing automatically); ease each caster toward it. Spin in
   place → wheels point tangent to their circle. (Engine port: derive foot velocity analytically
   from ω×r + swing rate since there's no "last frame" across scrubs — or from the pose delta.)
5. **Differential = ONE-SIDED LATERAL SPLAY, narrow at rest (matches the CvC "player5" cog).**
   - Rest: both front legs TUCKED NARROW, wheels parallel & pointing forward (like player5 idle).
   - Turn LEFT: ONLY the LEFT leg splays OUT; turn RIGHT: ONLY the RIGHT leg splays out. The other
     front leg stays tucked. NOT both legs swinging (that's not differential).
   - ⚠️ "Splay" = the foot swings SIDEWAYS to a WIDER TRACK (hip opens outward, wheel moves away
     from the body centerline) — NOT arcing the foot fore/aft about the hub. Arcing fore/aft was
     wrong (moves the foot forward-over-the-body, not out to the side). The lateral-track DOF is
     the correct joint motion (confirmed by Maxwell against player5).
   - Driven by turnAmt = normalized smoothed turn rate; splay/tuck magnitudes are FEEL dials.

   **SPLAY ∝ ANGULAR VELOCITY (final model, 2026-07-22, Maxwell's call).** The splay width =
   the MAGNITUDE of the heading's angular velocity (|cog.w|, deg/frame), normalized by a FIXED
   reference WFULL (≈3°/frame = full/equilateral splay), smoothed (EMA) so a steady curve holds
   a steady splay. Straight = 0 = narrow; gentle curve = slightly wide; sharp curve = equilateral.
   ⚠️ MUST be decoupled from the body-turn-rate slider: normalize by the FIXED WFULL, NOT by the
   slider, so a slow body still reaches full splay (just needs a tighter curve). Earlier attempts
   that drove splay from body turn RATE, or from heading→travel/input ERROR, were WRONG: error
   collapses to 0 once the body catches the input (holding W+A is a straight line to NW, not a
   curve → correctly zero splay). Only real continuous curving (auto-drive, or steering that keeps
   changing heading) produces sustained angular velocity → sustained splay. Verified under
   auto-drive: w=−1.4→turnAmt−0.4, w=0→0, w=+2.8→+0.8. Live tool: /tmp/cog_rig_v4.html.

## KINEMATICS — how CogDriveState drives each part (the math the build rests on)
Brad space: `AimBradsTurn=256`, 0=east, 64=north (CCW; screen y down). Front = north.
Leg rest mount angles **relative to forward** (measured from art, forward=north): the two front
legs flank the nose at **±55°**, the rear trails at **180°**. (Art angles 35°/145°/270° about the
hub; forward=90° art.)

**Turn rate** `w` = signed Δ`bodyHeading`/frame (brads), +=left/CCW. Derived in the controller
from the heading ease (or `easeBrads` step just taken).

**Leg hip angle (the ONLY per-leg DOF — angular, about the hub, constant radius):**
```
legAngleAbs_i = bodyHeading + legMount_i + swing_i
swing_i (front pair) = clamp(Cswing * w, ±SwingMax)      # BOTH front legs swing in turn dir
swing_rear           = small, follows travel; rear WHEEL casters to absorb
```
A uniform swing of both front legs *in the turn direction* IS the differential: for a LEFT (CCW)
turn the front-right foot arcs **forward** and the front-left foot arcs **back** (they start on
opposite sides of the nose), exactly the described pull-back-left / push-forward-right. Magnitude
∝ `w` (Maxwell's call). `w≈0` → rest stance. Committed turn-around = sustained large `w` → full
swing through the U-turn. Symmetric "splay wide/narrow" is an optional extra `±sigma` on the front
pair (speed-tied), layered on the same angular DOF.

**Each leg is baked standalone, centered on the hub, at N_leg absolute-angle steps.** Its object
sits at `spritePlayerX/Y` (canvas center = hub) — so the baked rotation *is* the pose; no per-leg
position FK. `bodyHeading + legMount + swing` all fold into one nearest-step index. Splay animates
continuously across steps; **nothing frozen** (the point you flagged).

**Each wheel is its own object, FK-positioned at its live foot:**
```
foot_i (canvas px from hub) = R_leg * unitVec(legAngleAbs_i)     # fork-tip radius, scaled
wheel_obj.xy = spritePlayerXY + foot_i - wheelAxleInSprite
wheel yaw_i  = angleOf( travelVec  +  omega × r_i )              # local roll dir → nearest yaw step
```
First pass: `yaw_i = wheelToe` (shared travel toe — already casters fast, never scrapes). Refinement
(cheap, tunable): add the `omega × r_i` term so the rear caster visibly kicks out on a tight turn.
Wheel picks its nearest baked YAW step; same tire table reused by all 3 wheels.

**Head/turret + gun:** unchanged aim model — `soldierRotIndex(aimBrads)`, gun on the right face
(CvC carry-pose spec).

**Determinism:** every value above is a pure function of `(cogDrive state, vel, aim)`; `cogDrive`
is already scrub-snapped (`global.nim:4899-4914`), so replays reproduce every limb pose exactly.

## CONDITIONAL TURRET ATTACHMENTS (state-gated — MUST be in the player model for the PR)
Two attachments ride the TURRET (head group, rotate with aim) and appear ONLY on the right state:
- **ARMS** (`data/rig/arms_{blue,red}.png`, nanobanana-generated + knockout-bg + team-tint):
  emit ONLY when **`player.carryingFlag`** is true. No heart → no arms (idle trike + head only).
  Carrying → arms cradle the heart out front along aim (heart already rides `CarryHeartFwdPx=12`).
  Draw arms UNDER the head cube, at head scale/rot. This gate goes in addPlayerActorSprites /
  the per-player emission (global.nim), mirroring the plasma pattern below.
- **PLASMA SWORD/ARC**: gated on **`player.hasPlasmaArc`** — ALREADY implemented
  (`PlasmaArcCarrySpriteId=2001`, emitted at global.nim ~3521: `if not player.alive or not
  player.hasPlasmaArc: continue`). This is the EXACT template for the arms gate. Ensure the
  articulated-rig rework keeps the plasma carry sprite + fired-cone FX (2002+) intact and on the
  turret group so it aims correctly.
The clean rule: each turret attachment = a per-player bool → conditional object emission. Same
shape as the existing shield/plasma gating.

## Sprite table (added, not multiplied) + object count
| Part | Steps | ×teams | Defs | Per-frame objects/player |
|------|-------|--------|------|--------------------------|
| chassis (hub+body, NO legs) | 16 facings | 2 | 32 | 1 |
| leg (one shape, standalone on hub) | ~64 abs-angle | 2 | 128 | 3 (same table, 3 indices) |
| caster wheel (black tire) | ~32 yaw | (team-indep) | 32 | 3 (FK-positioned) |
| head/turret + gun | 16 aim | 2 | 32 | 1 |
| **total** | | | **~224 defs (init-only)** | **8 objects/player** |
Leg 64-step for smooth splay (tunable down to 32 if bake CPU bites). All defs ship once at init +
must be **pre-warmed in `warmBoardRenderCaches`** (today warms 32; this ~7×). Per-frame wire = 8×12 B
/player = trivial. Sprite-id ranges to be allocated off the 2300/2340/2380 bases.

## Emission budget (from the plumbing trace)
- Sprite DEFS ship **once at init** (dedup in `addBoardSpriteChanged`; init-only call site).
  Per frame = only cheap 12-byte objects. Adding parts is nearly free on the wire.
- Wire cap is **per-message 1 MiB**, chunked at message boundaries (`chunkSpritePacket`,
  `MaxWsFrameBytes=900_000`). A 144×144 (boardScale=2) sprite ≈83 KB raw, snappy-compressed far
  under the cap — a big pose table cannot bust the frame cap; it only adds init/pre-bake CPU
  (pre-warm in `warmBoardRenderCaches`).
- `SoldierCanvas=72`, `boardScale=RenderScale=2`, `SoldierRotations=16`, `MaxPlayers=16`.

## Z-stack (small integer offsets around player.y; z IS map-Y painter depth)
wheels (y−3) < legs (y−2) < chassis (y−1) < heart-when-carried (y) < head (y+? ) < gun.
Keep the spread tiny — z is the map Y, so a spread wider than a neighbor cog's Y-gap lets stacks
interleave across players. (Today only base=y−1 / turret=y+1 exist.)
