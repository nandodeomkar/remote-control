# Phase 12: In-App Updates - Pattern Map

**Mapped:** 2026-08-01
**Files analyzed:** 34 new/modified files across 4 codebases (Rust server, Flutter app, browser extension, release tooling)
**Analogs found:** 31 / 34 (3 have no analog — see § No Analog Found)

> Every excerpt below was read out of the tree on 2026-08-01. Line numbers and
> signatures are real. Where a planner task says "copy X", the file:line named
> here is the exact source.

---

## File Classification

### 1. Rust — `server/server-core` (zero-Windows-deps invariant HOLDS)

| New/Modified File | Role | Data Flow | Closest Analog | Match |
|---|---|---|---|---|
| `src/codec/json.rs` (MODIFY) | codec | request-response + push | itself — the `bm.*` family block, added phase 11 | exact |
| `src/executors/mod.rs` (MODIFY) | trait/model | command | `Bookmarks` / `Tabs` traits (`:268-307`) | exact |
| `src/executors/mock.rs` (MODIFY) | test double | command | existing recording mocks | exact |
| `src/dispatch/router.rs` (MODIFY) | router | request-response | `Msg::BmList` / `Msg::BmOpen` arms (`:265-300`) | exact |
| `src/transport/mod.rs` (MODIFY) | config/DI | push seam | `ServerDeps.bookmarks` field (`:111-118`) | exact |
| `src/transport/session.rs` (MODIFY) | session loop | push (watch) | `bookmarks.changed()` select arm (`:368-393`); `SERVER_PROTO_VERSION` (`:65`) | exact |
| `src/transport/ext.rs` (MODIFY) | relay | event-driven | `ExtCmd` enum (`:65-81`), `"ext.hello" => None` (`:383`) | exact |

### 2. Rust — `server/server-windows` (all I/O)

| New/Modified File | Role | Data Flow | Closest Analog | Match |
|---|---|---|---|---|
| `src/update/mod.rs` (NEW) | executor impl | command | `server-core/src/transport/ext.rs::BookmarksRelay` (`:121-159`) and `src/executors/clipboard.rs` | role-match |
| `src/update/update_thread.rs` (NEW) | worker thread | batch / streaming | `src/clip_thread.rs` (whole file) · `src/audio_thread.rs` | exact |
| `src/update/feed.rs` (NEW) | service | request-response (HTTP) | **none in tree** — no HTTP client exists yet | none |
| `src/update/download.rs` (NEW) | service | streaming + hashing | `clip_thread::clip_fingerprint` (`:70-77`) for the `sha2` half only | partial |
| `src/update/apply.rs` (NEW) | service | process spawn | `src/firewall.rs` (native command spawn), `src/autostart.rs` | partial |
| `src/update/marker.rs` (NEW) | service | file I/O | `src/config.rs::config_path` / `load` (`:104-135`) | exact |
| `src/main.rs` (MODIFY) | composition root | wiring | steps 3a/3b/3c (`:78-130`) | exact |
| `src/shell/settings.rs` (MODIFY) | UI section | request-response | `GENERAL` / `PAIRED DEVICES` sections (`:160-266`, `field_label` at `:434`) | exact |
| `Cargo.toml` (MODIFY) | config | — | its own `[dependencies]` block (`:12`+) | exact |
| `tests/` update guard test (NEW) | test | — | `tests/extension_guard.rs` (string-invariant guards); `single_instance.rs` mutex-name test | exact |

### 3. Flutter — `app/remote_control` + `app/packages/remote_protocol`

| New/Modified File | Role | Data Flow | Closest Analog | Match |
|---|---|---|---|---|
| `packages/remote_protocol/lib/src/json_codec.dart` (MODIFY) | codec | request-response + push | `BmListMsg` (`:1063-1096`), `BmChangedMsg` (`:1102-1141`), `BmOpenMsg` (`:1153-1170`), dispatch `switch` (`:1404-1449`) | exact |
| `lib/update/version.dart` (NEW) | utility (pure) | transform | `lib/settings/haptics.dart` pure-helper shape; RESEARCH Code Ex. 7 | partial |
| `lib/update/release_feed.dart` (NEW) | service | request-response (HTTP) | **none** — no `HttpClient` use in `lib/` | none |
| `lib/update/update_cache.dart` (NEW) | store | file/prefs I/O | `lib/browser/browser_segment.dart` `PrefsKv` seam; `lib/settings/sensitivity.dart` | exact |
| `lib/update/apk_download.dart` (NEW) | service | streaming | **none** | none |
| `lib/update/apk_installer.dart` (NEW) | platform channel | command | `lib/platform/multicast_lock.dart` (whole file) | exact |
| `lib/update/update_providers.dart` (NEW) | provider/store | event-driven | `lib/browser/bookmarks_store.dart` (whole file); `lib/net/connection_providers.dart` | exact |
| `lib/update/updates_screen.dart` (NEW) | screen | — | `lib/settings/settings_screen.dart` (`:136-200`, `:226-266`, `:318-345`) | exact |
| `lib/settings/settings_screen.dart` (MODIFY) | screen | — | its own `_AddSwitchPcRow` (`:318-345`) + `_AboutGroup` | exact |
| `lib/net/connection_service.dart` (MODIFY) | service | event-driven | its own `if (msg is BmChangedMsg)` handler (`:747-770`) + `sendReliable` (`:559`) | exact |
| `android/.../MainActivity.kt` (MODIFY) | platform | command | its own multicast `MethodChannel` block (`:15-34`) | exact |
| `android/.../InstallResultReceiver.kt` (NEW) | platform receiver | event-driven | **none** — no BroadcastReceiver in tree | none |
| `android/app/src/main/AndroidManifest.xml` (MODIFY) | config | — | existing `uses-permission` block (`:11-13`) | exact |
| `pubspec.yaml` (MODIFY) | config | — | its own dependency block (`:55`, `:69`) | exact |

