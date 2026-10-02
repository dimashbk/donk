import Foundation

enum WebCaptureScript {
    static let handlerName = "__donkNetCapture"
    static let globalName = "__donkNet"
    static let bodyLimit = 256 * 1024

    static let source: String = template
        .replacingOccurrences(of: "__HANDLER__", with: handlerName)
        .replacingOccurrences(of: "__GLOBAL__", with: globalName)
        .replacingOccurrences(of: "__CAP__", with: String(bodyLimit))

    static func setEnabledScript(_ enabled: Bool) -> String {
        "(function(){try{var a=window.\(globalName);if(a){a.setEnabled(\(enabled ? "true" : "false"));}}catch(e){}})();void 0;"
    }

    // MARK: - Source

    private static let template = #"""
    (function () {
      'use strict';
      var KEY = '__GLOBAL__';
      try { if (Object.prototype.hasOwnProperty.call(window, KEY)) { return; } } catch (e) { return; }
      var handler = null;
      try { handler = window.webkit.messageHandlers.__HANDLER__; } catch (e) { handler = null; }
      if (!handler || typeof handler.postMessage !== 'function') { return; }

      var CAP = __CAP__;
      var R = Reflect;
      var apply = R.apply;
      var construct = R.construct;
      var postMessage = handler.postMessage;
      var then = Promise.prototype.then;
      var addListener = EventTarget.prototype.addEventListener;
      var setT = window.setTimeout;
      var stringify = JSON.stringify;
      var perf = window.performance;
      var perfNow = perf && perf.now ? function () { return apply(perf.now, perf, []); } : function () { return Date.now(); };
      var T0 = Date.now();
      var P0 = perfNow();
      var token = Math.random().toString(36).slice(2, 10) + T0.toString(36);
      var seq = 0;
      var enabled = true;
      var open = new Map();
      var esURLs = new Set();
      var beaconURLs = new Map();
      var encoder = typeof TextEncoder === 'function' ? new TextEncoder() : null;

      var api = {};
      try {
        Object.defineProperty(api, 'setEnabled', { value: function (value) { enabled = !!value; } });
        Object.defineProperty(api, 'version', { value: 1 });
        Object.defineProperty(window, KEY, { value: Object.freeze(api), enumerable: false, configurable: false, writable: false });
      } catch (e) { return; }

      function now() { return T0 + (perfNow() - P0); }
      function epoch(relative) { return T0 - P0 + relative; }
      function nextId() { seq += 1; return token + '.' + seq; }
      function later(fn, ms) { try { apply(setT, window, [fn, ms]); } catch (e) {} }
      function listen(target, type, fn) { try { apply(addListener, target, [type, fn]); } catch (e) {} }
      function pageURL() { try { return String(location.href); } catch (e) { return ''; } }

      function post(msg) {
        if (!enabled) { return; }
        msg.pg = token;
        try { apply(postMessage, handler, [msg]); } catch (e) {}
      }

      function absolute(url) {
        try { return new URL(String(url), document.baseURI).href; } catch (e) { return String(url); }
      }

      function headerList(h) {
        var out = [];
        if (!h) { return out; }
        try {
          if (typeof Headers === 'function' && h instanceof Headers) {
            h.forEach(function (value, name) { out.push([String(name), String(value)]); });
            return out;
          }
          if (Array.isArray(h)) {
            for (var i = 0; i < h.length; i++) {
              var pair = h[i];
              if (pair && pair.length >= 2) { out.push([String(pair[0]), String(pair[1])]); }
            }
            return out;
          }
          if (typeof h === 'object') {
            Object.keys(h).forEach(function (name) { out.push([name, String(h[name])]); });
          }
        } catch (e) {}
        return out;
      }

      function mergeHeaders(base, extra) {
        if (!extra.length) { return base; }
        var names = {};
        extra.forEach(function (pair) { names[pair[0].toLowerCase()] = true; });
        return base.filter(function (pair) { return !names[pair[0].toLowerCase()]; }).concat(extra);
      }

      function findHeader(list, name) {
        var key = name.toLowerCase();
        for (var i = 0; i < list.length; i++) {
          if (list[i][0].toLowerCase() === key) { return list[i][1]; }
        }
        return null;
      }

      function parseRawHeaders(raw) {
        var out = [];
        if (!raw) { return out; }
        String(raw).split(/\r?\n/).forEach(function (line) {
          var index = line.indexOf(':');
          if (index > 0) { out.push([line.slice(0, index).trim(), line.slice(index + 1).trim()]); }
        });
        return out;
      }

      function isBinaryType(ct) {
        if (!ct) { return false; }
        return /^(image|audio|video|font)\//i.test(ct) || /(octet-stream|pdf|zip|gzip|protobuf|grpc|wasm|msgpack|x-tar)/i.test(ct);
      }

      function base64(bytes) {
        var parts = [];
        for (var i = 0; i < bytes.length; i += 0x8000) {
          parts.push(String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000)));
        }
        return btoa(parts.join(''));
      }

