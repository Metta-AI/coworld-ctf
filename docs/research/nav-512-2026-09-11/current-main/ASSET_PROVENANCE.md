# Current-main asset provenance check

The old-base qualification/assets.json intentionally records the earlier
campaign. Current-main runners use the separately created mounted results
folder nav512-main58-qualification, whose assets.json is copied here alongside
this note. Root created that directory with exist_ok=False after building
nav512-main58-results from git archive origin/main58e6c947 plus production.patch.

All three server hashes in this assets.json were checked against the corresponding
server-256/512.sha256 files in builds.tar.gz. That archive includes compiler
versions, build logs, source-256/512.sha256 and the exact original server source
before timing instrumentation. Binaries are original256 and candidate256/512
from this base, not the H3 screen binaries. Guest and presence hashes are pinned
as shared inputs. The runner verifies these binary/module bytes before each phase.

Peer review finding1 is closed by this explicit readback and archive provenance.
A source-file check alone would not prove a binary came from that source; the
recorded build, source hashes and binary readback together supply the provenance.
If any run fails, keep its raw log and metrics; label the campaign incomplete.
Same-budget mismatch leaves both per-run metrics and a traceback in correctness.log;
write an explicit mismatch summary as part of failure triage if one occurs.
