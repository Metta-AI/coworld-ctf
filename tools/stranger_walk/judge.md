# Stranger Walk — judge rubric

This is read by the HUMAN/AGENT judging a completed run, never by the stranger. The judge has
full internal knowledge (source, memory, wiki) that the stranger does not, and uses it only to
grade the stranger's beliefs and milestone reach after the fact — never to help a run in flight.

## Protocol v2 (2026-09-09, owner ruling): post-hoc extraction, not self-report

Protocol v1's `prompt.md` handed the stranger the eight milestones by name and asked it to narrate
`BELIEF: `/`MILESTONE: ` lines as it formed them. The owner ruled that invalid as a clean-slate
discovery test: telling a stranger "here are the 8 things a game must teach you, announce each
one" primes it to go hunting for exactly those 8 things, which is scaffolding, not the stranger's
own unprompted path. Protocol v1's five runs are kept on record (they still surfaced real,
independently-verifiable defects — see `docs/designs/STRANGER_WALK.md`'s "Protocol v2" section)
but are **invalid as a baseline** for "did the game explain itself with no help."

Protocol v2's `prompt.md` gives the stranger only the goal, the think-aloud instruction, the
contact/lane rules, and the signup/`WAITING: ` mechanics (kept because it's a real synchronization
primitive, not milestone scaffolding — see that file's own note). It does **not** mention
milestones, beliefs, or the words "blocked"/"ready" at all. `score.py` mechanically computes tool
counts, digs, and stuck-episode timing straight from transcript timestamps — it can do all of that
with zero cooperation from the stranger. What it cannot compute is milestones and beliefs, because
there's no longer a `MILESTONE:`/`BELIEF:` line to find. That's now the judge's job, done directly
against the raw transcript:

1. Run `score.py <run-id>` first — it writes the mechanical skeleton (`milestones: {}`,
   `beliefs: []`, `judged: false`) so you have tool-call counts, digs, and stuck episodes to work
   from.
2. Read `transcript.jsonl`'s assistant `text` blocks in chronological order (skip `tool_use`/
   `tool_result` blocks — you're reading the stranger's own reasoning prose, not its actions,
   though the actions around a passage are useful context for a stuck episode).
3. For each milestone M1–M8 below, find the FIRST point in that prose where its criteria are
   actually met (not claimed — the stranger isn't claiming anything anymore, so there's nothing to
   fact-check against a self-report; you're finding it yourself). Record, in the same shape
   Protocol v1 used so downstream tooling doesn't change: `{"timestamp": ..., "elapsed_s": ...,
   "tool_call_count": ..., "sentence": "<your one-sentence account of what the transcript shows,
   citing the specific tool call or passage>"}`. The `tool_call_count` is whatever `total_tool_calls`
   value applied at that point in the transcript — count `tool_use` blocks in turns up to and
   including the one you cite.
4. Separately, extract **belief statements** — any sentence in the prose asserting how the game,
   scoring, or submission process works, hedged or confident. Aim for the same density Protocol
   v1's self-reported beliefs had (roughly one substantive claim every few minutes of active
   reasoning); don't invent claims the prose doesn't support, and don't extract restatements that
   add no new claim. For each: `{"text": "<quoted or lightly paraphrased>", "timestamp": ...,
   "elapsed_s": ..., "tool_call_count": ..., "verdict": "true"|"false"|
   "unknowable-from-public-surfaces", "source": "<path/file:line, memory doc, or public URL>",
   "note": "<why a stranger would land here, for false/partly beliefs — this is punchlist material>"}`.
   Grading happens in this same pass — there's no separate "judge the self-report" step anymore.
5. Hand-edit `<run-dir>/score.json`'s `milestones` and `beliefs` keys with what you found (also set
   `furthest_milestone`). Re-running `score.py` afterward is safe — it preserves whatever's already
   in those two keys and only recomputes the mechanical fields around them.

## Milestone completion criteria

