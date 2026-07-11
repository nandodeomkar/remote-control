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
use server_core::executors::{Button, KeyCode, WindowInfo};
use server_core::executors::mock::{Call, CallLog, MockExecutors};
use server_core::transport::{SERVER_PROTO_VERSION, ServerDeps, VolumeState};

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
    // Named binding (not `_`): dropping the sender would disable the
    // session's volume branch.
    let (_volume_tx, volume_rx) = tokio::sync::watch::channel(VolumeState::default());
    // Same discipline for the apps watch (APPS-03): keep the sender alive.
    let (_apps_tx, apps_rx) = tokio::sync::watch::channel(Vec::<WindowInfo>::new());
    let deps = ServerDeps {
        executors,
        auth: Arc::clone(&auth),
        pause: pause_rx,
        volume: volume_rx,
        apps: apps_rx,
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
    // "1.0" here is a HISTORICAL WIRE PIN, kept deliberately: a 1.0 client
    // against the 1.1 server exercises SPEC §2 minor-mismatch acceptance.
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
    /// Test-owned producer end of the volume watch (MED-02): the vol_ suite
    /// drives `vol.changed` pushes through it.
    volume_tx: tokio::sync::watch::Sender<VolumeState>,
    /// Test-owned producer end of the apps watch (APPS-03): the apps_ suite
    /// drives `apps.changed` pushes through it.
    apps_tx: tokio::sync::watch::Sender<Vec<WindowInfo>>,
    _server: tokio::task::JoinHandle<()>,
}

