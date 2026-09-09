// Contract: the endcard's MATCH GLORY tier line is SCALE-FREE (closeness of
// the final standings + how many times the lead changed hands), never an
// absolute glory floor — the old fork's table (2000/2300/2600/3100) died the
// moment the S2 economy retuned: glory today reaches 9.15 quadrillion with
// no cap and has measured NEGATIVE (-60), so any fixed threshold is wrong by
// construction. Also covers the glory odometer's target-parts formatter
// (gloryOdometerParts): sign/unit held static, only the mantissa counts up.
//
// TIER DETERMINISM (2026-09-09): the show-review tier is a property of the
// MATCH, never of the viewing path. Two screenshots of the SAME fixture at
// the SAME settled end state once showed the SAME combined total but
// DIFFERENT tier lines depending on whether the viewer sought straight to
// the end or played through — because the once-per-episode `lead` series
// can legitimately land on a LATER frame than the endcard's own first
// render (native server: sendLead waits on a background scan a fast seek
// can outrace), and renderEndcard's content dedupe (card._key) then never
// called renderEndcardBR again for what was, correctly, the same verdict —
// freezing whatever tier a series-less guess produced. The fix
// (mgTotalsCache + mgRepaintTier) recomputes the tier the moment the
// series actually arrives, off the cached totals, regardless of which
// frames were rendered on the way there — and omits the line entirely
// (never guesses a 0-change count) when no series has arrived yet or ever
// will. The tests below exercise that recompute-on-arrival path directly,
// not just the pure tier math (which was already order-independent).
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

// Extracts mgLeadFull / mgTotalsCache / mgIngestLead — the late-arrival
// state that mgIngestLead updates the instant the wire's one-shot `lead`
// field shows up, independent of which rendered frame it rides in on.
function loadMgIngestSlice(html) {
  const start = html.indexOf('var mgLeadFull = null;');
  const end = html.indexOf('var renderMomentum = C.renderMomentum;');
  assert.ok(start >= 0, 'mgLeadFull not found');
  assert.ok(end > start, 'renderMomentum not found after mgLeadFull');
  return html.slice(start, end);
}

