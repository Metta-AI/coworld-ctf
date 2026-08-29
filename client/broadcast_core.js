// broadcast_core.js — Bitworld sprite protocol v1 client core
// Dependency-free IIFE module for inlining into standalone HTML

(function() {
  'use strict';

  // ========== Vendored SnappyJS (MIT) ==========
  // @license MIT (http://opensource.org/licenses/MIT)
  // author: Zhipeng Jia
  // version: 0.7.0
  (function(r,e,n){function t(i,f){if(!e[i]){if(!r[i]){var c="function"==typeof require&&require;if(!f&&c)return c(i,!0);if(o)return o(i,!0);var a=new Error("Cannot find module '"+i+"'");throw a.code="MODULE_NOT_FOUND",a}var p=e[i]={exports:{}};r[i][0].call(p.exports,function(e){var n=r[i][1][e];return t(n||e)},p,p.exports,r,e,n)}return e[i].exports}for(var o="function"==typeof require&&require,i=0;i<n.length;i++)t(n[i]);return t})({1:[function(require,module,exports){var SnappyJS={};SnappyJS.uncompress=require("./index").uncompress,SnappyJS.compress=require("./index").compress,window.SnappyJS=SnappyJS;},{"./index":2}],2:[function(require,module,exports){"use strict";function isNode(){return"object"==typeof process&&"object"==typeof process.versions&&void 0!==process.versions.node}function isUint8Array(r){return r instanceof Uint8Array&&(!isNode()||!Buffer.isBuffer(r))}function isArrayBuffer(r){return r instanceof ArrayBuffer}function isBuffer(r){return!!isNode()&&Buffer.isBuffer(r)}var SnappyDecompressor=require("./snappy_decompressor").SnappyDecompressor,SnappyCompressor=require("./snappy_compressor").SnappyCompressor,TYPE_ERROR_MSG="Argument compressed must be type of ArrayBuffer, Buffer, or Uint8Array";function uncompress(r,e){if(!isUint8Array(r)&&!isArrayBuffer(r)&&!isBuffer(r))throw new TypeError(TYPE_ERROR_MSG);var s=!1,n=!1;isUint8Array(r)?s=!0:isArrayBuffer(r)&&(n=!0,r=new Uint8Array(r));var o,f,i=new SnappyDecompressor(r),t=i.readUncompressedLength();if(-1===t)throw new Error("Invalid Snappy bitstream");if(t>e)throw new Error("The uncompressed length of "+t+" is too big, expect at most "+e);if(s){if(o=new Uint8Array(t),!i.uncompressToBuffer(o))throw new Error("Invalid Snappy bitstream")}else if(n){if(o=new ArrayBuffer(t),f=new Uint8Array(o),!i.uncompressToBuffer(f))throw new Error("Invalid Snappy bitstream")}else if(o=Buffer.alloc(t),!i.uncompressToBuffer(o))throw new Error("Invalid Snappy bitstream");return o}function compress(r){if(!isUint8Array(r)&&!isArrayBuffer(r)&&!isBuffer(r))throw new TypeError(TYPE_ERROR_MSG);var e=!1,s=!1;isUint8Array(r)?e=!0:isArrayBuffer(r)&&(s=!0,r=new Uint8Array(r));var n,o,f,i=new SnappyCompressor(r),t=i.maxCompressedLength();if(e?(n=new Uint8Array(t),f=i.compressToBuffer(n)):s?(n=new ArrayBuffer(t),o=new Uint8Array(n),f=i.compressToBuffer(o)):(n=Buffer.alloc(t),f=i.compressToBuffer(n)),!n.slice){var p=new Uint8Array(Array.prototype.slice.call(n,0,f));if(e)return p;if(s)return p.buffer;throw new Error("Not implemented")}return n.slice(0,f)}exports.uncompress=uncompress,exports.compress=compress;},{"./snappy_compressor":3,"./snappy_decompressor":4}],3:[function(require,module,exports){"use strict";var BLOCK_LOG=16,BLOCK_SIZE=1<<BLOCK_LOG,MAX_HASH_TABLE_BITS=14,globalHashTables=new Array(MAX_HASH_TABLE_BITS+1);function hashFunc(r,a){return 506832829*r>>>a}function load32(r,a){return r[a]+(r[a+1]<<8)+(r[a+2]<<16)+(r[a+3]<<24)}function equals32(r,a,e){return r[a]===r[e]&&r[a+1]===r[e+1]&&r[a+2]===r[e+2]&&r[a+3]===r[e+3]}function copyBytes(r,a,e,o,n){var t;for(t=0;t<n;t++)e[o+t]=r[a+t]}function emitLiteral(r,a,e,o,n){return e<=60?(o[n]=e-1<<2,n+=1):e<256?(o[n]=240,o[n+1]=e-1,n+=2):(o[n]=244,o[n+1]=e-1&255,o[n+2]=e-1>>>8,n+=3),copyBytes(r,a,o,n,e),n+e}function emitCopyLessThan64(r,a,e,o){return o<12&&e<2048?(r[a]=1+(o-4<<2)+(e>>>8<<5),r[a+1]=255&e,a+2):(r[a]=2+(o-1<<2),r[a+1]=255&e,r[a+2]=e>>>8,a+3)}function emitCopy(r,a,e,o){for(;o>=68;)a=emitCopyLessThan64(r,a,e,64),o-=64;return o>64&&(a=emitCopyLessThan64(r,a,e,60),o-=60),emitCopyLessThan64(r,a,e,o)}function compressFragment(r,a,e,o,n){for(var t=1;1<<t<=e&&t<=MAX_HASH_TABLE_BITS;)t+=1;var s=32-(t-=1);void 0===globalHashTables[t]&&(globalHashTables[t]=new Uint16Array(1<<t));var i,u,p,h,l,f,c,m,y,L,C=a+e,T=a,S=a,_=!0;if(e>=15)for(i=C-15,p=hashFunc(load32(r,a+=1),s);_;){f=32,h=a;do{if(u=p,c=f>>>5,f+=1,h=(a=h)+c,a>i){_=!1;break}p=hashFunc(load32(r,h),s),l=T+globalHashTables[u],globalHashTables[u]=a-T}while(!equals32(r,a,l));if(!_)break;n=emitLiteral(r,S,a-S,o,n);do{for(m=a,y=4;a+y<C&&r[a+y]===r[l+y];)y+=1;if(a+=y,n=emitCopy(o,n,m-l,y),S=a,a>=i){_=!1;break}globalHashTables[hashFunc(load32(r,a-1),s)]=a-1-T,l=T+globalHashTables[L=hashFunc(load32(r,a),s)],globalHashTables[L]=a-T}while(equals32(r,a,l));if(!_)break;p=hashFunc(load32(r,a+=1),s)}return S<C&&(n=emitLiteral(r,S,C-S,o,n)),n}function putVarint(r,a,e){do{a[e]=127&r,(r>>>=7)>0&&(a[e]+=128),e+=1}while(r>0);return e}function SnappyCompressor(r){this.array=r}SnappyCompressor.prototype.maxCompressedLength=function(){var r=this.array.length;return 32+r+Math.floor(r/6)},SnappyCompressor.prototype.compressToBuffer=function(r){var a,e=this.array,o=e.length,n=0,t=0;for(t=putVarint(o,r,t);n<o;)t=compressFragment(e,n,a=Math.min(o-n,BLOCK_SIZE),r,t),n+=a;return t},exports.SnappyCompressor=SnappyCompressor;},{}],4:[function(require,module,exports){"use strict";var WORD_MASK=[0,255,65535,16777215,4294967295];function copyBytes(r,e,s,t,o){var p;for(p=0;p<o;p++)s[t+p]=r[e+p]}function selfCopyBytes(r,e,s,t){var o;for(o=0;o<t;o++)r[e+o]=r[e-s+o]}function SnappyDecompressor(r){this.array=r,this.pos=0}SnappyDecompressor.prototype.readUncompressedLength=function(){for(var r,e,s=0,t=0;t<32&&this.pos<this.array.length;){if(r=this.array[this.pos],this.pos+=1,(e=127&r)<<t>>>t!==e)return-1;if(s|=e<<t,r<128)return s;t+=7}return-1},SnappyDecompressor.prototype.uncompressToBuffer=function(r){for(var e,s,t,o,p=this.array,n=p.length,i=this.pos,a=0;i<p.length;)if(e=p[i],i+=1,0==(3&e)){if((s=1+(e>>>2))>60){if(i+3>=n)return!1;t=s-60,s=1+((s=p[i]+(p[i+1]<<8)+(p[i+2]<<16)+(p[i+3]<<24))&WORD_MASK[t]),i+=t}if(i+s>n)return!1;copyBytes(p,i,r,a,s),i+=s,a+=s}else{switch(3&e){case 1:s=4+(e>>>2&7),o=p[i]+(e>>>5<<8),i+=1;break;case 2:if(i+1>=n)return!1;s=1+(e>>>2),o=p[i]+(p[i+1]<<8),i+=2;break;case 3:if(i+3>=n)return!1;s=1+(e>>>2),o=p[i]+(p[i+1]<<8)+(p[i+2]<<16)+(p[i+3]<<24),i+=4}if(0===o||o>a)return!1;selfCopyBytes(r,a,o,s),a+=s}return!0},exports.SnappyDecompressor=SnappyDecompressor;},{}]},{},[1]);
  // ========== End vendored SnappyJS ==========

  const textDecoder = new TextDecoder('utf-8');

  const ZoomableFlag = 1;
  const MapLayerType = 0;
  // Reserved sprite id whose LABEL carries the broadcast chrome JSON on the
  // binary channel (see server: BroadcastChromeSpriteId). Kept off the drawable
  // sprite map and fed straight to onText.
  const CHROME_SPRITE_ID = 4090;

  function readU16(bytes, offset) {
    return bytes[offset] | (bytes[offset + 1] << 8);
  }

  function readU32(bytes, offset) {
    return (bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] * 0x1000000)) >>> 0;
  }

  function readI16(bytes, offset) {
    const value = readU16(bytes, offset);
    return value & 0x8000 ? value - 0x10000 : value;
  }

  function writeI16(bytes, offset, value) {
    value = Math.max(-32768, Math.min(32767, value)) & 0xffff;
    bytes[offset] = value & 255;
    bytes[offset + 1] = value >> 8;
  }

  function writeU16(bytes, offset, value) {
    value = Math.max(0, Math.min(65535, value)) & 0xffff;
    bytes[offset] = value & 255;
    bytes[offset + 1] = value >> 8;
  }

  function decodeSpritePixelsSnappy(compressed, width, height) {
    if (!window.SnappyJS) {
      throw new Error('SnappyJS is not loaded');
    }
    const expected = width * height * 4;
    const pixels = window.SnappyJS.uncompress(compressed, expected);
    const rgba = pixels instanceof Uint8Array ? pixels : new Uint8Array(pixels);
    if (rgba.length !== expected) {
      throw new Error('Bad sprite pixel length');
    }
    return rgba;
  }

  function tryDecodeSpritePixelsSnappy(bytes, offset, remaining, width, height) {
    const expected = width * height * 4;
    if (remaining < 6) return null;
    const compressedLength = readU32(bytes, offset);
    if (compressedLength > remaining - 6) return null;
    const labelOffset = offset + 4 + compressedLength;
    const labelLength = readU16(bytes, labelOffset);
    if (labelLength > remaining - 4 - compressedLength - 2) return null;
    const compressed = bytes.slice(offset + 4, labelOffset);
    let pixels;
    try {
      pixels = decodeSpritePixelsSnappy(compressed, width, height);
    } catch (e) {
      return null;
    }
    const labelStart = labelOffset + 2;
    const labelEnd = labelStart + labelLength;
    return {
      pixels,
      label: textDecoder.decode(bytes.slice(labelStart, labelEnd)),
      offset: labelEnd
    };
  }

  function ensureLayer(layers, id) {
    if (!layers.has(id)) {
      const canvas = document.createElement('canvas');
      const ctx = canvas.getContext('2d');
      ctx.imageSmoothingEnabled = false;
      layers.set(id, {
        id,
        type: MapLayerType,
        flags: ZoomableFlag,
        width: 1,
        height: 1,
        canvas,
        ctx
      });
    }
    return layers.get(id);
  }

  function defineLayer(layers, id, type, flags) {
    const layer = ensureLayer(layers, id);
    layer.type = type;
    layer.flags = flags;
  }

  function setViewport(layers, layerId, width, height, onResize) {
    const layer = ensureLayer(layers, layerId);
    layer.width = width;
    layer.height = height;
    layer.canvas.width = width;
    layer.canvas.height = height;
    if (onResize) onResize();
  }

  // Sprite pixels arrive as straight (non-premultiplied) RGBA. Bake them into
  // a per-sprite canvas once, so composite() is a chain of GPU drawImage calls
  // instead of a per-pixel JS alpha blender. The old putSpritePixel painter
  // cost ~61ms/frame at 268 live objects (6.7M sprite-pixels) and capped the
  // whole viewer at ~12fps; drawImage of a pre-baked canvas is the same
  // src-over math done by the compositor.
  function spriteCanvas(sprite) {
    if (sprite.baked) return sprite.baked;
    if (!sprite.width || !sprite.height || !sprite.pixels) return null;
    const canvas = document.createElement('canvas');
    canvas.width = sprite.width;
    canvas.height = sprite.height;
    const ctx = canvas.getContext('2d');
    const image = ctx.createImageData(sprite.width, sprite.height);
    image.data.set(sprite.pixels);
    ctx.putImageData(image, 0, 0);
    sprite.baked = canvas;
    return canvas;
  }

  function websocketPathForClientPage(path) {
    const mappings = [
      ['/client/global', '/global'],
      ['/client/replay', '/replay'],
      ['/client/player', '/player'],
      // The live player view (our client, not bitworld's) rides the same
      // per-seat `/player` socket the stock client does.
      ['/client/play', '/player'],
      ['/client/rewards', '/reward'],
      ['/client/admin', '/admin'],
      ['/clients/replay', '/replay']
    ];
    for (const [clientPath, websocketPath] of mappings) {
      if (path === clientPath) {
        return websocketPath;
      }
      if (path.endsWith(clientPath)) {
        return path.slice(0, path.length - clientPath.length) + websocketPath;
      }
    }
    return path;
  }

  function websocketAddress(pageUrl) {
    const url = new URL(pageUrl);
    const protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
    const host = url.host || 'localhost:8080';
    const wsPath = websocketPathForClientPage(url.pathname);
    const wsUrl = new URL(protocol + '//' + host + wsPath);
    for (const key of ['name', 'slot', 'token', 'uri']) {
      const value = url.searchParams.get(key);
      if (value !== null) {
        wsUrl.searchParams.set(key, value);
      }
    }
    return wsUrl.toString();
  }

  function BroadcastCore(config) {
    const canvas = config.canvas;
    const onText = config.onText || (() => {});
    const onStatus = config.onStatus || (() => {});
    const onFirstFrame = config.onFirstFrame || (() => {});
    const websocketEnabled = config.websocket !== false;
    const onSendPacket = config.onSendPacket || null;
    const ctx = canvas.getContext('2d');
    ctx.imageSmoothingEnabled = false;

    const layers = new Map();
    const sprites = new Map();
    const objects = new Map();

    let socket = null;
    let rafHandle = null;
    let dirty = false;
    let firstFrameFired = false;
    let offscreenCanvas = null;
    let offscreenCtx = null;
    let nativeW = 1, nativeH = 1;
    let scale = 1, offsetX = 0, offsetY = 0;
    // ---- follow camera (live player view) ----
    // Null = the replay viewer's behaviour, unchanged: fit the whole arena into
    // the canvas and letterbox the remainder. Set = follow a point in BOARD
    // pixels at a fixed on-screen width, which is what lets a human find their
    // own cog among fifteen bots instead of hunting a 16px sprite in a
    // bird's-eye view of the whole map (playtest failure #1).
    //
    // The target moves at the sim's 24Hz while the display runs at 60-120Hz, so
    // the camera EASES toward it in draw() rather than snapping per tick — a
    // camera that steps at tick rate makes the whole world judder even though
    // every sprite on it is already interpolated.
    let camera = null;            // {x, y, viewW} in board px, or null for fit
    let camX = 0, camY = 0;       // the eased position actually drawn
    let camPrimed = false;        // first target snaps; later ones ease
    let camLastDraw = 0;
    const CAM_TAU_MS = 90;        // ease time constant
    const CAM_SETTLE_PX = 0.25;   // below this the ease is done
    let reconnectDelay = 1000;
    const maxReconnectDelay = 8000;
    let reconnecting = false;
    let stopped = false;

    // ---- Playout buffer (jitter absorption) ----
    // The stream leaves the server at a clean source cadence (~24fps), but the
    // delivery chain (container → kube proxy → backend → nginx) is bursty:
    // gaps >100ms followed by catch-up bursts. Drawing on arrival turns that
    // into freeze-then-jump. Instead, queue incoming messages and present them
    // on a fixed cadence inferred from the arrival rate, cushioned by a couple
    // of frame intervals. Messages are stateful deltas (sprite defs, object
    // moves), so backlog control must fast-forward — apply everything, draw
    // once — never discard, or sprite/object state corrupts.
    const paceEnabled = config.playoutBuffer !== false;
    const onFrame = config.onFrame || null;
    // 12 frames ≈ 500ms at 24fps: replay playback has no latency budget, so a
    // deep cushion that rides out measured WAN delivery stalls (p99 ≈ 400-500ms
    // against production, July 2026) beats the responsiveness a live viewer
    // would want. Live surfaces pass their own paceTargetDepth.
    //
    // `|| 12` was the bug: a SEATED player's `me` truth rode this exact 12-frame
    // cushion with no override ever supplied (the LIVE call site in
    // replay_broadcast.html built its config with no paceTargetDepth key at
    // all), so input read back through ~0.5s of stale world state -- measured
    // 1274ms between shots against the engine's own 708ms cooldown (see the
    // fire-pulse note below). `|| 12` also can never accept 0: `0 || 12` is
    // 12, so a caller asking for the minimum buffer would have silently gotten
    // the deep one anyway. A live surface now passes 0 explicitly, so the
    // fallback must distinguish "not provided" from "provided as zero".
    const PACE_TARGET_DEPTH = (typeof config.paceTargetDepth === "number") ? config.paceTargetDepth : 12;
    const PACE_MAX_DEPTH = PACE_TARGET_DEPTH + 7;
    const PACE_HARD_QUEUE = 240;
    const PACE_MIN_INTERVAL = 1000 / 60;
    const PACE_MAX_INTERVAL = 1000 / 10;
    const PACE_WINDOW = 48;
    const PACE_PRIME_TIMEOUT = 300;
    let paceQueue = [];
    let paceBinaryCount = 0;
    let paceArrivals = [];
    let paceInterval = 1000 / 24;
    let paceNextDue = 0;
    let pacePrimed = false;
    let paceFirstArrival = 0;
    let pacePresented = 0;
    let paceRaf = null;
    let paceTimer = null;

    function mapLayer() {
      for (const layer of layers.values()) {
        if ((layer.flags & ZoomableFlag) !== 0 || layer.type === MapLayerType) {
          return layer;
        }
      }
      return null;
    }

    function computeNativeSize() {
      let maxW = 1, maxH = 1;
      for (const layer of layers.values()) {
        if ((layer.flags & ZoomableFlag) !== 0 || layer.type === MapLayerType) {
          maxW = Math.max(maxW, layer.width);
          maxH = Math.max(maxH, layer.height);
        }
      }
      return { w: maxW, h: maxH };
    }

    function updateNativeSize() {
      const size = computeNativeSize();
      nativeW = size.w;
      nativeH = size.h;
      if (!offscreenCanvas) {
        offscreenCanvas = document.createElement('canvas');
        offscreenCtx = offscreenCanvas.getContext('2d');
        offscreenCtx.imageSmoothingEnabled = false;
      }
      if (offscreenCanvas.width !== nativeW) offscreenCanvas.width = nativeW;
      if (offscreenCanvas.height !== nativeH) offscreenCanvas.height = nativeH;
    }

    function computeFit() {
      const dpr = window.devicePixelRatio || 1;
      const cssW = canvas.clientWidth || canvas.width / dpr;
      const cssH = canvas.clientHeight || canvas.height / dpr;
      const scaleX = cssW / nativeW;
      const scaleY = cssH / nativeH;
      const fitScale = Math.min(scaleX, scaleY);
      if (camera) {
        // Never zoom OUT past the fit view: below it the follow camera would
        // show less board than the fallback while still refusing to sit still.
        scale = Math.max(fitScale, cssW / Math.max(1, camera.viewW));
        const drawW = nativeW * scale;
        const drawH = nativeH * scale;
        // Clamp the pan to the board's own edges. Letting the camera run past
        // them puts half a screen of dead stage next to the arena wall, which
        // reads as a broken viewport rather than as "you are at the edge".
        const wantX = cssW / 2 - camX * scale;
        const wantY = cssH / 2 - camY * scale;
        offsetX = drawW <= cssW
          ? (cssW - drawW) / 2
          : Math.min(0, Math.max(cssW - drawW, wantX));
        offsetY = drawH <= cssH
          ? (cssH - drawH) / 2
          : Math.min(0, Math.max(cssH - drawH, wantY));
        return;
      }
      scale = fitScale;
      const drawW = nativeW * scale;
      const drawH = nativeH * scale;
      offsetX = (cssW - drawW) / 2;
      offsetY = (cssH - drawH) / 2;
    }

    function stepCamera(now) {
      // Returns true while the ease is still in flight, so draw() knows to keep
      // repainting at display rate the same way an in-flight sprite lerp does.
      if (!camera) return false;
      if (!camPrimed) {
        camX = camera.x; camY = camera.y; camPrimed = true; camLastDraw = now;
        return false;
      }
      const dt = Math.max(0, Math.min(250, now - camLastDraw));
      camLastDraw = now;
      const a = 1 - Math.exp(-dt / CAM_TAU_MS);
      camX += (camera.x - camX) * a;
      camY += (camera.y - camY) * a;
      return Math.abs(camera.x - camX) > CAM_SETTLE_PX ||
        Math.abs(camera.y - camY) > CAM_SETTLE_PX;
    }

    function setCamera(next) {
      // {x, y, viewW} in board pixels. Re-priming on a >1 screen jump keeps a
      // respawn across the map from sliding the camera through every wall in
      // between.
      if (!next) { camera = null; camPrimed = false; scheduleDraw(); return; }
      if (camera && camPrimed) {
        const jump = Math.hypot(next.x - camX, next.y - camY);
        if (jump > Math.max(1, next.viewW)) camPrimed = false;
      }
      camera = next;
      scheduleDraw();
    }

    function cameraActive() { return camera !== null; }

    // ---- player input (live seats) ----
    // Sprite v1 input packet: [0x84][held-button mask]. Sent ON CHANGE ONLY,
    // matching the native client — the server diffs each arriving mask against
    // the one it stored to synthesise its own press edges, so a resent
    // identical mask is pure noise. `lastSentMask` starts at a value no real
    // mask can equal, so the first genuine mask always goes out even if it is 0.
    let lastSentMask = -1;
    function sendInputMask(mask) {
      const m = mask & 0xff;
      if (m === lastSentMask) return;
      lastSentMask = m;
      const packet = new Uint8Array(2);
      packet[0] = 0x84;
      packet[1] = m;
      sendPacket(packet);
    }

    // ---- Motion interpolation (rendering only) ----
    // The sim ticks at ~24Hz while displays run 60-120Hz, so drawing objects
    // only at their per-tick positions reads as 24fps-steppy motion. Between
    // ticks, ease each object's TRANSLATE from where it was rendered when its
    // latest move arrived toward its authoritative wire position. Sprite
    // swaps and fog appear/disappear apply instantly (never blended), and any
    // per-tick jump beyond LERP_SNAP_PX (seeks, loop restarts, respawns,
    // teleports, fast movers at 8x/16x playback) snaps. Sim truth is never
    // touched: obj.x/obj.y stay the exact wire values; only the blit offset
    // eases toward them.
    // Escape hatch: ?nolerp=1 in the page URL (or interpolate:false in the
    // core config) restores draw-at-tick-positions exactly.
    const interpolateEnabled = config.interpolate !== false && (() => {
      try {
        return new URLSearchParams(window.location.search).get('nolerp') !== '1';
      } catch (e) { return true; }
    })();
    // Field-measured per-tick motion at 1x is p50 6px / max 10px, and the sim
    // multiplies per-packet displacement (not packet rate) at 2x-16x speed, so
    // 48px lerps genuine motion through ~4x and snaps discontinuities.
    const LERP_SNAP_PX = 48;
    const LERP_WINDOW_MIN = 16;
    const LERP_WINDOW_MAX = 100;
    let lerpWindow = 1000 / 24; // EMA of the real inter-tick present interval
    let lerpLastMove = 0;       // parse timestamp of the last packet that moved anything
    let lerpDeadline = 0;       // when every in-flight lerp has landed

    function lerpAlpha(obj, now) {
      if (!obj.lt) return 1;
      const a = (now - obj.lt) / lerpWindow;
      return a >= 1 ? 1 : (a < 0 ? 0 : a);
    }

    // ---- Size interpolation (rendering only) ----
    // A sprite SWAP applies instantly (never blended) above, which is right
    // for content (a stage's baked alpha, a new pose) but wrong when the
    // swap ALSO changes the sprite's own baked pixel DIMENSIONS -- e.g. a
    // glory claim's one-shot spawn overshoot (SPLAT C8: 132% at stage 0, then
    // 100%). The server only ever bakes a FEW discrete sizes per pop (so the
    // compose cost stays bounded, see buildGloryChipSprite's own cache), so
    // fixing the granularity server-side would either reintroduce that cost
    // or still leave a client rendering at whatever tick rate it happens to
    // receive packets. Instead ease the DRAWN width/height toward the new
    // sprite's true size here, independently of position (a resize can land
    // on a tick that does not move the object at all), the same way
    // drawX/drawY already ease toward x/y above.
    function sizeLerpAlpha(obj, now) {
      if (!obj.slt) return 1;
      const a = (now - obj.slt) / lerpWindow;
      return a >= 1 ? 1 : (a < 0 ? 0 : a);
    }

    function composite() {
      const now = interpolateEnabled ? performance.now() : 0;
      const orderedLayers = [...layers.values()]
        .filter(layer => (layer.flags & ZoomableFlag) !== 0 || layer.type === MapLayerType)
        .sort((a, b) => a.id - b.id);

      offscreenCtx.clearRect(0, 0, nativeW, nativeH);

      for (const layer of orderedLayers) {
        const ordered = [...objects.values()]
          .filter(obj => obj.layer === layer.id)
          .sort((a, b) => a.z - b.z || a.y - b.y || a.id - b.id);
        if (ordered.length === 0) continue;
        layer.ctx.clearRect(0, 0, layer.width, layer.height);
        for (const obj of ordered) {
          const sprite = sprites.get(obj.spriteId);
          if (!sprite) continue;
          const baked = spriteCanvas(sprite);
          if (!baked) continue;
          let drawX = obj.x, drawY = obj.y;
          if (interpolateEnabled && obj.lt) {
            const a = lerpAlpha(obj, now);
            if (a < 1) {
              drawX = Math.round(obj.px + (obj.x - obj.px) * a);
              drawY = Math.round(obj.py + (obj.y - obj.py) * a);
            }
          }
          let drawW = sprite.width, drawH = sprite.height;
          if (interpolateEnabled && obj.slt) {
            const sa = sizeLerpAlpha(obj, now);
            if (sa < 1) {
              drawW = Math.max(1, obj.pw + (sprite.width - obj.pw) * sa);
              drawH = Math.max(1, obj.ph + (sprite.height - obj.ph) * sa);
            }
          }
          // imageSmoothingEnabled stays false (set once on this layer's own
          // ctx, ensureLayer) even while drawW/drawH differ from the baked
          // canvas's true size: a nearest-neighbor resample keeps every
          // single FRAME crisp (retro pixel art, never a bilinear wash)
          // while the SIZE itself still glides smoothly frame to frame — the
          // motion reads continuous even though each still is blocky.
          layer.ctx.drawImage(baked, drawX, drawY, drawW, drawH);
        }
        offscreenCtx.drawImage(layer.canvas, 0, 0);
      }
      dirty = false;
    }

    function draw() {
      const dpr = window.devicePixelRatio || 1;
      const cssW = canvas.clientWidth || canvas.width / dpr;
      const cssH = canvas.clientHeight || canvas.height / dpr;
      if (canvas.width !== cssW * dpr) canvas.width = cssW * dpr;
      if (canvas.height !== cssH * dpr) canvas.height = cssH * dpr;

      const camMoving = stepCamera(performance.now());

      computeFit();

      ctx.fillStyle = '#000';
      ctx.fillRect(0, 0, canvas.width, canvas.height);

      if (dirty) {
        composite();
      }

      if (offscreenCanvas && nativeW > 0 && nativeH > 0) {
        ctx.save();
        ctx.scale(dpr, dpr);
        ctx.translate(offsetX, offsetY);
        // Nearest-neighbor at ALL scales (matches #board's image-rendering:
        // pixelated). The old code force-enabled smoothing whenever the board
        // had to shrink (scale < 1, e.g. small windows or side panels eating
        // width), which softened the ENTIRE board — floor, cracks, sprites —
        // into a uniform blur. Retro pixel art wants crisp pixels, never a
        // bilinear wash, so keep smoothing off in every regime.
        ctx.imageSmoothingEnabled = false;
        ctx.drawImage(offscreenCanvas, 0, 0, nativeW * scale, nativeH * scale);
        ctx.restore();
      }

      // Keep repainting at display rate while any lerp is in flight; once the
      // deadline passes every object sits at its wire position and the redraw
      // chain goes idle until the next packet dirties it.
      if (interpolateEnabled && performance.now() < lerpDeadline) {
        dirty = true;
        scheduleDraw();
      } else if (camMoving) {
        scheduleDraw();
      }
    }

    function scheduleDraw() {
      if (rafHandle) return;
      rafHandle = requestAnimationFrame(() => {
        rafHandle = null;
        draw();
      });
    }

    function parse(bytes) {
      let offset = 0;
      let changed = false;
      let moved = false;
      const parseNow = interpolateEnabled ? performance.now() : 0;
      while (offset < bytes.length) {
        const type = bytes[offset++];
        if (type === 0x01) {
          const id = readU16(bytes, offset);
          const width = readU16(bytes, offset + 2);
          const height = readU16(bytes, offset + 4);
          offset += 6;
          const remaining = bytes.length - offset;
          const snappySprite = tryDecodeSpritePixelsSnappy(
            bytes,
            offset,
            remaining,
            width,
            height
          );
          let pixels, label = '';
          if (snappySprite) {
            pixels = snappySprite.pixels;
            label = snappySprite.label;
            offset = snappySprite.offset;
          } else {
            offset += width * height;
          }
          // Broadcast chrome (scorebug/clock/scrubber/roster/events) is smuggled
          // as the label of a reserved 1×1 sprite (id 4090). Route it to onText
          // exactly like the legacy TextMessage chrome channel. This binary path
          // is the ONLY one that survives a hosted replay, where the interactive
          // TextMessage opt-in never routes through the recorded stream. Never
          // register it as a drawable sprite.
          if (id === CHROME_SPRITE_ID) {
            if (label) onText(label);
          } else {
            // A fresh entry drops any previously baked canvas; spriteCanvas()
            // re-bakes lazily on the next blit that references it.
            sprites.set(id, { width, height, pixels, label });
          }
          changed = true;
        } else if (type === 0x02) {
          const id = readU16(bytes, offset);
          const x = readI16(bytes, offset + 2);
          const y = readI16(bytes, offset + 4);
          const z = readI16(bytes, offset + 6);
          const layer = bytes[offset + 8];
          const spriteId = readU16(bytes, offset + 9);
          const prev = objects.get(id);
          // px/py: where the blit renders FROM while easing toward x/y.
          // pw/ph: same idea for SIZE (see sizeLerpAlpha) -- 0/0 with slt
          // left falsy reads as "no ease in flight" (sizeLerpAlpha returns 1
          // when slt is falsy, which collapses the lerp formula to the
          // sprite's own true size regardless of pw/ph's placeholder value).
          // Defaults snap: new objects, fog re-entries and cross-layer moves
          // must appear at their true spot/size, never slide or grow there.
          const next = {
            id, x, y, z, layer, spriteId,
            px: x, py: y, lt: 0,
            pw: 0, ph: 0, slt: 0
          };
          if (interpolateEnabled && prev && prev.layer === layer) {
            const dx = x - prev.x;
            const dy = y - prev.y;
            if (dx === 0 && dy === 0) {
              // Identical re-send (~27% of wire traffic): keep the in-flight
              // ease exactly as it was, or it would freeze mid-lerp.
              next.px = prev.px;
              next.py = prev.py;
              next.lt = prev.lt;
            } else if (Math.abs(dx) <= LERP_SNAP_PX && Math.abs(dy) <= LERP_SNAP_PX) {
              // Genuine motion: ease from the currently RENDERED spot so a
              // move landing mid-lerp (or a bunched catch-up step) never
              // jumps backward.
              const a = lerpAlpha(prev, parseNow);
              next.px = prev.px + (prev.x - prev.px) * a;
              next.py = prev.py + (prev.y - prev.py) * a;
              next.lt = parseNow;
              moved = true;
            }
            // else: beyond the snap threshold — seek, loop restart, respawn
            // or 8x/16x fast mover; px/py already snap to x/y.
            // Size: independent of the position branches above (a resize can
            // land on a tick that doesn't move the object at all).
            if (prev.spriteId === spriteId) {
              // Same sprite id: keep any in-flight size ease running.
              next.pw = prev.pw;
              next.ph = prev.ph;
              next.slt = prev.slt;
            } else {
              const prevSprite = sprites.get(prev.spriteId);
              const nextSprite = sprites.get(spriteId);
              if (prevSprite && nextSprite &&
                  (prevSprite.width !== nextSprite.width ||
                   prevSprite.height !== nextSprite.height)) {
                // Ease from prev's own CURRENTLY RENDERED size (mirrors the
                // position branch above) so a second resize landing mid-ease
                // never jumps.
                const sa = sizeLerpAlpha(prev, parseNow);
                next.pw = prev.pw + (prevSprite.width - prev.pw) * sa;
                next.ph = prev.ph + (prevSprite.height - prev.ph) * sa;
                next.slt = parseNow;
              }
              // else: swapped to a same-size (or not-yet-registered) sprite
              // -- nothing to ease; pw/ph/slt stay at next's defaults above.
            }
          }
          objects.set(id, next);
          offset += 11;
          changed = true;
        } else if (type === 0x03) {
          const id = readU16(bytes, offset);
          objects.delete(id);
          offset += 2;
          changed = true;
        } else if (type === 0x04) {
          objects.clear();
          changed = true;
        } else if (type === 0x05) {
          setViewport(layers, bytes[offset], readU16(bytes, offset + 1), readU16(bytes, offset + 3), () => {
            updateNativeSize();
            computeFit();
          });
          offset += 5;
          changed = true;
        } else if (type === 0x06) {
          defineLayer(layers, bytes[offset], bytes[offset + 1], bytes[offset + 2]);
          offset += 3;
        } else if (type === 0x07) {
          offset += 2;
        } else {
          console.warn('Unknown sprite protocol message type:', type);
          if (socket) socket.close();
          break;
        }
      }
      if (moved) {
        // Track the true present cadence (rAF-aligned 24Hz here; live surfaces
        // pace differently) so the ease window matches it. Gaps outside
        // [4, 250]ms are bunched catch-up steps or stalls, not cadence.
        if (lerpLastMove) {
          const gap = parseNow - lerpLastMove;
          if (gap >= 4 && gap <= 250) {
            lerpWindow = Math.min(LERP_WINDOW_MAX,
              Math.max(LERP_WINDOW_MIN, lerpWindow * 0.75 + gap * 0.25));
          }
        }
        lerpLastMove = parseNow;
        lerpDeadline = parseNow + lerpWindow;
      }
      if (changed) {
        dirty = true;
        scheduleDraw();
        if (!firstFrameFired && objects.size > 0) {
          firstFrameFired = true;
          onFirstFrame();
        }
      }
    }

    function pacePresentOne() {
      // Pop entries up to and including the next binary frame; text messages
      // ride along in arrival order without consuming a cadence slot.
      while (paceQueue.length) {
        const entry = paceQueue.shift();
        if (entry.text !== undefined) {
          onText(entry.text);
          continue;
        }
        paceBinaryCount--;
        parse(entry.bytes);
        pacePresented++;
        if (onFrame) onFrame();
        return true;
      }
      return false;
    }

    function paceFastForward(keepDepth) {
      while (paceBinaryCount > keepDepth) pacePresentOne();
    }

    function paceReset() {
      // Drain anything still pending (in order — they're valid deltas), then
      // start priming from scratch. Used on (re)connect.
      paceFastForward(0);
      while (paceQueue.length) {
        const entry = paceQueue.shift();
        if (entry.text !== undefined) onText(entry.text);
      }
      paceArrivals = [];
      paceFirstArrival = 0;
      pacePrimed = false;
    }

    function paceSchedule() {
      // rAF gives paint-aligned pacing when the page is visible, but it
      // throttles or fully stops in hidden/occluded tabs — the timer backstop
      // keeps presentation and backlog control running there. Whichever fires
      // first cancels the other.
      if (!paceRaf) paceRaf = requestAnimationFrame(pacePumpRaf);
      if (!paceTimer) {
        paceTimer = setTimeout(pacePumpTimer, Math.max(25, paceInterval * 1.5));
      }
    }

    function pacePumpRaf(now) {
      paceRaf = null;
      if (paceTimer) {
        clearTimeout(paceTimer);
        paceTimer = null;
      }
      pacePump(now);
    }

    function pacePumpTimer() {
      paceTimer = null;
      if (paceRaf) {
        cancelAnimationFrame(paceRaf);
        paceRaf = null;
      }
      pacePump(performance.now());
    }

    function pacePump(now) {
      if (stopped) return;
      if (paceBinaryCount > PACE_MAX_DEPTH) {
        // Fell behind the live stream (delivery burst or stalled tab): apply
        // the backlog immediately so latency stays bounded at the cushion.
        paceFastForward(PACE_TARGET_DEPTH);
        pacePrimed = true;
        paceNextDue = now;
      }
      if (!pacePrimed &&
          (paceBinaryCount > PACE_TARGET_DEPTH ||
            (paceFirstArrival && now - paceFirstArrival >= PACE_PRIME_TIMEOUT))) {
        pacePrimed = true;
        paceNextDue = now;
      }
      // Text messages at the head arrived before every queued binary frame and
      // their preceding frame is already presented — deliver them now.
      while (paceQueue.length && paceQueue[0].text !== undefined) {
        onText(paceQueue.shift().text);
      }
      if (pacePrimed && paceBinaryCount > 0) {
        if (now - paceNextDue > 2 * paceInterval) {
          // Re-anchor after a long stall instead of machine-gunning the
          // backlog through the cadence (fast-forward bounds the depth).
          paceNextDue = now;
        }
        // Present every due frame, capped per invocation: a throttled driver
        // (1Hz setTimeout in a hidden tab) must still keep up, but a
        // recovering stall shouldn't machine-gun the backlog.
        let budget = 3;
        while (budget > 0 && paceBinaryCount > 0 && now >= paceNextDue) {
          budget--;
          pacePresentOne();
          // Nudge the cadence a few percent to hold the cushion at target
          // depth — imperceptible, but stops underruns from permanently
          // ratcheting latency upward (and overruns from accumulating).
          const drift = Math.max(-2, Math.min(2, paceBinaryCount - PACE_TARGET_DEPTH));
          paceNextDue += paceInterval * (1 - 0.02 * drift);
        }
      }
      if (paceQueue.length) paceSchedule();
    }

    function paceEnqueue(event) {
      const isText = typeof event.data === 'string';
      if (isText) {
        if (paceQueue.length === 0) {
          // Nothing buffered ahead of it — no ordering to preserve.
          onText(event.data);
          return;
        }
        paceQueue.push({ text: event.data });
      } else {
        const now = performance.now();
        if (!paceFirstArrival) paceFirstArrival = now;
        paceArrivals.push(now);
        if (paceArrivals.length > PACE_WINDOW) paceArrivals.shift();
        if (paceArrivals.length >= 8) {
          const span = paceArrivals[paceArrivals.length - 1] - paceArrivals[0];
          const mean = span / (paceArrivals.length - 1);
          paceInterval = Math.min(PACE_MAX_INTERVAL, Math.max(PACE_MIN_INTERVAL, mean));
        }
        paceQueue.push({ bytes: new Uint8Array(event.data) });
        paceBinaryCount++;
        if (paceBinaryCount > PACE_HARD_QUEUE) {
          // rAF isn't firing (hidden tab): drain inline to cap memory.
          paceFastForward(PACE_TARGET_DEPTH);
        }
      }
      paceSchedule();
    }

    function connect() {
      if (stopped) return;
      if (paceEnabled) paceReset();
      const ws = new WebSocket(websocketAddress(window.location.href));
      socket = ws;
      ws.binaryType = 'arraybuffer';
      onStatus('connecting');

      ws.onmessage = event => {
        if (socket !== ws) return;
        if (paceEnabled) {
          paceEnqueue(event);
        } else if (typeof event.data === 'string') {
          onText(event.data);
        } else {
          parse(new Uint8Array(event.data));
          if (onFrame) onFrame();
        }
      };

      ws.onopen = () => {
        if (socket !== ws) return;
        onStatus('open');
        reconnectDelay = 1000;
        // A fresh socket is a fresh server-side mask (it is keyed per
        // connection and starts at 0). Forget what we last sent, or a key held
        // across the reconnect would be deduped into never being re-announced.
        lastSentMask = -1;
        reconnecting = false;
      };

      ws.onclose = () => {
        if (socket !== ws) return;
        socket = null;
        onStatus('closed');
        if (!stopped && !reconnecting) {
          reconnecting = true;
          setTimeout(() => {
            reconnecting = false;
            reconnectDelay = Math.min(reconnectDelay * 2, maxReconnectDelay);
            connect();
          }, reconnectDelay);
        }
      };

      ws.onerror = () => {
        if (socket !== ws) return;
        try { ws.close(); } catch (e) {}
      };
    }

    function sendPacket(bytes) {
      if (onSendPacket) {
        onSendPacket(bytes);
        return;
      }
      if (!socket || socket.readyState !== WebSocket.OPEN) return;
      socket.send(bytes);
    }

    function sendCommand(text) {
      const asciiBytes = [];
      for (let i = 0; i < text.length; i++) {
        const code = text.charCodeAt(i);
        if (code >= 32 && code < 127) asciiBytes.push(code);
      }
      if (asciiBytes.length === 0) return;
      const packet = new Uint8Array(asciiBytes.length + 3);
      packet[0] = 0x81;
      writeU16(packet, 1, asciiBytes.length);
      packet.set(asciiBytes, 3);
      sendPacket(packet);
    }

    function clickMap(mapX, mapY) {
      const ml = mapLayer();
      const layerId = ml ? ml.id : 0;
      const move = new Uint8Array(6);
      move[0] = 0x82;
      writeI16(move, 1, mapX);
      writeI16(move, 3, mapY);
      move[5] = layerId & 255;
      const down = new Uint8Array(9);
      down[0] = 0x82;
      writeI16(down, 1, mapX);
      writeI16(down, 3, mapY);
      down[5] = layerId & 255;
      down[6] = 0x83;
      down[7] = 0x01;
      down[8] = 1;
      sendPacket(down);
      const up = new Uint8Array(9);
      up[0] = 0x82;
      writeI16(up, 1, mapX);
      writeI16(up, 3, mapY);
      up[5] = layerId & 255;
      up[6] = 0x83;
      up[7] = 0x01;
      up[8] = 0;
      sendPacket(up);
    }

    function getTransform() {
      return {
        scale,
        offsetX,
        offsetY,
        nativeW,
        nativeH
      };
    }

    function setViewportFit() {
      updateNativeSize();
      computeFit();
      scheduleDraw();
    }

    function start() {
      updateNativeSize();
      computeFit();
      if (websocketEnabled) connect();
      else onStatus('open');
      scheduleDraw();
    }

    function ingest(bytes) {
      parse(bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes));
      if (onFrame) onFrame();
    }

    function stop() {
      stopped = true;
      if (socket) {
        socket.close();
        socket = null;
      }
      if (rafHandle) {
        cancelAnimationFrame(rafHandle);
        rafHandle = null;
      }
      if (paceRaf) {
        cancelAnimationFrame(paceRaf);
        paceRaf = null;
      }
      if (paceTimer) {
        clearTimeout(paceTimer);
        paceTimer = null;
      }
    }

    function getPaceStats() {
      return {
        enabled: paceEnabled,
        queued: paceBinaryCount,
        presented: pacePresented,
        interval: paceInterval,
        primed: pacePrimed
      };
    }

    return {
      start,
      ingest,
      sendCommand,
      sendInputMask,
      setCamera,
      cameraActive,
      clickMap,
      getTransform,
      setViewportFit,
      getPaceStats,
      stop
    };
  }

  window.BroadcastCore = { create: BroadcastCore };
})();
