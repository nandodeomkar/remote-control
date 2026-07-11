//! Real `Apps` executor (APPS-01/APPS-02): a sync trait impl holding ONLY the
//! `Send + Sync` command sender and the snapshot `watch::Receiver` — identical
//! shape to [`crate::executors::media::WinMedia`].
//!
//! All Win32/COM work (`EnumWindows`, the foreground-lock focus dance,
//! `ShellExecuteW`) lives on the dedicated apps thread ([`crate::apps_thread`]),
//! never on a tokio worker (Pitfall / Phase-5 rule). This executor only:
//!   - reads the latest enumerated list from a `watch::borrow()` (`list`), and
//!   - sends an [`AppsCmd`] over an `mpsc` channel (`focus`/`close`/`launch`).
//!
//! ## Snapshot-validation for the synchronous `bool` (Pattern 4 validate-on-use)
//!
//! `Apps::focus/close` must return `bool` synchronously, but the true OS
//! outcome (`IsWindow` on the apps thread) is only known asynchronously. For v1
//! we validate the id against the CURRENT snapshot before sending: if the
//! window is no longer in the enumerated list we return `false` immediately (→
//! router `err{windowGone}`), otherwise we send the command and return `true`.
//! The apps thread's own `IsWindow` guard is the second-line defense against a
//! same-tick recycle race (T-06-13, accepted). `launch` returns whether the
//! mpsc send was accepted — the path always originates from a server-enumerated
//! window (D-01), never user-typed (T-06-02).

use std::sync::mpsc::Sender;

use server_core::executors::{Apps, WindowInfo};
use tokio::sync::watch::Receiver;

use crate::apps_thread::AppsCmd;

/// Windows `Apps` executor: `cmd_tx` carries Focus/Close/Launch to the apps
/// thread; `snapshot_rx` is the live enumerated window list (the same watch the
/// session's `apps.changed` branch reads).
pub struct WinApps {
    cmd_tx: Sender<AppsCmd>,
    snapshot_rx: Receiver<Vec<WindowInfo>>,
}

impl WinApps {
    /// Wrap the apps-thread command sender + the snapshot receiver from the
    /// composition root.
    pub fn new(cmd_tx: Sender<AppsCmd>, snapshot_rx: Receiver<Vec<WindowInfo>>) -> Self {
        Self { cmd_tx, snapshot_rx }
    }

    /// `true` iff `id` is present in the current enumerated snapshot
    /// (validate-on-use: a stale id from the phone maps to `err{windowGone}`
    /// without ever touching the OS).
    fn id_present(&self, id: u64) -> bool {
        self.snapshot_rx.borrow().iter().any(|w| w.id == id)
    }
}

impl Apps for WinApps {
    /// Non-blocking read of the latest enumerated window list (the only
    /// synchronous touch — a `watch::borrow().clone()`, never an OS call).
    fn list(&self) -> Vec<WindowInfo> {
        self.snapshot_rx.borrow().clone()
    }

    /// Launch a resolved exe path on the apps thread. Returns whether the mpsc
    /// send was accepted (the apps thread reports the real `ShellExecuteW`
    /// outcome via the refreshed snapshot; a closed channel — shutting down —
    /// is the only `false`).
    fn launch(&self, path: &str) -> bool {
        self.cmd_tx.send(AppsCmd::Launch(path.to_owned())).is_ok()
    }

    /// Focus a window: reject a stale id up front (`err{windowGone}`), else
    /// dispatch the focus dance to the apps thread.
    fn focus(&self, id: u64) -> bool {
        if !self.id_present(id) {
            return false;
        }
        self.cmd_tx.send(AppsCmd::Focus(id)).is_ok()
    }

    /// Close a window: reject a stale id up front (`err{windowGone}`), else post
    /// `WM_CLOSE` via the apps thread.
    fn close(&self, id: u64) -> bool {
        if !self.id_present(id) {
            return false;
        }
        self.cmd_tx.send(AppsCmd::Close(id)).is_ok()
    }
}
