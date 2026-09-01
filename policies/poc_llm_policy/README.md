# `poc_llm_policy` — a proof-of-concept LLM policy image

A self-contained container that plays one Season 2 play seat end to end: it
carries a **playbook** of wasm play modules, connects to the game server over
the real play-seat WebSocket protocol, uploads the playbook over the wire, asks
an LLM for a lobby line and a ladder call, and sends both — then asks again
mid-match and re-calls.

The LLM is reached the way a deployed policy actually reaches one: through the
platform's per-pod **Bedrock sidecar**, with no model credentials in the image.
A direct OpenRouter path and a canned path stand behind it for local
development and CI.

This is explicitly a **proof of concept**, not a competitor. It plays badly. Its
value is that it proves an outsider-shaped client, written against the byte
layouts alone, can drive the protocol.

---

## What it proves

| Requirement | Evidence |
| --- | --- |
| A wasm playbook baked into the image | `build_playbook.sh` compiles `edge_ride` and `pact` from `play_sdk/reference/` with wasi-sdk 33 during the Docker build |
| Connect as a play seat over the real protocol | `ws://host:port/player?slot=N&token=T`, upgraded by the server's play-seat transport |
| Upload the playbook over the wire | 0xA0 ModuleUpload → `module_accepted` → `module_ready` with the server's own sha256 |
| An LLM chooses the chat line and the play call | one model call per decision, two decisions per run, over whichever backend the environment selects |
| It works on the hosted platform's LLM path | the Bedrock sidecar backend is the primary path, gated on `AWS_ENDPOINT_URL_BEDROCK_RUNTIME` |
| A mid-match re-call driven by a later model call | a second 0xA1 at a higher proposal id, accepted at epoch 2, with the standing ladder fed back to the model so the re-call is a revision |
| The production validator is the oracle | a deliberately bad call comes back `call_rejected` with `reason` and the offending JSON path |

## What it punts on

- **It does not play well.** The model sees a short text summary, not the game.
  There is no evaluation loop, no reaction to the 0xB1 view stream, and no
  attempt to win.
- **The sidecar path is unproven against a real pod.** It is written to the
  documented contract and exercised against a stub built to that same contract,
  which cannot catch a doc-versus-behaviour mismatch. Nothing here has run in a
  hosted tournament.
- **One seat.** A real policy image would drive all 32.
- **No reconnect handling.** The protocol's rebind, transcript replay, and
  generation-stamping rules (§4.3/§9.2) are read but not exercised.
- **The status-ack mark is used as a tick pump**, not as an honest
  acknowledgement high-water mark. It monotonically increases, which is legal,
  but a real client would ack the ordinals it has actually consumed.
- **`poc_shell_server.nim` is scaffolding, not product** — see the next section.

---

## The blocker this PoC uncovered

**The production server cannot answer a wire policy today.** `src/ctf/server.nim`
owns the entire receive half — the `/player` upgrade with the play-seat
transport limits, the leading-byte dispatch (`classifyPlaySeatMessage`,
`src/shell/dispatch.nim`), the bounded per-seat ingress queue with its id
floors and budgets (`src/shell/ingress.nim`), and the tick-boundary drain. All
of that works. What is missing is the two ends it hands off to:

1. **No consumer is ever registered.** `registerPlayModuleUploadConsumer`,
   `registerPlayCallConsumer`, `registerPlayStatusAckConsumer`, and
   `registerPlayLobbyChatConsumer` are defined at `src/ctf/server.nim:180-194`
   and called from nowhere in the tree. Every admitted 0xA0/0xA1/0xA2/0xA3 is
   therefore counted into `playProtocolRejected` and dropped.
2. **Nothing sends server→client.** `trySendPlaySocket`
   (`src/shell/transport.nim:26`) has no caller outside its own tests, so
   0xB0 PlayContext, 0xB1 PlayView, and 0xB2 LobbyChatBroadcast are never
   emitted by a running server.

The first-light demo (`tools/run_first_light.sh`) does not hit this, because it
never goes over the wire: `src/shell/episode.nim`'s
`configureFirstLightPlay` reads a `.wasm` off local disk and calls
`compilePlane.admitModule` / `ladder.acceptCall` **in process**, from a config
file. That is a real exercise of the compile and call path, but it is not the
protocol.

`poc_shell_server.nim` supplies exactly the missing glue and nothing else: it
registers the four consumers, encodes the replies with the **production**
`packets.nim` codec, and then hands off to the stock `runServerLoop`. It is a
PoC stand-in for a lane that has not landed, deliberately kept inside this
directory. Its own limits are listed in its file header.

