## Metallic-paint shimmer: WHICH ONE POLICY in the whole league renders as metal.
##
## There is at most ONE shimmering policy per lobby — the league's #1-ranked
## competitor — and usually none at all. The mark is a recognition device, not a
## legend: if you are in a match with the #1, you really know it, and that only
## works because you almost never see it. A second sheen on the board would make
## it decoration. So the payload carries a single root-level `shimmer` string
## (docs/COLOR_CONTRACT.md §5), not one per team, and this module keeps one
## string, not one per team.
##
## It stays deliberately orthogonal to `slug`, the preferred team color: color
## says TEAM, shimmer says THE #1. A team is dressed uniformly in one color
## (paint stains are the scoreboard, so a half-recolored team would corrupt the
## score read) while the single marked competitor still stands out inside it.
##
## FOUR PROPERTIES THIS MODULE MUST KEEP:
##
## - **Display-only.** Nothing here is read by the sim, enters `gameHash`, or
##   changes an existing sprite's LABEL. `Player.address` — the string this
##   resolves against — is already outside the hash (sim_state.nim hashes only
##   positional/combat fields), and the renderer's use of it adds one extra
##   overlay OBJECT, never a change to the cog art a policy scans. A replay
##   played with shimmer on and one played with it off are the same game.
## - **Boot-time, whole-episode.** The value is process state set once before
##   the first render and never re-read per frame, mirroring the payload's own
##   "immutable per page load" rule (§5). Nothing invalidates a viewer's sprite
##   cache mid-episode.
## - **Team-INDEPENDENT.** The gate is a policy identity and nothing else. The
##   #1 usually is not in this episode at all (nobody shimmers, which is the
##   normal case and is not an error); when it is, and the platform seated it on
##   two different teams, every one of its agents shimmers on both.
## - **Identity is the STRIPPED policy name.** `policyName` collapses the hosted
##   runtime's per-seat `" (N)"` / `"_(N)"` suffix, so all seats of one policy
##   share one identity and the platform can send a single string. The payload
##   spec promises the platform sends the stripped form; this strips whatever it
##   is given and compares against the stripped roster name, so both halves agree
##   even if one side forgets. NOTE `policyName` is not injective across
##   genuinely different policies (roster.nim enforces uniqueness on the FULL
##   address only) — a collision would shimmer both, which is a cosmetic wrong,
##   not a crash.

import
  std/[os, strutils],
  broadcast, team_colors

export broadcast.policyName

const ShimmerEnvVar* = "CTF_SHIMMER"
  ## DEV STUB ONLY. See `parseShimmerSpec`.

var
  shimmerPolicyName: string   ## the one policy that renders as metal, or "".
  shimmerSeamCalled = false   ## true once a real caller set the policy, which
                              ## permanently disables the env stub below.
  shimmerStubApplied = false

proc setShimmerPolicy*(policy: string) =
  ## THE INTEGRATION SEAM — the one call that turns shimmer on, and the only
  ## entry point the `?colors=` payload parser needs. Call it once at boot,
  ## before the first render, with the league/lobby #1's policy identity; pass
  ## `""` (or never call it) and nothing shimmers, which is what most episodes
  ## do. Calling it at all disables the dev env stub, so a real payload always
  ## wins over a stray `CTF_SHIMMER` in the environment.
  ##
  ## A single string rather than a per-team mapping BY DESIGN: the mark means
  ## "this is the #1 competitor in the league", a fact about one policy that has
  ## nothing to do with which team it was seated on, and an API with a team in
  ## it would let a payload light up four policies at once and make the rarest
  ## thing on the board look routine.
  shimmerPolicyName = policyName(policy.strip())
  shimmerSeamCalled = true

proc installPayloadShimmer*() =
  ## Bridges the `?colors=` payload into the seam above: reads the root-level
  ## `shimmer` field that `setTeamDisplayColors` parsed and, when the payload
  ## named a policy, installs it. A payload with colors but no shimmer
  ## deliberately leaves the seam untouched, so the CTF_SHIMMER dev stub still
  ## works in local runs; a payload WITH shimmer wins outright. Call it right
  ## after `setTeamDisplayColors` on both boot paths.
  let policy = payloadShimmerPolicy()
  if policy.len > 0:
    setShimmerPolicy(policy)

proc parseShimmerSpec*(spec: string): string =
  ## DEV STUB parser for `CTF_SHIMMER`: a plain policy name, `CTF_SHIMMER=picasso`.
  ##
  ## Whitespace is trimmed and the hosted seat suffix stripped, so a name copied
  ## straight out of a roster line works. There is nothing to fail at: an empty
  ## or blank value means nobody shimmers, exactly like an absent one. (It used
  ## to take `red:picasso,blue:jordan` pairs; a colon here is now just part of
  ## the name, which hosted names like `ctf-focusfire:v62` genuinely contain.)
  policyName(spec.strip())

proc ensureShimmerStub() =
  ## Applies `CTF_SHIMMER` the first time anything asks about shimmer, unless a
  ## real caller already set the policy.
  ##
  ## Lazy rather than wired into an entrypoint on purpose: this is scaffolding
  ## for looking at the effect, and every surface that renders a board — the
  ## live server, the replay viewer, the frame-dump tools, the tests — would
  ## otherwise each need its own boot hook, and each would be a line to delete
  ## when the payload lands. `setShimmerPolicy` is the seam that ships; this
  ## proc is the part that goes away.
  if shimmerStubApplied or shimmerSeamCalled:
    return
  shimmerStubApplied = true
  shimmerPolicyName = parseShimmerSpec(getEnv(ShimmerEnvVar))

proc shimmerPolicy*(): string =
  ## The stripped policy name whose agents render as metal, or `""` when nobody
  ## shimmers. Also the inverse of `setShimmerPolicy`, so a caller (a test, a
  ## diagnostic) can save and restore the registry rather than assume it was
  ## empty.
  ensureShimmerStub()
  shimmerPolicyName

proc anyShimmer*(): bool =
  ## True when some policy is flagged — the cheap early-out that keeps a stock
  ## episode from paying anything for this feature. Note it says nothing about
  ## whether that policy is IN this episode; the #1 usually is not, and then no
  ## seat matches and nothing draws.
  shimmerPolicy().len > 0

proc playerShimmers*(address: string): bool =
  ## Whether ONE seat renders as metal: this seat's stripped connection name is
  ## the flagged policy. The per-AGENT, team-independent test — two seats of the
  ## same team disagree whenever only one of them belongs to the #1, and two
  ## seats on DIFFERENT teams both shimmer when both do.
  let want = shimmerPolicy()
  want.len > 0 and policyName(address) == want
