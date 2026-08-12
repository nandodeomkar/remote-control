# Phase 7: Server Shell, Dashboard & Polish - Pattern Map

**Mapped:** 2026-07-12
**Files analyzed:** 24 (13 server, 11 client + protocol)
**Analogs found:** 22 / 24 (2 genuinely new: tray/settings shell, firewall COM)

This phase copies established house patterns almost everywhere. The genuinely
new engineering is confined to (a) the winit/tray/egui shell topology and
(b) two Win32 detection quirks (firewall COM read, UIPI integrity-level check).
Everything else — the `input.blocked` protocol amendment, config persistence,
revoke, the dashboard rewire, haptics gate, keep-awake ref-count — clones an
existing seam byte-for-byte.

---

## File Classification

### Server half (Rust)

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `server-windows/src/shell/mod.rs` | shell/thread-spawn | event-driven | `server-windows/src/main.rs` (4 dedicated-thread spawns) | role-match (new topology) |
| `server-windows/src/shell/tray.rs` | UI (tray) | event-driven | — (no analog) | **no analog** |
| `server-windows/src/shell/settings.rs` | UI (egui window) | event-driven | — (no analog) | **no analog** |
| `server-windows/src/config.rs` | config/persistence | file-I/O | `server-windows/src/main.rs` step 7a (winreg reads) | partial (serde+dirs new) |
| `server-windows/src/firewall.rs` | detection thread | request-response | `server-windows/src/apps_thread.rs` (COM/OpenProcess) | role-match |
| `server-windows/src/autostart.rs` | utility | request-response | `server-windows/src/main.rs` `machine_guid()` (winreg) | partial |
| `server-windows/src/notify.rs` (extend) | notification | fire-and-forget | `server-windows/src/notify.rs` `notify_pin` | exact |
| `server-windows/src/input_thread.rs` (extend) | input thread | event-driven | `apps_thread.rs` `exe_path()` (OpenProcess+token) | role-match |
| `server-windows/src/main.rs` (modify) | composition root | — | `main.rs` steps 3a-3c, 5, 5a | exact |
| `server-core/src/auth/mod.rs` (modify) | model/state machine | CRUD | `auth/mod.rs` `AuthManager` | exact (extend) |
| `server-core/src/transport/session.rs` (modify) | transport/session | pub-sub push | `session.rs` volume/apps/clip `select!` branches | exact |
| `server-core/src/transport/mod.rs` (modify) | deps struct | — | `ServerDeps` volume/apps/clip fields | exact |
| `server-core/src/codec/json.rs` (modify) | codec | transform | `json.rs` `VolChangedPayload`/`Msg::VolChanged` | exact |
| `protocol/fixtures/input_blocked/*.json` (new) | test fixture | — | `protocol/fixtures/volume/01-vol-changed.json` | exact |

### Client half (Flutter)

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `lib/theme/tokens.dart` (new) | config/theme | — | palette consts in `hub_screen.dart` L45-49 | exact (consolidate) |
| `lib/settings/haptics.dart` (new) | provider/store | CRUD | `settings/sensitivity.dart` | exact |
| `lib/settings/scroll_direction.dart` (new) | provider/store | CRUD | `settings/sensitivity.dart` | exact |
| `lib/settings/settings_screen.dart` (new) | screen | request-response | `hub_screen.dart` `HubScreen` chrome | role-match |
| `lib/keyboard/keyboard_screen.dart` (new) | screen | request-response | `trackpad_screen.dart` (hosts KeyboardPanel) | role-match |
| `lib/widgets/quick_bar_scaffold.dart` (new) | widget/shell | — | `hub_screen.dart` `_HubTile`/Scaffold chrome | partial |
| `lib/widgets/keep_awake.dart` (new) | utility | — | `trackpad_screen.dart` L145/155 WakelockPlus | role-match |
| `lib/main.dart` (modify) | app shell/routing | — | `main.dart` `home:` + ThemeData | exact |
| `lib/hub/hub_screen.dart` (modify) | screen/registry | — | `hub_screen.dart` `kHubTiles`/`HubTileGrid` | exact |
| `lib/net/connection_service.dart` (modify) | service | pub-sub decode | `connection_service.dart` `_onFrame` arms | exact |
| `packages/remote_protocol/lib/src/json_codec.dart` (modify) | codec | transform | `json_codec.dart` `VolChangedMsg` | exact |
| ~15 haptic call sites (modify) | — | — | `HapticFeedback.lightImpact` injected callbacks | exact |

