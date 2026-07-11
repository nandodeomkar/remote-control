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
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::time::Duration;

use server_core::executors::WindowInfo;
use tokio::sync::watch::Sender;
use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
use windows::Win32::System::Com::{
    CoInitializeEx, CoUninitialize, COINIT_MULTITHREADED,
};
use windows::Win32::System::Threading::{AttachThreadInput, GetCurrentThreadId};
use windows::Win32::UI::Shell::ShellExecuteW;
use windows::Win32::UI::WindowsAndMessaging::{
    AllowSetForegroundWindow, BringWindowToTop, GetForegroundWindow,
    GetWindowThreadProcessId, IsIconic, IsWindow, PostMessageW, SetForegroundWindow, ShowWindow,
    ASFW_ANY, SW_RESTORE, WM_CLOSE, WS_EX_APPWINDOW, WS_EX_TOOLWINDOW,
};
use windows::core::{w, PCWSTR};

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

/// Enumerate the current Alt-Tab-quality windows with icons + resolved paths.
///
/// Task 1 stub — the real `EnumWindows` body lands in Task 2. Returns an empty
/// list so the poll loop compiles and the command path is exercisable now.
fn enumerate_windows(_icon_cache: &mut HashMap<String, String>) -> Vec<WindowInfo> {
    Vec::new()
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
}
