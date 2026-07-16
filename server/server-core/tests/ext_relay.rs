//! Socket-level suite for the extension leg (SPEC §15, BROW-01): a REAL
//! `run_ext` relay on an ephemeral 127.0.0.1 port driven by a fake
//! extension via a tokio-tungstenite client.
//!
//! Six scenarios (plan Task 3): tabs.state → watch, disconnect → reset,
//! ExtCmd → activate frame, ExtCmd with no session dropped, newest-wins
//! replacement, and the oversize-frame kill + recovery (pitfall-2
//! regression).

use std::net::SocketAddr;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio::sync::{mpsc, watch};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

use server_core::executors::TabsState;
use server_core::transport::ext::{ExtCmd, run_ext};

const RECV_TIMEOUT: Duration = Duration::from_secs(2);

type WsClient = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

/// Everything a relay test needs: the bound address, the watch receiver the
/// phone side would observe, and the command sender the router side would
/// hold.
struct Relay {
    addr: SocketAddr,
    tabs_rx: watch::Receiver<TabsState>,
    cmd_tx: mpsc::Sender<ExtCmd>,
    _relay: tokio::task::JoinHandle<()>,
}

/// Bind 127.0.0.1:0, spawn `run_ext`, return the handles.
async fn spawn_relay() -> Relay {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind ephemeral port on 127.0.0.1");
    let addr = listener.local_addr().expect("read bound address");
    let (tabs_tx, tabs_rx) = watch::channel(TabsState::default());
    let (cmd_tx, cmd_rx) = mpsc::channel::<ExtCmd>(16);
    let relay = tokio::spawn(run_ext(listener, tabs_tx, cmd_rx));
    Relay { addr, tabs_rx, cmd_tx, _relay: relay }
}

/// Connect a fake extension to the relay.
async fn connect_ext(addr: SocketAddr) -> WsClient {
    let (ws, _resp) = tokio::time::timeout(
        RECV_TIMEOUT,
        tokio_tungstenite::connect_async(format!("ws://{addr}")),
    )
    .await
    .expect("timed out connecting to the ext relay")
    .expect("websocket connect failed");
    ws
}

async fn send_json(ws: &mut WsClient, v: Value) {
    ws.send(Message::text(v.to_string())).await.expect("send frame");
}

/// Receive the next JSON text frame from the relay within RECV_TIMEOUT.
async fn recv_json(ws: &mut WsClient) -> Value {
    let msg = tokio::time::timeout(RECV_TIMEOUT, ws.next())
        .await
        .expect("timed out waiting for a relay frame")
        .expect("connection closed before the expected frame")
        .expect("websocket error while receiving");
    match msg {
        Message::Text(t) => serde_json::from_str(t.as_str()).expect("relay sent invalid JSON"),
        other => panic!("expected a JSON text frame, got: {other:?}"),
    }
}

/// Wait (bounded) for the watch to satisfy `pred`.
async fn wait_watch(
    rx: &mut watch::Receiver<TabsState>,
    pred: impl FnMut(&TabsState) -> bool,
    why: &str,
) -> TabsState {
    tokio::time::timeout(RECV_TIMEOUT, rx.wait_for(pred))
        .await
        .unwrap_or_else(|_| panic!("timed out: {why}"))
        .expect("tabs watch sender dropped")
        .clone()
}

/// The canonical fake-extension snapshot frame.
fn tabs_state_frame() -> Value {
    json!({"t": "tabs.state", "p": {"tabs": [
        {"id": 7, "title": "GitHub", "active": true, "icon": "bbbb"},
        {"id": 9, "title": "Docs", "active": false}
    ]}})
}

/// Scenario 1: a `tabs.state` frame from the extension lands in the watch
/// as `{connected:true, tabs}` with fields intact.
#[tokio::test]
async fn tabs_state_populates_watch() {
    let mut r = spawn_relay().await;
    let mut ext = connect_ext(r.addr).await;

    send_json(&mut ext, json!({"t": "ext.hello", "p": {"extVersion": "1.0.0"}})).await;
    send_json(&mut ext, tabs_state_frame()).await;

    let state =
        wait_watch(&mut r.tabs_rx, |s| s.connected, "watch never showed connected:true").await;
    assert_eq!(state.tabs.len(), 2, "watch must carry both tabs");
    assert_eq!(state.tabs[0].id, 7);
    assert_eq!(state.tabs[0].title, "GitHub");
    assert!(state.tabs[0].active);
    assert_eq!(state.tabs[0].icon.as_deref(), Some("bbbb"));
    assert_eq!(state.tabs[1].id, 9);
    assert!(state.tabs[1].icon.is_none(), "iconless tab must decode icon=None");
}

/// Scenario 2: the extension disconnecting resets the watch to the default
/// (never-connected) state — the CONN-07-style cleanup that flips the phone
/// to the install hint.
#[tokio::test]
async fn ext_disconnect_resets_watch() {
    let mut r = spawn_relay().await;
    let mut ext = connect_ext(r.addr).await;

    send_json(&mut ext, tabs_state_frame()).await;
    wait_watch(&mut r.tabs_rx, |s| s.connected, "watch never showed connected:true").await;

    // Abrupt drop: no close frame, no goodbye.
    drop(ext);

    let state = wait_watch(
        &mut r.tabs_rx,
        |s| !s.connected,
        "watch never reset after the ext disconnect",
    )
    .await;
    assert_eq!(state, TabsState::default(), "reset must be the full default state");
}

