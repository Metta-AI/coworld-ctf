# Stranger Walk — judge rubric

This is read by the HUMAN/AGENT judging a completed run, never by the stranger. The judge has
full internal knowledge (source, memory, wiki) that the stranger does not, and uses it only to
grade the stranger's beliefs and milestone claims after the fact — never to help a run in flight.

## Milestone completion criteria

A milestone counts as REACHED only if the stranger's own transcript supports the claim — a
`MILESTONE: M<n>` line is a claim, not proof. Verify each one:

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

If credentials never existed in the run env, M6–M8 are expected to be unreached; the run should
instead show a `READY-TO-SUBMIT:` line. Grade that line's accuracy against what the real
submission flow requires (cite the actual endpoint/UI path from the codebase or docs) — a
confident-but-wrong `READY-TO-SUBMIT:` is a wrong belief, not a milestone.

**Owner decision 2026-09-09:** the stranger self-signs-up with a real address
(`STRANGER_EMAIL`, from `~/.ctf/knowledge/stranger-walk/env`, copied to `<run-id>/env` by
run.sh). Two special markers follow from this:

- `WAITING: ` — the stranger hit an email-verification step it can't complete alone and stopped
  cleanly, to be resumed via `resume.sh <run-id> "<code>"` once the owner relays the code from
  their inbox. The wall-clock between the `WAITING:` line and the resume is real time the
  stranger spent blocked on a human, not stuck for lack of ideas — `score.py` tags that gap
  `"owner_latency": true` and totals it separately (`owner_latency_minutes_total`). Report it in
  `STRANGER_WALK.md` as its own line, not folded into "stuck minutes."
- `BLOCKED-M6: ` — the site requires a GitHub/Google login the stranger has no credentials for
  (as opposed to an email/password it could self-serve). This is a genuine M6 blocker, not a
  process failure — verify the claim against the real signup flow and record it as the top-line
  finding for what's stopping strangers from ever reaching M6.

## Scoring each BELIEF

For every `BELIEF:` line in the transcript, the judge assigns exactly one of:

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
- A **stuck episode** is any ≥10-minute gap between `BELIEF:`/`MILESTONE:` lines. `score.py`
  finds these; the judge should read what tool calls happened during the gap and write one line
  on what actually blocked progress (a missing link, a confusing label, a slow page, a dead end).

## Attribution rule

Never name a policy by author or team in any deliverable — cite by `pv<id>` only, pulled from a
public standings/replay page or the codebase. This rubric and its outputs are internal judging
material; they still follow the no-attribution rule because the doc they feed
(`docs/designs/STRANGER_WALK.md`) is a PR artifact.
