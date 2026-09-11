# Precision note on the diagnostic tradeoff

The eleven named helpers omit their own Nim diagnostic frames; bounds checks
and the nearest framed caller remain. Some selected helpers call other
selected helpers (canStand -> clearanceAt -> inBounds), so the peer review's
statement that counted depth can fall by "at most one" is too narrow. A chain
can omit several selected frames. None is recursive, and the scope remains the
explicit eleven procedures tested in H3. The deliberate setPosition defect
covers its one-helper path; it does not claim every call chain has length one.
