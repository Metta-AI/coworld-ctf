#!/usr/bin/env bash
#@doc Build the test binary from this tree and run the whole suite as cached
#@doc jobs in parallel — one per tests/test_*.nim module, or one per test for
#@doc the slow modules — then return the report: a line per job with its time,
#@doc the tail of every failure, and a pass/fail banner. An unchanged job never
#@doc re-runs. Nothing is handed in from the host; the suite is compiled from
#@doc these sources.
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
# program, so 66 per-module compiles cost ~20x one combined compile (36s vs
# 9-16 CPU-minutes) — the shared modules get rebuilt 66 times. And the run, not
# the compile, is the expensive part (~340 CPU-seconds vs 36s). So: compile
# once, fan out the RUN.
#
# WHAT BOUNDS THE WALL CLOCK, measured. Not any single test any more — the
# longest job is ~21s against a ~90s wall. It is throughput:
#
#   - CORES, and only cores. Interleaving 8/16/8/16 on an idle box: doubling
#     the slots doubles measured test CPU (396s -> 812s) for identical work,
#     because the 16 in nproc are SMT siblings on 8 physical. Wall clock is a
#     wash in both orderings. 8 slots IS the machine; do not plumb
#     CAOS_RUNNER_SLOTS through `caosd up` expecting a win.
#
#     `get ws` per job also doubles at 16 slots (0.49s -> 0.98s), which looks
#     like the object server saturating and is NOT. A probe that fetches the
#     same objects with curl — pure transfer, nothing materialized — gets
#     672/645us per object at 8 slots and 579/582us at 16: FASTER concurrent,
#     with aggregate throughput more than doubling. The server scales. What
#     doubles is `caos get`'s own client-side work — zlib inflate, ~600 file
#     operations and ~600 xattr sets — competing for the same 8 cores.
#   - each job re-fetching the same 11.2 MB tree and 9.5 MB binary from the
#     server (see the "fan-out cost" block the report prints). Uncontended the
#     tree is 385ms — ~215ms of that HTTP at 0.66ms per object over 326
#     objects, ~110ms filesystem, ~60ms of caos's own placeholder bookkeeping,
#     6ms of walk — but it is the ceiling above, not the 385ms, that shapes a
#     run.
#   - four chained stages before any test runs. Dispatch itself is cheap: a
#     whole no-op tool call — eval, ingest, container, result — is 240ms.
#
# Splitting the 73s baseline test is what made any of this reachable: before
# it, ONE test set an 86s floor that nothing else could get under.
#
# PER MODULE BY DEFAULT, PER TEST WHERE IT PAYS: each invocation pays ~660ms of
# fixed startup (the module-scope asserts of every module run on every startup)
# against a ~356ms average test, so splitting a fast module costs more than it
# saves. Fanning out ALL 570 tests adds 6.3 CPU-minutes of startup to a suite
# whose total is ~6 CPU-minutes — it doubles the work to shave the tail. So
# only the modules in PER_TEST below are split, and the ms column of the report
# is how you decide which.
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
  nim c -d:release --hints:off "${CCACHE_NIM_FLAGS[@]}" "${DEPS_FLAGS[@]}" \
    --nimcache:"$NIMCACHE" -o:/tmp/build/tests tests/tests.nim > "$R/report" 2>&1
  status=$?
  set -e
  echo "$status" > "$R/status"

  # Cache stats into the report: a remote that cannot be reached is otherwise
  # indistinguishable from a cold one.
  {
    echo
    echo "---- ccache ----"
    echo "  gcc:    $(command -v gcc)"
    echo "  remote: ${CCACHE_REMOTE_STORAGE:-<none: CAOS_WORKER_REDIS_ADDR unset>}"
    ccache -s 2>/dev/null || echo "  (no stats)"
  } >> "$R/report"

  if [ "$status" -ne 0 ]; then
    # Compiling is the whole job when it fails: return the diagnostics as the
    # result rather than fanning out over a binary that does not exist.
    { echo; echo "FAILED: the test binary did not compile (nim exited $status)"; } >> "$R/report"
    caos put "$R" /cas/out
    exit 0
  fi
  cp /tmp/build/tests "$R/bin"

  # The tree the BINARY needs at run time, which is not the tree it was built
  # from: no .nim, so it does not move when a source edit leaves the binary
  # unchanged. Built here because this is where /cas/args/ws is already
  # materialized. `ws` still rides along — fanout greps the sources for test
  # names, and only the MAPPER gets the runtime tree.
  runtime_tree /cas/rtws /cas/args/ws

  fwd=("--worker1:@=/cas/args/worker1" --stage=fanout
       "--ws:@=/cas/args/ws" "--rtws:@=/cas/rtws" "--runner:@=/cas/args/runner")
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
  caos get /cas/args/rtws

  # The binary is curried into the MAPPER, so every job names the same blob by
  # the same hash — stored once, not copied per child. The mapper is curried
  # HERE, where the image (/cas/args/base) is a genuine tree.
  # A tree rides along with the binary because the binary NEEDS ONE AT RUNTIME:
  # nim bakes currentSourcePath at compile time, so the tests resolve their
  # fixtures against the directory they were COMPILED in. Both are curried into
  # the mapper, so every job names the same two hashes, each stored once.
  # --ws here is the RUNTIME tree, not the source tree. That is the whole point:
  # these two hashes are every child's ArgTree, so if either moves when the
  # binary has not changed, the entire suite re-runs for nothing.
  mapper=$(caos curry --base:@=/cas/args/base \
    "--worker1:@=/cas/args/runner" \
    "--ws:@=/cas/args/rtws" \
    "--tests:@=/cas/args/in/bin") || fail "currying the per-job test runner"

  only=""
  if [ -e /cas/args/only ]; then caos get /cas/args/only; only=" $(cat /cas/args/only) "; fi
  salt=""
  if [ -e /cas/args/test-salt ]; then caos get /cas/args/test-salt; salt=$(cat /cas/args/test-salt); fi

  # Test names come straight out of the source: 570 `test "..."` and 83
  # `suite "..."` — exactly what the binary reports — with zero computed names,
  # so a grep is complete rather than approximate. No listing pass needed.

  # Modules fanned out one job PER TEST instead of one job per module. ONE
  # module belongs here, and the list was measured, not reasoned about — full
  # salted runs on an idle box, interleaved to cancel thermal drift:
  #
  #    58 jobs (empty list)                        152s
  #    74 jobs (this)                              109s
  #   109 jobs (+ test_mapgen, + test_four_team)   114s
  #
  # Both directions cost. Empty, test_map_editor_core's 17 tests run in one
  # 118s job that sets the wall clock by itself. Wider, the extra 35 jobs each
  # re-fetch and re-materialize the tree — 385ms uncontended, and it is CPU
  # they take from the tests, not just bytes (see the header). Adding a module
  # here has to beat that, and only one does.
  #
  # NOT here, deliberately: test_replay_switch_caches, whose 21s is 20s of ONE
  # test (`invalidateBoardMapCaches stops serving the previous sim's map`).
  # Splitting a module cannot split a test — caos selects tests by name and a
  # name is indivisible — so it is the floor until the test itself is broken
  # up, the way tests/test_map_editor_core.nim's 73s baseline was.
  PER_TEST="test_map_editor_core"

  # One child per job. --test-salt rides in EVERY child and nowhere else, so a
  # fresh value re-runs the tests and leaves the compile a cache hit. Nothing
  # reads it: its presence in the child is what moves the key. Do not "clean up"
  # the unused write — it is the whole mechanism.
  emit() { # $1 = child name, rest = the test names that job runs
    local child=$1; shift
    mkdir -p "/tmp/sel/$child"
    printf '%s\n' "$@" > "/tmp/sel/$child/names"
    if [ -n "$salt" ]; then printf '%s' "$salt" > "/tmp/sel/$child/salt"; fi
  }

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
      # on every startup of the binary — i.e. in every job, not none. They
      # simply cannot be fanned out, having no test names to filter on.
      echo "$m" >> /tmp/skipped/list
      continue
    fi
    case " $PER_TEST " in
      *" $m "*)
        # `<module>--NN`: unique and stable, and it keeps the module name at the
        # front so a split module's jobs read together in the report.
        i=0
        while IFS= read -r t; do
          i=$((i + 1))
          emit "$(printf '%s--%02d' "$m" "$i")" "$t"
        done <<< "$names"
        ;;
      *)
        mapfile -t all <<< "$names"
        emit "$m" "${all[@]}"
        ;;
    esac
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

  : > /tmp/allphases
  for d in /cas/args/children/*/; do
    [ -d "$d" ] || continue
    m=$(basename "$d")
    st=$(cat "$d/status" 2>/dev/null || echo "?")
    ms=$(cat "$d/ms" 2>/dev/null || echo 0)
    cat "$d/phases" >> /tmp/allphases 2>/dev/null || true
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
    # By the ms column. -k1,1 explicitly: the whole-line fallback only sorted
    # correctly because %6s right-aligns, and would break at 7 digits.
    sort -rn -k1,1 /tmp/lines
    # SUMMED ACROSS EVERY JOB, in slot-seconds. What decides whether splitting a
    # module further helps is not one job's overhead but the total: each extra
    # job re-materializes the test binary and the source tree, and there are
    # only 8 runner slots to spend that on. Reported so the PER_TEST list above
    # can be tuned against a number rather than a guess.
    # Pure bash: the worker image carries coreutils and grep, not awk.
    if [ -s /tmp/allphases ]; then
      echo
      echo "fan-out cost, summed over all $((pass + failed)) jobs:"
      order=(); declare -A tot=()
      while IFS= read -r pline; do
        case "$pline" in *"---- job total"*) continue ;; *ms) ;; *) continue ;; esac
        key=${pline%%:*}; key=${key#  }
        val=${pline##*: }; val=${val%ms}
        [ -n "${tot[$key]+x}" ] || order+=("$key")
        tot[$key]=$(( ${tot[$key]:-0} + val ))
      done < /tmp/allphases
      for key in "${order[@]}"; do
        printf '  %-22s %6s.%03ds\n' "$key" "$(( tot[$key] / 1000 ))" "$(( tot[$key] % 1000 ))"
      done
    fi
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
    echo "jobs: $((pass + failed))   passed: $pass   failed: $failed   cpu: $((total_ms / 1000))s"
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
