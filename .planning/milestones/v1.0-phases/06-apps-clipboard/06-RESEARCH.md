# Phase 6: Apps & Clipboard - Research

**Researched:** 2026-07-11
**Domain:** Win32 window management + clipboard interop (Rust `windows` 0.62 / arboard 3.6) and two push-driven Flutter screens (Riverpod 3)
**Confidence:** HIGH (Win32 mechanisms verified against Microsoft Learn; all codebase seams read first-hand; one new crate audited)

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01** (APPS-02): Pin from **running windows** — long-press a running window row to pin it; relaunch uses that window's resolved executable path. No separate app-picker, no manual path entry, no installed-app scan.
- **D-02** (APPS-02): Favorites stored **client-side** (PrefsKv seam, same pattern as device store / keyboard rowGroup). Server stays stateless for favorites; `apps.launch` just receives the resolved path string.
- **D-03** (CLIP-03): Auto-sync defaults **OFF** — opt-in toggle in the Clipboard screen.
- **D-04** (CLIP-03): When enabled, **skip very large text** (size cap — researcher picks) and **best-effort skip sensitive/password-manager clips** (Windows exclusion marker — researcher confirms mechanism).
- **D-05** (CLIP-03): **Echo suppression via content hash** (roadmap-locked) — a copy that originated on the other device must not bounce back. Reuse the Phase-5 push-seam discipline (auth-gated S→C push; value-equal snapshot on the client).
- **D-06** (CLIP-04): Last-5 history **persists** across app restart (PrefsKv), consecutive duplicate copies **collapse** (dedupe), and tapping a history entry sets it as the **PC** clipboard (reuse pushes to the PC).
- **D-07** (APPS-01): List mirrors Windows **Z-order (Alt-Tab order)**, most-recent first, and shows each window's **app icon**.
- **D-08** (CLIP-03): phone→PC clipboard syncs **on app resume** (Android 10+ blocks background reads); surface honestly with a short persistent note. PC→phone stays live via `clip.changed` push.

### Claude's Discretion
- Hub tile placement/order for the new Apps + Clipboard tiles (data-driven `kHubTiles` registry — insert cleanly, no grid rework).
- Server poll cadence/debounce for `apps.changed` and `clip.changed` (responsiveness vs CPU) — follow the Phase-5 250ms audio-poll precedent unless research says otherwise.
- Exact byte cap for large-clip skip; sensitive-clip detection mechanism.

### Deferred Ideas (OUT OF SCOPE)
- Clipboard sync **configuration in a proper settings window** → Phase 7 (SRV-03). Phase 6 ships only the in-app toggle + behavior.
- Server one-pairing-per-run and `noPairing` copy split → Phase 7 (not apps/clipboard concerns).
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| APPS-01 | User sees running windows and can focus or close them | §Alt-Tab enumeration (DWMWA_CLOAKED + WS_EX filter), §Foreground-lock focus, §Close-race handling; slice "Apps list+focus+close" |
| APPS-02 | User can launch pinned favorite apps | §Exe-path resolution (QueryFullProcessImageNameW + UWP fallback), §WindowInfo `path` amendment, §ShellExecuteW launch; slice "Apps favorites/pin+launch" |
| APPS-03 | App list stays current via server push (`apps.changed`) | §Apps push seam (dedicated apps thread + watch channel, mirrors vol.changed); slice "Apps live refresh push" |
| CLIP-01 | User can send phone clipboard to PC | §arboard set + `clip.set` router arm (already wired), Flutter `Clipboard.getData`; slice "Clipboard send/fetch" |
| CLIP-02 | User can fetch PC clipboard to phone | §arboard get + `clip.get`→`clip.set` reply (already wired), Flutter `Clipboard.setData`; slice "Clipboard send/fetch" |
| CLIP-03 | Auto-sync within platform limits — PC→phone live, phone→PC on resume, echo suppression | §Clipboard push seam, §Sensitive/large skip, §Echo suppression, §Android 10+ resume-sync; slice "Clipboard auto-sync+echo-suppression" |
| CLIP-04 | User sees last-5 clipboard history | §PrefsKv history store (JSON list, dedupe); slice "Clipboard history" |
</phase_requirements>

## Summary

Phase 6 replaces two Phase-1 no-op seeds (`StubApps`, `StubClipboard`) with real Windows executors and adds two Flutter screens. **The wire protocol, router arms, dispatch gates, and both codecs already exist and are tested** (json.rs, router.rs, json_codec.dart all carry the full `apps.*`/`clip.*` families and pass round-trip tests). This phase is therefore mostly (a) filling in `WinApps`/`WinClipboard` against the `windows` 0.62 crate + arboard 3.6, (b) adding two S→C push seams that clone the Phase-5 `vol.changed` watch-channel discipline byte-for-byte, and (c) two screens that clone the Phase-5 `VolumeSnapshot`/`VolumeNotifier` value-equal snapshot pattern.

Two protocol amendments are needed, both additive/minor, both mirroring the locked Phase-5 `vol.changed` 1.1 amendment: **WindowInfo gains two optional fields `icon` (small base64 PNG) and `path` (resolved exe path)** — bumping the server version to `1.2`. Optional fields mean 1.0/1.1 clients still decode (D-05 unknown-field-ignore is proven in both codecs). A third, non-wire change: the `Apps` executor trait's `focus`/`close`/`launch` should return success so the router can emit `err{windowGone|launchFailed}` (design spec §8 "phone shows toast" — SC1's "clear toast if the window is gone").

The two platform-fiddly risks are real but bounded: **window focus from a background tray process** is fundamentally unreliable on Windows (SetForegroundWindow foreground-lock) and needs the AttachThreadInput workaround with graceful failure; and **Android 10+ blocks background clipboard reads**, forcing phone→PC sync onto the app-resume lifecycle hook (this is a platform limit, not a bug — surface it honestly per D-08). Both are verified against Microsoft Learn / Android developer docs below.