      function decodeUTF8(bytes, fatal) {
        if (typeof TextDecoder !== 'function') { throw new Error('no decoder'); }
        return new TextDecoder('utf-8', { fatal: !!fatal }).decode(bytes);
      }

      function textBody(text, ct) {
        var s = String(text);
        var body = {};
        if (s.length > CAP) {
          body.x = s.slice(0, CAP);
          body.tr = true;
          body.s = s.length;
        } else {
          body.x = s;
        }
        if (ct) { body.ct = String(ct); }
        return body;
      }

      function bytesBody(bytes, ct, total) {
        var size = typeof total === 'number' ? total : bytes.byteLength;
        var slice = bytes.byteLength > CAP ? bytes.subarray(0, CAP) : bytes;
        var body = {};
        var text = null;
        if (!isBinaryType(ct)) {
          var trims = slice.byteLength < size ? 3 : 0;
          for (var drop = 0; drop <= trims && text === null; drop++) {
            try { text = decodeUTF8(drop ? slice.subarray(0, slice.byteLength - drop) : slice, true); } catch (e) { text = null; }
          }
        }
        if (text !== null) { body.x = text; } else { body.b64 = base64(slice); }
        if (ct) { body.ct = String(ct); }
        body.s = size;
        if (size > slice.byteLength) { body.tr = true; }
        return body;
      }

      function noteBody(note, size, ct) {
        var body = { n: note };
        if (typeof size === 'number') { body.s = size; }
        if (ct) { body.ct = String(ct); }
        return body;
      }

      function concat(chunks, length) {
        var out = new Uint8Array(length);
        var offset = 0;
        for (var i = 0; i < chunks.length; i++) { out.set(chunks[i], offset); offset += chunks[i].byteLength; }
        return out;
      }

      function readBlob(blob, ct, done) {
        try {
          var part = blob.size > CAP ? blob.slice(0, CAP) : blob;
          apply(then, part.arrayBuffer(), [function (buffer) {
            try { done(bytesBody(new Uint8Array(buffer), ct || blob.type || null, blob.size)); } catch (e) { done(null); }
          }, function () { done(null); }]);
        } catch (e) { done(null); }
      }

