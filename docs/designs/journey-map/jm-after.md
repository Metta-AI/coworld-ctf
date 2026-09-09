<!-- Source: ~/.ctf/knowledge/stranger-walk/journey-map/jm-after.md, copied verbatim 2026-09-09 (shot paths repointed to ./shots/) -->

# Journey Map — AFTER submit (jm-after) — era 2026-09-09, live paintbot-v0.7.374 (GV61/GLORYVERSION16), main ≈070d4805

Source: Walk 1 stranger runs `sonnet-a` (finished, through resubmission) and `sonnet-b` (killed_by_teardown
mid-round-wait, exit 137 — infra teardown side effect, not a stranger failure or dead end; see
`docs/designs/STRANGER_WALK.md` protocol v1.2). Both strangers were given the **same** throwaway
`GITHUB_USER=gloriouslyagentic` credential and ran concurrently — this is a Walk-1 test artifact
(shared identity across parallel walker runs), not something a real solo beginner would hit; flagged
inline wherever it shaped what a run observed. Walk 1 itself is VOID as a measurement (its prompt fed
milestones) but the surfaces touched and defects hit are real and cited by transcript line offset `[n]`.

## S1 — Submission response (CLI) — `uv run coworld submit <policy>:vN --league <id> --no-open-browser`
- Reached from: policy built + uploaded (`coworld upload-policy`); ~848 lines / ~99 tool calls into the
  run before the first submit call fired (sonnet-a `[848]`).
- What it says: `"Submitting … to league … / Submitted to league / Submission: sub_… / Status: pending /
  Auto champion: always / Placement runs asynchronously; check the status page for updates. / Status
  page: https://softmax.com/observatory/v2?tab=uploads&detail=policy-version:…"` `[849]` — a single
  terse confirmation plus a URL, no ETA.
- Beginner question answered: HOW AM I DOING (partial) — confirms accepted, not confirms placed. WHAT
  HAPPENED (no) — "pending" without saying what pending means or how long.
- Where the thread breaks: the printed "status page" URL opens the Observatory "Your Policies" detail
  view, which rendered as **stuck skeleton loaders** ("LEAGUE RANKINGS" / "LEAGUE STATUS HISTORY" /
  "RECENT EPISODES" all grey placeholder bars, never resolved) on both the submit-time screenshot and a
  later confirmation screenshot (`status-page.png`, `policy-detail-final.png`) — dead end, no next step
  from that page; the stranger abandoned it and went back to CLI polling (`coworld memberships --mine
  --json`, looped every 15s) `[909]`–`[920]`.
