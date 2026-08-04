//! The update thread — ALL blocking update work, on a dedicated OS thread,
//! never on the tokio runtime.
//!
//! `ureq` is blocking BY DESIGN (see the dependency note in `Cargo.toml`), so
//! a feed GET or a ~5 MB asset download called from a tokio task would park a
//! runtime worker for the entire duration — mouse frames and key frames
//! included. This module is therefore the same shape as
//! [`crate::apps_thread`], [`crate::clip_thread`] and [`crate::audio_thread`]:
//! one `std::thread`, commanded over a `std::sync::mpsc`, publishing state
//! outward over a `tokio::sync::watch`.
//!
//! # The refusal ladder (D-15) is pure, and its ORDER is the point
//!
//! Everything a refusal needs to decide is a string comparison, so the whole
//! ladder is factored OUT of the thread as pure functions — the same rule
//! `clip_thread` follows for its OS call and `audio_thread` follows for
//! `pct_from_scalar`. That is what lets a test assert the ORDER rather than
//! merely the outcomes:
//!
//! ```text
//! 1. busy       — an apply is already in flight            (cheapest, no I/O)
//! 2. target shape — not ^\d+\.\d+\.\d+$                    (pure, no I/O)
//! 3. downgrade  — target <= CARGO_PKG_VERSION              (pure, no I/O)
//! ── the network starts only here ──
//! 4. <fetch the feed>                                      (failure => network)
//! 5. stale      — target != the version WE just resolved
//! 6. <resolve the asset by name>                           (absent => installer)
//! 7. <download>                                            (failure => network/disk)
//! 8. checksum   — digest mismatch => delete, never execute
//! ```
//!
//! The cheap checks come first so that a forged, hostile or merely stale
//! target costs nothing: a `update.apply` naming a URL is refused with ZERO
//! network activity (SC6).

use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Receiver;
use std::time::{Duration, Instant};

use server_core::executors::UpdateProgress;
use server_core::version::{compare_versions, VersionOrder};
use tokio::sync::watch;

use super::feed::{Asset, Release};
use super::{UpdateError, apply, download, feed};

/// The running version, from the package itself (D-05) — NEVER a hardcoded
/// constant. A hand-maintained version string is exactly the bug that pinned
/// the phone's `pubspec.yaml` at `1.0.0+1` across four shipped releases, and
/// on this side it would additionally break the downgrade refusal: a stale
/// literal makes every version "newer".
///
/// `pub(super)` so [`super::WinUpdate`] answers `update.status` from the SAME
/// constant the refusal ladder is anchored to. Two reads of `env!` would be
/// two things to keep in step for no benefit.
pub(super) const RUNNING_VERSION: &str = env!("CARGO_PKG_VERSION");

/// `^\d+\.\d+\.\d+$`, RE-EXPORTED rather than re-implemented.
///
/// [`super::download::is_valid_target`] is the crate's single version-shape
/// validator; 12-06 made it `pub` precisely so later plans would not invent a
/// second regex that could drift from it. A second validator is a second
/// answer to "what is a legal target", and the weaker of two answers is the
/// one an attacker gets to use.
///
/// It runs BEFORE `target` is interpolated into a path or a generated command
/// line. Without it a target of `..\..\Startup\x` reaches a filename under
/// `%TEMP%` — and therefore a directory Windows executes on login — and a
/// target carrying a quote and an ampersand reaches `cmd.exe` as the helper
/// script's `set "TARGET=..."` line (T-12-13/T-12-26).
pub use super::download::is_valid_target;

/// The D-10 stage vocabulary, as constants.
///
/// This is the CLOSED list from SPEC §7; the schema's `enum` and
/// `protocol/fixtures/update/` mirror it. It lives here as `const`s so the two
/// surfaces that publish stages — this thread and 12-17's settings window —
/// spell them the same way, and so a typo is a compile error rather than a
/// value the phone silently renders as nothing.
pub const STAGE_CHECKING: &str = "checking";
pub const STAGE_DOWNLOADING: &str = "downloading";
pub const STAGE_VERIFYING: &str = "verifying";
pub const STAGE_INSTALLING: &str = "installing";
pub const STAGE_RESTARTING: &str = "restarting";
/// Terminal: the check completed. See [`run_check`] for what the accompanying
/// `version` means — the consumer, not this stage, decides "available".
pub const STAGE_UPTODATE: &str = "uptodate";
/// Terminal: always accompanied by an `error` from [`UpdateError::code`].
pub const STAGE_FAILED: &str = "failed";

/// A command for the update thread.
///
/// [`UpdateCmd::Apply`]'s payload is **a version string and nothing else**
/// (D-14). It is not a URL, not a filename, not an asset id and not a hash:
/// the thread resolves the download locator and its sha256 itself, from the
/// compiled-in constants in [`super::feed`]. Widening this variant would
/// convert a paired phone — or anything that ever obtained a token — into
/// arbitrary code execution on the PC.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UpdateCmd {
    /// Fetch the feed and report what "latest" is. The PC settings window's
    /// own check (12-17); the phone's `update.check` is answered synchronously
    /// from `UpdateInfo` and never enters here.
    Check,
    /// Install this version. The string is a version, and only a version.
    Apply(String),
}

