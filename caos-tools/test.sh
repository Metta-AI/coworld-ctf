#!/usr/bin/env bash
#@doc Build the test binary from this tree and run the whole suite as cached
#@doc jobs — one job per tests/test_*.nim module, in parallel — then return
#@doc the report: a line per module with its time, the tail of every failure,
#@doc and a pass/fail banner. An unchanged module never re-runs. Nothing is
#@doc handed in from the host; the suite is compiled from these sources.
#@arg [test-salt] Re-run every test while leaving the compile a cache hit — any fresh value (e.g. $(date --iso=s)) re-keys the test runs and nothing else.
#@arg [only] Space-separated module names (e.g. "test_fov test_mapgen") to run just those.
#
# FOUR STAGES, one script, selected by a curried --stage.
#
#   narrow   (default) narrow the tree, curry the deps job, run-then it
#   compile  the `then`: build ONE test binary from the deps tree
#   fanout   the `then` of that: one child per module, map-then over them
#   summarize the `then` of the fan-out: assemble the report
#
# WHY ONE BINARY AND NOT ONE PER MODULE: Nim's unit of compilation is the whole
# program, so 66 per-module compiles cost ~20x one combined compile (35s vs
# 9-16 CPU-minutes) — the shared modules get rebuilt 66 times. And the run, not
# the compile, is the expensive part (~203s vs 35s). So: compile once, fan out
# the RUN.
#
# WHY PER MODULE AND NOT PER TEST: each invocation pays ~660ms of fixed startup
# against a ~356ms average test, and the wall clock floor is one 74.6s test
# (test_map_editor_core's generated-map validation) that no granularity splits.
# Per module is 78s; per test is ~75s for 10x the containers.
set -euo pipefail

fail() { echo "TEST FAIL: $*" >&2; exit 1; }

# How much of a failing module's output the report inlines: enough to carry the
# assertion and its diagnostic, not enough to bury the other failures. The
# whole thing is one `caos-cli get` away.
EXCERPT_LINES=25

stage=narrow
if caos get /cas/args/stage 2>/dev/null; then stage=$(cat /cas/args/stage); fi

case "$stage" in

narrow)
  caos get /cas/args/in
  caos get /cas/args/in/caos-tools
  # -r: we SOURCE common.sh, so we need its bytes, not a placeholder.
  caos get -r /cas/args/in/caos-tools/lib
  source /cas/args/in/caos-tools/lib/common.sh

  # What the TEST build reads. tools/ and players/ are not optional: the suite
  # reaches out to ../tools/{map_render,map_editor,expand_replay,
  # extract_events,dump_map_mask} and ../players/baseline/baseline/artlog.
  # tests/config.nims (tracked) carries --path:"../src" and must come along.
  #
  # The two top-level JSON files are read at RUN time, not compile time:
  # tests/helpers.nim sets `GameDir = currentSourcePath.parentDir.parentDir`
  # and chdirs there, so the suite resolves them against the tree it was
  # COMPILED in. Verified as the only top-level files any .nim actually reads
  # (Dockerfile and AGENTS.md appear in comments only).
  narrow_tree /cas/ws src tests tools players client data \
    config.json coworld_manifest_paintbot.json

  deps=$(caos curry --base:@=/cas/args/base \
    "--worker1:@=/cas/args/in/caos-tools/lib/deps.sh") || fail "currying deps"

  fwd=("--worker1:@=/cas/args/worker1" --stage=compile "--ws:@=/cas/ws"
       "--lib:@=/cas/args/in/caos-tools/lib/common.sh"
       "--runner:@=/cas/args/in/caos-tools/lib/run-batch.sh")
  if [ -e /cas/args/test-salt ]; then fwd+=("--test-salt:@=/cas/args/test-salt"); fi
  if [ -e /cas/args/only ]; then fwd+=("--only:@=/cas/args/only"); fi
  next=$(caos curry --base:@=/cas/args/base "${fwd[@]}") || fail "currying compile"

  caos run-then /cas/args/in/nimby.lock --run:hash="$deps" --then:hash="$next"
  ;;

