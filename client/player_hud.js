/* ============================================================================
   client/player_hud.js — Paintbot player HUD overlay  (lane: hud)
   ============================================================================

   OWNERSHIP: this file is wholly owned by the `hud` lane. Nothing else in the
   client tree should need to change for this to work — see ATTACH below.

   WHAT THIS IS
   A self-contained overlay that answers, at a glance, the questions Maxwell
   said the human client leaves unanswered: did I just get a kill, who/what
   killed me, is my gun ready, where am I on the map, who nearby is a person
   vs a policy, what's the score, and (mid-fight) how much health do I have
   left. It draws to its own DOM layer stacked above the game canvas and never
   intercepts pointer events except on its one clickable toggle tag.

   ATTACH (the "small, documented init hook")
   Add ONE line to the host page, after its own inline <script> block:

       <script src="player_hud.js"></script>

   That's it — no call required. On load this module:
     1. Mounts its own overlay DOM (`#phud-root`), independent of any host ID.
     2. Reads the CURRENT MOUSE POSITION itself (own listener, screen space).
     3. Reads decoded wire state from exactly TWO host globals: `objects` and
        `sprites` (see WIRE DEPENDENCY below). Everything else it computes
        itself by scanning label text — the same technique the host's own
        findSelfAndAim() already uses, applied more broadly.
     4. Reads its own map viewport/pan/zoom from the host canvas's *rendered*
        CSS transform (getComputedStyle), not from any host JS variable — so
        it stays correct even if the host's camera implementation changes,
        as long as it keeps using a CSS transform on #c (a stable pattern).

   For a tighter, push-based integration later (optional, not required today):
       window.PaintbotHUD.update(stateObject)   // see CONTRACT below
   accepts an explicit per-frame state object shaped like the one this module
   builds internally, if the host ever wants to hand data over directly
   instead of being scanned. Both paths render through the same code.

   WIRE DEPENDENCY (the one real coupling — documented, not hidden)
   `objects` (Map<id, {id,x,y,z,layer,spriteId,dispX,dispY}>) and `sprites`
   (Map<spriteId, {width,height,pixels,label}>) are top-level `let` bindings
   declared in player_client.html's inline <script> (as of commit 7a052635,
   see line ~100). Because classic (non-module) <script> tags in one document
   share a single global lexical environment for top-level let/const, a
   *later* classic script — this one — can read those identifiers directly,
   the same way two <script> blocks in one page always could. This module
   depends on NOTHING ELSE from that file: no business-logic variable
   (selfPos, lmb, estAim, isDead, tickCount, the websocket, ...) is read here.
   Every `typeof` check below is a real safety net, not decoration: if either
   binding is ever renamed or the file is restructured into a module, this
   degrades to honest "no data" empty states instead of throwing.

   THE WIRE LABELS THIS MODULE SCANS (all documented in src/ctf/labels.nim —
   quoted here so the parsing logic has a single citation trail):
     "self <color> <side>"                    — LabelPrefixSelf
     "player <color> <side>"                  — LabelPrefixPlayer (alive, other)
     "corpse <color> <side>"                  — LabelPrefixCorpse (dead)
     "own aim <brads>"                        — LabelPrefixOwnAim
     "lives <hp>hp x<lives>"                  — LabelPrefixLives (OWN hp+lives)
     "kd <kills>/<deaths>"                    — LabelPrefixKd (OWN, human wire only;
                                                landed 50a13efc, absent on engines
                                                before it — parsed by prefix, "—"
                                                until it actually arrives)
     "hp <lit>/<total>[ shield <n>]"          — LabelPrefixHp (overhead, by proximity)
     "identity <color> <greekletter>[ shield][ nade] <weapon>" — LabelPrefixIdentity
     "roster <team> <name> <lives> <kills>/<deaths>" — LabelPrefixRoster
                                                (8ad1c420): ONE marker per roster
                                                seat on EVERY player stream, human
                                                wire only (`not spritesOff`), all
                                                modes. This is what fills the Tab
                                                table on the live player page.
                                                <team> = teamText (single word, all
                                                16 BR colors); <name> = the same
                                                anonymous per-team slot identity
                                                the identity/shout labels use
                                                (alpha..theta, ranked within team,
                                                wraps) — NEVER a connection
                                                address; rendered as-is. Every
                                                field a fixed token; no greedy
                                                matching needed. Absent on engines
                                                before 8ad1c420 — rows then fall
                                                back to "score " rows / the HTTP
                                                roster, same as ever.
     "team score <NAME> <kills>/<deaths>"     — addTeamScoreboard, per team, always sent
     "score <name> <lives> <kills>/<deaths> color <n>" — addScoreboard, per player
                                                (50a13efc). OLDER ENGINES: the row is
                                                "score <name> <lives> color <n>" and is
                                                suppressed entirely above 4 teams; BOTH
                                                shapes are parsed (kills/deaths null on
                                                the old one) so this HUD works against
                                                the deployed engine AND the next swap.
                                                ROUTING (server.nim): only /client/global
                                                builds (board + POV) run addScoreboard —
                                                the live seated/takeover player stream
                                                (buildSpriteProtocolPlayerUpdates) never
                                                carries these rows, so on the live player
                                                page the Tab table populates only via
                                                fallbacks/push; rows appear wherever the
                                                host Maps actually carry them.
     "fire icon" / "fire icon cooldown"       — LabelFireIcon / LabelFireIconCooldown

   THE CONTRACT — full combat-state family, defined now even where unpopulated
   (per Maxwell's ask: specify the engine emit work once, not three times).
   window.PaintbotHUD.update() accepts, and the internal scanner builds, this
   shape. Every field that has NO current wire source is called out below and
   renders an honest placeholder ("—" / hidden), never a fabricated value.

     {
       wireOk: bool,              // objects/sprites Maps reachable at all
       seated: bool,              // a "self " labeled cog exists this tick
       dead: bool,                // was seated, self label now absent
       selfTeam: string|null,     // color word off the self label

       fire: { ready: bool|null },              // RESOLVED — "fire icon(*)" labels

       health: {                                 // RESOLVED — "lives "/"hp " labels
         hp: number|null, maxHp: number|null, shield: number|null, lives: number|null,
         source: 'hp-label'|'lives-label'|null   // which label supplied the split
       },

       combat: {                                 // the family Maxwell asked to reserve
         kills: number|null,      // RESOLVED — own "kd <k>/<d>" label (LabelPrefixKd,
                                  //   50a13efc); null (renders "—") until the label
                                  //   actually arrives, so older engines stay honest
         deaths: number|null,     // RESOLVED — same label, same tolerance
         score: null,             // UNRESOLVED — Glory/XP not deployed to the field yet
         xp: null,                // UNRESOLVED — ditto
         level: null,             // UNRESOLVED — ditto
         rank: null,              // UNRESOLVED — one of GLORY_RANKS below, once shipped
         buffs: []                // UNRESOLVED — always empty until the wire carries any
       },

       respawn: { ticksRemaining: null },        // UNRESOLVED — CTF only; state exists server-side
                                                   // but is never sent (HUD_SPEC.md). Render surface
                                                   // is fix-client3's center-screen transient, not
                                                   // this module — reserved here for spec completeness.

       map: { w: number, h: number, viewport: {x,y,w,h}|null },  // RESOLVED (own canvas)

       zone: { current: {x0,y0,x1,y1}, next: {x0,y0,x1,y1}, shrinking: bool } | null,
                                                   // RESOLVED — BR shrink ring, "zone "/"zonenext "
                                                   // labels, world knowledge, never fog-gated. No
                                                   // tick-countdown ships with it (see `shrinking`,
                                                   // a derived qualitative read, never a fake number).

       cogs: [ { x, y, color, side, alive, self, human: bool|null } ],   // RESOLVED (dots);
                                                                          // human RESOLVED only
                                                                          // when roster + the
                                                                          // identity-label greek
                                                                          // -letter->slot join
                                                                          // both land (see below)

       variant: 'ctf' | 'br' | 'unknown',        // RESOLVED from live team count on the wire
       teamScores: [ { team, kills, deaths } ],   // RESOLVED — always sent regardless of team count
       teamsAlive: number|null,                   // RESOLVED (Swap#11 item 6) — "teamsalive "
                                                   // label, sim.teamsAliveCount(); null pre-Swap#11
                                                   // engine, render() falls back to teamAliveChips'
                                                   // per-seat-deaths heuristic in that case only
       playerRows: [ { name, team, lives: number|null, kills: number|null,
                        deaths: number|null, human: bool|null, self: bool } ],
                                                   // source priority: "roster " markers (the live
                                                   // player stream's own full roster, 8ad1c420) >
                                                   // "score " rows (global-backed hosts; old-shape
                                                   // rows keep kills/deaths null) > the HTTP roster
                                                   // fallback (names only). On the roster-marker
                                                   // path `name` is the anonymous slot identity and
                                                   // `human` stays null (nothing joins an anonymous
                                                   // row to the HTTP roster's real names — honest
                                                   // "—", not a guess).

       roster: { resolved: bool, url: string }
     }

   KNOWN GAPS (told to the orchestrator; repeated here so the code and the
   report can never drift apart):
     - combat.kills / combat.deaths: RESOLVED (was the top gap here). The
       engine now emits the own-stat "kd <kills>/<deaths>" label per tick on
       the human player stream (LabelPrefixKd, 50a13efc) — real attribution
       (Player.kills/deaths via roster.nim recordKill/recordDeath), NOT the
       damage-pop proximity guess this file always refused to dress up as a
       counter. Read by prefix in scanWire(); the tick-emphasis animation and
       the scoreboard K/D columns were already built against the reserved
       field, so the label's arrival lights them with no layout change.
       Against a pre-50a13efc engine the label never arrives and the rail
       stays at "—" — tolerance, not fabrication.
     - combat.score/xp/level/rank/buffs: Glory is not deployed to the field
       yet. Fields are reserved. Swap#11 item 3: SCORE/RANK are no longer
       rendered as a permanent "—" placeholder tile — a tile that can only
       ever read "—" isn't an honest placeholder, it's dead rail weight —
       the two tiles (#phud-sc-tile/#phud-rk-tile) are structurally hidden
       (display:none) until the wire actually carries a value, then reappear
       with no code change. buffs already worked this way (phud-buffwrap
       hidden when the list is empty); score/rank now follow the same idiom.
     - BR (>4 teams) playerRows: RESOLVED end to end. 50a13efc lifted the
       addScoreboard >4-team suppression ("score " rows at every team count,
       kills/deaths included — /client/global builds only), and 8ad1c420
       closed the routing gap this file's earlier revision documented: the
       live player stream now carries its own "roster " marker per seat, so
       the Tab table fills from real wire data on the live player page in
       every mode. What remains by design:
       (a) LEGIBILITY — BR is up to 32 rows; the Tab table caps at
       BR_MAX_ROWS sorted by kills (own row always kept visible, an
       explicit "+N more" line for the rest) instead of rendering a wall —
       see renderScoreboard.
       (b) SELF on the roster path — roster names are anonymous; the own
       row resolves via selfTeam when unambiguous (one seat on my team),
       else via the identity badge nearest the self cog; else no row is
       highlighted (never a guess).
       teamsAlive: RESOLVED (Swap#11 item 6) — real feed via the
       "teamsalive " label (sim.teamsAliveCount()), not end-card-only
       anymore. Placement (sim.brPlacements()) stays END-CARD ONLY; its always-empty
       column is gone from the BR table. So is the numeric lives column:
       wire lives = respawns remaining, which reads 0 for every LIVING
       one-life player — BR renders an ALIVE/SPLAT status column derived
       from the row's own deaths count instead (see renderScoreboard).
     - zone (BR shrink ring): RESOLVED TODAY, zero engine work — "zone "/
       "zonenext " labels are world knowledge on the player stream right now
       (labels.nim:238-259, global.nim:8692-8693). No tick-countdown value
       ships with them, so this module derives "shrinking" vs "hold"
       qualitatively (current rect != next rect) rather than inventing a
       seconds-remaining number.
     - cogs[].human: requires BOTH the roster join (person: true/false per
       slot) AND matching an "identity" label's Greek slot-letter
       (alpha=0, beta=1, ...) to that slot index — an assumption (documented
       at GREEK_TO_SLOT below) that has not been checked against a live
       roster response in this environment. Falls back to `null` (unknown)
       whenever either half of the join is missing, which is most of the
       time until a real /api/field shape is confirmed.

   ============================================================================ */
