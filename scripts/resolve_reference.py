#!/usr/bin/env python3
"""Reference implementation of the surf-etiquette team-color resolution
algorithm specified in docs/COLOR_CONTRACT.md (SS3 resolution, SS4
provenance, SS5 payload composition / distinctness pass).

This is a CURATION-SIDE artifact, not server code: it exists so the
platform team (softmax.com) can prove their implementation matches the
spec in this repo without reading our Nim. stdlib only.

Public API:

    resolve(claimants, palette) -> grants
        SS3. claimants: [{"player": str, "standing": number,
        "requested_slug": str}, ...]. `standing` is bigger-is-better
        (this repo's league runs Elo, where a higher number is a better
        standing -- see SS3's own wording, "the higher-standing player").
        palette: the {"version": int, "colors": [{"slug","wire",...}]}
        shape from data/team_palette.json (only "slug" is read).
        Returns {player: {"requested", "granted", "takenBy"}} per SS4.

    compose_payload(grants, episode_teams, palette=None, palette_version=None,
                     shimmer=None) -> payload
        SS5. grants: output of resolve() (or an equivalently
        globally-unique grant map). episode_teams: {wire_word: {
        "claimant": player_id | None}} for exactly the wire words live
        in one episode (2 or 4 keys). shimmer: an optional single,
        already seat-suffix-stripped policy name -- the #1-ranked
        player in the whole lobby/league, if and only if that player is
        currently flagged for the shimmer treatment. There is at most
        ONE shimmering identity in existence at a time (not one per
        team); most episodes carry none, since the #1-ranked player
        usually isn't even in a given match, and shimmer is omitted
        (None) in that case. The name is stamped verbatim at the
        payload root -- compose_payload does NOT check whether it
        matches any claimant/grant in episode_teams, so a root shimmer
        naming a policy absent from this episode is normal, not an
        error.
        Returns the {"v": 1, "palette": N, "shimmer": name?, "teams":
        {...}} payload, including the SS5 distinctness pass for
        unclaimed teams whose stock slug collides with a grant (or with
        another unclaimed team's already-bumped slug) elsewhere in the
        same payload.

Run this file directly to execute tests/resolver_vectors.json as a
self-check:

    python3 scripts/resolve_reference.py

Exits 0 if every vector (and every derived determinism/byte-for-byte
check) passes, 1 otherwise. Prints one PASS/FAIL line per vector.
"""
from __future__ import annotations

import base64
import json
import sys
from pathlib import Path
from typing import Any, Optional

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PALETTE_PATH = REPO_ROOT / "data" / "team_palette.json"
VECTORS_PATH = REPO_ROOT / "tests" / "resolver_vectors.json"

# Canonical wire-word order. Also the order SS2 freezes for the first
# four palette entries ("in wire order"), reused here (see report /
# module docstring on compose_payload) as the deterministic processing
# order for the SS5 distinctness pass when more than one unclaimed team
# needs to walk in the same payload -- a case SS5's prose doesn't
# specify an order for.
WIRE_ORDER = ["red", "blue", "green", "yellow"]


def _slug_order(palette: dict) -> list[str]:
    return [c["slug"] for c in palette["colors"]]


def load_default_palette() -> dict:
    with DEFAULT_PALETTE_PATH.open() as f:
        return json.load(f)


def resolve(claimants: list[dict], palette: dict) -> dict[str, dict]:
    """SS3 resolve(claimants, palette).

    Sort claimants by standing (bigger = better), lexicographic
    player-id tiebreak, and walk each one, in that order, from its
    requested slug forward (wrapping) to the first free slug. Once all
    palette slots are taken, every remaining claimant is granted null
    with a full-palette walk (SS3's "more claimants than slugs" branch).
    """
    slugs = _slug_order(palette)
    n = len(slugs)

    ordered = sorted(claimants, key=lambda c: (-c["standing"], c["player"]))

    taken: dict[str, str] = {}       # slug -> player who holds it
    grants: dict[str, dict] = {}     # player -> provenance record (SS4)

    for c in ordered:
        player = c["player"]
        requested = c["requested_slug"]

        if len(taken) == n:
            # SS3: "more claimants than slugs: everyone past the 8th
            # keeps stock colors". The doc's pseudocode calls
            # walk_of_all_slugs(taken) with no start-index argument,
            # which is ambiguous about where the full walk begins (see
            # module report). This reference starts at the claimant's
            # own requested slug and reports the full cycle, so the
            # provenance record still reads as "here's what you asked
            # for, and here's who already owns everything" rather than
            # an unrelated array dump.
            start = slugs.index(requested)
            walk = [
                {"slug": slugs[(start + step) % n], "by": taken[slugs[(start + step) % n]]}
                for step in range(n)
            ]
            grants[player] = {"requested": requested, "granted": None, "takenBy": walk}
            continue

        i = slugs.index(requested)
        walk = []
        while slugs[i] in taken:
            walk.append({"slug": slugs[i], "by": taken[slugs[i]]})
            i = (i + 1) % n
        granted = slugs[i]
        taken[granted] = player
        grants[player] = {"requested": requested, "granted": granted, "takenBy": walk}

    return grants


