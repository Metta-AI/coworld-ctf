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