/// The three cheap refusals, in the ONE order they may run in (D-15).
///
/// Pure: no file is opened, no socket is created, no clock is read. That is
/// not tidiness — it is the property that makes a forged
/// `update.apply {target: "https://evil/x.exe"}` cost the machine nothing at
/// all (SC6, T-12-01).
///
/// The order, and why each step is where it is:
///
/// 1. **`busy`** — cheapest possible check, a single atomic load at the call
///    site. A second tap during a download must be answered immediately
///    rather than queued behind a 5 MB transfer.
/// 2. **target shape** — a malformed target is reported as
///    [`UpdateError::Stale`], deliberately NOT as a shape/parse error. The
///    D-11 vocabulary is closed and has no such code, and "that is not the
///    version I resolved" is a truthful description of a target the server
///    cannot even parse. It is also the least informative answer available to
///    give an attacker probing the seam.
/// 3. **downgrade** — an integer tuple comparison against the running
///    version, via `server_core::version::compare_versions` (D-26, the SAME
///    comparator the phone is pinned to through
///    `protocol/fixtures/update/10-version-compare.json`). NEVER a lexical or
///    float comparison: `"1.10.0" < "1.9.0"` as strings, and `1.10 < 1.9` as
///    floats. Anything that is not strictly newer is refused, and an
///    `Unknown` comparison is refused too — unknown is never newer.
///
/// Returns `None` when all three pass, which is the only state in which the
/// network may be touched.
pub fn pre_fetch_refusal(busy: bool, target: &str, running: &str) -> Option<UpdateError> {
    // 1. Cheapest first, and no I/O (D-15).
    if busy {
        return Some(UpdateError::Busy);
    }
    // 2. Shape, BEFORE the value is used for anything at all.
    if !is_valid_target(target) {
        return Some(UpdateError::Stale);
    }
    // 3. Pure integer-tuple ordering (D-15, D-26).
    if compare_versions(target, running) != VersionOrder::Newer {
        return Some(UpdateError::Downgrade);
    }
    None
}

/// The post-fetch refusal: the phone's target must equal the version the
/// SERVER itself just resolved.
///
/// The server trusts only what it just fetched. The phone's cached feed can be
/// up to 24 hours old (D-07), so the phone's opinion of "latest" is ADVISORY —
/// it decides what to offer, never what the server installs. A release
/// published, replaced or unpublished in that window leaves the phone asking
/// for a version that is no longer the answer, and the honest response is
/// [`UpdateError::Stale`]: re-check, then ask again.
///
/// The same rule closes the replay seam (T-12-36): a captured `update.apply`
/// naming an older release cannot be replayed into an install, because the
/// version the server resolves a moment later will not match it.
pub fn post_fetch_refusal(target: &str, resolved_latest: &str) -> Option<UpdateError> {
    if target == resolved_latest {
        return None;
    }
    tracing::warn!(
        "update: refusing an apply for a target that is not the freshly resolved latest"
    );
    Some(UpdateError::Stale)
}

// ── Published values ────────────────────────────────────────────────────────
//
// Three constructors, and NOTHING else builds an `UpdateProgress` in this
// module. Everything that reaches them is either a closed-vocabulary constant
// or a value derived from one, which is how the D-10/D-11 rules stay true by
// construction instead of by review:
//
//   - `pct` is set ONLY by `downloading` (D-10);
//   - `error` is set ONLY by `failed`, and ALWAYS from [`UpdateError::code`]
//     (D-11) — no path, URL, HTTP status or OS error string can reach a
//     published value, because none of these functions accepts one (T-12-06).
//     Those details go to `tracing` and `update.log`.

/// The `version` a published value may carry for `target`.
///
/// `None` for anything that is not three integers. A malformed target is
/// ATTACKER-SUPPLIED TEXT, and echoing it back on the wire would turn a
/// refusal into a reflection: `update.apply {target: "<script>…"}` answered
/// with that same string rendered on the phone's Updates screen. The refusal
/// is the message; the rejected value is not part of it.
fn safe_version(target: &str) -> Option<String> {
    is_valid_target(target).then(|| target.to_string())
}

/// A plain stage with no `pct` and no `error`.
fn stage_only(stage: &str, target: &str) -> UpdateProgress {
    UpdateProgress {
        stage: stage.to_string(),
        pct: None,
        version: safe_version(target),
        error: None,
    }
}

/// The ONLY constructor that sets `pct` (D-10).
fn downloading(target: &str, pct: u8) -> UpdateProgress {
    UpdateProgress {
        stage: STAGE_DOWNLOADING.to_string(),
        pct: Some(pct),
        version: safe_version(target),
        error: None,
    }
}

/// The ONLY constructor that sets `error`, and it takes an [`UpdateError`] —
/// not a string — so the closed D-11 vocabulary is the only thing expressible.
///
/// `pub(super)` because [`super::WinUpdate`] publishes the pre-fetch refusals
/// itself, without waking the thread. It must build them the same way.
pub(super) fn failed(target: &str, e: UpdateError) -> UpdateProgress {
    UpdateProgress {
        stage: STAGE_FAILED.to_string(),
        pct: None,
        version: safe_version(target),
        error: Some(e.code().to_string()),
    }
}

// ── Progress throttling (RESEARCH Pattern 1) ────────────────────────────────

/// Minimum wall-clock gap between two `downloading` publications — the house
/// 250 ms cadence `clip_thread` and `audio_thread` already poll at.
pub const PROGRESS_MIN_INTERVAL: Duration = Duration::from_millis(250);

/// Integer percent of `read` against `total`, clamped into 0..=100.
///
/// A zero `total` yields 0 rather than dividing: a Content-Length-less or
/// zero-sized asset must not panic a download.
pub fn pct_of(read: u64, total: u64) -> u8 {
    if total == 0 {
        return 0;
    }
    ((read.min(total) * 100) / total) as u8
}