**Primary recommendation:** Build server-side on the Phase-5 dedicated-OS-thread + `watch`-channel + mpsc-command architecture exactly (one "apps thread", one "clipboard thread"), amend `WindowInfo` with optional `icon`+`path` (server `1.2`), and clone the `VolumeSnapshot`→`VolumeNotifier` pattern for `AppsSnapshot`/`ClipSnapshot` on the client. Do not invent new patterns — every seam this phase needs already has a green Phase-5 precedent in this repo.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Window enumeration + Alt-Tab filter | Server (dedicated apps thread) | — | EnumWindows/DWM are Win32-only; blocking/shell work must never run on a tokio worker (Phase-5 audio-thread precedent) |
| Icon extraction + PNG encode | Server (apps thread) | — | Shell/GDI + COM; cache by exe path; ride the wire only on real list changes |
| Window focus / close / launch | Server (apps thread) | Router (err reply) | SetForegroundWindow/AttachThreadInput + IsWindow validation; router emits `err` on failure → client toast |
| Live window-list refresh | Server watch channel → session push | Client Notifier | `apps.changed` clones the `vol.changed` authed-gated select! branch |
| Favorites (pin/store/relaunch list) | Client (PrefsKv) | Server (`apps.launch` executor) | D-02: server stateless for favorites; client owns the persisted list; server only executes a path string |
| Clipboard get/set | Server (clipboard thread, arboard) | Router (already wired) | arboard must stay on one OS thread; `clip.set`/`clip.get` arms exist |
| Sensitive/large-clip gate | Server (clipboard thread) | — | Windows exclusion clipboard formats are only readable via Win32 on the PC |
| Live PC→phone clip push | Server watch channel → session push | Client Notifier (auto-sync gate) | `clip.changed` clones `vol.changed`; **client** decides apply-or-ignore by its local toggle |
| Phone→PC sync-on-resume | Client (lifecycle hook) | Server (`clip.set`) | Android 10+ blocks background reads (D-08); only the focused app may read the phone clipboard |
| Echo suppression | Both ends (value/hash fingerprint) | — | Server suppresses re-push of a value it just set; client value-equal snapshot suppresses redundant apply |
| History (last-5, dedupe, reuse) | Client (PrefsKv) | Server (`clip.set` on reuse) | D-06: persisted client-side; tapping an entry pushes to the **PC** |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `windows` | 0.62.2 | Win32 window mgmt, DWM cloak check, clipboard-format check, shell launch/icon | Microsoft's official crate; already the project's Win32 dep (CLAUDE.md locked 0.62) `[VERIFIED: local crates.io registry — windows-0.62.2]` |
| `arboard` | 3.6.1 | Clipboard text get/set | Locked by CLAUDE.md; stub comment already names it. Latest is 3.6.1 `[VERIFIED: cargo search 2026-07-11]` |
| `png` | 0.18.1 | Encode extracted icon bitmaps to compact PNG for the wire | Pure-Rust, image-rs org, minimal; far smaller wire payload than raw RGBA (keeps under the 64 KB frame cap) `[VERIFIED: cargo search 2026-07-11]` |
| `sha2` | 0.11 | Content-hash fingerprint for echo suppression (D-05) | Already a workspace dep (token hashing); reuse — no new dependency `[CITED: ./CLAUDE.md stack table]` |

### Supporting (client — already in pubspec)
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `flutter/services` `Clipboard` | built-in | Read/write the **phone** clipboard (`getData`/`setData`) | CLIP-01 send, CLIP-02 fetch-apply, D-08 resume read. No package needed |
| `WidgetsBindingObserver` / `AppLifecycleListener` | built-in | Detect `AppLifecycleState.resumed` for phone→PC sync-on-resume (D-08) | Recommend `AppLifecycleListener` (Flutter 3.13+, cleaner than the observer mixin) |
| `shared_preferences` | ^2.5.5 | Favorites list (D-02) + history (D-06) persistence via `PrefsKv` | Non-secret data → prefs, never secure storage (house rule) `[VERIFIED: app/remote_control/pubspec.yaml]` |
| `flutter_riverpod` | 3.3.2 | `AppsNotifier`/`ClipNotifier` state | Clone `VolumeNotifier` `[VERIFIED: pubspec]` |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `png` 0.18 (icon encode) | `image` 0.25.10 | `image` is heavier (many codecs); we only PNG-encode a 32×32 RGBA buffer — `png` is the minimal fit |
| Server PNG encode | Raw RGBA + Flutter `ui.decodeImageFromPixels` | Raw 32×32×4 = 4 KB/icon × ~40 windows ≈ 160 KB — blows the 64 KB WS frame cap. PNG (~0.5–2 KB/icon) keeps it safe |
| `AppLifecycleListener` | `WidgetsBindingObserver.didChangeAppLifecycleState` | Both work; the observer mixin is the older pattern. Either is fine |
| SetForegroundWindow direct | AttachThreadInput workaround | Direct call silently fails from a background process (verified below) — the workaround is mandatory |

**Installation:**
```bash
# server/server-windows/Cargo.toml — add to existing `windows` features list:
#   "Win32_Graphics_Dwm",          # DwmGetWindowAttribute, DWMWA_CLOAKED (Alt-Tab cloak filter)
#   "Win32_System_DataExchange",   # RegisterClipboardFormatW, IsClipboardFormatAvailable (sensitive-clip check)
#   "Win32_UI_Shell",              # ShellExecuteW (launch), SHGetFileInfoW (icon)
#   "Win32_Graphics_Gdi",          # GetIconInfo, GetDIBits, DeleteObject (icon bitmap → RGBA)
# (Win32_UI_WindowsAndMessaging, Win32_UI_Input_KeyboardAndMouse, Win32_System_Threading,
#  Win32_System_Com, Win32_Foundation are ALREADY enabled — EnumWindows, AttachThreadInput,
#  QueryFullProcessImageNameW, CoInitializeEx all covered.)
arboard = "3.6"
png = "0.18"
# sha2 already in the workspace (server-core); add to server-windows deps if used there.
```

**Version verification:** `windows` 0.62.2, `arboard` 3.6.1, `png` 0.18.1 all confirmed on crates.io 2026-07-11. All four new `windows` feature flags (`Win32_Graphics_Dwm`, `Win32_Graphics_Gdi`, `Win32_System_DataExchange`, `Win32_UI_Shell`) confirmed present in the installed `windows-0.62.2/Cargo.toml` `[VERIFIED: local registry grep]`.

## Package Legitimacy Audit

| Package | Registry | Age | Downloads | Source Repo | Verdict | Disposition |
|---------|----------|-----|-----------|-------------|---------|-------------|
| `windows` | crates.io | 6+ yrs | very high | github.com/microsoft/windows-rs | OK | Approved (already in tree) |
| `arboard` | crates.io | 4+ yrs | high | github.com/1Password/arboard | OK | Approved (CLAUDE.md locked) |
| `png` | crates.io | 8+ yrs | very high | github.com/image-rs/image-png | OK | Approved (image-rs org) |
| `sha2` | crates.io | 8+ yrs | very high | github.com/RustCrypto/hashes | OK | Approved (already in tree) |

**Packages removed due to [SLOP] verdict:** none
**Packages flagged as suspicious [SUS]:** none
`png` was discovered via `cargo search`; it is the canonical image-rs PNG crate (same org as `image`) — treat as verified given the org provenance, but the planner may add a light `checkpoint:human-verify` before first install if desired.

## Architecture Patterns

### System Architecture Diagram

