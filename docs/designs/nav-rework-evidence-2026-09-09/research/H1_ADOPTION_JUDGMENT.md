# H1_ADOPTION_JUDGMENT: peer view on adopting the exact-goal heuristic

## 0. Revision 3 (after `H1_PAIRED_CORRECTION.md`): reassessment from paired evidence

The paired seat-wave data (`H1-paired-seat-latency.json`, 480 measured
pairs) removes the basis for the far-tail concern in sections 2 and 3
below, which are kept as the record of an interpretation that the paired
evidence does not support:

- The 1968-tick value at 32 seats is an additional completion: a request
  the parent never published by the cap, published by the candidate. A
  completed-only maximum rises when more work finishes. It is not an
  existing request slowed down.
- Common far completions: at 32 seats 4 faster, 10 same, 1 slower by 19
  ticks, one gained, none lost. At 16 seats 2 faster, 10 same, 3 slower
  (8, 2, 36 ticks), gains of 27 and 13 ticks, none gained or lost. All 240
  near pairs improve.
- Both-censored requests stay unknown beyond 2,000 ticks in both arms; the
  paired data says nothing about them and nothing here claims otherwise.

Reassessed judgment: H1 is an exact, quality-preserving change (frozen
quality hash and pops reproduce; route identity intentionally differs)
whose measured effect on the latency process is a broad near-goal
improvement and a mixed, small, net-positive shift on common far
completions, with one extra far completion. The earlier requirement of a
scheduler remedy as a prerequisite is withdrawn; it rested on the
completed-only p95 reading that the pairing refutes. Stable SJF's censored
far tail is a pre-existing, separate open item in both arms.

What still governs adoption is the contract, not the far tail:

- Whole-body timing is unchanged and both arms fail the 4/5 ms gates at
  1300 px and miss selection headroom at 331 px, so H1 neither earns nor
  blocks a timing pass and is not progress toward the 2x goal.
- Route identity changes, so adoption carries the fixture consequences in
  the acceptance map: the nine fixtures, GameVersion, and the viewer
  rebuild gate in the same change, with the route-hash difference listed.
- Determinism and cross-architecture reproduction already hold.

Recommendation: adopt H1 in the next integrated validation as a standalone
exact improvement, judged on the contract's own gates (quality, determinism,
memory, timing not regressed, latency reported as censored count plus
completed distribution plus survival bounds per arm). No scheduler
prerequisite. If root wants a single sentence: the paired data shows no
request made slower by more than 36 ticks and every near request faster,
so the case against adoption reduces to fixture cost and to H1 not being a
throughput result, which it never claimed to be.


Peer (Claude) judgment requested in `CACHE_TRACE_REVIEW_REQUEST.md`, based
on `H1_NATIVE_REPORT.md`, `H1_REVIEW.md`, and the earlier starvation
findings. Documents only.

## 1. What the native evidence says, in its own terms

- Exactness holds: the 3,072-case quality hash and pop total reproduce the
  Mac run; aggregate quality is unchanged; route identity differs by
  design (equal-cost ties settle in a different order).
- Whole-body timing shows no improvement: worst p95/max moved from
  3.949/4.081 to 3.967/4.326 ms at 331 px and 5.209/5.252 to 5.270/5.630 ms
  at 1300 px. Both arms fail the 4/5 ms tick gates at 1300 px and miss the
  3.6 ms selection headroom at 331 px, so H1 neither creates nor removes a
  gate pass.
- Useful work in the fixed synthetic workload rises: 789 completions
  versus 462 across the 18 rows per range, with slightly fewer pops
  (2.08 M versus 2.19 M). That is more routes per pop, not throughput
  qualification and not progress toward 2x.
- Latency: near-goal p50/p95/max drop from 18/48/51 to 8/16/17 ticks at 16
  seats and 50/133/140 to 15/36/41 at 32 seats. Far-goal completed-only
  p95/max rise from 1129 to 1165 at 16 seats and 1169 to 1968 at 32 seats;
  medians stay 82; every measured far wave hits the 2,000-tick cap in both
  arms; unpublished seat-waves are 65/145 parent and 65/144 candidate.
  These far numbers are censored completed-only tails and are not all-seat
  latency percentiles.

