//! Autostart toggle (SRV-02 / D-discretion) — a thin wrapper over
//! [`auto_launch`] that registers the server under the per-user HKCU
//! `...\CurrentVersion\Run` key so it starts with Windows.
//!
//! SECURITY (threat T-07-06, ASVS V4): this is deliberately **HKCU-only** —
//! per-user, no elevation, never HKLM (a system-wide Run entry would need
//! admin and affect every account). `auto-launch` writes HKCU on Windows by
//! default; the entry is user-togglable and visible in the settings window
//! (07-08). If [`enable`] ever returns access-denied (the crate insisting on
//! the system registry — RESEARCH Pitfall 7 / A2), the documented fallback is
//! a direct `winreg` HKCU `...\Run` write (winreg is already a dependency).
//!
//! RUNTIME STATE (RESEARCH Runtime State Inventory): the Run entry stores the
//! ABSOLUTE `current_exe()` path. Moving or renaming the exe **orphans** the
//! entry — `is_enabled()` then reports `false` and autostart silently stops
//! working until the toggle is re-applied from the new location.
//!
//! RESILIENCE: [`is_enabled`] swallows every error into `false`. A broken or
//! access-denied registry read must NEVER crash the composition root or the
//! settings window that renders the toggle — the same degrade-never-panic
//! discipline as `main.rs`'s `machine_guid()`.

// These primitives are intentionally unwired in this plan (07-03) — the
// composition root (07-06) and settings window (07-08) are the consumers.
// Scoped-allow so the interim build stays warning-clean without masking dead
// code elsewhere.
#![allow(dead_code)]

use auto_launch::AutoLaunchBuilder;

/// The Run-entry display name (the registry value name under `...\Run`).
const APP_NAME: &str = "Remote Control";

/// Build an [`auto_launch::AutoLaunch`] bound to this exe's ABSOLUTE path.
///
/// Fails only if `current_exe()` cannot be resolved or the builder rejects the
/// inputs — both are surfaced as `anyhow::Error` to the caller (the settings
/// window turns them into a non-fatal warning; the toggle stays interactive).
fn build() -> anyhow::Result<auto_launch::AutoLaunch> {
    // ABSOLUTE exe path (SRV-02, ASVS V4): a relative or bare-name path would
    // resolve against the launcher's CWD at boot and fail silently.
    let exe = std::env::current_exe()?;
    let auto = AutoLaunchBuilder::new()
        .set_app_name(APP_NAME)
        .set_app_path(exe.to_string_lossy().as_ref())
        .build()?;
    Ok(auto)
}

/// Register the server to start with Windows (HKCU `...\Run`, absolute exe).
///
/// Idempotent: re-enabling an already-enabled entry rewrites the same value.
pub fn enable() -> anyhow::Result<()> {
    build()?.enable()?;
    Ok(())
}

/// Remove the autostart Run entry (clean off). Idempotent — disabling when not
/// present is a no-op that returns `Ok`.
pub fn disable() -> anyhow::Result<()> {
    build()?.disable()?;
    Ok(())
}

/// Whether the autostart Run entry currently exists for THIS exe path.
///
/// Degrades to `false` on any error (bad `current_exe()`, registry read
/// failure, orphaned entry from a moved exe): a failed query must never panic
/// the caller — it just reports "autostart off", the safe default for a
/// settings toggle.
pub fn is_enabled() -> bool {
    match build() {
        Ok(auto) => auto.is_enabled().unwrap_or(false),
        Err(_) => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Round-trips the REAL HKCU Run key: enable → is_enabled() true →
    /// disable → is_enabled() false. `#[ignore]` because it mutates on-device
    /// OS state — run on demand with `cargo test -p server-windows autostart
    /// -- --ignored`.
    ///
    /// Cleanup is GUARANTEED: `disable()` runs unconditionally before any
    /// assertion that could unwind, so a failed assert never leaves a stray
    /// Run entry behind.
    #[test]
    #[ignore = "touches real HKCU Run key; run on-device with --ignored"]
    fn autostart_round_trip_hkcu() {
        // Start from a known-clean state (ignore result — may already be off).
        let _ = disable();

        enable().expect("enable() should write the HKCU Run entry");
        let enabled_after_enable = is_enabled();

        // Teardown BEFORE asserting so a panic can't orphan the entry.
        let _ = disable();
        let enabled_after_disable = is_enabled();

        assert!(
            enabled_after_enable,
            "is_enabled() must report true immediately after enable()"
        );
        assert!(
            !enabled_after_disable,
            "is_enabled() must report false after disable()"
        );
    }
}
