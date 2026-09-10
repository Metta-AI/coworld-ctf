# G1: configured variant screen on m8i

One complete diagnostic process, B1024, CPU5, checked-in manifest gunRange1300 and brpool16. This is not repeat qualification or a hosted configuration readback. Every map fails the unchanged16MiB shared-memory cap.

| Map | Whole-body p95 ms | Whole-body max ms | Shared retained bytes | Total retained bytes |
|---|---:|---:|---:|---:|
| configured:0:br-gen-505 | 5.127141 | 5.199400 | 30504907 | 61526603 |
| configured:1:br-gen-5001 | 13.642536 | 14.049040 | 30551351 | 61573047 |
| configured:2:br-gen-5040 | 9.219113 | 9.350345 | 30489711 | 61511407 |
| configured:3:br-gen-5120 | 15.015300 | 15.193815 | 30600147 | 61621843 |
| configured:4:br-gen-5161 | 10.675588 | 10.912214 | 30755007 | 61776703 |
| configured:5:br-gen-5204 | 8.432659 | 8.564591 | 30509379 | 61531075 |
| configured:6:br-gen-5263 | 7.141962 | 7.215787 | 30608667 | 61630363 |
| configured:7:br-gen-5312 | 13.452145 | 13.761171 | 30697243 | 61718939 |
| configured:8:br-gen-5359 | 9.371280 | 9.457869 | 30645759 | 61667455 |
| configured:9:br-gen-5400 | 11.283516 | 11.377762 | 30444011 | 61465707 |
| configured:10:br-gen-5448 | 9.464643 | 9.669529 | 30567887 | 61589583 |

Input hashes and deterministic start/near/far coordinates are embedded in G1-m8i/configured.json. The3072-case frozen quality reference remains unchanged. No pool cap is relaxed or reclassified as a total-memory gate.

Accounting correction: pre-M1 danger geometry was copied per seat but counted once. Total-memory numbers understated retained payload; see [GEOMETRY_ACCOUNTING_CORRECTION.md](GEOMETRY_ACCOUNTING_CORRECTION.md). Raw results are preserved.
