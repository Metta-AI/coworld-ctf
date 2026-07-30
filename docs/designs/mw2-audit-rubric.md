# MW2 Map Pack v2 — Audit Rubric (100 points, ship gate ≥ 90)

Scored by an independent auditor that authored none of the work. Every criterion
states how to verify (command or eyes-on). Whole-point partial credit. Hard
gates at the bottom cap the score regardless of the sum.

## A. Reference fidelity — 36 pts (6 per map)

Per map (rust, terminal, highrise, favela, afghan, scrapyard), judged by
comparing the rendered board art (tools/mw2_gallery_regen.py output, or a
tools/dump_map_mask.nim render) side-by-side against
docs/designs/mw2-reference/<map>.png:

- **3 pts** — key named structures exist and sit in the correct *relative*
  positions (Terminal: the 747 at ONE end of the concourse; Highrise: twin
  office cores flanking the exterior; Rust: central tower + pipe runs; Favela:
  dense hillside block with alley grid; Afghan: crashed C-130 + cave arc;
  Scrapyard: plane fuselage rows between hangars).
- **2 pts** — the real map's asymmetry is preserved where it is asymmetric
  (fullObstacles, not an x-mirror blob); interior walls + door gaps present;
  shape density comparable to the reference, not sparse abstraction.
- **1 pt** — spawn pockets and objective (pedestal) placement follow the real
  map's spawn/objective logic, adapted to CTF.

## B. Playability invariants — 20 pts

- **8** — tests/test_mw2_maps.nim invariants pass for all 6: spawn→flag BFS
  reachability, no sealed pockets (1px flood, not strided), pickups/spawns on
  occupiable floor, 0 open cross-field rows.
- **8** — the NEW fairness parity test passes for all 6: occupiable-area
  ratio, cover-density ratio, and BFS spawn-pocket→enemy-pedestal distance
  ratio each within a stated tolerance — and the tolerances are justified in
  the test, not tuned-to-pass.
- **4** — the "mw2" rotation alias still resolves per seed and the replay
  header records the concrete map.

## C. Engineering quality — 14 pts

- **6** — full test suite green on the rebased branch (auditor reports exact
  pass counts from a run they executed themselves).
- **4** — release build clean; all six floor PNGs tracked (an untracked
  floorTex crashes clean-checkout boot); no stray debug defines.
- **4** — code matches sim.nim idiom (const shape list + constructor per map,
  registered in loadCtfMapMetadata); no dead v1 geometry left behind.

## D. Verified like a user — 20 pts

- **12 (2/map)** — fixture replay recorded and served per map
  (release bin/ctf-server, run-mw2-preview.sh); screenshot judged: rendered
  geometry matches the mask, floor art aligned with walls, no console errors.
- **4** — the MAP banner chip shows the correct map name in both
  replay_broadcast.html and league_replayer.html (staticRead-baked — verify on
  a freshly rebuilt binary, not a stale one).
- **4** — a real 16-bot episode plays sanely on each map: no bot permanently
  stuck at spawn, at least one capture attempt occurs, no pathological
  camping corner created by new geometry.

## E. Ship readiness — 10 pts

- **4** — tooling committed (mw2_gallery_regen.py, mw2_gallery_watch.sh,
  run-mw2-preview.sh); reference images committed or durably linked.
- **3** — GameVersion decision made and justified from label_manifest/fixture
  test evidence (bump iff default arena masks changed).
- **3** — PR body carries per-map reference-vs-result image comparison;
  design doc + RULES.md updated to match what shipped.

## Hard gates — any violation caps the score at 89

- Any map still effectively an x-mirror blob where the real map is asymmetric.
- Any invariant or fairness test failing.
- Any floor PNG untracked.
- No eyes-on screenshot evidence for a map.
- Layout authored from model recall instead of the acquired reference.
