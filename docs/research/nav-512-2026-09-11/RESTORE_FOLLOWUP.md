# Restore audit follow-up

Claude independently verified checkpoint c651dec9 and the archived source,
inputs and results; see RESTORE_REVIEW.md. The following gaps are closed:

- Exact benchmark guest bytes were copied from the native candidate directory,
  checked against current-main/assets.json and archived in guest-modules.tar.gz.
  The local edge_ride build differed from the pin and was not substituted.
- RAW_ARTIFACTS.md explicitly locates the restored production.patch referenced
  by the frozen current-main card; no frozen card/hash was edited.
- H1/raw-games.sha256 now supplies the same archive hash as H1/RESULT.md.
- checks/viewer-at-c651.txt records the Node viewer QA pass at c651dec9.
- README.md now records completed correctness and training confirmation,
  with held-out timing still in progress.

These are evidence repairs only. No benchmark inputs or production source changed.
