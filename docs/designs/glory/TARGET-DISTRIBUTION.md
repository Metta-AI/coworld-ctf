# GLORY GRADIENT — S3 TARGET DISTRIBUTION (owner-signed)

Status: **SIGNED by the owner.** This document is a scribe transcription of
the owner's definition, not a redesign — the numeric bands below are
consequences the rig (S5) must hit, not inventions of this doc. Docs-only;
no code, no `glory.nim`/`sim.nim`, no `GLORYVERSION` bump, no settings POST,
no deploy.

Epic: `25d9108e` (GLORY GRADIENT), step S3, following S1 (census) and S2
(gate-open / target-distribution questions put to the owner).

---

## 1. The band definitions (owner's words, verbatim)

The owner defined the bands by **what a seat did**, not by a score number.
The ratios in §2 are *consequences* of these definitions, derived by the
rig — they are not the definition itself.

- **LOW** = "didn't really accomplish anything in this match"
- **MID** = "played the game, but skill varies"
- **TOP** = "knows and understands the game well, wins intentionally and
  predictably"
- **JACKPOT** (above top) = a master ALSO lands the lit mode / hail mary —
  rare, named, and **NEVER REQUIRED** to reach top.

A seat can reach TOP without ever touching a JACKPOT deed. JACKPOT is a
bonus layer on top of mastery, not a gate on it.

---

## 2. The rig checks (consequences — the numbers S5 must hit)

Deed-points = `log2` of the leg (the multiplicative factor a deed/achievement
contributes). Because points are logs, they add where legs multiply:
**one big deed = three small ones** whenever its points equal the sum of
theirs (e.g. a 6-pt deed ≡ three 2-pt deeds stacked — the log preserves that
relationship). Deed value is DIFFICULTY, not frequency.

| band | pts | leg (2^pts) | reached how |
|---|---:|---:|---|
| LOW | 1–2 | 2–4 | passively; "didn't really accomplish anything" |
| MID | 2–6 | 4–64 | playing the game; width comes from **deeds chosen**, not placement legs |
| TOP | 7–10 | 128–1,024 | intentionally; "wins intentionally and predictably" |
| JACKPOT | beyond top | >1,024 | rare, named skill/luck spike; never required for TOP |

Stated ratio targets (owner-signed, from the S2 question set):
- MID spread ≈ **~20× wide** (roughly p25–p85 of the mid band) — and that
  spread must come from deeds CHOSEN, not from placement legs.
- TOP ≈ **~100× a typical round**, reached intentionally.
- JACKPOT ≈ ~~**~1000× median**, cap-hit on the order of **0.1–1%** of
  seat-episodes.~~
  **⚠️ SUPERSEDED on the raw scale** (S2 lead, 2026-09-09, under the
  owner's delegation — see `CAP-CEILING-S7.md`'s Decision; owner may
  overrule). The owner's feel rulings ("jackpots RARE by design", "the
  top must feel glorious and earned, not lucky, not a fluke", "crazy
  but not predictable scores", "exponential compounding") rule out a
  raw-scale wall that pins a chunk of the top decile to one number:
  `CAP-CEILING-S7.md`'s sweep gives the jackpot ratio at each tested
  ceiling (2^14 16,384× · 2^18 262,144× · 2^20 1,048,576× · 2^21
  2,097,152×), and cap-hit ∈[0.1,1]% and ≈1000× median cannot both hold
  on the raw scale — the tail is exponential in tag count. Standings
  are unaffected (`signed_log2`, Step A: 21 raw bits vs. a 2–8 bit
  mid-band is fine there).
- The geometric-mean standings must separate TOP from MID **every round**
  (this is why the season rule is per-leg log / geometric mean — already
  decided, not reopened here).
- Placement (final 8/4) becomes a **small deliberate reward**, not the
  engine of the middle — today it is a near-universal floor
  (`dFinal8` fires in 100% of episodes, S1 census Q1) and must stop being
  the thing that pushes a seat from LOW into MID.

---

## 3. Anchor to the measured present (S1 census baseline)

