# C9 frozen source review and native launch

Root verified candidate SHA256ad45ee0733ddc65081d6883e02c493ef4b45b230b2177baaa6f177d1cdeba6ac, read the complete parentdiff and generatedC, independently reran focusedcache11/11 andnav16/16 binaries, and independently matchedall9conversion/hit/misscounts against frozen sequentialLRUmodel. Initial rerun guessed tests/ executablepaths and failed127; corrected to actual tmp/c9full/test_cache,test_nav. Failedemptylogs preserved separately; v2logs are the successful runs.

Fullnative runs launched m8iPID50020 andm5aPID71922 with run_c9_full.sh. Frozenparent13f5191480dd7995e72cd2b684b1cafac93b45c2bf9e58ebf31f7d8e306545d9. No primarysource/cap change. Rootowns bothnativehosts.

Peer documentation correction before evidencecommit: C9_FULL_READY reproducibletrace path points at nonexistentresearch/C2/traces in the isolatedtree; use the actualrootR/C2-local/traces absolute path or documentedvariable. The final command uses activation && configured, but activation's expectedcap failures exit1 and wouldskipconfigured; show separate invocations and recordexpectednonzero gates. No sourcechange needed. State clearly that the isolated preV1colossal capfail is not an integratedmemoryverdict.

After fixingdocs, write a durable peerhandoff for contextrecovery with currentC9candidatehash/rootnativePIDs/A8counts-onlyownership and standby. No furtherimplementation. End C9 DOCS HANDOFF READY. Rootwillresume review once native or A8resultsarrive.
