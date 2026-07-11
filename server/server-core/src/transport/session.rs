//! Per-connection session task internals: read loop → codec →
//! `dispatch::router` behind the auth/pause gates, write half fed by an mpsc
//! queue, and the UNSKIPPABLE post-loop cleanup that releases held input
//! (CONN-07 — structured so cleanup runs after the loop exits on clean
//! close, socket error, abort, AND liveness-deadline expiry — the half-open
//! TCP leg after an abrupt WiFi loss, where no FIN/RST ever arrives).
//!
//! The handshake FSM (AwaitingHello → AwaitingAuth → Authed, SPEC §3) is
//! owned HERE, not in dispatch: `hello`/`pin`/`auth` never reach
//! [`router::route`]. Not part of the public API — everything external goes
//! through [`super::run`].
//!
//! No logging anywhere in this module (threat T-01-31): `pin` digits, `auth`
//! macs, tokens, and `text` payloads must never appear in any log sink.

use std::net::IpAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, watch};
// tokio's Instant (not std's) so the paused-clock regression test
// (`tokio::time::pause` + auto-advance) can drive the liveness deadline
// deterministically. Outside a test runtime it is std's Instant.
use tokio::time::{Instant, sleep_until};
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::Message;

use crate::auth::AuthManager;
use crate::auth::pin::PinOutcome;
use super::{ClipState, VolumeState};
use crate::codec::json::{
    AppsChangedPayload, AuthFailPayload, AuthOkPayload, ChallengePayload, ClipChangedPayload,
    ErrPayload, Msg, PairOkPayload, VolChangedPayload,
};
use crate::codec::{binary, json};
use crate::dispatch::AuthState;
use crate::dispatch::held::HeldInput;
use crate::dispatch::router::{self, SessionCtx};
use crate::executors::{Executors, WindowInfo};

/// The server's protocol version (SPEC §2). Only the MAJOR component is
/// compared against the client's `hello.protoVersion`. `pub` (re-exported
/// via [`super`]) so the beacon's `proto` field AND tests asserting "the
/// current server version" reference it instead of duplicating the literal.
/// 1.1 adds the additive `vol.changed` S→C push (MED-02, D-03) — minor
/// bump: 1.0 clients are still accepted (§2). 1.2 adds the additive
/// `WindowInfo.icon`/`.path` fields + the `apps.changed` S→C push (APPS-02,
/// APPS-03) — still a minor bump, so 1.0/1.1 clients remain accepted (§2).
pub const SERVER_PROTO_VERSION: &str = "1.2";
const SERVER_PROTO_MAJOR: u64 = 1;

/// POST-auth liveness deadline: an Authed session receiving NO inbound
/// frames for this long breaks its read loop so the CONN-07 cleanup
/// releases held input.
///
/// Rationale: the client emits protocol pings every ~250ms under move load
/// and ~2s idle (latency_probe.dart `pingIntervalMillis` /
/// `idlePingIntervalMillis`), so 10s is ≥ 5× the slowest healthy inbound
/// cadence — a live client can never trip this. Without it, a half-open TCP
/// connection after an abrupt WiFi kill (no FIN, no RST) keeps
/// `stream.next()` pending for OS-timeout minutes while held input stays
/// stuck (04-UAT Test 5, threat class T-04-04). Private on purpose —
/// nothing else needs it; the integration test hard-codes a longer wait
/// and names the coupling.
const LIVENESS_TIMEOUT: Duration = Duration::from_secs(10);

/// PRE-auth liveness deadline (review CR-01): before `Authed`, the client
/// sends NOTHING while the user reads the PIN off the PC toast and types 6
/// digits — protocol pings only start post-auth — so pre-auth silence is
/// the NORMAL pairing shape, routinely >10s. The auth PIN window budgets
/// 60s ([`crate::auth::pin::PIN_TTL_SECS`]) for exactly this; 90s = that
/// window + margin, so the deadline can never race a still-valid PIN.
/// Held input only exists post-auth, so the UAT Test 5 contract (10s)
/// loses nothing here; a silent pre-hello socket squatter still dies in
/// 90s instead of holding a session task forever (T-04-10-02, relaxed).
const PRE_AUTH_LIVENESS_TIMEOUT: Duration = Duration::from_secs(90);