(function () {
  'use strict';
  if (window.PaintbotHUD) return; // idempotent: never double-mount

  // ---------------------------------------------------------------------
  // Small utilities
  // ---------------------------------------------------------------------
  function clamp(v, lo, hi) { return v < lo ? lo : v > hi ? hi : v; }
  function el(tag, cls) { const e = document.createElement(tag); if (cls) e.className = cls; return e; }
  function fmtDash(v, suffix) { return (v === null || v === undefined) ? '—' : (v + (suffix || '')); }
  // Fills in every documented CONTRACT field a caller's partial state didn't
  // set — found necessary by testing, not by inspection: window.PaintbotHUD
  // .update()'s Object.assign is a SHALLOW merge, so a caller passing e.g.
  // `combat: {kills, deaths}` (the natural, minimal thing to write) silently
  // REPLACES the whole combat object and drops `buffs`, which render() then
  // reads unguarded and throws. buildState()'s own output is already
  // complete, so this is a no-op on the auto-scan path and a safety net on
  // the push-API path — one normalization site instead of an `|| []` at
  // every call site in render().
  function normalizeState(s) {
    s = s || {};
    return {
      wireOk: !!s.wireOk, seated: !!s.seated, dead: !!s.dead, selfTeam: s.selfTeam || null,
      fire: Object.assign({ ready: null }, s.fire),
      health: Object.assign({ hp: null, maxHp: null, shield: null, lives: null }, s.health),
      combat: Object.assign({ kills: null, deaths: null, score: null, xp: null, level: null, rank: null, buffs: [] }, s.combat),
      respawn: Object.assign({ ticksRemaining: null }, s.respawn),
      map: Object.assign({ w: 0, h: 0, viewport: null }, s.map),
      zone: s.zone || null,
      cogs: s.cogs || [],
      variant: s.variant || 'unknown',
      teamScores: s.teamScores || [],
      teamsAlive: s.teamsAlive != null ? s.teamsAlive : null,
      playerRows: s.playerRows || [],
      roster: Object.assign({ resolved: false, url: roster.url }, s.roster),
    };
  }

  // ---------------------------------------------------------------------
  // Wire access — the ONE coupling, guarded every time it's used.
  // ---------------------------------------------------------------------
  function wireObjects() {
    try { return (typeof objects !== 'undefined' && objects instanceof Map) ? objects : null; }
    catch (e) { return null; }
  }
  function wireSprites() {
    try { return (typeof sprites !== 'undefined' && sprites instanceof Map) ? sprites : null; }
    catch (e) { return null; }
  }

  // ---------------------------------------------------------------------
  // Label parsers — each cites the exact wire format it decodes.
  // ---------------------------------------------------------------------
  // "lives <hp>hp x<lives>" — own top-right HUD text (labels.nim LabelPrefixLives)
  function parseLivesLabel(label) {
    const m = /^lives (\d+)hp x(\d+)$/.exec(label);
    return m ? { hp: +m[1], lives: +m[2] } : null;
  }
  // "hp <lit>/<total>[ shield <n>]" — overhead bar, attach by proximity (LabelPrefixHp)
  function parseHpLabel(label) {
    const rest = label.slice(3);
    const bits = rest.split(' shield ');
    const hpTot = bits[0].split('/');
    const lit = +hpTot[0], total = +hpTot[1];
    if (!isFinite(lit) || !isFinite(total)) return null;
    return { lit, total, shield: bits[1] !== undefined ? +bits[1] : 0 };
  }
  // "team score <NAME> <kills>/<deaths>" — always sent on the player stream (addTeamScoreboard)
  function parseTeamScoreLabel(label) {
    const rest = label.slice(11); // 'team score '.length
    const m = /^(\S+) (\d+)\/(\d+)$/.exec(rest);
    return m ? { team: m[1], kills: +m[2], deaths: +m[3] } : null;
  }
  // "kd <kills>/<deaths>" — OWN persistent kill/death readout, human wire only
  // (labels.nim LabelPrefixKd, landed 50a13efc). Absent on older engines; the
  // caller keeps null (renders "—") rather than inventing a zero.
  function parseKdLabel(label) {
    const m = /^kd (\d+)\/(\d+)$/.exec(label);
    return m ? { kills: +m[1], deaths: +m[2] } : null;
  }
  // "teamsalive <n>" — match-wide count of teams still in it, human wire
  // only (labels.nim LabelPrefixTeamsAlive, Swap#11 item 6). Absent on
  // older engines; the caller keeps null (teamAliveChips' heuristic takes
  // over) rather than inventing a number.
  function parseTeamsAliveLabel(label) {
    const m = /^teamsalive (\d+)$/.exec(label);
    return m ? +m[1] : null;
  }
  // "roster <team> <name> <lives> <kills>/<deaths>" — one marker per roster
  // seat on the live player stream (labels.nim LabelPrefixRoster, 8ad1c420).
  // Every field is a single fixed token by contract (the emitting commit
  // rebuilt the shape around that after test_identity_privacy.nim caught a
  // connection address in the first draft) — so no greedy matching here.
  function parseRosterLabel(label) {
    const m = /^roster (\S+) (\S+) (\d+) (\d+)\/(\d+)$/.exec(label);
    return m ? { team: m[1], name: m[2], lives: +m[3], kills: +m[4], deaths: +m[5] } : null;
  }
  // Per-player scoreboard row (addScoreboard), BOTH deployed shapes:
  //   NEW (50a13efc):  "score <name> <lives> <kills>/<deaths> color <n>"
  //   OLD (deployed):  "score <name> <lives> color <n>"
  // New shape is tried first; a new-shape row can never satisfy the old regex
  // (the "/" blocks `(\d+) color`), and an old-shape row lacks the k/d token,
  // so the two are mutually exclusive — no misparse window during the engine
  // swap. kills/deaths come back null on the old shape (renders "—"), never 0.
  // Name may itself contain spaces; greedy backtracking on `.+` correctly finds
  // the trailing tokens regardless (mirrors how the label is built).
  function parseScoreLabel(label) {
    let m = /^score (.+) (\d+) (\d+)\/(\d+) color (\d+)$/.exec(label);
    if (m) return { name: m[1], lives: +m[2], kills: +m[3], deaths: +m[4] };
    m = /^score (.+) (\d+) color (\d+)$/.exec(label);
    return m ? { name: m[1], lives: +m[2], kills: null, deaths: null } : null;
  }
  // "identity <color> <greekletter>[ shield][ nade] <weapon>" (labels.nim labelIdentity)
  // <name> here is a per-slot GREEK LETTER (alpha..theta), not the player's display
  // name — see GREEK_TO_SLOT below for how this becomes a roster join key.
  function parseIdentityLabel(label) {
    const toks = label.slice(9).split(' '); // 'identity '.length
    if (toks.length < 3) return null;
    return { color: toks[0], greek: toks[1], weapon: toks[toks.length - 1] };
  }
  const GREEK_TO_SLOT = { alpha: 0, beta: 1, gamma: 2, delta: 3, epsilon: 4, zeta: 5, eta: 6, theta: 7 };
  // "zone <x0>,<y0> <x1>,<y1>" / "zonenext <x0>,<y0> <x1>,<y1>" — BR shrink-zone
  // current/target rects, inclusive map pixels, WORLD KNOWLEDGE (never fog-gated),
  // labels.nim LabelPrefixZone/LabelPrefixZoneNext, emitted whenever the rect moves.
  // No tick-countdown value ships alongside these — only the two rects — so this
  // module derives a qualitative "shrinking vs holding" state, never a fabricated
  // numeric countdown (see the zone status text in render()).
  function parseZoneLabel(rest) {
    const m = /^(-?\d+),(-?\d+) (-?\d+),(-?\d+)$/.exec(rest);
    return m ? { x0: +m[1], y0: +m[2], x1: +m[3], y1: +m[4] } : null;
  }

  // ---------------------------------------------------------------------
  // Team color tokens — the 4 CTF words mirror player_client.html's
  // TEAM_TINT (own copy so this module has zero coupling to that file
  // beyond the wire Maps). The 12 BR-only words come from the engine's own
  // team palette (sim_types.nim teamColor indices into the client's 16-
  // color palette), lifted toward readable luminance where the raw palette
  // entry would vanish as text on the dark panel (black/umber/navy/plum) —
  // a display map keyed by the wire's team WORD, never an identity claim.
  // ---------------------------------------------------------------------
  const TEAM_COLOR = {
    red: '#e0523a', blue: '#3f7cc4', green: '#45a85e', yellow: '#ddc531',
    black: '#8d8d8d', silver: '#c2c3c7', ivory: '#fff1e8', pink: '#ff77a8',
    umber: '#8a6f5a', rust: '#ab5236', orange: '#ffa300', plum: '#a34a78',
    lime: '#00e436', navy: '#5a6fb4', azure: '#29adff', peach: '#ffccaa',
  };
  function teamColor(word) { return (word && TEAM_COLOR[word]) || '#b7b0a3'; }
  // Swap#12 item 6 (DUET+ORIENT): the minimap dot outline used to be a single
  // fixed dark stroke (rgba(10,8,5,.9)) regardless of the dot's own fill --
  // fine contrast for a light team color against the dark scrim, but for a
  // dark-ish fill (black's lifted-but-still-moderate #8d8d8d chief among
  // them) a dark ring on a dark fill against a dark scrim is three dark
  // things stacked, which is exactly the measured "black dot invisible"
  // failure. Pick the outline that contrasts with THIS dot's own fill —
  // guarantees the ring reads as a ring against both a dark scrim and a
  // light paint field, without touching the self-ring (still literal white,
  // unrelated to this — see the own-dot-white investigation note below).
  function minContrastOutline(hex) {
    const n = parseInt(hex.slice(1), 16);
    const r = (n >> 16) & 255, g = (n >> 8) & 255, b = n & 255;
    const luma = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
    return luma > 0.5 ? 'rgba(10,8,5,.9)' : 'rgba(255,255,255,.85)';
  }

  const GLORY_RANKS = ['PRIMER', 'DABBLER', 'SPLATTER', 'DRENCHER', 'ARTIST', 'MAESTRO'];

  // ---------------------------------------------------------------------
  // Roster join (/api/field) — contract field C. Shape UNCONFIRMED against a
  // live response; parsed defensively, several plausible shapes accepted.
  // Configurable so integration never requires editing this file:
  //   window.PaintbotHUDConfig = { rosterUrl: '...' }
  // ---------------------------------------------------------------------
  const roster = {
    url: (window.PaintbotHUDConfig && window.PaintbotHUDConfig.rosterUrl) || '/api/field',
    resolved: false,
    byName: new Map(),
    bySlot: new Map(),
    // -ROSTER_POLL_MS (not 0): a plain 0 sentinel meant the very first guard
    // check ("now - lastFetchAt < ROSTER_POLL_MS") compared a small
    // just-loaded `now` against 0 and came back true, SKIPPING the first
    // fetch for a full poll interval — every fresh seat sat at "unknown"
    // bot/human for 5s before ever asking, not just on a slow roster. Found
    // by testing, not inspection: the join looked correct reading the code,
    // wrong the moment a real clock ran it.
    lastFetchAt: -Infinity,
    failed: false,
  };
  const ROSTER_POLL_MS = 5000;
  function pollRoster(now) {
    if (now - roster.lastFetchAt < ROSTER_POLL_MS) return;
    roster.lastFetchAt = now;
    fetch(roster.url, { credentials: 'same-origin' })
      .then(function (r) { return r.ok ? r.json() : Promise.reject(r.status); })
      .then(function (data) {
        const rows = Array.isArray(data) ? data
          : (data.slots || data.players || data.roster || []);
        const byName = new Map(), bySlot = new Map();
        for (let i = 0; i < rows.length; i++) {
          const row = rows[i];
          if (!row) continue;
          const name = row.name || row.player_name || row.playerName || null;
          const slot = (row.slot != null) ? row.slot : (row.seat != null ? row.seat : null);
          const person = (typeof row.person === 'boolean') ? row.person
            : (typeof row.human === 'boolean') ? row.human : null;
          const entry = { name: name, slot: slot, team: row.team || null, person: person };
          if (name != null) byName.set(String(name).toLowerCase(), entry);
          if (slot != null) bySlot.set(slot, entry);
        }
        roster.byName = byName; roster.bySlot = bySlot;
        roster.resolved = rows.length > 0;
        roster.failed = false;
      })
      .catch(function () { roster.failed = true; /* stays honestly unresolved */ });
  }

  // My own identity: read straight off the page URL, independent of the
  // host script's connection-building logic (?slot=&name= are the params
  // player_client.html itself forwards onto the socket address).
  const myIdentity = (function () {
    try {
      const u = new URL(location.href);
      const slotStr = u.searchParams.get('slot');
      return {
        slot: slotStr !== null ? +slotStr : null,
        name: u.searchParams.get('name'),
      };
    } catch (e) { return { slot: null, name: null }; }
  })();

  // ---------------------------------------------------------------------
  // Wire scan: one pass over objects/sprites -> a raw parsed snapshot.
  // ---------------------------------------------------------------------
  function scanWire() {
    const objs = wireObjects(), sprs = wireSprites();
    const raw = {
      wireOk: !!(objs && sprs),
      self: null, selfTeam: null,
      fireReady: null,
      livesLabel: null,
      hpMarkers: [],       // {x,y,lit,total,shield}
      identityMarkers: [], // {x,y,color,greek,weapon}
      cogs: [],            // {x,y,color,side,alive,self}
      teamScoreRows: [],
      scoreRows: [],
      rosterRows: [], // "roster " markers — the live player stream's full roster (8ad1c420)
      zone: null, zoneNext: null,
      // Own kills/deaths off the "kd " label (the TODO this slot was reserved
      // for — landed 50a13efc). Stays null when the label never arrives
      // (pre-50a13efc engine), which renders as "—", never a fabricated 0.
      kdSelf: null,
      // Match-wide teams-alive count off the "teamsalive " label (Swap#11
      // item 6, labels.nim LabelPrefixTeamsAlive). Stays null against a
      // pre-Swap#11 engine (label never arrives) — teamAliveChips' own
      // per-seat-deaths heuristic is the fallback for that case, same
      // tolerance idiom as kdSelf above, never a fabricated number.
      teamsAlive: null,
    };
    if (!objs || !sprs) return raw;
    objs.forEach(function (o) {
      const sp = sprs.get(o.spriteId);
      if (!sp) return;
      const label = sp.label;
      if (!label) return;
      if (label === 'fire icon') { raw.fireReady = true; return; }
      if (label === 'fire icon cooldown') { raw.fireReady = false; return; }
      if (label.indexOf('self ') === 0) {
        const parts = label.split(' ');
        const cx = o.x + sp.width / 2, cy = o.y + sp.height / 2;
        raw.self = { x: cx, y: cy };
        raw.selfTeam = parts[1] || null;
        raw.cogs.push({ x: cx, y: cy, color: parts[1] || null, side: parts[2] || null, alive: true, self: true });
        return;
      }
      if (label.indexOf('player ') === 0) {
        const parts = label.split(' ');
        raw.cogs.push({
          x: o.x + sp.width / 2, y: o.y + sp.height / 2,
          color: parts[1] || null, side: parts[2] || null, alive: true, self: false,
        });
        return;
      }
      if (label.indexOf('corpse ') === 0) {
        const parts = label.split(' ');
        raw.cogs.push({
          x: o.x + sp.width / 2, y: o.y + sp.height / 2,
          color: parts[1] || null, side: parts[2] || null, alive: false, self: false,
        });
        return;
      }
      if (label.indexOf('lives ') === 0) { raw.livesLabel = parseLivesLabel(label); return; }
      if (label.indexOf('kd ') === 0) { raw.kdSelf = parseKdLabel(label); return; }
      if (label.indexOf('teamsalive ') === 0) { raw.teamsAlive = parseTeamsAliveLabel(label); return; }
      if (label.indexOf('hp ') === 0) {
        const hp = parseHpLabel(label);
        if (hp) raw.hpMarkers.push({ x: o.x, y: o.y, lit: hp.lit, total: hp.total, shield: hp.shield });
        return;
      }
      if (label.indexOf('identity ') === 0) {
        const idn = parseIdentityLabel(label);
        if (idn) raw.identityMarkers.push({ x: o.x, y: o.y, color: idn.color, greek: idn.greek, weapon: idn.weapon });
        return;
      }
      if (label.indexOf('team score ') === 0) {
        const ts = parseTeamScoreLabel(label);
        if (ts) raw.teamScoreRows.push(ts);
        return;
      }
      if (label.indexOf('roster ') === 0) {
        const rr = parseRosterLabel(label);
        if (rr) raw.rosterRows.push(rr);
        return;
      }
      if (label.indexOf('score ') === 0) {
        const sc = parseScoreLabel(label);
        if (sc) raw.scoreRows.push(sc); // {name, lives, kills, deaths} — k/d null on old-shape rows
        return;
      }
      if (label.indexOf('zone ') === 0) { raw.zone = parseZoneLabel(label.slice(5)); return; }
      if (label.indexOf('zonenext ') === 0) { raw.zoneNext = parseZoneLabel(label.slice(9)); return; }
    });
    return raw;
  }

  function nearest(list, x, y, maxDist) {
    let best = null, bestD = maxDist * maxDist;
    for (let i = 0; i < list.length; i++) {
      const it = list[i], dx = it.x - x, dy = it.y - y, d = dx * dx + dy * dy;
      if (d <= bestD) { bestD = d; best = it; }
    }
    return best;
  }

  // ---------------------------------------------------------------------
  // Camera readback: the *rendered* CSS transform of the host canvas, not
  // any host JS variable — robust to the host's camera implementation.
  // ---------------------------------------------------------------------
  function readCamera(canvasEl) {
    try {
      const t = getComputedStyle(canvasEl).transform;
      if (!t || t === 'none') return { tx: 0, ty: 0, scale: 1 };
      const m = new DOMMatrixReadOnly(t);
      return { tx: m.m41, ty: m.m42, scale: m.m11 || 1 };
    } catch (e) { return { tx: 0, ty: 0, scale: 1 }; }
  }

  // ---------------------------------------------------------------------
  // Build the full documented contract object from a raw wire scan.
  // ---------------------------------------------------------------------
  function buildState(raw, canvasEl) {
    const seated = !!raw.self;
    // Health: prefer the proximity-matched overhead "hp " marker (carries the
    // hp/shield split); fall back to the combined self "lives " number.
    let health = { hp: null, maxHp: null, shield: null, lives: null, source: null };
    if (seated) {
      const hpM = nearest(raw.hpMarkers, raw.self.x, raw.self.y, 40);
      if (hpM) {
        health.hp = hpM.lit; health.maxHp = hpM.total; health.shield = hpM.shield;
        health.source = 'hp-label';
      }
      if (raw.livesLabel) {
        health.lives = raw.livesLabel.lives;
        if (health.hp === null) { health.hp = raw.livesLabel.hp; health.source = 'lives-label'; }
      }
    }

    // Map + viewport box. Map dims used to be read straight off the host
    // canvas's OWN pixel buffer (canvasEl.width/height), on the assumption
    // that it always held the whole map at native resolution -- true before
    // the viewport-clip lane (client/player_client.html, 2026-08-31), which
    // shrank that buffer down to just the current camera window (+ margin)
    // so per-frame draw cost scales with the SCREEN, not the map. Prefer the
    // host's own `mapW`/`mapH` globals (the TRUE map size it already tracks
    // for this exact purpose, set from the viewport() wire packet -- same
    // cross-script-global pattern this module already relies on for
    // `objects`/`sprites`, see the file header). Falls back to the old
    // canvas-size read if those aren't defined for some reason (an older
    // host build without this lane) -- never a hard dependency either way.
    let map = { w: 0, h: 0, viewport: null };
    const trueMapW = (typeof mapW === 'number' && mapW > 1) ? mapW : (canvasEl ? canvasEl.width : 0);
    const trueMapH = (typeof mapH === 'number' && mapH > 1) ? mapH : (canvasEl ? canvasEl.height : 0);
    if (canvasEl && trueMapW > 1 && trueMapH > 1) {
      map.w = trueMapW; map.h = trueMapH;
      // readCamera() still reads the CSS transform, unchanged -- the
      // viewport-clip lane keeps that transform expressing the exact same
      // world-to-screen relationship it always did (it bakes the camera
      // window's own offset into the translate term precisely so this
      // stays true), so this inverse-transform math needs no changes at
      // all beyond map.w/h now being correct.
      const cam = readCamera(canvasEl);
      const vx0 = clamp((0 - cam.tx) / cam.scale, 0, map.w);
      const vy0 = clamp((0 - cam.ty) / cam.scale, 0, map.h);
      const vx1 = clamp((innerWidth - cam.tx) / cam.scale, 0, map.w);
      const vy1 = clamp((innerHeight - cam.ty) / cam.scale, 0, map.h);
      map.viewport = { x: vx0, y: vy0, w: Math.max(0, vx1 - vx0), h: Math.max(0, vy1 - vy0) };
    }

    // Bot vs human per cog dot: greek-letter identity marker (by proximity) ->
    // slot index -> roster. Best-effort; null (unknown) whenever any hop misses.
    const cogs = raw.cogs.map(function (c) {
      let human = null;
      if (!c.self && roster.resolved) {
        const idn = nearest(raw.identityMarkers, c.x, c.y, 30);
        if (idn && idn.greek in GREEK_TO_SLOT) {
          const slot = GREEK_TO_SLOT[idn.greek];
          const entry = roster.bySlot.get(slot);
          if (entry && typeof entry.person === 'boolean') human = entry.person;
        }
      }
      return { x: c.x, y: c.y, color: c.color, side: c.side, alive: c.alive, self: c.self, human: human };
    });

    // Variant: teamScoreRows is unconditional on the player stream regardless
    // of team count, so its length IS the live team count.
    const teamCount = raw.teamScoreRows.length;
    const variant = teamCount === 0 ? 'unknown' : (teamCount <= 4 ? 'ctf' : 'br');

    // Player rows, best wire source first:
    //   1. "roster " markers (8ad1c420) — the live player stream's own full
    //      roster: team/lives/kills/deaths per seat, anonymous slot names.
    //   2. "score " rows (50a13efc, global-backed hosts) — display names;
    //      kills/deaths null when the row is the old deployed shape.
    //   3. the HTTP roster (names only) — BR's last-resort fallback against
    //      a pre-50a13efc engine.
    let playerRows = [];
    if (raw.rosterRows.length) {
      // SELF on anonymous rows: unambiguous when my team has exactly one
      // seat; otherwise the identity badge nearest my own cog names my slot
      // identity; otherwise no row is marked (honest, never a guess).
      let selfName = null;
      if (seated && raw.selfTeam) {
        const mine = raw.rosterRows.filter(function (r) { return r.team === raw.selfTeam; });
        if (mine.length === 1) selfName = mine[0].name;
        else {
          const idn = nearest(raw.identityMarkers, raw.self.x, raw.self.y, 40);
          if (idn) selfName = idn.greek;
        }
      }
      playerRows = raw.rosterRows.map(function (row) {
        return {
          name: row.name, team: row.team, lives: row.lives,
          kills: row.kills, deaths: row.deaths,
          human: null, // anonymous rows never join the HTTP roster — honest "—"
          self: row.team === raw.selfTeam && row.name === selfName,
        };
      });
    } else if (raw.scoreRows.length) {
      playerRows = raw.scoreRows.map(function (row) {
        const rEntry = roster.resolved ? roster.byName.get(row.name.toLowerCase()) : null;
        return {
          name: row.name, team: rEntry ? rEntry.team : null, lives: row.lives,
          kills: row.kills, deaths: row.deaths,
          human: rEntry ? rEntry.person : null, self: isSelfRow(row.name, rEntry),
        };
      });
    } else if (variant === 'br' && roster.resolved) {
      roster.byName.forEach(function (rEntry) {
        playerRows.push({
          name: rEntry.name, team: rEntry.team, lives: null,
          kills: null, deaths: null, // nothing per-player on this wire — honest "—"
          human: rEntry.person, self: isSelfRow(rEntry.name, rEntry),
        });
      });
    }

    // BR zone (shrink ring): world knowledge, never fog-gated, present only
    // when the match is config-gated into zonePhases (labels.nim
    // LabelPrefixZone/LabelPrefixZoneNext). No tick-countdown ships with it —
    // only the two rects — so `shrinking` is a derived qualitative read
    // (current != next), never a fabricated number of seconds.
    let zone = null;
    if (raw.zone) {
      const eq = raw.zoneNext && raw.zone.x0 === raw.zoneNext.x0 && raw.zone.y0 === raw.zoneNext.y0 &&
        raw.zone.x1 === raw.zoneNext.x1 && raw.zone.y1 === raw.zoneNext.y1;
      zone = { current: raw.zone, next: raw.zoneNext, shrinking: raw.zoneNext ? !eq : false };
    }

    return {
      wireOk: raw.wireOk,
      seated: seated,
      dead: false, // filled in by caller, which tracks the seated->unseated edge over time
      selfTeam: raw.selfTeam,
      fire: { ready: raw.fireReady },
      health: health,
      combat: {
        // Own K/D straight off the "kd " label (real attribution, 50a13efc);
        // null — rendering "—" — whenever the label isn't on the wire.
        kills: raw.kdSelf ? raw.kdSelf.kills : null,
        deaths: raw.kdSelf ? raw.kdSelf.deaths : null,
        score: null, xp: null, level: null, rank: null, buffs: [],
      },
      // CTF-only; reserved. HUD_SPEC.md: the respawn ticks-remaining value
      // exists server-side (Player has the state) but is never sent on the
      // wire today. The render surface for this is fix-client3's center-
      // screen "you're down" transient, not this module — reserved here so
      // the shape is specified once if/when it needs threading through.
      respawn: { ticksRemaining: null },
      map: map,
      zone: zone,
      cogs: cogs,
      variant: variant,
      teamScores: raw.teamScoreRows,
      // Swap#11 item 6: real feed off the "teamsalive " label
      // (labels.nim LabelPrefixTeamsAlive -> sim.teamsAliveCount(), the
      // teamLivesRemaining() sibling). Null against a pre-Swap#11 engine —
      // teamAliveChips' per-seat-deaths heuristic is the fallback render
      // path for that case (see render()'s own use of this field).
      teamsAlive: raw.teamsAlive,
      playerRows: playerRows,
      roster: { resolved: roster.resolved, url: roster.url },
    };
  }

  function isSelfRow(name, rEntry) {
    if (myIdentity.slot != null && rEntry && rEntry.slot != null) return myIdentity.slot === rEntry.slot;
    if (myIdentity.name && name) return myIdentity.name.toLowerCase() === String(name).toLowerCase();
    return false;
  }

  // ---------------------------------------------------------------------
  // DOM + styling. Tokens pulled from docs/designs/season2-cheatsheet.html
  // (the established in-house in-game look — this surface is Case A, not
  // Observatory's cream/serif system, per HUD_SPEC.md §0): --panel
  // rgba(13,10,6,.55), --line (amber-tinted hairline) rgba(232,163,61,.28),
  // --paper #f2e8d8 text, --paper-dim #b8ac98 / --ghost #8a7f72 secondary,
  // --amber #e8a33d reserved for the one emphasis job per zone (never every
  // label — principles.md "reserve the primary accent"). Swap#11 item 2:
  // eyebrows/headers/toggle/standings-th previously carried the cheat
  // sheet's condensed-sans display face (Rajdhani) — that violates this
  // codebase's own rule (player_client.html:101-109, stated at
  // --eventfont's definition) that the display face may not touch
  // readouts; these ARE readouts (labels over live numeric data), not a
  // headline beat like the death card / round-flip / endcard. Every word
  // AND every numeral in this HUD now shares the one in-game monospace
  // face (player_client.html's own #hud/#feed use it) for legible tabular
  // digits and player names — no word-face/number-face split left. No
  // left-border accent stripes anywhere (the hard floor this spec calls
  // out by name against player_client.html's own .wchip) — hairlines run
  // all the way around or not at all.
  // ---------------------------------------------------------------------
  // ---------------------------------------------------------------------
  // HUD scale (Maxwell, live 8/30: "no numbers on the scorecard thing in
  // the top left (barely readable at that size... maybe give the option
  // to adjust gui size? in settings if possible)"). Checked first: this
  // client has NO settings surface anywhere -- no #settings, no options
  // panel, nothing beyond player_client.html's own bare mute button and
  // this module's click-to-cycle "standings · tab" toggle. Smallest honest
  // thing, not a settings system built on spec: one more click-to-cycle
  // control living right next to that toggle, persisted the same way this
  // codebase's one real persisted preference already is (cameraStorageKey
  // in player_client.html -- localStorage, wrapped in try/catch, one key
  // per preference). Mute itself does NOT persist across reload (checked:
  // `muted` is a bare in-memory flag) so it is not the idiom to copy for
  // persistence, only for the button's own "label: value" text shape.
  //
  // The root readability bug this also fixes: .phud-num/.phud-eyebrow were
  // fixed CSS px (15px/10px) with zero relationship to viewport size or
  // display size -- as the window (or a maximised Retina panel) gets
  // bigger the arena fills more of the eye while this chrome stays exactly
  // the same absolute size, so it reads smaller in practice even though
  // DPR-correct crisp rendering was never the problem. --phud-scale is a
  // single multiplier threaded through every size-bearing rule below
  // (never the screen-edge INSETS -- left/top/right/bottom of each panel
  // stay fixed so the corner anchor never drifts, only the chrome pinned
  // to it grows) and through the minimap's own JS pixel budget below. The
  // 'M' step is also the new always-on DEFAULT (index 1, no click
  // required) -- a good default beats a good control; this makes the
  // control matter only for players who want MORE or less than that.
  // ---------------------------------------------------------------------
  const HUD_SCALE_KEY = 'ctfHudScale';
  const HUD_SCALE_STEPS = [
    { label: 'S', value: 0.85 },
    { label: 'M', value: 1 },
    { label: 'L', value: 1.2 },
    { label: 'XL', value: 1.45 },
  ];
  const HUD_SCALE_DEFAULT_INDEX = 1; // 'M'
  function loadHudScaleIndex() {
    let stored = null;
    try { stored = localStorage.getItem(HUD_SCALE_KEY); } catch (e) { /* private mode etc. -- fall through to default */ }
    const idx = stored === null ? NaN : parseInt(stored, 10);
    return (idx >= 0 && idx < HUD_SCALE_STEPS.length) ? idx : HUD_SCALE_DEFAULT_INDEX;
  }
  let hudScaleIndex = loadHudScaleIndex();
  function hudScaleValue() { return HUD_SCALE_STEPS[hudScaleIndex].value; }
  function hudScaleLabel() { return HUD_SCALE_STEPS[hudScaleIndex].label; }
  function applyHudScale() {
    const root = document.getElementById('phud-root');
    if (root) root.style.setProperty('--phud-scale', String(hudScaleValue()));
  }
  function cycleHudScale(nodes) {
    hudScaleIndex = (hudScaleIndex + 1) % HUD_SCALE_STEPS.length;
    try { localStorage.setItem(HUD_SCALE_KEY, String(hudScaleIndex)); } catch (e) { /* stays session-only, never fatal */ }
    applyHudScale();
    if (nodes && nodes.scaleToggle) nodes.scaleToggle.textContent = 'hud size: ' + hudScaleLabel().toLowerCase();
  }
  // Every scaled length in the CSS template below is built through this
  // instead of a bare `Npx`, so one custom-property write (initial mount,
  // or a click on the toggle) moves every dependent rule in lockstep.
  function S(px) { return 'calc(' + px + 'px * var(--phud-scale,1))'; }

  // F_WORD (the cheat sheet's Rajdhani display face) intentionally removed
  // here, Swap#11 item 2: every use-site in this module was a readout
  // (eyebrow/header/toggle/standings-th), which the display-face rule
  // forbids — see the comment above. Rajdhani stays sanctioned ONLY for
  // player_client.html's own headline beats (death card / round-flip /
  // endcard via --eventfont), which are untouched.
  const F_NUM = 'ui-monospace,SFMono-Regular,Menlo,monospace';
  const CSS = '\n'
    + '#phud-root{position:fixed;inset:0;pointer-events:none;z-index:35;'
    // A second, independent layer of insurance against bright-paint bleed
    // (on top of the .82 panel backing above): the same dark drop-shadow
    // technique player_client.html's own kill feed already uses over the
    // world canvas ("#feed .fev{text-shadow:0 1px 2px #000,0 0 5px #000a}")
    // — proven in this exact codebase for legible text over an unpredictable
    // bright/busy background.
    + 'font-family:' + F_NUM + ';color:#f2e8d8;text-shadow:0 1px 2px #000,0 0 4px #000c;}\n'
    // Panel opacity deviates from the cheat sheet's own --panel token (.55):
    // that value was tuned for a static instructional page over a controlled
    // dark stage background. This chrome sits over a LIVE painted arena —
    // the floor is high-chroma team paint, including bright orange/yellow —
    // and amber-on-.55-translucent-dark risks disappearing over a fresh
    // light splat (coordinator's flagged concern). .82 keeps the hairline/
    // token language but gives real backing contrast regardless of what's
    // painted underneath; verified by screenshot over painted ground, not
    // assumed.
    + '.phud-panel{background:rgba(10,8,5,.82);border:1px solid rgba(232,163,61,.28);padding:' + S(7) + ' ' + S(10) + ';}\n'
    + '.phud-eyebrow{font-family:' + F_NUM + ';font-size:' + S(11) + ';font-weight:700;letter-spacing:.12em;'
    + 'text-transform:uppercase;color:#b8ac98;white-space:nowrap;}\n'
    // 15px -> 19px base (Maxwell, live 8/30: "barely readable at that
    // size"): this is the number the player scans mid-fight, so it carries
    // the whole readability fix -- the eyebrow above it stays a label, this
    // is the thing that has to read at a glance. Scaled like everything
    // else, but its base is the actual fix, not the control.
    + '.phud-num{font-family:' + F_NUM + ';font-size:' + S(19) + ';font-weight:700;letter-spacing:.2px;font-variant-numeric:tabular-nums;}\n'
    + '.phud-sub{font-size:' + S(11) + ';color:#b8ac98;letter-spacing:.2px;}\n'
    + '#phud-rail{position:fixed;left:10px;top:9px;display:flex;gap:' + S(16) + ';}\n'
    + '#phud-rail .phud-stat{display:flex;flex-direction:column;gap:1px;min-width:' + S(44) + ';}\n'
    + '#phud-rail .phud-num.tick{animation:phud-tick .42s ease-out;}\n'
    + '@keyframes phud-tick{0%{transform:scale(1);color:#f2e8d8;}30%{transform:scale(1.28);color:#e8a33d;}100%{transform:scale(1);color:#f2e8d8;}}\n'
    + '#phud-cond{position:fixed;left:10px;bottom:8px;display:flex;gap:' + S(13) + ';align-items:baseline;}\n'
    + '#phud-cond .phud-stat{display:flex;flex-direction:column;gap:1px;}\n'
    + '#phud-cond .phud-hp-low{color:#ff6a52;}\n'
    // Weapon-ready pip — REDESIGNED off a live field report (Maxwell, playing
    // BR): "there is a yellow dot near my cursor, but not on it... i already
    // have a crosshair ON my cursor. and this yellow dot is big enough to
    // cover any cog on my screen so definitely not for aiming." The prior
    // build cursor-anchored this at 11px + a 5px glow (bigger under the
    // .pop feedback), offset from the cursor by a fixed margin — exactly
    // the shape of that complaint: close enough to the crosshair to read as
    // a SECOND aim marker, big enough to occlude a cog, and it never sat
    // where the eye already was (the actual crosshair, drawn by fix-client3
    // AT the cursor pixel). Fix ships as the design review calls for: this
    // is a STATUS, not a position, so it moves OFF the cursor entirely and
    // anchors to a fixed HUD position inside the condition panel (bottom-
    // left, alongside hp/lives) — nowhere near the reticle, impossible to
    // mistake for an aim aid — and shrinks to a 7px pip so it can never
    // occlude a cog even transiently. Filled amber = ready / hollow ring =
    // cooling (unchanged semantics; the wire is a boolean ready/not-ready,
    // global.nim:8787 — no numeric remaining-time exists, so still no
    // progress idiom), plus the short word (READY/COOLING) next to it so
    // the state reads with zero ambiguity even before the color registers.
    + '#phud-cooldown{display:inline-block;width:' + S(8) + ';height:' + S(8) + ';margin-right:' + S(6) + ';'
    + 'vertical-align:middle;border-radius:50%;transition:opacity .12s;}\n'
    + '#phud-cooldown.ready{background:#e8a33d;box-shadow:0 0 3px #e8a33d90;}\n'
    + '#phud-cooldown.cooling{background:transparent;border:1.5px solid #8a7f72;}\n'
    + '#phud-cooldown.pop{animation:phud-pop .22s ease-out;}\n'
    + '@keyframes phud-pop{0%{transform:scale(1.6);}100%{transform:scale(1);}}\n'
    // left:50% is a fallback only -- positionTopBar() (see render section
    // below) overwrites this element's `left` inline every frame it's
    // shown, biased right of dead-center by just enough to clear
    // #phud-rail's actual measured width so the two panels can never
    // overlap at any window size or --phud-scale value (the collision a
    // prior HUD lane flagged and explicitly left alone at small sizes).
    + '#phud-top{position:fixed;left:50%;top:9px;transform:translateX(-50%);display:flex;gap:' + S(16) + ';align-items:baseline;white-space:nowrap;}\n'
    + '#phud-top .t{font-family:' + F_NUM + ';font-size:' + S(16) + ';font-weight:700;letter-spacing:.05em;}\n'
    + '#phud-top .phud-eyebrow{align-self:center;}\n'
    // Per-team-color alive chips — Maxwell: "i can't see what colors are
    // still alive in the header." The BR top bar carried teams-alive/zone
    // as TEXT only; this adds the at-a-glance row the report asked for.
    // Filled square = that team's color, still in it; hollow/greyed square
    // = eliminated — the SAME filled-vs-hollow vocabulary the minimap dots
    // already use for bot-vs-unknown, reused here for alive-vs-wiped rather
    // than invented fresh (see renderTopBar/teamAliveChips for the wire
    // read this is driven by).
    + '#phud-top .phud-chips{display:inline-flex;gap:3px;align-items:center;align-self:center;}\n'
    // Partner-out toast — Swap#12 item 5 (DUET C: "the partner is a dot,
    // death of partner = zero acknowledgment"). One-shot, feed-style line
    // that reuses the same panel/eyebrow-adjacent idiom as the rest of this
    // HUD rather than inventing a new chrome language; --tc is the
    // partner's own team color (teamColor(), set at fire time), and the
    // left accent bar borrows the exact "colored edge on a dark panel"
    // read replay_broadcast.html's own banner-chip already established.
    + '#phud-partner{position:fixed;left:50%;top:' + S(38) + ';transform:translateX(-50%) translateY(-6px);'
    + 'font-family:' + F_NUM + ';font-size:' + S(13) + ';font-weight:700;letter-spacing:.1em;text-transform:uppercase;'
    + 'background:rgba(10,8,5,.88);border-left:3px solid var(--tc,#e8a33d);padding:' + S(6) + ' ' + S(12) + ';'
    + 'opacity:0;transition:opacity .25s ease,transform .25s ease;white-space:nowrap;pointer-events:none;}\n'
    + '#phud-partner.show{opacity:1;transform:translateX(-50%) translateY(0);}\n'
    + '#phud-top .phud-chip{width:' + S(10) + ';height:' + S(10) + ';border-radius:2px;flex:none;box-shadow:inset 0 0 0 1px rgba(0,0,0,.55);}\n'
    + '#phud-top .phud-chip.wiped{background:transparent;opacity:.5;box-shadow:inset 0 0 0 1px rgba(184,172,152,.6);}\n'
    + '#phud-mini-wrap{position:fixed;right:10px;bottom:10px;display:flex;flex-direction:column;align-items:flex-end;gap:5px;}\n'
    + '#phud-mini-wrap .phud-eyebrow{padding-right:2px;}\n'
    // Toolbar row: the "standings · tab" toggle plus the new HUD-size
    // toggle, side by side -- same corner cluster idiom player_client.html
    // already uses for its own mute/leave pair, not a second control system.
    + '#phud-toolbar{display:flex;gap:6px;}\n'
    // The panel chrome (background/border/padding) lives on a dedicated
    // #phud-mini-frame wrapper, NOT on the canvas itself. Found by testing
    // over the real client, not by inspection: a <canvas> is a "replaced
    // element" with its own intrinsic bitmap size (168x90, set via its
    // width/height attributes, not CSS) — putting .phud-panel's padding/
    // border directly on that same element produced a flex-column parent
    // that shrink-wrapped to a SMALLER box than the canvas actually painted
    // at, so the real rendered panel spilled ~90px past the intended
    // right:10px/bottom:10px inset and got clipped by the raw viewport edge
    // instead. Separating "the box" from "the bitmap" into two elements
    // fixes the measurement at its root instead of fighting flex sizing.
    + '#phud-mini-frame{display:inline-block;line-height:0;}\n'
    // THE crop bug (still reproducing after the 90px-spill fix above, at
    // Maxwell's own real window size): the host page's OWN top-level
    // `canvas{...}` rule (player_client.html, scoped to the world canvas #c
    // — position:absolute;left:0;top:0;transform-origin:0 0) is a bare TYPE
    // selector, so it matches every <canvas> on the page, including this
    // one — and because #phud-mini here never declared `position`/`left`/
    // `top` of its own, those three properties cascade in from the host
    // rule (an ID selector only wins the properties it actually sets; an
    // unset property still falls through to a lower-specificity rule that
    // DOES set it). Confirmed live, not guessed: getComputedStyle(#phud-
    // mini).position read back "absolute" with left/top "0px" in a harness
    // built from the real player_client.html markup. The nearest POSITIONED
    // ancestor is #phud-mini-wrap itself (position:fixed above), so the
    // canvas rendered as a 168x100 box pinned to *that* element's top-left
    // corner and — being absolutely positioned — stopped contributing to
    // #phud-mini-frame's inline-block sizing entirely (frame collapsed to
    // just its own padding/border). Net effect: the visible bitmap floats
    // detached from its own chrome and, depending on how wide the rest of
    // the column (the toggle button/label) happens to be, its right/bottom
    // edge can land past the viewport edge — silent, size-dependent
    // cropping, exactly what was reported. Fix: reclaim the 3 properties
    // explicitly so this element can never again inherit host-page canvas
    // styling by accident, at any window size.
    + '#phud-mini{display:block;position:static;left:auto;top:auto;image-rendering:pixelated;}\n'
    + '#phud-toggle,#phud-scale-toggle{pointer-events:auto;cursor:pointer;font-family:' + F_NUM + ';font-size:' + S(10) + ';font-weight:700;letter-spacing:.1em;'
    + 'text-transform:uppercase;color:#b8ac98;background:rgba(13,10,6,.55);border:1px solid rgba(232,163,61,.28);padding:' + S(3) + ' ' + S(7) + ';user-select:none;white-space:nowrap;}\n'
    + '#phud-toggle:hover,#phud-scale-toggle:hover{color:#f2e8d8;}\n'
    + '#phud-toggle.pinned{color:#e8a33d;border-color:rgba(232,163,61,.55);}\n'
    // top offset scales alongside #phud-top above it (S(64) not a bare
    // 64px) so a bigger --phud-scale, which makes #phud-top taller too,
    // can never push this panel's header up under it.
    + '#phud-score{position:fixed;left:50%;top:' + S(64) + ';transform:translateX(-50%);min-width:340px;max-width:min(78vw,620px);'
    + 'max-height:min(60vh,520px);overflow:auto;display:none;}\n'
    + '#phud-score.open{display:block;}\n'
    + '#phud-score h2{font-family:' + F_NUM + ';font-size:' + S(13) + ';font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:#b8ac98;margin:0 0 6px;}\n'
    + '#phud-score table{border-collapse:collapse;width:100%;font-size:' + S(13) + ';}\n'
    + '#phud-score th{text-align:left;font-family:' + F_NUM + ';font-size:' + S(11) + ';font-weight:700;letter-spacing:.08em;text-transform:uppercase;'
    + 'color:#b8ac98;border-bottom:1px solid rgba(232,163,61,.28);padding:' + S(3) + ' ' + S(8) + ' ' + S(4) + ' 0;}\n'
    + '#phud-score td{padding:' + S(4) + ' ' + S(9) + ' ' + S(4) + ' 0;border-bottom:1px solid rgba(232,163,61,.14);white-space:nowrap;}\n'
    + '#phud-score tr.self td{color:#e8a33d;font-weight:700;}\n'
    + '#phud-score .phud-dim{color:#b8ac98;}\n'
    + '#phud-score .phud-splat{color:#ff6a52;font-weight:700;letter-spacing:.06em;}\n'
    + '#phud-score .phud-empty{color:#8a7f72;font-style:italic;padding:8px 0;}\n'
    ;

  function mount() {
    const style = el('style'); style.textContent = CSS; document.head.appendChild(style);
    const root = el('div'); root.id = 'phud-root';
    root.innerHTML =
      '<div id="phud-top" class="phud-panel" style="display:none"></div>' +
      '<div id="phud-partner"></div>' +
      '<div id="phud-rail" class="phud-panel">' +
      '<div class="phud-stat"><span class="phud-eyebrow">kills</span><span class="phud-num" id="phud-k">—</span></div>' +
      '<div class="phud-stat"><span class="phud-eyebrow">deaths</span><span class="phud-num" id="phud-d">—</span></div>' +
      // SCORE/RANK tiles: Swap#11 item 3 — combat.score/rank are reserved
      // Glory fields that always render the placeholder while Glory is
      // undeployed (see the KNOWN GAPS note above). A tile that can only
      // ever read "—" is not an honest placeholder, it's permanent dead
      // weight in the rail; hidden here by STRUCTURE (display:none on the
      // whole .phud-stat, not just the number span) whenever the value is
      // the placeholder, and unhidden with zero further code the day Glory
      // actually ships real values — see the display toggle in the render
      // loop below (nodes.scTile/nodes.rkTile).
      '<div class="phud-stat" id="phud-sc-tile" style="display:none"><span class="phud-eyebrow">score</span><span class="phud-num" id="phud-sc">—</span></div>' +
      '<div class="phud-stat" id="phud-rk-tile" style="display:none"><span class="phud-eyebrow">rank</span><span class="phud-num" id="phud-rk" style="font-size:11px">—</span></div>' +
      '</div>' +
      '<div id="phud-cond" class="phud-panel">' +
      '<div class="phud-stat"><span class="phud-eyebrow">condition</span><span class="phud-num" id="phud-hp">—</span></div>' +
      '<div class="phud-stat"><span class="phud-eyebrow">lives</span><span class="phud-num" id="phud-lv">—</span></div>' +
      // Eyebrow text only ("marker" -- Maxwell's ruling 8/30, real
      // paintball's own word for the gun): CSS uppercases it to MARKER,
      // same treatment as every other eyebrow here. The DOM ids
      // (phud-weapon-text etc.) and the wire fields they read stay exactly
      // as they were -- this is a chrome label, not a protocol rename.
      '<div class="phud-stat"><span class="phud-eyebrow">marker</span><span class="phud-num"><span id="phud-cooldown"></span><span id="phud-weapon-text">—</span></span></div>' +
      '<div class="phud-stat" id="phud-buffwrap" style="display:none"><span class="phud-eyebrow">buffs</span><span class="phud-sub" id="phud-buffs"></span></div>' +
      '</div>' +
      '<div id="phud-mini-wrap">' +
      '<div id="phud-toolbar">' +
      '<div id="phud-toggle">standings · tab</div>' +
      '<div id="phud-scale-toggle" title="Click to change HUD text size">hud size: ' + hudScaleLabel().toLowerCase() + '</div>' +
      '</div>' +
      '<div><span class="phud-eyebrow" id="phud-mini-label" style="display:block;text-align:right;margin-bottom:3px;">map</span>' +
      '<div id="phud-mini-frame" class="phud-panel"><canvas id="phud-mini"></canvas></div></div>' +
      '</div>' +
      '<div id="phud-score" class="phud-panel"><div id="phud-score-body"></div></div>';
    document.body.appendChild(root);
    applyHudScale(); // before first paint -- no flash of the unscaled default
    return {
      top: root.querySelector('#phud-top'),
      rail: root.querySelector('#phud-rail'),
      k: root.querySelector('#phud-k'), d: root.querySelector('#phud-d'),
      sc: root.querySelector('#phud-sc'), rk: root.querySelector('#phud-rk'),
      scTile: root.querySelector('#phud-sc-tile'), rkTile: root.querySelector('#phud-rk-tile'),
      hp: root.querySelector('#phud-hp'), lv: root.querySelector('#phud-lv'),
      buffWrap: root.querySelector('#phud-buffwrap'), buffs: root.querySelector('#phud-buffs'),
      cooldown: root.querySelector('#phud-cooldown'), weaponText: root.querySelector('#phud-weapon-text'),
      mini: root.querySelector('#phud-mini'),
      miniLabel: root.querySelector('#phud-mini-label'),
      toggle: root.querySelector('#phud-toggle'),
      scaleToggle: root.querySelector('#phud-scale-toggle'),
      score: root.querySelector('#phud-score'),
      scoreBody: root.querySelector('#phud-score-body'),
      partnerToast: root.querySelector('#phud-partner'),
    };
  }

  // ---------------------------------------------------------------------
  // Tab-to-show scoreboard + click-toggle fallback. Never steals Tab while
  // the chat box (host's #i) is focused.
  // ---------------------------------------------------------------------
  let scorePinned = false, scoreHeld = false;
  function chatFocused() {
    const a = document.activeElement;
    return !!a && a.tagName === 'INPUT' && a.id === 'i';
  }
  addEventListener('keydown', function (e) {
    if (e.code !== 'Tab' || chatFocused()) return;
    e.preventDefault();
    scoreHeld = true;
  });
  addEventListener('keyup', function (e) {
    if (e.code !== 'Tab') return;
    scoreHeld = false;
  });
  addEventListener('blur', function () { scoreHeld = false; });

  // ---------------------------------------------------------------------
  // Minimap draw: reuses the host's OWN already-decoded pixel buffer (the
  // #c canvas) via a scaled drawImage — no duplicate pixel stream requested
  // from the server. (No literal "factor-3 bake" was found to reuse in this
  // tree as of 7a052635; the closest prior art is broadcast_core.js's own
  // drawMinimap, on the unmerged maxwell/br-pixelpipe-perf-clean branch.
  // This draws its own, independently, off the client's live canvas.)
  // ---------------------------------------------------------------------
  // Base budget at --phud-scale 1 ('M'); miniMaxW/H below scale these
  // alongside every other piece of this module's screen-fixed chrome, so
  // a player who bumps HUD size gets a bigger minimap too, not just
  // bigger text next to an unchanged map.
  const MINIMAP_MAX_W = 168, MINIMAP_MAX_H = 100;
  function miniMaxW() { return MINIMAP_MAX_W * hudScaleValue(); }
  function miniMaxH() { return MINIMAP_MAX_H * hudScaleValue(); }
  // Defense in depth alongside the #phud-mini position fix above (the
  // actual root cause of the reported crop): clamp the on-screen budget to
  // whatever room the corner ACTUALLY has at the CURRENT viewport size, so
  // the panel can never claim more than fits between its own 10px inset and
  // the edge of the screen, independent of the fixed MINIMAP_MAX_W/H budget
  // above (which alone assumes the corner always has >=~200x160px of slack
  // — true at every size this lane tested, kept here for whatever size
  // wasn't). Numbers below are the wrap's own CSS: MINI_INSET_PX matches
  // #phud-mini-wrap's right/bottom; MINI_CHROME_W_PX is #phud-mini-frame's
  // own padding+border (9*2 + 1*2); MINI_CHROME_H_PX is everything stacked
  // ABOVE the canvas in that same corner — the toggle button, the wrap's
  // gap, the eyebrow label, and the frame's own padding+border.
  const MINI_INSET_PX = 10, MINI_CHROME_W_PX = 20, MINI_CHROME_H_PX = 60;
  function miniChromeW() { return MINI_CHROME_W_PX * hudScaleValue(); }
  function miniChromeH() { return MINI_CHROME_H_PX * hudScaleValue(); }
  let lastMiniDrawAt = 0;
  function drawMinimap(miniCanvas, canvasEl, state) {
    if (!canvasEl || state.map.w < 2 || state.map.h < 2) { miniCanvas.width = 0; miniCanvas.height = 0; return; }
    const now = performance.now();
    if (now - lastMiniDrawAt < 90) return; // throttle, matches the cadence of the prior-art minimap
    lastMiniDrawAt = now;
    const boundW = Math.min(miniMaxW(), Math.max(40, innerWidth - MINI_INSET_PX * 2 - miniChromeW()));
    const boundH = Math.min(miniMaxH(), Math.max(40, innerHeight - MINI_INSET_PX * 2 - miniChromeH()));
    const scale = Math.min(boundW / state.map.w, boundH / state.map.h);
    const w = Math.max(1, Math.round(state.map.w * scale)), h = Math.max(1, Math.round(state.map.h * scale));
    if (miniCanvas.width !== w) miniCanvas.width = w;
    if (miniCanvas.height !== h) miniCanvas.height = h;
    const ctx = miniCanvas.getContext('2d');
    ctx.imageSmoothingEnabled = true;
    ctx.clearRect(0, 0, w, h);
    // Pixel source: used to sample `canvasEl` (the host's own #c) directly,
    // on the assumption it always held the whole map at native resolution.
    // The viewport-clip lane broke that assumption (canvasEl is now just the
    // current camera window) and added a dedicated, already-downsampled
    // whole-map source for exactly this consumer — `minimapSourceCanvas`,
    // read the same cross-script-global way `objects`/`sprites`/`mapW` are
    // (see buildState's own comment on this). Falls back to the old
    // canvasEl sampling if that global isn't present (an older host build,
    // or the very first frame before it's been built once) so this module
    // never hard-depends on the newer host.
    const miniSrc = (typeof minimapSourceCanvas !== 'undefined' && minimapSourceCanvas && minimapSourceCanvas.width > 1) ? minimapSourceCanvas : canvasEl;
    ctx.drawImage(miniSrc, 0, 0, miniSrc.width, miniSrc.height, 0, 0, w, h);
    ctx.fillStyle = 'rgba(0,0,0,.28)'; ctx.fillRect(0, 0, w, h); // legibility scrim over busy paint

    // BR shrink zone (item B's primary overlay when present — "where is
    // safe and which way do I move" outranks everything else in a one-life
    // closing-ring mode). Current ring solid+bright with the outside-zone
    // area darkened; next (target) ring dashed and dim. Both rects are
    // world knowledge off the wire (labels.nim LabelPrefixZone/ZoneNext) —
    // no fabricated countdown, see parseZoneLabel's header comment.
    if (state.zone && state.zone.current) {
      const z = state.zone.current;
      const zx = z.x0 * scale, zy = z.y0 * scale, zw = Math.max(1, (z.x1 - z.x0) * scale), zh = Math.max(1, (z.y1 - z.y0) * scale);
      const outside = new Path2D();
      outside.rect(0, 0, w, h);
      outside.rect(zx, zy, zw, zh);
      ctx.fillStyle = 'rgba(0,0,0,.4)';
      ctx.fill(outside, 'evenodd');
      if (state.zone.next) {
        const zn = state.zone.next;
        ctx.save();
        ctx.setLineDash([2, 2]);
        ctx.strokeStyle = 'rgba(255,255,255,.55)'; ctx.lineWidth = 1;
        ctx.strokeRect(zn.x0 * scale + .5, zn.y0 * scale + .5, Math.max(1, (zn.x1 - zn.x0) * scale), Math.max(1, (zn.y1 - zn.y0) * scale));
        ctx.restore();
      }
      ctx.strokeStyle = '#ffec27'; ctx.lineWidth = 1.4;
      ctx.strokeRect(zx + .5, zy + .5, zw, zh);
    }

    // Viewport box.
    if (state.map.viewport) {
      const vp = state.map.viewport;
      ctx.strokeStyle = 'rgba(255,255,255,.85)'; ctx.lineWidth = 1;
      ctx.strokeRect(vp.x * scale + .5, vp.y * scale + .5, Math.max(1, vp.w * scale), Math.max(1, vp.h * scale));
    }

    // Cog dots. A same-team-colored dot on a floor already painted that
    // team's color is a real failure mode found by testing (not guessed):
    // at this minimap scale a plain filled circle can disappear into a
    // same-hue splat behind it. Every dot gets a min-contrast outline first
    // (regardless of self/bot/human) so it reads as a DOT, not a paint
    // pixel, before any fill/stroke color decision — Swap#12 item 6 made
    // that outline color adapt to the dot's own fill (see minContrastOutline)
    // instead of always being dark, which is what let a dark-ish team color
    // vanish into the dark scrim outline-and-all.
    for (let i = 0; i < state.cogs.length; i++) {
      const c = state.cogs[i];
      const px = c.x * scale, py = c.y * scale;
      const col = teamColor(c.color);
      ctx.globalAlpha = c.alive ? 1 : 0.4;
      if (c.self) {
        ctx.beginPath(); ctx.arc(px, py, 3.4, 0, Math.PI * 2);
        ctx.strokeStyle = '#fff'; ctx.lineWidth = 1.2; ctx.stroke();
      }
      const r = c.self ? 2.2 : 1.9;
      ctx.beginPath(); ctx.arc(px, py, r + 0.9, 0, Math.PI * 2);
      ctx.strokeStyle = minContrastOutline(col); ctx.lineWidth = 1.4; ctx.stroke();
      ctx.beginPath(); ctx.arc(px, py, r, 0, Math.PI * 2);
      if (c.human === false) { // confirmed bot: hollow ring, not filled
        ctx.strokeStyle = col; ctx.lineWidth = 1; ctx.stroke();
      } else { // confirmed human, or unresolved (honest default: filled, slightly dimmer when unknown)
        ctx.fillStyle = col; ctx.globalAlpha *= (c.human === null ? 0.55 : 1); ctx.fill();
      }
    }
    ctx.globalAlpha = 1;

    // Partner pulse (Swap#12 item 5) — a one-time expanding, fading ring at
    // the partner's last known position, armed by trackPartner()'s own
    // deaths-transition detection (see that function). Purely decorative;
    // clears itself once and never re-triggers on its own.
    if (partnerPulse) {
      if (now < partnerPulse.expireAt) {
        const t = (now - partnerPulse.startAt) / PARTNER_PULSE_MS;
        const ppx = partnerPulse.x * scale, ppy = partnerPulse.y * scale;
        ctx.globalAlpha = Math.max(0, 1 - t);
        ctx.beginPath(); ctx.arc(ppx, ppy, 3 + t * 16, 0, Math.PI * 2);
        ctx.strokeStyle = partnerPulse.color; ctx.lineWidth = 2.2; ctx.stroke();
        ctx.globalAlpha = 1;
      } else {
        partnerPulse = null; // expired — stop drawing/checking it every frame
      }
    }
  }

  // ---------------------------------------------------------------------
  // Scoreboard render: CTF vs BR variant, per the wire-derived team count.
  // ---------------------------------------------------------------------
  // BR visible-row cap. 12 rows ≈ the 16-duo midgame's live half without
  // approaching the 32-row wall the emitting lane flagged; own row is exempt
  // from the cap (see below), so "where am I" never scrolls away.
  const BR_MAX_ROWS = 12;
  function renderScoreboard(nodes, state) {
    const rows = state.playerRows.slice();
    // Team score / teams-alive is the always-on TOP-CENTER bar now (see
    // renderTopBar) — not repeated here, so the hold-Tab panel is purely
    // the per-player table it's named for.
    let html = '';
    if (state.variant === 'ctf') {
      html += '<h2>ctf · standings</h2>';
      rows.sort(function (a, b) {
        if (a.team !== b.team) return (a.team || '').localeCompare(b.team || '');
        return (b.lives || 0) - (a.lives || 0);
      });
      // K/D column lights up row by row as the new-shape "score " rows arrive
      // (parseScoreLabel); old-shape rows keep an honest "—/—". No layout
      // change either way — the column was built for this.
      html += rowsTable(rows, ['name', 'team', 'lives', 'kd', 'who'], function (r) {
        return '<td>' + escapeHtml(r.name) + '</td>' +
          '<td style="color:' + teamColor(r.team) + '">' + fmtDash(r.team) + '</td>' +
          '<td>' + fmtDash(r.lives) + '</td>' +
          '<td class="phud-dim">' + fmtDash(r.kills) + '/' + fmtDash(r.deaths) + '</td>' +
          '<td class="phud-dim">' + whoText(r.human) + '</td>';
      }, rows.length ? null : 'No standings data yet.');
    } else if (state.variant === 'br') {
      // Real wire rows (any lives/kills present) get "standings"; the
      // roster-only fallback keeps calling itself what it is.
      const haveWireRows = rows.some(function (r) { return r.lives !== null || r.kills !== null; });
      html += '<h2>br · ' + (haveWireRows ? 'standings' : 'roster') +
        ' · <span class="phud-dim">teams in match: ' + fmtDash(state.teamScores.length) +
        ' · teams alive: ' + fmtDash(state.teamsAlive) + '</span></h2>';
      // 32-row legibility (the emitting lane's flagged handoff): a full BR
      // roster as a wall of rows is unreadable mid-fight, so sort by kills
      // (nulls last), then lives, then name, and CAP at BR_MAX_ROWS — with
      // the own row ALWAYS kept visible (pulled up past the cap behind a
      // "···" gap marker when it ranks below it) and an explicit "+N more"
      // footer, so the cut is stated, never silent.
      rows.sort(function (a, b) {
        const ak = a.kills === null ? -1 : a.kills, bk = b.kills === null ? -1 : b.kills;
        if (bk !== ak) return bk - ak;
        // Alive above eliminated at equal kills (deaths asc, no-data last) —
        // the wire's own deaths count, not the misleading BR lives number.
        const ad = a.deaths === null ? 9999 : a.deaths, bd = b.deaths === null ? 9999 : b.deaths;
        if (ad !== bd) return ad - bd;
        return String(a.name).localeCompare(String(b.name));
      });
      let visible = rows, hidden = 0;
      if (rows.length > BR_MAX_ROWS) {
        visible = rows.slice(0, BR_MAX_ROWS);
        for (let i = BR_MAX_ROWS; i < rows.length; i++) {
          if (rows[i].self) { // own row below the cap: show top N-1, gap, self
            visible = rows.slice(0, BR_MAX_ROWS - 1);
            visible.push({ gap: true }, rows[i]);
            break;
          }
        }
        hidden = rows.length - visible.filter(function (r) { return !r.gap; }).length;
      }
      // placement stays END-CARD ONLY (sim.brPlacements(), never live).
      // NO numeric lives column in BR: the wire's lives value is RESPAWNS
      // REMAINING, so in a one-life mode every LIVING player reads 0 — a
      // column of zeros next to living players says "everyone is dead"
      // (caught on the first real 16-solo field, coordinator-confirmed).
      // Status renders instead, derived from the row's own deaths count
      // under BR's one rule (killPlayer: first death is elimination):
      // deaths>0 = SPLAT, deaths==0 = ALIVE, no data (HTTP-roster fallback
      // rows) = an honest em-dash. CTF keeps the numeric column, where the
      // number is true.
      html += rowsTable(visible, ['name', 'team', 'status', 'kd', 'who'], function (r) {
        if (r.gap) return '<td colspan="5" class="phud-dim" style="text-align:center">···</td>';
        const status = r.deaths === null ? '—' : (r.deaths > 0 ? 'SPLAT' : 'ALIVE');
        return '<td>' + escapeHtml(r.name) + '</td>' +
          '<td style="color:' + teamColor(r.team) + '">' + fmtDash(r.team) + '</td>' +
          '<td class="' + (r.deaths !== null && r.deaths > 0 ? 'phud-splat' : 'phud-dim') + '">' + status + '</td>' +
          '<td class="phud-dim">' + fmtDash(r.kills) + '/' + fmtDash(r.deaths) + '</td>' +
          '<td class="phud-dim">' + whoText(r.human) + '</td>';
      }, rows.length ? null : (state.roster.resolved ? 'No standings data yet.' : 'Roster unavailable — no /api/field response.'));
      if (hidden > 0) {
        html += '<div class="phud-sub" style="padding:5px 0 1px">+' + hidden +
          ' more · sorted by kills · your row always shown</div>';
      }
    } else {
      html += '<div class="phud-empty">No standings data yet.</div>';
    }
    nodes.scoreBody.innerHTML = html;
  }
  // ---------------------------------------------------------------------
  // Top-center bar: the mode-selected "what's the match situation" readout
  // (HUD_SPEC.md Part 2 — team score for CTF, teams-alive + zone status for
  // BR). Always-on, never gated behind Tab; team count alone (present every
  // tick) picks the variant the same way buildState() does.
  // ---------------------------------------------------------------------
  function renderTopBar(nodes, state) {
    if (state.variant === 'unknown') { nodes.top.style.display = 'none'; return; }
    nodes.top.style.display = '';
    if (state.variant === 'ctf') {
      // Eyebrow label (coordinator, live 8/30: Maxwell himself couldn't
      // identify this strip -- guessed team lives, then a hearts perk --
      // for a bare "BLUE 110/110" pair. It's tags-made/tags-lost
      // (parseTeamScoreLabel: kills/deaths), same contract as the BR
      // branch's own "teams alive"/"zone" eyebrows just below, which this
      // branch was missing entirely. Provisional word ("team tags") --
      // paintbot-voice owns the eventual paintball-register vocabulary
      // pass; not designing around this string.
      nodes.top.innerHTML = '<span class="phud-eyebrow">team tags</span>' +
        state.teamScores.slice()
        .sort(function (a, b) { return b.kills - a.kills; })
        .map(function (t) {
          return '<span class="t" style="color:' + teamColor(t.team.toLowerCase()) + '">' +
            t.team + ' <span class="phud-dim">' + t.kills + '/' + t.deaths + '</span></span>';
        }).join('');
    } else {
      const zoneWord = state.zone ? (state.zone.shrinking ? 'SHRINKING' : 'HOLD') : '—';
      const chips = teamAliveChips(state);
      // Swap#11 item 6: the real wire count (state.teamsAlive, "teamsalive "
      // label) now takes priority over teamAliveChips' own locally-derived
      // aliveCount heuristic — that heuristic is only as fresh as whatever
      // per-seat deaths data has arrived, and stays as the fallback purely
      // for a pre-Swap#11 engine that never sends the label (state.teamsAlive
      // null in that case, same tolerance idiom as combat.kills/deaths).
      nodes.top.innerHTML =
        '<span class="phud-eyebrow">teams alive</span><span class="t">' +
        fmtDash(state.teamsAlive != null ? state.teamsAlive : chips.aliveCount) +
        ' <span class="phud-dim">/ ' + fmtDash(state.teamScores.length) + '</span></span>' +
        '<span class="phud-chips">' + chips.html + '</span>' +
        '<span class="phud-eyebrow">zone</span><span class="t">' + zoneWord + '</span>';
    }
    positionTopBar(nodes);
  }
  // Collision fix (coordinator, live 8/30): a prior HUD lane found this bar
  // (CTF team score / BR teams-alive) can overlap #phud-rail's kills/
  // deaths/score/rail readout at small window widths and explicitly left
  // it alone as out of scope then. In scope now, and a bigger --phud-scale
  // makes both panels wider, so a static CSS breakpoint would need
  // retuning per scale step -- measure instead. #phud-top's CSS `left:50%`
  // sets where its un-translated left edge sits; translateX(-50%) then
  // shifts it left by exactly half of ITS OWN (already-rendered, so
  // already-scaled) width, so whatever px `left` we compute here IS the
  // horizontal CENTER the bar ends up at. Centered on the viewport unless
  // that would land its left edge inside #phud-rail's actual measured
  // right edge plus a gutter, in which case it's pushed right just far
  // enough to clear it -- true at every window size and every scale step,
  // not tuned per breakpoint.
  function positionTopBar(nodes) {
    const railRect = nodes.rail.getBoundingClientRect();
    const gutter = 14 * hudScaleValue();
    const halfTopWidth = nodes.top.offsetWidth / 2;
    const naturalCenter = innerWidth / 2;
    const minCenter = railRect.right + gutter + halfTopWidth;
    nodes.top.style.left = Math.max(naturalCenter, minCenter) + 'px';
  }
  // Per-team elimination read, keyed lowercase: "team score <NAME> ..." ships
  // NAME upper-ascii'd (addTeamScoreboard, global.nim:4327) while the roster
  // marker's <team> ships the bare lowercase color word (global.nim:4499,
  // "roster " & teamText(team), no .toUpperAscii) — two casings for the same
  // identity, confirmed against the engine source rather than assumed, so
  // both keys get lowercased before the join. Same rule the BR scoreboard's
  // own SPLAT/ALIVE status column uses (deaths>0 = eliminated, BR's one-life
  // rule), applied per TEAM instead of per row: a team reads WIPED only once
  // every seat we have data for reads deaths>0. A team with NO deaths data
  // at all (old-shape "score " rows, or the HTTP-roster names-only fallback)
  // stays presumed alive — never a fabricated elimination.
  function teamAliveStatus(state) {
    const byTeam = new Map();
    state.playerRows.forEach(function (r) {
      if (!r.team) return;
      const key = String(r.team).toLowerCase();
      const e = byTeam.get(key) || { anyAlive: false, anyData: false };
      if (r.deaths !== null) { e.anyData = true; if (r.deaths === 0) e.anyAlive = true; }
      byTeam.set(key, e);
    });
    return byTeam;
  }
  // The top-bar chip row itself: one small square per team in the match
  // (state.teamScores — RESOLVED, always sent regardless of team count, so
  // its list of teams is reliable even when no per-seat data has arrived
  // yet). Filled = alive or unknown (honest default); hollow/greyed =
  // confirmed wiped. aliveCount is a locally-derived DISPLAY read (same
  // pattern as "shrinking"/"ALIVE"/"SPLAT" elsewhere in this file) — it does
  // NOT change state.teamsAlive itself, which stays whatever buildState()
  // set it to (the real "teamsalive " wire count as of Swap#11 item 6, or
  // null against an older engine). render()'s own top-bar code prefers
  // state.teamsAlive over this function's aliveCount whenever the real
  // value is present — see the comment at that call site.
  function teamAliveChips(state) {
    const status = teamAliveStatus(state);
    const teams = state.teamScores.map(function (t) { return t.team; });
    if (!teams.length) return { html: '', aliveCount: null };
    let aliveCount = 0, html = '';
    teams.forEach(function (team) {
      const key = String(team).toLowerCase();
      const e = status.get(key);
      const wiped = !!(e && e.anyData && !e.anyAlive);
      if (!wiped) aliveCount++;
      html += '<i class="phud-chip' + (wiped ? ' wiped' : '') + '"' +
        (wiped ? '' : ' style="background:' + teamColor(key) + '"') +
        ' title="' + escapeHtml(team) + (wiped ? ' — eliminated' : '') + '"></i>';
    });
    return { html: html, aliveCount: aliveCount };
  }
  function whoText(human) { return human === true ? 'HUMAN' : human === false ? 'BOT' : '—'; }
  function escapeHtml(s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  // Keeps headers visible even with zero rows (an italic placeholder row
  // inside the table, never a hidden/replaced table) — an empty scoreboard
  // reads as "not yet", not as broken chrome.
  function rowsTable(rows, cols, rowFn, emptyMsg) {
    const headers = { name: 'Name', team: 'Team', lives: 'Lives', status: 'Status', placement: 'Placement', kd: 'K/D', who: '' };
    let h = '<table><thead><tr>' + cols.map(function (c) { return '<th>' + headers[c] + '</th>'; }).join('') + '</tr></thead><tbody>';
    if (emptyMsg) {
      h += '<tr><td colspan="' + cols.length + '" class="phud-empty">' + emptyMsg + '</td></tr>';
    } else {
      for (let i = 0; i < rows.length; i++) h += '<tr class="' + (rows[i].self ? 'self' : '') + '">' + rowFn(rows[i]) + '</tr>';
    }
    return h + '</tbody></table>';
  }

  // ---------------------------------------------------------------------
  // Main loop
  // ---------------------------------------------------------------------
  let nodes = null, canvasEl = null;
  let prevKills = null, prevSeated = false;
  let cooldownPrevReady = null;
  // Swap#12 item 5 (DUET C: "death of partner = zero acknowledgment, tested").
  // Client-side only -- no engine channel exists for this, so it is derived
  // entirely from playerRows/cogs the client already receives. See
  // trackPartner()/firePartnerPulse() below.
  const PARTNER_PULSE_MS = 1800;
  let partnerWasAlive = null;   // null = unresolved/not-a-duo; true/false once known
  let partnerLastPos = null;    // {x,y} world coords, refreshed every frame the partner's own cog is visible+alive
  let partnerNotified = false;  // one-shot per life; rearmed the moment the partner reads alive again (next round)
  let partnerPulse = null;      // {startAt, expireAt, x, y, color} while the one-time minimap pulse animates
  let partnerToastTimer = null;
  // Found by testing (a live tick-animation check came back silently false):
  // the self-attaching auto-scan loop below and the public update() push API
  // both write the SAME shared render state (prevKills, cooldownPrevReady,
  // the DOM nodes themselves) every frame. Harmless today — nothing in the
  // real client calls update(), so auto-scan is the only writer — but the
  // instant a host DOES call update(), the two race and produce exactly the
  // confusing half-applied result this comment is describing. First real
  // update() call disables auto-scan for the rest of the page's life, so
  // "push mode" is actually usable rather than a documented trap.
  let autoScanEnabled = true;

  function frame() {
    requestAnimationFrame(frame);
    if (!autoScanEnabled) return;
    if (!nodes) return;
    canvasEl = canvasEl || document.getElementById('c');
    const now = performance.now();
    pollRoster(now);

    const raw = scanWire();
    const state = buildState(raw, canvasEl);
    state.dead = prevSeated && !state.seated;
    prevSeated = state.seated;
    render(normalizeState(state), now); // no-op here (buildState's output is always complete) — see normalizeState's own comment for why this guard exists at all
  }

  // ---------------------------------------------------------------------
  // Partner tracking (Swap#12 item 5, DUET) — a duo team is exactly TWO
  // playerRows sharing selfTeam; no numeric seat id ever reaches this
  // module (playerRows only ever carries name/team/lives/kills/deaths/
  // human/self, see buildState above), so "the other row on my team" is
  // both the only signal available AND unambiguous for a duo specifically
  // — a solo (1 row) or squad (>2 rows) team just skips the feature rather
  // than guess who the partner is. deaths>0 = SPLAT is the same one-life
  // BR convention renderScoreboard already uses for the ALIVE/SPLAT column.
  // ---------------------------------------------------------------------
  function trackPartner(state, now) {
    const selfTeam = state.selfTeam;
    if (!selfTeam) return;
    const teamRows = state.playerRows.filter(function (r) { return r.team === selfTeam; });
    if (teamRows.length !== 2) {
      // Not a duo (solo/squad/unresolved roster) — never latch a stale
      // notified/alive flag across a variant this feature doesn't apply to.
      partnerWasAlive = null; partnerLastPos = null; partnerNotified = false;
      return;
    }
    const selfRow = teamRows.filter(function (r) { return r.self; })[0];
    const partnerRow = teamRows.filter(function (r) { return !r.self; })[0];
    if (!selfRow || !partnerRow) return; // which row is "me" is unresolved this frame — wait, don't guess

    // Cache the partner's minimap position every frame their cog is visible
    // and alive. BR is one-life: once they die, the wire is likely to stop
    // sending their cog object at all THIS SAME FRAME the death shows up in
    // playerRows, so "last known position" has to be captured ahead of the
    // death tick, never looked up after it.
    const partnerCog = state.cogs.filter(function (c) { return !c.self && c.color === selfTeam; })[0];
    if (partnerCog && partnerCog.alive !== false) partnerLastPos = { x: partnerCog.x, y: partnerCog.y };

    if (partnerRow.deaths === null) return; // honest unknown wire shape — never fabricate a transition
    const alive = partnerRow.deaths === 0;
    if (alive && partnerWasAlive === false) partnerNotified = false; // partner's back up — new round, rearm
    if (partnerWasAlive === true && !alive && !partnerNotified) {
      partnerNotified = true;
      firePartnerPulse(selfTeam, partnerLastPos, now);
    }
    partnerWasAlive = alive;
  }

  function firePartnerPulse(team, pos, now) {
    const toast = nodes.partnerToast;
    if (toast) {
      toast.textContent = 'YOUR PARTNER IS OUT';
      toast.style.setProperty('--tc', teamColor(team));
      toast.classList.add('show');
      clearTimeout(partnerToastTimer);
      partnerToastTimer = setTimeout(function () { toast.classList.remove('show'); }, 3400);
    }
    if (pos) partnerPulse = { startAt: now, expireAt: now + PARTNER_PULSE_MS, x: pos.x, y: pos.y, color: teamColor(team) };
  }

  function render(state, now) {
    trackPartner(state, now);
    // A — weapon-ready STATUS, fixed in the condition panel (bottom-left),
    // never cursor-anchored — see the CSS block's own comment for the field
    // report this replaced. No seat = nothing to show.
    const cd = nodes.cooldown;
    if (!state.seated || state.fire.ready === null) {
      cd.style.opacity = '0';
      nodes.weaponText.textContent = '—';
    } else {
      cd.style.opacity = '1';
      cd.className = state.fire.ready ? 'ready' : 'cooling';
      nodes.weaponText.textContent = state.fire.ready ? 'READY' : 'COOLING';
      if (state.fire.ready && cooldownPrevReady === false) {
        cd.classList.add('pop'); // it just finished cooling — a real transition, not fabricated progress
        setTimeout(function () { cd.classList.remove('pop'); }, 240);
      }
      cooldownPrevReady = state.fire.ready;
    }

    // F — own condition (health/lives), typographic, no bar chrome.
    if (state.seated && (state.health.hp !== null || state.health.lives !== null)) {
      let hpText = state.health.hp !== null ? state.health.hp + (state.health.maxHp ? '/' + state.health.maxHp : '') + ' hp' : '—';
      if (state.health.shield) hpText += ' +' + state.health.shield + ' shield';
      nodes.hp.textContent = hpText;
      nodes.hp.className = 'phud-num' + (state.health.maxHp && state.health.hp <= Math.ceil(state.health.maxHp * 0.34) ? ' phud-hp-low' : '');
      nodes.lv.textContent = fmtDash(state.health.lives, ' left');
    } else {
      nodes.hp.textContent = '—'; nodes.hp.className = 'phud-num';
      nodes.lv.textContent = '—';
    }
    if (state.combat.buffs.length) {
      nodes.buffWrap.style.display = ''; nodes.buffs.textContent = state.combat.buffs.join(', ');
    } else nodes.buffWrap.style.display = 'none';

    // Top-center — always-on match situation (team score / teams-alive+zone).
    renderTopBar(nodes, state);

    // E — persistent kills/deaths/score, with a restrained tick on real increment.
    setStat(nodes.k, state.combat.kills, function () { return prevKills !== null && state.combat.kills !== null && state.combat.kills > prevKills; });
    prevKills = state.combat.kills;
    nodes.d.textContent = fmtDash(state.combat.deaths);
    // SCORE/RANK tiles stay structurally absent while Glory is undeployed
    // (combat.score/rank null placeholder) and reappear untouched — same
    // text, same markup — the moment the wire starts carrying real values.
    if (state.combat.score !== null && state.combat.score !== undefined) {
      nodes.sc.textContent = fmtDash(state.combat.score);
      nodes.scTile.style.display = '';
    } else {
      nodes.scTile.style.display = 'none';
    }
    if (state.combat.rank) {
      nodes.rk.textContent = state.combat.rank;
      nodes.rkTile.style.display = '';
    } else {
      nodes.rkTile.style.display = 'none';
    }

    // B — minimap (+ BR zone label; qualitative, never a fabricated countdown).
    nodes.miniLabel.textContent = state.zone
      ? 'map · zone ' + (state.zone.shrinking ? 'shrinking' : 'hold')
      : 'map';
    drawMinimap(nodes.mini, canvasEl, state);

    // D — scoreboard visibility + content.
    const open = scoreHeld || scorePinned;
    nodes.score.classList.toggle('open', open);
    if (open) renderScoreboard(nodes, state);
  }
  function setStat(elm, value, didTick) {
    const tick = didTick();
    elm.textContent = fmtDash(value);
    if (tick) { elm.classList.remove('tick'); void elm.offsetWidth; elm.classList.add('tick'); }
  }

  function boot() {
    nodes = mount();
    nodes.toggle.addEventListener('click', function () {
      scorePinned = !scorePinned;
      nodes.toggle.classList.toggle('pinned', scorePinned);
    });
    nodes.scaleToggle.addEventListener('click', function () { cycleHudScale(nodes); });
    requestAnimationFrame(frame);
  }
  if (document.body) boot(); else document.addEventListener('DOMContentLoaded', boot);

  // ---------------------------------------------------------------------
  // Public API — documented push path for a future tighter integration.
  // ---------------------------------------------------------------------
  window.PaintbotHUD = {
    VERSION: '1.0.0',
    // Accepts a state object shaped like buildState()'s return value (see
    // the CONTRACT block up top) and renders it directly, bypassing the
    // auto-scan. Useful for a host-driven push, or a demo/QA harness.
    update: function (state) { autoScanEnabled = false; if (nodes) render(normalizeState(state), performance.now()); },
    attach: function (opts) { if (opts && opts.canvas) canvasEl = opts.canvas; },
    config: { set rosterUrl(v) { roster.url = v; }, get rosterUrl() { return roster.url; } },
    GLORY_RANKS: GLORY_RANKS,
  };
})();
