# CARDBOARD — the deployable box-fort panel

> **⛔ SUPERSEDED (2026-08-26, Maxwell's review).** Cardboard already exists: David
> Bloomin's **barrier** item — PR #255 / commit `d3aa603`, on `origin/main` since Aug 7,
> config-gated behind `barrierPickups`. His design (a half-hex paint-blocking band that
> touches no mask and reads correctly from the top-down camera) supersedes everything
> below; this document was written unaware of it, from a branch that forked before #255
> landed. Kept only as a reference for its measured placement-funnel method and A/B
> framework. The box-fort art was rejected — it doesn't fit paintbot's camera.

**Season 2 mechanic · design one-pager · DESIGN REVIEW, not a build spec**
Author: Season 2 design lane, 2026-08-26. Status: **rejected/superseded — see banner.** Nothing
below is implemented; no engine file was modified to produce it.

---

## 1. The pitch, and why it belongs in paintbot

Real paintball fields are not made of stone. They are made of **bunkers** — inflatables on a
pro field, and, on every backyard and church-hall field a kid has ever played, **cardboard**.
A flattened fridge box propped on its wings is the original paintball bunker. Paintbot has
carved-stone arenas and no way for a cog to change the field it fights on. CARDBOARD is that
verb: *pick up a board, set it down in the open, and now there is cover where there was none.*

The register is exact and it is the whole reason this item is right: cardboard does not
*break*, it **soaks**. You shoot it, it goes blotchy, it goes soggy, it sags, it falls over in
a wet flop. Nobody is destroyed; the fort just gives up. That is the kids'-paintball read, and
it is also, conveniently, a clean bounded resource model.

One sentence of design spine, from which everything else falls out:

> **A board is a wall you can carry, that your enemy can wash away, and that a grenade goes
> straight over.**

---

## 2. Supply — where cardboard comes from

**Cardboard is a floor pickup that sits ON the line of symmetry, and it is contested by
design.** Every other item spawns in a mirrored pair tucked into the back columns — spray cans
and shields at `ArenaBorder + 40`, deep in each team's own half, effectively free. Cardboard
does not get that treatment:

- **Two spawns, both at `x = MapWidth div 2`** — `(617, 164)` and `(617, 494)` on arena, both
  verified walkable. Sitting exactly on the vertical centre line makes them **self-mirrored**:
  431px from each heart, identical for both teams, no geometric advantage possible.
- Respawn **45s** (`1080` ticks) — 9× a grenade corner (5s), 1.5× a med kit (30s). Boards are
  the scarcest item on the field.
- Walk-over auto-pickup at the standard 12px touch radius, like everything else.

Putting the supply at midfield rather than at home is a **deliberate counterweight to the
defensive bias in §6**: the item that helps you hold ground can only be got by leaving it.

**Cardboard and a grenade are mutually exclusive in the hands.** Holding one refuses the
other's pickup. This is not a storage limitation, it is *the* design choice of the item:

| you are holding | you can | you cannot |
|---|---|---|
| a grenade | throw paint **over** a board | make cover |
| a board | make cover | throw paint over a board |

The two items are exact counters, and choosing between them is a real read on the state of the
match. It also means the human's **Space** key is never ambiguous: whatever is in your hands is
what Space uses.

### The supply-cycle trap (measured, do not skip)

The obvious alternative — "add cardboard to the veteran supply drop" — **is a silent no-op**,
and the reason is worth writing down. `SupplyDropCycle` is `["med kit", "grenade", "spray can",
"shield"]` (glory.nim:701) and the slot index is `player.supplyDropsThisLife`, bounded by
`SupplyDropMaxPerLife = 4`. Slots only ever run `0..3`. **Appending a fifth entry produces an
element the rotation can never reach.** Any future proposal to put cardboard in the drop must
*reorder* the cycle or raise the per-life cap, and must say which — an append will compile,
ship, and do nothing.

---

## 3. Placement — the rules, and the measured funnel

**Space (engine: the `c` button) places the board one cog body in front of you, broadside to
your aim.** You set a board down the way you'd drop a fridge box: facing out, so it covers the
direction you were looking.

| property | value | why this number |
|---|---|---|
| panel size | **68 × 16 px** | 68 = two cog bodies (`SoldierBodyPx` 34), so a cog and a strafe both fit behind it. 16 = **2 × `FovCellSize`** — see §5, it is the thinnest panel the fog grid cannot leak through. |
| stand-off | **40 px** ahead of the cog centre, along aim | leaves ~30px of clear floor between your body and the board: you are behind it instantly, but not fused to it. |
| orientation | **snapped to 8 facings** (45°) | maps exactly onto geometry the engine already has: 4 are `shapeRect`, 4 are `shapeDiagonal`. **Cardboard needs no new geometry primitive.** Integer, so it survives Season 2 smooth aim without a determinism argument. |

**A placement must pass all five gates, or it is refused and the board stays in your hands.**

1. **Every stamped pixel is walkable.** Reuses `isWalkable`; no overlap with existing cover.
2. **Not in a capture column** (`x < 210` or `x ≥ 1025` on arena, i.e. `ArenaCaptureClear`).
   This is the engine's own protected floor — the region the map generator itself refuses to
   wall, because carriers must always be able to get home. A board across a capture column
   could deny a heart return, so this ban is not tuning, it is a rule.
3. **16px of clearance from existing cover at both panel ends.** Cardboard contests *open
   ground*; it does not thicken stone or seal a doorway. 16 is chosen as the smallest value
   strictly greater than a cog's 13px solid footprint (`PlayerHalf` 6) — so **the gap beside a
   board is always at least one cog wide.** That single fact doubles as the anti-trap
   guarantee: no placement can ever wedge a cog into a pocket it cannot leave.
4. **No player of any team inside the footprint.** You cannot crush or cage anyone.
5. **≥ 102px (three cog bodies) centre-to-centre from any live friendly board.** The anti-fort
   rule. Boards make a *position*, never a *maze*.

Plus a standing cap: **3 live boards per team.** A 4th placement collapses your team's oldest —
it never refuses, so a human never gets a dead keypress, and a policy never needs to model a
failure case.

### Measured: does anyone ever get to use this?

The lesson banked from ported gates is that a rule set can be perfectly reasonable and still be
**unreachable**, so this was measured against the real arena walk mask before it was written
down, not after. The first draft used a 34px end-clearance. It collapsed legal placement to
**10.0%** of standable floor — an item you could almost never use.

| end clearance | mean per-facing | any-of-8 facings |
|---|---|---|
| 0 px | 17.3% | 56.5% |
| 12 px | 12.3% | 47.4% |
| **16 px (chosen)** | **8.9%** | **39.2%** |
| 26 px | 3.5% | 20.3% |
| 34 px (first draft) | 1.3% | **10.0%** ← dead item |

At 16px, **39.2% of standable floor has at least one legal facing**, and the legal region is
the open midfield and the lanes — precisely the ground the item is meant to contest, and
mirror-symmetric by construction. See `cardboard-funnel.png`.

---

## 4. Durability — soak, sag, flop

A board has **8 soak**. Paint that lands on it takes soak off; at zero it falls over.

| source | soak | note |
|---|---|---|
| gun shot | **1** | the shot already stops at the board — shots march to the last wall-free pixel |
| spray cone | **3** | per *activation*, not per active tick |
| grenade blast in radius | **3** | and the blast still hits everyone behind it — see §5 |

Eight soak is **~4 seconds of one shooter's uninterrupted output** (`FireCooldownTicks` 12 → 2
shots/sec), or two grenades and two shots. It is deliberately priced at *less than three cogs'
worth of paint* (a cog is 3 hp): a board buys you one fight, not three.

