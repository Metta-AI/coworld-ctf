# Correction: geometry ownership before M1

Generated Nim C and independent peer review prove that pre-M1 constructors duplicated the immutable kernel and perimeter for each seat. The ledger counted these sequences once. It understated total retained memory; historical raw JSON is unchanged. See M1-parent-generated-c.txt and MEMORY_SHARING_REVIEW.md.

For32seats, omitted logical payload is31 times shared_danger_geometry:1,012,956bytes at331px and13,717,500bytes at1300px, plus omitted per-copy allocation overhead. With the existing16-byte sequence allowance, add992bytes for62sequence allocations. These are logical ownership corrections, not independently measured allocator RSS. Previous claims of an exact total ledger were wrong.

The frozen331px colossal total remains below256MiB after this correction. Configured11-map shared memory still fails16MiB. Neither fact completes a full allocator-capacity audit; seq capacity can exceed length when grown with add. M1 fixes actual sharing and records the ref owner. Follow-up must check retained capacity rather than assume len always equals allocated capacity.
