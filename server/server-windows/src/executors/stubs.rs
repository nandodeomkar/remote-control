//! Runtime no-op executors for the two remaining non-mouse traits so
//! `Executors` can be constructed in the binary.
//!
//! NOT the core `MockExecutors` (that is a test recorder) — these are the seed
//! implementations that Phase 6 grows into real Windows backends: Apps and
//! Clipboard via the `windows` crate. (Media/Power became real in Phase 5 —
//! see [`super::media::WinMedia`] / [`super::power::WinPower`].)

use server_core::executors::{Apps, Clipboard, WindowInfo};

/// No-op `Apps` executor. Phase 6 fills this with `EnumWindows` /
/// `ShellExecuteW`.
pub struct StubApps;

impl Apps for StubApps {
    fn list(&self) -> Vec<WindowInfo> {
        vec![]
    }
    // Report success (`true`) so the binary keeps compiling and the router
    // stays silent; the real WinApps (06-02) returns the true OS outcome.
    fn launch(&self, _path: &str) -> bool {
        true
    }
    fn focus(&self, _id: u64) -> bool {
        true
    }
    fn close(&self, _id: u64) -> bool {
        true
    }
}

/// No-op `Clipboard` executor. Phase 6 fills this with arboard.
pub struct StubClipboard;

impl Clipboard for StubClipboard {
    fn get(&self) -> String {
        String::new()
    }
    fn set(&self, _text: &str) {}
}
