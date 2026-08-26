// input -> action unit tests for the Season 2 human-seat control translator.
// Run: node client/player_controls.test.js
//
// These assert against the ENGINE's semantics as read out of src/ctf/sim.nim,
// not against the translator's own prose. The companion Nim test
// (tests/test_player_controls.nim) then drives the real SimServer with the
// masks this module produces, so the two ends meet in the middle.

const assert = require("node:assert");
const C = require("./player_controls.js");

let passed = 0;
const test = (name, fn) => {
  try { fn(); passed++; console.log("  ok  " + name); }
  catch (e) { console.error("FAIL  " + name + "\n      " + e.message); process.exitCode = 1; }
};

console.log("\nbit layout (spriteprotocol.nim:20-27)");
test("button bits match the engine's ButtonUp..ButtonC", () => {
  assert.deepStrictEqual(C.BUTTON, {
    up: 1, down: 2, left: 4, right: 8, select: 16, attack: 32, b: 64, c: 128,
  });
});

console.log("\nmovement: WASD chords -> d-pad bits");
test("single keys map to single bits", () => {
  assert.strictEqual(C.moveMask({ up: true }), 1);
  assert.strictEqual(C.moveMask({ down: true }), 2);
  assert.strictEqual(C.moveMask({ left: true }), 4);
  assert.strictEqual(C.moveMask({ right: true }), 8);
});
test("diagonal chord sets both bits (W+D = up|right)", () => {
  assert.strictEqual(C.moveMask({ up: true, right: true }), 1 | 8);
});
test("opposing keys are both forwarded; the engine cancels them to 0", () => {
  // applyInput does inputX -= 1 then inputX += 1 -> 0. We do not pre-filter.
  assert.strictEqual(C.moveMask({ left: true, right: true }), 4 | 8);
});
test("no keys = no movement bits", () => {
  assert.strictEqual(C.moveMask({}), 0);
});

console.log("\naim: shortest-arc traverse toward the cursor");
test("bradsOfVector matches the engine's compass (0=E, 64=N, 128=W, 192=S)", () => {
  assert.strictEqual(C.bradsOfVector(10, 0), 0);    // east
  assert.strictEqual(C.bradsOfVector(0, -10), 64);  // north (screen y is down)
  assert.strictEqual(C.bradsOfVector(-10, 0), 128); // west
  assert.strictEqual(C.bradsOfVector(0, 10), 192);  // south
});
test("shortestDelta wraps the short way around the circle", () => {
  assert.strictEqual(C.shortestDelta(250, 10), 16);   // forward across 0
  assert.strictEqual(C.shortestDelta(10, 250), -16);  // backward across 0
  assert.strictEqual(C.shortestDelta(0, 128), 128);   // exactly opposite
});
test("b is CCW and select is CW, matching applyInput's sign", () => {
  // sim.nim: turn = if input.b: +aimTurnRate else: -aimTurnRate
  assert.strictEqual(C.stepAim(100, "b"), 105);
  assert.strictEqual(C.stepAim(100, "select"), 95);
  assert.strictEqual(C.stepAim(100, null), 100);
});
test("stepAim wraps at the seam in both directions", () => {
  assert.strictEqual(C.stepAim(254, "b"), 3);
  assert.strictEqual(C.stepAim(2, "select"), 253);
});
test("rotateButton picks the shorter arc, never the long way", () => {
  assert.strictEqual(C.rotateButton(0, 20), "b");        // +20 CCW
  assert.strictEqual(C.rotateButton(0, 236), "select");  // -20 CW, not +236
  assert.strictEqual(C.rotateButton(250, 10), "b");      // across the seam
  assert.strictEqual(C.rotateButton(10, 250), "select");
});
test("rotateButton parks inside the deadzone instead of oscillating", () => {
  assert.strictEqual(C.rotateButton(100, 100), null);
  assert.strictEqual(C.rotateButton(100, 102), null); // |d|=2 < rate 5
  assert.strictEqual(C.rotateButton(100, 103), "b");  // |d|=3 -> turn
});
test("a chase converges and then holds still (no limit-cycle jitter)", () => {
  let aim = 0;
  const target = 90;
  for (let i = 0; i < 200; i++) aim = C.stepAim(aim, C.rotateButton(aim, target));
  assert.ok(Math.abs(C.shortestDelta(aim, target)) < C.AIM_DEADZONE,
    "settled at " + aim + " vs target " + target);
  const settled = aim;
  for (let i = 0; i < 20; i++) aim = C.stepAim(aim, C.rotateButton(aim, target));
  assert.strictEqual(aim, settled, "aim must stay parked once inside the deadzone");
});
test("a 180 flick costs ~26 ticks at 5 brads/tick (~1.07s) -- game-feel budget", () => {
  let aim = 0, ticks = 0;
  while (Math.abs(C.shortestDelta(aim, 128)) >= C.AIM_DEADZONE && ticks < 100) {
    aim = C.stepAim(aim, C.rotateButton(aim, 128)); ticks++;
  }
  assert.strictEqual(ticks, 26);
});
test("spawn aim faces the enemy side (sim.nim:3463-3469)", () => {
  assert.strictEqual(C.spawnAimBrads("red"), 0);    // east, toward Blue
  assert.strictEqual(C.spawnAimBrads("blue"), 128); // west, toward Red
});