/// Should this byte count be published, given the last percent published and
/// how long ago that was? `Some(pct)` means publish; `None` means skip.
///
/// PURE, so the 1 %/250 ms rule is testable with no download. Three clauses,
/// each with a reason:
///
/// - **never republish the same percent.** The `watch` channel coalesces by
///   design, so a repeat carries no information at all.
/// - **at most one publication per 250 ms** otherwise. A 64 KiB chunk loop on
///   a fast LAN produces callbacks far faster than any UI can render, and the
///   phone's screen updates no faster than its frame rate.
/// - **100 % always publishes.** It is the last callback the loop will ever
///   make; dropping it for being 3 ms early would leave the progress bar
///   parked at 97 % until the `verifying` stage replaced it.
pub fn should_emit_pct(read: u64, total: u64, last_pct: u8, since_last: Duration) -> Option<u8> {
    let pct = pct_of(read, total);
    if pct <= last_pct {
        return None;
    }
    if pct == 100 || since_last >= PROGRESS_MIN_INTERVAL {
        return Some(pct);
    }
    None
}

// ── The injectable I/O seam ─────────────────────────────────────────────────

/// Every blocking step of the pipeline, behind one trait.
///
/// It exists so the ORDER of the pipeline — which is a security property, not
/// an implementation detail — can be tested without a socket, without a disk
/// write and, above all, without spawning a detached process that installs
/// software. [`RealOps`] is the only production implementation; the test
/// double lives in this file's `#[cfg(test)]` module.
///
/// `resolve_setup` is deliberately ABSENT: asset resolution is pure and lives
/// in [`feed`], which is the module D-14 designates as the locator authority.
/// Making it injectable would make the locator injectable.
trait ApplyOps {
    fn fetch_latest(&self) -> Result<Release, UpdateError>;
    fn download(
        &self,
        asset: &Asset,
        dest: &Path,
        on_progress: &mut dyn FnMut(u64),
    ) -> Result<(), UpdateError>;
    fn verify(&self, path: &Path, expected_hex: &str) -> Result<(), UpdateError>;
    fn begin_apply(&self, target: &str, setup: &Path) -> Result<(), UpdateError>;
    /// End this process so the installer can replace its exe. Never returns in
    /// production.
    fn exit_process(&self);
}

/// The production [`ApplyOps`]: the two `ureq` agents plus the real
/// filesystem and process calls.
struct RealOps {
    feed_agent: ureq::Agent,
    download_agent: ureq::Agent,
}

impl RealOps {
    fn new() -> Self {
        Self {
            feed_agent: feed::feed_agent(),
            download_agent: download::download_agent(),
        }
    }
}

/// How long the thread waits after publishing `restarting` before ending the
/// process.
///
/// The session loop has to observe the `watch` change and write one small
/// frame; this is the window in which it can. Without it the process exits
/// while the last stage is still in a channel and the phone's last observed
/// state is `installing` until its reconnect FSM (D-17) brings it back — a
/// visibly stuck update that in fact succeeded. Generous rather than tight:
/// the installer's own wait-for-PID poll is ~1 s per iteration, so this costs
/// nothing measurable in the overall swap.
const RESTART_FLUSH_GRACE: Duration = Duration::from_millis(750);

impl ApplyOps for RealOps {
    fn fetch_latest(&self) -> Result<Release, UpdateError> {
        feed::fetch_latest(&self.feed_agent)
    }

    fn download(
        &self,
        asset: &Asset,
        dest: &Path,
        on_progress: &mut dyn FnMut(u64),
    ) -> Result<(), UpdateError> {
        download::download_to_with_progress(&self.download_agent, &asset.url, dest, on_progress)
    }

    fn verify(&self, path: &Path, expected_hex: &str) -> Result<(), UpdateError> {
        download::verify_or_delete(path, expected_hex)
    }

    fn begin_apply(&self, target: &str, setup: &Path) -> Result<(), UpdateError> {
        apply::begin_apply(target, setup)
    }

    /// Give the session loop its flush window, then end the process.
    ///
    /// `std::process::exit` is the crate's existing shutdown path — it is
    /// exactly what the tray's Quit action does (`shell::mod`'s
    /// `ShellAction::Quit` arm). THE CHOICE IS DELIBERATE over returning a
    /// signal for `main` to act on: by this point the detached helper is
    /// already polling for this PID to disappear, and every second the process
    /// lingers is a second the helper spends against its bounded 30-poll wait.
    /// A graceful unwind through the accept loop would have to be plumbed
    /// through the shell's winit loop on another thread, and a failure
    /// anywhere in that plumbing would leave the helper timing out and the
    /// update silently not happening.
    fn exit_process(&self) {
        std::thread::sleep(RESTART_FLUSH_GRACE);
        tracing::info!("update: exiting so the installer can replace this exe");
        std::process::exit(0);
    }
}

// ── The two command arms ────────────────────────────────────────────────────

