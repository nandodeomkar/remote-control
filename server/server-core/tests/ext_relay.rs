//! Socket-level suite for the extension leg (SPEC §15, BROW-01): a REAL
//! `run_ext` relay on an ephemeral 127.0.0.1 port driven by a fake
//! extension via a tokio-tungstenite client.
//!
//! Six scenarios (plan Task 3): tabs.state → watch, disconnect → reset,
//! ExtCmd → activate frame, ExtCmd with no session dropped, newest-wins
//! replacement, and the oversize-frame kill + recovery (pitfall-2
//! regression). Plus the protoVersion-1.5 group scenarios (quick
//! 260716-sme): groups → watch, 16-group belt, malformed-groups
//! tolerant-degrade.
//!
//! protoVersion 1.6 (phase 11) adds the bookmark leg: bm.state → watch, the
//! BOTH-watch reset, the four command frames with correctly TYPED keys, the
//! 500-node belt, and the strict malformed-nodes posture. The ext leg has no
//! codec harness (SPEC §15), so these socket tests plus the §15 prose ARE
//! the contract for this tier — every one of them goes through a real
//! socket, never a direct call into the frame handler.

use std::net::SocketAddr;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio::sync::{mpsc, watch};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

use server_core::executors::{Bookmarks, BookmarksState, ExtInfo, TabsState};
use server_core::transport::ext::{BookmarksRelay, ExtCmd, run_ext};

const RECV_TIMEOUT: Duration = Duration::from_secs(2);

type WsClient = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

