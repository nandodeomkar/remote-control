---
phase: 7
slug: server-shell-dashboard-polish
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-07-12
---

# Phase 7 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
> Sourced from 07-RESEARCH.md "Validation Architecture". House style: pure
> IO-free predicates/FSMs factored out of the OS threads + injected seams with
> unit tests; shared golden fixtures for the wire contract; on-device UAT for the
> OS-registration / input-injection / tray behaviors that are not CI-testable.
> Task/Plan/Wave IDs are TBD until the planner runs — this file is created at
> plan-phase step 5.5 (before planning) so the Nyquist map is locked to research.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework (Rust)** | `cargo test` across the workspace (`server-core` integration + `server-windows` pure-predicate units); optional `cargo-nextest` for faster runs |
| **Framework (Dart)** | `flutter_test` (widget + pure-logic) / `dart test` (remote_protocol golden fixtures) |
| **Config file** | none — Cargo workspace `server/` + `app/remote_control` + `app/packages/remote_protocol` cover both langs |
| **Quick run command** | `cd server && cargo test -p server-core <module>` / `cd server && cargo test -p server-windows <module>` / `cd app/remote_control && flutter test test/<file>` |
| **Full suite command** | `cd server && cargo test --workspace` + `cd app/packages/remote_protocol && dart test` + `cd app/remote_control && flutter test` |
| **Estimated runtime** | ~30s (Dart) + ~20s (Rust); `--ignored` OS-state tests (autostart/firewall) run on demand |

---

## Sampling Rate

- **After every task commit:** Run the touched side — `cargo test -p <crate> <module>` (server task) or single `flutter test test/<file>` (client task). < 30s.
- **After every plan wave:** Run full `cargo test --workspace` + both Dart suites (`dart test` remote_protocol fixtures + `flutter test` app).
- **Before `/gsd-verify-work`:** Full suites green PLUS the on-device UAT checklist below (tray + Explorer-restart, reboot autostart, firewall toggle, elevated-window banner, dashboard/quick-bar/haptics/keep-awake).
- **Max feedback latency:** ~30 seconds (per-side quick run).

---

## Per-Task Verification Map

*(Requirement-level map from 07-RESEARCH.md; planner assigns final Task/Plan/Wave IDs. Threat refs from the RESEARCH Security Domain / ASVS L1 table.)*

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| TBD | TBD | TBD | SRV-03 | T-01-08 hash-only | `config.toml` serde round-trip; malformed-safe load (bad hex hash skipped, out-of-range port clamped, missing fields defaulted → defaults, never panic); **hash hex only, never a raw token field** | unit | `cargo test -p server-windows config` | ❌ W0 (`config.rs` + tests) | ⬜ pending |
| TBD | TBD | TBD | SRV-03 | — | `AuthManager::from_paired` / `revoke` / `complete_pairing(name)` + paired-set change signal | unit | `cargo test -p server-core auth` | ⚠️ extend (`auth/mod.rs`) | ⬜ pending |
| TBD | TBD | TBD | SRV-03 / D-03 | — | smart-startup: ≥1 paired ⇒ silent; zero paired ⇒ `begin_pairing()` + notify | unit | `cargo test -p server-windows startup` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | SRV-03 / D-05 | V3 session mgmt | revoke drops a **live authed** session → reconnect returns `authFail` → client re-pairs | integration (fake-ws client, existing suite pattern) | `cargo test -p server-core` (transport) | ⚠️ extend transport integration | ⬜ pending |
| TBD | TBD | TBD | SRV-01 | — | `conn_count` watch increments on Authed / decrements on cleanup | unit/integration | `cargo test -p server-core session` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | SRV-01 | — | pause toggle drops input while keeping the connection alive (existing pause seam) | integration | `cargo test -p server-core` (extend pause test) | ⚠️ extend | ⬜ pending |
| TBD | TBD | TBD | SRV-01 | I/D tooltip | tray appears / tooltip shows device **count** (not names) / quit / **Explorer-restart survival** | manual | on-device UAT (roadmap SC1) | manual | ⬜ pending |
| TBD | TBD | TBD | SRV-02 | V4 HKCU-only | autostart enable/disable/is_enabled round-trip (HKCU `...\Run`, absolute exe path, no admin) | integration (writes real HKCU — guard + cleanup) | `cargo test -p server-windows autostart -- --ignored` | ❌ W0; reboot = manual | ⬜ pending |
| TBD | TBD | TBD | SRV-04 | — | bind-in-use (`AddrInUse`) surfaces a distinct warning, **not** a crash (today `main.rs` `?`-propagates) | unit/integration | `cargo test -p server-windows firewall` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | SRV-04 | V4 read-only fw | firewall self-test (`INetFwPolicy2`) runs without panic; inbound-blocked ⇒ warn; query is **read-only** (never modifies a rule) | smoke + manual | on-device (toggle a firewall rule) | manual | ⬜ pending |
| TBD | TBD | TBD | SRV-05 | V5 fwd-compat | `input.blocked` proto-1.3 golden fixture decodes identically Rust + Dart (unknown fields ignored) | unit (contract fixture) | `cargo test -p server-core codec` + `dart test` (remote_protocol) | ❌ W0 (fixture + both codecs) | ⬜ pending |
| TBD | TBD | TBD | SRV-05 | I/D authed-gate | `input.blocked` push rides the **authed-gated** `select!` branch (no pre-auth leak — clone `vol.changed` gate) | integration | `cargo test -p server-core input_blocked_push` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | SRV-05 | — | banner shows on `input.blocked`, auto-dismisses (Timer) | widget | `flutter test test/uipi_banner_test.dart` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | SRV-05 | — | integrity-level detection fires on an elevated foreground window (proactive IL compare / `ACCESS_DENIED`) | manual | on-device (run an admin app, attempt input) | manual | ⬜ pending |
| TBD | TBD | TBD | UI-01 | — | home is `HubScreen`; 8 tiles present in order (Trackpad, Keyboard, Media, Apps, Clipboard, Power, Presenter, Browser) | widget | `flutter test test/hub_tiles_test.dart` | ⚠️ extend | ⬜ pending |
| TBD | TBD | TBD | UI-01 | — | offline ⇒ tiles disabled except Settings | widget | `flutter test test/hub_offline_test.dart` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | UI-01 | — | quick-bar present on every tool screen, hidden/no-op on Trackpad | widget | `flutter test test/quick_bar_test.dart` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | UI-02 | — | haptics gate honors the pref (on ⇒ fires, off ⇒ silent); cached read on the hot path | unit | `flutter test test/haptics_gate_test.dart` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | UI-02 | — | keep-awake ref-count: enable only on 0→1, disable only on 1→0 (Pitfall 8 — quick-bar nav path) | unit | `flutter test test/keep_awake_test.dart` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | UI-02 | — | theme tokens single-source (no per-file palette literal regressions) | unit/lint | grep-guard test or analyzer | ❌ W0 (optional) | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky.*

