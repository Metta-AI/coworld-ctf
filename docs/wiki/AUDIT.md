# Wiki audit — Phase 2d (wiki-is-the-book)

Audited 2026-09-09 against the live wiki at `https://softmax.com/paintbot/wiki`
(fetched read-only via `GET /api/observatory/v2/wikis/paintbot/pages[/…]`,
40 pages, no writes made) and against source at `main` `9b6019aa`
(`paintbot-v0.7.367`+3, **GameVersion 61 / GLORYVERSION 16**).

## Headline finding

**Every page except four is still stamped `*Verified against [[versions|GV24 /
Glory 12]].*`** — the corpus was written once (2026-08-30) and never
re-dated. GV24 predates the entire Season 2 launch: the battle-royale rework,
the duo→solo conversion (2026-09-05), the variant-dependent hit-point split
(0.7.348), the multiplier-recut economy (Glory 13→16), and the level-buff
wiring (GLORYVERSION 16, 2026-09-08, this week). The one page that tracks
Season 2 economy changes (`glory-season-2`) is itself stamped GV52/Glory13 —
three GloryVersions behind. Confirmed via the wiki's own API, not inferred.

**There is no `battle-royale-s2` page, and no `battle-royale` page either** —
the second is referenced as `[[battle-royale]]` (an unwritten red link) from
**7 other pages** (`modes`, `glory`, `glory-season-2`, `deeds`, `achievements`,
`patch-notes`, `main`) and none of the 40 slugs is a deleted stub — it was
simply never written. `modes.md`'s own `## Gaps` section says so explicitly:
*"The full rules... of `battle-royale-s2`... still has no dedicated page."*
This is the exact gap the real stranger walk hit and had to route around by
reading replays instead (12 minutes lost).

## Deep-audited pages (read in full, traced against current source/manifest)

