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

// A bookmark import fires hundreds of onCreated events. Chrome's own guidance:
// expensive observers should ignore updates between onImportBegan and
// onImportEnded — otherwise a full getTree() runs on every settling gap of a
// multi-second import over a tree that is huge and still growing.
let bmImporting = false;

// Every bookmark URL in the tree, rebuilt on each snapshot walk — the D-11
// "starred anywhere" truth. Tri-state contract: null means the bookmark tree
// could not be read, and in that case buildAndSend must OMIT the `bookmarked`
// key from every tab element rather than emitting false — the star must never
// misreport. This Set never leaves the extension (no url crosses the wire).
let bmUrlSet = null;

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
    // Full snapshots on every (re)connect — the SW is stateless by design.
    buildAndSendAll();
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

function onBookmarkEvent() {
  if (bmImporting) return; // coalesced away until onImportEnded
  connect(); // reconnect-if-closed guard: a bookmark event also wakes the SW
  scheduleSnapshot();
}

// Bookmark events feed the same debounced snapshot. Guarded like tabGroups
// above: chrome.bookmarks may be absent (permission withheld, non-Chromium
// fork) and the worker must still load and keep reporting tabs. Registered
// synchronously at top level — MV3 dispatches events to listeners that exist
// on initial script execution only.
if (chrome.bookmarks) {
  chrome.bookmarks.onCreated.addListener(onBookmarkEvent);
  chrome.bookmarks.onRemoved.addListener(onBookmarkEvent);
  chrome.bookmarks.onChanged.addListener(onBookmarkEvent);
  chrome.bookmarks.onMoved.addListener(onBookmarkEvent);
  chrome.bookmarks.onChildrenReordered.addListener(onBookmarkEvent);
  // Chrome: "Fired when a bookmark import session is begun. Expensive
  // observers should ignore onCreated updates until onImportEnded is fired."
  chrome.bookmarks.onImportBegan.addListener(() => {
    bmImporting = true;
  });
  chrome.bookmarks.onImportEnded.addListener(() => {
    bmImporting = false;
    scheduleSnapshot(); // exactly one snapshot for the whole import
  });
}

function scheduleSnapshot() {
  clearTimeout(snapshotTimer);
  snapshotTimer = setTimeout(buildAndSendAll, DEBOUNCE_MS);
}

// ---------------------------------------------------------------------------
// The single debounce target: ONE settling gap => ONE getTree() walk => TWO
// frames. The bookmark snapshot runs FIRST so the tab snapshot that follows
// reads a freshly rebuilt bmUrlSet (D-11 star truth).
// ---------------------------------------------------------------------------