console.log("\nfire: rising-edge semantics, auto-repeat by pulsing");
test("a fresh click emits the attack bit", () => {
  assert.strictEqual(C.fireBit(true, false), 32);
});
test("holding LMB pulses: the bit drops the tick after it was emitted", () => {
  // The engine fires on `input.attack and not prev.attack`; a held bit is a
  // single shot. Pulsing is how a policy repeats, so it is how we repeat.
  assert.strictEqual(C.fireBit(true, true), 0);
});
test("a held button alternates on/off, giving repeated rising edges", () => {
  let prevAttack = false;
  const emitted = [];
  for (let i = 0; i < 6; i++) {
    const bit = C.fireBit(true, prevAttack);
    emitted.push(bit !== 0);
    prevAttack = bit !== 0;
  }
  assert.deepStrictEqual(emitted, [true, false, true, false, true, false]);
});
test("releasing LMB emits nothing", () => {
  assert.strictEqual(C.fireBit(false, false), 0);
  assert.strictEqual(C.fireBit(false, true), 0);
});

console.log("\nitem use (Space): level-triggered hold-charge / release-throw");
test("Space held sets c; released clears it", () => {
  assert.strictEqual(C.itemBit(true), 128);
  assert.strictEqual(C.itemBit(false), 0);
});
test("a hold-then-release produces the charge..throw edge applyGrenadeInput wants", () => {
  const held = [true, true, true, false];
  const bits = held.map(C.itemBit);
  assert.deepStrictEqual(bits, [128, 128, 128, 0]);
  // prev.c set and input.c clear on the last step == the throw edge.
  assert.ok(bits[2] !== 0 && bits[3] === 0);
});

console.log("\ncallouts (1-6): standard ping vocabulary on the shout wire");
test("bare digits emit !N", () => {
  assert.strictEqual(C.pingText(1), "!1");
  assert.strictEqual(C.pingText(6), "!6");
});
test("a positional ping appends a chess cell", () => {
  assert.strictEqual(C.pingText(2, "F14"), "!2 F14");
});
test("digits outside 1-6 emit nothing", () => {
  assert.strictEqual(C.pingText(0), null);
  assert.strictEqual(C.pingText(7), null);
});
test("every ping fits sanitizeShout's 10-char budget", () => {
  for (let d = 1; d <= 6; d++) {
    for (const cell of ["A1", "Z14", "M7"]) {
      assert.ok(C.pingText(d, cell).length <= C.SHOUT_MAX_CHARS);
    }
  }
});
test("chessCell clamps to the 26x14 grid at both extremes", () => {
  assert.strictEqual(C.chessCell(0, 0, 1235, 665), "A1");
  assert.strictEqual(C.chessCell(1234, 664, 1235, 665), "Z14");
  assert.strictEqual(C.chessCell(99999, 99999, 1235, 665), "Z14");
});

console.log("\nfull per-tick mask");
test("move + rotate + item compose into one mask", () => {
  const mask = C.buildMask(
    { up: true, right: true, rotate: "b", fire: false, item: true }, {});
  assert.strictEqual(mask, 1 | 8 | 64 | 128);
  const b = C.maskToButtons(mask);
  assert.ok(b.up && b.right && b.b && b.c);
  assert.ok(!b.down && !b.left && !b.select && !b.attack);
});
test("rotate is exclusive -- b and select are never both set", () => {
  // applyInput: `if input.b != input.select` -- both set is a no-op turn, so
  // emitting both would silently cost the player their whole aim authority.
  for (const r of ["b", "select", null]) {
    const m = C.buildMask({ rotate: r, fire: false, item: false }, {});
    assert.ok(!((m & C.BUTTON.b) && (m & C.BUTTON.select)));
  }
});
test("Shift binds to nothing: no key can set a ninth bit", () => {
  const m = C.buildMask(
    { up: true, left: true, rotate: "select", fire: true, item: true, shift: true }, {});
  assert.strictEqual(m & ~0xff, 0, "mask must stay inside the 8-bit space");
  // Every bit present is accounted for by a real binding.
  assert.strictEqual(m, 1 | 4 | 16 | 32 | 128);
});
test("the mask never exceeds one byte for any input combination", () => {
  for (let i = 0; i < 64; i++) {
    const m = C.buildMask({
      up: !!(i & 1), down: !!(i & 2), left: !!(i & 4), right: !!(i & 8),
      rotate: (i & 16) ? "b" : "select", fire: !!(i & 32), item: !!(i & 16),
    }, {});
    assert.ok(m >= 0 && m <= 255);
  }
});

console.log("\n" + passed + " passed" + (process.exitCode ? " (with failures)" : ""));
