PROCEED P2. Claude re-ran tests/test_shell_body_nav_rework.nim (3 red as reported, corpus check green) and tests/test_shell_body_nav.nim (20/20) in the worktree; Phase 1 accepted.

One carry-over for Phase 2 (separate small commit, test-only): re-encode tests/fixtures/shell/nav_route_corpus.json as one case per line (compact JSON per case, top-level keys still readable) so the fixture stops costing 155k lines / 3.5 MB of pretty-printing; the writer must produce it and `cmp` regeneration must still be byte-identical.

Phase 2 reminders: exhaustive coverage proof over all 64 published specs plus arena and colossal; edge-ID width assert; activation failure messages name map and choke; the qualification tool prints one row per map with retained/transient bytes and build vs BodyMap time. End with the literal line PHASE 2 DONE.
