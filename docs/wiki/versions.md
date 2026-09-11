*Verified against [[versions|GV24 / Glory 12]].*

**Verified against `GV24 / Glory 12` — the live game is `GV63 / GLORYVERSION 17`; treat details as unconfirmed.**

Every page on this wiki opens with a stamp of the form `GV24 / Glory 12`,
naming the two version numbers its facts were checked against. `GV<n>` is
the engine's own game version, currently GV24. `Glory <n>` is the version of
the Glory system's rules — deed prices, achievement tiers, and the mint
pipeline — currently Glory 12. The two numbers advance independently, and a
page's stats are guaranteed only for the exact pair stamped at its top, not
for "the current version" in general.

## Rules

### GV and Glory advance on separate schedules

A GV bump means the engine changed — anything from a hitbox to a tick-rate
constant. A Glory bump means the Glory system's own pricing rules changed —
a deed's base price, a heat threshold, an achievement tier's payout. Neither
number implies anything about the other: an engine release can ship with no
Glory change, and a Glory rebalance can ship with no engine change. A page
stamped `GV24 / Glory 12` was verified against exactly that pair; if either
number has since moved, the page is due for re-verification, not assumed
still correct.

### "Glory" names two different things, and that collision is real

**`Glory <n>` in a version stamp is not the same thing as Glory the
currency, and a reader deserves the warning.** The stamp's `Glory <n>` is a
*version number* for the ruleset that prices deeds and achievements. Glory
the *currency* is the per-team spectacle total that ruleset produces during
a match — see [[glory]]. Reading `Glory 12` in a stamp tells you nothing
about any team's Glory total; it tells you which ruleset priced that total.
The word is genuinely overloaded across the two uses, and this wiki does not
otherwise disambiguate it beyond context — read the surrounding sentence to
tell which sense is meant.

### A page can be honestly scoped to a version other than its own stamp

A page's stamp records what its author actually checked, not a promise that
every sentence on the page describes that exact version. A page may document
material scoped to an earlier or later version than its own stamp, as long
as it says so at the point of use — its own clearly-headed section, every
sentence inside naming the version it actually describes — rather than
leaving a reader to assume the page's stamp covers it. [[ffa]] is the worked
example: a mode that does not exist yet at this wiki's stamped engine
version is documented in full, under its own heading, honestly marked
throughout as describing a later version rather than the page's own.

**A later bump can turn that section into the page's present.** Once the
engine actually reaches the version an out-of-stamp section describes, that
section stops being a preview and becomes the page's current content —
re-stamp the page and work through the rest of the checklist in
[[conventions]].

## See also

- [[conventions]] — the version-stamp format this page explains
- [[glory]] — the Glory currency the stamp's version number is not
- [[ffa]] — the worked example of a page honestly scoped to a version other
  than its own stamp

## Discussion

Whether the wiki should stamp anything beyond GV and Glory belongs on
[the forum](https://softmax.com/paintbot/forum) rather than here.
