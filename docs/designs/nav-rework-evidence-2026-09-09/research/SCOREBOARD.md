# Research scoreboard

Append results; do not erase negatives. All numbers are observed, not inferred production acceptance.

| Unit | Host | Source | Result | Evidence | What it does not establish |
|---|---|---|---|---|---|
| B0 | m6i.8xlarge CPU5 | 20234cc7, budget-only patches | 1024 passes3.6/4.5; 2048 fails headroom maximum; 3072/4096 fail | B0_REPORT.md; B0_SUMMARY.json | production fleet baseline, max affordable budget, completion latency, quality requalification |
| PROFILE | same | baseline plus harness Fluffy start/finish | valid trace;756 tick frames,18144 seat observations | PROFILE/profile-trace.json; PROFILE/summary.json | acceptance timing, guest invokeStep coverage, per-scenario attribution |
| I0 | same | harness breakdown toggle only | RUNNING | I0 prereg and remote logs | no instrumentation overhead verdict yet |
| PLATFORM | tournament live snapshot | read-only inventory22:11UTC | running CTF:27c6a4,3c8i-flex4,2m5a4,1m8i-flex4; all1CPU requests | platform-ctf-summary.json | unseen fleet types or CPU model inference from labels alone |
| I0 complete | Xeon CPU5 B1024 | on-A1/off-B/on-A2 harness builds | all9 processes have identical pop arrays; no consistent clock-removal speed gain; off worst max4.433177ms | I0_REPORT.md; I0/ | exact instrumentation cost or stable small speedup; server compile-shape qualification |
| B0-c6a | EPYC7R13 c6a.4xlarge CPU5 |20234cc7 budget-only patches|2048 passes headroom3.168633/3.276519ms;3072 passes4/5 only;4096 fails|B0_C6A_SUMMARY.json;B0-c6a/|fleet worst-case, maximum interpolated budget, or optimized throughput|
| QUALITY | Xeon CPU5 B1024 |20234cc7|3072/0missing/0illegal;expected route hash;65 activation rows|QUALITY/result.json|pool16MiB shared cap: measured conservative17,510,959B exceeds it despite broad global pass|

| B0-m5a | m5a.4xlarge CPU5 | 20234cc7, Nim2.2.6 | B1024 worst6.055890/6.129271ms; all four budgets fail | B0_M5A_SUMMARY.json | no fleet-wide budget can be selected yet |
| M0 | c6a CPU5 | half default Dial ring | same corpus hash and pops; pool max15938095B; timing2.484964/2.642113ms | M0_REPORT.md | not final canonical or complete inherited qualification |
| L0 preregistered | Xeon, then production families | exact ordered source reuse, retain installed-route expiry | not implemented or measured | L0_PREREG.md | no claim of general moving-threat liveness |

| L0 failed qualification | c6a and m5a CPU5 B1024 | reuse identical ordered sources | modest timing gain; m5a still fails; far waves publish only3seats then cap | L0_REPORT.md | not a complete liveness fix or throughput success |

| L1 failed completion target | c6a CPU5 B1024 | exact packed identity with shared scratch | no false restarts; still3publishedseats/farwave; quality and memory pass | L1_REPORT.md | no doubling or general admission-liveness claim |

| C0 | m5a CPU5 B1024 | L1 native vs repository Docker | native5.793836/5.857997ms; Docker5.404456/5.496837ms; both fail | C0_REPORT.md | no compiler-only attribution or fleet qualification |
| B0-c8i | c8i-flex.4xlarge CPU5 | baseline20234cc7 | B4096 passes headroom3.574419/3.822601ms | B0_C8I_REPORT.md | does not qualify slower m5a or establish an optimization |

| B0-m8i | m8i-flex.4xlarge CPU5 | baseline20234cc7 | B4096 passes headroom3.537775/3.699664ms | B0_M8I_REPORT.md | frozen331px harness, not current1300px/11-map variant |

