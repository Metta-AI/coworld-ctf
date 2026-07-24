# Eval-harness build config (a .nims, not a nim.cfg: the repo's root nim.cfg is
# nimby-generated and gitignored, so committed per-project config uses .nims —
# same convention as tests/config.nims). The nimby package --path entries come
# from the root nim.cfg, read as an ancestor of this project file.
switch("path", thisDir() & "/../../../src")  # ctf/sim, ctf/global (the engine).
switch("path", thisDir() & "/..")            # baseline/protocols (via include).
switch("define", "ctfEvalHarness")           # suppress the included baseline WS main.
