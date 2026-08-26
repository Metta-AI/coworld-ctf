"""Hermetic tests for policyfetch.py.

No network calls, no docker calls, no git fetches. Every function that would
otherwise touch the outside world (`_public_get`, `_authed_get`, `_docker`,
`_git`) is monkeypatched with a recording stub. policyfetch is a safety gate
in front of seating an unknown-provenance bot on our server, so the refusal
paths (engine mismatch, engine unknown, artifact unavailable, unresolvable
ref) are exercised at least as hard as the happy path.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import policyfetch  # noqa: E402
from policyfetch import (  # noqa: E402
    Artifact,
    _commit_from_source_url,
    availability,
    commit_game_version,
    gate,
    local_game_version,
    resolve,
    resolve_coworld_player,
    resolve_policy_version,
    seat_command,
)

SHA = "abcdef1234567890abcdef1234567890abcdef12"


# --------------------------------------------------------------------------
# local_game_version
# --------------------------------------------------------------------------

def _write(repo: Path, rel: str, version: str) -> None:
    path = repo / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f'const GameVersion* = "{version}"\n')


def test_local_game_version_prefers_sim_types(tmp_path):
    _write(tmp_path, "src/ctf/sim_types.nim", "24")
    _write(tmp_path, "src/ctf/sim.nim", "99")  # would be wrong if this won
    assert local_game_version(tmp_path) == "24"


def test_local_game_version_falls_back_to_sim(tmp_path):
    _write(tmp_path, "src/ctf/sim.nim", "17")
    assert local_game_version(tmp_path) == "17"


def test_local_game_version_raises_when_absent(tmp_path):
    with pytest.raises(RuntimeError):
        local_game_version(tmp_path)


# --------------------------------------------------------------------------
# commit_game_version
# --------------------------------------------------------------------------

def _cat_file_ok(version: str) -> SimpleNamespace:
    return SimpleNamespace(returncode=0, stdout=f'GameVersion* = "{version}"\n')


def _cat_file_miss() -> SimpleNamespace:
    return SimpleNamespace(returncode=1, stdout="")


def test_commit_game_version_found_in_sim_types(monkeypatch):
    calls = []

    def fake_git(repo, *args, **kwargs):
        calls.append(args)
        if args == ("cat-file", "-p", f"{SHA}:src/ctf/sim_types.nim"):
            return _cat_file_ok("24")
        return _cat_file_miss()

    monkeypatch.setattr(policyfetch, "_git", fake_git)
    assert commit_game_version(SHA) == "24"
    assert not any(a[0] == "fetch" for a in calls)  # resolved on first try, no fetch needed


def test_commit_game_version_found_only_in_sim(monkeypatch):
    def fake_git(repo, *args, **kwargs):
        if args == ("cat-file", "-p", f"{SHA}:src/ctf/sim_types.nim"):
            return _cat_file_miss()
        if args == ("cat-file", "-p", f"{SHA}:src/ctf/sim.nim"):
            return _cat_file_ok("17")
        return _cat_file_miss()

    monkeypatch.setattr(policyfetch, "_git", fake_git)
    assert commit_game_version(SHA) == "17"


def test_commit_game_version_fetches_then_resolves(monkeypatch):
    calls = []
    state = {"fetched": False}

    def fake_git(repo, *args, **kwargs):
        calls.append(args)
        if args and args[0] == "fetch":
            state["fetched"] = True
            return SimpleNamespace(returncode=0, stdout="")
        if args[0] == "cat-file":
            if not state["fetched"]:
                return _cat_file_miss()
            if args == ("cat-file", "-p", f"{SHA}:src/ctf/sim_types.nim"):
                return _cat_file_ok("24")
        return _cat_file_miss()

    monkeypatch.setattr(policyfetch, "_git", fake_git)
    assert commit_game_version(SHA) == "24"
    assert any(a[0] == "fetch" for a in calls), "expected a fetch to have been attempted"


def test_commit_game_version_never_resolvable_returns_none(monkeypatch):
    calls = []

    def fake_git(repo, *args, **kwargs):
        calls.append(args)
        if args and args[0] == "fetch":
            return SimpleNamespace(returncode=0, stdout="")
        return _cat_file_miss()

    monkeypatch.setattr(policyfetch, "_git", fake_git)
    assert commit_game_version(SHA) is None
    assert any(a[0] == "fetch" for a in calls)


def test_commit_game_version_fetch_timeout_returns_none(monkeypatch):
    def fake_git(repo, *args, **kwargs):
        if args and args[0] == "fetch":
            raise subprocess.TimeoutExpired(cmd="git fetch", timeout=180.0)
        return _cat_file_miss()

    monkeypatch.setattr(policyfetch, "_git", fake_git)
    assert commit_game_version(SHA) is None


# --------------------------------------------------------------------------
# _commit_from_source_url
# --------------------------------------------------------------------------

def test_commit_from_source_url_extracts_sha():
    url = f"https://github.com/org/repo/tree/{SHA}"
    assert _commit_from_source_url(url) == SHA


def test_commit_from_source_url_extracts_sha_with_trailing_path():
    url = f"https://github.com/org/repo/tree/{SHA}/players/baseline"
    assert _commit_from_source_url(url) == SHA


def test_commit_from_source_url_branch_ref_is_not_a_commit():
    # A branch name must never be mistaken for a commit sha: unresolved
    # provenance has to fall through to a refusal, not a false positive.
    url = "https://github.com/x/y/tree/main"
    assert _commit_from_source_url(url) is None


def test_commit_from_source_url_none_input():
    assert _commit_from_source_url(None) is None


# --------------------------------------------------------------------------
# gate
# --------------------------------------------------------------------------

OURS = "42"


@pytest.fixture(autouse=False)
def fixed_local_version(monkeypatch):
    monkeypatch.setattr(policyfetch, "local_game_version", lambda repo=None: OURS)


def _artifact(**overrides) -> Artifact:
    defaults = dict(
        ref="pv:x", kind="policy_version", name="n", version="1",
        platform_id="p", fetchable=True, engine_game_version=None,
        engine_evidence="test evidence",
    )
    defaults.update(overrides)
    return Artifact(**defaults)


def test_gate_ok_when_engine_matches(fixed_local_version):
    art = _artifact(fetchable=True, engine_game_version=OURS)
    v = gate(art)
    assert v.runnable is True
    assert v.code == "ok"


def test_gate_engine_mismatch(fixed_local_version):
    art = _artifact(fetchable=True, engine_game_version="7")
    v = gate(art)
    assert v.runnable is False
    assert v.code == "engine_mismatch"
    assert OURS in v.reason
    assert "7" in v.reason


def test_gate_engine_unknown_refuses_by_default(fixed_local_version):
    art = _artifact(fetchable=True, engine_game_version=None)
    v = gate(art)
    assert v.runnable is False
    assert v.code == "engine_unknown"


def test_gate_engine_unknown_overridden(fixed_local_version):
    art = _artifact(fetchable=True, engine_game_version=None)
    v = gate(art, allow_unknown_engine=True)
    assert v.runnable is True
    assert v.code == "engine_unknown_overridden"


def test_gate_unavailable_takes_priority_over_matching_engine(fixed_local_version):
    # Even when the (never-fetched) artifact's engine equals ours, unavailability
    # must be reported first: "we could run it if we could get it" is a
    # different fact than "we have it and it agrees".
    art = _artifact(fetchable=False, fetch_blocker="no image", engine_game_version=OURS)
    v = gate(art)
    assert v.runnable is False
    assert v.code == "artifact_unavailable"


def test_verdict_render_contains_code_and_both_versions(fixed_local_version):
    art = _artifact(fetchable=True, engine_game_version="7")
    v = gate(art)
    rendered = v.render()
    assert "engine_mismatch" in rendered
    assert OURS in rendered
    assert "7" in rendered


# --------------------------------------------------------------------------
# seat_command
# --------------------------------------------------------------------------

def test_seat_command_shape():
    record = {
        "local_tag": "ctf-policycache/deadbeef:latest",
        "run": ["python", "bot.py", "--flag"],
        "env": {"FOO": "bar", "BAZ": "qux"},
    }
    cmd = seat_command(record, slot=3, token="tok123", port=2000)

    assert "--platform" in cmd
    idx = cmd.index("--platform")
    assert cmd[idx + 1] == "linux/amd64"

    # host defaults to the gateway alias, NOT loopback: the URL is dialled from
    # inside the container, where 127.0.0.1 would be the container itself.
    ws_flag = "COWORLD_PLAYER_WS_URL=ws://host.docker.internal:2000/player?slot=3&token=tok123"
    assert ws_flag in cmd

    assert "--add-host" in cmd
    idx = cmd.index("--add-host")
    assert cmd[idx + 1] == "host.docker.internal:host-gateway"

    assert cmd[-3:] == ["python", "bot.py", "--flag"]

    assert "FOO=bar" in cmd
    assert "BAZ=qux" in cmd
    # every env var should be threaded through as its own -e flag
    for kv in ("FOO=bar", "BAZ=qux"):
        i = cmd.index(kv)
        assert cmd[i - 1] == "-e"


def test_seat_command_host_override_is_honoured():
    """--host must actually change the dial target; it was once silently ignored."""
    record = {"local_tag": "tag:latest"}
    cmd = seat_command(record, slot=2, token="t", port=9000, host="192.168.1.50")

    assert "COWORLD_PLAYER_WS_URL=ws://192.168.1.50:9000/player?slot=2&token=t" in cmd
    # the gateway alias stays mapped regardless, so the default target keeps working
    assert cmd[cmd.index("--add-host") + 1] == "host.docker.internal:host-gateway"


def test_seat_command_no_env_no_run():
    record = {"local_tag": "tag:latest"}
    cmd = seat_command(record, slot=0, token="t", host="h", port=1)
    assert cmd[-1] == "tag:latest"  # nothing appended after the image when run is empty


# --------------------------------------------------------------------------
# resolve — reference-form dispatch
# --------------------------------------------------------------------------

SOME_UUID = "12345678-1234-5678-1234-567812345678"


def test_resolve_bare_uuid_routes_to_policy_version(monkeypatch):
    calls = []
    monkeypatch.setattr(policyfetch, "resolve_policy_version", lambda pv_id: calls.append(("pv", pv_id)))
    resolve(SOME_UUID)
    assert calls == [("pv", SOME_UUID)]


def test_resolve_pv_prefix(monkeypatch):
    calls = []
    monkeypatch.setattr(policyfetch, "resolve_policy_version", lambda pv_id: calls.append(("pv", pv_id)))
    resolve(f"pv:{SOME_UUID}")
    assert calls == [("pv", SOME_UUID)]


def test_resolve_cw_prefix_no_player(monkeypatch):
    calls = []
    monkeypatch.setattr(
        policyfetch, "resolve_coworld_player",
        lambda cow_id, player_id=None: calls.append((cow_id, player_id)),
    )
    resolve("cw:abc123")
    assert calls == [("abc123", None)]


def test_resolve_cw_prefix_with_player(monkeypatch):
    calls = []
    monkeypatch.setattr(
        policyfetch, "resolve_coworld_player",
        lambda cow_id, player_id=None: calls.append((cow_id, player_id)),
    )
    resolve("cw:abc123#playerid")
    assert calls == [("abc123", "playerid")]


def test_resolve_bare_cow_id(monkeypatch):
    calls = []
    monkeypatch.setattr(
        policyfetch, "resolve_coworld_player",
        lambda cow_id, player_id=None: calls.append((cow_id, player_id)),
    )
    resolve("cow_deadbeef")
    assert calls == [("cow_deadbeef", None)]


def test_resolve_garbage_ref_raises():
    with pytest.raises(RuntimeError):
        resolve("not-a-recognised-reference")


# --------------------------------------------------------------------------
# resolve_coworld_player
# --------------------------------------------------------------------------

def _manifest_doc(players):
    return {"name": "SomeCoworld", "version": "3", "manifest": {"player": players}}


def _player_entry(pid, source_url=None):
    return {
        "id": pid,
        "image": f"registry.example/{pid}@sha256:deadbeef",
        "run": ["python", "bot.py"],
        "env": {"K": "V"},
        "source_url": source_url or f"https://github.com/org/repo/tree/{SHA}/players/{pid}",
    }


def test_resolve_coworld_player_populates_artifact(monkeypatch):
    doc = _manifest_doc([_player_entry("baseline")])
    monkeypatch.setattr(policyfetch, "_public_get", lambda path: doc)
    monkeypatch.setattr(policyfetch, "commit_game_version", lambda sha, repo=None: "24")

    art = resolve_coworld_player("cow_x")
    assert art.image == "registry.example/baseline@sha256:deadbeef"
    assert art.run == ["python", "bot.py"]
    assert art.source_commit == SHA
    assert art.engine_game_version == "24"
    assert art.fetchable is True
    assert "pinned" in art.engine_evidence and "commit" in art.engine_evidence


def test_resolve_coworld_player_selects_by_id(monkeypatch):
    doc = _manifest_doc([_player_entry("baseline"), _player_entry("aggressive")])
    monkeypatch.setattr(policyfetch, "_public_get", lambda path: doc)
    monkeypatch.setattr(policyfetch, "commit_game_version", lambda sha, repo=None: "24")

    art = resolve_coworld_player("cow_x", "aggressive")
    assert art.name.endswith("/aggressive")
    assert art.image == "registry.example/aggressive@sha256:deadbeef"


def test_resolve_coworld_player_unknown_id_raises(monkeypatch):
    doc = _manifest_doc([_player_entry("baseline")])
    monkeypatch.setattr(policyfetch, "_public_get", lambda path: doc)
    monkeypatch.setattr(policyfetch, "commit_game_version", lambda sha, repo=None: "24")

    with pytest.raises(RuntimeError):
        resolve_coworld_player("cow_x", "nonexistent")


# --------------------------------------------------------------------------
# resolve_policy_version
# --------------------------------------------------------------------------

def test_resolve_policy_version_no_container_image_id(monkeypatch):
    row = {
        "name": "my-policy", "version": "5",
        "container_image_id": None,
        "attributes": {"run": ["python", "bot.py"]},
        "user": {"name": "someone"}, "created_at": "2026-01-01", "tags": {},
    }

    def fake_authed_get(path, **params):
        assert path == "/stats/policy-versions/pv123"
        return 200, row

    monkeypatch.setattr(policyfetch, "_authed_get", fake_authed_get)
    art = resolve_policy_version("pv123")

    assert art.fetchable is False
    assert art.fetch_blocker  # non-empty string
    assert isinstance(art.fetch_blocker, str) and len(art.fetch_blocker) > 0
    assert art.engine_game_version is None


def test_resolve_policy_version_private_image_redacted(monkeypatch):
    row = {
        "name": "my-policy", "version": "5",
        "container_image_id": "img-999",
        "attributes": {"run": []},
        "user": {"name": "someone"}, "created_at": "2026-01-01", "tags": {},
    }
    img_row = {"status": "ready", "image_digest": "sha256:zzz"}  # both uri fields redacted

    def fake_authed_get(path, **params):
        if path == "/stats/policy-versions/pv123":
            return 200, row
        if path == "/v2/container_images/img-999":
            return 200, img_row
        raise AssertionError(f"unexpected path {path}")

    monkeypatch.setattr(policyfetch, "_authed_get", fake_authed_get)
    art = resolve_policy_version("pv123")

    assert art.fetchable is False
    assert art.image is None
    assert "img-999" in art.fetch_blocker


# --------------------------------------------------------------------------
# availability
# --------------------------------------------------------------------------

def test_availability_unresolvable_ref_does_not_raise():
    result = availability("not-a-recognised-reference")
    assert result["runnable"] is False
    assert result["code"] == "unresolvable"
