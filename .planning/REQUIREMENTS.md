# Requirements: Remote Control

**Defined:** 2026-07-07
**Core Value:** Phone controls the laptop over WiFi with zero friction: instant cursor response, full keyboard, and the control-center extras — all free.

## v1 Requirements

### Connection & Pairing

- [x] **CONN-01**: User sees laptops on the same LAN appear automatically in a device list (UDP beacon discovery)
- [x] **CONN-02**: User pairs with a laptop once via 6-digit PIN shown on the PC (60s expiry, 5 attempts, lockout)
- [x] **CONN-03**: Paired phone reconnects silently using challenge-response auth — the token never crosses the wire
- [x] **CONN-04**: Connection recovers automatically after WiFi drops or PC IP changes (backoff + beacon re-listen)
- [x] **CONN-05**: User can connect by typing IP:port manually when discovery fails (AP isolation, firewall, VPN adapters)
- [ ] **CONN-06**: User sees connection status and live latency in the app header
- [x] **CONN-07**: Server releases all held keys/buttons when a session ends (no phantom input after mid-drag disconnect)

### Trackpad

- [x] **PAD-01**: User moves the PC cursor with one finger — velocity-based acceleration, sub-pixel accumulation on server
- [x] **PAD-02**: User clicks via tap (left), two-finger tap (right), and on-screen L/M/R buttons
- [x] **PAD-03**: User scrolls with two fingers — momentum with instant touch-stop
- [x] **PAD-04**: User drags via long-press drag with drag lock for screen-edge drags
- [x] **PAD-05**: Cursor response is visually instant on same LAN (<30ms end-to-end; TCP_NODELAY both ends, raw pointer events)

### Keyboard

- [ ] **KEY-01**: User types with the phone keyboard including IME autocomplete and backspace (diff-op text messages)
- [ ] **KEY-02**: User can press F1–F12, numpad, and nav cluster keys (Home/End/PgUp/PgDn/Del/Esc/Tab, arrows)
- [ ] **KEY-03**: User can hold sticky modifiers (Ctrl/Alt/Shift/Win) to send combos like Ctrl+Alt+Del, Win+D
- [ ] **KEY-04**: Held keys autorepeat correctly (server-side key-down/hold, not client tap-spam)

### Media

- [ ] **MED-01**: User can play/pause, next, previous system-wide
- [ ] **MED-02**: User sets absolute volume via slider and mute; slider stays accurate via server volume-state push (on connect and external change)

### Power

- [ ] **PWR-01**: User can lock the PC behind slide-to-confirm
- [ ] **PWR-02**: User can sleep the PC (SetSuspendState) behind slide-to-confirm
- [ ] **PWR-03**: User can restart or shut down the PC behind slide-to-confirm plus server-side confirm message

### Apps

- [ ] **APPS-01**: User sees running windows and can focus or close them
- [ ] **APPS-02**: User can launch pinned favorite apps
- [ ] **APPS-03**: App list stays current via server push (apps.changed)

### Clipboard

- [ ] **CLIP-01**: User can send phone clipboard to PC
- [ ] **CLIP-02**: User can fetch PC clipboard to phone
- [ ] **CLIP-03**: Auto-sync works within platform limits — PC→phone pushed live, phone→PC synced on app resume (Android 10+ restriction), echo suppression via content hash
- [ ] **CLIP-04**: User sees last-5 clipboard history

### Presenter

- [ ] **PRES-01**: User can drive slides — next/prev, start/end show, blank screen
- [ ] **PRES-02**: User sees elapsed presentation timer

### Browser

- [ ] **BROW-01**: User can send browser controls — back/forward, new/close tab, refresh, zoom in/out (key macros on focused browser)

### Server Shell

