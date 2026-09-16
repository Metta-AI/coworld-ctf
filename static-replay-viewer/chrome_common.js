'use strict';
// chrome_common.js — the replay chrome shared 1:1 by the broadcast client
// (replay_broadcast.html) and the League Replayer shell (league_replayer.html):
// team identity/naming, the clock, the transport bar (buttons/speed chips/
// scrubber), beat markers, lull shading, the beats timeline + verdict, and the
// momentum graph. Both pages instantiate it at the top of their IIFE and alias
// the returned functions to their old local names, so the per-view code
// (board rendering, killfeed, endcard, walls, KDA tables) is untouched.
//
// Served three ways, mirroring wire_constants (this file is inlined into a
// script tag, so it must never contain the literal splice marker or a script
// close tag):
//  - native server: staticRead + spliced over the CHROME_COMMON marker in
//    both embedded pages (src/ctf/server.nim);
//  - static WASM bundle: copied into dist/ and loaded via a script src
//    (Dockerfile.replay-viewer sed's the marker);
//  - raw file:// opens of the source HTML have NO splice — the pages guard the
//    instantiation and fail with a clear console error (same non-functional
//    baseline replay_broadcast.html already had without BROADCAST_CORE).
//
// window.ChromeCommon(ctx) -> object of shared functions + constants.
// ctx fields (each required unless noted):
//  - send(cmd):    deliver a transport command char ('.', 'b', '1'…'8', '6',
//                  's:<tick>'-style strings NOT included — plain chars only
//                  here; pages keep their own seek path) to the playback
//                  channel. Broadcast sends over its websocket; the league
//                  shell postMessages it down to the embedded board.
//  - sendPov(slot): select the POV lens for a join slot (-1 clears). The two
//                  pages transport this differently (broadcast: 'v:'+slot
//                  command; league: a dedicated postMessage), hence its own hook.
//  - getState():   the latest parsed state frame (or null before the first
//                  frame). Read lazily by togglePov and renderMomentum.
//  - holdCaption(s): OPTIONAL. Given the gameover-phase state, return a
//                  caption string to show under FINAL, or null/undefined for
//                  the default 'Game over'. The league shell uses it for the
//                  looping-hold countdown ('Replaying in Ns').
//
// UI toggles: chrome-level toggles read their initial value from the page URL
// (uiToggle below), so whatever launches a replay can preconfigure the chrome.
// Current params: ?spoilers=0|1 — future kills / flag story / winner / momentum
// past the playhead on the scrubber (default 1, the classic broadcast chrome).
window.ChromeCommon = function (ctx) {
  var $ = function (id) { return document.getElementById(id); };

  // ---- palette (mirrors board tints so chrome matches the arena) ----
  // Read from the live CSS custom properties (:root --red/--blue/--amber/
  // --paper/--green/--yellow) via getComputedStyle instead of a second
  // hardcoded copy of the token hexes -- this file draws canvas/SVG chrome
  // (scorebug, momentum graph, beat markers) that needs literal color
  // values, not a var() reference, so without this read a CSS token retune
  // could silently drift three viewers' canvas chrome out of sync with
  // their own HTML/CSS. The literals stay ONLY as the file:// fallback
  // (no spliced <style> block to read a property from), so a raw open's
  // behaviour is unchanged.
  var rootStyle = getComputedStyle(document.documentElement);
  function cssTok(name, fallback) {
    var v = rootStyle.getPropertyValue(name);
    v = v && v.trim();
    return v || fallback;
  }
  var RED = cssTok('--red', '#e0523a'),
    BLUE = cssTok('--blue', '#3f7cc4'),
    AMBER = cssTok('--amber', '#e8a33d'),
    PAPER = cssTok('--paper', '#f2e8d8');
  var GREEN = cssTok('--green', '#45a85e'),
    YELLOW = cssTok('--yellow', '#ddc531');

  // ---- teams (2-4, data-driven) --------------------------------------------
  // The chrome renders whatever teams the state frame carries, in this
  // canonical display order: index 0/2 seat on the LEFT of the clock, 1/3 on
  // the RIGHT — so classic red/blue keeps its exact old layout and a 4-team
  // game reads red+green vs blue+yellow. Colors must stay in sync with the
  // CSS --red/--blue/--green/--yellow team utility classes.
  // Both tables come from the ENGINE via window.CTF_WIRE (wire_constants.nim
  // derives them from the Team enum). The literals below are the file://
  // fallback this file has always kept for un-spliced opens — and they are
  // exactly what the engine emits for these four, so a spliced page and a
  // raw open agree to the byte.
  //
  // They used to be the only table, which meant a 16-team BR board drew
  // twelve of its teams in the fallback amber: the scoreboard could not tell
  // plum from azure from lime. Deriving them fixes that class, not just this
  // instance — a 17th team would arrive here with a colour already.
  var WIRE_EARLY = window.CTF_WIRE || {};
  var TEAM_ORDER = WIRE_EARLY.teamOrder ||
    ['red', 'blue', 'green', 'yellow'];
  var TEAM_COLOR = WIRE_EARLY.teamColors ||
    { red: RED, blue: BLUE, green: GREEN, yellow: YELLOW };
  function teamCol(team) { return TEAM_COLOR[team] || null; }
  function activeTeams(s) {
    var keys = (s && s.teams) ? Object.keys(s.teams) : [];
    if (!keys.length) return ['red', 'blue'];
    keys.sort(function (a, b) {
      var ia = TEAM_ORDER.indexOf(a), ib = TEAM_ORDER.indexOf(b);
      ia = ia < 0 ? TEAM_ORDER.length : ia;
      ib = ib < 0 ? TEAM_ORDER.length : ib;
      return ia - ib || (a < b ? -1 : a > b ? 1 : 0);
    });
    return keys;
  }

  // Engine-authoritative wire constants (spliced by the server / static
  // bundle); the literals are fallbacks for raw file:// opens only.
  var WIRE = window.CTF_WIRE || {};
  var SPEEDS = WIRE.speeds || [1, 2, 3, 4, 8, 16];
  var FPS = WIRE.fps || 24;
  // Speed -> the one-character command that selects it. Lives here, beside
  // SPEEDS, because it is now read twice: the chip row below builds its
  // buttons from it, and replay_broadcast's ?speed= opt-in resolves against
  // it. 16 maps to '6' because the command channel is one character wide.
  var SPEED_CMD = { 1: '1', 2: '2', 3: '3', 4: '4', 8: '8', 16: '6' };

  // ---- UI toggles (externally configurable) --------------------------------
  // Chrome-level UI toggles read their initial value from the page URL, so
  // whatever triggers a replay can preconfigure the chrome by appending query
  // params (works on both the broadcast client and the league shell, native
  // or static bundle). Accepted values: 1/0, true/false, on/off, yes/no;
  // anything else keeps the default. Pages can also flip a toggle at runtime
  // through the returned setters.
  function uiToggle(name, dflt) {
    var raw = null;
    try { raw = new URLSearchParams(location.search).get(name); } catch (e) {}
    if (raw == null) return dflt;
    raw = String(raw).toLowerCase();
    if (raw === '1' || raw === 'true' || raw === 'on' || raw === 'yes') return true;
    if (raw === '0' || raw === 'false' || raw === 'off' || raw === 'no') return false;
    return dflt;
  }

  // [spoilers] — whether story beats AHEAD of the playhead are visible before
  // playback gets there: scrubber kill/flag markers, the winner cap + WINS
  // chip, and the momentum curve past the playhead. ON (default) preserves
  // the classic broadcast chrome (full flag story + verdict placed up front);
  // OFF keeps the timeline clean of anything the viewer hasn't watched yet
  // and reveals it as the playhead advances. URL: ?spoilers=0 starts hidden.
  var spoilers = uiToggle('spoilers', true);
  function getSpoilers() { return spoilers; }
  function setSpoilers(on) {
    spoilers = !!on;
    var b = $('btn-spoilers');
    if (b) b.classList.toggle('on', spoilers);
    var s = ctx.getState();
    if (s) applySpoilers(s);
  }
  // Optional [spoilers] transport button (pages that carry #btn-spoilers).
  (function () {
    var b = $('btn-spoilers');
    if (!b) return;
    b.classList.toggle('on', spoilers);
    b.addEventListener('click', function () { setSpoilers(!spoilers); });
  })();

  // ---- viewer identity ("this one is me") -----------------------------------
  // The owner watches replays of a league he's IN and can't pick his own cog
  // out of 16 — the scorebug prints SOFTMAXWELL same as everyone else, but
  // nothing on the board says "that one's you." ?me=<name> names the viewer
  // against roster[].name (case/whitespace-insensitive: names get typed by
  // hand into a URL bar). Persisted to localStorage under a dedicated key so
  // it survives clicking into the NEXT replay without retyping — ?me= with
  // no value clears it, same as leaving the param off keeps whatever's
  // stored. Unset or no roster match: callers below return nothing, so the
  // whole feature costs zero on every replay that never asks for it.
  var ME_STORAGE_KEY = 'ctf.chrome.me';
  var meName = (function () {
    var raw = null;
    try { raw = new URLSearchParams(location.search).get('me'); } catch (e) {}
    if (raw === null) {
      try { return (localStorage.getItem(ME_STORAGE_KEY) || '').trim(); } catch (e) { return ''; }
    }
    var trimmed = raw.trim();
    try {
      if (trimmed) localStorage.setItem(ME_STORAGE_KEY, trimmed);
      else localStorage.removeItem(ME_STORAGE_KEY);
    } catch (e) {}
    return trimmed;
  })();
  function getMe() { return meName; }
  function isMe(name) {
    return !!meName && String(name || '').trim().toLowerCase() === meName.toLowerCase();
  }
  // Roster array-INDEX positions (NOT join slot `.s`) matching the viewer —
  // the same sim.players-INDEX keying pushDownedSeatsToCore/learnSeats
  // already use for the rig object pool (RIG_HEAD_OBJECT_BASE + index), so
  // a page can hand this straight to core.setMeSeats(...) with no extra
  // lookup. Duos can seat the same name twice, so every match comes back,
  // not just the first. Pure function of the frame's own roster — nothing
  // cached, so resetEpisode has nothing to clear here.
  function meSeatIndices(s) {
    if (!meName || !s || !s.roster) return [];
    var out = [];
    for (var i = 0; i < s.roster.length; i++) {
      if (s.roster[i] && isMe(s.roster[i].name)) out.push(i);
    }
    return out;
  }

  // ---- names ---------------------------------------------------------------
  function stripSeatSuffix(name) {
    // Strip the per-seat " (N)" suffix the hosted runtime appends to the SAME
    // policy's multiple connections ("softmaxwell (2)", "softmaxwell (7)"…) so
    // every seat of one policy collapses to a single shared identity. The join
    // path converts spaces to underscores, so the separator usually reads
    // "_(N)" by the time it is a player address. The killfeed shows the full
    // per-seat name (it colors names per event and never compares them).
    // Distinct local self-play names (Player1, Player2) carry no such suffix,
    // so they stay distinct.
    return String(name || '').replace(/[\s_]*\(\d+\)\s*$/, '');
  }

  function teamPolicies(s, team) {
    // The distinct policy identities seated on a team, in join-slot order.
    // Prefer the server's own list (state.teams[team].policies); derive from
    // the roster's per-seat policy (p.pol, falling back to a name strip) when
    // a frame predates it.
    var tr = s.teams && s.teams[team];
    if (tr && tr.policies && tr.policies.length) return tr.policies;
    var seen = [];
    (s.roster || []).forEach(function (p) {
      if (p.team !== team) return;
      var pol = p.pol != null ? p.pol : stripSeatSuffix(p.name);
      if (pol && seen.indexOf(pol) < 0) seen.push(pol);
    });
    return seen;
  }

  function teamName(s, team, fallback) {
    // The scorebug headline is the POLICY name, not the color (the plate color +
    // board already say which side is which). In a hosted league a side seats
    // one policy — show it — or, in CTF-Doubles, exactly two: headline BOTH
    // ("A + B"). Local self-play seats a distinct bot per seat (3+ "policies"),
    // which carries no shared identity, so fall back to the color label rather
    // than pinning the team to one arbitrary bot.
    var pols = teamPolicies(s, team);
    if (pols.length === 1 && pols[0]) return teamHeadline(pols[0]);
    if (pols.length === 2) {
      return teamHeadline(pols[0]) + ' + ' + teamHeadline(pols[1]);
    }
    return fallback;
  }
  function teamHeadline(n) {
    // Format a policy identity for the scorebug headline: drop any host:port
    // suffix, restore the spaces the server encodes as underscores, and let the
    // plate's CSS ellipsis clip anything still too wide (no hard char cut, so a
    // full name reads whole when it fits).
    n = String(n || '');
    var at = n.indexOf('@'); if (at > 0) n = n.slice(0, at);
    n = n.replace(/_/g, ' ').trim();
    return (n || '?').toUpperCase();
  }
  function setName(id, txt) { var el = $(id); if (el.textContent !== txt) el.textContent = txt; }

  // Per-team handicap badge. The chrome carries teams[team].hcap ONLY for a
  // handicapped team, with the deltas already resolved server-side (the sim is
  // the single source of the interpolation), so here we just format: `h` is the
  // authored fraction in permille, `spd` a percent of base speed, `miss` a
  // percent of point-blank shots dropped. Returns null for an unhandicapped
  // team so the caller hides the badge.
  function handicapInfo(s, team) {
    var tr = s && s.teams && s.teams[team];
    var h = tr && tr.hcap;
    if (!h || !h.h) return null;
    var pct = Math.round(h.h / 10);
    return {
      text: 'HCP ' + pct + '%',
      title: 'Handicap ' + pct + '% — HP ' + h.hp0 + '→' + h.hp +
        ' · Lives ' + h.lives0 + '→' + h.lives +
        ' · Speed ' + h.spd + '% · Miss ' + h.miss + '%'
    };
  }
  // Update a badge element in place: text is the compact "HCP 60%", the native
  // `title` is the full delta breakdown on hover (the codebase's one tooltip
  // idiom). Hidden entirely when the team is unhandicapped.
  function setHandicap(id, s, team) {
    var el = $(id); if (!el) return;
    var info = handicapInfo(s, team);
    if (!info) {
      if (el.style.display !== 'none') el.style.display = 'none';
      if (el.title) el.title = '';
      if (el.textContent) el.textContent = '';
      return;
    }
    if (el.style.display === 'none') el.style.display = '';
    if (el.textContent !== info.text) el.textContent = info.text;
    if (el.title !== info.title) el.title = info.title;
  }

  // ---- perks ---------------------------------------------------------------
  // Team perk badges (docs/plans/2026-08-07-team-perks-design.md). The sim
  // resolves a seat's perks at join and ships them per roster seat as `pk`
  // (wire names); every seat of one policy shares a set, so a team's badges
  // group by policy. Each perk keeps ONE fixed color on every plate — the
  // icon identifies the perk, the plate identifies the team — so the badges
  // are never team-tinted. Tooltips state the perk name plus its resolved
  // magnitude from the frame's `pmods` (permille ints, sim-resolved).
  var PERK_ICONS = {
    armor: { color: '#9aa7b8', svg:
      '<svg viewBox="0 0 16 16" fill="currentColor">' +
      '<path d="M8 1l6 2v5c0 3.7-2.6 6.3-6 7.5C4.6 14.3 2 11.7 2 8V3l6-2z"/>' +
      '</svg>' },
    scope: { color: '#f2e8d8', svg:
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6">' +
      '<circle cx="8" cy="8" r="4.6"/>' +
      '<path d="M8 .8V4M8 12v3.2M.8 8H4M12 8h3.2"/>' +
      '<circle cx="8" cy="8" r="1.2" fill="currentColor" stroke="none"/>' +
      '</svg>' },
    grenade: { color: '#8a9a5b', svg:
      '<svg viewBox="0 0 16 16" fill="currentColor">' +
      '<rect x="6" y="2.2" width="4" height="3"/>' +
      '<path d="M10 3.2h2.6v1.6H10z"/>' +
      '<circle cx="8" cy="10" r="5"/>' +
      '</svg>' },
    thruster: { color: '#e8a33d', svg:
      '<svg viewBox="0 0 16 16" fill="currentColor">' +
      '<path d="M8 .8C9.8 3.6 13 5.8 13 9.6a5 5 0 0 1-10 0C3 5.8 6.2 3.6 8 .8z"/>' +
      '<path d="M8 15.4a2.6 2.6 0 0 1-2.6-2.6C5.4 11 7 9.8 8 8.6c1 1.2 2.6 2.4 2.6 4.2A2.6 2.6 0 0 1 8 15.4z" fill="rgba(0,0,0,0.35)"/>' +
      '</svg>' },
    luck: { color: '#45a85e', svg:
      '<svg viewBox="0 0 16 16" fill="currentColor">' +
      '<circle cx="5.4" cy="5.4" r="2.8"/><circle cx="10.6" cy="5.4" r="2.8"/>' +
      '<circle cx="5.4" cy="10.6" r="2.8"/><circle cx="10.6" cy="10.6" r="2.8"/>' +
      '<path d="M8.6 8.6c.6 2.2 1.6 3.8 3 5.2l-1.2 1.2C9 13.6 8 11.8 7.4 9.8z"/>' +
      '</svg>' }
  };
  // Defaults mirror the engine's perkMods defaults; used only when a frame
  // predates `pmods` so a tooltip never reads blank.
  var PERK_MOD_DEFAULTS = {
    armorHp: 1, scope: 500, grenade: 250, thruster: 100,
    luck: 100, luckDamage: 2
  };
  function pct(permille) { return Math.round(permille / 10) + '%'; }
  function perkTitle(name, mods) {
    // "scope - +50% accuracy" — the perk name plus its resolved magnitude.
    var m = mods || PERK_MOD_DEFAULTS;
    function v(key) { return m[key] != null ? m[key] : PERK_MOD_DEFAULTS[key]; }
    switch (name) {
      case 'armor': return 'armor - +' + v('armorHp') + ' hp';
      case 'scope': return 'scope - +' + pct(v('scope')) + ' accuracy';
      case 'grenade': return 'grenade - +' + pct(v('grenade')) + ' throw range';
      case 'thruster': return 'thruster - +' + pct(v('thruster')) + ' speed';
      case 'luck': return 'luck - ' + pct(v('luck')) + ' of shots deal ' +
        v('luckDamage') + ' damage';
      default: return name;
    }
  }
  var warnedPerks = {};
  function perkIconsHtml(perks, mods) {
    // The badge strip markup for one perk list (wire names). An unknown name
    // is skipped but warned once: the client ships with the engine (splice /
    // bundle), so a name this table doesn't know is a PerkNames drift, not
    // version skew — silence would hide a perk that alters gameplay with no
    // badge at all.
    var html = '';
    (perks || []).forEach(function (p) {
      var ico = PERK_ICONS[p];
      if (!ico) {
        if (!warnedPerks[p]) {
          warnedPerks[p] = true;
          try { console.warn('scorebug: unknown perk name "' + p + '"'); } catch (e) {}
        }
        return;
      }
      html += '<span class="perk-ico" style="color:' + ico.color + '" title="' +
        esc(perkTitle(p, mods)) + '">' + ico.svg + '</span>';
    });
    return html;
  }
  function teamPerkGroups(s, team) {
    // One entry per distinct policy seated on `team`, in join-slot order:
    // {pol, perks, lives, players}. `lives` uses the squad-pip rule (p.lives
    // counts SPARE respawns; the current life is the alive flag), so the two
    // split meters always sum to the team numeral. Every seat of one policy
    // shares its perk set, so the policy's first seat carries the badges;
    // `players` is the group's roster seats in join-slot order.
    var groups = [], byPol = {};
    (s.roster || []).filter(function (p) { return p.team === team; })
      .sort(function (a, b) { return a.s - b.s; })
      .forEach(function (p) {
        var pol = p.pol != null ? p.pol : stripSeatSuffix(p.name);
        var g = byPol[pol];
        if (!g) {
          g = byPol[pol] = { pol: pol, perks: p.pk || [], lives: 0, players: [] };
          groups.push(g);
        }
        g.lives += (p.lives || 0) + (p.alive ? 1 : 0);
        g.players.push(p);
      });
    return groups;
  }
  function renderTeamMeters(el, s, team) {
    // Renders one team's life meter(s) + perk badges into `el` (a plate's
    // `.meters` slot; used by the league shell — the broadcast client's
    // meter is its squad-pip strip). Single policy (or pre-roster): the
    // classic "Lives N" team meter with the badges beyond the numeral, and
    // the el gains class `single` so a page may mirror that one case.
    // CTF-Doubles (exactly two policies): one meter per policy in the
    // headline's policy order, fixed DOM order `icons,num | num,icons`, so
    // the two numerals sit adjacent at the cluster's center with each
    // policy's badges flanking outside its own numeral — no side-dependent
    // CSS. Three or more distinct policies (local self-play) fall back to
    // the single team meter and show NO badges: per-policy sets can differ
    // there, and badging the whole team with one policy's set would lie.
    // Persistent-DOM discipline: rebuild only when the group shape changes,
    // update numerals in place every frame.
    var tr = s.teams && s.teams[team];
    var groups = teamPerkGroups(s, team);
    var split = groups.length === 2;
    // Exactly one policy may badge the team meter; 3+ shows none (see above).
    var badged = groups.length === 1 ? groups[0].perks : [];
    var key = split
      ? 'split:' + groups.map(function (g) {
          return g.pol + '=' + g.perks.join('+');
        }).join('|')
      : 'single:' + badged.join('+');
    if (el._key !== key) {
      el.classList.toggle('single', !split);
      var html;
      if (split) {
        html =
          '<span class="pgrp">' +
          '<span class="perk-icos">' + perkIconsHtml(groups[0].perks, s.pmods) + '</span>' +
          '<span class="lives-num sub" title="' + esc(groups[0].pol) + '"></span>' +
          '</span>' +
          '<span class="pgrp">' +
          '<span class="lives-num sub" title="' + esc(groups[1].pol) + '"></span>' +
          '<span class="perk-icos">' + perkIconsHtml(groups[1].perks, s.pmods) + '</span>' +
          '</span>';
      } else {
        html =
          '<span class="lives-label">Lives</span>' +
          '<span class="lives-num"></span>' +
          (badged.length
            ? '<span class="perk-icos">' + perkIconsHtml(badged, s.pmods) + '</span>'
            : '');
      }
      el.innerHTML = html;
      el._key = key;
    }
    var nums = el.querySelectorAll('.lives-num');
    if (split) {
      for (var i = 0; i < 2; i++) {
        var t = tr ? String(groups[i].lives) : '—';
        if (nums[i] && nums[i].textContent !== t) nums[i].textContent = t;
      }
    } else if (nums[0]) {
      // '—' until the frame actually carries this team's entry (a pre-roster
      // frame would otherwise read as a real 0).
      var txt = tr ? String(tr.lives || 0) : '—';
      if (nums[0].textContent !== txt) nums[0].textContent = txt;
    }
  }

  function rosterName(s, slot) {
    if (!s.roster) return '#' + slot;
    for (var i = 0; i < s.roster.length; i++) {
      if (s.roster[i].s === slot) return s.roster[i].name || ('#' + slot);
    }
    return '#' + slot;
  }
  function teamOf(s, slot) {
    if (slot < 0 || !s.roster) return null;
    for (var i = 0; i < s.roster.length; i++) if (s.roster[i].s === slot) return s.roster[i].team;
    return null;
  }
  // HTML-escape for innerHTML-built rows. Escapes [&<>"] — the double-quote
  // matters because callers interpolate names into attribute values too.
  function esc(t) { return String(t).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }

  // ---- POV lens ------------------------------------------------------------
  function togglePov(slot) {
    var s = ctx.getState();
    if (s && s.pov === slot) ctx.sendPov(-1);
    else ctx.sendPov(slot);
  }

  // ---- clock ---------------------------------------------------------------
  function fmt(sec) {
    sec = Math.max(0, Math.round(sec));
    var m = Math.floor(sec / 60), r = sec % 60;
    return m + ':' + (r < 10 ? '0' : '') + r;
  }
  function renderClock(s) {
    var timeEl = $('clock-time'), capEl = $('clock-caption'), clk = $('clock');
    if (s.ph === 'lobby') {
      timeEl.textContent = s.lob > 0 ? (':' + (s.lob < 10 ? '0' : '') + s.lob) : '--';
      capEl.textContent = s.lob > 0 ? 'Starting in' : 'Waiting for players';
      clk.classList.remove('tiebreak-warn');
    } else if (s.ph === 'gameover') {
      timeEl.textContent = 'FINAL';
      // ctx.holdCaption may supply a live caption during the server's
      // end-segment hold (the league shell mirrors the board end-card's
      // "Replaying in Ns" countdown); default reads Game over.
      capEl.textContent = (ctx.holdCaption && ctx.holdCaption(s)) || 'Game over';
      clk.classList.remove('tiebreak-warn');
    } else {
      // Playing: an HONEST countdown to the scheduled draw limit, not to the
      // replay's end. The game is scheduled to end at absolute tick st + mt
      // (gameStartTick + maxTicks, the scoreless-draw ceiling); the clock counts
      // down to that. A game decided early by a capture or wipe FREEZES the
      // clock at whatever was left and flips to FINAL — so a nonzero freeze
      // reads as "ended it early", and only a genuine grind to the limit ever
      // reaches 0:00. (Old behavior pinned the end to mx = the replay's last
      // tick, so every game counted to zero and the race-to-zero was an
      // artifact.) When no limit is configured (mt <= 0) there is no scheduled
      // end to count toward, so fall back to the replay span.
      var end = (s.mt && s.mt > 0) ? ((s.st || 0) + s.mt) : s.mx;
      var remain = Math.max(0, (end - s.t)) / FPS;
      timeEl.textContent = fmt(remain);
      capEl.textContent = 'Time left';
      clk.classList.toggle('tiebreak-warn', remain <= 30);
    }
  }

  // ---- speed chips ---------------------------------------------------------
  // Built here (both pages carry an identical #speedchips host + the identical
  // speed→command map); clicks go down the page's own command channel.
  var speedChipEls = {};
  (function () {
    var host = $('speedchips'), map = SPEED_CMD;
    SPEEDS.forEach(function (v) {
      var b = document.createElement('button');
      b.className = 'chip';
      b.textContent = v + '×';
      b.setAttribute('aria-label', v + 'x speed');
      b.addEventListener('click', function () { if (map[v]) ctx.send(map[v]); });
      host.appendChild(b);
      speedChipEls[v] = b;
    });
  })();

  // ---- transport -----------------------------------------------------------
  function renderTransport(s) {
    $('transport').classList.toggle('disabled', !s.en);
    $('btn-play').textContent = s.pl ? '❘❘' : '▶';
    $('btn-loop').classList.toggle('on', !!s.lp);
    $('btn-skip').classList.toggle('on', !!s.sk);
    $('ffwd-chip').classList.toggle('show', !!s.ff);
    $('ffwd-mini').classList.toggle('show', !!s.ff);

    // speed chips
    SPEEDS.forEach(function (sp) { var b = speedChipEls[sp]; if (b) b.classList.toggle('on', sp === s.sp); });

    // scrubber. The x-axis skips the dead lobby: it spans [startTick, maxTick]
    // so tick 0 on-screen is the first frame of actual play, not "WAITING FOR
    // PLAYERS". All the derived geometry (fill, head, clock, beats, momentum)
    // shares this offset origin.
    var st = Math.max(0, s.st || 0);
    var mx = Math.max(st + 1, s.mx || 1);
    var span = mx - st;
    var frac = Math.min(1, Math.max(0, (s.t - st) / span));
    $('scrub-fill').style.width = (frac * 100) + '%';
    $('scrub-head').style.left = (frac * 100) + '%';
    $('tick-clock').textContent = Math.max(0, s.t - st) + ' / ' + span;

    renderBeatMarkers(st, mx);
    renderLullSpans(st, mx);
    renderMomentum();
    applySpoilers(s);
  }

  // ---- [spoilers] gate ------------------------------------------------------
  // Runs every transport render (same synchronous pass, so no flash of
  // spoiled chrome before the gate lands). With spoilers ON everything is
  // visible — identical to the classic chrome. With spoilers OFF, anything
  // that tells the story past the playhead is held back: beat markers ahead
  // of the current tick (including kill markers left stranded ahead after a
  // backward scrub), the verdict cap/chip until the game-over beat, and the
  // momentum curve past the playhead (clipped, so it still reveals 1:1 as
  // playback advances).
  function applySpoilers(s) {
    for (var i = 0; i < markerEls.length; i++) {
      var el = markerEls[i];
      var hide = !spoilers && el.__tick > s.t;
      if (el.__hidden !== hide) {
        el.__hidden = hide;
        el.style.display = hide ? 'none' : '';
      }
    }
    applyVerdict(s);
    if (momClipRect) {
      var st = Math.max(0, s.st || 0);
      var mx = Math.max(st + 1, s.mx || 1);
      var frac = spoilers ? 1 : Math.min(1, Math.max(0, (s.t - st) / (mx - st)));
      var w = (frac * VBW).toFixed(1);
      if (momClipRect.getAttribute('width') !== w) momClipRect.setAttribute('width', w);
    }
  }

  // ---- scrubber lull shading (spans shipped once; rendered once) -----------
  // The lull spans ride the same first HUD frame as the lead series. Cache them
  // once; the scrubber shades them so "the grayed stretches are what ▸▸ skips"
  // is visible before ever toggling the mode.
  var lullSpans = null;      // full-match [[a,b]] quiet spans, shipped once
  var lullsRendered = false;
  function ingestLullSpans(s) {
    if (!s.lulls || lullSpans) return;
    lullSpans = s.lulls;
  }
  function renderLullSpans(st, mx) {
    if (!lullSpans || lullsRendered) return;
    lullsRendered = true;
    var span = Math.max(1, mx - st);
    var box = $('lulls');
    lullSpans.forEach(function (p) {
      var el = document.createElement('div');
      el.className = 'lull-span';
      var a = Math.min(1, Math.max(0, (p[0] - st) / span));
      var b = Math.min(1, Math.max(0, (p[1] - st) / span));
      el.style.left = (a * 100) + '%';
      el.style.width = ((b - a) * 100) + '%';
      box.appendChild(el);
    });
  }

  // ---- scrubber beat markers -----------------------------------------------
  var scrubEl = $('scrub');
  var seenMarkers = {};      // tick|kind -> marker (dedup)
  var pendingMarkers = [];
  var markerEls = [];        // placed marker elements (spoiler gate re-checks these)
  function markBeat(tick, kind, team) {
    var mk = tick + '|' + kind;
    if (seenMarkers[mk]) return;
    seenMarkers[mk] = { tick: tick, kind: kind, team: team || '' };
    pendingMarkers.push(seenMarkers[mk]);
  }
  // A kill tick is colored by the KILLER's team; a team-kill or an
  // unattributable same-tick pileup stays honestly neutral.
  function killMarkerTeam(e, s) {
    if (e.amb || e.tk || e.killer < 0) return '';
    return teamOf(s, e.killer) || '';
  }
  function renderBeatMarkers(st, mx) {
    if (!pendingMarkers.length) return;
    var span = Math.max(1, mx - st);
    pendingMarkers.forEach(function (m) {
      var el = document.createElement('div');
      el.className = 'beat-marker ' + m.kind + (m.team ? ' ' + m.team : '');
      el.style.left = (Math.min(1, Math.max(0, (m.tick - st) / span)) * 100) + '%';
      el.__tick = m.tick;
      markerEls.push(el);
      scrubEl.appendChild(el);
    });
    pendingMarkers = [];
  }

  // ---- full-match flag beats + verdict (shipped once; placed up front) -----
  // The full-match flag beats + verdict ride the same first HUD frame: place
  // every steal/return/capture marker and the winner cap up front, so the
  // scrubber tells the flag story (and how it ends) before playback gets
  // there. Kill markers stay accumulate-as-played — dozens of them up front
  // would bury the flag beats. markBeat dedups by tick|kind, so the live
  // events re-firing over these is harmless.
  var beatTimeline = null;
  function otherTeam(t) { return t === 'red' ? 'blue' : t === 'blue' ? 'red' : ''; }
  function captureTeam(s, e) {
    // The CAPTURING team: the capturer's own team when the roster can name it,
    // else (two-team frames without a `by` slot) the flag's opponent.
    var byTeam = e.by != null ? teamOf(s, e.by) : null;
    return byTeam || otherTeam(e.flag);
  }
  function ingestBeats(s) {
    if (!s.beats || beatTimeline) return;
    beatTimeline = s.beats;
    for (var i = 0; i < beatTimeline.length; i++) {
      var b = beatTimeline[i];
      if (b.k === 'steal' || b.k === 'return') markBeat(b.t, b.k, b.flag);
      else if (b.k === 'capture') markBeat(b.t, 'capture', captureTeam(s, b));
      else if (b.k === 'gameover') setVerdict(b);
    }
  }

  // Winner cap + "RED WINS" chip. Fed by the up-front beat timeline, and as a
  // fallback by the game-over state (older servers that ship no beats still
  // get the verdict once playback reaches the end). Idempotent. Visibility is
  // spoiler-gated: with spoilers off the verdict stays hidden until the
  // playhead reaches the game-over beat (or the phase itself goes gameover,
  // which also covers verdicts that arrive without a tick).
  var verdict = null;        // {cls, label, tick|null} once known
  function setVerdict(v) {
    var cls = v.draw ? 'draw' : (v.winner || '');
    if (!cls) return;
    if (!verdict) {
      verdict = {
        cls: cls,
        label: v.draw ? 'DRAW' : v.winner.toUpperCase() + ' WINS',
        tick: v.t != null ? v.t : null
      };
    }
    applyVerdict(ctx.getState());
  }
  function applyVerdict(s) {
    if (!verdict) return;
    var show = spoilers ||
      (s && (s.ph === 'gameover' || (verdict.tick != null && s.t >= verdict.tick)));
    var cap = $('scrub-win');
    cap.className = 'scrub-win ' + (show ? 'show ' : '') + verdict.cls;
    cap.title = verdict.label;
    var chip = $('win-chip');
    chip.textContent = verdict.label;
    chip.className = 'win-chip ' + (show ? 'show ' : '') + verdict.cls;
  }

  // ---- momentum graph (GLORY over the WHOLE timeline) ---------------------
  // One team-colored step line per team on the SAME 0→maxTicks x-axis as the
  // seek track, so a point's x IS its tick. The metric is GLORY: it is the
  // score, and unlike lives it only ever climbs, so the lane reads as a RACE
  // off a shared floor — the leader is simply the taller line — rather than a
  // two-sided tug of war around a midline. (A signed differential would make
  // the trailing team read as NEGATIVE, which glory never is.) Samples are
  // keyed by tick (dedup) and accumulate for the whole replay — NOT a scrolling
  // window — so the curve stays put while only the playhead moves across it.
  var VBW = 1000, VBH = 100, MID = 50; // SVG viewBox (preserveAspectRatio:none)
  var MOM_SVGNS = 'http://www.w3.org/2000/svg';
  var momentumSeen = {};            // tick -> true (dedup)
  var momentumDirty = true;         // rebuild the path only when a new tick lands
  var fullLeadSeries = null;        // full-match {teams, pts} shipped once by the server
  var momentumSamples = [];         // accumulate-as-played fallback samples
  var momentumTeams = null;         // team list backing the accumulated samples
  var momClipRect = null;           // spoiler clip: curve visible up to this width

  // The server ships the full-match glory change-point series ONCE (on the
  // first HUD frame). Cache it so the momentum graph draws its whole-timeline
  // shape immediately, with the playhead riding across a curve that's already
  // there — a broadcast win-probability graph, not a line that grows as it plays.
  function ingestLeadSeries(s) {
    if (!s.lead || fullLeadSeries) return;
    if (Array.isArray(s.lead)) {
      // Legacy shape: [[tick, redVal - blueVal], …] — a two-team signed diff,
      // from bundles that predate the team-keyed series. Only this shape still
      // draws the old midline graph; see the isDiff branch in renderMomentum.
      fullLeadSeries = {
        teams: ['red', 'blue'],
        isDiff: true,
        pts: s.lead.map(function (p) { return { t: p[0], vals: [p[1]] }; })
      };
    } else {
      // Team-keyed shape: {metric, teams, out: [tick|-1…], pts: [[tick, value…]…]}.
      fullLeadSeries = {
        teams: s.lead.teams || ['red', 'blue'],
        metric: s.lead.metric || 'glory',
        out: s.lead.out || [],
        isDiff: false,
        pts: (s.lead.pts || []).map(function (p) {
          return { t: p[0], vals: p.slice(1) };
        })
      };
    }
    labelMomentum(fullLeadSeries.metric);
    momentumDirty = true;
  }
  // The band names what it is plotting. The server says which metric the
  // series carries; a bundle too old to say is glory, the classic default.
  // (This used to be hardcoded "LIVES LEAD" in each viewer's markup, which
  // went stale the moment KotH started shipping hill ticks through the same
  // field.)
  var MOMENTUM_LABELS = { glory: 'GLORY', hill: 'HILL TICKS' };
  function labelMomentum(metric) {
    var el = document.querySelector('.momentum-label');
    if (el) el.textContent = MOMENTUM_LABELS[metric] || MOMENTUM_LABELS.glory;
  }
  function recordMomentum(s) {
    if (fullLeadSeries) return;     // full curve already known; nothing to accumulate
    if (s.ph !== 'playing' && s.ph !== 'gameover') return;
    if (momentumSeen[s.t]) return;  // deterministic replay: a tick's glory is fixed
    momentumSeen[s.t] = true;
    var teams = activeTeams(s);
    var tr = s.teams || {};
    momentumTeams = teams;
    momentumSamples.push({
      t: s.t,
      vals: teams.map(function (team) {
        return (tr[team] && tr[team].glory) || 0;
      })
    });
    momentumDirty = true;
  }
  function renderMomentum() {
    var el = $('momentum');
    // Prefer the full precomputed series (spans the WHOLE timeline from frame 1);
    // fall back to accumulate-as-you-play only if the server didn't ship it.
    var norm = fullLeadSeries ||
      { teams: momentumTeams || ['red', 'blue'], isDiff: false, pts: momentumSamples };
    var samples = norm.pts;
    var lastState = ctx.getState();
    if (!lastState || !samples.length) { if (!samples.length) el.innerHTML = ''; return; }
    if (!momentumDirty && el.childNodes.length) return; // nothing new to draw
    momentumDirty = false;
    // Share the scrubber's trimmed [startTick, maxTick] axis so the momentum
    // curve lines up 1:1 with the playhead (the lobby prefix is flat/even and
    // carries no signal, so dropping it just removes dead leading space).
    var st = Math.max(0, lastState.st || 0);
    var mx = Math.max(st + 1, lastState.mx || 1);
    function xOf(t) { return Math.min(1, Math.max(0, (t - st) / (mx - st))) * VBW; }
    var pts = samples.slice().sort(function (a, b) { return a.t - b.t; });

    el.setAttribute('viewBox', '0 0 ' + VBW + ' ' + VBH);
    el.innerHTML = '';
    // dark backing so the graph reads against a consistent ground, not the
    // flagstone floor showing through the transport gradient.
    var bg = document.createElementNS(MOM_SVGNS, 'rect');
    bg.setAttribute('x', 0); bg.setAttribute('y', 0);
    bg.setAttribute('width', VBW); bg.setAttribute('height', VBH);
    bg.setAttribute('fill', 'rgba(11,7,4,0.55)');
    el.appendChild(bg);

    // The graph itself draws into a clipped layer so the spoilers gate can
    // trim the curve at the playhead (applySpoilers drives the rect width
    // every transport render; full width when spoilers are on). The backing
    // rect stays unclipped so the band keeps a consistent ground either way.
    var clipDefs = document.createElementNS(MOM_SVGNS, 'defs');
    clipDefs.innerHTML = '<clipPath id="momclip"><rect x="0" y="0" width="' +
      VBW + '" height="' + VBH + '"/></clipPath>';
    el.appendChild(clipDefs);
    momClipRect = clipDefs.firstChild.firstChild;
    var layer = document.createElementNS(MOM_SVGNS, 'g');
    layer.setAttribute('clip-path', 'url(#momclip)');
    el.appendChild(layer);

    function stepPath(valueOf, subset) {
      // A step series across the full [0, mx] axis: hold, then step. `subset`
      // narrows it to one team's alive stretch; it defaults to the whole
      // series (note: do NOT shadow `pts` here, the outer series is the
      // default and the closure is the only thing holding it).
      var d = '';
      var series = subset || pts;
      for (var k = 0; k < series.length; k++) {
        var x = xOf(series[k].t), y = valueOf(series[k]);
        if (k === 0) d += 'M ' + x.toFixed(1) + ' ' + y.toFixed(1);
        else d += ' H ' + x.toFixed(1) + ' V ' + y.toFixed(1);
      }
      return d;
    }
    function addPath(d, stroke, width, opacity, fill) {
      var p = document.createElementNS(MOM_SVGNS, 'path');
      p.setAttribute('d', d);
      p.setAttribute('fill', fill || 'none');
      if (stroke) {
        p.setAttribute('stroke', stroke);
        p.setAttribute('stroke-width', width);
        p.setAttribute('stroke-opacity', opacity);
        p.setAttribute('vector-effect', 'non-scaling-stroke');
      } else {
        p.setAttribute('stroke', 'none');
      }
      layer.appendChild(p);
    }

    if (norm.isDiff) {
      // LEGACY bundles only: a pre-computed two-team signed difference is all
      // we have, so it can only be drawn the old way — a single step line
      // around a midline, shaded in the leading team's color above/below.
      var colTop = teamCol(norm.teams[0]) || RED;
      var colBot = teamCol(norm.teams[1]) || BLUE;
      var diffOf = function (m) { return norm.isDiff ? m.vals[0] : m.vals[0] - m.vals[1]; };
      // Auto-scale each side of the midline on its OWN extreme so the biggest
      // lead touches the band edge while 0 stays pinned at MID, keeping the
      // shading split honest. Floor at 1 so a dead-even match never divides
      // by zero.
      var maxPos = 1, maxNeg = 1;
      pts.forEach(function (m) {
        var d = diffOf(m);
        if (d > maxPos) maxPos = d;
        if (-d > maxNeg) maxNeg = -d;
      });
      var yOf = function (m) {
        var d = diffOf(m);
        return d >= 0
          ? MID - (d / maxPos) * (MID - 2)
          : MID + (-d / maxNeg) * (MID - 2);
      };
      var defs = document.createElementNS(MOM_SVGNS, 'defs');
      // Split fill: first team above the midline, second below — one gradient,
      // hard stop. userSpaceOnUse so the 50/50 split lands exactly on y=MID.
      defs.innerHTML =
        '<linearGradient id="momfill" gradientUnits="userSpaceOnUse" ' +
          'x1="0" y1="0" x2="0" y2="' + VBH + '">' +
        '<stop offset="0%" stop-color="' + colTop + '" stop-opacity="0.8"/>' +
        '<stop offset="50%" stop-color="' + colTop + '" stop-opacity="0.28"/>' +
        '<stop offset="50%" stop-color="' + colBot + '" stop-opacity="0.28"/>' +
        '<stop offset="100%" stop-color="' + colBot + '" stop-opacity="0.8"/>' +
        '</linearGradient>';
      el.appendChild(defs);
      // even-lives midline
      var mid = document.createElementNS(MOM_SVGNS, 'line');
      mid.setAttribute('x1', 0); mid.setAttribute('y1', MID);
      mid.setAttribute('x2', VBW); mid.setAttribute('y2', MID);
      mid.setAttribute('stroke', 'rgba(242,232,216,0.22)');
      mid.setAttribute('stroke-width', '0.8');
      layer.appendChild(mid);
      var line = stepPath(yOf);
      // Shaded area drops from the line to the midline and closes back.
      var lastX = xOf(pts[pts.length - 1].t);
      var area = line + ' L ' + lastX.toFixed(1) + ' ' + MID +
        ' L ' + xOf(pts[0].t).toFixed(1) + ' ' + MID + ' Z';
      addPath(area, null, 0, 0, 'url(#momfill)');
      addPath(line, PAPER, '1.5', '0.95');
    } else {
      // THE LANE: one team-colored glory line per team on a shared 0..peak
      // scale with zero pinned to the lane bottom — every team climbing from
      // the same floor, so the leader is just the taller line. Works the same
      // for two teams as for sixteen. Scaling on the running peak rather than
      // the final value keeps a curve on-scale even where the ledger dips
      // (penalties), instead of clipping it against the top of the band.
      //
      // ELIMINATED TEAMS STOP LOOKING LIKE COMPETITORS. The metric only ever
      // climbs, so a team that is out goes FLAT — pixel-identical to a live
      // team that just is not scoring. A high flat line from a team knocked
      // out early therefore reads as the leader, which is exactly backwards,
      // and it misread that way in practice. So each line is drawn solid only
      // while its team is alive, ends in a filled cap at the elimination
      // tick, and continues to the right edge as a faint dashed hold. The
      // final total stays readable — often the biggest number on the board —
      // while "still in this" is legible at a glance.
      // The GLORY LEDGER CAN GO NEGATIVE -- penalties outrun earnings on a
      // team that does little else (measured on the 16-team golden fixture:
      // a final total of -60). Displayed values clamp at >= 0 so such a line
      // rides the axis instead of being drawn below the lane and clipped
      // away by the viewBox; the scorebug numeral remains the authoritative
      // figure. Lives and hill ticks cannot go negative, so this only ever
      // bites glory.
      var peak = 1;
      pts.forEach(function (m) {
        m.vals.forEach(function (v) { if (v > peak) peak = v; });
      });
      // LOGARITHMIC, because glory is heavy-tailed and MULTIPLICATIVE.
      // Achievements multiply and heat chains multiply, so totals spread over
      // orders of magnitude: a live 16-duo episode had a top seat on 16,588
      // against a median of 6, ~2700x. Scaled linearly to the peak that puts
      // every other team under 1% of the band -- the whole lane is a flat
      // line with one riser, which is exactly how it read in the field.
      //
      // Measured across the same live totals, band height per team:
      //          16,588   864     96     12      1
      //   linear   100%   5.2%   0.6%   0.1%   0.0%   <- unreadable
      //   share     94%   4.9%   0.5%   0.1%   0.0%   <- leader eats the pot
      //   rank     100%  93.3%  86.7%  60.0%  33.3%   <- magnitude thrown away
      //   log      100%  69.6%  47.1%  26.4%   7.1%   <- every tier separated
      //
      // On this axis equal vertical distance is equal MULTIPLE, which is the
      // honest reading of a quantity built by multiplication. log1p keeps
      // zero at the floor (log1p(0) = 0) and, with the >= 0 clamp above, a
      // negative ledger lands there too instead of off the bottom of the band.
      var logPeak = Math.log1p(peak);
      var base = document.createElementNS(MOM_SVGNS, 'line');
      base.setAttribute('x1', 0); base.setAttribute('y1', VBH - 2);
      base.setAttribute('x2', VBW); base.setAttribute('y2', VBH - 2);
      base.setAttribute('stroke', 'rgba(242,232,216,0.22)');
      base.setAttribute('stroke-width', '0.8');
      layer.appendChild(base);
      var outTicks = norm.out || [];
      norm.teams.forEach(function (team, ti) {
        var col = teamCol(team) || PAPER;
        var yOfTeam = function (m) {
          return (VBH - 2) -
            (Math.log1p(Math.max(0, m.vals[ti] || 0)) / logPeak) * (VBH - 4);
        };
        var outTick = typeof outTicks[ti] === 'number' ? outTicks[ti] : -1;
        if (outTick < 0) {                       // survived: one solid line
          addPath(stepPath(yOfTeam), col, '1.5', '0.9');
          return;
        }
        // Alive stretch: every change-point up to elimination, plus the value
        // it held AT that tick so the line reaches its true end, not the last
        // point before it.
        var alive = pts.filter(function (m) { return m.t <= outTick; });
        if (!alive.length) alive = [pts[0]];
        var endY = yOfTeam(alive[alive.length - 1]);
        var endX = xOf(outTick);
        addPath(stepPath(yOfTeam, alive) +
          ' H ' + endX.toFixed(1), col, '1.5', '0.9');
        // The stop itself. A VERTICAL TICK, not a dot: this lane is drawn
        // with preserveAspectRatio="none", so the viewBox is scaled
        // differently in x and y and a circle comes out as a squashed,
        // near-invisible ellipse. A tick's height is viewBox units and its
        // width is a non-scaling stroke, so it reads the same at any lane
        // size -- and it matches the beat-marker language on the seek track
        // right above it.
        var cap = document.createElementNS(MOM_SVGNS, 'line');
        cap.setAttribute('x1', endX.toFixed(1));
        cap.setAttribute('x2', endX.toFixed(1));
        cap.setAttribute('y1', Math.max(0, endY - 4).toFixed(1));
        cap.setAttribute('y2', Math.min(VBH, endY + 4).toFixed(1));
        cap.setAttribute('stroke', col);
        cap.setAttribute('stroke-width', '1.5');
        cap.setAttribute('stroke-opacity', '0.9');
        cap.setAttribute('vector-effect', 'non-scaling-stroke');
        layer.appendChild(cap);
        // Dead hold: the total stays legible, the line stops competing.
        var hold = document.createElementNS(MOM_SVGNS, 'path');
        hold.setAttribute('d', 'M ' + endX.toFixed(1) + ' ' + endY.toFixed(1) +
          ' H ' + VBW);
        hold.setAttribute('fill', 'none');
        hold.setAttribute('stroke', col);
        hold.setAttribute('stroke-width', '1.5');
        hold.setAttribute('stroke-opacity', '0.3');
        hold.setAttribute('stroke-dasharray', '3 4');
        hold.setAttribute('vector-effect', 'non-scaling-stroke');
        layer.appendChild(hold);
      });
    }
  }

  // ---- episode-transition reset --------------------------------------------
  // A live spectator page can outlive its episode: when the next episode's
  // server takes over the same URL, broadcast_core reconnects the SAME page
  // to a DIFFERENT match. Everything in this closure that latches "once per
  // match" (the up-front beat timeline, the verdict chip, the momentum
  // series, the lull spans, placed scrubber markers) must be re-derived from
  // the incoming stream, or the old episode's chrome plays over the new one
  // — the owner's live screenshot: CTF markers + red/blue momentum over a
  // 16-duo battle royale, "fixed" only by a manual refresh. The pages call
  // this from their reconnect hook; a refresh IS this reset, done by hand.
  function resetEpisode() {
    lullSpans = null;
    lullsRendered = false;
    var lullBox = $('lulls');
    if (lullBox) lullBox.innerHTML = '';
    seenMarkers = {};
    pendingMarkers = [];
    // Sweep by class, not only the tracked divs: the paintball block's
    // labelled buttons share the scrubber and the .beat-marker class.
    if (scrubEl) {
      var stale = scrubEl.querySelectorAll('.beat-marker');
      for (var i = 0; i < stale.length; i++) {
        if (stale[i].parentNode) stale[i].parentNode.removeChild(stale[i]);
      }
    }
    markerEls = [];
    beatTimeline = null;
    verdict = null;
    var cap = $('scrub-win');
    if (cap) cap.className = 'scrub-win';
    var chip = $('win-chip');
    if (chip) { chip.textContent = ''; chip.className = 'win-chip'; }
    momentumSeen = {};
    momentumDirty = true;
    fullLeadSeries = null;
    momentumSamples = [];
    momentumTeams = null;
    momClipRect = null;
    var mom = $('momentum');
    if (mom) mom.innerHTML = '';
  }

  return {
    // constants + helpers the pages alias locally
    $: $,
    RED: RED, BLUE: BLUE, AMBER: AMBER, PAPER: PAPER, GREEN: GREEN, YELLOW: YELLOW,
    TEAM_ORDER: TEAM_ORDER, TEAM_COLOR: TEAM_COLOR,
    WIRE: WIRE, SPEEDS: SPEEDS, FPS: FPS, SPEED_CMD: SPEED_CMD,
    // shared chrome
    teamCol: teamCol, activeTeams: activeTeams, teamOf: teamOf, otherTeam: otherTeam,
    stripSeatSuffix: stripSeatSuffix, teamPolicies: teamPolicies, teamName: teamName,
    teamHeadline: teamHeadline, rosterName: rosterName, setName: setName,
    handicapInfo: handicapInfo, setHandicap: setHandicap,
    perkIconsHtml: perkIconsHtml, teamPerkGroups: teamPerkGroups,
    renderTeamMeters: renderTeamMeters,
    esc: esc, fmt: fmt, togglePov: togglePov,
    renderClock: renderClock, renderTransport: renderTransport,
    ingestLullSpans: ingestLullSpans, renderLullSpans: renderLullSpans,
    markBeat: markBeat, killMarkerTeam: killMarkerTeam, renderBeatMarkers: renderBeatMarkers,
    captureTeam: captureTeam, ingestBeats: ingestBeats, setVerdict: setVerdict,
    resetEpisode: resetEpisode,
    ingestLeadSeries: ingestLeadSeries, recordMomentum: recordMomentum,
    renderMomentum: renderMomentum,
    // UI toggles ([spoilers] + the generic URL-param reader for future ones)
    uiToggle: uiToggle, getSpoilers: getSpoilers, setSpoilers: setSpoilers,
    // viewer identity ("this one is me")
    getMe: getMe, isMe: isMe, meSeatIndices: meSeatIndices
  };
};