### 4. Extension, protocol, tooling

| New/Modified File | Role | Data Flow | Closest Analog | Match |
|---|---|---|---|---|
| `extension/background.js` (MODIFY) | service worker | event-driven | its own `switch (msg.t)` arms (`:140-175`); `ext.hello` send (`:113-116`) | exact |
| `extension/manifest.json` (MODIFY) | config | — | itself | exact |
| `protocol/SPEC.md` (MODIFY) | doc | — | §2 1.6/1.7 addition lines (`:41-42`); §7 `bm.*` rows (`:127-128`); §15 | exact |
| `protocol/fixtures/update/*.json` (NEW) | fixture | — | `protocol/fixtures/bookmarks/*` (9 files) | exact |
| `protocol/fixtures/beacon/01-valid.json` (MODIFY) | fixture | — | itself — pins `"proto": "1.7"` at `:10` and `:16` | exact |
| `server-core/tests/fixtures.rs` (MODIFY) | test | — | `codec_fixtures_bookmarks()` (`:188-200`) | exact |
| `remote_protocol/test/fixture_test.dart` (MODIFY) | test | — | `group('bookmarks fixtures', ...)` (`:230`) | exact |
| `tools/release.ps1` (NEW) | build script | batch | `installer/build-installer.ps1` (whole file) | exact |
| `installer/RemoteControl.iss` (MODIFY) | packaging | — | its own `[Files]` extension entry (`:102`) | exact |
| `DISTRIBUTION.md` (MODIFY) | doc | — | itself | exact |

---

## Pattern Assignments

### `server-core/src/codec/json.rs` — the `update.*` payload structs (codec, request-response)

**Analog:** the `bm.*` block in the same file, added by phase 11.

**Payload struct with an optional field, renamed to camelCase** (`:270-295`) — this is the exact shape `UpdateStatusPayload` needs (`serverVersion` required, `extVersion`/`lastUpdate` optional):

```rust
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BmChangedPayload {
    pub connected: bool,
    pub nodes: Vec<BmNode>,
    /// Snapshot-level truncation — see [`BmListPayload::truncated`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub truncated: Option<bool>,
}
```

**camelCase rename convention** (`:373-377`, on `ErrPayload`):

```rust
    #[serde(
        rename = "serverVersion",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub server_version: Option<String>,
```

**Empty-payload struct** for `update.check` — copy `ClipGetPayload` (`:200-201`):

```rust
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClipGetPayload {}
```

**Three registration points, all in this one file** (a new variant must be added to all three or it will not compile / will silently not decode):
1. `enum Msg` — `:391-433` (add `UpdateCheck(..)`, `UpdateStatus(..)`, `UpdateApply(..)`, `UpdateProgress(..)`)
2. `decode_text` match — `:452-495`, e.g. `"bm.open" => Msg::BmOpen(payload(p)?),`
3. `encode_msg` match — `:529-570`, e.g. `Msg::BmOpen(pl) => ("bm.open", val(pl)),`

**Round-trip test convention** (`:591-597` helper, `:731-737` an additive-push example):

```rust
    #[test]
    fn round_trip_input_blocked() {
        // proto 1.3 (SRV-05/D-07): additive S→C push, encode/decode symmetric.
        round_trip(
            Msg::InputBlocked(InputBlockedPayload { reason: "elevated".into() }),
            None,
        );
    }
```

**D-14 note for the planner:** the file-level doc (`:1-15`) states enum-valued wire fields decode as plain `String` — so `stage`/`error` are `String`, validated by the router, not the codec. And `UpdateApplyPayload` must contain exactly one field, `target: String`. The structural SC6 test belongs beside `server-core/tests/extension_guard.rs`, whose style is a source-text assertion.

