# C10 documentation audit before the native micro

Scope: tools-only C10 research, plus completion/correction of the prior A8 peer report. No primary src, tests, public CLI, config, gameplay, GameVersion or viewer changes. No broad user-facing documentation update is needed for an unadopted experiment.

The proposal cites the existing pinned nimsimd1.3.2 dependency and Intel primary intrinsic references. Counts prove safe group coverage and exact index mapping; they are not timings. ARM correctness-v3.json proves five crafted cases and256border/mask cases for both grouped variants. The current decision adds a scalar grouping control and fixes the selection rule before native measurements. C10_MICRO_DECISION.md supersedes the differing scalar-selection suggestion in NEXT_THROUGHPUT_UNIT_PLAN.md; its caution also qualifies the plan's p95/mean ceiling arithmetic.

Tools are isolated in nav-deferred-cache/tools and frozen under C10/. Native runner restores the original source and removes only its three uniquely named tool files. Native inputs were copied, but no native timing has started at this audit. The evaluator verifies90rawprocessoutputs perhost, reference equality, fixed workload metadata and all registered thresholds. Python compilation and shell syntax checks pass. Full game quality, whole-body timing and production portability are later gates, not established by this micro.

A8 remains rejected by its registered4.96858%vs5%screen. Its exact-path comparison is complete; the initial failed arm-label compile is historical. The peer review now distinguishes the observed threshold decision from uncertainty about the underlying near-threshold effect.

Generated compiler caches and executable binaries are excluded from checkpoints. Native and local diagnostic output bytes are preserved; authored Markdown/Nim/shell/Python whitespace is checked separately from raw logs/patch context.

Post-micro update: both native90processdatasets are complete, exact, evaluated under the frozen rules, and selectSIMD. NativecraftedJSON equals ARM bit-for-bit; bothmicro runners restored source. The isolated full-source candidate now passes9cachetests,17navigationtests,5crafted+256border cases and bothservercompilechecks. It records a256byte conservative fixedmask allowance. The fulltrace/regime/qualityscreen is now launching; no primarysource, cap, budget or viewer changes. The first full-source cache test command used a wrong filename and failed before compilation; the corrected canonical testfilename passed, with bothlogs retained.

Whitespace check also reports one terminal blank line in each of two frozen correctness-driver snapshots. These are preserved to keep the tested source hashes exact; no implementation semantics are affected. All other newly authored source/docs pass the targeted check.
