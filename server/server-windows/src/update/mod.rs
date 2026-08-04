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
// apply+marker, 12-11 the thread + `WinUpdate`). `update_thread` now consumes
// most of what the others expose, but NOTHING consumes `WinUpdate` itself
// until 12-12 puts it in `Executors` — and this is a BINARY crate, where `pub`
// buys no dead-code exemption. REMOVE this allow in 12-12, once the bundle
// wiring gives every public item in this subtree a real caller; after that,
// dead code here really is dead.
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
}
