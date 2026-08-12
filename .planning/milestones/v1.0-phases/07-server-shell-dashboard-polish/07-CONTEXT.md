# Phase 7: Server Shell, Dashboard & Polish - Context

**Gathered:** 2026-07-12
**Status:** Ready for planning

<domain>
## Phase Boundary

Turn the working system into a daily-driver product. Two halves:

**Server shell (SRV-01..05):** the `server-windows` binary grows a tray shell —
tray icon + menu (settings / pause-input / quit), autostart toggle, a settings
window (device name, port, clipboard-sync, paired-device list + revoke),
persistent paired-token storage, a startup firewall self-test warning, and a
UIPI (elevated-window) input-blocked status pushed to the phone.

**App polish (UI-01/02):** the Flutter client gets its final dashboard identity —
dashboard-as-home with the 8-tool tile grid, a persistent trackpad quick-bar on
every screen, an app-side Settings screen, a haptics toggle, one consolidated
dark-minimal theme, and audited keep-awake.

**In scope:** everything in the roadmap Phase-7 goal + 5 success criteria
(SRV-01..05, UI-01, UI-02).

**Out of scope (own milestones / deferred):** MSI installer + firewall-rule
setup (v2 FEAT-04), Play Store release / crash reporting (v2 FEAT-05),
user-selectable accent presets (user chose fixed blue), a live "peek" trackpad
overlay on tool screens (user chose a nav button).

</domain>

<decisions>
## Implementation Decisions

### Pairing lifecycle & multi-device (SRV-03) — closes the folded todo
- **D-01:** Paired token hashes **persist** across process runs in a server
  config file at `%APPDATA%/RemoteControl/config.toml` (stack-locked: `toml` +
  `dirs` + `serde`). This is the mechanism that makes revoke, multi-device, and
  re-pair real — today tokens are in-memory and the server pairs at most one
  device per run.
- **D-02:** Pairing a **new** device is **on-demand**: a "Pair new device" action
  in BOTH the tray menu AND the settings window opens a fresh PIN window
  (`begin_pairing()`) on demand. This decouples the PIN lifecycle from a single
  process run (revisit the `break`-on-`is_paired` in `main.rs:77` and the
  `verify` → `active = None` in `pin.rs:126`).
- **D-03:** **Smart startup** — auto-open a PIN window at startup ONLY when zero
  devices are paired. If ≥1 device is already paired, start silent (no PIN toast
  every boot). New devices come in via the D-02 on-demand path.
- **D-04:** Multiple paired phones are allowed (spec already permits two phones
  controlling concurrently); the settings paired-device list manages them.
- **D-05:** **Revoke** drops the revoked phone's live session **immediately** →
  server returns `authFail` → phone clears its token and returns to pairing with
  an explanation (spec-locked behavior; no silent retry loop).

### Failure surfacing (SRV-04 / SRV-05)
- **D-06 (firewall, SRV-04):** startup self-test verifies the port is actually
  bindable/listenable; if firewall-blocked → **tray icon warning state + a
  Windows notification with a one-line fix hint** at startup, plus a persistent
  hint in the settings window. Loud on purpose — a blocked port breaks all
  connectivity.
