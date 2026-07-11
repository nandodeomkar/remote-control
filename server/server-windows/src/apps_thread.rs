//! Dedicated apps OS thread — the Windows body of the Apps slice (06-02), a
//! clone of [`crate::audio_thread`]'s shape (RESEARCH Pattern 1).
//!
//! One `std::thread` owns the enumeration + shell/COM state: `CoInitializeEx`
//! (MTA) runs once here (shell icon APIs), commands arrive on an `mpsc`
//! channel, and the 500 ms `recv_timeout` poll tick walks `EnumWindows`,
//! filters to Alt-Tab-quality windows (D-07), resolves each window's icon +
//! exe path, and pushes a `Vec<WindowInfo>` onto the 06-01 `apps.changed`
//! watch seam ONLY when the list actually changes (APPS-03 anti-flood).
//!
//! `focus`/`close`/`launch` execute here too (never on a tokio worker):
//! [`execute_cmd`] validates the HWND with `IsWindow` (dead → returns `false`
//! so the router can emit `err{windowGone}`, SC1), runs the AttachThreadInput
//! focus dance (Pitfall 1 — never asserts success), posts `WM_CLOSE`
//! gracefully (never `TerminateProcess`), or `ShellExecuteW`s a resolved path.
//! EVERY HRESULT is `.ok()`-dropped / `let _ =`-dropped — never a panic (the
//! send-and-forget discipline from `audio_thread.rs`).

use std::collections::HashMap;
use std::ffi::c_void;
use std::mem::size_of;
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::time::Duration;

