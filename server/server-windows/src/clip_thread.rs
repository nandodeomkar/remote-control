//! Dedicated clipboard thread — the ONLY place the `arboard` clipboard lives
//! (RESEARCH Pitfall 6, a clone of [`crate::audio_thread`]'s shape).
//!
//! One `std::thread` owns the single `arboard::Clipboard` instance; commands
//! arrive on an `mpsc` channel and the 250 ms `recv_timeout` poll tick reads
//! the PC clipboard, filters it, and pushes a [`ClipState`] onto the 06-04
//! `watch` seam whenever the text changes (CLIP-03, poll-over-notify — the
//! same house pattern as the audio thread; arboard has no change events).
//!
//! Unlike the audio thread there is **no** `CoInitializeEx`: arboard needs no
//! COM apartment. What this thread DOES own that the audio thread does not is
//! the three server-side privacy gates (RESEARCH Flag 3 / Pitfall 5):
//!   - **sensitive skip** — a clip carrying the Windows
//!     `ExcludeClipboardContentFromMonitorProcessing` format (KeePassXC,
//!     Credential Manager, Chrome incognito) is never pushed;
//!   - **large skip** — text over 16 KiB is never pushed (frame-cap headroom,
//!     D-04);
//!   - **echo suppression** — the value the server just wrote from a
//!     `clip.set` is read back on the next tick and must NOT bounce out as a
//!     `clip.changed` (fingerprint match, D-05).
//!
//! EVERY arboard/HRESULT failure skips the tick and is dropped with `let _ =`
//! / `?`-to-`None` — never a panic (the send-and-forget rule).

use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::time::Duration;

use server_core::transport::ClipState;
use sha2::{Digest, Sha256};
use tokio::sync::watch::Sender;
use windows::Win32::System::DataExchange::{
    IsClipboardFormatAvailable, RegisterClipboardFormatW,
};
use windows::core::w;

/// Auto-sync large-text cap (RESEARCH Flag 3 / D-04): text over 16 KiB
/// (16384 UTF-8 bytes) is never pushed so every `clip.*` frame rides well
/// under the 64 KB WS frame cap (SPEC §13) after JSON escaping.
const MAX_CLIP_BYTES: usize = 16384;

/// Poll cadence (RESEARCH A5): 250 ms mirrors the audio thread — responsive
/// without burning CPU.
const POLL_INTERVAL: Duration = Duration::from_millis(250);

/// Command sent from [`crate::executors::clipboard::WinClipboard`] (non-blocking
/// mpsc send) to the clipboard thread.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClipCmd {
    /// Write `text` to the PC clipboard (from a phone `clip.set`).
    Set(String),
}

/// Pure gate (RESEARCH Flag 3 / D-04): a clip is skipped when it exceeds the
/// 16 KiB cap OR carries a sensitive-content exclusion format. Factored out of
/// the OS poll so it is unit-testable without any clipboard call (mirrors the
/// `pct_from_scalar` precedent in `audio_thread`).
pub fn should_skip_clip(byte_len: usize, sensitive: bool) -> bool {
    byte_len > MAX_CLIP_BYTES || sensitive
}

/// Pure content fingerprint (D-05): a SHA-256 over the UTF-8 bytes. Used to
/// suppress the echo of a value the server just wrote (Pitfall 5). Deterministic
/// and fixed-size so the just-set fingerprint can be compared cheaply on every
/// poll tick.
pub fn clip_fingerprint(text: &str) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(text.as_bytes());
    let out = hasher.finalize();
    let mut fp = [0u8; 32];
    fp.copy_from_slice(&out);
    fp
}

/// Pure echo predicate (D-05): `true` only when the current clipboard
/// fingerprint matches the fingerprint of the value the server last SET —
/// i.e. the poll is reading back our own write, which must never be pushed as
/// a change. `None` (no prior set) is never an echo.
pub fn is_echo(current: &[u8; 32], last_set: Option<&[u8; 32]>) -> bool {
    last_set == Some(current)
}

