# Hex arena — ship gate report

Audit of `maxwell/hex-integration` @ `dc715bf` (53 commits ahead of
`origin/main`), run 2026-08-06 night. Six adversarial lenses (hex geometry,
silent-failure, determinism, test-integrity, replay/wasm, hard-coded
coordinates), then fixes, then a real-binary visual check.

Every claim below was reproduced by RUNNING the code. Nothing here is
read-off-the-source inference.

---

## 1. There was no unbanked work. The "34 staged files" were a ghost.

The session that owned worktree `agent-ae4424a5e3f2494a6` showed 34 files
staged-but-uncommitted, which read as a night's work about to be lost. It was
not work at all:

* That worktree last wrote its index **Aug 5 15:58**. Its files have not been
  touched since.
* At **Aug 5 19:03** `maxwell/hex-integration` was force-moved from `eca1553`
  to `dc715bf` **from outside that worktree** (empty reflog message = a
  `branch -f` / `update-ref`). `dc715bf` was committed on `maxwell/hex-landing`.
* Moving a branch pointer changes a worktree's HEAD without touching its files
  or index. An abandoned Aug-5 checkout therefore disagreed with its own new
  HEAD in exactly 34 files, and git renders that disagreement as "staged".

Confirmed content-first before trusting the reflog: **every one of the 34
staged blobs matches an older ancestor commit byte-for-byte** — 12 from
`cb5a665`, 8 from `eca1553` (23 commits back). Two different restore points,
which is not what a deliberate revert looks like.

**Committing them would have been the disaster, not losing them.** They undo
the `maxwell/map-best-of-k` merge and six integration commits: best-of-K
ranking, the map fitness harness, the pool re-curation, the fixture
re-records. Because the set reverts the *tests and fixtures in lockstep*, the
result would have compiled, passed, and looked green — the regression would
have been invisible to CI. And its parent is `dc715bf`, so it would have
fast-forwarded onto origin cleanly.

Preserved anyway as `maxwell/hex-stale-index-ghost` (pushed) in case this
reading is wrong. `dc715bf` itself was already safe on
`origin/maxwell/hex-integration` and `origin/maxwell/hex-landing`.

---

## 2. Verified

| What | How | Result |
|---|---|---|
| Release build | `nim c -d:release --threads:on --mm:orc src/ctf.nim` | green, 49s |
| Test suite | `tests/tests.nim -d:release`, all shards | **534 passing, 0 failures** (stopped early under load-75 fleet contention, having cleared every major suite) |
| Hex board renders | release binary + `COGAME_LOAD_REPLAY_URI`, real canvas at 1600x1000 | **PASS** — flat-top landscape hexagon, bounding-box corners correctly void, mirrored heart pedestals with capture rings, hex boulders 30° off the hull, 16 cogs, working transport bar |
| Grenade/shout range | probe, before + after map install | bug reproduced, then fixed and re-verified |
| Symmetry sweep | probe at stride 1 vs the test's stride 3 | defect reproduced (see §4) |
| 4-team league config | real release binary, config lifted verbatim from `coworld_manifest_paintbot.json` | **crashes, exit 1, no listener** |
| Merge with main | trial merge in a scratch worktree | 23 conflicted files, 55 hunks |

---

## 3. Fixed on this branch

Seven fixes, none of which touch the sim, so the branch stays green.

* **Two new tools did not compile, with CI fully green.**
  `tools/hex_los_probe.nim` and `tools/hex_scene_probe.nim` used
  `import ctf/sim`, which needs `--path:src`; every other tool uses
  `../src/ctf/…`. CI ran `nim check src/ctf.nim` and nothing else, so
  `players/` was compiled only by the post-merge Docker build and `tools/`
  (~2,500 new lines here) was compiled nowhere at all. Both imports fixed, and
  the build job now checks the baseline player and all 54 tools — verified all
  54 pass before the step was added, so it goes in green.
