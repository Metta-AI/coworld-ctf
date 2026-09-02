'use strict';

// broadcast_core.js is shared with the native Window client and its vendored
// Snappy module publishes through `window`. A classic Worker can provide that
// alias without introducing a second implementation or bundle step.
self.window = self;

var Module = {};
var runtimeReady = false;
var initMessage = null;
var runtimeLoaded = false;
var core = null;
var minimapSurface = null;
var failed = false;
var disposed = false;

function stageNote() {
  // The fixed progress buffer survives an ABORTING_MALLOC failure even though
  // the Emscripten call stack does not.
  try {
    var length = Module._ctf_stage_len ? Module._ctf_stage_len() : 0;
    if (!length) return '';
    var pointer = Module._ctf_stage_ptr();
    return new TextDecoder().decode(
      Module.HEAPU8.slice(pointer, pointer + length));
  } catch (ignored) {
    return '';
  }
}

function runtimeError() {
  var length = Module._ctf_error_len();
  if (!length) {
    var stage = stageNote();
    return stage
      ? 'Replay runtime failed while: ' + stage
      : 'Replay runtime rejected the replay';
  }
  var pointer = Module._ctf_error_ptr();
  return new TextDecoder().decode(
    Module.HEAPU8.slice(pointer, pointer + length));
}

function reportFailure(error) {
  if (failed || disposed) return;
  failed = true;
  postMessage({
    type: 'error',
    message: error && error.message ? error.message : String(error),
    stage: stageNote()
  });
}

function callsJsonText() {
  // SEASON 2 observability: the play-call ("flash") records JSON the runtime
  // serialized at load (ctf_replay.nim, ctf_calls_ptr/len). Null on a replay
  // with no calls, or under an OLDER wasm bundle without the export — both
  // degrade to "no calls payload", never an error.
  try {
    var length = Module._ctf_calls_len ? Module._ctf_calls_len() : 0;
    if (!length) return null;
    var pointer = Module._ctf_calls_ptr();
    return new TextDecoder().decode(
      Module.HEAPU8.slice(pointer, pointer + length));
  } catch (ignored) {
    return null;
  }
}

function tellPhase(phase) {
  // Observatory load marks. The page relays these to its parent (see
  // static_replay.js): a Worker has no window.parent of its own.
  postMessage({ type: 'phase', phase: phase });
}

function copyIntoRuntime(bytes, callback) {
  var pointer = Module._malloc(bytes.length);
  try {
    Module.HEAPU8.set(bytes, pointer);
    return callback(pointer, bytes.length);
  } finally {
    Module._free(pointer);
  }
}

function ingestPacket() {
  var length = Module._ctf_packet_len();
  if (!length) throw new Error('Replay runtime produced an empty frame');
  var pointer = Module._ctf_packet_ptr();
  // BroadcastCore parses synchronously and copies any retained compressed
  // sprite bytes, so it can read the WASM heap view directly. This avoids a
  // full packet allocation/copy on every replay frame.
  core.ingest(Module.HEAPU8.subarray(pointer, pointer + length));
}

function sendRuntimeInput(bytes) {
  if (!runtimeLoaded) return;
  copyIntoRuntime(bytes, function (pointer, length) {
    Module._ctf_input(pointer, length);
  });
}

function createBroadcastCore(message) {
  core = self.BroadcastCore.create({
    canvas: message.canvas,
    websocket: false,
    playoutBuffer: false,
    viewportWidth: message.width,
    viewportHeight: message.height,
    devicePixelRatio: message.dpr,
    onText: function (text) {
      // hasZoneField rides along on every state frame so the page can decide,
      // the instant it sees ph:'gameover', whether the completion beat has
      // anything to play — the core object lives here, so the query is free.
      postMessage({
        type: 'text',
        text: text,
        hasZoneField: core ? core.getZonePaintStats().hasField : false
      });
    },
    onStatus: function (status) {
      postMessage({ type: 'status', status: status });
    },
    onFirstFrame: function () {
      postMessage({ type: 'firstFrame' });
    },
    onTransform: function (transform) {
      postMessage({ type: 'transform', transform: transform });
    },
    onSendPacket: sendRuntimeInput
  });
  if (minimapSurface) core.attachMinimap(minimapSurface);
  core.start();
}

async function start() {
  if (!runtimeReady || !initMessage || runtimeLoaded || failed || disposed) return;
  var message = initMessage;
  initMessage = null;
  try {
    tellPhase('bundle_ready');
    createBroadcastCore(message);
    tellPhase('replay_fetch_start');
    var response = await fetch(message.replayUrl, {
      credentials: 'omit',
      mode: 'cors'
    });
    if (!response.ok) {
      throw new Error('Replay request returned HTTP ' + response.status);
    }
    var bytes = new Uint8Array(await response.arrayBuffer());
    // Sniff the content, never the URL or headers: the public copy of a
    // replay may be gzip (1f 8b) or zlib (78 ..) bytes served with no
    // Content-Encoding. The wasm codec inflates either itself
    // (allowCompressed in the replay spec); this only labels the download.
    postMessage({
      type: 'phase',
      phase: 'replay_fetch_end',
      bytes: bytes.byteLength,
      compressed: (bytes[0] === 0x1f && bytes[1] === 0x8b) || bytes[0] === 0x78
    });
    if (!bytes.length) throw new Error('Replay response was empty');
    var loaded = copyIntoRuntime(bytes, function (pointer, length) {
      return Module._ctf_load_replay(pointer, length);
    });
    if (!loaded) throw new Error(runtimeError());
    tellPhase('replay_parsed');
    runtimeLoaded = true;
    ingestPacket();
    postMessage({
      type: 'loaded',
      // Flash observability: the decoded play-call records ride to the PAGE
      // (comms feed) here; the page resolves each seat's roster index and
      // hands enriched calls BACK over the 'flashCalls' message below for
      // the in-arena pulse ring. Either side missing the capability is
      // fine — both degrade to "no flash chrome".
      calls: callsJsonText(),
      mismatchTick: Module._ctf_mismatch_tick(),
      // The page needs this to schedule its own scoreboard-reveal delay, but
      // it never loads broadcast_core.js (only this Worker does, via
      // importScripts) — so hand over the module's own constant once, here,
      // rather than the page hardcoding a second copy of the number.
      zoneEndcardMs: self.BroadcastCore.ZONE_ENDCARD_MS
    });
  } catch (error) {
    reportFailure(error);
  }
}

