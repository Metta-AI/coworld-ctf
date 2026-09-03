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
// Four contracts:
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
const { execFileSync } = require('child_process');

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
  // A top-level window: the shell's Observatory bridge posts only when
  // window.parent !== window, so this stays silent here.
  win.parent = win;
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

// ---- 3. the committed wasm is not stale --------------------------------
// Contract 2 above only byte-diffs the HAND-WRITTEN JS against its source --
// it has no way to look inside a compiled binary. That blind spot is exactly
// what let THE FLIP (GameVersion 48 -> 50, 2026-09-01) ship with this whole
// file green while static-replay-viewer/ctf_replay.wasm still reported
// GameVersion 48: every hosted replay recorded after the flip failed to
// load in the browser ("Replay game version \"50\" is not compatible"),
// invisibly, because nothing here ever asked the wasm what version it was
// built for. So: actually INSTANTIATE the committed wasm (same trick
// tools/wasm_replay_smoke.cjs uses -- `Module` as a function PARAMETER, not
// a global, because the bundle's own `var Module=typeof Module!=
// "undefined"?Module:{}` is hoisted and shadows a global set before
// `require()`) and ask it directly, rather than inferring anything from
// file mtimes or git history.
{
  // One instantiation answers BOTH identity questions: the hand-bumped
  // GameVersion (contract 3) and the machine-derived sim-sources stamp
  // (contract 4 below). Each reads as `null` when the committed bundle
  // predates that export's existence, '' when the export exists but was
  // built without a value.
  const wasmIdentity = () => new Promise((resolve, reject) => {
    const distDir = path.join(repo, 'static-replay-viewer');
    const bundlePath = path.join(distDir, 'ctf_replay.js');
    const watchdog = setTimeout(
      () => reject(new Error('wasm runtime did not initialize within 60s')),
      60000);
    const readExport = (lenName, ptrName) => {
      if (typeof Module[lenName] !== 'function' ||
          typeof Module[ptrName] !== 'function') {
        // The exact shape of a bundle that predates the export (the OLD
        // 19c310dc-era bundle for GameVersion; every pre-stamp bundle for
        // the sim-sources stamp): fail as "stale", not as a TypeError from
        // calling an undefined function.
        return null;
      }
      const length = Module[lenName]();
      if (!length) return '';
      const pointer = Module[ptrName]();
      return Buffer.from(
        Module.HEAPU8.subarray(pointer, pointer + length)).toString('utf8');
    };
    const Module = {
      locateFile: (p) => path.join(distDir, p),
      onAbort: (what) => {
        clearTimeout(watchdog);
        reject(new Error('wasm runtime aborted: ' + what));
      },
      onRuntimeInitialized: () => {
        clearTimeout(watchdog);
        try {
          resolve({
            gameVersion: readExport(
              '_ctf_game_version_len', '_ctf_game_version_ptr'),
            simSourcesStamp: readExport(
              '_ctf_sim_sources_stamp_len', '_ctf_sim_sources_stamp_ptr'),
          });
        } catch (e) {
          reject(e);
        }
      },
    };
    try {
      new Function('Module', 'require', '__filename', '__dirname',
        fs.readFileSync(bundlePath, 'utf8'))(Module, require, bundlePath, distDir);
    } catch (e) {
      clearTimeout(watchdog);
      reject(e);
    }
  });

  const sourceGameVersion = () => {
    const constFile = path.join(repo, 'src/ctf/sim_types.nim');
    const text = fs.readFileSync(constFile, 'utf8');
    const line = text.split('\n').find((l) => /GameVersion\* =/.test(l));
    const m = line && line.match(/"([0-9]+)"/);
    if (!m) {
      throw new Error('could not read GameVersion from ' + constFile +
        ' -- if the const was renamed, update tools/qa_module_eval.cjs ' +
        '(and tools/ci/check_gameversion.sh)');
    }
    return m[1];
  };

  // ---- 4. the committed wasm was built from the sim sources at HEAD ---
  // Contract 3 catches a GameVersion someone bumped without rebuilding.
  // It is blind BY DESIGN to the opposite failure: sim-behavior changes
  // that ship WITHOUT a bump. That blind spot shipped on 2026-09-01, hours
  // after contract 3 itself landed (#347): an engine train (default
  // restores incl. cogsPerTeam, deprecation gates, season2Shell default)
  // merged same-day at GameVersion 50, so replays recorded on the new
  // canonical engine re-simulated differently in the freshly rebuilt
  // bundle -- every hosted replay showed the hash-mismatch banner while
  // this file stayed green. The stamp is a content hash over the wasm
  // build's actual Nim inputs (tools/sim_sources_stamp.sh), baked in at
  // build time by tools/build_replay_viewer.sh; recomputing it here at
  // HEAD catches ANY sim-source drift, versioned or not.
  const sourceSimStamp = () =>
    execFileSync(path.join(repo, 'tools', 'sim_sources_stamp.sh'),
      { encoding: 'utf8' }).trim();

  wasmIdentity().then((wasm) => {
    let sourceVersion;
    try {
      sourceVersion = sourceGameVersion();
    } catch (e) {
      check('committed wasm GameVersion matches src/ctf/sim_types.nim',
        false, e.message);
      process.exit(failures);
      return;
    }
    if (wasm.gameVersion === null) {
      check('committed wasm GameVersion matches src/ctf/sim_types.nim',
        false,
        'static-replay-viewer/ctf_replay.wasm does not export ' +
        'ctf_game_version_ptr/len -- it predates this check and is ' +
        'almost certainly stale. Source is GameVersion ' + sourceVersion +
        '. Rebuild with tools/build_replay_viewer.sh.');
    } else {
      check('committed wasm GameVersion matches src/ctf/sim_types.nim',
        wasm.gameVersion === sourceVersion,
        'wasm reports GameVersion ' + JSON.stringify(wasm.gameVersion) +
        ', source (src/ctf/sim_types.nim) is GameVersion ' +
        JSON.stringify(sourceVersion) + ' -- the committed ' +
        'static-replay-viewer/ctf_replay.wasm is stale (this is the exact ' +
        'class of bug that shipped THE FLIP broken: a GameVersion bump ' +
        'with no matching bundle rebuild). Rebuild with ' +
        'tools/build_replay_viewer.sh and commit the result.');
    }

    let expectedStamp;
    try {
      expectedStamp = sourceSimStamp();
    } catch (e) {
      check('committed wasm sim-sources stamp matches HEAD', false,
        'could not run tools/sim_sources_stamp.sh: ' +
        (e && e.message ? e.message : String(e)));
      process.exit(failures);
      return;
    }
    if (wasm.simSourcesStamp === null || wasm.simSourcesStamp === '') {
      check('committed wasm sim-sources stamp matches HEAD', false,
        (wasm.simSourcesStamp === null
          ? 'static-replay-viewer/ctf_replay.wasm does not export ' +
            'ctf_sim_sources_stamp_ptr/len -- it predates the sim-sources ' +
            'stamp and cannot prove what it was built from.'
          : 'static-replay-viewer/ctf_replay.wasm carries an EMPTY ' +
            'sim-sources stamp -- it was built without ' +
            'tools/build_replay_viewer.sh (which injects the stamp).') +
        ' Treating it as: bundle built from older sim sources -- rebuild ' +
        'with tools/build_replay_viewer.sh and commit the result.');
    } else {
      check('committed wasm sim-sources stamp matches HEAD',
        wasm.simSourcesStamp === expectedStamp,
        'bundle built from older sim sources -- rebuild with ' +
        'tools/build_replay_viewer.sh and commit the result. (wasm stamp ' +
        wasm.simSourcesStamp.slice(0, 12) + '..., sources at HEAD hash to ' +
        expectedStamp.slice(0, 12) + '...; the sim sources changed after ' +
        'this bundle was built -- with or without a GameVersion bump, ' +
        'which is exactly the drift contract 3 cannot see.)');
    }
    process.exit(failures);
  }).catch((e) => {
    check('committed wasm identity exports readable', false,
      'could not instantiate static-replay-viewer/ctf_replay.wasm: ' +
      (e && e.message ? e.message : String(e)) +
      ' -- rebuild with tools/build_replay_viewer.sh.');
    process.exit(failures);
  });
}