| S1 | m5a CPU5 B1024 | positive Q8 truncation | refresh2.30% better; whole-body still5.713180/5.770981ms fail; exact quality and memory unchanged | S1_REPORT.md | no doubling, fleet or current-variant qualification |

| G0 | m5a CPU5 B1024 | S1, gun range331vs1300 only | whole-body p95 5.691996->13.982918ms; maximum15.593524ms at1300 | G0_REPORT.md | old geometry; no full configured-variant or optimization acceptance |

| G1 | m8i CPU5 B1024 | S1 configured1300px/11-map screen | all11 fail timing and16MiBsharedcap; worstp95/max15.015300/15.193815ms; sharedmax30755007B | G1_REPORT.md | single diagnostic, no hosted readback or repeat qualification |

- M1: reference-share immutable danger geometry under ORC; generated C no longer duplicates per-seat sequence payloads. Three m5a1300px pairs show no substantial speed gain; full quality unchanged. Historical logical memory undercount corrected, later capacity/context audit still required. M1_REPORT.md.
- W1: integer nearest/ties-even ray traversal; m5a1300px p95/max13.820488/15.464153 ->11.448389/12.762947ms. All masks/pops match, full quality unchanged; still fails tick gate. W1_REPORT.md.
- M2: capacity-based retained ledger; original65 maps pass, configured11 all fail shared cap (max31,340,947B). No speed claim; hazard/cache context still omitted until M3. M2_REPORT.md.

- M3: full installed hazard/cache accounting; 65 original maps pass memory, configured11 all fail shared cap (max31,521,758B). No speed claim. See M3_REPORT.md.
- W2: checked direct wall lookup, m5a1300px three pairs; p95/max11.543802/12.864276 ->10.375292/10.534817ms; all masks/pops identical, full3,072 quality and activation pass. Tick gate still fails; retain for combined qualification. See W2_REPORT.md.

- R1: exact shared sight table, three m5a1300px pairs; worst p95/max10.367423/10.601260 ->7.984246/8.777049ms. All masks/pops identical, full corpus hash unchanged; original memory gates pass, configured giant shared cap still fails. R1_REPORT.md.

- W6: major-axis specialization; m5a1300px p95/max8.201069/8.788592 ->5.960683/6.704114ms. All masks/pops and full corpus hash unchanged; original memory passes, configured shared cap remains failed. W6_REPORT.md.

- W7: clearance skip, weapon p95 3.206897->0.638566ms; whole-body p95/max5.881750/5.931860 ->5.957923/6.044486ms (no worst-body improvement). All masks/pops and corpus hash unchanged; clearance proof checks pass261,581,865 pixels. One reader repair retained. W7_REPORT.md.

## Durable checkpoint mapping

G0 bed15e11; G1 9e4971f1; M1 5a6c4963; W1 da13e2c7; M2 d9962a8d; M3 f261aeca; W2 f5433765; R1 ae5658fc; W6 e5791746; W7 addaad7a. Source-changing units include rebuilt viewer artifacts and documentation audits. Newer research notes were restored after the primary branch fast-forward; original files remain in the external sync backup.

- CAP32: James authorized up to 4x non-colossal caps. Selected 32 MiB shared (2x), preserving the 256 MiB total/colossal cap. Fresh memory passes all 76 maps; configured timing and inherited activation ratios still fail. Historical 16 MiB failures above remain historical. See MEMORY_CAP_RULING.md.

- D0a: incremental danger-ray decision; m5a1300px three pairs p95/max5.948740/6.034892 ->5.838907/5.953172ms. All18 matched rows improve p95; masks, pops, full quality and retained ledgers unchanged. Tick gate still fails. D0_REPORT.md.

- D1 rejected: incremental kernel index; m5a1300px worstp95/max5.839953/5.887573 ->5.936474/5.996664ms. Exact masks/pops/quality/ledgers, but slower. Restored D0a; archive candidate and negative evidence. D1_REPORT.md.

