//! The record that outlives the process (D-12/D-16/D-24).
//!
//! This module owns the ONLY state that survives an update swap. Everything
//! else the update subsystem knows lives in the process that is about to be
//! replaced: for Inno's `AppMutex` gate to pass, the server MUST exit, so the
//! process that knew whether the install worked is gone before it can report
//! anything. Disk is the only tier that outlives it.
//!
//! Two files, both beside what [`crate::config`] and [`crate::logging`]
//! already write:
//!
//! - the marker JSON ([`MARKER_FILE`], beside `config.toml`) — written
//!   PESSIMISTICALLY by the server before the helper is spawned and flipped to
//!   `ok:true` by the helper only on a zero installer exit;
//! - `%APPDATA%\RemoteControl\logs\update.log` — appended by the *helper*
//!   (a `cmd` process, which cannot participate in `tracing-appender`
//!   rotation) and truncated by the *server* at startup.
//!
//! **Failure posture: DEGRADE, NEVER CRASH.** Nothing here may panic, and —
//! the rule that is easiest to get wrong — **an absent marker is the NORMAL
//! case**, not an error. It means "no previous update attempt", which is true
//! of every server that has never updated itself. A `NotFound` must produce no
//! warn, no error line and no failure on the wire.
//!
//! The two other rules that are easy to get wrong:
//!
//! - **Pessimistic first.** The marker is written BEFORE the helper is
//!   spawned, so a power cut, a crash or a helper that never starts still
//!   leaves an honest record (D-16). The optimistic rewrite is the helper's
//!   job and happens only after the installer returns zero.
//! - **Delete on READ, not on report.** [`take_marker`] removes the file the
//!   moment it parses it. Deleting only after a successful `update.status`
//!   would leave a permanent marker on a PC whose phone never reconnects, and
//!   the next connection would re-report an outcome from weeks ago.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use server_core::executors::LastUpdate;

use super::UpdateError;
use super::download::is_valid_target;

/// Marker filename. Lives beside `config.toml` because it is per-user state
/// with the same lifetime as the install, not a log.
const MARKER_FILE: &str = "update-result.json";

/// Helper-appended log filename, beside the rolling `server.log.<date>` files.
const UPDATE_LOG_FILE: &str = "update.log";

/// Truncation threshold for [`truncate_update_log_if_large`] — RESEARCH Open
/// Question 4, resolved here rather than left implicit.
///
/// A few lines per update attempt is noise, but the helper appends from a
/// `cmd` process that has no `tracing` and therefore cannot participate in
/// `tracing-appender`'s daily rotation. Unbounded-forever is not a posture; 64
/// KiB is roughly a thousand attempt lines, far more history than anyone will
/// ever read, and truncating at startup costs three lines instead of a second
/// rotation mechanism.
const MAX_UPDATE_LOG_BYTES: u64 = 64 * 1024;

/// The on-disk marker shape, shared VERBATIM with the helper script.
///
/// [`super::apply::helper_script`] writes `{"target":"<v>","ok":true}` with a
/// `cmd` `echo`, so `error` must be optional on the read side — the helper has
/// no way to emit a three-field object and no reason to.
#[derive(Debug, Serialize, Deserialize)]
struct MarkerFile {
    target: String,
    ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

/// `%APPDATA%/RemoteControl/` + [`MARKER_FILE`], resolved exactly the way
/// [`crate::config::config_path`] resolves `config.toml` — via
/// `dirs::config_dir()`, never a raw environment-variable read (RESEARCH A5).
///
/// A `None` known folder (never seen on real Windows) degrades to a relative
/// path rather than panicking — the same degrade-never-panic fallback the
/// config and log paths use.
pub fn marker_path() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_default()
        .join("RemoteControl")
        .join(MARKER_FILE)
}

/// `%APPDATA%/RemoteControl/logs/update.log` — beside the rolling
/// `server.log.<date>` files [`crate::config::log_dir`] hosts, so "where are
/// the logs" has one answer. Same degrade-never-panic resolution.
pub fn update_log_path() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_default()
        .join("RemoteControl")
        .join("logs")
        .join(UPDATE_LOG_FILE)
}

