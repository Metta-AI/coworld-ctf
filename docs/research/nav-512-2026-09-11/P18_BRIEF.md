# P18: verify the local research checkpoint is restorable

Source/evidence checkpoint c651dec9 is local only. Read RAW_ARTIFACTS.md and
README.md. In your own scratch directory, verify archive SHA256s and restore
raw patches, validation logs and first-divergence dumps. Check:
- current-main/production.patch applied to58e6c947 reproduces the four source
  files in c651dec9 (body_map/cache/planner/nav); viewer stamp is recorded.
- frozen qualification config hashes matchmanifest, cards matchtheir hashes,
  source/binary/guest provenance paths are discoverable after documentedextract.
- H3 rawarchive parent binaryhash readback and nativechecks/memory records are
  present or explicitlylinked. Older failed/superseded results remain negative.
- no claim that512 is globallyqualified yet: currentbase12correctness and6training
  pass, but36heldoutperformance juststarted (rootnativeonly).

Use read-onlyGit/archive extraction in scratch, no root/production edits, no
nativehostuse, no builds/benchmarks/commits. Write RESTORE_REVIEW.md with concrete
missing links/bytes or misleadingclaims; end PHASE 18 READY and wait. Do not
repeat a full semantic audit of all historical prose. Root can fix small durable
record gaps whiletimingsrun. Updated fleet runner already separatesmismatch.json
fromfailure.json and pinsimage/libc; fleet gatesunchanged.
