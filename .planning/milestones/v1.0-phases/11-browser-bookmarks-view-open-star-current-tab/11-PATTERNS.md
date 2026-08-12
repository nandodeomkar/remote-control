# Phase 11: Browser bookmarks — view, open, star current tab - Pattern Map

**Mapped:** 2026-07-29
**Files analyzed:** 19 new/modified files
**Analogs found:** 18 / 19 (1 partial — see § No Analog Found)

All file:line citations below were opened and verified during this mapping pass.

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `extension/manifest.json` | config | — | itself (permissions array) | exact |
| `extension/background.js` (bookmark snapshot + `bm.*` handlers) | service (MV3 SW) | event-driven → push snapshot | `background.js:204-308` (`scheduleSnapshot`/`buildAndSend`) | exact |
| `extension/README.md` | doc | — | itself | exact |
| `server/server-core/src/executors/mod.rs` (`BmNode`, `BookmarksState`, `Bookmarks` trait, `TabInfo.bookmarked`) | model + trait | CRUD/read | `executors/mod.rs:66-117` (`TabInfo`/`GroupInfo`/`TabsState`) | exact |
| `server/server-core/src/codec/json.rs` (`bm.*` payloads + `Msg` variants) | codec | transform | `codec/json.rs:220-259, 337-340, 392-395, 463-466` (tabs family) | exact |
| `server/server-core/src/transport/ext.rs` (`ExtCmd` variants, `bm_tx`, `"bm.state"` arm, both-watch reset) | transport/relay | streaming push + command relay | `ext.rs:48-90, 110-240` (whole file is the analog) | exact |
| `server/server-core/src/transport/session.rs` (`bm.changed` push arm, `SERVER_PROTO_VERSION`) | transport/session | pub-sub push | `session.rs:324-346` (tabs arm), `:674-686` (`tabs_changed_frame`) | exact |
| `server/server-core/src/transport/mod.rs` (`ServerDeps.bookmarks`) | wiring | — | `mod.rs:22` re-export + `session.rs:103` receiver param | exact |
| `server/server-core/src/dispatch/router.rs` (`bm.list` read, 4 executor-bound arms) | router | request-response + fire-and-forget | `router.rs:234-256`, `:303-324` (`is_executor_bound`) | exact |
| `server/server-windows/src/main.rs` (bm watch channel wiring) | composition root | — | existing tabs watch/cmd channel wiring in the same file | role-match |
| `app/packages/remote_protocol/lib/src/json_codec.dart` (`BmNode`, `_bmList`, `TabInfo.bookmarked`) | codec | transform | `json_codec.dart:112-215` (`_tabList`/`_groupList`/`TabInfo`) | exact |
| `app/remote_control/lib/net/connection_service.dart` (`BookmarksSnapshot` + parking arms) | service | pub-sub | `connection_service.dart:163-190` (class), `:309`, `:412`, `:660-680` (arms) | exact |
| `app/remote_control/lib/browser/bookmarks_store.dart` **(NEW)** | store (Riverpod notifier) | event-driven view + commands | `app/remote_control/lib/browser/tabs_store.dart` (whole file, 110 lines) | exact |
| `app/remote_control/lib/browser/tabs_store.dart` (optimistic star overlay) | store | event-driven | itself (`:66-106`) | exact |
| `app/remote_control/lib/browser/browser_screen.dart` (segment control, `_BookmarksSection`, star slot, confirm dialogs) | component | request-response + local nav | `settings_screen.dart:409-485` (segment), `browser_screen.dart:738-818` (`_TabRow`), `settings_screen.dart:271-301` (confirm) | mixed — see below |
| `protocol/SPEC.md` (§2/§7/§11/§15) | spec/doc | — | existing tabs rows in the same sections | exact |
| `protocol/fixtures/bookmarks/*` **(NEW family)** | test fixture | — | `protocol/fixtures/tabs/` (8 files, listed below) | exact |
| `server/server-core/tests/fixtures.rs` + `app/packages/remote_protocol/test/fixture_test.dart` | test harness registration | — | `fixtures.rs:177-184`, `fixture_test.dart:195-202` | exact |
| `app/remote_control/test/browser/browser_screen_test.dart` (star gesture-isolation, segment, vocabulary guard) | test | — | `browser_screen_test.dart:30, 195-209` | exact |
| `server/server-core/tests/ext_relay.rs` (bm.state watch, both-watch reset) | test | — | `ext_relay.rs:94-146` | exact |

---

## Pattern Assignments

### `app/remote_control/lib/browser/bookmarks_store.dart` (NEW — store, event-driven)

**Analog:** `app/remote_control/lib/browser/tabs_store.dart` (110 lines, read in full — it is itself an `AppsNotifier` clone, so the shape is twice-proven).

**Value-equal view state** (`tabs_store.dart:24-61`) — hand-rolled element-wise `==`, **no `package:collection`** (06-03 rule):