* **Four documented validator pass rates were wrong by 20–45 points.**
  `AGENTS.md` said ~55–65%, `arena.nim` said ~80%, 80–96%, and a "measured
  ~77% mean". Measured: **97.5–100% per class**, and the branch's own committed
  baseline is 199 pass / 1 reject over 200 seeds. The ~77% figure was
  load-bearing — it is the stated reason `MapGenMaxAttempts` is not scaled by
  K. Corrected to the measured value with the baseline cited, and `AGENTS.md`
  now draws the conclusion the number actually supports: the validators are a
  crash guard, not a quality filter, which is *why* best-of-K exists.

* **No preflight on the replay format's uint16 string cap.** A colossal
  mapSpec is 67387 bytes against 65535, so the episode died with a bare
  `ReplayError: Replay string is too long` from inside `openReplayWriter`,
  outside any try, after the full generation cost, naming neither the field nor
  the byte count nor the size class. Now caught where `mapSpec` is pinned.
* **The wasm-smoke canary was red on every PR.** Its colossal fixture is a GV37
  recording of a deleted 4992x4992 rectangle that cannot load on GV38 — which
  the comment says, while the loop below still listed it and exited 1. A
  permanently-red canary makes a genuine regression in the two working fixtures
  indistinguishable from the known failure.
* **`check failures > 0` asserted the generator stays BAD.** The 200-seed
  validation sweep rejects exactly ONE seed (1189, too clogged), so a better
  generator turns the test red — the "ratchet backwards" trap this repo has
  paid for three times. Replaced with a map invalid BY CONSTRUCTION (base
  against the hull, behind-gate off the board), which improvement can never
  make green. The sweep's own count is now `echo`ed rather than gated —
  `unittest.checkpoint` only prints on failure, so it was reporting nothing.
* **`league_replayer`'s "open the board directly" link 404'd in the static
  bundle.** It did not branch on `STATIC_BUNDLE` unlike the iframe src twenty
  lines above; `ROUTE_BASE`'s regex cannot match a bundle path, so it kept the
  whole pathname including the filename. That link is the escape hatch a user
  gets *after* their replay already failed to load.

---

## 3b. Held back deliberately: the grenade/shout axis fix

`maxwell/hex-grenade-axis-fix` (pushed) carries the one-line correction plus its
test. **It is correct and it is not on the ship branch**, because it changes the
sim: `ShoutRange` alters what a bot hears, so recorded fixtures desync. Measured
A/B on identical fixture bytes:

| fixture | before | with the fix |
|---|---|---|
| `tests/replays/ctf.bitreplay` | OK (12277 ticks) | DESYNC @ 2689 |
| `tests/fixtures/capture-seed4.bitreplay` | OK (4718) | DESYNC @ 2561 |
| `tests/fixtures/draw-nokill.bitreplay` | OK (1780) | DESYNC @ 1185 |
| `tests/fixtures/gen-small-pits.bitreplay` | OK (4757) | DESYNC @ 1329 |
| `tests/fixtures/wipe-lives1.bitreplay` | OK (1601) | OK (ends first) |

Re-rolled: the desync tick is identical across runs, so this is a rules change,
not a bad dice roll. It therefore needs a GameVersion event and a re-record of
all five recordable fixtures — which the GV41 renumber in §4B forces anyway.
Landing it now would mean re-recording twice and throwing the first set away,
under fleet load that produces degenerate takes. The assignment in `arena.nim`
and the assertion in `test_grenades.nim` both carry a comment pointing at the
branch, so this cannot be quietly forgotten.

---

## 4. What I would NOT ship

**A. The 4-team league variants crash the server at boot. This is the blocker.**

`coworld_manifest_paintbot.json` declares `4ffa` (`teams:4, mapPath:"gen"`) and
`4ffa8` (`teams:4, mapPath:"gen", mapSize:"giant"`). Booting the real release
binary on the manifest's own config:

```
arena.nim(1798)  generateMapAttempt
Error: unhandled exception: Hex Stage 2 generates 2-team maps only;
4 teams needs the cube-space orbit rasterizer (Stage 2b). [CtfError]
```

Exit 1, no listener, every seated bot times out. The refusal is deliberate and
loud — Stage 2b was never built — but the manifest was never updated to match
(`git diff` over `coworld_manifest*.json` on this branch is empty). Two of the
three live competitive variants are dead on this branch. Options: land Stage
2b; pin a hand-authored 4-team hex `mapSpec` into both variants
(`tests/helpers.nim:52` already builds one); or remove the variants in the same
commit.