---

## Shared Patterns (cross-cutting — apply to multiple files)

### SHARED-A: Minor protocol amendment with golden fixtures (the `input.blocked` = proto 1.3 seam)

This is THE dominant server-side pattern. The `vol.changed` (1.1) and
`apps.changed`/`clip.changed` (1.2) additions are the exact precedent; the
`input.blocked` amendment (SRV-05/D-07) clones all five touchpoints:

1. **Payload + enum arm** — `server-core/src/codec/json.rs`. Copy `VolChangedPayload` (L143-147) → `InputBlockedPayload { reason: String }`; add `Msg::InputBlocked(...)` to the enum (after L271); add `"input.blocked" => Msg::InputBlocked(payload(p)?)` to the decode match (near L321) and `Msg::InputBlocked(pl) => ("input.blocked", val(pl))` to the encode match (near L387); add a `round_trip` test mirroring `round_trip_clip_family` (L558).
2. **Version bump** — `session.rs` L51: `SERVER_PROTO_VERSION` `"1.2"` → `"1.3"`; `SERVER_PROTO_MAJOR` (L52) unchanged (additive — 1.0-1.2 clients still accepted).
3. **Dart mirror** — `json_codec.dart`. Copy `VolChangedMsg` (L418-437) → `InputBlockedMsg`; add `'input.blocked' => InputBlockedMsg.fromPayload(p)` to the `decodeText` switch (L818).
4. **Golden fixture** — copy `protocol/fixtures/volume/01-vol-changed.json` (below) to `protocol/fixtures/input_blocked/01-input-blocked.json`, keeping the `future: "ignored"` unknown-field-dropped discipline. Both `fixture_test.dart` (Dart) and the Rust fixture test pick it up.

```json
// protocol/fixtures/volume/01-vol-changed.json — the fixture shape to clone
{ "wire":   { "t": "vol.changed", "p": { "value": 55, "muted": false, "future": "ignored" } },
  "expect": { "t": "vol.changed", "p": { "value": 55, "muted": false } } }
```

### SHARED-B: Authed-gated S→C watch push branch (session.rs `select!`)

**Source:** `server-core/src/transport/session.rs` L169-224 (the volume/apps/clip branches).
**Apply to:** the `input.blocked` push branch. Clone the volume branch exactly:

```rust
// session.rs L169-182 — the pattern the input.blocked branch copies verbatim
changed = volume.changed(), if volume_alive && ctx.auth_state == AuthState::Authed => {
    match changed {
        Ok(()) => {
            let state = *volume.borrow_and_update();
            if tx.send(vol_changed_frame(state)).await.is_err() {
                break 'read; // write task gone → session over
            }
        }
        Err(_) => volume_alive = false,
    }
}
```

The `input.blocked` branch adds a `blocked: watch::Receiver<u64>` param to `run_session` (mirror L88-91), a `blocked_alive` flag (mirror L121), an `input_blocked_frame(reason)` encoder (mirror `vol_changed_frame` L462-470), and the same authed-gate + `borrow_and_update` + `break 'read` discipline. **Note:** unlike volume there is NO after-auth snapshot (mirror apps/clip, not volume — the banner is a transition event, not a state prime).

