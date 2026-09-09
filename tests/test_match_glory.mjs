// Contract: the endcard's MATCH GLORY tier line is SCALE-FREE (closeness of
// the final standings + how many times the lead changed hands), never an
// absolute glory floor — the old fork's table (2000/2300/2600/3100) died the
// moment the S2 economy retuned: glory today reaches 9.15 quadrillion with
// no cap and has measured NEGATIVE (-60), so any fixed threshold is wrong by
// construction. Also covers the glory odometer's target-parts formatter
// (gloryOdometerParts): sign/unit held static, only the mantissa counts up.
//
// Scoped to client/replay_broadcast.html (the SOURCE) only, not the checked-
// in static-replay-viewer/index.html bundle: that bundle is a pre-existing,
// deliberately-NOT-rebuilt build artifact (one bundle rebuild happens later,
// across several branches at once) and predates this feature entirely.
//
// Run: node --test tests/test_match_glory.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const pagePath = join(root, 'client/replay_broadcast.html');

function loadMatchGlorySlice(html) {
  const start = html.indexOf("var GLORY_UNITS = ['k', 'M', 'B', 'T', 'Q'];");
  const end = html.indexOf('function teamGloryOf(o, team) {');
  assert.ok(start >= 0, 'GLORY_UNITS not found');
  assert.ok(end > start, 'teamGloryOf() not found after GLORY_UNITS');
  const sandbox = {};
  vm.createContext(sandbox);
  vm.runInContext(html.slice(start, end), sandbox);
  for (const name of ['matchGloryMargin', 'matchGloryLeadChanges', 'matchGloryTier', 'gloryOdometerParts', 'gloryText']) {
    assert.equal(typeof sandbox[name], 'function', name + '() not found in the extracted slice');
  }
  return sandbox;
}

const html = readFileSync(pagePath, 'utf8');
const { matchGloryMargin, matchGloryLeadChanges, matchGloryTier, gloryOdometerParts, gloryText } =
  loadMatchGlorySlice(html);

test('matchGloryMargin: dead-even totals read as 0, a total blowout reads as 1', () => {
  assert.equal(matchGloryMargin([1000, 1000]), 0);
  assert.equal(matchGloryMargin([1000, 0]), 1);
  assert.ok(matchGloryMargin([1000, 900]) > 0 && matchGloryMargin([1000, 900]) < 1);
});

test('matchGloryMargin: scale-free under a x1e6 multiply on every total', () => {
  const totals = [4123, 3990, 1200, -60];
  const scaled = totals.map((v) => v * 1e6);
  assert.equal(matchGloryMargin(scaled), matchGloryMargin(totals));
});

test('matchGloryMargin: handles an all-negative field (measured: glory can go to -60)', () => {
  const m = matchGloryMargin([-10, -60]);
  assert.ok(Number.isFinite(m) && m >= 0 && m <= 1, 'must be a finite ratio, not NaN/Infinity');
});

test('matchGloryMargin: fewer than two real totals reads as a runaway (1), never a crash', () => {
  assert.equal(matchGloryMargin([500]), 1);
  assert.equal(matchGloryMargin([]), 1);
  assert.equal(matchGloryMargin(null), 1);
});

test('matchGloryLeadChanges: counts identity flips, not raw magnitude swings', () => {
  // red leads, then blue overtakes, then red retakes: 2 changes.
  const series = {
    teams: ['red', 'blue'],
    pts: [
      { t: 0, vals: [0, 0] },     // kickoff, all-zero: no leader yet
      { t: 1, vals: [10, 0] },    // red establishes the lead (not a "change")
      { t: 2, vals: [20, 5] },    // red still leads: no change
      { t: 3, vals: [15, 30] },   // blue overtakes: change #1
      { t: 4, vals: [15, 25] },   // blue still leads (magnitude shrank): no change
      { t: 5, vals: [40, 25] },   // red retakes: change #2
    ],
  };
  assert.equal(matchGloryLeadChanges(series), 2);
});