Era: GloryVersion 15 (JointAct pact-gated, PR #467), coworld_version
0.7.361–0.7.367, GameVersion 59/60 (byte-identical scoring), Paintbot
Season 2 ladder, rounds r4515–r4539 — the entire population at this era.
24 rounds, 305 episodes, **4,880 seat-episodes**, reconciled **100%**
against platform `participant_scores` before anything downstream was
trusted.

| p50 | p90 | p99 | p99.9 | max |
|---:|---:|---:|---:|---:|
| 4 | 576 | 98,304 | 3,681,681 | 16,777,216 (2^24 cap) |

- p99/p50 = **24,576×** (owner's target for TOP-vs-typical: ~100×)
- p99.9/p50 = **920,420×** (owner's target for JACKPOT-vs-median: ~1000×)
- cap-hit = **0.020%** (1/4,880) — already inside the 0.1–1% jackpot design
  band's neighborhood, but as an ACCIDENT nobody reaches on purpose, not a
  designed jackpot.

**Headline: today the median seat-episode scores 4, and the middle is
empty. The floor is the defect, not the cap.** The gap is not that TOP is
too low; today's spread is 2–3 orders of magnitude past both the TOP and
JACKPOT ratio targets while the MID band (the one most players should live
in) does not functionally exist — p50→p90 is 144× (4→576) and almost none
of that is reachable by choice; it is who got placement legs, not who
played better.

### Known open item — carried forward, does not block this target
A separate worker is attributing it, and the target in this document does
not depend on the answer, but **S4 must not freeze its catalog before it
lands**: on the S1 achievements addendum, the named recipe
(closing_time × jointact × win8, mean 42.2%/median 44.6% of a top-decile
score's log2-magnitude) plus achievement stacking (mean 18.0%/median 9.8%)
together explain only ~mean 60%/median 54% of a top-decile score's
bit-length — **~40–46% of a top-decile score's magnitude is currently
unexplained** by either named mechanism.

---

## 4. Open arithmetic (flagged, not resolved here — for S5 to reconcile)

Per instruction, the pts bands above are checked against the owner's stated
ratios rather than adjusted to agree with them. Two tensions and one
ambiguity:

1. **MID band internal ratio, 16× vs "~20× wide."** MID = 2–6 pts = leg
   4–64. `64 / 4 = 16×`, not 20×. Same order of magnitude, but not exact —
   S5 may need to widen the MID band (e.g. to ~1.3–6.3 pts for an exact 20×)
   or accept 16× as "close enough to ~20×."

2. **TOP band vs "~100× a typical round" is anchor-dependent.** TOP = 7–10
   pts = leg 128–1,024 (an internal 8× range). "A typical round" is not
   itself defined in pts, so the ×100 check depends entirely on which point
   in MID counts as "typical":
   - Anchored on MID's geometric center (4 pts, leg 16): TOP spans
     `128/16=8×` to `1024/16=64×` — both *below* the ~100× target, and even
     TOP's ceiling only reaches 64× the MID center.
   - Anchored on MID's floor (2 pts, leg 4): TOP spans `128/4=32×` to
     `1024/4=256×`, geometric mean ≈ 90× — much closer to ~100×.
   These two reasonable anchors disagree by roughly an order of magnitude.
   The pts bands alone do not pin down which "typical round" the owner's
   ~100× figure means; S5 needs to pick the anchor (most likely the target
   MID's own median, once S5 sets it) explicitly rather than let it default.

3. **JACKPOT's "~1000×" baseline is unstated — median (per Q3) or TOP's
   ceiling?** Q3 (S2 question set) signed "~1000× median" explicitly. This
   doc's own JACKPOT row says "beyond top (~1000×)" without naming the
   baseline. Two readings:
   - 1000× the target median lands somewhere S5 has not yet fixed (the
     target median itself is a rig output, not signed here).
   - 1000× TOP's ceiling (1,024) ≈ 1,024,000 (~20 pts) sits **~16× below**
     the hard 2^24 cap (16,777,216, 24 pts) — leaving headroom between
     "named jackpot" and "hard cap," which is plausible but not something
     the pts bands establish on their own.
   Recommend S5 treat "JACKPOT ~1000×" as 1000× the *target* median (matching
   Q3's signed wording) and derive where that sits relative to the 24-pt
   cap once the target median is fixed — not the 10-pt TOP ceiling.

None of these are contradictions in the owner's intent — they are places
where a single pts-band table is being asked to satisfy three
independently-stated ratios, and the arithmetic doesn't uniquely resolve
which anchor closes each ratio. Flagging per instruction; not adjusted here.

---

## 5. Pinned arithmetic (owner-delegated ruling — resolves §4's ambiguity)

The ambiguity in §4 (which anchor "a typical round" means) was surfaced,
not resolved, by this doc. The owner delegated the numeric pin to the lead;
the lead's ruling below resolves it. §4 is left standing as the record of
what was ambiguous and how it got resolved — it is not deleted or edited.

**"Typical" = the median of all legs**, which after the redesign sits at
the mid band's centre (~4 pts).

| band | pts | note |
|---|---:|---|
| LOW | 1–2 | unchanged |
| MID | 2–6 | centre ≈ 4 pts = the "typical" anchor |
| TOP | ≈9–11 | ≈100× the median |
| JACKPOT | ≈13–15 | ≈1000× the median |
| ceiling | ≈16 | cap-hit ~0.1–1% |

**Working, so the anchor-dependence in §4 can be seen to close:**
- `log2(100) = 6.6439`, so TOP sits at `median + 6.64 ≈ 10.64` pts —
  inside the pinned 9–11 range.
- `log2(1000) = 9.9658`, so JACKPOT sits at `median + 9.97 ≈ 13.97 ≈ 14`
  pts — inside the pinned 13–15 range.
- Both check out against the ~4-pt median anchor, i.e. §4's "anchor on
  MID's centre" reading is the one the lead ruled correct, not the
  "anchor on MID's floor" alternative also raised in §4.

**Degree of freedom, not slack**: simulators (S5) may move any boundary
above by **±1 pt on the rig**, provided the reason for the move is written
down. This is an explicit, deliberate tolerance — not an invitation to
silently retune a band to make a different number work.

**⚠️ Flagged, not resolved here: 6–9 pts is unassigned.** MID tops out at
6 pts; TOP starts at ≈9 pts. The earlier (§2/§4) draft had TOP at 7–10,
which covered this range; the pinned ladder does not. **7–8 pts is
currently unnamed.** Is this deliberate headroom — the "reached
intentionally" climb between MID and TOP the owner described — or an
oversight in the pin? This doc does not fill the gap or quietly widen a
band to close it; it is an open question for the lead/owner to answer.

**RULING (resolves the flag above): the gap is deliberate.** 7–8 points
is the **upper shoulder of MID** — where a strong mid-risk player lands
regularly; still "played the game, but skill varies" at its best. TOP
begins where wins become intentional and predictable (~9).

**The bands are percentile checks, not walls.** No discontinuity is
intended between MID and TOP through 6–9 pts.

**Rig acceptance criterion for S5 (explicit, not prose):** the simulated
distribution MUST show a **continuous population through 6–9 pts** —
seat-episodes landing there, not a gap. A visible population gap in the
simulated distribution at 6–9 pts is a **FAILURE of the rig to fix**, not
evidence that the bands are working or that the boundary is "clean."

---

## 6. What is NOT verified

- The pts↔leg↔ratio reconciliation in §4 is arithmetic only — no
  simulation was run against these bands; S5 owns fitting deed classes,
  heat-rung spacing, and cap placement to actually hit these numbers.
- The MID band's "spread must come from deeds chosen, not placement legs"
  is a design requirement carried from the owner/lead, not something this
  census-anchored doc can confirm — S4's catalog choices decide whether it
  holds.
- The ~40–46% top-decile unexplained-magnitude finding (§3) is inherited
  from `01b-achievements-addendum-2026-09-09.md`; this doc does not
  re-derive it and explicitly does not wait on it.
- p99.9/p50 (920,420×) rests on ~4.9 samples in the S1 census — real, not
  fabricated, but not a stable tail estimate; treat the JACKPOT-vs-median
  ratio target's present-day baseline as indicative only.
- No code, sim, or live-config check was performed — this is a docs-only
  target definition for S5 to implement against.

---

## Sources

- `~/.ctf/knowledge/glory-gradient/03-target-distribution-questions-2026-09-09.md`
  (the three ratio questions as put to the owner, recommended options)
- `~/.ctf/knowledge/glory-gradient/01-census-2026-09-08.md` (S1 census,
  measured-present baseline in §3)
- `~/.ctf/knowledge/glory-gradient/01b-achievements-addendum-2026-09-09.md`
  (achievements decomposition, the ~40–46% open item in §3)
- `~/.ctf/knowledge/glory-gradient/00a-manager-ledger.md` (S2 gate-open
  guidance: "NOTHING SERVES THE MID BAND" headline, mid-band-first-and-widest
  instruction)
