# B0-c6a preregistration

Repeat the B0 four-budget matrix without algorithm changes on owned c6a.4xlarge i-0b37d010a49d1a53d.
Source20234cc7, Nim2.2.6 via nimby, CPU5 pinned, same flags, three fresh processes per budget,
six scenarios per process,120 ticks each; one informational unpinned run per budget.
Only benchmark work runs on this host; no concurrent measurements. Pin logical CPU5, record SMT
sibling and CPU topology. Original bodyNavBreakdown-on harness for matched inherited comparison.
Use3.6/4.5 selection and4/5 gate, retain every failed row. No claim of complete fleet worst-case
from one AMD host. Production Docker uses Nim2.2.4 and static runtime; that separate compiler/build
shape check remains required before final production qualification.
