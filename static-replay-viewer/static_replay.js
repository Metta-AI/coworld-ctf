(function () {
  'use strict';

  // Observatory readiness protocol. A second channel beside the page's
  // ?embed=1 postToShell bridge: the host keeps a "Loading replay..." overlay
  // over this iframe until `ready`, shows `error`, and stamps each `phase`
  // with its own clock (so no timestamps travel). Target origin is '*': the
  // bundle cannot know its embedder and the payload is timings only.
  function tellHost(message) {
    if (window.parent === window) return;
    window.parent.postMessage(Object.assign({ src: 'coworld-replay' }, message), '*');
  }
  tellHost({ type: 'loading' });

  var failed = false;
  var readyPosted = false;
  var scriptUrl = document.currentScript && document.currentScript.src;
  var workerUrl = new URL('./static_replay_worker.js', scriptUrl || location.href);

  function showFailure(error) {
    // First failure wins: an OOM abort reports once from the Worker (with the
    // stage note), then may also surface as an error event. Keep the specific
    // diagnostic instead of overwriting it with the generic one.
    if (failed) return;
    failed = true;
    tellHost({
      type: 'error',
      message: error && error.message ? error.message : String(error)
    });
    // The failure marker, on <html>, next to data-replay-loaded: without it a
    // deadlocked bundle is indistinguishable from a slow one, and every
    // failure mode below degrades to the harness's timeout instead of an
    // immediate named failure (tools/ci/viewer_smoke.mjs reads this attribute
    // and fails fast on it).
    document.documentElement.setAttribute(
      'data-replay-error', error && error.message ? error.message : String(error));
    console.error(error);
    var status = document.getElementById('status');
    if (status) {
      status.textContent = 'Replay failed: ' + (error.message || String(error));
      status.classList.add('show');
    }
  }

  function markReady() {
    // One animation frame after the first drawn frame, so the host lifts its
    // overlay onto a painted board rather than a black stage.
    if (readyPosted) return;
    readyPosted = true;
    requestAnimationFrame(function () { tellHost({ type: 'ready' }); });
  }

  function setMismatchTick(tick) {
    if (tick >= 0) {
      document.documentElement.setAttribute(
        'data-replay-mismatch-tick', String(tick));
    }
  }

  function createCore(config) {
    var canvas = config.canvas;
    var worker = null;
    var started = false;
    var loaded = false;
    var advanceInFlight = false;
    var advanceStarted = 0;
    var lastAdvanceMs = 0;
    var lastFrame = 0;
    var accumulator = 0;
    var frameMs = 1000 / 24;
    var workerDraws = 0;
    // Learned once from the Worker's 'loaded' message (see
    // static_replay_worker.js) — the Worker is the one that actually loads
    // broadcast_core.js, so it hands over the module's own beat-length
    // constant instead of this file hardcoding a second copy of the number.
    var zoneEndcardMs = 0;
    // Same shape the in-process core reports, so the page's view controls read
    // one object either way. These are the pre-stream values: fitted, whole
    // board, nothing to pan — which is exactly the state the board opens in.
    var transform = {
      scale: 1,
      offsetX: 0,
      offsetY: 0,
      nativeW: 1,
      nativeH: 1,
      zoom: 1,
      minZoom: 1,
      maxZoom: 12,
      fitScale: 1,
      focusX: 0,
      focusY: 0,
      visW: 1,
      visH: 1
    };
    var viewport = { width: 1, height: 1, dpr: window.devicePixelRatio || 1 };
    var offscreen;
    var pendingMinimap = null;
    var minimapSent = false;

    // transferControlToOffscreen is one-way and one-shot: the canvas is dead to
    // the main thread afterwards, so this must happen exactly once, and only
    // once the Worker exists to receive it.
    function sendMinimap() {
      if (!worker || !pendingMinimap || minimapSent) return;
      if (typeof pendingMinimap.transferControlToOffscreen !== 'function') return;
      try {
        var surface = pendingMinimap.transferControlToOffscreen();
        minimapSent = true;
        pendingMinimap = null;
        worker.postMessage({ type: 'minimap', canvas: surface }, [surface]);
      } catch (error) {
        console.warn('Minimap unavailable', error);
        pendingMinimap = null;
      }
    }

    if (!canvas || typeof canvas.transferControlToOffscreen !== 'function') {
      showFailure(new Error('This browser does not support OffscreenCanvas Workers'));
    } else {
      try {
        offscreen = canvas.transferControlToOffscreen();
      } catch (error) {
        showFailure(error);
      }
    }

    function readViewport() {
      var rect = canvas.getBoundingClientRect();
      viewport = {
        width: Math.max(1, rect.width || canvas.clientWidth || 1),
        height: Math.max(1, rect.height || canvas.clientHeight || 1),
        dpr: window.devicePixelRatio || 1
      };
      return viewport;
    }

    function postViewport() {
      readViewport();
      if (worker && started) {
        worker.postMessage({
          type: 'resize',
          width: viewport.width,
          height: viewport.height,
          dpr: viewport.dpr
        });
      }
    }

    function animate(now) {
      if (failed || !loaded || !worker) return;
      if (!lastFrame) lastFrame = now;
      accumulator = Math.min(accumulator + Math.min(now - lastFrame, 250), 250);
      lastFrame = now;
      if (!advanceInFlight && accumulator >= frameMs) {
        // A batch of six frames is a catch-up for a Worker that is keeping up.
        // When the previous batch overran its own frame budget — the
        // background precompute walk on a long replay, or a seek converging —
        // the Worker is the bottleneck, and a batch is exactly how long a
        // click's seek then sits in the message queue. Drop to one frame per
        // message so an input waits at most one frame.
        var maxFrames = lastAdvanceMs > frameMs ? 1 : 6;
        var frames = Math.min(maxFrames, Math.floor(accumulator / frameMs));
        accumulator -= frames * frameMs;
        advanceInFlight = true;
        advanceStarted = now;
        worker.postMessage({ type: 'advance', frames: frames });
      }
      requestAnimationFrame(animate);
    }

    function onWorkerMessage(event) {
      if (failed) return;
      var message = event.data || {};
      try {
        if (message.type === 'text') {
          // hasZoneField rides along so the page can decide, synchronously
          // inside its onText handler, whether the completion beat has
          // anything to play — the SAME state frame ph:'gameover' arrives on.
          if (config.onText) config.onText(message.text, message.hasZoneField);
        } else if (message.type === 'status') {
          if (config.onStatus) config.onStatus(message.status);
        } else if (message.type === 'firstFrame') {
          if (config.onFirstFrame) config.onFirstFrame();
          markReady();
        } else if (message.type === 'transform') {
          transform = message.transform;
          // The view lives a thread away, so the page's controls can only learn
          // about a zoom/pan when the Worker says so — same callback the
          // in-process core fires, so the page has one code path.
          if (config.onTransform) config.onTransform(transform);
        } else if (message.type === 'loaded') {
          setMismatchTick(message.mismatchTick);
          if (typeof message.zoneEndcardMs === 'number') {
            zoneEndcardMs = message.zoneEndcardMs;
          }
          // SEASON 2 observability: the play-call ("flash") records the
          // runtime decoded from the replay's shell metadata, forwarded
          // once — the comms feed renders them beside the huddle
          // transcript. Absent (no calls in the replay, or an older wasm
          // bundle) the page hook is simply never called.
          if (message.calls && config.onCalls) {
            try { config.onCalls(JSON.parse(message.calls)); } catch (ignored) {}
          }
          loaded = true;
          document.documentElement.setAttribute('data-replay-loaded', 'true');
          markReady();
          requestAnimationFrame(animate);
        } else if (message.type === 'advanced') {
          setMismatchTick(message.mismatchTick);
          lastAdvanceMs = advanceStarted
            ? (typeof performance !== 'undefined' ? performance.now() : Date.now()) - advanceStarted
            : 0;
          advanceInFlight = false;
          if (typeof message.draws === 'number') workerDraws = message.draws;
        } else if (message.type === 'inputApplied') {
          // One frame the Worker ran on its own to apply a viewer input
          // promptly. Nothing to reschedule — the rAF loop owns pacing.
          setMismatchTick(message.mismatchTick);
        } else if (message.type === 'phase') {
          // The Worker has no window.parent of its own; relay its load marks.
          tellHost({
            type: 'phase',
            phase: message.phase,
            bytes: message.bytes,
            compressed: message.compressed
          });
        } else if (message.type === 'error') {
          showFailure(new Error(message.message || 'Replay Worker failed'));
          stop();
        }
      } catch (error) {
        showFailure(error);
      }
    }

    function start() {
      if (started || !offscreen || failed) return;
      started = true;
      // Host mints index.html?v=2#replay=<url> (fragment is not in the HTTP
      // request, so the immutable HTML cache key does not vary per episode).
      // Read loc.hash first; keep ?replay= as the local-URL fallback.
      var replayUrl =
        new URLSearchParams((location.hash || '').slice(1)).get('replay') ||
        new URLSearchParams(location.search).get('replay');
      if (!replayUrl) {
        showFailure(new Error('Missing required replay URL'));
        return;
      }
      readViewport();
      if (config.onStatus) config.onStatus('connecting');
      try {
        worker = new Worker(workerUrl, { name: 'ctf-static-replay' });
        worker.onmessage = onWorkerMessage;
        worker.onerror = function (event) {
          // A Worker that dies at MODULE LOAD — a temporal-dead-zone
          // reference in broadcast_core.js, a 404 on an importScripts
          // target — reports HERE and nowhere else. Reading only
          // `event.message` throws away the only two fields that say
          // where: filename and lineno. That is what made the 2026-08-25
          // ZONE_BEAD_TICKS TDZ read as a fault in this file, ~80 lines
          // from the real one, and it is why tools/qa_module_eval.cjs now
          // evaluates the worker's whole importScripts chain. Keep them.
          var where = event && event.filename
            ? ' (' + event.filename +
              (event.lineno ? ':' + event.lineno : '') + ')'
            : '';
          var detail = (event && event.message) ||
            (event && event.error && event.error.message) || '';
          showFailure(new Error(detail
            ? detail + where
            : 'Replay Worker crashed before it could report' + where));
          stop();
        };
        worker.onmessageerror = function () {
          showFailure(new Error('Replay Worker sent an unreadable message'));
          stop();
        };
        worker.postMessage({
          type: 'init',
          replayUrl: replayUrl,
          canvas: offscreen,
          width: viewport.width,
          height: viewport.height,
          dpr: viewport.dpr
        }, [offscreen]);
        sendMinimap();
        document.documentElement.setAttribute('data-replay-worker', 'true');
      } catch (error) {
        showFailure(error);
      }
    }

    function stop() {
      if (!worker) return;
      worker.postMessage({ type: 'dispose' });
      worker.terminate();
      worker = null;
    }

    window.addEventListener('pagehide', stop, { once: true });

    return {
      start: start,
      stop: stop,
      sendCommand: function (text) {
        if (worker) worker.postMessage({ type: 'command', text: text });
      },
      clickMap: function (mapX, mapY) {
        if (worker) worker.postMessage({ type: 'click', x: mapX, y: mapY });
      },
      // Flash observability: the page resolves each flash record's seat to
      // its CURRENT roster index and hands the enriched list to the core
      // (which anchors the in-arena pulse ring on that player's rig) — see
      // broadcast_core.js setFlashCalls. Re-sent whenever the mapping moves.
      setFlashCalls: function (calls) {
        if (worker) worker.postMessage({ type: 'flashCalls', calls: calls });
      },
      // Zoom/pan forwarded to the worker that owns the OffscreenCanvas. Same
      // signatures as the in-process core, so the page drives one API whether
      // it renders here or in a worker.
      zoomAt: function (factor, x, y) {
        if (worker) worker.postMessage({ type: 'view', action: 'zoom', factor: factor, x: x, y: y });
      },
      setZoom: function (level, x, y) {
        if (worker) worker.postMessage({ type: 'view', action: 'setZoom', level: level, x: x, y: y });
      },
      panBy: function (dx, dy) {
        if (worker) worker.postMessage({ type: 'view', action: 'pan', dx: dx, dy: dy });
      },
      panByMap: function (dx, dy) {
        if (worker) worker.postMessage({ type: 'view', action: 'panMap', dx: dx, dy: dy });
      },
      panTo: function (x, y) {
        if (worker) worker.postMessage({ type: 'view', action: 'panTo', x: x, y: y });
      },
      resetView: function () {
        if (worker) worker.postMessage({ type: 'view', action: 'reset' });
      },
      // Mirrors the in-process core's beginZoneEndcard: the page calls this
      // the instant it sees ph:'gameover', and the Worker (which owns the
      // actual core) arms the paint-completion + terminal-splat beat.
      beginZoneEndcard: function () {
        if (worker) worker.postMessage({ type: 'endcard' });
      },
      getZoneEndcardMs: function () { return zoneEndcardMs; },
      // The board pixels the minimap shrinks live in the Worker, so the Worker
      // has to draw it: hand over control of the page's minimap canvas exactly
      // once and let the core keep it in sync from there.
      attachMinimap: function (surface) {
        // The page wires its controls before start(), so hold the surface until
        // there is a Worker to hand it to.
        pendingMinimap = surface || null;
        sendMinimap();
      },
      getTransform: function () { return transform; },
      setViewportFit: postViewport,
      getPaceStats: function () {
        // `draws` mirrors the Worker core's blit count (refreshed on every
        // 'advanced' ack), so the page can observe the real presentation
        // rate even though drawing happens a thread away.
        return {
          enabled: false,
          queued: 0,
          presented: 0,
          interval: frameMs,
          draws: workerDraws
        };
      }
    };
  }

  window.CtfStaticReplay = {
    createCore: createCore
  };
})();
