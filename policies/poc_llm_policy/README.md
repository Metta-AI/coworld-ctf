# `poc_llm_policy` — a proof-of-concept LLM policy image

A self-contained container that plays one Season 2 play seat end to end: it
carries a **playbook** of wasm play modules, connects to the game server over
the real play-seat WebSocket protocol, uploads the playbook over the wire, asks
a small open-weights model for a lobby line and a ladder call, and sends both —
then asks the model again mid-match and re-calls.

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
| An LLM chooses the chat line and the play call | one JSON-mode OpenRouter completion per decision, two decisions per run |
| A mid-match re-call driven by a later model call | a second 0xA1 at a higher proposal id, accepted at epoch 2 |
| The production validator is the oracle | a deliberately bad call comes back `call_rejected` with `reason` and the offending JSON path |

## What it punts on

- **It does not play well.** The model sees a seven-line text summary, not the
  game. There is no evaluation loop, no reaction to the 0xB1 view stream, and no
  attempt to win.
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
registers the four consumers over the **production** compile plane, module
cache, ladder, and call validator, encodes the replies with the **production**
`packets.nim` codec, and then hands off to the stock `runServerLoop`. It is a
PoC stand-in for a lane that has not landed, deliberately kept inside this
directory. Its own limits are listed in its file header — most importantly, an
accepted call is validated and epoch-advanced but is **not** stepped into the
seat's body.

---

## Layout

```
poc_llm_policy/
  wire.py              packet codec + canonical JSON, from the byte layouts alone
  brain.py             OpenRouter (JSON mode) and canned model backends
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
docker run --rm \
  -e POC_HOST=host.docker.internal -e POC_PORT=21815 \
  -e POC_SLOT=0 -e POC_TOKEN=0xBADA55_0 \
  -e OPENROUTER_API_KEY="$OPENROUTER_API_KEY" \
  poc-llm-policy
```

Add `--canned` after the image name (or `-e POC_CANNED=1`) to run without a key.

The server has to be reachable from inside the container: start it with
`COGAME_HOST=0.0.0.0` and use `host.docker.internal` (Docker Desktop) or
`--network host` with `POC_HOST=127.0.0.1` (Linux). `run_poc.sh` binds the
server to loopback, so for a container run start the server yourself.

### Environment

| Variable | Default | Meaning |
| --- | --- | --- |
| `POC_HOST` / `POC_PORT` | `127.0.0.1` / `21815` | the game server |
| `POC_SLOT` / `POC_TOKEN` | `0` / empty | the play seat and its configured token |
| `POC_PLAYBOOK` | `playbook` | directory of `.wasm` modules to upload |
| `POC_MODEL` | `qwen/qwen3-30b-a3b-instruct-2507` | any OpenRouter model id |
| `POC_CANNED` | unset | `1` substitutes a fixed model response |
| `POC_RECALL_SECONDS` | `6` | how long to hold before the mid-match re-call |
| `OPENROUTER_API_KEY` | unset | absent ⇒ the harness falls back to canned |

### The model

`qwen/qwen3-30b-a3b-instruct-2507`, chosen for being open weights, cheap
(~$0.05 per million prompt tokens), and reliable under
`response_format: {"type": "json_object"}`. It gets a system prompt describing
the two plays and their parameter ranges — transcribed from the reference
manifests — plus a seven-line match summary, and returns
`{"chat": ..., "call": {"entries": [...]}}`.

The model is never trusted. `build_call` in `poc_policy.py` drops unknown
plays and parameters, clamps numbers into their manifest ranges, coerces
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

What was more than sufficient: `src/shell/packets.nim` reads as a
specification — the length equations and the four rejection kinds are
unambiguous, and the Python codec was a direct transcription with no guessing.
`src/shell/canonical.nim` is the same. And the golden fixtures under
`tests/fixtures/shell/` answer nearly every "what do the bytes actually look
like" question, once you know they are there.

## Recorded run

Canned mode, against the local gate-on server, slot 0:

```
0xB0 play_context: {"gun_range":497,"map":{"height":1713,"name":"br-gen-4242","width":3211},
                    "mode":"br","roster":[...32 rows...],"schema":"play_context",
                    "self":{"duo_partner":1,"seat":0,"team":"red"},"v":1,"view_interval":6}
0xB2 chat: seat=0 ordinal=1 text='edge_ride from the off. See you at the last circle.'
0xB1 status: {"gen":"1","kind":"module_accepted","ordinal":"1","upload_id":"1"}
0xB1 status: {"gen":"1","kind":"module_ready","name":"edge_ride","ordinal":"2",
              "sha256":"399962bc1aa1e2c5b9e218e72d61b5154b502244e473c55a50a1710aa49d9c38",
              "upload_id":"1"}
0xB1 status: {"gen":"1","kind":"module_ready","name":"pact","ordinal":"4",
              "sha256":"cf092e1af573da829bc9805fcdfeaef662f40fa5bd35e5b45b6793ab1addf3ec",
              "upload_id":"2"}
0xA1 opening call: {"plays":[{"entry_id":"ride","params":{"coverBias":0.8,"margin":240},
                              "play":"edge_ride"}]}
0xB1 status: {"epoch":"1","gen":"1","kind":"call_accepted","ordinal":"1",
              "proposal_id":"1","tick":7}
0xB2 chat: seat=0 ordinal=2 text='Zone is tightening -- pulling in and taking a partner.'
0xA1 mid-match re-call: {"plays":[{"entry_id":"truce","params":{"partners":["seat:3"],
                                    "protect":true},"play":"pact"},
                                  {"entry_id":"ride","params":{"coverBias":0.95,
                                    "enterLead":200,"margin":140},"play":"edge_ride"}]}
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

The same run out of the container, against the same server on slot 5, reaches
`call_accepted` at epoch 2 with the image-built playbook — whose `pact` hash
(`7a4d2772…`) differs from a host build's, since the wasm carries build-path
detail. `edge_ride` happens to match (`399962bc…`).