      function serializeBody(body, id) {
        if (body === null || body === undefined) { return null; }
        try {
          if (typeof body === 'string') { return textBody(body, 'text/plain;charset=UTF-8'); }
          if (typeof URLSearchParams === 'function' && body instanceof URLSearchParams) {
            return textBody(body.toString(), 'application/x-www-form-urlencoded;charset=UTF-8');
          }
          if (typeof FormData === 'function' && body instanceof FormData) {
            var lines = [];
            body.forEach(function (value, name) {
              if (typeof value === 'string') { lines.push(name + '=' + value); }
              else { lines.push(name + '=<file ' + (value.name || 'blob') + ', ' + (value.type || 'application/octet-stream') + ', ' + value.size + ' bytes>'); }
            });
            return textBody(lines.join('\n'), 'multipart/form-data');
          }
          if (typeof Blob === 'function' && body instanceof Blob) {
            var type = body.type || null;
            if (id) {
              readBlob(body, type, function (read) { if (read) { post({ k: 'patch', id: id, rb: read }); } });
            }
            return noteBody('[Blob ' + (type || 'application/octet-stream') + ', ' + body.size + ' bytes]', body.size, type);
          }
          if (body instanceof ArrayBuffer) { return bytesBody(new Uint8Array(body), null); }
          if (ArrayBuffer.isView(body)) { return bytesBody(new Uint8Array(body.buffer, body.byteOffset, body.byteLength), null); }
          if (typeof ReadableStream === 'function' && body instanceof ReadableStream) { return noteBody('[ReadableStream body]', null, null); }
          if (typeof Document === 'function' && body instanceof Document) {
            return textBody(new XMLSerializer().serializeToString(body), 'application/xml');
          }
          return textBody(String(body), 'text/plain;charset=UTF-8');
        } catch (e) {
          return noteBody('[unreadable body]', null, null);
        }
      }

      function dataSize(data) {
        try {
          if (typeof data === 'string') { return encoder && data.length < 65536 ? encoder.encode(data).length : data.length; }
          if (data instanceof ArrayBuffer) { return data.byteLength; }
          if (ArrayBuffer.isView(data)) { return data.byteLength; }
          if (typeof Blob === 'function' && data instanceof Blob) { return data.size; }
        } catch (e) {}
        return 0;
      }

      function readStream(response, ct, length, done) {
        var stream = null;
        try { stream = response.body; } catch (e) { stream = null; }
        if (!stream || typeof stream.getReader !== 'function') {
          if (typeof length === 'number' && length > CAP) { done(noteBody('[body not captured]', length, ct)); return; }
          try {
            apply(then, response.arrayBuffer(), [function (buffer) {
              try { done(bytesBody(new Uint8Array(buffer), ct)); } catch (e) { done(null); }
            }, function () { done(null); }]);
          } catch (e) { done(null); }
          return;
        }
        var reader = stream.getReader();
        var chunks = [];
        var got = 0;
        var total = 0;
        var finished = false;
        function finish(truncated) {
          if (finished) { return; }
          finished = true;
          try {
            var size = truncated ? Math.max(total, typeof length === 'number' ? length : 0) : total;
            var body = bytesBody(concat(chunks, got), ct, size);
            if (truncated) { body.tr = true; }
            done(body);
          } catch (e) { done(null); }
        }
        function pump() {
          try {
            apply(then, reader.read(), [function (result) {
              if (result.done) { finish(false); return; }
              var value = result.value;
              if (!value || typeof value.byteLength !== 'number') { pump(); return; }
              total += value.byteLength;
              if (got < CAP) {
                var take = Math.min(value.byteLength, CAP - got);
                chunks.push(take === value.byteLength ? value : value.subarray(0, take));
                got += take;
              }
              if (total > CAP) {
                try { reader.cancel(); } catch (e) {}
                finish(true);
                return;
              }
              pump();
            }, function () { finish(total > got); }]);
          } catch (e) { finish(total > got); }
        }
        pump();
      }

      function errorCode(error, fallback) {
        var name = error && error.name ? String(error.name) : '';
        if (name === 'AbortError') { return 'abort'; }
        if (name === 'TimeoutError') { return 'timeout'; }
        return fallback || 'network';
      }

      function errorMessage(error) {
        try { return String((error && error.message) || error || 'Request failed'); } catch (e) { return 'Request failed'; }
      }

      var nativeFetch = window.fetch;
      var nativeClone = typeof Response === 'function' ? Response.prototype.clone : null;