| Slug | Title | Last true era | Stale / wrong vs GameVersion 61 / GLORYVERSION 16 | Missing for a stranger |
| --- | --- | --- | --- | --- |
| `modes` | Modes | GV24/Glory12 | Says `battle-royale-s2` is "sixteen seats as eight two-policy **duo** teams" — the wiki's **own** `changelog-2026-09-05` entry documents the switch to sixteen **solo** teams, a self-contradiction. Also still headlines a "duo pairing" section that no longer applies. | The actual ruleset (map, zone, elimination) — flagged as its own gap already. |
| `glory-season-2` | Glory (Season 2) | GV52/Glory13 | Documents the win path as "restored `VICTORY` ×8 deed" after the 2026-09-04 `winAsMultiplier` rollback — but the live manifest (`battle-royale-s2` variant, verified 2026-09-09) has `winAsMultiplier: true` **again**, re-armed after that page's own snapshot. Under the live flag the win is a flat ×8/×4 factor (solo/duo), not the `VICTORY` deed, and `dTagBack`/`dJointAct`/the `dClosingTime` rung bump are live and unmentioned. Whole page still frames the ladder as duo (`TAG BACK` = "reviving a downed duo partner" — dead in 16-solo, no teammate to revive). | A current, dated statement of which flags are armed today; the pact-gating of `dJointAct` (GLORYVERSION 15 ruling). |
| `glory` | Glory | GV24/Glory12 | Its own "Battle royale runs a different Glory economy" section correctly punts to `glory-season-2`, so it inherits that page's staleness rather than adding new errors. | — |
| `damage-and-health` | Damage and health | GV24/Glory10 (but its BR sub-section is dated "since build 0.7.348") | **This page is current** — hit points per variant (classic 3 / `battle-royale-s2` 4 / free-play 4) and downed-state-live match the manifest exactly. Good model for what a fresh page should look like. | Nothing found stale. |
| `ranks` | Ranks | GV24/Glory12 | States "grenade charges is genuinely dead code" (rank 4-5 second throw never fires) and frames gun-range as the only *other* neutered buff. **As of GLORYVERSION 16 (commit `62fa0146`, 2026-09-08) this is wrong**: the engine now wires `levelGrenadeCharges` into `tryPickupGrenades`/`throwGrenade` — a rank-4+ pickup genuinely yields two throws. Verified: zero call sites for any of the six `levelX` accessors existed in `sim.nim` before that commit; all six (windup, max HP, fire cooldown, spray reset, grenade charges, carrier speed) are wired now. Only `levelGunRange` stays a permanent 100% no-op (confirmed still true). | A rewrite of the buff table's "dead code" framing — this is a real regression (wiki says weaker than truth), not a stale-in-the-safe-direction gap. |
| `achievements` | Achievements | GV24/Glory12 | Correctly notes the `battle-royale-s2` ladder reprices tiers as whole-number multipliers (still true) but frames everything else around classic mode; the 16-solo-specific facts (which trees are dead in solo, e.g. `treeShield`/`treeCarrier`/`treeDefender`) are absent. | Solo-BR-specific achievement reachability. |
| `deeds` | Deeds | GV24/Glory12 | Same mode-scoping gap as achievements — correctly flags that BR reprices via `glory-season-2` but doesn't say which deeds are structurally dead in 16-solo (`dDuoDown`, `dTagBack`, `dAssist`, `dRescue`, all flag deeds). | Solo-BR deed reachability. |
| `patch-notes` | Patch notes | GV24/Glory12 (append-only log, individually dated entries) | Entries stop at 0.7.334-ish (the duo→solo switch); nothing past that is recorded here even though `changelog-2026-09-07`/`-08` cover later builds — the two logs have diverged into separate, non-cross-linked timelines. | A merge or explicit hand-off between `patch-notes` and the dated `changelog-*` pages. |
| `submitting-a-policy` | Submitting a policy | GV24/Glory12 | Explicitly refuses to document the platform push step ("not exercised or verified... see `## Gaps`"). **This is the second stranger-walk pain point** — the CLI's `upload-policy`/`submit` commands exist, have stable `--help` output, and were exercised end-to-end by the real stranger run; none of that made it back into this page. | The whole "build → run locally → upload → submit" path with real commands (this task's `build-and-submit.md` fills it). |
| `policies` | Policies | GV24/Glory12 | Core claims (Docker image + run argv, no version handshake, `COWORLD_PLAYER_WS_URL`) re-checked against `policies.md`'s own text and found structurally still accurate; not contradicted by anything found this pass. Era stamp itself is unconfirmed at GV61. | — |
| `main` | Paintbot (portal) | GV24/Glory12 | Says Battle Royare is "now the *only*" scheduled mode — still true — but inherits the same duo-framing risk via its links to `modes`/`battle-royale`. | — |
| `league` | League | GV24/Glory12 | Documents the CTF→(Season2 + Campaign) league split; not contradicted this pass. | — |
| `round` | Round | GV24/Glory12 | `battle-royale-s2` row correctly says "no fixed count... at least 12 episodes per entrant"; not contradicted. | — |

## Remaining 27 pages — not deep-audited this pass

All carry the identical `*Verified against [[versions|GV24 / Glory 12]].*`
stamp (checked via API fetch + grep, not individually re-traced to source this
pass): `action-mask`, `arena`, `baseline-policy`, `capture-the-flag`,
`champion`, `combat`, `conventions`, `division`, `elo`, `episode`, `ffa`,
`labels`, `med-kit`, `movement`, `paint-bomb`, `perception`, `scoring`,
`shield`, `shouts`, `spray-can`, `versions`, `wire`, plus the changelog family
(`changelog`, `changelog-2026-09-04`, `-05`, `-07`, `-08`, each individually
dated and not stale by definition — they're point-in-time logs). Most of
these describe classic/CTF-era mechanics (movement, action mask, wire
protocol, shield, spray can) that are less likely to have moved under
Season 2, but the GV24 stamp means **any correction made between GV24 and
GV61 could be silently missing** — same failure class as `ranks.md`. **Open
risk, flagged for the lead rather than guessed at:** a full re-trace of these
27 against GV61 source is the natural next audit pass; not attempted here
given this task's scope (battle-royale-s2 + build/submit).

## A defect adjacent to the wiki, not in it

The platform's own canonical game description for the `Paintbot` game
(`coworld leagues` → `game.description`, live-fetched 2026-09-09) still reads
*"Season 2 plays battle royale: **sixteen duos**... last team standing"* —
the same duo/solo staleness as `modes.md`, but on the platform side, not the
wiki. Not this task's fix (out of scope — game metadata, not wiki content)
but worth flagging to whoever owns it.
