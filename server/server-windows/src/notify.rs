//! Pairing-PIN display (D-09 / CONN-02): console print first (the
//! guaranteed path — Focus Assist / notification settings can suppress
//! toasts entirely), then a best-effort WinRT toast.
//!
//! Accepted v1 quirk: the toast uses `Toast::POWERSHELL_APP_ID` because an
//! unpackaged exe has no registered AUMID — Windows attributes the toast to
//! "Windows PowerShell". Proper AUMID registration lands with the Phase-7
//! tray.
//!
//! SECURITY (threat T-03-04): the PIN goes to stdout + toast ONLY — never
//! through tracing (the same discipline as main.rs steps 2/5). The `warn!`
//! on toast failure deliberately carries no pin.

use tauri_winrt_notification::{Duration, Toast};

/// Show the pairing PIN: console line first, then a best-effort toast.
///
/// Both pairing call sites (initial `begin_pairing` and the WR-01 refresh
/// loop) route through here, so this function owns the console format.
pub fn notify_pin(pin: &str) {
    // Console FIRST — always works, even when toasts are suppressed.
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
