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
