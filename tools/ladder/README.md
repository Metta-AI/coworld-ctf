# Ladder assessment tools

Judge a submitted policy on the LIVE Elo ladder. Run everything with the
cogherence player's venv, which holds the working login:

```sh
PY=~/projects/coworld-players/coworld-cogherence-player/.venv/bin/python
cd tools/ladder
```

| script | question it answers |
|---|---|
| `scout.py` | ⭐ **Fast loop.** Measure a policy against the real field from free public replays — per-opponent ground truth, plus who is SHIPPING. Start here; see below. |
| `standing.py` | Where are we right now? Champion state + leaderboard. |
| `tenures.py [first] [last]` | Which of our versions was champion over which round range (+ mean rank, zero-episode/DQ count). Run this FIRST — every comparison needs the boundaries. |
| `rounds.py [since]` | Round-by-round rank/score/episode-count for our champion. |
| `h2h.py <first> <last>` | Per-opponent episode W/L/winrate over a round range. |
| `matched.py <aF> <aL> <bF> <bL> [min_n]` | ⭐ A/B two tenures, matched on opponents present in both. |
| `heals.py <first> <last> <ver> [n] [--cw V]` | Mechanism metrics (heals, K/D, attrition window) by re-simulating real league replays. |
| `ffa4score.py` | ⭐ **The ffa4 gate.** Score one policy version's ffa4 *survival economy* (med-kit uptake, hp==1 escape, deaths of 12) from hosted replays, split by coworld build, with a power line. See below. |
| `gloryscore.py` | Calibrate the glory economy (`src/ctf/glory.nim`'s levels/achievements/heat/sweep-budget) against re-simulated real league episodes. See below. |

## Three traps this tooling exists to avoid

**The leaderboard `win_rate` is not your policy's winrate.** It is cumulative
over the whole *policy-slot* history, so it blends the current version with
every predecessor. Use `h2h.py` over the version's own tenure instead.

**The field re-arms underneath you, so a raw tenure-vs-tenure delta is
confounded.** Over r1672..r1938, 40% of our schedule turned over and the
churned-in opposition was 27.3 pp harder than what it replaced — a *flat* raw
winrate there is actually a real gain. `matched.py` restricts to opponent
versions present in both tenures. For the same reason, **mean rank can worsen
while the policy improves**: rank is relative to the field's current strength.

**A replay only re-simulates on the engine that recorded it.** The hosted
coworld build churns every few days (0.7.80 → 0.7.102 across two tenures) and a
mismatched build refuses outright ("Replay game version does not match"). Do not
"fix" this by overriding `GameVersion` in `sim.nim` — that gets you a hash
mismatch at tick 1, which is the engine correctly telling you behavior differs.
If two tenures share no build, the cross-version mechanism A/B is *unavailable*;
report it as such rather than comparing incomparable numbers.

## `heals.py` prereq

Needs the tier-2 event sink, which lives on the GV23 lab worktree:

```sh
cd /private/tmp/ctf-gv23-lab
nim c -d:release --hints:off -o:/tmp/medcheck/extract_events tools/extract_events.nim
```

Match the extractor's engine to the replays' `coworld_version` (GV23 accepts
0.7.95+). Pin one build with `--cw 0.7.99` when comparing across tenures.

Caches live in `/tmp/ctfladder/` (rounds + episodes) and `/tmp/medcheck/work/`
(replays + event streams), so re-runs are free. A full 174-round `h2h.py` sweep
takes ~10 min cold — run it with `nohup` in the background.

---

# `scout.py` — the fast diagnosis loop

**Why it exists.** Elo is zero-sum, so *standing still is falling*: a rival who
ships faster takes rating off us even when our own play is unchanged. On
2026-07-28 our episode winrate was flat at ~0.50 across every bucket of 146
rounds while our mean rank drifted 4.23 → 5.38 — we did not decay, the field
moved. Andre fielded six policy-versions in ~120 rounds; we shipped one. A
6-rubric audit plus a hosted single-lever A/B takes ~a day per candidate, which
loses to an opponent shipping 6/day.

**The unlock.** Every completed round already holds 110 head-to-head episodes
whose replays are **public, downloadable without auth, and re-simulable to ground
truth**. The field test is already paid for — we just have to read it. Hosted
A/Bs (which cost xp-requests and a day of latency) become the *final gate*, not
the measurement.

Measured: **411 episodes of full ground-truth attribution in 9 minutes**, 411/411
extracted cleanly.

## Setup, once

`scout.py` needs its own extractor build (it re-simulates in parallel and pins a
known engine, so it does not share `heals.py`'s `/tmp/medcheck` binary):

```sh
git worktree add ~/projects/coworld-ctf-scout -b scout origin/main
cp nim.cfg ~/projects/coworld-ctf-scout/       # UNTRACKED; builds fail without it
cd ~/projects/coworld-ctf-scout
nim c -d:release --hints:off -o:bin/extract_events tools/extract_events.nim
```

Found by default; override with `CTF_SCOUT_BIN`.

## The loop

```sh
PYTHONPATH=. $PY scout.py index                     # who we played, what they fielded
PYTHONPATH=. $PY scout.py run    --rounds 20        # download + re-simulate + report
PYTHONPATH=. $PY scout.py report --vs daveey        # drill into one opponent
PYTHONPATH=. $PY scout.py diff   --since 1837 --until 1856   # our version A vs B
```

Caches under `~/.ctf/scout/` (rounds → replays → events), so re-slicing an
existing corpus is nearly free. ~19MB per 88 episodes.

**Reports** per opponent: episodes, winrate, K/D, our accuracy vs theirs, damage
dealt/taken, shield-blocked hp, med kits, steals, captures, carrier drops — plus
a kill/death split by tick bucket (where in the match the fight is actually
lost), damage by weapon, and a **version-cadence table** flagging any rival who
shipped mid-window. `diff` compares two of our own versions over *shared
opponents only*, since a raw total is not comparable across a different mix.

## Gotchas this encodes — do not relearn them

- **`limit=1000`, always.** `/v2/rounds/{id}/episodes` defaults to `limit=50` but
  a round holds **110** episodes. The default silently truncates and can drop our
  own pairings entirely.
- **Check the `entries` key.** That endpoint returns
  `{entries, limit, offset, total_count}`. Code looking only for
  `episodes`/`data`/`items` got an empty list, which read as "no episodes" rather
  than as an error. (The old note that this endpoint 403s is **stale** — it
  returns 200 and `replay_url` is a public S3 object needing no auth.)
- **`--rounds N` slides.** A round lands every ~9 min (~165/day), so a bare
  `--rounds N` names a different set each run and a long sweep can drift under
  its own report. Pin with `--since A --until B`; `scout.py` prints the flags to
  reproduce any sliding run.
- **`Heal` records the healed player in `source`, not `target`.** Reading
  `target` silently drops every heal — and med-kit uptake is a watched lever.
- **The GameVersion horizon is real** (same trap `heals.py` documents), but
  `scout.py` reads it from the replay *header* and reports it up front
  (`GV22=271 skipped`) instead of as N opaque failures. `diff` deliberately uses
  the episode's **own API score** rather than a re-simulation, so version
  comparisons still work across a bump.
- **Attribution is grounded in the replay, never assumed.** Hosted replays record
  the league player name per seat (`"softmaxwell"`, `"softmaxwell (2)"`…), and
  API `position` == replay join slot. An episode containing a name we can't place
  is skipped rather than guessed at.
- **Empty seats happen.** A blank recorded name means that agent never joined and
  the episode ran short-handed — a free loss, not a policy problem. Reported
  separately.
- **Both seatings come free.** 110 episodes = 55 pairings × both seatings, so the
  Red-favored map is already controlled for; `report` prints the red/blue split
  so a per-opponent number is never just the map talking.

**Trust.** The re-simulated winner agreed with the league's own episode score on
**88/88** episodes — the extraction faithfully mirrors the hosted result, so the
richer attribution built on it can be trusted too.

---

# `ffa4score.py` — the ffa4 survival-economy gate

**Why it exists.** We shipped two ffa4 levers without ever measuring their
outcome, because the measurement was a bespoke research project each time. The
local 4-team rig is **disqualified** for scoring survival: it saturates at ~92%
of the metric's ceiling (10.3-10.9 lives of 12 spent by t1500 vs **7.02** in the
field; P(die|hp==1) 95-99% vs ~90%), runs the wrong map family, and its probes
read the fogged HUD. Hosted replays are the only trustworthy source — and they
are free, public and need no auth. The field ledger discriminates the med-kit
economy at **6.4-6.9 SE across three independent build cells**, which no local
A/B in this class reaches.

## The six pre-registered metrics

Per policy version, per coworld build, clustered on the **team-Episode** (a
policy's four seats in one Episode are ONE sample, not four), bootstrap CI:

1. **med_kits per 1e6 ALIVE ticks** — the alive-time denominator is what kills
   the "we just die more" confound.
2. **kit share of the map** — our pickups / all pickups that Episode. Null 25%.
3. **P(escape | hp==1)** — from a *reconstructed HP track* (respawn→3,
   `damage.hp`, `heal.hp`, death→0), never from event counts. Segments still
   open at the last event are dropped, so the denominator holds only resolved
   outcomes.
4. **P(zero kits all Episode)** — blunt and very discriminating.
5. **deaths per team-Episode** and **P(survive, <12 deaths)** — 3 lives x 4
   agents. `ffa4score.py` prints the elimination invariant it rests on: *0 of
   160 winning team-Episodes reached 12 deaths.*
6. **Paired within-Episode delta vs the scripted `Baseline` control** — the
   design that closes the map/field confound, because both arms sit in the same
   Episode.

## The loop

```sh
PY=~/projects/coworld-players/coworld-cogherence-player/.venv/bin/python
cd tools/ladder

PYTHONPATH=. $PY ffa4score.py index --rounds 40            # what ffa4 exists, per build
PYTHONPATH=. $PY ffa4score.py fetch --limit 200            # download + re-simulate ours
PYTHONPATH=. $PY ffa4score.py score --version v57 --vs v55           # our ship vs our last
PYTHONPATH=. $PY ffa4score.py score --version v57 --vs "Ron @ SWGY"  # vs the field's best
PYTHONPATH=. $PY ffa4score.py selfcheck                    # the trap defences, as tests
```

**After a ship, this is the one command** — `--vs` takes either a rival *or one
of our own versions*, so the post-ship gate is a single call:

```sh
PYTHONPATH=. $PY ffa4score.py run --version v58 --vs v57 --limit 200 \
    --since 2100 --until 2260
```

Run it again with `--vs "Ron @ SWGY"` to see where the new version sits against
the field's best ffa4 player under the same instrument.

`run` = index → fetch → score. Pin `--since/--until` (or the portable
`--after/--before` ISO dates) or the window slides under the report: a round
lands every ~9 min. Every stage caches under `~/.ctf/scout/` and
`~/.ctf/scout/ffa4/`, so a re-score of an existing corpus is instant.

## What counts as success

The ship is on the **med-kit economy**, so read metric 1 and metric 6 first.

| reading | verdict |
|---|---|
| paired-vs-`Baseline` med_kits moves from **-0.56** toward **0**, CI excluding zero | the lever fired |
| kits/1e6 alive ticks **59.7 → ≥90** (pre-registered ship-size is +30), CI excluding zero | the lever fired |
| P(zero kits) **57.5% → ≤47%** | the lever fired |
| any CI crossing zero | the tool prints **"no measurable change"** — that is the verdict, not a near-miss |
| fewer than 20 team-Episodes | the cell prints **⚠️ THIN**; e.g. v57 reads +41 kits/1e6 over v55 at n=6, CI [-22,+109] → *no measurable change*, and the power line says a quarter of that apparent gap needs 156 days |
| the sign of the paired delta stays negative | we still take *fewer* kits than a scripted bot in the same Episode |

The reference band is on the same table: winners take **212** kits/1e6 alive and
escape hp==1 **13.4%** of the time; the scripted filler takes **224**; we take
**59.7** and escape **2.1%**. Ron @ SWGY is at **+1.62 kits paired vs the same
control** where we are at **-0.56** — a sign flip, which is the single most
discriminating number this tool prints.

## How long a real read takes (the power line)

`score` measures the ffa4 arrival rate rather than assuming it — over
fully-cached rounds only, because a per-calendar-day count of an imported cache
measures how hard somebody swept that day. At **~7.6 ffa4 team-Episodes/day**:

| effect to resolve (80% power, alpha .05) | n/arm | days |
|---|---|---|
| +30 kits per 1e6 alive ticks (half our current level) | 123 | **16** |
| +0.30 med_kits per team-Episode | 99 | **13** |
| -0.50 deaths per team-Episode | 248 | **33** |
| -10pp on P(zero kits) | 387 | **51** |

So a med-kit lever is readable in about **two weeks** of field play, and a
deaths-based read is **not** worth waiting for — deaths is the outcome, kits is
the instrument. The rate tracks the campaign cells we hold, so it is re-measured
every run (`--rate-days`, `--eps-per-day` to override).

## Gotchas this encodes — do not relearn them

- **The `{"type":"summary"}` row is the LAST line of an event file**, not the
  first. A line-1 read yields zero slots *silently*. `selfcheck` asserts it on
  real files.
- **`is_filler` marks a SEAT, not a policy.** It flags every entrant's 2nd-4th
  seats — including 1155 of our own participant rows — so trusting it labels
  every entrant a filler. The scripted control is the entrant whose
  `slot_address` is literally `Baseline`, and that is the only test used.
- **Builds are never summed.** 0.7.228 and 0.7.229 are both GV43 but different
  builds; v52's ffa4 record ran +0.198 → +0.305 → -0.270 across builds, a sign
  flip a blended number hid completely. A build with no extractions prints
  **UNAVAILABLE**, which is not the same as zero.
- **Read the GameVersion from the replay HEADER, never from the summary row.**
  The summary's `gameVersion` is the *extractor's* and reads 43 for every file
  we could extract at all — circular. Measured off headers, **0.7.227 is GV43,
  not GV42**; only 0.7.225/0.7.226 are GV42. For a build we hold no replay of,
  the tool probes one header with a 64-byte HTTP Range request, so "new build,
  0 extracted" is correctly reported as *run fetch* rather than as an engine
  horizon.
- **`limit=1000`, always** — `/v2/rounds/{id}/episodes` defaults to 50.
- **Cross-player fields can be viewer-scoped** (`dropped`/`error`/`latency_s`/
  `reasoning` exist only for our own player). The index compares participant
  **key sets** and says so if they differ; a missing key is never read as zero.
- **ffa8 (`4-team free-for-all (8 per team)`) is excluded** by name *and* by a
  16-slot / 4-colour geometry assertion, and the exclusion count is printed.
- **Four bases have no x-midline**, so every single-midline positional estimator
  is UNDEFINED here, not noisy. This tool contains no positional estimator at
  all: the six metrics are counts, times and outcomes.
- **Event files are named for the REPLAY uuid, not `episode_id`.** Joining on
  `episode_id` returns zero rows and looks exactly like an empty corpus.
- **A policy can hold two teams in one Episode**, and the scripted control
  usually does (1248 of 1488 Episodes). Those are averaged, not double-counted.

**Trust.** Every headline reproduces the existing hand-built corpus exactly on
the v55 @ 0.7.229 cell: kits/1e6 alive **59.66** (published 59.66), kit share
**12.88%**, P(escape|hp==1) **2.07%** over **1403** resolved hp==1 segments,
deaths **10.881**, with n=160/116/110/254 team-Episodes across
ours/winner/rival/control — and the winner (212.06 / 42.30% / 13.36% / 7.560)
and scripted-filler (224.34) columns land on the published values too.
P(survive) reproduces at **0.3986** (published 0.399) for us and **0.6181**
(0.618) for Ron @ SWGY on the same corpus snapshot.

---

# `gloryscore.py` — the glory-economy calibration mirror

**Why it exists.** `src/ctf/glory.nim` prices every kill, objective act and
achievement, and its two calibration constants (`LevelThresholds`,
`AchievementSweepBudgetPct`) were either guessed or shipped uncalibrated. This
runs the same pricing table over real, re-simulated league episodes so those
numbers are fit to the field, not to intuition — and reports the
**DISCRIMINATION** check (winners must out-claim losers) that tells you
whether the achievement curriculum is a real skill test or participation
candy. It also reports per-(tree, tier) claim rates, so a tier that should be
rare (V) but claims *more* than a tier that should be common (I) is caught,
not shipped.

⚠️ It is a MIRROR, not the source — see the file's docstring for the exact
list of what it approximates (drops `dRunDown`/`dRevengeKill`, prices range
off the last shot position, recovers pedestals from `flag_steal` only) and
the `GLORY_VERSION` tripwire that pins it to `glory.nim`.

## Two cache traps this file's docstring exists to warn about

- **Event files are named for the REPLAY uuid, not `episode_id`.** `meta` is
  keyed by `episode_id` from `rounds/*.json`, but `events/*.jsonl` is named
  after the uuid in `replay_url`. Joining on `episode_id` matches zero files
  and the run silently scores nothing — always derive the join key from
  `replay_url.rsplit("/", 1)[-1]`.
- **2-TEAM ONLY, by construction.** The cache mixes 2-team, `4ffa` and
  `4ffa8` episodes in the same directories, and this file's `team = slot % 2`
  formula is only valid for 2-team play. It filters to the `default` variant
  before scoring anything; on a 4-team episode the mod-2 split would silently
  scramble every per-team number rather than erroring (the exact shape of bug
  that once made half our agents statues).

A third, related trap this file's `--min-version` comment now documents: the
filter does a **STRING** compare, so `v0.7.9x` episodes pass it despite
predating `0.7.200` by 100+ builds (`"0.7.95" < "0.7.200"` is `False` in
Python). Today's 120-episode field is entirely `v0.7.95-98`, which ships with
**zero** `item_pickup` events — the PER-TREE RUNG ORDER report below prints an
explicit caveat when this is why a tree can't claim tier I, rather than
letting it read as a curriculum defect.

## Sample invocation

```sh
cd tools/ladder
python3 gloryscore.py --episodes 400
# -> scoring 120 real episodes (cache 2277 attributed, glory v1)
```

Prints levels, achievements (with per-tree rung order and a tier-banded
DISCRIMINATION split), heat occupancy, glory-vs-winning, a wipe-corrected
sweep budget, deed frequencies and a by-policy breakdown — all over whatever
`~/.ctf/scout/` already holds, so a re-run is free.
