# Starter LLM policies — three examples that play differently

Three deployable policy images built on the proven `poc_llm_policy` machinery
(`../poc_llm_policy/README.md` documents the wire protocol, the model
backends, and the canonical-encoding traps — read it first). Each starter is
the same protocol client with a different **persona**: a different system
prompt, a different re-call schedule, and a different set of harness rules
that shape whatever the model (or the canned fallback) decides. They are
meant to be handed to players as worked examples, and they visibly do
different things in the same match.

| policy | one line | model calls / match | base play | signature harness rules |
| --- | --- | --- | --- | --- |
| `aggressive/` | hunts; tight zone margins; re-calls eagerly | up to 8, min 6 s apart | `jackal` (holds in cover, joins the first fight heard) | kill-feed lines in the summary; margins clamped tight; pacts always `returnFire`; races pickups |
| `cautious/` | survives; wide margins; calls rarely | up to 4, min 15 s apart | `edge_ride` | margins floored wide; omitted params filled with safe defaults; pacts always `disengage`; hold fire until zone phase 2 (`target_law holdTrigger {zonePhase: 2}`); short safe detours for pickups |
| `collaborative/` | duo-first; pact with protect always; talks | up to 6, min 10 s apart | `edge_ride` | partner state leads the summary; a coordination chat line every turn; duo pact injected with `protect: true`; `bodyguard` only when the ward drifts past its leash |

Every persona also carries the shared live loop, live-state summary, and
harness-side ladder gating described below; the rows above are only what
makes them differ.

## Layout

```
starters/
  common/
    plays.py            the plays manifest -- single source of truth for specs
                        AND prompt text; the drift guard between prompt and
                        playbook lives here
    starter_harness.py  the shared harness: Persona seam over the PoC's
                        wire/brain/poc_policy machinery (imported, not copied);
                        the live loop, live-state summary and ladder gating
    build_playbook.sh   compiles EVERY play in play_sdk/reference/ (the PoC's
                        script names its two; this one discovers them)
  aggressive/           system_prompt.md, policy.py (harness deltas),
  cautious/             Dockerfile, README.md -- one directory per policy
  collaborative/
  VERSION_LOG.md        platform version -> change, per policy (keep it current)
```

The harness imports `wire.py`, `brain.py` and `poc_policy.py` from
`policies/poc_llm_policy/` by relative path; the images preserve that layout.
The protocol layer is not forked.

## How a starter plays a match (the live loop)

The PoC made an opening call plus one or two re-calls and then exited; the
seat rode its last ladder with nobody home for ~75% of every match. The
starters now stay connected until the server closes the socket:

1. **Lobby.** One model turn: chat line, playbook upload, opening call.
2. **Live loop** (`starter_harness._live_loop`). The seat pumps the socket
   and watches the 0xB1 view. It re-calls the model when something changed —
   own hp fell, zone phase moved, duo partner eliminated, shot at, kills in
   the feed — spaced at least `recall_seconds` apart, unconditionally every
   `periodic_seconds`, and never more than `max_calls` per match. Every
   summary carries a **live-state block** (position, hp, zone current/next
   rect and whether you are inside it, enemies ranked by distance with hp and
   track age, partner distance, items in view, who shot at you).
3. **Ladder maintenance** (no model). The engine steps the FIRST controller
   whose guard passes, and a controller that emits nothing hands the seat to
   the engine default — never to the next rung. So a `supply_run` with
   nothing to do, or a `bodyguard` whose ward is fine, must be kept OFF the
   ladder or it pins the seat with its idle hold. `layer_ladder` evaluates
   the gates from the live view (`gate_open`) and re-sends the gated ladder
   whenever the gate state changes: `supply_run` only when wounded with a
   medkit in view, `loot` only when no fresh enemy track is within 500 px
   and a non-medkit item is within `detourMax`, `bodyguard` only when the
   ward has drifted past its leash, `jackal`/`crossfire` only with enemies
   tracked. Overlays (`pact`, `target_law`) always ride along, and the
   persona's base play (below) is never gated.
4. **Base play.** `Persona.base_play` names the always-on rung, ordered
   above any other unguarded controller and appended if the model omitted
   it: `edge_ride` (default), `jackal` (the hunter: holds in cover until a
   fight is heard), or `None` (the engine default rotate + zone reflex
   drive; set `POC_NO_BASE_PLAY=1` to force it). For the first 150 ticks
   after the seat's first view the base is always `edge_ride`, whatever the
   persona chose — a base that holds when idle, parked at spawn next to a
   hostile duo, was the aggressive starter's top cause of death.

Why the harness gates instead of the wire's `when` guards: for play seats
the engine currently evaluates guards against `noGuardContext()`
(`src/shell/episode.nim`) — every path reads `0.0`/`false` — so a
`self.hp_frac < 0.8` guard is always true and `partner.alive` always false.
The harness deliberately never forwards `when`.

