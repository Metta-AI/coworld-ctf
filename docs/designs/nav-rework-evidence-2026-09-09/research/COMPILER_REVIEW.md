# Compiler review: production C flags, exact CPU targeting, and the floor call

Written 2026-09-09 by Claude (peer) for `COMPILER_REVIEW_BRIEF.md`. Review and preregistration
only: no source edits, no flags added anywhere, no benchmarks run. The only execution was a
codegen inspection of a 20-line C probe in a throwaway amd64 GCC container (assembly output,
no timing).
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. What production actually compiles with

- Docker (`Dockerfile`): `debian:bookworm-slim`, nimby `use 2.2.4`, build arg
  `NimFlags="-d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on"`, applied to
  `src/ctf.nim` and `src/paintball_player.nim`. No `-march`, no `--passC`. The image is
  built for both amd64 and arm64 (nimby is fetched per arch), so any x86 flag must be
  amd64-only.
- Nim's own C flags for `-d:release --opt:speed` on gcc are `-O3 -fno-strict-aliasing`
  (plus `-fno-ident`); Nim does not pass `-std=`, so GCC is in GNU C mode, where the
  documented default is `-ffp-contract=fast` ("The default is -ffp-contract=off for C in a
  standards compliant mode ... -ffp-contract=fast otherwise", GCC Optimize-Options). That
  default is inert today because the baseline x86-64 target has no FMA instructions; it
  becomes live the moment `-march=x86-64-v3` is added.
- Compiler versions: Docker bookworm ships GCC 12.2; my probe used the `gcc:12-bookworm`
  image (12.5). The benchmark hosts' GCC versions are not recorded in any manifest; Codex
  should add `gcc --version` to the run manifests. Nim: B0 and later hosts 2.2.6, CI
  `build.yml` 2.2.10 (2.2.12 rejected for a fuel shift), Docker 2.2.4. Nim version affects the
  generated C little; the C compiler and its flags are what this review is about.
- Nim's `std/math` binds `floor`, `ceil`, `round`, `sqrt`, `hypot` directly to libm
  (`importc: "floor"` and so on, `lib/pure/math.nim:368-759`), so what GCC does with those
  calls is what the game does.

## 2. What GCC 12 emits at the production flags (probe, amd64, inspection only)

Probe: `floor`, `(long)floor`, `round`, `hypot`, `sqrt`, and a loop with the exact shape of
`packedDangerQ8` (`body_route_query.nim:308-319`: `scaled = value * 256.0`,
`lower = floor(scaled)`, ties-to-even). Flags always include `-O3 -fno-strict-aliasing`.

| Target | `(long)floor(x)` and the pack loop | `floor` returning double | `round` | `hypot` | `sqrt` |
|---|---|---|---|---|---|
| baseline x86-64 (production today) | **`call floor` per element** | inline SSE2 sequence | `jmp round` (libm) | `jmp hypot` (libm) | `sqrtsd` plus a libm call on the error path |
| `-march=x86-64-v2` | inline `roundsd $9` plus `cvttsd2si` | `roundsd` | libm | libm | same |
| `-march=x86-64-v3` | inline `vroundsd` plus `vcvttsd2si` | `vroundsd` | libm | libm | `vsqrtsd` plus error path |
| v3 plus `-ffp-contract=off` | same as v3 | same | libm | libm | same |

So the brief's question has a definite answer: yes, at the production flags the Q8 packer
pays one libm `floor` call per nonzero danger cell on every rebuild, and every observed
production CPU could execute it as a single SSE4.1 instruction. `round`, `hypot` and
`sqrt` stay libm calls at every level; GCC does not inline `round` without fast-math because
no instruction implements round-half-away-from-zero.

## 3. Where those calls sit on the per-tick path

- Hot, every rebuild: `packedDangerQ8` (`floor` per nonzero cell, up to ~42.7k cells on the
  largest pool map, one seat per tick at 32 seats; this is inside the ~0.46 ms m6i / ~1.1 ms
  m5a weight-refresh slice). The raster accumulation itself (`addVisibleCell`, `castRay`) is
  float32 adds and integer index math with no libm call.
- Per tick, small: `distance` (`hypot`, `body_nav.nim:604`) in `noteProgress` and the
  waypoint checks (a few calls per seat per tick); `pixelDistanceQ4` (`round(sqrt(...))`,
  910) in `steeringDangerCost`, a handful per steering seat per tick.
- Activation only: `attenuation` (`hypot`, 241), `pyRound` (`floor`, 208 and
  `body_map.nim:104`, used by `body_cache.nim` too), `initDangerGeometry`'s `sqrt`,
  `body_hazard.nim:186` and `body_route_index.nim:525,1000` segment lengths.
The only call site whose count scales with the raster is the packer's `floor`.

## 4. Two ways to remove the packer's libm call; only one is a compiler change

- **S1, source (preferred, not a compiler change).** In `packedDangerQ8` the value is
  strictly positive after the `value <= 0` guard, so `scaled > 0` and `floor(scaled) ==
  trunc(scaled)`; `int(scaled)` compiles to a single `cvttsd2si` at the baseline target
  (probe `f_to_int`). Same integer, same ties-to-even branch, no flag, no fleet question,
  arm64 unaffected. This is a one-line src change and is out of scope for this unit, but the
  compiler experiment below should be run alongside it so the two are not confused.
- **S2, compiler.** `-march=x86-64-v2` (SSE4.1 `roundsd`) or `-march=x86-64-v3`. v2 is the
  minimal change that inlines `floor`; v3 additionally enables AVX2 (possible vectorisation of
  the pack loop and the raster passes) and FMA, and FMA is exactly what makes v3 risky
  (section 6).

## 5. Deployment constraints

- Observed CPU flags (`B0/lscpu.txt`, `B0-c6a/lscpu.txt`, `B0-m5a/lscpu.txt`): Ice Lake
  8375C, Milan 7R13 and Zen 1 EPYC 7571 all report `sse4_1 sse4_2 avx avx2 fma bmi1 bmi2 f16c
  abm movbe xsave`, that is the full x86-64-v3 set; only the Xeon has `avx512f`. So v2 and v3
  are both executable on every host measured; v4 is not (Milan and Zen 1 lack AVX-512).
- Fleet: the jobs pool admits instance-generation > 4 in families c, m, r (handoff section 2).
  Every generation-5-or-later x86 family on EC2 (Skylake, Cascade Lake, Ice Lake, Sapphire
  Rapids, Zen 1 through Zen 4) has AVX2 and FMA. I have not verified this against an AWS
  primary source for every family; the safe statement is that all three measured families
  are v3-capable and the Karpenter rule admits nothing older than they are. A wrong guess is
  a SIGILL on a game pod, so the experiment must include an explicit `cpuid` guard or a
  fleet-wide flag inventory before any production flag lands.
- The image is dual-arch: the flag must be applied only for amd64 (Dockerfile build arg per
  platform, or a Nim `when defined(amd64)` `{.passC.}` in a single config file), and the
  arm64 and wasm builds must be shown byte-identical to today.
- CI (GitHub runners, Nim 2.2.10) and the Mac are not gated by these flags; the canonical
  Docker gate is.

## 6. Exactness: what could change bits, and how to prove it did not

- `-march` alone does not change floating-point results for `floor`, `sqrt`, integer
  conversion, or IEEE adds and multiplies; `roundsd $9` is exact floor.
- FMA contraction can. At v3 with the GNU-mode default `-ffp-contract=fast`, expressions such
  as `1.0 - fraction * (1.0 - DangerLosFarFactor)` (`attenuation`, 221-223) and any
  `a * b + c` in the hazard and steering pricing may be fused, changing the last bit, and the
  kernel feeds every raster, so the per-case `danger_hash` the quality harness asserts
  (`bench_body_nav_rework.nim:125-130`, "production danger differs") could fail, and through
  Q8 rounding the route hash could move. `-ffp-contract=off` is therefore mandatory for any
  v3 build, exactly as the brief says. It costs nothing at v2 (no FMA to contract).
- Note for the record: the Mac build uses clang, whose default is `-ffp-contract=on`
  (fusing within a statement) on an FMA-capable arm64 core, and the danger and route hashes
  match the Xeon today. That is empirical evidence that no fused expression currently reaches
  the hashed state, not a proof; the exactness checks below settle it per build.
- Exactness checks that must pass byte-for-byte for a candidate to be considered at all:
  full corpus route hash 5a1340213fe3...; every case's `danger_hash` (already asserted by
  `--quality`); `pops_per_tick` arrays equal to the parent's in all six `--tick` rows; the
  `--latency` non-timing content equal to the parent's; the activation ledger equal; arm64
  and amd64 hashes equal in the canonical Docker gate.

