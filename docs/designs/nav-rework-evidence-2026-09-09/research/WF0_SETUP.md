# Fresh native worktrees for the next experiment

Both owned hosts now have a clean detached worktree at `~/coworld-nav-wavefront-20260909`, commit `067a4af2e992ee2e52b57c76a26487ccdcf80cf3`, including main 3c127d1c. This was transferred as a Git bundle, not a partial source overlay. Bundle size is 17,666,673 bytes; SHA256 `934cc4f4c01d20fab44eaa3994b349eb9da83555cd938d35d96ab0d21e5f44c5`. Each host verified its prerequisite commits before fetching. The local bundle is under ignored checkpoint-inputs.

Initial setup accidentally selected Nim's bundled Nimby0.2.3, which refused to create a workspace inside the checkout. The repository Dockerfile and original native setup pin Nimby0.1.26. Re-running with the already installed `~/.local/bin/nimby`0.1.26 succeeded on both hosts; failed and successful logs are preserved. No guard was disabled.

The native parent benchmark builds on both hosts with Nim2.2.6 and the existing release/useMalloc/noSignalHandler/threads/speed flags. Build artifacts are in `~/nav-throughput-results-20260909/WF0-setup/`. Wasmtime is read from the prior owned checkout's runtime installation. No benchmark timing has run from these fresh worktrees yet. Actual Docker Nim2.2.4 qualification remains separate.