/// Run one connection to completion: write task + read loop + handshake FSM
/// + unconditional held-input cleanup (CONN-07).
pub(super) async fn run_session(
    ws: WebSocketStream<TcpStream>,
    peer_ip: IpAddr,
    executors: Executors,
    auth: Arc<Mutex<AuthManager>>,
    mut pause: watch::Receiver<bool>,
    mut volume: watch::Receiver<VolumeState>,
    mut apps: watch::Receiver<Vec<WindowInfo>>,
    mut clip: watch::Receiver<ClipState>,
) {
    let (mut sink, mut stream) = ws.split();

    // Write task: the read loop never touches the sink directly — replies
    // are queued on this channel and written (in order) by a dedicated task.
    let (tx, mut rx) = mpsc::channel::<Message>(64);
    let write_task = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if sink.send(msg).await.is_err() {
                break;
            }
        }
    });

    let mut ctx = SessionCtx {
        auth_state: AuthState::AwaitingHello,
        held: HeldInput::default(),
        pending_power: None,
    };
    // The challenge nonce issued to THIS connection (SPEC §3): fresh per
    // connection, consumed by the `auth` verification path.
    let mut session_nonce: Option<[u8; 32]> = None;
    // Errored binary frames are dropped and counted, never routed and never
    // fatal (SPEC §9). Diagnostics-only until tracing lands in Phase 2.
    let mut binary_decode_errors: u64 = 0;
    // The pause watch sender may drop before the session ends; disable the
    // branch then (`changed()` would return Err forever and busy-loop).
    let mut pause_alive = true;
    // Same discipline for the volume watch (MED-02): producer dropped →
    // disable the branch, never busy-loop.
    let mut volume_alive = true;
    // Same discipline for the apps watch (APPS-03): producer dropped →
    // disable the branch, never busy-loop.
    let mut apps_alive = true;
    // Same discipline for the clip watch (CLIP-03): producer dropped →
    // disable the branch, never busy-loop.
    let mut clip_alive = true;
    // Last time ANY inbound bytes arrived from the peer; drives the
    // liveness deadline branch below.
    let mut last_inbound = Instant::now();

    'read: loop {
        tokio::select! {
            // Liveness deadline (04-UAT Test 5): no inbound frames for the
            // deadline means the peer is gone (half-open TCP after an
            // abrupt WiFi kill never yields None/Err from stream.next()).
            // Breaking 'read lands on the EXISTING straight-line CONN-07
            // cleanup below the loop — no new cleanup code, that is the
            // entire point of the straight-line structure. Constructing the
            // sleep_until future fresh each iteration is correct: select!
            // re-creates non-pinned futures per pass, and the loop rate is
            // bounded by the inbound frame rate. The deadline scales by
            // auth state (review CR-01): pre-auth silence is the normal
            // pairing shape (the user typing the PIN, no client pings yet),
            // so only Authed sessions get the tight 10s held-input contract.
            () = sleep_until(last_inbound + if ctx.auth_state == AuthState::Authed {
                LIVENESS_TIMEOUT
            } else {
                PRE_AUTH_LIVENESS_TIMEOUT
            }) => break 'read,
            changed = pause.changed(), if pause_alive => {
                match changed {
                    Ok(()) => {
                        // Pause activation IMMEDIATELY releases held input
                        // (SPEC §11, RESEARCH pitfall 12).
                        if *pause.borrow() {
                            ctx.held.release_all(&*executors.mouse_keys);
                        }
                    }
                    Err(_) => pause_alive = false,
                }
            }
            // MED-02 live push (D-03), authed-gated: the volume watch fires
            // for EVERY session, but only Authed ones may see host state —
            // the guard is what stands between host state and an unauthed
            // socket (threat T-05-05 / RESEARCH Pitfall 8). watch is
            // latest-value-only (no backlog to flood, T-05-06); frames ride
            // the same bounded write queue as replies.
            changed = volume.changed(), if volume_alive && ctx.auth_state == AuthState::Authed => {
                match changed {
                    Ok(()) => {
                        // borrow_and_update clears the changed flag so this
                        // branch and the after-auth snapshot below never
                        // double-fire on the same state.
                        let state = *volume.borrow_and_update();
                        if tx.send(vol_changed_frame(state)).await.is_err() {
                            break 'read; // write task gone → session over
                        }
                    }
                    Err(_) => volume_alive = false,
                }
            }
            // APPS-03 live push, authed-gated: identical privacy backstop to
            // the volume branch (threat T-06-01 / RESEARCH Pitfall 8) — the
            // window list must never cross to an unauthed socket. watch is
            // latest-value-only (no backlog flood). Unlike volume there is NO
            // after-auth snapshot: the client pulls the current list via
            // `apps.list` on the Apps screen, so this branch is the ONLY apps
            // push site.
            changed = apps.changed(), if apps_alive && ctx.auth_state == AuthState::Authed => {
                match changed {
                    Ok(()) => {
                        // Vec<WindowInfo> is not Copy: clone the borrowed
                        // snapshot. borrow_and_update clears the changed flag.
                        let windows = apps.borrow_and_update().clone();
                        if tx.send(apps_changed_frame(windows)).await.is_err() {
                            break 'read; // write task gone → session over
                        }
                    }
                    Err(_) => apps_alive = false,
                }
            }
            // CLIP-03 live push, authed-gated: identical privacy backstop to
            // the volume/apps branches (threat T-06-05 / RESEARCH Pitfall 8) —
            // the PC clipboard must never cross to an unauthed socket. watch is
            // latest-value-only (no backlog flood). Like apps — and UNLIKE
            // volume — there is NO after-auth snapshot: dumping the PC
            // clipboard to a connecting phone is a privacy leak (Pitfall 8), so
            // this branch is the ONLY clip push site. The client pulls the
            // current value via `clip.get`. The producer already skips
            // sensitive/oversized/echo clips before they reach this watch.
            changed = clip.changed(), if clip_alive && ctx.auth_state == AuthState::Authed => {
                match changed {
                    Ok(()) => {
                        // ClipState owns a String (not Copy): clone the
                        // borrowed snapshot. borrow_and_update clears the flag.
                        let text = clip.borrow_and_update().text.clone();
                        if tx.send(clip_changed_frame(text)).await.is_err() {
                            break 'read; // write task gone → session over
                        }
                    }
                    Err(_) => clip_alive = false,
                }
            }
            incoming = stream.next() => {
                let msg = match incoming {
                    // Clean close: the client finished the WS close
                    // handshake (or dropped the socket).
                    None => break 'read,
                    // Protocol/socket error — including a frame exceeding
                    // the 64 KB caps (SPEC §13): terminate the session.
                    Some(Err(_)) => break 'read,
                    Some(Ok(m)) => m,
                };
                // ANY inbound bytes prove the peer is alive — refreshed
                // BEFORE the frame-type match so Text, Binary, and WS
                // control frames (Ping/Pong in the `_` arm) all count.
                // The pause branch above deliberately does NOT refresh:
                // a server-side pause toggle says nothing about the
                // phone's reachability.
                last_inbound = Instant::now();
                match msg {
                    Message::Text(text) => {
                        // Captured BEFORE handle_text so the D-03 snapshot
                        // below fires exactly at the two Authed transitions
                        // (pairOk and authOk) — never on later frames.
                        let was_authed = ctx.auth_state == AuthState::Authed;
                        let (replies, close_after) = handle_text(
                            text.as_str(),
                            &mut ctx,
                            &mut session_nonce,
                            peer_ip,
                            &executors,
                            &auth,
                            &pause,
                        );
                        for reply in replies {
                            let frame = Message::text(json::encode_msg(&reply, None));
                            if tx.send(frame).await.is_err() {
                                break 'read; // write task gone → session over
                            }
                        }
                        if close_after {
                            // versionMismatch (D-06): err queued above is
                            // written first (mpsc preserves order), then the
                            // close frame, then the session ends.
                            let _ = tx.send(Message::Close(None)).await;
                            break 'read;
                        }
                        // D-03 "right after auth": exactly one vol.changed
                        // snapshot, queued AFTER the pairOk/authOk reply
                        // (mpsc preserves order). borrow_and_update here AND
                        // in the branch above prevents an immediate
                        // duplicate branch-fire on a pre-auth state change.
                        if !was_authed && ctx.auth_state == AuthState::Authed {
                            let state = *volume.borrow_and_update();
                            if tx.send(vol_changed_frame(state)).await.is_err() {
                                break 'read;
                            }
                        }
                    }
                    Message::Binary(bytes) => {
                        // Pre-auth binary frames are silently dropped
                        // BEFORE decode (SPEC §6 — no probing oracle).
                        if ctx.auth_state == AuthState::Authed {
                            match binary::decode(bytes.as_ref()) {
                                Ok(frame) => router::route_binary(
                                    frame,
                                    &ctx,
                                    &executors,
                                    *pause.borrow(),
                                ),
                                // Dropped and counted, never fatal (SPEC §9).
                                Err(_) => binary_decode_errors += 1,
                            }
                        }
                    }
                    // WS control frames: tungstenite answers Ping itself and
                    // acknowledges Close internally (next() then yields
                    // None). Nothing to do here — protocol-level `ping` is a
                    // JSON text message, not a WS control frame.
                    _ => {}
                }
            }
        }
    }

    // ── CONN-07: UNSKIPPABLE cleanup ────────────────────────────────────
    // Straight-line code after the read loop — reached on clean close,
    // socket error, oversize-frame error, and version-reject alike. No
    // phantom held input survives this session. (release_all is drain-based
    // and idempotent: if the pause branch already released, this is a no-op.)
    ctx.held.release_all(&*executors.mouse_keys);

    // Closing the channel lets the write task drain anything still queued
    // (e.g. the versionMismatch err + close frames), then exit.
    drop(tx);
    let _ = write_task.await;
    let _ = binary_decode_errors; // surfaced via tracing in Phase 2
}

