import Foundation

enum WebPlaygroundPage {
    static let baseURL = URL(string: "https://donk.demo/")!

    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <title>donk WebView playground</title>
    <style>
      :root {
        color-scheme: light dark;
        --bg: #F2F2F7; --card: #FFFFFF; --fill: rgba(118,118,128,0.12); --text: #111114; --muted: #6B6B76;
        --accent: #6D5DFC; --ok: #16A34A; --warn: #D97706; --err: #DC2626; --info: #2563EB; --web: #0D9488;
      }
      @media (prefers-color-scheme: dark) {
        :root {
          --bg: #000000; --card: #1C1C1E; --fill: rgba(118,118,128,0.24); --text: #F5F5F7; --muted: #A1A1AA;
          --accent: #8B7FFF; --ok: #22C55E; --warn: #F59E0B; --err: #F87171; --info: #60A5FA; --web: #2DD4BF;
        }
      }
      * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
      body { margin: 0; padding: 16px 16px 32px; background: var(--bg); color: var(--text); font: -apple-system-body; font-family: -apple-system, system-ui; }
      header { display: flex; align-items: center; gap: 12px; margin-bottom: 14px; }
      .logo { width: 40px; height: 40px; border-radius: 12px; background: linear-gradient(135deg, var(--web), var(--accent)); display: grid; place-items: center; color: #fff; font-weight: 700; font-size: 18px; }
      h1 { font: 600 20px ui-rounded, -apple-system; margin: 0; }
      .sub { color: var(--muted); font-size: 13px; margin: 2px 0 0; }
      .section { font-size: 12px; font-weight: 600; letter-spacing: 0.04em; text-transform: uppercase; color: var(--muted); margin: 18px 4px 8px; }
      .grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; }
      button { appearance: none; border: 0; border-radius: 14px; padding: 12px; background: var(--card); color: var(--text); text-align: left; font: inherit; font-size: 15px; font-weight: 600; display: flex; flex-direction: column; gap: 2px; transition: transform .12s ease, opacity .12s ease; }
      button:active { transform: scale(0.97); opacity: 0.8; }
      button small { font-size: 11px; font-weight: 500; color: var(--muted); font-family: ui-monospace, Menlo; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      button .tag { font-size: 10px; font-weight: 700; font-family: ui-monospace, Menlo; color: var(--tone, var(--accent)); }
      .primary { grid-column: 1 / -1; background: var(--accent); color: #fff; align-items: center; font-size: 16px; }
      .primary small { color: rgba(255,255,255,0.8); }
      #media { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 8px; }
      #media img { width: calc(33.3% - 6px); aspect-ratio: 3 / 2; object-fit: cover; border-radius: 10px; background: var(--fill); }
      #media iframe { width: 100%; height: 160px; border: 0; border-radius: 12px; background: #fff; }
      ul { list-style: none; padding: 0; margin: 0; background: var(--card); border-radius: 14px; overflow: hidden; }
      li { display: flex; align-items: center; gap: 10px; padding: 10px 12px; border-top: 0.5px solid var(--fill); font-size: 13px; }
      li:first-child { border-top: 0; }
      li .dot { width: 8px; height: 8px; border-radius: 4px; background: var(--tone, var(--muted)); flex: none; }
      li .label { font-weight: 600; flex: none; }
      li .detail { color: var(--muted); font-family: ui-monospace, Menlo; font-size: 11px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      li.empty { color: var(--muted); justify-content: center; }
    </style>
    </head>
    <body>
    <header>
      <div class="logo">d</div>
      <div>
        <h1>WebView playground</h1>
        <p class="sub">Everything this page loads is captured by DonkWebView.</p>
      </div>
    </header>

    <div class="grid">
      <button class="primary" data-action="runAll">Run all<small>fire every scenario at once</small></button>
    </div>

    <div class="section">fetch</div>
    <div class="grid">
      <button data-action="fetchGet" style="--tone: var(--info)"><span class="tag">GET</span>JSON todo<small>jsonplaceholder.typicode.com</small></button>
      <button data-action="fetchPost" style="--tone: var(--ok)"><span class="tag">POST</span>JSON body<small>httpbin.org/post</small></button>
      <button data-action="notFound" style="--tone: var(--warn)"><span class="tag">GET</span>HTTP 404<small>httpbin.org/status/404</small></button>
      <button data-action="networkError" style="--tone: var(--err)"><span class="tag">GET</span>Network error<small>no-such-host.donk.invalid</small></button>
    </div>

    <div class="section">XMLHttpRequest &amp; beacon</div>
    <div class="grid">
      <button data-action="xhrGet" style="--tone: var(--info)"><span class="tag">GET</span>Custom headers<small>httpbin.org/get</small></button>
      <button data-action="xhrPost" style="--tone: var(--ok)"><span class="tag">POST</span>Form body<small>httpbin.org/post · json</small></button>
      <button data-action="beacon" style="--tone: var(--ok)"><span class="tag">BEACON</span>sendBeacon<small>Blob · text/plain</small></button>
      <button data-action="fetchBlob" style="--tone: var(--info)"><span class="tag">GET</span>Binary image<small>fetch · image/png</small></button>
    </div>

    <div class="section">streams &amp; resources</div>
    <div class="grid">
      <button data-action="websocket" style="--tone: var(--web)"><span class="tag">WSS</span>WebSocket echo<small>ws.postman-echo.com</small></button>
      <button data-action="eventSource" style="--tone: var(--web)"><span class="tag">SSE</span>EventSource<small>stream.wikimedia.org</small></button>
      <button data-action="images" style="--tone: var(--muted)"><span class="tag">IMG</span>Images<small>picsum.photos × 3</small></button>
      <button data-action="iframe" style="--tone: var(--muted)"><span class="tag">DOC</span>Iframe<small>example.com</small></button>
    </div>

    <div id="media"></div>

    <div class="section">page log</div>
    <ul id="log"><li class="empty">Tap a scenario to generate traffic</li></ul>

    <script>
      (function () {
        var logList = document.getElementById('log');
        var media = document.getElementById('media');
        var tones = { ok: 'var(--ok)', warn: 'var(--warn)', err: 'var(--err)', info: 'var(--info)' };
        function log(label, detail, tone) {
          var empty = logList.querySelector('.empty');
          if (empty) { empty.remove(); }
          var item = document.createElement('li');
          item.style.setProperty('--tone', tones[tone] || 'var(--muted)');
          item.innerHTML = '<span class="dot"></span><span class="label"></span><span class="detail"></span>';
          item.querySelector('.label').textContent = label;
          item.querySelector('.detail').textContent = String(detail);
          logList.insertBefore(item, logList.firstChild);
        }
        function xhr(method, url, configure, body) {
          return new Promise(function (resolve) {
            var request = new XMLHttpRequest();
            request.open(method, url);
            configure(request);
            request.onloadend = function () { resolve(request); };
            request.send(body === undefined ? null : body);
          });
        }
        var actions = {
          fetchGet: async function () {
            var response = await fetch('https://jsonplaceholder.typicode.com/todos/1');
            var json = await response.json();
            log('fetch GET', response.status + ' · ' + json.title, response.ok ? 'ok' : 'warn');
          },
          fetchPost: async function () {
            var response = await fetch('https://httpbin.org/post', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json', 'X-Donk-Demo': 'fetch-post' },
              body: JSON.stringify({ app: 'donk', feature: 'webview-capture', items: [1, 2, 3], nested: { ok: true } })
            });
            var json = await response.json();
            log('fetch POST', response.status + ' · echoed ' + Object.keys(json.json || {}).length + ' keys', response.ok ? 'ok' : 'warn');
          },
          notFound: async function () {
            var response = await fetch('https://httpbin.org/status/404');
            log('fetch 404', response.status + ' ' + (response.statusText || 'Not Found'), 'warn');
          },
          networkError: async function () {
            try {
              await fetch('https://no-such-host.donk.invalid/data.json');
              log('network error', 'unexpected success', 'warn');
            } catch (error) {
              log('network error', error.message, 'err');
            }
          },
          xhrGet: async function () {
            var request = await xhr('GET', 'https://httpbin.org/get?source=xhr&lang=en', function (r) {
              r.setRequestHeader('X-Donk-Demo', 'xhr-get');
              r.setRequestHeader('Accept', 'application/json');
            });
            log('XHR GET', request.status, request.status === 200 ? 'ok' : 'err');
          },
          xhrPost: async function () {
            var request = await xhr('POST', 'https://httpbin.org/post', function (r) {
              r.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
              r.setRequestHeader('X-Donk-Demo', 'xhr-post');
              r.responseType = 'json';
            }, 'user=donk&role=debugger&count=3');
            log('XHR POST', request.status + (request.response ? ' · form ' + JSON.stringify(request.response.form) : ''), request.status === 200 ? 'ok' : 'err');
          },
          beacon: function () {
            var payload = new Blob([JSON.stringify({ event: 'demo_beacon', at: new Date().toISOString() })], { type: 'text/plain' });
            var queued = navigator.sendBeacon('https://httpbin.org/post', payload);
            log('sendBeacon', queued ? 'queued' : 'refused', queued ? 'ok' : 'err');
          },
          fetchBlob: async function () {
            var response = await fetch('https://httpbin.org/image/png');
            var blob = await response.blob();
            log('fetch image', response.status + ' · ' + blob.size + ' bytes', response.ok ? 'ok' : 'warn');
          },
          websocket: function () {
            return new Promise(function (resolve) {
              var socket = new WebSocket('wss://ws.postman-echo.com/raw');
              var received = 0;
              var timer = setTimeout(function () { if (socket.readyState < 2) { socket.close(4000, 'timeout'); } }, 10000);
              socket.onopen = function () {
                socket.send('hello from donk');
                socket.send(JSON.stringify({ type: 'ping', at: Date.now() }));
                socket.send('bye');
              };
              socket.onmessage = function () { received += 1; if (received === 3) { socket.close(1000, 'done'); } };
              socket.onclose = function (event) { clearTimeout(timer); log('WebSocket', 'closed ' + event.code + ' · ' + received + ' echoes', event.code === 1000 ? 'ok' : 'warn'); resolve(); };
            });
          },
          eventSource: function () {
            return new Promise(function (resolve) {
              var source = new EventSource('https://stream.wikimedia.org/v2/stream/recentchange');
              var count = 0;
              var finish = function (detail, tone) { source.close(); log('EventSource', detail, tone); resolve(); };
              var timer = setTimeout(function () { finish(count + ' events · timed out', count ? 'ok' : 'warn'); }, 8000);
              source.onmessage = function () { count += 1; if (count === 5) { clearTimeout(timer); finish('5 events', 'ok'); } };
              source.onerror = function () { if (source.readyState === 2) { clearTimeout(timer); finish('connection failed', 'err'); } };
            });
          },
          images: function () {
            var seed = Math.floor(Math.random() * 1000);
            for (var i = 0; i < 3; i++) {
              var image = new Image();
              image.src = 'https://picsum.photos/seed/donk' + (seed + i) + '/240/160';
              media.appendChild(image);
            }
            log('images', '3 × picsum.photos', 'info');
          },
          iframe: function () {
            var frame = document.createElement('iframe');
            frame.src = 'https://example.com/';
            media.appendChild(frame);
            log('iframe', 'example.com', 'info');
          },
          runAll: async function () {
            var names = ['fetchGet', 'fetchPost', 'notFound', 'networkError', 'xhrGet', 'xhrPost', 'beacon', 'fetchBlob', 'websocket', 'eventSource', 'images', 'iframe'];
            await Promise.all(names.map(function (name) {
              return Promise.resolve().then(actions[name]).catch(function (error) { log(name, error.message, 'err'); });
            }));
            log('run all', 'finished', 'ok');
          }
        };
        document.addEventListener('click', function (event) {
          var button = event.target.closest('button[data-action]');
          if (!button) { return; }
          Promise.resolve().then(actions[button.dataset.action]).catch(function (error) { log(button.dataset.action, error.message, 'err'); });
        });
        window.donkDemo = { run: function (name) { return actions[name](); }, runAll: function () { return actions.runAll(); } };
      })();
    </script>
    </body>
    </html>
    """#
}
