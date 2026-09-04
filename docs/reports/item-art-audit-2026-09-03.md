# Item completeness audit: matrix × layers (T2 slice seed)

Epic 1ef4f9d6 ("Item completeness — every item fully real in every layer"),
task **P0 · T2 Ground-art gap closure** (the `bandages` lane). This doc is
the audit table T2 needed to scope its own work; it also seeds T1's fuller
census (matrix × ALL layers incl. exchange/HUD/wiki, file:line per cell).

Scope of what was actually fixed in this slice: **ground sprite art for
bandage / gun crate / hopper crate**, wired end-to-end (asset → loader →
sprite/object id pools → both packet-builder call sites). Everything else
below is audited, not built, in this slice.

## Method

Grepped the engine's item enums/defs and their broadcast render paths in
`src/ctf/` (sim_types.nim, sim_config.nim, sim.nim, global.nim, rig_art.nim,
labels.nim, broadcast.nim) plus the SDK perception layer in `src/shell/`
(body.nim, view.nim). Every cell below is a direct code read, not inference.

## The item kinds (9 real, 1 phantom)

| kind | sim field(s) | config gate | file:line |
|---|---|---|---|
| med kit | `medKitSpawns` | always on (map-authored) | sim_types.nim:1608, 3600 |
| shield | `shieldSpawns` | always on (map-authored) | global.nim:6049 (`addShields`) |
| grenade (paint bomb) | `grenadeSpawns` | always on | global.nim:6187 (`addGrenades`) |
| spray can | `sprayPaintSpawns` | always on | global.nim:5987 (`addSprayPaints`) |
| barrier | `barrierSpawns` | `barrierPickups > 0` | global.nim:6456 (`addBarriers`) |
| **bandage** | `bandageSpawns` | `bandagePickups > 0` | sim_types.nim:3884 |
| **gun / marker crate** | `weaponSpawns` | `lootStart` (brMode only) | sim_types.nim:1803, 3879 |
| **hopper crate** | `hopperSpawns` | `lootStart` (brMode only) | sim_types.nim:1807, 3882 |
| perks (armor/scope/grenade/thruster/luck) | `config.perks[team]` | authored per-team/policy at config time | sim_config.nim:460-524 |

**"scope" is a PHANTOM as a ground/pickup item.** It is one of 5 team-level
**perks** (`PerkNames = ["armor","scope","grenade","thruster","luck"]`,
sim_config.nim:490-491) — a permanent stat modifier (50% less aim deviation,
`scopeAim: 500`, sim_types.nim:4150) assigned in the match config JSON
(`{"red":["armor","scope"]}`) or per-policy, never spawned or picked up on
the map. It already has full visual coverage: an inline SVG scorebug badge
(`PERK_ICONS.scope`, `client/chrome_common.js:237-241`) and a tooltip string
(`perkTitle`, `client/chrome_common.js:274`). **No ground sprite is missing
because none was ever designed — do not draw one.**

## Layer matrix

Columns: **world sprite** (this slice) · **HUD/pickup token** (wire
`item_pickup`/`map_item`) · **on-use effect** · **SDK perception**
(pik/sik/bik) · **exchange (dHandoff)**.

| kind | world sprite | wire pickup token | on-use | SDK perception | exchange |
|---|:-:|:-:|:-:|:-:|:-:|
| med kit | ✅ | n/a (full-heal-on-touch) | ✅ full heal | ✅ `pikMedkit`/`sikMedkit`/`bikMedkit` | n/a (not carryable) |
| shield | ✅ | n/a | ✅ | ✅ `pikShield` | n/a |
| grenade | ✅ | n/a | ✅ | ✅ `pikGrenade` | n/a |
| spray can | ✅ | n/a | ✅ | ✅ `pikSpray` | n/a |
| barrier | ✅ | n/a | ✅ | ✅ `pikBarrier` | n/a |
| **bandage** | ✅ **FIXED this slice** | ✅ `"bandage"` (broadcast.nim:773,967) | ✅ +1hp self-apply, 72-tick calm clock (sim.nim:3894) | ❌ **GAP — no `pikBandage`/`sikBandage`/`bikBandage`; only `pikMedkit` exists** (view.nim:93-99) | ✅ `giveDeclItem` whitelist incl. `"bandage"` (sim_types.nim:2923) |
| **gun / marker crate** | ✅ **FIXED this slice** | ✅ `"gun"` (broadcast.nim:771,965) | ✅ grants `hasGun` (sim.nim:3948) | ✅ `pikGun`/`sikGun`/`bikGun` (view.nim:92, landed glory-2 §17) | ✅ `"gun"` in whitelist |
| **hopper crate** | ✅ **FIXED this slice** | ✅ `"hopper"` (broadcast.nim:772,966) | ✅ grants `hasHopper` (sim.nim:3967) | ✅ `pikHopper`/`sikHopper`/`bikHopper` | ✅ `"hopper"` in whitelist |
| perks incl. scope | n/a (config-time, not a pickup) | n/a | ✅ (stat modifiers apply automatically) | n/a | n/a |