      function fetchStart(input, init) {
        var url;
        var method = 'GET';
        var headers = [];
        var request = null;
        if (typeof Request === 'function' && input instanceof Request) {
          request = input;
          url = input.url;
          method = input.method || 'GET';
          headers = headerList(input.headers);
        } else {
          url = String(input);
        }
        if (init && typeof init === 'object') {
          if (init.method) { method = String(init.method).toUpperCase(); }
          if (init.headers) { headers = mergeHeaders(headers, headerList(init.headers)); }
        }
        var id = nextId();
        var msg = { k: 'start', id: id, i: 'fetch', m: method, u: absolute(url), h: headers, t: now(), p: pageURL() };
        if (init && typeof init === 'object' && init.body !== undefined && init.body !== null) {
          msg.b = serializeBody(init.body, id);
        } else if (request && method !== 'GET' && method !== 'HEAD') {
          try {
            var copy = request.clone();
            var ct = findHeader(headers, 'content-type');
            apply(then, copy.blob(), [function (blob) {
              if (!blob || !blob.size) { return; }
              readBlob(blob, ct, function (read) { if (read) { post({ k: 'patch', id: id, rb: read }); } });
            }, function () {}]);
          } catch (e) {}
        }
        open.set(id, 'fetch');
        post(msg);
        return { id: id, method: method };
      }

      function fetchFinish(record, end) {
        end.t = now();
        open.delete(record.id);
        post(end);
      }

      function fetchResponse(record, response) {
        var headers = headerList(response.headers);
        var ct = findHeader(headers, 'content-type');
        var lengthHeader = findHeader(headers, 'content-length');
        var length = lengthHeader !== null && lengthHeader !== '' ? parseInt(lengthHeader, 10) : null;
        if (typeof length === 'number' && isNaN(length)) { length = null; }
        post({ k: 'head', id: record.id, st: response.status, h: headers, ty: response.type, ru: response.url, t: now() });
        var end = { k: 'end', id: record.id };
        if (response.type === 'opaque' || response.type === 'opaqueredirect') { end.lvl = 'metadata'; fetchFinish(record, end); return; }
        if (ct && /text\/event-stream/i.test(ct)) { end.b = noteBody('[event stream: body not captured]', null, null); end.stream = true; fetchFinish(record, end); return; }
        var hasBody = true;
        try { hasBody = response.body !== null; } catch (e) { hasBody = true; }
        if (record.method === 'HEAD' || response.status === 204 || response.status === 304 || !hasBody || !nativeClone) { fetchFinish(record, end); return; }
        var copy;
        try { copy = apply(nativeClone, response, []); } catch (e) { fetchFinish(record, end); return; }
        readStream(copy, ct, length, function (body) {
          if (body) { end.b = body; }
          fetchFinish(record, end);
        });
      }

      function fetchError(record, error) {
        open.delete(record.id);
        post({ k: 'fail', id: record.id, t: now(), c: errorCode(error), e: errorMessage(error), en: error && error.name ? String(error.name) : 'TypeError' });
      }

      if (typeof nativeFetch === 'function') {
        try {
          window.fetch = new Proxy(nativeFetch, {
            apply: function (target, thisArg, args) {
              var record = null;
              if (enabled) {
                try { record = fetchStart(args[0], args[1]); } catch (e) { record = null; }
              }
              var promise;
              try { promise = apply(target, thisArg, args); }
              catch (error) { if (record) { try { fetchError(record, error); } catch (e) {} } throw error; }
              if (!record) { return promise; }
              try {
                return apply(then, promise, [function (response) {
                  try { fetchResponse(record, response); } catch (e) {}
                  return response;
                }, function (error) {
                  try { fetchError(record, error); } catch (e) {}
                  throw error;
                }]);
              } catch (e) {
                return promise;
              }
            }
          });
        } catch (e) {}
      }

