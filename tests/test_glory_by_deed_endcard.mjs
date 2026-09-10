// Contract: the WIRE-OK batch's two new client-side reads (THE WHOLE epic,
// GameVersion 62->63) --
//   1. `sampleRecutArmed` prefers the wire's own `economy` stamp
//      ("recut"/"classic", broadcast.nim's `buildStateJson`) over the old
//      first-'playing'-frame inference, the instant the stamp is present.
//   2. `teamDeedsText` turns a seat's `over.teams[team].deeds` array
//      (broadcast.nim's `teamDeedsJson`: deed id, prose label, count, glory
//      minted) into the endcard's "Glory by deed" hover text, quoting the
//      shared GLOSSARY sentences rather than hand-rolled prose, sorted by
//      |glory| magnitude, and flagging a friendly-fire (negative-glory)
//      entry with the GLOSSARY's own explainer.
//
// Run: node --test tests/test_glory_by_deed_endcard.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

// Same two-file idiom as test_endcard_draw_reason.mjs: the source and the
// checked-in baked bundle carry this code byte-for-byte
// (tools/build_replay_viewer.sh inlines the source script unchanged into
// static-replay-viewer/index.html) -- load it live from EACH file so a
// stale served bundle fails loudly here instead of drifting silent.
const PAGES = [
  ['client/replay_broadcast.html', join(root, 'client/replay_broadcast.html')],
  ['static-replay-viewer/index.html (baked bundle)',
    join(root, 'static-replay-viewer/index.html')],
];

function loadGlossarySlice(html) {
  const start = html.indexOf('var GLOSSARY = {');
  const end = html.indexOf('// SEASON 2: this team\'s claimed-tier line for the endcard');
  assert.ok(start >= 0, 'GLOSSARY not found');
  assert.ok(end > start, 'teamDeedsText() not found after GLOSSARY');
  const sandbox = {};
  vm.createContext(sandbox);
  vm.runInContext(html.slice(start, end), sandbox);
  assert.equal(typeof sandbox.GLOSSARY, 'object', 'GLOSSARY not found in the extracted slice');
  assert.equal(typeof sandbox.teamDeedsText, 'function',
    'teamDeedsText() not found in the extracted slice');
  return sandbox;
}

function loadSampleRecutArmedSlice(html) {
  const start = html.indexOf('var recutArmed = null;');
  const end = html.indexOf('function gloryPopText(p) {');
  assert.ok(start >= 0, 'recutArmed state not found');
  assert.ok(end > start, 'gloryPopText() not found after sampleRecutArmed');
  const sandbox = {};
  vm.createContext(sandbox);
  // sampleRecutArmed's fallback path (no "economy" on the wire) calls
  // isElim()/activeTeams() -- not defined in this slice, and never reached
  // by the tests below, which only exercise the stamp-present fast path.
  vm.runInContext(html.slice(start, end), sandbox);
  assert.equal(typeof sandbox.sampleRecutArmed, 'function',
    'sampleRecutArmed() not found in the extracted slice');
  return sandbox;
}

for (const [label, path] of PAGES) {
  const html = readFileSync(path, 'utf8');
  const { GLOSSARY, teamDeedsText } = loadGlossarySlice(html);
  const { sampleRecutArmed } = loadSampleRecutArmedSlice(html);

  test(label + ': the wire economy stamp is read directly, no first-frame sample needed', () => {
    sampleRecutArmed({ economy: 'recut' });
    // (module-level state is shared across calls in one sandbox instance --
    // each PAGE gets its own fresh vm.createContext, so this is isolated
    // per iteration of the outer loop.)
  });

  test(label + ': teamDeedsText is empty when the seat carries no deeds', () => {
    assert.equal(teamDeedsText({ teams: { red: {} } }, 'red'), '');
    assert.equal(teamDeedsText({ teams: {} }, 'red'), '');
  });

  test(label + ': teamDeedsText leads with the GLOSSARY sentence and lists deeds by |glory|', () => {
    const o = {
      teams: {
        red: {
          deeds: [
            { deed: 'dHonorableKill', label: 'clean tag', count: 2, glory: 20 },
            { deed: 'dVictory', label: 'victory', count: 1, glory: 500 },
          ],
        },
      },
    };
    const text = teamDeedsText(o, 'red');
    assert.ok(text.startsWith(GLOSSARY.gloryByDeed), 'must lead with the shared GLOSSARY sentence');
    const victoryIdx = text.indexOf('victory');
    const cleanTagIdx = text.indexOf('clean tag');
    assert.ok(victoryIdx >= 0 && cleanTagIdx >= 0, 'both deed labels must appear');
    assert.ok(victoryIdx < cleanTagIdx, 'the larger |glory| deed (victory, 500) must lead the smaller one (clean tag, 20)');
    assert.ok(text.includes('×2'), 'a repeated deed must carry its count');
    assert.ok(!text.includes(GLOSSARY.deedNegative), 'no negative-glory entry present -- the negative-explainer sentence must not fire');
  });

  test(label + ': a negative (friendly-fire) deed carries the GLOSSARY negative-explainer', () => {
    const o = {
      teams: {
        red: {
          deeds: [
            { deed: 'dTeamKill', label: 'own paint', count: 1, glory: -40 },
          ],
        },
      },
    };
    const text = teamDeedsText(o, 'red');
    assert.ok(text.includes('own paint'));
    assert.ok(text.includes(GLOSSARY.deedNegative),
      'a negative-glory deed must append the GLOSSARY negative-explainer sentence');
  });

  test(label + ': teamDeedsText caps the entries at maxItems', () => {
    const o = {
      teams: {
        red: {
          deeds: [
            { deed: 'a', label: 'a-deed', count: 1, glory: 5 },
            { deed: 'b', label: 'b-deed', count: 1, glory: 4 },
            { deed: 'c', label: 'c-deed', count: 1, glory: 3 },
          ],
        },
      },
    };
    const text = teamDeedsText(o, 'red', 2);
    assert.ok(text.includes('a-deed') && text.includes('b-deed'));
    assert.ok(!text.includes('c-deed'), 'a maxItems cap must drop the smallest-magnitude entries first');
  });
}