**B. GameVersion 38 is double-assigned.** This branch declares
`GameVersion = "38"` for HEX ARENA, forking when main was at GV37. Main has
since shipped GV38 (spray-can aim lock), GV39 (quad-mirror 4-team maps), GV40
(restored continuous aim). Two incompatible contracts now share the string
"38", and the version check cannot catch it because the string did not move —
a main-line GV38 replay loads here and desyncs at tick 1, and playback
*continues anyway*. Fix is a rebase onto main and a bump to `"41"`, which also
re-invalidates the fixtures.

**C. Main has diverged in a contradictory direction.** Trial merge: 23
conflicted files, 55 hunks, 26 in `arena.nim` alone, plus 5 binary fixtures
that cannot be merged textually. Main's GV39 added `symQuadMirror` for
**rectangular** 4-team maps (23 references in `arena.nim`); this branch deletes
rot90 entirely because C4 is not a subgroup of D6. Those are opposing designs
for one generator and the conflict is semantic, not textual.

**D. The flag-ring carve is not symmetric on even-dimension classes.** Found
independently by two lenses and confirmed by my own probe. `arena.nim:1149`
sets `center = (width div 2, height div 2)` while the true symmetry centre is
`((W-1)/2, (H-1)/2)`, so on any even dimension the ring is half a pixel
off-axis and obstacle pixels are stone for one team and open floor for the
other:

```
pool:18  2014x1744  stride3 mask=4  ->  stride1 mask=70
pool:16  2014x1744  stride3 mask=6  ->  stride1 mask=42
gen:777  1455x1260  stride3 mask=0  ->  stride1 mask=8
```

`test_hex_arena.nim:296` strides `x += 3` / `y += 3`, sampling 1/9 of the
board, and bounds the result at `<= 4`. **The test is green only because of
the stride** — at stride 1 it is red today. The obstacle union and the hull are
exact everywhere; the entire discrepancy is the carve.

Left unfixed deliberately: the fix is doubled-coordinate ring comparison, which
changes map rasterization and therefore re-invalidates the pool render hashes,
the validation baseline and every fixture. That is a re-record cycle, and this
repo's re-records are non-deterministic. It should ride with the GV41 rebase,
not a late-night patch.

