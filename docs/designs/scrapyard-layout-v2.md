# Scrapyard layout v2 — measured rebuild plan

Status: layout plan for the integrating session. Supersedes the current
in-game `scrapyardCtfMap()` (1235x659). Keeps the two things the current map
got right — the MW2-model capture (`captureRadius 64`) and the stand-shelter /
offset-spawn conversion fix — and rebuilds everything else from measurement:
the current map's structures were placed free-hand against the wrong frame, it
squashed the yard 10% vertically, and it has no yard fence (the boneyard's
enclosure) at all.

Provenance: every number below is MEASURED from the official 2009 overhead
(`docs/designs/mw2-reference/scrapyard.png`, 1024x1024) rotated into game
space, percentile-stretched (per `tools/mw2_ref_prep.py`), thresholded at
T=185 and component-labelled. The transform from rotated-reference pixels
(rx, ry) to THIS canvas is:

```
canvas.x = round((rx - 51) * 1.42)
canvas.y = round((ry - 276) * 1.42)
```

(51/276 = the prep-tool playable-frame origin for scrapyard's
`frame=(0.050, 0.270, 0.900, 0.770)` on the rotated 1024 image; 1.42 = chosen
scale, see section 1; no additional offset is needed — the frame itself
centers the yard.) Items marked [CHOICE] are creative decisions where the
reference is ambiguous; [ADJ] are deliberate small departures from the
measured footprint (to clear an engine carve zone, kill a sliver, or break an
over-long open run).

Ground truth: the four canvas-scale masks in
`docs/designs/mw2-reference/scrapyard-v2-masks/` (README there lists
semantics + white-pixel counts). If a Nim transcription disagrees with a
mask, the mask wins. Verification render: `/tmp/scrapyard_plan_view.jpg`.

---

## 1. CANVAS

**`width = 1235, height = 727`** [CHOICE]

- Real Scrapyard's playable frame is 870x512 in the rotated reference,
  aspect 1.699. `1235/727 = 1.6987` — the aspect is preserved to 0.1%.
  The current 1235x659 canvas squashed it 10% vertically.
- Scale 1.42 canvas px per reference px keeps the pack-standard width (the
  other MW2 plates also map their frame width to 1235), so structure
  footprints and engagement ranges feel like the rest of the pack.
- Engine center is `(617, 363)`; the forced flag ring r70 lands in the open
  court at the inner corner of the central L-building — the map's real
  contested crossing ("the Crossroads"). After the [ADJ]s in section 4 the
  ring carve chews **0 px** of authored wall (verified).
- Keep `gunRange = 1300`, `captureRadius = 64`, `captureClear = 210`,
  `flagRing = 70`.

---

## 2. ORIENTATION DECISION

**Plate rotation.** The game-space plate is the original image rotated **90
degrees counter-clockwise** (PIL `rotate(90)`, exactly as
`tools/mw2_ref_prep.py` PLATES declares: `rot=90`). Compass mapping:

| original (2009 map, north up) | game space |
|---|---|
| north (depot/garage building) | **west — RED end** |
| south (the big hangar, "C" roof mark) | **east — BLUE end** |
| east (shed row + engine pen) | **north edge** |
| west (the "2" warehouse) | **south edge** |

**The boneyard rows run EAST-WEST in game space.** On the 2009 minimap the
stored fuselages lie north-south (e.g. the largest one occupies orig
(539..579, 263..375) — tall, not wide); the 90-CCW plate rotation turns that
axis horizontal. This is the load-bearing fact of the whole layout: the rows
are **parallel to the spawn-to-spawn carry axis**, so the streets between the
rows ARE the lanes, and the gaps between fuselage sections are the
cut-throughs (section 6). Anything traced from the *unrotated* image must
rotate with the plate — this is exactly the 90-degree error that shipped in
Afghan's first plane. Art note: the painted roof numbers ("2" on the
warehouse, "C" on the hangar) read sideways in game space; that is correct.

---

## 3. THE YARD FENCE

