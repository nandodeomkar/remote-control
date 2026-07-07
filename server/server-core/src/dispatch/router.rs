//! Family routing behind the auth and pause gates (SPEC §6, §7, §10, §11).

use std::sync::Mutex;
use std::time::Instant;

use crate::auth::AuthManager;
use crate::codec::binary::MouseFrame;
use crate::codec::json::{Decoded, Msg};
use crate::dispatch::AuthState;
use crate::dispatch::held::HeldInput;
use crate::executors::Executors;

/// Maximum `text.bs` value; larger requests are rejected with
/// `err{code:"bsTooLarge"}` and not executed (SPEC §8).
pub const MAX_BS: u64 = 10000;

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
    auth: &Mutex<AuthManager>,
    paused: bool,
) -> Vec<Msg> {
    todo!("implemented in plan 01-05 (dispatch wave)")
}

/// Route one decoded binary mouse frame (fire-and-forget hot path).
///
/// Dropped silently unless `ctx.auth_state` is [`AuthState::Authed`] and not
/// `paused` (SPEC §6, §11). Never replies.
pub fn route_binary(frame: MouseFrame, ctx: &SessionCtx, exec: &Executors, paused: bool) {
    todo!("implemented in plan 01-05 (dispatch wave)")
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
