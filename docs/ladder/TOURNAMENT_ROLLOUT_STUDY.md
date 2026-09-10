# Can we replace the CTF tournament with Monte Carlo rollouts?

**Status:** COMPLETE — verdict and plan below. Research done 2026-09-09; all live API figures
measured that day and era-stamped by division. Read the **VERDICT** and **EXECUTION PLAN** at the
end first; §1–6 are the framing, F1–F12 the evidence.
**Source:** Asana `1217201474450553` (Paintbot board, `1 · Scoped`, Layer: League & Campaign Ops).
Raised by daveey in Discord `#game-of-the-week`: *"it seems like for CTF we don't actually need
to run the tournament, we could use historical 1v1 scores between each policy in the roster,
and just run monte carlo rollouts?"*
**Scope:** **CTF (now the `Campaign` league) and Elite Paintbot** — the two Paintbot divisions in
question. Explicitly NOT the BR / main league: Paintbot S2 and Battle Royale episodes are 16- and
12-way free-for-alls, so they have no pairwise 1v1 structure and none of this transfers.

---

## 1. The proposal, restated precisely

The claim bundles **three** independent propositions. They have different answers, and the
value of this study is mostly in separating them.

- **P1 — Estimation.** The pairwise win probability `p(i beats j)` for every roster pair that
  matters can be estimated from already-recorded ladder episodes, precisely enough to be useful.
- **P2 — Sufficiency.** The tournament's *result* is a deterministic function of the pairwise
  matrix plus the bracket structure plus randomness. Nothing enters the tournament that is not
  already in the matrix.
- **P3 — Substitution.** Therefore publishing rollout output is an acceptable replacement for
  running the bracket.

P1 is an empirical question about data density — measurable, and the cheapest to settle.
P2 is close to true *by construction* for frozen policies, with named leaks (§4).
**P3 does not follow from P1 and P2**, and that is the crux of this study.

## 2. The category error to avoid (this drives the whole design)

The Asana task asks: *"Does the simulated bracket reproduce the actual bracket on tournaments
already run?"* — and asks for agreement at the winner, the final, and the top four.

**Agreement is the wrong metric, and using it would likely reject a correct method.**

A real tournament is **one draw** from a distribution. A Monte Carlo rollout *is* the
distribution. They are different mathematical objects, and asking whether a distribution
"equals" a sample is a category error. Concretely: if the true favourite wins a 20-entrant
bracket 30% of the time, then a *perfect, oracle-accurate* simulator predicts the real winner
only 30% of the time. A 30% "accuracy" headline would read as failure while describing a
flawless model.

The correct question is **calibration**: over many tournaments, do outcomes assigned probability
*p* happen about *p* of the time? That is measured with proper scoring rules and calibration
tests, never with agreement:

- **Log score / Brier score** on the champion distribution, and separately on each
  "does X reach the final four" binary — scored against two baselines, uniform and
  seed-order (the division’s published standing), so the number means something.
- **Reliability diagram / PIT-style rank histogram** — bucket every predicted probability,
  plot realised frequency. A well-calibrated forecaster sits on the diagonal.
- **Per-stage**, as the task asks — but stated as calibration per stage, not agreement per stage.

**This inverts one branch of the conclusion.** If the tournament turns out to be high-variance —
if the bracket is largely a coin-flip machine that a near-perfect model still cannot predict —
that is not evidence against rollouts. It is evidence that *the tournament is a noisy
instrument*, and that a rollout reporting `P(champion)` over the field is strictly **more
informative** than one bracket run. The weaker the agreement, the stronger the case that the
bracket was never a measurement in the first place.

## 3. What the tournament is *for* — the question behind the question

P3 cannot be settled with statistics, because it depends on the tournament's purpose:

- **If the tournament is MEASUREMENT** ("which policy is best?"), then rollouts very likely
  dominate it on information-per-episode, and the honest recommendation is to stop running it
  as a measurement device.
- **If the tournament is SPECTACLE / legitimacy** (it is the `#game-of-the-week`; people watch
  it; a champion crowned by a simulation is not a champion), then no amount of calibration
  justifies replacing it, and the correct move is a *cheaper* tournament, not no tournament.

These give opposite answers, so the study must report the episode cost and the information
content separately, and let the purpose decide. A recommendation that does not name the
purpose it assumes is not a recommendation.

## 4. Named leaks in P2 — what a rollout cannot see

Each is a falsifiable, measurable risk, not a hand-wave. The study measures the ones marked ★.

1. **★ Engine churn (the biggest one).** Policies are frozen binaries, so `p(i>j)` *should* be
   stationary — a real advantage over human sports, where form drifts. But the hosted coworld
   build churns every few days, and a GameVersion bump changes the game the policies are
   playing. History that straddles a bump is history of a *different game*. Any matrix must be
   era-stamped by GameVersion, and the study must check whether `p(i>j)` is stable across a
   bump for the same pair.