```
  PHONE (Flutter)                          PC (Rust server-windows)
  ─────────────                            ────────────────────────
  Apps screen                              ┌─────────────────────────────┐
   ├─ apps.list (open) ───────────────────▶│ router: exec.apps.list()    │
   │◀── apps.list{windows[icon,path]} ─────│   (reads apps-thread snapshot)│
   ├─ tap row  → apps.focus{id} ──────────▶│ router → AppsCmd::Focus(hwnd)│──┐
   ├─ close    → apps.close{id} ──────────▶│ router → AppsCmd::Close(hwnd)│  │
   │◀── err{windowGone} (if IsWindow false)│                              │  ▼
   ├─ long-press row → pin (store path) ───┤                       ┌──────────────────┐
   └─ tap favorite → apps.launch{path} ───▶│ router → AppsCmd::Launch   │ APPS THREAD    │
                                           │   (ShellExecuteW)     │ (std::thread,COM)│
   AppsNotifier ◀── apps.changed{windows} ─│◀─ session select! ◀── watch│ poll 500ms:    │
   (value-equal AppsSnapshot)              │   (authed-gated)          │ EnumWindows +  │
                                           │                           │ DWM cloak filt +│
                                           │                           │ icon(cache/exe)+│
                                           │                           │ QueryFullProc..│
                                           └───────────────────────────┴──────────────────┘

  Clipboard screen                         ┌─────────────────────────────┐
   ├─ Send → read phone clip ──────────────│                       ┌──────────────────┐
   │        → clip.set{text} ─────────────▶│ router→exec.clip.set()│ CLIPBOARD THREAD │
   ├─ Fetch → clip.get ───────────────────▶│ router→exec.clip.get()│ (std::thread)    │
   │◀── clip.set{text} (reply) ────────────│   (reads snapshot)    │ poll 250ms:      │
   ├─ resume+autosync → clip.set ─────────▶│ (records set-hash)    │  arboard get_text│
   │       (Android 10+ D-08)              │                       │  + IsClipboard   │
   ClipNotifier ◀─ clip.changed{text} ─────│◀─ session select! ◀── watch│ FormatAvailable│
   (apply IFF autosync ON; value-equal)    │   (authed-gated;          │  (sensitive?)  │
                                           │    server skips echo/     │  + size cap    │
                                           │    sensitive/large)       └──────────────────┘
                                           └─────────────────────────────┘
```

Trace the primary use case (focus a window): phone opens Apps → `apps.list` → server returns the apps-thread's cached snapshot with icons/paths → user taps a row → `apps.focus{id}` → router maps id→HWND, sends `AppsCmd::Focus` to the apps thread → thread runs the AttachThreadInput focus dance → if the HWND is dead, router returns `err{windowGone}` → phone toasts.

### Component Responsibilities
| File (new/changed) | Responsibility |
|--------------------|----------------|
| `server-windows/src/apps_thread.rs` (new) | Owns EnumWindows poll loop, DWM cloak filter, icon extraction+cache, exe-path resolution; produces `watch<Vec<WindowInfo>>`; consumes `mpsc<AppsCmd>` (Focus/Close/Launch) |
| `server-windows/src/clip_thread.rs` (new) | Owns arboard instance + 250ms poll; sensitive/large gate; echo suppression; produces `watch<ClipState>`; consumes `mpsc<ClipCmd::Set>` |
| `server-windows/src/executors/apps.rs` (new) | `WinApps`: `list()` reads watch snapshot; `focus/close/launch` send `AppsCmd`, return `bool` success |
| `server-windows/src/executors/clipboard.rs` (new) | `WinClipboard`: `get()` reads watch snapshot; `set()` sends `ClipCmd::Set` |
| `server-windows/src/main.rs` (changed) | Spawn both threads; wire `WinApps`/`WinClipboard` into `Executors`; add `apps`/`clip` receivers to `ServerDeps` |
| `server-core/src/transport/mod.rs` (changed) | `ServerDeps` gains `apps: watch::Receiver<Vec<WindowInfo>>`, `clip: watch::Receiver<ClipState>`; add core `ClipState` struct |
| `server-core/src/transport/session.rs` (changed) | Two new authed-gated `select!` branches emitting `apps.changed`/`clip.changed` (clone the volume branch) |
| `server-core/src/executors/mod.rs` (changed) | `WindowInfo` gains optional `icon`/`path`; `Apps` trait `focus/close/launch` → `bool` |
| `server-core/src/dispatch/router.rs` (changed) | `focus/close/launch` arms emit `err{windowGone|launchFailed}` on `false` |
| `server-core/src/codec/json.rs` (changed) | `WindowInfo` serde gains optional `icon`/`path` (skip_serializing_if None); bump `SERVER_PROTO_VERSION` → `1.2` |
| `app/.../remote_protocol/.../json_codec.dart` (changed) | `WindowInfo` gains optional `icon`/`path` |
| `app/.../apps/apps_screen.dart` + `apps_store.dart` (new) | Apps screen, `AppsNotifier`, favorites `PrefsKv` store |
| `app/.../clipboard/clipboard_screen.dart` + `clip_store.dart` (new) | Clipboard screen, `ClipNotifier`, auto-sync toggle, history `PrefsKv` store, lifecycle resume hook |
| `app/.../net/connection_service.dart` (changed) | Park `AppsSnapshot`/`ClipSnapshot`/error from `_onFrame` (clone the `VolChangedMsg` arm) |
| `app/.../hub/hub_screen.dart` (changed) | Insert Apps + Clipboard `HubTileSpec` entries in `kHubTiles` |

### Pattern 1: Dedicated OS thread + watch producer + mpsc commands (Phase-5 audio-thread clone)
**What:** Each platform subsystem (apps, clipboard) gets one `std::thread` that owns all its OS/COM state, polls on a `recv_timeout` interval, pushes a value-equal snapshot onto a `tokio::sync::watch` channel only when it changes, and executes commands arriving on an `mpsc` channel.
**When to use:** Any Win32/COM/blocking work (mandatory — never on a tokio worker).
**Example:** `server-windows/src/audio_thread.rs` (read in full) is the exact template — `run_audio_thread(rx, tx)` with `recv_timeout(250ms)`, `push_if_changed`, `execute_cmd`. Copy its shape for `run_apps_thread` and `run_clip_thread`. `CoInitializeEx(MTA)` once at top for the apps thread (shell icon APIs), `CoUninitialize` on exit.

### Pattern 2: Authed-gated S→C push branch (Phase-5 vol.changed clone)
**What:** A `watch::Receiver` in `ServerDeps` → a `select!` branch in `run_session` guarded by `volume_alive && ctx.auth_state == AuthState::Authed` → `borrow_and_update()` → encode frame → `tx.send`.
**When to use:** `apps.changed` and `clip.changed`.
**Example — `session.rs` lines 159–172** (the volume branch), reproduced structurally for apps:
```rust
// Source: server/server-core/src/transport/session.rs (vol.changed branch, adapted)
changed = apps.changed(), if apps_alive && ctx.auth_state == AuthState::Authed => {
    match changed {
        Ok(()) => {
            let windows = apps.borrow_and_update().clone();
            let frame = Message::text(json::encode_msg(
                &Msg::AppsChanged(AppsChangedPayload { windows }), None));
            if tx.send(frame).await.is_err() { break 'read; }
        }
        Err(_) => apps_alive = false,
    }
}
```
**Note the two differences from volume:**
1. **Apps:** no after-auth snapshot is required (the client sends `apps.list` on screen-open). Optional to add one.
2. **Clip:** **do NOT send an after-auth snapshot** — dumping the PC clipboard to every connecting phone is a privacy leak. Only push on change; `clip.get` is the explicit pull.

