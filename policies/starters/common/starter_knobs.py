"""The starter harness's own tunable knobs, named once so `run_local.py`
and `compare_local.py` (and the wiki page) all use the same words.

Each knob is an env var the shared harness (`starter_harness.py main()`)
already reads with `os.environ.get(...)` -- setting it via
`coworld run-episode --secret-env KEY=VALUE` changes a seat's behavior
without rebuilding the Docker image. `recall_seconds` is the one sonnet-a
actually retuned (see `../VERSION_LOG.md`); the other four are the rest of
the persona's live-loop schedule (`Persona` dataclass fields in
`starter_harness.py`).
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Knob:
    env: str
    help: str


#: name -> Knob. Names match the harness's own `--flag-name` spelling with
#: dashes, so `--knob recall-seconds` reads naturally next to the harness's
#: `--recall-seconds`.
KNOBS: dict[str, Knob] = {
    "recall-seconds": Knob(
        "POC_RECALL_SECONDS",
        "minimum spacing between model calls, in seconds "
        "(the retune sonnet-a actually made)",
    ),
    "recall-count": Knob(
        "POC_RECALL_COUNT",
        "canned/offline turn budget (ignored once --max-calls is reached)",
    ),
    "max-calls": Knob(
        "POC_MAX_CALLS",
        "model calls per match, opening call included",
    ),
    "connect-deadline": Knob(
        "POC_CONNECT_DEADLINE",
        "keep retrying the play socket for this many seconds before giving up",
    ),
    "no-base-play": Knob(
        "POC_NO_BASE_PLAY",
        "1 disables the persona's always-on base play (edge_ride/jackal); "
        "the engine default (rotate + zone-escape reflex) drives instead",
    ),
}