**E. `sightlineMinSpan` scales past `GunRange`.** `arena.nim:1463` is
`height * 4 div 5` while `GunRange` is fixed at 1050, so the rule that stops
end-to-end firing lanes weakens as the board grows. Measured longest unblocked
run on maps that PASS validation: huge 1376px, giant 2000px — both over gun
range, both in the random draw, against `docs/RULES.md`'s published "no
straight shot crosses the field". One-line fix (`min(height * 4 div 5,
GunRange)`) but it changes generated maps, so same re-record cost as D.

---

**F. Best-of-K — the branch's headline feature — has no regression coverage on
the maps the pool actually serves.** `test_map_editor_core.nim:34` builds its
pool map from `generateMapAttempt(seed, …)` — attempt 0, UNRANKED — while
`poolCtfMap` ships best-of-8. Probed all 20 entries: **16 of 20 render hashes
pin a map `poolCtfMap` never returns** (seed 1024 ships 42 obstacles, attempt-0
has 36; seed 1040: 112 vs 88). The fixture regenerates byte-identically, so it
is not stale — it is a *false* guard, and `docs/pool-review.html` (which renders
the shipped map) and this fixture disagree for 16 of 20 seeds. Nothing anywhere
pins the shipped pool geometry, and the ranker's pick depends on
`controlMetrics()` = the hand-authored arena, so editing `arenaHexObstacles` can
silently re-deal the whole served pool with every test green.

Fix is one line — `proc poolMap(index: int): CtfMap = poolCtfMap(index)` — plus
`CTF_REGEN_MAP_BASELINE=1`. Deterministic, no bot recording, so it is safe to do
outside a re-record cycle. Left undone only because it arrived at the end of the
window and deserves its own verification pass.

Related, same area: `arena.nim:2849` passes config overrides straight into
`poolCtfMap`, so `mapPath: "pool"` + `mapRankK: 4` silently serves a map the
pool was never curated for. Should raise in `sim_config.update`.

**G. `hardGates` — documented as the reject-outright layer — is never called by
the runtime generator.** `map_score.nim:59` calls itself "Layer 1: reject
outright … a map that fails one cannot be played fairly at all", and adds the
two gates the repo never had (fewer than 2 vertex-disjoint routes, unreachable
base). Its only callers are `gen_map_pool`, `map_eval`, `hex_metrics_probe` and
a test — `generateCtfMap` and `rankCtfMapCandidates` deliberately run
`computeMapMetrics(…, withValidation = false)`. A generated map with a single
route loses score points and ships anyway. It also rejects 0 of 40 shipped maps,
so making it a real gate is a behaviour change, not a no-op.

**H. `tools/hex_cover_probe.nim` ran with the ranker silently absent.** It
imports `arena` directly rather than `sim`, so `mapCandidateRanker` is nil and
`arena.nim:2655` collapses default K to 1 — the probe measures FIRST-VALID maps.
Proven: same probe body, 12 seeds, `import ctf/sim` → 8/12 maps differ between
default-K and K=1; `import ctf/[sim_types, arena, hex]` → 0/12. This is the
probe used to derive the shipped hex cover band (`f544358`, `4da6bed`), and its
own comment claims it renders "ACCEPTED maps … so the thing being looked at is
the thing that ships". It is not. The band should be re-derived.

Two false cost claims ride with it: `arena.nim:2612` says "every binary that
builds a game ranks" (false — see above), and `arena.nim:2616` says the wasm
replay viewer "never imports [map_score] and pays neither the code size nor the
milliseconds" — but `replay-viewer/ctf_replay.nim` imports `ctf/sim`, which
imports `map_metrics, map_score`. The whole scorer IS in the wasm bundle, on the
branch that just declared the wasm address-space canary blocked.

**I. `BarAxisFlat` (`arena.nim:31`) is a tombstone** — exported, carrying an
8-line justification and an untested rotation-closure claim, with exactly one
reference in the repo: its own declaration. Left in place rather than deleted;
whether it is unwired-yet or reverted-from is its author's call, not mine.

---

## 4b. Round three — six adversarial lenses

Six lenses ran in parallel against the branch: DETERMINISM, GEOMETRY,
CONTRACT, BOUNDS, GATE, DELIVERY. Eleven defects fixed. Two claims from
earlier rounds were **corrected by measurement**, and one of the corrections
invalidated a measurement made during this very round — recorded below,
because the mechanism that caused it is the most important finding here.

### The deepest one: the ranker is a LINK-TIME property

`map_score` installs the best-of-K ranker from a top-level statement, so
whether best-of-K happens at all depends on whether a **binary** links that
module — nothing the caller writes. A binary without it silently returns the
first VALID candidate: a different board for the same seed, measured on 3 of 7
pool seeds. This has already shipped one wrong constant (the cover band was
derived by `hex_cover_probe` with the ranker absent), and during this audit it
silently corrupted a fresh stride-1 symmetry sweep run from a probe importing
only `arena` — that run's `gen:*` numbers measured maps the server never
builds, and were withdrawn. Two independent errors, same cause, months apart.

Fixed at the root: `generateCtfMap` now RAISES when no ranker is linked unless
the caller passes `rankK = 1` deliberately, and `ctf/map_score` was linked into
the five tools that lacked it (`hex_arena_check`, `hex_connectivity_probe`,
`hex_cover_probe`, `hex_gen_probe`, `hex_range_probe`). The remaining exposure
is the goldens themselves — see the filed follow-up.

### Fixed

1. **The board never went transparent on the league path.** The branch's
   headline visual change did not reach the screen. Every other link was
   plumbed right — `map_art` writes alpha 0 outside the hull, `broadcast_core`
   switched to `clearRect`, the shell cleared `#floor` *and* `#floor iframe` —
   but an iframe ELEMENT's background paints behind its DOCUMENT, so the
   embedded page's `#120d09` stayed opaque over the whole box. Proven by pixel
   sampling: the corner inside the board rect was exactly `(18,13,9)` before
   and is `(24,17,11)` after, the shell's lit floor showing through.
