#!/usr/bin/env bash
# A Nim toolchain, installed by nimby inside a worker, as a cached tree.
#
# A HELPER, not a tool: it is curried by build-viewer/worker.sh, never called
# by an agent. caos-tools/lib/ carries no `.caos-expr`, which is what keeps it
# out of the registry (caos SPEC, "Tools").
#
# WHY THIS EXISTS AT ALL, when caos/nim already ships a compiler: the wasm
# build does not run on caos/nim. It runs on the upstream emsdk image, which is
# pinned for `emcc` (see caos/emsdk/README.md) and carries no Nim. The
# Dockerfile this replaced installed one with the same two commands at image
# build time; here it is a job, so it is cached rather than rebuilt, and the
# pins are visible in the arg tree rather than baked into an image nobody
# rebuilds.
#
# Keyed on `--in`, which is the pins blob its caller writes: change a pin, get
# a different toolchain; change anything else in the repo, get a cache hit.
#
# Result: the whole ~/.nimby tree — the compiler under nim/, ready to be put on
# PATH as <tree>/nim/bin.
set -euo pipefail

fail() { echo "NIM-TOOLCHAIN FAIL: $*" >&2; exit 1; }

caos get -r /cas/args/in || fail "fetching the pins"
# nimby=<ver> sha256=<hex> nim=<ver>, one word each. Parsed rather than
# hardcoded so the values that key this job are the values it uses.
# shellcheck disable=SC2046
eval $(tr ' ' '\n' < /cas/args/in | sed 's/^/PIN_/')
[ -n "${PIN_nimby:-}" ] && [ -n "${PIN_sha256:-}" ] && [ -n "${PIN_nim:-}" ] \
  || fail "pins blob must read 'nimby=<ver> sha256=<hex> nim=<ver>'"

export HOME=/tmp
mkdir -p /tmp/bin
# The release binary, checked. An unverified curl into a toolchain is how a
# build gets a compiler nobody chose; the Dockerfile checked this hash and so
# does this.
timeout 300 curl -fsSL -o /tmp/bin/nimby \
  "https://github.com/treeform/nimby/releases/download/$PIN_nimby/nimby-Linux-X64" \
  || fail "downloading nimby $PIN_nimby"
echo "$PIN_sha256  /tmp/bin/nimby" | sha256sum -c - >/dev/null \
  || fail "nimby $PIN_nimby does not match its pinned sha256"
chmod +x /tmp/bin/nimby

# BOUNDED for the same reason lib/deps.sh is: a caos job carries no execution
# deadline, so a stalled download hangs forever and looks exactly like a slow
# one. A cold `nimby use` is well under a minute.
timeout 900 /tmp/bin/nimby use "$PIN_nim" > /tmp/nimby.log 2>&1 \
  || { tail -20 /tmp/nimby.log >&2; fail "nimby use $PIN_nim (timeout 900s)"; }

[ -x "$HOME/.nimby/nim/bin/nim" ] || fail "nimby use produced no nim binary"
# nimby lands here too; the build stage wants both on PATH from one tree.
install -m 0755 /tmp/bin/nimby "$HOME/.nimby/nim/bin/nimby"
caos put "$HOME/.nimby" /cas/out