- **M1 (knows the game).** The stranger can state genre + objective + format (e.g. "battle-royale
  team paintball, last team standing") in its own words, not just quoted page text pasted verbatim
  with no evidence of comprehension.
- **M2 (top ways to score).** The stranger names concrete scoring actions (tags, captures, zone
  control, survival, etc.), not just "there's a leaderboard."
- **M3 (watched a round, explains the winner).** The stranger must have actually opened a
  replay/live view (a tool call fetching a round/replay page or asset) AND produced a causal
  explanation ("X won because..."), not a guess made from the standings table alone.
- **M4 (took a seat and played).** Only counts if the site actually offered a human-playable seat
  and the transcript shows the stranger driving it (inputs sent, a match outcome observed). If no
  such surface exists or is reachable from the public entry point, this milestone is UNREACHABLE
  for the run — record that explicitly, do not mark it "stuck."
- **M5 (built a policy).** A real artifact must exist in the run directory (code, config, or a
  fully specified spec) that the stranger believes implements a strategy, built from what it
  actually learned in-session (not boilerplate copy-pasted without adaptation).
- **M6 (submitted).** Only counts with real evidence of a successful submission call/response.
- **M7 (saw it in standings).** Only counts if the stranger fetched the standings/leaderboard
  again after submitting and located its own entry.
- **M8 (changed it, saw rank respond).** Requires a second submit + a second standings check
  showing a rank delta the stranger attributes to its change.

If the stranger never obtains usable credentials, M6–M8 are expected to be unreached. Judge
whatever the stranger says about why it's stopping (there's no `READY-TO-SUBMIT:`/`BLOCKED-M6:`
marker to look for anymore — read its own words) against what the real submission flow requires
(cite the actual endpoint/UI path from the codebase or docs); a confident-but-wrong account of why
it's stuck is a wrong belief like any other, graded the same way.

**Owner decision 2026-09-09 (unchanged by Protocol v2):** the stranger self-signs-up with a real
address (`STRANGER_EMAIL`, from `~/.ctf/knowledge/stranger-walk/env`, copied to `<run-id>/env` by
run.sh). One marker survives the v1→v2 cut because it's a synchronization primitive, not
scaffolding:

- `WAITING: ` — the stranger hit an email-verification step it can't complete alone and stopped
  cleanly, to be resumed via `resume.sh <run-id> "<code>"` once the owner relays the code from
  their inbox. The wall-clock between the `WAITING: ` line and the resume is real time the
  stranger spent blocked on a human, not stuck for lack of ideas — `score.py` tags the gap that
  follows `"owner_latency": true` and totals it separately
  (`owner_latency_minutes_total`). Report it in `STRANGER_WALK.md` as its own line, not folded
  into "stuck minutes."

## Scoring each BELIEF

For every belief you extract, assign exactly one of:

- **true** — matches the real system. Cite the source of truth: a `path/file:line` in the
  codebase, a named internal memory file, or a public page URL the stranger itself could have
  reached.
- **false** — contradicts the real system. Cite the same, plus one sentence on why a stranger
  would form this false belief (missing/misleading label, stale doc, absent affordance, etc.) —
  that sentence is the punchlist material.
- **unknowable-from-public-surfaces** — the belief is a reasonable guess that the public surfaces
  the stranger had access to simply do not confirm or refute. This is itself a finding (a gap in
  what's exposed), distinct from a wrong belief.

Wrong beliefs are a first-class output of this exercise, not noise to filter out. A run with zero
wrong beliefs and a shallow milestone reach is a worse outcome than a run with several wrong
beliefs that still reached deep — it means the stranger didn't engage enough to be wrong about
anything interesting.

## Dig counts and stuck episodes

- A **dig** is any tool call that moves the stranger to a different host or a materially
  different surface (e.g. softmax.com → github.com, or observatory/v2 → wiki → forum) in search
  of a fact the current surface didn't have. `score.py` computes this mechanically from
  `WebFetch`/`WebSearch` targets; the judge should sanity-check a few by hand.
- A **stuck episode** is now (Protocol v2) any ≥10-minute gap between consecutive assistant turns
  — `score.py` finds these mechanically, with no marker needed. This is a coarser signal than it
  sounds: a stranger genuinely waiting on a slow qualification round tends to check in every
  30-300s rather than fall silent, so a real ~15-20 minute wait can hide as several turn-gaps that
  individually never cross 10 minutes — `stuck_minutes_total` is a lower bound, not a
  measurement. The judge should read what tool calls happened during each reported gap (attached
  in `stuck_episodes[].tool_calls_during`) and, more importantly, should also read the surrounding
  transcript directly for genuine multi-turn wait stretches the mechanical threshold missed —
  write one line on what actually blocked progress (a missing link, a confusing label, a slow
  page, a dead end, a qualification/round-fulfillment wait).

## Attribution rule

Never name a policy by author or team in any deliverable — cite by `pv<id>` only, pulled from a
public standings/replay page or the codebase. This rubric and its outputs are internal judging
material; they still follow the no-attribution rule because the doc they feed
(`docs/designs/STRANGER_WALK.md`) is a PR artifact.
