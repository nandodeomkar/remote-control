//! Update subsystem — the ONLY place update I/O lives (Phase 12).
//!
//! This module owns ALL of it: the release-feed fetch, the asset download,
//! sha256 verification, the installer hand-off and the outcome marker. It sits
//! in `server-windows` and not in `server-core` for one structural reason —
//! `server-core` has a zero-Windows-dependencies invariant (it must keep
//! compiling on CI Linux), and every step here is Windows-shaped: `%TEMP%`,
//! an Inno setup exe, a detached `cmd.exe` helper, a process that replaces
//! itself. `server-core` is the tier that touches the wire; it must not be
//! the tier that executes files.
//!
//! **Failure posture: DEGRADE, NEVER CRASH.** No path in this module may
//! panic or take the server down. An unreachable feed, a rate limiter, a full
//! disk, a bad digest and a failed installer all end the same way — a single
//! [`UpdateError`] returned upward, reported once as `update.progress
//! {stage:"failed", error:"<code>"}`, and a server that is still sitting in
//! the tray doing everything it did before.
//!
//! # D-14 — no locator authority (the rule this module exists to enforce)
//!
//! The server resolves EVERY asset URL and EVERY hash itself, from a
//! compiled-in repo constant that lives in [`feed`]. It never accepts,
//! derives, or is influenced by a download target supplied over the wire.
//! The single value that crosses from the phone into this subsystem is a
//! version string matched against `^\d+\.\d+\.\d+$`, and it is used only to
//! decide *whether* to proceed and to name a temp file — never to say *what*
//! to fetch or *where* from.
//!
//! The reason is blunt: a wire-supplied locator is remote code execution on
//! the PC. Whoever names the file also names the process that runs with the
//! owner's privileges a moment later. So the tier that executes the installer
//! is the only tier allowed to name the file it executes, and `server-core`
//! — which decodes attacker-reachable JSON — has no path to these constants
//! at all. That absence is asserted, not assumed: the repo string must not
//! appear anywhere under `server/server-core/`.

// The submodules land across several plans (12-06 feed+download, 12-09
// apply+marker, 12-11 the thread + `WinUpdate`). This is a BINARY crate, where
// `pub` buys no dead-code exemption.
//
// 12-12 wired `WinUpdate` into `Executors`, which was supposed to be this
// allow's removal point — it is not. Probed with the allow removed, FOUR items
// in this subtree still have no caller:
//
//   - `UpdateCmd::Check`      — 12-17's settings-window "Check for updates"
//   - `marker::write_pending` — 12-09's writer, called only from the apply
//                               pipeline's hand-off, which no test drives
//   - `download::download_to` — superseded by `download_to_with_progress`;
//                               kept as the no-callback convenience form
//   - `feed::APK_ASSET_PREFIX` — the phone's asset name, resolved by the
//                                phone itself; the server never fetches it
//
// REMOVE this allow in 12-17, once the settings window constructs
// `UpdateCmd::Check` — and re-probe the other three then rather than assuming.
#![allow(dead_code)]

pub mod apply;
pub mod download;
pub mod feed;
pub mod marker;
pub mod update_thread;

/// The D-11 error vocabulary, as a Rust type.
///
/// This enum **IS** the closed vocabulary. It is never free text, and it
/// never carries a path, a URL, an HTTP status or an OS error string —
/// those go to `tracing` only, because everything here is on its way to a
/// phone screen across a trust boundary (T-12-06). Every failure in the
/// subsystem, however specific, collapses into exactly one of these seven
/// before it can reach the wire.
///
/// The list is closed on purpose: SPEC §7 defines it, the JSON schema mirrors
/// it as an enum, and `protocol/fixtures/update/` pins it. **Adding a variant
/// means amending SPEC §7 first** — not adding a variant here and letting the
/// spec catch up. A code the phone does not know is a code the phone renders
/// as nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UpdateError {
    /// The feed or the asset could not be fetched. Deliberately covers both a
    /// dead socket and a rate-limited 403 — the vocabulary has no
    /// `ratelimit`, and the two are indistinguishable to the user (D-22).
    Network,
    /// The digest did not match, OR the release carried no digest at all.
    /// An absent digest is a HARD refusal, never a skipped verification
    /// (D-15).
    Checksum,
    /// A local filesystem failure: no space, a locked temp file, a failed
    /// flush.
    Disk,
    /// The release is malformed (no matching asset, or more than one), or the
    /// installer itself exited non-zero.
    Installer,
    /// The resolved version is not newer than what is installed.
    Downgrade,
    /// The target the phone asked for is no longer what the feed offers —
    /// the phone's view is stale and it must re-check.
    Stale,
    /// An update is already in flight; the guard refused a second one.
    Busy,
}

