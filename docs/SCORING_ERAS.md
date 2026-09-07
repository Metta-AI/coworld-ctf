# Season 2 scoring eras

Paintbot (Season 2) has changed how a round score is computed **ten times**
since 2026-09-02 — seven inside the verified window the era table below covers
(through r4208), and three more that merged after it — the GV58 friendly-fire
change (#384) and the winAsMultiplier arming (#436) both went live at r4257
(build 0.7.344), while the GV57 recut's (#435) first-served round is still
pending — all documented below. Every change was silent: no announcement, no version flag on
the round, and two of the first seven did not move a build number either. A
standings or Glory number that spans two of these eras is not a result — it is
an artifact of where its window happened to start.

**The rule this page exists to state: stamp every scoring claim with a round
range and the canonical build, not with a wall-clock time.** Rounds do not
switch builds on a clean hour, two boundaries below are pure scorer-side config
that no build number records at all, and two rounds sat on the older build after
their change had already merged.

Scope: league `Paintbot (Season 2)`, division `Competition`
(`div_aa7825db-262f-4a62-b01a-177c1b48f7ee`). Round numbers are that division's
`round_number`; times are each round's `completed_at` in UTC. Everything below
was read from `/v2/rounds/{id}` (`result_metadata`) and `/v2/rounds/{id}/episodes`
(`coworld_version`) — see [Reproducing this table](#reproducing-this-table).

Verified through **r4208** (2026-09-06T18:57:21Z), the latest completed round at
the time of writing. Three further scoring-era boundaries (PRs #435, #384, #436)
merged after r4208 and are documented in [The boundaries, one at a
time](#the-boundaries-one-at-a-time); #384 and #436 went live together at r4257
(build 0.7.344), while #435's first-served round is still pending. They are not
yet folded into the era table above.

## The eras

| Era | Rounds | A round score is | First round completed | Builds |
| --- | --- | --- | --- | --- |
| A | …–r3709 | the **mean** of the entrant's episode scores | — | …–0.7.293 |
| B | r3710–r3777 | the entrant's **single best** episode | 2026-09-02T18:27:21Z | 0.7.294–0.7.307 |
| C | r3778–r3788 | the **sum** of every episode the entrant banked | 2026-09-03T05:51:14Z | 0.7.307 |
| D | r3789–r3829 | sum; a `sum_top_k = 12` guard is armed but never trims | 2026-09-03T07:42:05Z | 0.7.307–0.7.309 |
| E | r3830–r3842 | same rule, **multiplier-recut** Glory economy | 2026-09-03T19:53:53Z | 0.7.310–0.7.313 |
| F | r3843–r3848 | same, plus **exchange / `giveItem`** armed | 2026-09-03T22:03:32Z | 0.7.314–0.7.316 |
| G | r3849–r3999 | the sum of the entrant's **top 12 episodes only** — the guard trims real score in *every* round | 2026-09-03T23:02:03Z | 0.7.317–0.7.330 |
| H | r4003–present | sum of all 12 episodes; the guard is armed and sitting exactly on its threshold | 2026-09-05T08:44:51Z | 0.7.334– |

r4000, r4001 and r4002 produced no results at all — see [Rounds that carry no
result](#rounds-that-carry-no-result).

**The magnitudes are not comparable across any two rows.** Rank-1 round score,
as actually served today: r3709 = `47.25`; r3777 = `199`; r3788 = `306`;
r3830 = `42,560`; r3848 = `664,560`; r3938 = `4,518,872,667,779`;
r4208 = `5,744`. That is a span of about **10¹¹ inside one season**, and none of
it is a strength signal.

## The boundaries, one at a time

### r3710 — mean → max

`result_metadata.scoring_rule` flips `"mean"` → `"max"` between r3709
(2026-09-02T18:16:04Z, build 0.7.293) and r3710 (2026-09-02T18:27:21Z, build
0.7.294). A build hop lands on the same round; the two are not known to be the
same change, and `scoring_rule` is scorer-side config that can move without any
build at all.

*What a cross-boundary read gets wrong:* a mean is divided by the entrant's
episode count and a max is not, so era-A scores are roughly an order of
magnitude smaller. Rank-1 ran `26`–`63` in era A and `152`–`375` in era B, with
no change in how well anyone played.

### r3778 — max → sum

`scoring_rule` flips `"max"` → `"sum"` between r3777 (2026-09-03T05:40:51Z) and
r3778 (2026-09-03T05:51:14Z). **Both rounds ran on the same build, 0.7.307**
(`cow_0f19f5c7-b667-4cfc-b15d-a29ce78af58f`). Nothing in the build number,
`GameVersion`, or any replay header marks this boundary.

*What a cross-boundary read gets wrong:* summing every episode instead of taking
the best one inflates the round score by roughly the number of episodes an
entrant scores in. Measured on rank-1 round score over the windows either side:
mean `221.1` across r3760–r3777 (n=18) versus `427.4` across r3778–r3788 (n=11)
— **1.93×**, and it also changes *who* is rank 1, because sum rewards
consistency where max rewarded a single spike.

### r3789 — the `sum_top_k = 12` guard is armed

A new key, `sum_top_k: 12`, appears in `result_metadata` at r3789
(2026-09-03T07:42:05Z), two hours after the max→sum flip and **again on the same
build, 0.7.307**. This is a separate event from the aggregation flip, not the
same change arriving late.

Note the shape carefully: `scoring_rule` stays `"sum"` on both sides. The guard
is not a new rule name — it is an extra key next to the old one. Any check that
watches `scoring_rule` alone misses this boundary entirely.

*What a cross-boundary read gets wrong:* nothing yet — see
[The k=12 guard](#the-k12-guard-armed-since-r3789-inert-today).

### r3830 — the multiplier recut

Between r3829 (build 0.7.309, `cow_e11b7e6a-…`) and r3830 (build **0.7.310**,
`cow_efc92fee-18b8-44ff-8c27-4f68d276a138`). Rank-1 round score goes `338` →
`42,560` in one round: a **126×** step with no policy change behind it.

`result_metadata` is **byte-identical in shape** across this pair — same keys,
same `scoring_rule: "sum"`, same `sum_top_k: 12`. The only in-band marker is
`coworld_version` on the round's episodes.

r3828 and r3829 ran pre-arm on 0.7.309 after the recut had already merged
(0.7.309 is commit `9fc78300`, "glory-multiplier-recut"). That is a
credit-bridge resume, not a rollback — **the code being merged is not the era
boundary; the first round that ran armed is.**

### r3843 — exchange / `giveItem` armed

Between r3842 (build 0.7.313, `cow_a124b619-…`) and r3843 (build **0.7.314**,
`cow_12b2eb90-5d54-4570-bdc8-ee40a6e9d420`, commit `9a3f9194`, PR #387
"arm-exchange"). As with the recut, `result_metadata` does not change shape;
only `coworld_version` moves.

### r3849 — the win gate is removed, and the guard starts biting

Between r3848 (build 0.7.316) and r3849 (build **0.7.317**,
`cow_dc4876d3-4a9f-403a-89f5-e3e8f306a6ee`). The behaviour comes from commit
`21c672b9` (PR #386, "glory-nonwinner-report"), which is an ancestor of 0.7.317
and **not** of 0.7.316 — so 0.7.317 is the first build that could carry it, and
r3849 is the first round that did.

The observable is unambiguous. Counting the episodes in which each policy banked
a non-zero score:

```
r3847  0.7.316  23 eps/policy   non-zero eps/policy: min 0  max 7   median 2
r3848  0.7.316  23 eps/policy   non-zero eps/policy: min 0  max 6   median 3
r3849  0.7.317  23 eps/policy   non-zero eps/policy: min 23 max 23  median 23
r3850  0.7.317  23 eps/policy   non-zero eps/policy: min 23 max 23  median 23
```

Every seat now banks in every episode instead of only the winners. **That is
what makes the k=12 guard start discarding score**: the win-gate removal is the
cause and the trim is its immediate effect, in this same round. Neither is
recorded anywhere on the round, and the guard had by then been sitting armed and
harmless for 60 rounds.

### r3999 → r4003 — PKG-A flags-off

PR #420 (commit `040f1451`, "manifest(s2): flags-off — restore pre-loot-economy
defaults on battle-royale-s2") merged 2026-09-05T02:47:37Z, turning `loot-start`,
`downedMode` and `giveItem` back off on `battle-royale-s2`.

The boundary is not one round pair, and the merge time is not the boundary:

- **r3999** (2026-09-05T01:47:10Z, build 0.7.330) is the last **scored** round
  before the rollback. 0.7.330 does **not** contain `040f1451`.
- **r4000, r4001, r4002** dispatched on build **0.7.333** — the first build that
  does contain `040f1451` — and all three **failed** with
  `0/12 planned slots produced attributable scoring evidence`. They have no
  `results` rows and cannot be compared to anything.
- **r4003** (2026-09-05T08:44:51Z, build **0.7.334**,
  `cow_41bcdd59-b066-436b-a96b-c0d77725ecab`, commit `3eed397f`) is the first
  **scored** post-rollback round, nearly seven hours after the merge.

Episodes per policy per round drop from 23 to exactly 12 across the same
boundary, which is a second, independent reason not to compare a round score
across it.

*Behavioural evidence for the loot-economy rollback itself* (zero downed events
and zero gun/hopper pickups in 156/156 sampled post-boundary episodes; zone-death
share 21.5% post versus 53.4% over r3960–r3999) was measured separately and is
recorded on the filing task, not re-derived here. `/v2/rounds` history reaches
back past every boundary on this page, so the earlier concern that the
loot-start window would age out of the API does not apply — see
[Reproducing this table](#reproducing-this-table).

### Checked and *not* an era boundary: the winAsMultiplier rollback (r3953)

Commit `d595f300` (PR #401, "winAsMultiplier OFF on battle-royale-s2") ships in
build 0.7.322, first served at r3953. It is a real Glory-economy config change,
so it is listed here — but it does **not** move round-score magnitude in a way a
standings read can detect. Median rank-1 round score is `324,436` over
r3930–r3952 and `430,390` over r3953–r3975 (both excluding the excluded rounds
below): a ratio of 0.8×, inside the era's own round-to-round noise, which spans
`19,014` to `19,950,982`. Treat r3953 as a build boundary to *name* when quoting
a window, not as an era split.

### The GV57 glory recut (#435)

Commit `82e4f547` (PR #435, "glory(s2): solo recut + alliance keying + heat
retune [GV57]", `softmaxwell`) merged **2026-09-07T02:03:46Z** and bumps
`GameVersion` **56 → 57** — a glory-economy recut (solo-seat scoring recut,
alliance keying, heat retune). It changes how per-episode score is earned, and
replay hashes move with the `GameVersion` bump.

Its headline lever shipped **dark**: per the arming commit (#436, below), GV57's
Part A — the placement ladder (`dFinal` 8/4/2, ×24 cumulative) and the
team-size-keyed win factor `M` — was
gated behind `winAsMultiplier`, off since the 2026-09-04 rollback (incident
`d595f300`). So the GV57 code boundary and the round its win factor starts
scoring are different events; the win factor went live only at **r4257** with
#436 (below).

*What a cross-boundary read gets wrong:* the merge is not the era boundary — the
first production round on the GV57 build is. **TODO (orchestrator):** pin the
first `coworld_version`/round carrying `82e4f547` from a live `/v2/coworlds`
read-back (it is after r4208); whether the non-gated recut/heat-retune parts
reached an earlier build than 0.7.344 is not yet established, but the win factor
itself first scored at r4257.

### The GV58 friendly-fire pricing change (#384)

Commit `1f63673a` (PR #384, "sim: price friendly-fire at the DOWN, not the
finalize (Amendment 5)", `softmaxwell`) merged **2026-09-07T03:17:32Z** and
bumps `GameVersion` **57 → 58**. It prices friendly-fire at the down rather than
at finalize — a scoring-behaviour change, so per-episode scores **and replay
hashes both change** across it; any replay compared or re-verified across the
GV57/GV58 line mismatches by design.

It reached the live field in canonical build **0.7.344**, first served at
**r4257** (see #436) — **not** at the merge. Build 0.7.344 also carries the
winAsMultiplier arming, so on the live field the GV58 friendly-fire price and the
team-size-keyed win factor (solo ×8) arrived **together** at r4257, even though
they were separate merges an hour apart.

*What a cross-boundary read gets wrong:* a standings or Glory window spanning
r4257 pools episode scores computed under two different friendly-fire prices —
and, because the win factor arms in the same build, also across the win-factor
magnitude step (×8 on the all-solo field). Neither effect is a strength signal.

### winAsMultiplier armed — the GV57 win factor goes live (#436)

Commit `2b66cec4` (PR #436, "manifest(s2): arm winAsMultiplier — the GV57 recut
goes live [flag-flip]", `softmaxwell`) merged **2026-09-07T03:37:41Z**. It is a
**one-line manifest flip** — `winAsMultiplier: false → true` in
`coworld_manifest_paintbot.json` — with **no code change and no `GameVersion`
bump** (stays 58). This is the boundary the r3830 / r3843 pattern warns about:
pure scorer/economy config, invisible in `GameVersion` and in `result_metadata`
shape. Arming it turns on GV57's Part A live: a composition-neutral placement
ladder (`dFinal` 8/4/2, **×24** cumulative) that folds first, then a
**team-size-keyed win factor `M`** on winner round score — **solo ×8, duo ×4**.
The live `battle-royale-s2` field is 100% solo (16 one-seat teams per episode,
zero duos), so the live win factor is **×8**. The armed product is capped at
**16,777,216 (2^24)**.

**The production boundary is r4257 / build 0.7.344, not the merge.** The
canonical build carrying this flip (0.7.344) did not deploy until
**2026-09-07T03:50Z**; the first round completed with the flag armed is **r4257**
(`completed_at` 2026-09-07T04:01:47Z), and it is still armed at r4326. Merge date
≠ live date: #436 merged on the 2026-09-06 (PT) calendar day but reached
production on 2026-09-07 (UTC) — dating this boundary from the merge, or from the
PT day, misplaces it across the day line and ahead of its real deploy. Build
0.7.344 carries #384 as well, so the GV58 friendly-fire price and the
team-size-keyed win factor share this one live boundary.

*What a cross-boundary read gets wrong:* the win factor multiplies winner round
score (solo ×8 on today's all-solo field, after the ×24 placement ladder), so
magnitudes jump across r4257 with no strength change — exactly
the artifact this page exists to stop. The arming is recorded **nowhere on the
round**: not in `result_metadata`, not in any per-round ruleset flag. The only
way to date it is `coworld_version` on the round's episodes, resolved to a commit
via `GET /v2/coworlds` (`manifest.game.runnable.source_url` → arming commit
`2b66cec4`). Stamp any post-r4257 claim with `coworld_version`, never a
wall-clock time.

## The k=12 guard, armed since r3789, inert today

`sum_top_k: 12` means a round score is the sum of the entrant's **twelve
best** episodes, and the rest are dropped. Its history has three phases:

**r3789–r3848 — armed, never bit.** Rounds ran 20–23 episodes per policy, but
the win gate meant almost all of them scored zero: across all 58 completed
rounds in this range, the most episodes any policy banked non-zero in was **8**.
Sorting descending and keeping 12 therefore discarded only zeros. Confirmed by
full score reconstruction on r3848: reported score equals both sum-of-all and
sum-of-top-12 for all 15 rows.

**r3849–r3999 — armed and biting, in every single round.** The moment every
seat began banking in every episode, 20–23 non-zero episodes per policy met a
12-episode cap. **All 145 completed rounds in this range are trimmed** — not a
sample, the whole range. Full score reconstruction on two of them: at r3849 the
reported score matches sum-of-top-12 and not sum-of-all for 15 rows out of 15;
at r3960, 14 out of 14, with 21 episodes played per policy and 9 discarded from
every entrant. **This is a standings-affected era of its own, 145 scored rounds
long, and nothing on the round says so.**

**r4003–r4208 — armed, inert, with zero headroom.** Every round since the PKG-A
boundary has run **exactly 12** episodes per policy, so the guard has nothing to
trim: none of the 205 completed rounds in r4003–r4208 discards anything.
Confirmed by full score reconstruction on r4003 and r4208 — reported score
equals sum-of-all for every row.

### The condition that makes it bite

**The guard bites the moment any policy banks a non-zero score in more than 12
episodes in one round.** Either of two conditions keeps it inert, and only one
of them is currently doing any work:

1. **Episodes scheduled per policy per round stay at or below 12.** This is the
   condition currently holding — and it is holding at exactly 12, which is
   **zero headroom**. Any increase in round composition trips the guard in the
   very next round.
2. **Or scoring stays sparse enough** that no policy banks in more than 12
   episodes. This held through r3848 and is *not* true today: since r3849 every
   seat banks in every episode, so it provides no margin at all.

The r3849 breach happened because an unrelated change (removing the win gate)
altered condition 2 while nobody was watching condition 1. The same class of
change — another economy edit, an entrant-count change, a scheduling tweak —
recurs silently. There is no log line, no era flag, and no alert when it does;
the only detection is reconstructing round scores from raw episode scores.

`sum_top_k` is a scoring-time trim sitting downstream of an unbounded
episode-scheduling process. It is not doing cap duty on purpose, and it has
already proven it fails silently when tripped.

### Where these settings actually live

`GET /v2/leagues/{id}/settings` (with `X-Use-Elevated-Privileges: true`) is the
authoritative source, and it makes the shape of the problem explicit. As served
on 2026-09-06:

```json
"ranking": {
  "algorithm": "score",
  "round_scoring_rule": "sum",
  "sum_top_k": 12,
  "standing_aggregation": "rated",
  "rated_k": 0.05,
  "direction": "maximize"
},
"scheduler": {
  "strategy": "team_n",
  "team_count": 16,
  "min_episodes_per_entrant": 12,
  "episodes_per_entrant": null,
  "episodes_per_round": null,
  "variant_rotation": ["battle-royale-s2"]
}
```

**`12` is a scheduler *minimum*, not a maximum.** `min_episodes_per_entrant` is
12 and both `episodes_per_entrant` and `episodes_per_round` are `null` — there
is no ceiling anywhere on the scheduling side. The field sits at exactly 12
today because 12 is the floor it is being held to, not because anything stops it
going higher; it ran 20–23 for most of eras D through G. `sum_top_k = 12` then
trims whatever the scheduler produced above that number, silently. The guard and
the floor are the same number, which is exactly why there is no headroom.

A real cap belongs on the scheduling side, at the value the league intends, with
`sum_top_k` kept only as a backstop. Until then, **read this section together
with a live settings fetch** — every value above is live config that can change
between two rounds with no build bump and no record on the round.

## What `result_metadata` can and cannot tell you

`result_metadata` on a round result row carries `wins`, `scoring_rule`,
`episodes_scored`, `completed_episode_count`, and — since r3789 — `sum_top_k`.

**It does tell you** the aggregation rule (`scoring_rule`) and whether the top-k
guard is armed (`sum_top_k` present).

**It does not tell you** whether the guard actually trimmed anything.
`episodes_scored` is not a count of episodes that survived scoring — it echoes
`completed_episode_count`, and it has never once been observed below it,
including in rounds independently proven to be trimmed. r3849 reports
`episodes_scored: 23` on rows whose reported score is the sum of 12 episodes.

**It does not tell you** the Glory economy in force. The r3830 multiplier recut
and the r3843 exchange arming both leave `result_metadata` unchanged in shape
and value. Only `coworld_version`, read from the round's episodes, distinguishes
them.

So the minimum stamp on any scoring claim is **round range + `coworld_version`**,
and if the claim depends on the top-k guard, an arithmetic check against raw
per-episode scores as well.

## Rounds that carry no result

Some rounds complete with no `results` rows and must be dropped from any window
rather than counted as zeros. In r3789–r4208 these are r3836, r3845, r3876,
r3879, r3908, r3966, r3979, r3997, **r4000, r4001, r4002** and r4116 — twelve
rounds out of 420, all `status: failed`.

Separately, eleven rounds in era G are reported **excluded from the recomputed
standings** (recorded on the Season 2 epic; the exclusion itself is not
re-derived here) but are *still served with their inflated magnitudes* by
`/v2/rounds/{id}` and `/v2/rounds/{id}/episodes`: r3885, r3894, r3897, r3900,
r3901, r3904, r3917, r3920, r3921, r3936, r3938. Spot-checked here: r3885 rank-1
= `47,071,632,263`, r3900 = `4,184,142,541,546`, r3938 = `4,518,872,667,779`.
Any tool that reads round results directly — superlatives, jackpot backfills,
analytics — has to exclude that list by hand.

## The leaderboard pools every era

`GET /v2/divisions/{div}/leaderboard` returns one accumulated standing per
entrant with `rounds_played` running as high as 567 — a single number spanning
all eight eras above.

The standing is not a sum of round scores. `ranking.standing_aggregation` is
`"rated"` with `rated_k` `0.05`: a live-decaying weighted average over the
entrant's round scores. That makes the pooling worse rather than better, because
the round scores being averaged differ by about **10¹¹** between eras — a single
era-G round in the trillions does not average against an era-H round in the
thousands, it drowns it.

The standing aggregation is itself an era boundary: it was `"max"` (an entrant's
single best round, ever) before changing to `"rated"` at round 3856, with the
full round history replayed through the new formula. That change is recorded on
the league's own patch notes; the settings endpoint serves only the current
value, so unlike everything else on this page it is **not** independently
re-derived here.

The leaderboard is not wrong. It is just not an era-scoped result, and it cannot
be quoted as evidence that anything changed for the better between two rounds.
For that, compare inside one era.

## Reproducing this table

Run with the player venv that holds the working login.

```sh
PY=~/projects/coworld-players/coworld-cogherence-player/.venv/bin/python
```

`/v2/rounds` is keyed by round **id**, not round number, so numbers have to be
mapped first. `offset` is silently ignored; `next_cursor` works as a `cursor=`
parameter, **but only URL-encoded** — the `+` in its timestamp otherwise decodes
as a space and the request 422s:

```python
from urllib.parse import quote
import ctfapi                      # tools/ladder/ctfapi.py

DIV = "div_aa7825db-262f-4a62-b01a-177c1b48f7ee"
cursor, index = None, {}
while True:
    path = f"/v2/rounds?division_id={DIV}&limit=100"
    if cursor:
        path += f"&cursor={quote(cursor, safe='')}"
    page = ctfapi.get(path)
    for e in page["entries"]:
        index[e["round_number"]] = e["id"]
    cursor = page.get("next_cursor")
    if not cursor:
        break
```

Paged this way the division's history reaches back to at least **r109**, so
every boundary on this page is re-derivable at any time.

Then, per round:

```python
detail = ctfapi.round_detail(index[3778])          # result_metadata, scores, ranks
eps    = ctfapi.episodes(index[3778])              # coworld_version = canonical build
```

To decide whether the top-k guard trimmed a round, group `episode["scores"]` by
`policy_version_id`, sort descending, and compare the reported round score
against both the full sum and the sum of the first twelve. Matching top-12 while
missing sum-of-all is the trim.

Sweeping hundreds of rounds does not need the full reconstruction. The trim can
discard real score **if and only if** some policy banked a non-zero score in more
than twelve episodes, so counting non-zero episodes per policy is both sound and
complete as a screen, and costs one `/episodes` call per round. The whole-range
claims above were established that way over r3789–r4208 (420 rounds), with full
reconstruction run on the boundary rounds r3848, r3849, r3960, r4003 and r4208.

The scoring settings themselves are one authenticated read — token from
`~/.softmax/credentials.yaml` under `tokens['https://softmax.com/api']`, and use
`curl`, not python `urllib`, which is blocked at the edge:

```sh
curl -s -H "Authorization: Bearer $TOK" -H "X-Use-Elevated-Privileges: true" \
  "https://softmax.com/api/observatory/v2/leagues/$LEAGUE/settings"
```

To resolve a build to a commit, `GET /v2/coworlds` carries
`manifest.game.runnable.source_url`. Its `canonical: true` flag marks the
**current** build only — the canonical build a past round ran is the
`coworld_version` on that round's own episodes, never this flag.

## See also

- `AGENTS.md`, "Operating the prod league" — league settings, fillers, elevation.
- `tools/ladder/ctfapi.py` — the API helper every snippet above uses.
