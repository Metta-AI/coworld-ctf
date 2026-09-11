# Restore raw research artifacts

From this directory, restore exact source patches and native perf reports:

```sh
tar -xzf source-and-profile-text.tar.gz
tar -xzf validation-logs.tar.gz
(cd CROSS_ARCH/first_divergence && tar -xzf raw-dumps.tar.gz)
```

The archives preserve exact bytes, including unified-diff context spaces and
perf's aligned trailing columns. Roundtrip content equality was verified before
packing them. Companion SHA256 files pin each archive. H1/H2/H3 raw games and
current-main build evidence remain in their own named archives; extract those
into a scratch directory so their original directory layout is preserved.

Source patches describe intermediate candidate states. The current production
diff is also directly visible in Git; its source checkpoint retains default256.
Raw evidence is historical, including failed and superseded experiments, and
must not be treated as a current qualification verdict.
