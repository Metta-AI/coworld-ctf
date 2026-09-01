"""The LLM half of the PoC: turn a short match summary into a chat line and a
ladder call.

Three interchangeable backends, all returning the same dict shape::

    {"chat": "<one lobby line>",
     "call": {"entries": [{"play": ..., "entry_id": ..., "params": {...}}, ...]}}

Selected in this order, which is deliberate — see the README:

1. :class:`BedrockSidecarBrain` -- **the production path.** A hosted policy pod
   gets no model credentials of its own; the platform runs a per-pod "Bedrock
   sidecar" on loopback that holds the real identity and signs calls for it.
   Selected when ``AWS_ENDPOINT_URL_BEDROCK_RUNTIME`` is present.
2. :class:`OpenRouterBrain` -- **dev/local only.** One JSON-mode chat completion
   against OpenRouter with a cheap open-weights instruct model. Selected when
   ``OPENROUTER_API_KEY`` is set.
3. :class:`CannedBrain` -- a fixed response so the image is testable offline and
   in CI. Forced by ``--canned``, and used when neither of the above is present.

Everything uses ``urllib`` from the standard library, so the image needs no
HTTP or cloud SDK dependency.

The model is never trusted: :mod:`poc_policy` re-validates and repairs whatever
comes back before any of it reaches the wire, and the server's call validator
is the final oracle.
"""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"

# ── The hosted-platform contract ──────────────────────────────────────────
# Verified against the metta checkout at commit 9e780b9ff7. The authoritative
# player-facing document is
# packages/coworld/src/coworld/docs/BEDROCK.md; the pod wiring that sets these
# is packages/coworld/src/coworld/runner/bedrock_sidecar_wiring.py:267-282.
SIDECAR_ENDPOINT_ENV = "AWS_ENDPOINT_URL_BEDROCK_RUNTIME"
"""Presence of this is THE signal that hosted Bedrock is available.

BEDROCK.md is explicit that you gate on this and not on ``USE_BEDROCK``, which
is also set for direct local AWS access with no sidecar in front of it.
"""

SIDECAR_MODEL_ENV = "BEDROCK_MODEL"
"""Set from the ``--bedrock-model`` upload flag. Must be read, never hardcoded."""

ANTHROPIC_BEDROCK_VERSION = "bedrock-2023-05-31"

DEFAULT_MODEL = "qwen/qwen3-30b-a3b-instruct-2507"
"""A cheap, capable open-weights instruct model with reliable JSON mode.

Any OpenRouter model id works via ``--model``; this one is the PoC default
because it is inexpensive (well under $0.10 per million prompt tokens), open
weights, and follows ``response_format: json_object`` consistently.
"""

# The playbook the harness carries. Params are described to the model exactly
# as the reference manifests declare them
# (tests/fixtures/shell/manifest_edge_ride.golden.json and manifest_pact.golden.json)
# so the model has the same contract the server validates against.
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


