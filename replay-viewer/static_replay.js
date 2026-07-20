var Module = window.Module || {};

(function () {
  'use strict';

  var core = null;
  var runtimeReady = false;
  var started = false;
  var lastFrame = 0;
  var accumulator = 0;
  var frameMs = 1000 / 24;
  var failed = false;

  function showFailure(error) {
    failed = true;
    console.error(error);
    var status = document.getElementById('status');
    if (status) {
      status.textContent = 'Replay failed: ' + (error.message || String(error));
      status.classList.add('show');
    }
  }

  function ingestPacket() {
    var length = Module._ctf_packet_len();
    if (!length) throw new Error('Replay runtime produced an empty frame');
    var pointer = Module._ctf_packet_ptr();
    core.ingest(Module.HEAPU8.slice(pointer, pointer + length));
    var mismatchTick = Module._ctf_mismatch_tick();
    if (mismatchTick >= 0) {
      document.documentElement.setAttribute(
        'data-replay-mismatch-tick', String(mismatchTick));
    }
  }

  function runtimeError() {
    var length = Module._ctf_error_len();
    if (!length) return 'Replay runtime rejected the replay';
    var pointer = Module._ctf_error_ptr();
    return new TextDecoder().decode(Module.HEAPU8.slice(pointer, pointer + length));
  }

  function copyIntoRuntime(bytes, callback) {
    var pointer = Module._malloc(bytes.length);
    Module.HEAPU8.set(bytes, pointer);
    callback(pointer, bytes.length);
    Module._free(pointer);
  }

  function animate(now) {
    if (failed) return;
    if (!lastFrame) lastFrame = now;
    accumulator += Math.min(now - lastFrame, 250);
    lastFrame = now;
    try {
      while (accumulator >= frameMs) {
        if (Module._ctf_frame() < 0) throw new Error(runtimeError());
        ingestPacket();
        accumulator -= frameMs;
      }
      requestAnimationFrame(animate);
    } catch (error) {
      showFailure(error);
    }
  }

  async function start() {
    if (started || !runtimeReady || !core) return;
    started = true;
    var replayUrl = new URLSearchParams(location.search).get('replay');
    if (!replayUrl) throw new Error('Missing required replay URL');
    var response = await fetch(replayUrl, { credentials: 'omit', mode: 'cors' });
    if (!response.ok) {
      throw new Error('Replay request returned HTTP ' + response.status);
    }
    var bytes = new Uint8Array(await response.arrayBuffer());
    if (!bytes.length) throw new Error('Replay response was empty');
    var loaded = 0;
    copyIntoRuntime(bytes, function (pointer, length) {
      loaded = Module._ctf_load_replay(pointer, length);
    });
    if (!loaded) throw new Error(runtimeError());
    ingestPacket();
    document.documentElement.setAttribute('data-replay-loaded', 'true');
    requestAnimationFrame(animate);
  }

  Module.locateFile = function (path) { return './' + path; };
  Module.onRuntimeInitialized = function () {
    runtimeReady = true;
    start().catch(showFailure);
  };
  window.Module = Module;

  window.CtfStaticReplay = {
    attachCore: function (value) {
      core = value;
      start().catch(showFailure);
    },
    sendPacket: function (bytes) {
      if (!runtimeReady) return;
      copyIntoRuntime(bytes, function (pointer, length) {
        Module._ctf_input(pointer, length);
      });
    }
  };
})();