2. **★ Matchmaking selection bias.** Ladder pairing is not random — it pairs similar ratings.
   So the missing cells are not missing at random; they are exactly the extreme mismatches.
   Fill rate alone hides this; the study reports fill *as a function of rating gap*.
3. **★ Clustered observations.** Episodes within a round share a map/seed, violating the
   independence that naive confidence intervals assume. Intervals must be clustered by
   round/map or they will be too narrow, and the matrix will look more certain than it is.
4. **★ Map/seed dependence.** If `p(i>j)` swings by map and the tournament's map distribution
   differs from the ladder's, the historical marginal is the wrong estimand. (We have already
   measured, in a neighbouring setting, that the winner varies by seed.)
5. **Cold start.** A policy uploaded the day before has no history. This is the leak with no
   statistical fix — only a prior. Mitigation is hierarchical shrinkage toward a Bradley-Terry /
   Elo prior, which *degrades gracefully* rather than failing, but a rollout will always be
   least trustworthy exactly where interest is highest: the new challenger.
6. **Roster composition.** A rollout answers about the roster it was given. A tournament can
   surface a policy that was never on the leaderboard.

## 5. A point in David's favour the proposal undersells

Whatever we rank by today is a **single scalar** — and a scalar ranking provably *cannot* represent
non-transitivity (rock-paper-scissors cycles among policies), which RL policy populations are a
classic home for (§6, Czarnecki et al. 2020). The **full pairwise matrix is strictly more expressive
than the leaderboard we already publish**, whichever scalar that leaderboard uses.

So building the matrix is worth doing *even if we keep running the tournament* — it is a better
instrument than the ranking currently on the board. That decouples the cheap, high-value half
of this work (build and publish the matrix) from the contested half (stop running the bracket).

> **Measured, and it changes the baseline** (`GET /v2/leagues/{id}`, 2026-09-09): the two divisions
> in scope do **not** rank by Elo. **Campaign (= CTF)** uses `ladder.ranking.algorithm = "score"`
> (`direction: maximize`, `standing_aggregation: max`, `round_scoring_rule: mean`) and has
> `ladder.enabled = false`. **Elite Paintbot** exposes **no ladder settings at all** (`{}`). Elo
> belonged to the retired CTF league. Phase 2's out-of-sample baseline must therefore be *the
> standing actually published for that division*, not Elo — a max-aggregated score standing is a
> considerably weaker baseline to beat, which makes the comparison more favourable to the matrix,
> not less.
>
> ⚠️ Filing-worthy while reading this: the Campaign league's `ladder.divisions` points at
> `div_aa7825db…` — **Paintbot S2's division** — with `variant_rotation: ["battle-royale-s2"]`,
> not its own `div_254a3613…`. With `ladder.enabled = false` nothing is driven by it, so this reads
> as a stale templated config rather than live misrouting, but it should be confirmed by whoever
> owns the league.

## 6. Prior art — what the literature already settles

**The calibration point is established, not my opinion.** Probabilistic forecasts are validated
with proper scoring rules and calibration/sharpness, not agreement: Brier (1950); Gneiting,
Balabdaoui & Raftery, *JRSS-B* (2007). FiveThirtyEight's NCAA bracket model — the canonical
public instance of exactly daveey's method — validates itself by calibration across many
bracket-years ("70% favourites won ~70% of the time"), never by single-tournament agreement.
§2 stands.

**If the goal is standings, simulating a bracket is the wrong target.** Given a full pairwise
matrix, the multi-agent-RL evaluation literature offers *bracket-free* rankings that dominate it:
- Balduzzi et al., **"Re-evaluating Evaluation"**, NeurIPS 2018 (arXiv:1806.02643) — single-number
  Elo collapses under intransitive populations and is schedule-dependent and gameable by
  redundant near-clones; **Nash averaging** over the antisymmetric win matrix is invariant to
  duplicate agents.
- Omidshafiei et al., **α-Rank**, *Scientific Reports* 2019 (arXiv:1903.01373) — polynomial-time
  evolutionary ranking over the full empirical game; handles cycles via limit cycles.
- Czarnecki et al., **"Navigating the Landscape of Multiplayer Games"**, 2020 (arXiv:2005.01642) —
  real trained-policy populations measurably have cyclic "spinning top" structure alongside
  transitive skill.

A bracket simulation only earns its keep when you need the outcome *of a named bracket with a
named seeding*. For "who is best", it deliberately re-injects the seeding artifacts and
single-elimination noise that the matrix had already removed.

