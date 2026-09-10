# Independent archive review

A fresh Claude Code process reviewed the archive read-only, with no permission
denials or API errors. It verified byte-identical source patches against the
recorded Git diffs, all eight expected blob/mode manifests, seven dirty patch
preimages, the complete 147-commit history, and no runtime activation path.
It found no credentials or private key material.

## Findings and disposition

- Infrastructure identifiers: removed redundant IDs/account numbers from the
  newly authored operations records. Deliberately retain non-secret instance
  identifiers and historical SSH targets in frozen historical evidence and
  source patches, preserving their exact hashes and provenance under James's
  explicit authorization to publish the complete research archive. These are
  identifiers, not access credentials; the review's high-severity classification
  is declined. The private restart note also retains the owned-host mapping.
- Ignored evidence: already addressed by forced staging. Git inventory verifies
  45 DONE, one EDGE_DONE, 19 SHA256SUMS, one SHA256SUMS-v1 and six .out files.
  The review inspected the directory while initial staging was still underway.
- Restore verifier discoverability: README includes the runnable command and
  describes expected blob/mode manifests and checksum verification.
- Docker context: one narrow .dockerignore entry excludes the archive.
- Archive size: 53 large JSON measurements compressed losslessly from
  295,273,622 to 17,277,669 bytes. Original byte counts and SHA-256 digests are
  recorded; README supplies expansion instructions for historical paths.
- Ambiguous side base.txt: renamed to historical-head.txt, explicitly marked
  provenance-only; restoration uses the top-level pinned main commit.
- Restore snippet: uses a durable worktree path and chained commands; it
  explicitly forbids applying to the main branch or a shared checkout.
- Verification edges: the full archive checksum manifest includes pending
  patches and untracked files. Dirty-patch validation is described accurately
  as an applicability check; base restoration compares every blob and mode.
- Git object writes: verifier docstring now notes loose blobs may be created.

The first review ended NOT JUST NITS before these dispositions. A bounded text-only follow-up emitted unsupported tool-call markup rather
than findings and is not counted as a review. The corrected retry and its
verdict are recorded in the PR description before merge.
This review is validation evidence, not a GitHub approval of authored work.
