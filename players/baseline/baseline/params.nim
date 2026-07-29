## All tunable gameplay constants for the baseline bot, declared through the
## tunables.nim registry macros: overridable via -d:tune<Name>=<int>,
## compile-time range-guarded, discoverable via dump_tunables.nim.
##
## Defaults are the CHAMPION values — a build with no -d:tune* flags behaves
## identically to the hand-tuned bot. Floats are deci-scaled unless noted
## (gameplay value = define / scale).
##
## NOT declared here (fixed by design, keep in baseline.nim):
##   - sim mirrors that must track the server (PlasmaReach, PlasmaHalfBrads,
##     MedKitRespawn, PickupRespawn, NadeMaxRange/NadeBlast/NadeFullChargeTicks,
##     AimBrads, AimRate, MaxHp, PlayerHalf)
##   - protocol/sprite geometry (WebSocketPath, ButtonC, AimDotRadius,
##     HpPipRadius, TrackCap)
##   - structural values whose change invalidates other assumptions (NavCell,
##     LaneTop map geometry)
##
## Tuning-campaign note (cogamer cogames/ctf/team/meta.md): the accuracy-micro
## and grenade-economy families are CLOSED for tuning — they are still declared
## (discoverability, range guards) but the tuner's params file keeps them
## disabled; do not enable without the meta.md reopen trigger.

import tunables
export tunables

# ---- navigation / pathing ----
tunableI RepathTicks, 10, 4, 30,
  "refresh the nav cost field at least this often (ticks)"
tunableI LookaheadCells, 6, 2, 12,
  "how far ahead on the path we aim the waypoint (nav cells)"
tunableI32 StepCost, 5, 3, 10,
  "orthogonal move cost in the nav field"
tunableI32 DiagCost, 7, 4, 14,
  "diagonal move cost (~sqrt(2) * StepCost)"
tunableI32 ExposedCost, 14, 6, 28,
  "extra cost to enter a threat-exposed cell — under fog the exposure model is the only warning of watched lanes"

# ---- engagement ranges ----
tunableF CarrierFireRange, 1100, 600, 1800, 10,
  "while carrying, only shoot enemies this close (px)"
tunableF RushEngageRange, 2300, 1400, 3600, 10,
  "racing for the steal: only fight what blocks it (px)"
tunableF EscortEngageRange, 3200, 2000, 4600, 10,
  "escorting a run: only fight near threats (px)"
tunableF PocketRushRange, 2100, 1200, 3200, 10,
  "this close to the enemy pedestal, just GRAB (px)"
tunableF ThreatRange, 2000, 1200, 3000, 10,
  "react to a visible enemy this close facing us (px)"
tunableF DuckRange, 3400, 2000, 4800, 10,
  "duck from remembered threats this close on cooldown (px)"
tunableF MateSpacing, 400, 200, 900, 10,
  "soft repulsion radius between teammates (px)"
tunableF CorridorHalfWidth, 150, 80, 250, 10,
  "friendly-fire corridor half width along the firing ray (px)"

# ---- tracking / memory ----
tunableF TrackMatchDist, 400, 200, 800, 10,
  "a sighting matches a remembered track within this distance (px)"
tunableI TrackTtl, 120, 40, 300,
  "forget a player not seen for this many ticks (~5s default)"
tunableI FreshShotTicks, 24, 8, 48,
  "only fire at tracks seen this recently; chases keep shooting a bit after the target fogs out"
tunableI ThiefFixTtl, 40, 16, 120,
  "a thief position fix guides the chase this long (ticks)"
tunableI ThiefCommitTtl, 240, 80, 600,
  "-d:thiefCommit: how long a dead-reckoned fix keeps every free role committed to the thief chase (ticks)"

# ---- aiming / firing policy (CLOSED family for tuning — see header) ----
tunableF LeadTicks, 60, 20, 120, 10,
  "aim this many ticks ahead of a moving enemy (the 5-tick windup releases late)"
tunableI AimResyncBrads, 4, 2, 12,
  "trust aim dead reckoning inside this error (brads)"
tunableI CombatDeadband, 2, 1, 6,
  "stop the traverse within this error in combat (brads); AimRate 5 cannot settle tighter than +-2"
tunableI CruiseDeadband, 8, 2, 16,
  "sloppier traverse deadband for non-combat aim (brads)"
tunableF FireSlackPx, 110, 60, 160, 10,
  "fire when the aim error's perpendicular miss at the target's range is inside this (px)"