- [ ] **SRV-01**: Server lives in the tray with status tooltip, pause-input toggle, and quit
- [ ] **SRV-02**: Server can auto-start with Windows (toggle)
- [ ] **SRV-03**: User manages device name, port, paired-device revoke, and clipboard sync in a settings window
- [ ] **SRV-04**: Server warns in tray when its port is blocked by firewall (startup self-test)
- [ ] **SRV-05**: Phone shows a clear status when input is blocked by an elevated window (UIPI) instead of failing silently

### App UI

- [ ] **UI-01**: Dashboard home with tool tiles plus persistent trackpad quick-bar on every screen
- [ ] **UI-02**: Dark minimal theme (#0E0F12, blue accent), haptic feedback toggle, keep-awake during trackpad/presenter

## v2 Requirements

### Transport

- **TRAN-01**: UDP channel for mouse deltas if WebSocket jitter shows up in real use

### Features

- **FEAT-01**: Gyro/air mouse mode
- **FEAT-02**: File transfer
- **FEAT-03**: Home-screen widgets / quick tiles
- **FEAT-04**: Windows installer (MSI/Inno) with firewall rule setup
- **FEAT-05**: Play Store release (signing, crash reporting, privacy policy, onboarding)

### Platforms

- **PLAT-01**: iOS client (same Flutter codebase)
- **PLAT-02**: Linux server (new executor impls on server-core)
- **PLAT-03**: macOS server

## Out of Scope

| Feature | Reason |
|---------|--------|
| Bluetooth / USB transport | WiFi LAN covers the use case; second codepath without payoff |
| Internet/remote access (WAN) | LAN-only by security design; never internet-exposed |
| Voice control, macros/scripting | Not needed by owner; complexity without core value |
| Multi-monitor spanning controls | v1 treats desktop as one surface; revisit on real need |
| Wake-on-LAN | PC must be awake to run server anyway; marginal value |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| CONN-01 | Phase 3 | Complete |
| CONN-02 | Phase 3 | Complete |
| CONN-03 | Phase 3 | Complete |
| CONN-04 | Phase 3 | Complete |
| CONN-05 | Phase 3 | Complete |
| CONN-06 | Phase 3 | Pending |
| CONN-07 | Phase 1 | Complete |
| PAD-01 | Phase 4 | Complete |
| PAD-02 | Phase 4 | Complete |
| PAD-03 | Phase 4 | Complete |
| PAD-04 | Phase 4 | Complete |
| PAD-05 | Phase 2 | Complete |
| KEY-01 | Phase 4 | Pending |
| KEY-02 | Phase 4 | Pending |
| KEY-03 | Phase 4 | Pending |
| KEY-04 | Phase 4 | Pending |
| MED-01 | Phase 5 | Pending |
| MED-02 | Phase 5 | Pending |
| PWR-01 | Phase 5 | Pending |
| PWR-02 | Phase 5 | Pending |
| PWR-03 | Phase 5 | Pending |
| APPS-01 | Phase 6 | Pending |
| APPS-02 | Phase 6 | Pending |
| APPS-03 | Phase 6 | Pending |
| CLIP-01 | Phase 6 | Pending |
| CLIP-02 | Phase 6 | Pending |
| CLIP-03 | Phase 6 | Pending |
| CLIP-04 | Phase 6 | Pending |
| PRES-01 | Phase 5 | Pending |
| PRES-02 | Phase 5 | Pending |
| BROW-01 | Phase 5 | Pending |
| SRV-01 | Phase 7 | Pending |
| SRV-02 | Phase 7 | Pending |
| SRV-03 | Phase 7 | Pending |
| SRV-04 | Phase 7 | Pending |
| SRV-05 | Phase 7 | Pending |
| UI-01 | Phase 7 | Pending |
| UI-02 | Phase 7 | Pending |

**Coverage:**

- v1 requirements: 38 total (note: earlier "36" was a miscount; the sections above contain 38 REQ-IDs)
- Mapped to phases: 38
- Unmapped: 0 ✓

---
*Requirements defined: 2026-07-07*
*Last updated: 2026-07-07 after roadmap creation (traceability populated)*
