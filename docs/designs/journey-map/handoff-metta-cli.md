# Handoff to the metta CLI/docs worker — Stop 4 (THE WHOLE)

Written while building Stop 4 ("Your first policy",
[docs/wiki/your-first-policy.md](../../wiki/your-first-policy.md)). Every
file below was located by reading the **live** `Metta-AI/metta` `main`
branch via `gh api` (2026-09-09) — the read-only sibling checkout at
`/Users/maxwellstarr/projects/metta` on this machine is stale (last commit
2026-07-29) and was not used for citations, only as a starting grep target.
None of this was edited; it is not ours to ship (`packages/coworld` and
`web/docs` are metta repo paths). One item (#2) turned out to be partly
**ours** — flagged below rather than filed as a pure metta ask.

## 1. Help banner naming the human page and play.md

**File:** `packages/coworld/src/coworld/cli.py:80-83` (the `typer.Typer(...,
epilog=...)` on the root `app`).

**Current text** (verified live, matches what `coworld --help` printed in
a fresh install on 2026-09-09):

```
New agent? Start at https://softmax.com/llms.txt (the agent hub) and
https://softmax.com/play.md (the Game of the Week guide). `coworld leagues`
shows where each public league's participation guide lives.
```

**Ask:** a second sentence addressed to a human, not an agent — Law 4
("two audiences, one truth... a human is never handed an instruction
addressed to an agent"). Something like: "Building by hand? Start at
`docs/wiki/your-first-policy.md` in your game's repo, or ask `coworld
leagues` for the game's own docs." This repo's half (the page existing,
and the wiki knowing its own URL) is done; the banner text itself is
metta's to change.

## 2. `run-episode` success message naming `coworld replay`

**File:** `packages/coworld/src/coworld/cli.py:1642-1649`
(`_echo_feedback_commands`).

The logic is **already correct** when it fires:

```python
if uses_static_replay_viewer_bundle:
    typer.echo(f"Inspect replay: open {artifacts.replay_path} in your static "
               "replay viewer bundle (see STATIC_REPLAY_VIEWERS.md)")
else:
    replay_command = ["uv", "run", "coworld", "replay", manifest_uri, str(artifacts.replay_path)]
    ...
    typer.echo("Inspect replay: " + shlex.join(replay_command))
```

`uses_static_replay_viewer_bundle` (line 1384) is
`package.manifest.game.replay_viewer is not None` — and Paintbot's own
manifest **sets that field**, in **our** repo:
[`coworld_manifest_paintbot.json:12-15`](../../../coworld_manifest_paintbot.json):

```json
"replay_viewer": {
  "bundle": "static-replay-viewer",
  "replay_compression": "gzip"
}
```

This is the actual root cause of J19 (docs/designs/JOURNEY_MAP.md), not a
metta CLI defect — a real `coworld replay <manifest> <replay>` was
verified live on 2026-09-09 (served a working viewer, HTTP 200, on
`http://127.0.0.1:<port>/client/replay`), so the static-bundle branch looks
stale for Paintbot's current setup. **Recommend the Stop 2 / replay-client
owner evaluate dropping `game.replay_viewer` from
`coworld_manifest_paintbot.json`** — if it's safe to drop, J19 closes with
a one-line coworld-ctf change and *no* metta PR. If Paintbot genuinely
still needs the static-bundle path for some other consumer, then the ask
for metta is: have the `uses_static_replay_viewer_bundle` branch **also**
print the `coworld replay` command as a "just want to look" alternative,
since it works today regardless of which manifest field is set.

## 3. `--variant` defaulting to the live variant, server-side

**Files, all in `packages/coworld/src/coworld/cli.py`**, three separate
copies of the same help string "Defaults to the certification fixture.":

- line 682 — `play`
- line 1253 — `run-episode`
- line 1409 — `scrimmage`

Verified live (jm-door S16, reproduced again while building `run_local.py`):
omitting `--variant` on any of these silently swaps to a two-team
certification fixture on a different map (`arena`, not `brpool16`) with no
warning — J17.

**Ask:** either (a) default to a variant the Coworld's own manifest names
as its live/primary one, if `coworld_manifest.json` ever grows such a
field, or (b), lower-risk and no schema change needed, print a one-line
stderr warning whenever `--variant` is omitted and a non-certification
episode was clearly intended (e.g. any real player image was supplied,
not just the bundled certification players) — so the silent swap becomes a
visible one. `run_local.py` in this PR works around this by always passing
`--variant` explicitly and refusing to start if its own variant constant
is unset; that's a client-side fix, not a CLI fix.

## 4. `coworld download` naming the live version

**Files:** `packages/coworld/src/coworld/upload.py`.

`resolve_coworld_download_id` (line 1737-1748) returns a literal `cow_...`
ID **verbatim, with no freshness check**, when one is given — which is
exactly what `docs/wiki/build-and-submit.md` and this repo's own
`README.md` document (`cow_3aa0f59a-6146-4bcf-822e-daea1bf889a4`).
Verified live 2026-09-09: that ID resolves to `paintbot:0.7.367`
(`gameVersion: "60"` / `gloryVersion: 15` at runtime), while the live
ladder was at `paintbot-v0.7.377` (GameVersion 62 / GLORYVERSION 17) —
**two full versions behind**. The download's own generated `AGENTS.md`
does say "No public league runs this Coworld version" (from the league
filter at `upload.py` ~line 1850), so the drift isn't silent, but a
documented literal ID is guaranteed to go stale every time Paintbot
publishes, and there's no CLI-side way to notice without downloading first.

The one path that *would* stay current — `coworld download paintbot` (by
**name**, resolving to the platform's canonical build) — requires signing
in first:

```
RuntimeError: Not authenticated. Run: uv run softmax login --server https://softmax.com/api
```

verified live: `resolve_coworld_download_id` calls
`find_canonical_coworld` (line 688-691), a method on the **authenticated**
`CoworldUploadClient` class (`CoworldUploadClient.from_login(...)`, line
~1746). Twenty lines further down the same function, listing which
leagues run a Coworld ID uses the **anonymous** `CoworldApiClient`
(comment on that line: "Anonymous read: the league listing is public, so
the guide links need no login"). Listing-by-name and listing-leagues look
like the same class of read.

**Ask:** move (or duplicate) `find_canonical_coworld` onto the anonymous
client, so `coworld download <name>` works without `softmax login` — then
docs can stop hardcoding a `cow_` ID that drifts, and name the game
instead.

## 5. The docs.softmax.com Paintbot page

**Files:** `web/docs/guides/quickstart.mdx` (title "Build your first
player") and `web/docs/coworld/overview.mdx`, both in the metta repo's
Mintlify docs app (`web/docs/`, `docs.json` is the Mintlify config).

Neither names any specific game. `quickstart.mdx`'s entire "Before you
begin" / "Follow the live participation guide" section is addressed to a
coding agent verbatim: "Give your coding agent this prompt: `Let's follow
https://softmax.com/play.md`" — confirms jm-door S10 exactly, with an
exact file now. `overview.mdx`'s "Build a player" card links generically;
no worked example is named anywhere in the Coworld doc tree searched.

**Ask:** name Paintbot as the worked example somewhere in this tree — either
inline in `quickstart.mdx` (a "for example, Paintbot..." aside linking
`softmax.com/paintbot` and `docs/wiki/your-first-policy.md` for the human
path) or a small new page under `web/docs/coworld/build-a-player/`. Either
way, the human path and the agent path should sit side by side per Law 4,
the way `coworld --help`'s banner should (item 1).

## 6. The GitHub README naming Paintbot

**File:** `README.md` at the `Metta-AI/metta` repo root (111 lines,
verified live 2026-09-09).

Zero mentions of "Paintbot" or "Paint Arena." The only "arena" hits are
metta's own unrelated RL training tool (`./tools/run.py train arena`,
lines 99-108) — a different "arena," not this game. This repo's own
`README.md` (coworld-ctf) already names Paintbot clearly and is not part
of this ask; J6's remaining half is the metta monorepo's own top-level
README, which a stranger following a GitHub search or link is at least as
likely to land on first.

**Ask:** one line naming Paintbot as a running example, linking
`softmax.com/paintbot` and `github.com/Metta-AI/coworld-ctf`.

## What this handoff does not cover

- Items 1-6 above are the six named in this task's brief. Building
  `docs/wiki/your-first-policy.md` surfaced two more coworld-ctf-owned
  (not metta-owned) breaks worth a separate note to whoever owns Stop 3:
  `coworld_manifest_paintbot.json:16`'s `game.description` still says
  "sixteen duos" — the same stale claim JOURNEY_MAP.md's J12 flags for
  `modes.md`, but *this* copy is the one `.github/workflows/
  upload-coworld-paintbot.yml:149` actually publishes from
  (`--template coworld_manifest_paintbot.json`), not a live settings POST
  as THE_WHOLE.md's lane table (§4) assumed — worth correcting that
  assumption before Stop 3 files it as a metta/league-settings ask.
- No PR against `Metta-AI/metta` was opened or drafted; this file is the
  handoff, not the fix.