Robustness, both learned the hard way on hosted rounds: the play socket is
opened with retries inside the lobby join allowance (`--connect-deadline`,
240 s; a single 30 s attempt lost 15 of 114 seats in one batch), and the
client keepalive `ping_timeout` is disabled (a late pong during a model call
closed live sockets with 1011, and a play seat cannot rebind mid-match).

## The prompt/playbook drift guard

`common/plays.py` is the only place a play is described. The system prompt's
playbook section is **generated** from it, filtered to the plays actually
baked in the image, and the harness refuses to start if the playbook carries
a `.wasm` the manifest does not know. So when lane C lands the next reference
plays (`target_law`, `bodyguard`, `jackal`, `supply_run`, `crossfire`):

1. rebuild the playbook (`common/build_playbook.sh` picks up every
   `play_sdk/reference/*.nims` automatically),
2. add a manifest row (specs + brief) to `common/plays.py` — the harness
   fails loudly until you do,
3. nothing else: each persona already carries dormant `play_notes` for the
   expected plays, which enter the prompt automatically once the play is
   baked.

## Run one locally

Against a stock server configured with play seats (see
`../poc_llm_policy/README.md` for the
server-side rig; unfilled slots need presence connections and the lobby-chat
window must be open):

```bash
python3 -m venv .venv && .venv/bin/pip install "websockets>=13"
POC_HOST=127.0.0.1 POC_PORT=21820 POC_SLOT=0 POC_TOKEN=<token> \
POC_PLAYBOOK=<dir of .wasm> \
  .venv/bin/python policies/starters/aggressive/policy.py --canned
```

`--canned` uses the persona's own scripted decisions (each persona's canned
turns exercise its character, so the three differ even offline). With
`OPENROUTER_API_KEY` set, decisions come from a real model; in a hosted pod
the platform's LLM sidecar is used automatically. Backend selection is the
PoC's, unchanged.

Knobs beyond the PoC's (`policy.py --help` lists them all): `--max-calls` /
`POC_MAX_CALLS` (model calls per match, opening included), `--recall-seconds`
/ `POC_RECALL_SECONDS` (minimum spacing between them), `--connect-deadline`
/ `POC_CONNECT_DEADLINE` (keep retrying the play socket for this long,
default 240 s), and `POC_NO_BASE_PLAY=1` (no base play; the engine default
drives when every gate is closed). Hosted, set env knobs at upload time with
`coworld upload-policy --secret-env KEY=VALUE`.

The full local proof is one match of sixteen seats on the hosted game image:

```bash
coworld play <coworld id of the canonical paintbot> starter-cautious:vN \
  --run python --run /app/policies/starters/cautious/policy.py --run --canned \
  --variant battle-royale-s2 --no-open-browser -o /tmp/localplay
```

`--run` is required: without it the runner reuses the manifest's reference
player command (`/bin/baseline`) and every seat fails to start. The per-seat
logs land in `<output dir>/logs/policy_agent_N.log` and the replay in
`<output dir>/replay`.

## Traps a policy author will hit

Beyond the list in `../poc_llm_policy/README.md` ("Where the docs and schemas
were not enough"), one more found while building these:

- **An empty ladder is rejected** (`call_validation.nim`: 1..16 entries).
  When every gate is closed and there is no base play, the harness sends a
  parameterless `target_law` as the honest no-op overlay.
- **Policy version numbers are per-policy counters.** `coworld
  upload-policy` prints the platform label (`starter-cautious:v8`); it drifts
  from your local docker tag the moment you upload one persona without the
  others. Keep a version log per policy; an experience request with a wrong
  label is refused with "policy_ref matched no version N".
- **Lobby chat is rate limited per seat.** A second 0xA3 from the same seat
  within `LobbyChatMinSpacingTicks` (24 ticks, ~1s — `src/ctf/sim_types.nim`)
  is refused with `lobby_chat:lcrTooSoon`, delivered as a status entry, and
  the line is dropped. A policy that sends two lines back to back (the
  collaborative starter's model chat + coordination line) loses the second
  silently unless it spaces them; `common/starter_harness.py`
  (`_send_coordination`) holds ~1.5s and confirms the 0xB2 echo.

## Build the images

From the repository root:

```bash
docker build -f policies/starters/aggressive/Dockerfile    -t starter-aggressive .
docker build -f policies/starters/cautious/Dockerfile      -t starter-cautious .
docker build -f policies/starters/collaborative/Dockerfile -t starter-collaborative .
```

Run as in the PoC README (`POC_HOST=host.docker.internal`, or `--network
host` on Linux). No model credentials are baked into any image.