**Density requirements are quantified.** Bradley-Terry MLE is consistent on sparse comparison
graphs **provided the graph is connected** (Bradley & Terry 1952; Simons & Yao 1999) — disconnected
components are simply not comparable, which makes connectivity a hard gate, not a quality metric.
Per-cell precision is binomial: SE ≈ 5pp at n=100, ≈2.5pp at n=400. Chess-engine practice
(Stockfish fishtest / SPRT) needs 500–1000 games to resolve a >30-Elo gap reliably. Cold start is
handled by shrinkage: Glicko (Glickman 1999) seeds at 1500 with RD 350; Whole-History Rating
(Coulom) uses a Bayesian virtual win+loss prior and refits jointly.

**Matchmaking bias has a name and a remedy.** Rating-matched pairing makes the rank-decisive
top-vs-bottom cells missing-not-at-random; correcting Swiss-pairing bias needs propensity-style
adjustment (arXiv:2410.19333). Filling those cells by BT extrapolation is *interpolation, not
measurement*, and must be labelled as such.

**The hybrid has literature behind it.** Best-arm identification is the right frame for spending
a limited episode budget: successive halving / successive rejects, Hoeffding Races (Maron & Moore,
NeurIPS 1993), preference-based racing for RL policy selection (Busa-Fekete et al., *Machine
Learning* 2014). Directly on point: **"Best Agent Identification for General Game Playing"**
(arXiv:2507.00451, 2025) converges on the best game-playing agent in far fewer games than a full
pairwise tournament or round robin.

> Caveat carried from the research pass: map-seed clustering is treated by analogy to
> cluster-robust SE / GEE (Liang & Zeger 1986); no directly-matched esports-ratings citation was
> found. Treat as standard applied practice, **unverified** in this specific domain.

---

# FINDINGS

## F1. The feature daveey proposed already exists and is on `main`

`tournament_sim` is a shipped module, not a hypothesis. On metta `origin/main`:

| Piece | Path |
|---|---|
| Rollout engine (853 lines) | `app_backend/src/metta/app_backend/v2/tournament_sim/engine.py` |
| Pairwise matrix builder (358 lines) | `app_backend/src/metta/app_backend/v2/tournament_sim/matrix.py` |
| API route | `app_backend/src/metta/app_backend/v2/routes/tournament_sim.py` |
| Tests | `app_backend/tests/v2/test_tournament_sim_{engine,matrix,route}.py` |
| Observatory UI | `web/softmax.com/src/app/(observatory)/observatory/v2/details/TournamentSimDetail.tsx` |

`POST /v2/divisions/{division_id}/tournament-sim` already returns `matrix`, `roster`, `win_model`,
`showcase`, `monte_carlo` and `sufficiency`. It supports `single_elim`, `double_elim`,
`round_robin`, `elimination_rounds`, `evolutionary` (`engine.py:27`, `_RUNNERS` `engine.py:600-606`),
and outputs a **distribution** — `champion_odds`, `p_first`/`p_top3` with Wilson CIs, rank
histograms over `n_sims` (default 1000) — not a single sampled bracket (`engine.py:788-853`).

**So the plan is not "build this."** It is: validate it, feed it well, and decide policy.

## F2. There is no CTF tournament to replace — real tournaments were never wired

The *executed* tournament is a different, unshipped feature. `docs/specs/0073-league-tournaments.md:27-33`
(Status: **In Progress**):

```
- [x] Typed tournament definition with double elimination as default
- [x] Pure, deterministic round generator with idempotent plans
- [x] Roster freeze at lock (`explicit`, `top_n`, `division_all`)
- [x] Placements (rank + optional tiers), not Elo
- [ ] Temporal `TournamentWorkflow` wired to live RoundWorkflow
- [ ] Observatory tournament page
```

Planning logic is done; **live execution and UI are not**. Also note `top_n` accepts `n: 2..256`
(`tournaments/config.py:19-41`) — the "top 20" in the task framing is not a hardcoded fact.

This reframes the question. The premise "we don't need to *run* the tournament" assumes we run
one. We do not, and never have. **The episode-budget saving that motivates the task is therefore
**zero** — there is no spend to recover.** The live decision is the reverse of the one asked: *should we
ever build executed tournaments, given a simulator already exists?*

## F3. The estimator is sound, with two real modelling gaps

Blend of Beta-smoothed empirical rate and a Bradley-Terry fallback:
`p = (w + smoothing)/(w + l + 2·smoothing)`, `smoothing=1.0` (`engine.py:145-165`, `:48`). For a pair
with zero episodes it falls back to BT strengths (`engine.py:152-155`), and the BT fit adds
`eps=0.1` virtual wins in each direction to keep the comparison graph connected
(`fit_bradley_terry`, `engine.py:92-124`) — the connectivity gate the literature requires (§6) is
handled, by fabrication.

