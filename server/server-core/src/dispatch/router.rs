//! Family routing behind the auth and pause gates (SPEC §6, §7, §10, §11).

use std::sync::Mutex;
use std::time::Duration;

// tokio's Instant (not std's) so the paused-clock test harness
// (`start_paused` + `tokio::time::advance`) can drive the 10s confirm
// window deterministically. Outside a test runtime it is std's Instant.
use tokio::time::Instant;

use crate::auth::AuthManager;
use crate::codec::binary::MouseFrame;
use crate::codec::json::{
    AppsListPayload, BmListPayload, ClipSetPayload, Decoded, ErrPayload, LastUpdatePayload, Msg,
    PongPayload, TabsListPayload, UpdateStatusPayload,
};
use crate::dispatch::AuthState;
use crate::dispatch::held::HeldInput;
use crate::executors::{Button, Executors, KeyCode, Modifier};

/// Maximum `text.bs` value; larger requests are rejected with
/// `err{code:"bsTooLarge"}` and not executed (SPEC §8).
pub const MAX_BS: u64 = 10000;

/// `power` → `confirm` window (SPEC §7): a confirm landing later than this
/// after its `power` request is `err{noPendingAction}`.
const CONFIRM_WINDOW: Duration = Duration::from_secs(10);

/// Mutable per-session routing context.
pub struct SessionCtx {
    /// Handshake FSM state — the structural auth gate (threat T-01-09).
    pub auth_state: AuthState,
    /// Held buttons/keys for CONN-07 release-on-session-end.
    pub held: HeldInput,
    /// Pending `power` action awaiting `confirm`: (action, requested-at).
    /// The confirm window is 10 seconds (SPEC §7).
    pub pending_power: Option<(String, Instant)>,
}