use server_core::executors::WindowInfo;
use tokio::sync::watch::Sender;
use windows::Win32::Foundation::{CloseHandle, HWND, LPARAM, WPARAM};
use windows::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED};
use windows::Win32::Graphics::Gdi::{
    DeleteObject, GetDC, GetDIBits, GetObjectW, ReleaseDC, BITMAP, BITMAPINFO, BITMAPINFOHEADER,
    DIB_RGB_COLORS, HGDIOBJ,
};
use windows::Win32::Storage::FileSystem::FILE_FLAGS_AND_ATTRIBUTES;
use windows::Win32::System::Com::{
    CoInitializeEx, CoUninitialize, COINIT_MULTITHREADED,
};
use windows::Win32::System::Threading::{
    AttachThreadInput, GetCurrentThreadId, OpenProcess, QueryFullProcessImageNameW,
    PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows::Win32::UI::Shell::{
    SHGetFileInfoW, ShellExecuteW, SHFILEINFOW, SHGFI_ICON, SHGFI_LARGEICON,
};
use windows::Win32::UI::WindowsAndMessaging::{
    AllowSetForegroundWindow, BringWindowToTop, DestroyIcon, EnumWindows, GetAncestor,
    GetClassLongPtrW, GetForegroundWindow, GetIconInfo, GetLastActivePopup, GetWindowLongPtrW,
    GetWindowTextLengthW, GetWindowTextW, GetWindowThreadProcessId, IsIconic, IsWindow,
    IsWindowVisible, PostMessageW, SendMessageW, SetForegroundWindow, ShowWindow, ASFW_ANY,
    GA_ROOTOWNER, GCLP_HICONSM, GWL_EXSTYLE, HICON, ICONINFO, SW_RESTORE, WM_CLOSE, WM_GETICON,
    WS_EX_APPWINDOW, WS_EX_TOOLWINDOW,
};
use windows::core::{w, BOOL, PCWSTR, PWSTR};

/// Command sent from [`crate::executors::apps::WinApps`] (non-blocking mpsc
/// send) to the apps thread — mirrors [`crate::audio_thread::AudioCmd`].
#[derive(Debug, Clone, PartialEq)]
pub enum AppsCmd {
    /// Bring the window with this opaque id (HWND-as-u64, Pattern 4) forward.
    Focus(u64),
    /// Gracefully close the window with this id (posts `WM_CLOSE`).
    Close(u64),
    /// Launch a resolved exe path (`ShellExecuteW`, APPS-02).
    Launch(String),
}

/// PURE Alt-Tab-quality predicate (RESEARCH Flag 2's 5 points), factored out
/// of the OS enumeration so it unit-tests without any Win32 call — exactly as
/// `pct_from_scalar` was factored out of the audio thread.
///
/// All five inputs are already-extracted booleans/bits:
/// - `style_ex`: the window's `GWL_EXSTYLE` bits (`WS_EX_TOOLWINDOW`/`WS_EX_APPWINDOW`).
/// - `has_title`: `GetWindowTextLengthW(hwnd) > 0`.
/// - `visible`: `IsWindowVisible(hwnd)`.
/// - `cloaked`: `DwmGetWindowAttribute(DWMWA_CLOAKED) != 0` (suspended-UWP ghost / hidden desktop).
/// - `is_root_owner`: the candidate is its owner-chain root (`GetLastActivePopup` of the top owner).
///
/// A window shows in Alt-Tab iff it is visible, titled, not cloaked, the
/// owner-chain root, and either not a tool window or explicitly an app window.
pub fn is_alt_tab_window(
    style_ex: u32,
    has_title: bool,
    visible: bool,
    cloaked: bool,
    is_root_owner: bool,
) -> bool {
    if !visible || !has_title || cloaked || !is_root_owner {
        return false;
    }
    let is_tool = style_ex & WS_EX_TOOLWINDOW.0 != 0;
    let is_app = style_ex & WS_EX_APPWINDOW.0 != 0;
    // A tool window is hidden from Alt-Tab UNLESS it also flags WS_EX_APPWINDOW.
    !is_tool || is_app
}

/// Map the opaque protocol id back to an `HWND` (Pattern 4: HWND numeric value
/// cast to `u64` is the id; the cast back is O(1), validated with `IsWindow`).
fn hwnd_from_id(id: u64) -> HWND {
    HWND(id as usize as *mut core::ffi::c_void)
}

/// Best-effort focus of a live window (RESEARCH Flag 4 / Pitfall 1). Returns
/// `false` only when the HWND is already dead (SC1 `err{windowGone}`); a
/// foreground-lock miss still returns `true` — we NEVER assert the raise
/// actually succeeded (Windows may flash the taskbar button instead).
fn focus_window(hwnd: HWND) -> bool {
    // SAFETY: every call is a plain Win32 read/post; a dead HWND is rejected
    // up front and every fallible result is dropped, never unwrapped.
    unsafe {
        if !IsWindow(Some(hwnd)).as_bool() {
            return false;
        }
        // Restore first so a minimized window actually comes forward.
        if IsIconic(hwnd).as_bool() {
            let _ = ShowWindow(hwnd, SW_RESTORE);
        }
        // AttachThreadInput dance: lift the foreground lock for the duration by
        // attaching to the current foreground thread's input queue.
        let fore = GetForegroundWindow();
        let fore_thread = GetWindowThreadProcessId(fore, None);
        let this_thread = GetCurrentThreadId();
        let attached = AttachThreadInput(this_thread, fore_thread, true).as_bool();
        let _ = AllowSetForegroundWindow(ASFW_ANY);
        let _ = SetForegroundWindow(hwnd);
        let _ = BringWindowToTop(hwnd);
        if attached {
            let _ = AttachThreadInput(this_thread, fore_thread, false);
        }
        true
    }
}

/// Gracefully close a live window by posting `WM_CLOSE` (lets the app show a
/// "Save?" prompt — NEVER `TerminateProcess`). Returns `false` for a dead HWND.
fn close_window(hwnd: HWND) -> bool {
    // SAFETY: IsWindow guards the post; PostMessageW's result is dropped.
    unsafe {
        if !IsWindow(Some(hwnd)).as_bool() {
            return false;
        }
        let _ = PostMessageW(Some(hwnd), WM_CLOSE, WPARAM(0), LPARAM(0));
        true
    }
}

/// Launch a resolved exe path via `ShellExecuteW`. Returns whether the shell
/// accepted the request (`HINSTANCE` > 32 per the documented convention). The
/// path only ever originates from a server-enumerated window (D-01; no
/// user-typed paths ever reach here — T-06-02).
fn launch_path(path: &str) -> bool {
    // Widen to a NUL-terminated UTF-16 buffer for the W API.
    let wide: Vec<u16> = path.encode_utf16().chain(std::iter::once(0)).collect();
    // SAFETY: `wide` is NUL-terminated and outlives the call; the verb literal
    // is a static wide string. The returned HINSTANCE is only compared, never
    // dereferenced.
    let hinst = unsafe {
        ShellExecuteW(
            None,
            w!("open"),
            PCWSTR(wide.as_ptr()),
            PCWSTR::null(),
            PCWSTR::null(),
            windows::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL,
        )
    };
    // ShellExecuteW returns a value > 32 on success (legacy HINSTANCE contract).
    hinst.0 as usize > 32
}

/// Execute one apps command, returning honest success/failure. Focus/Close on
/// a dead HWND return `false` (the router surfaces `err{windowGone}`); Launch
/// returns the shell's own success.
fn execute_cmd(cmd: &AppsCmd) -> bool {
    match cmd {
        AppsCmd::Focus(id) => focus_window(hwnd_from_id(*id)),
        AppsCmd::Close(id) => close_window(hwnd_from_id(*id)),
        AppsCmd::Launch(path) => launch_path(path),
    }
}

/// Hard cap on the pushed window list (Pitfall 3 wire-size guard): 32×32 PNG
/// icons run ~0.5–2 KB each, so ≤50 keeps `apps.changed` well under the 64 KB
/// WS frame cap.
const MAX_WINDOWS: usize = 50;

/// `WM_GETICON` small-icon variant (2 = the per-DPI small icon). Not a named
/// constant in the `windows` crate; the raw value is documented + stable.
const ICON_SMALL2: usize = 2;

/// Map a live `HWND` to the opaque protocol id (Pattern 4 — the pointer's
/// numeric value; the inverse of [`hwnd_from_id`]).
fn id_from_hwnd(hwnd: HWND) -> u64 {
    hwnd.0 as usize as u64
}

/// `EnumWindows` callback: collect every top-level HWND into the `Vec<HWND>`
/// pointed at by `lparam`. Returns `TRUE` to keep enumerating. Filtering to
/// Alt-Tab quality happens afterward on the collected handles (keeps the
/// callback trivially correct — no OS calls that could unwind across FFI).
unsafe extern "system" fn collect_hwnd(hwnd: HWND, lparam: LPARAM) -> BOOL {
    // SAFETY: `lparam` is the `&mut Vec<HWND>` we passed into EnumWindows; it
    // outlives the synchronous enumeration and is touched by this thread only.
    let candidates = unsafe { &mut *(lparam.0 as *mut Vec<HWND>) };
    candidates.push(hwnd);
    BOOL(1)
}

/// `true` iff the window is DWM-cloaked (suspended-UWP ghost or hidden virtual
/// desktop — RESEARCH Flag 2 point 5). A failed attribute read (pre-Win8 / no
/// DWM) is treated as NOT cloaked so the other four checks still decide.
fn is_cloaked(hwnd: HWND) -> bool {
    let mut cloaked: u32 = 0;
    // SAFETY: `cloaked` is a live u32; size is passed explicitly; result dropped.
    let ok = unsafe {
        DwmGetWindowAttribute(
            hwnd,
            DWMWA_CLOAKED,
            &mut cloaked as *mut _ as *mut c_void,
            size_of::<u32>() as u32,
        )
    }
    .is_ok();
    ok && cloaked != 0
}

/// `true` iff `hwnd` is the visible root of its owner chain (RESEARCH Flag 2
/// point 4 — the classic Alt-Tab "last active popup" walk). Prevents listing a
/// dialog's owner (or vice-versa) as a second entry for the same app.
fn is_owner_chain_root(hwnd: HWND) -> bool {
    // SAFETY: pure Win32 window-relationship reads; no handles are retained.
    unsafe {
        let mut walk = GetAncestor(hwnd, GA_ROOTOWNER);
        loop {
            let try_popup = GetLastActivePopup(walk);
            if IsWindowVisible(try_popup).as_bool() {
                walk = try_popup;
                break;
            }
            if try_popup == walk {
                break;
            }
            walk = try_popup;
        }
        walk == hwnd
    }
}

/// Read the window title (`GetWindowTextW`) as a Rust `String`. Empty on any
/// failure (the caller already gated on `GetWindowTextLengthW > 0`).
fn window_title(hwnd: HWND) -> String {
    // SAFETY: length queried first; buffer sized len+1 for the API's NUL.
    unsafe {
        let len = GetWindowTextLengthW(hwnd);
        if len <= 0 {
            return String::new();
        }
        let mut buf = vec![0u16; (len + 1) as usize];
        let got = GetWindowTextW(hwnd, &mut buf);
        String::from_utf16_lossy(&buf[..got.max(0) as usize])
    }
}

/// Resolve the owning process's full exe path (RESEARCH Flag 1): PID →
/// `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` → `QueryFullProcessImageNameW`.
/// `None` on any failure (access-denied system process, race, etc.).
fn exe_path(hwnd: HWND) -> Option<String> {
    // SAFETY: the process handle is closed on every path (RAII-by-hand); the
    // image-name buffer is sized up front and the written length is honored.
    unsafe {
        let mut pid: u32 = 0;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        if pid == 0 {
            return None;
        }
        let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buf = vec![0u16; 512];
        let mut size = buf.len() as u32;
        let res = QueryFullProcessImageNameW(
            handle,
            PROCESS_NAME_WIN32,
            PWSTR(buf.as_mut_ptr()),
            &mut size,
        );
        let _ = CloseHandle(handle);
        res.ok()?;
        Some(String::from_utf16_lossy(&buf[..size as usize]))
    }
}

/// `true` for UWP/packaged windows whose resolved path is the frame host or
/// lives under the packaged-app roots (RESEARCH Flag 1). These are marked
/// `path=None` = non-pinnable in v1 (focus/close still work on the frame HWND).
fn is_uwp_host(path: &str) -> bool {
    let lower = path.to_ascii_lowercase();
    lower.ends_with("applicationframehost.exe")
        || lower.contains("\\windowsapps\\")
        || lower.contains("\\systemapps\\")
}

/// Encode a top-down RGBA buffer to PNG (the `png` crate) then base64 (hand-
/// rolled, no dep). `None` if PNG encoding fails.
fn encode_png_base64(rgba: &[u8], width: u32, height: u32) -> Option<String> {
    let mut png_bytes: Vec<u8> = Vec::new();
    {
        let mut enc = png::Encoder::new(&mut png_bytes, width, height);
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        let mut writer = enc.write_header().ok()?;
        writer.write_image_data(rgba).ok()?;
    }
    Some(base64_encode(&png_bytes))
}

/// Standard RFC 4648 base64 (with `=` padding). Hand-rolled to keep the icon
/// path dependency-free (Cargo comment: base64 is a pure fn, no crate).
fn base64_encode(data: &[u8]) -> String {
    const TABLE: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = if chunk.len() > 1 { chunk[1] as u32 } else { 0 };
        let b2 = if chunk.len() > 2 { chunk[2] as u32 } else { 0 };
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(TABLE[((n >> 18) & 63) as usize] as char);
        out.push(TABLE[((n >> 12) & 63) as usize] as char);
        out.push(if chunk.len() > 1 {
            TABLE[((n >> 6) & 63) as usize] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            TABLE[(n & 63) as usize] as char
        } else {
            '='
        });
    }
    out
}

