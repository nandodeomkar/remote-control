# Quick Task 260716-oi2: Browser tab list + switching via Chrome extension — Research

**Researched:** 2026-07-16
**Domain:** Chrome/Edge MV3 extension ↔ localhost WS ↔ existing tokio server relay ↔ Flutter tab list
**Confidence:** HIGH on server/Flutter architecture (verified against this codebase); MEDIUM on MV3 specifics (training knowledge, web tools unavailable this session — every MV3 claim is tagged `[ASSUMED]` with its canonical doc URL; all are verifiable in 10 minutes at the load-unpacked smoke checkpoint the plan needs anyway)

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **Tab source:** Browser extension (MV3, Chromium) — NOT UI Automation. Reliability + favicons over zero-install.
- **Distribution:** Unpacked extension folder zipped into the GitHub release; load via chrome://extensions → Developer mode → Load unpacked. README walkthrough. No Web Store.
- **Tab display:** Title + favicon per tab (favicon as small data URL from the extension). Active tab visually marked.
- **Actions:** Tap = switch. Swipe or long-press = close. No new-tab from the list (existing `newtab` macro covers it).
- **Fallback:** Browser screen keeps ALL existing key-macro controls; tab section shows an "Install the browser extension" hint (linking to README) when not connected.

### Claude's Discretion
- Extension↔server transport (dedicated localhost WS endpoint vs existing port with a role) — localhost-only binding for the extension side is a HARD security requirement.
- Protocol message naming/shape, favicon size cap, debounce/refresh strategy.
- UI layout of the tab list within the existing dark-minimal browser screen.

### Specifics
- Existing `browser` C→S macro stays untouched; tab list is additive.
- tabs switch/close are executor-bound → respect pause (drop while paused), like `browser` today (SPEC §11).
- Extension lives in a new top-level `extension/` directory with its own README.
- Protocol changes go through `protocol/SPEC.md` + fixtures + BOTH codecs (Rust `server-core`, Dart `remote_protocol`).
</user_constraints>

## Summary

