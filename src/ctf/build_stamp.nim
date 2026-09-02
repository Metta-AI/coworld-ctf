## The engine build stamp: a content hash of the sim-relevant sources this
## binary was compiled from (tools/sim_sources_stamp.sh), injected at build
## time via `-d:ctfSimSourcesStamp=<hash>`.
##
## WHY IT EXISTS. GameVersion is bumped by hand, so sim-behavior changes can
## (and did, 2026-09-01: the post-#347 engine train) land WITHOUT a bump.
## Two builds can then both say GameVersion 50 and still re-simulate the
## same recorded inputs to different hash chains. The stamp is the
## machine-derived version underneath the hand-bumped one:
##
## - The static replay viewer exports it (ctf_sim_sources_stamp_ptr/len in
##   replay-viewer/ctf_replay.nim) so CI can compare the COMMITTED wasm
##   bundle against the sources at HEAD (tools/qa_module_eval.cjs) — the
##   same-GameVersion drift the #347 tripwire is blind to by design.
## - The replay writer records it in the header configJson ("engineStamp",
##   src/ctf/replay_codec.nim) so playback can tell an EXPECTED cross-build
##   hash mismatch (old recording on a newer engine, or vice versa — show a
##   quiet chip) from a SAME-build mismatch (a true determinism break —
##   keep the loud red banner). Old replays carry no stamp and old configs
##   ignore unknown keys (sim_config.nim `update` reads keys selectively),
##   so both directions of skew keep loading exactly as before.
##
## The hosted game image gets the define from the upload workflow
## (.github/workflows/upload-coworld-paintbot.yml exports SIM_SOURCES_STAMP,
## compose.yaml forwards it as a build arg, the Dockerfile passes it to nim).
## Empty ("") in builds that did not pass the define — tests, ad-hoc dev
## builds, a local `coworld build` without the variable. An empty stamp
## claims nothing: recordings carry no stamp and the viewer never claims a
## mismatch is same-build.

const ctfSimSourcesStamp* {.strdefine.} = ""