### Update, after `78e05b06` ("a live admission seam on the episode")

Main has since added the seam this PoC should eventually sit on:
`admitPlayModule` and `acceptPlayCall` (`src/shell/episode.nim:468,491`) plus
`FirstLightTickResult.moduleStatuses` (`:85`) give a consumer the episode's
*own* compile plane and ladder, non-blocking, with accepted calls actually
stepped into seat bodies. That commit's message calls out standing up parallel
plane and ladder instances as the shortcut lane B declined to copy — and
standing up parallel instances is exactly what this PoC does.

Two things are still true, so the PoC's shape has not changed yet:

* **The consumers remain unregistered in production.** After the merge the only
  callers of `registerPlay*Consumer` in the tree are in
  `tests/test_shell_dispatch.nim:72-75`. `trySendPlaySocket` still has no
  production caller.
* **The new seam is not reachable from where a consumer runs.** The live
  episode is a local `var` inside `runServerLoop` (`src/ctf/server.nim:3068`)
  with no exported accessor, and a registered consumer is a module-level
  `gcsafe` proc. Lane B can wire this because it is working *inside*
  `server.nim`, where the episode is in scope; an out-of-tree PoC cannot reach
  it at all.

So the PoC keeps its parallel plane and ladder, and its calls still do not
drive seat bodies — but that is now a consequence of a missing accessor, not of
a missing seam. **Migrating `poc_shell_server.nim` onto `admitPlayModule` /
`acceptPlayCall` is the right follow-up the moment `server.nim` exposes the
live episode** (or the moment lane B's own registration lands, at which point
this file should simply be deleted).

---

## Layout

```
poc_llm_policy/
  wire.py              packet codec + canonical JSON, from the byte layouts alone
  brain.py             the three model backends: Bedrock sidecar, OpenRouter, canned
  poc_policy.py        the harness: connect, upload, chat, call, re-call
  build_playbook.sh    compiles edge_ride.wasm and pact.wasm from play_sdk
  poc_shell_server.nim the gate-on server plus the unregistered wire consumers
  run_poc.sh           the end-to-end local proof (server + harness)
  Dockerfile           the image, playbook baked in
```

---

## Run it

### End to end, locally

```bash
policies/poc_llm_policy/run_poc.sh          # canned model response
policies/poc_llm_policy/run_poc.sh --live   # one real OpenRouter call per decision
```

This fetches the wasm/wasi toolchain, builds the playbook, builds the gate-on
server, starts it on `POC_PORT` (default 21815) with a config derived from
`config.practice.json` (`season2Shell: true`, every slot switched to
`control: "play"`), and runs the harness against slot 0. It prints the harness
log and then the server's own `POC_WIRE_*` lines.

The harness needs `websockets`; `run_poc.sh` prefers
`policies/poc_llm_policy/.venv/bin/python` if you have made one:

```bash
python3 -m venv policies/poc_llm_policy/.venv
policies/poc_llm_policy/.venv/bin/pip install "websockets>=13"
```

### The image

Build from the **repository root** — the playbook is compiled from `play_sdk/`
during the build:

```bash
docker build -f policies/poc_llm_policy/Dockerfile -t poc-llm-policy .

# Offline / CI: no model credentials of any kind.
docker run --rm \
  -e POC_HOST=host.docker.internal -e POC_PORT=21815 \
  -e POC_SLOT=0 -e POC_TOKEN=0xBADA55_0 \
  poc-llm-policy --canned

# Local dev against a real model, with your own key.
docker run --rm \
  -e POC_HOST=host.docker.internal -e POC_PORT=21815 \
  -e POC_SLOT=0 -e POC_TOKEN=0xBADA55_0 \
  -e OPENROUTER_API_KEY="$OPENROUTER_API_KEY" \
  poc-llm-policy
```

**In a hosted tournament you pass no key at all.** The platform injects the
sidecar environment into the pod, the harness detects
`AWS_ENDPOINT_URL_BEDROCK_RUNTIME` and takes the Bedrock path automatically, and
the image itself carries no credentials. That is the whole point of the backend
order — see "The model backends" below. Upload with
`--use-bedrock --bedrock-model <id>`.

The server has to be reachable from inside the container: start it with
`COGAME_HOST=0.0.0.0` and use `host.docker.internal` (Docker Desktop) or
`--network host` with `POC_HOST=127.0.0.1` (Linux). `run_poc.sh` binds the
server to loopback, so for a container run start the server yourself.