---

### `server-core/src/executors/mod.rs` — the `UpdateExecutor` trait (trait, command)

**Analog:** `Bookmarks` (`:289-295`) and the `Executors` bundle (`:299-307`).

```rust
pub trait Bookmarks: Send + Sync {
    fn list(&self) -> BookmarksState;
    fn open(&self, node_id: &str);
    fn star(&self, tab_id: i64);
    fn unstar(&self, tab_id: i64);
    fn remove(&self, node_id: &str);
}

pub struct Executors {
    pub mouse_keys: Arc<dyn MouseKeys>,
    pub media: Arc<dyn Media>,
    pub power: Arc<dyn Power>,
    pub apps: Arc<dyn Apps>,
    pub clipboard: Arc<dyn Clipboard>,
    pub tabs: Arc<dyn Tabs>,
    pub bookmarks: Arc<dyn Bookmarks>,
}
```

Module header rule to honour (`:1-7`): *"Traits are SYNC (`&self` methods, `Send + Sync`) … NO OS types anywhere."* The `UpdateExecutor` methods must be `&self`, sync, and take/return only `String`/plain data — which is also exactly what D-14 demands.

**Where the new executor goes** is a real decision the planner must name: RESEARCH proposes `ServerDeps.update`, but every existing executor lives in `Executors`. Follow `Executors` (the trait bundle) for the command half and `ServerDeps` (watch receivers) for the progress half — that split matches `Tabs`+`ServerDeps.tabs` exactly.

---

### `server-core/src/dispatch/router.rs` — the `update.*` dispatch arms (router, request-response)

**Analog:** the `bm.*` arms (`:265-300`) and the `apps.list` reply arm (`:196-198`).

**Read-with-reply arm** (`:265-278`) — the shape `update.check` copies:

```rust
        Msg::BmList(_) => {
            let state = exec.bookmarks.list();
            vec![Msg::BmList(BmListPayload {
                connected: Some(state.connected),
                nodes: Some(state.nodes),
                truncated: Some(state.truncated),
            })]
        }
```

**Fire-and-forget command arm** (`:280-283`) — the shape `update.apply` copies:

```rust
        Msg::BmOpen(p) => {
            exec.bookmarks.open(&p.node_id);
            Vec::new()
        }
```

**Executor binding (D-13)** — `is_executor_bound` at `:344-366`. `Msg::UpdateCheck` and `Msg::UpdateApply` must BOTH be added to the `matches!` list there. Note this diverges from the `bm.list`/`apps.list`/`clip.get` read exemption: CONTEXT D-13 says `update.check` IS executor-bound, unlike every other `*.list` read. The doc comment at `:344` explains the exemption rule and must be amended, not silently contradicted.

**S→C-only arms** (`:326-340`): `Msg::UpdateStatus` and `Msg::UpdateProgress` arriving from a client are ignored silently — add them to that `|`-chain, NOT to the `Unknown` arm.

**Router gates in order** (`:66-78`): GATE 1 auth (`ctx.auth_state != Authed` ⇒ empty), GATE 2 pause, GATE 3 family routing. `update.*` inherits auth for free.

**Test convention** for the pause gate (`:657-687`, `paused_drops_every_executor_bound_family_silently`) — the new families go into that test's list, and `bm_commands_route_when_unpaused` (`:874`) is the routing-test template.

---

### `server-core/src/transport/session.rs` + `mod.rs` — progress push (session, push)

**Analog:** the `bookmarks.changed()` select arm (`session.rs:368-393`).

```rust
            changed = bookmarks.changed(), if bookmarks_alive && ctx.auth_state == AuthState::Authed => {
                match changed {
                    Ok(()) => {
                        let state = bookmarks.borrow_and_update().clone();
                        // WR-08: non-blocking try_send — drop on a full queue,
                        // the latest-value re-delivers.
                        match tx.try_send(bm_changed_frame(state)) {
                            Ok(()) => {}
                            Err(mpsc::error::TrySendError::Full(_)) => {}
                            Err(mpsc::error::TrySendError::Closed(_)) => break 'read,
                        }
                    }
                    Err(_) => bookmarks_alive = false,
                }
            }
```

The `try_send`-drop-on-full behaviour is exactly right for `update.progress` `pct` (watch coalesces; a dropped tick re-delivers).

**`ServerDeps` field** (`mod.rs:111-118`) — add `pub update: tokio::sync::watch::Receiver<UpdateProgress>` beside `tabs`/`bookmarks`, with the same doc-comment discipline (state ownership, no-snapshot vs snapshot).