def compose_payload(
    grants: dict[str, dict],
    episode_teams: dict[str, dict],
    palette: Optional[dict] = None,
    palette_version: Optional[int] = None,
    shimmer: Optional[str] = None,
) -> dict:
    """SS5 compose_payload(grants, episode_teams, shimmer=None).

    `palette` / `palette_version` are reference-implementation
    conveniences, not part of the three-argument SS5 signature: the
    algorithm still needs *some* copy of the slug array (to know
    walk/wrap order) and the version number to stamp into the payload,
    so they default to loading data/team_palette.json when omitted.

    episode_teams keys are wire team words for exactly the teams live in
    this episode (2 for a 2-team mode, 4 for a 4-team mode); a key
    absent from episode_teams is simply absent from the output payload
    too -- SS5's own graceful-omission rule ("missing team key => that
    team keeps stock") makes this equivalent to sending it explicitly at
    stock, so the leaner form is used here.

    `shimmer` is a payload-ROOT concern, not a per-team one: there is
    exactly one shimmering policy identity in the entire lobby/league
    (the #1 ranked player) or none at all. Per-team shimmer keys do not
    exist in this schema. Pass the seat-suffix-stripped policy name to
    stamp it at the root, or leave it None (the common case -- most
    episodes don't include the #1 player) to omit the key entirely.
    """
    palette = palette or load_default_palette()
    slugs = _slug_order(palette)
    n = len(slugs)
    version = palette_version if palette_version is not None else palette.get("version")

    # Pass 1: claimed teams lock to their grant. Unclaimed teams default
    # to their stock slug, which for the four canonical wire words is
    # the word itself (SS1: "the identity mapping ... is a no-op").
    locked_slugs: set[str] = set()
    info: dict[str, dict] = {}
    for wire_word, team_in in episode_teams.items():
        claimant = team_in.get("claimant")
        grant = grants.get(claimant) if claimant else None
        if grant is not None and grant.get("granted") is not None:
            slug = grant["granted"]
            locked = True
            locked_slugs.add(slug)
        else:
            slug = wire_word
            locked = False
        info[wire_word] = {"slug": slug, "locked": locked}

    # Pass 2: distinctness (SS5). Walk each unclaimed team whose slug
    # collides with something already spoken for in this payload.
    # Explicit grants never move. Processing order for >1 unclaimed team
    # is the WIRE_ORDER convention documented above; each resolution
    # feeds the "taken" set for the next, so a team's *bumped* slug can
    # in turn collide with a later unclaimed team's stock default (see
    # the cascading-collision golden vector).
    taken: set[str] = set(locked_slugs)
    ordered_words = [w for w in WIRE_ORDER if w in episode_teams]
    ordered_words += [w for w in episode_teams if w not in WIRE_ORDER]

    for wire_word in ordered_words:
        rec = info[wire_word]
        if rec["locked"]:
            continue
        slug = rec["slug"]
        if slug in taken:
            i = slugs.index(slug)
            i = (i + 1) % n
            while slugs[i] in taken:
                i = (i + 1) % n
            slug = slugs[i]
            rec["slug"] = slug
        taken.add(slug)

    teams_out: dict[str, dict] = {}
    for wire_word in episode_teams:
        rec = info[wire_word]
        teams_out[wire_word] = {"slug": rec["slug"]}

    payload: dict[str, Any] = {"v": 1}
    if version is not None:
        payload["palette"] = version
    if shimmer:
        payload["shimmer"] = shimmer
    payload["teams"] = teams_out
    return payload


