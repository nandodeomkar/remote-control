---
phase: 06-apps-clipboard
plan: 02
subsystem: server-windows
tags: [rust, windows, win32, apps, enumwindows, dwm, icons, tokio-watch]

# Dependency graph
requires:
  - phase: 06-apps-clipboard
    plan: 01
    provides: "WindowInfo.icon/path fields, Apps::focus/close/launch->bool trait, apps.changed authed-gated push seam, ServerDeps.apps watch receiver"
  - phase: 05-control-center
    provides: "audio_thread.rs dedicated-OS-thread template (AudioCmd/pct_from_scalar/push_if_changed/run loop), WinMedia sender-only executor shape, main.rs audio-thread wiring block"
provides:
  - "run_apps_thread: dedicated apps OS thread (CoInitializeEx MTA, recv_timeout 500ms loop) — the real watch<Vec<WindowInfo>> producer"
  - "is_alt_tab_window pure 5-point predicate (visible/titled/tool-app/owner-root/cloaked)"
  - "EnumWindows Z-order enumeration + DWM cloak filter + exe-path resolution (UWP->None) + 32x32 icon PNG/base64 (cached by exe path)"
  - "AppsCmd { Focus/Close/Launch }; execute_cmd with IsWindow-guarded focus dance, WM_CLOSE, ShellExecuteW"
  - "WinApps executor (snapshot-validated focus/close, send-and-forget launch) wired into Executors + ServerDeps"
affects: [06-03 Flutter Apps screen drives apps.list/focus/close/launch end-to-end, 06-07 on-device UAT of real enumeration/icons/focus]

# Tech tracking
tech-stack:
  added:
    - "png 0.18 (image-rs org, T-06-SC audited) — 32x32 RGBA -> PNG icon encode"
    - "windows feature Win32_Storage_FileSystem (FILE_FLAGS_AND_ATTRIBUTES for SHGetFileInfoW)"
  patterns:
    - "Dedicated OS thread owns EnumWindows/COM/shell state; tokio never touches Win32 (audio_thread clone)"
    - "Pure predicate factored from OS calls for unit test (is_alt_tab_window mirrors pct_from_scalar)"
    - "Snapshot-validation for a synchronous bool over an async executor (Pattern 4 validate-on-use)"
    - "Icon cache keyed by resolved exe path — repeated windows reuse one extraction"
    - "Hand-rolled RFC 4648 base64 (pure fn, zero dep) for the wire icon"

key-files:
  created:
    - "server/server-windows/src/executors/apps.rs"
  modified:
    - "server/server-windows/src/apps_thread.rs"
    - "server/server-windows/Cargo.toml"
    - "server/server-windows/src/executors/mod.rs"
    - "server/server-windows/src/executors/stubs.rs"
    - "server/server-windows/src/main.rs"

key-decisions:
  - "Icons requested at 32x32 (SHGFI_LARGEICON) to match the plan/protocol size; hicon_to_png encodes the bitmap's ACTUAL dimensions via GetObjectW so a non-32 icon still renders honestly (never a forced rescale that GetDIBits cannot do)"
  - "shell_icon (by exe path) returns an OWNED HICON -> DestroyIcon; the WM_GETICON/class-icon fallback is BORROWED -> never destroyed (leak/double-free avoidance)"
  - "WinApps validates focus/close ids against the current snapshot BEFORE sending (stale id -> false -> err{windowGone}); the apps thread's own IsWindow is the second-line same-tick-race guard (T-06-13 accept)"
  - "UWP detection is path-based (ApplicationFrameHost.exe OR under WindowsApps\\/SystemApps\\) -> path=None non-pinnable; focus/close still work on the frame HWND"

patterns-established:
  - "Win32 icon pipeline: GetIconInfo -> GetObjectW(dims) -> GetDIBits(32bpp top-down BGRA) -> B/R swap -> png -> base64, with both bitmaps DeleteObject-d on every exit path"
  - "EnumWindows collect-then-filter: trivial FFI callback pushes HWNDs, all filtering runs after on the collected handles (no OS calls that could unwind across the extern boundary)"

requirements-completed: [APPS-01, APPS-02, APPS-03]

# Metrics
duration: 25min
completed: 2026-07-11
---

# Phase 6 Plan 02: Apps Thread + WinApps Executor Summary

**The no-op `StubApps` is replaced by a real `WinApps` backed by a dedicated apps OS thread: the server now enumerates Alt-Tab-quality windows (visible, titled, non-tool, owner-root, DWM-uncloaked) in Z-order with 32x32 base64 PNG icons and resolved exe paths (UWP -> path=None), pushes the live list on the 06-01 apps.changed seam only when it changes, and executes focus/close/launch with honest success/failure.**

## Performance