/// Route one decoded JSON message through the gates.
///
/// Behavior contract:
/// - Pre-auth: only `hello`/`pin`/`auth` are processed; everything else is
///   silently dropped — NO reply (SPEC §6).
/// - Paused: executor-bound messages are silently dropped; handshake and
///   `ping`/`pong` still work (SPEC §11).
/// - Unknown `t` post-auth: reply `err{unknownType}`, keep session (D-07).
///
/// Returns the messages the session must send back to the client (possibly
/// empty).
pub fn route(
    decoded: Decoded,
    ctx: &mut SessionCtx,
    exec: &Executors,
    _auth: &Mutex<AuthManager>,
    paused: bool,
) -> Vec<Msg> {
    // Handshake messages (hello/pin/auth) are owned by the session-layer
    // FSM (Plan 06) — they must never reach the post-auth router.
    debug_assert!(
        !matches!(decoded.msg, Msg::Hello(_) | Msg::Pin(_) | Msg::Auth(_)),
        "handshake messages are owned by the session FSM, never route()"
    );

    // GATE 1 — auth (SPEC §6, threat T-01-20): pre-auth, EVERYTHING
    // non-handshake is silently dropped. No reply, no executor call, no
    // probing oracle — even `ping` gets nothing.
    if ctx.auth_state != AuthState::Authed {
        return Vec::new();
    }

    // GATE 2 — pause (SPEC §11, threat T-01-21): executor-bound families
    // are silently dropped while paused. `ping`/`pong` (and the read-only
    // queries `apps.list`/`clip.get`/`tabs.list`/`bm.list`, which SPEC §11
    // exempts) keep working — pause never breaks liveness probing.
    if paused && is_executor_bound(&decoded.msg) {
        return Vec::new();
    }

    // GATE 3 — family routing to the OS-agnostic trait objects.
    match decoded.msg {
        // ── mouse / keyboard ───────────────────────────────────────────
        Msg::Click(p) => {
            if let Some(button) = parse_button(&p.button) {
                exec.mouse_keys.click(button);
            }
            Vec::new()
        }
        Msg::Drag(p) => {
            if let Some(button) = parse_button(&p.button) {
                match p.action.as_str() {
                    // Held state updates BEFORE the trait call (RESEARCH
                    // Pattern 4): tracking must never lag execution.
                    "start" => {
                        ctx.held.note_button_down(button);
                        exec.mouse_keys.button_down(button);
                    }
                    "end" => {
                        ctx.held.note_button_up(button);
                        exec.mouse_keys.button_up(button);
                    }
                    _ => {} // semantic validation: unknown action → drop
                }
            }
            Vec::new()
        }
        Msg::Key(p) => {
            let code = KeyCode(p.code);
            match p.action.as_str() {
                "tap" => exec.mouse_keys.key_tap(code, &parse_mods(&p.mods)),
                "down" => {
                    ctx.held.note_key_down(code.clone());
                    exec.mouse_keys.key_down(code);
                }
                "up" => {
                    ctx.held.note_key_up(code.clone());
                    exec.mouse_keys.key_up(code);
                }
                _ => {} // unknown action → drop
            }
            Vec::new()
        }
        Msg::Text(p) => {
            // T-01-22: cap check BEFORE any executor call.
            if p.bs > MAX_BS {
                return vec![err(
                    "bsTooLarge",
                    format!("text.bs {} exceeds the cap of {MAX_BS}", p.bs),
                )];
            }
            if p.bs > 0 {
                // Infallible narrowing: bs <= MAX_BS = 10000 < u32::MAX.
                exec.mouse_keys.backspace(p.bs as u32);
            }
            if !p.ins.is_empty() {
                exec.mouse_keys.type_text(&p.ins);
            }
            Vec::new()
        }

        // ── media ──────────────────────────────────────────────────────
        Msg::Media(p) => {
            match p.action.as_str() {
                "playpause" => exec.media.play_pause(),
                "next" => exec.media.next(),
                "prev" => exec.media.prev(),
                "volup" => exec.media.vol_up(),
                "voldown" => exec.media.vol_down(),
                "mute" => exec.media.mute(),
                // `value` required iff setvol (SPEC §7); out-of-range or
                // missing values are semantic errors → dropped.
                "setvol" => {
                    if let Some(pct) = p.value.filter(|v| *v <= 100) {
                        exec.media.set_volume(pct);
                    }
                }
                _ => {} // unknown action → drop
            }
            Vec::new()
        }

        // ── power double-confirm gate (SPEC §7, threat T-01-23) ────────
        Msg::Power(p) => {
            if matches!(p.action.as_str(), "lock" | "sleep" | "restart" | "shutdown") {
                ctx.pending_power = Some((p.action, Instant::now()));
            }
            // NEVER an executor call from `power` alone.
            Vec::new()
        }
        Msg::Confirm(p) => {
            // take(): the pending slot is single-shot. A mismatched confirm
            // also clears it — suspicious traffic must restart the two-step
            // sequence from `power`.
            match ctx.pending_power.take() {
                Some((action, requested_at))
                    if action == p.action && requested_at.elapsed() < CONFIRM_WINDOW =>
                {
                    match action.as_str() {
                        "lock" => exec.power.lock(),
                        "sleep" => exec.power.sleep(),
                        "restart" => exec.power.restart(),
                        "shutdown" => exec.power.shutdown(),
                        // Only the four validated actions are ever stored.
                        _ => unreachable!("pending_power only stores validated actions"),
                    }
                    Vec::new()
                }
                _ => vec![err(
                    "noPendingAction",
                    format!("no pending power action matches confirm '{}'", p.action),
                )],
            }
        }

        // ── apps ───────────────────────────────────────────────────────
        Msg::AppsList(_) => vec![Msg::AppsList(AppsListPayload {
            windows: Some(exec.apps.list()),
        })],
        // APPS-01: a failed action returns err{launchFailed|windowGone} so
        // the client can toast it (SC1). The err `msg` is operator-facing
        // prose — it NEVER embeds the exe path or the HWND id (T-06-12,
        // SPEC §12 no-payload-logging / copy contract).
        Msg::AppsLaunch(p) => {
            if exec.apps.launch(&p.path) {
                Vec::new()
            } else {
                vec![err("launchFailed", "could not launch the app".to_string())]
            }
        }
        Msg::AppsFocus(p) => {
            if exec.apps.focus(p.id) {
                Vec::new()
            } else {
                vec![err("windowGone", "that window is no longer available".to_string())]
            }
        }
        Msg::AppsClose(p) => {
            if exec.apps.close(p.id) {
                Vec::new()
            } else {
                vec![err("windowGone", "that window is no longer available".to_string())]
            }
        }

        // ── clipboard ──────────────────────────────────────────────────
        Msg::ClipSet(p) => {
            exec.clipboard.set(&p.text);
            Vec::new()
        }
        Msg::ClipGet(_) => vec![Msg::ClipSet(ClipSetPayload {
            text: exec.clipboard.get(),
        })],

        // ── tabs (protoVersion 1.4, BROW-01) ───────────────────────────
        // tabs.list is a READ (SPEC §11 pause exemption, like apps.list):
        // the reply carries the relay's current state — including the
        // never-connected {connected:false, tabs:[]} hint shape.
        Msg::TabsList(_) => {
            let state = exec.tabs.list();
            vec![Msg::TabsList(TabsListPayload {
                connected: Some(state.connected),
                tabs: Some(state.tabs),
                // 1.5 server always emits groups (empty when none) — 1.4
                // clients drop the unknown key per D-05.
                groups: Some(state.groups),
            })]
        }
        // Fire-and-forget (SPEC §7): no err reply — stale ids self-heal via
        // the next tabs.changed push. Both are executor-bound (pause gate).
        Msg::TabsActivate(p) => {
            exec.tabs.activate(p.id);
            Vec::new()
        }
        Msg::TabsClose(p) => {
            exec.tabs.close(p.id);
            Vec::new()
        }

        // ── bookmarks (protoVersion 1.6, phase 11) ─────────────────────
        // bm.list is a READ (SPEC §11 pause exemption, like apps.list):
        // the reply carries the relay's current state — including the
        // never-connected {connected:false, nodes:[]} install-hint shape.
        Msg::BmList(_) => {
            let state = exec.bookmarks.list();
            vec![Msg::BmList(BmListPayload {
                connected: Some(state.connected),
                nodes: Some(state.nodes),
                // The 1.6 server ALWAYS emits truncated (the same posture as
                // the 1.5 groups array) — older clients drop the unknown key
                // per D-05.
                truncated: Some(state.truncated),
            })]
        }
        // Fire-and-forget (SPEC §7): NO err reply exists for any of the four
        // — stale node/tab ids self-heal via the next bm.changed push, and
        // adding an err code would break the family's posture (and hand a
        // caller an existence oracle over bookmark ids). All four are
        // executor-bound, so the pause gate drops them (D-13/D-14
        // destructive actions included).
        Msg::BmOpen(p) => {
            exec.bookmarks.open(&p.node_id);
            Vec::new()
        }
        Msg::BmStar(p) => {
            exec.bookmarks.star(p.tab_id);
            Vec::new()
        }
        Msg::BmUnstar(p) => {
            exec.bookmarks.unstar(p.tab_id);
            Vec::new()
        }
        Msg::BmRemove(p) => {
            exec.bookmarks.remove(&p.node_id);
            Vec::new()
        }

        // ── key-macro families (Phase 1 minimal tables; Phase 5 refines)
        Msg::Browser(p) => {
            if let Some((code, mods)) = browser_macro(&p.action) {
                exec.mouse_keys.key_tap(code, &mods);
            }
            Vec::new()
        }
        Msg::Present(p) => {
            if let Some(code) = present_macro(&p.action) {
                exec.mouse_keys.key_tap(code, &[]);
            }
            Vec::new()
        }

        // ── liveness ───────────────────────────────────────────────────
        Msg::Ping(p) => vec![Msg::Pong(PongPayload { ts: p.ts })],

        // ── unknown type (SPEC §10, D-07, threat T-01-25) ──────────────
        Msg::Unknown { t } => vec![err(
            "unknownType",
            format!("unknown message type: {t}"),
        )],

        // Handshake types: unreachable post-debug_assert; release builds
        // drop them defensively (the session FSM owns them).
        Msg::Hello(_) | Msg::Pin(_) | Msg::Auth(_) => Vec::new(),

        // ── in-app updates (protoVersion 1.8, phase 12) ────────────────
        // `update.check` is a read-with-reply (the `bm.list` shape) but it is
        // NOT pause-exempt — see `is_executor_bound`'s doc comment for why
        // (D-13).
        //
        // **`info()` TAKES the pending marker**, so this arm is the one and
        // only place `lastUpdate` can appear: a marker is reported on exactly
        // one `update.status` and never again (D-12). Calling `info()` twice
        // here — or calling it anywhere else on the request path — would
        // silently consume the marker and the owner would never see that the
        // previous install failed.
        Msg::UpdateCheck(_) => {
            let info = exec.update.info();
            vec![Msg::UpdateStatus(UpdateStatusPayload {
                server_version: info.server_version,
                ext_connected: info.ext_connected,
                ext_version: info.ext_version,
                last_update: info.last_update.map(|lu| LastUpdatePayload {
                    target: lu.target,
                    ok: lu.ok,
                    error: lu.error,
                }),
            })]
        }
        // Fire-and-forget (SPEC §7): no reply, no err code — the whole
        // outcome, including every refusal, arrives as `update.progress`
        // pushes on the executor's own thread.
        //
        // **D-14 (threat T-12-01): `&p.target` is the ONLY value that
        // crosses this boundary, and it is a version string.** The executor
        // resolves the asset's download URL and its sha256 ITSELF, from a
        // repo constant compiled into `server-windows` — a crate the codec
        // cannot see. There is no field here in which a URL, filename, asset
        // id or hash could travel, which is why `forged_apply_is_refused`
        // asserts the exact recorded argument and `tests/update_guard.rs`
        // fails the build if such a field is ever added.
        Msg::UpdateApply(p) => {
            exec.update.apply(&p.target);
            Vec::new()
        }

        // S→C-only types arriving FROM a client are known-but-invalid
        // direction: ignored silently (no unknownType — the type IS known;
        // no routing fallthrough — nothing executes).
        Msg::PairOk(_)
        | Msg::Challenge(_)
        | Msg::AuthOk(_)
        | Msg::AuthFail(_)
        | Msg::AppsChanged(_)
        | Msg::ClipChanged(_)
        | Msg::VolChanged(_)
        | Msg::InputBlocked(_)
        | Msg::TabsChanged(_)
        | Msg::BmChanged(_)
        | Msg::UpdateStatus(_)
        | Msg::UpdateProgress(_)
        | Msg::Pong(_)
        | Msg::Err(_) => Vec::new(),
    }
}