**Independently, a board expires after 45s** (`1080` ticks), whichever comes first. The timer
is what stops an uncontested board from becoming permanent terrain, and it is why cardboard can
never quietly re-author a map over the course of a long game.

**Four visual states, purely cosmetic until the last one:** crisp → speckled → soggy → sagging.
The soak state is *legible from across the board* so both a human and a spectator can read
"that board is nearly gone" without a health bar. On collapse the panel stops blocking at end
of tick and leaves a flat splat decal on the floor (chrome, not contract).

---

## 5. Collision, line of sight, and the four-layer cover raster

Existing cover is emitted in four layers — **structure → fill → centre feature → row pickets** —
all of it inside `leftObstacles`, all of it mirrored, and all of it **baked once** at map load
into `walkMask`, `wallMask`, `fovBlocked` and the map art. Cardboard is a *fifth* layer and it
differs on all three axes that matter:

| | layers 1–4 | cardboard |
|---|---|---|
| when | baked at map load | mutates mid-tick |
| symmetry | mirrored by construction | **asymmetric** |
| budget | generator's (~120–170 permille) | **set by players** |

**How much cover does it actually add?** A panel is 1088 px²; six live panels (3 per team) is
6,528 px² against an 813,865 px² arena = **8.0 permille**, or ~5% relative to a ~165pm board.
Small in area — but cover is bought in *lanes*, not permille, and one board across a midfield
sightline is worth far more than its area. **The permille number is the reassurance that
cardboard cannot break map-fairness validation; it is not the fairness argument.** That is §6.

