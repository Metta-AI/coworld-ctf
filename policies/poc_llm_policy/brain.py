"""The LLM half of the PoC: turn a short match summary into a chat line and a
ladder call.

Backends, all returning the same dict shape::

    {"chat": "<one lobby line>",
     "call": {"entries": [{"play": ..., "entry_id": ..., "params": {...}}, ...]}}

Selected in this order:

1. **The hosted sidecar (production).** A deployed policy pod gets no model
   credentials of its own. The platform runs a per-pod proxy on loopback that
   holds the real identity, and it speaks **OpenAI-compatible chat
   completions**, served by OpenRouter. Selected when
   ``AWS_ENDPOINT_URL_BEDROCK_RUNTIME`` is present.
2. **Direct OpenRouter (dev/local).** Selected when ``OPENROUTER_API_KEY`` is
   set and no sidecar endpoint is present.
3. **Canned.** A fixed response, so the image is testable offline and in CI.
   Forced by ``--canned``.

The happy consequence of (1) and (2) speaking the same protocol: they are the
*same client class* with a different URL and a different auth header. Only the
opt-in Bedrock fallback below needs its own code path.

Live backends are wrapped in :class:`ResilientBrain`: the first completions
failure of any kind (the sidecar's model-allowlist 403 first among them) is
logged once and the policy degrades to canned decisions instead of dying. A
policy that cannot reach its LLM plays dumb; it never exits 1 over it.

Everything uses ``urllib`` from the standard library, so the image needs no HTTP
or cloud SDK dependency.

The model is never trusted: :mod:`poc_policy` re-validates and repairs whatever
comes back before any of it reaches the wire, and the server's call validator is
the final oracle.
"""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request

# ── The hosted-platform contract ──────────────────────────────────────────
# Verified against the metta checkout at commit 9e780b9ff7, plus a read of
# production (`coworld leagues`) on 2026-08-31.
#
# ROUTING IS OPENROUTER, GLOBALLY. devops/app-manifests/values.yaml sets
# `coworldOpenRouterRouting.enabled: true` with `episodePercent: 100` (a
# James-authorized ramp to 100% on 2026-08-29 01:08Z, with the full ramp log in
# that file's comments). Assignment is a deterministic per-episode hash gated by
# that percent, so at 100% every new episode is routed to OpenRouter. It is NOT
# a per-league setting: `LeagueSettings`
# (app_backend/src/metta/app_backend/v2/league_settings_schema.py:158) has no
# routing field, and the only per-league LLM knob is
# `settings.llm.player_model_allowlist` (:139-146).
#
# The chart default in devops/charts/observatory-backend/values.yaml says
# `enabled: false, episodePercent: 0`. That is the UNCONFIGURED default, marked
# "Keep disabled with zero percent until a separately reviewed rollout" — it is
# not what production runs. Reading it as production is a mistake this file
# previously made.
SIDECAR_ENDPOINT_ENV = "AWS_ENDPOINT_URL_BEDROCK_RUNTIME"
"""Presence of this is THE signal that the hosted LLM proxy is available.

The name is historical -- the sidecar began as a Bedrock proxy and kept the env
var when OpenRouter routing became the serving path -- so do not read it as
"Bedrock only". Gate on this rather than ``USE_BEDROCK``, which is also set for
direct local AWS access with no sidecar in front of it.
"""

SIDECAR_MODEL_ENV = "BEDROCK_MODEL"
"""Set from the ``--bedrock-model`` upload flag. Must be read, never hardcoded.

The sidecar resolves whatever string arrives through its legacy-id alias table
to a canonical OpenRouter slug, then checks it against the model allowlist
(``resolve_model``,
app_backend/src/metta/app_backend/job_runner/llm_sidecar.py:260-268), so both a
legacy Bedrock id and a canonical ``vendor/model`` slug are accepted.
"""

SIDECAR_PROTOCOL_ENV = "POC_LLM_PROTOCOL"
"""Escape hatch: set to ``bedrock`` to use the legacy InvokeModel path instead."""

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"

ANTHROPIC_BEDROCK_VERSION = "bedrock-2023-05-31"

DEFAULT_MODEL = "qwen/qwen3-30b-a3b-instruct-2507"
"""The last-resort default: a cheap, capable open-weights model with JSON mode.

The platform-injected ``BEDROCK_MODEL`` always wins when present; this is used
on the direct-OpenRouter dev path and as the sidecar-path fallback when nothing
was injected. NOTE it is not necessarily on the platform's allowlist (which
carries `anthropic/claude-haiku-4.5` and `anthropic/claude-sonnet-4.5`, among
others) -- a hosted pod that ends up asking for it may be refused with a 403
``model_not_allowed``, which :class:`ResilientBrain` turns into degraded canned
play rather than a dead pod.
"""


