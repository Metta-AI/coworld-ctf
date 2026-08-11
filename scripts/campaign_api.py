#!/usr/bin/env python3
"""Observatory API access for the campaign map scripts.

Split out of the scripts so that reading production and WRITING to it are
visibly different calls. Everything above `upload_cell_map` is read-only;
`upload_cell_map` is the one function that changes the live league, and the
scripts only reach it behind an explicit `--apply` flag.

Needs the team token in ~/.softmax/credentials.yaml plus elevated-privileges
team auth; a custom User-Agent dodges Cloudflare's urllib block.
"""

from __future__ import annotations

import base64
import json
import urllib.request
from pathlib import Path

API = "https://softmax.com/api/observatory"
LEAGUE = "b8fa9b35-ac22-48cf-a03f-07b397aff1c7"


def token() -> str:
    import yaml

    creds = yaml.safe_load(open(Path.home() / ".softmax/credentials.yaml"))
    return creds["tokens"]["https://softmax.com/api"]


def api_call(path: str, payload: dict) -> dict:
    req = urllib.request.Request(
        f"{API}{path}",
        data=json.dumps(payload).encode(),
        headers={
            "Authorization": f"Bearer {token()}",
            "X-Use-Elevated-Privileges": "true",
            "Content-Type": "application/json",
            # Cloudflare 403s urllib's default UA.
            "User-Agent": "coworld-ctf-campaign-maps",
        },
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())


def sql(query: str) -> list[list]:
    return api_call("/sql/query", {"query": query})["rows"]


# --- read-only --------------------------------------------------------------


def fetch_board(league: str = LEAGUE) -> dict:
    """A snapshot of the live board: geometry from the league's campaign
    settings, and every cell's mode / variant / size / blob anchor.

    This is the file the generator keys off, so a dry run is reproducible and
    reviewable offline and nothing has to be guessed about the live board."""
    (settings,) = sql(f"SELECT settings FROM leagues WHERE id = '{league}'")
    board = ((settings[0] or {}).get("campaign") or {}).get("board") or {}
    rows = sql(
        "SELECT key, value->>'mode', value->>'map_ref', value->>'map_size', "
        "value->>'blob_anchor', value->>'agents', value->>'blob_id', "
        "(value ? 'map_spec')::text, value->>'preview_url' "
        "FROM leagues, jsonb_each(commissioner_state->'cells') AS c(key, value) "
        f"WHERE id = '{league}' ORDER BY key"
    )
    cells = {}
    for key, mode, ref, size, anchor, agents, blob, pinned, preview in rows:
        cells[key] = {
            "mode": mode,
            "map_ref": ref,
            "map_size": size,
            "blob_anchor": anchor,
            "agents": int(agents) if agents else None,
            "blob_id": blob,
            "pinned": pinned == "true",
            "preview_url": preview,
        }
    return {
        "width": board.get("width", 16),
        "height": board.get("height", 16),
        "shape": board.get("board_shape", "hex"),
        "mode_layout": board.get("mode_layout"),
        "mode_mix": board.get("mode_mix"),
        "cells": cells,
    }


def fetch_pinned_specs(cells: list[str], league: str = LEAGUE) -> dict[str, dict]:
    """The map_spec already pinned on each named cell (missing keys = unpinned)."""
    if not cells:
        return {}
    keys = ", ".join(f"'{c}'" for c in cells)
    rows = sql(
        "SELECT key, value->'map_spec' "
        "FROM leagues, jsonb_each(commissioner_state->'cells') AS c(key, value) "
        f"WHERE id = '{league}' AND key IN ({keys}) AND value ? 'map_spec'"
    )
    return {
        key: (json.loads(spec) if isinstance(spec, str) else spec)
        for key, spec in rows
        if spec
    }


def count_pinned(league: str = LEAGUE) -> tuple[int, int]:
    """(cells carrying a pinned map_spec, total cells)."""
    (row,) = sql(
        "SELECT count(*) FILTER (WHERE value ? 'map_spec'), count(*) "
        "FROM leagues, jsonb_each(commissioner_state->'cells') AS c(key, value) "
        f"WHERE id = '{league}'"
    )
    return int(row[0]), int(row[1])


# --- the ONLY write ---------------------------------------------------------


def upload_cell_map(
    cell: str, spec: dict, png: bytes | None, league: str = LEAGUE
) -> dict:
    """Pin one cell's map_spec (+ hover preview) on the LIVE league.

    Callers must gate this behind an explicit operator flag. The endpoint
    rejects the pin if the coworld's config schema does not declare `mapSpec`,
    and drops the cell's `map_size` because pinned geometry replaces it.
    """
    payload: dict = {"cell": cell, "map_spec": spec}
    if png is not None:
        payload["preview_png_base64"] = base64.b64encode(png).decode()
    return api_call(f"/v2/leagues/league_{league}/campaign/cell-map", payload)