/// Handle one decoded-or-not text frame through the handshake FSM.
///
/// Returns the replies to queue plus whether the session must close after
/// sending them (true only for the D-06 version reject).
fn handle_text(
    text: &str,
    ctx: &mut SessionCtx,
    session_nonce: &mut Option<[u8; 32]>,
    peer_ip: IpAddr,
    executors: &Executors,
    auth: &Mutex<AuthManager>,
    pause: &watch::Receiver<bool>,
) -> (Vec<Msg>, bool) {
    let decoded = match json::decode_text(text) {
        Ok(decoded) => decoded,
        Err(e) => {
            // Pre-auth: silent drop (SPEC §6 — no probing oracle for
            // unauthenticated peers, malformed frames included).
            if ctx.auth_state != AuthState::Authed {
                return (Vec::new(), false);
            }
            // Post-auth decode error: the SPEC §7 err table defines no
            // decode-failure code ("badMessage" does not exist), so by
            // documented choice this replies with the closest existing
            // code — `internal` ("server-side failure executing a
            // request") — and KEEPS the connection. A malformed frame is
            // thus visible to an authed client without inventing an
            // off-spec code.
            return (
                vec![Msg::Err(ErrPayload {
                    code: "internal".to_string(),
                    msg: format!("failed to decode message: {e}"),
                    server_version: None,
                    client_version: None,
                })],
                false,
            );
        }
    };

    match ctx.auth_state {
        // ── AwaitingHello: ONLY hello is processed (SPEC §3, §6) ────────
        AuthState::AwaitingHello => match decoded.msg {
            Msg::Hello(p) => {
                let major = p
                    .proto_version
                    .split('.')
                    .next()
                    .and_then(|m| m.parse::<u64>().ok());
                if major == Some(SERVER_PROTO_MAJOR) {
                    // Minor mismatch is accepted (SPEC §2).
                    let nonce = auth.lock().expect("auth mutex poisoned").issue_challenge();
                    *session_nonce = Some(nonce);
                    ctx.auth_state = AuthState::AwaitingAuth;
                    (
                        vec![Msg::Challenge(ChallengePayload { nonce: hex::encode(nonce) })],
                        false,
                    )
                } else {
                    // D-06: major mismatch (or unparseable version) → err
                    // carrying BOTH versions, then close.
                    (
                        vec![Msg::Err(ErrPayload {
                            code: "versionMismatch".to_string(),
                            msg: format!(
                                "server speaks protoVersion {SERVER_PROTO_VERSION}; \
                                 client sent {}",
                                p.proto_version
                            ),
                            server_version: Some(SERVER_PROTO_VERSION.to_string()),
                            client_version: Some(p.proto_version),
                        })],
                        true,
                    )
                }
            }
            // Everything else pre-hello — including protocol `ping` — is
            // silently dropped (SPEC §6).
            _ => (Vec::new(), false),
        },

        // ── AwaitingAuth: ONLY pin / auth are processed (SPEC §3) ───────
        AuthState::AwaitingAuth => match decoded.msg {
            Msg::Pin(p) => {
                let outcome = auth
                    .lock()
                    .expect("auth mutex poisoned")
                    .verify_pin(&p.pin, peer_ip);
                match outcome {
                    PinOutcome::Ok => {
                        let token =
                            auth.lock().expect("auth mutex poisoned").complete_pairing();
                        ctx.auth_state = AuthState::Authed;
                        (vec![Msg::PairOk(PairOkPayload { token })], false)
                    }
                    PinOutcome::WrongPin { attempts_remaining } => {
                        (vec![auth_fail("pinInvalid", Some(attempts_remaining), None)], false)
                    }
                    PinOutcome::Expired => (vec![auth_fail("pinExpired", None, None)], false),
                    PinOutcome::LockedOut { retry_after_secs } => {
                        (vec![auth_fail("lockedOut", None, Some(retry_after_secs))], false)
                    }
                    PinOutcome::NoPairing => (vec![auth_fail("noPairing", None, None)], false),
                }
            }
            Msg::Auth(p) => {
                // The mac must be bound to THIS connection's nonce; a
                // session that never got a challenge verifies nothing.
                let verified = session_nonce.is_some_and(|nonce| {
                    auth.lock()
                        .expect("auth mutex poisoned")
                        .verify_auth(&nonce, &p.mac)
                });
                if verified {
                    ctx.auth_state = AuthState::Authed;
                    (vec![Msg::AuthOk(AuthOkPayload {})], false)
                } else {
                    (vec![auth_fail("badMac", None, None)], false)
                }
            }
            // Everything else pre-auth is silently dropped (SPEC §6).
            _ => (Vec::new(), false),
        },

        // ── Authed: full registry via the dispatch gates ────────────────
        AuthState::Authed => match &decoded.msg {
            // Handshake replays post-auth are ignored: the FSM owns these
            // types and they must never reach route() (its debug_assert).
            Msg::Hello(_) | Msg::Pin(_) | Msg::Auth(_) => (Vec::new(), false),
            _ => (
                router::route(decoded, ctx, executors, auth, *pause.borrow()),
                false,
            ),
        },
    }
}