- **D-07 (UIPI, SRV-05):** when input is dropped because the foreground window is
  elevated, the phone shows a **transient, non-blocking banner** ("Can't control
  this window — it's running as administrator") that auto-dismisses. Contextual,
  not a permanent header chip. *(Detection mechanism + the phone-ward status
  message shape → researcher; likely a minor protocol amendment reusing the
  authed-gated push seam, mirroring the `vol.changed` 1.1 / apps 1.2 pattern.)*

### App dashboard identity (UI-01)
- **D-08 (home model):** the **Dashboard (8-tile grid) is home**, with an offline
  state (tiles disabled except Settings when the PC is offline — spec-locked).
  The current device-list becomes the **add/switch-PC** screen, reachable from the
  dashboard (today `main.dart` makes the device-list the home — this reroute lands
  here).
- **D-09 (8 tiles):** add the **Keyboard** tile and reorder to the spec grid:
  **Trackpad, Keyboard, Media, Apps, Clipboard, Power, Presenter, Browser**
  (today `kHubTiles` has 7 tiles, no Keyboard, in a different order). Keyboard is
  currently a panel inside the trackpad screen — planner picks the least-rework
  path to a Keyboard tile entry.
- **D-10 (quick-bar, UI-01):** the persistent bottom quick-bar is a **single
  Trackpad shortcut button**; tap pushes the full Trackpad screen. On the Trackpad
  screen itself it is hidden/no-op (no redundancy). Visible on every other screen.
  *(Not a live mini-pad — that richer "peek pad" was explicitly deferred.)*

### App settings & theme (UI-02)
- **D-11 (settings entry):** an **app-bar gear icon** on the dashboard (reachable
  when offline). The app Settings screen holds: paired PCs, trackpad sensitivity
  (existing `settings/sensitivity.dart` seam), scroll direction, haptics toggle,
  and accent (display-only — fixed).
- **D-12 (accent):** **fixed blue `#4C8DFF`.** Phase-7 work is **consolidating**
  the palette consts (`_bg #0E0F12`, `_surface #16181D`, `_hairline #2A2D34`,
  `_text #E6E8EB`, `_muted #6B7280`, `_accent #4C8DFF`, error `#FF6B6B`) —
  currently copy-pasted into every screen file — into one shared theme/tokens
  source. No accent picker.
- **D-13 (haptics toggle, UI-02):** add a haptics-enabled setting (default ON,
  `shared_preferences`) and gate the existing `HapticFeedback.lightImpact()` call
  sites (apps / browser / clipboard / keyboard / media / trackpad screens) behind
  it.
- **D-14 (keep-awake, UI-02):** already implemented via `WakelockPlus` in the
  trackpad and presenter screens — Phase-7 work is an **audit only** (confirm no
  leak past those screens), not new plumbing.

### Claude's Discretion
- Settings-window toolkit = `eframe`/`egui` on the same `winit` event loop as
  `tray-icon` (stack-locked, CLAUDE.md); exact window layout.
- Tray icon asset + pause-input **visual feedback** (icon state while paused);
  surviving an Explorer restart (tray re-registration).
- Autostart mechanism = `auto-launch` crate / HKCU `...\Run` key (stack-locked);
  the settings toggle wiring.
- `config.toml` schema (device name, port, autostart flag, clip-sync flag, paired
  token hashes + device metadata).
- Whether a **port change** in settings re-binds the listener live or is
  restart-required — research flag.
- Quick-bar exact height/placement and the hide-on-trackpad-screen mechanic.
- Theme file structure (e.g. `lib/theme/app_theme.dart`) and how the shared
  tokens replace the per-file consts.
- Scroll-direction setting plumbing into the trackpad driver.
- AUMID registration for a proper tray/notification identity (Phase-5 used
  `POWERSHELL_APP_ID` as an interim).

### Folded Todos
- **Server supports only one pairing per process run** (`.planning/todos/pending/2026-07-09-server-one-pairing-per-run.md`)
  — the server pairs at most one device per run (in-memory token, PIN-refresh loop
  `break`s on `is_paired`, `verify` clears the active window). Folded: **D-01**
  (persistent token store) + **D-02/D-03** (on-demand `begin_pairing()` from
  tray/settings, smart startup) close it. This is the mechanism SRV-03 revoke +
  multi-device depend on.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Design spec & requirements (locked)
- `docs/superpowers/specs/2026-07-07-remote-control-design.md` — the authority for
  this phase: tray menu (§tray-icon: tooltip = connected device count; settings /
  pause-input / quit), settings-window contents, autostart (registry Run key),
  the 2×4 dashboard grid (Trackpad, Keyboard, Media, Apps, Clipboard, Power,
  Presenter, Browser), the persistent trackpad quick-bar, the error-handling table
  rows (firewall self-test, UIPI, revoked token, two-phones, server-killed →
  offline dashboard), and app-settings contents (paired PCs, sensitivity, scroll
  direction, haptics). MUST read.
- `.planning/REQUIREMENTS.md` — SRV-01..05, UI-01/02 rows + traceability.
- `.planning/ROADMAP.md` §"Phase 7: Server Shell, Dashboard & Polish" — goal + 5
  success criteria.

### Server — where the shell wires in
- `server/server-windows/src/main.rs` — composition root; `DEFAULT_PORT = 17777`
  (overridable via `RC_PORT`, becomes the config-file port); `main.rs:77` PIN
  refresh loop that `break`s on `is_paired` (D-02/D-03 rework); where tray /
  settings / autostart / config load must wire in around `server_core::run`.
- `server/server-core/src/auth/pin.rs` — PIN lifecycle; `verify` sets
  `self.active = None` on success (`pin.rs:126`); the on-demand re-pairing hook.
- `server/server-core/src/transport/session.rs` — `authFail` reason emission
  (`session.rs:269` `NoPairing` branch), the revoke/disconnect + session-cleanup
  path; the authed-gated S→C push seam a UIPI status message would reuse.
- `server/server-core/src/auth/` — `AuthManager` + SHA-256 token hashing; the
  persist-hashes-to-config target.
- `server/server-windows/src/notify.rs` — existing WinRT toast used for the PIN;
  firewall-blocked + PIN notifications extend it.

### App — where the dashboard/polish lands
- `app/remote_control/lib/main.dart` — app shell + home (device-list is home
  today; D-08 dashboard-as-home reroute lands here), the `#4C8DFF` seed
  `ThemeData` (D-12 consolidation anchor), launch/resume wiring.
- `app/remote_control/lib/hub/hub_screen.dart` — `kHubTiles` registry (D-09 add
  Keyboard + reorder), the per-file palette consts to consolidate (D-12), the grid
  that gains an offline/disabled state (D-08).
- `app/remote_control/lib/screens/device_list_screen.dart` +
  `screens/connection_copy.dart` — device-list → add/switch-PC screen; pairing
  copy incl. the `noPairing` reason (see deferred todo).
- `app/remote_control/lib/settings/sensitivity.dart` — the existing settings seam
  the app Settings screen (D-11) extends.
- `app/remote_control/lib/trackpad/trackpad_screen.dart` &
  `presenter/presenter_screen.dart` — `WakelockPlus` keep-awake precedent (D-14
  audit).

### Folded-todo source
- `.planning/todos/pending/2026-07-09-server-one-pairing-per-run.md` — folded
  (D-01/02/03).

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **PrefsKv / shared_preferences** seam (device store, keyboard rowGroup,
  clipboard history) — client home for the haptics toggle (D-13), scroll-direction
  (D-11), and any non-secret app setting. Secrets (tokens) stay in
  `flutter_secure_storage`.
- **Server persistence stack** — `toml` + `dirs` + `serde` for
  `config.toml` (D-01); `auto-launch` for the autostart toggle (SRV-02);
  `tray-icon` + `eframe`/`egui` + `winit` for the shell (all stack-locked in
  CLAUDE.md — note the pitfall: the tray must be created on the winit loop thread,
  `StartCause::Init` timing).
- **`HapticFeedback.lightImpact()` call sites** — already spread across apps /
  browser / clipboard / keyboard / media / trackpad screens; D-13 gates them all
  behind one setting rather than adding new calls.
- **`WakelockPlus`** — already enabled/disabled in trackpad + presenter
  (`initState`/`dispose`); D-14 is an audit, not new code.
- **`kHubTiles`** — data-driven ordered tile registry; D-09 inserts the Keyboard
  tile and reorders with no grid-structure change (grid chunks any list).
- **Authed-gated S→C push seam** (`session.rs` `select!` on `AuthState::Authed`,
  `vol.changed` / `apps.changed` / `clip.changed` precedent) — the UIPI status
  push (D-07) reuses this exact discipline.

### Established Patterns
- **Dedicated OS thread for blocking/COM work** (input / audio / apps / clip
  threads in `server-windows`) — any firewall self-test or UIPI-detection Win32
  work follows the same "don't block a tokio worker" rule.
- **Minor protocol amendment with fixtures** — the `vol.changed` 1.1 and apps 1.2
  bumps are the precedent for the UIPI status message (D-07) if one is needed.
- **Palette-as-consts per file** is the current (duplicated) pattern — D-12
  deliberately replaces it with one shared source.

### Integration Points
- `main.rs` `Executors`/`ServerDeps` assembly — tray, settings window, autostart,
  config load, and the firewall self-test all bolt on here around
  `server_core::run` (Phase-5/6 executor-wiring precedent).
- Config load at startup feeds device name + port + autostart + clip-sync + paired
  token hashes into `AuthManager`/beacon/listener.
- Flutter: dashboard-as-home reroute in `main.dart`; the quick-bar wraps every
  routed screen (a shared `Scaffold`/shell wrapper); the gear-icon Settings screen
  reads/writes shared_preferences.

</code_context>

<specifics>
## Specific Ideas

- Quick-bar is a **shortcut to** the trackpad, not a live pad — one button, tap →
  full Trackpad screen, hidden on the Trackpad screen itself (D-10).
- Firewall warning is deliberately loud (tray state + notification) because a
  blocked port breaks everything (D-06).
- UIPI message is contextual and transient — "it's running as administrator" —
  not a permanent status (D-07).
- Startup should NOT toast a PIN every boot once a device is paired (D-03).
- Accent stays a single fixed blue `#4C8DFF`; the win is consolidating the
  scattered palette consts, not adding a picker (D-12).

</specifics>

<deferred>
## Deferred Ideas

- **User-selectable accent presets** — the design-spec settings list an accent
  color, but PROJECT locks blue and the user chose fixed (D-12). Revisit only if a
  theming milestone opens.
- **Live "peek" trackpad overlay** on tool screens — the richer quick-trackpad
  hybrid; user chose the nav button (D-10). Candidate for a later UX pass.

### Reviewed Todos (not folded)
- **Split the overloaded `noPairing` authFail reason** (`.planning/todos/pending/2026-07-09-nopairing-reason-overloaded-copy.md`)
  — reviewed, **not folded** (user left it out of scope). Note for the planner:
  it lives in the *same* `session.rs:269` / `pin.rs` / `connection_copy.dart` code
  path that the folded one-pairing-per-run rework (D-02) touches, so it may be
  cheap to close opportunistically — but it is not a Phase-7 commitment.

</deferred>

---

*Phase: 7-Server Shell, Dashboard & Polish*
*Context gathered: 2026-07-12*
