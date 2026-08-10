# How many people actually use a coworld?

**Proposal: adopt one definition of Daily Active Users for every coworld league.**
Measured on Paintbot, 2026-08-10. Live dashboard: `tools/ladder/dau_server.py`.

---

## The number

**Paintbot has ~7 daily active users.** Today it had 4.

Not 18, not 20, not 26 — which is what the three obvious places to look will tell
you.

| Where you'd naturally look | Says | Why it misleads |
|---|---:|---|
| Players fielded in one round | **18** | Measured on round 1228 (31 episodes). Those policies play every ~12 minutes with nobody watching. |
| Leaderboard entrants | **20** | Everyone who ever entered. Flat whether or not a person is here. |
| Lifetime submitters | **26** | Monotonic by construction — it can only ever go up. |
| **This definition** | **7.2** | Counts people, not processes. |

## Why this is harder than it looks

A coworld is not a normal product. **You upload a bot, and then the bot plays
forever without you.** Paintbot runs a round every ~12 minutes, around the clock.

That breaks activity metrics in both directions at once:

- **Count what the bots do** and you get 18 — a number that would still read 18 if
  every one of those 18 people quit this afternoon, because their policies keep
  fighting each other regardless. It is "people who ever signed up" wearing a DAU
  costume. It cannot go down.
- **Count only uploads** and you under-report the people who matter most: someone
  near the top of the ladder reads replays every morning and ships once a week.

So the definition has to count *human decisions*, and be honest that a machine
running unattended is not one.

## The definition

**1. A user is active on a day if they took at least one deliberate action on that
league.** Today the only action the platform exposes is shipping a policy version,
so the number is a floor (see the ask below). One action is enough to count for
the day; a hundred is still one day.

**2. Repeat actions are capped, so volume cannot buy activity.** At most 3 count
per person per day. This is not hypothetical: one Paintbot player opened **229
memberships in a single day**. That is one active day, not 229. Without the cap
that single player would have been 48% of all league activity and would have set
the trend line by themselves.

**3. Machine cadence is excluded — and reported separately, not deleted.** That
same player's median gap between uploads was **2.1 minutes**, with 75% of gaps
under five, all on one policy. No human hand does that. Every other player in the
league sat at a 60-minute-or-longer median, so the test separates cleanly with
nothing borderline.

**4. Compare coworlds on their own loop period, not on a calendar day.** Paintbot
re-ships every 7.6h at the median — faster than a day, so a daily count is already
the right unit here. A coworld with a multi-day training loop would read as dead
on the same metric unless the window is widened to its loop. This is the parameter
that makes one number work across every coworld.

## What it found in its first run

Two things no other count on this page can see.

**Weekend retention flipped.** The first weekend after launch, activity fell to 2
people. The most recent weekend held at 6–7. Same coworld, twelve days apart —
people started coming back on their own time. All three naive counts are
*identical* across both weekends.

**An auto-improvement loop ran for 36 hours and produced nothing.** 233 policy
versions, uploaded every ~2 minutes, all on one policy. Final territory score:
**0.0**, rank 10 of 20, and 225 of the 233 versions sat benched. It stopped on
2026-07-31 and no human has been back since.

That second finding is the one with a real lesson in it, and it is why this
proposal reports two numbers instead of one.

## The judgment this metric deliberately does not make

An unattended loop that is *still running* uploads policies every day with no
human present. Capping and gating bound the damage, but they cannot answer the
actual question: **is that an engaged user or a forgotten cron?**

Both look identical by volume. Someone who built a working auto-improvement loop
is arguably the most invested user we have. Someone who left one running and
walked away is not a user at all.

**Volume cannot tell these apart. Only progress can** — whether the score actually
moves. That is a second metric (learning progress), and it is the natural next
piece of work. Until it exists, this tool refuses to guess: it reports *attended*
and *unattended* in separate columns and leaves the judgment visible rather than
silently merging or silently dropping it.

## The ask

**One append-only event log**, per action, with five fields:

```
(user_id, coworld_id, timestamp, action, credential_type)
```

covering page views, replay downloads, and authenticated API reads — not just
uploads. `credential_type` is what separates a person from their running policy,
which authenticates with the same token today.

**The formula does not change.** It just stops being a floor. Everything else in
this proposal is already built and running against the live API.

## What's built

| | |
|---|---|
| `tools/ladder/dau.py` | The definition, computable. Takes `--league` / `--div`, so it points at any coworld. |
| `tools/ladder/dau_server.py` | Live dashboard, recomputed from the API every 5 minutes. |

```sh
PY=~/projects/coworld-players/coworld-cogherence-player/.venv/bin/python
cd tools/ladder
PYTHONPATH=. $PY dau.py --days 12          # the report
PYTHONPATH=. $PY dau_server.py             # the dashboard, on :8931
```

> **One gotcha for anyone re-running this:** `ctfapi.py` still hardcodes the dead
> `Ctf` league in its `LEAGUE` constant. Both tools here default to Paintbot
> explicitly and print the league name and id in their header, because an empty
> result from the wrong league is indistinguishable from an outage — that mistake
> has cost this project a full session before.