```dart
// Source: app/remote_control/lib/browser/tabs_store.dart:43-60
@override
bool operator ==(Object other) {
  if (other is! TabsViewState) return false;
  if (other.connected != connected) return false;
  if (other.tabs.length != tabs.length) return false;
  for (var i = 0; i < tabs.length; i++) {
    if (other.tabs[i] != tabs[i]) return false;
  }
  ...
  return true;
}

@override
int get hashCode =>
    Object.hash(connected, Object.hashAll(tabs), Object.hashAll(groups));
```

**Notifier lifecycle + re-snapshot + commands** (`tabs_store.dart:66-110`) — copy verbatim, substituting `bookmarksSnapshot` for `tabsSnapshot`:

```dart
// Source: app/remote_control/lib/browser/tabs_store.dart:66-110
class TabsNotifier extends Notifier<TabsViewState> {
  StreamSubscription<void>? _sub;
  late final ConnectionService _service;

  @override
  TabsViewState build() {
    _service = ref.watch(connectionServiceProvider);
    _sub?.cancel();
    _sub = _service.changes.listen((_) => _onChange());
    ref.onDispose(() { _sub?.cancel(); _sub = null; });
    return _view();
  }

  void _onChange() { state = _view(); }

  TabsViewState _view() {
    final snapshot = _service.tabsSnapshot;
    return TabsViewState(
      connected: snapshot?.connected ?? false,
      tabs: snapshot?.tabs ?? const [],
      groups: snapshot?.groups ?? const [],
    );
  }

  void primeList() => _service.sendReliable(const TabsListMsg());
  void activate(int id) => _service.sendReliable(TabsActivateMsg(id: id));
  void close(int id) => _service.sendReliable(TabsCloseMsg(id: id));
}

final tabsStateProvider =
    NotifierProvider<TabsNotifier, TabsViewState>(TabsNotifier.new);
```

**Deltas the planner owns (no analog — new to this store):** `currentFolderId` + back stack, the `childrenByParent` index built in `_view()`, stale-folder healing, and inclusion of nav state in `==`/`hashCode`. The optimistic star overlay belongs on `TabsNotifier` (the star renders on a tab row), not here.

**Prime trigger differs from the analog:** `TabsNotifier.primeList()` is called from `initState` today; `BookmarksNotifier.primeList()` must be called from the segment `onSelect`, guarded by a `bool _bmPrimed` (D-03).

---

### `app/remote_control/lib/net/connection_service.dart` (service, pub-sub)

**Analog:** the `TabsSnapshot` parking, same file — four sites, all verified:

| Site | Line | What |
|------|------|------|
| Snapshot class | `:163-190` | `TabsSnapshot` with element-wise `==` |
| Field | `:309` | `TabsSnapshot? _tabsSnapshot;` |
| Getter | `:412` | `TabsSnapshot? get tabsSnapshot => _tabsSnapshot;` |
| Push arm | `:660-671` | `TabsChangedMsg` → park + `_notify()` |
| Reply arm | `:672-680` | `TabsListMsg` → park with `?? false` / `?? const []` defaults |

```dart
// Source: app/remote_control/lib/net/connection_service.dart:660-680
if (msg is TabsChangedMsg) {
  _tabsSnapshot = TabsSnapshot(
    connected: msg.connected, tabs: msg.tabs, groups: msg.groups ?? const [],
  );
  _notify();
  return;
}
if (msg is TabsListMsg) {
  // A request has neither field; a reply always carries both —
  // default to the never-connected hint shape. No payload logging.
  _tabsSnapshot = TabsSnapshot(
    connected: msg.connected ?? false, tabs: msg.tabs ?? const [], ...
  );
  _notify();
  return;
}
```

**Copy the "no payload logging" comment discipline** — both arms carry it explicitly (SPEC §12).

---

### `extension/background.js` (service worker, event-driven → push snapshot)

**Analog:** the tab snapshot machinery in the same file.

**Top-level listener registration + reconnect guard** (`background.js:172-202`) — bookmark listeners clone `onTabEvent`, and MV3 requires global scope:

```js
// Source: extension/background.js:172-182
function onTabEvent() {
  connect(); // reconnect-if-closed guard: every tabs event wakes the SW
  scheduleSnapshot();
}
chrome.tabs.onCreated.addListener(onTabEvent);
chrome.tabs.onRemoved.addListener(onTabEvent);
...
```

Note the **optional-API guard** at `:197-202` (`if (chrome.tabGroups) {...}`) — the same defensive shape applies if `chrome.bookmarks` is ever absent.

**Debounce** (`:204-207`) — reuse as-is:

```js
// Source: extension/background.js:204-207
function scheduleSnapshot() {
  clearTimeout(snapshotTimer);
  snapshotTimer = setTimeout(buildAndSend, DEBOUNCE_MS);
}
```

