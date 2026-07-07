//! Socket-level integration suite: a REAL server on an ephemeral port
//! driven by a real tokio-tungstenite client (RESEARCH Pattern 5 — no
//! mocked sockets).
//!
//! Proves phase success criteria 2 and 4 end to end: pairing and
//! challenge-response reconnect over the wire, the CONN-07 headline
//! (disconnect mid-drag releases held input), pre-auth/pause gating at the
//! socket level, D-06 version rejection, D-07 unknown-type survival, and
//! the 64 KB transport caps (SPEC §13).
//!
//! Timeout discipline: EVERY recv (and connect) is wrapped in
//! `tokio::time::timeout(RECV_TIMEOUT)` so a silent server fails a test in
//! seconds, never hangs the suite.

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

use server_core::auth::AuthManager;
use server_core::auth::challenge::auth_proof;
use server_core::codec::binary::{MouseFrame, encode as encode_frame};
use server_core::executors::Button;
use server_core::executors::mock::{Call, CallLog, MockExecutors};
use server_core::transport::ServerDeps;

/// Every recv (and the connect) is wrapped in this timeout so a silent
/// server fails the test in seconds, never hangs it.
const RECV_TIMEOUT: Duration = Duration::from_secs(2);

type WsClient = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

/// Bind 127.0.0.1:0, spawn `server_core::run`, return the actual address
/// (RESEARCH Pattern 5: real TCP, ephemeral port, no mocked sockets).
async fn spawn_test_server(deps: ServerDeps) -> (SocketAddr, tokio::task::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind ephemeral port on 127.0.0.1");
    let addr = listener.local_addr().expect("read bound address");
    let handle = tokio::spawn(server_core::run(listener, deps));
    (addr, handle)
}

/// Receive the next frame, requiring a JSON text frame within RECV_TIMEOUT.
async fn recv_json(ws: &mut WsClient) -> Value {
    let msg = tokio::time::timeout(RECV_TIMEOUT, ws.next())
        .await
        .expect("timed out waiting for a server frame")
        .expect("connection closed before the expected frame")
        .expect("websocket error while receiving");
    match msg {
        // tungstenite 0.29: Text carries Utf8Bytes, not String.
        Message::Text(t) => serde_json::from_str(t.as_str()).expect("server sent invalid JSON"),
        other => panic!("expected a JSON text frame, got: {other:?}"),
    }
}

#[tokio::test]
async fn walking_skeleton_pair_auth_input() {
    // Recording mocks: the test's only window into executed input.
    let (executors, log) = MockExecutors::recording();

    // Test hook: hold the AuthManager ourselves so we can read the active
    // pairing PIN (ServerDeps exposes it for exactly this reason).
    let auth = Arc::new(Mutex::new(AuthManager::new()));
    let pin = auth.lock().unwrap().begin_pairing();

    let (_pause_tx, pause_rx) = tokio::sync::watch::channel(false);
    let deps = ServerDeps {
        executors,
        auth: Arc::clone(&auth),
        pause: pause_rx,
    };

    let (addr, _server) = spawn_test_server(deps).await;

    let (mut ws, _resp) = tokio::time::timeout(
        RECV_TIMEOUT,
        tokio_tungstenite::connect_async(format!("ws://{addr}")),
    )
    .await
    .expect("timed out connecting to test server")
    .expect("websocket connect failed");

    // 1. hello → expect challenge with a 64-lowercase-hex nonce.
    ws.send(Message::text(
        json!({"t": "hello", "seq": 1, "p": {"protoVersion": "1.0", "device": "itest"}})
            .to_string(),
    ))
    .await
    .expect("send hello");

    let challenge = recv_json(&mut ws).await;
    assert_eq!(
        challenge["t"], "challenge",
        "expected challenge after hello, got: {challenge}"
    );
    let nonce = challenge["p"]["nonce"]
        .as_str()
        .expect("challenge must carry p.nonce");
    assert_eq!(nonce.len(), 64, "nonce must be 64 hex chars");
    assert!(
        nonce.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()),
        "nonce must be lowercase hex, got: {nonce}"
    );

    // 2. pin (pairing path) → expect pairOk carrying a 64-hex raw token.
    ws.send(Message::text(
        json!({"t": "pin", "seq": 2, "p": {"pin": pin}}).to_string(),
    ))
    .await
    .expect("send pin");

    let pair_ok = recv_json(&mut ws).await;
    assert_eq!(
        pair_ok["t"], "pairOk",
        "expected pairOk after correct pin, got: {pair_ok}"
    );
    let token = pair_ok["p"]["token"]
        .as_str()
        .expect("pairOk must carry p.token");
    assert_eq!(token.len(), 64, "token must be 64 hex chars");
    assert!(
        token.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()),
        "token must be lowercase hex, got: {token}"
    );

    // 3. click (now Authed) → the mock MouseKeys must record it.
    ws.send(Message::text(
        json!({"t": "click", "seq": 3, "p": {"button": "left"}}).to_string(),
    ))
    .await
    .expect("send click");

    let recorded = log
        .wait_for(
            |calls| calls.contains(&Call::Click(Button::Left)),
            RECV_TIMEOUT,
        )
        .await;
    assert!(
        recorded,
        "mock never recorded Click(Left); recorded calls: {:?}",
        log.calls()
    );
}

