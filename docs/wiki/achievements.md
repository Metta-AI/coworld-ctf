# Achievements

*Verified against [[versions|GV24 / Glory 12]].*

**Verified against `GV24 / Glory 12` — the live game is `GV63 / GLORYVERSION 17`; treat details as unconfirmed.**

An achievement is one of 40 fixed claims — **8 trees, 5 tiers each** — that
mint [[glory|Glory]] into a team's scoreboard the instant its gate condition
is satisfied, on top of and separate from per-kill deed pricing. Every tree is
keyed to a kit, a role, or a team behaviour, and every tier from I to V both
prices higher and gates harder than the one before it. Claiming a tier never
touches heat and only ever multiplies for a first claim at tier V — tiers I
through IV never carry a first-claim bonus.

**No tree has a shipped display name.** The 8 trees are fixed in a stable
order, and each is identified only by the 5 real per-tier names inside it —
the per-tier name array is the only achievement *name* table that exists as
a runtime string. Each tier also ships a one-sentence tooltip description,
read by the client as a native `title=` attribute on the achievement panel
and the two team dropdowns — given verbatim, per tier, in its own Shipped
tooltip column below. If you need a tree-level display name for UI, there is
currently no shipped one to reach for.

## Stats

| Property | Value | Ticks | Notes |
| --- | --- | --- | --- |
| Trees | 8 | — | Ordinal-fixed enum |
| Tiers per tree | 5 | — | I through V |
| Total claims | 40 | — | 8 × 5 |

### Tier pricing

**These flat prices are the classic (CTF) ladder's.** Paintbot (Season 2)'s
live `battle-royale-s2` ladder reprices every tier below as a whole-number
multiplier instead of a flat Glory/Drama pair, composed into a per-duo
product rather than added to a per-team total — see [[glory-season-2]] for that
ladder's pricing map. The gate conditions in `### The 8 trees` below (what
unlocks each tier) are unaffected — only the payout number changes.

| Tier | Glory | Drama (tenths) |
| --- | --- | --- |
| I | 9 | 5 |
| II | 11 | 5 |
| III | 14 | 15 |
| IV | 18 | 15 |
| V | 23 | 30 |

**The Drama column above never does anything.** An achievement claim never
climbs the heat ladder and never takes the carry multiplier — for an
ordinary deed, both are gated on a positive Drama price, see [[deeds]] and
[[glory]] — so tier V's larger Drama number carries no more weight than
tier I's smaller one; neither carries any weight at all. Achievements never
feed heat, full stop, regardless of tier.

Each tier's Glory value scales by the same site gradient a deed gets — 100%
on home ground, 150% on the enemy's — but **never by heat**: the per-claim
price is flat, never streak-scaled, regardless of how hot the team's kill
feed is running. A **first claim of tier V only** additionally multiplies the
result ×3; tiers I–IV are never first-claim eligible, at any point in a game.
"First" is scoped to the whole episode and both teams together, not to one
team's own history — whichever team, of the two in the match, is the first
to clear a given tree's tier V takes the bonus; the other team still banks
the same tier V at its un-multiplied price if it clears it later.

### The 8 trees

The Unlock column below describes the gate condition each tier actually
checks in the simulation, in this page's own words. The Shipped tooltip
column beside it is the different thing: the verbatim client-facing
sentence, transcribed exactly as it ships.

### Gun

| Tier | Name | Unlock | Shipped tooltip |
| --- | --- | --- | --- |
| I | "First Tag" | A gun kill | "Get a kill with your gun." |
| II | "Marksman" | 3 gun kills in one game | "Get 3 gun kills in one game." |
| III | "Bounty" | Killed an enemy at or above [[ranks]]'s Ace rank | "Take down an enemy who has leveled up to Ace rank or higher." |
| IV | "Sharpshooter" | A cog reaches max rank in one life | "Reach max rank in one life." |
| V | "Longshot" | A kill past the [[deeds]] longshot range | "Land a kill from way out past the longshot range." |

### Spray can