compile)
  caos get -r /cas/args/result     # the deps tree
  caos get -r /cas/args/ws
  caos get -r /cas/args/lib
  source /cas/args/lib

  deps_flags /cas/args/result
  setup_ccache

  rm -rf /tmp/build/src; mkdir -p /tmp/build
  cp -RL /cas/args/ws/. /tmp/build/src/
  cd /tmp/build/src

  R=/tmp/result; rm -rf "$R"; mkdir -p "$R"
  set +e
  nim c -d:release --hints:off "${DEPS_FLAGS[@]}" \
    --nimcache:"$NIMCACHE" -o:/tmp/build/tests tests/tests.nim > "$R/report" 2>&1
  status=$?
  set -e
  echo "$status" > "$R/status"

  if [ "$status" -ne 0 ]; then
    # Compiling is the whole job when it fails: return the diagnostics as the
    # result rather than fanning out over a binary that does not exist.
    { echo; echo "FAILED: the test binary did not compile (nim exited $status)"; } >> "$R/report"
    caos put "$R" /cas/out
    exit 0
  fi
  cp /tmp/build/tests "$R/bin"

  fwd=("--worker1:@=/cas/args/worker1" --stage=fanout
       "--ws:@=/cas/args/ws" "--runner:@=/cas/args/runner")
  if [ -e /cas/args/test-salt ]; then fwd+=("--test-salt:@=/cas/args/test-salt"); fi
  if [ -e /cas/args/only ]; then fwd+=("--only:@=/cas/args/only"); fi
  next=$(caos curry --base:@=/cas/args/base "${fwd[@]}") || fail "currying fanout"

  caos put "$R" /cas/build
  # map-then with NO `map` is a plain tail call to `then` — `fanout` receives
  # the built tree as its --in. No middle step, no extra job.
  caos map-then /cas/build --then:hash="$next"
  ;;

fanout)
  # --in is the compile stage's tree { bin, report, status }.
  caos get -r /cas/args/in
  # One level at a time: a path has to exist before it can be descended into.
  caos get /cas/args/ws
  caos get -r /cas/args/ws/tests
  caos get -r /cas/args/runner

  # The binary is curried into the MAPPER, so all 58 jobs name the same blob by
  # the same hash — stored once, not copied per child. The mapper is curried
  # HERE, where the image (/cas/args/base) is a genuine tree.
  # `ws` rides along with the binary because the binary NEEDS IT AT RUNTIME:
  # nim bakes currentSourcePath at compile time, so the tests resolve their
  # fixtures against the directory they were COMPILED in. Both are curried into
  # the mapper, so all 58 jobs name the same two hashes and each is stored once.
  mapper=$(caos curry --base:@=/cas/args/base \
    "--worker1:@=/cas/args/runner" \
    "--ws:@=/cas/args/ws" \
    "--tests:@=/cas/args/in/bin") || fail "currying the per-module runner"

  only=""
  if [ -e /cas/args/only ]; then caos get /cas/args/only; only=" $(cat /cas/args/only) "; fi
  salt=""
  if [ -e /cas/args/test-salt ]; then caos get /cas/args/test-salt; salt=$(cat /cas/args/test-salt); fi

  # Test names come straight out of the source: 570 `test "..."` and 83
  # `suite "..."` — exactly what the binary reports — with zero computed names,
  # so a grep is complete rather than approximate. No listing pass needed.
  mkdir -p /tmp/sel /tmp/skipped
  : > /tmp/skipped/list
  for f in /cas/args/ws/tests/test_*.nim; do
    [ -e "$f" ] || continue
    m=$(basename "$f" .nim)
    if [ -n "$only" ]; then case "$only" in *" $m "*) ;; *) continue ;; esac; fi
    # `|| true`: grep exits 1 when a module has no top-level `test "..."`, and
    # under `set -euo pipefail` that failure propagates through the pipeline to
    # the assignment and kills this stage — silently, because grep prints
    # nothing. 8 of the tests/*.nim are exactly that case, so a full run died
    # with a bare "exited with exit status: 1" while any --only subset passed.
    names=$(grep -oE '^[[:space:]]*test "[^"]+"' "$f" | sed 's/.*test "//; s/"$//' || true)
    if [ -z "$names" ]; then
      # NOT skipped, and the report must not say so. These modules assert at
      # MODULE SCOPE (doAssert, printing "Testing <x> ... ok"), so they execute
      # on every startup of the binary — i.e. in all 58 batches, not none. They
      # simply cannot be fanned out, having no test names to filter on.
      echo "$m" >> /tmp/skipped/list
      continue
    fi
    mkdir -p "/tmp/sel/$m"
    printf '%s\n' "$names" > "/tmp/sel/$m/names"
    # --test-salt rides in EVERY child and nowhere else, so a fresh value
    # re-runs the tests and leaves the compile a cache hit. Nothing reads it:
    # its presence in the child is what moves the key. Do not "clean up" the
    # unused write — it is the whole mechanism.
    if [ -n "$salt" ]; then printf '%s' "$salt" > "/tmp/sel/$m/salt"; fi
  done
  caos put /tmp/sel /cas/sel
  caos put /tmp/skipped /cas/skipped

  fwd=("--worker1:@=/cas/args/worker1" --stage=summarize "--skipped:@=/cas/skipped")
  next=$(caos curry --base:@=/cas/args/base "${fwd[@]}") || fail "currying summarize"

  caos map-then /cas/sel --map:hash="$mapper" --then:hash="$next"
  ;;

