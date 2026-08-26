# Policy artifacts: addressing, auth, and the engine gate

How a policy on the platform maps to something our own server can actually
seat. Written for the lobby any-policy picker, which has to show *truthful*
availability rather than a hopeful list.

Tool: `tools/policyfetch/policyfetch.py`. Run it with the venv that holds the
login: `~/projects/coworld-players/coworld-cogherence-player/.venv/bin/python`.

---

## 1. The headline, before the details

**A policy version you own cannot be pulled to a local box through the platform
API today.** Entrant policy artifacts are private container images and the read
API deliberately exposes no address for them. The picker can *search* and
*describe* any owned policy version, but it can only *seat* artifacts that come
from a coworld package.

So the picker's availability column is not decoration — for most entrant
policies it is the answer. §5 has the exact reason strings.

---

## 2. What an artifact is

Every runnable on the platform — the engine, a bundled player, an entrant
policy — is a **linux/amd64 Docker image** plus a `run` argv. There is no
weights blob, no wasm, no source bundle: fetching an artifact means pulling an
image, and running one means starting a container.

A policy version's own record carries the entrypoint:

```
GET /stats/policy-versions/{policy_version_id}
  → { id, policy_id, name, version, created_at, tags: {},
      attributes: { kind: "docker-img", run: ["/bin/baseline"] },
      container_image_id }
```

`attributes.run` is the argv. `attributes.kind` is `docker-img` for every
policy we own.

---

## 3. Addressing — two classes, and only one of them is fetchable

### Class A — coworld-bundled runnables: PUBLIC, pullable, commit-attributed

`GET /v2/coworlds/{cow_id}` — **no auth required** — returns the manifest with
the internal image ids already resolved to public registry URIs:

```
manifest.game.runnable.image = public.ecr.aws/…/cogames@sha256:<digest>
manifest.player[0] = { id, image: public.ecr.aws/…@sha256:<digest>,
                       run: ["/bin/baseline"], env: {},
                       source_url: "…/tree/<40-hex-commit>/players/baseline" }
```

Three things matter here:

- **The image is digest-pinned and public** — plain `docker pull` works, no
  registry credentials at all.
- **`source_url` pins the exact build commit.** This is the only
  build-provenance the platform publishes anywhere, and it is what makes the
  engine gate exact rather than a guess (§4).
- Coworld versions are dense and immutable (`paintbot` alone has 128 versions,
  `ctf` 220), so a coworld version is effectively a pinned engine release.

Note the `list` endpoint is **paginated** (`limit`/`offset`, 200 max) — the same
trap as the league list. `tools/policyfetch` pages it.

Caveat: a few old coworlds set `source_url` to a *branch* ref (`…/tree/main`)
rather than a commit. That is unresolvable provenance and falls through to a
refusal, which is correct — see §4.

### Class B — entrant policy versions: PRIVATE, not fetchable

This is what the picker searches (`GET /stats/policy-versions?mine=true&…`,
`name_exact`, `version`, `limit`). Resolution works fine; retrieval does not:

- `container_image_id` **is on the response schema but comes back `null`** —
  measured across 200 owned policy versions, zero were populated.
- Even given an image id, `GET /v2/container_images/{id}` redacts the address:
  `image_uri: null` and `public_image_uri: null`. Across 521 visible image
  records, **134 had a public URI and every one of them was
  `is_coworld_image: true`**; no entrant policy image had either field set.
- The only endpoint that ever discloses a registry address is the *push* path
  (`POST /v2/container_images/upload` → `EcrPushInfo{registry, repository, tag,
  image_uri, authorization_token}`), which is write-scoped and creates state.

There is also **no build-provenance field** on a policy version — no commit, no
engine version, no coworld pin. So even if the image were pullable, its target
engine would still be unknown.

---

## 4. The engine gate — why this is the load-bearing part

**Our server and a policy artifact exchange no version handshake.** The wire
protocol carries no version field; the server never asks a connecting client
what it was built against, and the client never says. `GameVersion` is a
compile-time constant baked into each binary.

This was verified, not assumed. A `GameVersion 44` artifact pointed at our
`GameVersion 24` server connected cleanly:

```
container: connected ws://host.docker.internal:2000/player?slot=1&token=…
server   : player connected: player2
```

No error, no warning. It would have played a full match that looked completely
normal and meant nothing — the failure mode banked as *wrong-engine policies
produce garbage that looks like data*. Compatibility therefore **cannot** be
discovered at runtime; it has to be established from provenance before the
process starts.

### How the gate establishes a version

- **Ours**: parse `GameVersion` out of the working tree — `src/ctf/sim_types.nim`
  first, then `src/ctf/sim.nim`. The constant **moved between those files** in
  the sim split, so a single hard-coded path silently resolves nothing for one
  era of commits. Read the tree, not `HEAD`: the server binary is built from
  the tree, so an uncommitted bump counts.
- **Theirs**: take the commit from the artifact's `source_url` and read the
  same constant at that commit (`git cat-file -p <sha>:<file>`). Coworld builds
  pin PR-head commits that are often *not* ancestors of `main`, so a plain
  `git fetch` will not have them — fetch the single object by name
  (`git fetch origin <sha>`), which works.