tunableI ScanArc, 44, 24, 80,
  "scan sweeps this many brads each side of the watch heading (vision cone half-angle is 32)"
tunableI TargetCallCooldown, 48, 12, 120,
  "min ticks between one bot's engage callouts"

# ---- target selection (focus fire) ----
tunableF HpFocusBonus, 600, 0, 1500, 10,
  "px of effective-distance credit per missing enemy hit point (tiebreak, never a cross-map swing)"
tunableF ThiefFocusBonus, 4000, 2000, 8000, 10,
  "px of credit for the enemy running OUR flag — killing the thief returns it instantly"
tunableF FocusFireBonus, 450, 0, 1200, 10,
  "px of credit when a visible mate's aim line already covers the target (finish together)"
tunableF TraversePxPerBrad, 16, 5, 40, 10,
  "px of effective distance per brad of turret swing needed to lay on the target"
tunableF MateAimRayLen, 7000, 3000, 10000, 10,
  "trust a mate's aim line out to this range (px)"
tunableF MateAimHitSlack, 220, 100, 400, 10,
  "enemy within this perpendicular distance of a mate's aim ray counts as mate-targeted (px)"

# ---- grenade policy (CLOSED family for tuning — see header) ----
tunableF NadeMinRange, 720, 520, 1200, 10,
  "never lob inside this — the 52px blast + drift would clip us (px)"
tunableF NadePickupDetour, 900, 300, 2000, 10,
  "grab a grenade pickup within this detour range (path px)"
tunableI NadeCampTicks, 360, 120, 720,
  "-d:campNade: a stationary remembered enemy stays lob-eligible this long after fogging out"
tunableF NadeCampSpeed, 3, 1, 10, 10,
  "px/tick: tracks slower than this count as camped"
tunableI StaleClusterTtl, 600, 200, 1200,
  "-d:nadeCluster: a track this old is still a target if it clustered"
tunableF ClusterPairPx, 900, 500, 1500, 10,
  "two remembered enemies this close = one blast (px)"
tunableI SalvoWindow, 70, 30, 140,
  "ticks after the charge order to force the lob"

# ---- pickups / heals ----
tunableF MedKitDetour, 800, 300, 2000, 10,
  "heal-detour budget when merely wounded (path px)"
tunableF MedKitCriticalReach, 1800, 900, 3200, 10,
  "at 1 hp a heal outranks the current errand within this (path px)"
tunableF MedKitCarrierBudget, 900, 400, 2000, 10,
  "extra path px a hurt CARRIER spends to heal — a full-heal carrier survives pocket exits"
tunableF MedKitSeenClear, 550, 300, 900, 10,
  "inside this range an empty kit spot is truly empty (bubble vision), not just fogged (px)"
tunableF PlasmaDetour, 700, 200, 1600, 10,
  "attacker detour budget for a plasma arc pickup (path px)"
tunableF ShieldStealDetour, 4800, 2000, 8000, 10,
  "MidGuard's trip to the enemy endzone shield (~430 path px round trip since GV7)"

# ---- flag carry model ----
tunableF CarrySelfRadius, 260, 150, 400, 10,
  "carried-banner slack: anything inside this that no visible mate sits closer to is OUR carry (px)"
tunableF CarrierEstSpeed, 10, 5, 15, 10,
  "px/tick a fogged mate-carrier is assumed to advance homeward (carrier moves ~70% speed)"

# ---- cover / overwatch ----
tunableF CoverShieldDist, 420, 250, 700, 10,
  "an obstacle this close blocks a threat direction (px)"
tunableF PeekLineDist, 1500, 800, 3000, 10,
  "floor for an overwatch peek firing line; post scoring prefers the longest line (px)"
tunableI DuckSearchCells, 3, 1, 6,
  "duck-cell search radius (nav cells)"
tunableI PeekSearchCells, 3, 1, 6,
  "peek-cell search radius (nav cells)"

# ---- exposure model / movement under threat ----
tunableF ExposureRange, 3800, 2200, 5200, 10,
  "enemy threat radius used for exposure costing (px)"
tunableI ExposureThreats, 3, 1, 6,
  "cost only the freshest few remembered threats"
tunableI ExposureTrackTtl, 60, 20, 150,
  "only cost threats remembered this recently (ticks)"
tunableI UnderFireTrackTtl, 16, 6, 40,
  "tracks this fresh can pin us on open ground (ticks)"
tunableF SerpentineNear, 1000, 500, 2000, 10,
  "serpentine band floor: closer threats are jink/duck territory (px)"
