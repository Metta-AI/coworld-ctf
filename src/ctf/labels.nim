## Sprite-label vocabulary: the machine-readable CONTRACT between the engine
## (the producer, `global.nim`) and AI policies (the consumers, e.g.
## `players/baseline/`). A policy has no API into the sim — it reads the wire,
## finds sprite objects by their label string, and steers off their positions.
## So a label is not a debug tag: it is the observation schema, and renaming one
## is a breaking change to every policy in the league.
##
## The failure mode this module exists to prevent is SILENT. Labels are computed
## at render time and never serialized (flatty writes `SimServer` positionally,
## so replays carry no label bytes), nothing type-checks a label string, and
## `spriteObjectsWithLabel` returns an empty seq for a name that no longer
## exists. Rename `"med kit"` to `"medkit"` and every bot simply stops routing
## to kits — no crash, no failing assertion, no log line. Hoisting the strings
## to consts makes at least the producer/consumer halves share one definition,
## and `tests/test_label_contract.nim` guards the rest.
##
## **Contract labels live here; spectator CHROME deliberately does not.** The
## renderer emits far more labels than this file names — map bands, the replay
## scrubber and transport, the roster and score pips, interstitial text, hit
## flashes, muzzle blooms, tracer stages, splatters, damage pops, endzone glow,
## the cog rig's limbs. No policy reads any of them; they exist for the
## inspector and for sprite dedup. Hoisting them here would imply a stability
## promise the engine does not owe — the broadcast view is free to re-cut its
## chrome any week. They are still covered by the golden manifest (a chrome
## rename shows up as a diff you can wave through), just not as API.
##
## **Renaming anything in this file is a four-surface change**, all in the same
## commit: this module, `tests/label_manifest.txt` (the golden vocabulary),
## `docs/RULES.md` (the published observation spec policy authors read), and
## `players/baseline/` (the reference consumer). The contract test fails until
## the manifest agrees; the other two surfaces are on you.
##
## **This module must keep ZERO imports** — not even `std/strutils`. The
## baseline bot imports it via `players/baseline/config.nims`, and the bot's
## Docker image ships no `data/` directory. Any import here risks dragging the
## renderer's cone (pixie / mummy / aseprite, all of which load assets at
## import or first use) into a binary that cannot satisfy it. If an addition
## seems to need an import, change the API instead.