async function buildAndSendAll() {
  let snap = null;
  try {
    snap = await buildBmSnapshot();
  } catch {
    snap = null; // treat any unexpected throw as unreadable, never as empty
  }
  if (snap === null) {
    // Unreadable tree: the star state is UNKNOWN, and NO bm.state frame is
    // sent. An empty snapshot would tell the phone "you have no bookmarks",
    // which is a lie; with no frame the server's BookmarksState stays
    // connected:false and the phone shows the honest install hint.
    bmUrlSet = null;
  } else {
    bmUrlSet = snap.urls;
    if (ws && ws.readyState === WebSocket.OPEN) {
      try {
        ws.send(snap.frame);
        // Counts and lifecycle only — never a bookmark title, never a url.
        console.log(
          "[tab-bridge] bm snapshot sent:",
          snap.count,
          "nodes,",
          bytesOf(snap.frame),
          "bytes"
        );
      } catch {
        /* onclose handles it; next connect pushes a fresh snapshot */
      }
    }
    // Socket not open: skip — the connect handler pushes a snapshot on open.
  }
  await buildAndSend();
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
// Bookmark snapshot builder (protoVersion 1.6) — always a FULL getTree() walk,
// never a diff, the same stateless posture as the tab snapshot above.
//
// Returns { frame, urls, count }, or null when the tree is UNREADABLE. null is
// not "no bookmarks": the caller sends no bm.state frame at all, so the server
// keeps BookmarksState connected:false and the phone shows the honest install
// hint instead of being told the collection is empty.
// ---------------------------------------------------------------------------

// Cap a bookmark title at MAX_BM_TITLE, never leaving a lone surrogate behind.
// slice() cuts on UTF-16 code units, so an emoji straddling the cap is split in
// half; JSON.stringify then emits a bare "\ud83d", which serde_json rejects as
// a hard decode error — and bm.state ingest is STRICT, so ONE such title would
// silently cost the phone the entire bookmark tree.
function capBmTitle(s) {
  const t = (s || "").slice(0, MAX_BM_TITLE);
  const last = t.charCodeAt(t.length - 1);
  return last >= 0xd800 && last <= 0xdbff ? t.slice(0, -1) : t;
}

async function buildBmSnapshot() {
  if (!chrome.bookmarks) return null; // permission withheld / API absent
  let tree;
  try {
    tree = await chrome.bookmarks.getTree();
  } catch (e) {
    console.log("[tab-bridge] bookmarks.getTree failed:", e && e.message);
    return null;
  }

  // Breadth-first (level order), seeded from the CHILDREN of root "0" — the
  // root is never emitted as a node; its children carry parentId "0" and the
  // phone treats "0" as the virtual top level (D-08).
  //
  // The walk order is load-bearing. A pre-order (DFS) walk can spend the whole
  // budget inside the first root's first deep subtree, leaving "Other
  // bookmarks" and "Mobile bookmarks" absent entirely — a direct D-08
  // violation. BFS guarantees every root, and the top level of every root,
  // lands before any depth-2 node, so degradation prunes the deepest leaves.
  const queue = ((tree[0] && tree[0].children) || []).slice();
  const nodes = [];
  const urls = new Set();
  const dropped = new Set(); // parentIds whose children did not all fit

  while (queue.length) {
    const n = queue.shift();
    const parentId = n.parentId !== undefined ? n.parentId : "0";
    if (nodes.length >= MAX_BM_NODES) {
      dropped.add(parentId);
      continue;
    }
    // Exactly these keys and no others. NEVER a url key and NEVER an icon key
    // — the url is collected into a module-local Set that never leaves the
    // extension, and D-07 drops icons to keep the whole tree in one frame.
    const el = {
      id: n.id,
      parentId,
      title: capBmTitle(n.title),
    };
    if (n.children !== undefined) {
      el.folder = true;
      el.count = n.children.length;
    } else if (n.url) {
      urls.add(n.url); // exact-URL star truth (D-11)
    }
    if (n.unmodifiable) el.locked = true;
    nodes.push(el);
    if (n.children !== undefined) {
      for (const child of n.children) queue.push(child);
    }
  }

  // Truncation flags are applied BEFORE measuring, so the bytes counted are the
  // bytes actually sent — `truncated` costs ~18 B per flagged node plus the
  // payload key, enough to push a borderline frame back over on its own.
  // Known edge: when a dropped node's own parent was dropped too, the
  // per-folder flag lands nowhere and the snapshot-level flag is what remains
  // honest.
  const serialize = () => {
    if (dropped.size === 0) {
      return JSON.stringify({ t: "bm.state", p: { nodes } });
    }
    for (const el of nodes) {
      if (dropped.has(el.id)) el.truncated = true;
    }
    return JSON.stringify({ t: "bm.state", p: { nodes, truncated: true } });
  };

  // 56 KB serialized budget: same control shape as the icon-strip loop above,
  // but popping whole nodes off the END of the breadth-first order and
  // measuring UTF-8 BYTES, never UTF-16 code units.
  let frame = serialize();
  while (nodes.length && bytesOf(frame) > MAX_FRAME_BYTES) {
    dropped.add(nodes.pop().parentId);
    frame = serialize();
  }

  return { frame, urls, count: nodes.length };
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