impl UpdateError {
    /// The lowercase wire string for this error, as it appears in
    /// `update.progress {stage:"failed", error:"<code>"}`.
    ///
    /// These seven literals are the contract. They match SPEC §7's error
    /// vocabulary, the `updateError` enum in `protocol/schema/messages.schema
    /// .json`, and `protocol/fixtures/update/06-update-progress-failed-
    /// checksum.json` character for character.
    pub fn code(&self) -> &'static str {
        match self {
            UpdateError::Network => "network",
            UpdateError::Checksum => "checksum",
            UpdateError::Disk => "disk",
            UpdateError::Installer => "installer",
            UpdateError::Downgrade => "downgrade",
            UpdateError::Stale => "stale",
            UpdateError::Busy => "busy",
        }
    }

    /// Every variant, in SPEC §7 order. Exists so tests can assert over the
    /// whole vocabulary rather than over whichever variants someone
    /// remembered to list.
    pub const ALL: [UpdateError; 7] = [
        UpdateError::Network,
        UpdateError::Checksum,
        UpdateError::Disk,
        UpdateError::Installer,
        UpdateError::Downgrade,
        UpdateError::Stale,
        UpdateError::Busy,
    ];
}

/// Any local I/O failure is `disk`. The OS error text is deliberately dropped
/// here rather than wrapped: it is exactly the kind of path-bearing string
/// that must not reach the wire (T-12-06). Log it at the call site before the
/// `?` if it matters for support.
impl From<std::io::Error> for UpdateError {
    fn from(_: std::io::Error) -> Self {
        UpdateError::Disk
    }
}

impl std::fmt::Display for UpdateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.code())
    }
}

impl std::error::Error for UpdateError {}

// ── The executor ────────────────────────────────────────────────────────────

use std::sync::mpsc::Sender;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use server_core::executors::{ExtInfo, LastUpdate, UpdateExecutor, UpdateInfo, UpdateProgress};
use tokio::sync::watch;

use update_thread::{RUNNING_VERSION, UpdateCmd};

/// The Windows [`UpdateExecutor`] — the ONLY part of this subsystem the wire
/// can reach.
///
/// The shape is `server_core::transport::ext::TabsRelay`'s, applied to the
/// update thread: a `watch::Receiver` for reads, an `mpsc::Sender` for
/// fire-and-forget commands. Everything is INJECTED through [`WinUpdate::new`]
/// — the struct owns no OS handle of its own and starts no thread.
///
/// # D-14, restated where it is enforced
///
/// `target` is the only value from the wire that reaches this crate. It is
/// validated inside the refusal ladder (`^\d+\.\d+\.\d+$`) before ANY use, and
/// the asset URL and its sha256 are resolved by [`feed`] from a compiled-in
/// repo constant that `server-core` — the tier that decodes attacker-reachable
/// JSON — cannot see. There is no field on this struct, and no parameter on
/// this trait, through which a locator could arrive.
pub struct WinUpdate {
    /// Into the update thread. `std::sync::mpsc` is UNBOUNDED, so `send` never
    /// blocks; it fails only when the thread is gone. That is the house
    /// non-blocking send-and-forget rule on a hot seam, spelled the way this
    /// channel type spells it (`TabsRelay` uses tokio's bounded `try_send`).
    cmd: Sender<UpdateCmd>,
    /// A clone of the sender the thread owns, used ONLY for the immediate
    /// pre-fetch refusals.
    ///
    /// Those refusals must reach the phone WITHOUT waiting for a thread that
    /// may be 30 seconds into a download: a second tap has to answer `busy`
    /// now, not when the first attempt finishes. Nothing else is published
    /// from this side — every stage of a real attempt comes from the thread.
    progress: Arc<watch::Sender<UpdateProgress>>,
    /// Shared with the thread, which clears it on every exit path.
    busy: Arc<AtomicBool>,
    /// The extension relay's state (12-12 produces into it).
    ext: watch::Receiver<ExtInfo>,
    /// The PREVIOUS run's outcome, read from the marker file exactly once at
    /// construction and handed out exactly once by [`WinUpdate::info`] (D-12).
    pending_marker: Mutex<Option<LastUpdate>>,
}