The revoke branch (D-05) is a SIBLING `select!` arm on a `revoke: watch::Receiver<u64>` epoch: when it advances, check whether this session's auth hash still lives in `AuthManager.paired` and `break 'read` if gone — landing on the EXISTING straight-line CONN-07 cleanup (L308-319).

### SHARED-C: ServerDeps wiring (transport/mod.rs + listener.rs + main.rs)

**Source:** `transport/mod.rs` L62-87 (`ServerDeps` fields), `listener.rs` L23 + L46-60 (destructure + clone-per-connection + pass to `run_session`), `main.rs` L148-155 (assembly).
**Apply to:** new `conn_count`, `revoke`, and `blocked` receivers. Each is a `tokio::sync::watch::Receiver<_>` added as a `ServerDeps` field (mirror the `apps`/`clip` doc-comment style L78-86), destructured in `accept_loop` (L23), `.clone()`d per connection (L46-51), and threaded into the `run_session(...)` call (L60). `conn_count` is a `watch::Sender<usize>` the session bumps on Authed / decrements on cleanup — the shell thread's tooltip reads its `Receiver`.

### SHARED-D: Dedicated OS thread for blocking/COM work

**Source:** `main.rs` L54-84 (four `std::thread::spawn` + `mpsc`/`watch` channel pairs); `apps_thread.rs` L564-596 (`run_apps_thread`: `CoInitializeEx(MTA)` once, `recv_timeout` poll loop, `CoUninitialize` on exit).
**Apply to:** the shell thread (`shell/mod.rs`), the firewall self-test (`firewall.rs` — one-shot COM read), and the UIPI check inside `input_thread.rs`. The shell thread breaks the mold (winit event loop, not `mpsc` poll) but its SPAWN follows `main.rs` step 3x exactly: `let (tx, rx) = channel; std::thread::spawn(move || shell::run(...))`. Firewall/UIPI COM follows `apps_thread`'s `CoInitializeEx`/`.ok()`-drop-every-HRESULT/never-panic discipline.

### SHARED-E: Win32 process-token / integrity-level read (UIPI + firewall)

**Source:** `apps_thread.rs` `exe_path()` L265-287 — `GetWindowThreadProcessId` → `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` → query → `CloseHandle` on every path, `.ok()?` never panic.
**Apply to:** UIPI detection in `input_thread.rs` (SRV-05). Extend the chain with `OpenProcessToken(TOKEN_QUERY)` → `GetTokenInformation(TokenIntegrityLevel)`; compare the foreground window's integrity RID to ours. `OpenProcess` returning `ERROR_ACCESS_DENIED` is itself a higher-IL signal (Pitfall 6). Debounce to a transition and advance the `blocked` watch epoch. The RAII-by-hand handle discipline (`let _ = CloseHandle(handle);` on every exit) is mandatory.

```rust
// apps_thread.rs L268-286 — the OpenProcess/token skeleton the UIPI check extends
let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
// ... query ...
let _ = CloseHandle(handle);
```

### SHARED-F: Cached-pref Riverpod store (haptics + scroll_direction)

**Source:** `lib/settings/sensitivity.dart` (whole file — the canonical two-half store+Notifier).
**Apply to:** `haptics.dart` (bool, default true) and `scroll_direction.dart` (enum/bool). Clone `SensitivityStore` (L38-66, shared_preferences, try/catch degrade-to-default) + `sensitivityStoreProvider` (L69) + `SensitivityNotifier` (L76-97, synchronous seed + async load + persist-through `set`) + `sensitivityProvider` (L101). The HOT-PATH CONTRACT (L21-24) is load-bearing for haptics: `hapticTick()` reads a cached bool, NEVER `ref.read` per tap.

```dart
// sensitivity.dart L76-97 — the Notifier shape haptics/scroll clone
class SensitivityNotifier extends Notifier<double> {
  @override
  double build() {
    unawaited(_load(ref.watch(sensitivityStoreProvider)));
    return kSensitivityDefault; // synchronous seed
  }
  Future<void> _load(SensitivityStore store) async { state = await store.load(); }
  void set(double value) {
    final clamped = value.clamp(kSensitivityMin, kSensitivityMax).toDouble();
    state = clamped;
    unawaited(ref.read(sensitivityStoreProvider).save(clamped)); // fire-and-forget
  }
}
```

### SHARED-G: Client `_onFrame` decode arm (input.blocked banner)

**Source:** `connection_service.dart` `_onFrame` L517-595 — the parked-snapshot + `_notify()` pattern; specifically the `VolChangedMsg`/`AppsChangedMsg`/`ClipChangedMsg` arms (L531-561).
**Apply to:** an `InputBlockedMsg` arm. Copy the `ClipChangedMsg` arm (L554-561): park a transient value in a new field (mirror `_clipSnapshot` L239 + the getter L332), `_notify()`, `return`. A `ClipSnapshot`-style value class (L163-176) wraps it if equality-dedup is wanted. S→C only — never routed to the driver, no payload logged. The banner widget (UI-SPEC §8) reads it off a `changes` ping and auto-dismisses via a `Timer` (~4s).

```dart
// connection_service.dart L554-561 — the decode arm to clone
if (msg is ClipChangedMsg) {
  _clipSnapshot = ClipSnapshot(msg.text);
  _notify();
  return;
}
```

---

## Pattern Assignments (per-file specifics)

### `server-windows/src/notify.rs` (extend) — exact analog to itself

**Analog:** `notify.rs` `notify_pin` L20-33. Add `notify_firewall_warning(hint: &str)` alongside it — same `Toast::new(Toast::POWERSHELL_APP_ID).title(...).text1(...).show()` shape (L24-28), same `is_err()` → generic `tracing::warn!` no-secret discipline (L29-32). D-06 firewall block is deliberately loud (tray warn state + this toast).

### `server-windows/src/autostart.rs` (new) — winreg precedent + auto-launch

**Analog:** `main.rs` `machine_guid()` L204-210 (the winreg read shape, if the `winreg` fallback is needed per Pitfall 7). Primary is `auto-launch` `AutoLaunchBuilder` (RESEARCH Code Examples). Wrap `enable()`/`disable()`/`is_enabled()` with `current_exe()` as the absolute `app_path`. Every fallible call `.ok()`/`?` — never panic the composition root.

### `server-windows/src/config.rs` (new) — serde structs + dirs

**Analog:** partial — `main.rs` L159-186 (env-var + fallback resolution precedence: `RC_PORT > config.port > DEFAULT_PORT`). New: `#[derive(Serialize, Deserialize, Default)]` `Config` + `[[paired]]` `PairedDeviceCfg` at `dirs::config_dir().join("RemoteControl/config.toml")`. Load path decodes each `hash` hex → `[u8;32]`, skips malformed (never panic — mirror `machine_guid`'s `unwrap_or_else` fallback L176-180), feeds `AuthManager::from_paired(...)`. All file I/O stays in server-windows (server-core keeps its zero-Windows-deps invariant).