### Environment

| Variable | Set by | Meaning |
| --- | --- | --- |
| `AWS_ENDPOINT_URL_BEDROCK_RUNTIME` | the platform, in a hosted pod | **presence selects the production backend.** Never hardcode it |
| `BEDROCK_MODEL` | `--bedrock-model` at upload | the model id the sidecar backend calls; required when the endpoint is set |
| `OPENROUTER_API_KEY` | you, for local dev | selects the OpenRouter backend when no sidecar is present |
| `POC_MODEL` | you | OpenRouter model id (default `qwen/qwen3-30b-a3b-instruct-2507`); ignored on the sidecar path |
| `POC_CANNED` | you | `1` (or `--canned`) forces the fixed response, overriding both |
| `POC_HOST` / `POC_PORT` | you | the game server (default `127.0.0.1` / `21815`) |
| `POC_SLOT` / `POC_TOKEN` | you | the play seat and its configured token |
| `POC_PLAYBOOK` | the image | directory of `.wasm` modules to upload |
| `POC_RECALL_SECONDS` | you | how long to hold before the mid-match re-call (default 6) |

The platform also injects `AWS_REGION`, `AWS_DEFAULT_REGION`, and deliberately
fake `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_BEARER_TOKEN_BEDROCK`
placeholders. This harness ignores all of them — it sends no `Authorization`
header at all, because the sidecar strips whatever the client sends and
re-signs with the real pod identity. All six are reserved: the platform strips
them from an uploaded secret-env and re-applies its own.

### The model backends

Selected in this order, production first (`brain.py`, `build_brain`):

**1. The hosted Bedrock sidecar — the production path.** A deployed policy image
does *not* call OpenRouter. The Softmax platform runs a per-pod sidecar on
loopback that holds the real AWS identity and signs calls on the policy's
behalf, so the container ships no model credentials. The contract, verified
against metta at commit `9e780b9ff7`:

