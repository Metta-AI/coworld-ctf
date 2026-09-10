# Meta-research: auto-research loops for the nav throughput programme

Written 2026-09-09 by Claude (peer, tmux `nav-research-peer`); revised after Codex's first-pass
review (`PEER_REVIEW.md`): paraphrased, quotes capped at 25 words per source, unread papers
dropped. Companion: `PEER_PLAN.md`.
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

Each entry says how much of the source was read. Only sources I actually read are listed.

## 1. Sources

### 1.1 AlphaEvolve (Google DeepMind, 2025)
Novikov et al., "AlphaEvolve: A coding agent for scientific and algorithmic discovery",
arXiv:2506.13131, https://arxiv.org/abs/2506.13131. Read: full text (v1 HTML).

The loop is an LLM proposer inside an evolutionary database, driven entirely by automated
evaluators that map a candidate to a set of scalar metrics (section 2.1). Three mechanisms
matter for us. First, an evaluation cascade (section 2.4): candidates face test sets of rising
difficulty and only reach the next stage after passing all earlier ones. Second, they report
that optimising several metrics at once tends to improve the one you care about (section 2.4),
so every run records all metrics even when the hypothesis targets one. Third, when they changed
production infrastructure, every proposed modification was checked against the unmodified code
on randomised inputs (section 3.3.4). The database combines MAP-Elites with island populations
(section 2.5); prompts carry several sampled prior solutions (section 2.2). Their stated
budget regime is that spending on the order of 100 compute-hours per candidate is feasible
(section 2.4). Ablations (section 4) covered the evolutionary loop itself, prompt context,
meta prompts, full-file versus single-function evolution, and model strength.

### 1.2 FunSearch (DeepMind, Nature 2024)
Romera-Paredes et al., "Mathematical discoveries from program search with large language
models", Nature 625, 468-475. https://www.nature.com/articles/s41586-023-06924-6. Read:
abstract and search summary only.

The ancestor of AlphaEvolve: an LLM paired with a systematic evaluator; a database of program
islands where the worst islands are periodically discarded and reseeded from the best; only
programs that pass the evaluator are stored. The transferable point is the same as 1.1: the
evaluator is the source of truth.

### 1.3 OpenEvolve (open-source AlphaEvolve implementation)
https://github.com/algorithmicsuperintelligence/openevolve. Read: README at `main`, 2026-09-09.

What the config exposes: `cascade_evaluation: true` (multi-stage filtering; the README does not
detail thresholds), `num_islands` and `migration_interval`, MAP-Elites feature dimensions with
automatic binning of raw evaluator values, checkpoint directories, and an artifacts side
channel where the evaluator returns metrics plus stderr, profiling data and build warnings that
are fed into the next prompt. Every component is seeded (`random_seed`) for deterministic
evolution across machines. The artifacts idea maps directly onto our per-run directory of
harness JSON, stderr and Fluffy trace.

### 1.4 ShinkaEvolve (Sakana AI, ICLR 2026)
Lange et al., "ShinkaEvolve: Towards Open-Ended And Sample-Efficient Program Evolution",
arXiv:2509.19349, https://arxiv.org/abs/2509.19349; code https://github.com/SakanaAI/ShinkaEvolve.
Read: full text (v1 HTML).

Three sample-efficiency mechanisms (section 3): parent sampling by fitness rank or by a
performance-novelty weight that penalises programs with many offspring; code-novelty rejection
sampling, where a candidate whose embedding is more than 0.95 cosine-similar to an existing
island member must pass an LLM "is this meaningfully different" check before it may consume an
evaluation; and a UCB1 bandit over an LLM ensemble rewarded by improvement over the parent.
They report a state-of-the-art circle packing in about 150 evaluations (section 4.1). Noise
handling is thin: three independent runs per candidate in one experiment (section 4.2). The
transferable idea is the rejection step: do not pay evaluation cost for a near-duplicate of a
prior experiment.

### 1.5 The AI Scientist-v2 (Sakana AI, 2025)
Yamada et al., "The AI Scientist-v2: Workshop-Level Automated Scientific Discovery via Agentic
Tree Search", arXiv:2504.08066, https://arxiv.org/abs/2504.08066. Read: full text (v1 HTML).

An experiment-manager agent runs best-first tree search through four stages with explicit
stopping criteria (section 3.2.1): a minimal working prototype, hyperparameter tuning, the
research agenda, then ablations. Nodes that error are marked buggy and re-selected for repair
with a fixed probability, under a hard cap ("Maximum Debug Depth: 3", Table 3). Replication
nodes exist for statistical measures. Best-node selection is done by an LLM evaluator, which is
the part we must not copy. The limitations section (section 5) concedes workshop-level rigour
and the need for human oversight because of hallucination. The transferable ideas are the
staged search with per-stage exit criteria and the debug cap.

### 1.6 Agent Laboratory (Schmidgall et al., Findings of EMNLP 2025)
arXiv:2501.04227, https://arxiv.org/abs/2501.04227; code
https://github.com/SamuelSchmidgall/AgentLaboratory. Read: full text (v1 HTML).

