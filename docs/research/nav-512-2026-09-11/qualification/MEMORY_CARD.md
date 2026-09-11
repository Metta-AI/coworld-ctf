# Memory comparison

Registered before measurement. Separate original/current-candidate processes,
32-seat activation with gun range 1050, first scale-2.9 map, then the committed
4992x4992 colossal replay geometry. One activation per variant and map.
Use production native flags and the same image. No game timing runs overlap.

memory_activation.nim records Linux VmRSS and VmHWM before/after map and body
navigation activation, constructor capacities, object sizes, validator logical
bytes and dominant array payload arithmetic. It retains the same map/config
objects in both processes. RSS is not a peak-gameplay measurement and zeroed
pages can be demand-allocated. Arithmetic excludes sequence/allocation headers
and shared geometry arrays; these are unchanged by the candidate as well.

H1-H3 introduce no allocation, type, capacity or lifetime change. Require equal
reported capacities/object sizes/array payloads. Report absolute RSS and its
delta; investigate a candidate increase over max(5%,16MiB) rather than silently
explaining it as noise. This is an investigation threshold, not permission to
change memory budgets. No cap increase has been used.
