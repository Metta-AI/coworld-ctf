"""Fetch a platform policy artifact and seat it on OUR local server.

The lobby any-policy picker promises: search a policy version you own on the
platform, then seat it in a lobby on our self-hosted server. This module is the
dependency that makes that promise checkable — it resolves a platform reference
to a concrete artifact, decides whether the artifact is *actually* runnable
here, caches it, and drives it onto a slot.

The load-bearing part is the ENGINE GATE. Our server and a policy artifact
exchange NO version handshake (see docs/POLICY_ARTIFACTS.md §4) — a bot built
against a different GameVersion connects happily and plays garbage that looks
exactly like data. So compatibility can never be discovered at runtime; it has
to be established before the process starts, from provenance, and a version we
cannot establish is REFUSED rather than assumed.

Run with the cogherence player's venv, which holds the working login:
  ~/projects/coworld-players/coworld-cogherence-player/.venv/bin/python
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

import httpx

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "tools" / "ladder"))

PUBLIC_API = "https://softmax.com/api/observatory"
CACHE_ROOT = Path(os.environ.get("CTF_POLICY_CACHE", Path.home() / ".ctf" / "policy-cache"))

# GameVersion has moved between modules across history (the 2026-08 sim split
# pulled the consts out of sim.nim). Probe in most-recent-location-first order
# and take the first hit, or a commit from either era resolves to None and gets
# refused for the wrong reason.
GAME_VERSION_FILES = ("src/ctf/sim_types.nim", "src/ctf/sim.nim")
GAME_VERSION_RE = re.compile(r'GameVersion\*?\s*=\s*"([^"]*)"')
COMMIT_RE = re.compile(r"/tree/([0-9a-f]{7,40})")


# --------------------------------------------------------------------------
# Engine identity
# --------------------------------------------------------------------------

def local_game_version(repo: Path = REPO_ROOT) -> str:
    """The GameVersion our locally-built server actually runs.

    Read from the working tree, not from git HEAD: the server binary is built
    from the tree, so an uncommitted bump has to count.
    """
    for rel in GAME_VERSION_FILES:
        path = repo / rel
        if not path.exists():
            continue
        m = GAME_VERSION_RE.search(path.read_text(encoding="utf-8", errors="replace"))
        if m:
            return m.group(1)
    raise RuntimeError(
        f"Could not find GameVersion in any of {GAME_VERSION_FILES} under {repo}. "
        "The engine gate cannot run without knowing our own engine version."
    )


def _git(repo: Path, *args: str, timeout: float = 180.0) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True, text=True, timeout=timeout,
    )


def commit_game_version(sha: str, repo: Path = REPO_ROOT) -> str | None:
    """GameVersion at a pinned commit, fetching the object if we lack it.

    Coworld artifacts pin the commit they were built from, so this turns a
    build-provenance URL into the exact engine version — no guessing from
    timestamps.
    """
    for attempt in range(2):
        for rel in GAME_VERSION_FILES:
            got = _git(repo, "cat-file", "-p", f"{sha}:{rel}")
            if got.returncode == 0:
                m = GAME_VERSION_RE.search(got.stdout)
                if m:
                    return m.group(1)
        if attempt == 0:
            # Coworld builds pin PR-head commits that are often not ancestors of
            # main, so a plain `git fetch` will not have them; ask for the one
            # object by name.
            try:
                _git(repo, "fetch", "origin", sha, timeout=180.0)
            except subprocess.TimeoutExpired:
                return None
    return None


# --------------------------------------------------------------------------
# Platform resolution
# --------------------------------------------------------------------------

@dataclass
class Artifact:
    """Everything the picker needs to show truthful availability for one ref."""
    ref: str
    kind: str                      # "coworld_player" | "policy_version"
    name: str
    version: str
    platform_id: str
    image: str | None = None       # digest-pinned, docker-pullable
    run: list[str] = field(default_factory=list)
    env: dict[str, str] = field(default_factory=dict)
    source_url: str | None = None
    source_commit: str | None = None
    engine_game_version: str | None = None
    engine_evidence: str = "none"  # how we learned it — never guess silently
    fetchable: bool = False
    fetch_blocker: str | None = None
    extra: dict[str, Any] = field(default_factory=dict)

    @property
    def cache_key(self) -> str:
        return hashlib.sha256(self.ref.encode()).hexdigest()[:16]

    @property
    def cache_dir(self) -> Path:
        return CACHE_ROOT / self.cache_key


def _public_get(path: str) -> Any:
    r = httpx.get(f"{PUBLIC_API}{path}", timeout=120.0, follow_redirects=True)
    r.raise_for_status()
    return r.json()


def _authed():
    import ctfapi  # noqa: PLC0415 — needs the venv's login, imported lazily
    return ctfapi.client()


def _authed_get(path: str, **params: Any) -> tuple[int, Any]:
    c, h = _authed()
    r = c._http_client.get(path, headers=h, params=params, timeout=90.0)
    ct = r.headers.get("content-type", "")
    return r.status_code, (r.json() if ct.startswith("application/json") else r.text[:400])


def _commit_from_source_url(url: str | None) -> str | None:
    if not url:
        return None
    m = COMMIT_RE.search(url)
    return m.group(1) if m else None


def resolve_coworld_player(cow_id: str, player_id: str | None = None) -> Artifact:
    """A coworld-bundled player: public, digest-pinned, commit-attributed.

    This endpoint needs no auth and resolves the manifest's internal image ids
    to public registry URIs — it is the only path on the platform that hands
    out a pullable address for a runnable.
    """
    doc = _public_get(f"/v2/coworlds/{cow_id}")
    manifest = doc["manifest"]
    players = manifest.get("player") or []
    if not players:
        raise RuntimeError(f"Coworld {cow_id} bundles no player runnables")
    entry = next((p for p in players if p.get("id") == player_id), None) if player_id else players[0]
    if entry is None:
        have = [p.get("id") for p in players]
        raise RuntimeError(f"Coworld {cow_id} has no player '{player_id}'; has {have}")

    commit = _commit_from_source_url(entry.get("source_url"))
    gv = commit_game_version(commit) if commit else None
    image = entry.get("image")
    return Artifact(
        ref=f"cw:{cow_id}#{entry.get('id')}",
        kind="coworld_player",
        name=f"{doc['name']}/{entry.get('id')}",
        version=str(doc["version"]),
        platform_id=cow_id,
        image=image,
        run=list(entry.get("run") or []),
        env=dict(entry.get("env") or {}),
        source_url=entry.get("source_url"),
        source_commit=commit,
        engine_game_version=gv,
        engine_evidence=("pinned build commit" if gv else
                         ("build commit unresolvable" if commit else "no source_url on manifest entry")),
        fetchable=bool(image),
        fetch_blocker=None if image else "coworld manifest entry carries no image URI",
        extra={"coworld": doc["name"], "coworld_version": doc["version"]},
    )


def resolve_policy_version(pv_id: str) -> Artifact:
    """An entrant policy version — what the picker actually searches.

    The read API exposes the policy's identity and its container entrypoint but
    NOT a pull address: `container_image_id` comes back null, and the container
    image record redacts both `image_uri` and `public_image_uri`. So these
    resolve fully and still cannot be fetched; the blocker is recorded rather
    than papered over, because the picker has to tell the truth about it.
    """
    st, row = _authed_get(f"/stats/policy-versions/{pv_id}")
    if st != 200:
        raise RuntimeError(f"policy version {pv_id} not found (HTTP {st}): {row}")

    attrs = row.get("attributes") or {}
    image_id = row.get("container_image_id")
    image_uri = None
    blocker = None
    img_row: dict[str, Any] = {}
    if image_id:
        sti, img_row = _authed_get(f"/v2/container_images/{image_id}")
        if sti == 200 and isinstance(img_row, dict):
            image_uri = img_row.get("public_image_uri") or img_row.get("image_uri")
            if not image_uri:
                blocker = (
                    f"container image {image_id} is private: the API redacts both "
                    "image_uri and public_image_uri, so there is no address to pull from"
                )
        else:
            img_row = {}
            blocker = f"container image {image_id} not readable (HTTP {sti})"
    else:
        blocker = (
            "the platform does not expose this policy version's container_image_id "
            "(the field is present on the schema but returns null), so the artifact "
            "has no resolvable pull address"
        )

    # Entrant policy images carry no build-provenance field at all, so there is
    # nothing to derive an engine version from. Left as None -> the gate refuses
    # on unknown provenance rather than assuming our own version.
    return Artifact(
        ref=f"pv:{pv_id}",
        kind="policy_version",
        name=row.get("name") or "?",
        version=str(row.get("version")),
        platform_id=pv_id,
        image=image_uri,
        run=list(attrs.get("run") or []),
        env={},
        source_url=None,
        source_commit=None,
        engine_game_version=None,
        engine_evidence="policy versions carry no build-provenance field",
        fetchable=bool(image_uri),
        fetch_blocker=blocker,
        extra={
            "kind_attr": attrs.get("kind"),
            "owner": (row.get("user") or {}).get("name"),
            "created_at": row.get("created_at"),
            "container_image_id": image_id,
            "image_status": img_row.get("status"),
            "image_digest": img_row.get("image_digest"),
            "tags": row.get("tags") or {},
        },
    )


UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)


def resolve(ref: str) -> Artifact:
    """Resolve any supported reference form to an Artifact.

    Accepted: a bare policy_version UUID, `pv:<uuid>`, `cw:<cow_id>[#player]`,
    or `coworld:<name>:<version>[#player]`.
    """
    if ref.startswith("pv:"):
        return resolve_policy_version(ref[3:])
    if ref.startswith("cw:"):
        rest = ref[3:]
        cow_id, _, player = rest.partition("#")
        return resolve_coworld_player(cow_id, player or None)
    if ref.startswith("coworld:"):
        _, _, rest = ref.partition(":")
        spec, _, player = rest.partition("#")
        name, _, version = spec.partition(":")
        return resolve_coworld_player(_find_coworld(name, version), player or None)
    if ref.startswith("cow_"):
        cow_id, _, player = ref.partition("#")
        return resolve_coworld_player(cow_id, player or None)
    if UUID_RE.match(ref):
        return resolve_policy_version(ref)
    raise RuntimeError(
        f"Unrecognised reference '{ref}'. Use a policy_version UUID, pv:<uuid>, "
        "cw:<cow_id>[#player], or coworld:<name>:<version>[#player]."
    )


def _find_coworld(name: str, version: str | None) -> str:
    """Look up a coworld id by name/version. The list endpoint is PAGINATED."""
    rows: list[dict] = []
    for off in range(0, 4000, 200):
        st, page = _authed_get("/v2/coworlds", limit=200, offset=off)
        if st != 200 or not page:
            break
        rows += page
        if len(page) < 200:
            break
    hits = [r for r in rows if r.get("name") == name]
    if version:
        hits = [r for r in hits if str(r.get("version")) == version]
    if not hits:
        raise RuntimeError(f"No coworld named {name}" + (f" at version {version}" if version else ""))
    hits.sort(key=lambda r: [int(p) for p in str(r["version"]).split(".") if p.isdigit()])
    return hits[-1]["id"]


# --------------------------------------------------------------------------
# The engine gate
# --------------------------------------------------------------------------

@dataclass
class Verdict:
    runnable: bool
    code: str
    reason: str
    ours: str
    theirs: str | None
    evidence: str

    def render(self) -> str:
        head = "RUNNABLE" if self.runnable else f"REFUSED [{self.code}]"
        return (f"{head}\n"
                f"  reason        : {self.reason}\n"
                f"  our engine    : GameVersion {self.ours}\n"
                f"  their engine  : GameVersion {self.theirs or 'UNKNOWN'}\n"
                f"  evidence      : {self.evidence}")


def gate(art: Artifact, *, allow_unknown_engine: bool = False,
         repo: Path = REPO_ROOT) -> Verdict:
    """Decide whether this artifact may be seated on our server, and why.

    Order matters: an artifact we cannot fetch is reported as unfetchable even
    if its engine matches, because "we could run it if we could get it" is a
    different fact for the picker than "we have it and it is wrong".
    """
    ours = local_game_version(repo)
    theirs = art.engine_game_version

    if not art.fetchable:
        return Verdict(False, "artifact_unavailable",
                       art.fetch_blocker or "artifact has no retrievable image",
                       ours, theirs, art.engine_evidence)

    if theirs is None:
        if not allow_unknown_engine:
            return Verdict(
                False, "engine_unknown",
                ("this artifact's target GameVersion could not be established, and our "
                 "server performs NO version handshake — seating it would produce plausible "
                 "garbage rather than an error. Refusing. Override with --allow-unknown-engine "
                 "only if you independently know the build matches."),
                ours, theirs, art.engine_evidence)
        return Verdict(True, "engine_unknown_overridden",
                       "engine version unknown; seated anyway because --allow-unknown-engine was passed",
                       ours, theirs, art.engine_evidence)

    if theirs != ours:
        return Verdict(
            False, "engine_mismatch",
            (f"artifact targets GameVersion {theirs}, our server runs GameVersion {ours}. "
             "These engines disagree about the wire protocol and rules; the connection "
             "would SUCCEED and the match would look normal while being meaningless. "
             "Rebuild our server at the artifact's engine, or pick an artifact built "
             f"for GameVersion {ours}."),
            ours, theirs, art.engine_evidence)

    return Verdict(True, "ok",
                   f"artifact and server agree on GameVersion {ours}",
                   ours, theirs, art.engine_evidence)


# --------------------------------------------------------------------------
# Fetch + cache
# --------------------------------------------------------------------------

def _docker(*args: str, check: bool = True, timeout: float = 1800.0) -> subprocess.CompletedProcess:
    return subprocess.run(["docker", *args], capture_output=True, text=True,
                          check=check, timeout=timeout)


def fetch(art: Artifact, *, force: bool = False) -> dict[str, Any]:
    """Pull the artifact image onto this box and record what we got.

    Images are built linux/amd64 for the hosted runner; we pin --platform so an
    arm64 box emulates rather than silently pulling a different manifest.
    """
    if not art.fetchable:
        raise RuntimeError(f"Cannot fetch {art.ref}: {art.fetch_blocker}")

    art.cache_dir.mkdir(parents=True, exist_ok=True)
    record_path = art.cache_dir / "artifact.json"
    local_tag = f"ctf-policycache/{art.cache_key}:latest"

    if record_path.exists() and not force:
        cached = json.loads(record_path.read_text())
        if _docker("image", "inspect", cached["local_tag"], check=False).returncode == 0:
            cached["cache_hit"] = True
            return cached

    _docker("pull", "--platform", "linux/amd64", art.image)
    _docker("tag", art.image, local_tag)

    inspect = _docker("image", "inspect", local_tag)
    meta = json.loads(inspect.stdout)[0]
    record = {
        **asdict(art),
        "local_tag": local_tag,
        "image_id": meta.get("Id"),
        "architecture": meta.get("Architecture"),
        "os": meta.get("Os"),
        "cache_hit": False,
    }
    record_path.write_text(json.dumps(record, indent=2) + "\n")
    return record


# --------------------------------------------------------------------------
# Seat: drive the artifact onto a slot
# --------------------------------------------------------------------------

DOCKER_HOST_ALIAS = "host.docker.internal"


def seat_command(record: dict[str, Any], *, slot: int, token: str,
                 port: int, host: str = DOCKER_HOST_ALIAS) -> list[str]:
    """The exact docker command that seats this artifact on one slot.

    Our seat protocol is a single env var: the bot reads COWORLD_PLAYER_WS_URL
    and connects to /player?slot=&token= — the same URL our own bots use, so a
    fetched artifact needs no adapter beyond reaching the host from a container.

    `host` is dialled from INSIDE the container, so it defaults to the
    host-gateway alias rather than to loopback: `127.0.0.1` here would mean the
    container itself. The alias is always mapped so the default resolves; the
    server must still bind 0.0.0.0 for any of it to be reachable.
    """
    ws = f"ws://{host}:{port}/player?slot={slot}&token={token}"
    cmd = ["docker", "run", "--rm", "--platform", "linux/amd64",
           "-e", f"COWORLD_PLAYER_WS_URL={ws}"]
    for k, v in (record.get("env") or {}).items():
        cmd += ["-e", f"{k}={v}"]
    cmd += ["--add-host", f"{DOCKER_HOST_ALIAS}:host-gateway", record["local_tag"]]
    cmd += list(record.get("run") or [])
    return cmd


# --------------------------------------------------------------------------
# Availability (what the picker renders)
# --------------------------------------------------------------------------

def availability(ref: str, *, allow_unknown_engine: bool = False) -> dict[str, Any]:
    try:
        art = resolve(ref)
    except Exception as e:  # noqa: BLE001 — a bad ref is an availability answer
        return {"ref": ref, "runnable": False, "code": "unresolvable",
                "reason": str(e), "name": None, "version": None}
    v = gate(art, allow_unknown_engine=allow_unknown_engine)
    return {
        "ref": art.ref, "kind": art.kind, "name": art.name, "version": art.version,
        "runnable": v.runnable, "code": v.code, "reason": v.reason,
        "our_game_version": v.ours, "artifact_game_version": v.theirs,
        "engine_evidence": v.evidence,
        "image": art.image, "run": art.run,
        "source_commit": art.source_commit,
    }


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def _print_artifact(art: Artifact) -> None:
    print(f"ref            : {art.ref}")
    print(f"kind           : {art.kind}")
    print(f"name/version   : {art.name} v{art.version}")
    print(f"image          : {art.image or '(none exposed)'}")
    print(f"run            : {' '.join(art.run) if art.run else '(image default entrypoint)'}")
    print(f"source commit  : {art.source_commit or '(none)'}")
    print(f"engine GV      : {art.engine_game_version or 'UNKNOWN'}  [{art.engine_evidence}]")
    print(f"fetchable      : {art.fetchable}" + (f"  — {art.fetch_blocker}" if art.fetch_blocker else ""))
    if art.extra:
        print(f"extra          : {json.dumps(art.extra, default=str)}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="policyfetch",
        description="Resolve, gate, fetch and seat platform policy artifacts on our local server.")
    ap.add_argument("--json", action="store_true", help="machine-readable output")

    # Accept --json on either side of the subcommand; SUPPRESS keeps the
    # subparser's default from clobbering a --json given before it.
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", default=argparse.SUPPRESS,
                        help="machine-readable output")

    sub = ap.add_subparsers(dest="cmd", required=True)

    for name, help_text in [
        ("resolve", "resolve a reference to an artifact descriptor"),
        ("gate", "engine-compatibility verdict for a reference"),
        ("fetch", "pull the artifact into the local cache"),
    ]:
        p = sub.add_parser(name, help=help_text, parents=[common])
        p.add_argument("ref")
        p.add_argument("--allow-unknown-engine", action="store_true",
                       help="seat artifacts whose target GameVersion cannot be established")
        if name == "fetch":
            p.add_argument("--force", action="store_true", help="re-pull even if cached")
            p.add_argument("--skip-gate", action="store_true",
                           help="cache the image without asserting compatibility (never seats it)")

    p = sub.add_parser("seat", help="run a fetched artifact on a slot against our server", parents=[common])
    p.add_argument("ref")
    p.add_argument("--slot", type=int, required=True)
    p.add_argument("--token", help="defaults to the config.json pattern 0xBADA55_<slot>")
    p.add_argument("--host", default=DOCKER_HOST_ALIAS,
                   help="address the CONTAINER dials; loopback here means the container itself "
                        f"(default: {DOCKER_HOST_ALIAS})")
    p.add_argument("--port", type=int, default=2000)
    p.add_argument("--allow-unknown-engine", action="store_true")
    p.add_argument("--print-only", action="store_true", help="print the command instead of running it")

    p = sub.add_parser("availability", help="runnable/not (and why) for one or more references", parents=[common])
    p.add_argument("refs", nargs="+")
    p.add_argument("--allow-unknown-engine", action="store_true")

    p = sub.add_parser("engine", help="print the GameVersion our local server runs", parents=[common])

    args = ap.parse_args(argv)

    if args.cmd == "engine":
        gv = local_game_version()
        print(json.dumps({"game_version": gv}) if args.json else f"local server GameVersion: {gv}")
        return 0

    if args.cmd == "availability":
        rows = [availability(r, allow_unknown_engine=args.allow_unknown_engine) for r in args.refs]
        if args.json:
            print(json.dumps(rows, indent=2))
        else:
            for r in rows:
                mark = "RUNNABLE" if r["runnable"] else "NOT RUNNABLE"
                print(f"[{mark}] {r.get('name')} v{r.get('version')}  ({r['code']})")
                print(f"    {r['reason']}")
        return 0 if all(r["runnable"] for r in rows) else 1

    if args.cmd == "resolve":
        art = resolve(args.ref)
        if args.json:
            print(json.dumps(asdict(art), indent=2, default=str))
        else:
            _print_artifact(art)
        return 0

    if args.cmd == "gate":
        art = resolve(args.ref)
        v = gate(art, allow_unknown_engine=args.allow_unknown_engine)
        if args.json:
            print(json.dumps(asdict(v), indent=2))
        else:
            _print_artifact(art)
            print()
            print(v.render())
        return 0 if v.runnable else 2

    if args.cmd == "fetch":
        art = resolve(args.ref)
        if not args.skip_gate:
            v = gate(art, allow_unknown_engine=args.allow_unknown_engine)
            if not v.runnable:
                print(v.render(), file=sys.stderr)
                return 2
        rec = fetch(art, force=args.force)
        if args.json:
            print(json.dumps(rec, indent=2, default=str))
        else:
            print(f"cached {rec['name']} v{rec['version']}")
            print(f"  local tag    : {rec['local_tag']}")
            print(f"  platform     : {rec['os']}/{rec['architecture']}")
            print(f"  cache dir    : {art.cache_dir}")
            print(f"  cache hit    : {rec['cache_hit']}")
        return 0

    if args.cmd == "seat":
        art = resolve(args.ref)
        v = gate(art, allow_unknown_engine=args.allow_unknown_engine)
        if not v.runnable:
            print("REFUSING TO SEAT — engine gate failed", file=sys.stderr)
            print(v.render(), file=sys.stderr)
            return 2
        rec = fetch(art)
        token = args.token or f"0xBADA55_{args.slot}"
        cmd = seat_command(rec, slot=args.slot, token=token, host=args.host, port=args.port)
        if args.print_only:
            print(" ".join(cmd))
            return 0
        print(f"seating {rec['name']} v{rec['version']} on slot {args.slot} "
              f"(GameVersion {v.ours}, {v.evidence})", file=sys.stderr)
        return subprocess.run(cmd).returncode

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
