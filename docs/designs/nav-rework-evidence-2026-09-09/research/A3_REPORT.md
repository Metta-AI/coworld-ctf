# A3: reject the inline pragma

Parent f9dff753; m8i CPU5, Nim2.2.6, three interleaved native activation pairs. The only candidate change marked the existing legalNavMove predicate inline. Map48 index times (parent/candidate ms) were275.147/275.572,276.449/276.717,276.221/274.078. Colossal times were4533.699/4544.779,4558.657/4597.752,4543.081/4531.401. There is no repeatable improvement; the pragma is removed.

Candidate full3072-case quality is exact, including37,637,596pops and hash5a1340213fe3046dc119d6f8d5d59d59cbfd379f885b95968f105d3edcbca500. The full activation sweep still fails map48 at2.0039340807x against2x. A passing targeted repeat does not override that failure. Raw configured-map diagnostic, memory ledgers, source and executable hashes, exit codes and completion marker remain in A3-m8i/; run_a3.sh is the recipe.

Documentation audit: no production behavior or documentation contract changes survive this experiment. This report records the negative result. No viewer rebuild is required for the restored source, which matches the existing committed A2 viewer stamp. The focused candidate test passed before remote measurement; no broader candidate checks were justified after rejection.
