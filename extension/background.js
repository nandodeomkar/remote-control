// Remote Control — Tab Bridge (MV3 service worker).
//
// Talks ONLY to the Remote Control server on this machine over
// ws://127.0.0.1:<PORT>. Sends full tab snapshots (title + favicon, never
// full URLs beyond what the local favicon cache needs) and executes
// tabs.activate / tabs.close commands from the server.
//
// Privacy discipline: NEVER log tab titles or urls to the console — they
// are browsing data. Lifecycle events and counts only.

// Must match the server's RC_EXT_PORT (default 17779). If you change the
// server port, edit this const and press the reload arrow for the extension
// on chrome://extensions.
const PORT = 17779;

// Wire caps (must stay in sync with protocol/SPEC.md §15).
const MAX_TABS = 50;
const MAX_ICON_B64 = 4096; // chars; icons above this are dropped
const MAX_FRAME_BYTES = 57344; // 56 KB — under the server's 64 KB WS cap

const PING_INTERVAL_MS = 20000; // Chrome >=116: WS message activity keeps the SW alive
const DEBOUNCE_MS = 200;
const BACKOFF_STEPS_MS = [1000, 2000, 4000, 8000, 10000]; // Phase-03 policy clone

let ws = null;
let pingTimer = null;
let reconnectTimer = null;
let backoffIdx = 0;
let snapshotTimer = null;

// Favicon base64 cache keyed by page url. Lost on SW restart — fine, it
// refills from Chrome's own favicon cache.
const faviconCache = new Map();

// ---------------------------------------------------------------------------
// Connection lifecycle
// ---------------------------------------------------------------------------

function connect() {
  if (
    ws &&
    (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)
  ) {
    return;
  }
  clearTimeout(reconnectTimer);
  reconnectTimer = null;

  let socket;
  try {
    socket = new WebSocket("ws://127.0.0.1:" + PORT);
  } catch (e) {
    console.log("[tab-bridge] ws construct failed:", e && e.message);
    scheduleReconnect();
    return;
  }
  ws = socket;

  socket.onopen = () => {
    if (ws !== socket) return;
    console.log("[tab-bridge] connected");
    backoffIdx = 0;
    send({
      t: "ext.hello",
      p: { extVersion: chrome.runtime.getManifest().version },
    });
    clearInterval(pingTimer);
    pingTimer = setInterval(() => send({ t: "ext.ping", p: {} }), PING_INTERVAL_MS);
    // Full snapshot on every (re)connect — the SW is stateless by design.
    buildAndSend();
  };

  socket.onmessage = (ev) => {
    let msg;
    try {
      msg = JSON.parse(ev.data);
    } catch {
      return;
    }
    if (!msg || typeof msg.t !== "string") return;
    const p = msg.p || {};
    switch (msg.t) {
      case "tabs.activate":
        // Stale ids self-heal on the next snapshot; swallow rejections.
        chrome.tabs
          .update(p.id, { active: true })
          .then(() => chrome.tabs.get(p.id))
          .then((tab) => chrome.windows.update(tab.windowId, { focused: true }))
          .catch(() => {});
        break;
      case "tabs.close":
        chrome.tabs.remove(p.id).catch(() => {});
        break;
      case "ext.pong":
        break; // keepalive echo — no-op
      default:
        break; // unknown type — ignore (forward compatibility)
    }
  };

  socket.onclose = () => {
    if (ws !== socket) return;
    console.log("[tab-bridge] disconnected");
    teardownSocket();
    scheduleReconnect();
  };

  socket.onerror = () => {
    if (ws !== socket) return;
    console.log("[tab-bridge] socket error");
    teardownSocket();
    scheduleReconnect();
  };
}

function teardownSocket() {
  clearInterval(pingTimer);
  pingTimer = null;
  if (ws) {
    try {
      ws.close();
    } catch {
      /* already closed */
    }
  }
  ws = null;
}

function scheduleReconnect() {
  if (reconnectTimer) return;
  const delay = BACKOFF_STEPS_MS[Math.min(backoffIdx, BACKOFF_STEPS_MS.length - 1)];
  backoffIdx += 1;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, delay);
}

function send(obj) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    try {
      ws.send(JSON.stringify(obj));
    } catch {
      /* socket died mid-send; onclose handles it */
    }
  }
}

// ---------------------------------------------------------------------------
// Resurrection (A5): the SW dies ~30s after the last event when the server is
// down. The alarm (min period 30s since Chrome 120) plus runtime hooks plus
// every chrome.tabs event below re-run connect() when the socket is closed.
// ---------------------------------------------------------------------------

chrome.alarms.create("rc-reconnect", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === "rc-reconnect") connect();
});
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);