      var XHR = window.XMLHttpRequest;
      if (typeof XHR === 'function' && XHR.prototype) {
        var xp = XHR.prototype;
        var xhrRecords = new WeakMap();
        var xhrHooked = new WeakSet();
        var nativeOpen = xp.open;
        var nativeSend = xp.send;
        var nativeSetHeader = xp.setRequestHeader;
        var nativeAllHeaders = xp.getAllResponseHeaders;

        var xhrFail = function (record, code, message) {
          if (record.done) { return; }
          record.done = true;
          open.delete(record.id);
          post({ k: 'fail', id: record.id, t: now(), c: code, e: message });
        };

        var xhrFinish = function (xhr, record) {
          if (record.done) { return; }
          var status = 0;
          try { status = xhr.status; } catch (e) { status = 0; }
          if (record.err || status === 0) {
            var code = record.err || 'network';
            xhrFail(record, code, code === 'abort' ? 'Request aborted' : code === 'timeout' ? 'Request timed out' : 'Network request failed');
            return;
          }
          record.done = true;
          open.delete(record.id);
          var headers = [];
          try { headers = parseRawHeaders(apply(nativeAllHeaders, xhr, [])); } catch (e) { headers = []; }
          var end = { k: 'end', id: record.id, st: status, h: headers, ru: xhr.responseURL || null, rt: record.rt || null };
          var ct = findHeader(headers, 'content-type');
          var type = '';
          try { type = xhr.responseType; } catch (e) { type = ''; }
          try {
            if (type === '' || type === 'text') {
              end.b = textBody(xhr.responseText, ct);
            } else if (type === 'json') {
              end.b = textBody(xhr.response === null ? 'null' : apply(stringify, JSON, [xhr.response]), ct || 'application/json');
            } else if (type === 'arraybuffer') {
              if (xhr.response) { end.b = bytesBody(new Uint8Array(xhr.response), ct); }
            } else if (type === 'blob') {
              if (xhr.response) {
                readBlob(xhr.response, ct, function (body) {
                  if (body) { end.b = body; }
                  end.t = now();
                  post(end);
                });
                return;
              }
            } else if (type === 'document') {
              if (xhr.responseXML) { end.b = textBody(new XMLSerializer().serializeToString(xhr.responseXML), ct); }
            }
          } catch (e) {}
          end.t = now();
          post(end);
        };

        var hookXHR = function (xhr) {
          if (xhrHooked.has(xhr)) { return; }
          xhrHooked.add(xhr);
          listen(xhr, 'readystatechange', function () {
            var record = xhrRecords.get(xhr);
            try { if (record && record.id && !record.rt && xhr.readyState >= 2) { record.rt = now(); } } catch (e) {}
          });
          listen(xhr, 'error', function () { var record = xhrRecords.get(xhr); if (record) { record.err = 'network'; } });
          listen(xhr, 'abort', function () { var record = xhrRecords.get(xhr); if (record) { record.err = 'abort'; } });
          listen(xhr, 'timeout', function () { var record = xhrRecords.get(xhr); if (record) { record.err = 'timeout'; } });
          listen(xhr, 'loadend', function () {
            var record = xhrRecords.get(xhr);
            if (record && record.id && !record.done) { try { xhrFinish(xhr, record); } catch (e) {} }
          });
        };

        try {
          xp.open = new Proxy(nativeOpen, {
            apply: function (target, xhr, args) {
              var result = apply(target, xhr, args);
              try {
                var previous = xhrRecords.get(xhr);
                if (previous && previous.id && !previous.done) { xhrFail(previous, 'abort', 'Request aborted by open()'); }
                xhrRecords.set(xhr, {
                  m: String(args[0] || 'GET').toUpperCase(),
                  u: absolute(args[1]),
                  async: args.length < 3 ? true : !!args[2],
                  h: []
                });
              } catch (e) {}
              return result;
            }
          });
          xp.setRequestHeader = new Proxy(nativeSetHeader, {
            apply: function (target, xhr, args) {
              var result = apply(target, xhr, args);
              try {
                var record = xhrRecords.get(xhr);
                if (record && !record.id) { record.h.push([String(args[0]), String(args[1])]); }
              } catch (e) {}
              return result;
            }
          });
          xp.send = new Proxy(nativeSend, {
            apply: function (target, xhr, args) {
              var record = null;
              if (enabled) {
                try {
                  record = xhrRecords.get(xhr) || null;
                  if (record && record.id) { record = null; }
                  if (record) {
                    record.id = nextId();
                    record.done = false;
                    record.err = null;
                    var msg = { k: 'start', id: record.id, i: 'xhr', m: record.m, u: record.u, h: record.h.slice(), t: now(), p: pageURL() };
                    var body = args[0];
                    if (body !== undefined && body !== null && record.m !== 'GET' && record.m !== 'HEAD') { msg.b = serializeBody(body, record.id); }
                    hookXHR(xhr);
                    open.set(record.id, 'xhr');
                    post(msg);
                  }
                } catch (e) { record = null; }
              }
              try {
                return apply(target, xhr, args);
              } catch (error) {
                if (record && !record.done) { xhrFail(record, errorCode(error), errorMessage(error)); }
                throw error;
              } finally {
                if (record && !record.async && !record.done) { try { xhrFinish(xhr, record); } catch (e) {} }
              }
            }
          });
        } catch (e) {}
      }