PLAYBOOK_BRIEF = """\
Your playbook has exactly two plays, both already uploaded to the server.

1. "edge_ride" (class: controller). Rides safe-zone edges early and biases
   toward nearby cover. Params:
     - margin: integer 40..600, default 220. Distance inside the zone edge to
       sit at. Smaller = more aggressive edge play.
     - enterLead: integer 0..600, default 120. How early to start rotating
       before the zone shrinks.
     - coverBias: number 0.0..1.0, default 0.8. Higher = detour further for
       cover.

2. "pact" (class: overlay). A negotiated alliance: never target the partners,
   dissolve at an agreed endgame. Params:
     - partners: REQUIRED list of 1..8 seat references, each of the exact form
       "seat:<N>" with N from 0 to 31. No other form is legal.
     - protect: boolean, default false. Also body-block for partners.
     - onBetrayal: one of "returnFire" or "disengage", default "returnFire".

A ladder is an ordered list of entries; the first non-overlay entry is the
controller that drives the seat, and overlays modify it. At most 2 overlays.
"""

SYSTEM_PROMPT = """\
You are a policy calling plays for one seat in a battle-royale match.

""" + PLAYBOOK_BRIEF + """
Reply with a single JSON object and nothing else:

{
  "chat": "one short line of lobby trash talk or a callout, under 200 characters",
  "call": {
    "entries": [
      {"play": "edge_ride", "entry_id": "ride", "params": {"margin": 240}}
    ]
  }
}

Rules: every "play" must be "edge_ride" or "pact". Every "entry_id" must be
unique within the call and made of letters, digits, underscores or hyphens.
Only use parameters named above, within their stated ranges. Include at least
one entry.
"""


class BrainError(Exception):
    """The model call failed, or returned something unusable."""


class CannedBrain:
    """A fixed response standing in for the model.

    The two turns differ so the mid-match re-call is a genuinely different
    ladder, which is what the PoC has to demonstrate.
    """

    name = "canned"

    def __init__(self) -> None:
        self.turn = 0

    def decide(self, summary: str) -> dict:
        self.turn += 1
        if self.turn == 1:
            return {
                "chat": "edge_ride from the off. See you at the last circle.",
                "call": {
                    "entries": [
                        {
                            "play": "edge_ride",
                            "entry_id": "ride",
                            "params": {"margin": 240, "coverBias": 0.8},
                        }
                    ]
                },
            }
        return {
            "chat": "Zone is tightening -- pulling in and taking a partner.",
            "call": {
                "entries": [
                    {
                        "play": "pact",
                        "entry_id": "truce",
                        "params": {
                            "partners": ["seat:3"],
                            "protect": True,
                        },
                    },
                    {
                        "play": "edge_ride",
                        "entry_id": "ride",
                        "params": {"margin": 140, "enterLead": 200,
                                   "coverBias": 0.95},
                    },
                ]
            },
        }