/// Write the PESSIMISTIC marker `{target, ok:false, error:"installer"}`.
///
/// Called BEFORE the helper is spawned (D-16). Every way the process can die
/// from here on — a crash, a power cut, a helper that never starts, an
/// installer that aborts — leaves this record, and the only thing that can
/// improve it is the helper observing a zero exit code.
///
/// A write failure is logged at warn and SWALLOWED. It must never abort the
/// update: losing the diagnosis is bad, refusing the update the owner asked
/// for because the diagnosis could not be filed is worse. The returned unit is
/// deliberate — there is no failure for a caller to handle.
pub fn write_pending(target: &str) {
    write_pending_at(&marker_path(), target);
}

/// [`write_pending`] against an explicit path, so tests never touch the real
/// `%APPDATA%`.
fn write_pending_at(path: &Path, target: &str) {
    debug_assert!(
        is_valid_target(target),
        "write_pending called with an unvalidated target: {target:?} — \
         the caller must enforce ^\\d+\\.\\d+\\.\\d+$ first (T-12-26)"
    );

    let marker = MarkerFile {
        target: target.to_string(),
        ok: false,
        error: Some(UpdateError::Installer.code().to_string()),
    };

    let json = match serde_json::to_string(&marker) {
        Ok(j) => j,
        Err(e) => {
            tracing::warn!("update: could not serialise the marker ({e}); continuing anyway");
            return;
        }
    };

    // The parent exists on every real install (config.toml lives there), but
    // creating it is cheaper than a first-run edge case that silently loses
    // the marker.
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    if let Err(e) = std::fs::write(path, json) {
        // The path is not logged: it is exactly the kind of detail that must
        // not travel, and there is only one path this can be.
        tracing::warn!(
            "update: could not write the pending marker ({}); the outcome will not be reportable",
            e.kind()
        );
    }
}

/// Read the marker, DELETE the file, and return what it said.
///
/// `None` is the normal answer. It means one of:
/// - no marker exists (no previous update attempt) — the overwhelmingly
///   common case, and NOT an error: no warn, no error line, nothing on the
///   wire;
/// - the file was unreadable or unparseable, in which case it is deleted
///   anyway so a corrupt marker cannot outlive one startup.
///
/// The delete happens on READ rather than on report, on purpose: a phone that
/// never reconnects must not leave a permanent marker that re-reports a stale
/// outcome forever (D-12).
pub fn take_marker() -> Option<LastUpdate> {
    take_marker_at(&marker_path())
}

/// [`take_marker`] against an explicit path, so tests never touch the real
/// `%APPDATA%`.
fn take_marker_at(path: &Path) -> Option<LastUpdate> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        // The NORMAL case. Mirrors config::load's NotFound arm — no warn.
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return None,
        Err(e) => {
            tracing::warn!("update: could not read the marker ({}); ignoring it", e.kind());
            let _ = std::fs::remove_file(path);
            return None;
        }
    };

    // Delete FIRST, then decide. Whatever the content turns out to be, this
    // marker has now been consumed exactly once — an early return below must
    // not be able to leave the file behind.
    let _ = std::fs::remove_file(path);

    let parsed: MarkerFile = match serde_json::from_str(&text) {
        Ok(m) => m,
        Err(_) => {
            // The content is NOT logged: a corrupt marker could hold anything
            // (config::parse's precedent).
            tracing::warn!("update: the marker was unparseable; discarding it");
            return None;
        }
    };

    // The marker crosses into `update.status` and therefore onto the wire, so
    // it is validated as if it came from outside — a marker is a local file a
    // corrupted disk or a local process can shape.
    if !is_valid_target(&parsed.target) {
        tracing::warn!("update: the marker carried a malformed target; discarding it");
        return None;
    }

    // `error` belongs to a failure and to the closed D-11 vocabulary alone
    // (T-12-06). A success drops it; an unrecognised code collapses to
    // `installer` rather than travelling verbatim.
    let error = if parsed.ok {
        None
    } else {
        Some(normalise_error(parsed.error.as_deref()))
    };

    Some(LastUpdate {
        target: parsed.target,
        ok: parsed.ok,
        error,
    })
}

