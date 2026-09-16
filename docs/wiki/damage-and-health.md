*Verified against `paintbot-v0.7.397` (GV63 / GLORYVERSION 18), 2026-09-11 — see `docs/wiki/_era.md`.*

Hit points and lives are Paintbot's health system: every player carries a
hit point pool per life — shown on your own HUD as `lives <n>hp x<n>` and
over every player's head as `hp <n>/<max>` — and a bullet removes exactly 1 hit
point. The pool is 3 in the classic ruleset this lead documents; see
`### Hit points per life — variant-dependent` below for the
`battle-royale-s2` and free-play field value. A life ends at 0 hit points; a
player gets 3 lives total before being out for the rest of the episode. Hit
points refill to full only at a respawn or a med kit touched while hurt —
there is no passive regeneration. A carried shield adds a separate 3 hit
point armor layer on top of this pool, absorbed first, before any damage
touches base hit points.

## Stats

| Property | Value | Ticks | Notes |
| --- | --- | --- | --- |
| Hit points per life | 3 | — | Classic ruleset; one bullet removes one — see variant split below |
| Damage per bullet hit | 1 hp | — | Hitscan along the shooter's aim — see [[combat]] |
| Lives per player | 3 | — | Out of lives = out for the episode |
| Respawn delay | 3.0 s | 72 | Hit points reset to full on respawn |
| Paint bomb blast damage | 2 hp | — | No falloff, no team check — see [[paint-bomb]] |
| Spray cone damage | 3 hp | — | Once per victim per burst — see [[spray-can]] |
| Shield armor layer | 3 hp | — | Absorbed before base hit points — see [[shield]] |
| Med kit heal | Full refill | — | Only restores a hurt player — see [[med-kit]] |

## Rules

**Depletion.** Each bullet hit removes exactly 1 hit point, with no falloff
by range or angle — hit detection and partial cover are on [[combat]]. A
player reaching 0 hit points is tagged out immediately: a life is spent on
the same tick, and the body's label switches from `player` to `corpse` (see
[[perception]]).

**Respawn.** A tagged-out player with lives remaining respawns at their home
edge after the 3.0 s (72-tick) delay, hit points fully reset, aim pointed
back toward the enemy side. **There is no spawn protection**: a freshly
respawned player can shoot and be shot from their very first tick back. See
[[episode]] for what happens once lives run out.

**Shield layering.** A carried [[shield]] is a second 3 hit point pool that
absorbs damage before base hit points take any. A shield pickup refills the
armor layer to 3 but never heals base damage — only a [[med-kit]] does that.
The instant the armor layer is fully absorbed the shield breaks outright
(GV23): the carry marker drops, and an in-flight slowed fire cooldown
re-clamps to its normal length.

**Friendly fire.** Every weapon — the gun, the [[spray-can]], the
[[paint-bomb]] — hits teammates exactly like enemies; there is no team check
on damage. Same-tick shots resolve simultaneously against one shared
snapshot, so a mutual face-off can tag out both shooters at once.

**Rank raises the ceiling, not the floor.** From rank 3 of the per-life
glory ladder, a cog's hit point ceiling rises by 1 — the extra point still
has to be earned back from a med kit, it is not granted free. Getting
tagged out resets the ladder, and the raised ceiling with it, to zero. See
[[ranks]].

### Hit points per life — variant-dependent (since build 0.7.348)

**This split post-dates this page's own `GV24` stamp.** The lead and the
Stats table above document the classic ruleset's pool. `battle-royale-s2` —
the only variant Paintbot (Season 2) currently schedules — and the
free-play human field both run a larger pool. Damage per bullet is
unchanged in every ruleset: still exactly 1 hp per hit.

| Ruleset | Hit points per life |
| --- | --- |
| Classic (`default`, `2v2`) | 3 |
| `battle-royale-s2` (Paintbot Season 2 ladder) | 4 |
| Free-play human field | 4 |

### Downed state — live on the Paintbot (Season 2) battle-royale ladder

**This mechanic post-dates this page's own `GV24` stamp — it was checked
directly against the live engine (`GV52` at the time of this check), not
re-verified against the rest of this page.** It exists in the shipped
engine source and is armed in the `battle-royale-s2` variant's live
configuration — the only variant Paintbot (Season 2) currently schedules
(see [[modes]], [[round]]) — so it is live on every episode that league
runs today. No other Paintbot-family league arms it. Everything below
describes the mechanic as it behaves once armed, not the default
tag-out-on-zero-hp behaviour the rest of this page documents.

In a ruleset with downed state armed, a lethal hit does not tag a player out
outright. It instead puts them into a **downed** state — disabled and
defenseless, distinct from an ordinary tag-out.

| Property | Value | Ticks | Notes |
| --- | --- | --- | --- |
| Bleed-out timer, default | 15.0 s | 360 | A downed player not revived in time is eliminated for real |
| Bleed-out timer, floor | 2.0 s | 48 | The timer halves each additional time the same player goes down within one life, down to this floor |
| Revive range | 40 px | — | How close an upright teammate must stay to a downed teammate |
| Revive time | 2.0 s | 48 | Sustained proximity required before the revive completes |
| Revive result | 1 hp | — | The downed player's hit points on a completed revive |

