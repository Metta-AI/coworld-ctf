# CQC video-game lens — competitive team-shooter tactics for an 8v8 CTF bot

> Companion to `ctf-playbook.md`. That doc sourced plays from real-world SEAL/CQB doctrine.
> This doc is the **video-game layer**: what expert *human* teams do in competitive arena/CTF
> shooters (Counter-Strike, Valorant, Overwatch, Team Fortress 2, Quake/QuakeWorld CTF), and —
> critically — **how it INVERTS real-life CQC** because the medium is a game: respawns, no fear
> of death, hitscan weapons, a scored clock, and wipe/attrition win conditions.
>
> Each principle is a short imperative + WHY it's true + HOW it would manifest as a concrete bot
> behavior, with an inline citation. ~55 principles across 6 themes. The priority theme —
> **contingency / branch planning (§1)** — comes first and is weighted heaviest.
>
> **Reading note for the encoder:** many of these want a captain's global read that this codebase
> cannot broadcast (see `ctf-playbook.md`: comms is a lossy 10-char shout, no reliable election).
> Where a principle needs a "caller," treat it as *either* (a) a per-bot local rule that happens
> to converge because all bots run it, or (b) something keyed off the two provably-shared signals
> (elapsed-since-round-start clock; own-flag/carry state). Flagged inline as **[shared-signal OK]**
> or **[needs-read: local-approx]**.

---

## Why the video-game lens differs from real CQC (the frame)

In real CQB, death is terminal, information is foggy, ammo and fatigue are real, and you never
trade your life. In a competitive respawn shooter almost every one of those inverts, and the
inversions are where the *edge* is:

- **Death is a timer, not an ending.** A death that costs the enemy a player, a position, or
  enough time is a *winning trade*. Suicide grabs and body-blocks become +EV.
- **The clock is the real opponent.** You're not trying to survive; you're trying to out-score
  before time runs out. Aggression is a function of score + clock, not danger.
- **Information is often near-perfect.** Killfeed/HUD tell you exactly who's dead and for how
  long, so you can *math out* man-advantage windows instead of guessing.
- **Numbers are the currency.** Every fight is really a fight over the alive-count for the *next*
  few seconds. Removing one enemy gun permanently helps every future second until they respawn.
- **Hitscan punishes exposure instantly.** No bullet travel time means peeking, holding, and
  angles are decided in milliseconds — the opposite of leaning around real cover.

Everything below is downstream of those five facts.

---

## §1 — Contingency / branch planning (PRIORITY)

The core idea: expert callers do **not** issue one instruction at a time. They pre-brief a
*default* plus explicit **if-then branches** so the team already knows the response the instant a
trigger fires. This is exactly the structure the bot's play layer wants.

