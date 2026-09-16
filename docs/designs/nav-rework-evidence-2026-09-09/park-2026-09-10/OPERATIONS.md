# Park operations

Claude peer nav-research-peer delivered PARK HANDOFF READY and is idle. Both
existing C10 runs completed, all results were downloaded and evaluated, source
restoration was verified, and no benchmark process remained before stopping.

m8i owned-m8i and m5a owned-m5a have received stop requests.
c6a owned-c6a and c8i owned-c8i were already stopped.
Final EC2 readback is recorded in host-state-final.json. Stopped instances
retain disks for later restart; these old public IPs must not be assumed valid.

The broker aws.readonly credentials target account broker-account and cannot
see these instances. Sandbox account sandbox-account was verified through EC2
instance identity; the sandbox SSO profile is used because the broker does
not vend that account. Exact instance IDs and James ownership tags were
verified before stopping. Protected m6i protected-m6i is untouched.

Root verified the local C10 candidate against its frozen SHA-256 snapshot and
restored only its owned src/shell/body_nav.nim edit in nav-deferred-cache.
Other side-worktree changes and untracked tools remain preserved in place and
in the archive; no worktree is deleted. The original coworld-ctf checkout's
in-progress merge and divergent local main are untouched. Submission uses a
separate clone to avoid changing that shared main branch.
