//! Asset download and verification.
//!
//! **Nothing this module writes to disk is ever executed before it has been
//! verified, and nothing that fails verification is left on disk at all.**
//! That sentence is the whole design. The file this module produces is handed
//! to an installer that runs with the owner's privileges, so the window
//! between "bytes arrived" and "bytes were proven" is the only place an
//! integrity failure can still be caught for free.
//!
//! The order is fixed and each step exists for a reason:
//!
//! 1. stream to a **server-chosen** path under `%TEMP%` — never a path the
//!    wire had a hand in ([`temp_path_for`], D-14/T-12-13);
//! 2. [`File::create`] truncates, so a stale partial from an interrupted
//!    earlier attempt cannot be mistaken for a complete file;
//! 3. `sync_all()` before hashing — a tail still sitting in the OS buffer
//!    would hash differently from the file the installer later opens;
//! 4. [`verify_or_delete`] compares the sha256, and on ANY mismatch removes
//!    the file (D-15/D-23);
//! 5. only then may a caller spawn anything.
//!
//! Every error path deletes the partial before returning, including a
//! transport failure mid-stream. An unverified byte never survives a return
//! from this module.

use std::fs::File;
use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

use sha2::{Digest, Sha256};

use super::feed::map_ureq;
use super::UpdateError;

/// Filename template for the downloaded Windows installer. Lives HERE,
/// server-side, next to the code that builds the path — not on the wire.
const SETUP_FILE_PREFIX: &str = "RemoteControl-Setup-v";
const SETUP_FILE_SUFFIX: &str = ".exe";

/// The agent used for asset downloads.
///
/// Same Pitfall 1 as [`super::feed::feed_agent`] — ureq sets no timeouts at
/// all by default — but a different global budget: a ~5 MB setup exe over a
/// weak link legitimately takes far longer than a small JSON GET, so 10 s
/// would abort perfectly healthy downloads. `timeout_connect` stays short:
/// DNS/TCP failures should fail fast either way.
pub fn download_agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(120)))
        .timeout_connect(Some(Duration::from_secs(5)))
        .user_agent("RemoteControl-Updater")
        .build()
        .into()
}

/// `true` iff `target` is exactly three dot-separated runs of ASCII digits —
/// the `^\d+\.\d+\.\d+$` shape SPEC's `semver` `$def` pins.
///
/// Pure and public so the caller can validate BEFORE deciding to act, rather
/// than discovering the problem inside a path builder.
pub fn is_valid_target(target: &str) -> bool {
    let mut parts = target.split('.');
    let ok = (0..3).all(|_| {
        parts
            .next()
            .is_some_and(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()))
    });
    ok && parts.next().is_none()
}

/// `%TEMP%\RemoteControl-Setup-v{target}.exe`.
///
/// # The target must already be validated
///
/// `target` reaching this function has ALREADY been checked against
/// `^\d+\.\d+\.\d+$` by the caller ([`is_valid_target`]); the debug assertion
/// below is a development tripwire, not the defence.
///
/// The defence matters because `target` is the one value that crosses from
/// the wire into this subsystem, and it is interpolated into two dangerous
/// contexts:
/// - **into a path**, where `..\..\Start Menu\Programs\Startup\x` walks out
///   of `%TEMP%` and drops a file somewhere Windows will execute on login;
/// - **into the helper script** (12-09), where a `cmd`-metacharacter payload
///   is straightforward command injection.
///
/// Note what is NOT taken from the wire: the directory, the prefix and the
/// extension are all constants here. The phone can influence three integers
/// inside a filename and nothing else (D-14).
pub fn temp_path_for(target: &str) -> PathBuf {
    debug_assert!(
        is_valid_target(target),
        "temp_path_for called with an unvalidated target: {target:?} — \
         the caller must enforce ^\\d+\\.\\d+\\.\\d+$ first (T-12-13)"
    );
    std::env::temp_dir().join(format!("{SETUP_FILE_PREFIX}{target}{SETUP_FILE_SUFFIX}"))
}

/// Stream the asset at `url` into `dest`.
///
/// Streams deliberately, via `as_reader()`. ureq's whole-body read helpers
/// would buffer the entire asset in memory AND silently cap it at their
/// 10 MiB default limit — which would start failing the day the setup exe
/// grows past that (T-12-16). No helper of that kind appears in this file.
///
/// On ANY error after the file is opened, the partial is deleted before
/// returning (D-23) — a half-downloaded installer must never outlive the
/// attempt that created it.
pub fn download_to(agent: &ureq::Agent, url: &str, dest: &Path) -> Result<(), UpdateError> {
    // browser_download_url 302s to a different host with a time-limited
    // signed query; ureq follows cross-host redirects and strips auth headers
    // on redirect by default. We send none anyway (D-01).
    let mut res = agent.get(url).call().map_err(map_ureq)?;

    let streamed = (|| -> Result<(), UpdateError> {
        // create() truncates any stale partial from an earlier attempt.
        let mut file = File::create(dest)?;
        io::copy(&mut res.body_mut().as_reader(), &mut file).map_err(classify_io)?;
        // Flush to the device BEFORE anyone hashes this file: a tail left in
        // the OS buffer would hash differently from what the installer opens.
        file.sync_all()?;
        Ok(())
    })();

    if let Err(e) = streamed {
        // Never leave an unverified partial behind (D-23).
        let _ = std::fs::remove_file(dest);
        tracing::warn!("update: download failed ({}); partial removed", e.code());
        return Err(e);
    }
    Ok(())
}

