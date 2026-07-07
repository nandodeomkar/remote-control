//! Walking-skeleton end-to-end test (MVP first-task rule).
//!
//! Drives the full happy path against a REAL server on an ephemeral port
//! with a real tokio-tungstenite client:
//! connect → hello → challenge → pin → pairOk → click → mock recording.
//!
//! RED by design in Wave 2: every body in `server-core` is `todo!()`
//! (`run()` included). Plan 01-06 makes this green — do not weaken any
//! assertion to get there early.

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

use server_core::auth::AuthManager;
use server_core::executors::Button;
use server_core::executors::mock::{Call, MockExecutors};
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