**Element build loop with skip-when-absent optional keys** (`:242-259`) — this is where `el.bookmarked` is added:

```js
// Source: extension/background.js:243-259
for (const tab of tabs) {
  // NEVER include tab.url in the payload — titles are enough (privacy).
  const el = { id: tab.id, title: tab.title !== undefined ? tab.title : "", active: tab.id === activeId };
  // groupId only when grouped — never emit -1 (TAB_GROUP_ID_NONE), never null.
  if (tab.groupId !== undefined && tab.groupId !== GROUP_ID_NONE) el.groupId = tab.groupId;
  const icon = tab.url ? await favicon(tab.url) : null;
  if (icon !== null && icon.length <= MAX_ICON_B64) el.icon = icon;
  els.push(el);
}
```

**Size-budget loop — the control shape to clone, and the bug to fix** (`:284-291`):

```js
// Source: extension/background.js:284-291
// 56 KB serialized budget: strip icons from the END of the list until under.
let frame = JSON.stringify({ t: "tabs.state", p: { tabs: els, groups } });
for (let i = els.length - 1; i >= 0 && frame.length > MAX_FRAME_BYTES; i--) {
  if (els[i].icon !== undefined) {
    delete els[i].icon;
    frame = JSON.stringify({ t: "tabs.state", p: { tabs: els, groups } });
  }
}
```

`frame.length` is a UTF-16 code-unit count, **not** bytes (RESEARCH Pitfall 1, confirmed at this line). The bookmark loop must measure `new TextEncoder().encode(frame).length`; fixing this loop the same way is in-scope hardening.

**Command handler + fire-and-forget catch** (`:88-104`) — `bm.open`/`bm.star`/`bm.unstar`/`bm.remove` clone this switch arm shape:

```js
// Source: extension/background.js:89-99
case "tabs.activate":
  // Stale ids self-heal on the next snapshot; swallow rejections.
  chrome.tabs.update(p.id, { active: true })
    .then(() => chrome.tabs.get(p.id))
    .then((tab) => chrome.windows.update(tab.windowId, { focused: true }))
    .catch(() => {});
  break;
case "tabs.close":
  chrome.tabs.remove(p.id).catch(() => {});
  break;
```

**Send + counts-only logging** (`:293-307`) — clone verbatim; log node counts, never titles/URLs (privacy header at `:8-9`).

**Caps block to extend** (`:16-21`): `MAX_TABS`/`MAX_ICON_B64`/`MAX_FRAME_BYTES`/`MAX_GROUPS`/`MAX_GROUP_TITLE`, each carrying the "must stay in sync with protocol/SPEC.md §15" comment. Add `MAX_BM_NODES` / `MAX_BM_TITLE` here with the same comment.

---

### `server/server-core/src/executors/mod.rs` (model)

**Analog:** `TabInfo` / `GroupInfo` / `TabsState`, `:66-117`.

**Additive optional field — the exact three-part shape** (`:71-78`):

```rust
// Source: server/server-core/src/executors/mod.rs:71-78
#[serde(default, skip_serializing_if = "Option::is_none")]
pub icon: Option<String>,
/// Owning tab-group id (protoVersion 1.5, quick 260716-sme). Absent =
/// ungrouped — the WindowInfo `icon`/`path` skip-when-absent convention:
/// never emitted as null, and never emitted as `-1`.
#[serde(rename = "groupId", default, skip_serializing_if = "Option::is_none")]
pub group_id: Option<i64>,
```

`WindowInfo.icon/path` at `:50-53` is the 1.2 precedent for the same shape. `TabEl.bookmarked` copies it byte-for-byte — **but its doc comment must state that `None` means UNKNOWN, not false** (the one semantic divergence; RESEARCH §Star State).

**Wire-required-field discipline** — `GroupInfo` (`:91-97`) has all four fields non-`Option`, documented at `:83-84` as "a missing field is a hard decode error". `BmNode`'s `id`/`parentId`/`title` follow `GroupInfo`, not `TabInfo`.

**Default-is-the-never-connected-shape** (`:105-117`):

```rust
// Source: server/server-core/src/executors/mod.rs:108-117
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TabsState {
    pub connected: bool,
    pub tabs: Vec<TabInfo>,
    pub groups: Vec<GroupInfo>,
}
```

`BookmarksState` clones this — `Default` = `{connected: false, nodes: []}`, which is what the watch resets to on ext session death.

---

### `server/server-core/src/transport/ext.rs` (transport/relay, streaming + command relay)

**Analog:** the whole file (241 lines, read in full).

**Command enum** (`:48-56`) — add `BmOpen(String)` / `BmStar(i64)` / `BmUnstar(i64)` / `BmRemove(String)`. Note the existing `#[derive(..., Copy, ...)]` — **a `String` payload breaks `Copy`**; the derive list must drop `Copy` (an easy-to-miss compile break):