The boneyard is fully enclosed. **Fill the entire canvas with wall, then
carve the yard floor as this 16-point polygon** (canvas px, clockwise from
the NW pocket corner). Everything outside it — desert rubble, the rock
shelves, the fence line itself — stays solid:

```
YARD = [
  (142,57),(460,57),(460,40),(1136,40),(1136,71),(1193,71),
  (1193,185),(1219,185),(1219,490),(1207,490),(1207,706),(125,706),
  (125,490),(21,490),(21,206),(142,206)
]
```

Named segments (real features):

| segment | polygon edge | what it is |
|---|---|---|
| NW pocket shelf | (142,57)-(460,57) | rubble shelf hangs lower here; the NW yard pocket sits under it |
| north fence | (460,40)-(1136,40) | straight fence behind the workshop court, shed, rack, heap and pen |
| NE notch | (1136,40)..(1193,71) | measured stepped corner; makes the NE pocket a hook, not a box |
| NE pocket east face | (1193,71)-(1193,185) | fence face down to the hangar's north wall line |
| hangar weld | (1193,185)..(1219,490) | the hangar sits ON the east fence — no alley behind it |
| east fence, south reach | (1207,490)-(1207,706) | from the hangar's SW to the SE corner |
| south fence | (1207,706)-(125,706) | the warehouse's south wall welds through it |
| SW cutback | (125,706)-(125,490) | the yard narrows; rubble west of x=125 south of the Depot |
| Depot weld | (21,490)..(142,206) | the Depot building juts west past the fence line and IS the west boundary (enterable, section 4) |

The fence band between polygon and canvas edge is 21..40 px; nothing playable
touches the canvas edge, and **all four canvas edges are solid** (this is
what makes `carveClear = -1` legal, section 5).

### Callout -> coordinate index

| callout (notes-file vocabulary) | canvas anchor |
|---|---|
| The Depot (red base building; orig-north garage) | interior (75, 348) |
| The Office / annex nook + stair porch | (205, 235) / (203, 465) |
| The Workshop | interior (348, 108) |
| The North Shed (open bay) | mouth (625, 150) |
| Plane fuselages / the Row | F1..F4 along y≈207..293 |
| The Crossroads (center flag) | (617, 363) |
| Wing bay (skylight building) | (510, 380) |
| The Long Shed ("central corridor" / tunnel feel) | (800, 421) |
| Wing slab | (750, 320) |
| Engine fans | (878, 335) |
| The Cutting Shed | (378, 398) |
| The Crane / the Tower (red building callout) | base (288, 594) |
| The Warehouse ("2" roof mark) | interior (580, 615) |
| The Hangar ("C" roof mark; blue base) | interior (1135, 337) |
| MG nest | (996, 264) |
| Scrap heap / engine pen / fuselage rack | (895,70) / (998,90) / (800,60) |
| Containers | NE (1054..1144, 101..121), SE (778, 636) |
| Trailers | truck (645, 509), standing (1006, 622) |

---

## 4. STRUCTURES

All rects are `MapRect(x, y, w, h)` canvas px, walls 10-18 thick, measured
unless marked. Welds (deliberate 0-gap contacts) are intentional — never
"fix" them apart, they kill sliver corridors. Doors are >= 24 px throughout.

### RED end — the Depot block (boundary-welded, enterable)

| piece | rect | notes |
|---|---|---|
| north wall | `MapRect(x: 21, y: 206, w: 121, h: 12)` | |
| west wall | `MapRect(x: 21, y: 206, w: 12, h: 284)` | boundary side |
| south wall | `MapRect(x: 21, y: 478, w: 121, h: 12)` | |
| east wall | `MapRect(x: 130, y: 206, w: 12, h: 32)`, `MapRect(x: 130, y: 262, w: 12, h: 68)`, `MapRect(x: 130, y: 354, w: 12, h: 124)` | doors y 238..262 and y 330..354 (24 each) [ADJ: north door raised out of the forecourt row band] |
| interior partition | `MapRect(x: 33, y: 336, w: 64, h: 10)` | two bays, 33-px pass at its east end |
| stair porch | `MapRect(x: 135, y: 432, w: 136, h: 67)` | solid; exterior stairs art [ADJ +30y to clear the red spawn pocket] |
| annex-room walls | `MapRect(x: 189, y: 213, w: 35, h: 7)`, `MapRect(x: 217, y: 219, w: 7, h: 39)` | roofless cover nook in the forecourt [ADJ: trimmed to y<=258 for the pocket] |
| NW low walls | `MapRect(x: 162, y: 146, w: 30, h: 6)`, `MapRect(x: 267, y: 143, w: 33, h: 7)` | gate line of the NW pocket; 75-px gap between them |