function applyInputNow() {
  // A viewer input (transport command, scrubber seek, board click) only takes
  // effect at the top of the next presentation frame, and the main thread only
  // asks for one on its next rAF -- behind whatever advance batch is already
  // queued. On a long replay that made a mid-replay seek arrive seconds after
  // the click (the hosted 50 % scrub read identically to 0 %). Run ONE frame
  // right here instead, so the input is applied and drawn as soon as the
  // message is processed. `advanced` is not posted: the main thread's
  // advance-in-flight bookkeeping is not ours to touch.
  if (!runtimeLoaded || failed || disposed) return;
  try {
    if (Module._ctf_frame() < 0) throw new Error(runtimeError());
    ingestPacket();
    postMessage({
      type: 'inputApplied',
      mismatchTick: Module._ctf_mismatch_tick()
    });
  } catch (error) {
    reportFailure(error);
  }
}

function advance(frames) {
  if (!runtimeLoaded || failed || disposed) return;
  try {
    var count = Math.max(1, Math.min(6, Number(frames) || 1));
    for (var i = 0; i < count; i++) {
      var step = Module._ctf_frame();
      if (step < 0) throw new Error(runtimeError());
      if (step !== 1) {
        // Playback has reached the end of the replay. The page normally
        // already armed the completion beat (an 'endcard' message, sent the
        // instant it saw ph:'gameover' — long before frames actually run out,
        // over the whole replay-hold countdown). beginZoneEndcard is
        // idempotent, so this is just the fallback for a page that somehow
        // never observed that phase transition, not the primary trigger.
        if (core) core.beginZoneEndcard();
        break;
      }
      ingestPacket();
    }
    postMessage({
      type: 'advanced',
      mismatchTick: Module._ctf_mismatch_tick(),
      // Presentation stat for the page (the core draws over here, a thread
      // away): total frames blitted, so the page can read draws-per-second.
      draws: core ? core.getPaceStats().draws : 0
    });
  } catch (error) {
    reportFailure(error);
  }
}

Module.locateFile = function (path) {
  return new URL(path, self.location.href).toString();
};
Module.onAbort = function (what) {
  var stage = stageNote();
  reportFailure(new Error('Replay runtime ran out of memory (' + what +
    ') — wasm32 is limited to 2 GB' +
    (stage ? '. Failed while: ' + stage : '')));
};
Module.onRuntimeInitialized = function () {
  runtimeReady = true;
  start();
};
self.Module = Module;

self.onmessage = function (event) {
  var message = event.data || {};
  try {
    if (message.type === 'init') {
      initMessage = message;
      start();
    } else if (message.type === 'advance') {
      advance(message.frames);
    } else if (message.type === 'flashCalls' && core) {
      // Enriched flash records from the page (seat -> roster index resolved
      // there) for the in-arena pulse ring — see broadcast_core.js
      // setFlashCalls.
      if (core.setFlashCalls) core.setFlashCalls(message.calls);
    } else if (message.type === 'command' && core) {
      core.sendCommand(message.text || '');
      applyInputNow();
    } else if (message.type === 'click' && core) {
      core.clickMap(Number(message.x) || 0, Number(message.y) || 0);
      applyInputNow();
    } else if (message.type === 'input' && runtimeLoaded) {
      sendRuntimeInput(new Uint8Array(message.bytes));
      applyInputNow();
    } else if (message.type === 'resize' && core) {
      core.setViewportSize(message.width, message.height, message.dpr);
    } else if (message.type === 'endcard' && core) {
      // Sent by the page the instant it sees ph:'gameover' — the same moment
      // (not frame exhaustion) that drives the live client directly. Arms the
      // paint-completion + terminal-splat beat; see ZONE_ENDCARD_MS.
      core.beginZoneEndcard();
    } else if (message.type === 'view' && core) {
      // The canvas is an OffscreenCanvas here, so wheel/drag land on the main
      // thread's placeholder element and arrive as view commands. The core's
      // transform (and the transform echoed back for click mapping) stays the
      // single source of truth either way.
      if (message.action === 'zoom') core.zoomAt(message.factor, message.x, message.y);
      else if (message.action === 'setZoom') core.setZoom(message.level, message.x, message.y);
      else if (message.action === 'pan') core.panBy(message.dx, message.dy);
      else if (message.action === 'panMap') core.panByMap(message.dx, message.dy);
      else if (message.action === 'panTo') core.panTo(message.x, message.y);
      else if (message.action === 'reset') core.resetView();
    } else if (message.type === 'minimap') {
      // The board pixels live here, so the minimap is drawn here too. The page
      // transferred its canvas across; hold it until the core exists.
      minimapSurface = message.canvas || null;
      if (core && minimapSurface) core.attachMinimap(minimapSurface);
    } else if (message.type === 'dispose') {
      disposed = true;
      if (core) core.stop();
      close();
    }
  } catch (error) {
    reportFailure(error);
  }
};

importScripts('./wire_constants.js', './broadcast_core.js', './ctf_replay.js');
