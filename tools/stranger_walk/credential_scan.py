#!/usr/bin/env python3
"""tools/stranger_walk/credential_scan.py — shared helper for
isolation_audit.sh's v1.4 credential-leak checks.

Only relevant to a run whose credential_source was "host_claude_login"
(see run_container.sh's header) — a `run` where option (a), a run-scoped
Anthropic API key, was unavailable and the operator's own Claude Code login
(extracted from the host's credential store) was copied into the run's own
$RUN_DIR/.claude/.credentials.json instead. This module NEVER prints the
credential's value: every check reports PASS/FAIL plus a SHA256 fingerprint
of the credential file's bytes and, on a hit, only the NAME of the artifact
that matched — never the matched text itself.

Two checks:
  - artifacts <run-dir>
        Substring-search every standard run-dir artifact (transcript.jsonl,
        meta.json, score.json, logs, prompt.rendered.md, isolation_probe.json,
        ...) for any candidate secret extracted from the run's own retained
        credential file. This is what would catch a stranger that `cat`s its
        own ~/.claude/.credentials.json and has the raw text land in its own
        transcript.
  - docker-image <run-dir> <image-ref>
        `docker save`s the given image/container and scans every layer's
        file contents for the same candidate secrets. Only ever has
        anything to scan when STRANGER_ENABLE_DOCKER_SOCKET=1 was used (see
        run_container.sh) — the container can't reach a docker daemon at
        all by default, so there is nothing a stranger could have built.

Exit 0 = no hit (PASS, or not-applicable because this run used option (a)
or never got a host_claude_login credential at all). Exit 1 = a hit was
found (FAIL — disqualifying, same severity as any other isolation_audit.sh
boundary hit).
"""
import hashlib
import io
import json
import os
import subprocess
import sys
import tarfile

MIN_SECRET_LEN = 20

# The standard set of files a run dir can contain across run.sh and
# run_container.sh output (see docs/designs/STRANGER_WALK.md's run-dir
# contract) — checked when present, skipped when not. Deliberately broad
# (better to check a file that doesn't exist than to miss one that does).
ARTIFACT_NAMES = [
    "transcript.jsonl",
    "meta.json",
    "score.json",
    "run.stderr.log",
    "run.stdout.log",
    "container.stdout.log",
    "container.stderr.log",
    "docker-build.log",
    "docker-wait.stderr.log",
    "prompt.rendered.md",
    "isolation_probe.json",
    "credential_meta.json",
    "probe.stdout.log",
    "probe.stderr.log",
    "selftest.stdout.log",
    "selftest.stderr.log",
]


def load_secrets(run_dir):
    """Returns (secrets: set[str] | None, sha256: str | None).

    None means "no host_claude_login credential file for this run" — the
    caller should treat that as not-applicable, not a failure.
    """
    cred_path = os.path.join(run_dir, ".claude", ".credentials.json")
    if not os.path.isfile(cred_path):
        return None, None
    raw = open(cred_path, "rb").read()
    sha256 = hashlib.sha256(raw).hexdigest()
    secrets = set()
    text = raw.decode("utf-8", errors="ignore").strip()
    if len(text) >= MIN_SECRET_LEN:
        secrets.add(text)
    try:
        data = json.loads(raw)
    except Exception:
        data = None

    def walk(o):
        if isinstance(o, str):
            if len(o) >= MIN_SECRET_LEN:
                secrets.add(o)
        elif isinstance(o, dict):
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)

    if data is not None:
        walk(data)
    return secrets, sha256


def _contains_any(content, secrets):
    return any(len(s) >= MIN_SECRET_LEN and s in content for s in secrets)


def scan_artifacts(run_dir):
    secrets, sha256 = load_secrets(run_dir)
    if secrets is None:
        print("CREDENTIAL LEAK CHECK: not applicable (no host_claude_login credential file for this run)")
        return 0
    hit_files = []
    for name in ARTIFACT_NAMES:
        path = os.path.join(run_dir, name)
        if not os.path.isfile(path):
            continue
        try:
            content = open(path, "r", errors="ignore").read()
        except Exception:
            continue
        if _contains_any(content, secrets):
            hit_files.append(name)
    if hit_files:
        print(
            f"CREDENTIAL LEAK CHECK: source=host_claude_login sha256={sha256} "
            f"result=FAIL hits_in={','.join(sorted(set(hit_files)))}"
        )
        return 1
    print(
        f"CREDENTIAL LEAK CHECK: source=host_claude_login sha256={sha256} "
        f"result=PASS (checked {len(ARTIFACT_NAMES)} artifact name(s), value never printed)"
    )
    return 0


def scan_docker_image(run_dir, image_ref):
    secrets, sha256 = load_secrets(run_dir)
    if secrets is None:
        print(f"DOCKER IMAGE SCAN [{image_ref}]: not applicable (no host_claude_login credential for this run)")
        return 0
    try:
        proc = subprocess.Popen(["docker", "save", image_ref], stdout=subprocess.PIPE)
        outer = tarfile.open(fileobj=proc.stdout, mode="r|*")
        hit = False
        hit_members = []
        for member in outer:
            if not member.isfile() or member.size > 200_000_000:
                continue
            f = outer.extractfile(member)
            if f is None:
                continue
            data = f.read()
            # `docker save` output varies by engine/version: legacy format
            # nests a real tar per layer at "<layerid>/layer.tar" (plus
            # plain-JSON "<layerid>/json" config blobs); newer engines (this
            # host: docker 29.x) use the OCI layout instead — content-
            # addressed files under "blobs/sha256/<digest>" with NO
            # extension, where each blob is either a gzip-compressed tar
            # layer or a plain JSON config/manifest. Don't trust the member
            # NAME at all: try to open every file as a (possibly
            # compressed) nested tar first, and if that fails, fall back to
            # checking its raw bytes directly (covers JSON config/manifest
            # blobs and any other plain-text member).
            try:
                inner = tarfile.open(fileobj=io.BytesIO(data), mode="r:*")
            except Exception:
                inner = None
            if inner is not None:
                for imember in inner:
                    if not imember.isfile() or imember.size > 20_000_000:
                        continue
                    inf = inner.extractfile(imember)
                    if inf is None:
                        continue
                    try:
                        icontent = inf.read().decode("utf-8", errors="ignore")
                    except Exception:
                        continue
                    if _contains_any(icontent, secrets):
                        hit = True
                        hit_members.append(f"{member.name}:{imember.name}")
            else:
                try:
                    content = data.decode("utf-8", errors="ignore")
                except Exception:
                    continue
                if _contains_any(content, secrets):
                    hit = True
                    hit_members.append(member.name)
        proc.stdout.close()
        proc.wait()
        if hit:
            print(
                f"DOCKER IMAGE SCAN [{image_ref}]: sha256={sha256} result=FAIL "
                f"hits_in={','.join(hit_members)}"
            )
            return 1
        print(f"DOCKER IMAGE SCAN [{image_ref}]: sha256={sha256} result=PASS (value never printed)")
        return 0
    except Exception as e:
        print(f"DOCKER IMAGE SCAN [{image_ref}]: ERROR ({e}) — treating as FAIL (cannot prove clean)")
        return 1


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "artifacts" and len(sys.argv) == 3:
        sys.exit(scan_artifacts(sys.argv[2]))
    elif mode == "docker-image" and len(sys.argv) == 4:
        sys.exit(scan_docker_image(sys.argv[2], sys.argv[3]))
    else:
        print("usage: credential_scan.py artifacts <run-dir> | docker-image <run-dir> <image-ref>", file=sys.stderr)
        sys.exit(2)