### Pattern 3: Client value-equal snapshot Notifier (Phase-5 VolumeNotifier clone)
**What:** `ConnectionService._onFrame` parks a value-equal snapshot (`AppsSnapshot`/`ClipSnapshot`) and pings `changes`; a `Notifier` re-snapshots on each ping and publishes a value-equal view the screen watches.
**When to use:** Apps list + clipboard state.
**Example:** `connection_service.dart` lines 462–469 (the `VolChangedMsg` arm) + `volume_store.dart` `VolumeNotifier`. Clone verbatim, adding arms for `AppsListMsg` (reply), `AppsChangedMsg`, `ClipChangedMsg`, `ClipSetMsg` (the `clip.get` reply), and `ErrMsg` (for toasts).

### Pattern 4: id ↔ HWND mapping via HWND-as-u64
**What:** `WindowInfo.id` is a core-level opaque `u64` (mod.rs: "NEVER an HWND-shaped OS type"). The **windows executor** uses the HWND's numeric value cast to `u64` as the id. Core stays OS-agnostic; the executor gets O(1) id→HWND (a cast) and validates with `IsWindow(hwnd)` on every focus/close.
**Why:** No id table to maintain; HWND is stable while the window lives. HWND recycling after close is mitigated by validate-on-use + fast (500 ms) list refresh — acceptable for v1.

### Anti-Patterns to Avoid
- **Running EnumWindows / arboard / SetForegroundWindow on a tokio worker** — Win32/COM blocking work must be on the dedicated OS thread (Phase-5 rule). `WinApps::list()` reading a `watch::borrow()` is the only synchronous touch, and it never blocks.
- **Pushing `clip.changed` on a poll tick that didn't change** — gate every push on value-equality (the `push_if_changed` discipline), else you flood the phone and defeat echo suppression.
- **Sending a clipboard snapshot right after auth** — privacy leak; clip is pull-only (`clip.get`) plus change-push.
- **Trusting `SetForegroundWindow` alone** — it silently no-ops from a background process (verified below).
- **Relaunching an `ApplicationFrameHost.exe` path** — that is the UWP frame host, not the app; see UWP handling below.
- **Sending raw RGBA icons** — blows the 64 KB frame cap; PNG-encode.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Sensitive-clip detection | A heuristic (regex for "password", app-name blocklist) | Windows exclusion clipboard formats (`ExcludeClipboardContentFromMonitorProcessing` etc.) | Microsoft-standard; KeePassXC, Credential Manager, Chrome incognito all set these `[VERIFIED: Microsoft Learn]` |
| Cloaked/ghost window filtering | Title/visibility heuristics alone | `DwmGetWindowAttribute(DWMWA_CLOAKED)` + WS_EX filter + owner-chain | EnumWindows returns suspended-app and UWP-ghost windows; DWM cloak is the authoritative signal `[VERIFIED: Microsoft Learn]` |
| Icon → PNG | Manual PNG chunk writing | `png` crate encoder | Trivial to get CRC/zlib wrong; `png` is battle-tested |
| Clipboard change events | A WM_CLIPBOARDUPDATE listener window | arboard poll (250 ms) — Phase-5 precedent | arboard has no change events; the audio thread already establishes poll-over-notify as the house pattern |
| Content-hash echo suppression from scratch | Custom digest | `sha2` (already in tree) or plain value-equality | Under the 16 KiB cap, value-equality is sufficient; sha2 gives a fixed-size fingerprint if preferred |
| Phone clipboard access | A platform channel | `flutter/services` `Clipboard` | Built-in; no plugin |

**Key insight:** Every hard part of this phase has an authoritative Windows/Flutter primitive or an in-repo Phase-5 precedent. The only genuinely custom code is the Alt-Tab filter predicate and the icon-extraction plumbing — both are well-trodden Win32 recipes documented below.

## Resolving the Four Research Flags

### Flag 1 — APPS-02 exe-path resolution (D-01/D-02): classic vs UWP
**Mechanism (classic Win32):** `GetWindowThreadProcessId(hwnd, &pid)` → `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid)` → `QueryFullProcessImageNameW(h, 0, buf, &len)` yields the full `.exe` path. `QueryFullProcessImageNameW` is in `Win32_System_Threading` (already enabled) and needs only `PROCESS_QUERY_LIMITED_INFORMATION` (works unelevated for same-user processes). `[CITED: learn.microsoft.com QueryFullProcessImageNameW]`

**UWP/packaged apps:** their top-level window is hosted by `ApplicationFrameHost.exe`, so `QueryFullProcessImageNameW` returns `...\ApplicationFrameHost.exe` — **relaunching that does nothing useful.** Proper relaunch needs the AppUserModelID and `IApplicationActivationManager::ActivateApplication` or `shell:AppsFolder\<AUMID>` — meaningfully more COM plumbing.

