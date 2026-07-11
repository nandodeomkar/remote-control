//! Runtime no-op executor for the last non-real trait so `Executors` can be
//! constructed in the binary.
//!
//! NOT the core `MockExecutors` (that is a test recorder) — this is the seed
//! implementation that Phase 6 grows into a real Windows backend: Clipboard via
//! arboard (06-04). (Media/Power became real in Phase 5; Apps became real in
//! 06-02 — see [`super::media::WinMedia`] / [`super::power::WinPower`] /
//! [`super::apps::WinApps`].)

use server_core::executors::Clipboard;

/// No-op `Clipboard` executor. 06-04 fills this with arboard.
pub struct StubClipboard;

impl Clipboard for StubClipboard {
    fn get(&self) -> String {
        String::new()
    }
    fn set(&self, _text: &str) {}
}
