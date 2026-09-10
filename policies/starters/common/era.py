"""The named constants `run_local.py`/`compare_local.py` read the live
ladder variant and engine stamp from.

THE_WHOLE.md (Law 2, "Era truth is sourced, never typed") designs a single
live-ruleset record that every surface's banner should render from. That
record is `docs/wiki/_era.md` (landed by #513) -- variant, build tag,
GameVersion, GLORYVERSION, standing rule, transform, all in one place.

This module MIRRORS that record rather than deriving from it at import
time: a beginner's copy of `policies/starters/` is its own standalone
project (see pyproject.toml's `[tool.uv]` comment) and does not ship
`docs/`, so `era.py` cannot reliably find `docs/wiki/_era.md` on disk at
runtime. Instead, `policies/starters/common/test_era.py` parses
`docs/wiki/_era.md` from the monorepo checkout and asserts the literals
below still match it -- that test is wired into CI (`era-tripwire` in
.github/workflows/build.yml) so the two files cannot drift silently.

**`docs/wiki/_era.md` is authoritative.** If you are bumping GameVersion,
GLORYVERSION, the build tag, or the live variant: edit `_era.md` first,
then copy the same values down here. Editing only one file is exactly the
drift `test_era.py` exists to catch.

Era stamp mirrored here (as of `docs/wiki/_era.md` dated 2026-09-09):
paintbot-v0.7.377, GameVersion 62 / GLORYVERSION 17, on league
`league_b8fa9b35` (Paintbot Season 2). `uv run coworld leagues` lists the
live league id and its variant without login; `coworld download`'s own
AGENTS.md tells you if the Coworld snapshot you downloaded is older than
what a league actually runs -- read it before trusting a local result to
predict a hosted one.
"""

from __future__ import annotations

#: The variant a beginner's local episode should run by default. Never
#: leave this blank: `run_local.py` refuses to run rather than let
#: `coworld run-episode` silently fall back to its own certification
#: fixture (a different map, different team count, same-looking output --
#: see docs/designs/JOURNEY_MAP.md J17).
LIVE_VARIANT: str = "battle-royale-s2"

#: Mirrors `docs/wiki/_era.md`'s **Build tag**.
BUILD_TAG: str = "paintbot-v0.7.377"

#: Mirrors `docs/wiki/_era.md`'s **GameVersion**.
GAME_VERSION: int = 62

#: Mirrors `docs/wiki/_era.md`'s **GLORYVERSION**.
GLORY_VERSION: int = 17