/// Decide whether a mid-stream `io::Error` was the network or the disk.
///
/// ureq wraps its transport failures in an `io::Error` when they surface
/// through a reader, so the inner error is the discriminator. Anything that
/// is not a wrapped ureq failure is a genuine local write problem — no space,
/// a locked file — and is `disk`.
fn classify_io(e: io::Error) -> UpdateError {
    if e.get_ref()
        .is_some_and(|inner| inner.downcast_ref::<ureq::Error>().is_some())
    {
        tracing::warn!("update: asset stream failed in transport: {e}");
        return UpdateError::Network;
    }
    tracing::warn!("update: asset stream failed writing to disk: {}", e.kind());
    UpdateError::Disk
}

/// Chunk size for the hashing read loop — big enough that a 5 MB asset is
/// ~80 reads, small enough to stay off the stack-vs-heap radar entirely.
const HASH_CHUNK: usize = 64 * 1024;

/// Lowercase hex sha256 of a file's contents, streamed.
///
/// Reads in fixed chunks rather than `io::copy`ing into the hasher: `sha2`
/// 0.11 exposes no `std` feature (its features are `alloc`, `oid`, `zeroize`
/// only), so `Sha256` does **not** implement `io::Write` and cannot be an
/// `io::copy` sink. The loop keeps the streaming property that matters — the
/// file is never held in memory — using the same `Digest` API
/// `clip_thread::clip_fingerprint` already uses. No second digest crate
/// enters the tree.
pub fn file_sha256_hex(path: &Path) -> io::Result<String> {
    use io::Read;

    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; HASH_CHUNK];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hex::encode(hasher.finalize()))
}