// ---------------------------------------------------------------------------
// Tab events -> debounced full snapshot
// ---------------------------------------------------------------------------

function onTabEvent() {
  connect(); // reconnect-if-closed guard: every tabs event wakes the SW
  scheduleSnapshot();
}

chrome.tabs.onCreated.addListener(onTabEvent);
chrome.tabs.onRemoved.addListener(onTabEvent);
chrome.tabs.onActivated.addListener(onTabEvent);
chrome.tabs.onMoved.addListener(onTabEvent);
chrome.tabs.onAttached.addListener(onTabEvent);
chrome.tabs.onDetached.addListener(onTabEvent);
chrome.tabs.onReplaced.addListener(onTabEvent); // prerender id swaps
chrome.windows.onFocusChanged.addListener(onTabEvent);
// onUpdated fires per load-progress tick — only react to meaningful changes.
chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (
    changeInfo.title !== undefined ||
    changeInfo.favIconUrl !== undefined ||
    changeInfo.status === "complete"
  ) {
    onTabEvent();
  }
});

function scheduleSnapshot() {
  clearTimeout(snapshotTimer);
  snapshotTimer = setTimeout(buildAndSend, DEBOUNCE_MS);
}

// ---------------------------------------------------------------------------
// Snapshot builder — always a FULL chrome.tabs.query({}), never a diff
// (SW restarts lose all module state; full snapshots are idempotent).
// ---------------------------------------------------------------------------

async function buildAndSend() {
  let tabs;
  try {
    tabs = await chrome.tabs.query({});
  } catch (e) {
    console.log("[tab-bridge] tabs.query failed:", e && e.message);
    return;
  }

  tabs.sort((a, b) => a.windowId - b.windowId || a.index - b.index);
  tabs = tabs.slice(0, MAX_TABS);

  // Exactly one active tab: the active tab of the last-focused normal window.
  let activeId = null;
  try {
    const win = await chrome.windows.getLastFocused({ windowTypes: ["normal"] });
    if (win && win.id !== undefined) {
      const active = tabs.find((t) => t.windowId === win.id && t.active);
      if (active) activeId = active.id;
    }
  } catch {
    /* fall through to first tab.active below */
  }
  if (activeId === null) {
    const firstActive = tabs.find((t) => t.active);
    if (firstActive) activeId = firstActive.id;
  }

  const els = [];
  for (const tab of tabs) {
    // NEVER include tab.url in the payload — titles are enough (privacy).
    const el = {
      id: tab.id,
      title: tab.title !== undefined ? tab.title : "",
      active: tab.id === activeId,
    };
    const icon = tab.url ? await favicon(tab.url) : null;
    if (icon !== null && icon.length <= MAX_ICON_B64) {
      el.icon = icon;
    }
    els.push(el);
  }

  // 56 KB serialized budget: strip icons from the END of the list until under.
  let frame = JSON.stringify({ t: "tabs.state", p: { tabs: els } });
  for (let i = els.length - 1; i >= 0 && frame.length > MAX_FRAME_BYTES; i--) {
    if (els[i].icon !== undefined) {
      delete els[i].icon;
      frame = JSON.stringify({ t: "tabs.state", p: { tabs: els } });
    }
  }

  if (ws && ws.readyState === WebSocket.OPEN) {
    try {
      ws.send(frame);
      console.log("[tab-bridge] snapshot sent:", els.length, "tabs");
    } catch {
      /* onclose handles it; next connect pushes a fresh snapshot */
    }
  }
  // Socket not open: skip — the connect handler pushes a snapshot on open.
}

// ---------------------------------------------------------------------------
// Favicons via the `favicon` permission's _favicon/ endpoint (Chrome's own
// cache — same-origin fetch, no CORS, no <all_urls>). Returns base64 PNG
// without a data: prefix, or null on any failure (row shows fallback glyph).
// ---------------------------------------------------------------------------

async function favicon(url) {
  if (faviconCache.has(url)) return faviconCache.get(url);
  let b64 = null;
  try {
    const res = await fetch(
      "chrome-extension://" +
        chrome.runtime.id +
        "/_favicon/?pageUrl=" +
        encodeURIComponent(url) +
        "&size=32"
    );
    if (res.ok) {
      const buf = await res.arrayBuffer();
      b64 = bufToBase64(buf);
    }
  } catch {
    b64 = null;
  }
  faviconCache.set(url, b64);
  return b64;
}

function bufToBase64(buf) {
  const bytes = new Uint8Array(buf);
  const CHUNK = 8192; // dodge String.fromCharCode argument-limit blowups
  let binary = "";
  for (let i = 0; i < bytes.length; i += CHUNK) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
  }
  return btoa(binary);
}

// Kick off on SW load (covers browser launch, extension reload, SW restart).
connect();