/// Everything a relay test needs: the bound address, the watch receiver the
/// phone side would observe, and the command sender the router side would
/// hold.
struct Relay {
    addr: SocketAddr,
    tabs_rx: watch::Receiver<TabsState>,
    /// protoVersion 1.6: the SECOND watch `run_ext` produces into.
    bm_rx: watch::Receiver<BookmarksState>,
    /// protoVersion 1.8: the THIRD watch `run_ext` produces into (the
    /// `ext.hello` version capture, D-09/D-18).
    ext_rx: watch::Receiver<ExtInfo>,
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
    // protoVersion 1.6: `run_ext` owns a SECOND watch, surfaced alongside
    // the tabs receiver so every test can observe both.
    let (bm_tx, bm_rx) = watch::channel(BookmarksState::default());
    // protoVersion 1.8: the THIRD, same discipline.
    let (ext_tx, ext_rx) = watch::channel(ExtInfo::default());
    let (cmd_tx, cmd_rx) = mpsc::channel::<ExtCmd>(16);
    let relay = tokio::spawn(run_ext(listener, tabs_tx, bm_tx, ext_tx, cmd_rx));
    Relay { addr, tabs_rx, bm_rx, ext_rx, cmd_tx, _relay: relay }
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

/// Wait (bounded) for the BOOKMARKS watch to satisfy `pred`.
async fn wait_bm_watch(
    rx: &mut watch::Receiver<BookmarksState>,
    pred: impl FnMut(&BookmarksState) -> bool,
    why: &str,
) -> BookmarksState {
    tokio::time::timeout(RECV_TIMEOUT, rx.wait_for(pred))
        .await
        .unwrap_or_else(|_| panic!("timed out: {why}"))
        .expect("bookmarks watch sender dropped")
        .clone()
}

/// Wait (bounded) for the EXT-INFO watch to satisfy `pred`.
async fn wait_ext_watch(
    rx: &mut watch::Receiver<ExtInfo>,
    pred: impl FnMut(&ExtInfo) -> bool,
    why: &str,
) -> ExtInfo {
    tokio::time::timeout(RECV_TIMEOUT, rx.wait_for(pred))
        .await
        .unwrap_or_else(|_| panic!("timed out: {why}"))
        .expect("ext watch sender dropped")
        .clone()
}

/// The canonical fake-extension snapshot frame.
fn tabs_state_frame() -> Value {
    json!({"t": "tabs.state", "p": {"tabs": [
        {"id": 7, "title": "GitHub", "active": true, "icon": "bbbb"},
        {"id": 9, "title": "Docs", "active": false}
    ]}})
}

/// A `bm.state` snapshot frame carrying `nodes`, plus the optional
/// snapshot-level `truncated` flag when `truncated` is `Some` (the
/// `tabs_state_frame` sibling for the bookmark leg).
fn bm_state_frame(nodes: Vec<Value>, truncated: Option<bool>) -> Value {
    let mut p = json!({"nodes": nodes});
    if let Some(flag) = truncated {
        p["truncated"] = json!(flag);
    }
    json!({"t": "bm.state", "p": p})
}

/// The canonical two-node tree: the bookmarks-bar folder plus one link
/// inside it. Root `"0"` is never shipped — the bar carries `parentId: "0"`.
fn bm_nodes() -> Vec<Value> {
    vec![
        json!({"id": "1", "parentId": "0", "title": "Bookmarks bar", "folder": true, "count": 2}),
        json!({"id": "12", "parentId": "1", "title": "Rust docs"}),
    ]
}

/// Build a `BookmarksRelay` on a relay's channels — the executor the router
/// would hold.
fn bm_relay(r: &Relay) -> BookmarksRelay {
    BookmarksRelay::new(r.bm_rx.clone(), r.cmd_tx.clone())
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

/// protoVersion 1.5 (quick 260716-sme): a `tabs.state` frame WITH groups +
/// per-tab groupId lands in the watch with both intact; the ungrouped tab
/// decodes group_id=None.
#[tokio::test]
async fn tabs_state_with_groups_populates_watch() {
    let mut r = spawn_relay().await;
    let mut ext = connect_ext(r.addr).await;

    send_json(
        &mut ext,
        json!({"t": "tabs.state", "p": {
            "tabs": [
                {"id": 7, "title": "GitHub", "active": true, "groupId": 1},
                {"id": 9, "title": "Docs", "active": false}
            ],
            "groups": [
                {"id": 1, "title": "Work", "color": "blue", "collapsed": false}
            ]
        }}),
    )
    .await;

    let state =
        wait_watch(&mut r.tabs_rx, |s| s.connected, "watch never showed connected:true").await;
    assert_eq!(state.tabs[0].group_id, Some(1), "grouped tab must carry its groupId");
    assert_eq!(state.tabs[1].group_id, None, "ungrouped tab must decode group_id=None");
    assert_eq!(state.groups.len(), 1, "watch must carry the group");
    assert_eq!(state.groups[0].id, 1);
    assert_eq!(state.groups[0].title, "Work");
    assert_eq!(state.groups[0].color, "blue");
    assert!(!state.groups[0].collapsed);
}

/// protoVersion 1.5 belt: 17+ groups in one snapshot are truncated to 16
/// server-side (the MAX_EXT_TABS pattern applied to MAX_EXT_GROUPS).
#[tokio::test]
async fn groups_belt_truncates_at_sixteen() {
    let mut r = spawn_relay().await;
    let mut ext = connect_ext(r.addr).await;

    let groups: Vec<Value> = (0..20)
        .map(|i| json!({"id": i, "title": format!("g{i}"), "color": "grey", "collapsed": false}))
        .collect();
    send_json(
        &mut ext,
        json!({"t": "tabs.state", "p": {
            "tabs": [{"id": 1, "title": "Tab", "active": true}],
            "groups": groups
        }}),
    )
    .await;

    let state =
        wait_watch(&mut r.tabs_rx, |s| s.connected, "watch never showed connected:true").await;
    assert_eq!(state.groups.len(), 16, "server must belt groups at 16");
    assert_eq!(state.groups[0].id, 0);
    assert_eq!(state.groups[15].id, 15, "truncation must keep the FIRST 16");
}

/// protoVersion 1.5 tolerant-degrade: a malformed `groups` value must NOT
/// discard the frame — tabs still land, groups degrade to empty. (Unlike a
/// malformed `tabs`, which ignores the whole frame.)
#[tokio::test]
async fn malformed_groups_degrade_to_empty() {
    let mut r = spawn_relay().await;
    let mut ext = connect_ext(r.addr).await;

    send_json(
        &mut ext,
        json!({"t": "tabs.state", "p": {
            "tabs": [{"id": 5, "title": "Solo", "active": true}],
            "groups": "garbage"
        }}),
    )
    .await;

    let state =
        wait_watch(&mut r.tabs_rx, |s| s.connected, "tabs must land despite bad groups").await;
    assert_eq!(state.tabs.len(), 1, "tabs must survive a malformed groups value");
    assert_eq!(state.tabs[0].id, 5);
    assert!(state.groups.is_empty(), "malformed groups must degrade to []");
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

/// protoVersion 1.6 scenario 1: a `bm.state` frame lands in the BOOKMARKS
/// watch as `{connected:true, nodes}` with every field intact — the
/// `tabs_state_populates_watch` clone for the bookmark leg.
#[tokio::test]
async fn bm_state_populates_bookmarks_watch() {
    let mut r = spawn_relay().await;
    let mut ext = connect_ext(r.addr).await;

    send_json(&mut ext, json!({"t": "ext.hello", "p": {"extVersion": "1.0.0"}})).await;
    send_json(&mut ext, bm_state_frame(bm_nodes(), Some(true))).await;

    let state = wait_bm_watch(
        &mut r.bm_rx,
        |s| s.connected,
        "bookmarks watch never showed connected:true",
    )
    .await;
    assert_eq!(state.nodes.len(), 2, "watch must carry both nodes");
    assert_eq!(state.nodes[0].id, "1", "bookmark ids are STRINGS, not integers");
    assert_eq!(state.nodes[0].parent_id, "0", "the bar hangs off the virtual root");
    assert_eq!(state.nodes[0].title, "Bookmarks bar");
    assert_eq!(state.nodes[0].folder, Some(true));
    assert_eq!(state.nodes[0].count, Some(2));
    assert_eq!(state.nodes[1].id, "12");
    assert_eq!(state.nodes[1].parent_id, "1");
    assert_eq!(state.nodes[1].title, "Rust docs");
    assert_eq!(state.nodes[1].folder, None, "a link omits folder entirely");
    assert!(state.truncated, "the snapshot-level truncated flag must survive");
}

/// protoVersion 1.6 scenario 2 (the Pitfall-2 test): the extension
/// disconnecting resets BOTH watches in the same instant. Both are populated
/// first so the reset is a real transition — this test is capable of failing
/// if only the tabs watch is reset, which is exactly the bug that would
/// leave the phone rendering a stale, tappable bookmark tree next to a
/// correct "install the extension" hint.
#[tokio::test]
async fn ext_disconnect_resets_both_watches() {
    let mut r = spawn_relay().await;
    let mut ext = connect_ext(r.addr).await;

    send_json(&mut ext, tabs_state_frame()).await;
    send_json(&mut ext, bm_state_frame(bm_nodes(), None)).await;
    wait_watch(&mut r.tabs_rx, |s| s.connected, "tabs watch never showed connected").await;
    wait_bm_watch(&mut r.bm_rx, |s| s.connected, "bm watch never showed connected").await;

    // Abrupt drop: no close frame, no goodbye.
    drop(ext);

    let tabs = wait_watch(
        &mut r.tabs_rx,
        |s| !s.connected,
        "tabs watch never reset after the ext disconnect",
    )
    .await;
    assert_eq!(tabs, TabsState::default(), "tabs reset must be the full default");

    let bm = wait_bm_watch(
        &mut r.bm_rx,
        |s| !s.connected,
        "BOOKMARKS watch never reset after the ext disconnect",
    )
    .await;
    assert_eq!(
        bm,
        BookmarksState::default(),
        "bookmarks reset must be the full default — nodes cleared, not just connected:false"
    );
}

/// protoVersion 1.6 scenario 3: `Bookmarks::open` reaches the extension as a
/// `bm.open` frame whose `nodeId` is a JSON **STRING**. The type assertion
/// is the point: `nodeId` (string) vs `tabId` (integer) is the swap gate —
/// a swapped value decodes fine on both sides and fails silently at the
/// extension.
#[tokio::test]
async fn ext_cmd_forwards_bm_open_frame() {
    let mut r = spawn_relay().await;
    let mut ext = connect_ext(r.addr).await;

    // Prove the session is registered before commanding (the watch
    // round-trip is the observable handshake).
    send_json(&mut ext, tabs_state_frame()).await;
    wait_watch(&mut r.tabs_rx, |s| s.connected, "session never registered").await;

    bm_relay(&r).open("1234");
    let frame = recv_json(&mut ext).await;
    assert_eq!(frame["t"], "bm.open", "expected bm.open, got: {frame}");
    assert!(
        frame["p"]["nodeId"].is_string(),
        "nodeId MUST be a JSON string, got: {}",
        frame["p"]["nodeId"]
    );
    assert_eq!(frame["p"]["nodeId"], "1234");
}

/// protoVersion 1.6 scenario 4: the remaining three commands. `bm.star` and
/// `bm.unstar` carry `tabId` as a JSON **NUMBER**; `bm.remove` carries
/// `nodeId` as a JSON **STRING**. All four key names are now pinned.
#[tokio::test]
async fn ext_cmd_forwards_bm_star_frame() {
    let mut r = spawn_relay().await;
    let mut ext = connect_ext(r.addr).await;

    send_json(&mut ext, tabs_state_frame()).await;
    wait_watch(&mut r.tabs_rx, |s| s.connected, "session never registered").await;

    let relay = bm_relay(&r);

    relay.star(7);
    let frame = recv_json(&mut ext).await;
    assert_eq!(frame["t"], "bm.star", "expected bm.star, got: {frame}");
    assert!(
        frame["p"]["tabId"].is_i64(),
        "tabId MUST be a JSON integer, got: {}",
        frame["p"]["tabId"]
    );
    assert_eq!(frame["p"]["tabId"], 7);

    relay.unstar(9);
    let frame = recv_json(&mut ext).await;
    assert_eq!(frame["t"], "bm.unstar", "expected bm.unstar, got: {frame}");
    assert!(frame["p"]["tabId"].is_i64(), "unstar tabId MUST be a JSON integer");
    assert_eq!(frame["p"]["tabId"], 9);

    relay.remove("42");
    let frame = recv_json(&mut ext).await;
    assert_eq!(frame["t"], "bm.remove", "expected bm.remove, got: {frame}");
    assert!(frame["p"]["nodeId"].is_string(), "remove nodeId MUST be a JSON string");
    assert_eq!(frame["p"]["nodeId"], "42");
}

/// protoVersion 1.6 belt (T-11-07): 600 nodes in one snapshot are truncated
/// to 500 server-side, regardless of the extension's own cap — the
/// `groups_belt_truncates_at_sixteen` pattern at bookmark scale.
#[tokio::test]
async fn bm_nodes_belt_truncates_at_five_hundred() {
    let mut r = spawn_relay().await;
    let mut ext = connect_ext(r.addr).await;

    let nodes: Vec<Value> = (0..600)
        .map(|i| json!({"id": i.to_string(), "parentId": "0", "title": format!("n{i}")}))
        .collect();
    send_json(&mut ext, bm_state_frame(nodes, None)).await;

    let state = wait_bm_watch(
        &mut r.bm_rx,
        |s| s.connected,
        "bookmarks watch never showed connected:true",
    )
    .await;
    assert_eq!(state.nodes.len(), 500, "server must belt bookmark nodes at 500");
    assert_eq!(state.nodes[0].id, "0");
    assert_eq!(state.nodes[499].id, "499", "truncation must keep the FIRST 500");
}

/// protoVersion 1.6 STRICT posture: a malformed `nodes` value ignores the
/// WHOLE frame — the watch keeps the previous good snapshot. This is the
/// deliberate CONTRAST with `malformed_groups_degrade_to_empty`: groups are
/// decoration and degrade to empty, but nodes ARE the payload, so degrading
/// them would render "you have no bookmarks" as if it were an answer.
#[tokio::test]
async fn malformed_bm_nodes_ignore_frame() {
    let mut r = spawn_relay().await;
    let mut ext = connect_ext(r.addr).await;

    send_json(&mut ext, bm_state_frame(bm_nodes(), None)).await;
    wait_bm_watch(&mut r.bm_rx, |s| s.connected, "good snapshot never landed").await;

    // A node missing the wire-required `title` — a hard decode error.
    send_json(
        &mut ext,
        bm_state_frame(vec![json!({"id": "99", "parentId": "0"})], None),
    )
    .await;

    // Frames are processed in order on one socket, so a marker frame that
    // moves the OTHER watch proves the bad bm.state was already handled.
    send_json(&mut ext, tabs_state_frame()).await;
    wait_watch(&mut r.tabs_rx, |s| s.connected, "marker frame never landed").await;

    let state = r.bm_rx.borrow().clone();
    assert_eq!(state.nodes.len(), 2, "the previous good snapshot must survive");
    assert_eq!(state.nodes[0].id, "1");
    assert_eq!(state.nodes[1].id, "12");
    assert!(state.connected, "the frame was ignored, not treated as a disconnect");
}

/// protoVersion 1.8 scenario 1 (D-09/D-18): an `ext.hello` carrying
/// `extVersion` populates the THIRD watch with `connected:true` and that
/// version — the field `update.status` reports as `extVersion`.
#[tokio::test]
async fn ext_hello_populates_ext_watch_with_version() {
    let mut r = spawn_relay().await;
    let mut ext = connect_ext(r.addr).await;

    send_json(&mut ext, json!({"t": "ext.hello", "p": {"extVersion": "1.5.0"}})).await;

    let info = wait_ext_watch(
        &mut r.ext_rx,
        |s| s.connected,
        "ext watch never showed connected:true",
    )
    .await;
    assert_eq!(
        info.version.as_deref(),
        Some("1.5.0"),
        "the extension's self-reported version must reach the watch verbatim"
    );
    assert_eq!(info, ExtInfo { connected: true, version: Some("1.5.0".into()) });
}

/// protoVersion 1.8 scenario 2 (T-12-41, the lenient ext-leg convention): an
/// `ext.hello` with NO `extVersion` is NOT an error — it yields
/// `{connected:true, version:None}`. An extension built before 1.8 sends
/// exactly this frame, and "connected but version unknown" is a truthful
/// state (`update.status` omits `extVersion` for it).
///
/// The `null` and non-string cases ride along: `and_then(Value::as_str)`
/// makes all three the same answer, and none of them may drop the frame or
/// panic.
#[tokio::test]
async fn ext_hello_without_version_is_not_an_error() {
    for payload in [json!({}), json!({"extVersion": null}), json!({"extVersion": 150})] {
        let mut r = spawn_relay().await;
        let mut ext = connect_ext(r.addr).await;

        send_json(&mut ext, json!({"t": "ext.hello", "p": payload.clone()})).await;

        let info = wait_ext_watch(
            &mut r.ext_rx,
            |s| s.connected,
            "a versionless ext.hello must still mark the extension connected",
        )
        .await;
        assert_eq!(
            info.version, None,
            "{payload} must degrade to version:None, never an error"
        );

        // The relay is still alive and still processing frames afterwards —
        // the lenient read did not kill the session.
        send_json(&mut ext, tabs_state_frame()).await;
        wait_watch(
            &mut r.tabs_rx,
            |s| s.connected,
            "the relay died on a versionless ext.hello",
        )
        .await;
    }
}

/// protoVersion 1.8 scenario 3 — the three-watch reset, asserted in ONE
/// observation so the cleanup sites cannot drift apart.
///
/// All three watches are populated first, so every reset is a real
/// transition: this test is capable of failing if ANY of the three is missed
/// at `reset_relay_watches`. That function is the single session-death
/// cleanup point precisely so a fourth watch cannot be added without landing
/// here too.
#[tokio::test]
async fn ext_disconnect_resets_all_three_watches() {
    let mut r = spawn_relay().await;
    let mut ext = connect_ext(r.addr).await;

    send_json(&mut ext, json!({"t": "ext.hello", "p": {"extVersion": "1.5.0"}})).await;
    send_json(&mut ext, tabs_state_frame()).await;
    send_json(&mut ext, bm_state_frame(bm_nodes(), None)).await;
    wait_watch(&mut r.tabs_rx, |s| s.connected, "tabs watch never showed connected").await;
    wait_bm_watch(&mut r.bm_rx, |s| s.connected, "bm watch never showed connected").await;
    wait_ext_watch(&mut r.ext_rx, |s| s.connected, "ext watch never showed connected").await;

    // Abrupt drop: no close frame, no goodbye.
    drop(ext);

    // Wait on the LAST watch to be reset in source order, then read the other
    // two synchronously: `reset_relay_watches` sends all three before it
    // returns, so once the third has landed the first two cannot still be
    // stale. That is what makes this ONE observation rather than three.
    let ext_info = wait_ext_watch(
        &mut r.ext_rx,
        |s| !s.connected,
        "EXT watch never reset after the ext disconnect",
    )
    .await;
    assert_eq!(
        ext_info,
        ExtInfo::default(),
        "ext reset must be the full default — the version cleared, not just connected:false"
    );

    assert_eq!(
        r.tabs_rx.borrow().clone(),
        TabsState::default(),
        "tabs must be reset in the SAME instant as ext info"
    );
    assert_eq!(
        r.bm_rx.borrow().clone(),
        BookmarksState::default(),
        "bookmarks must be reset in the SAME instant as ext info"
    );
}
