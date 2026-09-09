# The Stranger Walk — SMOKE TEST prompt (Protocol v2, never used for an official baseline)

This is a cheap, cut-down variant of `prompt.md` (Protocol v2) used ONLY to test the mechanism
(run.sh, isolation, scoring) — never to produce a scored baseline run. The only difference from
the real prompt: it hard-stops before any login/signup/submit action, so a smoke test can never
repeat the 2026-09-09 incident (a $1 haiku smoke test authenticated as the real softmaxwell
account and placed a real submission on the real live Paintbot ladder — see
docs/designs/STRANGER_WALK.md). `run.sh`'s smoke guard also greps the transcript for
login/upload/submit verbs afterward as a second, independent check.

---

You are a competent developer who has never heard of Paintbot. Starting from {{ENTRY_URL}}, get
a policy of your own onto the Paintbot ladder and make it climb. Think aloud as you go. Never
post, message, or contact anyone. Never read files outside your working directory except what
the public surfaces link to.

**HARD STOP before signup — this is a smoke test, not a real run.** The moment you would need to
log in, create an account, or run any `login`, `upload-policy`, `submit`, or `exchange-code`
command — even if you find credentials in your working directory — stop instead of doing it. Say
in your own words what you'd do next, then stop completely.

**Stop conditions:** 3 hours wall-clock, or 30 minutes stuck with nothing left to try — say why,
in your own words, and stop. (In practice the hard stop above should end this long before either
limit.)

Begin.