// ───────────────────────── shared harness ─────────────────────────────

/// Everything a socket-level test needs: a live server on an ephemeral
/// port plus handles to its recording log, auth manager, and pause switch.
struct Harness {
    addr: SocketAddr,
    log: CallLog,
    auth: Arc<Mutex<AuthManager>>,
    pause_tx: tokio::sync::watch::Sender<bool>,
    _server: tokio::task::JoinHandle<()>,
}

async fn start_server() -> Harness {
    let (executors, log) = MockExecutors::recording();
    let auth = Arc::new(Mutex::new(AuthManager::new()));
    let (pause_tx, pause_rx) = tokio::sync::watch::channel(false);
    let deps = ServerDeps {
        executors,
        auth: Arc::clone(&auth),
        pause: pause_rx,
    };
    let (addr, server) = spawn_test_server(deps).await;
    Harness { addr, log, auth, pause_tx, _server: server }
}

async fn connect(addr: SocketAddr) -> WsClient {
    let (ws, _resp) = tokio::time::timeout(
        RECV_TIMEOUT,
        tokio_tungstenite::connect_async(format!("ws://{addr}")),
    )
    .await
    .expect("timed out connecting to test server")
    .expect("websocket connect failed");
    ws
}

async fn send_json(ws: &mut WsClient, v: Value) {
    ws.send(Message::text(v.to_string())).await.expect("send frame");
}

/// hello → challenge; returns the challenge nonce (64 lowercase hex).
async fn hello_challenge(ws: &mut WsClient) -> String {
    send_json(
        ws,
        json!({"t": "hello", "seq": 1, "p": {"protoVersion": "1.0", "device": "itest"}}),
    )
    .await;
    let challenge = recv_json(ws).await;
    assert_eq!(
        challenge["t"], "challenge",
        "expected challenge after hello, got: {challenge}"
    );
    challenge["p"]["nonce"]
        .as_str()
        .expect("challenge must carry p.nonce")
        .to_string()
}

/// Full pairing handshake on a fresh connection (begins a new pairing
/// window each call); returns the authed client plus the pairOk raw token.
async fn pair_client(h: &Harness) -> (WsClient, String) {
    let pin = h.auth.lock().unwrap().begin_pairing();
    let mut ws = connect(h.addr).await;
    let _nonce = hello_challenge(&mut ws).await;
    send_json(&mut ws, json!({"t": "pin", "seq": 2, "p": {"pin": pin}})).await;
    let pair_ok = recv_json(&mut ws).await;
    assert_eq!(
        pair_ok["t"], "pairOk",
        "expected pairOk after correct pin, got: {pair_ok}"
    );
    let token = pair_ok["p"]["token"]
        .as_str()
        .expect("pairOk must carry p.token")
        .to_string();
    (ws, token)
}

