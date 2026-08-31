#!/usr/bin/env node
// MODULE-EVALUATION check for the hand-written viewer JS.
//
// WHY THIS EXISTS, and why `node --check` is not it. On 2026-08-25 the
// served replay viewer refused every replay outright with
//   Uncaught ReferenceError: Cannot access 'ZONE_BEAD_TICKS' before
//   initialization
// — the derived ZONE_BANDS palette in broadcast_core.js was placed ABOVE
// the age-threshold constants it reads, so it hit the temporal dead zone at
// module load and took the whole Worker down. That is VALID SYNTAX. A
// parser is happy with it; only EVALUATING the module finds it.
//
// The fix commit claimed this check, but never landed one: broadcast_core.js
// happened to be evaluated as a side effect of qa_band_desync.cjs's setup,
// and static_replay.js / static_replay_worker.js had no coverage at all —
// which is exactly the pair that fails hardest, because a Worker that dies
// at module load surfaces only as `worker.onerror`, i.e. as a line number in
// static_replay.js pointing nowhere near the real fault.
//
// Two contracts:
//
// 1. EVERY hand-written viewer module EVALUATES. Each is run under Node with
//    the minimal globals its real context provides. The worker is evaluated
//    with `importScripts` wired to actually evaluate the modules it names,
//    in the order it names them — so this reproduces the exact load path the
//    TDZ took down, at the exact site, rather than approximating it.
//
// 2. THE SERVED BUNDLE IS NOT STALE. static-replay-viewer/ is a BUILD OUTPUT
//    (Dockerfile.replay-viewer copies client/ and replay-viewer/ into
//    dist/), but it is checked in and it is what actually gets served. A
//    source fixed while the served copy still carries the bug looks green
//    everywhere and is broken in the browser.
//
// Usage: node tools/qa_module_eval.cjs
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const repo = path.join(__dirname, '..');
let failures = 0;
function check(name, cond, detail) {
  console.log((cond ? 'PASS' : 'FAIL') + ': ' + name +
    (cond || !detail ? '' : ' -- ' + detail));
  if (!cond) failures = 1;
}

const noop = function () {};
function stubCanvas() {
  const c = {
    width: 64, height: 64, clientWidth: 64, clientHeight: 64, style: {},
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 64, height: 64 }),
    addEventListener: noop, removeEventListener: noop,
    transferControlToOffscreen: () => ({ width: 64, height: 64 }),
  };
  c.getContext = () => ({
    canvas: c, imageSmoothingEnabled: false, fillStyle: '#000',
    createImageData: (w, h) =>
      ({ width: w, height: h, data: new Uint8ClampedArray(w * h * 4) }),
    putImageData: noop, getImageData: (x, y, w, h) =>
      ({ width: w, height: h, data: new Uint8ClampedArray(w * h * 4) }),
    clearRect: noop, fillRect: noop, drawImage: noop, save: noop,
    restore: noop, scale: noop, translate: noop, setTransform: noop,
    measureText: () => ({ width: 0 }), fillText: noop, beginPath: noop,
    arc: noop, fill: noop, stroke: noop, moveTo: noop, lineTo: noop,
    closePath: noop, createLinearGradient: () => ({ addColorStop: noop }),
  });
  return c;
}

function windowContext() {
  const win = {
    devicePixelRatio: 1,
    location: { href: 'http://localhost/replay', search: '' },
    addEventListener: noop, removeEventListener: noop,
    requestAnimationFrame: (cb) => 1, cancelAnimationFrame: noop,
    setTimeout: noop, clearTimeout: noop, console,
    URL, URLSearchParams, TextDecoder, TextEncoder, performance,
    Worker: function () { this.postMessage = noop; this.terminate = noop; },
  };
  win.window = win;
  win.self = win;
  const doc = {
    currentScript: { src: 'http://localhost/static_replay.js' },
    documentElement: { setAttribute: noop, style: {} },
    createElement: () => stubCanvas(),
    getElementById: () => null, querySelector: () => null,
    addEventListener: noop, readyState: 'complete', body: { style: {} },
  };
  win.document = doc;
  return win;
}

// ---- 1. every hand-written viewer module EVALUATES --------------------
// ctf_replay.js is deliberately NOT in this list: it is Emscripten's
// generated glue, not ours to author, and evaluating it would try to
// instantiate the wasm runtime. Everything a human edits IS here.
const windowModules = [
  'client/broadcast_core.js',
  'replay-viewer/static_replay.js',
];
for (const rel of windowModules) {
  const ctx = vm.createContext(windowContext());
  let err = null;
  try {
    vm.runInContext(fs.readFileSync(path.join(repo, rel), 'utf8'), ctx,
      { filename: rel });
  } catch (e) {
    err = (e && e.constructor ? e.constructor.name + ': ' : '') +
      (e && e.message ? e.message : String(e));
  }
  check('module evaluates: ' + rel, err === null, err);
}

// The Worker is the one that matters most: broadcast_core.js runs INSIDE it
// (via `self.window = self` plus importScripts), so a TDZ there kills the
// worker at load and reaches the page only as a bare `worker.onerror`.
// importScripts is wired to the REAL files, in the REAL order.
{
  const importable = {
    './wire_constants.js': 'static-replay-viewer/wire_constants.js',
    './broadcast_core.js': 'client/broadcast_core.js',
  };
  const skipped = [];
  const sandbox = windowContext();
  sandbox.self = sandbox;
  sandbox.postMessage = noop;
  sandbox.OffscreenCanvas = function () { return stubCanvas(); };
  sandbox.importScripts = function () {
    for (const name of arguments) {
      const rel = importable[name];
      if (!rel) { skipped.push(name); continue; }
      vm.runInContext(fs.readFileSync(path.join(repo, rel), 'utf8'), ctx,
        { filename: rel });
    }
  };
  const ctx = vm.createContext(sandbox);
  let err = null;
  try {
    vm.runInContext(
      fs.readFileSync(path.join(repo, 'replay-viewer/static_replay_worker.js'),
        'utf8'), ctx, { filename: 'static_replay_worker.js' });
  } catch (e) {
    err = (e && e.constructor ? e.constructor.name + ': ' : '') +
      (e && e.message ? e.message : String(e));
  }
  check('module evaluates: replay-viewer/static_replay_worker.js ' +
    '(+ importScripts of ' + Object.keys(importable).join(', ') + ')',
    err === null, err);
  // The skip list is REPORTED, never silent: if the worker starts importing
  // another hand-written module, this check must not quietly stop covering
  // the load path it claims to cover.
  check('worker importScripts skips only Emscripten glue',
    skipped.every((n) => n === './ctf_replay.js'),
    'unexpected skipped imports: ' + skipped.join(', '));
}

// ---- 2. the served bundle is not stale --------------------------------
const bundled = [
  ['client/broadcast_core.js', 'static-replay-viewer/broadcast_core.js'],
  ['client/chrome_common.js', 'static-replay-viewer/chrome_common.js'],
  ['replay-viewer/static_replay.js', 'static-replay-viewer/static_replay.js'],
  ['replay-viewer/static_replay_worker.js',
    'static-replay-viewer/static_replay_worker.js'],
];
for (const [src, out] of bundled) {
  const a = fs.readFileSync(path.join(repo, src));
  const b = fs.readFileSync(path.join(repo, out));
  check('served bundle matches source: ' + out, a.equals(b),
    'rebuild with tools/build_replay_viewer.sh -- a stale served copy ' +
    'looks green in the source and is broken in the browser');
}

process.exit(failures);
