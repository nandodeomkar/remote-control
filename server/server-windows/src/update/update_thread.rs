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

use server_core::version::{compare_versions, VersionOrder};

use super::UpdateError;

/// The running version, from the package itself (D-05) — NEVER a hardcoded
/// constant. A hand-maintained version string is exactly the bug that pinned
/// the phone's `pubspec.yaml` at `1.0.0+1` across four shipped releases, and
/// on this side it would additionally break the downgrade refusal: a stale
/// literal makes every version "newer".
const RUNNING_VERSION: &str = env!("CARGO_PKG_VERSION");

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
}