/// Fully authed client via the pairing path, for tests that don't need the
/// token.
async fn authed_client(h: &Harness) -> WsClient {
    pair_client(h).await.0
}

/// A 9-byte binary move frame ready to send (SPEC §9).
fn move_frame(dx: f32, dy: f32) -> Message {
    Message::binary(encode_frame(&MouseFrame::Move { dx, dy }).to_vec())
}

// ───────────────────────── socket-level suite ──────────────────────────

/// Phase criterion 3, wire half: after pairing once, a reconnect
/// authenticates with an HMAC proof — the raw token never crosses the wire
/// again (SPEC §4).
#[tokio::test]
async fn reconnect_challenge_response_auth() {
    let h = start_server().await;

    // Pair once, capturing the raw token, then disconnect.
    let (mut ws, token) = pair_client(&h).await;
    ws.close(None).await.expect("clean close after pairing");
    drop(ws);

    // Reconnect: hello → challenge → auth with mac = HMAC-SHA256(
    // key = SHA-256(raw token), msg = nonce bytes).
    let mut ws = connect(h.addr).await;
    let nonce_hex = hello_challenge(&mut ws).await;
    let token_bytes = hex::decode(&token).expect("token is hex");
    let nonce_bytes = hex::decode(&nonce_hex).expect("nonce is hex");
    let mac = auth_proof(&token_bytes, &nonce_bytes);
    send_json(&mut ws, json!({"t": "auth", "seq": 2, "p": {"mac": mac}})).await;
    let auth_ok = recv_json(&mut ws).await;
    assert_eq!(
        auth_ok["t"], "authOk",
        "expected authOk for a valid challenge-response proof, got: {auth_ok}"
    );

    // The authed reconnect session drives the binary hot path.
    ws.send(move_frame(12.5, -3.25)).await.expect("send binary move frame");
    assert!(
        h.log
            .wait_for(|calls| calls.contains(&Call::MoveRel(12.5, -3.25)), RECV_TIMEOUT)
            .await,
        "mock never recorded MoveRel(12.5, -3.25); calls: {:?}",
        h.log.calls()
    );
}

/// CONN-07 HEADLINE (RESEARCH Code Example 4): killing the socket mid-drag
/// must release the held button via session teardown — and a fresh session
/// must start with empty held state (no phantom releases).
#[tokio::test]
async fn disconnect_mid_drag_releases_held_input() {
    let h = start_server().await;
    let mut ws = authed_client(&h).await;

    // Start a drag and PROVE it reached the executor before killing the
    // socket (no sleep-and-hope).
    send_json(
        &mut ws,
        json!({"t": "drag", "seq": 3, "p": {"action": "start", "button": "left"}}),
    )
    .await;
    assert!(
        h.log
            .wait_for(|calls| calls.contains(&Call::ButtonDown(Button::Left)), RECV_TIMEOUT)
            .await,
        "drag start never reached the mock; calls: {:?}",
        h.log.calls()
    );

    // Kill the socket abruptly mid-drag: no close frame, no goodbye.
    drop(ws);

    // Session teardown must release the held button (CONN-07).
    assert!(
        h.log
            .wait_for(|calls| calls.contains(&Call::ButtonUp(Button::Left)), RECV_TIMEOUT)
            .await,
        "mid-drag disconnect never released the held button; calls: {:?}",
        h.log.calls()
    );

    // Fresh session: input works, and NO phantom ButtonUp precedes its own
    // actions (HeldInput is per session, starting empty).
    let baseline = h.log.calls().len();
    let mut ws2 = authed_client(&h).await;
    send_json(&mut ws2, json!({"t": "click", "seq": 4, "p": {"button": "left"}})).await;
    assert!(
        h.log
            .wait_for(|calls| calls.contains(&Call::Click(Button::Left)), RECV_TIMEOUT)
            .await,
        "second session's click never routed; calls: {:?}",
        h.log.calls()
    );
    let after: Vec<Call> = h.log.calls().split_off(baseline);
    assert!(
        after.contains(&Call::Click(Button::Left)),
        "second session's click missing from the post-teardown calls: {after:?}"
    );
    assert!(
        !after.contains(&Call::ButtonUp(Button::Left)),
        "phantom ButtonUp in the fresh session — held state leaked across sessions: {after:?}"
    );
}

