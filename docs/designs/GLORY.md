# Glory

## What it is

Glory is paintbot's score. Every consequential act on the field — a kill, a
save, a steal, a clean sweep — mints an integer amount of **glory** to the
acting team's ledger. It is not a side stat: it is the number the scorebug,
the endcard and the league standings all show as THE score, replacing the
older `kills/deaths` framing.

Three systems sit under that one word, and they answer three different
questions:

- **Deeds** (this doc's "Deeds and drama") price what a TEAM did.
- **The per-life ladder** ("XP and stars") prices what one COG did, and
  buys that cog real, playable power for as long as it stays alive.
- **Achievements** ("The curriculum") price a team's mastery of the full
  kit, independent of whether it won.

A fourth mechanic, **heat**, is not a currency of its own — it is a
multiplier that rides on top of deed glory, rewarding a live streak.

Every number in this system lives in exactly one file, `src/ctf/glory.nim`,
which the sim, the achievement tracker and the ladder all read through a
small set of accessors. Glory is **causal**: it changes gameplay (levels
grant buffs, buffs change hit points and fire timing), so it is entered into
`gameHash` and must never depend on anything that isn't replay-deterministic.

## Deeds and drama

A **deed** is a priced act — a kill by weapon, a flag steal, a capture, a
denial, a clutch heal, a point of shield absorbed, a wipe, a friendly-fire
penalty. Each deed carries two numbers:

- **Glory**: the integer amount minted to the team ledger.
- **Drama**: a spectator weight, in tenths, that decides whether the deed
  lights heat and ranks how the replay feed highlights moments. A deed can
  be worth real glory and zero drama — an economy act that funds a team
  without being a moment (shield soak is the clearest example).

Every kill resolves to **exactly one** deed, chosen by a fixed priority
order (a friendly-fire penalty outranks every flattering description; the
victim's own situation — carrying the flag, near their own base, a levelled
target — outranks how they were shot; a plain gun kill is the floor). This
prevents one kill from paying five times for satisfying five descriptions
at once.

Where a deed happened also matters: a **site gradient** prices initiative
into an enemy-held part of the arena above sitting on your own ground,
using nearest-home-pedestal ownership rather than a fixed midline, so the
same rule works regardless of how many teams' bases sit on the map.

## Heat

A team on a live streak of drama deeds climbs a **heat ladder**: enough
"embers" (one per drama deed) crosses a threshold and the team's next drama
deeds mint at a multiplier — the flame you see on the scorebug. It costs a
real streak to reach the top rung, not one lucky kill, and heat bleeds away
during a quiet stretch, so no team can bank a multiplier it has stopped
earning. Heat only ever amplifies deed glory that was already going to
mint; it is never its own source of income.

## XP and stars

Separately from the team ledger, each living cog runs its own five-rung
**per-life ladder**. It levels on WORK, not outcomes: damage landed (by any
weapon), healing taken, kits picked up, and flag play all pay experience;
kills pay none. The reasoning is that a kill is the last-hit lottery on
damage mostly dealt by the team, so it belongs on the (team-wide) glory
ledger, not the (individual) ladder — and every source that DOES pay is
naturally rate-limited (pickups respawn on a timer, damage is capped by
what a fight can actually produce), so nothing on this ladder can be farmed
by repeating a free action.

Each rung a cog crosses buys a real, playable capability — not just a
bigger number:

1. **Tagger** — a faster trigger.
2. **Marksman** — the spray can recycles faster.
3. **Ironhide** — one more hit point of headroom (must still be healed
   back; a level-up is never a free heal).
4. **Quickdraw** — faster fire, and the grenade holds two charges.
5. **Legend** — the fastest trigger in the game, and carrying the enemy
   flag no longer slows you down.

The anti-snowball rule: **levels are per life**. A cog's xp resets to zero
on death and every buff goes with it. A cog that reaches level 3
("Ace") is a visible, named threat AND a fat bounty — killing one
prices as its own deed — so the counter-play to a runaway veteran is
always the same: tag them out before they cash in further.

### The supply drop

At Ace level, a cog's team pedestal starts producing kit — a med
kit, grenade, spray can or shield appears for the team to collect. It is
fed by continued EARNING, not by standing still: every fixed amount of new
xp an Ace-level cog scores drops one pickup, on a cooldown, capped per
life. A veteran that keeps fighting keeps the kit coming; one that hides
behind a wall produces nothing, because the tap only ever moves on landed
effect.

## The curriculum

Achievements are an eight-tree, five-tier curriculum — one tree per kit
(gun, spray, grenade, teamwork, supply drop, flag-carrying, defending) plus
two team-wide trees (fielding the full kit, a clean sheet). Forty named
tiers total, each claimable once per team per game, priced by tier rather
than by deed.

The laws that hold the whole curriculum together:

1. **One-shot per team per game.** A per-tick reward gets farmed; a claim
   fires once and is done.
2. **Every team can claim every tier**; the first team in the game to
   claim TIER V of a tree claims at a bonus multiplier — no other tier
   ever races, no matter who gets there first (no more than a quarter of
   the 40 possible claims can ever be a "first"). A first-only reward
   would teach the other teams nothing; a race on every tier would make
   most claims feel like a coin flip instead of a real milestone.
3. **Big enough to chase, too small to win on.** Sweeping the entire
   curriculum must be worth less than winning the game outright.
4. **Achievements never light heat.** Heat is for the LIVE fight; a claim
   mints through the same ledger but never climbs the multiplier ladder.
5. **Never a self-benefiting act.** Achievements and glory reward play
   ABOVE AND BEYOND normal, never a cog benefiting only itself. This is
   judged by MECHANICS, not by name: a shield protects only its own
   wearer, so soaking hits is not a team act however "defensive" it
   sounds; healing yourself is not a team act either. The one genuine
   team-benefit loop in this game is the supply drop, because any
   teammate — not just the veteran who earned it — may consume a drop.

A tier never rewards mere possession, arrival, or a pickup by itself — an
act that already pays for itself mechanically (a pickup heals or arms you)
is not "above and beyond" normal play. Every tier reads the CONVERTED
result the pickup was only ever a precondition for: not "you picked up a
grenade" but "you killed someone with it."

Two trees were caught violating law 5 and re-founded rather than patched:

- **The shield tree** used to price absorbed hit points directly — soaking
  protects only the wearer, so it was rewarding self-preservation, not
  teamwork. It is now **the teamwork tree**: landing an assist (your damage
  set up a teammate's kill), covering the flag carrier, rescuing a
  teammate who was about to die, riding a rescue into a kill of your own,
  and a genuine multi-teammate kill volley.
- **The med kit tree** used to price healing yourself — the same
  violation on the survival side. It is now **the supply drop tree**:
  every tier reads whether a TEAMMATE consumed kit your own heart
  produced, and whether that teammate was in real danger when they did.

## Tooltips

Every tier's requirement ships to the viewer as a plain, truthful sentence
— no fiction, just the mechanic the gate actually checks — and shows as a
native tooltip over the achievement panel. The text lives in exactly one
place, the same "one accessor" rule every other glory number follows, so a
tooltip can never promise something the gate does not check.

## Versioning

Every pricing table, threshold and curriculum requirement is stamped with
one integer, bumped whenever a change moves WHETHER or HOW MUCH something
mints or levels. A ledger recorded under one version is never comparable to
a ledger from another — replays carry their version in the hash and refuse
to validate against a mismatched table, and the offline measurement tool
that scores real games refuses to run until its own copy of the pricing
tables is confirmed in sync with the live one.

## 4-team port inventory

Every rule above is already written to be team-count agnostic where it
matters (the site gradient uses nearest-pedestal ownership specifically so
it needs no fixed midline). A handful of surfaces still hardcode "exactly
two teams" and would need attention before glory could run correctly on a
board with more than two:

- **`src/ctf/sim.nim`, the enemy-flag lookup inside `awardDeed`** — used to
  spell out `if team == Red: Blue else: Red` inline (twice) to find the
  opposing flag when deciding whether a deed's team is currently carrying.
  Fixed this wave to call the existing `enemy(team)` helper instead, which
  generalizes for free once `Team` grows past two values.
- **`broadcast.nim`'s `gloryLine`** — the live wire shape that carries a
  team's glory/heat state to the viewer is a fixed 5-integer tuple, built
  for exactly two teams. A third team has nowhere to go on that wire
  without a shape change.
- **The client's `#glory-red` / `#glory-blue` DOM ids and the `ec-*`
  endcard id pairs** — hardcoded per-color element ids rather than a
  per-team loop, so the HUD and endcard both assume exactly the two colors
  that exist today.
- **The league replayer's plaque layout** — "left plaque, right plaque"
  is a literal two-team assumption baked into the broadcast layout, not a
  generic N-team roster panel.

None of these are fixed in this wave beyond the one `sim.nim` site above,
which sits inside code this wave already owns and is a pure refactor (same
behavior for today's two teams). The other three sit in files outside this
wave's ownership and would need their own pass.