- Hand-off: back to CLI polling loops (`coworld memberships`, `coworld rounds`), not the printed URL.
- Owning lane: league backend (submit response) + Observatory epic (status page).
- Fixed since: OPEN (status-page skeleton not in original punchlist; not addressed by any of #492–#507).

## S2 — Standings row — `https://softmax.com/paintbot` (public, no sign-in)
- Reached from: CLI told it to check "the status page"; stranger instead re-navigated to the public
  league URL and used in-page text search for its own name `[883]`, `[925]`.
- What it says: live-checked today (2026-09-09, signed-out headless browser): a right-rail "COMPETITION
  DIVISION" ladder (`1 soft-codexter-t2 383.5K LEADER`, deltas like `+144.5K behind`), a left "HIGHLIGHTS"
  list of terse lines like `"14th won a field of 16"`, and "LEAGUE LEADERS" awards (`MOST LETHAL`,
  `UNTOUCHABLE`, `THE CLOSER`, `POINT MACHINE`) — none of these labels are defined on the page itself.
- Beginner question answered: HOW AM I DOING — yes, if you can find your row (a numeric rank + a score
  in K-units). WHY am I ranked there — no, no cause is shown next to the row.
- Where the thread breaks: (1) jargon — "won a field of 16", "LEADER"/"+N behind", "ON THE STAGE",
  "MOST LETHAL/UNTOUCHABLE/THE CLOSER/POINT MACHINE" are all unexplained; (2) **name mismatch** — the
  stranger searched the page for its *policy* name `"opportunist"` and got "No matches found" `[884]`,
  `[926]`; it only ever found itself by searching its *player* name `"gloriouslyagentic"` `[1001]`,
  `[1002]`, `[1066]` — a beginner who only knows their policy name has no way to find their row; (3)
  **live-checked today**: the round-list "Search player or code" box returned `"No episode in the window
  matches."` for `gloriouslyagentic` once ~60 rounds had passed since Walk 1's round #4544 — old
  submissions age out of the searchable window with no indication of what "the window" is or how to
  reach further back (screenshot: `~/.ctf/knowledge/stranger-walk/journey-map/./shots/jm-after-01.png`).
- Hand-off: gave up on UI search, fell back to CLI (`coworld memberships --mine --json`, `coworld rounds
  <id> --json`) to get its real rank/score `[996]`.
- Owning lane: Observatory epic (search/label consistency) + wiki (jargon glossary).
- Fixed since: OPEN — bb86dcc9 (#497, "why #1 is #1") and ebb90cf0/588f1ac7 (#505/#506) are the THE WHOLE
  epic's own follow-up on exactly this "no cause shown" gap, but #505 records the underlying platform
  data as **BLOCKED** (no per-seat standing-before/after, no per-deed breakdown client-side) — the
  legibility fix is scoped, not shipped. Name-mismatch and search-window jargon: not in original
  punchlist; UNKNOWN / not addressed.

## S3 — Own-round replay — same URL (featured/live match), `coworld rounds <round_id> --json`
- Reached from: CLI polling showed round #4544 `completed`; stranger cross-referenced its
  `policy_version_id` inside the round's `entrant_attributions` via CLI JSON `[981]`–`[996]`, *then*
  separately noticed its player name `"gloriouslyagentic"` inside the standings page's live "featured
  match" iframe by luck (that round happened to still be on stage) `[1001]`–`[1003]`.
- What it says: the CLI gave a structured, correct result (`rank 12, score 807.0, wins: 2, episodes_scored:
  13`) `[996]`; the web UI gave a visual confirmation (a screenshot of the featured-match iframe with
  its player name inside), not a dedicated "here is your round" page or permalink.
- Beginner question answered: WHAT HAPPENED — yes, but only via the CLI JSON, not the website. The
  website confirmed *that* it played, not *how* it did.
- Where the thread breaks: no stable deep link — the page's `?e=<uuid>` episode param changed on every
  navigation in this session and again on a fresh page load during today's live check (`e=416bd795…` →
  `e=439d4023…` on a second load of the same URL) — a beginner cannot bookmark or share "my round."
- Hand-off: back to CLI (`coworld episode-logs`, `coworld episodes -r <round_id>`) to diagnose why 2 of
  14 episodes in that round `failed` (unrelated seat, "player slot 8 never joined the lobby within 7200
  lobby ticks") `[1121]`, `[1125]` — the stranger had to independently rule out that this was *its own*
  policy's fault.
- Owning lane: paintbot engine/viewer (episode-id stability) + Observatory epic (permalink).
- Fixed since: UNKNOWN — not in original punchlist; no PR title matches "permalink" or "episode id."

## S4 — Score-bug strip — replay viewer overlay (per-seat running multiplier readout)
- Reached from: the same public replay viewer used above, described from an *earlier pre-submit* replay
  watch (`paintbot.r4538.e11`, M3) since the UI is identical; the stranger's own post-submit featured
  match was mid-round (6:47 on the clock) when screenshotted, not toward the multiplier-heavy endgame.
- What it says (stranger's own words): `"live per-team Glory multiplier badges (e.g. CLOSING TIME ×3,
  FINAL 8 ×2)"` `[109]` — read off the badges directly, no separate legend consulted.
- Beginner question answered: HOW DO I GET BETTER (partial) — the badges show *that* late-round survival
  multiplies score, which the stranger correctly generalized into design advice for its own policy
  (`"prioritize securing kill/objective deeds late in a round when multiplier stacks... are high"` `[43]`).
- Where the thread breaks: none observed for badge legibility itself; the break is upstream (S2/S3) —
  reaching *your own* round's endgame moment, rather than an arbitrary one, is the hard part.
- Hand-off: informed policy-tuning choices for the M8 retune (see S6).
- Owning lane: paintbot engine/viewer.
- Fixed since: FIXED (#498, "score-bug strip: pact grouping + one-word intent" — landed the same day,
  after Walk 1, adding pact grouping + a one-word intent readout to this exact element; #474/#473
  pre-date Walk 1 and already built the ×N multiplier pulse itself).

## S5 — Endcard — round-end summary panel
- Reached from: not reached. Neither stranger's transcript shows a round ending while being watched live
  by that stranger's own session (sonnet-a's featured match was mid-round at capture time; sonnet-b was
  killed while still waiting for its round to finish).
- What it says: NOT OBSERVED by either stranger.
- Beginner question answered: none — surface not reached.
- Where the thread breaks: no next step ever pointed a stranger at "wait for/watch your round end."
- Hand-off: NONE.
- Owning lane: paintbot engine/viewer.
- Fixed since: OPEN — 588f1ac7 (#505) is the THE WHOLE epic's own "endcard v1 standings-delta" work and
  explicitly reports itself **BLOCKED**: no outbound API from the client, no seat→player_id key on the
  wire, and `recent_rounds` is schema-present but null on every live entry — a standings-delta endcard
  is not buildable today. ebb90cf0 (#506) scopes the metta-side fix but has not landed.

## S6 — Iteration loop — retune → rebuild → re-upload → resubmit → observe
- Reached from: after confirming v1's real result (rank 12/17, score 807), the stranger edited
  `recall_seconds` 8.0→6.0 and `max_calls` 6→8 in its own policy, rebuilt the Docker image, uploaded as
  `:v2`, and resubmitted `[1142]`–`[1155]`.
- What it says: `coworld submit` gave the same terse pending/status-page response as v1; the site gave no
  A/B comparison view.
- Beginner question answered: HOW DO I GET BETTER (attempted, failed) — v2 was **disqualified from
  Paintbot (Season 2) before playing any round**, while staying stably "competing" in the unrelated Elite
  Paintbot league `[1271]`. The stranger correctly diagnosed via CLI that the disqualification traced to
  an *unrelated* round-execution failure (a different seat's lobby-join timeout), not its own change
  `[1141]` — meaning the one real "did my tweak help" experiment in this walk returned **no signal at
  all**, confounded by an unrelated platform reliability issue.
- Where the thread breaks: (1) no comparison UI (before/after score, A/B) exists anywhere — the stranger
  had to hand-assemble the comparison from two separate CLI JSON pulls; (2) `auto_champion=always` on
  Season-2 submission **silently also placed a membership in the separate Elite Paintbot league** — the
  stranger discovered this only by listing `coworld memberships --mine` and had to manually
  `coworld retire-membership` it at the very end, calling it explicitly out-of-scope `[1331]`; (3) — test
  artifact, not a beginner-facing bug — sonnet-b, running concurrently on the **same shared throwaway
  identity**, uploaded its own `opportunist-v1:v2` mid-session and silently displaced sonnet-a's `v2` as
  league champion `[1104]`, a collision that would not occur for a real solitary beginner but shows the
  champion seat has no contention protection.
- Hand-off: back to CLI polling to watch the new membership status.
- Owning lane: league backend (auto_champion league-scoping, champion contention) + Observatory epic (A/B
  view).
- Fixed since: UNKNOWN for all three — none of #492–#507 touch `auto_champion` scoping, champion
  contention, or an iteration/comparison UI.

## S7 — Forum / help
- Reached from: proactively fetched `https://softmax.com/paintbot/forum.md` early, before submission
  `[65]`.
- What it says: `"The forum posts discuss a competitive battle royale ladder system but provide no
  explicit details about closing zones or team mechanics. The content focuses on scoring systems..."`
  `[66]` — a summarized digest, not a live thread the stranger could post to or ask a question in.
- Beginner question answered: none directly — no case of the stranger asking a question and getting a
  human (or other-agent) answer; it only ever pulled a static one-shot summary.
- Where the thread breaks: no evidence of an interactive help channel anywhere in either transcript — no
  attempt to post, no Discord link followed (the profile page had a Discord-link opt-in the stranger
  explicitly skipped `[552]`), no other-player contact.
- Hand-off: NONE — reverted to reading more wiki pages instead.
- Owning lane: forum (metta) / community.
- Fixed since: UNKNOWN — not in original punchlist.

## Threads
- B1: S1 status page → skeleton loaders never resolve → CLI polling loop instead of the printed URL.
- B2: S2 standings search → policy-name search returns no matches (only player-name works) → gave up on
  in-page search, used CLI JSON to self-locate.
- B3: S2 standings search (live-checked today) → `"No episode in the window matches"` for an
  ~60-round-old submission → no path shown to older rounds.
- B4: S2/S3 → `?e=<uuid>` episode param is not a stable permalink → cannot bookmark/share "my round."
- B5: S3 → 2/14 episodes in the stranger's own round `failed` for an unrelated reason → stranger had to
  independently CLI-diagnose to rule itself out as the cause.
- B6: S5 endcard/standings-delta → platform data gaps (no client outbound API, no seat→player_id on
  wire, `recent_rounds` never populated) → BLOCKED per #505, not shippable yet.
- B7: S6 iteration → v2 disqualified for an unrelated round-execution failure → the one real "did my
  change help" test returned no usable signal.
- B8: S6 iteration → `auto_champion=always` silently also seated a membership in Elite Paintbot → manual
  `retire-membership` cleanup at the end, self-flagged as scope creep.
- B9: S6 iteration (test artifact, not beginner-facing) → shared throwaway identity across two concurrent
  Walk-1 runs → champion seat displaced mid-experiment.
- B10: S7 forum → static digest only, no interactive help path found → no hand-off, reverted to docs.

## Punchlist status
- `coworld run-episode --run` argv undocumented · FIXED #499 (docs now show exact syntax), reinforced by
  #500 (fixed the underlying env contract) and #503 (README reconciliation).
- `-p`-mode background-task loss (protocol v1.1) · FIXED #492 (mitigation landed in the same PR that
  documents the finding; `run.sh`/`resume.sh` auto-continue).
- sonnet-b's detached-launch SIGKILL (protocol v1.2, closely related) · FIXED #492 (same PR; `docs/designs
  /STRANGER_WALK.md` "Protocol v1.2: detached launch (2026-09-09, sonnet-b finding)").
- softmax.com sign-in is GitHub-OAuth-only, no email/password/magic-link · OPEN — now explicitly
  documented as a known limitation in `docs/wiki/build-and-submit.md` (`"GitHub OAuth only — there is no
  token or API-key alternative as of this [date]"`), but the constraint itself is unchanged.
- `battle-royale-s2` wiki page was an empty stub · FIXED #496 (battle-royale-s2 rules + build-and-submit
  pages authored), refreshed by #502.
- Self-reported M6 without proof, caught by judge.md's "claim not proof" rule · FIXED #492 — the rule
  (`tools/stranger_walk/judge.md` lines 9-10, 27) shipped in the initial instrument landing; neither
  sonnet-a nor sonnet-b actually triggered a false M6 claim, so this could not be re-verified against
  their transcripts directly.

## What a beginner never learns after submitting
- What "pending" actually means or how long qualification normally takes.
- Why they're ranked where they are — no deed-level or before/after cause is ever shown next to a
  standings row (the platform data for this is BLOCKED, per #505).
- What "won a field of 16," "LEADER," "+N behind," "MOST LETHAL/UNTOUCHABLE/THE CLOSER/POINT MACHINE"
  actually mean or how they're computed.
- Whether a rank change after resubmitting reflects their policy or an unrelated platform hiccup — the
  one real iteration attempt in this walk produced a disqualification that had nothing to do with the
  change.
- That a Season-2 submission also seats them, unasked, in a separate Elite Paintbot league.
- Where to find a specific old round of theirs once it scrolls out of the standings search window.
- Who to ask, if anything looks wrong — no interactive help surface was ever found.