| Tier | Name | Unlock | Shipped tooltip |
| --- | --- | --- | --- |
| I | "First Coat" | A spray kill | "Get a kill with the spray can." |
| II | "Full Coverage" | 2 spray kills in one game | "Get 2 spray kills in one game." |
| III | "Repainted" | 2 spray kills on one [[spray-can]] pickup | "Get 2 spray kills with the same can." |
| IV | "The Muralist" | 3 spray kills on a single pickup | "Get 3 spray kills with the same can." |
| V | "Double Splash" | One cone activation kills 2+ enemies | "Hit 2 or more enemies with one spray blast." |

### Grenade

| Tier | Name | Unlock | Shipped tooltip |
| --- | --- | --- | --- |
| I | "Delivery" | A [[paint-bomb]] kill | "Get a kill with a grenade." |
| II | "Splatterbomb" | 2 grenade kills in one game | "Get 2 grenade kills in one game." |
| III | "Blast Radius" | A blast catching 2+ enemies | "Catch 2 or more enemies in one grenade blast." |
| IV | "Double Blast" | Two separate multi-kill blasts in one game | "Catch 2 or more enemies in a blast, twice in one game." |
| V | "The Bombardier" | 3 grenade kills in one game | "Get 3 grenade kills in one game." |

### Shield / teamwork

Re-founded as the teamwork tree; see Version history.

| Tier | Name | Unlock | Shipped tooltip |
| --- | --- | --- | --- |
| I | "Cover Fire" | Land an assist — your damage plus a teammate's finishing kill, within the assist window | "Damage an enemy that a teammate finishes off soon after." |
| II | "Escort Duty" | Land a kill while a teammate carries the enemy heart | "Get a kill while a teammate is running the enemy's heart." |
| III | "The Save" | Kill a cog that recently put a teammate at or near [[med-kit]]'s clutch HP | "Take down an enemy who just hurt one of your teammates badly." |
| IV | "Second Wind" | Get rescued, then land a kill within the follow-up window | "Get rescued by a teammate, then land a kill of your own soon after." |
| V | "Squad Volley" | **Team-wide.** 3+ distinct teammates each land a kill inside one window of each other | "Have 3 or more different teammates each land a kill in one quick burst." |

### Med-kit / supply drop

Re-founded as the team's supply-drop tree; see Version history.

| Tier | Name | Unlock | Shipped tooltip |
| --- | --- | --- | --- |
| I | "First Delivery" | A teammate consumes YOUR supply drop for the first time | "Have a teammate pick up kit from your team's supply drop." |
| II | "Clutch Delivery" | A teammate consumed your drop at or near [[med-kit]]'s clutch HP | "Have a teammate grab your supply drop while they're badly hurt." |
| III | "Regular Route" | 3 shared drops in one episode | "Share 3 supply drops with your team in one game." |
| IV | "Emergency Route" | 2 clutch saves in one episode | "Save a badly hurt teammate with your supply drop, twice in one game." |
| V | "Supply Chain" | 6 shared drops in one episode | "Share 6 supply drops with your team in one game." |

### Carrier

| Tier | Name | Unlock | Shipped tooltip |
| --- | --- | --- | --- |
| I | "Hands On" | A steal landed with a live enemy nearby — contested, not a walk-in | "Steal the enemy's heart while a live enemy is close enough to contest it." |
| II | "Fighting Carry" | An enemy kill landed while carrying the heart | "Get a kill while you're carrying the enemy's heart." |
| III | "Double Steal" | 2 contested steals in one game | "Steal the enemy's heart twice in one game, both times against contest." |
| IV | "Hard Carry" | 2 contested steals AND a kill while carrying, in one game | "Steal against contest twice AND get a kill while carrying, all in one game." |
| V | "Delivered" | Score the enemy heart | "Carry the enemy's heart all the way home for a capture." |

### Defender