**`SERVER_PROTO_VERSION`** — `session.rs:65`:

```rust
pub const SERVER_PROTO_VERSION: &str = "1.7";
```

Re-exported at `transport/mod.rs:22`. **CONFIRMED RESEARCH Pitfall 11:** `protocol/fixtures/beacon/01-valid.json` pins `"proto": "1.7"` at BOTH `:10` (wire) and `:16` (expect). Bumping to `"1.8"` must edit that fixture in the same task, or `codec_fixtures_beacon` fails with an unrelated-looking error.

---

### `server-core/src/transport/ext.rs` — `ext.reload` (relay, event-driven)

**Analog:** `ExtCmd` (`:65-81`) and the `ext.hello` handler (`:383`).

```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExtCmd {
    /// `tabs.activate {id}` — switch the browser to that tab.
    Activate(i64),
    Close(i64),
    BmOpen(String),
    BmStar(i64),
    BmUnstar(i64),
    BmRemove(String),
}
```

Add `Reload`. The command dispatch arms are at `:263-280` inside `run_ext`.

**`ext.hello` is currently a no-op** (`:383`) — `"ext.hello" => None,`. This is the single line that must grow into the D-18 version comparison + the `Option<String>` reload guard. The extension already sends `extVersion` (`extension/background.js:113-116`):

```js
      t: "ext.hello",
      p: { extVersion: chrome.runtime.getManifest().version },
```

**Lenient-parse convention for ext-leg fields** (`:369-372`) — read `extVersion` the same way `truncated` is read: `frame.p.get("extVersion").and_then(Value::as_str)`, absent ⇒ unknown, never an error.

---

### `server-windows/src/update/update_thread.rs` (worker thread, streaming)

**Analog:** `server-windows/src/clip_thread.rs` — read its header (`:1-23`) for the house doc style, and:

```rust
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::time::Duration;
use tokio::sync::watch::Sender;

/// Poll cadence (RESEARCH A5): 250 ms mirrors the audio thread.
const POLL_INTERVAL: Duration = Duration::from_millis(250);

/// Command sent from the executor (non-blocking mpsc send) to the thread.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClipCmd {
    Set(String),
}
```

**Wiring in `main.rs`** — the three-line pattern, from step 3b (`:96-99`):

```rust
    let (apps_cmd_tx, apps_cmd_rx) = std::sync::mpsc::channel::<AppsCmd>();
    let (apps_tx, apps_rx) = tokio::sync::watch::channel(Vec::<WindowInfo>::new());
    std::thread::spawn(move || apps_thread::run_apps_thread(apps_cmd_rx, apps_tx));
```

and the executor bundle at `:139-148`:

```rust
        apps: Arc::new(WinApps::new(apps_cmd_tx, apps_rx.clone())),
        clipboard: Arc::new(WinClipboard::new(clip_cmd_tx, clip_rx.clone())),
```

**sha256 with the in-tree `sha2` 0.11** (`clip_thread.rs:70-77`) — no new digest crate:

```rust
use sha2::{Digest, Sha256};

pub fn clip_fingerprint(text: &str) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(text.as_bytes());
    let out = hasher.finalize();
    let mut fp = [0u8; 32];
    fp.copy_from_slice(&out);
    fp
}
```

`hex = "0.4"` is already in `server-windows/Cargo.toml:77`, so `hex::encode(hasher.finalize())` needs no new dependency.

**Pure-function factoring rule** (`clip_thread.rs:57-84`): the testable predicates (`should_skip_clip`, `is_echo`) are pulled OUT of the OS loop so they unit-test with no OS call. Apply the same to version compare, digest-prefix stripping, and the D-15 refusal ordering.

---

### `server-windows/src/update/marker.rs` (service, file I/O)

**Analog:** `server-windows/src/config.rs:104-135`.

```rust
pub fn config_path() -> PathBuf {
    // unwrap_or_default: a None known folder degrades to a relative path —
    // mirror of main.rs's machine_guid degrade-never-panic fallback.
    dirs::config_dir()
        .unwrap_or_default()
        .join("RemoteControl")
        .join("config.toml")
}

pub fn log_dir() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_default()
        .join("RemoteControl")
        .join("logs")
}

pub fn load() -> Config {
    match std::fs::read_to_string(config_path()) {
        Ok(text) => parse(&text),
        // Missing file IS the normal first run — no warn for NotFound.
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Config::default(),
```

The `NotFound ⇒ default, no warn` arm is precisely RESEARCH Pattern 4's "an absent marker is the normal case". `update-result.json` goes beside `config.toml`; `update.log` beside `logs/`. `dirs = "6.0"` is already at `Cargo.toml:74`.

---

### `server-windows/src/update/apply.rs` (service, process spawn) — no strong analog

