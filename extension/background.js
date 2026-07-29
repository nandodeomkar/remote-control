// Remote Control — Tab Bridge (MV3 service worker).
//
// Talks ONLY to the Remote Control server on this machine over
// ws://127.0.0.1:<PORT>. Sends full tab snapshots (title + favicon + tab
// groups, never full URLs beyond what the local favicon cache needs) and full
// bookmark snapshots (bm.state — id + parentId + title only, never a url and
// never an icon), and executes tabs.activate / tabs.close plus the bm.open /
// bm.star / bm.unstar / bm.remove commands from the server.
//
// Privacy discipline: NEVER log tab titles, group titles, bookmark titles,
// bookmark urls, or tab urls to the console — they are all browsing data, and
// a bookmark collection is a more durable profile of the owner than a live tab
// list is. Lifecycle events and counts only.

// Must match the server's RC_EXT_PORT (default 17779). If you change the
// server port, edit this const and press the reload arrow for the extension
// on chrome://extensions.
const PORT = 17779;

// Wire caps (must stay in sync with protocol/SPEC.md §15).
const MAX_TABS = 50;
const MAX_ICON_B64 = 4096; // chars; icons above this are dropped
const MAX_FRAME_BYTES = 57344; // 56 KB — under the server's 64 KB WS cap
const MAX_GROUPS = 16; // tab groups per snapshot (SPEC §15, protoVersion 1.5)
const MAX_GROUP_TITLE = 32; // chars; group titles truncated above this
const MAX_BM_NODES = 500; // bookmark nodes per snapshot (SPEC §15, protoVersion 1.6)
const MAX_BM_TITLE = 48; // chars; bookmark titles truncated above this

// UTF-8 byte length. String.prototype.length counts UTF-16 CODE UNITS, so a
// CJK char reads as 1 but costs 3 bytes on the wire and an emoji reads as 2 but
// costs 4 — a code-unit count under-measures a frame by up to 3x. The server's
// max_message_size kills the ext session on an oversize frame, so every budget
// check below must measure bytes. TextEncoder is a platform built-in and is
// available in MV3 service workers.
function bytesOf(s) {
  return new TextEncoder().encode(s).length;
}

// chrome.tabGroups may be absent (older browsers / non-Chromium forks) — the
// worker must still load and report ungrouped tabs.
const GROUP_ID_NONE = chrome.tabGroups ? chrome.tabGroups.TAB_GROUP_ID_NONE : -1;

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
// Group events feed the same debounced snapshot (guarded: the API may be
// absent on browsers without tab groups — the worker must still load).
if (chrome.tabGroups) {
  chrome.tabGroups.onCreated.addListener(onTabEvent);
  chrome.tabGroups.onUpdated.addListener(onTabEvent);
  chrome.tabGroups.onRemoved.addListener(onTabEvent);
  chrome.tabGroups.onMoved.addListener(onTabEvent);
}

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
    // groupId only when grouped — never emit -1 (TAB_GROUP_ID_NONE), never null.
    if (tab.groupId !== undefined && tab.groupId !== GROUP_ID_NONE) {
      el.groupId = tab.groupId;
    }
    const icon = tab.url ? await favicon(tab.url) : null;
    if (icon !== null && icon.length <= MAX_ICON_B64) {
      el.icon = icon;
    }
    els.push(el);
  }

  // Tab groups (protoVersion 1.5): degrade to [] on ANY failure — a snapshot
  // without groups is better than no snapshot. NEVER log group titles.
  let groups = [];
  if (chrome.tabGroups) {
    try {
      const referenced = new Set(
        els.filter((e) => e.groupId !== undefined).map((e) => e.groupId)
      );
      const all = await chrome.tabGroups.query({});
      groups = all
        .filter((g) => referenced.has(g.id)) // drop groups whose tabs fell past the 50-tab cap
        .slice(0, MAX_GROUPS)
        .map((g) => ({
          id: g.id,
          title: (g.title || "").slice(0, MAX_GROUP_TITLE),
          color: g.color,
          collapsed: !!g.collapsed,
        }));
    } catch {
      groups = [];
    }
  }

  // 56 KB serialized budget: strip icons from the END of the list until under.
  // Measured in UTF-8 BYTES via bytesOf, never in UTF-16 code units.
  let frame = JSON.stringify({ t: "tabs.state", p: { tabs: els, groups } });
  for (let i = els.length - 1; i >= 0 && bytesOf(frame) > MAX_FRAME_BYTES; i--) {
    if (els[i].icon !== undefined) {
      delete els[i].icon;
      frame = JSON.stringify({ t: "tabs.state", p: { tabs: els, groups } });
    }
  }

  if (ws && ws.readyState === WebSocket.OPEN) {
    try {
      ws.send(frame);
      console.log(
        "[tab-bridge] snapshot sent:",
        els.length,
        "tabs,",
        groups.length,
        "groups"
      );
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