```rust
// Source: server/server-core/src/transport/ext.rs:50-56
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExtCmd {
    Activate(i64),
    Close(i64),
}
```

**Relay struct pairing a watch receiver with a cmd sender** (`:62-90`) — `BookmarksRelay` clones it:

```rust
// Source: server/server-core/src/transport/ext.rs:62-90
pub struct TabsRelay { state: watch::Receiver<TabsState>, cmd: mpsc::Sender<ExtCmd> }
impl Tabs for TabsRelay {
    fn list(&self) -> TabsState { self.state.borrow().clone() }
    /// Fire-and-forget from the sync trait: `try_send` — a full or closed
    /// channel is silently dropped.
    fn activate(&self, id: i64) { let _ = self.cmd.try_send(ExtCmd::Activate(id)); }
    fn close(&self, id: i64) { let _ = self.cmd.try_send(ExtCmd::Close(id)); }
}
```

**Watch-reset sites — VERIFIED count is THREE, not four.** RESEARCH Pitfall 2 says four; the live code has exactly three `tabs_tx.send(TabsState::default())` calls:

| Site | Line | Trigger |
|------|------|---------|
| 1 | `ext.rs:165-166` | cmd send failure |
| 2 | `ext.rs:178-179` | pong send failure |
| 3 | `ext.rs:191-192` | stream end / error (incl. 64 KB cap kill) |

```rust
// Source: server/server-core/src/transport/ext.rs:190-193
None | Some(Err(_)) => {
    session = None;
    let _ = tabs_tx.send(TabsState::default());
}
```

Every one of the three must also reset `bm_tx`. Extract a helper so a future fourth watch cannot regress.

**Note the deliberate non-reset at `:144-147`** (newest-wins replace: "No watch reset on replace — the new extension pushes a full tabs.state within moments"). Bookmarks must match this too, or a reconnect blanks the tree.

**The `"bm.state"` arm clones the `"tabs.state"` arm** (`:209-231`) — note the two different tolerance levels:

```rust
// Source: server/server-core/src/transport/ext.rs:210-231
"tabs.state" => {
    let raw = frame.p.get("tabs").cloned().unwrap_or(Value::Null);
    // Tolerant: a parse failure ignores the frame entirely.
    if let Ok(mut tabs) = serde_json::from_value::<Vec<TabInfo>>(raw) {
        tabs.truncate(MAX_EXT_TABS);        // server-side belt (SPEC §15)
        let mut groups = frame.p.get("groups").cloned()
            .map(serde_json::from_value::<Vec<GroupInfo>>)
            .and_then(Result::ok).unwrap_or_default();
        groups.truncate(MAX_EXT_GROUPS);
        let _ = tabs_tx.send(TabsState { connected: true, tabs, groups });
    }
    None
}
```

`nodes` takes the **strict** posture (parse failure ⇒ ignore the whole frame), like `tabs`. `MAX_EXT_BM_NODES = 500` is the belt const, following `MAX_EXT_TABS` at `:39-42` and `MAX_EXT_GROUPS` at `:44-46` — each with its "server-side belt for the extension-side cap (SPEC §15)" doc comment.

---

### `server/server-core/src/transport/session.rs` (transport, pub-sub push)

**Analog:** the tabs push arm (`:324-346`) and its encoder (`:674-686`).

```rust
// Source: server/server-core/src/transport/session.rs:331-345
changed = tabs.changed(), if tabs_alive && ctx.auth_state == AuthState::Authed => {
    match changed {
        Ok(()) => {
            // TabsState owns a Vec (not Copy): clone the borrowed state.
            let state = tabs.borrow_and_update().clone();
            match tx.try_send(tabs_changed_frame(state)) { /* … */ }
        }
        Err(_) => tabs_alive = false,
    }
}
```

Three details to carry: the `_alive` flag pattern (declared `:149`, "producer dropped" discipline at `:147-149`), the `AuthState::Authed` guard, and the receiver threaded as a `run_session` param (`:103`).

**Version machinery:** `SERVER_PROTO_VERSION` lives at `session.rs:60` (verified — **not** in `codec/json.rs` as CONTEXT.md states), re-exported at `transport/mod.rs:22`, and the in-file changelog doc block at `:54-58` documents each minor addition. Append a 1.6 line there.

**No after-auth snapshot** — the comment at `:324-330` says the client pulls via `tabs.list` and "this branch is the ONLY tabs push site". Do not add an after-auth `bm.changed`.

---

### `server/server-core/src/dispatch/router.rs` (router)

**Analog:** the tabs arms.

**Read arm (pause-exempt)** — `router.rs:234-247`:

```rust
// Source: server/server-core/src/dispatch/router.rs:234-241
// tabs.list is a READ (SPEC §11 pause exemption, like apps.list):
Msg::TabsList(_) => {
    let state = exec.tabs.list();
    vec![Msg::TabsList(TabsListPayload { /* connected/tabs/groups */ })]
}
```

