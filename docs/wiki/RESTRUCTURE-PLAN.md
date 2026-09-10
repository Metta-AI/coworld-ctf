# Restructure plan — the wiki as the book

Chapter order follows the stranger's own question ladder (owner ruling;
internal tracking, not public): what is
this → how it works → the S2 battle-royale rules → glory/scoring as the
player sees it → build your brain → run an episode locally → submit → read
the ladder. Existing pages are reassigned to that ladder below; nothing here
renames a slug (nav/search weight the title, not the position in a list).

| # | Chapter | Pages (existing unless marked NEW) | Action |
| --- | --- | --- | --- |
| 1 | What is this | `main` | Keep. Light lead-paragraph refresh so it opens with genre/format/objective, mirroring the door page (another lane's task) rather than duplicating this plan. |
| 2 | How it works (the loop) | `main`, `episode`, `modes` (taxonomy only) | Keep as-is. `modes` supplies "which ruleset runs" without re-explaining any one ruleset's mechanics. |
| 3 | The S2 battle-royale rules | **NEW `battle-royale-s2`**, `modes` | `modes` DELETES its `### battle-royale-s2 duo pairing` and `### Ground items on battle-royale-s2` sections (both stale/wrong — see AUDIT.md) and trims its `battle-royale-s2` table row to point at the new page instead of the `[[battle-royale]]` red link. |
| 4 | Glory/scoring as the player sees it | `glory-season-2`, `deeds`, `achievements`, `glory` | `glory-season-2` needs a full re-verification pass (out of this task's scope — flagged below). `deeds`/`achievements` get a one-line pointer each to which rows are structurally dead in 16-solo BR. `glory` is unchanged, already correctly defers BR to `glory-season-2`. |
| 5 | Build your brain | `policies`, `baseline-policy`, `action-mask`, `perception`, `submitting-a-policy` (protocol half only) | `submitting-a-policy` SPLITS: keep §1–3 (protocol, Docker packaging, the socket handshake) here; delete its `### Platform-side push (not exercised or verified)` section and the two Gaps bullets it owns. |
| 6 | Run an episode locally | **NEW `build-and-submit`** (§1–2b) | New. Absorbs `submitting-a-policy`'s short "Local dev equivalent" note by cross-reference rather than duplicating it. |
| 7 | Submit | **NEW `build-and-submit`** (§3–5) | New. This is where `submitting-a-policy`'s deleted platform-push section's *intent* lands, now verified instead of gapped. |
| 8 | Read the ladder | `round`, `elo`, `league`, `champion` | Unchanged this pass. |

## Merges

- `modes`'s battle-royale-s2 taxonomy row **merges by reference** into the
  new `battle-royale-s2` page — `modes` stops trying to also be the ruleset
  page and just links to it, matching how it already treats `capture-the-flag`
  and `ffa`.
- `submitting-a-policy`'s "Local dev equivalent" paragraph (building/running
  locally without the platform) stays conceptually part of the same idea as
  `build-and-submit`'s §1–2 but is not restated — one `[[build-and-submit]]`
  link replaces it.

## Splits

- `submitting-a-policy` → protocol/packaging (stays) + platform push (moves
  to `build-and-submit`, now with real verified commands instead of a Gap).

## Deletions

- **`modes`**: the two stale battle-royale-s2 sections named above (their
  content is wrong — duo pairing no longer exists — not merely outdated
  phrasing).
- **`submitting-a-policy`**: the "Platform-side push (not exercised or
  verified)" section and its two Gaps bullets, once `build-and-submit` is
  live — add a `## Version history` row noting the split rather than
  silently dropping the fact that this was once undocumented.
- **The `[[battle-royale]]` red link itself**: repoint every occurrence
  (7 pages: `modes`, `glory`, `glory-season-2`, `deeds`, `achievements`,
  `patch-notes`, `main`) to `[[battle-royale-s2|battle royale]]`. Do **not**
  create a separate thin `battle-royale` stub page — `main` already states
  Battle Royale is the *only* live mode, so a second page for the bare word
  would only recreate the exact "nine writers linked to the wrong page
  because of a colloquial name" failure this wiki has already paid for once
  (see `conventions.md`'s own `glory`/ranks hatnote story). One page, one
  aliased link text, everywhere.

## Left for a follow-up pass (not in this task's scope)

- **`glory-season-2` full re-verification.** It currently documents the
  `winAsMultiplier` flag as rolled back to the `VICTORY` ×8 deed
  (2026-09-04 state); the flag is armed again on the currently published
  configuration (verified this task). This flag has now flipped three times
  live — arm, incident, rollback, re-arm — so the next editor should treat
  "armed today" as a live-service fact to re-check at write time, the same
  caution `battle-royale-s2.md` now states for the zone schedule.
- **The 27 pages still stamped GV24/Glory12** that this task did not
  deep-audit (see AUDIT.md) — a full re-trace against GV61 is the natural
  next pass.
- Solo-BR achievement/deed reachability detail on `achievements`/`deeds`.
