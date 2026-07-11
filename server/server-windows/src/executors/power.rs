//! Real `Power` executor (PWR-01..03): `LockWorkStation` / `SetSuspendState` /
//! `ExitWindowsEx` behind SE_SHUTDOWN_NAME enablement.
//!
//! EVERY method body `std::thread::spawn`s a throwaway thread and never blocks
//! the session read task (Pitfall 4 — `SetSuspendState` can block until resume;
//! even `ExitWindowsEx` does token work). All OS results are dropped
//! (`let _ =`); nothing panics. The power executor is reachable ONLY through
//! the existing router `power`→`confirm` 10s single-shot gate (T-05-11) — this
//! file adds no new call path into the `Power` trait.

use windows::core::PCWSTR;
use windows::Win32::Foundation::{CloseHandle, GetLastError, ERROR_NOT_ALL_ASSIGNED, HANDLE, LUID};
use windows::Win32::Security::{
    AdjustTokenPrivileges, LookupPrivilegeValueW, LUID_AND_ATTRIBUTES, SE_PRIVILEGE_ENABLED,
    SE_SHUTDOWN_NAME, TOKEN_ADJUST_PRIVILEGES, TOKEN_PRIVILEGES, TOKEN_QUERY,
};
use windows::Win32::System::Power::SetSuspendState;
use windows::Win32::System::Shutdown::{
    ExitWindowsEx, LockWorkStation, EWX_FORCEIFHUNG, EWX_POWEROFF, EWX_REBOOT, EXIT_WINDOWS_FLAGS,
    SHTDN_REASON_FLAG_PLANNED, SHTDN_REASON_MAJOR_OTHER, SHTDN_REASON_MINOR_OTHER,
};
use windows::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

use server_core::executors::Power;

/// Enable `SeShutdownPrivilege` on this process token (idempotent, required by
/// both `SetSuspendState` and `ExitWindowsEx` — Pitfall 1). Returns `true` only
/// when the privilege was FULLY assigned: `AdjustTokenPrivileges` reports
/// success even when it assigned nothing, so `GetLastError()` must be checked
/// against `ERROR_NOT_ALL_ASSIGNED` (T-05-08 — a silent partial grant is a
/// failure, not a success).
fn enable_shutdown_privilege() -> bool {
    // SAFETY: the standard OpenProcessToken → LookupPrivilegeValueW →
    // AdjustTokenPrivileges sequence. Each fallible call short-circuits to
    // `false`, never panics; the token handle is closed before returning.
    unsafe {
        let mut token = HANDLE::default();
        if OpenProcessToken(
            GetCurrentProcess(),
            TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY,
            &mut token,
        )
        .is_err()
        {
            return false;
        }

        let mut luid = LUID::default();
        if LookupPrivilegeValueW(PCWSTR::null(), SE_SHUTDOWN_NAME, &mut luid).is_err() {
            let _ = CloseHandle(token);
            return false;
        }

        let tp = TOKEN_PRIVILEGES {
            PrivilegeCount: 1,
            Privileges: [LUID_AND_ATTRIBUTES {
                Luid: luid,
                Attributes: SE_PRIVILEGE_ENABLED,
            }],
        };

        let adjusted = AdjustTokenPrivileges(token, false, Some(&tp), 0, None, None).is_ok();
        // Read the error BEFORE CloseHandle (which resets the thread's last
        // error). A partial grant → treat as failure (Pitfall 1).
        let fully_assigned = GetLastError() != ERROR_NOT_ALL_ASSIGNED;
        let _ = CloseHandle(token);
        adjusted && fully_assigned
    }
}

/// Windows `Power` executor. Unit struct — all state lives in the OS.
pub struct WinPower;

impl WinPower {
    /// Enable the privilege, then `ExitWindowsEx(flags | EWX_FORCEIFHUNG,
    /// planned reason)`. Runs on a throwaway thread's context (each caller
    /// spawns). `EWX_FORCEIFHUNG` force-closes ONLY hung apps — a couch user
    /// can't dismiss a "Save changes?" dialog — but never the unconditional
    /// force flag (which skips `WM_QUERYENDSESSION` → data loss); the non-zero
    /// planned `dwReason`
    /// avoids the unplanned-shutdown state capture that delays the action
    /// (Pitfalls 2/3).
    fn do_exit(flags: EXIT_WINDOWS_FLAGS) {
        if enable_shutdown_privilege() {
            // SAFETY: ExitWindowsEx is async and its result is irrelevant (the
            // box is going down); dropped, never unwrapped.
            unsafe {
                let _ = ExitWindowsEx(
                    flags | EWX_FORCEIFHUNG,
                    SHTDN_REASON_MAJOR_OTHER | SHTDN_REASON_MINOR_OTHER | SHTDN_REASON_FLAG_PLANNED,
                );
            }
        }
    }
}

impl Power for WinPower {
    fn lock(&self) {
        std::thread::spawn(|| {
            // SAFETY: LockWorkStation needs no privilege; result dropped.
            unsafe {
                let _ = LockWorkStation();
            }
        });
    }
    fn sleep(&self) {
        std::thread::spawn(|| {
            if enable_shutdown_privilege() {
                // SAFETY: hibernate=FALSE ⇒ SUSPEND (sleep), the SC2
                // requirement — NEVER hibernate. The call may block until
                // resume (A1), so it runs on this throwaway thread, never a
                // tokio worker (Pitfall 4). Return value dropped.
                unsafe {
                    let _ = SetSuspendState(false, false, false);
                }
            }
        });
    }
    fn restart(&self) {
        std::thread::spawn(|| Self::do_exit(EWX_REBOOT));
    }
    fn shutdown(&self) {
        // EWX_POWEROFF actually powers the machine off; the plain halt flag
        // would only stop Windows and leave the box powered on ("safe to turn
        // off") on some configs.
        std::thread::spawn(|| Self::do_exit(EWX_POWEROFF));
    }
}
