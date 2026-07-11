//! Real `Clipboard` executor (CLIP-01/CLIP-02): a sync trait impl holding ONLY
//! the `Send + Sync` command sender and the snapshot `watch::Receiver` —
//! identical shape to [`crate::executors::apps::WinApps`] /
//! [`crate::executors::media::WinMedia`].
//!
//! All arboard work (the single-thread clipboard instance, the sensitive/large
//! gate, echo suppression) lives on the dedicated clip thread
//! ([`crate::clip_thread`]), never on a tokio worker (Pitfall 6). This executor
//! only:
//!   - reads the latest mirrored clipboard text from a `watch::borrow()`
//!     (`get`), and
//!   - sends a [`ClipCmd::Set`] over an `mpsc` channel (`set`).
//!
//! ## `get` returns the last MIRRORED value
//!
//! The clip thread deliberately does NOT push the value it wrote from a
//! `clip.set` (echo suppression, D-05), and skips sensitive/oversized clips, so
//! the snapshot only ever holds the last policy-clean EXTERNAL change. `get`
//! therefore returns that last mirrored value — never a secret, never a
//! half-written echo — which is exactly what `clip.get` should hand the phone.

use std::sync::mpsc::Sender;

use server_core::executors::Clipboard;
use server_core::transport::ClipState;
use tokio::sync::watch::Receiver;

use crate::clip_thread::ClipCmd;

/// Windows `Clipboard` executor: `cmd_tx` carries `Set` to the clip thread;
/// `snapshot_rx` is the live mirrored clipboard text (the same watch the
/// session's `clip.changed` branch reads).
pub struct WinClipboard {
    cmd_tx: Sender<ClipCmd>,
    snapshot_rx: Receiver<ClipState>,
}

impl WinClipboard {
    /// Wrap the clip-thread command sender + the snapshot receiver from the
    /// composition root.
    pub fn new(cmd_tx: Sender<ClipCmd>, snapshot_rx: Receiver<ClipState>) -> Self {
        Self { cmd_tx, snapshot_rx }
    }
}

impl Clipboard for WinClipboard {
    /// Non-blocking read of the latest mirrored clipboard text (the only
    /// synchronous touch — a `watch::borrow().clone()`, never an arboard call).
    fn get(&self) -> String {
        self.snapshot_rx.borrow().text.clone()
    }

    /// Write `text` to the PC clipboard on the clip thread (send-and-forget: a
    /// closed channel — shutting down — drops the frame, never blocks the read
    /// task, never runs arboard on a tokio worker).
    fn set(&self, text: &str) {
        let _ = self.cmd_tx.send(ClipCmd::Set(text.to_owned()));
    }
}
