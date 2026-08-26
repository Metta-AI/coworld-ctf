// Per-key PACKET-LEVEL proof for the Season 2 human seat.
//
// Fleet doctrine: a control is not "working" because the client believes it
// sent something. This hooks WebSocket.prototype.send -- the real byte sink --
// so what is counted is what actually left the browser. It includes a NULL
// CONTROL (Shift) that must produce ZERO packets; without a null arm a probe
// like this cannot discriminate a real binding from a phantom one.
//
// Usage: paste into devtools on /client/player, or drive via Playwright:
//   await page.evaluate(<this file>); await page.evaluate('probeControls()')
// Requires an live round (a self marker on the board) for the aim arm.

(function () {
  if (window.__wsHooked) return;
  window.__pkts = [];
  const orig = WebSocket.prototype.send;
  WebSocket.prototype.send = function (data) {
    try {
      const b = new Uint8Array(data);
      window.__pkts.push({
        op: b[0],                                   // 0x84 input mask, 0x81 chat
        mask: b.length > 1 ? b[1] : null,
        text: b[0] === 0x81 ? String.fromCharCode.apply(null, b.slice(3)) : null,
      });
    } catch (e) {}
    return orig.apply(this, arguments);
  };
  window.__wsHooked = true;
})();

window.probeControls = async function () {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const B = CtfControls.BUTTON;
  const key = (t, code) => window.dispatchEvent(new KeyboardEvent(t, { code, bubbles: true }));
  const reset = () => { window.__pkts = []; };
  const inputs = () => window.__pkts.filter((p) => p.op === 0x84);
  const withBit = (bit) => inputs().filter((p) => (p.mask & bit) !== 0).length;

  const probeKey = async (code, bit, name) => {
    await sleep(500); reset();
    key("keydown", code); await sleep(400); key("keyup", code); await sleep(300);
    const pk = inputs();
    return {
      input: name, expectBit: "0x" + bit.toString(16),
      packets: pk.length, packetsWithBit: withBit(bit),
      masksSeen: [...new Set(pk.map((p) => p.mask))],
      strayBits: [...new Set(pk.map((p) => p.mask & ~bit & 0xff))].filter((v) => v !== 0),
      pass: withBit(bit) >= 1 && pk.every((p) => (p.mask & ~bit & 0xff) === 0),
    };
  };

  const out = { movement: [], aim: null, fire: null, item: null, ping: null, nullControl: null };
  for (const [code, bit, name] of [["KeyW", B.up, "W"], ["KeyA", B.left, "A"],
                                   ["KeyS", B.down, "S"], ["KeyD", B.right, "D"]]) {
    out.movement.push(await probeKey(code, bit, name));
  }

  // AIM: sweep the cursor across the map and count rotate bits on the wire.
  await sleep(500); reset();
  if (typeof selfPos !== "undefined" && selfPos) {
    const r = c.getBoundingClientRect();
    window.dispatchEvent(new MouseEvent("mousemove", { bubbles: true,
      clientX: r.left + selfPos.x - 250, clientY: r.top + selfPos.y - 60 }));
    await sleep(1600);
  }
  const ap = inputs();
  out.aim = {
    packets: ap.length, withB: withBit(B.b), withSelect: withBit(B.select),
    bothAtOnce: ap.filter((p) => (p.mask & B.b) && (p.mask & B.select)).length,
    // both-at-once must be 0: applyInput gates on `b != select`, so setting
    // both is a silent no-op turn that costs the player all aim authority.
    pass: (withBit(B.b) + withBit(B.select)) >= 1 &&
          ap.filter((p) => (p.mask & B.b) && (p.mask & B.select)).length === 0,
  };

  // FIRE: the engine fires on a RISING edge, so a held button is ONE shot.
  // Auto-repeat must show as repeated edges in the packet stream.
  await sleep(600); reset();
  c.dispatchEvent(new MouseEvent("mousedown", { button: 0, bubbles: true }));
  await sleep(1400);
  window.dispatchEvent(new MouseEvent("mouseup", { button: 0, bubbles: true }));
  await sleep(300);
  const fp = inputs();
  let edges = 0, prev = false;
  for (const p of fp) { const a = (p.mask & B.attack) !== 0; if (a && !prev) edges++; prev = a; }
  out.fire = { packets: fp.length, withAttack: withBit(B.attack), risingEdges: edges, pass: edges >= 1 };

  // ITEM: the stock client sent `mask & 127`, so bit 0x80 never reached the
  // server and the grenade was unreachable in a browser. Prove it lands now.
  await sleep(600); reset();
  key("keydown", "Space"); await sleep(500);
  const heldC = withBit(B.c);
  key("keyup", "Space"); await sleep(300);
  const ip = inputs();
  out.item = { packets: ip.length, withC: heldC,
               clearedOnRelease: ip.length > 0 && (ip[ip.length - 1].mask & B.c) === 0,
               pass: heldC >= 1 && ip.length > 0 && (ip[ip.length - 1].mask & B.c) === 0 };

  // PING: rides the chat opcode, not the mask.
  await sleep(1200); reset();
  key("keydown", "Digit1"); key("keyup", "Digit1"); await sleep(600);
  const chats = window.__pkts.filter((p) => p.op === 0x81);
  out.ping = { chatPackets: chats.length, texts: chats.map((p) => p.text),
               pass: chats.length === 1 && /^!\d/.test(chats[0].text || "") };

  // NULL CONTROL: Shift binds to nothing, so it must emit NOTHING.
  await sleep(600); reset();
  key("keydown", "ShiftLeft"); await sleep(700); key("keyup", "ShiftLeft"); await sleep(300);
  out.nullControl = { allPackets: window.__pkts.length, pass: window.__pkts.length === 0 };

  out.ALL_PASS = out.movement.every((m) => m.pass) && out.aim.pass && out.fire.pass &&
                 out.item.pass && out.ping.pass && out.nullControl.pass;
  return out;
};
