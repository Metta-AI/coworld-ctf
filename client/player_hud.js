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
     "hp <lit>/<total>[ shield <n>]"          — LabelPrefixHp (overhead, by proximity)
     "identity <color> <greekletter>[ shield][ nade] <weapon>" — LabelPrefixIdentity
     "team score <NAME> <kills>/<deaths>"     — addTeamScoreboard, per team, always sent
     "score <name> <lives> color <n>"         — addScoreboard, per player, teams<=4 ONLY
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
         kills: null,             // ROUTED to realcog (Player.kills exists, sim_types.nim:1402)
         deaths: null,            // ROUTED to realcog (Player.deaths, sim_types.nim:1403)
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
       teamsAlive: null,                          // ROUTED to realcog (teamLivesRemaining(), sim.nim:3198)
       playerRows: [ { name, team, lives: number|null, kills: null, deaths: null,
                        human: bool|null, self: bool } ],
                                                   // lives RESOLVED for CTF (teams<=4) today; BR rows
                                                   // are roster-only today (see D gap). kills/deaths
                                                   // reserved on BOTH — ROUTED to realcog, same fix
                                                   // as the >4-team scoreboard gap.

       roster: { resolved: bool, url: string }
     }

   KNOWN GAPS (told to the orchestrator; repeated here so the code and the
   report can never drift apart):
     - combat.kills / combat.deaths: no per-player field is on the wire YET,
       only the per-team aggregate (useless for attribution once a team has
       more than one seat — duos, BR). CONFIRMED to exist server-side though
       (Player.kills/Player.deaths, sim_types.nim:1402-1403, real attribution
       at the kill/death sites) — a pure emission gap, routed to realcog.
       NOT bridged from the existing damage-pop proximity+engagement-range
       heuristic (that heuristic is a *guess*, already backing the transient
       hitmarker/sound elsewhere) — a persistent, "trust me, I ticked up"
       counter needs real attribution, not a guess dressed as one. Read by
       PREFIX once the label lands (this codebase's convention), not exact
       match — exact prefix TBD from realcog. Everything downstream (the
       tick-emphasis animation, the scoreboard K/D columns) is already built
       against the reserved field; only scanWire()'s TODO block needs a line.
     - combat.score/xp/level/rank/buffs: Glory is not deployed to the field
       yet. Fields are reserved and always render as an honest placeholder.
     - BR (>4 teams) playerRows: addScoreboard's per-player row loop
       hard-returns above 4 teams (src/ctf/global.nim ~4979 — independently
       confirmed by wire-audit), so there is NO live per-player lives/kd on
       the wire in BR today. Routed to realcog (queued behind other work).
       teamsAlive: teamLivesRemaining() (sim.nim:3198) exists but is only
       called from end-card code today — also routed, small emission change.
       Placement itself (sim.brPlacements(), broadcast.nim ~838) stays
       END-CARD ONLY for now. BR rows are roster-only until landed;
       lives/kills/deaths/teamsAlive/placement all render "—" honestly.
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
  // "score <name> <lives> color <n>" — per-player row, teams<=4 ONLY (addScoreboard)
  // Name may itself contain spaces; greedy backtracking on `.+` correctly finds the
  // trailing " <digits> color <digits>" regardless (mirrors how the label is built).
  function parseScoreLabel(label) {
    const m = /^score (.+) (\d+) color (\d+)$/.exec(label);
    return m ? { name: m[1], lives: +m[2] } : null;
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
  // Team color tokens — mirrors player_client.html's TEAM_TINT (own copy so
  // this module has zero coupling to that file beyond the wire Maps).
  // ---------------------------------------------------------------------
  const TEAM_COLOR = { red: '#e0523a', blue: '#3f7cc4', green: '#45a85e', yellow: '#ddc531' };
  function teamColor(word) { return (word && TEAM_COLOR[word]) || '#b7b0a3'; }

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
      zone: null, zoneNext: null,
      // TODO(engine kills/deaths emission, routed to realcog as of 8/29):
      // once a per-player kills/deaths label lands (expected same family as
      // the existing self "lives <hp>hp x<lives>" label — exact prefix TBD,
      // read by prefix per this file's own convention, not exact-match), add
      // one `if (label.indexOf(<prefix>) === 0)` case here setting
      // raw.killsSelf/deathsSelf (own) and/or raw.scoreRows[i].kills/deaths
      // (per-row, CTF+BR), then thread through buildState()'s combat/
      // playerRows construction below — both already have the fields
      // reserved (null) so this is the ONLY edit needed.
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
      if (label.indexOf('score ') === 0) {
        const sc = parseScoreLabel(label);
        if (sc) raw.scoreRows.push(sc); // {name, lives} — kills/deaths reserved, see buildState
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

    // Map + viewport box, from the canvas's own pixel buffer + rendered transform.
    let map = { w: 0, h: 0, viewport: null };
    if (canvasEl && canvasEl.width > 1 && canvasEl.height > 1) {
      map.w = canvasEl.width; map.h = canvasEl.height;
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

    // Player rows: CTF gets real per-player lives off the wire today; BR is
    // roster-only today (see the BR gap note at the top of this file). Both
    // branches reserve kills/deaths (null) NOW so that once realcog's
    // per-player emission lands — routed for both the >4-team scoreboard
    // gap and per-player K/D generally — populating them is a buildState
    // edit only, never a render/layout edit.
    let playerRows = [];
    if (variant === 'ctf') {
      playerRows = raw.scoreRows.map(function (row) {
        const rEntry = roster.resolved ? roster.byName.get(row.name.toLowerCase()) : null;
        const self = isSelfRow(row.name, rEntry);
        return {
          name: row.name, team: rEntry ? rEntry.team : null, lives: row.lives,
          kills: null, deaths: null, // reserved — see TODO in scanWire()
          human: rEntry ? rEntry.person : null, self: self,
        };
      });
    } else if (variant === 'br' && roster.resolved) {
      roster.byName.forEach(function (rEntry) {
        playerRows.push({
          name: rEntry.name, team: rEntry.team, lives: null,
          kills: null, deaths: null, // reserved — see TODO in scanWire()
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
      combat: { kills: null, deaths: null, score: null, xp: null, level: null, rank: null, buffs: [] },
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
      teamsAlive: null, // reserved — teamLivesRemaining() (sim.nim:3198) routed for player-stream emission
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
  // label — principles.md "reserve the primary accent"). Word chrome
  // (eyebrows/headers/toggle) uses the cheat sheet's condensed-sans stack;
  // numerals and table data stay in the existing in-game monospace face
  // (player_client.html's own #hud/#feed use it) for legible tabular digits
  // and player names — a deliberate word-face/number-face split, not a
  // half-applied font swap. No left-border accent stripes anywhere (the
  // hard floor this spec calls out by name against player_client.html's own
  // .wchip) — hairlines run all the way around or not at all.
  // ---------------------------------------------------------------------
  const F_WORD = "'rajdhani','Avenir Next Condensed','Arial Narrow',sans-serif";
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
    + '.phud-panel{background:rgba(10,8,5,.82);border:1px solid rgba(232,163,61,.28);padding:6px 9px;}\n'
    + '.phud-eyebrow{font-family:' + F_WORD + ';font-size:10px;font-weight:700;letter-spacing:.12em;'
    + 'text-transform:uppercase;color:#b8ac98;}\n'
    + '.phud-num{font-family:' + F_NUM + ';font-size:15px;font-weight:700;letter-spacing:.2px;font-variant-numeric:tabular-nums;}\n'
    + '.phud-sub{font-size:10px;color:#b8ac98;letter-spacing:.2px;}\n'
    + '#phud-rail{position:fixed;left:10px;top:9px;display:flex;gap:14px;}\n'
    + '#phud-rail .phud-stat{display:flex;flex-direction:column;gap:1px;min-width:34px;}\n'
    + '#phud-rail .phud-num.tick{animation:phud-tick .42s ease-out;}\n'
    + '@keyframes phud-tick{0%{transform:scale(1);color:#f2e8d8;}30%{transform:scale(1.28);color:#e8a33d;}100%{transform:scale(1);color:#f2e8d8;}}\n'
    + '#phud-cond{position:fixed;left:10px;bottom:8px;display:flex;gap:12px;align-items:baseline;}\n'
    + '#phud-cond .phud-stat{display:flex;flex-direction:column;gap:1px;}\n'
    + '#phud-cond .phud-hp-low{color:#ff6a52;}\n'
    // Crosshair region carries 3 jobs already (reticle + hitmarker, both
    // fix-client3's, both a ~10-14px cross drawn exactly ON the cursor
    // pixel): the readiness pip sits deliberately OFF that footprint, not
    // stacked on it — offset further than a first pass, and a fixed small
    // dot/ring (presence vs absence of glow), never a sweeping/depleting
    // shape (the wire is a boolean ready/not-ready, global.nim:8787 — no
    // numeric remaining-time exists, so no progress idiom is honest here).
    + '#phud-cooldown{position:fixed;left:0;top:0;width:11px;height:11px;margin:-24px 0 0 20px;'
    + 'border-radius:50%;pointer-events:none;transition:opacity .12s;}\n'
    + '#phud-cooldown.ready{background:#e8a33d;box-shadow:0 0 5px #e8a33da0;}\n'
    + '#phud-cooldown.cooling{background:transparent;border:2px solid #8a7f72;opacity:.7;}\n'
    + '#phud-cooldown.pop{animation:phud-pop .22s ease-out;}\n'
    + '@keyframes phud-pop{0%{transform:scale(1.7);}100%{transform:scale(1);}}\n'
    + '#phud-top{position:fixed;left:50%;top:9px;transform:translateX(-50%);display:flex;gap:16px;align-items:baseline;}\n'
    + '#phud-top .t{font-family:' + F_NUM + ';font-size:13px;font-weight:700;letter-spacing:.05em;}\n'
    + '#phud-top .phud-eyebrow{align-self:center;}\n'
    + '#phud-mini-wrap{position:fixed;right:10px;bottom:10px;display:flex;flex-direction:column;align-items:flex-end;gap:5px;}\n'
    + '#phud-mini-wrap .phud-eyebrow{padding-right:2px;}\n'
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
    + '#phud-mini{display:block;image-rendering:pixelated;}\n'
    + '#phud-toggle{pointer-events:auto;cursor:pointer;font-family:' + F_WORD + ';font-size:10px;font-weight:700;letter-spacing:.1em;'
    + 'text-transform:uppercase;color:#b8ac98;background:rgba(13,10,6,.55);border:1px solid rgba(232,163,61,.28);padding:3px 7px;user-select:none;}\n'
    + '#phud-toggle:hover{color:#f2e8d8;}\n'
    + '#phud-toggle.pinned{color:#e8a33d;border-color:rgba(232,163,61,.55);}\n'
    + '#phud-score{position:fixed;left:50%;top:64px;transform:translateX(-50%);min-width:340px;max-width:min(78vw,620px);'
    + 'max-height:min(60vh,520px);overflow:auto;display:none;}\n'
    + '#phud-score.open{display:block;}\n'
    + '#phud-score h2{font-family:' + F_WORD + ';font-size:12px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:#b8ac98;margin:0 0 6px;}\n'
    + '#phud-score table{border-collapse:collapse;width:100%;font-size:12px;}\n'
    + '#phud-score th{text-align:left;font-family:' + F_WORD + ';font-size:10px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;'
    + 'color:#b8ac98;border-bottom:1px solid rgba(232,163,61,.28);padding:3px 8px 4px 0;}\n'
    + '#phud-score td{padding:3px 8px 3px 0;border-bottom:1px solid rgba(232,163,61,.14);white-space:nowrap;}\n'
    + '#phud-score tr.self td{color:#e8a33d;font-weight:700;}\n'
    + '#phud-score .phud-dim{color:#b8ac98;}\n'
    + '#phud-score .phud-empty{color:#8a7f72;font-style:italic;padding:8px 0;}\n'
    ;

  function mount() {
    const style = el('style'); style.textContent = CSS; document.head.appendChild(style);
    const root = el('div'); root.id = 'phud-root';
    root.innerHTML =
      '<div id="phud-top" class="phud-panel" style="display:none"></div>' +
      '<div id="phud-rail" class="phud-panel">' +
      '<div class="phud-stat"><span class="phud-eyebrow">kills</span><span class="phud-num" id="phud-k">—</span></div>' +
      '<div class="phud-stat"><span class="phud-eyebrow">deaths</span><span class="phud-num" id="phud-d">—</span></div>' +
      '<div class="phud-stat"><span class="phud-eyebrow">score</span><span class="phud-num" id="phud-sc">—</span></div>' +
      '<div class="phud-stat"><span class="phud-eyebrow">rank</span><span class="phud-num" id="phud-rk" style="font-size:11px">—</span></div>' +
      '</div>' +
      '<div id="phud-cond" class="phud-panel">' +
      '<div class="phud-stat"><span class="phud-eyebrow">condition</span><span class="phud-num" id="phud-hp">—</span></div>' +
      '<div class="phud-stat"><span class="phud-eyebrow">lives</span><span class="phud-num" id="phud-lv">—</span></div>' +
      '<div class="phud-stat" id="phud-buffwrap" style="display:none"><span class="phud-eyebrow">buffs</span><span class="phud-sub" id="phud-buffs"></span></div>' +
      '</div>' +
      '<div id="phud-cooldown"></div>' +
      '<div id="phud-mini-wrap">' +
      '<div id="phud-toggle">standings · tab</div>' +
      '<div><span class="phud-eyebrow" id="phud-mini-label" style="display:block;text-align:right;margin-bottom:3px;">map</span>' +
      '<div id="phud-mini-frame" class="phud-panel"><canvas id="phud-mini"></canvas></div></div>' +
      '</div>' +
      '<div id="phud-score" class="phud-panel"><div id="phud-score-body"></div></div>';
    document.body.appendChild(root);
    return {
      top: root.querySelector('#phud-top'),
      rail: root.querySelector('#phud-rail'),
      k: root.querySelector('#phud-k'), d: root.querySelector('#phud-d'),
      sc: root.querySelector('#phud-sc'), rk: root.querySelector('#phud-rk'),
      hp: root.querySelector('#phud-hp'), lv: root.querySelector('#phud-lv'),
      buffWrap: root.querySelector('#phud-buffwrap'), buffs: root.querySelector('#phud-buffs'),
      cooldown: root.querySelector('#phud-cooldown'),
      mini: root.querySelector('#phud-mini'),
      miniLabel: root.querySelector('#phud-mini-label'),
      toggle: root.querySelector('#phud-toggle'),
      score: root.querySelector('#phud-score'),
      scoreBody: root.querySelector('#phud-score-body'),
    };
  }

  // ---------------------------------------------------------------------
  // Own cursor tracking, screen space, fully independent of the host's
  // internal (map-space) mouseX/mouseY.
  // ---------------------------------------------------------------------
  let cursorX = innerWidth / 2, cursorY = innerHeight / 2, haveCursor = false;
  addEventListener('mousemove', function (e) { cursorX = e.clientX; cursorY = e.clientY; haveCursor = true; }, { passive: true });

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
  const MINIMAP_MAX_W = 168, MINIMAP_MAX_H = 100;
  let lastMiniDrawAt = 0;
  function drawMinimap(miniCanvas, canvasEl, state) {
    if (!canvasEl || state.map.w < 2 || state.map.h < 2) { miniCanvas.width = 0; miniCanvas.height = 0; return; }
    const now = performance.now();
    if (now - lastMiniDrawAt < 90) return; // throttle, matches the cadence of the prior-art minimap
    lastMiniDrawAt = now;
    const scale = Math.min(MINIMAP_MAX_W / state.map.w, MINIMAP_MAX_H / state.map.h);
    const w = Math.max(1, Math.round(state.map.w * scale)), h = Math.max(1, Math.round(state.map.h * scale));
    if (miniCanvas.width !== w) miniCanvas.width = w;
    if (miniCanvas.height !== h) miniCanvas.height = h;
    const ctx = miniCanvas.getContext('2d');
    ctx.imageSmoothingEnabled = true;
    ctx.clearRect(0, 0, w, h);
    ctx.drawImage(canvasEl, 0, 0, canvasEl.width, canvasEl.height, 0, 0, w, h);
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
    // same-hue splat behind it. Every dot gets a thin dark outline first
    // (regardless of self/bot/human) so it reads as a DOT, not a paint
    // pixel, before any fill/stroke color decision.
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
      ctx.strokeStyle = 'rgba(10,8,5,.9)'; ctx.lineWidth = 1.4; ctx.stroke();
      ctx.beginPath(); ctx.arc(px, py, r, 0, Math.PI * 2);
      if (c.human === false) { // confirmed bot: hollow ring, not filled
        ctx.strokeStyle = col; ctx.lineWidth = 1; ctx.stroke();
      } else { // confirmed human, or unresolved (honest default: filled, slightly dimmer when unknown)
        ctx.fillStyle = col; ctx.globalAlpha *= (c.human === null ? 0.55 : 1); ctx.fill();
      }
    }
    ctx.globalAlpha = 1;
  }

  // ---------------------------------------------------------------------
  // Scoreboard render: CTF vs BR variant, per the wire-derived team count.
  // ---------------------------------------------------------------------
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
      // kills/deaths columns are reserved (always "—" today) — see the
      // TODO in scanWire(): the moment realcog's per-player emission lands,
      // r.kills/r.deaths populate and this table needs no other change.
      html += rowsTable(rows, ['name', 'team', 'lives', 'kd', 'who'], function (r) {
        return '<td>' + escapeHtml(r.name) + '</td>' +
          '<td style="color:' + teamColor(r.team) + '">' + fmtDash(r.team) + '</td>' +
          '<td>' + fmtDash(r.lives) + '</td>' +
          '<td class="phud-dim">' + fmtDash(r.kills) + '/' + fmtDash(r.deaths) + '</td>' +
          '<td class="phud-dim">' + whoText(r.human) + '</td>';
      }, rows.length ? null : 'No standings data yet.');
    } else if (state.variant === 'br') {
      html += '<h2>br · roster · <span class="phud-dim">teams in match: ' + fmtDash(state.teamScores.length) +
        ' · teams alive: ' + fmtDash(state.teamsAlive) + '</span></h2>';
      rows.sort(function (a, b) { return (a.team || '').localeCompare(b.team || ''); });
      // placement is END-CARD ONLY today (sim.brPlacements(), never live) —
      // kills/deaths reserved the same as CTF, both routed to realcog.
      html += rowsTable(rows, ['name', 'team', 'placement', 'kd', 'who'], function (r) {
        return '<td>' + escapeHtml(r.name) + '</td>' +
          '<td style="color:' + teamColor(r.team) + '">' + fmtDash(r.team) + '</td>' +
          '<td class="phud-dim">—</td>' +
          '<td class="phud-dim">' + fmtDash(r.kills) + '/' + fmtDash(r.deaths) + '</td>' +
          '<td class="phud-dim">' + whoText(r.human) + '</td>';
      }, rows.length ? null : (state.roster.resolved ? 'No standings data yet.' : 'Roster unavailable — no /api/field response.'));
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
      nodes.top.innerHTML = state.teamScores.slice()
        .sort(function (a, b) { return b.kills - a.kills; })
        .map(function (t) {
          return '<span class="t" style="color:' + teamColor(t.team.toLowerCase()) + '">' +
            t.team + ' <span class="phud-dim">' + t.kills + '/' + t.deaths + '</span></span>';
        }).join('');
    } else {
      const zoneWord = state.zone ? (state.zone.shrinking ? 'SHRINKING' : 'HOLD') : '—';
      nodes.top.innerHTML =
        '<span class="phud-eyebrow">teams alive</span><span class="t">' + fmtDash(state.teamsAlive) +
        ' <span class="phud-dim">/ ' + fmtDash(state.teamScores.length) + '</span></span>' +
        '<span class="phud-eyebrow">zone</span><span class="t">' + zoneWord + '</span>';
    }
  }
  function whoText(human) { return human === true ? 'HUMAN' : human === false ? 'BOT' : '—'; }
  function escapeHtml(s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  // Keeps headers visible even with zero rows (an italic placeholder row
  // inside the table, never a hidden/replaced table) — an empty scoreboard
  // reads as "not yet", not as broken chrome.
  function rowsTable(rows, cols, rowFn, emptyMsg) {
    const headers = { name: 'Name', team: 'Team', lives: 'Lives', placement: 'Placement', kd: 'K/D', who: '' };
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
  let lastCooldownX = null, lastCooldownY = null;
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

  function render(state, now) {
    // A — fire cooldown, screen-cursor-anchored. No seat = nothing to show.
    // Position writes are ROUNDED and SKIPPED-WHEN-UNCHANGED on purpose: the
    // black-bars root cause elsewhere in this client was a per-rAF transform
    // write with sub-pixel drift onto a pixelated-rendering element — this
    // is the same class of element (screen-fixed, small, would show banding
    // under fractional positions), so it gets the same discipline even
    // though left/top (not transform) is the property here.
    const cd = nodes.cooldown;
    if (!state.seated || state.fire.ready === null || !haveCursor) {
      cd.style.opacity = '0';
    } else {
      cd.style.opacity = '1';
      const cx = Math.round(cursorX), cy = Math.round(cursorY);
      if (cx !== lastCooldownX || cy !== lastCooldownY) {
        cd.style.left = cx + 'px'; cd.style.top = cy + 'px';
        lastCooldownX = cx; lastCooldownY = cy;
      }
      cd.className = state.fire.ready ? 'ready' : 'cooling';
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
    nodes.sc.textContent = fmtDash(state.combat.score);
    nodes.rk.textContent = state.combat.rank ? state.combat.rank : '—';

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
