# M1: immutable danger geometry is actually shared

All13focused tests, bothserver compile shapes, and peer ownership review pass. Generated C now increments a DangerGeometry reference instead of duplicating kernel/perimeter sequences for every seat. Parent and candidate snippets are retained.

Full3072case quality passes, zero missing/illegal, unchanged37637596pops and route hash `5a1340213fe3046dc119d6f8d5d59d59cbfd379f885b95968f105d3edcbca500`. All six pop arrays match in each of three1300pxm5a pairs. Parent worstp95/max13.835260/15.513166ms; candidate13.792467/15.353760ms. No substantial body-time gain is claimed.

The original memory ledger passes on65rows, but it counts sequence length rather than allocated capacity. CAPACITY_AUDIT.md identifies retained slack in bridgeNodes and shared perimeter; those passes are not final memory proof. M1 fixes ownership without solving the giant-map shared-memory excess. A capacity-based follow-up is required.
