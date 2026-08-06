# Definition-of-done verification, item by item

Epic owner, 2026-08-06, on `maxwell/mapgen-rebuild` @ 31ec37a. Every ✅ here is a measurement I
ran myself with the arena as control and an explicit clean `--nimcache`, not a report I accepted.
Kept updated as tasks land; the closeout gate (d4196468) is scored against it.

| DoD item | status | evidence |
|---|---|---|
| suite 0 failures | ❌ **5** | was 37, zero raises; all 5 owned, all expectation re-derivations |
| 2-team >= 95% valid | ✅ **97%** | 39/40, 40 seeds, corrected stick |
| 4-team >= 95% valid | ✅ **100%** | 32/32, 32 seeds, corrected stick |
| interiorFrac >= 0.30 (2-team) | ❌ **0.291** | criterion retargeted on evidence, miss reported as a miss |
| interiorFrac >= 0.30 (4-team) | ❌ **0.240** | was 0.098; large improvement, still under the bar |
| staticScore >= old 0.939 mean | ✅ **0.961 / 0.987** | 2-team / 4-team, corrected stick |
| repair-plug share 0% | ✅ | verified below |
| 50-map sheet, nameable archetypes | ❌ | 10fc7a24 in flight; both sheets still read as one map |
| pool re-curated + pool-review.html | ❌ | c752704b not started; page stale since 1dcbb01 |
| >= 1 play result per team count w/ control | ⚠️ **2-team only** | 4-team has NO control; 44d455a1 in flight |

Two things not in the original DoD that measurement added, and that the scorecard should carry:

| added criterion | status | evidence |
|---|---|---|
| distinct maps per seed | ✅ **39/39, 32/32** | `tools/seed_distinct_probe.nim`; no per-map metric can see this |
| spec -> map identity (replays pin mapSpec) | ✅ **18/18, 11/11** | `tools/spec_roundtrip_probe.nim` |

## repair-plug share 0% — verified, with a caveat worth acting on

    grep -rniE "repairplug|repair_plug|plugshape|sightlinerepair|repairShape" src/   -> NO MATCHES

The prosthetic is genuinely gone from the source, not merely unused. The row cover that replaced it
is a construction, not a repair, and says so at `arena.nim:2299` ("an interval cover on the TRUE
mask, not a repair loop") and `:2317` ("no retry — the difference between a construction and a
repair").

**CAVEAT — three comments still describe the deleted mechanism as if it were live:**

    arena.nim:2517  "...a sightline-repair plug can land on its slot..."
    arena.nim:2554  "pairs lost to sightline-repair walls are topped back up"
    arena.nim:2556  "...a late `instead` swap would dodge the repair pass"

There is no repair pass. This is not cosmetic in this repo specifically: a stale comment describing
a removed mechanism has already nearly caused a defective feature to be RE-ADDED here, and these
three are exactly that shape — they tell a future reader to reason about a pass that cannot run.
Left unedited only because `arena.nim` is Lane-A serial and the archetype session owns it right
now. Fix them with whatever next touches that block.

Related, and NOT a defect: `pitInstead` / `pitGap` (`arena.nim:1809-1810`) are live and read at
`:2134`, `:2238-2239`, but they are lattice vocabulary surviving into a generator that has no
lattice — the candidates now come from the FILL. The names are misleading rather than dead. Task
78d0db3c is in that code and is the natural place to rename them.