## 7. Preregistration for the compiler comparison (proposal; do not assume a speedup)

Parent: current source at the L1 checkpoint, production flags. Candidates, each a separate
binary from a fresh nimcache:
- K1 `--passC:-march=x86-64-v2 --passL:-march=x86-64-v2`
- K2 `--passC:"-march=x86-64-v3 -ffp-contract=off" --passL:-march=x86-64-v3`
- K3 (control for the contraction question) `--passC:-march=x86-64-v3` with the default
  contraction, quality run only, to show whether any hash moves; never a timing candidate.
- S1 (source, separate card, baseline flags) if Codex chooses to run it: `int(scaled)` in the
  packer.
Hosts: c6a first, then m5a (the host where the weight slice is 1.1 ms), then m6i; CPU 5
pinned; no concurrent benchmark. Protocol: three interleaved parent/candidate `--tick`
processes at B = 1,024, breakdown on; report `weight_refresh_p95_ns`, `danger_p95_ns`,
`route_search_ns_per_pop_p95`, whole-tick p95 and max, every repeat, worst-of-repeats,
against the A/A spread already measured on that host. Then one `--quality --activation`
per candidate for section 6. Prediction to be tested, stated before the run: K1 and K2 reduce
`weight_refresh_p95_ns` by the cost of ~N libm calls where N is the nonzero-cell count
(unknown; the harness does not emit it, so add it to the ledger or compute it offline from a
raster snapshot); no prediction for `ns/pop` (the search loop has no libm call); no
prediction for the raster rebuild. Decision rule: a candidate is worth carrying to a fleet
decision only if every exactness check passes and the weight slice improves beyond the A/A
spread on m5a; whole-tick p95 on m5a is reported but is not expected to pass headroom from
this alone (the raster rebuild dominates, `QUALIFICATION_FLOOR_OPTIONS.md` section 0).
Cost: 4 builds x 3 hosts, 6 processes per host per candidate.

## 8. What this does not establish, and what needs a decision

- No timing has been measured; section 2 is codegen, not performance. The libm `floor` cost
  per call on Zen 1 is unmeasured; the nonzero-cell count is unmeasured.
- Adding `-march` to the production image is a deployment change with a SIGILL failure mode;
  it needs the fleet flag inventory and the dual-arch build handling, and it should be
  preferred only if S1 (which needs neither) does not capture the same gain.
- Nim version alignment (2.2.4 Docker, 2.2.6 hosts, 2.2.10 CI) is a separate reproducibility
  gap: the numbers in this programme come from 2.2.6 binaries while production ships 2.2.4.
  Record it; a canonical Docker build of the harness is the way to close it, and that is
  already the ratified quality gate path.
