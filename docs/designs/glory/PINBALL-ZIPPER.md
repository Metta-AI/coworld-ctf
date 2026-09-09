# PINBALL ZIPPER — Glory Gradient Step 2 Study

Program: 25d9108e (GLORY GRADIENT). Gate: S2-lead-approved before Step 3 (TARGET DISTRIBUTION).
Docs only — no sim/scoring/glory code touched, no GameVersion/GLORYVERSION/wire changes in this
step.

**Landing note.** This is the repo-of-record copy of the gate-approved study, landed verbatim from
the lane ledger at `~/.ctf/knowledge/glory-gradient/02-pinball-study-2026-09-08.md` (860 lines) so
the deliverable exists in-repo, not only under local knowledge notes. The knowledge-lane copy
remains the lane's working ledger and continues to accrue lane discussion; this file is a snapshot
of its gate-approved content and is not auto-synced — treat this repo doc as the citable record for
this step's conclusions, and the lane ledger as where any further revision happens before the next
landing. The supporting raw per-researcher material this study synthesizes and cites throughout —
`02a-raw-research-mm-afm.md`, `02b-raw-research-multiball-wizard.md`, and the
`02c-zipper-dimensions/` tree — stays in the knowledge lane and is not duplicated here; this
document already cites rather than pastes it, consistent with how it was originally written.

## Provenance (added 2026-09-09)

The original 5-way `/zipper` fan-out for this study did **not** all fail as the Method note below
originally claimed. Five background researchers' deliverables were misrouted to the manager
session instead of landing in this file; the manager banked them verbatim and they were recovered
and merged into this document on 2026-09-09:
- `02a-raw-research-mm-afm.md` — skill shot + drain risk, all five reference tables (MM, AFM,
  Godzilla, Jurassic Park Pro, Twilight Zone), plus a manager cross-table synthesis.
- `02b-raw-research-multiball-wizard.md` — multiball/jackpot set-up and wizard mode, all four
  core reference tables (AFM, MM, Godzilla, TZ), with code citations and an owner-ruling
  correction (dJointAct pact-gating, GV15).
- `02c-zipper-dimensions/01-bonusx-tally.md` — Bonus-X build-up and end-of-ball tally.
- `02c-zipper-dimensions/02-modes.md` — mode lighting/stacking/failure, all three of MM/AFM/Godzilla.

Sourced material carries real citations (pinball.org, pinballrulesheets.com via tiltforums.com
redirects, planetarypinball.com, robertwinter.com, funwithpinball.com, missionpinball.org, and
WebSearch-recovered snippets of Pinside/GameFAQs/Digital Pinball Fans/Bowen Kerins' rulesheets
where direct fetch was blocked) and explicit per-claim confidence markers. It supersedes
expert-recall specifics wherever the two cover the same ground; where they conflict, the sourced
version is kept and the conflict is named in place — nothing is silently dropped. Merged 2026-09-09.

## Method note (read before trusting the numbers below)

**UPDATE 2026-09-09 — partially obsolete, see Provenance above.** This study was meant to run as
a 5-way `/zipper` fan-out. It was originally believed that **all five background researchers
failed to produce their deliverable file** — that is now known to be wrong for at least five
researcher outputs, recovered as described above. What *is* still true from the original account:
one researcher recursively spawned its own sub-agents and parked waiting on them (the anti-pattern
this step's own instructions forbid) — that lane's output is genuinely lost and not recovered.
Two of the recovered researchers also lost their working worktree mid-task when a sibling agent
removed it (a known hazard in this environment); each names exactly which follow-up grep it could
not finish, and those are carried into "What is NOT verified" below rather than guessed at.

Pinball rulesheet specifics for Medieval Madness, Attack from Mars, Godzilla (Stern 2021),
Jurassic Park Pro (2019), and Twilight Zone are now **live-web-sourced**, with named sources and
per-claim confidence markers given inline in each dimension — treat numbers with a stated
confidence level as sourced fact, not illustrative placeholders. The Paintbot-side code mapping
is grepped fresh against `origin/main`/an in-session worktree by both the original author and the
recovered researchers; those citations are solid.

**Blocked sources** (listed once here rather than repeated per dimension): `ipdb.org` rulesheets
(403 on every table tried — the single richest canonical source, Bowen Kerins'/Brian Dominy's
sheets, was never reachable directly, only via WebSearch-indexed snippets or mirror sites);
`gamefaqs.gamespot.com` (403 on every FAQ/rulesheet page tried); `kineticist.com` (429,
rate-limited, on multiple attempts); `pinside.com` forum threads (blocked on direct WebFetch,
reachable only via WebSearch snippets); `medium.com` (one Medieval Madness wizard-mode
retrospective); `tvtropes.org`; and `web.archive.org` (unavailable to the fetch tool entirely —
not a 403, the tool refuses the host — so no wayback fallback existed for any blocked page
above). Stern's official Godzilla rules PDF was not fetched (over the tool's 10MB limit); Godzilla
detail instead came from `pinballrulesheets.com`, reached via a working redirect from a blocked
`tiltforums.com` URL, and was rich enough that no further source was needed for that table. An
honest study names what it could not reach — the above is that list.

---

## 1. Bonus X build-up

**(a) Reference — SOURCED 2026-09-09.** Confirmed per-table, each with a distinct build-up shape:

- **Twilight Zone** (sourced via pinball.org + WebSearch aggregation): Bonus X caps at **5x**,
  armed by a Right Inlane rollover that lights the Left Ramp for ~5 seconds; shooting it while lit
  adds +1X (and doubles a Robot award). End-of-ball formula: `((500K x hitchhikers) + (500K x door
  panels)) x BonusX`. The Gumball Mystery / Camera / Slot Machine / Clock Millions systems are flat
  mystery-award point pools, orthogonal to Bonus X, not a multiplier feed.
- **Medieval Madness** (sourced via planetarypinball.com, robertwinter.com, WebSearch): Bonus X
  caps at an extreme **250x**. Fed three ways: +5x from the flashing launch-lane skill shot (see
  Dimension 5), +2x every time all four FIRE lanes are lit (spelling F-I-R-E), and incidental
  jet-bumper accumulation during multiball. Elite play is an explicit "build now, cash later"
  strategy — bank extra balls, grind the multiplier toward 250x while multiball runs, then let the
  ball drain to collect; one strategy thread reports jumping from an ~80M game to 150M+ once a
  player started working the multiplier deliberately, and a maxed multiplier on a >1M switch-bonus
  base can produce a 50-60M bonus alone — a material fraction of a strong game's whole score.
- **Attack from Mars** (sourced): base bonus starts at 5,000,000, +2,500,000 per defeated Martian,
  plus per-switch value; multiplier fed by Upper Lane rollovers plus the +5x skill-shot award (see
  Dimension 5). A documented outlier: a **42x** multiplier producing "almost 4 billion" in bonus
  alone in one ball — exactly the rare-but-earned jackpot shape the owner wants, arising purely
  from the bonus screen, not mode/jackpot scoring.
- **Godzilla (Stern 2021, Elwin)** (sourced via pinballrulesheets.com): Bonus X earned by clearing
  *named objectives* rather than volume — **+1x per city conquered** (4 cities, so +4x max) plus a
  chance at +1x from the Maser Cannon mystery award. End bonus itemizes named components before
  applying BonusX: cities 750K, tail whips 250K, power-ups 200K, jet fighters 350K, loops 150K
  (each per-unit).

*Cross-table pattern* (sourced): Bonus X is (1) **monotonic and non-decaying for the whole ball**
— held until tilt or ball-end, never lost to inactivity; (2) built through many small, legible,
named actions spread across the ball; (3) **visible as a running number** on the backglass/DMD
throughout play; (4) creates risk/reward tension via **tilt, which forfeits the entire bonus
(multiplier included) in one stroke** — the payoff for a risk survived, not just a number reveal.

*CONFLICT WITH RECALL:* the original recall-only draft said Bonus X "typically" builds "+1X per
specific shot or award" and correctly had it resetting to 1X each ball, but understated how far it
can climb (sourced: caps vary 5x on TZ to 250x on MM) and missed that **tilt-forfeiture**, not the
routine ball-end reset, is the risk mechanism designers actually point to. No hard numeric
contradiction — the sourced version above supersedes and fills in the missing shape.

