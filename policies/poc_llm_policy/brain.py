"""The LLM half of the PoC: turn a short match summary into a chat line and a
ladder call.

Two interchangeable backends, both returning the same dict shape::

    {"chat": "<one lobby line>",
     "call": {"entries": [{"play": ..., "entry_id": ..., "params": {...}}, ...]}}

* :class:`OpenRouterBrain` -- one JSON-mode chat completion against OpenRouter
  with a cheap open-weights instruct model. Uses ``urllib`` from the standard
  library, so the image needs no HTTP dependency.
* :class:`CannedBrain` -- a fixed response so the image is testable offline and
  in CI. Selected by ``--canned``, and used automatically when no API key is
  present.

The model is never trusted: :mod:`poc_policy` re-validates and repairs whatever
comes back before any of it reaches the wire, and the server's call validator
is the final oracle.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"

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


def build_brain(canned: bool, model: str) -> tuple[object, str]:
    """Pick a backend and report why, so the run log is unambiguous."""
    key = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if canned:
        return CannedBrain(), "canned mode requested"
    if not key:
        return CannedBrain(), "OPENROUTER_API_KEY is not set; falling back to canned"
    return OpenRouterBrain(key, model), f"OpenRouter model {model}"
