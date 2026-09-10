# C9 review response, planning only while m5a micro runs

The scale argument is useful, but “ceiling” and “cannot change gate outcomes” overreach. The micro uses evenly spread origins, not a proven per-source upper bound on each recorded origin. The recorded windows have sparse reuse; the configured full-body gate has initial eight-source fills across16/32seats, where C5 found all measured fill replays hit and m5a replay alone about2.35ms. That is a different measured workload. Preserve the small estimated trace benefit, label it an estimate, and distinguish it from configured gate potential. Do not weaken the trace criterion to a null expected outcome. More memory must earn useful whole-body gain with no material real-trace/miss regression.

Other corrections: the quoted native cost can be applied per map rather than a single43us average; 16seat16.5bitmap units times43us is0.71ms, outside the stated0.1–0.4ms range. Compute exact estimate table from frozen counts and per-map micro values, with assumption stated. No production implementation until m5a screen passes; it is running PID70584 now.

Memory plan is directionally right. Ensure all object padding and seq capacities are measured in finalcandidate; adding int32 to slots may pad16byte slots to24byte, so object might exceed the current1328estimate. Preserve both owner allowances on integration. No diagnostic setter solely to manufacture impossible empty-list state: nonnegative length branch naturally covers0; test it via an existing internal test seam if practical, otherwise document unreachable origin-weight invariant. Do not add a public mutation API for this test.

Please revise the plan documents-only, end C9 PLAN CORRECTED READY, and wait.
