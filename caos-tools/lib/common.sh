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
  # caos-stack, NOT caos-redis. The stack is ONE container (design/one-stack-image.md)
  # running redis, the registry, the server and runnerd as a process group, so
  # redis answers on the stack container's own name. `caos-redis` is the name the
  # SERVER uses from inside that container; it does not resolve on caos-net.
  #
  # Getting this wrong is silent: ccache treats an unreachable remote as a miss
  # and falls back to a local cache that is empty in every fresh container, so
  # the build simply stays slow with no error anywhere. That is why the stats
  # below are written into the report — an unobservable cache is a cache you
  # cannot trust.
  export CCACHE_REMOTE_STORAGE="${CTF_CCACHE_REDIS:-redis://caos-stack:6379}"
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
