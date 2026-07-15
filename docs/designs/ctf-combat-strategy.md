# CTF Combat Strategy — the gunfighter doctrine

*How Picasso should fight. Grounds Navy SEAL / US-Army CQB doctrine in the exact
mechanics of this game, then turns each principle into a per-tick rule. Written
2026-07-14 (session 2). Sources: the verified deep-research pass on CQB /
small-unit gunfighting (ATP 3-21.8 2024, FM 90-10-1 App K, FM 3-90 direct-fire
appendix, Boyd's OODA, credible CQB-practitioner writing) cross-checked against
`src/ctf/sim.nim` and `players/baseline/baseline.nim`.*

---

## 0. The objective function (read this first — everything follows from it)

Win conditions, from `sim.nim`:

1. **Capture** — grab enemy flag, return it home. Instant win. *Structurally
   hard* here (dense cover, map-wide guns watching lanes) — 8 of our sanctioned
   xp-request games were draws, meaning nobody capped.
2. **Wipe** — enemy has no live players *and no lives left*. With **3 lives ×
   respawn (72 ticks)**, this is near-impossible mid-game. **Not a real lever.**
3. **Timeout (10 000 ticks)** — tiebreak on **most total lives remaining**
   (`teamLivesRemaining = Σ p.lives (+1 if alive)`), then flag progress, then
   draw.

**Therefore most games are decided by the lives differential = (kills − deaths).**
Not kill *volume* — kill *differential*. Every death we take hands the enemy a
tiebreak point; every kill we land removes one of theirs. **"Be the best
gunfighter in the game" is not a vibe — it is literally the scoring function.**
This is why the earlier "convert equal frags into a wipe" framing (Fork 1) was
only half right: wipes barely happen, but the *differential* that a good
gunfighter runs up is exactly the tiebreak metric.

Design consequence: **we optimize K−D**, i.e. maximize our kills while minimizing
our own exposure-deaths. Reckless face-first pushes and passive hiding are the
*same* mistake seen from two sides — both trade away differential.

---

## 1. The mechanics that constrain every heuristic

From `sim.nim` config + `baseline.nim` constants. Any CQB rule has to survive
these or it is fantasy:

| Mechanic | Value | Why it matters for the doctrine |
|---|---|---|
| Lives / HitPoints | 3 / 3 | 3 hits to kill; downed enemies **come back** in 72 ticks. Never "clear and forget." |
| Respawn / spawn-protect | 72 / 24 ticks | A killed enemy is gone ~1.5 s then returns invulnerable for 0.5 s. Re-scan cleared angles. |
| **Aim turn rate** | **5 brads/tick** (`AimRate`), 256 = full turn | **The turret is SLOW.** 90° slew ≈ 13 ticks; a full about-face ≈ 25 ticks (~0.5 s). *Every tick the gun points away from a live enemy is expensive to undo.* This is the single most important mechanical fact. |
| Fire windup / cooldown | 5 / 12 ticks | Aim **locks on the pull** (windup 5). Hard cap ≈ **1.4 shots/s**. Every trigger pull must count. |
| Bullet corridor | 14 px (`FireSlackPx` 11) | Hitscan down a narrow corridor. Miss = wasted shot + wasted ~12-tick cooldown. |
| Gun range | 1300 px (map-wide) | You can kill far beyond your view — a *remembered* fresh track with a clear pixel ray is a valid target. |
| Friendly fire | ON | The **nearest** unit in the corridor takes the hit — a teammate crossing your line eats your shot. |
| **Vision = fire axis** | forward cone ±45° around aim, walls block LOS, fog | **The gun and the eyes are the same vector.** Where you aim is what you see and what you can shoot. This is why "keep the gun on him" and "keep him out of the fog" are the *same action* — the core of target-lock (§7). |

**The killer corollary:** because the turret is slow *and* vision rides the aim,
the worst thing Picasso can do is let the gun drift off a live enemy. Re-scanning
to find them again + re-slewing to line up burns 15–30 ticks — during which the
enemy (who kept *their* gun on us) shoots first. **Slew budget is the scarcest
resource in the game.**

---

## 2. What Picasso does wrong today (the three symptoms, mechanized)

The user's field observations, each traced to a code site:

1. **"Runs into a corner and hides."** `stuckTicks` only triggers the unstuck
   jink when `engage < 0` (baseline.nim:1607) — so a bot frozen against a wall
   *while it holds an enemy track* never breaks free. Diagnostic camp-ticks
   confirm it: **28 frozen-with-live-target ticks** in the control vs **2** with
   the unstuck fix. Real bug.
2. **"Didn't fire nearly enough / didn't shoot on a good shot."** Two causes:
   (a) the fire gate fires at a **`predicted` lead point** (`pos + vel *
   (staleness + 6)`, line 1410) — when the target jukes, that phantom swings and
   the corridor test fails though a shot at the *real* body would connect;
   (b) the cooldown-duck branch (line 1493) makes the bot **hide behind cover**
   during its 12-tick cooldown instead of staying on the target — passive by
   design.
3. **"Ran face-first into the full enemy team."** No local force-count awareness
   in the shipped path. (Fork 2 tried to add "retreat when outnumbered" — see §8;
   it was falsified as a *win* lever, but the *insight* — don't feed a 1-v-N —
   folds into aggression-with-timing, §5.)

The through-line: Picasso **spins** (searching, re-lining, re-searching) instead
of **tracking**. The fix is a doctrine of decisive acquisition + smooth tracking,
below.

---

## 3. The doctrine — CQB principles → CTF per-tick rules

Each row: the verified doctrine (with its source quote), then the mechanized
rule. Ranked by expected K−D impact.

### A. Decisive engagement — "hesitation is fatal" ⭐ highest priority
> *"Hesitation can be fatal in CQB operations."* — CQB practitioner writing.
> *"Eliminate all enemy … by the use of fast, accurate, and discriminating
> fires."* — FM 90-10-1 App K. *"When it's time to go, go."*

- **Rule A1 — fire on the real body, not the phantom.** Test the corridor
  against the target's *actual last-seen position* (and a *small* lead), not a
  6-tick extrapolation that a juking target invalidates. Firing at a slightly
  stale real position beats firing at a confident-but-wrong prediction. *This is
  the single biggest suspected miss source.*
- **Rule A2 — shoot the tick the line is clear.** The moment a positively-ID'd
  enemy sits in the corridor and the gun is off cooldown, pull. Do not wait for a
  tighter settle than the corridor needs. (Windup 5 already forces a small delay;
  don't add more.)
- **Rule A3 — never idle with a live target in reach.** If we hold a fresh track
  and are neither firing nor repositioning to a *better* line, that is a wasted
  tick. Kills the "hide during cooldown" passivity.

### B. Target prioritization — greatest threat / finish before switching ⭐
> *"Destroy the greatest threat first … threat depends on weapons, range, and
> positioning."* / *"concentrate fires to destroy the greatest threat first, then
> distribute over the remainder."* / *"shoot the threat center mass and continue
> shooting until the threat is down."* / *"Avoid target overkill — use only the
> fire required."* — FM 3-90 direct-fire appendix; failure-to-stop doctrine.

- **Rule B1 — danger score, not just nearest.** Score each visible/fresh enemy
  by: aim-alignment on us (are they about to shoot?) > proximity > wounded (1-hit
  kill). Engage the top score. (Today's target pick is nearest-with-clear-ray
  plus wounded/focus-fire bonuses — extend it with "is aiming at me".)
- **Rule B2 — commit rounds to one target until it drops, then switch.** This is
  Fork 1 (target commitment), already shipped and lab-proven **14–5 vs
  baseline**. Doctrine confirms it: finish the threat, *then* redistribute. The
  "spinning between enemies" the user sees is exactly the anti-pattern doctrine
  warns against.
- **Rule B3 — avoid overkill.** Once a target is confirmed downed (or respawn-
  protected), release and reassign immediately — don't burn cooldowns on a corpse
  or an invulnerable spawn.

### C. Continuous scanning — "always hunting for the next threat" ⭐
> *"Maintain security at all times and be prepared to react to more enemy contact
> at any moment. Do not neglect rear security."* / *"sight fixation … belongs in
> the movies"* / *"viewing the world through a toilet-paper roll."* — App K;
> CQB practitioner writing.

- **Rule C1 — no dead time after a kill.** The instant a target drops with no
  other fresh track, sweep the cone toward the **densest remembered-enemy
  bearing** or the most likely approach — never freeze facing a cleared spot.
  (`scanAim` already sweeps for Overwatch/HomeDefender; extend the *hunting*
  posture to everyone with no current engage.)
- **Rule C1b — two-speed scan.** Doctrine (ATP 3-21.8): a **rapid** sweep to
  catch gross movement, then a **slow deliberate** pass that measurably raises
  detection. Mechanized: the idle sweep should slow its brads/tick near the
  densest-threat bearing (dwell where contact is likely) instead of raking at a
  constant rate — more cone-time where an enemy is about to appear.
- **Rule C1c — primary sector first.** Clear your assigned/forward sector before
  shifting the sweep to a secondary arc; don't rake the whole 360° uniformly.
- **Rule C2 — respawns mean re-scan.** Because downed enemies return in 72 ticks,
  a "cleared" direction is only clear for ~1.5 s. Bias the idle-sweep back toward
  recently-cleared kill spots on a timer.
- **Rule C3 — watch the hands/aim, not the body.** Research: *"faces don't
  operate firearms — hands do."* Our readable analogue is the enemy's **rendered
  aim dots / facing** — already used for `mateTargeted` focus-fire and the
  facing-me threat jink. Use enemy facing as the primary "is this one dangerous
  right now" cue in the danger score (B1).

### D. Movement & exposure — cover-to-cover, capped dashes, get off the X
> *"Each rush should last 3 to 5 seconds … kept short so gunners can't track
> you."* / *"pick your next covered position and route before moving; always hit
> the ground behind cover."* / *"Traveling when contact unlikely, traveling
> overwatch when possible, bounding overwatch when contact expected."* — ATP
> 3-21.8.

- **Rule D1 — cap open-ground exposure.** A dash across an uncovered corridor
  should be time-boxed; if we're still exposed after N ticks, break to the nearest
  cover. (The 3–5 s rush ≈ 150–250 ticks is *long* here; our corridors are short,
  so the mechanizable version is "don't linger in the open, and never freeze in a
  chokepoint" — the fatal-funnel rule.)
- **Rule D2 — plan the next cover node before leaving cover.** Our `navSteer` /
  `findDuckCell` / `findPeekCell` already do cover-aware pathing; the doctrine
  endorses keeping that discipline and *not* moving without a destination that
  ends behind cover.
- **Rule D3 — threat-gated posture.** Map contact-probability to aggression: no
  enemy seen → travel fast toward objective; enemy possible (fresh tracks nearby)
  → weave/overwatch; enemy engaged → fight from the best line. (We have weave /
  serpentine already; formalize the three-state gate.)

### E. Aggression & initiative — violence of action, but *timed* (OODA) ⭐
> *"Speed, Surprise, Violence of Action … overwhelm the enemy so they cannot
> defend or counter."* BUT *"speed means controlled rapid action, not reckless
> rushing"* and *"the key to interrupting an opponent's OODA loop lies not in
> acting faster, but in acting at the right time"* — strike on the **half-beat**,
> when the enemy is mid-commit (reloading/cooldown, turning, re-pathing).

This is the resolution of the user's paradox — *"be aggressive"* vs *"don't run
1-v-3 face-first."* Aggression ≠ charging. Aggression = **seizing the moment the
enemy is vulnerable**:

- **Rule E1 — press when we have the drop.** Enemy in our cone, not yet facing
  us (surprise) → close and fire; we're inside their OODA loop.
- **Rule E2 — press the wounded / isolated.** A lone or 1-hp enemy is the
  "half-beat" target — commit and finish (doctrine: *"close on lone shooters"*).
- **Rule E3 — press-vs-break is keyed to fire superiority, not head-count.**
  This is the sharpest verified finding (ATP 3-21.8 + ADP 3-90, 3-0 unanimous):
  on contact, *achieve fire superiority and assault* — press when you have (or
  can get) the better firing line; if you'd need everything just to hold the
  line, shift to **support-by-fire** so a mate can assault; **break contact ONLY
  if fire superiority is unachievable and no one is free to assault.** So the
  rule is *not* "retreat when outnumbered by count" — it's "break only when we
  can't win the *fire* exchange." Facing 2+ enemies already oriented on us with
  no cover and no surprise = no fire superiority → break to cover / bait them
  into our team's guns; but 2 enemies we've flanked or caught reloading = we
  *have* superiority → press. This both answers the user's "aware it loses a
  1v3" **and** explains why blanket "retreat when outnumbered" (Fork 2) was
  falsified: it broke contact in fights we were actually winning.
- **Rule E4 — never be the static target.** *"Freezing in a doorway makes you a
  static target at the focal point."* Combined with our slow turret: a frozen bot
  that also lets its gun drift is the worst possible state. Always be either
  firing, tracking, or repositioning-with-purpose.

### F. Angles — slice the pie, muzzle leads (maps to peek logic)
> *"The angle of vision expands … engage targets before stepping across the
> threshold."* / *"the first thing an adversary sees is your muzzle."* — CQB
> footwork writing; App K.

- **Rule F1 — pre-lay the gun on the peek.** Our `findPeekCell` + `blockedAim`
  already implement this: aim at the wall-blocked target *while* sidestepping to
  the cell that opens the line, so we fire the instant the ray clears. This is
  literally "muzzle leads, engage as the angle opens." Keep and sharpen it.
- **Rule F2 — widen LOS before committing the body.** Prefer approach angles that
  reveal the danger area incrementally (more ID time, less exposure) over walking
  straight into an unscanned corridor. Movement rate gated by how much the cone
  has cleared.

### G. Team play — sectors of fire, opposing corners, focus fire
> *"A team divides non-overlapping sectors of fire keyed to threat directions."*
> / *"shooters dominate from opposing corners, forcing the enemy to split fire."*
> / concentrate fires on one target. — App K; FM 3-90.

- **Rule G1 — don't stack; split the enemy's attention.** Soft teammate repulsion
  (`MateSpacing`) already spreads us; the doctrine says spread *across the
  enemy's frontage* so they can't cover two of us with one facing.
- **Rule G2 — focus fire.** Already implemented via mate aim-dot readback
  (`mateTargeted`, `FocusFireBonus`): pile onto the target a mate is already
  lined up on → two 1-damage hits become a kill. Doctrine-endorsed. Keep.
- **Rule G3 — friendly-fire discipline.** FF is ON and hits the *nearest*
  corridor unit. `friendlyBlocked` already vetoes a shot that would hit a mate —
  essential, keep. (This is the "positive ID / weapons-tight" gate.)
- **Rule G4 — stagger cooldowns (buddy overwatch).** Doctrine: buddy pairs
  **stagger reloads so both weapons are never down at once**, and the mover
  bounds *only while the partner is actively firing* and never past the partner's
  covering range. Our 12-tick fire cooldown *is* the "reload." Mechanized: when a
  nearby mate is mid-cooldown (or exposed and moving), prefer to *hold and cover*
  its line rather than both ducking together; advance across an open lane only
  while a mate has a live gun on the danger area. Turns two lone guns into a
  bounding pair — one always up.

---

## 4. Priority stack (what to build, in K−D-impact order)

1. **A1 — fire at the real body, not the phantom lead.** Suspected biggest miss
   source. Cheap, isolated, testable.
2. **C1/A3 — hunting posture: never idle, always tracking or sweeping toward the
   densest threat bearing.** Directly answers "always looking / hunting."
3. **§7 target-lock tracking** (below) — the unifying mechanic: smooth-track a
   locked enemy so the gun *stays* on them (keeps them lit + lined). Subsumes much
   of A/B/C.
4. **Corner-unstuck fix** (Fork 3) — real bug; camp-ticks 28→2; last A/B 7–3,
   K−D +16, lives 55–34 (10 games, needs a 20+-game confirm).
5. **B1 — danger score includes "is aiming at me."**
6. **E1–E4 — timed aggression** (press on the drop / wounded; break a no-drop
   1-v-N to cover). Behavior tuning — *validate hard*, translates least reliably.

**Discipline reminder (Arena rule):** *bug fixes translate to the live server;
behavior tuning often doesn't.* Rank fixes (A1, unstuck) above tuning (aggression
thresholds). Ship only a **proven** K−D improvement, A/B'd on paired seeds vs the
current shipped Picasso (CONTROL_COMMIT=1), and only with explicit go-ahead.

---

## 5. The unifying mechanic — TARGET-LOCK TRACKING ⭐⭐

*(This is the user's insight, and it is mechanically the highest-leverage single
change. It deserves its own section.)*

**Observation.** Picasso today runs a three-phase spin: spin until it sees a
player → spin to line up the shot → spin again after firing. Each phase throws
away slew budget and, because vision rides the aim, repeatedly *loses the target
into the fog* between phases.

**Why it happens, mechanically.** The desired aim is recomputed from scratch each
tick against a `predicted` lead point that (a) jumps when the target jukes or the
track ages, and (b) is abandoned entirely when no engage is active — at which
point the aim snaps to the *movement* direction (line 1591–1595), pointing the
cone away from where the enemy just was. Combine that with `AimRate = 5` (slow
turret) and every re-acquisition is a 15–30-tick tax during which a target-locked
opponent out-shoots us.

**The fix — commit to *tracking*, not re-lining:**

- **L1 — persistent lock target.** Extend Fork 1's commitment lock from "target
  *priority* preference" to "aim *ownership*": once locked onto an enemy, the
  turret's job every tick is to **null the bearing error to that enemy's current
  position** (smooth pursuit), not to chase a lead phantom or drift to the move
  vector. Hold the lock through brief fog (we already keep tracks for
  `freshShotTicks`); only drop it on death, prolonged fog, or a strictly-higher
  danger target (B1).
- **L2 — track the body; lead only for the shot.** Separate *tracking aim* (point
  at where they are, so they stay in-cone and out-of-fog) from *fire aim* (a
  small lead for the corridor test). Tracking keeps them lit; the tiny lead only
  gates the trigger. This directly implements A1 + C-continuous-vision at once.
- **L3 — keep them out of the fog by design.** Because cone = fire axis, a locked
  bot that holds its gun on the enemy *automatically* keeps them visible. The
  behavior the user described ("follow them, keep them in our line of fire by
  tracking perfectly") is exactly L1+L2 — it is not a new subsystem, it's making
  the aim *stick*.
- **L4 — movement serves the lock.** While locked and on cooldown, don't hide
  (kills A3); instead micro-position to *maintain or improve the firing line*
  (strafe to hold LOS, close if we have the drop, break only for a no-drop 1-v-N
  per E3). Movement and aim both serve "stay locked and lethal."

**Predicted effect on the metric.** Fewer wasted slew ticks → gun on target a far
higher fraction of the time → more shots inside the corridor per engagement →
higher hit-rate and, crucially, we shoot *first* (initiative/OODA). That is
straight K−D. **This is the top candidate to build and A/B next.**

**Risk / falsification.** Tracking a *single* locked target can tunnel-vision the
bot into ignoring a higher threat (B1) or an incoming flank (C1). Guardrails:
lock is *breakable* by a strictly-higher danger score, and the idle-sweep only
applies when *no* lock is held. Must A/B against commit-only to prove the
tracking (not just the commitment) adds differential.

---

## 6. What's already confirmed / falsified (don't re-litigate)

- ✅ **Fork 1 target commitment** — lab 14–5 vs baseline; shipped in Picasso:v1.
  Doctrine-endorsed (B2). Keep as the control baseline (`CONTROL_COMMIT=1`).
- ✅ **Corner-unstuck (Fork 3)** — real bug (camp-ticks 28→2). Last 10-game A/B:
  7–3, K−D +16, lives 55–34. Promising; **needs a 20+-game paired confirm** before
  it counts.
- ⛔ **Fire-discipline knob-tuning** (tighter deadband, less lead, shorter fresh
  window) — **falsified both directions** 2026-07-14. Don't re-sweep knobs; the
  lever is *logic* (A1 real-body fire, L target-lock), not thresholds.
- ⛔ **Fork 2 blanket "retreat when outnumbered"** — falsified as a *win* lever
  (11–9 vs commit, worse than commit's 14–5): retreating undoes commitment's
  kill-conversion. The *insight* survives only as timed E3 ("don't feed a no-drop
  1-v-N"), not as a standing retreat rule.

---

## 7. Test protocol (how any change earns the right to ship)

1. Build the fork behind a `CombatTune` flag so the shipped path stays
   byte-identical until proven.
2. Paired A/B on the in-process harness: hunter slots vs `CONTROL_COMMIT=1`
   (current shipped Picasso), **identical seeds**, **20+ games**, 10 000 ticks.
3. Read the **K−D differential** and **lives-remaining** lines (the tiebreak
   metric), not just win count. Camp-ticks as a secondary health check.
4. A change ships only if it improves K−D on the paired metric with a margin that
   survives the seed noise (leaderboard rank swung 4↔2 within a session — small
   edges are noise).
5. **Never upload without explicit Maxwell go-ahead.** Anonymous policy name.
   One new branch off fresh main, one PR, open it — don't self-merge.

---

*Provenance: research claims verified 60/60 (0 refuted) in the deep-research pass;
mechanics cross-checked against `src/ctf/sim.nim` and `players/baseline/baseline.nim`
@ branch `maxwell/ctf-eval-harness`.*
