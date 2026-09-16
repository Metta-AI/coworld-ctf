// Contract: the static viewer reads #replay= before ?replay=.
// Host mints index.html?v=2#replay=<url> (fragment is not an HTTP cache key).
// Local opens keep ?replay=. The league shell nests ./index.html?embed=1#replay=.
//
// Run: node --test tests/test_replay_artifact_url.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

function replayUrlFromLocation(loc) {
  return new URLSearchParams((loc.hash || '').slice(1)).get('replay') ||
    new URLSearchParams(loc.search || '').get('replay');
}

test('host mint index.html?v=2#replay= reads the fragment', () => {
  const replay = 'https://softmax-public.s3.amazonaws.com/replays/abc.replay';
  const loc = new URL(
    'https://viewer.example/v/index.html?v=2#replay=' + encodeURIComponent(replay));
  assert.equal(replayUrlFromLocation(loc), replay);
});

test('hash wins over a leftover ?replay= query', () => {
  const fromHash = 'https://example.com/from-hash.replay';
  const fromQuery = 'https://example.com/from-query.replay';
  const loc = new URL(
    'https://viewer.example/index.html?v=2&replay=' + encodeURIComponent(fromQuery) +
    '#replay=' + encodeURIComponent(fromHash));
  assert.equal(replayUrlFromLocation(loc), fromHash);
});

test('query fallback keeps local ?replay= URLs working', () => {
  const loc = new URL(
    'http://127.0.0.1:21404/index.html?replay=' +
    encodeURIComponent('./capture-seed1.bitreplay'));
  assert.equal(replayUrlFromLocation(loc), './capture-seed1.bitreplay');
});

test('missing hash and query yields no replay URL', () => {
  const loc = new URL('https://viewer.example/index.html?v=2');
  assert.equal(replayUrlFromLocation(loc), null);
});

test('static_replay.js reads loc.hash before location.search', () => {
  const src = readFileSync(join(root, 'replay-viewer/static_replay.js'), 'utf8');
  const hashIdx = src.indexOf("location.hash");
  const searchIdx = src.indexOf('location.search');
  assert.ok(hashIdx >= 0, 'static_replay.js must read location.hash');
  assert.ok(searchIdx >= 0, 'static_replay.js must keep ?replay= fallback');
  assert.ok(hashIdx < searchIdx, 'hash must be read before search');
  assert.match(src, /location\.hash \|\| ''\)\.slice\(1\)/);
});

test('league nested board is ./index.html?embed=1#replay=', () => {
  const src = readFileSync(join(root, 'client/league_replayer.html'), 'utf8');
  const hashIdx = src.indexOf('location.hash');
  const searchIdx = src.indexOf('params.get(\'replay\')');
  assert.ok(hashIdx >= 0, 'league_replayer.html must read location.hash');
  assert.ok(searchIdx >= 0, 'league_replayer.html must keep ?replay= fallback');
  assert.ok(hashIdx < searchIdx, 'hash must be read before query fallback');
  assert.match(src, /'\.\/index\.html\?embed=1#replay=' /);
  assert.doesNotMatch(src, /\?embed=1&replay=/);
});
