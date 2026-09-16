# G0: configured range changes the measured floor

Three interleaved fresh331/1300process pairs on m5a CPU5, same S1 binary and B1024; only harness gun range differs. Frozen map15 and original six rows remain unchanged.

| Range px | Worst whole-body p95 ms | Worst whole-body max ms | Worst danger p95 ms | Worst packed refresh p95 ms | Worst weapon p95 ms |
|---|---:|---:|---:|---:|---:|
|331|5.691996|5.807979|3.392069|1.071591|0.507274|
|1300|13.982918|15.593524|8.078249|1.109622|11.960938|

Each column takes its own worst row/repeat; these maxima can come from different rows. Do not add them or subtract their percentiles to infer another stage. All raw rows, samples, exit codes and source/compiler provenance are in G0-m5a. Every timing run fails the unchanged whole-body gate.

The increase affects danger and weapon work; a search-only optimization cannot address this measured floor. No10x timing inference is made from geometric ray counts. Different ranges intentionally change danger and route choices, so cross-arm pop equality is not an acceptance requirement. This diagnostic still uses old corpus geometry; G1 tests configured11-map geometry separately.
