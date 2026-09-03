# Recon: Softmax / Observatory permission model for leagues, coworlds, policies

Target checkout: `/Users/jamesboggs/coding/metta` at `e5d8bde81d` (origin/main, clean tree, pulled 2026-09-02). Read-only; no writes or git mutations were performed. All paths below are absolute. `M` abbreviates `/Users/jamesboggs/coding/metta`, `B` abbreviates `M/app_backend/src/metta/app_backend`.

## Mission

Map who may do what to leagues, coworld images, and policies on the Observatory backend, and how the `coworld`/`softmax` CLIs and raw curl authenticate, so that the coworld-ctf team can (a) stop guessing why calls 403/404/409 and (b) know which knobs are owner-reachable versus team-only. Eighteen checklist questions; every claim cites `path:line`. Consumer: James and the coworld-ctf coordination agents.

## Directory map

```
M/app_backend/src/metta/app_backend/
  auth.py                  principal resolution: token -> AuthContext; AuthPolicy; require_auth/maybe_auth/no_auth
  authorization.py         row scopes (Anonymous/Owner/Player/_Elevated) + dependency wrappers
  credential_tokens.py     usr_/ply_/cmr_/mch_ token generation + hashing
  config.py                Settings incl. LADDER_RECONCILERS_ENABLED, DEBUG_AUTH_ENABLED
  server.py                app factory; starts ladder reconcilers when enabled
  models/credentials.py    credentials table, CredentialScope, token prefixes, commissioner:league:<id> scope
  models/players.py        players table, PlayerId (ply_)
  models/user_settings.py  user_settings (admin flag, max_players_per_league)
  models/ids.py, ID_GUIDE.md   PrefixedId column machinery + the normative doc
  routes/coworld_routes.py     /v2/coworlds (upload, certification, patch-commissioner, play/replay)
  routes/player_routes.py      /players (2-player cap, login/session tokens)
  routes/stats_routes.py       /stats/policies (policy upload completion, version listing)
  queries/policy_queries.py    version counter; queries/player_queries.py default player
  v2/permissions.py        league/XP read scopes, league_owned_by_user, platform-commissioner machine
  v2/routes/_shared.py     the auth-dependency catalogue + assert_league_owner_or_team & friends
  v2/routes/leagues.py     /v2/leagues* (settings, rounds-paused, locks, filler-policies, owners, submissions)
  v2/routes/commissioner.py    commissioner tokens, division topology, commissioner-state
  v2/routes/coworld_league_seeds.py   /v2/coworld-league-seeds (lseed_)
  v2/routes/rounds.py, league_logs.py, episode_requests.py, experience_requests.py
  v2/seed.py               seed reconciler (runs every round-runner cycle)
  v2/league_settings_schema.py, league_settings.py, league_fillers.py
  v2/ladders/{config,persistence,updater}.py, v2/campaign/state.py, v2/landscape/state.py
  v2/coworlds.py           canonical lookup, variant binding, coworld_manifest_league_errors
  coworld/smoke_test.py, coworld/auto_certification.py, job_runner/coworld_recording.py  promotion pipeline
M/packages/metta-app-backend-client/src/metta/app_backend/wire/prefixed_id.py   PrefixedId base class
M/packages/coworld/src/coworld/{cli,tournament_cli,api_client,upload}.py   `coworld` CLI (Typer)
M/packages/softmax-cli/src/softmax/{auth,players,cli}.py                  `softmax` CLI (Typer)
M/docs/{auth.md,specs/*,ai/onboarding/services/{coworlds,observatory}/*}   docs
M/packages/coworld/{COOKBOOK.md,AGENTS.md,src/coworld/docs/PLATFORM_LADDER_LEAGUE.md}
```

---

## Findings

### Q1. Principal types and request classification

Five subject types, one enum: `B/auth.py:68-82` — `USER`, `PLAYER`, `REPORTER_RUN`, `COMMISSIONER`, `MACHINE`. There is **no separate "team token" type and no admin/superuser principal**: "Softmax team" is a boolean on a USER principal (`AuthContext.is_softmax_team_member`, `B/auth.py:145`) resolved from the GitHub team-member mirror table (`B/auth.py:250-255`), and only when the request carries `X-Use-Elevated-Privileges: true` (`B/auth.py:390-402`, `_apply_elevation_gate`). `is_softmax_admin` is populated only for `/whoami` (`B/auth.py:122-124`, `:637-646`) and per `M/docs/auth.md:126-127` "has no effective authorization meaning". Service accounts are `MACHINE` credentials owned by the sentinel user `machine-sentinel` (`B/models/credentials.py:15`, `:31-33`) and never inherit team membership (`B/auth.py:355-358`); their only authority is the scope list (`B/auth.py:420-433`).

Credential prefixes (`B/models/credentials.py:73-79`): `usr_`, `ply_`, `code_`, `rrt_`, `cmr_`, `mch_`. Machine scopes (`:36-55`): `write`, `stats:write`, `jobs:lifecycle`, `jobs:batch`, `coworld:certify`, `commissioner:platform`. A commissioner credential carries exactly one `commissioner:league:<league_public_id>` scope (`:45`, `:62-70`) and its `subject_id` is the league's **bare internal UUID** (`:27-29`; minted at `B/v2/routes/commissioner.py:129-134`).

Classification path: `_token_from_request` (`B/auth.py:221-238`, order: Bearer, legacy `X-Auth-Token`, NextAuth cookie) → `validate_token` (`:654-681`; debug backdoors `debug-machine:`/`debug:` only when `DEBUG_AUTH_ENABLED`, `B/config.py:47-50`) → `_local_credential_principal` (`:297-364`, hashes the token, loads `credentials`, branches on `subject_type`) → `_resolve_principal_for_policy` (`:459-519`): unnamed subject → 403 (`:194-201`), missing credential → 401 (`:211-215`), read-only user credential on a write → 403 (`:405-417`), machine without a required scope → 403 (`:429-433`), team gate → 403 "User is not a softmax team member" (`:495-500`).

Route-level dependencies are `require_auth`/`maybe_auth`/`no_auth` (`B/auth.py:557-608`). The named constants routes actually use live in `B/v2/routes/_shared.py:36-194`: `TEAM_AUTH` (:36), `USER_AUTH` (:53), `SUBMITTER_AUTH` = user|player (:37-38, `SUBMITTER_SUBJECTS` at `B/auth.py:87`), `COMMISSIONER_API_AUTH` = user|commissioner|machine{commissioner:platform} (:57-62), `PLATFORM_WORKER_AUTH` (:67-73), `LEAGUE_TOKEN_MANAGEMENT_AUTH` (:151), `COWORLD_CERTIFY_*` (:155-194). Team-only routes are `require_auth(..., require_softmax_team_member=True)` — there is no function literally named `require_team`.