/// SPEC §6 at socket level (T-01-27): pre-auth executor-bound traffic —
/// JSON and binary alike — never reaches an executor, and the gate does not
/// poison the session: pairing on the SAME connection then routes normally.
#[tokio::test]
async fn pre_auth_input_dropped() {
    let h = start_server().await;
    let pin = h.auth.lock().unwrap().begin_pairing();

    let mut ws = connect(h.addr).await;
    let _nonce = hello_challenge(&mut ws).await; // state: AwaitingAuth

    // Executor-bound traffic BEFORE auth.
    send_json(&mut ws, json!({"t": "click", "seq": 2, "p": {"button": "left"}})).await;
    send_json(&mut ws, json!({"t": "text", "seq": 3, "p": {"bs": 0, "ins": "pwned"}})).await;
    ws.send(move_frame(5.0, 5.0)).await.expect("send binary move frame");

    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(
        h.log.calls().is_empty(),
        "pre-auth input reached an executor: {:?}",
        h.log.calls()
    );

    // Complete pairing on the SAME connection…
    send_json(&mut ws, json!({"t": "pin", "seq": 4, "p": {"pin": pin}})).await;
    let pair_ok = recv_json(&mut ws).await;
    assert_eq!(
        pair_ok["t"], "pairOk",
        "pairing must still work after pre-auth drops, got: {pair_ok}"
    );

    // …after which input routes normally (the gate didn't poison the session).
    send_json(&mut ws, json!({"t": "click", "seq": 5, "p": {"button": "left"}})).await;
    assert!(
        h.log
            .wait_for(|calls| calls.contains(&Call::Click(Button::Left)), RECV_TIMEOUT)
            .await,
        "post-auth click never routed on the same connection; calls: {:?}",
        h.log.calls()
    );
}

/// SPEC §11 at socket level (T-01-30): paused input is dropped, liveness
/// (ping/pong) survives, unpausing restores routing, and pause ACTIVATION
/// releases held input immediately.
#[tokio::test]
async fn paused_input_dropped() {
    let h = start_server().await;
    let mut ws = authed_client(&h).await;

    // Paused: executor-bound input is silently dropped.
    h.pause_tx.send(true).expect("pause watch alive");
    send_json(&mut ws, json!({"t": "click", "seq": 3, "p": {"button": "left"}})).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(
        h.log.calls().is_empty(),
        "paused click reached the executor: {:?}",
        h.log.calls()
    );

    // Pause never breaks liveness probing: ping still pongs.
    send_json(&mut ws, json!({"t": "ping", "seq": 4, "p": {"ts": 777}})).await;
    let pong = recv_json(&mut ws).await;
    assert_eq!(pong["t"], "pong", "ping must survive pause, got: {pong}");
    assert_eq!(pong["p"]["ts"], 777, "pong must echo the ping ts");

    // Unpaused: input routes again.
    h.pause_tx.send(false).expect("pause watch alive");
    send_json(&mut ws, json!({"t": "click", "seq": 5, "p": {"button": "left"}})).await;
    assert!(
        h.log
            .wait_for(|calls| calls.contains(&Call::Click(Button::Left)), RECV_TIMEOUT)
            .await,
        "click after unpause never routed; calls: {:?}",
        h.log.calls()
    );

    // Pause ACTIVATION releases held input: drag start while unpaused…
    send_json(
        &mut ws,
        json!({"t": "drag", "seq": 6, "p": {"action": "start", "button": "right"}}),
    )
    .await;
    assert!(
        h.log
            .wait_for(|calls| calls.contains(&Call::ButtonDown(Button::Right)), RECV_TIMEOUT)
            .await,
        "drag start never reached the mock; calls: {:?}",
        h.log.calls()
    );
    // …then pause → immediate release (SPEC §11, RESEARCH pitfall 12).
    h.pause_tx.send(true).expect("pause watch alive");
    assert!(
        h.log
            .wait_for(|calls| calls.contains(&Call::ButtonUp(Button::Right)), RECV_TIMEOUT)
            .await,
        "pause activation must release the held button; calls: {:?}",
        h.log.calls()
    );
}