| Tier | Name | Unlock | Shipped tooltip |
| --- | --- | --- | --- |
| I | "The Peel" | Kill the enemy carrier | "Kill the enemy who is carrying your team's heart." |
| II | "Doorstep" | A denial — a carrier kill inside denial range of the pedestal | "Stop a carrier right at your own team's doorstep." |
| III | "Double Peel" | 2 carrier kills in one game | "Kill an enemy carrier twice in one game." |
| IV | "Turnaround" | Peel, then steal back, within a short window | "Peel a carrier off your heart, then steal the enemy's yourself soon after." |
| V | "Lockdown" | 2 denials in one episode | "Stop carriers at the doorstep twice in one game." |

### Squad

**Team-wide** — every tier is evaluated for the whole team, not one player.
"Converted" means at least one teammate landed that kit's signature act
this game — a shared supply drop for the med-kit, a grenade kill, a spray
kill, or a landed assist for shield/teamwork — not merely holding the item.
The count is cumulative for the whole game and survives a teammate's death.

| Tier | Name | Unlock | Shipped tooltip |
| --- | --- | --- | --- |
| I | "Kitted" | 2 of 4 kits converted, team-wide | "Your team gets real use out of 2 of the 4 kits in one game." |
| II | "Full Loadout" | 3 of 4 kits converted | "Your team gets real use out of 3 of the 4 kits in one game." |
| III | "Full Kit" | **Tombstoned — zero-claim on this port** (v12, Amendment 1). Needs 4 of 4 kits converted, but `teamConvertedKits` hard-caps at `KitLegsImplemented` (3, no med-kit leg yet); no code path ever sets this tier. Restores when the med leg lands. | "Your team gets real use out of all 4 kits in one game." |
| IV | "Clean Sheet" | Zero team kills for the whole game — evaluated only at the game's conclusion | "Finish the whole game without a single teammate shooting a teammate." |
| V | "Victory Lap" | Every implemented kit converted (`kits >= KitLegsImplemented`, 3 today, was 4) AND your team has captured the enemy's heart this game (v12, Amendment 1) | "Use every kit AND capture the enemy's heart in the same game." |

### Window and threshold values

| Property | Value | Ticks | Notes |
| --- | --- | --- | --- |
| Cover Fire assist window | 5.0 s | 120 | How soon a teammate's finishing kill must land after your damage for it to count as an assist |
| Second Wind follow-up window | 5.0 s | 120 | How soon after being rescued a kill must land to still count |
| Fast Break window | 10.0 s | 240 | How soon a capture must follow the steal, in the same life |
| Turnaround window | 10.0 s | 240 | How soon a steal must follow a peel — the same duration as Fast Break's window above |
| Clutch HP threshold | 1 hp | — | The HP value "at or near clutch HP" means in The Save and Clutch Delivery — the same threshold [[med-kit]] uses for its own clutch heal |

## Rules

