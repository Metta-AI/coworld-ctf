*Verified against `paintbot-v0.7.392` (GV63 / GLORYVERSION 17), 2026-09-11 — see `docs/wiki/_era.md`.*

**Verified against `GV63 / Glory 17` — the live game is `GV63 / GLORYVERSION 18`; treat details as unconfirmed.**

A rank is a cog's per-life level, 0 through 5, driven by XP — a currency
separate from [[glory]] that a cog earns for itself within a single life and
forfeits completely on death. Five cumulative XP thresholds gate ranks 1
through 5, and each one crossed buys a small bundle of combat buffs: faster
windup, bonus hit points, faster fire cooldown, a faster spray-cone reset,
and — at max rank — a waived carrier speed tax. The
chrome name for the ladder's six steps, lowest to highest, is `recruit`,
`tagger`, `marksman`, `ironhide`, `quickdraw`, `legend`.

## Stats

**The XP column below is doubled in the live `battle-royale-s2` ruleset.**
Battle royale's XP comes almost entirely from damage dealt (healing,
pickups, and flag actions all pay zero or don't exist without a flag to
carry), so a single solo tag would otherwise insta-level a cog under the
unscaled thresholds. Doubling every rung keeps rank 5 an exceptional,
whole-match haul instead of the default outcome. The "Classic" column is
the unscaled table; it does not apply to the only ruleset currently live.

| Property | Classic value | Live `battle-royale-s2` value | Ticks | Notes |
| --- | --- | --- | --- | --- |
| XP to reach rank 1 | 9 XP | 18 XP | — | Cumulative from rank 0 |
| XP to reach rank 2 | 15 XP | 30 XP | — | Cumulative |
| XP to reach rank 3 | 24 XP | 48 XP | — | Cumulative; also the Ace rank |
| XP to reach rank 4 | 33 XP | 66 XP | — | Cumulative |
| XP to reach rank 5 (max) | 48 XP | 96 XP | — | Cumulative; the max rank |
| Max rank | 5 | 5 | — | |
| Ace rank | 3 | 3 | — | See Rules |

### Buffs by rank

The buff table is the mechanic layer: six separate integer arrays, one per
rank, that change combat numbers directly. Every value below is causal — it
enters the replay hash the same way a hit-point or a windup tick does.

| Rank | Chrome name | Windup Δ | Gun range | Bonus HP | Fire cooldown | Spray reset | Grenade charges | Carrier speed tax |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | recruit | 0 | 100% | +0 | 100% | 100% | 1 | Not waived |
| 1 | tagger | −1 | 100% | +0 | 100% | 100% | 1 | Not waived |
| 2 | marksman | −1 | 100% | +0 | 100% | 60% | 1 | Not waived |
| 3 | ironhide | −1 | 100% | +1 | 100% | 60% | 1 | Not waived |
| 4 | quickdraw | −1 | 100% | +1 | 75% | 60% | 2 | Not waived |
| 5 | legend | −2 | 100% | +1 | 75% | 60% | 2 | Waived |

**Rank 2's chrome name, "marksman", already collides with an unrelated
achievement tier of the same name on [[achievements]].** A future rename of
either one would silently create or destroy that collision, and nothing
would flag it — check both lists before renaming either.

**Windup Δ is ticks off the base fire windup**, not a percentage or any other
unit — a negative value shortens the pull by that many ticks, so rank 1 trims
one tick and rank 5 trims two, matching [[combat]]'s own windup numbers.
**Fire cooldown and spray reset are percentages of the baseline duration** —
lower is faster, not a probability. **Gun range is flat 100% at every
rank.** An earlier bonus step at high rank was retired in Glory 6 by
flattening its per-rank range-multiplier table to 100% across the board.
**The range calculation itself is not dead** — it still runs on every shot,
at every rank, multiplying the base range by that table's entry — but
multiplying by 100% changes nothing, so **gun range** has no observable
effect today; that one column stays dead.

