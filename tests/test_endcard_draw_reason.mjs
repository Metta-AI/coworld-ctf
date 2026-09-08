// Contract: the endcard's win-condition header names a draw's REAL reason
// (mutual wipe vs tick limit) off survivor lives, not off the sim's
// `timeLimit` flag alone. A same-tick race between the sim's generic
// aliveCount==0 check and its maxTicks tiebreak (both funnel through
// finishGame(isDraw=true)) can leave timeLimit=true on a draw that was
// actually a full wipe -- see the 2026-09-07 endcard bug: a real BR
// full-wipe draw's header read "TIME LIMIT — DRAW / time expired before a
// capture" while the hero card correctly said "NO SURVIVORS — every team
// was eliminated" right beneath it.
//
// Run: node --test tests/test_endcard_draw_reason.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

// The source and the checked-in baked bundle carry this function block
// byte-for-byte (tools/build_replay_viewer.sh inlines the source script
// unchanged into static-replay-viewer/index.html) -- load it live from
// EACH file so a fix that lands in one and not the other (a stale served
// bundle) fails loudly here instead of drifting silent.
const PAGES = [
  ['client/replay_broadcast.html', join(root, 'client/replay_broadcast.html')],
  ['static-replay-viewer/index.html (baked bundle)',
    join(root, 'static-replay-viewer/index.html')],
];

function loadEndcardWinCondition(html) {
  const start = html.indexOf('function overLives(o, team) {');
  const end = html.indexOf('function endcardOrder(a, b) {');
  assert.ok(start >= 0, 'overLives() not found');
  assert.ok(end > start, 'endcardOrder() not found after overLives()');
  const sandbox = { PB_MODE: false };
  vm.createContext(sandbox);
  // PB_MODE is the only free variable this slice reads (endcardWinCondition's
  // Paintball branch); everything else (overLives, elimDrawIsWipe) is
  // declared inside the extracted slice itself.
  vm.runInContext(html.slice(start, end), sandbox);
  assert.equal(typeof sandbox.endcardWinCondition, 'function',
    'endcardWinCondition() not found in the extracted slice');
  return sandbox.endcardWinCondition;
}

for (const [label, path] of PAGES) {
  const html = readFileSync(path, 'utf8');
  const endcardWinCondition = loadEndcardWinCondition(html);

  test(label + ': full-wipe BR draw reads NO SURVIVORS, never TIME LIMIT', () => {
    const o = {
      draw: true, timeLimit: true, winner: null,
      teams: { red: { lives: 0 }, blue: { lives: 0 } },
    };
    const chip = endcardWinCondition(o, ['red', 'blue'], /* elim */ true);
    assert.equal(chip, 'NO SURVIVORS');
    assert.ok(!chip.includes('TIME LIMIT'),
      'a mutual wipe (every team at 0 lives) must never read as a time-limit draw');
  });

  test(label + ': tick-limit BR draw with survivors still reads TIME LIMIT', () => {
    const o = {
      draw: true, timeLimit: true, winner: null,
      teams: { red: { lives: 3 }, blue: { lives: 0 } },
    };
    const chip = endcardWinCondition(o, ['red', 'blue'], /* elim */ true);
    assert.equal(chip, 'TIME LIMIT — DRAW');
  });

  test(label + ': classic CTF time-expired draw is unchanged', () => {
    const o = { draw: true, timeLimit: true, winner: null, redLives: 0, blueLives: 0 };
    const chip = endcardWinCondition(o, ['red', 'blue'], /* elim */ false);
    assert.equal(chip, 'TIME LIMIT — DRAW');
  });

  test(label + ': classic CTF non-timelimit draw is still a plain DRAW', () => {
    const o = { draw: true, timeLimit: false, winner: null, redLives: 0, blueLives: 0 };
    const chip = endcardWinCondition(o, ['red', 'blue'], /* elim */ false);
    assert.equal(chip, 'DRAW');
  });
}