tunableF SerpentineFar, 4000, 2400, 6000, 10,
  "serpentine band ceiling: farther tracks cannot really aim at us (px)"

# ---- flank / lane geometry ----
tunableF FlankDepth, 2600, 1400, 4000, 10,
  "wide flankers cross this far past mid (px)"
tunableF WeaveBand, 2800, 1600, 4200, 10,
  "rushers serpentine within this x-band of mid (px)"
tunableF CenterScanHalf, 2800, 1500, 4500, 10,
  "|x - CenterX| under this counts as the corridor (px)"

# ---- plasma arc usage (bot-side margins over sim geometry) ----
tunableF ArcReach, 1300, 1100, 1360, 10,
  "plasma cone engage reach: sim reach is 136px, keep a safety margin (px)"
tunableI ArcConeBrads, 13, 6, 18,
  "cone ignition angle tolerance (brads): sim half-width 10 + 3 margin (the burning cone tracks our traverse)"

# ---- endgame / tempo ----
tunableI CounterPunchTick, 1400, 900, 2200,
  "by here a 0-steal attack is not converting: fall back and win the attrition instead"
tunableI PushOutTicks, 360, 180, 720,
  "endgame push: no enemy seen for this long breaks the posts (~15s default)"
tunableI PushOutMinGame, 1400, 800, 2400,
  "...but only this deep into the game"
tunableI StalemateTick, 2000, 1200, 3000,
  "nobody has MOVED a flag by here: the game is heading for a lose-lose timeout — go convert"
tunableI QuietForBreak, 240, 96, 480,
  "the field must be actually DEAD (no enemy contact this long) before an early castle break"
tunableI LatePushTick, 3400, 2600, 4200,
  "all-in on the clock: past this tick a draw is a loss for both and games cap at 5000 ticks"
tunableF HoldFrontCap, 2200, 1200, 3600, 10,
  "-d:holdFront: ceiling on the phalanx creep — a castle line near our wall (px)"

# ---- siege mode (-d:siege) ----
tunableI SiegeBarrageTicks, 100, 40, 200,
  "-d:siege: bombardment window per cycle (ticks)"
tunableI SiegeAdvanceTicks, 90, 40, 200,
  "-d:siege: advance-and-settle window per cycle (ticks)"
tunableF SiegeStep, 1700, 800, 3000, 10,
  "-d:siege: ground taken per advance order (px)"

# ---- communication / coordination cadence (hoisted from inline literals) ----
tunableI ShoutCooldown, 26, 12, 60,
  "min ticks between one bot's gameplay shouts (the ~1 per second voice slot)"
tunableI ComebackReqCooldown, 240, 60, 600,
  "min ticks between comeback ('K') requests"
tunableI TargetCallFreshTicks, 15, 5, 60,
  "-d:targetCall: engage callout only for targets seen this recently"
tunableF TargetCallRange, 5000, 2000, 7000, 10,
  "-d:targetCall: engage callout only for targets within this range (px)"
tunableI HelpShoutCooldown, 400, 120, 900,
  "-d:zonePhalanx: min ticks between outnumbered ('H') help calls"
tunableI HelpTrackAge, 50, 15, 120,
  "-d:zonePhalanx: H call counts enemies seen this recently (ticks)"
tunableF HelpNearRange, 4200, 2000, 6000, 10,
  "-d:zonePhalanx: H call counts enemies within this range (px)"
tunableI HelpNearCount, 3, 2, 6,
  "-d:zonePhalanx: enemies within HelpNearRange that trigger the H call"
tunableI EShoutCooldown, 30, 10, 90,
  "-d:zonePhalanx: min ticks between the scout's sighting ('E') relays"
tunableI EShoutTrackAge, 20, 5, 60,
  "-d:zonePhalanx: sighting relay only for enemies seen this recently"

# ---- memory / movement misc (hoisted from inline literals) ----
tunableF SpotDedupRadius, 240, 120, 400, 10,
  "pickup/nade-spot memories within this distance are the same spot (px)"
tunableF CampMemRadius, 500, 250, 900, 10,
  "-d:nadeCluster: camp-memory sighting dedup radius (px)"
tunableF MateCarryNearRange, 2500, 1200, 4000, 10,
  "escort radius: this close to a mate's carry switches to escort logic (px)"
tunableI StuckJinkTicks, 20, 8, 60,
  "stuck against geometry this long triggers the jink escape"