### What the engine gives us for free

Nearly everything, because **every consumer already routes through the same two masks**:

- `wallMask` — bullets (`isWall` march), `lineOfSightClear`, spray-cone victim selection.
- `walkMask` — movement (`canOccupy`). The two masks are exact complements built from one
  bool, so **one stamp updates both.**
- **Policy pathfinding, free.** `buildWalkabilitySpritePixels` reads `sim.walkMask` live and
  publishes it as the `walkability map` sprite that every policy already decodes. A board
  appears in every bot's navigation mask with **zero policy changes** — the single strongest
  argument that this item is league-legal rather than a human-only toy.

### Three things it does NOT give us free — the real build cost

1. **🚨 The walkability sprite is deduped and would never re-send.** `addSpriteChanged` only
   re-emits when *width, height or label* change, or when the caller passes `changed = true`
   (global.nim:1199). The walkability sprite is emitted with the default `changed = false`, so
   it ships **once per game and never again**. A board would stamp `walkMask` and **no policy
   would ever see it.** This is exactly the silent-failure class `labels.nim` exists to warn
   about: no crash, no assertion, bots simply path through cardboard forever. *The build must
   pass `changed = <walk mask dirty this tick>`.* Non-negotiable, and it needs its own test.
2. **Fog cache invalidation.** `PlayerFov` is keyed on `(originCx, originCy, aimBrads, valid)`
   with no notion of the world changing. A cog standing still, aim unchanged, would keep a
   stale visibility grid straight through a board that just appeared. Needs a **`fovEpoch`**
   bumped on every stamp/collapse and compared in `refreshPlayerFov`; the affected `fovBlocked`
   cells need a local rebuild (a panel touches ~9×3 cells — cheap, not a full-grid pass).
3. **The panel is opaque, and 16px is why.** `buildFovBlocked` marks a fog cell blocking when
   ≥ half its 8×8 pixels are wall. Measured across every sub-cell alignment: a 10px or 12px
   panel degrades to an **8px** fog occluder at some alignments (its shadow shifts depending on
   where the placer happened to stand); **16px = 2 × `FovCellSize` is the thinnest panel whose
   fog occluder is never thinner than the panel itself.** Cardboard is a box, not a window — it
   is not `window: true` glass, it occludes.

### The interactions that are the design

- **A grenade goes over a board.** Blast damage is a pure radius with no LOS test, and the
  label contract already publishes this to policies (`grenade air`: *"It travels OVER walls"*).
  So cardboard's counter already exists, is already perceivable, and needs no new code. **This
  is the single most important balance fact in the document.**
- **A board blocks your shots as hard as theirs.** It is cover, not a shield: two-sided by
  construction.
- **A board can eat a committed shot.** `windupBrads` locks aim at trigger pull; a board set
  during someone's 5-tick windup eats the shot they already paid for. Skilful, symmetric, and
  available to any policy that can time a `c` press.
