#!/usr/bin/env bash
# Shared by build.sh and test.sh. Sourced, not run.

# Narrow the workspace tree to the entries a compile actually reads, and put it
# in the CAS. Everything is linked BY REFERENCE: `caos put` resolves a symlink
# pointing into /cas to the hash already recorded for it, so no content is
# fetched or copied — data/ is never read just to appear in the tree. The one
# requirement is that the path exists to be resolved, which the single
# top-level `caos get` satisfies.
#
# This is what keeps a compile from re-keying on edits to docs/, README.md,
# AGENTS.md or replay-viewer/.
#
# $1 = destination /cas path, rest = top-level entries to keep.
narrow_tree() {
  local dest=$1; shift
  local w e
  w=$(mktemp -d)
  for e in "$@"; do
    if [ -e "/cas/args/in/$e" ]; then
      ln -s "/cas/args/in/$e" "$w/$e"
    fi
  done
  caos put "$w" "$dest"
}

# Mirror a MATERIALIZED /cas tree, keeping only what the test binary reads at
# RUN time: everything that is not Nim source.
#
# This exists so a source edit that does not change the binary does not re-run
# the tests. The fan-out's mapper has to carry a tree, because nim bakes
# currentSourcePath and the binary resolves its fixtures against the directory
# it was COMPILED in. Carrying the full source tree there meant every child's
# ArgTree moved whenever any .nim moved — so editing a comment re-ran all 74
# jobs, even though the generated C was byte-identical (measured: 0 of 133 .c
# files differ after a comment-only edit) and the binary therefore was too.
#
# Exclude-the-sources rather than enumerate-the-data, deliberately: the suite
# reads data/, client/, tests/fixtures/, tests/replays/, tools/map_editor/'s
# assets and both top-level JSON files, plenty of it via paths built at run
# time, so any hand-written include list would be wrong the first time someone
# added a fixture. Nothing under tests/ or tools/ reads a .nim at run time
# (checked): the one `"/static/../arena.nim"` is a traversal probe asserting a
# 404, which it gets either way.
#
# By reference, like narrow_tree: every entry is a symlink into /cas, so `caos
# put` records the hash already known for it and no content is copied.
#
# $1 = destination /cas path, $2 = the materialized source tree.
runtime_tree() {
  local dest=$1 src=$2 w f rel d
  w=$(mktemp -d)
  while IFS= read -r f; do
    rel=${f#"$src"/}
    d=$(dirname "$rel")
    mkdir -p "$w/$d"
    ln -s "$f" "$w/$rel"
  done < <(find "$src" \( -type f -o -type l \) \
             ! -name '*.nim' ! -name '*.nims' ! -name '*.cfg')
  caos put "$w" "$dest"
}

# The --path: flags for the deps tree at $1, rooted there. nim reads a nim.cfg
# only from the PROJECT dir and its parents, never from a --path: directory, so
# the deps ship the list and we root it here. (This repo's own nim.cfg is
# nimby's, full of host paths — it is gitignored, so caos never sees it and a
# worker has none. Nim's paths are managed entirely by the deps job's output.)
deps_flags() {
  local d=$1 p
  DEPS_FLAGS=()
  while read -r p; do
    [ -n "$p" ] && DEPS_FLAGS+=("--path:$d/$p")
  done < "$d/paths.txt"
}

# ccache, backed by the caos stack's own redis. Content-addressed, so it can
# only change speed, never output — a corrupted entry degrades to a miss
# (verified: overwriting a result with garbage cost one recompile and produced
# a byte-identical binary). It stays out of the ArgTree, so it cannot re-key a
# job; it is an optimization, not an input.
#
# NIMCACHE IS A FIXED PATH ON PURPOSE. Absolute paths are baked into the C nim
# generates, so a nimcache that moves misses 100% (measured: 0 hits / 266).
# This is caos's own lesson from cargo-workers.md, in a different compiler.
setup_ccache() {
  # caos tells us where the cache is: runnerd injects CAOS_WORKER_REDIS_ADDR
  # into every worker when the deployment offers one (crates/runnerd/src/main.rs).
  # It is a host:port ADDRESS, not a URL, so ccache's scheme goes on the front.
  #
  # ABSENT IS NORMAL, and must never be an error. caos's contract is explicit:
  # "unset means no worker is offered one, so a worker must treat its absence as
  # 'no cache available' and still do the work". A deployment without a worker
  # redis builds slower; it does not fail.
  #
  # Do not hardcode an address here again. The previous one was `caos-stack`,
  # because the stack was a single container and `caos-redis` did not resolve on
  # caos-net; it does now. Guessing this wrong is SILENT — ccache reports an
  # unreachable remote as a miss and falls back to a local cache that is empty in
  # every fresh container, so the build just stays slow with no error anywhere.
  # That is why the stats go into the report: an unobservable cache is one you
  # cannot trust, and this one was dead for a long time before anyone noticed.
  if [ -n "${CAOS_WORKER_REDIS_ADDR:-}" ]; then
    export CCACHE_REMOTE_STORAGE="redis://$CAOS_WORKER_REDIS_ADDR"
  else
    unset CCACHE_REMOTE_STORAGE
  fi
  export CCACHE_DIR=/tmp/ccache
  export CCACHE_BASEDIR=/tmp/build
  mkdir -p /tmp/build "$CCACHE_DIR"
}
NIMCACHE=/tmp/build/nimcache

# Tell nim EXPLICITLY which compiler to run. Shadowing `gcc` on PATH does not
# work here: the nixpkgs nim wrapper bakes an absolute compiler path into its
# config, so nim invokes
#   /nix/store/...-gcc-wrapper-15.3.0/bin/gcc
# directly and never consults PATH (measured with `nim c --listCmd`). Shipping a
# /ccache-bin wrapper without this flag looks completely correct — `command -v
# gcc` even reports the wrapper — while ccache records ZERO calls.
CCACHE_NIM_FLAGS=(--cc:gcc --gcc.exe:/ccache-bin/gcc)