Nearest in-tree process spawning is `src/firewall.rs` (netsh) and `src/autostart.rs`. Neither uses `creation_flags`/detachment. Use RESEARCH Code Example 3 verbatim.

**The one in-tree string this file must reference** — `src/single_instance.rs:36`:

```rust
/// `installer/RemoteControl.iss` sets `AppMutex=RemoteControl.SingleInstance`
/// so Setup can detect a running copy … Changing this string on one side only
/// silently breaks that detection — change both or neither.
pub const MUTEX_NAME: &str = "RemoteControl.SingleInstance";
```

Its file header documents the fact D-16 leans on: *"the handle is released on drop (and by the kernel on exit, including a hard kill)"* — i.e. PID death is a sufficient mutex-release signal. The pinned-string test in that file (`mutex_name_matches_the_installer_contract`) is the template for the SC6 structural test.

---

### `server-windows/src/shell/settings.rs` — the `UPDATES` section (UI, request-response)

**Analog:** the sibling sections at `:160-166` and the field block at `:213-236`:

```rust
                        style::section_label(ui, "GENERAL");
                        ui.add_space(12.0);
                        …
                        ui.add_space(22.0);
                        style::section_label(ui, "PAIRED DEVICES");
                        ui.add_space(12.0);
```

```rust
        field_label(ui, "Device name", Some("(shown on your phone)"));
        ui.add_space(7.0);
        …
        field_label(ui, "Port", None);
        ui.add_space(7.0);
```

`field_label` is a local helper at `:434`. The UI-SPEC's egui block quotes this geometry exactly — the `7.0` is correct and must not be "fixed" to 8.

---

### `remote_protocol/lib/src/json_codec.dart` — Dart `update.*` codecs (codec)

**Analog:** `BmListMsg` (`:1063-1096`) for a dual/optional-field payload, `BmChangedMsg` (`:1102-1141`) for a required-field push, `BmOpenMsg` (`:1153-1170`) for a one-field command.

```dart
final class BmOpenMsg extends RemoteMessage {
  /// Chrome bookmark node id (a String).
  final String nodeId;

  /// Creates a bm.open message.
  const BmOpenMsg({required this.nodeId});

  /// Decodes the `bm.open` payload.
  factory BmOpenMsg.fromPayload(Map<String, dynamic> p) =>
      BmOpenMsg(nodeId: _req<String>(p, 'nodeId'));

  @override
  String get t => 'bm.open';

  @override
  Map<String, Object?> toPayload() => {'nodeId': nodeId};
}
```

`UpdateApplyMsg` is a byte-for-byte clone of this with `target`. Required vs optional field helpers are `_req<T>` / `_opt<T>`; a missing required field throws `FormatException` (`:1123-1125`):

```dart
    if (!p.containsKey('nodes')) {
      throw const FormatException('missing required field: nodes');
    }
```

**Registration point** — the `switch (tRaw)` in `decodeText` (`:1404-1449`), one line per type:

```dart
    'bm.open' => BmOpenMsg.fromPayload(p),
```

Unknown `t` falls to `_ => UnknownMsg(t: tRaw)` (`:1447`) — the SC8 forward-compat guarantee, already implemented on both sides.

---

### `protocol/fixtures/update/` (fixtures) — the shared contract

**Analog:** `protocol/fixtures/bookmarks/` (9 files). Empty-payload fixture, `09-bm-list-request.json`, verbatim:

```json
{
  "name": "bm-list-request",
  "description": "C→S bm.list request (protocol 1.6): the request form carries NEITHER field … `encode_msg` always emits `p`, as `{}` for an empty payload (the Phase-01 canonical-form rule) …",
  "wire": { "t": "bm.list", "p": {} },
  "expect": { "t": "bm.list", "p": {} }
}
```

**Both harnesses hard-register families — neither globs directories.** A new `update/` directory with no registration is silently untested. Register in BOTH:

- `server/server-core/tests/fixtures.rs:188` — `fn codec_fixtures_bookmarks() { run_json_family("bookmarks"); }`, whose own comment states the rule: *"Hard-registered: neither harness globs directories (the 07-02 input.blocked lesson), so without this function the nine golden files would be silently untested — zero coverage AND zero failures."*
- `app/packages/remote_protocol/test/fixture_test.dart:230` — `group('bookmarks fixtures', () { runJsonFamily('bookmarks'); });`

The RESEARCH-proposed `version-compare.json` is NOT a wire fixture — it has no `wire`/`expect` envelope, so it needs its own loader on both sides, following the `handshake/05-auth-proof.json` "special case" precedent documented in `protocol/fixtures/README.md`.

---

### `lib/update/apk_installer.dart` (platform channel, command)

**Analog:** `lib/platform/multicast_lock.dart` — the whole file is the template, including the test contract:

```dart
class MulticastLock {
  static const MethodChannel _channel =
      MethodChannel('remote_control/multicast');

  Future<void> acquire() async {
    try {
      await _channel.invokeMethod<void>('acquire');
    } on MissingPluginException {
      // No handler registered (test / non-Android): nothing to hold.
    }
  }
}
```

**Kotlin side** — `MainActivity.kt:15-34`, one `configureFlutterEngine` override, one `MethodChannel(...).setMethodCallHandler { call, result -> when (call.method) { ... else -> result.notImplemented() } }`. Add a SECOND `MethodChannel` in the same override; do not restructure the existing one.

**Manifest** — `android/app/src/main/AndroidManifest.xml:11-13` currently declares `INTERNET`, `CHANGE_WIFI_MULTICAST_STATE`, `CAMERA`. `REQUEST_INSTALL_PACKAGES` joins that block, and `InstallResultReceiver` needs a `<receiver>` entry (no existing analog).

---

### `lib/update/update_providers.dart` (provider, event-driven)

**Analog:** `lib/browser/bookmarks_store.dart` — a Riverpod-3 `Notifier` that subscribes to `service.changes`, re-snapshots into a value-equal state, and sends commands over `sendReliable`. Its header names the pattern:

> *"Clones the [TabsNotifier] shape (subscribe to `service.changes`, re-snapshot `service.bookmarksSnapshot` into a value-equal state, expose the commands over `sendReliable`)"*

`BookmarksViewState` (`:27-130`) is the template for an immutable value-equal state class with a hand-written `operator ==` — the UI-SPEC's row-state matrix maps onto exactly this.

**Service seam** — `lib/net/connection_service.dart`: `Stream<void> get changes` (`:490`), `void sendReliable(RemoteMessage msg)` (`:559`), snapshot getters (`:459`, `:464`), and the push handler (`:747-770`, `if (msg is BmChangedMsg) { … }`). A `_updateSnapshot` field + getter + `if (msg is UpdateStatusMsg)` / `UpdateProgressMsg` arms is the exact shape to add.

**Provider registration** — `lib/net/connection_providers.dart:66-88` (`class ConnectionStatusNotifier extends Notifier<...>` + `NotifierProvider`).

**Installed-app version** — `lib/settings/app_version.dart` (whole file, 50 lines). Reuse `appVersionProvider` as-is; do not add a parallel one. Note it returns the FORMATTED `"1.4.0 (8)"` string via `formatAppVersion`, so the Updates screen — which needs the bare `1.4.0` for comparison — needs either a second provider off `PackageInfo` or a split of that function. Name this explicitly in the plan; silently reusing the formatted string would break `SemVer.tryParse`.

Also copy the anti-constant rationale in its header (`:15-18`) — it is D-05's origin.

---

### `lib/update/update_cache.dart` (store, prefs I/O)

**Analog:** `lib/browser/browser_segment.dart` and `lib/settings/sensitivity.dart` — the `PrefsKv` seam: namespaced key, corrupt/unknown read degrades to default, fire-and-forget save. `shared_preferences: ^2.5.5` is already at `pubspec.yaml:55`.

---

### `lib/update/updates_screen.dart` + `lib/settings/settings_screen.dart` (screens)

**Analog:** `lib/settings/settings_screen.dart` — every idiom the UI-SPEC names is in this one file.

**Scaffold** (`:136-161`):

```dart
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        title: const Text(kSettingsTitle, style: _appBarTitle),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: const [ … SizedBox(height: 24) between groups … ],
        ),
      ),
    );
```

**Typography consts** (`:108-127`) — copy `_appBarTitle` (16/600 kText), `_groupHeading` (14/600 kMuted), `_rowTitle` (16/400 kText), `_rowSubtitle` (14/400 kMuted) verbatim into the new file; they are private per-file consts, not shared.

**`_GroupSurface`** (`:168-200`) — `Material(kSurface)` radius 12 with interleaved `Divider(height: 1, thickness: 1, color: kHairline)`, optional heading with `EdgeInsets.only(bottom: 8, left: 4)`.

**`_PairedPcRow`** (`:226-266`) — the `UpdateRow` geometry, including the trailing action button:

```dart
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(children: [
            Expanded(child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: _rowTitle),
                const SizedBox(height: 2),
                Text(deviceMetaPaired(entry.host), style: _rowSubtitle),
              ])),
            TextButton(
              onPressed: () => _confirmRevoke(context, ref),
              child: const Text(kRevokeLabel,
                style: TextStyle(color: kError, fontWeight: FontWeight.w600)),
            ),
          ]),
        ),
      );
```

The `Update`/`Retry` button is this `TextButton` with `kError` → `kAccent`. (The UI-SPEC forbids `kError` anywhere in phase 12.)

