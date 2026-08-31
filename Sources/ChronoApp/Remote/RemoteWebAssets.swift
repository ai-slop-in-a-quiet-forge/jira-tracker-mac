import Foundation

/// The phone remote, embedded in the binary.
///
/// Deliberately one self-contained page with no external requests: no CDN, no fonts to fetch,
/// no service worker to go stale. It has to work on hotel Wi-Fi with no internet, because that
/// is exactly when you are away from your desk with a timer running.
///
/// The signing code mirrors `ChronoCore.RemoteAuth` byte for byte, and a test in
/// `SigningContractTests` pins a shared vector so the two cannot drift.
enum RemoteWebAssets {

    static let manifestJSON = #"""
    {
      "name": "Chrono Remote",
      "short_name": "Chrono",
      "display": "standalone",
      "background_color": "#0b0d12",
      "theme_color": "#0b0d12",
      "icons": [{ "src": "/icon.svg", "sizes": "any", "type": "image/svg+xml" }]
    }
    """#

    static let iconSVG = #"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
      <rect width="512" height="512" rx="112" fill="#2563eb"/>
      <g fill="none" stroke="#ffffff" stroke-width="34" stroke-linecap="round">
        <circle cx="256" cy="256" r="132"/>
        <path d="M256 256V174M256 256l58 42"/>
      </g>
      <circle cx="340" cy="340" r="30" fill="#10b981"/>
    </svg>
    """#

