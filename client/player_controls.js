// Season 2 human-seat control translator: keyboard + mouse -> the REAL
// per-tick action space, and nothing else.
//
// THE ACTION SPACE (verified against the engine, not assumed). A seat emits
// exactly one 8-bit button mask per tick plus an optional chat string:
//
//   bit  button  engine effect                                    site
//   ---  ------  ----------------------------------------------  ------------------
//   0x01 up      inputY -= 1 (accelerates, does NOT teleport)     sim.nim applyInput
//   0x02 down    inputY += 1
//   0x04 left    inputX -= 1
//   0x08 right   inputX += 1
//   0x10 select  aim CW:  aimBrads -= aimTurnRate (5)             sim.nim applyInput
//   0x20 attack  RISING EDGE -> startFireWindup; the shot leaves  sim.nim step
//                fireWindupTicks (5) later with the aim LOCKED
//                at the pull. Holding does nothing extra.
//   0x40 b       aim CCW: aimBrads += aimTurnRate (5)             sim.nim applyInput
//   0x80 c       HOLD charges a grenade, RELEASE throws it        sim.nim applyGrenadeInput
//   + chat text  -> sim.applyShout: <=10 printable ASCII, 1/sec   sim.nim applyShout
//
// There is NO sprint bit, no jump, no crouch, no ability key: all eight bits
// are spoken for above and InputState has exactly eight (spriteprotocol.nim).
// That is why Shift binds to nothing here -- see SHIFT below.
//
// Bit values are ButtonUp..ButtonC, spriteprotocol.nim:20-27.
//
// AIM IS DEAD-RECKONED, BY ENGINE MANDATE. Every soldier sprite in a player
// view -- including your own self marker -- renders with a FUZZED aim
// (global.nim:6211-6226, GV24). That comment states the contract outright:
// "your true aim is knowable only from the commands you issued, never from
// the pixels." So we integrate the commands we issue. Picasso's turret does
// the same thing internally (players/picasso/baseline.nim:47-54).

