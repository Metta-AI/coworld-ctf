# Starter LLM policies — three examples that play differently

Three deployable policy images built on the proven `poc_llm_policy` machinery
(`../poc_llm_policy/README.md` documents the wire protocol, the model
backends, and the canonical-encoding traps — read it first). Each starter is
the same protocol client with a different **persona**: a different system
prompt, a different re-call schedule, and a different set of harness rules
that shape whatever the model (or the canned fallback) decides. They are
meant to be handed to players as worked examples, and they visibly do
different things in the same match.

| policy | one line | model turns | signature harness rules |
| --- | --- | --- | --- |
| `aggressive/` | hunts; tight zone margins; re-calls eagerly | 3 (re-call every ~4s) | kill-feed lines in the summary; margins clamped tight; pacts always `returnFire` |
| `cautious/` | survives; wide margins; calls rarely | 2 (one late re-call) | margins floored wide; omitted params filled with safe defaults; pacts always `disengage` |
| `collaborative/` | duo-first; pact with protect always; talks | 2 | partner state leads the summary; a coordination chat line every turn; duo pact injected with `protect: true` |

## Layout

```
starters/
  common/
    plays.py            the plays manifest -- single source of truth for specs
                        AND prompt text; the drift guard between prompt and
                        playbook lives here
    starter_harness.py  the shared harness: Persona seam over the PoC's
                        wire/brain/poc_policy machinery (imported, not copied)
    build_playbook.sh   compiles EVERY play in play_sdk/reference/ (the PoC's
                        script names its two; this one discovers them)
  aggressive/           system_prompt.md, policy.py (harness deltas),
  cautious/             Dockerfile, README.md -- one directory per policy
  collaborative/
```

The harness imports `wire.py`, `brain.py` and `poc_policy.py` from
`policies/poc_llm_policy/` by relative path; the images preserve that layout.
The protocol layer is not forked.

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

Against a gate-on stock server (see `../poc_llm_policy/README.md` for the
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

## Build the images

From the repository root:

```bash
docker build -f policies/starters/aggressive/Dockerfile    -t starter-aggressive .
docker build -f policies/starters/cautious/Dockerfile      -t starter-cautious .
docker build -f policies/starters/collaborative/Dockerfile -t starter-collaborative .
```

Run as in the PoC README (`POC_HOST=host.docker.internal`, or `--network
host` on Linux). No model credentials are baked into any image.