**Gap A — cold start is fabricated, not refused.** A policy with zero games against *anyone* still
gets BT strength `1.0` (`engine.py:113`) linked only by those fabricated `eps` wins, so it receives
confident-looking but invented win probabilities. The route flags this separately as
`missing_data_pairs`/`no_data` (`routes/tournament_sim.py:321-325, 513-529`), so the information
exists — but the engine's own default is to make a number up rather than decline.

**Gap B — draws are tallied but never sampled.** Draws are a distinct bucket from mutual losses
(`matrix.py:230-236`) and count toward `n_games`, but `sample_game` can only return
`WIN_A`/`WIN_B`/`MUTUAL` — the module docstring says outright that sampled games never produce a
draw (`engine.py:12-14`). If CTF draws are non-negligible, the rollout is simulating a game whose
outcome space differs from the real one.

**Handled well:** era-stamping. Tallies are split per `coworld_version` (`matrix.py:195-201`) and
default to `coworld_version_min="latest"` (`routes/tournament_sim.py:87-93`), so the engine-churn
leak (§4.1) is closed *by default* — at the cost of shrinking the usable window to one build.

**Not handled:** no recency weighting, and no de-duplication or clustering by round/map seed —
every episode in the window counts once and independently (`matrix.py:204-250`), so §4.3 stands.

## F4. The critical finding: `sufficiency` measures precision, not correctness

`sufficiency_analysis` (`engine.py:674-785`) resamples `sufficiency_draws` (default 24) posterior
worlds, reruns 150 mini-tournaments each, and grades:

```
if champion_agreement < 0.7 or bt_contender_pairs > 0:      "insufficient"
elif champion_agreement >= 0.9 and top_half_width <= 0.07:  "sufficient"
else:                                                        "marginal"
```

This is a genuinely good internal-stability check, and it even emits `weak_pairs` with
`additional_games_needed` per pair (`engine.py:722-754`, Wilson-CI based). **But it answers "is my
win model precisely estimated?", not "is my win model right?"** The docstring concedes the scope
(`engine.py:687-689`). A systematically wrong model — wrong because of matchmaking bias, map
skew, or the draw gap above — returns **`"sufficient"` with high confidence**.

That is a live footgun: a verdict string reading `sufficient` next to a champion prediction will
be read by everyone as "this result is trustworthy."

## F5. It has never been validated against reality

Repo-wide grep for `backtest`, `calibrat`, `ground truth`, `actual outcome`: **ABSENT**. Both test
files are mechanical or synthetic — determinism under seed
(`test_tournament_sim_engine.py:146-149, :311-314`), bracket structure/byes/grand-final counts
(`:159-224`), Beta-smoothing arithmetic against hand-computed fractions (`:48-78`), a synthetic
"dominant hierarchy" fixture recovering the expected order (`:33-39, :151-156`), and matrix
tallying/caching mechanics. `tournament_sim` has no spec document at all.

Nothing anywhere compares a prediction to a real outcome or measures calibration.

**This — not the matrix, not the rollout — is the gap worth our episodes.**

## F6. The back-test the task asks for is impossible — and unnecessary

The Asana task's Verify section says: *"pick tournaments that have already run, build the pairwise
matrix from data available before each one, roll it out, and compare."* Per **F2, the number of CTF
tournaments that have ever run is zero.** There is nothing to back-test against, and there never
will be enough — even once wired, a weekly tournament yields ~52 samples a year, which is far too
few to establish calibration (§2, §6).

**The unlock: the unit of back-test is the episode, not the tournament.**

A tournament simulation is exactly two things bolted together:

1. **A win model** — `p(i beats j)`. Statistical, and the only part that can be wrong about reality.
2. **Bracket combinatorics** — given `p`, how a bracket resolves. Pure deterministic bookkeeping,
   and *already covered* by the existing mechanical tests (`engine.py` bracket tests, F5).

Part 2 is verified. So **validating the simulator reduces to validating the win model**, and a win
model is validated against *episodes*, of which the ladder produces thousands per day and has
already banked thousands more. No tournament required.

### The design

**Temporal hold-out on the ladder.** Choose a cut time `T` inside a single `coworld_version` era.
Fit the matrix on episodes before `T`, using exactly the shipped estimator
(`WinModel`, `engine.py:145-165`). Predict every episode after `T`. Score:

- **Brier and log score** on `P(A beats B)` per held-out episode, against three baselines:
  (i) uniform `p=0.5`, (ii) the live Elo leaderboard's implied probability, (iii) the shipped
  BT fit. If the matrix cannot beat Elo out-of-sample, daveey's idea adds nothing over the
  ranking already on the board — a clean, decisive kill criterion.
- **Reliability diagram** — bucket predictions by decile, plot realised win frequency. This is
  the headline artifact and the one that answers "can we trust it".