/// Convert an `HICON` to a base64 PNG via `GetIconInfo` → `GetDIBits` (32bpp
/// top-down BGRA) → B/R swap → PNG. Both bitmaps from `GetIconInfo` are always
/// `DeleteObject`-d. `None` on any GDI failure.
fn hicon_to_png(hicon: HICON) -> Option<String> {
    // SAFETY: GetIconInfo hands us two owned HBITMAPs we must delete; every
    // fallible GDI call is checked, the DC is released, and both bitmaps are
    // freed on every exit path below.
    unsafe {
        let mut ii = ICONINFO::default();
        GetIconInfo(hicon, &mut ii).ok()?;
        let hbm_color = ii.hbmColor;
        let hbm_mask = ii.hbmMask;

        let result = (|| {
            if hbm_color.is_invalid() {
                return None;
            }
            let mut bm = BITMAP::default();
            let got = GetObjectW(
                HGDIOBJ(hbm_color.0),
                size_of::<BITMAP>() as i32,
                Some(&mut bm as *mut _ as *mut c_void),
            );
            if got == 0 {
                return None;
            }
            let width = bm.bmWidth;
            let height = bm.bmHeight;
            if width <= 0 || height <= 0 || width > 256 || height > 256 {
                return None;
            }

            let hdc = GetDC(None);
            let mut bmi = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER {
                    biSize: size_of::<BITMAPINFOHEADER>() as u32,
                    biWidth: width,
                    biHeight: -height, // negative = top-down rows
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: 0, // BI_RGB
                    ..Default::default()
                },
                ..Default::default()
            };
            let mut buf = vec![0u8; (width * height * 4) as usize];
            let scan = GetDIBits(
                hdc,
                hbm_color,
                0,
                height as u32,
                Some(buf.as_mut_ptr() as *mut c_void),
                &mut bmi,
                DIB_RGB_COLORS,
            );
            let _ = ReleaseDC(None, hdc);
            if scan == 0 {
                return None;
            }
            // DIB is BGRA; PNG wants RGBA — swap the blue/red channels in place.
            for px in buf.chunks_exact_mut(4) {
                px.swap(0, 2);
            }
            encode_png_base64(&buf, width as u32, height as u32)
        })();

        if !hbm_color.is_invalid() {
            let _ = DeleteObject(HGDIOBJ(hbm_color.0));
        }
        if !hbm_mask.is_invalid() {
            let _ = DeleteObject(HGDIOBJ(hbm_mask.0));
        }
        result
    }
}

