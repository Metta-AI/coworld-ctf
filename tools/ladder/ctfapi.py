"""Shared CTF league API helper.

Run with the cogherence player's venv, which holds the working login:
  ~/projects/coworld-players/coworld-cogherence-player/.venv/bin/python

The CLI schema drifts; we speak raw JSON against /v2.
"""
import os
import sys
import time

sys.path.insert(0, "/Users/maxwellstarr/projects/coworld-players/coworld-cogherence-player")

from coworld.api_client import CoworldApiClient  # noqa: E402
from coworld.config import DEFAULT_SUBMIT_SERVER  # noqa: E402

# ⚠️ These pointed at the DEAD `Ctf` league until 2026-08-12, so every helper
# built on them (standing.py, scout.py index, my_memberships) answered about a
# league that stopped playing — "0 of 224 episodes involve softmaxwell" was TRUE
# there and meaningless about ours. An empty result from the wrong league is
# indistinguishable from a real outage; it once cost a full session to a false
# "we are paused and disqualified" reading. The live league is Paintbot.
# Override with CTF_LEAGUE / CTF_DIV to inspect any other league.
PAINTBOT_LEAGUE = "league_b8fa9b35-ac22-48cf-a03f-07b397aff1c7"
PAINTBOT_DIV = "div_aa7825db-262f-4a62-b01a-177c1b48f7ee"
DEAD_CTF_LEAGUE = "league_3243d905-d32d-4ec6-978b-fa94751d4a37"  # kept: do not use

LEAGUE = os.environ.get("CTF_LEAGUE", PAINTBOT_LEAGUE)
COMPETITION_DIV = os.environ.get("CTF_DIV", PAINTBOT_DIV)
OUR_PLAYER = "softmaxwell"


def whoami():
    """Print which league every helper here is about to query. Call this before
    believing ANY empty result."""
    tag = "Paintbot (live)" if LEAGUE == PAINTBOT_LEAGUE else (
        "DEAD Ctf league" if LEAGUE == DEAD_CTF_LEAGUE else "custom")
    print(f"[ctfapi] league={LEAGUE} div={COMPETITION_DIV} -> {tag}",
          file=sys.stderr)

_client = None
_headers = None


def gid(o):
    """Membership records nest league/division/policy_version as objects."""
    return (o or {}).get("id") if isinstance(o, dict) else o


def client():
    global _client, _headers
    if _client is None:
        _client = CoworldApiClient.from_login(server_url=DEFAULT_SUBMIT_SERVER)
        _headers = _client._headers()
    return _client, _headers


def get(path, tries=5):
    """A long sweep over hundreds of rounds reliably hits a read timeout;
    retry with backoff rather than losing the whole run."""
    c, h = client()
    for i in range(tries):
        try:
            r = c._http_client.get(path, headers=h, timeout=60.0)
            r.raise_for_status()
            return r.json()
        except Exception as e:  # noqa: BLE001 — transient transport/5xx
            if i == tries - 1:
                raise
            print(f"  [retry {i+1}/{tries}] {type(e).__name__} on {path}",
                  file=sys.stderr)
            time.sleep(2 * (i + 1))


MAX_RECENT_ROUNDS = 1  # see below


def leaderboard(include_recent_rounds=MAX_RECENT_ROUNDS, div=COMPETITION_DIV):
    """⚠️ As of 2026-08-18 the endpoint 422s on include_recent_rounds > 1.
    Probed 0,1,4,8,16,20,24,32: only 0 and 1 are accepted. The old default of
    32 meant EVERY caller crashed — standing.py died on its first call, which
    is the first command of most sessions. Clamp rather than pass through, so
    a stale caller degrades to a working leaderboard instead of a traceback.

    The field is dead weight anyway: it comes back as `recent_rounds: null`
    with `rounds_played: 0`. Use rounds.py / h2h.py for per-round history.
    Note the score is now `Territory` (campaign cells), not Elo.
    """
    n = min(include_recent_rounds, MAX_RECENT_ROUNDS)
    r = get(f"/v2/divisions/{div}/leaderboard?include_recent_rounds={n}")
    return r if isinstance(r, list) else (r.get("entries") or r.get("rows") or [])


def episodes(round_id, limit=1000):
    """⚠️ default limit is 50 but a round holds ~110 episodes — the default
    silently truncates and can drop our own pairings entirely."""
    r = get(f"/v2/rounds/{round_id}/episodes?limit={limit}")
    if isinstance(r, list):
        return r
    return (r.get("entries") or r.get("episodes") or r.get("data")
            or r.get("items") or [])


def round_detail(round_id):
    return get(f"/v2/rounds/{round_id}")


def my_memberships(league=LEAGUE):
    m = get("/v2/league-policy-memberships?mine=true")
    ms = m if isinstance(m, list) else (m.get("memberships") or m.get("data") or m.get("items") or [])
    return [x for x in ms if gid(x.get("league")) == league]