- **Sharpness** — a calibrated-but-useless forecaster predicts 0.5 forever. Report calibration
  *and* sharpness together (Gneiting et al. 2007), never calibration alone.

**Then stress exactly the leaks §4 named, using the same score:**

- **Matchmaking bias (§4.2).** Score held-out episodes *stratified by Elo gap*. If calibration
  is good for near-rating pairs and bad for wide-gap pairs, the rollout is unreliable precisely
  in the mismatches an elimination bracket is made of. This is the highest-prior-probability
  failure in the whole study.
- **BT-filled cells (§4.5 / F3-A).** Score held-out episodes whose pair was *unobserved* before
  `T` separately from observed pairs. This directly measures whether the `eps=0.1` fabrication
  is honest, and is the only way to price cold start.
- **Clustering (§4.3).** Recompute intervals clustered by round/map; report how much they widen.
  This quantifies the overconfidence `sufficiency` currently cannot see.
- **Draw gap (F3-B).** Report the raw draw rate. If it is non-negligible, the rollout's outcome
  space is wrong and that is a bug to file.

**Finally, audit the `sufficiency` verdict itself (F4).** For each hold-out configuration, record
what `sufficiency` claimed and what the out-of-sample score actually showed. If it ever says
`"sufficient"` on a configuration that is out-of-sample miscalibrated, that is the headline
finding of this study and a defect report against a shipped, user-facing feature.

## F7. The cheap measurement that decides whether any of this beats Elo

Before any rollout work: **measure how intransitive the CTF policy population actually is.**

Count 3-cycles in the empirical matrix (A>B, B>C, C>A, each significant against the clustered
interval), and report the fraction of significant triads that are cyclic versus the fraction
expected by chance. Fit BT and report residual structure.

This is one query over data we already have, and it splits the outcome cleanly:

- **If the population is near-transitive**, Elo is an adequate summary, the matrix adds little
  ranking information beyond what the leaderboard already shows, and rollout output should be
  treated as a convenience view rather than a better instrument.
- **If cycles are significant** (which Czarnecki et al. 2020 found is common in trained-policy
  populations — §6), then the Elo leaderboard is *actively misleading*, the matrix is the correct
  object, and the right ranking is Nash averaging or α-Rank — **not** a simulated bracket, which
  re-injects seeding artifacts the matrix had already removed.

Note this measurement is worth making regardless of what we decide about tournaments, and it is
the one result here that could change what the public CTF standings *are*.

---

# EMPIRICAL RESULTS (measured live, 2026-09-09)

## F8. The two divisions in scope: Campaign (= CTF) and Elite Paintbot

**CTF is now the `Campaign` league** (owner, 2026-09-09). That resolves the naming: no live league
or division carries the string "CTF" — all 158 divisions are named `Competition` (132),
`Qualifiers` (19) or one of seven one-offs, and `tools/ladder/ctfapi.py:20-21`'s old
`LEAGUE`/`COMPETITION_DIV` constants are dead. Exactly three leagues run the Paintbot game, each
with exactly one division (verified **authenticated**, so this is not a public-visibility artifact):

| League | Division | In scope |
|---|---|---|
| **Campaign** (= CTF) | `div_254a3613…` | ✅ |
| **Elite Paintbot** | `div_ed510662…` | ✅ |
| Paintbot (Season 2) | `div_aa7825db…` | ❌ `is_game_of_week: true`, plays BR — excluded |

> Correction logged: an earlier draft treated **Paintarena** as a CTF-shaped Paintbot division and
> drew conclusions from it. Paintarena is a **separate game** (`game.coworld_name = "paintarena"`).
> Those findings are withdrawn.

## F9. Episode shape — only one of the two is genuinely pairwise

Measured on real rounds, counting distinct scored policies per episode:

| Division | Seats | 2 policies | 4 policies | 0 policies | Sample |
|---|---|---|---|---|---|
| **Campaign (= CTF)** | 16 | **86.6%** | 0.9% | 12.4% | n=426 |
| **Elite Paintbot** | 16 | **48.8%** | **43.5%** | 7.8% | n=400 |
| Battle Royale | 12 | — | — | — | 12-way FFA |
| Paintbot (S2) | 16 | — | — | — | 16-way FFA |

`tournament_sim`'s matrix builder requires **exactly two** scored policies, else `episodes_skipped++`
(`matrix.py:222-225`). So the usable fraction is the "2 policies" column:

- **Campaign loses 13.4%**, and almost all of that is *dead episodes* that scored nothing — a bug to
  chase, not a modelling limit. Its data is structurally clean: a Campaign episode is a true 8v8
  policy-A-vs-policy-B duel, exactly what daveey's proposal assumes.
