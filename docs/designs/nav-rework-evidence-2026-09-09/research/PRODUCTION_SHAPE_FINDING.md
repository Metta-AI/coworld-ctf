# Production-shape coverage gap

Observed in research source at d5967c82 (2026-09-09):

- Frozen quality corpus uses `data/br_s2_map_pool.json` (64 maps) and `NavCorpusGunRangePx = 331`. Tick and activation harnesses also hard-code331; tick uses pool index15.
- Current `coworld_manifest_paintbot.json` variant `battle-royale-s2` explicitly sets `mapPath: brpool16` and `gunRange: 1300`. `brpool16` resolves `data/br_map_pool.json` (11 maps, larger geometry).
- `sim_config.nim` preserves an explicit gunRange override; `server.nim:resetShellForSim` passes config.gunRange into resetShellEpisode. The default GunRange1050 is therefore not the configured variant value.

This is source evidence, not a refreshed hosted configuration readback. Existing331px baseline results remain valid for their stated corpus/harness; they do not establish performance or memory acceptance for the current manifest variant. Neither a10x slowdown nor any other range-scaling factor has been measured.

Next diagnostics: first isolate331 versus1300 on the same existing map, source, budget and machine; then cover the11 configured pool maps with legal deterministic endpoints and exact provenance. Keep the3072-case quality corpus frozen. Add production-shape coverage rather than replacing that gate or quietly relabeling its maps. The existing16MiB pool and256MiB total caps remain requirements; report any new failures.