async fn start_server() -> Harness {
    let (executors, log) = MockExecutors::recording();
    let auth = Arc::new(Mutex::new(AuthManager::new()));
    let (pause_tx, pause_rx) = tokio::sync::watch::channel(false);
    let (volume_tx, volume_rx) = tokio::sync::watch::channel(VolumeState::default());
    let (apps_tx, apps_rx) = tokio::sync::watch::channel(Vec::<WindowInfo>::new());
    let deps = ServerDeps {
        executors,
        auth: Arc::clone(&auth),
        pause: pause_rx,
        volume: volume_rx,
        apps: apps_rx,
    };
    let (addr, server) = spawn_test_server(deps).await;
    Harness { addr, log, auth, pause_tx, volume_tx, apps_tx, _server: server }
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
/// "1.0" is a HISTORICAL WIRE PIN, kept deliberately: a 1.0 client against
/// the 1.1 server exercises SPEC §2 minor-mismatch acceptance.
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
/// token. The D-03 `vol.changed` snapshot arriving right after pairOk is
/// drained here so callers start with a clean stream; the vol_ suite uses
/// `pair_client` directly when the snapshot itself is under test.
async fn authed_client(h: &Harness) -> WsClient {
    let mut ws = pair_client(h).await.0;
    let _snapshot = recv_vol_changed(&mut ws).await;
    ws
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

/// 04-UAT Test 5 (MAJOR gap, threat class T-04-04): a HALF-OPEN connection
/// — abrupt WiFi kill, no FIN, no RST — must not preserve held input. The
/// sibling test above covers the graceful path (dropping the client sends
/// FIN/RST on loopback); HERE the socket stays open and silent, which is
/// byte-for-byte what the server sees after the phone vanishes
/// mid-keypress. The server's liveness deadline must break the read loop
/// so the EXISTING straight-line CONN-07 cleanup releases the held key.
#[tokio::test]
async fn half_open_silence_releases_held_input() {
    let h = start_server().await;
    let mut ws = authed_client(&h).await;

    // Real-time phase: hold Shift and PROVE it reached the executor BEFORE
    // any clock games (no sleep-and-hope).
    send_json(
        &mut ws,
        json!({"t": "key", "seq": 3, "p": {"code": "ShiftLeft", "action": "down"}}),
    )
    .await;
    assert!(
        h.log
            .wait_for(
                |calls| calls.contains(&Call::KeyDown(KeyCode("ShiftLeft".into()))),
                RECV_TIMEOUT,
            )
            .await,
        "key hold never reached the mock; calls: {:?}",
        h.log.calls()
    );

    // From here the clock is virtual: auto-advance jumps to the next
    // pending timer whenever the runtime idles, so the silent wait below
    // costs ~0 wall-clock. (Requires the current-thread test flavor.)
    tokio::time::pause();

    // Half-open simulation: keep `ws` ALIVE and BOUND — do NOT drop it,
    // do NOT close it, send NOTHING. Dropping would emit FIN/RST on
    // loopback (the already-passing graceful path above); pure silence is
    // the abrupt-WiFi-kill shape: the server's stream.next() stays
    // pending forever.

    // The liveness deadline must release the held key. The 60s bound must
    // exceed session.rs LIVENESS_TIMEOUT (10s): under paused time the
    // EARLIEST pending timer fires first, so a shorter wait (e.g.
    // RECV_TIMEOUT = 2s) would expire before the server's deadline and
    // false-fail.
    assert!(
        h.log
            .wait_for(
                |calls| calls.contains(&Call::KeyUp(KeyCode("ShiftLeft".into()))),
                Duration::from_secs(60),
            )
            .await,
        "half-open silence never released the held key (phantom Shift); calls: {:?}",
        h.log.calls()
    );

    // Back to REAL time for the session-end check: tokio auto-advance does
    // not block-wait on IO, so a virtual timeout could expire before the
    // kernel delivers the loopback FIN and flake (plan-checker note).
    tokio::time::resume();

    // The server must terminate the half-open session (read loop broke →
    // socket halves dropped) — the client observes close/EOF/error. Any of
    // the three proves the session task exited rather than leaking.
    // Awaiting ws.next() here also keeps `ws` alive through the assertions
    // above (ownership never dropped early).
    let end = tokio::time::timeout(RECV_TIMEOUT, ws.next())
        .await
        .expect("timed out waiting for the server to drop the half-open session");
    match end {
        None | Some(Ok(Message::Close(_))) | Some(Err(_)) => {}
        Some(Ok(other)) => {
            panic!("expected the half-open session to end, got: {other:?}")
        }
    }
}

/// Review CR-01 regression: the liveness deadline must NOT kill a pre-auth
/// session mid-PIN-entry. During pairing the user reads the PIN off the PC
/// toast and types 6 digits — routinely >10s of inbound silence (the client
/// sends nothing while waiting for PIN input; protocol pings only start
/// post-auth), and the server's own PIN window budgets 60s (PIN_TTL_SECS)
/// for exactly this. An unconditional 10s deadline slams the socket before
/// the pin frame arrives — a deterministic pairing regression. Pre-auth
/// sessions get the longer PRE_AUTH_LIVENESS_TIMEOUT; the 10s UAT Test 5
/// contract applies only once Authed (held input only exists post-auth —
/// the sibling test above keeps that leg pinned).
#[tokio::test]
async fn pre_auth_silence_survives_pin_entry() {
    let h = start_server().await;
    let pin = h.auth.lock().unwrap().begin_pairing();

    let mut ws = connect(h.addr).await;
    let _nonce = hello_challenge(&mut ws).await; // state: AwaitingAuth

    // Simulate the human PIN-entry gap: 30s of inbound silence — well past
    // the 10s post-auth deadline, comfortably inside both the 60s PIN
    // window (PIN expiry rides the tokio clock, so virtual time counts
    // against it too) and the pre-auth liveness deadline (90s). Paused
    // clock: the wait costs ~0 wall-clock via auto-advance.
    tokio::time::pause();
    tokio::time::sleep(Duration::from_secs(30)).await;
    tokio::time::resume();

    // The session must still be alive: PIN submission completes pairing on
    // the SAME connection.
    send_json(&mut ws, json!({"t": "pin", "seq": 2, "p": {"pin": pin}})).await;
    let pair_ok = recv_json(&mut ws).await;
    assert_eq!(
        pair_ok["t"], "pairOk",
        "pre-auth liveness deadline killed the session mid-PIN-entry, got: {pair_ok}"
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
    assert_eq!(
        err["p"]["serverVersion"], SERVER_PROTO_VERSION,
        "D-06: err must carry the CURRENT serverVersion"
    );
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

// ──────────────── vol.changed push gating (MED-02, D-03) ───────────────

/// "No frame arrives" window: long enough for a wrongly-pushed frame to
/// cross loopback, short enough not to drag the suite.
const SILENCE_WINDOW: Duration = Duration::from_millis(400);

/// Receive the next frame, requiring a `vol.changed` push; returns
/// `(value, muted)`.
async fn recv_vol_changed(ws: &mut WsClient) -> (u64, bool) {
    let v = recv_json(ws).await;
    assert_eq!(v["t"], "vol.changed", "expected a vol.changed push, got: {v}");
    (
        v["p"]["value"].as_u64().expect("vol.changed must carry p.value"),
        v["p"]["muted"].as_bool().expect("vol.changed must carry p.muted"),
    )
}

/// Receive the next frame, requiring an `apps.changed` push; returns the
/// `windows` JSON array for field-level assertions.
async fn recv_apps_changed(ws: &mut WsClient) -> Vec<Value> {
    let v = recv_json(ws).await;
    assert_eq!(v["t"], "apps.changed", "expected an apps.changed push, got: {v}");
    v["p"]["windows"]
        .as_array()
        .expect("apps.changed must carry p.windows")
        .clone()
}

/// Two-window sample list: one with icon+path (protocol 1.2), one legacy.
fn sample_windows() -> Vec<WindowInfo> {
    vec![
        WindowInfo {
            id: 7,
            title: "Firefox".into(),
            icon: Some("aaaa".into()),
            path: Some("C:\\ff.exe".into()),
        },
        WindowInfo { id: 8, title: "Notepad".into(), icon: None, path: None },
    ]
}

/// Assert NO frame of any kind arrives within [`SILENCE_WINDOW`].
async fn assert_no_frame(ws: &mut WsClient, why: &str) {
    match tokio::time::timeout(SILENCE_WINDOW, ws.next()).await {
        Err(_) => {} // silence — expected
        Ok(frame) => panic!("{why}: expected silence, got: {frame:?}"),
    }
}

/// RESEARCH Pitfall 8 / threat T-05-05: a volume change while the session
/// is still pre-auth must push NOTHING to the unauthenticated peer.
/// Positive control on the SAME connection: once paired, the D-03 snapshot
/// arrives — proving the silence above was the auth gate, not a dead
/// channel.
#[tokio::test]
async fn vol_no_push_preauth() {
    let h = start_server().await;
    let pin = h.auth.lock().unwrap().begin_pairing();

    let mut ws = connect(h.addr).await;
    let _nonce = hello_challenge(&mut ws).await; // state: AwaitingAuth

    // Volume changes while the session is unauthed → total silence.
    h.volume_tx
        .send(VolumeState { value: 40, muted: false })
        .expect("volume watch alive");
    assert_no_frame(&mut ws, "vol.changed leaked to an unauthed session").await;

    // Positive control: pairing on the SAME connection → pairOk, then the
    // snapshot carrying the state pushed while unauthed.
    send_json(&mut ws, json!({"t": "pin", "seq": 2, "p": {"pin": pin}})).await;
    let pair_ok = recv_json(&mut ws).await;
    assert_eq!(
        pair_ok["t"], "pairOk",
        "expected pairOk after correct pin, got: {pair_ok}"
    );
    let (value, muted) = recv_vol_changed(&mut ws).await;
    assert_eq!(
        (value, muted),
        (40, false),
        "post-auth snapshot must carry the state set while unauthed"
    );
}

/// D-03 "right after auth", pairing path: exactly ONE vol.changed snapshot
/// immediately after pairOk, carrying the watch channel's current state.
#[tokio::test]
async fn vol_snapshot_after_pair_auth() {
    let h = start_server().await;
    // Non-default state BEFORE the client connects, so the snapshot
    // assertion can't pass vacuously on Default.
    h.volume_tx
        .send(VolumeState { value: 37, muted: true })
        .expect("volume watch alive");

    let (mut ws, _token) = pair_client(&h).await; // asserts pairOk inside
    let (value, muted) = recv_vol_changed(&mut ws).await;
    assert_eq!((value, muted), (37, true), "snapshot must carry current state");

    // EXACTLY one: the select! branch must not re-fire on the same state
    // right after the transition snapshot (borrow_and_update discipline).
    assert_no_frame(&mut ws, "duplicate vol.changed after the pair-path snapshot").await;
}

/// D-03 "right after auth", challenge-response reconnect path: exactly ONE
/// vol.changed snapshot immediately after authOk.
#[tokio::test]
async fn vol_snapshot_after_token_auth() {
    let h = start_server().await;

    // Pair once for the token, then disconnect.
    let (mut ws, token) = pair_client(&h).await;
    ws.close(None).await.expect("clean close after pairing");
    drop(ws);

    h.volume_tx
        .send(VolumeState { value: 82, muted: false })
        .expect("volume watch alive");

    // Reconnect via HMAC proof (same construction as the reconnect test).
    let mut ws = connect(h.addr).await;
    let nonce_hex = hello_challenge(&mut ws).await;
    let token_bytes = hex::decode(&token).expect("token is hex");
    let nonce_bytes = hex::decode(&nonce_hex).expect("nonce is hex");
    let mac = auth_proof(&token_bytes, &nonce_bytes);
    send_json(&mut ws, json!({"t": "auth", "seq": 2, "p": {"mac": mac}})).await;
    let auth_ok = recv_json(&mut ws).await;
    assert_eq!(
        auth_ok["t"], "authOk",
        "expected authOk for a valid proof, got: {auth_ok}"
    );

    let (value, muted) = recv_vol_changed(&mut ws).await;
    assert_eq!((value, muted), (82, false), "snapshot must carry current state");
    assert_no_frame(&mut ws, "duplicate vol.changed after the auth-path snapshot").await;
}

/// MED-02 live push: once authed (snapshot drained), every watch change —
/// including a mute-only change — produces a vol.changed frame.
#[tokio::test]
async fn vol_push_on_change_when_authed() {
    let h = start_server().await;
    let (mut ws, _token) = pair_client(&h).await;
    // Drain the D-03 after-auth snapshot (default state).
    let _snapshot = recv_vol_changed(&mut ws).await;

    h.volume_tx
        .send(VolumeState { value: 55, muted: false })
        .expect("volume watch alive");
    let (value, muted) = recv_vol_changed(&mut ws).await;
    assert_eq!((value, muted), (55, false), "push must carry the new value");

    // Mute-only change pushes too (value unchanged).
    h.volume_tx
        .send(VolumeState { value: 55, muted: true })
        .expect("volume watch alive");
    let (value, muted) = recv_vol_changed(&mut ws).await;
    assert_eq!((value, muted), (55, true), "push must carry the new muted flag");
}

// ──────────────── apps.changed push gating (APPS-03) ───────────────────

/// T-06-01 / threat: a window-list change while the session is still
/// pre-auth must push NOTHING to the unauthenticated peer. Positive control
/// on the SAME connection: once paired, the pending pre-auth change is
/// delivered via the now-enabled apps branch (after the D-03 vol snapshot) —
/// proving the silence above was the auth gate, not a dead channel.
#[tokio::test]
async fn apps_no_push_preauth() {
    let h = start_server().await;
    let pin = h.auth.lock().unwrap().begin_pairing();

    let mut ws = connect(h.addr).await;
    let _nonce = hello_challenge(&mut ws).await; // state: AwaitingAuth

    // Window list changes while unauthed → total silence.
    h.apps_tx.send(sample_windows()).expect("apps watch alive");
    assert_no_frame(&mut ws, "apps.changed leaked to an unauthed session").await;

    // Positive control: pair on the SAME connection → pairOk, then the D-03
    // vol.changed snapshot, then the pending window change fires.
    send_json(&mut ws, json!({"t": "pin", "seq": 2, "p": {"pin": pin}})).await;
    let pair_ok = recv_json(&mut ws).await;
    assert_eq!(
        pair_ok["t"], "pairOk",
        "expected pairOk after correct pin, got: {pair_ok}"
    );
    let _snapshot = recv_vol_changed(&mut ws).await; // D-03 vol snapshot
    let windows = recv_apps_changed(&mut ws).await;
    assert_eq!(
        windows.len(),
        2,
        "post-auth push must carry the windows set while unauthed"
    );
    assert_eq!(windows[0]["id"], 7);
    assert_eq!(windows[0]["icon"], "aaaa", "icon must survive the push");
    assert_eq!(windows[1]["id"], 8);
    assert!(
        windows[1].get("icon").is_none(),
        "legacy window must omit the icon key"
    );
}

/// APPS-03 live push + no-snapshot contract: once authed (with NO prior
/// window change), the transition emits NO apps snapshot (unlike volume); a
/// subsequent change produces exactly one apps.changed carrying the current
/// windows array.
#[tokio::test]
async fn apps_changed_after_auth() {
    let h = start_server().await;
    let mut ws = authed_client(&h).await; // drains the D-03 vol snapshot

    // No after-auth apps snapshot at the transition: apps never changed, so
    // nothing is pushed (the client pulls the initial list via apps.list).
    assert_no_frame(&mut ws, "unexpected apps.changed snapshot at the auth transition").await;

    // A window-list change now produces exactly one apps.changed.
    h.apps_tx.send(sample_windows()).expect("apps watch alive");
    let windows = recv_apps_changed(&mut ws).await;
    assert_eq!(windows.len(), 2, "push must carry the current window list");
    assert_eq!(windows[0]["id"], 7);
    assert_eq!(windows[0]["title"], "Firefox");
    assert_eq!(windows[0]["path"], "C:\\ff.exe");

    // Exactly one: no duplicate push on the same state.
    assert_no_frame(&mut ws, "duplicate apps.changed after a single change").await;
}