## 2. How to read the far-tail change

Corrections to the first version of this note, per `CACHE_DESIGN_REQUEST.md`:

- The candidate completed one MORE far wave than the parent (unpublished
  seat-waves 144 versus 145 at 32 seats), not fewer. "Fewer, later" was
  wrong; the accurate statement is "about the same number, with the
  completed ones finishing later".
- "Exact" for H1 means the quality screen and cross-architecture hash and
  pop totals reproduce; route identity intentionally differs. Exactness
  does not refer to routes.
- A tighter admissible heuristic does not prove the candidate settles a
  strict subset of the parent's nodes: with ties and the Dial bucket order,
  the settled sets can differ in both directions. Fewer pops in aggregate
  is a measurement, not a consequence of the proof.
- The capped 2,000-tick values are right-censored lower bounds. They are
  not all-seat percentiles and must not be turned into a "passing" all-seat
  p95 by counting the cap as a completion time. The right report is the
  censored count per arm, the completed-only distribution, and survival
  bounds (the fraction still unfinished at each tick), which the
  `H1_NATIVE_REPORT.md` numbers allow but this note cannot compute.

What the evidence supports: the far waves are censored at the cap in both
arms; H1 leaves that censoring essentially unchanged; among the far
requests that do complete, the completed-only p95/max at 32 seats moves
from 1169 to 1968 ticks. Why it moves is a hypothesis, not a finding: the
plausible mechanism is that cheaper near jobs let stable SJF admission
hand the freed pop budget to further near jobs, deferring far ones. That
mechanism is consistent with the earlier starvation findings but is not
verified by this run; a scheduler trace (admission order, pops per job,
expiry events) is what would verify or refute it.

## 3. Judgment

Agree with root: keep H1 isolated; do not adopt it alone now. Adopt it, if
at all, inside an integrated validation together with a bounded starvation
remedy for far requests, judged on all-seat outcomes reported as censored
count plus completed distribution plus survival bounds.

Reasons:

- The near-goal gain (8/16/17 versus 18/48/51 ticks at 16 seats, 15/36/41
  versus 50/133/140 at 32) and the completions-per-pop gain are real in the
  fixed workload, and the acceptance contract does not forbid tie-order
  changes. On those grounds H1 would be adoptable.
- The far waves already fail the cap in both arms; H1 does not fix that,
  and the completed-only far tail worsens at 32 seats. Adopting H1 alone
  ships a change whose far-request effect is unexplained; the redistribution
  hypothesis above needs a scheduler trace before it can be cited as the
  reason.
- Whole-body gates are unaffected either way, so nothing argues for
  adopting H1 before the admission question is settled.

Recommended order: (1) preregister a bounded far-request remedy in
admission (an aging term or a per-wave reservation; unchanged caps and
budgets) together with the scheduler trace that tests the mechanism, (2)
measure parent, H1, remedy, and H1 plus remedy on one latency process,
reporting censored counts, completed distributions and survival bounds per
arm, (3) adopt H1 only in an arm whose far survival curve is no worse than
the parent's at every reported tick and whose censored count does not rise.
If the remedy is out of the current unit, H1 stays isolated with its patch,
hashes and this record.

Adoption also carries the fixture consequences in the acceptance map:
route identity changes, so the nine fixtures, GameVersion and the viewer
rebuild gate apply in the same change, with the route-hash difference
listed in that change's record.

## 4. On A3

A3 (inline route index) is recorded as rejected and restored: no repeatable
activation gain, frozen map 48 still at 2.003934x. Nothing in this judgment
depends on A3, and the map 48 activation ratio remains an open item
separate from H1.

H1 JUDGMENT DONE (revision 3, paired reassessment applied; sections 2 and 3 retained as superseded record)