/// SPEC §11's pause drop list: every executor-bound family. `ping`/`pong`
/// and the read-only queries (`apps.list`, `clip.get`, `tabs.list`,
/// `bm.list`) are exempt — a paused PC still answers reads, so the phone
/// renders an honest list instead of an empty lie (D-03).
///
/// **`update.check` is the ONE read that is deliberately NOT exempt
/// (protoVersion 1.8, D-13).** The exemption above exists because answering a
/// list while paused is harmless: it describes the machine and offers nothing.
/// `update.check` is different — it reports the version state of a machine
/// that is about to be REPLACED, and the only thing the phone does with that
/// answer is offer an install. Answering it while paused would advertise an
/// action the session has just been told it may not take, and `update.apply`
/// (which is executor-bound for the obvious reason) would then be dropped
/// after the owner had already tapped. Both halves of the family therefore
/// stop at the same gate. Do NOT "fix" `update.check` back into the read
/// exemption list on the grounds that it is a read — it is, and that is not
/// the criterion.
fn is_executor_bound(msg: &Msg) -> bool {
    matches!(
        msg,
        Msg::Click(_)
            | Msg::Drag(_)
            | Msg::Key(_)
            | Msg::Text(_)
            | Msg::Media(_)
            | Msg::Power(_)
            | Msg::Confirm(_)
            | Msg::AppsLaunch(_)
            | Msg::AppsFocus(_)
            | Msg::AppsClose(_)
            | Msg::ClipSet(_)
            | Msg::Browser(_)
            | Msg::Present(_)
            | Msg::TabsActivate(_)
            | Msg::TabsClose(_)
            | Msg::BmOpen(_) | Msg::BmStar(_) | Msg::BmUnstar(_) | Msg::BmRemove(_)
            // protoVersion 1.8 (D-13): the check as well as the apply — see
            // the doc comment above for why the read is not exempt.
            | Msg::UpdateCheck(_) | Msg::UpdateApply(_)
    )
}

/// Semantic validation of the wire `button` string (codec is value-lenient
/// by design; the router owns enum validation). Unknown values → `None` →
/// silent drop.
fn parse_button(s: &str) -> Option<Button> {
    match s {
        "left" => Some(Button::Left),
        "middle" => Some(Button::Middle),
        "right" => Some(Button::Right),
        _ => None,
    }
}

/// Parse wire `key.mods` strings; unknown modifier names are skipped.
fn parse_mods(mods: &[String]) -> Vec<Modifier> {
    mods.iter()
        .filter_map(|m| match m.as_str() {
            "ctrl" => Some(Modifier::Ctrl),
            "alt" => Some(Modifier::Alt),
            "shift" => Some(Modifier::Shift),
            "win" => Some(Modifier::Win),
            _ => None,
        })
        .collect()
}

/// `browser` → key-macro table (Phase 1 minimal mapping; Phase 5 refines
/// semantics). Unknown actions → `None` → silent drop.
fn browser_macro(action: &str) -> Option<(KeyCode, Vec<Modifier>)> {
    let (code, mods): (&str, Vec<Modifier>) = match action {
        "back" => ("BrowserBack", vec![]),
        "forward" => ("BrowserForward", vec![]),
        "newtab" => ("T", vec![Modifier::Ctrl]),
        "closetab" => ("W", vec![Modifier::Ctrl]),
        "refresh" => ("F5", vec![]),
        "zoomin" => ("Plus", vec![Modifier::Ctrl]),
        "zoomout" => ("Minus", vec![Modifier::Ctrl]),
        _ => return None,
    };
    Some((KeyCode(code.to_string()), mods))
}

/// `present` → key-macro table (Phase 1 minimal; modifier-free).
fn present_macro(action: &str) -> Option<KeyCode> {
    let code = match action {
        "next" => "Right",
        "prev" => "Left",
        "start" => "F5",
        "end" => "Esc",
        "blank" => "B",
        _ => return None,
    };
    Some(KeyCode(code.to_string()))
}

/// Build an `err` reply with `code` + human-readable `msg` (SPEC §7).
fn err(code: &str, msg: String) -> Msg {
    Msg::Err(ErrPayload {
        code: code.to_string(),
        msg,
        server_version: None,
        client_version: None,
    })
}