**Pre-brief the branches** — Issue every round-plan as a *default plus explicit if-then audibles*,
never a single committed line. WHY: pre-loading the branch means the team already knows the
response the moment a trigger fires, so nobody freezes mid-round negotiating what to do. HOW:
each attack cycle carries a compact plan struct — `{default: pressure mid; if pick_gained → group
+ push weak side; if no_contact@Ts → split; if clock<X → force flag}` — that every bot reads and
executes without re-deciding. **[shared-signal OK for clock branches; needs-read: local-approx for
pick/contact branches]** [Boosteria CS2 Communication Guide — https://boosteria.org/guides/cs2-communication-guide-calls-trades-mid-round-plans]

**Default, then finish** — Open every round in a non-committal "default" that gathers information,
and convert to a committed finish only when a trigger fires. WHY: a default is "reconnaissance, of
a sort" — spreading to learn the enemy setup keeps the maximum number of options open until the
last useful moment. HOW: spend the opening seconds spreading scouts across key lanes to read the
enemy stack, holding the "finish" (grouped hit / split / rotate-to-weak-side) in reserve until a
pick, a spotted gap, or a time threshold triggers it. [Refrag — https://refrag.gg/blog/what-is-a-default-cs2/]

**Name the trigger** — A contingency is only real if its trigger is a *concrete observable event*:
a pick, spent enemy utility, a heard rotation, a time threshold. WHY: vague plans ("maybe go B")
die on contact; a named trigger ("if we get a pick mid, we split") produces instant unambiguous
execution. HOW: encode triggers as boolean predicates over game state —
`enemy_killed_in_lane`, `enemy_util_spent`, `heard_rotation`, `round_clock < T` — each wired to
exactly one branch action. [Boosteria — https://boosteria.org/guides/cs2-communication-guide-calls-trades-mid-round-plans]

**Pick flips the plan** — Treat a kill (a numbers edge) as the *primary* re-call trigger: the
instant you go up a body, convert the default into a committed group-and-hit. WHY: with respawns a
man-advantage is a short window ("five versus four, use numbers on B") and spending it *is* the
whole point. HOW: on any confirmed pick, flip from spread/default into a synchronized push on the
side where the advantage exists, before the downed enemy respawns. **[needs-read: local-approx —
key off own-kill + nearby teammate kills]** [csgo-guides IGL — https://csgo-guides.com/roles/igl]

**Force on the clock** — Make the timer a first-class trigger: when the round clock crosses a
threshold, cut lurking/scouting and force a committed play. WHY: a "good enough action before
time, health or utility disappear" beats a perfect play that never fires ("twenty seconds: no more
lurk, hit B"). HOW: a hard `elapsed > T` predicate overrides the passive default and forces a
grouped flag attempt or all-in, preventing timid stalling into a scoreless clock. **[shared-signal
OK — this is exactly the elapsed-since-round-start clock]** [Alviran Valorant IGL Guide — https://alviran.net/blog/valorant-igl-communication-guide-2026/]

**One sound, one rotator** — Never full-rotate the whole team on a single sound or sighting; send
one to confirm and keep the rest anchored. WHY: "counts come first because they decide everything"
— two enemies can't take a site, so an all-rotate on a feint is exactly how you lose the real
objective. HOW: on an ambiguous cue, dispatch one defender to gather a count/confirm and hold the
rest until the read resolves, avoiding the "everyone rotates on a fake" failure. [Guild Order
Valorant Comms — https://guildorder.com/games/valorant/guides/comms-and-callouts]

**Never split-decide** — When a read goes wrong, commit *fully* to one branch — full retake or
full save — never a half-team hedge. WHY: the worst outcome is a "split decision" where some push
and some fall back, losing to both; decisiveness beats correctness. HOW: when a plan is
invalidated (flag lost, entry failed), resolve to a single unanimous branch ("full collapse to
retake" OR "full reset/regroup") rather than letting the squad fracture. [Boosteria — https://boosteria.org/guides/cs2-communication-guide-calls-trades-mid-round-plans]

**Cancel needs a regroup** — Any audible/abort must name a *regroup point and a new timing*, not
just "stop." WHY: audibles "fail without a clear regroup point" — telling a team to cancel without
a rally spot produces a scattered, easily-picked mess. HOW: a re-call always carries a rendezvous
node and a countdown ("regroup mid, re-hit in 10"), so a canceled push reforms as a coordinated
group instead of dribbling in one at a time. **[shared-signal OK — countdown on the shared
clock]** [Boosteria — https://boosteria.org/guides/cs2-communication-guide-calls-trades-mid-round-plans]

**Reads beat sites** — Adapt the target to what the enemy shows: if they stack one side, hit the
other; if they over-rotate, feint then hit the vacated side. WHY: the enemy setup *is*
information, and "defaults don't commit to anything," so the correct target is whichever side the
read reveals as weak. HOW: maintain a running estimate of enemy defender distribution and route
the flag push at the lowest-density side, feinting toward the stacked side to hold it. [csgo-guides
IGL — https://csgo-guides.com/roles/igl]

**Backstop the caller** — Predesignate who assumes calling when the primary caller dies, so the
plan survives losing its brain. WHY: in respawn games the IGL dies constantly ("if your IGL is
dead by 0:45, the mid-round caller assumes voice") — a leaderless team reverts to solo players.
HOW: define a caller-succession order so when the caller unit is downed, the next-priority live
unit inherits the plan struct and keeps issuing branch calls until respawn. In this codebase,
prefer making the "plan" a pure function of shared state so *no* unit needs to hold it. [Guild
Order Valorant Comms — https://guildorder.com/games/valorant/guides/comms-and-callouts]

**Adapt, don't thrash** — Change formation/assignments only when a detected pattern crosses a
*confidence threshold*; reflexive counters cost you your own strengths. WHY: "locking a
mathematically optimal comp and never adjusting is worse than a smart mid-match swap," but a swap
for no reason breaks your own synergy — anti-stratting is double-edged. HOW: gate any
re-assignment on a hysteresis threshold (N consecutive confirming observations) and otherwise hold
the baseline default so the team doesn't oscillate. [Counterwatch — https://www.counterwatch.gg/blog/overwatch-team-composition-guide-synergy-balance-and-win-rat-8b715608]

**Utility solves the problem** — Spend your strongest tools (power item / paintbomb) on the
round's *biggest current obstacle*, chosen reactively, not on a fixed script. WHY: rigid
pre-planned utility is wasted when the plan breaks — "utility should solve your biggest problem,
not your favorite habit." HOW: pick the ability target from the live bottleneck (block a rotation
lane, stall a push, deny a defended choke) instead of dumping it on a rote timer. [CS2Hype
Mid-Round Adaptation — https://cs2hype.com/guides/mastering-cs2-mid-round-adaptation-how-to-react-and-adjust-for-victory]

---

## §2 — CTF-specific meta (roles, pushes, stalemates, conversion)

**Split def-mid-att** — Hard-assign fixed roles at spawn (defense / midfield / offense) instead of
letting all 8 free-roam. WHY: competitive CTF resolves to a "def-mid-att" split because uncovered
offense or defense loses the game while lone-wolfing gets your flag capped repeatedly. HOW: assign
seats each match (e.g. 3 defense / 2 midfield / 3 offense) and have each bot check "is my role
still covered?" before deviating. [QL CTF Guide, Plus Forward — https://www.plusforward.net/multipage/?page=3&pid=835]

**Midfield is eyes** — Keep midfielders high and central to scout and gate the map, not to farm
frags. WHY: the mid player is "the eyes and ears of your defender," a damage buffer, and "inflicting
damage on incoming enemys is enough, dont chase for frags." HOW: midfield bots hold a choke node
between bases, broadcast enemy sightings, and deal damage-in-passing without abandoning position to
chase kills. [Steam CTF Guide (5v5) — https://steamcommunity.com/sharedfiles/filedetails/?id=3145278073]

**Grab with control** — Only grab the enemy flag once your team owns midfield; never grab into a
full enemy squad. WHY: a lone grab into a stacked defense gets picked "1 by 1," whereas grabbing
behind midfield control means escorts are already forward. HOW: gate the grab behind a precondition
— the runner waits to touch the flag until midfield reports "mid clear" or ≥N teammates are past
center. [QL CTF Guide — https://www.plusforward.net/multipage/?page=3&pid=835]

**Carrier runs home** — The flag carrier's only job is to survive and reach base — do not stop to
fight. WHY: it's "Capture the Flag — not Die a Spectacular Death"; once you have it, "run (and
think at the same time)... Don't bother yourself with killing enemies (unless you absolutely have
to)." HOW: on pickup, a bot switches to a carrier behavior that pathfinds the *safest* route home
(avoiding known enemy positions from callouts) and only fires when directly blocked. [ChocoLLama
Quake CTF Strategy — https://www.geocities.ws/oldquaker/clanllama/strategy.html]

**Escort the runner** — Nearby teammates body-block, clear interceptors, and follow the carrier
"until it is a cap." WHY: protecting the carrier means "not taking any items around him or in front
of him, not even a 5hp bubble," killing interceptors, and eating hits for him. HOW: any offense/mid
bot within radius of a friendly carrier enters escort mode — matches the carrier's route,
prioritizes shooting enemies aiming at the carrier, and refuses to grab items in the carrier's
path. [QL CTF Guide — https://www.plusforward.net/multipage/?page=3&pid=835]

**Hand-off to speed** — If a faster/healthier teammate is nearby (or you're low), drop the flag
forward to them. WHY: "if a faster class such as a Scout is nearby, drop the Intelligence for
them," and drop it *before* knockback erases your forward progress. HOW: a wounded/slower carrier
drops the flag toward a healthier faster teammate's position rather than dying with it deep in
enemy territory. [TF2 Wiki Community CTF strategy — https://wiki.teamfortress.com/wiki/Community_Capture_the_Flag_strategy]

**Chase, then reset** — Pursue the enemy carrier to recover a stolen flag, but break off and
re-home if he's gone. WHY: "if he's too far gone or too fast, get back to base and prepare for the
next attack" — over-chasing leaves your base open. HOW: a recovery bot chases a fleeing enemy
carrier only while a time-to-intercept estimate is winnable; otherwise it returns to defend the next
wave. [Chimz Proper Teamwork in CTF — https://steamcommunity.com/sharedfiles/filedetails/?id=1633738299]

**Two blocking options** — When your flag is taken, you can either kill the carrier OR grab the
enemy flag to deny their cap. WHY: "you have two options: kill the carrier before he caps, or steal
the enemy flag to block their capture" — a cap can't complete while their own flag is also out. HOW:
if recovery looks unlikely, redirect an offense bot to grab the enemy flag, converting a losing
position into a mutual standoff. **[shared-signal OK — own-flag-stolen is globally legible]**
[Chimz Proper Teamwork — https://steamcommunity.com/sharedfiles/filedetails/?id=1633738299]

**Call the escape route** — Defenders broadcast the enemy carrier's escape direction so teammates
converge and the defender sweeps from the *uncovered* side. WHY: short callouts ("He's going
middle!") let teammates intercept; a smart defender checks which route teammates already hold and
sweeps from the other. HOW: a defender emits a route/direction event on flag loss; interceptors path
to cut-off nodes on that route while the defender flanks the uncovered lane. [Chimz Proper Teamwork
— https://steamcommunity.com/sharedfiles/filedetails/?id=1633738299]

**Push in sync** — Attack in one coordinated wave so defenders can't pick you off one at a time.
WHY: "synchronize your attacks so enemy def can't pick you off 1 by 1," forcing more damage than a
single item-cycle can recover; a 3-man push traps the enemy in their base. HOW: offense bots stage
at a rally node and commit simultaneously when the group reaches size N, rather than trickling in as
each respawns. [QL CTF Guide — https://www.plusforward.net/multipage/?page=3&pid=835]

**Snowball the pick** — When you hear the enemy defense is low/dead, immediately push the
man-advantage into a grab before it resets. WHY: "when you hear the enemy def is low (screaming)...
push with 3 for one cycle" — the opening is temporary, and the most common throw is chasing kills
instead of taking the objective. HOW: on a "enemy down/low" signal, offense bots trigger an
immediate coordinated grab timed to the enemy's respawn delay, then fall back to hold. [QL CTF Guide
— https://www.plusforward.net/multipage/?page=3&pid=835]

**Never full-send** — Keep at least one or two defenders home at all times; don't all-in every
player. WHY: all-in aggression "concentrates the enemy inside their own territory," making grabs
harder and leaving you "open to easy captures"; even a losing team keeps one attacker to force the
enemy to divert defenders. HOW: enforce a floor of home defenders that cannot leave regardless of
offensive opportunity, plus a floor of one attacker even under heavy defense. [TF2 Wiki Community
CTF strategy — https://wiki.teamfortress.com/wiki/Community_Capture_the_Flag_strategy]

**Break cross-caps fast** — In both-flags-out ("cross cap") stalemates, the freshest/most-stacked
bot races the tiebreaker home while others secure. WHY: "a delay of even 1 second can decide if a
flag is returned or is capped," and the well-stacked player is "the guy to bring the tiebreaking cap
home." HOW: when both flags are out, designate the bot with best survival odds (highest HP/armor,
safest route) as capper; the rest form its escort and block the enemy carrier. **[shared-signal OK
— both-flags-out is globally legible]** [QL CTF Guide — https://www.plusforward.net/multipage/?page=3&pid=835]

**Own the timers** — Track and control high-value items/powerups; deny them to the enemy. WHY:
"time and control your items... an item denial means a lot," and powerups (Quad/Protection) "change
the tide of battle." Powerups cycle on a fixed clock. HOW: bots track item/powerup respawn timers,
pre-position to grab powerups on spawn (denying the enemy), and route a powered-up bot into a
synchronized push. **[shared-signal OK — item timers are deterministic]** [Steam CTF Guide (5v5) —
https://steamcommunity.com/sharedfiles/filedetails/?id=3145278073]

**Give items to the strong** — Route health, armor, and powerups to your healthiest / highest-impact
teammates and the carrier. WHY: "if you are weak, give powerups, items & weapons to healthier or
higher rated teammates" — concentrate resources on whoever can convert them. HOW: a low-HP bot
skips a nearby pickup when a healthier teammate or the carrier is close and heading the same way,
keeping the strong player stacked. [Chimz Proper Teamwork — https://steamcommunity.com/sharedfiles/filedetails/?id=1633738299]

---

## §3 — Attrition / man-advantage tempo (wipe → push, don't feed)

**Trade every death** — Never let a teammate die untraded; kill the enemy who got them within ~1
second. WHY: a traded death resets the fight to even and gifts you the enemy's position, whereas a
dry death means "the enemy plays the rest of the round up a player." HOW: when a teammate dies, the
nearest ally immediately swings/pre-aims the killer's last position rather than continuing its own
path. [CSStatLab Trading Kills — https://www.csstatlab.com/academy/gameplay/trading-kills]

**Stay tradeable, spaced** — Position a short distance behind the lead fighter, on a *different*
angle — close enough to punish, far enough that one AoE/spray can't kill you both. WHY: being behind
isn't enough; "stay close, but not stacked," and you must be *ready* to re-frag on contact. HOW: a
follower holds a trailing offset on a distinct sightline to the leader's contact point, weapon
already trained forward, never in the leader's collision path. [CSStatLab Trading Kills — https://www.csstatlab.com/academy/gameplay/trading-kills]

**Punish the pick** — The instant you win a fight and go up a body, press it — "we got one, now make
them solve the round." WHY: a 5v4 is only worth something if you spend it before the enemy resets.
HOW: after a confirmed kill yielding a local numbers edge, the winning cluster advances on the
contested lane/flag immediately rather than backing off. [CSStatLab Man Advantage — https://www.csstatlab.com/academy/gameplay/man-advantage-fundamentals]

**Don't overpeek the lead** — When up a man, do NOT hunt the extra kill with greedy solo peeks.
WHY: man-advantage rounds "are lost through impatience more than mechanics," and the edge
"disappear[s] quickly if the advantaged team overpeeks or gets split up." HOW: a bot that just
gained a local numbers edge suppresses independent aggressive peeks into unknown angles and holds
space, waiting for the enemy to move. [CSStatLab Man Advantage — https://www.csstatlab.com/academy/gameplay/man-advantage-fundamentals]

**Collapse into one fight** — When up bodies, force the round into one or two coordinated fights
instead of offering several isolated 1v1s. WHY: spreading thin "gifts multiple opportunities to get
back into the round." HOW: agents with a man advantage regroup toward a single defensible
choke/flag lane rather than fanning out to cover everything, denying the down-team any even duels.
[CSStatLab Man Advantage — https://www.csstatlab.com/academy/gameplay/man-advantage-fundamentals]

**Make them come** — When ahead, stop forcing the action — hold stacked crossfires and let the
enemy walk into your guns. WHY: "you no longer need to force the action — the enemy does"; time is
now your ally. HOW: an up-a-man team defending its flag or a lane sets up mutually-covering holds
and lets objective/clock pressure force the enemy into prepared angles. **[partly shared-signal —
"ahead" from score/flag state]** [eloking Man Advantage — https://eloking.com/glossary/csgo/man-advantage]

**Don't reinforce failure** — Recognize a clearly lost fight and fall back; don't feed bodies into
it. WHY: "if the teamfight is clearly lost, fall back and regroup" — "winning a teamfight with a
three-person deficit is extremely unlikely." HOW: when local force ratio drops below even (down 2+
in an engagement), surviving agents disengage toward safety instead of walking into the fight that
just killed their teammates. [Blizzard Forums Fall Back & Regroup — https://us.forums.blizzard.com/en/overwatch/t/fall-back-and-regroup/594659]

**Don't trickle in** — Never sprint back solo after death; wait to re-enter with at least one
teammate. WHY: staggered arrivals mean "you will die one by one"; regrouping is "a necessary
investment" since the team that draws first blood wins the large majority of fights. HOW: a
freshly-respawned bot stages at a rally point until a minimum group forms before pushing toward the
objective. [Dignitas Ultimate Economy & Regrouping — https://dignitas.gg/articles/blogs/overwatch/12958/ultimate-economy-and-regrouping-in-overwatch]

**Die together, respawn together** — A grouped wipe respawns as a wave and re-enters whole;
staggered deaths reset your fight repeatedly. WHY: respawn systems even sync deaths within a few
seconds into one wave — a team that returns whole gets "space," a trickle does not. HOW: if a fight
is already lost, prefer a coordinated fall-back-and-wipe (or synchronized reset) so the team
re-forms at full strength, rather than saving one straggler who feeds a solo death. [CharlieINTEL
OW2 Group Respawn — https://www.charlieintel.com/overwatch-2/overwatch-2-group-respawn-feature-explained-278856/]

**Snowball the spawn tempo** — Track the alive-count/spawn edge before each engagement and take
whatever free push the enemy gives you. WHY: pressing while the enemy is down players and out of
position compounds the lead. HOW: maintain a live alive-teammates-vs-alive-enemies count (and enemy
respawn timers if inferable) and switch to aggressive objective pushes only during man-advantage
windows. **[needs-read: local-approx — count visible living enemies/teammates]** [OverwatchU
Retreating, Respawns & Risk — https://www.reddit.com/r/OverwatchUniversity/comments/14wz42i/retreating_respawns_and_risk_management_how_to/]

**Play the clock** — "Slow when you can afford to, fast when you must" — let time pressure the
enemy when you're ahead; act only when behind on score forces it. WHY: whoever uses the clock
better "wins the round they should." HOW: tie aggression to game state — stall and hold when
leading on flags/score, accept risky forces only when the clock demands a comeback. **[shared-signal
OK — elapsed clock + globally-legible score]** [CSStatLab Playing the Clock — https://www.csstatlab.com/academy/gameplay/playing-the-clock]

**Even the numbers first** — When DOWN a man, play slower, avoid unnecessary duels, and hunt
isolated fights to equalize before contesting the objective. WHY: disciplined trading "evens the
numbers"; contesting the objective down bodies just feeds. HOW: a short-handed team defers the flag
grab/push, looks for favorable isolated picks to reach parity, and only re-commits to the objective
once even. [eloking Man Advantage — https://eloking.com/glossary/csgo/man-advantage]

**Track the resource** — Sequence engagements around the power-item/cooldown differential: enter
only at parity-plus, otherwise bait, stall, or reset. WHY: fights are decided "before the first
shot" by resource economy — "the team with ult advantage decides when to engage." HOW: track
team-vs-enemy power-item (paintbomb) availability and only greenlight a wipe attempt at
parity-plus; at a deficit, stall the choke and force the enemy to spend first. [Guild Order OW Ult
Economy — https://guildorder.com/games/overwatch/guides/ult-economy-and-fight-sequencing]

---

## §4 — What INVERTS vs real CQC (the game-native moves)

**Trade your life** — Peek or grab even when you'll die, *as long as* a teammate can kill your
killer within ~1 second. WHY: in real CQC your death ends you; in a respawn game a death that costs
the enemy a player/position/time is a winning trade that turns two isolated 1v1s into one fight the
enemy must solve on two timings. HOW: the bot never enters a duel without a second bot inside ~1s
trade range on the same danger, crosshair already on that angle — "close enough, never stacked."
[Alviran VALORANT Trading Guide — https://alviran.net/blog/valorant-trading-guide-2026/]

**Suicide-grab the flag** — Touch the flag even if you die immediately after, because the grab
itself resets timers and drags defenders out of position. WHY: in real life you never charge a
fortified objective to die on it; here a grab that dies still "buy[s] time for a real attack to
break through" and resets the recovery timer. HOW: send a fast expendable runner to force a grab
whenever real pressure is arriving behind it, treating its own death as a timer-reset tool, not a
failure. [TF2 Wiki Community CTF strategy — https://wiki.teamfortress.com/wiki/Community_Capture_the_Flag_strategy]

**Body-block the carrier** — Throw your body into a doorway/choke to physically stop an enemy flag
carrier, spending your life to deny progress. WHY: in CQC you'd never stand in the open to be shot;
here a body can "block doorways or other routes to prevent the escape," and even a dying block
erases the carrier's forward progress. HOW: when an enemy carrier is escaping, the nearest bot paths
*into* the carrier's exit choke and stands in it rather than trying to out-DPS from range. [TF2 Wiki
Community CTF strategy — https://wiki.teamfortress.com/wiki/Community_Capture_the_Flag_strategy]

**Remove a gun** — Concentrate the whole team's fire to fully delete ONE target instead of spreading
damage. WHY: spreading lets a healed enemy stalemate, but concentrating fire "locally exceed[s] the
opponent's total damage output" and permanently subtracts that target's DPS from every future
second — a compounding numbers edge (unlike real suppressing fire, which has value even without a
kill). HOW: run a shared target-call variable so all engaging bots shoot the same enemy until it
dies, then shift together. [note.com OW focus-priority guide — https://note.com/fre_d_/n/na3c828ddc270?hl=en]

**Kill the support first** — Priority order: enemy carrier > isolated support/healer > low-HP
flanker > isolated attacker >> anyone grouped or full-HP. WHY: an "isolated support" is "the most
cost-effective focus target" (killing it collapses enemy sustain), while a big-HP target "cannot be
defeated quickly even if focused." HOW: compute a target-priority score from the HUD every tick and
focus the highest-value reachable enemy, not the nearest. [note.com OW focus-priority guide — https://note.com/fre_d_/n/na3c828ddc270?hl=en]

**Deny, don't chase** — Count a target as "handled" the moment you force it to retreat or stop
shooting, even with zero kill. WHY: a flanker chased off to heal is "effectively out of the team
fight for over ten seconds" — you removed its gun without the frag, an idea with no CQC analog. HOW:
treat "enemy fled below X HP / left sightline" as a satisfied objective and immediately re-task to
the next target rather than over-committing to the chase. [note.com OW focus-priority guide — https://note.com/fre_d_/n/na3c828ddc270?hl=en]

**Take peeker's advantage** — Prefer to be the one who *initiates* contact by moving into an angle,
because the mover sees the stationary holder first. WHY: latency plus "the person you peek is a
stationary target" means the peeker fires first — the opposite of real CQC, where breaking cover
into a prepared position is suicide. HOW: the bot prefers swinging a held angle over passively
holding, and times swings right after the enemy shoots or spends utility. [csgo-guides Positioning —
https://csgo-guides.com/gameplay/positioning]

**Pre-aim, don't react** — Hold the crosshair at enemy body/head height on the exact spot an enemy
will appear, *before* they appear. WHY: most fast kills come from pre-aim, not reflexes — you win by
already aiming where geometry says the enemy must be. HOW: always park aim on the nearest uncleared
corner/sightline at enemy height along the path, never at floor or sky, so first-frame exposure =
first accurate shot. [Boosteria CS2 Peeking & Angle Advantage — https://boosteria.org/guides/cs2-peeking-angle-advantage-timing-pre-aim-off-angles]

**Pre-fire known spots** — Shoot through common angles/chokes before you even see an enemy. WHY:
maps are fixed and info is near-perfect, so firing "before you actually see the enemy" gives a
split-second edge — and wasting ammo has no real cost (no scarcity/fatigue realism). HOW: fire
pre-emptively into high-probability enemy positions (last-known location, common holds, the corner
about to be cleared) instead of waiting for a confirmed target. [Boosteria CS2 Peeking — https://boosteria.org/guides/cs2-peeking-angle-advantage-timing-pre-aim-off-angles]

**Jiggle for info** — Strafe a body-part out and instantly back to bait shots and gather info
without committing. WHY: a shoulder/jiggle peek "expose[s] just enough to see... then instantly
strafe[s] back," drawing fire and revealing positions at near-zero risk (real soldiers don't
repeatedly flash themselves to farm data). HOW: use short in-out jiggles at contested chokes to
reveal enemy presence/aim before deciding whether to commit a push. [Boosteria CS2 Peeking — https://boosteria.org/guides/cs2-peeking-angle-advantage-timing-pre-aim-off-angles]

**Hold off-angles** — Post up in unexpected spots away from where enemies pre-aim, take one kill,
then immediately relocate. WHY: off-angles "break default pre-aim," forcing a slower enemy first
shot; the "one and done" rule says leave before they adapt and pre-fire you. HOW: defending bots
rotate between non-obvious depth/height positions and move after each kill instead of camping the
one spot attackers clear first. [csgo-guides Positioning — https://csgo-guides.com/gameplay/positioning]

**Set up crossfires** — Position two bots to cover one lane from separate angles so an enemy
fighting one is exposed to the other. WHY: "an enemy engaging one exposes themselves to the other,"
and if one dies the other trades instantly — but keep them spaced so "one nade shouldn't kill both."
HOW: default flag defense to paired crossfires on each entrance choke (one deep, one wide) rather
than stacking two bots on the same sightline. [csgo-guides Positioning — https://csgo-guides.com/gameplay/positioning]

**Own the choke and high ground** — Funnel enemies through chokepoints and hold high ground for
first-sight and worse enemy headshot angles, but treat elevation as temporary. WHY: high ground lets
you "spot enemies first" with a "harder headshot angle against you"; chokes let defenders
peek-info-and-fall-back — both are info/angle levers, not places to die. HOW: route flag runs to
avoid enemy chokes/high ground, and site defense to force attackers through a single funnel covered
by crossfire + area denial, abandoning perches once spotted. [csgo-guides Positioning — https://csgo-guides.com/gameplay/positioning]

**Deny with area** — Camp and spam explosive/area fire onto the objective and chokes even with no
visible target, because denying space is a legitimate win. WHY: in arena play "rail 'camping' (it's
called defence) works in CTF," and area effects on dropped flag "stop a single capture attempt
instantly" — blind area denial is +EV here in a way it rarely is in reality. HOW: saturate the enemy
capture zone and the flag's return path with area effects/pre-fire when holding a lead and running
down the clock. [Quake3World Rail Gun Tips — https://www.quake3world.com/forum/viewtopic.php?t=23814]

**Aim by weapon type** — With projectile weapons lead the target's path; with hitscan aim exactly
at it and treat any exposure as instantly lethal. WHY: a projectile "must be led" (it lags target
motion by travel time), whereas hitscan "resolves instantly" and needs zero prediction — so hitscan
punishes a peek the instant it shows. HOW: branch the aim model by weapon — crosshair-on-target for
hitscan, velocity-based lead for projectiles — and treat any hitscan exposure of the carrier as
immediately lethal. [Sam Reitich Projectile Prediction — https://sreitich.github.io/projectile-prediction-1/]

**Exploit the killfeed** — Use perfect HUD/killfeed info to math out man-advantage windows and time
pushes to known respawns, while denying the enemy the same read. WHY: you know exactly who's dead
and for how long, so you can push a 6v8 window with certainty — impossible in real fog of war. HOW:
track live alive-counts and respawn timers to trigger flag pushes only during confirmed
man-advantage windows, and *stagger your own deaths* to avoid handing the enemy a clean numbers
read. **[needs-read: local-approx for enemy counts; shared-signal OK for own respawn cadence]**
[Steam OW2 Competitive Optimization — https://steamcommunity.com/sharedfiles/filedetails/?id=3561543472]

---

## §5 — Adaptation & counter-strategy (read → counter → re-engage)

**Log their tendencies** — Keep a running read of which lane, side, and timing the enemy repeats,
and pre-position to punish it. WHY: predictable teams replay the same default and set plays, and
spotting the indicator lets you hard-counter before the round develops. HOW: maintain a rolling
histogram of enemy approach lanes and defended zones over the match, and bias defenders toward the
lane the enemy has favored in its last several pushes. [Dignitas Art of Anti-Stratting — https://dignitas.gg/articles/the-art-of-anti-stratting]

**Exploit the overstack** — When the enemy clumps on one side, swing hard at the side they
abandoned. WHY: bodies committed to one zone can't defend another, so a detected imbalance is free
objective tempo — "if enemies are stacked on one site, rotate swiftly to the other." HOW: if scouted
enemy density on one flag/lane exceeds a threshold, immediately redirect the attack squad to the
thin side. [CS2Hype Mid-Round Adaptation — https://cs2hype.com/guides/mastering-cs2-mid-round-adaptation-how-to-react-and-adjust-for-victory]

**Punish the passive** — Against a team that only sits and holds, take free map control and the
objective rather than trading peeks. WHY: a passive hold surrenders space and info, and a default
that spreads and gathers picks beats it without risky duels. HOW: when contact stays low and the
enemy isn't contesting midfield, advance the line to claim map control and stage a grab, taking
"calculated risks for info and potential picks." [Dignitas Default Strategies — https://dignitas.gg/articles/blogs/CSGO/8453/default-strategies-in-csgo-on-t-side-why-how-and-when]

**Set up to trade vs a rush** — Against a rush/force, stop clumping and hold spaced crossfires so
every death is instantly avenged. WHY: with respawns and no fear of death, attrition is won by
trades, not heroics; a rusher confused by two angles feeds a 1-for-1 you win on tempo. HOW: on a
fast-push read, defenders fall into paired crossfires at range where "the enemy cannot shoot more
than one of you at a time" instead of stacking a single choke. [Dignitas Winning Anti-Ecos — https://dignitas.gg/articles/blogs/CSGO/12129/a-guide-to-winning-anti-ecos]

**Spread beats stack** — Hold chokes with distributed players plus one free flexer instead of
grouping the whole squad. WHY: a spread lets you hit any point from multiple angles and react to
what the enemy reveals; a stack gets flanked or split. HOW: assign one defender per key choke and
keep a "free agent" that rotates to reinforce or trade, rather than parking the team on the home
flag. [Dignitas Default Strategies — https://dignitas.gg/articles/blogs/CSGO/8453/default-strategies-in-csgo-on-t-side-why-how-and-when]

**Never hero-peek** — Keep trade spacing so no bot swings alone into a fight the rest can't punish.
WHY: a lone swing that dies "leaves the rest of the team with fewer options"; proper spacing is
close enough to trade, far enough not to feed one spray two kills. HOW: enforce a min/max teammate
distance before engaging, and forbid a solo push into an uncleared angle unless a trader is within
range. [Boosteria CS2 Retake Guide — https://boosteria.org/guides/cs2-retake-guide-2026-site-retake-strategy-teamplay]

**Bait, then re-peek** — Show a body to draw the enemy's peek, then punish the over-aggressor with a
second wave. WHY: drawing an opponent out of position converts their aggression into a trade on your
terms — "wave one makes contact, wave two punishes the response." HOW: use a jiggle/expendable
peeker to bait shots, then have a staggered second attacker re-peek the same angle a beat later to
clean up the committed enemy. [Boosteria CS2 Retake Guide — https://boosteria.org/guides/cs2-retake-guide-2026-site-retake-strategy-teamplay]

**Fake, then rotate** — Commit visible pressure to one flag to pull defenders, then swing fast to
the other. WHY: a convincing fake "draws the defenders away" and forces a mistake, opening the real
target before they recover. HOW: send a noisy sub-group to threaten flag A (pressure + shots to
commit enemy attention), then rotate the main strike squad to flag B on a timer before the defense
resets. [Fragster CS:GO Mirage Guide — https://www.fragster.com/csgo-mirage-a-comprehensive-guide-to-the-popular-map/]

**Retake, don't force** — When you lose a position, regroup and take it back with info and angles
instead of trickling in. WHY: "indecision is the worst outcome" — staggered solo re-entries feed
kills, while a coordinated retake from two lanes divides enemy attention. HOW: on losing the home
flag, hold the re-plan until enough bots are grouped, then enter from two directions at once —
"first regain structure, then regain control, then regain the site." [Boosteria CS2 Retake Guide —
https://boosteria.org/guides/cs2-retake-guide-2026-site-retake-strategy-teamplay]

**Isolate each angle on a retake** — Clear a contested zone one threat at a time by priority, not
all at once. WHY: you can't fight everything — "clear what you must fight, block what you don't need
to fight yet, and pressure what the attackers cannot abandon" (the flag/carrier). HOW: on a retake,
rank threats (immediate close angles, then the flag-denial line) and commit fire sequentially rather
than spreading attention across the whole area. [Boosteria CS2 Retake Guide — https://boosteria.org/guides/cs2-retake-guide-2026-site-retake-strategy-teamplay]

**Hold fights at range** — When you hold the advantage, fight from range and refuse tight chokes.
WHY: enemies are strongest up close and in a swarm, and "it is only when you carelessly push tight
chokepoints that you start losing" a won position. HOW: when ahead on numbers or holding the flag
lead, default defenders to long sightlines and deny corridor duels, forcing the enemy to cross open
ground into fire. [Dignitas Winning Anti-Ecos — https://dignitas.gg/articles/blogs/CSGO/12129/a-guide-to-winning-anti-ecos]

---

## §6 — The rock-paper-scissors (why you stay flexible)

Underlying §1 and §5 is a simple loop: every hard commitment loses to the right counter, so the
whole point of pre-briefed branches is to *not* be the one who committed first-and-visibly.

- **Push loses to Hold/Retake** — a committed aggressive push walks into a prepared crossfire and
  gets traded down; the holder wins by making them come. [eloking Man Advantage — https://eloking.com/glossary/csgo/man-advantage]
- **Hold loses to Map-control/Default** — a passive hold surrenders space and info; a patient
  default takes free control and picks it apart. [Dignitas Default Strategies — https://dignitas.gg/articles/blogs/CSGO/8453/default-strategies-in-csgo-on-t-side-why-how-and-when]
- **Stack loses to Spread/Flank** — bodies clumped on one side can't defend the other; the abandoned
  side is free tempo. [CS2Hype Mid-Round Adaptation — https://cs2hype.com/guides/mastering-cs2-mid-round-adaptation-how-to-react-and-adjust-for-victory]
- **Spread loses to a focused Sync-push** — a thin line gets locally out-numbered and picked; a
  coordinated wave beats scattered defenders one choke at a time. [QL CTF Guide — https://www.plusforward.net/multipage/?page=3&pid=835]

**Bot takeaway:** never fully reveal a hard commitment early. Run the non-committal default, read
which of {push, hold, stack, spread} the enemy has shown, and only then fire the branch that beats
it — exactly the §1 machinery.

---

## Sources

**IGL / shot-calling / contingencies (§1)**
- Boosteria — CS2 Communication Guide (calls, trades, mid-round plans): https://boosteria.org/guides/cs2-communication-guide-calls-trades-mid-round-plans
- csgo-guides — CS2 IGL Guide: https://csgo-guides.com/roles/igl
- csgo-guides — CS2 Communication Guide: https://csgo-guides.com/gameplay/communication
- Refrag — What Is A Default (CS2): https://refrag.gg/blog/what-is-a-default-cs2/
- Guild Order — Valorant Comms & Callouts: https://guildorder.com/games/valorant/guides/comms-and-callouts
- Alviran — Valorant IGL Communication Guide 2026: https://alviran.net/blog/valorant-igl-communication-guide-2026/
- Guild Order — OW2 Ult Economy & Fight Sequencing: https://guildorder.com/games/overwatch/guides/ult-economy-and-fight-sequencing
- Guild Order — OW2 Tank Shotcalling & Anchor Theory: https://guildorder.com/games/overwatch/guides/tank-shotcalling-and-anchor-theory
- TF2 Official Wiki — Medic (competitive): https://wiki.teamfortress.com/wiki/Medic_(competitive)

**CTF meta (§2)**
- QL CTF Guide (Positions), Plus Forward: https://www.plusforward.net/multipage/?page=3&pid=835
- TF2 Official Wiki — Community Capture the Flag strategy: https://wiki.teamfortress.com/wiki/Community_Capture_the_Flag_strategy
- ChocoLLama Quake CTF Strategy: https://www.geocities.ws/oldquaker/clanllama/strategy.html
- Steam — CTF Guide (5v5, Quake): https://steamcommunity.com/sharedfiles/filedetails/?id=3145278073
- Chimz — Proper Teamwork in CTF (Quake Champions): https://steamcommunity.com/sharedfiles/filedetails/?id=1633738299
- BoostRoom — Overwatch 2 Map Guide (push/control/hybrid): https://boostroom.com/blog/overwatch-2-map-guide-how-to-play-push-control-and-hybrid

**Attrition / man-advantage / tempo (§3)**
- CSStatLab — Trading Kills: https://www.csstatlab.com/academy/gameplay/trading-kills
- CSStatLab — Man Advantage Fundamentals: https://www.csstatlab.com/academy/gameplay/man-advantage-fundamentals
- CSStatLab — Playing the Clock: https://www.csstatlab.com/academy/gameplay/playing-the-clock
- csgo-guides — CS2 Trading & Refragging: https://csgo-guides.com/gameplay/trading
- eloking — Man Advantage (CS2 glossary): https://eloking.com/glossary/csgo/man-advantage
- Dignitas — Understanding Basic Teamwork (CSGO): https://dignitas.gg/articles/blogs/CSGO/9310/understanding-basic-teamwork-and-how-to-be-a-better-teammate
- Dignitas — Ultimate Economy and Regrouping (Overwatch): https://dignitas.gg/articles/blogs/overwatch/12958/ultimate-economy-and-regrouping-in-overwatch
- Blizzard Forums — Fall Back and Regroup: https://us.forums.blizzard.com/en/overwatch/t/fall-back-and-regroup/594659
- CharlieINTEL — OW2 Group Respawn explained: https://www.charlieintel.com/overwatch-2/overwatch-2-group-respawn-feature-explained-278856/
- r/OverwatchUniversity — Retreating, Respawns & Risk Management: https://www.reddit.com/r/OverwatchUniversity/comments/14wz42i/retreating_respawns_and_risk_management_how_to/

**Inversions vs real CQC (§4)**
- ALVIRAN — VALORANT Trading Guide 2026: https://alviran.net/blog/valorant-trading-guide-2026/
- TF2 Official Wiki — Community Capture the Flag strategy: https://wiki.teamfortress.com/wiki/Community_Capture_the_Flag_strategy
- note.com (fre_d_) — Overwatch focus/target-priority guide: https://note.com/fre_d_/n/na3c828ddc270?hl=en
- csgo-guides — CS2 Positioning Guide: https://csgo-guides.com/gameplay/positioning
- Boosteria — CS2 Peeking & Angle Advantage: https://boosteria.org/guides/cs2-peeking-angle-advantage-timing-pre-aim-off-angles
- Sam Reitich — Projectile Prediction Part 1: https://sreitich.github.io/projectile-prediction-1/
- Quake3World — Rail Gun Tips (area denial in CTF): https://www.quake3world.com/forum/viewtopic.php?t=23814
- Steam — Overwatch 2 Competitive Optimization (info/audio over killfeed): https://steamcommunity.com/sharedfiles/filedetails/?id=3561543472

**Adaptation / counter-strategy (§5, §6)**
- Dignitas — The Art of Anti-Stratting: https://dignitas.gg/articles/the-art-of-anti-stratting
- CS2Hype — Mastering CS2 Mid-Round Adaptation: https://cs2hype.com/guides/mastering-cs2-mid-round-adaptation-how-to-react-and-adjust-for-victory
- Boosteria — CS2 Retake Guide 2026: https://boosteria.org/guides/cs2-retake-guide-2026-site-retake-strategy-teamplay
- Dignitas — Default Strategies on T-Side (CS:GO): https://dignitas.gg/articles/blogs/CSGO/8453/default-strategies-in-csgo-on-t-side-why-how-and-when
- Dignitas — A Guide To Winning Anti-Ecos: https://dignitas.gg/articles/blogs/CSGO/12129/a-guide-to-winning-anti-ecos
- Counterwatch — Overwatch Team Composition Guide: https://www.counterwatch.gg/blog/overwatch-team-composition-guide-synergy-balance-and-win-rat-8b715608
- Fragster — CS:GO Mirage Guide (B-site fake): https://www.fragster.com/csgo-mirage-a-comprehensive-guide-to-the-popular-map/
