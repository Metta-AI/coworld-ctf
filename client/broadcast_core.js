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
        ctx,
        image: null
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
    layer.image = layer.ctx.createImageData(width, height);
    if (onResize) onResize();
  }

  function putSpritePixel(layer, x, y, sprite, srcOffset) {
    if (x < 0 || y < 0 || x >= layer.width || y >= layer.height) return;
    const srcA = sprite.pixels[srcOffset + 3];
    if (srcA === 0) return;
    const offset = (y * layer.width + x) * 4;
    if (srcA === 255 || layer.image.data[offset + 3] === 0) {
      layer.image.data[offset] = sprite.pixels[srcOffset];
      layer.image.data[offset + 1] = sprite.pixels[srcOffset + 1];
      layer.image.data[offset + 2] = sprite.pixels[srcOffset + 2];
      layer.image.data[offset + 3] = srcA;
      return;
    }
    const dstA = layer.image.data[offset + 3];
    const srcAlpha = srcA / 255, dstAlpha = dstA / 255;
    const outAlpha = srcAlpha + dstAlpha * (1 - srcAlpha);
    const dstWeight = dstAlpha * (1 - srcAlpha);
    layer.image.data[offset] = Math.round(
      (sprite.pixels[srcOffset] * srcAlpha +
        layer.image.data[offset] * dstWeight) / outAlpha
    );
    layer.image.data[offset + 1] = Math.round(
      (sprite.pixels[srcOffset + 1] * srcAlpha +
        layer.image.data[offset + 1] * dstWeight) / outAlpha
    );
    layer.image.data[offset + 2] = Math.round(
      (sprite.pixels[srcOffset + 2] * srcAlpha +
        layer.image.data[offset + 2] * dstWeight) / outAlpha
    );
    layer.image.data[offset + 3] = Math.round(outAlpha * 255);
  }

  function websocketPathForClientPage(path) {
    const mappings = [
      ['/client/global', '/global'],
      ['/client/replay', '/replay'],
      ['/client/player', '/player'],
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
    const PACE_TARGET_DEPTH = config.paceTargetDepth || 12;
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
      scale = Math.min(scaleX, scaleY);
      const drawW = nativeW * scale;
      const drawH = nativeH * scale;
      offsetX = (cssW - drawW) / 2;
      offsetY = (cssH - drawH) / 2;
    }

    // Static map-band cache. The full-board map bands (object ids 40..67 on
    // layer 0, z pinned at -32768 so they underlie everything) are emitted
    // once at init and never change, yet re-blitting them dominates composite
    // cost at full board size. Bake them into a per-layer base buffer and
    // start each composite from a copy of that base, re-blitting only the
    // dynamic objects above them (the endzone fade overlay at z = -32767 DOES
    // change every frame and must stay dynamic).
    const STATIC_BAND_MIN_ID = 40;
    const STATIC_BAND_MAX_ID = 67;
    const STATIC_BAND_Z = -32768;
    let staticBandsDirty = true;

    function isStaticBand(obj) {
      return obj.layer === 0 &&
        obj.id >= STATIC_BAND_MIN_ID && obj.id <= STATIC_BAND_MAX_ID &&
        obj.z === STATIC_BAND_Z;
    }

    function blitObject(layer, obj) {
      const sprite = sprites.get(obj.spriteId);
      if (!sprite) return;
      const startX = Math.max(0, -obj.x);
      const startY = Math.max(0, -obj.y);
      const endX = Math.min(sprite.width, layer.width - obj.x);
      const endY = Math.min(sprite.height, layer.height - obj.y);
      if (startX >= endX || startY >= endY) return;
      for (let y = startY; y < endY; y++) {
        for (let x = startX; x < endX; x++) {
          putSpritePixel(
            layer,
            obj.x + x,
            obj.y + y,
            sprite,
            (y * sprite.width + x) * 4
          );
        }
      }
    }

    function composite() {
      const orderedLayers = [...layers.values()]
        .filter(layer => (layer.flags & ZoomableFlag) !== 0 || layer.type === MapLayerType)
        .sort((a, b) => a.id - b.id);

      offscreenCtx.clearRect(0, 0, nativeW, nativeH);

      for (const layer of orderedLayers) {
        if (!layer.image) continue;
        const ordered = [...objects.values()]
          .filter(obj => obj.layer === layer.id)
          .sort((a, b) => a.z - b.z || a.y - b.y || a.id - b.id);
        if (ordered.length === 0) continue;
        // The cache is only sound if the static bands form the sorted prefix
        // and every dynamic object sorts strictly after them (i.e. nothing
        // dynamic shares z = -32768). Otherwise fall back to a full re-blit.
        let staticCount = 0;
        while (staticCount < ordered.length && isStaticBand(ordered[staticCount])) {
          staticCount++;
        }
        let cacheable = staticCount > 0;
        for (let i = staticCount; cacheable && i < ordered.length; i++) {
          if (ordered[i].z <= STATIC_BAND_Z) cacheable = false;
        }
        if (cacheable) {
          if (staticBandsDirty || !layer.staticBase ||
              layer.staticBase.length !== layer.image.data.length) {
            layer.image.data.fill(0);
            for (let i = 0; i < staticCount; i++) blitObject(layer, ordered[i]);
            layer.staticBase = layer.image.data.slice();
          } else {
            layer.image.data.set(layer.staticBase);
          }
          for (let i = staticCount; i < ordered.length; i++) {
            blitObject(layer, ordered[i]);
          }
        } else {
          layer.staticBase = null;
          layer.image.data.fill(0);
          for (const obj of ordered) blitObject(layer, obj);
        }
        layer.ctx.putImageData(layer.image, 0, 0);
        offscreenCtx.drawImage(layer.canvas, 0, 0);
      }
      staticBandsDirty = false;
      dirty = false;
    }

    function draw() {
      const dpr = window.devicePixelRatio || 1;
      const cssW = canvas.clientWidth || canvas.width / dpr;
      const cssH = canvas.clientHeight || canvas.height / dpr;
      if (canvas.width !== cssW * dpr) canvas.width = cssW * dpr;
      if (canvas.height !== cssH * dpr) canvas.height = cssH * dpr;

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
            sprites.set(id, { width, height, pixels, label });
            // Only a redefinition of a sprite some static band currently
            // references can change the baked base; other sprite traffic
            // (agents, fade stages, decals) must not thrash the cache.
            for (const obj of objects.values()) {
              if (isStaticBand(obj) && obj.spriteId === id) {
                staticBandsDirty = true;
                break;
              }
            }
          }
          changed = true;
        } else if (type === 0x02) {
          const id = readU16(bytes, offset);
          const x = readI16(bytes, offset + 2);
          const y = readI16(bytes, offset + 4);
          const z = readI16(bytes, offset + 6);
          const layer = bytes[offset + 8];
          const spriteId = readU16(bytes, offset + 9);
          objects.set(id, { id, x, y, z, layer, spriteId });
          if (id >= STATIC_BAND_MIN_ID && id <= STATIC_BAND_MAX_ID) {
            staticBandsDirty = true;
          }
          offset += 11;
          changed = true;
        } else if (type === 0x03) {
          const id = readU16(bytes, offset);
          objects.delete(id);
          if (id >= STATIC_BAND_MIN_ID && id <= STATIC_BAND_MAX_ID) {
            staticBandsDirty = true;
          }
          offset += 2;
          changed = true;
        } else if (type === 0x04) {
          objects.clear();
          staticBandsDirty = true;
          changed = true;
        } else if (type === 0x05) {
          setViewport(layers, bytes[offset], readU16(bytes, offset + 1), readU16(bytes, offset + 3), () => {
            updateNativeSize();
            computeFit();
          });
          staticBandsDirty = true;
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
      connect();
      scheduleDraw();
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
      sendCommand,
      clickMap,
      getTransform,
      setViewportFit,
      getPaceStats,
      stop
    };
  }

  window.BroadcastCore = { create: BroadcastCore };
})();
