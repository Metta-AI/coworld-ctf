# Native baseline platform probes

Nim 2.2.4 / GCC 12.2.0 / Debian bookworm libm, original planner at 256.
The 2,763,201-input integer-grid probe found 17,374 hypot values differing
from correctly rounded sqrt of the exact integer square sum. The same probe
on Apple libm found zero differences. Raw hex examples are retained. This
establishes a platform-dependent numeric input, not by itself which planner
state first diverges or whether every heap decision agrees.

The split workload matched Mac exactly: map raster, danger bits, all 1,119
per-tick counter digests, sampled route-float digest, path digest and 29,546
points. The full internal-state digest still differs as previously recorded.
The sampled probe cannot establish exact heap ordering; retain that limitation.
The native full-state comparison of original versus H1+H2+H3 remains exact.
