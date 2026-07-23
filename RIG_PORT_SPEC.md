# RIG PORT SPEC — the locked numbers to transcribe (FINAL one-sided model)

## Frames (do not mix)
- COMMITTED art canvas 1046x1024, hub/pivot (523,412)  [anchors.json] — what data/rig/*.png use.
- Validated FK points live in the 1031-art frame (/tmp/rig_data.json, artHub (524.215,385.783)).
- Map 1031-frame -> committed via scale-about-hub, k=1.326:
    committedPt = (523,412) + (p - (524.215,385.783)) * 1.326
  Verified: fr foot (904.4,130.6)->(1027,73) matches wedge cut; fl->(9,67); rear->(518,1032).

## Mapped hips/feet in COMMITTED frame (k=1.326)
- front_right: hip (591.4,353.7)  foot (1027.2,73.4)
- front_left : hip (449.1,363.5)  foot (9.0,67.3)
- rear       : hip (539.7,481.0)  foot (518.1,1031.6)
Rest mount rel forward(N=up,-y): front pair flank nose ±~55°, rear trails 180°.

## Scales / feel [rig_def TUNED + nativeScale]
nativeScale legset 0.6016, head 0.6006, wheel 0.6202 (near-equal; wheels ~3% bigger). rigSize 0.55.
bodyTurnRate 2, splayAmountDeg SW=86, restTuckDeg TUCK=45, casterRate 32, WFULL 3.0 deg/frame.
On-screen: rig body must match the current cog footprint (~SoldierBodyPx). Calibrate scale to that,
keep native RATIOS for relative part sizes.

## Controller (stepDrive) — brads TURN=256, 0=E,64=N,CCW. STOP=8,REVMAX=96,COMMIT=12.
speed=|vx|+|vy| (fed vx*6,vy*6). travel=bradsOf(vx,vy). err=bdiff(travel,head).
back = |err|>REVMAX. rev +1(cap 24) if back else -2. committed = rev>=COMMIT.
tgt = (back and not committed)? head : travel.  rate=max(bodyTurnRate/2, round(bodyTurnRate*STOP*4/max(speed,STOP*4))).
head=ease(head,tgt,rate); w=bdiff(head,prev); toe=ease(toe,travel,40).
tInst=clamp(deg(w)/WFULL,-1,1); wAvg=wAvg*0.7+tInst*0.3; turnAmt=easeF(turnAmt,wAvg,0.12).
(Branch stepCogArticulation already does 0.7/0.3 EMA + ease — VERIFY it matches.)

## Render/pose (FINAL §C) — dHead = headingDeg - 90.
ONE-SIDED splay (t=turnAmt, + = LEFT/CCW):
  leftOpen=max(0,t)*SW; rightOpen=max(0,-t)*SW
  swing.front_left  = -TUCK + leftOpen
  swing.front_right = +TUCK - rightOpen
  swing.rear = 0
Leg drawn: pinned at ITS OWN HIP (hip rides hub by dHead), art rotated by (dHead+swing_leg) about hip.
  hipScreen = cogCenter + rotate(hipArt - hub, dHead) * S
  foot      = hipScreen + rotate(footArt - hipArt, dHead+swing_leg) * S
Wheel: at foot, caster eases toward each foot's ACTUAL velocity dir (finite-diff; engine: analytic
  omega x r + swing rate), max step casterRate=32 deg/f. drawPart rot = casterDeg - 90 (drawPart negates).
Hub disc: at cogCenter, rotated dHead.
Head: at cogCenter, rot = aimDeg - 90 (soldierRotIndex(aimBrads)).
Arms: ONLY if carryingFlag; UNDER head; head scale+rot; bone (191.5,613) native 384x628.
Heart: CarryHeartFwdPx=12 map px forward along aim (already emitted by engine).
drawPart(k,px,py,scale,rotDeg,bone): pin bone-art-px at (px,py), scale, rotate(-rotDeg) [CSS+ =CW].

## Z-stack (engine, authoritative): wheels(y-3) < legs(y-2) < chassis/disc(y-1) < heart(y) < head(y+1) < gun(y+2). arms just under head.

## Gotchas (do X not Y)
1. Pivot each leg about its OWN hip, not the body hub (else differential washes out).
2. Splay from EMA-smoothed tInst (0.7/0.3), not raw w or heading error (error collapses in ~1 frame).
3. Caster: pass rotDeg = wr-90 (drawPart negates); -(wr-90) casters perpendicular.
4. Caster to each foot's ACTUAL velocity (analytic omega x r + swing), not shared body travel.
5. Splay is ONE-SIDED lateral, narrow at rest; only steering-side leg opens; magnitude by |ang vel|/WFULL, decoupled from turn-rate dial.

## Art decomposition (VERIFIED from committed bytes)
chassis_{team}.png (1046x1024, hub 523,412) = FULL legset. Wedge-cut:
  ang=atan2(-(y-412),x-523) deg 0=E CCW; r from hub.
  front_right (330,82), front_left (82,200), rear (200,330); leg = wedge & r>70 & a>=40.
  hub_disc = r<=175 & a>=40. (Verified: 3 clean legs ~40k px, disc covers roots.)
leg_{team}.png = single front_right leg alt source. head_{team}.png turret. arms 384x628 bone(191.5,613).
wheel.png 84x250 axle (44,121) roll +y.

## ARCHITECTURE DECISION (2026-07-23) — separate objects, not a fat composite
Per-wheel caster fidelity (strafe/spin/rapid-turn) REQUIRES wheels as their own board
objects picked live by foot velocity — a composite baked by (moveRot×turnBucket) can't
show wheels pointing off the body during a decoupled strafe. So port the spec's 8-object
design:
- chassis/hub-disc: 1 obj, 16 facings by bodyHeading. ids off a new base.
- 3 legs: each 1 obj at cog center, baked hub-centered at ~48 ABSOLUTE-angle steps =
  nearest(bodyHeading + legMount + swing). splay animates across steps (turnAmt continuous).
  ONE leg shape; front_left is the mirror; rear is the same leg. team-tinted.
- 3 wheels: each 1 obj FK-positioned at its live foot; spriteId from ~32 caster-yaw steps
  by the foot's actual velocity dir (analytic: travel + omega×r + swing rate). team-neutral.
- head: 1 obj, 16 aim (existing turret path). arms: 1 gated obj (carryingFlag), under head.
Baked != frozen: same mechanism as the existing 16-step rotation; index varies per frame.
Determinism: all indices are pure funcs of cogDrive (scrub-snapped) — replay-exact.
Analytic foot velocity (no last-frame across scrubs): v_foot = v_body + omega × r_hip→foot
  + d(swing)/dt tangential; ease caster toward angleOf(v_foot), max step casterRate=32.

## RESOLVED: legs are HIP-PIVOT, not hub-pivot (2026-07-23)
Gotcha #1 is authoritative and the prototype confirms it. A standalone hub-centered leg
bake rotated by an absolute angle is a HUB rotation — it misplaces the foot by ~40px in the
1046 frame (~2px on map) and, worse, the differential washes out. Correct bake:
- LEG SPRITE: bake each leg on a canvas centered on ITS OWN HIP (translate hip->canvas
  center), so rotating the sprite = rotating the leg about its hip. One canvas per
  (team, leg-role, swingStep) OR per (team, absoluteHipAngleStep) where the emission also
  positions the hip. Simplest faithful port: bake per (team, role, absAngleStep) where
  absAngle = dHead + legMount + swing, sprite centered on hip; emit the leg OBJECT at the
  hip's SCREEN position (hip rides the hub by dHead: hipScreen = center + rot(hipArt-hub,dHead)*S).
- Because the leg object is placed at the hip (not the cog center), legs are FK-positioned
  objects like the wheels — not centered like the chassis/head. This matches prototype render().
- front_left = front_right leg MIRRORED (both share the hip-pivot mechanic, mirrored hip/foot).
Net: chassis+head centered at cog; legs at their hip screen pos; wheels at their foot screen pos.
