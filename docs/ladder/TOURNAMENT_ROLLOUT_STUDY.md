# Can we replace the CTF tournament with Monte Carlo rollouts?

**Status:** DRAFT — methodology fixed, findings pending
**Source:** Asana `1217201474450553` (Paintbot board, `1 · Scoped`, Layer: League & Campaign Ops).
Raised by daveey in Discord `#game-of-the-week`: *"it seems like for CTF we don't actually need
to run the tournament, we could use historical 1v1 scores between each policy in the roster,
and just run monte carlo rollouts?"*
**Scope:** CTF only. Explicitly NOT the BR / main league — BR episodes are 16-way, so they have
no pairwise 1v1 structure to roll out and none of this transfers.

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
  seed-order (Elo rank), so the number means something.
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

The current CTF ladder ranks by **Elo** — a single scalar. A scalar ranking provably *cannot*
represent non-transitivity (rock-paper-scissors cycles among policies), and RL policy
populations are a classic home for exactly that. The **full pairwise matrix is strictly more
expressive than the Elo leaderboard we already publish.**

So building the matrix is worth doing *even if we keep running the tournament* — it is a better
instrument than the ranking currently on the board. That decouples the cheap, high-value half
of this work (build and publish the matrix) from the contested half (stop running the bracket).

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
₀ — there is no spend to recover.** The live decision is the reverse of the one asked: *should we
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

# RECOMMENDATION

**Directionally right, already built, wrong premise, and the real risk is elsewhere.**

- ✅ **Sound in kind.** CTF episodes genuinely are pairwise — 8v8, 16 seats, exactly two scored
  policies per episode — so the 1v1 matrix daveey assumes really does exist. The method is
  standard and validated practice elsewhere (§6).
- ✅ **A rollout is more informative than a bracket.** It reports `P(champion)` over the whole
  field with intervals; a bracket reports one sample.
- ❌ **The motivating economics are absent.** The proposal saves tournament episodes. We run no
  tournaments (**F2**), so the saving is zero. The decision it actually bears on is whether to
  *finish* live tournaments (spec 0073), not whether to stop them.
- 🚨 **The live risk is unvalidated trust.** A shipped, user-facing simulator has never been
  checked against reality (**F5**) and ships a `sufficiency` badge that measures precision, not
  correctness (**F4**). "Insufficient/marginal/sufficient" will be read as a correctness verdict.
  That is the thing to fix, and it is fixable cheaply.

**So: do not build a simulator. Validate the one that shipped, then decide.**

---

# EXECUTION PLAN

Each phase has a gate. Stop and report at every gate — several can end the work early.

### Phase 0 — Density census + intransitivity  *(≈half a day; answers the task's "Done when" #1)*
Build the CTF pairwise matrix from banked ladder episodes via the shipped
`matrix.load_pairwise_matrix`, and report, era-stamped by `coworld_version`:
fill rate; **per-pair sample counts as a distribution, not a mean**; fill as a function of Elo gap
(the §4.2 bias probe); **comparison-graph connectivity** (a hard gate — disconnected components are
not comparable at all, §6); the `episodes_skipped` count and why; the raw draw rate (F3-B); and the
3-cycle census (**F7**).
**Gate:** if the graph is disconnected or median per-pair `n` is tiny (SE ≈5pp at n=100), report
that and stop — nothing downstream can be trusted, and this alone answers a chunk of the task.

### Phase 1 — Episode-level calibration back-test  *(≈1–2 days; the core)*
Implement **F6**: temporal hold-out within one engine era, score Brier/log against the uniform,
Elo, and BT baselines, plot the reliability diagram, report sharpness alongside calibration, and
stratify by Elo gap and by observed-vs-BT-filled pairs.
**Gate — the kill criterion:** if the matrix does not beat the live Elo baseline out-of-sample,
the idea adds nothing over the leaderboard we already publish. Say so plainly and stop.

### Phase 2 — Sufficiency audit + defect reports  *(≈half a day)*
Cross-tabulate the shipped `sufficiency` verdict against measured out-of-sample calibration. Any
configuration graded `"sufficient"` while miscalibrated is a defect against a live feature.
Deliverables: a PR relabelling the verdict to what it measures (e.g. `estimate_precision`) with the
scope stated in the API response and UI, plus filed bugs for the draw gap (F3-B) and, if it bites,
the fabricated cold-start strength (F3-A).
*This phase is worth doing on its own merits even if Phase 1 fails its gate.*

### Phase 3 — The decision memo  *(≈half a day)*
One page to daveey and the league owners, stating the purpose assumption explicitly (§3):
whether to finish spec 0073's live tournament wiring at all; whether rollout output should be
published as CTF standings; and, if F7 found significant cycles, whether standings should move to
Nash averaging / α-Rank instead of Elo **or** a simulated bracket.

### Phase 4 — *conditional* — bracket-free ranking  *(only if F7 finds cycles)*
Implement Nash averaging (Balduzzi 2018) and α-Rank (Omidshafiei 2019) over the same matrix and
compare all three rankings — Elo, simulated-bracket, bracket-free — on the same held-out episodes.

### Explicitly out of scope
BR / the main league (16-way, no pairwise structure); any change to a live league without a
recorded owner GO; finishing spec 0073's Temporal wiring (that is the *outcome* of Phase 3,
not part of this study).

### Risks
- Data window may be one `coworld_version` deep (default `coworld_version_min="latest"`), which
  could make Phase 1's hold-out too thin. Mitigation: widen `version_min` and treat era as a
  covariate, reporting the cross-era stability check (§4.1) as a first-class result.
- `tournament_sim` is owned by the platform team, not this lane. Phase 2's PR touches their
  surface — coordinate before landing.