**(b) Paintbot analogue.** HEAT embers remain the closest existing mechanism: a per-team counter
(0-11 cap) that climbs +1 per heat-paying tag and decays -2 embers per 270 ticks, read through a
multiplier ladder `[1,2,4,8]` **sampled before** the deed's own increment (`sim.nim:257-258` decay,
`sim.nim:476-477` cap/increment). Per a recovered researcher's grep, heat already ships a live
client HUD indicator (a "flame chip" — the code's own comment block above `HeatLadder`, `glory.nim`
~975, explicitly compares it against a rejected "overspray" alternative and states "the flame chip
already ships"). Achievement-tree climbing (`treeGun/treeSpray/treeGrenade`, `sim.nim:620-636`;
`treeSquad`, `sim.nim:665-684`) is a second build-up axis: monotonic and permanent — each (tree,
tier) mints exactly once via a `claimed` set (`sim.nim:535` comment: "No MINT cap here: a claim is
one-shot per (tree, tier)"), tier factors `RecutTierClass=[1,1,2,2,4]` (`sim.nim:520-539`,
`glory.nim:373`) compounding 1x1x2x2x4 = 16 across a full climb — matching Bonus X's "hold what you
earn" property. It likely **fails** the "visible running meter" property: each tier claim appears
to surface only as a one-shot toast/log event, not a persistent on-screen gauge — **UNVERIFIED**,
a direct `client/player_hud.js` check could not be completed (worktree removed mid-task; see "What
is NOT verified" below).

**(c) Gap.** No single Paintbot mechanic combines Bonus X's two most load-bearing properties
(never-decaying AND continuously visible) in one place — heat has the visible meter but decays
every 270 ticks; achievement tiers are monotonic/permanent but (unverified) probably surface only
as a one-shot event, not a running gauge. That split is itself the headline finding for this
dimension. Heat is architecturally the right shape otherwise (a climbing, decaying,
visible-in-principle multiplier) but behaves opposite to Bonus X in two ways: (1) it is **applied
instantly, per-deed**, never banked; (2) it decays, where every reference table's Bonus X never
regresses within a ball.

---

## 2. Modes

**(a) Reference — SOURCED 2026-09-09**, covering lighting mechanics, stacking, and timeout/failure
consequences for all three tables researched in depth (Medieval Madness, Attack from Mars,
Godzilla):

**Medieval Madness.** Castle Multiball: lock 3 balls, then 5 ramp shots per jackpot; after 5
jackpots collected the castle lock shot lights Super Jackpot + Extra Ball (hitting the lock again
instead of the ramp scores a Double Super Jackpot). Trolls!: hit center yellow standups to light,
shoot the right eject to start — two troll pop-ups, a hard **30-second timer**, 3 hits each;
clearing lights a repeatable "Troll Madness" escalation. **Multiball Madness is the headline
stacking mechanic**: bank any of 5 sub-objectives (Joust, Catapult, Peasant, Damsel, Troll)
independently during single-ball play, then choose *when* to cash in at Merlin's saucer — 1
objective lit = 2-ball multiball, 2-4 lit = 3-ball, all 5 lit = 4-ball, with jackpot/super-jackpot
values (super jackpot 250K base + 150K per lit mode, up to 1M) scaling directly with how many
you're holding when you cash. This is a genuine hold-vs-cash risk decision: banking more is
strictly more valuable but risks losing the ball, or a mode timing out, before cashing in.
Merlin's Magic (a separate saucer award, not a multiball) is a pure random grab-bag sitting beside
this skill-gated ladder, not inside it. Timeout/failure: sources did not give explicit
partial-credit language for a failed Trolls! attempt (**unconfirmed, not asserted absent**) — the
practical read is an incomplete attempt simply ends without minting Troll Madness, with no
evidence of lost previously-banked Multiball Madness progress (the 5 sub-objectives bank
independently and permanently once completed). Telegraphing is via lit inserts and escalating
voice lines, **not** an explicit callout — the specific "SHOOT THE CASTLE" wording one researcher
initially recalled is **low-confidence and is dropped here**.

**Attack from Mars.** Complete the center 3-bank of drop targets to open an Attack Wave against
the saucer: Wave 1 needs 4 saucer hits (50M each) for a 200M destroy bonus; each successive wave
adds +4 hits/+10M per hit/+100M to the bonus (Wave 5 = 20 hits, 90M/hit, 600M bonus). Separately,
**Martian Multiball** is gated by two researchers at different granularity, both sourced and
treated as complementary rather than contradictory: spelling all 7 letters of M-A-R-T-I-A-N at
standup targets lights the Stroke-of-Luck scoop; shooting the scoop starts a 30-second timed
sub-mode where 4 Martians bounce on the playfield and must be killed via specific target banks
before the timer expires; only then does the 2-ball Martian Multiball itself start, base 20M per
target +10M each time Martian Attack is relit across the game. **Total Annihilation**: hit each of
4 main shots (L/R orbit, L/R ramp) 3 times each; a 4-ball multiball, escalating jackpot capped at
200M/shot, each successive TA in the same game opens 25M higher (2nd TA = 75M/shot). **Stacking
philosophy — the single most load-bearing quote found** (pinball.org rules page): *"features don't
end when something else is started up. If you have an Attack Phase going and you start multiball,
it keeps going. Very good things can be going on at once."* An explicit design law, not an
emergent side effect — stacking Martian Multiball with Total Annihilation is cited as one of the
highest-scoring combos short of the Rule the Universe wizard mode (Dimension 7). Timeout/failure:
the Attack Phase itself is explicitly **not timed** — "will not end until the saucer is destroyed,
not even if you lose your ball," a true carryover across drains; Martian Attack (lighting all 4
targets) **is** time-limited, and missing the window ends that attempt with no stated partial
credit, requiring re-qualification from the ramps/orbits.

**Godzilla (Stern 2021, Elwin).** Tier 1 Kaiju Battle (Ebirah/Titanosaurus/Gigan/Megalon): shoot
either ramp twice, then the scoop, to start; ~60-second timer. Tier 2 Kaiju Battle unlocks only
after completing at least half of a Tier 1 battle in a new city, lights via both ramps, 75-second
timer, and **takes priority over all other scoring features / cannot start while a multiball is
running**. Tesla Strike, Bridge Attack (50 Magna-Grab hits, +25 per repeat activation), Tank
Attack (destroy 10 tanks, +5 per repeat). **Stacking rules — the most structured, explicit tiered
permission model of the three tables researched**: Tier 1 battles CAN stack with Jet Fighter
Attack, Tesla Strike, and any multiball; Tier 2 battles CANNOT start while a multiball runs and
OVERRIDE Tier 1/other features when they do run. Destruction Jackpots compound: each one collected
boosts all subsequent Annihilation Bonus values by +1% — a second, slower-growing exponential
riding on the main one — but an explicit **anti-stack rule** caps it: "if two Destruction Jackpots
stack on top of one another, you don't get extra points or powerups." **Timeout/failure — the most
detailed of the three tables**: Tier 1 gives partial credit *and* progress carries over between
attempts, but a retry's completion-timer bonus is cut to **1/10 of normal value**; draining while a
Tier 2 battle is active **loses progress entirely**, a harsher consequence. Tier 2 offers a
voluntary "Flee" option — bail early for `multiplied value + 200K x seconds remaining`, paying out
less than full completion but more than a drain (this is also directly relevant to Drain Risk,
Dimension 6). City Select forfeiture: switching to a different city before finishing its battle
**permanently forfeits** that city — true total loss, the opposite end of the spectrum from Tier
1's soft carryover. Tank Attack: missing an 8-second jackpot window decays the super-jackpot
multiplier by -1x, live and stacked. *(Model caveat: none of the above hardware is Premium/LE-only
— that caveat applies to Mechagodzilla's magnet/jump ramp and JP's motorized raptor-pen gate, see
Dimensions 5-6, not to any Godzilla mode named here.)*

