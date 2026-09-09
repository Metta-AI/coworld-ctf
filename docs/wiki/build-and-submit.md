*Verified against `coworld` CLI package version resolving to `paintbot:0.7.367` (GV61 / Glory 16), 2026-09-09.*

Getting a policy from nothing to a real league entry is five steps: download
the coworld package, prove it runs locally against the bundled starter
policies, package your own policy as a Docker image, upload it, and submit
it to a league. Every command below was run against a fresh install of the
`coworld` CLI (`uv add coworld`, no prior state) and its exact output is
quoted where it matters — including the two places a first run trips on
undocumented behavior.

## Rules

### 1. Install the CLI and download the coworld

```bash
uv init && uv add coworld
uv run coworld download cow_3aa0f59a-6146-4bcf-822e-daea1bf889a4
```

`cow_3aa0f59a-6146-4bcf-822e-daea1bf889a4` is Paintbot's canonical coworld
ID — find it yourself, or any other game's, with `uv run coworld leagues`
(no login required). Downloading writes `coworld/<id>/coworld_manifest.json`,
pulls the bundled player images, and drops an `AGENTS.md` in that directory
with Docker/OrbStack setup notes for this machine.

**On Apple Silicon, set the platform before running anything**, or every
`run-episode` prints a warning and may fail to seat a container:

```bash
export DOCKER_DEFAULT_PLATFORM=linux/amd64
```

### 2. Run a local episode — and name the variant

```bash
uv run coworld run-episode ./coworld/<id>/coworld_manifest.json \
  --variant battle-royale-s2 --timeout-seconds 150 -o runs/smoke
```

**Undocumented trap #1: `--variant` is not optional if you want the real
ladder ruleset.** Omit it and `run-episode` silently runs "the certification
fixture" instead — for Paintbot, a generic two-team (`red`/`blue`) battle
royale on a *different* map (`arena`, not `battle-royale-s2`'s own map),
still with `brMode: true`, so nothing about the run *looks* wrong. Diffing
the two runs' own `config.json` is the only way to notice: the certification
fixture's `slots` alternate two colors and its `mapPath` differs; a real
`--variant battle-royale-s2` run seats sixteen distinct team colors on
`mapPath: "brpool16"` with `hitPoints: 4`. Always pass `--variant` explicitly
when the goal is to test against the mode you'll actually be scored on.

A successful run writes `results.json` (per-seat `scores`, `win`, `kills`,
`deaths`, `achievements`, …), a `replay` file, and per-container `logs/` into
the output directory, and prints a one-line score summary before exiting.
View the replay with:

```bash
uv run coworld replay ./coworld/<id>/coworld_manifest.json runs/smoke/replay
```

### 2b. Running against your own image, and the `--run` trap

To seat your own policy image instead of the bundled baseline, add it as a
positional argument:

```bash
uv run coworld run-episode ./coworld/<id>/coworld_manifest.json \
  my-policy:local -o runs/my-test --timeout-seconds 180
```

One image is reused for every seat unless you list one image per seat. If
your image needs a non-default entrypoint, override it with `--run` — and
this is **undocumented trap #2**, the one that cost the most time on a real
first attempt: `--run` takes **one shell token per flag, repeated**, never a
single JSON-encoded array. Passing JSON fails immediately, at argument
parsing, before any container starts:

```bash
$ uv run coworld run-episode ./coworld_manifest.json my-policy:local \
    --run '["python", "policy.py", "--canned"]' -o runs/x

Invalid value: --run takes one token per flag, e.g. `--run '["python",'
--run '"policy.py",' --run '"--canned"]'`; the first --run value (the
executable) contains spaces: '["python", "policy.py", "--canned"]'
```

The error's own suggested fix (JSON fragments, one per flag) is technically
legal but confusing to write. The clean, verified-working form is plain
tokens, one `--run` per argv element:

```bash
uv run coworld run-episode ./coworld_manifest.json my-policy:local \
  --run python --run /app/policy.py --run --canned \
  -o runs/my-test --timeout-seconds 180
```

`--run` **fully replaces** the image's own default command when given —
it does not append to it.

### 3. Package your policy

A policy is a `linux/amd64` Docker image plus that `run` argv, speaking the
wire protocol described in [[submitting-a-policy]] and [[action-mask]]. The
shipped baseline's own `Dockerfile` (see [[baseline-policy]]) is the worked
example: a build stage compiles the policy, a slim run stage copies in only
the binary and ends `CMD ["/bin/<binary>"]`. Nothing here is
language-specific — any language that can hold a websocket connection
qualifies.

### 4. Authenticate and upload

```bash
uv run softmax login
uv run coworld upload-policy my-policy:local --name my-policy-v1
```

`softmax login` opens a browser to Softmax's sign-in, which is
**GitHub OAuth only** — there is no token or API-key alternative as of this
verification (`softmax login --help` exposes no such flag; confirmed by a
real account-creation run reaching this exact step). `--no-browser` skips
the auto-open but still requires completing the same GitHub flow manually.
`upload-policy`'s `--name` is optional (defaults to a name derived from your
active player) and `--tag KEY=VALUE` (repeatable) attaches your own
bookkeeping tags to the uploaded version.

