"""Read-only REST client for the seat-connectivity checker.

Speaks raw JSON against the Softmax Observatory API (base
https://softmax.com/api/observatory) with stdlib `urllib` only — no
dependency on the internal `coworld` player package, so any entrant can run
this with just their own API token.

Every trap below was hit and documented by prior sessions working this same
API; each is cited by its memory-file name so a future reader can find the
original incident. Do not "simplify" any of these away.
"""
from __future__ import annotations

import ast
import json
import os
import sys
import time
import urllib.error
import urllib.request

BASE = "https://softmax.com/api/observatory"

# Paintbot Season 2 (the live league this checker targets by default).
# league/div ids are STABLE per tools/ladder/ctfapi.py + repo memory; a
# division id, never a league id, is what actually filters server-side
# (see TRAP 1 below), so that is the one exposed as an override.
PAINTBOT_LEAGUE = "league_b8fa9b35-ac22-48cf-a03f-07b397aff1c7"
PAINTBOT_DIV = os.environ.get("SEATCHECK_DIVISION",
                               "div_aa7825db-262f-4a62-b01a-177c1b48f7ee")

# TRAP: token via env var only. Never hardcode, never print/log it, and
# never put it in an argparse default (defaults show up in --help/-h and in
# any shell history that echoes the parsed args).
TOKEN_ENV = "SEATCHECK_TOKEN"


def _token() -> str:
    tok = os.environ.get(TOKEN_ENV)
    if not tok:
        print(f"error: set {TOKEN_ENV} to your API token (never pass it as "
              f"a CLI flag). See README.md for how to obtain one.",
              file=sys.stderr)
        sys.exit(2)
    return tok


def _get(path: str, headers: dict, tries: int = 4):
    """GET with retry/backoff — a multi-round sweep reliably hits at least
    one transient timeout, and re-raising on the first failure throws away
    everything already fetched in the same process for no reason."""
    url = f"{BASE}{path}"
    req = urllib.request.Request(url, headers=headers)
    last_exc = None
    for attempt in range(tries):
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = resp.read()
                return resp.status, (json.loads(body) if body else None)
        except urllib.error.HTTPError as exc:
            # A real HTTP error status is signal, not a transport failure —
            # return it so callers can branch on 404 vs 200 (the policy-log
            # fetch NEEDS to distinguish "never ran" 404s from real content).
            return exc.code, None
        except Exception as exc:  # noqa: BLE001 — transient DNS/timeout/etc.
            last_exc = exc
            if attempt == tries - 1:
                raise
            time.sleep(1.5 * (attempt + 1))
    raise last_exc  # pragma: no cover — unreachable, satisfies linters


def _get_text(path: str, headers: dict, tries: int = 4):
    """Like _get but for endpoints that return a raw log blob, not JSON."""
    url = f"{BASE}{path}"
    req = urllib.request.Request(url, headers=headers)
    for attempt in range(tries):
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.status, resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as exc:
            return exc.code, None
        except Exception:  # noqa: BLE001
            if attempt == tries - 1:
                raise
            time.sleep(1.5 * (attempt + 1))


def auth_headers() -> dict:
    """A prior session's notes recorded that the policy-log download route
    specifically only accepts `X-Auth-Token` and 404s (not 401) on
    `Authorization: Bearer`, which would read like a missing endpoint
    rather than an auth failure. Re-verified live while building this tool
    (2026-09-07): both header styles returned 200 with identical bodies on
    that route today — the 404-on-Bearer behavior did NOT reproduce. We
    send both anyway; it costs nothing and hedges against this being
    version-dependent rather than fixed for good."""
    tok = _token()
    return {"Authorization": f"Bearer {tok}", "X-Auth-Token": tok,
             "User-Agent": "seat-connectivity-checker/1.0"}


def _decode_policy_log_body(raw: str) -> str:
    """The policy-log route returns the log as a literal Python bytes-repr
    STRING — e.g. the HTTP body's actual text is `b'[poc] 0xB0 ...\\n...'`
    (a literal `b'`...`'` wrapper, with real newlines encoded as the two
    characters backslash-n, not an actual line break). Confirmed live
    2026-09-07. Decode it with ast.literal_eval so downstream substring/
    line-based classification runs on the real log content, not on a
    string that still contains literal escape sequences and quoting.
    Falls back to the raw text if it doesn't look like a bytes repr, so a
    format change degrades to UNKNOWN rather than crashing."""
    text = raw.strip()
    if (text.startswith("b'") and text.endswith("'")) or \
       (text.startswith('b"') and text.endswith('"')):
        try:
            return ast.literal_eval(text).decode("utf-8", "replace")
        except (ValueError, SyntaxError):
            pass
    return raw