- `AWS_ENDPOINT_URL_BEDROCK_RUNTIME` (e.g. `http://127.0.0.1:9100`) is the
  signal that hosted Bedrock is available. Gate on **this**, not on
  `USE_BEDROCK`, which is also set for direct local AWS access with no sidecar
  (`packages/coworld/src/coworld/docs/BEDROCK.md`, "Detecting that you're
  behind the sidecar").
- `BEDROCK_MODEL` carries the model id from `--bedrock-model` at upload. It must
  be read, never hardcoded. If the endpoint is set and this is not, the harness
  **refuses loudly** rather than falling back — a silent fallback here is the
  documented way to score zero completed episodes without noticing.
- The call is a Bedrock Runtime `InvokeModel`:
  `POST $AWS_ENDPOINT_URL_BEDROCK_RUNTIME/model/$BEDROCK_MODEL/invoke` with an
  Anthropic Messages body (`"anthropic_version": "bedrock-2023-05-31"`) and
  **no `Authorization` header**. No AWS SDK is needed; `urllib` is enough.
- `requestMetadata` is deliberately never set — the sidecar overwrites it with
  trusted attribution.
- Calls are rate limited (30/minute per player slot by default). A 429 arrives
  as a Bedrock `ThrottlingException` carrying `Retry-After` / `Retry-After-Ms`,
  which the backend honours once before giving up.
- Every call is bounded by a timeout, because a slow call times the whole
  episode out and scores as a loss.

To deploy: `coworld upload-policy ... --use-bedrock --bedrock-model <id>`.
Without `--use-bedrock` the pod gets no sidecar and this backend never engages.

There is **no JSON mode** on this path. The Anthropic Messages body has no
`response_format`, so JSON is forced by prefilling the assistant turn with `{`
and prepending it back onto the reply. That is a real difference from the
OpenRouter path, not a detail.

> The sidecar also exposes `/v1/chat/completions` and `/v1/messages`. **Do not
> build against them.** They return HTTP 503 `"OpenRouter is not configured"`
> unless a backend-side key is set, which is gated behind a chart flag that is
> off (`coworldOpenRouterRouting.enabled: false`), and they are undocumented for
> players. The design intent is that Bedrock-speaking images keep working
> unchanged while OpenRouter is swapped in *behind* the sidecar.

**2. Direct OpenRouter — local development only.** Selected when
`OPENROUTER_API_KEY` is set and no sidecar endpoint is present. Uses
`qwen/qwen3-30b-a3b-instruct-2507` (open weights, ~$0.05 per million prompt
tokens) with `response_format: {"type": "json_object"}`. Convenient for
iterating locally; it is not how the image runs in a tournament.

**3. Canned.** A fixed response, so the image is testable offline and in CI.
Forced by `--canned`, and the fallback when neither of the above is configured.

### What the model is asked, and how far it is trusted

Each backend gets the same system prompt — the two plays and their parameter
ranges, transcribed from the reference manifests — plus a short match summary,
and returns `{"chat": ..., "call": {"entries": [...]}}`. The mid-match summary
also carries **the ladder currently in force**, so the second call is a revision
rather than a fresh decision. Without that, a model handed the same map facts
twice simply repeats itself, which is exactly what the first live run did.

The model is never trusted. `build_call` in `poc_policy.py` drops unknown plays
and parameters, clamps numbers into their manifest ranges, coerces
integer-typed parameters to JSON integers, rewrites `partners` into sorted
unique `seat:N` references, enforces `MaxActiveOverlays`, and falls back to a
bare `edge_ride` entry if nothing survives. Whatever it produces still has to
pass the server's validator.

---

## Where the docs and schemas were not enough

The point of writing the harness in Python was to find out what a real policy
author hits. The headline is not that the protocol is undocumented — it is
documented thoroughly. `docs/designs/strategy-play-calling-shell-2026-08-29.md`
carries a complete normative packet table (§4.3, its lines 487-509), the
per-tick admission budgets, the id-floor rule, the canonical encoding rules,
and the parameter kinds. Almost everything below is a *findability* problem or
a gap between what the spec says and what the validator checks.

1. **There is no client-facing protocol reference.** The file named
   `docs/PROTOCOL.md` is Sprite v1 and never mentions a Season 2 packet. The
   normative table lives 490 lines into a 3,501-line design document that also
   carries lane assignments, budget tables, and implementation planning. An
   outside policy author opening the obviously-named document learns nothing,
   and the document that would tell them is not written for them. This is the
   single highest-leverage thing to fix.

2. **The join handshake is documented only in passing.** That a play seat
   connects to `/player?slot=N&token=T` with the token from
   `config["tokens"][slot]` appears in a recon note
   (`docs/recon/paintbot-s2-policy-shell-2026-08-29.md:631`) and in the
   paintball design's file inventory, but nowhere in the Season 2 material.
   In practice I read it out of `tools/run_first_light.sh`.

3. **Nothing warns that a play socket also carries the legacy Sprite stream.**
   The design doc explains the *inbound* leading-byte split (§4.3's Sprite
   row) but says nothing about the outbound direction. A client that treats
   every binary message it receives as a shell packet fails immediately; a
   conforming one must ignore unknown leading bytes. That rule is only visible
   by running against a real server.

4. **Exceeding a per-tick admission budget is silent.** The budgets are
   documented (1 upload, 2 calls per seat per tick). What is not documented is
   that going over them produces no status entry — the drop is a counter in
   `control_view.counters`. A client that uploads its whole playbook back to
   back loses everything after the first module and is told nothing.

5. **The status `kind` strings are not in the docs at all.** `module_accepted`,
   `module_ready`, `call_accepted`, `call_rejected`, `play_faulted`,
   `retune_refused` — the literal wire values a client switches on — appear
   zero times in the design document. They are in
   `status_entry.schema.json` and, much more usefully, in the eight goldens
   under `tests/fixtures/shell/status_*.golden.json`. Those goldens are
   excellent and answered every question I had; nothing links to them from
   anywhere a policy author would look.

6. **Most of the refusal vocabulary is undocumented.** `nameBound` is in the
   design doc; `playUnknown`, `unknownParam`, `unknownReference`,
   `duplicateEntryId`, `notSorted`, `range` are not. They are defined only by
   the `invalid(...)` call sites in `src/shell/call_validation.nim`. The
   messages themselves are genuinely good — `playUnknown:call.plays[0].play`
   told me exactly what was wrong — but you have to read the validator to know
   the vocabulary exists, and a client cannot branch on values it has never
   seen listed.

7. **`duo:<team>` needs a server-side *configured* duo, and the doc's own
   example does not survive that.** §4.3 says `duo:` references are valid in
   BR mode, and both the worked example (design doc line 2082) and
   `ladder_call.golden.json` use `duo:navy`. But
   `validateSeatOrDuoRef` also requires `ctx.duoSeats[team].configured`, so
   copying the documented example into a call can come back
   `unknownReference`. `seat:N` is the form that always works. The PoC's
   sanitizer rewrites `duo:` refs away for exactly this reason.

8. **`"set"` params sort by their canonical *encoded* form.** The doc says
   sets are "sorted and deduplicated"; only `validateSortedUnique` shows the
   comparison is on encoded strings, so `partners` sorts as
   `["seat:10", "seat:2"]` rather than numerically. That is the kind of detail
   that turns into a `notSorted` refusal on a call that looks obviously right.

9. **`"integer": true` params must be JSON integers, not integral floats.**
   The doc states the spec flag; `call_validation.nim` is where you learn the
   check is on the JSON *kind* (`jkInt`). In Python that means a value must
   never round-trip through `float`, and getting it wrong yields
   `range:...must be integral` — a message that reads like a bounds error.

10. **The schemas do not carry canonicality.** `ladder_call.schema.json` says
    nothing about key order or number grammar, and puts `MaxCallBytes` in a
    `$comment`. An author who validates against the schema alone produces
    bytes the server refuses. The canonical grammar is only in
    `src/shell/canonical.nim` (which is an excellent reference implementation)
    and in the design doc's Appendix P. Worth a `$comment` on the schema
    pointing at both.

11. **`ladder_call.golden.json` has no integral float.** It shows `0.8` and
    `0.4`, so the rule that an integral float keeps its `.0` — the single
    easiest canonical-encoding mistake to make — has no specimen. One more
    golden with a `1.0` in it would close that.

12. **Nothing tells you the server will not answer.** The largest cost in this
    exercise was not any of the above: it was discovering, by reading
    `src/ctf/server.nim` far enough to find that the consumers are never
    registered, that a correct client gets silence. The failure mode is a
    counter, not a status or a close, so from the client side it is
    indistinguishable from a bug in your own bytes.

### On the platform side, by contrast

The hosted-LLM contract is documented *well*.
`packages/coworld/src/coworld/docs/BEDROCK.md` in metta is what a client-facing
protocol reference looks like: one rule in a callout at the top, a table of
every env var with what you do with it, working snippets for three SDKs plus
hand-rolled HTTP, and a troubleshooting table keyed by symptom that names the
three mistakes which produce zero completed episodes. Writing the sidecar
backend took a fraction of the time the game protocol did, and the difference
is entirely the documentation.

Two traps survive it:

* **`/v1/chat/completions` and `/v1/messages` exist on the sidecar and look
  like the obvious modern choice.** They return HTTP 503 `"OpenRouter is not
  configured"` in production, they are undocumented for players, and nothing at
  the route itself says so. An author who reaches for the OpenAI-shaped
  endpoint gets a 503 with no hint that the Bedrock path is the supported one.
* **`PLAYER.md` and `BEDROCK.md` disagree.** `PLAYER.md` says to use
  `InvokeModel` "not `Converse`"; `BEDROCK.md` and the sidecar's own route
  table both list `Converse` and `ConverseStream` as supported. The code
  supports them. This harness uses `InvokeModel` anyway, as the stricter of the
  two.

What was more than sufficient: `src/shell/packets.nim` reads as a
specification — the length equations and the four rejection kinds are
unambiguous, and the Python codec was a direct transcription with no guessing.
`src/shell/canonical.nim` is the same. And the golden fixtures under
`tests/fixtures/shell/` answer nearly every "what do the bytes actually look
like" question, once you know they are there.

## Recorded runs

### Live, against a real model (OpenRouter dev path)

`qwen/qwen3-30b-a3b-instruct-2507`, two real completions, local gate-on server,
slot 0. The model picked the partner seat out of the `play_context` it was
given, and the mid-match turn revised the standing ladder rather than repeating
it — `edge_ride` `margin` 240 → 200 as the zone closes, `pact` left alone:

```
model backend: qwen/qwen3-30b-a3b-instruct-2507 (OpenRouter model ... (dev path))

turn 1 -> {"call": {"entries": [
             {"entry_id": "ride", "params": {"margin": 240}, "play": "edge_ride"},
             {"entry_id": "ally", "params": {"onBetrayal": "disengage",
                "partners": ["seat:1"], "protect": true}, "play": "pact"}]},
           "chat": "Edge ride with my bro seat 1 - don't get greedy, we're
                    riding the zone together."}
0xB2 chat: seat=0 ordinal=1  (em dash and curly apostrophe round-trip intact)
0xA1 opening call ACCEPTED: epoch=1 proposal_id=1 tick=7

turn 2 -> {"call": {"entries": [
             {"entry_id": "ride", "params": {"margin": 200}, "play": "edge_ride"},
             {"entry_id": "ally", "params": {"onBetrayal": "disengage",
                "partners": ["seat:1"], "protect": true}, "play": "pact"}]},
           "chat": "Edge tight, cover close-stay sharp with seat 1."}
0xB2 chat: seat=0 ordinal=2
0xA1 mid-match re-call ACCEPTED: epoch=2 proposal_id=2 tick=20

real model calls: 2 | statuses received: 6 | chat broadcasts received: 2
all PoC steps passed
```

The chat lines are worth noting on their own: the model emits em dashes and
curly apostrophes, and they survive the 0xA3 → 0xB2 round trip byte-exactly,
which exercises the UTF-8 measured-in-bytes cap on that packet.

### The Bedrock sidecar backend

Exercised against a local stub implementing the documented `InvokeModel`
contract (`GET /healthz/core-v1`, `POST /model/{id}/invoke`) and translating to
an upstream model — which is what the real sidecar does internally when
OpenRouter routing is enabled:

```
model backend: bedrock-sidecar us.anthropic.claude-haiku-4-5-20251001-v1:0
               (hosted Bedrock sidecar at http://127.0.0.1:9137
                (BEDROCK_MODEL=us.anthropic.claude-haiku-4-5-20251001-v1:0))

[stub] InvokeModel path=/model/us.anthropic.claude-haiku-4-5-20251001-v1:0/invoke
       auth=False  anthropic_version=bedrock-2023-05-31

opening call ACCEPTED: epoch=1 proposal_id=1 tick=7
mid-match re-call ACCEPTED: epoch=2 proposal_id=2 tick=20   (margin 240 -> 180)
real model calls: 2
```

`auth=False` is the contract being honoured: the harness sends no
`Authorization` header, because the sidecar supplies the real one.

**This has not been run against a real hosted sidecar** — only against a stub
built to the documented contract. The remaining risk is that the documentation
and the sidecar's actual behaviour differ somewhere this stub reproduces
faithfully by construction.

Backend selection, all five branches:

```
sidecar + OPENROUTER_API_KEY     -> bedrock-sidecar (hosted wins)
sidecar, no BEDROCK_MODEL        -> BrainError, refuses loudly
OPENROUTER_API_KEY only          -> qwen/... (dev path)
neither                          -> canned
--canned                         -> canned (overrides everything)
```

### Canned, offline

The same sequence with a fixed response, which is what CI runs:

```
0xB0 play_context: {"gun_range":497,"map":{"height":1713,"name":"br-gen-4242","width":3211},
                    "mode":"br","roster":[...32 rows...],"schema":"play_context",
                    "self":{"duo_partner":1,"seat":0,"team":"red"},"v":1,"view_interval":6}
0xB1 status: {"gen":"1","kind":"module_accepted","ordinal":"1","upload_id":"1"}
0xB1 status: {"gen":"1","kind":"module_ready","name":"edge_ride","ordinal":"2",
              "sha256":"399962bc1aa1e2c5b9e218e72d61b5154b502244e473c55a50a1710aa49d9c38",
              "upload_id":"1"}
0xB1 status: {"gen":"1","kind":"module_ready","name":"pact","ordinal":"4",
              "sha256":"cf092e1af573da829bc9805fcdfeaef662f40fa5bd35e5b45b6793ab1addf3ec",
              "upload_id":"2"}
0xB1 status: {"epoch":"1","gen":"1","kind":"call_accepted","ordinal":"1",
              "proposal_id":"1","tick":7}
0xB1 status: {"epoch":"2","gen":"1","kind":"call_accepted","ordinal":"2",
              "proposal_id":"2","tick":20}
```

And the negative probe, confirming the production validator is doing the work:

```
sending: {"plays":[{"entry_id":"bad","params":{"margin":9999},"play":"edge_ride"}]}
STATUS   {"gen":"1","kind":"call_rejected","ordinal":"1","proposal_id":"1",
          "reason":"playUnknown:call.plays[0].play"}
```

(The seat in that probe never uploaded `edge_ride`, so the play name is
unbound — the validator refuses the name before it ever reaches the out-of-range
`margin`.)

The same canned run out of the container, against the same server on slot 5,
also reaches `call_accepted` at epoch 2 with the image-built playbook — whose
`pact` hash (`7a4d2772…`) differs from a host build's, since the wasm carries
build-path detail. `edge_ride` happens to match (`399962bc…`).