impl WinUpdate {
    /// Pair the executor with the update thread's channels.
    ///
    /// Also does the two once-per-process-run pieces of update housekeeping,
    /// here because this is the one place guaranteed to run exactly once: the
    /// marker is READ AND DELETED ([`marker::take_marker`]), and `update.log`
    /// is truncated if the helper has grown it past its cap.
    pub fn new(
        cmd: Sender<UpdateCmd>,
        progress: Arc<watch::Sender<UpdateProgress>>,
        busy: Arc<AtomicBool>,
        ext: watch::Receiver<ExtInfo>,
    ) -> Self {
        marker::truncate_update_log_if_large();
        Self::with_marker(cmd, progress, busy, ext, marker::take_marker())
    }

    /// [`WinUpdate::new`] with the marker injected, so tests never read — and
    /// never DELETE — the real `%APPDATA%` marker of a server the developer
    /// may have running.
    fn with_marker(
        cmd: Sender<UpdateCmd>,
        progress: Arc<watch::Sender<UpdateProgress>>,
        busy: Arc<AtomicBool>,
        ext: watch::Receiver<ExtInfo>,
        pending: Option<LastUpdate>,
    ) -> Self {
        Self {
            cmd,
            progress,
            busy,
            ext,
            pending_marker: Mutex::new(pending),
        }
    }

    /// Publish one value. Send-and-forget: a `watch` with no receivers means
    /// no phone is connected, which is not a failure.
    fn publish(&self, p: UpdateProgress) {
        let _ = self.progress.send(p);
    }
}

impl UpdateExecutor for WinUpdate {
    /// A cheap read with NO I/O — the feed is never touched on the request
    /// path.
    fn info(&self) -> UpdateInfo {
        let ext = self.ext.borrow().clone();
        UpdateInfo {
            // D-05: the package's own version, never a hardcoded constant. A
            // hand-maintained version string is exactly the bug that pinned
            // the phone's pubspec.yaml at 1.0.0+1 across four shipped
            // releases — and on this side a stale literal would additionally
            // make every downgrade look like an upgrade.
            server_version: RUNNING_VERSION.to_string(),
            ext_connected: ext.connected,
            ext_version: ext.version,
            // TAKE, not clone (D-12). An outcome is reported on exactly ONE
            // update.status and never again: a marker re-reported forever
            // would keep showing the owner a failure that has since been
            // superseded, possibly by a success. This is why the read is
            // `&self` but not idempotent.
            //
            // A poisoned mutex degrades to None rather than panicking — the
            // failure posture of this whole module is DEGRADE, NEVER CRASH,
            // and a lost marker is a lost diagnosis, not a lost server.
            last_update: self.pending_marker.lock().ok().and_then(|mut g| g.take()),
        }
    }

    /// **D-14 — `target` is a version string and NOTHING else.**
    ///
    /// It is validated inside [`update_thread::pre_fetch_refusal`] before any
    /// use, and the asset URL and its sha256 are resolved from a compiled-in
    /// constant in [`feed`]. Nothing here concatenates `target` into a URL or
    /// a path; the download's `%TEMP%` filename is built by
    /// [`download::temp_path_for`] from server-owned constants, downstream of
    /// that validation and after a second check inside the thread.
    ///
    /// FIRE-AND-FORGET: everything after the refusals happens on the update
    /// thread and reports back through `update.progress`.
    fn apply(&self, target: &str) {
        // The cheap ladder runs HERE rather than on the thread so that a
        // second tap during a download is answered immediately instead of
        // queueing behind a 5 MB transfer (T-12-37).
        if let Some(e) =
            update_thread::pre_fetch_refusal(self.busy.load(Ordering::SeqCst), target, RUNNING_VERSION)
        {
            self.publish(update_thread::failed(target, e));
            return;
        }

        // Compare-and-swap, NOT a plain store: two sessions can reach the load
        // above at the same time and both see `false`. Only one may win the
        // exchange; the loser is refused exactly as if it had arrived second,
        // which it did.
        if self
            .busy
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            self.publish(update_thread::failed(target, UpdateError::Busy));
            return;
        }

