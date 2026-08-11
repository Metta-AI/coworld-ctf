#!/usr/bin/env python3
"""Hex campaign-board geometry and the campaign map DESIGN FIELDS.

Shared by `gen_campaign_maps.py` (terrain) and `campaign_puddles.py` (splats)
so the two scripts can never drift on what a cell is or where it sits.

The board is a HEXAGON of hexes inside a WxH bounding grid, pointy-top,
odd-r offset coordinates, cell ids "x,y", 6-way adjacency. `on_board` is a
line-for-line port of the backend's membership test
(app_backend/src/metta/app_backend/v2/campaign/engine.py::on_board) — cube
distance from the middle — so this module's idea of "a cell" is exactly the
server's. 16x16 carves 169 cells (radius 7), rows y=1..15.

THE DESIGN FIELDS, carried over from daveey's 10x10 square scripts:

- Mode zones by NEAREST ANCHOR (Voronoi), now measured in HEX distance.
  The square put 1v1 at the top-left corner, 2v2 at the top-right corner and
  ffa4 at the bottom-middle edge. The hexagon has the same three landmarks:
  its NW vertex, its NE vertex, and the middle of its bottom edge. See
  `zone_anchors`. NOTE this layer is a PROPOSAL, not the truth — the live
  board assigns modes itself (see `Board.from_snapshot`).
- A DENSITY GRADIENT: obstacle fill peaks at the board's centre and falls to
  the rim. On the hexagon `d` is hex-distance/radius, so it is exactly 0 at
  the middle cell and exactly 1 on every rim cell — cleaner than the square,
  where only the four corners reached 1.
- NEIGHBOUR SIMILARITY: fill comes from the density field and blobScale
  drifts with the axial coordinates, so adjacent cells look like relatives.
- PER-CELL DETERMINISM: every seed is a hash of the cell's coordinates.
"""

from __future__ import annotations

import json
import math
import zlib
from dataclasses import dataclass, field
from typing import Iterable, Iterator, Sequence

Cell = tuple[int, int]
Cube = tuple[int, int, int]

# Odd-r offset neighbour tables for a pointy-top hex board, copied from the
# backend's engine so adjacency means the same thing on both sides.
_HEX_EVEN_ROW = ((1, 0), (0, -1), (-1, -1), (-1, 0), (-1, 1), (0, 1))
_HEX_ODD_ROW = ((1, 0), (1, -1), (0, -1), (-1, 0), (0, 1), (1, 1))

MODES = ("1v1", "2v2", "ffa4")

# Symmetry per mode — unchanged from the square scripts. The map's team count
# follows from the symmetry (mapkit: rot90/quadmirror imply --teams 4), so this
# table is also the 2-team/4-team test the puddle stage relies on.
SYMMETRY = {"1v1": "mirror", "2v2": "rot180", "ffa4": "quadmirror"}
FOUR_TEAM_MODES = frozenset({"ffa4"})


def cell_id(x: int, y: int) -> str:
    return f"{x},{y}"


def parse_cell(cid: str) -> Cell:
    x, y = cid.split(",")
    return int(x), int(y)


def to_cube(x: int, y: int) -> Cube:
    """odd-r offset -> cube. Matches the backend's inline conversion."""
    q = x - (y - (y & 1)) // 2
    return (q, y, -q - y)