**Before this slice: bandage/gun-crate/hopper-crate had sim-side touch/pickup
logic (`pickupByTouch`, sim.nim:3894/3948/3967) and wire pickup tokens
(broadcast.nim) but ZERO board presence** — confirmed by grepping
`global.nim` for `addWeapon*`/`addHopper*`/`addBandage*` procs (none existed)
and for object-id pool bases (none allocated). A cog could walk straight
through a crate it could not see. This is a genuine, complete gap, not a
wiring bug — no code called `addBoardObject` for these three at all.

**One more real gap found (not fixed, flagged for T5):** bandage has no SDK
perception kind. `pikMedkit`/`sikMedkit`/`bikMedkit` exist but there is no
bandage-specific twin — a play cannot currently distinguish "there's a
med kit" from "there's a bandage" via the perception SDK, even though the
board now renders them as visually distinct pickups. Grepped
`src/shell/view.nim` and `src/shell/body*.nim` for `pikBandage`/`bikBandage`/
`sikBandage`: zero hits.

## What this slice built (commits on `maxwell/bandages-visible`)

- **Assets**: `data/bandage.png`, `data/gun_crate.png`, `data/hopper_crate.png`
  (700×700 RGBA, chunky bold-outline painted style matching
  `medkit.png`/`shield.png`/`paintbomb.png`/`spraycan.png` — generated via
  the nano-banana skill on a flat magenta backdrop, chroma-keyed to real
  alpha, cropped/padded to a square canvas).
- **Loaders**: `loadBandageSprite`/`loadGunCrateSprite`/`loadHopperCrateSprite`
  in `src/ctf/rig_art.nim`, same `loadRgbaSprite(..., alphaCutoff=128)`
  pattern as every other neutral pickup.
- **Sprite/object id pools**: `BandageSpriteId=1495`/`GunCrateSpriteId=1496`/
  `HopperCrateSpriteId=1497` (free run after the barrier statics, clear of
  the corpses at 2900) and `BandageObjectBase=35586`/`GunCrateObjectBase=35650`/
  `HopperCrateObjectBase=35714` (free run after the spray-can pickups, each
  `NeutralItemPoolWidth`=64 wide, clear of the barrier pickups at 36600) in
  `src/ctf/global.nim`, registered in both compile-time collision audits
  (`BoardObjectPools`, `BoardSpritePools`).
- **Render procs**: `addBandages`/`addGunCrates`/`addHopperCrates` in
  `global.nim`, modeled exactly on `addMedKits` (fog-gated by
  `fovVisibleAt`, sprite defined lazily), wired into BOTH packet-builder
  call sites (the per-player POV stream and the board/replay stream).
- **Labels**: `LabelBandage="bandage"`, `LabelGunCrate="gun crate"`,
  `LabelHopperCrate="hopper crate"` in `src/ctf/labels.nim`. Not added to
  `PolicyScannedLabels` — the reference policy does not read them yet
  (that's T4/T5 territory); the golden manifest (`tests/label_manifest.txt`)
  is unaffected because the new render procs emit nothing when
  `bandageSpawns`/`weaponSpawns`/`hopperSpawns` are empty (the default) —
  verified by re-running `tests/test_label_contract.nim` and
  `tests/test_sprite_collisions.nim` clean.
- **Visual proof**: `tools/loot_art_probe.nim` (probe pattern from
  `tools/spray_probe.nim`) poses three pickups directly, renders a real
  board frame via `buildSpriteProtocolUpdates`, and crops each — confirms
  both the pixels and the wire labels (`sprite 1495 "bandage"`,
  `sprite 1496 "gun crate"`, `sprite 1497 "hopper crate"`).

## Placement (T3) — explicitly OUT of this slice's scope

The epic's own fan-out (`~/.ctf/handoff/2026-09-02-tg5-fanout-ledger.md`,
"T1 census → **T2 art gaps (bandages lane = first slice)** → T3 placement →
...") assigns placement to a separate task
(`f6bd0708-1e69-4770-a880-e89ce761ff32`, "P1 · T3 Placement gap closure").
Sprite existence was a hard prerequisite for that lane (arming placement
before the sprite renders is a dark ship) — that prerequisite is now
satisfied for all three kinds. No placement/config changes were made here.