- **Elite loses 51.2%**, and that loss is *structural*. Elite is the 2v2 partner lottery: in 43.5%
  of its episodes the competing unit is a **coalition**, not a policy. "A partnered with B beat
  C partnered with D" **cannot be written in a policy-vs-policy matrix at all.** No quantity of
  extra episodes fixes it, and the discarded half is precisely the partnership effect Elite exists
  to test.

> A rollout over Elite Paintbot is silently built from **under half that league's own history**,
> with no warning to the caller.

## F10. Density census — the answer to the task's "Done when" #1

Via `GET /v2/divisions/{id}/pairing-matrix` (authenticated). For both divisions `games_together`
counts genuine head-to-head games, so these figures are exact rather than a proxy.

| | **Campaign (= CTF)** | **Elite Paintbot** |
|---|---|---|
| Policies | 30 | 51 |
| Pairs observed | 374 / 435 = **86.0%** | 1120 / 1275 = **87.8%** |
| Total games | 26,519 | 80,987 |
| **Median games / pair** | **20** | **66** |
| **Binomial SE per cell** | **±11.2 pp** | **±6.2 pp** |
| Graph connected (all pairs) | ✅ [30] | ✅ [51] |
| Connected at n ≥ 30 | ✅ **[30]** | ❌ **[45,1,1,1,1,1,1]** |
| Connected at n ≥ 100 | ❌ [26,1,1,1,1] | ❌ [43, 1×8] |
| Connected at n ≥ 400 | ❌ [18, 1×12] | — |
| Pairs under 400 games | 354 / 374 | 1069 / 1120 |
| Usable episodes (F9) | 86.6% | 48.8% |

**Neither division can carry a bracket today, and the reasons are different — which matters.**

- **Campaign's problem is curable.** It is connected at n ≥ 30, and its data is structurally clean.
  It is simply thin: 20 games per pair gives ±11.2 pp, so a 55/45 matchup is indistinguishable
  from 45/55 — and elimination brackets turn on exactly those near-even pairs. More episodes fix
  this.
- **Elite's problem is not.** It has 3× the games per pair, but its well-measured subgraph
  **fragments** (six policies fall out at n ≥ 30, eight at n ≥ 100) — and connectivity is
  Bradley-Terry's *hard* gate (Bradley & Terry 1952; Simons & Yao 1999), not a quality knob. On top
  of that, half its episodes are structurally unrepresentable (F9).

The shipped engine hides the fracture rather than reporting it: unobserved pairs fall back to BT
strengths built on `eps=0.1` fabricated virtual wins (`engine.py:92-124, 152-155` — **F3-A**).

**Conclusion for the roadmap: if we want rollouts to work, Campaign is the division to invest
episodes in.** Elite would need a coalition-level model, which is a different piece of software.

## F11. The budget — priced with the platform's own calculator

`POST /v2/divisions/{id}/power-analysis` already computes episodes needed to detect a given Elo
difference (α = 0.05, power = 0.8). Using the robust `league_pooled` anchor, **1v1-mode games per
pair**:

| Elo gap to resolve | **Campaign needs** | Campaign has | **Shortfall** | **Elite needs** | Elite has |
|---|---|---|---|---|---|
| 200 | 75 | **20** | ~4× | 25 | **66** ✅ |
| 100 | 299 | **20** | **~15×** | 99 | **66** ~1.5× |
| 50 | 1,194 | **20** | **~60×** | 395 | **66** ~6× |
| 25 | 4,773 | **20** | **~240×** | 1,577 | **66** ~24× |

This converts "not enough data" into a number the league owners can accept or refuse. Read plainly:

- **Campaign today resolves only gaps well above 200 Elo.** Bringing every one of its 435 pairs to
  the 100-Elo standard would cost roughly **130,000 episodes** — about **5× its entire recorded
  history** (26,519 games). Restricting the spend to bracket-decisive pairs is the only affordable
  version of this.
- **Elite today resolves roughly a 100–150 Elo gap** — better, but still far coarser than the
  near-even matchups a bracket hinges on, and it cannot use half its own episodes anyway.

> Read the mode split carefully: the calculator reports both `ffa4` and `1v1` sample sizes because
> these divisions contain both. The `1v1` column is the relevant one for a head-to-head matrix.

## F11b. Defects found in passing

- **`pairing-matrix` needs a ~240 s timeout on a large roster.** The stock client timeout gives up,
  so a caller sees an outage rather than a slow success (one attempt returned a 500).
- **12.4% of Campaign episodes and 7.8% of Elite episodes score zero policies** and vanish into
  `episodes_skipped` with no surfaced reason. For Campaign that is nearly all of its data loss.
- `GET /v2/tournaments` returns `[]` globally while the league-scoped call returns records (F12).
## F12. Every tournament ever attempted has failed