**Executor-bound arms (fire-and-forget, no reply)** — `:248-256`:

```rust
// Source: server/server-core/src/dispatch/router.rs:248-256
// the next tabs.changed push. Both are executor-bound (pause gate).
Msg::TabsActivate(p) => { exec.tabs.activate(p.id); vec![] }
Msg::TabsClose(p) => { exec.tabs.close(p.id); vec![] }
```

**Pause gate** — `:73-75` (`if paused && is_executor_bound(&decoded.msg)`) and the classifier at `:303-324`:

```rust
// Source: server/server-core/src/dispatch/router.rs:303-324
/// and the read-only queries (`apps.list`, `clip.get`, `tabs.list`) are …
fn is_executor_bound(msg: &Msg) -> bool {
    matches!(msg, … | Msg::TabsActivate(_) | Msg::TabsClose(_))
}
```

`bm.open`/`bm.star`/`bm.unstar`/`bm.remove` join this `matches!` list; `bm.list` joins the read group.

**Router unit-test shapes to clone** (same file, in-module tests): `:591-623` (read answers while paused, asserts `log.calls().is_empty()`), `:626-655` (fire-and-forget records the call and returns no reply). The `browser_macro` table is at `:353` with its coverage test at `:1055`.

---

### `app/packages/remote_protocol/lib/src/json_codec.dart` (codec, transform)

**Analog:** `_tabList` / `_groupList` / `TabInfo`, `:112-215`.

**Element-list parser — `_bmList` clones `_groupList`'s strict shape** (required fields via `_req`, optional via `_opt`):

```dart
// Source: app/packages/remote_protocol/lib/src/json_codec.dart:117-131
List<TabInfo> _tabList(Object? v, String key) {
  if (v is! List) throw FormatException('field $key must be an array');
  return v.map((e) {
    if (e is! Map<String, dynamic>) {
      throw FormatException('entries of $key must be objects');
    }
    return TabInfo(
      id: _req<int>(e, 'id'),
      title: _req<String>(e, 'title'),
      active: _req<bool>(e, 'active'),
      icon: _opt<String>(e, 'icon'),
      groupId: _opt<int>(e, 'groupId'),
    );
  }).toList();
}
```

**Canonical encode — `if (x != null)` mirrors Rust's `skip_serializing_if`** (`:186-195`):

```dart
// Source: app/packages/remote_protocol/lib/src/json_codec.dart:186-195
/// Canonical JSON form: `{id, title, active}` plus `icon`/`groupId` only
/// when non-null (mirrors the Rust `skip_serializing_if = "Option::is_none"`).
Map<String, Object?> toJson() => {
      'id': id, 'title': title, 'active': active,
      if (icon != null) 'icon': icon,
      if (groupId != null) 'groupId': groupId,
    };
```

Plus hand-rolled `==`/`hashCode` at `:197-206` — every new field must be added to **three** places (parse, `toJson`, `==`/`hashCode`), which is the drift risk the fixtures catch.

---

### `app/remote_control/lib/browser/browser_screen.dart` (component)

Four distinct sub-patterns, each with its own analog.

**(a) Segment control — analog `settings_screen.dart:409-485`** (`_ScrollDirectionSegment` + `_SegmentButton`, both read in full):

```dart
// Source: app/remote_control/lib/settings/settings_screen.dart:422-441
Row(children: [
  Expanded(child: _SegmentButton(label: kScrollNaturalLabel, selected: !reversed, onTap: () => onChanged(false))),
  const SizedBox(width: 8),
  Expanded(child: _SegmentButton(label: kScrollReversedLabel, selected: reversed, onTap: () => onChanged(true))),
]);

// Source: app/remote_control/lib/settings/settings_screen.dart:458-484
final color = selected ? kAccent : kMuted;
return Material(
  color: kBg,
  borderRadius: BorderRadius.circular(8),
  child: InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(8),
    child: Container(
      constraints: const BoxConstraints(minHeight: 40),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        border: Border.all(color: selected ? kAccent : kHairline),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: color)),
    ),
  ),
);
```

The "navigation, not a send — no `enabled` parameter" rule comes from `KeyboardTabBar`'s doc block, `key_pads.dart:186-192`:

```dart
// Source: app/remote_control/lib/keyboard/key_pads.dart:186-192
/// # Always interactive — there is deliberately no `enabled` parameter
///
/// Tabs are NAVIGATION, not sends: they must work offline and unauthed, so
/// the user can still reach a pad while the socket is down. … Do not add a
/// gated variant.
```

`KeyboardTabBar` also documents the effect-ownership split (`:194-199`): the bar reports the tap, the **screen** runs `hapticTick()`. Follow that.

**(b) Layout restructure — analog is `browser_screen.dart:329-368` itself** (verified current tree):