/// Compare the file's sha256 against `expected_hex` and delete it on any
/// mismatch.
///
/// `expected_hex` is the digest AS ALREADY STRIPPED by
/// [`super::feed::strip_digest`] — 64 hex characters, no `sha256:` prefix.
/// The comparison is case-insensitive so the API's casing can never decide
/// the outcome. A malformed expectation is itself a [`UpdateError::Checksum`]
/// refusal, not a pass.
///
/// # Ordering
///
/// This runs AFTER `sync_all` and BEFORE anything is spawned. That is the
/// entire point: the digest is the only integrity check standing between a
/// tampered asset and an installer running with the owner's privileges
/// (D-15), so on failure the bytes are removed rather than merely reported —
/// a returned error that left the file in place would still leave something
/// on disk for a later run, or a user, to execute.
pub fn verify_or_delete(path: &Path, expected_hex: &str) -> Result<(), UpdateError> {
    let delete = || {
        let _ = std::fs::remove_file(path);
    };

    if expected_hex.len() != 64 || !expected_hex.bytes().all(|b| b.is_ascii_hexdigit()) {
        tracing::error!("update: expected digest is not 64 hex chars — refusing");
        delete();
        return Err(UpdateError::Checksum);
    }

    let got = match file_sha256_hex(path) {
        Ok(g) => g,
        Err(e) => {
            tracing::warn!("update: could not hash downloaded asset: {}", e.kind());
            delete();
            return Err(UpdateError::Disk);
        }
    };

    if got.eq_ignore_ascii_case(expected_hex) {
        return Ok(());
    }

    // Log the digests, not the path — they are not secrets and they are the
    // only thing that makes a mismatch diagnosable.
    tracing::error!("update: sha256 mismatch (got {got}, expected {expected_hex}) — deleting");
    delete();
    Err(UpdateError::Checksum)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    /// sha256("hello world"), precomputed independently of this code.
    const HELLO_WORLD_SHA256: &str =
        "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9";

    /// A unique temp file per test — the suite runs threaded, so a shared
    /// filename would let one test delete another's fixture.
    fn scratch(tag: &str, contents: &[u8]) -> PathBuf {
        let p = std::env::temp_dir().join(format!(
            "rc-update-test-{}-{tag}-{:?}.bin",
            std::process::id(),
            std::thread::current().id()
        ));
        let mut f = File::create(&p).expect("create scratch file");
        f.write_all(contents).expect("write scratch file");
        f.sync_all().expect("flush scratch file");
        p
    }

    #[test]
    fn file_sha256_hex_matches_a_precomputed_digest() {
        let p = scratch("hash", b"hello world");
        assert_eq!(file_sha256_hex(&p).unwrap(), HELLO_WORLD_SHA256);
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn file_sha256_hex_handles_an_empty_file() {
        let p = scratch("empty", b"");
        assert_eq!(
            file_sha256_hex(&p).unwrap(),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn verify_or_delete_accepts_the_right_digest_and_keeps_the_file() {
        let p = scratch("ok", b"hello world");
        assert!(verify_or_delete(&p, HELLO_WORLD_SHA256).is_ok());
        assert!(p.exists(), "a verified file must survive verification");
        let _ = std::fs::remove_file(&p);
    }

    /// Casing of the API's digest must never decide the outcome.
    #[test]
    fn verify_or_delete_is_case_insensitive() {
        let p = scratch("case", b"hello world");
        assert!(verify_or_delete(&p, &HELLO_WORLD_SHA256.to_ascii_uppercase()).is_ok());
        assert!(p.exists());
        let _ = std::fs::remove_file(&p);
    }

    /// The load-bearing assertion of this module: a mismatch does not merely
    /// return an error, it removes the bytes.
    #[test]
    fn verify_or_delete_deletes_the_file_on_mismatch() {
        let p = scratch("bad", b"tampered payload");
        assert!(p.exists());

        let got = verify_or_delete(&p, HELLO_WORLD_SHA256);

        assert_eq!(got.unwrap_err(), UpdateError::Checksum);
        assert!(
            !p.exists(),
            "unverified bytes must NOT survive on disk (D-15/D-23)"
        );
    }

    /// A malformed expectation is a refusal, never an accidental pass — and
    /// it also takes the file with it.
    #[test]
    fn verify_or_delete_refuses_a_malformed_expectation() {
        for bad in ["", "not-hex", &"a".repeat(63), &"a".repeat(65)] {
            let p = scratch("malformed", b"hello world");
            assert_eq!(verify_or_delete(&p, bad).unwrap_err(), UpdateError::Checksum);
            assert!(!p.exists(), "expectation {bad:?} left a file behind");
        }
    }

    /// A `sha256:`-prefixed value is NOT accepted here: stripping is
    /// `feed::strip_digest`'s job, and accepting both shapes would let an
    /// unstripped value silently reach the comparison.
    #[test]
    fn verify_or_delete_refuses_an_unstripped_digest() {
        let p = scratch("prefixed", b"hello world");
        let prefixed = format!("sha256:{HELLO_WORLD_SHA256}");
        assert_eq!(
            verify_or_delete(&p, &prefixed).unwrap_err(),
            UpdateError::Checksum
        );
        assert!(!p.exists());
    }

    #[test]
    fn verify_or_delete_on_a_missing_file_is_disk() {
        let p = std::env::temp_dir().join("rc-update-test-definitely-absent.bin");
        let _ = std::fs::remove_file(&p);
        assert_eq!(
            verify_or_delete(&p, HELLO_WORLD_SHA256).unwrap_err(),
            UpdateError::Disk
        );
    }

    #[test]
    fn temp_path_for_builds_the_expected_filename() {
        let p = temp_path_for("1.5.0");
        assert_eq!(
            p.file_name().unwrap().to_str().unwrap(),
            "RemoteControl-Setup-v1.5.0.exe"
        );
        assert_eq!(p.parent().unwrap(), std::env::temp_dir());
    }

    /// The validator the caller must run before `temp_path_for` — the
    /// rejected cases are the traversal and injection payloads, not just
    /// tidiness.
    #[test]
    fn is_valid_target_accepts_only_three_numeric_components() {
        for good in ["1.5.0", "0.0.0", "10.20.30", "1.0.10"] {
            assert!(is_valid_target(good), "{good} should be valid");
        }
        for bad in [
            "",
            "1.5",
            "1.5.0.1",
            "v1.5.0",
            "1.5.0-rc1",
            "1..0",
            "1.5.",
            ".5.0",
            "1.5.0 ",
            "..\\..\\Startup\\x",
            "1.5.0&calc.exe",
            "1.5.0\"&calc&\"",
            "1.5.0\n2.0.0",
            "１.５.０",
        ] {
            assert!(!is_valid_target(bad), "{bad:?} should be rejected");
        }
    }

    /// A rejected target never reaches a path — the debug assertion fires
    /// first in debug builds, which is where the tests run.
    #[test]
    #[should_panic(expected = "unvalidated target")]
    #[cfg(debug_assertions)]
    fn temp_path_for_trips_on_a_traversal_target() {
        let _ = temp_path_for("..\\..\\Startup\\x");
    }
}
