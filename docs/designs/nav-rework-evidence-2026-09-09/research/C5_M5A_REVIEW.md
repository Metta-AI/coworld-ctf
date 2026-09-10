# C5_M5A_REVIEW: configured map 3 first-fill attribution on m5a (with m8i beside it)

Peer (Claude) documents-only review per `C5_M5A_REVIEW_REQUEST.md` of
`C5-v2-m5a/` and `C5-v2-m8i/`. Machine-readable per-row summary for both
hosts: `C5-m5a-stage-summary.json` (per-tick top-level and danger stage
means on measured fill and no-fill ticks, fill tick indices, phases). All
durations are Fluffy-nested attribution with profiler overhead and are
never gate values.

## 1. Provenance and exit statuses

Both hosts ran base f9dff753 with identical source hashes
(`body_nav.nim` 13f51914..., `bench_body_nav_rework.nim` 20dab7e2...),
configured index 3 (br-gen-5120), all six rows, traced and counted builds.
Exit codes: m5a build-traced 0, run-traced 1, build-counted 0, run-counted
1; m8i all four 0. The m5a run exits of 1 are the expected configured
tick-gate failures on that host (both arms report `pass: false`, worst
counted p95 6.44 to 6.52 ms against 4 ms), not run faults; the m8i rows
pass on that host. Neither is a green gate for anything: these are
diagnostic builds.

Trace structure verified against the actual events, not assumed: 170,574
events and the same 26 names on both hosts; per row one
`bench.tickRow:<roster>:<scenario>` marker, 126 `shell.compile` ticks (the
first top-level stage of every `episode.step`, used as the tick delimiter),
126 `shell.danger` and `shell.planning`, per-seat `shell.lifecycle`,
`body.belief`, `shell.default`, `shell.reflex`, `shell.context`,
`shell.guard`, `body.follower`, `body.weapon`, and the C5 danger markers
(`danger.clear` 144, `danger.hit.replay` 1,104, `danger.miss.rays` 48,
`danger.closeFloor` 1,152, `danger.scaleMax` 144, `danger.packWeights` 144
per host).

## 2. Masks and pops between arms and hosts

Every row's `masks_per_tick` and `pops_per_tick` are identical between the
traced and counted builds on m5a, identical between the two builds on m8i,
and identical between m5a and m8i for all six rows. Cache counters
(counted build only): 120 hits and 8 misses at 16 seats, 248 and 8 at 32,
on both hosts.

## 3. First-fill attribution on m5a

| row | fills initial / warmup / measured | measured ticks with a fill | last fill tick | fill-tick shell.danger us (mean) | no-fill measured shell.danger us (mean / max) |
|---|---|---|---:|---:|---|
| 16 first_goals | 1 / 5 / 10 | 6..14, 31 | 31 | 4,186 | 15.6 / 34.4 |
| 16 moving_goals | 1 / 5 / 10 | 6..14, 31 | 31 | 4,184 | 16.0 / 28.2 |
| 16 stuck_replans | 1 / 5 / 10 | 6..14, 31 | 31 | 4,190 | 15.6 / 36.0 |
| 32 first_goals | 1 / 5 / 26 | 6..31 | 31 | 4,191 | 30.7 / 51.6 |
| 32 moving_goals | 1 / 5 / 26 | 6..31 | 31 | 4,194 | 30.8 / 57.0 |
| 32 stuck_replans | 1 / 5 / 26 | 6..31 | 31 | 4,189 | 30.0 / 55.0 |

Same structure as m8i: one first scheduled fill per seat, all inside ticks
0 to 31, none afterwards; 10 of 120 measured samples at 16 seats and 26
of 120 at 32 seats carry a fill, both above the 5 percent that defines
p95, so the row p95 and maximum are first-fill ticks on m5a too. The 8
misses per row all occur in the initial tick's rebuild (seat 0), so every
measured fill tick is eight cache hits: `danger.miss.rays` is absent from
measured ticks on both hosts.

## 4. Packing versus hit replay on a cold fill (m5a, means over measured fill ticks)

| stage | m5a us | m8i us | m5a / m8i | share of m5a shell.danger |
|---|---:|---:|---:|---:|
| shell.danger (whole) | 4,186 to 4,194 | 1,474 to 1,485 | 2.82 | 100 percent |
| danger.hit.replay (8 sources) | 2,345 to 2,350 | 731 to 740 | 3.2 | 56 percent |
| danger.packWeights | 1,015 to 1,022 | 421 to 424 | 2.4 | 24 percent |
| danger.closeFloor (8 sources) | 430 to 436 | 114 to 116 | 3.8 | 10 percent |
| danger.scaleMax | 277 to 279 | 161 to 162 | 1.7 | 7 percent |
| danger.clear | 74 to 88 | 37 to 41 | 1.9 to 2.4 | 2 percent |

Hit replay dominates the cold fill on both hosts and dominates more on
m5a, where it scales 3.2x against 2.4x for packing; packing is the second
stage at about a quarter. The close floor is the worst-scaling stage
(3.8x) but a tenth of the whole. This is the attribution behind the C6
(replay) and C8 (fewer replayed cells) screens; it does not by itself
predict their whole-tick effect.

## 5. What remains after tick 31 (m5a, measured no-fill ticks)

Mean top-level time per no-fill tick is 1.94 to 1.97 ms at 16 seats and
2.45 to 2.56 ms at 32, against 6.1 to 6.7 ms on fill ticks. The no-fill
tick is `shell.planning` 1.41 to 1.44 ms (fixed per tick, independent of
roster), `body.weapon` 0.25 ms at 16 seats and 0.49 to 0.50 ms at 32,
then `shell.standing`, `shell.lifecycle`, `body.follower` and
`shell.default` at 0.04 to 0.16 ms each; `shell.danger` is 16 to 31 us.
So after the fills the danger stage is negligible and the tick is planning
plus per-seat weapon and shell work. Two no-fill outliers are in the raw
data and are reported, not explained: one 5.37 ms tick in 32 first_goals
and one 8.94 ms tick in 32 stuck_replans, both far above every other
no-fill tick on that host and absent on m8i; they look like host
interference, but nothing in the trace identifies the cause.

## 6. Conclusions

- The m5a configured p95 for map 3 is a first-fill tick, as on m8i, and
  the fill is 56 percent hit replay and 24 percent weight packing on this
  host.
- No-fill ticks are about 2 to 2.5 ms on m5a with planning fixed at 1.4
  ms; removing every fill would not by itself change the fact that the
  gate is measured on ticks that include them, and warmups must not be
  lengthened to hide them.
- Nothing here is an acceptance number; traced rows include profiler
  overhead and the counted rows are diagnostic builds. Real traces remain
  the evidence for steady play.

C5 M5A REVIEW READY