/// D-06 at socket level: a major protoVersion mismatch is rejected with an
/// err carrying BOTH versions, then the connection closes.
#[tokio::test]
async fn version_major_mismatch_rejected() {
    let h = start_server().await;
    let mut ws = connect(h.addr).await;

    send_json(
        &mut ws,
        json!({"t": "hello", "seq": 1, "p": {"protoVersion": "2.0", "device": "itest"}}),
    )
    .await;
    let err = recv_json(&mut ws).await;
    assert_eq!(err["t"], "err", "expected err after major mismatch, got: {err}");
    assert_eq!(err["p"]["code"], "versionMismatch");
    assert_eq!(err["p"]["serverVersion"], "1.0", "D-06: err must carry serverVersion");
    assert_eq!(err["p"]["clientVersion"], "2.0", "D-06: err must carry clientVersion");

    // The connection then closes (SPEC §2).
    let next = tokio::time::timeout(RECV_TIMEOUT, ws.next())
        .await
        .expect("timed out waiting for the stream to close after versionMismatch");
    match next {
        None | Some(Ok(Message::Close(_))) | Some(Err(_)) => {}
        Some(Ok(other)) => {
            panic!("expected the stream to close after versionMismatch, got: {other:?}")
        }
    }
}

/// D-07 at socket level: an unknown `t` post-auth gets err{unknownType} and
/// the session SURVIVES.
#[tokio::test]
async fn unknown_type_err_keeps_connection() {
    let h = start_server().await;
    let mut ws = authed_client(&h).await;

    send_json(&mut ws, json!({"t": "frobnicate", "seq": 3, "p": {}})).await;
    let err = recv_json(&mut ws).await;
    assert_eq!(err["t"], "err", "expected err for unknown type, got: {err}");
    assert_eq!(err["p"]["code"], "unknownType");

    // The session survives (D-07): ping still pongs on the same connection.
    send_json(&mut ws, json!({"t": "ping", "seq": 4, "p": {"ts": 42}})).await;
    let pong = recv_json(&mut ws).await;
    assert_eq!(pong["t"], "pong", "session must survive an unknown type, got: {pong}");
    assert_eq!(pong["p"]["ts"], 42);
}

/// SPEC §13 / T-01-26: a >64 KB frame pre-auth must not panic the server or
/// reach an executor. Whether the connection is closed or the message is
/// rejected is implementation detail — both are accepted; the server must
/// keep accepting NEW connections afterward.
#[tokio::test]
async fn oversized_message_handled() {
    let h = start_server().await;
    let mut ws = connect(h.addr).await;

    // 70 KB of pre-auth junk text. The send itself may fail if the server
    // slams the connection first — that is also a valid rejection.
    let oversized = "x".repeat(70 * 1024);
    let _ = ws.send(Message::text(oversized)).await;

    // Drain until the connection settles (close/error/end) or goes quiet.
    loop {
        match tokio::time::timeout(RECV_TIMEOUT, ws.next()).await {
            Err(_) => break,                          // quiet: frame was dropped
            Ok(None) => break,                        // stream ended
            Ok(Some(Err(_))) => break,                // connection error
            Ok(Some(Ok(Message::Close(_)))) => break, // server closed
            Ok(Some(Ok(other))) => {
                panic!("unexpected frame after oversized send: {other:?}")
            }
        }
    }

    assert!(
        h.log.calls().is_empty(),
        "oversized frame reached an executor: {:?}",
        h.log.calls()
    );

    // The SERVER survives: a brand-new connection pairs and routes input.
    let mut ws2 = authed_client(&h).await;
    send_json(&mut ws2, json!({"t": "click", "seq": 3, "p": {"button": "right"}})).await;
    assert!(
        h.log
            .wait_for(|calls| calls.contains(&Call::Click(Button::Right)), RECV_TIMEOUT)
            .await,
        "server must keep accepting connections after an oversized frame; calls: {:?}",
        h.log.calls()
    );
}