      var NavigatorProto = typeof Navigator === 'function' ? Navigator.prototype : null;
      if (NavigatorProto && typeof NavigatorProto.sendBeacon === 'function') {
        try {
          NavigatorProto.sendBeacon = new Proxy(NavigatorProto.sendBeacon, {
            apply: function (target, thisArg, args) {
              var started = now();
              var queued = apply(target, thisArg, args);
              if (enabled) {
                try {
                  var id = nextId();
                  var msg = { k: 'start', id: id, i: 'beacon', m: 'POST', u: absolute(args[0]), h: [], t: started, p: pageURL() };
                  if (args.length > 1 && args[1] !== undefined && args[1] !== null) {
                    msg.b = serializeBody(args[1], id);
                    if (msg.b && msg.b.ct) { msg.h = [['Content-Type', msg.b.ct]]; }
                  }
                  post(msg);
                  if (queued) { beaconURLs.set(msg.u, (beaconURLs.get(msg.u) || 0) + 1); }
                  if (queued) { post({ k: 'end', id: id, t: now(), beacon: true }); }
                  else { post({ k: 'fail', id: id, t: now(), c: 'refused', e: 'Beacon was not queued' }); }
                } catch (e) {}
              }
              return queued;
            }
          });
        } catch (e) {}
      }