const
  # ---------------------------------------------------------------------------
  # Flat labels: exact strings, matched with `==` by consumers.
  # ---------------------------------------------------------------------------

  LabelMedKit* = "med kit"
    ## Center-line health pickup, fog-gated by map position.
  LabelShield* = "shield"
    ## Endzone armor pickup on the floor, fog-gated by map position.
  LabelShieldCarried* = "shield carried"
    ## Marker floating over a shield carrier you can see.
  LabelSprayCan* = "spray can"
    ## Side-column weapon pickup (the 0.7.x rename of the plasma arc).
  LabelSprayCanCarried* = "spray can carried"
    ## Marker floating over a spray-can carrier you can see.
  LabelSprayPaintPuff* = "spray paint puff"
    ## One mist puff of a firing spray cone; a burst emits a run of them.
  LabelGrenade* = "grenade"
    ## Corner paint-bomb pickup on the floor, fog-gated by map position.
  LabelGrenadeAir* = "grenade air"
    ## A grenade in flight. It travels OVER walls, so an airborne orb is a
    ## threat even with no line of sight to the thrower.
  LabelGrenadeCarried* = "grenade carried"
    ## Marker floating over a grenade carrier you can see.
  LabelGrenadeSound* = "grenade sound"
    ## Jittered ring for a landing you could NOT see: audio-only intel.
  LabelThrowTarget* = "throw target"
    ## Projected landing ring of a charging lob. PLAYER-VIEW ONLY — the
    ## broadcast suppresses it, so a board-stream sweep never sees this label.
  LabelBlastStagePrefix* = "blast stage "
    ## Grenade landing splat, suffixed with its animation stage.
  LabelShotImpact* = "shot impact"
    ## Jittered ring near where a shot landed. The only trace a shot leaves in
    ## a player observation — firing itself is silent.
  LabelFireIcon* = "fire icon"
    ## Bottom-left HUD trigger-ready light. Its PRESENCE is the ready signal:
    ## on cooldown the HUD object switches to LabelFireIconCooldown, so a
    ## policy gates firing on `spriteObjectsWithLabel(LabelFireIcon).len > 0`.
  LabelFireIconCooldown* = "fire icon cooldown"
    ## The dimmed twin of LabelFireIcon, shown while the gun is recovering.
  LabelWalkabilityMap* = "walkability map"
    ## The invisible full-arena navigation mask: an RGBA sprite whose alpha is
    ## the walkable bit per map pixel. Always unscaled 1x, whatever the render
    ## scale — a policy decodes its pixels, it never reads its position.

  # ---------------------------------------------------------------------------
  # Prefixes: consumers match these with `startsWith`, because the tail
  # interpolates (a color, a side, a name, a count, free text).
  # ---------------------------------------------------------------------------

  LabelPrefixPlayer* = "player "
    ## A LIVING player: `player <color> <side>`. The board stream also puts
    ## this prefix on the cog rig's HEAD segment as bare `player <color>` (the
    ## aim-facing piece a scanner reads as the actor), so match by prefix and
    ## never assume a side token is present.
  LabelPrefixSelf* = "self "
    ## Your own avatar, `self <color> <side>`, drawn only while alive — so its
    ## absence is how a policy learns it is dead.
  LabelPrefixCorpse* = "corpse "
    ## A body, `corpse <color> <side>`. Deliberately NOT the player prefix so a
    ## scanner never counts a corpse as a live threat.
  LabelPrefixSelectedPlayer* = "selected player "
    ## Spectator-highlighted player, `selected player <color> <side>`. Emitted
    ## only on the board stream.
  LabelPrefixHp* = "hp "
    ## Overhead health bar, `hp <lit>/<total>`. A distinct object centered on
    ## its player and fog-gated with them: attach it by proximity.
  LabelPrefixLives* = "lives "
    ## Own top-right HUD text, `lives <hp>hp x<lives>`. Reads PAST the base hp
    ## cap — a shield carrier shows 6hp — which is how a policy detects its own
    ## shield without seeing the carry marker.
  LabelPrefixWeapon* = "weapon "
    ## Own weapon readout, `weapon <token>`. Authoritative for your own hands;
    ## inferring your weapon from floating markers gets it wrong under fog.
  LabelPrefixIdentity* = "identity "
    ## Per-player badge, `identity <color> <name>[ shield][ nade] <weapon>`.
    ## See `labelIdentity` for the ordering invariant. Scan by PREFIX only: the
    ## tail changes every time the wearer picks something up.
  LabelPrefixCogGun* = "cog gun "
    ## The held paintball marker, `cog gun <color>` (board stream only).
  LabelPrefixCogSprayCan* = "cog spray can "
    ## The held spray can, `cog spray can <color>`, which REPLACES the gun
    ## sprite while one is carried — so the silhouette shows the live weapon.
  LabelPrefixGameParams* = "game teams "
    ## The episode-parameter marker, `game teams <count> map <width>x<height>`:
    ## an invisible 1x1 object in the init snapshot stating the match setup
    ## outright — how many teams share the arena (2 or 4) and the exact map
    ## size in map pixels. Before it existed a policy had to INFER both: the
    ## team count from counting room markers or pedestals, the map size from
    ## the walkability sprite's dimensions. Those channels still work; this
    ## label is the stated-value contract for them.

  # ---------------------------------------------------------------------------
  # Tokens that fill the interpolated slots above.
  # ---------------------------------------------------------------------------

  LabelSideRight* = "right"
    ## The coarse facing an aim angle falls into; see `labelPlayer`.
  LabelSideLeft* = "left"
  LabelWeaponGun* = "gun"
    ## Default paintball marker; see `labelWeapon` / `labelIdentity`.
  LabelWeaponSpray* = "spray"
    ## Spray can. (0.7.x renamed the plasma arc, whose token was "arc"; the
    ## internal `hasPlasmaArc` field kept its name, the wire token did not.)
  LabelTokenShield* = "shield"
    ## Optional identity-badge suffix: the wearer carries a shield.
  LabelTokenNade* = "nade"
    ## Optional identity-badge suffix: the wearer carries a grenade.