def from_cube(c: Cube) -> Cell:
    q, r, _ = c
    return (q + (r - (r & 1)) // 2, r)


def hex_distance(a: Cell, b: Cell) -> int:
    """Steps between two cells over 6-way adjacency — the distance the game
    itself cares about, and the one the backend measures membership with."""
    ca, cb = to_cube(*a), to_cube(*b)
    return max(abs(ca[0] - cb[0]), abs(ca[1] - cb[1]), abs(ca[2] - cb[2]))


def hex_pixel(x: int, y: int) -> tuple[float, float]:
    """Pointy-top pixel centre at unit size. Only ever used as a TIE-BREAK
    between two anchors that are the same number of hex steps away: hex
    distance is coarse and would otherwise hand every tied cell to whichever
    mode sorts first, skewing the two 2-team zones against each other."""
    return (math.sqrt(3.0) * (x + 0.5 * (y & 1)), 1.5 * y)


@dataclass(frozen=True)
class Board:
    """The bounding grid plus its shape. `cells` is the carved board."""

    width: int = 16
    height: int = 16
    shape: str = "hex"
    # cid -> {"mode", "map_ref", "map_size", "blob_anchor", "agents"}; empty
    # when the board is a pure design proposal rather than a live snapshot.
    cells: dict[str, dict] = field(default_factory=dict)

    # --- membership: a line-for-line port of engine.on_board ---------------
    def on_board(self, x: int, y: int) -> bool:
        if not (0 <= x < self.width and 0 <= y < self.height):
            return False
        if self.shape == "square":
            return True
        r = (min(self.width, self.height) - 1) // 2
        cx, cy = self.width // 2, self.height // 2
        dx = (x - (y - (y & 1)) // 2) - (cx - (cy - (cy & 1)) // 2)
        dz = y - cy
        return max(abs(dx), abs(dz), abs(dx + dz)) <= r

    @property
    def radius(self) -> int:
        return (min(self.width, self.height) - 1) // 2

    @property
    def centre(self) -> Cell:
        return (self.width // 2, self.height // 2)

    def coords(self) -> list[Cell]:
        return [
            (x, y)
            for y in range(self.height)
            for x in range(self.width)
            if self.on_board(x, y)
        ]

    def ids(self) -> list[str]:
        return [cell_id(x, y) for x, y in self.coords()]

    def neighbors(self, x: int, y: int) -> Iterator[Cell]:
        deltas = _HEX_ODD_ROW if y & 1 else _HEX_EVEN_ROW
        if self.shape == "square":
            deltas = ((1, 0), (-1, 0), (0, 1), (0, -1))
        for dx, dy in deltas:
            if self.on_board(x + dx, y + dy):
                yield (x + dx, y + dy)

    # --- arenas: one map per BLOB, not per cell ---------------------------
    def anchor_of(self, cid: str) -> str:
        """The cell that owns this one's arena. On the live hex board a
        territory is a multi-hex FOOTPRINT (a 'blob') whose hexes all play the
        SAME arena, so a map is generated once per anchor and pinned to every
        member. A board with no blobs is every-cell-its-own-anchor, exactly
        like the old square board."""
        return (self.cells.get(cid) or {}).get("blob_anchor") or cid

    def anchors(self) -> list[str]:
        if not self.cells:
            return self.ids()
        return sorted(
            (cid for cid in self.cells if self.anchor_of(cid) == cid),
            key=parse_cell,
        )

    def members_of(self, anchor: str) -> list[str]:
        if not self.cells:
            return [anchor]
        return sorted(
            (cid for cid in self.cells if self.anchor_of(cid) == anchor),
            key=parse_cell,
        )

    # --- mode: the live board's answer, else the design proposal ----------
    def board_mode(self, cid: str) -> str | None:
        return (self.cells.get(cid) or {}).get("mode")

    def mode_for(self, cid: str, source: str = "board") -> str:
        """`source="board"` trusts the live board's own mode assignment (the
        default, and the only safe choice for pinning maps onto a running
        league: a 2-team spec on a 4-team cell would shift seats under the
        geometry). `source="voronoi"` uses the design's zone scheme."""
        if source == "board":
            mode = self.board_mode(cid)
            if mode is None:
                raise KeyError(f"cell {cid} not in the board snapshot")
            return mode
        return zone_mode(self, *parse_cell(cid))

    def map_size(self, cid: str, default: str = "standard") -> str:
        return (self.cells.get(cid) or {}).get("map_size") or default

    # --- io ---------------------------------------------------------------
    @classmethod
    def from_snapshot(cls, path) -> "Board":
        raw = json.loads(open(path).read())
        return cls(
            width=raw["width"],
            height=raw["height"],
            shape=raw.get("shape", "hex"),
            cells=raw["cells"],
        )

    def to_snapshot(self) -> dict:
        return {
            "width": self.width,
            "height": self.height,
            "shape": self.shape,
            "cells": self.cells,
        }


# --- mode zones: Voronoi by nearest anchor, in HEX distance -----------------


def zone_anchors(board: Board) -> dict[str, list[Cell]]:
    """The three landmarks the square design used, re-read on a hexagon.

    Square:  1v1 (0,0) top-left corner, 2v2 (9,0) top-right corner,
             ffa4 (4.5,9) the middle of the bottom edge.
    Hexagon: 1v1 the NW vertex, 2v2 the NE vertex, ffa4 the middle of the
             bottom edge — the same three landmarks, and the same reading
             (duels upper-left, pairs upper-right, four-ways along the
             bottom). The bottom-edge midpoint falls between two cells on an
             even-width edge, exactly as the square's 4.5 did, so that anchor
             is a PAIR and its distance is the distance to the nearer of them.
    """
    if board.shape == "square":
        w, h = board.width - 1, board.height - 1
        return {
            "1v1": [(0, 0)],
            "2v2": [(w, 0)],
            "ffa4": [(w // 2, h), (w - w // 2, h)],
        }
    cx, cy = board.centre
    c = to_cube(cx, cy)
    r = board.radius

    def vertex(d: Cube) -> Cell:
        return from_cube((c[0] + d[0] * r, c[1] + d[1] * r, c[2] + d[2] * r))

    nw = vertex((0, -1, 1))
    ne = vertex((1, -1, 0))
    bottom_row = cy + r
    xs = sorted(x for x, y in board.coords() if y == bottom_row)
    mid = [(xs[(len(xs) - 1) // 2], bottom_row), (xs[len(xs) // 2], bottom_row)]
    return {"1v1": [nw], "2v2": [ne], "ffa4": mid}


def zone_mode(board: Board, x: int, y: int) -> str:
    """Nearest anchor wins. Primary metric is HEX distance (the game's own
    metric); ties break on straight-line pixel distance so the two 2-team
    zones stay balanced across the board's mirror axis, then on mode name so
    the result is fully deterministic."""
    anchors = zone_anchors(board)

    def key(mode: str) -> tuple:
        pts = anchors[mode]
        return (
            min(hex_distance((x, y), p) for p in pts),
            round(min(math.dist(hex_pixel(x, y), hex_pixel(*p)) for p in pts), 6),
            mode,
        )

    return min(anchors, key=key)


# --- the density gradient ---------------------------------------------------


def density_norm(board: Board, x: int, y: int) -> float:
    """0.0 at the board's centre (densest) .. 1.0 on the rim (sparsest).

    On the hexagon this is hex-distance / radius, so every rim cell is exactly
    1.0 and the middle cell is exactly 0.0. The square version normalised a
    Euclidean distance by the corner distance, which left the edge MIDPOINTS
    short of 1.0; the hex field is the same idea with the ragged edge removed.
    """
    if board.shape == "square":
        cx, cy = (board.width - 1) / 2.0, (board.height - 1) / 2.0
        dmax = math.dist((0.0, 0.0), (cx, cy))
        return min(1.0, math.dist((x, y), (cx, cy)) / dmax)
    return min(1.0, hex_distance((x, y), board.centre) / board.radius)


def axial_norm(board: Board, x: int, y: int) -> tuple[float, float]:
    """The cell's axial coordinates rescaled to 0..1 across the board — the
    hex stand-in for the square's `x/9` and `y/9` drift terms."""
    if board.shape == "square":
        return (x / max(board.width - 1, 1), y / max(board.height - 1, 1))
    c = to_cube(*board.centre)
    cq, cr, _ = to_cube(x, y)
    r = board.radius
    return ((cq - c[0] + r) / (2.0 * r), (cr - c[1] + r) / (2.0 * r))


def params_for(board: Board, x: int, y: int, mode: str) -> dict:
    """Style parameters for one cell: fill from the density field, blobScale
    drifting with the axial coordinates so neighbours stay relatives.

    NOTE, carried over verbatim from the square script: never vary `cell`.
    Some values (e.g. 44) systematically break the caves style's sightline
    anchors and no seed validates. (The square script's docstring claimed cave
    cell size drifted with y; its code did not, and neither does this.)
    """
    d = density_norm(board, x, y)
    qn, rn = axial_norm(board, x, y)
    if mode == "ffa4":
        # Quad-mirror boards: the small quadrant CA grid is bistable at the
        # default birth/death — loosen thresholds so organic blobs survive,
        # and run a fill band tuned to the tighter cover/route budget.
        return {
            "fillProb": round(0.26 + (1.0 - d) * 0.08, 3),
            "birth": 4,
            "death": 3,
            "blobScale": 0.55,
        }
    return {
        "fillProb": round(0.17 + (1.0 - d) * 0.14, 3),  # 0.17 rim .. 0.31 centre
        "blobScale": round(0.46 + 0.06 * qn + 0.03 * rn, 3),
    }


def features_for(board: Board, x: int, y: int, mode: str) -> list[str]:
    """Trench + glass flags. 2-team maps carry generous trenches and glass
    (scaled with the density field); trenches never place on 4-team maps, and
    quads keep the default glass draw."""
    if mode == "ffa4":
        return []
    d = density_norm(board, x, y)
    pits = 4 + round(8 * (1.0 - d))      # 4 at the rim .. 12 mid-board
    windows = 3 + round(3 * (1.0 - d))   # 3 .. 6
    return ["--pits", str(pits), "--windows", str(windows)]


def base_seed(x: int, y: int) -> int:
    """Deterministic in the cell's coordinates — unchanged from the square
    script, so a cell that keeps its coordinates keeps its terrain family."""
    return zlib.crc32(f"paintbot-campaign:{x},{y}".encode()) % 100_000


def puddle_seed(x: int, y: int) -> int:
    return zlib.crc32(f"paintbot-puddles:{x},{y}".encode()) % 100_000


# --- the puddle gradient ----------------------------------------------------

PUDDLE_PEAK = 12
# STEP is the re-derivation the hexagon forces. The square walked CHEBYSHEV
# rings across two SOLID 2-team zones and puddled 32 of its 52 two-team cells
# (62%) with 176 splats. On the live hex board the 2-team ground is not a zone
# at all — it is the tic-tac-toe LINES, threaded across the whole hexagon — so
# a 2-ring reach from two origins touches almost none of it (7 arenas, 12%).
# Halving the step keeps the design's shape (a peak at each origin, falling by
# ring, counts always EVEN so splats read as scattered pairs) while restoring
# its REACH: 23 arenas, 40%, 146 splats. `--puddle-step 4` reproduces the
# square's literal constant.
PUDDLE_STEP = 2


def puddle_origins(board: Board) -> list[Cell]:
    """One origin per 2-team zone, up near the two top corners — the square
    used (1,1) and (8,1), a step in from its (0,0)/(9,0) corners so the
    5x5 Chebyshev block stayed on the board. The hexagon's NW and NE vertices
    are already cells (the square's corners were the grid's outer corner
    POINTS), so the anchors serve as origins directly. On the live board both
    of them land on 1v1 ground, which is what the gradient needs."""
    anchors = zone_anchors(board)
    return [anchors["1v1"][0], anchors["2v2"][0]]


def puddle_count(
    board: Board,
    x: int,
    y: int,
    mode: str,
    peak: int = PUDDLE_PEAK,
    step: int = PUDDLE_STEP,
    origins: Sequence[Cell] | None = None,
) -> int:
    """PEAK at an origin, minus STEP per HEX ring, floored at 0 — and always 0
    on a 4-team map, whatever the distance says.

    The zero on 4-team maps is not a preference. The sim raises
    `puddles never place on 4-team maps` (src/ctf/arena.nim) rather than
    placing them, so an ffa4 cell with a non-zero count would abort the patch.
    """
    if mode in FOUR_TEAM_MODES:
        return 0
    pts = list(origins) if origins is not None else puddle_origins(board)
    d = min(hex_distance((x, y), o) for o in pts)
    return max(0, peak - step * d)


# --- pretty-printing --------------------------------------------------------

_GLYPH = {"1v1": "1", "2v2": "2", "ffa4": "4"}


def render_board(board: Board, value, width: int = 2) -> str:
    """One text row per board row; off-board positions print as dots."""
    out = []
    for y in range(board.height):
        row = []
        for x in range(board.width):
            if not board.on_board(x, y):
                row.append(".".rjust(width))
                continue
            row.append(str(value(x, y)).rjust(width))
        out.append("  " + " ".join(row))
    return "\n".join(out)


def mode_glyph(mode: str) -> str:
    return _GLYPH.get(mode, "?")