      var NativeWebSocket = window.WebSocket;
      if (typeof NativeWebSocket === 'function') {
        var sockets = new WeakMap();
        var flushSocket = function (record) {
          post({ k: 'ws', id: record.id, ev: 'count', tx: record.tx, txb: record.txb, rx: record.rx, rxb: record.rxb });
        };
        var scheduleSocket = function (record) {
          if (record.timer || record.closed) { return; }
          record.timer = 1;
          later(function () { record.timer = 0; if (!record.closed) { flushSocket(record); } }, 1000);
        };
        var trackSocket = function (socket, args) {
          var id = nextId();
          var record = { id: id, tx: 0, txb: 0, rx: 0, rxb: 0, timer: 0, closed: false, err: false };
          sockets.set(socket, record);
          var url = String(socket.url);
          var headers = [];
          var protocols = args[1];
          if (protocols !== undefined && protocols !== null) {
            headers.push(['Sec-WebSocket-Protocol', Array.isArray(protocols) ? protocols.join(', ') : String(protocols)]);
          }
          open.set(id, 'websocket');
          post({ k: 'start', id: id, i: 'websocket', m: /^wss:/i.test(url) ? 'WSS' : 'WS', u: url, h: headers, t: now(), p: pageURL() });
          listen(socket, 'open', function () {
            post({ k: 'ws', id: id, ev: 'open', t: now(), pr: socket.protocol || '', ex: socket.extensions || '' });
          });
          listen(socket, 'message', function (event) { record.rx += 1; record.rxb += dataSize(event.data); scheduleSocket(record); });
          listen(socket, 'error', function () { record.err = true; });
          listen(socket, 'close', function (event) {
            if (record.closed) { return; }
            record.closed = true;
            open.delete(id);
            post({ k: 'ws', id: id, ev: 'close', t: now(), code: event.code, reason: event.reason || '', clean: !!event.wasClean, err: record.err,
                   tx: record.tx, txb: record.txb, rx: record.rx, rxb: record.rxb });
          });
        };
        try {
          window.WebSocket = new Proxy(NativeWebSocket, {
            construct: function (target, args, newTarget) {
              var socket = construct(target, args, newTarget);
              if (enabled) { try { trackSocket(socket, args); } catch (e) {} }
              return socket;
            }
          });
          var nativeSocketSend = NativeWebSocket.prototype.send;
          NativeWebSocket.prototype.send = new Proxy(nativeSocketSend, {
            apply: function (target, socket, args) {
              var result = apply(target, socket, args);
              try {
                var record = sockets.get(socket);
                if (record) { record.tx += 1; record.txb += dataSize(args[0]); scheduleSocket(record); }
              } catch (e) {}
              return result;
            }
          });
        } catch (e) {}
      }

      var NativeEventSource = window.EventSource;
      if (typeof NativeEventSource === 'function') {
        var sources = new WeakMap();
        var scheduleSource = function (record) {
          if (record.timer || record.closed) { return; }
          record.timer = 1;
          later(function () {
            record.timer = 0;
            if (!record.closed) { post({ k: 'es', id: record.id, ev: 'count', rx: record.rx, rxb: record.rxb, re: record.re }); }
          }, 1000);
        };
        var trackSource = function (source) {
          var id = nextId();
          var record = { id: id, rx: 0, rxb: 0, re: 0, timer: 0, closed: false, opened: false };
          sources.set(source, record);
          var url = String(source.url);
          esURLs.add(url);
          open.set(id, 'eventSource');
          post({ k: 'start', id: id, i: 'eventSource', m: 'GET', u: url, h: [['Accept', 'text/event-stream']], t: now(), p: pageURL() });
          listen(source, 'open', function () {
            if (record.opened) { record.re += 1; }
            record.opened = true;
            post({ k: 'es', id: id, ev: 'open', t: now(), re: record.re });
          });
          listen(source, 'message', function (event) { record.rx += 1; record.rxb += dataSize(event.data); scheduleSource(record); });
          listen(source, 'error', function () {
            if (record.closed) { return; }
            var closed = false;
            try { closed = source.readyState === 2; } catch (e) { closed = false; }
            if (closed) { record.closed = true; open.delete(id); }
            post({ k: 'es', id: id, ev: 'error', fatal: closed, opened: record.opened, t: now(), rx: record.rx, rxb: record.rxb, re: record.re });
          });
        };
        try {
          window.EventSource = new Proxy(NativeEventSource, {
            construct: function (target, args, newTarget) {
              var source = construct(target, args, newTarget);
              if (enabled) { try { trackSource(source); } catch (e) {} }
              return source;
            }
          });
          var nativeSourceClose = NativeEventSource.prototype.close;
          NativeEventSource.prototype.close = new Proxy(nativeSourceClose, {
            apply: function (target, source, args) {
              var result = apply(target, source, args);
              try {
                var record = sources.get(source);
                if (record && !record.closed) {
                  record.closed = true;
                  open.delete(record.id);
                  post({ k: 'es', id: record.id, ev: 'close', t: now(), rx: record.rx, rxb: record.rxb, re: record.re });
                }
              } catch (e) {}
              return result;
            }
          });
        } catch (e) {}
      }