Row-level scopes: `B/authorization.py:22-48` (`AnonymousScope`, `OwnerScope`, `PlayerScope`, `_ElevatedScope`); `resource_scope` refuses machine/commissioner principals (`:70-85`) — those get resource-specific checks in-handler. League read scopes: `B/v2/permissions.py:104-112` (`league_read_scope`: commissioner → its one league; platform machine → all leagues; other non-user/player subjects → anonymous).

### Q2. How `coworld`, `softmax`, and raw curl authenticate

Both CLIs use one token store: `~/.softmax/credentials.yaml` (`M/packages/softmax-cli/src/softmax/auth.py:16`, `:64-70`, chmod 0600 `:83-87`), shape `tokens:{server: usr_…}` plus `player_sessions:{server:{active, cache}}` (`:47-61`). Login: `softmax login` opens `<server>/cli-auth` (`:225-237`), the browser mints a `code_` auth code, the CLI exchanges it at `POST /observatory/credentials/auth-codes/exchange` (`:254-269`, exchange hosts restricted to softmax.com/*.softmax.com/*.softmax-research.net/loopback `:23-24`). Headless: `softmax set-token` (`M/packages/softmax-cli/src/softmax/cli.py:240-254`; used by the ctf workflow `/Users/jamesboggs/coding/coworlds/coworld-ctf/.github/workflows/upload-coworld-paintbot.yml:68`). The only env override is `COGAMES_API_URL` for the server URL (`auth.py:27-28`); no token env var exists in the CLI path.

`coworld` delegates entirely to `softmax.auth`: `CoworldApiClient.from_login` calls `load_current_token` (`M/packages/coworld/src/coworld/api_client.py:704-708`), which returns the **active player session token if one is set, else the user token** (`softmax/auth.py:183-185`). Header is `Authorization: Bearer <token>`; `--elevated` adds `X-Use-Elevated-Privileges: true` and is refused on `ply_` tokens (`api_client.py:719-731`). `coworld player use ply_…` mints a 24h player session via `POST /players/{id}/login` (`softmax/players.py:129-152`; backend `B/routes/player_routes.py:381-407`, TTL `settings.PLAYER_LOGIN_TTL_SECONDS` = 86400 at `B/config.py:73`).

Raw curl: send `Authorization: Bearer <usr_|ply_|cmr_|mch_…>`; add `X-Use-Elevated-Privileges: true` for team routes (`B/auth.py:390-402`; documented at `M/docs/ai/onboarding/services/coworlds/certification.md:29-34` and `M/packages/coworld/src/coworld/docs/PLATFORM_LADDER_LEAGUE.md:384-392`). `X-Auth-Token` still works but is a deprecated fallback (`B/auth.py:227-231`; policy at `M/app_backend/AGENTS.md:19-27`). Machine tokens are minted by team members at `POST /admin/machine-credentials` (`B/routes/admin_routes.py:302-336` per the auth subagent; not read in full — UNVERIFIED line range) and injected into Temporal/certifier/supervisor pods as `MACHINE_TOKEN` (`B/v2/orchestration/activities.py:130`, `B/job_runner/config.py:49`).

### Q3. "League owner" in the data model, and which endpoints check it

There is **no `owner_id`/`team_id`/`commissioner_id` column on `leagues`** (`B/v2/models.py:1072-1258`). Ownership = the game's legacy owner (`Game.owner_user_id`, `B/v2/models.py:484`) **plus** every row in `league_owners` (`LeagueOwner`, `B/v2/models.py:1329-1360`; docstring: seeded games are owned by the seed system user, so this table "is the only way a real user owns a seeded league"). The single predicate is `league_owned_by_user` (`B/v2/permissions.py:115-140`, correlated EXISTS over both sources). Write authority is `assert_league_owner_or_team` (`B/v2/routes/_shared.py:444-462`): rejects any non-USER subject with 403 (player and commissioner tokens carry the owner's `user.id` and must not escalate, `:446-453`), passes team members, else checks ownership → 403 "Only an owner of league … may …" (`:459-462`). Owners are granted at seed materialization when the creator owns the canonical coworld or game (`B/v2/seed.py:559-580`) and via `POST/DELETE /v2/leagues/{id}/owners` (`B/v2/routes/leagues.py:1939-1990`, owner-or-team, USER_AUTH).

Per-endpoint gates (all in `B/v2/routes/leagues.py` unless noted):

| Endpoint | Auth dependency | In-handler gate | Cite |
| --- | --- | --- | --- |
| `GET /leagues/{id}/settings` | `COMMISSIONER_OR_SUBMITTER_AUTH` | public league: any submitter; private: commissioner/platform/team, else owner | `:2395-2419` |
| `POST /leagues/{id}/settings` | `COMMISSIONER_API_AUTH` | `assert_commissioner_api_league_or_owner` (`_shared.py:472-483`); then **ladder document is team/platform-only**: a non-team writer may only (a) omit `ladder` (stored one carried forward, `:2460-2481`), (b) disable it, or (c) change `scheduler.variant_rotation`/`variant_rotation_by_seat_count` ("map_pool_only"); anything else → 403 "ladder settings are platform-owned" | `:2421-2500` |
| `GET/POST /leagues/{id}/rounds-paused` | `COMMISSIONER_API_AUTH` | `assert_commissioner_api_league_or_owner` → owner, team, cmr_ (bound to league), platform machine | `:2151-2205` |
| `GET/POST /leagues/{id}/locks` (submissions lock + game-version lock) | `COMMISSIONER_API_AUTH` | same owner-or-commissioner gate | `:2252-2300` |
| `GET/POST /leagues/{id}/filler-policies` | `COMMISSIONER_API_AUTH` | same gate ("baselines are owner-manageable, like its settings", `:3248-3249`) | `:3203-3286` |
| `GET/POST /leagues/{id}/seed-policies` | `COMMISSIONER_API_AUTH` | same gate | `:3322-3408` |
| `default_variant_id` | not on `/leagues` at all — lives in `commissioner_config` and is set through the **seed** PATCH; team-only (`_assert_owner_patch_scope`: "Only Softmax team members may change the default variant") and blocked by a maintenance window (409) unless rounds paused + submissions locked + no active rounds | `B/v2/routes/coworld_league_seeds.py:179-183`, `:519-546`, `:905-919` |
| `POST /leagues/{id}/visibility` (public/hidden) | `TEAM_AUTH` | — | `:1710-1724` |
| `POST /leagues/{id}/short-name` | `SUBMITTER_AUTH` | `assert_league_owner_or_team` | `:1737-1785` |
| `PUT /leagues/{id}/coworld-budget` | (team; not read in full) | — | `:2105` |
| `POST /leagues/{id}/reset-rounds` | `TEAM_AUTH` | 409 for campaign state unless `destroy_campaign_state` | `:2859-2906` |
| `POST /leagues/{id}/trigger-round` | (read partially) `assert_league_owner_or_team` | 409 if paused | `:2951-3037` |
| `PUT /leagues/{id}/divisions` | `COMMISSIONER_API_AUTH` | cmr_ token → 403 once platform ladder enabled | `B/v2/routes/commissioner.py:220-266` |
| `GET/PUT /leagues/{id}/commissioner-state` | `COMMISSIONER_API_AUTH` | `assert_commissioner_api_league_id` = cmr_ (own league) / platform machine / **team member**; league owners are NOT admitted | `commissioner.py:269-372`, `_shared.py:369-379` |
| `POST/GET/DELETE /leagues/{id}/commissioner-tokens` | `LEAGUE_TOKEN_MANAGEMENT_AUTH` (USER only) | owner or team | `commissioner.py:108-218`, `_shared.py:465-469` |

Endpoints requiring a team or platform-machine credential regardless of ownership: visibility (`:1710`), reset-rounds (`:2859`), commissioner-state write on a platform-ladder/campaign/landscape league (`commissioner.py:337-349`; owners are not in `assert_commissioner_api_league_id` at all), the ladder half of settings (`:2482-2500`), division topology once the ladder is enabled for cmr_ tokens (`commissioner.py:249-258`), seed enable/disable and default_variant (`coworld_league_seeds.py:170-183`), and `ladder_update` on round completion (platform machine only, `B/v2/routes/rounds.py:974-978`).

Settings is a **full-object replace**: `stored = request.model_dump(mode="json", exclude_none=True); league.settings = stored or None` (`:2671-2672`). Unknown keys are 422 (`:2432-2439`). The schema is `LeagueSettings` (`B/v2/league_settings_schema.py:158-209`: `ladder`, `campaign`, `landscape`, `counterfactual_eval`, `episodes_per_round`, `round_interval_minutes`, `episode_player_pod_llm_spend_limit_usd`, `llm`, `leaderboard`, `logs`, `achievements`, `rewards`, `tournament_sim_visibility`; only one round brain may be enabled `:200-208`). `league_settings_from_row` tolerates unknown stored keys (`:212-220`). There is no PUT or PATCH on `/settings`; the only PUTs on the league surface are `/coworld-budget` (`:2105`) and `/reward-pool/drip` (`:2821`). The public doc says the same: "Settings POST replaces the whole document" (`M/packages/coworld/src/coworld/docs/PLATFORM_LADDER_LEAGUE.md:360-361`).

Filler-list shape: `League.filler_policy_version_ids` JSONB of bare policy-version UUIDs or `{policy_version_id, display_name}` objects (`B/v2/league_fillers.py:1-14`, `:27-67`); the seating mode that consumes it is `settings.ladder.scheduler.insufficient_players: "filler_policy" | "multiple_seats" | "do_not_run"` default `do_not_run` (`B/v2/ladders/config.py:136`).

### Q4. What an unauthorized caller gets: 401 / 403 / 404

- **401** only when no credential resolves at all: `_raise_failed_to_authenticate` (`B/auth.py:211-215`, called from `:462-464`). The CLI translates it to "Run: uv run softmax login" (`M/packages/coworld/src/coworld/api_client.py:1252-1255`).
- **403** for: a credential type the route did not name (`B/auth.py:194-201`), read-only user credentials on writes (`:413-417`), machine scope missing (`:429-433`), non-team on team routes (`:495-500`), non-owner on owner routes (`_shared.py:453`, `:459-462`), commissioner token for the wrong league (`_shared.py:322-326`, `:362-366`), query-list reads by a commissioner token without `league_id=` (`_shared.py:362-365`, `rounds.py:212-216`).
- **404 that hides existence**: yes, by design. Spec 0080 requirement 5: "Return `404` for private data outside the caller's access" (`M/docs/specs/0080-observatory-resource-visibility.md:96`). Concretely: any private/hidden league the caller cannot see → `_assert_league_visible` → 404 "League … not found" (`B/v2/routes/leagues.py:278-288`); disabled leagues → 404 (`_shared.py:245-247`); a round in an invisible league → 404 (`rounds.py:260-261`); `_shared.py:199-210` `load_*_or_404` helpers. The commissioner routes deliberately bind the token to the path id *before* any DB read ("existence-oracle contract", `leagues.py:2157-2158`), so a cmr_ token for league A probing league B gets 403, not a 404 that would reveal whether B exists.

### Q5. Disabled leagues (`disabled_at`)

`League.disabled_at` (`B/v2/models.py:1168-1172`). Effects: `assert_league_enabled` raises 404 (`_shared.py:245-247`) and is called by every league detail/write handler (`leagues.py:279`, `:291`, `:297`; `commissioner.py:240`, `:277`, `:299`); list/query reads filter `disabled_at IS NULL` (`rounds.py:409`, `permissions.py:169`, `league_logs.py:120-121` "Episode league is disabled" 404, `coworld_routes.py:226`). `disabled_at` is written by exactly three functions, all in the seed reconciler: `_disable_seeded_leagues` (`B/v2/seed.py:719-748`), `_disable_uncommissioned_coworld_daily_league` (`:766-783`), and the clear in `_ensure_leagues` (`:653-658`). Disabling also revokes every outstanding commissioner token for the league (`:751-763`).

There is **no API that reads or re-enables a disabled league directly**. The only re-enable path is the seed row: `PATCH /v2/coworld-league-seeds/{lseed_…} {"enabled": true}` (`coworld_league_seeds.py:889-981`; team-only per `:170-178`) or `DELETE` to disable (`:984-997`, TEAM_AUTH), each followed by an immediate `reconcile_seed_coworld_leagues` (`:967`, `:995`). The seed row itself remains readable for team members via `GET /v2/coworld-league-seeds` and `/by-league/{league_id}` (`:360-377`, `:861-875`). Runbook: `M/docs/ai/onboarding/services/observatory/retire-seeded-league.md:7-21`, `:88-89` ("To bring the league back, re-enable the seed row … the reconciler clears `disabled_at`").

### Q6. Seed / reconciler (`coworld-league-seed`, `lseed_`)

`CoworldLeagueSeed` table `coworld_league_seeds` (`B/v2/models.py:955-1023`), public id prefix `lseed_` (`:265-266`): columns `coworld_name`, `league_key`, `league_name`, `league_id` (FK → `leagues.league_id`), `template`, `overrides` JSONB, `enabled`, `created_by`, `notes`. Overrides are `CoworldSeedOverrides` (`B/v2/seed.py:128-206`: `commissioner_key` container|platform, `commissioner_runnable_id`, `commissioner_config_extensions`, overlay secrets, `entrants_from_league_id`, `is_game_of_week`, `minimum_champions`, `schedule_interval_minutes`).

Cadence: `reconcile_seed_coworld_leagues` is called unconditionally from the round runner every cycle (`B/v2/pipeline.py:2453`; docstring "runs every round-runner cycle (~5s)" `B/v2/seed.py:801-803`) and after every seed route write (`coworld_league_seeds.py:482`, `:857`, `:967`, `:995`).

What it **re-asserts** on an existing league (`_ensure_leagues`, `B/v2/seed.py:611-670`): `game_id` (:618), `name` (:620), `description` (:622), `commissioner_key` (:624-639, with a WARNING log — "the one place a LIVE league changes hands"), `commissioner_config` rebuilt from the template **but preserving the league's existing `default_variant_id`** and skipped while `locked_coworld_id` is set (:640-650), `rules` (:651), **`disabled_at = None`** (:653-658), `public` (:659-660), `hidden` (:661-662), `is_game_of_week` (only to initialize, :663-665), divisions for container leagues (:666-670, `_ensure_league_divisions` :509-556 un-hides/un-archives). It also links the seed's `league_id` and grants the creator ownership (:709-714).

Does it write `settings`? **No.** The exact text at `B/v2/seed.py:697-700`:

> "A platform seed is deliberately only the first of three steps: topology and the ladder document are operator-owned -- reconcile must never write `settings`, which the settings API replaces wholesale."

Verified: `settings` is never assigned anywhere in `seed.py` (the only `League(...)` construction at `:672-683` omits it; the update branch `:611-670` never touches it). `settings` is documented as stored "outside commissioner_config so it survives seed reconciliation" (`B/v2/models.py:1116-1119`, `B/v2/league_settings.py:3-5`). Rotation lives inside `settings.ladder.scheduler.variant_rotation` (`B/v2/ladders/config.py:166`, `:217`) and is therefore untouched. `filler_policy_version_ids`, `rounds_paused_at`, `submissions_locked_at`, `locked_coworld_id`, `commissioner_state` are likewise not written by reconcile (`B/v2/models.py:1101-1106`, `:1126-1131`; spec `M/docs/specs/0065-league-commissioner-state-column.md:209-213`).

`LADDER_RECONCILERS_ENABLED` (`B/config.py:57-64`, default False) gates only the four Temporal-facing loops started in `create_app` — schedule, policy-qualification, counterfactual-eval, tournament reconcilers (`B/server.py:305-325`); set from the Helm chart `M/devops/charts/observatory-backend/templates/deployment.yaml:127-128`. It does **not** gate the seed reconciler.

### Q7. ID formats

One mechanism: `PrefixedId(str)` (`M/packages/metta-app-backend-client/src/metta/app_backend/wire/prefixed_id.py:8-47`; `validate` at `:22-27` is the only place a prefix is stripped, `generated_expr` `:30-31` builds the Postgres generated column), bound to tables by `generated_prefixed_id_field` (`B/models/ids.py:37-46`). Normative doc: `B/models/ID_GUIDE.md` (rule `:45` and `:83`: FKs point at the UUID `id`, never the public column; `:85`: never expose internal UUIDs once a public id exists).

Prefixes declared (`B/v2/models.py` line → prefix): `:132 game_`, `:138 frm_`, `:144 wik_`, `:150 wpg_`, `:156 wrv_`, `:162 mod_`, `:168 cow_`, `:174 ps_`, `:180 league_`, `:186 div_` (**not** `division_`), `:192 pmev_`, `:198 sub_`, `:204 lpm_`, `:210 round_`, `:216 ereq_`, `:222 xreq_`, `:228 lby_`, `:234 cfeval_`, `:240 rrun_`, `:246 rres_`, `:252 event_`, `:266 lseed_`, `:272 creq_`, `:3530 post_`; `B/models/players.py:11 ply_`; reporters `rptr_/rv_/rout_/rsub_` (`B/models/reporters.py:62,68,165,225`). Credential token prefixes are a separate namespace (`B/models/credentials.py:73-79`); `ply_` is used for both a PlayerId and a player token.

**There is no `pvid`/`policy_` prefix.** Policies and policy versions are bare UUIDs everywhere (`B/models/policies.py:98`, `:149` per the ids subagent; `PolicyVersionRow.id` is `uuid.UUID`, `B/routes/stats_routes.py:527`). `pvid` only appears as a local variable (`B/v2/seed.py:878-920`).

Bare-UUID / prefixed mismatches that exist today:

1. Commissioner credentials store the league's bare UUID in `subject_id` (`commissioner.py:130`) while the scope in the same row holds the prefixed id (`:134`); revocation and listing key off the bare form (`commissioner.py:174-178`, `seed.py:757-762`), the auth binding off the prefixed one (`_shared.py:322`).
2. `DELETE /leagues/{league_id}/commissioner-tokens/{credential_id}` takes a bare credential UUID (`commissioner.py:188-197`).
3. `filler-policies` / `seed-policies` bodies take bare policy-version UUIDs (`leagues.py:3155-3169`), as does `campaign.baseline_policy_version_id` (`:2598-2607`) and `POST /league-submissions` `policy_version_id` (`:3532-3535`).
4. `GET /v2/episodes/{episode_id}/logs` takes a bare episode UUID (`league_logs.py:184-186`) while the CLI-facing episode routes take `ereq_` (`episode_requests.py:1301-1312`).
5. `LadderDivisionConfig.division_id` is an unconstrained `str` inside `settings.ladder` but is matched against the prefixed `div_` column (`B/v2/ladders/config.py:563` per the ids subagent; `B/v2/league_settings.py:24-45` validates it against live division ids at save time, so a bare UUID there is a 400 "missing, archived, or not in this league").
6. `entrants_from_league_id` requires the `league_` form by regex (`B/v2/seed.py:174-176`).
7. `CoworldLeagueSeed.league_id` FK points at the public column `leagues.league_id`, contrary to ID_GUIDE (`B/v2/models.py:961-967`).

### Q8. Rounds listing filters

`GET /v2/rounds` (`B/v2/routes/rounds.py:376-448`) accepts `league_id`, `division_id`, `division_type`, `status[]`, `limit`, `cursor` (`:389-398`). **`?league=` and `?division=` are not parameters** — FastAPI silently ignores unknown query strings, so they are dropped rather than honored. Filters are applied at `:415-420`. The commissioner-token binding reads the same `league_id` query (`:225-229`, `:208-223`: a cmr_ token must pass `league_id=` equal to its scope or gets 403). The list also hard-filters `League.disabled_at IS NULL`, `Division.archived_at IS NULL`, coworld-backed games (`:407-412`) and division/league visibility (`apply_round_read_visibility`, `B/v2/permissions.py:188-191`). Every other league-scoped list uses `league_id` as well (`divisions.py:122`, `league_policy_memberships.py:213`, `competition_events.py:72`, `leagues.py:3448` per the league subagent).

### Q9. `commissioner_state`

Column `leagues.commissioner_state` JSONB + `commissioner_state_version` int, on the table class only so it never reaches `LeaguePublic` (`B/v2/models.py:1246-1254`; spec `M/docs/specs/0065-league-commissioner-state-column.md`). It is the round brain's persisted state: container commissioners store an opaque blob; the platform ladder stores `{"kind":"platform_ladder_v1","standings":[…]}` (`B/v2/ladders/updater.py:185-191`); campaign stores `{"version":"campaign_v1",…}` (`B/v2/campaign/state.py:969-979`); landscape `{"version":"landscape_v1",…}` (`B/v2/landscape/state.py:51-56`). Each brain has its own `classify_state` returning `empty | <own> | foreign`.

Why the 409: `apply_ladder_round_update` (`B/v2/ladders/persistence.py:45-91`) refuses to run when `classify_state(league.commissioner_state) == "foreign"` — i.e. a non-empty document without `kind == "platform_ladder_v1"`, such as a leftover campaign board — and raises `ValueError` "ladder league … has foreign commissioner_state … refusing to overwrite it. Archive then explicitly clear leagues.commissioner_state" (`:64-90`). `POST /rounds/{id}/complete` wraps `ValueError`/`ValidationError` into **409** (`B/v2/routes/rounds.py:980-998`). So a league flipped to the ladder with a stale campaign board 409s on every completion until the blob is cleared. The container-commissioner path has the same refusal (`B/v2/pipeline.py:2761-2779` per the league subagent).

Who can write it via API: `PUT /v2/leagues/{id}/commissioner-state` (`commissioner.py:284-372`), `COMMISSIONER_API_AUTH` + `assert_commissioner_api_league_id` (`_shared.py:369-379`: cmr_ for its league, platform machine, or team member — **league owners are not admitted**). Optimistic CAS on `version` → 409 `commissioner_state_version_conflict` (`:305-312`). Once the ladder/campaign/landscape is enabled **or a campaign/landscape document is stored**, cmr_ tokens get 403 "platform league commissioner state is platform-owned" (`:322-349`) and team/platform writes must validate as the brain's model (`:350-365`; `PlatformLadderState` is `extra="forbid"`, so `{"kind":"platform_ladder_v1"}` is the minimal valid ladder doc, `updater.py:185-191`). Resetting to `None` through the API: `POST /leagues/{id}/reset-rounds` (TEAM_AUTH) sets `commissioner_state = None` and bumps the version (`B/v2/league_round_reset.py:217-218`) but **409s when the stored state is a campaign board** unless `destroy_campaign_state: true` (`leagues.py:2876-2910`, `league_round_reset.py:174-179`). Campaign leagues use `POST /leagues/{id}/campaign/restart` instead (`leagues.py:2881-2882`). Otherwise it is DB-only (`persistence.py:86-89` says "explicitly clear leagues.commissioner_state … see the ladder runbook"; UNVERIFIED which runbook file that refers to — no doc under `M/docs` names that procedure beyond the spec's reset-path note at `0065:199-204`).

### Q10. Coworld image upload, ownership, cert / canonical / graduation

Upload is `POST /v2/coworlds/upload` (`B/routes/coworld_routes.py:2219-2387`, `USER_AUTH` — a `ply_` session is rejected, hence "Coworld upload requires the user credential" at `M/web/docs/guides/authentication.mdx:58-59`). The CLI is `coworld upload-coworld` (`M/packages/coworld/src/coworld/cli.py:922-991`; orchestration `upload.py:1428-1512` per the coworld subagent). There is no `softmax coworld` command. The certification pipeline in metta is the certifier image workflow `M/.github/workflows/build-coworld-certifier-image.yml` plus the registry poller; the `upload-coworld-*.yml` workflows live in the game repos (e.g. `/Users/jamesboggs/coding/coworlds/coworld-ctf/.github/workflows/upload-coworld-paintbot.yml`).

Who may upload a new version of an existing name: `_assert_coworld_upload_owner` (`coworld_routes.py:1238-1245`) — the **original uploader** (earliest `created_at` row's `user_id`, `:1200-1203`) or a Softmax team member; then `_authorize_coworld_manifest_update` on the canonical/latest baseline row (`:1325-1339`) — same rule, and the new row keeps the original owner's `user_id` (`:2290-2294`). A team-owned `mch_` token does not help here (route admits USER only). "Anyone with a team token" is therefore wrong; it is *the original uploader or a team member with a user credential*. Concurrent uploads serialize on an advisory lock per name (`:2265-2268`); case-variant names 409 (`:2272-2281`); an equivalent version with a different hash/owner 409s (`:2306-2317`).

Canonical: `Coworld.canonical` (`B/v2/models.py:855`); at most one canonical row per name (`B/v2/coworlds.py:334-358`). A new upload becomes canonical only if its PEP-440 version is strictly greater than every existing canonical row (`coworld_upload_should_be_canonical`, `:330-331`). With `COWORLD_SMOKE_TEST_ENABLED` (prod) the row is created **non-canonical** (`coworld_routes.py:2321-2352`) and promotion is deferred to `promote_coworld_if_ready` (`B/coworld/smoke_test.py:222-300`), which requires: latest certification job completed **and** its `certification_request_id == coworld.latest_certification_request_id` (i.e. the attempt graduated, `:228-241`), all `SMOKE_EPISODE_COUNT` smoke episodes completed (`:243-256`), still version-dominant (`:258-261`), and every live league compatible (`coworld_manifest_league_errors`, `:263-296`) — then flips `canonical` (`:298-299`). Before either path can promote, `_assert_canonical_candidate_supports_leagues` 409s an upload that would strand a league (`coworld_routes.py:214-258`).

"Cert" = the hosted `coworld_certification` job auto-queued per upload (`coworld_routes.py:2372-2376`; `B/coworld/auto_certification.py`); states `never_run|queued|certifying|certified|failed` (`B/coworld/certification_status.py:36-41`). "Graduation" = the certifier stamped `graduated_at` in the job result; only then does `finalize_coworld_certification_job` move `coworlds.latest_certification_request_id` to the new `certification_requests` row (`B/job_runner/coworld_recording.py:37-77`; model comment `B/v2/models.py:864-871`). Spec header: "a Coworld cannot become canonical until its latest attempt graduates" (`M/docs/specs/0062-async-coworld-upload-certification.md:5-6`). Note `M/docs/ai/onboarding/services/coworlds/certification.md:57-58` still says the verdict "never blocks … canonical promotion" — **CONFLICT** with the code and the revised spec.

"Verify upload: uploaded version not found on server" is **not a metta string**. It is the coworld-ctf workflow step `/Users/jamesboggs/coding/coworlds/coworld-ctf/.github/workflows/upload-coworld-paintbot.yml:104-138`: after `coworld upload-coworld --wait-hosted-smoke --wait-certification` it polls `coworld list --json --limit 500` for up to 15 minutes until a row with the expected name+version reports `canonical: true`; "not found on server" is printed when no row matches at all (`:129`). Backend-side, the upload row exists immediately (`coworld_routes.py:2342-2352`), so "not found" after a *successful* upload means the poll's listing did not include it (the list is keyset-paginated, `coworld_routes.py:1984`; whether 500 rows covers the catalog is UNVERIFIED) or the freshness guard skipped the upload (the coordination note at `/Users/jamesboggs/coding/coworlds/coworld-ctf/docs/coordination/agents-notes.md:201-206` describes exactly that race with an already-canonical newer version).

### Q11. Is `game.description` patchable without a new version?

No. Each Coworld row's manifest is immutable ("new versions are new rows", `B/coworld/certification_status.py:5-7`); the only manifest-mutating route, `POST /v2/coworlds/patch-commissioner`, creates a *new* version row with only the commissioner image swapped (`coworld_routes.py:2460-2530`, auto-bumps the patch version `:1320-1323`). `games.description` is overwritten from the **canonical** manifest's `game.description` on every reconcile (`B/v2/seed.py:382`, `:487-488`). There is no `PATCH /games` route (catalog write is only `POST /games/{id}/default-league`, `B/v2/routes/catalog.py:79` per the coworld subagent). So a description change requires uploading a new version that becomes canonical.

### Q12. Rotation to a variant not in the canonical image

Who: anyone who can `POST /settings` — owner, team, cmr_, platform machine — because `variant_rotation`/`variant_rotation_by_seat_count` are the one ladder field a non-team writer may edit ("map_pool_only", `leagues.py:2482-2500`). What fails: the settings POST itself, with **400 "League settings are incompatible with its Coworld: ladder variant '…' is absent from the manifest"** (`leagues.py:2567-2596` → `coworld_manifest_league_errors`, `B/v2/coworlds.py:173-235`, message at `:207-209`), evaluated against the league's *effective* coworld — the canonical row, or the pinned row when game-version-locked (`coworld_for_league`, `:368-378`). The same check blocks the reverse direction: a new canonical candidate lacking a variant the rotation names is refused with 409 at upload (`coworld_routes.py:214-258`) and at promotion (`smoke_test.py:286-296`, logged "passed smoke but cannot become canonical"). If a stale rotation ever reaches planning, `round_lifecycle.py:1866` raises "Unknown Coworld variant … in variant_rotation" (`:1892-1894` for by-seat-count), which the round lifecycle surfaces as 409/failed planning. Default variant resolution failure is `B/v2/coworlds.py:76-81`.

### Q13. `coworld upload-policy` version labels

CLI `upload-policy` (`cli.py:1040-1101`) → `upload_policy_cmd` (`upload.py:1515-1534`) → `POST /stats/policies/docker-img/complete` (`B/routes/stats_routes.py:346-417`) → `get_or_create_policy_version` (`B/queries/policy_queries.py:152-203`): it locks the parent `Policy` row (`:174`), reuses an existing version when `(policy_id, container_image_id, attributes, player_id, policy_secret_env_id)` all match, else `next_version = (max(version) or 0) + 1` (`:190-195`, `:207-210`). So the label is a **per-policy integer counter** (per `Policy` = per user + name, `upsert_policy` per the policy subagent — exact uniqueness constraint UNVERIFIED), and the `vN` string is CLI formatting (`upload.py:1534` prints `Upload complete: {name}:v{version}`). Consequence: re-uploading the identical image with the same player and secrets returns the existing `vN`; uploading the same image under a different active player mints a new `vN`.

### Q14. Player identity, active player for a submission, the "2 active players" cap

Model: `players` with `owner_user_id`, `is_default` (one default per user), `disabled_at` (`B/models/players.py:16-67` per the policy subagent). Default player: `get_or_create_default_player` — active default, else promote the earliest active, else create (`B/queries/player_queries.py:46-77`).

Which player a submission is attributed to (`_submission_player_id`, `B/v2/routes/leagues.py:311-361`): a `ply_` session token forces its own player and 403s on a mismatching `player_id` (`:343-347`); with a user token, explicit `player_id` must be owned and active (`:349-355`), otherwise the default player (`:357-358`). The policy version is pinned to that player on first submission and later mismatches are 409 "already assigned to player …" (`:3546-3556`). `coworld submit --player ply_…` exposes the explicit form (`cli.py:1126-1136`); `coworld player use` swaps the CLI's identity for every command (`softmax/players.py:129-152`; COOKBOOK `M/packages/coworld/COOKBOOK.md:559-586`).

Two different "2" caps:
- **Per account**: `MAX_ACTIVE_PLAYERS_PER_USER = 2` (`B/routes/player_routes.py:38`); `POST /players` 409s "Users are limited to 2 active players" for non-team users (`:202-218`, counted as `disabled_at IS NULL` `:138-146`).
- **Per league**: `DEFAULT_MAX_PLAYERS_PER_LEAGUE = 2` (`B/models/user_settings.py:9`) → `MAX_ACTIVE_PLAYERS_PER_USER_PER_LEAGUE` (`B/v2/policy_membership_events.py:38`); resolution order: `user_settings.max_players_per_league` (team-set), then `settings.ladder.players_per_user`, then `commissioner_config.players_per_user` (`:45-58`); enforcement deactivates the oldest surplus live memberships with `substatus=inactive` (`:99-146`). Documented at `PLATFORM_LADDER_LEAGUE.md:338-353` ("Per-user seat cap … no retroactive sweep").

### Q15. Filler list write path

`POST /v2/leagues/{id}/filler-policies` (`leagues.py:3221-3286`), `COMMISSIONER_API_AUTH` + `assert_commissioner_api_league_or_owner` (`:3249`) — **league owners, team members, the league's cmr_ token, or the platform machine**. Body is either `policy_version_ids: [UUID]` or `filler_policies: [{policy_version_id, display_name}]`, not both (`:3155-3169`, `:3231-3234`); unknown policy versions 400 (`:3271-3280`); removing the campaign's configured baseline 400 (`:3251-3269`). Stored via `serialize_league_filler_entries` (`:3282`, `B/v2/league_fillers.py:56-67`). `GET` mirrors the gate (`:3203-3218`). The seed twin is `/seed-policies` (`:3322-3408`).

### Q16. `xp-request list` CLI vs API mismatch

Backend `GET /v2/experience-requests` (`B/v2/routes/experience_requests.py:968-1040`) takes `mine`, `limit`, `cursor` and returns `V2ExperienceRequestPage{entries, next_cursor}` (`B/v2/api_types.py:817-819`). Metta **main** CLI matches: `xp-request list --mine --limit --cursor` (`M/packages/coworld/src/coworld/tournament_cli.py:195-210`), client sends `mine/limit/cursor` (`api_client.py:1080-1094`), tests at `M/packages/coworld/tests/test_coworld_experience_request_cli.py:137-162`.

The mismatch is **version skew**: the last published tags `coworld-v0.1.43` and `coworld-v0.1.44` (both 2026-08-26) still send `limit`+`offset` and print `page.offset`/`page.total_count` (`git show coworld-v0.1.44:packages/coworld/src/coworld/tournament_cli.py` lines 199-209; `api_client.py` 1087-1092 in that tag), while the backend's cursor migration landed in `893f1b64f3` (2026-08-27) and `8dc40cb0bf` (2026-09-02). coworld-ctf pins `coworld[auth]==0.1.43` (four places, e.g. `upload-coworld-paintbot.yml:68,91,97`). Whether a newer release containing the fix has been published to PyPI is UNVERIFIED (no tag after 0.1.44 exists in the checkout; `pyproject.toml:80` uses `no-guess-dev` scm versioning). This matches the coordination note (`/Users/jamesboggs/coding/coworlds/coworld-ctf/docs/coordination/agents-notes.md:984`).

### Q17. `coworld episode-logs --list/--agent` 403 on commissioner-run league rounds

CLI flow (`tournament_cli.py:598-724`): every non-`--game` path first calls `GET /v2/episode-requests/{ereq}/policy-artifacts` (`:644`) before it ever reaches the `--agent` download (`:695`). That manifest route (`episode_requests.py:1213-1239`) uses `load_policy_manifest_episode_request` (`B/v2/episode_artifacts.py:451-478`), which loads the episode with **`include_public=False`** (`:465`) and then applies `_can_access_episode_request_artifacts` (`:398-405` / `:471`; 403 "You do not have access to this episode request", `:76-103`). For a round episode with no experience request, the visibility inputs are (`:153-173`): `owner_visible` = you requested it **or you own the round's league**; `player_visible` = the episode's `requester_player_id` is your active player; `public_visible` = public league, but that flag is deliberately switched off for this route ("Deliberately does NOT grant the public-league allowance: the manifest lists per-policy telemetry, which stays owner/team-scoped", `:468-470`). A commissioner-dispatched round has no requester user/player equal to you, so a non-owner, non-team caller is denied **before** ownership of a seated policy is ever consulted (`readable_episode_request_policies`, `:416-444`, runs after the gate). Owning a policy that played grants nothing: spec rule "Participation does not grant access" / "Using a policy does not grant its owner access to the request or episode that used it" (`M/docs/specs/0080-observatory-resource-visibility.md:8`, `:19`).

If a caller *is* a league owner or team member and still 403s on `--agent`, the second-stage check is `_certifier_can_read_policy` → `_policy_owned_by_scope` (`episode_requests.py:279-292`, 403 "You do not own this policy" `:1334-1335`): under a `ply_` session the scope is `PlayerScope`, which requires **both** `policy.user_id == you` and `policy_version.player_id == that player` (`B/authorization.py:244-259`) — so uploading as James Botts and reading as Games Bond 403s. `--game` uses `load_artifact_episode_request` with `include_public=True` (`episode_artifacts.py:386-406`) and therefore works on public-league rounds; the COOKBOOK already labels `--list`/`--agent --mine` as team-only (`M/packages/coworld/COOKBOOK.md:969-976`) and points non-team users at the raw per-policy route (`:962-966`), which is itself gated the same way.

### Q18. Documentation coverage

Docs that cover league admin / commissioner ops / coworld publishing (all read at least in the cited ranges):

- `M/packages/coworld/src/coworld/docs/PLATFORM_LADDER_LEAGUE.md` — the primary league-admin guide: ownership table (`:35-47`), create-a-league via seed → divisions → settings (`:160-235`), maintenance table incl. rounds-paused, trigger-round, per-user seat cap, retire (`:344-361`), hard rules (settings POST replaces the doc, seed PATCH replaces overrides) (`:359-368`), auth cheatsheet (`:384-392`).
- `M/docs/ai/onboarding/services/coworlds/platform-commissioner-api.md` — cmr_ token lifecycle (`:9-40`), endpoint table (`:42-58`), config ownership (`:68-75`).
- `M/docs/ai/onboarding/services/observatory/retire-seeded-league.md` — disabled leagues / seed kill switch (`:7-21`, `:88-89`).
- `M/docs/ai/onboarding/services/coworlds/README.md` — object model, CLI/API map (`:87-110`), operating-a-league table (`:112-123`).
- `M/docs/ai/onboarding/services/coworlds/certification.md` (`:51-69` auto-cert; note the stale "never blocks canonical promotion" claim at `:57-58`) and `M/docs/specs/0062-async-coworld-upload-certification.md` (`:5-19`).
- `M/docs/auth.md` (`:100-127` token storage + authorization table; per the auth subagent it omits `rrt_/cmr_/mch_` prefixes), `M/docs/specs/0080-observatory-resource-visibility.md` (product rules `:5-24`), `M/app_backend/AGENTS.md:19-27` (Bearer standard).
- `M/web/docs/guides/authentication.mdx:32-75` — user vs player credentials, "Coworld upload requires the user credential".
- `M/packages/coworld/COOKBOOK.md` — player swap (`:559-586`), XP requests (`:860-925`), logs incl. team-only `episode-logs --list/--agent` (`:943-985`).
- `M/packages/coworld/AGENTS.md`, `M/packages/softmax-cli/src/softmax/players.py:1-7` (player sessions), `M/docs/specs/0065-league-commissioner-state-column.md`, `0078-multiple-leagues-per-coworld.md`, `B/models/ID_GUIDE.md`, `B/v2/COWORLD_MECHANICS.md` (per the docs subagent; not read in full).
- CLI `--help` text is inline Typer help in `M/packages/coworld/src/coworld/{cli,tournament_cli,campaign_cli}.py` and `M/packages/softmax-cli/src/softmax/{cli,players}.py`; the public `M/web/docs/coworld/cli.mdx` is 34 lines and does not mirror the subcommands.

Questions with **no** doc coverage found (code is the only source):

- Q4 — the 401/403/404 matrix and the "404 hides existence" rule (only the one-line requirement in spec 0080:96).
- Q7 — the list of prefixes and the bare-UUID surfaces (ID_GUIDE explains the pattern, not the inventory or the exceptions).
- Q8 — that `GET /v2/rounds` takes `league_id` (only the OpenAPI schema).
- Q9 — the foreign-`commissioner_state` 409 and how to clear it (persistence.py refers to a "ladder runbook" that was not located).
- Q10 (partly) — the "original uploader or team" rule for new versions and the canonical-promotion gate order; the ctf workflow's "Verify upload" is a repo-local step.
- Q11 — description immutability.
- Q12 — the 400 on a rotation naming a missing variant (only the error text).
- Q13 — per-policy version counter and the dedupe reuse rule.
- Q14 (partly) — the per-account 2-player cap appears only in the route description string (`player_routes.py:205`) and a frontend constant; the per-league cap is documented in PLATFORM_LADDER_LEAGUE.md.
- Q15 — filler-policies endpoint and who may write it (COOKBOOK/PLATFORM_LADDER_LEAGUE mention `filler_policy` mode, not the endpoint).
- Q16 — the pagination skew (only in coworld-ctf coordination notes).
- Q17 — the *reason* for the 403 (COOKBOOK states team-only without saying why).
- Q3 (partly) — the ladder-half-of-settings 403 for owners and the `map_pool_only` exception are undocumented; Q5/Q6 are covered by retire-seeded-league.md and PLATFORM_LADDER_LEAGUE.md.

---

## Cross-references and surprises

1. **`league_owner_status.py` is not about ownership.** Despite the name it computes the owner-panel metrics (`B/v2/league_owner_status.py:1-23`); the ownership predicate is `league_owned_by_user` in `permissions.py`.
2. **Owners can pause, lock, and edit fillers — but not the ladder document, division topology, commissioner-state, visibility, or reset.** The owner surface is narrower than "league owner" suggests; see the Q3 table. Owners also cannot enable/disable their seed or change `default_variant_id` (`coworld_league_seeds.py:170-183`).
3. **A `ply_` session strictly narrows authority** (`authorization.py:244-259`): it cannot manage leagues (`_shared.py:452-453`), cannot upload a coworld (USER_AUTH), cannot use `--elevated` (`api_client.py:724-731`), and only reads evidence attributed to that exact player. Forgetting `coworld player unset` is a plausible root cause for several of the coordination notes' 403s.
4. **`X-Use-Elevated-Privileges` is required for any team-only call**, including from team members' own tokens (`auth.py:393-402`); the CLI never sends it unless `--elevated` (`softmax/auth.py:203-212`).
5. **Seed `enabled:false` is teardown, not pause** (`seed.py:719-748` revokes commissioner tokens; runbook `retire-seeded-league.md:32-42`). Pause is `POST /rounds-paused`.
6. **certification.md contradicts the code/spec** on whether certification gates canonical promotion (`certification.md:57-58` vs `smoke_test.py:228-241`, spec 0062:5-6).
7. **Published `coworld` 0.1.43/0.1.44 predate the cursor-pagination backend change**, breaking `xp-request list` (Q16). Other list commands in the same tag (`reporters`, `rounds`) also use `--offset` (tag `tournament_cli.py:256`, `:382`) and may be affected similarly — UNVERIFIED which backend routes still accept `offset`.
8. **Two independent "2 players" caps** (account vs per-league) with different override paths (Q14).
9. **Debug tokens**: with `DEBUG_AUTH_ENABLED`, `debug-machine:<id>` grants every machine scope (`auth.py:656-668`); irrelevant for prod but explains local-stack behavior.
10. **`GET /v2/coworlds` returns the full manifest of every coworld to any authenticated user** (`coworld_routes.py:1984`, per the coworld subagent); only the certification transcript is owner-gated (`:2150-2160`).

## Unresolved

- The exact "ladder runbook" referenced by `persistence.py:88` for clearing `commissioner_state` was not located under `M/docs` or `M/agent-plugins`.
- Whether a `coworld` release newer than 0.1.44 (with cursor-based `xp-request list`) has been published; only git tags were checked.
- `upsert_policy` uniqueness (per user+name) — inferred from the subagent's read of `stats_routes.py:289-316` / `policy_queries.py`; the constraint itself was not read.
- `POST /admin/machine-credentials` handler line ranges and `PUT /leagues/{id}/coworld-budget` auth — reported by subagents, not read in full here.
- Whether `coworld list --json --limit 500` in the ctf workflow can miss the just-uploaded version on a large catalog (keyset pagination at `coworld_routes.py:1984`); the "not found on server" branch depends on it.

## Files read (full or significant section)

- `B/auth.py` (full), `B/authorization.py` (full), `B/credential_tokens.py` (full), `B/models/credentials.py` (full), `B/models/ids.py`, `B/models/ID_GUIDE.md`, `B/models/user_settings.py`, `B/config.py:40-80`, `B/server.py:285-340`
- `B/v2/permissions.py` (full), `B/v2/league_owner_status.py` (full), `B/v2/routes/_shared.py` (full), `B/v2/league_settings_schema.py` (full), `B/v2/league_settings.py` (full), `B/v2/league_fillers.py` (full), `B/v2/seed.py` (full), `B/v2/coworlds.py` (full), `B/v2/routes/commissioner.py` (full), `B/v2/schema.py`
- `B/v2/routes/leagues.py`: 255-362, 1460-1480, 1700-1990, 1990-2735, 2859-2950, 3125-3300, 3501-3560
- `B/v2/routes/rounds.py`: 195-300, 376-448, 918-1005; `B/v2/routes/coworld_league_seeds.py`: 60-200, 885-1000; `B/v2/routes/league_logs.py`: 1-260; `B/v2/routes/episode_requests.py`: 279-301, 1213-1262, 1290-1370; `B/v2/routes/experience_requests.py`: 960-1045
- `B/v2/models.py`: 131-274 (prefixes), 832-900, 955-1035, 1072-1370; `B/v2/ladders/persistence.py`: 1-140, 220-250; `B/v2/ladders/updater.py`: 185-212; `B/v2/ladders/config.py`: 120-160; `B/v2/campaign/state.py`: 969-989; `B/v2/landscape/state.py`: 51-62; `B/v2/policy_membership_events.py`: 1-150; `B/v2/league_round_reset.py` (grep); `B/v2/episode_artifacts.py`: 76-192, 193-313, 386-478
- `B/routes/coworld_routes.py`: 210-260, 1198-1245, 1318-1342, 2195-2400, 2460-2530; `B/routes/player_routes.py`: 117-240, 338-410; `B/routes/stats_routes.py`: 470-660; `B/queries/player_queries.py` (full); `B/queries/policy_queries.py`: 152-210 (grep); `B/coworld/smoke_test.py`: 215-305; `B/coworld/certification_status.py`: 1-80; `B/job_runner/coworld_recording.py`: 30-100
- `M/packages/metta-app-backend-client/src/metta/app_backend/wire/prefixed_id.py` (full); `M/packages/coworld/src/coworld/cli.py`: 1040-1160 (+ command map); `tournament_cli.py`: 120-240, 598-724, 1246-1270; `api_client.py`: 690-760, 1080-1096, 1140-1160; `config.py`; `upload.py` (grep); `M/packages/softmax-cli/src/softmax/auth.py`: 1-140, 140-270; `players.py` (full)
- Docs: `M/app_backend/AGENTS.md` (full), `M/docs/ai/onboarding/services/observatory/retire-seeded-league.md` (full), `M/docs/ai/onboarding/services/coworlds/{platform-commissioner-api,platform-ladder-league,README,certification}.md` (full), `M/docs/specs/0080-observatory-resource-visibility.md` (full), `M/docs/specs/0065-league-commissioner-state-column.md:160-230`, `M/docs/specs/0062-*.md` (grep), `M/docs/auth.md:100-135`, `M/web/docs/guides/authentication.mdx:28-88`, `M/packages/coworld/src/coworld/docs/PLATFORM_LADDER_LEAGUE.md`: 30-60, 155-235, 340-405, `M/packages/coworld/COOKBOOK.md`: 555-600, 860-990, `M/AGENTS.md:130-160`
- coworld-ctf: `.github/workflows/upload-coworld-paintbot.yml:90-140`, `docs/coordination/agents-notes.md:190-215`, `:984`, `:1014`
- Git (read-only): `git show coworld-v0.1.43` / `coworld-v0.1.44` for `tournament_cli.py` and `api_client.py`; `git log -S next_cursor -- tournament_cli.py`