### `server-core/src/auth/mod.rs` (modify) — extend AuthManager

**Analog:** `auth/mod.rs` (whole file). Today `paired_hashes: Vec<[u8;32]>` (L29). Phase 7 grows this to `paired: Vec<PairedDevice { hash, name, paired_at }>` (keep hash-only — never raw token, T-01-17, L27-28). Add: `from_paired(records)` constructor (mirror `new()` L42-48), `revoke(hash)` (removes + returns whether present), `paired_hashes()` accessor for the revoke-branch membership check, and a change-signal `watch::Sender<u64>` version bump on every mutation (the composition root subscribes and re-serializes config). `complete_pairing` (L67-73) grows a `name` param (assumption A7 — thread `hello.device` through). `verify_auth` (L93-97) stays but must return the MATCHING hash (for the session to record which hash authed it — D-05 revoke needs this). Existing tests (L100-153) stay green; add revoke round-trip tests.

### `lib/theme/tokens.dart` (new) — palette consolidation

**Analog:** `hub_screen.dart` L44-49 (the copy-pasted `const Color _bg/_surface/_hairline/_text/_muted` block — duplicated across EVERY screen file, D-12). Extract to one file exporting these consts + `_accent = Color(0xFF4C8DFF)` + `error = Color(0xFFFF6B6B)` + a `buildAppTheme()` returning the `ThemeData` currently inline in `main.dart` L93-100. Every screen deletes its local block and imports from here. A grep-guard test (no per-file palette literal) is a UI-02 acceptance check (UI-SPEC L33).

### `lib/main.dart` (modify) — dashboard-as-home reroute

**Analog:** `main.dart` L90-103. Change `home: const DeviceListScreen()` (L101) → `home: const HubScreen()` (D-08); replace the inline `ThemeData` (L93-100) with `buildAppTheme()` from tokens.dart. The device list becomes the add/switch-PC screen reached from the dashboard. Launch-kick (L65-86) + resume wiring (L44-46) stay verbatim.

### `lib/hub/hub_screen.dart` (modify) — 8 tiles + uniform 2×4 grid + offline