**The flat curriculum is priced below a win — the real ceiling is not.**
Summed across every tier of every tree at base price only — a full 40-claim
sweep, 8 trees × 5 tiers, with no site gradient and no first-claim bonus —
the total comes to 600 Glory, below the combined value of a capture and a
wipe (250 + 400 = 650). That specific comparison, the unmultiplied
base-price sweep against a capture-plus-wipe, is exactly what the test
suite checks; it is a design constraint on the pricing table itself, not a
cap on what a team can actually bank in a game. In play, the site gradient
(up to ×1.5, claiming on the enemy's ground) and the tier-V first-claim
bonus (×3) both apply on top of base price — so a team's real achievement
income in one episode can run well past that 650 figure: a full sweep on
enemy ground with every tier V landed first prices out to 1,432 Glory, more
than double a capture plus a wipe. No test bounds that multiplied total.

**This comparison assumes classic mode.** In [[battle-royale-s2|battle
royale]], neither the "capture" nor the "wipeout" deed mints at all — see
[[glory]] — so the 650-Glory capture-plus-wipe figure above is not a
comparison point that exists in that ruleset.

**A claim is a separate mint path from a deed.** Achievements do not go
through the same per-deed pricing table kills and captures use — the generic
deed slot reserved for an achievement claim always prices at 0 there. The
real payout comes from the tier pricing table above, applied by its own
formula (tier price × site gradient, ×3 if first-and-tier-V).

**Only tier V of any tree can ever be a first claim.** The ×3 first-claim
bonus and its accompanying marker are scoped to a tree's last tier only —
claiming tiers I–IV first, fastest, or before the enemy team never carries a
multiplier.

**A genuine same-tick tie pays both teams, not whichever team happens to be
evaluated first.** If both teams clear the same tree's tier V on the exact
same tick, both take the ×3 — ties are judged across every team's claims for
that tick before any of them mints, specifically so a tie is never broken by
an arbitrary team order.

## Version history

| Version | Change |
| --- | --- |
| Unrecorded | Mode-scoped the tier pricing table to the classic (CTF) ladder; Paintbot (Season 2)'s `battle-royale-s2` ladder reprices every tier as a whole-number multiplier instead — see [[glory-season-2]]. |
| Unrecorded | Noted that the base-price-sweep-versus-capture-plus-wipe comparison in `## Rules` assumes classic mode — in [[battle-royale-s2|battle royale]], neither the "capture" nor the "wipeout" deed mints, so the 650-Glory figure it compares against does not apply there. See [[glory]]. |
| Wiki | Closed this page's five open gaps: the Cover Fire, Second Wind, Fast Break, and Turnaround window durations, and the clutch HP threshold shared by The Save and Clutch Delivery — see the new Window and threshold values table. Also repointed the "Longshot" tier's link from [[combat]] to [[deeds]], which is where the longshot range is actually defined. |
| Wiki | Corrected this page: achievement Drama values are never read for anything — achievements never climb the heat ladder and never take the carry multiplier, so no tier's Drama number has any effect. |
| Glory 12 | Squad tree corrected: "Full Kit" (III) is tombstoned/zero-claim on this port — `teamConvertedKits` hard-caps at `KitLegsImplemented` (3, no med-kit leg), so no code path can ever set it; restores when the med leg lands. "Victory Lap" (V) gate corrected to `kits >= KitLegsImplemented` (3 today, was stated as 4) AND a capture this game. |
| Glory 12 | Carrier tree recut: "Fighting Carry" moved II (was III); "Delivered" moved to the single terminal tier V (was II); two new mid-game tiers added, "Double Steal" (III, 2 contested steals) and "Hard Carry" (IV, 2 contested steals AND a carry kill). The two retired names, "Uphill" and "Fast Break", no longer claim Glory — they now ship only as no-glory endcard match-record distinctions on the capture itself. |
| Glory 9 | Tier pricing table [2, 4, 8, 16, 32] → [9, 11, 14, 18, 23] |
| Glory 9 | First-claim ×3 bonus narrowed to tier V only, across every tree |
| Glory 9 | The shield tree re-founded as the teamwork tree (Cover Fire, Escort Duty, The Save, Second Wind, Squad Volley) |
| Glory 9 | The med-kit tree re-founded as the supply-drop "Provider" tree |

## Gaps

- Which GameVersion gated the "capture" and "wipeout" deeds off in
  [[battle-royale-s2|battle royale]] — confirmed behavior, not dated; see
  [[glory]].

## See also

- [[main]] — the portal and item list
- [[glory-season-2]] — the whole-number multiplier economy this page's tier prices do not apply to
- [[battle-royale-s2]] — the ruleset where the capture-plus-wipe comparison above does not hold
- [[ranks]] — the rank ladder; Ace rank gates the gun tree's "Bounty" tier
- [[deeds]] — per-kill deed pricing, and the longshot range the gun tree's "Longshot" tier reuses
- [[glory]] — deed pricing, the mint formula, site gradient and heat
- [[scoring]] — match reward, and why it never reads Glory
- [[spray-can]], [[paint-bomb]], [[shield]], [[med-kit]] — the items several trees are keyed to
- [[conventions]] — the mechanic/chrome layering rule this page follows

## Discussion

Which tree to grind first, whether coordinating for Squad Volley is worth it,
and any claim-rate numbers you measured yourself belong on
[the forum](https://softmax.com/paintbot/forum) rather than here.