summarize)
  # --in is the selection tree, --children one { output, status, ms } per module.
  caos get -r /cas/args/in
  caos get -r /cas/args/children
  caos get -r /cas/args/skipped

  R=/tmp/summary; rm -rf "$R"; mkdir -p "$R/results"
  pass=0; failed=0; total_ms=0
  : > /tmp/lines; : > /tmp/failures

  for d in /cas/args/children/*/; do
    [ -d "$d" ] || continue
    m=$(basename "$d")
    st=$(cat "$d/status" 2>/dev/null || echo "?")
    ms=$(cat "$d/ms" 2>/dev/null || echo 0)
    cp -RL "$d" "$R/results/$m" 2>/dev/null || true
    if [ "$ms" -eq "$ms" ] 2>/dev/null; then total_ms=$((total_ms + ms)); fi
    if [ "$st" = "0" ]; then
      pass=$((pass + 1)); printf '  %6sms  PASS  %s\n' "$ms" "$m" >> /tmp/lines
    else
      failed=$((failed + 1)); printf '  %6sms  FAIL  %s (exit %s)\n' "$ms" "$m" "$st" >> /tmp/lines
      {
        echo "=== $m (exit $st) ==="
        # The binary prints EVERY suite header regardless of the name filter,
        # so the tail is a wall of empty [Suite] lines with the real assertion
        # buried above it. Pull the [FAILED] blocks instead, and only fall back
        # to the tail when there is no such marker (a crash before any test).
        if grep -q "\[FAILED\]" "$d/output" 2>/dev/null; then
          grep -B8 -A2 "\[FAILED\]" "$d/output" | head -n "$EXCERPT_LINES"
        else
          grep -vE "^\[Suite\] |^$" "$d/output" 2>/dev/null | tail -n "$EXCERPT_LINES"
        fi
        echo
      } >> /tmp/failures
    fi
  done

  {
    echo "coworld-ctf test suite"
    echo
    sort -k2 -rn /tmp/lines
    if [ -s /cas/args/skipped/list ]; then
      echo
      echo "module-scope asserts (run in EVERY batch, not fanned out):"
      echo "  $(tr '\n' ' ' < /cas/args/skipped/list)"
    fi
    if [ "$failed" -gt 0 ]; then
      echo; echo "---- failures (last $EXCERPT_LINES lines each) ----"; echo
      cat /tmp/failures
    fi
    echo
    # The banner goes LAST: long results are truncated by keeping the TAIL, so
    # a summary at the top is the first thing lost.
    echo "modules: $((pass + failed))   passed: $pass   failed: $failed   cpu: $((total_ms / 1000))s"
    if [ "$failed" -gt 0 ]; then
      echo "FAILED"
    else
      echo "PASSED"
    fi
  } > "$R/report"

  caos put "$R" /cas/out
  ;;

*) fail "unknown stage: $stage" ;;
esac