**`_AddSwitchPcRow`** (`:318-345`) — the `UpdatesNavRow` template: `Material(kSurface)` + `InkWell`, `minHeight 48`, `EdgeInsets.symmetric(horizontal: 16, vertical: 12)`, leading `Icon(Symbols.x_rounded, color: kText, size: 20)` + `SizedBox(width: 12)` + `Text(label, style: _rowTitle)`.

**Copy-const convention** — named `const String` at file top (`kRevokeConfirmConfirm`, `kRevokeLabel`, `:100-104`), never inline literals.

---

### `extension/background.js` — the `ext.reload` arm (service worker, event-driven)

**Analog:** the `switch (msg.t)` at `:140`, e.g.:

```js
      case "tabs.close":
        chrome.tabs.remove(p.id).catch(() => {});
        break;
```

Add `case "ext.reload": chrome.runtime.reload(); break;`. `chrome.runtime.getManifest().version` is already read at `:115` for `ext.hello` — no new read is needed.

**Guard test analog:** `server/server-core/tests/extension_guard.rs` asserts source-text invariants over `extension/background.js` and `extension/manifest.json` from the Rust test suite (e.g. `extension_declares_bookmarks_permission`, `:118-128`). Any new extension invariant belongs there.

---

### `tools/release.ps1` (build script, batch)

**Analog:** `installer/build-installer.ps1` (157 lines) — reuse four things verbatim.