/// [`UpdateCmd::Check`]: fetch the feed and report what "latest" is.
///
/// This arm serves the PC settings window (12-17). The phone's `update.check`
/// is answered synchronously from `UpdateInfo` and never enters here.
///
/// # Why the terminal is `uptodate` in both outcomes
///
/// The D-10 stage vocabulary is CLOSED (SPEC §7) and has no `available` stage;
/// adding one means amending SPEC §7, the JSON schema and both codecs first,
/// which is not this plan's business. So the check's terminal is `uptodate` in
/// both cases, and the `version` field carries the distinction:
///
/// - **absent** — nothing newer exists. The consumer renders its own
///   `CARGO_PKG_VERSION` beside "up to date"; it needs no help from us.
/// - **present** — this is the strictly-newer version the SERVER resolved, and
///   the only value 12-17's `Update now` button may ever send back as an
///   `Apply` target. It is never a value a human typed or pasted.
fn run_check(ops: &dyn ApplyOps, running: &str, emit: &mut dyn FnMut(UpdateProgress)) {
    emit(stage_only(STAGE_CHECKING, running));

    let rel = match ops.fetch_latest() {
        Ok(r) => r,
        Err(e) => {
            emit(failed(running, e));
            return;
        }
    };

    let newer = compare_versions(&rel.version, running) == VersionOrder::Newer;
    emit(UpdateProgress {
        stage: STAGE_UPTODATE.to_string(),
        pct: None,
        version: newer.then(|| rel.version.clone()).and_then(|v| safe_version(&v)),
        error: None,
    });
}

/// [`UpdateCmd::Apply`]: the ordered pipeline (D-15/D-16).
///
/// Every step's failure publishes exactly ONE terminal and returns. There is
/// no retry, no fallback locator and no "download it anyway": a step that did
/// not succeed is a step whose successor must not run.
///
/// The `busy` flag is NOT touched here — its lifetime is owned by
/// [`run_update_loop`], which clears it at the single call site so that every
/// early return below is covered by construction rather than by six correct
/// `store` calls (T-12-37).
fn run_apply(
    ops: &dyn ApplyOps,
    target: &str,
    running: &str,
    emit: &mut dyn FnMut(UpdateProgress),
) {
    // The ladder again, at the thread's own door. `WinUpdate::apply` already
    // ran it — but 12-17's settings window can also command this thread, and
    // the two dangerous interpolations (a `%TEMP%` filename and the helper's
    // command line) are both downstream of this line. A validator that only
    // one of two callers runs is not a validator.
    if let Some(e) = pre_fetch_refusal(false, target, running) {
        emit(failed(target, e));
        return;
    }

    // 1.
    emit(stage_only(STAGE_CHECKING, target));

    // 2. The feed, fetched NOW — never a URL resolved at check time and reused
    //    (GitHub's asset redirect is a time-limited signed URL).
    let rel = match ops.fetch_latest() {
        Ok(r) => r,
        Err(e) => {
            emit(failed(target, e));
            return;
        }
    };

    // 3. What WE just resolved decides, not the phone's cached view.
    if let Some(e) = post_fetch_refusal(target, &rel.version) {
        emit(failed(target, e));
        return;
    }

    // 4. The asset, by a name this crate owns. Absent or ambiguous is
    //    `installer`; a digest-less asset is `checksum` — a hard refusal, so
    //    nothing is downloaded that could not have been verified (D-15).
    let asset = match feed::resolve_setup(&rel) {
        Ok(a) => a,
        Err(e) => {
            emit(failed(target, e));
            return;
        }
    };
    let Some(digest) = asset.sha256.clone() else {
        // Unreachable: resolve_setup refuses a digest-less asset. Kept as a
        // total match rather than an unwrap — this module never panics.
        emit(failed(target, UpdateError::Checksum));
        return;
    };

    // 5. Download to a SERVER-CHOSEN path (D-14): the directory, the prefix and
    //    the extension are all constants; the target contributes three
    //    integers inside the filename and nothing else.
    let dest = download::temp_path_for(target);
    emit(downloading(target, 0));

    let total = asset.size_bytes;
    let mut last_pct: u8 = 0;
    let mut last_at = Instant::now();
    let streamed = {
        let mut on_progress = |read: u64| {
            if let Some(pct) = should_emit_pct(read, total, last_pct, last_at.elapsed()) {
                last_pct = pct;
                last_at = Instant::now();
                emit(downloading(target, pct));
            }
        };
        ops.download(asset, &dest, &mut on_progress)
    };
    if let Err(e) = streamed {
        // The partial is already gone: download_to deletes it on every error
        // path before returning (D-23).
        emit(failed(target, e));
        return;
    }

    // 6. Verify BEFORE anything is spawned. A mismatch has already deleted the
    //    file by the time this returns (D-15/T-12-38).
    emit(stage_only(STAGE_VERIFYING, target));
    if let Err(e) = ops.verify(&dest, &digest) {
        emit(failed(target, e));
        return;
    }

    // 7. Pessimistic marker, helper script, detached spawn — in that order,
    //    inside begin_apply (D-16).
    emit(stage_only(STAGE_INSTALLING, target));
    if let Err(e) = ops.begin_apply(target, &dest) {
        emit(failed(target, e));
        return;
    }

    // 8. LAST, then go. The phone's existing reconnect FSM takes it from here
    //    (D-17) — there is no second reconnect path and this thread builds
    //    none.
    emit(stage_only(STAGE_RESTARTING, target));
    ops.exit_process();
}

// ── The loop ────────────────────────────────────────────────────────────────

/// Run the update command loop until every `Sender<UpdateCmd>` is dropped.
///
/// MUST be called on a dedicated `std::thread` (RESEARCH Pattern 1): every
/// step below blocks, and `ureq` blocking a tokio worker for a 5 MB download
/// would stall the input path this server exists to keep instant.
///
/// Unlike `clip_thread` and `audio_thread` there is NO poll tick — the update
/// subsystem has nothing to poll. The loop blocks on `recv()` and handles one
/// command at a time, which is also what makes the `busy` guard meaningful:
/// commands are serialised here, so `busy` is refusing a QUEUE, not a race.
pub fn run_update_thread(
    cmd_rx: Receiver<UpdateCmd>,
    progress_tx: Arc<watch::Sender<UpdateProgress>>,
    busy: Arc<AtomicBool>,
) {
    let ops = RealOps::new();
    let mut emit = |p: UpdateProgress| {
        // Send-and-forget: a watch with no receivers is not a failure, it is a
        // phone that is not connected right now.
        let _ = progress_tx.send(p);
    };
    run_update_loop(cmd_rx, &ops, &mut emit, &busy);
}