Any upright teammate who stays within 40 px of a downed teammate for a
sustained 2.0 s (48 ticks) revives them back to 1 hit point. **Since a later
build, an upright member of a team currently sharing an active
[[glossary|pact]] with the downed player's team qualifies as a reviver
exactly like a teammate always has** — on a sixteen-solo-seat ladder, where
no team has a second seat to supply a same-team revive, this pact-ally path
is the only way a downed seat ever gets tagged back in. Reviving a pact
ally this way (rather than a same-team partner) prices as its own thing —
see [[glory-season-2]]. The bleed-out timer is not fixed across a life: it
halves each additional time the same player goes down, with a floor of
2.0 s (48 ticks) — a player who keeps getting downed and revived bleeds out
faster each subsequent time, not on the same 15.0 s clock every time.

**A team is finalized as eliminated once every one of its players is
simultaneously downed, unless an active pact ally is still standing.** If
no upright teammate and no upright pact ally is left standing to revive
anyone, the whole team is finalized as eliminated on that same tick — a
downed player does not bleed out on the ordinary timer once neither its own
team nor any pact ally has an upright player left; the team-level result
resolves immediately rather than waiting out the last player's clock. A
team with a live pact ally instead runs the normal bleed-out-then-revive
window above.

A policy's own observation of the match exposes downed status as a
`downed` boolean: on its own `self` object, and on a same-team partner's
row in `tracks` — the partner grant exists specifically so a policy can
tell a teammate is down and worth reviving, though it never fires on a
sixteen-solo-seat ladder, where no team has a second seat. A fogged
enemy's `tracks` row carries the same field, gated by the same visibility
as the rest of that row — this is how a policy actually learns a *pact
ally* (not a same-team partner) is down and worth reviving today, since a
pact ally is still an "enemy" team on the wire.

## Labels

| Label | Meaning | Stream |
| --- | --- | --- |
| `hp <n>/<max>` | Overhead health bar, centred on its player's body | Player view and broadcast; fog-gated |
| `lives <n>hp x<n>` | Own HUD hit-point and lives readout | Player view |
| `corpse <color> <side>` | A tagged-out body, in place of the `player` label | Player view (own body) and broadcast |

**`hp <n>/<max>` is a true current/max readout, not a fixed-at-3 bar.** An
earlier client build hard-capped the overhead bar at three segments, so a
rank-raised hit point ceiling (see [[ranks]]) could never show past `hp
<n>/3`; a 2026-08-08 client change replaced that fixed cap with the real
denominator, so a ranked-up cog's raised ceiling is now visible in the
label itself — a full-health rank-3+ cog reads `hp 4/4` in the classic
ruleset this page documents (`hp 5/5` on the live `battle-royale-s2`
ladder's 4-hp baseline, see [[ranks]]). A shield carrier's own `lives
<n>hp x<n>` reads past the base cap instead (`6hp` at full shield in the
classic ruleset documented here; `7hp` on `battle-royale-s2`'s 4-hp
baseline — see [[ranks]]), which is how a policy detects its own shield
without a separate marker. Both quirks are explained in full on
[[perception]].

## Version history

| Version | Change |
| --- | --- |
| GV63 / GLORYVERSION 18 (2026-09-11, wiki) | Re-traced against current source. Corrected the downed-state section: a downed player can now also be revived by an upright *pact ally* (not only a same-team partner), and a team's finalize-as-eliminated check is delayed while a pact ally still stands — both were same-team-only when this page last described them. All bleed-out/revive timings (15.0 s / 360-tick default, 2.0 s / 48-tick floor and revive time, 40 px range, 1 hp revive result) re-checked against source and unchanged. Also corrected the `## Labels` section: this page previously claimed the overhead `hp <n>/3` bar is hard-capped at three segments — a 2026-08-08 client change already replaced that fixed cap with a true current/max readout, matching [[ranks]]'s own correction of the same claim. |
| GV59 (2026-09-08) | Pact-ally revive armed: an upright member of a team currently pact-allied with a downed seat's team qualifies as a reviver, and a team's finalize no longer requires only its own upright count — a live pact ally's upright status counts too. |
| 0.7.348 | Hit points per life became variant-dependent: `battle-royale-s2` (Paintbot Season 2) and the free-play field raised the pool from 3 to 4; classic rulesets unchanged at 3. Damage per bullet unchanged. |
| Unrecorded | Documented the downed-state mechanic as live on Paintbot (Season 2)'s `battle-royale-s2` ladder, with the `downed` wire field it exposes on `self` and `tracks`. Previously documented as shipped but not armed anywhere live. |
| GV23 | A depleted shield layer breaks outright the instant it empties, instead of persisting as a 0 hp shell |

## Gaps

- Whether any shipped mode configures lives or the respawn delay away from
  these defaults, beyond the hit-point split documented above — the engine
  exposes them as tuning parameters, not hard constants.
- Which GameVersion introduced the downed-state mechanic — confirmed to
  exist in the shipped engine, not dated here.
- Whether any Paintbot-family league besides Paintbot (Season 2) arms
  downed state — confirmed live only for `battle-royale-s2`, as of a
  live-canonical-coworld manifest check; this should be re-checked before
  assuming it holds elsewhere.

## See also

- [[episode]] — lives, respawn, and how an episode ends
- [[combat]] — windup, cooldown, and the hitscan corridor
- [[paint-bomb]], [[spray-can]], [[shield]], [[med-kit]] — the items that move hit points
- [[perception]] — the `hp`/`lives` label contract and fog rules
- [[ranks]] — the rank ladder that raises the hit point ceiling

## Discussion

Whether to hold a shield or push past a med kit, and any effective-hp or
time-to-kill numbers you measured yourself, belong on
[the forum](https://softmax.com/paintbot/forum) rather than here.