/// Read the current clipboard text and push a [`ClipState`] onto the watch
/// seam iff it survives all three gates AND differs from the last pushed value
/// (value-equality anti-flood, the audio_thread `push_if_changed` clone). A
/// failed/empty/non-text read simply skips this tick.
fn push_if_changed(
    clipboard: Option<&mut arboard::Clipboard>,
    exclude_id: u32,
    tx: &Sender<ClipState>,
    last_set: &Option<[u8; 32]>,
    last_pushed: &mut Option<ClipState>,
) {
    let Some(cb) = clipboard else {
        return;
    };
    // Empty or non-text clipboard (image, files, …) → arboard returns Err →
    // nothing to mirror this tick.
    let Ok(text) = cb.get_text() else {
        return;
    };

    // Sensitive-content check: mere PRESENCE of the exclusion format means
    // "never sync" (RESEARCH Flag 3). IsClipboardFormatAvailable needs no
    // OpenClipboard and is contention-free. A 0 exclude_id (registration
    // failed) yields Err → not sensitive (fail-open, documented A3).
    // SAFETY: format-availability probe with a registered format id; no
    // clipboard ownership taken, result dropped to a bool.
    let sensitive = unsafe { IsClipboardFormatAvailable(exclude_id).is_ok() };
    if should_skip_clip(text.len(), sensitive) {
        return;
    }

    // Echo suppression (Pitfall 5, D-05): the value we just wrote from a
    // clip.set is read back here on the next tick — never bounce it out.
    let fp = clip_fingerprint(&text);
    if is_echo(&fp, last_set.as_ref()) {
        return;
    }

    // Value-equality anti-flood: a genuine external change pushes exactly once.
    let state = ClipState { text };
    if last_pushed.as_ref() != Some(&state) {
        let _ = tx.send(state.clone());
        *last_pushed = Some(state);
    }
}

/// Run the clipboard command + poll loop until every `Sender<ClipCmd>` is
/// dropped. MUST be called on a dedicated `std::thread` (arboard single-thread
/// affinity, Pitfall 6). NO `CoInitializeEx` — arboard needs no COM apartment.
pub fn run_clip_thread(rx: Receiver<ClipCmd>, tx: Sender<ClipState>) {
    // Register the sensitive-content exclusion format once (RESEARCH Flag 3).
    // A 0 id (registration failure) simply makes the sensitive check always
    // report false — fail-open, the documented residual risk (A3).
    // SAFETY: register a well-known clipboard format name; returns a u32 id.
    let exclude_id =
        unsafe { RegisterClipboardFormatW(w!("ExcludeClipboardContentFromMonitorProcessing")) };

    // The single arboard instance owned by THIS thread (Pitfall 6). A failed
    // construction disables the mirror for this run rather than panicking; the
    // loop still drains commands so senders never block.
    let mut clipboard = arboard::Clipboard::new().ok();

    // Fingerprint of the value the server last WROTE (echo suppression); the
    // last value pushed to the watch (value-equality anti-flood).
    let mut last_set: Option<[u8; 32]> = None;
    let mut last_pushed: Option<ClipState> = None;

    loop {
        match rx.recv_timeout(POLL_INTERVAL) {
            // A phone clip.set: write arboard and remember the fingerprint so
            // the read-back next tick is not bounced out. DELIBERATELY no push
            // — the value we set must never emit a clip.changed (the whole
            // echo-loop defense, D-05).
            Ok(ClipCmd::Set(text)) => {
                last_set = Some(clip_fingerprint(&text));
                if let Some(cb) = clipboard.as_mut() {
                    let _ = cb.set_text(text);
                }
            }
            // Poll tick: read the clipboard, gate it, push iff it changed
            // externally.
            Err(RecvTimeoutError::Timeout) => {
                push_if_changed(
                    clipboard.as_mut(),
                    exclude_id,
                    &tx,
                    &last_set,
                    &mut last_pushed,
                );
            }
            // Every producer dropped — the server is shutting down.
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// D-04 gate: exactly at 16 KiB is allowed; one byte over is skipped; a
    /// sensitive clip is skipped regardless of size.
    #[test]
    fn clip_gate() {
        assert!(!should_skip_clip(0, false), "empty non-sensitive clip is allowed");
        assert!(
            !should_skip_clip(MAX_CLIP_BYTES, false),
            "exactly 16 KiB is allowed (boundary, not > cap)"
        );
        assert!(
            should_skip_clip(MAX_CLIP_BYTES + 1, false),
            "one byte over the cap is skipped"
        );
        assert!(should_skip_clip(1, true), "any sensitive clip is skipped");
        assert!(
            should_skip_clip(MAX_CLIP_BYTES + 1, true),
            "sensitive AND oversized is skipped"
        );
    }

    /// D-05 fingerprint + echo: deterministic, collision-distinct for
    /// different text, and `is_echo` matches only the recorded set fingerprint.
    #[test]
    fn clip_echo() {
        let a = clip_fingerprint("abc");
        let a_again = clip_fingerprint("abc");
        let b = clip_fingerprint("xyz");

        assert_eq!(a, a_again, "fingerprint is deterministic across calls");
        assert_ne!(a, b, "different text yields a different fingerprint");

        assert!(is_echo(&a, Some(&a_again)), "matching fingerprint is an echo");
        assert!(!is_echo(&a, Some(&b)), "non-matching fingerprint is not an echo");
        assert!(!is_echo(&a, None), "no prior set is never an echo");
    }
}