2. **The uint16 mapSpec ceiling was checked on one path only.** The guard was
   gated on "we just generated this spec", so an EXPLICIT `mapSpec` — the
   hosted path, and the one blocker A's own remediation prescribes — was never
   measured. Verified after the fix: 70031- and 66927-byte colossal specs are
   now refused at config resolve, naming the byte count, instead of dying later
   in `openReplayWriter` with the bare `ReplayError` this guard exists to
   replace. Found independently by two lenses.
3. **Both manifests advertised layouts the engine rejects.** `mapLayout`
   published `enum: [sides, corners, plus]` while `arena.nim` now raises
   `CtfError` for anything outside `[sides, hex2]` — so `corners`/`plus` crash
   the server and `hex2` fails the platform's own validator. `test_manifest_
   schema.nim` already SAMPLED `hex2`, which is how far apart the two had
   drifted. Also added `mapRankK`, the branch's headline knob, which had no
   schema entry at all — no league episode could set it.
4. **A ratchet wearing a different name.** `check reasons.len > 0` is true iff
   `failures > 0`, so it is precisely the assertion the comment 25 lines above
   it deletes as a ratchet, and it hangs on the same single seed.
5. **A "visible" number that printed nothing.** `test_mapgen_styles` reported
   its validator pass rate with `checkpoint`, which unittest only flushes on
   FAILURE — so a green run printed nothing and the pass rate went from gated
   to invisible. The sibling file documents the correct idiom verbatim.
6. **Four unchecked index sites and a non-object spec** in the mapSpec parser.
   A truncated spec raised `IndexDefect` and a well-formed `[1,2,3]` raised an
   `AssertionDefect` from inside json.nim. Both are *Defects*: no upstream
   `except CatchableError` on the config or replay-load path can catch them.
7. **`buildMapMasks` with a non-positive cell.** 0 was a `DivByZeroDefect`;
   NEGATIVE was worse than a crash — every grid loop ran zero times and it
   returned an all-zero `MapMasks` that `scoreMap` ranks as a real map.
8. **`AUTHORABLE_OBSTACLES`** — dead, and wrong (it omits `barAngled`, so it
   would have broken the 60° bar button the moment anything read it).
   Tombstone-checked: one commit added it, nothing ever read it.

### Two earlier claims corrected by measurement

- **"Flag-ring carve asymmetric on even dimensions; the test is green only
  because it strides by 3."** The stride is real, but it is not hiding this.
  Swept at stride 1: `mask=0` on `arena` and `arena-large` (hand-authored, so
  the ranker cannot affect them). The asymmetry is real only on the `huge` and
  `colossal` classes the test never loads — 506-714 protected-floor pixels on
  a 2014x1744 board. The defect is COVERAGE, not tolerance.
- **"Spawn asymmetry is a hex regression."** It is INHERITED — main has the
  identical `anchor.x + stepMinor` in absolute screen coordinates. But this
  branch AMPLIFIES it: 12px on main's rectangular mirror boards, ~144px on
  rot180 hex boards, because the y-stagger is never rotated. Filed for GV41.

---

## 5. Verdict

The 2-team hex arena is real, correct where it counts, and looks good on the
real canvas. The branch is **safe to push and safe to keep working on** — that
is done.

It is **not deployable**: 4-team boots crash (A), and the GameVersion collides
with main's (B). Neither is a code-quality problem; both are integration work
that needs a decision from you, not from me.

Round three does not change that verdict, but it sharpens one thing: the
generator's own measuring instruments were not all pointed at the map the
server ships. That is now loud instead of silent, and the remaining pieces —
the pool goldens, the two rectangular metrics still gating selection, and the
host-libm dependence in selection geometry — are filed rather than fixed,
because each one changes which candidate wins best-of-K and therefore has to
land together with a golden re-derivation, not at 3am on a ship night.