Pipeline: literature review, experimentation, report writing. The experiment loop (section 3.2)
edits or replaces code in sampled top programs, compiles with up to three repair attempts,
scores with an LLM reward model, and self-reflects. Two findings matter here. Human feedback at
each stage significantly improved quality (abstract; section 4.2). And LLM self-scoring
over-estimated: automated reviews averaged 6.1/10 against 3.8/10 from humans (section 4.1.1),
and one generated paper reported hyperparameters for experiments that never ran (section 5.1).
Cost per full run was 2.33 to 13.10 USD depending on model (section 4.3). Transferable: human
checkpoints at stage boundaries. Not transferable: LLM-scored results.

### 1.7 autoresearch (Karpathy, March 2026)
https://github.com/karpathy/autoresearch, file `program.md` at `master`. Read: full file,
2026-09-09.

The whole loop fits in a page: one editable file, a fixed five-minute training budget, one
metric (validation bits per byte), keep the commit if the metric improves else `git reset`, a
five-column results TSV (commit, metric, memory, status, description), a ten-minute kill
timeout, and a crash rule that says fix trivial errors and re-run but log a fundamentally
broken idea as a crash and move on. It also instructs the agent never to pause to ask whether to
continue. This is structurally the closest match to our problem (one hot module, an existing
evaluator, bounded evaluation cost). Its weaknesses for us are a single metric, no noise model,
no preregistration and no held-out check; `PEER_PLAN.md` keeps the shape and adds those.

### 1.8 Methodology
- Nosek, Ebersole, DeHaven, Mellor, "The preregistration revolution", PNAS 115(11):2600-2606
  (2018), https://www.pnas.org/doi/10.1073/pnas.1708274114. Read: search summary. The point:
  separate prediction (hypothesis fixed before data) from postdiction (hypothesis fitted after);
  specifying the analysis before seeing data closes Gelman and Loken's garden of forking paths.
- Vaccaro, "Preregistration for Experiments with AI Agents", arXiv:2606.11217 (ICML 2026
  spotlight), https://arxiv.org/abs/2606.11217. Read: abstract. Catalogues the degrees of freedom
  agent experiments add (model choice, prompt wording, settings, outcome-contingent redesign)
  and argues that cheap iteration plus absent reporting norms makes them easy to exploit and
  hard to detect; proposes a preregistration template. Our harness constants, repeat counts,
  pin choice and any rerun-until-green are exactly such degrees of freedom.
- Hoefler and Belli, "Scientific benchmarking of parallel computing systems: twelve ways to tell
  the masses when reporting performance results", SC 2015, DOI 10.1145/2807591.2807644. Title
  verified against the dblp listing (dblp.org/rec/conf/sc/HoeflerB15) and by Codex against the
  original PDF. PDF at
  https://htor.inf.ethz.ch/publications/img/hoefler-scientific-benchmarking.pdf was fetched but
  could not be text-extracted on this machine, so the rules used below are from my prior
  knowledge of the paper plus the search summary, not a fresh quotation: state the whole setup;
  say whether results are deterministic and give confidence intervals when they are not; repeat
  until the interval is acceptable; compare intervals rather than points; report percentiles
  with their estimator; never average speedup ratios; do not cherry-pick runs.

## 2. What transfers (and is adopted in PEER_PLAN.md)

1. Evaluator as ground truth, never the proposer (1.1, 1.2, 1.4; 1.6 shows the failure mode).
2. Cascaded evaluation: cheap checks first, the expensive remote measurement for survivors (1.1, 1.3).
3. Record every metric on every run even when one is the target (1.1).
4. Reject near-duplicates before paying for evaluation: a registry check against the exploration
   record's rejected list (1.4).
5. Hard cap on repair attempts, then log a negative (1.5, 1.6, 1.7).
6. Staged programme with per-stage exit criteria (1.5).
7. Seeded, checkpointed, resumable runs with an artifacts directory (1.3).
8. Human checkpoints at stage boundaries, not per experiment (1.6). Per `DECISIONS.md` the
   partner gate is the default; James is consulted only where publishing, Asana, push or merge
   is involved, or where new scope or a policy denial arises.
9. Preregister the hypothesis card before the first measurement (1.8).
10. Report noise: A/A calibration, intervals on percentiles, stated estimator, no mean of
    speedups (1.8).

## 3. What does not transfer

- Population evolution (islands, MAP-Elites) as the outer loop. Those engines fit problems
  where candidates are small, independent program variants that an evaluator can score in
  isolation (a heuristic function, a kernel, a packing). Our candidates are bounded, coupled
  changes across several Nim modules that must keep cross-architecture determinism, memory
  caps and a per-stratum quality gate, and the plausible mechanisms number about a dozen with
  strong priors from the campaign. A linear, preregistered, cascaded loop over a ranked
  registry fits that shape. OpenEvolve or ShinkaEvolve stay optional for a hypothesis that is
  genuinely a parameter-space search (bucket sizing, prefetch distance, hot-set dilation), where
  the evaluator is one script and the candidate is one block.
- LLM-judged selection or scoring (1.5, 1.6).
- Single-run keep-if-better (1.7): fine for a smooth scalar, wrong for a max-of-120 tail on a
  shared host. Replaced by A/A-calibrated acceptance.
- Manuscript generation. The deliverables are a scoreboard, a ledger, and a budget with evidence.