- **Pings are unaffected** — `ShoutRange` is a radius, never LOS-gated.
- **Map art does not change.** Boards are live objects (the precedent is `AnimatedDiamonds`),
  never baked into `mapImage`, so **`PoolRenderHashes` should come out byte-identical** — a
  cheap, checkable assertion that this feature did not disturb the map pool.

---

## 6. Fairness — the free-wall problem, stated honestly

**Cardboard is the first asymmetric cover in paintbot.** Every wall on the field today exists
in mirrored pairs. A board does not. That is the whole fairness question and it deserves a
straight answer rather than a reassurance.

**The risk is not "cover is strong". It is "cover is defensive".** The Andre meta study puts
88.3% of winning play in defence and fast reconquest; a free wall is worth more to whoever is
*holding* than to whoever is *crossing*. Left unbounded, cardboard makes stalling cheaper, and
stalling is the failure mode this game has already legislated against once (GameVersion 21 made
a timeout **−1 for everyone**, both sides).

Five bounds, each answering a specific way the free wall could go wrong:

| the failure | the bound |
|---|---|
| fortify the objective | **capture-column ban** — no board within 210px of either heart |
| build a maze | **102px separation + 3-per-team cap** |
| thicken existing stone | **16px end clearance** — boards live in the open or nowhere |
| permanent terrain | **45s expiry**, independent of soak |
| a wall you cannot answer | **8 soak; grenades pass over it entirely** |

Two structural points in cardboard's favour:

- **It is two-sided.** Every board you set is a board you must shoot around.
- **Supply is mirrored and scarce.** Two spawns, 45s respawn, and holding a board costs you the
  grenade slot. A team that boards up has disarmed itself.

**The honest residual risk**, and the reason the A/B below leads on stalls: a board is worth
more to the team that is *ahead*, because they have less need to cross. The 45s timer is the
main defence and it is a guess. **If the A/B shows the timeout-draw rate rising, the timer is
the first knob to cut, not the soak.** Stated in advance so the result cannot be re-read after
the fact.

---

## 7. Policies must be able to place it — the symmetry rule

Maxwell's governing rule: *every key binds to something a policy could also do.* Cardboard
satisfies it without a single new wire bit.

**Action.** The engine action space is the 8-bit `InputState` mask
(`up/down/left/right/select/attack/b/c`). `b`/`select` are aim rotation; `attack` is
gun-or-spray. **`c` is already the deploy button** (grenade hold-charge/release), so cardboard
places on a `c` **tap**, and hand-exclusivity (§2) makes the meaning of `c` unambiguous at every
instant. Every policy in the league can already emit `c`.

> **One correction to the brief, stated plainly.** "Space throws grenade, spray can, places
> cardboard" is right as a *human control*, but the spray is not an item-use — it is a weapon
> that replaces the gun and fires on `attack`. So Space is a **client-side item key** that emits
> `c` when you hold a grenade or a board, and `attack` when you hold a spray can. One key for
> the human, zero ambiguity for the engine. No engine change is needed to honour the intent.

**Perception.** Four additions to the label contract (`labels.nim`), following its own
flat-vs-prefix rule:

| label | kind | meaning |
|---|---|---|
| `cardboard` | flat | the floor pickup, fog-gated by position |
| `cardboard carried` | flat | marker over a carrier you can see |
| `cardboard panel <color> <soak>/8` | **prefix** | a placed board: whose, and how soaked |
| `board` | token | `identity` badge suffix, beside `shield` / `nade` |

A policy can therefore see boards, tell whose they are, tell which are nearly gone, path around
them (free, via the walkability map), and place its own. Adding these is the documented
**four-surface change**: `labels.nim`, `tests/label_manifest.txt`, `docs/RULES.md`, and
`players/baseline/`.

**Determinism.** No RNG: placement is a pure integer function of `(x, y, snapped aim)`.
Simultaneous placements resolve in player-index order, so the second may legitimately fail the
102px separation gate — deterministic, and correct. Panels go in `gameHash` (count, then per
panel: x, y, facing, soak, team, `expiresAt`), following `supplyDropPickups` exactly. Replays
re-simulate, so panels reconstruct from inputs alone.

---

## 8. The A/B plan

