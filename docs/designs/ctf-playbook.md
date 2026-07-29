# CTF Playbook — observation-triggered team plays (design)

> Goal (Maxwell, 2026-07-16): "we can't do the same thing every time or we get countered.
> Either flip which side we favor (top/bottom) or run different plays — some offensive, some
> defensive. When observations add up to a certain picture, that play triggers and they ALL
> perform it." Source the plays from the completed Navy SEAL / CQB deep-research.

## The hard problem: consensus without reliable comms

For a "play" to be coordinated, all 8 bots must pick the **same** play on the **same** tick.
But comms in this game is a lossy 10-char shout heard only within ~247px through walls — a
carrier deep in enemy territory cannot hear the home defender. So we CANNOT elect a play by
voting or by a captain broadcasting it.

### ⚠️ Correction (2026-07-16, verified against sim.nim): NO per-game entropy exists

The original design keyed the strong-side flip off "a per-game seed hashed from the opening
spawn layout." **This is impossible.** `SimServer.spawnPosition` (src/ctf/sim.nim:1934) is a
*pure deterministic function* of team + seat order — no seed, no RNG. Every game opens
BYTE-IDENTICALLY. So a salt hashed from the opening frame is the SAME every game, and the strong
side would never flip. More generally: **cross-game variation with consensus is fundamentally
impossible from observation alone**, because there is nothing in the observation that both varies
per game AND is shared across teammates (each bot's cumulative `bot.tick` differs by connection
time, so a persistent game-counter isn't shared either).

**What IS shared and usable.** Two signals are provably identical across all 8 teammates:

1. **Elapsed-since-round-start** — `elapsed = bot.tick - bot.gameStart`. Every bot resets
   `gameStart` on the same broadcast lobby→Playing frame and advances `tick` by the same
   `frameAdvance` each frame (all seats receive the same broadcast stream), so *elapsed* is the
   same integer for every teammate even though absolute `tick` is not. This is the shared CLOCK.
2. **Own-flag / carry status** — `ownStolen` and `mateCarry` are globally legible (the planted
   banner is visible to any teammate; once stolen it disappears for everyone; a mate carrying is
   team-radioed). This is the shared STATE.

Anything only *locally* observed (I personally see 3 enemies) must NOT drive the play — my
neighbor sees a different picture and would split the team. Local reads stay in the per-bot
combat layer (already built); the PLAY layer keys ONLY off the two shared signals above.

**How we get unpredictability without per-game entropy.** The favored flank OSCILLATES on the
shared clock — `favorTop = ((elapsed div PlayPeriod) and 1) == 0`. The strong side flips every
`PlayPeriod` ticks on a schedule all 8 bots share, so an opponent who pre-stacks one flank finds
us on the other half the time and must track the shift *live* instead of scouting it once. The
unpredictability lives on the TIME axis, not a per-game seed. Posture (offense↔defense) is driven
by the shared flag STATE, which the existing `ownStolen`/`mateCarry` branches already handle.

## The plays (grounded in the SEAL/CQB deep-research, wf_eb814b4e, 70/70 claims survived)

Each play is a **role→posture remap** layered on top of the existing role system. The play does
not micro-manage combat (that stays per-bot doctrine); it sets each role's *objective bias*.

| Play | Trigger (shared read) | Doctrine basis | What each role does |
|------|----------------------|----------------|---------------------|
| **STRONG-SIDE PUSH (top)** | `favorTop` this game AND own flag safe | *Point of domination / mass at the decisive point* (ADP 3-90) — concentrate combat power on one flank | 4 of the 6 attackers weight to LaneTop; 2 hold a light bottom feint. Overwatch posts high. |
| **STRONG-SIDE PUSH (bottom)** | `not favorTop` AND own flag safe | same, mirrored | mass on LaneBottom, feint top |
| **STACK DEFENSE / RECAPTURE** | `ownStolen` | *Break contact only when you can't win; otherwise assault the objective* (#9 fire-superiority) — but the objective is now the THIEF | back line + nearest 2 attackers converge on the thief's home-bound crossing; 1-2 keep pressing enemy pedestal to keep the capture race alive |
| **ESCORT / CONVOY** | a teammate is carrying (`mateCarry`) | *Bounding overwatch, one gun always up* (#6) | attackers collapse onto the carrier's lane and body-screen the respawn cone; the carrier runs, never fights |
| **PROBE / RESET** | mid-round stalemate (long since either flag moved) | *Two-speed scan + tempo on the half-beat* (#8) — change the tempo to force an error | shift the favored side, push a fresh flank the enemy hasn't had to defend |

The **top/bottom flip is per-game** (from `gameSalt`), so an opponent who scouts our last game
and pre-stacks that flank finds us on the other one. Offensive vs defensive posture is
**state-driven** (own-flag status), so we're not predictable there either.

## Counter-daveey lever (specific)

Maxwell: "daveey always goes to the top of the map." When we detect we're likely facing daveey
(or simply as a robust default vs a top-heavy field), the **STACK DEFENSE** play biases the
thief-intercept guess and the home Overwatch post toward **LaneTop**. This is a *defensive*
counter that doesn't cost us when wrong (a top-posted sniper still covers the ring), and when
right it puts a gun exactly where his carrier runs.

## Implementation shape (incremental, each A/B-gated)

- New `Play` enum + `proc selectPlay(bot): Play` computing ONLY from shared bits above.
- `gameSalt` = a hash folded once at `resetTransient` from the opening frame's own-team spawn
  layout (identical across seats). Store on `Bot`.
- Each play maps to small deltas already expressible in the current code: a lane bias for
  `safestLaneY` / flank targets, a posture flag for the retreat/press decision, and the
  thief-intercept lane bias.
- Gate the whole system behind `tune.playbook` (default off) so it A/Bs cleanly vs the current
  champion, exactly like every prior lever. **Validate seat-rotated, never mirror** — a playbook
  that varies our side is only measurable against a field that does NOT get the same variation.

## Why this beats "one fixed strategy"

A fixed policy is a fixed target: an opponent that logs our games converges a hard counter. A
playbook that (a) flips its strong side per game from a shared seed and (b) switches
offense↔defense off globally-legible flag state presents a *different* board each game while
staying internally coordinated — the SEAL principle of *seizing/retaining the initiative*
(ADP 3-90) rather than reacting.

## Addendum (2026-07-18/19): three levers picked up from the v14 handoff

Three CombatTune levers were added on top of the shipped champion, each **GATED OFF** in
`shippedCombatTune` and behind a harness env-knob. None is shipped — all await a hosted
mixed-field A/B before they go into the champion.

### preSlew — "fire first" (ported from v14, `PRESLEW`)

When we have no clear shot **this** frame, `aimLock` pre-lays the turret on the freshest
engageable-range enemy whose gun points **most off us** — the draw we win — instead of the
merely-nearest. Our ~5-tick windup then completes while its turret is still slewing onto us
(the OODA half-beat), so our bullet leaves first. A fire-*timing* choice inside aimLock's
existing on-objective candidate set; requires `aimThreat` (the enemy aim-dot read) and falls
back to nearest when a dot is unreadable. **Not** the refuted `huntSweep` (which aimed
off-objective and traded wins for kills). Mirror-measurable in principle (it's a mechanical
aim choice), but it needs the aim-dot to be present, so validate against a real opponent.

### staggerFire — "staggered bounding" (ported from v14, `STAGGERFIRE`)

The complement of `boundingOverwatch`. When **my** gun is up but a covering mate's gun is
**down** (a "muzzle bloom stage N" sprite sits on it = it fired inside the 12t reload), HOLD
my up-gun on the crossing to cover its reload instead of bounding forward and leaving the lane
with no live team gun. Turns a pair into alternating bounds (one gun always live), killing the
"both empty on one beat → focus-fired wipe" death-burst. Movement-only; never throttles my own
trigger (the engage branch always wins a clear shot), so it cannot regress into fire-discipline
tuning. Engine-safety confirmed: the current live engine still emits the muzzle-bloom sprite
label the read depends on.

### regroupPush — post-wipe consolidation (NEW this session, `REGROUP`)

**The v14 loss cause, addressed.** The 47-episode replay study found we lose by *squandering
the post-wipe man-advantage*: after we clear the enemy nest we feed the ~72t respawn wave one
body at a time and die piecemeal (in losses: cash-the-wipe 0%, squander 47%). Crucially the
same study showed **depth correlates with winning** — we die *deeper* in their half in WINS —
so the fix must be a **timing** correction, not a depth cut.

`regroupPush` fires ONLY in the full squander signature: a **mid** (MidTop/MidBottom/MidGuard)
over-extended past `RegroupPushTrigDepth` (130px) into the enemy half, its local area a
**vacuum** (no fresh enemy within `RegroupPushClearRange`=240px — the just-cleared nest), it is
**not yet grouped** (fewer than `RegroupPushPack`=2 fresh mates within 200px), and support is
**genuinely inbound** (≥1 fresh mate homeward of it). In that case it holds a shallow rally line
just inside the enemy half (`RegroupPushRallyDepth`=70px past center) at its current lane height
until the trio re-forms, then **releases and commits a joint push** for `RegroupPushCommit`=90t
(hysteresis, so the wave doesn't re-hold as it naturally spreads). A lone last survivor
(no inbound support) never holds — nobody is coming, so it presses the grab. Purely a movement-
target gate: the combat block still fires at anything lined up while rallying, and carry/defense
states are untouched.

- **Coordination + trigger-absent lever** — the self-play mirror lies about it two ways:
  it gives *both* teams the regroup (benefit cancels) and its clean-wipe trigger (enemy carrier
  already dead, a mid alone in a cleared enemy half) barely occurs in self-play. **Validate on a
  hosted/asymmetric mixed field, not the lab.**
- **Reachability confirmed** via `-d:rgprobe` (a funnel counter, mirroring the `hsprobe`
  pattern): with the lever on one team over 24 games the rally-hold fired 784× and the funnel
  (reach 109805 → deep 9951 → vacuum 6602 → lone 5407 → support 1261 → **fired 784**) shows each
  sub-condition thinning the population as designed — so the gate is live code, not dead.
- **Paired lab A/B (seed 100, 24g, Red = shipped ± regroupPush vs shipped Blue):** win count
  **identical** (RED 14–10 both); capture wins R7/B5 → R7/B6; grab→cap RED 20.6%→17.1%,
  BLUE 19.2%→24.0%. That is a one-capture swing on ~34 grabs — noise — and the *wrong venue*:
  the v14 squander is a **vs-daveey** phenomenon (his grouped ~72t respawn wave is what we feed
  piecemeal), which self-play against our own champion does not reproduce. No lab regression;
  the real test is a hosted mixed field.
- **Harness caveat learned:** the `REGROUP`/`PRESLEW`/`STAGGERFIRE` knobs only reach seats in
  `HUNTER_SLOTS`. An A/B with no `HUNTER_SLOTS` applies the knob to **nobody** and reports a
  false byte-identical "no-op." Always set `HUNTER_SLOTS` (e.g. the Red seats `0,2,4,6,8,10,12,14`)
  when isolating one of these levers.

## Addendum (2026-07-19): the live league is on GameVersion 7 — sword/shield adaptation

**The finding that reframes everything.** The hosted CTF league
(`league_3243d905-…`) scores on engine **gameVersion="7"** — confirmed by decoding a
real completed-round replay header (round `4e7262cf…`, finished 2026-07-19). Our working
branch pins `GameVersion="3"` and is **76 commits behind `origin/main`** (which is at
`"7"`). v7 (merged to main 2026-07-17..19) adds three objects our bot had never seen:

| Object | Spawn (v7) | Effect | Bot label |
|--------|-----------|--------|-----------|
| **Sword** | side back-column, TOP half (`MapHeight div 4`) | auto-grab on 12px touch; `canFire=false`; the attack button becomes a **26px forward-arc INSTANT kill** (ignores the 3-hit gun, no windup); lost on death | `"sword"`, `"sword carried"`, `"sword swipe"` |
| **Shield** | endzone back-column, BOTTOM half (`3·MapHeight div 4`) | auto-grab; `canFire=false`; **6 HP** tank; lost on death | `"shield"`, `"shield carried"` |
| **Med kit** | center line, 1/3 & 2/3 height | auto-grab if damaged; **heals to full HP** | `"med kit"` |

The bot senses these via `spriteObjectsWithLabel` and **does not crash** on v7 (unknown
labels are ignored). But **auto-pickup is a trap**: walking over a sword or shield silently
sets `canFire=false`, and the bot then "fires" air until it dies.

**Measured self-disarm rate (SS-PROBE, 20 self-play games on a v7 worktree, 484k
alive-ticks):** sword grabbed **8×** (~0.4/game, ~330 ticks held each ≈ 13 s disarmed),
shield **1×**. ~6.3 disarmed-ticks per 1k alive (~0.6% of alive-time gun-dead). Real but
low-frequency — a pure-downside leak, not catastrophic. This is *why "picasso v14 is
winning" holds on v7*: the bot is blind to the new objects, not broken by them.

**Test bed:** a git worktree on `origin/main` (`/tmp/ctf-v7`) with our Picasso
`baseline.nim` + eval harness dropped in and the (gitignored, nimby-generated) root
`nim.cfg` copied over. The v3-authored harness compiles clean against the v7 engine (only
an unused-import warning) — every sim API symbol it needs still exists. `-d:ssprobe` adds
a `swordShieldOf` accessor + per-tick possession counter (guarded, since `hasSword`/
`hasShield` exist only on v7).

### Three v7 levers added to `baseline.nim` (all GATED OFF in `shippedCombatTune`)

- **`avoidDisarm` (`AVOIDDISARM`)** — the pure-downside fix. A soft repulsion (radius
  `DisarmAvoidRadius`=34px) in the navigate steer that pushes a body-width around any
  `"sword"`/`"shield"` pickup we're **not** deliberately collecting. **The only v7 lever
  that is mirror-measurable** — success = the SS-PROBE pickup count on the avoidDisarm side
  drops toward zero while the control side stays at the ~7 baseline. Safe to lab-prove and
  (if it does) ship.
- **`shieldTank` (`SHIELDTANK`)** — a carrier-escort (`MidBottom`/`FlankBottom`/`MidGuard`)
  with our heart stolen and a shield within `ShieldGrabDetour`=120px deliberately grabs it,
  becoming a **6-HP body-block** on the carrier's respawn/threat cone (it can't shoot
  anyway, so trading its gun for a 2× tank on the ray is free). Extends `carrierScreen`/
  `escortRun`. ⚠️ COORDINATION lever — validate hosted, gated OFF.
- **`swordAmbush` (`SWORDAMBUSH`)** — a bot with **no clear ranged shot** boxed in close
  (fresh enemy within `SwordCloseRange`=70px) and a sword within `SwordGrabDetour`=90px
  grabs it, then closes and **swings** (attack-button melee) when the enemy is inside
  `SwordReach`=26px. Wins the point-blank scrum the windup gun loses. ⚠️ trades the gun for
  melee — positional/coordination lever, validate hosted, gated OFF.

Compiles clean on **both** v3 (labels never appear) and v7. Each behind its own harness
knob reaching only `HUNTER_SLOTS`.

### Measured (v7 worktree, `-d:ssprobe`, `HUNTER_SLOTS`=Red, SHIPBASE+CONTROL_SHIPPED)

- **Self-disarm is tune-dependent.** At the **default** tune, 20 self-play games grabbed a
  sword **8×** + shield 1× (~9 accidental disarms). At the **shipped champion** tune it drops
  to **~1 grab per 12–20 games** — the champion's commit/aimLock/lane discipline already keeps
  it off the spawn back-columns incidentally. So the outcome benefit of avoidDisarm is **below
  the noise floor** at n≤20 (win count can't separate it); it's near-zero-cost proven-live
  insurance, not a measurable win-rate lever.
- **Reachability proven (12g, all three ON, Red):** `avoid-repel-frames 267` (avoidDisarm
  actively bends the steer around pickups 267× — LIVE code), `ambush-swing 8` (the sword-melee
  branch fires), but `tank-seek 0` / `ambush-seek 0` — **the two deliberate-grab triggers never
  fire in self-play** (a mate carrying past our own endzone shield, or a boxed-in pocket scrum
  with a sword handy, barely occurs against our mirror). This is the documented coordination-
  lever mirror-lie: `shieldTank`/`swordAmbush` are **field-only**, exactly like `regroupPush`/
  `escortRun`/`huntCarrier`. `avoidDisarm` is the only one the lab can even exercise.
- **Verdict:** `avoidDisarm` is safe to ship (pure-downside removal, proven-live, zero lab
  regression) whenever we port the deployed bot to v7; `shieldTank`/`swordAmbush` stay GATED
  OFF pending a hosted mixed-field A/B. **No bot uploaded** — awaiting explicit go-ahead.
