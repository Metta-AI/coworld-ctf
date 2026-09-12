# Lessons from the resumed navigation loop

1. **Use the shipping compiler flags.** Production enables Nim stack traces
   even in release builds. Eleven frequently called helpers spent substantial
   work maintaining frames. Explicit local inlining/frame omission improved
   whole-game time while preserving checks and framed callers; a global
   diagnostics-disable comparison would not have qualified this change.
2. **Sampled self time is not a ceiling on an inlining win.** Calls, argument
   handling, error propagation and register effects also live in callers. The
   H3 improvement exceeded the peer's estimate. Timing established the gain;
   the exact split between those mechanisms was not measured.
3. **A stage win is not the 512 target.** H1 and H2 improved same-budget speed
   but still missed comparison with original 256. Keep those misses visible.
   Do not reduce mint work or reprice units to make the displayed budget pass.
4. **Validate benchmark inputs before timing.** A different replay seed did
   not make the golden fixture a different map. Two old match maps could not
   boot under current pickup-pool validation. Keep failed inputs and choose
   replacements before seeing candidate performance.
5. **Measure who controls the cogs.** Native zone-escape reflexes can suppress
   all guest stepping for hundreds of ticks. A moving-play filename alone does
   not establish moving-goal coverage. Inspect installs, profiles, revisions,
   live seats and reflex windows; retain every whole-game frame.
6. **Pin binaries and guest bytes, not just config JSON.** Configs reference
   gitignored WASM modules. Record source, compiler, binary and guest hashes,
   and distinguish old-base evidence from a refreshed-main campaign.
7. **Use standard private-field test support.** Nim's std/importutils
   privateAccess can inspect diagnostic state without exported production
   fields or hand-maintained unsafe layout mirrors. Heap-operation oracles
   still use include to reach private procedures, a different requirement.
8. **Separate numeric provenance from decisions.** Full float hashes can
   differ across libm implementations while paths and counters agree. A
   three-tick dump showed some hypot differences round away before storage.
   Do not claim that identifies every later internal difference or that a
   sampled counter digest proves identical pop order.
9. **Keep experimental failures reproducible.** Archive failed boots, slower
   repetitions, all burst frames and incomplete campaigns. Freeze criteria
   and replacements before running them; never relabel an old miss as a pass.
10. **Keep tools from exposing credentials.** Start Claude in safe-mode and
    inspect numeric PIDs/times only. A macOS process command field unexpectedly
    expanded to an MCP launch command containing a secret earlier in the run;
    the user was notified and that unused client was stopped. The value is not
    in these artifacts. Credential rotation remains an owner follow-up.

## Qualification and restoration follow-ups

- Keep a separate verdict for each workload and CPU placement. The candidate
  passed older m5a, AMD c6a and Intel c8i-flex comparisons; fleet timing must
  still be described as representative testing, not production contention.
- Preserve exact guest bytes, not just build source and a hash. A local rebuilt
  edge_ride module differed from the tested native copy; archive the pinned
  bytes and verify them independently before claiming restoration is complete.
- Do not divide diagnostic counters without checking their definitions. Stale
  and no-path are measured before planning, pending afterward, and movement
  counts direction masks. They are not nested states; aggregate declines do
  not prove every request finishes sooner or every movement is useful.
- Distinguish direct observations from structural guarantees: same-budget 512
  equality was measured on training screens, while held-out exactness used256.
  Output-preserving mechanisms support the broader expectation, but do not
  relabel that inference as an experiment that was never run.
- Tiny helper stack-frame costs can be material in a production Nim build.
  Preserve global stack traces and bounds checks, record the exact helpers,
  and acknowledge that nested selected helpers can omit a whole call chain.
