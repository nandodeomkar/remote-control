//! Recording mock executors for tests.
//!
//! Compiled UNCONDITIONALLY (no `cfg(test)`, no feature gate): the mocks
//! are OS-free and the integration tests in `tests/` link against the
//! library's public surface, so they must always be available.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use super::{Apps, Button, Clipboard, Executors, KeyCode, Media, Modifier, MouseKeys, Power, WindowInfo};

/// One recorded executor invocation, in call order.
#[derive(Debug, Clone, PartialEq)]
pub enum Call {
    MoveRel(f32, f32),
    Scroll(f32, f32),
    Click(Button),
    ButtonDown(Button),
    ButtonUp(Button),
    KeyDown(KeyCode),
    KeyUp(KeyCode),
    KeyTap(KeyCode, Vec<Modifier>),
    TypeText(String),
    Backspace(u32),
    /// Media action by wire name (`"playpause"`, `"next"`, `"mute"`, …).
    MediaAction(String),
    SetVolume(u8),
    /// Power action by wire name (`"lock"`, `"sleep"`, …).
    PowerAction(String),
    AppsLaunch(String),
    AppsFocus(u64),
    AppsClose(u64),
    ClipSet(String),
}

/// Shared, cloneable view of everything the mocks have recorded.
#[derive(Debug, Clone, Default)]
pub struct CallLog {
    calls: Arc<Mutex<Vec<Call>>>,
}

impl CallLog {
    /// Snapshot of all recorded calls, in order.
    pub fn calls(&self) -> Vec<Call> {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }

    /// Poll until `pred` returns true over the recorded calls, or `timeout`
    /// elapses. Returns whether the predicate was satisfied.
    pub async fn wait_for(&self, pred: impl Fn(&[Call]) -> bool, timeout: Duration) -> bool {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
}

/// Mock backend implementing all five executor traits by appending to a
/// shared [`CallLog`].
pub struct MockExecutors {
    log: CallLog,
}

impl MockExecutors {
    /// Build a recording executor bundle: every trait object in the returned
    /// [`Executors`] appends to the returned [`CallLog`].
    pub fn recording() -> (Executors, CallLog) {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
}

impl MouseKeys for MockExecutors {
    fn move_rel(&self, dx: f32, dy: f32) {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
    fn scroll(&self, dx: f32, dy: f32) {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
    fn click(&self, button: Button) {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
    fn button_down(&self, button: Button) {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
    fn button_up(&self, button: Button) {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
    fn key_down(&self, code: KeyCode) {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
    fn key_up(&self, code: KeyCode) {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
    fn key_tap(&self, code: KeyCode, mods: &[Modifier]) {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
    fn type_text(&self, text: &str) {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
    fn backspace(&self, n: u32) {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
}

impl Media for MockExecutors {
    fn play_pause(&self) {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
    fn next(&self) {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
    fn prev(&self) {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
    fn vol_up(&self) {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
    fn vol_down(&self) {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
    fn mute(&self) {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
    fn set_volume(&self, pct: u8) {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
}

impl Power for MockExecutors {
    fn lock(&self) {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
    fn sleep(&self) {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
    fn restart(&self) {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
    fn shutdown(&self) {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
}

impl Apps for MockExecutors {
    fn list(&self) -> Vec<WindowInfo> {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
    fn launch(&self, path: &str) {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
    fn focus(&self, id: u64) {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
    fn close(&self, id: u64) {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
}

impl Clipboard for MockExecutors {
    fn get(&self) -> String {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
    fn set(&self, text: &str) {
        todo!("implemented in plan 01-05 (dispatch wave)")
    }
}
