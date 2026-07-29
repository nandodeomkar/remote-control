//! Recording mock executors for tests.
//!
//! Compiled UNCONDITIONALLY (no `cfg(test)`, no feature gate): the mocks
//! are OS-free and the integration tests in `tests/` link against the
//! library's public surface, so they must always be available.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::Notify;

use super::{
    Apps, BookmarksState, Bookmarks, Button, Clipboard, Executors, KeyCode, Media, Modifier,
    MouseKeys, Power, Tabs, TabsState, WindowInfo,
};

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
    TabsActivate(i64),
    TabsClose(i64),
    BmOpen(String),
    BmStar(i64),
    BmUnstar(i64),
    BmRemove(String),
}

/// Shared, cloneable view of everything the mocks have recorded.
///
/// Internals: one `Mutex<Vec<Call>>` (call order) + one [`Notify`]
/// (notify-driven wakeups for [`CallLog::wait_for`] — NO polling loops).
#[derive(Debug, Clone, Default)]
pub struct CallLog {
    inner: Arc<LogInner>,
}

#[derive(Debug, Default)]
struct LogInner {
    calls: Mutex<Vec<Call>>,
    notify: Notify,
}

impl CallLog {
    /// Append one call and wake every pending [`CallLog::wait_for`].
    fn record(&self, call: Call) {
        self.inner
            .calls
            .lock()
            .expect("CallLog mutex poisoned")
            .push(call);
        self.inner.notify.notify_waiters();
    }

    /// Snapshot of all recorded calls, in order.
    pub fn calls(&self) -> Vec<Call> {
        self.inner
            .calls
            .lock()
            .expect("CallLog mutex poisoned")
            .clone()
    }

    /// Poll until `pred` returns true over the recorded calls, or `timeout`
    /// elapses. Returns whether the predicate was satisfied.
    ///
    /// Notify-driven (no busy-wait): the `Notified` future is registered
    /// BEFORE the predicate check, so a `record` landing between the check
    /// and the await still wakes the waiter (no lost-notification race).
    pub async fn wait_for(&self, pred: impl Fn(&[Call]) -> bool, timeout: Duration) -> bool {
        let satisfied = async {
            loop {
                let notified = self.inner.notify.notified();
                tokio::pin!(notified);
                // Register interest before checking, closing the race window.
                notified.as_mut().enable();
                if pred(&self.inner.calls.lock().expect("CallLog mutex poisoned")) {
                    return;
                }
                notified.await;
            }
        };
        tokio::time::timeout(timeout, satisfied).await.is_ok()
    }
}

/// Mock backend implementing all five executor traits by appending to a
/// shared [`CallLog`].
pub struct MockExecutors {
    log: CallLog,
}

impl MockExecutors {
    /// Build a recording executor bundle: every trait object in the returned
    /// [`Executors`] appends to the returned [`CallLog`] (one shared sink).
    pub fn recording() -> (Executors, CallLog) {
        let log = CallLog::default();
        let mock = Arc::new(MockExecutors { log: log.clone() });
        let executors = Executors {
            mouse_keys: Arc::clone(&mock) as Arc<dyn MouseKeys>,
            media: Arc::clone(&mock) as Arc<dyn Media>,
            power: Arc::clone(&mock) as Arc<dyn Power>,
            apps: Arc::clone(&mock) as Arc<dyn Apps>,
            clipboard: Arc::clone(&mock) as Arc<dyn Clipboard>,
            tabs: Arc::clone(&mock) as Arc<dyn Tabs>,
            bookmarks: mock as Arc<dyn Bookmarks>,
        };
        (executors, log)
    }
}

impl MouseKeys for MockExecutors {
    fn move_rel(&self, dx: f32, dy: f32) {
        self.log.record(Call::MoveRel(dx, dy));
    }
    fn scroll(&self, dx: f32, dy: f32) {
        self.log.record(Call::Scroll(dx, dy));
    }
    fn click(&self, button: Button) {
        self.log.record(Call::Click(button));
    }
    fn button_down(&self, button: Button) {
        self.log.record(Call::ButtonDown(button));
    }
    fn button_up(&self, button: Button) {
        self.log.record(Call::ButtonUp(button));
    }
    fn key_down(&self, code: KeyCode) {
        self.log.record(Call::KeyDown(code));
    }
    fn key_up(&self, code: KeyCode) {
        self.log.record(Call::KeyUp(code));
    }
    fn key_tap(&self, code: KeyCode, mods: &[Modifier]) {
        self.log.record(Call::KeyTap(code, mods.to_vec()));
    }
    fn type_text(&self, text: &str) {
        self.log.record(Call::TypeText(text.to_string()));
    }
    fn backspace(&self, n: u32) {
        self.log.record(Call::Backspace(n));
    }
}

impl Media for MockExecutors {
    fn play_pause(&self) {
        self.log.record(Call::MediaAction("playpause".to_string()));
    }
    fn next(&self) {
        self.log.record(Call::MediaAction("next".to_string()));
    }
    fn prev(&self) {
        self.log.record(Call::MediaAction("prev".to_string()));
    }
    fn vol_up(&self) {
        self.log.record(Call::MediaAction("volup".to_string()));
    }
    fn vol_down(&self) {
        self.log.record(Call::MediaAction("voldown".to_string()));
    }
    fn mute(&self) {
        self.log.record(Call::MediaAction("mute".to_string()));
    }
    fn set_volume(&self, pct: u8) {
        self.log.record(Call::SetVolume(pct));
    }
}

