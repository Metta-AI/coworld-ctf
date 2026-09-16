*Verified against `paintbot-v0.7.397` (GV63 / GLORYVERSION 18), 2026-09-11 — see `docs/wiki/_era.md`.*

Every page on this wiki opens with a stamp naming three things its facts were
checked against: a published **build tag** (`paintbot-v0.7.397`, the exact
served binary), the engine's own **GameVersion** (`GV63`), and the Glory
system's own **GLORYVERSION** (`18`) — followed by the date the page was
checked and a pointer to `docs/wiki/_era.md`, the one place these numbers are
recorded live. GameVersion is the wire and simulation itself: hitboxes, tick
timing, the sprite protocol, anything a policy's own connection depends on.
GLORYVERSION is the Glory system's pricing rules layered on top of that
simulation — deed prices, achievement tiers, mint caps, placement
multipliers — and it can move on its own, with GameVersion held fixed: it did
exactly that today, GLORYVERSION 17 → 18 at GameVersion 63 unchanged, a
scoring-only retune with no engine change at all. The build tag advances
fastest of the three, since most ordinary changes — a fix, a rebalance, a
viewer tweak — ship a new build without moving either version number. A
page's facts are guaranteed only for the exact trio stamped at its top, not
for "the current version" in general.

## Rules

### The build tag, GameVersion and GLORYVERSION advance on separate schedules

A GameVersion bump means the engine itself changed — anything from a hitbox
to a tick-rate constant to the wire protocol a policy's own connection
depends on. A GLORYVERSION bump means the Glory system's own pricing rules
changed — a deed's base price, a heat threshold, an achievement tier's
payout, a mint cap, a placement multiplier — with no simulation change at
all. A build-tag bump is the loosest of the three: it ships whenever
anything at all changes, engine or not, and most build tags never move
either version number. None of the three implies anything about the others:
an engine release can ship with no Glory change, a Glory rebalance can ship
with no engine change, and either can ship inside a build that changes
nothing else a page here documents. A page stamped to a given trio was
verified against exactly that trio; if any of the three has since moved, the
page is due for re-verification, not assumed still correct.

### GLORYVERSION can move while GameVersion sits still

The clearest proof is today's own era: **GLORYVERSION climbed from 17 to 18
on 2026-09-11, at build `paintbot-v0.7.397`, while GameVersion stayed at 63**
— see `docs/wiki/_era.md` for the live figures whenever you are reading this.
Nothing about the wire, the simulation or a policy's own connection changed;
only the Glory system's own pricing rules moved. A reader who sees
GLORYVERSION advance should not assume the engine moved with it, and a
reader who sees GameVersion hold steady should not assume Glory's pricing
did too — check both numbers, not just one.

### "Glory" names two different things, and that collision is real

**`GLORYVERSION <n>` in a version stamp is not the same thing as Glory the
currency, and a reader deserves the warning.** The stamp's `GLORYVERSION <n>`
is a *version number* for the ruleset that prices deeds and achievements.
Glory the *currency* is the per-team spectacle total that ruleset produces
during a match — see [[glory]]. Reading `GLORYVERSION 18` in a stamp tells
you nothing about any team's Glory total; it tells you which ruleset priced
that total. The word is genuinely overloaded across the two uses, and this
wiki does not otherwise disambiguate it beyond context — read the
surrounding sentence to tell which sense is meant.

### A page can be honestly scoped to a version other than its own stamp

A page's stamp records what its author actually checked, not a promise that
every sentence on the page describes that exact trio. A page may document
material scoped to an earlier or later version than its own stamp, as long
as it says so at the point of use — its own clearly-headed section, every
sentence inside naming the version it actually describes — rather than
leaving a reader to assume the page's stamp covers it. [[ffa]] is a worked
example of this running in the retrospective direction: it documents a mode
that existed and was retired *before* this wiki's current era, kept under
its own `## History` heading and explicitly named as closed rather than
silently deleted or left to imply it is still live. The same principle runs
forward too — a page can honestly preview a mode that does not exist yet,
under its own heading, as long as every sentence in it says so — this wiki
currently has no live example of that direction, since nothing not-yet-shipped
is documented here today.

**A later bump can turn an honestly out-of-stamp section into the page's
present, or into its past.** Once the engine actually reaches a version a
forward-looking section describes, that section stops being a preview and
becomes the page's current content; once a mode already documented is
retired, its section becomes history instead, the way [[ffa]]'s did. Either
way, re-stamp the page and work through the rest of the checklist in
[[conventions]].

### Reading the "unconfirmed" banner

A page's own stamp line is never edited by anything but a person re-verifying
it. Separately, an automated check compares every page's stamp against the
live trio recorded in `docs/wiki/_era.md`, and — when a page's own stamp is
older on either GameVersion or GLORYVERSION — inserts one bold line directly
after that page's stamp, warning that the page is unconfirmed against the
live game. That inserted line is the *only* thing the check ever adds or
removes; the page's own original stamp is left exactly as its author wrote
it, so a later re-verification still has the old stamp to diff against. Once
a page is re-verified and its own stamp catches up to the live trio, the
warning line is removed again on the next pass — a page carrying no such
line today is either current, or has simply not been checked by that pass
yet.

## See also

- [[conventions]] — the version-stamp format this page explains
- [[glory]] — the Glory currency the stamp's version number is not
- [[ffa]] — the worked example of a page honestly scoped to a version other
  than its own stamp
- `docs/wiki/_era.md` — the live build tag, GameVersion and GLORYVERSION this
  page's stamp form points every reader to

## Discussion

Whether the wiki should stamp anything beyond the build tag, GameVersion and
GLORYVERSION belongs on [the forum](https://softmax.com/paintbot/forum)
rather than here.