### The verdicts

| code | runnable | when |
|---|---|---|
| `ok` | yes | versions match, established from a pinned commit |
| `engine_mismatch` | **no** | versions differ — names both numbers |
| `engine_unknown` | **no** | provenance could not be established |
| `engine_unknown_overridden` | yes | operator passed `--allow-unknown-engine` |
| `artifact_unavailable` | **no** | nothing to fetch (Class B, or a missing image) |
| `unresolvable` | **no** | the reference itself did not resolve |

Two deliberate choices:

- **Unknown provenance refuses.** Since a mismatch is invisible at runtime,
  "we could not tell" has to behave like "no". `--allow-unknown-engine` exists
  as an explicit operator override and is named in the refusal message.
- **Unavailability is reported before compatibility.** "We could run it if we
  could get it" is a different fact for the picker than "we have it and it is
  wrong".

---

## 5. What the picker consumes

```
policyfetch.py availability --json <ref> [<ref> …]
```

returns one row per reference:

```json
{
  "ref": "cw:cow_dc3b090b-…#baseline",
  "kind": "coworld_player",
  "name": "ctf/baseline", "version": "0.7.103",
  "runnable": true, "code": "ok",
  "reason": "artifact and server agree on GameVersion 24",
  "our_game_version": "24", "artifact_game_version": "24",
  "engine_evidence": "pinned build commit",
  "image": "public.ecr.aws/…@sha256:…", "run": ["/bin/baseline"],
  "source_commit": "e05c73134c3b0dc961cc7fbf7e89a7aa8e4ab1be"
}
```

`reason` is written to be shown to a person verbatim. For an entrant policy it
reads:

> the platform does not expose this policy version's container_image_id (the
> field is present on the schema but returns null), so the artifact has no
> resolvable pull address

Reference forms accepted everywhere: a bare `policy_version` UUID, `pv:<uuid>`,
`cw:<cow_id>[#player_id]`, `cow_…[#player_id]`, or
`coworld:<name>:<version>[#player_id]`.

---

## 6. Fetch, cache, seat

```
policyfetch.py engine                      # what GameVersion our server runs
policyfetch.py resolve  <ref>              # descriptor + provenance
policyfetch.py gate     <ref>              # verdict; exit 0 runnable, 2 refused
policyfetch.py fetch    <ref>              # gate, then pull + cache
policyfetch.py seat     <ref> --slot N     # gate, fetch, run on a slot
```

`fetch` pulls with an explicit `--platform linux/amd64` (so an arm64 box
emulates rather than quietly resolving a different manifest), tags it
`ctf-policycache/<key>:latest`, and writes the descriptor to
`~/.ctf/policy-cache/<key>/artifact.json` (override with `CTF_POLICY_CACHE`).
A second `fetch` is a cache hit unless `--force`. `fetch --skip-gate` caches
without asserting compatibility and **never seats** — it exists for
investigating an artifact you already know is incompatible.

Seating needs no adapter. Our seat protocol is one env var, so a fetched
container joins exactly the way our own bots do:

```
docker run --rm --platform linux/amd64 \
  -e COWORLD_PLAYER_WS_URL='ws://host.docker.internal:2000/player?slot=1&token=0xBADA55_1' \
  --add-host host.docker.internal:host-gateway \
  ctf-policycache/<key>:latest /bin/baseline
```

`--add-host …:host-gateway` is required, and the server must bind `0.0.0.0`
(not `127.0.0.1`) or the container cannot reach it.

### Running a local match

`tools/policyfetch/demo-config.json` is the stock `config.json` with
`minPlayers: 4` and `maxGames: 50` — the shipped values (16 and 1) make a small
match impossible and exit the server after a single game.

```
COGAME_HOST=0.0.0.0 COGAME_PORT=2000 \
COGAME_CONFIG_URI="file://$PWD/tools/policyfetch/demo-config.json" ./bin/ctf-server
```

Then seat the artifact on a slot, fill the rest with
`players/baseline/baseline.out`, and take a human seat at
`http://localhost:2000/client/player?slot=0&token=0xBADA55_0`.

⚠️ The server **exits** if the roster drops below `minPlayers` mid-cycle
("finite match roster dropped below minPlayers"). Closing the human tab kills
the match — keep it open, or spectate from a seat you are not using.

---

## 7. Consequences for the picker

1. **Availability must be shown per version, from `availability --json`.** Most
   owned policy versions will come back `artifact_unavailable`; presenting them
   as seatable would be a lie the user discovers at Start.
2. **The seatable set today is coworld-bundled players**, addressed by coworld
   id. Those are public, pinned, and gate cleanly.
3. **The engine gate is not optional and not advisory.** Because a mismatch
   produces a normal-looking match, a refusal must block seating rather than
   warn.
4. **Unblocking Class B needs a platform change**, not a client workaround: a
   read endpoint that discloses a pull address for an owned policy image (or a
   signed short-lived pull token), plus a build-provenance field so the gate has
   something to check. Until then the picker's promise is bounded, and it should
   say so in the UI rather than at Start.
