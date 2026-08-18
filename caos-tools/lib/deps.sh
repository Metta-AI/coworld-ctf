#!/usr/bin/env bash
# The pinned Nim dependency tree, fetched by nimby inside a worker.
#
# A HELPER, not a tool (subdirectories of caos-tools/ are not registered): it
# is curried by build.sh and test.sh, never called by an agent.
#
# Keyed on `nimby.lock` ALONE. The lock file is the whole `--in`, deliberately:
# bind the repo tree here and every source edit re-fetches 29 git repos. As it
# stands this runs once per lock change and is a cache hit forever after.
#
# Result: { <pkg>/ x29, nim.cfg, paths.txt }.
set -euo pipefail

fail() { echo "DEPS FAIL: $*" >&2; exit 1; }

caos get -r /cas/args/in || fail "fetching nimby.lock"

W=/tmp/deps
rm -rf "$W"; mkdir -p "$W"
cp /cas/args/in "$W/nimby.lock"
cd "$W"

# nimby syncs into the CWD, one directory per package, and writes a nim.cfg of
# relative --path: lines beside them.
export HOME=/tmp
nimby sync nimby.lock >/tmp/nimby.log 2>&1 || { tail -20 /tmp/nimby.log >&2; fail "nimby sync"; }

# A partial tree is worse than no tree: it would cache as a valid result and
# every later build would fail against it for reasons that point nowhere near
# the fetch. Check we got every package the lock names.
want=$(grep -cvE '^\s*(#|$)' nimby.lock)
got=$(find . -mindepth 1 -maxdepth 1 -type d | wc -l)
[ "$got" -eq "$want" ] || fail "lock names $want packages, got $got"

# THIN. The tree is 178 MB, but only ~4 MB is the srcDirs nim searches — the
# rest is test corpora (pixie/tests 46M, zippy/tests 31M, supersnappy/tests
# 19M). Dropping */tests gives 82 MB and both binaries still build.
#
# Do NOT prune to the srcDirs alone, however tempting: bitworld's
# src/bitworld/spriteprotocol.nim staticReads ../../client/data/pallete.png,
# outside its own srcDir, so a srcDir-only tree fails to compile. Measured, not
# theorised.
find . -mindepth 2 -maxdepth 2 -type d -name tests -exec rm -rf {} + 2>/dev/null || true
find . -mindepth 2 -maxdepth 2 -type d -name .git -exec rm -rf {} + 2>/dev/null || true
rm -f nimby.lock

# SORT nim.cfg. nimby syncs on four threads and appends each --path: as that
# package lands, so the file's order is thread-completion order — the one
# genuinely nondeterministic thing in this output, and enough on its own to
# give two identical fetches two different hashes.
{ head -1 nim.cfg; tail -n +2 nim.cfg | LC_ALL=C sort; } > nim.cfg.sorted
mv nim.cfg.sorted nim.cfg

# paths.txt — the same srcDirs as bare relative lines. nim reads a nim.cfg only
# from the PROJECT dir and its parents, never from a directory handed to
# --path:, and these paths are relative to this root. So consumers get the LIST
# and root it at wherever this tree is mounted.
tail -n +2 nim.cfg | sed 's|^--path:"||; s|"$||' > paths.txt

caos put "$W" /cas/out