### The Workshop (NW yard, enterable)

| piece | rect |
|---|---|
| N wall | `MapRect(x: 301, y: 68, w: 95, h: 12)` |
| S wall (door 28 @ x330) | `MapRect(x: 301, y: 136, w: 29, h: 12)`, `MapRect(x: 358, y: 136, w: 38, h: 12)` |
| W wall | `MapRect(x: 301, y: 80, w: 12, h: 56)` |
| E wall (door 24 @ y124) | `MapRect(x: 384, y: 80, w: 12, h: 44)` |
| bench (welded to N wall) | `MapRect(x: 330, y: 80, w: 34, h: 20)` |

### North pens band (against the north fence)

| piece | shape | notes |
|---|---|---|
| shed W wall | `MapRect(x: 500, y: 40, w: 12, h: 130)` | [ADJ: reaches y170 to break the north-street row run] |
| shed E wall | `MapRect(x: 738, y: 40, w: 12, h: 108)` | open-front bay; roof art only |
| shed crates | `MapRect(x: 560, y: 60, w: 40, h: 30)`, `MapRect(x: 650, y: 52, w: 36, h: 26)` | [CHOICE] |
| rack walls | `MapRect(x: 750, y: 40, w: 12, h: 60)`, `MapRect(x: 847, y: 40, w: 12, h: 60)` | |
| rack cylinders | `MapRect(x: 762, y: 40, w: 85, h: 26)`, `MapRect(x: 762, y: 66, w: 85, h: 26)` | two cut fuselage barrels, butted (art keeps them distinct) |
| scrap heap | diamond c(895, 70) r 36 + disc c(920, 42) r 18 | [ADJ: welded west to the rack wall] |
| heap shoulder | `MapRect(x: 847, y: 40, w: 50, h: 44)` | fills the tapering-diamond wedge — without it a sealed pocket forms at (868, 49) |
| flatbed + container | diagonal (770,188)-(843,162) t 34 + `MapRect(x: 760, y: 168, w: 30, h: 30)` | [ADJ +22y: second baffle of the north street] |
| engine pen | `MapRect(x: 968, y: 40, w: 61, h: 63)` + disc c(998, 122) r 20 | back mass welded to fence; art shows two stored engines |
| NE crates | `MapRect(x: 1054, y: 104, w: 36, h: 15)`, `MapRect(x: 1090, y: 101, w: 54, h: 20)` | |

### The Row (fuselage row 1, the boneyard spine)

Runs east-west at y ≈ 207..293 — see section 2. Gaps G1..G4 between the
sections are the north cut-throughs (section 6).

| piece | shape | notes |
|---|---|---|
| F1 nose | disc c(300, 232) r 25 | nose points WEST at the red forecourt |
| F1 hull | `MapRect(x: 307, y: 207, w: 153, h: 50)` | [ADJ -36y: staggered north so the red spawn pocket clears it; a boneyard row is not a parade line] |
| F2 tilted section | diagonal (527,259)-(570,206) t 44 | measured tilt ~40 deg |
| F3 gutted hull | `MapRect(x: 628, y: 241, w: 140, h: 52)` | bright interior in the reference = cut open; art shows ribs |
| F4 hull | `MapRect(x: 821, y: 238, w: 155, h: 50)` | [ADJ +30x for G3, east face welds the MG nest] |
| parts pile | diamond c(560, 185) r 22 | welded to F2's nose; north-street rhythm |