- P1: streaming packed hot dilation, m5a1300 threepairs worstp95/max5.828086/5.878588 ->5.242172/5.274622ms; weightp951.092082->0.423183ms. Exact masks/pops/quality/memory; no sparse-regime regression observed. Tick gate still fails. P1_REPORT.md.

- WF0 rejected: exact wavefront diagnostic passes 14 raster comparisons but loses 13/14 m5a rows; 1300 px p95 is 1.99–3.57x reference. Production unchanged. See WF0_REPORT.md.

- A0 retained: symmetric fine-edge construction reduces mixed-graph activation 20.88–21.91% over three m8i pairs. All 76 graph fingerprints and full quality match; memory unchanged. 53–57/64 non-colossal activation ratios still fail. See A0_REPORT.md.

- A1 retained: exact two-edge bridge shortcut halves mixed-graph activation in three m8i pairs. All 76 graph arrays, full quality and memory match. Only frozen map 48 still exceeds 2x activation (2.081–2.097x); configured timing remains failed. See A1_REPORT.md.

- WF1 rejected before implementation: corrected per-source enumeration model costs median 1.52 ray-step equivalents at 331 px and 0.86 at 1300 px, exceeding preregistered 0.80/0.60 limits. Wavefront direction closed. See WF1_PROPOSAL.md and retained count scripts/output.

- C1: current A0/P1 source, three m5a native/Docker pairs per range. 1300px worstp95/max5.186019/5.246860 native versus5.140920/5.177941 Docker, both fail. All masks/pops and Dockerfullquality match. See C1_REPORT.md.

- A2 retained: coarse-edge symmetry preserves32,545,936bits/76maps and fullquality. Three m8i targeted pairs reduce map48 index~24ms and pass ratios; full sweep stillfails map48 at2.004792788x (75/76time,76/76memory). See A2_REPORT.md.

- A3 rejected: inline legalNavMove has no repeatable native m8i gain and full map48 remains2.003934x. Source restored to A2. See A3_REPORT.md.
- H1 isolated positive work screen: full quality matches across architectures with15.47% fewer corpus pops; native short-run completions462->789 and near latency improve, whole-body does not. Censored far-tail worsens; adoption pending joint review. See H1_NATIVE_REPORT.md.

- C2 trace screen: nine real baselineS2episodes, three distinct pinned maps at16/32seats. LRU64 passes30%ray-step-removal count gate on2/3 and3/3maps respectively; no timing claim. Corrected previous-rebuild carry attribution independently reproduced. CACHE_TRACE_ROOT_REVIEW.md.

- V1 retained: bytevisitstamps preservefullquality/masks/pops and684native rollovers. Colossal saves37,380,096B;76/76memorypasses. Smallm5atiminggain,1300pxstillfails5ms; m5aactivationonly11/76passes. V1_REPORT.md.

- A4 retained: equivalent coarse-edge validation,2164mutation decisions match; m8ithreepairs map48index275->251ms,full76/76activation/memorypass,fullqualityunchanged. m5a/finalcompileractivationstillopen. A4_REPORT.md.

- H1 integrated after paired-seat correction: all240near completions improve, commonfar6faster/20same/4slower,1newcompletion/0lost. New1968tick tail was additional work, not a delayed existing request. Newhash ee2488d32085fb4de3457c4cf841298c14b87add2225964d934f80f2a7c1013d; finalcombinedqualificationpending. H1_INTEGRATION.md.

- C2 retained for integration: m5a short 331/1300 regimes fit B1024 headroom, but configured 0/11 pass (worst p95/max 6.484532/6.680327 ms). All 27 native real-trace pairs improve total/p95 with exact rasters; changing-source microbench regresses up to 1.08%. Integrated +16-byte owner allowance corrects isolated ledger. C2_STATUS.md.

- C4 rejected at trace-count screen: complete ordered-source raster reuse at capacity8 is only2.20–7.31% of nonempty rebuilds, fails20% threshold everywhere. No source implementation or memory-cap increase. C4_REPORT.md.