      var SKIPPED = { fetch: true, xmlhttprequest: true, beacon: true, navigation: true };

      function timingFields(entry, out) {
        var names = ['fetchStart', 'domainLookupStart', 'domainLookupEnd', 'connectStart', 'connectEnd', 'secureConnectionStart', 'requestStart', 'responseStart', 'responseEnd'];
        var timing = {};
        for (var i = 0; i < names.length; i++) {
          var value = entry[names[i]];
          if (typeof value === 'number' && value > 0) { timing[names[i]] = epoch(value); }
        }
        out.tm = timing;
        if (typeof entry.transferSize === 'number') { out.ts = entry.transferSize; }
        if (typeof entry.encodedBodySize === 'number') { out.es = entry.encodedBodySize; }
        if (typeof entry.decodedBodySize === 'number') { out.ds = entry.decodedBodySize; }
        if (entry.nextHopProtocol) { out.np = String(entry.nextHopProtocol); }
        if (typeof entry.responseStatus === 'number' && entry.responseStatus > 0) { out.st = entry.responseStatus; }
        return out;
      }

      function resourceInfo(entry) {
        var end = entry.responseEnd > 0 ? entry.responseEnd : entry.startTime + entry.duration;
        return timingFields(entry, { u: entry.name, it: entry.initiatorType || 'other', t0: epoch(entry.startTime), t1: epoch(end) });
      }

      try {
        if (typeof PerformanceObserver === 'function') {
          var observer = new PerformanceObserver(function (list) {
            if (!enabled) { return; }
            try {
              var out = [];
              list.getEntries().forEach(function (entry) {
                var name = String(entry.name);
                if (SKIPPED[entry.initiatorType] || !/^https?:/i.test(name) || esURLs.has(name)) { return; }
                var beacons = beaconURLs.get(name);
                if (beacons) {
                  if (beacons > 1) { beaconURLs.set(name, beacons - 1); } else { beaconURLs.delete(name); }
                  return;
                }
                out.push(resourceInfo(entry));
              });
              if (out.length) { post({ k: 'res', list: out, p: pageURL() }); }
            } catch (e) {}
          });
          try { observer.observe({ type: 'resource', buffered: true }); }
          catch (e) { observer.observe({ entryTypes: ['resource'] }); }
        }
      } catch (e) {}

      var navigationSent = false;
      function sendNavigation(partial) {
        if (navigationSent || !enabled) { return; }
        navigationSent = true;
        try {
          var href = pageURL();
          if (!/^(https?|file):/i.test(href)) { return; }
          var entry = null;
          try { entry = perf && perf.getEntriesByType ? perf.getEntriesByType('navigation')[0] : null; } catch (e) { entry = null; }
          var msg = { k: 'nav', u: entry && entry.name ? String(entry.name) : href, t0: epoch(0), p: href, partial: !!partial };
          if (entry) {
            timingFields(entry, msg);
            if (entry.type) { msg.typ = String(entry.type); }
            if (entry.loadEventEnd > 0) { msg.load = epoch(entry.loadEventEnd); }
            if (entry.domContentLoadedEventEnd > 0) { msg.dcl = epoch(entry.domContentLoadedEventEnd); }
          }
          post(msg);
        } catch (e) {}
      }

      function flushOpen() {
        if (!open.size) { return; }
        var ids = [];
        open.forEach(function (initiator, id) { ids.push(id); });
        open.clear();
        post({ k: 'gone', ids: ids, t: now() });
      }

      listen(window, 'load', function () { later(function () { sendNavigation(false); }, 0); });
      listen(window, 'pagehide', function () { sendNavigation(true); flushOpen(); });
    })();
    """#
}
