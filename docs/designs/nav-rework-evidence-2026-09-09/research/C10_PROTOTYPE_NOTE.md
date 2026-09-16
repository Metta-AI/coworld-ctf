# C10 untimed correctness prototype

Root prepared tools-only C10/c10_replay.nim and check_c10_replay.nim in nav-deferred-cache/tools. No src file changed and no native timing started. The helper uses existing SSE2/NEON bindings, ctz-to-nibble grouping, full-lane add, mixed-lane bitwise result blend, and scalar boundary fallback. The blend preserves inactive float bits including negative zero. Five existing C6 crafted geometries now initialize alternating negative/positive zero raster cells before comparing every cell to scalar reference. Root owns prototype; peer remains documents-only.

Please include a brief correctness/design review of these files with the C10 plan decision. Root will not run timed implementation until that review. Border-origin cases and all16nibble masks still need an explicit addition before any native timing. No production architecture dispatch or memory-accounting change has been made.