- **Duration:** ~25 min (continuation — Task 1 landed in a prior session commit `04d7ef2`)
- **Completed:** 2026-07-11
- **Tasks:** 3
- **Files:** 7 touched (1 created, 6 modified)

## Accomplishments
- **Apps OS thread** (`apps_thread.rs`): `CoInitializeEx(MTA)` once, `recv_timeout(500ms)` loop mirroring `audio_thread.rs` — executes a command then re-enumerates, else polls; `push_if_changed` value-equality gate (APPS-03 anti-flood) so `apps.changed` fires only on a real list delta.
- **Pure Alt-Tab predicate** `is_alt_tab_window(style_ex, has_title, visible, cloaked, is_root_owner)` — RESEARCH Flag 2's 5 points, unit-tested without any OS call (six exclusion cases + the WS_EX_APPWINDOW re-admit).
- **Enumeration body**: `EnumWindows` (Z-order, most-recent-first = D-07) collect-then-filter; per survivor resolve title (`GetWindowTextW`), exe path (`QueryFullProcessImageNameW` via `PROCESS_QUERY_LIMITED_INFORMATION`), and a 32x32 icon. UWP/frame-host/packaged paths map to `None` (Flag 1). List capped at 50 (Pitfall 3 wire-size guard).
- **Icon pipeline**: `SHGetFileInfoW` by exe path (owned HICON) with `WM_GETICON`/`GCLP_HICONSM` fallback (borrowed) -> `GetIconInfo` -> `GetObjectW` dims -> `GetDIBits` 32bpp top-down -> BGRA->RGBA swap -> `png`-encode -> hand-rolled base64. Cached in a `HashMap<exe_path, base64>`; all GDI bitmaps `DeleteObject`-d on every path.
- **Focus/close/launch** (`execute_cmd`): `IsWindow` validation first (dead -> `false` -> SC1 `err{windowGone}`), then the AttachThreadInput foreground dance (Pitfall 1 — never asserts success), graceful `WM_CLOSE` (never `TerminateProcess`), or `ShellExecuteW`.
- **WinApps executor** (`executors/apps.rs`): sender-only shape cloned from `WinMedia` — `list()` reads `snapshot_rx.borrow().clone()` (only synchronous touch), `focus/close` snapshot-validate the id before sending (Pattern 4), `launch` is send-and-forget over mpsc.
- **Composition root**: `main.rs` spawns `run_apps_thread`, builds `WinApps` into `Executors`, and feeds the real `apps_rx` into `ServerDeps` — the 06-01 placeholder channel is gone. `StubApps` removed (`StubClipboard` stays until 06-04).

## Task Commits

Each task was committed atomically:

1. **Task 1: apps thread skeleton — AppsCmd, Alt-Tab filter, focus/close/launch** — `04d7ef2` (feat, prior session)
2. **Task 2: window enumeration — icon PNG extraction, exe-path resolution, change-gated push** — `e6fd037` (feat)
3. **Task 3: WinApps executor + composition-root wiring** — `4fc9c43` (feat)

## Files Created/Modified
- `server/server-windows/src/apps_thread.rs` — AppsCmd, pure `is_alt_tab_window`, `execute_cmd` (focus dance/WM_CLOSE/ShellExecuteW), full `enumerate_windows` body (EnumWindows + cloak/owner filter + exe-path + icon PNG/base64 cache), `run_apps_thread` loop
- `server/server-windows/Cargo.toml` — added `Win32_Storage_FileSystem` windows feature (png 0.18 + Dwm/Gdi/UI_Shell already present from the Task 1 commit)
- `server/server-windows/src/executors/apps.rs` — new `WinApps` executor
- `server/server-windows/src/executors/mod.rs` — `pub mod apps;` + doc update
- `server/server-windows/src/executors/stubs.rs` — removed `StubApps` (only `StubClipboard` remains)
- `server/server-windows/src/main.rs` — apps-thread spawn + channels, `WinApps` in `Executors`, real `apps_rx` into `ServerDeps`, dropped `StubApps` import + placeholder channel

