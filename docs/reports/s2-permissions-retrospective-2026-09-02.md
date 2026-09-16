# Season 2 changeover: league permissions retrospective

Date: 2026-09-02. Scope: the Paintbot Season 2 cut-over on the Softmax Observatory platform,
2026-08-31 through 2026-09-02, as executed by James's agents (Claude Code PM session, Codex
lanes, the starter-policy loop) and Maxwell's orchestrator ("testing grounds 5").

Evidence: fourteen agent transcripts (Claude Code, Codex) mined from
`~/coding/agent-transcripts/transcripts.db`, the shared coordination log
`docs/coordination/agents-notes.md`, and a read-only recon of the metta backend at
`e5d8bde81d` (2026-09-02). Per-incident evidence with `session@seq` pointers is in
`s2-permissions-retrospective-2026-09-02-evidence.md`; the permission-model recon with
`path:line` citations is in `../recon/observatory-permission-model-2026-09-02.md`.

## 1. Summary

Nothing we tried was actually blocked by permissions once we sent the right header. Every
league read and write our side attempted succeeded with James's user token plus
`X-Use-Elevated-Privileges: true` (or `coworld --elevated`). The time we lost came from four
things, in order of cost:

1. **Silent failure modes in the platform** that look like permission or infrastructure
   problems: an unfunded reward pool that skips rounds without any visible error (about
   7.5 hours of a dormant league, both teams diagnosing Temporal); a full-replace settings
   endpoint with no audit trail (two "who reverted this?" hunts, one of which produced a false
   "seed reconciler" theory on Maxwell's side); 404s for anything private or disabled.
2. **Our own agents deferring writes they could make.** The PM session staged a working
   league-settings payload at 16:55Z on Sep 1 and still handed the flip to Maxwell's side, who
   executed it five hours later. The starter loop read Maxwell's "announce every settings write
   here before applying" as an approval gate and idled about 6.5 hours. The PM requested a prod
   DB write to retire Elite Paintbot when a team-only seed PATCH was the platform's own path,
   which Maxwell's side then used.
3. **Missing or code-only documentation** for the operator surface: the API base path, the
   elevated header, which league fields an owner may change versus team-only, the seed
   reconciler's re-assert list, the reward pool, the filler endpoint, the ID inventory.
4. **CLI drift**: the published `coworld` (0.1.44, Aug 27) predates backend cursor pagination,
   so `xp-request list` fails on every install; ids get truncated in table output; error bodies
   are swallowed.

The phrase "only softmaxwell has access" does not appear in any of our transcripts. The closest
is our PM's coordination note "your side reports no authority/access for the 0.7.253 steps",
which was a misreading of Maxwell's agent saying it had no *Temporal* reach. Maxwell's agent
corrected this in the log at the time. Both sides then spent the rest of the day assuming the
other held levers that neither had verified.

## 2. The permission model, as it actually is

Verified against `~/coding/metta` at `e5d8bde81d`. File citations are in the recon report.

### 2.1 Principals

There are five subject types on one enum: `USER`, `PLAYER`, `REPORTER_RUN`, `COMMISSIONER`,
`MACHINE`. There is no "team token" and no admin principal. "Softmax team member" is a boolean
on a USER principal, mirrored from the GitHub team, and it only takes effect when the request
carries `X-Use-Elevated-Privileges: true`. Without that header a team member's token is an
ordinary user token. The `coworld` CLI never sends the header unless you pass `--elevated`.

Token prefixes: `usr_` (user), `ply_` (player session), `cmr_` (commissioner, bound to one
league), `mch_` (machine, scope list only), plus `code_`/`rrt_`. A `ply_` session strictly
narrows authority: it cannot manage leagues, cannot upload a coworld, cannot use `--elevated`.
`coworld player use` swaps the CLI onto a `ply_` token for every subsequent command; forgetting
`coworld player unset` is a plausible cause of surprising 403s.

Both CLIs read `~/.softmax/credentials.yaml`. The API base is
`https://softmax.com/api/observatory`; `/api/v2/...` without `/observatory` returns an HTML
404 from Next.js, which is indistinguishable from "league not found" if you are not looking.

### 2.2 What "league owner" means

The `leagues` table has no owner column. Ownership is the game's `owner_user_id` plus rows in
`league_owners`. Seeded leagues are owned by the seed system user; a real person owns a seeded
league only through a `league_owners` row, which is granted at seed materialization when the
seed creator owns the canonical coworld, or via `POST /v2/leagues/{id}/owners`. James's user
was not an owner of `league_b8fa9b35` (Paintbot); the 403 "Only an owner of league ... may
updating league settings" was correct. Team elevation bypasses the owner check.

### 2.3 Owner-reachable versus team-only

This is the concrete answer to "ownership does not equal mutability". It is by design.

| Surface | Owner (or `cmr_` for its league) | Team-only |
|---|---|---|
| `POST /settings`: `variant_rotation`, disabling the ladder, cadence and sibling sections | yes | |
| `POST /settings`: any other ladder field (`team_count`, `num_episodes`, `insufficient_players`, scheduler, Elo, qualification) | 403 "ladder settings are platform-owned" | yes |
| `rounds-paused`, `locks`, `filler-policies`, `seed-policies`, `short-name`, commissioner tokens, `trigger-round`, `owner-status` | yes | |
| `PUT /divisions` (topology) | `cmr_` until the ladder is enabled | yes |
| `commissioner-state` read/write | `cmr_` only while no platform brain is enabled | yes; owners never |
| `visibility`, `reset-rounds`, `coworld-budget`, `ladder_update` on completion | | yes |
| Seed row: `enabled` (disable/retire), `default_variant_id`, overrides | | yes, plus a maintenance window (paused + submissions locked + no active rounds) for `default_variant_id` |

`POST /settings` is a whole-document replace with no PATCH, no `If-Match`, no version field,
no `updated_at` on the row, and no event recording who wrote it. Unknown keys are 422.
`commissioner_state` by contrast has an optimistic version and 409s on conflict.

### 2.4 Status codes

401 only when no credential resolves. 403 for the wrong principal type, a read-only
credential on a write, a missing machine scope, a non-team caller on a team route, a non-owner
on an owner route, or a `cmr_` token on the wrong league. 404, deliberately, for any private or
hidden league the caller cannot see and for every disabled league, per spec 0080 ("return 404
for private data outside the caller's access"). A disabled league is therefore invisible on
every league endpoint, including to its owner; it is readable and re-enablable only through the
seed row (`GET/PATCH /v2/coworld-league-seeds/{lseed_...}`), which is team-only.

### 2.5 The seed reconciler

`reconcile_seed_coworld_leagues` runs every round-runner cycle (about 5 seconds), unconditionally,
not gated by `LADDER_RECONCILERS_ENABLED` (that flag gates four Temporal loops). On an existing
league it re-asserts: `game_id`, `name`, `description`, `commissioner_key`,
`commissioner_config` (preserving the league's `default_variant_id`, and skipped while
game-version-locked), `rules`, `disabled_at = None` (for enabled seeds), `public`, `hidden`,
divisions for container leagues. It never writes `settings`, `filler_policy_version_ids`,
`rounds_paused_at`, `submissions_locked_at`, or `commissioner_state`.

So: a direct DB edit to `disabled_at`, `commissioner_key`, `commissioner_config`, `public` or
`hidden` will revert within seconds. A settings write will not. The Sep 1 "clobber" was two
agents writing the same full-replace document 70 minutes apart with delayed note reads, not the
reconciler. The Aug 31 `campaign.enabled` revert had no identifiable actor because nothing
records one.

### 2.6 IDs

Public ids are prefixed strings generated from the row UUID (`league_`, `div_`, `lseed_`,
`round_`, `ereq_`, `xreq_`, `sub_`, `lpm_`, `cow_`, `ply_` and others). The DB primary key is
the bare UUID (`leagues.id`); the prefixed value is a separate generated column
(`leagues.league_id`). The `/sql` endpoint and every FK need the bare form. Policies and policy
versions have no prefix at all (bare UUIDs everywhere; `pvid` is a local variable name).
Surfaces that take bare UUIDs where you would expect prefixed ids: commissioner credential
`subject_id`, `filler-policies` and `seed-policies` bodies, `POST /league-submissions`,
`GET /v2/episodes/{uuid}/logs`.

### 2.7 List filters

`GET /v2/rounds` takes `league_id` and `division_id`. FastAPI drops unknown query parameters
silently, so `?league=` and `?division=` return the platform-wide list. Same class:
`GET /v2/policy-versions?policy_name=` is ignored (use `/stats/policy-versions?name_exact=`),
and the CLI footer on a league-scoped `coworld rounds` shows the global round count.

### 2.8 Coworld images

Upload is `POST /v2/coworlds/upload`, user credential only. A new version of an existing name
may be uploaded by the original uploader or a team member. In prod the row is created
non-canonical and promoted asynchronously once the certification attempt graduates, the smoke
episodes complete, the version is still dominant, and every live league's variant references
are satisfied. An upload that would strand a league's default variant is refused with 409 at
upload time; that guard skips disabled leagues. `game.description` is immutable per version.
The repo's "Verify upload ... not found on server" step is our own workflow's poll, not a
platform message.

### 2.9 Policies and players

`coworld upload-policy` version labels are a per-policy integer counter; uploading one persona
alone advances only its counter, so local docker tags drift from platform labels. A policy
version is pinned to the player that first submitted it (409 "already assigned" afterwards).
Two independent caps of two: active players per account (`POST /players` 409), and active
memberships per user per league (oldest surplus deactivated). `coworld episode-logs --list`
and `--agent` 403 on commissioner-run league rounds for everyone but the league owner or team,
because the manifest route deliberately excludes the public-league allowance and spec 0080
says participation grants nothing.

### 2.10 Maxwell's agent's five claims, checked

| Claim | Verdict |
|---|---|
| Ownership does not equal mutability; settings is a full-object replace | True, and by design. Owners get rotation, pause, locks, fillers, tokens; the ladder document is team-only. No PATCH, no concurrency control, no audit. |
| Disabled equals invisible; indistinguishable from a permission denial | True. 404 by spec. Re-enable only via the seed row, team-only. The runbook exists (`retire-seeded-league.md`) but nothing in the API points to it. |
| A reconciler fights you; the real switch lives on the seed object, undocumented | Half true. It re-asserts `disabled_at`, `commissioner_key`, `commissioner_config`, `public`, `hidden` every ~5s and never `settings`. A DB-side "fix" to any of those fields reverts; a settings write does not. The seed switch is documented in metta's onboarding docs, not discoverable from the league API. |
| Prefixed ids do not match column types | True. `leagues.id` is a bare UUID; `league_id` is the prefixed generated column. Several API bodies take bare UUIDs. |
| `?league=` / `?division=` filters are silently ignored | True in effect. The parameters are `league_id` / `division_id`; unknown params are dropped. |

## 3. What happened to us

Timeline of the incidents that cost time, with the belief at the time and what was true.
Session pointers are `source:session@seq`; full detail in the evidence file.

| When (UTC) | Incident | Belief | Truth | Cost |
|---|---|---|---|---|
| Aug 31 06:02 | `coworld league list` 403 on seeds | needs elevated | correct; the 403 text said so | 1 min |
| Aug 31 19:31 | Settings POST 403 "Only an owner ... may updating" (`claude-code:2bbc72ec@220`) | James should be owner | James is not in `league_owners`; elevation bypasses | 1 min, after ~6 failed hand-rolled requests to find the base path and header |
| Aug 31 21:25 to Sep 1 01:30 | `campaign.enabled` silently back to true (`2bbc72ec@421-646`) | some reconciler | an unattributable privileged writer; no audit exists | ~7 min hunt, ~4 h of failing campaign rounds |
| Sep 1 09:33 to 17:10 | League dormant after Stage-1 flip (`1f0b5841@12558-12591`, `@13354`) | Temporal or `LADDER_RECONCILERS_ENABLED`; "no Temporal reach from our side" | reward pool at -1193 credits; workflow skips silently; balance was readable via `GET /owner-status` with elevation | ~7.5 h dormant, both teams |
| Sep 1 16:03 to 21:52 | League variant flip deferred to Maxwell's side (`1f0b5841@13089-14761`) | "you hold the Stage-1 mechanics"; then "their side reports no authority" | our agent had a working elevated write at 16:55Z; Maxwell's agent never said it lacked access | ~5 h flip delay |
| Sep 1 17:02 to 18:35 | Round completion 409 on foreign `commissioner_state` | prod DB write needed | DB write done by Maxwell's side; `reset-rounds` with `destroy_campaign_state` was an API path (team-only) that was never considered | ~1.5 h of dead rounds |
| Sep 1 21:04 | Upload 409 "existing Leagues are incompatible" (`1f0b5841@14522`) | correct reading | `default_variant_id` lives on the seed, invisible on the league GET; needs a maintenance window to change | extra union image build (~25 min); slim manifest deferred |
| Sep 1 21:27 | Retire Elite Paintbot "needs Maxwell's owner go, a prod DB write" (`1f0b5841@14661`) | no API path | `PATCH /v2/coworld-league-seeds/{lseed} {enabled:false}` is the platform's path; team-only; James's elevated token qualifies | executed by Maxwell's side at 22:37Z instead |
| Sep 1 22:25 to 23:38 | Settings "clobbered" (`1f0b5841@15111-15241`) | ours: "their protective rollback fired"; theirs: "seed reconciliation" | two unannounced full-replace writes | ~1 h of rounds on the wrong shape; origin of announce-before-write |
| Sep 1 23:30 | "Pool balance isn't visible from our side" (`1f0b5841@15055`) | needs their DB | `GET /v2/leagues/{id}/owner-status` (excluded from public docs) | 3 min, after James pushed |
| Sep 2 09:04 to 15:37 | Starter loop stops: "a league-settings write under the announce-first rule, so I didn't" (`claude-code:5124496e@3095`) | announce = approval | announce = notify; the write took one note and one POST | ~6.5 h idle |
| Sep 2 15:40 to 18:02 | Starters submitted as James's entrants; 409 "already assigned", 409 "limited to 2 active players", stale player-swap skill (`5124496e@3168-4540`) | must compete to be measured | starters are filler-only; measure via experience requests | ~2 h 20 m plus leaderboard pollution |
| Sep 2, all day | `xp-request list` fails on dev626 and dev750; `policy_name` filter ignored; `coworld show` 500; `coworld list` shape; Verify-upload false reds | | CLI/API drift; workflow polling | ~30 min plus one wasted 20-episode batch scored on a pre-fix canonical |

Things that were requested of Maxwell's side and whether that was necessary:

| Request | Necessary? |
|---|---|
| Drive the league settings flip | No. Elevated user write worked on our side. |
| Check the reward pool balance | No. `owner-status` with elevation. |
| Null the foreign `commissioner_state` | Partly. A prod DB write is what was done; `reset-rounds` with `destroy_campaign_state` is a team-only API alternative if a round reset was acceptable. |
| Retire Elite Paintbot | No DB write needed. Seed PATCH is team-only; James qualifies with elevation. |
| Fund the pool | Yes in practice (Maxwell approved the grant); whether James's elevated token could `POST /reward-pool/grants` was never tested. |
| Trigger upload / cert / canonical | Ours by repo ownership (the workflow lives in Metta-AI/coworld-ctf); not a platform permission. |

## 4. Where the pain came from

Grouped by what would have to change to prevent it.

### 4.1 API design

- **Full-replace settings with no concurrency control and no audit.** Two teams, one document,
  no `If-Match`, no `updated_at`, no actor event. Every "who changed this" question was
  unanswerable, and one of them produced a false root cause that went into the shared log.
- **Silent skips instead of errors.** An unfunded reward pool skips round planning with a
  message only visible in Temporal history. Rounds whose episodes all failed still mark
  COMPLETED, so the breaker never trips.
- **Unknown query parameters dropped.** `?league=` returns the platform-wide list;
  `?policy_name=` returns the 30 newest versions platform-wide. Both produced wrong
  conclusions that happened to look right while Paintbot was the only active league.
- **The guard keys on a field you cannot see.** The canonicalization 409 names a league's
  `default_variant_id`, which is not on `LeaguePublic`; it lives on the seed row and needs a
  maintenance window to change.
- **403 messages do not say what would pass.** "Only an owner of league X may updating league
  settings" (sic) does not mention team elevation; the CLI adds an `--elevated` hint only on
  some paths. The ladder-half 403 ("platform-owned; only team principals") is undocumented.
- **404 for disabled and private leagues with no distinguishing detail**, even for a caller who
  would be allowed to see it with elevation.
- **No owner-reachable retire/disable.** The league API has no disable route; the seed PATCH is
  team-only and the seed id is a different object from the league id.
- **Owner-visible balance endpoint is excluded from public docs** (`owner-status`).

### 4.2 Documentation

Metta documents ownership, seed retirement, ladder setup, commissioner tokens and player
swapping reasonably well (`PLATFORM_LADDER_LEAGUE.md`, `retire-seeded-league.md`,
`platform-commissioner-api.md`, COOKBOOK). Nothing documents: the 401/403/404 matrix and the
"404 hides existence" rule; which settings fields an owner may change; the reconciler's
re-assert list; the reward pool gate and where to read the balance; the filler endpoint and
who may write it; the prefixed-versus-bare id inventory; that `GET /v2/rounds` takes
`league_id`; the foreign `commissioner_state` 409 and how to clear it (the code refers to a
"ladder runbook" that does not exist); per-policy version counters; the per-account player cap;
why `episode-logs --list` 403s. `certification.md` still says certification never blocks
canonical promotion, which contradicts the code and spec 0062. The API base path and the
elevated header are documented only in the coworld package docs and the CLI source.

On our side, `AGENTS.md` documents the `/sql` path but not the league-ops recipe, and the
`coworld-player-swap` skill references `softmax.auth.save_player_session`, which does not exist
in the installed CLI.

### 4.3 Access control

- Owners cannot edit the scheduler (`team_count`, `num_episodes`, `insufficient_players`). That
  is a deliberate split, but it means "league owner" is not the role a game operator needs; the
  operator needs team elevation for most of the cut-over, and nothing tells them so up front.
- Team membership requires an explicit opt-in header on every call. Reasonable as a safety
  measure; costly when undocumented.
- `episode-logs` for your own policy in a commissioner-run public league is denied by spec.
  Competitors cannot read their own agent logs from league rounds at all.
- Seed enable/disable and `default_variant_id` are team-only, so a league owner cannot retire
  their own league or move its default variant.

### 4.4 Backend infrastructure

- No `updated_at` on `leagues`; no analytics event on settings writes; backend pod logs rotate
  within hours (a rolling deploy removed the window we needed).
- The ladder completion path had no foreign-state guard (`ladders/persistence.py`), so a
  leftover campaign board 409'd every completion. Fix in flight as metta PR #20953.
- Breaker blind spot: COMPLETED rounds with all episodes failed.
- `GET /v2/coworlds` returned 500 on `coworld show`.
- The experience-requests route moved to cursor pagination on Aug 27 and Sep 2 without a CLI
  release.

### 4.5 CLI

- No published `coworld` release since 0.1.44 (Aug 27); `xp-request list` fails on every
  install; `rounds` and `reporters` in that tag also send `offset`.
- No `--version`; no settings read/write, filler, pause, or owner-status commands
  (`coworld leagues` is read-only); ids truncated in table mode produce 422s when pasted; 409
  and 422 bodies are swallowed (a bare httpx traceback instead of "Users are limited to 2
  active players"); `coworld list --json` and `rounds --json` return `{entries: [...]}` where
  scripts expected lists.

### 4.6 Cross-team coordination

- Access claims were relayed through humans and paraphrased ("no authority, the access, or
  something") instead of quoted. Both sides ended up believing the other held levers.
- Both sides wrote the same full-replace document without telling the other. The
  announce-before-write rule fixed that but was then over-read by our starter loop as an
  approval gate.
- The coordination file's "trigger is theirs" agreement was treated as an access fact for the
  rest of the day.
- Nobody established at kickoff: who owns the league, who has team elevation, which side holds
  which lever, and which repo's workflow does the upload.

### 4.7 Our own agents

- Deferred writes it had already proven it could make (flip, pool check, Elite retirement).
- Read a notify rule as an approval gate and idled.
- Submitted starters as James's competitive entrants against the instruction to update fillers.
- Guessed a ghost ("their protective rollback fired") instead of asking.
- One Codex lane captured another process's Asana MCP `client_secret` into its transcript via
  `pgrep -fl` (`codex:01a0554d@17968`). Low-value dynamic-registration secret, but it is now in
  the rollout JSONL and the transcript DB.

## 5. Proposed issues

Candidates for Asana, for James to review. Severity reflects the time it cost us or would cost
the next team. "Owner" is the repo where the fix lives.

### Platform API (metta app_backend)

| # | Title | Sev | Owner | Evidence |
|---|---|---|---|---|
| P1 | League settings: add concurrency control (`If-Match` or a `version` field, 409 on stale) and a merge or PATCH path so one field can change without re-posting the document | high | metta | 3.x clobber, A13, B4/B6 |
| P2 | Record actor and diff for every league mutation (settings, filler list, pause, locks, seed PATCH) as a `competition_events` row; add `updated_at` to `leagues` | high | metta | B5, A13, Maxwell's TLDR |
| P3 | Reward pool: when the ladder workflow skips for an unfunded pool, surface it (league GET `blocked_reason`, an event, a log line at WARN) instead of a Temporal-only payload; document the gate | high | metta | A4, 7.5 h dormancy |
| P4 | Breaker: a round whose episodes all failed must count as a failure for the consecutive-failure breaker | high | metta | A16, Maxwell 23:50Z note |
| P5 | Reject unknown query parameters on list endpoints, or at least alias `league`/`division` to `league_id`/`division_id`; make `policy_name` on `/v2/policy-versions` either work or 422 | medium | metta | E2, E11, Maxwell's "filters lie" |
| P6 | 403 messages name the principal that would pass ("league owner, or a Softmax team member with `X-Use-Elevated-Privileges: true`"); fix "may updating"; document the ladder-half 403 | medium | metta | B3, A5 |
| P7 | Expose `default_variant_id` on the league object and have the canonicalization 409 say where it lives and how to change it (seed PATCH plus maintenance window) | medium | metta | A9, 14622/14828 |
| P8 | Disabled leagues: for a caller who would be allowed with elevation, return a distinguishable response (410 or a 404 detail naming the `lseed_` and the re-enable path) | medium | metta | Maxwell's "disabled = invisible" |
| P9 | League disable/retire route on the league API reachable by owners, or at minimum a link from the league object to its seed id | medium | metta | A10, 14661 |
| P10 | Publish `GET /v2/leagues/{id}/owner-status` in the API docs; consider showing pool credits on the league GET for owners | low | metta | A14 |
| P11 | Foreign `commissioner_state`: ship PR #20953; document the archive-and-clear procedure the code calls "the ladder runbook" (it does not exist); document `reset-rounds` with `destroy_campaign_state` as the API path | medium | metta | A8 |
| P12 | `GET /v2/coworlds` 500 on `coworld show` | medium | metta | E15 |
| P13 | Let a policy owner read their own policy's agent log from a commissioner-run public-league round (design decision against spec 0080) | low | metta | E3 |
| P14 | Per-account 2-player cap: document it; return the reason in the CLI | low | metta / coworld | E9 |
| P15 | Manifest `config_schema` defaults: document whether the platform materializes them into the effective game config | low | metta | D-1 |

### Documentation (metta)

| # | Title | Sev | Owner | Evidence |
|---|---|---|---|---|
| D1 | League operator guide: base URL, elevated header, owner-vs-team table per endpoint, 401/403/404 matrix, seed reconciler re-assert list, settings full-replace with snapshot-first recipe, filler endpoint, pause/lock/maintenance window, reward pool, id inventory (prefixed vs bare, `/sql` needs bare) | high | metta | recon Q18 |
| D2 | Fix `certification.md` claim that certification never blocks canonical promotion | low | metta | recon Q10 |
| D3 | `docs/auth.md`: list `cmr_`/`mch_`/`rrt_` prefixes and the elevation header semantics | low | metta | recon Q1 |

### CLI (metta packages/coworld, softmax-cli)

| # | Title | Sev | Owner | Evidence |
|---|---|---|---|---|
| C1 | Publish a `coworld` release with cursor pagination (`xp-request list`, `rounds`, `reporters`); add a CI contract test between CLI request/response models and the backend | high | metta | E12, recon Q16 |
| C2 | Render API error bodies (409/422 detail) instead of bare httpx tracebacks; add `coworld --version` | medium | metta | E1, E9 |
| C3 | Do not truncate ids in table output (or print full ids in a copyable column) | medium | metta | A15, E1 |
| C4 | League ops commands: `coworld league settings get`, `settings set --patch key=value` (GET, modify, POST, read back), `fillers set`, `pause`/`unpause`, `owner-status`, `retire` (seed PATCH) | medium | metta | A5, B2 |
| C5 | `--elevated` hint on every owner-gated 403, not only some | low | metta | B3 |

### Our repo (coworld-ctf) and process

| # | Title | Sev | Owner | Evidence |
|---|---|---|---|---|
| R1 | League-ops runbook in `AGENTS.md`/docs: the recipe that worked (elevated GET, snapshot, POST, read-back; filler write; owner-status; seed PATCH for retire; ids), plus "announce means notify, not approval" | high | coworld-ctf | E6, E7 |
| R2 | Upload workflow: path-filter docs-only pushes so they do not supersede an engine upload; make the verify step distinguish "superseded" from "failed"; single source for the `coworld[auth]==0.1.43` pin (four places) | medium | coworld-ctf | A3, E13, E14 |
| R3 | Fix the `coworld-player-swap` skill (references `save_player_session`, which does not exist) | low | skills | E9 |
| R4 | Rotate or scrub the Asana MCP `client_secret` captured in `codex:01a0554d@17968`; add a `pgrep -fl` hygiene note for lanes | medium | local | D hygiene |
| R5 | Cross-team kickoff checklist: who owns the league, who has team elevation, which side holds the deploy trigger, exact error text required when relaying access claims | medium | process | A7, 13248 |
| R6 | Agent guidance: a write the agent has already proven it can make is not a decision for the other team; verify "needs X" claims against the API before relaying them | medium | process / memory | A7, A10, A14, E4, E6 |

## 6. What was not found

- No transcript contains "only softmaxwell has access" or an equivalent. If Maxwell's agent is
  quoting something, it is likely our 16:52Z coordination note paraphrasing James's relay.
- No transcript shows a bare `?league=` on the rounds listing from our side; our agents used
  `league_id=`.
- Group A sessions (Aug 29-30) and all Codex lanes contain no platform calls; the permission
  activity is concentrated in four Claude Code sessions.
- Whether James's elevated token can `POST /reward-pool/grants` was never tested.
