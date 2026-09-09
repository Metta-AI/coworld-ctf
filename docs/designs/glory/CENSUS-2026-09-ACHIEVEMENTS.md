# GLORY GRADIENT — STEP 1 ADDENDUM: ACHIEVEMENTS (2026-09-09)

**Filed standalone**: `docs/designs/glory/CENSUS-2026-09.md` (the main S1
census doc, PR #483) did not exist on this branch's base at write time —
PR #483 lands only `tools/glory/`, not that doc. If #483 later adds it,
the lead should decide whether to fold this file in as a section or keep
it separate; not done here to avoid guessing at another PR's shape.

Measurement only. No sim/glory/scoring code touched; no WIRE change; no
settings POST; no deploy. Decomposes the S1 census's already-reconciled
product into its deed vs achievement factors — it does not re-score
anything or add a new data source.

## Era stamp — SAME population as the S1 census, unchanged

GloryVersion 15 (JointAct pact-gated, PR #467), coworld_version
0.7.361-0.7.367, GameVersion 59/60 (byte-identical scoring), Paintbot
Season 2 ladder, rounds r4515-r4539 — **the entire population at this era**.
305 episodes, 4,880 seat-episodes. Identical to
`01-census-2026-09-08.md`; no re-scoping.

## Method

This program's own S1 method finding is *why* this addendum is possible:
the census's first decode pass reconciled 0/4,880 because achievement
events (`kind: "achievement"`) fold into the **same** multiplicative
product as `glory_deed` events — an achievement's contribution was never a
separate source, it was already inside the reconciled product. This
addendum decomposes that already-validated product back into its two
factors using the SAME cached extraction the census produced (no
re-download, no re-simulate):

- `tools/glory/census_achievements.py` re-walks the 305 already-cached
  JSONL event streams (`~/.ctf/scout/glory_census_replays/*.jsonl`,
  produced by the census's own era-matched `extract_events` binaries) and
  keeps two running products per seat — `deed_product` (glory_deed events,
  `amount>1`) and `ach_product` (achievement events, `amount>1`) — instead
  of one combined product. Every achievement event carries `weapon` = tree
  name and `hp` = tier index (0-4), verified directly against the emitter
  (`src/ctf/sim.nim:562-568`, `claimAchievement`'s `emitEvent(Achievement,
  weapon = $tree, hp = tier, blocked = ord(effectiveFirst), amount =
  factor)`).
- **Cross-check, not a new reconciliation**: recombining
  `deed_product x ach_product`, FF-halving, win-multiplying and capping
  reproduces census_decode.py's already-platform-validated `recon_final`
  for **4,880/4,880 (100.00%)** rows, byte-exact. The census did the real
  reconciliation against the platform; this only confirms the split
  recombines to the same number the census's single combined product did.
- `tools/glory/census_achievements_analyze.py` answers the four questions
  below. Both scripts are new (this addendum), reusing the census's data
  and conventions; `census_decode.py`/`census_analyze.py` themselves were
  not modified.

## Q1 — Per-achievement mint rate (8 trees x 5 tiers = 40 slots, n=305 episodes)

Only **5 of 40 (12.5%)** achievement slots minted at all. **35 of 40
(87.5%) are DEAD** — zero mints across the entire population:

| tree | tier | class | mints/ep | % eps >=1 | total | firsts |
|---|---|---:|---:|---:|---:|---:|
| treeGun | I (any kill) | x1 | 7.4820 | 100.00% | 2282 | 0 |
| treeGun | II (3 kills) | x1 | 0.8262 | 67.87% | 252 | 0 |
| treeGun | III (Ace) | x2 | 0.0164 | 1.64% | 5 | 0 |
| treeGun | IV (max level) | x2 | 0 | 0% | 0 | 0 |
| treeGun | V (Sharpshooter/longshot) | x4 | 1.1541 | 69.18% | 352 | 211 |
| treeSquad | IV (Clean Sheet) | x2 | **16.0000** | **100.00%** | 4880 | 0 |
| every other slot (treeSpray x5, treeGrenade x5, treeShield x5, treeMedKit x5, treeCarrier x5, treeDefender x5, treeSquad I/II/III/V) | — | — | 0 | 0% | 0 | — |

**DEAD by cause**: treeMedKit (all 5) is engine-omitted on this port,
structurally dead regardless of mode (`sim.nim` GLORY-PORT-TODO).
treeCarrier (all 5) and treeDefender tiers I/III/IV gate on
flag-carry/peel/denial — dead on flagless BR, same structural cause as the
census's dead CTF-objective deeds. treeShield's four live-tier gates
(assists, escortKills, rescues, squadVolleyDone) all require a **teammate**
— structurally impossible in 16-solo, same cause as the census's dead
`dWipe`/`dDuoDown`/`dTagBack`. treeSpray/treeGrenade (all 5 each) are
**not** structurally blocked in BR — they're dead because nobody in this
population landed a spray or grenade kill at all, matching the census's own
`dSprayKill`/`dGrenadeKill` deed finding (0 mints) exactly — the same
underlying behavioral fact, seen from the achievement side too.

**Tier I/II mint but pay nothing**: `RecutTierClass[0]=RecutTierClass[1]=1`
(glory.nim:2555) — a x1 factor never enters the product
(`census_decode.py`'s own fold rule is `if amount>1`). 2,534 of 7,771 total
achievement mint *events* (32.6%) are tier I/II and are score-inert by
construction — real, logged, but multiplicatively invisible. This
reproduces the 2026-09-06 memory finding ("tiers I/II fold nothing at
all") on a different, independent population.

## Q2 — Log2-magnitude share of the product: achievements vs deeds

Same log2-share convention the census used for its 42.2%/44.6% recipe
figure (`log2(factor) / log2(final_score)`).

| population | n | mean share | median share |
|---|---:|---:|---:|
| whole population | 4,880 | **60.3%** | **50.0%** |
| top decile (p90 threshold=576, same as census Q4) | 509 | **18.0%** | **9.8%** |

**Achievements dominate the FLOOR, not the top.** Every seat-episode gets
Clean Sheet's guaranteed x2 for free (barring a team-kill, 0.66% of
episodes), so achievements supply roughly half the bit-length of a
median/low score almost by default. At the top decile that share collapses
to a median of one-tenth — the deed-side recipe (closing_time x jointact x
win8, the census's 42.2%/44.6% figure) and the placement ladder
(`dFinal8/4/2`) do the heavy lifting once a score is large. This is an
**inversion**, not a confirmation, of an "achievements drive the jackpot"
framing.

## Q3 — Does achievement stacking explain the top-decile remainder? Testing "the x24 was achievements"

- The exact **x24 mechanism from the 2026-09-06 memory is CONFIRMED
  present in this independent population**: Clean Sheet (treeSquad.IV,
  x2) x a tier-V FIRST claim (treeGun.V only — no other tree ever reaches
  tier V in this population — x4 base x AchievementFirstMultPct 300% = x12)
  = **24**, observed as the exact `ach_product` value in **135/509 (26.5%)**
  of top-decile seat-episodes — every single top-decile row with a tier-V
  first claim hits exactly 24 (the two counts match precisely; no other
  achievement ever stacks alongside it in the top decile).
- But that confirmed x24 factor explains only a **median 9.8% / mean 18.0%**
  of a top-decile score's log2-magnitude (Q2). Added to the census's
  already-measured deed-recipe share (mean 42.2% / median 44.6%),
  achievements + recipe together cover roughly **mean ~60% / median ~54%**
  of a top-decile score's bit-length — leaving a **~40-46% remainder still
  unexplained** by either named mechanism, consistent with the census's own
  attribution of the residual to combat-generic deed stacking
  (`dHonorableKill`, `dFirstBlood`, `dLongshotKill`) and the near-universal
  `dFinal8/4/2` placement floor.
- **VERDICT: REFUTE "the x24 was [what explains] the top" as a top-decile
  driver; CONFIRM the x24 mechanism itself is real and reproducible.** The
  2026-09-06 memory's "24x" was a **decode-gap** finding (why an early
  decoder undercounted a specific episode's product by exactly that
  factor) — that mechanism checks out byte-for-byte here too. It was never
  a claim that achievements are what makes today's top decile large; on
  this population's evidence, achievements are proportionally a much
  bigger piece of the FLOOR than of the jackpot.

## Q4 — Tier structure (`RecutTierClass`, not `RecutClassTable`)

| tier | class factor | total mints | % of all achievement mints | fires in % of seat-episodes |
|---|---:|---:|---:|---:|
| I | x1 (no-op) | 2282 | 29.4% | 46.76% |
| II | x1 (no-op) | 252 | 3.2% | 5.16% |
| III | x2 | 5 | 0.1% | 0.10% |
| IV | x2 | 4880 | 62.8% | 100.00% |
| V | x4 (+ x3 FIRST, tier V only by law) | 352 | 4.5% | 7.21% |

FIRST-claim bonus fires on 211/4,880 seat-episodes (4.32%) — **always**
on `treeGun` tier V (Sharpshooter/longshot-kill), since no other tree ever
reaches tier V in this population; 211/352 (59.9%) of everyone who reaches
tier V wins the first-claim race.

**Nearly two-thirds (62.8%) of every achievement mint in this population
is the single universal Clean Sheet freebie.** Excluding the two no-op
tiers (I/II), the entire achievement axis reduces to exactly THREE
score-moving gates: Clean Sheet (universal x2), Ace (x2, 0.1% — vanishingly
rare), Sharpshooter (x4, +x3 first, 7.21% — the only real skill-gated
jackpot leg).

## Design input carried, not designed here

The lead's S4 framing: "achievements = tier-2 named modes/sets that pay a
multiplier when completed" (pinball's drop-target-bank analogy). Measured
reality **partially supports this for exactly one achievement**
(Sharpshooter: skill-gated, real multiplier, meaningfully rare) but does
**not** describe the catalog as a whole — 87.5% of slots never fire at
all in this population (mostly structural: engine-omitted, flag-gated on a
flagless mode, or teammate-gated in 16-solo), and a further 32.6% of all
mint *events* pay a x1 no-op. The measured catalog today is closer to "one
universal participation stamp (Clean Sheet) + one narrow skill spike
(Sharpshooter) + 35 non-functional slots" than to a bank of lightable modes.
No new constants proposed — this is a measurement, not a redesign.

## What is NOT verified

- **Population inherits every S1 census caveat** (p99.9 ~5-sample tail,
  round-target miss at 24/200, gunRange not exposed by the extractor) —
  this addendum adds no new sampling, so no new caveats on the population
  itself.
- **`treeSpray`/`treeGrenade` zero-mint is a behavioral finding, not a
  code-reachability claim** — nothing here proves these are unreachable in
  principle, only that nobody in this specific 305-episode window landed a
  qualifying kill with those weapons (matches the census's identical
  finding on the corresponding deeds).
- **`secondWind` gate (`treeShield` tier IV) was read from source
  (`player.secondWind`) but its exact trigger condition was not traced
  beyond the field name** — it did not fire in this population regardless,
  so the mint-rate measurement is unaffected either way.
- **Single population, single era** — no comparison run against a
  different GloryVersion/era was performed; "the x24 was achievements"
  verdict is scoped to THIS population only, as instructed.
- Cross-check reconciles the SPLIT against the census's OWN reconciled
  number (100.00%, 4880/4880) — it does not re-derive reconciliation
  against the platform's `participant_scores` independently; that
  validation is the census's, inherited here, not repeated from scratch.

## Evidence paths

- New scripts (this branch, `maxwell/glory-achievements`):
  `tools/glory/census_achievements.py`, `tools/glory/census_achievements_analyze.py`.
- Reused unmodified from `maxwell/glory-census`: `tools/glory/{discover_cohort,census_decode,census_analyze}.py`.
- Reused cached data (not committed, produced by the census, `/tmp` is
  ephemeral): episode replay cache
  `~/.ctf/scout/glory_census_replays/*.{replay,jsonl}` (612 files, 305
  episodes' worth); validated ground truth
  `/tmp/glory-census/seat_episode_rows_final.json` (4,880 rows).
- This addendum's raw output: `/tmp/glory-achv/achievement_rows.json`
  (4,880 decomposed rows), `/tmp/glory-achv/decompose_run.log` (0
  split-vs-combined mismatches), `/tmp/glory-achv/analyze_run.log` (full
  numeric output this document summarizes).
- Source citations: `src/ctf/glory.nim:1782-1930` (Tree enum,
  AchievementTrees/Tiers, TierGlory, RecutTierClass, AchievementFirstMultPct),
  `src/ctf/glory.nim:2555` (`RecutTierClass = [1,1,2,2,4]`),
  `src/ctf/sim.nim:511-568` (`claimAchievement`, event emission),
  `src/ctf/sim.nim:578-699` (`satisfiedAchievements`, `UnattainableAchievementTiers`).