/// Route one decoded binary mouse frame (fire-and-forget hot path).
///
/// Dropped silently unless `ctx.auth_state` is [`AuthState::Authed`] and not
/// `paused` (SPEC §6, §11). Never replies.
pub fn route_binary(frame: MouseFrame, ctx: &SessionCtx, exec: &Executors, paused: bool) {
    // Same gate order as route(): auth first (SPEC §6), pause second
    // (SPEC §11). Binary frames never produce a reply.
    if ctx.auth_state != AuthState::Authed || paused {
        return;
    }
    match frame {
        MouseFrame::Move { dx, dy } => exec.mouse_keys.move_rel(dx, dy),
        MouseFrame::Scroll { dx, dy } => exec.mouse_keys.scroll(dx, dy),
        MouseFrame::Zoom { dx, dy } => exec.mouse_keys.zoom(dx, dy),
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tokio::time::advance;

    use super::*;
    use crate::codec::json::{
        AppsClosePayload, AppsFocusPayload, AppsLaunchPayload, AppsListPayload, BmChangedPayload,
        BmListPayload, BmOpenPayload, BmRemovePayload, BmStarPayload, BmUnstarPayload,
        BrowserPayload, ClickPayload, ClipGetPayload, ClipSetPayload, ConfirmPayload, DragPayload,
        ErrPayload, KeyPayload, MediaPayload, PingPayload, PongPayload, PowerPayload,
        PresentPayload, TabsActivatePayload, TabsClosePayload, TabsListPayload, TextPayload,
        UpdateApplyPayload, UpdateCheckPayload, UpdateProgressPayload,
    };
    use crate::executors::mock::{Call, MockExecutors, MockUpdate};
    use crate::executors::{
        Apps, BmNode, Bookmarks, BookmarksState, Button, Executors, GroupInfo, KeyCode, LastUpdate,
        Modifier, TabInfo, Tabs, TabsState, UpdateExecutor, UpdateInfo, WindowInfo,
    };
    use std::sync::Arc;

    /// Apps executor whose actions always FAIL (`false`) — drives the
    /// APPS-01 err{windowGone|launchFailed} path. `list` returns empty.
    struct FailingApps;
    impl Apps for FailingApps {
        fn list(&self) -> Vec<WindowInfo> {
            Vec::new()
        }
        fn launch(&self, _path: &str) -> bool {
            false
        }
        fn focus(&self, _id: u64) -> bool {
            false
        }
        fn close(&self, _id: u64) -> bool {
            false
        }
    }

    /// Tabs executor with a POPULATED fixed state (the recording mock's
    /// `list` returns the default) — drives the tabs.list reply assertions,
    /// including the paused read-exemption test.
    struct PopulatedTabs;
    impl PopulatedTabs {
        fn state() -> TabsState {
            TabsState {
                connected: true,
                tabs: vec![
                    TabInfo {
                        id: 7,
                        title: "GitHub".into(),
                        active: true,
                        icon: None,
                        group_id: Some(1),
                        // Tri-state UNKNOWN (protoVersion 1.6): these tabs
                        // predate the bookmark relay, so the key stays off
                        // the wire and every existing assertion is unchanged.
                        bookmarked: None,
                    },
                    TabInfo {
                        id: 9,
                        title: "Docs".into(),
                        active: false,
                        icon: None,
                        group_id: None,
                        bookmarked: None,
                    },
                ],
                groups: vec![GroupInfo {
                    id: 1,
                    title: "Work".into(),
                    color: "blue".into(),
                    collapsed: false,
                }],
            }
        }
    }
    impl Tabs for PopulatedTabs {
        fn list(&self) -> TabsState {
            Self::state()
        }
        fn activate(&self, _id: i64) {}
        fn close(&self, _id: i64) {}
    }

    /// Bookmarks executor with a POPULATED fixed state (the recording mock's
    /// `list` returns the never-connected default) — drives the bm.list
    /// reply assertions, including the paused read-exemption test. The four
    /// command methods are no-ops: this double exists to prove the READ
    /// path, the recording mock proves the command path.
    struct PopulatedBookmarks;
    impl PopulatedBookmarks {
        fn state() -> BookmarksState {
            BookmarksState {
                connected: true,
                nodes: vec![
                    BmNode {
                        id: "1".into(),
                        parent_id: "0".into(),
                        title: "Bookmarks bar".into(),
                        folder: Some(true),
                        count: Some(2),
                        locked: Some(true),
                        truncated: None,
                    },
                    BmNode {
                        id: "12".into(),
                        parent_id: "1".into(),
                        title: "Rust docs".into(),
                        folder: None,
                        count: None,
                        locked: None,
                        truncated: None,
                    },
                ],
                truncated: true,
            }
        }
    }
    impl Bookmarks for PopulatedBookmarks {
        fn list(&self) -> BookmarksState {
            Self::state()
        }
        fn open(&self, _node_id: &str) {}
        fn star(&self, _tab_id: i64) {}
        fn unstar(&self, _tab_id: i64) {}
        fn remove(&self, _node_id: &str) {}
    }

    fn d(msg: Msg) -> Decoded {
        Decoded { seq: None, msg }
    }

    fn ctx(state: AuthState) -> SessionCtx {
        SessionCtx { auth_state: state, held: HeldInput::default(), pending_power: None }
    }

    fn auth() -> Mutex<AuthManager> {
        Mutex::new(AuthManager::new())
    }

    fn click_left() -> Msg {
        Msg::Click(ClickPayload { button: "left".into() })
    }

    fn ping(ts: u64) -> Msg {
        Msg::Ping(PingPayload { ts })
    }

    fn assert_single_err<'a>(reply: &'a [Msg], code: &str) -> &'a ErrPayload {
        match reply {
            [Msg::Err(p)] => {
                assert_eq!(p.code, code, "unexpected err code (msg: {})", p.msg);
                p
            }
            other => panic!("expected exactly one err {{code:{code}}}, got: {other:?}"),
        }
    }

    // ── Gate 1: auth (T-01-20) ─────────────────────────────────────────

    #[tokio::test]
    async fn pre_auth_drops_every_non_handshake_message_silently() {
        for state in [AuthState::AwaitingHello, AuthState::AwaitingAuth] {
            let (exec, log) = MockExecutors::recording();
            let auth = auth();
            let mut ctx = ctx(state);
            for msg in [
                click_left(),
                Msg::Text(TextPayload { bs: 1, ins: "x".into() }),
                ping(7),
                Msg::Unknown { t: "gesture.swipe".into() },
                Msg::Media(MediaPayload { action: "playpause".into(), value: None }),
                Msg::Power(PowerPayload { action: "restart".into() }),
            ] {
                let reply = route(d(msg), &mut ctx, &exec, &auth, false);
                assert!(reply.is_empty(), "pre-auth ({state:?}) must produce NO reply");
            }
            assert!(log.calls().is_empty(), "pre-auth ({state:?}) must reach NO executor");
        }
    }

    #[tokio::test]
    async fn pre_auth_ping_dropped_even_though_pause_would_pong_it() {
        // Ordering proof: the auth gate runs BEFORE the pause gate's
        // ping exemption — pre-auth ping gets nothing, even while paused.
        let (exec, log) = MockExecutors::recording();
        let auth = auth();
        let mut ctx = ctx(AuthState::AwaitingHello);
        let reply = route(d(ping(1)), &mut ctx, &exec, &auth, true);
        assert!(reply.is_empty(), "pre-auth ping must be silently dropped");
        assert!(log.calls().is_empty());
    }

    #[tokio::test]
    async fn pre_auth_binary_frames_dropped() {
        for state in [AuthState::AwaitingHello, AuthState::AwaitingAuth] {
            let (exec, log) = MockExecutors::recording();
            let ctx = ctx(state);
            route_binary(MouseFrame::Move { dx: 1.0, dy: 2.0 }, &ctx, &exec, false);
            route_binary(MouseFrame::Scroll { dx: 0.0, dy: -3.0 }, &ctx, &exec, false);
            assert!(log.calls().is_empty(), "pre-auth binary must reach NO executor");
        }
    }

    // ── Gate 2: pause (T-01-21) ────────────────────────────────────────

    #[tokio::test]
    async fn paused_drops_every_executor_bound_family_silently() {
        let (base, log) = MockExecutors::recording();
        // The update slot is NOT the shared CallLog (see MockUpdate's doc), so
        // it needs its own handle for the "reached NO executor" assertion.
        let update = Arc::new(MockUpdate::new());
        update.set_info(UpdateInfo {
            server_version: "1.5.0".into(),
            ext_connected: true,
            ext_version: Some("1.5.0".into()),
            last_update: None,
        });
        let exec = Executors { update: Arc::clone(&update) as Arc<dyn UpdateExecutor>, ..base };
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);
        for msg in [
            click_left(),
            Msg::Drag(DragPayload { action: "start".into(), button: "left".into() }),
            Msg::Key(KeyPayload { code: "KeyA".into(), action: "tap".into(), mods: vec![] }),
            Msg::Text(TextPayload { bs: 0, ins: "x".into() }),
            Msg::Media(MediaPayload { action: "mute".into(), value: None }),
            Msg::Power(PowerPayload { action: "lock".into() }),
            Msg::Confirm(ConfirmPayload { action: "lock".into() }),
            Msg::AppsLaunch(AppsLaunchPayload { path: "C:\\x.exe".into() }),
            Msg::AppsFocus(AppsFocusPayload { id: 1 }),
            Msg::AppsClose(AppsClosePayload { id: 1 }),
            Msg::ClipSet(ClipSetPayload { text: "t".into() }),
            Msg::Browser(BrowserPayload { action: "back".into() }),
            Msg::Present(PresentPayload { action: "next".into() }),
            Msg::TabsActivate(TabsActivatePayload { id: 7 }),
            Msg::TabsClose(TabsClosePayload { id: 9 }),
            // protoVersion 1.6: pause means the phone cannot CHANGE the PC,
            // and that includes the D-13/D-14 destructive bookmark commands.
            Msg::BmOpen(BmOpenPayload { node_id: "1234".into() }),
            Msg::BmStar(BmStarPayload { tab_id: 7 }),
            Msg::BmUnstar(BmUnstarPayload { tab_id: 7 }),
            Msg::BmRemove(BmRemovePayload { node_id: "1234".into() }),
            // protoVersion 1.8 (D-13): the update family stops here TOO —
            // including `update.check`, which is a read and is deliberately
            // NOT in the SPEC §11 read-exemption list (see is_executor_bound).
            Msg::UpdateCheck(UpdateCheckPayload {}),
            Msg::UpdateApply(UpdateApplyPayload { target: "1.6.0".into() }),
        ] {
            let reply = route(d(msg), &mut ctx, &exec, &auth, true);
            assert!(reply.is_empty(), "paused executor-bound traffic must produce NO reply");
        }
        assert!(log.calls().is_empty(), "paused traffic must reach NO executor");
        assert!(
            update.applies().is_empty(),
            "a paused session must NOT be able to start an install (T-12-45)"
        );
    }

    /// SPEC §11 read exemption (BROW-01): tabs.list still answers while
    /// paused — the same exemption as apps.list/clip.get — and the reply
    /// carries the Tabs executor's current state.
    #[tokio::test]
    async fn paused_tabs_list_still_answers_with_state() {
        let (base, log) = MockExecutors::recording();
        let exec = Executors { tabs: Arc::new(PopulatedTabs), ..base };
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);

        let reply = route(
            d(Msg::TabsList(TabsListPayload { connected: None, tabs: None, groups: None })),
            &mut ctx, &exec, &auth, true,
        );
        match &reply[..] {
            [Msg::TabsList(TabsListPayload {
                connected: Some(true),
                tabs: Some(tabs),
                groups: Some(groups),
            })] => {
                assert_eq!(tabs.len(), 2, "reply must carry the executor's tabs");
                assert_eq!(tabs[0].id, 7);
                assert!(tabs[0].active, "active flag must survive the reply");
                assert_eq!(tabs[0].group_id, Some(1), "groupId must survive the reply");
                assert_eq!(tabs[1].id, 9);
                assert_eq!(tabs[1].group_id, None, "ungrouped tab stays groupId-less");
                assert_eq!(groups.len(), 1, "reply must carry the executor's groups (1.5)");
                assert_eq!(groups[0].id, 1);
                assert_eq!(groups[0].color, "blue");
            }
            other => panic!("expected a tabs.list reply with state, got: {other:?}"),
        }
        assert!(log.calls().is_empty(), "tabs.list is a read — no recorded call");
    }

    /// BROW-01 routing: unpaused tabs.activate/close reach the recording
    /// mock with the right ids and produce NO reply (fire-and-forget).
    #[tokio::test]
    async fn tabs_activate_and_close_route_when_unpaused() {
        let (exec, log) = MockExecutors::recording();
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);

        assert!(
            route(
                d(Msg::TabsActivate(TabsActivatePayload { id: 7 })),
                &mut ctx, &exec, &auth, false,
            )
            .is_empty(),
            "tabs.activate is fire-and-forget: no reply"
        );
        assert!(
            route(
                d(Msg::TabsClose(TabsClosePayload { id: 9 })),
                &mut ctx, &exec, &auth, false,
            )
            .is_empty(),
            "tabs.close is fire-and-forget: no reply"
        );
        assert_eq!(
            log.calls(),
            vec![Call::TabsActivate(7), Call::TabsClose(9)]
        );
    }

    /// The recording mock's tabs.list reply carries its (default) state —
    /// the never-connected {connected:false, tabs:[]} hint shape.
    #[tokio::test]
    async fn tabs_list_replies_mock_default_state() {
        let (exec, _log) = MockExecutors::recording();
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);
        let reply = route(
            d(Msg::TabsList(TabsListPayload { connected: None, tabs: None, groups: None })),
            &mut ctx, &exec, &auth, false,
        );
        assert_eq!(
            reply,
            vec![Msg::TabsList(TabsListPayload {
                connected: Some(false),
                tabs: Some(Vec::new()),
                groups: Some(Vec::new()),
            })],
            "mock default state must reply the never-connected hint shape"
        );
    }

    /// SPEC §11 read exemption (protoVersion 1.6, D-03): bm.list still
    /// answers while paused — the same exemption as apps.list/clip.get/
    /// tabs.list — so the phone renders an HONEST bookmark list instead of
    /// an empty lie whenever the PC happens to be paused.
    #[tokio::test]
    async fn paused_bm_list_still_answers_with_state() {
        let (base, log) = MockExecutors::recording();
        let exec = Executors { bookmarks: Arc::new(PopulatedBookmarks), ..base };
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);

        let reply = route(
            d(Msg::BmList(BmListPayload { connected: None, nodes: None, truncated: None })),
            &mut ctx, &exec, &auth, true,
        );
        match &reply[..] {
            [Msg::BmList(BmListPayload {
                connected: Some(true),
                nodes: Some(nodes),
                truncated: Some(true),
            })] => {
                assert_eq!(nodes.len(), 2, "reply must carry the executor's nodes");
                assert_eq!(nodes[0].id, "1");
                assert_eq!(nodes[0].folder, Some(true), "folder flag must survive the reply");
                assert_eq!(nodes[0].count, Some(2), "count must survive the reply");
                assert_eq!(nodes[0].locked, Some(true), "locked must survive the reply");
                assert_eq!(nodes[1].id, "12");
                assert_eq!(nodes[1].folder, None, "a plain link stays folder-less");
            }
            other => panic!("expected a bm.list reply with state, got: {other:?}"),
        }
        assert!(log.calls().is_empty(), "bm.list is a read — no recorded call");
    }

    /// The recording mock's bm.list reply carries its (default) state — the
    /// never-connected {connected:false, nodes:[]} install-hint shape the
    /// phone keys its "install the extension" copy on.
    #[tokio::test]
    async fn bm_list_replies_mock_default_state() {
        let (exec, _log) = MockExecutors::recording();
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);
        let reply = route(
            d(Msg::BmList(BmListPayload { connected: None, nodes: None, truncated: None })),
            &mut ctx, &exec, &auth, false,
        );
        assert_eq!(
            reply,
            vec![Msg::BmList(BmListPayload {
                connected: Some(false),
                nodes: Some(Vec::new()),
                truncated: Some(false),
            })],
            "mock default state must reply the never-connected hint shape"
        );
    }

    /// Direction rule (SPEC §7): bm.changed is S→C-ONLY. A client that sends
    /// it is ignored SILENTLY — specifically NOT err{unknownType}, because
    /// the type IS known, only the direction is wrong. An err here would
    /// also hand a caller a type-existence oracle.
    #[tokio::test]
    async fn client_sent_bm_changed_ignored_without_err() {
        let (exec, log) = MockExecutors::recording();
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);

        let reply = route(
            d(Msg::BmChanged(BmChangedPayload {
                connected: true,
                nodes: vec![],
                truncated: None,
            })),
            &mut ctx, &exec, &auth, false,
        );
        assert!(
            reply.is_empty(),
            "bm.changed is S→C-only: a client sending it gets NO reply, and in \
             particular no err{{code:\"unknownType\"}} — the type is known, the \
             direction is not (got: {reply:?})"
        );
        assert!(
            !reply.iter().any(|m| matches!(m, Msg::Err(_))),
            "no err of any code may be emitted for a wrong-direction bm.changed"
        );
        assert!(log.calls().is_empty(), "bm.changed must reach NO executor");
    }

    /// Routing (protoVersion 1.6): unpaused bm.open/star/unstar/remove each
    /// reach the recording mock EXACTLY once with their id passed through
    /// unchanged, and produce NO reply (fire-and-forget).
    ///
    /// This is the second line of defence against a nodeId/tabId swap (the
    /// first is the ext_relay.rs frame test from 11-02): the string node ids
    /// and the integer tab ids are asserted by value on distinct Call
    /// variants, so a crossed wiring cannot pass.
    #[tokio::test]
    async fn bm_commands_route_when_unpaused() {
        let (exec, log) = MockExecutors::recording();
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);

        for msg in [
            Msg::BmOpen(BmOpenPayload { node_id: "1234".into() }),
            Msg::BmStar(BmStarPayload { tab_id: 7 }),
            Msg::BmUnstar(BmUnstarPayload { tab_id: 9 }),
            Msg::BmRemove(BmRemovePayload { node_id: "5678".into() }),
        ] {
            assert!(
                route(d(msg), &mut ctx, &exec, &auth, false).is_empty(),
                "every bm command is fire-and-forget: no reply, ever"
            );
        }
        assert_eq!(
            log.calls(),
            vec![
                Call::BmOpen("1234".into()),
                Call::BmStar(7),
                Call::BmUnstar(9),
                Call::BmRemove("5678".into()),
            ],
            "each command must record exactly one call with its id unswapped"
        );
    }

    // ── update.* routing (protoVersion 1.8, phase 12) ──────────────────

    /// Routing (protoVersion 1.8): unpaused `update.check` produces EXACTLY
    /// one `update.status` carrying everything `info()` reported, and
    /// `update.apply` produces ZERO reply frames while the executor records
    /// the target string verbatim (D-14).
    ///
    /// The `bm_commands_route_when_unpaused` shape, extended with the read
    /// half because this family — unlike `bm.*` — has one.
    #[tokio::test]
    async fn update_commands_route_when_unpaused() {
        let (base, log) = MockExecutors::recording();
        let update = Arc::new(MockUpdate::new());
        update.set_info(UpdateInfo {
            server_version: "1.5.0".into(),
            ext_connected: true,
            ext_version: Some("1.4.0".into()),
            last_update: Some(LastUpdate {
                target: "1.4.9".into(),
                ok: false,
                error: Some("installer".into()),
            }),
        });
        let exec = Executors { update: Arc::clone(&update) as Arc<dyn UpdateExecutor>, ..base };
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);

        let reply = route(d(Msg::UpdateCheck(UpdateCheckPayload {})), &mut ctx, &exec, &auth, false);
        assert_eq!(
            reply,
            vec![Msg::UpdateStatus(UpdateStatusPayload {
                server_version: "1.5.0".into(),
                ext_connected: true,
                ext_version: Some("1.4.0".into()),
                last_update: Some(LastUpdatePayload {
                    target: "1.4.9".into(),
                    ok: false,
                    error: Some("installer".into()),
                }),
            })],
            "update.check must reply EXACTLY one update.status mapping info() field-for-field"
        );

        assert!(
            route(
                d(Msg::UpdateApply(UpdateApplyPayload { target: "1.6.0".into() })),
                &mut ctx, &exec, &auth, false,
            )
            .is_empty(),
            "update.apply is fire-and-forget: no reply, ever — every outcome \
             arrives as an update.progress push"
        );
        assert_eq!(
            update.applies(),
            vec!["1.6.0".to_string()],
            "the target string must reach the executor exactly once, verbatim (D-14)"
        );
        assert!(log.calls().is_empty(), "no OTHER executor may be touched by the update family");
    }

    /// Direction rule (SPEC §7): `update.status` and `update.progress` are
    /// S→C-ONLY. A client that sends one is ignored SILENTLY — specifically
    /// NOT `err{unknownType}`, because the type IS known, only the direction
    /// is wrong. This is the `client_sent_bm_changed_ignored_without_err`
    /// contract applied to the 1.8 family.
    #[tokio::test]
    async fn client_sent_update_pushes_ignored_without_err() {
        let (base, log) = MockExecutors::recording();
        let update = Arc::new(MockUpdate::new());
        let exec = Executors { update: Arc::clone(&update) as Arc<dyn UpdateExecutor>, ..base };
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);

        for msg in [
            Msg::UpdateStatus(UpdateStatusPayload {
                server_version: "9.9.9".into(),
                ext_connected: true,
                ext_version: None,
                last_update: None,
            }),
            Msg::UpdateProgress(UpdateProgressPayload {
                stage: "installing".into(),
                pct: None,
                version: Some("9.9.9".into()),
                error: None,
            }),
        ] {
            let reply = route(d(msg), &mut ctx, &exec, &auth, false);
            assert!(
                reply.is_empty(),
                "an S→C-only update push sent BY a client gets NO reply, and in \
                 particular no err{{code:\"unknownType\"}} — the type is known, the \
                 direction is not (got: {reply:?})"
            );
            assert!(
                !reply.iter().any(|m| matches!(m, Msg::Err(_))),
                "no err of any code may be emitted for a wrong-direction update push"
            );
        }
        assert!(log.calls().is_empty(), "wrong-direction update pushes must reach NO executor");
        assert!(update.applies().is_empty(), "and must never reach the update executor either");
    }

    #[tokio::test]
    async fn paused_ping_still_ponged() {
        let (exec, log) = MockExecutors::recording();
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);
        let reply = route(d(ping(42)), &mut ctx, &exec, &auth, true);
        assert_eq!(reply, vec![Msg::Pong(PongPayload { ts: 42 })]);
        assert!(log.calls().is_empty());
    }

    #[tokio::test]
    async fn paused_binary_frames_dropped() {
        let (exec, log) = MockExecutors::recording();
        let ctx = ctx(AuthState::Authed);
        route_binary(MouseFrame::Move { dx: 1.0, dy: 2.0 }, &ctx, &exec, true);
        assert!(log.calls().is_empty());
    }

    // ── Held-input tracking (CONN-07, T-01-24) ─────────────────────────

    #[tokio::test]
    async fn drag_start_end_updates_held_and_calls_trait() {
        let (exec, log) = MockExecutors::recording();
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);

        route(
            d(Msg::Drag(DragPayload { action: "start".into(), button: "left".into() })),
            &mut ctx, &exec, &auth, false,
        );
        assert_eq!(log.calls(), vec![Call::ButtonDown(Button::Left)]);
        assert!(!ctx.held.is_empty(), "drag start must be tracked as held");

        route(
            d(Msg::Drag(DragPayload { action: "end".into(), button: "left".into() })),
            &mut ctx, &exec, &auth, false,
        );
        assert_eq!(
            log.calls(),
            vec![Call::ButtonDown(Button::Left), Call::ButtonUp(Button::Left)]
        );
        assert!(ctx.held.is_empty(), "drag end must clear the held entry");
    }

    #[tokio::test]
    async fn key_down_up_updates_held_and_calls_trait() {
        let (exec, log) = MockExecutors::recording();
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);
        let code = KeyCode("ShiftLeft".into());

        route(
            d(Msg::Key(KeyPayload { code: "ShiftLeft".into(), action: "down".into(), mods: vec![] })),
            &mut ctx, &exec, &auth, false,
        );
        assert_eq!(log.calls(), vec![Call::KeyDown(code.clone())]);
        assert!(!ctx.held.is_empty(), "key down must be tracked as held");

        route(
            d(Msg::Key(KeyPayload { code: "ShiftLeft".into(), action: "up".into(), mods: vec![] })),
            &mut ctx, &exec, &auth, false,
        );
        assert_eq!(log.calls(), vec![Call::KeyDown(code.clone()), Call::KeyUp(code)]);
        assert!(ctx.held.is_empty(), "key up must clear the held entry");
    }

    #[tokio::test]
    async fn release_all_emits_up_for_everything_held_then_is_empty() {
        let (exec, log) = MockExecutors::recording();
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);

        route(
            d(Msg::Drag(DragPayload { action: "start".into(), button: "left".into() })),
            &mut ctx, &exec, &auth, false,
        );
        route(
            d(Msg::Key(KeyPayload { code: "KeyW".into(), action: "down".into(), mods: vec![] })),
            &mut ctx, &exec, &auth, false,
        );
        assert!(!ctx.held.is_empty());

        // The CONN-07 mechanism Plan 06's teardown will invoke.
        ctx.held.release_all(&*exec.mouse_keys);

        let calls = log.calls();
        let released: Vec<_> = calls[2..].to_vec();
        assert_eq!(released.len(), 2, "exactly one up per held input, got: {released:?}");
        assert!(released.contains(&Call::ButtonUp(Button::Left)));
        assert!(released.contains(&Call::KeyUp(KeyCode("KeyW".into()))));
        assert!(ctx.held.is_empty(), "release_all must leave nothing held");

        // Idempotent: a second release emits nothing.
        ctx.held.release_all(&*exec.mouse_keys);
        assert_eq!(log.calls().len(), 4, "second release_all must emit nothing");
    }

    #[tokio::test]
    async fn key_tap_does_not_touch_held_state() {
        let (exec, log) = MockExecutors::recording();
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);
        route(
            d(Msg::Key(KeyPayload {
                code: "KeyC".into(),
                action: "tap".into(),
                mods: vec!["ctrl".into()],
            })),
            &mut ctx, &exec, &auth, false,
        );
        assert_eq!(
            log.calls(),
            vec![Call::KeyTap(KeyCode("KeyC".into()), vec![Modifier::Ctrl])]
        );
        assert!(ctx.held.is_empty(), "tap is not held input");
    }

    // ── Unknown type post-auth (D-07, T-01-25) ─────────────────────────

    #[tokio::test]
    async fn unknown_type_post_auth_errs_and_session_continues() {
        let (exec, log) = MockExecutors::recording();
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);

        let reply = route(
            d(Msg::Unknown { t: "gesture.swipe".into() }),
            &mut ctx, &exec, &auth, false,
        );
        let err = assert_single_err(&reply, "unknownType");
        assert!(
            err.msg.contains("gesture.swipe"),
            "err.msg must name the offending type, got: {}",
            err.msg
        );
        assert!(log.calls().is_empty());

        // Session continues: the next message still routes normally.
        route(d(click_left()), &mut ctx, &exec, &auth, false);
        assert_eq!(log.calls(), vec![Call::Click(Button::Left)]);
    }

    // ── text diff-ops + bs cap (T-01-22) ───────────────────────────────

    #[tokio::test]
    async fn text_bs_over_cap_rejected_without_execution() {
        let (exec, log) = MockExecutors::recording();
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);
        let reply = route(
            d(Msg::Text(TextPayload { bs: 10001, ins: "x".into() })),
            &mut ctx, &exec, &auth, false,
        );
        assert_single_err(&reply, "bsTooLarge");
        assert!(log.calls().is_empty(), "rejected text must reach NO executor");
    }

    #[tokio::test]
    async fn text_diff_ops_backspace_then_insert_in_order() {
        let (exec, log) = MockExecutors::recording();
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);
        let reply = route(
            d(Msg::Text(TextPayload { bs: 2, ins: "ab".into() })),
            &mut ctx, &exec, &auth, false,
        );
        assert!(reply.is_empty());
        assert_eq!(log.calls(), vec![Call::Backspace(2), Call::TypeText("ab".into())]);
    }

    // ── power → confirm double-gate (T-01-23) ──────────────────────────

    #[tokio::test]
    async fn power_alone_never_calls_power_trait() {
        let (exec, log) = MockExecutors::recording();
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);
        let reply = route(
            d(Msg::Power(PowerPayload { action: "restart".into() })),
            &mut ctx, &exec, &auth, false,
        );
        assert!(reply.is_empty());
        assert!(log.calls().is_empty(), "power without confirm must not execute");
    }

    #[tokio::test(start_paused = true)]
    async fn power_then_matching_confirm_within_window_executes() {
        let (exec, log) = MockExecutors::recording();
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);
        route(
            d(Msg::Power(PowerPayload { action: "restart".into() })),
            &mut ctx, &exec, &auth, false,
        );
        advance(Duration::from_secs(9)).await;
        let reply = route(
            d(Msg::Confirm(ConfirmPayload { action: "restart".into() })),
            &mut ctx, &exec, &auth, false,
        );
        assert!(reply.is_empty());
        assert_eq!(log.calls(), vec![Call::PowerAction("restart".into())]);
    }

    #[tokio::test]
    async fn confirm_with_no_pending_errs() {
        let (exec, log) = MockExecutors::recording();
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);
        let reply = route(
            d(Msg::Confirm(ConfirmPayload { action: "restart".into() })),
            &mut ctx, &exec, &auth, false,
        );
        assert_single_err(&reply, "noPendingAction");
        assert!(log.calls().is_empty());
    }

    #[tokio::test]
    async fn confirm_with_mismatched_action_errs() {
        let (exec, log) = MockExecutors::recording();
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);
        route(
            d(Msg::Power(PowerPayload { action: "restart".into() })),
            &mut ctx, &exec, &auth, false,
        );
        let reply = route(
            d(Msg::Confirm(ConfirmPayload { action: "shutdown".into() })),
            &mut ctx, &exec, &auth, false,
        );
        assert_single_err(&reply, "noPendingAction");
        assert!(log.calls().is_empty(), "mismatched confirm must not execute");
    }

    #[tokio::test(start_paused = true)]
    async fn confirm_after_window_expiry_errs() {
        let (exec, log) = MockExecutors::recording();
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);
        route(
            d(Msg::Power(PowerPayload { action: "restart".into() })),
            &mut ctx, &exec, &auth, false,
        );
        advance(Duration::from_secs(11)).await;
        let reply = route(
            d(Msg::Confirm(ConfirmPayload { action: "restart".into() })),
            &mut ctx, &exec, &auth, false,
        );
        assert_single_err(&reply, "noPendingAction");
        assert!(log.calls().is_empty(), "expired confirm must not execute");
    }

    // ── family routing to traits ───────────────────────────────────────

    #[tokio::test]
    async fn click_routes_to_mouse_keys() {
        let (exec, log) = MockExecutors::recording();
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);
        assert!(route(d(click_left()), &mut ctx, &exec, &auth, false).is_empty());
        assert_eq!(log.calls(), vec![Call::Click(Button::Left)]);
    }

    #[tokio::test]
    async fn media_routes_to_media_trait() {
        let (exec, log) = MockExecutors::recording();
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);
        route(
            d(Msg::Media(MediaPayload { action: "playpause".into(), value: None })),
            &mut ctx, &exec, &auth, false,
        );
        route(
            d(Msg::Media(MediaPayload { action: "setvol".into(), value: Some(55) })),
            &mut ctx, &exec, &auth, false,
        );
        assert_eq!(
            log.calls(),
            vec![Call::MediaAction("playpause".into()), Call::SetVolume(55)]
        );
    }

    #[tokio::test]
    async fn apps_family_routes_and_list_replies_mock_windows() {
        let (exec, log) = MockExecutors::recording();
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);

        let reply = route(
            d(Msg::AppsList(AppsListPayload { windows: None })),
            &mut ctx, &exec, &auth, false,
        );
        match &reply[..] {
            [Msg::AppsList(AppsListPayload { windows: Some(w) })] => {
                assert_eq!(w.len(), 2, "reply must carry the mock's fixed windows");
                assert_eq!(w[0].id, 1);
                assert_eq!(w[1].id, 2);
            }
            other => panic!("expected apps.list reply with windows, got: {other:?}"),
        }

        // Success path (MockApps returns true): each action stays silent.
        assert!(
            route(d(Msg::AppsLaunch(AppsLaunchPayload { path: "C:\\x.exe".into() })), &mut ctx, &exec, &auth, false).is_empty(),
            "successful launch must produce no reply"
        );
        assert!(
            route(d(Msg::AppsFocus(AppsFocusPayload { id: 2 })), &mut ctx, &exec, &auth, false).is_empty(),
            "successful focus must produce no reply"
        );
        assert!(
            route(d(Msg::AppsClose(AppsClosePayload { id: 2 })), &mut ctx, &exec, &auth, false).is_empty(),
            "successful close must produce no reply"
        );
        assert_eq!(
            log.calls(),
            vec![
                Call::AppsLaunch("C:\\x.exe".into()),
                Call::AppsFocus(2),
                Call::AppsClose(2),
            ]
        );
    }

    /// APPS-01 (SC1 toast path): a failing apps executor makes focus/close
    /// reply err{windowGone} and launch reply err{launchFailed} — exactly one
    /// err each. The err.msg must never embed the id or the path (T-06-12).
    #[tokio::test]
    async fn apps_failed_actions_emit_err_codes() {
        let (base, _log) = MockExecutors::recording();
        let exec = Executors { apps: Arc::new(FailingApps), ..base };
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);

        let focus = route(
            d(Msg::AppsFocus(AppsFocusPayload { id: 42 })),
            &mut ctx, &exec, &auth, false,
        );
        let p = assert_single_err(&focus, "windowGone");
        assert!(!p.msg.contains("42"), "err.msg must not embed the HWND id: {}", p.msg);

        let close = route(
            d(Msg::AppsClose(AppsClosePayload { id: 99 })),
            &mut ctx, &exec, &auth, false,
        );
        let p = assert_single_err(&close, "windowGone");
        assert!(!p.msg.contains("99"), "err.msg must not embed the HWND id: {}", p.msg);

        let launch = route(
            d(Msg::AppsLaunch(AppsLaunchPayload { path: "C:\\secret\\app.exe".into() })),
            &mut ctx, &exec, &auth, false,
        );
        let p = assert_single_err(&launch, "launchFailed");
        assert!(
            !p.msg.contains("secret") && !p.msg.contains(".exe"),
            "err.msg must not embed the exe path: {}",
            p.msg
        );
    }

    #[tokio::test]
    async fn clip_family_routes_and_get_replies_clip_set() {
        let (exec, log) = MockExecutors::recording();
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);

        let reply = route(d(Msg::ClipGet(ClipGetPayload {})), &mut ctx, &exec, &auth, false);
        assert_eq!(
            reply,
            vec![Msg::ClipSet(ClipSetPayload { text: "mock-clip".into() })],
            "clip.get must reply clip.set with the mock's fixed clipboard"
        );

        route(d(Msg::ClipSet(ClipSetPayload { text: "hi".into() })), &mut ctx, &exec, &auth, false);
        assert_eq!(log.calls(), vec![Call::ClipSet("hi".into())]);
    }

    #[tokio::test]
    async fn browser_macro_table_maps_every_action() {
        let (exec, log) = MockExecutors::recording();
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);
        let expected = [
            ("back", "BrowserBack", vec![]),
            ("forward", "BrowserForward", vec![]),
            ("newtab", "T", vec![Modifier::Ctrl]),
            ("closetab", "W", vec![Modifier::Ctrl]),
            ("refresh", "F5", vec![]),
            ("zoomin", "Plus", vec![Modifier::Ctrl]),
            ("zoomout", "Minus", vec![Modifier::Ctrl]),
        ];
        for (action, _, _) in &expected {
            route(
                d(Msg::Browser(BrowserPayload { action: (*action).into() })),
                &mut ctx, &exec, &auth, false,
            );
        }
        let want: Vec<Call> = expected
            .iter()
            .map(|(_, code, mods)| Call::KeyTap(KeyCode((*code).into()), mods.clone()))
            .collect();
        assert_eq!(log.calls(), want);
    }

    #[tokio::test]
    async fn present_macro_table_maps_every_action() {
        let (exec, log) = MockExecutors::recording();
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);
        let expected = [
            ("next", "Right"),
            ("prev", "Left"),
            ("start", "F5"),
            ("end", "Esc"),
            ("blank", "B"),
        ];
        for (action, _) in &expected {
            route(
                d(Msg::Present(PresentPayload { action: (*action).into() })),
                &mut ctx, &exec, &auth, false,
            );
        }
        let want: Vec<Call> = expected
            .iter()
            .map(|(_, code)| Call::KeyTap(KeyCode((*code).into()), vec![]))
            .collect();
        assert_eq!(log.calls(), want);
    }

    #[tokio::test]
    async fn ping_pongs_post_auth() {
        let (exec, log) = MockExecutors::recording();
        let auth = auth();
        let mut ctx = ctx(AuthState::Authed);
        let reply = route(d(ping(1783436504123)), &mut ctx, &exec, &auth, false);
        assert_eq!(reply, vec![Msg::Pong(PongPayload { ts: 1783436504123 })]);
        assert!(log.calls().is_empty());
    }

    #[tokio::test]
    async fn binary_frames_route_when_authed_and_unpaused() {
        let (exec, log) = MockExecutors::recording();
        let ctx = ctx(AuthState::Authed);
        route_binary(MouseFrame::Move { dx: 1.5, dy: -2.0 }, &ctx, &exec, false);
        route_binary(MouseFrame::Scroll { dx: 0.0, dy: 3.0 }, &ctx, &exec, false);
        route_binary(MouseFrame::Zoom { dx: 0.0, dy: 2.0 }, &ctx, &exec, false);
        assert_eq!(
            log.calls(),
            vec![
                Call::MoveRel(1.5, -2.0),
                Call::Scroll(0.0, 3.0),
                Call::Zoom(0.0, 2.0)
            ]
        );
    }

    #[tokio::test]
    async fn paused_zoom_frames_dropped() {
        // Zoom is executor-bound like every other binary frame (SPEC §11) —
        // the pause gate in route_binary covers it with no extra check.
        let (exec, log) = MockExecutors::recording();
        let ctx = ctx(AuthState::Authed);
        route_binary(MouseFrame::Zoom { dx: 0.0, dy: 2.0 }, &ctx, &exec, true);
        assert!(log.calls().is_empty());
    }
}