        // Unbounded channel: this never blocks. A failure means the thread is
        // gone, which is an installer-side fault from the phone's point of
        // view — and the flag must not be left set by it.
        if self.cmd.send(UpdateCmd::Apply(target.to_string())).is_err() {
            self.busy.store(false, Ordering::SeqCst);
            tracing::error!("update: the update thread is gone; the apply cannot be started");
            self.publish(update_thread::failed(target, UpdateError::Installer));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The closed vocabulary, asserted over EVERY variant (not a sample).
    /// If a variant is ever added without a SPEC §7 amendment, this test is
    /// where it should hurt.
    #[test]
    fn update_error_codes_are_the_closed_vocabulary() {
        let codes: Vec<&str> = UpdateError::ALL.iter().map(|e| e.code()).collect();
        assert_eq!(
            codes,
            vec![
                "network",
                "checksum",
                "disk",
                "installer",
                "downgrade",
                "stale",
                "busy",
            ],
            "the D-11 error vocabulary is closed — amend SPEC §7 before changing this"
        );
    }

    /// Every code is lowercase, non-empty, and distinct from every other.
    #[test]
    fn update_error_codes_are_lowercase_and_unique() {
        let mut seen = std::collections::BTreeSet::new();
        for e in UpdateError::ALL {
            let c = e.code();
            assert!(!c.is_empty(), "{e:?} has an empty code");
            assert_eq!(c, c.to_ascii_lowercase(), "{e:?} code is not lowercase");
            assert!(seen.insert(c), "duplicate code {c}");
        }
        assert_eq!(seen.len(), 7);
    }

    /// An io::Error becomes `disk` and carries no OS text with it.
    #[test]
    fn update_error_io_maps_to_disk() {
        let io = std::io::Error::new(std::io::ErrorKind::NotFound, "C:\\Users\\secret\\path");
        let e: UpdateError = io.into();
        assert_eq!(e, UpdateError::Disk);
        assert_eq!(e.to_string(), "disk");
    }

    // ── WinUpdate ───────────────────────────────────────────────────────────

    /// A [`WinUpdate`] wired to test-owned channels. The marker is INJECTED,
    /// so no test reads or deletes the real `%APPDATA%` marker of a server the
    /// developer may have running.
    struct Harness {
        up: WinUpdate,
        cmds: std::sync::mpsc::Receiver<UpdateCmd>,
        progress: watch::Receiver<UpdateProgress>,
        busy: Arc<AtomicBool>,
        _ext_tx: watch::Sender<ExtInfo>,
    }

    impl Harness {
        fn new(marker: Option<LastUpdate>, ext: ExtInfo) -> Self {
            let (cmd_tx, cmds) = std::sync::mpsc::channel();
            let (ptx, progress) = watch::channel(UpdateProgress::default());
            let busy = Arc::new(AtomicBool::new(false));
            let (ext_tx, ext_rx) = watch::channel(ext);
            let up = WinUpdate::with_marker(
                cmd_tx,
                Arc::new(ptx),
                Arc::clone(&busy),
                ext_rx,
                marker,
            );
            Self {
                up,
                cmds,
                progress,
                busy,
                _ext_tx: ext_tx,
            }
        }

        fn plain() -> Self {
            Self::new(None, ExtInfo::default())
        }

        fn published(&self) -> UpdateProgress {
            self.progress.borrow().clone()
        }

        /// Drain the command channel and assert the thread was never woken.
        fn assert_nothing_sent(&self) {
            assert!(
                self.cmds.try_recv().is_err(),
                "a refusal must never reach the update thread"
            );
        }
    }

    /// A target strictly newer than the package's own version, whatever that
    /// version currently is — so the test cannot rot on a release bump.
    const NEWER: &str = "9999.0.0";

    /// D-05: the reported version is the package's own.
    #[test]
    fn win_update_info_reports_the_package_version() {
        let h = Harness::plain();
        let info = h.up.info();

        assert_eq!(info.server_version, env!("CARGO_PKG_VERSION"));
        assert!(
            !info.server_version.is_empty(),
            "an empty version would reach the wire as a broken update.status"
        );
        // The never-connected extension shape.
        assert!(!info.ext_connected);
        assert_eq!(info.ext_version, None);
        assert_eq!(info.last_update, None, "no marker is the NORMAL case");
    }

    /// The relay's extension state is read live from the watch.
    #[test]
    fn win_update_info_reads_the_ext_watch() {
        let h = Harness::new(
            None,
            ExtInfo {
                connected: true,
                version: Some("1.5.0".into()),
            },
        );
        let info = h.up.info();
        assert!(info.ext_connected);
        assert_eq!(info.ext_version.as_deref(), Some("1.5.0"));
    }

    /// D-12: the marker is handed over on exactly ONE `update.status`.
    #[test]
    fn win_update_reports_a_marker_exactly_once() {
        let marker = LastUpdate {
            target: "1.6.0".into(),
            ok: false,
            error: Some(UpdateError::Installer.code().to_string()),
        };
        let h = Harness::new(Some(marker.clone()), ExtInfo::default());

        assert_eq!(h.up.info().last_update, Some(marker));
        assert_eq!(
            h.up.info().last_update,
            None,
            "a second status must NOT re-report an outcome that has already \
             been delivered (D-12)"
        );
        assert_eq!(h.up.info().last_update, None);
    }

    /// A legal, strictly-newer target claims the busy flag and reaches the
    /// thread as a version string and nothing else.
    #[test]
    fn win_update_apply_claims_busy_and_forwards_the_target() {
        let h = Harness::plain();

        h.up.apply(NEWER);

        assert!(h.busy.load(Ordering::SeqCst), "the apply owns the flag");
        assert_eq!(
            h.cmds.try_recv().unwrap(),
            UpdateCmd::Apply(NEWER.to_string())
        );
        h.assert_nothing_sent();
    }

    /// T-12-37: a second tap during an in-flight apply is answered
    /// IMMEDIATELY, without queueing behind the download.
    #[test]
    fn win_update_apply_refuses_a_second_apply_without_touching_the_thread() {
        let h = Harness::plain();
        h.busy.store(true, Ordering::SeqCst);

        h.up.apply(NEWER);

        let p = h.published();
        assert_eq!(p.stage, update_thread::STAGE_FAILED);
        assert_eq!(p.error.as_deref(), Some(UpdateError::Busy.code()));
        assert_eq!(p.pct, None);
        h.assert_nothing_sent();
        assert!(h.busy.load(Ordering::SeqCst), "the refusal must not clear it");
    }

    /// SC6 / T-12-01: a forged, URL-shaped target is refused as stale, the
    /// thread is never woken, the flag is never claimed — and the rejected
    /// string is never reflected back onto the wire.
    #[test]
    fn win_update_apply_refuses_a_forged_target_without_touching_the_thread() {
        for forged in [
            "https://evil/x.exe",
            "..\\..\\Startup\\x",
            "9999.0.0\" & calc &",
            "v9999.0.0",
        ] {
            let h = Harness::plain();

            h.up.apply(forged);

            let p = h.published();
            assert_eq!(p.stage, update_thread::STAGE_FAILED);
            assert_eq!(
                p.error.as_deref(),
                Some(UpdateError::Stale.code()),
                "{forged:?} must be refused as stale"
            );
            assert_eq!(
                p.version, None,
                "{forged:?} must not be echoed back to the phone"
            );
            h.assert_nothing_sent();
            assert!(!h.busy.load(Ordering::SeqCst));
        }
    }

    /// D-26: the running version, and anything below it, is refused as a
    /// downgrade — before the thread, before the network.
    #[test]
    fn win_update_apply_refuses_a_downgrade_without_touching_the_thread() {
        for target in [env!("CARGO_PKG_VERSION"), "0.0.1"] {
            let h = Harness::plain();

            h.up.apply(target);

            let p = h.published();
            assert_eq!(p.stage, update_thread::STAGE_FAILED);
            assert_eq!(p.error.as_deref(), Some(UpdateError::Downgrade.code()));
            h.assert_nothing_sent();
            assert!(!h.busy.load(Ordering::SeqCst));
        }
    }

    /// A dead update thread reports `installer` and — the part that matters —
    /// gives the flag back, so the next attempt is not refused as busy
    /// forever.
    #[test]
    fn win_update_apply_clears_busy_when_the_thread_is_gone() {
        // Built by hand rather than through the harness: this test needs the
        // command RECEIVER dropped, which the harness owns.
        let (cmd_tx, cmd_rx) = std::sync::mpsc::channel();
        let (ptx, progress) = watch::channel(UpdateProgress::default());
        let busy = Arc::new(AtomicBool::new(false));
        let (_ext_tx, ext_rx) = watch::channel(ExtInfo::default());
        let up = WinUpdate::with_marker(cmd_tx, Arc::new(ptx), Arc::clone(&busy), ext_rx, None);
        drop(cmd_rx); // the thread's receiver is gone

        up.apply(NEWER);

        let p = progress.borrow().clone();
        assert_eq!(p.stage, update_thread::STAGE_FAILED);
        assert_eq!(p.error.as_deref(), Some(UpdateError::Installer.code()));
        assert!(
            !busy.load(Ordering::SeqCst),
            "a failed hand-off must not leave the guard set"
        );
    }
}
