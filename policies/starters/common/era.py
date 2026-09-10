"""The one named constant `run_local.py`/`compare_local.py` read the live
ladder variant from.

THE_WHOLE.md (Law 2, "Era truth is sourced, never typed") designs a single
live-ruleset record -- variant, GameVersion, GLORYVERSION, standing rule,
transform -- that every surface's banner should render from. That record
does not exist yet anywhere in this repo or on the platform (checked
2026-09-09: no file under docs/ holds it, and `coworld_manifest.json` names
variants but not which one is "live"). Until it lands, `LIVE_VARIANT` below
is the one place a beginner's local tooling names the ladder variant --
when the live-ruleset record ships, point this constant at it instead of
hand-editing the string.

Era stamp at the time this was set (2026-09-09): paintbot-v0.7.377,
GameVersion 62 / GLORYVERSION 17, on league `league_b8fa9b35` (Paintbot
Season 2). `uv run coworld leagues` lists the live league id and its
variant without login; `coworld download`'s own AGENTS.md tells you if the
Coworld snapshot you downloaded is older than what a league actually runs
-- read it before trusting a local result to predict a hosted one.
"""

from __future__ import annotations

#: The variant a beginner's local episode should run by default. Never
#: leave this blank: `run_local.py` refuses to run rather than let
#: `coworld run-episode` silently fall back to its own certification
#: fixture (a different map, different team count, same-looking output --
#: see docs/designs/JOURNEY_MAP.md J17).
LIVE_VARIANT: str = "battle-royale-s2"
