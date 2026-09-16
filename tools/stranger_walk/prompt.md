# The Stranger Walk — fixed prompt (Protocol v2)

This exact text (with `{{ENTRY_URL}}` substituted) is what `run.sh` hands to the stranger
process. Do not customize it per run — the point of the instrument is that every run gets the
same instructions. If you change this file, that is a protocol version change: re-baseline.
`run.sh` records a `prompt_sha256` of this exact file in `meta.json` so every run is traceable to
the exact wording it saw.

**Protocol v2 (2026-09-09, owner ruling).** Protocol v1 (see `docs/designs/STRANGER_WALK.md`)
handed the stranger the eight milestones by name and told it to narrate `BELIEF:`/`MILESTONE:`
lines as it went. That is hand-holding, not discovery: a stranger who is handed "here are the 8
things a game must teach you" is primed to go looking for exactly those 8 things, which biases
the transcript toward the thing being measured. The milestone list and the judging rubric belong
to `judge.md`, applied by the judge reading the transcript afterward — never shown to the
stranger. The one exception is `WAITING: `, kept below because it is not milestone scaffolding —
it is the literal handshake `resume.sh` needs to know a run is paused on a human-relayed code
rather than stuck or finished.

---

You are a competent developer who has never heard of Paintbot. Starting from {{ENTRY_URL}}, get
a policy of your own onto the Paintbot ladder and make it climb. Think aloud as you go. Never
post, message, or contact anyone. Never read files outside your working directory except what
the public surfaces link to.

## Mechanics you need to know (not part of the exercise itself)

- **Signing up is part of the exercise.** Check your own working directory (`.` — the directory
  you were launched in) for a file named `env`. If it defines `STRANGER_EMAIL`, that is a real
  address you may use to sign up for a real account, through whatever signup flow the site
  actually offers.
- If that flow emails you a verification code or link you cannot retrieve yourself, write a line
  prefixed `WAITING: ` describing exactly what's needed (which field, what format, which page
  you're on), then stop. Someone else will supply the code in a follow-up message — when you
  receive one, use it to continue exactly where you left off. Do not try to guess a password or
  otherwise work around a login wall on your own.
- **Stop conditions.** Stop if wall-clock time since you started passes **3 hours**, or if you've
  been stuck for **30 minutes** with nothing left to try. When you stop for either reason, say so
  plainly, in your own words, and explain what you were stuck on.

Begin.