- A5 native attribution: pocket work is about half of index construction on both m5a/m8i; no uniquely worse pixel-stage host scaling. A6 lazy screen improves m8i index time3.45–4.12%, direct loses11.1–11.7%; full m8i quality and76activation/memory rows pass. All retained ledgers equal A4. m5a follow-up pending, no integration. A6_NATIVE_STATUS.md.

- C6 rejected at native micro gate:1300px replay gains6.90–8.94%, below preregistered10%; all27real-trace totals regress0.12–1.53%,24/27p95slower. Exact inputs/rasters/crafted indices. No primarysource or whole-body run. C6_NATIVE_REPORT.md.

- C3 rejected: all 198 configured rows exact, median p95 gain1.25%, 0/11maps pass; recorded-trace p95 worsens23/27pairs. Source/viewer restored to C2; multi-range cache regression retained. C3_STATUS.md.

- A6 m5a qualification complete:3072quality exact,62/76activation-time,76/76memory,retained ledgers equal m8i. No integration;14activation failures remain. A6-m5a-qualification-summary.json.

- C8 rejected standalone: all27recorded-trace totals slow0.50–2.38%,26/27p95slower; all3072quality exact. No primary source change or m5a follow-up. C8_ROOT_RESULT.md.

- C7v2micro passes both native hosts:120rows exact, list replay about49–59%faster m8i and51–56%m5a. Full64slot candidate still isolated; no whole-body/cap decision. C7_NATIVE_MICRO_REPORT.md.

- A7 sub-threshold: combinedlazy+early gainsmedian5.2%m8i but3.8%m5a, below5%both-host gate; early-onlyflat. All76selected-index fields and173424pathchain exact,12real exactEdges differences preserved. No integration. A7_NATIVE_REPORT.md.

- C7 full eager cache rejected: v1 per-cell reference ownership caused large native regressions; removing it preserves all quality/rasters but corrected traces still slow23/27p95pairs m8i and18/27m5a, with changing-source costs up1.3–4.2%. Median total ratios0.9951/0.9567 are mixed and do not justify ~27MBextra. Both full3072quality exact. C7_REFCOUNT_ROOT_RESULT.md.

- C9 conditional conversion micro: m8i all40rows exact and eight median configurations pass preregistered limits;1300px conversion extra23.7–24.4%,list ratio46.5–48.0%. m5a replication active; no production/cap change. C9_NATIVE_RESULT.md.

- C9 fullscreen fails m5a: all9trace medians improve totals andallquality exact, but3changing-source medians regress1.19–1.64%against1%limit. m8ipassesallchecks. Noadoption/capchange; integratedlocal13cachetests archivedthenrestored. C9_NATIVE_FULL_RESULT.md.

- A8countscreen passes correctedpre-runcriterion: map48 189identical failedsearches repeat,44.2866%dequeuework; all1991pixelcalls across76maps showzeroexact-keyresultdifferences, onlymap48repeats. First128failure-keycachewouldserveall189; no timinggainproven. A8_FULL_COUNT_RESULT.md.

- A8 bounded failure memo native screen negative: m8i median6.15593%gain, m5a4.96858%vs preregistered5%bothhosts. All76maps/19retainedarrays exact;189hits/356784saveddequeues match model; noadoption, no capchange. A8_MEMO_SCREEN_RESULT.md.

- C10 preregistered grouped replay: retained bitmap unchanged; safe4cellgroups cover98.81–99.70%of additions on sixmap/range samples. ARM fivecrafted+256border/mask cases exact forscalar/SIMD. Three-arm native20%screen pending; no productionchange. C10_MICRO_DECISION.md and C10_MICRO_READY.md.

- C10 native micro passesbothhosts: SIMD1300replay ratios0.4398–0.4520m8i and0.2905–0.2971m5a; scalar~0.72–0.73. All180processoutputs exact, fivecrafted+256border cases exactacrossARM/SSE2. SIMDadvancesonlytofullsource trace/regime screen. C10_NATIVE_MICRO_RESULT.md.