# --------------------------------------------------------------------------
# Self-check runner
# --------------------------------------------------------------------------

# Worked example for the corrected (2026-08) shimmer rule: shimmer is a
# single root-level policy name (the #1-ranked player in the whole
# lobby/league, or nobody), never a per-team key. This literal was
# computed and round-tripped independently in this repo (minify ->
# base64 -> decode -> reparse -> compare) rather than copied from
# docs/COLOR_CONTRACT.md SS5, whose §5 prose is being rewritten
# concurrently by another agent in a different worktree as of this
# writing -- see the module report for the exact bytes so that doc's
# author can cross-check against them independently.
DOC_SS5_EXAMPLE_JSON = (
    '{"v":1,"palette":1,"shimmer":"picasso","teams":{"red":{"slug":"orange"},'
    '"blue":{"slug":"teal"}}}'
)
DOC_SS5_EXAMPLE_B64 = (
    "eyJ2IjoxLCJwYWxldHRlIjoxLCJzaGltbWVyIjoicGljYXNzbyIsInRlYW1zIjp7InJlZCI6"
    "eyJzbHVnIjoib3JhbmdlIn0sImJsdWUiOnsic2x1ZyI6InRlYWwifX19"
)
# Name of the vector expected to reproduce that exact example (checked
# by name below so the doc cross-check runs against the golden vector,
# not a hand-rolled duplicate).
DOC_SS5_VECTOR_NAME = "compose-root-shimmer-present"


def _print_diff(label: str, expected: Any, got: Any) -> None:
    print(f"         {label} expected: {json.dumps(expected, sort_keys=False)}")
    print(f"         {label} got:      {json.dumps(got, sort_keys=False)}")


def run_vectors(path: Path = VECTORS_PATH) -> bool:
    with path.open() as f:
        vectors = json.load(f)

    all_ok = True

    for v in vectors:
        name = v["name"]
        op = v["input"]["op"]
        ok = True
        notes = []

        try:
            if op == "resolve":
                palette = v["input"]["palette"]
                claimants = v["input"]["claimants"]
                want = v["expected"]["grants"]

                got = resolve(claimants, palette)
                if got != want:
                    ok = False
                    _print_diff("grants", want, got)

                # Determinism (SS3 "re-running with the same inputs
                # gives the same outputs", generalized here to "input
                # array order never affects the result" -- see report).
                got_rev = resolve(list(reversed(claimants)), palette)
                if got_rev != got:
                    ok = False
                    notes.append("reversed-input-order produced a different result")
                    _print_diff("reversed-order grants", got, got_rev)

            elif op == "compose_payload":
                palette = v["input"]["palette"]
                grants = v["input"]["grants"]
                episode_teams = v["input"]["episode_teams"]
                shimmer = v["input"].get("shimmer")
                want = v["expected"]["payload"]

                got = compose_payload(grants, episode_teams, palette=palette, shimmer=shimmer)
                if got != want:
                    ok = False
                    _print_diff("payload", want, got)

                if name == DOC_SS5_VECTOR_NAME:
                    minified = json.dumps(got, separators=(",", ":"))
                    if minified != DOC_SS5_EXAMPLE_JSON:
                        ok = False
                        notes.append("minified JSON does not match SS5 doc example byte-for-byte")
                        _print_diff("minified", DOC_SS5_EXAMPLE_JSON, minified)
                    b64 = base64.b64encode(minified.encode("utf-8")).decode("ascii")
                    if b64 != DOC_SS5_EXAMPLE_B64:
                        ok = False
                        notes.append("base64 does not match SS5 doc example byte-for-byte")
                        _print_diff("base64", DOC_SS5_EXAMPLE_B64, b64)

            else:
                ok = False
                notes.append(f"unknown op {op!r}")

        except Exception as exc:  # noqa: BLE001 - surface any vector failure, don't crash the run
            ok = False
            notes.append(f"EXCEPTION: {exc!r}")

        status = "PASS" if ok else "FAIL"
        suffix = f" -- {'; '.join(notes)}" if notes else ""
        print(f"[{status}] {name}{suffix}")

        if not ok:
            all_ok = False

    return all_ok


def main() -> int:
    ok = run_vectors()
    print()
    print("ALL VECTORS PASSED" if ok else "SOME VECTORS FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
