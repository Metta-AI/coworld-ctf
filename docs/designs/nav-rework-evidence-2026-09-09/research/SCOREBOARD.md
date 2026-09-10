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

- G0: configured range diagnostic on m5a, same source and 3 paired runs; 331 px worst p95/max5.691996/5.807979ms,1300 px13.982918/15.593524ms. Workload gap, no optimization claim. G0_REPORT.md.

- G1: checked-in configured 11-map screen on native m8i; all maps fail timing and shared memory. Worst p95/max15.015300/15.193815ms, original logical shared max30,755,007B. Later M2/M3 correct capacity/context counts; raw G1 preserved. G1_REPORT.md.

- M1: reference-share immutable danger geometry under ORC; generated C no longer duplicates per-seat sequence payloads. Three m5a1300px pairs show no substantial speed gain; full quality unchanged. Historical logical memory undercount corrected, later capacity/context audit still required. M1_REPORT.md.

- W1: integer nearest/ties-even ray traversal; m5a1300px p95/max13.820488/15.464153 ->11.448389/12.762947ms. All masks/pops match, full quality unchanged; still fails tick gate. W1_REPORT.md.

- M2: capacity-based retained ledger; original65 maps pass, configured11 all fail shared cap (max31,340,947B). No speed claim; hazard/cache context still omitted until M3. M2_REPORT.md.

- M3: include installed hazard and refreshed cache; all65 original maps pass, historical configured shared maximum31,521,758B. New user ruling permits a later32 MiB cap update; raw16 MiB failures remain. M3_REPORT.md.

- W2: Worst m5a p95/max11.543802/12.864276 ->10.375292/10.534817ms; all masks/pops and full corpus unchanged. See W2_REPORT.md.

- R1: Worst m5a1300px p95/max10.367423/10.601260 ->7.984246/8.777049ms; all masks/pops and corpus unchanged. Count shared table memory. See R1_REPORT.md.

- W6: Worst m5a p95/max8.201069/8.788592 ->5.960683/6.704114ms; all masks/pops and full corpus unchanged. See W6_REPORT.md.

- W7: Weapon p95 improves3.206897->0.638566ms; worst body p95 does not improve. All masks/pops and corpus unchanged; clearance invariants pass261581865 pixels. Preserve failed verifier attempt. See W7_REPORT.md.