(function (root, factory) {
  const api = factory();
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.CtfControls = api;
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  // ---- engine constants (mirrored; every one traced to a source line) ----
  const BUTTON = {
    up: 0x01, down: 0x02, left: 0x04, right: 0x08,
    select: 0x10, attack: 0x20, b: 0x40, c: 0x80,
  };
  const AIM_BRADS_TURN = 256; // sim.nim:141 AimBradsTurn
  const AIM_TURN_RATE = 5;    // sim.nim:142 AimTurnRate (brads/tick)
  const TICK_HZ = 24;         // sim.nim:21  ReplayFps
  const SHOUT_MAX_CHARS = 10; // sim.nim:205 ShoutMaxChars
  const SHOUT_COOLDOWN_TICKS = 24; // sim.nim:207 ShoutCooldownTicks
  // Half a turn rate: rotating inside this would overshoot and oscillate, so
  // we park. Worst-case steady-state aim error is AIM_DEADZONE-1 = 2 brads.
  const AIM_DEADZONE = 3;
  const CHESS_FILES = 26; // baseline.nim:1019 ChessFiles
  const CHESS_RANKS = 14; // baseline.nim:1020 ChessRanks

  const wrapBrads = (b) => ((b % AIM_BRADS_TURN) + AIM_BRADS_TURN) % AIM_BRADS_TURN;

  // Signed shortest traverse from -> to, in (-128, 128].
  // Positive means COUNTER-CLOCKWISE, which is the `b` button (aimBrads += rate).
  function shortestDelta(from, to) {
    let d = wrapBrads(to - from);
    if (d > AIM_BRADS_TURN / 2) d -= AIM_BRADS_TURN;
    return d;
  }

  // Inverse of the engine's aimVector: 0 = east, increasing CCW, screen y down.
  // Mirrors sim.nim bradsOfVector exactly (including its rounding).
  function bradsOfVector(dx, dy) {
    if (dx === 0 && dy === 0) return 0;
    return wrapBrads(Math.round(Math.atan2(-dy, dx) * (AIM_BRADS_TURN / 2) / Math.PI));
  }

  // Which rotate button traverses shortest toward `desired`? null = park.
  // This is the whole of "mouse aim": there is no analog aim field on the
  // wire (the server decodes and DISCARDS mouse packets, global.nim:1339),
  // so a human aims exactly the way a policy does -- one rotate button/tick.
  function rotateButton(estAim, desiredAim) {
    const d = shortestDelta(estAim, desiredAim);
    if (Math.abs(d) < AIM_DEADZONE) return null;
    return d > 0 ? "b" : "select";
  }

  // Advance the dead-reckoned aim by one applied tick of `button`.
  function stepAim(estAim, button, turnRate) {
    const rate = turnRate === undefined ? AIM_TURN_RATE : turnRate;
    if (button === "b") return wrapBrads(estAim + rate);
    if (button === "select") return wrapBrads(estAim - rate);
    return wrapBrads(estAim);
  }

  // Spawn/respawn aim faces the enemy side. sim.nim:3463-3469.
  const spawnAimBrads = (team) => (team === "blue" ? AIM_BRADS_TURN / 2 : 0);

  // Re-seed the dead-reckoned aim on every FRESH SPAWN, not just the first.
  //
  // The engine resets aimBrads to spawnAimBrads(team) on EVERY respawn
  // (sim.nim respawnPlayers, and again in resetPlayerToHome), so a client that
  // seeded once and kept integrating would carry a silent offset equal to
  // however far the player had turned before dying -- the gun would sit off
  // the cursor by that much for the rest of the life. Nothing on the wire
  // looks wrong when this happens, which is why it needs its own guard.
  //
  // `seated` means our own self marker is on the board. The engine draws it
  // whenever we are alive and never when we are not (global.nim: "yourself is
  // always visible"), so a false->true edge IS a spawn, and fog can never
  // fake one.
  function reseedAim(estAim, seatedNow, wasSeated, team) {
    if (seatedNow && !wasSeated && team) return spawnAimBrads(team);
    return estAim;
  }

  // ---- movement ----
  // WASD chords -> d-pad bits. Opposing keys are BOTH sent: the engine sums
  // them to inputX/inputY = 0, which is a real (and different) state from
  // sending neither -- it still cancels, but we do not silently rewrite the
  // player's input. Diagonals are the natural chord of two bits.
  function moveMask(keys) {
    let m = 0;
    if (keys.up) m |= BUTTON.up;
    if (keys.down) m |= BUTTON.down;
    if (keys.left) m |= BUTTON.left;
    if (keys.right) m |= BUTTON.right;
    return m;
  }

  // ---- fire ----
  // The engine fires on a RISING edge and the shot auto-releases after the
  // windup; holding the button does NOT keep firing. To auto-repeat while the
  // player holds LMB we PULSE the bit -- press one tick, release the next --
  // which is precisely what a policy does. startFireWindup self-guards on
  // canFire and on an in-flight windup (sim.nim:6156-6164), so a pulse that
  // lands during cooldown is simply ignored; we never gain a shot a bot
  // could not also take.
  function fireBit(lmbDown, prevEmittedAttack) {
    if (!lmbDown) return 0;
    return prevEmittedAttack ? 0 : BUTTON.attack;
  }

  // ---- item use (Space) ----
  // Level-triggered straight through: hold charges, release throws.
  // applyGrenadeInput reads input.c and prev.c (sim.nim:6227-6245).
  const itemBit = (spaceDown) => (spaceDown ? BUTTON.c : 0);

  // ---- callouts (1-6) ----
  // Glory is entirely PASSIVE -- src/ctf/glory.nim is pure pricing funcs with
  // no input surface at all -- so the number keys cannot "call" a glory
  // action. They emit standard pings on the shout wire instead, the same
  // channel every bot already shouts on (players/picasso/baseline.nim:8107).
  // Vocabulary is callout-spec.md section 5.
  function pingText(digit, cell) {
    if (!(digit >= 1 && digit <= 6)) return null;
    const body = cell ? "!" + digit + " " + cell : "!" + digit;
    return body.length <= SHOUT_MAX_CHARS ? body : "!" + digit;
  }

  // Map position -> chess cell, the encoding the shipped E-callout already
  // round-trips (baseline.nim:3010-3034). Used by the ping wheel hook.
  function chessCell(x, y, mapWidth, mapHeight) {
    const fx = Math.min(CHESS_FILES - 1, Math.max(0, Math.floor(x * CHESS_FILES / mapWidth)));
    const fy = Math.min(CHESS_RANKS - 1, Math.max(0, Math.floor(y * CHESS_RANKS / mapHeight)));
    return String.fromCharCode(65 + fx) + (fy + 1);
  }

  // ---- the whole mask for one tick ----
  // `state` is what the input layer observed; `prev` is what we EMITTED last
  // tick (not what the user did), because the fire edge is defined on the wire.
  //
  // SHIFT binds to nothing and is absent on purpose. No speed modifier exists
  // anywhere in the engine: the only speed scale in applyInput is
  // carrierSpeedPct, a 70% PENALTY for carrying the heart (sim.nim:140,
  // 6760-6763). All eight input bits are already spoken for. Wiring Shift to
  // a client-side speed change would be a human-only capability no policy
  // could express -- exactly what the governing rule forbids. Shipping it
  // would require a real Season 2 engine mechanic with its own bit.
  function buildMask(state, prev) {
    const p = prev || {};
    let mask = moveMask(state);
    if (state.rotate === "b") mask |= BUTTON.b;
    else if (state.rotate === "select") mask |= BUTTON.select;
    mask |= fireBit(state.fire, p.attack);
    mask |= itemBit(state.item);
    return mask;
  }

  const maskToButtons = (mask) => ({
    up: !!(mask & BUTTON.up), down: !!(mask & BUTTON.down),
    left: !!(mask & BUTTON.left), right: !!(mask & BUTTON.right),
    select: !!(mask & BUTTON.select), attack: !!(mask & BUTTON.attack),
    b: !!(mask & BUTTON.b), c: !!(mask & BUTTON.c),
  });

  // ---- KEYMAP: the single source of truth for any on-screen controls panel ----
  // The app/product lane's re-vendor tripwire reads THIS, so a binding can
  // never drift from what the panel advertises. `bits` names the engine
  // buttons a binding can set; `wire` is "mask" (the per-tick button byte) or
  // "chat" (the shout string). `status` marks anything not live yet.
  const KEYMAP = [
    { id: "move",   label: "Move",          keys: ["W", "A", "S", "D"], alt: ["Arrow keys"],
      wire: "mask", bits: ["up", "left", "down", "right"], status: "live",
      note: "accelerates; a one-tick tap is sub-pixel by design" },
    { id: "aim",    label: "Aim",           keys: ["Mouse"], alt: [],
      wire: "mask", bits: ["b", "select"], status: "live",
      note: "cursor angle drives one rotate button per tick, shortest arc" },
    { id: "fire",   label: "Fire",          keys: ["Left click"], alt: [],
      wire: "mask", bits: ["attack"], status: "live",
      note: "press fires; the shot leaves after a short windup, aim locked at the pull" },
    { id: "item",   label: "Use item",      keys: ["Space"], alt: [],
      wire: "mask", bits: ["c"], status: "live",
      note: "hold to charge a grenade, release to throw" },
    { id: "ping",   label: "Callout",       keys: ["1", "2", "3", "4", "5", "6"], alt: [],
      wire: "chat", bits: [], status: "live",
      note: "team callout at the cursor; one per second" },
    { id: "chat",   label: "Chat",          keys: ["Enter"], alt: [],
      wire: "chat", bits: [], status: "live", note: "" },
    { id: "wheel",  label: "Ping wheel",    keys: ["Right click"], alt: [],
      wire: "chat", bits: [], status: "reserved",
      note: "hook is in place; the wheel UI ships separately" },
    { id: "shift",  label: "(unbound)",     keys: ["Shift"], alt: [],
      wire: null, bits: [], status: "unbound",
      note: "no speed modifier exists in the engine, so Shift binds to nothing" },
  ];

  return {
    BUTTON, KEYMAP, AIM_BRADS_TURN, AIM_TURN_RATE, TICK_HZ, AIM_DEADZONE,
    SHOUT_MAX_CHARS, SHOUT_COOLDOWN_TICKS,
    wrapBrads, shortestDelta, bradsOfVector, rotateButton, stepAim,
    spawnAimBrads, reseedAim, moveMask, fireBit, itemBit, pingText, chessCell,
    buildMask, maskToButtons,
  };
});