def list_rounds(limit=100, division_id=PAINTBOT_DIV, headers=None):
    """TRAP 1 (ctf-rounds-endpoint-filter-and-offset-traps.md /
    ctf-coworld-scoped-queries-cross-leagues.md): `/v2/rounds` silently
    IGNORES `league_id=` and any offset/page/skip param — every call
    returns the same newest page regardless. `division_id=` is the ONLY
    filter that actually works server-side. Rounds also carry no top-level
    `league` field (it's `null`); the league only exists nested at
    `round.division.league.id`, so a caller that wants to double check the
    league (not just the division) must reach through `division`.

    TRAP 2 (same memory files): pagination on this endpoint returns
    OVERLAPPING pages, not disjoint ones — a multi-page sweep can see the
    same round 2-3x. Callers MUST dedupe by `round["id"]`.
    """
    headers = headers or auth_headers()
    status, data = _get(f"/v2/rounds?limit={limit}&division_id={division_id}",
                         headers)
    if status != 200:
        raise RuntimeError(f"list_rounds: HTTP {status} on /v2/rounds "
                            f"(division_id={division_id})")
    rows = data if isinstance(data, list) else (data.get("entries")
                                                  or data.get("data") or [])
    seen, out = set(), []
    for r in rows:
        rid = r.get("id")
        if rid in seen:  # TRAP 2 dedupe
            continue
        seen.add(rid)
        out.append(r)
    return out


def list_episodes(round_id: str, headers=None):
    """Default `limit` on this route is 50, but a round can hold 100+
    episodes — the default silently truncates and can drop the very seat
    you're checking for. Always pass limit=1000. The payload key is
    `entries`, NOT `episodes`/`data`/`items` — code that checks the wrong
    key reads an empty result as "no episodes" instead of erroring loudly.
    (documented in ~/.ctf/knowledge/reference/api-access.md)

    Each entry already carries everything this tool needs per seat: `id`
    (the episode_request_id), `participants[]`, `status`, `error_type`,
    `error`, `failed_agent_index`, and `coworld_version`. The thinner
    sibling route `/v2/rounds/{id}/episode-requests` (which also caps
    `limit` at 100, confirmed live) is not needed by this tool.
    """
    headers = headers or auth_headers()
    status, data = _get(f"/v2/rounds/{round_id}/episodes?limit=1000", headers)
    if status != 200:
        raise RuntimeError(f"list_episodes({round_id}): HTTP {status}")
    return data.get("entries") or []


def find_seat(episode: dict, entrant: str):
    """Return the participant dict for `entrant` in this episode, or None.

    TRAP 3 (ctf-api-playername-lies-on-filler-seats.md): the API's
    `player_name` field on scripted FILLER seats can read as a REAL
    player's name (historically `daveey`; more recently seats under
    `softmaxwell` itself) even though they are a different, scripted
    policy — a name-only match double-counts filler seats into a real
    entrant's own row. Always require `is_filler` is falsy IN ADDITION to
    the name match; never key on `player_name` alone.
    """
    for p in episode.get("participants", []) or []:
        if p.get("player_name") == entrant and not p.get("is_filler"):
            return p
    return None


def get_policy_log(episode: dict, participant: dict, headers=None):
    """Fetch the decoded policy-log text for one seat in one episode.

    Route: /v2/episode-requests/{episode_request_id}/{policy_version_id}/policy-logs/{agent_idx}
    Confirmed live 2026-09-07 against a real completed episode:
      - `episode_request_id` is the round-episode entry's OWN `id` field
        (an `ereq_...`-prefixed id) — NOT its separate `episode_id` field,
        which is a bare UUID used only for display/lookup elsewhere.
      - `policy_version_id` comes straight off the participant dict.
      - `agent_idx` is the participant's global `position` (0..N-1 across
        the whole episode roster, NOT a per-team index — a per-team index
        gets a clean 403 "Agent N does not run the specified policy").

    Returns (log_text, fetch_status). log_text is None whenever no content
    was obtained; fetch_status distinguishes WHY: "ok" (200, decoded),
    "http-404" (route confirms no log was ever produced for this seat —
    strong NOT-STARTED evidence), "http-403" (wrong agent_idx/policy_version_id
    pairing — OUR bug, not platform evidence, classifier leaves it UNKNOWN),
    "missing-ids" (episode/participant dict didn't carry what we needed).
    """
    headers = headers or auth_headers()
    ereq_id = episode.get("id")
    pv_id = participant.get("policy_version_id")
    agent_idx = participant.get("position")
    if not (ereq_id and pv_id is not None and agent_idx is not None):
        return None, "missing-ids"
    status, text = _get_text(
        f"/v2/episode-requests/{ereq_id}/{pv_id}/policy-logs/{agent_idx}",
        headers)
    if status == 200 and text is not None:
        return _decode_policy_log_body(text), "ok"
    return None, f"http-{status}"