/// Encode one `vol.changed` push frame (S→C, protoVersion 1.1) from the
/// core-owned [`VolumeState`] — used by both the live watch branch and the
/// D-03 after-auth snapshot so the wire shape can never diverge.
fn vol_changed_frame(state: VolumeState) -> Message {
    Message::text(json::encode_msg(
        &Msg::VolChanged(VolChangedPayload {
            value: u64::from(state.value),
            muted: state.muted,
        }),
        None,
    ))
}

/// Encode one `apps.changed` push frame (S→C, protoVersion 1.2, APPS-03)
/// from the core-owned window list. The sole apps-push encoder — no
/// after-auth snapshot analog (the client pulls via `apps.list`).
fn apps_changed_frame(windows: Vec<WindowInfo>) -> Message {
    Message::text(json::encode_msg(
        &Msg::AppsChanged(AppsChangedPayload { windows }),
        None,
    ))
}

/// Encode one `clip.changed` push frame (S→C, protoVersion 1.2, CLIP-03)
/// from the core-owned clipboard text. The sole clip-push encoder — no
/// after-auth snapshot analog (the client pulls via `clip.get`; dumping the
/// clipboard at auth would be a privacy leak, RESEARCH Pitfall 8).
fn clip_changed_frame(text: String) -> Message {
    Message::text(json::encode_msg(
        &Msg::ClipChanged(ClipChangedPayload { text }),
        None,
    ))
}

/// Build an `authFail` reply with the SPEC §5 reason string and its
/// reason-specific extras.
fn auth_fail(
    reason: &str,
    attempts_remaining: Option<u32>,
    retry_after_secs: Option<u64>,
) -> Msg {
    Msg::AuthFail(AuthFailPayload {
        reason: reason.to_string(),
        attempts_remaining,
        retry_after_secs,
    })
}