```dart
// Source: app/remote_control/lib/browser/browser_screen.dart:329-361
body: SafeArea(child: Column(children: [
  ReconnectingBannerSlot(visible: status.chip == ChipStatus.reconnecting, onRetry: _service.retryNow),
  Expanded(child: SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(16, 32, 16, 16),   // md edge, xl top
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const _SectionHeader('Tabs'),          // ← REPLACED by the segment control
      const SizedBox(height: 8),
      _TabsSection(tabs: tabs, enabled: authed, onActivate: _onActivateTab, onClose: _onCloseTab),
      const SizedBox(height: 24),
      BrowserMacroGrid(onAction: _onAction, enabled: authed),   // ← moves OUT of the scroll
    ]),
  )),
])),
```

`enabled: authed` where `authed = status.chip == ChipStatus.connected` (`:306-307`) is the gating source for every new control.

**(c) Star slot + row chrome — analog `_TabRow`, `:738-818`:**

```dart
// Source: app/remote_control/lib/browser/browser_screen.dart:785-812
child: InkWell(
  borderRadius: BorderRadius.circular(widget.radius),
  onTap: widget.enabled ? () {} : null,
  onTapDown: widget.enabled ? (_) => _fire() : null,
  onLongPress: widget.enabled ? () => widget.onClose(widget.tab.id) : null,
  child: ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 56),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        _TabIcon(iconB64: widget.tab.icon, size: 24),
        const SizedBox(width: 8),
        Expanded(child: Text(widget.tab.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: …)),
        // ← star slot inserts HERE, after the Expanded
      ]),
    ),
  ),
)
```

Press-flash FSM (`:766-772`) — copy for bookmark/folder rows:

```dart
// Source: app/remote_control/lib/browser/browser_screen.dart:766-772
void _fire() {
  widget.onActivate(widget.tab.id);
  setState(() => _pressed = true);
  Future.delayed(const Duration(milliseconds: 100), () {
    if (mounted) setState(() => _pressed = false);
  });
}
```

Color resolution (`:776-783`): `borderColor = (_pressed || active) ? kAccent : kHairline`; `titleColor = !enabled ? kMuted : _pressed ? kAccent : kText`.

**(d) Body-state selection + install hint + muted one-liner — analog `_TabsSection.build` (`:447-461`) and `_InstallHintCard` (`:555-599`):**

```dart
// Source: app/remote_control/lib/browser/browser_screen.dart:447-461
if (!tabs.connected) return const _InstallHintCard();
if (tabs.tabs.isEmpty) {
  return const Align(
    alignment: Alignment.centerLeft,
    child: Text('No tabs open.',
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: kMuted)),
  );
}
```

`_InstallHintCard` is a **private const widget with no parameters** (`:558-599`) — the Bookmarks segment reuses it directly (UI-SPEC: do not fork a bookmarks variant).

**Trailing `· N` count — analog `_GroupHeader`, `:703-711`** (separate `Text`, never concatenated):

```dart
// Source: app/remote_control/lib/browser/browser_screen.dart:703-711
const SizedBox(width: 6),
Text('· $count',
    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: kMuted)),
```

---

### Confirm dialog (`browser_screen.dart` or a sibling file)

**Analog: `settings_screen.dart:271-301` (`_confirmRevoke`)** — this is the correct-weight house destructive gate.

```dart
// Source: app/remote_control/lib/settings/settings_screen.dart:272-302
final confirmed = await showDialog<bool>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    backgroundColor: kSurface,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    title: const Text(kRevokeConfirmTitle,
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: kText)),
    content: const Text(kRevokeConfirmBody, style: _rowSubtitle),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(dialogContext).pop(false),
        child: const Text(kRevokeConfirmCancel, style: TextStyle(color: kMuted)),
      ),
      FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: kError, foregroundColor: kBg,
          minimumSize: const Size(0, 48),
        ),
        onPressed: () => Navigator.of(dialogContext).pop(true),
        child: const Text(kRevokeConfirmConfirm),
      ),
    ],
  ),
);
if (confirmed != true) return;
```

Note the named-const copy convention (`kRevokeConfirmTitle`/`Body`/`Cancel`/`Confirm`) — UI-SPEC's Copywriting Contract requires the same for all three phase-11 dialogs.

**Weight-mismatch analogs, cited and rejected:** `ConfirmTrackFsm` **exists** at `app/remote_control/lib/power/confirm_track_fsm.dart:98` (slide-to-confirm). Both it and the Power red-countdown dialog are calibrated for irreversible machine state; UI-SPEC explicitly selects the revoke dialog instead. Do not use them.

---

### Vocabulary drift guard test

**Analog:** `app/remote_control/test/browser/browser_screen_test.dart:30` (`const Set<String> kRouterBrowserVocabulary`) + the assertion at `:195-209`:

```dart
// Source: app/remote_control/test/browser/browser_screen_test.dart:195-209
test('kBrowserActions is exactly the 7-action router vocabulary', () {
  expect(kBrowserActions, hasLength(7));
  expect(
    kBrowserActions.map((s) => s.action).toSet(),
    kRouterBrowserVocabulary,
    reason: 'action strings must byte-match router.rs browser_macro — '
        'anything else is silently dropped by the server',
  );
  expect(kBrowserActions.map((s) => s.action).toSet(), hasLength(7));
  ...
});
```

The shape: a hand-maintained mirror const **in the test file**, plus a set-equality assertion with a `reason` naming the server file. The `CLIENT_KEY_CODES` sibling precedent uses the same posture across four files (`key_pads_test.dart:6`, `key_rows_test.dart:53-65`, `modifier_fsm_test.dart:104`, source comment `key_rows.dart:31`). Any new client-side `bm.*` vocabulary needs this gate.

---

### Fixture family registration (BOTH harnesses — neither globs)

**Rust — `server/server-core/tests/fixtures.rs:177-184`:**

```rust
// Source: server/server-core/tests/fixtures.rs:176-184
#[test]
fn codec_fixtures_tabs() {
    // protocol 1.4 (BROW-01): the tabs.* family — … Hard-registered:
    // neither harness globs directories (07-02 lesson).
    run_json_family("tabs");
}
```

**Dart — `app/packages/remote_protocol/test/fixture_test.dart:195-202`:**

```dart
// Source: app/packages/remote_protocol/test/fixture_test.dart:195-202
// protocol 1.4 (BROW-01): the additive tabs.* family. …
group('tabs fixtures', () {
  runJsonFamily('tabs');
});
```

**Existing `protocol/fixtures/tabs/` contents** (verified on disk — the file-naming and coverage template for `protocol/fixtures/bookmarks/`):
`01-tabs-changed-with-icon.json`, `02-tabs-list-reply.json`, `03-tabs-activate.json`, `04-tabs-activate-missing-id.json`, `05-tabs-close.json`, `06-tabs-changed-with-groups.json`, `07-tabs-list-reply-with-groups.json`, `08-tabs-group-missing-color.json`.

A `09-tabs-changed-bookmarked.json` added to this directory needs **no** harness edit — both harnesses enumerate files within a registered family.

---

### `server/server-core/tests/ext_relay.rs` (test)

**Analog:** the existing ext-leg contract tests (this file + SPEC §15 prose ARE the contract — there is no codec harness for the ext leg).

Helper shapes at `:40-101` (`spawn_relay`, `connect_ext`, `send_json`, `recv_json`, `wait_watch`, `tabs_state_frame`). Tests to clone for bookmarks:

| Existing test | Line | Bookmarks equivalent |
|---|---|---|
| `tabs_state_populates_watch` | `:104` | `bm.state` populates the bm watch |
| `ext_disconnect_resets_watch` | `:126` | **must reset BOTH watches** (Pitfall 2 — RESEARCH warns this passes while a bm equivalent fails) |
| `ext_cmd_forwards_activate_frame` | `:148` | `bm.open`/`bm.star` relay frames |
| `ext_cmd_without_session_dropped` | `:172` | same, for `bm.*` |
| `oversize_frame_kills_session_and_relay_recovers` | `:233` | oversize `bm.state` |
| `groups_belt_truncates_at_sixteen` | `:301` | nodes belt truncates at 500 |
| `malformed_groups_degrade_to_empty` | `:328` | (N/A — nodes take the strict posture) |

---

## Shared Patterns

### Additive optional wire field (`Option<T>` + `default` + `skip_serializing_if`)
**Sources:** `server/server-core/src/executors/mod.rs:50-53` (`WindowInfo.icon/path`, 1.2) and `:71-78` (`TabInfo.groupId`, 1.5); Dart mirror `json_codec.dart:186-195`.
**Apply to:** `TabInfo.bookmarked`, every optional `BmNode` field, in **both** codecs + a fixture proving the key is absent on re-encode.

### Value-equal snapshot / view state, hand-rolled (no `package:collection`)
**Sources:** `connection_service.dart:163-190` (`TabsSnapshot`), `tabs_store.dart:24-61` (`TabsViewState`), `json_codec.dart:197-206` (`TabInfo`).
**Apply to:** `BookmarksSnapshot`, `BookmarksViewState`, `BmNode`.

### Fire-and-forget with self-healing snapshots (no `err` reply)
**Sources:** `router.rs:248-256` (no reply), `ext.rs:83-89` (`try_send`, silent drop), `background.js:91-99` (`.catch(() => {})`), `tabs_store.dart:102-105`.
**Apply to:** all four `bm.*` commands. Adding an `err` code would break the family's posture (RESEARCH Pitfall 10).