### Center — the L-building and the slab

| piece | shape | notes |
|---|---|---|
| wing bay W wall | `MapRect(x: 482, y: 305, w: 10, h: 95)`, `MapRect(x: 482, y: 428, w: 10, h: 26)` | door y 400..428 |
| wing bay E wall | `MapRect(x: 529, y: 305, w: 10, h: 55)`, `MapRect(x: 529, y: 388, w: 10, h: 66)` | door y 360..388 opens onto the Crossroads |
| wing bay N/S walls | `MapRect(x: 482, y: 305, w: 57, h: 10)`, `MapRect(x: 482, y: 444, w: 57, h: 16)` | [ADJ: whole bay shifted 65 west of its measured spot so the forced ring carves nothing; S wall deepened to kill a seam run] |
| long shed N wall | `MapRect(x: 695, y: 393, w: 65, h: 10)`, `MapRect(x: 788, y: 393, w: 42, h: 10)`, `MapRect(x: 858, y: 393, w: 41, h: 10)` | doors x 760..788 and x 830..858 |
| long shed S wall | `MapRect(x: 695, y: 440, w: 204, h: 10)` | |
| long shed W wall | `MapRect(x: 695, y: 393, w: 10, h: 14)`, `MapRect(x: 695, y: 435, w: 10, h: 15)` | door y 407..435 onto the Crossroads. [ADJ: measured west face 604 cut back to 695 to clear the forced ring] |
| long shed E wall | `MapRect(x: 889, y: 393, w: 10, h: 57)` | [ADJ: east end cut 909->899 to clear the blue spawn pocket] |
| stored-wing rack | `MapRect(x: 790, y: 403, w: 60, h: 12)` | welded to N wall (free-standing it slivers the interior) |
| wing slab | `MapRect(x: 695, y: 290, w: 111, h: 61)` | flat wing on the ground; art rotates it ~20 deg. [ADJ: moved from measured (620,322) — welds to F3's south face, reads as a wing leaned on the hull |
| engine fans | discs c(872,331) r16, c(876,300) r13, c(884,372) r21, c(386,304) r11 | [ADJ: trio regrouped west, clear of the blue pocket; the r21 fan welds the shed's N wall corner and, with the slab, closes the corridor's y 290..393 band into a chicane] |

### West mid — cutting shed and the Crane

| piece | shape | notes |
|---|---|---|
| cutting shed side walls | `MapRect(x: 330, y: 358, w: 10, h: 81)`, `MapRect(x: 425, y: 358, w: 10, h: 81)` | [ADJ: west face 302->330 for the red pocket] |
| cutting shed N/S walls | `MapRect(x: 330, y: 358, w: 25, h: 10)`, `MapRect(x: 383, y: 358, w: 52, h: 10)`, `MapRect(x: 330, y: 429, w: 25, h: 10)`, `MapRect(x: 383, y: 429, w: 52, h: 10)` | doors 28 N and S @ x355 — a drive-through shed; the crane boom passes over it (art) |
| crane base N wall | `MapRect(x: 229, y: 535, w: 41, h: 12)`, `MapRect(x: 298, y: 535, w: 50, h: 12)` | door x 270..298 |
| crane base W/S walls | `MapRect(x: 229, y: 535, w: 12, h: 118)`, `MapRect(x: 229, y: 641, w: 119, h: 12)` | |
| crane base E wall | `MapRect(x: 336, y: 535, w: 12, h: 35)`, `MapRect(x: 336, y: 598, w: 12, h: 55)` | door y 570..598 |
| tower core | `MapRect(x: 265, y: 575, w: 40, h: 40)` | the "red building / control tower" callout — paint it rust-red |
| crane boom (ART ONLY) | lattice from (280, 560) to (362, 305), hook disc c(365, 300) r 8 | measured; no collision — you walk under it |

### South — the Warehouse, the long wall, the baffle

| piece | rect | notes |
|---|---|---|
| N wall | `MapRect(x: 405, y: 528, w: 85, h: 12)`, `MapRect(x: 518, y: 528, w: 122, h: 12)`, `MapRect(x: 668, y: 528, w: 86, h: 12)` | doors x 490..518 and x 640..668 (28 each), staggered off the G1 column |
| W wall | `MapRect(x: 405, y: 528, w: 12, h: 62)`, `MapRect(x: 405, y: 618, w: 12, h: 88)` | door y 590..618 |
| E wall | `MapRect(x: 742, y: 528, w: 12, h: 104)`, `MapRect(x: 742, y: 660, w: 12, h: 46)` | door y 632..660 [ADJ: staggered south of the W door so no row threads both] |
| S wall | `MapRect(x: 405, y: 694, w: 349, h: 14)` | welds through the south fence — no strip behind |
| pallet racks | `MapRect(x: 470, y: 580, w: 90, h: 24)`, `MapRect(x: 560, y: 630, w: 120, h: 26)`, `MapRect(x: 668, y: 540, w: 24, h: 60)` | third rack welded to N wall; aisles >= 27 |
| the long wall | `MapRect(x: 754, y: 525, w: 172, h: 18)` | measured; extends the warehouse's north face line east |
| the baffle wall | `MapRect(x: 535, y: 450, w: 19, h: 78)` | the measured N-S wall at plate x 377..390 restored at full height: welds long-shed-S to warehouse-N and to the wing bay's S wall — the mid-west barrier |
| leaning scrap sheet | diagonal (812,452)-(852,478) t 22 | welded to the shed's S face; south-street rhythm |
| truck trailer | `MapRect(x: 600, y: 490, w: 91, h: 38)` | the white window-band vehicle in the reference; parked against the warehouse face [ADJ from measured (636,479): welded south, keeps the street slot 40 px] |

### BLUE end — the Hangar and its forecourt

| piece | shape | notes |
|---|---|---|
| N wall | `MapRect(x: 1051, y: 185, w: 69, h: 12)`, `MapRect(x: 1148, y: 185, w: 71, h: 12)` | door x 1120..1148 to the NE pocket |
| E wall | `MapRect(x: 1207, y: 185, w: 12, h: 305)` | welds the east fence |
| S wall | `MapRect(x: 1051, y: 478, w: 31, h: 12)`, `MapRect(x: 1110, y: 478, w: 109, h: 12)` | door x 1082..1110, staggered off the N door |
| W piers | `MapRect(x: 1051, y: 185, w: 18, h: 58)`, `MapRect(x: 1051, y: 417, w: 18, h: 73)` | **the mouth: y 243..417 (174 px), facing the field** — the real hangar's giant door; the blue stand sits in front of it |
| rail-line debris | `MapRect(x: 1080, y: 290, w: 40, h: 26)`, `MapRect(x: 1150, y: 330, w: 42, h: 32)` | interior cover on the diagonal rail streak (streak itself is floor art) |
| wing wreck | diagonal (905,240)-(985,190) t 30 | [ADJ: forecourt wrecks shifted north out of the blue pocket] |
| tail wreck | `MapRect(x: 1020, y: 200, w: 34, h: 44)` | [ADJ NE; breaks the x~1040 column] |
| MG nest | diamond c(996, 264) r 22 | sandbags at F4's tail, covering the forecourt [CHOICE on identity, position measured at (960..991, 355..413) then ADJ north out of the pocket] |
| SE crates | `MapRect(x: 1172, y: 490, w: 35, h: 43)` | welded to the hangar's S face |
| standing trailer | `MapRect(x: 991, y: 578, w: 30, h: 88)` | measured; SE-yard anchor |
| SE container | `MapRect(x: 778, y: 636, w: 64, h: 27)` | [ADJ +61y: breaks the warehouse-E-door row] |

### Trenches (walkable pits, existing mechanic)

```
result.trenches = @[
  MapRect(x: 600, y: 150, w: 150, h: 56),  # north street, at the shed mouth
  MapRect(x: 560, y: 438, w: 128, h: 50),  # Crossroads south mouth
  MapRect(x: 866, y: 462, w: 104, h: 56),  # south street, east reach
  MapRect(x: 352, y: 470, w: 56, h: 56),   # SW court foxhole
]
```

Art-only props (no collision): crane boom + hook, landing-gear pair at
(640, 418), the rail streak (923,263)-(1219,383), roof marks "2" and "C",
oil stains under the rail inside the hangar.

---

## 5. OBJECTIVES

| field | value | rationale |
|---|---|---|
| `redHome` | `MapPoint(x: 257, y: 345)` | Depot forecourt, ringed by the annex nook, porch, east wall and F1's nose |
| `blueHome` | `MapPoint(x: 978, y: 381)` | in front of the hangar mouth, covered by the piers, MG nest and wrecks |
| `redSpawn` | `MapRect(x: 189, y: 262, w: 116, h: 166)` | hugs the Depot side of the pocket (offset away from midfield) |
| `blueSpawn` | `MapRect(x: 933, y: 300, w: 112, h: 162)` | hugs the hangar side of the pocket |
| `spawnClearW` / `spawnClearH` | **70 / 85** | pockets: red (187..327, 260..430), blue (908..1048, 296..466). Every structure is placed/[ADJ]-shifted so the forced pockets and the flag ring carve **0 px** of authored wall (verified per-shape) |
| `carveClear` | **-1** | **load-bearing.** All four canvas edges are solid fence band/rubble; the old 96-px always-floor columns would punch floor corridors through the west fence (x<125 is solid at spawn height... x<21 everywhere) and the east fence/hangar. Edges are solid, so -1 is legal; 0 is an acceptable fallback; anything >=24 breaches the yard |
| `captureRadius` | **64** | keep — MW2-model capture at the stand, the conversion fix's other half |
| `medKitSpawns` [CHOICE] | `MapPoint(x: 580, y: 610)`, `MapPoint(x: 455, y: 108)` | one INSIDE the Warehouse (the south lane's contested heart, three doors, no owner), one at the head of the G1 cut in the north street — both on crossfire ground |

**Stand-side cover (the conversion-fix invariant):** structure-wall fraction
of yard ground within 200 px of the stand — **red 18.9%, blue 21.0%**, both
inside the 10-25% band that converts (the old map's defect was 9%/12%
pre-fix). The shelter is cut airframe and hangar steel, not bolted-on hull
sections: it falls out of the measured buildings.

Symmetry note: homes are point-symmetric about the engine center by
construction (`257 + 978 = 1235 = width`, `345 + 381 = 726 = 2*centerY`) —
mild diagonal, red slightly north-of-center, blue slightly south. Straight
distances to center are equal (~361) but red's line crosses the Row while
blue's runs the open corridor, so BFS walk distance is the number that
matters. **Integrator: run the walk-to-midfield BFS check (asymmetric-map
fairness suite); if red measures long, nudge `redHome` to (262, 350) — do
not move blue, its pocket is 3 px off the hangar piers. Also assert the
asymmetry test itself fires: this layout is NOT a mirror (hangar end vs
depot end).**

---

## 6. LANES

Three east-west lanes — the boneyard streets — plus the cut-throughs that
give the map its rhythm. Polylines are lane centerlines in canvas px.

**Lane N — the North Street (pens side):**
```
(257,300) -> (290,180)                  # out the forecourt, past the low walls
          -> (420,160) -> (455,108)     # workshop court (medkit 2)
          -> (620,170)                  # shed mouth + slit trench
          -> (700,180) -> (740,120)     # shed E / rack slot
          -> (900,150)                  # heap-flatbed slot
          -> (950,120) -> (1080,150)    # past the engine pen, NE pocket
          -> (1134,220) -> (1134,300)   # hangar north door, into the Hangar
```

**Lane M — the Central Corridor (the carry lane):**
```
(257,345) -> (380,398)                  # forecourt, through the Cutting Shed
          -> (460,380) -> (560,370)     # west court, past the wing bay door
          -> (617,363)                  # THE CROSSROADS (flag ring)
          -> (750,370) -> (830,375)     # corridor: slab-fan chicane
          -> (920,370) -> (978,381)     # hangar forecourt (blue stand)
          -> (1060,350)                 # into the hangar mouth
```

**Lane S — the South Street (warehouse side):**
```
(257,400) -> (300,510) -> (352,498)     # porch corner, SW court + foxhole
          -> (450,505) -> (504,528)     # warehouse NW door...
          -> (580,610) -> (742,646)     # ...through the Warehouse (medkit 1), E door
          -> (860,490) -> (940,500)     # south street east reach + trench
          -> (1040,560) -> (1096,484)   # SE yard, hangar south door
```

Cut-throughs (the between-rows gaps; all >= 24, most >= 33):

| cut | where | gap |
|---|---|---|
| G1 | F1 tail -> F2 nose (x 460..511) | 51; N-S column capped by the warehouse N wall |
| G2 | F2 tail -> F3 nose (x 592..628) | 36 |
| G3 | F3 tail -> F4 nose (x 768..821) | 53 north mouth; exits east of the slab weld |
| G4 | F4/MG tail -> hangar piers | 76 at y 240, opens into the forecourt |
| Crossroads mouths | W (wing-bay door 28), E (shed W door 28), N (to G2, 89), S (baffle -> shed W face, 141) | 4-way at the flag |
| slab-fan chicane | slab E face -> fan pile (x 806..863) | 57 — the corridor's mid choke |
| shed-S slot | shed S face -> truck trailer / sheet | 40 / 26 |
| Depot doors, Warehouse doors x4, Hangar doors N/S + mouth | | 24 / 28 / 28+174 |
| heap -> engine pen | x 942..968 | 26 [ADJ: heap shrunk r36] |
| pen -> NE crates | x 1029..1054 | 25 |

Chokepoint [ADJ] ledger (measured -> shipped): wing bay -65x and long-shed
west face 604->695 (forced-ring clearance -> creates the Crossroads); shed
east 909->899, fans regrouped, wrecks north, MG north, F1 -36y, cutting-shed
west 302->330 (spawn-pocket clearance); F4 +30x (opens G3); baffle restored
to full measured height (mid-west barrier); doors staggered (Depot NE,
Warehouse E, Hangar S) and small scrap welded (parts pile, sheet, shoulder,
container +61y, tail wreck NE) to break over-long straight runs.

Invariant compliance (all measured on the masks, engine carves applied):
- **Forced-carve chew: 0 px** across all four masks (ring + both pockets).
- **No full-span open row or column.** Longest open row run: 497 px (y=488,
  the south street east of the baffle, capped by baffle and hangar pier).
  Longest open column run: 488 px (x=460, the G1 cut, capped by the north
  fence and the warehouse) — G1 is the map's deliberate fast flank and the
  north medkit sits at its head.
- **No sealed pockets:** 1-px flood from `redHome` reaches `blueHome`, both
  medkits, and all 13 interior/court probes (Depot, Workshop, wing bay, long
  shed, cutting shed, crane, Warehouse, Hangar, north-shed bay, annex nook,
  NE pocket, SE yard, Crossroads); no unreachable floor component over 40 px.
- **Pickups on occupiable floor:** both medkits sit on carved floor with
  measured wall clearance 20 px (warehouse) and 45 px (north street); all
  four trench rects lie entirely on carved floor (they hug cover by design —
  they are pits, not pickups).
- Doors/passages >= 24 px everywhere (schedule above).

Verification renders for this plan: `/tmp/scrapyard_plan_view.jpg`
(canvas-scale color overlay: masks + trenches + ring + homes/spawns/medkits +
lane polylines + 100-px grid) and the four masks with white-pixel counts in
`docs/designs/mw2-reference/scrapyard-v2-masks/README.md`. Regenerate via the
measurement pipeline in this doc's provenance note if the reference plate or
scale changes.