test('matchGloryLeadChanges: a tie keeps the previous leader (not a change)', () => {
  const series = { teams: ['red', 'blue'], pts: [
    { t: 0, vals: [5, 0] }, { t: 1, vals: [5, 5] }, { t: 2, vals: [6, 5] },
  ] };
  assert.equal(matchGloryLeadChanges(series), 0);
});

test('matchGloryLeadChanges: handles 0 lead changes and a missing/empty series without crashing', () => {
  assert.equal(matchGloryLeadChanges(null), 0);
  assert.equal(matchGloryLeadChanges({ teams: [], pts: [] }), 0);
  assert.equal(matchGloryLeadChanges({ teams: ['red', 'blue'], pts: [{ t: 0, vals: [3, 1] }] }), 0);
});

test('matchGloryTier: a photo finish (near-0 margin) always reads razor-close, regardless of scale', () => {
  const a = matchGloryTier(0.01, 0);
  const b = matchGloryTier(0.01, 0); // deterministic: same inputs, same line
  assert.equal(a.id, 'razor');
  assert.equal(a.line, b.line);
});

test('matchGloryTier: a total blowout with no lead changes reads as one-sided', () => {
  const t = matchGloryTier(1, 0);
  assert.equal(t.id, 'rout');
});

test('matchGloryTier: same verdict (tier AND exact line) when every glory value is scaled by x1e6', () => {
  const totals = [9150000000000000, 1200, -60]; // the measured runaway + the measured negative
  const scaled = totals.map((v) => v * 1e6);
  const changes = 3; // an integer count is already scale-free by construction
  const plain = matchGloryTier(matchGloryMargin(totals), changes);
  const big = matchGloryTier(matchGloryMargin(scaled), changes);
  assert.equal(big.id, plain.id);
  assert.equal(big.line, plain.line);
});

test('matchGloryTier: never throws on NaN/undefined margin or negative changes', () => {
  assert.doesNotThrow(() => matchGloryTier(NaN, -5));
  assert.doesNotThrow(() => matchGloryTier(undefined, undefined));
  const t = matchGloryTier(undefined, undefined);
  assert.equal(typeof t.line, 'string');
  assert.ok(t.line.length > 0);
});

test('matchGloryTier copy: no exclamation marks, no emoji, all-caps house style', () => {
  const seen = new Set();
  for (let m = 0; m <= 1; m += 0.1) {
    for (let c = 0; c <= 5; c++) seen.add(matchGloryTier(m, c).line);
  }
  for (const line of seen) {
    assert.ok(!line.includes('!'), `"${line}" has an exclamation mark`);
    assert.equal(line, line.toUpperCase(), `"${line}" is not all-caps`);
    assert.ok(!/[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/u.test(line), `"${line}" contains an emoji`);
  }
});

test('gloryOdometerParts: holds the sign and unit static, matches gloryText on the landed value', () => {
  for (const v of [0, 42, 9999, 16600, -16600, 999999, 9150000000000000, -60]) {
    const parts = gloryOdometerParts(v);
    const landed = parts.sign + (parts.unit ? String(parts.mantissa) : String(Math.round(parts.mantissa))) + parts.unit;
    // The odometer's own rendering rule (trim-tenth for a unit'd mantissa,
    // integer for a bare one) must reconstruct gloryText's exact text.
    const rendered = parts.unit
      ? parts.sign + trimTenthLike(parts.mantissa) + parts.unit
      : parts.sign + String(Math.round(parts.mantissa));
    assert.equal(rendered, gloryText(v), 'landed odometer text must match gloryText(v) exactly for v=' + v);
  }
  function trimTenthLike(n) {
    const r = n.toFixed(1);
    return r.slice(-2) === '.0' ? r.slice(0, -2) : r;
  }
});

test('gloryOdometerParts: a negative total carries the sign, not a negative mantissa', () => {
  const parts = gloryOdometerParts(-16600);
  assert.equal(parts.sign, '-');
  assert.ok(parts.mantissa > 0, 'mantissa must be a positive magnitude');
});