const LabelHpBarSegments* = 3
  ## The overhead health bar's FIXED segment count — the denominator of every
  ## `hp <lit>/<total>` label, and the single place that number is allowed to
  ## live. Producer and consumer must agree on it exactly (an exact-match scan
  ## for "hp 2/3" finds nothing in a world that emits "hp 2/4"), so neither
  ## side gets to spell it itself: both go through `labelHp`.
  ##
  ## It is NOT the hit-point config, and the distinction is load-bearing rather
  ## than pedantic. The bar always draws three thirds whatever `hitPoints` is
  ## set to — a 99-hp game would otherwise paint a ~296px ribbon over a 16px
  ## sprite — so the engine maps `hp + shieldHp` onto thirds (ceil, floor of
  ## one lit segment for anyone alive) and the NUMERATOR is that lit-segment
  ## count, not a hit-point count. Today `hitPoints` also defaults to 3, which
  ## makes the two quantities numerically identical and makes it look like the
  ## label reports hit points. It does not. A retune of `hitPoints` alone must
  ## leave this constant — and every emitted hp label — untouched; only a
  ## redesign of the BAR moves it.
  ##
  ## The reference policy currently builds its scan denominator from its own
  ## `MaxHp = 3` (players/baseline/baseline.nim), i.e. from the hit-point
  ## coincidence rather than from the bar. That is the exact drift this
  ## constant closes, and it stays open until the bot calls `labelHp`;
  ## tests/test_label_contract.nim asserts the two have not diverged yet.

proc labelPlayer*(color, side: string): string =
  ## A living player's sprite label, `player <color> <side>`.
  LabelPrefixPlayer & color & " " & side

proc labelCorpse*(color, side: string): string =
  ## A body's sprite label, `corpse <color> <side>`.
  LabelPrefixCorpse & color & " " & side

proc labelSelf*(color, side: string): string =
  ## Your own avatar's sprite label, `self <color> <side>`.
  LabelPrefixSelf & color & " " & side

proc labelSelectedPlayer*(color, side: string): string =
  ## The spectator-highlighted variant, `selected player <color> <side>`.
  LabelPrefixSelectedPlayer & color & " " & side

proc labelFlag*(color: string): string =
  ## The CARRIED objective banner, `<color> flag`, centered exactly on its
  ## carrier and fogged with them. In-sim prose calls it a heart; the wire
  ## label stayed `flag` so label-scanning policies did not break.
  color & " flag"

proc labelFlagPlanted*(color: string): string =
  ## The PEDESTAL objective banner, `<color> flag planted`. Your own pedestal
  ## is never fogged, so an absent own-planted flag means it has been stolen.
  color & " flag planted"

proc labelHp*(lit: int): string =
  ## An overhead health bar, `hp <lit>/<LabelHpBarSegments>`, where `lit` is the
  ## number of LIT bar segments (see LabelHpBarSegments for why that is not a
  ## hit-point count).
  ##
  ## Takes the numerator only, deliberately. The denominator was the live drift
  ## risk in this vocabulary: the engine spelled it `HpBarSegments` and the
  ## reference policy spelled it `MaxHp`, two independent constants that must be
  ## equal for an exact-match scan to hit and that nothing compared. Accepting a
  ## `total` parameter would preserve exactly that — two callers, two beliefs,
  ## still no check — so the total is not a parameter at all.
  LabelPrefixHp & $lit & "/" & $LabelHpBarSegments

proc labelGameParams*(teams, mapWidth, mapHeight: int): string =
  ## The episode-parameter marker label,
  ## `game teams <count> map <width>x<height>`. A consumer matches
  ## LabelPrefixGameParams and splits the tail on spaces into exactly
  ## `["<count>", "map", "<width>x<height>"]` — the `map` token is fixed, and
  ## the size splits once more on the `x`.
  LabelPrefixGameParams & $teams & " map " & $mapWidth & "x" & $mapHeight

proc labelWeapon*(token: string): string =
  ## The own-weapon HUD label, `weapon <token>` — LabelWeaponGun or
  ## LabelWeaponSpray.
  LabelPrefixWeapon & token

proc labelCogWeapon*(color: string; spray: bool): string =
  ## The held-weapon sprite label on the board rig: `cog spray can <color>`
  ## when a spray can is carried, `cog gun <color>` otherwise. A cog holds
  ## exactly one thing, so these two are mutually exclusive per player.
  (if spray: LabelPrefixCogSprayCan else: LabelPrefixCogGun) & color