/// Coerce a marker's `error` into the closed D-11 vocabulary.
///
/// Pure, so the coercion is testable without disk. Anything absent or
/// unrecognised becomes `installer`: a failed update whose cause did not
/// survive is still an installer failure, and a code the phone does not know
/// renders as nothing at all.
fn normalise_error(raw: Option<&str>) -> String {
    let code = raw.unwrap_or_default();
    UpdateError::ALL
        .iter()
        .find(|e| e.code() == code)
        .map_or(UpdateError::Installer, |e| *e)
        .code()
        .to_string()
}

/// Truncate `update.log` at startup when it has grown past
/// [`MAX_UPDATE_LOG_BYTES`] (RESEARCH Open Question 4).
///
/// The server owns this because the helper cannot: the helper is a `cmd`
/// process appending with `>>`, outside `tracing-appender` entirely. Every
/// failure is swallowed — an untruncatable log is not a reason to do anything
/// differently.
pub fn truncate_update_log_if_large() {
    truncate_update_log_if_large_at(&update_log_path());
}

/// [`truncate_update_log_if_large`] against an explicit path.
fn truncate_update_log_if_large_at(path: &Path) {
    if let Ok(md) = std::fs::metadata(path)
        && md.len() > MAX_UPDATE_LOG_BYTES
    {
        let _ = std::fs::write(path, b"");
        tracing::info!("update: update.log exceeded {MAX_UPDATE_LOG_BYTES} bytes; truncated");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    /// A unique scratch directory per test — the suite runs threaded, so a
    /// shared filename would let one test delete another's fixture. The real
    /// `%APPDATA%` is never touched by anything in this module's tests.
    fn scratch_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "rc-marker-test-{}-{tag}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create scratch dir");
        dir
    }

    /// The whole D-12 lifecycle in one test: pessimistic write, read-and-
    /// delete, and a second take that finds nothing.
    #[test]
    fn marker_lifecycle() {
        let dir = scratch_dir("lifecycle");
        let marker = dir.join(MARKER_FILE);

        write_pending_at(&marker, "1.6.0");
        assert!(marker.exists(), "write_pending must leave a file behind");

        let taken = take_marker_at(&marker).expect("the marker must be readable");
        assert_eq!(
            taken,
            LastUpdate {
                target: "1.6.0".into(),
                ok: false,
                error: Some("installer".into()),
            },
            "the pessimistic marker is ok:false / installer"
        );

        assert!(
            !marker.exists(),
            "take_marker must DELETE the file it read (delete on read, not on report)"
        );
        assert!(
            take_marker_at(&marker).is_none(),
            "an outcome is reported once, never twice"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The normal case: no marker, no value, and — the part that matters — no
    /// file conjured into existence by the read.
    #[test]
    fn absent_marker_is_the_normal_case() {
        let dir = scratch_dir("absent");
        let marker = dir.join(MARKER_FILE);

        assert!(take_marker_at(&marker).is_none());
        assert!(!marker.exists(), "reading must not create anything");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The helper's optimistic rewrite, byte-for-byte as the `cmd` `echo`
    /// emits it — two fields, no `error`, and a trailing CRLF.
    #[test]
    fn helper_written_success_marker_parses_without_an_error_field() {
        let dir = scratch_dir("ok");
        let marker = dir.join(MARKER_FILE);
        std::fs::write(&marker, "{\"target\":\"1.6.0\",\"ok\":true}\r\n").unwrap();

        let taken = take_marker_at(&marker).expect("the helper's marker must parse");
        assert_eq!(
            taken,
            LastUpdate {
                target: "1.6.0".into(),
                ok: true,
                error: None,
            }
        );
        assert!(!marker.exists());

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A success that somehow carries an error drops it — `error` is present
    /// only when `ok` is false (D-12).
    #[test]
    fn a_successful_marker_never_carries_an_error() {
        let dir = scratch_dir("ok-with-error");
        let marker = dir.join(MARKER_FILE);
        std::fs::write(
            &marker,
            "{\"target\":\"1.6.0\",\"ok\":true,\"error\":\"installer\"}",
        )
        .unwrap();

        assert_eq!(take_marker_at(&marker).unwrap().error, None);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Corrupt content yields `None` AND takes the file with it, so a bad
    /// marker cannot outlive one startup.
    #[test]
    fn a_corrupt_marker_is_discarded_and_deleted() {
        for (tag, body) in [
            ("truncated", "{\"target\":\"1.6.0\""),
            ("not-json", "not json at all"),
            ("empty", ""),
            ("wrong-types", "{\"target\":5,\"ok\":\"yes\"}"),
        ] {
            let dir = scratch_dir(tag);
            let marker = dir.join(MARKER_FILE);
            std::fs::write(&marker, body).unwrap();

            assert!(take_marker_at(&marker).is_none(), "{tag} should be discarded");
            assert!(!marker.exists(), "{tag} must not survive the read");

            let _ = std::fs::remove_dir_all(&dir);
        }
    }

    /// A marker's `target` reaches the wire through `update.status`, so a
    /// malformed one is refused rather than relayed.
    #[test]
    fn a_marker_with_a_malformed_target_is_discarded() {
        let dir = scratch_dir("bad-target");
        let marker = dir.join(MARKER_FILE);
        std::fs::write(&marker, "{\"target\":\"../../evil\",\"ok\":true}").unwrap();

        assert!(take_marker_at(&marker).is_none());
        assert!(!marker.exists());

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// An error code outside the closed D-11 vocabulary never travels
    /// verbatim (T-12-06).
    #[test]
    fn an_unknown_error_code_collapses_to_installer() {
        assert_eq!(normalise_error(None), "installer");
        assert_eq!(normalise_error(Some("")), "installer");
        assert_eq!(normalise_error(Some("C:\\Users\\me\\secret")), "installer");
        assert_eq!(normalise_error(Some("ratelimit")), "installer");
        // Every real code survives unchanged.
        for e in UpdateError::ALL {
            assert_eq!(normalise_error(Some(e.code())), e.code());
        }
    }

    /// Above the threshold the log is emptied; at or below it is left exactly
    /// as the helper wrote it.
    #[test]
    fn update_log_truncates_only_above_the_threshold() {
        let dir = scratch_dir("log");

        let big = dir.join("big.log");
        std::fs::write(&big, vec![b'x'; (MAX_UPDATE_LOG_BYTES + 1) as usize]).unwrap();
        truncate_update_log_if_large_at(&big);
        assert_eq!(std::fs::metadata(&big).unwrap().len(), 0);
        assert!(big.exists(), "truncation must not delete the file");

        let small = dir.join("small.log");
        std::fs::write(&small, b"[date] setup exited 5\r\n").unwrap();
        truncate_update_log_if_large_at(&small);
        assert_eq!(
            std::fs::read_to_string(&small).unwrap(),
            "[date] setup exited 5\r\n",
            "a small log must be left alone"
        );

        // An absent log is not an error either.
        truncate_update_log_if_large_at(&dir.join("nope.log"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The two runtime paths land where config.rs and logging.rs already
    /// write, and are derived from the same known folder.
    #[test]
    fn paths_sit_beside_the_existing_appdata_state() {
        let m = marker_path();
        assert_eq!(m.file_name().unwrap(), MARKER_FILE);
        assert_eq!(m.parent().unwrap(), crate::config::config_path().parent().unwrap());

        let l = update_log_path();
        assert_eq!(l.file_name().unwrap(), UPDATE_LOG_FILE);
        assert_eq!(l.parent().unwrap(), crate::config::log_dir());
    }
}