class OpenAiChatBrain:
    """One JSON-mode chat completion, OpenAI-compatible.

    This single class serves BOTH the production and dev paths, because they
    speak the same protocol:

    * hosted -- ``POST $AWS_ENDPOINT_URL_BEDROCK_RUNTIME/v1/chat/completions``
      with **no** ``Authorization`` header. The sidecar holds the real
      credential and attributes the call to this pod's own player slot.
    * dev    -- ``POST https://openrouter.ai/api/v1/chat/completions`` with your
      own bearer key.

    Notes on the hosted path specifically:

    * ``X-Coworld-Player-Slot`` is deliberately NOT sent. On a player pod the
      sidecar defaults attribution to that pod's own slot, and a value that
      disagrees with it is rejected outright
      (``_resolve_request_attribution``, bedrock_sidecar.py:1387-1404). Sending
      nothing is both correct and safer.
    * Calls are rate limited per player slot. A 429 carries
      ``Retry-After`` / ``Retry-After-Ms``, which this honours once.
    * Every call is timeout-bounded: a slow call times the whole episode out,
      which scores as a loss.
    """

    def __init__(self, url: str, model: str, api_key: str | None = None,
                 label: str | None = None, timeout: float = 30.0) -> None:
        self.url = url
        self.model = model
        self.api_key = api_key
        self.name = label or model
        self.timeout = timeout
        self.calls = 0

    def _headers(self) -> dict:
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
            headers["X-Title"] = "coworld-ctf poc_llm_policy"
        return headers

    def decide(self, summary: str) -> dict:
        body = json.dumps({
            "model": self.model,
            "response_format": {"type": "json_object"},
            "temperature": 0.4,
            "max_tokens": 600,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": summary},
            ],
        }).encode("utf-8")

        for attempt in (0, 1):
            request = urllib.request.Request(
                self.url, data=body, headers=self._headers(), method="POST")
            try:
                with urllib.request.urlopen(request, timeout=self.timeout) as response:
                    payload = json.loads(response.read().decode("utf-8"))
                break
            except urllib.error.HTTPError as error:
                # Log the RESPONSE BODY, not just the status: it names whether
                # the failure was the route, the auth, the model allowlist, or
                # the spend cap. A bot that logs only "HTTP 4xx" hides which.
                detail = error.read().decode("utf-8", "replace")[:400]
                if error.code == 429 and attempt == 0:
                    delay = _retry_delay(error.headers)
                    print(f"[poc] rate limited; retrying in {delay:.1f}s ({detail})",
                          flush=True)
                    time.sleep(delay)
                    continue
                raise BrainError(
                    f"chat completions HTTP {error.code} at {self.url}: {detail}"
                ) from error
            except urllib.error.URLError as error:
                raise BrainError(
                    f"chat completions unreachable at {self.url}: {error.reason}"
                ) from error
        else:
            raise BrainError("stayed rate limited")

        self.calls += 1
        try:
            content = payload["choices"][0]["message"]["content"]
        except (KeyError, IndexError) as error:
            raise BrainError(f"unexpected completion response: {payload}") from error
        try:
            return json.loads(content)
        except json.JSONDecodeError as error:
            raise BrainError(f"model did not return JSON: {content[:400]}") from error


class BedrockInvokeBrain:
    """OPT-IN FALLBACK ONLY -- the legacy Bedrock Runtime `InvokeModel` path.

    James states that OpenRouter routing is the production truth: the sidecar's
    OpenAI-compatible route is the live path, and production runs
    `episodePercent: 100`. This class is kept only because the sidecar still
    accepts the Bedrock shapes, so it is a usable escape hatch if the
    OpenAI-compatible route ever misbehaves for a specific model.

    It is NOT load-bearing and is never auto-selected. Turn it on deliberately
    with ``POC_LLM_PROTOCOL=bedrock``.

    Shape: ``POST {endpoint}/model/{model}/invoke`` with an Anthropic Messages
    body and no ``Authorization`` header. There is no ``response_format`` here,
    so JSON is forced by prefilling the assistant turn with ``{``.
    ``requestMetadata`` is deliberately never set -- the sidecar overwrites it
    with trusted attribution.
    """

    def __init__(self, endpoint: str, model: str, timeout: float = 30.0) -> None:
        self.endpoint = endpoint.rstrip("/")
        self.model = model
        self.name = f"bedrock-invoke {model}"
        self.timeout = timeout
        self.calls = 0

    @property
    def url(self) -> str:
        return f"{self.endpoint}/model/{self.model}/invoke"

    def decide(self, summary: str) -> dict:
        body = json.dumps({
            "anthropic_version": ANTHROPIC_BEDROCK_VERSION,
            "max_tokens": 600,
            "temperature": 0.4,
            "system": SYSTEM_PROMPT,
            "messages": [
                {"role": "user", "content": summary},
                {"role": "assistant", "content": "{"},
            ],
        }).encode("utf-8")
        request = urllib.request.Request(
            self.url, data=body,
            headers={"Content-Type": "application/json",
                     "Accept": "application/json"},
            method="POST")
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")[:400]
            raise BrainError(
                f"InvokeModel HTTP {error.code} at {self.url}: {detail}") from error
        except urllib.error.URLError as error:
            raise BrainError(
                f"InvokeModel unreachable at {self.url}: {error.reason}") from error
        self.calls += 1
        try:
            text = "".join(block.get("text", "") for block in payload["content"]
                           if block.get("type") == "text")
        except (KeyError, TypeError) as error:
            raise BrainError(f"unexpected InvokeModel response: {payload}") from error
        text = "{" + text
        try:
            return json.loads(text)
        except json.JSONDecodeError as error:
            raise BrainError(f"model did not return JSON: {text[:400]}") from error


