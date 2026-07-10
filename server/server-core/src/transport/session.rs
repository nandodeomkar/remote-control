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
use crate::codec::json::{
    AuthFailPayload, AuthOkPayload, ChallengePayload, ErrPayload, Msg, PairOkPayload,
};
use crate::codec::{binary, json};
use crate::dispatch::AuthState;
use crate::dispatch::held::HeldInput;
use crate::dispatch::router::{self, SessionCtx};
use crate::executors::Executors;

/// The server's protocol version (SPEC §2). Only the MAJOR component is
/// compared against the client's `hello.protoVersion`. `pub(crate)` so the
/// beacon's `proto` field references it instead of duplicating the literal.
pub(crate) const SERVER_PROTO_VERSION: &str = "1.0";
const SERVER_PROTO_MAJOR: u64 = 1;

/// Liveness deadline: a session receiving NO inbound frames for this long
/// breaks its read loop so the CONN-07 cleanup releases held input.
///
/// Rationale: the client emits protocol pings every ~250ms under move load
/// and ~2s idle (latency_probe.dart `pingIntervalMillis` /
/// `idlePingIntervalMillis`), so 10s is ≥ 5× the slowest healthy inbound
/// cadence — a live client can never trip this. Without it, a half-open TCP
/// connection after an abrupt WiFi kill (no FIN, no RST) keeps
/// `stream.next()` pending for OS-timeout minutes while held input stays
/// stuck (04-UAT Test 5, threat class T-04-04). Side-effect hardening: a
/// silent pre-hello socket squatter also dies in 10s instead of holding a
/// session task forever. Private on purpose — nothing else needs it; the
/// integration test hard-codes a longer wait and names the coupling.
const LIVENESS_TIMEOUT: Duration = Duration::from_secs(10);

/// Run one connection to completion: write task + read loop + handshake FSM
/// + unconditional held-input cleanup (CONN-07).
pub(super) async fn run_session(
    ws: WebSocketStream<TcpStream>,
    peer_ip: IpAddr,
    executors: Executors,
    auth: Arc<Mutex<AuthManager>>,
    mut pause: watch::Receiver<bool>,
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
    // Last time ANY inbound bytes arrived from the peer; drives the
    // liveness deadline branch below.
    let mut last_inbound = Instant::now();

    'read: loop {
        tokio::select! {
            // Liveness deadline (04-UAT Test 5): no inbound frames for
            // LIVENESS_TIMEOUT means the peer is gone (half-open TCP after
            // an abrupt WiFi kill never yields None/Err from stream.next()).
            // Breaking 'read lands on the EXISTING straight-line CONN-07
            // cleanup below the loop — no new cleanup code, that is the
            // entire point of the straight-line structure. Constructing the
            // sleep_until future fresh each iteration is correct: select!
            // re-creates non-pinned futures per pass, and the loop rate is
            // bounded by the inbound frame rate.
            () = sleep_until(last_inbound + LIVENESS_TIMEOUT) => break 'read,
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
