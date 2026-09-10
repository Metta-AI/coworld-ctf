# M3: include the installed hazard context in retained memory

The full 65-map activation run completed on native m8i, CPU 5, Nim 2.2.6. All 64 frozen pool maps remain below 16 MiB shared; maximum 16,150,745 bytes. Colossal retains 266,089,555 bytes against 268,435,456. These figures include allocated sequence capacity, hazard overlay, a refreshed safe cache and estimated allocation-header allowances. They are not a physical RSS upper bound.

The configured 11-map screen still fails the shared cap on every map; maximum 31,521,758 bytes. This is a real scope gap, not waived by the larger total cap. The workload reads the checked-in manifest; live configuration has not been authenticated and verified.

Activation now includes constructing the armed overlay and refreshing the cache before the index releases its following payload, then installing this context and reading the fresh navigation ledger. Thus prior activation totals omitted work and are not interchangeable with M3. Prior raw results are preserved. The armed-context regression test passes locally. Peer review is pending.

Evidence: M3-m8i/{activation,configured}.json, exit files, source.patch, build.log, input-hashes.txt and lscpu.txt. No performance improvement is claimed for this accounting correction; no qualification sentinel is earned.

Subsequent user ruling: MEMORY_CAP_RULING.md authorizes higher non-colossal caps. These raw measurements retain their original16 MiB verdicts; current measured maxima fit the selected32 MiB shared allowance.