/// Fetch a shell icon BY EXE PATH (`SHGetFileInfoW`, the natural cache key).
/// The returned `HICON` is owned by the caller — `DestroyIcon` it.
fn shell_icon(path: &str) -> Option<HICON> {
    let wide: Vec<u16> = path.encode_utf16().chain(std::iter::once(0)).collect();
    let mut shfi = SHFILEINFOW::default();
    // SAFETY: `wide` is NUL-terminated and outlives the call; the struct size
    // is passed explicitly; the returned HICON validity is checked below.
    let res = unsafe {
        SHGetFileInfoW(
            PCWSTR(wide.as_ptr()),
            FILE_FLAGS_AND_ATTRIBUTES(0),
            Some(&mut shfi),
            size_of::<SHFILEINFOW>() as u32,
            SHGFI_ICON | SHGFI_LARGEICON,
        )
    };
    if res != 0 && !shfi.hIcon.is_invalid() {
        Some(shfi.hIcon)
    } else {
        None
    }
}

/// Fallback icon straight off the WINDOW (`WM_GETICON`, then the class small
/// icon). Both handles are OWNED BY THE WINDOW/CLASS — the caller must NOT
/// destroy them.
fn window_icon(hwnd: HWND) -> Option<HICON> {
    // SAFETY: message send + class-long read; the returned handle is borrowed,
    // never freed here.
    unsafe {
        let r = SendMessageW(hwnd, WM_GETICON, Some(WPARAM(ICON_SMALL2)), Some(LPARAM(0)));
        if r.0 != 0 {
            return Some(HICON(r.0 as *mut c_void));
        }
        let cls = GetClassLongPtrW(hwnd, GCLP_HICONSM);
        if cls != 0 {
            return Some(HICON(cls as *mut c_void));
        }
        None
    }
}

