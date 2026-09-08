"""Classifier: did a seat's policy process actually complete the match handshake?

Pure function, no network — kept separate from checker.py so it can be unit
tested against representative log/metadata snippets without hitting the API.

Classes (see README.md for how each is produced from real data):
  HANDSHAKE-COMPLETE  the policy log shows a `0xB0 play_context` message —
                       the server handed the seat its PlayContext and the
                       seat is in the match.
  NO-PLAYCONTEXT      the policy log exists (the process ran, connected to
                       the game server) but the server never sent 0xB0 — the
                       log ends on the documented failure line, "FAILED: no
                       0xB0 PlayContext from the server".
  NEVER-JOINED        no policy log content at all, and the round/episode
                       record's own error fields say the seat never joined
                       the lobby inside its join window (a platform-reported
                       timeout, not a process crash).
  NOT-STARTED         no policy log content at all, and either the record
                       says the platform never started that seat's process
                       (e.g. `container_failed`), or the policy-log route
                       itself returned a clean 404 for the correct
                       (episode_request_id, policy_version_id, agent_idx)
                       triple — confirmed live (see README "Real run") that
                       a 404 means "no log was ever produced for this seat",
                       distinct from a 403 ("wrong agent/policy pairing",
                       which is OUR bug, not the platform's — left UNKNOWN).
  UNKNOWN             anything else — an unrecognized log shape, or a status/
                       error combination we haven't seen before. Reported
                       honestly rather than guessed into one of the above.
"""
from __future__ import annotations

# Error-type / error-string fragments observed on the ladder for each
# platform-reported non-completion cause. Kept as a tuple of substrings
# (not a single exact string) because the exact wording has drifted across
# engine builds in this ladder's history (commons-pipeline RUNSTATE notes
# on error_type drift) — match loosely, on substrings, not equality.
_NEVER_JOINED_HINTS = (
    "never joined",
    "did not join",
    "lobby",
    "join window",
    "join_timeout",
    "lobby_timeout",
)
_NOT_STARTED_HINTS = (
    "container_failed",
    "not_started",
    "no process",
    "failed to start",
    "never started",
    # Real wording confirmed live 2026-09-07 (round 4360): a platform-wide
    # message, no specific seat named, so safe to trust without a slot-match
    # guard (see checker.py's _SLOT_RE — that guard is only needed for
    # per-seat "slot N never joined" wording, not this one).
    "did not start every player process",
)

_HANDSHAKE_OK = "0xb0 play_context"
_HANDSHAKE_FAIL = "no 0xb0 playcontext"

# log_fetch_status values (see api.get_policy_log) that mean "the route
# itself confirmed no log exists", as opposed to "we don't know" (a 403 /
# missing-ids / transport error, which stays UNKNOWN rather than guessed).
_FETCH_STATUS_NO_LOG = ("http-404",)


def classify_seat_appearance(log_text: str | None, error_type: str | None = None,
                              error: str | None = None,
                              log_fetch_status: str | None = None) -> str:
    """Classify one seat's appearance in one episode.

    log_text: the raw (decoded) policy-log text for this seat/episode, or
        None if no log content was obtained at all.
    error_type / error: fields off the round/episode record's own failure
        metadata (only meaningful when the episode did not complete
        cleanly at the round level).
    log_fetch_status: the outcome of the policy-log HTTP fetch itself
        (e.g. "ok", "http-404", "http-403", "missing-ids") — lets the
        classifier distinguish "the platform confirms no log exists" from
        "we couldn't determine that".
    """
    hint = f"{error_type or ''} {error or ''}".lower()

    if log_text:
        lower = log_text.lower()
        if _HANDSHAKE_OK in lower:
            return "HANDSHAKE-COMPLETE"
        if _HANDSHAKE_FAIL in lower:
            return "NO-PLAYCONTEXT"
        # A log exists but shows neither marker — e.g. it stops mid-connect,
        # or during module upload, before the server would ever emit 0xB0.
        # That is exactly the "never made it into the lobby in time" shape,
        # so route it there if the episode metadata agrees; otherwise
        # UNKNOWN rather than a guess.
        if any(h in hint for h in _NEVER_JOINED_HINTS):
            return "NEVER-JOINED"
        return "UNKNOWN"

    # No log content at all. Distinguish "process never launched" from
    # "process launched somewhere but never reached the lobby in time"
    # using the round/episode record's own error fields first (most
    # specific), then fall back to what the log-fetch route itself told us.
    if any(h in hint for h in _NEVER_JOINED_HINTS):
        return "NEVER-JOINED"
    if any(h in hint for h in _NOT_STARTED_HINTS):
        return "NOT-STARTED"
    if log_fetch_status in _FETCH_STATUS_NO_LOG:
        return "NOT-STARTED"
    return "UNKNOWN"