proc labelShoutPrefix*(color: string): string =
  ## The prefix a listener matches to attribute a shout to a team:
  ## `<color> shout `. Own-team and enemy shouts differ only by this prefix.
  color & " shout "

proc labelShout*(color, name, text: string): string =
  ## A speech bubble, `<color> shout <name>: <text>`, where `<name>` is the
  ## shouter's anonymous Greek slot letter (alpha..theta) — the same identity
  ## `labelIdentity` uses, NOT the shouter's connection address. Every player in
  ## earshot reads this label, so the address would broadcast the connecting
  ## policy's own name to its rivals; see `shoutIdentityName`.
  ##
  ## The tail is arbitrary player-authored text, so consumers split on `": "`
  ## and treat everything after it as payload — never exact-match a whole shout
  ## label. A slot letter can never contain `": "`, so the FIRST separator is
  ## always the real one; shipped consumers (`players/baseline/`, and the league
  ## champions built from it) split on the last, which differs only for a payload
  ## that contains a `": "` of its own.
  labelShoutPrefix(color) & name & ": " & text

proc labelIdentity*(
  color, name: string;
  shield, nade: bool;
  weapon: string
): string =
  ## A player's identity badge: `identity <color> <name>[ shield][ nade]
  ## <weapon>`, where `<name>` is the Greek slot letter (alpha..theta).
  ##
  ## ORDERING INVARIANT, stated here so it lives in exactly one place: the
  ## optional loadout flags come first, in a FIXED order (shield before nade),
  ## and the WEAPON TOKEN IS ALWAYS LAST AND ALWAYS PRESENT. Always-present
  ## matters more than the order: if the weapon token were omitted for the
  ## default gun, an observer would have to infer "gun" from ABSENCE — and
  ## absence is also what a truncated, stale, or fog-dropped badge looks like.
  ## An explicit terminal token makes the badge self-describing, which is why
  ## a consumer may read the weapon as the substring after the final space.
  result = LabelPrefixIdentity & color & " " & name
  if shield:
    result.add " " & LabelTokenShield
  if nade:
    result.add " " & LabelTokenNade
  result.add " " & weapon

const PolicyScannedLabels* = [
  ## Every label the reference policy (`players/baseline/baseline.nim`) passes
  ## to `spriteObjectsWithLabel`, i.e. matches EXACTLY. The contract test
  ## asserts each one is actually emitted somewhere in a full-feature frame,
  ## because an exact-match scan for a label the engine no longer emits fails
  ## in the quietest possible way: an empty seq, forever, with nothing else
  ## breaking.
  ##
  ## KNOWN GAP — this list is hand-maintained. Nothing forces a NEW
  ## `spriteObjectsWithLabel` call in the bot to be registered here, so the
  ## guard only covers labels somebody remembered to add. It catches the
  ## engine-side half of a rename (producer drops a label the policy still
  ## wants), not the consumer-side half (policy invents a label the producer
  ## never had). Prefix-scanned families (`lives `, `identity `,
  ## `<color> shout `) cannot appear here at all — their tails interpolate —
  ## and are covered instead by the vocabulary diff against the manifest.
  LabelFireIcon,
  LabelWalkabilityMap,
  LabelMedKit,
  LabelShield,
  LabelShieldCarried,
  LabelSprayCan,
  LabelSprayCanCarried,
  LabelGrenade,
  LabelGrenadeAir,
  LabelGrenadeCarried,
  LabelThrowTarget,
  labelFlag("red"),
  labelFlag("blue"),
  labelFlagPlanted("red"),
  labelFlagPlanted("blue"),
  labelPlayer("red", LabelSideRight),
  labelPlayer("red", LabelSideLeft),
  labelPlayer("blue", LabelSideRight),
  labelPlayer("blue", LabelSideLeft),
  labelSelf("red", LabelSideRight),
  labelSelf("red", LabelSideLeft),
  labelSelf("blue", LabelSideRight),
  labelSelf("blue", LabelSideLeft),
  labelCorpse("red", LabelSideRight),
  labelCorpse("red", LabelSideLeft),
  labelCorpse("blue", LabelSideRight),
  labelCorpse("blue", LabelSideLeft),
  labelHp(1),
  labelHp(2),
  labelHp(3),
  labelWeapon(LabelWeaponGun),
  labelWeapon(LabelWeaponSpray)
]
