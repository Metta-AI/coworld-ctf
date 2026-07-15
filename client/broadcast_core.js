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
        layer.image.data.fill(0);
        for (const obj of ordered) {
          const sprite = sprites.get(obj.spriteId);
          if (!sprite) continue;
          const startX = Math.max(0, -obj.x);
          const startY = Math.max(0, -obj.y);
          const endX = Math.min(sprite.width, layer.width - obj.x);
          const endY = Math.min(sprite.height, layer.height - obj.y);
          if (startX >= endX || startY >= endY) continue;
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
        layer.ctx.putImageData(layer.image, 0, 0);
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
        if (scale < 1) {
          ctx.imageSmoothingEnabled = true;
          ctx.imageSmoothingQuality = 'high';
        } else {
          ctx.imageSmoothingEnabled = false;
        }
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
          sprites.set(id, { width, height, pixels, label });
          changed = true;
        } else if (type === 0x02) {
          const id = readU16(bytes, offset);
          const x = readI16(bytes, offset + 2);
          const y = readI16(bytes, offset + 4);
          const z = readI16(bytes, offset + 6);
          const layer = bytes[offset + 8];
          const spriteId = readU16(bytes, offset + 9);
          objects.set(id, { id, x, y, z, layer, spriteId });
          offset += 11;
          changed = true;
        } else if (type === 0x03) {
          objects.delete(readU16(bytes, offset));
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
      if (changed) {
        dirty = true;
        scheduleDraw();
        if (!firstFrameFired && objects.size > 0) {
          firstFrameFired = true;
          onFirstFrame();
        }
      }
    }

    function connect() {
      if (stopped) return;
      const ws = new WebSocket(websocketAddress(window.location.href));
      socket = ws;
      ws.binaryType = 'arraybuffer';
      onStatus('connecting');

      ws.onmessage = event => {
        if (socket !== ws) return;
        if (typeof event.data === 'string') {
          onText(event.data);
        } else {
          const bytes = new Uint8Array(event.data);
          parse(bytes);
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
    }

    return {
      start,
      sendCommand,
      clickMap,
      getTransform,
      setViewportFit,
      stop
    };
  }

  window.BroadcastCore = { create: BroadcastCore };
})();