class ResilientBrain:
    """Keeps the policy alive when its model cannot be reached or used.

    Wraps a live backend. The first ``decide`` failure of ANY kind -- an HTTP
    4xx such as the sidecar's model-allowlist 403 ``model_not_allowed``, a
    transport error, unusable output -- is logged ONCE, and every decision
    from then on comes from the canned ``fallback`` instead. No further model
    calls are attempted, so a hard rejection costs exactly one upstream
    request.

    Why: a policy that cannot reach its LLM should play its scripted game, not
    exit 1. On the hosted platform a dead pod forfeits the seat, and when the
    sidecar's allowlist rejected the starters' default model that was ten dead
    seats per episode.
    """

    def __init__(self, primary, fallback=None) -> None:
        self.primary = primary
        self.fallback = fallback if fallback is not None else CannedBrain()
        self.error: Exception | None = None

    @property
    def name(self) -> str:
        if self.error is None:
            return self.primary.name
        return (f"{self.primary.name} (degraded to {self.fallback.name}: "
                f"{str(self.error)[:200]})")

    @property
    def calls(self) -> int:
        """Real model calls, for the end-of-run summary."""
        return getattr(self.primary, "calls", 0)

    def decide(self, summary: str) -> dict:
        if self.error is None:
            try:
                return self.primary.decide(summary)
            except Exception as error:  # noqa: BLE001 -- ANY model failure
                self.error = error
                print(f"[poc] model backend {self.primary.name} failed; "
                      f"playing on with {self.fallback.name} decisions: "
                      f"{error}", flush=True)
        return self.fallback.decide(summary)


def _retry_delay(headers, default: float = 2.0) -> float:
    """Honour the proxy's throttling hint. `Retry-After-Ms` wins if present."""
    milliseconds = headers.get("Retry-After-Ms")
    if milliseconds:
        try:
            return max(0.0, float(milliseconds) / 1000.0)
        except ValueError:
            pass
    seconds = headers.get("Retry-After")
    if seconds:
        try:
            return max(0.0, float(seconds))
        except ValueError:
            pass
    return default


def build_brain(canned: bool, model: str, fallback=None) -> tuple[object, str]:
    """Pick a backend and report why, so the run log is unambiguous.

    Order is production-first: the hosted sidecar, then a developer's own
    OpenRouter key, then canned. `--canned` overrides everything so an offline
    or CI run is never at the mercy of ambient environment.

    ``fallback`` is the canned engine used when nothing is configured AND as
    the degrade target when a live backend fails (see :class:`ResilientBrain`).
    Callers with scripted personas pass their own; ``None`` means the PoC's
    :class:`CannedBrain`.

    Model precedence on the sidecar path: the platform-injected
    ``BEDROCK_MODEL`` wins (set per player pod from the upload's
    ``--bedrock-model`` -- the dispatcher's documented injection seam, see
    metta app_backend job_runner/dispatcher.py and COWORLD_MECHANICS.md);
    ``model`` (usually :data:`DEFAULT_MODEL`) is used only when nothing was
    injected.
    """
    if fallback is None:
        fallback = CannedBrain()
    if canned:
        return fallback, "canned mode requested"

    endpoint = os.environ.get(SIDECAR_ENDPOINT_ENV, "").strip()
    if endpoint:
        injected = os.environ.get(SIDECAR_MODEL_ENV, "").strip()
        if injected:
            sidecar_model = injected
            source = f"{SIDECAR_MODEL_ENV}={injected}"
        else:
            # Nothing injected. This used to refuse loudly (exit 1 before the
            # seat ever played, on a hosted pod). Degraded play beats a dead
            # pod: try the default model, and if the sidecar rejects it the
            # ResilientBrain wrapper keeps the seat alive on canned decisions.
            sidecar_model = model
            source = (f"{SIDECAR_MODEL_ENV} unset; trying the default "
                      f"model {model}")
        if os.environ.get(SIDECAR_PROTOCOL_ENV, "").strip().lower() == "bedrock":
            return (ResilientBrain(BedrockInvokeBrain(endpoint, sidecar_model),
                                   fallback),
                    f"hosted sidecar at {endpoint}, legacy InvokeModel path "
                    f"({SIDECAR_PROTOCOL_ENV}=bedrock, {source})")
        return (ResilientBrain(
                    OpenAiChatBrain(
                        f"{endpoint.rstrip('/')}/v1/chat/completions",
                        sidecar_model,
                        label=f"sidecar-openai {sidecar_model}"),
                    fallback),
                f"hosted sidecar at {endpoint}, OpenAI-compatible chat "
                f"completions ({source})")

    key = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if key:
        return (ResilientBrain(
                    OpenAiChatBrain(OPENROUTER_URL, model, api_key=key,
                                    label=model),
                    fallback),
                f"direct OpenRouter, model {model} (dev path)")

    return fallback, (
        f"neither {SIDECAR_ENDPOINT_ENV} nor OPENROUTER_API_KEY is set; "
        "falling back to canned")