    static let indexHTML = #"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <meta name="apple-mobile-web-app-title" content="Chrono">
    <meta name="theme-color" content="#0b0d12">
    <link rel="manifest" href="/manifest.webmanifest">
    <link rel="apple-touch-icon" href="/icon.svg">
    <title>Chrono Remote</title>
    <style>
      :root {
        --bg: #0b0d12;
        --card: #151922;
        --card-2: #1d222d;
        --text: #f2f4f8;
        --muted: #8b93a4;
        --accent: #3b82f6;
        --warn: #f59e0b;
        --danger: #ef4444;
        --ok: #10b981;
        --radius: 18px;
      }
      * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
      html, body { margin: 0; height: 100%; }
      body {
        background: var(--bg);
        color: var(--text);
        font: 16px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
        padding: env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left);
        overscroll-behavior: none;
      }
      .wrap { max-width: 520px; margin: 0 auto; padding: 18px 16px 32px; }

      header { display: flex; align-items: center; gap: 10px; margin-bottom: 16px; }
      header .dot { width: 9px; height: 9px; border-radius: 50%; background: var(--muted); flex: none; }
      header .dot.live { background: var(--ok); box-shadow: 0 0 0 4px rgba(16,185,129,.18); }
      header .dot.stale { background: var(--danger); }
      header .name { font-size: 13px; color: var(--muted); font-weight: 500; }
      header .spacer { flex: 1; }
      header button.link { background: none; border: 0; color: var(--muted); font-size: 12px; padding: 6px; }

      .banner {
        display: none; align-items: flex-start; gap: 10px;
        background: rgba(245,158,11,.14); border: 1px solid rgba(245,158,11,.35);
        color: #ffd894; border-radius: 14px; padding: 12px 14px; margin-bottom: 14px; font-size: 13.5px;
      }
      .banner.show { display: flex; }

      .card { background: var(--card); border-radius: var(--radius); padding: 20px; margin-bottom: 14px; }

      .status { font-size: 12px; letter-spacing: .08em; text-transform: uppercase; color: var(--muted); font-weight: 600; }
      .label { font-size: 20px; font-weight: 650; margin: 6px 0 2px; word-break: break-word; }
      .summary { font-size: 13.5px; color: var(--muted); margin-bottom: 14px; }
      .timer {
        font-size: 58px; font-weight: 600; letter-spacing: -.02em;
        font-variant-numeric: tabular-nums; font-feature-settings: "tnum";
        margin: 4px 0 2px;
      }
      .timer.paused { color: var(--warn); }
      .timer.idle { color: var(--muted); }
      .today { font-size: 13px; color: var(--muted); }

      .ring { display: flex; align-items: center; gap: 14px; margin-top: 16px; }
      .ring svg { flex: none; transform: rotate(-90deg); }
      .ring .meta { font-size: 13px; color: var(--muted); }
      .ring .meta b { color: var(--text); font-weight: 600; }

      .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
      button.action {
        appearance: none; border: 0; border-radius: 14px; padding: 18px 12px;
        font-size: 16px; font-weight: 600; color: var(--text);
        background: var(--card-2); transition: transform .08s ease, opacity .15s ease;
      }
      button.action:active { transform: scale(.97); }
      button.action:disabled { opacity: .35; }
      button.action.primary { background: var(--accent); }
      button.action.warn { background: rgba(245,158,11,.2); color: #ffd894; }
      button.action.danger { background: rgba(239,68,68,.18); color: #ffb4b4; }
      button.action.wide { grid-column: 1 / -1; }
      button.action .sub { display: block; font-size: 11.5px; font-weight: 500; opacity: .7; margin-top: 3px; }

      h2 { font-size: 12px; letter-spacing: .08em; text-transform: uppercase; color: var(--muted); margin: 22px 0 8px; }
      .row {
        display: flex; align-items: center; gap: 12px; width: 100%;
        background: var(--card); border: 0; border-radius: 14px; padding: 14px 16px;
        color: var(--text); text-align: left; margin-bottom: 8px; font-size: 15px;
      }
      .row:active { background: var(--card-2); }
      .row .key { font-weight: 650; }
      .row .sm { font-size: 12.5px; color: var(--muted); display: block; margin-top: 2px; }
      .row .arrow { margin-left: auto; color: var(--muted); }

      .toast {
        position: fixed; left: 50%; transform: translateX(-50%);
        bottom: calc(24px + env(safe-area-inset-bottom));
        background: #23293a; color: var(--text); padding: 12px 18px; border-radius: 999px;
        font-size: 13.5px; opacity: 0; transition: opacity .2s ease; pointer-events: none; max-width: 90%;
      }
      .toast.show { opacity: 1; }

      .setup { text-align: center; padding: 60px 20px; }
      .setup h1 { font-size: 22px; margin-bottom: 10px; }
      .setup p { color: var(--muted); font-size: 14px; }
    </style>
    </head>
    <body>
    <div class="wrap">
      <div id="setup" class="setup" hidden>
        <h1>Not paired yet</h1>
        <p>Open <b>Settings &rsaquo; Phone</b> in Chrono on your Mac and scan the QR code with this phone's camera.</p>
      </div>

      <div id="app" hidden>
        <header>
          <span class="dot" id="conn"></span>
          <span class="name" id="device">Chrono</span>
          <span class="spacer"></span>
          <button class="link" id="forget">Unpair</button>
        </header>

        <div class="banner" id="banner">
          <span>&#9888;</span>
          <span id="bannerText"></span>
        </div>

        <div class="card">
          <div class="status" id="status">&mdash;</div>
          <div class="label" id="label">&mdash;</div>
          <div class="summary" id="summary"></div>
          <div class="timer" id="timer">0:00</div>
          <div class="today" id="today"></div>

          <div class="ring">
            <svg width="46" height="46" viewBox="0 0 46 46">
              <circle cx="23" cy="23" r="19" fill="none" stroke="rgba(255,255,255,.10)" stroke-width="5"/>
              <circle id="ringArc" cx="23" cy="23" r="19" fill="none" stroke="var(--accent)"
                      stroke-width="5" stroke-linecap="round" stroke-dasharray="119.4" stroke-dashoffset="119.4"/>
            </svg>
            <div class="meta"><b id="dayTotal">0h</b> <span id="dayTarget"></span><br><span id="queued"></span></div>
          </div>
        </div>

        <div class="grid">
          <button class="action primary wide" id="toggle">Pause</button>
          <button class="action warn" id="meeting">Meeting<span class="sub">log this as a call</span></button>
          <button class="action danger" id="stop">Stop<span class="sub">log the time</span></button>
          <button class="action wide" id="snooze">Silence reminders for 30 min</button>
        </div>

        <h2 id="recentHeading" hidden>Switch to</h2>
        <div id="recents"></div>
      </div>
    </div>
    <div class="toast" id="toast"></div>

    <script>
    "use strict";

    /* ---------------------------------------------------------------- crypto */
    /* SHA-256 + HMAC-SHA256, mirroring ChronoCore.RemoteAuth.
       WebCrypto is not available: crypto.subtle requires a secure context, and this page is
       served over plain HTTP on a LAN address. Shipping our own keeps the pairing secret off
       the wire — only signatures travel. */

    const K = [
      0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
      0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
      0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
      0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
      0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
      0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
      0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
      0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
    ];

    function sha256(bytes) {
      const h = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19];
      const bitLength = bytes.length * 8;
      const padded = new Uint8Array(((bytes.length + 9) + 63) & ~63);
      padded.set(bytes);
      padded[bytes.length] = 0x80;
      const view = new DataView(padded.buffer);
      view.setUint32(padded.length - 4, bitLength >>> 0, false);
      view.setUint32(padded.length - 8, Math.floor(bitLength / 0x100000000), false);

      const w = new Uint32Array(64);
      const rotr = (x, n) => (x >>> n) | (x << (32 - n));

      for (let offset = 0; offset < padded.length; offset += 64) {
        for (let i = 0; i < 16; i++) w[i] = view.getUint32(offset + i * 4, false);
        for (let i = 16; i < 64; i++) {
          const s0 = rotr(w[i-15],7) ^ rotr(w[i-15],18) ^ (w[i-15] >>> 3);
          const s1 = rotr(w[i-2],17) ^ rotr(w[i-2],19) ^ (w[i-2] >>> 10);
          w[i] = (w[i-16] + s0 + w[i-7] + s1) >>> 0;
        }
        let a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],hh=h[7];
        for (let i = 0; i < 64; i++) {
          const S1 = rotr(e,6) ^ rotr(e,11) ^ rotr(e,25);
          const ch = (e & f) ^ (~e & g);
          const t1 = (hh + S1 + ch + K[i] + w[i]) >>> 0;
          const S0 = rotr(a,2) ^ rotr(a,13) ^ rotr(a,22);
          const maj = (a & b) ^ (a & c) ^ (b & c);
          const t2 = (S0 + maj) >>> 0;
          hh=g; g=f; f=e; e=(d+t1)>>>0; d=c; c=b; b=a; a=(t1+t2)>>>0;
        }
        h[0]=(h[0]+a)>>>0; h[1]=(h[1]+b)>>>0; h[2]=(h[2]+c)>>>0; h[3]=(h[3]+d)>>>0;
        h[4]=(h[4]+e)>>>0; h[5]=(h[5]+f)>>>0; h[6]=(h[6]+g)>>>0; h[7]=(h[7]+hh)>>>0;
      }
      const out = new Uint8Array(32);
      const outView = new DataView(out.buffer);
      for (let i = 0; i < 8; i++) outView.setUint32(i * 4, h[i], false);
      return out;
    }

    function hmacSha256(keyBytes, messageBytes) {
      const blockSize = 64;
      let key = keyBytes.length > blockSize ? sha256(keyBytes) : keyBytes;
      const padKey = new Uint8Array(blockSize);
      padKey.set(key);
      const inner = new Uint8Array(blockSize + messageBytes.length);
      const outer = new Uint8Array(blockSize + 32);
      for (let i = 0; i < blockSize; i++) {
        inner[i] = padKey[i] ^ 0x36;
        outer[i] = padKey[i] ^ 0x5c;
      }
      inner.set(messageBytes, blockSize);
      outer.set(sha256(inner), blockSize);
      return sha256(outer);
    }

    const utf8 = (s) => new TextEncoder().encode(s);
    const b64 = (bytes) => { let s = ''; for (const x of bytes) s += String.fromCharCode(x); return btoa(s); };

    function signature(secret, counter, timestamp, payload) {
      return b64(hmacSha256(sha256(utf8(secret)), utf8(counter + '.' + timestamp + '.' + payload)));
    }

    /* ------------------------------------------------------------- pairing */

    const store = {
      get secret() { try { return localStorage.getItem('chrono.secret'); } catch (e) { return null; } },
      set secret(v) { try { localStorage.setItem('chrono.secret', v); } catch (e) {} },
      get device() { try { return localStorage.getItem('chrono.device'); } catch (e) { return null; } },
      set device(v) { try { localStorage.setItem('chrono.device', v); } catch (e) {} },
      get name() { try { return localStorage.getItem('chrono.name') || 'Chrono'; } catch (e) { return 'Chrono'; } },
      set name(v) { try { localStorage.setItem('chrono.name', v); } catch (e) {} },
      nextCounter() {
        let n = 0;
        try { n = parseInt(localStorage.getItem('chrono.counter') || '0', 10) || 0; } catch (e) {}
        n += 1;
        try { localStorage.setItem('chrono.counter', String(n)); } catch (e) {}
        return n;
      },
      clear() { try { localStorage.clear(); } catch (e) {} }
    };

    /* The pairing secret arrives in the URL fragment, which browsers never send to the server.
       Read it once, keep it locally, then scrub it from the address bar and history. */
    (function adoptPairing() {
      if (!location.hash) return;
      const params = new URLSearchParams(location.hash.slice(1));
      const secret = params.get('s');
      if (!secret) return;
      store.secret = secret;
      if (params.get('n')) store.name = decodeURIComponent(params.get('n'));
      history.replaceState(null, '', location.pathname);
    })();

    if (!store.device) {
      /* A stable per-phone id, so the Mac can track counters per device. */
      store.device = 'phone-' + Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
    }

    /* ----------------------------------------------------------------- api */

    async function request(path, method, bodyObject) {
      const secret = store.secret;
      if (!secret) throw new Error('not paired');

      const body = bodyObject ? JSON.stringify(bodyObject) : '';
      /* A GET has no body, so the path is what gets signed. */
      const payload = method === 'GET' ? path : body;
      const counter = store.nextCounter();
      const timestamp = Math.floor(Date.now() / 1000);

      const response = await fetch(path, {
        method,
        headers: {
          'Content-Type': 'application/json',
          'X-Chrono-Counter': String(counter),
          'X-Chrono-Timestamp': String(timestamp),
          'X-Chrono-Mac': signature(secret, counter, timestamp, payload),
          'X-Chrono-Device': store.device
        },
        body: method === 'GET' ? undefined : body,
        cache: 'no-store'
      });

      if (response.status === 401 || response.status === 403) {
        throw new Error('Pairing rejected — re-scan the QR code on your Mac.');
      }
      if (!response.ok) throw new Error('Mac returned ' + response.status);
      return response.json();
    }

    /* -------------------------------------------------------------- render */

    const el = (id) => document.getElementById(id);
    let state = null;
    let lastGoodAt = 0;
    let localElapsed = 0;

    function humane(seconds) {
      seconds = Math.max(0, Math.round(seconds));
      if (seconds < 60) return seconds + 's';
      const h = Math.floor(seconds / 3600), m = Math.floor((seconds % 3600) / 60);
      if (!h) return m + 'm';
      if (!m) return h + 'h';
      return h + 'h ' + m + 'm';
    }

    function clock(seconds) {
      seconds = Math.max(0, Math.round(seconds));
      const h = Math.floor(seconds / 3600), m = Math.floor((seconds % 3600) / 60), s = seconds % 60;
      const mm = String(m).padStart(2, '0'), ss = String(s).padStart(2, '0');
      return h > 0 ? h + ':' + mm + ':' + ss : m + ':' + ss;
    }

    function toast(message) {
      const node = el('toast');
      node.textContent = message;
      node.classList.add('show');
      clearTimeout(toast.timer);
      toast.timer = setTimeout(() => node.classList.remove('show'), 2600);
    }

    function render() {
      if (!state) return;
      const running = state.s === 1, paused = state.s === 2;

      el('device').textContent = state.name || store.name;
      el('status').textContent = running ? 'Tracking' : (paused ? 'Paused' : 'Not tracking');
      el('label').textContent = state.l || 'Nothing selected';
      el('summary').textContent = state.sum || '';
      el('summary').style.display = state.sum ? 'block' : 'none';

      const timer = el('timer');
      timer.textContent = clock(running ? localElapsed : (paused ? state.e : 0));
      timer.className = 'timer' + (paused ? ' paused' : (running ? '' : ' idle'));

      el('today').textContent = state.d ? humane(state.d) + ' logged today' : '';

      el('dayTotal').textContent = humane(state.d || 0);
      el('dayTarget').textContent = state.t ? 'of ' + humane(state.t) : '';
      const fraction = state.t ? Math.min(1, (state.d || 0) / state.t) : 0;
      el('ringArc').setAttribute('stroke-dashoffset', String(119.4 * (1 - fraction)));

      const notes = [];
      if (state.q) notes.push(state.q + (state.q === 1 ? ' worklog queued' : ' worklogs queued'));
      if (state.u) notes.push(humane(state.u) + ' unfiled');
      el('queued').textContent = notes.join(' · ');

      const banner = el('banner');
      if (state.m && running) {
        el('bannerText').textContent = 'Your Mac thinks you are on a call, and ' + (state.l || 'a task') + ' is still tracking.';
        banner.classList.add('show');
      } else {
        banner.classList.remove('show');
      }

      el('toggle').textContent = running ? 'Pause' : (paused ? 'Resume' : 'Resume last task');
      el('stop').disabled = state.s === 0;
      el('meeting').disabled = state.s === 0;

      const recents = state.recents || [];
      el('recentHeading').hidden = recents.length === 0;
      const list = el('recents');
      if (list.dataset.signature !== JSON.stringify(recents)) {
        list.dataset.signature = JSON.stringify(recents);
        list.innerHTML = '';
        recents.forEach((issue) => {
          const button = document.createElement('button');
          button.className = 'row';
          const key = document.createElement('span');
          key.innerHTML = '<span class="key">' + issue.key + '</span><span class="sm"></span>';
          key.querySelector('.sm').textContent = issue.summary || '';
          const arrow = document.createElement('span');
          arrow.className = 'arrow';
          arrow.textContent = '▶';
          button.appendChild(key);
          button.appendChild(arrow);
          button.onclick = () => send({ c: 'startIssue', v: issue.key }, 'Switched to ' + issue.key);
          list.appendChild(button);
        });
      }
    }

    function markConnection(ok) {
      const dot = el('conn');
      dot.className = 'dot' + (ok ? ' live' : (Date.now() - lastGoodAt > 12000 ? ' stale' : ''));
    }

    async function poll() {
      try {
        state = await request('/state', 'GET');
        localElapsed = state.e || 0;
        lastGoodAt = Date.now();
        markConnection(true);
        render();
      } catch (error) {
        markConnection(false);
        if (String(error.message).indexOf('Pairing rejected') === 0) toast(error.message);
      }
    }

    async function send(command, successMessage) {
      try {
        const result = await request('/command', 'POST', command);
        if (result.snapshot) { state = Object.assign(state || {}, result.snapshot); localElapsed = state.e || 0; render(); }
        toast(result.accepted ? (successMessage || result.message || 'Done') : (result.message || 'Refused'));
        setTimeout(poll, 350);
      } catch (error) {
        toast(error.message);
      }
    }

    /* --------------------------------------------------------------- wiring */

    if (!store.secret) {
      el('setup').hidden = false;
    } else {
      el('app').hidden = false;

      el('toggle').onclick = () => {
        if (!state) return;
        if (state.s === 1) send({ c: 'pause' }, 'Paused');
        else if (state.s === 2) send({ c: 'resume' }, 'Resumed');
        else send({ c: 'resumeLast' }, 'Resumed');
      };
      el('stop').onclick = () => send({ c: 'stop' }, 'Stopped and logged');
      el('meeting').onclick = () => send({ c: 'switchToMeeting' }, 'Logging this as a meeting');
      el('snooze').onclick = () => send({ c: 'snooze', v: 30 }, 'Reminders silenced for 30 minutes');
      el('forget').onclick = () => {
        if (!confirm('Unpair this phone from your Mac?')) return;
        store.clear();
        location.reload();
      };

      /* Tick the displayed timer locally between polls, so it counts smoothly rather than
         jumping every couple of seconds. */
      setInterval(() => { if (state && state.s === 1) { localElapsed += 1; render(); } }, 1000);
      setInterval(poll, 2500);
      poll();

      /* Refresh the instant the phone comes back to the foreground. */
      document.addEventListener('visibilitychange', () => { if (!document.hidden) poll(); });
    }
    </script>
    </body>
    </html>
    """#
}
