# Articulated rig port — working notes (verified from committed art, 2026-07-23)

Goal: port the ALREADY-VALIDATED one-sided differential FK (RIG_SPEC.md + tools/build_live_html.py,
Maxwell-approved) into the Nim renderer so the articulated cog (3 legs, caster wheels, carry arms)
shows in the replay viewer and lands in PR #78. NO redesign — transcribe the locked numbers.

## Art ground truth (from the committed data/rig/*.png bytes, NOT /tmp layers)
Canvas 1046x1024, shared hub/pivot = (523, 412) [anchors.json].
- chassis_{team}.png: FULL legset (all 3 legs at rest + hub Y-body). Wedge-cut into hub-disc + 3 legs.
- leg_{team}.png: ONE leg (front_right), hub-centered same canvas (alt source; wedge-cut from chassis
  is cleaner and gives all 3 + disc — VERIFIED /tmp/rigview/wedgecut.jpg: 3 clean legs ~40k px each,
  feet at radius ~600-650, hub disc r<=175 covers all roots, no gap).
- head_{team}.png: turret cube+visor, on 1046x1024.
- arms_{team}.png: 384x628, bone (191.5, 613). Symmetric two-arm cradle. Gated on carryingFlag.
- wheel.png: 84x250, axle (44,121) [anchors: 43.6,121.2], team-neutral black tire, rolls +y long axis.

## Wedge cut (reproducible, CI-safe — no /tmp dependency)
hub = (523,412); ang = atan2(-(y-hy), x-hx) deg 0=E CCW; r = dist from hub.
WEDGES (deg): front_right (330,82), front_left (82,200), rear (200,330); leg = wedge & r>70 & a>=40.
hub_disc = r<=175 & a>=40. Legs baked standalone hub-centered; disc drawn over roots.

## Native scales [rig_def.json nativeScale]: legset 0.6016, head 0.6006, wheel 0.6202. size dial rigSize=0.55.
## TUNED feel [rig_def.json]: bodyTurnRate 2, splayAmountDeg 86, restTuckDeg 45, casterRate 32, WFULL 3.0 deg/frame.
## Leg rest mounts rel forward(N): front pair ±55° flank nose, rear 180°. (art-abs 35/145/270 about hub.)

## Controller (stepCogDrive ALREADY on branch, sim.nim): computes bodyHeading, wheelToe, turnAmt,
## casterFR/FL/Rear, reverseFrames — all scrub-snapped + replay-deterministic. Currently the base
## sprite consumes bodyHeading (my earlier fix); legs/wheels/arms are what remain to emit.

## Plan stages: 1 geom ✓  2 python preview (articulate contact sheet)  3 Nim bake tables (sim.nim)
## 4 FK emission global.nim (8 objs/player, arms gate)  5 warm+audit+tests  6 browser verify.
## Sprite-id bases to allocate off 2300/2340/2380 window (see global.nim split consts).
## Z-stack: wheels(y-3) < legs(y-2) < chassis/disc(y-1) < heart(y) < head(y+1) < gun(y+2). arms under head.