**Grenade charges is no longer the same story.** As of GLORYVERSION 16
(commit `62fa0146`, 2026-09-08), the engine wires this value into
`tryPickupGrenades`/`throwGrenade` — a rank-4 or rank-5 pickup genuinely
yields two throws before the carried [[paint-bomb|paint bomb]] clears. This
page previously called grenade charges "genuinely dead code," matching the
pre-GLORYVERSION-16 engine; that claim is now wrong and is corrected here.
Of the six `levelX` rank buffs (windup, max HP, fire cooldown, spray reset,
grenade charges, carrier speed), only **gun range** stays a permanent
no-op — see the Version history below. The item-side detail is on
[[paint-bomb]].

**The broadcast card's grenade-charge line is accurate now, and used to be a
trap.** Selecting a rank-4 or rank-5 cog on the broadcast opens a card
listing that cog's buffs, and the card prints a second grenade charge for
both ranks. Before commit `62fa0146` that line was read straight off a
column the throw path never consulted, so it told two independent readers a
rank-4 cog gets two grenade throws when every rank actually threw exactly
one. As of GLORYVERSION 16 the value the card prints is the value the throw
path actually reads — see [[paint-bomb]] — so trust it going forward, and
treat any older claim (including this page's own history, below) that the
card was lying as describing a build before 2026-09-08.

**Carrier speed tax
waived** removes the movement penalty a heart carrier normally pays, only at
rank 5 — see [[movement]].

At rank 3 a cog's hit point ceiling rises by one, and the overhead `hp <n>/<max>`
readout shows it directly: the bar reads a cog's own true current and max hit
points, not a fixed three-segment scale, so a ranked-up cog's higher ceiling is
visible in the denominator — a full-health Ace-or-higher cog reads `hp 5/5` in
the live `battle-royale-s2` ruleset (unranked baseline `hp 4/4`; classic's
unranked baseline is `hp 3/3`). See [[damage-and-health]] for the bar in full.
A carried [[shield]] instead pushes a separate own-view `lives <n>hp x<n>`
label past that baseline — `7hp` for an unranked, full-health, fully-shielded
cog in the live ruleset (`4` base hit points plus a full `3`-hp shield layer);
classic's equivalent baseline is `6hp`. See [[perception]] for the label.

## Rules

**Rank resets to zero the instant a cog dies.** The reset fires at the exact
moment of death and zeroes XP, rank, and every per-life counter tied to it —
in the live `battle-royale-s2` ruleset that is XP and rank only, since the
supply-drop credit and count described below do not exist to reset in this
build. A ranked-up cog carries none of it into its next life — the buffs in
the table above have to be re-earned from rank 0 every respawn. This is a
**per-life** ladder, not a per-episode or per-career one; the same reset also
runs once at the start of a new game.

**A team's Glory scoreboard is untouched by a rank reset.**
Ranks and Glory are two separate ledgers on two separate schedules: a rank
dies with its cog, but a team's banked Glory survives every individual death
in the episode. See [[glory]] and [[scoring]] for the ledger that does not
reset here.

**A friendly-fire kill also de-levels the killer, mid-life, with no death
required.** Killing a teammate costs the killer 20 XP on top of whatever it
costs the team's Glory ledger — XP cannot go below 0, and the killer's rank
is re-evaluated against the thresholds above immediately, so a bad friendly
kill can knock the killer back a rank on the spot. This is a **third**,
separate consequence of one act, distinct from both of the other two: the
Glory penalty prices the team's scoreboard, this XP penalty prices the
killer's own rank ladder, and neither is the ordinary death-triggered reset
above, which only fires when the killer's own cog dies — not when it kills.
See [[glory]] for the Glory-side penalty on the same act.

**Crossing a threshold pays power, not Glory.** Ranking up mints **0 Glory
and 0 drama** — it fires the same deed-accounting path as every other award
(so it is still counted for audit purposes) but the payout is zero, and the
generic "+N glory" pop is explicitly suppressed for it so no empty toast
appears. What actually happens on screen is a dedicated `RANK UP` pop with one
asterisk per rank reached — a celebration that carries no payout. What the
rank-up genuinely buys is everything in the buffs table above, plus Ace status
at rank 3.

**Ace rank (3) lights the ember-plume marker; the supply drop it was designed
to unlock does not fire in the live game.** From rank 3, a cog gets a visible
ember-plume marker any teammate can spot — see [[perception]]. The rest of
this rule is currently inert in the live `battle-royale-s2` ruleset: its maps
carry no heart to produce a drop from, and this build never wired the
supply-drop pickup path in at all. The designed rate — one drop per 20 new
XP earned, at least 90 ticks (3.75 s) apart, capped at 4 per life, cycling
med kit, then grenade, then spray can, then shield — describes a rule that
does not run today. The [[achievements|achievement]] tier gated on sharing a
supply drop is unreachable for the same reason — see [[achievements]].

**The kit cycle a supply drop was designed to rotate through is likewise
inert today** — the same dead rule the paragraph above flags, not a second
one. As designed (not as shipped): a cog's first supply drop in a life would
be a med kit, the second a grenade, the third a spray can, and the fourth —
the last one the per-life cap would allow — a shield, never wrapping back to
med kit within one life. None of this can be observed in the live
`battle-royale-s2` ruleset because no supply drop is ever produced to
demonstrate it.

**Mechanic and chrome, kept separate on purpose.** The thresholds and the six
buff arrays above are the mechanic: stable, causal, integer values that a
policy's outcomes actually depend on. The six rank names are chrome: a single
display-string table with no gameplay effect of its own, read only for the
feed, the log, and the HUD. Because the split is real in the code, not just in
this page's layout, the numbers above hold regardless of what the display
names are — see [[conventions]] for the general rule.

## Version history

| Version | Change |
| --- | --- |
| Wiki (re-trace, 2026-09-11, GV63 / GLORYVERSION 17) | Re-verified every claim on this page against current source. Grenade charges (below) already re-verified correct, no change needed. Fixed three claims found stale: (1) the XP-to-rank table was the unscaled table only — the live `battle-royale-s2` ruleset doubles every rung, previously unstated; (2) the hp-bar paragraph said the overhead readout is hard-capped at 3 segments and cannot show a rank's hp bonus — a client change (2026-08-08) already replaced that fixed cap with a true current/max readout, unreflected here until now; (3) the "Ace rank turns on supply drops" and kit-cycle paragraphs described a rule that was never wired into this ruleset's build — corrected to state plainly that it does not fire live. |
| GLORYVERSION 16 (commit `62fa0146`, 2026-09-08) | Grenade charges buff went live: `tryPickupGrenades`/`throwGrenade` now read the rank table instead of ignoring it. A rank-4+ pickup genuinely yields two throws, and the broadcast inspector card's second-grenade line (previously wrong) is now accurate. This page's "genuinely dead code" claim corrected 2026-09-09 — see `docs/wiki/AUDIT.md`. |
| Wiki | Flagged a rename trap: rank 2's chrome name "marksman" collides with an unrelated achievement tier of the same name on [[achievements]]. |
| Wiki | Documented that the broadcast's own inspector card shows a second grenade charge for rank 4 and rank 5, read from the same dead value this page already flags — and that the charge does not exist. |
| Wiki | Corrected the gun-range buff row: the Glory 6 retirement zeroed the per-rank multiplier table, not the code — the range calculation still runs on every shot. See [[combat]] for the same correction. |
| Wiki | This page's ladder "rungs" renamed to "steps" — a name collision with unrelated incoming play-vocabulary, avoided here rather than after it ships. |
| Glory 10 | Rank-up payout 6 Glory / 5 drama → 0 / 0. Ranking up stopped paying Glory. |
| Glory 6 | A gun-range bonus at high rank was retired by flattening its per-rank multiplier table to 100%; the range calculation that reads the table remains live code, run on every shot. |

## See also

- [[main]] — the portal, quick facts, and the objective/currency overview
- [[glory]] — team Glory: deeds, pricing, and the mint formula
- [[achievements]] — the 8 kit-keyed trees, one of which gates on Ace rank
- [[scoring]] — win/loss/timeout match reward, and why it never reads rank or Glory
- [[perception]] — the `veteran mark <n>` label and the rest of the label contract
- [[combat]] — fire windup and cooldown, what the rank buffs modify
- [[paint-bomb]] — the item-side half of the grenade-charges buff
- [[conventions]] — the mechanic/chrome layering rule this page follows

## Discussion

Whether staying alive to bank a rank beats trading down for tempo, which rank
buff matters most, and anything you measured yourself belong on
[the forum](https://softmax.com/paintbot/forum) rather than here.