The clean shape is a **second WS listener bound to `127.0.0.1` on its own port** for the extension, feeding tab state into the existing `ServerDeps` watch-channel pattern (the `apps.changed` precedent is a near-exact template), plus a small command channel back to the extension for activate/close. On the phone, the tab list is a straight clone of the Apps-screen live-list machinery (value-equal snapshot parked on ConnectionService → Notifier → rows with base64-PNG `Image.memory` icons). The MV3 extension is vanilla JS, zero dependencies; its two real risks are service-worker idle-kill (solved by a ≥20s heartbeat over the WS since Chrome 116 keeps message-active sockets alive) and favicon fetching (solved by the `favicon` permission's `_favicon/` endpoint — no `<all_urls>` host permission needed).

**Primary recommendation:** second 127.0.0.1-only listener + `tabs.*` message family (proto 1.3→1.4 additive) cloning the apps push/pull pattern end-to-end; extension fetches favicons via `_favicon/?pageUrl=…&size=32`, base64-encodes with a per-icon cap, debounces re-query 200ms.

## Standard Stack

**No new packages anywhere.** Extension = vanilla JS MV3 (no bundler, no npm — it's a zip-and-load-unpacked artifact, keep it dependency-free). Server = existing tokio/tokio-tungstenite/serde. Flutter = existing riverpod/web_socket_channel/material_symbols_icons. **Package legitimacy audit: N/A — zero installs.**

## Architecture

### Data flow

```
Chrome/Edge (MV3 service worker)
  chrome.tabs.* events ──debounce 200ms──▶ full re-query ──▶ tabs.state JSON
        │                                                        │
        ▼                                                        ▼
  ws://127.0.0.1:17779  ◀──── tabs.activate / tabs.close ── Rust server
                                                                 │ watch::channel<TabsState>
                                                                 ▼
                                              session.rs authed-gated push branch
                                                (clone of apps.changed branch)
                                                                 │
Phone ◀── tabs.changed push / tabs.list reply ──────────────────┘
Phone ─── tabs.activate {id} / tabs.close {id} ──▶ router (pause-gated) ──▶ ext cmd channel
```

### 1. Extension ↔ server transport: SECOND LISTENER (recommended, HIGH confidence)

**Bind a second `TcpListener` to `("127.0.0.1", ext_port)`** (default `17779`, `RC_EXT_PORT` env override mirroring `RC_PORT`; do NOT use `port+1` — a user-configured phone port shouldn't silently move the extension port). Run a small dedicated accept loop (new `server-core/src/transport/ext.rs` or in `server-windows` — see note below).

Why not the existing listener with a role handshake:
- `session.rs` owns a phone-specific FSM (hello → challenge → pin/auth). The extension has no PIN and no token; adding an unauthenticated "extension role" branch to the pre-auth path of the LAN-exposed listener creates exactly the impersonation surface the CONTEXT flags. A LAN device could claim the role; you'd then need a peer-addr check *inside* the shared session anyway.
- The 127.0.0.1 bind IS the auth boundary: a LAN device cannot complete a TCP handshake to a loopback-bound socket — the kernel enforces it, no application check can be bypassed. Belt-and-braces: assert `peer.ip().is_loopback()` in the accept loop (costs one line, documents intent).
- Accepted residual: any *local* process can connect and feed fake tab state or receive activate/close ids. A malicious local process already owns the machine — consistent with the v1 LAN threat model (SPEC §12). Note it in the SPEC amendment.
- Single-extension policy: newest connection wins; on a second accept, drop the previous extension session (extension reconnect/backoff makes stale sockets common after SW restarts).

**Where the ext listener lives:** tab relay has ZERO OS deps, so it can live in `server-core` (keeps compiling on CI Linux) — recommended. The composition root (`main.rs`) binds `127.0.0.1:ext_port` and passes the listener in, mirroring how `run(listener, deps)` works today.

### 2. Server state plumbing (clone the apps precedent, verified in source)

- `TabsState { connected: bool, tabs: Vec<TabInfo> }` — core-owned plain data next to `VolumeState`/`ClipState` in `transport/mod.rs`. Default = `{connected: false, tabs: []}`.
- `TabInfo { id: i64, title: String, active: bool, icon: Option<String> }` — mirrors `WindowInfo` (optional icon, serde `skip_serializing_if`, tolerant decode).
- `ServerDeps` gains `tabs: watch::Receiver<TabsState>`. The ext session task is the producer: sets `connected: true` + tab list on every extension `tabs.state` frame; resets to default on extension disconnect (CONN-07-style unconditional cleanup so the phone hint appears when Chrome closes).
- `session.rs` gains a `tabs.changed` authed-gated `select!` branch — byte-for-byte clone of the `apps.changed` branch (`borrow_and_update`, `try_send` never blocking-await, `tabs_alive` flag). **No after-auth snapshot** (apps precedent): the phone pulls via `tabs.list` on screen open.
- Phone→extension commands: `tokio::sync::mpsc::channel::<ExtCmd>` (`Activate(i64)` / `Close(i64)`). Router holds the Sender (via a new `Tabs` entry in `Executors` or directly in `SessionCtx` deps — planner's call; an executor-trait entry keeps the pause-drop wiring uniform since SPEC §11 lists executor-bound messages). The ext accept loop holds the Receiver and forwards to the currently connected extension socket; commands arriving with no extension connected are **silently dropped** (the phone already renders `connected: false`; consistent with the router's drop-silently posture for semantic no-ops).
- **Pause:** `tabs.activate`/`tabs.close` join the SPEC §11 executor-bound drop list. `tabs.list` (a read) stays allowed while paused, like `apps.list` today.

### 3. Wire protocol additions (phone ↔ server; proto 1.3 → 1.4, additive minor)

Naming consistent with `apps.*` family:

| Type | Direction | Required `p` | Optional `p` | Notes |
|------|-----------|--------------|--------------|-------|
| `tabs.list` | C→S request / S→C reply | request: `{}`; reply: `connected` (bool), `tabs` (array) | — | Pull on screen open |
| `tabs.changed` | S→C | `connected` (bool), `tabs` (array) | — | Push on any change incl. extension connect/disconnect |
| `tabs.activate` | C→S | `id` (integer) | — | Executor-bound (pause-dropped) |
| `tabs.close` | C→S | `id` (integer) | — | Executor-bound (pause-dropped) |

Tab element: `{id: integer, title: string, active: bool, icon?: string}` — `icon` is a base64 PNG **without** a `data:` prefix (matches `WindowInfo.icon` convention exactly; phone decodes with the same `base64Decode` → `Image.memory` path).

Fire-and-forget on activate/close — no new err codes. Stale ids self-heal on the next `tabs.changed` (the extension swallows the `chrome.tabs.update` rejection for a dead id). This avoids inventing an err plumbing path through the ext channel for v1.

**Contract-testing obligations (verified repo conventions):**
- `SERVER_PROTO_VERSION` `"1.3"` → `"1.4"` in `session.rs` AND the shared beacon fixture proto in lockstep (06-01 decision).
- New fixture family dir `protocol/fixtures/tabs/` + **hard-coded** test fns in BOTH harnesses — neither the Rust nor Dart fixture harness globs directories (07-02 lesson). Include: full round-trip with icon, icon-absent round-trip, missing-required-field negative (`tabs.activate` without `id`), unknown-extra-field tolerance.
- Dart: `json_codec.dart` gains `TabInfo` (tolerant `_opt` icon parse + skip-none `toJson` + value `==`, cloning `WindowInfo`), plus the four message classes.

**Extension ↔ server protocol:** reuse the same `{t, seq?, p}` envelope so the Rust side reuses serde plumbing. Types: `ext.hello {p:{extVersion}}` (ext→srv, lets the server log/gate), `tabs.state {p:{tabs:[…]}}` (ext→srv), `tabs.activate`/`tabs.close` (srv→ext, same payloads as phone-facing), `ext.ping`/`ext.pong` (keepalive, either direction). Document as a new SPEC §15 (or `protocol/EXT-SPEC.md`) — but fixtures are only mandatory for the *phone-facing* additions; the ext leg has one Rust implementation and one JS implementation with no codec harness, so spec-prose + an integration test suffices.

**Size budget (real constraint, verified):** the ext listener should reuse the 64 KB `WebSocketConfig` caps (SPEC §13 applies per-listener; tungstenite caps inbound reads). 50 tabs × (title ~200 B + icon ~1–2 KB base64 at 32 px) ≈ 60–110 KB worst case — **can exceed 64 KB**. Mitigations (extension-side, before send): cap tabs at **50** (apps precedent), cap each icon at **4 KB base64** (drop to `null` above), and if the serialized frame still exceeds ~56 KB, strip icons from the tail of the list. Do NOT build a hash-cache icon protocol for v1 — LAN bandwidth is free; the 64 KB frame cap is the only real limit.

## MV3 Extension specifics

All claims in this section are `[ASSUMED]` (training knowledge; canonical docs linked — verify at the load-unpacked smoke checkpoint).

### Service-worker lifetime + WebSocket (the #1 pitfall)

- MV3 service workers are killed after **~30 s idle**. Since **Chrome 116**, WebSocket *message activity* (either direction) resets the idle timer — an extension can hold a WS open indefinitely if a message crosses it at least every 30 s. Before 116 it could not. `[ASSUMED — https://developer.chrome.com/docs/extensions/how-to/web-platform/websockets]`
- **Keepalive pattern (Chrome's own documented sample):** while the socket is open, `setInterval(() => ws.send('ping'), 20_000)` (20 s < 30 s budget). Our design: extension sends `ext.ping` every 20 s; server replies `ext.pong`. The interval lives in the SW — fine, because as long as messages flow the SW never dies, so the interval survives. `[ASSUMED, same doc]`
- **Resurrection when the server is down:** with no WS activity the SW dies ~30 s after the last event. Recovery hooks: `chrome.runtime.onStartup`, `onInstalled`, and a **`chrome.alarms` alarm with `periodInMinutes: 0.5`** (30 s is the minimum period since Chrome 120; 60 s before that) whose handler attempts reconnect if the socket is closed. Every chrome.tabs event also wakes the SW — attach a "reconnect if closed" guard at the top of the shared event handler. `[ASSUMED — https://developer.chrome.com/docs/extensions/reference/api/alarms]`
- **Reconnect strategy:** exponential backoff 1/2/4/8/10 s cap (mirror the app's Phase-03 policy) *while the SW lives*; when it dies, the alarm/event resurrection above takes over at 30 s granularity. Net effect: worst-case ~30 s to notice the server came back. Acceptable; document in extension README.
- **State is not persistent:** the SW restarts from scratch — no module-level state survives. Keep the extension stateless: on (re)connect, do a full `chrome.tabs.query({})` and push a complete `tabs.state`. Never diff.

### Permissions / manifest

```json
{
  "manifest_version": 3,
  "name": "Remote Control — Tab Bridge",
  "version": "1.0",
  "permissions": ["tabs", "favicon", "alarms"],
  "background": { "service_worker": "background.js" }
}
```

- `tabs` permission is required to read `url`, `title`, and `favIconUrl` on Tab objects (without it they're undefined). It triggers the "Read your browsing history" install warning — fine for load-unpacked. `[ASSUMED — https://developer.chrome.com/docs/extensions/reference/api/tabs]`
- **`ws://127.0.0.1` from the SW needs NO host_permissions** — WebSocket connections are not gated by host permissions (those govern fetch/CORS), and loopback is a potentially-trustworthy origin so mixed-content rules don't block `ws:`. `[ASSUMED — verify first at smoke test; if wrong, the fix is host_permissions: ["ws://127.0.0.1/*"] — one manifest line]`
- **No content scripts, no `<all_urls>`** — the whole point of the favicon approach below.

### Favicons: use the `_favicon/` endpoint, NOT `tab.favIconUrl` fetch

Three options considered:

| Option | Verdict |
|--------|---------|
| Send `tab.favIconUrl` to the phone | ✗ Phone would fetch cross-network; URLs can be intranet-only, `chrome://` values, or empty during load |
| `fetch(tab.favIconUrl)` in the SW → base64 | ✗ Cross-origin fetch in the SW requires `<all_urls>` host permission — huge grant for icons |
| **`favicon` permission + `fetch('chrome-extension://<own-id>/_favicon/?pageUrl=' + encodeURIComponent(tab.url) + '&size=32')`** | ✓ Chrome's own favicon cache, same-origin fetch (no CORS), returns PNG (a globe placeholder when uncached) `[ASSUMED — https://developer.chrome.com/docs/extensions/how-to/ui/favicons]` |

Encode in the SW without FileReader: `arrayBuffer()` → chunked `btoa(String.fromCharCode(...))` (chunk to avoid arg-limit blowups on big buffers; at 32 px it's tiny anyway). Cache in a SW-module-level `Map<url, b64>` — fine to lose on SW restart. Apply the 4 KB per-icon cap here.

### chrome.tabs event set + debounce

Subscribe: `onCreated`, `onRemoved`, `onUpdated` (**filter**: only re-query when `changeInfo.title`, `changeInfo.favIconUrl`, or `changeInfo.status === 'complete'` — `onUpdated` fires for every load-progress tick and would storm), `onActivated`, `onMoved`, `onAttached`/`onDetached` (cross-window drags), **`onReplaced`** (prerender swaps tab IDs — without it a stale id is shown), and `chrome.windows.onFocusChanged` (active-tab marking across windows). `[ASSUMED — chrome.tabs reference]`

**Strategy: every event → trailing-edge 200 ms debounce → full `chrome.tabs.query({})` → build → send full `tabs.state`.** Never incremental diffs (SW restarts lose state; full-snapshot is idempotent). The server's watch channel is latest-value-only, so bursts coalesce again server-side for free — double protection.

**Multi-window: flatten.** Query `{}` returns all windows; order by `windowId` then `index`. Mark exactly one tab `active`: the active tab of the **last-focused normal window** (`chrome.windows.getLastFocused({windowTypes:['normal']})`). The phone never sees windowId — the extension resolves `tabs.activate` id → `chrome.tabs.update(id, {active:true})` + `chrome.tabs.get(id).windowId` → `chrome.windows.update(windowId, {focused:true})`; `tabs.close` → `chrome.tabs.remove(id)`, both with swallowed rejections.

**Tab id stability:** stable for the tab's lifetime within a browser session (except `onReplaced`); not stable across browser restarts. Fine for tap-to-act — every action round-trips through a fresh snapshot anyway.

**Edge:** loads Chrome MV3 extensions unmodified via edge://extensions → Developer mode; `chrome.*` namespace works. One README section covers both. `[ASSUMED]`

## Flutter side (verified in source, HIGH)

Clone the Apps-screen machinery — it is this exact feature shape (live pushed list, base64 icons, tap/long-press actions, auth-gated muting):

- **Snapshot flow:** `ConnectionService` parks a value-equal `TabsSnapshot` from `tabs.changed` AND the `tabs.list` reply (exact `AppsSnapshot` pattern incl. hand-rolled element-wise `==` — no package:collection, 06-03 decision) → `changes` ping → `TabsNotifier` (clone `AppsNotifier`). Screen sends `sendReliable(TabsListMsg())` on open/auth.
- **Rows:** reuse the `_AppIcon` approach verbatim (`base64Decode` → `Image.memory(gaplessPlayback: true, errorBuilder: fallback)`; fallback glyph `Symbols.public_rounded` or `Symbols.language_rounded` muted). Row chrome: `kSurface` fill, `kHairline` border, radius 16, ≥56 px — byte-match `_WindowRow`. Active tab: `kAccent` border (matches the armed-chip language used elsewhere).
- **Actions:** tap-down → `sendReliable(TabsActivateMsg(id))` + `hapticTick()` (house pattern: act on press-down). Close: `Dismissible` swipe AND a long-press → both fire `TabsCloseMsg(id)`. CONTEXT says "swipe or long-press" — implement swipe as primary, long-press as the discoverable alternative (the Apps screen already uses long-press = pin, so per-screen long-press meanings differ; acceptable, but note it in the plan).
- **Layout:** tab section ABOVE the macro grid inside the existing `SingleChildScrollView` (the macros are reachable by scroll; tabs are the new primary content). Section header "Tabs" 16/600 `kText`, apps-screen style. Not-connected state: hint card (`kSurface`, muted copy, link-style "See the README" — `url_launcher` is NOT currently a dependency, so render the URL as selectable text or plain copy rather than adding a package).
- **Gating:** `enabled = status.chip == ChipStatus.connected` for actions (existing pattern); the extension hint renders whenever `snapshot.connected == false` regardless of phone-auth state.

## Don't Hand-Roll

| Problem | Don't build | Use instead |
|---------|-------------|-------------|
| Favicon fetching/CORS | Per-site fetch + `<all_urls>` | `favicon` permission `_favicon/` endpoint |
| SW lifetime management | Offscreen documents / nagging notifications | Chrome-116 WS-message keepalive + alarms resurrection |
| Tab diffing | Incremental add/remove/update protocol | Full-snapshot `tabs.state` + watch-channel coalescing |
| Icon dedup/caching protocol | hash + fetch-by-hash messages | Just resend; 64 KB budget managed by caps |

## Common Pitfalls

1. **SW idle-kill mid-session** — no keepalive → tab list silently freezes after 30 s. Prevention: 20 s `ext.ping` + alarms resurrection; verify at smoke test by watching the SW stay alive >5 min in chrome://serviceworker-internals.
2. **64 KB frame overflow** — many tabs × icons exceeds the SPEC §13 cap and tungstenite kills the read. Prevention: 50-tab cap + 4 KB icon cap + strip-icons-over-budget, enforced extension-side; add a Rust integration test feeding an oversized frame and asserting the ext session dies without touching the phone session.
3. **`onUpdated` event storm** — fires per load-progress tick; unfiltered → re-query dozens of times per page load. Prevention: changeInfo filter + 200 ms trailing debounce.
4. **Extension disconnect not surfacing** — phone shows a stale tab list forever. Prevention: ext session cleanup unconditionally resets the watch to `{connected:false, tabs:[]}` (CONN-07 discipline), which pushes `tabs.changed` to the phone.
5. **`onReplaced` missed** — prerendered navigations swap tab ids; taps then hit dead ids. Prevention: subscribe `onReplaced`; fire-and-forget semantics make the failure benign anyway.
6. **Pause bypass** — `tabs.activate`/`tabs.close` must join the SPEC §11 executor-bound drop list in the router, not just the ext channel. Test: paused session drops both; `tabs.list` still answers.
7. **Fixture harness doesn't glob** — new `tabs/` fixture family needs hand-added test fns in BOTH the Rust and Dart harnesses or the fixtures silently never run (07-02 lesson).
8. **Privacy backstop** — tab titles are as sensitive as window titles: `tabs.changed` push MUST be authed-gated (`ctx.auth_state == Authed`), cloning the T-06-01 guard; never log titles/urls server-side (T-01-31 discipline — extension frames contain browsing data).

## Assumptions Log

| # | Claim | Risk if wrong |
|---|-------|---------------|
| A1 | Chrome ≥116 WS activity extends SW life; 20 s heartbeat suffices | Keepalive fails → fall back to alarms-driven reconnect every 30 s (worse UX, still works) |
| A2 | `ws://127.0.0.1` from SW needs no host_permissions | One-line manifest fix (`host_permissions`) |
| A3 | `favicon` permission `_favicon/` endpoint fetchable from SW, returns PNG | Fall back to sending no icons (title-only rows) or favIconUrl fetch with broader permission — user decision |
| A4 | `tabs` permission exposes `title`/`favIconUrl`/`url` on queried tabs | Core to the feature; extremely stable API, but verify first at smoke test |
| A5 | `chrome.alarms` min period 30 s (Chrome ≥120) | Use 60 s — slower resurrection only |
| A6 | Edge loads unpacked Chrome MV3 extensions with working `chrome.*` | Edge-specific README note; feature still ships for Chrome |

All six are verified in one sitting at the first load-unpacked smoke test — the plan should front-load a tiny walking-skeleton extension (connect + log tabs) as its first checkpoint before any protocol/fixture work depends on the answers.

## Open Questions

1. **Ext port default** — `17779` proposed (beacon uses its own default, WS 17777). Planner should confirm no collision with `DEFAULT_BEACON_PORT` (check `beacon.rs` constant during planning).
2. **Where router gets the ext command sender** — new `Tabs` executor-trait entry (uniform pause wiring) vs a raw sender in `SessionCtx`. Recommend the executor-trait entry; planner decides after reading `router.rs` dispatch arms.
3. **`tabs.list` while extension never connected** — reply `{connected:false, tabs:[]}` immediately (recommended; gives the phone its hint state on screen open with zero extra machinery).

## Sources

- **Codebase (HIGH, verified this session):** `server/server-core/src/transport/{mod,listener,session}.rs`, `server/server-windows/src/main.rs`, `server/server-core/src/dispatch/router.rs`, `app/remote_control/lib/browser/browser_screen.dart`, `app/remote_control/lib/apps/apps_screen.dart`, `protocol/SPEC.md`, `.planning/STATE.md` decisions log.
- **MV3 (ASSUMED, training — canonical docs for verification):** developer.chrome.com WebSockets-in-SW guide, chrome.tabs / chrome.alarms references, favicons how-to. Web tools (WebSearch/WebFetch) were unavailable this session; claims are individually tagged above.
