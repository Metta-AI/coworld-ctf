# Real-server budget screen

Registered before native timings, 2026-09-11. Base: 83e60c243ed20aa7c756f372306768066054644e.
This replaces the synthetic protocol under superseded/. That harness was only
smoke-tested on arm64. Its simplified physical state and its use of archived
4/5ms gates make it unsuitable for adoption decisions. No native timing result
from it is used.

This is a bounded exploratory screen, not final runtime qualification. Build
production Nim 2.2.4 runtime-linked release/useMalloc/threads/speed/stackTrace
server variants with only ColdPlanBudgetPerTick changed: 256, 512, 1024.
Use the existing shell demo's real server, presence clients and edge_ride WASM
play, installed for every configured seat. Real physics, observation, weapon
state and sim.step run normally. Use 16 and 32 seats, seed 907, the practice config’s pinned br-gen-4242 mapSpec (3211×1713),
gunRange 497,
practice config overlaid by shell_demo_config (the embedded mapSpec takes
precedence over its mapPath="arena" label), maxGames 1, maxTicks 1200,
playSeatBindTicks 120, speed 1, fastMode true, barrageMaxPerSec 0 (so the tick limit applies). Trim players, slots and tokens to the seat count and set minPlayers accordingly.
Retain exact input JSON and verify observed seat counts.
Fast mode removes intentional waiting when clients are ready; it does not
increase the number of simulation steps per frame. These are finite real games,
with normal death and early endings; report actual tick/seat coverage.

Owned native m5a.4xlarge: pin all server threads to CPU 5; presence clients to CPUs 6–7.
One server at a time. Two repetitions, budget order 256, 512, 1024 then 1024, 512, 256;
16 then 32 seats within each budget. No discarded warmups or replacement runs
for slow results. Setup failures may be repaired before measuring; retain them.

Measurement-only source patch records ShellEpisode.step wall time, and whole
server-frame work before the frame limiter. The latter includes shell, physics,
replay and player output preparation, as well as benchmark logging overhead;
it excludes intentional limiter waiting, final shutdown and the last exiting
frame. Record all existing plan-budget, navigation, combat, install, fault and
stage timing logs. Compare p50/p95/max and counts exceeding 41.667 ms (24 Hz),
including cold ticks. This deadline is descriptive, not an adoption threshold.
Report failed/completed/suspended planning events and no-path/pending seat-ticks.
Completed/failed events describe only previously suspended plans; plans that
finish on their first visit emit no such event. Do not use these as total plan counts.
Do not equate completed plans with route quality, or reduced pending queues
with success. Deaths and divergent trajectories can change workload across
budgets. Existing CPU containment gates remain unchanged and separate.

This screen can reveal a promising budget or a regression; it cannot certify
all maps, long gun ranges, adversarial replans or representative league plays.
No runtime constant or memory cap will be changed in main from this screen
alone. Follow-up qualification needs those workloads, actual path/arrival
quality and a predeclared acceptable whole-game headroom margin.

Native ownership/access: sandbox i-08b7fb62b50e0740a. Broker vends another account
and no sandbox scope, so use authorized sandbox AWS profile. SSH checks pinned
host key and needs no Tailscale. Stop the host after collecting evidence.

All server threads share CPU 5, including HTTP workers; production may have
more CPU capacity. Its SMT sibling is not reserved. This is a conservative
single-core screen, not a reproduction of production scheduling. Frame and
shell rows differ at start/end phase boundaries; analyze their join by tick.