impl Power for MockExecutors {
    fn lock(&self) {
        self.log.record(Call::PowerAction("lock".to_string()));
    }
    fn sleep(&self) {
        self.log.record(Call::PowerAction("sleep".to_string()));
    }
    fn restart(&self) {
        self.log.record(Call::PowerAction("restart".to_string()));
    }
    fn shutdown(&self) {
        self.log.record(Call::PowerAction("shutdown".to_string()));
    }
}

impl Apps for MockExecutors {
    /// Fixed two-entry window table (ids 1, 2) so `apps.list` routing is
    /// assertable through the reply payload. There is no `Call` variant for
    /// `list` — it is a read-only query, observable via its reply.
    fn list(&self) -> Vec<WindowInfo> {
        vec![
            WindowInfo {
                id: 1,
                title: "Mock Window One".to_string(),
                icon: None,
                path: None,
            },
            WindowInfo {
                id: 2,
                title: "Mock Window Two".to_string(),
                icon: None,
                path: None,
            },
        ]
    }
    /// Records the call and reports success (`true`) so pass-through routing
    /// tests still see empty replies; the err{windowGone|launchFailed} path
    /// is exercised by a dedicated failing-apps executor in the router tests.
    fn launch(&self, path: &str) -> bool {
        self.log.record(Call::AppsLaunch(path.to_string()));
        true
    }
    fn focus(&self, id: u64) -> bool {
        self.log.record(Call::AppsFocus(id));
        true
    }
    fn close(&self, id: u64) -> bool {
        self.log.record(Call::AppsClose(id));
        true
    }
}

impl Tabs for MockExecutors {
    /// Returns the never-connected default state so `tabs.list` routing is
    /// assertable through the reply payload. A FailingApps-style custom
    /// impl in tests can return a populated state where needed. Read-only:
    /// not recorded as a `Call`.
    fn list(&self) -> TabsState {
        TabsState::default()
    }
    fn activate(&self, id: i64) {
        self.log.record(Call::TabsActivate(id));
    }
    fn close(&self, id: i64) {
        self.log.record(Call::TabsClose(id));
    }
}

impl Bookmarks for MockExecutors {
    /// Returns the never-connected default state so `bm.list` routing is
    /// assertable through the reply payload — the `Tabs::list` convention.
    /// Read-only: not recorded as a `Call`.
    fn list(&self) -> BookmarksState {
        BookmarksState::default()
    }
    fn open(&self, node_id: &str) {
        self.log.record(Call::BmOpen(node_id.to_string()));
    }
    fn star(&self, tab_id: i64) {
        self.log.record(Call::BmStar(tab_id));
    }
    fn unstar(&self, tab_id: i64) {
        self.log.record(Call::BmUnstar(tab_id));
    }
    fn remove(&self, node_id: &str) {
        self.log.record(Call::BmRemove(node_id.to_string()));
    }
}

impl Clipboard for MockExecutors {
    /// Fixed clipboard content so `clip.get` routing is assertable through
    /// the `clip.set` reply. Read-only: not recorded as a `Call`.
    fn get(&self) -> String {
        "mock-clip".to_string()
    }
    fn set(&self, text: &str) {
        self.log.record(Call::ClipSet(text.to_string()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn wait_for_resolves_after_cross_task_record() {
        let (exec, log) = MockExecutors::recording();
        let mk = Arc::clone(&exec.mouse_keys);
        // Record from ANOTHER task after a delay: wait_for must wake up
        // promptly via the notify path, not by returning a stale snapshot.
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(50)).await;
            mk.button_up(Button::Left);
        });
        let satisfied = log
            .wait_for(
                |calls| calls.contains(&Call::ButtonUp(Button::Left)),
                Duration::from_secs(2),
            )
            .await;
        assert!(satisfied, "wait_for must resolve true once the call lands");
    }

    #[tokio::test]
    async fn wait_for_times_out_when_predicate_never_satisfied() {
        let (_exec, log) = MockExecutors::recording();
        let satisfied = log
            .wait_for(|calls| !calls.is_empty(), Duration::from_millis(100))
            .await;
        assert!(!satisfied, "wait_for must resolve false at timeout");
    }

    #[tokio::test]
    async fn calls_snapshot_preserves_recording_order() {
        let (exec, log) = MockExecutors::recording();
        exec.mouse_keys.click(Button::Left);
        exec.media.play_pause();
        assert_eq!(
            log.calls(),
            vec![Call::Click(Button::Left), Call::MediaAction("playpause".into())],
            "calls() must be a snapshot in call order"
        );
    }

    #[tokio::test]
    async fn every_trait_records_through_the_shared_log() {
        let (exec, log) = MockExecutors::recording();
        exec.mouse_keys.key_tap(KeyCode("F5".into()), &[Modifier::Ctrl]);
        exec.media.set_volume(40);
        exec.power.restart();
        exec.apps.launch("C:\\x.exe");
        exec.clipboard.set("hi");
        assert_eq!(
            log.calls(),
            vec![
                Call::KeyTap(KeyCode("F5".into()), vec![Modifier::Ctrl]),
                Call::SetVolume(40),
                Call::PowerAction("restart".into()),
                Call::AppsLaunch("C:\\x.exe".into()),
                Call::ClipSet("hi".into()),
            ],
            "all five traits must share one recording sink"
        );
    }

    #[tokio::test]
    async fn apps_list_returns_fixed_two_windows() {
        let (exec, _log) = MockExecutors::recording();
        let windows = exec.apps.list();
        assert_eq!(windows.len(), 2, "mock apps.list is a fixed two-entry table");
        assert_eq!(windows[0].id, 1);
        assert_eq!(windows[1].id, 2);
    }

    #[tokio::test]
    async fn clipboard_get_returns_fixed_mock_clip() {
        let (exec, _log) = MockExecutors::recording();
        assert_eq!(exec.clipboard.get(), "mock-clip");
    }
}
