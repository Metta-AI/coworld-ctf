# Ladder assessment tools

Judge a submitted policy on the LIVE Elo ladder. Run everything with the
cogherence player's venv, which holds the working login:

```sh
PY=~/projects/coworld-players/coworld-cogherence-player/.venv/bin/python
cd tools/ladder
```

| script | question it answers |
|---|---|
| `standing.py` | Where are we right now? Champion state + leaderboard. |
| `tenures.py [first] [last]` | Which of our versions was champion over which round range (+ mean rank, zero-episode/DQ count). Run this FIRST — every comparison needs the boundaries. |
| `rounds.py [since]` | Round-by-round rank/score/episode-count for our champion. |
| `h2h.py <first> <last>` | Per-opponent episode W/L/winrate over a round range. |
| `matched.py <aF> <aL> <bF> <bL> [min_n]` | ⭐ A/B two tenures, matched on opponents present in both. |
| `heals.py <first> <last> <ver> [n] [--cw V]` | Mechanism metrics (heals, K/D, attrition window) by re-simulating real league replays. |

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