### Privacy discipline — never log titles or URLs
**Sources:** `background.js:8-9` (header), `ext.rs:11-14` (header), `connection_service.dart:660-663` ("NO payload logging anywhere"), `background.js:296-302` (counts-only log).
**Apply to:** every new log line in the extension and every new parking arm comment.

### Gated = muted, never red; layout never shifts
**Sources:** `browser_screen.dart:306-307` (`authed` derivation), `:776-790` (`enabled ? … : null` on every callback, `kMuted` title when disabled).
**Apply to:** the star slot, bookmark rows, folder rows. **Not** the segment control (`key_pads.dart:186-192` — navigation has no gated variant).

### Caps declared as named consts with a SPEC §15 cross-reference comment
**Sources:** `background.js:16-21` (extension side), `ext.rs:39-46` (server belt side).
**Apply to:** `MAX_BM_NODES` / `MAX_BM_TITLE` (extension) and `MAX_EXT_BM_NODES` (server).

### Hard-registered fixture families (neither harness globs)
**Sources:** `fixtures.rs:176-184`, `fixture_test.dart:195-202`.
**Apply to:** `protocol/fixtures/bookmarks/` — two one-line registrations, or the family is silently untested.

---

## No Analog Found

| File / concern | Role | Data Flow | Reason |
|---|---|---|---|
| **A segmented control that swaps a list region inside an existing screen** | component | — | **Stated explicitly, as requested:** the app has three hand-rolled segment/tab affordances — `_ScrollDirectionSegment` (`settings_screen.dart:409-485`), `KeyboardTabBar` (`key_pads.dart:201-271`), `KeyRowGroupSwitcher` (`key_rows.dart`) — but **none of them swaps a scrollable list region while keeping surrounding chrome pixel-pinned.** `_ScrollDirectionSegment` toggles a boolean setting; `KeyboardTabBar` drives a full-screen `PageView` with a slide animation (the opposite of D-01's instant list swap). The **visual** contract has an exact analog (`_SegmentButton`); the **layout** contract — `Column` → fixed segment / `Expanded` scroll / pinned footer — does not exist anywhere in `lib/` and is genuinely new. The planner should treat the layout restructure as new work with a pinned `tester.getRect()` acceptance test (UI-SPEC), not as a copy. |
| Folder drill-down + local back stack in a store | store | — | No existing notifier holds local navigation state; `TabsNotifier`/`AppsNotifier` are pure projections of a pushed snapshot. New. |
| Optimistic-then-reconcile UI state | store | — | No precedent. Every existing surface renders the authoritative snapshot only (D-12 notes the Media mute deliberately has no optimistic flip). New. |

---

## Corrections to Upstream Documents

Verified against live code — the planner should not propagate these as stated:

1. **CONTEXT.md:80** — "`SERVER_PROTO_VERSION` bump to 1.6 lives in `codec/json.rs`". **False.** It is `server/server-core/src/transport/session.rs:60`, re-exported at `transport/mod.rs:22`. (RESEARCH already catches this.)
2. **RESEARCH Pitfall 2 / Pattern 2** — "`run_ext` resets `tabs_tx` at **four** sites". **Three**, verified: `ext.rs:165-166`, `:178-179`, `:191-192`. The "send-failure path inside the incoming arm" and the pong-send-failure path are the same site (`:177-180`).
3. **`ExtCmd` derives `Copy`** (`ext.rs:50`). A `String`-carrying `BmOpen`/`BmRemove` variant forces dropping `Copy` from the derive list — not mentioned in RESEARCH.
4. **UI-SPEC vs RESEARCH on the star glyph:** RESEARCH (`§Icons`, line 702) recommends `Symbols.star_outline_rounded`; UI-SPEC (Component 3) states that symbol **does not exist** in the pinned `material_symbols_icons 4.2951.0` and mandates `Symbols.star_rounded` with the FILL axis. **Follow UI-SPEC** (later document, explicitly verified there). Not independently re-verified in this pass.
5. **UI-SPEC star touch target is 48×48**; RESEARCH's snippet says 44×44. Follow UI-SPEC (48 is the house token).

---

## Metadata

**Analog search scope:** `extension/`, `server/server-core/src/{executors,codec,transport,dispatch}`, `server/server-core/tests/`, `app/packages/remote_protocol/`, `app/remote_control/lib/{browser,settings,keyboard,net,theme,power}`, `app/remote_control/test/`, `protocol/fixtures/`
**Files read in full:** `extension/background.js` (350), `server/server-core/src/transport/ext.rs` (241), `app/remote_control/lib/browser/tabs_store.dart` (110)
**Files read by targeted range:** `browser_screen.dart` (851), `settings_screen.dart`, `json_codec.dart`, `connection_service.dart`, `router.rs` (1127), `session.rs`, `executors/mod.rs`, `key_rows.dart`, `key_pads.dart`, the two fixture harnesses, `browser_screen_test.dart`, `ext_relay.rs`
**Pattern extraction date:** 2026-07-29