/// Scenario 3: an `ExtCmd::Activate(7)` reaches the connected fake extension
/// as a `tabs.activate` frame with id 7 (and Close as tabs.close).
#[tokio::test]
async fn ext_cmd_forwards_activate_frame() {
    let mut r = spawn_relay().await;
    let mut ext = connect_ext(r.addr).await;

    // Prove the session is registered before commanding: the relay only
    // owns the session once accept completes — a snapshot round-trip
    // through the watch is the observable handshake.
    send_json(&mut ext, tabs_state_frame()).await;
    wait_watch(&mut r.tabs_rx, |s| s.connected, "session never registered").await;

    r.cmd_tx.send(ExtCmd::Activate(7)).await.expect("cmd channel alive");
    let frame = recv_json(&mut ext).await;
    assert_eq!(frame["t"], "tabs.activate", "expected tabs.activate, got: {frame}");
    assert_eq!(frame["p"]["id"], 7, "activate must carry the commanded id");

    r.cmd_tx.send(ExtCmd::Close(9)).await.expect("cmd channel alive");
    let frame = recv_json(&mut ext).await;
    assert_eq!(frame["t"], "tabs.close", "expected tabs.close, got: {frame}");
    assert_eq!(frame["p"]["id"], 9, "close must carry the commanded id");
}

/// Scenario 4: an ExtCmd with NO extension connected is dropped silently —
/// no panic, and the relay still works for a later connection.
#[tokio::test]
async fn ext_cmd_without_session_dropped() {
    let mut r = spawn_relay().await;

    // No extension connected: both commands must be swallowed.
    r.cmd_tx.send(ExtCmd::Activate(7)).await.expect("cmd channel alive");
    r.cmd_tx.send(ExtCmd::Close(9)).await.expect("cmd channel alive");

    // The relay survives: a later extension connects and its snapshot lands.
    let mut ext = connect_ext(r.addr).await;
    send_json(&mut ext, tabs_state_frame()).await;
    wait_watch(
        &mut r.tabs_rx,
        |s| s.connected,
        "relay dead after commands with no session",
    )
    .await;
}

/// Scenario 5: newest-wins — a second connection's tabs.state applies, and
/// the first socket observes closure (its stream ends once replaced).
#[tokio::test]
async fn newest_connection_wins() {
    let mut r = spawn_relay().await;
    let mut ext1 = connect_ext(r.addr).await;

    send_json(&mut ext1, tabs_state_frame()).await;
    wait_watch(&mut r.tabs_rx, |s| s.connected, "first session never registered").await;

    // Second extension connects and pushes a DIFFERENT snapshot.
    let mut ext2 = connect_ext(r.addr).await;
    send_json(
        &mut ext2,
        json!({"t": "tabs.state", "p": {"tabs": [
            {"id": 42, "title": "Edge", "active": true}
        ]}}),
    )
    .await;

    let state = wait_watch(
        &mut r.tabs_rx,
        |s| s.tabs.len() == 1 && s.tabs[0].id == 42,
        "second connection's snapshot never applied",
    )
    .await;
    assert!(state.connected);

    // The FIRST socket observes closure: the relay dropped its stream on
    // replacement, so ext1 sees end/close/error — never a data frame.
    let end = tokio::time::timeout(RECV_TIMEOUT, ext1.next())
        .await
        .expect("timed out waiting for the replaced socket to close");
    match end {
        None | Some(Ok(Message::Close(_))) | Some(Err(_)) => {}
        Some(Ok(other)) => panic!("expected the replaced socket to end, got: {other:?}"),
    }
}

/// Scenario 6 (pitfall-2 regression): an oversize text frame (>64 KB) kills
/// the extension session — the watch resets — and a FRESH connection
/// afterwards still works.
#[tokio::test]
async fn oversize_frame_kills_session_and_relay_recovers() {
    let mut r = spawn_relay().await;
    let mut ext = connect_ext(r.addr).await;

    send_json(&mut ext, tabs_state_frame()).await;
    wait_watch(&mut r.tabs_rx, |s| s.connected, "session never registered").await;

    // 70 KB of junk: exceeds the SPEC §13 per-listener cap. The send itself
    // may fail if the relay slams the connection first — also a valid kill.
    let oversized = "x".repeat(70 * 1024);
    let _ = ext.send(Message::text(oversized)).await;

    // The relay's read arm errors → unconditional watch reset.
    let state = wait_watch(
        &mut r.tabs_rx,
        |s| !s.connected,
        "watch never reset after the oversize frame",
    )
    .await;
    assert_eq!(state, TabsState::default());

    // Recovery: a fresh connection still works.
    let mut ext2 = connect_ext(r.addr).await;
    send_json(&mut ext2, tabs_state_frame()).await;
    wait_watch(
        &mut r.tabs_rx,
        |s| s.connected,
        "relay dead after the oversize-frame kill",
    )
    .await;
}

/// Bonus liveness check rolled into the suite: `ext.ping` gets an
/// `ext.pong` reply (the MV3 keepalive contract, SPEC §15).
#[tokio::test]
async fn ext_ping_gets_pong() {
    let mut r = spawn_relay().await;
    let mut ext = connect_ext(r.addr).await;

    // Register the session first (accept must complete inside the relay).
    send_json(&mut ext, tabs_state_frame()).await;
    wait_watch(&mut r.tabs_rx, |s| s.connected, "session never registered").await;

    send_json(&mut ext, json!({"t": "ext.ping", "p": {}})).await;
    let frame = recv_json(&mut ext).await;
    assert_eq!(frame["t"], "ext.pong", "expected ext.pong, got: {frame}");
}