/// [`run_update_thread`] with the I/O and the publication sink injected.
///
/// The sink is a `FnMut` rather than the `watch::Sender` itself for one
/// reason: a `watch` COALESCES, so a test holding a receiver cannot observe
/// the sequence of stages — only the last one. The published SEQUENCE is
/// exactly what D-10 constrains, so it has to be observable.
fn run_update_loop(
    cmd_rx: Receiver<UpdateCmd>,
    ops: &dyn ApplyOps,
    emit: &mut dyn FnMut(UpdateProgress),
    busy: &AtomicBool,
) {
    while let Ok(cmd) = cmd_rx.recv() {
        match cmd {
            UpdateCmd::Check => run_check(ops, RUNNING_VERSION, emit),
            UpdateCmd::Apply(target) => {
                run_apply(ops, &target, RUNNING_VERSION, emit);
                // THE single clear site (T-12-37). `run_apply` has six early
                // returns and one success path; all seven land here, so "the
                // flag is cleared on every exit path" is a structural fact
                // rather than a checklist. On the success path the process is
                // already gone inside `exit_process`.
                busy.store(false, Ordering::SeqCst);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The load-bearing test of this module: the ORDER is observable.
    ///
    /// With ALL THREE pre-fetch conditions true at once the answer is `Busy`;
    /// peel `busy` off and the malformed shape surfaces; fix the shape and the
    /// downgrade surfaces. An implementation that happened to check downgrade
    /// first would pass every "does it refuse?" test and fail this one.
    #[test]
    fn refusal_order() {
        // busy AND malformed AND (as a consequence) not newer.
        assert_eq!(
            pre_fetch_refusal(true, "https://evil/x.exe", "1.4.0"),
            Some(UpdateError::Busy),
            "busy is the cheapest check and must win over every later one"
        );

        // Not busy: the shape refusal is next.
        assert_eq!(
            pre_fetch_refusal(false, "https://evil/x.exe", "1.4.0"),
            Some(UpdateError::Stale),
            "a malformed target is refused before any ordering comparison"
        );

        // Well-formed but not newer: the downgrade refusal is last of the three.
        assert_eq!(
            pre_fetch_refusal(false, "1.3.0", "1.4.0"),
            Some(UpdateError::Downgrade)
        );

        // All three pass — the only state in which the network may be touched.
        assert_eq!(pre_fetch_refusal(false, "1.5.0", "1.4.0"), None);

        // And busy still wins when the target is perfectly legal.
        assert_eq!(
            pre_fetch_refusal(true, "1.5.0", "1.4.0"),
            Some(UpdateError::Busy)
        );
    }

    /// The hostile shapes, each refused as stale with no I/O (SC6, T-12-01).
    /// A URL-shaped target is the case the phase exists to make impossible.
    #[test]
    fn refusal_rejects_every_hostile_target_shape() {
        for hostile in [
            "https://evil/x.exe",
            "..\\..\\Startup\\x",
            "1.5.0\" & calc &",
            "1.5.0&calc.exe",
            "v1.5.0",
            "1.5",
            "1.5.0-rc1",
            "1.5.0.1",
            "",
            " 1.5.0",
            "1.5.0 ",
            "latest",
        ] {
            assert!(!is_valid_target(hostile), "{hostile:?} must not validate");
            assert_eq!(
                pre_fetch_refusal(false, hostile, "1.4.0"),
                Some(UpdateError::Stale),
                "{hostile:?} must refuse as stale before anything is fetched"
            );
        }

        // The positive control: three integers, and strictly newer.
        assert!(is_valid_target("1.5.0"));
        assert_eq!(pre_fetch_refusal(false, "1.5.0", "1.4.0"), None);
    }

    /// The lexical/float trap, asserted through the refusal rather than
    /// through the comparator: 1.10.0 IS newer than 1.9.0.
    #[test]
    fn refusal_orders_versions_as_integer_tuples() {
        assert_eq!(pre_fetch_refusal(false, "1.10.0", "1.9.0"), None);
        assert_eq!(
            pre_fetch_refusal(false, "1.9.0", "1.10.0"),
            Some(UpdateError::Downgrade)
        );
        // Equal is not newer.
        assert_eq!(
            pre_fetch_refusal(false, "1.5.0", "1.5.0"),
            Some(UpdateError::Downgrade)
        );
        // An unparseable RUNNING version makes the comparison Unknown, and
        // unknown is never newer — so it refuses rather than installing.
        assert_eq!(
            pre_fetch_refusal(false, "1.5.0", "not-a-version"),
            Some(UpdateError::Downgrade)
        );
    }

    /// The running version is the package's own, so the ladder is anchored to
    /// what is actually installed (D-05).
    #[test]
    fn refusal_is_anchored_to_the_package_version() {
        assert!(
            is_valid_target(RUNNING_VERSION),
            "the package version must itself be a legal three-integer target"
        );
        assert_eq!(
            pre_fetch_refusal(false, RUNNING_VERSION, RUNNING_VERSION),
            Some(UpdateError::Downgrade),
            "re-installing the running version is a downgrade refusal"
        );
    }

    /// The server's own fetch is authoritative; the phone's cached view is not.
    #[test]
    fn post_fetch_refusal_trusts_only_the_fresh_fetch() {
        assert_eq!(post_fetch_refusal("1.6.0", "1.6.0"), None);
        assert_eq!(
            post_fetch_refusal("1.6.0", "1.6.1"),
            Some(UpdateError::Stale),
            "a phone whose cached feed is a release behind is stale, not served"
        );
        assert_eq!(
            post_fetch_refusal("1.7.0", "1.6.0"),
            Some(UpdateError::Stale),
            "a target NEWER than what the feed offers is stale too — the \
             comparison is equality, not ordering"
        );
    }

    // ── The pipeline ────────────────────────────────────────────────────────

    use std::cell::{Cell, RefCell};

    /// A release carrying exactly one well-formed setup asset.
    fn release(version: &str) -> Release {
        Release {
            version: version.to_string(),
            assets: vec![Asset {
                name: format!("RemoteControl-Setup-v{version}.exe"),
                url: "https://example.invalid/setup".to_string(),
                size_bytes: 1000,
                sha256: Some("a".repeat(64)),
            }],
        }
    }

    /// The [`ApplyOps`] double: every step is a scripted result, every call is
    /// recorded, and NOTHING touches a socket, a disk or a process.
    struct FakeOps {
        feed: Result<Release, UpdateError>,
        /// Cumulative byte counts handed to the progress callback.
        chunks: Vec<u64>,
        download: Result<(), UpdateError>,
        verify: Result<(), UpdateError>,
        begin: Result<(), UpdateError>,
        /// Set when the feed must NOT be reachable at all — the SC6 assertion.
        feed_is_forbidden: bool,
        calls: RefCell<Vec<&'static str>>,
        exited: Cell<bool>,
    }

    impl FakeOps {
        /// A fully working pipeline that resolves `latest`.
        fn happy(latest: &str) -> Self {
            Self {
                feed: Ok(release(latest)),
                chunks: vec![500, 1000],
                download: Ok(()),
                verify: Ok(()),
                begin: Ok(()),
                feed_is_forbidden: false,
                calls: RefCell::new(Vec::new()),
                exited: Cell::new(false),
            }
        }

        fn called(&self) -> Vec<&'static str> {
            self.calls.borrow().clone()
        }
    }

    impl ApplyOps for FakeOps {
        fn fetch_latest(&self) -> Result<Release, UpdateError> {
            assert!(
                !self.feed_is_forbidden,
                "the feed was fetched for a target that must have been refused \
                 with ZERO network activity (SC6, T-12-01)"
            );
            self.calls.borrow_mut().push("fetch");
            self.feed.clone()
        }

        fn download(
            &self,
            _asset: &Asset,
            _dest: &Path,
            on_progress: &mut dyn FnMut(u64),
        ) -> Result<(), UpdateError> {
            self.calls.borrow_mut().push("download");
            for c in &self.chunks {
                on_progress(*c);
            }
            self.download
        }

        fn verify(&self, _path: &Path, _expected_hex: &str) -> Result<(), UpdateError> {
            self.calls.borrow_mut().push("verify");
            self.verify
        }

        fn begin_apply(&self, _target: &str, _setup: &Path) -> Result<(), UpdateError> {
            self.calls.borrow_mut().push("begin");
            self.begin
        }

        fn exit_process(&self) {
            self.calls.borrow_mut().push("exit");
            self.exited.set(true);
        }
    }

    /// Collect a published sequence. Returns the stage names in order.
    fn stages(published: &[UpdateProgress]) -> Vec<&str> {
        published.iter().map(|p| p.stage.as_str()).collect()
    }

    /// D-10, asserted over a whole sequence: `pct` belongs to `downloading`
    /// alone and `error` to `failed` alone, and every error is a code.
    fn assert_d10_d11(published: &[UpdateProgress]) {
        for p in published {
            if p.stage != STAGE_DOWNLOADING {
                assert_eq!(p.pct, None, "{} must not carry pct (D-10)", p.stage);
            }
            if p.stage == STAGE_FAILED {
                let code = p.error.as_deref().expect("failed always carries an error");
                assert!(
                    UpdateError::ALL.iter().any(|e| e.code() == code),
                    "{code:?} is outside the closed D-11 vocabulary"
                );
            } else {
                assert_eq!(p.error, None, "{} must not carry an error", p.stage);
            }
        }
    }

    /// The pure throttle: no repeats, one publication per 250 ms, and 100 %
    /// always lands.
    #[test]
    fn update_progress_throttle() {
        assert_eq!(pct_of(0, 1000), 0);
        assert_eq!(pct_of(505, 1000), 50);
        assert_eq!(pct_of(1000, 1000), 100);
        assert_eq!(pct_of(9999, 1000), 100, "an over-read clamps, never wraps");
        assert_eq!(pct_of(1, 0), 0, "a zero total must not divide");

        let quick = Duration::from_millis(10);
        let slow = PROGRESS_MIN_INTERVAL;

        // Advanced, but too soon.
        assert_eq!(should_emit_pct(300, 1000, 0, quick), None);
        // Advanced, and the cadence has elapsed.
        assert_eq!(should_emit_pct(300, 1000, 0, slow), Some(30));
        // The same percent is never republished, however long it has been.
        assert_eq!(should_emit_pct(300, 1000, 30, slow), None);
        // Nor is a lower one (defensive: the loop is monotonic).
        assert_eq!(should_emit_pct(100, 1000, 30, slow), None);
        // 100 % always publishes, even 1 ms after the previous one.
        assert_eq!(
            should_emit_pct(1000, 1000, 99, Duration::from_millis(1)),
            Some(100),
            "the last callback of the transfer must never be throttled away"
        );
    }

    /// The whole apply pipeline, in order, with only legal published values.
    #[test]
    fn update_apply_publishes_the_ordered_stages() {
        let ops = FakeOps::happy("9.9.9");
        let mut published = Vec::new();

        run_apply(&ops, "9.9.9", RUNNING_VERSION, &mut |p| published.push(p));

        assert_eq!(
            stages(&published),
            vec![
                STAGE_CHECKING,
                STAGE_DOWNLOADING, // pct 0, published before the transfer starts
                STAGE_DOWNLOADING, // pct 100, the final callback
                STAGE_VERIFYING,
                STAGE_INSTALLING,
                STAGE_RESTARTING,
            ],
            "restarting is published LAST, before the process is asked to exit"
        );
        assert_d10_d11(&published);
        assert_eq!(published[1].pct, Some(0));
        assert_eq!(published[2].pct, Some(100));
        for p in &published {
            assert_eq!(
                p.version.as_deref(),
                Some("9.9.9"),
                "every published value names the target being applied"
            );
        }

        // The steps ran once each, in the D-15 order, and the process was
        // asked to exit only after the hand-off returned.
        assert_eq!(
            ops.called(),
            vec!["fetch", "download", "verify", "begin", "exit"]
        );
        assert!(ops.exited.get());
    }

    /// SC6 / T-12-01: a URL-shaped target is refused with ZERO network
    /// activity, and the rejected string is NOT echoed back on the wire.
    #[test]
    fn update_apply_refuses_a_forged_target_without_touching_the_feed() {
        for forged in [
            "https://evil/x.exe",
            "..\\..\\Startup\\x",
            "1.5.0\" & calc &",
        ] {
            let mut ops = FakeOps::happy("9.9.9");
            ops.feed_is_forbidden = true;
            let mut published = Vec::new();

            run_apply(&ops, forged, RUNNING_VERSION, &mut |p| published.push(p));

            assert_eq!(stages(&published), vec![STAGE_FAILED]);
            assert_eq!(published[0].error.as_deref(), Some(UpdateError::Stale.code()));
            assert_eq!(
                published[0].version, None,
                "a rejected target must never be reflected back onto the wire"
            );
            assert!(
                ops.called().is_empty(),
                "{forged:?} reached an I/O step; nothing may run after a refusal"
            );
            assert!(!ops.exited.get());
        }
    }

    /// The phone's cached view loses to the server's own fetch, and the loss
    /// happens BEFORE anything is downloaded.
    #[test]
    fn update_apply_refuses_a_stale_target_before_downloading() {
        let ops = FakeOps::happy("9.9.9");
        let mut published = Vec::new();

        run_apply(&ops, "9.9.8", RUNNING_VERSION, &mut |p| published.push(p));

        assert_eq!(stages(&published), vec![STAGE_CHECKING, STAGE_FAILED]);
        assert_eq!(published[1].error.as_deref(), Some(UpdateError::Stale.code()));
        assert_eq!(
            ops.called(),
            vec!["fetch"],
            "the mismatch is caught before the asset is resolved or fetched"
        );
        assert_d10_d11(&published);
    }

    /// Every failing step publishes exactly ONE terminal, stops the pipeline
    /// there, and never reaches the hand-off.
    #[test]
    fn update_apply_stops_at_the_first_failing_step() {
        // A feed failure.
        let mut ops = FakeOps::happy("9.9.9");
        ops.feed = Err(UpdateError::Network);
        let mut published = Vec::new();
        run_apply(&ops, "9.9.9", RUNNING_VERSION, &mut |p| published.push(p));
        assert_eq!(stages(&published), vec![STAGE_CHECKING, STAGE_FAILED]);
        assert_eq!(
            published[1].error.as_deref(),
            Some(UpdateError::Network.code())
        );
        assert_eq!(ops.called(), vec!["fetch"]);

        // A transfer failure: the partial is already deleted by download_to.
        let mut ops = FakeOps::happy("9.9.9");
        ops.download = Err(UpdateError::Disk);
        let mut published = Vec::new();
        run_apply(&ops, "9.9.9", RUNNING_VERSION, &mut |p| published.push(p));
        assert_eq!(
            stages(&published),
            vec![
                STAGE_CHECKING,
                STAGE_DOWNLOADING,
                STAGE_DOWNLOADING,
                STAGE_FAILED
            ]
        );
        assert_eq!(published[3].error.as_deref(), Some(UpdateError::Disk.code()));
        assert_d10_d11(&published);
        assert_eq!(ops.called(), vec!["fetch", "download"]);

        // A digest mismatch: NOTHING is spawned (D-15/T-12-38).
        let mut ops = FakeOps::happy("9.9.9");
        ops.verify = Err(UpdateError::Checksum);
        let mut published = Vec::new();
        run_apply(&ops, "9.9.9", RUNNING_VERSION, &mut |p| published.push(p));
        assert_eq!(published.last().unwrap().stage, STAGE_FAILED);
        assert_eq!(
            published.last().unwrap().error.as_deref(),
            Some(UpdateError::Checksum.code())
        );
        assert_eq!(
            ops.called(),
            vec!["fetch", "download", "verify"],
            "begin_apply must be unreachable from a verification failure"
        );
        assert!(!ops.exited.get(), "unverified bytes must never be executed");

        // A hand-off failure: reported, and the process does NOT exit — the
        // still-installed server keeps working (D-24).
        let mut ops = FakeOps::happy("9.9.9");
        ops.begin = Err(UpdateError::Installer);
        let mut published = Vec::new();
        run_apply(&ops, "9.9.9", RUNNING_VERSION, &mut |p| published.push(p));
        assert_eq!(
            published.last().unwrap().error.as_deref(),
            Some(UpdateError::Installer.code())
        );
        assert!(!ops.exited.get());

        // A release with no matching asset is `installer`, not a network fault.
        let mut ops = FakeOps::happy("9.9.9");
        ops.feed = Ok(Release {
            version: "9.9.9".into(),
            assets: vec![],
        });
        let mut published = Vec::new();
        run_apply(&ops, "9.9.9", RUNNING_VERSION, &mut |p| published.push(p));
        assert_eq!(
            published.last().unwrap().error.as_deref(),
            Some(UpdateError::Installer.code())
        );
        assert_eq!(ops.called(), vec!["fetch"]);
    }

    /// T-12-37: the loop clears `busy` on a FAILING pipeline, not only on a
    /// successful one — a flag left set would refuse every later attempt until
    /// the server was quit from the tray.
    #[test]
    fn update_loop_clears_busy_after_a_failing_apply() {
        let mut ops = FakeOps::happy("9.9.9");
        ops.feed = Err(UpdateError::Network);

        let busy = AtomicBool::new(true);
        let (tx, rx) = std::sync::mpsc::channel();
        tx.send(UpdateCmd::Apply("9.9.9".to_string())).unwrap();
        drop(tx); // the loop ends when every sender is gone

        let mut published = Vec::new();
        run_update_loop(rx, &ops, &mut |p| published.push(p), &busy);

        assert!(
            !busy.load(Ordering::SeqCst),
            "busy must be clear after a failed apply (T-12-37)"
        );
        assert_eq!(stages(&published), vec![STAGE_CHECKING, STAGE_FAILED]);
        assert_d10_d11(&published);
    }

    /// The same, on the refusal path that never reaches an I/O step at all.
    #[test]
    fn update_loop_clears_busy_after_a_refused_apply() {
        let mut ops = FakeOps::happy("9.9.9");
        ops.feed_is_forbidden = true;

        let busy = AtomicBool::new(true);
        let (tx, rx) = std::sync::mpsc::channel();
        tx.send(UpdateCmd::Apply("https://evil/x.exe".to_string()))
            .unwrap();
        drop(tx);

        let mut published = Vec::new();
        run_update_loop(rx, &ops, &mut |p| published.push(p), &busy);

        assert!(!busy.load(Ordering::SeqCst));
        assert_eq!(stages(&published), vec![STAGE_FAILED]);
        assert!(ops.called().is_empty());
    }

    /// The Check arm: `uptodate` in both outcomes, with the resolved version
    /// carried ONLY when it is strictly newer than the running one.
    #[test]
    fn update_check_carries_the_resolved_version_only_when_it_is_newer() {
        // Something newer exists.
        let ops = FakeOps::happy("9.9.9");
        let mut published = Vec::new();
        run_check(&ops, RUNNING_VERSION, &mut |p| published.push(p));
        assert_eq!(stages(&published), vec![STAGE_CHECKING, STAGE_UPTODATE]);
        assert_eq!(published[1].version.as_deref(), Some("9.9.9"));
        assert_d10_d11(&published);

        // Nothing newer: the terminal carries no version at all.
        let mut ops = FakeOps::happy("9.9.9");
        ops.feed = Ok(release(RUNNING_VERSION));
        let mut published = Vec::new();
        run_check(&ops, RUNNING_VERSION, &mut |p| published.push(p));
        assert_eq!(stages(&published), vec![STAGE_CHECKING, STAGE_UPTODATE]);
        assert_eq!(published[1].version, None);

        // An older "latest" (a rolled-back release) is not newer either.
        let mut ops = FakeOps::happy("9.9.9");
        ops.feed = Ok(release("0.0.1"));
        let mut published = Vec::new();
        run_check(&ops, RUNNING_VERSION, &mut |p| published.push(p));
        assert_eq!(published[1].version, None);

        // An unreachable feed is one terminal with a closed-vocabulary code.
        let mut ops = FakeOps::happy("9.9.9");
        ops.feed = Err(UpdateError::Network);
        let mut published = Vec::new();
        run_check(&ops, RUNNING_VERSION, &mut |p| published.push(p));
        assert_eq!(stages(&published), vec![STAGE_CHECKING, STAGE_FAILED]);
        assert_eq!(
            published[1].error.as_deref(),
            Some(UpdateError::Network.code())
        );
        assert_d10_d11(&published);
    }

    /// The stage constants ARE the SPEC §7 vocabulary, spelled once.
    #[test]
    fn update_stage_constants_are_the_closed_vocabulary() {
        assert_eq!(
            vec![
                STAGE_CHECKING,
                STAGE_DOWNLOADING,
                STAGE_VERIFYING,
                STAGE_INSTALLING,
                STAGE_RESTARTING,
                STAGE_UPTODATE,
                STAGE_FAILED,
            ],
            vec![
                "checking",
                "downloading",
                "verifying",
                "installing",
                "restarting",
                "uptodate",
                "failed",
            ],
            "amend SPEC §7, the schema and the fixtures before touching this list"
        );
    }
}
