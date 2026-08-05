## Metallic-paint shimmer: WHICH POLICY on each team renders as metal.
##
## Preferred team colors dress a whole TEAM in one color (docs/COLOR_CONTRACT.md
## §5 `slug`). That deliberately erases the one thing a spectator most wants to
## see on a mixed team — whose agents are whose — so the payload carries a
## second, orthogonal channel: `shimmer`, the policy whose own cogs wear an
## animated clearcoat sheen. Color says TEAM; shimmer says WHOSE. Keeping them
## on separate axes is the point: a team stays uniformly one color (paint stains
## are the scoreboard, so a half-recolored team would corrupt the score read)
## while a single policy's agents still stand out inside it.
##
## THREE PROPERTIES THIS MODULE MUST KEEP:
##
## - **Display-only.** Nothing here is read by the sim, enters `gameHash`, or
##   changes an existing sprite's LABEL. `Player.address` — the string this
##   resolves against — is already outside the hash (sim_state.nim hashes only
##   positional/combat fields), and the renderer's use of it adds one extra
##   overlay OBJECT, never a change to the cog art a policy scans. A replay
##   played with shimmer on and one played with it off are the same game.
## - **Boot-time, whole-episode.** The mapping is process state set once before
##   the first render and never re-read per frame, mirroring the payload's own
##   "immutable per page load" rule (§5). Nothing invalidates a viewer's sprite
##   cache mid-episode.
## - **Identity is the STRIPPED policy name.** `policyName` collapses the hosted
##   runtime's per-seat `" (N)"` / `"_(N)"` suffix, so all seats of one policy
##   share one identity and the platform can send a single string per team. The
##   payload spec promises the platform sends the stripped form; this compares
##   against the stripped roster name, so both halves agree even if one side
##   forgets. NOTE `policyName` is not injective across genuinely different
##   policies (roster.nim enforces uniqueness on the FULL address only) — a
##   collision would shimmer both, which is a cosmetic wrong, not a crash.

import
  std/[os, strutils, tables],
  sim_types, broadcast

export broadcast.policyName

const ShimmerEnvVar* = "CTF_SHIMMER"
  ## DEV STUB ONLY. See `parseShimmerSpec`.

var
  shimmerPolicies: array[Team, string]
  shimmerSeamCalled = false   ## true once a real caller set the mapping, which
                              ## permanently disables the env stub below.
  shimmerStubApplied = false

proc setTeamShimmerPolicies*(mapping: Table[Team, string]) =
  ## THE INTEGRATION SEAM — the one call that turns shimmer on, and the only
  ## entry point the `?colors=` payload parser needs. Call it once at boot,
  ## before the first render, with one entry per team that has a `shimmer`
  ## field; teams absent from `mapping` (and every team, if it is empty) render
  ## stock. Calling it at all disables the dev env stub, so a real payload
  ## always wins over a stray `CTF_SHIMMER` in the environment.
  ##
  ## Deliberately whole-mapping rather than per-team: a payload is applied as a
  ## unit, and a set-one-team API invites the half-applied state (team A from
  ## this episode, team B left over from the last) that a per-page-load
  ## contract exists to prevent.
  for team in Team:
    shimmerPolicies[team] = mapping.getOrDefault(team, "")
  shimmerSeamCalled = true

proc teamShimmerPolicies*(): Table[Team, string] =
  ## The current mapping, teams with no shimmer omitted. The inverse of
  ## `setTeamShimmerPolicies`; exists so a caller (a test, a diagnostic) can
  ## save and restore the registry rather than assume it was empty.
  for team in Team:
    if shimmerPolicies[team].len > 0:
      result[team] = shimmerPolicies[team]

proc parseShimmerSpec*(spec: string): Table[Team, string] =
  ## DEV STUB parser for `CTF_SHIMMER`: `red:baseline,blue:picasso` — comma- or
  ## semicolon-separated `<wire team word>:<policy name>` pairs. Team words are
  ## the WIRE words (`red|blue|green|yellow`, `teamText`), never display slugs:
  ## the wire word is what the roster and the payload's `teams` keys use, and a
  ## slug here would quietly diverge from the real seam.
  ##
  ## Splits at the LAST colon so a policy name may contain one (hosted names
  ## like `ctf-focusfire:v62` do). Unparseable entries are skipped rather than
  ## raised on — this is a debug knob, and a typo in it must never take a server
  ## down.
  for entry in spec.split({',', ';'}):
    let text = entry.strip()
    if text.len == 0:
      continue
    let cut = text.rfind(':')
    if cut <= 0:
      continue
    let
      word = text[0 ..< cut].strip().toLowerAscii()
      policy = text[cut + 1 .. ^1].strip()
    if policy.len == 0:
      continue
    for team in Team:
      if teamText(team) == word:
        result[team] = policyName(policy)

proc ensureShimmerStub() =
  ## Applies `CTF_SHIMMER` the first time anything asks about shimmer, unless a
  ## real caller already set the mapping.
  ##
  ## Lazy rather than wired into an entrypoint on purpose: this is scaffolding
  ## for looking at the effect, and every surface that renders a board — the
  ## live server, the replay viewer, the frame-dump tools, the tests — would
  ## otherwise each need its own boot hook, and each would be a line to delete
  ## when the payload lands. `setTeamShimmerPolicies` is the seam that ships;
  ## this proc is the part that goes away.
  if shimmerStubApplied or shimmerSeamCalled:
    return
  shimmerStubApplied = true
  let spec = getEnv(ShimmerEnvVar)
  if spec.len > 0:
    for team in Team:
      shimmerPolicies[team] = ""
    for team, policy in parseShimmerSpec(spec):
      shimmerPolicies[team] = policy

proc teamShimmerPolicy*(team: Team): string =
  ## The stripped policy name whose agents shimmer on `team`, or `""`.
  ensureShimmerStub()
  shimmerPolicies[team]

proc anyShimmer*(): bool =
  ## True when at least one team has a shimmer policy — the cheap early-out
  ## that keeps a stock episode from paying anything for this feature.
  ensureShimmerStub()
  for team in Team:
    if shimmerPolicies[team].len > 0:
      return true
  false

proc playerShimmers*(team: Team, address: string): bool =
  ## Whether ONE seat renders as metal: its team has a shimmer policy and this
  ## seat's stripped connection name is that policy. The per-AGENT test — two
  ## seats of the same team disagree whenever the team is mixed, which is the
  ## whole reason the channel exists.
  let want = teamShimmerPolicy(team)
  want.len > 0 and policyName(address) == want