// A sandbox wired with BOTH slices above (mgIngestLead lives much earlier
// in the file than matchGloryTier/mgRepaintTier, but they share one script
// scope in the real page — function hoisting makes the cross-reference
// work there, and running both slices into one vm context reproduces that).
// `$` is stubbed to a tiny fake-DOM map so mgRepaintTier's `$('mg-line')`
// resolves to a real object whose `.textContent` a test can read back.
function loadEndcardSandbox(html) {
  const dom = { 'mg-line': { textContent: '' } };
  const sandbox = { $: (id) => dom[id] };
  vm.createContext(sandbox);
  vm.runInContext(loadMgIngestSlice(html), sandbox);
  const mgStart = html.indexOf("var GLORY_UNITS = ['k', 'M', 'B', 'T', 'Q'];");
  const mgEnd = html.indexOf('function teamGloryOf(o, team) {');
  vm.runInContext(html.slice(mgStart, mgEnd), sandbox);
  for (const name of ['mgIngestLead', 'mgRepaintTier']) {
    assert.equal(typeof sandbox[name], 'function', name + '() not found across the two slices');
  }
  return { sandbox, dom };
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

test('MATCH GLORY tier classes: 5 lead changes + a near-tie margin reads "kept reversing"; 0 changes + a wide margin reads "clear result"', () => {
  // Leader flips red -> blue -> red -> blue -> red -> blue after kickoff: 5
  // identity changes, and the final standing (60 vs 90) is a near-tie.
  const reversingSeries = { teams: ['red', 'blue'], pts: [
    { t: 0, vals: [0, 0] }, { t: 1, vals: [10, 0] }, { t: 2, vals: [5, 20] },
    { t: 3, vals: [30, 20] }, { t: 4, vals: [30, 50] }, { t: 5, vals: [60, 50] },
    { t: 6, vals: [60, 90] },
  ] };
  const reversingChanges = matchGloryLeadChanges(reversingSeries);
  assert.equal(reversingChanges, 5);
  const reversingMargin = matchGloryMargin([90, 60]);
  assert.ok(reversingMargin < 0.4, 'expected a near-tie margin, got ' + reversingMargin);
  // 'backforth' is the tier whose copy pool is "THE LEAD CHANGED HANDS
  // REPEATEDLY" / "NEITHER SIDE HELD IT FOR LONG" / "A MATCH THAT KEPT
  // REVERSING" — the "kept reversing" class the bug report named.
  assert.equal(matchGloryTier(reversingMargin, reversingChanges).id, 'backforth');

  // Leader never changes (red the whole way), and the final standing is a
  // lopsided 200 vs 20 — wide, but short of a total rout.
  const steadySeries = { teams: ['red', 'blue'], pts: [
    { t: 0, vals: [0, 0] }, { t: 1, vals: [100, 0] }, { t: 2, vals: [150, 10] },
    { t: 3, vals: [200, 20] },
  ] };
  const steadyChanges = matchGloryLeadChanges(steadySeries);
  assert.equal(steadyChanges, 0);
  const steadyMargin = matchGloryMargin([200, 20]);
  assert.ok(steadyMargin > 0.5 && steadyMargin < 0.85, 'expected a wide, sub-rout margin, got ' + steadyMargin);
  // 'clear' is the tier whose copy pool includes "A CLEAR RESULT, NO
  // DRAMA" — the "clear result" class the bug report named.
  assert.equal(matchGloryTier(steadyMargin, steadyChanges).id, 'clear');
});

test('MATCH GLORY tier determinism: the SAME lead series lands on the SAME tier text regardless of whether it arrives before or after the endcard first renders (a fast seek vs a play-through)', () => {
  const totals = [90, 60]; // matches the reversing series' final standing above
  const wireLead = { teams: ['red', 'blue'], pts: [
    [0, 0, 0], [1, 10, 0], [2, 5, 20], [3, 30, 20], [4, 30, 50], [5, 60, 50], [6, 60, 90],
  ] };

  // Scenario A ("play-through"): the wire's one-shot `lead` field lands
  // BEFORE the endcard ever caches its totals -- mgIngestLead runs first.
  const a = loadEndcardSandbox(html);
  a.sandbox.mgIngestLead({ lead: wireLead }); // arrives first; no totals cached yet, so this is a no-op repaint
  assert.equal(a.dom['mg-line'].textContent, '', 'nothing to paint yet: renderEndcardBR has not run');
  a.sandbox.mgTotalsCache = totals; // renderEndcardBR-equivalent: totals now known
  a.sandbox.mgRepaintTier();
  const lineA = a.dom['mg-line'].textContent;
  assert.notEqual(lineA, '', 'a real series + totals must produce real tier text');

  // Scenario B ("seek straight to the end"): the endcard renders its
  // totals FIRST, on a frame that landed before the background scan
  // shipped `lead` -- the exact race the live bug hit. The tier must be
  // omitted, not guessed, until the series actually shows up.
  const b = loadEndcardSandbox(html);
  b.sandbox.mgTotalsCache = totals; // renderEndcardBR-equivalent, no series yet
  b.sandbox.mgRepaintTier();
  assert.equal(b.dom['mg-line'].textContent, '', 'no series yet: must omit the tier, never guess off 0 changes');
  b.sandbox.mgIngestLead({ lead: wireLead }); // series lands late; must recompute + repaint now
  const lineB = b.dom['mg-line'].textContent;

  assert.equal(lineA, lineB, 'the tier text must not depend on which frames were rendered on the way to it');
});

test('mgRepaintTier: omits the tier line when no lead series has arrived (never guesses off 0 changes), and never throws', () => {
  const { sandbox, dom } = loadEndcardSandbox(html);

  // renderEndcardBR ran (totals are known) but the wire hasn't shipped
  // `lead` yet.
  sandbox.mgTotalsCache = [200, 20];
  sandbox.mgRepaintTier();
  assert.equal(dom['mg-line'].textContent, '', 'no series yet: must be empty, not a guessed tier');

  // The legacy 2-team diff array (a pre-BR/glory wire shape) is read the
  // same way as "no series": mgIngestLead declines to adopt it, so it
  // never manufactures a fake series either.
  sandbox.mgIngestLead({ lead: [1, 2, 3] });
  assert.equal(dom['mg-line'].textContent, '', 'legacy array shape must not be treated as a real series');

  // No glory at all on this render (anyGlory false in the real caller
  // clears mgTotalsCache to null): repainting must stay a safe no-op.
  sandbox.mgTotalsCache = null;
  assert.doesNotThrow(() => sandbox.mgRepaintTier());
  assert.equal(dom['mg-line'].textContent, '', 'still empty with no totals cached');
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
