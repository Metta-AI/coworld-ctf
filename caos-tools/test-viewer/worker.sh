#!/usr/bin/env bash
# The `test-viewer` tool's worker. Its DOCS live in the sibling `.caos-expr`
# here-string, not in this header (caos SPEC, "Tools").
#
# TWO STAGES, one script, selected by a curried --stage:
#
#   prepare (default) assemble the emsdk worker image, curry `build-viewer`,
#           run-then it
#   smoke   the `then`: --result is build-viewer's { report, status, dist }.
#           Run the bundle.
#
# WHY THE SMOKES RUN ON THE emsdk IMAGE. They need node, and the node that
# matters is the one beside the emcc that emitted the module: the bundle is
# `-s ENVIRONMENT=web,worker,node` precisely so CI can step the EXACT emitted
# module rather than a re-linked approximation of it. Reaching for some other
# node would be testing a different thing.
set -euo pipefail

fail() { echo "TEST-VIEWER FAIL: $*" >&2; exit 1; }

# How many ticks each fixture is stepped. 300 is what the workflow this
# replaced used: far enough in to load, seek and render, short enough that
# three replays stay a smoke rather than a suite.
TICKS=300

stage=prepare
if caos get /cas/args/stage 2>/dev/null; then stage=$(cat /cas/args/stage); fi

case "$stage" in

prepare)
  caos get /cas/args/in
  caos get /cas/args/in/caos-tools
  caos get -r /cas/args/in/caos-tools/lib
  caos get /cas/args/in/caos
  # shellcheck source=../lib/image.sh
  source /cas/args/in/caos-tools/lib/image.sh
  caos get -r /cas/args/in/caos-tools/build-viewer
  caos get -r /cas/args/in/caos/emsdk

  assemble_worker_image /cas/args/in/caos/emsdk /cas/emsdk

  # build-viewer starts on OUR image (both tools' first stage is imgtools) and
  # decides for itself what a bundle build reads. Duplicating that here is how
  # the two would drift.
  viewer=$(caos curry --base:@=/cas/args/base \
    "--worker1:@=/cas/args/in/caos-tools/build-viewer/worker.sh" \
    "--nim:@=/cas/args/nim") || fail "currying build-viewer"

  fwd=("--worker1:@=/cas/args/worker1" --stage=smoke)
  # --test-salt rides in the smoke stage and nowhere else, so a fresh value
  # re-runs the checks and leaves the bundle a cache hit. Nothing reads it: its
  # presence in the key is the whole mechanism.
  if [ -e /cas/args/test-salt ]; then fwd+=("--test-salt:@=/cas/args/test-salt"); fi
  next=$(caos curry --base:@=/cas/emsdk "${fwd[@]}") || fail "currying smoke"

  caos run-then /cas/args/in --run:hash="$viewer" --then:hash="$next"
  ;;

smoke)
  # --result is build-viewer's tree; --in the workspace tree, for the fixtures
  # and the two node harnesses.
  caos get -r /cas/args/result

  R=/tmp/result; rm -rf "$R"; mkdir -p "$R"
  if [ ! -d /cas/args/result/dist ]; then
    # The bundle is the whole job when it fails to build. Return ITS report —
    # an agent calling this wants the emcc errors, not our bookkeeping.
    { cat /cas/args/result/report 2>/dev/null
      echo; echo "FAILED: no bundle to run."
    } > "$R/report"
    caos put "$R" /cas/out
    exit 0
  fi

  # One level at a time: a path has to exist as a placeholder before it can be
  # descended into, which is why `tests` is fetched before the two directories
  # inside it.
  caos get /cas/args/in
  caos get -r /cas/args/in/tools
  # client/, because qa_band_desync.cjs reads ../client/broadcast_core.js
  # relative to tools/ — it exercises the SHIPPED parser, not a copy of it.
  caos get -r /cas/args/in/client
  caos get /cas/args/in/tests
  caos get -r /cas/args/in/tests/replays
  caos get -r /cas/args/in/tests/fixtures

  rm -rf /tmp/run; mkdir -p /tmp/run/tests
  cp -RL /cas/args/in/tools /tmp/run/tools
  cp -RL /cas/args/in/client /tmp/run/client
  cp -RL /cas/args/in/tests/replays /tmp/run/tests/replays
  cp -RL /cas/args/in/tests/fixtures /tmp/run/tests/fixtures
  cp -RL /cas/args/result/dist /tmp/run/dist
  cd /tmp/run
  export HOME=/tmp

  command -v node >/dev/null || fail "no node on PATH — is this the emsdk image?"

  fails=0
  : > /tmp/lines; : > /tmp/detail
  check() { # $1 = label, rest = argv
    local label=$1; shift
    local t0 ms st
    t0=$(date +%s%N)
    set +e
    "$@" > /tmp/out 2>&1
    st=$?
    set -e
    ms=$(( ($(date +%s%N) - t0)/1000000 ))
    if [ "$st" -eq 0 ]; then
      printf '  %6sms  PASS  %s\n' "$ms" "$label" >> /tmp/lines
    else
      fails=$((fails + 1))
      printf '  %6sms  FAIL  %s (exit %s)\n' "$ms" "$label" "$st" >> /tmp/lines
      { echo "=== $label (exit $st) ==="; tail -30 /tmp/out; echo; } >> /tmp/detail
    fi
  }

  # Pure-node client regression, no bundle needed: the sprite-protocol parser
  # must survive a failed band decode without desyncing, and the failed band
  # must self-heal from its retained compressed payload.
  check "band decode-failure regression" node tools/qa_band_desync.cjs

  # gen-colossal-4team is the ADDRESS-SPACE canary: a 4992x4992 board only fits
  # wasm32 because oversize boards emit at 1x (MaxSupersampledMapPixels).
  # Re-record on GameVersion bumps with:
  #   tools/record_colossal_demo.sh <out> 4242 1500 16
  for replay in tests/replays/ctf.bitreplay \
                tests/fixtures/gen-small-pits.bitreplay \
                tests/fixtures/gen-colossal-4team.bitreplay; do
    check "wasm smoke: $(basename "$replay")" node tools/wasm_replay_smoke.cjs dist "$replay" "$TICKS"
  done

  {
    echo "coworld-ctf replay viewer"
    echo
    cat /tmp/lines
    if [ "$fails" -gt 0 ]; then
      echo; echo "---- failures (last 30 lines each) ----"; echo
      cat /tmp/detail
    fi
    echo
    # The banner goes LAST: long results are truncated by keeping the TAIL, so
    # a summary at the top is the first thing lost.
    echo "checks: 4   failed: $fails"
    if [ "$fails" -gt 0 ]; then echo "FAILED"; else echo "PASSED"; fi
  } > "$R/report"
  caos put "$R" /cas/out
  ;;

*) fail "unknown stage: $stage" ;;
esac