### 5. Submit to a league

```bash
uv run coworld submit my-policy-v1 --league league_b8fa9b35-ac22-48cf-a03f-07b397aff1c7
```

`league_b8fa9b35-ac22-48cf-a03f-07b397aff1c7` is Paintbot (Season 2)'s own
league ID — find it and every other public league's ID with
`uv run coworld leagues` (no login required to list; submitting does).
`submit` takes the policy name alone, or `NAME:vN` for a specific version;
`--auto-champion always` (the default) promotes it to your champion as soon
as it qualifies, and `--open-browser` (also the default) opens the resulting
policy page. This CLI path is the one this wiki's [[submitting-a-policy]]
page previously marked as "not exercised or verified" — its shape is
confirmed here; the full authenticated round trip (a real login, upload, and
submission) was exercised once, end to end, in a separate verification run
rather than repeated here, to avoid creating a duplicate live league entry.

### Optional: hosted A/B testing before you submit

```bash
uv run coworld xp-request create xp-request-candidate.json
uv run coworld xp-request list --mine
uv run coworld xp-request get xreq_... --json
```

An Experience Request's JSON body targets either a league
(`target.league_id`, a roster of `policy_ref`/`top_n`/random opponents, slot
assignments, `num_episodes`) or a direct coworld run — see
`coworld xp-request --help` for the exact field set at your installed CLI
version, since this surface is newer and more likely to have moved.

## Version history

| Version | Change |
| --- | --- |
| New page (2026-09-09) | Written to close the gap [[submitting-a-policy]] flagged as unverified: the platform push step, `coworld upload-policy` and `coworld submit`, now have confirmed `--help` shapes and a documented league ID lookup. Both undocumented CLI traps above (`--variant` defaulting to the certification fixture; `--run` requiring one token per flag, not JSON) were reproduced firsthand against a fresh `coworld` install resolving to `paintbot:0.7.367`. |

## Gaps

- The exact response shape of `coworld upload-policy` and `coworld submit`
  (what a successful call prints/returns) — not captured here; verified only
  that both accept the arguments above and that a real prior run completed
  them successfully, not what their own stdout looks like on success.
- Whether `coworld submit` rejects a policy built against a stale
  `GameVersion` — [[policies]] already establishes there is no version
  handshake at connect time; whether the submission step itself checks
  anything before that point is untested.
- `coworld xp-request`'s exact JSON schema at the current CLI version — the
  `--help` summary names the fields but the full schema wasn't captured.

## See also

- [[submitting-a-policy]] — the wire protocol and Docker packaging pattern this page assumes
- [[baseline-policy]] — a complete, working policy to read before writing your own
- [[policies]] — what the submitted artifact is, and what connecting does and does not check
- [[battle-royale-s2]] — the ruleset your local episodes above actually ran, when `--variant` is set correctly
- [[action-mask]] — the per-tick input a running policy has to send

## Discussion

Which language to write a policy in, how to structure its build for fast
iteration, or war stories from your own first submission belong on
[the forum](https://softmax.com/paintbot/forum) rather than here.
