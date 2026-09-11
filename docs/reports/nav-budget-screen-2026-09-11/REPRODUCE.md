# Reproduce the real-server screen

Use a fresh disposable checkout of `83e60c243ed20aa7c756f372306768066054644e`
on native Linux amd64. All paths below are benchmark-owned paths; do not run
source variants in a user's working checkout. Timing on an emulated Docker
process is not comparable.

The existing `coworld-nav-c0:latest` image is the production Dockerfile's
`build` stage from the archived research, using Nim 2.2.4. The source tree is
replaced by the fresh bind mount and `nimby --global sync nimby.lock` runs
again. `measurement-image.Dockerfile` adds Python 3 for orchestration only.
The recorded image ID identifies the actual environment used. To establish a
new environment without that cached image, build the production Dockerfile's
`build` stage at the pinned commit, then add Python in the same way; record its
new image ID and treat results as a new run.

Create empty results and copy the original source as the checkout's owner
before starting the container (the original run used the paths below):

```sh
git -C /home/ubuntu/nav-budget-screen-20260911 rev-parse HEAD > /home/ubuntu/nav-budget-results-20260911/baseline-commit.txt
cp /home/ubuntu/nav-budget-screen-20260911/src/shell/body_nav.nim /home/ubuntu/nav-budget-results-20260911/body_nav_base.nim
```

Copy `prepare_native.py`, `build_native.sh` and `run_native.py` to the host,
and use the verified runtime dependency installation from
`tools/runtime_spike/fetch_deps.sh`. The original build invocation was:

```sh
sudo docker run --rm \
  -e WASMTIME_C_API=/wasmtime -e WASI_SDK_PATH=/wasi \
  -v /home/ubuntu/coworld-nav-throughput-20260909/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api:/wasmtime:ro \
  -v /home/ubuntu/coworld-nav-throughput-20260909/tools/runtime_spike/.deps/installed/x86_64-linux/wasi-sdk:/wasi:ro \
  -v /home/ubuntu/nav-budget-screen-20260911:/workspace/ctf \
  -v /home/ubuntu/nav-budget-results-20260911:/results \
  -v /home/ubuntu/prepare-nav-game.py:/prepare.py:ro \
  -v /home/ubuntu/build-nav-game.sh:/build.sh:ro \
  --entrypoint sh coworld-nav-budget:20260911 /build.sh
```

The retained scripts add explicit environment/fresh-checkout preconditions
following review. These checks do not change the compiled source. Compare the
resulting measurement patch with `server.patch`, and retain compiler, source,
guest and binary hashes. The source budget returns to 256 after the build;
server instrumentation remains only in this disposable checkout.

Run the screen once, with all `game-*` output paths initially absent:

```sh
sudo docker run --rm --name nav-budget-games \
  -v /home/ubuntu/nav-budget-screen-20260911:/workspace/ctf \
  -v /home/ubuntu/nav-budget-results-20260911:/results \
  -v /home/ubuntu/run-nav-game.py:/run.py:ro \
  --entrypoint python3 coworld-nav-budget:20260911 /run.py
```

The script records failed/timed-out runs and continues; its exit code alone
is not a success check. Inspect every `exit.json`/`failure.json`, verify all
12 expected directories and correct seat/module coverage, then analyze:

```sh
python3 analyze.py /path/to/extracted/results > summary.json
```

Preserve slow rows. Do not restart the script over existing output or replace
a failed timing run. Setup failures can be repaired in a separately named run.
Archive results before stopping the owned instance. No Coworld or softmax CLI
is used, and no hosted game, league setting or live budget is changed.
