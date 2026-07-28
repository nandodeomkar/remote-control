//! Single-instance guard (quick 260729-38z) — a named mutex that keeps a
//! second launch from racing the first one onto the WebSocket port.
//!
//! WHY THIS EXISTS NOW: before the installer there was exactly one way to
//! start the server (run the exe out of the build directory), so a double
//! launch was a deliberate act. With a Start Menu entry, a desktop icon and
//! an autostart Run value all pointing at the same exe, "click it again
//! because I forgot it was already running" becomes the common case. Without
//! a guard that second process walks the whole composition root and only
//! fails at `main.rs` step 7's `bind()`, surfacing a misleading
//! "another app is using port ..." toast — the other app being itself.
//!
//! NAMESPACE: the name deliberately carries NO `Global\` prefix, so the mutex
//! lives in the caller's logon session. Two different Windows users may each
//! run their own copy — correct for a per-user app whose config, autostart
//! entry and paired devices are all per-user.
//!
//! FAIL-OPEN: every failure path other than a confirmed
//! `ERROR_ALREADY_EXISTS` yields a guard anyway. A broken or refused mutex
//! must never be the reason the owner cannot start their own server — the
//! same degrade-never-block discipline as `autostart::is_enabled` and
//! `main.rs`'s `machine_guid()`.

use windows::Win32::Foundation::{CloseHandle, ERROR_ALREADY_EXISTS, GetLastError, HANDLE};
use windows::Win32::System::Threading::CreateMutexW;
use windows::core::PCWSTR;

/// The mutex name, shared VERBATIM with the installer.
///
/// `installer/RemoteControl.iss` sets `AppMutex=RemoteControl.SingleInstance`
/// so Setup can detect a running copy and ask the owner to close it instead of
/// failing on a locked exe. Changing this string on one side only silently
/// breaks that detection — change both or neither.
pub const MUTEX_NAME: &str = "RemoteControl.SingleInstance";

/// Owns the process-wide instance mutex for as long as it is alive.
///
/// Held in `main` for the whole run; the handle is released on drop (and by
/// the kernel on exit, including a hard kill — Windows never leaks a mutex
/// past process death, so a crashed instance cannot lock out the next one).
pub struct InstanceGuard {
    /// `None` when the mutex could not be created at all (fail-open path):
    /// there is nothing to close, and nothing was ever held.
    handle: Option<HANDLE>,
}

impl Drop for InstanceGuard {
    fn drop(&mut self) {
        if let Some(handle) = self.handle.take() {
            // Nothing actionable on failure during teardown.
            unsafe { CloseHandle(handle) }.ok();
        }
    }
}

/// Acquire the instance mutex under [`MUTEX_NAME`].
///
/// Returns `None` — and ONLY `None` — when another instance in this logon
/// session already holds it.
pub fn acquire() -> Option<InstanceGuard> {
    acquire_named(MUTEX_NAME)
}

/// [`acquire`] with an explicit name, so tests can use their own mutex names
/// and never collide with a real running instance (or with each other, since
/// cargo runs tests in parallel threads of one process).
fn acquire_named(name: &str) -> Option<InstanceGuard> {
    let wide: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();

    // `binitialowner: false` — ownership is irrelevant here; the mutex is a
    // presence flag, never locked or waited on. Requesting ownership would
    // only add an abandoned-mutex state to reason about.
    let created = unsafe { CreateMutexW(None, false, PCWSTR(wide.as_ptr())) };

    match created {
        Ok(handle) => {
            // windows 0.62's CreateMutexW returns Ok for an ALREADY-EXISTING
            // mutex too — it only Errs on an invalid handle. So the
            // "someone else got here first" signal is the thread's last
            // error, read immediately after the successful call.
            let already_exists = unsafe { GetLastError() } == ERROR_ALREADY_EXISTS;
            if already_exists {
                unsafe { CloseHandle(handle) }.ok();
                None
            } else {
                Some(InstanceGuard {
                    handle: Some(handle),
                })
            }
        }
        // Handle creation genuinely failed (name refused, quota, policy).
        // FAIL OPEN: start the server anyway rather than block the owner.
        Err(_) => Some(InstanceGuard { handle: None }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// First acquire wins; a second acquire under the same name is refused
    /// while the first guard lives; dropping the first frees the name again.
    #[test]
    fn second_acquire_is_refused_until_the_first_guard_drops() {
        const NAME: &str = "RemoteControl.SingleInstance.test.round_trip";

        let first = acquire_named(NAME).expect("first acquire must succeed");
        assert!(
            acquire_named(NAME).is_none(),
            "a second acquire must be refused while the first guard is alive"
        );

        drop(first);
        assert!(
            acquire_named(NAME).is_some(),
            "the name must be reusable once the holding guard is dropped"
        );
    }

    /// Distinct names are independent — proves the guard keys on the name and
    /// not on some process-wide flag.
    #[test]
    fn distinct_names_do_not_collide() {
        const A: &str = "RemoteControl.SingleInstance.test.distinct_a";
        const B: &str = "RemoteControl.SingleInstance.test.distinct_b";

        let _a = acquire_named(A).expect("first name must acquire");
        assert!(
            acquire_named(B).is_some(),
            "a different mutex name must acquire independently"
        );
    }

    /// The installer's `AppMutex` directive is matched against this exact
    /// string; a rename here without the matching .iss edit breaks Setup's
    /// running-copy detection silently.
    #[test]
    fn mutex_name_matches_the_installer_contract() {
        assert_eq!(MUTEX_NAME, "RemoteControl.SingleInstance");
    }
}