class OpenRouterBrain:
    """One JSON-mode chat completion per decision."""

    def __init__(self, api_key: str, model: str = DEFAULT_MODEL,
                 timeout: float = 60.0) -> None:
        self.api_key = api_key
        self.model = model
        self.name = model
        self.timeout = timeout
        self.calls = 0

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
        request = urllib.request.Request(
            OPENROUTER_URL,
            data=body,
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
                # OpenRouter attribution headers; harmless if unset upstream.
                "X-Title": "coworld-ctf poc_llm_policy",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")[:400]
            raise BrainError(f"OpenRouter HTTP {error.code}: {detail}") from error
        except urllib.error.URLError as error:
            raise BrainError(f"OpenRouter unreachable: {error.reason}") from error
        self.calls += 1
        try:
            content = payload["choices"][0]["message"]["content"]
        except (KeyError, IndexError) as error:
            raise BrainError(f"unexpected OpenRouter response: {payload}") from error
        try:
            return json.loads(content)
        except json.JSONDecodeError as error:
            raise BrainError(f"model did not return JSON: {content[:400]}") from error


class BedrockSidecarBrain:
    """The production path: Bedrock Runtime `InvokeModel` through the sidecar.

    The platform injects a loopback endpoint plus deliberately fake AWS
    credentials; the sidecar strips whatever auth the client sends and re-signs
    with the real pod identity, so this sends **no** ``Authorization`` header
    and needs no AWS SDK.

    Two things differ from the OpenRouter path and are worth knowing:

    * **There is no ``response_format``.** The Anthropic Messages body has no
      JSON mode, so JSON is forced by prefilling the assistant turn with ``{``
      and prepending it back onto the reply. That is the standard technique and
      it is reliable, but it is not the same mechanism.
    * **Requests are rate limited** (30/minute per player slot by default). A
      429 comes back as a Bedrock ``ThrottlingException`` with ``Retry-After``,
      which this honours once rather than failing the turn.

    Deliberately not set: ``requestMetadata``. The sidecar overwrites it with
    trusted attribution, so sending it is at best ignored.
    """

    def __init__(self, endpoint: str, model: str, timeout: float = 30.0) -> None:
        self.endpoint = endpoint.rstrip("/")
        self.model = model
        self.name = f"bedrock-sidecar {model}"
        # BEDROCK.md warns that a slow call times the whole episode out, which
        # scores as a loss, so the bound is short and deliberate.
        self.timeout = timeout
        self.calls = 0

    @property
    def url(self) -> str:
        # The model id is placed in the path raw, matching the documented curl
        # example in BEDROCK.md ("How to make the call").
        return f"{self.endpoint}/model/{self.model}/invoke"

    def _post(self, body: bytes) -> dict:
        request = urllib.request.Request(
            self.url,
            data=body,
            headers={"Content-Type": "application/json",
                     "Accept": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=self.timeout) as response:
            return json.loads(response.read().decode("utf-8"))

    def decide(self, summary: str) -> dict:
        body = json.dumps({
            "anthropic_version": ANTHROPIC_BEDROCK_VERSION,
            "max_tokens": 600,
            "temperature": 0.4,
            "system": SYSTEM_PROMPT,
            "messages": [
                {"role": "user", "content": summary},
                # Prefill: forces the reply to open as a JSON object.
                {"role": "assistant", "content": "{"},
            ],
        }).encode("utf-8")

        for attempt in (0, 1):
            try:
                payload = self._post(body)
                break
            except urllib.error.HTTPError as error:
                detail = error.read().decode("utf-8", "replace")[:400]
                # BEDROCK.md: log the RESPONSE BODY, not just the status -- the
                # body names whether it was the route, the auth, or the model.
                if error.code == 429 and attempt == 0:
                    delay = _retry_delay(error.headers)
                    print(f"[poc] sidecar throttled; retrying in {delay:.1f}s "
                          f"({detail})", flush=True)
                    time.sleep(delay)
                    continue
                raise BrainError(
                    f"Bedrock sidecar HTTP {error.code} at {self.url}: {detail}"
                ) from error
            except urllib.error.URLError as error:
                raise BrainError(
                    f"Bedrock sidecar unreachable at {self.url}: {error.reason}"
                ) from error
        else:
            raise BrainError("Bedrock sidecar stayed throttled")

        self.calls += 1
        try:
            text = "".join(block.get("text", "")
                           for block in payload["content"]
                           if block.get("type") == "text")
        except (KeyError, TypeError) as error:
            raise BrainError(f"unexpected Bedrock response: {payload}") from error
        # Put back the prefilled brace the model was not asked to repeat.
        text = "{" + text
        try:
            return json.loads(text)
        except json.JSONDecodeError as error:
            raise BrainError(f"model did not return JSON: {text[:400]}") from error


def _retry_delay(headers, default: float = 2.0) -> float:
    """Honour the sidecar's throttling hint. `Retry-After-Ms` wins if present."""
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


def build_brain(canned: bool, model: str) -> tuple[object, str]:
    """Pick a backend and report why, so the run log is unambiguous.

    Order is production-first: the hosted sidecar, then a developer's own
    OpenRouter key, then canned. `--canned` overrides everything so an offline
    or CI run is never at the mercy of ambient environment.
    """
    if canned:
        return CannedBrain(), "canned mode requested"

    endpoint = os.environ.get(SIDECAR_ENDPOINT_ENV, "").strip()
    if endpoint:
        sidecar_model = os.environ.get(SIDECAR_MODEL_ENV, "").strip()
        if not sidecar_model:
            # Falling back silently here is the documented way to score zero
            # completed episodes without noticing, so refuse loudly instead.
            raise BrainError(
                f"{SIDECAR_ENDPOINT_ENV} is set but {SIDECAR_MODEL_ENV} is not. "
                "Upload the policy with --bedrock-model, and read the model "
                "from that variable rather than hardcoding one.")
        return (BedrockSidecarBrain(endpoint, sidecar_model),
                f"hosted Bedrock sidecar at {endpoint} ({SIDECAR_MODEL_ENV}="
                f"{sidecar_model})")

    key = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if key:
        return OpenRouterBrain(key, model), f"OpenRouter model {model} (dev path)"

    return CannedBrain(), (
        f"neither {SIDECAR_ENDPOINT_ENV} nor OPENROUTER_API_KEY is set; "
        "falling back to canned")
