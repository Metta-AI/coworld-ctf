"""Verify archived source restoration using only main's base commit and patches."""

import json
import os
from pathlib import Path
import subprocess
import tempfile


archive = Path(__file__).resolve().parent
repo = subprocess.check_output(
    ["git", "-C", str(archive), "rev-parse", "--show-toplevel"], text=True
).strip()
base = (archive / "base.txt").read_text().strip()
evidence = "docs/designs/nav-rework-evidence-2026-09-09/"

for snapshot in [archive, *sorted((archive / "worktrees").iterdir())]:
    with tempfile.TemporaryDirectory() as temporary:
        environment = dict(os.environ, GIT_INDEX_FILE=str(Path(temporary) / "index"))

        def git(*arguments):
            return subprocess.check_output(
                ["git", "-C", repo, *arguments], env=environment, text=True
            )

        git("read-tree", base)
        patch = snapshot / ("implementation.patch" if snapshot == archive else "base.patch")
        if patch.stat().st_size:
            git("apply", "--cached", "--binary", str(patch))
        actual = {}
        for row in git("ls-files", "--stage").splitlines():
            fields, name = row.split("\t", 1)
            mode, blob, stage = fields.split()
            if not name.startswith(evidence):
                actual[name] = [mode, blob]
        expected = json.loads((snapshot / "tracked-files.json").read_text())
        if actual != expected:
            raise SystemExit(f"Restoration mismatch: {snapshot.name}")
        if snapshot != archive:
            dirty_patch = snapshot / "working-tree.patch"
            if dirty_patch.stat().st_size:
                git("apply", "--cached", "--binary", str(dirty_patch))
        print(f"Verified {snapshot.name}: {len(actual)} tracked paths; patches apply")
