# I0: extra navigation clock overhead

Completed nine fresh processes: three each of two independently compiled breakdown-on builds
(A1,A2), and one breakdown-off build (B). Three interleaved A1/B/A2 rounds, B1024, Xeon CPU5.
All six scenario pop-count arrays match exactly in every process. Both compile shapes for
this harness toggle build successfully; this is not the server runtime-linked/stub check.

| Build | worst p95 range across repeats ms | maximum observed ms |
|---|---:|---:|
| on A1 |2.447862–2.502366|4.110737|
| on A2 |2.495826–2.597007|4.190597|
| off B |2.466532–2.607315|4.433177|

No material timing reduction from removing the extra clocks is established by these runs.
Off is not consistently faster. The large spread in maxima demonstrates shared-host noise;
all observed B1024 runs still meet3.6/4.5 headroom. Do not subtract an estimated clock cost
from B0 or use the fastest run as acceptance. More process repeats and matched controls are
needed before a small optimization claim. Normal production body clocks remain in both builds.

Raw source patch, build logs, per-process JSON, stderr and exits are in I0/. The off variant
marks body_nav_breakdown=false and leaves unavailable breakdown counters as zero; those
zeros do not mean zero work. Actual scheduler pops are still measured and match.