/// Resolve a 32×32 base64 PNG icon for a window: prefer the by-path shell icon
/// (owned → destroyed), fall back to the window/class icon (borrowed → kept).
fn resolve_icon(path: Option<&str>, hwnd: HWND) -> Option<String> {
    if let Some(p) = path {
        if let Some(hicon) = shell_icon(p) {
            let png = hicon_to_png(hicon);
            // SAFETY: shell_icon returns an OWNED icon — destroy exactly once.
            unsafe {
                let _ = DestroyIcon(hicon);
            }
            if png.is_some() {
                return png;
            }
        }
    }
    // Borrowed icon (window/class) — hicon_to_png only reads it, never frees it.
    window_icon(hwnd).and_then(hicon_to_png)
}

/// Enumerate the current Alt-Tab-quality windows (Z-order, most-recent-first —
/// D-07) with a 32×32 base64 PNG icon and a resolved exe path each. UWP/frame-
/// host windows carry `path=None` (non-pinnable). Icons are cached by resolved
/// exe path so repeated windows reuse a single extraction. Capped at
/// [`MAX_WINDOWS`].
fn enumerate_windows(icon_cache: &mut HashMap<String, String>) -> Vec<WindowInfo> {
    let mut candidates: Vec<HWND> = Vec::new();
    // SAFETY: `collect_hwnd` only writes into `candidates`, which lives for the
    // whole synchronous enumeration; a failed EnumWindows leaves it empty.
    unsafe {
        let _ = EnumWindows(
            Some(collect_hwnd),
            LPARAM(&mut candidates as *mut _ as isize),
        );
    }

    let mut out: Vec<WindowInfo> = Vec::new();
    for hwnd in candidates {
        // SAFETY: single-value reads on a handle EnumWindows just yielded.
        let (visible, has_title, style_ex) = unsafe {
            (
                IsWindowVisible(hwnd).as_bool(),
                GetWindowTextLengthW(hwnd) > 0,
                GetWindowLongPtrW(hwnd, GWL_EXSTYLE) as u32,
            )
        };
        let cloaked = is_cloaked(hwnd);
        let root = is_owner_chain_root(hwnd);
        if !is_alt_tab_window(style_ex, has_title, visible, cloaked, root) {
            continue;
        }

        let title = window_title(hwnd);
        // Resolve the exe path, mapping UWP/frame-host paths to None (Flag 1).
        let (path, cache_key) = match exe_path(hwnd) {
            Some(p) if !is_uwp_host(&p) => (Some(p.clone()), Some(p)),
            _ => (None, None),
        };
        // Icon: cache hit by exe path, else extract once and memoize. UWP/
        // unknown-path windows use the (uncached) window/class icon.
        let icon = match &cache_key {
            Some(key) => {
                if let Some(cached) = icon_cache.get(key) {
                    Some(cached.clone())
                } else {
                    let extracted = resolve_icon(Some(key.as_str()), hwnd);
                    if let Some(ref e) = extracted {
                        icon_cache.insert(key.clone(), e.clone());
                    }
                    extracted
                }
            }
            None => resolve_icon(None, hwnd),
        };

        out.push(WindowInfo {
            id: id_from_hwnd(hwnd),
            title,
            icon,
            path,
        });
        if out.len() >= MAX_WINDOWS {
            break;
        }
    }
    out
}