**GameVersion `24` → `25`.** Fixture re-records required (gameHash moves for every replay).
Arm the mechanic **in the build, never via container ENV** — the banked rule after the barrage
lever was never actually armed.

**Phase 0 — null.** Cardboard-OFF vs cardboard-OFF, same build, same seeds. The harness null
must come out ~zero before any arm is believed.

**Phase 1 — mechanic on, policies naive.** Champion vs champion, cardboard available but no
policy taught to use it. Answers: *does the item's mere existence disturb the game?* Expect
near-null. A large effect here means the item is doing something nobody chose.

**Phase 2 — one side taught.** Champion + a minimal cardboard behaviour vs unmodified champion.
This is the only phase that can say whether the item is **decoration**.

| | metric | why |
|---|---|---|
| **Primary** | **timeout-draw rate** | the stall detector, and already −1 for both sides |
| **Primary** | captures per episode | did the item change who scores |
| Dense secondary | shots fired per episode (contact volume) | captures are rare; a rare outcome is the wrong primary to *steer* on |
| Item health | boards placed / episode; mean board lifetime; **% of boards ever shot at** | a board nobody shoots is a board nobody cared about — the discrimination test |
| Fairness | per-team placement counts under mirrored policies | a systematic asymmetry is a positional exploit, not a preference |

**Pre-registered kill criteria** (written before the run, so the result cannot be re-read after
it):

- timeout-draw rate up by more than **3pp** → **cut the 45s timer first**, re-run; soak is not
  the suspect.
- median board lifetime **> 15s under contest** → too tanky, cut soak 8 → 5.
- **< 25% of boards ever take a single hit** → the item is decoration; do not ship it, redesign
  the placement rules.
- Phase 2 shows **no measurable edge** for the taught side → cardboard is a human-facing toy,
  which fails the governing rule. Cut or redesign — do not ship it as a human-only control.

---

## 9. Open questions for Maxwell

1. **Boards in the centre ring?** The 70px flag ring at midfield is protected floor for the
   *generator*, but the hearts sit in the spawn pockets, not there. This draft **allows** boards
   in the centre ring — it is the most interesting ground on the map. Say the word and it joins
   the ban list.
2. **The 4th board: collapse-oldest or refuse?** Drafted as collapse-oldest so a human never
   gets a dead key. Refusing keeps the item in hand and is arguably fairer to a policy.
3. **Should a collapsing board damage anyone?** Drafted as harmless (it is a wet box). A 1-hp
   flop on whoever is adjacent would be funny and would punish board-hugging.
4. **BR league too, or CTF only?** BR scores 1/sec alive vs 10/kill — cover is worth
   structurally more there, so cardboard is a *different item* on that board and probably wants
   its own tuning pass rather than a shared constant.

---

## 10. Explicitly out of scope

Not stacking or shooting *over* boards (the game is top-down and binary); not destructible
existing cover; not boards as a mapgen layer; not carrying more than one; not a cardboard
variant per team. Each is a fine follow-up and none is needed to answer whether the mechanic
works.

---

### Artifacts

| file | what |
|---|---|
| `cardboard-mock.png` | the placed bunker in-situ. **Not an illustration** — the floor and stone are real engine pixels from `loadMapLayers`, the cogs are `data/soldier_*.png`, the scale is true (68px = two cog bodies), and the placement at arena (473, 199) facing S was verified legal by the funnel probe. Left panel: what a player sees, with a tracer dying on the board. Right panel: the same frame showing what the sim actually stamps. |
| `cardboard-funnel.png` | the measured legal-placement map, over the real arena walk mask |
| `cardboard-states.png` | the four soak states. **Art exploration of the soak *read*, not the silhouette spec** — it draws a four-sided box fort, whereas §3 specifies a 68×16 panel with wings. A 4-sided fort gives 360° cover and would be a fortress; the panel is the game object. The progression crisp → speckled → soggy → sagging is the part to review. |
| `tools/dump_map_art.nim` | new tooling (not engine): dumps real arena art + walk mask, so every mock and probe above works off engine pixels and engine collision instead of a hand-approximated copy |
