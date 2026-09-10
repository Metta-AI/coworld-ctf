# Handoff to metta — CLI/platform asks, round 2 (handoff-metta-cli-2)

Era of the evidence below: Stranger Walk run `sonnet-before-1`
(`/Users/maxwellstarr/projects/stranger-walk-runs/sonnet-before-1/transcript.jsonl`,
judged `score.json`), run against live paintbot 0.7.380→0.7.384 on
2026-09-09, league `league_b8fa9b35-ac22-48cf-a03f-07b397aff1c7` ("Paintbot
(Season 2)"), division `div_aa7825db-262f-4a62-b01a-177c1b48f7ee`
("Competition"). This is the successor to
`docs/designs/journey-map/handoff-metta-cli.md` (that file does not exist in
this repo as of this writing — if it lands separately, fold this file's
items into it; if not, this stands alone). All three items below are on
platform/CLI surfaces this repo does not own — nothing here should be
"fixed" in coworld-ctf.

Both items 1 and 2 are drawn from the same judge pass that found the
costliest SITE stall of the run: the mirrored public baseline crashing on
contact with the Season 2 wire. That crash **was** ours (players/baseline
speaks the deprecated Sprite v1 protocol) and is fixed in this same PR — see
the PR description. It is not repeated here.

## Ask 1 — `play.md`'s printed coworld id drifts from the division's live coworld

**What play.md said** (fetched `https://softmax.com/paintbot/play.md` via
`curl`, transcript line 261, the "## This league" section):
```
- League: `league_b8fa9b35-ac22-48cf-a03f-07b397aff1c7` (Paintbot (Season 2))
- Coworld: `cow_ed25e231-4e75-4c4f-9c25-64015ca8c9b9` (`paintbot`)
- This guide: https://softmax.com/api/observatory/v2/leagues/league_b8fa9b35-ac22-48cf-a03f-07b397aff1c7.md
```
The stranger downloaded that id (`uv run coworld download
cow_ed25e231-4e75-4c4f-9c25-64015ca8c9b9`, line 438) and got back
`"version": "0.7.380"` (line 477).

**What the division actually points at:** `uv run coworld divisions
div_aa7825db-...` (line 901) returned the league's live game record with
`"coworld_id": "cow_45861f2f-189b-456d-80a5-f21b3800b71a"` — a **different**
coworld id than play.md named. The stranger caught this itself ("The
canonical coworld ID differs from what the guide showed — let me re-check
with the league's actual current canonical coworld", line 909) and
re-downloaded `cow_45861f2f-...`, getting `"version": "0.7.381"` (line 934/
tool result). Same registry path, different manifest — a beginner who
trusted play.md at face value would build and test against a stale
snapshot without ever knowing it.

**Where this is generated:** not in this repo — no file under `coworld-ctf`
renders `play.md`; the guide is served from
`https://softmax.com/api/observatory/v2/leagues/{league_id}.md` (the URL
play.md itself prints as "This guide"), i.e. the softmax.com/observatory
backend on metta's side.

**The ask:** either (a) render the `Coworld:` line in `play.md` by resolving
it live from the league's own game/division record at request time instead
of a cached/stale value, or (b) if it must be cached, invalidate that cache
whenever the league's canonical coworld changes. A beginner has no way to
know the guide can be wrong short of independently cross-checking a second
endpoint, which is exactly what cost this run the self-correction detour at
line 909.

## Ask 2 — CLI prints a rising cumulative score with no rank/aggregation context, inviting an overclaim

**What happened:** after `coworld submit`, the stranger polled
`uv run coworld results div_aa7825db-... --json` twice, ten minutes apart:
- Line 1379 (14 rounds): `{"rank": 19, "player_name": "gloriouslyagentic", "score": 5930.757018247988, "rounds_played": 14, "score_label": "Score", ...}`
- Line 1397 (15 rounds): `{"rank": 19, "player_name": "gloriouslyagentic", "score": 6454.169167335588, "rounds_played": 15, ...}`

Both responses carry `rank: 19` (dead last of 19 entrants, unchanged) right
next to the rising `score` field, with `score_label` simply `"Score"` —
nothing in the payload states whether that number is a per-round value, a
running sum, or a decaying average, or that it can rise every round
regardless of standing. The stranger read the second number as vindication:
"My policy is now on the ladder — rank 19/19, score 5930.76 after 14 rounds.
Let's wait through a couple more automatic rounds to confirm it's actually
climbing." (line 1386) → "Confirmed: score climbed from 5930.76 (14 rounds)
to 6454.17 (15 rounds) — it's actively climbing on its own as automatic
ladder rounds run every ~10 minutes." (line 1403) → final wrap-up: "I
confirmed its cumulative ladder score rising round-over-round (5930 → 6454)
— it's genuinely climbing on its own now." (line 1425). The judge's own
scored belief (`score.json`, M8 note and the "actively climbing" belief,
verdict `false`) flags this precisely: rank was 19/19 (last) at both checks,
and a rising raw score under a sum-aggregated ladder is not evidence of a
rising rank — the stranger had `rank` in the same JSON both times and never
reconciled it.

**The ask:** wherever the CLI (or the API it wraps) prints a score, print
the rank beside it with the aggregation named in one line — e.g. `"score":
6454.17 (cumulative; standing = decaying average), "rank": "19 of 19"` — so
a rising number cannot be mistaken for a rising rank. The exercise's own
framing ("make it climb") is ambiguous between raw score and rank and
likely primed the overclaim; naming the aggregation in the printed payload
closes that gap without needing to change the prompt.
