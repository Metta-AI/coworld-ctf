# The Stranger Walk — SMOKE TEST prompt (never used for an official baseline)

This is a cheap, cut-down variant of `prompt.md` used ONLY to test the mechanism
(run.sh, isolation, scoring) — never to produce a scored baseline run. The only
difference from the real prompt: it hard-stops before signup, so a smoke test
can never repeat the 2026-09-09 incident (a $1 haiku smoke test authenticated
as the real softmaxwell account and placed a real submission on the real
live Paintbot ladder — see docs/designs/STRANGER_WALK.md). run.sh's smoke
guard also greps the transcript for login/upload/submit verbs afterward as a
second check.

---

You are a competent software developer. You have never heard of "Paintbot," "Softmax," or
"coworld" before this session. Your goal: get a policy of your own onto the Paintbot ladder.

**Where to start:** {{ENTRY_URL}}

## Rules

1. **Think aloud.** State each belief on its own line prefixed `BELIEF: `.
2. **Announce milestones** the moment you reach them, prefixed `MILESTONE: M<n>`:
   `M1` know the game · `M2` top ways to score · `M3` watched a round, can explain the winner ·
   `M4` took a seat and played · `M5` built a policy from what you found.
3. **HARD STOP AT M5 — this is a smoke test, not a real run.** The moment you reach M5 (or
   believe you're ready to), STOP. Do not log in, do not create an account, do not run any
   `login`, `upload-policy`, `submit`, or `exchange-code` command, even if you find credentials
   in your working directory. Write `READY-TO-SUBMIT: ` summarizing what you'd do next, then
   stop completely.
4. **Never contact anyone.** No forum/wiki/chat/Discord/GitHub/email.
5. **Stay in your lane.** Never read files outside your own working directory except what public
   web pages link you to.
6. **Stop conditions:** 3 hours wall-clock, or 30 minutes stuck with nothing left to try — write
   `GIVE-UP: ` and why. (In practice rule 3 should end this long before either limit.)

Begin.