## Decisions Made
- **Encode the icon's actual dimensions, request 32x32.** `SHGFI_LARGEICON` asks Windows for a 32x32 icon (matching the protocol/plan size), but `hicon_to_png` reads the real bitmap dimensions via `GetObjectW` and encodes those — `GetDIBits` cannot rescale, so honoring the true size keeps the icon correct even if a shell hands back a different size.
- **Owned vs borrowed HICON discipline.** The by-path `SHGetFileInfoW` icon is owned and `DestroyIcon`-d exactly once; the `WM_GETICON`/class-icon fallback is owned by the window/class and is never destroyed — avoids both a leak and a double-free.
- **Snapshot-validated bool.** Because `Apps::focus/close` must return `bool` synchronously while the OS truth is async on the thread, `WinApps` checks the id against the current enumerated snapshot up front; a stale id returns `false` (-> `err{windowGone}`) without any OS call, and the thread's `IsWindow` guard covers the residual same-tick recycle race (T-06-13 accepted).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Added the `Win32_Storage_FileSystem` windows feature**
- **Found during:** Task 2 (first build of the enumeration body)
- **Issue:** `SHGetFileInfoW`'s `dwFileAttributes` parameter is typed `FILE_FLAGS_AND_ATTRIBUTES`, which lives under `Win32_Storage_FileSystem`. Without that feature the function and its param type fail to resolve (`E0433: could not find Storage in Win32`, `E0432: unresolved import SHGetFileInfoW`).
- **Fix:** Added `"Win32_Storage_FileSystem"` to the `windows` feature list in `server-windows/Cargo.toml`. No new crate — a feature of the already-in-tree `windows` 0.62 dep (T-06-SC verdict: accept, no package-legitimacy checkpoint).
- **Files modified:** server/server-windows/Cargo.toml
- **Verification:** `cargo build -p server-windows` clean; `cargo test -p server-windows apps` -> 4 passed
- **Committed in:** `e6fd037` (Task 2 commit)

**2. [Rule 3 - Blocking] windows 0.62 API-shape adjustments (build-fit, not behavior)**
- **Found during:** Task 2 build
- **Issue:** `BOOL` is exported from `windows::core` (not `Win32::Foundation`) in 0.62; `SendMessageW` takes `Option<WPARAM>`/`Option<LPARAM>`; the `unsafe extern` `EnumWindows` callback needs an explicit `unsafe {}` block for the raw-pointer deref (edition 2024 `unsafe_op_in_unsafe_fn`).
- **Fix:** Imported `BOOL` from `windows::core`, wrapped the `SendMessageW` params in `Some(...)`, and put the callback deref in an explicit `unsafe {}` block.
- **Files modified:** server/server-windows/src/apps_thread.rs
- **Verification:** build clean, 0 warnings introduced by this file
- **Committed in:** `e6fd037` (Task 2 commit)

---

**Total deviations:** 2 auto-fixed (both blocking build-fit). No scope change — the icon-by-path recipe is exactly the planned `SHGetFileInfoW` path; the feature/API adjustments are mechanical consequences of the `windows` 0.62 surface.

## Issues Encountered
- None beyond the build-fit adjustments above. Full `cargo test -p server-windows` -> 17 passed; whole-workspace `cargo build` clean.

## Known Stubs
- `server-windows` `executors/stubs.rs` `StubClipboard` returns empty/no-op — intentional and plan-mandated. The real arboard-backed `WinClipboard` lands in 06-04. Not goal-blocking for this plan (Apps is the 06-02 scope; Clipboard is a separate vertical slice).

## Threat Flags
None — no new security surface beyond the plan's threat register. `apps.launch` only ever receives a server-enumerated path (D-01, no user-typed paths — T-06-02); icons are fixed 32x32 PNG with the list capped at 50 (T-06-03 wire-size); HWND-recycle is validate-on-use + 500ms refresh (T-06-13 accept); the only dependency delta is a feature of the already-in-tree `windows` crate plus `png` 0.18 (T-06-SC: audited/accept, no checkpoint).

## Verification Evidence
- `cargo test -p server-windows apps` -> 4 passed (`apps_filter_excludes_non_alt_tab_windows`, `apps_filter_app_window_override_readmits_tool_window`, `apps_uwp_host_detection`, `apps_base64_encodes_rfc4648_vectors`).
- `cargo test -p server-windows` -> 17 passed, 0 failed.
- `cargo build -p server-windows` and workspace `cargo build` -> clean, 0 errors.
- Real enumeration / focus / close / launch / icon rendering are on-device UAT (06-07) — not CI-testable (real windows). The <64 KB `apps.changed` wire-size guard is also a 06-07 UAT check.

## Next Phase Readiness
- The Apps server capability is live end-to-end: 06-03 (Flutter Apps screen) can drive `apps.list`/`apps.focus`/`apps.close`/`apps.launch` and render the pushed `apps.changed` list with icons/paths against the 06-01 golden fixtures.
- No blockers. The Phase-6-flagged fiddliness (apps.focus foreground-lock, EnumWindows filtering) is implemented per RESEARCH Flags 2/4; its real-world reliability is the 06-07 on-device gate, as planned.

---
*Phase: 06-apps-clipboard*
*Completed: 2026-07-11*

## Self-Check: PASSED

- Created files verified on disk: server/server-windows/src/executors/apps.rs, server/server-windows/src/apps_thread.rs, 06-02-SUMMARY.md
- Task commits verified in git log: 04d7ef2, e6fd037, 4fc9c43