Authenticated, live:

| League | Tournaments | Status |
|---|---|---|
| Paintbot (Season 2) | **2** | **both `failed`** — `TournamentWorkflow failed: Activity task failed`, `placements: null` on both |
| Battle Royale | 0 | — |
| Elite Paintbot | 0 | — |
| **Campaign (= CTF)** | **0** | — |

**Zero tournaments have ever produced placements on this platform.** This corroborates F2 from the
other direction: spec 0073's live wiring is unchecked, and the two attempts to run it crashed in
the Temporal activity.

> Inconsistency worth filing: `GET /v2/tournaments?limit=100` returns `[]` while
> `GET /v2/leagues/{s2}/tournaments` returns the two failed records. The global list does not
> surface them.

This inverts the proposal's economics one final time. daveey's question — *"do we need to run the
tournament?"* — presumes a tournament that runs. **We have never successfully run one.** The
simulator is not a cheaper alternative to a working bracket; right now it is the *only* thing that
produces tournament placements at all.

---

# VERDICT

**The reasoning is sound. The premise is not, it is already built, and neither division's data can
carry it today.**

daveey is right on method. Pairwise-matrix Monte Carlo is exactly how this is done elsewhere (§6),
a rollout's distribution genuinely carries more information than one bracket run, and Campaign's
episodes really are clean policy-A-vs-policy-B duels — the 1v1 history he assumes does exist. Four
findings nonetheless mean the proposal cannot be executed as posed:

1. **It is already built** (F1). `tournament_sim` — engine, matrix, route, Observatory UI — is on
   metta `main` and already does Beta-smoothed pairwise rates + a Bradley-Terry fallback + Monte
   Carlo over five bracket structures, returning a champion distribution with Wilson CIs.
2. **There is no tournament being run, and there has never been one that worked** (F2, F12). Two
   have ever been attempted, both crashed in the Temporal activity, and **zero placements have ever
   been produced on this platform.** The episode saving that motivates the proposal is **zero** —
   the simulator is not a cheaper alternative to a working bracket, it is currently the only thing
   that produces placements at all.
3. **Campaign (= CTF) is clean but far too thin** (F10, F11). Structurally ideal — 86.6% of its
   episodes are true 8v8 duels, and its comparison graph is connected at n ≥ 30. But the median
   pair has **20 games (±11.2 pp)**, which cannot separate a 55/45 matchup from 45/55, and
   elimination brackets turn on exactly those pairs. The platform's own power calculator puts it
   **~15× short** of resolving a 100-Elo gap and **~60× short** of 50 Elo.
4. **Elite Paintbot is denser but structurally unfit** (F9, F10). Three times the games per pair
   (±6.2 pp), yet its well-measured subgraph **fragments** — six policies fall out at n ≥ 30,
   eight at n ≥ 100 — and connectivity is Bradley-Terry's hard gate, not a quality knob. Worse,
   it is the 2v2 partner lottery: **51.2% of its episodes are silently discarded** because a
   coalition result ("A+B beat C+D") cannot be written in a policy-vs-policy matrix at all. That
   half is a representational limit; no quantity of episodes will fix it.

**The useful asymmetry:** Campaign's deficiency is *curable* (buy episodes), Elite's is *not*
(needs a coalition-level model, which is different software). If we want rollouts to work,
**Campaign is the division to invest in.**

**And the finding nobody asked for is the one that matters most.** A shipped, user-facing simulator
has **never been validated against reality** (F5) — repo-wide grep for `backtest`/`calibrat`/ground
truth returns ABSENT, and its tests are mechanical or synthetic. It nonetheless reports a
`sufficiency` badge graded *insufficient / marginal / sufficient* which measures whether the win
model is **precisely estimated**, not whether it is **right** (F4; its own docstring concedes the
scope). On both divisions above it will return a confident-looking answer over data that cannot
support one — on Elite, built from under half that league's history. That is the live risk here,
and it is the cheapest thing on this list to fix.

**Recommendation: don't build, and don't back-test brackets. Relabel the badge, surface the
discarded episodes, then validate the win model on episodes — and take the budget number (F11) to
the league owners as the real decision.**

---
# EXECUTION PLAN

**Phases 0, 1, 1b and 3 are done** — 1 and 1b landed as metta PR #22429 (awaiting review; merge needs an owner go).
**Phases 0 and 3 were done in this study** — the density census, episode-shape audit and
the episode budget (F9–F11). The task's "Done when" #1 is answered.

Each remaining phase has a gate; several can end the work early.