---

## Wave 0 Requirements

- [ ] `server-windows/src/config.rs` (+ tests) — serde round-trip, malformed-safe load, port precedence (`RC_PORT` env > `config.port` > `DEFAULT_PORT`), **assert no raw-token field**.
- [ ] `server-core/src/auth/mod.rs` — extend for `from_paired` / `revoke` / `complete_pairing(name)` + a paired-set change signal (`watch` version bump).
- [ ] `server-core/src/transport/session.rs` — `conn_count` watch inc/dec + revoke branch (break on revoked hash) + `input.blocked` authed-gated push branch tests.
- [ ] New golden fixtures — `protocol/fixtures/input_blocked/*.json` decoded by Rust (`codec/json.rs`) + Dart (`remote_protocol/json_codec.dart`); bump `SERVER_PROTO_VERSION` to `1.3` (additive minor) with the shared version assertion updated in lockstep.
- [ ] `app` widget tests — hub offline state, quick-bar presence/hide-on-trackpad, UIPI banner auto-dismiss.
- [ ] `app` unit tests — haptics gate (cached pref), keep-awake ref-count helper (0→1 / 1→0).
- [ ] Firewall + autostart integration tests behind `#[ignore]` (touch real OS state — HKCU Run key, firewall query) with guard + cleanup.
- [ ] Framework install: none — cargo + `flutter_test` + `dart test` already in use.

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Tray presence + Explorer-restart survival | SRV-01 | Tray host / `TaskbarCreated` re-registration is not CI-testable | Launch server → tray icon + tooltip (device count) present; `taskkill /f /im explorer.exe && start explorer` → icon returns; Pause toggles input off/on; Quit exits cleanly |
| Autostart across a reboot | SRV-02 | Requires a real reboot + login | Enable autostart in settings → reboot → server starts silently with Windows; toggle off → reboot → server does NOT start; confirm the HKCU Run entry is removed |
| Firewall-blocked warning | SRV-04 | Needs a real firewall rule (ideally a second host to fully confirm inbound block) | Add a firewall rule blocking the WS port (or set inbound default-block) → start server → tray shows warning state + a Windows notification with a fix hint + a persistent settings hint |
| UIPI elevated-window banner | SRV-05 | UIPI drops are invisible to `SendInput`; needs a real higher-integrity foreground | Run an app as administrator (or open an elevated Task Manager / a UAC prompt) → attempt cursor/keys from the phone → phone shows the transient "Can't control this window — it's running as administrator" banner that auto-dismisses |
| Port change apply | SRV-03 | Live re-bind is out of scope (restart-required, Open Q3) | Change port in settings → prompt says "restart to apply" → restart → server binds the new port, phone rediscovers/reconnects |
| Dashboard + quick-bar + keep-awake feel | UI-01 / UI-02 | Real device navigation + screen-wake behavior | 8 tiles render in order; offline disables all but Settings; quick-bar Trackpad button on every non-Trackpad screen; navigate hub→Presenter→(quick-bar)→Trackpad→back and confirm the screen stays awake throughout (ref-count holds); toggle haptics off → taps are silent |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending (planner to map final Task/Plan/Wave IDs, then flip `nyquist_compliant`)
