# C7 corrected ownership: m8i mechanism result, not an adoption

All27native m8i trace pairs are complete and exact. Candidate/C2total ratios0.974783–1.017079,median0.995052;23/27p95pairs are slower. Changing-source regime ratios1.026492–1.042391,median1.033823; repeated-source0.671513–0.735323,median0.701086. Full m8i quality passed all 3,072 cases with the frozen pre-H1 hash `5a1340213fe3046dc119d6f8d5d59d59cbfd379f885b95968f105d3edcbca500` and 37,637,596 pops; m5a corrected run also completed; both owned host checkouts restored cleanly. Root separately inspected nativegenerated addVisibleCell and proved no eqcopy/eqdestroy cache ownership in thatfunction (C7-refcount-native-addVisibleCell-C.txt).

The original per-cell reference owner caused most of the observed v1regression under this compiled workload: v1m8ichanging1.81–1.97 andtracetotal1.48–1.67 versus correctedchanging1.026–1.042 andtracetotal0.975–1.017. This comparison retains allraw runs and doesnot attribute the small remainder uniquely to stores or arithmetic. It is a source-level controlledcorrection, not a compilerflag change.

The corrected fullcandidate stillfails the useful recorded-trace/miss criterion on m8i: mixedsmall total movement, consistent p95/missregression, and nearly27MBadditional sharedpayload. No primarysource/cap/budget change. Finish bothhostrawquality/results; C9tools-onlyconversionmicro is the next conditionalscreen.

## m5a timed pairs completed

All27trace pairs and24regime rows are exact. Trace total candidate/C2 ratios range0.721896–1.073950,median0.956725;18/27p95pairs slower. Changing-source ratios1.012729–1.039963,median1.023023; repeated0.603824–0.756056,median0.655375. Preserve the large best-pair movement and negative pairs; no claim of uniform improvement. The isolated quality run passed all3,072cases with the same pre-H1 hash and37,637,596pops. These mixed results do not reverse the no-adoption decision.