**(b) Paintbot analogue.** The achievement trees are a "bank of targets -> tier" structure
(`sim.nim:620-636`, `:665-684`; `Tree` enum `glory.nim:1884-1897` — live trees `treeGun/treeSpray/
treeGrenade/treeSquad`; dead trees `treeShield/treeMedKit/treeCarrier/treeDefender` need mechanics
the repo doesn't have): reaching a kill/level threshold "lights" (mints) the next tier via
`claimAchievement` (`sim.nim` ~503-520) -> `mintAchievement` (`glory.nim:2437-2441`), tier factors
`RecutTierClass=[1,1,2,2,4]` (`glory.nim:2528`) folding in as you climb. This is a real "hit N
things to light a reward" mechanic in spirit, but it is **structurally unlike every pinball
reference above**: pinball modes are *stateful and time-boxed* — you enter a mode, a timer runs,
you're "in" it and can fail it. An achievement tier is an **instantaneous, retroactive mint** the
moment a threshold crosses; there is no "mode active" window, no timer, no way to be mid-attempt,
and therefore nothing to fail — the single largest structural gap for this dimension. The
placement ladder (`dFinal8/dFinal4/dFinal2`, `recutMintPlacementMilestones`, `sim.nim:6616`, gated
`gloryMultiplierRecut and winAsMultiplier and brMode`) is the closest thing to an auto-lit "story
mode" that escalates as a round progresses, but requires **zero player action** — pure survival
bookkeeping, identical for every team still alive at that moment. Nothing in Paintbot lets a
player/policy *choose which "mode" to pursue* the way AFM lets you pick which saucer wave to hit or
MM lets you bank Joust before Damsels: the strategy layer (`policies/starters/common/plays.py`)
defines controller plays (`edge_ride, supply_run, scatter, loot, bodyguard, crossfire, jackal`) and
overlay plays (`pact, target_law`) — none reference achievement trees or the placement ladder.
`docs/paintball/RULES.md` does not mention either system at all (it covers only the deprecated
King-of-Hill legacy mode) — there is currently **no player-facing vocabulary** for these systems.
Paintbot's scoring is already "additive-never-exclusive" in one sense, structurally consistent
with AFM's "features don't end when something else starts" law: every deed and achievement tier
folds into the same per-team product (`gloryProduct[team]`) through the single chokepoint
`awardDeed*` (`sim.nim:329`, ~12 distinct call sites). But this is **stacking-by-construction, not
stacking-by-choice** — every pinball reference's stacking mechanic is a live decision under time
pressure (bank Joust now or wait to combine with Damsels? start TA now or hold for Martian
Multiball overlap?); Paintbot has no "hot but uncollected" state a policy can choose to delay a
deed into — a deed mints and resolves in the same tick it triggers.

**(c) Gap.** Three real absences, confirmed by grep (no "modeTimer"/"wizard"/"finale" symbols found
anywhere in `sim.nim`/`glory.nim`/`sim_types.nim`): (1) **no player-chosen mode start or target
selection** — everything today is threshold-triggered by whatever you happen to do, and no play in
`plays.py` biases pursuit toward a specific achievement tree or milestone; (2) **no timer,
therefore no failure state** — achievement progress never expires or times out, so there is no
tension moment of "the clock is running out," and no mode-forfeiture consequence to map against
Godzilla's graduated 1/10-value retry vs. permanent city-forfeiture vs. live -1x decay spectrum
(the nearest thing, self-frag halving, is a flat whole-episode retroactive penalty, not a
per-mode, in-the-moment forfeit); (3) **stacking is already multiplicative by construction** (every
deed folds into one big product) so in one sense we already have AFM's "everything keeps running"
stacking payoff, but without the player-visible "I am now running two modes at once," or MM's
deliberate hold-vs-cash choice, that makes pinball's stacking feel earned rather than incidental.
An anti-stack dedup rule (Godzilla's "don't double-pay simultaneous Destruction Jackpots") is not
directly comparable today — we have no same-tick double-fire case yet — flag for later if any new
lever introduces one.

---

## 3. Multiball / jackpot set-up

**(a) Reference — SOURCED 2026-09-09.** **Attack from Mars**: Martian Attack Multiball and Total
Annihilation as described in Dimension 2 above; additionally, **Super Jackpot** is a *roaming*
award, lit only after collecting 5 ordinary jackpots in one multiball — worth 250M, escalating to
500M/750M/1B on repeat collects, and it physically relocates its lit shot every 5 seconds, skill-
*and*-timing-pressure gated rather than just a bigger number at a fixed shot. **Medieval
Madness — Multiball Madness** as described in Dimension 2 (5 sub-modes, hold-vs-cash, ball count
and jackpots scaling 2-ball/3-ball/4-ball with 1/2-4/5 modes lit). **Godzilla — multiball family**:
Godzilla Multiball requires reducing a building's "integrity" to 0% via ramp/structure shots then a
final building shot; Mechagodzilla Multiball requires building right-spinner hits with an
**escalating cost per activation** ("20 + 10 per prior activation" — the 2nd light costs 30 spins,
the 3rd costs 40, etc.), then disabling a 3-target Neo Barrier, then hitting the spinner again;
Saucer Attack Multiball needs 6 defeated saucers first; Planet X Multiball needs 4 separate
city-level objectives completed. Jackpots inside Godzilla MB are progressive/color-staged; 6
collected lights a Super Jackpot at the building. Mechagodzilla MB requires collecting all 3
lit-shot-plus-target-bank jackpots to *qualify* (not collect) a timed super-jackpot round.
**Twilight Zone — regular multiball** (distinct from the wizard mode, see Dimension 7): locking 3
balls (spelling GUMBALL twice at the lock lane) starts a standard 3-ball multiball whose jackpot
base value climbs +10M per collect, capped after 5 increases.

*Cross-cutting design principles observed across all four tables* (sourced): **a jackpot shot is a
switch, not a stat** — it pays little or nothing until a distinct, separately-tracked action flips
it "lit" (spelling letters, a ramp count, a boss's health bar, a target bank); **escalating cost
defeats farming** (Godzilla's Mechagodzilla spinner requirement rises every re-light — the closest
thing in these tables to a "fire counter" that changes future behavior, not just records a count);
**hold-vs-cash creates the mid-risk band** (MM explicitly rewards banking multiple lit modes before
cashing at the cost of risking the ball before cash-in — the single clearest "wide mid-risk band"
mechanism of the four tables); **mutual exclusion enforces scarcity** (AFM won't let Total
Annihilation and regular multiball run together, so the top-tier mode can't be "just another
stacked multiplier"); **a roaming/escalating super-jackpot is its own reward tier**, gated behind
banking several ordinary jackpots first, worth an order of magnitude more, and actively hard to hit.

**(b) Paintbot analogue.** The STACK co-engagement multiplier (`RecutStackLadder=[1,2,3,5,8,13]`,
`glory.nim:2513,2720-2722`, computed by `recutContextK` ~`sim.nim:2699`) is **gated on an active
pact** — since GV56/v14 it only counts a co-attacker toward the Fibonacci multiplier `if
attackerTeam == killerTeam or sim.pactActive(attackerTeam, killerTeam)` (`sim.nim:2757-2758`).
Without a pact, stack reads as x1 for everyone — exactly AFM's "the saucer scores nothing until
the multiball is lit." `pact.nim` (`play_sdk/reference/pact.nim`, 212 lines) is the policy-facing
mechanism: a negotiated alliance declared via `resolveConfiguredPacts` (config-seeded,
`sim.nim:854`) or `declarePactPartners` (in-match, mutual-only, `sim.nim:915`), read live via
`pactActive` (checked at ~15 sites). Per the S2 scoring doc, pacts DO form live (~1/episode,
1,019/1,068 GV59 episodes) — the "light it" step is reachable, not theoretical.

**CORRECTION 2026-09-09 (owner ruling, GV15) — the previous draft of this study was stale here.**
It previously described `dJointAct` as "NOT pact-gated," calling it a "consolation prize" that
"survives even when no pact is lit." That is now confirmed **wrong**: `recutJointActOnDamage`
(`sim.nim`, proc starting ~line 2762) carries a comment block headed "ALLIANCE GATE (owner ruling
2026-09-08, task f3fe0b4f, GloryVersion 15): JOINT ACT is an ALLIANCE deed, not a co-fire deed" —
a contributing seat now mints `dJointAct` only if it shares an active pact with at least one other
contributing team, enforced at `sim.nim:2840` (`if t != selfTeam and sim.pactActive(selfTeam, t):
pactPartner = true`). **As of GV15, both of BR's co-engagement deeds (STACK and dJointAct) are
pact-gated — there is currently no "always pays something even unlit" consolation path in BR
co-engagement scoring at all.** Every reference table above keeps *some* payout live when a
jackpot isn't lit (a normal-value shot, a base jackpot); ours has none for this deed family. This
also matters for ranked-gap item 4 below.

**Where the pact-as-lighting-mechanism diverges from pinball's lighting rituals** (sourced): a
pinball lit-jackpot is earned by an in-the-moment *skill act on the table itself* and is typically
*time-boxed* once lit — Hurry-Ups decay to a floor, Total Annihilation excludes regular multiball
while active. A pact is a *protocol handshake*, either config-seeded before the match starts or a
mutual declaration via the `pact` play (params `partners` [1-8 seat refs], `protect` bool,
`onBetrayal` enum `disengage`/`returnFire`) — and it has **no engine-enforced expiry**. The
reference play (`play_sdk/reference/pact.nim`) exposes an optional `holdFire.arms` union
(`aliveTeams`/`tick`/`zonePhase`, default `aliveTeams: 2`) letting the *declaring policy* choose
when its own pact ends, but nothing in `pactActive`'s engine-side check forces an expiry — a
policy can simply never schedule one, or schedule one so late (`aliveTeams: 2`, "until the final
two") that it behaves as permanent for the whole episode. **The "lighting" step exists, real and
verified, but its rarity profile is inverted from pinball's: pinball jackpots are hard to light and
then briefly live; ours are comparatively easy to light via declaration and then can persist
open-ended. The gap is the missing expiry, not the absence of a gate.**

**(c) Gap.** The mechanism EXISTS but only for one axis (co-engagement — now confirmed to cover
both STACK and dJointAct, per the correction above). Nothing else in our scoring uses the
"must-light-before-it-pays" pattern — heat, achievements, and the win multiplier all pay
unconditionally whenever their trigger condition is met. **No escalating cost per re-activation**
exists anywhere (Godzilla's Mechagodzilla precedent: deed classes are fixed constants regardless of
how many times a deed type has fired this episode). **No roaming/escalating super-jackpot ladder**
exists — `RecutStackLadder`'s Fibonacci scaling is keyed to *how many allies co-hit this one victim
right now*, not to *how many prior jackpots this team has already banked this episode*, a
fundamentally different axis from AFM's Super Jackpot. **No hold-vs-cash mechanism** — nothing has
a "hot, waiting to be collected" state a policy can choose to delay; a deed mints and resolves in
the same tick. **No mutual-exclusion rule** between concurrent top-tier systems — pact/STACK, heat,
zone-phase deeds, and achievement tiers can all fire simultaneously with nothing disarming one
because another is active; given this program's stated goal is "many multipliers stacking," this
may be an intentional divergence rather than a gap (flagged low severity), though pinball uses
exclusivity specifically to protect rarity, a goal we do share. **Fire-counter precedent already
exists and should be reused, not reinvented**: `RecutMintCapTable` (`glory.nim:2589-2700`) already
implements the exact "switch + fire counter" idiom this program mandates for any new lever (e.g.
`dJointAct` capped at 6 mints/duo/episode, `dDuoDown` at 4, `dTagBack`/`dShieldSoak` at 3) — a flat
per-episode budget, not an *escalating* one like Godzilla's, but the closest existing strength on
this axis.

---

## 4. End-of-ball BONUS TALLY

**(a) Reference.** Every reference table ends each ball with a paced count-up: base bonus points
tick up on the display, then multiply by the accumulated Bonus X, with audio/light escalation timed
to the reveal — widely cited by designers as the single biggest "did I do well?" payoff moment in
the game. Mechanically, EM-era tables counted the bonus on a physical score reel at a **metered
pulse rate** (sourced, funwithpinball.com): single bonus steps at 5000 pts/Score-Motor-cycle,
double bonus at 4000 pts/cycle but with two reel-advances per bonus-unit-step — the *count itself*,
not just the final total, was the show. Modern DMD/LCD tables replace the reel with an animated
roll-up: base total appears, multiplies by Bonus X, and the digits visibly climb rather than
snapping instantly. On some tables it is the single biggest score swing available: AFM's 42x
example turned an ordinary ball into an "almost 4 billion" jackpot purely at the bonus screen; MM's
50-60M bonus can rival or exceed the rest of a strong ball's score. Tilting forfeits the whole
bonus, so the tally also pays off a risk survived for the entire ball, not merely a math step.

**(b) Paintbot analogue — CORRECTED 2026-09-09, this dimension's headline claim changes.** The
previous draft called this **"Confirmed ABSENT,"** citing `client/global_plus_pov.html:1341-1343`
— a match-stats scoreboard comment reading verbatim *"no per-match glory data yet (that lane lands
separately), so this shows from the roster — never a glory/XP/rank vocabulary."* That citation is
real, but a sourced researcher subsequently found a **separate, already-shipped mechanism
elsewhere in the same file that the original draft did not look at**: the **MATCH GLORY endcard
reveal**. `renderEndcardBR` (~`global_plus_pov.html:5272`) sums every team's `over.teams[team].glory`
into `mgSum` and writes it through `rollGloryNumber` (`global_plus_pov.html:3745`) instead of
snap-printing — the function's own doc comment: "MATCH GLORY rolls up instead of snap-printing"
(`global_plus_pov.html:3721-3722`). The reveal is paced in beats: paint-splat volley (~150ms+),
headline paint-wipe (~500ms), then the MATCH GLORY number rolls up over `EC_ROLL_MS=520ms`
starting at `EC_ROLL_DELAY=750ms` (`global_plus_pov.html:3736`) — a deliberately sequenced
multi-beat reveal, structurally the same idea as a pinball bonus count-up. It also carries a
**"show-review tier" narrative line** (`matchGloryTier`, ~5217; `matchGloryMargin`, ~5163;
`matchGloryLeadChanges`, ~5180) reading margin-of-victory and lead-change-count off the match's
`lead` series (`mgIngestLead`, ~2144) to print lines like `'RAZOR-CLOSE, START TO FINISH'` /
`'ONE-SIDED FROM THE START'` (`MG_TIERS` table, ~5203-5217) — a genuinely pinball-flavored idea
**already shipped**. CSS scaffolding: `#endcard .mg-splash` (1431), `.mg-total` (1437),
`.mg-total-num` (1447).

**Reconciling the conflict**: both citations are correct and both are real code in the same file —
the roster-based match-stats *scoreboard* (`:1341-1343`, no glory data) and the separate `#endcard`
MATCH GLORY *reveal* (`~3721-5272`, glory data present, paced, already reveals a number) are two
different UI regions the original draft did not distinguish. **The gap is narrower than originally
scored**: MATCH GLORY sums *all* teams into one combined spectacle number for the show-review
line — it is not a per-player/per-team itemized "base x multiplier, line by line" breakdown the
way a pinball bonus screen is. The per-player endcard rows (`.ec-row`/`.ec-frow`, `~1472/1584`)
show raw stats (kills/captures/tags, e.g. the `.n.tk` friendly-fire count at `1593`) but are **not**
run through any roll-up/count-up treatment, and nowhere on the endcard is the actual multiplier
chain that produced a score (heat rung reached, stack tier hit, achievement tiers claimed,
friendly-fire halvings taken) decomposed or shown. The sim already tracks this server-side —
`sim.deedGloryMass` (accumulated per-deed, referenced `sim.nim:547`) and `sim.achievementFeed`
(`sim.nim:550`) both exist — the gap is that none of it reaches the client as line items. Friendly-
fire halving (`recutFfHalvings`, `glory.nim:2803`; `recutScore`, `glory.nim:2828`, dividing
`product div (int64(1) shl halvings)` at `glory.nim:2837`) is Paintbot's closest thing to a
standing risk penalty, but it applies continuously through the episode rather than as a single
dramatic all-or-nothing forfeiture gated at a reveal moment the way tilt forfeits a whole ball's
bonus. Player-facing vocabulary check confirms public terms are "tag" (RULES.md:39), "spray can"
(RULES.md:21), "spray"/`sprayDamage` (RULES.md:34) — consistent with this program's tagging-
vocabulary law.

**Season-level reveal — DOWNGRADED to unverified.** The previous draft stated as settled fact that
"the season leaderboard shows only a rolling mean — no per-round breakdown is ever surfaced
anywhere client-side." A sourced researcher grepped `src/ctf/` for "rolling mean," "geometric
mean," "season_score," and "SeasonLeaderboard" and got **zero hits** — the aggregation code is not
in this checkout at all, so this claim is **UNVERIFIED here**, not confirmed (see "What is NOT
verified" below). If confirmed elsewhere, a rolling mean would still be structurally the opposite
of a pinball bonus reveal (opaque continuous average vs. legible discrete theatrical tally), but
that follow-up search has not happened.

**(c) Gap.** Presentation gap, narrower than the original "Confirmed ABSENT" framing: a combined,
paced, already-shipped MATCH GLORY total exists (`renderEndcardBR`/`rollGloryNumber`); what's
missing is (1) a **per-player** itemized breakdown (base x multiplier, line by line, the way a
pinball bonus screen shows), and (2) any analogue to tilt's **all-or-nothing forfeiture at the
reveal moment** (today's only standing penalty, friendly-fire halving, is continuous, not a
dramatic gate). This remains a strong candidate for the owner's "the standings must FEEL glorious"
requirement, and remains **cosmetic** — it changes nothing about the score distribution, only
whether players can see and feel it — but the specific build is "extend/itemize an existing
mechanism," not "build one from nothing." See the note under ranked-gap item 3 below.

---

## 5. Skill shot

**(a) Reference — SOURCED 2026-09-09**, all five reference tables:

- **Medieval Madness** (high confidence, 2 sources): one top-lane rollover flashes pre-plunge;
  flipper buttons shift which lane is lit. Award 50,000 +10,000 per successive skill shot that
  ball, PLUS **+5x to the end-of-ball bonus multiplier** (see Dimension 1). Holding the left
  flipper at launch arms a Super Skill Shot: the ball rides the right orbit and all major shots
  light; collecting any awards 100,000 and starts a Castle Hurry-Up — but counts only as one
  generic shot, no credit toward a specific mode requirement.
- **Attack from Mars** (high confidence, 2 sources): basic skill shot above the pops to a flashing
  lane = 10,000,000 +10,000,000 per successive, plus **+5x bonus multiplier**. Left-flipper hold
  arms a Super Skill Shot: around the loop to any lit ramp/orbit/gate for 50,000,000 AND FULL
  COMPLETION CREDIT toward that feature — the real trade-off is forfeiting the separate 100M
  counting-down hurry-up the basic shot can feed instead.
- **Godzilla (Stern 2021)**: tiered by plunge strength, each paying base **x number of unique
  skill shots made** (an escalating collection bonus) plus ball-save seconds: 250K x uniques +3s /
  500K x uniques +5s / 750K x uniques +5s / secret left-spinner 5M +1M per unique / super-secret
  combo (spinner then reflex scoop) 10M + 2 Power-Ups + lights an Ally.
- **Jurassic Park Pro (2019)**: full plunge feeds a 4-shot combo off 2M base, multiplying
  2x/4x/6x per consecutive shot (max ~12M), each adding 3 seconds of ball save; the MXV variant is
  8x. *Excluded, per source: the 1993 Data East Jurassic Park "press FIRE" skill shot is a
  different, wrong table and does not appear here.*
- **Twilight Zone** (high confidence, 3x corroborated): soft plunge over three colour-coded
  rollover lanes — Red 2M +1 jet / Orange 5M +2 jets / Yellow 10M +all 3 jets (hardest, most
  precise); overshoot into the scoop = 1M+100K. Telegraphed physically (the lit lane the ball
  trips), no light show. Bowen Kerins notes the wrinkle that making it catapults the ball into the
  bumpers — many players just full-plunge anyway. Super Skill Shot re-arms later via the left ramp
  (returns ball to plunger): Red lights Battle the Power, Orange lights outlanes, Yellow a
  temporary Extra Ball, flat 10M regardless (medium confidence).

*CONFLICT WITH RECALL*: the previous draft described Twilight Zone's plunge skill shot as "~tens
of thousands of points, illustrative only." The sourced figure is **millions** (2M/5M/10M base,
plus jet-bumper awards) — a real, order-of-magnitude conflict between recall and sourced material.
The sourced version is kept; recall's number is dropped.

*Model caveat carried across*: Mechagodzilla's magnet/jump ramp and JP's motorized raptor-pen gate
(mentioned for context in Dimension 6) are Premium/LE-only hardware, not present on the base/Pro
models this research otherwise describes — noted so no lever design assumes hardware we can't map.

**(b) Paintbot analogue.** **Confirmed ABSENT** — grepped for any "skill shot"/opening-precision
concept in `sim.nim`/`glory.nim`/`sim_types.nim`; nothing matches. The nearest scoring-wise is
LONGSHOT (`dLongshotKill`, class 3, `glory.nim:2448` `RecutClassTable`) — but Longshot is not an
opening mechanic: it can fire at any point in the episode, and per the S2 scoring doc the
triggering situation (a rival at >=2/3 live weapon range) occurs in only ~0.89% of firing moments
— rare by geometry, not by design as a "moment," and not guaranteed-once-per-episode the way a
plunge is. `dAceTag` (class 4, "a runaway cog is a `dAceTag` bounty," comment at `sim.nim:844`)
rewards punishing a snowballing leader — a mid/late-episode mechanic, not an opener.

**(c) Gap.** We have no analogue to "a modest, legible, guaranteed opportunity in the first moments
of every episode." The manager cross-table synthesis (below) makes the more important point
concrete: reference skill shots overwhelmingly pay into a **multiplier or an escalating
unique-count**, not into raw score (MM/AFM both feed the end-of-ball Bonus X; Godzilla pays x
uniques) — any Paintbot analogue should feed the episode multiplier, not the point total, to be a
true match rather than a reskin. This matters for the owner's risk-shape goal specifically at the
LOW-risk end: today low-risk play earns "little/no reward" only by omission, rather than by a
deliberately modest but real payoff that establishes the risk ladder's floor.

---

## 6. Drain risk

**(a) Reference — SOURCED 2026-09-09**, all five reference tables:

- **Medieval Madness**: the Castle (drawbridge->gate) is a deliberately drain-prone dead-center
  shot, the table's classic gamble — slightly safer than AFM's saucer as the geometry deflects
  less to the outlanes. Castle Multiball = 3 lock shots (6 for repeats), ~750K jackpots -> 1.5M
  supers. The real risk layer is **Multiball Madness stacking** (Dimension 2/3): each of six
  sub-modes can be left LIT BUT UNCOLLECTED and stacked; 5 stacked = 4-ball multiball, 875K
  jackpots/1M supers. Advanced play deliberately delays collection across risky shots to inflate
  the eventual payout — a press-your-luck structure. Telegraphed by lit inserts and escalating
  voice lines, not an explicit callout (the specific "SHOOT THE CASTLE" wording is **low confidence
  and is dropped**, per Dimension 2).
- **Attack from Mars**: the saucer/forcefield hurry-up is the sharpest legibility example — value
  starts at 100,000,000 and **visibly counts down** on the display to a 25M floor, with a strobe
  physically flashing at the saucer: an explicit real-time gambling clock. Hurry-ups stack
  (2=300M, 3=500M, 4=1B and auto-starts Total Annihilation) and stacked ones do **not** count down
  faster, easing risk once stacked. Community consensus (high confidence): the center saucer has a
  fast, unpredictable return and players drain off most saucer hits. Total Annihilation escalates
  jackpots from 50M by +5M per collect.
- **Godzilla "FIGHT OR FLEE" (King Ghidorah)** is the single best legibility exemplar found: shots
  colour-coded green->yellow->red for 1x/2x/4x as value climbs (~16M jackpot base, shots 400K
  +150K each); after each hit the flippers become a choice — left = FIGHT (add ~35s, reset
  colours, keep climbing, but a drain forfeits EVERYTHING) vs right = FLEE (bank the multiplied
  value + 200K/second remaining, safely). A live timer, escalating colour-coded stakes, and an
  explicit bank-or-gamble button. *(This is the same Tier-2 "Flee" option described from the
  lighting/stacking side in Dimension 2.)*
- **Jurassic Park Pro**: Feed T-Rex hurry-up — truck x3 arms a 500K hurry-up at the left ramp, 20s
  visible countdown, orange CHAOS shots raise value (~6.75M cap) and extend the timer, and
  **crucially no ball-saver is active until the ramp converts it to multiball** — a true
  shoot-for-more-or-drain-for-zero window. Inside a Paddock the pursuing dinosaur visibly speeds up
  toward the next unclaimed shot — urgency without a timer. *Model caveat: Mechagodzilla's
  magnet/jump ramp and JP's motorized raptor-pen gate are Premium/LE only, not base hardware.*
- **Twilight Zone POWERBALL**: a ~20% lighter ceramic ball — faster, more erratic, and immune to
  the flipper magnets. Getting it into play lights Powerball Mania and flashes the Greed targets:
  the elevated-risk mode is announced by a **change in the ball itself**. Powerball Mania targets
  250K, defeating the Power = 50M jackpot; during regular multiball the Powerball can score a
  double jackpot at the Player Piano — a ~1/3 probability high-value alternative to banking the
  safer payout. **"BATTLE THE POWER"** (right ramp -> magnetic Powerfield mini-playfield) is the
  clearest pre-commitment gamble found anywhere: a 10-second audible countdown, walls scoring
  escalating points while it runs; hit the exit hole in time and the accumulated total DOUBLES plus
  a random door panel; miss or time out and you keep only the raw points, no multiplier — the
  downside is losing the multiplier, not the points. *(Note: an unsourced "Rod Serling
  intro-quote" flavour detail sometimes attached to TZ is single-source flavour and is not
  included here — it never appeared in the sourced material and is not asserted.)*

**(b) Paintbot analogue.** Self-frag halving (a division penalty for friendly fire, per the S2
scoring doc's `glory.nim` cap-table region) punishes an ACCIDENT, not a chosen risk. `dRevengeKill`
(PAYBACK, class 2, `glory.nim:2448`) is closer: a grenade thrown before you're tagged out still
detonates, and killing your killer within `RevengeTicks` (`sim.nim:661,2940`, mint at
`sim.nim:3024`) mints it — per the S2 doc this fires ~1% of the time. It IS a real hail-mary in
shape — but it is **reactive**, triggered by your own death, never a choice a healthy player makes
to trade safety for upside.

**(c) Gap.** Two distinct gaps, not one: (1) **no proactive risk mechanic** — nothing today lets a
healthy player deliberately walk toward a bigger, riskier payoff; (2) **no legibility channel** —
`play_view` (the policy's perception surface) does not appear to expose any "you are entering a
high-stakes situation" signal today (still **NOT VERIFIED exhaustively** — see below). This is
arguably the single biggest philosophical gap against the owner's stated risk-shape (low=nothing /
mid=WIDE band / high=hail-mary-or-nothing): we have the "nothing" end (self-frag) and a sliver of
the "hail-mary" end (revenge kill), but no built, legible MID band at all — exactly where the owner
wants most players to live. The manager cross-table synthesis (below) names three distinct sourced
risk *grammars* worth choosing from, and identifies MM's deferred-collection press-your-luck as the
specific mechanism that produces a *wide* mid-risk band rather than a binary — directly relevant to
closing this gap.

---

## 7. Wizard mode

**(a) Reference — SOURCED 2026-09-09, all four core reference tables**, materially richer and in
places **corrected** versus the previous recall-only draft:

- **Attack from Mars — Rule the Universe**: qualifies only after completing a **union of six
  independent objectives in the same game**: (1) collect >=1 Super Jackpot, (2) start Total
  Annihilation >=1 time, (3) start Martian Attack Multiball >=1 time, (4) "conquer Mars" by
  completing all Attack Waves, (5) start Super Jets, (6) complete >=1 five-way combo. Only once all
  six are true does the Stroke-of-Luck hole light Rule the Universe: a 5-ball multiball with an
  explicit win condition — score 5 billion points before it ends, not just "score a lot." It is a
  checklist across nearly every major system on the table, not a score threshold.
- **Medieval Madness — Battle for the Kingdom**: qualification requires completing each of the 5
  madness modes **3 times each** (not once) plus destroying all 6 castles: Master of Trolls (10
  trolls destroyed), Defender of Damsels (3 damsel saves), Patron of the Peasants (3 peasant
  revolts), Catapult Ace (3 catapult slams), Joust Champion (3 joust victories), Castle Crusher
  (all 6 castles). All six lit simultaneously arms it at the Main Entrance (single-ball play
  only). Two phases: Phase 1 is a 4-ball multiball with a ~15s ball-saver, 6 named shots for 2.5M
  Battle Jackpots each; Phase 2 is a gate-shooting hurry-up (6 hits @5M, trolls actively harassing
  you, survivable via banked Troll Bombs) followed by one final gate shot for a 50M capstone award.
  After completion **all six requirements reset** — a strict one-shot-per-game capstone, not
  repeatable.
- **Godzilla — a tiered wizard-mode ladder** (no prior recall coverage; pure addition): "King of
  the Monsters" requires completing EITHER of two mini-wizard modes (Monster Zero or Terror of
  Mechagodzilla), reaching Planet X Multiball (started, not necessarily won), AND holding a
  **persistent cross-episode meta stat** — Godzilla Power-Up level #8 or #11. Two-part structure: a
  60s(+5s/city) simultaneous defeat of all 4 tier-1 monsters, then a 4-ball multiball boss fight
  against King Ghidorah. Above that sits "Monster Island Madness," an **ultra-wizard mode**
  requiring winning the Planet X Victory Challenge (or collecting all 10 secret combos) PLUS having
  already beaten King Ghidorah — gated on having already cleared the first wizard mode. This is
  the only reference table with a multi-tier ladder (mini-wizard -> wizard -> ultra-wizard), and
  the only one gating a capstone on a persistent meta-progression stat rather than purely
  this-game achievements.
- **Twilight Zone — Lost in the Zone (LITZ)** (no prior recall coverage; pure addition): the purest
  union-gate of the four — collect all 14 door panels (regardless of order; via skill shot at the
  Player Piano or randomly via the Slot Machine) and the 15th "Door Handle" flashes; either of two
  shots starts LITZ. Mechanically distinct from everything else on the table: the game's only
  6-ball multiball (every other multiball is 3-ball), a hard 45-second timer not ended early by
  drains (balls are put back into play until time runs out, then all flippers cut and every ball
  drains at once), and **nearly every other system runs simultaneously and stacked** (Clock
  Millions, Town Square Madness, Powerball Mania, Greed, Super Slot, doubled Hitchhiker value all
  active at once) — **the single closest real-world analogue found to "many multipliers stacking to
  a huge, unpredictable total,"** which is exactly this program's own diagnosis. LITZ computes its
  own separate scoring ledger ("Lost In The Zone Total"), tallied independently of normal per-shot
  scoring and end-of-ball bonus, reported as one lump sum, reset afterward, and gets its own
  dedicated high-score table entry separate from the game's main list. Commentary confirms this
  requires "sustained, skillful play over an extended session" — not a lucky accident.

*CONFLICTS WITH RECALL, resolved in favour of sourced material*: (1) the previous draft said "MM's
'Battle for the Kingdom' requires the castle destroyed, trolls conquered, joust won, AND the damsel
rescued" — four items, each apparently once. Sourced research shows it is **six** requirements
(five modes at **3x each**, plus **all 6 castles**), a materially higher bar than recall stated —
recall's simpler framing is dropped. (2) The previous draft said "Attack from Mars's 'Total
Annihilation' requires all 8 cities destroyed" — this **conflates two distinct AFM systems**: Total
Annihilation (a repeatable mid-tier mode, lit via 4 shots x3 hits each, see Dimension 2/3, that
explicitly locks out regular multiball while it runs) is not the wizard mode at all; the true
terminal wizard mode is **Rule the Universe**, gated on the six-item union above (of which "start
Total Annihilation >=1 time" is only one item), not "8 cities." Recall's "8 cities" figure does not
match either sourced researcher and is dropped. (3) A smaller, **unresolved** cross-researcher
numeric disagreement: one researcher describes AFM's wave-clearing objective as "5 waves = 5
cities/countries saved -> Attack & Conquer Mars," another names Rule the Universe's precondition
#4 as "conquer Mars by completing all 6 Attack Waves." Both are sourced; neither could be
independently reconciled here — flagged rather than guessed at.

**(b) Paintbot analogue.** No terminal/capstone state exists. **Confirmed by a cleaner, targeted
grep than the original**: searching `sim.nim`, `glory.nim`, and `docs/paintball/RULES.md` for
`jackpot|multiball|wizard` (case-insensitive) returned **zero matches** across all three files —
consistent with, and sharper than, the original study's own `wizard|finale|skillshot|modeTimer`
grep. The placement ladder (`dFinal8/dFinal4/dFinal2`, `recutMintPlacementMilestones`,
`sim.nim:6655-6816`, driven by `RecutFinalThresholds=[(8,dFinal8),(4,dFinal4),(2,dFinal2)]`,
`glory.nim:2701-2704`) plus the deterministic solo-win x8 multiplier are the closest things to a
"final stage," but **the gate is survival, not achievement-union**: every reference wizard mode
requires the player to have *deliberately completed a spread of the game's other systems*
(AFM's six-way checklist, MM's 3x-each-plus-castles, Godzilla's mini-wizard-plus-meta-stat, TZ's
all-14-panels); our placement ladder requires only that a team's players still be alive when the
elimination count crosses a threshold — a function of how the match played out around you, not of
what you chose to go light. There is no code path anywhere in the grepped surface that requires
"have you started pact + stack + an achievement tier + survived a zone-closing window" as a joint
precondition for anything; the win multiplier applies unconditionally to any winner regardless of
what else they stacked. Our economy is also fully episode-scoped (the product resets each
episode) — there is no analogue to Godzilla's persistent cross-episode Power-Up level gating a
capstone. **Reusable primitive worth keeping**: the `recutFinalFired` one-shot-per-threshold latch
(`sim.nim:6684,6687`, reset `sim.nim:1024-1025`) is architecturally the same idea as MM's "BfK
resets all six requirements after firing" — a hard, auditable, fires-once guarantee. Any new
wizard-mode-shaped gate this program designs later should copy this latch pattern, and
`RecutMintCapTable`'s switch+fire-counter idiom (Dimension 3), rather than inventing new ones.

**(c) Gap.** Everything that currently makes a big round big is arithmetic coincidence — several
independently-triggered multipliers happening to land in the same episode — never a deliberately
gated "you did everything, here is the capstone" state, now confirmed by a cleaner grep than
before. This is precisely the owner's diagnosis ("the jackpot is not rare: it's the recipe plus a
stackable carrier or two hitting caps") restated in pinball vocabulary — and TZ's Lost in the Zone
is the clearest real-world proof that a deliberately-gated "everything stacks at once" terminal
round is exactly the shape that produces a legible, huge, rare number. A tiered ladder
(mini-wizard -> wizard -> ultra-wizard, Godzilla-style) and a persistent cross-episode meta-stat
gate (Godzilla's Power-Up level) are both real reference patterns but likely out of scope for a
single-episode scoring recipe — more of a season/meta feature — and are not scored higher here for
that reason.

---

## 8. Score distribution shape

**(a) Reference.** Designers of multiplicative-scoring tables (the Ritchie/Lawlor/Eddy/Elwin
lineage this study's tables all come from) have long argued in interviews that multiplying
independent factors, rather than adding them, is what makes a great player's score look nothing
like an average player's — small differences in each factor compound. Rigorous PUBLISHED
percentile data for specific tables is scarce and mostly informal (tournament score sheets,
IFPA/Match Play Events records, Pinside "what's a good score" threads) rather than a clean
statistical study. **No sourced researcher was dispatched against this dimension this round** —
none of the recovered research (02a/02b/02c) covers score-distribution percentiles; this remains
recall/folklore, exactly as the original draft flagged. Treat "top scores are 100-1000x typical
scores on a good table" as directionally true folklore, not sourced fact.

**(b) Paintbot analogue.** Unchanged from the original draft. We already have the measurement
machinery for this at the SEASON level: `tools/ladder/standing_replay.py`,
`standing_sweep_charts.py`, `standing.py`, and `docs/designs/STANDING_SWEEP.md` (the per-leg log2
sweep cited in the program brief was produced by these exact tools). What's absent is the
equivalent machinery at the EPISODE level — a percentile report (median vs top-1%/top-0.1%) is
exactly what Step 3 (TARGET DISTRIBUTION) is chartered to produce, so this is correctly out of
scope here, not a gap in this step. The product cap itself (`RecutProductCapArmed = 1 shl 24`,
`glory.nim:2540`, history at `glory.nim:330,398`) is a historical constant ("2^26 -> 2^24, ruled")
with no cited cap-hit-share target in its own comments — retuned by roughly halving, not by a
measured target rate.

**(c) Gap.** Not a scoring-mechanism gap so much as a MEASUREMENT gap: we have no monitored,
designed cap-hit-share target (the S2 doc's own empirical finding — "hit 7x by 5 policies in one
r4257-4272 window" — was discovered after the fact, not tracked as a live dial). This is a cheap,
low-risk fix that directly serves the owner's "cap-hit-share < 1%" draft target in Step 3.

---

## RANKED GAP LIST (best-first: impact on stated feel × cost × wire-change need)

*Order, impact/cost/wire scores, and text are UNCHANGED from the original worker draft — that
ranking is the worker's judgement and the S2 lead's to revise, not this merge's. Notes below each
item name where the newly-recovered sourced research bears on an item's rationale; nothing here
edits the scores themselves.*

1. **Skill shot** — a modest, known, opening-episode precision reward. *Impact: med-high (fills the
   entirely-missing LOW end of the risk ladder with something designed, not absent).* *Cost: cheap
   (a new deed on an early-episode range/precision condition; does not touch existing math).* *Wire:
   likely no, unless the "this is your skill-shot window" state needs to be perceivable — flag for
   Step 4 design.* Distribution-changing (adds a new, small, floor-raising mint).
   > Sourced-research note: MM/AFM's skill shots pay via a **+5x end-of-ball bonus multiplier**,
   > and Godzilla's via an **escalating unique-shot count** — neither pays much in raw score. Any
   > design against this item should feed the episode multiplier, not the point total, to match
   > the reference pattern (see Dimension 5 and the cross-table synthesis below).

2. **Cap-hit-share as a designed, monitored target** — turn `RecutProductCapArmed`'s hit rate into
   a tracked dial instead of an after-the-fact discovery. *Impact: med (directly serves the
   "rare-but-earned, not lucky" goal and feeds Step 3's <1% target).* *Cost: cheap (a counter + a
   report, no mechanism change).* *Wire: no.* Measurement-only, not distribution-changing by itself
   — but it is the switch+fire-counter Step 4 will need regardless of what else ships.

3. **End-of-ball bonus tally / endcard reveal** — plumb the already-computed per-round score to the
   client and pace its reveal. *Impact: high on "the standings must FEEL glorious" (the owner's own
   words) — this is the single most direct lever on player-facing FEEL in the whole study.* *Cost:
   cheap-medium (client/broadcast work; the code already anticipates this as a deferred, separate
   lane — see `global_plus_pov.html:1341-1343`).* *Wire: yes (no per-match glory data reaches the
   client today).* **Cosmetic — changes nothing about the score distribution**, only whether players
   can see and feel it. Say this plainly at the gate: high leverage, zero effect on the numbers
   underneath.
   > Sourced-research note (Dimension 4): the "no per-match glory data reaches the client" premise
   > is **narrower than stated** — a combined, paced MATCH GLORY roll-up already ships
   > (`renderEndcardBR`/`rollGloryNumber`, `global_plus_pov.html` ~3721-5272). What's actually
   > missing is **per-player itemization** of the multiplier chain (heat/stack/achievement/FF
   > halvings as line items) and a tilt-like all-or-nothing forfeiture moment — a smaller build
   > than "from nothing." Flag for the S2 lead to re-scope this item's description at the next
   > revision; the cost/impact/wire scores above are left as the worker set them.

4. **Generalize the "light it before it pays" gate beyond stack** — extend the pact-gates-stack
   pattern (already live and working) to a second axis, e.g. a genuine super-jackpot deed reachable
   only when multiple systems are simultaneously primed. *Impact: high (this is the direct fix for
   "the jackpot is not rare — it's the recipe").* *Cost: medium (the pattern and the pact
   infrastructure already exist; this is "reuse the mechanism," not "invent one").* *Wire: likely
   yes (a lit/unlit jackpot state needs to be perceivable to be meaningful as a "set it up" choice).*
   Distribution-changing — this is a core lever, not decoration.
   > Sourced-research note (Dimension 3): `dJointAct` is now confirmed **pact-gated** too (GV15
   > owner ruling) — the gate already covers both of BR's co-engagement deeds, not just stack, so
   > "generalizing beyond stack" is partly already true. The sharper finding: pinball's lighting
   > acts are always **time-boxed once lit** (hurry-ups decay); a Paintbot pact has **no
   > engine-enforced expiry** (`pact.nim`'s `holdFire` is optional and policy-chosen). The real gap
   > this item should target is the missing decay/expiry, not the absence of a gate. Flag for S2
   > lead re-review; scores left unchanged here.

5. **Bonus-X as a visible, banked meter** — change heat (or a new parallel meter) from
   instant-apply-per-deed to a running total the player can see build and choose to protect/extend.
   *Impact: medium (sharpens the "I am building toward something" feeling pinball relies on).*
   *Cost: medium (touches core fold timing in `glory.nim`, higher regression risk than the above
   since it changes WHEN value is realized, not just what triggers it).* *Wire: yes (needs the
   running total exposed).* Distribution-changing if the banking mechanic changes when/whether the
   multiplier is realized (e.g. lost on death vs cashed at episode end) — needs careful Step 3/5
   design, not a free lunch.

6. **Proactive drain-risk mechanic + risk-legibility wire fields** — a mid/high-risk choice a
   healthy player can consciously make, with a perceivable "you are gambling now" signal. *Impact:
   high (this is the owner's stated risk-shape gap, arguably the biggest philosophical miss — we
   have "nothing" and a sliver of "hail-mary" but no built, legible MID band).* *Cost: expensive
   (new mechanic design + new perception surface; `play_view` exposure is NOT VERIFIED, see below).*
   *Wire: yes.* Distribution-changing, foundational to the whole risk-shape goal — likely a Step 4/5
   centerpiece, not a quick win.
   > Sourced-research note (Dimension 6, cross-table synthesis): three distinct sourced risk
   > grammars are now available to choose from — countdown-to-a-floor, explicit bank-or-push, and
   > keep-points-lose-the-multiplier — with MM's deferred-collection press-your-luck identified as
   > the specific mechanism that produces a *wide* mid-risk band rather than a binary. Useful input
   > for whoever designs this item; does not change its score here.

7. **Modes with player-chosen start, a timer, and a real failure state** — sharpen the achievement
   trees / placement ladder into genuine pinball-style modes. *Impact: med-high (adds tension and
   agency currently absent — everything today is threshold-triggered, never chosen).* *Cost:
   medium-expensive (needs new sim state for timers and explicit start/fail transitions).* *Wire:
   yes (mode-lit/timer state must be perceivable to be "chosen").* Distribution-changing.

8. **Wizard-mode-style terminal conjunction gate** — a capstone state that only unlocks when
   several systems are simultaneously primed (pact + heat + achievement tier + final-2), paying
   beyond what any one system pays alone. *Impact: med-high conceptually, but highest uncertainty
   of anything on this list — the owner's target distribution (Step 3) isn't set yet, so we don't
   yet know how much headroom a wizard-mode tier should occupy.* *Cost: expensive (most
   architecturally novel item here — a genuinely new deed/state machine, not a reuse of an existing
   pattern).* *Wire: yes.* Distribution-changing; sequence this AFTER Step 3 sets the target shape,
   not before.
   > Sourced-research note (Dimension 7): confirmed absent by a cleaner grep
   > (`jackpot|multiball|wizard`, zero hits across `sim.nim`/`glory.nim`/`docs/paintball/RULES.md`).
   > Also: `recutFinalFired` (the placement ladder's one-shot latch) is architecturally reusable for
   > whatever fires this gate, and TZ's Lost in the Zone is the closest real-world proof that a
   > deliberately-gated "everything stacks at once" round produces exactly the legible, huge, rare
   > number this program wants — useful precedent, not a change to this item's cost/impact here.

### Explicitly NOT recommended to close in this program (paradigm mismatch or already-adequate)
- **Multiball's literal "N balls in play at once"** has no meaningful analogue and shouldn't be
  force-fit — our unit of play is tags/episodes, not physical balls; the STACK/pact mechanism
  already captures multiball's *scoring* shape (a gated, rare, group payoff) without needing a
  literal multi-object mechanic.
- **Per-table unique art/lighting callouts** (flashers, DMD animations) are not gaps in scoring
  design — they're production polish downstream of whatever the endcard/tally work (item 3) decides
  to build; do not scope them into this program.

---

## Manager cross-table synthesis (input to S3/S4, not a decision)

*Carried across verbatim in substance from `02a-raw-research-mm-afm.md`'s closing synthesis:*

1. Skill shots overwhelmingly pay into a MULTIPLIER or an ESCALATING UNIQUE-COUNT, not into raw
   score. MM/AFM both give +5x to the END-OF-BALL BONUS; Godzilla pays x uniques. Our analogue must
   feed the episode multiplier, not the point total.
2. THREE distinct risk grammars, all with the risk legible BEFORE commitment: (a) countdown-to-a-
   floor (AFM 100M->25M with a physical strobe; JP 20s with no ball-save); (b) explicit
   BANK-OR-PUSH button (Godzilla Fight or Flee); (c) keep-points-but-lose-the-MULTIPLIER on failure
   (TZ Battle the Power). (c) is the gentlest and maps cleanly onto a glory product that is already
   multiplicative.
3. Press-your-luck by DEFERRED COLLECTION (MM: leave modes lit and uncollected to stack up to
   4-ball, 875K/1M jackpots) is the mechanism that produces a WIDE mid-risk band rather than a
   binary.
4. A physically different, more dangerous BALL (TZ Powerball) announces elevated risk with zero UI.

**Additional cross-cutting design principles** (from the multiball/wizard-mode and modes/bonus-
tally researchers, 02b/02c — genuinely complementary to the four points above, not overlapping):
- A jackpot shot is a switch, not a stat — it pays nothing until a separately-tracked action flips
  it lit; the switch and the payout are two different objects in the code on every reference table.
- Escalating cost defeats farming (Godzilla's Mechagodzilla spinner: 20+10 per activation) — the
  closest reference precedent to a "fire counter that changes future behavior," not just records a
  count.
- Mutual exclusion enforces scarcity (AFM's Total Annihilation locks out regular multiball while it
  runs) — protects a top-tier mode's specialness structurally, not just by rarity of the trigger.
- A roaming/escalating super-jackpot is its own reward tier, gated behind banking several ordinary
  jackpots first, worth an order of magnitude more, and actively hard to hit (AFM's Super Jackpot
  physically relocates every 5 seconds).
- Every reference table's Bonus X is non-decaying and continuously visible — no table's build-up
  meter ever regresses mid-ball; Paintbot's heat is the only build-up mechanic studied here that
  decays.

---

## What is NOT verified (name it plainly)

- **Pinball-reference specifics — CORRECTED 2026-09-09.** No longer "all recall": specifics for
  Medieval Madness, Attack from Mars, Godzilla (Stern 2021), Jurassic Park Pro (2019), and
  Twilight Zone are now live-web-sourced with named sources and per-claim confidence markers (see
  Provenance note and each dimension above). Two small cross-researcher numeric disagreements were
  found and left unresolved rather than guessed at: (1) AFM's wave count feeding "Attack & Conquer
  Mars" is reported as 5 by one researcher and named as a precondition of "all 6 Attack Waves" by
  another (Dimension 7); (2) the exact Martian Multiball gate sequence is described at different
  granularity by two researchers (Dimension 2) — likely complementary, not contradictory, but not
  independently reconciled here. Score-distribution percentiles (Dimension 8) had no sourced
  researcher dispatched against them at all and remain pure recall/folklore.
- **Whether `play_view` (the policy's perception surface) can expose a "risky moment" or "mode
  lit" signal today** — still not exhaustively checked by any researcher this round; needs a
  dedicated grep of `play_sdk`/view-field definitions before Step 4 design work on gaps 4, 5, 6, or
  7 above (all of which assume some new perceivable state).
- **Whether any timer/mode-window primitive exists anywhere in the sim beyond zone-phase timing** —
  now checked by TWO independent keyword greps (original: `wizard`/`finale`/`skillshot`/
  `modeTimer`; recovered researcher: `jackpot`/`multiball`/`wizard`, case-insensitive, across
  `sim.nim`/`glory.nim`/`docs/paintball/RULES.md`), both zero hits — still keyword greps, not an
  exhaustive read of an 8,000+ line file, so left as NOT VERIFIED rather than confirmed absent.
- **No published percentile data for real pinball score distributions was found or rigorously
  searched for** (Dimension 8) — no sourced researcher covered this dimension; treat "100x/1000x"
  as folklore pending Step 3's own target-setting exercise, not as an external benchmark this study
  established.
- **NEW — `docs/paintball/RULES.md` was never grepped for alliance/ally/team-up vocabulary.** A
  planned follow-up, meant to check for a half-documented capstone or pact-adjacent concept under
  different words, did not complete before a researcher's shared worktree was removed mid-task by
  a sibling agent (a known hazard in this environment).
- **NEW — whether achievement-tier claims surface as a live HUD gauge in `client/player_hud.js`**
  is not checked (same worktree-removal interruption). The claim is only confirmed server-side
  (`sim.nim` achievement feed / one-shot toast-log event); "no running gauge" is a likely read, not
  a confirmed one.
- **NEW — the season leaderboard's "rolling mean" aggregation code was not located inside
  `src/ctf/`** (zero hits for "rolling mean"/"geometric mean"/"season_score"/"SeasonLeaderboard").
  This directly **softens** this study's own Dimension 4(b), which had asserted the rolling-mean
  behavior as settled fact — it is UNVERIFIED in this checkout, likely lives in a separate
  league/leaderboard service, and should be treated as believed-but-not-code-confirmed pending that
  follow-up search.