**1. The Cargo.toml version regex (D-20's server bump must use the SAME anchor):**

```powershell
    # First `version = "..."` line, which is the [package] one -- dependency
    # versions further down the file are all inside inline tables.
    $match = Select-String -Path $CargoToml -Pattern '^\s*version\s*=\s*"([^"]+)"' |
             Select-Object -First 1
```

**2. `Invoke-Native` — the PS 5.1 stderr/NativeCommandError workaround** (`:49-61`). Every `cargo` / `flutter` / `gh` / `ISCC` call must go through it and be checked via `$LASTEXITCODE`.

**3. The three-candidate exe resolution shape** (`:92-104`, for ISCC) — the same shape resolves `gh.exe` (RESEARCH Pitfall 10: `Get-Command gh` first, then `C:\Program Files\GitHub CLI\gh.exe`, then a clear multi-line `throw`).

**4. Path/layout conventions** (`:63-68`):

```powershell
$RepoRoot   = Split-Path -Parent $PSScriptRoot
$ServerDir  = Join-Path $RepoRoot 'server'
$CargoToml  = Join-Path $ServerDir 'server-windows\Cargo.toml'
$DistDir    = Join-Path $RepoRoot 'dist'
```

Note `tools/release.ps1` is one level deep like `installer/`, so `Split-Path -Parent $PSScriptRoot` still yields the repo root.

Also copy: `[CmdletBinding()] param(...)`, `$ErrorActionPreference = 'Stop'`, the comment-based help block (`.SYNOPSIS`/`.PARAMETER`/`.EXAMPLE`), and the `Write-Host ... -ForegroundColor Cyan/Green/Yellow` progress convention.

**The release script must CALL `installer/build-installer.ps1`, not reimplement it** (D-20). Its output path is `dist\RemoteControl-Setup-v$Version.exe` (`:147`).

---

### Version-bearing files — exactly what `release.ps1` rewrites

| File | Line | Current value | Anchor |
|---|---|---|---|
| `server/server-windows/Cargo.toml` | `:7` | `version = "1.4.0"` | `^\s*version\s*=\s*"([^"]+)"`, **first match only** |
| `app/remote_control/pubspec.yaml` | `:24` | `version: 1.4.0+8` | `^version:\s*(\d+\.\d+\.\d+)\+(\d+)$` — BOTH halves; build number must strictly increase |
| `extension/manifest.json` | `:4` | `"version": "1.2.1"` | `"version": "..."` |

Also version-adjacent but NOT rewritten by the script (protocol identity, hand-edited in the SPEC task):
`server-core/src/transport/session.rs:65` `SERVER_PROTO_VERSION = "1.7"`; `protocol/SPEC.md:3` and `:32`; `protocol/fixtures/beacon/01-valid.json:10` and `:16`.
Known-stale, deliberately NOT touched: `app/packages/remote_protocol/lib/src/version.dart` (`protoVersion = '1.1'`).

---

### `installer/RemoteControl.iss` (packaging)

The four lines that matter, read in tree:

- `:102` — `Source: "..\extension\*"; DestDir: "{app}\extension"; Flags: ignoreversion recursesubdirs createallsubdirs` — the RESEARCH Pattern 5 `restartreplace` target.
- `:98` — the server exe `[Files]` entry, listed BEFORE the extension entry (Pitfall 4's ordering requirement is already satisfied — do not reorder).
- `:135` — `[Run] Filename: "{app}\{#MyAppExeName}"; … Flags: nowait postinstall skipifsilent` — confirms the helper must relaunch.
- `:139` — `[UninstallDelete] Type: filesandordirs; Name: "{app}\extension"`.

`AppMutex=RemoteControl.SingleInstance` is set earlier in the same file and is pinned by `single_instance.rs:36`.

---

## Shared Patterns

### Doc-comment discipline (applies to EVERY new Rust file)

**Source:** `server-windows/src/clip_thread.rs:1-23`, `single_instance.rs:1-24`, `logging.rs:1-24`.
Every module opens with a `//!` block that states WHAT it owns, WHY it exists now, and the failure posture (`DEGRADE, NEVER CRASH` / `FAIL-OPEN`). Decision IDs (`D-16`, `T-11-10`, `Pitfall 3`) are cited inline. A new module without this header is off-pattern.

### Degrade-never-crash

**Source:** `config.rs:104-135`, `logging.rs:19-24`, `single_instance.rs:19-24`.
**Apply to:** `marker.rs`, `feed.rs`, `update_cache.dart`, the whole background-check path (D-07 "a failed background check must never interrupt the user").
A missing marker, an unwritable log dir, a `None` known folder — all yield a default, never an error return, never a panic, and (for `NotFound`) not even a warn line.

### Pure-function extraction for testability

**Source:** `clip_thread.rs:57-84` (`should_skip_clip`, `clip_fingerprint`, `is_echo`), `audio_thread::pct_from_scalar`.
**Apply to:** version compare, `sha256:` prefix stripping, D-15 refusal ordering, the `{ago}` and `{size}` formatters in Dart.

### Named copy constants, no inline literals

**Source:** `settings_screen.dart:100-104`; `connection_copy.dart`.
**Apply to:** every string in `updates_screen.dart` and the explainer sheet. The UI-SPEC Copywriting Contract is the value source.

### Fixture hard-registration

**Source:** `server-core/tests/fixtures.rs:188-200` + `remote_protocol/test/fixture_test.dart:230`.
**Apply to:** `protocol/fixtures/update/`. Both harnesses, same task, or the family is silently untested.

### Pinned-string invariant tests

**Source:** `single_instance.rs` (`mutex_name_matches_the_installer_contract`), `server-core/tests/extension_guard.rs` (source-text assertions over `background.js` / `manifest.json` with long explanatory failure messages).
**Apply to:** the SC6 structural test (no `url`/`sha256`/`asset`/`path` field on any `update.*` payload struct), and any new installer-contract string.

### Non-blocking send-and-forget on hot seams

**Source:** `session.rs:378-386` (`tx.try_send`, drop on `Full`), `ext.rs:108` (`let _ = self.cmd.try_send(...)`).
**Apply to:** the `UpdateCmd` mpsc send from the executor and every progress push.

---

## No Analog Found

The planner should follow RESEARCH's Code Examples for these three; nothing in the tree resembles them.

| File | Role | Data Flow | Reason |
|---|---|---|---|
| `server-windows/src/update/feed.rs` + `download.rs` | service | HTTP request-response / streaming | **No HTTP client exists anywhere in the Rust tree.** `ureq` is a brand-new dependency; there is no prior redirect/timeout/streaming code to copy. Use RESEARCH Code Examples 1–2, and honour the timeout rule (ureq defaults to none). |
| `app/remote_control/lib/update/release_feed.dart` + `apk_download.dart` | service | HTTP / streaming + digest | **No `dart:io HttpClient` use in `lib/`**, and `crypto` is a new dependency. The only SDK-primitive precedent is `RawDatagramSocket` in `lib/net/beacon_listener.dart` — a precedent for the CHOICE, not for the code. Use RESEARCH Code Example 4. |
| `android/.../InstallResultReceiver.kt` | platform receiver | event-driven | **No `BroadcastReceiver`, no `PendingIntent`, no manifest `<receiver>` exists.** `MainActivity.kt` is the entirety of the Kotlin surface (34 lines). Use RESEARCH Code Examples 5–6, and mind Pitfalls 5/6/7. |

---

## Metadata

**Analog search scope:** `server/server-core/src/**`, `server/server-windows/src/**`, `server/server-core/tests/**`, `app/remote_control/lib/**`, `app/packages/remote_protocol/lib/src/**`, `app/packages/remote_protocol/test/**`, `app/remote_control/android/**`, `extension/`, `protocol/` (SPEC, fixtures, schema), `installer/`, `tools/`
**Files scanned:** ~45 read or grepped; 22 read in full or in targeted ranges
**Pattern extraction date:** 2026-08-01