/// Push the current window list onto the watch seam iff it changed since
/// `*last` (APPS-03 anti-flood — no-change ticks push nothing, the
/// `push_if_changed` value-equality discipline cloned from the audio thread).
fn push_if_changed(
    tx: &Sender<Vec<WindowInfo>>,
    last: &mut Option<Vec<WindowInfo>>,
    icon_cache: &mut HashMap<String, String>,
) {
    let windows = enumerate_windows(icon_cache);
    if last.as_ref() != Some(&windows) {
        let _ = tx.send(windows.clone());
        *last = Some(windows);
    }
}

/// Run the apps enumeration + command loop until every `Sender<AppsCmd>` is
/// dropped. MUST be called on a dedicated `std::thread`: `CoInitializeEx` is
/// called once here (shell icon APIs) and the enumeration/shell state lives
/// and dies on this thread, exactly like the audio thread's COM apartment.
pub fn run_apps_thread(rx: Receiver<AppsCmd>, tx: Sender<Vec<WindowInfo>>) {
    // SAFETY: initialize the MTA apartment once on this thread (shell icon
    // extraction needs COM). A failed init is dropped; per-tick calls then
    // simply fail and skip, never panic.
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED).ok();
    }

    let mut last: Option<Vec<WindowInfo>> = None;
    let mut icon_cache: HashMap<String, String> = HashMap::new();
    loop {
        match rx.recv_timeout(Duration::from_millis(500)) {
            // A command: execute it, then immediately re-enumerate + push so
            // the client sees the post-command list (e.g. a closed window
            // vanishing) without waiting for the next tick.
            Ok(cmd) => {
                execute_cmd(&cmd);
                push_if_changed(&tx, &mut last, &mut icon_cache);
            }
            // Poll tick: re-enumerate, push iff the list changed.
            Err(RecvTimeoutError::Timeout) => {
                push_if_changed(&tx, &mut last, &mut icon_cache);
            }
            // Every producer dropped — the server is shutting down.
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }

    // SAFETY: balance the CoInitializeEx above on thread exit (best-effort).
    unsafe {
        CoUninitialize();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The six Alt-Tab filter cases from the plan behavior spec: a normal
    /// visible titled top-level window passes; cloaked, invisible, untitled,
    /// tool-without-app, and non-root-owner windows are all excluded.
    #[test]
    fn apps_filter_excludes_non_alt_tab_windows() {
        // A normal visible, titled, non-tool, non-cloaked, root-owner window.
        assert!(
            is_alt_tab_window(0, true, true, false, true),
            "a normal visible titled top-level window must show in Alt-Tab"
        );
        // Cloaked (suspended-UWP ghost / hidden virtual desktop) → excluded.
        assert!(
            !is_alt_tab_window(0, true, true, true, true),
            "a cloaked window must be excluded"
        );
        // Not visible → excluded.
        assert!(
            !is_alt_tab_window(0, true, false, false, true),
            "an invisible window must be excluded"
        );
        // No title → excluded.
        assert!(
            !is_alt_tab_window(0, false, true, false, true),
            "an untitled window must be excluded"
        );
        // Tool window WITHOUT the app-window override → excluded.
        assert!(
            !is_alt_tab_window(WS_EX_TOOLWINDOW.0, true, true, false, true),
            "a WS_EX_TOOLWINDOW without WS_EX_APPWINDOW must be excluded"
        );
        // Not the owner-chain root → excluded.
        assert!(
            !is_alt_tab_window(0, true, true, false, false),
            "a non-root-owner window must be excluded"
        );
    }

    /// A tool window that ALSO sets WS_EX_APPWINDOW is forced back into the
    /// Alt-Tab list (the documented app-window override).
    #[test]
    fn apps_filter_app_window_override_readmits_tool_window() {
        let style = WS_EX_TOOLWINDOW.0 | WS_EX_APPWINDOW.0;
        assert!(
            is_alt_tab_window(style, true, true, false, true),
            "WS_EX_APPWINDOW must re-admit a tool window to Alt-Tab"
        );
    }

    /// UWP/packaged windows (frame host or under the packaged-app roots) are
    /// detected as non-pinnable so enumeration maps their `path` to None; a
    /// classic Win32 exe path is NOT flagged (Flag 1).
    #[test]
    fn apps_uwp_host_detection() {
        assert!(
            is_uwp_host(r"C:\Windows\System32\ApplicationFrameHost.exe"),
            "the frame host is a UWP host"
        );
        assert!(
            is_uwp_host(r"C:\Program Files\WindowsApps\Some.Package_1.0\app.exe"),
            "WindowsApps-rooted paths are packaged"
        );
        assert!(
            is_uwp_host(r"C:\Windows\SystemApps\Microsoft.Foo\bar.exe"),
            "SystemApps-rooted paths are packaged"
        );
        // Case-insensitive.
        assert!(is_uwp_host(r"c:\windows\system32\applicationframehost.EXE"));
        // A classic Win32 app resolves to a real, pinnable path.
        assert!(
            !is_uwp_host(r"C:\Program Files\Mozilla Firefox\firefox.exe"),
            "a classic Win32 exe is pinnable"
        );
    }

    /// The hand-rolled base64 encoder matches RFC 4648 vectors, including the
    /// one- and two-byte padding tails (icons are arbitrary-length PNGs).
    #[test]
    fn apps_base64_encodes_rfc4648_vectors() {
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_encode(b"f"), "Zg==");
        assert_eq!(base64_encode(b"fo"), "Zm8=");
        assert_eq!(base64_encode(b"foo"), "Zm9v");
        assert_eq!(base64_encode(b"foob"), "Zm9vYg==");
        assert_eq!(base64_encode(b"fooba"), "Zm9vYmE=");
        assert_eq!(base64_encode(b"foobar"), "Zm9vYmFy");
        // A byte that exercises the high bits (0xFF triples).
        assert_eq!(base64_encode(&[0xff, 0xff, 0xff]), "////");
    }
}