**Analog:** `hub_screen.dart` `kHubTiles` L73-116 + `HubTileGrid` L120-174.
- **8th tile (D-09):** insert `HubTileSpec(label: 'Keyboard', icon: Icons.keyboard, builder: (_) => const KeyboardScreen())` at index 1 (after Trackpad) and reorder to Trackpad, Keyboard, Media, Apps, Clipboard, Power, Presenter, Browser.
- **Uniform 2×4 (UI-SPEC §1, Pitfall 9):** `HubTileGrid.build` L134-137 currently renders `tiles.first` full-width. Delete the full-width primary `SizedBox(height: 96, ...)` row; chunk ALL tiles into 2-column `_halfTile` rows (the loop L141-156 already does this — start it at `i = 0` and drop the special-cased first row). "chunks any list" — small layout change, not a rewrite.
- **Offline-disabled (D-08/UI-SPEC §2):** drive tile `onTap = null` off `connectionStatusProvider`/`ChipStatus` (already watched L250) when offline; keep tiles visible, muted. Settings gear + add/switch-PC stay reachable.
- **Gear icon (D-11):** add `IconButton(Icons.settings)` to the AppBar `actions` (L267-272) that pushes `SettingsScreen`, always tappable.

### `lib/widgets/keep_awake.dart` (new) — ref-counted wrapper

**Analog:** `trackpad_screen.dart` L145/155 + `presenter_screen.dart` L88/95 (bare `WakelockPlus.enable()`/`disable()` in initState/dispose). Pitfall 8: the new quick-bar nav path (`Presenter → quick-bar → Trackpad → back`) makes `Trackpad.dispose()` globally disable while Presenter still wants it. New helper holds an int of active requesters: `acquire()` enables only 0→1, `release()` disables only 1→0. Both screens route through it instead of the raw global flag. This is the concrete deliverable of the D-14 "audit."

### `lib/widgets/quick_bar_scaffold.dart` (new) — shared shell

**Analog:** partial — `hub_screen.dart` Scaffold chrome (L253-292) for the surface/hairline styling. `QuickBarScaffold({required Widget body, bool showQuickBar = true})`: `body` + a 56px bottom bar (`#16181D` surface, top `#2A2D34` hairline) with one centered `Icons.touch_app` + "Trackpad" button in `#4C8DFF` accent → `Navigator.push(TrackpadScreen)`. Tap fires `hapticTick()`. `TrackpadScreen` passes `showQuickBar: false`. Every other tool screen wraps its body.

---

## No Analog Found

| File | Role | Data Flow | Reason | Planner Action |
|------|------|-----------|--------|----------------|
| `server-windows/src/shell/tray.rs` | tray UI | event-driven | No winit/tray-icon code exists yet — first win32-event-loop UI in the tree | Use RESEARCH Pattern 1 (tray-icon 0.24 + winit 0.30 `with_any_thread`, `StartCause::Init` create). Spawn follows `main.rs` step-3x thread idiom (SHARED-D). |
| `server-windows/src/shell/settings.rs` | egui window | event-driven | No egui/GUI code exists yet | Use RESEARCH Pattern 1 (egui-on-winit, NOT eframe — Pitfall 4). On-demand window on the shell loop. |
| `server-windows/src/firewall.rs` | detection | request-response | No `INetFwPolicy2` COM code exists (apps_thread is the closest COM shape) | COM discipline from `apps_thread` (SHARED-D/E); firewall API from RESEARCH Pitfall 5. Read-only, unprivileged. |

The shell topology (where the winit loop lives, how tokio ↔ shell thread talk
over `EventLoopProxy` + channels) is the one genuinely novel piece — RESEARCH
recommends a ~½-day spike (Open Q2) before committing the plan.

---

## Metadata

**Analog search scope:** `server/server-windows/src/`, `server/server-core/src/`, `app/remote_control/lib/`, `app/packages/remote_protocol/lib/`, `protocol/fixtures/`
**Files scanned (read in full):** main.rs, notify.rs, apps_thread.rs, input_thread.rs, session.rs, listener.rs, transport/mod.rs, auth/mod.rs, codec/json.rs, sensitivity.dart, hub_screen.dart, connection_service.dart, main.dart, json_codec.dart + targeted greps of trackpad/presenter screens and the volume fixture
**Pattern extraction date:** 2026-07-12
