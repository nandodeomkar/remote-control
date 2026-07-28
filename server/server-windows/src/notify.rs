//! Pairing-PIN display (D-09 / CONN-02): a console print, then a best-effort
//! WinRT toast.
//!
//! THE CONSOLE IS NO LONGER THE GUARANTEED PATH (quick 260729-4rg). Two things
//! changed since that was written: the Phase-10 pair window renders the PIN as
//! digit boxes beside a QR code, and the release binary is now
//! `windows_subsystem = "windows"` so it has no console at all. The pair
//! window is the path that always works; the toast is a convenience that Focus
//! Assist can still suppress.
//!
//! The `println!` calls below are kept deliberately — they are real output
//! under `cargo run` and a harmless no-op in a windowed build. They are not
//! dead code to be cleaned up.
//!
//! Accepted v1 quirk: the toast uses `Toast::POWERSHELL_APP_ID` because an
//! unpackaged exe has no registered AUMID — Windows attributes the toast to
//! "Windows PowerShell". Proper AUMID registration lands with the Phase-7
//! tray.
//!
//! SECURITY (threat T-03-04): the PIN goes to stdout + toast + the pair
//! window ONLY — never through tracing (the same discipline as main.rs steps
//! 2/5). That rule matters more now that tracing writes to a FILE on disk
//! (logging.rs) instead of a console that closed with the process. The `warn!`
//! on toast failure deliberately carries no pin.

use tauri_winrt_notification::{Duration, Toast};

/// Show the pairing PIN: console line, then a best-effort toast.
///
/// Both pairing call sites (initial `begin_pairing` and the WR-01 refresh
/// loop) route through here, so this function owns the console format.
pub fn notify_pin(pin: &str) {
    // Dev-build convenience only: no console exists in a release build. The
    // pair window is what the owner actually reads (see the module docs).
    println!("Pairing PIN: {pin}");

    let result = Toast::new(Toast::POWERSHELL_APP_ID)
        .title("Remote Control — pairing PIN")
        .text1(pin)
        .duration(Duration::Long) // ~25s of the 60s PIN window
        .show();
    if result.is_err() {
        // Generic on purpose: no pin in any tracing sink (T-03-04).
        tracing::warn!("toast notification failed; PIN available on console");
    }
}

/// Tell the owner the server is already up (quick 260729-38z).
///
/// Fires from the `single_instance` guard when a second launch is refused.
/// With a Start Menu entry, a desktop icon AND an autostart Run value all
/// pointing at the same exe, an accidental re-launch is routine — silence
/// would read as "the icon is broken", so the duplicate says so and points at
/// the tray.
///
/// Console line first (the guaranteed path, same as [`notify_pin`]), then a
/// best-effort toast. No secrets, no interpolated text on the failure log.
pub fn notify_already_running() {
    // ASCII-only on purpose: the Windows console defaults to a legacy OEM
    // codepage, where a UTF-8 em-dash renders as mojibake.
    println!("Remote Control is already running - look for the tray icon near the clock.");

    let result = Toast::new(Toast::POWERSHELL_APP_ID)
        .title("Remote Control is already running")
        .text1("Look for the icon in the tray near the clock.")
        .duration(Duration::Short)
        .show();
    if result.is_err() {
        tracing::warn!("already-running toast failed");
    }
}

/// Show a loud firewall-block warning toast (D-06 / SRV-04): the phone can't
/// reach the server, and the one-line `hint` tells the owner how to fix it
/// (e.g. "Allow Remote Control through Windows Firewall (TCP port 17777)").
///
/// D-06 is deliberately noisy — a firewall block silently strands the daily
/// driver, so it earns a toast on top of the tray warning state. The
/// composition root (07-06) fires this from the startup firewall self-test
/// ([`crate::firewall::inbound_allowed`] == `BlockedNoRule`).
///
/// SECURITY (threat T-07-08): the `hint` is operator-facing fix guidance only
/// — it carries NO token, PIN, or device name. On toast failure we log a
/// generic `warn!` with no interpolated text (same no-secret discipline as
/// [`notify_pin`]).
// Consumed by the composition root's startup self-test in 07-06; unwired here.
#[allow(dead_code)]
pub fn notify_firewall_warning(hint: &str) {
    let result = Toast::new(Toast::POWERSHELL_APP_ID)
        .title("Remote Control can't be reached")
        .text1(hint)
        .duration(Duration::Long)
        .show();
    if result.is_err() {
        // Generic on purpose: never echo the hint into a tracing sink.
        tracing::warn!("firewall warning toast failed");
    }
}