**v1 recommendation (definite):** **Pin only classic Win32 apps.** During enumeration, detect UWP/packaged windows (resolved path is `ApplicationFrameHost.exe`, or the path lives under `C:\Program Files\WindowsApps\` or `%SystemRoot%\SystemApps\`) and set `WindowInfo.path = None` for them. The client treats **absent `path` = non-pinnable**: long-press-to-pin is disabled on those rows (a brief toast "This app can't be pinned yet" is enough). **Focus and close still work** on UWP windows via their frame HWND. Full AUMID launch is deferred (v2). This keeps v1 honest and scoped while covering the owner's real workflow (browsers, editors, terminals — all classic Win32). `[ASSUMED — UWP window hosting by ApplicationFrameHost is training knowledge; verify on-device that the owner's pinned apps resolve to real .exe paths]`

### Flag 2 — APPS-01 enumeration + icon (D-07)
**Alt-Tab-quality filter predicate** (apply to each HWND from `EnumWindows`, which enumerates in **Z-order top→bottom = most-recent-first**, so no extra sort is needed for D-07):
1. `IsWindowVisible(hwnd)` is true.
2. Title is non-empty (`GetWindowTextLengthW > 0`).
3. Not a tool window: `!(GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW)` **OR** it has `WS_EX_APPWINDOW`.
4. Owner-chain root: walk `GetWindow(hwnd, GW_OWNER)`; the candidate should be the root owner's `GetLastActivePopup`.
5. **Not cloaked:** `DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &v, 4)` returns `v == 0`. Cloaked (`DWM_CLOAKED_APP=1`, `DWM_CLOAKED_SHELL=2`, `DWM_CLOAKED_INHERITED=4`) = a suspended-UWP ghost or virtual-desktop-hidden window → **exclude.** `[VERIFIED: Microsoft Learn — DWMWINDOWATTRIBUTE + "Get last active window / Alt+Tab list" community recipe]`

**Icon extraction + encoding:**
- Get an `HICON`: `SHGetFileInfoW(path, 0, &shfi, size, SHGFI_ICON | SHGFI_SMALLICON)` (by exe path — natural cache key), or fall back to `SendMessageW(hwnd, WM_GETICON, ICON_SMALL2, 0)` / `GetClassLongPtrW(hwnd, GCLP_HICONSM)` for windows whose path didn't resolve.
- `HICON` → RGBA: `GetIconInfo` → `HBITMAP hbmColor` → `GetDIBits` (request 32bpp top-down BGRA) → swap B/R → RGBA buffer. `DeleteObject` the bitmaps.
- **Encode 32×32 RGBA → PNG** with the `png` crate → base64 → `WindowInfo.icon`.
- **Cache by resolved exe path** (many windows share one exe). Extraction runs on the apps thread only for paths not yet cached.

**Protocol amendment (WindowInfo → server `1.2`, mirrors `vol.changed` 1.1):** add two **optional** fields to `WindowInfo` in both codecs and the core struct:
```rust
// server-core/src/executors/mod.rs
pub struct WindowInfo {
    pub id: u64,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,   // base64 PNG, 32×32
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,   // resolved exe path; None = non-pinnable (UWP)
}
```
Because both are optional and both codecs already ignore unknown fields (D-05, proven), 1.0/1.1 clients still decode. Bump `SERVER_PROTO_VERSION` to `"1.2"` (still major 1 → 1.0 clients accepted, SPEC §2). **Add golden fixtures** for a `WindowInfo` carrying `icon`+`path` and one carrying neither (request/legacy form) — mirror the `volume/` fixture directory added in 05-01. **Wire-size guard:** cap the pushed list length (recommend ≤ 50 windows) and use 32×32 icons (~0.5–2 KB PNG each) to stay well under the 64 KB frame cap; note this as a verification check.

### Flag 3 — CLIP-03 large-clip cap + sensitive-clip skip (D-04)
**Large-text cap (concrete recommendation):** auto-sync **skips text > 16 KiB (16384 bytes UTF-8).** Rationale: all `clip.*` frames must fit the 64 KB WS frame cap (SPEC §13) after JSON+escaping; 16 KiB of text is generous for normal copy-paste and leaves ample envelope headroom. Manual **Send** may allow larger but must still hard-cap below the frame limit (reject/toast over ~48 KiB). `[ASSUMED — 16 KiB is a judgment call; surfaced for confirmation]`

**Sensitive-clip detection (verified mechanism):** Windows-standard clipboard exclusion formats:
- **`ExcludeClipboardContentFromMonitorProcessing`** — mere **presence** means "exclude from history and cloud sync." Set by KeePassXC, Windows Credential Manager, and (since 2025) Chrome incognito. **This is the primary, cheapest signal.**
- **`CanIncludeInClipboardHistory`** — a serialized DWORD; value `0` = exclude from history.
- **`CanUploadToCloudClipboard`** — a serialized DWORD; value `0` = exclude from cloud sync.
`[VERIFIED: Microsoft Learn — Clipboard Formats]`

**How to read via windows-rs (no OpenClipboard needed for presence):**
- Register each name once at thread start: `RegisterClipboardFormatW(w!("ExcludeClipboardContentFromMonitorProcessing"))` → a format id.
- Per poll tick, `IsClipboardFormatAvailable(id)` (does **not** require `OpenClipboard`, contention-free) tells you presence.
- **v1 recommendation:** treat **presence of `ExcludeClipboardContentFromMonitorProcessing`** as "sensitive → skip auto-sync push." It is presence-only (no value read), covers the important password managers + incognito, and needs no `OpenClipboard`. Optionally also skip when `CanIncludeInClipboardHistory`/`CanUploadToCloudClipboard` are present (reading the DWORD-0 value requires `OpenClipboard`+`GetClipboardData`; defer unless needed). Requires `Win32_System_DataExchange`. `[VERIFIED: Microsoft Learn; windows-rs API path confirmed present in 0.62.2]`

This gate is applied **server-side on the clipboard thread** before any `clip.changed` push — the password never leaves the PC even if the phone's auto-sync is on. That server-side skip is the real privacy backstop (see the design note under Open Questions about unconditional push).

### Flag 4 — APPS-01 focus reliability (foreground lock) + close-race
**The problem (verified):** "A process can set the foreground window only if it is the foreground process, was started by it, received the last input event, there is no foreground process, or the foreground lock timeout expired." A background tray server meets none of these, so `SetForegroundWindow` **silently fails.** `[VERIFIED: Microsoft Learn — SetForegroundWindow restrictions]`

**Recommended focus sequence (best-effort, run on the apps thread):**
1. If minimized, `ShowWindow(hwnd, SW_RESTORE)`.
2. `foreThread = GetWindowThreadProcessId(GetForegroundWindow(), null)`; `thisThread = GetCurrentThreadId()`.
3. `AttachThreadInput(thisThread, foreThread, true)` — attaching to the current foreground thread's input queue lifts the lock for the duration.
4. `AllowSetForegroundWindow(ASFW_ANY)` then `SetForegroundWindow(hwnd)` (optionally `BringWindowToTop`).
5. `AttachThreadInput(thisThread, foreThread, false)` to detach.
`[VERIFIED: Microsoft Learn / community — AttachThreadInput workaround]`

**Honest caveat:** even this is **not 100% reliable** (documented as "works in most cases, depends on environment"; UAC/UIPI complicates it). Windows may flash the taskbar button instead of stealing focus. That is acceptable for v1 — do not fight it further. `SE_FOREGROUND`/UIPI cases (elevated foreground window) are the SRV-05 Phase-7 concern, not this phase.

**Close-race handling (SC1 "clear toast if the window is gone"):**
- Close = `PostMessageW(hwnd, WM_CLOSE, 0, 0)` (graceful — lets the app show "Save?"). Never `TerminateProcess`.
- Before focus/close, validate `IsWindow(hwnd)`. If false (window already closed), the command **fails**.
- **Surface the failure:** amend the `Apps` trait so `focus`/`close`/`launch` return `bool` (or `Result`). The router emits `err{code:"windowGone", msg}` (focus/close) or `err{code:"launchFailed", msg}` (launch) on `false`; the client's `_onFrame` `ErrMsg` arm raises a toast. This honors design spec §8 verbatim. `MockExecutors` return `true`; update the two router tests that assert empty replies for these arms.

## Runtime State Inventory

> This is a greenfield feature phase (new executors + screens), **not** a rename/refactor. Included for completeness — no pre-existing runtime state is being migrated.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | **None** — favorites (D-02) and history (D-06) are *new* client PrefsKv keys created by this phase, not migrated. Suggested keys: `apps.favorites` (JSON list `[{name,path,icon}]`), `clip.history` (JSON list of ≤5 strings), `clip.autosync` (bool, default false). | Create new keys only |
| Live service config | **None** — server is stateless for favorites (D-02); no external service config touched | None |
| OS-registered state | **None** — no Task Scheduler / registry / autostart changes (those are Phase 7 SRV-02) | None |
| Secrets/env vars | **None** — clipboard text is not a secret store; sensitive clips are *skipped*, never persisted. Favorites/history go to `shared_preferences` (non-secret), never secure storage | None |
| Build artifacts | New `windows` feature flags + `png`/`arboard` crates recompile `server-windows`; no stale artifacts | `cargo build` picks up new deps |

## Common Pitfalls

### Pitfall 1: SetForegroundWindow silently no-ops from the tray process
**What goes wrong:** `apps.focus` appears to succeed (no error) but the window never comes forward.
**Why:** foreground-lock restriction on background processes (verified).
**How to avoid:** the AttachThreadInput sequence above; accept partial reliability; never assert focus succeeded.
**Warning signs:** taskbar button flashes instead of window raising.

### Pitfall 2: Relaunching a UWP window's "path" launches nothing
**What goes wrong:** pinning a Store app then tapping the favorite does nothing.
**Why:** the resolved path is `ApplicationFrameHost.exe`.
**How to avoid:** mark UWP windows `path=None` → non-pinnable in v1 (Flag 1).
**Warning signs:** resolved path ends in `ApplicationFrameHost.exe` or lives under `WindowsApps\`.

### Pitfall 3: Icon payloads blow the 64 KB frame cap
**What goes wrong:** `apps.changed` with many raw-RGBA icons exceeds `max_frame_size` (65536) → tungstenite drops the frame → session error (`session.rs` treats oversize as `break 'read`).
**Why:** raw 32×32×4 = 4 KB/icon × 40 = 160 KB.
**How to avoid:** PNG-encode (0.5–2 KB/icon), cap list length ≤ 50, use 32×32.
**Warning signs:** session drops when many windows are open.

### Pitfall 4: EnumWindows includes ghost/cloaked/suspended windows
**What goes wrong:** the Apps list shows blank or phantom entries (suspended UWP apps, `Windows.UI.Core.CoreWindow` ghosts).
**Why:** EnumWindows returns far more than Alt-Tab shows.
**How to avoid:** the full 5-point filter incl. `DWMWA_CLOAKED` (Flag 2).
**Warning signs:** entries with no icon or duplicate/empty-ish titles.

### Pitfall 5: Echo/sync loop on clipboard
**What goes wrong:** phone sends `clip.set` → server sets PC clipboard → poll detects "change" → server pushes `clip.changed` back → phone re-applies → on next resume re-sends `clip.set` → loop.
**Why:** the server's own write looks like an external change.
**How to avoid:** server records the fingerprint (value or SHA-256) of the text it just set from a `clip.set`; `push_if_changed` suppresses a `clip.changed` whose fingerprint matches. Client parks a value-equal `ClipSnapshot` and ignores a push identical to what it last sent. Both ends (D-05).
**Warning signs:** clipboard "flickers" or history fills with duplicates.

### Pitfall 6: arboard on a tokio worker / cross-thread
**What goes wrong:** intermittent clipboard-open failures or panics.
**Why:** Windows clipboard is single-owner; arboard opens/closes per call and must stay on one thread.
**How to avoid:** one dedicated clipboard thread owns the arboard instance (Pattern 1). `WinClipboard::get()` reads the watch snapshot, never touches arboard directly.
**Warning signs:** `ClipboardOccupied`-style errors under contention.

### Pitfall 7: Android 10+ background clipboard read returns empty
**What goes wrong:** phone→PC auto-sync "works in a demo" (app in foreground) but silently does nothing in real use.
**Why:** only the focused app or default IME may read the phone clipboard on Android 10+ (verified).
**How to avoid:** read the phone clipboard **only** on `AppLifecycleState.resumed` (D-08); surface the persistent honesty note.
**Warning signs:** `Clipboard.getData` returns null/empty when the app wasn't foregrounded.

### Pitfall 8: Sending clip snapshot at auth leaks the PC clipboard
**What goes wrong:** every phone that connects receives whatever is on the PC clipboard.
**Why:** copying the volume "after-auth snapshot" pattern to clipboard.
**How to avoid:** clip is pull-only (`clip.get`) + change-push; **no** after-auth clip snapshot.

## Code Examples

### Registering + checking a sensitive-clip format (windows-rs 0.62)
```rust
// Source: Microsoft Learn "Clipboard Formats" + windows-rs 0.62 DataExchange
use windows::core::w;
use windows::Win32::System::DataExchange::{
    RegisterClipboardFormatW, IsClipboardFormatAvailable,
};
// once, on the clipboard thread:
let cf_exclude = unsafe {
    RegisterClipboardFormatW(w!("ExcludeClipboardContentFromMonitorProcessing"))
}; // returns u32 format id
// per poll tick:
let sensitive = unsafe { IsClipboardFormatAvailable(cf_exclude).is_ok() };
if sensitive { /* skip auto-sync push */ }
```

### DWM cloak check for Alt-Tab filtering
```rust
// Source: Microsoft Learn DWMWINDOWATTRIBUTE
use windows::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED};
let mut cloaked: u32 = 0;
let ok = unsafe {
    DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED,
        &mut cloaked as *mut _ as *mut _, std::mem::size_of::<u32>() as u32)
}.is_ok();
let visible_in_alt_tab = ok && cloaked == 0; // combine with WS_EX + owner-chain checks
```

### Client `_onFrame` arms (clone of the VolChangedMsg arm)
```dart
// Source: app/.../net/connection_service.dart (VolChangedMsg arm, adapted)
if (msg is AppsChangedMsg) {
  _appsSnapshot = AppsSnapshot(msg.windows); // value-equal
  _notify(); return;
}
if (msg is ClipChangedMsg) {
  _clipSnapshot = ClipSnapshot(msg.text);    // value-equal; echo-checked in Notifier
  _notify(); return;
}
if (msg is ErrMsg) { _lastError = msg; _notify(); return; } // toast surface
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| WM_CLIPBOARDUPDATE listener window | Poll arboard (250 ms) | House rule (Phase 5) | No hidden message window; matches audio-thread pattern |
| Heuristic "is this a password?" | `ExcludeClipboardContentFromMonitorProcessing` format | Win10 1809+ | Reliable, Microsoft-standard skip signal |
| `EnumWindows` + visibility only | + `DWMWA_CLOAKED` | Win8+ (DWM) | Filters suspended-UWP ghosts correctly |
| `keybd_event`/`SetForegroundWindow` naive | AttachThreadInput dance | long-standing | Only reliable-ish focus path from background |

**Deprecated/outdated:** none new for this phase (locked stack is current per CLAUDE.md 2026-07-07 verification).

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | UWP windows are hosted by `ApplicationFrameHost.exe` so path-relaunch fails → pin classic-only in v1 | Flag 1 | If the owner's key apps are UWP, pinning covers fewer apps than hoped — verify on-device which of the owner's apps resolve to real .exe paths |
| A2 | 16 KiB is a sane auto-sync large-text cap | Flag 3 | Too low → legit large pastes silently skipped; too high → nears frame cap. Tunable constant |
| A3 | Presence of `ExcludeClipboardContentFromMonitorProcessing` is a sufficient sensitive-clip signal for v1 | Flag 3 | A password manager that only sets `CanIncludeInClipboardHistory=0` (not the Exclude format) would slip through — add the DWORD checks if observed |
| A4 | Server pushes `clip.changed` on every (non-sensitive, non-large) PC change post-auth; the **client** gates apply-vs-ignore by its local auto-sync toggle | Open Q 1 | Clipboard text crosses the LAN to an authed paired phone even when the phone's auto-sync is off (sensitive clips still skipped). Mild privacy over-send — confirm acceptable |
| A5 | 500 ms apps poll / 250 ms clip poll are good cadences | Discretion | Too slow → laggy Alt-Tab order / clip; too fast → CPU. Tunable |
| A6 | HWND-as-u64 id with validate-on-use is collision-safe enough for v1 | Pattern 4 | HWND recycled between polls could focus/close the wrong new window in a race — narrow window, acceptable for a personal LAN tool |
| A7 | Amending the `Apps` trait to return `bool` is in-scope (traits are Phase-6-owned, not wire-locked) | Flag 4 | If the trait signatures are considered frozen, fall back to apps.changed convergence + client optimism (weaker toast UX) |

## Open Questions

1. **Unconditional `clip.changed` push vs. client-gated apply (A4).**
   - What we know: the locked protocol has **no upstream "enable auto-sync" message**; SC4 requires live PC→phone when auto-sync is on; the only live path is a server push.
   - What's unclear: whether pushing (non-sensitive) clipboard text to an authed phone whose auto-sync is *off* is acceptable, or whether the user wants stricter gating.
   - Recommendation: **push always (post-auth, sensitive/large skipped server-side); client applies only when its toggle is on.** Flag to discuss-phase for a privacy sign-off; if rejected, the fallback is "no live PC→phone" (fetch-only), which weakens SC4.

2. **Icon size/quality vs. wire budget.**
   - What we know: 32×32 PNG stays under the frame cap for ≤50 windows.
   - What's unclear: whether 32×32 looks acceptable on a modern phone screen or 48×48 is wanted.
   - Recommendation: ship 32×32; revisit only if the owner finds them too small (raise list-length guard accordingly).

3. **Whether to add an after-auth `apps.changed` snapshot.**
   - Recommendation: not required — client sends `apps.list` on Apps-screen open; the change-push keeps it live. Add the snapshot only if the screen must be pre-warmed before open (it needn't be).

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `windows` crate feats (Dwm/Gdi/DataExchange/UI_Shell) | server executors | ✓ | 0.62.2 | — (confirmed in local registry) |
| `arboard` | clipboard | ✓ (crates.io) | 3.6.1 | — |
| `png` | icon encode | ✓ (crates.io) | 0.18.1 | `image` 0.25 |
| Windows 10 1809+ (clipboard exclusion formats) | sensitive-clip skip | ✓ (target is Win11) | 11 | If absent, formats simply never present → no skip (fail-open; acceptable) |
| Android 10+ device | resume-sync UAT (D-08) | ✓ (Xiaomi test device, Phase 3) | — | — |

**Missing dependencies with no fallback:** none.
**Missing dependencies with fallback:** `png` → `image` if ever needed.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework (Rust) | `cargo test` (+ optional `cargo-nextest`); core integration suite in `server-core/tests` |
| Framework (Dart) | `flutter test` / `dart test` (widget + pure-logic + fixture tests) |
| Config file | Cargo workspace `server/`; `app/remote_control` + `app/packages/remote_protocol` |
| Quick run (server-core) | `cargo test -p server-core` |
| Quick run (Dart proto) | `dart test` in `app/packages/remote_protocol` |
| Full suite | `cargo test --workspace` + `flutter test` in `app/remote_control` + `dart test` in `remote_protocol` |

### Phase Requirements → Test Map
| Req | Behavior | Test Type | Automated Command | Exists? |
|-----|----------|-----------|-------------------|---------|
| APPS-01 | `apps.list` returns filtered windows; `apps.focus/close` route; `err{windowGone}` on `false` | integration (MockExecutors, extended to return bool) | `cargo test -p server-core apps` | ⚠️ extend router tests (currently assert empty replies) |
| APPS-01 | Alt-Tab filter predicate excludes cloaked/tool/ownerless | unit (pure predicate over synthetic style bits) | `cargo test -p server-windows apps_filter` | ❌ Wave 0 (new) |
| APPS-01 | Real focus/close on a live window | **on-device UAT only** | manual smoke | n/a (input not CI-testable) |
| APPS-02 | `WindowInfo` icon/path optional fields round-trip; server `1.2` | contract fixture (Rust + Dart) | `cargo test -p server-core codec` / `dart test` | ❌ Wave 0 (new fixtures) |
| APPS-02 | UWP window → `path=None` → non-pinnable in UI | widget test (favorites disabled when path null) | `flutter test test/apps` | ❌ Wave 0 |
| APPS-02 | Launch routes `apps.launch{path}`; `err{launchFailed}` on bad path | integration | `cargo test -p server-core apps` | ⚠️ extend |
| APPS-03 | `apps.changed` pushed authed-only, once per real change | integration (drive watch, assert authed-gate + no pre-auth leak) | `cargo test -p server-core apps_changed_push` | ❌ Wave 0 (clone vol.changed push test) |
| CLIP-01 | `clip.set` routes to executor | integration | `cargo test -p server-core clip` | ✓ (exists) |
| CLIP-02 | `clip.get`→`clip.set` reply | integration | `cargo test -p server-core clip` | ✓ (exists) |
| CLIP-03 | echo suppression: server won't re-push its own set value | unit (clip-thread fingerprint logic, pure) | `cargo test -p server-windows clip_echo` | ❌ Wave 0 |
| CLIP-03 | sensitive/large skip predicate | unit (pure: given flags+len → skip?) | `cargo test -p server-windows clip_gate` | ❌ Wave 0 |
| CLIP-03 | `clip.changed` authed-gated push | integration (clone vol push test) | `cargo test -p server-core clip_changed_push` | ❌ Wave 0 |
| CLIP-03 | phone→PC syncs on resume, not background | **on-device UAT only** (Android 10+) | manual | n/a |
| CLIP-04 | history persists, dedupes consecutive, reuse pushes to PC | widget/unit (clip_store over fake PrefsKv) | `flutter test test/clipboard` | ❌ Wave 0 |
| — | Client parks Apps/Clip snapshot + err from `_onFrame` | unit (connection_service_test, clone vol test) | `flutter test test/connection_service_test.dart` | ⚠️ extend |

### Sampling Rate
- **Per task commit:** `cargo test -p <crate>` for the touched crate; `flutter test test/<area>` for the touched screen.
- **Per wave merge:** `cargo test --workspace` + `flutter test` + `dart test` (remote_protocol fixtures).
- **Phase gate:** full suite green + on-device UAT checklist before `/gsd-verify-work`.

### Wave 0 Gaps
- [ ] `server-windows` unit tests: Alt-Tab filter predicate, clip sensitive/large gate, clip echo fingerprint (pure functions, no OS calls — factor the predicates out of the thread loops so they're testable, exactly as `pct_from_scalar` was factored out of the audio thread).
- [ ] `server-core` push tests for `apps.changed`/`clip.changed` (clone the vol.changed authed-gate + no-pre-auth-leak tests).
- [ ] New golden fixtures: `WindowInfo` with `icon`+`path`, and legacy without (Rust + Dart both decode). Extend server-version assertion to `1.2`.
- [ ] Extend router tests: `focus/close/launch` now return `bool` → assert `err{windowGone|launchFailed}` on false; `MockExecutors` return true.
- [ ] Extend `connection_service_test.dart`: Apps/Clip snapshot + err arms.
- [ ] `flutter test` for apps_store (favorites, UWP non-pinnable) and clip_store (history dedupe/persist/reuse) over fake `PrefsKv`.
- [ ] On-device UAT checklist (not CI): real focus/close, launch, live `apps.changed`, PC→phone live push, phone→PC resume-sync on Android 10+, sensitive-clip skip (copy from a password manager → confirm no phone sync).

## Security Domain

**security_enforcement: true, ASVS level 1.**

### Applicable ASVS Categories
| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes (inherited) | All `apps.*`/`clip.*` gated behind `AuthState::Authed` — proven in `router.rs`/`session.rs`; push branches carry the `== Authed` guard (clone vol.changed) |
| V4 Access Control | yes | S→C-only families (`apps.changed`/`clip.changed`) already in the router's ignore arm — a client cannot spoof them upstream (router.rs lines 250–258). Read-only `apps.list`/`clip.get` exempt from pause gate; executor-bound `apps.launch/focus/close`, `clip.set` are pause-gated (router `is_executor_bound`) |
| V5 Input Validation | yes | `apps.launch{path}` executes a path via `ShellExecuteW` — see threat below; window ids validated with `IsWindow` before use |
| V6 Cryptography | no new | Echo fingerprint uses `sha2` (already vetted) or plain value-equality — not a security control |
| V7 Data Protection | yes | Sensitive clips skipped server-side (never leave the PC); clipboard text never logged (session.rs T-01-31 no-log rule extends to `clip.*`); favorites/history in non-secret prefs only |

### Known Threat Patterns for this stack
| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| `apps.launch{path}` arbitrary-exe execution by an authed peer | Elevation / Tampering | The peer is already authed+paired (owns the token); scope is "run a program as the logged-in user" — inherent to the feature. **Mitigation:** the path originates from a window the server itself enumerated and resolved (D-01 pin-from-running-window); the client sends back a path the server produced. Recommend the executor **not** validate/whitelist beyond `ShellExecuteW`'s own behavior for v1, but **never** pass user-typed paths (D-01 forbids manual entry) — keep it that way. Log launches as lifecycle events (path is not a secret) |
| Clipboard text leak to an off-auto-sync phone (A4) | Information disclosure | Sensitive-clip server-side skip; authed+LAN-only; confirm the push-always design in discuss (Open Q 1) |
| Password/secret capture via clipboard sync | Information disclosure | `ExcludeClipboardContentFromMonitorProcessing` skip (fail-open if the source app doesn't set it — document the residual risk) |
| Clipboard/window text in logs | Information disclosure | Extend the existing no-payload-logging rule (session.rs) to `clip.*` and window titles/paths — log counts/lifecycle only |
| Icon PNG as a decode-bomb on the phone | DoS | Server encodes fixed 32×32 icons; list length capped; frame cap (64 KB) enforced by tungstenite both directions |

## Sources

### Primary (HIGH confidence)
- Microsoft Learn — **Clipboard Formats** (`ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory`, `CanUploadToCloudClipboard`): https://learn.microsoft.com/en-us/windows/win32/dataxchg/clipboard-formats
- Microsoft Learn — **DWMWINDOWATTRIBUTE / DWMWA_CLOAKED**: https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
- Microsoft Learn — **SetForegroundWindow restrictions** (foreground lock): https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow (via archived forum thread + shlomio AttachThreadInput writeup)
- Android Developers — **Secure Clipboard Handling** (Android 10 background-read restriction): https://developer.android.com/privacy-and-security/risks/secure-clipboard-handling
- In-repo (read first-hand): `audio_thread.rs`, `session.rs`, `router.rs`, `json.rs`, `executors/mod.rs`, `power.rs`, `media.rs`, `connection_service.dart`, `volume_store.dart`, `json_codec.dart`, `device_store.dart`, `hub_screen.dart`
- Local crates.io registry — `windows-0.62.2/Cargo.toml` feature-flag confirmation; `cargo search` for `arboard 3.6.1`, `png 0.18.1`

### Secondary (MEDIUM confidence)
- AutoHotkey / community — Alt-Tab window-list owner-chain + LastActivePopup recipe
- Medium (F. García Álvarez) — "Working with clipboard data on Android 10"

### Tertiary (LOW confidence)
- UWP `ApplicationFrameHost.exe` hosting behavior (training knowledge — A1, verify on-device)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — versions verified on crates.io; feature flags confirmed in the installed registry
- Architecture: HIGH — every seam clones a green Phase-5 precedent read first-hand in this repo
- Win32 mechanisms (cloak filter, clipboard formats, foreground lock, QueryFullProcessImageNameW): HIGH — Microsoft Learn verified
- UWP relaunch fallback: MEDIUM — mechanism correct, exact per-app behavior needs on-device confirmation (A1)
- Poll cadences / byte caps: MEDIUM — reasoned defaults, tunable (A2/A5)

**Research date:** 2026-07-11
**Valid until:** 2026-08-10 (stable stack; 30 days)
