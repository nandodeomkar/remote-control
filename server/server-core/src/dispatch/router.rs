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
    AppsListPayload, ClipSetPayload, Decoded, ErrPayload, Msg, PongPayload,
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
    // queries `apps.list`/`clip.get`, which SPEC §11 does not list) keep
    // working — pause never breaks liveness probing.
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
        Msg::AppsLaunch(p) => {
            exec.apps.launch(&p.path);
            Vec::new()
        }
        Msg::AppsFocus(p) => {
            exec.apps.focus(p.id);
            Vec::new()
        }
        Msg::AppsClose(p) => {
            exec.apps.close(p.id);
            Vec::new()
        }

        // ── clipboard ──────────────────────────────────────────────────
        Msg::ClipSet(p) => {
            exec.clipboard.set(&p.text);
            Vec::new()
        }
        Msg::ClipGet(_) => vec![Msg::ClipSet(ClipSetPayload {
            text: exec.clipboard.get(),
        })],

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

        // S→C-only types arriving FROM a client are known-but-invalid
        // direction: ignored silently (no unknownType — the type IS known;
        // no routing fallthrough — nothing executes).
        Msg::PairOk(_)
        | Msg::Challenge(_)
        | Msg::AuthOk(_)
        | Msg::AuthFail(_)
        | Msg::AppsChanged(_)
        | Msg::ClipChanged(_)
        | Msg::Pong(_)
        | Msg::Err(_) => Vec::new(),
    }
}

/// SPEC §11's pause drop list: every executor-bound family. `ping`/`pong`
/// and the read-only queries (`apps.list`, `clip.get`) are exempt.
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
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tokio::time::advance;

    use super::*;
    use crate::codec::json::{
        AppsClosePayload, AppsFocusPayload, AppsLaunchPayload, AppsListPayload, BrowserPayload,
        ClickPayload, ClipGetPayload, ClipSetPayload, ConfirmPayload, DragPayload, ErrPayload,
        KeyPayload, MediaPayload, PingPayload, PongPayload, PowerPayload, PresentPayload,
        TextPayload,
    };
    use crate::executors::mock::{Call, MockExecutors};
    use crate::executors::{Button, KeyCode, Modifier};

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
        let (exec, log) = MockExecutors::recording();
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
        ] {
            let reply = route(d(msg), &mut ctx, &exec, &auth, true);
            assert!(reply.is_empty(), "paused executor-bound traffic must produce NO reply");
        }
        assert!(log.calls().is_empty(), "paused traffic must reach NO executor");
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

        route(d(Msg::AppsLaunch(AppsLaunchPayload { path: "C:\\x.exe".into() })), &mut ctx, &exec, &auth, false);
        route(d(Msg::AppsFocus(AppsFocusPayload { id: 2 })), &mut ctx, &exec, &auth, false);
        route(d(Msg::AppsClose(AppsClosePayload { id: 2 })), &mut ctx, &exec, &auth, false);
        assert_eq!(
            log.calls(),
            vec![
                Call::AppsLaunch("C:\\x.exe".into()),
                Call::AppsFocus(2),
                Call::AppsClose(2),
            ]
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
        assert_eq!(
            log.calls(),
            vec![Call::MoveRel(1.5, -2.0), Call::Scroll(0.0, 3.0)]
        );
    }
}
