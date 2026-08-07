# Policy label-scan audit — is the bot blind to spray-can pickups?

**Date:** 2026-08-07 · **Engine:** GameVersion 40 · **Policy lineage:** `maxwell/paintbot-v43` (a18fb17)

Filed as: *"Policy is blind to spray-can pickups on the live engine (0.7.x renamed the labels)."*

## Verdict

**The reported bug is already fixed — and the fix is not the finding.** The pickup scans on
the current champion lineage read `LabelSprayCan` / `LabelSprayCanCarried`, not the retired
`"plasma arc"`. That happened between the task being filed (2026-07-29) and v42/v43
(2026-08-06/07); no `"plasma arc"` string literal survives anywhere in `players/`.

The finding is what the audit *around* it turned up:

1. The historical field data carries the **fingerprint of the blindness**, and it is a
   distinctive one — see [The 0.20x signature](#the-020x-signature).
2. Two *other* retired-label families are still being scanned, and they were sitting in a
   documented hole in the existing guard — see [The audit](#the-audit).
3. **We cannot field-verify anything right now: we have no active champion.** Our last
   league appearance was round r2034; the league is at r2583. See [The live-field
   blocker](#the-live-field-blocker).
4. The durable outcome is a test that derives the scanned-label set from the policy source,
   so this class of bug cannot recur silently — see [The guard](#the-guard).

## Engine parity — the first check

| | |
|---|---|
| `GameVersion` on `origin/main` | `40` |
| `GameVersion` on `maxwell/paintbot-v43` | `40` |
| `src/ctf/labels.nim` v43 vs main | identical |
| `tests/label_manifest.txt` v43 vs main | identical (75 lines) |

The policy lineage is on the same engine and the same observation contract as main. Nothing
in this audit is confounded by an engine gap.

## The 0.20x signature

Ground truth from the free replay loop — `item_pickup` events re-simulated out of public
league replays, attributed per seat via `slot_address`, ours vs everyone else in the same
episodes. This is the last field data we have (GV26/GV27, rounds up to r2034):

**GameVersion 26** — 123 episodes, 984 our seats / 984 field seats

| item | ours/seat | field/seat | ratio |
|---|---|---|---|
| grenade | 0.524 | 0.724 | 0.72x |
| med kit | 0.260 | 0.170 | 1.53x |
| shield | 0.136 | 0.202 | 0.67x |
| **spray can** | **0.022** | **0.112** | **0.20x** |

**GameVersion 27** — 207 episodes, 1656 our seats / 1656 field seats

| item | ours/seat | field/seat | ratio |
|---|---|---|---|
| grenade | 0.467 | 0.710 | 0.66x |
| med kit | 0.207 | 0.249 | 0.83x |
| shield | 0.139 | 0.218 | 0.64x |
| **spray can** | **0.031** | **0.111** | **0.28x** |

**Read the spray-can row against the others, not on its own.** We are mildly *below* the
field on grenades and shields (0.66–0.72x) and *above* it on med kits — that is a policy
with different item priorities, which is a choice. Spray cans are a different animal
entirely: **0.20x and 0.28x, four to five times below the field, on the one item whose
label had been renamed.** Every other item's label survived 0.7.x untouched.

And critically it is **0.20x, not 0.00x**. That is the exact signature of a blind scan
rather than a disabled lever: pickup is a *touch* radius, so a bot that cannot see a can
still collects one occasionally by walking over it. A bot that had the lever gated off
would show the same. A bot that could *see* cans and declined them would not be 5x below
the field on that item alone. **We were getting spray cans only by accident.**

This is consistent with, and sharpens, the prior finding that ~87% of our spray cans went
unfired: a can you picked up by accident is a can you did not plan to use.

> **Caveat, stated plainly:** this is GV26/GV27 data and the live engine is GV40. It
> establishes that the blindness was real and measurable in the field, on the engine where
> the policy still scanned `"plasma arc"`. It does **not** measure the fixed policy, because
> there is no field data for the fixed policy — see below.

### A live-context claim that did not survive checking

The task brief stated spray is the #2 weapon on GV40 at **28.5% of kills**. Measured over
the cached corpus by reading `weapon=` off kill events:

| engine | gun | grenade | spray |
|---|---|---|---|
| GV26 (5108 kills) | 90.4% | 7.8% | **1.9%** |
| GV27 (8609 kills) | 90.1% | 7.7% | **2.2%** |

Spray is the #3 weapon at ~2% of kills, not #2 at 28.5%. It is still *second* by
lethality-per-use and worth contesting — but a lever sized against "28.5% of kills" would
be sized roughly 13x too generously. This is GV26/27 data and the claim was made about GV40,
so it is not a direct refutation; it does mean the 28.5% figure needs a GV40 source before
anything is built on it. `spray_use.amount` is confirmed always 0 and useless as a signal —
read `weapon=` off damage/kill events instead.

## The audit

Every exact-match label the policy scans, resolved from source and checked against
`tests/label_manifest.txt` (33 call sites, 24 distinct patterns):

| pattern | sites | status |
|---|---|---|
| `spray can`, `spray can carried` | 3 | ✅ emitted — **the reported bug is fixed** |
| `med kit` | 4 | ✅ emitted |
| `shield`, `shield carried` | 3 | ✅ emitted |
| `grenade`, `grenade air`, `grenade carried`, `throw target` | 4 | ✅ emitted |
| `fire icon`, `shot impact` | 2 | ✅ emitted |
| `<color> flag`, `<color> flag planted` | 7 | ✅ emitted |
| `self <color> <side>`, `player <color> <side>` | 3 | ✅ emitted |
| `hp <n>/3` | 2 | ✅ emitted (denominator matches `LabelHpBarSegments`) |
| `muzzle bloom stage <n>` | 1 | ✅ emitted |
| **`aim dot <color>`** | **3** | ❌ **retired — nothing emits it** |
| **`sword`** | **1** | ❌ **retired at GameVersion 15** |
| **`sword carried`** | **1** | ❌ **retired at GameVersion 15** |

### The two dead families

Both are **benign**, and both are now registered rather than merely known:

- **`aim dot <color>` ×3** — the aim-indicator dots are gone from the renderer. All three
  readers (`observedAim`, `mateAimBrads`, `actorsFor`'s dot attribution) are pre-GV26
  fallbacks: the engine now states own aim outright via the `own aim <brads>` marker, which
  `ownAimBrads()` reads *first* and which `break resync`-es before a dot scan is reached.
  Mate and enemy bearings come from `aimRotRead`'s sprite ids. Each dead scan yields -1 and
  the live path takes over, so behaviour is unaffected.
- **`sword` / `sword carried`** — the sword was replaced by the plasma arc (now the spray
  can) at GameVersion 15. The pickup scan is gated behind `tune.swordAmbush`, off in every
  shipped bundle. The carry scan is ungated and runs every frame, but `false` is the correct
  value on any engine since GV15 and every use is `not iHaveSword` or sits under the same
  off gate.

**They were not deleted, deliberately.** Both have verified live fallbacks, so removing them
buys no behaviour change — and the champion is a hot artifact with several branches in
flight against it. Registering them costs nothing and, because the registration is a
two-way guard (below), cannot rot.

## The live-field blocker

**We have not played a league episode in ~549 rounds.**

```
scout.py index --rounds 12   ->  344 completed episodes over rounds r2572-r2583
                                 0 of them involve softmaxwell
standing.py                  ->  champ=False status=competing/benched  Picasso:v29
                                 champ=False status=competing/benched  Picasso:v28
                                 ... every version down to Picasso:v1. Nothing championed.
last cached round with our episodes: r2034      league now at: r2583
```

The newest version registered with the league is **v29**, while v41/v42/v43 exist only
locally. Two consequences, both load-bearing:

- ELO is running (k=16), so **standing still is falling**. Benched is not neutral.
- **The free field-diagnosis loop is dead for anything policy-side.** `scout.py` re-sims
  league replays to ground truth, but with zero episodes of ours there is nothing to
  attribute. Every measurement in this report had to fall back to July's GV26/GV27 cache or
  to local GV40 self-play.

Filed as its own task; it is a bigger problem than the one this audit was opened for.
A second task covers `standing.py` dying on a 422 from the leaderboard endpoint
(`include_recent_rounds=40` is now rejected).

## Verifying the lever actually fires

With the field unavailable, the fix was verified on **local GV40 self-play** — the real
engine, the real fogged sprite packets, the shipped `decide()`. A new `-d:canprobe`
separates the two causes that produce the same symptom:

- `cpGate` — decide-frames where the pickup scan ran
- `cpSeen` — ...and the `spray can` scan came back **non-empty** ← *the label read itself*
- `cpSeek` — ...and `sprayGrab` committed the steer
- engine-truth held-ticks and rising-edge pickups, from `hasPlasmaArc`

`cpSeen` is the measurement that matters, because it is taken **before any policy judgement
is applied**. A pickup count alone cannot distinguish "never saw one" from "saw one and
declined"; `cpSeen` can.

Two arms, identical seeds, built from the same tree and differing in **one string**:

| arm | the scan |
|---|---|
| **fix** | `spriteObjectsWithLabel(LabelSprayCan)` — as shipped |
| **blind** | `spriteObjectsWithLabel("plasma arc")` — the pre-fix label |

<!-- RESULTS -->

## The guard

`tests/test_policy_label_scans.nim` (wired into shard 4).

`test_label_contract.nim` already guards the *producer* half — every label in
`labels.PolicyScannedLabels` must actually be emitted. But that list is hand-maintained, and
`labels.nim` says so outright:

> KNOWN GAP — this list is hand-maintained. Nothing forces a NEW `spriteObjectsWithLabel`
> call in the bot to be registered here, so the guard only covers labels somebody remembered
> to add. It catches the engine-side half of a rename, not the consumer-side half.

`aim dot` and `sword` were living in exactly that hole. The new test closes it from the
other end: it reads `players/baseline/baseline.nim`, resolves **every**
`spriteObjectsWithLabel` argument to the manifest pattern it builds — chasing `let`/`for`
bindings, expanding `Label*` consts scraped from `labels.nim`, mapping colour/number/side
interpolation — and asserts each is a label the engine emits. Nothing to remember: add a
scan and it is covered on the next run.

Three properties worth keeping if this is ever edited:

- **Unresolvable is a FAILURE, not a skip.** An argument shape the resolver cannot read is
  an *unchecked* scan, which is the blind spot the test exists to remove. Teach the
  resolver instead of relaxing the check.
- **A floor on the resolved scan count**, so a moved or renamed policy cannot make the whole
  suite pass vacuously over an empty list. That is the one way a test like this can lie.
- **`RetiredScans` is a two-way guard.** An entry exempts a pattern from "must be emitted",
  but *also* asserts the engine really has retired it — and that the scan still exists. If a
  retired label comes back to the manifest the entry fails and demands a rewire; if the scan
  is deleted the entry fails as dead weight. It expires the moment its premise stops holding
  rather than becoming a permanent excuse.

### Verified by mutation, not by its own green

A guard that passes proves nothing until it is shown to fail on the real bug:

| mutation | result |
|---|---|
| revert the spray-can fix (`scan "plasma arc"`) | ❌ FAILS — `baseline.nim:7023 -> "plasma arc"` |
| drop a `RetiredScans` exemption | ❌ FAILS — `baseline.nim:6994 -> "sword carried"` |
| add an unreadable scan shape | ❌ FAILS as unresolvable, at all 3 affected sites |
| unmodified tree | ✅ passes |

## Reproducing

```sh
nim r tests/test_policy_label_scans.nim          # the guard (pure text, no sim/renderer)
python3 tools/ladder/pickup_rates.py             # ours-vs-field pickup rates by engine version

nim c -d:release -d:canprobe --opt:speed \
  -o:/tmp/harness.out players/baseline/eval/harness.nim
./tmp/harness.out --games 12 --seed 7 --ticks 8000   # run from the repo root: needs data/
```