### Phase 1 — Relabel `sufficiency` and file the defects — ✅ **DONE: metta PR #22429**
https://github.com/Metta-AI/metta/pull/22429 (open, targets main, +203/-7 across 7 files).
Highest value per hour and independent of every other outcome. A metta PR renaming the verdict to
what it measures (e.g. `estimate_precision`) and stating the scope in both the API response and
`TournamentSimDetail.tsx`: *"measures how precisely the win model is estimated, not whether it
matches reality; never validated against a real tournament."*
Defects to file alongside: draws are tallied but **never sampled** in rollouts (`engine.py:12-14`);
the fabricated `eps=0.1` cold-start strength (F3-A); `pairing-matrix` failing under the default
client timeout on large rosters; zero-score episodes vanishing into `episodes_skipped`; and the
`/v2/tournaments` global-list inconsistency (F12).

### Phase 1b — Surface the discarded episodes — ✅ **DONE: same PR #22429**
Return `episodes_skipped` with its reason breakdown in the API response and render it in the UI, so
a caller can see that a rollout used **48.8%** of Elite's history or **86.6%** of Campaign's. Today
that loss is completely invisible at the call site. Whether Elite should be ranked over *coalitions*
rather than policies is a Phase 5 question, not this one.

### Phase 2 — Episode-level calibration back-test on **Campaign (= CTF)**  *(~1–2 days; the real validation)*
Campaign, not Elite: it is the structurally clean division (F9), so a result there is about the
*method* rather than about coalition leakage. Implement §F6 — temporal hold-out inside one
`coworld_version`; score Brier/log against three baselines — uniform, the division’s **actually published standing**
(Campaign: max-aggregated mean score, NOT Elo — see §5), and Bradley-Terry;
reliability diagram; report sharpness alongside calibration; stratify by Elo gap and by
observed-vs-BT-filled pairs.
**Kill criterion:** if the matrix cannot beat that published-standing baseline out-of-sample, the idea adds
nothing over the ranking already published. Say so and stop.
**Expect this to be hard at ±11.2 pp.** *"The data cannot currently carry a bracket"* is a
legitimate and probably correct answer to daveey's question — and F11 already says what it would
cost to change that.

### Phase 3 — ✅ DONE: the budget (F11)
`POST /v2/divisions/{id}/power-analysis` priced the gap: Campaign is ~15× short of resolving a
100-Elo gap and ~60× short of 50 Elo; bringing all 435 of its pairs to the 100-Elo standard would
cost ~130,000 episodes, about 5× its entire recorded history. **The open question this hands to the
league owners is whether to spend that on bracket-decisive pairs only** — which is the affordable
version, and the one worth designing.

### Phase 4 — Intransitivity census  *(~half a day; the one that could change standings)*
§F7 on Campaign's clean-duel subset: count significant 3-cycles against chance, plus Bradley-Terry
residual structure. If cycles are real, the Elo leaderboard is **actively misleading** and the right
ranking is Nash averaging or α-Rank (§6) — **not** a simulated bracket, which re-injects the seeding
noise the matrix had already removed. Worth doing regardless of any tournament decision, because it
bears on what the published standings should be.

### Phase 5 — Decision memo  *(~half a day)*
One page to daveey and the league owners, stating the purpose assumption explicitly (§3 —
measurement vs spectacle). Three decisions to put in front of them:
1. Given the simulator exists and the Temporal workflow does not, **is it worth finishing live
   tournaments at all?**
2. Do we spend the F11 budget on bracket-decisive Campaign pairs?
3. Does Elite need a **coalition-level** rating model, given half its episodes can never enter a
   policy-vs-policy matrix?

### Out of scope
Paintbot Season 2 / Battle Royale and any FFA division (12- and 16-way — no duel structure, F9);
Paintarena (a different game entirely); any change to a live league without a recorded owner GO;
fixing the Temporal workflow (that is Phase 5's *output*, not its input).

### Ownership note
League + Campaign are **daveey's lane** — Campaign work is explicitly out of scope for the Paintbot
board's router, and this task auto-filed from `#game-of-the-week` on 2026-08-05, inside the
Season-1 window that router was later floored out of (`season2_start = 2026-08-26`). Phases 2, 4 and
5 touch his lane and want his sign-off; **Phases 1 and 1b touch only metta platform code and are
unaffected.**

### Correction log
- **2026-09-09:** an earlier draft treated **Paintarena** as a CTF-shaped Paintbot division and drew
  conclusions from its 27% fill and `[9,1,1,1]` fragmentation. Paintarena is a **separate game**
  (`coworld_name = "paintarena"`); those findings are withdrawn.
- **2026-09-09:** an earlier draft reported that no CTF division could be found. Resolved by the
  owner: **CTF is now the `Campaign` league**. The scope is Campaign + Elite Paintbot.
- **2026-09-09:** `pairing-matrix` was first reported as returning 500 for Elite. It is **slow**,
  not broken — it needs a ~240 s timeout; the stock client timeout makes a slow success look like
  an outage.
