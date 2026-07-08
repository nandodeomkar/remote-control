//! Runtime no-op executors for the four non-mouse traits so `Executors`
//! can be constructed in the spike binary.
//!
//! NOT the core `MockExecutors` (that is a test recorder) — these are the
//! seed implementations that Phases 4-6 grow into real Windows backends
//! (D-08 kept-as-foundation): Media/Power via key macros (Phase 5), Apps
//! and Clipboard via the `windows` crate (Phase 6).

use server_core::executors::{Apps, Clipboard, Media, Power, WindowInfo};

/// No-op `Media` executor. Phase 5 fills this with enigo media keys +
/// `IAudioEndpointVolume` absolute volume.
pub struct StubMedia;

impl Media for StubMedia {
    fn play_pause(&self) {}
    fn next(&self) {}
    fn prev(&self) {}
    fn vol_up(&self) {}
    fn vol_down(&self) {}
    fn mute(&self) {}
    fn set_volume(&self, _pct: u8) {}
}

/// No-op `Power` executor. Phase 5 fills this with `LockWorkStation` /
/// shutdown APIs (always behind the double-confirm gate).
pub struct StubPower;

impl Power for StubPower {
    fn lock(&self) {}
    fn sleep(&self) {}
    fn restart(&self) {}
    fn shutdown(&self) {}
}

/// No-op `Apps` executor. Phase 6 fills this with `EnumWindows` /
/// `ShellExecuteW`.
pub struct StubApps;

impl Apps for StubApps {
    fn list(&self) -> Vec<WindowInfo> {
        vec![]
    }
    fn launch(&self, _path: &str) {}
    fn focus(&self, _id: u64) {}
    fn close(&self, _id: u64) {}
}

/// No-op `Clipboard` executor. Phase 6 fills this with arboard.
pub struct StubClipboard;

impl Clipboard for StubClipboard {
    fn get(&self) -> String {
        String::new()
    }
    fn set(&self, _text: &str) {}
}
